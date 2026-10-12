-- Giving items to the partner (the "Give to ..." entry of the attache case's item commands).
--
-- The giver's game takes the item out of the case (the game's own discard path) and reports it
-- (game_give.lua); this module sends it. The partner's game makes the same item and puts it in
-- its case (the game's own item factory and CsInventoryController.add) - not while its case is
-- open, a cutscene plays or a level loads: it waits for that. Whatever did not fit is sent back
-- and goes back into the giver's case. An item is never lost: one given to a partner who left
-- before confirming it comes back, and one that does not fit anywhere waits until there is room.
--
-- Game contract:
--   game:give_receive(item_id, count, durability) -> fitted (0..count) | nil, why (not now)
--   game:item_name(item_id) -> string | nil      (optional)

local GiveSync = {}
GiveSync.__index = GiveSync

local RETRY = 0.5          -- seconds between attempts to place an item here
local ROOM_NOTICE = 20.0   -- how often "make room" is repeated for an item that does not fit
local WAIT_NOTICE = 1.0    -- an item waiting this long for our case to close is announced

-- opts: { protocol, settings, send(bytes, reliable), notify(text, kind), partner_name() }
function GiveSync.new(opts)
    local self = setmetatable({}, GiveSync)
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.notify = opts.notify or function() end
    self.partner_name = opts.partner_name or function() return "partner" end
    self.seq = 0
    self.outgoing = {}  -- seq -> {ev, time}: given, not confirmed yet
    self.incoming = {}  -- {seq, ev, next_try}: the partner's items waiting to go into our case
    self.returns = {}   -- {ev, next_try, noticed}: our items coming back into our case
    self.counters = { given = 0, received = 0, placed = 0, returned = 0, back = 0 }
    return self
end

function GiveSync:enabled()
    return self.settings.give_items ~= false
end

local function name_of(game, ev)
    local n = game and game.item_name and game:item_name(ev.item_id) or nil
    local what = n or "an item"
    if (ev.count or 1) > 1 then what = ("%s x%d"):format(what, ev.count) end
    return what
end

-- Our player gave an item (already out of our case). ev = {item_id, count, durability}
function GiveSync:on_give(ev, now, game)
    self.seq = self.seq % 0xFFFFFFFF + 1
    self.outgoing[self.seq] = { ev = ev, time = now }
    self.send(self.P.encode_item_give({ seq = self.seq, item_id = ev.item_id, count = ev.count,
        durability = ev.durability }), true)
    self.counters.given = self.counters.given + 1
    self.notify(("Gave %s to %s"):format(name_of(game, ev), self.partner_name()), "info")
end

-- The partner left: what they never confirmed comes back to us.
function GiveSync:partner_left(now)
    for seq, o in pairs(self.outgoing) do
        self.returns[#self.returns + 1] = { ev = o.ev, next_try = now }
        self.outgoing[seq] = nil
    end
end

function GiveSync:on_message(m, now)
    if m.type == self.P.T.ITEM_GIVE then
        self.counters.received = self.counters.received + 1
        local e = { seq = m.seq, ev = { item_id = m.item_id, count = m.count, durability = m.durability },
            next_try = now }
        e.on_wait = function(why)
            self.notify(("%s is giving you %s - %s"):format(self.partner_name(), name_of(self.game, e.ev),
                why == "inventory open" and "close your case to receive it" or "it arrives as soon as you can take it"), "info")
        end
        self.incoming[#self.incoming + 1] = e
        return true
    elseif m.type == self.P.T.ITEM_GIVE_RESULT then
        local o = self.outgoing[m.seq]
        self.outgoing[m.seq] = nil
        if o ~= nil and m.returned > 0 then
            local back = { item_id = o.ev.item_id, count = m.returned, durability = o.ev.durability }
            self.returns[#self.returns + 1] = { ev = back, next_try = now, full = true }
        end
        return true
    end
    return false
end

-- Puts an item into our case: true when done with it (all of it placed, or `on_rest` took the rest).
local function place(self, game, entry, now, on_rest)
    if now < entry.next_try then return false end
    entry.next_try = now + RETRY
    local ev = entry.ev
    local fitted, why = game:give_receive(ev.item_id, ev.count, ev.durability)
    if fitted == nil then -- not now (case open, cutscene, loading)
        entry.since = entry.since or now
        if entry.on_wait and not entry.wait_noticed and now - entry.since >= WAIT_NOTICE then
            entry.wait_noticed = true
            entry.on_wait(why)
        end
        return false
    end
    if fitted > 0 then self.counters.placed = self.counters.placed + 1 end
    local rest = ev.count - fitted
    if rest <= 0 then return true, fitted end
    ev.count = rest
    return on_rest(rest), fitted
end

-- playable: our player is in game, not in a cutscene or a loading screen.
function GiveSync:tick(now, game, playable)
    self.game = game
    if not playable or game == nil or game.give_receive == nil then return end
    -- The partner's items.
    local keep = {}
    for _, e in ipairs(self.incoming) do
        local total = e.ev.count
        local done, fitted = place(self, game, e, now, function(rest)
            -- No room: back to the partner (or, if they left, it waits here for room).
            self.send(self.P.encode_item_give_result({ seq = e.seq, returned = rest }), true)
            self.counters.returned = self.counters.returned + 1
            self.notify(("%s gave you %s - no room in your case, %d sent back"):format(self.partner_name(),
                name_of(game, e.ev), rest), "warn")
            return true
        end)
        if done then
            if fitted ~= nil and fitted >= total then
                self.send(self.P.encode_item_give_result({ seq = e.seq, returned = 0 }), true)
                self.notify(("%s gave you %s"):format(self.partner_name(), name_of(game, e.ev)), "good")
            end
        else
            keep[#keep + 1] = e
        end
    end
    self.incoming = keep
    -- Our own items coming back.
    keep = {}
    for _, r in ipairs(self.returns) do
        local done = place(self, game, r, now, function()
            if now - (r.noticed or -math.huge) >= ROOM_NOTICE then
                r.noticed = now
                self.notify(("Make room in your case: %s is waiting to come back"):format(name_of(game, r.ev)), "warn")
            end
            return false
        end)
        if done then
            self.counters.back = self.counters.back + 1
            if r.full then
                self.notify(("%s's case is full: %s came back to yours"):format(self.partner_name(), name_of(game, r.ev)), "warn")
            end
        else
            keep[#keep + 1] = r
        end
    end
    self.returns = keep
end

function GiveSync:summary()
    local waiting = 0
    for _ in pairs(self.outgoing) do waiting = waiting + 1 end
    return { counters = self.counters, queued = #self.incoming + #self.returns, unconfirmed = waiting }
end

-- Items waiting here (for the UI): { {text}, ... }
function GiveSync:waiting_items()
    local out = {}
    for _, e in ipairs(self.incoming) do
        out[#out + 1] = ("from %s: %s"):format(self.partner_name(), name_of(self.game, e.ev))
    end
    for _, r in ipairs(self.returns) do
        out[#out + 1] = ("coming back: %s"):format(name_of(self.game, r.ev))
    end
    return out
end

return GiveSync
