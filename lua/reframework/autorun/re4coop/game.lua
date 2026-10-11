-- RE4 (2023) adapter: the only module that touches REFramework's `sdk`, `draw` and game
-- objects. Everything else talks to the game through the methods below.
--
-- Type and method names come from REFramework's own RE4 helper (scripts/utility/RE4.lua),
-- published RE4R mods and the game's PAK file list (see docs/RESEARCH.md). Names that
-- could not be confirmed are *probed* at runtime: each capability is looked up once,
-- reported in the UI's diagnostics panel, and the feature that needs it switches itself
-- off if it is missing. Every game call is wrapped in pcall so a game patch degrades
-- features instead of throwing errors every frame.

local P = require("re4coop.protocol")

local Game = {}
Game.__index = Game

local CHARACTER_MANAGER = "chainsaw.CharacterManager"
local GUI_MANAGER = "chainsaw.GuiManager"
local HIT_POINT = "chainsaw.HitPoint"
local GUN = "chainsaw.Gun"

-- Writing an enemy's current HP: no public RE4R source names the setter, so candidates are
-- collected from chainsaw.HitPoint itself (known names first, then any "set...HitPoint/HP"
-- method or "current HP" field with one numeric value) and a candidate is only trusted once
-- reading get_CurrentHitPoint back shows the value it wrote. See write_hp().
local HP_SETTERS = { "set_CurrentHitPoint", "setCurrentHitPoint", "setHitPoint", "set_HitPoint" }
local HP_FIELDS = { "<CurrentHitPoint>k__BackingField", "_CurrentHitPoint", "CurrentHitPoint", "_HitPoint" }
-- Words that mark a setter/field as something other than the current HP value.
local HP_NAME_EXCLUDE = { "default", "max", "init", "rate", "ratio", "base", "invincible", "damage", "dead",
    "recover", "param", "table", "flag", "enable", "lock", "limit", "reset", "add", "sub", "heal", "regen",
    "event", "callback", "delegate", "listener", "notify", "request", "min" }
local HP_CANDIDATE_TRIES = 3   -- failed verifications before a candidate is set aside
-- Enemies can refuse HP changes for a while (invincible phases, scripted states), so a
-- set-aside candidate is retried after this many further write attempts, and a writer that
-- was verified once is never dropped.
local HP_RETRY_AFTER_WRITES = 60
local KILL_METHODS = { "dead", "setDead", "kill", "die" }

-- RE4 key items occupy one ItemID block (all 16 key items in the resyst/re4r autosplitter,
-- e.g. Wooden Cog 119235200, Church Insignia 119257600, are 119,2xx,xxx).
local KEY_ITEM_MIN, KEY_ITEM_MAX = 119000000, 119999999
local AREA_PROBES = {
    { "chainsaw.CampaignManager", { "get_CurrentChapter", "get_CurrentChapterID", "get_ChapterID", "get_CurrentChapterNo" } },
    { "chainsaw.GameStatusManager", { "get_CurrentChapter", "get_ChapterID" } },
    { "chainsaw.LevelManager", { "get_CurrentLevelID", "get_CurrentLevel", "get_LevelID" } },
    { "chainsaw.MapManager", { "get_CurrentMapID", "get_CurrentAreaID", "get_CurrentMap" } },
}

-- Partner model. Every character has <id>_body.pfb (skeleton, materials, physics) and
-- <id>_head.pfb (game logic); costume parts are separate prefabs/meshes. Paths come from
-- the game's file list (e.g. _chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb for
-- Leon, _mercenaries/.../ch3a8z0/ch3a8z0_body.pfb for Ada) and are confirmed at runtime
-- with via.Prefab.get_Exist before use.
local CONTENT_PREFIXES = { "_chainsaw", "_mercenaries", "_anotherorder" }
local BODY_PREFAB = "%s/appsystem/character/%s/%s_body.pfb"
local WEAPON_PREFAB = "%s/appsystem/prefab/weapon/%s.pfb"
local MUZZLE_FLASH_PREFAB = "_chainsaw/vfx/provider/epv_system/epv_muzzleflash/epve_0015_muzzleflash_0000.pfb"

-- Weapon GameObjects are named after their id: wp4000 (SG-09 R), wp4100 (W-870), ...,
-- with _ao (Separate Ways) / _mc (Mercenaries) variants.
local WEAPON_PATTERN = "^wp%d%d%d%d"
local WEAPON_IDS = {}
for _, r in ipairs({ { 4000, 4005 }, { 4100, 4102 }, { 4200, 4202 }, { 4400, 4402 }, { 4500, 4502 },
    { 4600, 4600 }, { 4701, 4702 }, { 4800, 4800 }, { 4900, 4902 }, { 5000, 5006 }, { 5300, 5301 },
    { 5400, 5408 }, { 6000, 6001 }, { 6100, 6114 }, { 6300, 6300 }, { 6304, 6304 }, { 6400, 6400 } }) do
    for id = r[1], r[2] do WEAPON_IDS[#WEAPON_IDS + 1] = "wp" .. id end
end

-- Sounds and effects are replayed by mirroring calls the game makes on the local
-- player's components: the partner's model carries the same components (it is built
-- from the same prefabs), so the same call plays the same sound/effect at its position.
local MIRRORS = {
    { type = "via.wwise.WwiseContainer", prefix = "trigger", kind = "sound", fallback = true },
    { type = "via.effect.script.EPVStandard", prefix = "requestEffect", kind = "effect" },
}
-- chainsaw.Gun methods that may mark a shot (probed; see diagnostics), else ammo polling.
local SHOOT_METHODS = { "shoot", "shot", "fire", "doShoot", "doFire", "execShoot", "shootBullet",
    "fireBullet", "requestShoot", "onShoot", "onFire" }
local AMMO_GETTERS = { "get_CurrentAmmoCount", "get_CurrentAmmo", "get_AmmoCount", "get_LoadedAmmo",
    "get_LoadedAmmoCount", "get_CurrentBulletCount", "get_BulletCount", "get_RemainingBulletCount" }

local AVATAR_RESCAN = 1.0  -- seconds between scans of what the local character is made of
local GEAR_RESCAN = 0.25
local SCENE_WEAPON_SEARCH = 2.0
local MAX_SCAN_OBJECTS = 128
local MAX_PENDING_EVENTS = 128
local MAX_CALLS_PER_SECOND = 120
-- Joints whose local position is animated too (pelvis height when crouching, root motion).
local TRANSLATE_HINTS = { "root", "hip", "cog", "pelvis", "waist", "center", "centre" }

-- Components a puppet keeps running: rendering, sound and effects. Everything listed in
-- PUPPET_DISABLE is game logic, physics or animation and is switched off, which turns the
-- spawned body into a pure visual that only our pose stream moves.
local PUPPET_DISABLE = { "chainsaw.", "app.", "via.behaviortree.", "via.physics.", "via.motion.Motion",
    "via.motion.Ik", "via.motion.Look", "via.navigation.", "via.dynamics.", "via.gui.", "via.ai." }

local ARG_KIND = {
    ["System.UInt32"] = P.ARG.U32, ["System.UInt16"] = P.ARG.U32, ["System.Byte"] = P.ARG.U32,
    ["System.Int32"] = P.ARG.I32, ["System.Int16"] = P.ARG.I32, ["System.SByte"] = P.ARG.I32,
    ["System.Boolean"] = P.ARG.BOOL, ["System.Single"] = P.ARG.F32,
    ["System.Int64"] = P.ARG.I64, ["System.UInt64"] = P.ARG.I64,
    ["via.GameObject"] = P.ARG.OBJ,
}
local ARG_REF = "ref" -- a managed reference other than a GameObject: only null can travel

local function v3(v)
    if v == nil then return nil end
    return { x = v.x, y = v.y, z = v.z }
end

local function q4(q)
    if q == nil then return nil end
    return { x = q.x, y = q.y, z = q.z, w = q.w }
end

local function qmul(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end

local function qconj(q)
    return { x = -q.x, y = -q.y, z = -q.z, w = q.w }
end

-- Rotates v by unit quaternion q.
local function qrot(q, v)
    local tx = 2 * (q.y * v.z - q.z * v.y)
    local ty = 2 * (q.z * v.x - q.x * v.z)
    local tz = 2 * (q.x * v.y - q.y * v.x)
    return {
        x = v.x + q.w * tx + (q.y * tz - q.z * ty),
        y = v.y + q.w * ty + (q.z * tx - q.x * tz),
        z = v.z + q.w * tz + (q.x * ty - q.y * tx),
    }
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function starts_with_any(s, prefixes)
    for _, p in ipairs(prefixes) do
        if s:sub(1, #p) == p then return true end
    end
    return false
end

local function name_matches(name, list)
    for _, p in ipairs(list) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

function Game.new(log, clock)
    local self = setmetatable({}, Game)
    self.log = log or function() end
    self.clock = clock or os.clock
    self.method_cache = {}
    self.caps = {}        -- name -> { ok=bool, detail=string }
    self.enemy_ctx = {}   -- id -> context object from the latest list_enemies()
    self.area_probe = nil
    self.prefab_exist = {} -- path -> bool
    self.claimed = {}      -- addresses of objects that belong to the partner's model
    self.resources = {}    -- "type|path" -> holder (kept referenced)
    self.capture_enabled = false
    self.events = {}
    self.avatar = nil      -- local character description (see avatar_descriptor)
    self.gear = nil
    self.avatar_comp_ref = {}
    self.gear_comp_ref = {}
    self.gun_slot = {}
    self.last_shot = {}
    self.ammo_seen = {}
    self.call_budget = { t = 0, n = 0 }
    self.counters = { calls = 0, calls_fallback = 0, calls_skipped = 0, shots = 0, events_dropped = 0 }
    self.pickup_events = {} -- filled by the DropItem callback hooks, drained by take_pickup_events()
    self:probe()
    self:install_pickup_hooks()
    return self
end

-------------------------------------------------------------------------------
-- Reflection helpers
-------------------------------------------------------------------------------

function Game:cap(name, ok, detail)
    self.caps[name] = { ok = ok and true or false, detail = detail or "" }
    return ok
end

local function type_name_of(obj)
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or td == nil then return nil, nil end
    return td:get_full_name(), td
end

-- Runtime type name and definition of a managed object.
function Game:type_name(obj)
    return type_name_of(obj)
end

-- Looks up (and caches) a method by name on the object's runtime type.
function Game:method(obj, name)
    local tname, td = type_name_of(obj)
    if tname == nil then return nil end
    local key = tname .. "::" .. name
    local m = self.method_cache[key]
    if m == nil then
        local ok, found = pcall(td.get_method, td, name)
        m = (ok and found) or false
        self.method_cache[key] = m
    end
    return m or nil
end

function Game:call(obj, name, ...)
    if obj == nil then return nil end
    local m = self:method(obj, name)
    if m == nil then return nil end
    local ok, r = pcall(m.call, m, obj, ...)
    if ok then return r end
    return nil
end

local function singleton(name)
    local ok, s = pcall(sdk.get_managed_singleton, name)
    if ok then return s end
    return nil
end

local function find_type(name)
    local ok, td = pcall(sdk.find_type_definition, name)
    if ok then return td end
    return nil
end

local function method_param_count(m)
    local ok, n = pcall(m.get_num_params, m)
    return ok and n or -1
end

local function method_param_type(m, i)
    local ok, types = pcall(m.get_param_types, m)
    if not ok or types == nil or types[i] == nil then return nil end
    local ok2, name = pcall(types[i].get_full_name, types[i])
    return ok2 and name or nil
end

local function address_of(obj)
    local ok, a = pcall(obj.get_address, obj)
    return ok and a or nil
end

local INTEGER_TYPES = {
    ["System.Int32"] = true, ["System.UInt32"] = true, ["System.Int16"] = true,
    ["System.UInt16"] = true, ["System.Int64"] = true, ["System.UInt64"] = true,
    ["System.Byte"] = true, ["System.SByte"] = true,
}
local FLOAT_TYPES = { ["System.Single"] = true, ["System.Double"] = true }

local function type_hierarchy(td, max_depth)
    local out, depth = {}, 0
    while td ~= nil and depth < (max_depth or 8) do
        local ok, name = pcall(td.get_full_name, td)
        if not ok or name == "System.Object" then break end
        out[#out + 1] = td
        local okp, parent = pcall(td.get_parent_type, td)
        td = okp and parent or nil
        depth = depth + 1
    end
    return out
end

local function field_type_name(f)
    local ok, name = pcall(function() return f:get_type():get_full_name() end)
    return ok and name or nil
end

local function field_is_static(f)
    local ok, v = pcall(f.is_static, f)
    return ok and v or false
end

local function looks_like_current_hp(lname)
    if not (lname:find("hitpoint", 1, true) or lname:find("hp", 1, true)) then return false end
    return not name_matches(lname, HP_NAME_EXCLUDE)
end

-- Resolves the capabilities we cannot confirm statically.
function Game:probe()
    self:cap("character_manager_type", find_type(CHARACTER_MANAGER) ~= nil, CHARACTER_MANAGER)

    local hp_td = find_type(HIT_POINT)
    self.kill_method = nil
    self.hp_writer, self.hp_writer_fails, self.hp_writes_since_reject = nil, 0, 0
    self.hp_candidates = hp_td and self:collect_hp_writers(hp_td) or {}
    if hp_td ~= nil then
        for _, name in ipairs(KILL_METHODS) do
            local m = hp_td:get_method(name)
            if m ~= nil and method_param_count(m) == 0 then
                self.kill_method = name
                break
            end
        end
    end
    self:cap("hitpoint_type", hp_td ~= nil, HIT_POINT)
    self:report_hp_writer()
    self:cap("enemy_kill", self.kill_method ~= nil or #self.hp_candidates > 0,
        self.kill_method and ("method " .. self.kill_method .. "()") or "fallback: set HP to 0")

    local japi = self:joint_api()
    self:cap("joints", japi ~= nil, japi and "via.Joint local rotation get/set" or "via.Joint methods missing")
end

-- Lists every plausible way to write chainsaw.HitPoint's current HP, best guesses first.
function Game:collect_hp_writers(hp_td)
    local out, seen = {}, {}
    local function add(w)
        if not seen[w.label] then
            seen[w.label] = true
            out[#out + 1] = w
        end
    end
    local function method_writer(m, name)
        if method_param_count(m) ~= 1 then return end
        local pt = method_param_type(m, 1) or ""
        if not (INTEGER_TYPES[pt] or FLOAT_TYPES[pt]) then return end
        add({ kind = "method", name = name, method = m, int = INTEGER_TYPES[pt] or false, label = "method " .. name, tries = 0 })
    end
    local function field_writer(f, name)
        local ft = field_type_name(f) or ""
        if field_is_static(f) or not (INTEGER_TYPES[ft] or FLOAT_TYPES[ft]) then return end
        add({ kind = "field", name = name, int = INTEGER_TYPES[ft] or false, label = "field " .. name, tries = 0 })
    end

    for _, name in ipairs(HP_SETTERS) do
        local ok, m = pcall(hp_td.get_method, hp_td, name)
        if ok and m ~= nil then method_writer(m, name) end
    end
    local discovered = {}
    for _, td in ipairs(type_hierarchy(hp_td, 4)) do
        local ok, methods = pcall(td.get_methods, td)
        for _, m in ipairs(ok and methods or {}) do
            local okn, name = pcall(m.get_name, m)
            local lname = okn and name:lower() or ""
            if lname:sub(1, 3) == "set" and looks_like_current_hp(lname) then
                discovered[#discovered + 1] = { m = m, name = name, current = lname:find("cur", 1, true) ~= nil }
            end
        end
    end
    table.sort(discovered, function(a, b)
        if a.current ~= b.current then return a.current end
        return a.name < b.name
    end)
    for _, d in ipairs(discovered) do method_writer(d.m, d.name) end

    for _, name in ipairs(HP_FIELDS) do
        local ok, f = pcall(hp_td.get_field, hp_td, name)
        if ok and f ~= nil then field_writer(f, name) end
    end
    for _, td in ipairs(type_hierarchy(hp_td, 4)) do
        local ok, fields = pcall(td.get_fields, td)
        for _, f in ipairs(ok and fields or {}) do
            local okn, name = pcall(f.get_name, f)
            local lname = okn and name:lower() or ""
            if looks_like_current_hp(lname) and (lname:find("cur", 1, true) or lname == "_hp" or lname == "_hitpoint") then
                field_writer(f, name)
            end
        end
    end
    return out
end

function Game:report_hp_writer()
    if self.hp_writer ~= nil then
        local fails = self.hp_writer_fails > 0 and (" (%d writes refused by the enemy)"):format(self.hp_writer_fails) or ""
        self:cap("enemy_set_hp", true, "verified " .. self.hp_writer.label .. fails)
        return
    end
    local names = {}
    for _, w in ipairs(self.hp_candidates or {}) do
        names[#names + 1] = w.label .. (w.rejected and " (rejected)" or "")
    end
    if #names == 0 then
        self:cap("enemy_set_hp", false, "no HP setter candidates on chainsaw.HitPoint - please send the research dump")
    else
        self:cap("enemy_set_hp", false, "untested: " .. table.concat(names, ", "))
    end
end

function Game:capabilities()
    return self.caps
end

-- chainsaw.ContextID (a class: _Category, _Kind, _Group, _Index - confirmed by the research
-- dump) to a plain table, or nil.
local function read_field(obj, name)
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

local function context_id_table(id)
    if id == nil then return nil end
    local group, index = tonumber(read_field(id, "_Group")), tonumber(read_field(id, "_Index"))
    if group == nil or index == nil then return nil end
    return {
        category = tonumber(read_field(id, "_Category")) or 0,
        kind = tonumber(read_field(id, "_Kind")) or 0,
        group = group,
        index = index,
    }
end

-- An object's own `_ID`. For characters and drop items this is a runtime counter (the dump
-- showed enemies 12:312, 12:987, 12:1053 and items 12:192..486), so it is NOT the same on
-- both machines - use it only as a local identity.
function Game:read_context_id(obj)
    return context_id_table(read_field(obj, "_ID"))
end

-- CharacterContext.get_SpawnerID(): the level spawner that created this character. Spawners
-- are placed in level data, so this is the cross-machine identity for an enemy - although one
-- spawner may create several enemies (enemy_sync only trusts it when unique).
function Game:read_spawner_id(ctx)
    return context_id_table(self:call(ctx, "get_SpawnerID"))
end

-------------------------------------------------------------------------------
-- Engine helpers: GameObjects, components, transforms, joints, resources
-------------------------------------------------------------------------------

function Game:typeof(type_name)
    local t = self.typeof_cache and self.typeof_cache[type_name]
    if t == nil then
        local ok, ty = pcall(sdk.typeof, type_name)
        t = ok and ty or false
        self.typeof_cache = self.typeof_cache or {}
        self.typeof_cache[type_name] = t
    end
    return t or nil
end

function Game:get_component(game_object, type_name)
    local t = self:typeof(type_name)
    if not t then return nil end
    return self:call(game_object, "getComponent(System.Type)", t)
end

-- Cached via.Joint methods; joints are read and written hundreds of times per frame.
function Game:joint_api()
    if self.japi == nil then
        local td = find_type("via.Joint")
        local api = td and {
            get_lrot = td:get_method("get_LocalRotation"), set_lrot = td:get_method("set_LocalRotation"),
            get_lpos = td:get_method("get_LocalPosition"), set_lpos = td:get_method("set_LocalPosition"),
            get_name = td:get_method("get_Name"), get_pos = td:get_method("get_Position"),
        }
        self.japi = (api and api.get_lrot and api.set_lrot and api.get_name) and api or false
    end
    return self.japi or nil
end

function Game:scene()
    local ok, scene = pcall(function()
        return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    end)
    return ok and scene or nil
end

function Game:find_game_object(name)
    local scene = self:scene()
    return scene and self:call(scene, "findGameObject(System.String)", name) or nil
end

function Game:transform_of(go)
    return go and self:call(go, "get_Transform") or nil
end

function Game:name_of(go)
    return tostring(go and self:call(go, "get_Name") or "")
end

-- A component is alive while its owner GameObject pointer (offset 0x10) is a managed
-- object; the game clears it when it destroys the object (area unloads, cutscenes).
function Game:alive(component)
    if component == nil then return false end
    local ok, alive = pcall(function()
        local owner = component:read_qword(0x10)
        return owner ~= nil and owner ~= 0 and sdk.is_managed_object(owner)
    end)
    return ok and alive == true
end

function Game:children(tf)
    local out = {}
    local c = self:call(tf, "get_Child")
    while c ~= nil and #out < 256 do
        out[#out + 1] = c
        c = self:call(c, "get_Next")
    end
    return out
end

function Game:components(go)
    local arr = self:call(go, "get_Components")
    if arr == nil then return {} end
    local ok, list = pcall(arr.get_elements, arr)
    if ok and type(list) == "table" then return list end
    local out = {}
    local ok2, n = pcall(arr.get_size, arr)
    for i = 0, (ok2 and n or 0) - 1 do
        local ok3, c = pcall(arr.get_element, arr, i)
        if ok3 and c ~= nil then out[#out + 1] = c end
    end
    return out
end

function Game:joint_list(tf)
    local arr = tf and self:call(tf, "get_Joints")
    if arr == nil then return {} end
    local ok, n = pcall(arr.get_size, arr)
    if not ok or type(n) ~= "number" then return {} end
    local out = {}
    for i = 0, n - 1 do
        local ok2, j = pcall(arr.get_element, arr, i)
        if ok2 and j ~= nil then out[#out + 1] = j end
    end
    return out
end

function Game:joint_count(tf)
    local arr = tf and self:call(tf, "get_Joints")
    if arr == nil then return 0 end
    local ok, n = pcall(arr.get_size, arr)
    return ok and tonumber(n) or 0
end

function Game:joint_name(joint)
    local api = self:joint_api()
    if api == nil then return nil end
    local ok, name = pcall(api.get_name.call, api.get_name, joint)
    return ok and name and tostring(name) or nil
end

-- Returns x, y, z, w (or nil).
function Game:get_joint_rotation(joint)
    local api = self.japi
    if not api then return nil end
    local ok, q = pcall(api.get_lrot.call, api.get_lrot, joint)
    if not ok or q == nil then return nil end
    return q.x, q.y, q.z, q.w
end

function Game:set_joint_rotation(joint, x, y, z, w)
    local api = self.japi
    if not api then return false end
    return (pcall(api.set_lrot.call, api.set_lrot, joint, Quaternion.new(w, x, y, z)))
end

function Game:get_joint_position(joint)
    local api = self.japi
    if not api or not api.get_lpos then return nil end
    local ok, p = pcall(api.get_lpos.call, api.get_lpos, joint)
    if not ok or p == nil then return nil end
    return p.x, p.y, p.z
end

function Game:set_joint_position(joint, x, y, z)
    local api = self.japi
    if not api or not api.set_lpos then return false end
    return (pcall(api.set_lpos.call, api.set_lpos, joint, Vector3f.new(x, y, z)))
end

function Game:joint_world_position(joint)
    local api = self.japi
    if joint == nil or api == nil or not api.get_pos then return nil end
    local ok, p = pcall(api.get_pos.call, api.get_pos, joint)
    return ok and v3(p) or nil
end

function Game:world_transform(tf)
    return v3(self:call(tf, "get_Position")), q4(self:call(tf, "get_Rotation"))
end

function Game:set_world_transform(tf, pos, rot)
    return pcall(function()
        tf:call("set_Position", Vector3f.new(pos.x, pos.y, pos.z))
        if rot then tf:call("set_Rotation", Quaternion.new(rot.w, rot.x, rot.y, rot.z)) end
    end)
end

function Game:set_local_transform(tf, pos, rot)
    return pcall(function()
        if pos then tf:call("set_LocalPosition", Vector3f.new(pos.x, pos.y, pos.z)) end
        if rot then tf:call("set_LocalRotation", Quaternion.new(rot.w, rot.x, rot.y, rot.z)) end
    end)
end

-- Resource holders print as "...[@path]"; newer builds also expose get_ResourcePath.
local function resource_path(holder)
    if holder == nil then return nil end
    local ok, p = pcall(holder.call, holder, "get_ResourcePath")
    if ok and type(p) == "string" and p ~= "" then return p end
    local ok2, s = pcall(holder.call, holder, "ToString()")
    if ok2 and type(s) == "string" then return s:match("^.+%[@?(.+)%]") end
    return nil
end

-- Returns mesh path, material path, Mesh component (or nil when the object has no mesh).
function Game:mesh_info(go)
    local mesh = self:get_component(go, "via.render.Mesh")
    if mesh == nil then return nil end
    local mpath = resource_path(self:call(mesh, "getMesh"))
    if mpath == nil or mpath == "" then return nil end
    return mpath, resource_path(self:call(mesh, "get_Material")) or "", mesh
end

-- Objects spawned for the partner's model get a "re4coop_" name so neither the game nor
-- name lookups (ours included) mistake them for the local player's, and are excluded from
-- capture even where renaming is not possible.
function Game:claim(go, name)
    local addr = address_of(go)
    if addr ~= nil then self.claimed[addr] = true end
    if name ~= nil then pcall(go.call, go, "set_Name", name) end
end

function Game:unclaim(go)
    local addr = go and address_of(go)
    if addr ~= nil then self.claimed[addr] = nil end
end

function Game:is_claimed(go)
    local addr = go and address_of(go)
    return addr ~= nil and self.claimed[addr] == true
end

function Game:is_drawn(go)
    return self:call(go, "get_Draw") ~= false
end

function Game:set_drawn(go, on)
    return pcall(go.call, go, "set_DrawSelf", on and true or false)
end

function Game:resource_holder(type_name, path)
    local key = type_name .. "|" .. path
    local holder = self.resources[key]
    if holder == nil then
        local ok, h = pcall(function()
            local res = sdk.create_resource(type_name, path)
            if res == nil then return nil end
            res = res:add_ref()
            local hd = res:create_holder(type_name .. "Holder")
            return hd and hd:add_ref() or nil
        end)
        holder = ok and h or false
        self.resources[key] = holder
    end
    return holder or nil
end

function Game:set_mesh(mesh_comp, mesh_path, mdf_path)
    local ok = true
    if mesh_path and mesh_path ~= "" then
        local h = self:resource_holder("via.render.MeshResource", mesh_path)
        ok = h ~= nil and self:call(mesh_comp, "setMesh", h) ~= false
    end
    if mdf_path and mdf_path ~= "" then
        local m = self:resource_holder("via.render.MeshMaterialResource", mdf_path)
        if m ~= nil then self:call(mesh_comp, "set_Material", m) end
    end
    return ok
end

function Game:create_game_object(name)
    local td = find_type("via.GameObject")
    local create = td and td:get_method("create(System.String)")
    if create == nil then return nil end
    local ok, go = pcall(create.call, create, nil, name)
    if not ok or go == nil then return nil end
    pcall(function() go = go:add_ref() end)
    pcall(go.call, go, ".ctor")
    return go
end

function Game:add_component(go, type_name)
    local t = self:typeof(type_name)
    if not t then return nil end
    local ok, comp = pcall(go.call, go, "createComponent(System.Type)", t)
    if not ok or comp == nil then return nil end
    pcall(function() comp = comp:add_ref() end)
    pcall(comp.call, comp, ".ctor()")
    return comp
end

-- A bare GameObject showing one mesh: how parts the body prefab lacks are rebuilt.
function Game:create_mesh_object(name, mesh_path, mdf_path)
    local go = self:create_game_object(name)
    if go == nil then return nil end
    local mesh = self:add_component(go, "via.render.Mesh")
    if mesh == nil or not self:set_mesh(mesh, mesh_path, mdf_path) then
        self:destroy_game_object(go)
        return nil
    end
    return go
end

-- opts: { joint = parent joint name or "", same_joints = bool, lpos, lrot }
function Game:attach(child_go, parent_go, opts)
    local ct, pt = self:transform_of(child_go), self:transform_of(parent_go)
    if ct == nil or pt == nil then return false end
    local ok = pcall(ct.call, ct, "set_Parent", pt)
    if opts.joint ~= nil then pcall(ct.call, ct, "set_ParentJoint", opts.joint) end
    if opts.same_joints ~= nil then pcall(ct.call, ct, "set_SameJointsConstraint", opts.same_joints) end
    if opts.lpos or opts.lrot then self:set_local_transform(ct, opts.lpos, opts.lrot) end
    return ok
end

function Game:destroy_game_object(go)
    if go == nil then return end
    if self:alive(self:transform_of(go)) then
        pcall(go.call, go, "destroy", go)
    end
    self:unclaim(go)
end

-- Every GameObject in go's hierarchy (go first), with its transform.
function Game:collect_tree(go, max_depth)
    local out = {}
    local root_tf = self:transform_of(go)
    if root_tf == nil then return out end
    out[1] = { go = go, tf = root_tf, depth = 0 }
    local function walk(tf, depth)
        if depth > (max_depth or 8) or #out >= MAX_SCAN_OBJECTS then return end
        for _, c in ipairs(self:children(tf)) do
            local cgo = self:call(c, "get_GameObject")
            if cgo ~= nil then
                out[#out + 1] = { go = cgo, tf = c, depth = depth }
                walk(c, depth + 1)
            end
        end
    end
    walk(root_tf, 1)
    return out
end

-- Switches off game logic, physics and animation on a spawned puppet (see PUPPET_DISABLE),
-- keeping rendering, sound and effect components. Returns how many were disabled.
function Game:sanitize(tree)
    local disabled = 0
    for _, node in ipairs(tree) do
        for _, comp in ipairs(self:components(node.go)) do
            local tname, td = type_name_of(comp)
            if tname ~= nil and starts_with_any(tname, PUPPET_DISABLE) and not self:mirror_kind_of(td) then
                if pcall(comp.call, comp, "set_Enabled", false) then
                    disabled = disabled + 1
                end
            end
        end
    end
    return disabled
end

function Game:prefab_exists(path)
    local known = self.prefab_exist[path]
    if known ~= nil then return known end
    local ok, exists = pcall(function()
        local pf = sdk.create_instance("via.Prefab", true)
        pf:call("set_Path", path)
        return pf:call("get_Exist") == true
    end)
    known = ok and exists == true
    self.prefab_exist[path] = known
    return known
end

-- Starts loading a prefab; poll prefab_ready, then instantiate.
function Game:load_prefab(path)
    local ok, pf = pcall(function()
        local pf = sdk.create_instance("via.Prefab", true):add_ref()
        pf:call("set_Path", path)
        pf:call("set_Standby", true)
        return pf
    end)
    return ok and pf or nil
end

function Game:prefab_ready(pf)
    if pf == nil then return false end
    local ok, ready = pcall(pf.call, pf, "get_Ready")
    return ok and ready == true
end

function Game:instantiate(pf, pos)
    local ok, go = pcall(pf.call, pf, "instantiate(via.vec3)", Vector3f.new(pos.x, pos.y, pos.z))
    if not ok or go == nil then return nil end
    pcall(function() go = go:add_ref() end)
    return go
end

function Game:release(obj)
    if obj ~= nil then pcall(obj.release, obj) end
end

-- The partner's body prefab from their character id (the body GameObject's name minus
-- "_body", e.g. ch0a0z0 for Leon).
function Game:find_body_prefab(char_id)
    if char_id == nil or char_id == "" or not char_id:match("^[%w_]+$") then return nil end
    for _, prefix in ipairs(CONTENT_PREFIXES) do
        local path = BODY_PREFAB:format(prefix, char_id, char_id)
        if self:prefab_exists(path) then return path end
    end
    return nil
end

-- wp4000 -> _chainsaw/appsystem/prefab/weapon/wp4000.pfb; wp4000_mc -> _mercenaries/...
function Game:find_weapon_prefab(name)
    local base = name:match("^(wp%d%d%d%d)")
    if base == nil or not name:match("^[%w_]+$") then return nil end
    local names = base ~= name and { name, base } or { name }
    for _, n in ipairs(names) do
        for _, prefix in ipairs(CONTENT_PREFIXES) do
            local path = WEAPON_PREFAB:format(prefix, n)
            if self:prefab_exists(path) then return path end
        end
    end
    return nil
end

function Game:muzzle_flash_prefab()
    return self:prefab_exists(MUZZLE_FLASH_PREFAB) and MUZZLE_FLASH_PREFAB or nil
end

-------------------------------------------------------------------------------
-- Player
-------------------------------------------------------------------------------

function Game:player_context()
    local cm = singleton(CHARACTER_MANAGER)
    if cm == nil then return nil end
    return self:call(cm, "getPlayerContextRef")
end

function Game:is_cutscene()
    local gui = singleton(GUI_MANAGER)
    return gui ~= nil and self:call(gui, "get_IsPlayingEvent") == true
end

-- Returns { pos, rot, hp, max_hp, dead, cutscene, aiming, stage } or nil when there is no
-- controllable player (title screen, loading).
function Game:read_player_state()
    local ctx = self:player_context()
    if ctx == nil then
        self:cap("player", false, "no player context (menu/loading?)")
        return nil
    end
    local pos = v3(self:call(ctx, "get_Position"))
    if pos == nil then
        self:cap("player", false, "get_Position failed")
        return nil
    end
    self:cap("player", true, type_name_of(ctx) or "?")

    local st = { pos = pos }
    local body = self:call(ctx, "get_BodyGameObject")
    local transform = body and self:call(body, "get_Transform")
    if transform ~= nil then
        st.rot = q4(self:call(transform, "get_Rotation"))
    end

    local hp = self:call(ctx, "get_HitPoint")
    if hp ~= nil then
        st.hp = tonumber(self:call(hp, "get_CurrentHitPoint")) or 0
        st.max_hp = tonumber(self:call(hp, "get_DefaultHitPoint")) or 0
        st.dead = self:call(hp, "get_IsLive") == false
    end
    st.cutscene = self:is_cutscene()
    st.stage = tonumber(self:call(ctx, "get_CurrentStageID"))
    st.aiming = self:call(ctx, "get_IsHolding") == true
    return st
end

-- Moves an object, also warping its CharacterController so physics does not snap it back.
function Game:warp_game_object(go, pos)
    local transform = self:call(go, "get_Transform")
    if transform == nil then return false, "no transform" end
    local target = Vector3f.new(pos.x, pos.y, pos.z)
    local ok = pcall(function() transform:call("set_Position", target) end)
    if not ok then return false, "set_Position failed" end
    local cc = self:get_component(go, "via.physics.CharacterController")
    if cc ~= nil then
        self:call(cc, "warp")
    end
    return true
end

function Game:teleport_player(pos)
    local ctx = self:player_context()
    local body = ctx and self:call(ctx, "get_BodyGameObject")
    if body == nil then return false, "no player" end
    -- Land slightly behind/above the partner so we do not spawn inside them.
    local ok, err = self:warp_game_object(body, { x = pos.x, y = pos.y + 0.1, z = pos.z - 0.8 })
    self:cap("teleport", ok, ok and "transform + CharacterController.warp" or err)
    return ok, err
end

-------------------------------------------------------------------------------
-- Local avatar capture: what the partner needs to rebuild and animate our character
-------------------------------------------------------------------------------

-- Numbers mirrored components (sound containers, effect providers) per runtime type over
-- `nodes` in order, so the partner can find the matching component on its copy.
function Game:index_mirrors(nodes, ref, out)
    local per_type = {}
    for _, go in ipairs(nodes) do
        for _, comp in ipairs(self:components(go)) do
            local tname, td = type_name_of(comp)
            local kind = tname and self:mirror_kind_of(td)
            if kind ~= nil then
                per_type[tname] = (per_type[tname] or 0) + 1
                local addr = address_of(comp)
                if addr ~= nil and out ~= nil then
                    out[addr] = { part = ref, type_hash = P.hash(tname), idx = per_type[tname] }
                end
            end
        end
    end
    return per_type
end

function Game:mirror_kind_of(td)
    if td == nil then return nil end
    for _, spec in ipairs(MIRRORS) do
        local ok, yes = pcall(td.is_a, td, spec.type)
        if ok and yes then return spec.kind end
    end
    return nil
end

-- Describes the local character: { sig, char_id, body_name, parts, joints } plus private
-- fields used to read the pose. Rescanned every AVATAR_RESCAN seconds (costume changes).
function Game:avatar_descriptor(now)
    now = now or self.clock()
    local ctx = self:player_context()
    local body = ctx and self:call(ctx, "get_BodyGameObject")
    if body == nil then
        self.avatar, self.gear = nil, nil
        return nil
    end
    local a = self.avatar
    if a ~= nil and a.body_addr == address_of(body) and now - a.scanned < AVATAR_RESCAN and self:alive(a.body_tf) then
        return a
    end
    local ok, fresh = pcall(self.scan_avatar, self, ctx, body)
    if not ok or fresh == nil then
        self:cap("avatar", false, ok and "player body has no transform" or tostring(fresh))
        self.avatar = nil
        return nil
    end
    fresh.scanned = now
    if a ~= nil and a.sig == fresh.sig then
        fresh = a -- unchanged: keep the object (and the pose joint list) stable
        fresh.scanned = now
    end
    self.avatar = fresh
    return fresh
end

function Game:scan_avatar(ctx, body)
    local japi = self:joint_api()
    local body_tf = self:transform_of(body)
    if body_tf == nil or japi == nil then return nil end
    local body_name = self:name_of(body)
    local desc = {
        char_id = body_name:match("^(.-)_body$") or body_name, body_name = body_name,
        parts = {}, joints = {}, joint_objs = {}, joint_index = {}, translate = {},
        body = body, body_tf = body_tf, body_addr = address_of(body),
    }
    local comp_ref, go_ref = {}, {}
    local visited = { [desc.body_addr or 0] = true }

    -- Walks a hierarchy: every GameObject with a mesh becomes a part (hidden ones too, so
    -- cutscenes that hide the player do not rebuild the partner's copy); weapons are gear
    -- and skipped. `owner_nodes` collects the non-part objects mirrored as `ref`.
    local scanned = 0
    local function walk(tf, parent_ref, depth, owner_nodes)
        if depth > 8 then return end
        for _, child in ipairs(self:children(tf)) do
            scanned = scanned + 1
            if scanned > MAX_SCAN_OBJECTS then return end
            local go = self:alive(child) and self:call(child, "get_GameObject")
            local addr = go and address_of(go)
            if addr ~= nil and not visited[addr] then
                visited[addr] = true
                local name = self:name_of(go)
                if not name:find(WEAPON_PATTERN) then
                    local mesh, mdf = self:mesh_info(go)
                    if mesh ~= nil and #desc.parts < P.MAX_PARTS then
                        local same = self:call(child, "get_SameJointsConstraint") == true
                        desc.parts[#desc.parts + 1] = {
                            name = name, mesh = mesh, mdf = mdf, parent = parent_ref,
                            flags = same and P.PART_FLAGS.SAME_JOINTS or 0,
                            parent_joint = tostring(self:call(child, "get_ParentJoint") or ""),
                            lpos = v3(self:call(child, "get_LocalPosition")) or { x = 0, y = 0, z = 0 },
                            lrot = q4(self:call(child, "get_LocalRotation")) or { x = 0, y = 0, z = 0, w = 1 },
                            tf = child, go = go,
                        }
                        local ref = #desc.parts
                        go_ref[addr] = ref
                        desc.own_tf[address_of(child) or 0] = true
                        self:index_mirrors({ go }, ref, comp_ref)
                        walk(child, ref, depth + 1, nil)
                    else
                        if owner_nodes then owner_nodes[#owner_nodes + 1] = go end
                        walk(child, parent_ref, depth + 1, owner_nodes)
                    end
                end
            end
        end
    end

    local body_nodes = { body }
    desc.own_tf = { [address_of(body_tf) or 0] = true } -- transforms a weapon may hang from
    local mesh, mdf = self:mesh_info(body)
    if mesh ~= nil then
        -- The body object shows a mesh itself: describe it as the first part.
        desc.parts[1] = { name = body_name, mesh = mesh, mdf = mdf, parent = 0, flags = P.PART_FLAGS.MAIN,
            parent_joint = "", lpos = { x = 0, y = 0, z = 0 }, lrot = { x = 0, y = 0, z = 0, w = 1 },
            tf = body_tf, go = body, on_body = true }
    end
    walk(body_tf, 0, 1, body_nodes)
    go_ref[desc.body_addr] = P.REF.BODY
    self:index_mirrors(body_nodes, P.REF.BODY, comp_ref)

    -- The context's head object is game logic (equipment, voice); its sounds play on the body.
    local head = self:call(ctx, "get_HeadGameObject")
    local head_addr = head and address_of(head)
    if head_addr ~= nil and not visited[head_addr] then
        visited[head_addr] = true
        local head_nodes = { head }
        local head_tf = self:transform_of(head)
        if head_tf ~= nil then walk(head_tf, 0, 1, head_nodes) end
        go_ref[head_addr] = P.REF.HEAD
        self:index_mirrors(head_nodes, P.REF.HEAD, comp_ref)
        desc.head_tf = head_tf
    end

    -- Pose joints: the body skeleton first, then joints only a part has (hair, face).
    local seen = {}
    local function add_joints(tf)
        for _, j in ipairs(self:joint_list(tf)) do
            if #desc.joints >= P.MAX_POSE_JOINTS then return end
            local name = self:joint_name(j)
            if name ~= nil and name ~= "" and not seen[name] then
                seen[name] = true
                local i = #desc.joints + 1
                desc.joints[i] = { hash = P.hash(name), flags = 0, name = name }
                desc.joint_objs[i] = j
                desc.joint_index[name] = i
            end
        end
    end
    add_joints(body_tf)
    local body_joint_count = #desc.joints
    desc.body_joint_count = #self:joint_list(body_tf)
    local main, main_count = nil, -1
    for i, part in ipairs(desc.parts) do
        if not part.on_body then
            local n = #self:joint_list(part.tf)
            if n > main_count then main, main_count = i, n end
            add_joints(part.tf)
        end
    end
    if desc.parts[1] == nil or not desc.parts[1].on_body then
        if main ~= nil then desc.parts[main].flags = desc.parts[main].flags | P.PART_FLAGS.MAIN end
    end
    for i, j in ipairs(desc.joints) do
        local lname = j.name:lower()
        local hint = false
        for _, h in ipairs(TRANSLATE_HINTS) do
            if lname:find(h, 1, true) then hint = true break end
        end
        if (hint or (i <= 3 and i <= math.max(body_joint_count, 1))) and #desc.translate < P.MAX_TRANSLATIONS then
            j.flags = j.flags | P.JOINT_FLAGS.TRANSLATE
            desc.translate[#desc.translate + 1] = i
        end
    end

    local sig = { desc.char_id, body_name, #desc.joints }
    for _, part in ipairs(desc.parts) do
        sig[#sig + 1] = ("%s|%s|%s|%d|%d"):format(part.name, part.mesh, part.mdf, part.parent, part.flags)
    end
    if #desc.joints > 0 then
        sig[#sig + 1] = desc.joints[1].hash
        sig[#sig + 1] = desc.joints[#desc.joints].hash
    end
    desc.sig = table.concat(sig, ";")
    self.avatar_comp_ref = comp_ref
    self.avatar_go_ref = go_ref
    self:cap("avatar", #desc.joints > 0, ("%s: %d parts, %d joints"):format(desc.char_id, #desc.parts, #desc.joints))
    return desc
end

-- The weapons the local character carries: { sig, weapons = { {name, mesh, mdf, flags, joints} } }.
function Game:gear_descriptor(now)
    now = now or self.clock()
    local desc = self.avatar
    if desc == nil then return nil end
    local g = self.gear
    if g ~= nil and now - g.scanned < GEAR_RESCAN then return g end
    local ok, fresh = pcall(self.scan_gear, self, desc, now)
    if not ok or fresh == nil then
        self:cap("gear", false, ok and "no weapons" or tostring(fresh))
        return g
    end
    fresh.scanned = now
    if g ~= nil and g.sig == fresh.sig then
        g.scanned = now
        return g
    end
    self.gear = fresh
    return fresh
end

function Game:scan_gear(desc, now)
    local found, seen = {}, {}
    local function walk(tf, depth)
        for _, child in ipairs(self:children(tf)) do
            local go = self:alive(child) and self:call(child, "get_GameObject")
            if go then
                local name = self:name_of(go)
                if name:find(WEAPON_PATTERN) then
                    if not seen[name] then
                        seen[name] = true
                        found[#found + 1] = { name = name, go = go, tf = child }
                    end
                elseif depth < 8 then
                    walk(child, depth + 1)
                end
            end
        end
    end
    walk(desc.body_tf, 0)
    if desc.head_tf ~= nil then walk(desc.head_tf, 0) end

    if #found == 0 then
        -- Not parented to the player: look the known weapon ids up in the scene, nearby only.
        if self.scene_weapons == nil or now - (self.scene_weapons_at or -math.huge) > SCENE_WEAPON_SEARCH then
            self.scene_weapons_at = now
            self.scene_weapons = {}
            local root = v3(self:call(desc.body_tf, "get_Position"))
            for _, name in ipairs(WEAPON_IDS) do
                local go = root and self:find_game_object(name)
                if go and self:is_claimed(go) then go = nil end
                local tf = go and self:transform_of(go)
                local pos = tf and v3(self:call(tf, "get_Position"))
                if pos ~= nil and dist(pos, root) < 3.0 then
                    self.scene_weapons[#self.scene_weapons + 1] = { name = name, go = go, tf = tf }
                end
            end
        end
        for _, w in ipairs(self.scene_weapons) do
            if self:alive(w.tf) then found[#found + 1] = w end
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)

    local gear = { weapons = {} }
    local comp_ref, gun_slot = {}, {}
    local go_ref = {}
    local sig = {}
    for _, f in ipairs(found) do
        if #gear.weapons >= P.MAX_WEAPONS then break end
        local slot = #gear.weapons + 1
        local tree = self:collect_tree(f.go, 3)
        local mesh, mdf = nil, nil
        local nodes = {}
        for _, node in ipairs(tree) do
            nodes[#nodes + 1] = node.go
            if mesh == nil then mesh, mdf = self:mesh_info(node.go) end
        end
        local joints, joint_objs = {}, {}
        for _, j in ipairs(self:joint_list(f.tf)) do
            if #joints >= P.MAX_WEAPON_JOINTS then break end
            local name = self:joint_name(j)
            if name ~= nil then
                joints[#joints + 1] = P.hash(name)
                joint_objs[#joint_objs + 1] = j
            end
        end
        local ref = P.REF.WEAPON_BASE + slot
        go_ref[address_of(f.go) or 0] = ref
        self:index_mirrors(nodes, ref, comp_ref)
        local gun = self:get_component(f.go, GUN)
        if gun ~= nil then gun_slot[address_of(gun) or 0] = slot end
        gear.weapons[slot] = {
            name = f.name, mesh = mesh or "", mdf = mdf or "", flags = 0, joints = joints,
            go = f.go, tf = f.tf, joint_objs = joint_objs, gun = gun,
        }
        sig[#sig + 1] = ("%s|%s|%d"):format(f.name, mesh or "", #joints)
    end
    gear.sig = table.concat(sig, ";")
    self.gear_comp_ref = comp_ref
    self.gear_go_ref = go_ref
    self.gun_slot = gun_slot
    local names = {}
    for _, w in ipairs(gear.weapons) do names[#names + 1] = w.name end
    self:cap("gear", true, #names > 0 and table.concat(names, ", ") or "no weapon objects found")
    return gear
end

-- Asks for a pose capture at the end of the frame (PrepareRendering), when animation, IK
-- and physics have produced the final pose.
function Game:request_pose()
    self.pose_wanted = true
end

-- PrepareRendering callback.
function Game:capture_pose_late(now)
    self.late_capture_at = now
    if self.pose_wanted then
        self.pose_wanted = false
        self.captured_pose = self:read_pose(now)
    end
end

function Game:take_pose(now)
    local p = self.captured_pose
    self.captured_pose = nil
    if p == nil and (self.late_capture_at == nil or now - self.late_capture_at > 0.5) then
        p = self:read_pose(now) -- PrepareRendering is not reaching us: read in place
        self.pose_wanted = false
    end
    return p
end

-- { time, sig, gear_sig, root_pos, root_rot, flags, q, tpos, weapons } or nil.
function Game:read_pose(now)
    local desc = self.avatar
    local api = self.japi
    if desc == nil or not api or not self:alive(desc.body_tf) then return nil end
    -- Joint objects belong to their transform: never read them after it changed.
    local stale = self:joint_count(desc.body_tf) ~= desc.body_joint_count
    for _, part in ipairs(desc.parts) do
        if stale then break end
        stale = not self:alive(part.tf)
    end
    if stale then
        self.avatar = nil -- rescan next tick
        return nil
    end
    local root_pos, root_rot = self:world_transform(desc.body_tf)
    if root_pos == nil or root_rot == nil then return nil end
    local q = {}
    local get = api.get_lrot
    for i, j in ipairs(desc.joint_objs) do
        local ok, r = pcall(get.call, get, j)
        if not ok or r == nil then
            self.avatar = nil -- the skeleton was rebuilt: rescan next tick
            return nil
        end
        local k = i * 4
        q[k - 3], q[k - 2], q[k - 1], q[k] = r.x, r.y, r.z, r.w
    end
    local tpos = {}
    for _, i in ipairs(desc.translate) do
        local x, y, z = self:get_joint_position(desc.joint_objs[i])
        if x ~= nil then tpos[#tpos + 1] = { index = i, x = x, y = y, z = z } end
    end
    local flags = 0
    if self:is_cutscene() then flags = flags | P.POSE_FLAGS.CUTSCENE end

    local gear = self.gear
    local weapons = {}
    local inv = qconj(root_rot)
    for slot, w in ipairs(gear and gear.weapons or {}) do
        if self:alive(w.tf) then
            local e = { slot = slot, flags = self:is_drawn(w.go) and P.WEAPON_FLAGS.VISIBLE or 0, attach = 0 }
            local joint = tostring(self:call(w.tf, "get_ParentJoint") or "")
            local attach = joint ~= "" and desc.joint_index[joint] or nil
            local parent = attach and self:call(w.tf, "get_Parent")
            if attach ~= nil and parent ~= nil and desc.own_tf[address_of(parent) or 0] then
                -- Glued to one of our joints (the hand): send the offset from that joint.
                e.attach = attach
                e.pos = v3(self:call(w.tf, "get_LocalPosition"))
                e.rot = q4(self:call(w.tf, "get_LocalRotation"))
            else
                local wp, wr = self:world_transform(w.tf)
                if wp ~= nil and wr ~= nil then
                    e.pos = qrot(inv, { x = wp.x - root_pos.x, y = wp.y - root_pos.y, z = wp.z - root_pos.z })
                    e.rot = qmul(inv, wr)
                end
            end
            if e.pos ~= nil and e.rot ~= nil then
                local wq = {}
                for i, j in ipairs(w.joint_objs) do
                    local x, y, z, ww = self:get_joint_rotation(j)
                    local k = i * 4
                    wq[k - 3], wq[k - 2], wq[k - 1], wq[k] = x or 0, y or 0, z or 0, ww or 1
                end
                e.q = wq
                weapons[#weapons + 1] = e
            end
            self:poll_ammo(slot, w)
        end
    end
    return {
        time = now, sig = desc.sig, gear_sig = gear and gear.sig or "",
        root_pos = root_pos, root_rot = root_rot, flags = flags, q = q, tpos = tpos, weapons = weapons,
    }
end

function Game:push_event(ev)
    if #self.events >= MAX_PENDING_EVENTS then
        self.counters.events_dropped = self.counters.events_dropped + 1
        return
    end
    self.events[#self.events + 1] = ev
end

function Game:drain_events()
    local ev = self.events
    if #ev == 0 then return ev end
    self.events = {}
    return ev
end

-- Turns event capture on while a partner is connected (hooks are installed once).
function Game:set_capture(on)
    if on and not self.hooks_installed then
        self:install_hooks()
    end
    if not on and self.capture_enabled then
        self.events = {}
    end
    self.capture_enabled = on and true or false
end

-------------------------------------------------------------------------------
-- Call mirror: sounds and effects
-------------------------------------------------------------------------------

local function describe_method(m, spec)
    local ok, name = pcall(m.get_name, m)
    if not ok or type(name) ~= "string" then return nil end
    local okt, types = pcall(m.get_param_types, m)
    local names, kinds = {}, {}
    for i, t in ipairs(okt and types or {}) do
        local okn, tn = pcall(t.get_full_name, t)
        tn = okn and tn or "?"
        names[i] = tn
        local kind = ARG_KIND[tn]
        if kind == nil then
            local okv, vt = pcall(t.is_value_type, t)
            kind = (okv and vt) and false or ARG_REF
        end
        kinds[i] = kind
    end
    local sig = name .. "(" .. table.concat(names, ", ") .. ")"
    local oks, static = pcall(m.is_static, m)
    return {
        method = m, sig = sig, hash = P.hash(spec.type .. "::" .. sig), kinds = kinds,
        spec = spec, static = oks and static == true,
    }
end

-- Every hookable/replayable sound and effect method, by hash; built once.
function Game:mirror_registry()
    if self.mirror_reg ~= nil then return self.mirror_reg end
    local reg = { by_hash = {}, list = {}, fallback = {} }
    for _, spec in ipairs(MIRRORS) do
        local td = find_type(spec.type)
        local ok, methods = false, nil
        if td ~= nil then ok, methods = pcall(td.get_methods, td) end
        for _, m in ipairs(ok and methods or {}) do
            local okn, name = pcall(m.get_name, m)
            if okn and type(name) == "string" and name:sub(1, #spec.prefix) == spec.prefix then
                local e = describe_method(m, spec)
                if e ~= nil and reg.by_hash[e.hash] == nil then
                    reg.by_hash[e.hash] = e
                    reg.list[#reg.list + 1] = e
                    -- Simplest overload whose arguments we can always make up: replays calls
                    -- whose own arguments could not travel.
                    if spec.fallback and e.kinds[1] == P.ARG.U32 then
                        local simple = true
                        for _, k in ipairs(e.kinds) do
                            if k ~= P.ARG.U32 and k ~= P.ARG.OBJ and k ~= P.ARG.BOOL then simple = false end
                        end
                        local cur = reg.fallback[spec.kind]
                        if simple and (cur == nil or #e.kinds < #cur.kinds) then
                            reg.fallback[spec.kind] = e
                        end
                    end
                end
            end
        end
    end
    self.mirror_reg = reg
    return reg
end

function Game:mirror_kind(method_hash)
    if method_hash == 0 then return "sound" end -- fallback replays are sounds
    local e = self:mirror_registry().by_hash[method_hash]
    return e and e.spec.kind or nil
end

local function hook_int(raw)
    if raw == nil then return 0 end
    local ok, v = pcall(sdk.to_int64, raw)
    return ok and tonumber(v) or 0
end

-- Turns one raw hook argument into something that can travel, or nil.
local function capture_arg(kind, raw, go_ref)
    if kind == P.ARG.U32 then
        return { tag = P.ARG.U32, value = hook_int(raw) & 0xFFFFFFFF }
    elseif kind == P.ARG.I32 then
        local v = hook_int(raw) & 0xFFFFFFFF
        if v >= 0x80000000 then v = v - 0x100000000 end
        return { tag = P.ARG.I32, value = v }
    elseif kind == P.ARG.BOOL then
        return { tag = P.ARG.BOOL, value = (hook_int(raw) & 0xFF) ~= 0 }
    elseif kind == P.ARG.F32 then
        local ok, f = pcall(sdk.to_float, raw)
        return ok and { tag = P.ARG.F32, value = f } or nil
    elseif kind == P.ARG.I64 then
        return { tag = P.ARG.I64, value = hook_int(raw) }
    elseif kind == P.ARG.OBJ then
        local addr = hook_int(raw)
        if addr == 0 then return { tag = P.ARG.NULL } end
        local ref = go_ref(addr)
        return ref and { tag = P.ARG.OBJ, value = ref } or nil
    elseif kind == ARG_REF then
        return hook_int(raw) == 0 and { tag = P.ARG.NULL } or nil
    end
    return nil
end

function Game:local_go_ref(addr)
    local r = self.avatar_go_ref and self.avatar_go_ref[addr]
    if r == nil and self.gear_go_ref then r = self.gear_go_ref[addr] end
    return r
end

-- Pre-hook body for every mirrored method: records calls made on the local player's
-- components. Must stay cheap, it runs for every sound the game plays.
function Game:capture_call(entry, args)
    local this = hook_int(args[2])
    local owner = self.avatar_comp_ref[this] or self.gear_comp_ref[this]
    if owner == nil then return end
    local now = self.clock()
    local budget = self.call_budget
    if now - budget.t >= 1.0 then budget.t, budget.n = now, 0 end
    if budget.n >= MAX_CALLS_PER_SECOND then return end
    budget.n = budget.n + 1

    local base = entry.static and 1 or 2
    local out, first_u32 = {}, nil
    local go_ref = function(addr) return self:local_go_ref(addr) end
    for i, kind in ipairs(entry.kinds) do
        local raw = args[base + i]
        if kind == P.ARG.U32 and first_u32 == nil then first_u32 = hook_int(raw) & 0xFFFFFFFF end
        if out ~= nil then
            local a = capture_arg(kind, raw, go_ref)
            if a == nil then out = nil else out[i] = a end
        end
    end
    local ev = { kind = P.EVENT.CALL, time = now, part = owner.part, comp_type = owner.type_hash, comp_idx = owner.idx }
    if out ~= nil then
        ev.method, ev.args = entry.hash, out
        self.counters.calls = self.counters.calls + 1
    elseif entry.spec.fallback and first_u32 ~= nil then
        ev.method, ev.args = 0, { { tag = P.ARG.U32, value = first_u32 } }
        self.counters.calls_fallback = self.counters.calls_fallback + 1
    else
        self.counters.calls_skipped = self.counters.calls_skipped + 1
        return
    end
    self:push_event(ev)
end

function Game:on_shot(args)
    if not self.capture_enabled then return end
    local slot = self.gun_slot[hook_int(args[2])]
    if slot == nil then return end
    local now = self.clock()
    -- One trigger pull may run several shoot methods (pellets, helpers): one event per frame.
    if now - (self.last_shot[slot] or -math.huge) < 0.03 then return end
    self.last_shot[slot] = now
    self.counters.shots = self.counters.shots + 1
    self:push_event({ kind = P.EVENT.SHOT, time = now, slot = slot })
end

-- Fallback shot detection when no shoot method could be hooked: the magazine count drops.
function Game:poll_ammo(slot, w)
    if self.shot_hooked or self.ammo_getter == nil or w.gun == nil or not self.capture_enabled then return end
    local n = tonumber(self:call(w.gun, self.ammo_getter))
    local key = address_of(w.gun)
    if n == nil or key == nil then return end
    local prev = self.ammo_seen[key]
    self.ammo_seen[key] = n
    if prev ~= nil and n < prev then
        local now = self.clock()
        for _ = 1, math.min(prev - n, 3) do
            self.counters.shots = self.counters.shots + 1
            self:push_event({ kind = P.EVENT.SHOT, time = now, slot = slot })
        end
    end
end

function Game:install_hooks()
    self.hooks_installed = true
    if sdk.hook == nil then
        self:cap("sound_mirror", false, "sdk.hook unavailable (update REFramework)")
        return
    end
    local reg = self:mirror_registry()
    local hooked = { sound = 0, effect = 0 }
    for _, entry in ipairs(reg.list) do
        local ok = pcall(sdk.hook, entry.method, function(args)
            if self.capture_enabled then
                pcall(self.capture_call, self, entry, args)
            end
        end, function(retval) return retval end)
        if ok then hooked[entry.spec.kind] = hooked[entry.spec.kind] + 1 end
    end
    self:cap("sound_mirror", hooked.sound > 0, ("%d WwiseContainer.trigger overloads hooked%s"):format(
        hooked.sound, reg.fallback.sound and (", replay fallback " .. reg.fallback.sound.sig) or ""))
    self:cap("effect_mirror", hooked.effect > 0, ("%d EPVStandard.requestEffect overloads hooked"):format(hooked.effect))

    local gun_td = find_type(GUN)
    local names = {}
    if gun_td ~= nil then
        for _, name in ipairs(SHOOT_METHODS) do
            local m = gun_td:get_method(name)
            if m ~= nil and pcall(sdk.hook, m, function(args)
                pcall(self.on_shot, self, args)
            end, function(retval) return retval end) then
                names[#names + 1] = name
            end
        end
        if #names == 0 then
            for _, g in ipairs(AMMO_GETTERS) do
                if gun_td:get_method(g) ~= nil then
                    self.ammo_getter = g
                    break
                end
            end
        end
    end
    self.shot_hooked = #names > 0
    self:cap("shots", self.shot_hooked or self.ammo_getter ~= nil,
        self.shot_hooked and (GUN .. "." .. table.concat(names, "/"))
        or (self.ammo_getter and ("ammo count polling (" .. self.ammo_getter .. ")"))
        or (gun_td and "no shoot method or ammo getter found" or (GUN .. " not found")))
end

-- Replays a captured call on `comp` (a component of the partner's model). resolve(ref)
-- maps object references to the model's GameObjects.
function Game:replay_call(comp, ev, resolve)
    local reg = self:mirror_registry()
    local entry = reg.by_hash[ev.method]
    local vals, n = {}, 0
    if entry ~= nil then
        n = #entry.kinds
        for i = 1, n do
            local a = ev.args[i]
            if a == nil or a.tag == P.ARG.NULL then
                vals[i] = nil
            elseif a.tag == P.ARG.OBJ then
                vals[i] = resolve(a.value)
            else
                vals[i] = a.value
            end
        end
    else
        entry = reg.fallback.sound
        local id = ev.args and ev.args[1] and ev.args[1].value
        if entry == nil or id == nil then return false end
        local owner = self:call(comp, "get_GameObject")
        local used_id = false
        n = #entry.kinds
        for i, k in ipairs(entry.kinds) do
            if k == P.ARG.U32 then
                vals[i] = used_id and 0 or id
                used_id = true
            elseif k == P.ARG.OBJ then
                vals[i] = owner
            else
                vals[i] = false
            end
        end
    end
    local m = entry.method
    return (pcall(m.call, m, comp, table.unpack(vals, 1, n)))
end

-------------------------------------------------------------------------------
-- Enemies
-------------------------------------------------------------------------------

function Game:list_enemies()
    local cm = singleton(CHARACTER_MANAGER)
    if cm == nil then return nil end
    local list = self:call(cm, "get_EnemyContextList")
    if list == nil then
        self:cap("enemy_list", false, "get_EnemyContextList failed")
        return nil
    end
    local count = tonumber(self:call(list, "get_Count")) or 0
    self:cap("enemy_list", true, ("%d enemy contexts"):format(count))

    local out, ctx_by_id, ids = {}, {}, {}
    local old_ids = self.enemy_context_ids or {}
    local with_id = 0
    for i = 0, count - 1 do
        local ctx = self:call(list, "get_Item", i)
        if ctx ~= nil then
            local pos = v3(self:call(ctx, "get_Position"))
            local hp = self:call(ctx, "get_HitPoint")
            if pos ~= nil and hp ~= nil then
                local id = ctx:get_address()
                ctx_by_id[id] = ctx
                -- A context's spawner never changes, so read it once per context. A spawner
                -- with a runtime ID (P.ctx_is_runtime) is no use across machines.
                local cid = old_ids[id]
                if cid == nil then
                    cid = self:read_spawner_id(ctx) or false
                    if cid and P.ctx_is_runtime(cid) then cid = false end
                end
                ids[id] = cid
                if cid then with_id = with_id + 1 end
                out[#out + 1] = {
                    id = id,
                    kind = type_name_of(ctx) or "unknown",
                    ctx = cid or nil,
                    pos = pos,
                    yaw = 0,
                    hp = tonumber(self:call(hp, "get_CurrentHitPoint")) or 0,
                    max_hp = tonumber(self:call(hp, "get_DefaultHitPoint")) or 0,
                    alive = self:call(hp, "get_IsLive") ~= false,
                }
            end
        end
    end
    self.enemy_ctx = ctx_by_id
    self.enemy_context_ids = ids
    if #out > 0 then
        self:cap("enemy_spawner_id", with_id > 0, ("%d of %d enemies have a level SpawnerID"):format(with_id, #out))
    end
    return out
end

-- Applies one writer and reports whether get_CurrentHitPoint now reads the written value.
function Game:try_hp_writer(w, hp_obj, value)
    local v = w.int and math.floor(value + 0.5) or value
    local ok
    if w.kind == "method" then
        ok = pcall(w.method.call, w.method, hp_obj, v)
    else
        ok = pcall(function() hp_obj:set_field(w.name, v) end)
    end
    if not ok then return false end
    local after = tonumber(self:call(hp_obj, "get_CurrentHitPoint"))
    return after ~= nil and math.abs(after - v) <= 0.5
end

-- Sets current HP, trusting only a writer whose effect was confirmed by reading HP back.
function Game:write_hp(hp_obj, value)
    local before = tonumber(self:call(hp_obj, "get_CurrentHitPoint"))
    if before ~= nil and math.abs(before - value) <= 0.5 then
        return true -- nothing to change (and nothing to learn: a no-op would "verify")
    end
    if self.hp_writer ~= nil then
        if self:try_hp_writer(self.hp_writer, hp_obj, value) then
            return true
        end
        self.hp_writer_fails = self.hp_writer_fails + 1
        self:report_hp_writer()
        return false
    end
    local all_rejected = #self.hp_candidates > 0
    for _, w in ipairs(self.hp_candidates) do
        if not w.rejected then all_rejected = false end
    end
    if all_rejected then
        self.hp_writes_since_reject = self.hp_writes_since_reject + 1
        if self.hp_writes_since_reject < HP_RETRY_AFTER_WRITES then
            return false
        end
        self.hp_writes_since_reject = 0
        for _, w in ipairs(self.hp_candidates) do
            w.rejected, w.tries = false, 0
        end
    end
    for _, w in ipairs(self.hp_candidates) do
        if not w.rejected then
            if self:try_hp_writer(w, hp_obj, value) then
                self.hp_writer = w
                self:report_hp_writer()
                return true
            end
            w.tries = w.tries + 1
            if w.tries >= HP_CANDIDATE_TRIES then
                w.rejected = true
                self:report_hp_writer()
            end
        end
    end
    return false
end

function Game:enemy_set_hp(id, value)
    local ctx = self.enemy_ctx[id]
    local hp = ctx and self:call(ctx, "get_HitPoint")
    if hp == nil then return false end
    return self:write_hp(hp, math.max(1, value))
end

function Game:enemy_kill(id)
    local ctx = self.enemy_ctx[id]
    local hp = ctx and self:call(ctx, "get_HitPoint")
    if hp == nil then return false end
    if self.kill_method ~= nil then
        local m = self:method(hp, self.kill_method)
        if m ~= nil and pcall(m.call, m, hp) then return true end
    end
    return self:write_hp(hp, 0)
end

function Game:enemy_set_position(id, pos)
    local ctx = self.enemy_ctx[id]
    local body = ctx and self:call(ctx, "get_BodyGameObject")
    if body == nil then return false end
    return (self:warp_game_object(body, pos))
end

-------------------------------------------------------------------------------
-- Pickups (chainsaw.DropItem: world items, key items and enemy drops)
-------------------------------------------------------------------------------

function Game.is_key_item(item_id)
    return item_id ~= nil and item_id >= KEY_ITEM_MIN and item_id <= KEY_ITEM_MAX
end

function Game:current_scene()
    return self:scene()
end

local function array_elements(arr)
    local out = {}
    if arr == nil then return out end
    local ok, n = pcall(function() return arr:get_size() end)
    if not ok or n == nil then return out end
    for i = 0, n - 1 do
        local okE, e = pcall(function() return arr:get_element(i) end)
        if okE and e ~= nil then out[#out + 1] = e end
    end
    return out
end

-- Every component of a type in the loaded scene (via.Scene.findComponents), or nil, reason.
function Game:find_components(type_name)
    local scene = self:current_scene()
    if scene == nil then return nil, "no current scene" end
    local t = self:typeof(type_name)
    if not t then return nil, type_name .. " type not found" end
    local ok, comps = pcall(function() return scene:call("findComponents(System.Type)", t) end)
    if not ok or comps == nil then return nil, "findComponents(" .. type_name .. ") failed" end
    return array_elements(comps)
end

-- Every chainsaw.DropItem in the loaded scene:
-- { {id, item_id, count, pos, ctx}, ... }. Field names (_ID, _ItemData.ItemID/Count) come
-- from the RE4 RSZ schema; the scene search is the engine's via.Scene.findComponents.
function Game:list_pickups()
    local comps, why = self:find_components("chainsaw.DropItem")
    if comps == nil then
        self:cap("pickups", false, why)
        return nil
    end

    local out, go_by_id, comp_by_id, unreadable = {}, {}, {}, 0
    for _, comp in ipairs(comps) do
        local go = self:call(comp, "get_GameObject")
        local transform = go and self:call(go, "get_Transform")
        local pos = transform and v3(self:call(transform, "get_Position"))
        local data = read_field(comp, "_ItemData")
        local item_id = data and tonumber(read_field(data, "ItemID"))
        if item_id == 0 then
            -- Level-placed items showed ItemID 0 in their save data; ask the item itself.
            item_id = tonumber(self:call(comp, "getItemID")) or 0
        end
        if go ~= nil and pos ~= nil and item_id ~= nil then
            local id = comp:get_address()
            go_by_id[id] = go
            comp_by_id[id] = comp
            out[#out + 1] = {
                id = id,
                item_id = item_id,
                count = tonumber(read_field(data, "Count")) or 0,
                pos = pos,
                ctx = self:read_context_id(comp),
            }
        else
            unreadable = unreadable + 1
        end
    end
    self.pickup_objects = go_by_id
    self.pickup_comps = comp_by_id
    self:cap("pickups", #out > 0 or unreadable == 0,
        ("%d drop items readable, %d unreadable"):format(#out, unreadable))
    return out
end

-- The game's own pickup callbacks: static chainsaw.DropItem.onAcceptPickup(user_id, item_id)
-- and onAcceptOccupied(user_id, item_id, arg). REFramework passes a static method's
-- parameters from args[2] on (args[1] is the VM context). The hook only records the item's
-- ContextID; items_sync counts a key item as taken when a callback named it AND it left the
-- scene, which is exact where the vanish heuristic can only guess.
local PICKUP_CALLBACKS = { "onAcceptPickup", "onAcceptOccupied" }
local MAX_PICKUP_EVENTS = 64

function Game:install_pickup_hooks()
    self.pickup_hooks = 0
    self.pickup_hook_calls = 0
    self.recent_pickup_events = {}
    if type(sdk) ~= "table" or type(sdk.hook) ~= "function" or type(sdk.to_managed_object) ~= "function" then
        self:cap("pickup_hook", false, "sdk.hook unavailable")
        return
    end
    local td = find_type("chainsaw.DropItem")
    local events = self.pickup_events
    local game = self
    local function record(args, name)
        game.pickup_hook_calls = game.pickup_hook_calls + 1
        if #events >= MAX_PICKUP_EVENTS then return end
        local okI, item = pcall(sdk.to_managed_object, args[3])
        local key = okI and item ~= nil and P.ctx_key(context_id_table(item)) or nil
        if key == nil then return end
        local okU, user = pcall(sdk.to_managed_object, args[2])
        local ev = {
            key = key,
            user = okU and user ~= nil and P.ctx_key(context_id_table(user)) or nil,
            via = name,
        }
        events[#events + 1] = ev
        local recent = game.recent_pickup_events -- kept for the research log
        recent[#recent + 1] = ev
        if #recent > 8 then table.remove(recent, 1) end
    end
    local hooked = {}
    for _, name in ipairs(PICKUP_CALLBACKS) do
        local okM, m = pcall(function() return td and td:get_method(name) end)
        if okM and m ~= nil then
            local ok = pcall(sdk.hook, m, function(args) pcall(record, args, name) end,
                function(retval) return retval end)
            if ok then hooked[#hooked + 1] = name end
        end
    end
    self.pickup_hooks = #hooked
    self:cap("pickup_hook", #hooked > 0, #hooked > 0 and ("DropItem." .. table.concat(hooked, ", "))
        or "DropItem pickup callbacks not found")
end

-- Pickup callbacks since the last call: { {key=<ctx key>, user=<ctx key>, via=<name>}, ... },
-- or nil when no hook is installed.
function Game:take_pickup_events()
    if (self.pickup_hooks or 0) == 0 then return nil end
    local out = {}
    for i, e in ipairs(self.pickup_events) do out[i] = e end
    for i = #self.pickup_events, 1, -1 do self.pickup_events[i] = nil end
    return out
end

-- Removes a pickup found by the last list_pickups() (its partner took it).
function Game:remove_pickup(id)
    local go = self.pickup_objects and self.pickup_objects[id]
    if go == nil then return false end
    local ok = pcall(function() go:call("destroy", go) end)
    if ok then self.pickup_objects[id] = nil end
    return ok
end

-- Virtual-key state through REFramework (works with the menu closed).
function Game:is_key_down(vk)
    local ok, down = pcall(function() return reframework:is_key_down(vk) end)
    return ok and down == true
end

-------------------------------------------------------------------------------
-- World info
-------------------------------------------------------------------------------

-- Best-effort chapter/area label, used only to warn when partners are in different places.
function Game:area_name()
    if self.area_probe == false then return nil end
    if self.area_probe == nil then
        for _, probe in ipairs(AREA_PROBES) do
            local s = singleton(probe[1])
            if s ~= nil then
                for _, getter in ipairs(probe[2]) do
                    if self:method(s, getter) ~= nil then
                        self.area_probe = { probe[1], getter }
                        break
                    end
                end
            end
            if self.area_probe then break end
        end
        if self.area_probe == nil then
            -- Singletons appear only in-game; retry later, but stop after a while in game.
            self.area_probe_attempts = (self.area_probe_attempts or 0) + 1
            if self.area_probe_attempts > 600 and self:player_context() ~= nil then
                self.area_probe = false
                self:cap("area", false, "no chapter getter found")
            end
            return nil
        end
        self:cap("area", true, self.area_probe[1] .. "." .. self.area_probe[2])
    end
    local s = singleton(self.area_probe[1])
    local v = s and self:call(s, self.area_probe[2])
    if v == nil then return nil end
    return tostring(v)
end

-------------------------------------------------------------------------------
-- Drawing (only valid inside re.on_frame)
-------------------------------------------------------------------------------

function Game:world_to_screen(p)
    local ok, s = pcall(draw.world_to_screen, Vector3f.new(p.x, p.y, p.z))
    if ok and s ~= nil then
        return s.x, s.y
    end
    return nil
end

function Game:draw_line(x1, y1, x2, y2, color)
    draw.line(x1, y1, x2, y2, color)
end

function Game:draw_text(text, x, y, color)
    draw.text(text, x + 1, y + 1, 0xFF000000)
    draw.text(text, x, y, color)
end

function Game:draw_rect(x, y, w, h, color)
    draw.filled_rect(x, y, w, h, color)
end

function Game:draw_circle(x, y, r, color)
    draw.outline_circle(x, y, r, color, 16)
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

-- Types needed for the next sync features (enemy targeting/animation, drops, pickups, story
-- progress). Every name exists in the RE4 RSZ schema; the dump adds what the schema lacks:
-- method signatures.
local DUMP_TYPES = {
    CHARACTER_MANAGER, GUI_MANAGER, HIT_POINT, "chainsaw.CharacterContext", "chainsaw.EnemyBaseContext",
    "chainsaw.PlayerBaseContext", "chainsaw.PartnerBaseContext", "chainsaw.EnemyManager", "chainsaw.ContextID",
    "chainsaw.HateController", "chainsaw.HateTargetInfo", "chainsaw.HateControllerUserData",
    "chainsaw.EnemyAttackPermitManager", "chainsaw.PartnerAttackTargetSelector",
    "chainsaw.DropItemManager", "chainsaw.DropItemManager.GenerateItemOption", "chainsaw.DropItem",
    "chainsaw.DropItemContext", "chainsaw.RandomDrop", "chainsaw.RandomDrop.ItemResult", "chainsaw.Item",
    "chainsaw.GmOptionDropItem", "chainsaw.GmOptionGenerateDropItem",
    "chainsaw.InteractGetPickupItem", "chainsaw.InteractManager", "chainsaw.InventoryManager",
    "chainsaw.ItemManager", "chainsaw.ItemDefinitionManager", "chainsaw.GmKeyItemCase", "chainsaw.GmUseItemGate",
    "chainsaw.ScenarioFlagManager", "chainsaw.ChapterSceneManager", "chainsaw.LocationSceneManager",
    "chainsaw.CampaignManager", "chainsaw.GameSituationManager", "chainsaw.GimmickManager", "chainsaw.StageIdentifier",
    "chainsaw.CharacterSpawnController", "chainsaw.SpawnController", "chainsaw.PartnerNpcSpawnParam",
    "chainsaw.CharacterSpawnParam", "chainsaw.HitController", "chainsaw.HitController.DamageInfo",
    "chainsaw.CharacterDamageInfo", "chainsaw.MotionController", "chainsaw.AnimationController",
    "chainsaw.TargetSensor", "chainsaw.TargetMarker", "chainsaw.StayAreaController",
    "via.motion.Motion", "via.motion.TreeLayer", "via.motion.MotionFsm2", "via.behaviortree.BehaviorTree",
    "via.physics.CharacterController",
    GUN, "chainsaw.GameStatusManager", "chainsaw.LevelManager", "chainsaw.MapManager",
    "via.wwise.WwiseContainer", "via.effect.script.EPVStandard", "via.Prefab", "via.Joint", "via.render.Mesh",
}

-- Enums whose values the next features need (spawning a partner character that enemies can
-- target, targeting, drops, chapters). Values come from the enum's static literal fields.
local DUMP_ENUMS = {
    "chainsaw.CharacterKindID", "chainsaw.CharacterUsePurposeFlag", "chainsaw.ChapterID",
    "chainsaw.CharacterControlIndex", "chainsaw.character.PauseLayer",
    "chainsaw.HateTargetInfo.FindSourceType", "chainsaw.HateTargetInfo.FindStateType",
    "chainsaw.ContextID.EntityCategory", "chainsaw.RandomDrop.DropType", "chainsaw.CampaignManager.Difficulty",
    "chainsaw.CharacterManager.PlayerKind", "chainsaw.CharacterManager.PlayerNo", "chainsaw.StageID",
}
local ENUM_MAX_VALUES = 4000

local SINGLETONS_TO_CHECK = {
    CHARACTER_MANAGER, GUI_MANAGER, "chainsaw.EnemyManager", "chainsaw.DropItemManager", "chainsaw.InteractManager",
    "chainsaw.InventoryManager", "chainsaw.ItemManager", "chainsaw.ScenarioFlagManager",
    "chainsaw.ChapterSceneManager", "chainsaw.LocationSceneManager", "chainsaw.CampaignManager",
    "chainsaw.GameSituationManager", "chainsaw.GimmickManager", "chainsaw.EnemyAttackPermitManager",
}

-- The type dump is rewritten on every click but keeps every type described by earlier runs
-- (enemy and component types differ per area). Each click also appends a compact snapshot
-- of the live game to the research log, so runs in different areas all survive.
local TYPEDUMP_FILE = "re4coop_typedump.json"
local RESEARCH_LOG_FILE = "re4coop_research_log.json"
local RESEARCH_LOG_MAX = 60
local MAX_AREAS_SEEN = 200

local function method_signature(m)
    local okName, name = pcall(m.get_name, m)
    if not okName or name == nil then name = "?" end
    local params = {}
    local okT, types = pcall(m.get_param_types, m)
    local okN, pnames = pcall(m.get_param_names, m)
    for i, t in ipairs(okT and types or {}) do
        local okF, tname = pcall(t.get_full_name, t)
        local pname = okN and pnames and pnames[i] or ("p" .. i)
        params[i] = tostring(pname) .. ": " .. (okF and tname or "?")
    end
    local ret = "void"
    pcall(function() ret = m:get_return_type():get_full_name() end)
    local static = false
    pcall(function() static = m:is_static() end)
    return (static and "static " or "") .. ret .. " " .. name .. "(" .. table.concat(params, ", ") .. ")"
end

local function describe_type(td, depth)
    local out = { name = td:get_full_name(), methods = {}, fields = {} }
    local ok_m, methods = pcall(td.get_methods, td)
    for _, m in ipairs(ok_m and methods or {}) do
        out.methods[#out.methods + 1] = method_signature(m)
    end
    local ok_f, fields = pcall(td.get_fields, td)
    for _, f in ipairs(ok_f and fields or {}) do
        local okn, n = pcall(f.get_name, f)
        if okn then
            out.fields[#out.fields + 1] = (field_is_static(f) and "static " or "") .. (field_type_name(f) or "?") .. " " .. n
        end
    end
    local okp, parent = pcall(td.get_parent_type, td)
    if okp and parent ~= nil and depth < 6 and parent:get_full_name() ~= "System.Object" then
        out.parent = describe_type(parent, depth + 1)
    end
    return out
end

-- name -> value for an enum's literals.
local function enum_values(td)
    local out, n = {}, 0
    local ok, fields = pcall(td.get_fields, td)
    for _, f in ipairs(ok and fields or {}) do
        if field_is_static(f) then
            local okN, name = pcall(f.get_name, f)
            local okV, v = pcall(f.get_data, f, nil)
            if okN and name ~= nil and okV and v ~= nil then
                out[name] = type(v) == "number" and v or tostring(v)
                n = n + 1
                if n >= ENUM_MAX_VALUES then
                    out["(truncated)"] = true
                    break
                end
            end
        end
    end
    return out
end

-- A JSON-safe summary of one value read from the game.
local function plain_value(v)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    elseif t == "boolean" or t == "string" or v == nil then
        return v
    end
    local name = type_name_of(v)
    if name == "via.GameObject" then
        local ok, n = pcall(function() return v:call("get_Name") end)
        return "GameObject " .. tostring(ok and n or "?")
    elseif name == "chainsaw.ContextID" then
        return "ContextID " .. tostring(P.ctx_key(context_id_table(v)))
    end
    local okX, x = pcall(function() return v.x end)
    if okX and type(x) == "number" then
        local _, y = pcall(function() return v.y end)
        local _, z = pcall(function() return v.z end)
        return { x = x, y = type(y) == "number" and y or 0, z = type(z) == "number" and z or 0 }
    end
    return name or tostring(v)
end

-- Instance field values of an object (own type and parents), for structures whose meaning
-- is not known yet (HateTargetInfo, StageIdentifier, ...).
local function snapshot_fields(obj, max_fields)
    local out, n = {}, 0
    local _, td = type_name_of(obj)
    for _, t in ipairs(td and type_hierarchy(td, 4) or {}) do
        local ok, fields = pcall(t.get_fields, t)
        for _, f in ipairs(ok and fields or {}) do
            local okN, name = pcall(f.get_name, f)
            if okN and name ~= nil and out[name] == nil and not field_is_static(f) then
                local okV, v = pcall(function() return obj:get_field(name) end)
                if okV then
                    local pv = plain_value(v)
                    if pv == nil then pv = "nil" end
                    out[name] = pv
                else
                    out[name] = "?"
                end
                n = n + 1
                if n >= max_fields then return out end
            end
        end
    end
    return out
end

local function round_pos(p)
    if p == nil then return nil end
    local function r(v) return math.floor(v * 100 + 0.5) / 100 end
    return { x = r(p.x), y = r(p.y), z = r(p.z) }
end

-- Type names of every component on a GameObject (what drives an enemy, a pickup, ...).
function Game:component_names(go)
    if go == nil then return nil end
    local ok, arr = pcall(sdk.call_object_func, go, "get_Components")
    if not ok then return nil end
    local out = {}
    for _, c in ipairs(array_elements(arr)) do
        out[#out + 1] = type_name_of(c) or "?"
    end
    return out
end

-- Identity, stage and state of one character context.
function Game:character_sample(ctx)
    local body = self:call(ctx, "get_BodyGameObject")
    local hp = self:call(ctx, "get_HitPoint")
    local spawner = self:read_spawner_id(ctx)
    return {
        type = type_name_of(ctx),
        kind_id = plain_value(self:call(ctx, "get_KindID")),
        id = P.ctx_key(self:read_context_id(ctx)),
        spawner = P.ctx_key(spawner),
        spawner_runtime = P.ctx_is_runtime(spawner),
        stage = plain_value(self:call(ctx, "get_CurrentStageID")),
        pos = round_pos(v3(self:call(ctx, "get_Position"))),
        hp = hp and tonumber(self:call(hp, "get_CurrentHitPoint")) or nil,
        max_hp = hp and tonumber(self:call(hp, "get_DefaultHitPoint")) or nil,
        body = body and plain_value(body) or nil,
    }
end

-- Motion layer 0 of a character (what animation is playing), for animation sync.
function Game:motion_sample(ctx)
    local body = self:call(ctx, "get_BodyGameObject")
    local motion = body and self:get_component(body, "via.motion.Motion")
    if motion == nil then return nil end
    local layer = self:call(motion, "getLayer", 0)
    return {
        layers = tonumber(self:call(motion, "getLayerCount")),
        bank = layer and tonumber(self:call(layer, "get_MotionBankID")) or nil,
        motion = layer and tonumber(self:call(layer, "get_MotionID")) or nil,
        frame = layer and tonumber(self:call(layer, "get_Frame")) or nil,
    }
end

-- One compact snapshot of the live game for the research log.
function Game:research_snapshot(extra)
    local snap = { enemies = {}, pickups = {}, hate = {} }
    local okT, t = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ")
    snap.time = okT and t or nil
    snap.chapter = self:area_name()
    local campaign = singleton("chainsaw.CampaignManager")
    if campaign ~= nil then
        snap.difficulty = plain_value(self:call(campaign, "get_CurrentDifficulty"))
        local sid = self:call(campaign, "get_CurrentStageIdentifier")
        if sid ~= nil then snap.stage_identifier = snapshot_fields(sid, 16) end
    end

    local player = self:player_context()
    if player ~= nil then
        snap.player = self:character_sample(player)
        snap.player.motion = self:motion_sample(player)
    end
    local cm = singleton(CHARACTER_MANAGER)
    local partner = cm and self:call(cm, "getPartnerContextRef")
    if partner ~= nil then
        snap.partner = self:character_sample(partner)
        snap.partner.components = self:component_names(self:call(partner, "get_BodyGameObject"))
    end

    local enemies = self:list_enemies() or {}
    for i, e in ipairs(enemies) do
        if i > 30 then break end
        local ctx = self.enemy_ctx[e.id]
        local sample = ctx and self:character_sample(ctx) or { type = e.kind }
        sample.alive = e.alive
        sample.find_state = ctx and plain_value(self:call(ctx, "get_TargetFindState")) or nil
        sample.find_source = ctx and plain_value(self:call(ctx, "get_TargetFindSource")) or nil
        if i == 1 and ctx ~= nil then sample.motion = self:motion_sample(ctx) end
        snap.enemies[i] = sample
    end

    -- HateController is not on an enemy's body GameObject: find where it lives.
    for i, hc in ipairs(self:find_components("chainsaw.HateController") or {}) do
        if i > 8 then break end
        local go = self:call(hc, "get_GameObject")
        local transform = go and self:call(go, "get_Transform")
        local target = self:call(hc, "get_CurrentTarget")
        snap.hate[i] = {
            game_object = go and plain_value(go) or nil,
            pos = transform and round_pos(v3(self:call(transform, "get_Position"))) or nil,
            find_state = plain_value(self:call(hc, "get_FindState")),
            total_attention = plain_value(self:call(hc, "get_TotalAttention")),
            current_target = target and snapshot_fields(target, 16) or nil,
        }
    end

    for i, p in ipairs(self:list_pickups() or {}) do
        if i > 40 then break end
        local comp = self.pickup_comps and self.pickup_comps[p.id]
        local data = comp and read_field(comp, "_ItemData")
        snap.pickups[i] = {
            item_id = p.item_id,
            save_item_id = data and tonumber(read_field(data, "ItemID")) or nil,
            count = p.count,
            key_item = Game.is_key_item(p.item_id),
            id = P.ctx_key(p.ctx),
            pos = round_pos(p.pos),
            stage = comp and plain_value(self:call(comp, "getStage")) or nil,
            lost = comp and plain_value(read_field(comp, "_IsLostItem")) or nil,
        }
    end

    snap.pickup_hook = {
        hooks = self.pickup_hooks or 0,
        calls = self.pickup_hook_calls or 0,
        player_id = player and P.ctx_key(self:read_context_id(player)) or nil,
        recent = self.recent_pickup_events,
    }
    snap.hp_writer = self.hp_writer and self.hp_writer.label or nil
    if extra ~= nil then snap.session = extra end
    return snap
end

local function load_json(name)
    local ok, t = pcall(json.load_file, name)
    if ok and type(t) == "table" then return t end
    return nil
end

-- The local character as the mod sees it: objects, components, meshes, joints.
function Game:describe_player()
    local ctx = self:player_context()
    local body = ctx and self:call(ctx, "get_BodyGameObject")
    if body == nil then return "no player" end
    local out = { objects = {} }
    local roots = { body }
    local head = self:call(ctx, "get_HeadGameObject")
    if head ~= nil then roots[2] = head end
    for _, root in ipairs(roots) do
        for _, node in ipairs(self:collect_tree(root, 4)) do
            local comps = {}
            for _, c in ipairs(self:components(node.go)) do comps[#comps + 1] = type_name_of(c) or "?" end
            local mesh, mdf = self:mesh_info(node.go)
            out.objects[#out.objects + 1] = {
                name = self:name_of(node.go), depth = node.depth, components = comps, mesh = mesh, mdf = mdf,
                parent_joint = tostring(self:call(node.tf, "get_ParentJoint") or ""),
                same_joints = self:call(node.tf, "get_SameJointsConstraint"),
                joints = #self:joint_list(node.tf),
            }
        end
    end
    local desc = self.avatar
    if desc ~= nil then
        out.pose_joints = {}
        for i, j in ipairs(desc.joints) do
            if i > 400 then break end
            out.pose_joints[i] = j.name
        end
    end
    return out
end

-- Writes reframework/data/re4coop_typedump.json (signatures, enum values, capabilities, the
-- latest live sample, the local character's objects, meshes and joints) and appends to
-- reframework/data/re4coop_research_log.json. `extra` is the session's sync state (and the
-- partner model's status). Returns ok, number of runs so far.
function Game:dump_types(extra)
    local names, seen = {}, {}
    local function want(n)
        if n and not seen[n] then
            seen[n] = true
            names[#names + 1] = n
        end
    end
    for _, n in ipairs(DUMP_TYPES) do want(n) end

    local live = { singletons = {}, hp_writers = {} }
    for _, n in ipairs(SINGLETONS_TO_CHECK) do
        live.singletons[n] = singleton(n) ~= nil
    end
    for _, w in ipairs(self.hp_candidates or {}) do
        live.hp_writers[#live.hp_writers + 1] = w.label .. (w == self.hp_writer and " [verified]" or "")
            .. (w.rejected and " [rejected]" or "")
    end

    local ctx = self:player_context()
    if ctx ~= nil then
        want(type_name_of(ctx))
        live.player_context = type_name_of(ctx)
        live.player_components = self:component_names(self:call(ctx, "get_BodyGameObject"))
    end

    local enemies = self:list_enemies() or {}
    live.enemies = {}
    for i, e in ipairs(enemies) do
        if i > 12 then break end
        live.enemies[i] = { kind = e.kind, hp = e.hp, max_hp = e.max_hp, alive = e.alive, spawner_id = e.ctx }
        want(e.kind)
    end
    local first = enemies[1] and self.enemy_ctx[enemies[1].id]
    if first ~= nil then
        live.enemy_components = self:component_names(self:call(first, "get_BodyGameObject"))
        for _, c in ipairs(live.enemy_components or {}) do
            if c:find("Hate", 1, true) or c:find("Behavior", 1, true) or c:find("Motion", 1, true) then want(c) end
        end
    end
    local cm = singleton(CHARACTER_MANAGER)
    local partner = cm and self:call(cm, "getPartnerContextRef")
    if partner ~= nil then want(type_name_of(partner)) end

    local pickups = self:list_pickups() or {}
    live.pickups = {}
    for i, p in ipairs(pickups) do
        if i > 20 then break end
        live.pickups[i] = { item_id = p.item_id, count = p.count, key_item = Game.is_key_item(p.item_id), context_id = p.ctx }
    end
    if pickups[1] ~= nil and self.pickup_objects[pickups[1].id] ~= nil then
        live.pickup_components = self:component_names(self.pickup_objects[pickups[1].id])
    end

    local prev = load_json(TYPEDUMP_FILE)
    local dump = {
        game = reframework:get_game_name(),
        mod_version = P.MOD_VERSION,
        runs = (prev and tonumber(prev.runs) or 0) + 1,
        capabilities = self.caps,
        live = live,
        types = {},
        enums = {},
        areas_seen = {},
    }
    for _, n in ipairs(names) do
        local td = find_type(n)
        if td ~= nil then
            local ok, d = pcall(describe_type, td, 0)
            dump.types[n] = ok and d or ("error: " .. tostring(d))
        else
            dump.types[n] = "not found"
        end
    end
    for _, n in ipairs(DUMP_ENUMS) do
        local td = find_type(n)
        dump.enums[n] = td and enum_values(td) or "not found"
    end
    -- Keep what earlier runs found (types seen only in other areas).
    if prev ~= nil and type(prev.types) == "table" then
        for n, d in pairs(prev.types) do
            if dump.types[n] == nil then dump.types[n] = d end
        end
    end
    local area = tostring(self:area_name() or "?") .. " / stage " .. tostring(ctx and plain_value(self:call(ctx, "get_CurrentStageID")) or "?")
    local area_known = false
    for _, a in ipairs(prev and type(prev.areas_seen) == "table" and prev.areas_seen or {}) do
        if #dump.areas_seen < MAX_AREAS_SEEN then dump.areas_seen[#dump.areas_seen + 1] = a end
        if a == area then area_known = true end
    end
    if not area_known and #dump.areas_seen < MAX_AREAS_SEEN then dump.areas_seen[#dump.areas_seen + 1] = area end
    local okp, player = pcall(self.describe_player, self)
    dump.player = okp and player or tostring(player)
    dump.mirror_counters = self.counters
    local ok = pcall(json.dump_file, TYPEDUMP_FILE, dump)

    local okS, snap = pcall(self.research_snapshot, self, extra)
    if not okS then snap = { error = tostring(snap) } end
    snap.run = dump.runs
    local log = load_json(RESEARCH_LOG_FILE)
    local runs = log and type(log.runs) == "table" and log.runs or {}
    runs[#runs + 1] = snap
    while #runs > RESEARCH_LOG_MAX do table.remove(runs, 1) end
    local okL = pcall(json.dump_file, RESEARCH_LOG_FILE, { mod_version = P.MOD_VERSION, runs = runs })
    return ok and okL, dump.runs
end

return Game
