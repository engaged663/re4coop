-- Mechanisms for both games: levers, big doors and their locks, valves and cranks, shelves,
-- gates, bridges, lifts, pushed carts - every object a player moves through an interaction.
--
-- A gimmick's interaction plays a scripted sequence in the player's game: the object moving,
-- the in-game camera shot, its sounds and flags (a portrayal: PortrayalSettings.call on the
-- gimmick). Only its saved state crossed (gimmick_sync), which an object already on the
-- partner's screen does not show until its area reloads: the partner saw the big door shut,
-- the shelf in the way, the cart still blocking the path (docs/RESEARCH.md 3.19).
--
-- Each game reports the sequences its gimmicks start and the objects its player pushed; the
-- partner's game plays the same sequence on the same object (the game's own call, without the
-- player who started it) and moves the pushed object the way the game does. A gimmick not
-- loaded in the partner's game gets its finished state when its area loads, as after loading
-- a save (initializeGimmick). Never twice: a sequence the partner's game already started
-- itself - both games reacting to the same story flag - is not played again, and what the
-- partner's report starts here is not reported back. Paired by GameObject GUID (scene data).
--
-- Adapter contract (world):
--   world:take_mechanism_events() -> { {guid, kind, key}, ... } | nil   (our game's, since the last call;
--                                       one started while our area loads is its setup, not a player's)
--   world:mechanism_apply({guid, kind, key}) -> "done" | "skip" | "missing"

local MechanismSync = {}
MechanismSync.__index = MechanismSync

local SAME = 15.0     -- seconds in which both games starting the same sequence is one sequence
local REPEAT = 1.0    -- the same sequence reported again within this is the same call
local RETRY = 0.5     -- seconds between attempts for an object not loaded here yet
local WAIT = 10.0     -- a partner's sequence waits this long for its object (an area streaming in)

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function MechanismSync.new(opts)
    local self = setmetatable({}, MechanismSync)
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function MechanismSync:reset()
    self.local_at = {}   -- "guid:kind:key" -> time our game started it
    self.pending = {}    -- { ev, since, next_try }: the partner's, waiting to be played here
    self.counters = { sent = 0, received = 0, applied = 0, skipped = 0, same = 0, missing = 0, loading = 0 }
end

function MechanismSync:enabled()
    return self.settings.sync_mechanisms ~= false
end

local function key_of(ev)
    return ("%s:%d:%d"):format(ev.guid, ev.kind or 0, ev.key or 0)
end

function MechanismSync:on_message(m, now)
    if m.type ~= self.P.T.MECHANISMS then return false end
    if not self:enabled() then return true end
    for _, ev in ipairs(m.mechs) do
        if ev.guid ~= nil then
            self.counters.received = self.counters.received + 1
            self.pending[#self.pending + 1] = { ev = ev, since = now, next_try = now }
        end
    end
    return true
end

-- ready: our game can play a sequence now (in game, not loading). loading: our area is loading.
function MechanismSync:tick(now, world, ready, loading)
    if not self:enabled() or world == nil then return end
    -- Ours, for the partner.
    local events = world.take_mechanism_events and world:take_mechanism_events() or nil
    if events ~= nil and #events > 0 and loading then
        self.counters.loading = self.counters.loading + #events -- the area setting itself up
    elseif events ~= nil and #events > 0 then
        local out = {}
        for _, ev in ipairs(events) do
            local k = key_of(ev)
            local t = self.local_at[k]
            if t == nil or now - t >= REPEAT then out[#out + 1] = ev end
            self.local_at[k] = now
        end
        if #out > 0 then
            for _, msg in ipairs(self.P.encode_mechanisms(out)) do self.send(msg, true) end
            self.counters.sent = self.counters.sent + #out
        end
    end
    for k, t in pairs(self.local_at) do
        if now - t > SAME then self.local_at[k] = nil end
    end
    -- The partner's, here.
    if #self.pending == 0 or not ready or world.mechanism_apply == nil then return end
    local keep = {}
    for _, p in ipairs(self.pending) do
        local t = self.local_at[key_of(p.ev)]
        if t ~= nil and now - t < SAME then
            self.counters.same = self.counters.same + 1 -- our game started it too
        elseif now - p.since > WAIT then
            self.counters.missing = self.counters.missing + 1 -- its area is not loaded here: saved state does it
        elseif now < p.next_try then
            keep[#keep + 1] = p
        else
            local r = world:mechanism_apply(p.ev)
            if r == "missing" then
                p.next_try = now + RETRY
                keep[#keep + 1] = p
            elseif r == "done" then
                self.counters.applied = self.counters.applied + 1
            else
                self.counters.skipped = self.counters.skipped + 1
            end
        end
    end
    self.pending = keep
end

function MechanismSync:summary()
    return { counters = self.counters, queued = #self.pending }
end

return MechanismSync
