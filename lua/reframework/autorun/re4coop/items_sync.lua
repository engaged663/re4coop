-- Shared key items: a key item exists once for the pair. Whoever picks it up keeps it, and
-- the partner's copy is removed from their world. The other player rejoins with the
-- left-behind teleport (session.lua) instead of being softlocked behind a locked door.
--
-- Pure Lua with an adapter, tested offline (tests/lua/test_items_sync.lua).
-- Adapter contract:
--   pickups = { {id=<number>, item_id=<number>, pos={x,y,z}, ctx=<ContextID table or nil>,
--               stage=<StageID or nil>}, ... }
--   accepted = { {key=<ctx key>}, ... } pickup callbacks since the last tick (nil = no hook)
--   flags = { [item_id] = <bool> } InventoryManager.getItemGetFlag for watched_item_ids()
--           (nil = unreadable)
--   game:remove_pickup(id) -> bool
--   is_key_item(item_id) -> bool
--
-- How a pickup is detected (a key item left the scene, and...):
--   * flag: the game's "item obtained" flag for that item turned true. Exact, and works
--     however the item was picked up.
--   * confirmed: the game's pickup callback (DropItem.onAcceptPickup, hooked in game.lua)
--     named the item's ContextID. Exact.
--   * heuristic, only until one of the exact signals has been seen to match a vanished
--     pickup: the item vanished right next to the player, outside cutscenes, and not as part
--     of an area unload. After that only exact signals count: an unconfirmed key item that
--     vanishes is left alone (at worst both players keep a copy).

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
-- How far apart (seconds) an exact signal and the item's disappearance may be.
local ACCEPT_WINDOW = 3.0
local EVENT_LOG_MAX = 12

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
    self.tracked = {}       -- local pickup id -> {item_id, pos, ctx, stage, only, last_seen, near}
    self.taken = {}         -- array of {item_id, pos, ctx_key, stage, only_instance, by = "me"|"partner"}
    self.taken_ctx = {}     -- ctx key -> taken record
    self.counters = { taken_by_me = 0, taken_by_partner = 0, removed = 0, remove_failed = 0, remove_ineffective = 0,
        unloads_ignored = 0, flag = 0, confirmed = 0, heuristic = 0, unconfirmed_ignored = 0 }
    self.last_ids = nil     -- every pickup id (any item) seen in the previous scan -> {key, item_id}
    self.accepted = {}      -- ctx key -> time a pickup callback named it
    self.flag_accepted = {} -- item id -> time its "obtained" flag turned true
    self.flag_last = {}     -- item id -> last flag value read
    self.vanished = {}      -- ctx key -> time a pickup with that key left the scene
    self.vanished_items = {} -- key item id -> time a pickup of it left the scene
    self.pending = {}       -- local pickup id -> {tr, time}: vanished key item a late signal may confirm
    self.removed_ids = {}   -- pickups we removed in the previous scan (must be gone now)
    self.hook_seen, self.hook_proven = false, false
    self.flags_seen, self.flags_proven = false, false
    self.events = {}        -- recent decisions, for diagnostics and the research log
end

function ItemSync:log_event(now, text)
    local e = self.events
    e[#e + 1] = { t = math.floor(now * 10 + 0.5) / 10, text = text }
    if #e > EVENT_LOG_MAX then table.remove(e, 1) end
end

-- An exact pickup signal has been seen to work in this session.
function ItemSync:proven()
    return self.hook_proven or self.flags_proven
end

function ItemSync:record(item_id, pos, ctx, by, stage, only_instance)
    local key = self.P.ctx_key(ctx)
    if key ~= nil and self.taken_ctx[key] ~= nil and self.taken_ctx[key].item_id == item_id then return false end
    for _, t in ipairs(self.taken) do
        if t.item_id == item_id and dist(t.pos, pos) <= MATCH_RADIUS then return false end
    end
    local rec = { item_id = item_id, pos = { x = pos.x, y = pos.y, z = pos.z }, ctx_key = key, by = by,
        stage = stage, only_instance = only_instance == true }
    self.taken[#self.taken + 1] = rec
    if key ~= nil and self.taken_ctx[key] == nil then self.taken_ctx[key] = rec end
    return true
end

-- Has this pickup already been taken (by either player)? counts: item id -> copies in this scan.
function ItemSync:find_taken(p, counts)
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
    -- The item was the only copy in the taker's scene, it is the only copy here, and both
    -- are in the same stage: the same key item even if it lies elsewhere (dropped by an
    -- enemy, knocked away).
    if counts ~= nil and counts[p.item_id] == 1 and p.stage ~= nil then
        for _, t in ipairs(self.taken) do
            if t.only_instance and t.item_id == p.item_id and t.stage ~= nil and t.stage == p.stage then
                return t
            end
        end
    end
    return nil
end

-- The local player took this key item: remember it and tell the partner.
function ItemSync:took(now, tr, how)
    if not self:record(tr.item_id, tr.pos, tr.ctx, "me", tr.stage, tr.only) then return end
    self.counters.taken_by_me = self.counters.taken_by_me + 1
    self.counters[how] = self.counters[how] + 1
    self:log_event(now, ("you took key item %d (%s)"):format(tr.item_id, how))
    -- Runtime ContextIDs mean nothing on the partner's machine: match by item and position.
    local ctx = (tr.ctx ~= nil and not self.P.ctx_is_runtime(tr.ctx)) and tr.ctx or nil
    self.send(self.P.encode_item_taken({ item_id = tr.item_id, pos = tr.pos, ctx = ctx, stage = tr.stage,
        only_instance = tr.only }), true)
end

-- Key item ids whose "obtained" flag the caller should read for the next tick.
function ItemSync:watched_item_ids()
    local seen, out = {}, {}
    local function add(id)
        if id ~= nil and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    for _, tr in pairs(self.tracked) do add(tr.item_id) end
    for _, pend in pairs(self.pending) do add(pend.tr.item_id) end
    table.sort(out)
    return out
end

-- pickups: list from game:list_pickups() (nil = scene unreadable this tick: do nothing).
-- player_pos: fresh local player position, or nil when unknown/stale (then nothing can be
-- detected as picked up by the heuristic). can_detect: false during cutscenes and
-- transitions. accepted: game:take_pickup_events() (nil when the hook is not installed).
-- flags: game:item_get_flags(self:watched_item_ids()) (nil when unreadable).
function ItemSync:tick(now, pickups, player_pos, game, can_detect, accepted, flags)
    if self.settings.share_key_items == false then return end
    if accepted ~= nil then
        self.hook_seen = true
        for _, ev in ipairs(accepted) do
            if ev.key ~= nil then self.accepted[ev.key] = now end
        end
    end
    if flags ~= nil then
        self.flags_seen = true
        for id, v in pairs(flags) do
            if self.flag_last[id] == false and v == true then
                self.flag_accepted[id] = now
            end
            self.flag_last[id] = v
        end
    end
    if pickups == nil then return end

    -- Count pickups of any kind that disappeared since the last scan (new ones appearing in
    -- the same scan, as in an area swap, must not hide an unload).
    local ids, counts, vanished = {}, {}, 0
    for _, p in ipairs(pickups) do
        ids[p.id] = { key = self.P.ctx_key(p.ctx), item_id = p.item_id }
        counts[p.item_id] = (counts[p.item_id] or 0) + 1
    end
    if self.last_ids ~= nil then
        for id, info in pairs(self.last_ids) do
            if ids[id] == nil then
                vanished = vanished + 1
                if info.key then self.vanished[info.key] = now end
                if self.is_key_item(info.item_id) then self.vanished_items[info.item_id] = now end
            end
        end
    end
    self.last_ids = ids
    local mass_vanish = vanished >= MASS_VANISH

    -- An exact signal is proven once it named a pickup that then left the scene.
    for key, t in pairs(self.accepted) do
        local v = self.vanished[key]
        if v ~= nil and math.abs(v - t) <= ACCEPT_WINDOW then self.hook_proven = true end
        if now - t > ACCEPT_WINDOW then self.accepted[key] = nil end
    end
    for id, t in pairs(self.flag_accepted) do
        local v = self.vanished_items[id]
        if v ~= nil and math.abs(v - t) <= ACCEPT_WINDOW then self.flags_proven = true end
        if now - t > ACCEPT_WINDOW then self.flag_accepted[id] = nil end
    end
    for key, t in pairs(self.vanished) do
        if now - t > ACCEPT_WINDOW then self.vanished[key] = nil end
    end
    for id, t in pairs(self.vanished_items) do
        if now - t > ACCEPT_WINDOW then self.vanished_items[id] = nil end
    end

    -- Copies we destroyed last scan must be gone.
    for id in pairs(self.removed_ids) do
        if ids[id] ~= nil then
            self.counters.remove_ineffective = self.counters.remove_ineffective + 1
            self:log_event(now, ("removing key item %d had no effect"):format(ids[id].item_id))
        end
    end
    self.removed_ids = {}

    local present = {}
    for _, p in ipairs(pickups) do
        if self.is_key_item(p.item_id) then
            local t = self:find_taken(p, counts)
            if t ~= nil and t.by == "partner" then
                -- The partner has it: remove our copy (again, if the area reloaded it).
                if game:remove_pickup(p.id) then
                    self.counters.removed = self.counters.removed + 1
                    self.removed_ids[p.id] = true
                    self:log_event(now, ("removed your copy of key item %d"):format(p.item_id))
                else
                    self.counters.remove_failed = self.counters.remove_failed + 1
                end
                self.tracked[p.id] = nil
            elseif t == nil then
                present[p.id] = true
                local tr = self.tracked[p.id] or {}
                tr.item_id, tr.pos, tr.ctx, tr.stage, tr.last_seen = p.item_id, p.pos, p.ctx, p.stage, now
                tr.only = counts[p.item_id] == 1
                tr.near = player_pos ~= nil and dist(player_pos, p.pos) <= PICKUP_RADIUS
                self.tracked[p.id] = tr
            end
        end
    end

    if mass_vanish then
        self.counters.unloads_ignored = self.counters.unloads_ignored + 1
    end
    local proven = self:proven()
    for id, tr in pairs(self.tracked) do
        if not present[id] then
            local key = self.P.ctx_key(tr.ctx)
            local plausible = tr.near and now - tr.last_seen <= SEEN_FRESH and can_detect ~= false and not mass_vanish
            if self.flag_accepted[tr.item_id] ~= nil then
                self:took(now, tr, "flag")
            elseif key ~= nil and self.accepted[key] ~= nil then
                self:took(now, tr, "confirmed")
            elseif plausible and not proven then
                self:took(now, tr, "heuristic")
            else
                self.pending[id] = { tr = tr, time = now }
            end
            self.tracked[id] = nil
        end
    end
    for id, pend in pairs(self.pending) do
        local key = self.P.ctx_key(pend.tr.ctx)
        if self.flag_accepted[pend.tr.item_id] ~= nil then
            self:took(now, pend.tr, "flag")
            self.pending[id] = nil
        elseif key ~= nil and self.accepted[key] ~= nil then
            self:took(now, pend.tr, "confirmed")
            self.pending[id] = nil
        elseif now - pend.time > ACCEPT_WINDOW then
            if pend.tr.near and proven then
                -- Vanished next to us, but the game never reported a pickup: diagnostics only.
                self.counters.unconfirmed_ignored = self.counters.unconfirmed_ignored + 1
                self:log_event(now, ("key item %d vanished nearby without a pickup signal"):format(pend.tr.item_id))
            end
            self.pending[id] = nil
        end
    end
end

-- Returns true if the message was consumed.
function ItemSync:on_message(m, now)
    if m.type ~= self.P.T.ITEM_TAKEN then return false end
    local ctx = (m.ctx ~= nil and not self.P.ctx_is_runtime(m.ctx)) and m.ctx or nil
    if self:record(m.item_id, m.pos, ctx, "partner", m.stage, m.only_instance) then
        self.counters.taken_by_partner = self.counters.taken_by_partner + 1
        self:log_event(now or 0, ("partner took key item %d"):format(m.item_id))
        self.notify(("Partner picked up a key item (ID %d) - it is gone from your world"):format(m.item_id))
    end
    return true
end

local function signal_state(seen, proven)
    if proven then return "confirmed" elseif seen then return "waiting for first pickup" end
    return "off"
end

function ItemSync:summary()
    local tracked = 0
    for _ in pairs(self.tracked) do tracked = tracked + 1 end
    return { tracked = tracked, taken = #self.taken, counters = self.counters,
        hook = signal_state(self.hook_seen, self.hook_proven),
        flags = signal_state(self.flags_seen, self.flags_proven),
        events = self.events }
end

return ItemSync
