-- End to end for the shared world: the real entry script (re4coop.lua) hosts against the
-- mocked RE4 (with its scenario flags, gimmick table, pauses, cutscenes, breakables and
-- warps), and a second Session joins as the client with a fake game and world, over real
-- UDP on 127.0.0.1.
local T = require("testlib")
local mock = require("mock_reframework")

local PORT = 47000 + (os.time() % 3000)
local G_DOOR = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"   -- a door the host opens
local G_OBJ = "11111111-2222-3333-4444-555555555555"    -- an objective the client completes
local CROW = "c0c0c0c0-0000-0000-0000-000000000001"
local CRATE = "c0c0c0c0-0000-0000-0000-000000000002"

local world = mock.install()
world.player = mock.make_player({ x = 0, y = 0, z = 0 })
world.stage, world.chapter = 40200, 21100
mock.add_flag(G_DOOR, 1, 3)
mock.add_flag(G_OBJ, 2, 7)
local ganado = mock.make_character("chainsaw.Ch1c0z0Context", { x = 20, y = 0, z = 0 }, 100)
world.enemies = { ganado }
local crow = mock.make_object("chainsaw.GmCrow", CROW, { x = 3, y = 0, z = 0 }, 0)
local crate = mock.make_object("chainsaw.GmWoodBox", CRATE, { x = 4, y = 0, z = 0 }, 0)
mock.set_gimmick({ category = 1, kind = 0, group = 40200, index = 5 }, { 0, 0 }, { { id = 1, done = 0 } })
mock.files["re4coop.json"] = { player_name = "HostLeon", port = PORT }

local function run_entry_script()
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    dofile(TEST_ROOT .. "/lua/reframework/autorun/re4coop.lua")
end

run_entry_script()

local P = require("re4coop.protocol")
local Session = require("re4coop.session")
local Config = require("re4coop.config")

local function wrap(obj)
    return setmetatable({}, { __index = function(_, k)
        local f = obj[k]
        if f == nil then return re4coop_net[k] end
        return function(...) return f(obj, ...) end
    end })
end

-------------------------------------------------------------------------------
-- The client's game: a player far from the host, one enemy, a world with the same objects.
-------------------------------------------------------------------------------

local client_game = {
    player = { pos = { x = 80, y = 0, z = 0 }, chapter = 21100, stage = 40200 },
    enemies = { { id = 1, kind = "chainsaw.Ch1c0z0Context", pos = { x = 20.3, y = 0, z = 0.2 }, yaw = 0, hp = 100,
        max_hp = 100, alive = true } },
    ai_off = {},
    transforms = 0,
}
function client_game:read_player_state()
    local p = self.player
    return { pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 1000,
        max_hp = 1000, chapter = p.chapter, stage = p.stage, cutscene = self.world.playing ~= nil, id = 1 }
end
function client_game:area_name() return tostring(self.player.chapter) end
function client_game:list_enemies()
    local out = {}
    for i, e in ipairs(self.enemies) do
        out[i] = { id = e.id, kind = e.kind, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }, yaw = e.yaw,
            hp = e.hp, max_hp = e.max_hp, alive = e.alive }
    end
    return out
end
function client_game:enemy_set_hp(id, hp) self.enemies[id].hp = hp return true end
function client_game:enemy_kill(id) self.enemies[id].hp, self.enemies[id].alive = 0, false return true end
function client_game:enemy_set_position() return true end
function client_game:enemy_set_transform(id, pos, yaw)
    local e = self.enemies[id]
    e.pos, e.yaw = { x = pos.x, y = pos.y, z = pos.z }, yaw
    self.transforms = self.transforms + 1
    return true
end
function client_game:enemy_set_ai(id, on) self.ai_off[id] = (not on) or nil return true end
function client_game:teleport_player(pos) self.player.pos = pos return true end
function client_game:is_key_down() return false end

local client_world = { flags = {}, flag_sets = {}, full_groups = nil, gimmicks = {}, objects = {}, applied = {},
    played = {}, warps = {}, playing = nil }
client_game.world = client_world
function client_world:install_hooks(cb) self.cb = cb end
function client_world:update() end
function client_world:location()
    local p = client_game.player
    return { chapter = p.chapter, stage = p.stage, pos = p.pos, yaw = 0, playable = true, loading = false }
end
function client_world:flag_set(g, v) self.flags[g] = v self.flag_sets[#self.flag_sets + 1] = g return true end
function client_world:flag_check(g) return self.flags[g] or false end
function client_world:flag_hooks_active() return true end
function client_world:flag_words_snapshot() return { Main = { 0, 0, 0, 0 }, Chapter = { 0, 0 } } end
function client_world:flag_words_apply() return true end
function client_world:flag_words_apply_full(groups) self.full_groups = groups return true end
function client_world:gimmicks_snapshot()
    local out = {}
    for k, g in pairs(self.gimmicks) do out[k] = g end
    return out
end
function client_world:gimmicks_apply(items)
    for _, it in ipairs(items) do self.gimmicks[P.ctx_key(it.ctx)] = it end
    return true
end
function client_world:objects_scan()
    local out = {}
    for g, o in pairs(self.objects) do
        out[g] = { kind = o.kind, pos = o.pos, routine = o.routine, terminal = o.terminal }
    end
    return { stage = client_game.player.stage, objects = out }
end
function client_world:object_apply(g, event, value)
    if self.objects[g] == nil then return "missing" end
    self.applied[#self.applied + 1] = { guid = g, event = event, value = value }
    self.objects[g].terminal = true
    return "done"
end
function client_world:cutscene_playing() return self.playing end
function client_world:cutscene_play(id, method)
    self.played[#self.played + 1] = { id = id, method = method }
    self.playing = id
    return true
end
function client_world:preload_stage() return true end
function client_world:warp(stage, pos)
    self.warps[#self.warps + 1] = { stage = stage, pos = pos }
    client_game.player.pos = { x = pos.x, y = pos.y, z = pos.z }
    return true
end
function client_world:arm_chapter_switch() return true end
function client_world:disarm_chapter_switch() end
function client_world:trigger_reload() return true end
client_world.objects[CROW] = { kind = "chainsaw.GmCrow", pos = { x = 3, y = 0, z = 0 }, routine = 0, terminal = false }
client_world.objects[CRATE] = { kind = "chainsaw.GmWoodBox", pos = { x = 4, y = 0, z = 0 }, routine = 0, terminal = false }

local client_settings = Config.load(nil)
client_settings.player_name = "ClientLeon"
client_settings.port = PORT
local client_net_obj = re4coop_net.new_session()
local client = Session.new({ net = wrap(client_net_obj), game = client_game, world = client_world,
    clock = re4coop_net.time, settings = client_settings })

local function step()
    mock.run_frame()
    client:update()
end

local function host_messages_contain(pattern)
    for _, s in ipairs(mock.logs) do
        if s:find(pattern) then return true end
    end
    return false
end

T.run("hosting_stops_menus_pausing", function()
    T.eq(mock.pause_freezes(1), true, "the inventory pauses before")
    mock.press["Host game"] = true
    mock.run_frame()
    T.eq(re4coop_net.state(), "listening", "hosting")
    T.eq(mock.pause_freezes(1), false, "inventory no longer pauses the world")
    T.eq(mock.pause_freezes(2), false, "nor the map")
    T.eq(mock.pause_freezes(3), false, "nor the pause menu")
    T.eq(mock.pause_freezes(5), true, "cutscenes still pause")
end)

T.run("client_joins_takes_the_hosts_world_and_appears_next_to_the_host", function()
    -- The host had already opened a door before the client joined.
    mock.game_set_flag(G_DOOR, true)
    T.check(client:join("127.0.0.1:" .. PORT), "join started")
    local ok = T.wait_until(function()
        return client.travel ~= nil and client.travel.result == "arrived"
    end, step, 10)
    T.check(ok, "client travelled to the host (" .. tostring(client.travel and client.travel.state) .. ")")
    T.check(client_world.full_groups ~= nil, "full flag state received")
    local main
    for _, g in ipairs(client_world.full_groups or {}) do
        if g.name == "Main" then main = g.words end
    end
    T.check(main ~= nil and (main[1] & (1 << 3)) ~= 0, "with the door the host opened")
    T.check(client_world.gimmicks["1:0:40200:5"] ~= nil, "gimmick table received")
    T.near(client_game.player.pos.x, 0, 1.5, "client stands next to the host")
    T.check(host_messages_contain("Sent the world state to ClientLeon"), "host logged the transfer")
end)

T.run("flags_cross_both_ways", function()
    client_world.flags[G_DOOR] = true -- what the full copy gave the client's game
    mock.game_set_flag(G_DOOR, false)  -- the host's game closes the door again
    local ok = T.wait_until(function() return client_world.flags[G_DOOR] == false end, step, 5)
    T.check(ok, "the host's change reached the client's game")
    client_world.cb.on_flag(G_OBJ, true) -- the client's game completes an objective
    ok = T.wait_until(function() return mock.flag_value(G_OBJ) end, step, 5)
    T.check(ok, "the client's objective is set in the host's game (requestSetFlag)")
end)

T.run("gimmicks_cross_as_soon_as_the_game_announces_them", function()
    mock.set_gimmick({ category = 1, kind = 0, group = 40200, index = 5 }, { 1, 0 }, { { id = 1, done = 1 } }, true)
    local ok = T.wait_until(function()
        local g = client_world.gimmicks["1:0:40200:5"]
        return g ~= nil and g.triggers[1] and g.triggers[1].done == 1
    end, step, 5)
    T.check(ok, "the host's lever reached the client")
end)

T.run("breakables_and_animals_cross", function()
    crow.__fields._Routine = 2 -- the host shoots the crow (Dead)
    local ok = T.wait_until(function()
        for _, a in ipairs(client_world.applied) do
            if a.guid == CROW then return true end
        end
        return false
    end, step, 5)
    T.check(ok, "the crow died in the client's game")
    client_world.objects[CRATE].routine, client_world.objects[CRATE].terminal = 2, true -- the client breaks the crate
    ok = T.wait_until(function() return crate.__fields._Routine == 2 end, step, 5)
    T.check(ok, "the crate broke in the host's game (same terminal routine)")
end)

T.run("cutscene_plays_for_both", function()
    mock.start_cutscene(20130) -- the host walks into a cutscene trigger
    local ok = T.wait_until(function() return #client_world.played > 0 end, step, 5)
    T.check(ok, "the client's game played it")
    T.eq(client_world.played[1] and client_world.played[1].id, 20130, "the same cutscene")
    -- Both are in it, so the transition gate does not hold the host.
    for _ = 1, 30 do step() end
    T.eq(world.time_scale, 1.0, "host not frozen while the client watches too")
    mock.end_cutscene()
    client_world.playing = nil
    for _ = 1, 10 do step() end
end)

T.run("enemy_near_the_client_is_run_by_the_client", function()
    client_game.player.pos = { x = 21, y = 0, z = 1 } -- the client walks up to the Ganado
    local ok = T.wait_until(function()
        return client.enemy_sync ~= nil and client.enemy_sync:summary().client_owned == 1
    end, step, 6)
    T.check(ok, "the Ganado is handed over to the client")
    ok = T.wait_until(function() return client_game.ai_off[1] == nil end, step, 2)
    T.check(ok, "its AI runs in the client's game (it attacks the client)")
    ok = T.wait_until(function() return ganado.head.update_self == false end, step, 3)
    T.check(ok, "the host's copy has its AI switched off")
    client_game.enemies[1].pos = { x = 23, y = 0, z = 2 } -- the client's AI moves it
    ok = T.wait_until(function() return math.abs(ganado.pos.x - 23) < 0.05 end, step, 3)
    T.check(ok, "the host's copy follows (x=" .. ganado.pos.x .. ")")
    client_game.player.pos = { x = 80, y = 0, z = 0 }
    world.player.pos.x, world.player.pos.z = 22, 2 -- the host walks over, the client leaves
    ok = T.wait_until(function() return ganado.head.update_self == true end, step, 6)
    T.check(ok, "back to the host, AI on")
    ok = T.wait_until(function() return client_game.ai_off[1] == true end, step, 3)
    T.check(ok, "the client's copy now follows the host's")
end)

T.run("reset_scripts_keeps_the_session_and_no_pause", function()
    for _, cb in ipairs(mock.callbacks.reset) do cb() end
    T.eq(mock.pause_freezes(1), true, "pauses restored while the script is gone")
    for _, td in pairs(mock.classes) do
        for _, m in pairs(td.methods) do m.hooks = nil end
    end
    mock.hooks = {}
    mock.callbacks.entry, mock.callbacks.frame, mock.callbacks.ui = {}, {}, {}
    mock.callbacks.config_save, mock.callbacks.reset = {}, {}
    run_entry_script()
    for _ = 1, 20 do step() end
    T.eq(re4coop_net.state(), "connected", "still connected")
    T.eq(mock.pause_freezes(1), false, "no-pause back on")
    mock.game_set_flag(G_DOOR, true)
    local ok = T.wait_until(function() return client_world.flags[G_DOOR] == true end, step, 5)
    T.check(ok, "flag hooks reinstalled")
end)

T.run("stop_hosting_restores_pauses", function()
    client:leave()
    T.wait_until(function() return host_messages_contain("ClientLeon disconnected") end, step, 5)
    mock.press["Stop hosting"] = true
    mock.run_frame()
    T.eq(re4coop_net.state(), "idle", "stopped")
    T.eq(mock.pause_freezes(1), true, "the inventory pauses again")
    T.eq(ganado.head.update_self ~= false, true, "no enemy left without its AI")
end)

T.finish()
