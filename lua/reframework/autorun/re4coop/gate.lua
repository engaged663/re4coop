-- Transition gate (RE5/RE6 style): a player who reaches a story transition first waits
-- there until the partner arrives, so nobody is left behind in the previous area.
--
--   * Event gate: a cutscene/scripted event (GuiManager.get_IsPlayingEvent) that is still
--     running after `gate_grace` seconds holds the player, unless the partner is already in
--     an event nearby (anywhere, with cutscene sync: their game plays ours) or standing within
--     `gate_radius`. Short animations (doors, ladders,
--     pickups) end before the grace period and never hold anyone.
--   * Chapter gate: the player whose chapter (chainsaw.ChapterID, which also changes between
--     the parts of a chapter) moved ahead of the partner's waits at the start of the new one
--     until the partner gets there too. It only engages after both were in the same chapter
--     during this session, so joining from different saves never freezes anyone.
--
-- Holding is done by the caller (session.lua freezes the scene's time scale) and released
-- when the partner is ready, when the player presses the continue key, or when the partner
-- disconnects. Pure Lua, tested offline (tests/lua/test_gate.lua).
--
-- Never during our own transitions (s.transition: a chapter change, a game over, a load): the
-- game runs them on timers and on what it loads, so a frozen one never finishes - the screen
-- would stay black. The event our game plays as it comes out of one (the next part's first
-- cutscene) is the transition's own and is let through; the chapter gate takes care of
-- chapter starts.

local Gate = {}
Gate.__index = Gate

local READY_NEAR_SECONDS = 1.0 -- partner within gate_radius this long counts as arrived
local EVENT_RADIUS_FACTOR = 3  -- a partner's event counts if it is this many radii away at most
local AFTER_TRANSITION = 10.0  -- an event starting this soon after our transition belongs to it

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Gate.new(settings)
    local self = setmetatable({}, Gate)
    self.settings = settings or {}
    self:reset()
    return self
end

function Gate:reset()
    self.holding = nil          -- nil | "event" | "chapter"
    self.hold_since = nil
    self.event_start = nil
    self.event_decided = false  -- this event was already let through (or released)
    self.near_since = nil
    self.chapters_matched = false
    self.chapter_skipped = false
    self.last_release = nil     -- why the last hold ended (for the UI)
    self.transition_end = nil   -- when our last transition ended (its event is let through)
end

-- s = { connected, transition, in_game, event, chapter, stage, pos,
--       partner_fresh, partner_event, partner_chapter, partner_stage, partner_pos,
--       continue_pressed }
local function same_stage(s)
    return s.stage == nil or s.partner_stage == nil or s.stage == s.partner_stage
end

function Gate:partner_distance(s)
    if not s.partner_fresh or s.pos == nil or s.partner_pos == nil then return nil end
    return dist(s.pos, s.partner_pos)
end

-- Since when the partner has been standing within gate_radius (updated every tick).
function Gate:track_near(s, now)
    local d = self:partner_distance(s)
    if d ~= nil and d <= (self.settings.gate_radius or 10.0) and same_stage(s) then
        self.near_since = self.near_since or now
    else
        self.near_since = nil
    end
end

-- Partner close enough (or in the same event) to go through the transition together.
function Gate:partner_ready_for_event(s, now)
    local radius = self.settings.gate_radius or 10.0
    local d = self:partner_distance(s)
    if d == nil then return false end
    if s.partner_event and (d <= radius * EVENT_RADIUS_FACTOR or (s.stage ~= nil and s.stage == s.partner_stage)) then
        return true
    end
    -- With cutscene sync the partner's game plays our cutscene at once, wherever they are (and
    -- brings them over when it ends): in an event, they are watching it with us.
    if s.partner_event and self.settings.sync_cutscenes ~= false then return true end
    return self.near_since ~= nil and now - self.near_since >= READY_NEAR_SECONDS
end

function Gate:release(why)
    self.holding = nil
    self.hold_since = nil
    self.last_release = why
end

-- Returns the hold reason ("event" | "chapter") or nil.
function Gate:update(now, s)
    if self.settings.transition_gate == false or not s.connected then
        if self.holding ~= nil then self:release(s.connected and "gate switched off" or "partner disconnected") end
        if not s.connected then self.chapters_matched = false end
        self.event_start = nil
        return nil
    end

    self:track_near(s, now)

    if s.transition then
        if self.holding ~= nil then self:release("loading") end
        self.event_start = nil
        self.event_decided = false
        self.transition_end = now
        return nil
    end

    -- Chapter bookkeeping.
    if s.chapter ~= nil and s.partner_chapter ~= nil and s.partner_chapter == s.chapter then
        self.chapters_matched = true
        self.chapter_skipped = false
    end

    -- Event bookkeeping.
    if s.event then
        self.event_start = self.event_start or now
    else
        self.event_start = nil
        self.event_decided = false
        if self.holding == "event" then self:release("event ended") end
    end

    -- Release an active hold?
    if self.holding == "chapter" then
        if s.continue_pressed then
            self.chapter_skipped = true
            self:release("continued alone")
        elseif s.partner_chapter ~= nil and s.chapter ~= nil and s.partner_chapter >= s.chapter then
            self:release("partner arrived")
        end
    elseif self.holding == "event" then
        if s.continue_pressed then
            self:release("continued alone")
        elseif self:partner_ready_for_event(s, now) then
            self:release("partner arrived")
        end
    end
    if self.holding ~= nil then return self.holding end

    -- Start a hold?
    if s.in_game and self.chapters_matched and not self.chapter_skipped and s.chapter ~= nil
        and s.partner_chapter ~= nil and s.chapter > s.partner_chapter then
        self.holding, self.hold_since = "chapter", now
        return self.holding
    end
    local grace = self.settings.gate_grace or 1.5
    if s.event and not self.event_decided and now - self.event_start >= grace then
        self.event_decided = true
        local after_transition = self.transition_end ~= nil and self.event_start - self.transition_end <= AFTER_TRANSITION
        if not after_transition and not self:partner_ready_for_event(s, now) then
            self.holding, self.hold_since = "event", now
            return self.holding
        end
    end
    return nil
end

function Gate:summary(now)
    return {
        holding = self.holding,
        waited = self.hold_since and (now - self.hold_since) or nil,
        last_release = self.last_release,
    }
end

return Gate
