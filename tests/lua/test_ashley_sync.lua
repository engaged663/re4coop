-- Ashley for both players: two simulated games, each with its own Ashley whose AI follows its
-- own player, joined by the real codec (every message encoded and decoded). Then the real
-- adapter (game_ashley.lua) against the mocked RE4.
local T = require("testlib")
local P = require("re4coop.protocol")
local Config = require("re4coop.config")
local AshleySync = require("re4coop.ashley_sync")
local mock = require("mock_reframework")

local DT = 0.05
local HOST, CLIENT = P.OWNER.HOST, P.OWNER.CLIENT

local function copy3(v) return { x = v.x, y = v.y, z = v.z } end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- A game with a player and its Ashley. Her AI (when she is not a puppet) runs to the player at
-- 4 m/s and stops 1.5 m from them, playing a walk whose frame advances.
local function make_game(player, ashley)
    local g = { player = copy3(player), present = true, puppet = false, visible = true, extras = {}, removed = {},
        moves = 0, anims = 0, hp_sets = {}, warps = {},
        ash = { pos = copy3(ashley), rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 600, max_hp = 600, alive = true,
            kidnapped = false, busy = false, frame = 0 } }
    function g:ashley_read(full)
        if not self.present then return nil end
        local a = self.ash
        local st = { pos = copy3(a.pos), rot = a.rot, hp = a.hp, max_hp = a.max_hp, alive = a.alive,
            kidnapped = a.kidnapped, busy = a.busy or a.kidnapped or not a.alive, hidden = a.hidden }
        if full then
            st.layers = { { bank = 7, id = a.walking and 20 or 10, frame = a.frame, speed = 1, blend = 1, mask = 0, mode = 0 },
                { bank = 9, id = 3, frame = 0, speed = 1, blend = a.arm_blend or 0, mask = 12, mode = 1 } }
            st.bank_type = a.bank_type or 0
        end
        return st
    end
    function g:ashley_set_puppet(on)
        self.puppet = on
        if not on then self.visible = true end -- (the adapter draws her again when she is released)
        return true
    end
    function g:ashley_set_visible(on)
        self.visible = on
        return true
    end
    -- Other Ashleys of this game: { key, doll }; removing one fails while `refuse` is set.
    function g:ashley_extras()
        return self.extras
    end
    function g:ashley_remove_extra(key)
        if self.refuse then return false end
        for i, e in ipairs(self.extras) do
            if e.key == key then
                table.remove(self.extras, i)
                self.removed[#self.removed + 1] = key
                return "erased"
            end
        end
        return false
    end
    function g:ashley_set_transform(pos, rot)
        self.ash.pos, self.ash.rot = copy3(pos), rot
        self.moves = self.moves + 1
        return true
    end
    function g:ashley_set_anim(layers, bank_type)
        self.ash.layers = layers
        self.ash.set_bank_type = bank_type
        self.anims = self.anims + 1
        if self.banks_applied ~= nil then self.anim_after_banks = true end
        return true
    end
    -- Her dynamic motion banks (`dyn`: a list), and the owner's put on the puppet.
    function g:ashley_read_banks()
        if self.dyn == nil then return nil end
        return { banks = self.dyn }
    end
    function g:ashley_set_banks(banks, key)
        self.banks_applied = banks
        self.banks_applied_key = key
        self.bank_sets = (self.bank_sets or 0) + 1
        return true
    end
    function g:ashley_set_hp(hp)
        self.hp_sets[#self.hp_sets + 1] = hp
        self.ash.hp = math.max(1, hp)
        return true
    end
    function g:ashley_warp(pos)
        self.warps[#self.warps + 1] = copy3(pos)
        self.ash.pos = copy3(pos)
        return true
    end
    function g:ai(dt)
        local a = self.ash
        a.walking = false
        if self.puppet or not self.present or a.kidnapped or not a.alive then return end
        local d = dist(a.pos, self.player)
        a.frame = a.frame + dt * 30
        if d > 1.5 then
            local step = math.min(4 * dt, d - 1.5)
            a.pos.x = a.pos.x + (self.player.x - a.pos.x) / d * step
            a.pos.z = a.pos.z + (self.player.z - a.pos.z) / d * step
            a.walking = true
        end
    end
    return g
end

-- Two games and their Ashley syncs; messages arrive at the next step.
local function make_pair(opts)
    opts = opts or {}
    local pair = { now = 0, settings = Config.load(nil), told = { host = {}, client = {} }, inbox = { host = {}, client = {} } }
    for k, v in pairs(opts.settings or {}) do pair.settings[k] = v end
    pair.host_game = make_game(opts.host_player or { x = 0, y = 0, z = 0 }, opts.host_ashley or { x = 3, y = 0, z = 0 })
    pair.client_game = make_game(opts.client_player or { x = 30, y = 0, z = 0 },
        opts.client_ashley or { x = 31, y = 0, z = 0 })
    local function sync(role, other, name)
        return AshleySync.new({ role = role, protocol = P, settings = pair.settings,
            send = function(bytes) local q = pair.inbox[other] q[#q + 1] = bytes end,
            notify = function(text) local t = pair.told[role] t[#t + 1] = text end,
            partner_name = function() return name end })
    end
    pair.host = sync("host", "client", "Bea")
    pair.client = sync("client", "host", "Ana")
    function pair:deliver(who)
        local q = self.inbox[who]
        self.inbox[who] = {}
        for _, bytes in ipairs(q) do
            local m = assert(P.decode(bytes))
            self[who]:on_message(m, self.now)
        end
    end
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + DT
            self:deliver("host")
            self:deliver("client")
            for _, who in ipairs({ "host", "client" }) do
                local g = self[who .. "_game"]
                g:ai(DT)
                self[who]:tick(self.now, g, { in_game = not g.loading, local_pos = g.player,
                    local_rot = { x = 0, y = 0, z = 0, w = 1 }, unable = g.cutscene, cutscene = g.cutscene })
                self[who]:frame(self.now, g)
            end
        end
    end
    function pair:seconds(s) self:step(math.floor(s / DT + 0.5)) end
    function pair:told_to(who, pattern)
        for _, t in ipairs(self.told[who]) do
            if t:find(pattern) then return true end
        end
        return false
    end
    return pair
end

T.run("ashley_starts_with_the_host_and_the_clients_follows_hers", function()
    local pair = make_pair()
    pair:seconds(2)
    local h, c = pair.host_game, pair.client_game
    T.check(pair.host:runs_here() and not pair.client:runs_here(), "the host's game runs her")
    T.eq(h.puppet, false, "the host's Ashley is the game's own")
    T.eq(c.puppet, true, "the client's is a puppet")
    T.near(dist(h.ash.pos, h.player), 1.5, 0.01, "she followed the host's player")
    T.near(dist(c.ash.pos, h.ash.pos), 0, 0.05, "the client's stands where the host's is")
    T.near(dist(c.ash.pos, c.player), 28.5, 0.1, "not with the client's player")
    T.eq(c.ash.layers and c.ash.layers[1].bank, 7, "and plays her animation")
    h.ash.hp = 420
    pair:seconds(0.5)
    T.eq(c.ash.hp, 420, "her HP too")
    T.check(#pair.told.host == 0 and #pair.told.client == 0, "nothing to tell yet")
end)

T.run("tapping_the_key_on_the_host_sends_her_to_the_client", function()
    local pair = make_pair()
    pair:seconds(2)
    local h, c = pair.host_game, pair.client_game
    T.check(pair.host:request(pair.now), "the host's player sends her over")
    pair:step(3)
    T.check(pair.client:runs_here() and not pair.host:runs_here(), "the client's game runs her now")
    T.eq(c.puppet, false, "the client's Ashley is the game's own again")
    T.eq(h.puppet, true, "the host's is the puppet now")
    T.eq(#c.warps, 1, "taken over 28 m away from the client's player: brought to them")
    T.near(c.warps[1].z, c.player.z - 1.5, 0.01, "behind them")
    T.check(pair:told_to("host", "Ashley now follows Bea"), "the host is told")
    T.check(pair:told_to("client", "Ashley now follows you"), "the client is told")
    c.player = { x = 40, y = 0, z = 10 }
    pair:seconds(5)
    T.near(dist(c.ash.pos, c.player), 1.5, 0.01, "she follows the client's player")
    T.near(dist(h.ash.pos, c.ash.pos), 0, 0.05, "and the host's stands where the client's is")
    T.eq(h.ash.layers[1].id, 10, "standing there like the client's")
end)

T.run("the_client_calls_her_over_and_she_walks_when_near", function()
    local pair = make_pair({ client_player = { x = 9, y = 0, z = 0 }, client_ashley = { x = 10, y = 0, z = 0 } })
    pair:seconds(2)
    local h, c = pair.host_game, pair.client_game
    T.check(pair.client:request(pair.now), "the client's player asks for her")
    T.eq(pair.client:runs_here(), false, "the host decides")
    pair:step(3)
    T.check(pair.client:runs_here(), "she is the client's now")
    T.eq(pair.host.epoch, pair.client.epoch, "both agree on the switch")
    T.eq(#c.warps, 0, "near enough: she walks")
    local start = dist(c.ash.pos, c.player)
    T.check(start > 5, "she starts where she was")
    pair:seconds(3)
    T.near(dist(c.ash.pos, c.player), 1.5, 0.01, "she walked to the client's player")
    T.near(dist(h.ash.pos, c.ash.pos), 0, 0.05, "the host sees her follow the client")
    T.check(pair:told_to("client", "Ashley now follows you"), "the client is told")
    T.check(pair:told_to("host", "Ashley now follows Bea"), "the host is told")
end)

T.run("a_switch_waits_for_the_cooldown", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host:request(pair.now)
    pair:step(2)
    T.check(pair.client:runs_here(), "switched")
    T.eq(pair.client:request(pair.now), false, "too soon")
    T.check(pair:told_to("client", "can switch again in 5 s"), "the client is told how long")
    T.eq(pair.host:request(pair.now), false, "for the host too")
    T.check(pair:told_to("host", "can switch again in 5 s"), "the host is told")
    pair:seconds(4.8)
    T.check(pair.client:runs_here(), "still the client's")
    pair:seconds(0.3)
    T.check(pair.client:request(pair.now), "after 5 s it may switch again")
    pair:step(3)
    T.check(pair.host:runs_here(), "back with the host")
    T.eq(pair.host.counters.switches, 2, "two switches")
    pair.settings.ashley_cooldown = 2.0
    pair:seconds(5)
    T.check(pair.host:request(pair.now), "switched with the new cooldown")
    pair:step(3)
    T.eq(pair.client:request(pair.now), false, "too soon")
    pair:seconds(2)
    T.check(pair.client:request(pair.now), "the cooldown is a setting")
end)

T.run("the_host_keeps_the_cooldown_even_if_the_client_asks_early", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host:request(pair.now)
    pair:step(3)
    -- A request that left the client before it heard of the switch's cooldown.
    pair.client.send(P.encode_ashley_switch({ epoch = pair.client.epoch }), true)
    pair:step(3)
    T.check(pair.client:runs_here(), "refused: still the client's")
    T.check(pair:told_to("client", "can switch again in"), "the client is told")
end)

T.run("she_does_not_go_to_a_player_in_a_cutscene", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host:request(pair.now)
    pair:step(3)
    T.check(pair.client:runs_here(), "the client's")
    pair:seconds(5.1)
    pair.host_game.cutscene = true
    pair:step(2)
    T.eq(pair.host:request(pair.now), false, "the host's player watches a cutscene")
    T.check(pair:told_to("host", "cannot go to you now"), "told")
    pair.client:request(pair.now)
    pair:step(3)
    T.check(pair.client:runs_here(), "still the client's")
    T.check(pair:told_to("client", "cannot go to Ana now"), "the client is told")
    pair.host_game.cutscene = nil
    pair:step(2)
    T.check(pair.host:request(pair.now), "after it")
end)

T.run("both_pressing_at_once_switch_once", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host:request(pair.now)
    pair.client:request(pair.now)
    pair:step(4)
    T.check(pair.client:runs_here(), "she went over once")
    T.eq(pair.host.counters.switches, 1, "one switch")
    T.eq(pair.host.counters.stale, 1, "the client's request was about the old owner")
    T.eq(pair.client.epoch, pair.host.epoch, "both agree")
    T.eq(#pair.told.client, 1, "the client is told once")
end)

T.run("no_switch_while_she_is_busy_or_the_other_game_cannot_take_her", function()
    local pair = make_pair()
    pair:seconds(1)
    local h, c = pair.host_game, pair.client_game
    h.ash.kidnapped = true
    pair:step(2)
    T.eq(pair.host:request(pair.now), false, "kidnapped: refused")
    T.check(pair:told_to("host", "kidnapped, down or busy"), "the host is told why")
    pair.client:request(pair.now)
    pair:step(3)
    T.check(pair.host:runs_here(), "still the host's")
    T.check(pair:told_to("client", "kidnapped, down or busy"), "the client is told why")
    h.ash.kidnapped = false
    c.present = false
    pair:seconds(1)
    T.eq(pair.host:request(pair.now), false, "the client's game has no Ashley here")
    T.check(pair:told_to("host", "cannot go to Bea now"), "told")
    c.present, c.cutscene = true, true
    pair:seconds(1)
    T.eq(pair.host:request(pair.now), false, "the client's player is in a cutscene")
    c.cutscene = nil
    pair:seconds(1)
    T.check(pair.host:request(pair.now), "now she may go")
    pair:step(3)
    T.check(pair.client:runs_here(), "switched")
    T.eq(pair.host.counters.refused, 4, "four refusals")
end)

T.run("she_goes_over_by_herself_when_the_game_running_her_has_none", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host_game.present = false -- a part of the story without her in the host's game
    pair:seconds(4.5)
    T.check(pair.host:runs_here(), "not at once")
    pair:seconds(1)
    T.check(pair.client:runs_here(), "the client's game has her: she goes there")
    T.eq(pair.client_game.puppet, false, "and runs there")
    T.eq(pair.host.counters.auto, 1, "counted")
    T.check(pair:told_to("client", "Ashley now follows you"), "told")
    -- A client still loading does not count as having none.
    pair.host_game.present = true
    pair:seconds(6)
    pair.client_game.loading = true
    pair:seconds(8)
    T.check(pair.client:runs_here(), "the client's game is only loading")
end)

T.run("our_game_never_lets_the_puppet_go_down", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host_game.ash.hp = 0
    pair.host_game.ash.alive = false
    pair:seconds(1)
    local c = pair.client_game
    for _, v in ipairs(c.hp_sets) do T.check(v >= 1, "never below 1") end
    T.check(c.ash.hp >= 1, "the puppet is not killed here")
    T.eq(pair.host:request(pair.now), false, "and she cannot change hands while down")
end)

T.run("switched_off_nothing_happens", function()
    local pair = make_pair({ settings = { ashley_coop = false } })
    pair:seconds(2)
    T.eq(pair.client_game.puppet, false, "the client's Ashley runs on her own")
    T.eq(pair.host.counters.sent + pair.client.counters.sent, 0, "nothing sent")
    T.eq(pair.host:request(pair.now), false, "no switching")
    -- Switched off while a puppet: she runs on her own again.
    pair.settings.ashley_coop = true
    pair:seconds(1)
    T.eq(pair.client_game.puppet, true, "a puppet once on")
    pair.settings.ashley_coop = false
    pair:step(1)
    T.eq(pair.client_game.puppet, false, "released")
end)

T.run("a_new_partner_starts_with_the_host", function()
    local pair = make_pair()
    pair:seconds(1)
    pair.host:request(pair.now)
    pair:step(3)
    T.check(pair.client:runs_here(), "the client's")
    pair.host:reset()
    pair.client:reset()
    pair.host_game.puppet, pair.client_game.puppet = false, false -- the session restores both games
    pair:seconds(1)
    T.check(pair.host:runs_here(), "the host's again")
    T.eq(pair.client_game.puppet, true, "the client's is the puppet")
    T.eq(pair.host:cooldown_left(pair.now), 0, "no cooldown carried over")
end)

T.run("the_ashley_messages_round_trip", function()
    local F = P.ASHLEY_FLAGS
    local m = assert(P.decode(P.encode_ashley({ time = 12.5, epoch = 3, flags = F.PRESENT | F.OWNER | F.ALIVE | F.BUSY,
        pos = { x = 1, y = 2, z = 3 }, rot = { x = 0, y = 0.7071068, z = 0, w = 0.7071068 }, hp = 450, max_hp = 600,
        layers = { { bank = 7, id = 20, frame = 12.5, speed = 1.2 }, { bank = 8, id = 1, frame = 0, speed = 1 } } })))
    T.eq(m.type, P.T.ASHLEY, "type")
    T.check(m.present and m.owner and m.alive and m.busy and not m.kidnapped, "flags")
    T.eq(m.epoch, 3, "epoch")
    T.near(m.pos.y, 2, 1e-6, "position")
    T.near(m.rot.y, 0.7071068, 0.01, "rotation")
    T.eq(m.hp, 450, "hp")
    T.eq(#m.layers, 2, "layers")
    T.near(m.layers[1].frame, 12.5, 1e-6, "frame")
    local o = assert(P.decode(P.encode_ashley_owner({ owner = CLIENT, epoch = 4, cooldown = 4.5,
        reason = P.ASHLEY_REASON.CHANGED, by = HOST })))
    T.eq(o.owner, CLIENT, "owner")
    T.near(o.cooldown, 4.5, 1e-6, "cooldown")
    local s = assert(P.decode(P.encode_ashley_switch({ epoch = 9 })))
    T.eq(s.epoch, 9, "switch epoch")
    T.eq(P.decode(string.char(P.T.ASHLEY_OWNER, 7, 1, 0, 0, 0, 0, 0, 0)), nil, "a bad owner is rejected")
end)

-------------------------------------------------------------------------------
-- The real adapter (game_ashley.lua) against the mocked RE4.
-------------------------------------------------------------------------------

T.run("the_puppet_plays_every_layer_with_the_owners_banks", function()
    local pair = make_pair()
    local h, c = pair.host_game, pair.client_game
    h.dyn = { { path = "_chainsaw/animation/ch2a1z0/gimmick_ladder.motlist", bank_id = 301, bank_type = 0,
        mask_bit = 0, order = 5, flags = 1 } }
    h.ash.bank_type = 1048576 -- Battle
    h.ash.arm_blend = 0.75
    pair:seconds(1)
    T.eq(c.banks_applied and #c.banks_applied, 1, "the host's dynamic motion bank reached the client's puppet")
    T.eq(c.banks_applied[1].path, "_chainsaw/animation/ch2a1z0/gimmick_ladder.motlist", "its motlist")
    T.eq(c.banks_applied[1].bank_id, 301, "the bank it stands for")
    T.eq(c.banks_applied[1].order, 5, "its order")
    T.eq(c.banks_applied[1].flags, 1, "its overwrite flags")
    T.eq(c.ash.set_bank_type, 1048576, "the host's bank variant")
    local l = c.ash.layers
    T.eq(#l, 2, "every layer")
    T.eq(l[2].bank, 9, "the upper-body layer's motion")
    T.near(l[2].blend, 0.75, 1e-4, "its blend rate")
    T.eq(l[2].mask, 12, "its joint mask")
    T.eq(l[2].mode, 1, "its blend mode")
    T.eq(pair.host.counters.banks_sent, 1, "sent once")
    -- Unchanged: not again until the resend; changed: at once.
    pair:seconds(3)
    T.eq(pair.host.counters.banks_sent, 1, "nothing new")
    h.dyn[2] = { path = "_chainsaw/animation/ch2a1z0/hide.motlist", bank_id = 302, bank_type = 0, mask_bit = 0,
        order = 0, flags = 0 }
    pair:seconds(1)
    T.eq(pair.host.counters.banks_sent, 2, "a new bank: sent")
    T.eq(#c.banks_applied, 2, "and taken")
    pair:seconds(10)
    T.eq(pair.host.counters.banks_sent, 3, "again after a while (a partner that just joined)")
    -- She goes over: the client's own banks are sent now, the host takes them.
    c.dyn = { { path = "_chainsaw/animation/ch2a1z0/client.motlist", bank_id = 400, bank_type = 0, mask_bit = 0,
        order = 0, flags = 0 } }
    pair.host:request(pair.now)
    pair:seconds(1.5)
    T.check(pair.client:runs_here(), "the client's game runs her")
    T.eq(h.banks_applied and h.banks_applied[1].bank_id, 400, "the host's puppet has the client's banks")
    -- Back to the host (its banks unchanged): sent again at once for the new switch.
    c.banks_applied = nil
    pair:seconds(5)
    pair.host:request(pair.now)
    pair:seconds(1)
    T.check(pair.host:runs_here(), "back with the host")
    T.eq(c.banks_applied and #c.banks_applied, 2, "the client's puppet has the host's banks again at once")
    -- Over to the client again, whose game shows no banks now: the host's puppet keeps none of
    -- the client's old ones.
    c.dyn = nil
    pair:seconds(5)
    pair.host:request(pair.now)
    pair:seconds(0.5)
    local sets = h.bank_sets
    pair:seconds(1)
    T.eq(h.bank_sets, sets, "no old banks are put on the host's puppet")
    -- A banks message of an old switch is not taken.
    pair.host:on_message({ type = P.T.ASHLEY_BANKS, epoch = (pair.host.epoch + 1) & 0xFF, banks = { { path = "x", bank_id = 1,
        bank_type = 0, mask_bit = 0, order = 0, flags = 0 } } }, pair.now)
    T.eq(pair.host.banks, nil, "another switch's banks: ignored")
end)

T.run("ashley_animation_messages_round_trip", function()
    local m = assert(P.decode(P.encode_ashley({ time = 3.5, epoch = 2, flags = P.ASHLEY_FLAGS.PRESENT | P.ASHLEY_FLAGS.OWNER,
        pos = { x = 1, y = 2, z = 3 }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 500, max_hp = 600, bank_type = 1048577,
        layers = { { bank = 7, id = 20, frame = 12.5, speed = 1, blend = 1, mask = 0, mode = 0 },
            { bank = 9, id = 3, frame = 2, speed = 0.5, blend = 0.25, mask = 77, mode = 2 },
            { bank = 11, id = 1, frame = 0, speed = 1 } } })))
    T.eq(m.bank_type, 1048577, "her bank variant")
    T.eq(#m.layers, 3, "three layers")
    T.near(m.layers[2].blend, 0.25, 1e-6, "blend rate")
    T.eq(m.layers[2].mask, 77, "joint mask")
    T.eq(m.layers[2].mode, 2, "blend mode")
    T.eq(m.layers[3].blend, nil, "a layer without them stays without them")
    T.eq(m.layers[3].mask, nil, "no mask")
    T.eq(m.layers[3].mode, nil, "no mode")
    local many = {}
    for i = 1, 12 do many[i] = { bank = i, id = i, frame = 0, speed = 1 } end
    m = assert(P.decode(P.encode_ashley({ time = 0, epoch = 0, flags = 3, layers = many })))
    T.eq(#m.layers, P.MAX_ASHLEY_LAYERS, "at most eight layers")
    local banks = {}
    for i = 1, 20 do
        banks[i] = { path = ("_chainsaw/animation/ch2a1z0/bank_%02d_with_a_long_enough_name.motlist"):format(i),
            bank_id = 300 + i, bank_type = i, mask_bit = 2 * i, order = -i, flags = i % 8 }
    end
    local bytes = P.encode_ashley_banks({ epoch = 7, banks = banks })
    T.check(#bytes > P.MAX_PAYLOAD, "bigger than one datagram (sent in fragments)")
    local b = assert(P.decode(bytes))
    T.eq(b.type, P.T.ASHLEY_BANKS, "the banks message")
    T.eq(b.epoch, 7, "its epoch")
    T.eq(#b.banks, 20, "every bank")
    T.eq(b.banks[20].path, banks[20].path, "the motlist")
    T.eq(b.banks[20].bank_id, 320, "the bank")
    T.eq(b.banks[20].bank_type, 20, "its type")
    T.eq(b.banks[20].mask_bit, 40, "its mask bit")
    T.eq(b.banks[20].order, -20, "its order")
    T.eq(b.banks[20].flags, 4, "its flags")
    T.eq(#assert(P.decode(P.encode_ashley_banks({ epoch = 1, banks = {} }))).banks, 0, "none")
    -- An Ashley layer's blend rate, mask and mode travel through the interpolation.
    local Interp = require("re4coop.interp")
    local out = Interp.blend_layers({ pos = { x = 0, y = 0, z = 0 }, layers = { { bank = 1, id = 2, frame = 0, speed = 1, blend = 0, mask = 5, mode = 1 } } },
        { pos = { x = 0, y = 0, z = 0 }, layers = { { bank = 1, id = 2, frame = 10, speed = 1, blend = 1, mask = 5, mode = 1 } } }, 0.5)
    T.near(out.layers[1].blend, 0.5, 1e-6, "the blend rate blends")
    T.eq(out.layers[1].mask, 5, "the mask")
    T.eq(out.layers[1].mode, 1, "the mode")
end)

T.run("the_game_not_running_her_never_shows_an_ashley_of_its_own", function()
    -- The host's game is still loading: it has not said where she is yet.
    local pair = make_pair({ client_ashley = { x = 40, y = 0, z = 0 } })
    local h, c = pair.host_game, pair.client_game
    h.loading = true
    pair:step(1)
    T.eq(c.puppet, true, "a puppet at once, before the host's game has said where she is")
    T.eq(c.visible, false, "and not drawn until it has")
    local x = c.ash.pos.x -- (her AI had one frame before the sync saw her)
    pair:seconds(1)
    T.eq(c.ash.pos.x, x, "she does not walk to the client's player meanwhile")
    h.loading = false
    pair:seconds(0.5)
    T.eq(c.visible, true, "drawn once the host's game said where she is")
    T.near(dist(c.ash.pos, h.ash.pos), 0, 0.05, "there")
    -- The host's game does not draw hers (a scripted moment): neither does the client's.
    h.ash.hidden = true
    pair:seconds(0.5)
    T.eq(c.visible, false, "hidden like the host's")
    h.ash.hidden = false
    pair:seconds(0.5)
    T.eq(c.visible, true, "drawn again")
    -- The host's game pauses its reports (a menu, a load): she stays as she was.
    h.loading = true
    pair:seconds(3)
    T.eq(c.visible, true, "still drawn where she was")
    T.eq(c.puppet, true, "still a puppet")
    h.loading = false
    -- The host's game has no Ashley now: the client's is not drawn, until she goes over.
    h.present = false
    pair:seconds(1)
    T.eq(c.visible, false, "the host's game has none: not drawn here either")
    T.eq(c.puppet, true, "and still no Ashley of the client's own")
    pair:seconds(5)
    T.check(pair.client:runs_here(), "she went over to the client")
    T.eq(c.puppet, false, "the client's game runs her")
    T.eq(c.visible, true, "drawn")
    T.check(pair.client.counters.hidden >= 2, "counted")
end)

T.run("another_ashley_is_removed_in_both_games", function()
    local pair = make_pair()
    local h, c = pair.host_game, pair.client_game
    pair:seconds(1)
    h.extras[1] = { key = "doll", doll = true }
    c.extras[1] = { key = "second", doll = false }
    pair:seconds(0.5)
    T.eq(#h.removed + #c.removed, 0, "not at once (a reload may hold two a moment)")
    pair:seconds(1)
    T.eq(h.removed[1], "doll", "the host's game removed its other Ashley")
    T.eq(c.removed[1], "second", "and the client's game its own")
    T.eq(pair.host.counters.extras, 1, "counted")
    T.eq(pair.client.counters.extras, 1, "counted")
    -- One that comes and goes within the moment stays.
    c.extras[1] = { key = "blink", doll = false }
    pair:seconds(0.8)
    c.extras = {}
    pair:step(1)
    c.extras[1] = { key = "blink", doll = false }
    pair:seconds(0.8)
    T.eq(#c.removed, 1, "a fresh appearance waits its moment again")
    pair:seconds(0.5)
    T.eq(c.removed[2], "blink", "then it is removed")
    -- Not during a cutscene of ours (it may use one of its own).
    h.cutscene = true
    h.extras[1] = { key = "scene", doll = true }
    pair:seconds(3)
    T.eq(#h.removed, 1, "left alone during the cutscene")
    h.cutscene = false
    pair:seconds(0.5)
    T.eq(h.removed[2], "scene", "removed after it")
    -- A removal the game refused is tried again, not every tick.
    c.refuse = true
    c.extras[1] = { key = "stubborn", doll = true }
    pair:seconds(1.5)
    c.refuse = false
    pair:seconds(1)
    T.eq(c.removed[3], nil, "waits before trying again")
    pair:seconds(1.5)
    T.eq(c.removed[3], "stubborn", "tried again")
end)

T.run("an_ashley_alone_in_the_world_is_left_alone", function()
    -- Neither game has her as a partner (a part of the story before she joins): a scripted
    -- Ashley is the only one there is.
    local pair = make_pair()
    local h, c = pair.host_game, pair.client_game
    h.present, c.present = false, false
    h.extras[1] = { key = "waiting", doll = true }
    c.extras[1] = { key = "waiting", doll = true }
    pair:seconds(4)
    T.eq(#h.removed + #c.removed, 0, "no shared Ashley: the scripted one stays in both")
    -- Switched off: nothing is removed.
    local off = make_pair({ settings = { ashley_single = false } })
    off.host_game.extras[1] = { key = "doll", doll = true }
    off:seconds(3)
    T.eq(#off.host_game.removed, 0, "switched off")
end)

-- The key the adapter gives a character (its object address).
local function R_addr(obj)
    return require("re4coop.reflect").address(obj)
end

local test_clock = 0 -- the adapter's clock (seconds)

local function fresh_game()
    package.loaded["re4coop.game"] = nil
    local world = mock.install()
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    test_clock = 0
    return require("re4coop.game").new(function() end, function() return test_clock end), world
end

T.run("our_game_finds_ashley_among_the_partners", function()
    local game, world = fresh_game()
    T.eq(game:ashley_read(true), nil, "no Ashley here")
    T.eq(game:capabilities().ashley.ok, false, "shown in Diagnostics")
    local luis = mock.make_character("chainsaw.PartnerBaseContext", { x = 9, y = 0, z = 9 }, 900)
    luis.kind_id = 200032
    local ashley = mock.make_ashley({ x = 4, y = 0, z = 1 }, 600)
    world.partners = { luis, ashley }
    world.partner = luis -- getPartnerContextRef returns the first partner
    local st = assert(game:ashley_read(true), "found in PartnerContextList")
    T.near(st.pos.x, 4, 1e-6, "her position")
    T.eq(st.hp, 600, "her HP")
    T.eq(st.max_hp, 600, "max HP")
    T.eq(st.alive, true, "alive")
    T.eq(st.busy, false, "free")
    T.check(st.layers ~= nil and #st.layers >= 1, "her animation layers")
    ashley.kidnapped = true
    T.eq(game:ashley_read(false).busy, true, "kidnapped: busy")
    ashley.kidnapped = false
    ashley.partner_state = 1 << 54 -- HidingLocker
    T.eq(game:ashley_read(false).busy, true, "hiding: busy")
    ashley.partner_state = 2 -- IdleTurn
    T.eq(game:ashley_read(false).busy, false, "turning: free")
    T.check(game:capabilities().ashley.ok, "shown in Diagnostics")
    -- Without the partner list (a build where it cannot be read): the first partner.
    world.no_partner_list = true
    world.partner = ashley
    T.check(game:ashley_read(false) ~= nil, "found through getPartnerContextRef")
    world.partner = luis
    T.eq(game:ashley_read(false), nil, "Luis is not Ashley")
end)

T.run("a_puppet_ashley_neither_follows_nor_can_be_grabbed_or_hurt_here", function()
    local game, world = fresh_game()
    local ashley = mock.make_ashley({ x = 10, y = 0, z = 0 }, 600)
    world.partner = ashley
    mock.run_frame()
    T.check(ashley.pos.x < 10, "her AI follows our player")
    T.check(game:ashley_set_puppet(true), "puppet")
    T.eq(ashley.head.update_self, false, "her AI head stops")
    T.eq(mock.component(ashley.body, "via.motion.MotionFsm2").enabled, false, "her animation state machine too")
    local x = ashley.pos.x
    for _ = 1, 10 do mock.run_frame() end
    T.eq(ashley.pos.x, x, "she does not follow our player")
    T.eq(mock.try_kidnap(ashley), false, "enemies of our game cannot grab her")
    T.eq(ashley.permit_attacked, false, "nor attack her")
    mock.hit(ashley, 200)
    T.eq(ashley.hp, 600, "our game takes no HP from her")
    T.check(game:ashley_set_transform({ x = 3, y = 0, z = 4 }, { x = 0, y = 0, z = 0, w = 1 }), "moved")
    T.near(ashley.pos.z, 4, 1e-6, "where the partner's is")
    T.check(game:ashley_set_anim({ { bank = 100, id = 77, frame = 5, speed = 1 } }), "animated")
    local layer = mock.component(ashley.body, "via.motion.Motion").layers[1]
    T.eq(layer.motion, 77, "playing the partner's motion")
    game:ashley_set_hp(0)
    T.eq(ashley.hp, 1, "never killed here")
    game:ashley_set_hp(350)
    T.eq(ashley.hp, 350, "the partner's HP")
    T.check(game:capabilities().ashley_puppet.ok, "shown in Diagnostics")
    -- Back to her own game.
    T.check(game:ashley_set_puppet(false), "released")
    T.eq(ashley.head.update_self, true, "her head runs again")
    T.eq(mock.component(ashley.body, "via.motion.MotionFsm2").enabled, true, "her animation state machine too")
    T.eq(ashley.no_damage, false, "she takes damage again")
    mock.run_frame()
    T.eq(ashley.permit_kidnapped, true, "her head allows grabs again")
    mock.hit(ashley, 100)
    T.eq(ashley.hp, 250, "hurt")
end)

T.run("a_puppet_keeps_her_own_no_damage_and_survives_a_reload", function()
    local game, world = fresh_game()
    local ashley = mock.make_ashley({ x = 2, y = 0, z = 0 }, 600)
    ashley.no_damage = true -- an event made her invulnerable
    world.partner = ashley
    game:ashley_set_puppet(true)
    game:ashley_set_puppet(false)
    T.eq(ashley.no_damage, true, "left as the game had it")
    -- Every tick the locks are asserted again (something of ours could have changed them).
    game:ashley_set_puppet(true)
    ashley.permit_kidnapped = true
    game:ashley_set_puppet(true)
    T.eq(ashley.permit_kidnapped, false, "locked again")
    -- A checkpoint: a new Ashley.
    local again = mock.make_ashley({ x = 5, y = 0, z = 0 }, 600)
    world.partner = again
    game:on_reload()
    T.eq(ashley.head.update_self, true, "the old one was put back")
    T.check(game:ashley_set_puppet(true), "the new one becomes the puppet")
    T.eq(again.head.update_self, false, "her head off")
    game:ashley_restore()
    T.eq(again.head.update_self, true, "the session ends: she runs again")
end)

T.run("our_game_removes_any_other_ashley_the_games_way", function()
    local game, world = fresh_game()
    local ashley = mock.make_ashley({ x = 2, y = 0, z = 0 }, 600)
    local second = mock.make_ashley({ x = 8, y = 0, z = 0 }, 600)
    second.spawn_param = mock.new("chainsaw.CharacterSpawnParam", { ctx = second, owner = mock.make_go("spawner") })
    local doll = mock.make_doll_ashley({ x = 20, y = 0, z = 0 }, true)
    local loose = mock.make_doll_ashley({ x = 30, y = 0, z = 0 }, false)
    local child = mock.make_go("ch2a1z0_hair")
    mock.set_parent(child.transform, loose.body.transform)
    -- Only scripted ones: none of them is our Ashley.
    world.partners, world.partner, world.dolls = {}, nil, { doll }
    T.eq(game:ashley_read(false), nil, "a doll is never our Ashley")
    T.eq(#game:ashley_extras(), 1, "but it is another one")
    world.partners = { ashley, second }
    world.partner = ashley
    world.dolls = { doll, loose }
    T.check(game:ashley_set_puppet(true), "ours is a puppet")
    local extras = game:ashley_extras()
    T.eq(#extras, 3, "the second partner and both dolls")
    T.eq(extras[1].doll, false, "a partner")
    T.eq(extras[2].doll, true, "a doll")
    -- Ours stays ours even when the game lists another Ashley first.
    world.partners = { second, ashley }
    T.eq(game:ashley_context(), ashley, "the one we use")
    T.eq(#game:ashley_extras(), 3, "the same three")
    T.eq(game:ashley_remove_extra(R_addr(second)), "erased", "the second partner")
    T.eq(second.spawn_param.invalid, true, "through its spawn param (CharacterSpawnParam.invalidateSpawn)")
    T.eq(#world.partners, 1, "gone from the game")
    T.eq(world.partners[1], ashley, "ours is still there")
    T.eq(game:ashley_remove_extra(R_addr(doll)), "erased", "the doll with a spawn param")
    T.eq(world.dolls[1], loose, "gone too")
    -- Without a spawn param: it can no longer think, be grabbed, hurt or seen.
    T.eq(game:ashley_remove_extra(R_addr(loose)), "hidden", "the doll without one")
    T.eq(loose.head.update_self, false, "its head stops")
    T.eq(loose.no_damage, true, "no damage")
    T.eq(loose.body.draw_self, false, "not drawn")
    T.eq(child.draw_self, false, "nor what hangs from it")
    T.check(game:capabilities().ashley_extra.ok, "shown in Diagnostics")
    T.eq(#game:ashley_extras(), 1, "only the hidden doll is left in the lists")
    T.eq(game:ashley_context(), ashley, "ours untouched")
    T.eq(ashley.head.update_self, false, "still our puppet")
    -- Never our own Ashley's spawn param, even if another Ashley points at it.
    local twin = mock.make_ashley({ x = 9, y = 0, z = 0 }, 600)
    ashley.spawn_param = mock.new("chainsaw.CharacterSpawnParam", { ctx = ashley, owner = mock.make_go("spawner") })
    twin.spawn_param = ashley.spawn_param
    world.partners = { ashley, twin }
    game:ashley_extras()
    T.eq(game:ashley_remove_extra(R_addr(twin)), "hidden", "hidden instead")
    T.check(ashley.spawn_param.invalid ~= true, "ours is never despawned")
end)

T.run("a_puppet_ashley_is_hidden_and_drawn_again", function()
    local game, world = fresh_game()
    local ashley = mock.make_ashley({ x = 2, y = 0, z = 0 }, 600)
    local hair, off = mock.make_go("ch2a1z0_hair"), mock.make_go("ch2a1z0_bag")
    mock.set_parent(hair.transform, ashley.body.transform)
    mock.set_parent(off.transform, ashley.body.transform)
    off.draw_self = false -- something the game does not draw
    world.partner = ashley
    game:ashley_set_puppet(true)
    T.check(game:ashley_set_visible(false), "hidden")
    T.check(game:ashley_set_visible(false), "asked again every tick")
    T.eq(ashley.body.draw_self, false, "her body")
    T.eq(hair.draw_self, false, "and what hangs from it")
    T.check(game:capabilities().ashley_hide.ok, "shown in Diagnostics")
    T.check(game:ashley_set_visible(true), "drawn")
    T.check(ashley.body.draw_self ~= false and hair.draw_self ~= false, "again")
    T.eq(off.draw_self, false, "what the game had hidden stays hidden")
    game:ashley_set_visible(false)
    game:ashley_set_puppet(false)
    T.check(ashley.body.draw_self ~= false, "released: drawn again")
    game:ashley_set_puppet(true)
    game:ashley_set_visible(false)
    game:ashley_restore()
    T.check(ashley.body.draw_self ~= false, "the session ends: drawn again")
end)

-- Her motion as the game sets it up: two layers, a bank (100) every variant has, one (120) only
-- the Battle variant has, and none of bank 301 (it comes in a dynamic bank).
local function strict_ashley(world, with_controller)
    local ashley = mock.make_ashley({ x = 2, y = 0, z = 0 }, 600)
    local motion = mock.component(ashley.body, "via.motion.Motion")
    motion.banks = { [100] = 0, [120] = 1048576 }
    if with_controller then mock.add_component(ashley.body, "chainsaw.MotionController", { motion = motion }) end
    world.partner = ashley
    return ashley, motion
end

T.run("a_puppet_ashley_plays_every_motion_hers_can", function()
    local game, world = fresh_game()
    local ashley, motion = strict_ashley(world, true)
    -- The owner's side: every layer in full, the bank variant, the dynamic banks.
    motion.bank_type = 64
    motion.layers[2].blend, motion.layers[2].mask, motion.layers[2].mode = 0.5, 33, 1
    motion.dynamic = { mock.make_dynamic_bank("_chainsaw/animation/ch2a1z0/own.motlist", 250, { order = 3, ow_id = true }) }
    local st = game:ashley_read(true)
    T.eq(st.bank_type, 64, "her bank variant")
    T.eq(#st.layers, 2, "both layers")
    T.near(st.layers[2].blend, 0.5, 1e-6, "blend rate")
    T.eq(st.layers[2].mask, 33, "joint mask")
    T.eq(st.layers[2].mode, 1, "blend mode")
    local r = game:ashley_read_banks()
    T.eq(#r.banks, 1, "her dynamic bank")
    T.eq(r.banks[1].path, "_chainsaw/animation/ch2a1z0/own.motlist", "its motlist")
    T.eq(r.banks[1].bank_id, 250, "the bank it stands for")
    T.eq(r.banks[1].order, 3, "its order")
    T.eq(r.banks[1].flags, 1, "OverwriteBankID")
    T.check(r.key ~= nil and r.key ~= "", "a key for the list")
    motion.dynamic = {}
    motion.bank_type = 0
    -- The puppet's side.
    game:ashley_set_puppet(true)
    local layer = motion.layers[1]
    T.check(game:ashley_set_anim({ { bank = 120, id = 5, frame = 3, speed = 1 } }, 1048576), "a Battle motion")
    T.eq(motion.bank_type, 1048576, "her bank variant first")
    T.eq(layer.bank, 120, "so the Battle motion is found")
    T.eq(layer.motion, 5, "and played")
    -- A motion of a bank only a dynamic bank brings: not found until the bank is here.
    local wanted = { { bank = 301, id = 9, frame = 0, speed = 1 } }
    game:ashley_set_anim(wanted, 1048576)
    T.eq(layer.motion, 5, "not found here yet")
    game:ashley_set_anim(wanted, 1048576)
    T.eq(game.ashley_anim.missing, 1, "counted once")
    T.check(game.ashley_anim.last_missing:find("bank 301 motion 9") ~= nil, "and named for Diagnostics")
    local tries = layer.not_found
    game:ashley_set_anim(wanted, 1048576)
    T.eq(layer.not_found, tries, "not asked again every tick")
    T.eq(game.ashley_anim.missing, 1, "still counted once")
    local banks = { { path = "_chainsaw/animation/ch2a1z0/gimmick_ladder.motlist", bank_id = 301, bank_type = 0, mask_bit = 0,
        order = 5, flags = 1 } }
    T.check(game:ashley_set_banks(banks, "k1"), "the owner's banks")
    T.eq(#motion.dynamic, 1, "added to her motion")
    T.eq(mock.component(ashley.body, "chainsaw.MotionController").adds, 1, "through her MotionController")
    local added = motion.dynamic[1]
    T.eq(added.motlist:call("get_ResourcePath"), "_chainsaw/animation/ch2a1z0/gimmick_ladder.motlist", "its motlist loaded")
    T.eq(added.bank_id, 301, "standing for bank 301")
    T.eq(added.order, 5, "in its order")
    T.eq(added.ow_id, true, "overwriting as the owner's")
    T.check(game:capabilities().ashley_banks.ok, "shown in Diagnostics")
    T.check(game:ashley_set_banks(banks, "k1"), "the same again")
    T.eq(#motion.dynamic, 1, "nothing added twice")
    test_clock = test_clock + 0.6
    game:ashley_set_anim(wanted, 1048576)
    T.eq(layer.motion, 9, "now it plays")
    -- The upper-body layer's blend rate, joint mask and blend mode.
    game:ashley_set_anim({ { bank = 301, id = 9, frame = 0, speed = 1 }, { bank = 100, id = 50, frame = 0, speed = 1, blend = 0.25,
        mask = 7, mode = 2 } }, 1048576)
    local arm = motion.layers[2]
    T.near(arm.blend, 0.25, 1e-6, "blend rate")
    T.eq(arm.mask, 7, "joint mask")
    T.eq(arm.mode, 2, "blend mode")
    T.check(game:capabilities().ashley_motion.ok, "shown in Diagnostics")
    -- A bank the owner no longer has goes; one our own game gave her stays.
    local own = mock.make_dynamic_bank("_chainsaw/animation/ch2a1z0/costume.motlist", 260)
    motion.dynamic[#motion.dynamic + 1] = own
    -- One her own game gave her too is not added twice.
    T.check(game:ashley_set_banks({ banks[1], { path = "_chainsaw/animation/ch2a1z0/costume.motlist", bank_id = 260,
        bank_type = 0, mask_bit = 0, order = 0, flags = 0 } }, "k1b"), "the owner has the costume bank too")
    T.eq(#motion.dynamic, 2, "it is already here: not added again")
    T.check(game:ashley_set_banks({}, "k2"), "the owner's banks changed")
    T.eq(#motion.dynamic, 1, "ours went")
    T.eq(motion.dynamic[1], own, "her own game's stayed")
    game:ashley_set_banks(banks, "k3")
    T.eq(#motion.dynamic, 2, "added again")
    -- She stops being a puppet: what we added goes, her bank variant comes back.
    game:ashley_set_puppet(false)
    T.eq(#motion.dynamic, 1, "the banks we added are gone")
    T.eq(motion.dynamic[1], own, "hers stay")
    T.eq(motion.bank_type, 0, "her bank variant as her game had it")
end)

T.run("without_a_motion_controller_the_banks_go_straight_into_her_motion", function()
    local game, world = fresh_game()
    local ashley, motion = strict_ashley(world, false)
    local own = mock.make_dynamic_bank("_chainsaw/animation/ch2a1z0/costume.motlist", 260)
    motion.dynamic = { own }
    game:ashley_set_puppet(true)
    local banks = { { path = "a.motlist", bank_id = 301, bank_type = 0, mask_bit = 0, order = 0, flags = 0 },
        { path = "b.motlist", bank_id = 302, bank_type = 0, mask_bit = 0, order = 0, flags = 0 } }
    T.check(game:ashley_set_banks(banks, "k"), "added")
    T.eq(#motion.dynamic, 3, "into her motion's own list")
    T.eq(motion.dynamic[1], own, "after hers")
    T.check((motion.dynamic_set or 0) >= 1, "through setDynamicMotionBankCount / setDynamicMotionBank")
    -- The one in the middle of the list goes (the list closes up behind it).
    local middle = motion.dynamic[2].bank_id
    local keep = middle == 301 and banks[2] or banks[1]
    T.check(game:ashley_set_banks({ keep }, "k2"), "one less")
    T.eq(#motion.dynamic, 2, "taken out")
    T.eq(motion.dynamic[1], own, "hers first")
    T.eq(motion.dynamic[2].bank_id, keep.bank_id, "the other kept")
    game:ashley_restore()
    T.eq(#motion.dynamic, 1, "the session ends: only hers")
end)

T.run("taking_her_over_far_away_uses_the_games_own_teleport", function()
    local game, world = fresh_game()
    local ashley = mock.make_ashley({ x = 50, y = 0, z = 0 }, 600)
    world.partner = ashley
    T.check(game:ashley_warp({ x = 1, y = 0, z = -1.5 }, { x = 0, y = 0, z = 0, w = 1 }), "warped")
    T.eq(ashley.set_transforms, 1, "CharacterContext.setTransform")
    T.near(ashley.pos.x, 1, 1e-6, "next to our player")
    T.check((ashley.body.warped or 0) >= 1, "her CharacterController follows")
    T.check(game:capabilities().ashley_warp.ok, "shown in Diagnostics")
end)

T.finish()
