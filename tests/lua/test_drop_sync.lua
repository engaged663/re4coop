-- Identical enemy drops: host detection, client suppression/spawning and self-verification,
-- through the real protocol codec.
local T = require("testlib")
local P = require("re4coop.protocol")
local DropSync = require("re4coop.drop_sync")

local HERB, AMMO, COG = 112800000, 112806400, 119235200

-- Minimal stand-ins for the two sessions' EnemySync state (only the maps DropSync reads).
local function make_pair(settings)
    settings = settings or { sync_drops = true }
    local pair = { now = 0, to_client = {}, host_items = {}, client_items = {}, next_id = 1 }
    pair.host_es = { net_of = { [101] = 7 }, by_id = { [101] = { pos = { x = 10, y = 0, z = 0 } } }, local_of = {} }
    pair.client_es = { local_of = { [7] = 201 }, net_of = { [201] = 7 },
        by_id = { [201] = { pos = { x = 12, y = 0, z = 1 } } } }
    local function is_key(id) return id >= 119000000 and id <= 119999999 end
    pair.host = DropSync.new({ role = "host", protocol = P, settings = settings, enemy_sync = pair.host_es,
        is_key_item = is_key, send = function(b) table.insert(pair.to_client, b) end })
    pair.client = DropSync.new({ role = "client", protocol = P, settings = settings, enemy_sync = pair.client_es,
        is_key_item = is_key, send = function() end })

    pair.game = { spawned = {}, suppress = {}, spawn_works = true, spawn_errors = false }
    function pair.game:spawn_drop(item_id, count, pos, stage)
        if self.spawn_errors then return false end
        self.spawned[#self.spawned + 1] = { item_id = item_id, count = count, pos = pos, stage = stage }
        if self.spawn_works then pair:place(pair.client_items, item_id, pos.x, pos.z) end
        return true
    end
    function pair.game:set_drop_suppress(set) self.suppress = set end

    function pair:place(list, item_id, x, z, count)
        local p = { id = self.next_id, item_id = item_id, count = count or 1, pos = { x = x, y = 0, z = z }, stage = 43400 }
        self.next_id = self.next_id + 1
        list[#list + 1] = p
        return p
    end
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.25
            self.host:on_pickups(self.now, self.host_items, 43400)
            self.client:update_pairs(self.now, self.game)
            for _, b in ipairs(self.to_client) do
                self.client:on_message(assert(P.decode(b)), self.now, self.game, 43401)
            end
            self.to_client = {}
            self.client:on_pickups(self.now, self.client_items, 43401)
        end
    end
    return pair
end

T.run("host_sends_the_item_its_enemy_dropped", function()
    local pair = make_pair()
    pair:place(pair.host_items, HERB, 30, 30) -- unrelated item already lying around
    pair:step(1)
    pair.host:on_drop_events(pair.now, { { enemy_id = 101, droptype = 65536 } })
    pair:place(pair.host_items, AMMO, 10.5, 0.3, 15)
    pair.client.hook_proven = true -- (covered below)
    pair:step(2)
    T.eq(pair.host.counters.sent, 1, "one drop sent")
    local s = pair.game.spawned[1]
    T.check(s ~= nil, "client spawned it")
    T.eq(s.item_id, AMMO, "same item")
    T.eq(s.count, 15, "same count")
    T.near(s.pos.x, 12, 1e-6, "where the client's copy of the enemy is")
    T.eq(s.stage, 43401, "in the client's stage")
end)

T.run("host_ignores_far_late_and_key_items", function()
    local pair = make_pair()
    pair:step(1)
    pair.host:on_drop_events(pair.now, { { enemy_id = 101 } })
    pair:place(pair.host_items, HERB, 40, 0) -- too far from the enemy
    pair:place(pair.host_items, COG, 10, 0) -- key items are never drops
    pair:step(1)
    T.eq(pair.host.counters.sent, 0, "nothing sent")
    pair:step(20)
    pair:place(pair.host_items, HERB, 10, 0) -- appears long after the drop call
    pair:step(1)
    T.eq(pair.host.counters.sent, 0, "late item not sent")
    pair.host:on_drop_events(pair.now, { { enemy_id = 555 } }) -- enemy without a net id
    pair:place(pair.host_items, HERB, 10.2, 0)
    pair:step(1)
    T.eq(pair.host.counters.sent, 0, "unnumbered enemy ignored")
end)

T.run("client_waits_until_its_own_drop_hook_is_seen", function()
    local pair = make_pair()
    pair:step(1)
    T.eq(next(pair.game.suppress), nil, "nothing suppressed yet")
    pair.client:on_message(assert(P.decode(P.encode_item_dropped({ net_id = 7, item_id = AMMO, count = 1,
        pos = { x = 10, y = 0, z = 0 } }))), pair.now, pair.game, 43401)
    T.eq(#pair.game.spawned, 0, "no spawn while our own rolls still happen")
    T.eq(pair.client:summary().state, "waiting for the first enemy drop", "state")

    pair.client:on_drop_events(pair.now, { { enemy_id = 999 } }) -- our hook fired for an enemy
    pair:step(1)
    T.eq(pair.game.suppress[201], true, "paired enemy's roll suppressed")
    T.eq(pair.client:summary().state, "synced (first spawn not yet verified)", "state")
end)

T.run("spawn_is_verified", function()
    local pair = make_pair()
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.host:on_drop_events(pair.now, { { enemy_id = 101 } })
    pair:place(pair.host_items, HERB, 10, 0)
    pair:step(3)
    T.eq(pair.client.counters.verified, 1, "spawned item found in the scene")
    T.eq(pair.client:summary().state, "synced", "state")
end)

T.run("spawn_that_never_appears_switches_sync_off", function()
    local pair = make_pair()
    pair.game.spawn_works = false
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.host:on_drop_events(pair.now, { { enemy_id = 101 } })
    pair:place(pair.host_items, HERB, 10, 0)
    pair:step(20)
    T.eq(pair.client.spawn_failed, true, "gave up")
    T.eq(next(pair.game.suppress), nil, "our own rolls are back")
    T.eq(pair.client:summary().state, "off (spawning the host's items failed)", "state")
end)

T.run("spawn_error_switches_sync_off", function()
    local pair = make_pair()
    pair.game.spawn_errors = true
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.client:on_message(assert(P.decode(P.encode_item_dropped({ net_id = 7, item_id = AMMO, count = 1,
        pos = { x = 10, y = 0, z = 0 } }))), pair.now, pair.game, 43401)
    pair:step(1)
    T.eq(next(pair.game.suppress), nil, "rolls are back")
end)

T.run("later_missing_spawn_after_success_keeps_sync", function()
    local pair = make_pair()
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.host:on_drop_events(pair.now, { { enemy_id = 101 } })
    pair:place(pair.host_items, HERB, 10, 0)
    pair:step(3)
    pair.game.spawn_works = false
    pair.host:on_drop_events(pair.now, { { enemy_id = 101 } })
    pair:place(pair.host_items, AMMO, 10, 0.5)
    pair:step(20)
    T.eq(pair.client.spawn_failed, false, "one miss after a verified spawn is tolerated")
    T.eq(pair.client.counters.unverified, 1, "but counted")
end)

T.run("unpaired_enemy_keeps_its_own_drop", function()
    local pair = make_pair()
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.client:on_message(assert(P.decode(P.encode_item_dropped({ net_id = 42, item_id = AMMO, count = 1,
        pos = { x = 10, y = 0, z = 0 } }))), pair.now, pair.game, 43401)
    T.eq(#pair.game.spawned, 0, "no spawn for an enemy we never paired")
    T.eq(pair.client.counters.unpaired, 1, "counted")
end)

T.run("pairing_is_remembered_after_the_enemy_is_gone", function()
    local pair = make_pair()
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.client_es.local_of[7] = nil -- our copy died and was forgotten by enemy sync
    pair.client_es.by_id[201] = nil
    pair:step(4)
    pair.client:on_message(assert(P.decode(P.encode_item_dropped({ net_id = 7, item_id = AMMO, count = 2,
        pos = { x = 10, y = 0, z = 0 } }))), pair.now, pair.game, 43401)
    T.eq(#pair.game.spawned, 1, "still spawned")
    T.near(pair.game.spawned[1].pos.x, 12, 1e-6, "at the copy's last position")
end)

T.run("switched_off", function()
    local pair = make_pair({ sync_drops = false })
    pair.client:on_drop_events(0, { { enemy_id = 999 } })
    pair:step(1)
    pair.host:on_drop_events(pair.now, { { enemy_id = 101 } })
    pair:place(pair.host_items, HERB, 10, 0)
    pair:step(3)
    T.eq(pair.host.counters.sent, 0, "host sends nothing")
    T.eq(next(pair.game.suppress), nil, "client suppresses nothing")
    T.eq(pair.client:summary().state, "off", "state")
end)

T.finish()
