-- game.lua against the mocked REFramework object model.
local T = require("testlib")
local mock = require("mock_reframework")

local function fresh_game(opts)
    package.loaded["re4coop.game"] = nil
    local world = mock.install(opts)
    world.player = mock.make_character("chainsaw.PlayerBaseContext", { x = 1, y = 2, z = 3 }, 1200)
    world.enemies = {
        mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100,
            { category = 2, kind = 1, group = 4100, index = 7 }),
        mock.make_character("chainsaw.Ch1d0z0Context", { x = 0, y = 0, z = 8 }, 300),
    }
    return require("re4coop.game").new(function() end), world
end

T.run("reads_player_state_and_skeleton", function()
    local game, world = fresh_game()
    world.player.aiming = true
    world.gui_event = true
    local st = assert(game:read_player_state())
    T.near(st.pos.x, 1, 1e-6, "pos.x")
    T.eq(st.hp, 1200, "hp")
    T.eq(st.max_hp, 1200, "max hp")
    T.eq(st.dead, false, "alive")
    T.eq(st.aiming, true, "aiming")
    T.eq(st.cutscene, true, "cutscene via GuiManager.get_IsPlayingEvent")
    -- 22 mock joints minus root, a finger and a twist helper.
    T.eq(#st.joints, 19, "big bones selected")
    T.eq(#st.parents, 19, "parents for each joint")
    T.eq(st.parents[1], 0, "Hip has no selected parent (root skipped)")
    T.eq(st.parents[2], 1, "Spine_0 -> Hip")
    local names = game.joint_sel.names
    local has_forearm = false
    for _, n in ipairs(names) do
        if n == "L_Forearm" then has_forearm = true end
        T.check(not n:find("Finger") and not n:find("Twist"), "excluded helper bone " .. n)
    end
    T.check(has_forearm, "forearm kept")
    -- R_Hand's parent chain: R_Hand -> R_Forearm, all selected.
    local idx = {}
    for i, n in ipairs(names) do idx[n] = i end
    T.eq(st.parents[idx["R_Hand"]], idx["R_Forearm"], "R_Hand -> R_Forearm")
    T.eq(st.parents[idx["L_Hand"]], idx["L_Forearm"], "L_Hand -> L_Forearm")

    world.player.hp = 0
    T.eq(game:read_player_state().dead, true, "dead when HitPoint.get_IsLive is false")
    world.player = nil
    T.check(game:read_player_state() == nil, "nil without a player (menus/loading)")
end)

T.run("lists_and_modifies_enemies_via_setter", function()
    local game, world = fresh_game()
    local list = assert(game:list_enemies())
    T.eq(#list, 2, "two enemies")
    T.eq(list[1].kind, "chainsaw.Ch1c0z0Context", "kind is the runtime context type")
    T.eq(list[2].max_hp, 300, "max hp")
    T.check(list[1].ctx ~= nil and list[1].ctx.group == 4100 and list[1].ctx.index == 7
        and list[1].ctx.kind == 1 and list[1].ctx.category == 2, "spawner ContextID read via get_SpawnerID")
    T.eq(list[2].ctx, nil, "enemy without a spawner")
    T.check(game:enemy_set_hp(list[1].id, 41.6), "set hp")
    T.eq(world.enemies[1].hp, 42, "rounded for the Int32 setter")
    T.check(game:capabilities().enemy_set_hp.ok, "writer verified after a successful write")
    T.check(game:capabilities().enemy_set_hp.detail:find("set_CurrentHitPoint", 1, true), "names the verified writer")
    T.check(game:enemy_kill(list[2].id), "kill")
    T.eq(world.enemies[2].hp, 0, "dead() called")
    T.check(game:enemy_set_position(list[1].id, { x = 9, y = 1, z = 9 }), "move")
    T.near(world.enemies[1].pos.x, 9, 1e-6, "moved")
    T.eq(world.enemies[1].warped, 1, "CharacterController.warp called")
    T.check(game:enemy_set_hp(123456, 5) == false, "unknown id is a no-op")
    T.eq(mock.decoy_calls, 0, "set_DefaultHitPoint (max HP) never touched")
end)

T.run("hp_writer_discovered_under_another_name", function()
    local game, world = fresh_game({ hp_setter_name = "setCurrentHP" })
    local list = game:list_enemies()
    T.check(not game:capabilities().enemy_set_hp.ok, "not trusted before a verified write")
    T.check(game:enemy_set_hp(list[1].id, 30), "write succeeds")
    T.eq(world.enemies[1].hp, 30, "HP written")
    T.check(game:capabilities().enemy_set_hp.detail:find("setCurrentHP", 1, true), "found by discovery")
    T.eq(mock.decoy_calls, 0, "decoy never used")
end)

T.run("broken_setter_is_rejected_and_working_one_kept", function()
    local game, world = fresh_game({ broken_setter = true, hp_setter_name = "setCurrentHP" })
    local list = game:list_enemies()
    for _ = 1, 4 do
        world.enemies[1].hp = 100
        T.check(game:enemy_set_hp(list[1].id, 55), "write lands via the working setter")
        T.eq(world.enemies[1].hp, 55, "HP really changed")
    end
    local detail = game:capabilities().enemy_set_hp.detail
    T.check(detail:find("verified method setCurrentHP", 1, true), "working setter verified: " .. detail)
end)

T.run("no_op_write_does_not_verify_anything", function()
    local game, world = fresh_game({ broken_setter = true, no_hp_setter = true, hp_field_name = "_Unrelated" })
    local list = game:list_enemies()
    T.check(game:enemy_set_hp(list[1].id, 100), "HP already 100: nothing to do")
    T.check(not game:capabilities().enemy_set_hp.ok, "a no-op write proves nothing")
    for _ = 1, 3 do
        T.check(not game:enemy_set_hp(list[1].id, 10), "broken setter reports failure")
    end
    T.eq(world.enemies[1].hp, 100, "HP untouched")
    T.check(game:capabilities().enemy_set_hp.detail:find("rejected", 1, true), "broken setter rejected")
end)

T.run("verified_writer_survives_refusals_and_rejected_ones_are_retried", function()
    local game, world = fresh_game()
    local list = game:list_enemies()
    T.check(game:enemy_set_hp(list[1].id, 80), "verified")
    -- Boss phase: the enemy ignores HP changes for a while.
    local setter = mock.classes["chainsaw.HitPoint"].methods.set_CurrentHitPoint
    local real = setter.fn
    setter.fn = function() end
    for _ = 1, 10 do
        world.enemies[1].hp = 100
        T.check(not game:enemy_set_hp(list[1].id, 50), "refused")
    end
    setter.fn = real
    T.check(game:enemy_set_hp(list[1].id, 40), "works again with the same writer")
    T.eq(world.enemies[1].hp, 40, "written")
    T.check(game:capabilities().enemy_set_hp.detail:find("refused", 1, true), "refusals reported")

    -- Before any verification: candidates set aside during a refusal phase come back later.
    local game2, world2 = fresh_game()
    local list2 = game2:list_enemies()
    local setter2 = mock.classes["chainsaw.HitPoint"].methods.set_CurrentHitPoint
    local real2 = setter2.fn
    setter2.fn = function() end
    for _ = 1, 3 do
        world2.enemies[1].hp = 100
        game2:enemy_set_hp(list2[1].id, 50)
    end
    T.check(game2:capabilities().enemy_set_hp.detail:find("rejected", 1, true), "set aside")
    setter2.fn = real2
    local ok = false
    for _ = 1, 70 do
        world2.enemies[1].hp = 100
        if game2:enemy_set_hp(list2[1].id, 50) then ok = true break end
    end
    T.check(ok, "retried and verified after the refusal phase")
    T.eq(world2.enemies[1].hp, 50, "written")
end)

T.run("falls_back_to_field_write_and_hp_zero_kill", function()
    local game, world = fresh_game({ no_hp_setter = true, no_kill_method = true })
    local list = game:list_enemies()
    T.check(game:enemy_set_hp(list[1].id, 10), "field write")
    T.eq(world.enemies[1].hp, 10, "hp written through field")
    local caps = game:capabilities()
    T.check(caps.enemy_set_hp.ok and caps.enemy_set_hp.detail:find("field", 1, true), "verified field writer")
    T.check(caps.enemy_kill.detail:find("fallback", 1, true), "kill falls back")
    T.check(game:enemy_kill(list[2].id), "kill via hp 0")
    T.eq(world.enemies[2].hp, 0, "dead")
end)

T.run("pickups_scan_and_remove", function()
    local game, world = fresh_game()
    local Game = require("re4coop.game")
    local cog = mock.make_drop_item(119235200, { x = 3, y = 0, z = 1 }, { category = 5, kind = 0, group = 9, index = 2 })
    mock.make_drop_item(112800000, { x = -4, y = 0, z = 2 }, nil, 6)
    local list = assert(game:list_pickups())
    T.eq(#list, 2, "two drop items")
    T.eq(list[1].item_id, 119235200, "ItemID from _ItemData")
    T.check(list[1].ctx and list[1].ctx.group == 9 and list[1].ctx.index == 2, "pickup ContextID")
    T.eq(list[2].count, 6, "Count from _ItemData")
    T.check(Game.is_key_item(119235200) and Game.is_key_item(119273600), "Wooden Cog / Boat Fuel are key items")
    T.check(not Game.is_key_item(112800000) and not Game.is_key_item(nil), "ordinary items are not")
    T.check(game:remove_pickup(list[1].id), "removed")
    T.check(cog.go.destroyed, "GameObject destroyed")
    T.eq(#game:list_pickups(), 1, "gone from the scene")
    T.check(not game:remove_pickup(list[1].id), "second removal is a no-op")
end)

T.run("hotkeys", function()
    local game = fresh_game()
    T.check(not game:is_key_down(0x75), "F6 up")
    mock.keys[0x75] = true
    T.check(game:is_key_down(0x75), "F6 down")
end)

T.run("teleport_and_area", function()
    local game, world = fresh_game()
    local ok = game:teleport_player({ x = 50, y = 0, z = 50 })
    T.check(ok, "teleport ok")
    T.near(world.player.pos.x, 50, 1e-6, "moved")
    T.eq(world.player.warped, 1, "warped")
    world.chapter = 7
    T.eq(game:area_name(), "7", "area from CampaignManager.get_CurrentChapter")
end)

T.run("survives_missing_types", function()
    local game, world = fresh_game()
    world.singletons["chainsaw.CharacterManager"] = nil
    T.check(game:read_player_state() == nil, "no player")
    T.check(game:list_enemies() == nil, "no enemies")
    -- A method that throws inside the game must not propagate.
    mock.classes["chainsaw.CharacterContext"].methods.get_Position.fn = function() error("engine exception") end
    world.singletons["chainsaw.CharacterManager"] = mock.new("chainsaw.CharacterManager")
    T.check(game:read_player_state() == nil, "exception swallowed")
end)

T.run("pickup_callbacks_hooked", function()
    local game = fresh_game()
    T.check(game:capabilities().pickup_hook.ok, "hook capability")
    T.eq(#mock.hooks.onAcceptPickup, 1, "onAcceptPickup hooked once")
    T.eq(#mock.hooks.onAcceptOccupied, 1, "onAcceptOccupied hooked once")
    T.eq(#game:take_pickup_events(), 0, "nothing yet")
    local herb = mock.make_drop_item(112800000, { x = 1, y = 0, z = 0 }, { category = 2, kind = 0, group = 12, index = 77 })
    mock.pickup(herb)
    local ev = game:take_pickup_events()
    T.eq(#ev, 1, "one event")
    T.eq(ev[1].key, "2:0:12:77", "item ContextID read from args[3]")
    T.eq(ev[1].user, "2:0:12:" .. game:read_context_id(mock.world.player).index, "user ContextID from args[2]")
    T.eq(ev[1].via, "onAcceptPickup", "callback name")
    T.eq(#game:take_pickup_events(), 0, "drained")
    mock.fire_hooks("onAcceptPickup", nil, nil) -- unreadable arguments are ignored
    T.eq(#game:take_pickup_events(), 0, "nil args ignored")
    for i = 1, 100 do mock.fire_hooks("onAcceptPickup", nil, mock.value_type({ _Group = 12, _Index = i })) end
    T.eq(#game:take_pickup_events(), 64, "queue is bounded")

    local level_item = mock.make_drop_item(0, { x = 2, y = 0, z = 0 }, { category = 3, kind = 0, group = 40210, index = 13 })
    level_item.real_item_id = 119235200
    local found
    for _, p in ipairs(game:list_pickups()) do
        if p.ctx and p.ctx.group == 40210 then found = p end
    end
    T.eq(found and found.item_id, 119235200, "ItemID 0 in save data: getItemID() used")

    local nohook = fresh_game({ no_hook = true })
    T.eq(nohook:take_pickup_events(), nil, "no hook: nil")
    T.check(not nohook:capabilities().pickup_hook.ok, "capability reports it")
end)

T.run("runtime_spawner_ids_are_ignored", function()
    local _, world = fresh_game()
    world.enemies[2].spawner = mock.value_type({ _Category = 0, _Kind = 0, _Group = 12, _Index = 55 })
    local game = require("re4coop.game").new(function() end)
    local list = game:list_enemies()
    T.check(list[1].ctx ~= nil, "level spawner kept")
    T.eq(list[2].ctx, nil, "runtime spawner dropped")
end)

-- Only what REFramework's json.dump_file can write: finite numbers, strings, booleans,
-- arrays and string-keyed tables.
local function check_json_safe(v, path)
    local t = type(v)
    if t == "number" then
        T.check(v == v and v ~= math.huge and v ~= -math.huge, "finite number at " .. path)
    elseif t == "table" then
        T.check(getmetatable(v) == nil, "plain table at " .. path)
        local n = #v
        for k, x in pairs(v) do
            local ok = type(k) == "string" or (math.type(k) == "integer" and k >= 1 and k <= n)
            T.check(ok, "key " .. tostring(k) .. " at " .. path)
            check_json_safe(x, path .. "." .. tostring(k))
        end
    else
        T.check(t == "string" or t == "boolean", t .. " at " .. path)
    end
end

T.run("research_dump", function()
    local game, world = fresh_game()
    world.stage = 40200
    world.enemies[1].stage = 40200
    world.partner = mock.make_character("chainsaw.Ch3a8z0Context", { x = 2, y = 0, z = 3 }, 600,
        { category = 1, kind = 0, group = 40200, index = 1 })
    mock.make_hate_controller("ch1c0z0_hate", { x = 5, y = 0, z = 0 }, world.player.body)
    local cog = mock.make_drop_item(119235200, { x = 3, y = 0, z = 1 }, { category = 3, kind = 0, group = 40200, index = 2 })
    local ok, runs = game:dump_types({ role = "host", items = { hook = "confirmed" } })
    T.check(ok, "dump written")
    T.eq(runs, 1, "first run")
    local dump = mock.files["re4coop_typedump.json"]
    local hp = dump and dump.types["chainsaw.HitPoint"]
    T.check(type(hp) == "table", "HitPoint described")
    local sig_found = false
    for _, sig in ipairs(hp.methods) do
        if sig == "void set_CurrentHitPoint(p1: System.Int32)" then sig_found = true end
    end
    T.check(sig_found, "full method signatures (return type, parameter types)")
    T.check(dump.types["chainsaw.Ch1c0z0Context"] ~= nil, "live enemy type included")
    T.check(dump.types["chainsaw.Ch3a8z0Context"] ~= nil, "live partner type included")
    T.eq(dump.types["chainsaw.HateControllerUserData"], "not found", "types missing in this build are listed as such")
    T.check(dump.live.singletons["chainsaw.CharacterManager"] == true, "singleton presence")
    T.check(dump.live.enemies[1].spawner_id.group == 4100, "enemy spawner IDs")
    T.check(dump.live.pickups[1].key_item == true, "pickup samples")
    T.check(dump.live.pickup_components and dump.live.pickup_components[2] == "chainsaw.DropItem", "pickup components")
    T.check(dump.live.enemy_components and dump.live.enemy_components[1] == "via.Transform", "enemy components")
    T.check(#dump.live.hp_writers > 0, "HP writer candidates listed")
    T.eq(dump.enums["chainsaw.CharacterKindID"].ch3a8z0, 380000, "enum values from static literals")
    T.eq(dump.enums["chainsaw.ContextID.EntityCategory"].StaticItem, 3, "ContextID categories")
    T.eq(dump.enums["chainsaw.ChapterID"], "not found", "missing enum listed as such")
    T.eq(dump.areas_seen[1], "1 / stage 40200", "area recorded")
    check_json_safe(dump, "typedump")

    local log = mock.files["re4coop_research_log.json"]
    T.eq(#log.runs, 1, "one run logged")
    local r = log.runs[1]
    T.eq(r.run, 1, "run number")
    T.eq(r.difficulty, 20, "difficulty")
    T.eq(r.stage_identifier._StageID, 40200, "stage identifier fields")
    T.eq(r.player.type, "chainsaw.PlayerBaseContext", "player sample")
    T.eq(r.player.motion.motion, 1201, "player motion layer 0")
    T.eq(r.partner.type, "chainsaw.Ch3a8z0Context", "partner from getPartnerContextRef")
    T.eq(r.partner.spawner, "1:0:40200:1", "partner spawner")
    T.check(r.partner.components ~= nil, "partner components")
    T.eq(r.enemies[1].spawner, "2:1:4100:7", "enemy spawner key")
    T.eq(r.enemies[1].stage, 40200, "enemy stage")
    T.check(r.enemies[1].id:find("^2:0:12:") ~= nil, "runtime enemy ID")
    T.eq(r.enemies[1].motion.bank, 100, "first enemy motion")
    T.eq(r.enemies[1].find_state, 1, "enemy find state")
    T.eq(r.hate[1].game_object, "GameObject ch1c0z0_hate", "HateController's GameObject")
    T.eq(r.hate[1].current_target._Target, "GameObject PlayerBase", "current target read")
    T.eq(r.pickups[1].stage, 40210, "pickup stage")
    T.eq(r.pickups[1].id, "3:0:40200:2", "pickup level ID")
    T.eq(r.pickup_hook.hooks, 2, "hooks installed")
    T.eq(r.session.items.hook, "confirmed", "session state included")
    check_json_safe(log, "research_log")

    -- Second run in another area: a different enemy type; the first run's types and log
    -- entry survive.
    mock.pickup(cog)
    world.chapter, world.stage = 2, 40300
    world.enemies = { mock.make_character("chainsaw.Ch1d0z0Context", { x = 1, y = 0, z = 1 }, 300) }
    mock.classes["chainsaw.Ch1c0z0Context"] = nil -- gone from this area's loaded types
    local ok2, runs2 = game:dump_types(nil)
    T.check(ok2, "second dump written")
    T.eq(runs2, 2, "second run")
    dump = mock.files["re4coop_typedump.json"]
    T.eq(dump.runs, 2, "run count kept")
    T.check(type(dump.types["chainsaw.Ch1c0z0Context"]) == "table", "type from the first area kept")
    T.check(dump.types["chainsaw.Ch1d0z0Context"] ~= nil, "new area's type added")
    T.eq(#dump.areas_seen, 2, "both areas listed")
    log = mock.files["re4coop_research_log.json"]
    T.eq(#log.runs, 2, "both runs logged")
    T.eq(log.runs[1].chapter, "1", "first area's snapshot kept")
    T.eq(log.runs[2].chapter, "2", "second area's snapshot")
    T.eq(log.runs[2].pickup_hook.calls, 1, "hook call counted")
    T.eq(log.runs[2].pickup_hook.recent[1].key, "3:0:40200:2", "recent pickup callback")
    check_json_safe(log, "research_log 2")

    -- A full log drops its oldest run.
    local full = {}
    for i = 1, 60 do full[i] = { run = 100 + i } end
    mock.files["re4coop_research_log.json"] = { runs = full }
    game:dump_types()
    log = mock.files["re4coop_research_log.json"]
    T.eq(#log.runs, 60, "log capped at 60 runs")
    T.eq(log.runs[1].run, 102, "oldest run dropped")
    T.eq(log.runs[60].run, 3, "newest run appended")
end)

T.finish()
