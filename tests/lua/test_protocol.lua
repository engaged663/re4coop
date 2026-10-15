local T = require("testlib")
local P = require("re4coop.protocol")

local MAX = re4coop_net.max_payload()

T.run("fnv1a_hash", function()
    T.eq(P.hash(""), 0x811C9DC5, "empty")
    T.eq(P.hash("a"), 0xE40C292C, "a")
    T.eq(P.hash("foobar"), 0xBF9CF968, "foobar")
    T.check(P.hash("chainsaw.Ch1c0z0Context") ~= P.hash("chainsaw.Ch1c1z0Context"), "distinct kinds")
    T.eq(P.MAX_PAYLOAD, MAX, "protocol knows the transport's payload limit")
end)

T.run("hello_roundtrip", function()
    local m = assert(P.decode(P.encode_hello({ name = "Leon", area = "Chapter 3" })))
    T.eq(m.type, P.T.HELLO, "type")
    T.eq(m.version, P.VERSION, "version")
    T.eq(m.mod_version, P.MOD_VERSION, "mod version")
    T.eq(m.name, "Leon", "name")
    T.eq(m.area, "Chapter 3", "area")
end)

T.run("hello_flags_and_version_mismatch", function()
    local m = assert(P.decode(P.encode_hello({ name = "Ada", flags = P.HELLO_FLAGS.WANT_REPLY })))
    T.eq(m.flags, P.HELLO_FLAGS.WANT_REPLY, "flags")
    -- A future build may change everything after the version field; we must still read it.
    local future = string.pack("<BI2", P.T.HELLO, P.VERSION + 1) .. "\255\255garbage"
    local f = assert(P.decode(future))
    T.eq(f.version, P.VERSION + 1, "version readable from incompatible HELLO")
    -- And a protocol-1 peer's HELLO reads as "old version" too.
    T.eq(assert(P.decode(string.pack("<BI2s1s1s1B", P.T.HELLO, 1, "0.1.1", "x", "", 0))).version, 1, "v1 hello")
end)

T.run("player_roundtrip", function()
    local data = P.encode_player({
        time = 123.456, pos = { x = 10, y = 1, z = -5 }, rot = { x = 0, y = 0.7071, z = 0, w = 0.7071 },
        hp = 875, max_hp = 1000, flags = P.PLAYER_FLAGS.AIMING, area_hash = 42,
    })
    T.check(#data < 64, "player message stays small (" .. #data .. " bytes)")
    local m = assert(P.decode(data))
    T.eq(m.type, P.T.PLAYER, "type")
    T.near(m.time, 123.456, 1e-9, "time")
    T.near(m.pos.x, 10, 1e-5, "pos.x")
    T.near(m.rot.y, 0.7071, 1e-4, "rot.y")
    T.eq(m.hp, 875, "hp")
    T.eq(m.max_hp, 1000, "max_hp")
    T.eq(m.flags, P.PLAYER_FLAGS.AIMING, "flags")
    T.eq(m.area_hash, 42, "area hash")
    T.eq(m.stage, nil, "no stage sent")
end)

T.run("player_stage_roundtrip", function()
    local base = { time = 1, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 } }
    base.stage = 40210
    base.flags = P.PLAYER_FLAGS.CUTSCENE
    local m = assert(P.decode(P.encode_player(base)))
    T.eq(m.stage, 40210, "stage")
    T.check((m.flags & P.PLAYER_FLAGS.CUTSCENE) ~= 0, "other flags kept")
    T.check((m.flags & P.PLAYER_FLAGS.HAS_STAGE) ~= 0, "stage flag set")
    base.stage = 0
    T.eq(assert(P.decode(P.encode_player(base))).stage, 0, "stage 0 is a real value")
    base.stage = 1.5
    T.eq(assert(P.decode(P.encode_player(base))).stage, nil, "non-integer stage is not sent")
    base.stage = nil
    base.flags = P.PLAYER_FLAGS.HAS_STAGE -- a stale flag without a stage
    T.eq(assert(P.decode(P.encode_player(base))).stage, nil, "flag cleared without a stage")
end)

local function angle_between(a, b)
    local dot = math.abs(a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4])
    return 2 * math.deg(math.acos(math.min(1, dot)))
end

T.run("quaternion_packing_accuracy", function()
    local seed = 12345
    local function rnd()
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        return seed / 0x7FFFFFFF * 2 - 1
    end
    local worst = 0
    for _ = 1, 20000 do
        local q = { rnd(), rnd(), rnd(), rnd() }
        local len = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
        for i = 1, 4 do q[i] = q[i] / len end
        local packed = P.pack_quat(q[1], q[2], q[3], q[4])
        T.check(packed >= 0 and packed <= 0xFFFFFFFF, "fits 32 bits")
        local x, y, z, w = P.unpack_quat(packed)
        worst = math.max(worst, angle_between(q, { x, y, z, w }))
    end
    T.check(worst < 0.3, ("worst angular error %.3f deg under 0.3"):format(worst))
    -- Edge cases: identity, negated, degenerate.
    local x, y, z, w = P.unpack_quat(P.pack_quat(0, 0, 0, 1))
    T.check(angle_between({ 0, 0, 0, 1 }, { x, y, z, w }) < 0.1, "identity")
    x, y, z, w = P.unpack_quat(P.pack_quat(0, 0, 0, -1))
    T.check(angle_between({ 0, 0, 0, 1 }, { x, y, z, w }) < 0.1, "-identity is the same rotation")
    x, y, z, w = P.unpack_quat(P.pack_quat(0, 0, 0, 0))
    T.near(w, 1, 1e-3, "zero quaternion becomes identity")
    x, y, z, w = P.unpack_quat(P.pack_quat(0, 0.7071068, 0, 0.7071068))
    T.near(y, 0.7071068, 2e-3, "90 degrees about y")
end)

local function sample_avatar(nparts, njoints)
    local parts, joints = {}, {}
    for i = 1, nparts do
        parts[i] = {
            name = "cha000_" .. i, mesh = "_chainsaw/character/ch/cha0/cha000/" .. i .. "/cha000_" .. i .. ".mesh",
            mdf = "_chainsaw/character/ch/cha0/cha000/" .. i .. "/cha000_" .. i .. ".mdf2",
            parent = i - 1, flags = P.PART_FLAGS.SAME_JOINTS, parent_joint = i == 2 and "R_Hand" or "",
            lpos = { x = 0.1 * i, y = 0, z = -0.1 }, lrot = { x = 0, y = 0, z = 0.7071068, w = 0.7071068 },
        }
    end
    for i = 1, njoints do
        joints[i] = { hash = P.hash("joint_" .. i), flags = i <= 2 and P.JOINT_FLAGS.TRANSLATE or 0 }
    end
    return { rev = 7, char_id = "ch0a0z0", body_name = "ch0a0z0_body", parts = parts, joints = joints }
end

T.run("avatar_roundtrip", function()
    local src = sample_avatar(6, 300)
    local data = P.encode_avatar(src)
    T.check(#data > MAX, "a full character needs fragmenting (" .. #data .. " bytes)")
    local m = assert(P.decode(data))
    T.eq(m.type, P.T.AVATAR, "type")
    T.eq(m.rev, 7, "rev")
    T.eq(m.char_id, "ch0a0z0", "character id")
    T.eq(m.body_name, "ch0a0z0_body", "body name")
    T.eq(#m.parts, 6, "parts")
    T.eq(m.parts[3].mesh, src.parts[3].mesh, "mesh path")
    T.eq(m.parts[3].mdf, src.parts[3].mdf, "material path")
    T.eq(m.parts[3].parent, 2, "parent")
    T.eq(m.parts[2].parent_joint, "R_Hand", "parent joint")
    T.eq(m.parts[1].flags, P.PART_FLAGS.SAME_JOINTS, "flags")
    T.near(m.parts[4].lpos.x, 0.4, 1e-5, "local position")
    T.near(m.parts[4].lrot.z, 0.7071068, 2e-3, "local rotation")
    T.eq(#m.joints, 300, "joints")
    T.eq(m.joints[123].hash, P.hash("joint_123"), "joint hash")
    T.eq(m.joints[2].flags, P.JOINT_FLAGS.TRANSLATE, "joint flags")
end)

T.run("gear_roundtrip", function()
    local m = assert(P.decode(P.encode_gear({ rev = 3, weapons = {
        { name = "wp4000", mesh = "a.mesh", mdf = "a.mdf2", joints = { P.hash("Slide"), P.hash("Trigger") } },
        { name = "wp5000", mesh = "", mdf = "", joints = {} },
    } })))
    T.eq(m.type, P.T.GEAR, "type")
    T.eq(m.rev, 3, "rev")
    T.eq(#m.weapons, 2, "weapons")
    T.eq(m.weapons[1].name, "wp4000", "name")
    T.eq(m.weapons[1].joints[2], P.hash("Trigger"), "joint hash")
    T.eq(#m.weapons[2].joints, 0, "no joints")
end)

local function sample_pose(njoints)
    local q = {}
    for i = 1, njoints do
        local a = i * 0.01
        q[#q + 1], q[#q + 2], q[#q + 3], q[#q + 4] = math.sin(a), 0, 0, math.cos(a)
    end
    return {
        time = 42.5, avatar_rev = 7, gear_rev = 3, flags = P.POSE_FLAGS.CUTSCENE,
        root_pos = { x = 1.5, y = -2, z = 300.25 }, root_rot = { x = 0, y = 0.3826834, z = 0, w = 0.9238795 },
        q = q, tpos = { { index = 1, x = 0, y = 0.981, z = -0.012 }, { index = 2, x = 0.1, y = 0, z = 0 } },
        weapons = {
            { slot = 1, flags = P.WEAPON_FLAGS.VISIBLE, attach = 17, pos = { x = 0.02, y = 0.01, z = 0.12 },
                rot = { x = 0, y = 0.7071068, z = 0, w = 0.7071068 }, q = { 0, 0, 0, 1, 0, 0.1, 0, 0.995 } },
            { slot = 2, flags = 0, attach = 0, pos = { x = -0.2, y = 1.1, z = -0.15 }, rot = { x = 0, y = 0, z = 0, w = 1 }, q = {} },
        },
    }
end

T.run("pose_roundtrip_and_chunking", function()
    for _, n in ipairs({ 0, 1, 40, 250, 600 }) do
        local src = sample_pose(n)
        local msgs = P.encode_pose(src)
        local got_joints = 0
        local nexpected = math.min(n, P.MAX_POSE_JOINTS)
        for c, data in ipairs(msgs) do
            T.check(#data <= MAX, ("%d joints: chunk %d fits (%d bytes)"):format(n, c, #data))
            local m = assert(P.decode(data))
            T.eq(m.type, P.T.POSE, "type")
            T.eq(m.chunk, c, "chunk index")
            T.eq(m.chunks, #msgs, "chunk count")
            T.near(m.time, 42.5, 1e-9, "time")
            T.eq(m.avatar_rev, 7, "avatar rev")
            T.eq(m.gear_rev, 3, "gear rev")
            T.eq(m.first, got_joints + 1, "chunks are contiguous")
            for i = 1, m.count do
                local k, ks = i * 4, (m.first + i - 1) * 4
                local got = { m.q[k - 3], m.q[k - 2], m.q[k - 1], m.q[k] }
                local want = { src.q[ks - 3], src.q[ks - 2], src.q[ks - 1], src.q[ks] }
                T.check(angle_between(got, want) < 0.3, "joint rotation survives packing")
            end
            got_joints = got_joints + m.count
            if c == 1 then
                T.near(m.root_pos.z, 300.25, 1e-4, "root position")
                T.near(m.root_rot.y, 0.3826834, 2e-3, "root rotation")
                T.eq(m.flags, P.POSE_FLAGS.CUTSCENE, "flags")
                T.eq(#m.weapons, 2, "weapons")
                T.eq(m.weapons[1].attach, 17, "attach joint")
                T.eq(m.weapons[1].flags, P.WEAPON_FLAGS.VISIBLE, "weapon flags")
                T.near(m.weapons[1].pos.z, 0.12, 1e-5, "weapon offset")
                T.near(math.abs(m.weapons[1].q[6]), 0.1, 2e-3, "weapon joint")
                T.eq(#m.weapons[2].q, 0, "weapon without joints")
                T.eq(#m.tpos, 2, "translations")
                T.near(m.tpos[1].y, 0.981, 1e-3, "translation in mm")
            else
                T.check(m.root_pos == nil, "only chunk 1 carries the root")
            end
        end
        T.eq(got_joints, nexpected, n .. " joints all present")
        if n <= 250 then T.eq(#msgs, 1, n .. " joints fit one datagram") end
    end
end)

T.run("actions_roundtrip_and_split", function()
    local args = {
        { tag = P.ARG.U32, value = 0xDEADBEEF }, { tag = P.ARG.I32, value = -5 }, { tag = P.ARG.BOOL, value = true },
        { tag = P.ARG.F32, value = 0.25 }, { tag = P.ARG.OBJ, value = 201 }, { tag = P.ARG.NULL },
        { tag = P.ARG.I64, value = -1234567890123 },
    }
    local events = {}
    for i = 1, 120 do
        if i % 10 == 0 then
            events[i] = { kind = P.EVENT.SHOT, dt = -0.01 * i, slot = 1 }
        else
            events[i] = { kind = P.EVENT.CALL, dt = -0.001 * i, part = i % 5, comp_type = P.hash("chainsaw.WwiseContainerApp"),
                comp_idx = 1, method = 0xABCDEF01, args = args }
        end
    end
    local msgs = P.encode_actions({ time = 9.0, events = events })
    T.check(#msgs > 1, "many events split into several messages")
    local seen = 0
    for _, data in ipairs(msgs) do
        T.check(#data <= MAX, "fits a datagram")
        local m = assert(P.decode(data))
        T.eq(m.type, P.T.ACTIONS, "type")
        T.near(m.time, 9.0, 1e-9, "time")
        for _, ev in ipairs(m.events) do
            seen = seen + 1
            local src = events[seen]
            T.eq(ev.kind, src.kind, "kind")
            T.near(ev.dt, src.dt, 1e-6, "dt")
            if ev.kind == P.EVENT.SHOT then
                T.eq(ev.slot, 1, "slot")
            else
                T.eq(ev.part, src.part, "part")
                T.eq(ev.method, 0xABCDEF01, "method")
                T.eq(ev.args[1].value, 0xDEADBEEF, "u32")
                T.eq(ev.args[2].value, -5, "i32")
                T.eq(ev.args[3].value, true, "bool")
                T.near(ev.args[4].value, 0.25, 1e-7, "f32")
                T.eq(ev.args[5].value, 201, "object ref")
                T.eq(ev.args[6].tag, P.ARG.NULL, "null")
                T.eq(ev.args[7].value, -1234567890123, "i64")
            end
        end
    end
    T.eq(seen, 120, "all events")
    -- Values out of range are clamped instead of raising.
    local odd = P.encode_actions({ time = 0, events = { { kind = P.EVENT.CALL, method = 1,
        args = { { tag = P.ARG.I32, value = 1e12 }, { tag = P.ARG.U32, value = 1.5 } } } } })
    local m = assert(P.decode(odd[1]))
    T.eq(m.events[1].args[1].value, 0x7FFFFFFF, "i32 clamped")
    T.eq(m.events[1].args[2].value, 0, "non-integer u32 becomes 0")
end)

T.run("fragment_and_reassemble", function()
    local big = P.encode_avatar(sample_avatar(20, 500))
    local pieces = assert(P.fragment(big, 77))
    T.check(#pieces > 1, "several fragments")
    local r = P.new_reassembler()
    local out
    for i, piece in ipairs(pieces) do
        T.check(#piece <= MAX, "fragment fits")
        local m = assert(P.decode(piece))
        T.eq(m.type, P.T.FRAG, "type")
        out = r:push(m)
        if i < #pieces then T.check(out == nil, "incomplete until the last piece") end
    end
    T.eq(out, big, "reassembled bytes")
    T.eq(assert(P.decode(out)).char_id, "ch0a0z0", "decodes")
    -- A piece out of sequence drops the partial message instead of corrupting it.
    local r2 = P.new_reassembler()
    T.check(r2:push(assert(P.decode(pieces[1]))) == nil, "first")
    T.check(r2:push(assert(P.decode(pieces[3]))) == nil, "skipped one")
    for i = 2, #pieces do r2:push(assert(P.decode(pieces[i]))) end
    T.check(r2:push(assert(P.decode(pieces[1]))) == nil, "restarts cleanly")
    local again
    for i = 2, #pieces do again = r2:push(assert(P.decode(pieces[i]))) end
    T.eq(again, big, "next complete message still reassembles")
end)

T.run("enemy_states_roundtrip_and_packing", function()
    local entries = {}
    for i = 1, 75 do
        entries[i] = { net_id = i, epoch = i % 7, kind_hash = P.hash("k" .. (i % 3)), pos = { x = i, y = 0.5, z = -i },
            rot = { x = 0, y = math.sin(i / 20), z = 0, w = math.cos(i / 20) }, vel = { x = 1.25, y = 0, z = -i / 10 },
            hp = i * 10, max_hp = 1000, ack = 60000 + i, uid = 0x10000 + i,
            layers = { { bank = 100 + i, id = 2000 + i, frame = i / 4, speed = 1.5 }, { bank = 7, id = 8, frame = 9, speed = 1 } } }
    end
    entries[10].uid = 0xFEDCBA98
    entries[13].uid = nil -- a runtime enemy: its spawn point travels instead
    entries[13].spawn = { x = 99, y = 1, z = 98 }
    entries[11].layers = nil
    entries[12].hidden = true
    entries[14].pinfo = P.PARTNER_INFO.KNOWN | P.PARTNER_INFO.FATAL | P.PARTNER_INFO.TARGETS
    entries[14].ftype = 4
    local msgs = P.encode_enemy_states(9.5, entries)
    T.check(#msgs >= 4 and #msgs <= 6, ("75 enemies with two layers in %d messages"):format(#msgs))
    local seen = 0
    for c, data in ipairs(msgs) do
        T.check(#data <= MAX, ("message %d fits in one datagram (%d bytes)"):format(c, #data))
        local m = assert(P.decode(data))
        T.eq(m.type, P.T.ENEMY_STATE, "type")
        T.eq(m.chunk, c, "chunk index")
        T.eq(m.chunks, #msgs, "chunk count")
        T.near(m.time, 9.5, 1e-9, "time")
        for _, e in ipairs(m.enemies) do
            seen = seen + 1
            local src = entries[seen]
            T.eq(e.net_id, seen, "order preserved")
            T.eq(e.epoch, seen % 7, "ownership epoch")
            T.eq(e.hp, seen * 10, "hp")
            T.eq(e.max_hp, 1000, "max hp")
            T.eq(e.ack, (60000 + seen) & 0xFFFF, "hit ack")
            T.eq(e.alive, true, "alive")
            T.eq(e.hidden, seen == 12, "visibility")
            if seen == 14 then
                T.eq(e.pinfo, P.PARTNER_INFO.KNOWN | P.PARTNER_INFO.FATAL | P.PARTNER_INFO.TARGETS,
                    "what the enemy says about the client's player")
                T.eq(e.ftype, 4, "the finisher it offers")
            else
                T.eq(e.pinfo, 0, "nothing said")
                T.eq(e.ftype, 0, "no finisher")
            end
            T.near(e.pos.y, 0.5, 1e-6, "position")
            local dot = e.rot.x * src.rot.x + e.rot.y * src.rot.y + e.rot.z * src.rot.z + e.rot.w * src.rot.w
            T.check(math.abs(dot) > 0.99999, "rotation (q and -q are the same)")
            T.near(e.vel.x, 1.25, 0.01, "velocity")
            T.near(e.vel.z, -seen / 10, 0.01, "velocity z")
            if seen == 13 then
                T.eq(e.uid, nil, "no uid when none was sent")
                T.near(e.spawn.x, 99, 1e-6, "spawn point for a runtime enemy")
            else
                T.eq(e.uid, src.uid, "uid round-trips (all 32 bits)")
                T.eq(e.spawn, nil, "no spawn point needed with a uid")
            end
            if seen == 11 then
                T.eq(#e.layers, 0, "no animation when none was sent")
            else
                T.eq(#e.layers, 2, "two layers")
                T.eq(e.layers[1].bank, 100 + seen, "bank")
                T.eq(e.layers[1].id, 2000 + seen, "motion")
                T.near(e.layers[1].frame, seen / 4, 1e-5, "frame")
                T.near(e.layers[1].speed, 1.5, 1e-6, "speed")
                T.eq(e.layers[2].id, 8, "second layer")
            end
        end
    end
    T.eq(seen, 75, "all entries")
    local one = P.encode_enemy_states(1, {})
    T.eq(#one, 1, "an empty list still yields one message (the owner is alive)")
    T.eq(#assert(P.decode(one[1])).enemies, 0, "empty")
    local many = { { net_id = 1, pos = { x = 0, y = 0, z = 0 }, layers = {} } }
    for i = 1, 5 do many[1].layers[i] = { bank = 1, id = i, frame = 0, speed = 1 } end
    T.eq(#assert(P.decode(P.encode_enemy_states(1, many)[1])).enemies[1].layers, P.MAX_ENEMY_LAYERS,
        "layers capped")
end)

T.run("enemy_hits_carry_every_value", function()
    local fields = {
        { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = -140 },
        { h = P.hash("Wince"), t = P.HIT_VALUE.F32, v = 30.5 },
        { h = P.hash("IsCritical"), t = P.HIT_VALUE.BOOL, v = true },
        { h = P.hash("DamageDir"), t = P.HIT_VALUE.VEC3, v = { x = 0, y = 0.5, z = -1 } },
        { h = P.hash("Flags"), t = P.HIT_VALUE.U32, v = 0xFFFFFFFF },
        { h = P.hash("Big"), t = P.HIT_VALUE.I64, v = 1 << 40 },
        { h = P.hash("Exact"), t = P.HIT_VALUE.F64, v = 1 / 3 },
        { h = 1, t = 99, v = 5 }, -- unknown tag: not sent
    }
    local h = assert(P.decode(P.encode_enemy_hit({ net_id = 12, epoch = 200, kind_hash = 77, pos = { x = 1, y = 2, z = 3 },
        damage = 140.5, hp = 90, seq = 65535, uid = 0xABCDEF01, critical = true,
        flags = P.HIT_FLAGS.APPLY | P.HIT_FLAGS.LETHAL, fields = fields })))
    T.eq(h.type, P.T.ENEMY_HIT, "type")
    T.eq(h.net_id, 12, "net id")
    T.eq(h.epoch, 200, "epoch")
    T.eq(h.kind_hash, 77, "kind")
    T.near(h.pos.z, 3, 1e-6, "identity position")
    T.near(h.damage, 140.5, 1e-6, "damage")
    T.near(h.hp, 90, 1e-6, "HP it had")
    T.eq(h.seq, 65535, "sequence")
    T.eq(h.uid, 0xABCDEF01, "uid")
    T.eq(h.apply, true, "for the owner to run")
    T.eq(h.lethal, true, "lethal")
    T.eq(h.critical, true, "critical")
    T.eq(#h.fields, 7, "every known value, the unknown one dropped")
    T.eq(h.fields[1].v, -140, "int32")
    T.near(h.fields[2].v, 30.5, 1e-6, "float")
    T.eq(h.fields[3].v, true, "bool")
    T.near(h.fields[4].v.y, 0.5, 1e-6, "vector")
    T.eq(h.fields[5].v, 0xFFFFFFFF, "uint32")
    T.eq(h.fields[6].v, 1 << 40, "int64")
    T.near(h.fields[7].v, 1 / 3, 1e-15, "double")
    T.eq(h.fields[1].h, P.hash("Damage"), "by name hash")
    local bare = assert(P.decode(P.encode_enemy_hit({ pos = { x = 0, y = 0, z = 0 } })))
    T.eq(bare.uid, nil, "no uid")
    T.eq(#bare.fields, 0, "no values")
    T.eq(bare.apply, false, "a tracer only")
    local big = {}
    for i = 1, 80 do big[i] = { h = i, t = P.HIT_VALUE.VEC3, v = { x = i, y = i, z = i } } end
    local data = P.encode_enemy_hit({ pos = { x = 0, y = 0, z = 0 }, fields = big })
    T.check(#data <= MAX, ("the largest hit fits a datagram (%d bytes)"):format(#data))
    T.eq(#assert(P.decode(data)).fields, P.MAX_HIT_FIELDS, "values capped")
end)

T.run("enemy_deaths_owners_and_rosters", function()
    local d = assert(P.decode(P.encode_enemy_death({ net_id = 65535, epoch = 3, uid = 0x89ABCDEF, kind_hash = 5,
        pos = { x = 4, y = 5, z = 6 }, rot = { x = 0, y = 1, z = 0, w = 0 },
        fields = { { h = 1, t = P.HIT_VALUE.I32, v = 999 } } })))
    T.eq(d.type, P.T.ENEMY_DEATH, "type")
    T.eq(d.net_id, 65535, "net id")
    T.eq(d.epoch, 3, "epoch")
    T.eq(d.uid, 0x89ABCDEF, "uid")
    T.near(d.pos.y, 5, 1e-6, "where it died")
    T.near(math.abs(d.rot.y), 1, 0.003, "its rotation")
    T.eq(d.fields[1].v, 999, "the killing hit")
    T.eq(d.reset, false, "not a reset")
    T.eq(d.erased, false, "a death")
    T.eq(d.by_client, false, "the host's kill")
    local mine = assert(P.decode(P.encode_enemy_death({ net_id = 2, uid = 5, flags = P.DEATH_FLAGS.BY_CLIENT,
        fields = { { h = 1, t = P.HIT_VALUE.I32, v = 1 } } })))
    T.eq(mine.by_client, true, "the client's player's kill")
    T.eq(mine.fields[1].v, 1, "with its killing hit")
    local bare = assert(P.decode(P.encode_enemy_death({ net_id = 9, flags = P.DEATH_FLAGS.ERASED })))
    T.eq(bare.uid, nil, "runtime enemy: no uid")
    T.eq(bare.fields, nil, "no killing hit")
    T.eq(bare.erased, true, "erased")
    local reset = assert(P.decode(P.encode_enemy_reset()))
    T.eq(reset.reset, true, "reset")

    local owners = {}
    for i = 1, 200 do owners[i] = { net_id = i, epoch = i % 256, owner = i % 2, uid = 0x100 + i, hp = i } end
    owners[200].owner = P.OWNER.NONE
    owners[199].hp = nil
    local msgs = P.encode_enemy_owners(owners)
    T.eq(#msgs, 3, "200 owners -> 3 messages")
    local got = {}
    for _, data in ipairs(msgs) do
        T.check(#data <= MAX, ("owner message fits (%d bytes)"):format(#data))
        for _, o in ipairs(assert(P.decode(data)).owners) do got[#got + 1] = o end
    end
    T.eq(#got, 200, "all")
    T.eq(got[7].owner, P.OWNER.CLIENT, "owner")
    T.eq(got[8].owner, P.OWNER.HOST, "owner")
    T.eq(got[7].epoch, 7, "epoch")
    T.eq(got[7].uid, 0x107, "uid")
    T.eq(got[7].hp, 7, "HP at the change")
    T.eq(got[199].hp, nil, "no HP")
    T.eq(got[200].owner, P.OWNER.NONE, "retired")
    T.eq(#P.encode_enemy_owners({}), 0, "nothing to send")

    local roster = {}
    for i = 1, 300 do roster[i] = { net_id = i, flags = P.ROSTER_FLAGS.ALIVE | (i % 2 == 0 and P.ROSTER_FLAGS.LOCAL_RUN or 0), hp = i / 2 } end
    local rm = P.encode_enemy_roster(4.5, roster)
    T.eq(#rm, 2, "300 entries -> 2 messages")
    local r = assert(P.decode(rm[1]))
    T.check(#rm[1] <= MAX, "fits")
    T.eq(r.type, P.T.ENEMY_ROSTER, "type")
    T.near(r.time, 4.5, 1e-9, "time")
    T.eq(r.entries[2].local_run, true, "running on the client's own AI")
    T.eq(r.entries[1].local_run, false, "not")
    T.eq(r.entries[1].alive, true, "alive")
    T.near(r.entries[3].hp, 1.5, 1e-6, "hp")
    T.eq(#P.encode_enemy_roster(1, {}), 1, "an empty roster is still sent")
end)

T.run("character_identity", function()
    T.check(P.character_id_stable({ category = 0, kind = 0, group = 12, index = 312 }), "level enemy (group 12)")
    T.check(P.character_id_stable({ category = 0, kind = 0, group = 40200, index = 3 }), "level enemy (stage group)")
    T.check(not P.character_id_stable({ category = 0, kind = 0, group = 1, index = 5 }),
        "runtime character (CharacterManager.generateDynamicContextID: group 1)")
    T.check(not P.character_id_stable({ category = 2, kind = 0, group = 12, index = 3 }), "not a character")
    T.check(not P.character_id_stable({ category = 0, kind = 0, group = 0, index = 0 }), "empty ID")
    T.check(not P.character_id_stable(nil), "no ID")
end)

T.run("enemy_graveyard", function()
    local uids = {}
    for i = 1, 700 do uids[i] = 0x10000000 + i end
    uids[701] = 0 -- never sent
    local msgs = P.encode_enemy_grave(uids)
    T.eq(#msgs, 3, "700 uids -> 3 messages")
    local got = {}
    for c, data in ipairs(msgs) do
        T.check(#data <= MAX, ("graveyard chunk %d fits (%d bytes)"):format(c, #data))
        local m = assert(P.decode(data))
        T.eq(m.type, P.T.ENEMY_GRAVE, "type")
        T.eq(m.chunk, c, "chunk")
        T.eq(m.chunks, 3, "chunks")
        for _, u in ipairs(m.uids) do got[#got + 1] = u end
    end
    T.eq(#got, 700, "every uid, no zero")
    T.eq(got[700], 0x10000000 + 700, "order kept")
    local empty = P.encode_enemy_grave({})
    T.eq(#empty, 1, "an empty graveyard is still sent (it replaces the old one)")
    T.eq(#assert(P.decode(empty[1])).uids, 0, "empty")
end)

T.run("small_messages_roundtrip", function()
    local it = assert(P.decode(P.encode_item_taken({ item_id = 119235200, pos = { x = 4, y = 5, z = 6 },
        ctx = { category = 5, kind = 0, group = 9, index = 2 } })))
    T.eq(it.type, P.T.ITEM_TAKEN, "item taken type")
    T.eq(it.item_id, 119235200, "item id")
    T.near(it.pos.z, 6, 1e-6, "position")
    T.eq(P.ctx_key(it.ctx), "5:0:9:2", "item ContextID")
    T.eq(it.stage, nil, "no stage")
    T.eq(it.only_instance, false, "not flagged as only instance")
    local bare = assert(P.decode(P.encode_item_taken({ item_id = 1, pos = { x = 0, y = 0, z = 0 } })))
    T.eq(bare.ctx, nil, "item without ctx")
    local it2 = assert(P.decode(P.encode_item_taken({ item_id = 119288000, pos = { x = 0, y = 0, z = 0 },
        stage = 43400, only_instance = true })))
    T.eq(it2.stage, 43400, "item stage")
    T.eq(it2.only_instance, true, "only instance")
    T.eq(assert(P.decode(P.encode_chat("hola amigo"))).text, "hola amigo", "chat")
    T.eq(#assert(P.decode(P.encode_chat(string.rep("x", 2000)))).text, 512, "chat truncated")
    local n = assert(P.decode(P.encode_notify(3, "teleported")))
    T.eq(n.code, 3, "notify code")
    T.eq(n.text, "teleported", "notify text")
end)

T.run("player_chapter_and_gate_flag", function()
    local m = assert(P.decode(P.encode_player({ time = 1, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 },
        chapter = 21100, stage = 43300, flags = P.PLAYER_FLAGS.GATE_WAITING })))
    T.eq(m.chapter, 21100, "chapter")
    T.eq(m.stage, 43300, "stage still there")
    T.check((m.flags & P.PLAYER_FLAGS.GATE_WAITING) ~= 0, "gate flag")
    local m2 = assert(P.decode(P.encode_player({ time = 1, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 } })))
    T.eq(m2.chapter, nil, "no chapter")
end)

T.run("item_dropped_roundtrip", function()
    local d = assert(P.decode(P.encode_item_dropped({ net_id = 5, item_id = 124000000, count = 300,
        pos = { x = 7, y = 0.5, z = -2 }, stage = 43400 })))
    T.eq(d.type, P.T.ITEM_DROPPED, "type")
    T.eq(d.net_id, 5, "enemy")
    T.eq(d.item_id, 124000000, "item")
    T.eq(d.count, 300, "count")
    T.near(d.pos.x, 7, 1e-6, "position")
    T.eq(d.stage, 43400, "stage")
    T.eq(assert(P.decode(P.encode_item_dropped({ item_id = 1, count = 1, pos = { x = 0, y = 0, z = 0 } }))).stage, nil,
        "no stage")
end)

local G1 = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"
local G2 = "ffffffff-0000-1111-2222-333344445555"

T.run("guid_and_ctx_helpers", function()
    local b = P.guid_to_bytes(G1)
    T.eq(#b, 16, "16 bytes")
    T.eq(P.guid_from_bytes(b), G1, "round trip")
    T.eq(P.normalize_guid("{0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9}"), G1, "braces and case")
    T.eq(P.normalize_guid("0a1b2c3d4e5f60718293a4b5c6d7e8f9"), G1, "no dashes")
    T.check(P.normalize_guid("not-a-guid") == nil, "garbage rejected")
    T.check(P.guid_to_bytes(42) == nil, "non-string rejected")
    local back = P.ctx_from_key(P.ctx_key({ category = 1, kind = 7, group = 40210, index = -5 }))
    T.check(back.category == 1 and back.kind == 7 and back.group == 40210 and back.index == -5, "ctx key round trip")
end)

T.run("animals_roundtrip_and_chunking", function()
    local animals = {}
    for i = 1, 50 do
        animals[i] = { guid = ("%08x-0000-0000-0000-%012x"):format(i, i), pos = { x = i, y = 2, z = -i },
            rot = { x = 0, y = math.sin(i / 10), z = 0, w = math.cos(i / 10) }, routine = i % 9,
            motion = { bank = 300 + i, id = 40 + i, frame = i / 2 }, dead = i == 7 }
    end
    animals[8].routine = nil
    animals[9].motion = nil
    animals[51] = { guid = "bogus", pos = { x = 0, y = 0, z = 0 } }
    local msgs = P.encode_animals(4.25, animals)
    T.eq(#msgs, 3, "50 animals -> 3 messages (" .. P.ANIMALS_PER_MESSAGE .. " each)")
    local got = {}
    for c, data in ipairs(msgs) do
        T.check(#data <= MAX, ("chunk %d fits in one datagram (%d bytes)"):format(c, #data))
        local m = assert(P.decode(data))
        T.eq(m.type, P.T.ANIMALS, "type")
        T.eq(m.chunk, c, "chunk")
        T.eq(m.chunks, 3, "chunks")
        T.near(m.time, 4.25, 1e-9, "time")
        for _, a in ipairs(m.animals) do got[#got + 1] = a end
    end
    T.eq(#got, 50, "the bad GUID is skipped")
    local a = got[5]
    T.eq(a.guid, animals[5].guid, "guid")
    T.near(a.pos.x, 5, 1e-5, "position")
    T.near(a.rot.y, math.sin(0.5), 2e-3, "rotation")
    T.near(a.rot.w, math.cos(0.5), 2e-3, "rotation w")
    T.eq(a.routine, 5, "routine")
    T.check(a.motion and a.motion.bank == 305 and a.motion.id == 45, "animation")
    T.near(a.motion.frame, 2.5, 1e-5, "frame")
    T.eq(a.dead, false, "alive")
    T.eq(got[7].dead, true, "dead flag")
    T.eq(got[8].routine, nil, "no routine")
    T.eq(got[9].motion, nil, "no animation")
end)

T.run("flags_roundtrip_and_batching", function()
    local flags = {}
    for i = 1, 150 do
        flags[i] = { guid = ("%08x-0000-0000-0000-%012x"):format(i, i * 7), value = i % 3 ~= 0 }
    end
    flags[151] = { guid = "bogus", value = true }
    local msgs = P.encode_flags(flags)
    T.eq(#msgs, 3, "150 flags -> 3 messages")
    local got = {}
    for _, data in ipairs(msgs) do
        T.check(#data <= MAX, "fits")
        for _, f in ipairs(assert(P.decode(data)).flags) do got[#got + 1] = f end
    end
    T.eq(#got, 150, "invalid guid skipped")
    T.eq(got[1].guid, flags[1].guid, "first guid")
    T.eq(got[3].value, false, "value false")
    T.eq(got[150].guid, flags[150].guid, "last guid")
    T.eq(#P.encode_flags({}), 1, "empty batch is one (empty) message")
    local pulse = assert(P.decode(P.encode_flags({ { guid = flags[1].guid, value = true, pulse = true },
        { guid = flags[2].guid, value = true } })[1])).flags
    T.eq(pulse[1].pulse, true, "a pulse travels as one")
    T.eq(pulse[1].value, true, "and counts as on")
    T.eq(pulse[2].pulse, false, "a plain flag is not a pulse")
end)

T.run("flag_words_full_and_delta", function()
    local big = {}
    for i = 1, 700 do big[i] = (i * 2654435761) & 0xFFFFFFFF end
    local msgs = P.encode_flag_words(9, P.FLAG_WORDS_MODE.FULL, {
        { name = "Main", words = big }, { name = "Sub", words = { 1, 2, 3 } },
        { name = string.rep("L", 300), words = big } })
    T.check(#msgs >= 4, "large groups split into chunks (" .. #msgs .. ")")
    local words, long = {}, {}
    local n_sub = 0
    for c, data in ipairs(msgs) do
        T.check(#data <= MAX, ("chunk %d fits (%d bytes)"):format(c, #data))
        local m = assert(P.decode(data))
        T.eq(m.sync_id, 9, "sync id")
        T.eq(m.chunk, c, "chunk")
        T.eq(m.chunks, #msgs, "chunks")
        for _, g in ipairs(m.groups) do
            local into = g.name == "Main" and words or (g.name == "Sub" and {} or long)
            if g.name == "Sub" then n_sub = n_sub + #g.words end
            for k, w in ipairs(g.words) do into[g.first + k] = w end
        end
    end
    local same, same_long = true, true
    for i = 1, 700 do
        if words[i] ~= big[i] then same = false end
        if long[i] ~= big[i] then same_long = false end
    end
    T.check(same, "all 700 words arrive in order")
    T.check(same_long, "a group with a 255-byte name too")
    T.eq(n_sub, 3, "second group")

    local changes = {}
    for i = 1, 400 do changes[i] = { word = i, set = i, clear = 0x80000000 } end
    local dmsgs = P.encode_flag_words(0, P.FLAG_WORDS_MODE.DELTA, { { name = "Main", changes = changes } })
    local n = 0
    for _, data in ipairs(dmsgs) do
        T.check(#data <= MAX, "delta chunk fits (" .. #data .. " bytes)")
        local m = assert(P.decode(data))
        T.eq(m.mode, P.FLAG_WORDS_MODE.DELTA, "delta mode")
        for _, g in ipairs(m.groups) do
            for _, c in ipairs(g.changes) do
                n = n + 1
                if c.word ~= n or c.set ~= n or c.clear ~= 0x80000000 then T.check(false, "change " .. n) end
            end
        end
    end
    T.eq(n, 400, "every change arrives")
end)

T.run("gimmicks_roundtrip_and_chunking", function()
    local items = {}
    for i = 1, 80 do
        items[i] = { ctx = { category = 1, kind = 1, group = 40200 + i, index = -i }, attr = string.rep(string.char(i % 256), 20),
            triggers = { { id = i, done = 1 }, { id = i + 1000, done = 0 } }, detected = i % 2 == 0,
            acc = { { kind = 1, value = 1.5 }, { kind = 2, value = i } } }
    end
    items[81] = { ctx = { category = 1, kind = 0, group = 1, index = 1 }, attr = string.rep("A", 255),
        triggers = {}, detected = false, acc = {} }
    for t = 1, 64 do items[81].triggers[t] = { id = t, done = 1 } end
    for a = 1, 64 do items[81].acc[a] = { kind = 2, value = a } end
    local msgs = P.encode_gimmicks(4, P.GIMMICK_MODE.FULL, items)
    T.check(#msgs >= 2, "chunked")
    local got = {}
    for _, data in ipairs(msgs) do
        T.check(#data <= MAX, "chunk fits (" .. #data .. " bytes)")
        local m = assert(P.decode(data))
        T.eq(m.mode, P.GIMMICK_MODE.FULL, "mode")
        T.eq(m.sync_id, 4, "sync id")
        for _, it in ipairs(m.items) do got[#got + 1] = it end
    end
    T.eq(#got, 81, "all items")
    T.eq(P.ctx_key(got[10].ctx), "1:1:40210:-10", "ContextID")
    T.eq(got[10].attr, items[10].attr, "attr bytes")
    T.eq(got[10].triggers[2].id, 1010, "trigger id")
    T.eq(got[10].detected, true, "detected")
    T.near(got[10].acc[1].value, 1.5, 1e-6, "float accessory value")
    T.eq(got[10].acc[2].value, 10, "uint accessory value")
    T.eq(#got[81].triggers, 64, "largest item survives")
end)

T.run("objects_cutscene_world_roundtrip", function()
    local o = assert(P.decode(P.encode_objects({ { guid = G1, event = P.OBJECT_EVENT.DESTROYED, value = -1 },
        { guid = G2, event = P.OBJECT_EVENT.ROUTINE, value = 4 } })[1]))
    T.eq(#o.events, 2, "two events")
    T.eq(o.events[1].guid, G1, "guid")
    T.eq(o.events[1].value, -1, "value")
    T.eq(o.events[2].event, P.OBJECT_EVENT.ROUTINE, "event")
    local many = {}
    for i = 1, 130 do many[i] = { guid = ("%08x-0000-0000-0000-000000000000"):format(i), event = 1, value = i } end
    local msgs = P.encode_objects(many)
    T.eq(#msgs, 3, "130 events -> 3 messages")
    for _, data in ipairs(msgs) do T.check(#data <= MAX, "fits") end

    -- A cutscene as the game's PayloadPlay describes it.
    local starts, ends = {}, {}
    for i = 1, 60 do starts[i] = { group = i % 7, index = i * 3 } end
    ends[1] = { group = 12, index = -1 }
    local c = assert(P.decode(P.encode_cutscene({ camera = P.CAMERA.TIMELINE, id = 20130, screen = 3,
        owner_code = 0xF0000001, end_portrayal = 0xDEADBEEF, start_flags = starts, end_flags = ends,
        chapter = 21300, stage = 45200, pos = { x = 1, y = 2, z = 3 }, flags = P.CUTSCENE_FLAGS.LOCAL_TRIGGER })))
    T.eq(c.camera, P.CAMERA.TIMELINE, "camera type")
    T.eq(c.id, 20130, "cutscene id")
    T.eq(c.screen, 3, "screen")
    T.eq(c.owner_code, 0xF0000001, "data owner code (full u32)")
    T.eq(c.end_portrayal, 0xDEADBEEF, "next scripted step")
    T.eq(#c.start_flags, P.MAX_CUTSCENE_FLAGS, "start flags capped")
    T.eq(c.start_flags[2].group, 2, "flag group")
    T.eq(c.start_flags[2].index, 6, "flag index")
    T.eq(c.end_flags[1].index, -1, "signed")
    T.eq(#c.coords, 0, "no player placements for a timeline")
    T.eq(c.chapter, 21300, "chapter")
    T.eq(c.stage, 45200, "stage")
    T.near(c.pos.z, 3, 1e-6, "pos")
    T.eq(c.flags, P.CUTSCENE_FLAGS.LOCAL_TRIGGER, "flags")
    local big = P.encode_cutscene({ camera = P.CAMERA.MOVIE, id = 7, start_flags = starts, end_flags = starts,
        coords = { { kind = 1, pos = { x = 4, y = 5, z = 6 }, rot_y = 0.5, reset_camera = true, only_pc = true },
            { kind = 2 }, { kind = 3 }, { kind = 4 }, { kind = 5 }, { kind = 6 }, { kind = 7 }, { kind = 8 }, { kind = 9 } } })
    T.check(#big <= MAX, "the largest cutscene fits one datagram")
    local mv = assert(P.decode(big))
    T.eq(mv.camera, P.CAMERA.MOVIE, "movie")
    T.eq(#mv.coords, P.MAX_CUTSCENE_COORDS, "placements capped")
    T.eq(mv.coords[1].kind, 1, "player kind")
    T.near(mv.coords[1].pos.y, 5, 1e-6, "placement")
    T.near(mv.coords[1].rot_y, 0.5, 1e-6, "facing")
    T.eq(mv.coords[1].reset_camera, true, "reset camera")
    T.eq(mv.coords[1].only_pc, true, "only PC")
    T.eq(mv.coords[1].only_npc, false, "not only NPC")
    T.eq(mv.owner_code, 0xFFFFFFFF, "no data owner")

    local tr = assert(P.decode(P.encode_trigger({ guid = G1, hash = 0xCAFEBABE, trigger_type = 1, once = true,
        head = true, chapter = 21100, stage = 40200, pos = { x = 7, y = 8, z = 9 } })))
    T.eq(tr.type, P.T.TRIGGER, "trigger")
    T.eq(tr.guid, G1, "GameObject guid")
    T.eq(tr.hash, 0xCAFEBABE, "name hash")
    T.eq(tr.trigger_type, 1, "area hit")
    T.eq(tr.once, true, "once")
    T.eq(tr.head, true, "head")
    T.eq(tr.stage, 40200, "stage")
    T.near(tr.pos.y, 8, 1e-6, "where")
    T.eq(P.encode_trigger({ guid = "nope", hash = 1 }), nil, "needs a guid")

    local r = assert(P.decode(P.encode_world_request(77, P.WORLD.FLAGS | P.WORLD.GIMMICKS)))
    T.eq(r.sync_id, 77, "request id")
    T.eq(r.what, 3, "what")
    local d = assert(P.decode(P.encode_world_done(77, 3, 12, 345)))
    T.eq(d.n_flag_groups, 12, "flag groups")
    T.eq(d.n_gimmicks, 345, "gimmicks")
end)

T.run("malformed_input_never_raises", function()
    T.check(P.decode("") == nil, "empty")
    T.check(P.decode(nil) == nil, "nil")
    T.check(P.decode(string.char(250)) == nil, "unknown type")
    T.check(P.decode(string.char(3) .. "\0") == nil, "retired SKELETON type is unknown")
    for _, t in ipairs({ 4, 5, 6, 15, 17 }) do
        T.check(P.decode(string.char(t) .. string.rep("\0", 64)) == nil, "retired enemy message " .. t .. " is unknown")
    end
    local samples = {
        P.encode_player({ time = 1, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 } }),
        P.encode_avatar(sample_avatar(2, 3)),
        P.encode_gear({ rev = 1, weapons = { { name = "wp4000", mesh = "m", mdf = "d", joints = { 1, 2 } } } }),
        P.encode_pose(sample_pose(5))[1],
        P.encode_actions({ time = 1, events = { { kind = P.EVENT.CALL, method = 5, args = { { tag = P.ARG.U32, value = 1 } } },
            { kind = P.EVENT.SHOT, slot = 1 } } })[1],
        P.fragment(string.rep("z", 3000), 1)[1],
        P.encode_item_taken({ item_id = 119235200, pos = { x = 1, y = 2, z = 3 },
            ctx = { category = 5, kind = 0, group = 9, index = 2 } }),
        P.encode_enemy_hit({ pos = { x = 0, y = 0, z = 0 }, uid = 5, fields = { { h = 1, t = P.HIT_VALUE.VEC3,
            v = { x = 1, y = 2, z = 3 } }, { h = 2, t = P.HIT_VALUE.BOOL, v = true } } }),
        P.encode_enemy_death({ net_id = 4, uid = 77, fields = { { h = 1, t = P.HIT_VALUE.I32, v = 3 } } }),
        P.encode_enemy_grave({ 1, 2, 3 })[1],
        P.encode_enemy_states(1, { { net_id = 1, uid = 8, kind_hash = 2, pos = { x = 0, y = 0, z = 0 },
            layers = { { bank = 1, id = 2, frame = 3, speed = 1 } } }, { net_id = 2, pos = { x = 0, y = 0, z = 0 } } })[1],
        P.encode_enemy_owners({ { net_id = 1, epoch = 2, owner = 1, uid = 3, hp = 4 } })[1],
        P.encode_enemy_roster(1, { { net_id = 5, flags = 1, hp = 3 } })[1],
        P.encode_item_dropped({ item_id = 1, count = 1, pos = { x = 0, y = 0, z = 0 } }),
        P.encode_player({ time = 1, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 },
            stage = 43300, chapter = 21100 }),
        P.encode_animals(1, { { guid = G1, pos = { x = 0, y = 0, z = 0 }, routine = 2, motion = { bank = 1, id = 2, frame = 3 } } })[1],
        P.encode_flags({ { guid = G1, value = true } })[1],
        P.encode_flag_words(1, P.FLAG_WORDS_MODE.FULL, { { name = "Main", words = { 1, 2 } } })[1],
        P.encode_flag_words(1, P.FLAG_WORDS_MODE.DELTA, { { name = "Main", changes = { { word = 1, set = 1, clear = 0 } } } })[1],
        P.encode_gimmicks(1, P.GIMMICK_MODE.DELTA, { { ctx = { category = 1, kind = 0, group = 2, index = 3 }, attr = "ab",
            triggers = { { id = 1, done = 1 } }, detected = true, acc = { { kind = 1, value = 2 } } } })[1],
        P.encode_objects({ { guid = G1, event = 1, value = 2 } })[1],
        P.encode_cutscene({ id = 1, chapter = 2, stage = 3, start_flags = { { group = 1, index = 2 } } }),
        P.encode_cutscene({ camera = 2, id = 1, coords = { { kind = 1 } } }),
        P.encode_trigger({ guid = G1, hash = 5, trigger_type = 1, once = true }),
        P.encode_flags({ { guid = G1, value = true, pulse = true } })[1],
        P.encode_world_request(1, 15),
        P.encode_world_done(1, 15, 2, 3),
    }
    for _, good in ipairs(samples) do
        local t = good:byte(1)
        for cut = 1, #good - 1 do
            local m, err = P.decode(good:sub(1, cut))
            -- A truncated FRAG is still a (shorter) valid fragment once its header is complete.
            if not (t == P.T.FRAG and cut >= 5) then
                T.check(m == nil and err ~= nil, ("truncated message type %d at %d"):format(t, cut))
            end
        end
    end
    -- An empty FLAGS or OBJECTS batch (count 0) is a complete, valid message.
    local empty_ok = { [3] = true, [P.T.FLAGS] = true, [P.T.OBJECTS] = true, [P.T.ENEMY_OWNER] = true }
    for t = 1, 31 do
        if not empty_ok[t] then
            local m = P.decode(string.char(t) .. "\0")
            T.check(m == nil, "short message type " .. t)
        end
    end
    T.check(P.decode(string.pack("<BI2BB", P.T.FRAG, 1, 3, 2)) == nil, "fragment index beyond count")
    T.check(P.decode(string.pack("<BdB", P.T.ACTIONS, 0, 1) .. string.pack("<Bf", 99, 0)) == nil, "unknown event kind")
end)

T.run("doors_roundtrip", function()
    local doors = {}
    for i = 1, 70 do
        doors[i] = { guid = ("%08x-0000-0000-0000-000000000000"):format(i), open = i % 2 == 0, hold = i % 3 == 0, attr = i }
    end
    local msgs = P.encode_doors(doors)
    T.eq(#msgs, 2, "split at 60 per message")
    local m = assert(P.decode(msgs[1]))
    T.eq(m.type, P.T.DOORS, "type")
    T.eq(#m.doors, 60, "first part")
    T.eq(m.doors[2].guid, doors[2].guid, "guid")
    T.eq(m.doors[2].open, true, "open")
    T.eq(m.doors[3].hold, true, "hold")
    T.eq(m.doors[5].attr, 5, "attr")
    T.check(#msgs[1] <= P.MAX_PAYLOAD, "fits one datagram")
    T.eq(P.decode(msgs[1]:sub(1, 20)), nil, "truncated")
end)

T.run("item_give_roundtrip", function()
    local m = assert(P.decode(P.encode_item_give({ seq = 7, item_id = 114400000, count = 3, durability = -1 })))
    T.eq(m.type, P.T.ITEM_GIVE, "type")
    T.eq(m.seq, 7, "seq")
    T.eq(m.item_id, 114400000, "item")
    T.eq(m.count, 3, "count")
    T.eq(m.durability, -1, "durability")
    local r = assert(P.decode(P.encode_item_give_result({ seq = 7, returned = 2 })))
    T.eq(r.type, P.T.ITEM_GIVE_RESULT, "result type")
    T.eq(r.returned, 2, "returned")
end)

T.run("enemy_fatal_roundtrip", function()
    local m = assert(P.decode(P.encode_enemy_fatal({ net_id = 513, epoch = 1, uid = 0xCAFEBABE, kind_hash = 99,
        kind = P.FATAL_KIND.NORMAL, ftype = 2, pos = { x = 1, y = 2, z = 3 }, yaw = -1.5 })))
    T.eq(m.type, P.T.ENEMY_FATAL, "type")
    T.eq(m.net_id, 513, "net id")
    T.eq(m.epoch, 1, "epoch")
    T.eq(m.uid, 0xCAFEBABE, "uid")
    T.eq(m.kind_hash, 99, "kind hash")
    T.eq(m.kind, P.FATAL_KIND.NORMAL, "a kick")
    T.eq(m.ftype, 2, "its FatalType")
    T.near(m.pos.y, 2, 1e-6, "where the client's player was")
    T.near(m.yaw, -1.5, 1e-6, "facing")
    local bare = assert(P.decode(P.encode_enemy_fatal({ net_id = 7, kind = P.FATAL_KIND.KILL })))
    T.eq(bare.uid, nil, "no uid")
    T.eq(bare.ftype, 0, "no type")
    T.eq(P.T.ENEMY_FATAL ~= 37, true, "the old claim number stays unused")
end)

T.run("player_noise_roundtrip", function()
    local noises = {}
    for i = 1, 20 do
        noises[i] = { pos = { x = i, y = 0.5, z = -i }, radius = 10 + i, height = 3, volume = 0.5 + i / 100, sub = 2 }
    end
    local data = P.encode_player_noise(noises)
    T.check(#data <= MAX, "fits a datagram")
    local m = assert(P.decode(data))
    T.eq(m.type, P.T.PLAYER_NOISE, "type")
    T.eq(#m.noises, P.MAX_NOISES, "at most MAX_NOISES per message")
    T.near(m.noises[3].pos.x, 3, 1e-6, "position")
    T.near(m.noises[3].radius, 13, 1e-5, "radius")
    T.near(m.noises[3].height, 3, 1e-6, "height")
    T.near(m.noises[3].volume, 0.53, 1e-5, "volume")
    T.near(m.noises[3].sub, 2, 1e-6, "volume lost per second")
    T.eq(#assert(P.decode(P.encode_player_noise({}))).noises, 0, "empty")
end)

T.run("player_damage_roundtrip", function()
    local fields = { { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = 250 },
        { h = P.hash("DamageDir"), t = P.HIT_VALUE.VEC3, v = { x = 1, y = 0, z = 0 } } }
    local m = assert(P.decode(P.encode_player_damage({ seq = 65535, net_id = 300, uid = 0x12345678, kind_hash = 42,
        from_enemy = true, attack_id = 1100, key_hash = 0xDEADBEEF, fields = fields })))
    T.eq(m.type, P.T.PLAYER_DAMAGE, "type")
    T.eq(m.seq, 65535, "sequence")
    T.eq(m.net_id, 300, "the attacking enemy")
    T.eq(m.uid, 0x12345678, "its uid")
    T.eq(m.kind_hash, 42, "its kind")
    T.eq(m.from_enemy, true, "an enemy's attack")
    T.eq(m.attack_id, 1100, "AttackUserData._AttackHitDataID")
    T.eq(m.key_hash, 0xDEADBEEF, "AttackUserData._KeyNameHash")
    T.eq(m.fields[1].v, 250, "the hit's values")
    T.near(m.fields[2].v.x, 1, 1e-6, "vector value")
    T.eq(m.grab, false, "not a grab")
    local bare = assert(P.decode(P.encode_player_damage({})))
    T.eq(bare.uid, nil, "no uid")
    T.eq(bare.from_enemy, false, "not an enemy")
    T.eq(bare.attack_id, -1, "no attack identity")
    T.eq(#bare.fields, 0, "no values")
    -- Protocol 14: a grab, with its GrappleUserData priority.
    local g = assert(P.decode(P.encode_player_damage({ seq = 1, net_id = 2, from_enemy = true, grab = true,
        grab_priority = 3, attack_id = 7, key_hash = 8, fields = fields })))
    T.eq(g.grab, true, "a grab")
    T.eq(g.grab_priority, 3, "its priority")
    T.eq(g.fields[1].v, 250, "and its values")
end)

T.run("action_sign_roundtrip", function()
    local m = assert(P.decode(P.encode_action_sign({ net_id = 65535, uid = 0xCAFEBABE, kind_hash = 77, sign_type = 13,
        button = 1, just = true, act = false, angle_check = true })))
    T.eq(m.type, P.T.ACTION_SIGN, "type")
    T.eq(m.net_id, 65535, "the host's enemy")
    T.eq(m.uid, 0xCAFEBABE, "its uid")
    T.eq(m.kind_hash, 77, "its kind")
    T.eq(m.sign_type, 13, "ActionSignType")
    T.eq(m.button, 1, "ActionSignButton")
    T.eq(m.just, true, "just timing")
    T.eq(m.act, false, "act timing")
    T.eq(m.angle_check, true, "angle check")
    local bare = assert(P.decode(P.encode_action_sign({})))
    T.eq(bare.uid, nil, "no uid")
    T.eq(bare.just, false, "no flags")
    T.eq(P.decode(string.char(P.T.ACTION_SIGN, 1, 2)), nil, "truncated")
end)

T.run("enemy_parry_roundtrip", function()
    local m = assert(P.decode(P.encode_enemy_parry({ net_id = 513, uid = 0x01020304, kind_hash = 9,
        kind = P.PARRY_KIND.INPUT, sign_type = 2 })))
    T.eq(m.type, P.T.ENEMY_PARRY, "type")
    T.eq(m.net_id, 513, "net id")
    T.eq(m.uid, 0x01020304, "uid")
    T.eq(m.kind_hash, 9, "kind")
    T.eq(m.kind, P.PARRY_KIND.INPUT, "the press")
    T.eq(m.sign_type, 2, "the attack's sign")
    T.eq(assert(P.decode(P.encode_enemy_parry({}))).kind, P.PARRY_KIND.PARRY, "a parry by default")
end)

T.run("player_grab_and_escape_roundtrip", function()
    local m = assert(P.decode(P.encode_player_grab({ net_id = 12, uid = 0xABCDEF01, kind_hash = 5, held = true,
        struggles = 300, knife = true, action = 0x9960DD63 })))
    T.eq(m.type, P.T.PLAYER_GRAB, "type")
    T.eq(m.net_id, 12, "net id")
    T.eq(m.uid, 0xABCDEF01, "uid")
    T.eq(m.held, true, "held")
    T.eq(m.struggles, 255, "presses capped at 255")
    T.eq(m.knife, true, "knife allowed")
    T.eq(m.action, 0x9960DD63, "the grab's action")
    local off = assert(P.decode(P.encode_player_grab({ net_id = 12, held = false })))
    T.eq(off.held, false, "let go")
    T.eq(off.uid, nil, "no uid")
    local e = assert(P.decode(P.encode_grab_escape({ net_id = 12, uid = 3, kind_hash = 4, how = P.ESCAPE_KIND.KNIFE })))
    T.eq(e.type, P.T.GRAB_ESCAPE, "type")
    T.eq(e.net_id, 12, "net id")
    T.eq(e.uid, 3, "uid")
    T.eq(e.how, P.ESCAPE_KIND.KNIFE, "with the knife")
    T.eq(assert(P.decode(P.encode_grab_escape({}))).how, P.ESCAPE_KIND.MASH, "mashing by default")
end)

T.run("cutscene_skip_roundtrip", function()
    local m = assert(P.decode(P.encode_cutscene_skip({ camera = 2, id = 1234 })))
    T.eq(m.type, P.T.CUTSCENE_SKIP, "type")
    T.eq(m.camera, 2, "camera")
    T.eq(m.id, 1234, "id")
    T.eq(P.decode(string.char(P.T.CUTSCENE_SKIP, 1)), nil, "truncated")
end)

T.finish()
