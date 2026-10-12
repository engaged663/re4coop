-- Doors for both games.
--
-- A RE4 door (chainsaw.GmDoor) opens when its "open" attribute bit is set and closes by itself
-- once nobody keeps it open. Who keeps it open are two slots, _NeedKeepOpenSelf[Host] - our
-- player, a timer refreshed while it stands in the doorway - and [Guest], the other player of
-- the game's own (dormant) co-op design, set only by GmDoor.recvGmParam. Without this module
-- each game decides alone: the partner's game opens the door when the shared gimmick state
-- says "open", but nobody holds it there, so it swings shut while it stays open for the player
-- standing in it (docs/RESEARCH.md 3.11).
--
-- Each game reports the doors near its player - open or not, and whether its player keeps it
-- open - whenever that changes. The other game opens the same door at once (the same
-- attribute bits: the door plays its own opening) and holds it open through the Guest slot
-- until the partner's player no longer does. So a door is open in both games while either
-- player keeps it open, and closes in both when neither does.
--
-- Adapter contract (world):
--   world:doors_near(pos, radius) -> { [guid] = {open, hold, attr} } | nil
--   world:door_apply(guid, {open, hold, attr}) -> "done" | "missing"
--   world:doors_release()      (the partner left: no Guest slot stays set)

local DoorSync = {}
DoorSync.__index = DoorSync

local RADIUS = 25.0        -- metres around our player whose doors we report
local INTERVAL = 0.1       -- seconds between looks at those doors
local RETRY = 0.5          -- seconds between attempts for a door not loaded here yet
local MISSING_KEEP = 10.0  -- how long a partner's door waits to be loaded here

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function DoorSync.new(opts)
    local self = setmetatable({}, DoorSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function DoorSync:reset()
    if self.world ~= nil and self.world.doors_release ~= nil then pcall(self.world.doors_release, self.world) end
    self.sent = {}      -- guid -> {open, hold, attr}: what the partner knows of our doors
    self.pending = {}   -- guid -> {st, time, next_try}: partner doors not loaded here yet
    self.last = -math.huge
    self.counters = { sent = 0, received = 0, applied = 0, missing = 0 }
end

function DoorSync:enabled()
    return self.settings.sync_doors ~= false
end

function DoorSync:apply(world, guid, st, now)
    local r = world:door_apply(guid, st)
    if r == "missing" then
        local p = self.pending[guid]
        self.pending[guid] = { st = st, time = p and p.time or now, next_try = now + RETRY }
        return false
    end
    self.pending[guid] = nil
    self.counters.applied = self.counters.applied + 1
    return true
end

function DoorSync:on_doors(m, now, world)
    if not self:enabled() or world == nil or world.door_apply == nil then return end
    self.world = world
    for _, d in ipairs(m.doors) do
        if d.guid ~= nil then
            self.counters.received = self.counters.received + 1
            self:apply(world, d.guid, d, now)
        end
    end
end

-- pos = our player's position.
function DoorSync:tick(now, world, pos)
    if not self:enabled() or world == nil or world.doors_near == nil then return end
    self.world = world
    for guid, p in pairs(self.pending) do
        if now - p.time > MISSING_KEEP then
            self.pending[guid] = nil
            self.counters.missing = self.counters.missing + 1
        elseif now >= p.next_try then
            self:apply(world, guid, p.st, now)
        end
    end
    if now - self.last < INTERVAL or pos == nil then return end
    self.last = now
    local near = world:doors_near(pos, RADIUS)
    if near == nil then return end
    local changes = {}
    for guid, st in pairs(near) do
        local prev = self.sent[guid]
        if (prev == nil and (st.open or st.hold)) or (prev ~= nil and (prev.open ~= st.open or prev.hold ~= st.hold)) then
            changes[#changes + 1] = { guid = guid, open = st.open, hold = st.hold, attr = st.attr }
        end
        self.sent[guid] = st
    end
    -- Doors we walked away from: we no longer keep them open.
    for guid, prev in pairs(self.sent) do
        if near[guid] == nil then
            if prev.hold then changes[#changes + 1] = { guid = guid, open = false, hold = false, attr = prev.attr } end
            self.sent[guid] = nil
        end
    end
    if #changes == 0 then return end
    table.sort(changes, function(a, b) return a.guid < b.guid end)
    for _, msg in ipairs(self.P.encode_doors(changes)) do self.send(msg, true) end
    self.counters.sent = self.counters.sent + #changes
end

function DoorSync:on_message(m, now, world)
    if m.type == self.P.T.DOORS then
        self:on_doors(m, now, world)
        return true
    end
    return false
end

function DoorSync:summary()
    local queued = 0
    for _ in pairs(self.pending) do queued = queued + 1 end
    return { counters = self.counters, queued = queued }
end

return DoorSync
