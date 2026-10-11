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
            self.sa:tick(self.now, self.a:list(), self.pos_a, self.a)
            self.sb:tick(self.now, self.b:list(), self.pos_b, self.b)
            for _, m in ipairs(self.to_a) do self.sa:on_message(assert(P.decode(m))) end
            for _, m in ipairs(self.to_b) do self.sb:on_message(assert(P.decode(m))) end
            self.to_a, self.to_b = {}, {}
        end
    end
    return pair
end

local COG = 119235200
local CTX = { category = 5, kind = 0, group = 12, index = 3 }

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
    local cog2 = pair.a:place(COG, 1, 0, 0, { category = 5, kind = 0, group = 12, index = 4 })
    pair.b:place(COG, 1, 0, 0, { category = 5, kind = 0, group = 12, index = 4 })
    pair:step(1)
    pair.a:take(cog2)
    pair.now = pair.now + 0.25
    pair.sa:tick(pair.now, pair.a:list(), nil, pair.a, false) -- position unknown (stale)
    pair:step(2)
    T.eq(#pair.b.items, 2, "not detected without a fresh position")
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
