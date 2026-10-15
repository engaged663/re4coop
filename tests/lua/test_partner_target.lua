-- partner_target.lua: the client's player as a second player in the host's game, against a
-- fake game adapter, with every message going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local PartnerTarget = require("re4coop.partner_target")

-- A fake game: what game_partner.lua offers the logic.
local function fake_game()
    local g = { attached = false, attaches = {}, detaches = 0, updates = {}, noises = {}, damage = {},
        noise_out = {}, hits = {}, attach_ok = true, hit_result = "applied" }
    function g:partner_target_attach(root, opts)
        self.attaches[#self.attaches + 1] = { root = root, opts = opts }
        self.attached = self.attach_ok
        return self.attach_ok
    end
    function g:partner_target_attached() return self.attached end
    function g:partner_target_detach()
        self.detaches = self.detaches + 1
        self.attached = false
    end
    function g:partner_target_update(pos, rot, hp, max_hp)
        if not self.attached then return false end
        self.updates[#self.updates + 1] = { pos = pos, rot = rot, hp = hp, max_hp = max_hp }
        return not self.model_gone
    end
    function g:partner_noise(n)
        self.noises[#self.noises + 1] = n
        return true
    end
    function g:take_partner_damage_events()
        local q = self.damage
        self.damage = {}
        return q
    end
    function g:take_noise_events()
        local q = self.noise_out
        self.noise_out = {}
        return q
    end
    function g:player_take_hit(hit, attacker)
        self.hits[#self.hits + 1] = { hit = hit, attacker = attacker }
        return self.hit_result
    end
    return g
end

-- What enemy_net answers about the wire identity of enemies.
local enemies = {
    net_of_local = function(_, id)
        if id == 7 then return 42, 0x1234, 99 end
        return nil
    end,
    local_of_net = function(_, net_id, uid)
        if net_id == 42 or uid == 0x1234 then return 1007 end
        return nil
    end,
}

local function make(role, settings)
    local sent = {}
    local pt = PartnerTarget.new({ role = role, protocol = P, settings = settings or {}, enemies = enemies,
        send = function(bytes, reliable) sent[#sent + 1] = { m = assert(P.decode(bytes)), reliable = reliable } end })
    return pt, sent
end

local ROOT = { name = "re4coop_ch0a0z0_body" }
local function info(over)
    local i = { root = ROOT, pos = { x = 1, y = 0, z = 2 }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 800, max_hp = 1000 }
    for k, v in pairs(over or {}) do i[k] = v end
    return i
end

T.run("the_host_makes_the_clients_model_a_target_while_it_can_be_fought", function()
    local pt = make("host")
    local g = fake_game()
    pt:host_tick(0, g, info())
    T.eq(#g.attaches, 1, "attached")
    T.eq(g.attaches[1].root, ROOT, "the model's root")
    T.eq(g.attaches[1].opts.hits, true, "its hits on by default")
    T.eq(g.attaches[1].opts.grabs, true, "grabs on by default (the client breaks free)")
    T.eq(g.attaches[1].opts.parry, true, "warnings and parries on by default")
    T.eq(g.attaches[1].opts.bosses, true, "bosses on by default")
    pt:host_frame(g, info({ pos = { x = 3, y = 0, z = 4 }, hp = 700 }))
    T.near(g.updates[1].pos.x, 3, 1e-9, "the stand-in follows the client")
    T.eq(g.updates[1].hp, 700, "with its HP")
    for _, case in ipairs({ { "in a cutscene", { busy = true } }, { "in another area", { elsewhere = true } },
        { "our area loading", { loading = true } }, { "no model", { root = false } } }) do
        local over = case[2]
        if over.root == false then over.root = nil end
        local i = info(over)
        if case[1] == "no model" then i.root = nil end
        pt:host_tick(1, g, i)
        T.eq(g.attached, false, "let go: " .. case[1])
        pt:host_tick(2, g, info())
        T.eq(g.attached, true, "and back")
    end
    pt:host_tick(3, g, nil)
    T.eq(g.attached, false, "no fresh partner state: let go")
    T.eq(pt.counters.detaches, 5, "five times")
end)

T.run("the_host_retries_an_attach_that_failed_and_notices_a_lost_model", function()
    local pt = make("host")
    local g = fake_game()
    g.attach_ok = false
    pt:host_tick(0, g, info())
    pt:host_tick(0.5, g, info())
    T.eq(#g.attaches, 1, "not every tick")
    g.attach_ok = true
    pt:host_tick(2.5, g, info())
    T.eq(#g.attaches, 2, "tried again later")
    T.eq(pt.attached, true, "attached")
    g.model_gone = true -- the game unloaded the model
    pt:host_frame(g, info())
    T.eq(pt.attached, false, "noticed")
    g.model_gone = false
    pt:host_tick(3, g, info())
    T.eq(pt.attached, true, "attached to the rebuilt model")
end)

-- Protocol 14: warnings and parries, grabs.

-- The host's fake game also reports warnings, parries, holds and escapes.
local function host_game()
    local g = fake_game()
    g.signs, g.parried, g.holding, g.released = {}, {}, {}, {}
    function g:take_sign_events()
        local q = self.signs
        self.signs = {}
        return q
    end
    function g:enemy_partner_parry(id, kind, sign_type)
        self.parried[#self.parried + 1] = { id = id, kind = kind, sign_type = sign_type }
        return true
    end
    function g:partner_grabbers() return self.holding end
    function g:enemy_partner_release(id, how)
        self.released[#self.released + 1] = { id = id, how = how }
        self.holding[id] = nil
        return true
    end
    return g
end

-- The client's fake game: our player's head, input and grab.
local function client_game()
    local g = fake_game()
    g.shown, g.parry_out, g.presses, g.knife_press, g.let_go = {}, {}, 0, false, {}
    function g:player_action_sign(id, m)
        self.shown[#self.shown + 1] = { id = id, m = m }
        return true
    end
    function g:take_parry_events()
        local q = self.parry_out
        self.parry_out = {}
        return q
    end
    function g:player_grab_input(knife)
        if knife and self.knife_press then return "knife" end
        if self.presses > 0 then
            self.presses = self.presses - 1
            return "mash"
        end
        return nil
    end
    function g:player_grab_release(id, action)
        self.let_go[#self.let_go + 1] = { id = id, action = action }
        return true
    end
    return g
end

local PLAYABLE = { playable = true }

T.run("the_hosts_warnings_reach_the_client_with_the_blow_it_sees", function()
    local host, sent = make("host")
    local hg = host_game()
    host:host_tick(0, hg, info())
    hg.signs = { { id = 7, sign_type = 13, button = 1, just = true, act = true, angle_check = false },
        { id = 8, sign_type = 0 } } -- 8: an enemy the client has no number for
    host:host_tick(0.05, hg, info())
    T.eq(#sent, 1, "one warning sent (the unnumbered enemy's is not)")
    local m = sent[1].m
    T.eq(m.type, P.T.ACTION_SIGN, "an ACTION_SIGN")
    T.eq(sent[1].reliable, false, "unreliable: it repeats every frame")
    T.eq(m.net_id, 42, "the host's enemy")
    T.eq(m.sign_type, 13, "its sign type")
    T.eq(m.button, 1, "its button")
    T.eq(m.just, true, "just timing")

    local client = make("client", { enemy_interp_delay = 0.1 })
    local cg = client_game()
    client:on_message(m, 1.0)
    client:client_frame(1.05, cg, PLAYABLE)
    T.eq(#cg.shown, 0, "not before our copy shows the blow")
    client:client_frame(1.1, cg, PLAYABLE)
    T.eq(#cg.shown, 1, "then on our player's head")
    T.eq(cg.shown[1].id, 1007, "from our copy of that enemy")
    client:client_frame(1.12, cg, PLAYABLE)
    T.eq(#cg.shown, 2, "every frame while it lasts")
    client:client_frame(1.3, cg, PLAYABLE)
    T.eq(#cg.shown, 2, "over once the host stops repeating it")
    client:on_message(m, 2.0)
    client:client_frame(2.2, cg, { playable = false })
    T.eq(#cg.shown, 2, "never while we cannot play")
end)

T.run("the_clients_parry_staggers_the_hosts_enemy_and_its_blow_is_not_taken", function()
    local client, sent = make("client", { enemy_interp_delay = 0 })
    local cg = client_game()
    cg.parry_out = { { id = 7, kind = P.PARRY_KIND.PARRY, sign_type = 13, ok = true },
        { id = 7, kind = P.PARRY_KIND.INPUT, sign_type = 0, ok = true } }
    client:client_tick(1.0, cg, PLAYABLE)
    T.eq(#sent, 2, "both sent")
    T.eq(sent[1].m.type, P.T.ENEMY_PARRY, "an ENEMY_PARRY")
    T.eq(sent[1].reliable, true, "reliable")
    T.eq(sent[1].m.net_id, 42, "for the host's enemy")
    T.eq(sent[1].m.kind, P.PARRY_KIND.PARRY, "the parry")
    T.eq(sent[1].m.sign_type, 13, "of that attack")
    T.eq(sent[2].m.kind, P.PARRY_KIND.INPUT, "and the press")

    local host = make("host")
    local hg = host_game()
    host:host_tick(0, hg, info())
    host:on_message(sent[1].m, 1.0, hg)
    T.eq(#hg.parried, 1, "the host's enemy is parried")
    T.eq(hg.parried[1].id, 1007, "that enemy")
    T.eq(hg.parried[1].kind, P.PARRY_KIND.PARRY, "a parry")
    T.eq(hg.parried[1].sign_type, 13, "of that attack")

    -- The enemy's blow, struck in the host's game before it heard of the parry: not taken.
    local blow = assert(P.decode(P.encode_player_damage({ seq = 1, net_id = 42, uid = 0x1234, from_enemy = true,
        attack_id = 5, key_hash = 6, fields = {} })))
    client:on_message(blow, 1.2)
    client:client_tick(1.3, cg, PLAYABLE)
    T.eq(#cg.hits, 0, "the parried blow is not taken")
    T.eq(client.counters.hits_parried, 1, "counted")
    client:on_message(blow, 2.5)
    client:client_tick(2.6, cg, PLAYABLE)
    T.eq(#cg.hits, 1, "a later blow is")
end)

T.run("a_hold_on_the_client_lasts_until_the_client_breaks_free", function()
    local host, hsent = make("host")
    local hg = host_game()
    host:host_tick(0, hg, info())
    hg.holding[7] = { action = 0xBEEF, struggles = nil, knife = nil }
    host:host_tick(0.1, hg, info())
    T.eq(#hsent, 1, "the hold is sent")
    local m = hsent[1].m
    T.eq(m.type, P.T.PLAYER_GRAB, "a PLAYER_GRAB")
    T.eq(m.held, true, "held")
    T.eq(m.action, 0xBEEF, "with the grab's action")
    T.eq(m.struggles, 0, "presses unknown yet")
    host:host_tick(0.2, hg, info())
    T.eq(#hsent, 1, "not again at once")
    hg.holding[7].struggles, hg.holding[7].knife = 5, true
    host:host_tick(0.3, hg, info())
    T.eq(#hsent, 2, "again once the escape check said how many presses")
    T.eq(hsent[2].m.struggles, 5, "five")
    T.eq(hsent[2].m.knife, true, "or the knife")

    local client, csent = make("client", { enemy_interp_delay = 0.1 })
    local cg = client_game()
    client:on_message(m, 1.0)
    client:client_tick(1.05, cg, PLAYABLE)
    T.eq(client.grab, nil, "not before our copy shows the grab")
    client:client_tick(1.1, cg, PLAYABLE)
    T.eq(client.grab and client.grab.id, 1007, "held by our copy of that enemy")
    T.eq(client.grab and client.grab.struggles, 8, "the mod's default presses")
    client:on_message(hsent[2].m, 1.2)
    client:client_tick(1.3, cg, PLAYABLE)
    T.eq(client.grab.struggles, 5, "then the host's")
    T.eq(client:grab_status().presses, 0, "for the HUD")
    cg.presses = 4
    for i = 1, 6 do client:client_frame(1.3 + i * 0.016, cg, PLAYABLE) end
    T.eq(client.grab.presses, 4, "four presses counted")
    T.eq(#csent, 0, "not free yet")
    cg.presses = 1
    client:client_frame(1.5, cg, PLAYABLE)
    T.eq(client.grab, nil, "the fifth breaks free")
    T.eq(#cg.let_go, 1, "our character let go at once")
    T.eq(cg.let_go[1].id, 1007, "by our copy")
    T.eq(cg.let_go[1].action, 0xBEEF, "of that grab")
    T.eq(#csent, 1, "the host is told")
    T.eq(csent[1].m.type, P.T.GRAB_ESCAPE, "a GRAB_ESCAPE")
    T.eq(csent[1].m.how, P.ESCAPE_KIND.MASH, "by mashing")

    host:on_message(csent[1].m, 2.0, hg)
    T.eq(hg.released[1] and hg.released[1].id, 1007, "the host's enemy lets go")
    hg.holding[7] = nil -- (the fake's numbering: our enemy 7 is the one the client calls 1007)
    host:host_tick(2.1, hg, info())
    local last = hsent[#hsent].m
    T.eq(last.held, false, "the end of the hold is sent")
    client:on_message(last, 2.2)
    client:client_tick(2.4, cg, PLAYABLE)
    T.eq(#cg.let_go, 1, "our character was already free")
end)

T.run("a_knife_breaks_free_and_a_hold_the_host_ends_lets_go", function()
    local client, csent = make("client", { enemy_interp_delay = 0 })
    local cg = client_game()
    local held = assert(P.decode(P.encode_player_grab({ net_id = 42, uid = 0x1234, kind_hash = 99, held = true,
        struggles = 6, knife = true, action = 3 })))
    client:on_message(held, 1.0)
    client:client_tick(1.0, cg, PLAYABLE)
    cg.knife_press = true
    client:client_frame(1.1, cg, PLAYABLE)
    T.eq(csent[1] and csent[1].m.how, P.ESCAPE_KIND.KNIFE, "the knife broke free")

    cg.knife_press = false
    client:on_message(held, 2.0)
    client:client_tick(2.0, cg, PLAYABLE)
    T.check(client.grab ~= nil, "held again")
    local free = assert(P.decode(P.encode_player_grab({ net_id = 42, uid = 0x1234, kind_hash = 99, held = false, action = 3 })))
    client:on_message(free, 2.5)
    client:client_tick(2.5, cg, PLAYABLE)
    T.eq(client.grab, nil, "the host's enemy let go")
    T.eq(#cg.let_go, 2, "so our character is let go")

    -- Grabs switched off on the client: the hold is ignored (its damage still comes as a hit).
    local off = make("client", { enemy_interp_delay = 0, enemy_partner_grabs = false })
    off:on_message(held, 3.0)
    off:client_tick(3.0, cg, PLAYABLE)
    T.eq(off.grab, nil, "no hold")
end)

T.run("the_host_ends_a_hold_that_lasts_too_long", function()
    local host, hsent = make("host")
    local hg = host_game()
    host:host_tick(0, hg, info())
    hg.holding[7] = { action = 1 }
    host:host_tick(0.1, hg, info())
    hg.release_noop = true
    for t = 1, 16 do
        hg.holding[7] = hg.holding[7] or { action = 1 } -- an enemy kind that keeps holding
        host:host_tick(0.1 + t, hg, info())
    end
    T.eq(#hg.released, 1, "released once, after the longest hold")
    T.eq(host.counters.holds_timed_out, 1, "counted")
    T.check(#hsent >= 2, "repeated while it lasted")
end)

T.run("switched_off_the_host_never_attaches", function()
    local settings = { enemy_partner_target = false }
    local pt = make("host", settings)
    local g = fake_game()
    pt:host_tick(0, g, info())
    T.eq(#g.attaches, 0, "off")
    settings.enemy_partner_target = nil
    settings.enemy_partner_hits = false
    pt:host_tick(1, g, info())
    T.eq(g.attaches[1].opts.hits, false, "seen and heard, but not hittable")
    settings.sync_enemies = false
    pt:host_tick(2, g, info())
    T.eq(g.attached, false, "no enemy sync: let go")
end)

T.run("hits_on_the_model_go_to_the_client_with_the_enemys_identity", function()
    local pt, sent = make("host")
    local g = fake_game()
    pt:host_tick(0, g, info())
    local fields = { { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = 120 } }
    g.damage = { { id = 7, fields = fields, attack_id = 1100, key_hash = 0x77 }, { id = 8, fields = fields } }
    pt:host_tick(0.1, g, info())
    T.eq(#sent, 2, "both sent")
    local m = sent[1].m
    T.eq(m.type, P.T.PLAYER_DAMAGE, "as PLAYER_DAMAGE")
    T.eq(sent[1].reliable, true, "reliably")
    T.eq(m.net_id, 42, "the enemy's number")
    T.eq(m.uid, 0x1234, "its uid")
    T.eq(m.kind_hash, 99, "its kind")
    T.eq(m.attack_id, 1100, "the attack")
    T.eq(m.key_hash, 0x77, "its key")
    T.eq(m.fields[1].v, 120, "its values")
    T.eq(sent[2].m.net_id, 0, "an enemy the client does not have: no number")
    T.eq(pt.counters.hits_unpaired, 1, "counted")
    T.check(sent[2].m.seq ~= m.seq, "numbered")
end)

T.run("the_clients_noise_is_heard_in_the_hosts_game_while_attached", function()
    local host = make("host")
    local client, sent = make("client")
    local hg, cg = fake_game(), fake_game()
    -- Footsteps: the same noise again and again is sent once per step.
    cg.noise_out = {
        { pos = { x = 1, y = 0, z = 1 }, radius = 6, height = 2, volume = 0.3, sub = 1 },
        { pos = { x = 1.1, y = 0, z = 1 }, radius = 6, height = 2, volume = 0.3, sub = 1 },
        { pos = { x = 1, y = 0, z = 1 }, radius = 30, height = 4, volume = 1.0, sub = 0.2 }, -- a gunshot
    }
    client:client_tick(0, cg, { playable = true })
    T.eq(#sent, 1, "one message")
    T.eq(sent[1].reliable, false, "unreliable: noises are frequent and short-lived")
    T.eq(#sent[1].m.noises, 2, "the repeated step merged")
    T.eq(client.counters.noises_merged, 1, "counted")
    -- The host applies them only while the client's model is a target.
    host:on_message(sent[1].m, 0)
    host:host_tick(0, hg, nil)
    T.eq(#hg.noises, 0, "not attached: dropped")
    host:host_tick(0.1, hg, info())
    host:on_message(sent[1].m, 0.1)
    host:host_tick(0.2, hg, info())
    T.eq(#hg.noises, 2, "made in the host's game")
    T.eq(hg.noises[2].volume, 1.0, "the gunshot")
    -- The client sends at most every NOISE_INTERVAL; a step after the merge window is news again.
    cg.noise_out = { { pos = { x = 1, y = 0, z = 1 }, radius = 6, height = 2, volume = 0.3, sub = 1 } }
    client:client_tick(0.05, cg, { playable = true })
    T.eq(#sent, 1, "merged (too soon, same place)")
    cg.noise_out = { { pos = { x = 1, y = 0, z = 1 }, radius = 6, height = 2, volume = 0.3, sub = 1 } }
    client:client_tick(0.4, cg, { playable = true })
    T.eq(#sent, 2, "the next step")
end)

T.run("a_host_hit_lands_on_the_client_one_interpolation_delay_later", function()
    local client = make("client", { enemy_interp_delay = 0.1 })
    local g = fake_game()
    local m = assert(P.decode(P.encode_player_damage({ seq = 1, net_id = 42, uid = 0x1234, kind_hash = 99,
        from_enemy = true, attack_id = 1100, key_hash = 0x77,
        fields = { { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = 60 } } })))
    client:on_message(m, 10.0)
    client:client_tick(10.05, g, { playable = true })
    T.eq(#g.hits, 0, "not yet: our copy of the enemy shows the blow a moment later")
    client:client_tick(10.11, g, { playable = true })
    T.eq(#g.hits, 1, "now")
    T.eq(g.hits[1].attacker, 1007, "from our copy of that enemy")
    T.eq(g.hits[1].hit.attack_id, 1100, "with the attack's identity")
    T.eq(client.counters.hits_applied, 1, "applied")
    -- Dodged, failed, and not while we cannot be hit.
    g.hit_result = "blocked"
    client:on_message(m, 11)
    client:client_tick(11.2, g, { playable = true })
    T.eq(client.counters.hits_blocked, 1, "dodged")
    client:on_message(m, 12)
    client:client_tick(12.2, g, { playable = false })
    T.eq(client.counters.hits_dropped, 1, "loading or in a cutscene: dropped")
    client:on_message(m, 13)
    client:client_tick(13.2, g, { playable = true, dead = true })
    T.eq(client.counters.hits_dropped, 2, "dead: dropped")
end)

T.run("a_client_that_does_not_take_host_hits_drops_them", function()
    local client = make("client", { enemy_partner_hits = false })
    local g = fake_game()
    local m = assert(P.decode(P.encode_player_damage({ seq = 1, fields = {} })))
    client:on_message(m, 1)
    client:client_tick(2, g, { playable = true })
    T.eq(#g.hits, 0, "not taken")
    T.eq(client.counters.hits_dropped, 1, "dropped")
end)

T.run("shutdown_lets_go_of_the_model", function()
    local pt = make("host")
    local g = fake_game()
    pt:host_tick(0, g, info())
    pt:shutdown(g)
    T.eq(g.attached, false, "detached")
    T.eq(pt.attached, false, "forgotten")
end)

T.finish()
