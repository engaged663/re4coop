-- RE4 (2023) adapter: the only module that touches REFramework's `sdk`, `draw` and game
-- objects. Everything else talks to the game through the methods below.
--
-- Type and method names come from REFramework's own RE4 helper (scripts/utility/RE4.lua)
-- and from published RE4R mods (see docs/RESEARCH.md). Names that could not be confirmed
-- are *probed* at runtime: each capability is looked up once, reported in the UI's
-- diagnostics panel, and the feature that needs it switches itself off if it is missing.
-- Every game call is wrapped in pcall so a game patch degrades features instead of
-- throwing errors every frame.

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
    self:probe()
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

-- Reads an object's `_ID` field (chainsaw.ContextID: _Category, _Kind, _Group, _Index - field
-- names from the RE4 RSZ schema). Characters and DropItems both carry one. Returns a plain
-- table or nil if it cannot be read.
local function read_field(obj, name)
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

function Game:read_context_id(obj)
    local id = read_field(obj, "_ID")
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

function Game:get_component(game_object, type_name)
    local t = self.typeof_cache and self.typeof_cache[type_name]
    if t == nil then
        local ok, ty = pcall(sdk.typeof, type_name)
        t = ok and ty or false
        self.typeof_cache = self.typeof_cache or {}
        self.typeof_cache[type_name] = t
    end
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
                -- A context's ID never changes, so read it once per context.
                local cid = old_ids[id]
                if cid == nil then cid = self:read_context_id(ctx) or false end
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
        self:cap("enemy_context_id", with_id > 0, ("%d of %d enemies expose chainsaw.ContextID"):format(with_id, #out))
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

-- Every chainsaw.DropItem in the loaded scene:
-- { {id, item_id, count, pos, ctx}, ... }. Field names (_ID, _ItemData.ItemID/Count) come
-- from the RE4 RSZ schema; the scene search is the engine's via.Scene.findComponents.
function Game:list_pickups()
    local scene = self:current_scene()
    if scene == nil then
        self:cap("pickups", false, "no current scene")
        return nil
    end
    local t = self.typeof_cache and self.typeof_cache["chainsaw.DropItem"]
    if t == nil then
        local ok, ty = pcall(sdk.typeof, "chainsaw.DropItem")
        t = ok and ty or false
        self.typeof_cache = self.typeof_cache or {}
        self.typeof_cache["chainsaw.DropItem"] = t
    end
    if not t then
        self:cap("pickups", false, "chainsaw.DropItem type not found")
        return nil
    end
    local okF, comps = pcall(function() return scene:call("findComponents(System.Type)", t) end)
    if not okF or comps == nil then
        self:cap("pickups", false, "findComponents(chainsaw.DropItem) failed")
        return nil
    end

    local out, go_by_id, unreadable = {}, {}, 0
    for _, comp in ipairs(array_elements(comps)) do
        local go = self:call(comp, "get_GameObject")
        local transform = go and self:call(go, "get_Transform")
        local pos = transform and v3(self:call(transform, "get_Position"))
        local data = read_field(comp, "_ItemData")
        local item_id = data and tonumber(read_field(data, "ItemID"))
        if go ~= nil and pos ~= nil and item_id ~= nil then
            local id = comp:get_address()
            go_by_id[id] = go
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
    self:cap("pickups", #out > 0 or unreadable == 0,
        ("%d drop items readable, %d unreadable"):format(#out, unreadable))
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
    "chainsaw.PlayerBaseContext", "chainsaw.EnemyManager", "chainsaw.ContextID",
    "chainsaw.HateController", "chainsaw.HateTargetInfo", "chainsaw.HateControllerUserData",
    "chainsaw.EnemyAttackPermitManager", "chainsaw.PartnerAttackTargetSelector",
    "chainsaw.DropItemManager", "chainsaw.DropItem", "chainsaw.DropItemContext", "chainsaw.RandomDrop",
    "chainsaw.GmOptionDropItem", "chainsaw.GmOptionGenerateDropItem",
    "chainsaw.InteractGetPickupItem", "chainsaw.InteractManager", "chainsaw.InventoryManager",
    "chainsaw.ItemManager", "chainsaw.ItemDefinitionManager", "chainsaw.GmKeyItemCase", "chainsaw.GmUseItemGate",
    "chainsaw.ScenarioFlagManager", "chainsaw.ChapterSceneManager", "chainsaw.LocationSceneManager",
    "chainsaw.CampaignManager", "chainsaw.GameSituationManager", "chainsaw.GimmickManager",
    "chainsaw.CharacterSpawnController", "chainsaw.SpawnController", "chainsaw.PartnerNpcSpawnParam",
    "via.motion.Motion", "via.motion.TreeLayer", "via.motion.MotionFsm2", "via.behaviortree.BehaviorTree",
    "via.physics.CharacterController",
}

local SINGLETONS_TO_CHECK = {
    CHARACTER_MANAGER, GUI_MANAGER, "chainsaw.EnemyManager", "chainsaw.DropItemManager", "chainsaw.InteractManager",
    "chainsaw.InventoryManager", "chainsaw.ItemManager", "chainsaw.ScenarioFlagManager",
    "chainsaw.ChapterSceneManager", "chainsaw.LocationSceneManager", "chainsaw.CampaignManager",
    "chainsaw.GameSituationManager", "chainsaw.GimmickManager", "chainsaw.EnemyAttackPermitManager",
}

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

-- Writes reframework/data/re4coop_typedump.json: signatures of the types above, which
-- singletons exist right now, live component lists and sample IDs. Attach it to reports.
function Game:dump_types()
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
        live.enemies[i] = { kind = e.kind, hp = e.hp, max_hp = e.max_hp, alive = e.alive, context_id = e.ctx }
        want(e.kind)
    end
    local first = enemies[1] and self.enemy_ctx[enemies[1].id]
    if first ~= nil then
        live.enemy_components = self:component_names(self:call(first, "get_BodyGameObject"))
        for _, c in ipairs(live.enemy_components or {}) do
            if c:find("Hate", 1, true) or c:find("Behavior", 1, true) or c:find("Motion", 1, true) then want(c) end
        end
    end

    local pickups = self:list_pickups() or {}
    live.pickups = {}
    for i, p in ipairs(pickups) do
        if i > 20 then break end
        live.pickups[i] = { item_id = p.item_id, count = p.count, key_item = Game.is_key_item(p.item_id), context_id = p.ctx }
    end
    if pickups[1] ~= nil and self.pickup_objects[pickups[1].id] ~= nil then
        live.pickup_components = self:component_names(self.pickup_objects[pickups[1].id])
    end

    local dump = {
        game = reframework:get_game_name(),
        capabilities = self.caps,
        live = live,
        types = {},
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
    local ok = pcall(json.dump_file, "re4coop_typedump.json", dump)
    return ok
end

return Game
