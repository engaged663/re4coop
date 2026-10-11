-- Session behaviour of the shared world that the end-to-end test does not reach: messages
-- that arrive while the game loop is not running, joining (chapter switch, world state,
-- warp), following the host into the next chapter, reloads, cutscenes, the no-pause switch.
local T = require("testlib")
local P = require("re4coop.protocol")
local Session = require("re4coop.session")
local Config = require("re4coop.config")

local function fake_net(role)
    local net = { inbox = {}, sent = {}, st = "connected", r = role }
    function net.state() return net.st end
    function net.role() return net.r end
    function net.poll()
        local out = net.inbox
        net.inbox = {}
        return out
    end
    function net.send(b, reliable) net.sent[#net.sent + 1] = { data = b, reliable = reliable } return true end
    function net.stats() return { state = net.st, peer_name = "Host", rtt_ms = 1 } end
    function net.host() net.st = "listening" net.r = "host" return true end
    function net.join() net.st = "connecting" net.r = "client" return true end
    function net.stop() net.st = "idle" net.r = "none" end
    function net.push(data) net.inbox[#net.inbox + 1] = { type = "message", data = data } end
    function net.sent_types()
        local types = {}
        for _, m in ipairs(net.sent) do types[m.data:byte(1)] = (types[m.data:byte(1)] or 0) + 1 end
        return types
    end
    return net
end

local function fake_game()
    local g = { pos = { x = 0, y = 0, z = 0 }, chapter = 21100, stage = 40200, ctx_id = 1, keys = {}, teleports = {},
        ai_restored = 0 }
    function g:read_player_state()
        if self.loading then return nil end
        return { pos = self.pos, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 10, max_hp = 10, chapter = self.chapter,
            stage = self.stage, id = self.ctx_id }
    end
    function g:list_enemies() return {} end
    function g:area_name() return tostring(self.chapter) end
    function g:teleport_player(pos) self.teleports[#self.teleports + 1] = pos self.pos = pos return true end
    function g:is_key_down(vk) return self.keys[vk] == true end
    function g:restore_enemy_ai() self.ai_restored = self.ai_restored + 1 end
    return g
end

local function fake_world(game)
    local w = { flags = {}, armed = nil, reloads = 0, played = {}, game = game }
    function w:install_hooks(cb) self.cb = cb end
    function w:update() end
    function w:location()
        local g = self.game
        if g.loading then return { chapter = g.chapter, loading = true, playable = false } end
        return { chapter = g.chapter, stage = g.stage, pos = g.pos, yaw = 0, playable = true, loading = false }
    end
    function w:flag_set(guid, v) self.flags[guid] = v return true end
    function w:flag_check(guid) return self.flags[guid] or false end
    function w:flag_hooks_active() return true end
    function w:flag_words_snapshot() return nil end
    function w:gimmicks_snapshot() return nil end
    function w:objects_scan() return nil end
    function w:cutscene_playing() return self.playing end
    function w:cutscene_play(id, method)
        self.played[#self.played + 1] = { id = id, method = method }
        self.playing = id
        return true
    end
    function w:preload_stage() return true end
    function w:warp(stage, pos)
        self.game.stage = stage or self.game.stage
        self.game.pos = pos
        return true
    end
    function w:arm_chapter_switch(c) self.armed = c return true end
    function w:disarm_chapter_switch() self.armed = nil end
    function w:trigger_reload() self.reloads = self.reloads + 1 return true end
    return w
end

local function fake_pause()
    local p = {}
    function p:set_active(active, mode, aggressive) self.active, self.mode, self.aggressive = active, mode, aggressive end
    function p:update() end
    function p:status() return { active = self.active, patched = 0, names = {} } end
    return p
end

local function make(role, opts)
    opts = opts or {}
    local clock = { t = 0 }
    local net = fake_net(role)
    local settings = Config.load(nil)
    for k, v in pairs(opts.settings or {}) do settings[k] = v end
    local game = fake_game()
    local world = opts.world or fake_world(game)
    world.game = game
    local s = Session.new({ net = net, game = game, world = world, pause = opts.pause,
        clock = function() return clock.t end, settings = settings })
    s.role = role
    s:make_syncs()
    s.partner_connected = true
    return s, net, clock, game, world
end

local function player_msg(t, chapter, stage, pos, flags)
    return P.encode_player({ time = t, pos = pos or { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 },
        hp = 10, max_hp = 10, chapter = chapter, stage = stage, flags = flags or 0 })
end

local function told(s, pattern)
    for _, m in ipairs(s.messages) do
        if m.text:find(pattern) then return true end
    end
    return false
end

T.run("world_messages_wait_for_the_game_loop", function()
    local s, net, clock, _, world = make("client")
    local g = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"
    net.push(P.encode_flags({ { guid = g, value = true } })[1])
    net.push(P.encode_chat("still here"))
    net.push(P.encode_enemy_snapshots(1, {})[1])
    s:update_network_only() -- loading screen: the game loop is not running
    T.check(world.flags[g] == nil, "flag not applied outside the game loop")
    T.eq(#s.deferred, 1, "kept for later (enemy snapshots are not: they are resent)")
    T.eq(s.messages[#s.messages].text, "Host: still here", "chat handled right away")
    clock.t = 1
    s:update()
    T.eq(world.flags[g], true, "applied on the next game tick")
    T.eq(#s.deferred, 0, "queue drained")
end)

T.run("joining_client_takes_the_hosts_world_then_warps", function()
    local s, net, clock, game = make("client")
    s.join_travel_pending = true
    clock.t = 1
    net.push(player_msg(1, 21100, 40200, { x = 50, y = 0, z = 50 }))
    for i = 1, 5 do
        clock.t = 1 + i * 0.1
        s:update()
    end
    T.eq(net.sent_types()[P.T.WORLD_REQUEST], 1, "WORLD_REQUEST sent")
    T.eq(s.travel.state, "sync_wait", "travel waits for the host's world")
    T.eq(s:status().world_sync_pending, true, "shown as pending")
    net.push(P.encode_world_done(s.world_sync_pending, 7, 3, 4))
    for i = 1, 60 do
        clock.t = 2 + i * 0.1
        s:update()
    end
    T.eq(s.travel.result, "arrived", "then warps next to the host")
    T.near(game.pos.x, 50, 1e-6, "at the host's position")
    T.check(told(s, "World synchronised"), "player told")
end)

T.run("joining_from_another_chapter_loads_the_hosts", function()
    local s, net, clock, game, world = make("client")
    game.chapter = 23100
    s.join_travel_pending = true
    clock.t = 1
    net.push(player_msg(1, 21200, 41200, { x = 5, y = 0, z = 5 }))
    for i = 1, 5 do
        clock.t = 1 + i * 0.1
        s:update()
    end
    T.eq(world.armed, 21200, "the next load goes into the host's chapter")
    T.eq(world.reloads, 1, "and the reload is started (game over -> Continue)")
    -- The game reloads into the host's chapter.
    game.loading = true
    for i = 1, 10 do clock.t = 2 + i * 0.1 s:update() end
    game.loading, game.chapter, game.stage, game.ctx_id = false, 21200, 41200, 2
    for i = 1, 40 do
        clock.t = 3 + i * 0.1
        net.push(player_msg(clock.t, 21200, 41200, { x = 5, y = 0, z = 5 }))
        s:update()
    end
    T.eq(net.sent_types()[P.T.WORLD_REQUEST], 1, "world requested once in the right chapter")
    T.eq(world.armed, nil, "switch disarmed once there")
end)

T.run("joining_from_the_title_screen_redirects_the_next_load", function()
    local s, net, _, _, world = make("client")
    s.join_travel_pending = true
    net.push(player_msg(1, 22300, 44000))
    s:update_network_only() -- title screen: only the render thread runs
    T.eq(world.armed, 22300, "whatever save is loaded next goes into the host's chapter")
end)

T.run("client_follows_the_host_into_the_next_chapter", function()
    local s, net, clock, _, world = make("client")
    for i = 1, 40 do
        clock.t = i * 0.5
        net.push(player_msg(clock.t, 21200, 44410, { x = 3, y = 0, z = 230 }))
        s:update()
        if i == 20 then T.eq(world.armed, nil, "not before the delay (time to get there yourself)") end
    end
    T.eq(world.armed, 21200, "chapter switch armed after the delay")
    T.eq(world.reloads, 1, "reload started")
    T.check(told(s, "next chapter"), "player told")
end)

T.run("client_never_follows_the_host_back", function()
    local s, net, clock, game, world = make("client")
    game.chapter = 21300
    for i = 1, 60 do
        clock.t = i * 0.5
        net.push(player_msg(clock.t, 21200, 44410, { x = 3, y = 0, z = 230 }))
        s:update()
    end
    T.eq(world.armed, nil, "an earlier host chapter does not pull us back")
end)

T.run("f6_loads_the_chapter_the_host_waits_in", function()
    local s, net, clock, game, world = make("client")
    game.keys = {}
    -- Host is held at the start of the next chapter (GATE_WAITING).
    for i = 1, 10 do
        clock.t = i * 0.1
        net.push(player_msg(clock.t, 21200, 41200, { x = 1, y = 0, z = 1 }, P.PLAYER_FLAGS.GATE_WAITING))
        s:update()
    end
    T.check(s.left_behind ~= nil and s.left_behind.can_follow, "prompt offers loading the chapter")
    game.keys[s.settings.teleport_key] = true
    clock.t = 1.1
    s:update()
    clock.t = 1.2
    s:update()
    T.eq(world.armed, 21200, "F6 loads the host's chapter")
    T.eq(world.reloads, 1, "through the reload")
end)

T.run("cross_stage_teleport_uses_the_games_warp", function()
    local s, net, clock, game = make("client")
    for i = 1, 5 do
        clock.t = i * 0.1
        net.push(player_msg(clock.t, 21100, 43310, { x = 65, y = 6, z = -78 }))
        s:update()
    end
    T.check(s:teleport_to_partner(), "teleport")
    T.eq(#game.teleports, 0, "not the plain transform teleport")
    for i = 1, 40 do
        clock.t = 1 + i * 0.1
        net.push(player_msg(clock.t, 21100, 43310, { x = 65, y = 6, z = -78 }))
        s:update()
    end
    T.eq(game.stage, 43310, "warped into the partner's stage")
    T.near(game.pos.x, 65, 1e-6, "next to them")
end)

T.run("partners_cutscene_plays_here_too", function()
    local s, net, clock, _, world = make("client")
    net.push(player_msg(0.1, 21100, 40200, { x = 2, y = 0, z = 0 }))
    net.push(P.encode_cutscene({ id = 20130, method = "requestPlay", chapter = 21100, stage = 40200,
        pos = { x = 2, y = 0, z = 0 }, flags = P.CUTSCENE_FLAGS.LOCAL_TRIGGER }))
    for i = 1, 5 do
        clock.t = i * 0.1
        s:update()
    end
    T.eq(world.played[1] and world.played[1].id, 20130, "same cutscene played")
    T.eq(world.played[1].method, "requestPlay", "through the same request")
    -- And ours goes to the partner.
    world.cb.on_cutscene(10157, "requestPlay")
    local m
    for _, x in ipairs(net.sent) do
        if x.data:byte(1) == P.T.CUTSCENE then m = P.decode(x.data) end
    end
    T.eq(m and m.id, 10157, "our cutscene announced")
end)

T.run("host_answers_world_requests", function()
    local game = fake_game()
    local world = fake_world(game)
    function world:flag_words_snapshot() return { Main = { 1, 2 } } end
    function world:gimmicks_snapshot()
        return { ["1:0:1:0"] = { ctx = { category = 1, kind = 0, group = 1, index = 0 }, attr = "\1", triggers = {}, acc = {} } }
    end
    local s, net = make("host", { world = world })
    net.push(P.encode_world_request(9, P.WORLD.FLAGS | P.WORLD.GIMMICKS | P.WORLD.OBJECTS))
    s:update()
    local types = net.sent_types()
    T.eq(types[P.T.FLAG_WORDS], 1, "flag state sent")
    T.eq(types[P.T.GIMMICKS], 1, "gimmick table sent")
    T.eq(types[P.T.WORLD_DONE], 1, "end marker sent")
    local done
    for _, m in ipairs(net.sent) do
        if m.data:byte(1) == P.T.WORLD_DONE then done = P.decode(m.data) end
    end
    T.eq(done.sync_id, 9, "same request id")
    T.eq(done.n_gimmicks, 1, "counts")
end)

T.run("host_reload_resets_old_deaths_on_the_client", function()
    local s, net, clock, game = make("host")
    for i = 1, 3 do clock.t = i * 0.1 s:update() end
    game.ctx_id = 99 -- a new player context: the game reloaded a checkpoint
    clock.t = 1
    s:update()
    local reset = false
    for _, m in ipairs(net.sent) do
        local d = P.decode(m.data)
        if d and d.type == P.T.ENEMY_DEAD and d.net_id == P.ENEMY_DEAD_RESET then reset = true end
    end
    T.check(reset, "client told to forget the host's earlier deaths")
end)

T.run("no_pause_follows_the_session", function()
    local pause = fake_pause()
    local s, net, _, game = make("host", { pause = pause })
    net.st = "listening"
    s:update()
    T.eq(pause.active, true, "on while hosting, even before the partner joins")
    T.eq(pause.mode, "menus", "default mode")
    s.settings.no_pause = false
    s:update()
    T.eq(pause.active, false, "the player can turn it off")
    s.settings.no_pause = true
    s:update()
    T.eq(pause.active, true, "and on again")
    s:leave()
    T.eq(pause.active, false, "off after leaving")
    T.eq(game.ai_restored, 1, "enemy AI restored")
end)

T.run("shutdown_restores_everything", function()
    local pause = fake_pause()
    local s, net, _, game, world = make("client", { pause = pause })
    net.st = "connected"
    s:update()
    world.armed = 21200
    s:shutdown()
    T.eq(pause.active, false, "pauses back to normal")
    T.eq(game.ai_restored, 1, "enemy AI back on")
    T.eq(world.armed, nil, "no chapter switch left armed")
end)

T.finish()
