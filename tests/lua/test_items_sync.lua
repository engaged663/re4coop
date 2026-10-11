-- Shared key items between two simulated worlds, through the real protocol codec.
local T = require("testlib")
local P = require("re4coop.protocol")
local ItemSync = require("re4coop.items_sync")

local function is_key(id) return id >= 119000000 and id <= 119999999 end

local function make_world()
    local w = { items = {}, next_id = 1, removed = {} }
    function w:place(item_id, x, y, z, ctx)
        local p = { id = self.next_id, item_id = item_id, pos = { x = x, y = y, z = z }, ctx = ctx }
        self.next_id = self.next_id + 1
        table.insert(self.items, p)
        return p
    end
    function w:take(p) -- player picks it up / area unloads it
        for i, x in ipairs(self.items) do
            if x == p then table.remove(self.items, i) return end
        end
    end
    function w:list()
        local out = {}
        for i, p in ipairs(self.items) do
            out[i] = { id = p.id, item_id = p.item_id, pos = p.pos, ctx = p.ctx }
        end
        return out
    end
    -- Pickup callback hook (game.lua's DropItem hooks). nil = not installed.
    w.events = nil
    function w:accept(p) -- the game reports that the local player picked p up
        self.events = self.events or {}
        self.events[#self.events + 1] = { key = P.ctx_key(p.ctx) }
    end
    function w:take_events()
        if self.events == nil then return nil end
        local out = self.events
        self.events = {}
        return out
    end
    function w:remove_pickup(id)
        for i, p in ipairs(self.items) do
            if p.id == id then
                table.remove(self.items, i)
                self.removed[#self.removed + 1] = p.item_id
                return true
            end
        end
        return false
    end
    return w
end

local function make_pair(settings)
    local pair = { now = 0, a = make_world(), b = make_world(), to_a = {}, to_b = {}, notices = {} }
    settings = settings or { share_key_items = true }
    pair.sa = ItemSync.new({ protocol = P, settings = settings, is_key_item = is_key,
        send = function(bytes) table.insert(pair.to_b, bytes) end,
        notify = function(t) table.insert(pair.notices, t) end })
    pair.sb = ItemSync.new({ protocol = P, settings = settings, is_key_item = is_key,
        send = function(bytes) table.insert(pair.to_a, bytes) end,
        notify = function(t) table.insert(pair.notices, t) end })
    pair.pos_a = { x = 0, y = 0, z = 0 }
    pair.pos_b = { x = 0, y = 0, z = 0 }
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.25
            self.sa:tick(self.now, self.a:list(), self.pos_a, self.a, self.detect_a, self.a:take_events())
            self.sb:tick(self.now, self.b:list(), self.pos_b, self.b, true, self.b:take_events())
            for _, m in ipairs(self.to_a) do self.sa:on_message(assert(P.decode(m))) end
            for _, m in ipairs(self.to_b) do self.sb:on_message(assert(P.decode(m))) end
            self.to_a, self.to_b = {}, {}
        end
    end
    return pair
end

local COG = 119235200
-- Level-placed item ID (category 3, stage group): the same on both machines.
local CTX = { category = 3, kind = 0, group = 40210, index = 3 }
-- Runtime ID (group 12): handed out in load order, different meaning on each machine.
local function runtime(index) return { category = 2, kind = 0, group = 12, index = index } end

T.run("picking_up_a_key_item_removes_partners_copy", function()
    local pair = make_pair()
    local cog_a = pair.a:place(COG, 2, 0, 0, CTX)
    pair.b:place(COG, 2, 0, 0, CTX)
    pair.pos_a = { x = 1.5, y = 0, z = 0 }
    pair:step(2)
    pair.a:take(cog_a) -- player A picks it up
    pair:step(3)
    T.eq(#pair.b.items, 0, "partner's Wooden Cog removed")
    T.eq(pair.b.removed[1], COG, "removed via game:remove_pickup")
    T.eq(pair.sa.counters.taken_by_me, 1, "A recorded its pickup")
    T.eq(pair.sb.counters.taken_by_partner, 1, "B learned about it")
    T.check(#pair.notices == 1 and pair.notices[1]:find("Partner picked up"), "B is told")
end)

T.run("area_unload_far_away_is_not_a_pickup", function()
    local pair = make_pair()
    local cog_a = pair.a:place(COG, 80, 0, 0, CTX)
    pair.b:place(COG, 80, 0, 0, CTX)
    pair:step(2)
    pair.a:take(cog_a) -- A walked away and the area streamed out
    pair:step(3)
    T.eq(#pair.b.items, 1, "partner keeps the item")
    T.eq(pair.sa.counters.taken_by_me, 0, "no false pickup")
end)

T.run("stale_sighting_is_not_a_pickup", function()
    local pair = make_pair()
    local cog_a = pair.a:place(COG, 1, 0, 0, CTX)
    pair.b:place(COG, 1, 0, 0, CTX)
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(1)
    -- Scans fail for a while (loading screen), then the item is gone.
    pair.a:take(cog_a)
    for _ = 1, 8 do
        pair.now = pair.now + 0.25
        pair.sa:tick(pair.now, nil, pair.pos_a, pair.a)
    end
    pair:step(2)
    T.eq(#pair.b.items, 1, "unknown cause after a long gap: partner keeps it")
end)

T.run("ordinary_items_are_never_shared", function()
    local pair = make_pair()
    local herb_a = pair.a:place(112800000, 1, 0, 0, CTX)
    pair.b:place(112800000, 1, 0, 0, CTX)
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    pair.a:take(herb_a)
    pair:step(3)
    T.eq(#pair.b.items, 1, "both players get their own herb")
end)

T.run("reloaded_area_removes_it_again", function()
    local pair = make_pair()
    local cog_a = pair.a:place(COG, 0, 0, 0, CTX)
    pair.b:place(COG, 0, 0, 0, CTX)
    pair:step(1)
    pair.a:take(cog_a)
    pair:step(2)
    T.eq(#pair.b.items, 0, "removed")
    pair.b:place(COG, 0, 0, 0, CTX) -- B leaves and comes back; the level spawns it again
    pair:step(2)
    T.eq(#pair.b.items, 0, "removed again")
    T.eq(#pair.notices, 1, "told only once")
end)

T.run("matching_without_context_id_uses_item_and_position", function()
    local pair = make_pair()
    local a1 = pair.a:place(COG, 5, 0, 5, nil)
    pair.b:place(COG, 5.5, 0, 5.2, nil)
    local elsewhere = pair.b:place(COG, 40, 0, 0, nil) -- same ID, other place: a different item
    pair.pos_a = { x = 5, y = 0, z = 4 }
    pair:step(2)
    pair.a:take(a1)
    pair:step(2)
    T.eq(#pair.b.items, 1, "the matching copy is removed")
    T.eq(pair.b.items[1], elsewhere, "the distant one stays")
end)

T.run("simultaneous_pickup_keeps_both", function()
    local pair = make_pair()
    local ia = pair.a:place(COG, 0, 0, 0, CTX)
    local ib = pair.b:place(COG, 0, 0, 0, CTX)
    pair:step(1)
    pair.a:take(ia)
    pair.b:take(ib)
    pair:step(3)
    T.eq(pair.sa.counters.taken_by_me + pair.sb.counters.taken_by_me, 2, "both picked it up")
    T.eq(#pair.notices, 0, "nobody's copy is removed retroactively")
end)

T.run("area_unload_next_to_a_key_item_is_not_a_pickup", function()
    local pair = make_pair()
    -- A stands next to the Cog (not taking it) when a door/loading transition swaps areas:
    -- the old area's pickups vanish and the new area's appear in the same scan.
    local cog_a = pair.a:place(COG, 1, 0, 0, CTX)
    local herb1 = pair.a:place(112800000, 2, 0, 0, nil)
    local herb2 = pair.a:place(112800000, 3, 0, 0, nil)
    pair.b:place(COG, 1, 0, 0, CTX)
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    pair.a:take(cog_a)
    pair.a:take(herb1)
    pair.a:take(herb2)
    pair.a:place(112800000, 50, 0, 0, nil) -- new area's items
    pair.a:place(112800000, 51, 0, 0, nil)
    pair.a:place(112800000, 52, 0, 0, nil)
    pair:step(3)
    T.eq(#pair.b.items, 1, "partner keeps the Cog")
    T.eq(pair.sa.counters.taken_by_me, 0, "no false pickup")
    T.eq(pair.sa.counters.unloads_ignored, 1, "recognised as an unload")
end)

T.run("no_detection_without_fresh_position_or_during_cutscene", function()
    local pair = make_pair()
    local cog_a = pair.a:place(COG, 1, 0, 0, CTX)
    pair.b:place(COG, 1, 0, 0, CTX)
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(1)
    pair.a:take(cog_a)
    pair.now = pair.now + 0.25
    pair.sa:tick(pair.now, pair.a:list(), pair.pos_a, pair.a, false) -- cutscene/transition
    pair:step(2)
    T.eq(#pair.b.items, 1, "not detected during a cutscene")
    local cog2 = pair.a:place(COG, 1, 0, 0, { category = 3, kind = 0, group = 40210, index = 4 })
    pair.b:place(COG, 1, 0, 0, { category = 3, kind = 0, group = 40210, index = 4 })
    pair:step(1)
    pair.a:take(cog2)
    pair.now = pair.now + 0.25
    pair.sa:tick(pair.now, pair.a:list(), nil, pair.a, false) -- position unknown (stale)
    pair:step(2)
    T.eq(#pair.b.items, 2, "not detected without a fresh position")
end)

T.run("same_context_id_different_item_is_not_removed", function()
    local pair = make_pair()
    -- Runtime drop-item IDs can coincide across machines: B's Boat Fuel has the same
    -- ContextID number as A's Wooden Cog. Only the Cog's copy may disappear.
    local cog_a = pair.a:place(COG, 1, 0, 0, CTX)
    pair.b:place(119273600, 30, 0, 0, CTX)
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    pair.a:take(cog_a)
    pair:step(3)
    T.eq(#pair.b.items, 1, "B's Boat Fuel stays")
    T.eq(pair.b.items[1].item_id, 119273600, "it is the fuel")
end)

T.run("level_context_id_matches_across_positions", function()
    local pair = make_pair()
    -- Same level-placed item, but B's copy was knocked 10 m away: the ContextID still matches.
    local cog_a = pair.a:place(COG, 1, 0, 0, CTX)
    pair.b:place(COG, 11, 0, 0, CTX)
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    pair.a:take(cog_a)
    pair:step(3)
    T.eq(#pair.b.items, 0, "matched by level ContextID")
end)

T.run("runtime_context_id_is_never_matched_across_machines", function()
    local pair = make_pair()
    -- A's Cog and a second Cog on B elsewhere got the same runtime number 12:486.
    local cog_a = pair.a:place(COG, 1, 0, 0, runtime(486))
    pair.b:place(COG, 30, 0, 0, runtime(486))
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    pair.a:take(cog_a)
    pair:step(3)
    T.eq(pair.sa.counters.taken_by_me, 1, "A's pickup detected")
    T.eq(#pair.b.items, 1, "B's distant Cog stays")
end)

T.run("confirmed_pickup_counts_even_where_the_heuristic_refuses", function()
    local pair = make_pair()
    pair.a.events = {} -- hook installed
    local cog_a = pair.a:place(COG, 1, 0, 0, runtime(300))
    pair.b:place(COG, 1, 0, 0, runtime(301))
    for i = 1, 3 do pair.a:place(112800000, 5 + i, 0, 0, runtime(310 + i)) end
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    -- The pickup opens the key-item inspection screen (counts as a cutscene) and the area
    -- swaps in the same scan: the heuristic would refuse, the game's callback decides.
    pair.detect_a = false
    pair.a:accept(cog_a)
    pair.a:take(cog_a)
    for i = #pair.a.items, 1, -1 do pair.a:take(pair.a.items[i]) end
    pair:step(3)
    T.eq(pair.sa.counters.confirmed, 1, "confirmed by the callback")
    T.eq(#pair.b.items, 0, "partner's copy removed")
    T.eq(pair.sa:summary().hook, "confirmed", "hook proven")
end)

T.run("proven_hook_ignores_unconfirmed_vanish", function()
    local pair = make_pair()
    pair.a.events = {}
    local herb = pair.a:place(112800000, 2, 0, 0, runtime(200))
    local cog_a = pair.a:place(COG, 1, 0, 0, runtime(201))
    pair.b:place(COG, 1, 0, 0, runtime(202))
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    T.eq(pair.sa:summary().hook, "waiting for first pickup", "installed, not yet proven")
    pair.a:accept(herb) -- an ordinary pickup proves the callback works
    pair.a:take(herb)
    pair:step(2)
    T.eq(pair.sa:summary().hook, "confirmed", "proven by a herb")
    pair.a:take(cog_a) -- vanishes next to A without a callback (e.g. a scripted removal)
    pair:step(16)
    T.eq(pair.sa.counters.taken_by_me, 0, "not a pickup")
    T.eq(pair.sa.counters.unconfirmed_ignored, 1, "noted for diagnostics")
    T.eq(#pair.b.items, 1, "partner keeps the Cog")
end)

T.run("late_callback_still_confirms", function()
    local pair = make_pair()
    pair.a.events = {}
    local cog_a = pair.a:place(COG, 20, 0, 0, runtime(400)) -- far from A's position: heuristic says no
    pair.b:place(COG, 20, 0, 0, runtime(401))
    pair:step(2)
    pair.a:take(cog_a)
    pair:step(1)
    T.eq(pair.sa.counters.taken_by_me, 0, "not yet")
    pair.a:accept(cog_a) -- callback arrives one scan after the item left
    pair:step(3)
    T.eq(pair.sa.counters.confirmed, 1, "confirmed late")
    T.eq(#pair.b.items, 0, "partner's copy removed")
end)

T.run("callback_without_disappearance_is_nothing", function()
    local pair = make_pair()
    pair.a.events = {}
    local cog_a = pair.a:place(COG, 1, 0, 0, runtime(500))
    pair.b:place(COG, 1, 0, 0, runtime(501))
    pair.pos_a = { x = 1, y = 0, z = 0 }
    pair:step(2)
    pair.a:accept(cog_a) -- e.g. onAcceptOccupied: the pickup was refused, the item stays
    pair:step(10)
    T.eq(pair.sa.counters.taken_by_me, 0, "item still there: not taken")
    T.eq(#pair.b.items, 1, "partner keeps it")
    T.eq(pair.sa:summary().hook, "waiting for first pickup", "not proven by it either")
end)

T.run("disabled_setting_does_nothing", function()
    local pair = make_pair({ share_key_items = false })
    local ia = pair.a:place(COG, 0, 0, 0, CTX)
    pair.b:place(COG, 0, 0, 0, CTX)
    pair:step(1)
    pair.a:take(ia)
    pair:step(3)
    T.eq(#pair.b.items, 1, "untouched")
end)

T.finish()
