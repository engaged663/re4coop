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
        -- Placed by a level spawn param: its ContextID is the enemy's own.
        mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100,
            { category = 0, kind = 0, group = 4100, index = 7 }),
        -- Created at runtime (group 1): no identity that holds across machines.
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
    T.check(game:read_player_state() ~= nil, "the player context is read once per frame")
    game:begin_frame()
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
    game:begin_frame()
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
    T.eq(list[1].uid, mock.context_code({ category = 0, kind = 0, group = 4100, index = 7 }),
        "level enemy: uid = the code of its own ContextID")
    T.eq(list[2].uid, nil, "runtime enemy: no uid")
    T.check(game:capabilities().enemy_uid.ok, "reported: " .. game:capabilities().enemy_uid.detail)
    T.check(game:enemy_set_hp(list[1].id, 41.6), "set hp")
    T.eq(world.enemies[1].hp, 42, "rounded for the Int32 setter")
    T.check(game:capabilities().enemy_set_hp.ok, "writer verified after a successful write")
    T.check(game:capabilities().enemy_set_hp.detail:find("set_CurrentHitPoint", 1, true), "names the verified writer")
    T.check(game:enemy_kill(list[2].id), "kill")
    T.eq(world.enemies[2].hp, 0, "dead() called")
    T.check(game:enemy_set_hp(123456, 5) == false, "unknown id is a no-op")
    T.eq(mock.decoy_calls, 0, "set_DefaultHitPoint (max HP) never touched")
end)

T.run("enemy_identity_is_its_level_context_id", function()
    local _, world = fresh_game()
    world.enemies[3] = mock.make_character("chainsaw.Ch1c0z0Context", { x = 1, y = 0, z = 1 }, 100,
        { category = 0, kind = 0, group = 12, index = 312 }) -- the IDs the research dump saw
    world.enemies[4] = mock.make_character("chainsaw.Ch1c0z0Context", { x = 2, y = 0, z = 1 }, 100,
        { category = 2, kind = 0, group = 12, index = 9 })  -- not a character ID
    local game = require("re4coop.game").new(function() end)
    local list = game:list_enemies()
    T.eq(list[3].uid, mock.context_code({ category = 0, kind = 0, group = 12, index = 312 }),
        "group 12 is level data, not a runtime counter")
    T.eq(list[4].uid, nil, "a non-character ID is not an identity")
    T.eq(list[2].uid, nil, "group 1 (generateDynamicContextID) is not either")
    -- A second machine running the same level reads the same uid for the same enemy.
    local _, world2 = fresh_game()
    local game2 = require("re4coop.game").new(function() end)
    T.eq(game2:list_enemies()[1].uid, list[1].uid, "same enemy, same uid on another machine")
    T.check(world2 ~= world, "really another world")
end)

T.run("erasing_an_enemy_the_partner_already_killed", function()
    local game, world = fresh_game()
    local list = game:list_enemies()
    local ctx = world.enemies[1]
    T.check(game:enemy_set_puppet(list[1].id, true), "a puppet: AI off")
    T.check(game:enemy_erase(list[1].id), "erased")
    T.eq(ctx.eliminated, nil, "never CharacterContext.eliminate(): that one would end up in the save")
    T.eq(ctx.spawn_param.invalid, true, "CharacterSpawnParam.invalidateSpawn(true)")
    T.eq(ctx.despawned, true, "the game despawned it")
    T.eq(ctx.head.update_self, true, "its pooled head was switched back on first")
    T.eq(ctx.hp, 100, "never killed: no death, no corpse, no loot")
    T.check(game:capabilities().enemy_erase.ok, "reported")
    T.eq(#game:list_enemies(), 1, "gone from the list")
    -- A runtime enemy has no spawn param: the caller kills it instead.
    T.check(not game:enemy_erase(list[2].id), "no spawn param: not erased")
    T.eq(world.enemies[1].hp, 300, "and not touched")
    -- The partner's world brings it back (their checkpoint reload): it may spawn here again.
    T.eq(game:enemy_restore_spawns(nil), 1, "one spawn param restored")
    T.eq(ctx.spawn_param.invalid, false, "invalidateSpawn(false)")
    T.eq(game:enemy_restore_spawns(nil), 0, "only once")
end)

T.run("a_head_switched_off_goes_back_to_the_pool_switched_on", function()
    local game, world = fresh_game()
    local list = game:list_enemies()
    local ctx = world.enemies[1]
    T.check(game:enemy_set_puppet(list[1].id, true), "a puppet")
    T.eq(ctx.head.update_self, false, "head off")
    local fsm = mock.component(ctx.body, "via.motion.MotionFsm2")
    T.eq(fsm.enabled, false, "its animation state machine off")
    T.check(game:capabilities().enemy_puppet.ok, "reported")
    -- The area unloads: the game despawns the enemy, its head goes back to the pool unlinked.
    mock.despawn(ctx)
    game:list_enemies()
    -- Switching an unlinked head on makes CharacterHeadUpdater.update read a null Context
    -- (the crash at re4.exe+0x1273425): it stays off while it sits in the pool.
    T.eq(ctx.head.update_self, false, "not switched on while in the pool")
    T.eq(next(game.puppets), nil, "forgotten")
    game:begin_frame()
    T.eq(ctx.head.update_self, false, "still unlinked: still off")
    -- The game gives the head to its next enemy: it thinks again.
    mock.relink_head(ctx.head_updater, world.enemies[1])
    game.heads_checked = nil
    game:begin_frame()
    T.eq(ctx.head.update_self, true, "the next enemy that gets this head will think")
    T.eq(next(game.parked_heads), nil, "no longer parked")
    -- The same through a reload.
    local list2 = game:list_enemies()
    T.check(game:enemy_set_puppet(list2[1].id, true), "another one off")
    local head2 = world.enemies[1].head
    game:on_reload()
    T.eq(head2.update_self, true, "restored on reload")
    -- The context got another head while ours was off: ours runs again when the puppet ends.
    local list3 = game:list_enemies()
    local ctx3 = world.enemies[1]
    T.check(game:enemy_set_puppet(list3[1].id, true), "off")
    local old_head = ctx3.head
    ctx3.head = mock.make_go("Ch1d0z0_head")
    T.check(game:enemy_set_puppet(list3[1].id, false), "back to the game")
    T.eq(old_head.update_self, true, "the head we switched off runs again")
    -- Session ends while a switched-off head is already unlinked: it is parked, not woken.
    local list4 = game:list_enemies()
    local ctx4 = world.enemies[1]
    T.check(game:enemy_set_puppet(list4[1].id, true), "off again")
    ctx4.head_updater.context = nil
    game:restore_enemies()
    T.eq(ctx4.head.update_self, false, "an unlinked head is never woken")
    T.check(next(game.parked_heads) ~= nil, "parked until the game links it")
end)

T.run("puppets_take_the_owners_transform_and_animation", function()
    local game, world = fresh_game()
    local e = world.enemies[1]
    e.body.transform.wrot = { x = 0, y = math.sin(0.5), z = 0.1, w = math.cos(0.5) }
    local list = game:list_enemies()
    T.near(list[1].rot.y, math.sin(0.5), 1e-6, "full rotation read from the body transform")
    T.near(list[1].rot.z, 0.1, 1e-6, "not just the heading")
    T.eq(list[1].layers, nil, "animation not read unless the partner shows it")
    list = game:list_enemies(nil, function() return true end)
    T.eq(#list[1].layers, 2, "two animation layers read")
    T.eq(list[1].layers[1].id, 1201, "motion of layer 0")
    T.eq(list[1].layers[1].bank, 100, "its bank")
    T.near(list[1].layers[1].frame, 12.5, 1e-6, "its frame")
    T.eq(list[1].layers[1].speed, 1.0, "its speed")
    T.eq(list[1].layers[2].id, 50, "layer 1")
    T.eq(list[1].hidden, false, "drawn")
    local id = list[1].id
    local rot = { x = 0, y = math.sin(-0.25), z = 0, w = math.cos(-0.25) }
    T.check(game:enemy_set_transform(id, { x = 9, y = 1, z = 2 }, rot), "placed")
    T.near(e.pos.x, 9, 1e-6, "moved")
    T.near(game:list_enemies()[1].rot.y, math.sin(-0.25), 1e-6, "turned")
    T.eq(e.warped, 1, "CharacterController warped so physics does not pull it back")
    local layers = mock.component(e.body, "via.motion.Motion").layers
    -- Another motion: changed. The same motion far off: moved to the frame. Speed copied.
    T.check(game:enemy_set_anim(id, { { bank = 4, id = 1300, frame = 2, speed = 1.0 },
        { bank = 100, id = 50, frame = 30, speed = 0.5 } }), "animation set")
    T.eq(layers[1].motion, 1300, "changeMotion with the owner's motion")
    T.eq(layers[1].bank, 4, "and bank")
    T.eq(layers[2].motion, 50, "the second layer keeps its motion")
    T.near(layers[2].frame, 30, 1e-6, "but jumps to the owner's frame")
    T.eq(layers[2].speed, 0.5, "and plays at its speed")
    local changes = layers[1].changes
    layers[1].frame = 3.5
    game:enemy_set_anim(id, { { bank = 4, id = 1300, frame = 4, speed = 1.0 } })
    T.eq(layers[1].changes, changes, "a small drift is left to the game")
    T.eq(layers[1].seeks, nil, "no seek either")
    T.check(game:capabilities().enemy_motion.ok, "reported")
end)

T.run("an_enemy_the_host_does_not_run_is_hidden_and_shown_again", function()
    local game, world = fresh_game()
    local list = game:list_enemies()
    local ctx = world.enemies[1]
    T.check(game:enemy_set_visible(list[1].id, false), "hidden")
    T.eq(ctx.body.draw_self, false, "its body is not drawn")
    T.check(game:enemy_set_visible(list[1].id, true), "shown")
    T.eq(ctx.body.draw_self, true, "drawn again")
    -- Hidden when the session ends: drawn again.
    T.check(game:enemy_set_visible(list[1].id, false), "hidden again")
    game:restore_enemies()
    T.eq(ctx.body.draw_self, true, "restored with the session's end")
    -- Hidden when the enemy leaves the list: the body is drawn again only when an enemy
    -- shows up with it.
    T.check(game:enemy_set_visible(list[1].id, false), "hidden")
    local body = ctx.body
    for i = #world.enemies, 1, -1 do
        if world.enemies[i] == ctx then table.remove(world.enemies, i) end
    end
    game:list_enemies()
    T.eq(body.draw_self, false, "left alone while it is not an enemy's")
    T.eq(next(game.enemy_hidden), nil, "forgotten")
    table.insert(world.enemies, ctx)
    game:list_enemies()
    T.eq(body.draw_self, true, "drawn again once an enemy has it")
end)

T.run("reading_the_enemies_dead_in_our_save", function()
    local game = fresh_game()
    for i = 1, 100 do
        mock.add_backup({ category = 0, kind = 0, group = 12, index = i }, i % 3 == 0)
    end
    mock.add_backup({ category = 0, kind = 0, group = 1, index = 5 }, true) -- runtime: never sent
    local done, uids, calls = false, nil, 0
    while not done do
        done, uids = game:scan_eliminated(40)
        calls = calls + 1
        T.check(calls < 10, "finishes")
    end
    T.eq(calls, 3, "read in slices (40 per call)")
    T.eq(#uids, 33, "every eliminated level enemy")
    T.eq(uids[1], mock.context_code({ category = 0, kind = 0, group = 12, index = 3 }), "by uid")
    T.check(game:capabilities().enemy_backups.ok, "reported: " .. game:capabilities().enemy_backups.detail)
    local again_done, again = game:scan_eliminated(1000)
    T.eq(again_done, true, "a new scan starts from the beginning")
    T.eq(#again, 33, "same result")
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
    T.eq(ev[1].user, P.ctx_key(game:read_context_id(mock.world.player)), "user ContextID from args[2]")
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

local function field(fields, name)
    for _, f in ipairs(fields or {}) do
        if f.h == P.hash(name) then return f.v end
    end
    return nil
end

T.run("hit_hook_captures_player_hits_with_every_value", function()
    local game, world = fresh_game()
    T.eq(game:capabilities().hit_hook, nil, "hooks wait until a partner connects")
    game:set_active(true)
    T.check(game:capabilities().hit_hook.ok, "hit hook installed")
    T.check(game:capabilities().hit_values.ok, "DamageInfo values found: " .. game:capabilities().hit_values.detail)
    game:read_player_state() -- learns the player's body/head objects
    game:list_enemies()      -- learns the enemies' bodies
    local e1 = world.enemies[1]
    mock.hit(e1, 25, 12)
    local ev = game:take_hit_events()
    T.eq(#ev, 1, "one hit by the player")
    T.eq(ev[1].id, e1:get_address(), "the enemy that was hit")
    T.eq(ev[1].damage, 25, "damage")
    T.eq(ev[1].hp, 100, "its HP before the hit")
    T.eq(ev[1].local_damage, 25, "an enemy our game runs takes it all")
    T.eq(field(ev[1].fields, "Damage"), 25, "the Damage value")
    T.eq(field(ev[1].fields, "Wince"), 12, "the Wince value")
    T.near(field(ev[1].fields, "DamageDir").z, -1, 1e-6, "a vector value")
    T.eq(field(ev[1].fields, "AttackType"), 0, "an enum value")
    T.near(field(ev[1].fields, "HitPos").y, 1.6, 1e-6, "a value of the parent type")
    T.eq(field(ev[1].fields, "SerialNo"), nil, "a serial number only means something in its own game")
    T.eq(field(ev[1].fields, "AttackOwnerObject"), nil, "objects never travel")
    T.eq(e1.hp, 75, "the game applies its own damage")
    T.eq(#game:take_hit_events(), 0, "drained")
    T.eq(field(game:enemy_last_hit(e1:get_address()), "Damage"), 25, "kept as its last hit")

    local other = mock.make_character("chainsaw.Ch1d0z0Context", { x = 9, y = 0, z = 9 }, 100)
    mock.hit(e1, 5, 1, other.body)
    T.eq(#game:take_hit_events(), 0, "hits by other characters are not sent")
    T.eq(game.hit_stats.other_owner, 1, "counted")
    T.eq(field(game:enemy_last_hit(e1:get_address()), "Damage"), 5, "but remembered as its last hit")
    mock.hit(other, 5, 1)
    T.eq(#game:take_hit_events(), 0, "player hits on non-enemies are not sent")
    T.eq(game.hit_stats.not_enemy, 1, "counted")
    game:set_active(false)
    mock.hit(e1, 5, 1)
    T.eq(#game:take_hit_events(), 0, "the hook does nothing while no partner is connected")
end)

T.run("our_hit_never_kills_a_puppet", function()
    local game, world = fresh_game()
    game:set_active(true)
    game:read_player_state()
    local list = game:list_enemies()
    local e1 = world.enemies[1]
    game:enemy_set_puppet(list[1].id, true)
    mock.hit(e1, 30, 5)
    T.eq(e1.hp, 70, "a normal hit takes its HP at once")
    mock.hit(e1, 500, 5)
    T.eq(e1.hp, 1, "a lethal one leaves the last HP: the owner decides the death")
    local ev = game:take_hit_events()
    T.eq(ev[2].damage, 500, "the full hit goes to the owner")
    T.eq(ev[2].local_damage, 69, "what it took here")
    T.eq(ev[2].lethal, true, "marked lethal")
    T.eq(field(ev[2].fields, "Damage"), 500, "with its original values")
    T.eq(mock.component(e1.body, "chainsaw.HitController").received[2].kill, false, "never a kill here")
    T.eq(game.hit_stats.clamped, 1, "counted")
    game.settings.enemy_hit_predict = false
    mock.hit(e1, 10, 5)
    T.eq(e1.hp, 1, "without prediction it takes nothing here")
end)

T.run("a_partners_hit_runs_through_the_games_hit_code", function()
    local game, world = fresh_game()
    game:set_active(true)
    game:read_player_state()
    local list = game:list_enemies()
    local e2 = world.enemies[2]
    local id = list[2].id
    mock.hit(world.enemies[1], 10, 5)
    local fields = game:take_hit_events()[1].fields
    for _, f in ipairs(fields) do
        if f.h == P.hash("Damage") then f.v = 50 end
        if f.h == P.hash("Wince") then f.v = 30 end
    end
    T.check(game:enemy_apply_hit(id, { damage = 50, fields = fields }), "run")
    local r = mock.component(e2.body, "chainsaw.HitController").received[1]
    T.eq(r.damage, 50, "the partner's damage")
    T.eq(r.wince, 30, "the partner's reaction")
    T.near(r.hit_pos.y, 1.6, 1e-6, "every value it had")
    T.eq(r.serial, nil, "except what only meant something in its game")
    T.eq(r.attacker, world.player.body, "the attacker is our live player body")
    T.eq(e2.hp, 250, "the HP the game's own hit code took")
    T.eq(#game:take_hit_events(), 0, "not reported as our own hit")
    T.eq(field(game:enemy_last_hit(id), "Damage"), 50, "its last hit now")
    T.check(game:capabilities().hit_apply.ok, "reported")
    T.check(not game:enemy_apply_hit(id, { damage = 5, fields = {} }), "nothing to run without values")
end)

T.run("a_partners_hit_never_runs_without_attack_data", function()
    -- re4.exe crashed in HitController.playDamageSe: a hit we ran for the partner had no
    -- AttackUserData. Until our own player has hit something, a partner's hit and kill take
    -- the HP path instead; afterwards they carry our weapon's attack data.
    local game, world = fresh_game()
    game:set_active(true)
    game:read_player_state()
    local list = game:list_enemies()
    local e2 = world.enemies[2]
    local fields = { { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = 30 },
        { h = P.hash("WeaponID"), t = P.HIT_VALUE.I32, v = 4000 } }
    T.eq(game:enemy_apply_hit(list[2].id, { damage = 30, fields = fields }), false, "not run through the hit code")
    T.eq(mock.component(e2.body, "chainsaw.HitController").received, nil, "callbackDamageHit never called")
    T.check(game:enemy_kill(list[2].id, fields), "a kill still happens")
    T.eq(e2.hp, 0, "through HitPoint.dead()")
    T.eq(world.native_crashes, 0, "no crash")
    -- Our player hits an enemy: from now on the partner's hits carry that attack data.
    local e1 = world.enemies[1]
    mock.hit(e1, 0, 0)
    game:take_hit_events()
    T.check(game:enemy_apply_hit(list[1].id, { damage = 30, fields = fields }), "now it runs")
    T.eq(world.native_crashes, 0, "still no crash")
    T.eq(world.damage_sounds, 2, "the damage sound played (ours and the partner's)")
    T.check(game:capabilities().hit_templates.ok, "shown in Diagnostics")
end)

T.run("a_killing_hit_from_the_partner_never_throws_a_body_without_its_data", function()
    -- re4.exe crashed in RagdollUnit.onDamageHit: the partner's killing hit, run here on an enemy
    -- kind our player had never hit, had no AttackGameObject and no DamageUserData. Now it
    -- carries our body and the enemy's own (chest) damage data; an enemy without damage
    -- colliders dies through HitPoint.dead() instead.
    local game, world = fresh_game()
    game:set_active(true)
    game:read_player_state()
    local list = game:list_enemies()
    mock.hit(world.enemies[1], 0, 0) -- attack data known
    game:take_hit_events()
    game.hit_templates.by_kind = {}  -- but never this kind
    local fields = { { h = P.hash("Wince"), t = P.HIT_VALUE.F32, v = 44 } }
    local e2 = world.enemies[2]
    T.check(game:enemy_kill(list[2].id, fields), "killed")
    T.eq(world.native_crashes, 0, "no crash")
    T.eq(mock.component(e2.body, "chainsaw.HitController").received[1].kill, true, "by the killing hit")
    T.eq(world.ragdoll_parts, 1, "the body thrown from the enemy's own chest collider")
    T.eq(game.hit_stats.kills_with_hit, 1, "counted")
    -- An enemy without damage colliders: no hit run at all.
    local e1 = world.enemies[1]
    local hc1 = mock.component(e1.body, "chainsaw.HitController")
    hc1.colliders = nil
    T.check(game:enemy_kill(list[1].id, fields), "still killed")
    T.eq(#hc1.received, 1, "not through the hit code (only our own earlier hit)")
    T.eq(e1.hp, 0, "through HitPoint.dead()")
    T.eq(world.native_crashes, 0, "still no crash")
end)

T.run("a_finisher_on_a_puppet_switches_it_back_on_at_once", function()
    -- A stealth kill / grab / knife finish goes to the enemy's AI head, which a puppet has
    -- switched off: when the sync allows it, the head is back on before the request reaches it.
    local game, world = fresh_game()
    game:set_active(true)
    game:read_player_state()
    local list = game:list_enemies()
    local e2 = world.enemies[2]
    local id = list[2].id
    game:enemy_set_puppet(id, true)
    T.eq(e2.head.update_self, false, "a puppet: AI off")
    game.fatal_filter = function() return false end
    mock.fatal(e2)
    T.eq(e2.head.update_self, false, "not when the sync says no")
    T.eq(#game:take_fatal_events(), 0, "nothing reported")
    game.fatal_filter = function(i) return i == id end
    mock.fatal(e2, "requestKnifeFatal")
    T.eq(e2.head.update_self, true, "its AI head is back on before the request reaches it")
    T.eq(mock.component(e2.body, "via.motion.MotionFsm2").enabled, true, "and its animation driver")
    T.eq(world.fatal_requests[2].target, e2, "the game's request still goes through")
    local ev = game:take_fatal_events()
    T.eq(ev[1], id, "reported")
    T.eq(#ev, 1, "once")
    mock.fatal(e2, "requestStompFatal")
    T.eq(game:take_fatal_events()[1], id, "the stomp too")
    T.check(game:capabilities().fatal_hook.ok, "shown in Diagnostics")
end)

T.run("a_death_from_the_partners_game_comes_with_its_killing_hit", function()
    local game, world = fresh_game()
    game:set_active(true)
    game:read_player_state()
    local list = game:list_enemies()
    local e2 = world.enemies[2]
    local id = list[2].id
    game:enemy_set_puppet(id, true)
    mock.hit(world.enemies[1], 0, 0) -- our player has hit something: its attack data is known
    game:take_hit_events()
    local fields = { { h = P.hash("Wince"), t = P.HIT_VALUE.F32, v = 44 },
        { h = P.hash("IsCritical"), t = P.HIT_VALUE.BOOL, v = true } }
    T.check(game:enemy_kill(id, fields), "killed")
    local r = mock.component(e2.body, "chainsaw.HitController").received[1]
    T.eq(r.wince, 44, "by the killing hit")
    T.eq(r.critical, true, "with its values")
    T.eq(r.kill, true, "as a kill")
    T.eq(e2.hp, 0, "dead")
    T.eq(e2.head.update_self, true, "its AI back on for its death")
    T.eq(mock.component(e2.body, "via.motion.MotionFsm2").enabled, true, "and its animation driver")
    T.eq(game.hit_stats.kills_with_hit, 1, "counted")
    -- Without the hit: HitPoint.dead().
    local e1 = world.enemies[1]
    T.check(game:enemy_kill(list[1].id, nil), "killed")
    T.eq(e1.hp, 0, "dead")
end)

T.run("drop_hooks_see_the_games_rolls_and_roll_for_partner_kills", function()
    local game, world = fresh_game()
    game:set_active(true)
    T.check(game:capabilities().drop_hook.ok, "drop hooks installed")
    T.check(game:capabilities().drop_request.ok, "generateRandomDrop available for our own rolls")
    game:begin_frame()
    game:read_player_state()
    game:list_enemies()
    local e1, e2 = world.enemies[1], world.enemies[2]
    T.check(mock.enemy_drop(e1, 112800000) ~= nil, "the game's roll is never skipped")
    local ev = game:take_drop_events()
    T.eq(#ev, 2, "request + the stack's generate")
    T.eq(ev[1].enemy_id, e1:get_address(), "the enemy is the roll's `order`")
    T.eq(ev[1].via, "request", "seen when requested")
    T.eq(ev[2].via, "generate", "and when rolled")
    T.eq(ev[2].droptype, 65536, "drop type")
    local research = game.drop_research[#game.drop_research]
    T.eq(research.cc_is_player, true, "research: cc is our player")
    T.eq(research.order, "chainsaw.Ch1c0z0Context", "research: order is the enemy")
    mock.enemy_drop(nil, 112800000) -- a wooden box
    T.eq(#game:take_drop_events(), 0, "box drops are not enemy drops")

    -- The partner killed e2: we roll its loot for our player.
    local before = #world.generated
    local ok = game:request_enemy_drop(e2:get_address())
    T.check(ok, "rolled")
    local g = world.generated[#world.generated]
    T.eq(#world.generated, before + 1, "one roll")
    T.eq(g.cc, world.player, "for our player (their inventory decides)")
    T.eq(g.order, e2, "from that enemy")
    T.eq(g.droptype, 65536, "with the enemy drop type")
    T.eq(g.opt.__fields.Falldown, true, "falls to the ground like a drop")
    local evs = game:take_drop_events()
    T.eq(#evs, 1, "our own roll is seen by the hook too")
    T.eq(evs[1].via, "generate", "as a generate call")
    local found = false
    for _, p in ipairs(game:list_pickups()) do
        if math.abs(p.pos.x - (e2.pos.x + 0.5)) < 1e-6 then found = true end
    end
    T.check(found, "the loot lies next to the enemy")
    mock.destroy(e2.body)
    T.eq(select(2, game:request_enemy_drop(e2:get_address())), "enemy gone", "never on an enemy whose body is gone")
    game:set_active(false)
    mock.enemy_drop(e1, 112800000)
    T.eq(#game:take_drop_events(), 0, "hooks idle while no partner is connected")
end)

T.run("item_flags_and_time_scale", function()
    local game, world = fresh_game()
    world.item_flags[119288000] = true
    local f = game:item_get_flags({ 119288000, 119286400 })
    T.eq(f[119288000], true, "obtained")
    T.eq(f[119286400], false, "not obtained")
    T.eq(game:get_time_scale(), 1.0, "time scale")
    T.check(game:set_time_scale(0), "set")
    T.eq(world.time_scale, 0, "frozen")
    T.eq(game:get_time_scale(), 0, "read back")
    world.singletons["chainsaw.InventoryManager"] = nil
    T.eq(game:item_get_flags({ 1 }), nil, "no inventory: nil")
end)

T.run("give_an_item_from_the_attache_case", function()
    local game, world = fresh_game()
    local given, refused, enabled = {}, {}, true
    T.check(game:install_give_hooks({
        enabled = function() return enabled end,
        label = function() return "Give to Bob" end,
        on_give = function(ev) given[#given + 1] = ev end,
        on_refused = function(why) refused[#refused + 1] = why end,
    }), "hooks installed")
    T.eq(game:capabilities().give_items.ok, true, "capability")
    world.item_names[114400000] = "Green Herb"
    local herb = mock.case_item("g-herb", 114400000, 3)
    -- The command list: ours is the last entry, with our label.
    local menu, labels = mock.open_item_commands(herb)
    T.eq(menu.order[#menu.order], 13, "'give' is the last command")
    T.eq(menu.map[13], true, "enabled")
    T.eq(labels[13], "Give to Bob", "labelled")
    T.eq(labels[10], "command 10", "the game's own labels are left alone")
    -- Never for key items or weapons, nor without a partner.
    world.item_types[100] = 0
    local key = mock.case_item("g-key", 100, 1)
    T.eq(mock.open_item_commands(key).map[13], nil, "no 'give' for a key item")
    enabled = false
    T.eq(mock.open_item_commands(herb).map[13], nil, "no 'give' without a partner")
    enabled = true
    -- Choosing it: out of the case like a discard, handed to the partner, back to the case.
    mock.open_item_commands(herb)
    mock.choose_item_command(herb, 13)
    T.eq(#given, 1, "given")
    T.eq(given[1].item_id, 114400000, "the item")
    T.eq(given[1].count, 3, "the whole stack")
    T.eq(world.case["g-herb"], nil, "out of our case")
    T.eq(world.virtual_removed, 1, "and out of the case GUI")
    T.eq(world.case_default, 1, "the game goes back to the case by itself")
    -- Any other command is the game's.
    local ammo = mock.case_item("g-ammo", 112800000, 10)
    mock.choose_item_command(ammo, 10)
    T.eq(#given, 1, "a discard is not a gift")
    T.eq(game:item_name(114400000), "Green Herb", "item names from the game's messages")
    -- Receiving: into our case (the player's PlayerEquipment holds it), as much as fits; not
    -- while the case is open.
    T.eq(game:give_receive(114400000, 2, -1), 2, "placed")
    T.check(game:capabilities().give_receive.detail:find("PlayerEquipment") ~= nil, "found through PlayerEquipment")
    -- Without it: ChainsawGuiUtil.getInventoryControllers by its ContextID overload (another
    -- overload of the same name comes first).
    mock.component(world.player.body, "chainsaw.PlayerEquipment").__fields["<InventoryController>k__BackingField"] = nil
    T.eq(game:give_receive(114400000, 1, -1), 1, "placed through getInventoryControllers(ContextID)")
    T.check(game:capabilities().give_receive.detail:find("getInventoryControllers") ~= nil, "reported")
    world.case_room = world.case_room + 1
    T.eq(world.case["added-1"].__fields._CurrentItemCount, 2, "in our case")
    world.inventory_open = true
    T.eq(game:give_receive(114400000, 1, -1), nil, "waits while the case is open")
    world.inventory_open = false
    world.case_room = 0
    T.eq(game:give_receive(114400000, 1, -1), 0, "nothing fits")
    T.eq(#refused, 0, "nothing refused")
end)

T.run("hooks_absent_without_sdk_hook", function()
    local game = fresh_game({ no_hook = true })
    game:set_active(true)
    T.eq(game:take_hit_events(), nil, "no hit events")
    T.eq(game:take_drop_events(), nil, "no drop events")
    T.check(not game:capabilities().hit_hook.ok, "hit hook reported missing")
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
    game:set_active(true)
    mock.gimmick_dirty("chainsaw.GmContextBox", { group = 43400, index = 7 })
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
    T.check(type(dump.types["chainsaw.GmContextBox"]) == "table", "changed gimmick types described")
    T.eq(dump.types["chainsaw.HateControllerUserData"], "not found", "types missing in this build are listed as such")
    T.check(dump.live.singletons["chainsaw.CharacterManager"] == true, "singleton presence")
    T.eq(dump.live.enemies[1].uid, mock.context_code({ category = 0, kind = 0, group = 4100, index = 7 }), "enemy uids")
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
    T.eq(r.enemies[1].spawner, "0:0:4100:7", "enemy spawner key")
    T.eq(r.enemies[1].stage, 40200, "enemy stage")
    T.eq(r.enemies[1].id, "0:0:4100:7", "a level enemy's own ID is its spawn param's")
    T.eq(r.enemies[1].id_stable, true, "and holds across machines")
    T.eq(r.enemies[1].uid, mock.context_code({ category = 0, kind = 0, group = 4100, index = 7 }), "uid")
    T.eq(r.enemies[1].motion.bank, 100, "first enemy motion")
    T.eq(r.enemies[1].find_state, 1, "enemy find state")
    T.eq(r.hate[1].game_object, "GameObject ch1c0z0_hate", "HateController's GameObject")
    T.eq(r.hate[1].current_target._Target, "GameObject ch0a0z0_body", "current target read")
    T.eq(r.pickups[1].stage, 40210, "pickup stage")
    T.eq(r.pickups[1].id, "3:0:40200:2", "pickup level ID")
    T.eq(r.pickup_hook.hooks, 2, "hooks installed")
    T.eq(r.session.items.hook, "confirmed", "session state included")
    T.eq(r.session.partner_model.state, "idle", "partner model status included")
    T.eq(r.gimmicks.recent[1].type, "chainsaw.GmContextBox", "gimmick state changes logged")
    T.eq(r.gimmicks.recent[1].id, "1:0:43400:7", "gimmick ID")
    T.eq(r.enemies[1].head, "GameObject Ch1c0z0_head", "enemy AI head object")
    T.check(r.hits ~= nil and r.drops ~= nil, "hit and drop statistics")
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
