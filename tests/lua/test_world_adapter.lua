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
    local Game = require("re4coop.game")
    local game = Game.new(function() end, function() return 0 end)
    local World = require("re4coop.game_world")
    local w = World.new(game, function() end)
    return w, game, world
end

T.run("probes_find_the_world_api", function()
    local w, game = fresh()
    local caps = game:capabilities()
    for _, name in ipairs({ "flags", "flag_words", "gimmicks", "objects", "cutscenes", "warp", "chapter_switch" }) do
        T.check(caps[name] and caps[name].ok, name .. " capability: " .. tostring(caps[name] and caps[name].detail))
    end
    T.eq(w.flag_set_m.name, "requestSetFlag", "flag setter")
    T.eq(w.flag_check_m.name, "checkFlag", "flag check")
    T.eq(w.cs_play_ms[1].name, "requestPlay", "simple cutscene request preferred")
    T.eq(#w.cs_play_ms, 1, "a request with a complex parameter is not replayable")
    for _, i in ipairs(w.cs_hook_ms) do
        T.check(i.name ~= "requestPreloadPlay", "a preload is not a cutscene start")
        T.check(i.name ~= "isPlaying", "queries are not hooked")
        T.check(i.name ~= "requestStop", "stops are not hooked")
    end
    for _, i in ipairs(w.flag_hook_ms) do
        T.check(i.name ~= "setFlagWatch", "only real flag setters are hooked")
    end
    T.eq(#w.flag_hook_ms, 1, "requestSetFlag hooked")
end)

T.run("flag_hooks_report_game_changes_but_not_ours", function()
    local w, game, world = fresh()
    local seen = {}
    w:install_hooks({ on_flag = function(g, v) seen[#seen + 1] = { g, v } end })
    T.eq(game:capabilities().flag_hooks.ok, true, "hooks installed")
    mock.game_set_flag(G1, true)
    T.eq(#seen, 1, "game change reported")
    T.eq(seen[1][1], G1, "guid text")
    T.eq(seen[1][2], true, "value")
    T.eq(w:flag_check(G1), true, "flag is set")
    T.check(w:flag_set(G2, true), "set through requestSetFlag")
    T.eq(#seen, 1, "our own set is not reported")
    T.eq(w:flag_check(G2), true, "applied")
    T.eq(world.flag_groups[2].words[1], 0x80000000, "bit 31 of the second group")
    mock.game_set_flag(G1, false)
    T.eq(seen[2][2], false, "clears are reported too")
    T.eq(world.watch_calls, nil, "the flag watcher decoy was never called")
end)

T.run("flag_words_snapshot_and_full_apply", function()
    local w, _, world = fresh()
    world.flag_groups[1].words = { 7, 8, 9, 10 }
    local snap = w:flag_words_snapshot()
    T.eq(snap.Main[3], 9, "words read from the save object (boxed elements)")
    T.eq(#snap.Chapter, 2, "second group")
    T.check(w:flag_words_apply_full({ { name = "Main", words = { 1, 2, 0xFFFFFFFF, 10 } }, { name = "Nope", words = { 1 } } }),
        "full apply")
    T.eq(world.flag_groups[1].words[3], 0xFFFFFFFF, "word written back through loadGameSaveData")
    T.eq(world.flag_groups[1].words[1], 1, "first word")
    w:flag_words_apply("Chapter", 0, 0x10, 0)
    w:flag_words_apply("Main", 1, 0, 0x2)
    w:update()
    T.eq(world.flag_groups[2].words[1], 0x10, "queued set applied")
    T.eq(world.flag_groups[1].words[2], 0, "queued clear applied")
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
    -- Change it and add one the local table does not have yet.
    local changed = { ctx = item.ctx, attr = "\9\9\9\9", triggers = { { id = 77, done = 1 }, { id = 78, done = 1 } },
        detected = false, acc = { { kind = 2, value = 3 } } }
    local added = { ctx = { category = 1, kind = 1, group = 11, index = 2 }, attr = "\5", triggers = {}, detected = true, acc = {} }
    T.check(w:gimmicks_apply({ changed, added }), "applied")
    T.eq(world.gimmick_loads, 1, "one load call")
    local g = world.gimmick_table["1:1:10:0"]
    T.eq(#g.attr, 4, "attr resized")
    T.eq(g.attr[1], 9, "attr value")
    T.eq(#g.triggers, 2, "triggers")
    T.eq(g.detected, false, "detected cleared")
    T.eq(g.acc[1].value, 3, "accessory")
    T.check(world.gimmick_table["1:1:11:2"] ~= nil, "new record created")
    T.eq(world.gimmick_table["1:1:11:2"].attr[1], 5, "new record's attr")
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
    T.eq(calls, 3, "60 records per call")
    local n = 0
    for _ in pairs(snap) do n = n + 1 end
    T.eq(n, 150, "all records")
end)

T.run("gimmick_changes_are_announced", function()
    local w = fresh()
    T.eq(w:gimmicks_dirty(), false, "nothing yet")
    mock.set_gimmick({ category = 1, kind = 0, group = 5, index = 1 }, { 1 }, nil, true) -- the game: pushDirtyList
    T.eq(w:gimmicks_dirty(), true, "announced through the pushDirtyList hook")
    T.eq(w:gimmicks_dirty(), false, "once")
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
    T.eq(crow.__fields._Routine, 2, "crow killed through requestDead")
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000003", P.OBJECT_EVENT.DESTROYED, -1), "done", "bottle")
    T.eq(bottle.owner.draw_self, false, "bottle hidden as a last resort")
    box.__fields._Routine = 0
    w:objects_scan()
    T.eq(w:object_apply("aaaaaaaa-0000-0000-0000-000000000001", P.OBJECT_EVENT.DESTROYED, 2), "done", "box")
    T.eq(box.__fields._Routine, 2, "box enters the partner's terminal routine (plays its own break)")
end)

T.run("cutscene_hooks_play_and_current_id", function()
    local w, _, world = fresh()
    local seen = {}
    w:install_hooks({ on_cutscene = function(id, m) seen[#seen + 1] = { id, m } end })
    mock.start_cutscene(10157)
    T.eq(#seen, 1, "the game's cutscene reported")
    T.eq(seen[1][1], 10157, "id")
    T.eq(seen[1][2], "requestPlay", "method")
    T.eq(w:cutscene_playing(), 10157, "current id read")
    world.timeline_preloads = world.preloaded_events
    world.singletons["chainsaw.TimelineEventManager"]:call("requestPreloadPlay", 20130)
    T.eq(#seen, 1, "a preload is not reported")
    mock.end_cutscene()
    T.check(w:cutscene_playing() == nil, "not playing")
    T.check(w:cutscene_play(20130, "requestPlay"), "replayed")
    T.eq(world.played_events[#world.played_events], 20130, "the game played it")
    T.eq(#seen, 1, "our replay is not reported as a local trigger")
end)

T.run("location_preload_warp_and_fallback", function()
    local w, _, world = fresh()
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
    T.eq(by["chainsaw.EnvSceneManager"].status, 3, "status 3 (boxed Int32)")
    T.check(w:warp(43310, { x = 65, y = 6, z = -78 }, 0.5), "warp requested")
    T.eq(#world.warps, 1, "through CharacterManager.requestWarp")
    T.eq(world.warps[1].stage, 43310, "with a StageIdentifier for the target stage")
    T.near(world.warps[1].rot.y, math.sin(0.25), 1e-6, "facing")
    T.near(world.player.pos.x, 65, 1e-6, "player moved")
    T.eq(w:location().stage, 43310, "and is in the new stage")
    T.check(w:warp(nil, { x = 1, y = 1, z = 1 }), "stage unknown: direct move")
    T.near(world.player.pos.x, 1, 1e-6, "moved exactly there")
    T.eq(#world.warps, 1, "no stage warp")
    world.player = nil
    world.chapter = 22100
    local loading = w:location()
    T.eq(loading.loading, true, "no player: loading")
    T.eq(loading.chapter, 22100, "chapter still known")
end)

T.run("chapter_switch_rewrites_the_next_load", function()
    local w, _, world = fresh()
    w:install_hooks({})
    T.check(w:arm_chapter_switch(22200), "armed")
    mock.load_save(21100)
    T.eq(world.chapter, 22200, "loaded into the target chapter")
    T.eq(world.jump_sequence, 10, "with the chapter's jump sequence")
    mock.load_save(21300)
    T.eq(world.chapter, 21300, "one-shot: later loads untouched")
    T.check(w:arm_chapter_switch(21300), "armed for the chapter the save is in")
    mock.load_save(21300)
    T.eq(world.jump_sequence, 0, "a save already in that chapter keeps its own checkpoint")
    T.check(w:trigger_reload(), "reload")
    T.eq(world.game_over_requests, 1, "game over requested")
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
    T.eq(w:cutscene_play(1, "x"), false, "no replay")
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
    for _, t in ipairs({ 1, 2, 3, 4, 100 }) do
        T.eq(mock.pause_freezes(t), false, "pause " .. t .. " neutralised")
    end
    for _, t in ipairs({ 5, 6, 101 }) do
        T.eq(mock.pause_freezes(t), true, "pause " .. t .. " (event/loading/movie) kept")
    end
    T.eq(pause:status().patched, 5, "five pause types neutralised")
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

T.run("enemy_mirroring_facing_animation_and_ai", function()
    local _, game, world = fresh()
    local e = mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100)
    e.body.transform.wrot = { x = 0, y = math.sin(0.5), z = 0, w = math.cos(0.5) } -- facing 1 rad
    world.enemies = { e }
    local list = game:list_enemies()
    T.near(list[1].yaw, 1.0, 1e-6, "facing read from the body transform")
    T.check(list[1].motion == nil, "animation not read unless mirroring needs it")
    game.read_motion = true
    list = game:list_enemies()
    T.eq(list[1].motion and list[1].motion.id, 1201, "animation read from motion layer 0")
    T.eq(list[1].motion.bank, 100, "bank")
    local id = list[1].id
    T.check(game:enemy_set_transform(id, { x = 9, y = 1, z = 2 }, -0.5), "mirrored")
    T.near(e.pos.x, 9, 1e-6, "moved")
    T.near(game:list_enemies()[1].yaw, -0.5, 1e-6, "turned")
    T.eq(e.warped, 1, "CharacterController warped so physics does not pull it back")
    T.check(game:enemy_set_motion(id, { bank = 4, id = 1300, frame = 2 }), "animation set")
    local layer = mock.component(e.body, "via.motion.Motion").layers[1]
    T.eq(layer.motion, 1300, "changeMotion called with the owner's motion")
    T.check(game:enemy_set_ai(id, false), "AI off")
    T.eq(e.head.update_self, false, "the AI head stops updating")
    T.eq(game:capabilities().enemy_ai_switch.ok, true, "reported")
    T.check(game:enemy_kill(id), "killed")
    T.eq(e.head.update_self, true, "AI back on before the death")
    T.eq(e.hp, 0, "dead")
    local e2 = mock.make_character("chainsaw.Ch1c0z0Context", { x = 8, y = 0, z = 0 }, 100)
    world.enemies = { e, e2 }
    local id2 = game:list_enemies()[2].id
    game:enemy_set_ai(id2, false)
    game:restore_enemy_ai()
    T.eq(e2.head.update_self, true, "restored when the session ends")
end)

T.finish()
