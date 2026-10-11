-- A small stand-in for REFramework's Lua environment (sdk, re, imgui, draw, json, log,
-- Vector3f, Quaternion) backed by a fake RE4 object graph. It mirrors the *shapes* the mod
-- relies on - type definitions with get_method/get_field, managed objects with :call(),
-- List`1 with get_Count/get_Item, via.Transform joints - so game.lua, ui.lua, ghost.lua and
-- re4coop.lua can be exercised end to end outside the game.
--
-- It is not RE4: it only proves our code is internally consistent with the API shapes we
-- researched. Real-game verification is still required (see docs/TESTING.md).

local M = {}

local classes = {}

local function make_method(name, nparams, fn, param_types)
    return {
        name = name, nparams = nparams, fn = fn, param_types = param_types or {},
        call = function(self, obj, ...) return self.fn(obj, ...) end,
        get_name = function(self) return self.name end,
        get_num_params = function(self) return self.nparams end,
        get_param_types = function(self)
            local out = {}
            for i, t in ipairs(self.param_types) do
                out[i] = { get_full_name = function() return t end }
            end
            return out
        end,
    }
end

local TypeDef = {}
TypeDef.__index = TypeDef

function TypeDef:get_full_name() return self.name end
function TypeDef:get_name() return self.name:match("([^.]+)$") end
function TypeDef:get_parent_type() return self.parent and classes[self.parent] or nil end
function TypeDef:get_method(name)
    local td = self
    while td do
        local m = td.methods[name]
        if m then return m end
        td = td.parent and classes[td.parent] or nil
    end
    return nil
end
function TypeDef:get_field(name)
    local td = self
    while td do
        if td.fields[name] then
            local fname, ftype = name, td.fields[name]
            return {
                get_name = function() return fname end,
                get_type = function() return { get_full_name = function() return ftype end } end,
                is_static = function() return false end,
            }
        end
        if td.static_values[name] ~= nil then
            -- Enum literal: static field whose data is the value (field:get_data(nil)).
            local fname, value, owner = name, td.static_values[name], td.name
            return {
                get_name = function() return fname end,
                get_type = function() return { get_full_name = function() return owner end } end,
                is_static = function() return true end,
                get_data = function(_, obj)
                    assert(obj == nil, "static field read with an object")
                    return value
                end,
            }
        end
        td = td.parent and classes[td.parent] or nil
    end
    return nil
end
function TypeDef:get_methods()
    local out = {}
    for _, m in pairs(self.methods) do out[#out + 1] = m end
    return out
end
function TypeDef:get_fields()
    local out = {}
    for name in pairs(self.fields) do out[#out + 1] = self:get_field(name) end
    for name in pairs(self.static_values) do out[#out + 1] = self:get_field(name) end
    return out
end

-- class(name, parent, { method = {nparams, fn, param_types} }, { field = type })
local function class(name, parent, methods, fields)
    local td = setmetatable({ name = name, parent = parent, methods = {}, fields = fields or {}, static_values = {} },
        TypeDef)
    for mname, spec in pairs(methods or {}) do
        td.methods[mname] = make_method(mname, spec[1], spec[2], spec[3])
    end
    classes[name] = td
    return td
end
M.class = class
M.classes = classes

-- An enum type: its literals are static fields.
local function enum(name, values)
    local td = class(name, "System.Object", {})
    td.static_values = values
    return td
end

local Managed = {}
Managed.__index = Managed
local next_address = 0x10000

function Managed:get_type_definition() return classes[self.__type] end
function Managed:get_address() return self.__addr end
function Managed:add_ref() return self end
function Managed:release() end
function Managed:call(name, ...)
    local m = classes[self.__type]:get_method(name)
    if m == nil then error("mock: no method " .. name .. " on " .. self.__type) end
    return m.fn(self, ...)
end
function Managed:get_field(name) return self.__fields[name] end
function Managed:set_field(name, v)
    if classes[self.__type]:get_field(name) == nil then error("mock: no field " .. name) end
    self.__fields[name] = v
end

local function new(type_name, data)
    assert(classes[type_name], "mock: unknown class " .. type_name)
    next_address = next_address + 0x100
    local o = setmetatable(data or {}, Managed)
    o.__type = type_name
    o.__addr = next_address
    o.__fields = o.__fields or {}
    return o
end
M.new = new

local function vec(x, y, z) return { x = x, y = y, z = z } end

-- Stand-in for a REFramework ValueType (struct field value, e.g. chainsaw.ContextID).
local ValueType = {}
ValueType.__index = ValueType
function ValueType:get_field(name) return self.f[name] end
local function value_type(fields) return setmetatable({ f = fields }, ValueType) end
M.value_type = value_type

local function context_id(ctx)
    if ctx == nil then return nil end
    return value_type({ _Category = ctx.category or 0, _Kind = ctx.kind or 0, _Group = ctx.group, _Index = ctx.index })
end

-------------------------------------------------------------------------------
-- Fake RE4 object model
-------------------------------------------------------------------------------

local JOINT_NAMES = { "root", "Hip", "Spine_0", "Spine_2", "Neck_0", "Head", "L_Shoulder", "L_UpperArm",
    "L_Forearm", "L_Hand", "L_Finger_0", "R_Shoulder", "R_UpperArm", "R_Forearm", "R_Hand", "L_Thigh",
    "L_Knee", "L_Foot", "R_Thigh", "R_Knee", "R_Foot", "L_ArmTwist" }
local JOINT_PARENTS = { 0, 1, 2, 3, 4, 5, 4, 7, 8, 9, 10, 4, 12, 13, 14, 2, 16, 17, 2, 19, 20, 8 }

function M.install(opts)
    opts = opts or {}
    classes = {}
    M.classes = classes
    local world = { singletons = {}, enemies = {}, drops = {}, components = {}, gui_event = false, created = {} }
    M.world = world

    class("System.Object", nil, {})
    class("via.Joint", "System.Object", {
        get_Name = { 0, function(self) return self.name end },
        get_Position = { 0, function(self)
            local o = self.owner.pos
            return vec(o.x + self.offset.x, o.y + self.offset.y, o.z + self.offset.z)
        end },
        get_Parent = { 0, function(self) return self.parent end },
    })
    class("System.Array", "System.Object", {})
    class("via.Transform", "System.Object", {
        get_Position = { 0, function(self) return vec(self.owner.pos.x, self.owner.pos.y, self.owner.pos.z) end },
        set_Position = { 1, function(self, v) self.owner.pos.x, self.owner.pos.y, self.owner.pos.z = v.x, v.y, v.z end },
        get_Rotation = { 0, function(self) return { x = 0, y = self.owner.yaw or 0, z = 0, w = 1 } end },
        set_Rotation = { 1, function(self, q) self.owner.rot = q end },
        get_Joints = { 0, function(self) return self.joints end },
    })
    class("via.physics.CharacterController", "System.Object", {
        warp = { 0, function(self) self.owner.warped = (self.owner.warped or 0) + 1 end },
    })
    class("via.GameObject", "System.Object", {
        get_Transform = { 0, function(self) return self.transform end },
        ["getComponent(System.Type)"] = { 1, function(self, t)
            if t.name == "via.physics.CharacterController" then return self.cc end
            if t.name == "via.motion.Motion" then return self.motion end
            return nil
        end },
        get_Name = { 0, function(self) return self.name or "GameObject" end },
        destroy = { 1, function(self)
            self.destroyed = true
            if self.on_destroy then self.on_destroy() end
        end },
        get_Components = { 0, function(self) return M.array(self.components or {}) end },
    })
    class("chainsaw.DropItem", "System.Object", {
        get_GameObject = { 0, function(self) return self.go end },
        -- Level-placed items keep ItemID 0 in _ItemData; getItemID() knows the real one.
        getItemID = { 0, function(self) return self.real_item_id or self.__fields._ItemData.f.ItemID end },
        -- Static pickup callbacks (the game calls them; the mod only hooks them).
        onAcceptPickup = { 2, function() end, { "chainsaw.ContextID", "chainsaw.ContextID" } },
        onAcceptOccupied = { 3, function() end, { "chainsaw.ContextID", "chainsaw.ContextID", "System.Int32" } },
        getStage = { 0, function(self) return self.stage or 40210 end },
    }, { _ID = "chainsaw.ContextID", _ItemData = "chainsaw.DropItemContext.SaveData", _IsLostItem = "System.Boolean" })
    class("via.Scene", "System.Object", {
        ["findComponents(System.Type)"] = { 1, function(_, t)
            local comps = {}
            if t.name == "chainsaw.DropItem" then
                for _, d in ipairs(world.drops) do comps[#comps + 1] = d end
            end
            for _, c in ipairs(world.components[t.name] or {}) do comps[#comps + 1] = c end
            return M.array(comps)
        end },
    })
    class("via.motion.TreeLayer", "System.Object", {
        get_MotionBankID = { 0, function(self) return self.bank end },
        get_MotionID = { 0, function(self) return self.motion end },
        get_Frame = { 0, function(self) return self.frame end },
    })
    class("via.motion.Motion", "System.Object", {
        getLayer = { 1, function(self, i) return self.layers[i + 1] end, { "System.UInt32" } },
        getLayerCount = { 0, function(self) return #self.layers end },
    })
    class("chainsaw.HateTargetInfo", "System.Object", {}, { _Target = "via.GameObject", _Hate = "System.Single" })
    class("chainsaw.HateController", "System.Object", {
        get_GameObject = { 0, function(self) return self.go end },
        get_CurrentTarget = { 0, function(self) return self.target end },
        get_FindState = { 0, function() return 2 end },
        get_TotalAttention = { 0, function() return 0.5 end },
    })
    class("chainsaw.StageIdentifier", "System.Object", {}, { _StageID = "chainsaw.StageID", _AreaNo = "System.Int32" })
    enum("chainsaw.CharacterKindID", { ch0a0z0 = 100000, ch3a8z0 = 380000, ch1c0z0 = 1120000 })
    enum("chainsaw.CharacterUsePurposeFlag", { None = 0, Player = 1, Partner = 2 })
    enum("chainsaw.ContextID.EntityCategory", { Character = 0, Gimmick = 1, DropItem = 2, StaticItem = 3 })
    enum("chainsaw.StageID", { st40_200 = 40200, st40_210 = 40210 })
    class("via.SceneManager", "System.Object", {})

    -- HitPoint variants (opts):
    --   default            set_CurrentHitPoint(Int32) works
    --   hp_setter_name     the working setter has another name (discovery must find it)
    --   broken_setter      set_CurrentHitPoint exists but does nothing (must be rejected)
    --   no_hp_setter       no setter at all; HP lives in field hp_field_name
    --   decoy setter       set_DefaultHitPoint always exists (must never be used)
    local hp_methods = {
        get_CurrentHitPoint = { 0, function(self) return self.owner.hp end },
        get_DefaultHitPoint = { 0, function(self) return self.owner.max_hp end },
        get_IsLive = { 0, function(self) return self.owner.hp > 0 end },
        set_DefaultHitPoint = { 1, function(self, v)
            M.decoy_calls = (M.decoy_calls or 0) + 1
            self.owner.max_hp = v
        end, { "System.Int32" } },
    }
    M.decoy_calls = 0
    if opts.broken_setter then
        hp_methods.set_CurrentHitPoint = { 1, function() end, { "System.Int32" } }
    end
    if not opts.no_hp_setter then
        hp_methods[opts.hp_setter_name or "set_CurrentHitPoint"] = { 1, function(self, v)
            assert(math.type(v) == "integer", "HP setter expects an Int32")
            self.owner.hp = v
        end, { "System.Int32" } }
    end
    if not opts.no_kill_method then
        hp_methods.dead = { 0, function(self) self.owner.hp = 0 end }
    end
    M.hp_field_name = opts.hp_field_name or "<CurrentHitPoint>k__BackingField"
    class("chainsaw.HitPoint", "System.Object", hp_methods,
        opts.no_hp_setter and { [M.hp_field_name] = "System.Int32" } or {})

    local ctx_methods = {
        get_Position = { 0, function(self) return vec(self.pos.x, self.pos.y, self.pos.z) end },
        get_HitPoint = { 0, function(self) return self.hitpoint end },
        get_BodyGameObject = { 0, function(self) return self.body end },
        -- Level spawner that created the character (nil for characters without one).
        get_SpawnerID = { 0, function(self) return self.spawner end },
        get_CurrentStageID = { 0, function(self) return self.stage or world.stage or 40100 end },
        get_KindID = { 0, function(self) return self.kind_id or 0 end },
        get_TargetFindState = { 0, function() return 1 end },
        get_TargetFindSource = { 0, function() return 0 end },
    }
    class("chainsaw.CharacterContext", "System.Object", ctx_methods, { _ID = "chainsaw.ContextID" })
    class("chainsaw.PlayerBaseContext", "chainsaw.CharacterContext", {
        get_IsHolding = { 0, function(self) return self.aiming or false end },
    })
    class("chainsaw.EnemyBaseContext", "chainsaw.CharacterContext", {})
    class("chainsaw.Ch1c0z0Context", "chainsaw.EnemyBaseContext", {})
    class("chainsaw.Ch1d0z0Context", "chainsaw.EnemyBaseContext", {})
    class("chainsaw.PartnerBaseContext", "chainsaw.CharacterContext", {})
    class("chainsaw.Ch3a8z0Context", "chainsaw.PartnerBaseContext", {}) -- Ashley

    class("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>", "System.Object", {
        get_Count = { 0, function(self) return #world.enemies end },
        get_Item = { 1, function(self, i) return world.enemies[i + 1] end },
    })
    local enemy_list = new("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>")

    class("chainsaw.CharacterManager", "System.Object", {
        getPlayerContextRef = { 0, function() return world.player end },
        getPartnerContextRef = { 0, function() return world.partner end },
        get_EnemyContextList = { 0, function() return enemy_list end },
    })
    class("chainsaw.GuiManager", "System.Object", {
        get_IsPlayingEvent = { 0, function() return world.gui_event end },
    })
    class("chainsaw.CampaignManager", "System.Object", {
        get_CurrentChapter = { 0, function() return world.chapter or 1 end },
        get_CurrentDifficulty = { 0, function() return 20 end },
        get_CurrentStageIdentifier = { 0, function()
            local sid = new("chainsaw.StageIdentifier")
            sid.__fields._StageID, sid.__fields._AreaNo = world.stage or 40100, 3
            return sid
        end },
    })
    class("chainsaw.EnemyManager", "System.Object", {})
    class("via.Prefab", "System.Object", {
        set_Path = { 1, function(self, p) self.path = p end },
        set_Standby = { 1, function() end },
        get_Ready = { 0, function(self) return self.path ~= nil end },
        ["instantiate(via.vec3)"] = { 1, function(self, pos)
            local go = M.make_character("chainsaw.CharacterContext", pos, 100).body
            world.created[#world.created + 1] = go
            return go
        end },
    })

    world.scene = new("via.Scene")
    world.scene_manager = new("via.SceneManager")
    world.singletons["chainsaw.CharacterManager"] = new("chainsaw.CharacterManager")
    world.singletons["chainsaw.GuiManager"] = new("chainsaw.GuiManager")
    world.singletons["chainsaw.CampaignManager"] = new("chainsaw.CampaignManager")

    -- Globals REFramework provides.
    M.keys = {}
    _G.reframework = {
        get_game_name = function() return opts.game_name or "re4" end,
        is_key_down = function(_, vk) return M.keys[vk] == true end,
    }
    _G.sdk = {
        find_type_definition = function(name) return classes[name] end,
        get_managed_singleton = function(name) return world.singletons[name] end,
        get_native_singleton = function(name)
            if name == "via.SceneManager" then return world.scene_manager end
            return nil
        end,
        call_native_func = function(obj, td, name)
            assert(obj == world.scene_manager and td.name == "via.SceneManager" and name == "get_CurrentScene",
                "mock: unexpected native call " .. tostring(name))
            return world.scene
        end,
        call_object_func = function(obj, name, ...) return obj:call(name, ...) end,
        typeof = function(name) return { name = name } end,
        create_instance = function(name) return new(name) end,
        to_managed_object = function(ptr) return ptr end,
    }
    -- sdk.hook: pre-functions are kept per method name and run by M.fire_hooks().
    M.hooks = {}
    if not opts.no_hook then
        _G.sdk.hook = function(method, pre, post)
            M.hooks[method.name] = M.hooks[method.name] or {}
            table.insert(M.hooks[method.name], { pre = pre, post = post })
        end
    end
    _G.Vector3f = { new = function(x, y, z) return vec(x, y, z) end }
    _G.Quaternion = { new = function(w, x, y, z) return { x = x, y = y, z = z, w = w } end }

    local callbacks = { entry = {}, frame = {}, ui = {}, config_save = {}, reset = {} }
    M.callbacks = callbacks
    _G.re = {
        on_application_entry = function(name, fn) callbacks.entry[#callbacks.entry + 1] = { name = name, fn = fn } end,
        on_pre_application_entry = function(name, fn) callbacks.entry[#callbacks.entry + 1] = { name = name, fn = fn } end,
        on_frame = function(fn) callbacks.frame[#callbacks.frame + 1] = fn end,
        on_draw_ui = function(fn) callbacks.ui[#callbacks.ui + 1] = fn end,
        on_config_save = function(fn) callbacks.config_save[#callbacks.config_save + 1] = fn end,
        on_script_reset = function(fn) callbacks.reset[#callbacks.reset + 1] = fn end,
    }

    M.files = {}
    _G.json = {
        load_file = function(name) return M.files[name] end,
        dump_file = function(name, t) M.files[name] = t return true end,
    }
    M.logs = {}
    _G.log = { info = function(s) M.logs[#M.logs + 1] = s end, warn = function() end, error = function() end }

    M.draw_calls = { line = 0, text = 0, rect = 0, circle = 0, texts = {} }
    _G.draw = {
        world_to_screen = function(v)
            if v.z < -100 then return nil end -- "behind the camera"
            return { x = 640 + v.x * 20, y = 360 - v.y * 20 }
        end,
        line = function() M.draw_calls.line = M.draw_calls.line + 1 end,
        text = function(s) M.draw_calls.text = M.draw_calls.text + 1 M.draw_calls.texts[#M.draw_calls.texts + 1] = s end,
        filled_rect = function() M.draw_calls.rect = M.draw_calls.rect + 1 end,
        outline_circle = function() M.draw_calls.circle = M.draw_calls.circle + 1 end,
    }

    -- imgui: tree nodes open, buttons pressed only when scripted via M.press[label] = true.
    M.press = {}
    M.inputs = {}
    M.imgui_texts = {}
    local function pressed(label)
        if M.press[label] then
            M.press[label] = nil
            return true
        end
        return false
    end
    _G.imgui = {
        tree_node = function() return true end,
        tree_pop = function() end,
        text = function(s) M.imgui_texts[#M.imgui_texts + 1] = s end,
        text_colored = function(s) M.imgui_texts[#M.imgui_texts + 1] = s end,
        separator = function() end,
        same_line = function() end,
        button = function(label) return pressed(label) end,
        input_text = function(label, v)
            local new_v = M.inputs[label]
            if new_v ~= nil then
                M.inputs[label] = nil
                return true, new_v
            end
            return false, v
        end,
        checkbox = function(_, v) return false, v end,
        slider_float = function(_, v) return false, v end,
        slider_int = function(_, v) return false, v end,
        drag_int = function(_, v) return false, v end,
        color_edit = function(_, v) return false, v end,
    }
    return world
end

-- Creates a character context with HP, a body GameObject, a Transform and a joint tree.
-- Fixed-size System.Array stand-in (get_size / get_element).
function M.array(items)
    return new("System.Array", {
        get_size = function() return #items end,
        get_element = function(_, i) return items[i + 1] end,
    })
end

-- spawner: optional {group, index, kind, category} returned by get_SpawnerID() (level data,
-- the same on every machine). The `_ID` field is a runtime counter, like in the game.
local next_runtime_index = 300
function M.make_character(type_name, pos, hp, spawner)
    local ctx = new(type_name, { pos = vec(pos.x, pos.y, pos.z), hp = hp, max_hp = hp, yaw = 0 })
    next_runtime_index = next_runtime_index + 1
    ctx.__fields._ID = context_id({ category = 2, kind = 0, group = 12, index = next_runtime_index })
    ctx.spawner = context_id(spawner)
    ctx.hitpoint = new("chainsaw.HitPoint", { owner = ctx })
    if classes["chainsaw.HitPoint"]:get_field(M.hp_field_name) then
        -- Field-backed HP: keep ctx.hp in sync with writes through set_field.
        setmetatable(ctx.hitpoint.__fields, {
            __newindex = function(_, k, v) if k == M.hp_field_name then ctx.hp = v end end,
        })
    end
    local body = new("via.GameObject", { owner = ctx })
    local transform = new("via.Transform", { owner = ctx })
    local joints, elems = {}, {}
    for i, name in ipairs(JOINT_NAMES) do
        joints[i] = new("via.Joint", { name = name, owner = ctx, offset = vec(0, i * 0.08, 0) })
    end
    for i, p in ipairs(JOINT_PARENTS) do
        if p > 0 then joints[i].parent = joints[p] end
        elems[i] = joints[i]
    end
    transform.joints = new("System.Array", {
        get_size = function() return #elems end,
        get_element = function(_, i) return elems[i + 1] end,
    })
    body.transform = transform
    body.name = type_name:match("([^.]+)Context$") or type_name
    body.cc = new("via.physics.CharacterController", { owner = ctx })
    body.motion = new("via.motion.Motion", {
        layers = { new("via.motion.TreeLayer", { bank = 100, motion = 1201, frame = 12.5 }) },
    })
    body.components = { transform, body.motion, body.cc }
    ctx.body = body
    return ctx
end

-- A pickup (chainsaw.DropItem) lying in the scene. Destroying its GameObject removes it.
function M.make_drop_item(item_id, pos, context, count)
    local owner = { pos = vec(pos.x, pos.y, pos.z) }
    local comp = new("chainsaw.DropItem")
    local go = new("via.GameObject", { owner = owner })
    go.transform = new("via.Transform", { owner = owner })
    go.components = { go.transform, comp }
    go.on_destroy = function() M.remove_drop(comp) end
    comp.go = go
    comp.__fields._ID = context_id(context)
    comp.__fields._ItemData = value_type({ ItemID = item_id, Count = count or 1 })
    comp.__fields._IsLostItem = false
    table.insert(M.world.drops, comp)
    return comp
end

-- An enemy's HateController: a component on its own GameObject, targeting `target_go`.
function M.make_hate_controller(name, pos, target_go)
    local owner = { pos = vec(pos.x, pos.y, pos.z) }
    local go = new("via.GameObject", { owner = owner, name = name })
    go.transform = new("via.Transform", { owner = owner })
    local hc = new("chainsaw.HateController", { go = go })
    if target_go ~= nil then
        hc.target = new("chainsaw.HateTargetInfo")
        hc.target.__fields._Target, hc.target.__fields._Hate = target_go, 3.5
    end
    local list = M.world.components["chainsaw.HateController"] or {}
    list[#list + 1] = hc
    M.world.components["chainsaw.HateController"] = list
    return hc
end

-- Runs the hooks installed on a method with REFramework's argument layout for a static method:
-- args[1] = VM context, args[2..] = parameters.
function M.fire_hooks(method_name, ...)
    local args = { "vmctx", ... }
    for _, h in ipairs(M.hooks[method_name] or {}) do
        local r = h.pre(args)
        assert(r == nil, "pre-hook must let the original run")
        assert(h.post("retval") == "retval", "post-hook must pass the return value through")
    end
end

-- The local player picks a drop item up: the game reports it, then removes the item.
function M.pickup(comp)
    local player = M.world.player
    M.fire_hooks("onAcceptPickup", player and player.__fields._ID, comp.__fields._ID)
    return M.remove_drop(comp)
end

-- The player picks it up / the area unloads it: it leaves the scene.
function M.remove_drop(comp)
    for i, d in ipairs(M.world.drops) do
        if d == comp then
            table.remove(M.world.drops, i)
            return true
        end
    end
    return false
end

return M
