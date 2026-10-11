-- RE4 (2023) adapter: the only module that touches REFramework's `sdk`, `draw` and game
-- objects. Everything else talks to the game through the methods below.
--
-- Type and method names come from REFramework's own RE4 helper (scripts/utility/RE4.lua)
-- and from published RE4R mods (see docs/RESEARCH.md). Names that could not be confirmed
-- are *probed* at runtime: each capability is looked up once, reported in the UI's
-- diagnostics panel, and the feature that needs it switches itself off if it is missing.
-- Every game call is wrapped in pcall so a game patch degrades features instead of
-- throwing errors every frame.

local P = require("re4coop.protocol")

local Game = {}
Game.__index = Game

local CHARACTER_MANAGER = "chainsaw.CharacterManager"
local GUI_MANAGER = "chainsaw.GuiManager"
local HIT_POINT = "chainsaw.HitPoint"

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

-- Ghost skeleton: keep the big bones, skip fingers/face/twist helpers.
local JOINT_INCLUDE = { "hip", "pelvis", "cog", "spine", "chest", "neck", "head", "clavicle", "shoulder",
    "arm", "elbow", "hand", "wrist", "thigh", "leg", "knee", "calf", "shin", "foot", "ankle", "toe" }
local JOINT_EXCLUDE = { "twist", "finger", "thumb", "index", "middle", "ring", "pinky", "eye", "jaw", "lip",
    "brow", "cheek", "tongue", "teeth", "nose", "_ear", "hair", "breast", "_end", "null", "helper", "roll",
    "ik", "face", "sub", "prop", "wep", "weapon", "_h_", "skirt", "cloth", "bag", "holster" }
local MAX_JOINTS = 40

local function v3(v)
    if v == nil then return nil end
    return { x = v.x, y = v.y, z = v.z }
end

local function name_matches(name, list)
    for _, p in ipairs(list) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

function Game.new(log)
    local self = setmetatable({}, Game)
    self.log = log or function() end
    self.method_cache = {}
    self.caps = {}        -- name -> { ok=bool, detail=string }
    self.enemy_ctx = {}   -- id -> context object from the latest list_enemies()
    self.joint_sel = nil  -- cached ghost joint selection for the current player transform
    self.area_probe = nil
    self.puppet = nil
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

-- sdk.typeof(name), cached (false when the type does not exist).
function Game:typeof(type_name)
    self.typeof_cache = self.typeof_cache or {}
    local t = self.typeof_cache[type_name]
    if t == nil then
        local ok, ty = pcall(sdk.typeof, type_name)
        t = ok and ty or false
        self.typeof_cache[type_name] = t
    end
    return t
end

function Game:get_component(game_object, type_name)
    local t = self:typeof(type_name)
    if not t then return nil end
    return self:call(game_object, "getComponent(System.Type)", t)
end

-- Picks the ghost's joints once per transform and works out their parent links.
function Game:select_joints(transform)
    local joints = self:call(transform, "get_Joints")
    if joints == nil then return nil end
    local ok, count = pcall(function() return joints:get_size() end)
    if not ok or count == nil or count == 0 then return nil end

    local all, index_of_addr = {}, {}
    for i = 0, count - 1 do
        local j = joints:get_element(i)
        if j ~= nil then
            local name = tostring(self:call(j, "get_Name") or "")
            all[#all + 1] = { joint = j, name = name, lname = name:lower(), addr = j:get_address() }
        end
    end

    local picked = {}
    for _, e in ipairs(all) do
        if name_matches(e.lname, JOINT_INCLUDE) and not name_matches(e.lname, JOINT_EXCLUDE) then
            picked[#picked + 1] = e
            if #picked >= MAX_JOINTS then break end
        end
    end
    if #picked < 5 then
        picked = {}
        for i = 1, math.min(#all, MAX_JOINTS) do picked[i] = all[i] end
    end
    for i, e in ipairs(picked) do index_of_addr[e.addr] = i end

    local parents = {}
    for i, e in ipairs(picked) do
        local parent_index = 0
        local p = self:call(e.joint, "get_Parent")
        local guard = 0
        while p ~= nil and guard < 64 do
            local idx = index_of_addr[p:get_address()]
            if idx ~= nil then
                parent_index = idx
                break
            end
            p = self:call(p, "get_Parent")
            guard = guard + 1
        end
        parents[i] = parent_index
    end

    local names = {}
    for i, e in ipairs(picked) do names[i] = e.name end
    self:cap("ghost_skeleton", true, ("%d of %d joints"):format(#picked, #all))
    return { transform_addr = transform:get_address(), joints = picked, parents = parents, names = names }
end

-- Returns { pos, rot, hp, max_hp, dead, cutscene, aiming, joints, parents } or nil when
-- there is no controllable player (title screen, loading).
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
        local q = self:call(transform, "get_Rotation")
        if q ~= nil then
            st.rot = { x = q.x, y = q.y, z = q.z, w = q.w }
        end
        if self.joint_sel == nil or self.joint_sel.transform_addr ~= transform:get_address() then
            self.joint_sel = self:select_joints(transform)
        end
        if self.joint_sel ~= nil then
            local out = {}
            for i, e in ipairs(self.joint_sel.joints) do
                local jp = self:call(e.joint, "get_Position")
                if jp == nil then
                    out = nil
                    self.joint_sel = nil -- transform rebuilt; reselect next time
                    break
                end
                out[i] = { x = jp.x, y = jp.y, z = jp.z }
            end
            if out ~= nil then
                st.joints = out
                st.parents = self.joint_sel.parents
            end
        end
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
    local ok, scene = pcall(function()
        return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
    return ok and scene or nil
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
-- Experimental: real character model for the partner
-------------------------------------------------------------------------------

-- Spawns `prefab_path` (e.g. a character body .pfb path from the game's PAKs, written
-- relative to natives/stm) and moves it to the partner's interpolated position each tick.
-- The model is not animated. Off by default; see docs/RESEARCH.md for the risks.
function Game:update_puppet(enabled, prefab_path, state)
    local p = self.puppet
    if not enabled or prefab_path == "" or state == nil then
        if p ~= nil then self:destroy_puppet() end
        return
    end
    if p ~= nil and p.path ~= prefab_path then
        self:destroy_puppet()
        p = nil
    end
    if p == nil then
        local ok, prefab = pcall(function() return sdk.create_instance("via.Prefab", true):add_ref() end)
        if not ok or prefab == nil then
            self:cap("puppet", false, "could not create via.Prefab")
            return
        end
        pcall(function()
            prefab:call("set_Path", prefab_path)
            prefab:call("set_Standby", true)
        end)
        p = { path = prefab_path, prefab = prefab, go = nil, started = os.clock() }
        self.puppet = p
    end
    if p.failed then return end
    if p.go == nil then
        local ok, ready = pcall(function() return p.prefab:call("get_Ready") end)
        if ok and ready then
            local spawn_at = Vector3f.new(state.pos.x, state.pos.y, state.pos.z)
            local ok2, go = pcall(function() return p.prefab:call("instantiate(via.vec3)", spawn_at) end)
            if ok2 and go ~= nil then
                p.go = go
                self:cap("puppet", true, "spawned " .. prefab_path)
            else
                p.failed = true
                self:cap("puppet", false, "instantiate failed for " .. prefab_path)
            end
        elseif os.clock() - p.started > 10 then
            p.failed = true
            self:cap("puppet", false, "prefab never became ready - check the path")
        end
        return
    end
    local transform = self:call(p.go, "get_Transform")
    if transform == nil then
        self.puppet = nil -- destroyed by the game (area unload)
        return
    end
    pcall(function()
        transform:call("set_Position", Vector3f.new(state.pos.x, state.pos.y, state.pos.z))
        if state.rot then
            transform:call("set_Rotation", Quaternion.new(state.rot.w, state.rot.x, state.rot.y, state.rot.z))
        end
    end)
end

function Game:destroy_puppet()
    local p = self.puppet
    self.puppet = nil
    if p == nil then return end
    if p.go ~= nil then
        pcall(function() p.go:call("destroy", p.go) end)
    end
    if p.prefab ~= nil then
        pcall(function() p.prefab:release() end)
    end
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

-- Writes reframework/data/re4coop_typedump.json (signatures, enum values, capabilities, the
-- latest live sample) and appends to reframework/data/re4coop_research_log.json. `extra` is
-- the session's sync state. Returns ok, number of runs so far.
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
