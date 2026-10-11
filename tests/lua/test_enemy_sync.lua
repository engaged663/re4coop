-- Two simulated game worlds (host + client) running EnemySync against each other, with
-- every message going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local EnemySync = require("re4coop.enemy_sync")

local GANADO, DOG, CHIEF = "chainsaw.Ch1c0z0Context", "chainsaw.Ch1d1z1Context", "chainsaw.Ch1d0z0Context"

local function make_world(id_base)
    local w = { enemies = {}, next_id = id_base, calls = { set_hp = 0, kill = 0, erase = 0 }, save_dead = nil }

    -- uid: the enemy's level identity (the same on both machines), nil for runtime enemies.
    function w:spawn(kind, x, y, z, hp, uid)
        local e = { id = self.next_id, kind = kind, uid = uid, pos = { x = x, y = y, z = z }, yaw = 0,
            hp = hp or 100, max_hp = hp or 100, alive = true }
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
            out[#out + 1] = { id = e.id, kind = e.kind, uid = e.uid, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
                yaw = e.yaw, hp = e.hp, max_hp = e.max_hp, alive = e.alive, motion = e.motion }
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
        if self.refuse_kill then return false end
        self.calls.kill = self.calls.kill + 1
        e.hp = 0
        e.alive = false
        e.killed = true
        return true
    end

    -- Erasing despawns the enemy (it leaves the list). no_erase: the enemy has no spawn
    -- param; erase_ignored: the game accepted the call but the enemy stayed.
    function w:enemy_erase(id)
        local e = self:get(id)
        if not e or self.no_erase then return false end
        self.calls.erase = self.calls.erase + 1
        e.erased = true
        if not self.erase_ignored then self:remove(e) end
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

    -- The save's eliminated enemies, read over several calls like the real backup table.
    function w:scan_eliminated(budget)
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
    for k, v in pairs({ snapshot_hz = 10, replay_partner_hits = true }) do
        if settings[k] == nil then settings[k] = v end
    end
    local pair = { now = 0, host_world = make_world(1000), client_world = make_world(5000), to_host = {}, to_client = {},
        traffic = { host = 0, client = 0 }, host_kills = {}, client_kills = {},
        host_player = { x = 0, y = 0, z = -5 }, client_player = { x = 0, y = 0, z = -5 } }
    pair.host = EnemySync.new({ role = "host", protocol = P, settings = settings,
        send = function(bytes) table.insert(pair.to_client, bytes) pair.traffic.host = pair.traffic.host + 1 end,
        on_kill = function(id) pair.host_kills[#pair.host_kills + 1] = id end })
    pair.client = EnemySync.new({ role = "client", protocol = P, settings = settings,
        send = function(bytes) table.insert(pair.to_host, bytes) pair.traffic.client = pair.traffic.client + 1 end,
        on_kill = function(id) pair.client_kills[#pair.client_kills + 1] = id end })

    function pair:deliver_to_client()
        for _, bytes in ipairs(self.to_client) do
            self.client:on_message(assert(P.decode(bytes)), self.now, self.client_world)
        end
        self.to_client = {}
    end

    function pair:deliver_to_host()
        for _, bytes in ipairs(self.to_host) do
            self.host:on_message(assert(P.decode(bytes)), self.now, self.host_world)
        end
        self.to_host = {}
    end

    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.05
            local host_players = { local_pos = self.host_player, partner_pos = self.client_player }
            self.host:tick(self.now, self.host_world:list(), self.host_world, host_players)
            self.host:frame(self.now, self.host_world)
            self:deliver_to_client()
            self.client:tick(self.now, self.client_world:list(), self.client_world,
                { local_pos = self.client_player, partner_pos = self.host_player })
            self.client:frame(self.now, self.client_world)
            self:deliver_to_host()
        end
    end

    return pair
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
    -- A spawn point controller put the same three villagers at different points on each
    -- machine, in a different order: spawn positions say nothing, the uid says everything.
    local ha = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x2001)
    local hb = pair.host_world:spawn(GANADO, 1, 0, 0, 100, 0x2002)
    local hc = pair.host_world:spawn(GANADO, 2, 0, 0, 100, 0x2003)
    local cc = pair.client_world:spawn(GANADO, 40, 0, 7, 100, 0x2003)
    local ca = pair.client_world:spawn(GANADO, 1, 0, 0, 100, 0x2001)
    local cb = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x2002) -- standing exactly where the host's A is
    pair:step(5)
    local cl, ho = pair.client, pair.host
    T.eq(cl.net_of[ca.id], ho.net_of[ha.id], "A paired with A")
    T.eq(cl.net_of[cb.id], ho.net_of[hb.id], "B paired with B, not with the A standing on its spot")
    T.eq(cl.net_of[cc.id], ho.net_of[hc.id], "C paired with C 40 m away")
    T.eq(cl.counters.uid_pairs, 3, "all three by uid")
    T.eq(cl.counters.spatial_pairs, 0, "none by position")
end)

T.run("different_enemies_never_pair_even_on_the_same_spot", function()
    local pair = make_pair()
    pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x3001)
    local other = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x3002)
    local runtime = pair.client_world:spawn(GANADO, 0.1, 0, 0, 100, nil)
    pair:step(10)
    T.eq(pair.client.net_of[other.id], nil, "another level enemy is never taken for it")
    T.eq(pair.client.net_of[runtime.id], nil, "nor a runtime enemy")
end)

T.run("runtime_enemies_pair_by_kind_and_spawn_point", function()
    local pair = make_pair()
    local h1 = pair.host_world:spawn(GANADO, 0, 0, 0, 100, nil)
    local h2 = pair.host_world:spawn(GANADO, 6, 0, 0, 100, nil)
    local c2 = pair.client_world:spawn(GANADO, 6.3, 0, 0, 100, nil)
    local c1 = pair.client_world:spawn(GANADO, 0.2, 0, 0, 100, nil)
    local far = pair.client_world:spawn(GANADO, 30, 0, 0, 100, nil)
    local dog = pair.client_world:spawn(DOG, 0, 0, 0.5, 100, nil)
    pair:step(5)
    T.eq(pair.client.net_of[c1.id], pair.host.net_of[h1.id], "first by position")
    T.eq(pair.client.net_of[c2.id], pair.host.net_of[h2.id], "second by position")
    T.eq(pair.client.net_of[far.id], nil, "too far is not the same enemy")
    T.eq(pair.client.net_of[dog.id], nil, "another kind is not the same enemy")
    T.eq(pair.client.counters.spatial_pairs, 2, "counted")
end)

T.run("a_reused_context_is_a_new_enemy", function()
    local pair = make_pair()
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0x4001)
    local c = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0x4001)
    pair:step(5)
    T.check(pair.client.net_of[c.id] ~= nil, "paired")
    -- The game gives the same context to another enemy (pooled): different uid.
    c.uid = 0x4002
    pair:step(3)
    T.eq(pair.client.net_of[c.id], nil, "no longer paired with the old enemy")
    local h2 = pair.host_world:spawn(GANADO, 5, 0, 0, 100, 0x4002)
    pair:step(5)
    T.eq(pair.client.net_of[c.id], pair.host.net_of[h2.id], "paired with its new identity")
    T.check(h.alive, "nothing died")
end)

-------------------------------------------------------------------------------
-- Health and deaths during a fight
-------------------------------------------------------------------------------

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
    pair:step(25) -- the client has seen its enemies for a while (a fight in progress)
    pair.host_world:damage(h.b, 55)
    pair:step(3)
    T.eq(c.b.hp, 45, "client HP lowered to host value")
    pair.host_world:damage(h.c, 1000)
    pair:step(3)
    T.eq(c.c.alive, false, "client copy died")
    T.eq(c.c.killed, true, "with its own death (in front of the player)")
    T.eq(c.c.erased, nil, "not erased")
    T.eq(#pair.client_kills, 1, "the client rolls its own loot for it")
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
    T.eq(#pair.host_kills, 1, "the host rolls its own loot for it")
    pair:step(10)
    T.eq(pair.client_world.calls.kill, 0, "the client is not asked to kill it again")
end)

T.run("damage_before_pairing_is_matched_by_uid", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    -- The client has seen A once (HP baseline) but no host snapshot has arrived yet: the
    -- report goes out without a net id and the host finds A by its uid.
    pair.client:tick(pair.now, pair.client_world:list(), pair.client_world)
    pair.client_world:damage(c.a, 10)
    pair.host:tick(pair.now, pair.host_world:list(), pair.host_world)
    pair.client:tick(pair.now + 0.01, pair.client_world:list(), pair.client_world)
    local report = assert(P.decode(pair.to_host[#pair.to_host]))
    T.eq(report.net_id, 0, "no net id yet")
    T.eq(report.uid, 0x1001, "carries the uid")
    pair:deliver_to_host()
    T.eq(h.a.hp, 90, "landed on the right host enemy")
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

T.run("host_damage_between_ticks_is_not_overwritten", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(3)
    -- The client's 20 damage report arrives right after the host shot the same enemy for 30,
    -- before the host's next enemy scan.
    pair.client_world:damage(c.a, 20)
    pair.client:tick(pair.now, pair.client_world:list(), pair.client_world)
    pair.host_world:damage(h.a, 30)
    pair:deliver_to_host()
    T.eq(h.a.hp, 50, "both hits count (100 - 30 - 20)")
end)

-------------------------------------------------------------------------------
-- Enemies dead in the partner's world
-------------------------------------------------------------------------------

T.run("enemies_the_host_killed_never_appear_for_a_late_client", function()
    local pair = make_pair()
    standard_level(pair)
    local hd = pair.host_world:spawn(GANADO, 50, 0, 50, 100, 0x5001)
    pair:step(5)
    pair.host_world:damage(hd, 500) -- the host clears the next room alone...
    pair:step(5)
    pair.host_world:remove(hd)      -- ...and the corpse despawns from the host's list
    pair:step(20)
    -- The client arrives: its level spawns that enemy (wherever its own spawner put it).
    local cd = pair.client_world:spawn(GANADO, 42, 0, 60, 100, 0x5001)
    pair:step(2)
    T.eq(cd.erased, true, "erased the moment it appears")
    T.eq(cd.killed, nil, "not killed: no death animation, no corpse")
    T.eq(pair.client_world:get(cd.id), nil, "gone from the client's world")
    T.eq(#pair.client_kills, 0, "no loot for an enemy the client never fought")
    T.eq(pair.client.counters.erased, 1, "counted")
end)

T.run("an_old_dead_enemy_far_away_is_erased", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    local hf = pair.host_world:spawn(DOG, 100, 0, 0, 80, 0x5101)
    local cf = pair.client_world:spawn(DOG, 101, 0, 0, 80, 0x5101)
    pair:step(30) -- both had it loaded for a while, far from the client
    pair.host_world:damage(hf, 500)
    pair:step(3)
    T.eq(cf.erased, true, "nobody on the client could see it die: erased")
    T.eq(c.a.alive, true, "others untouched")
end)

T.run("an_enemy_without_spawn_param_is_killed_instead", function()
    local pair = make_pair()
    standard_level(pair)
    pair.client_world.no_erase = true
    local hd = pair.host_world:spawn(GANADO, 50, 0, 50, 100, 0x5201)
    pair:step(5)
    pair.host_world:damage(hd, 500)
    pair:step(5)
    local cd = pair.client_world:spawn(GANADO, 50, 0, 50, 100, 0x5201)
    pair:step(2)
    T.eq(cd.killed, true, "killed when it cannot be erased")
    T.eq(cd.alive, false, "dead")
end)

T.run("an_erase_that_did_not_take_is_followed_by_a_kill", function()
    local pair = make_pair()
    standard_level(pair)
    pair.client_world.erase_ignored = true
    local hd = pair.host_world:spawn(GANADO, 50, 0, 50, 100, 0x5301)
    pair:step(5)
    pair.host_world:damage(hd, 500)
    pair:step(5)
    local cd = pair.client_world:spawn(GANADO, 50, 0, 50, 100, 0x5301)
    pair:step(2)
    T.eq(cd.erased, true, "erase tried")
    T.eq(cd.alive, true, "but the game left it standing")
    pair:step(70)
    T.eq(cd.killed, true, "a few seconds later it is killed")
    T.eq(pair.client_world.calls.erase, 1, "erase not retried")
end)

T.run("a_kill_the_game_refuses_is_retried", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(25)
    pair.client_world.refuse_kill = true -- e.g. an invincible phase
    pair.host_world:damage(h.a, 500)
    pair:step(5)
    T.eq(c.a.alive, true, "still standing")
    pair.client_world.refuse_kill = false
    pair:step(25)
    T.eq(c.a.alive, false, "dies once the game accepts it")
end)

T.run("erasing_can_be_switched_off", function()
    local pair = make_pair({ enemy_erase = false })
    standard_level(pair)
    local hd = pair.host_world:spawn(GANADO, 50, 0, 50, 100, 0x5401)
    pair:step(5)
    pair.host_world:damage(hd, 500)
    pair:step(5)
    local cd = pair.client_world:spawn(GANADO, 50, 0, 50, 100, 0x5401)
    pair:step(2)
    T.eq(cd.killed, true, "killed instead")
    T.eq(pair.client_world.calls.erase, 0, "never erased")
end)

T.run("a_joining_client_gets_every_enemy_dead_in_the_hosts_save", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    -- Killed in earlier sessions: the host's save has them eliminated (never loaded now).
    pair.host_world.save_dead = { 0x6001, 0x6002 }
    -- Killed this session before the client asked.
    local hd = pair.host_world:spawn(GANADO, 30, 0, 0, 100, 0x6003)
    pair:step(3)
    pair.host_world:damage(hd, 500)
    pair:step(3)
    pair.host:request_graveyard(pair.now)
    pair:step(1)
    T.eq(pair.host:summary().listing_dead, true, "reading the save takes a few ticks")
    pair:step(5)
    T.eq(pair.client:summary().dead_known, 3, "client knows all three")
    T.eq(pair.client.counters.graves_received, 1, "one list")
    -- The client's level spawns all three: none of them shows up.
    local c1 = pair.client_world:spawn(GANADO, 70, 0, 0, 100, 0x6001)
    local c2 = pair.client_world:spawn(DOG, 75, 0, 0, 80, 0x6002)
    local c3 = pair.client_world:spawn(GANADO, 31, 0, 0, 100, 0x6003)
    pair:step(2)
    T.eq(c1.erased and c2.erased and c3.erased, true, "all erased")
    T.eq(c.a.alive and c.b.alive and c.c.alive, true, "the living ones stay")
end)

T.run("a_new_graveyard_list_replaces_the_old_one", function()
    local pair = make_pair()
    pair.host_world.save_dead = { 0x6101, 0x6102 }
    pair.host:request_graveyard(pair.now)
    pair:step(5)
    T.eq(pair.client:summary().dead_known, 2, "two")
    pair.host_world.save_dead = { 0x6102 }
    pair.host:request_graveyard(pair.now)
    pair:step(5)
    T.eq(pair.client:summary().dead_known, 1, "replaced, not added")
    T.eq(pair.host.counters.graves_sent, 2, "two lists sent")
end)

T.run("a_corpse_the_host_finds_is_announced", function()
    local pair = make_pair()
    -- Killed by the host before the session; its corpse is still in the host's list, while
    -- the client's copy (from the client's own save) is alive.
    local hd = pair.host_world:spawn(GANADO, 20, 0, 0, 100, 0x7001)
    hd.hp, hd.alive = 0, false
    local cd = pair.client_world:spawn(GANADO, 20, 0, 0, 100, 0x7001)
    pair:step(5)
    T.eq(cd.erased, true, "the client's copy is gone too")
    T.eq(pair.client_world:get(cd.id), nil, "despawned")
end)

T.run("the_old_scenes_dead_right_after_a_host_reload_are_not_news", function()
    local pair = make_pair()
    local cd = pair.client_world:spawn(GANADO, 20, 0, 0, 100, 0x7101)
    pair:step(5)
    pair.host:on_local_reload()
    -- For a moment the host's list still holds a dead enemy of the scene it just left.
    local old = pair.host_world:spawn(GANADO, 20, 0, 0, 100, 0x7101)
    old.hp, old.alive = 0, false
    pair:step(3)
    pair.host_world:remove(old)
    pair:step(5)
    T.eq(cd.erased, nil, "the client's copy is left alone")
    T.eq(cd.alive, true, "alive")
end)

T.run("a_stale_snapshot_never_revives_a_dead_enemy", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(25)
    -- A snapshot taken before the death arrives after the death notice.
    local old = P.encode_enemy_snapshots(pair.now, {
        { net_id = pair.host.net_of[h.a.id], uid = h.a.uid, kind_hash = P.hash(GANADO), pos = h.a.pos, yaw = 0, hp = 100,
          max_hp = 100, flags = P.ENEMY_FLAGS.ALIVE } })[1]
    pair.host_world:damage(h.a, 500)
    pair.host:tick(pair.now + 0.05, pair.host_world:list(), pair.host_world)
    pair.to_client[#pair.to_client + 1] = old
    pair:deliver_to_client()
    pair:step(3)
    T.eq(c.a.alive, false, "still dead")
    T.eq(pair.client:summary().dead_known, 1, "still buried")
end)

T.run("an_enemy_alive_again_in_the_hosts_world_is_unburied", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    pair.client:on_message(assert(P.decode(P.encode_enemy_dead(77, 0x1002))), pair.now, pair.client_world)
    T.eq(pair.client:summary().dead_known, 1, "buried")
    pair:step(1)
    T.eq(c.b.erased, true, "the client's copy goes")
    pair:step(60) -- the host keeps reporting B alive (respawned, or its world reloaded)
    T.eq(pair.client:summary().dead_known, 0, "unburied")
    -- The client's level spawns it again later: now it pairs instead of disappearing.
    local c2 = pair.client_world:spawn(GANADO, 10, 0, 0, 100, 0x1002)
    pair:step(5)
    T.eq(pair.client.net_of[c2.id], pair.host.net_of[h.b.id], "paired with the host's living B")
    T.eq(c2.erased, nil, "not erased")
end)

T.run("client_kill_where_the_host_had_no_enemy_applies_later", function()
    local pair = make_pair()
    standard_level(pair)
    pair:step(5)
    -- The client clears a room the host has not loaded.
    local far = pair.client_world:spawn(GANADO, 200, 0, 0, 100, 0x8001)
    pair:step(5)
    pair.client_world:damage(far, 500)
    pair:step(5)
    T.eq(pair.host:summary().dead_known, 1, "the host remembers the kill")
    -- The host arrives: its level spawns that enemy, which never shows up.
    local hf = pair.host_world:spawn(GANADO, 190, 0, 3, 100, 0x8001)
    local other = pair.host_world:spawn(GANADO, 200, 0, 0, 100, 0x8002)
    pair:step(3)
    T.eq(hf.erased, true, "host's copy erased on arrival")
    T.eq(other.alive, true, "another enemy at the same spot is not touched")
    T.eq(pair.host.counters.late_kills, 1, "counted")
end)

T.run("host_reload_forgets_old_deaths", function()
    local pair = make_pair()
    local hd = pair.host_world:spawn(GANADO, 50, 0, 50, 100, 0x9001)
    pair:step(5)
    pair.host_world:damage(hd, 500) -- host kills it alone
    pair:step(5)
    T.eq(pair.client:summary().dead_known, 1, "buried on the client")
    pair.host:on_local_reload()      -- the host died and reloaded the checkpoint...
    hd.hp, hd.alive = 100, true      -- ...which has that enemy alive
    pair:step(10)
    T.eq(pair.client:summary().dead_known, 0, "forgotten")
    local cd = pair.client_world:spawn(GANADO, 50.5, 0, 49.8, 100, 0x9001)
    pair:step(12)
    T.eq(cd.alive, true, "the reloaded host's world has it alive again: not removed")
end)

T.run("a_client_reload_keeps_the_hosts_dead_and_forgets_its_old_scene", function()
    local pair = make_pair()
    standard_level(pair)
    local hd = pair.host_world:spawn(GANADO, 50, 0, 50, 100, 0x9101)
    pair:step(5)
    pair.host_world:damage(hd, 500)
    pair:step(5)
    local cd = pair.client_world:spawn(GANADO, 50, 0, 50, 100, 0x9101)
    pair:step(2)
    T.eq(cd.erased, true, "erased once")
    -- The client dies and reloads: its level spawns that enemy again (the game may even reuse
    -- the same context).
    pair.client:on_local_reload()
    cd.erased = nil
    pair.client_world.enemies[#pair.client_world.enemies + 1] = cd
    pair:step(2)
    T.eq(cd.erased, true, "erased again, not taken for a failed erase of the old scene")
    T.eq(pair.client_world.calls.erase, 2, "two erases")
    T.eq(pair.client:summary().dead_known, 1, "the host's dead are still known")
end)

T.run("two_waves_at_the_same_door_are_never_confused", function()
    local pair = make_pair()
    -- Wave 1 dies at the door with the client watching.
    local h1 = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0xA001)
    local c1 = pair.client_world:spawn(GANADO, 0, 0, 0, 100, 0xA001)
    pair:step(25)
    pair.host_world:damage(h1, 500)
    pair:step(5)
    T.eq(c1.alive, false, "client copy died with it")
    pair.host_world:remove(h1)
    pair.client_world:remove(c1)
    -- Wave 2 spawns at the same door: first on the client, a moment later on the host.
    local c2 = pair.client_world:spawn(GANADO, 0.1, 0, 0, 100, 0xA002)
    pair:step(30)
    T.eq(c2.alive, true, "the new enemy is not mistaken for the dead one")
    local h2 = pair.host_world:spawn(GANADO, -0.1, 0, 0, 100, 0xA002)
    pair:step(5)
    T.eq(pair.client.net_of[c2.id], pair.host.net_of[h2.id], "and pairs with the host's new enemy")
end)

T.run("unmatched_enemies_are_left_alone", function()
    local pair = make_pair()
    standard_level(pair)
    local only_client = pair.client_world:spawn(GANADO, 100, 0, 100, 100, 0xB001)
    local only_host = pair.host_world:spawn(GANADO, -80, 0, 0, 100, 0xB002)
    pair:step(10)
    T.eq(pair.client.net_of[only_client.id], nil, "client-only enemy unpaired")
    pair.host_world:damage(only_host, 1000)
    pair:step(5)
    T.eq(only_client.alive, true, "nothing killed by mistake")
end)

-------------------------------------------------------------------------------
-- Hits
-------------------------------------------------------------------------------

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

T.run("unpaired_client_hit_matched_by_uid", function()
    local pair = make_pair()
    local h, c = standard_level(pair)
    pair.client:tick(0.05, pair.client_world:list(), pair.client_world) -- client has seen its enemies, no pairs yet
    pair.host:tick(0.05, pair.host_world:list(), pair.host_world)
    pair.client:on_local_hits({ hit_event(c.c, 20, 8) }, 0.05)
    pair:deliver_to_host()
    T.eq(pair.host_world.replays[1] and pair.host_world.replays[1].id, h.c.id, "found by its uid")
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

T.run("hits_on_unknown_enemies_are_counted", function()
    local pair = make_pair()
    standard_level(pair)
    pair:step(3)
    pair.client:on_message(assert(P.decode(P.encode_enemy_hit({ net_id = 999, uid = 0xDEAD, pos = { x = 0, y = 0, z = 0 } }))),
        pair.now, pair.client_world)
    T.eq(pair.client.counters.hits_unmatched, 1, "unmatched")
end)

T.run("snapshots_stay_compact", function()
    local pair = make_pair()
    for i = 1, 120 do
        pair.host_world:spawn(GANADO, i * 5, 0, 0, 100, 0xC000 + i)
    end
    pair:step(20) -- 1 second
    -- 10 Hz x ceil(120/19) chunks = 70 messages per second.
    T.check(pair.traffic.host <= 77, "host sends about 70 snapshot messages/s, got " .. pair.traffic.host)
    T.check(pair.traffic.client <= 22, "client sends about 20 reports/s, got " .. pair.traffic.client)
end)

-------------------------------------------------------------------------------
-- The host runs every enemy: the client's copies follow the host's (position, facing,
-- animation) with their own AI off. An enemy never changes hands.
-------------------------------------------------------------------------------

-- The transform, animation and AI writers game.lua provides.
local function with_mirroring(w)
    w.calls.transform, w.calls.motion, w.calls.ai = 0, 0, 0
    w.ai_off = {}
    function w:enemy_set_transform(id, pos, yaw)
        local e = self:get(id)
        if not e then return false end
        self.calls.transform = self.calls.transform + 1
        e.pos = { x = pos.x, y = pos.y, z = pos.z }
        e.yaw = yaw
        return true
    end
    function w:enemy_set_motion(id, motion)
        local e = self:get(id)
        if not e then return false end
        self.calls.motion = self.calls.motion + 1
        e.motion = { bank = motion.bank, id = motion.id, frame = motion.frame }
        return true
    end
    function w:enemy_set_ai(id, on)
        self.calls.ai = self.calls.ai + 1
        self.ai_off[id] = (not on) or nil
        return true
    end
    w.hidden = {}
    function w:enemy_set_visible(id, on)
        self.hidden[id] = (not on) or nil
        return true
    end
    local kill, erase = w.enemy_kill, w.enemy_erase
    function w:enemy_kill(id)
        self.killed_with_ai_off = self.killed_with_ai_off or (self.ai_off[id] == true)
        return kill(self, id)
    end
    function w:enemy_erase(id)
        self.erased_with_ai_off = self.erased_with_ai_off or (self.ai_off[id] == true)
        return erase(self, id)
    end
    return w
end

local function make_mirror_pair(settings)
    local pair = make_pair(settings)
    with_mirroring(pair.host_world)
    with_mirroring(pair.client_world)
    pair.host_player = { x = 0, y = 0, z = -30 }
    pair.client_player = { x = 0, y = 0, z = -30 }
    return pair
end

T.run("client_mirrors_host_enemy_movement", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    pair:step(5)
    -- The host's enemy walks 6 m over 0.5 s; the client's copy follows smoothly.
    for i = 1, 10 do
        h.b.pos = { x = 10 + i * 0.6, y = 0, z = 0 }
        h.b.yaw = 0.1 * i
        pair:step(1)
    end
    pair:step(8) -- let the interpolation buffer drain
    T.near(c.b.pos.x, 16, 0.05, "client copy reached the host's position")
    T.near(c.b.yaw, 1.0, 0.02, "and its facing")
    T.check(pair.client_world.calls.transform > 5, "moved over several frames, not one snap")
    T.eq(pair.client_world.ai_off[c.b.id], true, "the client copy's own AI is off")
    T.eq(pair.host_world.ai_off[h.b.id], nil, "the host's runs")
end)

T.run("a_copy_spawned_elsewhere_jumps_to_the_hosts_enemy", function()
    local pair = make_mirror_pair()
    local h = pair.host_world:spawn(GANADO, 0, 0, 0, 100, 0xD001)
    pair:step(5)
    -- The client's spawn point controller chose another spawn point for the same villager.
    local c = pair.client_world:spawn(GANADO, 35, 0, 12, 100, 0xD001)
    pair:step(6)
    T.near(c.pos.x, 0, 0.01, "moved to where the host's copy is")
    T.near(c.pos.z, 0, 0.01, "in every axis")
    T.eq(pair.client_world.ai_off[c.id], true, "following it with its AI off")
    T.check(h.alive, "untouched on the host")
end)

T.run("an_enemy_the_host_does_not_run_is_held_on_the_client_until_the_host_loads_it", function()
    local pair = make_mirror_pair()
    pair.host_player = { x = 0, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    -- The client ran ahead: its level spawned a villager the host's level has not spawned.
    local c = pair.client_world:spawn(GANADO, 101, 0, 1, 100, 0xD101)
    pair:step(10)
    T.eq(pair.client.net_of[c.id], nil, "nothing to follow yet")
    T.eq(pair.client_world.ai_off[c.id], true, "the client's game does not run it: AI off")
    T.eq(pair.client_world.hidden[c.id], true, "and it is not drawn")
    T.eq(pair.client_world.calls.transform, 0, "not moved by the sync")
    T.eq(pair.client:summary().held, 1, "reported as held")
    -- The host's level spawns it now: the client sees the host's enemy.
    local h = pair.host_world:spawn(GANADO, 40, 0, 0, 100, 0xD101)
    pair:step(10)
    T.eq(pair.client.net_of[c.id], pair.host.net_of[h.id], "paired")
    T.eq(pair.client_world.ai_off[c.id], true, "follows with its AI off")
    T.eq(pair.client_world.hidden[c.id], nil, "drawn again")
    T.near(c.pos.x, 40, 0.05, "where the host's enemy is")
    T.eq(pair.host_world.calls.ai, 0, "the host's enemy keeps its AI")
    -- The host's level unloads it again: the client holds its copy where it is.
    pair.host_world:remove(h)
    pair:step(60)
    T.eq(pair.client.net_of[c.id], nil, "no longer paired")
    T.eq(pair.client_world.ai_off[c.id], true, "still no AI of its own")
    T.eq(pair.client_world.hidden[c.id], true, "hidden again")
end)

T.run("the_client_can_kill_an_enemy_it_holds", function()
    local pair = make_mirror_pair()
    pair.host_player = { x = 0, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    local c = pair.client_world:spawn(GANADO, 101, 0, 1, 100, 0xD102)
    pair:step(5)
    T.eq(pair.client_world.ai_off[c.id], true, "held")
    pair.client_world:damage(c, 100) -- our player's shot
    pair:step(5)
    T.eq(pair.client_world.ai_off[c.id], nil, "its death runs with its own logic")
    T.eq(pair.client_world.hidden[c.id], nil, "and is seen")
    -- The host's level spawns it later: it dies there too.
    local h = pair.host_world:spawn(GANADO, 101, 0, 1, 100, 0xD102)
    pair:step(10)
    T.check(h.erased or not h.alive, "dead in the host's world")
    T.eq(pair.host.counters.late_kills, 1, "the client's kill applied when the host's level spawned it")
end)

T.run("without_host_only_an_enemy_only_the_client_has_runs_in_the_clients_game", function()
    local pair = make_mirror_pair({ enemy_host_only = false })
    pair.host_player = { x = 0, y = 0, z = 0 }
    pair.client_player = { x = 100, y = 0, z = 0 }
    -- The client ran ahead: its villager chases it where the host's level has not spawned it.
    local c = pair.client_world:spawn(GANADO, 101, 0, 1, 100, 0xD101)
    pair:step(10)
    T.eq(pair.client.net_of[c.id], nil, "nothing to follow yet")
    T.eq(pair.client_world.ai_off[c.id], nil, "its own AI runs it (it fights the client)")
    T.eq(pair.client_world.calls.transform, 0, "not moved by the sync")
    -- The host's level spawns it now: from here on the host's game runs it.
    local h = pair.host_world:spawn(GANADO, 40, 0, 0, 100, 0xD101)
    pair:step(10)
    T.eq(pair.client.net_of[c.id], pair.host.net_of[h.id], "paired")
    T.eq(pair.client_world.ai_off[c.id], true, "the client's copy follows with its AI off")
    T.near(c.pos.x, 40, 0.05, "to where the host's enemy is")
    T.eq(pair.host_world.calls.ai, 0, "the host's enemy keeps its AI")
end)

T.run("the_host_runs_every_enemy_even_next_to_the_client", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    pair.host_player = { x = 0, y = 0, z = -40 }  -- far away
    pair.client_player = { x = 11, y = 0, z = 1 } -- right next to B, shooting it
    for _ = 1, 20 do
        pair.client:on_local_hits({ hit_event(c.b, 1, 1) }, pair.now)
        pair:step(2)
    end
    T.eq(pair.client_world.ai_off[c.b.id], true, "B follows the host on the client")
    T.eq(pair.client_world.ai_off[c.a.id], true, "and so do the others")
    T.eq(pair.host_world.calls.ai, 0, "the host never switches an AI off")
    T.eq(pair.host_world.calls.transform, 0, "nor moves its enemies")
    h.b.pos = { x = 12, y = 0, z = 3 }
    pair:step(10)
    T.near(c.b.pos.z, 3, 0.05, "the client's B moves with the host's")
end)

T.run("the_host_reads_animations_only_for_enemies_the_client_has", function()
    local pair = make_mirror_pair()
    local h = standard_level(pair)
    local only_host = pair.host_world:spawn(GANADO, -80, 0, 0, 100, 0xE001)
    pair:step(10)
    T.eq(pair.host:wants_motion(h.a.id), true, "the client has A: its animation is read and sent")
    T.eq(pair.host:wants_motion(only_host.id), false, "the client lacks this one")
    T.eq(pair.host:summary().paired, 3, "three enemies with a copy at the client")
    T.eq(pair.client:wants_motion(1), false, "the client never sends animations")
end)

T.run("an_enemy_the_client_kills_dies_with_its_own_ai_and_on_the_host", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    pair.client_player = { x = 0, y = 0, z = 9 }
    pair:step(25)
    T.eq(pair.client_world.ai_off[c.c.id], true, "C follows the host")
    pair.client_world:damage(c.c, 1000) -- the client's shotgun
    pair:step(1)
    T.eq(pair.client_world.ai_off[c.c.id], nil, "its AI is back on for the death")
    pair:step(5)
    T.eq(h.c.alive, false, "the host's C died from the client's damage report")
    T.eq(pair.host_world.calls.kill, 1, "killed once")
    T.eq(pair.client_world.calls.kill, 0, "the client's copy died on its own (not killed again)")
end)

T.run("a_copy_without_news_from_the_host_waits_where_it_is", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    pair:step(10)
    T.eq(pair.client_world.ai_off[c.a.id], true, "following")
    local x = c.a.pos.x
    -- The host's game stops sending (loading, a hitch...): nothing runs the client's copy.
    for _ = 1, 30 do
        pair.now = pair.now + 0.05
        pair.client:tick(pair.now, pair.client_world:list(), pair.client_world, { local_pos = pair.client_player })
        pair.client:frame(pair.now, pair.client_world)
        pair.to_host = {}
    end
    T.eq(pair.client_world.ai_off[c.a.id], true, "its own AI stays off")
    T.near(c.a.pos.x, x, 0.01, "it waits where it was")
    h.a.pos = { x = h.a.pos.x + 2, y = 0, z = h.a.pos.z }
    pair:step(10)
    T.near(c.a.pos.x, x + 2, 0.05, "it follows again once the host is back")
end)

T.run("without_host_only_a_copy_without_news_from_the_host_runs_on_its_own", function()
    local pair = make_mirror_pair({ enemy_host_only = false })
    local h, c = standard_level(pair)
    pair:step(10)
    T.eq(pair.client_world.ai_off[c.a.id], true, "following")
    -- The host's game stops sending (loading, a hitch...): only the client runs.
    for _ = 1, 30 do
        pair.now = pair.now + 0.05
        pair.client:tick(pair.now, pair.client_world:list(), pair.client_world, { local_pos = pair.client_player })
        pair.client:frame(pair.now, pair.client_world)
        pair.to_host = {}
    end
    T.eq(pair.client_world.ai_off[c.a.id], nil, "its own AI takes over after a second")
    pair:step(10)
    T.eq(pair.client_world.ai_off[c.a.id], true, "it follows again once the host is back")
    T.check(h.a.alive, "the host's enemy is untouched")
end)

T.run("facing_blends_the_short_way_round", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    h.a.yaw = 3.0
    pair:step(10)
    h.a.yaw = -3.0 -- 0.28 rad further, across +-pi
    pair:step(2)
    local seen_far = false
    for _ = 1, 8 do
        pair:step(1)
        if math.abs(c.a.yaw) < 2.5 then seen_far = true end
    end
    T.check(not seen_far, "never turns the long way through 0")
    T.near(math.abs(c.a.yaw), 3.0, 0.05, "ends facing the same way")
end)

T.run("animation_is_mirrored", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    h.a.motion = { bank = 100, id = 2003, frame = 4 }
    pair:step(10)
    T.eq(c.a.motion and c.a.motion.id, 2003, "client plays the host's animation")
    local changes = pair.client_world.calls.motion
    pair:step(10)
    T.eq(pair.client_world.calls.motion, changes, "the same animation is not restarted every frame")
    h.a.motion = { bank = 100, id = 2010, frame = 0 }
    pair:step(8)
    T.eq(c.a.motion.id, 2010, "the next one follows")
end)

T.run("mirroring_off_keeps_every_copy_local", function()
    local pair = make_mirror_pair({ enemy_mirror = false })
    local h, c = standard_level(pair)
    pair.client_player = { x = 11, y = 0, z = 1 }
    pair:step(10)
    h.b.pos = { x = 20, y = 0, z = 0 }
    pair:step(5)
    T.eq(pair.client_world.calls.transform, 0, "no mirroring")
    T.eq(pair.client_world.calls.ai, 0, "AI never touched")
    pair.host_world:damage(h.b, 30)
    pair:step(3)
    T.eq(c.b.hp, 70, "HP still follows the host")
end)

T.run("switching_mirroring_off_gives_the_ai_back", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    pair:step(10)
    T.eq(pair.client_world.ai_off[c.a.id], true, "A mirrored with its AI off")
    pair.client.settings.enemy_mirror = false
    pair:step(2)
    T.eq(next(pair.client_world.ai_off), nil, "mirroring off: every AI back on")
    pair.client.settings.enemy_mirror = true
    pair:step(2)
    T.eq(pair.client_world.ai_off[c.a.id], true, "off again")
end)

T.run("mirrored_enemy_dies_with_its_ai_on", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    -- Both players near C: it dies in front of the client.
    pair.host_player = { x = 0, y = 0, z = 4 }
    pair.client_player = { x = 0, y = 0, z = 3 }
    pair:step(25)
    T.eq(pair.client_world.ai_off[c.c.id], true, "C mirrored on the client")
    pair.host_world:damage(h.c, 1000)
    pair:step(5)
    T.eq(c.c.alive, false, "client copy died")
    T.eq(pair.client_world.ai_off[c.c.id], nil, "AI back on for the death")
    T.eq(pair.client_world.killed_with_ai_off, false, "never killed while its AI was off")
end)

T.run("a_mirrored_enemy_is_erased_with_its_ai_on", function()
    local pair = make_mirror_pair()
    local h, c = standard_level(pair)
    local hf = pair.host_world:spawn(DOG, 90, 0, 0, 80, 0xF001)
    local cf = pair.client_world:spawn(DOG, 91, 0, 0, 80, 0xF001)
    pair:step(25)
    T.eq(pair.client_world.ai_off[cf.id], true, "mirrored")
    pair.host_world:damage(hf, 500)
    pair:step(3)
    T.eq(cf.erased, true, "erased (far from the client's player)")
    T.eq(pair.client_world.erased_with_ai_off, false, "its head goes back to the game's pool switched on")
end)

T.finish()
