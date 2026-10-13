-- Mechanisms for both games: two simulated games with levers, doors and a pushed cart (every
-- message through the real codec), then the real world adapter (game_world.lua) against the mock.
local T = require("testlib")
local P = require("re4coop.protocol")
local MechanismSync = require("re4coop.mechanism_sync")

local G_LEVER = "22222222-0000-0000-0000-000000000001"
local G_CART = "22222222-0000-0000-0000-000000000002"
local G_FAR = "22222222-0000-0000-0000-000000000003"
local G_DOOR = "22222222-0000-0000-0000-000000000004"
local PORT, PUSH = P.MECH_KIND.PORTRAYAL, P.MECH_KIND.PUSH
local KEY = 0x8E1A55C3

-- A game's mechanisms: guid -> { loaded, played, moved }. use() is its player using one (the
-- game reports it); mechanism_apply plays the partner's.
local function make_world()
    local w = { mechs = {}, events = {}, played = {} }
    function w:add(guid) self.mechs[guid] = { loaded = true, played = 0, moved = false } end
    function w:use(guid, kind, key)
        local m = self.mechs[guid]
        if kind == PUSH then m.moved = true else m.played = m.played + 1 end
        self.events[#self.events + 1] = { guid = guid, kind = kind, key = key or 0 }
    end
    function w:take_mechanism_events()
        if #self.events == 0 then return nil end
        local out = self.events
        self.events = {}
        return out
    end
    function w:mechanism_apply(ev)
        local m = self.mechs[ev.guid]
        if m == nil or not m.loaded then return "missing" end
        if ev.kind == PUSH then
            if m.moved then return "skip" end
            m.moved = true
        else
            m.played = m.played + 1
        end
        self.played[#self.played + 1] = ev
        return "done"
    end
    return w
end

local function make_pair(settings)
    local pair = { now = 0, a_to_b = {}, b_to_a = {}, ready = true, loading = false }
    pair.wa, pair.wb = make_world(), make_world()
    local function sync(out)
        return MechanismSync.new({ protocol = P, settings = settings or {},
            send = function(bytes) table.insert(pair[out], bytes) end })
    end
    pair.a, pair.b = sync("a_to_b"), sync("b_to_a")
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.1
            local ab, ba = self.a_to_b, self.b_to_a
            self.a_to_b, self.b_to_a = {}, {}
            for _, m in ipairs(ab) do self.b:on_message(assert(P.decode(m)), self.now) end
            for _, m in ipairs(ba) do self.a:on_message(assert(P.decode(m)), self.now) end
            self.a:tick(self.now, self.wa, self.ready, self.loading)
            self.b:tick(self.now, self.wb, self.ready, self.loading)
        end
    end
    for _, w in ipairs({ pair.wa, pair.wb }) do
        w:add(G_LEVER)
        w:add(G_CART)
    end
    return pair
end

T.run("mechanisms_roundtrip", function()
    local msgs = P.encode_mechanisms({ { guid = G_LEVER, kind = PORT, key = KEY }, { guid = G_CART, kind = PUSH, key = 0 } })
    T.eq(#msgs, 1, "one message")
    local m = assert(P.decode(msgs[1]))
    T.eq(m.type, P.T.MECHANISMS, "type")
    T.eq(m.mechs[1].guid, G_LEVER, "guid")
    T.eq(m.mechs[1].key, KEY, "the full 32-bit key")
    T.eq(m.mechs[2].kind, PUSH, "kind")
    local many = {}
    for i = 1, 120 do many[i] = { guid = G_LEVER, kind = PORT, key = i } end
    T.eq(#P.encode_mechanisms(many), 3, "split in messages of 50")
end)

T.run("a_lever_pulled_plays_its_sequence_in_the_partners_game", function()
    local pair = make_pair()
    pair.wa:use(G_LEVER, PORT, KEY)
    pair:step(3)
    T.eq(pair.wb.mechs[G_LEVER].played, 1, "the partner's game played it")
    T.eq(pair.wb.played[1].key, KEY, "the same sequence")
    pair:step(10)
    T.eq(pair.wa.mechs[G_LEVER].played, 1, "nothing came back")
    T.eq(pair.a:summary().counters.sent, 1, "sent once")
    -- The game's overloads all end in the same call: one use reported twice in a frame is one.
    pair.wa:use(G_LEVER, PORT, 5)
    pair.wa:use(G_LEVER, PORT, 5)
    pair:step(5)
    T.eq(pair.wb.mechs[G_LEVER].played, 2, "one more, not two")
end)

T.run("a_pushed_cart_moves_in_the_partners_game", function()
    local pair = make_pair()
    pair.wb:use(G_CART, PUSH)
    pair:step(3)
    T.check(pair.wa.mechs[G_CART].moved, "moved in the other game")
    T.eq(pair.a:summary().counters.applied, 1, "applied")
end)

T.run("a_sequence_both_games_start_plays_once_in_each", function()
    local pair = make_pair()
    -- Both games react to the same story flag in the same moment.
    pair.wa:use(G_LEVER, PORT, KEY)
    pair.wb:use(G_LEVER, PORT, KEY)
    pair:step(10)
    T.eq(pair.wa.mechs[G_LEVER].played, 1, "once here")
    T.eq(pair.wb.mechs[G_LEVER].played, 1, "once there")
    T.eq(pair.a:summary().counters.same + pair.b:summary().counters.same, 2, "both recognised as the same")
end)

T.run("the_partners_report_arriving_before_our_own_is_not_played_twice", function()
    local pair = make_pair()
    pair.wa:use(G_LEVER, PORT, KEY)
    pair.a:tick(pair.now, pair.wa, true, false) -- sent
    local msg = table.remove(pair.a_to_b, 1)
    pair.b:on_message(assert(P.decode(msg)), pair.now) -- arrives first...
    pair.wb:use(G_LEVER, PORT, KEY) -- ...then our game starts it itself in the same frame
    pair.b:tick(pair.now, pair.wb, true, false)
    T.eq(pair.wb.mechs[G_LEVER].played, 1, "played once")
    T.eq(pair.b:summary().counters.same, 1, "recognised")
end)

T.run("a_mechanism_not_loaded_waits_then_is_left_to_the_saved_state", function()
    local pair = make_pair()
    pair.wa:add(G_FAR)
    pair.wb:add(G_FAR)
    pair.wb.mechs[G_FAR].loaded = false
    pair.wa:use(G_FAR, PORT, 7)
    pair:step(5)
    T.eq(pair.b:summary().queued, 1, "waiting for its area")
    pair.wb.mechs[G_FAR].loaded = true
    pair:step(5)
    T.eq(pair.wb.mechs[G_FAR].played, 1, "played once loaded")
    pair.wb.mechs[G_FAR].loaded = false
    pair.wa:use(G_FAR, PORT, 8)
    pair:step(120)
    T.eq(pair.b:summary().queued, 0, "given up")
    T.eq(pair.b:summary().counters.missing, 1, "counted")
    pair.wb.mechs[G_FAR].loaded = true
    pair:step(5)
    T.eq(pair.wb.mechs[G_FAR].played, 1, "not played late next to a player who just arrived")
end)

T.run("nothing_plays_while_not_ready_and_area_setup_is_not_sent", function()
    local pair = make_pair()
    pair.ready = false
    pair.wa:use(G_LEVER, PORT, KEY)
    pair:step(5)
    T.eq(pair.wb.mechs[G_LEVER].played, 0, "waits while the partner is not ready")
    pair.ready = true
    pair:step(2)
    T.eq(pair.wb.mechs[G_LEVER].played, 1, "then plays")
    pair.loading = true
    pair.wa:use(G_LEVER, PORT, 99)
    pair:step(5)
    pair.loading = false
    pair:step(5)
    T.eq(pair.wb.mechs[G_LEVER].played, 1, "a sequence during our loading is the area's setup")
    T.eq(pair.a:summary().counters.loading, 1, "counted")
end)

T.run("mechanism_sync_can_be_switched_off", function()
    local pair = make_pair({ sync_mechanisms = false })
    pair.wa:use(G_LEVER, PORT, KEY)
    pair.wa:use(G_CART, PUSH)
    pair:step(10)
    T.eq(pair.wb.mechs[G_LEVER].played, 0, "off")
    T.check(not pair.wb.mechs[G_CART].moved, "off")
    pair.b:on_message(assert(P.decode(P.encode_mechanisms({ { guid = G_LEVER, kind = PORT, key = KEY } })[1])), pair.now)
    T.eq(pair.b:summary().queued, 0, "nothing kept for later")
    T.eq(pair.a:summary().counters.sent, 0, "nothing sent")
end)

-------------------------------------------------------------------------------
-- The world adapter against the mocked RE4 gimmicks
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
    w:install_hooks({})
    w:set_active(true)
    game:read_player_state()
    return w, game, world
end

T.run("adapter_reports_a_levers_sequence", function()
    local w, game = fresh()
    T.check(game:capabilities().mechanisms.ok, "mechanisms capability")
    local opened = 0
    local lever = mock.make_mechanism(G_LEVER, "chainsaw.GmLever", function() opened = opened + 1 end)
    lever.gimmick:call("setGmFlag", true, nil, nil) -- GmLever.onUsed: flag, then the sequence
    mock.play_portrayal(lever, KEY)
    T.eq(opened, 1, "it played here")
    local ev = w:take_mechanism_events()
    T.eq(#ev, 1, "one sequence")
    T.eq(ev[1].guid, G_LEVER, "by GameObject GUID")
    T.eq(ev[1].kind, PORT, "a portrayal")
    T.eq(ev[1].key, KEY, "its key")
    T.eq(ev[1].gimmick, "chainsaw.GmLever", "of a lever")
    T.eq(w:take_mechanism_events(), nil, "taken")
end)

T.run("adapter_keeps_other_syncs_and_player_actions_to_themselves", function()
    local w = fresh()
    -- A door (door_sync), a lever whose sequence runs an effect our game cannot mute, a
    -- portrayal with no gimmick (an event: trigger_sync).
    local door = mock.make_mechanism(G_DOOR, "chainsaw.GmDoor")
    local deadly = mock.make_mechanism(G_FAR, "chainsaw.GmLever", nil, { "chainsaw.TestMovieSettings.Param" })
    local go = mock.make_go("Event")
    go.guid = "22222222-0000-0000-0000-000000000009"
    local event = { port = mock.add_component(go, "chainsaw.PortrayalSettings", { __fields = {} }) }
    mock.play_portrayal(door, 1)
    mock.play_portrayal(deadly, 2)
    mock.play_portrayal(event, 3)
    T.eq(#w:take_mechanism_events(), 0, "none shared")
    T.eq(w.counters.mech_not_shared, 3, "counted")
end)

T.run("adapter_plays_the_partners_sequence_once", function()
    local w, _, world = fresh()
    local opened = 0
    local lever = mock.make_mechanism(G_LEVER, "chainsaw.GmShelves", function() opened = opened + 1 end)
    T.eq(w:mechanism_apply({ guid = G_LEVER, kind = PORT, key = KEY }), "done", "played")
    T.eq(opened, 1, "the sequence ran")
    T.eq(world.portrayals[#world.portrayals].key, KEY, "with its key")
    T.eq(w:take_mechanism_events(), nil, "not reported back")
    -- Our game now starts it itself (the gimmick flag gimmick_sync brought): not twice.
    world.now = 2
    mock.play_portrayal(lever, KEY)
    T.eq(opened, 1, "still once")
    T.eq(w.counters.mech_doubles, 1, "the double was skipped")
    T.eq(w:take_mechanism_events(), nil, "and not reported")
    -- Much later the same sequence is a new one.
    world.now = 60
    mock.play_portrayal(lever, KEY)
    T.eq(opened, 2, "a later use plays")
    T.eq(#w:take_mechanism_events(), 1, "and is reported")
    T.eq(w:mechanism_apply({ guid = "99999999-0000-0000-0000-000000000000", kind = PORT, key = 1 }), "missing", "unknown")
    mock.make_mechanism(G_DOOR, "chainsaw.GmDoor")
    T.eq(w:mechanism_apply({ guid = G_DOOR, kind = PORT, key = 1 }), "skip", "a denied gimmick is not played")
end)

T.run("adapter_reports_and_moves_a_pushed_cart", function()
    local w = fresh()
    local cart = mock.make_push(G_CART)
    mock.push(cart)
    local ev = w:take_mechanism_events()
    T.eq(#ev, 1, "the push")
    T.eq(ev[1].kind, PUSH, "a push")
    T.eq(ev[1].guid, G_CART, "of the cart")
    cart:call("setGmFlag", true, nil, nil)
    T.eq(w:take_mechanism_events(), nil, "already moved: nothing more")
    local other = mock.make_push(G_FAR)
    T.eq(w:mechanism_apply({ guid = G_FAR, kind = PUSH, key = 0 }), "done", "moved")
    T.eq(other.motion, 101, "with its move motion (MotMove)")
    T.eq(other.effector_moved, other.__fields._Move, "the AI blocker moved along")
    T.eq(other.flag, true, "flagged as moved")
    T.eq(w:take_mechanism_events(), nil, "not reported back")
    T.eq(w:mechanism_apply({ guid = G_FAR, kind = PUSH, key = 0 }), "skip", "already moved")
end)

T.finish()
