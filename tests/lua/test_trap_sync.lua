-- Traps for both games: two simulated games with bear traps and sensor bombs (every message
-- through the real codec), then the real world adapter (game_world.lua) against the mock.
local T = require("testlib")
local P = require("re4coop.protocol")
local TrapSync = require("re4coop.trap_sync")

local G_TRAP = "11111111-0000-0000-0000-000000000001"
local G_BOMB = "11111111-0000-0000-0000-000000000002"
local G_FAR = "11111111-0000-0000-0000-000000000003"
local LEG, BOMB = P.TRAP_KIND.LEG_HOLD, P.TRAP_KIND.SENSOR_BOMB

-- A game's traps: guid -> { kind, state, pos, loaded }; trap_apply plays what the game would.
local function make_world()
    local w = { traps = {}, applied = {}, played = 0 }
    function w:add(guid, kind, state, pos)
        self.traps[guid] = { kind = kind, state = state, pos = pos or { x = 0, y = 0, z = 0 }, loaded = true }
    end
    local function list(self, filter)
        local out = {}
        for guid, t in pairs(self.traps) do
            if t.loaded and (filter == nil or filter(t)) then out[guid] = { kind = t.kind, state = t.state } end
        end
        return out
    end
    function w:traps_near(pos, radius)
        return list(self, function(t)
            local dx, dy, dz = t.pos.x - pos.x, t.pos.y - pos.y, t.pos.z - pos.z
            return math.sqrt(dx * dx + dy * dy + dz * dz) <= radius
        end)
    end
    function w:traps_all() return list(self) end
    function w:trap_apply(guid, kind, event)
        local t = self.traps[guid]
        if t == nil or not t.loaded then return "missing" end
        self.applied[#self.applied + 1] = { guid = guid, event = event }
        if kind == LEG then
            if event == P.TRAP_EVENT.REARMED then
                if t.state ~= "closed" then return "skip" end
                t.state = "open"
            else
                if t.state ~= "open" then return "skip" end
                t.state = "closed"
                if event == P.TRAP_EVENT.FIRED then self.played = self.played + 1 end
            end
        else
            if t.state ~= "armed" then return "skip" end
            t.state = "gone"
            if event == P.TRAP_EVENT.FIRED then self.played = self.played + 1 end
        end
        return "done"
    end
    return w
end

local function make_pair(settings)
    local pair = { now = 0, a_to_b = {}, b_to_a = {}, pos = { x = 0, y = 0, z = 0 } }
    pair.wa, pair.wb = make_world(), make_world()
    local function sync(out)
        return TrapSync.new({ protocol = P, settings = settings or {},
            send = function(bytes) table.insert(pair[out], bytes) end })
    end
    pair.a, pair.b = sync("a_to_b"), sync("b_to_a")
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.1
            local ab, ba = self.a_to_b, self.b_to_a
            self.a_to_b, self.b_to_a = {}, {}
            for _, m in ipairs(ab) do self.b:on_message(assert(P.decode(m)), self.now, self.wb) end
            for _, m in ipairs(ba) do self.a:on_message(assert(P.decode(m)), self.now, self.wa) end
            self.a:tick(self.now, self.wa, self.pos)
            self.b:tick(self.now, self.wb, self.pos)
        end
    end
    for _, w in ipairs({ pair.wa, pair.wb }) do
        w:add(G_TRAP, LEG, "open")
        w:add(G_BOMB, BOMB, "armed")
    end
    pair:step(5) -- both games have seen their traps
    return pair
end

T.run("traps_roundtrip", function()
    local msgs = P.encode_traps({ { guid = G_TRAP, kind = LEG, event = P.TRAP_EVENT.FIRED },
        { guid = G_BOMB, kind = BOMB, event = P.TRAP_EVENT.SPENT } })
    T.eq(#msgs, 1, "one message")
    local m = assert(P.decode(msgs[1]))
    T.eq(m.type, P.T.TRAPS, "type")
    T.eq(m.traps[1].guid, G_TRAP, "guid")
    T.eq(m.traps[1].kind, LEG, "kind")
    T.eq(m.traps[2].event, P.TRAP_EVENT.SPENT, "event")
end)

T.run("a_bear_trap_that_closes_snaps_shut_in_the_partners_game", function()
    local pair = make_pair()
    pair.wa.traps[G_TRAP].state = "closed" -- it bit someone, or was shot
    pair:step(5)
    T.eq(pair.wb.traps[G_TRAP].state, "closed", "closed in the partner's game")
    T.eq(pair.wb.played, 1, "with its own snap")
    pair:step(10)
    T.eq(#pair.wa.applied, 0, "the partner's closing is not reported back")
    -- A villager opens it again.
    pair.wa.traps[G_TRAP].state = "open"
    pair:step(5)
    T.eq(pair.wb.traps[G_TRAP].state, "open", "open again in the partner's game")
end)

T.run("a_sensor_bomb_that_goes_off_goes_off_in_the_partners_game", function()
    local pair = make_pair()
    pair.wb.traps[G_BOMB].state = "gone" -- shot, or someone crossed its laser
    pair:step(5)
    T.eq(pair.wa.traps[G_BOMB].state, "gone", "gone in the other game")
    T.eq(pair.wa.played, 1, "it went off there too")
    pair:step(10)
    T.eq(#pair.wb.applied, 0, "not reported back")
end)

T.run("a_trap_not_loaded_here_waits_for_its_area", function()
    local pair = make_pair()
    pair.wa:add(G_FAR, LEG, "open", { x = 200, y = 0, z = 0 })
    pair.wb:add(G_FAR, LEG, "open", { x = 200, y = 0, z = 0 })
    pair.wb.traps[G_FAR].loaded = false
    pair.pos = { x = 200, y = 0, z = 0 }
    pair:step(5)
    pair.wa.traps[G_FAR].state = "closed"
    pair:step(5)
    T.eq(pair.b:summary().queued, 1, "waiting")
    pair.wb.traps[G_FAR].loaded = true
    pair:step(15)
    T.eq(pair.wb.traps[G_FAR].state, "closed", "closed once its area loaded")
    T.eq(pair.wb.played, 1, "played: the report is recent")
end)

T.run("an_old_report_is_set_without_playing_it", function()
    local pair = make_pair()
    pair.wb.traps[G_BOMB].loaded = false
    pair.wa.traps[G_BOMB].state = "gone"
    pair:step(5)
    pair.now = pair.now + 120 -- the partner arrives much later
    pair.wb.traps[G_BOMB].loaded = true
    pair:step(15)
    T.eq(pair.wb.traps[G_BOMB].state, "gone", "gone")
    T.eq(pair.wb.played, 0, "without going off next to a player who just arrived")
end)

T.run("a_joining_partner_gets_every_spent_trap", function()
    local pair = make_pair()
    pair.wa.traps[G_TRAP].state = "closed"
    pair.wa.traps[G_BOMB].state = "gone"
    pair.b.traps = nil
    -- Not connected: nothing reaches the partner (a fresh session for both).
    pair.a:reset()
    pair.b:reset()
    pair.wb.applied = {}
    pair.a_to_b, pair.b_to_a = {}, {}
    pair:step(5)
    T.eq(pair.wb.traps[G_TRAP].state, "closed", "the closed bear trap")
    T.eq(pair.wb.traps[G_BOMB].state, "gone", "the bomb that went off")
    T.eq(pair.wb.played, 0, "set as they are, nothing played")
end)

T.run("trap_sync_can_be_switched_off", function()
    local pair = make_pair({ sync_traps = false })
    pair.wa.traps[G_TRAP].state = "closed"
    pair:step(10)
    T.eq(pair.wb.traps[G_TRAP].state, "open", "off")
end)

-------------------------------------------------------------------------------
-- The world adapter against the mocked RE4 traps
-------------------------------------------------------------------------------

local mock = require("mock_reframework")

local function fresh()
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    local world = mock.install()
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    world.now = 0
    local Game = require("re4coop.game")
    local game = Game.new(function() end, function() return world.now end)
    local World = require("re4coop.game_world")
    local w = World.new(game, function() end)
    w:set_active(true)
    game:read_player_state()
    return w, game, world
end

T.run("adapter_reads_trap_states_by_guid", function()
    local w, game, world = fresh()
    T.check(game:capabilities().traps.ok, "traps capability")
    local trap = mock.make_trap("chainsaw.GmLegHoldTrap", G_TRAP, { x = 3, y = 0, z = 0 })
    local bomb = mock.make_trap("chainsaw.GmSensorBomb", G_BOMB, { x = 5, y = 0, z = 0 })
    mock.make_trap("chainsaw.GmLegHoldTrap", G_FAR, { x = 500, y = 0, z = 0 })
    local near = w:traps_near({ x = 0, y = 0, z = 0 }, 60)
    T.eq(near[G_TRAP].state, "open", "open bear trap")
    T.eq(near[G_TRAP].kind, LEG, "its kind")
    T.eq(near[G_BOMB].state, "armed", "armed bomb")
    T.eq(near[G_FAR], nil, "far ones are not near")
    T.check(w:traps_all()[G_FAR] ~= nil, "but loaded")
    trap.__fields._Routine = 1 -- Bite
    bomb.__fields._Routine = 4 -- Done
    world.now = 10
    near = w:traps_near({ x = 0, y = 0, z = 0 }, 60)
    T.eq(near[G_TRAP].state, "closed", "a biting trap is closed")
    T.eq(near[G_BOMB].state, "gone", "a done bomb is gone")
end)

T.run("adapter_closes_and_sets_off_traps_the_games_way", function()
    local w, _, world = fresh()
    local trap = mock.make_trap("chainsaw.GmLegHoldTrap", G_TRAP, { x = 3, y = 0, z = 0 })
    local bomb = mock.make_trap("chainsaw.GmSensorBomb", G_BOMB, { x = 5, y = 0, z = 0 })
    T.eq(w:trap_apply(G_TRAP, LEG, P.TRAP_EVENT.FIRED), "done", "bear trap")
    T.eq(trap.__fields._Routine, 2, "Close, like a shot")
    mock.update_traps()
    mock.update_traps()
    T.eq(trap.__fields._Routine, 3, "then Closed")
    T.eq(world.trap_sounds, 1, "with its snap")
    T.eq(trap.flag, true, "saved as closed")
    T.eq(w:trap_apply(G_TRAP, LEG, P.TRAP_EVENT.FIRED), "skip", "already closed: nothing")
    T.eq(w:trap_apply(G_TRAP, LEG, P.TRAP_EVENT.REARMED), "done", "a villager opens it")
    mock.update_traps()
    T.eq(trap.__fields._Routine, 0, "open again")
    T.eq(trap.flag, false, "not closed in the save")
    T.eq(w:trap_apply(G_BOMB, BOMB, P.TRAP_EVENT.FIRED), "done", "sensor bomb")
    T.eq(bomb.flag, true, "flagged like a shot")
    mock.update_traps()
    mock.update_traps()
    T.eq(world.explosions, 1, "it went off through its own state machine")
    T.eq(bomb.__fields._Routine, 4, "and is done")
    T.eq(w:trap_apply("99999999-0000-0000-0000-000000000000", LEG, 1), "missing", "unknown trap")
end)

T.run("adapter_sets_spent_traps_without_playing_them", function()
    local w, _, world = fresh()
    local trap = mock.make_trap("chainsaw.GmLegHoldTrap", G_TRAP, { x = 3, y = 0, z = 0 })
    local bomb = mock.make_trap("chainsaw.GmSensorBomb", G_BOMB, { x = 5, y = 0, z = 0 })
    T.eq(w:trap_apply(G_TRAP, LEG, P.TRAP_EVENT.SPENT), "done", "bear trap")
    T.eq(trap.__fields._Routine, 3, "straight to Closed (requestSetClosed)")
    T.eq(trap.flag, true, "flagged")
    T.eq(w:trap_apply(G_BOMB, BOMB, P.TRAP_EVENT.SPENT), "done", "bomb")
    mock.update_traps()
    mock.update_traps()
    T.eq(bomb.__fields._Routine, 4, "Done")
    T.eq(world.explosions, 0, "without an explosion")
    T.eq(world.trap_sounds, 0, "or a snap")
end)

T.finish()
