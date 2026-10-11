-- Two simulated game worlds (host + client) running EnemySync against each other, with
-- every message going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local EnemySync = require("re4coop.enemy_sync")

local function make_world(id_base)
    local w = { enemies = {}, next_id = id_base, calls = { set_hp = 0, kill = 0, move = 0 } }

    function w:spawn(kind, x, y, z, hp, ctx)
        local e = { id = self.next_id, kind = kind, pos = { x = x, y = y, z = z }, yaw = 0, hp = hp or 100,
            max_hp = hp or 100, alive = true, ctx = ctx }
        self.next_id = self.next_id + 1
        table.insert(self.enemies, e)
        return e
    end

    function w:get(id)
        for _, e in ipairs(self.enemies) do
            if e.id == id then return e end
        end
    end

    function w:damage(e, amount)
        e.hp = math.max(0, e.hp - amount)
        if e.hp == 0 then e.alive = false end
    end

    function w:remove(e)
        for i, x in ipairs(self.enemies) do
            if x == e then table.remove(self.enemies, i) return end
        end
    end

    -- Snapshot of the world the way game:list_enemies() returns it (fresh tables each call).
    function w:list()
        local out = {}
        for _, e in ipairs(self.enemies) do
            out[#out + 1] = { id = e.id, kind = e.kind, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
                yaw = e.yaw, hp = e.hp, max_hp = e.max_hp, alive = e.alive, ctx = e.ctx }
        end
        return out
    end

    -- game adapter
    function w:enemy_set_hp(id, hp)
        local e = self:get(id)
        if not e then return false end
        self.calls.set_hp = self.calls.set_hp + 1
        e.hp = hp
        return true
    end

    function w:enemy_kill(id)
        local e = self:get(id)
        if not e then return false end
        self.calls.kill = self.calls.kill + 1
        e.hp = 0
        e.alive = false
        return true
    end

    -- Replays a partner hit; `replay_kept` simulates a game where the replay's HP loss
    -- could not be put back.
    w.replays = {}
    w.replay_kept = 0
    function w:enemy_replay_hit(id, hit)
        local e = self:get(id)
        if not e then return false, 0 end
        self.replays[#self.replays + 1] = { id = id, wince = hit.wince, critical = hit.critical }
        if self.replay_kept > 0 then e.hp = e.hp - self.replay_kept end
        return true, self.replay_kept
    end

    function w:enemy_get_hp(id)
        local e = self:get(id)
        return e and e.hp or nil
    end

    function w:enemy_set_position(id, pos)
        local e = self:get(id)
        if not e then return false end
        self.calls.move = self.calls.move + 1
        e.pos = { x = pos.x, y = pos.y, z = pos.z }
        return true
    end

    return w
end

local function make_pair(settings)
    settings = settings or {}
    for k, v in pairs({ sync_hp = true, sync_deaths = true, snapshot_hz = 10, match_radius = 3.0, snap_distance = 0 }) do
        if settings[k] == nil then settings[k] = v end
    end
    local pair = { now = 0, host_world = make_world(1000), client_world = make_world(5000), to_host = {}, to_client = {},
        traffic = { host = 0, client = 0 } }
    pair.host = EnemySync.new({ role = "host", protocol = P, settings = settings,
        send = function(bytes) table.insert(pair.to_client, bytes) pair.traffic.host = pair.traffic.host + 1 end })
    pair.client = EnemySync.new({ role = "client", protocol = P, settings = settings,
        send = function(bytes) table.insert(pair.to_host, bytes) pair.traffic.client = pair.traffic.client + 1 end })

    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.05
            self.host:tick(self.now, self.host_world:list(), self.host_world)
            for _, bytes in ipairs(self.to_client) do
                self.client:on_message(assert(P.decode(bytes)), self.now, self.client_world)
            end
            self.to_client = {}
            self.client:tick(self.now, self.client_world:list(), self.client_world)
            for _, bytes in ipairs(self.to_host) do
                self.host:on_message(assert(P.decode(bytes)), self.now, self.host_world)
            end
            self.to_host = {}
        end
    end

    return pair
end

-- The same level spawned on two machines: same kinds/spawn points (tiny jitter), different
-- object ids and list order.
local function standard_level(pair)
    local h, c = {}, {}
    h.a = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0)
    h.b = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 10, 0, 0)
    h.c = pair.host_world:spawn("chainsaw.Ch1d0z0Context", 0, 0, 10, 300)
    c.c = pair.client_world:spawn("chainsaw.Ch1d0z0Context", 0.2, 0, 10.1, 300)
    c.b = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 10.3, 0, -0.2)
    c.a = pair.client_world:spawn("chainsaw.Ch1c0z0Context", -0.4, 0.1, 0.3)
    return h, c
end

T.run("pairs_enemies_by_kind_and_spawn", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    local cl = pair.client
    T.eq(cl.net_of[c.a.id], pair.host.net_of[h.a.id], "A paired with A")
    T.eq(cl.net_of[c.b.id], pair.host.net_of[h.b.id], "B paired with B")
    T.eq(cl.net_of[c.c.id], pair.host.net_of[h.c.id], "C paired with C")
    T.eq(cl:summary().paired, 3, "3 pairs")
end)

T.run("client_damage_applies_on_host_without_echo", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.client_world:damage(c.a, 30)
    pair:step(5)
    T.eq(h.a.hp, 70, "host copy took the client's damage")
    T.eq(c.a.hp, 70, "client copy unchanged by the echo")
    pair:step(20)
    T.eq(h.a.hp, 70, "no double application over time")
    T.eq(pair.client.counters.damage_sent, 1, "exactly one damage report")
end)

T.run("host_damage_and_kill_mirror_on_client", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.host_world:damage(h.b, 55)
    pair:step(3)
    T.eq(c.b.hp, 45, "client HP lowered to host value")
    pair.host_world:damage(h.c, 1000)
    pair:step(3)
    T.eq(c.c.alive, false, "client copy killed")
    T.eq(pair.client.counters.damage_sent, 0, "mirroring never reports back as damage")
    T.eq(h.a.hp, 100, "untouched enemy stays full")
end)

T.run("client_kill_is_authoritative", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.client_world:damage(c.c, 300)
    pair:step(5)
    T.eq(h.c.alive, false, "host enemy dies from the client's lethal hit")
    T.eq(pair.host_world.calls.kill, 1, "one kill call on host")
end)

T.run("damage_before_pairing_is_matched_by_spawn", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    -- The client has seen A once (HP baseline) but no host snapshot has arrived yet, so the
    -- first report goes out with net_id 0 and the host must find A by kind + spawn point.
    -- (Damage dealt before an enemy is observed at all has no baseline and is not reported.)
    pair.client:tick(pair.now, pair.client_world:list(), pair.client_world)
    pair.client_world:damage(c.a, 10)
    pair:step(1)
    pair.client_world:damage(c.a, 15)
    pair:step(5)
    T.eq(h.a.hp, 75, "both hits landed on the right host enemy")
end)

T.run("late_arrival_sees_enemies_host_already_killed", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    local hd = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 50, 0, 50)
    pair:step(5)
    pair.host_world:damage(hd, 500) -- host clears the next room alone...
    pair:step(5)
    pair.host_world:remove(hd)      -- ...and the corpse despawns from the host's list
    pair:step(10)
    local cd = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 50.5, 0, 49.8) -- client arrives
    pair:step(12)
    T.eq(cd.alive, false, "client's copy of the already-killed enemy is removed")
    T.eq(c.a.alive, true, "others unaffected")
end)

T.run("unmatched_enemies_are_left_alone", function()
    local pair = make_pair()
    standard_level(pair)
    local only_client = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 100, 0, 100)
    local wrong_kind = pair.client_world:spawn("chainsaw.Ch4b0z0Context", 0, 0, 0)
    local only_host = pair.host_world:spawn("chainsaw.Ch1c0z0Context", -80, 0, 0)
    pair:step(10)
    T.eq(pair.client.net_of[only_client.id], nil, "client-only enemy unpaired")
    T.eq(pair.client.net_of[wrong_kind.id], nil, "different kind at same spot unpaired")
    pair.host_world:damage(only_host, 1000)
    pair:step(5)
    T.eq(only_client.alive and wrong_kind.alive, true, "nothing killed by mistake")
end)

T.run("position_snapping_when_enabled", function()
    local pair = make_pair({ snap_distance = 2.0 })
    local h, c = standard_level(pair)
    pair:step(5)
    h.b.pos = { x = 20, y = 0, z = 0 } -- host's copy chased the host 10 m away
    pair:step(3)
    T.near(c.b.pos.x, 20, 1e-4, "client copy moved to host position")
    local moves = pair.client_world.calls.move
    pair:step(10)
    T.eq(pair.client_world.calls.move, moves, "no repeated snapping once close")
end)

-- Three enemies that both machines see near their spawn points: spatial pairing succeeds
-- and, since their spawner IDs agree, builds trust in spawner pairing.
local function build_spawner_trust(pair)
    for i = 1, 3 do
        local k = { category = 3, kind = 0, group = 900, index = i }
        pair.host_world:spawn("chainsaw.Ch1c0z0Context", 100 + i * 10, 0, 0, 100, k)
        pair.client_world:spawn("chainsaw.Ch1c0z0Context", 100 + i * 10 + 0.5, 0, 0, 100, k)
    end
    pair:step(5)
end

T.run("pairs_by_spawner_id_once_trusted", function()
    local pair = make_pair()
    build_spawner_trust(pair)
    T.check(pair.client:spawner_trusted(), "trusted after 3 agreeing spatial pairs")
    -- The client arrived later and saw these 8-12 m from where the host first saw them:
    -- spatial pairing would fail (3 m radius), the spawner ID does not.
    local ka, kb = { category = 3, kind = 0, group = 300, index = 1 }, { category = 3, kind = 0, group = 300, index = 2 }
    local ha = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0, 100, ka)
    local hb = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 1, 0, 0, 100, kb)
    local cb = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 9, 0, 6, 100, kb)
    local ca = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 12, 0, 0, 100, ka)
    pair:step(5)
    T.eq(pair.client.net_of[ca.id], pair.host.net_of[ha.id], "A paired by spawner")
    T.eq(pair.client.net_of[cb.id], pair.host.net_of[hb.id], "B paired by spawner (not swapped)")
    T.check(pair.client.counters.id_matches >= 2, "spawner matches counted")
    pair.client_world:damage(cb, 25)
    pair:step(5)
    T.eq(hb.hp, 75, "damage lands on the right enemy")
    T.eq(ha.hp, 100, "not on the other one")
end)

T.run("spawner_ids_unused_until_trusted", function()
    local pair = make_pair()
    local k = { category = 3, kind = 0, group = 300, index = 1 }
    pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0, 100, k)
    local c = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 12, 0, 0, 100, k)
    pair:step(5)
    T.eq(pair.client.net_of[c.id], nil, "no pairing by an unproven ID")
end)

T.run("one_disagreement_disables_spawner_pairing", function()
    local pair = make_pair()
    build_spawner_trust(pair)
    -- An enemy that both see at the same spot, but the spawner IDs differ: IDs are not a
    -- reliable cross-machine identity after all.
    pair.host_world:spawn("chainsaw.Ch1c0z0Context", 300, 0, 0, 100, { category = 3, kind = 0, group = 1, index = 1 })
    pair.client_world:spawn("chainsaw.Ch1c0z0Context", 300.2, 0, 0, 100, { category = 3, kind = 0, group = 1, index = 2 })
    pair:step(5)
    T.check(not pair.client:spawner_trusted(), "trust revoked")
    local k = { category = 3, kind = 0, group = 77, index = 7 }
    pair.host_world:spawn("chainsaw.Ch1c0z0Context", 400, 0, 0, 100, k)
    local c = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 412, 0, 0, 100, k)
    pair:step(5)
    T.eq(pair.client.net_of[c.id], nil, "no spawner pairing after a disagreement")
end)

T.run("shared_spawner_id_pairs_by_position_only", function()
    local pair = make_pair()
    build_spawner_trust(pair)
    -- A wave spawner created two enemies: same spawner ID, so the ID identifies neither.
    local k = { category = 3, kind = 0, group = 55, index = 1 }
    local h1 = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0, 100, k)
    local h2 = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 6, 0, 0, 100, k)
    local c2 = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 6.3, 0, 0, 100, k)
    local c1 = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 0.2, 0, 0, 100, k)
    pair:step(5)
    T.eq(pair.client.net_of[c1.id], pair.host.net_of[h1.id], "first paired by position")
    T.eq(pair.client.net_of[c2.id], pair.host.net_of[h2.id], "second paired by position")
end)

T.run("context_id_guarded_by_kind_and_distance", function()
    local pair = make_pair()
    local k = { category = 2, kind = 1, group = 50, index = 9 }
    pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0, 100, k)
    local wrong_kind = pair.client_world:spawn("chainsaw.Ch1d0z0Context", 0, 0, 0, 100, k)
    local too_far = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 60, 0, 0, 100, k)
    pair:step(5)
    T.eq(pair.client.net_of[wrong_kind.id], nil, "same ID but different kind is not paired")
    T.eq(pair.client.net_of[too_far.id], nil, "same ID but 60 m away is not paired")
end)

T.run("unpaired_damage_found_by_context_id", function()
    local pair = make_pair()
    -- Untrusted: the report carries no spawner ID.
    local k0 = { category = 3, kind = 0, group = 6, index = 6 }
    pair.host_world:spawn("chainsaw.Ch1c0z0Context", 500, 0, 0, 100, k0)
    local c0 = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 510, 0, 0, 100, k0)
    pair.client:tick(pair.now, pair.client_world:list(), pair.client_world)
    pair.client_world:damage(c0, 5)
    pair.client:tick(pair.now + 0.05, pair.client_world:list(), pair.client_world)
    T.eq(assert(P.decode(pair.to_host[1])).ctx, nil, "no spawner ID before trust")
    pair.to_host = {}
    build_spawner_trust(pair)
    pair.to_host = {}
    local k = { category = 2, kind = 1, group = 7, index = 7 }
    local h = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0, 100, k)
    local c = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 10, 0, 0, 100, k)
    pair.client:tick(pair.now, pair.client_world:list(), pair.client_world) -- baseline, no snapshot yet
    pair.client_world:damage(c, 40)
    pair.client:tick(pair.now + 0.05, pair.client_world:list(), pair.client_world)
    T.eq(#pair.to_host, 1, "report sent before pairing")
    local m = assert(P.decode(pair.to_host[1]))
    T.eq(m.net_id, 0, "no net id yet")
    T.eq(P.ctx_key(m.ctx), "2:1:7:7", "carries ContextID")
    pair.host:tick(pair.now, pair.host_world:list(), pair.host_world)
    pair.host:on_message(m, pair.now, pair.host_world)
    T.eq(h.hp, 60, "host matched it by ContextID although spawns are 10 m apart")
end)

T.run("failed_hp_writes_are_counted", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.host_world.enemy_set_hp = function() return false end -- game offers no working HP writer
    pair.client_world.enemy_set_hp = function() return false end
    pair.client_world:damage(c.a, 30)
    pair.host_world:damage(h.b, 20)
    pair:step(5)
    T.eq(pair.host.counters.damage_failed, 1, "host could not apply the client's damage")
    T.check(pair.client.counters.hp_failed >= 1, "client could not mirror host HP")
end)

local function hit_event(e, damage, wince)
    return { id = e.id, damage = damage, wince = wince, break_ = 0, stopping = 0, dir = { x = 0, y = 0, z = -1 },
        weapon = 4000, critical = false }
end

T.run("host_hits_replay_on_client", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(3)
    pair.host:on_local_hits({ hit_event(h.a, 30, 12) }, pair.now)
    pair:step(1)
    T.eq(#pair.client_world.replays, 1, "replayed once")
    T.eq(pair.client_world.replays[1].id, c.a.id, "on the client's copy of that enemy")
    T.eq(pair.client_world.replays[1].wince, 12, "with the host's wince")
    local hits = pair.client:recent_partner_hits(pair.now, 0.25)
    T.eq(#hits, 1, "shot tracer available")
    T.near(hits[1].pos.x, c.a.pos.x, 1e-6, "tracer ends at our copy")
    T.eq(#pair.client:recent_partner_hits(pair.now + 1, 0.25), 0, "tracer expires")
    T.eq(pair.host.counters.hits_sent, 1, "counted on the host")
end)

T.run("client_hits_replay_on_host", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(3)
    pair.client:on_local_hits({ hit_event(c.b, 20, 8) }, pair.now)
    pair:step(1)
    T.eq(#pair.host_world.replays, 1, "replayed on the host")
    T.eq(pair.host_world.replays[1].id, h.b.id, "on the host's copy")
end)

T.run("unpaired_client_hit_matched_by_spawn", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair.client:tick(0.05, pair.client_world:list(), pair.client_world) -- client has seen its enemies, no pairs yet
    pair.host:tick(0.05, pair.host_world:list(), pair.host_world)
    pair.client:on_local_hits({ hit_event(c.c, 20, 8) }, 0.05)
    for _, bytes in ipairs(pair.to_host) do pair.host:on_message(assert(P.decode(bytes)), 0.05, pair.host_world) end
    T.eq(pair.host_world.replays[1] and pair.host_world.replays[1].id, h.c.id, "found by kind and spawn point")
end)

T.run("replay_setting_off_still_draws_tracers", function()
    local pair = make_pair({ replay_partner_hits = false })
    local h = standard_level(pair)
    pair:step(3)
    pair.host:on_local_hits({ hit_event(h.b, 30, 12) }, pair.now)
    pair:step(1)
    T.eq(#pair.client_world.replays, 0, "no replay")
    T.eq(#pair.client:recent_partner_hits(pair.now, 0.25), 1, "tracer still shown")
end)

T.run("unrestorable_replay_hp_is_not_counted_twice", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(3)
    -- Client: the replay of the host's hit costs our copy 5 HP that cannot be put back.
    pair.client_world.replay_kept = 5
    pair.host_world:damage(h.a, 30)
    pair.host:on_local_hits({ hit_event(h.a, 30, 12) }, pair.now)
    pair:step(4)
    T.eq(pair.client.counters.damage_sent, 0, "the replay's HP loss is not reported as our damage")
    T.eq(h.a.hp, 70, "host HP only reflects its own hit")
    T.eq(c.a.hp, 70, "client follows the host")
    pair.client_world.replay_kept = 0

    -- Host: replaying the client's hit costs 5 HP; the client's damage report covers it.
    pair.host_world.replay_kept = 5
    pair.client_world:damage(c.b, 20)
    pair.client:on_local_hits({ hit_event(c.b, 20, 8) }, pair.now)
    pair:step(4)
    T.eq(h.b.hp, 80, "host takes the client's 20 damage once (5 by the replay + 15)")
    T.eq(c.b.hp, 80, "client agrees")
end)

T.run("host_damage_between_ticks_is_not_overwritten", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(3)
    -- The client's 20 damage report arrives right after the host shot the same enemy for 30,
    -- before the host's next enemy scan.
    pair.client_world:damage(c.a, 20)
    pair.client:tick(pair.now, pair.client_world:list(), pair.client_world)
    pair.host_world:damage(h.a, 30)
    for _, bytes in ipairs(pair.to_host) do pair.host:on_message(assert(P.decode(bytes)), pair.now, pair.host_world) end
    pair.to_host = {}
    T.eq(h.a.hp, 50, "both hits count (100 - 30 - 20)")
end)

T.run("hits_on_unknown_enemies_are_counted", function()
    local pair = make_pair()
    standard_level(pair)
    pair:step(3)
    pair.client:on_message(assert(P.decode(P.encode_enemy_hit({ net_id = 999, pos = { x = 0, y = 0, z = 0 } }))),
        pair.now, pair.client_world)
    T.eq(pair.client.counters.hits_unmatched, 1, "unmatched")
end)

T.run("snapshots_stay_compact", function()
    local pair = make_pair()
    for i = 1, 120 do
        pair.host_world:spawn("chainsaw.Ch1c0z0Context", i * 5, 0, 0)
    end
    pair:step(20) -- 1 second
    -- 10 Hz x ceil(120/25) chunks = ~50 messages per second.
    T.check(pair.traffic.host <= 60, "host sends about 50 snapshot messages/s, got " .. pair.traffic.host)
end)

T.finish()
