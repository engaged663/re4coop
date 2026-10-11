-- Reflection toolkit over REFramework's `sdk`, shared by the game adapters.
--
-- RE4's internal API is not documented and changes with game patches, so the adapters
-- look things up by *shape* as much as by name: "the method on ScenarioFlagManager that
-- takes (System.Guid, System.Boolean) and whose name starts with request/set", "the field
-- on PauseManager whose type is a Dictionary of PauseParameter". Everything here is
-- defensive: lookups are cached, every engine call is pcall'ed, and failures return nil.

local R = {}
R.__index = R

function R.new(log)
    local self = setmetatable({}, R)
    self.log = log or function() end
    self.types = {}       -- name -> td | false
    self.typeofs = {}     -- name -> System.Type | false
    self.method_lists = {}
    self.enum_cache = {}
    self.hooked = {}      -- "Type::method" -> true
    return self
end

-------------------------------------------------------------------------------
-- Types, singletons, methods, fields
-------------------------------------------------------------------------------

function R:type(name)
    local td = self.types[name]
    if td == nil then
        local ok, found = pcall(sdk.find_type_definition, name)
        td = (ok and found) or false
        self.types[name] = td
    end
    return td or nil
end

function R:typeof(name)
    local t = self.typeofs[name]
    if t == nil then
        local ok, found = pcall(sdk.typeof, name)
        t = (ok and found) or false
        self.typeofs[name] = t
    end
    return t or nil
end

function R.type_name(obj)
    if obj == nil then return nil end
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or td == nil then return nil end
    local ok2, n = pcall(td.get_full_name, td)
    return ok2 and n or nil
end

-- Managed singleton, AppSingleton-style static get_Instance, or native singleton.
function R:singleton(name)
    local ok, s = pcall(sdk.get_managed_singleton, name)
    if ok and s ~= nil then return s end
    local td = self:type(name)
    if td ~= nil then
        local okm, m = pcall(td.get_method, td, "get_Instance")
        if okm and m ~= nil then
            local okc, inst = pcall(m.call, m, nil)
            if okc and inst ~= nil then return inst end
        end
    end
    return nil
end

local function param_type_names(m)
    local out = {}
    local ok, types = pcall(m.get_param_types, m)
    if ok and types ~= nil then
        for i, t in ipairs(types) do
            local ok2, n = pcall(t.get_full_name, t)
            out[i] = ok2 and n or "?"
        end
    end
    return out
end

local function return_type_name(m)
    local ok, t = pcall(m.get_return_type, m)
    if not ok or t == nil then return nil end
    local ok2, n = pcall(t.get_full_name, t)
    return ok2 and n or nil
end

-- All methods of a type (and its parents up to `depth`), as info tables:
-- { method, name, params={type names}, ret=<type name>, static=bool, owner=<type name> }
function R:methods(type_name, depth)
    local key = type_name .. "#" .. tostring(depth or 0)
    local cached = self.method_lists[key]
    if cached ~= nil then return cached end
    local out = {}
    local td = self:type(type_name)
    local level = 0
    while td ~= nil and level <= (depth or 0) do
        local ok, list = pcall(td.get_methods, td)
        if ok and list ~= nil then
            local okn, owner = pcall(td.get_full_name, td)
            for _, m in ipairs(list) do
                local okname, name = pcall(m.get_name, m)
                if okname and name ~= nil then
                    local oks, st = pcall(m.is_static, m)
                    out[#out + 1] = { method = m, name = name, params = param_type_names(m),
                        ret = return_type_name(m), static = oks and st or false, owner = okn and owner or type_name }
                end
            end
        end
        local okp, parent = pcall(td.get_parent_type, td)
        td = okp and parent or nil
        level = level + 1
    end
    self.method_lists[key] = out
    return out
end

-- First method whose info satisfies pred, preferring the order of `prefer` names.
function R:find_method(type_name, pred, prefer, depth)
    local list = self:methods(type_name, depth)
    local matches = {}
    for _, info in ipairs(list) do
        if pred(info) then matches[#matches + 1] = info end
    end
    if #matches == 0 then return nil end
    if prefer ~= nil then
        for _, want in ipairs(prefer) do
            for _, info in ipairs(matches) do
                if info.name == want then return info end
            end
        end
    end
    table.sort(matches, function(a, b)
        if #a.params ~= #b.params then return #a.params < #b.params end
        return a.name < b.name
    end)
    return matches[1]
end

function R:find_methods(type_name, pred, depth)
    local out = {}
    for _, info in ipairs(self:methods(type_name, depth)) do
        if pred(info) then out[#out + 1] = info end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Fields of a type (and parents): { field, name, type=<type name>, static=bool }
function R:fields(type_name, depth)
    local out = {}
    local td = self:type(type_name)
    local level = 0
    while td ~= nil and level <= (depth or 0) do
        local ok, list = pcall(td.get_fields, td)
        if ok and list ~= nil then
            for _, f in ipairs(list) do
                local okn, name = pcall(f.get_name, f)
                local okt, ft = pcall(function() return f:get_type():get_full_name() end)
                local oks, st = pcall(f.is_static, f)
                if okn then
                    out[#out + 1] = { field = f, name = name, type = okt and ft or "?", static = oks and st or false }
                end
            end
        end
        local okp, parent = pcall(td.get_parent_type, td)
        td = okp and parent or nil
        level = level + 1
    end
    return out
end

function R:find_field(type_name, pred, depth)
    for _, info in ipairs(self:fields(type_name, depth)) do
        if not info.static and pred(info) then return info end
    end
    return nil
end

-- Enum value <-> name maps for an enum type: values[v] = name, names[name] = v.
function R:enum(type_name)
    local cached = self.enum_cache[type_name]
    if cached ~= nil then return cached end
    local values, names = {}, {}
    for _, info in ipairs(self:fields(type_name, 0)) do
        if info.static and info.name ~= "value__" then
            local ok, v = pcall(info.field.get_data, info.field, nil)
            v = ok and R.number(v) or nil
            if v ~= nil then
                names[info.name] = v
                if values[v] == nil then values[v] = info.name end
            end
        end
    end
    cached = { values = values, names = names }
    self.enum_cache[type_name] = cached
    return cached
end

-------------------------------------------------------------------------------
-- Values
-------------------------------------------------------------------------------

function R.call(obj, name, ...)
    if obj == nil then return nil end
    local args = table.pack(...)
    local ok, r = pcall(function() return obj:call(name, table.unpack(args, 1, args.n)) end)
    if ok then return r end
    return nil
end

function R.get(obj, ...)
    if obj == nil then return nil end
    for _, name in ipairs({ ... }) do
        local ok, v = pcall(function() return obj:get_field(name) end)
        if ok and v ~= nil then return v end
    end
    return nil
end

function R.set(obj, name, value)
    if obj == nil then return false end
    return (pcall(function() obj:set_field(name, value) end))
end

local VALUE_FIELDS = { "m_value", "value__", "_value" }

-- Lua number from a number, boolean, boxed primitive or enum object. Boxed primitives (what
-- primitive arrays hand out) are the common case and take one engine call.
function R.number(v)
    local t = type(v)
    if t == "number" then return v end
    if t == "boolean" then return v and 1 or 0 end
    if v == nil then return nil end
    local get = (t == "userdata" or t == "table") and v.get_field or nil
    if get == nil then return nil end
    local ok, x = pcall(get, v, "mValue")
    if ok and type(x) == "number" then return x end
    for _, f in ipairs(VALUE_FIELDS) do
        ok, x = pcall(get, v, f)
        if ok and type(x) == "number" then return x end
    end
    local ok, s = pcall(function() return v:call("ToString()") end)
    if ok and type(s) == "string" then return tonumber(s) end
    return nil
end

function R.string(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:call("ToString()") end)
    if ok and type(s) == "string" then return s end
    return nil
end

-- Iterates an engine collection (System.Array, List`1, anything with Count/Item).
-- fn(element, index0) returns true to stop.
function R.each(coll, fn)
    if coll == nil then return end
    local ok, elems = pcall(function() return coll:get_elements() end)
    if ok and type(elems) == "table" then
        for i, e in ipairs(elems) do
            if fn(e, i - 1) then return end
        end
        return
    end
    local okc, count = pcall(function() return coll:call("get_Count") end)
    if okc and type(count) == "number" then
        for i = 0, count - 1 do
            local oki, e = pcall(function() return coll:call("get_Item", i) end)
            if oki and fn(e, i) then return end
        end
        return
    end
    local oks, size = pcall(function() return coll:get_size() end)
    if oks and type(size) == "number" then
        for i = 0, size - 1 do
            local oke, e = pcall(function() return coll:get_element(i) end)
            if oke and fn(e, i) then return end
        end
    end
end

function R.count(coll)
    if coll == nil then return 0 end
    local ok, n = pcall(function() return coll:get_size() end)
    if ok and type(n) == "number" then return n end
    ok, n = pcall(function() return coll:call("get_Count") end)
    if ok and type(n) == "number" then return n end
    local c = 0
    R.each(coll, function() c = c + 1 end)
    return c
end

-- Numbers of a primitive array (UInt32[], Byte[]...). Elements come back boxed.
function R.numbers(arr)
    local out = {}
    R.each(arr, function(e, i) out[i + 1] = R.number(e) or 0 end)
    return out
end

local function to_i32(v)
    v = math.floor(v) & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

-- Writes arr[i] (0-based) for a UInt32[] / Int32[] / Byte[] array.
function R.set_number(arr, i, v, kind)
    local boxed
    local ok = pcall(function()
        if kind == "byte" then
            boxed = sdk.create_byte(math.floor(v) & 0xFF)
        elseif kind == "int32" then
            boxed = sdk.create_int32(to_i32(v))
        else
            boxed = sdk.create_uint32(to_i32(v))
        end
    end)
    if not ok or boxed == nil then return false end
    return (pcall(function() arr[i] = boxed end))
end

-- New engine objects are only used within the current call (stored straight into game data),
-- so the reference held by the Lua wrapper is enough.
function R.new_array(type_name, n)
    local ok, arr = pcall(sdk.create_managed_array, type_name, n)
    if ok and arr ~= nil then return arr end
    return nil
end

function R.new_instance(type_name)
    local ok, obj = pcall(sdk.create_instance, type_name)
    if ok and obj ~= nil then return obj end
    return nil
end

-------------------------------------------------------------------------------
-- GUIDs
-------------------------------------------------------------------------------

local GUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function norm_guid(s)
    if type(s) ~= "string" then return nil end
    s = s:lower():gsub("[{}]", "")
    if s:match(GUID_PATTERN) then return s end
    local hex = s:gsub("%-", "")
    if #hex == 32 and not hex:find("[^0-9a-f]") then
        return ("%s-%s-%s-%s-%s"):format(hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21, 32))
    end
    return nil
end
R.norm_guid = norm_guid

-- Canonical "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" from a System.Guid value (ValueType,
-- boxed object or string). Same text as Guid.ToString(), so it round-trips through Parse.
function R.guid_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return norm_guid(v) end
    local ok, s = pcall(function() return v:call("ToString()") end)
    if ok then
        local g = norm_guid(s)
        if g then return g end
    end
    -- Field layouts used by different runtimes.
    local layouts = {
        { "mData1", "mData2", "mData3", { "mData4_0", "mData4_1", "mData4_2", "mData4_3", "mData4_4", "mData4_5", "mData4_6", "mData4_7" } },
        { "_a", "_b", "_c", { "_d", "_e", "_f", "_g", "_h", "_i", "_j", "_k" } },
    }
    for _, l in ipairs(layouts) do
        local a, b, c = R.number(R.get(v, l[1])), R.number(R.get(v, l[2])), R.number(R.get(v, l[3]))
        if a and b and c then
            local bytes, okb = {}, true
            for i, n in ipairs(l[4]) do
                local x = R.number(R.get(v, n))
                if x == nil then okb = false break end
                bytes[i] = ("%02x"):format(x & 0xFF)
            end
            if okb then
                return ("%08x-%04x-%04x-%s%s-%s"):format(a & 0xFFFFFFFF, b & 0xFFFF, c & 0xFFFF,
                    bytes[1], bytes[2], table.concat(bytes, "", 3, 8))
            end
        end
    end
    -- Raw memory (ValueType wrapper).
    local okr, g = pcall(function()
        local a, b, c = v:read_dword(0), v:read_short(4), v:read_short(6)
        local bytes = {}
        for i = 0, 7 do bytes[#bytes + 1] = ("%02x"):format(v:read_byte(8 + i) & 0xFF) end
        return ("%08x-%04x-%04x-%s%s-%s"):format(a & 0xFFFFFFFF, b & 0xFFFF, c & 0xFFFF,
            bytes[1], bytes[2], table.concat(bytes, "", 3, 8))
    end)
    if okr then return norm_guid(g) end
    return nil
end

-- System.Guid value for a string (System.Guid.Parse), cached.
function R:guid_value(s)
    self.guid_cache = self.guid_cache or {}
    local cached = self.guid_cache[s]
    if cached ~= nil then return cached end
    local td = self:type("System.Guid")
    if td == nil then return nil end
    local m = nil
    pcall(function() m = td:get_method("Parse(System.String)") or td:get_method("Parse") end)
    if m == nil then return nil end
    local ok, v = pcall(m.call, m, nil, s)
    if not ok or v == nil then return nil end
    self.guid_cache[s] = v
    return v
end

-- GUID of a GameObject: its ToString() is "Name@<guid>]"-like in RE Engine.
function R.game_object_guid(go)
    if go == nil then return nil end
    local ok, s = pcall(function() return go:call("ToString()") end)
    if not ok or type(s) ~= "string" then return nil end
    local g = s:match("@([%x%-]+)%]") or s:match("([%x]+%-[%x]+%-[%x]+%-[%x]+%-[%x]+)")
    return norm_guid(g)
end

-------------------------------------------------------------------------------
-- Hook arguments
-------------------------------------------------------------------------------

function R.arg_obj(a)
    local ok, o = pcall(sdk.to_managed_object, a)
    return ok and o or nil
end

function R.arg_int(a)
    if type(a) == "number" then return math.floor(a) end
    local ok, v = pcall(sdk.to_int64, a)
    return ok and v or nil
end

function R.arg_i32(a)
    local v = R.arg_int(a)
    if v == nil then return nil end
    return to_i32(v)
end

function R.arg_bool(a)
    if type(a) == "boolean" then return a end
    local v = R.arg_int(a)
    return v ~= nil and (v & 0xFF) ~= 0
end

function R.arg_guid(a)
    if type(a) == "string" then return norm_guid(a) end
    local ok, vt = pcall(sdk.to_valuetype, a, "System.Guid")
    if ok and vt ~= nil then
        local g = R.guid_string(vt)
        if g ~= nil then return g end
    end
    return R.guid_string(a)
end

-- Installs a pre/post hook once per method. Returns true on success.
function R:hook(info, pre, post)
    if info == nil or info.method == nil then return false end
    local key = (info.owner or "?") .. "::" .. info.name .. "(" .. table.concat(info.params or {}, ",") .. ")"
    if self.hooked[key] then return true end
    local ok, err = pcall(sdk.hook, info.method, pre, post or function(retval) return retval end)
    if ok then
        self.hooked[key] = true
        return true
    end
    self.log("hook failed for " .. key .. ": " .. tostring(err))
    return false
end

R.to_i32 = to_i32
return R
