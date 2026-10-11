-- Shared key items: a key item exists once for the pair. Whoever picks it up keeps it, and
-- the partner's copy is removed from their world. The other player rejoins with the
-- left-behind teleport (session.lua) instead of being softlocked behind a locked door.
--
-- Pure Lua with an adapter, tested offline (tests/lua/test_items_sync.lua).
-- Adapter contract:
--   pickups = { {id=<number>, item_id=<number>, pos={x,y,z}, ctx=<ContextID table or nil>}, ... }
--   game:remove_pickup(id) -> bool
--   is_key_item(item_id) -> bool

local ItemSync = {}
ItemSync.__index = ItemSync

-- An item that vanishes counts as picked up only if the local player was this close when
-- it was last seen, and saw it moments before. Items also vanish when their area streams
-- out, but the player is far away then; treating that as a pickup would delete the
-- partner's copy and softlock both players.
local PICKUP_RADIUS = 4.0
local SEEN_FRESH = 1.0
-- Fallback when a pickup has no readable ContextID: same item ID this close = same item.
local MATCH_RADIUS = 2.5
-- A player picks up at most one item per scan (0.25 s). If this many pickups of any kind
-- disappear in one scan, an area unloaded (door, loading screen): nothing counts as taken.
-- Missing a real pickup only leaves a duplicate key item; a false one deletes the partner's
-- copy while nobody has it, which is a softlock.
local MASS_VANISH = 3

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts: { protocol, send=function(bytes, reliable), is_key_item=function(id), settings, notify=function(text) }
function ItemSync.new(opts)
    local self = setmetatable({}, ItemSync)
    self.P = opts.protocol
    self.send = opts.send
    self.is_key_item = opts.is_key_item
    self.settings = opts.settings or {}
    self.notify = opts.notify or function() end
    self:reset()
    return self
end

function ItemSync:reset()
    self.tracked = {}   -- local pickup id -> {item_id, pos, ctx, last_seen, near}
    self.taken = {}     -- array of {item_id, pos, ctx_key, by = "me"|"partner"}
    self.taken_ctx = {} -- ctx key -> taken record
    self.counters = { taken_by_me = 0, taken_by_partner = 0, removed = 0, remove_failed = 0, unloads_ignored = 0 }
    self.last_ids = nil -- every pickup id (any item) seen in the previous scan
end

function ItemSync:record(item_id, pos, ctx, by)
    local key = self.P.ctx_key(ctx)
    if key ~= nil and self.taken_ctx[key] ~= nil then return false end
    for _, t in ipairs(self.taken) do
        if key == nil and t.item_id == item_id and dist(t.pos, pos) <= MATCH_RADIUS then return false end
    end
    local rec = { item_id = item_id, pos = { x = pos.x, y = pos.y, z = pos.z }, ctx_key = key, by = by }
    self.taken[#self.taken + 1] = rec
    if key ~= nil then self.taken_ctx[key] = rec end
    return true
end

-- Has this pickup already been taken (by either player)?
function ItemSync:find_taken(p)
    local key = self.P.ctx_key(p.ctx)
    if key ~= nil and self.taken_ctx[key] ~= nil then
        return self.taken_ctx[key]
    end
    for _, t in ipairs(self.taken) do
        if t.item_id == p.item_id and dist(t.pos, p.pos) <= MATCH_RADIUS then
            return t
        end
    end
    return nil
end

-- pickups: list from game:list_pickups() (nil = scene unreadable this tick: do nothing).
-- player_pos: fresh local player position, or nil when unknown/stale (then nothing can be
-- detected as picked up). can_detect: false during cutscenes and transitions.
function ItemSync:tick(now, pickups, player_pos, game, can_detect)
    if self.settings.share_key_items == false or pickups == nil then return end
    -- Count pickups of any kind that disappeared since the last scan (new ones appearing in
    -- the same scan, as in an area swap, must not hide an unload).
    local ids, vanished = {}, 0
    for _, p in ipairs(pickups) do ids[p.id] = true end
    if self.last_ids ~= nil then
        for id in pairs(self.last_ids) do
            if not ids[id] then vanished = vanished + 1 end
        end
    end
    self.last_ids = ids
    local mass_vanish = vanished >= MASS_VANISH

    local present = {}
    for _, p in ipairs(pickups) do
        if self.is_key_item(p.item_id) then
            local t = self:find_taken(p)
            if t ~= nil and t.by == "partner" then
                -- The partner has it: remove our copy (again, if the area reloaded it).
                if game:remove_pickup(p.id) then
                    self.counters.removed = self.counters.removed + 1
                else
                    self.counters.remove_failed = self.counters.remove_failed + 1
                end
                self.tracked[p.id] = nil
            elseif t == nil then
                present[p.id] = true
                local tr = self.tracked[p.id] or {}
                tr.item_id, tr.pos, tr.ctx, tr.last_seen = p.item_id, p.pos, p.ctx, now
                tr.near = player_pos ~= nil and dist(player_pos, p.pos) <= PICKUP_RADIUS
                self.tracked[p.id] = tr
            end
        end
    end

    if mass_vanish then
        self.counters.unloads_ignored = self.counters.unloads_ignored + 1
    end
    for id, tr in pairs(self.tracked) do
        if not present[id] then
            if tr.near and now - tr.last_seen <= SEEN_FRESH and can_detect ~= false and not mass_vanish then
                if self:record(tr.item_id, tr.pos, tr.ctx, "me") then
                    self.counters.taken_by_me = self.counters.taken_by_me + 1
                    self.send(self.P.encode_item_taken({ item_id = tr.item_id, pos = tr.pos, ctx = tr.ctx }), true)
                end
            end
            self.tracked[id] = nil
        end
    end
end

-- Returns true if the message was consumed.
function ItemSync:on_message(m)
    if m.type ~= self.P.T.ITEM_TAKEN then return false end
    if self:record(m.item_id, m.pos, m.ctx, "partner") then
        self.counters.taken_by_partner = self.counters.taken_by_partner + 1
        self.notify(("Partner picked up a key item (ID %d) - it is gone from your world"):format(m.item_id))
    end
    return true
end

function ItemSync:summary()
    local tracked = 0
    for _ in pairs(self.tracked) do tracked = tracked + 1 end
    return { tracked = tracked, taken = #self.taken, counters = self.counters }
end

return ItemSync
