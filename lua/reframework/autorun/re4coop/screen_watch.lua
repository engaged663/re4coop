-- Our game's transitions and the screen they leave black (docs/RESEARCH.md 3.33).
--
-- RE4 changes chapter (and part of a chapter: the bell in the village ends chapter 1-1) in a
-- game state of its own, GameStateInGameChapterChange, behind a black screen: it unloads the
-- area, sets the next chapter up, autosaves, loads the next part and only then hands the game
-- back (GameStateInGame) and lifts the black when the next part's first cutscene starts. A
-- game over and loading a save are such states too. Our player's context lives on through
-- them, so to the rest of the mod the game looked playable the whole time.
--
-- This module follows those transitions for the session (how long the current one has lasted,
-- one log line with what it is doing when it lasts too long) and watches the screen after them:
-- a transition or event fade (share.FadeManager) that stays dark while the game is back in
-- normal play, no camera of its own runs and our player is alive is lifted after BLACK_SECONDS,
-- the way the game lifts it at the end of a transition. Pure Lua, tested offline
-- (tests/lua/test_screen_watch.lua).
--
-- tick(now, s) with s = {
--   transition = bool,           our game is between two moments of play
--   detail = function() -> {state, phase, jumper, saving}   (only called for the log)
--   playing = bool,              our player is in the game and alive
--   busy = bool,                 a cutscene/event or one of the game's cameras is running
--   dark = { fade types } | nil, the watched fades that are dark now
-- }
-- returns a list of fade types to lift now (possibly empty).

local ScreenWatch = {}
ScreenWatch.__index = ScreenWatch

ScreenWatch.BLACK_SECONDS = 10.0  -- dark this long in normal play, with nothing running: stuck
ScreenWatch.RETRY_SECONDS = 10.0  -- a lift that did not take is tried again after this
ScreenWatch.MAX_LIFTS = 3         -- per dark spell of one fade
ScreenWatch.LONG_TRANSITION = 45.0 -- a transition this long is written to the log (once)

local FADE_NAMES = { [0] = "INTER_GAMESTATE", [1] = "GAMESTATE", [2] = "CAMPAIGN_JUMPER", [3] = "GUI",
    [4] = "EVENT", [5] = "TEXT_CHANGE", [6] = "GIMMICK", [7] = "CAMPAIGN_MANAGER" }
ScreenWatch.FADE_NAMES = FADE_NAMES

-- opts: { settings, log(fmt, ...), notify(text, kind) }
function ScreenWatch.new(opts)
    local self = setmetatable({}, ScreenWatch)
    opts = opts or {}
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
    self.notify = opts.notify or function() end
    self:reset()
    self.counters = { transitions = 0, long_transitions = 0, lifts = 0 }
    return self
end

function ScreenWatch:reset()
    self.transition_since = nil
    self.transition_logged = false
    self.last_transition_end = nil
    self.dark_since = {}    -- fade type -> since when it is dark while it should not be
    self.lifts = {}         -- fade type -> { n, last }
end

function ScreenWatch:enabled()
    return self.settings.fix_black_screen ~= false
end

local function describe(d)
    if d == nil then return "?" end
    local parts = { tostring(d.state or "?") }
    if d.phase ~= nil then parts[#parts + 1] = "phase " .. tostring(d.phase) end
    if d.jumper ~= nil then parts[#parts + 1] = "jumper phase " .. tostring(d.jumper) end
    if d.saving then parts[#parts + 1] = "saving" end
    return table.concat(parts, ", ")
end
ScreenWatch.describe = describe

function ScreenWatch:tick(now, s)
    local lift = {}
    if s.transition then
        if self.transition_since == nil then
            self.transition_since = now
            self.transition_logged = false
            self.counters.transitions = self.counters.transitions + 1
        elseif not self.transition_logged and now - self.transition_since >= ScreenWatch.LONG_TRANSITION then
            self.transition_logged = true
            self.counters.long_transitions = self.counters.long_transitions + 1
            local d = s.detail and s.detail() or nil
            self.last_detail = d
            self.log("game transition still running after %.0f s: %s", now - self.transition_since, describe(d))
        end
        -- Inside a transition the black is the game's own.
        self.dark_since = {}
        return lift
    end
    if self.transition_since ~= nil then
        self.last_transition_end = now
        self.last_transition_length = now - self.transition_since
        self.transition_since = nil
    end
    local dark = {}
    for _, t in ipairs(s.dark or {}) do dark[t] = true end
    -- Fades that came back on their own: a new spell starts from zero next time.
    for t in pairs(self.dark_since) do
        if not dark[t] then self.dark_since[t] = nil end
    end
    for t in pairs(self.lifts) do
        if not dark[t] then self.lifts[t] = nil end
    end
    if not self:enabled() or not s.playing or s.busy then
        self.dark_since = {}
        return lift
    end
    for t in pairs(dark) do
        local since = self.dark_since[t]
        if since == nil then
            self.dark_since[t] = now
        elseif now - since >= ScreenWatch.BLACK_SECONDS then
            local l = self.lifts[t] or { n = 0 }
            if l.n < ScreenWatch.MAX_LIFTS and (l.last == nil or now - l.last >= ScreenWatch.RETRY_SECONDS) then
                l.n, l.last = l.n + 1, now
                self.lifts[t] = l
                lift[#lift + 1] = t
            end
        end
    end
    table.sort(lift)
    return lift
end

-- The game lifted (or was asked to lift) these fades.
function ScreenWatch:lifted(types, now)
    if #types == 0 then return end
    self.counters.lifts = self.counters.lifts + #types
    local names = {}
    for _, t in ipairs(types) do names[#names + 1] = FADE_NAMES[t] or tostring(t) end
    self.log("screen still black %.0f s after the game went back to play: lifting %s", ScreenWatch.BLACK_SECONDS,
        table.concat(names, ", "))
    if self.lifts_noticed == nil or now - self.lifts_noticed > 60 then
        self.lifts_noticed = now
        self.notify("The screen stayed black after a transition - brought the picture back", "warn")
    end
end

function ScreenWatch:summary(now)
    return {
        counters = self.counters,
        transition_for = self.transition_since and (now - self.transition_since) or nil,
        last_transition_length = self.last_transition_length,
        last_detail = self.last_detail and describe(self.last_detail) or nil,
    }
end

return ScreenWatch
