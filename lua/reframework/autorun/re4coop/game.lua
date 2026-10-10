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

-- Candidate names for things no public RE4R script confirmed. First match wins.
local HP_SETTERS = { "set_CurrentHitPoint", "setCurrentHitPoint", "setHitPoint", "set_HitPoint" }
local HP_FIELDS = { "<CurrentHitPoint>k__BackingField", "_CurrentHitPoint", "CurrentHitPoint", "_HitPoint" }
local KILL_METHODS = { "dead", "setDead", "kill", "die" }
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

-- Resolves the capabilities we cannot confirm statically.
function Game:probe()
    self:cap("character_manager_type", find_type(CHARACTER_MANAGER) ~= nil, CHARACTER_MANAGER)

    local hp_td = find_type(HIT_POINT)
    self.hp_setter, self.hp_setter_int, self.hp_field, self.hp_field_int, self.kill_method = nil, false, nil, false, nil
    if hp_td ~= nil then
        for _, name in ipairs(HP_SETTERS) do
            local m = hp_td:get_method(name)
            if m ~= nil and method_param_count(m) == 1 then
                self.hp_setter = name
                self.hp_setter_int = INTEGER_TYPES[method_param_type(m, 1) or ""] or false
                break
            end
        end
        if self.hp_setter == nil then
            for _, name in ipairs(HP_FIELDS) do
                local f = hp_td:get_field(name)
                if f ~= nil then
                    self.hp_field = name
                    local ok, ft = pcall(function() return f:get_type():get_full_name() end)
                    self.hp_field_int = ok and INTEGER_TYPES[ft] or false
                    break
                end
            end
        end
        for _, name in ipairs(KILL_METHODS) do
            local m = hp_td:get_method(name)
            if m ~= nil and method_param_count(m) == 0 then
                self.kill_method = name
                break
            end
        end
    end
    self:cap("hitpoint_type", hp_td ~= nil, HIT_POINT)
    self:cap("enemy_set_hp", self.hp_setter ~= nil or self.hp_field ~= nil,
        self.hp_setter and ("method " .. self.hp_setter) or (self.hp_field and ("field " .. self.hp_field)) or "no setter found")
    self:cap("enemy_kill", self.kill_method ~= nil or self.hp_setter ~= nil or self.hp_field ~= nil,
        self.kill_method and ("method " .. self.kill_method .. "()") or "fallback: set HP to 0")
end

function Game:capabilities()
    return self.caps
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

    local out, ctx_by_id = {}, {}
    for i = 0, count - 1 do
        local ctx = self:call(list, "get_Item", i)
        if ctx ~= nil then
            local pos = v3(self:call(ctx, "get_Position"))
            local hp = self:call(ctx, "get_HitPoint")
            if pos ~= nil and hp ~= nil then
                local id = ctx:get_address()
                ctx_by_id[id] = ctx
                out[#out + 1] = {
                    id = id,
                    kind = type_name_of(ctx) or "unknown",
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
    return out
end

function Game:write_hp(hp_obj, value)
    if self.hp_setter ~= nil then
        local v = self.hp_setter_int and math.floor(value + 0.5) or value
        local m = self:method(hp_obj, self.hp_setter)
        if m ~= nil and pcall(m.call, m, hp_obj, v) then return true end
    end
    if self.hp_field ~= nil then
        local v = self.hp_field_int and math.floor(value + 0.5) or value
        if pcall(function() hp_obj:set_field(self.hp_field, v) end) then return true end
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

local DUMP_TYPES = {
    CHARACTER_MANAGER, GUI_MANAGER, HIT_POINT, "chainsaw.EnemyManager", "chainsaw.EnemyBaseContext",
    "chainsaw.PlayerBaseContext", "chainsaw.CharacterContext", "chainsaw.CampaignManager",
    "chainsaw.GameStatusManager", "chainsaw.LevelManager", "chainsaw.MapManager",
}

local function describe_type(td, depth)
    local out = { name = td:get_full_name(), methods = {}, fields = {} }
    local ok_m, methods = pcall(td.get_methods, td)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok, n = pcall(m.get_name, m)
            if ok then
                out.methods[#out.methods + 1] = ("%s/%d"):format(n, method_param_count(m))
            end
        end
    end
    local ok_f, fields = pcall(td.get_fields, td)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok, n = pcall(f.get_name, f)
            if ok then out.fields[#out.fields + 1] = n end
        end
    end
    local parent = td:get_parent_type()
    if parent ~= nil and depth < 4 and parent:get_full_name() ~= "System.Object" then
        out.parent = describe_type(parent, depth + 1)
    end
    return out
end

-- Writes reframework/data/re4coop_typedump.json describing the types this mod relies on,
-- plus the live player/enemy context types. Attach it to bug reports.
function Game:dump_types()
    local names = {}
    for _, n in ipairs(DUMP_TYPES) do names[#names + 1] = n end
    local ctx = self:player_context()
    if ctx ~= nil then names[#names + 1] = type_name_of(ctx) end
    for _, ectx in pairs(self.enemy_ctx) do
        names[#names + 1] = type_name_of(ectx)
        break
    end

    local dump = { game = reframework:get_game_name(), capabilities = self.caps, types = {} }
    for _, n in ipairs(names) do
        local td = n and find_type(n)
        if td ~= nil then
            dump.types[n] = describe_type(td, 0)
        else
            dump.types[n or "?"] = "not found"
        end
    end
    local ok = pcall(json.dump_file, "re4coop_typedump.json", dump)
    return ok
end

return Game
