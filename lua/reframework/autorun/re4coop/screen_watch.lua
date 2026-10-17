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
-- After a skipped cutscene (docs/RESEARCH.md 3.36) it also looks for a screen that stays black:
-- when, SKIP_STUCK seconds after the skip, the skipped camera is still there or a fade layer
-- (GUI included) has been dark for half that time without a break - with no transition and no
-- other camera running - it hands back a rescue: end the skipped cameras still there and lift
-- those layers.
--
-- tick(now, s) with s = {
--   transition = bool,           our game is between two moments of play
--   detail = function() -> {state, phase, jumper, saving}   (only called for the log)
--   playing = bool,              our player is in the game and alive
--   busy = bool,                 a cutscene/event or one of the game's cameras is running
--   dark = { fade types } | nil, the watched fades that are dark now
--   cameras = { {camera, id, skipped, play_id, address} } | nil, the game's cameras
--   dark_all = { fade types } | nil, every layer a skip can leave dark that is dark now
-- }
-- returns a list of fade types to lift now (possibly empty), and a rescue or nil:
-- { end_cameras = {play_id...}, lift = {fade type...}, what = "camera:id" }.

local ScreenWatch = {}
ScreenWatch.__index = ScreenWatch

ScreenWatch.BLACK_SECONDS = 10.0  -- dark this long in normal play, with nothing running: stuck
ScreenWatch.RETRY_SECONDS = 10.0  -- a lift that did not take is tried again after this
ScreenWatch.MAX_LIFTS = 3         -- per dark spell of one fade
ScreenWatch.LONG_TRANSITION = 45.0 -- a transition this long is written to the log (once)
ScreenWatch.SKIP_STUCK = 15.0     -- black (or the skipped camera still there) this long after a skip: stuck
ScreenWatch.SKIP_WATCH = 60.0     -- a skip is watched this long at most

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
    self.counters = { transitions = 0, long_transitions = 0, lifts = 0, skips_watched = 0, skip_rescues = 0 }
    return self
end

function ScreenWatch:reset()
    self.transition_since = nil
    self.transition_logged = false
    self.last_transition_end = nil
    self.dark_since = {}    -- fade type -> since when it is dark while it should not be
    self.lifts = {}         -- fade type -> { n, last }
    self.skip = nil         -- { since, what, dark = {type -> true} | nil, seen = {address -> true} }
    self.skips_seen = {}    -- address of a skipped camera -> true (each skip starts one watch)
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
        -- Inside a transition the black is the game's own (a skipped cutscene that ends a
        -- chapter goes on into one).
        self.dark_since = {}
        self.skip = nil
        return lift
    end
    if self.transition_since ~= nil then
        self.last_transition_end = now
        self.last_transition_length = now - self.transition_since
        self.transition_since = nil
    end
    local rescue = self:watch_skip(now, s)
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
        return lift, rescue
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
    return lift, rescue
end

local function sorted_keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- A skip is being watched, or one just started (cameras: the game's cameras now).
function ScreenWatch:watching_skip(cams)
    if self.skip ~= nil and not self.skip.done then return true end
    for _, c in ipairs(cams or {}) do
        if c.skipped then return true end
    end
    return false
end

-- A skip (a camera of the game's with DoneSkip) starts a watch; it ends when the screen is lit
-- and the skipped camera gone, when another camera starts or after SKIP_WATCH. Returns a rescue
-- once if the screen is still black (or the skipped camera still there) SKIP_STUCK seconds on.
function ScreenWatch:watch_skip(now, s)
    local cams = s.cameras or {}
    local live, skipped, other = {}, {}, false
    for _, c in ipairs(cams) do
        if c.address ~= nil then live[c.address] = true end
        if c.skipped then
            skipped[#skipped + 1] = c
            if c.address ~= nil and not self.skips_seen[c.address] then
                self.skips_seen[c.address] = true
                if self.skip == nil then
                    self.skip = { since = now, what = ("%s:%s"):format(tostring(c.camera), tostring(c.id)) }
                    self.counters.skips_watched = self.counters.skips_watched + 1
                end
            end
        else
            other = true
        end
    end
    for a in pairs(self.skips_seen) do
        if not live[a] then self.skips_seen[a] = nil end
    end
    local w = self.skip
    if w == nil or w.done then
        if w ~= nil and now - w.since > ScreenWatch.SKIP_WATCH then self.skip = nil end
        return nil
    end
    if other or now - w.since > ScreenWatch.SKIP_WATCH then
        self.skip = nil -- the next cutscene owns the screen now
        return nil
    end
    -- Since when each layer is dark (a skip fades the EVENT layer out for a moment by itself).
    local dark_now = {}
    for _, t in ipairs(s.dark_all or s.dark or {}) do dark_now[t] = true end
    w.dark_from = w.dark_from or {}
    for t in pairs(w.dark_from) do
        if not dark_now[t] then w.dark_from[t] = nil end
    end
    for t in pairs(dark_now) do w.dark_from[t] = w.dark_from[t] or now end
    if next(dark_now) == nil and #skipped == 0 and now - w.since >= 1.0 then
        w.done = true -- the picture came back and the camera is gone: a skip like any other
        return nil
    end
    if not self:enabled() or not s.playing or now - w.since < ScreenWatch.SKIP_STUCK then return nil end
    local stuck = {}
    for t, from in pairs(w.dark_from) do
        if now - from >= ScreenWatch.SKIP_STUCK / 2 then stuck[t] = true end
    end
    if next(stuck) == nil and #skipped == 0 then return nil end -- dark only for a moment: wait
    w.done = true
    local ends = {}
    for _, c in ipairs(skipped) do
        if c.play_id ~= nil then ends[#ends + 1] = c.play_id end
    end
    self.counters.skip_rescues = self.counters.skip_rescues + 1
    return { end_cameras = ends, lift = sorted_keys(stuck), what = w.what }
end

-- A rescue after a skip was carried out (report = the fade layers before it, for the log).
function ScreenWatch:rescued(r, now, report)
    local names = {}
    for _, t in ipairs(r.lift) do names[#names + 1] = FADE_NAMES[t] or tostring(t) end
    self.last_rescue = ("%s: ended %d camera(s), lifted %s"):format(r.what, #r.end_cameras,
        #names > 0 and table.concat(names, ", ") or "nothing")
    self.log("screen still black %.0f s after skipping cutscene %s (fades %s): %s", ScreenWatch.SKIP_STUCK, r.what,
        tostring(report), self.last_rescue)
    self.notify("The screen stayed black after a skipped cutscene - brought the picture back", "warn")
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
        last_rescue = self.last_rescue,
    }
end

return ScreenWatch
