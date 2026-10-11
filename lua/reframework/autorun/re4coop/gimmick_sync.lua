-- Gimmick state synchronisation: doors, locks, key slots, levers, shutters, puzzles...
--
-- RE4 keeps every gimmick's persistent state in chainsaw.GimmickManager, keyed by the
-- gimmick's ContextID (the save table is what the game writes to save files, so its keys
-- come from the level data and are the same on both PCs): an attribute byte array, the
-- triggers that already fired (a key was used, a switch was pulled) and a few accessory
-- values. This module keeps those records equal on both machines:
--   * each side diffs its records when a gimmick announces a change (pushDirtyList) and
--     every couple of seconds anyway, and sends the ones that changed;
--   * the host is the referee: it applies the client's changes and re-broadcasts the result,
--     so if both changed the same gimmick at once, both end up with the host's version;
--   * a joining client gets the host's complete table.
--
-- Adapter contract (world):
--   world:gimmicks_snapshot(force) -> { [ctx_key] = item } | nil
--       (nil = not available, or still reading a large table over several frames; force =
--       read everything now)
--       item = { ctx={category,kind,group,index}, attr="<bytes>", triggers={{id,done},...},
--                detected=bool, acc={{kind=1|2, value},...} }
--   world:gimmicks_apply(items) -> bool   (items = array of item)
--   world:gimmicks_dirty() -> bool         (optional: a gimmick changed state since the last call)

local GimmickSync = {}
GimmickSync.__index = GimmickSync

local INTERVAL = 2.0
local DIRTY_DELAY = 0.2     -- after a pushDirtyList, let the gimmick finish updating its save state
local MIN_INTERVAL = 0.3
local FULL_TIMEOUT = 20.0
local APPLY_INTERVAL = 0.5
local MAX_ADDED = 16        -- more new records than this in one scan = an area loaded, not a change

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function GimmickSync.new(opts)
    local self = setmetatable({}, GimmickSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function GimmickSync:reset()
    self.baseline = nil      -- ctx_key -> hash of our last snapshot
    self.items = {}          -- ctx_key -> item of our last snapshot
    self.expect = {}         -- ctx_key -> hash we are about to reach because of a remote change
    self.queue = {}          -- ctx_key -> item waiting to be applied
    self.queued = 0
    self.last_scan = -math.huge
    self.last_apply = -math.huge
    self.parts = {}          -- sync_id -> reassembly
    self.dirty_at = nil       -- when a gimmick last announced a state change
    self.announced = false    -- a change was announced since the last scan
    self.has_signal = false   -- the game adapter reports announced changes (pushDirtyList hook)
    self.pending_added = {}   -- partner's new records received before our first scan
    self.counters = { sent = 0, received = 0, applied = 0, full_applied = 0, full_sent = 0, scans = 0 }
end

function GimmickSync:enabled()
    return self.settings.sync_gimmicks ~= false
end

-- Canonical string of an item's state (ContextID excluded).
function GimmickSync.hash(item)
    local parts = { item.attr or "", item.detected and "1" or "0" }
    for _, t in ipairs(item.triggers or {}) do
        parts[#parts + 1] = ("%d=%d"):format(t.id or 0, t.done or 0)
    end
    for _, a in ipairs(item.acc or {}) do
        if a.kind == 1 then
            parts[#parts + 1] = ("f%.4f"):format(a.value or 0)
        else
            parts[#parts + 1] = ("u%d"):format(math.floor(a.value or 0))
        end
    end
    return table.concat(parts, "|")
end

local function by_key(P)
    return function(a, b) return P.ctx_key(a.ctx) < P.ctx_key(b.ctx) end
end

function GimmickSync:scan(now, world)
    local snap = world:gimmicks_snapshot()
    if snap == nil then return false end
    local hashes, changed, added = {}, {}, {}
    for key, item in pairs(snap) do
        local h = GimmickSync.hash(item)
        hashes[key] = h
        local before = self.baseline and self.baseline[key]
        if self.expect[key] == h then
            self.expect[key] = nil -- the state we applied for the partner
        elseif before ~= nil and before ~= h then
            changed[#changed + 1] = item
        elseif before == nil and self.baseline ~= nil then
            added[#added + 1] = item
        end
    end
    self.baseline = hashes
    self.items = snap
    if #changed > 0 then
        table.sort(changed, by_key(self.P))
        for _, msg in ipairs(self.P.encode_gimmicks(0, self.P.GIMMICK_MODE.DELTA, changed)) do
            self.send(msg, true)
        end
        self.counters.sent = self.counters.sent + #changed
    end
    -- New records: a gimmick that keeps no record until its first change (sent when the game
    -- announced a change), or gimmicks of an area that just loaded (many at once: not sent).
    -- The partner only adds them where it has no record of its own, so nothing regresses.
    local announced = self.announced or not self.has_signal
    self.announced = false
    if #added > 0 and #added <= MAX_ADDED and announced then
        table.sort(added, by_key(self.P))
        for _, msg in ipairs(self.P.encode_gimmicks(0, self.P.GIMMICK_MODE.ADDED, added)) do
            self.send(msg, true)
        end
        self.counters.sent = self.counters.sent + #added
    end
    -- Records that arrived before we had read our own table.
    if #self.pending_added > 0 then
        local pending = self.pending_added
        self.pending_added = {}
        self:enqueue_added(pending)
    end
    return true
end

-- Host: the whole table for a joining client.
function GimmickSync:send_full(sync_id, world)
    local snap = world:gimmicks_snapshot(true)
    if snap == nil then return 0 end
    local items = {}
    for _, item in pairs(snap) do items[#items + 1] = item end
    table.sort(items, function(a, b) return self.P.ctx_key(a.ctx) < self.P.ctx_key(b.ctx) end)
    for _, msg in ipairs(self.P.encode_gimmicks(sync_id, self.P.GIMMICK_MODE.FULL, items)) do
        self.send(msg, true)
    end
    self.counters.full_sent = self.counters.full_sent + 1
    return #items
end

function GimmickSync:enqueue(items, full)
    for _, item in ipairs(items) do
        local key = self.P.ctx_key(item.ctx)
        local h = GimmickSync.hash(item)
        local mine = self.baseline and self.baseline[key]
        if mine ~= h or full then
            if self.queue[key] == nil then self.queued = self.queued + 1 end
            self.queue[key] = item
            -- The client must not echo the host's state back; the host re-broadcasts on purpose.
            if self.role == "client" and mine ~= h then
                self.expect[key] = h
            end
        end
    end
    if full then self.counters.full_applied = self.counters.full_applied + 1 end
end

-- The partner's new records: only where we have none for that gimmick.
function GimmickSync:enqueue_added(items)
    if self.baseline == nil then
        for _, item in ipairs(items) do self.pending_added[#self.pending_added + 1] = item end
        return
    end
    local replies = {}
    for _, item in ipairs(items) do
        local key = self.P.ctx_key(item.ctx)
        local mine = self.baseline[key]
        if mine == nil and self.queue[key] == nil then
            self.queue[key] = item
            self.queued = self.queued + 1
            self.expect[key] = GimmickSync.hash(item)
        elseif mine ~= nil and self.role == "host" and self.items[key] ~= nil and mine ~= GimmickSync.hash(item) then
            -- The client's game started this gimmick over (its record was lost): the host's
            -- state is the shared one, send it back.
            replies[#replies + 1] = self.items[key]
        end
    end
    if #replies > 0 then
        table.sort(replies, by_key(self.P))
        for _, msg in ipairs(self.P.encode_gimmicks(0, self.P.GIMMICK_MODE.DELTA, replies)) do
            self.send(msg, true)
        end
        self.counters.sent = self.counters.sent + #replies
    end
end

function GimmickSync:on_gimmicks(m, now)
    if not self:enabled() then return end
    self.counters.received = self.counters.received + #m.items
    if m.mode == self.P.GIMMICK_MODE.ADDED then
        self:enqueue_added(m.items)
        return
    end
    if m.mode ~= self.P.GIMMICK_MODE.FULL then
        self:enqueue(m.items, false)
        return
    end
    local part = self.parts[m.sync_id]
    if part == nil or part.chunks ~= m.chunks then
        part = { chunks = m.chunks, got = {}, n = 0, time = now }
        self.parts[m.sync_id] = part
    end
    if not part.got[m.chunk] then
        part.got[m.chunk] = m.items
        part.n = part.n + 1
    end
    for id, p in pairs(self.parts) do
        if now - p.time > FULL_TIMEOUT then self.parts[id] = nil end
    end
    if part.n < part.chunks then return end
    self.parts[m.sync_id] = nil
    local all = {}
    for c = 1, part.chunks do
        for _, it in ipairs(part.got[c] or {}) do all[#all + 1] = it end
    end
    self:enqueue(all, true)
end

function GimmickSync:apply_queue(now, world)
    if self.queued == 0 or now - self.last_apply < APPLY_INTERVAL then return end
    self.last_apply = now
    local items = {}
    for _, item in pairs(self.queue) do items[#items + 1] = item end
    table.sort(items, function(a, b) return self.P.ctx_key(a.ctx) < self.P.ctx_key(b.ctx) end)
    if world:gimmicks_apply(items) then
        self.counters.applied = self.counters.applied + #items
    else
        -- Not applicable right now (loading?). Drop our expectations so nothing is lost.
        for _, item in ipairs(items) do self.expect[self.P.ctx_key(item.ctx)] = nil end
    end
    self.queue = {}
    self.queued = 0
end

function GimmickSync:tick(now, world)
    if not self:enabled() then return end
    self:apply_queue(now, world)
    -- A gimmick announced a state change (GimmickManager.pushDirtyList): read the table soon
    -- instead of waiting for the next periodic scan.
    self.has_signal = world.gimmicks_dirty ~= nil
    if self.has_signal and world:gimmicks_dirty() then
        self.dirty_at = self.dirty_at or now
        self.announced = true
    end
    local due = now - self.last_scan >= (self.settings.gimmick_interval or INTERVAL)
    if self.dirty_at ~= nil and now - self.dirty_at >= DIRTY_DELAY and now - self.last_scan >= MIN_INTERVAL then
        due = true
    end
    if due and self:scan(now, world) then
        self.last_scan = now
        self.dirty_at = nil
        self.counters.scans = self.counters.scans + 1
    end
end

function GimmickSync:on_message(m, now)
    if m.type == self.P.T.GIMMICKS then
        self:on_gimmicks(m, now)
        return true
    end
    return false
end

function GimmickSync:summary()
    return { counters = self.counters, queued = self.queued }
end

return GimmickSync
