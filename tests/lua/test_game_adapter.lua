-- game.lua against the mocked REFramework object model.
local T = require("testlib")
local mock = require("mock_reframework")
local P = require("re4coop.protocol")

local clock_now = 0
local function clock() return clock_now end

local function fresh_game(opts)
    package.loaded["re4coop.game"] = nil
    local world = mock.install(opts)
    world.player = mock.make_player({ x = 1, y = 2, z = 3 })
    world.enemies = {
        mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100,
            { category = 2, kind = 1, group = 4100, index = 7 }),
        mock.make_character("chainsaw.Ch1d0z0Context", { x = 0, y = 0, z = 8 }, 300),
    }
    return require("re4coop.game").new(function() end, clock), world
end

local function index_of(list, name)
    for i, v in ipairs(list) do
        if v == name or (type(v) == "table" and v.name == name) then return i end
    end
    return nil
end

T.run("reads_player_state", function()
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
    T.check(st.rot ~= nil, "body rotation")
    world.player.hp = 0
    T.eq(game:read_player_state().dead, true, "dead when HitPoint.get_IsLive is false")
    world.player = nil
    T.check(game:read_player_state() == nil, "nil without a player (menus/loading)")
end)

T.run("describes_the_local_character", function()
    local game, world = fresh_game()
    local desc = assert(game:avatar_descriptor(0))
    T.eq(desc.char_id, "ch0a0z0", "character id from the body object's name")
    T.eq(desc.body_name, "ch0a0z0_body", "body name")
    T.eq(#desc.parts, 3, "three costume parts (body, face, hair); the weapon is gear")
    local body = desc.parts[index_of(desc.parts, "cha000_00")]
    T.eq(body.mesh, mock.MESH.body, "mesh path from Mesh.getMesh")
    T.eq(body.mdf, mock.MDF.body_dirty, "material path from Mesh.get_Material")
    T.eq(body.parent, 0, "attached to the body")
    T.check((body.flags & P.PART_FLAGS.SAME_JOINTS) ~= 0, "follows the body's joints")
    T.check((body.flags & P.PART_FLAGS.MAIN) ~= 0, "the body mesh carries the main skeleton")
    -- Joints: the whole body skeleton, then joints only the face and hair have.
    T.eq(desc.joints[1].name, "root", "skeleton first")
    T.eq(#desc.joints, #mock.LEON_JOINTS + 3 + 2, "body + Jaw/L_Eye/R_Eye + Hair_0/Hair_1")
    T.check(desc.joint_index["Jaw"] ~= nil and desc.joint_index["Hair_1"] ~= nil, "face and hair joints included")
    local hip = desc.joints[desc.joint_index["Hip"]]
    T.check((hip.flags & P.JOINT_FLAGS.TRANSLATE) ~= 0, "hip height travels")
    T.check((desc.joints[desc.joint_index["L_Hand"]].flags & P.JOINT_FLAGS.TRANSLATE) == 0, "hands rotate only")
    -- Cached between scans, rescanned after the interval.
    T.check(game:avatar_descriptor(0.5) == desc, "cached")
    clock_now = 2
    T.check(game:avatar_descriptor(2) == desc, "same object when nothing changed")
    mock.find("cha000_20")[1].components[2].mesh_path = "_chainsaw/character/ch/cha0/cha000/21/cha000_21.mesh"
    local changed = game:avatar_descriptor(4)
    T.check(changed ~= desc and changed.sig ~= desc.sig, "new description after a costume change")
    world.player = nil
    T.check(game:avatar_descriptor(6) == nil, "no player, no avatar")
end)

T.run("finds_the_weapon_and_reads_the_pose", function()
    local game, world = fresh_game()
    local desc = assert(game:avatar_descriptor(0))
    local gear = assert(game:gear_descriptor(0))
    T.eq(#gear.weapons, 1, "one weapon")
    T.eq(gear.weapons[1].name, "wp4000", "SG-09 R")
    T.eq(gear.weapons[1].mesh, mock.MESH.sg09, "weapon mesh for the fallback")
    T.eq(#gear.weapons[1].joints, #mock.WEAPON_JOINTS, "weapon joints")

    game:request_pose()
    game:capture_pose_late(0.1)
    local pose = assert(game:take_pose(0.1))
    T.eq(pose.sig, desc.sig, "pose made with the current description")
    T.eq(pose.gear_sig, gear.sig, "and gear")
    T.near(pose.root_pos.x, 1, 1e-6, "root position")
    local j = world.player.body.transform.joints[5]
    T.near(pose.q[5 * 4 - 3], j.lrot.x, 1e-9, "joint 5 local rotation x")
    T.near(pose.q[5 * 4], j.lrot.w, 1e-9, "joint 5 local rotation w")
    T.eq(#pose.q, #desc.joints * 4, "every joint")
    T.eq(#pose.tpos >= 1, true, "translations")
    local w = pose.weapons[1]
    T.eq(w.attach, desc.joint_index["R_WepHand"], "weapon glued to the R_WepHand joint")
    T.near(w.pos.z, 0.12, 1e-6, "offset from the hand")
    T.near(w.rot.y, 0.7071068, 1e-6, "rotation from the hand")
    T.eq(w.flags, P.WEAPON_FLAGS.VISIBLE, "drawn")
    T.eq(#w.q, #mock.WEAPON_JOINTS * 4, "weapon joints (slide...)")
    world.player.weapon.draw_self = false
    game:request_pose()
    game:capture_pose_late(0.2)
    T.eq(game:take_pose(0.2).weapons[1].flags, 0, "holstered/hidden weapon")

    -- Not parented to the player: found in the scene when within reach.
    mock.set_parent(world.player.weapon.transform, nil)
    world.player.weapon.transform.wpos = mock.vec(1.5, 2, 3)
    world.player.weapon.draw_self = true
    clock_now = 10
    local g2 = assert(game:gear_descriptor(10))
    T.eq(g2.weapons[1] and g2.weapons[1].name, "wp4000", "scene lookup")
    game:request_pose()
    game:capture_pose_late(10)
    local p2 = game:take_pose(10)
    T.eq(p2.weapons[1].attach, 0, "free-standing weapon")
    T.near(p2.weapons[1].pos.x, 0.5, 1e-6, "relative to the root")
end)

T.run("never_reads_joints_of_a_rebuilt_skeleton", function()
    local game, world = fresh_game()
    assert(game:avatar_descriptor(0))
    T.check(game:read_pose(0) ~= nil, "pose")
    mock.destroy(mock.find("cha000_20")[1]) -- costume change removes the hair part
    T.check(game:read_pose(0.1) == nil, "part gone: no read through its old joints")
    T.check(game.avatar == nil, "rescan requested")
    local desc = assert(game:avatar_descriptor(0.2))
    T.eq(#desc.parts, 2, "rescanned without the hair")
    T.check(game:read_pose(0.2) ~= nil, "reads again")
    mock.add_joints(world.player.body.transform, { "root", "Hip" }) -- skeleton rebuilt
    T.check(game:read_pose(0.3) == nil, "body skeleton changed: no read")
end)

T.run("pose_read_in_place_when_prepare_rendering_is_missing", function()
    local game = fresh_game()
    assert(game:avatar_descriptor(0))
    game:request_pose()
    T.check(game:take_pose(0) ~= nil, "no PrepareRendering seen yet: read directly")
    game:capture_pose_late(1.0)
    game:request_pose()
    T.check(game:take_pose(1.1) == nil, "waits for the end-of-frame capture")
end)

T.run("captures_sounds_effects_and_shots", function()
    local game, world = fresh_game()
    game:avatar_descriptor(0)
    game:gear_descriptor(0)
    game:set_capture(true)
    T.eq(game:capabilities().sound_mirror.ok, true, "trigger overloads hooked")
    T.eq(game:capabilities().effect_mirror.ok, true, "requestEffect overloads hooked")
    T.eq(game:capabilities().shots.ok, true, "chainsaw.Gun.shoot hooked")

    local ctx = world.player
    clock_now = 1.0
    ctx.sound:call("trigger(System.UInt32)", 1234)
    ctx.sound:call("trigger(System.UInt32, via.GameObject)", 99, ctx.body)
    ctx.gun_sound:call("trigger(via.GameObject, System.UInt32, via.GameObject, System.UInt32, via.wwise.RequestInfo, System.Boolean, System.Boolean, System.Boolean, System.Int32)",
        ctx.weapon, 555, ctx.weapon, 0, mock.new("via.wwise.RequestInfo"), false, false, false, 0)
    ctx.gun_effect:call("requestEffect(System.UInt32, System.UInt32)", 15, 3)
    ctx.gun_effect:call("requestEffect(System.Collections.Generic.IEnumerable`1<via.effect.script.EPVStandardData.Element>, via.GameObject)",
        mock.new("System.Object"), ctx.weapon)
    ctx.gun:call("shoot")
    ctx.gun:call("shoot") -- same frame: one shot
    -- Somebody else's sound container is not ours.
    local other = mock.make_go("ch1c0z0_body")
    mock.add_component(other, "via.wwise.WwiseContainer"):call("trigger(System.UInt32)", 8)

    local ev = game:drain_events()
    T.eq(#ev, 5, "four mirrored calls + one shot; the list overload and the enemy's sound are skipped")
    T.eq(ev[1].kind, P.EVENT.CALL, "call")
    T.eq(ev[1].part, P.REF.BODY, "on the body")
    T.eq(ev[1].comp_type, P.hash("chainsaw.WwiseContainerApp"), "component type")
    T.eq(ev[1].comp_idx, 1, "first container of that type")
    T.eq(ev[1].method, P.hash("via.wwise.WwiseContainer::trigger(System.UInt32)"), "overload")
    T.eq(ev[1].args[1].value, 1234, "trigger id")
    T.eq(ev[1].time, 1.0, "timestamp")
    T.eq(ev[2].args[2].tag, P.ARG.OBJ, "GameObject argument travels as a reference")
    T.eq(ev[2].args[2].value, P.REF.BODY, "the body")
    T.eq(ev[3].part, P.REF.WEAPON_BASE + 1, "weapon slot 1")
    T.eq(ev[3].method, 0, "RequestInfo cannot travel: replayed with the simplest overload")
    T.eq(ev[3].args[1].value, 555, "trigger id kept")
    T.eq(ev[4].args[1].value, 15, "effect container id")
    T.eq(ev[4].args[2].value, 3, "effect element id")
    T.eq(ev[5].kind, P.EVENT.SHOT, "shot")
    T.eq(ev[5].slot, 1, "from slot 1")
    T.eq(game.counters.calls_skipped, 1, "list-based effect overload skipped")
    T.eq(#game:drain_events(), 0, "drained")

    -- The head (logic) object's voice container.
    ctx.voice:call("trigger(System.UInt32)", 4242)
    local v = game:drain_events()
    T.eq(v[1].part, P.REF.HEAD, "head reference")

    game:set_capture(false)
    ctx.sound:call("trigger(System.UInt32)", 1)
    ctx.gun:call("shoot")
    T.eq(#game:drain_events(), 0, "nothing captured while not connected")
end)

T.run("finds_prefabs", function()
    local game = fresh_game()
    T.eq(game:find_body_prefab("ch0a0z0"), mock.PREFAB.leon_body, "Leon")
    T.eq(game:find_body_prefab("ch3a8z0"), mock.PREFAB.ada_body, "Ada lives in the _mercenaries content")
    T.check(game:find_body_prefab("ch9z9z9") == nil, "unknown character")
    T.check(game:find_body_prefab("../../evil") == nil, "path characters rejected")
    T.eq(game:find_weapon_prefab("wp4000"), mock.PREFAB.sg09, "weapon")
    T.eq(game:find_weapon_prefab("wp4000_mc"), mock.PREFAB.sg09_mc, "Mercenaries variant")
    T.eq(game:find_weapon_prefab("wp4000_ao"), mock.PREFAB.sg09, "missing variant falls back to the base weapon")
    T.check(game:find_weapon_prefab("knife") == nil, "not a weapon id")
    T.eq(game:muzzle_flash_prefab(), mock.PREFAB.muzzle, "muzzle flash effect")
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
    T.check(game:avatar_descriptor(0) == nil, "no avatar")
    -- A method that throws inside the game must not propagate.
    mock.classes["chainsaw.CharacterContext"].methods.get_Position.fn = function() error("engine exception") end
    world.singletons["chainsaw.CharacterManager"] = mock.new("chainsaw.CharacterManager")
    T.check(game:read_player_state() == nil, "exception swallowed")
    -- Without sdk.hook the mirrors report it instead of failing.
    local saved = sdk.hook
    sdk.hook = nil
    local g2 = require("re4coop.game").new(function() end, clock)
    g2:set_capture(true)
    sdk.hook = saved
    T.eq(g2:capabilities().sound_mirror.ok, false, "no hook support reported")
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
    game:avatar_descriptor(0)
    local ok, runs = game:dump_types({ role = "host", items = { hook = "confirmed" }, partner_model = { state = "idle" } })
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
    T.check(type(dump.player) == "table" and #dump.player.objects >= 5, "player hierarchy described")
    T.eq(dump.player.objects[1].name, "ch0a0z0_body", "body first")
    T.check(#dump.player.pose_joints > 0, "pose joint names")
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
    T.eq(r.hate[1].current_target._Target, "GameObject ch0a0z0_body", "current target read")
    T.eq(r.pickups[1].stage, 40210, "pickup stage")
    T.eq(r.pickups[1].id, "3:0:40200:2", "pickup level ID")
    T.eq(r.pickup_hook.hooks, 2, "hooks installed")
    T.eq(r.session.items.hook, "confirmed", "session state included")
    T.eq(r.session.partner_model.state, "idle", "partner model status included")
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
