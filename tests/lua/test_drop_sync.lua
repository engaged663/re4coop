-- Enemy loot: each player rolls their own loot for every enemy death, the partner's kills
-- included, exactly once (drop_sync.lua with a fake game).
local T = require("testlib")
local DropSync = require("re4coop.drop_sync")

local GANADO, DOG = "chainsaw.Ch1c0z0Context", "chainsaw.Ch1d0z0Context"

local function make(settings)
    local env = { now = 0, enemies = {}, events = {}, requests = {} }
    env.sync = DropSync.new({ settings = settings or {} })
    env.game = { gone = {} }
    function env.game:request_enemy_drop(id)
        if self.gone[id] then return false, "enemy gone" end
        env.requests[#env.requests + 1] = id
        -- The game reports our own request through the hook, as "generate".
        env.events[#env.events + 1] = { enemy_id = id, via = "generate" }
        return true
    end
    function env:spawn(id, kind)
        self.enemies[#self.enemies + 1] = { id = id, kind = kind or GANADO, alive = true }
    end
    function env:get(id)
        for _, e in ipairs(self.enemies) do if e.id == id then return e end end
    end
    -- The game rolled loot for an enemy (both hooks fire: the request, then the stack).
    function env:roll(id)
        self.events[#self.events + 1] = { enemy_id = id, via = "request" }
        self.events[#self.events + 1] = { enemy_id = id, via = "generate" }
    end
    -- Enemy sync killed it because the partner's game did.
    function env:partner_kill(id)
        self.sync:on_remote_kill(id, self.now)
        self:get(id).alive = false
    end
    function env:step(seconds)
        local t = 0
        repeat
            self.now = self.now + 0.05
            t = t + 0.05
            local list = {}
            for i, e in ipairs(self.enemies) do list[i] = { id = e.id, kind = e.kind, alive = e.alive } end
            local events = self.events
            self.events = {}
            self.sync:update(self.now, list, events, self.game)
        until t >= (seconds or 0.05) - 1e-9
    end
    -- Our own kill and the game rolling its loot `delay` seconds later.
    function env:own_kill_with_roll(id, delay)
        self:get(id).alive = false
        self:step(delay)
        self:roll(id)
        self:step(0.05)
    end
    return env
end

T.run("nothing_is_rolled_before_the_hooks_proved_themselves", function()
    local env = make()
    env:spawn(1)
    env:step(0.2)
    env:partner_kill(1)
    env:step(5)
    T.eq(#env.requests, 0, "no roll: a missing roll could be one we failed to see")
    T.eq(env.sync:summary().state, "waiting for the first enemy drop", "state")
end)

T.run("partners_kill_gets_our_own_roll_once", function()
    local env = make()
    env:spawn(1)
    env:spawn(2)
    env:step(0.2)
    env:own_kill_with_roll(1, 0.5) -- proves the hooks
    env:partner_kill(2)
    env:step(0.5)
    T.eq(#env.requests, 0, "the game gets time to roll it itself")
    env:step(3)
    T.eq(#env.requests, 1, "rolled for us")
    T.eq(env.requests[1], 2, "for that enemy")
    env:step(10)
    T.eq(#env.requests, 1, "never twice")
    T.eq(env.sync.counters.partner_kills, 1, "counted as the partner's kill")
    T.eq(env.sync.counters.doubles, 0, "no double loot")
end)

T.run("game_rolling_a_partner_kill_itself_is_enough", function()
    local env = make()
    env:spawn(1)
    env:spawn(2)
    env:step(0.2)
    env:own_kill_with_roll(1, 0.3)
    env:partner_kill(2)
    env:step(0.4)
    env:roll(2) -- enemy_kill ran the game's own death code, loot included
    env:step(5)
    T.eq(#env.requests, 0, "no extra roll")
end)

T.run("a_roll_seen_before_the_death_counts", function()
    local env = make()
    env:spawn(1)
    env:spawn(2)
    env:step(0.2)
    env:own_kill_with_roll(1, 0.3)
    env:roll(2) -- the hook fires in the frame the enemy dies, before our enemy list notices
    env:partner_kill(2)
    env:step(5)
    T.eq(#env.requests, 0, "already rolled")
end)

T.run("own_kill_without_loot_means_that_kind_drops_nothing", function()
    local env = make()
    env:spawn(1, GANADO)
    env:spawn(2, DOG)
    env:spawn(3, DOG)
    env:step(0.2)
    env:own_kill_with_roll(1, 0.3)
    env:get(2).alive = false -- we killed a dog: no roll at all
    env:step(5)
    T.eq(env.sync.counters.no_drop_kinds, 0, "not decided while a slow roll may still come")
    env:step(4)
    T.eq(env.sync.counters.no_drop_kinds, 1, "learned")
    env:partner_kill(3)
    env:step(5)
    T.eq(#env.requests, 0, "the partner's dog gives no loot either")
end)

T.run("waiting_time_is_learned_from_our_own_kills", function()
    local env = make()
    for i = 1, 4 do env:spawn(i) end
    env:step(0.2)
    env:own_kill_with_roll(1, 3.0) -- this game rolls loot 3 s after a death
    T.near(env.sync.wait, 3.8, 0.11, "waits longer than the slowest roll seen")
    env:partner_kill(2)
    env:step(3.2)
    T.eq(#env.requests, 0, "still waiting for the game's own roll")
    env:step(1.0)
    T.eq(#env.requests, 1, "then rolls")
end)

T.run("a_late_game_roll_after_ours_is_counted_and_learned", function()
    local env = make()
    for i = 1, 3 do env:spawn(i) end
    env:step(0.2)
    env:own_kill_with_roll(1, 0.2)
    env:partner_kill(2)
    env:step(1.5)
    T.eq(#env.requests, 1, "we rolled")
    env:roll(2) -- the game rolled after all
    env:step(0.05)
    T.eq(env.sync.counters.doubles, 1, "double counted")
    T.check(env.sync.wait > 1.5, "and the wait grows")
end)

T.run("an_enemy_gone_before_the_roll_is_counted", function()
    local env = make()
    env:spawn(1)
    env:spawn(2)
    env:step(0.2)
    env:own_kill_with_roll(1, 0.2)
    env:partner_kill(2)
    env.game.gone[2] = true
    env:step(3)
    T.eq(env.sync.counters.gone, 1, "counted")
    T.eq(#env.requests, 0, "nothing rolled")
end)

T.run("reload_forgets_enemies_but_keeps_what_was_learned", function()
    local env = make()
    env:spawn(1)
    env:spawn(2, DOG)
    env:step(0.2)
    env:own_kill_with_roll(1, 1.0)
    env:get(2).alive = false
    env:step(9)
    local wait = env.sync.wait
    env.sync:forget_enemies()
    T.eq(env.sync.wait, wait, "wait kept")
    T.eq(env.sync.no_drop[DOG], true, "kinds without loot kept")
    T.eq(env.sync.hook_proven, true, "proof kept")
    T.eq(next(env.sync.alive), nil, "enemies forgotten")
end)

T.run("switched_off", function()
    local env = make({ sync_drops = false })
    env:spawn(1)
    env:spawn(2)
    env:step(0.2)
    env:own_kill_with_roll(1, 0.2)
    env:partner_kill(2)
    env:step(5)
    T.eq(#env.requests, 0, "nothing rolled")
    T.eq(env.sync:summary().state, "off", "state")
end)

T.finish()
