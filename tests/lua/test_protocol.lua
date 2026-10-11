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

T.run("enemy_snapshot_chunking", function()
    local entries = {}
    for i = 1, 75 do
        entries[i] = { net_id = i, kind_hash = P.hash("k" .. (i % 3)), pos = { x = i, y = 0, z = -i },
            spawn = { x = i + 0.5, y = 0, z = -i }, yaw = 0.5, hp = i * 10, max_hp = 1000, flags = P.ENEMY_FLAGS.ALIVE }
    end
    entries[10].ctx = { category = 2, kind = 1, group = -5, index = 123456 }
    local msgs = P.encode_enemy_snapshots(9.5, entries)
    T.eq(#msgs, 3, "75 enemies -> 3 chunks of 25")
    local seen = 0
    for c, data in ipairs(msgs) do
        T.check(#data <= MAX, ("chunk %d fits in one datagram (%d bytes)"):format(c, #data))
        local m = assert(P.decode(data))
        T.eq(m.chunk, c, "chunk index")
        T.eq(m.chunks, 3, "chunk count")
        for _, e in ipairs(m.enemies) do
            seen = seen + 1
            T.eq(e.net_id, seen, "order preserved")
            T.near(e.spawn.x, seen + 0.5, 1e-5, "spawn")
            T.eq(e.hp, seen * 10, "hp")
            T.eq(e.flags & P.ENEMY_FLAGS.ALIVE, P.ENEMY_FLAGS.ALIVE, "alive flag kept")
            if seen == 10 then
                T.check(e.ctx and e.ctx.group == -5 and e.ctx.index == 123456 and e.ctx.kind == 1 and e.ctx.category == 2,
                    "ContextID round-trips (negative group too)")
                T.eq(P.ctx_key(e.ctx), "2:1:-5:123456", "ctx key")
            else
                T.eq(e.ctx, nil, "no ContextID when none was sent")
            end
        end
    end
    T.eq(seen, 75, "all entries")
    T.eq(#P.encode_enemy_snapshots(1, {}), 1, "empty list still yields one heartbeat snapshot")
end)

T.run("small_messages_roundtrip", function()
    local d = assert(P.decode(P.encode_enemy_damage({ net_id = 7, kind_hash = 99, pos = { x = 1, y = 2, z = 3 },
        amount = 12.5, flags = P.DAMAGE_FLAGS.LETHAL })))
    T.eq(d.net_id, 7, "net id")
    T.eq(d.kind_hash, 99, "kind")
    T.near(d.amount, 12.5, 1e-6, "amount")
    T.eq(d.flags, P.DAMAGE_FLAGS.LETHAL, "lethal")
    T.eq(d.ctx, nil, "no ctx")
    local d2 = assert(P.decode(P.encode_enemy_damage({ net_id = 0, kind_hash = 1, pos = { x = 0, y = 0, z = 0 },
        amount = 3, flags = 0, ctx = { category = 2, kind = 0, group = 77, index = 3 } })))
    T.eq(P.ctx_key(d2.ctx), "2:0:77:3", "damage carries ContextID")
    T.eq(d2.flags & P.DAMAGE_FLAGS.LETHAL, 0, "not lethal")
    local it = assert(P.decode(P.encode_item_taken({ item_id = 119235200, pos = { x = 4, y = 5, z = 6 },
        ctx = { category = 5, kind = 0, group = 9, index = 2 } })))
    T.eq(it.type, P.T.ITEM_TAKEN, "item taken type")
    T.eq(it.item_id, 119235200, "item id")
    T.near(it.pos.z, 6, 1e-6, "position")
    T.eq(P.ctx_key(it.ctx), "5:0:9:2", "item ContextID")
    T.eq(assert(P.decode(P.encode_item_taken({ item_id = 1, pos = { x = 0, y = 0, z = 0 } }))).ctx, nil, "item without ctx")
    T.eq(assert(P.decode(P.encode_enemy_dead(65535))).net_id, 65535, "dead id")
    T.eq(assert(P.decode(P.encode_chat("hola amigo"))).text, "hola amigo", "chat")
    T.eq(#assert(P.decode(P.encode_chat(string.rep("x", 2000)))).text, 512, "chat truncated")
    local n = assert(P.decode(P.encode_notify(3, "teleported")))
    T.eq(n.code, 3, "notify code")
    T.eq(n.text, "teleported", "notify text")
end)

T.run("malformed_input_never_raises", function()
    T.check(P.decode("") == nil, "empty")
    T.check(P.decode(nil) == nil, "nil")
    T.check(P.decode(string.char(250)) == nil, "unknown type")
    T.check(P.decode(string.char(3) .. "\0") == nil, "retired SKELETON type is unknown")
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
        P.encode_enemy_damage({ net_id = 3, kind_hash = 7, pos = { x = 0, y = 0, z = 0 }, amount = 5,
            ctx = { category = 2, kind = 1, group = 4, index = 5 } }),
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
    for t = 1, 14 do
        if t ~= 3 then
            local m = P.decode(string.char(t) .. "\0")
            T.check(m == nil, "short message type " .. t)
        end
    end
    T.check(P.decode(string.pack("<BI2BB", P.T.FRAG, 1, 3, 2)) == nil, "fragment index beyond count")
    T.check(P.decode(string.pack("<BdB", P.T.ACTIONS, 0, 1) .. string.pack("<Bf", 99, 0)) == nil, "unknown event kind")
end)

T.finish()
