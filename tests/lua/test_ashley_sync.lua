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
    local g = { player = copy3(player), present = true, puppet = false, moves = 0, anims = 0, hp_sets = {}, warps = {},
        ash = { pos = copy3(ashley), rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 600, max_hp = 600, alive = true,
            kidnapped = false, busy = false, frame = 0 } }
    function g:ashley_read(full)
        if not self.present then return nil end
        local a = self.ash
        local st = { pos = copy3(a.pos), rot = a.rot, hp = a.hp, max_hp = a.max_hp, alive = a.alive,
            kidnapped = a.kidnapped, busy = a.busy or a.kidnapped or not a.alive }
        if full then st.layers = { { bank = 7, id = a.walking and 20 or 10, frame = a.frame, speed = 1 } } end
        return st
    end
    function g:ashley_set_puppet(on)
        self.puppet = on
        return true
    end
    function g:ashley_set_transform(pos, rot)
        self.ash.pos, self.ash.rot = copy3(pos), rot
        self.moves = self.moves + 1
        return true
    end
    function g:ashley_set_anim(layers)
        self.ash.layers = layers
        self.anims = self.anims + 1
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
                    local_rot = { x = 0, y = 0, z = 0, w = 1 }, unable = g.cutscene })
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

local function fresh_game()
    package.loaded["re4coop.game"] = nil
    local world = mock.install()
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    return require("re4coop.game").new(function() end, function() return 0 end), world
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
