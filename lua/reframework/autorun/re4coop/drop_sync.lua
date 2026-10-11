-- Identical enemy drops: the host's random roll decides what a dead enemy drops for both.
--
--   host:   the game's random-drop call for an enemy (DropItemManager.generateRandomDrop,
--           hooked in game.lua) is followed by a new pickup appearing where the enemy died.
--           That item is sent as ITEM_DROPPED with the enemy's net id.
--   client: skips its own random roll for enemies paired with a host enemy, and spawns the
--           host's item where its copy of the enemy is.
--
-- Nothing is skipped until it is known to work: the client must have seen its own drop
-- hook fire for an enemy (so skipping really prevents the local roll), and if a spawn of
-- the host's item cannot be found in the scene afterwards before any spawn was verified,
-- drop sync switches itself off and both games roll their own drops again. Wooden boxes and
-- other non-enemy drops are never touched. Drops of unpaired enemies stay local.
--
-- Pure Lua with an adapter, tested offline (tests/lua/test_drop_sync.lua).
-- Adapter contract:
--   drop events = { {enemy_id=<local enemy id>, droptype=<number>}, ... } (game:take_drop_events())
--   pickups     = game:list_pickups() entries {id, item_id, count, pos, stage}
--   game:spawn_drop(item_id, count, pos, stage) -> ok
--   game:set_drop_suppress({ [enemy_id] = true })

local DropSync = {}
DropSync.__index = DropSync

local DROP_RADIUS = 4.0      -- metres between the enemy and the new pickup
local DROP_WINDOW = 3.0      -- seconds after the drop call the item may appear
local VERIFY_WINDOW = 3.0    -- seconds a spawned item has to show up in the scene
local PAIR_MEMORY = 60.0     -- client: remember a host enemy's local copy this long after it died
local MAX_PENDING = 32

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function copy3(v) return { x = v.x, y = v.y, z = v.z } end

-- opts: { role="host"|"client", protocol, send=function(bytes, reliable), settings,
--         enemy_sync=<EnemySync of the same session>, is_key_item=function(id), log }
function DropSync.new(opts)
    local self = setmetatable({}, DropSync)
    self.role = opts.role
    self.P = opts.protocol
    self.send = opts.send
    self.settings = opts.settings or {}
    self.enemy_sync = opts.enemy_sync
    self.is_key_item = opts.is_key_item or function() return false end
    self.log = opts.log or function() end
    self:reset()
    return self
end

function DropSync:reset()
    self.pending = {}        -- host: {net_id, pos, time} drops waiting for their item to appear
    self.seen = nil          -- pickup ids present in the previous scan
    self.pairs = {}          -- client: net id -> {id, pos, time}
    self.verifying = {}      -- client: spawned items to find: {item_id, pos, time}
    self.hook_proven = false -- client: our drop hook fired for an enemy
    self.spawn_verified = false
    self.spawn_failed = false
    self.counters = { drops_seen = 0, sent = 0, received = 0, spawned = 0, spawn_errors = 0, verified = 0,
        unverified = 0, unpaired = 0 }
end

function DropSync:enabled()
    return self.settings.sync_drops ~= false
end

-- Client: whether our own rolls for paired enemies are being skipped.
function DropSync:active()
    return self.role == "client" and self:enabled() and self.hook_proven and not self.spawn_failed
end

-- Every update. drop_events: game:take_drop_events() (nil without the hook).
function DropSync:on_drop_events(now, events)
    if events == nil or not self:enabled() then return end
    local es = self.enemy_sync
    for _, ev in ipairs(events) do
        self.counters.drops_seen = self.counters.drops_seen + 1
        if self.role == "host" then
            local net_id = es and es.net_of[ev.enemy_id]
            local e = es and es.by_id[ev.enemy_id]
            if net_id ~= nil and e ~= nil and #self.pending < MAX_PENDING then
                self.pending[#self.pending + 1] = { net_id = net_id, pos = copy3(e.pos), time = now }
            end
        else
            self.hook_proven = true
        end
    end
end

-- Client, every update: remember which local enemy copies belong to which host enemy, and
-- tell the game whose rolls to skip.
function DropSync:update_pairs(now, game)
    if self.role ~= "client" then return end
    local es = self.enemy_sync
    local suppress = {}
    if es ~= nil then
        for net_id, id in pairs(es.local_of) do
            local e = es.by_id[id]
            if e ~= nil then
                self.pairs[net_id] = { id = id, pos = copy3(e.pos), time = now }
                if self:active() then suppress[id] = true end
            end
        end
    end
    for net_id, p in pairs(self.pairs) do
        if now - p.time > PAIR_MEMORY then self.pairs[net_id] = nil end
    end
    if game ~= nil and game.set_drop_suppress ~= nil then game:set_drop_suppress(suppress) end
end

-- Every pickup scan. pickups: game:list_pickups() (nil = unreadable).
function DropSync:on_pickups(now, pickups, local_stage)
    if pickups == nil or not self:enabled() then return end
    local ids, fresh = {}, {}
    for _, p in ipairs(pickups) do
        ids[p.id] = true
        if self.seen ~= nil and not self.seen[p.id] then fresh[#fresh + 1] = p end
    end
    self.seen = ids

    if self.role == "host" then
        for _, p in ipairs(fresh) do
            if not self.is_key_item(p.item_id) then
                for i, d in ipairs(self.pending) do
                    if now - d.time <= DROP_WINDOW and dist(d.pos, p.pos) <= DROP_RADIUS then
                        self.send(self.P.encode_item_dropped({ net_id = d.net_id, item_id = p.item_id,
                            count = p.count or 1, pos = p.pos, stage = p.stage or local_stage }), true)
                        self.counters.sent = self.counters.sent + 1
                        table.remove(self.pending, i)
                        break
                    end
                end
            end
        end
        for i = #self.pending, 1, -1 do
            if now - self.pending[i].time > DROP_WINDOW then table.remove(self.pending, i) end
        end
    else
        for _, p in ipairs(fresh) do
            for i, v in ipairs(self.verifying) do
                if v.item_id == p.item_id and dist(v.pos, p.pos) <= DROP_RADIUS then
                    self.spawn_verified = true
                    self.counters.verified = self.counters.verified + 1
                    table.remove(self.verifying, i)
                    break
                end
            end
        end
        for i = #self.verifying, 1, -1 do
            if now - self.verifying[i].time > VERIFY_WINDOW then
                table.remove(self.verifying, i)
                self.counters.unverified = self.counters.unverified + 1
                if not self.spawn_verified then
                    -- Spawning the host's items does not work here: roll our own again.
                    self.spawn_failed = true
                    self.log("drop sync off: spawned item did not appear")
                end
            end
        end
    end
end

-- Client: the host's enemy dropped an item. Returns true if consumed.
function DropSync:on_message(m, now, game, local_stage)
    if m.type ~= self.P.T.ITEM_DROPPED then return false end
    if self.role ~= "client" then return true end
    self.counters.received = self.counters.received + 1
    if not self:active() then return true end
    local pair = self.pairs[m.net_id]
    if pair == nil then
        -- Not paired: our copy rolled its own drop (it was not suppressed).
        self.counters.unpaired = self.counters.unpaired + 1
        return true
    end
    local pos = pair.pos
    local ok = game:spawn_drop(m.item_id, m.count, pos, local_stage or m.stage)
    if ok then
        self.counters.spawned = self.counters.spawned + 1
        self.verifying[#self.verifying + 1] = { item_id = m.item_id, pos = copy3(pos), time = now }
    else
        self.counters.spawn_errors = self.counters.spawn_errors + 1
        if not self.spawn_verified then
            self.spawn_failed = true
            self.log("drop sync off: spawning failed")
        end
    end
    return true
end

function DropSync:summary()
    local state
    if not self:enabled() then
        state = "off"
    elseif self.role == "host" then
        state = "host rolls drops"
    elseif self.spawn_failed then
        state = "off (spawning the host's items failed)"
    elseif not self.hook_proven then
        state = "waiting for the first enemy drop"
    elseif self.spawn_verified then
        state = "synced"
    else
        state = "synced (first spawn not yet verified)"
    end
    return { state = state, counters = self.counters }
end

return DropSync
