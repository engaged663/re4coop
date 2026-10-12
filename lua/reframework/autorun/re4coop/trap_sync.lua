-- Traps for both games: bear traps and sensor bombs.
--
-- A trap goes off in one game only: the player (or an enemy) who steps into a bear trap, the
-- shot that snaps it shut or sets off a sensor bomb, the villager who opens a trap again - all
-- of it happens where it happened. The shared gimmick state (gimmick_sync) carries what is
-- saved, but a trap already on the partner's screen does not react to it: the bear trap stays
-- open, the bomb stays armed (docs/RESEARCH.md 3.18).
--
-- Each game watches the traps near its player and reports what changed:
--   * a bear trap that closed (it bit someone, was shot shut) - the partner's snaps shut with
--     the game's own closing (sound, animation, saved as closed); one opened again by a
--     villager opens again;
--   * a sensor bomb that went off (shot, or someone crossed its laser) - the partner's goes off
--     through its own state machine (explosion, damage around it, then gone).
-- A trap not loaded in the partner's game yet gets it when its area loads (FIRED then plays
-- as it would, so a far bomb is set off when the partner arrives: SPENT is used instead once a
-- report is old). A partner who joins gets every trap already closed or gone (SPENT: set
-- without playing it). Traps are paired by GameObject GUID (scene data, the same on both PCs).
--
-- Adapter contract (world):
--   world:traps_near(pos, radius) -> { [guid] = { kind, state } } | nil
--       state: "open" | "closed" (bear trap), "armed" | "gone" (sensor bomb), "hidden"
--   world:traps_all() -> { [guid] = { kind, state } } | nil       (every trap loaded)
--   world:trap_apply(guid, kind, event) -> "done" | "skip" | "missing"

local TrapSync = {}
TrapSync.__index = TrapSync

local RADIUS = 60.0          -- metres around our player whose traps we watch
local INTERVAL = 0.2         -- seconds between looks at them
local RETRY = 1.0            -- seconds between attempts for a trap not loaded here yet
local PENDING_KEEP = 1800.0  -- a partner's trap waits this long for its area to load here
local LIVE_FOR = 20.0        -- a report older than this is applied without playing it (SPENT)
local ECHO = 5.0             -- seconds in which our trap doing what the partner's did is not reported back

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function TrapSync.new(opts)
    local self = setmetatable({}, TrapSync)
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

-- A new partner: what they know of our traps starts over, and they get every spent trap.
function TrapSync:reset()
    self.seen = {}      -- guid -> state last seen here
    self.pending = {}   -- guid -> { kind, event, time, next_try }: partner traps not loaded here yet
    self.expect = {}    -- guid -> { state, till }: what applying the partner's report makes ours do
    self.snapshot_due = true
    self.last = -math.huge
    self.counters = { sent = 0, received = 0, applied = 0, skipped = 0, missing = 0 }
end

function TrapSync:enabled()
    return self.settings.sync_traps ~= false
end

local function fired_state(kind, P)
    return kind == P.TRAP_KIND.SENSOR_BOMB and "gone" or "closed"
end

local function idle_state(kind, P)
    return kind == P.TRAP_KIND.SENSOR_BOMB and "armed" or "open"
end

function TrapSync:apply(world, guid, kind, event, time, now)
    if event == self.P.TRAP_EVENT.FIRED and now - time > LIVE_FOR then event = self.P.TRAP_EVENT.SPENT end
    local r = world:trap_apply(guid, kind, event)
    if r == "missing" then
        local p = self.pending[guid]
        self.pending[guid] = { kind = kind, event = event, time = p and p.time or time, next_try = now + RETRY }
        return false
    end
    self.pending[guid] = nil
    if r == "done" then
        self.counters.applied = self.counters.applied + 1
        local state = event == self.P.TRAP_EVENT.REARMED and idle_state(kind, self.P) or fired_state(kind, self.P)
        self.expect[guid] = { state = state, till = now + ECHO }
    else
        self.counters.skipped = self.counters.skipped + 1
    end
    return true
end

function TrapSync:on_message(m, now, world)
    if m.type ~= self.P.T.TRAPS then return false end
    if not self:enabled() or world == nil or world.trap_apply == nil then return true end
    for _, t in ipairs(m.traps) do
        if t.guid ~= nil then
            self.counters.received = self.counters.received + 1
            self:apply(world, t.guid, t.kind, t.event, now, now)
        end
    end
    return true
end

-- What changed in trap `guid` (state `st.state`, last seen `prev`): the event to report, or nil.
function TrapSync:event_for(guid, st, prev, now)
    local P = self.P
    local e = self.expect[guid]
    if e ~= nil then
        if now > e.till then
            self.expect[guid] = nil
        elseif e.state == st.state then
            self.expect[guid] = nil
            return nil -- the partner's report doing its work here
        end
    end
    if prev == nil then return nil end
    if st.kind == P.TRAP_KIND.LEG_HOLD then
        if prev == "open" and st.state == "closed" then return P.TRAP_EVENT.FIRED end
        if prev == "closed" and st.state == "open" then return P.TRAP_EVENT.REARMED end
    elseif st.kind == P.TRAP_KIND.SENSOR_BOMB then
        if prev == "armed" and st.state == "gone" then return P.TRAP_EVENT.FIRED end
    end
    return nil
end

-- pos = our player's position.
function TrapSync:tick(now, world, pos)
    if not self:enabled() or world == nil or world.traps_near == nil then return end
    for guid, p in pairs(self.pending) do
        if now - p.time > PENDING_KEEP then
            self.pending[guid] = nil
            self.counters.missing = self.counters.missing + 1
        elseif now >= p.next_try then
            self:apply(world, guid, p.kind, p.event, p.time, now)
        end
    end
    if now - self.last < INTERVAL or pos == nil then return end
    self.last = now
    local out = {}
    if self.snapshot_due and world.traps_all ~= nil then
        -- A new partner: every trap of ours already closed or gone, set in their game as is.
        local all = world:traps_all()
        if all ~= nil then
            self.snapshot_due = false
            for guid, st in pairs(all) do
                if st.state == fired_state(st.kind, self.P) then
                    out[#out + 1] = { guid = guid, kind = st.kind, event = self.P.TRAP_EVENT.SPENT }
                end
                self.seen[guid] = st.state
            end
        end
    end
    local near = world:traps_near(pos, RADIUS)
    if near ~= nil then
        for guid, st in pairs(near) do
            local ev = self:event_for(guid, st, self.seen[guid], now)
            if ev ~= nil then out[#out + 1] = { guid = guid, kind = st.kind, event = ev } end
            if st.state ~= "hidden" then self.seen[guid] = st.state end
        end
    end
    if #out == 0 then return end
    table.sort(out, function(a, b) return a.guid < b.guid end)
    for _, msg in ipairs(self.P.encode_traps(out)) do self.send(msg, true) end
    self.counters.sent = self.counters.sent + #out
end

function TrapSync:summary()
    local queued = 0
    for _ in pairs(self.pending) do queued = queued + 1 end
    return { counters = self.counters, queued = queued }
end

return TrapSync
