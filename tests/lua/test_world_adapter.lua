-- game_world.lua, game_pause.lua and the enemy mirroring additions of game.lua against the
-- mocked REFramework / RE4 object model.
local T = require("testlib")
local mock = require("mock_reframework")
local P = require("re4coop.protocol")

local G1 = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"
local G2 = "11111111-2222-3333-4444-555555555555"

local function fresh(opts)
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    local world = mock.install(opts)
    world.player = mock.make_player({ x = 1, y = 2, z = 3 })
    world.stage, world.chapter = 40200, 21100
    if not (opts and opts.no_world) then
        mock.add_flag(G1, 1, 5)
        mock.add_flag(G2, 2, 31)
    end
    world.now = 0
    local Game = require("re4coop.game")
    local game = Game.new(function() end, function() return world.now end)
    local World = require("re4coop.game_world")
    local w = World.new(game, function() end)
    w:set_active(true) -- a partner is connected
    game:set_active(true)
    return w, game, world
end

T.run("probes_find_the_world_api", function()
    local w, game = fresh()
    local caps = game:capabilities()
    for _, name in ipairs({ "flags", "flag_words", "gimmicks", "objects", "cutscenes", "triggers", "warp", "chapter_switch" }) do
        T.check(caps[name] and caps[name].ok, name .. " capability: " .. tostring(caps[name] and caps[name].detail))
    end
    T.eq(w.flag_set_m.name, "requestSetFlag", "flag setter")
    T.eq(w.flag_check_m.name, "checkFlag", "flag check")
    T.eq(w.var_set_m.name, "trySetBool", "any flag set by GUID")
    T.eq(w.var_find_m.name, "findVariable", "any flag found by GUID")
    T.eq(#w.flag_event_ms, 2, "both change handlers (scenario and common flags)")
    T.eq(w.flag_save_m.name, "saveGameSaveData", "save found although declared with share.SaveDataBase")
    T.eq(w.flag_load_m.name, "loadGameSaveData", "load found although declared with share.SaveDataBase")
    T.eq(w.cs_proc_m.name, "procPayloadPlay", "cutscenes through their PayloadPlay")
    T.eq(w.trig_exec_m.name, "executeTrigger", "triggers through executeTrigger")
end)

T.run("every_flag_change_is_reported_but_not_ours", function()
    local w, game, world = fresh()
    local seen = {}
    w:install_hooks({ on_flag = function(g, v, pulse) seen[#seen + 1] = { g, v, pulse } end })
    T.eq(game:capabilities().flag_hooks.ok, true, "hooks installed")
    mock.game_set_flag(G1, true) -- game code: Variable.set_Bool
    T.eq(#seen, 1, "game change reported")
    T.eq(seen[1][1], G1, "guid text")
    T.eq(seen[1][2], true, "value")
    T.eq(w:flag_check(G1), true, "flag is set")
    world.singletons["chainsaw.ScenarioFlagManager"]:call("requestSetFlag", mock.guid_value(G2), true)
    T.eq(#seen, 2, "requestSetFlag goes through the same change event")
    mock.game_set_flag(G2, false)
    T.eq(#seen, 3, "a flag going off is reported too (flag_sync keeps it to itself)")
    T.eq(seen[3][2], false, "as off")
    T.check(w:flag_set(G2, true), "set through GlobalUserDataManager.trySetBool")
    T.eq(#seen, 3, "our own set is not reported")
    T.eq(w:flag_check(G2), true, "applied")
    T.eq(world.flag_groups[2].words[1], 0x80000000, "bit 31 of the second group")
    T.eq(world.watch_calls, nil, "the flag watcher decoy was never called")
    -- A trigger-kind flag fires once: reported as a pulse, and fired here as one.
    local G3 = "33333333-2222-3333-4444-555555555555"
    mock.add_flag(G3, 1, 9, { kind = 16 })
    mock.game_pulse_flag(G3)
    T.eq(seen[4][1], G3, "pulse reported")
    T.eq(seen[4][3], true, "as a pulse")
    T.check(w:flag_pulse(G3), "fired here")
    T.eq(world.pulses[#world.pulses], G3, "through setTrigger")
    T.eq(#seen, 4, "our own pulse is not reported")
    -- Common flags (outside the scenario groups) come through their own handler.
    local G4 = "44444444-2222-3333-4444-555555555555"
    mock.add_flag(G4, 2, 3, { common = true })
    mock.game_set_flag(G4, true)
    T.eq(seen[5][1], G4, "common flag reported")
end)

T.run("flag_hooks_are_idle_without_a_partner_and_never_flood", function()
    local w, game, world = fresh()
    local seen = 0
    w:install_hooks({ on_flag = function() seen = seen + 1 end })
    w:set_active(false)
    mock.game_set_flag(G1, true)
    T.eq(seen, 0, "no partner: the hook does nothing")
    w:set_active(true)
    for i = 1, 900 do mock.game_set_flag(G1, i % 2 == 0) end -- a game flipping a flag every frame
    T.eq(seen, 400, "at most 400 change events a second are read")
    T.eq(w:flag_hooks_active(), false, "word diffs take over meanwhile")
    T.check(game:capabilities().flag_hooks.detail:find("busy") ~= nil, "shown in Diagnostics")
    world.now = 6
    T.eq(w:flag_hooks_active(), true, "hooks back after the pause")
    mock.game_set_flag(G2, true)
    T.eq(seen, 401, "and report again")
end)

T.run("flag_words_snapshot_full_apply_and_live_bits", function()
    local w, _, world = fresh()
    world.flag_groups[1].words = { 7, 8, 9, 10 }
    local snap = w:flag_words_snapshot()
    T.eq(snap.Main[3], 9, "words read from the save object (boxed elements)")
    T.eq(#snap.Chapter, 2, "second group")
    T.check(w:flag_words_apply_full({ { name = "Main", words = { 1, 2, 0xFFFFFFFF, 10 } }, { name = "Nope", words = { 1 } } }),
        "full apply")
    T.eq(world.flag_groups[1].words[3], 0xFFFFFFFF, "word written back through loadGameSaveData")
    T.eq(world.flag_groups[1].words[1], 1, "first word")
    -- Live word changes go flag by flag (no table reload while playing): bits turning on only.
    local seen = 0
    w:install_hooks({ on_flag = function() seen = seen + 1 end })
    world.flag_groups[2].words = { 0, 0 }
    mock.game_set_flag(G1, true)
    seen = 0
    local loads = world.flag_loads
    w:flag_words_apply("Chapter", 0, 0x80000000, 0)
    w:flag_words_apply("Main", 0, 0, 0x20)
    w:update()
    T.eq(world.flag_groups[2].words[1], 0x80000000, "bit 31 of Chapter turned on through its variable")
    T.eq(mock.flag_value(G1), true, "a clear from the partner is never applied")
    T.eq(world.flag_loads, loads, "no flag table reload")
    T.eq(seen, 0, "and not reported back")
end)

T.run("gimmick_table_snapshot_and_apply", function()
    local w, _, world = fresh()
    world.gimmick_table["1:1:10:0"] = { ctx = { category = 1, kind = 1, group = 10, index = 0 }, attr = { 1, 0, 2 },
        triggers = { { id = 77, done = 1 } }, detected = true, acc = { { kind = 1, value = 0.5 }, { kind = 2, value = 9 } } }
    local snap = w:gimmicks_snapshot(true)
    local item = snap["1:1:10:0"]
    T.check(item ~= nil, "item read")
    T.eq(item.attr, "\1\0\2", "attr bytes")
    T.eq(item.triggers[1].id, 77, "trigger")
    T.eq(item.detected, true, "detected")
    T.eq(item.acc[1].kind, 1, "float accessory")
    T.eq(item.acc[2].value, 9, "uint accessory")
    -- Change it, and one this game has not set up yet.
    local changed = { ctx = item.ctx, attr = "\9\9\9\9", triggers = { { id = 77, done = 1 }, { id = 78, done = 1 } },
        detected = false, acc = { { kind = 1, value = 0.75 }, { kind = 1, value = 3 } } }
    local added = { ctx = { category = 1, kind = 1, group = 11, index = 2 }, attr = "\5", triggers = {}, detected = true, acc = {} }
    T.check(w:gimmicks_apply({ changed, added }), "applied")
    T.eq(world.gimmick_loads, nil, "never the game's whole-table load (it clears the manager)")
    T.eq(world.gimmick_context_loads, 1, "one context loaded the partner's state")
    local g = world.gimmick_table["1:1:10:0"]
    T.eq(#g.attr, 4, "attr resized")
    T.eq(g.attr[1], 9, "attr value")
    T.eq(#g.triggers, 2, "triggers")
    T.eq(g.detected, false, "detected cleared")
    T.eq(g.acc[1].value, 0.75, "accessory value")
    T.eq(g.acc[2].value, 9, "an accessory of another kind here stays ours")
    T.eq(w.counters.gimmicks_waiting, 1, "the other one waits for its gimmick")
    -- Its area loads: the gimmick is set up and takes the partner's state.
    world.gimmick_contexts["1:1:11:2"] = true
    world.now = (world.now or 0) + 5
    w:update()
    T.check(world.gimmick_table["1:1:11:2"] ~= nil, "applied once set up")
    T.eq(world.gimmick_table["1:1:11:2"].attr[1], 5, "its attr")
    T.eq(w.counters.gimmicks_waiting, 0, "nothing waits")
end)

T.run("large_gimmick_tables_are_read_over_several_frames", function()
    local w, _, world = fresh()
    for i = 1, 150 do
        mock.set_gimmick({ category = 1, kind = 0, group = 1000 + i, index = 0 }, { i % 256 })
    end
    local calls, snap = 0, nil
    repeat
        calls = calls + 1
        snap = w:gimmicks_snapshot()
    until snap ~= nil or calls > 10
    T.eq(calls, 4, "40 records per call")
    local n = 0
    for _ in pairs(snap) do n = n + 1 end
    T.eq(n, 150, "all records")
    -- Only the gimmicks that announced a change: their IDs are checked, only they are read.
    local keys = { ["1:0:1007:0"] = true, ["1:0:1120:0"] = true }
    local targeted = w:gimmicks_snapshot(false, keys)
    n = 0
    for _ in pairs(targeted or {}) do n = n + 1 end
    T.eq(n, 2, "two records, in one call (150 IDs per call)")
    T.eq(targeted["1:0:1120:0"].attr, string.char(120), "the right one")
end)

T.run("gimmick_changes_are_announced", function()
    local w = fresh()
    T.eq(w:gimmicks_dirty(), false, "nothing yet")
    mock.set_gimmick({ category = 1, kind = 0, group = 5, index = 1 }, { 1 }, nil, true) -- the game: pushDirtyList
    T.eq(w:gimmicks_dirty(), true, "announced through the pushDirtyList hook")
    T.eq(w:gimmicks_dirty(), false, "once")
    local keys = w:gimmick_dirty_keys()
    T.eq(keys["1:0:5:1"], true, "which gimmick")
    T.eq(next(w:gimmick_dirty_keys()), nil, "taken once")
end)

T.run("objects_scan_detect_and_apply", function()
    local w = fresh()
    local box = mock.make_object("chainsaw.GmWoodBox", "aaaaaaaa-0000-0000-0000-000000000001", { x = 2, y = 0, z = 0 }, 0)
    local crow = mock.make_object("chainsaw.GmCrow", "aaaaaaaa-0000-0000-0000-000000000002", { x = 3, y = 0, z = 0 }, 0)
    local bottle = mock.make_object("chainsaw.GmBottle", "aaaaaaaa-0000-0000-0000-000000000003", { x = 4, y = 0, z = 0 })
    local snap = w:objects_scan()
    T.eq(snap.stage, 40200, "stage")
    local o = snap.objects["aaaaaaaa-0000-0000-0000-000000000001"]
    T.check(o ~= nil, "box found by its GameObject GUID")
    T.eq(o.kind, "chainsaw.GmWoodBox", "kind")
    T.near(o.pos.x, 2, 1e-6, "position")
    T.eq(o.terminal, false, "intact")
    box.__fields._Routine = 2 -- Break
    T.eq(w:objects_scan().objects["aaaaaaaa-0000-0000-0000-000000000001"].terminal, true, "Break routine is terminal")
    -- Applying the partner's events.
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000099", P.OBJECT_EVENT.DESTROYED, -1), "missing", "unknown guid")
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000002", P.OBJECT_EVENT.DESTROYED, -1), "done", "crow")
    T.eq(crow.__fields._Routine, 7, "the crow dies the way a shot kills it: set_Routine(Die)")
    T.eq(crow.owner.draw_self, true, "not hidden")
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000003", P.OBJECT_EVENT.DESTROYED, -1), "done", "bottle")
    T.eq(bottle.owner.draw_self, false, "bottle hidden as a last resort")
    box.__fields._Routine = 0
    w:objects_scan()
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000001", P.OBJECT_EVENT.DESTROYED, 2), "done", "box")
    T.eq(box.__fields._Routine, 0, "its state machine is not forced (experimental switch off)")
    T.eq(box.owner.draw_self, false, "hidden instead")
    box.owner.draw_self = true
    w.game.settings.exp_force_routine = true
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000001", P.OBJECT_EVENT.DESTROYED, 2), "done", "box")
    T.eq(box.__fields._Routine, 2, "experimental: box enters the partner's terminal routine (plays its own break)")
    -- A scanned object that the game destroyed since is not touched.
    mock.destroy(crow.owner)
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000002", P.OBJECT_EVENT.DESTROYED, -1), "missing",
        "destroyed since the scan: left alone")
end)

T.run("animals_the_host_reads_and_the_client_follows", function()
    local w, _, world = fresh()
    local A, B = "bbbbbbbb-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002"
    local crow = mock.make_object("chainsaw.GmCrow", A, { x = 3, y = 1, z = 0 }, 0)
    mock.make_object("chainsaw.GmCrow", B, { x = 300, y = 0, z = 0 }, 0)
    local box = mock.make_object("chainsaw.GmWoodBox", "bbbbbbbb-0000-0000-0000-000000000003", { x = 2, y = 0, z = 0 }, 0)
    w:objects_scan()
    T.check(w.object_index[A].animal and not w.object_index[box.owner.guid].animal, "animals told apart from breakables")
    -- Host: the animals near both players, read now.
    crow.owner.transform.wpos.x = 4
    local list = w:animals_near({ { x = 0, y = 0, z = 0 }, { x = 6, y = 0, z = 0 } }, 50, 24)
    T.eq(#list, 1, "only the crow near both players")
    T.eq(list[1].guid, A, "by its GameObject GUID")
    T.near(list[1].pos.x, 4, 1e-6, "its current position")
    T.eq(list[1].routine, 0, "routine")
    T.eq(list[1].dead, false, "alive")
    T.check(list[1].motion and list[1].motion.bank == 7 and list[1].motion.id == 1, "its animation")
    T.eq(#w:animals_near({ { x = 0, y = 0, z = 0 }, { x = 200, y = 0, z = 0 } }, 50, 24), 0,
        "nothing when one player is far away")

    -- Client: the crow follows the host's, its own AI off the game's update.
    local core = crow.core
    T.eq(world.moving[core], true, "the game updates it")
    T.check(w:animal_puppet(A, true), "puppet")
    T.eq(world.moving[core], nil, "off the update list: its AI stops")
    local frames = crow.ai_frames or 0
    mock.update_gimmicks()
    T.eq(crow.ai_frames or 0, frames, "its state machine does not run")
    T.check(w:animal_set_transform(A, { x = 5, y = 2, z = 1 }, { x = 0, y = 0.6, z = 0, w = 0.8 }), "moved")
    T.near(crow.owner.transform.wpos.y, 2, 1e-6, "to the host's position")
    T.near(crow.owner.transform.wrot.y, 0.6, 1e-6, "and rotation")
    T.check(w:animal_set_motion(A, { bank = 7, id = 5, frame = 2 }), "animated")
    T.eq(crow.__fields._Motion.layers[1].motion, 5, "the host's animation")
    T.eq(w:animal_local(A).dead, false, "alive here")
    T.check(w:animal_puppet(A, false), "released")
    T.eq(world.moving[core], true, "back on the update")
    -- A gimmick the game finished meanwhile (GimmickCore.finish) is never put back.
    w:animal_puppet(A, true)
    core.__fields._HasRegisteredMove = false
    w:animal_puppet(A, false)
    T.eq(world.moving[core], nil, "finished: stays off the update")
    core.__fields._HasRegisteredMove = true
    world.moving[core] = true
    -- Killed for the partner: it dies with its own AI running.
    w:animal_puppet(A, true)
    T.check(w:animal_kill(A), "killed")
    T.eq(crow.__fields._Routine, 7, "Die")
    T.eq(world.moving[core], true, "its AI runs the death")
    T.eq(w:animal_local(A).dead, true, "dead here")
    -- Leaving the session gives every puppet back; destroyed ones are left alone.
    local B2 = mock.make_object("chainsaw.GmCrow", "bbbbbbbb-0000-0000-0000-000000000004", { x = 3, y = 0, z = 3 }, 0)
    local C2 = mock.make_object("chainsaw.GmCrow", "bbbbbbbb-0000-0000-0000-000000000005", { x = 3, y = 0, z = 4 }, 0)
    w:objects_scan()
    T.check(w:animal_puppet(B2.owner.guid, true) and w:animal_puppet(C2.owner.guid, true), "two puppets")
    mock.destroy(C2.owner)
    w:restore_animals()
    T.eq(world.moving[B2.core], true, "back on the update")
    T.eq(world.moving[C2.core], nil, "a destroyed one is not")
    T.eq(w:animal_puppet(C2.owner.guid, true), false, "and cannot become a puppet")
end)

T.run("cutscenes_are_read_and_played_as_the_games_own_payload", function()
    local w, _, world = fresh()
    local seen = {}
    w:install_hooks({ on_cutscene = function(ev) seen[#seen + 1] = ev end })
    -- The game plays a story cutscene "once": its PayloadPlay goes through procPayloadPlay.
    mock.start_cutscene(10157, { screen = 3, start_flags = { { group = 0, index = 5 } },
        end_flags = { { group = 1, index = 31 } }, owner = 0x1234, end_portrayal = 0xABCD })
    T.eq(#seen, 1, "the game's cutscene reported")
    local ev = seen[1]
    T.eq(ev.camera, P.CAMERA.TIMELINE, "timeline camera")
    T.eq(ev.id, 10157, "id")
    T.eq(ev.screen, 3, "screen")
    T.eq(ev.owner_code, 0x1234, "data owner")
    T.eq(ev.end_portrayal, 0xABCD, "next scripted step")
    T.eq(#ev.start_flags, 1, "start flag")
    T.eq(ev.start_flags[1].group, 0, "group")
    T.eq(ev.start_flags[1].index, 5, "index")
    T.eq(ev.end_flags[1].index, 31, "end flag")
    T.eq(w:cutscene_playing(), true, "playing")
    T.eq(w:cutscene_done(1, 10157), true, "recorded as seen")
    T.eq(mock.start_cutscene(10157), 0, "the game never plays it twice")
    mock.end_cutscene()
    T.check(w:cutscene_playing() == nil, "not playing")
    -- The partner's cutscene: the same payload through our own procPayloadPlay.
    T.eq(w:cutscene_done(1, 20130), false, "not seen yet")
    local ok = w:cutscene_play({ camera = 1, id = 20130, screen = 3, owner_code = 0x55, end_portrayal = 0x77,
        start_flags = { { group = 1, index = 31 } }, end_flags = { { group = 0, index = 5 } } })
    T.check(ok, "played")
    local rec = world.played[#world.played]
    T.eq(rec.id, 20130, "the game played it")
    T.eq(rec.screen, 3, "on the same screen")
    T.eq(rec.owner, 0x55, "with the same data owner")
    T.eq(rec.end_portrayal, 0x77, "and next step")
    T.eq(rec.start_flags[1].index, 31, "start flags as FlagInfo[]")
    T.eq(rec.end_flags[1].index, 5, "end flags as FlagInfo[]")
    T.eq(world.flag_groups[2].words[1], 0x80000000, "our game set its own start flag")
    T.eq(#seen, 1, "our replay is not reported as a local cutscene")
    T.eq(w:cutscene_done(1, 20130), true, "now seen here too")
    mock.end_cutscene()
    -- A movie keeps where it puts the players.
    T.check(w:cutscene_play({ camera = 2, id = 5, coords = { { kind = 1, pos = { x = 3, y = 0, z = 0 }, rot_y = 1.5,
        reset_camera = true } } }), "movie played")
    rec = world.played[#world.played]
    T.eq(rec.camera, 2, "movie")
    T.eq(rec.coords[1].kind, 1, "player kind")
    T.near(rec.coords[1].x, 3, 1e-6, "position")
    T.near(rec.coords[1].rot_y, 1.5, 1e-6, "facing")
end)

T.run("cutscene_skips_are_seen_and_applied_like_the_skip_button", function()
    local w, game, world = fresh()
    local skips = {}
    w:install_hooks({ on_cutscene_skip = function(ev) skips[#skips + 1] = ev end })
    w:set_active(true)
    T.eq(game:capabilities().cutscene_skips.ok, true, "PlayWork skip fields found")
    -- Our player skips a cutscene: reported once.
    mock.start_cutscene(100)
    mock.press_skip()
    mock.update_cutscene_skip() -- procSkip: DoneSkip
    w:update()
    w:update()
    T.eq(#skips, 1, "reported once")
    T.eq(skips[1].camera, 1, "camera type")
    T.eq(skips[1].id, 100, "camera id")
    mock.update_cutscene_skip() -- it ends after its fade
    T.eq(world.current_cutscene, nil, "over")
    -- The partner's skip here: through the same input, and not reported back.
    mock.start_cutscene(200)
    T.eq(w:cutscene_skip(1, 999), "missing", "not that cutscene")
    T.eq(w:cutscene_skip(1, 200), "skipped", "skip requested")
    mock.update_cutscene_skip()
    w:update()
    mock.update_cutscene_skip()
    T.eq(world.skips, 2, "skipped by the game")
    T.eq(#skips, 1, "our application is not reported")
    -- A cutscene the game does not let skip keeps playing.
    world.unskippable = true
    mock.start_cutscene(300)
    w:cutscene_skip(1, 300)
    mock.update_cutscene_skip()
    mock.update_cutscene_skip()
    T.check(world.current_cutscene ~= nil, "still playing")
end)

T.run("doors_are_read_and_held_open_for_the_partner", function()
    local w, game, world = fresh()
    T.eq(game:capabilities().doors.ok, true, "GmDoor keep-open slots found")
    local GD = "dddddddd-1111-0000-0000-000000000001"
    local door = mock.make_door(GD, { x = 3, y = 0, z = 0 })
    mock.make_door("dddddddd-1111-0000-0000-000000000002", { x = 300, y = 0, z = 0 }) -- far away
    local near = w:doors_near({ x = 0, y = 0, z = 0 }, 25)
    T.check(near[GD] ~= nil, "the near door")
    T.eq(near["dddddddd-1111-0000-0000-000000000002"], nil, "not the far one")
    T.eq(near[GD].open, false, "closed")
    -- Our player opens it and stands in it.
    mock.player_at_door(door, true)
    mock.update_doors()
    world.now = 5 -- a later look
    near = w:doors_near({ x = 0, y = 0, z = 0 }, 25)
    T.eq(near[GD].open, true, "open")
    T.eq(near[GD].hold, true, "held by our player")
    T.eq(near[GD].attr & 1, 1, "open bit")
    mock.player_at_door(door, false)
    mock.update_doors()
    T.eq(door.__fields._Routine, 0, "it closes once we walk on")
    -- The partner opens it in their game and stands in it: it opens here and stays open.
    T.eq(w:door_apply(GD, { open = true, hold = true, attr = 3 }), "done", "applied")
    mock.update_doors()
    T.eq(door.__fields._Routine, 1, "opened here")
    T.eq(door.ctx.attr[1], 3, "with the partner's side")
    for _ = 1, 5 do mock.update_doors() end
    T.eq(door.__fields._Routine, 1, "and held open by the Guest slot")
    -- They walk on: it closes here too.
    w:door_apply(GD, { open = true, hold = false, attr = 3 })
    mock.update_doors()
    T.eq(door.__fields._Routine, 0, "closed")
    -- A partner holding a door when the session ends never leaves it stuck open.
    w:door_apply(GD, { open = true, hold = true, attr = 1 })
    mock.update_doors()
    w:doors_release()
    mock.update_doors()
    T.eq(door.__fields._Routine, 0, "released")
    T.eq(w:door_apply("dddddddd-1111-0000-0000-0000000000ff", { open = true }), "missing", "not loaded here")
end)

T.run("automatic_and_big_doors_are_held_open_for_the_partner", function()
    local w, _, world = fresh()
    local GA, GE, GB = "dddddddd-2222-0000-0000-000000000001", "dddddddd-2222-0000-0000-000000000002",
        "dddddddd-2222-0000-0000-000000000003"
    local auto = mock.make_auto_door(GA, { x = 2, y = 0, z = 0 })
    local elevator = mock.make_auto_door(GE, { x = 4, y = 0, z = 0 }, "chainsaw.GmElevatorDoor")
    local big = mock.make_big_door(GB, { x = 6, y = 0, z = 0 })
    local origin = { x = 0, y = 0, z = 0 }
    local near = w:doors_near(origin, 25)
    T.check(near[GA] and near[GE] and near[GB], "all three kinds found")
    -- Our player walks through the automatic door: it opens and we hold it.
    auto.sensor = true
    mock.update_doors()
    world.now = 3
    near = w:doors_near(origin, 25)
    T.eq(near[GA].open, true, "automatic door open")
    T.eq(near[GA].hold, true, "held by our player")
    auto.sensor = false
    -- The partner walks into the elevator door in their game: ours opens and stays open.
    w:door_apply(GE, { open = true, hold = true })
    for _ = 1, 30 do
        w:update()
        mock.update_doors()
    end
    T.eq(elevator.__fields._Rno0, 1, "elevator door held open for the partner (3 s)")
    near = w:doors_near(origin, 25)
    T.eq(near[GE].hold, false, "and never reported back as held by us")
    w:door_apply(GE, { open = true, hold = false })
    for _ = 1, 15 do
        w:update()
        mock.update_doors()
    end
    T.eq(elevator.__fields._Rno0, 0, "closes after its wait once they left")
    -- A big double door open in both games: the partner close to it keeps ours open.
    big.__fields._Routine = 3
    w:door_apply(GB, { open = true, hold = true })
    mock.update_doors()
    T.eq(big.__fields._Routine, 3, "big door held open")
    T.eq(big.__fields.IsAnyOneCloseToDoor, 1, "through its 'someone close' count")
    T.eq(w:doors_near(origin, 25)[GB].hold, false, "not reported back as ours")
    w:door_apply(GB, { open = true, hold = true })
    T.eq(big.__fields.IsAnyOneCloseToDoor, 1, "counted once")
    w:doors_release()
    mock.update_doors()
    T.eq(big.__fields.IsAnyOneCloseToDoor, 0, "released when the partner leaves")
    T.eq(big.__fields._Routine, 0, "and it closes")
end)

T.run("event_triggers_are_reported_and_run_with_our_player", function()
    local w, game, world = fresh()
    game:read_player_state() -- knows our player's GameObjects
    local reported = {}
    w:install_hooks({ on_trigger = function(ev) reported[#reported + 1] = ev end })
    local GT = "cccccccc-0000-0000-0000-000000000001"
    local ran = {}
    local t = mock.make_trigger(GT, "Area_VillageAmbush", { components = { "chainsaw.GmPortrayalAreaHit",
        "chainsaw.SetFlagSettings" }, process = function(target) ran[#ran + 1] = target end })
    -- Our player walks in: the interaction update marks it done and runs it.
    T.check(mock.activate_trigger(t, world.player.body), "the game ran it")
    w:update()
    T.eq(#reported, 1, "reported")
    T.eq(reported[1].guid, GT, "by its GameObject's GUID")
    T.eq(reported[1].hash, mock.name_hash("Area_VillageAmbush"), "and its name hash")
    T.eq(reported[1].once, true, "play once")
    T.eq(reported[1].head, false, "set off by the body")
    -- Not reported: an NPC setting it off, a key trigger, gimmicks that are not pure events.
    local t2 = mock.make_trigger("cccccccc-0000-0000-0000-000000000002", "Area_Other", { once = false })
    mock.activate_trigger(t2, mock.make_go("ch2a1z0_body"))
    local door = mock.make_trigger("cccccccc-0000-0000-0000-000000000003", "Door_Open", { key = true,
        components = { "chainsaw.GmDoorBase" } })
    mock.activate_trigger(door, world.player.body)
    local pit = mock.make_trigger("cccccccc-0000-0000-0000-000000000004", "Area_Pitfall", {
        components = { "chainsaw.GmPortrayalAreaHit", "chainsaw.GmPitfall" } })
    mock.activate_trigger(pit, world.player.body)
    local death = mock.make_trigger("cccccccc-0000-0000-0000-000000000005", "Area_FallDeath", {
        components = { "chainsaw.GmPortrayalAreaHit", "chainsaw.PortrayalSettings" }, callees = { "chainsaw.TestMovieSettings.Param" } })
    mock.activate_trigger(death, world.player.body)
    local item = mock.make_trigger("cccccccc-0000-0000-0000-000000000006", "Area_GiveKey", {
        components = { "chainsaw.GmPortrayalAreaHit", "chainsaw.InventorySettings" } })
    mock.activate_trigger(item, world.player.body)
    w:update()
    T.eq(#reported, 1, "only the pure event")
    T.eq(w.counters.trigger_not_event, 3, "a trap, a portrayal with an effect we cannot mute and an item hand-out ruled out")

    -- The partner's trigger here: found by GUID and name hash, marked done, run with our player.
    t.trigger.__fields["<Done>k__BackingField"] = 0
    ran = {}
    T.eq(w:trigger_run(reported[1]), "run", "run")
    T.eq(ran[1], world.player.body, "with our player")
    T.eq(t.trigger.__fields["<Done>k__BackingField"], 1, "marked done the way the game marks it")
    T.eq(#reported, 1, "our run is not reported back")
    T.eq(w:trigger_run(reported[1]), "done", "never twice")
    -- Whatever the partner sends, our game only runs what is an event trigger here too.
    item.trigger.__fields["<Done>k__BackingField"] = 0
    T.eq(w:trigger_run({ guid = "cccccccc-0000-0000-0000-000000000006", hash = mock.name_hash("Area_GiveKey") }),
        "refused", "an item hand-out is refused")
    T.eq(item.trigger.__fields["<Done>k__BackingField"], 0, "and left as it was")
    door.trigger.__fields["<Done>k__BackingField"] = 0
    T.eq(w:trigger_run({ guid = "cccccccc-0000-0000-0000-000000000003", hash = mock.name_hash("Door_Open") }),
        "refused", "a key trigger is refused")
    T.eq(w:trigger_run({ guid = "cccccccc-0000-0000-0000-0000000000ff", hash = 1 }), "missing", "not loaded here")
end)

T.run("location_preload_warp_and_fallback", function()
    local w, _, world = fresh()
    T.eq(w:preload_stage(43310), false, "cross-stage warps are experimental: off by default")
    w.game.settings.stage_travel = true
    local loc = w:location()
    T.eq(loc.chapter, 21100, "chapter")
    T.eq(loc.stage, 40200, "stage")
    T.near(loc.pos.x, 1, 1e-6, "position")
    T.eq(loc.playable, true, "playable")
    T.check(w:preload_stage(43310), "preload")
    T.eq(#world.scene_requests, 3, "prefecture, location and stage requested")
    local by = {}
    for _, r in ipairs(world.scene_requests) do by[r.mgr] = r end
    T.eq(by["chainsaw.PrefectureSceneManager"].id, 43, "prefecture id")
    T.eq(by["chainsaw.LocationSceneManager"].id, 43000, "location id")
    T.eq(by["chainsaw.EnvSceneManager"].id, 43310, "stage id")
    T.eq(by["chainsaw.EnvSceneManager"].status, 3, "status 3 in a real Nullable struct")
    T.eq(world.bad_nullable, nil, "never a boxed value where the game expects a Nullable")
    T.check(w:warp(43310, { x = 65, y = 6, z = -78 }, 0.5), "warp requested")
    T.eq(#world.warps, 1, "through CharacterManager.requestWarp")
    T.eq(world.warps[1].stage, 43310, "with a StageIdentifier for the target stage")
    T.near(world.warps[1].rot.y, math.sin(0.25), 1e-6, "facing")
    T.near(world.player.pos.x, 65, 1e-6, "player moved")
    T.eq(world.bad_nullable, nil, "position and rotation passed as Nullable structs")
    T.eq(w:location().stage, 43310, "and is in the new stage")
    T.check(w:warp(nil, { x = 1, y = 1, z = 1 }), "stage unknown: direct move")
    T.near(world.player.pos.x, 1, 1e-6, "moved exactly there")
    T.eq(#world.warps, 1, "no stage warp")
    world.player = nil
    world.chapter = 22100
    w.game:begin_frame() -- the player context is read once per game frame
    local loading = w:location()
    T.eq(loading.loading, true, "no player: loading")
    T.eq(loading.chapter, 22100, "chapter still known")
end)

-- The bell in the village ends chapter 1-1: the game changes chapter in a state of its own
-- (GameStateInGameChapterChange) behind a black screen, with the player's context alive.
T.run("the_games_own_transitions_are_seen", function()
    local w, game, world = fresh()
    T.eq(game:in_transition(), false, "normal play")
    T.eq(w:location().playable, true, "playable")
    T.check(game:save_can(), "can save")
    local calls = mock.calls
    game:in_transition()
    game:in_transition()
    T.eq(mock.calls, calls, "read once per frame")
    game:begin_frame()
    mock.chapter_change(21200, 7)
    game:begin_frame()
    T.eq(game:in_transition(), true, "changing chapter")
    T.eq(game:main_state().state, "chainsaw.GameStateInGameChapterChange", "which state")
    local loc = w:location()
    T.eq(loc.transition, true, "the location says so")
    T.eq(loc.loading, true, "counts as loading")
    T.eq(loc.playable, false, "not playable")
    T.eq(loc.chapter, 21200, "chapter still read")
    T.near(loc.pos.x, 1, 1e-6, "and where the player is")
    T.eq(game:read_player_state().transition, true, "in the player state too")
    local ok, why = game:save_can()
    T.eq(ok, false, "no save in the middle of it")
    T.check(why:find("chapter") ~= nil, "says why")
    local d = game:transition_detail()
    T.eq(d.state, "chainsaw.GameStateInGameChapterChange", "detail: state")
    T.eq(d.phase, 7, "detail: its phase")
    T.eq(d.jumper, 0, "detail: the campaign jumper")
    T.eq(d.saving, false, "detail: the save system")
    local dark = game:dark_fades()
    T.eq(#dark, 2, "two watched fades dark")
    T.eq(dark[1], 2, "CAMPAIGN_JUMPER")
    T.eq(dark[2], 4, "EVENT")
    world.fades[6] = true -- a gimmick's own fade is never watched
    T.eq(#game:dark_fades(), 2, "gimmick fade left alone")
    mock.end_chapter_change(false) -- back in play, but the black stays
    game:begin_frame()
    T.eq(game:in_transition(), false, "playing again")
    T.check(game:lift_fade(2, 0.5), "lift")
    T.eq(world.fade_ins[1].type, 2, "through FadeManager.requestFadeIn")
    T.near(world.fade_ins[1].seconds, 0.5, 1e-6, "with a short fade")
    T.eq(#game:dark_fades(), 1, "one left")
    T.eq(game:camera_busy(), false, "no camera of the game's running")
    world.main_mode_broken = true -- an unreadable state machine never stops the mod
    game:begin_frame()
    T.eq(game:in_transition(), false, "unknown counts as playing")
    world.main_mode_broken = nil
    world.game_state, world.player = "chainsaw.GameStateMainMenu", nil
    game:begin_frame()
    T.eq(game:in_transition(), false, "the menus are no transition (no player)")
end)

T.run("a_cutscene_camera_counts_as_busy", function()
    local w, game, world = fresh()
    w:cutscene_play({ camera = P.CAMERA.TIMELINE, id = 10012, screen = 3 })
    T.eq(game:camera_busy(), true, "a PlayWork in _Plays")
    mock.end_cutscene()
    T.eq(game:camera_busy(), false, "none once it ended")
end)

T.run("chapter_switch_rewrites_the_next_load", function()
    local w, _, world = fresh()
    w:install_hooks({})
    T.check(w:arm_chapter_switch(22200), "armed")
    mock.load_save(21100)
    T.eq(world.chapter, 22200, "loaded into the target chapter")
    T.eq(world.jump_sequence, 0, "the save's opening field untouched (a SpecialOrderType, read for new games only)")
    mock.load_save(21300)
    T.eq(world.chapter, 21300, "one-shot: later loads untouched")
    T.check(w:arm_chapter_switch(21300), "armed for the chapter the save is in")
    mock.load_save(21300)
    T.eq(world.chapter, 21300, "a save already in that chapter keeps its own checkpoint")
    T.eq(w:trigger_reload(21200), false, "no in-game reload without a save to load")
end)

-- Where a loaded game puts the player: the campaign jump's locators (docs/RESEARCH.md 3.34).
local HOST_SPOT = { chapter = 22200, stage = 46100, pos = { x = 300, y = -7, z = -10 }, rot = { x = 0, y = 0.6, z = 0, w = 0.8 } }

T.run("spawn_loads_the_partners_place", function()
    local w, game, world = fresh()
    local spot = HOST_SPOT
    w:install_hooks({ spawn_spot = function() return spot end })
    T.check(game:capabilities().spawn_at_partner.ok, "capability")
    T.check(w:arm_chapter_switch(22200) and w:arm_spawn(), "armed")
    T.check(w:spawn_armed(), "spawn armed")
    -- The client's save: Leon and Ashley together in the village, chapter 1-1.
    mock.load_save(21100, { stage = 40200, pos = { x = 5, y = 0, z = 5 }, ashley = { pos = { x = 6, y = 0, z = 5 } } })
    local order = mock.ingame_setup()
    T.eq(world.chapter, 22200, "the host's chapter")
    T.eq(world.stage, 46100, "the map loads around the host's stage")
    T.near(world.player.pos.x, 300, 1e-6, "the player appears where the host stands")
    T.near(world.player.pos.z, -10, 1e-6, "...")
    local entries = order.__fields.CharacterEntryList.list
    local ashley = entries[2].__fields.Locator.__fields
    T.eq(ashley._Stage, 46100, "Ashley, who was with the player, comes along")
    T.near(ashley._Position.x, 300, 1e-6, "next to the player")
    T.near(entries[1].__fields.Locator.__fields._Rotation.y, 0.6, 1e-6, "facing the host's way")
    T.eq(world.opening_played, false, "no chapter opening")
    T.eq(w:spawn_armed(), false, "one jump only")
    T.eq(w.spawn_last.moved, 2, "reported")
    -- The next load (a death, a checkpoint) is the game's own again.
    mock.load_save(22200, { stage = 46000, pos = { x = 1, y = 0, z = 1 } })
    mock.ingame_setup()
    T.eq(world.stage, 46000, "the save's own place")
    T.near(world.player.pos.x, 1, 1e-6, "...")
end)

T.run("spawn_leaves_a_character_elsewhere_and_skips_a_new_games_opening", function()
    local w, _, world = fresh()
    w:install_hooks({ spawn_spot = function() return HOST_SPOT end })
    mock.load_save(22200, { stage = 40200, pos = { x = 5, y = 0, z = 5 },
        ashley = { stage = 41000, pos = { x = 90, y = 0, z = 9 } } })
    world.initial_settings.__fields._SpecialJumpSequence = 4 -- a chapter start's opening
    T.check(w:arm_spawn(), "armed")
    local order = mock.ingame_setup(true) -- a new game at the chapter's start
    T.eq(world.stage, 46100, "at the host's place")
    T.eq(world.opening_played, false, "the opening is skipped: the host is past it")
    local ashley = order.__fields.CharacterEntryList.list[2].__fields.Locator.__fields
    T.eq(ashley._Stage, 41000, "a character somewhere else keeps its own place")
    T.near(ashley._Position.x, 90, 1e-6, "...")
    -- Not armed: the new game plays its opening.
    mock.ingame_setup(true)
    T.eq(world.opening_played, true, "the game's own start")
end)

T.run("spawn_without_a_known_place_or_too_late_changes_nothing", function()
    local w, _, world = fresh()
    local spot = nil
    w:install_hooks({ spawn_spot = function() return spot end })
    T.check(w:arm_spawn(), "armed")
    mock.load_save(21100, { stage = 40200, pos = { x = 5, y = 0, z = 5 } })
    mock.ingame_setup()
    T.eq(world.stage, 40200, "the save's own place")
    T.check(w.spawn_last ~= nil and w.spawn_last.moved == 0 and w.spawn_last.why ~= nil, "why reported")
    T.eq(w:spawn_armed(), false, "used up")
    spot = HOST_SPOT
    T.check(w:arm_spawn(10), "armed for 10 s")
    world.now = 11
    T.eq(w:spawn_armed(), false, "expired")
    mock.ingame_setup()
    T.eq(world.stage, 40200, "an expired spawn changes nothing")
    w:arm_spawn()
    w:disarm_spawn()
    mock.ingame_setup()
    T.eq(world.stage, 40200, "a disarmed one neither")
end)

T.run("in_game_reload_loads_the_save_then_leaves_for_the_setup", function()
    local w, game, world = fresh()
    local slot = 20
    w:install_hooks({ spawn_spot = function() return HOST_SPOT end, reload_slot = function() return slot end })
    game:install_save_hooks({ redirect = function(s) return s end, on_save = function() end,
        continue_slot = function() return nil end, on_menu = function() return false end })
    T.check(game:capabilities().ingame_load.ok, "capability: " .. tostring(game:capabilities().ingame_load.detail))
    slot = 7
    T.eq(w:trigger_reload(22200), false, "an empty slot is refused")
    T.eq(w.chapter_target, nil, "and nothing stays armed")
    slot = 20
    world.save_files[20] = { chapter = 21100, order = 1, stage = 40200, pos = { x = 5, y = 0, z = 5 } }
    T.check(w:trigger_reload(22200), "reload started")
    T.eq(world.play_load.slot, 20, "the slot marked for playing, the way Continue does")
    T.eq(world.play_load.auto, false, "not the autosave")
    T.eq(world.load_requests[1], 20, "load queued")
    T.eq(game:ingame_load(20), nil, "one at a time")
    T.eq(world.state_requests, nil, "still in game while the save is read")
    for _ = 1, 6 do
        world.now = world.now + 0.2
        mock.save_system_tick()
        game:ingame_load_tick()
    end
    local req = world.state_requests and world.state_requests[1]
    T.check(req ~= nil, "the game leaves once the save is read")
    T.eq(req.state, "chainsaw.GameStateInGameCleanup", "through the in-game cleanup")
    T.eq(req.next, "chainsaw.GameStateIngameSetup", "to the in-game setup")
    T.check(req.fix_exit and req.timeline_cleared, "the way the pause menu's Load Game leaves")
    T.eq(game.ingame_loading.phase, "left", "done")
    mock.run_ingame_reload()
    T.eq(world.chapter, 22200, "in the host's chapter")
    T.eq(world.stage, 46100, "at the host's place")
    T.near(world.player.pos.x, 300, 1e-6, "...")
    T.eq(w:reload_failed(), false, "no failure")
end)

T.run("an_in_game_load_that_cannot_be_read_gives_up", function()
    local w, game, world = fresh()
    w:install_hooks({ spawn_spot = function() return HOST_SPOT end, reload_slot = function() return 3 end })
    game:install_save_hooks({ redirect = function(s) return s end, on_save = function() end,
        continue_slot = function() return nil end, on_menu = function() return false end })
    world.save_files[3] = { chapter = 21100, order = 1 }
    world.load_fails = true
    T.check(w:trigger_reload(22200), "started")
    for _ = 1, 6 do
        world.now = world.now + 0.2
        mock.save_system_tick()
        game:ingame_load_tick()
    end
    T.eq(game.ingame_loading.phase, "failed", "gave up")
    T.eq(world.state_requests, nil, "the game never left")
    T.eq(w:reload_failed(), true, "travel can tell")
end)

T.run("missing_world_types_disable_features_quietly", function()
    local w, game = fresh({ no_world = true })
    local caps = game:capabilities()
    T.eq(caps.flags.ok, false, "no flags")
    T.eq(caps.cutscenes.ok, false, "no cutscenes")
    T.eq(caps.gimmicks.ok, false, "no gimmick table")
    T.eq(caps.chapter_switch.ok, false, "no chapter switch")
    T.eq(w:flag_set(G1, true), false, "set refused")
    T.check(w:flag_check(G1) == nil, "check unknown")
    T.check(w:flag_words_snapshot() == nil, "no snapshot")
    T.check(w:gimmicks_snapshot() == nil, "no gimmicks")
    T.eq(w:cutscene_play({ camera = 1, id = 1 }), false, "no replay")
    T.eq(w:trigger_run({ guid = G1, hash = 1 }), "missing", "no triggers")
    T.eq(w:arm_chapter_switch(21200), false, "no chapter switch")
    w:install_hooks({})
    T.eq(caps.flag_hooks.ok, false, "no hooks")
    local Pause = require("re4coop.game_pause")
    local pause = Pause.new(game, function() end)
    pause:set_active(true, "menus", true, 0)
    T.eq(pause:status().patched, 0, "no pause table: nothing patched, nothing broken")
end)

T.run("no_pause_neutralises_menu_pauses_only", function()
    local _, game, world = fresh()
    local Pause = require("re4coop.game_pause")
    local pause = Pause.new(game, function() end)
    T.eq(game:capabilities().no_pause.ok, true, "pause table found")
    T.eq(mock.pause_freezes(1), true, "the inventory pause freezes before")
    pause:set_active(true, "menus", false, 0)
    for _, t in ipairs({ 1, 2, 3, 4 }) do
        T.eq(mock.pause_freezes(t), false, "pause " .. t .. " neutralised")
    end
    for _, t in ipairs({ 5, 6, 100, 101 }) do
        T.eq(mock.pause_freezes(t), true, "pause " .. t .. " (event/loading/typewriter/movie) kept")
    end
    T.eq(pause:status().patched, 4, "four pause types neutralised")
    -- The game rebuilds its table (area load): applied again.
    world.pause_params[2] = mock.new("share.PauseManager.PauseParameter", { __fields = { TargetUpdate = 0xFF, TargetDraw = 1 } })
    pause:update(10)
    T.eq(mock.pause_freezes(2), false, "applied again after a rebuild")
    pause:set_active(false)
    T.eq(mock.pause_freezes(1), true, "restored when the session ends")
    T.eq(world.pause_params[1].__fields.TargetUpdate, 0xFF, "original value back")
    pause:set_active(true, "all", false, 20)
    T.eq(mock.pause_freezes(5), false, "mode all: events too")
    pause:set_active(true, "off", false, 21)
    T.eq(mock.pause_freezes(5), true, "mode off: everything restored")
end)

T.run("aggressive_mode_refuses_pause_requests", function()
    local _, game, world = fresh()
    local Pause = require("re4coop.game_pause")
    local pause = Pause.new(game, function() end)
    pause:set_active(true, "menus", true, 0)
    local pm = world.singletons["share.PauseManager"]
    pm:call("requestPause", 1, "Inventory")
    pm:call("requestPause", 5, "Event")
    T.check(world.active_pauses[1] == nil, "inventory pause refused")
    T.check(world.active_pauses[5] ~= nil, "event pause allowed")
    pause:set_active(false)
    pm:call("requestPause", 1, "Inventory")
    T.check(world.active_pauses[1] ~= nil, "normal again when off")
end)

T.run("enemy_puppet_transform_animation_and_ai", function()
    local _, game, world = fresh()
    local e = mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100)
    e.body.transform.wrot = { x = 0, y = math.sin(0.5), z = 0, w = math.cos(0.5) } -- facing 1 rad
    world.enemies = { e }
    local list = game:list_enemies()
    T.near(list[1].rot.y, math.sin(0.5), 1e-6, "rotation read from the body transform")
    T.check(list[1].layers == nil, "animation not read unless the partner shows the enemy")
    list = game:list_enemies(nil, function() return true end)
    T.eq(list[1].layers and list[1].layers[1].id, 1201, "animation read from motion layer 0")
    local id = list[1].id
    local rot = { x = 0, y = math.sin(-0.25), z = 0, w = math.cos(-0.25) }
    T.check(game:enemy_set_transform(id, { x = 9, y = 1, z = 2 }, rot), "placed")
    T.near(e.pos.x, 9, 1e-6, "moved")
    T.near(game:list_enemies()[1].rot.y, math.sin(-0.25), 1e-6, "turned")
    T.check(game:enemy_set_anim(id, { { bank = 4, id = 1300, frame = 2, speed = 1 } }), "animation set")
    local layer = mock.component(e.body, "via.motion.Motion").layers[1]
    T.eq(layer.motion, 1300, "changeMotion called with the owner's motion")
    T.check(game:enemy_set_puppet(id, true), "a puppet")
    T.eq(e.head.update_self, false, "the AI head stops updating")
    T.eq(game:capabilities().enemy_puppet.ok, true, "reported")
    T.check(game:enemy_kill(id), "killed")
    T.eq(e.head.update_self, true, "AI back on before the death")
    T.eq(e.hp, 0, "dead")
    local e2 = mock.make_character("chainsaw.Ch1c0z0Context", { x = 8, y = 0, z = 0 }, 100)
    world.enemies = { e, e2 }
    local id2 = game:list_enemies()[2].id
    game:enemy_set_puppet(id2, true)
    game:restore_enemies()
    T.eq(e2.head.update_self, true, "restored when the session ends")
end)

T.finish()
