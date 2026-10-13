-- End to end for the shared world: the real entry script (re4coop.lua) hosts against the
-- mocked RE4 (with its scenario flags, gimmick table, pauses, cutscenes, breakables and
-- warps), and a second Session joins as the client with a fake game and world, over real
-- UDP on 127.0.0.1.
local T = require("testlib")
local mock = require("mock_reframework")

local PORT = 41000 + (os.time() % 2000) -- below the Windows dynamic port range, apart from the other UDP test
local G_DOOR = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"   -- a door the host opens
local G_OBJ = "11111111-2222-3333-4444-555555555555"    -- an objective the client completes
local G_GATE = "22222222-2222-3333-4444-555555555555"   -- a gate the host opens later
local G_START = "33333333-2222-3333-4444-555555555555"  -- set when the church cutscene starts
local G_HOOK = "44444444-2222-3333-4444-555555555555"   -- set after "Reset Scripts"
local G_AREA = "dddddddd-0000-0000-0000-000000000001"   -- the GameObject of an event trigger the host walks into
local G_AREA2 = "dddddddd-0000-0000-0000-000000000002"  -- ...and of one the client walks into
local G_DOOR_GO = "d0d0d0d0-0000-0000-0000-000000000001" -- a door both games have
local CROW = "c0c0c0c0-0000-0000-0000-000000000001"
local CRATE = "c0c0c0c0-0000-0000-0000-000000000002"
local CROW2 = "c0c0c0c0-0000-0000-0000-000000000003" -- a crow both players see fly around

local world = mock.install()
-- The test runs in a console, not in the game's window: the game "has the focus".
re4coop_net.window_focused = function() return true end
world.player = mock.make_player({ x = 0, y = 0, z = 0 })
world.stage, world.chapter = 40200, 21100
mock.add_flag(G_DOOR, 1, 3)
mock.add_flag(G_OBJ, 2, 7)
mock.add_flag(G_GATE, 1, 4)
mock.add_flag(G_START, 1, 5)
mock.add_flag(G_HOOK, 1, 6)
local area_runs = 0
local area2 = mock.make_trigger(G_AREA2, "Area_ChurchSquare", { process = function() area_runs = area_runs + 1 end })
local ganado = mock.make_character("chainsaw.Ch1c0z0Context", { x = 20, y = 0, z = 0 }, 100)
-- Level enemies: a villager both games have (each placed it at another spawn point), and one
-- the host killed in an earlier session (eliminated in its save; alive in the client's).
local VILLAGER_ID = { category = 0, kind = 0, group = 12, index = 501 }
local KILLED_ID = { category = 0, kind = 0, group = 12, index = 502 }
-- ...and one alive in the host's world that the client's save had dead (its game never spawns it).
local SAVED_DEAD_ID = { category = 0, kind = 0, group = 12, index = 503 }
local villager = mock.make_character("chainsaw.Ch1c0z0Context", { x = 30, y = 0, z = 30 }, 100, VILLAGER_ID)
local survivor = mock.make_character("chainsaw.Ch1c0z0Context", { x = 12, y = 0, z = -8 }, 100, SAVED_DEAD_ID)
world.enemies = { ganado, villager, survivor }
mock.add_backup(KILLED_ID, true)
local crow = mock.make_object("chainsaw.GmCrow", CROW, { x = 3, y = 0, z = 0 }, 0)
local door = mock.make_door(G_DOOR_GO, { x = 2, y = 0, z = 2 })
local crate = mock.make_object("chainsaw.GmWoodBox", CRATE, { x = 4, y = 0, z = 0 }, 0)
local crow2 = mock.make_object("chainsaw.GmCrow", CROW2, { x = 5, y = 0, z = 5 }, 0)
mock.set_gimmick({ category = 1, kind = 0, group = 40200, index = 5 }, { 0, 0 }, { { id = 1, done = 0 } })
-- Experimental features this test covers are switched on (config_version 7: a current config).
mock.files["re4coop.json"] = { player_name = "HostLeon", port = PORT, config_version = 7, sync_cutscenes = true,
    exp_force_routine = true, ashley_cooldown = 1.0 }
-- Ashley, in the host's game next to its player.
local ashley = mock.make_ashley({ x = 3, y = 0, z = 0 }, 600)
world.partner = ashley

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
    enemies = {
        { id = 1, kind = "chainsaw.Ch1c0z0Context", pos = { x = 20.3, y = 0, z = 0.2 }, yaw = 0, hp = 100,
          max_hp = 100, alive = true },
        { id = 2, kind = "chainsaw.Ch1c0z0Context", uid = mock.context_code(VILLAGER_ID), pos = { x = 45, y = 0, z = 20 },
          yaw = 0, hp = 100, max_hp = 100, alive = true },
        { id = 3, kind = "chainsaw.Ch1c0z0Context", uid = mock.context_code(KILLED_ID), pos = { x = 50, y = 0, z = 0 },
          yaw = 0, hp = 100, max_hp = 100, alive = true },
    },
    puppet = {},
    transforms = 0,
    reload_id = 1,
}
function client_game:read_player_state()
    local p = self.player
    return { pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 1000,
        max_hp = 1000, chapter = p.chapter, stage = p.stage, cutscene = self.world.playing ~= nil, id = self.reload_id }
end
function client_game:area_name() return tostring(self.player.chapter) end
function client_game:list_enemies()
    local out = {}
    for _, e in ipairs(self.enemies) do
        if not e.erased then
            out[#out + 1] = { id = e.id, kind = e.kind, uid = e.uid, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
                rot = { x = 0, y = 0, z = 0, w = 1 }, hp = e.hp, max_hp = e.max_hp, alive = e.alive }
        end
    end
    return out
end
function client_game:enemy_set_hp(id, hp) self.enemies[id].hp = math.max(1, hp) return true end
-- Its spawn param validated and permitted: the game spawns it at its spawn point.
function client_game:enemy_revive(uid)
    self.revives = (self.revives or 0) + 1
    if uid ~= mock.context_code(SAVED_DEAD_ID) or self.enemies[4] ~= nil then return "missing" end
    self.enemies[4] = { id = 4, kind = "chainsaw.Ch1c0z0Context", uid = uid, pos = { x = 40, y = 0, z = -40 }, yaw = 0,
        hp = 100, max_hp = 100, alive = true }
    return "spawning"
end
function client_game:enemy_kill(id) self.enemies[id].hp, self.enemies[id].alive = 0, false return true end
function client_game:enemy_erase(id) self.enemies[id].erased = true return true end
function client_game:enemy_set_transform(id, pos, rot)
    local e = self.enemies[id]
    e.pos, e.rot = { x = pos.x, y = pos.y, z = pos.z }, rot
    self.transforms = self.transforms + 1
    return true
end
function client_game:enemy_set_puppet(id, on) self.puppet[id] = on or nil return true end
function client_game:teleport_player(pos) self.player.pos = pos return true end
client_game.keys = {}
function client_game:is_key_down(vk) return self.keys[vk] == true end
-- The client's Ashley: her AI (while she is not a puppet) runs to the client's player.
client_game.ashley = { pos = { x = 82, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 600, puppet = false,
    warps = 0 }
function client_game:ashley_read(full)
    local a = self.ashley
    if not a.puppet then
        local p = self.player.pos
        local dx, dz = p.x - a.pos.x, p.z - a.pos.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1.5 then
            local step = math.min(0.4, d - 1.5)
            a.pos = { x = a.pos.x + dx / d * step, y = a.pos.y, z = a.pos.z + dz / d * step }
        end
    end
    return { pos = { x = a.pos.x, y = a.pos.y, z = a.pos.z }, rot = a.rot, hp = a.hp, max_hp = 600, alive = true,
        busy = false, layers = full and { { bank = 3, id = 40, frame = 1, speed = 1 } } or nil }
end
function client_game:ashley_set_puppet(on) self.ashley.puppet = on return true end
function client_game:ashley_set_transform(pos, rot)
    self.ashley.pos, self.ashley.rot = { x = pos.x, y = pos.y, z = pos.z }, rot
    return true
end
function client_game:ashley_set_anim() return true end
function client_game:ashley_set_hp(hp) self.ashley.hp = hp return true end
function client_game:ashley_warp(pos)
    self.ashley.warps = self.ashley.warps + 1
    self.ashley.pos = { x = pos.x, y = pos.y, z = pos.z }
    return true
end
client_game.case = {}
function client_game:give_receive(id, count)
    self.case[id] = (self.case[id] or 0) + count
    return count
end

local client_world = { flags = {}, flag_sets = {}, full_groups = nil, gimmicks = {}, objects = {}, applied = {},
    played = {}, warps = {}, playing = nil, done = {}, triggers_run = {} }
client_game.world = client_world
function client_world:install_hooks(cb) self.cb = cb end
function client_world:update() end
function client_world:location()
    local p = client_game.player
    return { chapter = p.chapter, stage = p.stage, pos = p.pos, yaw = 0, playable = true, loading = false }
end
function client_world:flag_set(g, v) self.flags[g] = v self.flag_sets[#self.flag_sets + 1] = g return true end
function client_world:flag_pulse() return true end
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
function client_world:cutscene_done(camera, id) return self.done[camera .. ":" .. id] == true end
function client_world:cutscene_play(ev)
    self.played[#self.played + 1] = ev
    self.playing = true
    self.done[ev.camera .. ":" .. ev.id] = true
    return true
end
function client_world:cutscene_skip(camera, id)
    if not self.playing then return "missing" end
    self.skipped = { camera = camera, id = id }
    self.playing = nil
    return "skipped"
end
client_world.door_states = {}
function client_world:doors_near() return self.door_states end
function client_world:door_apply(g, st) self.door_from_host = { guid = g, open = st.open, hold = st.hold } return "done" end
function client_world:doors_release() end
function client_world:trigger_run(ev)
    self.triggers_run[#self.triggers_run + 1] = ev
    return "run"
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
client_world.objects[CROW2] = { kind = "chainsaw.GmCrow", pos = { x = 5.5, y = 0, z = 4 }, routine = 0, terminal = false }
-- The client's animals (game_world.lua's animal functions): puppets follow the host's.
client_world.puppets, client_world.animal_pos, client_world.animal_routine = {}, {}, {}
function client_world:animals_near() return {} end
function client_world:animal_local(g)
    local o = self.objects[g]
    if o == nil or not o.kind:find("Crow") then return nil end
    local r = self.animal_routine[g] or 0
    return { pos = self.animal_pos[g] or o.pos, routine = r, dead = r == 7 or r == 8 }
end
function client_world:animal_puppet(g, on) self.puppets[g] = on or nil return true end
function client_world:animal_set_transform(g, pos)
    self.animal_pos[g] = { x = pos.x, y = pos.y, z = pos.z }
    return true
end
function client_world:animal_set_motion() return true end
function client_world:animal_kill(g) self.animal_routine[g] = 7 return true end
function client_world:restore_animals() self.puppets = {} end

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
    mock.run_frame() -- the UI queues it...
    mock.run_frame() -- ...the game thread hosts and switches the menu pauses off
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

T.run("enemies_by_level_identity", function()
    -- The enemy the host killed in an earlier session (only its save remembers it) never
    -- appears for the client: the host listed it from its backups when the client joined.
    local ok = T.wait_until(function() return client_game.enemies[3].erased == true end, step, 5)
    T.check(ok, "erased in the client's game")
    T.eq(client_game.enemies[3].hp, 100, "not killed: no corpse, no loot")
    -- The villager both games have pairs by its level ID although each game put it elsewhere,
    -- and the client's copy goes where the host's is.
    ok = T.wait_until(function()
        local e = client_game.enemies[2]
        return math.abs(e.pos.x - 30) < 0.05 and math.abs(e.pos.z - 30) < 0.05
    end, step, 5)
    T.check(ok, "the client's villager stands where the host's is (" .. client_game.enemies[2].pos.x .. ")")
    T.eq(client.enemy_net.counters.uid_pairs >= 1, true, "paired by level ID")
    T.eq(client_game.puppet[2], true, "following the host's copy with its AI off")
    -- The host kills it: it dies (or is removed) in the client's game too.
    villager.hp = 0
    ok = T.wait_until(function() return not client_game.enemies[2].alive or client_game.enemies[2].erased end, step, 5)
    T.check(ok, "the kill crossed by level ID")
    -- The villager the client's save had dead is alive in the host's world: it appears for the
    -- client too and follows the host's.
    ok = T.wait_until(function()
        local e = client_game.enemies[4]
        return e ~= nil and math.abs(e.pos.x - 12) < 0.05 and math.abs(e.pos.z + 8) < 0.05
    end, step, 8)
    T.check(ok, "spawned in the client's game, where the host's is")
    T.eq(client.enemy_net.counters.revived, 1, "paired with the host's (one enemy, run by one game)")
end)

T.run("a_client_reload_takes_the_hosts_world_again", function()
    local before = client.enemy_net:summary().dead_known
    T.check(before >= 2, "the client knows both dead villagers (" .. before .. ")")
    -- The client dies and reloads a checkpoint: its game has the villager killed earlier back.
    client_game.enemies[3].erased = nil
    client_game.reload_id = 2
    local ok = T.wait_until(function() return client_game.enemies[3].erased == true end, step, 5)
    T.check(ok, "the enemy the host killed is gone again")
    ok = T.wait_until(function() return client.world_sync_pending == nil end, step, 5)
    T.check(ok, "and the host's world state came again")
    local said = false
    for _, m in ipairs(client.messages) do
        if m.text:find("reloaded", 1, true) then said = true end
    end
    T.check(said, "the client was told")
end)

T.run("flags_cross_both_ways", function()
    mock.game_set_flag(G_GATE, true) -- game code in the host's game opens a gate (Variable.set_Bool)
    local ok = T.wait_until(function() return client_world.flags[G_GATE] == true end, step, 5)
    T.check(ok, "the host's change reached the client's game")
    client_world.flags[G_DOOR] = true -- what the full copy gave the client's game
    mock.game_set_flag(G_DOOR, false)  -- the host's game goes back to an older state (a checkpoint)
    T.wait_until(function() return false end, step, 0.5)
    T.eq(client_world.flags[G_DOOR], true, "a flag going off never undoes the client's world")
    client_world.cb.on_flag(G_OBJ, true) -- the client's game completes an objective
    ok = T.wait_until(function() return mock.flag_value(G_OBJ) end, step, 5)
    T.check(ok, "the client's objective is set in the host's game (GlobalUserDataManager.trySetBool)")
end)

T.run("gimmicks_cross_as_soon_as_the_game_announces_them", function()
    mock.set_gimmick({ category = 1, kind = 0, group = 40200, index = 5 }, { 1, 0 }, { { id = 1, done = 1 } }, true)
    local ok = T.wait_until(function()
        local g = client_world.gimmicks["1:0:40200:5"]
        return g ~= nil and g.triggers[1] and g.triggers[1].done == 1
    end, step, 5)
    T.check(ok, "the host's lever reached the client")
    -- The client's game opens a shutter: the host's game takes it gimmick by gimmick.
    client.settings.gimmick_interval = 0.5
    T.wait_until(function() return false end, step, 1.5) -- the client's game has compared its table
    client_world.gimmicks["1:0:40200:5"] = { ctx = { category = 1, kind = 0, group = 40200, index = 5 }, attr = "\2\0",
        triggers = { { id = 1, done = 1 } }, detected = false, acc = {} }
    ok = T.wait_until(function()
        local g = world.gimmick_table["1:0:40200:5"]
        return g ~= nil and g.attr[1] == 2
    end, step, 5)
    T.check(ok, "the client's change reached the host's game")
    T.eq(world.gimmick_loads, nil, "without reloading the host's whole gimmick table")
    client.settings.gimmick_interval = nil
end)

T.run("an_item_the_client_places_unlocks_the_hosts_slot_and_its_objective_crosses", function()
    -- The host's game has the slot on screen; the client's player sets the item in it.
    local ctx = { category = 1, kind = 0, group = 40200, index = 41 }
    local guid = "44444444-0000-0000-0000-000000000041"
    local slot = mock.make_live_gimmick("chainsaw.GmUseItem", ctx, guid, { keys = { [0x55E] = {
        callees = { "chainsaw.ReduceInventoryItemSettings.Param" }, end_callees = { "chainsaw.InventorySettings.Param" } } } })
    client.settings.gimmick_interval = 0.5
    client_world.gimmicks["1:0:40200:41"] = { ctx = ctx, attr = "\0\0", triggers = {}, detected = false, acc = {} }
    T.wait_until(function() return false end, step, 1.5) -- the client's game has compared its table
    client_world.gimmicks["1:0:40200:41"] = { ctx = ctx, attr = "\1\0", triggers = {}, detected = false, acc = {} }
    local ok = T.wait_until(function() return slot:call("getGmFlag") == true end, step, 5)
    T.check(ok, "the host's slot is set")
    local played = 0
    for _, p in ipairs(world.portrayals) do
        if p.guid == guid and p.key == 0x55E then played = played + 1 end
    end
    T.eq(played, 1, "with its own sequence: the item appears and the lock opens on the host's screen")
    T.eq(world.items_taken, nil, "nothing taken from the host's player")
    mock.finish_portrayals()
    T.eq(world.items_given, nil, "nor handed out to them")
    client.settings.gimmick_interval = nil
    -- The client's objective moved on (it holds the item): the host's follows.
    mock.set_purpose(1101, 10)
    client_world.purpose = { id = 1103, priority = 30, message = "0000044f-0000-0000-0000-000000000000", display = 3,
        delay = 0, mediate = false }
    function client_world:purpose_read() return self.purpose end
    function client_world:purpose_apply() return false end
    ok = T.wait_until(function()
        local cur = world.singletons["chainsaw.PurposeManager"].cur
        return cur ~= nil and cur.id == 1103
    end, step, 5)
    T.check(ok, "the host shows the client's objective")
    T.eq(world.purpose_banners, 1, "with the objective banner")
end)

T.run("a_door_the_client_walks_through_opens_and_stays_open_for_the_host", function()
    client_world.door_states[G_DOOR_GO] = { open = true, hold = true, attr = 1 }
    local ok = T.wait_until(function() return door.__fields._Routine == 1 end, step, 5)
    T.check(ok, "the host's door opened")
    T.wait_until(function() return false end, step, 1)
    T.eq(door.__fields._Routine, 1, "and stays open while the client is in it")
    client_world.door_states[G_DOOR_GO] = { open = true, hold = false, attr = 1 }
    ok = T.wait_until(function() return door.__fields._Routine == 0 end, step, 5)
    T.check(ok, "it closes once the client walked on")
    client_world.door_states = {}
end)

T.run("animals_near_both_players_follow_the_host", function()
    -- Both players stand next to the crow (the client appeared next to the host).
    local ok = T.wait_until(function() return client_world.puppets[CROW2] == true end, step, 5)
    T.check(ok, "the client's crow follows the host's (its own AI off)")
    local p = crow2.owner.transform.wpos
    p.x, p.y, p.z = 6, 2, 7 -- the host's crow flies up
    ok = T.wait_until(function()
        local q = client_world.animal_pos[CROW2]
        return q ~= nil and math.abs(q.x - 6) < 0.05 and math.abs(q.y - 2) < 0.05 and math.abs(q.z - 7) < 0.05
    end, step, 3)
    T.check(ok, "and flies where the host's flies")
    T.eq(world.moving[crow2.core], true, "the host's crow keeps its AI")
    -- The client's player shoots it: it dies in the client's game at once, and in the host's.
    client_world.animal_routine[CROW2] = 7
    ok = T.wait_until(function() return crow2.__fields._Routine == 7 end, step, 3)
    T.check(ok, "the host's crow died too (its Die routine)")
    T.eq(client_world.puppets[CROW2], nil, "the client's crow plays its own death")
end)

T.run("breakables_and_animals_cross", function()
    crow.__fields._Routine = 7 -- the host shoots the crow (Die)
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
    -- The client stands 20 m away: close enough to watch from there, too far to count as
    -- having arrived (gate radius 10 m) unless it is in the cutscene too.
    client_game.player.pos = { x = 20, y = 0, z = 0 }
    T.wait_until(function() return false end, step, 0.3) -- the host sees the client there
    -- The host walks into the church: its game plays the cutscene "once" through a PayloadPlay
    -- (start flag group 0 / bit 5, data owner and next scripted step).
    mock.start_cutscene(20130, { screen = 3, start_flags = { { group = 0, index = 5 } }, owner = 0x4242,
        end_portrayal = 0x99 })
    T.eq(mock.flag_value(G_START), true, "the host's cutscene set its start flag")
    local ok = T.wait_until(function() return #client_world.played > 0 end, step, 5)
    T.check(ok, "the client's game played it")
    local ev = client_world.played[1] or {}
    T.eq(ev.id, 20130, "the same cutscene")
    T.eq(ev.screen, 3, "on the same screen")
    T.eq(ev.owner_code, 0x4242, "continuing the same scripted sequence")
    T.eq(ev.start_flags and ev.start_flags[1].index, 5, "with its start flags")
    -- Both are in it, so the transition gate does not hold the host once its grace period
    -- (1.5 s) is over.
    T.wait_until(function() return false end, step, 2.5)
    T.eq(world.time_scale, 1.0, "host not frozen while the client watches too")
    T.eq(client.partner_state and (client.partner_state.flags & P.PLAYER_FLAGS.CUTSCENE) ~= 0, true,
        "the client sees the host in the cutscene")
    -- The host skips it: the client's copy is skipped too.
    mock.press_skip()
    ok = T.wait_until(function() return client_world.skipped ~= nil end, step, 5)
    T.check(ok, "skipped in the client's game")
    T.eq(client_world.skipped and client_world.skipped.id, 20130, "the same cutscene")
    T.wait_until(function() return world.current_cutscene == nil end, step, 2)
    T.eq(world.current_cutscene, nil, "and over in the host's")
    mock.end_cutscene()
    client_world.playing = nil
    client_game.player.pos = { x = 1, y = 0, z = 0 }
    for _ = 1, 10 do step() end
end)

T.run("event_triggers_run_in_both_games", function()
    -- The host walks into a scripted event's area: the client's game (standing close) runs it too.
    local t = mock.make_trigger(G_AREA, "Area_VillageAmbush")
    T.check(mock.activate_trigger(t, world.player.body), "the host's game ran it")
    local ok = T.wait_until(function() return #client_world.triggers_run > 0 end, step, 5)
    T.check(ok, "the client's game ran the same trigger")
    local ev = client_world.triggers_run[1] or {}
    T.eq(ev.guid, G_AREA, "identified by its GameObject's GUID")
    T.eq(ev.hash, mock.name_hash("Area_VillageAmbush"), "and its name hash")
    -- The client walks into another one: the host's game finds it and runs it with its player.
    client_world.cb.on_trigger({ guid = G_AREA2, hash = mock.name_hash("Area_ChurchSquare"), trigger_type = 1, once = true })
    ok = T.wait_until(function() return area_runs > 0 end, step, 5)
    T.check(ok, "the host's game ran the client's trigger")
    T.eq(area2.trigger.__fields["<Done>k__BackingField"], 1, "marked done there")
    for _ = 1, 10 do step() end
    T.eq(area_runs, 1, "once")
end)

T.run("the_host_gives_the_client_an_item_from_its_case", function()
    local herb = mock.case_item("case-herb", 114400000, 2)
    local menu, labels = mock.open_item_commands(herb)
    T.eq(menu.order[#menu.order], 13, "'give' is offered in the host's case")
    T.eq(labels[13], "Give to ClientLeon", "named after the partner")
    mock.choose_item_command(herb, 13)
    T.eq(world.case["case-herb"], nil, "out of the host's case")
    local ok = T.wait_until(function() return client_game.case[114400000] == 2 end, step, 5)
    T.check(ok, "in the client's case")
    ok = T.wait_until(function() return host_messages_contain("Gave") end, step, 2)
    T.check(ok, "the host was told")
end)

T.run("an_enemy_next_to_the_client_is_run_by_the_clients_game", function()
    -- The client far from the Ganado (the tests before left it anywhere: the cutscene test had
    -- it stand on the Ganado, which may have given the Ganado to the client's game, and then
    -- next to the host, where neither player is clearly closer). Going back to the host takes a
    -- lasting lead and its time with the owner (docs/PROTOCOL.md, enemy ownership).
    client_game.player.pos = { x = 80, y = 0, z = 0 }
    local ok = T.wait_until(function() return client_game.puppet[1] == true end, step, 8)
    T.check(ok, "far from the client, its copy of the Ganado follows the host's")
    client_game.player.pos = { x = 21, y = 0, z = 1 } -- the client walks up to the Ganado
    ok = T.wait_until(function() return client_game.puppet[1] == nil and ganado.head.update_self == false end, step, 5)
    T.check(ok, "the Ganado changed hands: the client's game runs it, the host's follows")
    T.eq(mock.component(ganado.body, "via.motion.MotionFsm2").enabled, false, "the host's copy plays only the client's animation")
    client_game.enemies[1].pos = { x = 24, y = 0, z = 3 } -- the client's AI moves it
    ok = T.wait_until(function() return math.abs(ganado.pos.x - 24) < 0.05 and math.abs(ganado.pos.z - 3) < 0.05 end, step, 3)
    T.check(ok, "the host's copy follows the client's (x=" .. ganado.pos.x .. ")")
    client_game.player.pos = { x = 80, y = 0, z = 0 } -- the client walks away again
    ok = T.wait_until(function() return client_game.puppet[1] == true and ganado.head.update_self == true end, step, 6)
    T.check(ok, "back to the host's game")
end)

local function gap(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

T.run("one_ashley_for_both_and_a_tap_of_alt_sends_her_over", function()
    local ca = client_game.ashley
    local ok = T.wait_until(function() return ca.puppet and gap(ca.pos, ashley.pos) < 0.05 end, step, 3)
    T.check(ok, "the client's Ashley follows the host's (" .. ca.pos.x .. " vs " .. ashley.pos.x .. ")")
    T.check(ashley.head.update_self ~= false, "the host's game runs her")
    -- The client's player taps Alt: she goes to the client.
    client_game.keys[0x12] = true
    step()
    client_game.keys[0x12] = false
    ok = T.wait_until(function() return not ca.puppet and ashley.head.update_self == false end, step, 3)
    T.check(ok, "the client's game runs her now, the host's is the puppet")
    T.eq(ca.warps, 1, "taken over far from the client's player: brought next to them")
    T.eq(ashley.no_damage, true, "the host's game takes no HP from her")
    T.eq(mock.try_kidnap(ashley), false, "and its enemies cannot grab her")
    T.eq(mock.component(ashley.body, "via.motion.MotionFsm2").enabled, false, "she plays only the client's animation")
    client_game.player.pos = { x = 70, y = 0, z = 6 } -- the client walks on; she follows
    ok = T.wait_until(function() return gap(ashley.pos, ca.pos) < 0.05 and gap(ca.pos, client_game.player.pos) < 1.6 end,
        step, 4)
    T.check(ok, "the host sees her follow the client (" .. ashley.pos.x .. ", " .. ashley.pos.z .. ")")
    T.check(host_messages_contain("Ashley now follows ClientLeon"), "the host is told")
    -- After the cooldown the host's player taps Alt: she comes back.
    ok = T.wait_until(function() return client:status().ashley.cooldown == 0 end, step, 3)
    mock.keys[0x12] = true
    step()
    mock.keys[0x12] = false
    ok = T.wait_until(function() return ca.puppet and ashley.head.update_self == true end, step, 3)
    T.check(ok, "back with the host")
    T.eq(ashley.set_transforms, 1, "the game's own teleport brought her to the host's player")
    T.eq(ashley.no_damage, false, "she takes damage again")
    ok = T.wait_until(function() return gap(ca.pos, ashley.pos) < 0.05 end, step, 3)
    T.check(ok, "the client's follows the host's again")
    client_game.player.pos = { x = 80, y = 0, z = 0 }
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
    mock.game_set_flag(G_HOOK, true)
    local ok = T.wait_until(function() return client_world.flags[G_HOOK] == true end, step, 5)
    T.check(ok, "flag hooks reinstalled")
end)

T.run("stop_hosting_restores_pauses", function()
    client:leave()
    T.wait_until(function() return host_messages_contain("ClientLeon disconnected") end, step, 5)
    mock.press["Stop hosting"] = true
    mock.run_frame()
    mock.run_frame()
    T.eq(re4coop_net.state(), "idle", "stopped")
    T.eq(mock.pause_freezes(1), true, "the inventory pauses again")
    T.eq(ganado.head.update_self ~= false, true, "no enemy left without its AI")
end)

T.finish()
