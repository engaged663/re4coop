-- Animal synchronisation between two simulated games (host and client), every message going
-- through the real protocol encoder/decoder: the host's animals near both players move the
-- client's copies, and deaths cross both ways.
local T = require("testlib")
local P = require("re4coop.protocol")
local AnimalSync = require("re4coop.animal_sync")

local function guid(i)
    return ("%08x-aaaa-bbbb-cccc-%012x"):format(i, i)
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- A fake game with animals, implementing both sides of the world adapter contract.
local function make_world()
    local w = { animals = {}, calls = { transform = 0, motion = 0, puppet = 0, kill = 0, restore = 0 } }

    function w:add(i, x, y, z)
        local a = { guid = guid(i), pos = { x = x, y = y, z = z }, rot = { x = 0, y = 0, z = 0, w = 1 }, routine = 0,
            dead = false, motion = { bank = 7, id = 1, frame = 0 } }
        self.animals[a.guid] = a
        return a
    end

    function w:die(a)
        a.routine, a.dead = 7, true
    end

    -- Host side.
    function w:animals_near(points, radius, max)
        local out = {}
        for _, a in pairs(self.animals) do
            local near = true
            for _, p in ipairs(points) do
                if dist(a.pos, p) > radius then near = false end
            end
            if near then
                out[#out + 1] = { guid = a.guid, pos = { x = a.pos.x, y = a.pos.y, z = a.pos.z }, rot = a.rot,
                    routine = a.routine, dead = a.dead, motion = { bank = a.motion.bank, id = a.motion.id, frame = 0 } }
            end
        end
        table.sort(out, function(a, b) return dist(a.pos, points[1]) < dist(b.pos, points[1]) end)
        while #out > max do table.remove(out) end
        return out
    end

    -- Client side.
    function w:animal_local(g)
        local a = self.animals[g]
        if a == nil then return nil end
        return { pos = { x = a.pos.x, y = a.pos.y, z = a.pos.z }, routine = a.routine, dead = a.dead }
    end
    function w:animal_puppet(g, on)
        local a = self.animals[g]
        if a == nil then return false end
        self.calls.puppet = self.calls.puppet + 1
        a.puppet = on or nil
        return true
    end
    function w:animal_set_transform(g, pos, rot)
        local a = self.animals[g]
        if a == nil then return false end
        self.calls.transform = self.calls.transform + 1
        a.pos = { x = pos.x, y = pos.y, z = pos.z }
        a.rot = rot
        return true
    end
    function w:animal_set_motion(g, motion)
        local a = self.animals[g]
        if a == nil then return false end
        self.calls.motion = self.calls.motion + 1
        a.motion = { bank = motion.bank, id = motion.id, frame = motion.frame }
        return true
    end
    function w:animal_kill(g)
        local a = self.animals[g]
        if a == nil then return false end
        self.calls.kill = self.calls.kill + 1
        a.killed_as_puppet = a.puppet == true
        self:die(a)
        return true
    end
    function w:restore_animals()
        self.calls.restore = self.calls.restore + 1
        for _, a in pairs(self.animals) do a.puppet = nil end
    end
    return w
end

local function make_pair(settings)
    settings = settings or {}
    local pair = { now = 0, host_world = make_world(), client_world = make_world(), to_client = {}, messages = 0,
        local_kills = {}, remote_kills = {},
        host_player = { x = 0, y = 0, z = 0 }, client_player = { x = 2, y = 0, z = 0 } }
    pair.host = AnimalSync.new({ role = "host", protocol = P, settings = settings,
        send = function(bytes, reliable)
            T.eq(reliable, false, "animal snapshots are unreliable")
            pair.to_client[#pair.to_client + 1] = bytes
            pair.messages = pair.messages + 1
        end })
    pair.client = AnimalSync.new({ role = "client", protocol = P, settings = settings,
        send = function() error("the client sends no animal messages") end,
        on_local_kill = function(g, routine) pair.local_kills[#pair.local_kills + 1] = { guid = g, routine = routine } end,
        on_remote_kill = function(g) pair.remote_kills[#pair.remote_kills + 1] = g end })

    -- frames at 60 fps
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 1 / 60
            self.host:tick(self.now, self.host_world, { local_pos = self.host_player, partner_pos = self.client_player })
            for _, bytes in ipairs(self.to_client) do
                T.check(self.client:on_message(assert(P.decode(bytes)), self.now), "consumed")
            end
            self.to_client = {}
            self.client:tick(self.now, self.client_world, { local_pos = self.client_player, partner_pos = self.host_player })
        end
    end

    -- The same animal in both games (each game may have put it a little elsewhere).
    function pair:both(i, x, y, z)
        return self.host_world:add(i, x, y, z), self.client_world:add(i, x + 0.5, y, z - 0.5)
    end
    return pair
end

T.run("the_clients_copies_follow_the_hosts_animals", function()
    local pair = make_pair()
    local h, c = pair:both(1, 5, 0, 5)
    pair:step(30)
    T.eq(c.puppet, true, "the client's crow follows the host's (its own AI off)")
    T.near(c.pos.x, 5, 1e-6, "where the host's stands")
    -- The host's crow flies off over half a second.
    for i = 1, 30 do
        h.pos = { x = 5 + i * 0.2, y = i * 0.1, z = 5 }
        pair:step(1)
    end
    pair:step(20) -- the interpolation buffer drains
    T.near(c.pos.x, 11, 0.05, "the client's crow got there too")
    T.near(c.pos.y, 3, 0.05, "flying")
    T.check(pair.client_world.calls.transform > 20, "moved smoothly, frame by frame")
    T.eq(h.puppet, nil, "the host's animals run on their own")
    T.eq(pair.client:summary().puppets, 1, "one puppet")
end)

T.run("the_host_animation_plays_once_per_change", function()
    local pair = make_pair()
    local h, c = pair:both(1, 5, 0, 5)
    h.motion = { bank = 7, id = 12, frame = 0 }
    pair:step(30)
    T.eq(c.motion.id, 12, "the client's crow plays the host's animation")
    local n = pair.client_world.calls.motion
    pair:step(30)
    T.eq(pair.client_world.calls.motion, n, "not restarted every frame")
    h.motion = { bank = 7, id = 13, frame = 0 }
    pair:step(30)
    T.eq(c.motion.id, 13, "the next one follows")
end)

T.run("the_host_runs_every_animal_near_the_client", function()
    local pair = make_pair()
    pair.host_player = { x = 60, y = 0, z = 0 } -- the crow is out of the host's reach, not the client's
    local _, near = pair:both(1, 5, 0, 5)
    local _, far = pair:both(2, 120, 0, 0)
    local only_client = pair.client_world:add(3, 6, 0, 6)
    pair:step(60)
    T.eq(near.puppet, true, "near the client: follows the host")
    T.near(near.pos.x, 5, 1e-6, "where the host's is")
    T.eq(far.puppet, nil, "far from the client: nothing to do")
    T.eq(only_client.puppet, true, "not in the host's game: held, its own AI off")
    T.near(only_client.pos.x, 6, 1e-6, "where it was")
    T.eq(pair.client:summary().counters.held, 1, "counted")
    -- The client runs far ahead: the host's crow is no longer reported, ours waits where it is.
    pair.client_player = { x = 200, y = 0, z = 0 }
    pair:step(400)
    T.eq(near.puppet, true, "still not running on its own")
    -- A held animal our player shoots dies with its own death, and the host is told.
    pair.client_player = { x = 2, y = 0, z = 0 }
    pair.client_world:die(only_client)
    pair:step(60)
    T.eq(only_client.puppet, nil, "released for its death")
    T.eq(#pair.local_kills, 1, "reported to the host")
end)

T.run("without_host_only_only_animals_near_both_players_follow_the_host", function()
    local pair = make_pair({ animal_host_only = false })
    local _, near = pair:both(1, 5, 0, 5)
    local _, far = pair:both(2, 120, 0, 0)
    local only_client = pair.client_world:add(3, 6, 0, 6)
    pair:step(30)
    T.eq(near.puppet, true, "near both players: follows the host")
    T.eq(far.puppet, nil, "far from both: runs on its own")
    T.eq(only_client.puppet, nil, "not in the host's game: runs on its own")
    -- The client runs far ahead: the host's game no longer decides about the crow.
    pair.client_player = { x = 200, y = 0, z = 0 }
    pair:step(90)
    T.eq(near.puppet, nil, "released after a second without news")
    T.eq(pair.client:summary().puppets, 0, "no puppets")
end)

T.run("an_animal_the_client_has_not_loaded_follows_once_it_appears", function()
    local pair = make_pair()
    local h = pair.host_world:add(1, 5, 0, 5)
    pair:step(30)
    T.eq(pair.client:summary().puppets, 0, "nothing to follow yet")
    local c = pair.client_world:add(1, 8, 0, 8)
    pair:step(30)
    T.eq(c.puppet, true, "follows once loaded")
    T.near(c.pos.x, h.pos.x, 1e-6, "and jumps to the host's")
end)

T.run("a_host_animal_that_dies_dies_in_the_clients_game", function()
    local pair = make_pair()
    local h, c = pair:both(1, 5, 0, 5)
    pair:step(30)
    T.eq(c.puppet, true, "following")
    pair.host_world:die(h) -- the host shoots it
    pair:step(10)
    T.eq(c.dead, true, "the client's crow died too")
    T.eq(c.killed_as_puppet, false, "with its own AI running its death")
    T.near(c.pos.x, 5, 1e-6, "where the host's died")
    T.eq(#pair.remote_kills, 1, "object sync is told (no echo back)")
    T.eq(#pair.local_kills, 0, "not reported as the client's kill")
    -- Even if the host's animal shows up alive again (a crow's death ends in its Loop routine).
    h.dead, h.routine = false, 10
    pair:step(30)
    T.eq(c.puppet, nil, "a dead animal never follows again")
    T.eq(pair.client_world.calls.kill, 1, "killed once")
end)

T.run("an_animal_the_client_shoots_dies_there_and_is_reported", function()
    local pair = make_pair()
    local h, c = pair:both(1, 5, 0, 5)
    pair:step(30)
    T.eq(c.puppet, true, "following")
    pair.client_world:die(c) -- the client's shot sets its routine to Die even while it is a puppet
    pair:step(10)
    T.eq(c.puppet, nil, "released: it plays its own death")
    T.eq(#pair.local_kills, 1, "the kill goes to the host right away")
    T.eq(pair.local_kills[1].guid, c.guid, "which animal")
    T.eq(pair.local_kills[1].routine, 7, "and its death routine")
    T.check(not h.dead, "(the host applies it through object sync)")
    pair.host_world:die(h)
    pair:step(30)
    T.eq(#pair.local_kills, 1, "reported once")
    T.eq(#pair.remote_kills, 0, "the host's death notice changes nothing")
    T.eq(pair.client_world.calls.kill, 0, "never killed again")
end)

T.run("far_puppets_move_at_a_third_of_the_frame_rate", function()
    local pair = make_pair()
    local _, near = pair:both(1, 5, 0, 5)
    local _, far = pair:both(2, 35, 0, 0)
    pair:step(30)
    T.check(near.puppet and far.puppet, "both follow")
    local writes = { near = 0, far = 0 }
    local tf = pair.client_world.animal_set_transform
    pair.client_world.animal_set_transform = function(w, g, pos, rot)
        if g == near.guid then writes.near = writes.near + 1 else writes.far = writes.far + 1 end
        return tf(w, g, pos, rot)
    end
    pair:step(60)
    T.eq(writes.near, 60, "near: every frame")
    T.check(writes.far >= 18 and writes.far <= 22, "far: every third frame (" .. writes.far .. ")")
end)

T.run("switching_animal_sync_off_releases_every_puppet", function()
    local settings = {}
    local pair = make_pair(settings)
    local _, c = pair:both(1, 5, 0, 5)
    pair:step(30)
    T.eq(c.puppet, true, "following")
    settings.sync_animals = false
    pair:step(2)
    T.eq(c.puppet, nil, "released")
    T.check(pair.client_world.calls.restore >= 1, "the adapter gave every animal back")
    local sent = pair.messages
    pair:step(30)
    T.eq(pair.messages, sent, "the host stops sending")
    settings.sync_animals = true
    pair:step(30)
    T.eq(c.puppet, true, "follows again")
end)

T.run("a_client_reload_forgets_the_old_scene", function()
    local pair = make_pair()
    local h, c = pair:both(1, 5, 0, 5)
    pair:step(30)
    pair.client_world:die(c)
    pair:step(5)
    T.eq(c.puppet, nil, "dead")
    -- The client reloads a checkpoint: its crow is alive again (the adapter dropped the old scene).
    pair.client:on_local_reload()
    c.dead, c.routine = false, 0
    pair:step(30)
    T.eq(c.puppet, true, "the new scene's crow follows the host's")
    T.check(not h.dead, "the host's crow lives on")
end)

T.run("traffic_stays_small", function()
    local pair = make_pair()
    for i = 1, 40 do pair:both(i, (i % 8) * 3, 0, (i // 8) * 3) end
    pair:step(60) -- one second
    T.check(pair.messages <= 2 * 11, "10 rounds of at most 24 animals (2 messages each): " .. pair.messages)
    T.eq(pair.client:summary().puppets, AnimalSync.MAX_ANIMALS, "the nearest 24 follow")
end)

T.finish()
