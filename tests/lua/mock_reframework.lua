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
    M.calls = (M.calls or 0) + 1 -- every engine call the mod makes (call budget tests)
    if M.call_names then M.call_names[m.key] = (M.call_names[m.key] or 0) + 1 end
    local params = table.pack(...)
    if m.hooks then
        local args = { 0 }
        if not m.static then args[2] = raw_arg(obj) end
        local base = #args
        for i = 1, params.n do args[base + i] = raw_arg(params[i]) end
        local skip = false
        for _, h in ipairs(m.hooks) do
            if h.pre and h.pre(args) == M.SKIP_ORIGINAL then skip = true end
        end
        if skip then
            M.skipped = (M.skipped or 0) + 1
            -- REFramework still runs the post-hooks: what they return is what the caller gets.
            local r = nil
            for _, h in ipairs(m.hooks) do
                if h.post then r = h.post(r) end
            end
            return r
        end
        -- A pre-hook that wrote a parameter (args[i] = sdk.to_ptr(v)) changes what the method gets.
        for i = 1, params.n do
            if args[base + i] ~= raw_arg(params[i]) then params[i] = args[base + i] end
        end
    end
    local r = m.fn(obj, table.unpack(params, 1, params.n))
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
        -- The method's code: methods sharing code (opts.code, e.g. the game's empty stub) share it.
        code = opts and opts.code or nil,
        get_function = function(self) return self.code or tostring(self) end,
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

-- Adds methods ({ key = {nparams, fn, param_types, opts} }) to a class defined elsewhere.
local function add_methods(name, methods)
    local td = classes[name]
    for key, spec in pairs(methods) do
        if td.methods[key] == nil then td.method_order[#td.method_order + 1] = key end
        td.methods[key] = make_method(key, spec[1], spec[2], spec[3], spec[4])
    end
end
M.add_methods = add_methods

-- An enum type: its literals are static fields.
local function enum(name, values)
    if classes["System.Enum"] == nil then class("System.Enum", "System.Object", {}) end
    local td = class(name, "System.Enum", {})
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
function Managed:add_ref()
    self.__refs = (self.__refs or 0) + 1
    M.add_refs = (M.add_refs or 0) + 1
    return self
end
function Managed:add_ref_permanent() self.__permanent = true return self end
function Managed:release() self.__refs = (self.__refs or 0) - 1 end
function Managed:call(name, ...)
    local m = classes[self.__type]:get_method(name)
    if m == nil then error("mock: no method " .. name .. " on " .. self.__type) end
    return invoke(m, self, ...)
end
function Managed:get_field(name)
    M.calls = (M.calls or 0) + 1
    if M.call_names then M.call_names["field " .. name] = (M.call_names["field " .. name] or 0) + 1 end
    return self.__fields[name]
end
function Managed:set_field(name, v)
    if classes[self.__type]:get_field(name) == nil then error("mock: no field " .. name) end
    self.__fields[name] = v
end
-- Components keep their owner GameObject at 0x10; the game clears it on destroy.
function Managed:read_qword(offset)
    M.calls = (M.calls or 0) + 1
    if M.call_names then M.call_names.read_qword = (M.call_names.read_qword or 0) + 1 end
    if offset == 0x10 and self.owner and self.owner.__type == "via.GameObject" then
        return self.owner.destroyed and 0 or self.owner.__addr
    end
    -- A GameObject keeps its transform at 0x18 (the pointer stays after a destroy).
    if offset == 0x18 and self.__type == "via.GameObject" and self.transform then return self.transform.__addr end
    return 0
end

local function new(type_name, data)
    assert(classes[type_name], "mock: unknown class " .. type_name)
    next_address = next_address + 0x100
    local o = setmetatable(data or {}, Managed)
    o.__type = type_name
    o.__addr = next_address
    o.__fields = o.__fields or o.data or {}
    -- A DamageInfo keeps its values in its fields (read by reflection); `data` is the same table.
    if type_name == "chainsaw.HitController.DamageInfo" then o.data = o.__fields end
    objects[o.__addr] = o
    return o
end
M.new = new
M.make_method = make_method

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

-- The 32-bit code of a ContextID {category, kind, group, index} (the game packs the four
-- fields into bits; any deterministic, non-zero code serves the mock).
function M.context_code(ctx)
    local s = ("%d:%d:%d:%d"):format(ctx.category or 0, ctx.kind or 0, ctx.group or 0, ctx.index or 0)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
    return (h & 0x7FFFFFFF) + 1
end

-- Stand-in for a REFramework ValueType (struct field value, e.g. chainsaw.ContextID).
local ValueType = {}
ValueType.__index = ValueType
function ValueType:get_field(name) return self.f[name] end
-- chainsaw.ContextID.get_Code() for ContextID-shaped values.
function ValueType:call(name)
    if name == "get_Code" and self.f._Group ~= nil then
        return M.context_code({ category = self.f._Category, kind = self.f._Kind, group = self.f._Group,
            index = self.f._Index })
    end
    error("mock: value has no method " .. tostring(name))
end
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
    -- REFramework hands get_elements' C++ vector to Lua as a sol2 container (userdata), not a
    -- table: with M.elements_container set, code that needs a table must use get_size /
    -- get_element (0.11.0's menu read every array as empty).
    if M.elements_container then return function() return out end end
    return out
end
function typed_methods:get_address() return rawget(self, "__addr") end
function typed_methods:get_type_definition() return classes["System.Array"] end
-- REManagedObject read_*/write_* (offset from the object): value-type arrays keep their
-- elements inline from 0x20 (the mod reads FlagInfo and PlayerCoordSetting.Pack this way).
local function raw(t) local r = rawget(t, "__raw") if r == nil then r = {} rawset(t, "__raw", r) end return r end
for _, w in ipairs({ "byte", "short", "dword", "qword", "float", "double" }) do
    typed_methods["read_" .. w] = function(self, off) return raw(self)[off] or 0 end
    typed_methods["write_" .. w] = function(self, off, v) raw(self)[off] = v end
end
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
    sr1903 = "_chainsaw/appsystem/prefab/weapon/wp4400.pfb",
    muzzle = "_chainsaw/vfx/provider/epv_system/epv_muzzleflash/epve_0015_muzzleflash_0000.pfb",
}

-- The player's grab state (PlayerBaseContext.get_IsInGrappleDamage) and the way out of a grab
-- (PlayerBodyUpdater.set_RequestCancelGrappleAction): their classes exist once install ends.
-- The player's deaths without a hit (PlayerHeadUpdater.requestDead / onDead) and game overs
-- (GameOverMediator.requestGameOver): recorded in world.player_deaths / world.game_overs.
local function install_player_deaths()
    local w = M.world
    local ph = classes["chainsaw.PlayerHeadUpdater"]
    for name, n in pairs({ requestDead = 2, onDead = 1 }) do
        ph.methods[name] = make_method(name, n, function(self, a)
            w.player_deaths = w.player_deaths or {}
            w.player_deaths[#w.player_deaths + 1] = { head = self, via = name, arg = a }
        end)
        ph.method_order[#ph.method_order + 1] = name
    end
    if classes["chainsaw.GameOverMediator"] == nil then -- (a world mock has its own)
        class("chainsaw.GameOverMediator", "System.Object", {
            requestGameOver = { 1, function(_, req)
                w.game_overs = w.game_overs or {}
                w.game_overs[#w.game_overs + 1] = req
            end, { "chainsaw.GameOverRequest" } },
        })
    end
end

local function install_player_grab()
    local pbc = classes["chainsaw.PlayerBaseContext"]
    pbc.methods.get_IsInGrappleDamage = make_method("get_IsInGrappleDamage", 0, function(self) return self.grabbed == true end,
        {}, { ret = "System.Boolean" })
    pbc.method_order[#pbc.method_order + 1] = "get_IsInGrappleDamage"
    local pbu = classes["chainsaw.PlayerBodyUpdater"]
    pbu.methods.set_RequestCancelGrappleAction = make_method("set_RequestCancelGrappleAction", 1, function(self, v)
        self.cancel_grapple = v
        if v and self.ctx then self.ctx.grabbed = false end
    end, { "System.Boolean" })
    pbu.method_order[#pbu.method_order + 1] = "set_RequestCancelGrappleAction"
end

function M.install(opts)
    opts = opts or {}
    -- A fresh world has other method bodies: the hook guard forgets the old ones.
    if package.loaded["re4coop.hookguard"] then package.loaded["re4coop.hookguard"].reset() end
    classes = {}
    M.classes = classes
    objects = {}
    local world = {
        singletons = {}, enemies = {}, drops = {}, components = {}, gui_event = false, created = {}, gos = {},
        sounds = {}, effects = {}, shots = {}, resources = {}, spawned = {}, item_flags = {}, time_scale = 1.0,
        moving = {}, -- GimmickCore -> true: registered for GimmickManager's update (registerMove)
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
        set_Frame = { 1, function(self, f) self.frame = f self.seeks = (self.seeks or 0) + 1 end },
        get_Speed = { 0, function(self) return self.speed or 1.0 end },
        set_Speed = { 1, function(self, v) self.speed = v end },
        -- A motion its Motion cannot find (M.motion_playable) is not played: nothing changes.
        ["changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"] = {
            6, function(self, bank, id, frame)
                if self.motion_comp ~= nil and not M.motion_playable(self.motion_comp, bank) then
                    self.not_found = (self.not_found or 0) + 1
                    return
                end
                self.bank, self.motion, self.frame = bank, id, frame
                self.changes = (self.changes or 0) + 1 end,
            { "System.UInt32", "System.UInt32", "System.Single", "System.Single", "via.motion.InterpolationMode",
                "via.motion.InterpolationCurve" } },
        get_BlendRate = { 0, function(self) return self.blend or 1.0 end },
        set_BlendRate = { 1, function(self, v) self.blend = v end },
        get_JointMaskID = { 0, function(self) return self.mask or 0 end },
        set_JointMaskID = { 1, function(self, v) self.mask = v end },
        get_BlendMode = { 0, function(self) return self.mode or 0 end },
        set_BlendMode = { 1, function(self, v) self.mode = v end },
    })
    -- Motion: its layers, its bank variant (TargetBankType) and its dynamic motion banks.
    class("via.motion.Motion", "via.Component", {
        getLayer = { 1, function(self, i)
            local l = (self.layers or {})[i + 1]
            if l ~= nil then l.motion_comp = self end
            return l
        end, { "System.UInt32" } },
        getLayerCount = { 0, function(self) return #(self.layers or {}) end },
        get_TargetBankType = { 0, function(self) return self.bank_type or 0 end },
        set_TargetBankType = { 1, function(self, v) self.bank_type = v end },
        getDynamicMotionBankCount = { 0, function(self) return #(self.dynamic or {}) end },
        getDynamicMotionBank = { 1, function(self, i) return (self.dynamic or {})[i + 1] end },
        setDynamicMotionBankCount = { 1, function(self, n)
            self.dynamic = self.dynamic or {}
            for i = #self.dynamic, n + 1, -1 do self.dynamic[i] = nil end
            self.dynamic_set = (self.dynamic_set or 0) + 1
        end },
        setDynamicMotionBank = { 2, function(self, i, b)
            self.dynamic = self.dynamic or {}
            self.dynamic[i + 1] = b
        end },
    })
    class("via.motion.MotionListResourceHolder", "System.Object", {
        get_ResourcePath = { 0, function(self) return self.path end },
    })
    local function prop(name, field)
        return { ["get_" .. name] = { 0, function(self) return self[field] end },
            ["set_" .. name] = { 1, function(self, v) self[field] = v end } }
    end
    local bank_methods = {}
    for _, pr in ipairs({ { "MotionList", "motlist" }, { "BankID", "bank_id" }, { "BankType", "bank_type" },
        { "BankTypeMaskBit", "mask_bit" }, { "Order", "order" }, { "OverwriteBankID", "ow_id" },
        { "OverwriteBankType", "ow_type" }, { "OverwriteBankTypeMaskBit", "ow_mask" } }) do
        for k, v in pairs(prop(pr[1], pr[2])) do bank_methods[k] = v end
    end
    class("via.motion.DynamicMotionBank", "System.Object", bank_methods)
    -- The game's way to add a dynamic bank to a character's motion (on its body).
    class("chainsaw.MotionController", "via.Component", {
        addDynamicMotionBank = { 1, function(self, b)
            local m = self.motion
            m.dynamic = m.dynamic or {}
            m.dynamic[#m.dynamic + 1] = b
            self.adds = (self.adds or 0) + 1
        end },
        removeDynamicMotionBank = { 1, function(self, b)
            local m = self.motion
            for i = #(m.dynamic or {}), 1, -1 do
                if m.dynamic[i] == b then table.remove(m.dynamic, i) end
            end
        end },
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
    -- Cameras and what renders with them (a scope's view).
    class("via.Camera", "via.Component", {})
    for _, n in ipairs({ "via.render.RenderOutput", "via.render.ToneMapping", "via.render.DepthOfField" }) do
        class(n, "via.Component", {})
    end
    class("via.GameObjectRef", "System.Object", { get_Target = { 0, function(self) return self.target end } })
    class("chainsaw.ScopeController", "via.Component", {}, { _CameraRef = "via.Camera",
        _WeaknessCameraGameObject = "via.GameObjectRef" })
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
        get_Transform = { 0, function(self)
            -- The game throws System.InvalidOperationException for a destroyed GameObject.
            if self.destroyed then
                M.exceptions = (M.exceptions or 0) + 1
                error("System.InvalidOperationException: get_Transform of a destroyed GameObject")
            end
            return self.transform
        end },
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
        -- The GameObject's tag string ("A|B"): TargetMarker.register files a marker under it.
        get_Tag = { 0, function(self) return self.tag or "" end },
        set_Tag = { 1, function(self, v) self.tag = v end },
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
        -- HitPoint.dead() (re4.exe 0x14028f870) only zeroes the HP: no death reaction.
        hp_methods.dead = { 0, function(self) self.owner.hp = 0 end }
    end
    -- HitPoint.checkDead(damage) (0x143408bc0): false while NoDamage, Immortal or NoDeath, or
    -- already dead; else whether HP - damage <= 0.
    -- NoDamage (HitPoint +0x19): the character takes no damage.
    hp_methods.get_NoDamage = { 0, function(self) return self.owner.no_damage == true end, {}, { ret = "System.Boolean" } }
    hp_methods.set_NoDamage = { 1, function(self, v) self.owner.no_damage = v end, { "System.Boolean" } }
    -- Invincible (+0x18), NoDeath (+0x1a), Immortal (+0x1b).
    for name, key in pairs({ Invincible = "invincible", NoDeath = "no_death", Immortal = "immortal" }) do
        hp_methods["get_" .. name] = { 0, function(self) return self.owner[key] == true end, {}, { ret = "System.Boolean" } }
        hp_methods["set_" .. name] = { 1, function(self, v) self.owner[key] = v end, { "System.Boolean" } }
    end
    hp_methods.checkDead = { 1, function(self, d)
        local c = self.owner
        if c.no_damage or c.immortal or c.no_death or c.hp <= 0 then return false end
        return c.hp - math.max(0, d or 0) <= 0
    end, { "System.Int32" }, { ret = "System.Boolean" } }
    M.hp_field_name = opts.hp_field_name or "<CurrentHitPoint>k__BackingField"
    class("chainsaw.HitPoint", "System.Object", hp_methods,
        opts.no_hp_setter and { [M.hp_field_name] = "System.Int32" } or {})

    -- Hits: HitController.callbackDamageHit(DamageInfo) applies damage to its character.
    local info_fields = { "Damage", "Wince", "Break", "Stopping", "DamageDir", "Position", "AttackOwnerObject", "WeaponID",
        "IsCritical", "IsKill", "WeaponGameObject", "AttackGameObject", "DamageGameObject", "ChildHitController",
        "AttackCollidable", "DamageCollidable", "AttackUserData", "AttackData", "DamageUserData" }
    local info_methods = {
        copy = { 1, function(self, src)
            for _, f in ipairs(info_fields) do self.data[f] = src.data[f] end
        end },
    }
    for _, f in ipairs(info_fields) do
        info_methods["get_" .. f] = { 0, function(self) return self.data[f] end }
        info_methods["set_" .. f] = { 1, function(self, v)
            -- Setting an object field adds a reference to the new value: one the game already
            -- freed (resource data unloaded with its area) is an access violation (2026-10-12).
            if type(v) == "table" and v.destroyed then
                world.native_crashes = world.native_crashes + 1
                error("access violation in HitInfo.set_" .. f .. " (freed object)")
            end
            self.data[f] = v
        end }
    end
    -- The fields, the way the type database lists them: primitive values, vectors, an enum,
    -- object references, a value that only means something in one game (SerialNo), and a
    -- parent type with a field of its own.
    enum("chainsaw.AttackType", { Shot = 0, Melee = 1, Explosion = 2 })
    class("chainsaw.HitController.HitInfo", "System.Object", {}, { HitPos = "via.vec3", SerialNo = "System.UInt32" })
    class("chainsaw.HitController.DamageInfo", "chainsaw.HitController.HitInfo", info_methods, {
        Damage = "System.Int32", Wince = "System.Single", Break = "System.Single", Stopping = "System.Single",
        DamageDir = "via.vec3", WeaponID = "System.Int32", IsCritical = "System.Boolean", IsKill = "System.Boolean",
        AttackType = "chainsaw.AttackType", AttackOwnerObject = "via.GameObject", WeaponGameObject = "via.GameObject",
        AttackGameObject = "via.GameObject", DamageGameObject = "via.GameObject",
        ChildHitController = "chainsaw.HitController", AttackCollidable = "via.physics.Collidable",
        DamageCollidable = "via.physics.Collidable", AttackUserData = "chainsaw.collision.AttackUserData",
        AttackData = "chainsaw.collision.AttackHitUserData.AttackData", DamageUserData = "chainsaw.collision.DamageUserData" })
    class("chainsaw.collision.AttackUserData", "System.Object", {})
    -- An attack's data: what the enemy's reaction is chosen from (EnemyHeadUpdater.
    -- findDamageReaction reads _AttackType, _AttackPower and _Option). doDeepCopy(src) copies
    -- src into it (0x141cf4250).
    enum("chainsaw.character.AttackType", { None = 0, Shot = 1, Slash = 2, Blow = 4, Explosion = 5 })
    enum("chainsaw.character.AttackPower", { Heavy = 0, Midle = 1, Light = 2 })
    enum("chainsaw.HitManager.AttackOption", { None = 0, NoReaction = 8 })
    enum("chainsaw.character.BodyParts", { Head = 0, Chest = 1, Thigh = 7 })
    enum("chainsaw.character.BodyPartsSide", { Center = 0, Left = 1, Right = 2 })
    class("chainsaw.collision.AttackHitUserData.AttackData", "System.Object", {
        doDeepCopy = { 1, function(self, src)
            for k, v in pairs(src.__fields) do self.__fields[k] = v end
            self.weapon = src.weapon
            self.copied_from = src
        end, { "chainsaw.collision.AttackHitUserData.AttackData" } },
    }, { _AttackType = "chainsaw.character.AttackType", _AttackPower = "chainsaw.character.AttackPower",
        _Option = "chainsaw.HitManager.AttackOption", _Damage = "System.Int32",
        _Wince = "System.Nullable`1<System.Single>", _AttackToEnemyUserData = "chainsaw.AttackToEnemyUserData" })
    class("chainsaw.collision.DamageUserData", "System.Object", {},
        { Parts = "chainsaw.character.BodyParts", PartsSide = "chainsaw.character.BodyPartsSide" })
    class("chainsaw.collision.EnemyDamageUserData", "chainsaw.collision.DamageUserData", {},
        { Parts = "chainsaw.character.BodyParts", PartsSide = "chainsaw.character.BodyPartsSide" })
    class("chainsaw.collision.PlayerDamageUserData", "chainsaw.collision.DamageUserData", {},
        { Parts = "chainsaw.character.BodyParts", PartsSide = "chainsaw.character.BodyPartsSide" })
    class("chainsaw.collision.PressUserData", "System.Object", {})
    class("via.physics.UserData", "System.Object", {})
    class("via.physics.RequestSetColliderUserData", "via.physics.UserData", {})
    -- A character's colliders (HitController.get_Colliders): each with its user data.
    class("via.physics.Collider", "System.Object", {
        get_UserData = { 0, function(self) return self.user_data end },
    })
    local colliders = classes["via.physics.Colliders"].methods
    colliders.getCollidersCount = make_method("getCollidersCount", 0, function(self) return #(self.list or {}) end, {},
        { ret = "System.UInt32" })
    colliders.getColliders = make_method("getColliders", 1, function(self, i) return (self.list or {})[i + 1] end,
        { "System.UInt32" })
    local order = classes["via.physics.Colliders"].method_order
    order[#order + 1], order[#order + 2] = "getColliders", "getCollidersCount"
    world.native_crashes = 0
    -- The player's AI head and target selector: a finisher (requestFatal & co.) goes to the
    -- selector's LockonTarget.
    class("chainsaw.PlayerTargetSelector", "System.Object", {
        get_LockonTarget = { 0, function(self) return self.target end },
    })
    -- PlayerHeadUpdater.requestFatal (0x141d65b70) asks the target's AI head
    -- convertNormalFatalAction(our context, FatalType); requestKnifeFatal (0x141d66c00)
    -- requestFatalKill or, from behind, requestStealthKill; requestStompFatal requestFatalKill.
    local function fatal_request(name)
        return { 0, function(self)
            world.fatal_requests = world.fatal_requests or {}
            local target = self.selector.target
            world.fatal_requests[#world.fatal_requests + 1] = { kind = name, target = target }
            local head = target and target.head_updater
            if head == nil then return false end
            local me = world.player
            if name == "requestFatal" then
                return head:call("convertNormalFatalAction", me, self.ftype or 1)
            elseif name == "requestKnifeFatal" and self.stealth then
                return head:call("requestStealthKill", me)
            end
            return head:call("requestFatalKill", me)
        end, {}, { ret = "System.Boolean" } }
    end
    class("chainsaw.PlayerHeadUpdater", "System.Object", {
        -- PlayerHeadUpdater.hasKnife (virtual +0x318): whether the player has a knife to use.
        hasKnife = { 0, function(self) return self.has_knife ~= false end, {}, { ret = "System.Boolean" } },
        get_TargetSelectorDriver = { 0, function(self) return self.selector end },
        requestFatal = fatal_request("requestFatal"),
        requestKnifeFatal = fatal_request("requestKnifeFatal"),
        requestStompFatal = fatal_request("requestStompFatal"),
    })
    -- A head's updater: linked to its character (Context) while in use, unlinked in the pool.
    world.head_fatals = {}
    local function head_request(kind)
        return { kind == "normal" and 2 or 1, function(self, ctx, ftype)
            world.head_fatals[#world.head_fatals + 1] = { head = self, kind = kind, attacker = ctx, ftype = ftype,
                target = self.context }
            return self.context ~= nil and self.context.refuse_fatal ~= true
        end, kind == "normal" and { "chainsaw.CharacterContext", "chainsaw.PlayerDefine.FatalType" }
            or { "chainsaw.CharacterContext" }, { ret = "System.Boolean" } }
    end
    class("chainsaw.HeadUpdater", "via.Component", {
        -- The finisher checks PlayerTargetSelector.checkTargetType asks (context: the player's).
        isEnableFatal = { 1, function(self) return self.context ~= nil and self.context.fatal_ok == true end,
            { "chainsaw.CharacterContext" }, { ret = "System.Boolean" } },
        -- EnemyHeadUpdater.isEnableKnifeFatal (0x1413d6800) also asks the attacker's head
        -- (CharacterContext._HeadUpdater) hasKnife(): no head, no knife finish.
        isEnableKnifeFatal = { 1, function(self, ctx)
            if self.context == nil or self.context.knife_ok ~= true or ctx == nil then return false end
            local head = ctx.__fields._HeadUpdater or ctx.head_updater
            if head == nil then return false end
            local k = head:call("hasKnife")
            return k == true or k == 1
        end, { "chainsaw.CharacterContext" }, { ret = "System.Boolean" } },
        isEnableStealthKill = { 2, function(self) return self.context ~= nil and self.context.stealth_ok == true end,
            { "chainsaw.CharacterContext", "System.Boolean" }, { ret = "System.Boolean" } },
        getAvailableFatalType = { 0, function(self) return self.context and self.context.fatal_type or 0 end, {},
            { ret = "chainsaw.PlayerDefine.FatalType" } },
        requestFatalKill = head_request("kill"),
        requestStealthKill = head_request("stealth"),
        convertNormalFatalAction = head_request("normal"),
        get_Context = { 0, function(self) return self.context end },
        -- CharacterHeadUpdater.entryDeadAction (0x1411a5f60): requests the death action.
        entryDeadAction = { 0, function(self)
            if self.context ~= nil then self.context.dying = self.context.dying or "action" end
        end },
    })
    class("chainsaw.HitController", "via.Component", {
        get_DamageOwner = { 0, function(self) return self.damage_owner end },
        get_ParentHitController = { 0, function(self) return self.parent_hc end },
        -- HitController.playDamageSe (re4.exe 0x142009440): reads DamageInfo.AttackUserData and
        -- AttackData without a null check. In the game a null one is an access violation.
        playDamageSe = { 1, function(_, info)
            if info.data.AttackUserData == nil or info.data.AttackData == nil then
                world.native_crashes = world.native_crashes + 1
                error("access violation in HitController.playDamageSe (null AttackUserData)")
            end
            world.damage_sounds = (world.damage_sounds or 0) + 1
        end, { "chainsaw.HitController.DamageInfo" } },
        get_Colliders = { 0, function(self) return self.colliders end },
        -- HitController.checkKill(damage) (0x141f3ab30): the character's HitPoint.checkDead.
        checkKill = { 1, function(self, d)
            return self.ctx ~= nil and self.ctx.hitpoint:call("checkDead", d) or false
        end, { "System.Int32" }, { ret = "System.Boolean" } },
        -- HitController.callbackCheckDamageHit (Delegates.OnCheckDamageHit): the character's own
        -- check (a dodge, invincibility frames).
        callbackCheckDamageHit = { 1, function(self)
            return not (self.ctx ~= nil and self.ctx.dodging == true)
        end, { "chainsaw.HitController.DamageInfo" }, { ret = "System.Boolean" } },
        get_CurrentHitPoint = { 0, function(self) return self.ctx and self.ctx.hp or 0 end, {}, { ret = "System.Int32" } },
        callbackDamageHit = { 1, function(self, info)
            self:call("playDamageSe", info)
            local ctx = self.ctx
            -- A killing hit throws the body: RagdollUnit.onDamageHit (re4.exe 0x143795890) reads
            -- AttackGameObject and, in addForceFromPointForce, DamageUserData without a check.
            if ctx ~= nil and (info.data.IsKill or (info.data.Damage or 0) >= ctx.hp) then
                if info.data.AttackGameObject == nil or info.data.DamageUserData == nil then
                    world.native_crashes = world.native_crashes + 1
                    error("access violation in RagdollUnit.onDamageHit (null AttackGameObject/DamageUserData)")
                end
                world.ragdoll_parts = info.data.DamageUserData.__fields.Parts
                -- A villager's death draws lots for a head burst (Ch1c0HeadUpdaterCommon.onDead ->
                -- lotteryBreakHead -> onPartsBreak -> Ch1c0BodyUpdaterCommon.requestPartsBreak), on
                -- its own head and body updaters.
                local hu = M.villager_head(ctx)
                local burst = hu:call("lotteryBreakHead", info)
                if burst == true or (type(burst) == "number" and burst ~= 0) then
                    hu:call("onPartsBreak", info, 0, 0)
                end
            end
            -- CharacterHeadUpdater.onHitDamage (0x141202de0): the HP (HitPoint.addDamage: never
            -- below 1 while NoDeath), the body part of the hit's DamageUserData, then the death
            -- only for a hit marked IsKill - else a damage reaction chosen from its AttackData,
            -- even when the HP reached 0 (the AI notices that only later: it walks on, dead).
            local ad = info.data.AttackData
            local du = info.data.DamageUserData
            local rec = { damage = info.data.Damage, wince = info.data.Wince,
                attacker = info.data.AttackOwnerObject, critical = info.data.IsCritical, kill = info.data.IsKill,
                attack_type = info.data.AttackType, hit_pos = info.data.HitPos, serial = info.data.SerialNo,
                reaction_type = ad and ad.__fields._AttackType, reaction_power = ad and ad.__fields._AttackPower,
                attack_data = ad, part = du and du.__fields.Parts, side = du and du.__fields.PartsSide,
                user_data = du, pos = info.data.Position, dir = info.data.DamageDir }
            self.received = self.received or {}
            self.received[#self.received + 1] = rec
            if M.deferred_damage then
                M.pending_damage = { owner = ctx, amount = info.data.Damage or 0 }
            elseif ctx ~= nil and ctx.no_damage then
                ctx.ignored_hits = (ctx.ignored_hits or 0) + 1 -- HitPoint.NoDamage
            elseif ctx ~= nil then
                ctx.hp = math.max(ctx.no_death and 1 or 0, ctx.hp - (info.data.Damage or 0))
                if info.data.IsKill then
                    ctx.dying = ctx.dying or "hit"
                elseif ctx.hp <= 0 then
                    ctx.walking_dead = true
                else
                    ctx.reaction = rec
                end
            end
        end, { "chainsaw.HitController.DamageInfo" } },
    })
    local hc_fields = classes["chainsaw.HitController"].fields
    hc_fields["<ContextAccessor>k__BackingField"] = "chainsaw.IContextAccessor"
    hc_fields["<Delegate>k__BackingField"] = "chainsaw.HitController.Delegates"
    hc_fields["<DamageCalcInfo>k__BackingField"] = "chainsaw.HitController.DamageInfo"
    class("chainsaw.HitController.Delegates", "System.Object", {})
    M.install_partner(world)
    -- Parts breaks (heads bursting, limbs): the break effect of a hit the mod ran crashed the
    -- game in WindManager.attachWindSettingEffect (re4.exe+0x326e37f, 2026-10-12).
    world.head_burst = false -- what the death lottery draws
    world.parts_broken = 0
    class("chainsaw.CharacterHeadUpdater", "System.Object", {
        onPartsBreak = { 3, function() end, { "chainsaw.HitController.DamageInfo", "chainsaw.character.BodyParts",
            "chainsaw.character.BodyPartsSide" } },
    })
    class("chainsaw.Ch1c0BodyUpdaterCommon", "System.Object", {
        requestPartsBreak = { 5, function(_, info)
            if not info.engine_owned then
                world.native_crashes = world.native_crashes + 1
                error("access violation in WindManager.attachWindSettingEffect (parts break of a replayed hit)")
            end
            world.parts_broken = world.parts_broken + 1
        end, { "chainsaw.HitController.DamageInfo", "chainsaw.character.BodyParts", "chainsaw.character.BodyPartsSide",
            "System.Boolean", "System.Boolean" } },
    })
    class("chainsaw.Ch1c0HeadUpdaterCommon", "chainsaw.CharacterHeadUpdater", {
        lotteryBreakHead = { 1, function() return world.head_burst end, { "chainsaw.HitController.DamageInfo" },
            { ret = "System.Boolean" } },
        onPartsBreak = { 3, function(self, info, parts, side)
            self.body:call("requestPartsBreak", info, parts, side, false, false)
        end, { "chainsaw.HitController.DamageInfo", "chainsaw.character.BodyParts", "chainsaw.character.BodyPartsSide" } },
    })
    -- Random drops and spawning items.
    class("chainsaw.Item", "System.Object", {
        setItemId = { 1, function(self, v) self.item_id = v end },
        setItemCount = { 1, function(self, v) self.count = v end },
        get_ItemId = { 0, function(self) return self.__fields._ItemId end, {}, { ret = "chainsaw.ItemID" } },
        get_CurrentItemCount = { 0, function(self) return self.__fields._CurrentItemCount end, {}, { ret = "System.Int32" } },
    }, { _ItemId = "chainsaw.ItemID", _CurrentItemCount = "System.Int32", _CurrentDurability = "System.Int32",
        _ID = "System.Guid" })
    class("chainsaw.DropItemManager.GenerateItemOption", "System.Object", {},
        { Falldown = "System.Boolean", Effect = "System.Boolean", NeedColCheck = "System.Boolean" })
    -- Random drops: requestGenerateRandomDrop queues a roll (RandomDropStack), updateRandomDropStack
    -- runs generateRandomDrop for each. cc is the player who gets the loot, order the enemy/box.
    class("chainsaw.RandomDrop.Option", "System.Object", {})
    local GEN = { "chainsaw.RandomDrop.DropType", "chainsaw.CharacterContext", "via.vec3", "chainsaw.StageID",
        "chainsaw.Context", "chainsaw.DropItemManager.GenerateItemOption" }
    class("chainsaw.DropItemManager", "System.Object", {
        ["requestGenerateRandomDrop(chainsaw.RandomDrop.Option, chainsaw.CharacterContext, via.vec3, chainsaw.StageID, chainsaw.Context, chainsaw.DropItemManager.GenerateItemOption)"] = {
            6, function(self, rnd, cc, pos, stage, order, opt)
                self.stack = self.stack or {}
                self.stack[#self.stack + 1] = { droptype = rnd and rnd.droptype or 65536, cc = cc, pos = pos, stage = stage,
                    order = order, opt = opt }
            end, { "chainsaw.RandomDrop.Option", "chainsaw.CharacterContext", "via.vec3", "chainsaw.StageID",
                "chainsaw.Context", "chainsaw.DropItemManager.GenerateItemOption" } },
        ["requestGenerateRandomDrop(chainsaw.RandomDrop.Option, chainsaw.CharacterContext, via.GameObject, chainsaw.DropItemManager.GenerateItemOption)"] = {
            4, function(self, rnd, cc, go, opt)
                self.stack = self.stack or {}
                local p = go and go.transform and M.world_pos(go.transform) or vec(0, 0, 0)
                self.stack[#self.stack + 1] = { droptype = rnd and rnd.droptype or 65536, cc = cc, pos = p, stage = 40100,
                    opt = opt }
            end, { "chainsaw.RandomDrop.Option", "chainsaw.CharacterContext", "via.GameObject",
                "chainsaw.DropItemManager.GenerateItemOption" } },
        updateRandomDropStack = { 0, function(self)
            local stack = self.stack or {}
            self.stack = {}
            for _, e in ipairs(stack) do
                self:call("generateRandomDrop", e.droptype, e.cc, e.pos, e.stage, e.order, e.opt)
            end
        end },
        -- Rolls `next_item` and drops it next to the dropper (`order`) or at `pos`.
        generateRandomDrop = { 6, function(self, droptype, cc, pos, stage, order, opt)
            world.generated = world.generated or {}
            world.generated[#world.generated + 1] = { droptype = droptype, cc = cc, order = order, pos = pos,
                stage = stage, opt = opt }
            local base = (order and order.pos) or pos or self.drop_pos or vec(0, 0, 0)
            self.last_drop = M.make_drop_item(self.next_item or 112800000, { x = base.x + 0.5, y = base.y, z = base.z },
                nil, 1)
        end, GEN },
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
    -- Gimmicks.
    class("chainsaw.GimmickManager", "System.Object", { pushDirtyList = { 1, function() end } })
    class("chainsaw.GmContextBox", "System.Object", { get_ID = { 0, function(self) return self.id end } })

    local ctx_methods = {
        get_Position = { 0, function(self) return vec(self.pos.x, self.pos.y, self.pos.z) end },
        get_HitPoint = { 0, function(self) return self.hitpoint end },
        get_BodyGameObject = { 0, function(self) return self.body end },
        get_HeadGameObject = { 0, function(self) return self.head end },
        get_HeadUpdater = { 0, function(self) return self.head_updater end },
        get_BodyUpdater = { 0, function(self) return self.body_updater end },
        -- The spawn param that created the character: its ContextID, which is also the
        -- character's own _ID (nil for characters without one).
        get_SpawnerID = { 0, function(self) return self.spawner end },
        get_CharacterSpawnParam = { 0, function(self) return self.spawn_param end },
        get_IsEliminated = { 0, function(self) return self.eliminated == true end },
        eliminate = { 0, function(self) self.eliminated = true end },
        get_CurrentStageID = { 0, function(self) return self.stage or world.stage or 40100 end },
        get_KindID = { 0, function(self) return self.kind_id or 0 end },
        get_TargetFindState = { 0, function() return 1 end },
        get_TargetFindSource = { 0, function() return 0 end },
    }
    class("chainsaw.CharacterContext", "System.Object", ctx_methods, { _ID = "chainsaw.ContextID" })
    -- A level spawn param (a component on its own GameObject). invalidateSpawn(true) despawns
    -- its character the way the game's updateSpawn does: the context leaves the enemy list
    -- and its body and head are destroyed.
    -- StatusFlag: Permitted 1, Readied 2, Activated 4, Invalidated 8 (see M.update_spawns).
    class("chainsaw.CharacterSpawnParam", "via.Component", {
        invalidateSpawn = { 1, function(self, b)
            self.invalid = b
            if b and self.ctx ~= nil then M.despawn(self.ctx) end
        end, { "System.Boolean" } },
        permitSpawn = { 1, function(self, b) self.permitted = b end, { "System.Boolean" } },
        get_StatusFlag = { 0, function(self)
            return (self.permitted ~= false and 1 or 0) | (self.invalid and 8 or 0)
        end, {}, { ret = "System.Int32" } },
        get_ContextID = { 0, function(self) return self.id end },
    })
    -- chainsaw.ContextID built from its code (the constructor ContextID(UInt32 code)).
    M.context_id_methods = {
        [".ctor(System.UInt32)"] = { 1, function(self, code) self.code = code end, { "System.UInt32" } },
        get_Code = { 0, function(self)
            if self.code ~= nil then return self.code end
            local f = self.__fields
            return M.context_code({ category = f._Category, kind = f._Kind, group = f._Group, index = f._Index })
        end, {}, { ret = "System.UInt32" } },
    }
    class("chainsaw.ContextID", "System.Object", M.context_id_methods, { _Category = "chainsaw.ContextID.EntityCategory",
        _Kind = "System.Byte", _Group = "System.Int32", _Index = "System.Int32" })
    -- CharacterManager.CharacterBackupDB: ContextID code -> CharacterBackup (world.backups).
    class("chainsaw.CharacterBackup", "System.Object", {
        get_IsEliminated = { 0, function(self) return self.eliminated == true end },
        get_ContextID = { 0, function(self) return self.id end },
    })
    class("System.Collections.ObjectModel.ReadOnlyCollection`1<chainsaw.CharacterBackup>", "System.Object", {
        get_Count = { 0, function(self) return #self.items end },
        get_Item = { 1, function(self, i) return self.items[i + 1] end },
    })
    local function backup_code(b) return b.id and b.id:call("get_Code") end
    local function backup_of(code)
        for i, b in ipairs(world.backups) do
            if backup_code(b) == code then return b, i end
        end
        return nil
    end
    M.backup_of = backup_of
    class("System.Collections.Concurrent.ConcurrentDictionary`2<System.UInt32,chainsaw.CharacterBackup>", "System.Object", {
        get_Values = { 0, function()
            local items = {}
            for _, b in ipairs(world.backups) do items[#items + 1] = b end
            return new("System.Collections.ObjectModel.ReadOnlyCollection`1<chainsaw.CharacterBackup>", { items = items })
        end },
        ContainsKey = { 1, function(_, code) return backup_of(code) ~= nil end, { "System.UInt32" },
            { ret = "System.Boolean" } },
        get_Item = { 1, function(_, code)
            local b = backup_of(code)
            if b == nil then error("KeyNotFoundException") end
            return b
        end, { "System.UInt32" } },
        ["System.Collections.Generic.IDictionary<TKey,TValue>.Remove(System.UInt32)"] = { 1, function(_, code)
            local _, i = backup_of(code)
            if i == nil then return false end
            table.remove(world.backups, i)
            return true
        end, { "System.UInt32" }, { ret = "System.Boolean" } },
    })
    world.backups = world.backups or {}
    local backup_db = new("System.Collections.Concurrent.ConcurrentDictionary`2<System.UInt32,chainsaw.CharacterBackup>")
    class("chainsaw.PlayerBaseContext", "chainsaw.CharacterContext", {
        get_IsHolding = { 0, function(self) return self.aiming or false end },
    })
    class("chainsaw.EnemyBaseContext", "chainsaw.CharacterContext", {})
    class("chainsaw.Ch1c0z0Context", "chainsaw.EnemyBaseContext", {})
    class("chainsaw.Ch1d0z0Context", "chainsaw.EnemyBaseContext", {})
    -- A partner (Ashley is CharacterKindID 200030). Her head's action unit sets
    -- IsPermitKidnapped from ThinkEnable every frame it runs (PartnerNpcActionUpdaterUnit.
    -- updateKidnapped); enemies grab her only while it is set (M.try_kidnap).
    class("chainsaw.PartnerBaseContext", "chainsaw.CharacterContext", {
        get_IsKidnapped = { 0, function(self) return self.kidnapped == true end },
        get_PartnerState = { 0, function(self) return self.partner_state or 0 end, {}, { ret = "chainsaw.Npc.State" } },
        get_IsPermitKidnapped = { 0, function(self) return self.permit_kidnapped == true end },
        set_IsPermitKidnapped = { 1, function(self, v) self.permit_kidnapped = v end, { "System.Boolean" } },
        get_IsPermitAttacked = { 0, function(self) return self.permit_attacked == true end },
        set_IsPermitAttacked = { 1, function(self, v) self.permit_attacked = v end, { "System.Boolean" } },
        -- CharacterContext.setTransform (0x1421f2ef0): the context's transform, passed on to
        -- its listeners (the body).
        ["setTransform(via.vec3, via.Quaternion)"] = { 2, function(self, pos, rot)
            self.pos.x, self.pos.y, self.pos.z = pos.x, pos.y, pos.z
            if self.body ~= nil then self.body.transform.wrot = quat(rot.x, rot.y, rot.z, rot.w) end
            self.set_transforms = (self.set_transforms or 0) + 1
        end, { "via.vec3", "via.Quaternion" } },
    })
    class("chainsaw.Ch3a8z0Context", "chainsaw.PartnerBaseContext", {}) -- an NPC partner
    -- A scripted NPC without AI of its own (CharacterManager.DollNpcContextList).
    class("chainsaw.DollNpcBaseContext", "chainsaw.CharacterContext", {})

    class("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>", "System.Object", {
        get_Count = { 0, function(self) return #world.enemies end },
        get_Item = { 1, function(self, i) return world.enemies[i + 1] end },
    })
    local enemy_list = new("System.Collections.Generic.List`1<chainsaw.EnemyBaseContext>")
    world.enemy_list = enemy_list

    world.spawn_params = {} -- ContextID code -> spawn param (CharacterManager.CharacterSpawnParamDB)
    local function live_context(code)
        for _, e in ipairs(world.enemies or {}) do
            if e.spawner ~= nil and e.spawner:call("get_Code") == code then return e end
        end
        return nil
    end
    -- CharacterManager.PartnerContextList: world.partners (or the one world.partner).
    class("System.Collections.Generic.List`1<chainsaw.CharacterContext>", "System.Object", {
        get_Count = { 0, function(self) return #self.items() end },
        get_Item = { 1, function(self, i) return self.items()[i + 1] end },
    })
    local function partner_list()
        return new("System.Collections.Generic.List`1<chainsaw.CharacterContext>", { items = function()
            return world.partners or { world.partner }
        end })
    end
    M.partner_list = partner_list
    -- CharacterManager.DollNpcContextList: world.dolls.
    function M.doll_list()
        return new("System.Collections.Generic.List`1<chainsaw.CharacterContext>", { items = function()
            return world.dolls or {}
        end })
    end
    local character_manager_methods = {
        getPlayerContextRef = { 0, function() return world.player end },
        getPartnerContextRef = { 0, function() return world.partner end },
        get_PartnerContextList = { 0, function() return not world.no_partner_list and partner_list() or nil end },
        get_DollNpcContextList = { 0, function() return M.doll_list() end },
        get_EnemyContextList = { 0, function() return enemy_list end },
        get_CharacterBackupDB = { 0, function() return backup_db end },
        getSpawnParamRef = { 1, function(_, id) return world.spawn_params[id:call("get_Code")] end,
            { "chainsaw.ContextID" }, { ret = "chainsaw.CharacterSpawnParam" } },
        getContextRef = { 1, function(_, id) return live_context(id:call("get_Code")) end,
            { "chainsaw.ContextID" }, { ret = "chainsaw.CharacterContext" } },
    }
    M.character_manager_methods = character_manager_methods
    class("chainsaw.CharacterManager", "System.Object", character_manager_methods)
    class("chainsaw.GuiManager", "System.Object", {
        get_IsPlayingEvent = { 0, function() return world.gui_event end },
    })
    -- The game's state machine (share.MainModeManager): IsInGame is the current game state's,
    -- true only for GameStateInGame. M.chapter_change() runs another state.
    world.game_state = "chainsaw.GameStateInGame"
    world.game_state_phase = 0
    class("System.RuntimeType", "System.Object", {
        get_FullName = { 0, function(self) return self.full_name end, {}, { ret = "System.String" } },
    })
    class("share.GameStateBase", "System.Object", {}, { ["<CurrPhase>k__BackingField"] = "System.Int32" })
    class("share.MainModeManager.GameStateControl", "System.Object", {}, { GameState = "share.GameStateBase" })
    class("share.MainModeManager", "System.Object", {
        get_IsInGame = { 0, function()
            if world.main_mode_broken then error("mock: MainModeManager unavailable") end
            return world.game_state == "chainsaw.GameStateInGame"
        end, {}, { ret = "System.Boolean" } },
        get_CurrStateType = { 0, function() return new("System.RuntimeType", { full_name = world.game_state }) end,
            {}, { ret = "System.Type" } },
    }, { CurrentGameState = "share.MainModeManager.GameStateControl" })
    world.singletons["share.MainModeManager"] = new("share.MainModeManager", { __fields = {
        CurrentGameState = new("share.MainModeManager.GameStateControl", { __fields = {
            GameState = new("share.GameStateBase", { __fields = { ["<CurrPhase>k__BackingField"] = 0 } }) } }) } })
    class("chainsaw.CampaignJumper", "System.Object", {
        get_CurrentPhase = { 0, function() return world.jumper_phase or 0 end, {}, { ret = "chainsaw.CampaignJumper.Phase" } },
    })
    world.singletons["chainsaw.CampaignJumper"] = new("chainsaw.CampaignJumper")
    -- Screen fades by share.FadeManager.FadeType: world.fades[type] = true while it is dark.
    world.fades, world.fade_ins = {}, {}
    class("share.FadeManager", "System.Object", {
        isFadeOut = { 1, function(_, t) return world.fades[t] == true end, { "share.FadeManager.FadeType" },
            { ret = "System.Boolean" } },
        ["requestFadeIn(share.FadeManager.FadeType, System.Single, System.String, System.Action)"] = { 4,
            function(_, t, seconds)
                world.fade_ins[#world.fade_ins + 1] = { type = t, seconds = seconds }
                world.fades[t] = nil
                if t == 4 then world.event_fade_held = nil end
            end, { "share.FadeManager.FadeType", "System.Single", "System.String", "System.Action" } },
    })
    world.singletons["share.FadeManager"] = new("share.FadeManager")
    -- HighwayGuiManager.isItemWindowActive: the item window (attache case) is open.
    class("chainsaw.HighwayGuiManager", "System.Object", {
        isItemWindowActive = { 0, function() return world.inventory_open == true end, {}, { ret = "System.Boolean" } },
    })
    world.singletons["chainsaw.HighwayGuiManager"] = new("chainsaw.HighwayGuiManager")
    -- The attache case (docs/RESEARCH.md 3.12): items by Guid; the command list of the item
    -- under the cursor (InventoryManager.getItemCommandMenu, a Dictionary in drawing order),
    -- each command drawn by an ItemCommandGui, the chosen one run by the select-command
    -- state's decide (unknown ones go back to the case).
    world.case = {}          -- Guid text -> chainsaw.Item
    world.case_room = 99     -- how many more items fit
    world.item_types = {}    -- ItemID -> chainsaw.ItemType (default 2, recovery)
    world.item_names = {}    -- ItemID -> name
    enum("chainsaw.ItemCommandType", { Use = 0, Equip = 1, Discard = 10, Store = 13 })
    local DICT_CMD = "System.Collections.Generic.Dictionary`2<chainsaw.ItemCommandType,System.Boolean>"
    class(DICT_CMD, "System.Object", {
        ContainsKey = { 1, function(self, k) return self.map[k] ~= nil end, { "chainsaw.ItemCommandType" },
            { ret = "System.Boolean" } },
        Add = { 2, function(self, k, v)
            assert(self.map[k] == nil, "duplicate key")
            self.map[k] = v
            self.order[#self.order + 1] = k
        end, { "chainsaw.ItemCommandType", "System.Boolean" } },
    })
    class("chainsaw.InventoryManager.GetCommandMenuArgs", "System.Object", {}, { Item = "chainsaw.Item" })
    class("chainsaw.InventoryManager", "System.Object", {
        getItemGetFlag = { 1, function(_, id) return world.item_flags[id] == true end },
        getItemCommandMenu = { 1, function(_, args)
            local d = new(DICT_CMD, { map = {}, order = {} })
            d:call("Add", 0, true)
            d:call("Add", 10, true)
            world.last_menu = d
            return d
        end, { "chainsaw.InventoryManager.GetCommandMenuArgs" } },
    })
    class("chainsaw.ItemIDDefine", "System.Object", {
        getItemType = { 1, function(_, id) return world.item_types[id] or 2 end, { "chainsaw.ItemID" },
            { ret = "chainsaw.ItemType", static = true } },
    })
    class("via.gui.Text", "System.Object", {
        set_Message = { 1, function(self, m) self.message = m end, { "System.String" } },
    })
    class("chainsaw.gui.commandmenu.ItemCommandGui", "System.Object", {
        drawCommand = { 3, function(self, cmd)
            self.__fields._CommandText.message = "command " .. tostring(cmd)
        end, { "chainsaw.ItemCommandType", "System.Boolean", "chainsaw.Item" } },
    }, { _CommandText = "via.gui.Text" })
    class("chainsaw.gui.commandmenu.ItemCommandMenuGui", "System.Object", {
        get_CurrSelectedCommandType = { 0, function() return world.selected_command end, {},
            { ret = "chainsaw.ItemCommandType" } },
    })
    class("chainsaw.AcCommandMenuGuiBehavior", "System.Object", {}, {
        _ItemCommandMenuGui = "chainsaw.gui.commandmenu.ItemCommandMenuGui" })
    class("chainsaw.gui.inventory.CsInventory", "System.Object", {
        ["remove(System.Guid)"] = { 1, function(_, g)
            world.case[g] = nil
            world.case_room = world.case_room + 1
        end, { "System.Guid" } },
    })
    class("chainsaw.gui.inventory.VirtualInventory", "System.Object", {
        ["remove(System.Guid)"] = { 1, function() world.virtual_removed = (world.virtual_removed or 0) + 1 end,
            { "System.Guid" } },
    })
    class("chainsaw.AddItemResult", "System.Object", {}, { AddCount = "System.Int32" })
    class("chainsaw.CsInventoryController", "System.Object", {
        ["getItem(System.Guid)"] = { 1, function(_, g) return world.case[g] end, { "System.Guid" },
            { ret = "chainsaw.Item" } },
        ["add(chainsaw.Item, chainsaw.InventorySlotType)"] = { 2, function(_, item)
            local n = item.__fields._CurrentItemCount
            local fit = math.max(0, math.min(n, world.case_room))
            if fit > 0 then
                world.case_room = world.case_room - 1
                world.case_adds = (world.case_adds or 0) + 1
                local id = ("added-%d"):format(world.case_adds)
                world.case[id] = new("chainsaw.Item", { __fields = { _ItemId = item.__fields._ItemId,
                    _CurrentItemCount = fit, _CurrentDurability = item.__fields._CurrentDurability, _ID = id } })
            end
            return new("chainsaw.AddItemResult", { __fields = { AddCount = fit } })
        end, { "chainsaw.Item", "chainsaw.InventorySlotType" } },
    }, { ["<_CsInventory>k__BackingField"] = "chainsaw.gui.inventory.CsInventory" })
    world.case_ctrl = new("chainsaw.CsInventoryController", { __fields = {
        ["<_CsInventory>k__BackingField"] = new("chainsaw.gui.inventory.CsInventory") } })
    class("chainsaw.AttacheCaseGuiDataHolder", "System.Object", {}, { _Inventory = "chainsaw.gui.inventory.VirtualInventory" })
    -- The player's equipment (a component of its body) holds its attache case controller.
    class("chainsaw.PlayerEquipment", "via.Component", {
        get_InventoryController = { 0, function(self) return self.__fields["<InventoryController>k__BackingField"] end,
            {}, { ret = "chainsaw.CsInventoryController" } },
    }, { ["<InventoryController>k__BackingField"] = "chainsaw.CsInventoryController" })
    class("chainsaw.AttacheCaseManager", "System.Object", {}, {
        ["<AttacheCaseGuiDataHolder>k__BackingField"] = "chainsaw.AttacheCaseGuiDataHolder" })
    world.singletons["chainsaw.AttacheCaseManager"] = new("chainsaw.AttacheCaseManager", { __fields = {
        ["<AttacheCaseGuiDataHolder>k__BackingField"] = new("chainsaw.AttacheCaseGuiDataHolder", { __fields = {
            _Inventory = new("chainsaw.gui.inventory.VirtualInventory") } }) } })
    class("chainsaw.InventoryControllersInfo", "System.Object", {}, { InventoryController = "chainsaw.CsInventoryController" })
    class("chainsaw.ChainsawGuiUtil", "System.Object", {
        -- Two overloads share the name (the first is not the one by ContextID).
        ["getInventoryControllers(chainsaw.CharacterKindID, System.Int32)"] = { 2, function() return nil end,
            { "chainsaw.CharacterKindID", "System.Int32" }, { ret = "chainsaw.InventoryControllersInfo", static = true } },
        ["getInventoryControllers(chainsaw.ContextID)"] = { 1, function()
            return new("chainsaw.InventoryControllersInfo", { __fields = { InventoryController = world.case_ctrl } })
        end, { "chainsaw.ContextID" }, { ret = "chainsaw.InventoryControllersInfo", static = true } },
        generateItem = { 6, function(_, id, count, durability)
            return new("chainsaw.Item", { __fields = { _ItemId = id, _CurrentItemCount = count,
                _CurrentDurability = durability, _ID = "new" } })
        end, { "chainsaw.ItemID", "System.Int32", "System.Int32", "chainsaw.ItemID", "System.Int32", "System.Boolean" },
            { ret = "chainsaw.Item", static = true } },
    })
    class("chainsaw.ItemMessageManager", "System.Object", {
        getItemNameMsgId = { 1, function(_, id) return world.item_names[id] and ("msg:" .. id) or nil end,
            { "chainsaw.ItemID" }, { ret = "System.Guid" } },
    })
    -- Not a singleton of its own: ItemManager.get_ItemMessageManager.
    class("chainsaw.ItemManager", "System.Object", {
        get_ItemMessageManager = { 0, function() return world.item_messages end, {}, { ret = "chainsaw.ItemMessageManager" } },
    })
    world.item_messages = new("chainsaw.ItemMessageManager")
    world.singletons["chainsaw.ItemManager"] = new("chainsaw.ItemManager")
    class("via.gui.message", "System.Object", {
        ["get(System.Guid)"] = { 1, function(_, g)
            local id = tonumber(tostring(g):match("^msg:(%d+)$"))
            return id and world.item_names[id] or nil
        end, { "System.Guid" }, { ret = "System.String", static = true } },
    })
    class("chainsaw.ItemWindowGuiState_AttacheCaseSelectCommand.EnterParam", "System.Object", {}, { TargetID = "System.Guid" })
    class("chainsaw.ItemWindowGuiState_AttacheCaseSelectCommand", "System.Object", {
        get__CommandMenuGuiBehavior = { 0, function(self) return self.behavior end, {}, { ret = "chainsaw.AcCommandMenuGuiBehavior" } },
        get__InventoryController = { 0, function() return world.case_ctrl end, {}, { ret = "chainsaw.CsInventoryController" } },
        decide = { 0, function(self)
            if world.selected_command == 10 then
                world.case[self.__fields._CurrEnterParam.__fields.TargetID] = nil
            else
                world.case_default = (world.case_default or 0) + 1 -- transitAttacheCaseDefault
            end
        end },
    }, { _CurrEnterParam = "chainsaw.ItemWindowGuiState_AttacheCaseSelectCommand.EnterParam" })
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
    class("chainsaw.HateTargetInfo", "System.Object", {}, { _Target = "via.GameObject", _Hate = "System.Single",
        ["<TargetGameObject>k__BackingField"] = "via.GameObject" })
    class("chainsaw.HateController", "via.Component", {
        -- HateController.lose(GameObject): the target is forgotten.
        lose = { 1, function(self, go)
            self.lost = self.lost or {}
            self.lost[#self.lost + 1] = go
            local cur = self.__fields["<CurrentTarget>k__BackingField"]
            if cur ~= nil and cur.__fields["<TargetGameObject>k__BackingField"] == go then
                self.__fields["<CurrentTarget>k__BackingField"] = nil
            end
        end, { "via.GameObject" } },
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
        ["findGameObject(System.Guid)"] = { 1, function(_, g)
            local text = g and g.text
            for _, go in ipairs(world.gos) do
                if text ~= nil and go.guid == text and not go.destroyed then return go end
            end
            return nil
        end, { "System.Guid" } },
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
        [M.PREFAB.sr1903] = function(pos) return M.build_scoped_weapon("wp4400", pos) end,
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
        to_ptr = function(v) return v end, -- objects stay objects here: a post-hook's return goes to the caller as is
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
    _G.ValueType = { new = function(td) return new(td.name) end }
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
    M.elements_container = opts.elements_container == true
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
    install_player_grab()
    install_player_deaths()
    return world
end

-------------------------------------------------------------------------------
-- The partner as a second player (game_partner.lua, docs/RESEARCH.md 3.25)
-------------------------------------------------------------------------------

function M.install_partner(world)
    world.noises, world.hit_controllers, world.attack_catalog = {}, {}, {}
    world.marker_registrations = 0
    -- BodyUpdater: answers which character its GameObject is (IContextAccessor.<Context>).
    class("chainsaw.BodyUpdater", "via.Component", {}, { ["<Context>k__BackingField"] = "chainsaw.Context" })
    class("chainsaw.PlayerBodyUpdater", "chainsaw.BodyUpdater", {})
    -- The player context class (CharacterContext's constructor makes its HitPoint).
    class("chainsaw.ChCommonPlContext", "chainsaw.PlayerBaseContext", {
        [".ctor"] = { 0, function(self)
            self.pos, self.hp, self.max_hp = M.vec(0, 0, 0), 2520, 2520
            M.add_hitpoint(self)
        end },
        initialize = { 6, function(self, id, kind)
            self.__fields._ID = id
            self.kind_id = kind
            self.initialized = (self.initialized or 0) + 1
        end },
        get_BodyGameObject = { 0, function(self)
            local u = self.__fields._BodyUpdater
            return u and u.owner or nil
        end },
    }, { ["<KindID>k__BackingField"] = "chainsaw.CharacterKindID", ["<Setupped>k__BackingField"] = "System.Boolean",
        _BodyUpdater = "chainsaw.CharacterBodyUpdater", _HeadUpdater = "chainsaw.CharacterHeadUpdater",
        ["<Position>k__BackingField"] = "via.vec3",
        ["<Rotation>k__BackingField"] = "via.Quaternion", ["<LastValidPosition>k__BackingField"] = "via.vec3",
        ["<LastValidRotation>k__BackingField"] = "via.Quaternion" })
    -- TargetMarker: what enemies' sight sensors look for, filed under its GameObject's tag.
    class("chainsaw.TargetMarker", "via.Component", {
        register = { 0, function(self)
            self.registrations = (self.registrations or 0) + 1
            world.marker_registrations = world.marker_registrations + 1
            self.registered_tag = self.owner and self.owner.tag
        end },
        unregister = { 0, function(self) self.registrations = math.max(0, (self.registrations or 0) - 1) end },
        get_IsRegistered = { 0, function(self) return (self.registrations or 0) > 0 end, {}, { ret = "System.Boolean" } },
    }, { _UseTargetJoint = "System.Boolean", _TargetOffset = "via.vec3" })
    -- AttackUserData: the attack's identity in HitManager's catalog; get_IsGrapple.
    local au = classes["chainsaw.collision.AttackUserData"]
    au.fields._AttackHitDataID, au.fields._KeyNameHash = "chainsaw.collision.AttackDataID", "System.UInt32"
    au.methods.get_IsGrapple = M.make_method("get_IsGrapple", 0, function(self) return self.grapple == true end, {},
        { ret = "System.Boolean" })
    au.method_order[#au.method_order + 1] = "get_IsGrapple"
    -- HitManager: the HitControllers that can be hit (by GameObject), the attack catalog, and
    -- hitSetting (0x142357370): IsKill, the damaged character's check, the non-lethal attacks'
    -- last HP, DamageCalcInfo.copy, callbackDamageHit.
    class("chainsaw.HitManager", "System.Object", {
        registerHitController = { 1, function(_, hc) world.hit_controllers[hc.owner] = hc end, { "chainsaw.HitController" } },
        unregisterHitController = { 1, function(_, hc)
            if world.hit_controllers[hc.owner] == hc then world.hit_controllers[hc.owner] = nil end
        end, { "chainsaw.HitController" } },
        getHitController = { 1, function(_, go) return world.hit_controllers[go] end, { "via.GameObject" } },
        getAttackData = { 2, function(_, id, hash) return world.attack_catalog[tostring(id) .. ":" .. tostring(hash)] end,
            { "chainsaw.collision.AttackDataID", "System.UInt32" } },
        hitSetting = { 3, function(_, info, attacker, damaged)
            local d = info.data
            d.IsKill = damaged:call("checkKill", d.Damage or 0)
            if damaged:call("callbackCheckDamageHit", info) == false then return false end
            local ad = d.AttackData
            if ad ~= nil and ((ad.__fields._Option or 0) & 4) ~= 0 and damaged:call("checkKill", d.Damage or 0) then
                d.Damage = math.max(0, (damaged:call("get_CurrentHitPoint") or 1) - 1)
            end
            d.IsKill = damaged:call("checkKill", d.Damage or 0)
            local calc = damaged.__fields["<DamageCalcInfo>k__BackingField"]
            if calc ~= nil then calc:call("copy", info) end
            damaged:call("callbackDamageHit", info)
            world.attacks_landed = (world.attacks_landed or 0) + 1
            return true
        end, { "chainsaw.HitController.DamageInfo", "chainsaw.HitController", "chainsaw.HitController" },
            { ret = "System.Boolean" } },
    })
    world.singletons["chainsaw.HitManager"] = M.new("chainsaw.HitManager")
    -- SoundDetectionManager: the sounds enemies hear (registerSound).
    class("chainsaw.SoundDetectionInfo", "System.Object", {}, { Position = "via.vec3", Radius = "System.Single",
        Height = "System.Single", Volume = "System.Single", SubVolumePerSec = "System.Single",
        ["<OwnerGameObject>k__BackingField"] = "via.GameObject", ["<RequestGameObject>k__BackingField"] = "via.GameObject" })
    class("chainsaw.SoundDetectionManager", "System.Object", {
        registerSound = { 1, function(_, info) world.noises[#world.noises + 1] = info end, { "chainsaw.SoundDetectionInfo" } },
    })
    world.singletons["chainsaw.SoundDetectionManager"] = M.new("chainsaw.SoundDetectionManager")

    -- 0.10.1 (docs/RESEARCH.md 3.26). HitController.poolDamage (0x142009ef0): the attacker's
    -- controller pools a contact's damage and decides whether the body shields the attack.
    local hc_cls = classes["chainsaw.HitController"]
    hc_cls.methods.poolDamage = make_method("poolDamage", 4, function(self, _, au, du)
        world.pooled = world.pooled or {}
        world.pooled[#world.pooled + 1] = { attacker = self, attack = au, damage = du }
    end, { "via.physics.CollisionInfo", "chainsaw.collision.AttackUserData", "chainsaw.collision.DamageUserData",
        "System.Boolean" })
    hc_cls.methods.get_AttackOwner = make_method("get_AttackOwner", 0, function(self) return self.attack_owner end)
    hc_cls.method_order[#hc_cls.method_order + 1] = "poolDamage"
    hc_cls.method_order[#hc_cls.method_order + 1] = "get_AttackOwner"
    class("chainsaw.ShellBase", "via.Component", {}, { ["<AttackOwner>k__BackingField"] = "via.GameObject" })
    -- An enemy's body updater: its attack's warning (action sign) and its parry answer.
    class("chainsaw.EnemyActionSignTrack.EnemyActionSignInfo", "System.Object", {}, { _SignType = "chainsaw.ActionSignType",
        _ButtonSetting = "chainsaw.ActionSignButton", _JustTiming = "System.Boolean", _ActTiming = "System.Boolean",
        _TargetAngleCheck = "System.Boolean", _Distance = "System.Single" })
    class("chainsaw.ParryResult", "System.Object", {
        get_Successful = { 0, function(self) return self.ok == true end, {}, { ret = "System.Boolean" } },
    })
    class("chainsaw.EnemyBodyUpdater", "via.Component", {
        checkEnableActionSign = { 0, function(self) return self.sign ~= nil end, {}, { ret = "System.Boolean" } },
        getActionSignInfo = { 0, function(self) return self.sign end },
        checkJustTimingActionSign = { 0, function(self) return self.just == true end, {}, { ret = "System.Boolean" } },
        onParry = { 2, function(self, go, sign)
            world.parries = world.parries or {}
            world.parries[#world.parries + 1] = { body = self, by = go, sign = sign }
            return new("chainsaw.ParryResult", { ok = self.parry_ok ~= false })
        end, { "via.GameObject", "chainsaw.ActionSignType" } },
        onParryInput = { 0, function(self) self.parry_inputs = (self.parry_inputs or 0) + 1 end },
    })
    -- EnemyActionSignUtility.sendActionSignInfo(owner, target, info): to the target's player head.
    class("chainsaw.EnemyActionSignUtility", "System.Object", {
        sendActionSignInfo = { 3, function(_, owner, target, info)
            world.signs_delivered = world.signs_delivered or {}
            world.signs_delivered[#world.signs_delivered + 1] = { owner = owner, target = target, info = info }
        end, { "via.GameObject", "via.GameObject", "chainsaw.EnemyActionSignTrack.EnemyActionSignInfo" } },
    })
    -- Grabs on the enemy's AI head (EnemyHeadUpdater): requestGrapple, the rejected grab.
    local head_cls = classes["chainsaw.HeadUpdater"]
    for name, spec in pairs({
        requestGrapple = { 2, function(self, target, action)
            if self.context then self.context.__fields["<GrappleTarget>k__BackingField"] = target end
            self.grab_action = action
        end, { "via.GameObject", "System.UInt32" } },
        onRejectGrapple = { 1, function(self, action)
            self.rejected = (self.rejected or 0) + 1
            self.rejected_action = action
        end, { "System.UInt32" } },
        clearGrappleTarget = { 0, function(self)
            if self.context then self.context.__fields["<GrappleTarget>k__BackingField"] = nil end
        end },
    }) do
        head_cls.methods[name] = make_method(name, spec[1], spec[2], spec[3])
        head_cls.method_order[#head_cls.method_order + 1] = name
    end
    classes["chainsaw.EnemyHeadUpdater"] = head_cls
    -- A grabbing Ganado's escape check (a behavior tree action) and its argument.
    class("via.behaviortree.ActionArg", "System.Object", {
        ["getComponent(System.Type)"] = { 1, function(self, t) return M.component(self.owner, t.name) end, { "System.Type" } },
        notifyActionEnd = { 0, function(self) self.done = true end },
    })
    class("chainsaw.Ch1c0z0BehaviorTreeAction_CheckEscapeGrapple", "System.Object", {
        update = { 1, function(self, arg) self.updates = (self.updates or 0) + 1 end, { "via.behaviortree.ActionArg" } },
        onSuccessfulEscape = { 1, function(self, arg)
            self.escaped = true
            local body = M.component(arg.owner, "chainsaw.EnemyBodyUpdater")
            local ctx = body and body.ctx
            if ctx then ctx.__fields["<GrappleTarget>k__BackingField"] = nil end
        end, { "via.behaviortree.ActionArg" } },
    }, { NumberOfStruggles = "System.Int32", isEnableKnifeEscape = "System.Boolean" })
    -- ActionTargetController.setTypeTarget(type, target): what the enemy aims at.
    class("chainsaw.ActionTargetController", "via.Component", {
        ["setTypeTarget(chainsaw.TargetType, via.GameObject)"] = { 2, function(self, t, go)
            self.target_type, self.target = t, go
        end, { "chainsaw.TargetType", "via.GameObject" } },
        get_HateController = { 0, function(self) return self.hate end },
    })
    -- The player's side: the warning on its head, its input, its grab state.
    local ph = classes["chainsaw.PlayerHeadUpdater"]
    ph.methods.onHitActionSign = make_method("onHitActionSign", 1, function(self, info)
        self.signs = self.signs or {}
        self.signs[#self.signs + 1] = { owner = info.__fields.OwnerGameObject, sign = info.__fields.SignType,
            just = info.__fields.JustTiming }
    end, { "chainsaw.ActionSignHitInfo" })
    ph.method_order[#ph.method_order + 1] = "onHitActionSign"
    class("chainsaw.ActionSignHitInfo", "System.Object", {}, { OwnerGameObject = "via.GameObject",
        SignType = "chainsaw.ActionSignType", ButtonType = "chainsaw.ActionSignButton", JustTiming = "System.Boolean",
        ActTiming = "System.Boolean", TargetAngleCheck = "System.Boolean" })
    class("share.hid.Command", "System.Object", {
        ["isTrigger(System.UInt32)"] = { 1, function(self, h) return (self.pressed or {})[h] == true end,
            { "System.UInt32" }, { ret = "System.Boolean" } },
    })
    -- via.physics.RequestSetCollider: request sets, each with its collidables, registered (in
    -- the physics world while the component is on) or not. set = { id, cols, user_data,
    -- registered }.
    local function set_by_id(rsc, id)
        for _, set in ipairs(rsc.sets or {}) do
            if (set.id or 0) == id then return set end
        end
        return nil
    end
    class("via.physics.RequestSetCollider.RequestSetGroup", "System.Object", {
        ["getRequestSetIdFromIndex(System.UInt32)"] = { 1, function(self, i)
            local set = (self.rsc.sets or {})[i + 1]
            return set and (set.id or i) or 0
        end, { "System.UInt32" }, { ret = "System.UInt32" } },
    })
    class("via.physics.RequestSetCollider", "via.Component", {
        ["getRequestSetGroups(System.UInt32)"] = { 1, function(self, i)
            if i ~= 0 then return nil end
            self.group = self.group or M.new("via.physics.RequestSetCollider.RequestSetGroup", { rsc = self })
            return self.group
        end, { "System.UInt32" } },
        ["isRegisteredRequestSetFromIndex(System.UInt32)"] = { 1, function(self, i)
            local set = (self.sets or {})[i + 1]
            return set ~= nil and set.registered ~= false
        end, { "System.UInt32" }, { ret = "System.Boolean" } },
        ["registerRequestSet(System.UInt32)"] = { 1, function(self, id)
            local set = set_by_id(self, id)
            if set then set.registered = true end
        end, { "System.UInt32" } },
        ["unregisterRequestSet(System.UInt32)"] = { 1, function(self, id)
            local set = set_by_id(self, id)
            if set then set.registered = false end
        end, { "System.UInt32" } },
        get_NumRequestSets = { 0, function(self) return #(self.sets or {}) end, {}, { ret = "System.UInt32" } },
        ["getRequestSetUserDataFromIndex(System.UInt32)"] = { 1, function(self, i)
            local set = (self.sets or {})[i + 1]
            return set and set.user_data
        end, { "System.UInt32" } },
        ["getNumCollidablesFromIndex(System.UInt32)"] = { 1, function(self, i)
            local set = (self.sets or {})[i + 1]
            return set and #set.cols or 0
        end, { "System.UInt32" }, { ret = "System.UInt32" } },
        ["getCollidableFromIndex(System.UInt32, System.UInt32)"] = { 2, function(self, i, j)
            local set = (self.sets or {})[i + 1]
            return set and set.cols[j + 1]
        end, { "System.UInt32", "System.UInt32" } },
    })
    hc_cls.methods.get_RequestSetCollider = make_method("get_RequestSetCollider", 0, function(self) return self.request_set end)
    hc_cls.method_order[#hc_cls.method_order + 1] = "get_RequestSetCollider"
    class("chainsaw.collision.GrappleUserData", "chainsaw.collision.AttackUserData", {},
        { _GrapplePriority = "chainsaw.collision.AttackPriority" })
end

-- Moves enemy `ctx`'s damage colliders from its HitController's Colliders into a
-- RequestSetCollider, where the game's enemies keep them (EnemyDamageUserData is a
-- RequestSetColliderUserData): request sets of `per_set` collidables each.
function M.colliders_in_request_sets(ctx, per_set)
    local hc = M.component(ctx.body, "chainsaw.HitController")
    local cols = hc.colliders and hc.colliders.list or {}
    local sets, cur = {}, nil
    for _, c in ipairs(cols) do
        if cur == nil or #cur.cols >= (per_set or 2) then
            cur = { cols = {}, user_data = M.new("chainsaw.collision.PressUserData") }
            sets[#sets + 1] = cur
        end
        cur.cols[#cur.cols + 1] = c
    end
    hc.request_set = M.new("via.physics.RequestSetCollider", { sets = sets })
    hc.colliders = M.new("via.physics.Colliders", { list = {} })
    return hc.request_set
end

-- Enemy `ctx`'s body updater (chainsaw.EnemyBodyUpdater, CharacterContext.get_BodyUpdater).
function M.enemy_body_updater(ctx)
    if ctx.body_updater == nil then ctx.body_updater = M.add_component(ctx.body, "chainsaw.EnemyBodyUpdater", { ctx = ctx }) end
    return ctx.body_updater
end

-- Enemy `ctx`'s head and body updaters seen as a villager's (Ch1c0HeadUpdaterCommon,
-- Ch1c0BodyUpdaterCommon): the same objects - same addresses - as get_HeadUpdater /
-- get_BodyUpdater give, where the parts-break methods run.
function M.villager_head(ctx)
    if ctx.villager_head ~= nil then return ctx.villager_head end
    local body = new("chainsaw.Ch1c0BodyUpdaterCommon")
    if ctx.body ~= nil then body.__addr = M.enemy_body_updater(ctx).__addr end
    local hu = new("chainsaw.Ch1c0HeadUpdaterCommon", { body = body })
    if ctx.head_updater ~= nil then hu.__addr = ctx.head_updater.__addr end
    ctx.villager_head = hu
    return hu
end

-- The game runs `enemy`'s death over the next frames (its AI's death action, after the hit or
-- entryDeadAction): a villager draws lots for a head burst then too, with the death's own
-- (engine-owned) damage. Returns whether a part broke.
function M.death_frame(enemy)
    if enemy.dying == nil then return false end
    local hu = M.villager_head(enemy)
    local info = new("chainsaw.HitController.DamageInfo", { data = { Damage = 0 } })
    info.engine_owned = true
    local before = M.world.parts_broken
    local burst = hu:call("lotteryBreakHead", info)
    if burst == true or (type(burst) == "number" and burst ~= 0) then hu:call("onPartsBreak", info, 0, 0) end
    return M.world.parts_broken > before
end

-- An attack's warning (EnemyActionSignInfo). opts: { sign, button, just, act, distance }
function M.sign_info(opts)
    opts = opts or {}
    return M.new("chainsaw.EnemyActionSignTrack.EnemyActionSignInfo", { __fields = { _SignType = opts.sign or 0,
        _ButtonSetting = opts.button or 0, _JustTiming = opts.just == true, _ActTiming = opts.act ~= false,
        _TargetAngleCheck = false, _Distance = opts.distance or 3 } })
end

-- The first DamageUserData of HitController `hc`: of its Colliders, else of its
-- RequestSetCollider's registered request sets.
function M.first_damage_ud(hc)
    local function is_damage(ud) return ud ~= nil and ud.__type:find("DamageUserData", 1, true) ~= nil end
    for _, c in ipairs(hc and hc.colliders and hc.colliders.list or {}) do
        if is_damage(c.user_data) then return c.user_data end
    end
    for _, set in ipairs(hc and hc.request_set and hc.request_set.sets or {}) do
        if set.registered ~= false then
            for _, c in ipairs(set.cols) do
                if is_damage(c.user_data) then return c.user_data end
            end
        end
    end
    return nil
end

-- Leon's colliders as ch0a0z0_body.pfb and ch0a0z0.rcol build them, on `body`: a
-- via.physics.Colliders with one sphere without damage data, and a RequestSetCollider whose
-- request sets hold his body's shapes - Damage (head, chest: PlayerDamageUserData), Press,
-- Target, a kick (AttackUserData, not registered) and ArmorDamage (not registered).
-- Returns the Colliders and the RequestSetCollider.
function M.leon_colliders(body)
    local function col(ud) return M.new("via.physics.Collider", { user_data = ud }) end
    local function damage(part) return col(M.new("chainsaw.collision.PlayerDamageUserData",
        { __fields = { Parts = part, PartsSide = 0 } })) end
    local function set_ud() return M.new("via.physics.RequestSetColliderUserData") end
    local cols = M.add_component(body, "via.physics.Colliders", { list = { col(M.new("via.physics.UserData")) } })
    local rsc = M.add_component(body, "via.physics.RequestSetCollider", { sets = {
        { id = 0, name = "Damage", registered = true, user_data = set_ud(), cols = { damage(1), damage(0) } },
        { id = 1, name = "Press", registered = true, user_data = set_ud(),
            cols = { col(M.new("chainsaw.collision.PressUserData")) } },
        { id = 2, name = "Target", registered = true, user_data = set_ud(), cols = { col(M.new("via.physics.UserData")) } },
        { id = 5, name = "NormalKick", registered = false, user_data = set_ud(),
            cols = { col(M.new("chainsaw.collision.AttackUserData")) } },
        { id = 18, name = "ArmorDamage", registered = false, user_data = set_ud(), cols = { damage(1), damage(0) } },
    } })
    return cols, rsc
end

-- A contact of `attacker_hc`'s attack on `go`'s first damage collider, the way the engine
-- reports it (HitController.poolDamage, hooks around it). Returns whether it was pooled.
function M.contact(attacker_hc, go)
    local hc = M.world.hit_controllers[go] or M.component(go, "chainsaw.HitController")
    local du = M.first_damage_ud(hc)
    local before = #(M.world.pooled or {})
    attacker_hc:call("poolDamage", nil, M.new("chainsaw.collision.AttackUserData"), du, false)
    return #(M.world.pooled or {}) > before
end

-- A character's damage colliders: chest and head (chainsaw.collision.DamageUserData).
function M.damage_colliders(type_name)
    local list = {}
    for _, part in ipairs({ { 1, 0 }, { 0, 0 } }) do
        list[#list + 1] = M.new("via.physics.Collider", { user_data = M.new(type_name or "chainsaw.collision.DamageUserData",
            { __fields = { Parts = part[1], PartsSide = part[2] } }) })
    end
    return M.new("via.physics.Colliders", { list = list })
end

-- A HitController as the game constructs it (its Delegates and DamageCalcInfo exist).
function M.add_hit_controller(go, ctx, cols, request_set)
    return M.add_component(go, "chainsaw.HitController", { ctx = ctx, colliders = cols, request_set = request_set, __fields = {
        ["<Delegate>k__BackingField"] = M.new("chainsaw.HitController.Delegates"),
        ["<DamageCalcInfo>k__BackingField"] = M.new("chainsaw.HitController.DamageInfo") } })
end

-- Enemy `enemy` targets `go` (its HateController's current target).
function M.target(enemy, go)
    local hate = enemy.hate
    local info = M.new("chainsaw.HateTargetInfo")
    info.__fields["<TargetGameObject>k__BackingField"] = go
    hate.__fields["<CurrentTarget>k__BackingField"] = info
end

-- Enemy `enemy`'s attack lands on `go`, the way the engine resolves it: HitManager finds the
-- damaged HitController by GameObject and runs hitSetting (hooks around it). opts: { attack_id,
-- key, grapple, option, owner (the attack's owner GameObject, default the enemy's body) }.
-- Returns hitSetting's result, or nil when `go` has no registered HitController.
function M.enemy_attack(enemy, go, damage, opts)
    opts = opts or {}
    local hm = M.world.singletons["chainsaw.HitManager"]
    local damaged = hm:call("getHitController", go)
    if damaged == nil then return nil end
    local attacker = M.component(enemy.body, "chainsaw.HitController")
    local au = M.new("chainsaw.collision.AttackUserData", { grapple = opts.grapple, __fields = {
        _AttackHitDataID = opts.attack_id or 1100, _KeyNameHash = opts.key or 0xABC } })
    local ad = M.new("chainsaw.collision.AttackHitUserData.AttackData", { __fields = { _AttackType = 4, _AttackPower = 1,
        _Option = opts.option or 0 } })
    local du = M.first_damage_ud(damaged)
    local owner = opts.owner or enemy.body
    local info = M.new("chainsaw.HitController.DamageInfo", { data = { Damage = damage, Wince = 20, Break = 0,
        Stopping = 0, DamageDir = M.vec(1, 0, 0), Position = M.vec(0, 1, 0), WeaponID = 0, IsCritical = false,
        IsKill = false, AttackOwnerObject = owner, AttackGameObject = owner, DamageGameObject = go, AttackUserData = au,
        AttackData = ad, DamageUserData = du } })
    return hm:call("hitSetting", info, attacker, damaged)
end

-- A sound the game registers (SoundDetectionManager.registerSound) with `owner` as its owner.
function M.make_noise(owner, pos, volume)
    local info = M.new("chainsaw.SoundDetectionInfo", { __fields = { Position = M.vec(pos.x, pos.y, pos.z), Radius = 12,
        Height = 3, Volume = volume or 0.6, SubVolumePerSec = 0.5, ["<OwnerGameObject>k__BackingField"] = owner,
        ["<RequestGameObject>k__BackingField"] = owner } })
    return M.world.singletons["chainsaw.SoundDetectionManager"]:call("registerSound", info)
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

-- GimmickManager's update: every registered animal's state machine runs (it moves by
-- `wander` per frame when it has one).
function M.update_gimmicks()
    for _, list in pairs(M.world.components) do
        for _, c in ipairs(list) do
            if c.core ~= nil and M.world.moving[c.core] and not c.owner.destroyed then
                c.ai_frames = (c.ai_frames or 0) + 1
                if c.wander then
                    local p = c.owner.transform.wpos
                    p.x, p.y, p.z = p.x + c.wander.x, p.y + c.wander.y, p.z + c.wander.z
                end
            end
        end
    end
end

-- One update of every trap in the scene (GmLegHoldTrap / GmSensorBomb.updateGimmick, reduced
-- to what the sync relies on).
function M.update_traps()
    for _, c in ipairs(M.world.components["chainsaw.GmLegHoldTrap"] or {}) do
        local f = c.__fields
        if not c.owner.destroyed then
            if f._Routine == 2 then -- Close: the snap and its sound, the flag, then Closed
                if f._Rno == 0 then
                    M.world.trap_sounds = M.world.trap_sounds + 1
                    c.flag = true
                    f._Rno = 1
                else
                    f._Routine, f._Rno = 3, 0
                end
            elseif f._Routine == 1 then -- Bite: holds whoever stepped in, then Closed (no flag)
                f._Routine, f._Rno = 3, 0
            elseif f._Routine == 7 then -- OpenByEm: open again
                f._Routine, f._Rno = 0, 0
            end
        end
    end
    for _, c in ipairs(M.world.components["chainsaw.GmSensorBomb"] or {}) do
        local f = c.__fields
        if not c.owner.destroyed then
            if f._Routine == 0 and c.flag then -- Wait watches the flag: Bomb
                f._Routine, f._Rno = 1, 0
            elseif f._Routine == 1 then -- the explosion, then Done
                M.world.explosions = M.world.explosions + 1
                f._Routine, f._Rno = 4, 0
            end
        end
    end
end

-- A mechanism in the scene: a GameObject (scene GUID) with a gimmick of `gimmick_type` and its
-- PortrayalSettings. on_call(key) is what the sequence does (e.g. open a door).
function M.make_mechanism(guid, gimmick_type, on_call, callees, end_callees)
    local go = M.make_go(gimmick_type:match("([^.]+)$"))
    go.guid = guid
    local gimmick = M.add_component(go, gimmick_type)
    local list, ends = {}, {}
    for _, c in ipairs(callees or {}) do list[#list + 1] = new(c) end
    for _, c in ipairs(end_callees or {}) do ends[#ends + 1] = new(c) end
    local param = new("chainsaw.PortrayalSettings.Param", { __fields = { _CalleePlay = typed_array("System.Object", list),
        _CalleeEnd = typed_array("System.Object", ends) } })
    local settings = new("chainsaw.OptionSettings`1<chainsaw.PortrayalSettings.Param>", { __fields = {
        _Params = typed_array("chainsaw.PortrayalSettings.Param", { param }) } })
    local port = M.add_component(go, "chainsaw.PortrayalSettings", { __fields = { _Params = settings }, on_call = on_call })
    return { go = go, gimmick = gimmick, port = port }
end

-- Every playing sequence ends (PortrayalSettings.update -> Param.onFinish: the end effects run).
function M.finish_portrayals()
    local playing = M.world.playing_params or {}
    M.world.playing_params = {}
    for _, param in ipairs(playing) do param:call("onFinish") end
end

-- The game plays a sequence of that mechanism (a player used it).
function M.play_portrayal(mech, key)
    mech.port:call("call(System.UInt32, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)", key, nil, nil)
end

-- A cart / shelf the player can push (GmPushMove), not moved yet.
function M.make_push(guid)
    local go = M.make_go("GmPushMove")
    go.guid = guid
    local comp = M.add_component(go, "chainsaw.GmPushMove", { motion = 100, __fields = { _Move = vec(0, 0, 3) } })
    return comp
end

-- The player pushes it: GmPushMove.onAcceptExecute (motion, blocker, flag).
function M.push(comp)
    comp:call("setGmMotion", 101)
    comp:call("moveEffectorShape", comp.__fields._Move)
    comp:call("setGmFlag", true, nil, nil)
end

-- A bear trap or sensor bomb in the scene with that GameObject GUID (routine 0: open / armed).
function M.make_trap(type_name, guid, pos, routine, flagged)
    local comp = M.make_object(type_name, guid, pos, routine or 0)
    comp.__fields._Rno = 0
    comp.flag = flagged == true
    return comp
end

-- ClapperboardMediator.procSkip: a skip input on a camera that can be skipped skips it; it
-- ends a frame later (after its fade).
-- ClapperboardMediator.procSkip each frame, with the EVENT layer the way the game counts it
-- (FadeController._RefCounter): a skip fades that layer out and the end fades it in once; a
-- skip that lands while the cutscene's start fade still holds the layer dark adds a fade-out
-- nothing lifts, and the cutscene's own fade-in never comes - it stays black (rec.stuck).
--
-- A skipped camera that ends fades the EVENT layer back in over world.skip_fade_frames frames
-- (0 by default). A request queued behind it starts once the screen is free
-- (ClapperboardMediator.updateWork); one that starts inside that fade asks for its own start
-- fade-out while the layer is still dark - the count goes up, nothing calls it back - so it
-- never plays and the layer never lights (rec.stuck_start; the black after the bell,
-- docs/RESEARCH.md 3.37).
function M.update_cutscene_skip()
    local w = M.world
    if w == nil then return end
    if (w.skip_fade_left or 0) > 0 then
        w.skip_fade_left = w.skip_fade_left - 1
        if w.skip_fade_left == 0 and not w.event_fade_held then w.fades[4] = nil end
    end
    if w.current_cutscene == nil and w.queued ~= nil and #w.queued > 0 then
        local q = table.remove(w.queued, 1)
        M.start_camera(q)
        if (w.skip_fade_left or 0) > 0 then
            q.stuck_start = true
            w.event_fade_held = true
            w.fades[4] = true
            w.stuck_starts = (w.stuck_starts or 0) + 1
        end
        return
    end
    local rec = w.current_cutscene
    if rec == nil or rec.work == nil or rec.stuck_start then return end
    local f = rec.work.__fields
    rec.age = (rec.age or 0) + 1
    local playing = rec.age >= (rec.load_frames or 0)
    if rec.holds_event_fade and not rec.stuck and rec.age >= (rec.load_frames or 0) + (rec.fade_frames or 0) then
        rec.holds_event_fade = false
        w.fades[4] = nil -- the start fade is over: the cutscene is on screen
    end
    if playing and rec.can_skip and not f.DoneSkip then f.DispUI = true end
    if f.DoneSkip then
        if rec.stuck then return end
        rec.skipped = true
        w.skips = (w.skips or 0) + 1
        M.end_cutscene()
        if (w.skip_fade_frames or 0) > 0 then
            w.fades[4] = true
            w.skip_fade_left = w.skip_fade_frames
        end
    elseif f.InputSkip and rec.can_skip and playing then
        f.DoneSkip = true
        if w.fades[4] then
            rec.stuck = true -- its skip fade-out never completes: the camera stays, the layer stays dark
            w.stuck_skips = (w.stuck_skips or 0) + 1
        end
    end
end

-- The player holds the skip button during the playing cutscene.
function M.press_skip()
    local rec = M.world.current_cutscene
    if rec and rec.work then rec.work.__fields.InputSkip = true end
end

-- One game frame in REFramework's order: behaviour updates, animation, end of frame,
-- presentation, menu.
function M.run_frame()
    M.update_gimmicks()
    M.update_doors()
    M.update_cutscene_skip()
    for _, cb in ipairs(M.callbacks.entry) do
        if cb.name == "LateUpdateBehavior" then cb.fn() end
    end
    M.update_partners()
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

M.add_hitpoint = add_hitpoint

-- A character created by a level spawn param carries that spawn param's ContextID as its
-- own `_ID` (level data: category 0 = Character, e.g. group 12); one created at runtime gets
-- CharacterManager.generateDynamicContextID's ContextID(Character, 0, group 1, counter).
local next_runtime_index = 300
local function runtime_id(ctx)
    next_runtime_index = next_runtime_index + 1
    ctx.__fields._ID = context_id({ category = 0, kind = 0, group = 1, index = next_runtime_index })
end

local function motion_layers()
    return { new("via.motion.TreeLayer", { bank = 100, motion = 1201, frame = 12.5 }),
        new("via.motion.TreeLayer", { bank = 100, motion = 50, frame = 0 }) }
end

-- Creates a character context with HP, a body GameObject, a Transform and a joint tree
-- (enemies, simple players). spawner: optional {group, index, kind, category}: the ContextID
-- of the level spawn param that created it (the same on every machine), which becomes the
-- character's `_ID` too; without one the character gets a runtime ID.
function M.make_character(type_name, pos, hp, spawner)
    local ctx = new(type_name, { pos = vec(pos.x, pos.y, pos.z), hp = hp, max_hp = hp, yaw = 0 })
    if spawner ~= nil then
        ctx.__fields._ID = context_id(spawner)
        if (spawner.category or 0) == 0 and spawner.group ~= 1 then
            ctx.spawn_param = new("chainsaw.CharacterSpawnParam", { ctx = ctx, owner = M.make_go("spawner") })
        end
    else
        runtime_id(ctx)
    end
    ctx.spawner = context_id(spawner)
    add_hitpoint(ctx)
    local body = M.make_go(type_name:match("Ch%w+") and (type_name:match("(Ch%w+)Context") .. "_body") or "body",
        { link = ctx.pos })
    M.add_joints(body.transform, JOINT_NAMES, JOINT_PARENTS)
    M.add_component(body, "via.motion.Motion", { layers = motion_layers() })
    M.add_component(body, "via.motion.MotionFsm2")
    M.add_component(body, "via.physics.CharacterController", { ctx = ctx })
    -- Its colliders: one without damage data, the head, the chest.
    local function collider(ud) return new("via.physics.Collider", { user_data = ud }) end
    M.add_component(body, "chainsaw.HitController", { ctx = ctx, colliders = new("via.physics.Colliders", { list = {
        collider(new("chainsaw.collision.PressUserData")),
        collider(new("chainsaw.collision.EnemyDamageUserData", { __fields = { Parts = 0, PartsSide = 0 } })),
        collider(new("chainsaw.collision.EnemyDamageUserData", { __fields = { Parts = 1, PartsSide = 0 } })),
        collider(new("chainsaw.collision.EnemyDamageUserData", { __fields = { Parts = 7, PartsSide = 1 } })),
        collider(new("chainsaw.collision.EnemyDamageUserData", { __fields = { Parts = 7, PartsSide = 2 } })),
    } }) })
    ctx.body = body
    ctx.head = M.make_go(type_name:match("(Ch%w+)Context") and (type_name:match("(Ch%w+)Context") .. "_head") or "head")
    ctx.head_updater = M.add_component(ctx.head, "chainsaw.HeadUpdater", { context = ctx })
    -- Its HateController (EnemyHeadUpdater.<HateController>): whom it is after.
    ctx.hate = M.new("chainsaw.HateController", { owner = ctx.head })
    ctx.head_updater.__fields["<HateController>k__BackingField"] = ctx.hate
    return ctx
end

-- Ashley (ch2_a1z0, CharacterKindID 200030) at `pos`.
M.ASHLEY_KIND = 200030
function M.make_ashley(pos, hp)
    local ctx = M.make_character("chainsaw.PartnerBaseContext", pos, hp or 600)
    ctx.kind_id = M.ASHLEY_KIND
    ctx.body.name, ctx.head.name = "ch2a1z0_body", "ch2a1z0_head"
    ctx.think_enable, ctx.permit_kidnapped, ctx.permit_attacked = true, true, true
    return ctx
end

-- A scripted Ashley (a doll NPC of her kind) at `pos`; with `spawn_param`, the level spawn
-- param that made her (invalidateSpawn(true) despawns her).
function M.make_doll_ashley(pos, spawn_param)
    local ctx = M.make_character("chainsaw.DollNpcBaseContext", pos, 600)
    ctx.kind_id = M.ASHLEY_KIND
    ctx.body.name, ctx.head.name = "ch2a1z0_body", "ch2a1z0_head"
    if spawn_param then ctx.spawn_param = new("chainsaw.CharacterSpawnParam", { ctx = ctx, owner = M.make_go("spawner") }) end
    return ctx
end

-- Whether `motion` can play a motion of `bank` (only for a Motion with `banks` set: bank ->
-- the TargetBankType bits its variant needs, 0 = any): one of its own banks in the selected
-- variant, or a dynamic bank standing for it.
function M.motion_playable(motion, bank)
    if motion.banks == nil then return true end
    local need = motion.banks[bank]
    if need ~= nil and (need == 0 or ((motion.bank_type or 0) & need) ~= 0) then return true end
    for _, b in ipairs(motion.dynamic or {}) do
        if b.bank_id == bank then return true end
    end
    return false
end

-- A dynamic motion bank for `path` standing for bank `bank_id`.
function M.make_dynamic_bank(path, bank_id, opts)
    opts = opts or {}
    return new("via.motion.DynamicMotionBank", { motlist = new("via.motion.MotionListResourceHolder", { path = path }),
        bank_id = bank_id, bank_type = opts.bank_type or 0, mask_bit = opts.mask_bit or 0, order = opts.order or 0,
        ow_id = opts.ow_id or false, ow_type = false, ow_mask = false })
end

-- Every partner whose head runs: she follows the player (up to 0.3 m a frame, stopping 1.5 m
-- from them), and her action unit sets the grab and attack permissions again.
function M.update_partners()
    local w = M.world
    local player = w.player
    for _, ctx in ipairs(w.partners or { w.partner }) do
        if ctx ~= nil and ctx.head ~= nil and ctx.head.update_self ~= false and not ctx.despawned then
            ctx.ai_frames = (ctx.ai_frames or 0) + 1
            ctx.permit_kidnapped, ctx.permit_attacked = ctx.think_enable ~= false, true
            if player ~= nil and not ctx.kidnapped then
                local dx, dz = player.pos.x - ctx.pos.x, player.pos.z - ctx.pos.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d > 1.5 then
                    local step = math.min(0.3, d - 1.5)
                    ctx.pos.x, ctx.pos.z = ctx.pos.x + dx / d * step, ctx.pos.z + dz / d * step
                end
            end
        end
    end
end

-- An enemy of this game tries to carry her off (Ch1c0NPCTargetDriver_Ch2a1z0.startTarget:
-- only while IsPermitKidnapped).
function M.try_kidnap(ctx)
    if ctx.permit_kidnapped ~= true then return false end
    ctx.kidnapped = true
    return true
end

-- The game gives a pooled head to another character (or to `ctx`): its updater is linked again.
function M.relink_head(head_updater, ctx)
    head_updater.context = ctx
end

-- The game despawns a character: its context leaves the character lists and its body is
-- destroyed. Its head GameObject survives: the game pools heads and gives them to the next
-- characters.
function M.despawn(ctx)
    local w = M.world
    for _, list in ipairs({ w.enemies or {}, w.partners or {}, w.dolls or {} }) do
        for i = #list, 1, -1 do
            if list[i] == ctx then table.remove(list, i) end
        end
    end
    if w.partner == ctx then w.partner = nil end
    ctx.despawned = true
    if ctx.body ~= nil then M.destroy(ctx.body) end
    -- Its head goes back to the pool unlinked: HeadUpdater.Context is null there.
    if ctx.head_updater ~= nil then ctx.head_updater.context = nil end
end

-- A level enemy's spawn param, registered in CharacterManager.CharacterSpawnParamDB. Its enemy
-- spawns in M.update_spawns the way CharacterSpawnParam.isNextSpawn / updateSpawn decide:
-- permitted and not invalidated; a save backup that says it died invalidates the spawn param
-- for good. opts: { permitted (default true), type_name, hp }.
function M.make_spawn_param(spawner, pos, opts)
    opts = opts or {}
    local sp = new("chainsaw.CharacterSpawnParam", { id = context_id(spawner), spawner = spawner,
        pos = vec(pos.x, pos.y, pos.z), permitted = opts.permitted ~= false, type_name = opts.type_name or
        "chainsaw.Ch1c0z0Context", hp = opts.hp or 100, owner = M.make_go("spawner") })
    M.world.spawn_params[sp.id:call("get_Code")] = sp
    return sp
end

-- One update of every spawn param (CharacterSpawnParam.onUpdate).
function M.update_spawns()
    for code, sp in pairs(M.world.spawn_params) do
        if not sp.invalid and sp.permitted and (sp.ctx == nil or sp.ctx.despawned) then
            local b = M.backup_of(code)
            if b ~= nil and b.eliminated then
                sp.invalid = true -- isNextSpawn: dead in the save
            else
                local ctx = M.make_character(sp.type_name, sp.pos, sp.hp, sp.spawner)
                ctx.spawn_param = sp
                sp.ctx = ctx
                table.insert(M.world.enemies, ctx)
                sp.spawned = (sp.spawned or 0) + 1
            end
        end
    end
end

-- A character backup in CharacterManager.CharacterBackupDB (what the save remembers about a
-- character that is not loaded). eliminated: it died and must never spawn again.
function M.add_backup(ctx, eliminated)
    local b = new("chainsaw.CharacterBackup", { id = context_id(ctx), eliminated = eliminated })
    M.world.backups[#M.world.backups + 1] = b
    return b
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
    M.add_component(body, "chainsaw.PlayerEquipment", { __fields = {
        ["<InventoryController>k__BackingField"] = M.world.case_ctrl } })
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
    ctx.head_updater = M.add_component(head, "chainsaw.PlayerHeadUpdater")
    ctx.voice = M.add_component(head, "via.wwise.WwiseContainer")
    ctx.body, ctx.head = body, head
    -- What enemies see (a TargetMarker filed under the body's tag) and hit (its damage colliders).
    body.tag = "Player|Character"
    ctx.marker = M.add_component(body, "chainsaw.TargetMarker", { registrations = 1 })
    ctx.hit_controller = M.add_hit_controller(body, ctx, M.leon_colliders(body))
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
    M.add_component(body, "chainsaw.CharacterBodyLogic")
    M.add_component(body, "chainsaw.WwiseContainerApp")
    M.add_component(body, "via.motion.Chain")
    -- What makes it a character once the mod gives it a context (game_partner.lua): its body
    -- updater, its HitController (constructed: Delegates and DamageCalcInfo) and its colliders:
    -- the damage shapes in its RequestSetCollider, as Leon's (M.leon_colliders).
    M.add_component(body, "chainsaw.PlayerBodyUpdater")
    M.add_hit_controller(body, nil, M.leon_colliders(body))
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

-- A scoped rifle's prefab (wp4400 SR M1903): the gun, its scope (chainsaw.ScopeController, with a
-- render output) and, four levels down, the scope's camera with its render output and post
-- effects; plus a thermal camera outside the hierarchy that the scope only references
-- (_WeaknessCameraGameObject).
-- Any enabled camera renders its view onto the screen (world.rendering_cameras).
function M.build_scoped_weapon(name, pos)
    local go = M.build_weapon(name, pos)
    local scope_go = M.make_go("scope")
    M.set_parent(scope_go.transform, go.transform)
    local lens = M.make_go("lens")
    M.set_parent(lens.transform, scope_go.transform)
    M.add_component(lens, "via.render.Mesh")
    local holder = M.make_go("camera_holder")
    M.set_parent(holder.transform, lens.transform)
    local cam_go = M.make_go("ScopeCamera")
    M.set_parent(cam_go.transform, holder.transform)
    local cam = M.add_component(cam_go, "via.Camera")
    M.add_component(cam_go, "via.render.RenderOutput")
    M.add_component(cam_go, "via.render.ToneMapping")
    M.add_component(cam_go, "via.render.DepthOfField")
    local thermal = M.make_go("ThermalCamera", { wpos = vec(pos.x, pos.y, pos.z) })
    local tcam = M.add_component(thermal, "via.Camera")
    local ref = new("via.GameObjectRef", { target = thermal })
    -- (_CameraRef is only set once the scope runs: null in a fresh prefab)
    M.add_component(scope_go, "chainsaw.ScopeController", { __fields = { _WeaknessCameraGameObject = ref } })
    -- The scope's own picture, rendered for its lens.
    M.add_component(scope_go, "via.render.RenderOutput")
    M.world.cameras = M.world.cameras or {}
    table.insert(M.world.cameras, cam)
    table.insert(M.world.cameras, tcam)
    return go
end

-- The cameras that render a view right now (enabled, on an updating GameObject).
function M.rendering_cameras()
    local n = 0
    for _, cam in ipairs(M.world.cameras or {}) do
        if cam.enabled ~= false and cam.owner.update_self ~= false and not cam.owner.destroyed then n = n + 1 end
    end
    return n
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

-- The player starts a finisher (`request`: "requestFatal", "requestKnifeFatal" or
-- "requestStompFatal") on `enemy`: the game's PlayerHeadUpdater call, hooks around it.
function M.fatal(enemy, request, opts)
    request = request or "requestFatal"
    opts = opts or {}
    local head = new("chainsaw.PlayerHeadUpdater", { selector = new("chainsaw.PlayerTargetSelector", { target = enemy }),
        stealth = opts.stealth, ftype = opts.ftype })
    M.fire_hooks(request, head)
    return head:call(request)
end

-- `attacker` (default: the player's body) hits `enemy`: the game builds a DamageInfo - marked
-- IsKill when it kills (HitController.checkKill) - and calls the victim's
-- HitController.callbackDamageHit (hooks run around it). opts: { weapon, attack_type (the
-- AttackData's _AttackType, default Shot), power (_AttackPower, default Light), part, side }.
function M.hit(enemy, damage, wince, attacker, opts)
    opts = opts or {}
    local owner = attacker or (M.world.player and M.world.player.body)
    local weapon = opts.weapon or 4000
    local hc = M.component(enemy.body, "chainsaw.HitController")
    local info = new("chainsaw.HitController.DamageInfo", { data = {
        Damage = damage, Wince = wince or 10, Break = 0, Stopping = 0, DamageDir = vec(0, 0, -1),
        AttackOwnerObject = owner, AttackGameObject = owner or M.make_go("shot"), WeaponID = weapon, IsCritical = false,
        IsKill = hc:call("checkKill", damage), AttackType = 0, HitPos = vec(0, 1.6, 0), SerialNo = 777,
        AttackUserData = new("chainsaw.collision.AttackUserData", { weapon = weapon,
            __fields = { _AttackHitDataID = 2000 + weapon % 1000, _KeyNameHash = 0x5EED } }),
        AttackData = new("chainsaw.collision.AttackHitUserData.AttackData", { weapon = weapon, __fields = {
            _AttackType = opts.attack_type or 1, _AttackPower = opts.power or 2, _Option = 0, _Damage = damage,
            _Wince = wince or 10 } }),
        DamageUserData = new("chainsaw.collision.DamageUserData", { __fields = { Parts = opts.part or 1,
            PartsSide = opts.side or 0 } }) } })
    info.engine_owned = true -- the game's own hit holds its DamageInfo
    hc:call("callbackDamageHit", info)
    return info
end

-- The game rolls a random drop for `enemy` (or a wooden box when enemy is nil) the way RE4
-- does: requestGenerateRandomDrop(option, player, pos, stage, dropper, option), processed by
-- the next updateRandomDropStack. Returns the dropped item.
function M.enemy_drop(enemy, item_id, droptype)
    local mgr = M.world.singletons["chainsaw.DropItemManager"]
    mgr.next_item, mgr.last_drop = item_id, nil
    local order = enemy or new("chainsaw.GmContextBox")
    local pos = enemy and enemy.pos or vec(0, 0, 0)
    mgr:call("requestGenerateRandomDrop(chainsaw.RandomDrop.Option, chainsaw.CharacterContext, via.vec3, chainsaw.StageID, chainsaw.Context, chainsaw.DropItemManager.GenerateItemOption)",
        new("chainsaw.RandomDrop.Option", { droptype = droptype or (enemy and 65536 or 1) }), M.world.player,
        vec(pos.x, pos.y, pos.z), 40100, order, new("chainsaw.DropItemManager.GenerateItemOption"))
    mgr:call("updateRandomDropStack")
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
    class("chainsaw.ContextID", "System.Object", M.context_id_methods, { _Category = "chainsaw.ContextID.EntityCategory",
        _Kind = "System.Byte", _Group = "System.Int32", _Index = "System.Int32" })
    class("via.vec3", "System.Object", {})
    class("via.Quaternion", "System.Object", {})
    -- System.Nullable`1<T>: a struct { _HasValue, _Value } built with REFramework's ValueType.new.
    for _, inner in ipairs({ "via.vec3", "via.Quaternion", "chainsaw.EnvSceneStatus" }) do
        local name = "System.Nullable`1<" .. inner .. ">"
        class(name, "System.Object", {}, { _HasValue = "System.Boolean", _Value = inner })
        M.value_types[name] = true
    end

    -- Scenario flags, as re4.exe has them (docs/RESEARCH.md 3.11): every flag is a
    -- via.userdata.Variable (GUID + value) of a ScenarioFlagManager.Group, whose words hold bit i
    -- for variable i. Game code sets variables from anywhere (Variable.set_Bool); every change
    -- runs ScenarioFlagManagerBehavior's change handlers (where the mod's hooks sit).
    world.flag_vars, world.flag_events, world.pulses = {}, 0, {}
    local function var_bit(var)
        local g = world.flag_groups[var.group]
        return (g.words[var.bit // 32 + 1] & (1 << (var.bit % 32))) ~= 0
    end
    local function flag_changed(var)
        world.flag_events = world.flag_events + 1
        world.flag_log[#world.flag_log + 1] = { guid = var.guid, value = var.kind == 16 or var_bit(var) }
        world.flag_behavior:call(var.common and "onSetCommonFlagEvent" or "onSetScenarioFlagEvent", var)
    end
    -- What the native Variable.set_Bool does: write, and announce a change.
    local function set_var(var, value)
        if var.write_protect then return end
        local g = world.flag_groups[var.group]
        local w = var.bit // 32 + 1
        local before = var_bit(var)
        if value then g.words[w] = g.words[w] | (1 << (var.bit % 32))
        else g.words[w] = g.words[w] & ~(1 << (var.bit % 32)) end
        if before ~= (value and true or false) then flag_changed(var) end
    end
    M.set_var = set_var
    enum("via.userdata.TypeKind", { Boolean = 2, Trigger = 16 })
    class("via.userdata.Variable", "System.Object", {
        get_Guid = { 0, function(self) return guid_value(self.guid) end, {}, { ret = "System.Guid" } },
        get_TypeKind = { 0, function(self) return self.kind end, {}, { ret = "via.userdata.TypeKind" } },
        get_Bool = { 0, function(self)
            if self.kind == 16 then return self.fired == true end
            return var_bit(self)
        end, {}, { ret = "System.Boolean" } },
        set_Bool = { 1, function(self, v) set_var(self, v) end, { "System.Boolean" } },
        setTrigger = { 0, function(self)
            world.pulses[#world.pulses + 1] = self.guid
            self.fired = true
            flag_changed(self)
            self.fired = false
        end },
    })
    class("via.userdata.UserVariables", "System.Object", {
        getVariable = { 1, function(self, i) return self.vars[i] end, { "System.UInt32" } },
    })
    class("chainsaw.ScenarioFlagManager.Group", "System.Object", {}, { ["<Name>k__BackingField"] = "System.String",
        ["<Variables>k__BackingField"] = "via.userdata.UserVariables" })
    class("chainsaw.ScenarioFlagManagerBehavior", "via.Component", {
        onSetScenarioFlagEvent = { 1, function(self) self.scenario = (self.scenario or 0) + 1 end, { "via.userdata.Variable" } },
        onSetCommonFlagEvent = { 1, function(self) self.common = (self.common or 0) + 1 end, { "via.userdata.Variable" } },
    })
    world.flag_behavior = new("chainsaw.ScenarioFlagManagerBehavior")
    class("chainsaw.GlobalUserDataManager", "System.Object", {
        findVariable = { 1, function(_, g) return world.flag_vars[g.text] end, { "System.Guid" },
            { static = true, ret = "via.userdata.Variable" } },
        trySetBool = { 2, function(_, g, v)
            local var = world.flag_vars[g.text]
            if var == nil or var.kind ~= 2 then return false end
            set_var(var, v)
            return true
        end, { "System.Guid", "System.Boolean" }, { static = true, ret = "System.Boolean" } },
    })
    class("share.SaveDataBase", "System.Object", {})
    class("chainsaw.ScenarioFlagManager.SaveGroup", "System.Object", {}, { GroupName = "System.String",
        Flags = "System.UInt32[]" })
    class("chainsaw.ScenarioFlagManager.SaveData", "share.SaveDataBase", {}, { VersionValue = "System.UInt32",
        Datas = "chainsaw.ScenarioFlagManager.SaveGroup[]" })
    class("chainsaw.ScenarioFlagManager", "System.Object", {
        -- requestSetFlag(flag, ck_readonly) turns a flag on; the Boolean is a read-only check.
        requestSetFlag = { 2, function(_, g, ck_readonly)
            local var = world.flag_vars[g.text]
            if var == nil or (ck_readonly and var.read_only) then return end
            set_var(var, true)
        end, { "System.Guid", "System.Boolean" } },
        checkFlag = { 1, function(_, g)
            local var = world.flag_vars[g.text]
            return var ~= nil and var_bit(var)
        end, { "System.Guid" }, { ret = "System.Boolean" } },
        -- Decoys a careless probe could pick: a counter and a flag *watcher*.
        getFlagCount = { 0, function() return 0 end, {}, { ret = "System.Int32" } },
        setFlagWatch = { 2, function() world.watch_calls = (world.watch_calls or 0) + 1 end,
            { "System.Guid", "System.Boolean" } },
        -- Declared with share.SaveDataBase, like the game's.
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
        end, {}, { ret = "share.SaveDataBase" } },
        loadGameSaveData = { 1, function(_, sd)
            local before = {}
            for guid, var in pairs(world.flag_vars) do before[guid] = var_bit(var) end
            for _, sg in ipairs(rawget(sd.__fields.Datas, "__items")) do
                for _, g in ipairs(world.flag_groups) do
                    if g.name == sg.__fields.GroupName then
                        for k, w in ipairs(rawget(sg.__fields.Flags, "__items")) do g.words[k] = w end
                    end
                end
            end
            -- applyBit2Variable: every variable takes its bit (changes are announced).
            for guid, var in pairs(world.flag_vars) do
                if var_bit(var) ~= before[guid] then flag_changed(var) end
            end
            world.flag_loads = (world.flag_loads or 0) + 1
        end, { "share.SaveDataBase" } },
    }, { _Group = "chainsaw.ScenarioFlagManager.Group[]" })

    local groups = {}
    for i, g in ipairs(world.flag_groups) do
        g.vars = {}
        groups[i] = new("chainsaw.ScenarioFlagManager.Group", { __fields = { ["<Name>k__BackingField"] = g.name,
            ["<Variables>k__BackingField"] = new("via.userdata.UserVariables", { vars = g.vars }) } })
    end
    world.singletons["chainsaw.ScenarioFlagManager"] = new("chainsaw.ScenarioFlagManager", { __fields = {
        _Group = typed_array("chainsaw.ScenarioFlagManager.Group", groups) } })

    -- Gimmick save table, keyed by ContextID; pushDirtyList announces a state change.
    class("chainsaw.GimmickContext.TriggerDone", "System.Object", {}, { SaveID = "System.UInt32", Done = "System.UInt32" })
    class("chainsaw.GimmickContext.AccessoryData", "System.Object", {})
    class("chainsaw.GimmickContext.AccessoryDataFloat", "chainsaw.GimmickContext.AccessoryData", {}, { Value = "System.Single" })
    class("chainsaw.GimmickContext.AccessoryDataUint", "chainsaw.GimmickContext.AccessoryData", {}, { Value = "System.UInt32" })
    local save_data_of, record_of
    -- SaveData.clone shares nothing with the original.
    class("chainsaw.GimmickContext.SaveData", "System.Object", {
        clone = { 0, function(self) return save_data_of(record_of({}, self)) end, {},
            { ret = "chainsaw.GimmickContext.SaveData" } },
    }, { Attr = "System.Byte[]",
        TriggerSave = "chainsaw.GimmickContext.TriggerDone[]", IsDetected = "System.Boolean",
        AccDatas = "chainsaw.GimmickContext.AccessoryData[]" })
    class("chainsaw.GimmickManager.SaveItem", "System.Object", {}, { ID = "chainsaw.ContextID",
        SaveData = "chainsaw.GimmickContext.SaveData" })
    class("System.Collections.Generic.List`1<chainsaw.GimmickManager.SaveItem>", "System.Object", {
        get_Count = { 0, function(self) return #self.items end, {}, { ret = "System.Int32" } },
        get_Item = { 1, function(self, i) return self.items[i + 1] end, { "System.Int32" } },
        Add = { 1, function(self, x) self.items[#self.items + 1] = x end, { "chainsaw.GimmickManager.SaveItem" } },
    })
    class("chainsaw.GimmickManager.SaveData", "share.SaveDataBase", {}, { VersionValue = "System.UInt32",
        Datas = "System.Collections.Generic.List`1<chainsaw.GimmickManager.SaveItem>" })
    -- A record's SaveData (the game builds a fresh one for every save).
    function save_data_of(g)
        local trig, acc = {}, {}
        for i, t in ipairs(g.triggers) do
            trig[i] = new("chainsaw.GimmickContext.TriggerDone", { __fields = { SaveID = t.id, Done = t.done } })
        end
        for i, a in ipairs(g.acc) do
            acc[i] = new(a.type or (a.kind == 1 and "chainsaw.GimmickContext.AccessoryDataFloat"
                or "chainsaw.GimmickContext.AccessoryDataUint"), { __fields = { Value = a.value } })
        end
        return new("chainsaw.GimmickContext.SaveData", { __fields = {
            Attr = typed_array("System.Byte", { table.unpack(g.attr) }),
            TriggerSave = typed_array("chainsaw.GimmickContext.TriggerDone", trig),
            IsDetected = g.detected, AccDatas = typed_array("chainsaw.GimmickContext.AccessoryData", acc) } })
    end
    -- ...and the record a SaveData describes.
    function record_of(ctx, data)
        data = data.__fields
        local g = { ctx = ctx, attr = {}, triggers = {}, acc = {}, detected = data.IsDetected == true }
        for i = 1, data.Attr:get_size() do g.attr[i] = rawget(data.Attr, "__items")[i] end
        for i = 1, data.TriggerSave:get_size() do
            local t = rawget(data.TriggerSave, "__items")[i]
            if t ~= nil then g.triggers[#g.triggers + 1] = { id = t.__fields.SaveID, done = t.__fields.Done } end
        end
        for i = 1, data.AccDatas:get_size() do
            local a = rawget(data.AccDatas, "__items")[i]
            if a ~= nil then
                g.acc[#g.acc + 1] = { kind = a.__type:find("Float") and 1 or 2, value = a.__fields.Value,
                    type = a.__type }
            end
        end
        return g
    end
    world.gimmick_record_of = record_of
    -- A gimmick's context (GimmickManager._Context): its current save state, which
    -- loadSaveDataFromManager replaces (with a clone) as the game's load does.
    class("chainsaw.GimmickContext", "System.Object", {
        getGmFlag = { 0, function(self)
            local g = world.gimmick_table[self.key]
            return g ~= nil and (g.attr[1] or 0) ~= 0
        end, {}, { ret = "System.Boolean" } },
        loadSaveDataFromManager = { 1, function(self, src)
            local g = record_of(self.ctx, src)
            world.gimmick_table[self.key] = g
            world.gimmick_context_loads = (world.gimmick_context_loads or 0) + 1
        end, { "chainsaw.GimmickContext.SaveData" } },
    }, { _SaveCur = "chainsaw.GimmickContext.SaveData" })
    world.gimmick_contexts = {} -- ctx key -> true: gimmicks set up in this game (default: every record)
    class("chainsaw.GimmickManager", "System.Object", {
        pushDirtyList = { 1, function() end },
        registerMove = { 1, function(_, core) world.moving[core] = true end, { "chainsaw.GimmickCore" } },
        unregisterMove = { 1, function(_, core) world.moving[core] = nil end, { "chainsaw.GimmickCore" } },
        findContext = { 1, function(_, id)
            local key = key_of_ctx_object(id)
            local g = world.gimmick_table[key]
            if g == nil and not world.gimmick_contexts[key] then return nil end
            if world.gimmick_unset and world.gimmick_unset[key] then return nil end
            local cur = g and save_data_of(g) or new("chainsaw.GimmickContext.SaveData", { __fields = {
                Attr = typed_array("System.Byte", { 0, 0 }), TriggerSave = typed_array("chainsaw.GimmickContext.TriggerDone", {}),
                IsDetected = false, AccDatas = typed_array("chainsaw.GimmickContext.AccessoryData", {}) } })
            cur.__ctx_key = key
            local live = world.live_gimmicks and world.live_gimmicks[key]
            if live ~= nil then
                live.context.__fields._SaveCur = cur
                return live.context
            end
            local ctx = { category = id.__fields._Category, kind = id.__fields._Kind, group = id.__fields._Group,
                index = id.__fields._Index }
            return new("chainsaw.GimmickContext", { key = key, ctx = ctx, __fields = { _SaveCur = cur } })
        end, { "chainsaw.ContextID" }, { ret = "chainsaw.GimmickContext" } },
        -- The GimmickCore registered for that ID (a gimmick loaded and set up here).
        findGimmick = { 1, function(_, id)
            local live = world.live_gimmicks and world.live_gimmicks[key_of_ctx_object(id)]
            return live and live.core or nil
        end, { "chainsaw.ContextID" }, { ret = "chainsaw.GimmickCore" } },
        -- Declared with share.SaveDataBase, like the game's.
        saveGameSaveData = { 0, function()
            local keys = {}
            for k in pairs(world.gimmick_table) do keys[#keys + 1] = k end
            table.sort(keys)
            local items = {}
            for _, k in ipairs(keys) do
                local g = world.gimmick_table[k]
                items[#items + 1] = new("chainsaw.GimmickManager.SaveItem", { __fields = { ID = ctx_object(g.ctx),
                    SaveData = save_data_of(g) } })
            end
            local list = new("System.Collections.Generic.List`1<chainsaw.GimmickManager.SaveItem>", { items = items })
            return new("chainsaw.GimmickManager.SaveData", { __fields = { Datas = list } })
        end, {}, { ret = "share.SaveDataBase" } },
        -- The game's load clears the whole manager first: never to be used while playing.
        loadGameSaveData = { 1, function(_, sd)
            world.gimmick_table = {}
            for _, item in ipairs(sd.__fields.Datas.items) do
                local id = item.__fields.ID
                local ctx = { category = id.__fields._Category, kind = id.__fields._Kind, group = id.__fields._Group,
                    index = id.__fields._Index }
                world.gimmick_table[key_of_ctx_object(id)] = record_of(ctx, item.__fields.SaveData)
            end
            world.gimmick_loads = (world.gimmick_loads or 0) + 1
        end, { "share.SaveDataBase" } },
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

    -- Cutscenes, as re4.exe plays them (docs/RESEARCH.md 3.11): a "play once" camera request
    -- becomes a ClapperboardMediator.PayloadPlay that procPayloadPlay plays (setting the start
    -- flags, recording the camera as seen); at the end the end flags are set and the data
    -- owner's scripted sequence continues (EndPortrayal).
    local PAYLOAD = "chainsaw.ClapperboardMediator.PayloadPlay"
    class("chainsaw.ScenarioFlagManager.FlagInfo", "System.Object", {}, { GroupIndex = "System.Int32", Index = "System.Int32" })
    class("chainsaw.PlayerCoordSetting.Pack", "System.Object", {})
    class(PAYLOAD, "System.Object", {}, { CameraType = "System.Int32", ID = "System.Int32", Screen = "System.Int32",
        StartFlag = "chainsaw.ScenarioFlagManager.FlagInfo[]", EndFlag = "chainsaw.ScenarioFlagManager.FlagInfo[]",
        CoorsSettings = "chainsaw.PlayerCoordSetting.Pack[]", DataOwnerCode = "System.UInt32", EndPortrayal = "System.UInt32" })
    world.played, world.has_done, world.play_id, world.continued = {}, {}, 0, {}
    -- The camera playing on a screen: the skip button sets InputSkip; procSkip (each frame)
    -- skips it when it can be skipped (DoneSkip), and it ends after the skip fade.
    -- canSkip: the event is playing (past world.cutscene_load_frames); DispUI: the skip prompt is up.
    class("chainsaw.ClapperboardMediator.PlayWork", "System.Object", {
        get_CameraID = { 0, function(self) return self.cam_id end, {}, { ret = "System.Int32" } },
        get_PlayID = { 0, function(self) return self.play_id end, {}, { ret = "System.UInt32" } },
        canSkip = { 0, function(self)
            local rec = self.rec
            return rec ~= nil and rec.can_skip and not rec.stuck_start and (rec.age or 0) >= (rec.load_frames or 0)
        end, {}, { ret = "System.Boolean" } },
    }, { CamType = "System.Int32", DoneSkip = "System.Boolean", InputSkip = "System.Boolean", DispUI = "System.Boolean" })
    class("chainsaw.ClapperboardMediator.PlayWorkTimeline", "chainsaw.ClapperboardMediator.PlayWork", {})
    -- The requests' cameras: a timeline (type 1) or a movie (type 2) by its number.
    class("chainsaw.ClapperboardMediator.CameraBase", "System.Object", {}, { RejectTimeline = "System.Boolean" })
    class("chainsaw.ClapperboardMediator.CameraTimeline", "chainsaw.ClapperboardMediator.CameraBase", {
        get_CameraType = { 0, function() return 1 end, {}, { ret = "chainsaw.ClapperboardMediator.CameraType" } },
        get_CameraID = { 0, function(self) return self.__fields.ID end, {}, { ret = "System.Int32" } },
    }, { ID = "chainsaw.TimelineEventDefine.ID" })
    class("chainsaw.ClapperboardMediator.CameraMovie", "chainsaw.ClapperboardMediator.CameraBase", {
        get_CameraType = { 0, function() return 2 end, {}, { ret = "chainsaw.ClapperboardMediator.CameraType" } },
        get_CameraID = { 0, function(self) return self.__fields.MovieID end, {}, { ret = "System.Int32" } },
    }, { MovieID = "chainsaw.MovieDefine.ID" })
    local function flag_infos(arr)
        local out = {}
        if arr == nil then return out end
        for i = 0, arr:get_size() - 1 do
            out[#out + 1] = { group = arr:read_dword(0x20 + i * 8), index = arr:read_dword(0x24 + i * 8) }
        end
        return out
    end
    local function set_flag_info(f)
        local g = world.flag_groups[f.group + 1]
        local var = g and g.vars[f.index]
        if var ~= nil then set_var(var, true) end
    end
    -- A camera starts on the screen (procRequest installing its PlayWork in _Plays).
    local function start_camera(rec)
        world.played[#world.played + 1] = rec
        world.current_cutscene = rec
        rec.work = new("chainsaw.ClapperboardMediator.PlayWorkTimeline", { cam_id = rec.id, play_id = rec.play_id,
            rec = rec, __fields = { CamType = rec.built, DoneSkip = false, InputSkip = false, DispUI = false } })
        rec.can_skip = not world.unskippable
        -- It loads for a few frames, then plays; its start fade holds the EVENT layer dark for
        -- a few more (world.cutscene_load_frames / cutscene_start_fade_frames, 0 by default).
        rec.age, rec.load_frames, rec.fade_frames = 0, world.cutscene_load_frames or 0, world.cutscene_start_fade_frames or 0
        if rec.load_frames + rec.fade_frames > 0 then
            world.fades[4] = true
            rec.holds_event_fade = true
        end
        world.singletons["chainsaw.ClapperboardMediator"].__fields._Plays =
            typed_array("chainsaw.ClapperboardMediator.PlayWork", { rec.work })
        world.gui_event = true
        for _, fi in ipairs(rec.start_flags) do set_flag_info(fi) end
    end
    M.start_camera = start_camera
    world.queued = {} -- requests procRequest queued behind the camera playing (ReserveWork)
    class("chainsaw.ClapperboardMediator", "System.Object", {
        procPayloadPlay = { 2, function(_, id, p)
            local f = p.__fields
            local rec = { play_id = id, camera = f.CameraType, id = f.ID, screen = f.Screen, owner = f.DataOwnerCode,
                end_portrayal = f.EndPortrayal, start_flags = flag_infos(f.StartFlag), end_flags = flag_infos(f.EndFlag) }
            if f.CoorsSettings ~= nil then
                local c = f.CoorsSettings
                rec.coords = { { kind = c:read_dword(0x20), x = c:read_float(0x30), rot_y = c:read_float(0x40),
                    reset = c:read_byte(0x44) } }
            end
            -- On PC a movie request plays the timeline of the same number (world.movie_timelines).
            rec.built = (world.movie_timelines and f.CameraType == 2) and 1 or f.CameraType
            -- procRequest: a timeline requested while a camera plays waits behind it.
            if world.current_cutscene ~= nil and rec.built == 1 then
                world.queued[#world.queued + 1] = rec
            else
                start_camera(rec)
            end
            world.has_done[("%d:%d"):format(rec.built, f.ID)] = true
        end, { "System.UInt32", PAYLOAD } },
        -- setHasDone(CameraBase): that camera is recorded as seen.
        setHasDone = { 1, function(_, cam)
            world.has_done[("%d:%d"):format(cam:call("get_CameraType"), cam:call("get_CameraID"))] = true
        end, { "chainsaw.ClapperboardMediator.CameraBase" } },
        -- ClapperboardMediator.requestEnd(UInt32 playid): that camera ends (a skip stuck on its
        -- fade-out included); its fades stay as they are.
        ["requestEnd(System.UInt32)"] = { 1, function(_, play_id)
            local rec = world.current_cutscene
            world.camera_ends = (world.camera_ends or 0) + 1
            if rec ~= nil and rec.play_id == play_id then
                rec.ended_by_request = true
                M.end_cutscene()
            end
        end, { "System.UInt32" } },
        emitPlayID = { 0, function()
            world.play_id = world.play_id + 1
            return world.play_id
        end, {}, { ret = "System.UInt32" } },
        checkHasDone = { 2, function(_, t, i) return world.has_done[("%d:%d"):format(t, i)] == true end,
            { "System.Int32", "System.Int32" }, { ret = "System.Boolean" } },
    }, { _Plays = "chainsaw.ClapperboardMediator.PlayWork[]" })
    world.singletons["chainsaw.ClapperboardMediator"] = new("chainsaw.ClapperboardMediator", { __fields = {
        _Plays = typed_array("chainsaw.ClapperboardMediator.PlayWork", {}) } })

    -- Level triggers: an InteractHolder on a level GameObject holds InteractTriggers; the
    -- interaction update runs one through InteractTrigger.Work.executeTrigger.
    enum("chainsaw.InteractTrigger.TriggerType", { None = 0, AreaHit = 1, Key = 2, Flag = 3, UseItem = 4 })
    class("chainsaw.collision.GimmickSensorUserData", "System.Object", {})
    class("chainsaw.InteractTrigger", "System.Object", {
        get_Type = { 0, function(self) return self.ttype end },
        get_Owner = { 0, function(self) return self.owner_go end },
        get_Hash = { 0, function(self) return self.hash end, {}, { ret = "System.UInt32" } },
        get_Done = { 0, function(self) return self.__fields["<Done>k__BackingField"] end, {}, { ret = "System.UInt32" } },
        recvDone = { 1, function(self, d)
            local f = self.__fields
            f["<Done>k__BackingField"] = f["<Done>k__BackingField"] | d
        end, { "System.UInt32" } },
        ["execute(via.GameObject, chainsaw.collision.GimmickSensorUserData)"] = { 2, function(self, target)
            M.run_trigger(self, target)
        end, { "via.GameObject", "chainsaw.collision.GimmickSensorUserData" } },
    }, { Succeed = "chainsaw.InteractTrigger.SucceedType", UniqueName = "System.String",
        ["<Done>k__BackingField"] = "System.UInt32" })
    class("chainsaw.InteractTriggerAreaHit", "chainsaw.InteractTrigger", {})
    class("chainsaw.InteractTriggerKey", "chainsaw.InteractTrigger", {})
    class("chainsaw.InteractTrigger.Work", "System.Object", {
        get_Trigger = { 0, function(self) return self.trig end },
        executeTrigger = { 2, function(self, target) M.run_trigger(self.trig, target) end,
            { "via.GameObject", "chainsaw.collision.GimmickSensorUserData" } },
    })
    class("chainsaw.InteractHolder", "via.Component", {
        ["findTrigger(System.UInt32)"] = { 1, function(self, h)
            for _, t in ipairs(self.triggers or {}) do
                if t.hash == h then return t end
            end
            return nil
        end, { "System.UInt32" } },
    })
    -- A sequence's parameter set: its effects (callees) run when it plays (triggerProcess), its end
    -- effects when it finishes (onFinish, from PortrayalSettings.update: M.finish_portrayals).
    local function items_of(arr)
        if arr == nil then return {} end
        return rawget(arr, "__items") or {}
    end
    class("chainsaw.PortrayalSettings.Param", "System.Object", {
        onFinish = { 0, function(self)
            for _, c in ipairs(items_of(self.__fields._CalleeEnd)) do
                if classes[c.__type] and classes[c.__type]:get_method("triggerProcess") then c:call("triggerProcess", nil, nil) end
            end
        end },
    }, { _CalleePlay = "System.Object", _CalleeEnd = "System.Object", _Settings = "chainsaw.PortrayalSettings" })
    -- Effects a sequence can run (docs/RESEARCH.md 3.24): the game's shared empty method is
    -- PortrayalParam.makeFinish; ReduceInventoryItemSettings' triggerProcess and makeFinish are one
    -- function (apply).
    class("chainsaw.PortrayalParam", "System.Object", {
        makeFinish = { 0, function() end, {}, { code = "stub" } },
    })
    local TP = { "chainsaw.InteractTrigger", "chainsaw.InteractActionArgs" }
    class("chainsaw.InventorySettings.Param", "chainsaw.PortrayalParam", {
        triggerProcess = { 2, function() world.items_given = (world.items_given or 0) + 1 end, TP },
    })
    class("chainsaw.PlDieSettings.Param", "chainsaw.PortrayalParam", {
        triggerProcess = { 2, function() world.player_killed = (world.player_killed or 0) + 1 end, TP },
    })
    class("chainsaw.ReduceInventoryItemSettings.Param", "chainsaw.PortrayalParam", {
        triggerProcess = { 2, function() world.items_taken = (world.items_taken or 0) + 1 end, TP, { code = "reduce" } },
        makeFinish = { 0, function() world.items_taken = (world.items_taken or 0) + 1 end, {}, { code = "reduce" } },
    })
    class("chainsaw.DevelopProcessSettings.Param", "chainsaw.PortrayalParam", {
        triggerProcess = { 2, function() end, TP, { code = "stub" } },
    })
    -- An effect the mod cannot mute (no triggerProcess of its own here): never shared.
    class("chainsaw.TestMovieSettings.Param", "chainsaw.PortrayalParam", {})
    class("chainsaw.SetFlagSettings.Param", "chainsaw.PortrayalParam", {
        triggerProcess = { 2, function() world.portrayal_flags = (world.portrayal_flags or 0) + 1 end, TP },
    })
    world.playing_params = {}
    class("chainsaw.OptionSettings`1<chainsaw.PortrayalSettings.Param>", "System.Object", {},
        { _Params = "chainsaw.PortrayalSettings.Param[]" })
    -- A gimmick's scripted sequence (docs/RESEARCH.md 3.19): call(key, trigger, args) plays it.
    world.portrayals = {}
    class("chainsaw.PortrayalSettings", "via.Component", {
        ["call(System.UInt32, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)"] = { 3, function(self, key, trig, args)
            world.portrayals[#world.portrayals + 1] = { guid = self.owner and self.owner.guid, key = key }
            if self.on_call then self.on_call(key) end
            local params = self.__fields._Params and self.__fields._Params.__fields._Params
            for _, param in ipairs(items_of(params)) do
                if param.key == nil or param.key == key then
                    param.__fields._Settings = self
                    for _, c in ipairs(items_of(param.__fields._CalleePlay)) do
                        if classes[c.__type] and classes[c.__type]:get_method("triggerProcess") then
                            c:call("triggerProcess", trig, args)
                        end
                    end
                    world.playing_params[#world.playing_params + 1] = param
                end
            end
        end, { "System.UInt32", "chainsaw.InteractTrigger", "chainsaw.InteractActionArgs" } },
    }, { _Params = "chainsaw.OptionSettings`1<chainsaw.PortrayalSettings.Param>" })
    for _, n in ipairs({ "GmPortrayalAreaHit", "SetFlagSettings", "ClapperboardSettings", "SoundCallSettings",
        "GmDoorBase", "GmPitfall", "PlDieSettings", "InventorySettings", "CustomLevel_DropAshleyItem" }) do
        class("chainsaw." .. n, "via.Component", {})
    end
    class("chainsaw.SoundCallSettings.Param", "chainsaw.PortrayalParam", {})
    world.trigger_runs = {}

    -- Objectives (docs/RESEARCH.md 3.24): PurposeManager keeps the current PurposeGuiItem and
    -- only takes one of higher priority (updateMainPurpose 0x1428e96f0: a copy, then the banner).
    local PURPOSE_CTOR = ".ctor(chainsaw.gui.PurposeID, System.Guid, System.Int32, System.Single, System.Boolean, System.Single)"
    class("chainsaw.gui.PurposeGuiItem", "System.Object", {
        [PURPOSE_CTOR] = { 6, function(self, id, msg, prio, disp, mediate, delay)
            self.id, self.msg, self.prio, self.disp, self.mediate, self.delay = id, msg, prio, disp, mediate, delay
        end, { "chainsaw.gui.PurposeID", "System.Guid", "System.Int32", "System.Single", "System.Boolean", "System.Single" } },
        get_MainPurposeID = { 0, function(self) return self.id end, {}, { ret = "chainsaw.gui.PurposeID" } },
        get_Priority = { 0, function(self) return self.prio end, {}, { ret = "System.Int32" } },
        get_Message = { 0, function(self) return self.msg end, {}, { ret = "System.Guid" } },
        get_DisplayTime = { 0, function(self) return self.disp end, {}, { ret = "System.Single" } },
        get_IsRequestMediate = { 0, function(self) return self.mediate end, {}, { ret = "System.Boolean" } },
        get_DelayTime = { 0, function(self) return self.delay end, {}, { ret = "System.Single" } },
        isValid = { 0, function(self) return self.id ~= nil and self.id > 0 end, {}, { ret = "System.Boolean" } },
    })
    class("chainsaw.PurposeManager", "System.Object", {
        get_CurrPurposeItem = { 0, function(self) return self.cur end, {}, { ret = "chainsaw.gui.PurposeGuiItem" } },
        ["updateMainPurpose(chainsaw.gui.PurposeGuiItem)"] = { 1, function(self, item)
            if item == nil or item.id == nil then return end
            if self.cur ~= nil and item.prio <= self.cur.prio then return end
            self.cur = new("chainsaw.gui.PurposeGuiItem", { id = item.id, msg = item.msg, prio = item.prio,
                disp = item.disp, mediate = item.mediate, delay = item.delay })
            world.purpose_banners = (world.purpose_banners or 0) + 1
        end, { "chainsaw.gui.PurposeGuiItem" } },
    })
    world.singletons["chainsaw.PurposeManager"] = new("chainsaw.PurposeManager")
    -- Our game's own objective changes (its conditions now hold another purpose).
    function M.set_purpose(id, prio, msg)
        local pm = world.singletons["chainsaw.PurposeManager"]
        pm.cur = new("chainsaw.gui.PurposeGuiItem", { id = id, prio = prio, msg = guid_value(msg or
            ("%08x-0000-0000-0000-000000000000"):format(id)), disp = 3.0, mediate = false, delay = 0.0 })
    end

    -- Chapter loads go through CampaignManager.loadGameSaveData(GameData); the in-game setup then
    -- builds its campaign jump with createCampaignJumperOrderFromInitialSettings (M.ingame_setup):
    -- each character appears at its locator, and the map loads around the base character's
    -- (docs/RESEARCH.md 3.34).
    class("chainsaw.GameLocator", "System.Object", {
        ["set_Position(via.vec3)"] = { 1, function(self, v) self.__fields._Position = vec(v.x, v.y, v.z) end,
            { "via.vec3" } },
        ["set_Rotation(via.Quaternion)"] = { 1, function(self, q) self.__fields._Rotation = quat(q.x, q.y, q.z, q.w) end,
            { "via.Quaternion" } },
    }, { _Stage = "chainsaw.StageID", _Position = "via.vec3", _Rotation = "via.Quaternion" })
    class("chainsaw.CampaignInitialSetting.CharacterProperty", "System.Object", {},
        { _Character = "chainsaw.CharacterKindID", _DefaultRole = "chainsaw.CampaignInitialSetting.CharacterProperty.Role",
            _Locator = "chainsaw.GameLocator" })
    class("chainsaw.CampaignInitialSetting", "System.Object", {}, { _Chapter = "chainsaw.ChapterID",
        _SpecialJumpSequence = "chainsaw.CampaignJumper.Order.SpecialOrderType",
        _CharacterList = "chainsaw.CampaignInitialSetting.CharacterProperty[]" })
    class("chainsaw.CampaignJumper.Order.CharacterEntry", "System.Object", {},
        { Property = "chainsaw.CampaignCharacterProperty", Locator = "chainsaw.GameLocator" })
    class("chainsaw.CampaignJumper.Order", "System.Object", {}, { Chapter = "chainsaw.ChapterID",
        CharacterEntryList = "chainsaw.CampaignJumper.Order.CharacterEntry[]", LoadBaseCharacter = "System.Int32",
        SpecialJumpSequence = "chainsaw.CampaignJumper.Order.SpecialOrderType", IsChapterStart = "System.Boolean" })
    class("chainsaw.CampaignManager.GameData", "System.Object", {}, { _InitialSettings = "chainsaw.CampaignInitialSetting" })
    -- The start point catalog (docs/RESEARCH.md 3.35): CampaignInitialSettingKey -> the chapter
    -- part's CampaignInitialSetting. world.start_points[key] = { chapter, special, chars = {
    -- { kind, stage, pos, rot } } } (Leon first); defaults from the game's own
    -- leveldesign/initialsettings/chpX-Y.user.2. world.start_catalog_off: not loaded.
    world.start_points = {
        [6] = { chapter = 21100, special = 2, chars = {
            { kind = 100000, stage = 40500, pos = vec(-256.70, 5.09, 26.02), rot = quat(0, 0.074, 0, 0.997) } } },
        [7] = { chapter = 21200, special = 3, chars = {
            { kind = 100000, stage = 44410, pos = vec(3.825, -6.087, 231.462), rot = quat(0, 0.999, 0, -0.042) } } },
        [10] = { chapter = 22200, special = 5, chars = {
            { kind = 100000, stage = 45401, pos = vec(98.72, 16.24, 94.59), rot = quat(0, 0.594, 0, 0.804) },
            { kind = 200030, stage = 45401, pos = vec(97.55, 16.21, 96.54), rot = quat(0, -0.736, 0, 0.677) } } },
    }
    class("chainsaw.EnvSceneStructureDB", "System.Object", {
        getCampaignInitialSetting = { 1, function(_, key)
            local sp = world.start_points[key]
            if sp == nil or world.start_catalog_off then return nil end
            world.start_point_reads = (world.start_point_reads or 0) + 1
            local list = {}
            for i, c in ipairs(sp.chars) do
                local loc = new("chainsaw.GameLocator", { __fields = { _Stage = c.stage, _Position = vec(c.pos.x, c.pos.y,
                    c.pos.z), _Rotation = quat(c.rot.x, c.rot.y, c.rot.z, c.rot.w) } })
                list[i] = new("chainsaw.CampaignInitialSetting.CharacterProperty", { __fields = { _Character = c.kind,
                    _DefaultRole = i == 1 and 0 or 10, _Locator = loc } })
            end
            return new("chainsaw.CampaignInitialSetting", { __fields = { _Chapter = sp.chapter,
                _SpecialJumpSequence = sp.special, _CharacterList = M.array(list) } })
        end, { "chainsaw.CampaignInitialSettingKey" }, { ret = "chainsaw.CampaignInitialSetting" } },
    })
    world.singletons["chainsaw.EnvSceneStructureDB"] = new("chainsaw.EnvSceneStructureDB")
    local function copy_locator(src)
        local f = src.__fields
        return new("chainsaw.GameLocator", { __fields = { _Stage = f._Stage, _Position = vec(f._Position.x, f._Position.y,
            f._Position.z), _Rotation = quat(f._Rotation.x, f._Rotation.y, f._Rotation.z, f._Rotation.w) } })
    end
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
            world.initial_settings = init
            world.loads = world.loads + 1
        end, { "chainsaw.CampaignManager.GameData" } },
        -- Order(InitialSettings): each character's entry with a copy of its locator, the base
        -- character the first (getPL1Index); a new game's jump also gets the setting's opening.
        createCampaignJumperOrderFromInitialSettings = { 4, function(_, _, _, _, special)
            local init = world.initial_settings
            if init == nil then return nil end
            local entries = {}
            local list = init.__fields._CharacterList
            for _, prop in ipairs(list and list.list or {}) do
                entries[#entries + 1] = new("chainsaw.CampaignJumper.Order.CharacterEntry", { __fields = {
                    Property = prop, Locator = copy_locator(prop.__fields._Locator) } })
            end
            local order = new("chainsaw.CampaignJumper.Order", { __fields = { Chapter = init.__fields._Chapter,
                CharacterEntryList = M.array(entries), LoadBaseCharacter = 0, SpecialJumpSequence = 0,
                IsChapterStart = false } })
            if special then
                order.__fields.SpecialJumpSequence = init.__fields._SpecialJumpSequence
                order.__fields.IsChapterStart = true
            end
            return order
        end, { "System.Boolean", "System.Boolean", "System.Boolean", "System.Boolean" },
            { ret = "chainsaw.CampaignJumper.Order" } },
    })
    -- Saving and loading (docs/RESEARCH.md 3.15). Every save goes through
    -- SaveFlowController.start(slot, args); SaveDataManager.requestStartSaveGameDataFlow is a
    -- jump to it. Continue loads SaveLoadMenuGuiManager.findContinueSave() (the newest of slots
    -- 0-20); the menus run it on their own when UDSManagerApp's game intent is requested.
    world.save_files = {}  -- slot -> { chapter, order }
    world.saves = {}       -- slots written, in order
    world.save_busy = false
    world.save_excluded = false
    world.save_order = 0
    class("chainsaw.ChainsawGameSaveRequestArgs", "System.Object", {})
    class("chainsaw.SaveFlowController", "System.Object", {
        start = { 2, function(_, slot, args)
            assert(type(slot) == "number", "slot must be a number")
            assert(args ~= nil and args.__type == "chainsaw.ChainsawGameSaveRequestArgs", "game save request args")
            world.save_order = world.save_order + 1
            world.saves[#world.saves + 1] = slot
            world.save_files[slot] = { chapter = world.chapter, order = world.save_order }
        end, { "System.Int32", "share.SaveLoadRequestArgs" } },
    })
    world.save_flow = new("chainsaw.SaveFlowController")
    class("share.SaveDataManager", "System.Object", {
        get_IsBusy = { 0, function() return world.save_busy end, {}, { ret = "System.Boolean" } },
        checkExcludeGameSave = { 0, function() return world.save_excluded end, {}, { ret = "System.Boolean" } },
        isExistSaveData = { 1, function(_, slot) return world.save_files[slot] ~= nil end, { "System.Int32" },
            { ret = "System.Boolean" } },
        ["setPlayLoadData(System.Boolean)"] = { 1, function() world.play_load_marked = true end, { "System.Boolean" } },
        requestStartSaveGameDataFlow = { 2, function(_, slot, args)
            return world.save_flow:call("start", slot, args)
        end, { "System.Int32", "share.GameSaveRequestArgs" } },
        -- Loading (docs/RESEARCH.md 3.34): the request is queued, read while the system is busy
        -- (M.save_system_tick), then waits as LoadedGamedataApplyable for the in-game setup.
        ["setPlayLoadData(System.Boolean, System.Int32)"] = { 2, function(_, auto, slot)
            world.play_load = { auto = auto, slot = slot }
        end, { "System.Boolean", "System.Int32" } },
        ["enqueueLoadRequest(System.Int32, share.SaveLoadRequestArgs)"] = { 2, function(_, slot, args)
            assert(type(slot) == "number", "slot must be a number")
            assert(args ~= nil and args.__type == "share.GameLoadRequestArgs", "game load request args")
            world.load_requests = world.load_requests or {}
            world.load_requests[#world.load_requests + 1] = slot
            world.load_queue = slot
        end, { "System.Int32", "share.SaveLoadRequestArgs" } },
        get_LoadedGamedataApplyable = { 0, function() return world.loaded_applyable == true end, {},
            { ret = "System.Boolean" } },
        get_LastLoadSuccessedGameSlot = { 0, function() return world.loaded_slot or -1 end, {}, { ret = "System.Int32" } },
    })
    class("share.SaveLoadRequestArgs", "System.Object", {})
    class("share.GameLoadRequestArgs", "share.SaveLoadRequestArgs", {})
    world.singletons["share.SaveDataManager"] = new("share.SaveDataManager")
    -- Leaving the game for a load (the pause menu's Load Game): HighwayGuiManager
    -- .setFixInGameStateExit, ClapperboardMediator.clearRequestTimeline, then
    -- MainModeManager.requestToChangeGameState(GameStateInGameCleanup, Argument{NextState}).
    class("chainsaw.GameStateIngameSetup", "System.Object", {})
    class("chainsaw.GameStateInGameCleanup", "System.Object", {})
    class("share.GameStateArgument", "System.Object", {})
    class("chainsaw.GameStateInGameCleanup.Argument", "share.GameStateArgument", {}, { Reset = "System.Boolean",
        NextState = "System.Type", IsFromEnding = "System.Boolean", IsDifficultyChanged = "System.Boolean",
        Difficulty = "chainsaw.CampaignManager.Difficulty" })
    add_methods("share.MainModeManager", {
        ["requestToChangeGameState(System.Type, share.GameStateArgument)"] = { 2, function(_, t, arg)
            world.state_requests = world.state_requests or {}
            world.state_requests[#world.state_requests + 1] = { state = t and t.name,
                next = arg and arg.__fields.NextState and arg.__fields.NextState.name, fix_exit = world.fix_exit,
                timeline_cleared = world.timeline_cleared }
        end, { "System.Type", "share.GameStateArgument" } },
    })
    add_methods("chainsaw.HighwayGuiManager", {
        setFixInGameStateExit = { 0, function() world.fix_exit = true end },
        get_SaveLoadMenuGuiManager = { 0, function() return world.save_menu end },
    })
    add_methods("chainsaw.ClapperboardMediator", {
        clearRequestTimeline = { 0, function() world.timeline_cleared = true end },
    })
    class("chainsaw.gui.SaveSlotInfo", "System.Object", {}, { SlotIndex = "System.Int32", ChapterID = "chainsaw.ChapterID" })
    class("chainsaw.gui.SaveSlotInfoDetail", "System.Object", {
        get_IsEmpty = { 0, function(self) return self.__fields["<IsEmpty>k__BackingField"] end },
    }, { ["<IsEmpty>k__BackingField"] = "System.Boolean", ["<Info>k__BackingField"] = "chainsaw.gui.SaveSlotInfo" })
    local function slot_detail(slot)
        local f = slot ~= nil and world.save_files[slot] or nil
        local info = f and new("chainsaw.gui.SaveSlotInfo", { __fields = { SlotIndex = slot, ChapterID = f.chapter } }) or nil
        return new("chainsaw.gui.SaveSlotInfoDetail", { __fields = { ["<IsEmpty>k__BackingField"] = f == nil,
            ["<Info>k__BackingField"] = info } })
    end
    class("chainsaw.SaveLoadMenuGuiManager", "System.Object", {
        findContinueSave = { 0, function()
            local best
            for slot = 0, 20 do
                local f = world.save_files[slot]
                if f ~= nil and (best == nil or f.order > world.save_files[best].order) then best = slot end
            end
            return slot_detail(best)
        end, {}, { ret = "chainsaw.gui.SaveSlotInfoDetail" } },
        getSaveSlotInfoDetail = { 1, function(_, slot) return slot_detail(slot) end, { "System.Int32" },
            { ret = "chainsaw.gui.SaveSlotInfoDetail" } },
    })
    world.save_menu = new("chainsaw.SaveLoadMenuGuiManager")
    class("chainsaw.UDSManagerApp", "System.Object", {
        set_RequestGameIntentMode = { 1, function(self, v) self.__fields["<RequestGameIntentMode>k__BackingField"] = v end,
            { "chainsaw.UDSManagerApp.GameIntentMode" } },
        set__IsRequestGameIntent = { 1, function(self, v) self.__fields["<_IsRequestGameIntent>k__BackingField"] = v end,
            { "System.Boolean" } },
        get_IsRequestGameIntent = { 0, function(self) return self.__fields["<_IsRequestGameIntent>k__BackingField"] == true end },
    }, { ["<_IsRequestGameIntent>k__BackingField"] = "System.Boolean",
        ["<RequestGameIntentMode>k__BackingField"] = "chainsaw.UDSManagerApp.GameIntentMode" })
    world.singletons["chainsaw.UDSManagerApp"] = new("chainsaw.UDSManagerApp", { __fields = {
        ["<_IsRequestGameIntent>k__BackingField"] = false, ["<RequestGameIntentMode>k__BackingField"] = 0 } })
    class("chainsaw.GameStateTitle", "System.Object", { update = { 0, function() return true end } })
    class("chainsaw.GameStateMainMenu", "System.Object", { update = { 0, function() return true end } })
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
                -- Only a real Nullable struct carries a value; anything else is garbage to the game.
                local ok = type(status) == "table" and status.__type == STATUS and status.__fields._HasValue == true
                if not ok then world.bad_nullable = (world.bad_nullable or 0) + 1 return end
                world.scene_requests[#world.scene_requests + 1] = { mgr = mgr, id = id,
                    status = status.__fields._Value, prio = prio }
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
    local backup_db = new("System.Collections.Concurrent.ConcurrentDictionary`2<System.UInt32,chainsaw.CharacterBackup>")
    class("chainsaw.CharacterManager", "System.Object", {
        getPlayerContextRef = { 0, function() return world.player end },
        getPartnerContextRef = { 0, function() return world.partner end },
        get_PartnerContextList = { 0, function() return not world.no_partner_list and M.partner_list() or nil end },
        get_DollNpcContextList = { 0, function() return M.doll_list() end },
        get_EnemyContextList = { 0, function() return world.enemy_list end },
        get_CharacterBackupDB = { 0, function() return backup_db end },
        getSpawnParamRef = M.character_manager_methods.getSpawnParamRef,
        getContextRef = M.character_manager_methods.getContextRef,
        isActive = { 1, function(_, stage) return world.active_stages ~= nil and world.active_stages[stage] == true end },
        [WARP] = { 4, function(_, id, npos, nrot, sid)
            local function value(n, t)
                if type(n) ~= "table" or n.__type ~= "System.Nullable`1<" .. t .. ">" or n.__fields._HasValue ~= true then
                    return nil
                end
                return n.__fields._Value
            end
            local pos, rot = value(npos, "via.vec3"), value(nrot, "via.Quaternion")
            if pos == nil or rot == nil then
                world.bad_nullable = (world.bad_nullable or 0) + 1
                return
            end
            world.warps[#world.warps + 1] = { pos = { x = pos.x, y = pos.y, z = pos.z }, rot = rot, stage = sid.stage, id = id }
            if world.refuse_warp or world.player == nil then return end
            local p = world.player.pos
            p.x, p.y, p.z = pos.x, pos.y, pos.z
            world.player.stage = sid.stage
        end, { "chainsaw.ContextID", "System.Nullable`1<via.vec3>", "System.Nullable`1<via.Quaternion>",
            "chainsaw.StageIdentifier" } },
    })

    -- Breakables and animals: scene components with a _Routine state machine. A gimmick's
    -- state machine runs from its GimmickCore, which GimmickManager updates while it is
    -- registered (registerMove / unregisterMove; see M.update_gimmicks).
    enum("chainsaw.GmWoodBoxBase.RoutineType", { Wait = 0, Damage = 1, Break = 2, BrokenWait = 3 })
    enum("chainsaw.GmCrow.RoutineType", { Idle = 0, Reaction = 1, Croak = 2, Peck = 3, Drink = 4, Run = 5,
        Landing = 6, Die = 7, Dead = 8, Sleep = 9, Loop = 10 })
    class("chainsaw.GimmickCore", "via.Component", {}, { _HasRegisteredMove = "System.Boolean" })
    -- A live gimmick bound to a context (M.make_live_gimmick) keeps its flag in the gimmick
    -- table: attribute 0 (GmBase.setGmFlag 0x141602d40: written, then onChangeGmFlag).
    local function live_flag(self)
        local g = self.ctx_key and world.gimmick_table[self.ctx_key]
        if g ~= nil then return (g.attr[1] or 0) ~= 0 end
        return self.flag == true
    end
    class("chainsaw.GmBase", "via.Component", {
        get_Core = { 0, function(self) return self.core end },
        get_Context = { 0, function(self) return self.context end },
        get_HasInitialized = { 0, function(self) return self.initialized ~= false end },
        -- The gimmick flag (attribute 0 of its context); a change runs onChangeGmFlag.
        setGmFlag = { 3, function(self, v, trig, args)
            if live_flag(self) ~= (v == true) then
                local g = self.ctx_key and world.gimmick_table[self.ctx_key]
                if g ~= nil then g.attr[1] = v and 1 or 0 else self.flag = v == true end
                if self.on_flag then self.on_flag(v == true) end
                self:call("onChangeGmFlag", v == true, trig, args)
            end
        end, { "System.Boolean", "chainsaw.InteractTrigger", "chainsaw.InteractActionArgs" } },
        getGmFlag = { 0, function(self) return live_flag(self) end },
        onChangeGmFlag = { 3, function() end, { "System.Boolean", "chainsaw.InteractTrigger", "chainsaw.InteractActionArgs" },
            { code = "stub" } },
    })
    -- GmUseItem (0x142fb7210): flag on -> its "use" sequence (the item set in the slot, the
    -- lock opening) with the trigger of the player who used it, or none.
    class("chainsaw.GmUseItem", "chainsaw.GmBase", {
        onChangeGmFlag = { 3, function(self, v, trig, args)
            if v and self.port ~= nil then
                self.port:call("call(System.UInt32, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)", self.use_key or 0x55E, trig, args)
            end
            -- A sequence of another object it sets off (a door the slot unlocks).
            if v and self.linked ~= nil then
                self.linked.port:call("call(System.UInt32, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)", self.linked_key or 1, trig, args)
            end
        end, { "System.Boolean", "chainsaw.InteractTrigger", "chainsaw.InteractActionArgs" } },
    })
    -- A puzzle door that only reads its state when it is set up (no reaction of its own).
    class("chainsaw.GmPutItemsPedestal", "chainsaw.GmBase", {})
    -- A pushed cart or shelf: its motion (MotWait / MotMove / MotMoved) and the AI map blocker.
    local push = class("chainsaw.GmPushMove", "chainsaw.GmBase", {
        setGmMotion = { 1, function(self, m) self.motion = m end, { "System.UInt32" } },
        moveEffectorShape = { 1, function(self, v) self.effector_moved = v end, { "via.vec3" } },
    }, { _Move = "via.vec3" })
    push.static_values = { MotWait = 100, MotMove = 101, MotMoved = 102 }
    class("chainsaw.GmLever", "chainsaw.GmBase", {})
    class("chainsaw.GmShelves", "chainsaw.GmBase", {})
    class("chainsaw.GmWoodBoxBase", "chainsaw.GmBase", {}, { _Routine = "chainsaw.GmWoodBoxBase.RoutineType" })
    class("chainsaw.GmWoodBox", "chainsaw.GmWoodBoxBase", {})
    class("chainsaw.GmAnimal", "chainsaw.GmBase", {
        get_Motion = { 0, function(self) return self.__fields._Motion end },
    }, { _Motion = "via.motion.Motion" })
    class("chainsaw.GmCrow", "chainsaw.GmAnimal", {
        set_Routine = { 1, function(self, v) self.__fields._Routine = v end, { "chainsaw.GmCrow.RoutineType" } },
    }, { _Routine = "chainsaw.GmCrow.RoutineType" })
    class("chainsaw.GmBottle", "chainsaw.GmBase", {})
    -- Traps (re4.exe, docs/RESEARCH.md 3.18), stepped by M.update_traps the way their
    -- updateGimmick runs: the gimmick flag (GmBase.setGmFlag) is attribute 0 of the context.
    world.trap_sounds, world.explosions = 0, 0
    local function set_flag(self, v)
        if (self.flag == true) ~= (v == true) then self.flag = v == true end
    end
    local gm_flag = {
        setGmFlag = { 3, function(self, v) set_flag(self, v) end,
            { "System.Boolean", "chainsaw.InteractTrigger", "chainsaw.InteractActionArgs" } },
        getGmFlag = { 0, function(self) return self.flag == true end },
    }
    local leg = { requestSetClosed = { 0, function(self)
        self.__fields._Routine, self.__fields._Rno = 3, 0
        set_flag(self, true)
    end }, requestOpenByEm = { 0, function(self)
        set_flag(self, false)
        self.__fields._Routine, self.__fields._Rno = 7, 0
    end } }
    for k, v in pairs(gm_flag) do leg[k] = v end
    class("chainsaw.GmLegHoldTrap", "chainsaw.GmBase", leg, { _Routine = "chainsaw.GmLegHoldTrap.RoutineType",
        _Rno = "System.Int32" })
    local bomb = {}
    for k, v in pairs(gm_flag) do bomb[k] = v end
    class("chainsaw.GmSensorBomb", "chainsaw.GmBase", bomb, { _Routine = "chainsaw.GmSensorBomb.RoutineType",
        _Rno = "System.Int32" })
    -- Doors (re4.exe, docs/RESEARCH.md 3.11): bit 0 of the context's first attribute = open;
    -- _NeedKeepOpenSelf[0] = our player keeps it open, [1] = the other player
    -- (recvGmParam); it closes by itself once neither does.
    enum("chainsaw.GmDoor.RoutineType", { Close = 0, Open = 1 })
    class("chainsaw.GmContextDoor", "System.Object", {
        ["getAttr(System.Int32)"] = { 1, function(self, i) return self.attr[i + 1] or 0 end, { "System.Int32" },
            { ret = "System.Byte" } },
        ["pushAttr(System.Int32, System.Byte)"] = { 2, function(self, i, v)
            self.attr[i + 1] = v
            self.pushes = (self.pushes or 0) + 1
        end, { "System.Int32", "System.Byte" } },
    })
    class("chainsaw.GmDoor", "chainsaw.GmBase", {
        get_GmkContext = { 0, function(self) return self.ctx end, {}, { ret = "chainsaw.GmContextDoor" } },
        recvGmParam = { 3, function(self, t, arg)
            rawget(self.__fields._NeedKeepOpenSelf, "__items")[t + 1] = arg ~= 0
        end, { "System.Int32", "System.Int32", "via.GameObject" } },
    }, { _Routine = "chainsaw.GmDoor.RoutineType", _NeedKeepOpenSelf = "System.Boolean[]" })
    -- Automatic / elevator doors (GmAutoDoorBase.calcRoutine): open while _OpenTimer runs; the
    -- sensor reloads it (CloseWaitTime) by setting _ActivateOpen, consumed each update.
    class("chainsaw.GmAutoDoorBase", "chainsaw.GmBase", {}, { _Rno0 = "System.Int32", _OpenTimer = "System.Single",
        _ActivateOpen = "System.Boolean", CloseWaitTime = "System.Single" })
    class("chainsaw.GmAutoDoor", "chainsaw.GmAutoDoorBase", {})
    class("chainsaw.GmElevatorDoor", "chainsaw.GmAutoDoorBase", {})
    -- Big double doors: open (Open/Opened) while IsAnyOneCloseToDoor > 0.
    enum("chainsaw.GmBigDoor.RoutineType", { Closed = 0, Close = 1, Open = 2, Opened = 3, ForceOpened = 4 })
    class("chainsaw.GmBigDoor", "chainsaw.GmBase", {}, { _Routine = "chainsaw.GmBigDoor.RoutineType",
        IsAnyOneCloseToDoor = "System.Int32" })
end

-- Defines a scenario flag: its GUID lives at bit `bit` of flag group `group` (1-based index).
-- opts: { kind = 2 (Boolean) | 16 (Trigger), common = bool, read_only = bool }
function M.add_flag(guid, group, bit, opts)
    opts = opts or {}
    guid = guid:lower()
    M.world.flag_map[guid] = { group = group, bit = bit }
    local var = new("via.userdata.Variable", { guid = guid, group = group, bit = bit, kind = opts.kind or 2,
        common = opts.common, read_only = opts.read_only })
    M.world.flag_vars[guid] = var
    M.world.flag_groups[group].vars[bit] = var
    return var
end

function M.flag_value(guid)
    local f = M.world.flag_map[guid:lower()]
    local g = M.world.flag_groups[f.group]
    return (g.words[f.bit // 32 + 1] & (1 << (f.bit % 32))) ~= 0
end

-- Game code sets a scenario flag (Variable.set_Bool from anywhere: its change handlers run).
function M.game_set_flag(guid, value)
    return M.set_var(M.world.flag_vars[guid:lower()], value)
end

-- Game code fires a trigger-kind flag.
function M.game_pulse_flag(guid)
    return M.world.flag_vars[guid:lower()]:call("setTrigger")
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

-- A gimmick loaded and set up in this game, bound to its context `ctx` in the gimmick table:
-- its GameObject (GUID), GimmickCore, the gimmick component and its sequence (a PortrayalSettings
-- with one parameter set per key: opts.keys = { [key] = { callees = {...}, end_callees = {...} } }).
function M.make_live_gimmick(type_name, ctx, guid, opts)
    opts = opts or {}
    local key = M.set_gimmick(ctx, opts.attr or { 0, 0 })
    local go = M.make_go(type_name:match("([^.]+)$"))
    go.guid = guid
    local core = M.add_component(go, "chainsaw.GimmickCore")
    local params = {}
    for k, spec in pairs(opts.keys or { [0x55E] = {} }) do
        local plays, ends = {}, {}
        for _, c in ipairs(spec.callees or {}) do plays[#plays + 1] = new(c) end
        for _, c in ipairs(spec.end_callees or {}) do ends[#ends + 1] = new(c) end
        local param = new("chainsaw.PortrayalSettings.Param", { key = k, __fields = {
            _CalleePlay = typed_array("System.Object", plays), _CalleeEnd = typed_array("System.Object", ends) } })
        params[#params + 1] = param
    end
    local settings = new("chainsaw.OptionSettings`1<chainsaw.PortrayalSettings.Param>", { __fields = {
        _Params = typed_array("chainsaw.PortrayalSettings.Param", params) } })
    local port = M.add_component(go, "chainsaw.PortrayalSettings", { __fields = { _Params = settings } })
    local context = new("chainsaw.GimmickContext", { key = key, ctx = ctx, __fields = {} })
    local comp = M.add_component(go, type_name, { ctx_key = key, context = context, core = core, port = port,
        use_key = opts.use_key, linked = opts.linked, linked_key = opts.linked_key, initialized = opts.initialized })
    M.world.live_gimmicks = M.world.live_gimmicks or {}
    M.world.live_gimmicks[key] = { core = core, comp = comp, context = context, go = go }
    return comp, key
end

-- FlagInfo[] as the game builds it (elements inline from 0x20, 8 bytes each).
local function flag_info_array(list)
    if list == nil or #list == 0 then return nil end
    local arr = typed_array("chainsaw.ScenarioFlagManager.FlagInfo", {}, #list)
    for i, f in ipairs(list) do
        arr:write_dword(0x20 + (i - 1) * 8, f.group)
        arr:write_dword(0x24 + (i - 1) * 8, f.index)
    end
    return arr
end

-- The game requests a cutscene "play once" (what calcRequest does): refused if this save
-- already played it, else packed into a PayloadPlay and played (hooks on procPayloadPlay run).
-- opts: { camera = 1|2, screen, start_flags = {{group (0-based), index}}, end_flags, owner, end_portrayal }
function M.start_cutscene(id, opts)
    opts = opts or {}
    local w = M.world
    local camera = opts.camera or 1
    if w.has_done[("%d:%d"):format(camera, id)] then
        w.refused_requests = (w.refused_requests or 0) + 1 -- setupAndCheck: seen, Option.fireOnFailed
        return 0
    end
    local p = new("chainsaw.ClapperboardMediator.PayloadPlay", { __fields = { CameraType = camera, ID = id,
        Screen = opts.screen or 0, StartFlag = flag_info_array(opts.start_flags), EndFlag = flag_info_array(opts.end_flags),
        DataOwnerCode = opts.owner or 0xFFFFFFFF, EndPortrayal = opts.end_portrayal or 0 } })
    local mediator = w.singletons["chainsaw.ClapperboardMediator"]
    local play_id = mediator:call("emitPlayID")
    mediator:call("procPayloadPlay", play_id, p)
    return play_id
end

-- The game changes chapter the way RE4 does at the end of a chapter-ending cutscene (the bell
-- in the village: GameStateInGameChapterChange): another game state runs behind a black screen
-- (CAMPAIGN_JUMPER and EVENT fades), the player's context lives on, the chapter changes.
function M.chapter_change(next_chapter, phase)
    local w = M.world
    w.game_state = "chainsaw.GameStateInGameChapterChange"
    w.singletons["share.MainModeManager"].__fields.CurrentGameState.__fields.GameState.__fields["<CurrPhase>k__BackingField"] = phase or 4
    w.fades[2], w.fades[4] = true, true
    if next_chapter ~= nil then w.chapter = next_chapter end
end

-- The chapter change hands the game back (GameStateInGame). lift = false: the black stays
-- (what the client saw after the bell).
function M.end_chapter_change(lift)
    local w = M.world
    w.game_state = "chainsaw.GameStateInGame"
    w.singletons["share.MainModeManager"].__fields.CurrentGameState.__fields.GameState.__fields["<CurrPhase>k__BackingField"] = 0
    if lift ~= false then w.fades[2], w.fades[4] = nil, nil end
end

-- The playing cutscene ends: its end flags are set and its data owner's scripted sequence
-- continues.
function M.end_cutscene()
    local w = M.world
    w.gui_event = false
    w.event_id = 0
    local rec = w.current_cutscene
    w.current_cutscene = nil
    if rec == nil then return end
    w.singletons["chainsaw.ClapperboardMediator"].__fields._Plays = typed_array("chainsaw.ClapperboardMediator.PlayWork", {})
    for _, f in ipairs(rec.end_flags or {}) do
        local g = w.flag_groups[f.group + 1]
        local var = g and g.vars[f.index]
        if var ~= nil then M.set_var(var, true) end
    end
    if rec.owner ~= nil and rec.owner ~= 0xFFFFFFFF and rec.end_portrayal ~= 0 then
        w.continued[#w.continued + 1] = { owner = rec.owner, portrayal = rec.end_portrayal }
    end
end

-- The 32-bit hash the game takes of a trigger's name (any stable hash serves the mock).
function M.name_hash(s)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
    return h
end

-- A level trigger: a GameObject (scene GUID) with an InteractHolder holding one trigger, plus
-- the components that make it an event (or not). opts: { components = {type names},
-- once = bool (default true), key = bool (a key trigger instead of an area), process(target),
-- callees = {type names a portrayal on it calls} }
function M.make_trigger(guid, name, opts)
    opts = opts or {}
    local go = M.make_go(name)
    go.guid = guid
    local holder = M.add_component(go, "chainsaw.InteractHolder", { triggers = {} })
    for _, tn in ipairs(opts.components or { "chainsaw.GmPortrayalAreaHit" }) do
        if tn == "chainsaw.PortrayalSettings" then
            local callees = {}
            for _, c in ipairs(opts.callees or {}) do callees[#callees + 1] = new(c) end
            local param = new("chainsaw.PortrayalSettings.Param", { __fields = { _CalleePlay = typed_array("System.Object", callees) } })
            local settings = new("chainsaw.OptionSettings`1<chainsaw.PortrayalSettings.Param>", { __fields = {
                _Params = typed_array("chainsaw.PortrayalSettings.Param", { param }) } })
            M.add_component(go, tn, { __fields = { _Params = settings } })
        else
            M.add_component(go, tn)
        end
    end
    local trig = new(opts.key and "chainsaw.InteractTriggerKey" or "chainsaw.InteractTriggerAreaHit", {
        ttype = opts.key and 2 or 1, owner_go = go, hash = M.name_hash(name), process = opts.process,
        __fields = { Succeed = opts.once == false and 0 or 1, UniqueName = name, ["<Done>k__BackingField"] = 0 } })
    holder.triggers[1] = trig
    return { go = go, holder = holder, trigger = trig }
end

-- What a trigger's registered processes do when it runs.
function M.run_trigger(trig, target)
    M.world.trigger_runs[#M.world.trigger_runs + 1] = { trig = trig, target = target }
    if trig.process then trig.process(target) end
end

-- InteractManager accepts a trigger the player activated: a play-once trigger is marked done
-- and run through executeTrigger (hooks run). False if it was done already.
function M.activate_trigger(t, target)
    local f = t.trigger.__fields
    if f.Succeed == 1 and f["<Done>k__BackingField"] ~= 0 then return false end
    if f.Succeed == 1 then f["<Done>k__BackingField"] = f["<Done>k__BackingField"] | 1 end
    local work = new("chainsaw.InteractTrigger.Work", { trig = t.trigger })
    work:call("executeTrigger", target, nil)
    return true
end

-- The game saves into `slot` on its own (an autosave point: 0; a typewriter: the chosen slot).
function M.game_save(slot)
    M.world.save_flow:call("start", slot, M.new("chainsaw.ChainsawGameSaveRequestArgs"))
end

-- One frame of the title screen ("title") or the main menu ("menu"): the game state's update.
-- A requested game intent makes the menus run Continue (findContinueSave, then the load):
-- returns the slot loaded, or nil.
function M.menu_frame(where)
    local w = M.world
    local st = M.new(where == "title" and "chainsaw.GameStateTitle" or "chainsaw.GameStateMainMenu")
    st:call("update")
    local uds = w.singletons["chainsaw.UDSManagerApp"]
    if uds.__fields["<_IsRequestGameIntent>k__BackingField"] ~= true then return nil end
    if where == "title" then return nil end -- the title only skips to the main menu
    uds.__fields["<_IsRequestGameIntent>k__BackingField"] = false -- Decided: resetRequestGameIntent
    local detail = w.save_menu:call("findContinueSave")
    if detail == nil or detail.__fields["<IsEmpty>k__BackingField"] then return nil end
    local slot = detail.__fields["<Info>k__BackingField"].__fields.SlotIndex
    w.loaded_slot = slot
    M.load_save(w.save_files[slot].chapter, w.save_files[slot])
    M.ingame_setup()
    return slot
end

-- The game loads a save (Continue / Load) of `chapter` through CampaignManager.loadGameSaveData.
-- where = { stage, pos, ashley = { stage, pos } }: where the save's characters stood (default:
-- stage 40100 at the origin, Leon alone). Leon is CharacterKindID ch0_a0z0 (100000), Ashley
-- ch2_a1z0 (200030).
M.LEON_KIND, M.ASHLEY_KIND = 100000, 200030
function M.load_save(chapter, where)
    where = where or {}
    local function character(kind, stage, pos)
        local loc = new("chainsaw.GameLocator", { __fields = { _Stage = stage, _Position = vec(pos.x, pos.y, pos.z),
            _Rotation = quat(0, 0, 0, 1) } })
        return new("chainsaw.CampaignInitialSetting.CharacterProperty", { __fields = { _Character = kind, _Locator = loc } })
    end
    local list = { character(M.LEON_KIND, where.stage or 40100, where.pos or vec(0, 0, 0)) }
    if where.ashley then
        list[2] = character(M.ASHLEY_KIND, where.ashley.stage or where.stage or 40100, where.ashley.pos or vec(1, 0, 0))
    end
    local init = new("chainsaw.CampaignInitialSetting", { __fields = { _Chapter = chapter, _SpecialJumpSequence = 0,
        _CharacterList = M.array(list) } })
    local data = new("chainsaw.CampaignManager.GameData", { __fields = { _InitialSettings = init } })
    M.world.singletons["chainsaw.CampaignManager"]:call("loadGameSaveData", data)
end

-- The in-game setup after a load or a new game: builds the campaign jump and runs it - the map
-- loads around the base character's locator, the player appears at it. Returns the jump.
function M.ingame_setup(new_game)
    local w = M.world
    local order = w.singletons["chainsaw.CampaignManager"]:call("createCampaignJumperOrderFromInitialSettings", true,
        true, true, new_game == true)
    if order == nil then return nil end
    local f = order.__fields
    local base = f.CharacterEntryList.list[f.LoadBaseCharacter + 1].__fields.Locator.__fields
    w.stage, w.jumps, w.last_order = base._Stage, (w.jumps or 0) + 1, order
    w.opening_played = f.SpecialJumpSequence ~= 0 or f.IsChapterStart == true
    -- (CampaignJumper.updateLeaveStart: a special order is a new game's opening; IsChapterStart
    -- plays the chapter's opening event, as the game's own chapter change does.)
    w.special_order, w.chapter_start = f.SpecialJumpSequence, f.IsChapterStart == true
    if w.player ~= nil then
        local p = w.player.pos -- moved in place: the body follows the same table
        p.x, p.y, p.z = base._Position.x, base._Position.y, base._Position.z
        w.player.stage = base._Stage
    end
    return order
end

-- The save system's work of a frame: a queued load is read (the system busy for a frame), then
-- waits to be applied.
function M.save_system_tick()
    local w = M.world
    if w.load_queue == nil then return end
    if not w.save_busy then
        w.save_busy = true
        return
    end
    w.save_busy = false
    if w.save_files[w.load_queue] ~= nil and not w.load_fails then
        w.loaded_applyable, w.applyable_slot = true, w.load_queue
    end
    w.load_queue = nil
end

-- The state change the in-game load asked for runs: the cleanup unloads the map, the in-game
-- setup applies the loaded save and runs its campaign jump. Returns the jump.
function M.run_ingame_reload()
    local w = M.world
    local req = w.state_requests and w.state_requests[#w.state_requests]
    assert(req ~= nil and req.state == "chainsaw.GameStateInGameCleanup", "no cleanup requested")
    assert(req.next == "chainsaw.GameStateIngameSetup", "the cleanup must lead to the in-game setup")
    local slot = w.applyable_slot
    w.loaded_applyable, w.applyable_slot, w.loaded_slot = false, nil, slot
    M.load_save(w.save_files[slot].chapter, w.save_files[slot])
    return M.ingame_setup()
end

-- A breakable or animal in the scene, with the GameObject GUID from the scene file. Animals
-- get a GimmickCore registered for the game's update and a Motion with one layer.
function M.make_object(type_name, guid, pos, routine)
    local go = M.make_go(type_name:match("([^.]+)$"), { wpos = vec(pos.x, pos.y, pos.z) })
    go.guid = guid
    local comp = M.add_component(go, type_name, { __fields = { _Routine = routine or 0 } })
    if classes[type_name]:is_a("chainsaw.GmAnimal") then
        local core = M.add_component(go, "chainsaw.GimmickCore", { __fields = { _HasRegisteredMove = true } })
        comp.core = core
        M.world.moving[core] = true
        comp.__fields._Motion = M.add_component(go, "via.motion.Motion",
            { layers = { new("via.motion.TreeLayer", { bank = 7, motion = 1, frame = 0 }) } })
    end
    local list = M.world.components[type_name] or {}
    list[#list + 1] = comp
    M.world.components[type_name] = list
    return comp
end

-- A door (GmDoor) in the scene with that GameObject GUID, closed.
function M.make_door(guid, pos)
    local go = M.make_go("Door", { wpos = vec(pos.x, pos.y, pos.z) })
    go.guid = guid
    local comp = M.add_component(go, "chainsaw.GmDoor", { __fields = { _Routine = 0,
        _NeedKeepOpenSelf = typed_array("System.Boolean", { false, false }) } })
    comp.ctx = new("chainsaw.GmContextDoor", { attr = { 0, 0, 0, 0 } })
    local list = M.world.components["chainsaw.GmDoor"] or {}
    list[#list + 1] = comp
    M.world.components["chainsaw.GmDoor"] = list
    return comp
end

-- An automatic door (or "chainsaw.GmElevatorDoor"...) / a big double door in the scene.
function M.make_auto_door(guid, pos, type_name)
    type_name = type_name or "chainsaw.GmAutoDoor"
    local go = M.make_go("AutoDoor", { wpos = vec(pos.x, pos.y, pos.z) })
    go.guid = guid
    local comp = M.add_component(go, type_name, { __fields = { _Rno0 = 0, _OpenTimer = 0, _ActivateOpen = false,
        CloseWaitTime = 1.0 } })
    local list = M.world.components[type_name] or {}
    list[#list + 1] = comp
    M.world.components[type_name] = list
    return comp
end

function M.make_big_door(guid, pos)
    local go = M.make_go("BigDoor", { wpos = vec(pos.x, pos.y, pos.z) })
    go.guid = guid
    local comp = M.add_component(go, "chainsaw.GmBigDoor", { __fields = { _Routine = 0, IsAnyOneCloseToDoor = 0 } })
    local list = M.world.components["chainsaw.GmBigDoor"] or {}
    list[#list + 1] = comp
    M.world.components["chainsaw.GmBigDoor"] = list
    return comp
end

-- Our player opens the door and stands in it (in_doorway = true) or walks on (false).
function M.player_at_door(door, in_doorway)
    if in_doorway then door.ctx.attr[1] = door.ctx.attr[1] | 1 end
    door.player_in = in_doorway
end

-- GmDoor.updateGimmick for every door: an open bit opens it; open, it closes once nobody keeps
-- it open (Host: our player in the doorway; Guest: set by recvGmParam). Automatic doors and
-- big doors as their own updates do (0.1 s per call).
function M.update_doors()
    for _, list in ipairs({ M.world.components["chainsaw.GmAutoDoor"] or {}, M.world.components["chainsaw.GmElevatorDoor"] or {} }) do
        for _, d in ipairs(list) do
            local f = d.__fields
            if d.sensor then f._ActivateOpen = true end -- our player in its sensor
            if f._ActivateOpen then
                f._OpenTimer, f._ActivateOpen = f.CloseWaitTime, false
            else
                f._OpenTimer = math.max(0, f._OpenTimer - 0.1)
            end
            f._Rno0 = f._OpenTimer > 0 and 1 or 0
        end
    end
    for _, d in ipairs(M.world.components["chainsaw.GmBigDoor"] or {}) do
        local f = d.__fields
        if f._Routine >= 2 and f.IsAnyOneCloseToDoor <= 0 then f._Routine = 0 end
    end
    for _, door in ipairs(M.world.components["chainsaw.GmDoor"] or {}) do
        local f = door.__fields
        local keep = rawget(f._NeedKeepOpenSelf, "__items")
        keep[1] = door.player_in == true
        if f._Routine == 0 and (door.ctx.attr[1] & 1) ~= 0 then
            f._Routine = 1
            door.opened = (door.opened or 0) + 1
        elseif f._Routine == 1 and not keep[1] and not keep[2] then
            door.ctx.attr[1] = door.ctx.attr[1] & 0xFE
            f._Routine = 0
            door.closed = (door.closed or 0) + 1
        end
    end
end

-- An item in our attache case (Guid text `id`).
function M.case_item(id, item_id, count)
    local item = new("chainsaw.Item", { __fields = { _ItemId = item_id, _CurrentItemCount = count or 1,
        _CurrentDurability = -1, _ID = id } })
    M.world.case[id] = item
    M.world.case_room = M.world.case_room - 1
    return item
end

-- The player opens the command list of an item in the case: it is built and drawn. Returns the
-- command list (keys in drawing order) and the label each command got.
function M.open_item_commands(item)
    local w = M.world
    local args = new("chainsaw.InventoryManager.GetCommandMenuArgs", { __fields = { Item = item } })
    local dict = w.singletons["chainsaw.InventoryManager"]:call("getItemCommandMenu", args)
    local labels = {}
    for _, cmd in ipairs(dict.order) do
        local g = new("chainsaw.gui.commandmenu.ItemCommandGui", { __fields = { _CommandText = new("via.gui.Text") } })
        g:call("drawCommand", cmd, true, item)
        labels[cmd] = g.__fields._CommandText.message
    end
    return dict, labels
end

-- ...and decides on `cmd` (ItemWindowGuiState_AttacheCaseSelectCommand.decide).
function M.choose_item_command(item, cmd)
    local w = M.world
    w.selected_command = cmd
    local behavior = new("chainsaw.AcCommandMenuGuiBehavior", { __fields = {
        _ItemCommandMenuGui = new("chainsaw.gui.commandmenu.ItemCommandMenuGui") } })
    local param = new("chainsaw.ItemWindowGuiState_AttacheCaseSelectCommand.EnterParam", { __fields = {
        TargetID = item.__fields._ID } })
    local state = new("chainsaw.ItemWindowGuiState_AttacheCaseSelectCommand", { behavior = behavior,
        __fields = { _CurrEnterParam = param } })
    state:call("decide")
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
