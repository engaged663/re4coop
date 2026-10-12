-- Level event triggers for both games.
--
-- RE4 starts its scripted events from InteractTriggers (docs/RESEARCH.md 3.11): an area the
-- player walks into (an InteractTriggerAreaHit) on a level GameObject whose components turn it
-- into an event - a portrayal (the game's scripted sequences: camera cuts, messages, sounds,
-- objects that move or hide, flags, cutscenes), a camera shot, a mini demo. Only the game of
-- the player who walked in runs it. This module makes the partner's game run the same event:
--
--   * the adapter reports each event trigger our player sets off (it filters out anything
--     that is not a pure event: doors, ladders, items, traps, deaths, saves, inventory...);
--   * the partner's game, if its player is near (same stage, within NEAR metres) or gets
--     there within WINDOW seconds, runs the same trigger with its own player, so the partner
--     sees the event happen and its game runs every consequence itself (a play-once trigger
--     is then done there and never runs twice);
--   * otherwise the trigger is left alone there: the flags and cutscene the event produced
--     arrive on their own, and the partner's game runs the rest of the event (objects that
--     move or hide, colliders, sounds...) itself when its player walks in - as it would
--     without the mod. Nothing that changes the level is ever skipped.
--
-- A trigger is identified by its GameObject's GUID (scene data, the same on both PCs) and the
-- hash of its name (what the game's own lookup uses).
--
-- Adapter contract (world):
--   world:trigger_run(ev) -> "run" | "done" | "missing" | "refused" | "failed"   (with our player;
--     "refused": not an event trigger in our game)

local TriggerSync = {}
TriggerSync.__index = TriggerSync

local NEAR = 40.0              -- metres: a partner this close runs the event too
local DEDUPE = 5.0             -- seconds: the same trigger from both sides is one event
local WINDOW = 20.0            -- seconds an event waits for us to be near and playable (cutscene, loading)
local WAIT = 0.5               -- seconds between checks while we are far or busy
local RETRY = 2.0              -- seconds between attempts while the trigger's area is not loaded here
local MAX_PENDING = 64

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function key_of(ev)
    return tostring(ev.guid) .. ":" .. tostring(ev.hash)
end
TriggerSync.key_of = key_of

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function TriggerSync.new(opts)
    local self = setmetatable({}, TriggerSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function TriggerSync:reset()
    self.pending = {}  -- partner events waiting: {ev, time, next_try}
    self.recent = {}   -- key -> time the trigger fired here (ours, or the partner's we ran)
    self.counters = { sent = 0, received = 0, run = 0, already_done = 0, dupes = 0, missed = 0, refused = 0,
        failed = 0, dropped = 0 }
end

function TriggerSync:enabled()
    return self.settings.sync_triggers ~= false
end

-- Our player set off an event trigger. ev = { guid, hash, trigger_type, once, head }
function TriggerSync:on_local_trigger(ev, now, loc)
    if not self:enabled() or ev == nil or ev.guid == nil or ev.hash == nil then return false end
    if loc == nil or loc.pos == nil then return false end -- where it happened decides who runs it
    local k = key_of(ev)
    local t = self.recent[k]
    if t ~= nil and now - t < DEDUPE then return false end
    self.recent[k] = now
    local msg = self.P.encode_trigger({ guid = ev.guid, hash = ev.hash, trigger_type = ev.trigger_type,
        once = ev.once, head = ev.head, chapter = loc.chapter, stage = loc.stage, pos = loc.pos })
    if msg == nil then return false end
    self.send(msg, true)
    self.counters.sent = self.counters.sent + 1
    return true
end

function TriggerSync:on_trigger(m, now)
    if not self:enabled() then return end
    self.counters.received = self.counters.received + 1
    local k = key_of(m)
    local t = self.recent[k]
    if t ~= nil and now - t < DEDUPE then
        self.counters.dupes = self.counters.dupes + 1 -- we set it off ourselves just now
        return
    end
    self.recent[k] = now
    if #self.pending >= MAX_PENDING then
        table.remove(self.pending, 1)
        self.counters.dropped = self.counters.dropped + 1
    end
    self.pending[#self.pending + 1] = { ev = m, time = now, next_try = now }
end

-- Whether our player stands where the partner set the trigger off.
local function near(ev, loc)
    if loc == nil or loc.pos == nil or ev.pos == nil then return false end
    if ev.stage ~= nil and ev.stage >= 0 and loc.stage ~= nil and loc.stage ~= ev.stage then return false end
    return dist(ev.pos, loc.pos) <= NEAR
end

-- Handles one waiting event; returns true when it is finished.
function TriggerSync:service(p, now, world, loc)
    local ev = p.ev
    if loc ~= nil and ev.chapter ~= nil and ev.chapter >= 0 and loc.chapter ~= nil and loc.chapter >= 0
        and loc.chapter ~= ev.chapter then
        self.counters.dropped = self.counters.dropped + 1
        return true -- another chapter: that trigger does not exist here
    end
    if now - p.time > WINDOW then
        -- We were not there in time: our game runs it itself if our player walks in.
        self.counters.missed = self.counters.missed + 1
        return true
    end
    if not near(ev, loc) or loc.loading or not loc.playable then
        p.next_try = now + WAIT
        return false
    end
    local r = world:trigger_run(ev)
    if r == "run" then
        self.counters.run = self.counters.run + 1
        self.recent[key_of(ev)] = now
        return true
    elseif r == "done" then
        self.counters.already_done = self.counters.already_done + 1
        return true
    elseif r == "refused" then
        self.counters.refused = self.counters.refused + 1
        return true
    elseif r == "failed" then
        self.counters.failed = self.counters.failed + 1
        return true
    end
    p.next_try = now + RETRY -- "missing": its area is not loaded here (yet)
    return false
end

-- loc = { chapter, stage, pos, loading, playable }
function TriggerSync:tick(now, world, loc)
    if #self.pending == 0 then return end
    if not self:enabled() then
        self.pending = {}
        return
    end
    local keep = {}
    for _, p in ipairs(self.pending) do
        if now < p.next_try or not self:service(p, now, world, loc) then
            keep[#keep + 1] = p
        end
    end
    self.pending = keep
    for k, t in pairs(self.recent) do
        if now - t > 60 then self.recent[k] = nil end
    end
end

function TriggerSync:on_message(m, now)
    if m.type == self.P.T.TRIGGER then
        self:on_trigger(m, now)
        return true
    end
    return false
end

function TriggerSync:summary()
    return { counters = self.counters, queued = #self.pending }
end

return TriggerSync
