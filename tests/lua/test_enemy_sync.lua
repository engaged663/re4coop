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

T.run("pairs_by_context_id_even_when_spawns_differ", function()
    local pair = make_pair()
    -- Same level enemies, but the client loaded later and saw them 8-12 m away from where the
    -- host first saw them: spatial pairing would fail (3 m radius), the ContextID does not.
    local ka, kb = { category = 2, kind = 1, group = 300, index = 1 }, { category = 2, kind = 1, group = 300, index = 2 }
    local ha = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 0, 0, 0, 100, ka)
    local hb = pair.host_world:spawn("chainsaw.Ch1c0z0Context", 1, 0, 0, 100, kb)
    local cb = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 9, 0, 6, 100, kb)
    local ca = pair.client_world:spawn("chainsaw.Ch1c0z0Context", 12, 0, 0, 100, ka)
    pair:step(5)
    T.eq(pair.client.net_of[ca.id], pair.host.net_of[ha.id], "A paired by ID")
    T.eq(pair.client.net_of[cb.id], pair.host.net_of[hb.id], "B paired by ID (not swapped)")
    T.check(pair.client.counters.id_matches >= 2, "ID matches counted")
    pair.client_world:damage(cb, 25)
    pair:step(5)
    T.eq(hb.hp, 75, "damage lands on the right enemy")
    T.eq(ha.hp, 100, "not on the other one")
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
