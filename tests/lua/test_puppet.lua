-- puppet.lua against the mocked REFramework world. The partner is simulated by capturing
-- the mock's local player (Leon with three costume parts and an SG-09 R) through the real
-- capture code, avatar sender, wire format and receiver - then the puppet builds and
-- animates the copy in the same world.
local T = require("testlib")
local mock = require("mock_reframework")
local P = require("re4coop.protocol")

local now = 0

local function setup(opts)
    opts = opts or {}
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    local world = mock.install()
    mock.motion_locked = opts.motion_locked
    world.player = mock.make_player({ x = 10, y = 0, z = 5 }, { body_name = opts.body_name })
    local Game = require("re4coop.game")
    local Avatar = require("re4coop.avatar")
    local Puppet = require("re4coop.puppet")
    local game = Game.new(function() end, function() return now end)
    local settings = { pose_hz = 240, interp_delay = 0.0 } -- a pose every frame
    local queue = {}
    local tx = Avatar.new_sender({
        protocol = P, settings = settings,
        send = function(bytes) queue[#queue + 1] = bytes return true end,
        send_large = function(bytes)
            for _, piece in ipairs(#bytes <= P.MAX_PAYLOAD and { bytes } or P.fragment(bytes, 1)) do
                queue[#queue + 1] = piece
            end
            return true
        end,
    })
    local rx = Avatar.new_receiver({ protocol = P, settings = settings })
    local r = P.new_reassembler()
    game:set_capture(true)
    local env = { world = world, game = game, tx = tx, rx = rx, logs = {} }
    env.puppet = Puppet.new(game, function(s) env.logs[#env.logs + 1] = s end)
    -- One frame: the partner's game sends, we receive, the puppet updates, animation runs,
    -- end of frame (pose capture + late pose check).
    function env.frame(hidden)
        now = now + 1 / 60
        env.opts = env.opts or {}
        game:begin_frame() -- what the entry script does at the start of every game frame
        tx:tick(now, game)
        for _, bytes in ipairs(queue) do
            local m = assert(P.decode(bytes))
            if m.type == P.T.FRAG then
                local full = r:push(m)
                m = full and assert(P.decode(full)) or nil
            end
            if m then rx:on_message(m, now) end
        end
        queue = {}
        env.puppet:update(now, rx:state(now), { hidden = hidden, meshes_only = env.opts.meshes_only })
        env.puppet:replay(rx:take_events(now), { audio = true, effects = true })
        mock.update_motion()
        game:capture_pose_late(now)
        env.puppet:late_update()
    end
    function env.frames(n, hidden)
        for _ = 1, n do env.frame(hidden) end
    end
    return env
end

-- The puppet's objects (the local player's Leon is also named ch0a0z0_body).
local function puppet_root(env)
    return env.puppet.root
end

local function angle(a, b)
    local dot = math.abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w)
    return 2 * math.deg(math.acos(math.min(1, dot)))
end

T.run("builds_leon_from_his_body_prefab", function()
    local env = setup()
    env.frames(4)
    local p = env.puppet
    T.eq(p.state, "ready", "model ready")
    T.eq(p.mode, "prefab", "from the body prefab")
    T.eq(p.prefab_path, mock.PREFAB.leon_body, "found ch0a0z0_body.pfb from the character id")
    local root = puppet_root(env)
    T.check(root ~= env.world.player.body, "a separate object from the local player")
    T.eq(root.name, "re4coop_ch0a0z0_body", "renamed: the game's own lookups keep finding the real player")
    T.eq(#mock.find("ch0a0z0_body"), 1, "only the local player answers to ch0a0z0_body")

    -- Game logic, physics and animation are off; rendering, sound and cloth stay on.
    T.eq(mock.component(root, "via.motion.Motion").enabled, false, "Motion off")
    T.eq(mock.component(root, "via.motion.MotionFsm2").enabled, false, "FSM off")
    T.eq(mock.component(root, "via.behaviortree.BehaviorTree").enabled, false, "behavior tree off")
    T.eq(mock.component(root, "via.physics.Colliders").enabled, false, "colliders off")
    T.eq(mock.component(root, "chainsaw.CharacterBodyLogic").enabled, false, "game logic off")
    T.check(mock.component(root, "chainsaw.WwiseContainerApp").enabled ~= false, "sound container kept")
    T.check(mock.component(root, "via.motion.Chain").enabled ~= false, "cloth/hair chains kept")

    -- Costume: the prefab's body mesh is reused with the partner's (dirty) material, the
    -- default jacket is hidden, the face and hair are rebuilt from their meshes.
    local body_part
    for _, c in ipairs(root.transform.children) do
        if c.owner.name == "re4coop_cha000_00" then body_part = c.owner end
    end
    T.check(body_part ~= nil, "prefab body mesh")
    T.eq(mock.component(body_part, "via.render.Mesh").mdf_path, mock.MDF.body_dirty, "partner's material")
    local jacket
    for _, c in ipairs(root.transform.children) do
        if c.owner.name == "re4coop_cha002_00" then jacket = c.owner end
    end
    T.eq(jacket.draw_self, false, "default jacket hidden: the partner does not wear it")
    local face = mock.find("re4coop_cha000_10")[1]
    local hair = mock.find("re4coop_cha000_20")[1]
    T.check(face and hair, "face and hair rebuilt")
    T.eq(face.transform.parent, root.transform, "attached to the body")
    T.eq(face.transform.same_joints, true, "following its joints")
    T.eq(mock.component(face, "via.render.Mesh").mesh_path, mock.MESH.face, "face mesh")
    T.eq(env.puppet.joints_mapped, env.puppet.joints_total, "every joint of the partner is animated")

    -- Pose: root placement and every joint, including face/hair-only joints.
    local src = env.world.player.body.transform
    T.near(root.transform.wpos.x, 10, 1e-4, "placed at the partner")
    for _, name in ipairs({ "Spine_1", "R_Forearm", "L_Foot" }) do
        local a, b = mock.joint(src, name).lrot, mock.joint(root.transform, name).lrot
        T.check(angle(a, b) < 0.3, name .. " matches the partner")
    end
    local jaw = mock.joint(face.transform, "Jaw")
    T.check(jaw.writes and jaw.writes > 0, "face-only joint animated")
    T.check(mock.joint(face.transform, "Head").writes == nil, "shared joints come from the body (constraint)")
    T.near(mock.joint(root.transform, "Hip").lpos.y, 0.98, 2e-3, "hip height")
    T.eq(root.draw_self, true, "visible")

    -- The partner walks and animates: the copy follows.
    for _ = 1, 10 do
        env.world.player.pos.x = env.world.player.pos.x + 0.2
        env.frame()
    end
    env.frames(3)
    T.near(root.transform.wpos.x, 12, 1e-3, "follows the partner")
    -- Teleports (doors, our own "teleport to partner") jump instead of sliding past.
    env.world.player.pos.x = 17
    local overshoot = false
    for _ = 1, 6 do
        env.frame()
        if root.transform.wpos.x > 17 + 1e-3 then overshoot = true end
    end
    T.check(not overshoot, "no overshoot on a teleport")
    T.near(root.transform.wpos.x, 17, 1e-3, "at the new place")
    for _, j in ipairs(src.joints) do j.anim_rot = mock.quat(0, 0, 0.3826834, 0.9238795) end
    env.frames(3)
    T.check(angle(mock.joint(root.transform, "Spine_1").lrot, mock.quat(0, 0, 0.3826834, 0.9238795)) < 0.3,
        "new pose")
    T.eq(env.puppet.late_writes, false, "pose sticks: no rewrite after animation needed")
end)

T.run("holds_the_partners_weapon", function()
    local env = setup()
    env.frames(5)
    local w = env.puppet.weapons[1]
    T.check(w ~= nil and w.state == "ready", "weapon ready")
    T.eq(w.mode, "prefab", "from wp4000.pfb")
    local go = w.go
    T.eq(go.name, "re4coop_wp4000", "SG-09 R, renamed so nothing mistakes it for the player's")
    T.eq(go.transform.parent, puppet_root(env).transform, "held by the model")
    T.eq(go.transform.parent_joint, "R_WepHand", "in the same hand joint")
    T.near(go.transform.lpos.z, 0.12, 1e-5, "same grip offset")
    T.eq(go.draw_self, true, "visible")
    T.eq(mock.component(go, "chainsaw.Gun").enabled, false, "gun logic off: it cannot shoot real bullets")
    T.eq(mock.component(go, "via.physics.Colliders").enabled, false, "no collision")
    -- Weapon joints (slide) follow too.
    mock.joint(env.world.player.weapon.transform, "Slide").lrot = mock.quat(0.2588190, 0, 0, 0.9659258)
    env.frames(3)
    T.check(angle(mock.joint(go.transform, "Slide").lrot, mock.quat(0.2588190, 0, 0, 0.9659258)) < 0.3, "slide")
    -- Held by a joint only one part has (here the face's Jaw): it hangs from that part.
    local face_src = mock.find("cha000_10")[1]
    mock.set_parent(env.world.player.weapon.transform, face_src.transform)
    env.world.player.weapon.transform.parent_joint = "Jaw"
    env.frames(3)
    T.eq(go.transform.parent, mock.find("re4coop_cha000_10")[1].transform, "held by the part owning the joint")
    T.eq(go.transform.parent_joint, "Jaw", "same joint")
    mock.set_parent(env.world.player.weapon.transform, env.world.player.body.transform)
    env.world.player.weapon.transform.parent_joint = "R_WepHand"
    env.frames(3)
    T.eq(go.transform.parent, puppet_root(env).transform, "back in the hand")
    -- Holstered (hidden) on the partner's side: hidden here.
    env.world.player.weapon.draw_self = false
    env.frames(2)
    T.eq(go.draw_self, false, "hidden with the partner's")
    -- Weapon dropped from the partner's gear: removed.
    mock.destroy(env.world.player.weapon)
    now = now + 1
    env.frames(2)
    T.check(go.destroyed, "puppet weapon removed")
    T.eq(#env.puppet:status().weapons, 0, "no weapons")
end)

T.run("replays_sounds_effects_and_shots", function()
    local env = setup()
    env.frames(5)
    local ctx, world = env.world.player, env.world
    local root, w = puppet_root(env), env.puppet.weapons[1]
    world.sounds, world.effects = {}, {}
    ctx.sound:call("trigger(System.UInt32)", 1234)        -- e.g. a footstep on the body
    ctx.sound:call("trigger(System.UInt32, via.GameObject)", 77, ctx.body)
    env.frames(2)
    local replayed = {}
    for _, s in ipairs(world.sounds) do
        if s.comp ~= ctx.sound then replayed[#replayed + 1] = s end
    end
    T.eq(#replayed, 2, "both sounds replayed on the copy")
    T.eq(replayed[1].id, 1234, "same trigger")
    T.eq(replayed[1].comp, mock.component(root, "chainsaw.WwiseContainerApp"), "on the model's own container")
    T.eq(replayed[2].target, root.name, "GameObject argument mapped to the model")
    T.eq(env.puppet.counters.sounds, 2, "counted")

    world.sounds = {}
    ctx.gun_sound:call("trigger(via.GameObject, System.UInt32, via.GameObject, System.UInt32, via.wwise.RequestInfo, System.Boolean, System.Boolean, System.Boolean, System.Int32)",
        ctx.weapon, 555, ctx.weapon, 0, mock.new("via.wwise.RequestInfo"), false, false, false, 0)
    env.frames(2)
    local gun_sound
    for _, s in ipairs(world.sounds) do
        if s.comp == mock.component(w.go, "chainsaw.WwiseContainerApp") then gun_sound = s end
    end
    T.check(gun_sound ~= nil and gun_sound.id == 555, "gunshot sound replayed on the copy's gun (simplest overload)")

    -- A shot without effects from the effect mirror gets the game's muzzle flash.
    ctx.gun:call("shoot")
    env.frames(2)
    T.eq(world.flashes, 1, "muzzle flash spawned")
    T.eq(env.puppet.counters.shots, 1, "shot counted")
    -- Effects coming through the mirror: replayed on the gun, no extra flash.
    ctx.gun_effect:call("requestEffect(System.UInt32, System.UInt32)", 15, 3)
    env.frames(2)
    T.eq(world.effects[#world.effects].comp, mock.component(w.go, "via.effect.script.EPVStandard"), "effect on the copy's gun")
    now = now + 0.05
    ctx.gun:call("shoot")
    env.frames(3)
    T.eq(world.flashes, 1, "no fallback flash while the gun's own effects replay")
    -- Flashes are cleaned up once their effect has surely finished.
    now = now + 1
    env.frames(1)
    T.check(#env.puppet.flashes > 0, "a flash is not destroyed while its effect may still play")
    now = now + 2.5
    env.frames(1)
    T.eq(#env.puppet.flashes, 0, "flashes expire")

    -- Hidden partner (cutscene): nothing plays.
    local before = #world.sounds
    ctx.sound:call("trigger(System.UInt32)", 9)
    env.frames(2, true)
    T.eq(root.draw_self, false, "hidden")
    T.eq(w.go.draw_self, false, "weapon hidden too")
    local echoed = 0
    for i = before + 1, #world.sounds do
        if world.sounds[i].comp ~= ctx.sound then echoed = echoed + 1 end
    end
    T.eq(echoed, 0, "no sound from a hidden partner")
end)

T.run("mirror_mode_without_a_body_prefab", function()
    local env = setup({ body_name = "ch7z7z0_body" })
    env.frames(3)
    local p = env.puppet
    T.eq(p.state, "ready", "still shown")
    T.eq(p.mode, "mirror", "rebuilt from meshes")
    T.check(p.detail:find("no body prefab"), "reason reported: " .. tostring(p.detail))
    local root = puppet_root(env)
    T.eq(root.name, "re4coop_partner", "own root object")
    T.eq(mock.component(root, "via.render.Mesh").mesh_path, mock.MESH.body, "root shows the main (body) mesh")
    T.eq(#root.transform.joints, #mock.LEON_JOINTS, "skeleton from the body mesh")
    T.check(mock.find("re4coop_cha000_10")[1] ~= nil, "face part")
    local src = env.world.player.body.transform
    T.check(angle(mock.joint(src, "R_Hand").lrot, mock.joint(root.transform, "R_Hand").lrot) < 0.3, "posed")
    T.eq(p.joints_mapped, p.joints_total, "all joints animated")
end)

T.run("meshes_only_option_skips_the_prefab", function()
    local env = setup()
    env.opts = { meshes_only = true }
    env.frames(3)
    T.eq(env.puppet.mode, "mirror", "built from meshes")
    T.eq(env.puppet.detail, "built from meshes (option)", "because the option says so")
    T.check(env.world.instantiated == nil or env.world.instantiated[1] ~= mock.PREFAB.leon_body, "body prefab not used")
    env.opts.meshes_only = false
    env.frames(4)
    T.eq(env.puppet.mode, "prefab", "switching the option back rebuilds from the prefab")
end)

T.run("retries_when_objects_cannot_be_created", function()
    local env = setup({ body_name = "ch7z7z0_body" }) -- no prefab: mirror mode
    local create = mock.classes["via.GameObject"].methods["create(System.String)"]
    local real = create.fn
    create.fn = function() return nil end
    env.frames(3)
    T.eq(env.puppet.state, "failed", "reported")
    T.check(env.puppet.detail:find("could not create"), "with the reason")
    create.fn = real
    env.frames(3)
    T.eq(env.puppet.state, "failed", "waits before retrying")
    now = now + 11
    env.frames(3)
    T.eq(env.puppet.state, "ready", "retried")
end)

T.run("rewrites_the_pose_after_animation_when_it_must", function()
    local env = setup({ motion_locked = true }) -- a Motion component that refuses to switch off
    env.frames(4)
    local root = puppet_root(env)
    T.eq(env.puppet.late_writes, true, "detected the engine overwriting the pose")
    T.check(env.logs[#env.logs]:find("overwrites the pose") or table.concat(env.logs, "\n"):find("overwrites the pose"),
        "logged")
    env.frames(1)
    local src = env.world.player.body.transform
    T.check(angle(mock.joint(src, "Spine_2").lrot, mock.joint(root.transform, "Spine_2").lrot) < 0.3,
        "the rendered pose is still the partner's")
end)

T.run("rebuilds_after_the_game_unloads_it", function()
    local env = setup()
    env.frames(4)
    local first = puppet_root(env)
    mock.destroy(first) -- area unload
    env.frames(1)
    T.eq(env.puppet.state, "idle", "noticed")
    env.frames(5)
    T.eq(env.puppet.state, "idle", "waits before rebuilding")
    now = now + 3.5
    env.frames(4)
    T.eq(env.puppet.state, "ready", "rebuilt")
    T.check(puppet_root(env) ~= first and not puppet_root(env).destroyed, "new copy")
end)

T.run("rebuilds_on_costume_change_and_cleans_up", function()
    local env = setup()
    env.frames(4)
    local first = puppet_root(env)
    local face = mock.find("re4coop_cha000_10")[1]
    mock.find("cha000_20")[1].components[2].mesh_path = "_chainsaw/character/ch/cha0/cha000/21/cha000_21.mesh"
    now = now + 2 -- next appearance scan
    env.frames(4)
    T.check(first.destroyed and face.destroyed, "old copy removed")
    T.eq(env.puppet.state, "ready", "new copy")
    T.check(mock.find("re4coop_cha000_20")[1] ~= nil, "new hair part")
    local w = env.puppet.weapons[1].go
    env.puppet:shutdown()
    T.check(puppet_root(env) == nil and w.destroyed, "everything removed on shutdown")
    T.eq(#mock.find("re4coop_cha000_10"), 0, "no rebuilt parts left")
    -- No partner at all: nothing is built.
    env.puppet:update(now, nil, {})
    T.eq(env.puppet.state, "idle", "idle without a partner")
end)

T.finish()
