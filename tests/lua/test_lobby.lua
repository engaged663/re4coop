-- The lobby (lobby.lua): the "Multijugador" entries of the game's menu, the host's choices
-- reaching the client, ready / start, and the synchronized start (each game holds its loaded
-- map until the partner's has loaded). Then two sessions end to end through a fake wire and
-- fake games that "load" when asked to start.
local T = require("testlib")
local P = require("re4coop.protocol")
local Lobby = require("re4coop.lobby")
local Session = require("re4coop.session")
local Config = require("re4coop.config")

local L = P.LOAD_PHASE

-- Two lobbies joined by a wire: what one sends, the other receives on pump().
local function pair(settings_h, settings_c)
    local clock = { t = 0 }
    local wire = { h = {}, c = {} } -- messages waiting for host / client
    local notes = { h = {}, c = {} }
    local function make(role, settings, other, note_list)
        local s = Config.load(nil)
        for k, v in pairs(settings or {}) do s[k] = v end
        local active = { on = true }
        local l = Lobby.new({ protocol = P, settings = s,
            send = function(bytes)
                local q = wire[other]
                q[#q + 1] = bytes
                return true
            end,
            notify = function(text, kind) note_list[#note_list + 1] = { text = text, kind = kind } end,
            role = function() return role end,
            active = function() return active.on end,
            my_name = function() return role == "host" and "Leon" or "Ada" end,
            partner_name = function() return role == "host" and "Ada" or "Leon" end })
        l.test_active = active
        return l
    end
    local host = make("host", settings_h, "c", notes.h)
    local client = make("client", settings_c, "h", notes.c)
    local function pump()
        for _ = 1, 4 do
            local hm, cm = wire.h, wire.c
            wire.h, wire.c = {}, {}
            for _, b in ipairs(hm) do host:on_message(assert(P.decode(b)), clock.t, true) end
            for _, b in ipairs(cm) do client:on_message(assert(P.decode(b)), clock.t, true) end
            if #wire.h == 0 and #wire.c == 0 then break end
        end
    end
    return host, client, pump, clock, notes, wire
end

local function env(o)
    o = o or {}
    return { connected = o.connected ~= false, in_menu = o.in_menu == true, in_game = o.in_game == true,
        loading_screen = o.loading_screen == true, synced = o.synced, continue_pressed = o.continue_pressed == true }
end

T.run("protocol_roundtrip_of_the_lobby_messages", function()
    local m = assert(P.decode(P.encode_lobby_settings({ rev = 7, file = 2, mode = P.LOBBY_MODE.CONTINUE, chapter = 5,
        difficulty = 30, options = 0x2A, save_chapter = 22200, save_difficulty = 20, save_count = 12, save_empty = false })))
    T.eq(m.type, P.T.LOBBY_SETTINGS, "type")
    T.eq(m.rev, 7, "rev")
    T.eq(m.file, 2, "file")
    T.eq(m.mode, P.LOBBY_MODE.CONTINUE, "mode")
    T.eq(m.chapter, 5, "chapter")
    T.eq(m.difficulty, 30, "difficulty")
    T.eq(m.options, 0x2A, "options")
    T.eq(m.save_chapter, 22200, "save chapter")
    T.eq(m.save_count, 12, "save count")
    T.eq(m.save_empty, false, "save not empty")
    local p = assert(P.decode(P.encode_lobby_player({ in_lobby = true, ready = true, loadout = 4, name = "Ada" })))
    T.eq(p.type, P.T.LOBBY_PLAYER, "player type")
    T.eq(p.in_lobby, true, "in lobby")
    T.eq(p.ready, true, "ready")
    T.eq(p.loadout, 4, "loadout")
    T.eq(p.name, "Ada", "name")
    local s = assert(P.decode(P.encode_lobby_start({ start_id = 3, mode = P.LOBBY_MODE.NEW, file = 1, chapter = 7,
        difficulty = 20, key = 12, chapter_id = 23100 })))
    T.eq(s.type, P.T.LOBBY_START, "start type")
    T.eq(s.start_id, 3, "start id")
    T.eq(s.key, 12, "key")
    T.eq(s.chapter_id, 23100, "chapter id")
    local st = assert(P.decode(P.encode_load_state({ start_id = 3, phase = L.READY, progress = 250 })))
    T.eq(st.phase, L.READY, "phase")
    T.eq(st.progress, 100, "progress clamped")
    T.eq(assert(P.decode(P.encode_load_go({ start_id = 3 }))).start_id, 3, "go")
end)

T.run("chapters_and_start_points", function()
    T.eq(#Lobby.CHAPTERS, 16, "sixteen chapters")
    T.eq(Lobby.CHAPTERS[1].key, 1, "chapter 1 is a full new game (Campaign1001_Master)")
    T.eq(Lobby.CHAPTERS[2].key, 7, "chapter 2 from its head (Campaign1001_Chp1_2_Head)")
    T.eq(Lobby.CHAPTERS[16].key, 21, "chapter 16 (Chp5_4_Head)")
    T.eq(Lobby.chapter_of_id(22300), 6, "ChapterID -> chapter")
    T.eq(Lobby.chapter_of_id(21000), 1, "chapter 1's opening part")
    T.eq(Lobby.key_of_id(24200), 16, "a save in chapter 11 starts a client's new game at chapter 11")
    T.eq(Lobby.chapter_of_id(99999), nil, "unknown")
end)

T.run("menu_entries_and_screens", function()
    local host = pair()
    T.eq(host.menu_mode, "main", "the game's entries with ours")
    T.eq(host:on_menu_decide(Lobby.ACTION.MULTIPLAYER), "handled", "Multijugador")
    T.eq(host.menu_mode, "mp", "our section replaces the entries")
    T.eq(host:covers_menu(), false, "the menu stays visible")
    T.eq(host:on_menu_decide(Lobby.ACTION.OPTIONS), "handled", "options")
    T.eq(host.screen, Lobby.SCREEN.OPTIONS, "options screen")
    T.eq(host:covers_menu(), true, "our screen covers the menu")
    host:back()
    T.eq(host.screen, nil, "back to the section")
    T.eq(host.menu_mode, "mp", "still in our section")
    T.eq(host:on_menu_decide(Lobby.ACTION.HOST), "host", "Host Game asks the session to host")
    T.eq(host.screen, Lobby.SCREEN.LOBBY, "lobby screen")
    host:open(Lobby.SCREEN.OPTIONS, Lobby.SCREEN.LOBBY)
    host:back()
    T.eq(host.screen, Lobby.SCREEN.LOBBY, "options opened from the lobby go back to it")
    T.eq(host:close(), "leave", "leaving the lobby ends the session")
    T.eq(host:on_menu_decide(Lobby.ACTION.BACK), "handled", "Back")
    T.eq(host.menu_mode, "main", "the game's entries again")
    T.eq(host:on_menu_decide(3), nil, "the game's own Options are not ours")
end)

T.run("host_choices_reach_the_client_and_ready_resets", function()
    local host, client, pump = pair()
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_saves({ { empty = false, chapter_id = 22200, difficulty = 30, count = 5 }, { empty = true }, { empty = true } })
    pump()
    local v = client:view()
    T.check(v ~= nil, "client sees the host's settings")
    T.eq(v.file, 1, "file")
    T.eq(v.mode, P.LOBBY_MODE.CONTINUE, "a file with a save continues by default")
    T.eq(v.save.chapter_id, 22200, "the save's chapter")
    T.eq(v.host, false, "read-only for the client")
    client:cycle_file(1)
    T.eq(host.cfg.file, 1, "the client cannot change the host's choices")
    client:set_ready(true)
    host:set_ready(true)
    pump()
    T.eq(host.partner.ready, true, "host sees the client ready")
    T.eq(client.partner.ready, true, "client sees the host ready")
    T.eq(host:can_start(), true, "both ready: the host can start")
    host:cycle_difficulty(1)
    pump()
    T.eq(host.me.ready, false, "a changed game: the host confirms again")
    T.eq(client.me.ready, false, "and the client too")
    T.eq(host:can_start(), false, "not startable")
    host:cycle_file(1)
    pump()
    T.eq(client:view().mode, P.LOBBY_MODE.NEW, "an empty file can only start a new game")
    host:cycle_mode()
    T.eq(host:mode(), P.LOBBY_MODE.NEW, "still new")
    local before = host.cfg.chapter
    host:cycle_chapter(1)
    T.eq(host.cfg.chapter, before % 16 + 1, "chapter of the new game")
    host:cycle_chapter(-before - 1)
    T.check(host.cfg.chapter >= 1 and host.cfg.chapter <= 16, "chapters wrap")
    local opt = Lobby.OPTIONS[1].key
    local was = host.settings[opt] == true
    host:toggle_option(opt)
    pump()
    T.eq(host.settings[opt], not was, "host option toggled")
    T.eq((client:view().options & 1) == 1, not was, "the client sees it")
end)

T.run("start_new_game_both_hold_until_both_loaded", function()
    local host, client, pump, clock, notes = pair()
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_saves({ { empty = true }, { empty = true }, { empty = true } })
    host.cfg.chapter = 4
    host.cfg.difficulty = 30
    client:cycle_loadout(1)
    pump()
    T.eq(host:request_start(0), false, "nobody ready yet")
    host:set_ready(true)
    client:set_ready(true)
    pump()
    T.eq(host:request_start(0), true, "started")
    pump()
    local ha, ca = host:take_action(), client:take_action()
    T.check(ha ~= nil and ca ~= nil, "both asked to start")
    T.eq(ha.params.mode, P.LOBBY_MODE.NEW, "new game")
    T.eq(ha.params.key, 9, "chapter 4's start point")
    T.eq(ca.params.key, 9, "the client starts the same chapter")
    T.eq(ca.params.difficulty, 30, "same difficulty")
    T.eq(ha.slot, 17, "the host's co-op file 1 = slot 17")
    T.eq(host.screen, nil, "lobby screen closed")
    T.eq(host:covers_menu(), true, "the menu stays covered until the game leaves it")

    -- Host loads fast.
    clock.t = 1
    T.eq(host:tick(1, env({ in_menu = true })), false, "still on the menu")
    T.eq(client:tick(1, env({ in_menu = true })), false, "client too")
    clock.t = 2
    host:tick(2, env({ loading_screen = true }))
    T.eq(host.start.phase, L.LOADING, "host loading")
    T.eq(host:covers_menu(), false, "left the menu")
    host:tick(3, env({ in_game = true }))
    T.eq(host:tick(4, env({ in_game = true })), true, "host's map loaded: held")
    pump()
    T.eq(client.start.partner_phase, L.READY, "the client sees the host ready")
    local loaders = client:loaders(4)
    T.eq(loaders[1].name, "Leon", "host's loader first")
    T.eq(loaders[1].done, true, "host done")
    T.eq(loaders[2].done, false, "client not yet")
    -- The client takes longer.
    for t = 5, 20 do
        T.eq(host:tick(t, env({ in_game = true })), true, "host waits")
        client:tick(t, env({ loading_screen = true }))
        pump()
    end
    client:tick(21, env({ in_game = true }))
    T.eq(client:tick(22, env({ in_game = true })), true, "client loaded: held until the host says go")
    pump()
    T.eq(host:tick(22.1, env({ in_game = true })), false, "host: both loaded -> go")
    T.eq(host.start.released, true, "host released")
    clock.t = 22.1
    pump()
    T.eq(client.start.released, true, "client released by GO")
    T.eq(client:tick(22.2, env({ in_game = true })), false, "client runs")
    T.eq(client.start.why, "go", "together")
    -- The loadout, once, when the player is in control.
    T.eq(client:take_loadout(22.3, true), nil, "not at once")
    T.eq(client:take_loadout(24, false), nil, "not in a cutscene")
    local l = client:take_loadout(24, true)
    T.check(l ~= nil and #l.weapons > 0, "client's loadout")
    T.eq(client:take_loadout(25, true), nil, "only once")
    T.eq(host:take_loadout(25, true), nil, "the host chose none")
    T.eq(host:loaders(30), nil, "loaders gone a moment after the start")
    T.check(#notes.c > 0, "players were told")
end)

T.run("start_continue_carries_the_save_and_the_jump", function()
    local host, client, pump = pair()
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_saves({ { empty = true }, { empty = false, chapter_id = 23200, difficulty = 20, count = 9 }, { empty = true } })
    host:cycle_file(1)
    T.eq(host:mode(), P.LOBBY_MODE.CONTINUE, "file 2 continues")
    pump() -- (a ready sent before the client saw the change would be reset by it)
    host:set_ready(true)
    client:set_ready(true)
    pump()
    T.eq(host:request_start(0), true, "started")
    pump()
    local ha, ca = host:take_action(), client:take_action()
    T.eq(ha.params.mode, P.LOBBY_MODE.CONTINUE, "continue")
    T.eq(ha.slot, 18, "co-op file 2 = slot 18")
    T.eq(ca.params.chapter_id, 23200, "the client goes to the save's chapter")
    T.eq(ca.params.key, 13, "or starts it new (chapter 8) without a co-op save")
    T.eq(ca.params.chapter, 0, "no chapter jump")
end)

T.run("a_partner_that_fails_or_leaves_is_not_waited_for", function()
    local host, client, pump, _, notes = pair()
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_ready(true)
    client:set_ready(true)
    pump()
    host:request_start(0)
    pump()
    client:start_failed("menu busy", 1)
    pump()
    host:tick(2, env({ in_game = true }))
    T.eq(host:tick(3, env({ in_game = true })), false, "the client's start failed: the host does not hold")
    T.eq(host.start.why, "partner_failed", "why")
    -- A disconnect while held releases too.
    local h2, c2, pump2 = pair()
    h2:open(Lobby.SCREEN.LOBBY)
    c2:open(Lobby.SCREEN.LOBBY)
    h2:set_ready(true)
    c2:set_ready(true)
    pump2()
    h2:request_start(0)
    pump2()
    h2:tick(1, env({ in_game = true }))
    T.eq(h2:tick(2, env({ in_game = true })), true, "held")
    T.eq(h2:tick(3, env({ in_game = true, connected = false })), false, "partner gone: released")
    T.eq(h2.start.why, "partner_left", "why")
end)

T.run("waiting_can_be_skipped_and_times_out", function()
    local host, client, pump = pair({ start_timeout = 60 })
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_ready(true)
    client:set_ready(true)
    pump()
    host:request_start(0)
    pump()
    host:tick(1, env({ in_game = true }))
    host:tick(2, env({ in_game = true }))
    T.eq(host:start_view(2).waiting, true, "waiting veil")
    T.eq(host:tick(5, env({ in_game = true, continue_pressed = true })), true, "too early to skip")
    T.eq(host:tick(18, env({ in_game = true })), true, "still waiting")
    T.eq(host:start_view(18).can_skip, true, "after a while the player may skip")
    T.eq(host:tick(20, env({ in_game = true, continue_pressed = true })), false, "skipped")
    T.eq(host.start.why, "skipped", "why")
    pump()
    T.eq(client.start.partner_phase, L.PLAYING, "the client sees the host playing")
    client:tick(21, env({ in_game = true }))
    T.eq(client:tick(22, env({ in_game = true })), false, "and does not wait for it")
    -- Timeout.
    local h2, c2, pump2 = pair({ start_timeout = 30 })
    h2:open(Lobby.SCREEN.LOBBY)
    c2:open(Lobby.SCREEN.LOBBY)
    h2:set_ready(true)
    c2:set_ready(true)
    pump2()
    h2:request_start(0)
    h2:tick(1, env({ in_game = true }))
    h2:tick(2, env({ in_game = true }))
    T.eq(h2:tick(40, env({ in_game = true })), false, "timed out")
    T.eq(h2.start.why, "timeout", "why")
end)

T.run("a_game_that_never_leaves_the_menu_fails_the_start", function()
    local host, client, pump = pair()
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_ready(true)
    client:set_ready(true)
    pump()
    host:request_start(0)
    pump()
    client:tick(10, env({ in_menu = true }))
    client:tick(60, env({ in_menu = true }))
    T.eq(client.start.phase, L.FAILED, "the client's start failed")
    pump()
    host:tick(61, env({ in_game = true }))
    T.eq(host:tick(62, env({ in_game = true })), false, "the host plays on without it")
end)

T.run("no_waiting_when_the_player_chose_so", function()
    local host, client, pump = pair({ start_sync = false })
    host:open(Lobby.SCREEN.LOBBY)
    client:open(Lobby.SCREEN.LOBBY)
    host:set_ready(true)
    client:set_ready(true)
    pump()
    host:request_start(0)
    host:tick(1, env({ in_game = true }))
    T.eq(host:tick(2, env({ in_game = true })), false, "not held")
    T.eq(host.start.why, "no_wait", "why")
end)

T.run("client_brought_into_the_hosts_lobby_and_joining_a_game_in_progress", function()
    local host, client, pump = pair()
    host:open(Lobby.SCREEN.LOBBY)
    pump()
    T.eq(client.screen, Lobby.SCREEN.LOBBY, "a client on the menu enters the host's lobby by itself")
    local h2, c2 = pair()
    c2:open(Lobby.SCREEN.LOBBY)
    c2:join_game_in_progress()
    T.eq(c2.screen, nil, "lobby closed")
    T.eq(c2.join_running, true, "the old join from the menu may run")
end)

T.run("a_client_joins_a_host_already_playing_on_its_own", function()
    local host, client, _, _, notes = pair()
    client:open(Lobby.SCREEN.LOBBY)
    T.eq(client:auto_join(0, false), false, "not while the host is not playing")
    T.eq(client:auto_join(1, true), false, "not at the first sign")
    T.eq(client:auto_join(1.2, false), false, "an interruption starts over")
    T.eq(client:auto_join(1.3, true), false, "...")
    T.eq(client:auto_join(1.9, true), true, "the host keeps playing: join")
    T.eq(client.join_running, true, "the join of a game in progress runs")
    T.eq(client.screen, nil, "the lobby gave way")
    T.eq(client.counters.auto_joins, 1, "counted")
    local told = false
    for _, n in ipairs(notes.c) do
        if n.text:find("ya está jugando") then told = true end
    end
    T.check(told, "the player is told")
    T.eq(client:auto_join(3, true), false, "once")
    -- Never for the host, never with the setting off, never while a lobby start runs.
    host:open(Lobby.SCREEN.LOBBY)
    T.eq(host:auto_join(0, true), false, "host")
    T.eq(host:auto_join(1, true), false, "host")
    local _, c2 = pair(nil, { auto_load_on_join = false })
    c2:open(Lobby.SCREEN.LOBBY)
    c2:auto_join(0, true)
    T.eq(c2:auto_join(1, true), false, "switched off")
    T.eq(c2.screen, Lobby.SCREEN.LOBBY, "the lobby stays (the button joins)")
    local _, c3 = pair()
    c3:open(Lobby.SCREEN.OPTIONS, "menu")
    c3:auto_join(0, true)
    T.eq(c3:auto_join(1, true), false, "not over the options screen")
end)

T.run("start_points_for_a_late_join", function()
    T.eq(Lobby.head_key_of_id(21100), 6, "chapter 1-1: its own start, not the very beginning")
    T.eq(Lobby.head_key_of_id(21200), 7, "chapter 2")
    T.eq(Lobby.head_key_of_id(22200), 10, "chapter 5")
    T.eq(Lobby.head_key_of_id(25400), 21, "chapter 16")
    T.eq(Lobby.head_key_of_id(20100), 4, "the drive")
    T.eq(Lobby.head_key_of_id(21000), 5, "the first house")
    T.eq(Lobby.head_key_of_id(99999), nil, "unknown")
    T.eq(Lobby.head_key_of_id(nil), nil, "none")
end)

-------------------------------------------------------------------------------
-- Two sessions end to end (fake wire, fake games with a main menu)
-------------------------------------------------------------------------------

local function fake_net()
    local net = { inbox = {}, sent = {}, st = "idle", r = "none" }
    function net.state() return net.st end
    function net.role() return net.r end
    function net.poll()
        local out = net.inbox
        net.inbox = {}
        return out
    end
    function net.send(b, reliable)
        if net.st ~= "connected" then return false, "not connected" end
        net.sent[#net.sent + 1] = b
        return true
    end
    function net.stats() return { state = net.st, peer_name = net.peer_name, rtt_ms = 1, peer = "127.0.0.1:1" } end
    function net.host() net.st = "listening" net.r = "host" return true end
    function net.join() net.st = "connecting" net.r = "client" return true end
    function net.stop() net.st = "idle" net.r = "none" end
    return net
end

local function fake_game(name)
    local g = { name = name, pos = { x = 0, y = 0, z = 0 }, chapter = 21100, stage = 40200, ctx_id = 1, keys = {},
        in_menu = true, loading = true, saves = {}, ts = 1, starts = {} }
    function g:read_player_state()
        if self.loading then return nil end
        return { pos = self.pos, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 10, max_hp = 10, chapter = self.chapter,
            stage = self.stage, id = self.ctx_id }
    end
    function g:list_enemies() return {} end
    function g:area_name() return tostring(self.chapter) end
    function g:is_key_down(vk) return self.keys[vk] == true end
    function g:window_focused() return true end
    function g:get_time_scale() return self.ts end
    function g:set_time_scale(v) self.ts = v return true end
    function g:install_menu_hooks(h) self.menu_h = h end
    function g:menu_tick(want) self.want = want end
    function g:menu_status() return { open = self.in_menu, phase = 10, ready = self.in_menu } end
    function g:gui_commands() local c = self.cmds or {} self.cmds = {} return c end
    function g:menu_start_new(key, difficulty)
        self.starts[#self.starts + 1] = { kind = "new", key = key, difficulty = difficulty }
        self.in_menu = false
        return true
    end
    function g:menu_continue(slot)
        if self.saves[slot] == nil then return nil, "empty" end
        self.starts[#self.starts + 1] = { kind = "continue", slot = slot }
        self.in_menu = false
        return true
    end
    function g:save_exists(slot) return self.saves[slot] ~= nil end
    function g:save_slot_info(slot)
        local s = self.saves[slot]
        if s == nil then return { empty = true } end
        return { empty = false, chapter_id = s.chapter, difficulty = 20, count = 3 }
    end
    function g:loading_screen() return false end
    function g:weapon_name(wp) return "Arma" .. wp end
    function g:give_loadout(weapons)
        self.given = weapons
        return { given = { "A", "B" }, failed = 0, full = 0 }
    end
    return g
end

local function fake_world(game)
    local w = { game = game, flags = {} }
    function w:install_hooks() end
    function w:update() end
    function w:location()
        local g = self.game
        if g.loading then return nil end
        return { chapter = g.chapter, stage = g.stage, pos = g.pos, yaw = 0, playable = true, loading = false }
    end
    function w:flag_hooks_active() return true end
    function w:flag_words_snapshot() return nil end
    function w:gimmicks_snapshot() return nil end
    function w:objects_scan() return nil end
    function w:cutscene_playing() return false end
    function w:cutscene_done() return false end
    function w:preload_stage() return true end
    function w:warp(stage, pos) self.game.pos = pos return true end
    function w:arm_chapter_switch(c) self.armed = c return true end
    function w:disarm_chapter_switch() self.armed = nil end
    return w
end

local function make_session(name, clock, settings)
    local net = fake_net()
    local s = Config.load(nil)
    s.player_name = name
    for k, v in pairs(settings or {}) do s[k] = v end
    local game = fake_game(name)
    local world = fake_world(game)
    local session = Session.new({ net = net, game = game, world = world, clock = function() return clock.t end, settings = s })
    return session, net, game, world
end

T.run("two_sessions_menu_lobby_ready_start_and_load_together", function()
    local clock = { t = 0 }
    local hs, hnet, hgame = make_session("Leon", clock)
    local cs, cnet, cgame, cworld = make_session("Ada", clock)
    T.check(hgame.menu_h ~= nil, "menu hooks installed")
    T.eq(hgame.menu_h.labels[Lobby.ACTION.MULTIPLAYER], "Multijugador", "our entry's label")
    local function deliver()
        for _ = 1, 3 do
            for _, b in ipairs(hnet.sent) do cnet.inbox[#cnet.inbox + 1] = { type = "message", data = b } end
            for _, b in ipairs(cnet.sent) do hnet.inbox[#hnet.inbox + 1] = { type = "message", data = b } end
            hnet.sent, cnet.sent = {}, {}
        end
    end
    local function frame(dt)
        clock.t = clock.t + (dt or 0.1)
        hs:update()
        cs:update()
        deliver()
    end
    -- Host: Multijugador -> Host Game.
    hgame.menu_h.on_decide(Lobby.ACTION.MULTIPLAYER)
    T.eq(hs.lobby.menu_mode, "mp", "section")
    hgame.menu_h.on_decide(Lobby.ACTION.HOST)
    T.eq(hs.role, "host", "hosting")
    T.eq(hs.lobby.screen, Lobby.SCREEN.LOBBY, "lobby open")
    frame()
    T.eq(hgame.want.covered, true, "the game's menu is hidden under the lobby")
    -- Client: Multijugador -> Join Game -> connect.
    cgame.menu_h.on_decide(Lobby.ACTION.MULTIPLAYER)
    cgame.menu_h.on_decide(Lobby.ACTION.JOIN)
    T.eq(cs.lobby.screen, Lobby.SCREEN.JOIN, "join screen")
    cs:queue("join", "127.0.0.1")
    frame()
    T.eq(cs.role, "client", "joining")
    hnet.st, cnet.st = "connected", "connected"
    hnet.peer_name, cnet.peer_name = "Ada", "Leon"
    hnet.inbox[#hnet.inbox + 1] = { type = "connected", name = "Ada", peer = "127.0.0.1:2" }
    cnet.inbox[#cnet.inbox + 1] = { type = "connected", name = "Leon", peer = "127.0.0.1:1" }
    for _ = 1, 30 do frame() end
    T.eq(cs.lobby.screen, Lobby.SCREEN.LOBBY, "the client is in the host's lobby")
    T.check(cs.lobby:view() ~= nil, "with the host's choices")
    T.check(hs.lobby.partner ~= nil and hs.lobby.partner.in_lobby, "the host sees the client in the lobby")
    -- Ready and start (a new game at chapter 3).
    hs.lobby.cfg.chapter = 3
    hs.lobby:set_ready(true)
    cs.lobby:set_ready(true)
    frame()
    frame()
    T.eq(hs.lobby:request_start(clock.t), true, "the host starts")
    for _ = 1, 3 do frame() end
    T.eq(#hgame.starts, 1, "the host's game started")
    T.eq(hgame.starts[1].key, 8, "chapter 3's start point")
    T.eq(#cgame.starts, 1, "the client's game started")
    T.eq(cgame.starts[1].key, 8, "the same")
    T.eq(cs.join_travel_pending, false, "a fresh game: nothing of the host's to take over")
    T.eq(hs.save_sync.host_slot, 17, "the host's saves go to its co-op file")
    -- The host's map loads first: held (time scale 0) until the client's has.
    hgame.loading = false
    for _ = 1, 15 do frame() end
    T.eq(hgame.ts, 0, "host held")
    T.eq(cgame.ts, 1, "client still loading")
    cgame.loading = false
    for _ = 1, 20 do frame() end
    T.eq(hgame.ts, 1, "host released")
    T.eq(cgame.ts, 1, "client runs")
    T.eq(hs.lobby.start.why, "go", "together")
    T.eq(cs.lobby.start.why, "go", "together (client)")
    -- The client's loadout.
    cs.lobby.start.loadout = 3
    cs.lobby.start.loadout_pending = true
    for _ = 1, 25 do frame() end
    T.check(cgame.given ~= nil and #cgame.given == 2, "the client's loadout given")
    T.eq(hgame.given, nil, "the host chose none")
    T.eq(cworld.armed, nil, "no chapter switch left armed")
end)

-- A host already playing (it hosted from the REFramework menu, or its lobby game runs): a
-- client that joins from Multijugador -> Join Game goes straight into the host's game - no
-- button, no save to pick - and comes back at the host's place.
local function late_join(client_saves, settings)
    local clock = { t = 0 }
    local hs, hnet, hgame = make_session("Leon", clock)
    local cs, cnet, cgame, cworld = make_session("Ada", clock, settings)
    for slot, chapter in pairs(client_saves or {}) do cgame.saves[slot] = { chapter = chapter } end
    function cgame:any_save() return next(self.saves) ~= nil end
    cworld.spawns = 0
    function cworld:arm_spawn() self.spawns = self.spawns + 1 return true end
    function cworld:spawn_armed() return false end
    -- The host plays in chapter 5 (22200).
    hgame.in_menu, hgame.loading, hgame.chapter, hgame.stage = false, false, 22200, 46100
    hgame.pos = { x = 300, y = -7, z = -10 }
    hs:queue("host")
    local function deliver()
        for _ = 1, 3 do
            for _, b in ipairs(hnet.sent) do cnet.inbox[#cnet.inbox + 1] = { type = "message", data = b } end
            for _, b in ipairs(cnet.sent) do hnet.inbox[#hnet.inbox + 1] = { type = "message", data = b } end
            hnet.sent, cnet.sent = {}, {}
        end
    end
    local function frame(dt)
        clock.t = clock.t + (dt or 0.1)
        hs:update()
        cs:update()
        deliver()
    end
    frame()
    T.eq(hs.role, "host", "hosting")
    -- Client: Multijugador -> Join Game -> connect.
    cgame.menu_h.on_decide(Lobby.ACTION.MULTIPLAYER)
    cgame.menu_h.on_decide(Lobby.ACTION.JOIN)
    cs:queue("join", "127.0.0.1")
    frame()
    hnet.st, cnet.st = "connected", "connected"
    hnet.peer_name, cnet.peer_name = "Ada", "Leon"
    hnet.inbox[#hnet.inbox + 1] = { type = "connected", name = "Ada", peer = "127.0.0.1:2" }
    cnet.inbox[#cnet.inbox + 1] = { type = "connected", name = "Leon", peer = "127.0.0.1:1" }
    for _ = 1, 20 do frame() end
    return { clock = clock, hs = hs, cs = cs, cgame = cgame, cworld = cworld, frame = frame }
end

T.run("a_late_client_goes_straight_into_the_hosts_game", function()
    local j = late_join({ [3] = 21100 })
    local cs, cgame, cworld = j.cs, j.cgame, j.cworld
    T.eq(cs.lobby.screen, nil, "no lobby to wait in: the host is playing")
    T.eq(cs.lobby.join_running, true, "the join of the game in progress runs on its own")
    T.check(cs.join_travel_pending, "the join waits for the load")
    -- The game's main menu asks the session every frame: Continue, into the host's place.
    T.eq(cs:on_menu("menu"), true, "Continue now")
    T.eq(cworld.armed, 22200, "into the host's chapter")
    T.eq(cworld.spawns, 1, "at the host's place")
    T.eq(cs:on_menu("menu"), false, "once")
    T.eq(#cgame.starts, 0, "no new game")
    -- The host's place is the one its game reported while playing.
    local spot = cs:host_spawn_spot()
    T.check(spot ~= nil and spot.stage == 46100 and spot.chapter == 22200, "the host's stage and chapter")
    T.near(spot.pos.x, 300, 1e-6, "and position")
end)

T.run("a_late_client_without_a_save_starts_a_new_game_in_the_hosts_chapter", function()
    local j = late_join({})
    local cs, cgame, cworld = j.cs, j.cgame, j.cworld
    T.eq(cs.lobby.screen, nil, "joined at once")
    T.eq(cs:on_menu("menu"), false, "nothing to Continue")
    j.frame()
    T.eq(#cgame.starts, 1, "a new game")
    T.eq(cgame.starts[1].kind, "new", "...")
    T.eq(cgame.starts[1].key, 10, "at the start of the host's chapter part (5)")
    T.eq(cgame.starts[1].difficulty, 20, "standard difficulty")
    T.eq(cworld.spawns, 2, "at the host's place (armed for the start too)")
    T.check(cs.join_travel_pending, "then the host's world and the host, once in game")
end)

T.run("with_the_automatic_load_off_the_lobby_keeps_its_button", function()
    local j = late_join({ [3] = 21100 }, { auto_load_on_join = false })
    T.eq(j.cs.lobby.screen, Lobby.SCREEN.LOBBY, "the lobby stays")
    T.eq(j.cs.lobby.join_running, false, "nothing runs on its own")
end)

T.run("session_continue_start_loads_the_coop_slots", function()
    local clock = { t = 0 }
    local hs, hnet, hgame = make_session("Leon", clock)
    local cs, cnet, cgame, cworld = make_session("Ada", clock)
    hgame.saves[18] = { chapter = 23200 }
    local function deliver()
        for _ = 1, 3 do
            for _, b in ipairs(hnet.sent) do cnet.inbox[#cnet.inbox + 1] = { type = "message", data = b } end
            for _, b in ipairs(cnet.sent) do hnet.inbox[#hnet.inbox + 1] = { type = "message", data = b } end
            hnet.sent, cnet.sent = {}, {}
        end
    end
    local function frame()
        clock.t = clock.t + 0.1
        hs:update()
        cs:update()
        deliver()
    end
    hgame.menu_h.on_decide(Lobby.ACTION.HOST)
    cs:queue("join", "127.0.0.1")
    frame()
    hnet.st, cnet.st = "connected", "connected"
    hnet.inbox[#hnet.inbox + 1] = { type = "connected", name = "Ada", peer = "x" }
    cnet.inbox[#cnet.inbox + 1] = { type = "connected", name = "Leon", peer = "y" }
    for _ = 1, 30 do frame() end
    hs.lobby:cycle_file(1) -- file 2 = slot 18 (a save in chapter 8)
    for _ = 1, 25 do frame() end
    T.eq(hs.lobby:mode(), P.LOBBY_MODE.CONTINUE, "continues the co-op save")
    hs.lobby:set_ready(true)
    cs.lobby:set_ready(true)
    frame()
    frame()
    T.eq(hs.lobby:request_start(clock.t), true, "start")
    for _ = 1, 3 do frame() end
    T.eq(hgame.starts[1].kind, "continue", "host continues")
    T.eq(hgame.starts[1].slot, 18, "its co-op file")
    T.eq(hs.save_sync:continue_slot(clock.t), 18, "Continue loads that slot")
    T.eq(cgame.starts[1].kind, "new", "the client has no co-op save: a new game...")
    T.eq(cgame.starts[1].key, 13, "...in the host's chapter (8)")
    T.eq(cworld.armed, 23200, "a save it loads would go into the host's chapter")
    T.eq(cs.join_travel_pending, true, "then it joins the host (world, warp)")
end)

T.finish()
