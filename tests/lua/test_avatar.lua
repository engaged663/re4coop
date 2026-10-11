-- Avatar sync logic offline: what the sender sends when, and how the receiver turns it
-- into an interpolated pose and timed events.
local T = require("testlib")
local P = require("re4coop.protocol")
local Avatar = require("re4coop.avatar")

-- A fake local character: n joints rotating about x by `angle`.
local function fake_game(njoints)
    local g = { angle = 0, events = {}, pose_requests = 0, wanted = false, sig = "A", gear_sig = "G" }
    function g:avatar_descriptor()
        local joints = {}
        for i = 1, njoints do joints[i] = { hash = P.hash("j" .. i), flags = i == 1 and P.JOINT_FLAGS.TRANSLATE or 0 } end
        return { sig = self.sig, char_id = "ch0a0z0", body_name = "ch0a0z0_body",
            parts = { { name = "cha000_00", mesh = "m.mesh", mdf = "m.mdf2", parent = 0, flags = 0 } }, joints = joints }
    end
    function g:gear_descriptor()
        return { sig = self.gear_sig, weapons = { { name = "wp4000", mesh = "w.mesh", mdf = "w.mdf2", joints = { P.hash("Slide") } } } }
    end
    function g:request_pose() self.wanted = true self.pose_requests = self.pose_requests + 1 end
    function g:take_pose(now)
        if not self.wanted then return nil end
        self.wanted = false
        local q = {}
        for i = 1, njoints do
            local h = self.angle / 2
            q[#q + 1], q[#q + 2], q[#q + 3], q[#q + 4] = math.sin(h), 0, 0, math.cos(h)
        end
        return { time = now, sig = self.sig, gear_sig = self.gear_sig, root_pos = { x = self.angle, y = 0, z = 0 },
            root_rot = { x = 0, y = 0, z = 0, w = 1 }, flags = 0, q = q, tpos = { { index = 1, x = 0, y = 1, z = 0 } },
            weapons = { { slot = 1, flags = P.WEAPON_FLAGS.VISIBLE, attach = 1, pos = { x = 0, y = 0, z = 0.1 },
                rot = { x = 0, y = 0, z = 0, w = 1 }, q = { 0, 0, 0, 1 } } } }
    end
    function g:drain_events()
        local e = self.events
        self.events = {}
        return e
    end
    return g
end

local function make_pair(njoints, settings)
    local sent = {}
    local settings = settings or { pose_hz = 30, interp_delay = 0.1 }
    local frag_id = 0
    local tx = Avatar.new_sender({
        protocol = P, settings = settings,
        send = function(bytes, reliable) sent[#sent + 1] = { bytes = bytes, reliable = reliable } return true end,
        send_large = function(bytes)
            frag_id = frag_id + 1
            for _, piece in ipairs(#bytes <= P.MAX_PAYLOAD and { bytes } or P.fragment(bytes, frag_id)) do
                sent[#sent + 1] = { bytes = piece, reliable = true }
            end
            return true
        end,
    })
    local rx = Avatar.new_receiver({ protocol = P, settings = settings })
    local r = P.new_reassembler()
    local function deliver(now)
        local n = 0
        for _, s in ipairs(sent) do
            local m = assert(P.decode(s.bytes))
            if m.type == P.T.FRAG then
                local full = r:push(m)
                m = full and assert(P.decode(full)) or nil
            end
            if m then rx:on_message(m, now) n = n + 1 end
        end
        sent = {}
        return n
    end
    return tx, rx, deliver, function() return sent end
end

T.run("sender_describes_character_once_and_streams_poses", function()
    local game = fake_game(400)
    local tx, rx, deliver, pending = make_pair(400)
    tx:tick(0.0, game) -- avatar + gear; asks for the first pose
    local types = {}
    for _, s in ipairs(pending()) do types[#types + 1] = s.bytes:byte(1) end
    T.check(#types >= 3, "avatar is fragmented and gear sent")
    T.eq(types[#types], P.T.GEAR, "gear after the avatar")
    T.eq(game.pose_requests, 1, "pose capture requested")
    deliver(0.0)
    T.eq(rx.avatar.char_id, "ch0a0z0", "receiver knows the character")
    T.eq(#rx.avatar.joints, 400, "all joints")
    T.eq(rx.gear.weapons[1].name, "wp4000", "receiver knows the weapon")

    tx:tick(0.04, game) -- pose captured at the end of the last frame is sent now
    local poses = 0
    for _, s in ipairs(pending()) do
        if s.bytes:byte(1) == P.T.POSE then
            poses = poses + 1
            T.check(not s.reliable, "poses are unreliable")
        end
    end
    T.eq(poses, 2, "400 joints need two POSE datagrams")
    tx:tick(0.05, game)
    T.eq(#pending(), 2, "rate limited: nothing new 10 ms later")
    deliver(0.05)
    T.eq(tx.counters.avatars, 1, "avatar sent once")

    tx:reset() -- the partner restarted
    tx:tick(0.2, game)
    T.eq(tx.counters.avatars, 2, "avatar resent after reset")
    game.sig = "B" -- costume change
    tx:tick(0.3, game)
    T.eq(tx.counters.avatars, 3, "avatar resent when it changes")
end)

T.run("pose_needs_matching_descriptors", function()
    local game = fake_game(10)
    local tx, rx, deliver, pending = make_pair(10)
    tx:tick(0, game)
    game.sig = "changed-after-capture"
    -- The captured pose says sig "changed-after-capture", but a new avatar is sent first
    -- in the same tick, so the pose goes out with it.
    tx:tick(0.04, game)
    local saw_avatar_before_pose = false
    local avatar_seen = false
    for _, s in ipairs(pending()) do
        local t = s.bytes:byte(1)
        if t == P.T.AVATAR then avatar_seen = true end
        if t == P.T.POSE then saw_avatar_before_pose = avatar_seen end
    end
    T.check(saw_avatar_before_pose, "new avatar precedes the pose that needs it")
    deliver(0.04)
    T.eq(rx.counters.stale_poses, 0, "no pose rejected")

    -- A pose for an avatar the receiver does not have yet is ignored.
    local stale = P.encode_pose({ time = 1, avatar_rev = 999, gear_rev = 1, root_pos = { x = 0, y = 0, z = 0 },
        root_rot = { x = 0, y = 0, z = 0, w = 1 }, q = { 0, 0, 0, 1 } })
    rx:on_message(assert(P.decode(stale[1])), 1)
    T.eq(rx.counters.stale_poses, 1, "pose for an unknown avatar revision ignored")
end)

T.run("receiver_interpolates_joints_and_root", function()
    local game = fake_game(300)
    local tx, rx, deliver = make_pair(300, { pose_hz = 30, interp_delay = 0.1 })
    -- 20 poses, 50 ms apart; angle and root x grow linearly. 10 ms one-way latency.
    for i = 0, 20 do
        game.angle = i * 0.05
        local t = i * 0.05
        tx:tick(t, game)
        deliver(t + 0.01)
    end
    local now = 0.66 -- renders sender time 0.66 - 0.01 - 0.1 = 0.55
    local st = rx:state(now)
    T.check(st and st.pose, "pose available")
    -- The fake captures at send time, so sender time t carries angle(t).
    local expect_angle = 0.55
    local q = st.pose.q
    T.near(math.abs(2 * math.asin(q[1])), expect_angle, 0.01, "joint 1 interpolated")
    T.near(math.abs(2 * math.asin(q[300 * 4 - 3])), expect_angle, 0.01, "joint 300 (second chunk) interpolated")
    T.near(st.pose.root_pos.x, expect_angle, 0.01, "root interpolated")
    T.eq(#st.pose.weapons, 1, "weapon placement")
    T.eq(st.pose.weapons[1].attach, 1, "attached to joint 1")
    T.near(st.pose.tpos[1].y, 1.0, 1e-3, "translation")
    -- Long after the last pose: joints hold (no extrapolation), root extrapolates a bit.
    local late = rx:state(5.0)
    T.near(math.abs(2 * math.asin(late.pose.q[1])), 1.0, 0.01, "joints hold the last pose")
    T.check(late.pose.root_pos.x <= 1.0 + 0.25 + 1e-6, "root extrapolation capped")
    T.near(rx:age(5.0), 5.0 - 1.01, 1e-6, "age since the last pose")
end)

T.run("weapons_need_the_matching_gear", function()
    local game = fake_game(5)
    local tx, rx, deliver = make_pair(5)
    tx:tick(0, game)
    deliver(0)
    rx.gear = nil -- as if GEAR had not arrived yet
    tx:tick(0.04, game)
    deliver(0.04)
    local st = rx:state(0.2)
    T.eq(#st.pose.weapons, 0, "weapon placement without its GEAR is dropped")
end)

T.run("events_follow_the_animation_delay", function()
    local game = fake_game(5)
    local tx, rx, deliver = make_pair(5, { pose_hz = 30, interp_delay = 0.1 })
    for i = 0, 5 do
        tx:tick(i * 0.04, game)
        deliver(i * 0.04)
    end
    -- A gunshot sound at sender time 0.20.
    game.events = { { kind = P.EVENT.CALL, time = 0.20, part = 0, comp_type = 1, comp_idx = 1, method = 42,
        args = { { tag = P.ARG.U32, value = 777 } } }, { kind = P.EVENT.SHOT, time = 0.20, slot = 1 } }
    tx:tick(0.21, game)
    deliver(0.21)
    T.eq(#rx:take_events(0.25), 0, "not yet: the animation shows sender time 0.15")
    local due = rx:take_events(0.31)
    T.eq(#due, 2, "due once the delayed timeline reaches it")
    T.eq(due[1].args[1].value, 777, "trigger id")
    T.eq(due[2].kind, P.EVENT.SHOT, "shot")
    -- An event that arrives far too late is dropped.
    game.events = { { kind = P.EVENT.SHOT, time = 0.22, slot = 1 } }
    tx:tick(0.23, game)
    deliver(0.23)
    T.eq(#rx:take_events(3.0), 0, "stale event dropped")
    T.eq(rx.counters.stale_events, 1, "counted")
    -- Without a pose stream, events play immediately.
    local rx2 = Avatar.new_receiver({ protocol = P })
    rx2:on_message(assert(P.decode(P.encode_actions({ time = 100, events = { { kind = P.EVENT.SHOT, slot = 2 } } })[1])), 0)
    T.eq(#rx2:take_events(0), 1, "no pose: immediate")
end)

T.run("receiver_reset_and_avatar_change", function()
    local game = fake_game(5)
    local tx, rx, deliver = make_pair(5)
    tx:tick(0, game)
    deliver(0)
    tx:tick(0.04, game)
    deliver(0.04)
    T.check(rx:state(0.2).pose ~= nil, "pose")
    game.sig = "new costume"
    tx:tick(0.1, game)
    deliver(0.1)
    T.check(rx:state(0.3).pose == nil or rx.avatar.rev == 2, "new avatar replaces old poses")
    rx:reset()
    T.check(rx:state(0.3) == nil, "nothing after reset")
end)

T.finish()
