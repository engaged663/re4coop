-- RE4 (2023) adapter: keep the world running while menus are open in a co-op session.
--
-- RE4 pauses through share.PauseManager. Each pause type has a PauseParameter
-- (TargetUpdate / TargetDraw flags) in a dictionary that says what that pause freezes.
--   * "safe" mode (default): while the session is active, the parameters of menu pauses
--     (inventory, map, files, pause menu, item pickup, typewriter, tutorials...) are set to
--     freeze nothing. The menus still open and close exactly as before; only the world keeps
--     going. Everything is restored when the session ends.
--   * "aggressive" mode: additionally refuses the pause requests themselves.
-- Which pauses are kept is decided by pause_policy.lua (cutscenes and loading are kept).

local R = require("re4coop.reflect")
local Policy = require("re4coop.pause_policy")

local Pause = {}
Pause.__index = Pause

local PM = "share.PauseManager"
local PAUSE_TYPE = "share.PauseManager.PauseType"
local CUSTOM_PAUSE = "chainsaw.PauseManagerCustom.CustomPause"
local REAPPLY_INTERVAL = 2.0

local STOP_WORDS = { "unpause", "resume", "end", "release", "cancel", "clear", "remove", "stop", "finish", "close" }

function Pause.new(game, log)
    local self = setmetatable({}, Pause)
    self.game = game
    self.log = log or function() end
    self.r = R.new(self.log)
    self.active = false
    self.mode = "menus"
    self.saved = {}         -- key -> {update, draw}
    self.names = {}         -- key -> enum name
    self.last_apply = -math.huge
    self.blocked = 0
    self:probe()
    return self
end

function Pause:cap(name, ok, detail)
    if self.game ~= nil and self.game.cap ~= nil then
        return self.game:cap(name, ok, detail)
    end
    return ok
end

function Pause:probe()
    local r = self.r
    self.dict_field = r:find_field(PM, function(i)
        return i.type:find("Dictionary", 1, true) ~= nil and i.type:find("PauseParameter", 1, true) ~= nil
    end)
    -- Keys: every PauseType and custom pause value, with its name.
    self.names = {}
    for v, name in pairs(r:enum(PAUSE_TYPE).values) do self.names[v] = name end
    for v, name in pairs(r:enum(CUSTOM_PAUSE).values) do
        if self.names[v] == nil then self.names[v] = name end
    end
    self.request_ms = r:find_methods(PM, function(i)
        local n = i.name:lower()
        if n:find("pause", 1, true) == nil or n:sub(1, 7) ~= "request" then return false end
        for _, w in ipairs(STOP_WORDS) do
            if n:find(w, 8, true) then return false end
        end
        return #i.params >= 1 and (i.params[1] == PAUSE_TYPE or i.params[1] == "System.UInt32")
    end)
    local n = 0
    for _ in pairs(self.names) do n = n + 1 end
    self:cap("no_pause", self.dict_field ~= nil and n > 0,
        self.dict_field and ("%s, %d pause types"):format(self.dict_field.name, n) or "PauseParameter table not found")
    self:cap("no_pause_requests", #self.request_ms > 0, ("%d request methods"):format(#self.request_ms))
end

function Pause:manager()
    return self.r:singleton(PM)
end

function Pause:name_of(key)
    return self.names[key] or ("#" .. tostring(key))
end

-- Visits every (key, PauseParameter) in the dictionary.
function Pause:each_param(fn)
    local mgr = self:manager()
    local dict = mgr and self.dict_field and R.get(mgr, self.dict_field.name)
    if dict == nil then return false end
    local seen = {}
    -- Known keys first (enum values), through the dictionary's own accessors.
    for key in pairs(self.names) do
        if R.call(dict, "ContainsKey", key) == true then
            local param = R.call(dict, "get_Item", key)
            if param ~= nil then
                seen[key] = true
                fn(key, param, dict)
            end
        end
    end
    -- Then any other entries (custom pauses registered at runtime).
    local entries = R.get(dict, "_entries", "entries", "mEntries")
    R.each(entries, function(e)
        local key = R.number(R.get(e, "key", "_key", "Key"))
        local hash = R.number(R.get(e, "hashCode", "_hashCode"))
        local param = R.get(e, "value", "_value", "Value")
        if key ~= nil and not seen[key] and param ~= nil and (hash == nil or hash >= 0) then
            seen[key] = true
            fn(key, param, dict)
        end
    end)
    return true
end

local function write_param(dict, key, param, update, draw)
    local ok1 = R.set(param, "TargetUpdate", update)
    local ok2 = R.set(param, "TargetDraw", draw)
    -- Struct values come back as copies: store them again.
    R.call(dict, "set_Item", key, param)
    return ok1 or ok2
end

function Pause:apply()
    local count = 0
    self:each_param(function(key, param, dict)
        local name = self:name_of(key)
        if Policy.neutralize(name, self.mode) then
            if self.saved[key] == nil then
                local u = R.number(R.get(param, "TargetUpdate"))
                local d = R.number(R.get(param, "TargetDraw"))
                if u ~= nil or d ~= nil then
                    self.saved[key] = { update = u or 0, draw = d or 0, name = name }
                end
            end
            if self.saved[key] ~= nil and write_param(dict, key, param, 0, 0) then
                count = count + 1
            end
        end
    end)
    self.patched = count
    return count
end

function Pause:restore()
    self:each_param(function(key, param, dict)
        local s = self.saved[key]
        if s ~= nil then write_param(dict, key, param, s.update, s.draw) end
    end)
    self.saved = {}
    self.patched = 0
end

function Pause:install_request_hooks()
    if self.hooks_installed then return end
    self.hooks_installed = true
    for _, info in ipairs(self.request_ms) do
        local base = info.static and 2 or 3
        self.r:hook(info, function(args)
            if not self.active or self.mode_requests ~= true then return end
            local key = R.arg_int(args[base])
            if key ~= nil and Policy.neutralize(self:name_of(key & 0xFFFFFFFF), self.mode) then
                self.blocked = self.blocked + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end)
    end
end

-- active: the co-op session is running. mode: "menus" | "all" | "off"; aggressive: also
-- refuse pause requests.
function Pause:set_active(active, mode, aggressive, now)
    mode = mode or "menus"
    if mode == "off" then active = false end
    if active and aggressive then self:install_request_hooks() end
    self.mode_requests = aggressive and true or false
    if active == self.active and mode == self.mode then return end
    if self.active then self:restore() end
    self.active = active
    self.mode = mode
    if active then
        local n = self:apply()
        self.last_apply = now or 0
        self.log(("no-pause on: %d pause types neutralised"):format(n))
    else
        self.log("no-pause off: pauses restored")
    end
end

-- The table can be rebuilt by the game (area loads); re-apply periodically while active.
function Pause:update(now)
    if not self.active then return end
    if now - self.last_apply >= REAPPLY_INTERVAL then
        self.last_apply = now
        self:apply()
    end
end

function Pause:status()
    local names = {}
    for _, s in pairs(self.saved) do names[#names + 1] = s.name end
    table.sort(names)
    return { active = self.active, mode = self.mode, patched = self.patched or 0, blocked = self.blocked, names = names }
end

return Pause
