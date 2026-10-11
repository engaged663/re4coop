-- Scene object synchronisation: breakables (crates, barrels, pots, bottles, windows, shoot
-- targets...) and animals (crows, chickens, fish, bats...). When one player breaks or
-- kills one, the same object breaks / dies in the partner's game, and it stays that way
-- for objects the partner only reaches later.
--
-- Objects are identified by their GameObject GUID, which comes from the level file and is
-- therefore the same on both PCs. Detection is by observation, so it does not depend on
-- which code path broke the object: an object whose state machine enters a terminal state
-- ("break", "dead"...) or that disappears from the scene near the player counts as
-- destroyed. A whole area unloading (many objects vanishing at once) does not.
--
-- Adapter contract (world):
--   world:objects_scan() -> { stage=<id|nil>, objects = { [guid] = { kind=<type name>,
--        pos={x,y,z}, routine=<int|nil>, terminal=<bool> } } } | nil
--   world:object_apply(guid, event, value) -> "done" | "missing" | "failed"

local ObjectSync = {}
ObjectSync.__index = ObjectSync

local SCAN_INTERVAL = 0.5
local NEAR = 40.0            -- metres: vanishing further away than this is an unload, not a break
local MASS_VANISH = 4        -- more objects than this vanishing in one scan = area unload
local ECHO_WINDOW = 10.0
local PENDING_LIFETIME = 1800.0
local MAX_RETRIES = 3
local MAX_HISTORY = 2000

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function ObjectSync.new(opts)
    local self = setmetatable({}, ObjectSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function ObjectSync:reset()
    self.prev = nil
    self.last_scan = -math.huge
    self.pending = {}        -- guid -> {event, value, time, tries}
    self.remote_applied = {} -- guid -> time
    self.history = {}        -- guid -> {event, value, time}: everything destroyed this session
    self.history_n = 0
    self.counters = { sent = 0, received = 0, applied = 0, pending = 0, failed = 0 }
end

function ObjectSync:enabled()
    return self.settings.sync_objects ~= false
end

function ObjectSync:remember(guid, event, value, now)
    if event ~= self.P.OBJECT_EVENT.DESTROYED then return end
    if self.history[guid] == nil then
        self.history_n = self.history_n + 1
        if self.history_n > MAX_HISTORY then
            -- Drop the oldest entry.
            local oldest, ot = nil, math.huge
            for g, h in pairs(self.history) do
                if h.time < ot then oldest, ot = g, h.time end
            end
            if oldest ~= nil then
                self.history[oldest] = nil
                self.history_n = self.history_n - 1
            end
        end
    end
    self.history[guid] = { event = event, value = value, time = now }
end

function ObjectSync:detect(now, snap, local_pos)
    local E = self.P.OBJECT_EVENT
    local events = {}
    local prev = self.prev
    if prev ~= nil and prev.stage == snap.stage then
        local vanished = {}
        for guid, o in pairs(prev.objects) do
            if snap.objects[guid] == nil and not o.terminal then
                vanished[#vanished + 1] = guid
            end
        end
        if #vanished <= MASS_VANISH and local_pos ~= nil then
            table.sort(vanished)
            for _, guid in ipairs(vanished) do
                local o = prev.objects[guid]
                if o.pos ~= nil and dist(o.pos, local_pos) <= NEAR then
                    events[#events + 1] = { guid = guid, event = E.DESTROYED, value = -1 }
                end
            end
        end
    end
    if prev ~= nil then
        local guids = {}
        for guid in pairs(snap.objects) do guids[#guids + 1] = guid end
        table.sort(guids)
        for _, guid in ipairs(guids) do
            local o, p = snap.objects[guid], prev.objects[guid]
            if p ~= nil then
                if o.terminal and not p.terminal then
                    events[#events + 1] = { guid = guid, event = E.DESTROYED, value = o.routine or -1 }
                elseif self.settings.sync_object_states and o.routine ~= nil and o.routine ~= p.routine
                    and not o.terminal then
                    events[#events + 1] = { guid = guid, event = E.ROUTINE, value = o.routine }
                end
            end
        end
    end
    -- Our own application of the partner's events is not news.
    local out = {}
    for _, ev in ipairs(events) do
        local t = self.remote_applied[ev.guid]
        if t == nil or now - t > ECHO_WINDOW then
            out[#out + 1] = ev
            self:remember(ev.guid, ev.event, ev.value, now)
        end
    end
    return out
end

function ObjectSync:apply(guid, ev, world, now)
    local result = world:object_apply(guid, ev.event, ev.value)
    if result == "done" then
        self.remote_applied[guid] = now
        self.counters.applied = self.counters.applied + 1
        return true
    elseif result == "missing" then
        return false
    end
    ev.tries = (ev.tries or 0) + 1
    if ev.tries >= MAX_RETRIES then
        self.counters.failed = self.counters.failed + 1
        self.remote_applied[guid] = now
        return true -- give up
    end
    return false
end

-- scan_anyway: scan even with object sync off (animal sync finds the animals in the scan).
function ObjectSync:tick(now, world, local_pos, scan_anyway)
    local enabled = self:enabled()
    if not enabled and not scan_anyway then return end
    if now - self.last_scan < SCAN_INTERVAL then return end
    self.last_scan = now
    local snap = world:objects_scan()
    if snap == nil or not enabled then
        self.prev = nil
        return
    end

    local events = self:detect(now, snap, local_pos)
    if #events > 0 then
        for _, msg in ipairs(self.P.encode_objects(events)) do
            self.send(msg, true)
        end
        self.counters.sent = self.counters.sent + #events
    end
    self.prev = snap

    -- Partner events for objects that were not loaded when they arrived.
    local n = 0
    for guid, ev in pairs(self.pending) do
        if now - ev.time > PENDING_LIFETIME then
            self.pending[guid] = nil
        elseif snap.objects[guid] ~= nil then
            if self:apply(guid, ev, world, now) then self.pending[guid] = nil end
        end
        if self.pending[guid] ~= nil then n = n + 1 end
    end
    self.counters.pending = n
    for guid, t in pairs(self.remote_applied) do
        if now - t > ECHO_WINDOW * 3 then self.remote_applied[guid] = nil end
    end
end

function ObjectSync:on_objects(m, now, world)
    if not self:enabled() then return end
    for _, ev in ipairs(m.events) do
        if ev.guid ~= nil then
            self.counters.received = self.counters.received + 1
            self:remember(ev.guid, ev.event, ev.value, now)
            local rec = { event = ev.event, value = ev.value, time = now, tries = 0 }
            if not self:apply(ev.guid, rec, world, now) then
                self.pending[ev.guid] = rec
            end
            -- The object vanishing / changing because of us must not be reported back.
            self.remote_applied[ev.guid] = now
        end
    end
end

-- An object died here because the partner's game killed it (animal sync applied it): the
-- next scan must not report it back.
function ObjectSync:note_applied(guid, now)
    self.remote_applied[guid] = now
    self:remember(guid, self.P.OBJECT_EVENT.DESTROYED, -1, now)
end

-- An object was destroyed here and must be reported now rather than on the next scans (an
-- animal our player killed while it followed the host's).
function ObjectSync:report_destroyed(guid, value, now)
    if not self:enabled() then return end
    local E = self.P.OBJECT_EVENT
    for _, msg in ipairs(self.P.encode_objects({ { guid = guid, event = E.DESTROYED, value = value or -1 } })) do
        self.send(msg, true)
    end
    self.counters.sent = self.counters.sent + 1
    self:remember(guid, E.DESTROYED, value or -1, now)
    -- Detection skips it like an event of the partner's we applied.
    self.remote_applied[guid] = now
end

-- Host: everything destroyed so far, for a joining client.
function ObjectSync:send_history()
    local events = {}
    for guid, h in pairs(self.history) do
        events[#events + 1] = { guid = guid, event = h.event, value = h.value }
    end
    table.sort(events, function(a, b) return a.guid < b.guid end)
    if #events > 0 then
        for _, msg in ipairs(self.P.encode_objects(events)) do
            self.send(msg, true)
        end
    end
    return #events
end

function ObjectSync:on_message(m, now, world)
    if m.type == self.P.T.OBJECTS then
        self:on_objects(m, now, world)
        return true
    end
    return false
end

function ObjectSync:summary()
    return { counters = self.counters, destroyed_known = self.history_n }
end

return ObjectSync
