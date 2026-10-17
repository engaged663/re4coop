-- Saves for both players and joining from the title screen: two simulated games saving
-- (every message through the real protocol encoder/decoder), then the real game adapter
-- (game_save.lua) and a client Session against the mocked RE4 save system.
local T = require("testlib")
local P = require("re4coop.protocol")
local SaveSync = require("re4coop.save_sync")

-- A game's save system: slots written, whether it can save now.
local function make_game()
    local g = { saved = {}, files = {}, can = true, why = nil }
    function g:save_can() return self.can, self.why end
    function g:save_now(slot)
        self.saved[#self.saved + 1] = slot
        self.files[slot] = true
        if self.on_save then self.on_save(slot, true, slot) end -- the hook reports our own save
        return true
    end
    function g:save_exists(slot) return self.files[slot] == true end
    function g:any_save() return next(self.files) ~= nil end
    return g
end

-- host = "a", client = "b"
local function make_pair(settings)
    local pair = { now = 0, a_to_b = {}, b_to_a = {}, msgs = { a = {}, b = {} }, ready = { a = true, b = true },
        connected = true }
    pair.ga, pair.gb = make_game(), make_game()
    local function sync(name, out, role)
        local s = {}
        for k, v in pairs(settings or {}) do s[k] = v end
        return SaveSync.new({ protocol = P, settings = s,
            send = function(bytes) table.insert(pair[out], bytes) end,
            notify = function(text, kind) table.insert(pair.msgs[name], { text = text, kind = kind }) end,
            partner_name = function() return name == "a" and "Bob" or "Ann" end,
            role = function() return role end,
            active = function() return pair.connected end })
    end
    pair.a, pair.b = sync("a", "a_to_b", "host"), sync("b", "b_to_a", "client")
    pair.ga.on_save = function(slot, mirrored, from) pair.a:on_local_save(slot, pair.now, mirrored, from) end
    pair.gb.on_save = function(slot, mirrored, from) pair.b:on_local_save(slot, pair.now, mirrored, from) end
    -- The game's own save (autosave point or typewriter), through the redirect like the hook.
    function pair:game_save(name, slot)
        local s, g = self[name], self["g" .. name]
        local to = s:redirect(slot)
        g.files[to] = true
        g.saved[#g.saved + 1] = to
        s:on_local_save(to, self.now, false, slot)
        return to
    end
    function pair:step(n)
        for _ = 1, n or 1 do
            self.now = self.now + 0.1
            local ab, ba = self.a_to_b, self.b_to_a
            self.a_to_b, self.b_to_a = {}, {}
            for _, m in ipairs(ab) do self.b:on_message(assert(P.decode(m)), self.now) end
            for _, m in ipairs(ba) do self.a:on_message(assert(P.decode(m)), self.now) end
            self.a:tick(self.now, self.ga, self.ready.a)
            self.b:tick(self.now, self.gb, self.ready.b)
        end
    end
    function pair:told(name, pattern)
        for _, m in ipairs(self.msgs[name]) do
            if m.text:find(pattern) then return true end
        end
        return false
    end
    return pair
end

T.run("save_roundtrip", function()
    local m = assert(P.decode(P.encode_save({ kind = P.SAVE_KIND.MANUAL })))
    T.eq(m.type, P.T.SAVE, "type")
    T.eq(m.kind, P.SAVE_KIND.MANUAL, "kind")
end)

T.run("a_host_autosave_saves_the_client_into_its_coop_slot", function()
    local pair = make_pair()
    pair:game_save("a", 0)
    T.eq(pair.ga.saved[1], 0, "the host's own autosave stays in slot 0")
    pair:step(20)
    T.eq(#pair.gb.saved, 1, "the client saved once")
    T.eq(pair.gb.saved[1], 20, "into its co-op slot")
    T.check(pair:told("b", "Saved with Ann %(slot 20%)"), "the client is told")
    pair:step(20)
    T.eq(#pair.ga.saved, 1, "the client's save is not reported back (no ping-pong)")
end)

T.run("a_client_autosave_goes_to_its_coop_slot_and_saves_the_host", function()
    local pair = make_pair()
    local to = pair:game_save("b", 0)
    T.eq(to, 20, "the client's autosave is redirected")
    T.eq(pair.b:summary().counters.redirected, 1, "counted")
    pair:step(20)
    T.eq(pair.ga.saved[1], 0, "the host saved into its autosave slot")
    T.eq(#pair.ga.saved, 1, "once")
    T.eq(#pair.gb.saved, 1, "and the client only once")
end)

T.run("a_lobby_game_saves_the_host_into_its_coop_file", function()
    local pair = make_pair()
    pair.a:set_host_slot(18)
    local to = pair:game_save("a", 0)
    T.eq(to, 18, "the host's autosave goes to its co-op file (single-player autosave untouched)")
    pair:step(20)
    T.eq(pair.gb.saved[1], 20, "the client saved into its co-op slot")
    -- The client's autosave makes the host save into its co-op file, not slot 0.
    pair.now = pair.now + 30
    pair:game_save("b", 0)
    pair:step(20)
    T.eq(pair.ga.saved[#pair.ga.saved], 18, "the host's save for the client goes to its co-op file")
    -- A typewriter save of the host elsewhere: the co-op file follows.
    pair.now = pair.now + 30
    local before = #pair.ga.saved
    pair:game_save("a", 3)
    pair:step(20)
    T.eq(pair.ga.saved[before + 1], 3, "the slot the host chose")
    T.eq(pair.ga.saved[before + 2], 18, "then a copy into its co-op file")
    -- Game over -> Continue reloads the co-op file; the lobby's own load asks for its slot.
    T.eq(pair.a:continue_slot(pair.now), 18, "continue loads the co-op file")
    pair.a:request_load(17, pair.now)
    T.eq(pair.a:continue_slot(pair.now), 17, "the slot the lobby asked for")
    pair.a:set_host_slot(nil)
    T.eq(pair.a:redirect(0), 0, "outside a lobby game the autosave is the game's again")
end)

T.run("a_typewriter_save_stays_where_the_player_chose", function()
    local pair = make_pair({ coop_save_slot = 7 })
    T.eq(pair:game_save("b", 5), 5, "the client's own save into slot 5 stays there")
    pair:step(20)
    T.eq(pair.ga.saved[1], 0, "the host saves into its autosave")
    T.eq(#pair.ga.saved, 1, "once")
    T.eq(pair.gb.saved[2], 7, "the client's co-op slot (setting) follows its typewriter save")
    T.eq(#pair.gb.saved, 2, "and nothing more")
    T.check(pair:told("b", "co%-op slot too %(slot 7%)"), "told")
    pair.now = pair.now + 30
    pair:game_save("a", 3)
    pair:step(20)
    T.eq(pair.gb.saved[3], 7, "a host typewriter save saves the client into its co-op slot")
    T.eq(#pair.ga.saved, 2, "and the host is not asked to save again")
end)

T.run("the_same_save_in_both_games_is_not_made_twice", function()
    local pair = make_pair()
    pair:game_save("a", 0) -- both walk through the same autosave point
    pair:game_save("b", 0)
    pair:step(30)
    T.eq(#pair.ga.saved, 1, "the host saved once")
    T.eq(#pair.gb.saved, 1, "the client saved once")
    T.check(pair.a:summary().counters.same + pair.b:summary().counters.same >= 1, "counted as the same save")
    -- The partner's report arrives first, our own save follows a moment later.
    pair.now = pair.now + 30
    pair:game_save("a", 0)
    pair.ready.b = false
    pair:step(2)
    pair:game_save("b", 0)
    pair.ready.b = true
    pair:step(30)
    T.eq(#pair.gb.saved, 2, "the client's own save stood for the host's")
end)

T.run("a_partners_save_waits_until_our_game_can_save", function()
    local pair = make_pair()
    pair.ready.b = false -- a cutscene plays, or the client is still taking over the host's world
    pair:game_save("a", 0)
    pair:step(60)
    T.eq(#pair.gb.saved, 0, "not while it cannot")
    T.eq(pair.b:summary().queued, 1, "waiting")
    T.check(pair:told("b", "saves as soon as it can"), "told it waits")
    pair.ready.b = true
    pair.gb.can, pair.gb.why = false, "the game is saving or loading"
    pair:step(30)
    T.eq(#pair.gb.saved, 0, "not while the save system is busy")
    pair.gb.can = true
    pair:step(15)
    T.eq(pair.gb.saved[1], 20, "then it saves")
end)

T.run("a_partners_save_that_never_can_be_made_is_dropped", function()
    local pair = make_pair()
    pair.ready.b = false
    pair:game_save("a", 0)
    pair:step(950)
    T.eq(#pair.gb.saved, 0, "never saved")
    T.eq(pair.b:summary().counters.given_up, 1, "given up")
    T.eq(pair.b:summary().queued, 0, "nothing left waiting")
    T.check(pair:told("b", "could not save with them"), "told")
end)

T.run("saving_for_both_can_be_switched_off", function()
    local pair = make_pair({ sync_saves = false })
    T.eq(pair:game_save("b", 0), 0, "no redirect")
    pair:game_save("a", 0)
    pair:step(20)
    T.eq(#pair.ga.saved, 1, "the host only made its own save")
    T.eq(#pair.gb.saved, 1, "the client only made its own save")
    -- Not connected: nothing redirected or reported either.
    local solo = make_pair()
    solo.connected = false
    T.eq(solo:game_save("b", 0), 0, "alone, the client's autosave stays in slot 0")
    solo:step(10)
    T.eq(#solo.ga.saved, 0, "nothing sent")
end)

T.run("joining_from_the_menu_loads_the_coop_save_once", function()
    local pair = make_pair()
    local b, g = pair.b, pair.gb
    T.eq(b:menu_tick(0, { joining = true, partner_in_game = false }, g), nil, "not before the host is in game")
    g.files[3] = true
    g.files[20] = true
    T.eq(b:menu_tick(1, { joining = true, partner_in_game = true }, g), "continue", "the host plays: load now")
    T.eq(b:continue_slot(2), 20, "Continue loads the co-op slot")
    T.check(pair:told("b", "co%-op save %(slot 20%)"), "told")
    T.eq(b:menu_tick(2, { joining = true, partner_in_game = true }, g), nil, "asked once")
    T.eq(b:continue_slot(200), 20, "a game over later reloads it too")
    pair.connected = false
    T.eq(b:continue_slot(200), nil, "not once the session is over")
    pair.connected = true
    b:menu_tick(40, { joining = true, partner_in_game = true }, g)
    T.check(pair:told("b", "did not load"), "a load that never happened is reported")
    -- The host never loads anything this way.
    T.eq(pair.a:menu_tick(1, { joining = true, partner_in_game = true }, pair.ga), nil, "host")
end)

T.run("joining_without_a_coop_save_loads_the_latest", function()
    local pair = make_pair()
    local b, g = pair.b, pair.gb
    g.files[3] = true
    T.eq(b:menu_tick(1, { joining = true, partner_in_game = true }, g), "continue", "load")
    T.eq(b:continue_slot(2), nil, "the game's own choice (the latest save)")
    T.check(pair:told("b", "latest save"), "told")
end)

T.run("a_game_over_reloads_the_clients_coop_save_once_it_holds_this_session", function()
    local pair = make_pair()
    local b, g = pair.b, pair.gb
    g.files[3], g.files[20] = true, true -- an old co-op save from another session
    pair.ga.files[3] = true
    b:menu_tick(1, { joining = false, partner_in_game = true }, g) -- joined while in game
    T.eq(b:continue_slot(5), nil, "the old co-op save is not this session's: the newest save")
    pair:game_save("b", 0) -- an autosave point: into the co-op slot
    T.eq(b:continue_slot(6), 20, "now a game over reloads the co-op slot")
    T.eq(pair.a:continue_slot(6), nil, "never for the host")
    b:reset() -- the partner left
    T.eq(b:continue_slot(7), nil, "a new session starts over")
end)

T.run("joining_without_any_save_starts_a_new_game_from_the_main_menu", function()
    local pair = make_pair()
    local b, g = pair.b, pair.gb
    -- The title screen cannot start one: it waits for a button (told once).
    T.eq(b:menu_tick(1, { joining = true, partner_in_game = true, where = "title" }, g), nil, "nothing on the title")
    T.eq(b:menu_tick(1.1, { joining = true, partner_in_game = true, where = "title" }, g), nil, "still nothing")
    T.check(pair:told("b", "press a button"), "told to go on to the main menu")
    T.eq(#pair.msgs.b, 1, "once")
    -- The main menu starts a new game in the host's chapter.
    T.eq(b:menu_tick(2, { joining = true, partner_in_game = true, where = "menu", can_start_new = true }, g), "new",
        "a new game")
    T.check(pair:told("b", "starting a new one"), "told")
    T.eq(b:menu_tick(3, { joining = true, partner_in_game = true, where = "menu", can_start_new = true }, g), nil,
        "asked once")
    T.eq(b:continue_slot(3), nil, "Continue is not involved")
    b:menu_tick(60, { joining = true, partner_in_game = true, where = "menu", can_start_new = true }, g)
    T.check(not pair:told("b", "did not load"), "no 'the save did not load' for a new game")
end)

T.run("joining_without_any_save_and_no_way_to_start_one_asks_for_a_new_game", function()
    local pair = make_pair()
    T.eq(pair.b:menu_tick(1, { joining = true, partner_in_game = true, where = "menu" }, pair.gb), nil, "nothing to load")
    T.check(pair:told("b", "no saved game"), "told")
    T.eq(#pair.msgs.b, 1, "once")
    pair.b:menu_tick(2, { joining = true, partner_in_game = true, where = "menu" }, pair.gb)
    T.eq(#pair.msgs.b, 1, "not every frame")
end)

T.run("loading_on_join_can_be_switched_off", function()
    local pair = make_pair({ auto_load_on_join = false })
    pair.gb.files[3] = true
    T.eq(pair.b:menu_tick(1, { joining = true, partner_in_game = true }, pair.gb), nil, "off")
    T.eq(pair.b:menu_tick(1, { joining = false, partner_in_game = true }, pair.gb), nil, "not joining")
end)

-------------------------------------------------------------------------------
-- The game adapter against the mocked RE4 save system
-------------------------------------------------------------------------------

local mock = require("mock_reframework")

local function fresh_game()
    for name in pairs(package.loaded) do
        if name:find("^re4coop%.game") then package.loaded[name] = nil end
    end
    local world = mock.install()
    world.chapter = 21100
    local Game = require("re4coop.game")
    local game = Game.new(function() end, function() return 0 end)
    return game, world
end

T.run("adapter_reports_and_redirects_the_games_saves", function()
    local game, world = fresh_game()
    local seen = {}
    local client = true
    T.check(game:install_save_hooks({
        redirect = function(slot) return (client and slot == 0) and 20 or slot end,
        on_save = function(slot, mirrored, from) seen[#seen + 1] = { slot = slot, mirrored = mirrored, from = from } end,
        continue_slot = function() return nil end,
        on_menu = function() return false end,
    }), "hooked")
    local caps = game:capabilities()
    T.check(caps.save_sync and caps.save_sync.ok, "save_sync capability")
    T.check(caps.join_load and caps.join_load.ok, "join_load capability: " .. tostring(caps.join_load and caps.join_load.detail))
    mock.game_save(0)
    T.eq(world.saves[1], 20, "the game's autosave went to the co-op slot")
    T.eq(seen[1].slot, 20, "reported where it went")
    T.eq(seen[1].from, 0, "and where the game wanted it")
    T.eq(seen[1].mirrored, false, "the game's own save")
    client = false
    mock.game_save(4)
    T.eq(world.saves[2], 4, "other slots untouched")
    -- A save for the partner, through the game's save flow.
    T.check(game:save_can(), "can save")
    T.check(game:save_now(0), "saved")
    T.eq(world.saves[3], 0, "into the slot asked for")
    T.eq(seen[3].mirrored, true, "reported as ours for the partner")
    T.check(world.play_load_marked, "marked like the game's autosave does")
    world.save_busy = true
    T.eq(game:save_can(), false, "not while saving")
    world.save_busy, world.save_excluded = false, true
    T.eq(game:save_can(), false, "not while the game excludes saving")
    T.check(game:save_exists(4) and not game:save_exists(9), "slots that hold a save")
    T.check(game:any_save(), "a save to load")
end)

-------------------------------------------------------------------------------
-- A client joining from the main menu: real Session, game and world adapters
-------------------------------------------------------------------------------

local function fake_net()
    local net = { inbox = {}, sent = {}, st = "connected", r = "client" }
    function net.state() return net.st end
    function net.role() return net.r end
    function net.poll()
        local out = net.inbox
        net.inbox = {}
        return out
    end
    function net.send(b, reliable) net.sent[#net.sent + 1] = { data = b, reliable = reliable } return true end
    function net.stats() return { state = net.st, peer_name = "Host", rtt_ms = 1 } end
    function net.stop() net.st = "idle" net.r = "none" end
    return net
end

local function client_on_title()
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    local world = mock.install()
    world.chapter = nil
    local Game = require("re4coop.game")
    local World = require("re4coop.game_world")
    local Session = require("re4coop.session")
    local Config = require("re4coop.config")
    local clock = { t = 0 }
    local game = Game.new(function() end, function() return clock.t end)
    local w = World.new(game, function() end)
    local net = fake_net()
    local settings = Config.load(nil)
    local s = Session.new({ net = net, game = game, world = w, clock = function() return clock.t end, settings = settings })
    s.role = "client"
    s:make_syncs()
    return s, net, clock, world
end

local HOST_CHAPTER = 21500

local function host_connects_and_plays(s, net, clock)
    net.inbox[#net.inbox + 1] = { type = "connected", name = "Host", peer = "127.0.0.1" }
    s:update_network_only() -- title screen: only the render-thread loop runs
    clock.t = clock.t + 0.1
    net.inbox[#net.inbox + 1] = { type = "message", data = P.encode_player({ time = 1, pos = { x = 1, y = 2, z = 3 },
        rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 10, max_hp = 10, chapter = HOST_CHAPTER, stage = 40200, flags = 0 }) }
    s:update_network_only()
end

T.run("a_client_joining_from_the_menu_loads_its_coop_save_into_the_hosts_chapter", function()
    local s, net, clock, world = client_on_title()
    world.save_files[3] = { chapter = 21100, order = 2 }  -- the client's own latest save
    world.save_files[20] = { chapter = 21300, order = 1 } -- its last co-op session
    T.eq(mock.menu_frame("menu"), nil, "nothing happens before joining")
    host_connects_and_plays(s, net, clock)
    T.check(s.join_travel_pending, "joining")
    -- Asked on the title screen: it skips to the main menu, which runs Continue.
    T.eq(mock.menu_frame("title"), nil, "the title screen skips to the main menu")
    T.check(world.singletons["chainsaw.UDSManagerApp"].__fields["<RequestGameIntentMode>k__BackingField"] == 0,
        "the main game's intent")
    clock.t = clock.t + 0.1
    T.eq(mock.menu_frame("menu"), 20, "Continue loaded the co-op save")
    T.eq(world.chapter, HOST_CHAPTER, "into the host's chapter")
    T.eq(world.loads, 1, "one load")
    local told = false
    for _, m in ipairs(s.messages) do
        if m.text:find("co%-op save %(slot 20%)") then told = true end
    end
    T.check(told, "the player is told")
end)

T.run("a_client_joining_from_the_menu_without_a_coop_save_loads_its_latest", function()
    local s, net, clock, world = client_on_title()
    world.save_files[3] = { chapter = 21100, order = 2 }
    world.save_files[0] = { chapter = 21000, order = 1 }
    host_connects_and_plays(s, net, clock)
    T.eq(mock.menu_frame("menu"), 3, "Continue loaded the latest save")
    T.eq(world.chapter, HOST_CHAPTER, "into the host's chapter")
    T.eq(mock.menu_frame("menu"), nil, "only once")
end)

T.run("a_client_with_no_save_is_asked_to_start_one", function()
    local s, net, clock, world = client_on_title()
    host_connects_and_plays(s, net, clock)
    T.eq(mock.menu_frame("menu"), nil, "nothing to load")
    T.eq(world.loads, 0, "no load")
    local told = false
    for _, m in ipairs(s.messages) do
        if m.text:find("no saved game") then told = true end
    end
    T.check(told, "told to start a game")
end)

local function told(s, pattern)
    for _, m in ipairs(s.messages) do
        if m.text:find(pattern) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Joining late, at the host's place (docs/RESEARCH.md 3.34): real Session, game and world
-------------------------------------------------------------------------------

local HOST_STAGE, HOST_POS = 46100, { x = 300, y = -7, z = -10 }

local function host_plays(net, chapter, flags)
    net.inbox[#net.inbox + 1] = { type = "message", data = P.encode_player({ time = 1, pos = HOST_POS,
        rot = { x = 0, y = 0.6, z = 0, w = 0.8 }, hp = 10, max_hp = 10, chapter = chapter or HOST_CHAPTER,
        stage = HOST_STAGE, flags = flags or 0 }) }
end

-- One game frame, the way the entry script runs it.
local function frame(s)
    s.game:begin_frame()
    s:update()
end

local function sent(net, t)
    local n = 0
    for _, m in ipairs(net.sent) do
        if m.data:byte(1) == t then n = n + 1 end
    end
    return n
end

-- 0.11.1 and before: in the main menu the session's own loop runs, and its join travel started
-- with the host's first message - the join was no longer pending when the menu asked, so
-- Continue never ran and the player had to load a save themself.
T.run("a_client_joining_in_the_main_menu_loads_straight_into_the_hosts_place", function()
    local s, net, clock, world = client_on_title()
    world.game_state, world.player = "chainsaw.GameStateMainMenu", nil
    world.save_files[3] = { chapter = 21100, order = 2, stage = 40200, pos = { x = 5, y = 0, z = 5 } }
    net.inbox[#net.inbox + 1] = { type = "connected", name = "Host", peer = "127.0.0.1" }
    for _ = 1, 10 do
        clock.t = clock.t + 0.1
        host_plays(net)
        frame(s) -- the main menu's frames: the game thread runs the session
    end
    T.check(s.join_travel_pending, "the join waits for its own load (no travel before our game plays)")
    T.eq(s.travel:busy(), false, "no travel yet")
    world.player = mock.make_player({ x = 0, y = 0, z = 0 }) -- the player the load brings
    T.eq(mock.menu_frame("menu"), 3, "Continue loaded the client's latest save")
    T.eq(world.chapter, HOST_CHAPTER, "into the host's chapter")
    T.eq(world.stage, HOST_STAGE, "the host's part of the map")
    T.near(world.player.pos.x, HOST_POS.x, 1e-6, "at the host's place")
    T.near(world.player.pos.z, HOST_POS.z, 1e-6, "...")
    -- In game: the join takes over the host's world; it is already next to the host.
    world.game_state = "chainsaw.GameStateInGame"
    for _ = 1, 50 do
        clock.t = clock.t + 0.1
        host_plays(net)
        frame(s)
    end
    T.eq(sent(net, P.T.WORLD_REQUEST), 1, "the host's world asked for")
    T.eq(s.join_travel_pending, false, "joined")
end)

T.run("a_client_joining_while_the_host_is_in_a_cutscene_spawns_where_the_host_last_played", function()
    local s, net, clock, world = client_on_title()
    world.game_state, world.player = "chainsaw.GameStateMainMenu", nil
    world.save_files[3] = { chapter = 21100, order = 2 }
    net.inbox[#net.inbox + 1] = { type = "connected", name = "Host", peer = "127.0.0.1" }
    clock.t = clock.t + 0.1
    host_plays(net)
    frame(s)
    -- Then a cutscene: its camera position is no place to stand.
    HOST_POS = { x = 900, y = 50, z = 900 }
    for _ = 1, 5 do
        clock.t = clock.t + 0.1
        host_plays(net, HOST_CHAPTER, P.PLAYER_FLAGS.CUTSCENE)
        frame(s)
    end
    HOST_POS = { x = 300, y = -7, z = -10 }
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    T.eq(mock.menu_frame("menu"), 3, "loaded")
    T.near(world.player.pos.x, 300, 1e-6, "where the host last stood in play")
end)

T.run("a_client_joining_in_game_from_another_chapter_reloads_at_the_hosts_place", function()
    local s, net, clock, world = client_on_title()
    world.game_state = "chainsaw.GameStateInGame"
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    world.stage, world.chapter = 40200, 21100
    world.save_files[3] = { chapter = 21100, order = 2 }  -- its own game
    world.save_files[20] = { chapter = 21300, order = 1 } -- its co-op save with the host
    net.inbox[#net.inbox + 1] = { type = "connected", name = "Host", peer = "127.0.0.1" }
    for _ = 1, 30 do
        clock.t = clock.t + 0.1
        host_plays(net, 22200)
        frame(s)
        mock.save_system_tick()
    end
    T.eq(world.load_requests and world.load_requests[1], 20, "its co-op save is read in game")
    T.check(world.state_requests ~= nil, "then the game leaves the map, the way Load Game does")
    T.eq(world.game_over_requests, 0, "no game over")
    T.check(not told(s, "Load any save"), "nothing asked of the player")
    -- The game unloads the map and loads the save into the host's chapter, at the host's place.
    world.game_state = "chainsaw.GameStateInGameCleanup"
    for _ = 1, 5 do
        clock.t = clock.t + 0.1
        host_plays(net, 22200)
        frame(s)
    end
    mock.run_ingame_reload()
    world.game_state = "chainsaw.GameStateInGame"
    T.eq(world.chapter, 22200, "the host's chapter")
    T.eq(world.stage, HOST_STAGE, "the host's part of the map")
    T.near(world.player.pos.x, HOST_POS.x, 1e-6, "next to the host")
    for _ = 1, 50 do
        clock.t = clock.t + 0.1
        host_plays(net, 22200)
        frame(s)
    end
    T.eq(sent(net, P.T.WORLD_REQUEST), 1, "then the host's world")
end)

T.finish()
