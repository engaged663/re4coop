-- A small stand-in for REFramework's Lua environment (sdk, re, imgui, draw, json, log,
-- Vector3f, Quaternion) backed by a fake RE4 object graph. It mirrors the *shapes* the mod
-- relies on - type definitions with get_method/get_methods/is_a, managed objects with
-- :call(), GameObjects with components and a transform hierarchy, via.Joint local
-- rotations, via.Prefab loading, mesh resources and holders, Wwise/EPV components and
-- sdk.hook - so game.lua, puppet.lua, ui.lua, overlay.lua and re4coop.lua can be
-- exercised end to end outside the game.
--
-- It is not RE4: it only proves our code is internally consistent with the API shapes we
-- researched. Real-game verification is still required (see docs/TESTING.md).

local M = {}

local classes = {}
local objects = {} -- address -> managed object
M.SKIP_ORIGINAL = 1 -- sdk.PreHookResult.SKIP_ORIGINAL

-------------------------------------------------------------------------------
-- Type definitions and methods
-------------------------------------------------------------------------------

local function raw_arg(v)
    if type(v) == "table" and v.__addr then return v.__addr end
    if type(v) == "boolean" then return v and 1 or 0 end
    if v == nil then return 0 end
    return v
end

-- Runs sdk.hook pre/post functions around a method call, like REFramework does: args[1] is
-- the VM context, then `this` (instance methods only), then the parameters.
local function invoke(m, obj, ...)
    if m.hooks then
        local args = { 0 }
        if not m.static then args[2] = raw_arg(obj) end
        local base = #args
        for i = 1, select("#", ...) do args[base + i] = raw_arg((select(i, ...))) end
        local skip = false
        for _, h in ipairs(m.hooks) do
            if h.pre and h.pre(args) == M.SKIP_ORIGINAL then skip = true end
        end
        if skip then
            M.skipped = (M.skipped or 0) + 1
            return nil
        end
    end
    local r = m.fn(obj, ...)
    if m.hooks then
        for _, h in ipairs(m.hooks) do
            if h.post then r = h.post(r) end
        end
    end
    return r
end

-- key is the name REFramework's get_method accepts, e.g. "trigger(System.UInt32)";
-- get_name() returns the part before "(".
local function make_method(key, nparams, fn, param_types, opts)
    return {
        key = key, name = key:match("^([^(]+)") or key, nparams = nparams, fn = fn,
        param_types = param_types or {}, static = opts and opts.static or false, ret = opts and opts.ret or nil,
        call = function(self, obj, ...) return invoke(self, obj, ...) end,
        get_name = function(self) return self.name end,
        get_num_params = function(self) return self.nparams end,
        is_static = function(self) return self.static end,
        get_return_type = function(self)
            local r = self.ret
            if r == nil then return nil end -- not declared in this mock
            return { get_full_name = function() return r end }
        end,
        get_param_types = function(self)
            local out = {}
            for i, t in ipairs(self.param_types) do
                out[i] = {
                    get_full_name = function() return t end,
                    is_value_type = function() return M.value_types[t] == true end,
                }
            end
            return out
        end,
    }
end

M.value_types = { ["via.vec3"] = true, ["via.Quaternion"] = true }

local TypeDef = {}
TypeDef.__index = TypeDef

function TypeDef:get_full_name() return self.name end
function TypeDef:get_name() return self.name:match("([^.]+)$") end
function TypeDef:get_parent_type() return self.parent and classes[self.parent] or nil end
function TypeDef:is_value_type() return M.value_types[self.name] == true end
function TypeDef:is_a(other)
    local target = type(other) == "string" and other or other.name
    local td = self
    while td do
        if td.name == target then return true end
        td = td.parent and classes[td.parent] or nil
    end
    return false
end
function TypeDef:get_method(name)
    local td = self
    while td do
        local m = td.methods[name]
        if m then return m end
        if not name:find("(", 1, true) then
            for _, key in ipairs(td.method_order) do
                if td.methods[key].name == name then return td.methods[key] end
            end
        end
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
    for _, key in ipairs(self.method_order) do out[#out + 1] = self.methods[key] end
    return out
end
function TypeDef:get_fields()
    local out = {}
    for name in pairs(self.fields) do out[#out + 1] = self:get_field(name) end
    for name in pairs(self.static_values) do out[#out + 1] = self:get_field(name) end
    return out
end
function TypeDef:get_runtime_type() return { name = self.name } end

-- class(name, parent, { key = {nparams, fn, param_types, opts} }, { field = type })
local function class(name, parent, methods, fields)
    local td = setmetatable({ name = name, parent = parent, methods = {}, method_order = {}, fields = fields or {},
        static_values = {} }, TypeDef)
    local keys = {}
    for key in pairs(methods or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local spec = methods[key]
        td.methods[key] = make_method(key, spec[1], spec[2], spec[3], spec[4])
        td.method_order[#td.method_order + 1] = key
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

-------------------------------------------------------------------------------
-- Managed objects
-------------------------------------------------------------------------------

local Managed = {}
Managed.__index = Managed

local next_address = 0x10000

function Managed:get_type_definition() return classes[self.__type] end
function Managed:get_address() return self.__addr end
function Managed:add_ref() self.__refs = (self.__refs or 0) + 1 return self end
function Managed:add_ref_permanent() self.__permanent = true return self end
function Managed:release() self.__refs = (self.__refs or 0) - 1 end
function Managed:call(name, ...)
    local m = classes[self.__type]:get_method(name)
    if m == nil then error("mock: no method " .. name .. " on " .. self.__type) end
    return invoke(m, self, ...)
end
function Managed:get_field(name) return self.__fields[name] end
function Managed:set_field(name, v)
    if classes[self.__type]:get_field(name) == nil then error("mock: no field " .. name) end
    self.__fields[name] = v
end
-- Components keep their owner GameObject at 0x10; the game clears it on destroy.
function Managed:read_qword(offset)
    if offset == 0x10 and self.owner and self.owner.__type == "via.GameObject" then
        return self.owner.destroyed and 0 or self.owner.__addr
    end
    return 0
end

local function new(type_name, data)
    assert(classes[type_name], "mock: unknown class " .. type_name)
    next_address = next_address + 0x100
    local o = setmetatable(data or {}, Managed)
    o.__type = type_name
    o.__addr = next_address
    o.__fields = o.__fields or {}
    objects[o.__addr] = o
    return o
end
M.new = new

local function vec(x, y, z) return { x = x, y = y, z = z } end
local function quat(x, y, z, w) return { x = x, y = y, z = z, w = w } end
M.vec, M.quat = vec, quat

local function qmul(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end

local function qrot(q, v)
    local tx = 2 * (q.y * v.z - q.z * v.y)
    local ty = 2 * (q.z * v.x - q.x * v.z)
    local tz = 2 * (q.x * v.y - q.y * v.x)
    return vec(v.x + q.w * tx + (q.y * tz - q.z * ty), v.y + q.w * ty + (q.z * tx - q.x * tz),
        v.z + q.w * tz + (q.x * ty - q.y * tx))
end

local function array(list)
    return new("System.Array", { list = list })
end
-- Fixed-size System.Array stand-in (get_size / get_element / get_elements).
M.array = array

-- Stand-in for a REFramework ValueType (struct field value, e.g. chainsaw.ContextID).
local ValueType = {}
ValueType.__index = ValueType
function ValueType:get_field(name) return self.f[name] end
local function value_type(fields) return setmetatable({ f = fields }, ValueType) end
M.value_type = value_type

-- A boxed primitive, the way REFramework hands out elements of primitive arrays.
local Boxed = {}
Boxed.__index = Boxed
function Boxed:get_field(f)
    if f == "mValue" then return self.mValue end
    error("mock: boxed value has no field " .. tostring(f))
end
function Boxed:call(name)
    if name == "ToString()" or name == "ToString" then return tostring(self.mValue) end
    error("mock: boxed value has no method " .. tostring(name))
end
local function box(v) return setmetatable({ __boxed = true, mValue = v }, Boxed) end
M.box = box

-- A typed System.Array (UInt32[], Byte[], or of objects) with REFramework's element access:
-- arr[i] reads (boxed for primitives) and writes (unboxing what it is given).
local TypedArray = {}
local typed_methods = {}
function typed_methods:get_size() return rawget(self, "__size") end
function typed_methods:get_element(i)
    local v = rawget(self, "__items")[i + 1]
    if rawget(self, "__primitive") and v ~= nil then return box(v) end
    return v
end
function typed_methods:get_elements()
    local out = {}
    for i = 1, rawget(self, "__size") do out[i] = self:get_element(i - 1) end
    return out
end
function typed_methods:get_address() return rawget(self, "__addr") end
function typed_methods:get_type_definition() return classes["System.Array"] end
function typed_methods:call(name)
    if name == "get_Length" or name == "get_Count" then return rawget(self, "__size") end
    error("mock: array has no method " .. tostring(name))
end
TypedArray.__index = function(t, k)
    if type(k) == "number" then return typed_methods.get_element(t, k) end
    return typed_methods[k]
end
TypedArray.__newindex = function(t, k, v)
    if type(k) ~= "number" then error("mock: arrays have no fields") end
    if k < 0 or k >= rawget(t, "__size") then error("mock: index out of range") end
    if type(v) == "table" and v.__boxed then v = v.mValue end
    rawget(t, "__items")[k + 1] = v
end
local PRIMITIVE = { ["System.Byte"] = true, ["System.UInt32"] = true, ["System.Int32"] = true, ["System.Single"] = true }
local next_array_address = 0x7000000
local function typed_array(elem, items, size)
    next_array_address = next_array_address + 0x100
    items = items or {}
    return setmetatable({ __items = items, __size = size or #items, __elem = elem, __primitive = PRIMITIVE[elem] or false,
        __addr = next_array_address }, TypedArray)
end
M.typed_array = typed_array

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

-- Leon (ch0a0z0): the body skeleton, plus joints only the face and hair meshes have.
M.LEON_JOINTS = { "root", "Hip", "Spine_0", "Spine_1", "Spine_2", "Neck_0", "Head", "L_Shoulder",
    "L_UpperArm", "L_Forearm", "L_Hand", "L_Finger_0", "R_Shoulder", "R_UpperArm", "R_Forearm", "R_Hand",
    "R_WepHand", "L_Thigh", "L_Knee", "L_Foot", "R_Thigh", "R_Knee", "R_Foot", "L_ArmTwist" }
M.FACE_JOINTS = { "Neck_0", "Head", "Jaw", "L_Eye", "R_Eye" }
M.HAIR_JOINTS = { "Head", "Hair_0", "Hair_1" }
M.WEAPON_JOINTS = { "wp_root", "Slide", "Trigger", "vfx_muzzle" }

M.MESH = {
    body = "_chainsaw/character/ch/cha0/cha000/00/cha000_00.mesh",
    face = "_chainsaw/character/ch/cha0/cha000/10/cha000_10.mesh",
    hair = "_chainsaw/character/ch/cha0/cha000/20/cha000_20.mesh",
    jacket = "_chainsaw/character/ch/cha0/cha002/00/cha002_00.mesh",
    sg09 = "_chainsaw/character/wp/wp40/wp4000/00/wp4000_00.mesh",
}
M.MDF = {
    body = "_chainsaw/character/ch/cha0/cha000/00/cha000_00.mdf2",
    body_dirty = "_chainsaw/character/ch/cha0/cha000/00/cha000_00b.mdf2",
    face = "_chainsaw/character/ch/cha0/cha000/10/cha000_10.mdf2",
    hair = "_chainsaw/character/ch/cha0/cha000/20/cha000_20.mdf2",
    jacket = "_chainsaw/character/ch/cha0/cha002/00/cha002_00.mdf2",
    sg09 = "_chainsaw/character/wp/wp40/wp4000/00/wp4000_00.mdf2",
}
M.PREFAB = {
    leon_body = "_chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb",
    ada_body = "_mercenaries/appsystem/character/ch3a8z0/ch3a8z0_body.pfb",
    sg09 = "_chainsaw/appsystem/prefab/weapon/wp4000.pfb",
    sg09_mc = "_mercenaries/appsystem/prefab/weapon/wp4000_mc.pfb",
    muzzle = "_chainsaw/vfx/provider/epv_system/epv_muzzleflash/epve_0015_muzzleflash_0000.pfb",
}

function M.install(opts)
    opts = opts or {}
    classes = {}
    M.classes = classes
    objects = {}
    local world = {
        singletons = {}, enemies = {}, drops = {}, components = {}, gui_event = false, created = {}, gos = {},
        sounds = {}, effects = {}, shots = {}, resources = {}, spawned = {}, item_flags = {}, time_scale = 1.0,
    }
    M.world = world

    class("System.Object", nil, {})
    class("System.Array", "System.Object", {
        get_size = { 0, function(self) return #self.list end },
        get_element = { 1, function(self, i) return self.list[i + 1] end },
        get_elements = { 0, function(self) return self.list end },
    })
    -- REFramework exposes arrays with these as plain methods too.
    Managed.get_size = function(self) return #self.list end
    Managed.get_element = function(self, i) return self.list[i + 1] end
    Managed.get_elements = function(self) return self.list end

    class("via.Joint", "System.Object", {
        get_Name = { 0, function(self) return self.name end },
        get_Parent = { 0, function(self) return self.parent end },
        get_LocalRotation = { 0, function(self) local q = self.lrot return quat(q.x, q.y, q.z, q.w) end },
        set_LocalRotation = { 1, function(self, q) self.lrot = quat(q.x, q.y, q.z, q.w) self.writes = (self.writes or 0) + 1 end },
        get_LocalPosition = { 0, function(self) local p = self.lpos return vec(p.x, p.y, p.z) end },
        set_LocalPosition = { 1, function(self, p) self.lpos = vec(p.x, p.y, p.z) end },
        get_Position = { 0, function(self)
            local tf = self.owner_tf
            local p = M.world_pos(tf)
            return vec(p.x + self.offset.x, p.y + self.offset.y, p.z + self.offset.z)
        end },
    })

    class("via.Component", "System.Object", {
        get_GameObject = { 0, function(self) return self.owner end },
        get_Enabled = { 0, function(self) return self.enabled ~= false end },
        set_Enabled = { 1, function(self, v) if not self.locked then self.enabled = v end end },
        [".ctor()"] = { 0, function() end },
    })
    class("via.Transform", "via.Component", {
        get_Position = { 0, function(self) local p = M.world_pos(self) return vec(p.x, p.y, p.z) end },
        set_Position = { 1, function(self, v) M.set_world_pos(self, v) end },
        get_Rotation = { 0, function(self) local q = M.world_rot(self) return quat(q.x, q.y, q.z, q.w) end },
        set_Rotation = { 1, function(self, q) M.set_world_rot(self, q) end },
        get_LocalPosition = { 0, function(self) return vec(self.lpos.x, self.lpos.y, self.lpos.z) end },
        set_LocalPosition = { 1, function(self, v) self.lpos = vec(v.x, v.y, v.z) end },
        get_LocalRotation = { 0, function(self) local q = self.lrot return quat(q.x, q.y, q.z, q.w) end },
        set_LocalRotation = { 1, function(self, q) self.lrot = quat(q.x, q.y, q.z, q.w) end },
        get_Joints = { 0, function(self) return array(self.joints) end },
        get_Parent = { 0, function(self) return self.parent end },
        set_Parent = { 1, function(self, p) M.set_parent(self, p) end },
        get_Child = { 0, function(self) return self.children[1] end },
        get_Next = { 0, function(self)
            local siblings = self.parent and self.parent.children or {}
            for i, c in ipairs(siblings) do
                if c == self then return siblings[i + 1] end
            end
            return nil
        end },
        get_ParentJoint = { 0, function(self) return self.parent_joint or "" end },
        set_ParentJoint = { 1, function(self, name) self.parent_joint = name end },
        get_SameJointsConstraint = { 0, function(self) return self.same_joints == true end },
        set_SameJointsConstraint = { 1, function(self, v) self.same_joints = v end },
    })
    class("via.physics.CharacterController", "via.Component", {
        warp = { 0, function(self) self.owner.warped = (self.owner.warped or 0) + 1 if self.ctx then self.ctx.warped = (self.ctx.warped or 0) + 1 end end },
    })
    class("via.physics.Colliders", "via.Component", {})
    class("via.motion.TreeLayer", "System.Object", {
        get_MotionBankID = { 0, function(self) return self.bank end },
        get_MotionID = { 0, function(self) return self.motion end },
        get_Frame = { 0, function(self) return self.frame end },
        ["changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"] = {
            6, function(self, bank, id, frame) self.bank, self.motion, self.frame = bank, id, frame
                self.changes = (self.changes or 0) + 1 end,
            { "System.UInt32", "System.UInt32", "System.Single", "System.Single", "via.motion.InterpolationMode",
                "via.motion.InterpolationCurve" } },
    })
    class("via.motion.Motion", "via.Component", {
        getLayer = { 1, function(self, i) return (self.layers or {})[i + 1] end, { "System.UInt32" } },
        getLayerCount = { 0, function(self) return #(self.layers or {}) end },
    })
    class("via.motion.MotionFsm2", "via.Component", {})
    class("via.motion.Chain", "via.Component", {})
    class("via.behaviortree.BehaviorTree", "via.Component", {})
    class("chainsaw.CharacterBodyLogic", "via.Component", {})
    class("chainsaw.PlayerEquipment", "via.Component", {})
    class("chainsaw.Gun", "via.Component", {
        shoot = { 0, function(self) world.shots[#world.shots + 1] = self.owner.name end },
        get_CurrentAmmoCount = { 0, function(self) return self.ammo or 15 end },
    })
    class("via.wwise.RequestInfo", "System.Object", {})
    class("via.wwise.WwiseContainer", "via.Component", {
        ["trigger(System.UInt32)"] = { 1, function(self, id)
            world.sounds[#world.sounds + 1] = { go = self.owner.name, id = id, comp = self }
        end, { "System.UInt32" } },
        ["trigger(System.UInt32, via.GameObject)"] = { 2, function(self, id, target)
            world.sounds[#world.sounds + 1] = { go = self.owner.name, id = id, target = target and target.name, comp = self }
        end, { "System.UInt32", "via.GameObject" } },
        ["trigger(via.GameObject, System.UInt32, via.GameObject, System.UInt32, via.wwise.RequestInfo, System.Boolean, System.Boolean, System.Boolean, System.Int32)"] = {
            9, function(self, target, id, pos_go, bone, req)
                world.sounds[#world.sounds + 1] = { go = self.owner.name, id = id, target = target and target.name, bone = bone, full = true, comp = self }
            end, { "via.GameObject", "System.UInt32", "via.GameObject", "System.UInt32", "via.wwise.RequestInfo",
                "System.Boolean", "System.Boolean", "System.Boolean", "System.Int32" } },
        stopAll = { 0, function() end },
    })
    class("chainsaw.WwiseContainerApp", "via.wwise.WwiseContainer", {})
    class("via.effect.script.EPVStandard", "via.Component", {
        ["requestEffect(System.UInt32, System.UInt32)"] = { 2, function(self, container, element)
            world.effects[#world.effects + 1] = { go = self.owner.name, container = container, element = element, comp = self }
        end, { "System.UInt32", "System.UInt32" } },
        ["requestEffect(System.Collections.Generic.IEnumerable`1<via.effect.script.EPVStandardData.Element>, via.GameObject)"] = {
            2, function(self) world.effects[#world.effects + 1] = { go = self.owner.name, list = true } end,
            { "System.Collections.Generic.IEnumerable`1<via.effect.script.EPVStandardData.Element>", "via.GameObject" } },
    })
    class("via.render.MeshResourceHolder", "System.Object", {
        get_ResourcePath = { 0, function(self) return self.path end },
        ["ToString()"] = { 0, function(self) return "MeshResourceHolder[@" .. self.path .. "]" end },
    })
    class("via.render.MeshMaterialResourceHolder", "System.Object", {
        get_ResourcePath = { 0, function(self) return self.path end },
        ["ToString()"] = { 0, function(self) return "MeshMaterialResourceHolder[@" .. self.path .. "]" end },
    })
    class("via.render.Mesh", "via.Component", {
        getMesh = { 0, function(self)
            return self.mesh_path and new("via.render.MeshResourceHolder", { path = self.mesh_path }) or nil
        end },
        setMesh = { 1, function(self, holder)
            self.mesh_path = holder.path
            local tf = self.owner.transform
            local skeleton = M.mesh_skeletons[holder.path]
            if skeleton and #tf.joints == 0 then M.add_joints(tf, skeleton) end
        end },
        get_Material = { 0, function(self)
            return self.mdf_path and new("via.render.MeshMaterialResourceHolder", { path = self.mdf_path }) or nil
        end },
        set_Material = { 1, function(self, holder) self.mdf_path = holder.path end },
    })

    class("via.GameObject", "System.Object", {
        get_Name = { 0, function(self) return self.name end },
        set_Name = { 1, function(self, name) self.name = name end },
        get_Transform = { 0, function(self) return self.transform end },
        ["getComponent(System.Type)"] = { 1, function(self, t)
            for _, c in ipairs(self.components) do
                if classes[c.__type]:is_a(t.name) then return c end
            end
            return nil
        end },
        ["createComponent(System.Type)"] = { 1, function(self, t)
            return M.add_component(self, t.name)
        end },
        get_Components = { 0, function(self) return array(self.components) end },
        get_Draw = { 0, function(self) return M.drawn(self) end },
        get_DrawSelf = { 0, function(self) return self.draw_self ~= false end },
        set_DrawSelf = { 1, function(self, v) self.draw_self = v end },
        get_UpdateSelf = { 0, function(self) return self.update_self ~= false end },
        set_UpdateSelf = { 1, function(self, v) self.update_self = v end },
        -- RE Engine prints a GameObject as "name@<guid>" (the GUID from the scene file).
        ["ToString()"] = { 0, function(self) return ("%s@%s]"):format(self.name or "", self.guid or "") end },
        destroy = { 1, function(self, go) M.destroy(go or self) end },
        [".ctor"] = { 0, function() end },
        ["create(System.String)"] = { 1, function(_, name)
            local go = M.make_go(name)
            world.created[#world.created + 1] = go
            return go
        end, { "System.String" }, { static = true } },
    })

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

    -- Hits: HitController.callbackDamageHit(DamageInfo) applies damage to its character.
    local info_fields = { "Damage", "Wince", "Break", "Stopping", "DamageDir", "AttackOwnerObject", "WeaponID",
        "IsCritical", "IsKill" }
    local info_methods = {
        copy = { 1, function(self, src)
            for _, f in ipairs(info_fields) do self.data[f] = src.data[f] end
        end },
    }
    for _, f in ipairs(info_fields) do
        info_methods["get_" .. f] = { 0, function(self) return self.data[f] end }
        info_methods["set_" .. f] = { 1, function(self, v) self.data[f] = v end }
    end
    class("chainsaw.HitController.DamageInfo", "System.Object", info_methods)
    class("chainsaw.HitController", "via.Component", {
        get_DamageOwner = { 0, function(self) return self.damage_owner end },
        get_ParentHitController = { 0, function(self) return self.parent_hc end },
        callbackDamageHit = { 1, function(self, info)
            local ctx = self.ctx
            self.received = self.received or {}
            self.received[#self.received + 1] = { damage = info.data.Damage, wince = info.data.Wince,
                attacker = info.data.AttackOwnerObject, critical = info.data.IsCritical }
            if M.deferred_damage then
                M.pending_damage = { owner = ctx, amount = info.data.Damage or 0 }
            elseif ctx ~= nil then
                ctx.hp = math.max(0, ctx.hp - (info.data.Damage or 0))
            end
        end, { "chainsaw.HitController.DamageInfo" } },
    })
    -- Random drops and spawning items.
    class("chainsaw.Item", "System.Object", {
        setItemId = { 1, function(self, v) self.item_id = v end },
        setItemCount = { 1, function(self, v) self.count = v end },
    })
    class("chainsaw.DropItemManager.GenerateItemOption", "System.Object", {},
        { Falldown = "System.Boolean", Effect = "System.Boolean", NeedColCheck = "System.Boolean" })
    class("chainsaw.DropItemManager", "System.Object", {
        -- The original rolls `next_item` and drops it next to the character (or at `drop_pos`).
        generateRandomDrop = { 6, function(self, droptype, cc)
            local base = cc and cc.pos or self.drop_pos or vec(0, 0, 0)
            self.last_drop = M.make_drop_item(self.next_item or 112800000, { x = base.x + 0.5, y = base.y, z = base.z },
                nil, 1)
        end, { "chainsaw.RandomDrop.DropType", "chainsaw.CharacterContext", "via.vec3", "chainsaw.StageID",
            "chainsaw.Context", "chainsaw.DropItemManager.GenerateItemOption" } },
        ["requestGenerateLostItem(chainsaw.Item, via.vec3, chainsaw.StageID, chainsaw.DropItemManager.GenerateItemOption)"] = {
            4, function(_, item, pos, stage, opt)
                world.spawned[#world.spawned + 1] = { item_id = item.item_id, count = item.count, pos = pos, stage = stage,
                    falldown = opt.__fields.Falldown }
                if not M.spawn_does_nothing then
                    M.make_drop_item(item.item_id, pos, { category = 3, kind = 0, group = stage or 0, index = #world.spawned },
                        item.count)
                end
            end },
    })
    -- Inventory "item obtained" flags.
    class("chainsaw.InventoryManager", "System.Object", {
        getItemGetFlag = { 1, function(_, id) return world.item_flags[id] == true end },
    })
    -- Gimmicks.
    class("chainsaw.GimmickManager", "System.Object", { pushDirtyList = { 1, function() end } })
    class("chainsaw.GmContextBox", "System.Object", { get_ID = { 0, function(self) return self.id end } })

    local ctx_methods = {
        get_Position = { 0, function(self) return vec(self.pos.x, self.pos.y, self.pos.z) end },
        get_HitPoint = { 0, function(self) return self.hitpoint end },
        get_BodyGameObject = { 0, function(self) return self.body end },
        get_HeadGameObject = { 0, function(self) return self.head end },
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
    class("chainsaw.Ch3a8z0Context", "chainsaw.PartnerBaseContext", {}) -- an NPC partner

    class("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>", "System.Object", {
        get_Count = { 0, function(self) return #world.enemies end },
        get_Item = { 1, function(self, i) return world.enemies[i + 1] end },
    })
    local enemy_list = new("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>")
    world.enemy_list = enemy_list

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

    -- Prefabs: files that "exist" are the keys of M.prefab_files; loading takes a few polls.
    class("via.Prefab", "System.Object", {
        set_Path = { 1, function(self, p) self.path = p end },
        get_Path = { 0, function(self) return self.path end },
        get_Exist = { 0, function(self) return M.prefab_files[self.path] ~= nil end },
        set_Standby = { 1, function(self, v) self.standby = v self.standby_frame = M.frame_count end },
        get_Ready = { 0, function(self)
            if not self.standby or M.prefab_files[self.path] == nil then return false end
            return M.frame_count - self.standby_frame >= (M.prefab_load_frames or 1)
        end },
        ["instantiate(via.vec3)"] = { 1, function(self, pos)
            local build = M.prefab_files[self.path]
            if build == nil then return nil end
            local go = build(pos)
            world.created[#world.created + 1] = go
            world.instantiated = world.instantiated or {}
            world.instantiated[#world.instantiated + 1] = self.path
            return go
        end, { "via.vec3" } },
    })
    class("chainsaw.DropItem", "via.Component", {
        -- Level-placed items keep ItemID 0 in _ItemData; getItemID() knows the real one.
        getItemID = { 0, function(self) return self.real_item_id or self.__fields._ItemData.f.ItemID end },
        -- Static pickup callbacks (the game calls them; the mod only hooks them).
        onAcceptPickup = { 2, function() end, { "chainsaw.ContextID", "chainsaw.ContextID" }, { static = true } },
        onAcceptOccupied = { 3, function() end, { "chainsaw.ContextID", "chainsaw.ContextID", "System.Int32" },
            { static = true } },
        getStage = { 0, function(self) return self.stage or 40210 end },
    }, { _ID = "chainsaw.ContextID", _ItemData = "chainsaw.DropItemContext.SaveData", _IsLostItem = "System.Boolean" })
    class("chainsaw.HateTargetInfo", "System.Object", {}, { _Target = "via.GameObject", _Hate = "System.Single" })
    class("chainsaw.HateController", "via.Component", {
        get_CurrentTarget = { 0, function(self) return self.target end },
        get_FindState = { 0, function() return 2 end },
        get_TotalAttention = { 0, function() return 0.5 end },
    })
    class("chainsaw.StageIdentifier", "System.Object", {}, { _StageID = "chainsaw.StageID", _AreaNo = "System.Int32" })
    enum("chainsaw.CharacterKindID", { ch0a0z0 = 100000, ch3a8z0 = 380000, ch1c0z0 = 1120000 })
    enum("chainsaw.CharacterUsePurposeFlag", { None = 0, Player = 1, Partner = 2 })
    enum("chainsaw.ContextID.EntityCategory", { Character = 0, Gimmick = 1, DropItem = 2, StaticItem = 3 })
    enum("chainsaw.StageID", { st40_200 = 40200, st40_210 = 40210 })
    class("via.Scene", "System.Object", {
        get_TimeScale = { 0, function() return world.time_scale end },
        ["set_TimeScale(System.Single)"] = { 1, function(_, v) world.time_scale = v end, { "System.Single" } },
        ["findGameObject(System.String)"] = { 1, function(_, name)
            for _, go in ipairs(world.gos) do
                if go.name == name and not go.destroyed then return go end
            end
            return nil
        end, { "System.String" } },
        ["findComponents(System.Type)"] = { 1, function(_, t)
            local comps = {}
            if t.name == "chainsaw.DropItem" then
                for _, d in ipairs(world.drops) do comps[#comps + 1] = d end
            end
            for _, c in ipairs(world.components[t.name] or {}) do comps[#comps + 1] = c end
            return array(comps)
        end, { "System.Type" } },
    })
    class("via.SceneManager", "System.Object", {
        ["get_CurrentScene()"] = { 0, function() return world.scene end },
    })
    world.scene = new("via.Scene")
    world.scene_manager = new("via.SceneManager")

    world.singletons["chainsaw.CharacterManager"] = new("chainsaw.CharacterManager")
    world.singletons["chainsaw.GuiManager"] = new("chainsaw.GuiManager")
    world.singletons["chainsaw.CampaignManager"] = new("chainsaw.CampaignManager")
    world.singletons["chainsaw.DropItemManager"] = new("chainsaw.DropItemManager")
    world.singletons["chainsaw.InventoryManager"] = new("chainsaw.InventoryManager")
    world.singletons["chainsaw.GimmickManager"] = new("chainsaw.GimmickManager")

    if not opts.no_world then M.install_world(world, opts) end

    M.prefab_files = {
        [M.PREFAB.leon_body] = function(pos) return M.build_body_prefab(pos) end,
        [M.PREFAB.ada_body] = function(pos) return M.build_body_prefab(pos, "ch3a8z0_body") end,
        [M.PREFAB.sg09] = function(pos) return M.build_weapon("wp4000", pos) end,
        [M.PREFAB.sg09_mc] = function(pos) return M.build_weapon("wp4000_mc", pos) end,
        [M.PREFAB.muzzle] = function(pos)
            local go = M.make_go("epve_0015_muzzleflash", { wpos = vec(pos.x, pos.y, pos.z) })
            world.flashes = (world.flashes or 0) + 1
            return go
        end,
    }
    M.prefab_load_frames = 1 -- loading finishes in the background after this many frames
    M.frame_count = 0
    M.mesh_skeletons = {
        [M.MESH.body] = M.LEON_JOINTS, [M.MESH.face] = M.FACE_JOINTS, [M.MESH.hair] = M.HAIR_JOINTS,
        [M.MESH.jacket] = { "Spine_1", "Spine_2", "Jacket_0" }, [M.MESH.sg09] = M.WEAPON_JOINTS,
    }
    M.missing_resources = {}

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
        call_native_func = function(obj, td, name, ...)
            return td:get_method(name).fn(obj, ...)
        end,
        call_object_func = function(obj, name, ...) return obj:call(name, ...) end,
        typeof = function(name) return { name = name } end,
        create_instance = function(name)
            local o = new(name)
            if name == "chainsaw.HitController.DamageInfo" then o.data = {} end
            return o
        end,
        PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = M.SKIP_ORIGINAL },
        create_resource = function(type_name, path)
            if M.missing_resources[path] then return nil end
            world.resources[#world.resources + 1] = path
            local res = { type = type_name, path = path }
            res.add_ref = function(self) return self end
            res.release = function() end
            res.create_holder = function(_, holder_type) return new(holder_type, { path = path }) end
            return res
        end,
        hook = function(method, pre, post)
            method.hooks = method.hooks or {}
            method.hooks[#method.hooks + 1] = { pre = pre, post = post }
            M.hooks[method.name] = M.hooks[method.name] or {}
            table.insert(M.hooks[method.name], { pre = pre, post = post })
        end,
        to_int64 = function(v)
            if type(v) == "table" and v.__addr then return v.__addr end
            if type(v) == "boolean" then return v and 1 or 0 end
            return math.tointeger(v) or 0
        end,
        to_float = function(v) return v end,
        to_managed_object = function(addr)
            if type(addr) == "table" then return addr end -- value stand-ins passed as is
            return objects[addr]
        end,
        to_valuetype = function(addr)
            if type(addr) == "table" then return addr end
            return objects[addr]
        end,
        create_managed_array = function(elem, n)
            local items = {}
            if PRIMITIVE[elem] then for i = 1, n do items[i] = 0 end end
            return typed_array(elem, items, n)
        end,
        create_int32 = function(v) return box(v) end,
        create_uint32 = function(v) return box(v & 0xFFFFFFFF) end,
        create_byte = function(v) return box(v & 0xFF) end,
        set_native_field = function(obj, _, name, v)
            if obj.__fields ~= nil and classes[obj.__type] and classes[obj.__type]:get_field(name) then
                obj.__fields[name] = v
            else
                rawset(obj, name, v)
            end
        end,
        is_managed_object = function(v)
            if type(v) == "table" then return v.__addr ~= nil end
            local o = objects[v]
            return o ~= nil and not o.destroyed
        end,
    }
    M.hooks = {}
    if opts.no_hook then _G.sdk.hook = nil end
    _G.Vector3f = { new = function(x, y, z) return vec(x, y, z) end }
    _G.Quaternion = { new = function(w, x, y, z) return quat(x, y, z, w) end }

    local callbacks = { entry = {}, frame = {}, ui = {}, config_save = {}, reset = {} }
    M.callbacks = callbacks
    _G.re = {
        on_application_entry = function(name, fn) callbacks.entry[#callbacks.entry + 1] = { name = name, fn = fn } end,
        on_pre_application_entry = function(name, fn) callbacks.entry[#callbacks.entry + 1] = { name = name, fn = fn, pre = true } end,
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

-------------------------------------------------------------------------------
-- GameObjects, transforms, joints
-------------------------------------------------------------------------------

local IDENTITY = { x = 0, y = 0, z = 0, w = 1 }

-- opts: { link = table with x,y,z used as the world position (a context's pos), wpos, wrot }
function M.make_go(name, opts)
    opts = opts or {}
    local go = new("via.GameObject", { name = name, components = {}, draw_self = true })
    local tf = new("via.Transform", {
        owner = go, children = {}, joints = {}, lpos = vec(0, 0, 0), lrot = quat(0, 0, 0, 1),
        link = opts.link, wpos = opts.wpos or vec(0, 0, 0), wrot = opts.wrot or quat(0, 0, 0, 1),
    })
    go.transform = tf
    go.components[1] = tf
    M.world.gos[#M.world.gos + 1] = go
    return go
end

function M.add_component(go, type_name, data)
    local c = new(type_name, data or {})
    c.owner = go
    go.components[#go.components + 1] = c
    return c
end

function M.set_parent(tf, parent)
    if tf.parent then
        for i, c in ipairs(tf.parent.children) do
            if c == tf then table.remove(tf.parent.children, i) break end
        end
    end
    tf.parent = parent
    if parent then parent.children[#parent.children + 1] = tf end
end

function M.world_rot(tf)
    if tf.parent == nil then return tf.wrot end
    return qmul(M.world_rot(tf.parent), tf.lrot)
end

function M.world_pos(tf)
    if tf.parent == nil then return tf.link or tf.wpos end
    local pp = M.world_pos(tf.parent)
    local o = qrot(M.world_rot(tf.parent), tf.lpos)
    return vec(pp.x + o.x, pp.y + o.y, pp.z + o.z)
end

function M.set_world_pos(tf, v)
    if tf.parent == nil then
        local target = tf.link or tf.wpos
        target.x, target.y, target.z = v.x, v.y, v.z
    else
        local pp = M.world_pos(tf.parent)
        local pr = M.world_rot(tf.parent)
        tf.lpos = qrot({ x = -pr.x, y = -pr.y, z = -pr.z, w = pr.w }, vec(v.x - pp.x, v.y - pp.y, v.z - pp.z))
    end
end

function M.set_world_rot(tf, q)
    if tf.parent == nil then
        tf.wrot = quat(q.x, q.y, q.z, q.w)
    else
        local pr = M.world_rot(tf.parent)
        tf.lrot = qmul({ x = -pr.x, y = -pr.y, z = -pr.z, w = pr.w }, q)
    end
end

function M.drawn(go)
    if go.draw_self == false or go.destroyed then return false end
    local p = go.transform.parent
    return p == nil or M.drawn(p.owner)
end

-- Destroyed objects leave the hierarchy (and so the scene), children included.
function M.destroy(go)
    if go.destroyed then return end
    go.destroyed = true
    if go.on_destroy then go.on_destroy() end
    local children = {}
    for i, c in ipairs(go.transform.children) do children[i] = c end
    for _, c in ipairs(children) do M.destroy(c.owner) end
    M.set_parent(go.transform, nil)
end

function M.add_joints(tf, names, parents)
    local list = {}
    for i, name in ipairs(names) do
        list[i] = new("via.Joint", { name = name, owner_tf = tf, lrot = quat(0, 0, 0, 1), lpos = vec(0, 0, 0),
            offset = vec(0, i * 0.08, 0) })
    end
    for i, p in ipairs(parents or {}) do
        if p > 0 then list[i].parent = list[p] end
    end
    tf.joints = list
    return list
end

function M.child(parent_go, name, opts)
    opts = opts or {}
    local go = M.make_go(name)
    M.set_parent(go.transform, parent_go.transform)
    go.transform.parent_joint = opts.joint or ""
    go.transform.same_joints = opts.same_joints or false
    if opts.lpos then go.transform.lpos = opts.lpos end
    if opts.lrot then go.transform.lrot = opts.lrot end
    if opts.mesh then
        local mesh = M.add_component(go, "via.render.Mesh")
        mesh.mesh_path, mesh.mdf_path = opts.mesh, opts.mdf
        local skeleton = M.mesh_skeletons[opts.mesh]
        if skeleton then M.add_joints(go.transform, skeleton) end
    end
    return go
end

-- "Animation": every GameObject whose Motion component is enabled gets its joints set to
-- their animated rotation (anim_rot) or identity, like the engine's motion update does.
function M.update_motion()
    M.frame_count = M.frame_count + 1
    for _, go in ipairs(M.world.gos) do
        if not go.destroyed then
            for _, c in ipairs(go.components) do
                if c.__type == "via.motion.Motion" and c.enabled ~= false then
                    for _, j in ipairs(go.transform.joints) do
                        local a = j.anim_rot or IDENTITY
                        j.lrot = quat(a.x, a.y, a.z, a.w)
                    end
                end
            end
        end
    end
end

-- One game frame in REFramework's order: behaviour updates, animation, end of frame,
-- presentation, menu.
function M.run_frame()
    for _, cb in ipairs(M.callbacks.entry) do
        if cb.name == "LateUpdateBehavior" then cb.fn() end
    end
    M.update_motion()
    for _, cb in ipairs(M.callbacks.entry) do
        if cb.name == "PrepareRendering" then cb.fn() end
    end
    for _, cb in ipairs(M.callbacks.frame) do cb() end
    for _, cb in ipairs(M.callbacks.ui) do cb() end
end

-------------------------------------------------------------------------------
-- Characters
-------------------------------------------------------------------------------

local function add_hitpoint(ctx)
    ctx.hitpoint = new("chainsaw.HitPoint", { owner = ctx })
    if classes["chainsaw.HitPoint"]:get_field(M.hp_field_name) then
        -- Field-backed HP: keep ctx.hp in sync with writes through set_field.
        setmetatable(ctx.hitpoint.__fields, {
            __newindex = function(_, k, v) if k == M.hp_field_name then ctx.hp = v end end,
        })
    end
end

-- Characters get a runtime `_ID` (group 12, like in the game) and a motion layer.
local next_runtime_index = 300
local function runtime_id(ctx)
    next_runtime_index = next_runtime_index + 1
    ctx.__fields._ID = context_id({ category = 2, kind = 0, group = 12, index = next_runtime_index })
end

local function motion_layers()
    return { new("via.motion.TreeLayer", { bank = 100, motion = 1201, frame = 12.5 }) }
end

-- Creates a character context with HP, a body GameObject, a Transform and a joint tree
-- (enemies, simple players). spawner: optional {group, index, kind, category} returned by
-- get_SpawnerID() (level data, the same on every machine).
function M.make_character(type_name, pos, hp, spawner)
    local ctx = new(type_name, { pos = vec(pos.x, pos.y, pos.z), hp = hp, max_hp = hp, yaw = 0 })
    runtime_id(ctx)
    ctx.spawner = context_id(spawner)
    add_hitpoint(ctx)
    local body = M.make_go(type_name:match("Ch%w+") and (type_name:match("(Ch%w+)Context") .. "_body") or "body",
        { link = ctx.pos })
    M.add_joints(body.transform, JOINT_NAMES, JOINT_PARENTS)
    M.add_component(body, "via.motion.Motion", { layers = motion_layers() })
    M.add_component(body, "via.physics.CharacterController", { ctx = ctx })
    M.add_component(body, "chainsaw.HitController", { ctx = ctx })
    ctx.body = body
    ctx.head = M.make_go(type_name:match("(Ch%w+)Context") and (type_name:match("(Ch%w+)Context") .. "_head") or "head")
    return ctx
end

-- The local player as RE4 builds Leon: body object with the skeleton and sound container,
-- costume parts (body, face, hair) following its joints, the SG-09 R in the right hand, and
-- the logic "head" object.
function M.make_player(pos, opts)
    opts = opts or {}
    local ctx = new("chainsaw.PlayerBaseContext", { pos = vec(pos.x, pos.y, pos.z), hp = 1200, max_hp = 1200 })
    runtime_id(ctx)
    add_hitpoint(ctx)
    local body = M.make_go(opts.body_name or "ch0a0z0_body", { link = ctx.pos })
    M.add_joints(body.transform, M.LEON_JOINTS)
    M.add_component(body, "via.motion.Motion", { layers = motion_layers() })
    M.add_component(body, "chainsaw.CharacterBodyLogic")
    M.add_component(body, "via.physics.CharacterController", { ctx = ctx })
    ctx.sound = M.add_component(body, "chainsaw.WwiseContainerApp")
    M.child(body, "cha000_00", { mesh = M.MESH.body, mdf = M.MDF.body_dirty, same_joints = true })
    M.child(body, "cha000_10", { mesh = M.MESH.face, mdf = M.MDF.face, same_joints = true })
    M.child(body, "cha000_20", { mesh = M.MESH.hair, mdf = M.MDF.hair, same_joints = true })
    local wp = M.child(body, "wp4000", { joint = "R_WepHand", mesh = M.MESH.sg09, mdf = M.MDF.sg09,
        lpos = vec(0.02, 0.01, 0.12), lrot = quat(0, 0.7071068, 0, 0.7071068) })
    ctx.gun = M.add_component(wp, "chainsaw.Gun")
    ctx.gun_sound = M.add_component(wp, "chainsaw.WwiseContainerApp")
    ctx.gun_effect = M.add_component(wp, "via.effect.script.EPVStandard")
    ctx.weapon = wp
    local head = M.make_go(opts.head_name or "ch0a0z0_head")
    M.add_component(head, "chainsaw.PlayerEquipment")
    ctx.voice = M.add_component(head, "via.wwise.WwiseContainer")
    ctx.body, ctx.head = body, head
    -- A recognisable animated pose: every joint turned a little around a different axis.
    for i, j in ipairs(body.transform.joints) do
        local a = 0.05 * i
        j.anim_rot = quat(math.sin(a) * 0.6, math.sin(a) * 0.8, 0, math.cos(a))
        j.lrot = quat(j.anim_rot.x, j.anim_rot.y, j.anim_rot.z, j.anim_rot.w)
    end
    body.transform.joints[2].lpos = vec(0, 0.98, 0.01) -- Hip height
    return ctx
end

-- What via.Prefab.instantiate builds for <id>_body.pfb: the skeleton with animation, logic
-- and physics components, and the default costume (body + a jacket).
function M.build_body_prefab(pos, name)
    local body = M.make_go(name or "ch0a0z0_body", { wpos = vec(pos.x, pos.y, pos.z) })
    M.add_joints(body.transform, M.LEON_JOINTS)
    M.add_component(body, "via.motion.Motion", { locked = M.motion_locked })
    M.add_component(body, "via.motion.MotionFsm2")
    M.add_component(body, "via.behaviortree.BehaviorTree")
    M.add_component(body, "via.physics.Colliders")
    M.add_component(body, "chainsaw.CharacterBodyLogic")
    M.add_component(body, "chainsaw.WwiseContainerApp")
    M.add_component(body, "via.motion.Chain")
    M.child(body, "cha000_00", { mesh = M.MESH.body, mdf = M.MDF.body, same_joints = true })
    M.child(body, "cha002_00", { mesh = M.MESH.jacket, mdf = M.MDF.jacket, same_joints = true })
    return body
end

function M.build_weapon(name, pos)
    local go = M.make_go(name, { wpos = vec(pos.x, pos.y, pos.z) })
    local mesh = M.add_component(go, "via.render.Mesh")
    mesh.mesh_path, mesh.mdf_path = M.MESH.sg09, M.MDF.sg09
    M.add_joints(go.transform, M.WEAPON_JOINTS)
    M.add_component(go, "chainsaw.Gun")
    M.add_component(go, "chainsaw.WwiseContainerApp")
    M.add_component(go, "via.effect.script.EPVStandard")
    M.add_component(go, "via.physics.Colliders")
    return go
end

-- A pickup (chainsaw.DropItem) lying in the scene. Destroying its GameObject removes it.
function M.make_drop_item(item_id, pos, context, count)
    local go = M.make_go("item_" .. tostring(item_id), { wpos = vec(pos.x, pos.y, pos.z) })
    local comp = M.add_component(go, "chainsaw.DropItem")
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
    local go = M.make_go(name, { wpos = vec(pos.x, pos.y, pos.z) })
    local hc = M.add_component(go, "chainsaw.HateController")
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

-- `attacker` (default: the player's body) hits `enemy`: the game builds a DamageInfo and
-- calls the victim's HitController.callbackDamageHit (hooks run around it).
function M.hit(enemy, damage, wince, attacker)
    local info = new("chainsaw.HitController.DamageInfo", { data = {
        Damage = damage, Wince = wince or 10, Break = 0, Stopping = 0, DamageDir = vec(0, 0, -1),
        AttackOwnerObject = attacker or (M.world.player and M.world.player.body), WeaponID = 4000, IsCritical = false,
        IsKill = false } })
    M.component(enemy.body, "chainsaw.HitController"):call("callbackDamageHit", info)
    return info
end

-- The game rolls a random drop for `enemy` (or a wooden box when enemy is nil). Returns the
-- dropped item, or nil if a hook skipped the roll.
function M.enemy_drop(enemy, item_id, droptype)
    local mgr = M.world.singletons["chainsaw.DropItemManager"]
    mgr.next_item, mgr.last_drop = item_id, nil
    mgr:call("generateRandomDrop", droptype or (enemy and 65536 or 1), enemy, vec(0, 0, 0), 40100, nil, nil)
    return mgr.last_drop
end

-- A gimmick changes state (box broken, door opened...).
function M.gimmick_dirty(type_name, ctx_id)
    local ctx = new(type_name, { id = value_type({ _Category = 1, _Kind = 0, _Group = ctx_id.group, _Index = ctx_id.index }) })
    M.world.singletons["chainsaw.GimmickManager"]:call("pushDirtyList", ctx)
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

-- Live GameObjects with this name.
function M.find(name)
    local out = {}
    for _, go in ipairs(M.world.gos) do
        if go.name == name and not go.destroyed then out[#out + 1] = go end
    end
    return out
end

function M.component(go, type_name)
    for _, c in ipairs(go.components) do
        if c.__type == type_name then return c end
    end
    return nil
end

function M.joint(tf, name)
    for _, j in ipairs(tf.joints) do
        if j.name == name then return j end
    end
    return nil
end

-------------------------------------------------------------------------------
-- The shared-world side of RE4: scenario flags, gimmick save table, pauses, timeline events
-- (cutscenes), chapter loads, game over, stage loading and warps, breakables and animals.
-------------------------------------------------------------------------------

local function guid_value(s)
    return new("System.Guid", { text = tostring(s):lower() })
end
M.guid_value = guid_value

local function ctx_object(ctx)
    return new("chainsaw.ContextID", { __fields = { _Category = ctx.category or 0, _Kind = ctx.kind or 0,
        _Group = ctx.group or 0, _Index = ctx.index or 0 } })
end

local function key_of_ctx_object(id)
    local f = id.__fields
    return ("%d:%d:%d:%d"):format(f._Category or 0, f._Kind or 0, f._Group or 0, f._Index or 0)
end

function M.install_world(world, opts)
    world.flag_groups = { { name = "Main", words = { 0, 0, 0, 0 } }, { name = "Chapter", words = { 0, 0 } } }
    world.flag_map, world.flag_log = {}, {}
    world.gimmick_table = {}
    world.pause_params, world.active_pauses = {}, {}
    world.played_events, world.preloaded_events = {}, 0
    world.event_id = 0
    world.scene_requests, world.warps = {}, {}
    world.game_over_requests, world.loads = 0, 0

    class("System.Guid", "System.Object", {
        ["Parse(System.String)"] = { 1, function(_, text) return guid_value(text) end, { "System.String" },
            { static = true, ret = "System.Guid" } },
        ["ToString()"] = { 0, function(self) return self.text end, {}, { ret = "System.String" } },
    })
    M.value_types["System.Guid"] = true
    class("chainsaw.ContextID", "System.Object", {}, { _Category = "chainsaw.ContextID.EntityCategory",
        _Kind = "System.Byte", _Group = "System.Int32", _Index = "System.Int32" })
    class("via.vec3", "System.Object", {})
    class("via.Quaternion", "System.Object", {})

    -- Scenario flags: GUID -> (group, bit). requestSetFlag applies at once and runs hooks.
    local function flag_bit(text)
        local f = world.flag_map[tostring(text):lower()]
        if f == nil then return nil end
        return world.flag_groups[f.group], f.bit
    end
    class("chainsaw.ScenarioFlagManager.SaveGroup", "System.Object", {}, { GroupName = "System.String",
        Flags = "System.UInt32[]" })
    class("chainsaw.ScenarioFlagManager.SaveData", "System.Object", {}, { VersionValue = "System.UInt32",
        Datas = "chainsaw.ScenarioFlagManager.SaveGroup[]" })
    class("chainsaw.ScenarioFlagManager", "System.Object", {
        requestSetFlag = { 2, function(_, g, value)
            local grp, bit = flag_bit(g.text)
            if grp == nil then return end
            local w = bit // 32 + 1
            if value then grp.words[w] = grp.words[w] | (1 << (bit % 32))
            else grp.words[w] = grp.words[w] & ~(1 << (bit % 32)) end
            world.flag_log[#world.flag_log + 1] = { guid = g.text, value = value }
        end, { "System.Guid", "System.Boolean" } },
        checkFlag = { 1, function(_, g)
            local grp, bit = flag_bit(g.text)
            if grp == nil then return false end
            return (grp.words[bit // 32 + 1] & (1 << (bit % 32))) ~= 0
        end, { "System.Guid" }, { ret = "System.Boolean" } },
        -- Decoys a careless probe could pick: a counter and a flag *watcher*.
        getFlagCount = { 0, function() return 0 end, {}, { ret = "System.Int32" } },
        setFlagWatch = { 2, function() world.watch_calls = (world.watch_calls or 0) + 1 end,
            { "System.Guid", "System.Boolean" } },
        saveGameSaveData = { 0, function()
            local groups = {}
            for i, g in ipairs(world.flag_groups) do
                local words = {}
                for k, w in ipairs(g.words) do words[k] = w end
                groups[i] = new("chainsaw.ScenarioFlagManager.SaveGroup", { __fields = { GroupName = g.name,
                    Flags = typed_array("System.UInt32", words) } })
            end
            return new("chainsaw.ScenarioFlagManager.SaveData", { __fields = {
                Datas = typed_array("chainsaw.ScenarioFlagManager.SaveGroup", groups) } })
        end, {}, { ret = "chainsaw.ScenarioFlagManager.SaveData" } },
        loadGameSaveData = { 1, function(_, sd)
            for _, sg in ipairs(rawget(sd.__fields.Datas, "__items")) do
                for _, g in ipairs(world.flag_groups) do
                    if g.name == sg.__fields.GroupName then
                        for k, w in ipairs(rawget(sg.__fields.Flags, "__items")) do g.words[k] = w end
                    end
                end
            end
            world.flag_loads = (world.flag_loads or 0) + 1
        end, { "chainsaw.ScenarioFlagManager.SaveData" } },
    })

    world.singletons["chainsaw.ScenarioFlagManager"] = new("chainsaw.ScenarioFlagManager")

    -- Gimmick save table, keyed by ContextID; pushDirtyList announces a state change.
    class("chainsaw.GimmickContext.TriggerDone", "System.Object", {}, { SaveID = "System.UInt32", Done = "System.UInt32" })
    class("chainsaw.GimmickContext.AccessoryData", "System.Object", {})
    class("chainsaw.GimmickContext.AccessoryDataFloat", "chainsaw.GimmickContext.AccessoryData", {}, { Value = "System.Single" })
    class("chainsaw.GimmickContext.AccessoryDataUint", "chainsaw.GimmickContext.AccessoryData", {}, { Value = "System.UInt32" })
    class("chainsaw.GimmickContext.SaveData", "System.Object", {}, { Attr = "System.Byte[]",
        TriggerSave = "chainsaw.GimmickContext.TriggerDone[]", IsDetected = "System.Boolean",
        AccDatas = "chainsaw.GimmickContext.AccessoryData[]" })
    class("chainsaw.GimmickManager.SaveItem", "System.Object", {}, { ID = "chainsaw.ContextID",
        SaveData = "chainsaw.GimmickContext.SaveData" })
    class("System.Collections.Generic.List`1<chainsaw.GimmickManager.SaveItem>", "System.Object", {
        get_Count = { 0, function(self) return #self.items end, {}, { ret = "System.Int32" } },
        get_Item = { 1, function(self, i) return self.items[i + 1] end, { "System.Int32" } },
        Add = { 1, function(self, x) self.items[#self.items + 1] = x end, { "chainsaw.GimmickManager.SaveItem" } },
    })
    class("chainsaw.GimmickManager.SaveData", "System.Object", {}, { VersionValue = "System.UInt32",
        Datas = "System.Collections.Generic.List`1<chainsaw.GimmickManager.SaveItem>" })
    class("chainsaw.GimmickManager", "System.Object", {
        pushDirtyList = { 1, function() end },
        saveGameSaveData = { 0, function()
            local keys = {}
            for k in pairs(world.gimmick_table) do keys[#keys + 1] = k end
            table.sort(keys)
            local items = {}
            for _, k in ipairs(keys) do
                local g = world.gimmick_table[k]
                local trig, acc = {}, {}
                for i, t in ipairs(g.triggers) do
                    trig[i] = new("chainsaw.GimmickContext.TriggerDone", { __fields = { SaveID = t.id, Done = t.done } })
                end
                for i, a in ipairs(g.acc) do
                    acc[i] = new(a.kind == 1 and "chainsaw.GimmickContext.AccessoryDataFloat"
                        or "chainsaw.GimmickContext.AccessoryDataUint", { __fields = { Value = a.value } })
                end
                local data = new("chainsaw.GimmickContext.SaveData", { __fields = {
                    Attr = typed_array("System.Byte", { table.unpack(g.attr) }),
                    TriggerSave = typed_array("chainsaw.GimmickContext.TriggerDone", trig),
                    IsDetected = g.detected, AccDatas = typed_array("chainsaw.GimmickContext.AccessoryData", acc) } })
                items[#items + 1] = new("chainsaw.GimmickManager.SaveItem", { __fields = { ID = ctx_object(g.ctx), SaveData = data } })
            end
            local list = new("System.Collections.Generic.List`1<chainsaw.GimmickManager.SaveItem>", { items = items })
            return new("chainsaw.GimmickManager.SaveData", { __fields = { Datas = list } })
        end, {}, { ret = "chainsaw.GimmickManager.SaveData" } },
        loadGameSaveData = { 1, function(_, sd)
            for _, item in ipairs(sd.__fields.Datas.items) do
                local id = item.__fields.ID
                local data = item.__fields.SaveData.__fields
                local g = { ctx = { category = id.__fields._Category, kind = id.__fields._Kind, group = id.__fields._Group,
                    index = id.__fields._Index }, attr = {}, triggers = {}, acc = {}, detected = data.IsDetected == true }
                for i = 1, data.Attr:get_size() do g.attr[i] = rawget(data.Attr, "__items")[i] end
                for i = 1, data.TriggerSave:get_size() do
                    local t = rawget(data.TriggerSave, "__items")[i]
                    if t ~= nil then g.triggers[#g.triggers + 1] = { id = t.__fields.SaveID, done = t.__fields.Done } end
                end
                for i = 1, data.AccDatas:get_size() do
                    local a = rawget(data.AccDatas, "__items")[i]
                    if a ~= nil then
                        g.acc[#g.acc + 1] = { kind = a.__type:find("Float") and 1 or 2, value = a.__fields.Value }
                    end
                end
                world.gimmick_table[key_of_ctx_object(id)] = g
            end
            world.gimmick_loads = (world.gimmick_loads or 0) + 1
        end, { "chainsaw.GimmickManager.SaveData" } },
    })

    -- Pauses: each pause type's parameter says what it freezes.
    enum("share.PauseManager.PauseType", { Inventory = 1, Map = 2, PauseMenu = 3, ItemGet = 4, Event = 5, Loading = 6 })
    enum("chainsaw.PauseManagerCustom.CustomPause", { Typewriter = 100, Movie = 101 })
    class("share.PauseManager.PauseParameter", "System.Object", {}, { TargetUpdate = "share.PauseManager.TargetFlag",
        TargetDraw = "share.PauseManager.TargetFlag" })
    local DICT = "System.Collections.Generic.Dictionary`2<System.UInt32,share.PauseManager.PauseParameter>"
    class(DICT, "System.Object", {
        ContainsKey = { 1, function(_, k) return world.pause_params[k] ~= nil end, { "System.UInt32" }, { ret = "System.Boolean" } },
        get_Item = { 1, function(_, k) return world.pause_params[k] end, { "System.UInt32" } },
        set_Item = { 2, function(_, k, v) world.pause_params[k] = v end, { "System.UInt32", "share.PauseManager.PauseParameter" } },
    })
    class("share.PauseManager", "System.Object", {
        requestPause = { 2, function(_, t, owner) world.active_pauses[t] = owner or true end,
            { "share.PauseManager.PauseType", "System.String" } },
        requestUnpause = { 2, function(_, t) world.active_pauses[t] = nil end,
            { "share.PauseManager.PauseType", "System.String" } },
    }, { _ParamTable = DICT })
    for _, k in ipairs({ 1, 2, 3, 4, 5, 6, 100, 101 }) do
        world.pause_params[k] = new("share.PauseManager.PauseParameter", { __fields = { TargetUpdate = 0xFF, TargetDraw = 0x0F } })
    end
    world.singletons["share.PauseManager"] = new("share.PauseManager", { __fields = { _ParamTable = new(DICT) } })

    -- Timeline events (cutscenes).
    local TE = "chainsaw.TimelineEventDefine.ID"
    enum(TE, { None = 0, cs_intro = 10157, cs_church = 20130 })
    class("chainsaw.TimelineEventPlayParam", "System.Object", {})
    class("chainsaw.TimelineEventManager", "System.Object", {
        requestPlay = { 1, function(_, id)
            world.played_events[#world.played_events + 1] = id
            world.event_id = id
            world.gui_event = true
        end, { TE } },
        requestPlayWithParam = { 2, function() error("mock: needs a real parameter object") end,
            { TE, "chainsaw.TimelineEventPlayParam" } },
        requestPreloadPlay = { 1, function() world.preloaded_events = world.preloaded_events + 1 end, { TE } },
        requestStop = { 1, function() world.gui_event = false end, { TE } },
        isPlaying = { 1, function() return world.gui_event end, { TE }, { ret = "System.Boolean" } },
        get_CurrentEventID = { 0, function() return world.event_id end, {}, { ret = TE } },
    })
    world.singletons["chainsaw.TimelineEventManager"] = new("chainsaw.TimelineEventManager")

    -- Chapter loads go through CampaignManager.loadGameSaveData(GameData).
    class("chainsaw.CampaignInitialSetting", "System.Object", {}, { _Chapter = "chainsaw.ChapterID",
        _SpecialJumpSequence = "chainsaw.CampaignJumper.Order.SpecialOrderType" })
    class("chainsaw.CampaignManager.GameData", "System.Object", {}, { _InitialSettings = "chainsaw.CampaignInitialSetting" })
    class("chainsaw.CampaignManager", "System.Object", {
        get_CurrentChapter = { 0, function() return world.chapter or 1 end, {}, { ret = "chainsaw.ChapterID" } },
        get_CurrentDifficulty = { 0, function() return 20 end },
        get_CurrentStageIdentifier = { 0, function()
            local sid = new("chainsaw.StageIdentifier")
            sid.__fields._StageID, sid.__fields._AreaNo = world.stage or 40100, 3
            return sid
        end },
        loadGameSaveData = { 1, function(_, data)
            local init = data.__fields._InitialSettings
            world.chapter = init.__fields._Chapter
            world.jump_sequence = init.__fields._SpecialJumpSequence
            world.loads = world.loads + 1
        end, { "chainsaw.CampaignManager.GameData" } },
    })
    class("chainsaw.GameOverRequest", "System.Object", {})
    class("chainsaw.GameOverMediator", "System.Object", {
        requestGameOver = { 1, function() world.game_over_requests = world.game_over_requests + 1 end,
            { "chainsaw.GameOverRequest" } },
    })
    class("chainsaw.GameOverManager", "System.Object", {
        get_Mediator = { 0, function(self) return self.mediator end },
    })
    world.singletons["chainsaw.GameOverManager"] = new("chainsaw.GameOverManager", { mediator = new("chainsaw.GameOverMediator") })

    -- Stage loading and the game's own warp.
    local STATUS = "System.Nullable`1<chainsaw.EnvSceneStatus>"
    local PRIO = "chainsaw.EnvSceneStatusRequestPriority"
    for name, id_type in pairs({ ["chainsaw.PrefectureSceneManager"] = "chainsaw.PrefectureID",
        ["chainsaw.LocationSceneManager"] = "chainsaw.LocID", ["chainsaw.EnvSceneManager"] = "chainsaw.StageID" }) do
        local mgr = name
        class(mgr, "System.Object", {
            [("requestToChangeStatus(%s, %s, %s)"):format(id_type, STATUS, PRIO)] = { 3, function(_, id, status, prio)
                world.scene_requests[#world.scene_requests + 1] = { mgr = mgr, id = id,
                    status = type(status) == "table" and status.mValue or status, prio = prio }
            end, { id_type, STATUS, PRIO } },
        })
        world.singletons[mgr] = new(mgr)
    end
    class("chainsaw.StageIdentifier", "System.Object", {
        ["setup(chainsaw.LocID, chainsaw.StageID, chainsaw.AreaID)"] = { 3, function(self, loc, stage, area)
            self.loc, self.stage, self.area = loc, stage, area
        end, { "chainsaw.LocID", "chainsaw.StageID", "chainsaw.AreaID" } },
    }, { _StageID = "chainsaw.StageID", _AreaNo = "System.Int32" })
    local WARP = "requestWarp(chainsaw.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>, chainsaw.StageIdentifier)"
    class("chainsaw.CharacterManager", "System.Object", {
        getPlayerContextRef = { 0, function() return world.player end },
        getPartnerContextRef = { 0, function() return world.partner end },
        get_EnemyContextList = { 0, function() return world.enemy_list end },
        isActive = { 1, function(_, stage) return world.active_stages ~= nil and world.active_stages[stage] == true end },
        [WARP] = { 4, function(_, id, pos, rot, sid)
            world.warps[#world.warps + 1] = { pos = { x = pos.x, y = pos.y, z = pos.z }, rot = rot, stage = sid.stage, id = id }
            if world.refuse_warp or world.player == nil then return end
            local p = world.player.pos
            p.x, p.y, p.z = pos.x, pos.y, pos.z
            world.player.stage = sid.stage
        end, { "chainsaw.ContextID", "System.Nullable`1<via.vec3>", "System.Nullable`1<via.Quaternion>",
            "chainsaw.StageIdentifier" } },
    })

    -- Breakables and animals: scene components with a _Routine state machine.
    enum("chainsaw.GmWoodBoxBase.RoutineType", { Wait = 0, Damage = 1, Break = 2, BrokenWait = 3 })
    enum("chainsaw.GmCrow.RoutineType", { Idle = 0, TakeOff = 1, Dead = 2 })
    class("chainsaw.GmBase", "via.Component", {})
    class("chainsaw.GmWoodBoxBase", "chainsaw.GmBase", {}, { _Routine = "chainsaw.GmWoodBoxBase.RoutineType" })
    class("chainsaw.GmWoodBox", "chainsaw.GmWoodBoxBase", {})
    class("chainsaw.GmCrow", "chainsaw.GmBase", {
        requestDead = { 0, function(self) self.__fields._Routine = 2 end },
    }, { _Routine = "chainsaw.GmCrow.RoutineType" })
    class("chainsaw.GmBottle", "chainsaw.GmBase", {})
end

-- Defines a scenario flag: its GUID lives at bit `bit` of flag group `group` (1-based index).
function M.add_flag(guid, group, bit)
    M.world.flag_map[guid:lower()] = { group = group, bit = bit }
end

function M.flag_value(guid)
    local f = M.world.flag_map[guid:lower()]
    local g = M.world.flag_groups[f.group]
    return (g.words[f.bit // 32 + 1] & (1 << (f.bit % 32))) ~= 0
end

-- Game code sets a scenario flag (hooks on the setter run).
function M.game_set_flag(guid, value)
    return M.world.singletons["chainsaw.ScenarioFlagManager"]:call("requestSetFlag", guid_value(guid), value)
end

-- A gimmick's record in the save table: attr = { bytes }, triggers = { {id, done} }.
function M.set_gimmick(ctx, attr, triggers, announce)
    local key = ("%d:%d:%d:%d"):format(ctx.category or 0, ctx.kind or 0, ctx.group, ctx.index)
    M.world.gimmick_table[key] = { ctx = ctx, attr = attr, triggers = triggers or {}, acc = {}, detected = false }
    if announce then
        M.world.singletons["chainsaw.GimmickManager"]:call("pushDirtyList",
            new("chainsaw.GmContextBox", { id = ctx_object(ctx) }))
    end
    return key
end

-- The game starts a cutscene (hooks on the request run).
function M.start_cutscene(id)
    return M.world.singletons["chainsaw.TimelineEventManager"]:call("requestPlay", id)
end

function M.end_cutscene()
    M.world.gui_event = false
    M.world.event_id = 0
end

-- The game loads a save (Continue / Load) of `chapter` through CampaignManager.loadGameSaveData.
function M.load_save(chapter)
    local init = new("chainsaw.CampaignInitialSetting", { __fields = { _Chapter = chapter, _SpecialJumpSequence = 0 } })
    local data = new("chainsaw.CampaignManager.GameData", { __fields = { _InitialSettings = init } })
    M.world.singletons["chainsaw.CampaignManager"]:call("loadGameSaveData", data)
end

-- A breakable or animal in the scene, with the GameObject GUID from the scene file.
function M.make_object(type_name, guid, pos, routine)
    local go = M.make_go(type_name:match("([^.]+)$"), { wpos = vec(pos.x, pos.y, pos.z) })
    go.guid = guid
    local comp = M.add_component(go, type_name, { __fields = { _Routine = routine or 0 } })
    local list = M.world.components[type_name] or {}
    list[#list + 1] = comp
    M.world.components[type_name] = list
    return comp
end

-- Removes a scene object (broken and cleaned up, or unloaded with its area).
function M.remove_object(comp)
    local list = M.world.components[comp.__type] or {}
    for i, c in ipairs(list) do
        if c == comp then table.remove(list, i) break end
    end
end

-- Whether a pause of this type freezes anything right now (what the player would notice).
function M.pause_freezes(t)
    local p = M.world.pause_params[t]
    return p ~= nil and ((p.__fields.TargetUpdate or 0) ~= 0 or (p.__fields.TargetDraw or 0) ~= 0)
end

return M
