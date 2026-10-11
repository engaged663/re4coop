-- RE4 (2023) adapter for world state: scenario flags, gimmick save states, breakables and
-- animals, cutscenes, location / warping / chapter switching. It implements the "world"
-- contracts of flag_sync, gimmick_sync, object_sync, cutscene_sync and travel. Like
-- game.lua (which it uses for the player context and the capability list), it is one of
-- the few modules that touch REFramework's `sdk`.
--
-- Status of what is used (see docs/RESEARCH.md for sources):
--   * Used in game by another published mod (RE4R-AP-Wizard): ScenarioFlagManager
--     requestSetFlag(System.Guid, System.Boolean) / checkFlag(System.Guid); the stage warp
--     (Prefecture/Location/EnvSceneManager.requestToChangeStatus + CharacterManager
--     .requestWarp with a StageIdentifier); PlayerContext.get_CurrentStageID;
--     CampaignManager.get_CurrentChapter and the chapter switch through
--     CampaignManager.loadGameSaveData; GameOverManager mediator requestGameOver; scene
--     findComponents and GameObject GUIDs.
--   * In this mod's own research dump (v0.5): GimmickManager.pushDirtyList (a gimmick
--     changed state, hooked in game.lua), CampaignManager.get_CurrentStageIdentifier.
--   * Found in the game's type database, method names probed at runtime by signature:
--     the setters to hook, save/load of the flag and gimmick tables, the timeline event
--     (cutscene) request methods, gimmick _Routine states.
-- Every lookup is cached and every engine call is pcall'ed; missing pieces switch the
-- corresponding feature off and show up in the Diagnostics panel.

local R = require("re4coop.reflect")
local P = require("re4coop.protocol")
local Perf = require("re4coop.perf")

local World = {}
World.__index = World

local SFM = "chainsaw.ScenarioFlagManager"
local GIM = "chainsaw.GimmickManager"
local TEM = "chainsaw.TimelineEventManager"
local TE_ID = "chainsaw.TimelineEventDefine.ID"
local CHARACTER_MANAGER = "chainsaw.CharacterManager"
local CAMPAIGN = "chainsaw.CampaignManager"
local GUI_MANAGER = "chainsaw.GuiManager"
local GAME_OVER = "chainsaw.GameOverManager"
local PREF_SCENE = "chainsaw.PrefectureSceneManager"
local LOC_SCENE = "chainsaw.LocationSceneManager"
local ENV_SCENE = "chainsaw.EnvSceneManager"
local CONTEXT_ID = "chainsaw.ContextID"

-- Breakables and animals whose destruction is synchronised.
World.OBJECT_TYPES = {
    "chainsaw.GmWoodBox", "chainsaw.GmSmoothWoodBox", "chainsaw.GmPhasedWoodBox", "chainsaw.GmSaveLoadWoodBox",
    "chainsaw.GmOilDrum", "chainsaw.GmBottle", "chainsaw.GmSimpleBreak", "chainsaw.GmBreakObj",
    "chainsaw.GmShootObj", "chainsaw.GmShootObj4DLC", "chainsaw.GmBlueCoin", "chainsaw.GmGlassBox",
    "chainsaw.GmWindowBreakable", "chainsaw.GmBreakWall", "chainsaw.GmBreakDoor", "chainsaw.GmFatBreak",
    "chainsaw.GmArmaBreak", "chainsaw.GmBreakFallenShelf", "chainsaw.GmLightBulb", "chainsaw.GmBreakableByEm",
    "chainsaw.GmCrow", "chainsaw.GmChicken", "chainsaw.GmFish", "chainsaw.GmAnimal", "chainsaw.GmBat",
    "chainsaw.GmBatGroup", "chainsaw.GmMouse", "chainsaw.GmCockroach", "chainsaw.GmSmokeBag",
}

-- Scenario flag setters worth hooking (lower case name -> "value": takes the new value as
-- its Boolean parameter, true/false: sets / clears the flag given only the GUID).
World.FLAG_SETTERS = {
    requestsetflag = "value", setflag = "value", requestflag = "value", setflagvalue = "value",
    requestsetflagvalue = "value", onflagchanged = "value", applyflag = "value", requestapplyflag = "value",
    setflagon = true, requestflagon = true, onsetflag = true,
    setflagoff = false, requestflagoff = false, resetflag = false, requestresetflag = false, clearflag = false,
}

local CUTSCENE_EXCLUDE = { "load", "release", "stop", "skip", "end", "cancel", "pause", "finish", "clear", "reset",
    "prepare", "ready", "standby", "preview", "debug", "test" }

-- Routine names (lower case prefixes) that mean "this object is finished" ("Break",
-- "BrokenWait", "Dead"...; not "WaitBreak").
local TERMINAL = { "break", "broken", "dead", "death", "die", "destroy", "crash", "shatter", "burst", "kill" }
local KILL_METHODS = { "requestBreak", "requestDead", "forceBreak", "forceDead", "breakObject", "requestDestroy",
    "onBreak", "dead", "setDead", "kill", "die" }

-- ChapterID -> CampaignJumper special jump sequence (main campaign), from RE4R-AP-Wizard.
World.CHAPTER_JUMP = {
    [21100] = 6, [21200] = 7, [21300] = 8, [22100] = 9, [22200] = 10, [22300] = 11,
    [23100] = 12, [23200] = 13, [23300] = 14, [24100] = 15, [24200] = 16, [24300] = 17,
    [25100] = 18, [25200] = 19, [25300] = 20, [25400] = 21,
}

local function lower(s) return tostring(s or ""):lower() end

local function ends_with(s, suffix)
    return s ~= nil and #s >= #suffix and s:sub(-#suffix) == suffix
end

local function starts_any(name, list)
    local n = lower(name)
    for _, p in ipairs(list) do
        if n:sub(1, #p) == p then return true end
    end
    return false
end

local function contains_any(name, list)
    local n = lower(name)
    for _, p in ipairs(list) do
        if n:find(p, 1, true) then return true end
    end
    return false
end

local function yaw_of(q)
    if q == nil then return 0 end
    local x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
    return math.atan(2 * (w * y + x * z), 1 - 2 * (x * x + y * y))
end

-- game: the core adapter (game.lua) for the player context and the capability list.
function World.new(game, log)
    local self = setmetatable({}, World)
    self.game = game
    self.log = log or function() end
    self.r = R.new(self.log)
    self.callbacks = {}      -- on_flag(guid, value), on_cutscene(id, method)
    self.applying = false
    self.dirty_seen = 0      -- game.gimmick_calls already reported by gimmicks_dirty()
    self.active = false      -- a partner is connected (set by the session)
    self.word_queue = {}     -- pending flag word changes (group -> word -> {set, clear})
    self.object_index = {}   -- guid -> {comp, go, info={field, enum}} from the latest scan
    self.comp_guid = {}      -- component address -> guid
    self.chapter_target = nil
    self:probe()
    return self
end

-- set_field, or set_native_field for fields the managed setter refuses (enum-typed fields).
function World:set_field_any(obj, type_name, field, value)
    if R.set(obj, field, value) and R.number(R.get(obj, field)) == value then return true end
    local td = self.r:type(type_name)
    return td ~= nil and (pcall(sdk.set_native_field, obj, td, field, value))
end

-- Live config (experimental switches live in the core adapter's settings).
function World:setting(key)
    local s = self.game and self.game.settings
    return s and s[key]
end

function World:perf()
    return (self.game and self.game.perf) or Perf.NULL
end

function World:crumb(step, detail, urgent)
    self:perf():crumb(step, detail, urgent)
end

-- The game reloaded: scanned components and half-read tables belong to the old scene.
function World:on_reload()
    self.object_index = {}
    self.comp_guid = {}
    self.comp_guid_n = 0
    self.gim_scan = nil
    self.object_scan = nil
    self.word_queue = {}
end

function World:cap(name, ok, detail)
    if self.game ~= nil and self.game.cap ~= nil then
        return self.game:cap(name, ok, detail)
    end
    return ok
end

-------------------------------------------------------------------------------
-- Probing
-------------------------------------------------------------------------------

local function params_are(info, list)
    if #info.params ~= #list then return false end
    for i, t in ipairs(list) do
        if info.params[i] ~= t then return false end
    end
    return true
end

local function ret_ends(info, suffix)
    return ends_with(info.ret, suffix)
end

function World:probe()
    local r = self.r
    -- Scenario flags.
    self.flag_set_m = r:find_method(SFM, function(i) return params_are(i, { "System.Guid", "System.Boolean" })
        and lower(i.name):find("flag") ~= nil and starts_any(i.name, { "request", "set" }) end,
        { "requestSetFlag", "setFlag" })
    self.flag_check_m = r:find_method(SFM, function(i) return params_are(i, { "System.Guid" })
        and i.ret == "System.Boolean" and starts_any(i.name, { "check", "is", "get" }) end,
        { "checkFlag", "isFlag", "getFlag" })
    -- Only names that clearly mean "this flag now has this value": a wrongly hooked method
    -- (a watcher, a lock...) would report flags that never changed.
    self.flag_hook_ms = r:find_methods(SFM, function(i)
        if #i.params < 1 or #i.params > 2 or i.params[1] ~= "System.Guid" then return false end
        if #i.params == 2 and i.params[2] ~= "System.Boolean" then return false end
        return World.FLAG_SETTERS[lower(i.name)] ~= nil and (#i.params == 2 or World.FLAG_SETTERS[lower(i.name)] ~= "value")
    end)
    self.flag_save_m = r:find_method(SFM, function(i) return #i.params == 0 and ret_ends(i, "ScenarioFlagManager.SaveData") end,
        { "saveGameSaveData", "createSaveData", "getSaveData", "makeSaveData" })
    self.flag_load_m = r:find_method(SFM, function(i) return #i.params == 1 and ends_with(i.params[1], "ScenarioFlagManager.SaveData") end,
        { "loadGameSaveData", "loadSaveData", "setSaveData", "applySaveData" })
    self:cap("flags", self.flag_set_m ~= nil and self.flag_check_m ~= nil,
        self.flag_set_m and (self.flag_set_m.name .. " / " .. (self.flag_check_m and self.flag_check_m.name or "no check")) or "no setter")
    self:cap("flag_words", self.flag_save_m ~= nil and self.flag_load_m ~= nil,
        self.flag_save_m and (self.flag_save_m.name .. " / " .. (self.flag_load_m and self.flag_load_m.name or "no load")) or "no save/load")

    -- Gimmick save table.
    self.gim_save_m = r:find_method(GIM, function(i) return #i.params == 0 and ret_ends(i, "GimmickManager.SaveData") end,
        { "saveGameSaveData", "createSaveData", "getSaveData" })
    self.gim_load_m = r:find_method(GIM, function(i) return #i.params == 1 and ends_with(i.params[1], "GimmickManager.SaveData") end,
        { "loadGameSaveData", "loadSaveData", "setSaveData" })
    self:cap("gimmicks", self.gim_save_m ~= nil and self.gim_load_m ~= nil,
        self.gim_save_m and (self.gim_save_m.name .. " / " .. (self.gim_load_m and self.gim_load_m.name or "no load")) or "no save/load")

    -- Breakables / animals present in this game build.
    self.object_types = {}
    for _, name in ipairs(World.OBJECT_TYPES) do
        if r:type(name) ~= nil then self.object_types[#self.object_types + 1] = name end
    end
    self:cap("objects", #self.object_types > 0, ("%d object types"):format(#self.object_types))

    -- Cutscenes.
    local function has_event_param(i)
        for _, p in ipairs(i.params) do
            if p == TE_ID then return true end
        end
        return false
    end
    -- Requests that start playback. Preloads, stops, skips and queries must not count: a
    -- hooked preload would make the partner play the cutscene before it happens.
    self.cs_hook_ms = r:find_methods(TEM, function(i)
        local n = lower(i.name)
        return has_event_param(i) and (n:find("play", 1, true) or n:find("start", 1, true))
            and not contains_any(n, CUTSCENE_EXCLUDE) and not starts_any(n, { "is", "get", "check", "has", "can" })
    end)
    local simple = { [TE_ID] = true, ["System.Boolean"] = true, ["System.Int32"] = true, ["System.UInt32"] = true,
        ["System.Single"] = true }
    self.cs_play_ms = {}
    for _, i in ipairs(self.cs_hook_ms) do
        local ok = true
        for _, p in ipairs(i.params) do
            if not simple[p] then ok = false break end
        end
        if ok then self.cs_play_ms[#self.cs_play_ms + 1] = i end
    end
    table.sort(self.cs_play_ms, function(a, b)
        local pa = lower(a.name):find("requestplay") and 0 or 1
        local pb = lower(b.name):find("requestplay") and 0 or 1
        if pa ~= pb then return pa < pb end
        if #a.params ~= #b.params then return #a.params < #b.params end
        return a.name < b.name
    end)
    self.cs_current = r:find_method(TEM, function(i) return #i.params == 0 and i.ret == TE_ID and starts_any(i.name, { "get_" }) end,
        { "get_CurrentEventID", "get_PlayingEventID", "get_CurrentID", "get_PlayingID" })
    self.cs_current_field = self.cs_current == nil and r:find_field(TEM, function(i) return i.type == TE_ID end) or nil
    self:cap("cutscenes", #self.cs_play_ms > 0,
        #self.cs_play_ms > 0 and (self.cs_play_ms[1].name .. (" (%d hooks)"):format(#self.cs_hook_ms)) or "no play method")

    -- Travel.
    self.warp_m = r:find_method(CHARACTER_MANAGER, function(i) return i.name == "requestWarp" and #i.params == 4 end)
    self:cap("warp", self.warp_m ~= nil and r:type("chainsaw.StageIdentifier") ~= nil,
        self.warp_m and "CharacterManager.requestWarp + stage preload" or "fallback: transform teleport")
    self.load_save_m = r:find_method(CAMPAIGN, function(i) return i.name == "loadGameSaveData" and #i.params == 1 end)
    self:cap("chapter_switch", self.load_save_m ~= nil,
        self.load_save_m and "CampaignManager.loadGameSaveData" or "not found")
end

function World:install_hooks(callbacks)
    self.callbacks = callbacks or {}
    local r = self.r
    local installed = 0

    -- Flag setters: report local changes.
    for _, info in ipairs(self.flag_hook_ms or {}) do
        local base = info.static and 2 or 3
        local kind = World.FLAG_SETTERS[lower(info.name)]
        local implied = kind ~= false
        local nparams = #info.params
        local ok = r:hook(info, function(args)
            -- Cheap checks first: this runs for every flag the game sets.
            if self.applying or not self.active then return end
            local cb = self.callbacks.on_flag
            if cb == nil or not self:flag_hook_budget() then return end
            local guid = R.arg_guid(args[base])
            if guid == nil then return end
            local value = implied
            if nparams == 2 then value = R.arg_bool(args[base + 1]) end
            pcall(cb, guid, value)
        end)
        if ok then installed = installed + 1 end
    end
    self.flag_hooks = installed > 0
    self:cap("flag_hooks", self.flag_hooks, ("%d setter hooks"):format(installed))

    -- Cutscene requests: report local starts.
    local cs = 0
    for _, info in ipairs(self.cs_hook_ms or {}) do
        local base = info.static and 2 or 3
        local idx
        for k, p in ipairs(info.params) do
            if p == TE_ID then idx = k break end
        end
        local ok = r:hook(info, function(args)
            if self.applying then return end
            local cb = self.callbacks.on_cutscene
            if cb == nil then return end
            local id = R.arg_i32(args[base + idx - 1])
            if id ~= nil then pcall(cb, id, info.name) end
        end)
        if ok then cs = cs + 1 end
    end
    self:cap("cutscene_hooks", cs > 0, ("%d request hooks"):format(cs))

    -- Chapter switch: rewrite the chapter of the next save load when armed.
    if self.load_save_m ~= nil then
        local base = self.load_save_m.static and 2 or 3
        r:hook(self.load_save_m, function(args)
            local chapter = self.chapter_target
            if chapter == nil then return end
            self.chapter_target = nil
            local data = R.arg_obj(args[base])
            local init = data and R.get(data, "_InitialSettings")
            if init == nil then
                self.log("chapter switch: save data has no _InitialSettings")
                return
            end
            if R.number(R.get(init, "_Chapter")) == chapter then
                return -- the save is already in that chapter: keep its own checkpoint
            end
            local ok1 = self:set_field_any(init, "chainsaw.CampaignInitialSetting", "_Chapter", chapter)
            local jump = World.CHAPTER_JUMP[chapter]
            if jump ~= nil then
                self:set_field_any(init, "chainsaw.CampaignInitialSetting", "_SpecialJumpSequence", jump)
            end
            self.log(("chapter switch applied: %d (%s)"):format(chapter, tostring(ok1)))
        end)
    end
end

-------------------------------------------------------------------------------
-- Scenario flags
-------------------------------------------------------------------------------

function World:flag_mgr()
    return self.r:singleton(SFM)
end

function World:flag_set(guid, value)
    local m, mgr = self.flag_set_m, self:flag_mgr()
    if m == nil or mgr == nil then return false end
    local g = self.r:guid_value(guid)
    if g == nil then return false end
    self:crumb("world.flag_set", guid)
    self.applying = true
    local ok = pcall(m.method.call, m.method, mgr, g, value and true or false)
    self.applying = false
    return ok
end

function World:flag_check(guid)
    local m, mgr = self.flag_check_m, self:flag_mgr()
    if m == nil or mgr == nil then return nil end
    local g = self.r:guid_value(guid)
    if g == nil then return nil end
    local ok, v = pcall(m.method.call, m.method, mgr, g)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- Sync is running (a partner is connected): the hooks only do work while it is.
function World:set_active(on)
    self.active = on and true or false
end

function World:now()
    local clock = self.game and self.game.clock
    return clock and clock() or os.clock()
end

-- Some games re-set flags every frame. If the setter hooks fire more than FLAG_HOOK_BUDGET
-- times in a second, they stop reading arguments for a while and the word diffs (which
-- see only real changes) take over, so the frame rate never pays for it.
local FLAG_HOOK_BUDGET = 400
local FLAG_HOOK_PAUSE = 5.0

function World:flag_hook_budget()
    local t = self:now()
    if t < (self.flag_overflow_until or -math.huge) then return false end
    if t - (self.flag_window or -math.huge) >= 1.0 then
        self.flag_window, self.flag_calls = t, 0
    end
    self.flag_calls = self.flag_calls + 1
    if self.flag_calls > FLAG_HOOK_BUDGET then
        self.flag_overflow_until = t + FLAG_HOOK_PAUSE
        self.flag_overflows = (self.flag_overflows or 0) + 1
        self:cap("flag_hooks", true, ("setters busy (%d/s): word diffs for %ds"):format(FLAG_HOOK_BUDGET, FLAG_HOOK_PAUSE))
        return false
    end
    return true
end

-- Whether every flag change arrives through the hooks (else flag_sync diffs the words).
function World:flag_hooks_active()
    return self.flag_hooks == true and self:now() >= (self.flag_overflow_until or -math.huge)
end

function World:flag_save_data()
    local m, mgr = self.flag_save_m, self:flag_mgr()
    if m == nil or mgr == nil or self.flag_load_m == nil then return nil end
    local ok, sd = pcall(m.method.call, m.method, mgr)
    if ok then return sd end
    return nil
end

function World:flag_words_snapshot()
    local sd = self:flag_save_data()
    if sd == nil then return nil end
    local out, n = {}, 0
    R.each(R.get(sd, "Datas"), function(g)
        local name = R.string(R.get(g, "GroupName"))
        if name ~= nil then
            out[name] = R.numbers(R.get(g, "Flags"))
            n = n + 1
        end
    end)
    if n == 0 then return nil end
    return out
end

-- Rewrites groups in a fresh save object and loads it back. changes(name, words_array, current)
-- returns true if it modified the array.
-- Reloading the whole flag table while playing is experimental (exp_table_reload); the
-- complete copy a joining client takes over (full = true) is always allowed.
function World:flag_rewrite(edit, full)
    if not full and self:setting("exp_table_reload") ~= true then
        self.table_reloads_skipped = (self.table_reloads_skipped or 0) + 1
        return false
    end
    local sd = self:flag_save_data()
    if sd == nil then return false end
    local changed = false
    R.each(R.get(sd, "Datas"), function(g)
        local name = R.string(R.get(g, "GroupName"))
        local arr = R.get(g, "Flags")
        if name ~= nil and arr ~= nil and edit(name, arr, R.numbers(arr)) then changed = true end
    end)
    if not changed then return true end
    self:crumb("world.flag_table_reload", full and "full" or "delta", true)
    self.applying = true
    local ok = pcall(self.flag_load_m.method.call, self.flag_load_m.method, self:flag_mgr(), sd)
    self.applying = false
    return ok
end

function World:flag_words_apply_full(groups)
    local by_name = {}
    for _, g in ipairs(groups) do by_name[g.name] = g.words end
    return self:flag_rewrite(function(name, arr, cur)
        local target = by_name[name]
        if target == nil then return false end
        local changed = false
        for i, w in pairs(target) do
            if i <= #cur and cur[i] ~= w then
                if R.set_number(arr, i - 1, w) then changed = true end
            end
        end
        return changed
    end, true)
end

-- Queued; applied together by World:update().
function World:flag_words_apply(group, word, set, clear)
    local g = self.word_queue[group]
    if g == nil then
        g = {}
        self.word_queue[group] = g
    end
    local c = g[word] or { set = 0, clear = 0 }
    c.set = (c.set | set) & ~clear
    c.clear = (c.clear | clear) & ~set
    g[word] = c
    return true
end

function World:update()
    if next(self.word_queue) == nil then return end
    local queue = self.word_queue
    self.word_queue = {}
    self:flag_rewrite(function(name, arr, cur)
        local g = queue[name]
        if g == nil then return false end
        local changed = false
        for word, c in pairs(g) do
            local old = cur[word + 1]
            if old ~= nil then
                local new = (old | c.set) & ~c.clear
                if new ~= old and R.set_number(arr, word, new) then changed = true end
            end
        end
        return changed
    end)
end

-------------------------------------------------------------------------------
-- Gimmick save table
-------------------------------------------------------------------------------

function World:read_ctx(id)
    if id == nil then return nil end
    local cat = R.number(R.get(id, "_Category"))
    local kind = R.number(R.get(id, "_Kind"))
    local group = R.number(R.get(id, "_Group"))
    local index = R.number(R.get(id, "_Index"))
    if cat == nil or group == nil or index == nil then return nil end
    return { category = cat, kind = kind or 0, group = group, index = index }
end

function World:gim_save_data()
    local mgr = self.r:singleton(GIM)
    if mgr == nil or self.gim_save_m == nil or self.gim_load_m == nil then return nil, nil end
    local ok, sd = pcall(self.gim_save_m.method.call, self.gim_save_m.method, mgr)
    if ok and sd ~= nil then return sd, mgr end
    return nil, nil
end

local function bytes_of(arr)
    local out = {}
    for i, v in ipairs(R.numbers(arr)) do out[i] = string.char(v & 0xFF) end
    return table.concat(out)
end

function World:read_gimmick(item)
    local ctx = self:read_ctx(R.get(item, "ID"))
    local data = R.get(item, "SaveData")
    if ctx == nil or data == nil then return nil end
    local out = { ctx = ctx, attr = bytes_of(R.get(data, "Attr")), triggers = {}, acc = {},
        detected = R.get(data, "IsDetected") == true }
    R.each(R.get(data, "TriggerSave"), function(t)
        out.triggers[#out.triggers + 1] = { id = R.number(R.get(t, "SaveID")) or 0, done = R.number(R.get(t, "Done")) or 0 }
    end)
    R.each(R.get(data, "AccDatas"), function(a)
        local tn = R.type_name(a) or ""
        local v = R.number(R.get(a, "Value")) or 0
        out.acc[#out.acc + 1] = { kind = tn:find("Float") and 1 or 2, value = v }
    end)
    return out
end

local GIMMICKS_PER_CALL = 40   -- items fully read per call
local GIMMICK_IDS_PER_CALL = 150 -- items whose ID is checked per call (targeted reads)

-- The table can hold hundreds of gimmicks; reading it all in one frame would hitch, so scans
-- run over several calls and return the table when done (nil until then).
--   force = read everything now (one-off full copies);
--   keys  = { [ctx_key] = true }: read only those gimmicks (the ones that announced a change).
-- The table itself comes from GimmickManager's save method, which builds a fresh copy: that
-- is done once per scan, not per call.
function World:gimmicks_snapshot(force, keys)
    local scan = self.gim_scan
    if scan ~= nil and scan.keys ~= keys then scan = nil end -- a different kind of scan was running
    if scan == nil then
        local sd = self:gim_save_data()
        if sd == nil then return nil end
        local items = {}
        R.each(R.get(sd, "Datas"), function(item) items[#items + 1] = item end)
        scan = { sd = sd, items = items, next = 1, out = {}, keys = keys }
        self.gim_scan = scan
        self:perf():crumb("world.gimmick_scan", keys and "targeted" or "full")
    end
    local per_call = keys and GIMMICK_IDS_PER_CALL or GIMMICKS_PER_CALL
    local last = force and #scan.items or math.min(#scan.items, scan.next + per_call - 1)
    for i = scan.next, last do
        local item = scan.items[i]
        if keys ~= nil then
            local key = P.ctx_key(self:read_ctx(R.get(item, "ID")))
            if key ~= nil and keys[key] then
                local g = self:read_gimmick(item)
                if g ~= nil then scan.out[key] = g end
            end
        else
            local g = self:read_gimmick(item)
            if g ~= nil then scan.out[P.ctx_key(g.ctx)] = g end
        end
    end
    scan.next = last + 1
    if scan.next <= #scan.items then return nil end
    self.gim_scan = nil
    return scan.out
end

function World:write_gimmick(data, item)
    -- Attr bytes: rewrite in place when the size matches, else a new array.
    local attr = R.get(data, "Attr")
    local n = #item.attr
    if attr == nil or R.count(attr) ~= n then
        attr = R.new_array("System.Byte", n)
        if attr == nil then return false end
        R.set(data, "Attr", attr)
    end
    for i = 1, n do
        R.set_number(attr, i - 1, item.attr:byte(i), "byte")
    end
    -- Triggers that already fired.
    local trig = R.new_array("chainsaw.GimmickContext.TriggerDone", #item.triggers)
    if trig ~= nil then
        for i, t in ipairs(item.triggers) do
            local td = R.new_instance("chainsaw.GimmickContext.TriggerDone")
            if td ~= nil then
                R.set(td, "SaveID", t.id)
                R.set(td, "Done", t.done)
                pcall(function() trig[i - 1] = td end)
            end
        end
        R.set(data, "TriggerSave", trig)
    end
    R.set(data, "IsDetected", item.detected and true or false)
    -- Accessory values.
    local acc = R.new_array("chainsaw.GimmickContext.AccessoryData", #item.acc)
    if acc ~= nil then
        for i, a in ipairs(item.acc) do
            local obj = R.new_instance(a.kind == 1 and "chainsaw.GimmickContext.AccessoryDataFloat"
                or "chainsaw.GimmickContext.AccessoryDataUint")
            if obj ~= nil then
                R.set(obj, "Value", a.value)
                pcall(function() acc[i - 1] = obj end)
            end
        end
        R.set(data, "AccDatas", acc)
    end
    return true
end

function World:new_ctx_value(ctx)
    local id = R.new_instance(CONTEXT_ID)
    if id == nil then return nil end
    R.set(id, "_Category", ctx.category)
    R.set(id, "_Kind", ctx.kind)
    R.set(id, "_Group", ctx.group)
    R.set(id, "_Index", ctx.index)
    return id
end

function World:gimmicks_apply(items)
    self.gim_scan = nil -- a scan in progress would read the old states
    -- Not while the game is loading or playing a cutscene: the table is being rebuilt then.
    local loc = self:location()
    if loc == nil or loc.loading or loc.cutscene then return nil end -- not now: keep the queue
    local sd, mgr = self:gim_save_data()
    if sd == nil then return false end
    local list = R.get(sd, "Datas")
    if list == nil then return false end
    local existing = {}
    R.each(list, function(item)
        local ctx = self:read_ctx(R.get(item, "ID"))
        if ctx ~= nil then existing[P.ctx_key(ctx)] = item end
    end)
    for _, it in ipairs(items) do
        local key = P.ctx_key(it.ctx)
        local item = existing[key]
        if item == nil then
            item = R.new_instance("chainsaw.GimmickManager.SaveItem")
            local data = R.new_instance("chainsaw.GimmickContext.SaveData")
            local id = self:new_ctx_value(it.ctx)
            if item ~= nil and data ~= nil and id ~= nil then
                R.set(item, "ID", id)
                R.set(item, "SaveData", data)
                if R.call(list, "Add", item) == nil then
                    pcall(function() list:call("Add(chainsaw.GimmickManager.SaveItem)", item) end)
                end
            else
                item = nil
            end
        end
        local data = item and R.get(item, "SaveData")
        if data ~= nil then self:write_gimmick(data, it) end
    end
    self:crumb("world.gimmick_table_reload", ("%d items"):format(#items), true)
    self.applying = true
    local ok = pcall(self.gim_load_m.method.call, self.gim_load_m.method, mgr, sd)
    self.applying = false
    return ok
end

-- True once after GimmickManager.pushDirtyList ran (game.lua hooks it and counts the
-- calls): a gimmick changed state, so the save table is worth reading again right away.
function World:gimmicks_dirty()
    local n = self.game and self.game.gimmick_calls or 0
    if n ~= self.dirty_seen then
        self.dirty_seen = n
        return true
    end
    return false
end

-- The gimmicks that announced a change since the last call ({ [ctx_key] = true }), or nil when
-- the hook cannot tell which ones.
function World:gimmick_dirty_keys()
    if self.game == nil or self.game.take_gimmick_dirty_keys == nil then return nil end
    return self.game:take_gimmick_dirty_keys()
end

-------------------------------------------------------------------------------
-- Breakables and animals
-------------------------------------------------------------------------------

function World:scene()
    local ok, scene = pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local td = sdk.find_type_definition("via.SceneManager")
        return sdk.call_native_func(sm, td, "get_CurrentScene")
    end)
    if ok then return scene end
    return nil
end

local function position_of(go)
    local tf = R.call(go, "get_Transform")
    local p = tf and R.call(tf, "get_Position")
    if p == nil then return nil end
    return { x = p.x, y = p.y, z = p.z }
end

function World:routine_info(type_name)
    self.routine_cache = self.routine_cache or {}
    local c = self.routine_cache[type_name]
    if c == nil then
        local f = self.r:find_field(type_name, function(i) return i.name == "_Routine" end, 4)
        c = { field = f ~= nil, enum = f and self.r:enum(f.type) or nil }
        self.routine_cache[type_name] = c
    end
    return c
end

local function is_terminal(name)
    return name ~= nil and starts_any(name, TERMINAL)
end

-- One scene-wide search per object type is not free, and there are ~30 types: each call
-- refreshes OBJECT_TYPES_PER_SCAN types and keeps the others from their last search, so a
-- full round takes a few scans. Returns the merged snapshot.
local OBJECT_TYPES_PER_SCAN = 4

function World:objects_scan()
    local scene = self:scene()
    if scene == nil or #self.object_types == 0 then return nil end
    self.comp_guid_n = (self.comp_guid_n or 0) + 1
    if self.comp_guid_n > 2000 then
        -- Components come and go with areas; addresses can be reused. Start afresh now and then.
        self.comp_guid = {}
        self.comp_guid_n = 0
    end
    local scan = self.object_scan
    if scan == nil then
        scan = { next = 1, by_type = {} } -- type name -> { objects = {guid -> obj}, index = {guid -> entry} }
        self.object_scan = scan
    end
    local n = #self.object_types
    local count = scan.complete and math.min(OBJECT_TYPES_PER_SCAN, n) or n -- the first round reads all
    for _ = 1, count do
        local tname = self.object_types[scan.next]
        scan.next = scan.next % n + 1
        if scan.next == 1 then scan.complete = true end
        local objects, index = {}, {}
        local t = self.r:typeof(tname)
        local comps = t and (R.call(scene, "findComponents(System.Type)", t) or R.call(scene, "findComponents", t))
        R.each(comps, function(comp)
            local okaddr, addr = pcall(function() return comp:get_address() end)
            local cached = okaddr and self.comp_guid[addr] or nil
            local go = R.call(comp, "get_GameObject")
            local okg, go_addr = pcall(function() return go:get_address() end)
            go_addr = okg and go_addr or nil
            local guid
            if cached ~= nil and go_addr ~= nil and cached.go_addr == go_addr then
                guid = cached.guid -- the same object as before (the address was not reused)
            else
                guid = R.game_object_guid(go)
                if okaddr and guid then self.comp_guid[addr] = { guid = guid, go_addr = go_addr } end
            end
            if guid ~= nil and objects[guid] == nil then
                local info = self:routine_info(R.type_name(comp) or tname)
                local routine = info.field and R.number(R.get(comp, "_Routine")) or nil
                local rname = routine and info.enum and info.enum.values[routine] or nil
                objects[guid] = { kind = tname, pos = position_of(go), routine = routine, terminal = is_terminal(rname) }
                index[guid] = { comp = comp, go = go, info = info }
            end
        end)
        scan.by_type[tname] = { objects = objects, index = index }
    end
    local objects, index = {}, {}
    for _, t in pairs(scan.by_type) do
        for guid, o in pairs(t.objects) do objects[guid] = o end
        for guid, e in pairs(t.index) do index[guid] = e end
    end
    self.object_index = index
    local loc = self:location()
    return { stage = loc and loc.stage or nil, objects = objects }
end

-- A scanned component is used again only while its GameObject still exists.
function World:object_alive(o)
    if o == nil or o.go == nil then return false end
    if self.game ~= nil and self.game.go_alive ~= nil then return self.game:go_alive(o.go) end
    return true
end

function World:object_apply(guid, event, value)
    local o = self.object_index[guid]
    if o == nil or not self:object_alive(o) then return "missing" end
    local E = P.OBJECT_EVENT
    self:crumb("world.object_apply", o.info and R.type_name(o.comp) or guid, true)
    self.applying = true
    local result = "failed"
    -- Forcing an object's state machine into another state is experimental (exp_force_routine).
    local force_routine = self:setting("exp_force_routine") == true
    if event == E.ROUTINE then
        if force_routine and o.info.field and R.set(o.comp, "_Routine", value) then result = "done" end
    elseif event == E.DESTROYED then
        -- 1) The same terminal state the partner's copy reached (plays its own break/death).
        if force_routine and value ~= nil and value >= 0 and o.info.field and R.set(o.comp, "_Routine", value) then
            result = "done"
        end
        -- 2) A break / kill method of the object.
        if result ~= "done" then
            local tname = R.type_name(o.comp)
            for _, mname in ipairs(KILL_METHODS) do
                local info = tname and self.r:find_method(tname, function(i) return i.name == mname and #i.params == 0 end, nil, 3)
                if info ~= nil and pcall(info.method.call, info.method, o.comp) then
                    result = "done"
                    break
                end
            end
        end
        -- 3) Last resort: hide it.
        if result ~= "done" and o.go ~= nil then
            local ok1 = pcall(function() o.go:call("set_DrawSelf", false) end)
            local ok2 = pcall(function() o.go:call("set_UpdateSelf", false) end)
            if ok1 or ok2 then result = "done" end
        end
    end
    self.applying = false
    return result
end

-------------------------------------------------------------------------------
-- Cutscenes
-------------------------------------------------------------------------------

function World:cutscene_playing()
    local gui = self.r:singleton(GUI_MANAGER)
    if gui == nil or R.call(gui, "get_IsPlayingEvent") ~= true then return nil end
    local mgr = self.r:singleton(TEM)
    if mgr ~= nil then
        local id
        if self.cs_current ~= nil then
            local ok, v = pcall(self.cs_current.method.call, self.cs_current.method, mgr)
            id = ok and R.number(v) or nil
        elseif self.cs_current_field ~= nil then
            id = R.number(R.get(mgr, self.cs_current_field.name))
        end
        if id ~= nil and id > 0 then return id end
    end
    return true
end

function World:cutscene_play(id, method)
    local mgr = self.r:singleton(TEM)
    if mgr == nil or #self.cs_play_ms == 0 then return false end
    self:crumb("world.cutscene_play", tostring(id), true)
    local candidates = {}
    for _, i in ipairs(self.cs_play_ms) do
        if i.name == method then table.insert(candidates, 1, i) else candidates[#candidates + 1] = i end
    end
    for _, info in ipairs(candidates) do
        local args = {}
        for k, p in ipairs(info.params) do
            if p == TE_ID then args[k] = id
            elseif p == "System.Boolean" then args[k] = false
            else args[k] = 0 end
        end
        self.applying = true
        local ok = pcall(info.method.call, info.method, info.static and nil or mgr, table.unpack(args, 1, #info.params))
        self.applying = false
        if ok then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Location, warp, chapter switch
-------------------------------------------------------------------------------

function World:location()
    local ctx = self.game and self.game:player_context()
    local campaign = self.r:singleton(CAMPAIGN)
    local chapter = campaign and R.number(R.call(campaign, "get_CurrentChapter")) or nil
    if ctx == nil then
        -- Loading screen or menus: report the chapter if the campaign knows it.
        if chapter ~= nil and chapter > 0 then
            return { chapter = chapter, loading = true, playable = false }
        end
        return nil
    end
    local pos = R.call(ctx, "get_Position")
    if pos == nil then return nil end
    local stage = R.number(R.call(ctx, "get_CurrentStageID"))
    local body = R.call(ctx, "get_BodyGameObject")
    local tf = body and R.call(body, "get_Transform")
    local rot = tf and R.call(tf, "get_Rotation")
    local cutscene = self.game:is_cutscene()
    return { chapter = chapter, stage = stage, pos = { x = pos.x, y = pos.y, z = pos.z }, yaw = yaw_of(rot),
        loading = false, playable = not cutscene, cutscene = cutscene }
end

local function split_stage(stage)
    local pref = math.floor(stage / 1000)
    return pref, pref * 1000
end

-- A System.Nullable`1<inner> value with a value, as a real struct (REFramework ValueType):
-- passing a boxed object where the game expects a Nullable hands it garbage. set(vt, field)
-- writes the value into the struct's value field. nil if the type or its fields are unknown.
function World:make_nullable(inner, set)
    if ValueType == nil or ValueType.new == nil then return nil end
    local tname = "System.Nullable`1<" .. inner .. ">"
    local td = self.r:type(tname)
    if td == nil then return nil end
    local has_f, val_f
    for _, f in ipairs(self.r:fields(tname, 0)) do
        if not f.static then
            if f.type == "System.Boolean" then has_f = f.name elseif f.type == inner then val_f = f.name end
        end
    end
    if has_f == nil or val_f == nil then return nil end
    local ok, vt = pcall(ValueType.new, td)
    if not ok or vt == nil then return nil end
    if not pcall(vt.set_field, vt, has_f, true) or not pcall(set, vt, val_f) then return nil end
    return vt
end

-- Cross-stage warps (preloading the partner's stage and CharacterManager.requestWarp) are
-- experimental (stage_travel): without them, travelling moves the player directly.
function World:stage_warp_enabled()
    return self:setting("stage_travel") == true and self.warp_m ~= nil
end

-- Keeps the stage's scenes requested so the warp lands in a loaded area.
function World:preload_stage(stage)
    if stage == nil or stage < 0 or not self:stage_warp_enabled() then return false end
    local pref, loc = split_stage(stage)
    local pm, lm, em = self.r:singleton(PREF_SCENE), self.r:singleton(LOC_SCENE), self.r:singleton(ENV_SCENE)
    if pm == nil or lm == nil or em == nil then return false end
    local status = self:make_nullable("chainsaw.EnvSceneStatus", function(vt, f) vt:set_field(f, 3) end)
    if status == nil then
        self:cap("warp", false, "cannot build Nullable<EnvSceneStatus>: stage preload off")
        return false
    end
    self:crumb("world.preload_stage", tostring(stage), true)
    local ok = pcall(function()
        pm:call("requestToChangeStatus(chainsaw.PrefectureID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)", pref, status, 1)
        lm:call("requestToChangeStatus(chainsaw.LocID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)", loc, status, 1)
        em:call("requestToChangeStatus(chainsaw.StageID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)", stage, status, 1)
    end)
    return ok
end

function World:warp(stage, pos, yaw)
    if stage ~= nil and stage >= 0 and self:stage_warp_enabled() then
        local cm = self.r:singleton(CHARACTER_MANAGER)
        local ctx = self.game:player_context()
        local npos = self:make_nullable("via.vec3", function(vt, f) vt:set_field(f, Vector3f.new(pos.x, pos.y, pos.z)) end)
        local h = (yaw or 0) * 0.5
        local nrot = self:make_nullable("via.Quaternion", function(vt, f)
            vt:set_field(f, Quaternion.new(math.cos(h), 0.0, math.sin(h), 0.0))
        end)
        if cm ~= nil and ctx ~= nil and npos ~= nil and nrot ~= nil then
            local pref, loc = split_stage(stage)
            self:crumb("world.warp", tostring(stage), true)
            local ok = pcall(function()
                local sid = sdk.create_instance("chainsaw.StageIdentifier")
                sid:call("setup(chainsaw.LocID, chainsaw.StageID, chainsaw.AreaID)", loc, stage, 0)
                cm:call("requestWarp(chainsaw.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>, chainsaw.StageIdentifier)",
                    ctx:get_field("_ID"), npos, nrot, sid)
            end)
            if ok then return true end
        end
    end
    -- Same area, no stage information or no stage warp: move the player directly (pos is
    -- already the landing spot next to the partner).
    local ctx = self.game:player_context()
    local body = ctx and R.call(ctx, "get_BodyGameObject")
    if body == nil then return false end
    return (self.game:warp_game_object(body, pos))
end

function World:arm_chapter_switch(chapter)
    if self.load_save_m == nil then return false end
    self.chapter_target = chapter
    return true
end

function World:disarm_chapter_switch()
    self.chapter_target = nil
end

-- Game over -> the player picks Continue -> the checkpoint load runs through
-- CampaignManager.loadGameSaveData, which the armed chapter switch redirects.
function World:trigger_reload()
    if self:setting("travel_reload") ~= true then return false end
    local gom = self.r:singleton(GAME_OVER)
    local mediator = gom and R.call(gom, "get_Mediator")
    if mediator == nil then return false end
    self:crumb("world.trigger_reload", nil, true)
    local ok = pcall(function()
        local req = sdk.create_instance("chainsaw.GameOverRequest")
        mediator:call("requestGameOver", req)
    end)
    return ok
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

World.DUMP_TYPES = { SFM, GIM, TEM, CAMPAIGN, CHARACTER_MANAGER, GAME_OVER, PREF_SCENE, LOC_SCENE, ENV_SCENE,
    "share.PauseManager", "chainsaw.PauseManagerCustom", "chainsaw.TimerManager", "chainsaw.GimmickContext",
    "chainsaw.GimmickCore", "chainsaw.GmBase", "chainsaw.GmWoodBox", "chainsaw.GmCrow", "chainsaw.GmDoor",
    "chainsaw.TimelineEventPlayer", "chainsaw.TimelineEventSensor", "chainsaw.PurposeManager", "chainsaw.MapManager",
    "chainsaw.CharacterSpawnController", "chainsaw.CharacterSpawnPointController", "chainsaw.EnemyManager",
    "chainsaw.InteractManager", "chainsaw.MovieManager" }

return World
