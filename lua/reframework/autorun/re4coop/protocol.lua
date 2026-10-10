-- Game-level message codec. Messages ride inside re4coop_net transport packets; see
-- docs/PROTOCOL.md. Pure Lua (string.pack), no game APIs, so it is unit tested offline.

local P = {}

P.VERSION = 1            -- bump on any incompatible change to the layouts below
P.MOD_VERSION = "0.1.0"

P.T = {
    HELLO = 1,          -- reliable, both directions, right after connecting
    PLAYER = 2,         -- unreliable, ~20 Hz, both directions
    SKELETON = 3,       -- reliable, joint parent table for the ghost renderer
    ENEMY_SNAPSHOT = 4, -- unreliable, ~10 Hz, host -> client
    ENEMY_DAMAGE = 5,   -- reliable, client -> host
    ENEMY_DEAD = 6,     -- reliable, host -> client
    CHAT = 7,           -- reliable
    NOTIFY = 8,         -- reliable, short status notices (died, cutscene, teleported...)
}

P.PLAYER_FLAGS = {
    DEAD = 1,
    CUTSCENE = 2,
    AIMING = 4,
}

P.ENEMY_FLAGS = {
    ALIVE = 1,
}

P.DAMAGE_FLAGS = {
    LETHAL = 1,
}

P.MAX_JOINTS = 40
P.ENEMIES_PER_SNAPSHOT = 30 -- 12 B header + 30 * 43 B entries stays under the 1388 B payload limit

local ENEMY_ENTRY = "<I2I4fffffffffB"
local JOINT_SCALE = 100.0 -- joints travel as int16 centimetres relative to the root

local function clamp_i16(v)
    v = math.floor(v + 0.5)
    if v > 32767 then return 32767 end
    if v < -32768 then return -32768 end
    return v
end

-- 32-bit FNV-1a, used to identify enemy kinds and areas compactly.
function P.hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF
    end
    return h
end

P.HELLO_FLAGS = {
    WANT_REPLY = 1, -- sender lost its session state (script reload) and wants our HELLO again
}

function P.encode_hello(m)
    return string.pack("<BI2s1s1s1B", P.T.HELLO, P.VERSION, m.mod_version or P.MOD_VERSION,
        m.name or "", m.area or "", m.flags or 0)
end

-- m = { time, pos={x,y,z}, rot={x,y,z,w}, hp, max_hp, flags, area_hash, joints={{x,y,z},...} }
-- Joint positions are absolute world positions; they are sent relative to pos.
function P.encode_player(m)
    local pos, rot = m.pos, m.rot
    local joints = m.joints or {}
    local n = math.min(#joints, P.MAX_JOINTS)
    local parts = {
        string.pack("<Bdfffffffff BI4B", P.T.PLAYER, m.time or 0,
            pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w,
            m.hp or 0, m.max_hp or 0, m.flags or 0, m.area_hash or 0, n)
    }
    for i = 1, n do
        local j = joints[i]
        parts[#parts + 1] = string.pack("<hhh",
            clamp_i16((j.x - pos.x) * JOINT_SCALE),
            clamp_i16((j.y - pos.y) * JOINT_SCALE),
            clamp_i16((j.z - pos.z) * JOINT_SCALE))
    end
    return table.concat(parts)
end

-- parents[i] = index (1-based) of joint i's parent within the sent joint list, or 0 for none.
function P.encode_skeleton(parents)
    local n = math.min(#parents, P.MAX_JOINTS)
    local parts = { string.pack("<BB", P.T.SKELETON, n) }
    for i = 1, n do
        parts[#parts + 1] = string.pack("<B", parents[i] or 0)
    end
    return table.concat(parts)
end

-- Splits the enemy list into as many messages as needed. Returns an array of strings.
-- entry = { net_id, kind_hash, pos={x,y,z}, spawn={x,y,z}, yaw, hp, max_hp, flags }
-- `spawn` is where the host first saw the enemy. Level spawns are deterministic, so
-- (kind, spawn position) identifies the same enemy on both machines.
function P.encode_enemy_snapshots(time, entries)
    local out = {}
    local per = P.ENEMIES_PER_SNAPSHOT
    local chunks = math.max(1, math.ceil(#entries / per))
    for c = 1, chunks do
        local first = (c - 1) * per + 1
        local last = math.min(#entries, c * per)
        local count = math.max(0, last - first + 1)
        local parts = { string.pack("<BdBBB", P.T.ENEMY_SNAPSHOT, time, c, chunks, count) }
        for i = first, last do
            local e = entries[i]
            local spawn = e.spawn or e.pos
            parts[#parts + 1] = string.pack(ENEMY_ENTRY, e.net_id, e.kind_hash,
                e.pos.x, e.pos.y, e.pos.z, spawn.x, spawn.y, spawn.z,
                e.yaw or 0, e.hp or 0, e.max_hp or 0, e.flags or 0)
        end
        out[#out + 1] = table.concat(parts)
    end
    return out
end

-- m = { net_id (0 if unknown), kind_hash, pos={x,y,z}, amount, flags }
function P.encode_enemy_damage(m)
    return string.pack("<BI2I4ffffB", P.T.ENEMY_DAMAGE, m.net_id or 0, m.kind_hash or 0,
        m.pos.x, m.pos.y, m.pos.z, m.amount or 0, m.flags or 0)
end

function P.encode_enemy_dead(net_id)
    return string.pack("<BI2", P.T.ENEMY_DEAD, net_id)
end

function P.encode_chat(text)
    if #text > 512 then text = text:sub(1, 512) end
    return string.pack("<Bs2", P.T.CHAT, text)
end

function P.encode_notify(code, text)
    return string.pack("<BBs1", P.T.NOTIFY, code or 0, (text or ""):sub(1, 255))
end

local decoders = {}

decoders[P.T.HELLO] = function(data)
    -- Only the version field is guaranteed across protocol versions, so a mismatched peer
    -- still gets a readable "please update" message instead of a decode error.
    local _, version, off = string.unpack("<BI2", data)
    if version ~= P.VERSION then
        return { version = version, mod_version = "?", name = "", area = "", flags = 0 }
    end
    local mod_version, name, area, flags = string.unpack("<s1s1s1B", data, off)
    return { version = version, mod_version = mod_version, name = name, area = area, flags = flags }
end

decoders[P.T.PLAYER] = function(data)
    local _, time, px, py, pz, qx, qy, qz, qw, hp, max_hp, flags, area_hash, n, off =
        string.unpack("<Bdfffffffff BI4B", data)
    local m = {
        time = time,
        pos = { x = px, y = py, z = pz },
        rot = { x = qx, y = qy, z = qz, w = qw },
        hp = hp, max_hp = max_hp, flags = flags, area_hash = area_hash,
        joints = {},
    }
    for i = 1, n do
        local jx, jy, jz
        jx, jy, jz, off = string.unpack("<hhh", data, off)
        m.joints[i] = { x = px + jx / JOINT_SCALE, y = py + jy / JOINT_SCALE, z = pz + jz / JOINT_SCALE }
    end
    return m
end

decoders[P.T.SKELETON] = function(data)
    local _, n, off = string.unpack("<BB", data)
    local parents = {}
    for i = 1, n do
        parents[i], off = string.unpack("<B", data, off)
    end
    return { parents = parents }
end

decoders[P.T.ENEMY_SNAPSHOT] = function(data)
    local _, time, chunk, chunks, count, off = string.unpack("<BdBBB", data)
    local m = { time = time, chunk = chunk, chunks = chunks, enemies = {} }
    for i = 1, count do
        local net_id, kind_hash, x, y, z, sx, sy, sz, yaw, hp, max_hp, flags
        net_id, kind_hash, x, y, z, sx, sy, sz, yaw, hp, max_hp, flags, off = string.unpack(ENEMY_ENTRY, data, off)
        m.enemies[i] = {
            net_id = net_id, kind_hash = kind_hash,
            pos = { x = x, y = y, z = z }, spawn = { x = sx, y = sy, z = sz },
            yaw = yaw, hp = hp, max_hp = max_hp, flags = flags,
        }
    end
    return m
end

decoders[P.T.ENEMY_DAMAGE] = function(data)
    local _, net_id, kind_hash, x, y, z, amount, flags = string.unpack("<BI2I4ffffB", data)
    return { net_id = net_id, kind_hash = kind_hash, pos = { x = x, y = y, z = z }, amount = amount, flags = flags }
end

decoders[P.T.ENEMY_DEAD] = function(data)
    local _, net_id = string.unpack("<BI2", data)
    return { net_id = net_id }
end

decoders[P.T.CHAT] = function(data)
    local _, text = string.unpack("<Bs2", data)
    return { text = text }
end

decoders[P.T.NOTIFY] = function(data)
    local _, code, text = string.unpack("<BBs1", data)
    return { code = code, text = text }
end

-- Returns the decoded message table (with .type set) or nil, error.
-- Malformed input never raises: a buggy or hostile peer must not break the script.
function P.decode(data)
    if type(data) ~= "string" or #data < 1 then
        return nil, "empty message"
    end
    local t = data:byte(1)
    local decoder = decoders[t]
    if decoder == nil then
        return nil, "unknown message type " .. tostring(t)
    end
    local ok, m = pcall(decoder, data)
    if not ok then
        return nil, "malformed message type " .. tostring(t)
    end
    m.type = t
    return m
end

return P
