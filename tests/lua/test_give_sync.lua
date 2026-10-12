-- Giving items to the partner: two simulated games with an attache case each, every message
-- going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local GiveSync = require("re4coop.give_sync")

local HERB, AMMO = 114400000, 112800000

-- A game's attache case: item counts by ItemID, `room` = how many more of anything fit.
local function make_game(room)
    local g = { case = {}, room = room or 99, open = false }
    function g:give_receive(id, count)
        if self.open then return nil, "inventory open" end
        local fit = math.max(0, math.min(count, self.room))
        self.room = self.room - fit
        if fit > 0 then self.case[id] = (self.case[id] or 0) + fit end
        return fit
    end
    function g:item_name(id) return id == HERB and "Green Herb" or nil end
    return g
end

local function make_pair()
    local pair = { now = 0, a_to_b = {}, b_to_a = {}, msgs = { a = {}, b = {} } }
    pair.ga, pair.gb = make_game(), make_game()
    local function sync(name, out)
        return GiveSync.new({ protocol = P, settings = {},
            send = function(bytes) table.insert(pair[out], bytes) end,
            notify = function(text, kind) table.insert(pair.msgs[name], { text = text, kind = kind }) end,
            partner_name = function() return name == "a" and "Bob" or "Ann" end })
    end
    pair.a, pair.b = sync("a", "a_to_b"), sync("b", "b_to_a")
    pair.playable = { a = true, b = true }
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.1
            local ab, ba = self.a_to_b, self.b_to_a
            self.a_to_b, self.b_to_a = {}, {}
            for _, m in ipairs(ab) do self.b:on_message(assert(P.decode(m)), self.now) end
            for _, m in ipairs(ba) do self.a:on_message(assert(P.decode(m)), self.now) end
            self.a:tick(self.now, self.ga, self.playable.a)
            self.b:tick(self.now, self.gb, self.playable.b)
        end
    end
    function pair:last(name)
        local m = self.msgs[name]
        return m[#m] and m[#m].text or ""
    end
    return pair
end

T.run("an_item_given_lands_in_the_partners_case", function()
    local pair = make_pair()
    pair.a:on_give({ item_id = HERB, count = 2, durability = -1 }, pair.now, pair.ga)
    T.check(pair:last("a"):find("Gave Green Herb x2 to Bob") ~= nil, "the giver is told")
    pair:step(5)
    T.eq(pair.gb.case[HERB], 2, "in the partner's case")
    T.check(pair:last("b"):find("Ann gave you Green Herb x2") ~= nil, "the partner is told")
    T.eq(pair.a:summary().unconfirmed, 0, "confirmed")
    T.eq(pair.ga.case[HERB], nil, "nothing came back")
end)

T.run("what_does_not_fit_comes_back", function()
    local pair = make_pair()
    pair.gb.room = 1
    pair.a:on_give({ item_id = AMMO, count = 3, durability = -1 }, pair.now, pair.ga)
    pair:step(5)
    T.eq(pair.gb.case[AMMO], 1, "what fitted stays with the partner")
    T.eq(pair.ga.case[AMMO], 2, "the rest is back in the giver's case")
    T.check(pair:last("b"):find("no room in your case, 2 sent back") ~= nil, "the partner is told")
    T.check(pair:last("a"):find("case is full") ~= nil, "the giver is told")
end)

T.run("an_item_waits_while_the_partners_case_is_open_or_they_are_busy", function()
    local pair = make_pair()
    pair.gb.open = true
    pair.a:on_give({ item_id = HERB, count = 1, durability = -1 }, pair.now, pair.ga)
    pair:step(15)
    T.eq(pair.gb.case[HERB], nil, "not while the case is open")
    T.check(pair:last("b"):find("Ann is giving you Green Herb %- close your case to receive it") ~= nil,
        "the partner is told why it waits")
    T.eq(pair.b:waiting_items()[1], "from Ann: Green Herb", "and sees it waiting")
    pair.gb.open = false
    pair.playable.b = false -- a cutscene
    pair:step(5)
    T.eq(pair.gb.case[HERB], nil, "nor during a cutscene")
    pair.playable.b = true
    pair:step(5)
    T.eq(pair.gb.case[HERB], 1, "then it is placed")
end)

T.run("an_item_given_to_a_partner_who_left_comes_back", function()
    local pair = make_pair()
    pair.a:on_give({ item_id = HERB, count = 1, durability = -1 }, pair.now, pair.ga)
    pair.a_to_b = {} -- the partner left before it arrived
    pair.a:partner_left(pair.now)
    pair:step(3)
    T.eq(pair.ga.case[HERB], 1, "back in the giver's case")
end)

T.run("a_returned_item_waits_for_room", function()
    local pair = make_pair()
    pair.ga.room = 0
    pair.gb.room = 0
    pair.a:on_give({ item_id = HERB, count = 1, durability = -1 }, pair.now, pair.ga)
    pair:step(5)
    T.eq(pair.ga.case[HERB], nil, "no room on either side yet")
    T.check(pair:last("a"):find("Make room in your case") ~= nil, "the giver is asked to make room")
    T.eq(pair.a:summary().queued, 1, "it waits")
    pair.ga.room = 1
    pair:step(10)
    T.eq(pair.ga.case[HERB], 1, "back once there is room")
end)

T.finish()
