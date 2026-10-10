local T = require("testlib")
local P = require("re4coop.protocol")

T.run("fnv1a_hash", function()
    T.eq(P.hash(""), 0x811C9DC5, "empty")
    T.eq(P.hash("a"), 0xE40C292C, "a")
    T.eq(P.hash("foobar"), 0xBF9CF968, "foobar")
    T.check(P.hash("chainsaw.Ch1c0z0Context") ~= P.hash("chainsaw.Ch1c1z0Context"), "distinct kinds")
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
end)

T.run("player_roundtrip_with_joints", function()
    local joints = {}
    for i = 1, 25 do
        joints[i] = { x = 10 + i * 0.01, y = 1 + i * 0.07, z = -5 - i * 0.03 }
    end
    local data = P.encode_player({
        time = 123.456, pos = { x = 10, y = 1, z = -5 }, rot = { x = 0, y = 0.7071, z = 0, w = 0.7071 },
        hp = 875, max_hp = 1000, flags = P.PLAYER_FLAGS.AIMING, area_hash = 42, joints = joints,
    })
    T.check(#data < 400, "player message stays small (" .. #data .. " bytes)")
    local m = assert(P.decode(data))
    T.eq(m.type, P.T.PLAYER, "type")
    T.near(m.time, 123.456, 1e-9, "time")
    T.near(m.pos.x, 10, 1e-5, "pos.x")
    T.near(m.rot.y, 0.7071, 1e-4, "rot.y")
    T.eq(m.hp, 875, "hp")
    T.eq(m.max_hp, 1000, "max_hp")
    T.eq(m.flags, P.PLAYER_FLAGS.AIMING, "flags")
    T.eq(m.area_hash, 42, "area hash")
    T.eq(#m.joints, 25, "joint count")
    for i = 1, 25 do
        T.near(m.joints[i].x, joints[i].x, 0.006, "joint x")
        T.near(m.joints[i].y, joints[i].y, 0.006, "joint y")
        T.near(m.joints[i].z, joints[i].z, 0.006, "joint z")
    end
end)

T.run("player_joint_cap_and_clamp", function()
    local joints = {}
    for i = 1, 60 do joints[i] = { x = 1000, y = 0, z = 0 } end -- 1 km away: clamps, no error
    local m = assert(P.decode(P.encode_player({ time = 0, pos = { x = 0, y = 0, z = 0 },
        rot = { x = 0, y = 0, z = 0, w = 1 }, joints = joints })))
    T.eq(#m.joints, P.MAX_JOINTS, "capped")
    T.near(m.joints[1].x, 327.67, 0.01, "clamped to int16 range")
end)

T.run("skeleton_roundtrip", function()
    local m = assert(P.decode(P.encode_skeleton({ 0, 1, 2, 2, 4 })))
    T.eq(m.type, P.T.SKELETON, "type")
    T.eq(table.concat(m.parents, ","), "0,1,2,2,4", "parents")
end)

T.run("enemy_snapshot_chunking", function()
    local entries = {}
    for i = 1, 75 do
        entries[i] = { net_id = i, kind_hash = P.hash("k" .. (i % 3)), pos = { x = i, y = 0, z = -i },
            spawn = { x = i + 0.5, y = 0, z = -i }, yaw = 0.5, hp = i * 10, max_hp = 1000, flags = P.ENEMY_FLAGS.ALIVE }
    end
    local msgs = P.encode_enemy_snapshots(9.5, entries)
    T.eq(#msgs, 3, "75 enemies -> 3 chunks of 30")
    local seen = 0
    for c, data in ipairs(msgs) do
        T.check(#data <= re4coop_net.max_payload(), ("chunk %d fits in one datagram (%d bytes)"):format(c, #data))
        local m = assert(P.decode(data))
        T.eq(m.chunk, c, "chunk index")
        T.eq(m.chunks, 3, "chunk count")
        for _, e in ipairs(m.enemies) do
            seen = seen + 1
            T.eq(e.net_id, seen, "order preserved")
            T.near(e.spawn.x, seen + 0.5, 1e-5, "spawn")
            T.eq(e.hp, seen * 10, "hp")
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
    local good = P.encode_player({ time = 1, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 },
        joints = { { x = 0, y = 1, z = 0 } } })
    for cut = 1, #good - 1 do
        local m, err = P.decode(good:sub(1, cut))
        T.check(m == nil and err ~= nil, "truncated player message at " .. cut)
    end
    for t = 1, 8 do
        if t ~= P.T.SKELETON then -- "\3\0" is a valid, empty skeleton
            T.check(P.decode(string.char(t) .. "\0") == nil, "short message type " .. t)
        end
    end
    T.check(P.decode(string.char(P.T.SKELETON, 5, 0, 1)) == nil, "skeleton shorter than its count")
end)

T.finish()
