-- Game-level message codec. Messages ride inside re4coop_net transport packets; see
-- docs/PROTOCOL.md. Pure Lua (string.pack), no game APIs, so it is unit tested offline.

local P = {}

P.VERSION = 3            -- bump on any incompatible change to the layouts below
P.MOD_VERSION = "0.3.0"

P.T = {
    HELLO = 1,          -- reliable, both directions, right after connecting
    PLAYER = 2,         -- unreliable, ~20 Hz, both directions
    SKELETON = 3,       -- reliable, joint parent table for the ghost renderer
    ENEMY_SNAPSHOT = 4, -- unreliable, ~10 Hz, host -> client
    ENEMY_DAMAGE = 5,   -- reliable, client -> host
    ENEMY_DEAD = 6,     -- reliable, host -> client
    CHAT = 7,           -- reliable
    NOTIFY = 8,         -- reliable, short status notices (died, cutscene, teleported...)
    ITEM_TAKEN = 9,     -- reliable, both directions: a shared pickup (key item) was taken
}

P.PLAYER_FLAGS = {
    DEAD = 1,
    CUTSCENE = 2,
    AIMING = 4,
    HAS_STAGE = 8, -- the message carries the player's chainsaw.StageID
}

P.ENEMY_FLAGS = {
    ALIVE = 1,
    HAS_CTX = 2, -- entry carries the enemy's chainsaw.ContextID
}

P.DAMAGE_FLAGS = {
    LETHAL = 1,
    HAS_CTX = 2,
}

P.ITEM_FLAGS = {
    HAS_CTX = 1,
}

P.MAX_JOINTS = 40
P.ENEMIES_PER_SNAPSHOT = 25 -- 12 B header + 25 * 53 B entries stays under the 1388 B payload limit

-- net id, kind hash, position, spawn position, yaw, hp, max hp, flags, ContextID (group, index, kind, category)
local ENEMY_ENTRY = "<I2I4fffffffffBi4i4BB"
local JOINT_SCALE = 100.0 -- joints travel as int16 centimetres relative to the root

local function clamp_i16(v)
    v = math.floor(v + 0.5)
    if v > 32767 then return 32767 end
    if v < -32768 then return -32768 end
    return v
end

-- chainsaw.ContextID {category, kind, group, index} identifies a character, spawner or item.
-- IDs from level data are the same on both machines; runtime ones are not (ctx_is_runtime).
local function ctx_fields(ctx)
    if ctx == nil then return 0, 0, 0, 0 end
    return ctx.group or 0, ctx.index or 0, (ctx.kind or 0) & 0xFF, (ctx.category or 0) & 0xFF
end

local function ctx_from(group, index, kind, category)
    return { group = group, index = index, kind = kind, category = category }
end

-- ContextIDs in this group are handed out at runtime, in load order: the research dump showed
-- enemies 12:312, 12:987, 12:1053 and drop items 12:192..486, while level-placed items carry
-- their stage (3:0:40210:13). Two machines can give the same runtime number to different
-- objects, or agree for a while and then drift apart, so these never identify anything
-- across the network.
P.RUNTIME_CONTEXT_GROUP = 12

function P.ctx_is_runtime(ctx)
    return ctx ~= nil and ctx.group == P.RUNTIME_CONTEXT_GROUP
end

-- Stable string key for a ContextID table, or nil.
function P.ctx_key(ctx)
    if ctx == nil then return nil end
    return string.format("%d:%d:%d:%d", ctx.category or 0, ctx.kind or 0, ctx.group or 0, ctx.index or 0)
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

-- m = { time, pos={x,y,z}, rot={x,y,z,w}, hp, max_hp, flags, area_hash, stage, joints={{x,y,z},...} }
-- Joint positions are absolute world positions; they are sent relative to pos.
-- stage: the player's chainsaw.StageID (nil if unknown).
local PLAYER_HEADER = "<Bdfffffffff BI4i4B"
function P.encode_player(m)
    local pos, rot = m.pos, m.rot
    local joints = m.joints or {}
    local n = math.min(#joints, P.MAX_JOINTS)
    local flags = (m.flags or 0) & ~P.PLAYER_FLAGS.HAS_STAGE
    local stage = math.tointeger(m.stage)
    if stage ~= nil and stage >= -0x80000000 and stage <= 0x7FFFFFFF then
        flags = flags | P.PLAYER_FLAGS.HAS_STAGE
    else
        stage = 0
    end
    local parts = {
        string.pack(PLAYER_HEADER, P.T.PLAYER, m.time or 0,
            pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w,
            m.hp or 0, m.max_hp or 0, flags, m.area_hash or 0, stage, n)
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
-- entry = { net_id, kind_hash, pos={x,y,z}, spawn={x,y,z}, yaw, hp, max_hp, flags, ctx }
-- `ctx` is the enemy's chainsaw.ContextID (nil if unreadable). `spawn` is where the host
-- first saw the enemy; (kind, spawn position) is the fallback identity when IDs differ.
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
            local flags = (e.flags or 0) & ~P.ENEMY_FLAGS.HAS_CTX
            if e.ctx ~= nil then flags = flags | P.ENEMY_FLAGS.HAS_CTX end
            local g, idx, k, c = ctx_fields(e.ctx)
            parts[#parts + 1] = string.pack(ENEMY_ENTRY, e.net_id, e.kind_hash,
                e.pos.x, e.pos.y, e.pos.z, spawn.x, spawn.y, spawn.z,
                e.yaw or 0, e.hp or 0, e.max_hp or 0, flags, g, idx, k, c)
        end
        out[#out + 1] = table.concat(parts)
    end
    return out
end

-- m = { net_id (0 if unknown), kind_hash, pos={x,y,z}, amount, flags, ctx }
function P.encode_enemy_damage(m)
    local flags = (m.flags or 0) & ~P.DAMAGE_FLAGS.HAS_CTX
    if m.ctx ~= nil then flags = flags | P.DAMAGE_FLAGS.HAS_CTX end
    local g, idx, k, c = ctx_fields(m.ctx)
    return string.pack("<BI2I4ffffBi4i4BB", P.T.ENEMY_DAMAGE, m.net_id or 0, m.kind_hash or 0,
        m.pos.x, m.pos.y, m.pos.z, m.amount or 0, flags, g, idx, k, c)
end

-- m = { item_id, pos={x,y,z}, ctx }  (ctx = the pickup's chainsaw.ContextID, may be nil)
function P.encode_item_taken(m)
    local flags = m.ctx ~= nil and P.ITEM_FLAGS.HAS_CTX or 0
    local g, idx, k, c = ctx_fields(m.ctx)
    return string.pack("<BI4fffBi4i4BB", P.T.ITEM_TAKEN, m.item_id or 0,
        m.pos.x, m.pos.y, m.pos.z, flags, g, idx, k, c)
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
    local _, time, px, py, pz, qx, qy, qz, qw, hp, max_hp, flags, area_hash, stage, n, off =
        string.unpack(PLAYER_HEADER, data)
    local m = {
        time = time,
        pos = { x = px, y = py, z = pz },
        rot = { x = qx, y = qy, z = qz, w = qw },
        hp = hp, max_hp = max_hp, flags = flags, area_hash = area_hash,
        stage = (flags & P.PLAYER_FLAGS.HAS_STAGE) ~= 0 and stage or nil,
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
        local net_id, kind_hash, x, y, z, sx, sy, sz, yaw, hp, max_hp, flags, g, idx, k, c
        net_id, kind_hash, x, y, z, sx, sy, sz, yaw, hp, max_hp, flags, g, idx, k, c, off =
            string.unpack(ENEMY_ENTRY, data, off)
        m.enemies[i] = {
            net_id = net_id, kind_hash = kind_hash,
            pos = { x = x, y = y, z = z }, spawn = { x = sx, y = sy, z = sz },
            yaw = yaw, hp = hp, max_hp = max_hp, flags = flags,
            ctx = (flags & P.ENEMY_FLAGS.HAS_CTX) ~= 0 and ctx_from(g, idx, k, c) or nil,
        }
    end
    return m
end

decoders[P.T.ENEMY_DAMAGE] = function(data)
    local _, net_id, kind_hash, x, y, z, amount, flags, g, idx, k, c = string.unpack("<BI2I4ffffBi4i4BB", data)
    return {
        net_id = net_id, kind_hash = kind_hash, pos = { x = x, y = y, z = z }, amount = amount, flags = flags,
        ctx = (flags & P.DAMAGE_FLAGS.HAS_CTX) ~= 0 and ctx_from(g, idx, k, c) or nil,
    }
end

decoders[P.T.ITEM_TAKEN] = function(data)
    local _, item_id, x, y, z, flags, g, idx, k, c = string.unpack("<BI4fffBi4i4BB", data)
    return {
        item_id = item_id, pos = { x = x, y = y, z = z },
        ctx = (flags & P.ITEM_FLAGS.HAS_CTX) ~= 0 and ctx_from(g, idx, k, c) or nil,
    }
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
