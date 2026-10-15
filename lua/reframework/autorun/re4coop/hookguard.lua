-- Every hook the mod installs goes through here (sdk.hook's stand-in).
--
-- REFramework hooks a method by patching its native body, and the game's compiler folds
-- identical bodies into one: a trivial "return false", "do nothing" or "return a field" body is
-- shared by thousands of methods (re4.exe 0x1400aea70, the body of System.Array.get_IsReadOnly,
-- is also 17,388 other methods' - among them EnemyHeadUpdater.isEnableStealthKill, which enemy
-- kinds without their own inherit). Hooking such a body sends every call of every one of
-- those methods, on every thread, through our Lua code under REFramework's script lock: the
-- game slows to a crawl (0.10.1, the client's puppet heads: 2 fps). Such a method has nothing
-- to hook anyway. So a method whose body is the body of one of a few well-known trivial
-- framework methods is refused (docs/RESEARCH.md 3.27).

local Guard = {}

-- Framework methods with the most shared trivial bodies of re4.exe (their names are stable
-- across builds; their bodies are what an inherited stub resolves to).
Guard.REFERENCES = {
    { "System.Action", "EndInvoke" },                          -- void, empty (59,967 methods)
    { "System.Array", "Insert" },                              -- 23,930
    { "System.Collections.BitArray.Enumerator", "Reset" },     -- 22,383
    { "System.Array", "get_IsReadOnly" },                      -- return false (17,388)
    { "System.Array", "CopyTo" },                              -- 11,164
    { "System.Action", "BeginInvoke" },                        -- 10,014
    { "System.Array", "get_IsFixedSize" },                     -- return true (8,023)
    { "System.Array", "get_SyncRoot" },                        -- return this (4,771)
    { "System.Type", "get_IsByRefLike" },                      -- 3,515
    { "System.ComponentModel.PropertyChangedEventArgs", "get_PropertyName" }, -- field getter (3,657)
    { "System.Collections.ArrayList", "get_Count" },           -- field getter (2,583)
    { "System.AsyncCallback", "Invoke" },                      -- 2,378
    { "System.Array", "Add" },                                 -- 2,001
    { "System.Collections.ArrayList", "get_Capacity" },        -- 1,959
    { "System.Reflection.MethodBase", "get_CallingConvention" }, -- return a constant
}

Guard.refused = {}  -- "Type.method" -> true
Guard.n_refused = 0
Guard.n_hooked = 0

local function function_of(m)
    local ok, fn = pcall(function() return m:get_function() end)
    if ok and fn ~= nil then return fn end
    return nil
end

-- A body's pointer as a table key (a number, or a light userdata REFramework may hand out).
local function key_of(fn)
    if type(fn) == "number" then return fn end
    if type(fn) == "userdata" then
        local ok, v = pcall(function() return sdk.to_int64(fn) end)
        if ok and type(v) == "number" and v ~= 0 then return v end
    end
    return tostring(fn)
end

local function label_of(m)
    local okN, name = pcall(function() return m:get_name() end)
    local okT, tname = pcall(function() return m:get_declaring_type():get_full_name() end)
    return (okT and tname or "?") .. "." .. (okN and name or "?")
end

-- The set of shared trivial bodies (built once; nil entries skipped).
function Guard.stubs()
    if Guard.stub_set ~= nil then return Guard.stub_set end
    local set = {}
    if type(sdk) == "table" and type(sdk.find_type_definition) == "function" then
        for _, r in ipairs(Guard.REFERENCES) do
            local okT, td = pcall(sdk.find_type_definition, r[1])
            local okM, m = pcall(function() return td and td:get_method(r[2]) end)
            local fn = okT and okM and m and function_of(m) or nil
            if fn ~= nil then set[key_of(fn)] = r[1] .. "." .. r[2] end
        end
    end
    -- Kept once found (the framework types exist from the start in the game; not yet in a
    -- test world that has no framework types).
    if next(set) ~= nil then Guard.stub_set = set end
    return set
end

-- Whether method `m`'s body is a shared trivial one (the framework method it is, or nil).
function Guard.shared_with(m)
    local fn = m and function_of(m)
    if fn == nil then return nil end
    return Guard.stubs()[key_of(fn)]
end

-- sdk.hook(m, pre, post), refused (an error) for a shared trivial body.
function Guard.hook(m, pre, post)
    local shared = Guard.shared_with(m)
    if shared ~= nil then
        local label = label_of(m)
        if not Guard.refused[label] then
            Guard.refused[label] = shared
            Guard.n_refused = Guard.n_refused + 1
        end
        error("refused: " .. label .. " has the shared body of " .. shared)
    end
    sdk.hook(m, pre, post)
    Guard.n_hooked = Guard.n_hooked + 1
end

-- For Diagnostics: { hooked, refused, names = { "Type.method (= System.X.y)", ... } }
function Guard.summary()
    local names = {}
    for label, shared in pairs(Guard.refused) do names[#names + 1] = label .. " (= " .. shared .. ")" end
    table.sort(names)
    return { hooked = Guard.n_hooked, refused = Guard.n_refused, names = names }
end

-- Tests: forget everything (a fresh mock world has other bodies).
function Guard.reset()
    Guard.stub_set = nil
    Guard.refused = {}
    Guard.n_refused = 0
    Guard.n_hooked = 0
end

return Guard
