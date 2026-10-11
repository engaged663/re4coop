-- Game-level message codec. Messages ride inside re4coop_net transport packets; see
-- docs/PROTOCOL.md. Pure Lua (string.pack), no game APIs, so it is unit tested offline.

local P = {}

P.VERSION = 4            -- bump on any incompatible change to the layouts below
P.MOD_VERSION = "0.4.0"
P.MAX_PAYLOAD = 1388     -- re4coop_net.max_payload(): biggest message one datagram carries

P.T = {
    HELLO = 1,          -- reliable, both directions, right after connecting
    PLAYER = 2,         -- unreliable, ~20 Hz, both directions: position, HP, flags
    -- 3 was SKELETON (protocols 1-3, the stick-figure ghost)
    ENEMY_SNAPSHOT = 4, -- unreliable, ~10 Hz, host -> client
    ENEMY_DAMAGE = 5,   -- reliable, client -> host
    ENEMY_DEAD = 6,     -- reliable, host -> client
    CHAT = 7,           -- reliable
    NOTIFY = 8,         -- reliable, short status notices (died, cutscene, teleported...)
    ITEM_TAKEN = 9,     -- reliable, both directions: a shared pickup (key item) was taken
    FRAG = 10,          -- reliable, one piece of a reliable message bigger than a datagram
    AVATAR = 11,        -- reliable (fragmented), how the sender's character is built
    GEAR = 12,          -- reliable, the weapons the sender's character carries
    POSE = 13,          -- unreliable, ~30 Hz, the full skeleton pose + weapon placement
    ACTIONS = 14,       -- reliable, sounds/effects/shots to replay on the partner's model
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

-- AVATAR part flags.
P.PART_FLAGS = {
    SAME_JOINTS = 1, -- the part's joints follow its parent's joints of the same name
    MAIN = 2,        -- the part carrying the main skeleton (used as the root when rebuilding)
}

-- AVATAR joint flags.
P.JOINT_FLAGS = {
    TRANSLATE = 1, -- the joint's local position is animated too (root, hips) and travels in POSE
}

-- POSE flags (character) and weapon flags.
P.POSE_FLAGS = {
    CUTSCENE = 1,
    DEAD = 2,
}
P.WEAPON_FLAGS = {
    VISIBLE = 1,
}

-- Part references used by ACTIONS: which of the sender's objects a call happened on.
P.REF = {
    BODY = 0,         -- the body GameObject (skeleton root)
    -- 1..199: AVATAR part index
    HEAD = 200,       -- the context's head GameObject (logic root), replayed on the body
    WEAPON_BASE = 200, -- weapon slot s is WEAPON_BASE + s (201..)
}

P.EVENT = {
    CALL = 1, -- a sound/effect method called on one of the sender's components
    SHOT = 2, -- a weapon fired
}

-- ACTIONS argument tags.
P.ARG = {
    U32 = 1, I32 = 2, BOOL = 3, F32 = 4, OBJ = 5, NULL = 6, I64 = 7,
}

P.MAX_PARTS = 64
P.MAX_POSE_JOINTS = 512
P.MAX_WEAPONS = 4
P.MAX_WEAPON_JOINTS = 32
P.MAX_TRANSLATIONS = 32
P.MAX_EVENT_ARGS = 16
P.ENEMIES_PER_SNAPSHOT = 25 -- 12 B header + 25 * 53 B entries stays under the 1388 B payload limit

-- net id, kind hash, position, spawn position, yaw, hp, max hp, flags, ContextID (group, index, kind, category)
local ENEMY_ENTRY = "<I2I4fffffffffBi4i4BB"

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

-- 32-bit FNV-1a, used to identify enemy kinds, areas, joint names and types compactly.
function P.hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF
    end
    return h
end

-------------------------------------------------------------------------------
-- Quaternions: "smallest three" in 32 bits (2-bit index of the dropped largest
-- component + three 10-bit components). Worst-case error is about 0.25 degree.
-------------------------------------------------------------------------------

local INV_SQRT2 = 0.70710678118654752
local QSCALE = 511 -- components map to 0..1022 with 511 = exactly zero

local function q10(v)
    local n = math.floor(v / INV_SQRT2 * QSCALE + QSCALE + 0.5)
    if n < 0 then return 0 end
    if n > 1022 then return 1022 end
    return n
end

local function uq10(n)
    return (n - QSCALE) / QSCALE * INV_SQRT2
end

function P.pack_quat(x, y, z, w)
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-9 or len ~= len then
        x, y, z, w, len = 0, 0, 0, 1, 1
    end
    local ax, ay, az, aw = math.abs(x), math.abs(y), math.abs(z), math.abs(w)
    local largest, a, b, c, big
    if ax >= ay and ax >= az and ax >= aw then
        largest, big, a, b, c = 0, x, y, z, w
    elseif ay >= az and ay >= aw then
        largest, big, a, b, c = 1, y, x, z, w
    elseif az >= aw then
        largest, big, a, b, c = 2, z, x, y, w
    else
        largest, big, a, b, c = 3, w, x, y, z
    end
    local s = (big < 0 and -1 or 1) / len -- q and -q are the same rotation
    return (largest << 30) | (q10(a * s) << 20) | (q10(b * s) << 10) | q10(c * s)
end

-- Returns x, y, z, w.
function P.unpack_quat(packed)
    local largest = (packed >> 30) & 3
    local a = uq10((packed >> 20) & 1023)
    local b = uq10((packed >> 10) & 1023)
    local c = uq10(packed & 1023)
    local d = 1.0 - a * a - b * b - c * c
    d = d > 0 and math.sqrt(d) or 0.0
    if largest == 0 then return d, a, b, c end
    if largest == 1 then return a, d, b, c end
    if largest == 2 then return a, b, d, c end
    return a, b, c, d
end

local function pack_rot(r)
    if r == nil then return P.pack_quat(0, 0, 0, 1) end
    return P.pack_quat(r.x, r.y, r.z, r.w)
end

local function unpack_rot(packed)
    local x, y, z, w = P.unpack_quat(packed)
    return { x = x, y = y, z = z, w = w }
end

local function mm(v)
    return clamp_i16((v or 0) * 1000.0)
end

-------------------------------------------------------------------------------
-- Encoders
-------------------------------------------------------------------------------

P.HELLO_FLAGS = {
    WANT_REPLY = 1, -- sender lost its session state (script reload) and wants our HELLO again
}

function P.encode_hello(m)
    return string.pack("<BI2s1s1s1B", P.T.HELLO, P.VERSION, m.mod_version or P.MOD_VERSION,
        m.name or "", m.area or "", m.flags or 0)
end

-- m = { time, pos={x,y,z}, rot={x,y,z,w}, hp, max_hp, flags, area_hash, stage }
-- stage: the player's chainsaw.StageID (nil if unknown).
local PLAYER_FORMAT = "<BdfffffffffBI4i4"
function P.encode_player(m)
    local pos, rot = m.pos, m.rot
    local flags = (m.flags or 0) & ~P.PLAYER_FLAGS.HAS_STAGE
    local stage = math.tointeger(m.stage)
    if stage ~= nil and stage >= -0x80000000 and stage <= 0x7FFFFFFF then
        flags = flags | P.PLAYER_FLAGS.HAS_STAGE
    else
        stage = 0
    end
    return string.pack(PLAYER_FORMAT, P.T.PLAYER, m.time or 0,
        pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w,
        m.hp or 0, m.max_hp or 0, flags, m.area_hash or 0, stage)
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

-- Splits an encoded reliable message that does not fit in one datagram into FRAG
-- messages. The reliable channel is ordered, so the receiver just concatenates them.
local FRAG_HEADER = 5
function P.fragment(data, msg_id, max_payload)
    local room = (max_payload or P.MAX_PAYLOAD) - FRAG_HEADER
    local count = math.max(1, math.ceil(#data / room))
    if count > 255 then
        return nil, "message too large to fragment"
    end
    local out = {}
    for i = 1, count do
        out[i] = string.pack("<BI2BB", P.T.FRAG, msg_id & 0xFFFF, i, count) .. data:sub((i - 1) * room + 1, i * room)
    end
    return out
end

-- m = { rev, char_id, body_name,
--       parts = { {name, mesh, mdf, parent (0 = body, k = part k), flags, parent_joint,
--                  lpos={x,y,z}, lrot={x,y,z,w}} ... },
--       joints = { {hash, flags} ... } }   -- POSE carries rotations in this order
function P.encode_avatar(m)
    local parts = m.parts or {}
    local joints = m.joints or {}
    local np = math.min(#parts, P.MAX_PARTS)
    local nj = math.min(#joints, P.MAX_POSE_JOINTS)
    local out = { string.pack("<BI2s1s1B", P.T.AVATAR, (m.rev or 0) & 0xFFFF,
        (m.char_id or ""):sub(1, 255), (m.body_name or ""):sub(1, 255), np) }
    for i = 1, np do
        local p = parts[i]
        local lp = p.lpos or { x = 0, y = 0, z = 0 }
        out[#out + 1] = string.pack("<s1s2s2BBs1fffI4", (p.name or ""):sub(1, 255), p.mesh or "", p.mdf or "",
            p.parent or 0, p.flags or 0, (p.parent_joint or ""):sub(1, 255), lp.x, lp.y, lp.z, pack_rot(p.lrot))
    end
    out[#out + 1] = string.pack("<I2", nj)
    for i = 1, nj do
        out[#out + 1] = string.pack("<I4B", joints[i].hash, joints[i].flags or 0)
    end
    return table.concat(out)
end

-- m = { rev, weapons = { {name, mesh, mdf, flags, joints = {hash, ...}} ... } }
function P.encode_gear(m)
    local weapons = m.weapons or {}
    local n = math.min(#weapons, P.MAX_WEAPONS)
    local out = { string.pack("<BI2B", P.T.GEAR, (m.rev or 0) & 0xFFFF, n) }
    for i = 1, n do
        local w = weapons[i]
        local joints = w.joints or {}
        local nj = math.min(#joints, P.MAX_WEAPON_JOINTS)
        out[#out + 1] = string.pack("<s1s2s2BB", (w.name or ""):sub(1, 255), w.mesh or "", w.mdf or "", w.flags or 0, nj)
        for j = 1, nj do
            out[#out + 1] = string.pack("<I4", joints[j])
        end
    end
    return table.concat(out)
end

local POSE_HEADER = "<BdI2I2BBI2I2"
local POSE_HEADER_SIZE = 19

-- The part of POSE chunk 1 that is not joint rotations: root placement, weapons, translations.
local function encode_pose_root(m)
    local rp = m.root_pos
    local out = { string.pack("<fffI4B", rp.x, rp.y, rp.z, pack_rot(m.root_rot), m.flags or 0) }
    local weapons = m.weapons or {}
    local nw = math.min(#weapons, P.MAX_WEAPONS)
    out[#out + 1] = string.pack("<B", nw)
    for i = 1, nw do
        local w = weapons[i]
        local q = w.q or {}
        local nj = math.min(#q // 4, P.MAX_WEAPON_JOINTS)
        out[#out + 1] = string.pack("<BBI2fffI4B", w.slot or i, w.flags or 0, w.attach or 0,
            w.pos.x, w.pos.y, w.pos.z, pack_rot(w.rot), nj)
        for j = 1, nj do
            local k = j * 4
            out[#out + 1] = string.pack("<I4", P.pack_quat(q[k - 3], q[k - 2], q[k - 1], q[k]))
        end
    end
    local tpos = m.tpos or {}
    local nt = math.min(#tpos, P.MAX_TRANSLATIONS)
    out[#out + 1] = string.pack("<B", nt)
    for i = 1, nt do
        local t = tpos[i]
        out[#out + 1] = string.pack("<I2hhh", t.index, mm(t.x), mm(t.y), mm(t.z))
    end
    return table.concat(out)
end

-- The sender's pose, split into as many unreliable datagrams as it needs (usually one).
-- m = { time, avatar_rev, gear_rev, flags, root_pos={x,y,z}, root_rot={x,y,z,w},
--       q = { x1, y1, z1, w1, x2, ... }        -- local joint rotations, AVATAR joint order
--       tpos = { {index, x, y, z} ... }         -- local positions (m) of TRANSLATE joints
--       weapons = { {slot, flags, attach, pos, rot, q = {flat}} ... } }
-- A weapon's pos/rot are local to AVATAR joint `attach` (1-based) when it is set, which
-- keeps the gun glued to the hand; otherwise they are relative to the root.
-- Each chunk is self-contained (own time), so a lost chunk only freezes its joints.
function P.encode_pose(m, max_payload)
    local max = max_payload or P.MAX_PAYLOAD
    local root = encode_pose_root(m)
    local q = m.q or {}
    local n = math.min(#q // 4, P.MAX_POSE_JOINTS)
    local per_first = math.max(0, (max - POSE_HEADER_SIZE - #root) // 4)
    local per_next = (max - POSE_HEADER_SIZE) // 4
    local chunks = 1
    if n > per_first then
        chunks = 1 + math.ceil((n - per_first) / per_next)
    end
    local out = {}
    local first = 1
    for c = 1, chunks do
        local room = c == 1 and per_first or per_next
        local count = math.max(0, math.min(n - first + 1, room))
        local parts = { string.pack(POSE_HEADER, P.T.POSE, m.time or 0, (m.avatar_rev or 0) & 0xFFFF,
            (m.gear_rev or 0) & 0xFFFF, c, chunks, first, count) }
        if c == 1 then parts[2] = root end
        for i = first, first + count - 1 do
            local k = i * 4
            parts[#parts + 1] = string.pack("<I4", P.pack_quat(q[k - 3], q[k - 2], q[k - 1], q[k]))
        end
        out[#out + 1] = table.concat(parts)
        first = first + count
    end
    return out
end

local function int_or_zero(v)
    return math.tointeger(v) or 0
end

local function encode_event(ev)
    if ev.kind == P.EVENT.SHOT then
        return string.pack("<BfB", P.EVENT.SHOT, ev.dt or 0, ev.slot or 0)
    end
    local args = ev.args or {}
    local na = math.min(#args, P.MAX_EVENT_ARGS)
    local out = { string.pack("<BfBI4BI4B", P.EVENT.CALL, ev.dt or 0, ev.part or 0, ev.comp_type or 0,
        ev.comp_idx or 0, ev.method or 0, na) }
    for i = 1, na do
        local a = args[i]
        local tag, v = a.tag, a.value
        if tag == P.ARG.U32 then
            out[#out + 1] = string.pack("<BI4", tag, int_or_zero(v) & 0xFFFFFFFF)
        elseif tag == P.ARG.I32 then
            out[#out + 1] = string.pack("<Bi4", tag, math.max(-0x80000000, math.min(0x7FFFFFFF, int_or_zero(v))))
        elseif tag == P.ARG.BOOL then
            out[#out + 1] = string.pack("<BB", tag, v and 1 or 0)
        elseif tag == P.ARG.F32 then
            out[#out + 1] = string.pack("<Bf", tag, v)
        elseif tag == P.ARG.OBJ then
            out[#out + 1] = string.pack("<BB", tag, int_or_zero(v) & 0xFF)
        elseif tag == P.ARG.I64 then
            out[#out + 1] = string.pack("<Bj", tag, int_or_zero(v))
        else
            out[#out + 1] = string.pack("<B", P.ARG.NULL)
        end
    end
    return table.concat(out)
end

-- m = { time, events = { {kind=CALL, dt, part, comp_type, comp_idx, method, args={{tag, value}...}}
--                        | {kind=SHOT, dt, slot} ... } }
-- `dt` is each event's offset from `time`. Returns an array of strings.
function P.encode_actions(m, max_payload)
    local max = max_payload or P.MAX_PAYLOAD
    local out = {}
    local current, count, size = {}, 0, 10
    local function flush()
        if count > 0 then
            out[#out + 1] = string.pack("<BdB", P.T.ACTIONS, m.time or 0, count) .. table.concat(current)
        end
        current, count, size = {}, 0, 10
    end
    for _, ev in ipairs(m.events or {}) do
        local bytes = encode_event(ev)
        if size + #bytes > max or count == 255 then flush() end
        current[#current + 1] = bytes
        count = count + 1
        size = size + #bytes
    end
    flush()
    return out
end

-------------------------------------------------------------------------------
-- Decoders
-------------------------------------------------------------------------------

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
    local _, time, px, py, pz, qx, qy, qz, qw, hp, max_hp, flags, area_hash, stage =
        string.unpack(PLAYER_FORMAT, data)
    return {
        time = time,
        pos = { x = px, y = py, z = pz },
        rot = { x = qx, y = qy, z = qz, w = qw },
        hp = hp, max_hp = max_hp, flags = flags, area_hash = area_hash,
        stage = (flags & P.PLAYER_FLAGS.HAS_STAGE) ~= 0 and stage or nil,
    }
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

decoders[P.T.FRAG] = function(data)
    local _, msg_id, index, count, off = string.unpack("<BI2BB", data)
    if index < 1 or index > count then error("bad fragment index") end
    return { msg_id = msg_id, index = index, count = count, data = data:sub(off) }
end

decoders[P.T.AVATAR] = function(data)
    local _, rev, char_id, body_name, np, off = string.unpack("<BI2s1s1B", data)
    local m = { rev = rev, char_id = char_id, body_name = body_name, parts = {}, joints = {} }
    for i = 1, np do
        local name, mesh, mdf, parent, flags, parent_joint, lx, ly, lz, lrot
        name, mesh, mdf, parent, flags, parent_joint, lx, ly, lz, lrot, off =
            string.unpack("<s1s2s2BBs1fffI4", data, off)
        m.parts[i] = {
            name = name, mesh = mesh, mdf = mdf, parent = parent, flags = flags, parent_joint = parent_joint,
            lpos = { x = lx, y = ly, z = lz }, lrot = unpack_rot(lrot),
        }
    end
    local nj
    nj, off = string.unpack("<I2", data, off)
    for i = 1, nj do
        local hash, flags
        hash, flags, off = string.unpack("<I4B", data, off)
        m.joints[i] = { hash = hash, flags = flags }
    end
    return m
end

decoders[P.T.GEAR] = function(data)
    local _, rev, n, off = string.unpack("<BI2B", data)
    local m = { rev = rev, weapons = {} }
    for i = 1, n do
        local name, mesh, mdf, flags, nj
        name, mesh, mdf, flags, nj, off = string.unpack("<s1s2s2BB", data, off)
        local joints = {}
        for j = 1, nj do
            joints[j], off = string.unpack("<I4", data, off)
        end
        m.weapons[i] = { name = name, mesh = mesh, mdf = mdf, flags = flags, joints = joints }
    end
    return m
end

local function read_quats(data, off, n, out)
    for i = 1, n do
        local packed
        packed, off = string.unpack("<I4", data, off)
        local x, y, z, w = P.unpack_quat(packed)
        local k = i * 4
        out[k - 3], out[k - 2], out[k - 1], out[k] = x, y, z, w
    end
    return off
end

decoders[P.T.POSE] = function(data)
    local _, time, avatar_rev, gear_rev, chunk, chunks, first, count, off = string.unpack(POSE_HEADER, data)
    if chunk < 1 or chunk > chunks or first < 1 then error("bad pose chunk") end
    local m = { time = time, avatar_rev = avatar_rev, gear_rev = gear_rev, chunk = chunk, chunks = chunks,
        first = first, count = count, q = {} }
    if chunk == 1 then
        local x, y, z, rot, flags, nw
        x, y, z, rot, flags, nw, off = string.unpack("<fffI4BB", data, off)
        m.root_pos = { x = x, y = y, z = z }
        m.root_rot = unpack_rot(rot)
        m.flags = flags
        m.weapons = {}
        for i = 1, nw do
            local slot, wflags, attach, wx, wy, wz, wrot, nj
            slot, wflags, attach, wx, wy, wz, wrot, nj, off = string.unpack("<BBI2fffI4B", data, off)
            local w = { slot = slot, flags = wflags, attach = attach, pos = { x = wx, y = wy, z = wz },
                rot = unpack_rot(wrot), q = {} }
            off = read_quats(data, off, nj, w.q)
            m.weapons[i] = w
        end
        local nt
        nt, off = string.unpack("<B", data, off)
        m.tpos = {}
        for i = 1, nt do
            local index, tx, ty, tz
            index, tx, ty, tz, off = string.unpack("<I2hhh", data, off)
            m.tpos[i] = { index = index, x = tx / 1000.0, y = ty / 1000.0, z = tz / 1000.0 }
        end
    end
    read_quats(data, off, count, m.q)
    return m
end

decoders[P.T.ACTIONS] = function(data)
    local _, time, count, off = string.unpack("<BdB", data)
    local m = { time = time, events = {} }
    for i = 1, count do
        local kind, dt
        kind, dt, off = string.unpack("<Bf", data, off)
        if kind == P.EVENT.SHOT then
            local slot
            slot, off = string.unpack("<B", data, off)
            m.events[i] = { kind = kind, dt = dt, slot = slot }
        elseif kind == P.EVENT.CALL then
            local part, comp_type, comp_idx, method, na
            part, comp_type, comp_idx, method, na, off = string.unpack("<BI4BI4B", data, off)
            local args = {}
            for a = 1, na do
                local tag, v
                tag, off = string.unpack("<B", data, off)
                if tag == P.ARG.U32 then
                    v, off = string.unpack("<I4", data, off)
                elseif tag == P.ARG.I32 then
                    v, off = string.unpack("<i4", data, off)
                elseif tag == P.ARG.BOOL then
                    v, off = string.unpack("<B", data, off)
                    v = v ~= 0
                elseif tag == P.ARG.F32 then
                    v, off = string.unpack("<f", data, off)
                elseif tag == P.ARG.OBJ then
                    v, off = string.unpack("<B", data, off)
                elseif tag == P.ARG.I64 then
                    v, off = string.unpack("<j", data, off)
                elseif tag ~= P.ARG.NULL then
                    error("bad argument tag")
                end
                args[a] = { tag = tag, value = v }
            end
            m.events[i] = { kind = kind, dt = dt, part = part, comp_type = comp_type, comp_idx = comp_idx,
                method = method, args = args }
        else
            error("unknown event kind")
        end
    end
    return m
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

-------------------------------------------------------------------------------
-- Reassembly of FRAG messages (the reliable channel delivers them in order)
-------------------------------------------------------------------------------

local Reassembler = {}
Reassembler.__index = Reassembler

function P.new_reassembler()
    return setmetatable({ id = nil, count = 0, pieces = {} }, Reassembler)
end

-- Takes a decoded FRAG message. Returns the complete original bytes once the last piece
-- arrives, nil otherwise. A piece out of sequence discards the partial message.
function Reassembler:push(m)
    if m.index == 1 then
        self.id, self.count, self.pieces = m.msg_id, m.count, {}
    elseif self.id ~= m.msg_id or m.count ~= self.count or m.index ~= #self.pieces + 1 then
        self.id, self.count, self.pieces = nil, 0, {}
        return nil
    end
    self.pieces[#self.pieces + 1] = m.data
    if m.index == m.count then
        local data = table.concat(self.pieces)
        self.id, self.count, self.pieces = nil, 0, {}
        return data
    end
    return nil
end

return P
