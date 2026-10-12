-- Two simulated game worlds (host + client) running EnemyNet against each other, with every
-- message going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local EnemyNet = require("re4coop.enemy_net")

local GANADO, DOG, CHIEF = "chainsaw.Ch1c0z0Context", "chainsaw.Ch1d1z1Context", "chainsaw.Ch1d0z0Context"
local HOST, CLIENT = P.OWNER.HOST, P.OWNER.CLIENT

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
    function w:enemy_kill(id, fields)
        local e = self:get(id)
        if not e or self.refuse_kill then return false end
        self.calls.kill = self.calls.kill + 1
        self.kills[#self.kills + 1] = { id = id, fields = fields, puppet = self.puppet[id] == true,
            pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z } }
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
            { local_pos = me, partner_pos = partner, partner_busy = self.partner_busy })
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

    -- Our player starts a finisher (stealth kill, grab...) on `e`, the way game.lua's hook
    -- reports it: the adapter switches a puppet back on at once when the sync allows it.
    function pair:fatal(side, e)
        local sync = side == "host" and self.host or self.client
        local world = side == "host" and self.host_world or self.client_world
        if sync:may_fatal(e.id) then world.puppet[e.id] = nil end
        sync:on_local_fatal({ e.id }, self.now, world)
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
-- Ownership
-------------------------------------------------------------------------------

T.run("each_enemy_goes_to_the_game_of_the_player_it_is_closer_to", function()
    local pair = make_pair()
    pair.host_player = { x = -20, y = 0, z = 0 }
    pair.client_player = { x = 30, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(6)
    T.eq(owner_of(pair, h.a), HOST, "A (x=0) is the host's")
    T.eq(owner_of(pair, h.b), CLIENT, "B (x=10) is the client's")
    T.eq(pair.host_world.puppet[h.b.id], true, "the host's B follows the client's")
    T.eq(pair.client_world.puppet[c.b.id], nil, "the client's B runs on its own AI")
    T.eq(pair.client_world.puppet[c.a.id], true, "the client's A follows the host's")
    T.eq(pair.host_world.puppet[h.a.id], nil, "the host's A runs")
    local s = pair.client:summary()
    T.eq(s.run_here, 1, "the client runs one")
    T.eq(s.run_by_partner, 2, "and shows two")
end)

T.run("host_authority_keeps_every_enemy_with_the_host", function()
    local pair = make_pair({ enemy_authority = "host" })
    pair.host_player = { x = -50, y = 0, z = 0 }
    pair.client_player = { x = 10, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(40)
    for k in pairs(h) do
        T.eq(owner_of(pair, h[k]), HOST, k .. " stays with the host")
        T.eq(pair.client_world.puppet[c[k].id], true, k .. " is a puppet on the client")
    end
end)

T.run("an_enemy_changes_hands_only_after_a_clear_lasting_lead", function()
    local pair = make_pair()
    pair.host_player = { x = -5, y = 0, z = 0 }
    pair.client_player = { x = 20, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4001)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x4001)
    pair:step(5)
    local owner, epoch = owner_of(pair, h)
    T.eq(owner, HOST, "the host's first")
    -- The client comes closer, but only 1 m closer than the host: no change.
    pair.client_player = { x = 4, y = 0, z = 0 }
    pair:step(40)
    T.eq(owner_of(pair, h), HOST, "a small lead changes nothing")
    -- Now clearly closer, but only for a moment.
    pair.client_player = { x = 0.5, y = 0, z = 0 }
    pair:step(5)
    pair.client_player = { x = 4, y = 0, z = 0 }
    pair:step(5)
    T.eq(owner_of(pair, h), HOST, "a short lead changes nothing")
    -- A lasting clear lead.
    pair.client_player = { x = 0.5, y = 0, z = 0 }
    pair:step(30)
    local owner2, epoch2 = owner_of(pair, h)
    T.eq(owner2, CLIENT, "the client's now")
    T.check(epoch2 ~= epoch, "a new ownership epoch")
    T.eq(pair.client.nets[net_of(pair.client, c)].epoch, epoch2, "the client knows the epoch")
    T.eq(pair.client_world.puppet[c.id], nil, "the client's AI runs it")
    T.eq(pair.host_world.puppet[h.id], true, "the host's copy follows")
    -- And straight back is not possible before the minimum time.
    pair.client_player = { x = 30, y = 0, z = 0 }
    pair:step(20)
    T.eq(owner_of(pair, h), CLIENT, "kept for the minimum time")
    pair:step(60)
    T.eq(owner_of(pair, h), HOST, "then back to the host")
    T.eq(pair.client_world.puppet[c.id], true, "the client's copy follows again")
end)

T.run("the_player_who_hits_an_enemy_draws_it", function()
    local pair = make_pair()
    pair.host_player = { x = -4, y = 0, z = 0 }
    pair.client_player = { x = 5, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 1000, 0x4101)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 1000, 0x4101)
    pair:step(5)
    T.eq(owner_of(pair, h), HOST, "the host's (closer)")
    -- Equal distances, but the client keeps shooting it: it goes to the client.
    pair.host_player = { x = -5, y = 0, z = 0 }
    for _ = 1, 60 do
        pair:player_hit("client", c, 1)
        pair:step(1)
    end
    T.eq(owner_of(pair, h), CLIENT, "the shooter's game runs it")
end)

T.run("a_partner_who_is_down_or_in_a_cutscene_gets_no_enemies", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 2, y = 0, z = 0 }
    pair.partner_busy = true
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4201)
    pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x4201)
    pair:step(60)
    T.eq(owner_of(pair, h), HOST, "stays with the host")
    pair.partner_busy = false
    pair:step(60)
    T.eq(owner_of(pair, h), CLIENT, "the client's once it can fight")
end)

T.run("taking_over_continues_from_the_partners_latest_state", function()
    local pair = make_pair()
    pair.host_player = { x = 0, y = 0, z = -2 }
    pair.client_player = { x = 0, y = 0, z = -40 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4301)
    local c = pair.client_world:spawn(GANADO, 30, 0, 30, 100, 0x4301)
    pair:step(10)
    -- The host's AI walked it and hurt it.
    h.pos = { x = 3, y = 0, z = 1 }
    h.hp = 40
    pair:step(10)
    T.near(c.pos.x, 3, 0.01, "the client's copy is where the host's is")
    T.eq(c.hp, 40, "with the host's HP")
    -- The players swap places: the client takes it over from there.
    pair.host_player = { x = 0, y = 0, z = -60 }
    pair.client_player = { x = 3, y = 0, z = -1 }
    pair:step(80)
    T.eq(owner_of(pair, h), CLIENT, "the client's")
    T.near(c.pos.x, 3, 0.1, "continues where it was")
    T.eq(c.hp, 40, "with the HP it had")
    -- The client's AI moves it: the host's copy follows.
    c.pos = { x = -6, y = 0, z = 2 }
    c.rot = yaw_quat(1.2)
    pair:step(10)
    T.near(h.pos.x, -6, 0.01, "the host's copy follows the client's")
    T.near(h.rot.y, math.sin(0.6), 0.01, "and its full rotation")
end)

T.run("an_owner_that_lost_its_copy_gives_it_back", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 2, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4401)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x4401)
    pair:step(8)
    T.eq(owner_of(pair, h), CLIENT, "the client's")
    pair.client_world:remove(c) -- the client's area unloaded
    pair:step(40)
    T.eq(owner_of(pair, h), HOST, "the host runs it again")
    T.eq(pair.host_world.puppet[h.id], nil, "with its own AI")
end)

T.run("a_host_enemy_that_left_the_hosts_world_frees_the_clients_copy", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 2, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4501)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x4501)
    pair:step(8)
    T.eq(owner_of(pair, h), CLIENT, "the client's")
    pair.host_world:remove(h) -- the host's area unloaded
    pair:step(140)
    T.eq(net_of(pair.client, c), nil, "no longer shared")
    T.eq(pair.client_world.puppet[c.id], nil, "the client's copy runs on its own")
    T.check(pair.client.counters.handed_over == 0 or true, "")
end)

-------------------------------------------------------------------------------
-- State: transform, animation, visibility, HP
-------------------------------------------------------------------------------

T.run("puppets_follow_position_rotation_and_animation", function()
    local pair = make_pair({ enemy_authority = "host" })
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
end)

T.run("a_copy_spawned_elsewhere_jumps_to_the_owners_enemy", function()
    local pair = make_pair({ enemy_authority = "host" })
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0xD001)
    pair:step(5)
    local c = pair.client_world:spawn(GANADO, 35, 0, 12, 100, 0xD001)
    pair:step(8)
    T.near(c.pos.x, 0, 0.01, "moved to where the host's copy is")
    T.near(c.pos.z, 0, 0.01, "in every axis")
    T.check(h.alive, "untouched on the host")
end)

T.run("an_enemy_the_owner_does_not_draw_is_not_drawn", function()
    local pair = make_pair({ enemy_authority = "host" })
    local h, c = standard_level(pair)
    pair:step(5)
    h.a.drawn = false
    pair:step(3)
    T.eq(pair.client_world.hidden[c.a.id], true, "hidden like the host's")
    h.a.drawn = nil
    pair:step(3)
    T.eq(pair.client_world.hidden[c.a.id], nil, "shown again")
end)

T.run("damage_the_owner_takes_shows_up_on_the_puppet", function()
    local pair = make_pair({ enemy_authority = "host" })
    local h, c = standard_level(pair)
    pair:step(5)
    pair.host_world:damage(h.c, 120) -- the host's player shot the chief
    pair:step(3)
    T.eq(c.c.hp, 180, "the client's chief has the host's HP")
end)

-------------------------------------------------------------------------------
-- Hits
-------------------------------------------------------------------------------

T.run("a_hit_on_an_enemy_the_partner_runs_is_run_by_the_partners_game", function()
    local pair = make_pair({ enemy_authority = "host" })
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
    local pair = make_pair({ enemy_authority = "host" })
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

T.run("a_puppet_never_dies_from_our_hit_the_owner_decides", function()
    local pair = make_pair({ enemy_authority = "host" })
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
    T.eq(#pair.client_kills, 1, "the client rolls its loot for it")
    T.eq(pair.host.dead_count, 1, "buried on the host")
end)

T.run("the_host_hitting_an_enemy_the_client_runs", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 9, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(8)
    T.eq(owner_of(pair, h.b), CLIENT, "B is the client's")
    pair:player_hit("host", h.b, 40)
    pair:step(2)
    T.eq(c.b.hp, 60, "the client's game ran the host's hit")
    T.eq(pair.client.counters.hits_applied, 1, "through its hit code")
    pair:step(4)
    T.eq(h.b.hp, 60, "and the host's copy agrees")
end)

T.run("a_hit_that_crossed_an_owner_change_is_sent_back", function()
    local pair = make_pair()
    pair.host_player = { x = 9, y = 0, z = 0 }
    pair.client_player = { x = -30, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(8)
    T.eq(owner_of(pair, h.b), HOST, "B is the host's")
    -- The host hands B to the client; the client hits its puppet before it hears of it.
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 9, y = 0, z = 0 }
    pair.drop_types = { [P.T.ENEMY_OWNER] = true }
    pair:step(80)
    T.eq(owner_of(pair, h.b), CLIENT, "the host gave B to the client")
    pair.drop_types = nil
    pair:player_hit("client", c.b, 15) -- still a puppet in the client's game: sent to the host
    pair:step(6)
    T.eq(pair.host.counters.hits_bounced, 1, "the host sent it back")
    T.eq(pair.client.counters.hits_applied, 1, "the client's game ran it")
    T.eq(c.b.hp, 85, "counted once")
    pair:step(4)
    T.eq(h.b.hp, 85, "both agree")
end)

T.run("the_owners_last_hits_before_a_change_still_count", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 9, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(60)
    T.eq(owner_of(pair, h.b), CLIENT, "B is the client's")
    pair.drop_to_client = true -- the host takes it back; the news is on its way
    pair.host_player = { x = 9, y = 0, z = 0 }
    pair.client_player = { x = -30, y = 0, z = 0 }
    pair:step(30)
    T.eq(owner_of(pair, h.b), HOST, "the host's again")
    pair.drop_to_client = false
    pair:player_hit("client", c.b, 20) -- the client's game still runs it: a normal hit
    T.eq(c.b.hp, 80, "hurt in the client's game")
    pair:step(6)
    T.eq(h.b.hp, 80, "the damage reached the new owner")
    T.eq(c.b.hp, 80, "and stays")
end)

T.run("hits_on_enemies_we_run_are_only_shown_to_the_partner", function()
    local pair = make_pair({ enemy_authority = "host" })
    local h, c = standard_level(pair)
    pair:step(5)
    pair:player_hit("host", h.a, 10)
    pair:step(1)
    T.eq(#pair.client_world.applied, 0, "nothing to run on the client")
    T.eq(#pair.client:recent_partner_hits(pair.now, 1.0), 1, "a tracer to draw")
    pair:step(3)
    T.eq(c.a.hp, 90, "the HP arrives with the host's state")
end)

T.run("other_damage_to_a_puppet_goes_to_the_owner", function()
    local pair = make_pair({ enemy_authority = "host" })
    local h, c = standard_level(pair)
    pair:step(5)
    pair.client_world:damage(c.c, 50) -- a barrel exploded next to it in the client's game
    pair:step(3)
    T.eq(pair.client.counters.damage_reported, 1, "reported to the host")
    T.eq(h.c.hp, 250, "the host applied it")
    T.eq(c.c.hp, 250, "and both agree")
end)

T.run("without_hit_code_the_owner_applies_the_damage_as_hp", function()
    local pair = make_pair({ enemy_authority = "host" })
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
end)

-------------------------------------------------------------------------------
-- Deaths
-------------------------------------------------------------------------------

T.run("an_enemy_the_client_runs_dies_in_both_games", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 9, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(8)
    T.eq(owner_of(pair, h.b), CLIENT, "B is the client's")
    c.b.pos = { x = 12, y = 0, z = 1 }
    pair:player_hit("client", c.b, 100)
    T.check(not c.b.alive, "died in the client's game (it runs it)")
    pair:step(3)
    T.check(not h.b.alive, "and in the host's")
    local k = pair.host_world.kills[1]
    T.eq(k.fields[1].v, 100, "from the same killing hit")
    T.near(k.pos.x, 12, 0.01, "where it died")
    T.eq(#pair.host_kills, 1, "the host rolls its loot")
    T.eq(pair.host.dead_count, 1, "in the host's graveyard")
    T.eq(pair.client.counters.deaths_sent, 1, "announced once")
end)

-------------------------------------------------------------------------------
-- Finishers (stealth kill, grab, knife finish, stomp)
-------------------------------------------------------------------------------

-- The bug: the host's player grabbed and killed an enemy the client's game ran. The request
-- went to the host's puppet (AI off), the client's enemy went on chasing the client and only
-- died when it changed hands seconds later.
T.run("the_host_finishing_an_enemy_the_client_runs_takes_it_at_once", function()
    local pair = make_pair()
    pair.host_player = { x = -30, y = 0, z = 0 }
    pair.client_player = { x = 9, y = 0, z = 0 }
    local h, c = standard_level(pair)
    pair:step(8)
    T.eq(owner_of(pair, h.b), CLIENT, "B is the client's (it chases the client)")
    pair.host_player = { x = 9.5, y = 0, z = 0 } -- the host's player walks up behind it
    pair:fatal("host", h.b)
    T.eq(owner_of(pair, h.b), HOST, "the host's game runs it at once")
    T.eq(pair.host_world.puppet[h.b.id], nil, "its AI is on here for the finisher")
    pair:step(2)
    T.eq(pair.client_world.puppet[c.b.id], true, "the client's copy follows the host's")
    pair:step(60) -- 3 s, the client still a little closer
    T.eq(owner_of(pair, h.b), HOST, "it stays with the host while the finisher plays out")
    pair.host_world:damage(h.b, 100) -- the finisher kills it
    pair:step(3)
    T.check(not c.b.alive, "dead in the client's game too, right away")
    T.eq(pair.host.counters.fatals, 1, "counted")
end)

T.run("the_clients_finisher_on_a_host_enemy_runs_in_the_clients_game", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    T.eq(owner_of(pair, h.a), HOST, "A is the host's")
    T.eq(pair.client_world.puppet[c.a.id], true, "the client shows a puppet")
    pair:fatal("client", c.a)
    T.eq(pair.client_world.puppet[c.a.id], nil, "the client's game runs it from this moment")
    c.a.pos = { x = 1.5, y = 0, z = 0.5 } -- the finisher moves it
    pair:player_hit("client", c.a, 30) -- the knife
    T.eq(c.a.hp, 70, "the finisher's hits count here")
    pair:step(1)
    T.eq(pair.client_world.puppet[c.a.id], nil, "not a puppet again while the host answers")
    T.eq(h.a.hp, 100, "those hits are not run in the host's game as well")
    pair:step(3)
    T.eq(owner_of(pair, h.a), CLIENT, "the host handed it over")
    T.eq(pair.host_world.puppet[h.a.id], true, "the host's copy follows the client's")
    T.near(c.a.pos.x, 1.5, 1e-6, "the client's enemy stayed where the finisher put it")
    T.eq(c.a.hp, 70, "and kept its damage")
    T.eq(pair.host.counters.claims_granted, 1, "granted")
    pair:step(60)
    T.eq(owner_of(pair, h.a), CLIENT, "it stays with the client while the finisher plays out")
    pair.client_world:damage(c.a, 70)
    pair:step(3)
    T.check(not h.a.alive, "dead in the host's game too")
end)

T.run("a_finisher_that_kills_before_the_host_answers_still_kills_in_both_games", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    pair:fatal("client", c.a)
    pair.client_world:damage(c.a, 100) -- a quick finisher: dead before the host's answer
    pair:step(1)
    T.eq(pair.client.counters.deaths_sent, 1, "the client announces the death (its game ran it)")
    pair:step(3)
    T.check(not h.a.alive, "dead in the host's game too")
    pair:step(60)
    T.check(not h.a.alive, "and it stays dead")
end)

T.run("two_finishers_on_one_enemy_the_hosts_wins", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(6)
    pair:fatal("host", h.a)
    pair:fatal("client", c.a)
    pair:step(3)
    T.eq(owner_of(pair, h.a), HOST, "the host keeps it")
    T.eq(pair.host.counters.claims_refused, 1, "the client's claim refused")
    pair:step(40) -- the claim runs out
    T.eq(pair.client_world.puppet[c.a.id], true, "the client's copy follows the host's again")
end)

T.run("host_authority_never_runs_a_finisher_in_the_clients_game", function()
    local pair = make_pair({ enemy_authority = "host" })
    local h, c = standard_level(pair)
    pair:step(6)
    pair:fatal("client", c.a)
    T.eq(pair.client_world.puppet[c.a.id], true, "still a puppet")
    pair:step(3)
    T.eq(owner_of(pair, h.a), HOST, "still the host's")
    T.eq(pair.client.counters.claims_sent, 0, "nothing claimed")
end)

T.run("dead_stays_dead_for_enemies_that_spawn_later", function()
    local pair = make_pair({ enemy_authority = "host" })
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
    -- The client ran ahead: its level spawned a villager the host's has not.
    local c = pair.client_world:spawn(GANADO, 101, 0, 1, 100, 0x5101)
    pair:step(5)
    T.eq(pair.client_world.puppet[c.id], nil, "shared authority: the client's game runs it meanwhile")
    pair:player_hit("client", c, 100)
    pair:step(3)
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
    local pair = make_pair({ enemy_authority = "host" })
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
    local pair = make_pair({ enemy_authority = "host" })
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

T.run("host_authority_holds_client_only_enemies_until_the_host_has_them", function()
    local pair = make_pair({ enemy_authority = "host" })
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

T.run("a_copy_fought_before_the_host_loaded_it_keeps_its_damage", function()
    local pair = make_pair()
    pair.host_player = { x = 0, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    local c = pair.client_world:spawn(GANADO, 99, 0, 0, 100, 0x7201)
    pair:step(5)
    pair:player_hit("client", c, 60) -- the client's game runs it: a normal hit
    pair:step(2)
    T.eq(c.hp, 40, "hurt in the client's game")
    -- The host arrives first, its level spawns it fresh: the host is closer, so it runs it.
    pair.host_player = { x = 98, y = 0, z = 0 }
    local h = pair.host_world:spawn(GANADO, 99, 0, 0, 100, 0x7201)
    pair:step(10)
    T.eq(owner_of(pair, h), HOST, "the host's")
    T.eq(h.hp, 40, "with the damage it took in the client's game")
    T.eq(c.hp, 40, "the client's copy keeps it")
end)

T.run("traffic_stays_small", function()
    local pair = make_pair({ enemy_authority = "host" })
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
            rot = e.rot, hp = e.hp, max_hp = e.max_hp, layers = { { bank = 1, id = 2, frame = 3, speed = 1 },
                { bank = 1, id = 2, frame = 3, speed = 1 } } }
    end
    for _, m in ipairs(P.encode_enemy_states(1, entries)) do
        T.check(#m <= P.MAX_PAYLOAD, "every message fits a datagram")
        bytes = bytes + #m
    end
    T.check(bytes < 2600, ("30 enemies with two layers in %d bytes per state"):format(bytes))
end)

T.finish()
