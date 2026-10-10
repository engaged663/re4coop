-- game.lua against the mocked REFramework object model.
local T = require("testlib")
local mock = require("mock_reframework")

local function fresh_game(opts)
    package.loaded["re4coop.game"] = nil
    local world = mock.install(opts)
    world.player = mock.make_character("chainsaw.PlayerBaseContext", { x = 1, y = 2, z = 3 }, 1200)
    world.enemies = {
        mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100),
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
    T.check(game:enemy_set_hp(list[1].id, 41.6), "set hp")
    T.eq(world.enemies[1].hp, 42, "rounded for the Int32 setter")
    T.check(game:enemy_kill(list[2].id), "kill")
    T.eq(world.enemies[2].hp, 0, "dead() called")
    T.check(game:enemy_set_position(list[1].id, { x = 9, y = 1, z = 9 }), "move")
    T.near(world.enemies[1].pos.x, 9, 1e-6, "moved")
    T.eq(world.enemies[1].warped, 1, "CharacterController.warp called")
    T.eq(game:capabilities().enemy_set_hp.ok, true, "capability reported")
    T.check(game:enemy_set_hp(123456, 5) == false, "unknown id is a no-op")
end)

T.run("falls_back_to_field_write_and_hp_zero_kill", function()
    local game, world = fresh_game({ no_hp_setter = true, no_kill_method = true })
    local caps = game:capabilities()
    T.check(caps.enemy_set_hp.ok and caps.enemy_set_hp.detail:find("field"), "uses backing field")
    T.check(caps.enemy_kill.detail:find("fallback"), "kill falls back")
    local list = game:list_enemies()
    T.check(game:enemy_set_hp(list[1].id, 10), "field write")
    T.eq(world.enemies[1].hp, 10, "hp written through field")
    T.check(game:enemy_kill(list[2].id), "kill via hp 0")
    T.eq(world.enemies[2].hp, 0, "dead")
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

T.run("type_dump", function()
    local game = fresh_game()
    game:list_enemies()
    T.check(game:dump_types(), "dump written")
    local dump = mock.files["re4coop_typedump.json"]
    T.check(dump and dump.types["chainsaw.HitPoint"], "HitPoint described")
    T.check(dump.types["chainsaw.Ch1c0z0Context"] ~= nil, "live enemy type included")
end)

T.finish()
