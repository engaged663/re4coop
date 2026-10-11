-- Shared key items: a key item exists once for the pair. Whoever picks it up keeps it, and
-- the partner's copy is removed from their world. The other player rejoins with the
-- left-behind teleport (session.lua) instead of being softlocked behind a locked door.
--
-- Pure Lua with an adapter, tested offline (tests/lua/test_items_sync.lua).
-- Adapter contract:
--   pickups = { {id=<number>, item_id=<number>, pos={x,y,z}, ctx=<ContextID table or nil>}, ... }
--   accepted = { {key=<ctx key>}, ... } pickup callbacks since the last tick (nil = no hook)
--   game:remove_pickup(id) -> bool
--   is_key_item(item_id) -> bool
--
-- How a pickup is detected:
--   * Confirmed: the game's pickup callback (DropItem.onAcceptPickup, hooked in game.lua)
--     named the item's ContextID and the item left the scene. Exact.
--   * Heuristic, only until a callback has been seen to match a vanished pickup: the item
--     vanished right next to the player, outside cutscenes, and not as part of an area
--     unload. Once callbacks are proven, they are the only signal: an unconfirmed key item
--     that vanishes is left alone (at worst both players keep a copy).

local ItemSync = {}
ItemSync.__index = ItemSync

-- An item that vanishes counts as picked up only if the local player was this close when
-- it was last seen, and saw it moments before. Items also vanish when their area streams
-- out, but the player is far away then; treating that as a pickup would delete the
-- partner's copy and softlock both players.
local PICKUP_RADIUS = 4.0
local SEEN_FRESH = 1.0
-- Same item ID this close = same item. A drop item's ContextID is a runtime counter (the
-- research dump showed 2:0:12:192..486), so two machines can give the same number to
-- different items: it only counts together with a matching item ID.
local MATCH_RADIUS = 2.5
-- A player picks up at most one item per scan (0.25 s). If this many pickups of any kind
-- disappear in one scan, an area unloaded (door, loading screen): nothing counts as taken.
-- Missing a real pickup only leaves a duplicate key item; a false one deletes the partner's
-- copy while nobody has it, which is a softlock.
local MASS_VANISH = 3
-- How far apart (seconds) a pickup callback and the item's disappearance may be.
local ACCEPT_WINDOW = 3.0

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
    self.counters = { taken_by_me = 0, taken_by_partner = 0, removed = 0, remove_failed = 0, unloads_ignored = 0,
        confirmed = 0, heuristic = 0, unconfirmed_ignored = 0 }
    self.last_ids = nil -- every pickup id (any item) seen in the previous scan -> its ctx key or false
    self.accepted = {}  -- ctx key -> time a pickup callback named it
    self.vanished = {}  -- ctx key -> time any pickup with that key left the scene
    self.pending = {}   -- ctx key -> {tr, time}: vanished key item that a late callback may still confirm
    self.hook_seen = false
    self.hook_proven = false
end

function ItemSync:record(item_id, pos, ctx, by)
    local key = self.P.ctx_key(ctx)
    if key ~= nil and self.taken_ctx[key] ~= nil and self.taken_ctx[key].item_id == item_id then return false end
    for _, t in ipairs(self.taken) do
        if t.item_id == item_id and dist(t.pos, pos) <= MATCH_RADIUS then return false end
    end
    local rec = { item_id = item_id, pos = { x = pos.x, y = pos.y, z = pos.z }, ctx_key = key, by = by }
    self.taken[#self.taken + 1] = rec
    if key ~= nil and self.taken_ctx[key] == nil then self.taken_ctx[key] = rec end
    return true
end

-- Has this pickup already been taken (by either player)?
function ItemSync:find_taken(p)
    local key = self.P.ctx_key(p.ctx)
    local by_ctx = key ~= nil and self.taken_ctx[key] or nil
    if by_ctx ~= nil and by_ctx.item_id == p.item_id then
        return by_ctx
    end
    for _, t in ipairs(self.taken) do
        if t.item_id == p.item_id and dist(t.pos, p.pos) <= MATCH_RADIUS then
            return t
        end
    end
    return nil
end

-- The local player took this key item: remember it and tell the partner.
function ItemSync:took(tr, how)
    if not self:record(tr.item_id, tr.pos, tr.ctx, "me") then return end
    self.counters.taken_by_me = self.counters.taken_by_me + 1
    self.counters[how] = self.counters[how] + 1
    -- Runtime ContextIDs mean nothing on the partner's machine: match by item and position.
    local ctx = (tr.ctx ~= nil and not self.P.ctx_is_runtime(tr.ctx)) and tr.ctx or nil
    self.send(self.P.encode_item_taken({ item_id = tr.item_id, pos = tr.pos, ctx = ctx }), true)
end

-- pickups: list from game:list_pickups() (nil = scene unreadable this tick: do nothing).
-- player_pos: fresh local player position, or nil when unknown/stale (then nothing can be
-- detected as picked up by the heuristic). can_detect: false during cutscenes and
-- transitions. accepted: game:take_pickup_events() (nil when the hook is not installed).
function ItemSync:tick(now, pickups, player_pos, game, can_detect, accepted)
    if self.settings.share_key_items == false then return end
    if accepted ~= nil then
        self.hook_seen = true
        for _, ev in ipairs(accepted) do
            if ev.key ~= nil then self.accepted[ev.key] = now end
        end
    end
    if pickups == nil then return end
    -- Count pickups of any kind that disappeared since the last scan (new ones appearing in
    -- the same scan, as in an area swap, must not hide an unload).
    local ids, vanished = {}, 0
    for _, p in ipairs(pickups) do ids[p.id] = self.P.ctx_key(p.ctx) or false end
    if self.last_ids ~= nil then
        for id, key in pairs(self.last_ids) do
            if ids[id] == nil then
                vanished = vanished + 1
                if key then self.vanished[key] = now end
            end
        end
    end
    self.last_ids = ids
    local mass_vanish = vanished >= MASS_VANISH

    -- The callbacks are proven once one of them named a pickup that then left the scene.
    for key, t in pairs(self.accepted) do
        local v = self.vanished[key]
        if v ~= nil and math.abs(v - t) <= ACCEPT_WINDOW then
            self.hook_proven = true
        end
        if now - t > ACCEPT_WINDOW then self.accepted[key] = nil end
    end
    for key, t in pairs(self.vanished) do
        if now - t > ACCEPT_WINDOW then self.vanished[key] = nil end
    end

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
            local key = self.P.ctx_key(tr.ctx)
            local plausible = tr.near and now - tr.last_seen <= SEEN_FRESH and can_detect ~= false and not mass_vanish
            if key ~= nil and self.accepted[key] ~= nil then
                self:took(tr, "confirmed")
            elseif plausible and not self.hook_proven then
                self:took(tr, "heuristic")
            elseif key ~= nil then
                self.pending[key] = { tr = tr, time = now }
            end
            self.tracked[id] = nil
        end
    end
    for key, pend in pairs(self.pending) do
        if self.accepted[key] ~= nil then
            self:took(pend.tr, "confirmed")
            self.pending[key] = nil
        elseif now - pend.time > ACCEPT_WINDOW then
            if pend.tr.near and self.hook_proven then
                -- Vanished next to us, but the game never reported a pickup: diagnostics only.
                self.counters.unconfirmed_ignored = self.counters.unconfirmed_ignored + 1
            end
            self.pending[key] = nil
        end
    end
end

-- Returns true if the message was consumed.
function ItemSync:on_message(m)
    if m.type ~= self.P.T.ITEM_TAKEN then return false end
    local ctx = (m.ctx ~= nil and not self.P.ctx_is_runtime(m.ctx)) and m.ctx or nil
    if self:record(m.item_id, m.pos, ctx, "partner") then
        self.counters.taken_by_partner = self.counters.taken_by_partner + 1
        self.notify(("Partner picked up a key item (ID %d) - it is gone from your world"):format(m.item_id))
    end
    return true
end

function ItemSync:summary()
    local tracked = 0
    for _ in pairs(self.tracked) do tracked = tracked + 1 end
    local hook = "off"
    if self.hook_proven then hook = "confirmed" elseif self.hook_seen then hook = "waiting for first pickup" end
    return { tracked = tracked, taken = #self.taken, counters = self.counters, hook = hook }
end

return ItemSync
