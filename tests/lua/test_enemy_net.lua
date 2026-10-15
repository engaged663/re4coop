-- Two simulated game worlds (host + client) running EnemyNet against each other, with every
-- message going through the real protocol encoder/decoder. The host's game runs every enemy;
-- the client's shows them (protocol 13).
local T = require("testlib")
local P = require("re4coop.protocol")
local EnemyNet = require("re4coop.enemy_net")

local GANADO, DOG, CHIEF = "chainsaw.Ch1c0z0Context", "chainsaw.Ch1d1z1Context", "chainsaw.Ch1d0z0Context"
local HOST = P.OWNER.HOST

local function yaw_quat(yaw)
    return { x = 0, y = math.sin(yaw / 2), z = 0, w = math.cos(yaw / 2) }
end

-- The values a DamageInfo carries (two of them, enough to recognise a hit on the other side).
local function hit_fields(damage, wince)
    return { { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = damage },
        { h = P.hash("Wince"), t = P.HIT_VALUE.F32, v = wince or 10 } }
end

local function make_world(id_base)
    local w = { enemies = {}, next_id = id_base, calls = { set_hp = 0, kill = 0, erase = 0, transform = 0, anim = 0,
        apply = 0 }, puppet = {}, hidden = {}, applied = {}, kills = {}, save_dead = nil }

    -- uid: the enemy's level identity (the same on both machines), nil for runtime enemies.
    function w:spawn(kind, x, y, z, hp, uid)
        local e = { id = self.next_id, kind = kind, uid = uid, pos = { x = x, y = y, z = z }, rot = yaw_quat(0),
            hp = hp or 100, max_hp = hp or 100, alive = true,
            layers = { { bank = 100, id = 1, frame = 0, speed = 1 } } }
        self.next_id = self.next_id + 1
        table.insert(self.enemies, e)
        return e
    end

    function w:get(id)
        for _, e in ipairs(self.enemies) do
            if e.id == id then return e end
        end
    end

    function w:remove(e)
        for i, x in ipairs(self.enemies) do
            if x == e then table.remove(self.enemies, i) return end
        end
    end

    -- Level enemies our game has eliminated (dead for good: its context or its save backup).
    w.eliminated = {}
    function w:enemy_eliminated(uid) return self.eliminated[uid] == true end

    -- The enemy list the way game:list_enemies() returns it (fresh tables each call; layers
    -- and visibility only for the enemies the sync asks for).
    function w:list(want)
        local out = {}
        for _, e in ipairs(self.enemies) do
            local ask = want ~= nil and want(e.id)
            local layers
            if ask then
                layers = {}
                for i, l in ipairs(e.layers) do layers[i] = { bank = l.bank, id = l.id, frame = l.frame, speed = l.speed } end
            end
            out[#out + 1] = { id = e.id, kind = e.kind, uid = e.uid, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
                rot = { x = e.rot.x, y = e.rot.y, z = e.rot.z, w = e.rot.w }, hp = e.hp, max_hp = e.max_hp,
                alive = e.alive, hidden = ask and (e.drawn == false) or nil, layers = layers }
        end
        return out
    end

    -- Its own game hurting it (our AI fighting, an explosion...).
    function w:damage(e, amount)
        e.hp = math.max(0, e.hp - amount)
        if e.hp == 0 then e.alive = false end
    end

    -- game adapter
    function w:enemy_set_hp(id, hp)
        local e = self:get(id)
        if not e then return false end
        self.calls.set_hp = self.calls.set_hp + 1
        e.hp = math.max(1, hp)
        return true
    end
    function w:enemy_get_hp(id)
        local e = self:get(id)
        return e and e.hp or nil
    end
    function w:enemy_kill(id, fields, by)
        local e = self:get(id)
        if not e or self.refuse_kill then return false end
        self.calls.kill = self.calls.kill + 1
        self.kills[#self.kills + 1] = { id = id, fields = fields, puppet = self.puppet[id] == true,
            pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }, by = by }
        e.hp, e.alive = 0, false
        return true
    end
    -- Erasing despawns the enemy (it leaves the list). no_erase: no spawn param.
    function w:enemy_erase(id)
        local e = self:get(id)
        if not e or self.no_erase then return false end
        self.calls.erase = self.calls.erase + 1
        e.erased = true
        self:remove(e)
        self.invalid_spawns = (self.invalid_spawns or 0) + 1
        return true
    end
    -- Undoing an erase: the spawn param may spawn it again.
    function w:enemy_restore_spawns()
        local n = self.invalid_spawns or 0
        self.invalid_spawns = 0
        self.restored = (self.restored or 0) + n
        return n
    end
    -- A partner's hit, through the "hit code": its Damage value comes off the HP.
    function w:enemy_apply_hit(id, hit)
        local e = self:get(id)
        if not e or self.no_hit_code then return false end
        self.calls.apply = self.calls.apply + 1
        local dmg = 0
        for _, f in ipairs(hit.fields or {}) do
            if f.h == P.hash("Damage") then dmg = f.v end
        end
        self.applied[#self.applied + 1] = { id = id, damage = dmg }
        e.last_hit = hit.fields
        self:damage(e, dmg)
        return true
    end
    function w:enemy_last_hit(id)
        local e = self:get(id)
        return e and e.last_hit
    end
    function w:enemy_set_puppet(id, on)
        if not self:get(id) then return false end
        self.puppet[id] = on or nil
        return true
    end
    function w:enemy_is_puppet(id) return self.puppet[id] == true end
    function w:enemy_set_transform(id, pos, rot)
        local e = self:get(id)
        if not e then return false end
        self.calls.transform = self.calls.transform + 1
        e.pos = { x = pos.x, y = pos.y, z = pos.z }
        if rot then e.rot = { x = rot.x, y = rot.y, z = rot.z, w = rot.w } end
        return true
    end
    function w:enemy_set_anim(id, layers)
        local e = self:get(id)
        if not e then return false end
        self.calls.anim = self.calls.anim + 1
        e.played = layers
        return true
    end
    function w:enemy_set_visible(id, on)
        self.hidden[id] = (not on) or nil
        return true
    end
    -- Spawning an enemy our game never spawned (its level spawn param, by uid): spawnable[uid]
    -- = { kind, pos } when the spawn param is loaded here.
    w.spawnable, w.revives = {}, {}
    function w:enemy_revive(uid)
        self.revives[#self.revives + 1] = uid or false
        local sp = self.spawnable[uid]
        if sp == nil then return "missing" end
        self.spawnable[uid] = nil
        self:spawn(sp.kind, sp.pos.x, sp.pos.y, sp.pos.z, 100, uid)
        return "spawning"
    end
    -- Host: the client's finishers run on our enemies (refuse_fatal: the enemy's head says no),
    -- and what our enemies say about the client's player (pinfo[id] = { bits, ftype }).
    w.fatals, w.pinfo, w.info_asked = {}, {}, {}
    function w:enemy_partner_fatal(id, kind, ftype)
        if not self:get(id) or self.refuse_fatal then return false end
        self.fatals[#self.fatals + 1] = { id = id, kind = kind, ftype = ftype }
        return true
    end
    function w:enemy_partner_info(id, near)
        self.info_asked[id] = near
        local p = self.pinfo[id]
        if p == nil then return P.PARTNER_INFO.KNOWN, 0 end
        return p[1], p[2]
    end

    -- The save's eliminated enemies, read over several calls like the real backup table.
    function w:scan_eliminated()
        if self.save_dead == nil then return true, {} end
        self.scan_calls = (self.scan_calls or 0) + 1
        if self.scan_calls < 3 then return false, nil end
        self.scan_calls = 0
        return true, self.save_dead
    end

    return w
end

local function make_pair(settings)
    settings = settings or {}
    for k, v in pairs({ snapshot_hz = 20, roster_hz = 10 }) do
        if settings[k] == nil then settings[k] = v end
    end
    local pair = { now = 0, host_world = make_world(1000), client_world = make_world(5000), to_host = {}, to_client = {},
        host_kills = {}, client_kills = {}, sent = { host = {}, client = {} },
        host_player = { x = 0, y = 0, z = -5 }, client_player = { x = 0, y = 0, z = -5 },
        host_events = {}, client_events = {} }
    pair.settings = settings
    local function count(side, bytes)
        local t = bytes:byte(1)
        pair.sent[side][t] = (pair.sent[side][t] or 0) + 1
    end
    pair.host = EnemyNet.new({ role = "host", protocol = P, settings = settings,
        send = function(bytes) table.insert(pair.to_client, bytes) count("host", bytes) end,
        on_kill = function(id) pair.host_kills[#pair.host_kills + 1] = id end })
    pair.client = EnemyNet.new({ role = "client", protocol = P, settings = settings,
        send = function(bytes) table.insert(pair.to_host, bytes) count("client", bytes) end,
        on_kill = function(id) pair.client_kills[#pair.client_kills + 1] = id end })

    function pair:deliver_to_client()
        local q = self.to_client
        self.to_client = {}
        for _, bytes in ipairs(q) do
            local m = assert(P.decode(bytes))
            if not (self.drop_to_client or (self.drop_types and self.drop_types[m.type])) then
                self.client:on_message(m, self.now, self.client_world)
            end
        end
    end
    function pair:deliver_to_host()
        local q = self.to_host
        self.to_host = {}
        for _, bytes in ipairs(q) do
            if not self.drop_to_host then self.host:on_message(assert(P.decode(bytes)), self.now, self.host_world) end
        end
    end

    function pair:tick_side(sync, world, events, me, partner)
        if #events > 0 then
            sync:on_local_hits(events, self.now)
            for i = #events, 1, -1 do events[i] = nil end
        end
        sync:tick(self.now, world:list(function(id) return sync:wants_state(id) end), world,
            { local_pos = me, partner_pos = partner, loading = sync == self.client and self.client_loading or nil })
        sync:frame(self.now, world)
    end

    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.05
            self:tick_side(self.host, self.host_world, self.host_events, self.host_player, self.client_player)
            self:deliver_to_client()
            self:tick_side(self.client, self.client_world, self.client_events, self.client_player, self.host_player)
            self:deliver_to_host()
        end
    end

    -- Our player hits `e` in `world`, the way game.lua's hook reports it: a puppet's hit can
    -- never kill it here (enemy_hit_predict), the rest of the damage happens at once.
    function pair:player_hit(side, e, damage)
        local world = side == "host" and self.host_world or self.client_world
        local events = side == "host" and self.host_events or self.client_events
        local hp = e.hp
        local local_damage = damage
        if world.puppet[e.id] and damage >= hp then local_damage = hp - 1 end
        world:damage(e, local_damage)
        e.last_hit = hit_fields(damage)
        events[#events + 1] = { id = e.id, damage = damage, hp = hp, local_damage = local_damage, lethal = damage >= hp,
            fields = hit_fields(damage) }
    end

    -- The client's player starts a finisher on puppet `e`, the way game_partner.lua's hooks on
    -- the puppet's AI head report it (the puppet itself does nothing).
    function pair:fatal(side, e, kind, ftype)
        local sync = side == "host" and self.host or self.client
        sync:on_local_fatal({ { id = e.id, kind = kind or P.FATAL_KIND.KILL, ftype = ftype or 0,
            pos = { x = 0, y = 0, z = 0 }, yaw = 0 } }, self.now)
    end

    return pair
end

local function net_of(sync, e)
    local l = sync.locals[e.id]
    return l and l.net_id
end

local function owner_of(pair, h)
    local net = pair.host.nets[net_of(pair.host, h)]
    return net and net.owner, net and net.epoch
end

-- The same level spawned on two machines: same uids, but each game placed its enemies on
-- its own (different positions, ids and list order).
local function standard_level(pair)
    local h, c = {}, {}
    h.a = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x1001)
    h.b = pair.host_world:spawn(GANADO, 10, 0, 0, 100, 0x1002)
    h.c = pair.host_world:spawn(CHIEF, 0, 0, 10, 300, 0x1003)
    c.c = pair.client_world:spawn(CHIEF, 0.2, 0, 10.1, 300, 0x1003)
    c.b = pair.client_world:spawn(GANADO, 10.3, 0, -0.2, 100, 0x1002)
    c.a = pair.client_world:spawn(GANADO, -0.4, 0.1, 0.3, 100, 0x1001)
    return h, c
end

-------------------------------------------------------------------------------
-- Identity
-------------------------------------------------------------------------------

T.run("pairs_by_level_identity_wherever_each_game_put_them", function()
    local pair = make_pair()
    local ha = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x2001)
    local hb = pair.host_world:spawn(GANADO, 1, 0, 0, 100, 0x2002)
    local hc = pair.host_world:spawn(GANADO, 2, 0, 0, 100, 0x2003)
    local cc = pair.client_world:spawn(GANADO, 40, 0, 7, 100, 0x2003)
    local ca = pair.client_world:spawn(GANADO, 1, 0, 0, 100, 0x2001)
    local cb = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x2002) -- standing exactly where the host's A is
    pair:step(5)
    T.eq(net_of(pair.client, ca), net_of(pair.host, ha), "A paired with A")
    T.eq(net_of(pair.client, cb), net_of(pair.host, hb), "B paired with B, not with the A standing on its spot")
    T.eq(net_of(pair.client, cc), net_of(pair.host, hc), "C paired with C 40 m away")
    T.eq(pair.client.counters.uid_pairs, 3, "all three by uid")
    T.eq(pair.client.counters.spatial_pairs, 0, "none by position")
end)

T.run("different_enemies_never_pair_even_on_the_same_spot", function()
    local pair = make_pair()
    pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x3001)
    local other = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x3002)
    local runtime = pair.client_world:spawn(GANADO, 0.1, 0, 0, 100, nil)
    pair:step(10)
    T.eq(net_of(pair.client, other), nil, "another level enemy is never taken for it")
    T.eq(net_of(pair.client, runtime), nil, "nor a runtime enemy")
end)

T.run("runtime_enemies_pair_by_kind_and_spawn_point", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(DOG, 5, 0, 5, 80, nil)
    local wrong_kind = pair.client_world:spawn(GANADO, 5, 0, 5, 80, nil)
    local c = pair.client_world:spawn(DOG, 5.5, 0, 4.8, 80, nil)
    pair:step(5)
    T.eq(net_of(pair.client, c), net_of(pair.host, h), "the dog pairs with the dog")
    T.eq(net_of(pair.client, wrong_kind), nil, "not with a villager on the same spot")
    T.eq(pair.client.counters.spatial_pairs, 1, "by position")
end)

T.run("a_context_reused_for_another_enemy_is_a_new_enemy", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x3101)
    pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x3101)
    pair:step(5)
    local first = net_of(pair.host, h)
    h.uid, h.kind = 0x3102, DOG -- the game gave this context to the next enemy
    pair:step(3)
    T.check(net_of(pair.host, h) ~= first, "new number for the new enemy")
    T.eq(pair.host.counters.retired, 1, "the old number was retired (the client had it)")
end)

-------------------------------------------------------------------------------
-- Authority: the host's, always
-------------------------------------------------------------------------------

T.run("every_enemy_is_the_hosts_wherever_the_players_are", function()
    local pair = make_pair()
    pair.host_player = { x = -60, y = 0, z = 0 }
    pair.client_player = { x = 9, y = 0, z = 0 } -- right next to B, far from the host
    local h, c = standard_level(pair)
    pair:step(80)
    for k in pairs(h) do
        T.eq(owner_of(pair, h[k]), HOST, k .. " is the host's")
        T.eq(pair.host_world.puppet[h[k].id], nil, k .. " runs on the host's AI")
        T.eq(pair.client_world.puppet[c[k].id], true, k .. " is a puppet on the client")
        T.eq(pair.client.nets[net_of(pair.client, c[k])].epoch, 1, k .. " numbered once")
    end
    T.eq(pair.host.counters.assigned, 3, "each numbered for the client once")
    local s = pair.client:summary()
    T.eq(s.authority, "host", "host authority")
    T.eq(s.puppets, 3, "the client shows three")
end)

T.run("a_puppet_switched_back_on_behind_the_syncs_back_is_switched_off_again", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    T.eq(pair.client_world.puppet[c.a.id], true, "the client's A follows the host's")
    -- The game adapter runs A's own AI again by itself (a death it ran, a head linked again).
    pair.client_world.puppet[c.a.id] = nil
    pair:step(2)
    T.eq(pair.client_world.puppet[c.a.id], true, "A is a puppet again: its own AI does not run in both games")
    T.eq(pair.client:summary().counters.puppet_lost, 1, "counted")
    T.eq(owner_of(pair, h.a), HOST, "still the host's")
end)

T.run("the_client_shooting_an_enemy_never_takes_it_over", function()
    -- 0.9 gave an enemy to the game of the player closest to it or shooting it. Now the client
    -- shoots it from point blank for a long time: it stays the host's, every hit runs there.
    local pair = make_pair()
    pair.host_player = { x = -40, y = 0, z = 0 }
    pair.client_player = { x = 1, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100000, 0x4111)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 100000, 0x4111)
    pair:step(5)
    for _ = 1, 100 do
        pair:player_hit("client", c, 1)
        pair:step(1)
    end
    T.eq(owner_of(pair, h), HOST, "the host's")
    T.eq(pair.client_world.puppet[c.id], true, "the client's copy never ran")
    T.eq(#pair.host_world.applied, 100, "every hit ran in the host's game")
    T.eq(pair.host.counters.assigned, 1, "numbered once, never handed over")
end)

T.run("the_reaction_to_a_partners_hit_goes_out_at_once", function()
    local pair = make_pair({ snapshot_hz = 2 })
    local h, c = standard_level(pair)
    pair:step(10)
    -- Right after one of the host's regular states (the next is half a second away).
    for _ = 1, 20 do
        if pair.host.last_state_send == pair.now then break end
        pair:step(1)
    end
    local early = pair.host.counters.states_early or 0
    pair:player_hit("client", c.a, 10)
    pair:step(1) -- the client sends it; the host runs it
    h.a.layers = { { bank = 100, id = 9, frame = 0, speed = 1 } } -- its reaction
    pair:step(1)
    T.eq((pair.host.counters.states_early or 0) - early, 1, "the host sent its state without waiting")
    T.eq(c.a.played[1].id, 9, "the shooter sees the reaction at once")
    T.check((pair.client.counters.fresh_anims or 0) > 0, "not one interpolation delay later")
end)

T.run("a_host_enemy_that_left_the_hosts_world_leaves_the_clients_copy_waiting_unseen", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4501)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x4501)
    pair:step(8)
    T.eq(pair.client_world.hidden[c.id], nil, "shown while the host has it")
    pair.host_world:remove(h) -- the host's area unloaded
    pair:step(140)
    T.eq(net_of(pair.client, c), nil, "no longer paired")
    T.eq(pair.client_world.puppet[c.id], true, "the client's copy never runs on its own")
    T.eq(pair.client_world.hidden[c.id], true, "and waits unseen")
    table.insert(pair.host_world.enemies, h) -- the host's area loads it again
    pair:step(10)
    T.eq(net_of(pair.client, c), net_of(pair.host, h), "paired again")
    T.eq(pair.client_world.hidden[c.id], nil, "shown again")
end)

-- El Gigante: its death is a cutscene (Ch1f0z0HeadUpdater.onDead -> die demo); the game then
-- removes it eliminated, without the list ever showing it dead.
local GIGANTE = "chainsaw.Ch1f0z0Context"

T.run("a_boss_whose_death_removes_it_dies_in_the_partners_game_too", function()
    local pair = make_pair()
    pair.host_player = { x = 3, y = 0, z = 0 }
    pair.client_player = { x = 30, y = 0, z = 0 }
    local h = pair.host_world:spawn(GIGANTE, 0, 0, 0, 5000, 0x4601)
    local c = pair.client_world:spawn(GIGANTE, 0, 0, 0, 5000, 0x4601)
    pair:step(8)
    T.eq(owner_of(pair, h), HOST, "the host's game runs it")
    T.eq(pair.client_world.puppet[c.id], true, "the client's copy follows it")
    -- The host's player kills it: its death cutscene plays and the game takes it away.
    pair.host_world.eliminated[0x4601] = true
    pair.host_world:remove(h)
    pair:step(6)
    T.check(not c.alive, "the client's Gigante dies too (it used to be let go, alive)")
    T.eq(pair.client_world.calls.kill, 1, "killed once")
    T.eq(pair.host.counters.vanished_deaths, 1, "the host announced it")
    T.eq(pair.host.dead[0x4601] ~= nil, true, "in the host's graveyard")
    pair:step(20)
    T.eq(pair.client_world.calls.kill, 1, "only once")
end)

T.run("a_boss_that_unloaded_and_came_back_is_checked_again_when_it_dies", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(GIGANTE, 0, 0, 0, 5000, 0x4604)
    local c = pair.client_world:spawn(GIGANTE, 0, 0, 0, 5000, 0x4604)
    pair:step(8)
    pair.host_world:remove(h) -- its area unloads for a moment (not a death)
    pair:step(2)
    table.insert(pair.host_world.enemies, h) -- and loads again
    pair:step(8)
    T.check(c.alive, "still alive for the client")
    pair.host_world.eliminated[0x4604] = true
    pair.host_world:remove(h)
    pair:step(6)
    T.check(not c.alive, "its real death crosses")
end)

T.run("an_enemy_that_only_unloaded_is_not_a_death_and_the_client_never_decides_one", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(GIGANTE, 0, 0, 0, 5000, 0x4603)
    local c = pair.client_world:spawn(GIGANTE, 0, 0, 0, 5000, 0x4603)
    pair:step(8)
    -- The client's area unloads its copy, which its save has dead (another session).
    pair.client_world.eliminated[0x4603] = true
    pair.client_world:remove(c)
    pair:step(6)
    T.check(h.alive, "the host's lives on")
    T.eq(pair.client.counters.vanished_deaths, nil, "the client announced nothing")
    T.eq(pair.client.counters.deaths_sent, 0, "the client never announces deaths")
    -- The host's area unloads it, not eliminated: not a death.
    pair.host_world:remove(h)
    pair:step(6)
    T.eq(pair.host.counters.vanished_deaths, nil, "the host announced nothing")
end)

-------------------------------------------------------------------------------
-- State: transform, animation, visibility, HP
-------------------------------------------------------------------------------

T.run("puppets_follow_position_rotation_and_animation", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    for i = 1, 10 do
        h.b.pos = { x = 10 + i * 0.6, y = 0, z = 0 }
        h.b.rot = yaw_quat(0.1 * i)
        h.b.layers = { { bank = 100, id = 7, frame = i * 2.0, speed = 1.25 }, { bank = 300, id = 2, frame = 5, speed = 1 } }
        pair:step(1)
    end
    pair:step(8)
    T.near(c.b.pos.x, 16, 0.05, "reached the host's position")
    T.near(c.b.rot.y, math.sin(0.5), 0.01, "and rotation")
    T.check(pair.client_world.calls.transform > 5, "moved over several frames, not one snap")
    T.eq(c.b.played[1].id, 7, "plays the host's motion")
    T.eq(c.b.played[1].speed, 1.25, "at its speed")
    T.near(c.b.played[1].frame, 20, 0.5, "at its frame")
    T.eq(c.b.played[2].bank, 300, "second layer too")
    T.eq(pair.client_world.puppet[c.b.id], true, "its own AI and animation driver off")
    T.eq(pair.host_world.calls.transform, 0, "the host's enemies are never moved by the sync")
    T.eq(pair.host_world.calls.anim, 0, "nor animated by it")
end)

T.run("a_copy_spawned_elsewhere_jumps_to_the_hosts_enemy", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0xD001)
    pair:step(5)
    local c = pair.client_world:spawn(GANADO, 35, 0, 12, 100, 0xD001)
    pair:step(8)
    T.near(c.pos.x, 0, 0.01, "moved to where the host's copy is")
    T.near(c.pos.z, 0, 0.01, "in every axis")
    T.check(h.alive, "untouched on the host")
end)

T.run("an_enemy_the_host_does_not_draw_is_not_drawn", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    h.a.drawn = false
    pair:step(3)
    T.eq(pair.client_world.hidden[c.a.id], true, "hidden like the host's")
    h.a.drawn = nil
    pair:step(3)
    T.eq(pair.client_world.hidden[c.a.id], nil, "shown again")
end)

T.run("damage_the_host_takes_shows_up_on_the_puppet", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.host_world:damage(h.c, 120) -- the host's player shot the chief
    pair:step(3)
    T.eq(c.c.hp, 180, "the client's chief has the host's HP")
end)

-------------------------------------------------------------------------------
-- Hits
-------------------------------------------------------------------------------

T.run("a_hit_of_the_clients_player_is_run_by_the_hosts_game", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair:player_hit("client", c.a, 30)
    pair:step(1)
    T.eq(#pair.host_world.applied, 1, "the host's game ran the hit")
    T.eq(pair.host_world.applied[1].damage, 30, "with the values of the client's hit")
    T.eq(h.a.hp, 70, "the host's villager lost the HP")
    pair:step(4)
    T.eq(c.a.hp, 70, "the client's copy agrees")
    T.eq(pair.client.counters.damage_reported, 0, "the client's own hit is not reported again as damage")
end)

T.run("the_hp_of_a_hit_in_flight_is_not_given_back", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.drop_to_host = true -- the hit is still on its way
    pair:player_hit("client", c.b, 25)
    pair:step(4)
    T.eq(c.b.hp, 75, "the host's older state does not heal it")
    pair.drop_to_host = false
    pair:step(30)
    T.eq(c.b.hp, 100, "a hit the host never ran is undone once it is overdue")
    T.eq(h.b.hp, 100, "(the host never got it)")
end)

T.run("a_puppet_never_dies_from_our_hit_the_host_decides", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair:player_hit("client", c.a, 500) -- far more than its HP
    T.eq(c.a.hp, 1, "our game cannot kill the puppet")
    T.check(c.a.alive, "it is still alive here")
    pair:step(3)
    T.check(not h.a.alive, "the host's game killed it")
    T.check(not c.a.alive, "and the client's copy died from the host's death notice")
    local k = pair.client_world.kills[1]
    T.check(k ~= nil and k.fields ~= nil and k.fields[1].v == 500, "killed with the same killing hit")
    T.eq(k.puppet, false, "with its own AI back on for its death")
    T.eq(k.by, "self", "the client's own player's hit")
    T.eq(#pair.client_kills, 1, "the client rolls its loot for it")
    T.eq(pair.host.dead_count, 1, "buried on the host")
    T.eq(pair.host.counters.client_kills, 1, "the host counts it as the client's kill")
end)

T.run("the_hosts_kill_is_the_hosts_for_the_client", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair:player_hit("client", c.b, 10) -- the client hit it a while ago...
    pair:step(80)
    pair:player_hit("host", h.b, 200) -- ...the host's player kills it
    pair.host_world:damage(h.b, 200)
    pair:step(3)
    T.check(not c.b.alive, "dead for the client")
    T.eq(pair.client_world.kills[1].by, "partner", "killed by the host's hit (the partner's model attacks)")
    T.eq(pair.host.counters.client_kills, 0, "not the client's kill")
end)

T.run("hits_of_the_hosts_player_are_only_shown_to_the_client", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair:player_hit("host", h.a, 10)
    pair:step(1)
    T.eq(#pair.client_world.applied, 0, "nothing to run on the client")
    T.eq(#pair.client:recent_partner_hits(pair.now, 1.0), 1, "a tracer to draw")
    pair:step(3)
    T.eq(c.a.hp, 90, "the HP arrives with the host's state")
end)

T.run("other_damage_to_a_puppet_goes_to_the_host", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.client_world:damage(c.c, 50) -- a barrel exploded next to it in the client's game
    pair:step(3)
    T.eq(pair.client.counters.damage_reported, 1, "reported to the host")
    T.eq(h.c.hp, 250, "the host applied it")
    T.eq(c.c.hp, 250, "and both agree")
end)

T.run("without_hit_code_the_host_applies_the_damage_as_hp", function()
    local pair = make_pair()
    pair.host_world.no_hit_code = true
    local h, c = standard_level(pair)
    pair:step(5)
    pair:player_hit("client", c.a, 30)
    pair:step(2)
    T.eq(h.a.hp, 70, "subtracted")
    T.eq(pair.host.counters.hits_fallback, 1, "as plain HP")
    pair:player_hit("client", c.a, 70)
    pair:step(3)
    T.check(not h.a.alive, "a lethal amount kills")
    T.eq(pair.host_world.kills[1].by, "partner", "the client's player killed it")
end)

-------------------------------------------------------------------------------
-- Finishers (stealth kill, knife finish, stomp, kicks)
-------------------------------------------------------------------------------

T.run("the_host_says_which_finishers_each_enemy_offers_the_client", function()
    local pair = make_pair()
    pair.client_player = { x = 0, y = 0, z = -2 }
    local h, c = standard_level(pair)
    local I = P.PARTNER_INFO
    pair.host_world.pinfo[h.a.id] = { I.KNOWN | I.FATAL | I.TARGETS, 1 }
    pair:step(6)
    local pinfo, ftype = pair.client:partner_fatal(c.a.id)
    T.eq(pinfo, I.KNOWN | I.FATAL | I.TARGETS, "the client knows what the host's enemy says")
    T.eq(ftype, 1, "and the finisher it offers (a round kick)")
    T.eq(pair.client:summary().targeting_partner, 1, "one enemy is after the client")
    T.eq(pair.host:summary().targeting_partner, 1, "the host counts it too")
    local near = pair.host_world.info_asked[h.a.id]
    T.eq(near, true, "the close enemy was asked about finishers")
    T.eq(pair.host_world.info_asked[h.b.id], false, "a farther one only whether it targets the client")
    -- The host's enemy goes quiet (its area unloads): no stale answer.
    pair.drop_to_client = true
    pair:step(50)
    T.eq(pair.client:partner_fatal(c.a.id), nil, "no answer without fresh news")
end)

T.run("the_clients_finisher_on_a_host_enemy_runs_in_the_hosts_game", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    T.eq(pair.client_world.puppet[c.a.id], true, "the client shows a puppet")
    pair:fatal("client", c.a, P.FATAL_KIND.STEALTH, 0)
    T.eq(pair.client_world.puppet[c.a.id], true, "still a puppet: the client's game does not run it")
    pair:step(1)
    local f = pair.host_world.fatals[1]
    T.check(f ~= nil, "the host's game was asked")
    T.eq(f and f.id, h.a.id, "on its own copy of the enemy")
    T.eq(f and f.kind, P.FATAL_KIND.STEALTH, "the same finisher")
    T.eq(pair.host.counters.fatals_applied, 1, "run")
    T.eq(owner_of(pair, h.a), HOST, "still the host's")
    -- The finisher kills it in the host's game: the client's copy dies, the kill is the client's.
    pair.host_world:damage(h.a, 100)
    pair:step(3)
    T.check(not c.a.alive, "dead in the client's game too")
    T.eq(pair.client_world.kills[1].by, "self", "by the client's player")
    T.eq(pair.host.counters.client_kills, 1, "the host counts the client's kill")
end)

T.run("a_kick_carries_its_finisher_type", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    pair:fatal("client", c.b, P.FATAL_KIND.NORMAL, 2)
    pair:step(1)
    local f = pair.host_world.fatals[1]
    T.eq(f and f.kind, P.FATAL_KIND.NORMAL, "a normal finisher")
    T.eq(f and f.ftype, 2, "a straight kick")
end)

T.run("a_finisher_the_host_cannot_run_is_counted", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    pair.host_world.refuse_fatal = true
    pair:fatal("client", c.a, P.FATAL_KIND.KILL, 0)
    pair:step(1)
    T.eq(pair.host.counters.fatals_failed, 1, "refused by the host's enemy")
    -- An enemy the client's game has but the host's does not (held, unpaired): nothing is sent.
    local lone = pair.client_world:spawn(GANADO, 70, 0, 70, 100, 0x4999)
    pair:step(2)
    pair:fatal("client", lone, P.FATAL_KIND.KILL, 0)
    T.eq(pair.client.counters.fatals_unpaired, 1, "unpaired: dropped")
    T.check(h.a.alive, "nothing died")
end)

T.run("a_host_enemy_the_clients_save_had_dead_appears_for_the_client", function()
    -- The client loaded a save in which these villagers had died: its game never spawns them,
    -- while they are alive in the host's world. The host's world decides: they appear.
    local pair = make_pair()
    pair.host_player = { x = 0, y = 0, z = -5 }
    pair.client_player = { x = 0, y = 0, z = -30 }
    local h = pair.host_world:spawn(GANADO, 4, 0, 0, 100, 0x5101)
    pair.client_world.spawnable[0x5101] = { kind = GANADO, pos = { x = 0, y = 0, z = 0 } }
    pair:step(10)
    T.eq(#pair.client_world.revives, 0, "not at once (it may still spawn by itself)")
    pair:step(30)
    T.eq(#pair.client_world.revives, 1, "then the client's game is asked to spawn it")
    local c = pair.client_world.enemies[1]
    T.eq(c and c.uid, 0x5101, "it spawned")
    pair:step(20)
    T.eq(net_of(pair.client, c), net_of(pair.host, h), "paired with the host's")
    T.eq(owner_of(pair, h), HOST, "the host runs it")
    T.eq(pair.client_world.puppet[c.id], true, "the client's copy follows it")
    T.near(c.pos.x, 4, 0.05, "where the host's is")
    T.eq(pair.client.counters.spawn_spawning, 1, "spawned once")
    pair:step(100)
    T.eq(#pair.client_world.revives, 1, "never asked again")
end)

T.run("an_enemy_spawned_for_the_hosts_world_starts_where_the_hosts_is", function()
    local pair = make_pair()
    pair.host_player = { x = 0, y = 0, z = -20 }
    pair.client_player = { x = 3, y = 0, z = 2 }
    local h = pair.host_world:spawn(GANADO, 5, 0, 5, 100, 0x5151)
    pair.host_world:damage(h, 35)
    pair.client_world.spawnable[0x5151] = { kind = GANADO, pos = { x = -30, y = 0, z = 40 } }
    pair:step(60)
    local c = pair.client_world.enemies[1]
    T.eq(c and c.uid, 0x5151, "spawned")
    T.eq(owner_of(pair, h), HOST, "the host's game runs it")
    T.near(c.pos.x, 5, 0.5, "from where the host's was")
    T.near(c.pos.z, 5, 0.5, "in every axis")
    T.eq(c.hp, 65, "with the HP it had there")
    T.near(h.pos.x, 5, 0.5, "the host's copy did not jump to a spawn point")
end)

T.run("the_client_never_spawns_what_it_has_or_just_killed", function()
    local pair = make_pair()
    pair.client_player = { x = 0, y = 0, z = -5 }
    -- Its corpse is still here.
    local h1 = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x5201)
    local c1 = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x5201)
    c1.hp, c1.alive = 0, false
    -- It died here a moment ago and its body is gone already; the host has not heard yet.
    local h2 = pair.host_world:spawn(GANADO, 6, 0, 0, 100, 0x5202)
    local c2 = pair.client_world:spawn(GANADO, 6, 0, 0, 100, 0x5202)
    -- A host enemy without a level identity (spawned at runtime).
    pair.host_world:spawn(DOG, 3, 0, 3, 100, nil)
    pair:step(10)
    pair.drop_to_host = true
    pair.client_world:damage(c2, 100)
    pair:step(2)
    pair.client_world:remove(c2)
    pair.drop_to_host = nil -- (its death report was lost)
    pair.client_world.spawnable[0x5201] = { kind = GANADO, pos = { x = 0, y = 0, z = 0 } }
    pair.client_world.spawnable[0x5202] = { kind = GANADO, pos = { x = 6, y = 0, z = 0 } }
    pair:step(100)
    T.eq(#pair.client_world.revives, 0, "nothing spawned")
    T.check(h1.alive and h2.alive, "(still alive on the host)")
end)

T.run("the_client_spawns_nothing_far_away_while_loading_or_when_switched_off", function()
    local pair = make_pair({ enemy_spawn_missing = false })
    pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x5301)
    pair.client_world.spawnable[0x5301] = { kind = GANADO, pos = { x = 0, y = 0, z = 0 } }
    pair:step(60)
    T.eq(#pair.client_world.revives, 0, "switched off")
    pair.settings.enemy_spawn_missing = nil
    pair.client_player = { x = 0, y = 0, z = 300 }
    pair:step(60)
    T.eq(#pair.client_world.revives, 0, "out of reach")
    pair.client_player = { x = 0, y = 0, z = -5 }
    pair.client_loading = true
    pair:step(60)
    T.eq(#pair.client_world.revives, 0, "not while our area loads")
    pair.client_loading = nil
    pair:step(60)
    T.eq(#pair.client_world.revives, 1, "then it is spawned")
    T.eq(#pair.host_world.revives, 0, "the host never spawns the client's enemies: its world decides")
end)

T.run("dead_stays_dead_for_enemies_that_spawn_later", function()
    local pair = make_pair()
    pair.client_player = { x = 0, y = 0, z = -5 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x5001)
    pair:step(5)
    pair.host_world:damage(h, 100)
    pair:step(3)
    -- The client's level spawns it only now, far from the client: never appears.
    local far = pair.client_world:spawn(GANADO, 100, 0, 100, 100, 0x5001)
    pair:step(3)
    T.check(far.erased, "erased: no corpse")
    -- One the client has been near for a while dies visibly.
    local h2 = pair.host_world:spawn(GANADO, 2, 0, 0, 100, 0x5002)
    local near = pair.client_world:spawn(GANADO, 2, 0, 0, 100, 0x5002)
    pair:step(40)
    pair.host_world:damage(h2, 100)
    pair:step(3)
    T.check(not near.alive and not near.erased, "died where the client sees it")
end)

T.run("the_clients_kill_of_an_enemy_the_host_has_not_loaded", function()
    local pair = make_pair()
    pair.host_player = { x = -200, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    -- The client ran ahead: its level spawned a villager the host's has not. It waits, unseen;
    -- a stray bullet still finds it.
    local c = pair.client_world:spawn(GANADO, 101, 0, 1, 100, 0x5101)
    pair:step(5)
    T.eq(pair.client_world.puppet[c.id], true, "held: the client's game does not run it")
    pair:player_hit("client", c, 100)
    pair:step(3)
    T.check(c.alive, "it never dies in the client's game")
    T.eq(pair.host.dead_count, 1, "the kill is in the host's graveyard")
    pair.host_player = { x = 95, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 101, 0, 1, 100, 0x5101)
    pair:step(30)
    T.check(not h.alive or h.erased, "it never lives in the host's world")
end)

T.run("a_joining_client_learns_the_dead_of_the_hosts_save", function()
    local pair = make_pair()
    pair.host_world.save_dead = { 0x6001, 0x6002 }
    pair.host:request_graveyard(pair.now)
    pair:step(6)
    T.eq(pair.client.grave_count, 2, "both dead enemies known")
    local c = pair.client_world:spawn(GANADO, 50, 0, 50, 100, 0x6002)
    pair:step(3)
    T.check(c.erased, "never appears in the client's world")
end)

T.run("a_host_reload_brings_its_dead_back_for_the_client_too", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.host_world:damage(h.a, 100)
    pair:step(3)
    T.eq(pair.client.grave_count, 1, "dead")
    local old = net_of(pair.host, h.b)
    pair.host:on_local_reload()
    pair:step(1)
    T.eq(pair.client.grave_count, 0, "the client forgets the dead")
    T.eq(pair.client_world.invalid_spawns or 0, 0, "and nothing it erased stays unable to spawn")
    pair:step(3)
    T.check(net_of(pair.host, h.b) ~= old, "the host numbered its enemies anew")
    T.eq(net_of(pair.client, c.b), net_of(pair.host, h.b), "and the client paired them again")
end)

T.run("an_enemy_erased_here_can_spawn_again_after_the_hosts_reload", function()
    -- The host kills an enemy the client has not loaded; when the client's level spawns it,
    -- it is erased (its spawn param invalidated). The host then reloads a checkpoint: that
    -- enemy is alive in its world again, so the client's spawn param must be able to spawn it.
    local pair = make_pair()
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x2001)
    pair:step(5)
    pair.host_world:damage(h, 100)
    pair:step(3)
    T.eq(pair.client.grave_count, 1, "dead in the host's world")
    pair.client_world:spawn(GANADO, 30, 0, 0, 100, 0x2001) -- the client's level spawns it
    pair:step(5)
    T.eq(pair.client_world.calls.erase, 1, "erased on sight")
    T.eq(pair.client_world.invalid_spawns, 1, "its spawn param is invalid")
    pair.host:on_local_reload()
    pair:step(2)
    T.eq(pair.client_world.restored, 1, "valid again after the host's reload")
end)

T.run("client_only_enemies_wait_until_the_host_has_them", function()
    local pair = make_pair()
    pair.host_player = { x = 0, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    local c = pair.client_world:spawn(GANADO, 101, 0, 1, 100, 0x7101)
    pair:step(10)
    T.eq(pair.client_world.puppet[c.id], true, "still")
    T.eq(pair.client_world.hidden[c.id], true, "and unseen")
    T.eq(pair.client:summary().held, 1, "reported as held")
    local h = pair.host_world:spawn(GANADO, 40, 0, 0, 100, 0x7101)
    pair:step(10)
    T.eq(net_of(pair.client, c), net_of(pair.host, h), "paired")
    T.eq(pair.client_world.hidden[c.id], nil, "visible")
    T.near(c.pos.x, 40, 0.01, "where the host's is")
end)

T.run("a_copy_hit_before_the_host_loaded_it_keeps_its_damage", function()
    local pair = make_pair()
    pair.host_player = { x = 0, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    local c = pair.client_world:spawn(GANADO, 99, 0, 0, 100, 0x7201)
    pair:step(5)
    -- Held in the client's game: a stray hit takes HP there (never the last), the host has none yet.
    pair:player_hit("client", c, 60)
    pair:step(2)
    T.eq(c.hp, 40, "hurt in the client's game")
    pair.host_player = { x = 98, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 99, 0, 0, 100, 0x7201)
    pair:step(10)
    T.eq(owner_of(pair, h), HOST, "the host's")
    T.eq(h.hp, 40, "with the damage it took in the client's game")
    T.eq(c.hp, 40, "the client's copy keeps it")
end)

T.run("traffic_stays_small", function()
    local pair = make_pair()
    for i = 1, 30 do
        pair.host_world:spawn(GANADO, i, 0, 0, 100, 0x8000 + i)
        pair.client_world:spawn(GANADO, i, 0, 0, 100, 0x8000 + i)
    end
    pair:step(20)
    local bytes = 0
    local probe = pair.host
    local entries = {}
    for _, net in pairs(probe.nets) do
        local e = probe.by_id[net.local_id]
        entries[#entries + 1] = { net_id = net.net_id, epoch = net.epoch, uid = e.uid, kind_hash = e.kind_hash, pos = e.pos,
            rot = e.rot, hp = e.hp, max_hp = e.max_hp, pinfo = P.PARTNER_INFO.KNOWN, ftype = 1,
            layers = { { bank = 1, id = 2, frame = 3, speed = 1 }, { bank = 1, id = 2, frame = 3, speed = 1 } } }
    end
    for _, m in ipairs(P.encode_enemy_states(1, entries)) do
        T.check(#m <= P.MAX_PAYLOAD, "every message fits a datagram")
        bytes = bytes + #m
    end
    T.check(bytes < 2700, ("30 enemies with two layers in %d bytes per state"):format(bytes))
    T.eq(pair.sent.client[P.T.ENEMY_STATE] or 0, 0, "the client never sends enemy states")
end)

T.finish()
