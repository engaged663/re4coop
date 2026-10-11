-- Game-level message codec. Messages ride inside re4coop_net transport packets; see
-- docs/PROTOCOL.md. Pure Lua (string.pack), no game APIs, so it is unit tested offline.

local P = {}

P.VERSION = 8            -- bump on any incompatible change to the layouts below
P.MOD_VERSION = "0.8.1"
P.MAX_PAYLOAD = 1188     -- re4coop_net.max_payload(): biggest message one datagram carries

P.T = {
    HELLO = 1,          -- reliable, both directions, right after connecting
    PLAYER = 2,         -- unreliable, ~20 Hz, both directions: position, HP, flags
    -- 3 was SKELETON (protocols 1-3, the stick-figure ghost)
    ENEMY_SNAPSHOT = 4, -- unreliable, ~20 Hz, host -> client: the host's living enemies
    ENEMY_DAMAGE = 5,   -- reliable, client -> host
    ENEMY_DEAD = 6,     -- reliable, host -> client: one enemy died in the host's world (or a reset)
    CHAT = 7,           -- reliable
    NOTIFY = 8,         -- reliable, short status notices (died, cutscene, teleported...)
    ITEM_TAKEN = 9,     -- reliable, both directions: a shared pickup (key item) was taken
    FRAG = 10,          -- reliable, one piece of a reliable message bigger than a datagram
    AVATAR = 11,        -- reliable (fragmented), how the sender's character is built
    GEAR = 12,          -- reliable, the weapons the sender's character carries
    POSE = 13,          -- unreliable, ~30 Hz, the full skeleton pose + weapon placement
    ACTIONS = 14,       -- reliable, sounds/effects/shots to replay on the partner's model
    ENEMY_HIT = 15,     -- unreliable, both directions: a hit the sender's player landed on an enemy
    ITEM_DROPPED = 16,  -- retired in 0.7 (each player rolls their own loot); still decoded, ignored
    ENEMY_CLIENT = 17,  -- unreliable, ~20 Hz, client -> host: the host's enemies the client has a copy of
    FLAGS = 18,         -- reliable, both directions: scenario flags that changed, by GUID
    FLAG_WORDS = 19,    -- reliable, both directions: scenario flag bits per group (full copy or masks)
    GIMMICKS = 20,      -- reliable, both directions: gimmick save states (doors, locks, levers...)
    OBJECTS = 21,       -- reliable, both directions: breakables/animals destroyed, by GameObject GUID
    CUTSCENE = 22,      -- reliable, both directions: a cutscene (timeline event) started
    WORLD_REQUEST = 23, -- reliable, client -> host: send me your whole world state
    WORLD_DONE = 24,    -- reliable, host -> client: end of a full world state transfer
    ENEMY_GRAVE = 25,   -- reliable, host -> client: every enemy dead in the host's world (full list)
    ANIMALS = 26,       -- unreliable, ~10 Hz, host -> client: the host's animals near its player
}

P.PLAYER_FLAGS = {
    DEAD = 1,
    CUTSCENE = 2,
    AIMING = 4,
    HAS_STAGE = 8,     -- the message carries the player's chainsaw.StageID
    HAS_CHAPTER = 16,  -- the message carries the player's chainsaw.ChapterID
    GATE_WAITING = 32, -- the player is held at a transition until the partner arrives
}

-- The host runs every enemy; the client's copies follow it. (Bits 4 and 16 meant "run by the
-- client" and "hand-over decided" while enemies changed hands between the games; retired.)
P.ENEMY_FLAGS = {
    ALIVE = 1,
    HAS_UID = 2,      -- entry carries the enemy's level identity (see "Enemy identity" below)
    HAS_MOTION = 8,   -- entry carries the enemy's animation (motion bank, motion id, frame)
}

P.ANIMAL_FLAGS = {
    HAS_MOTION = 1,  -- entry carries the animal's animation (motion bank, motion id, frame)
    DEAD = 2,        -- its state machine reached a final state (Die, Dead...)
    HAS_ROUTINE = 4, -- entry carries its _Routine value
}

-------------------------------------------------------------------------------
-- Enemy identity. Every enemy the level places is created by a chainsaw.CharacterSpawnParam
-- whose serialized _ContextID becomes the enemy's own ID (and its SpawnerID): level data, so
-- the same enemy has the same ID on both PCs. Its 32-bit code (ContextID.get_Code(), the key
-- of CharacterManager's context and backup tables) is the enemy's `uid` on the wire.
-- Characters created at runtime get ContextID(Character, 0, group 1, counter & 0x7FF)
-- (CharacterManager.generateDynamicContextID): those IDs differ between PCs and are never
-- sent; such enemies are paired by kind and position instead. See docs/RESEARCH.md 3.8.
-------------------------------------------------------------------------------
P.CHARACTER_CATEGORY = 0
P.DYNAMIC_CHARACTER_GROUP = 1

-- Whether a character's ContextID (table {category, kind, group, index}) is level data.
function P.character_id_stable(ctx)
    return ctx ~= nil and ctx.category == P.CHARACTER_CATEGORY and ctx.group ~= nil
        and ctx.group ~= P.DYNAMIC_CHARACTER_GROUP and (ctx.group ~= 0 or ctx.index ~= 0)
end

P.ENEMY_DEAD_FLAGS = {
    HAS_UID = 1,
    RESET = 2, -- the host's world reloaded: every death it reported before is void
}

P.FLAG_WORDS_MODE = {
    FULL = 1,  -- the sender's complete words for those groups (replace)
    DELTA = 2, -- pairs of masks: bits that turned on, bits that turned off
}

P.GIMMICK_MODE = {
    FULL = 1,  -- the sender's whole table (a joining client)
    DELTA = 2, -- records that changed
    ADDED = 3, -- records that appeared: apply only where the receiver has none for that gimmick
}

P.OBJECT_EVENT = {
    DESTROYED = 1, -- broken / killed / removed from the scene
    ROUTINE = 2,   -- the object's state machine (_Routine) moved to `value`
}

P.WORLD = {
    FLAGS = 1,
    GIMMICKS = 2,
    ENEMIES = 4,
    OBJECTS = 8,
}

P.CUTSCENE_FLAGS = {
    LOCAL_TRIGGER = 1, -- started by the sender's own game (not a replay of ours)
}

P.DAMAGE_FLAGS = {
    LETHAL = 1,
    HAS_UID = 2,
}

P.ITEM_FLAGS = {
    HAS_CTX = 1,
    ONLY_INSTANCE = 2, -- the sender's scene had no other copy of this key item
    HAS_STAGE = 4,
}

-- ENEMY_DEAD with this net id (and the RESET flag): the host's enemies were reset (checkpoint
-- reload), forget every death it reported. Real net ids start at 1.
P.ENEMY_DEAD_RESET = 0

P.HIT_FLAGS = {
    CRITICAL = 1,
    HAS_UID = 2,
}

P.DROP_FLAGS = {
    HAS_STAGE = 1,
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
P.ENEMIES_PER_SNAPSHOT = 19 -- 12 B header + 19 * 59 B entries stays under the 1188 B payload limit
P.MAX_CLIENT_PAIRED = 500 -- 11 B + 500 * 2 B paired ids < 1188 B
P.ANIMALS_PER_MESSAGE = 23 -- 12 B header + 23 * 49 B entries < 1188 B
P.FLAGS_PER_MESSAGE = 64
P.OBJECTS_PER_MESSAGE = 50 -- 2 B + 50 * 21 B
P.GRAVE_PER_MESSAGE = 290 -- 5 B header + 290 * 4 B uids

-- net id, kind hash, position, spawn position, yaw, hp, max hp, flags, uid (ContextID code),
-- motion bank, motion id, motion frame
local ENEMY_ENTRY = "<I2I4fffffffffBI4I4I4f"
-- GameObject GUID (16 raw bytes), position, packed rotation, _Routine, motion bank, motion id,
-- motion frame, flags
local ANIMAL_ENTRY = "<c16fffI4i4I4I4fB"

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

local function clamp_i32(v)
    v = math.floor(tonumber(v) or 0)
    if v > 0x7FFFFFFF then return 0x7FFFFFFF end
    if v < -0x80000000 then return -0x80000000 end
    return v
end

local function clamp_u32(v)
    v = math.floor(tonumber(v) or 0)
    if v < 0 then return 0 end
    if v > 0xFFFFFFFF then return 0xFFFFFFFF end
    return v
end

-- ContextID as group, index, kind, category (the field order ENEMY_ENTRY uses too).
local CTX = "<i4i4BB"

local function pack_ctx(ctx)
    local g, idx, k, c = ctx_fields(ctx)
    return string.pack(CTX, clamp_i32(g), clamp_i32(idx), k, c)
end

local function unpack_ctx(data, off)
    local g, idx, k, c
    g, idx, k, c, off = string.unpack(CTX, data, off)
    return ctx_from(g, idx, k, c), off
end

-- Parses a ctx_key() string back into a ContextID table.
function P.ctx_from_key(key)
    local c, k, g, i = tostring(key):match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if c == nil then return nil end
    return ctx_from(tonumber(g), tonumber(i), tonumber(k), tonumber(c))
end

-------------------------------------------------------------------------------
-- GUIDs (scenario flags, scene objects) travel as 16 raw bytes: the 32 hex digits of the
-- canonical string, in order.
-------------------------------------------------------------------------------

function P.guid_to_bytes(s)
    if type(s) ~= "string" then return nil end
    local hex = s:lower():gsub("[{}%-]", "")
    if #hex ~= 32 or hex:find("[^0-9a-f]") then return nil end
    return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

function P.guid_from_bytes(b)
    if type(b) ~= "string" or #b ~= 16 then return nil end
    local hex = b:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end)
    return ("%s-%s-%s-%s-%s"):format(hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21, 32))
end

-- Lower-case "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", or nil if `s` is not a GUID.
function P.normalize_guid(s)
    local b = P.guid_to_bytes(s)
    return b and P.guid_from_bytes(b) or nil
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

-- An optional Int32 field: returns value, true when it fits, or 0, false.
local function opt_i32(v)
    v = math.tointeger(v)
    if v ~= nil and v >= -0x80000000 and v <= 0x7FFFFFFF then return v, true end
    return 0, false
end

-- m = { time, pos={x,y,z}, rot={x,y,z,w}, hp, max_hp, flags, area_hash, stage, chapter }
-- stage/chapter: the player's chainsaw.StageID / chainsaw.ChapterID (nil if unknown).
local PLAYER_FORMAT = "<BdfffffffffBI4i4i4"
function P.encode_player(m)
    local pos, rot = m.pos, m.rot
    local F = P.PLAYER_FLAGS
    local flags = (m.flags or 0) & ~(F.HAS_STAGE | F.HAS_CHAPTER)
    local stage, has_stage = opt_i32(m.stage)
    local chapter, has_chapter = opt_i32(m.chapter)
    if has_stage then flags = flags | F.HAS_STAGE end
    if has_chapter then flags = flags | F.HAS_CHAPTER end
    return string.pack(PLAYER_FORMAT, P.T.PLAYER, m.time or 0,
        pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w,
        m.hp or 0, m.max_hp or 0, flags, m.area_hash or 0, stage, chapter)
end

-- A uid travels as a u32; 0 means "none" (an empty ContextID has code 0).
local function uid_or_zero(uid)
    uid = math.tointeger(uid)
    if uid == nil or uid <= 0 or uid > 0xFFFFFFFF then return 0 end
    return uid
end

-- Splits the enemy list into as many messages as needed. Returns an array of strings.
-- entry = { net_id, kind_hash, pos={x,y,z}, spawn={x,y,z}, yaw, hp, max_hp, flags, uid,
--           motion={bank, id, frame}|nil }
-- `uid` is the enemy's level identity (nil for characters created at runtime). `spawn` is
-- where the host first saw the enemy: with the kind, the fallback identity without a uid.
-- `motion` is the animation playing on the enemy (for mirroring it on the client).
function P.encode_enemy_snapshots(time, entries)
    local out = {}
    local per = P.ENEMIES_PER_SNAPSHOT
    local chunks = math.max(1, math.ceil(#entries / per))
    local F = P.ENEMY_FLAGS
    for c = 1, chunks do
        local first = (c - 1) * per + 1
        local last = math.min(#entries, c * per)
        local count = math.max(0, last - first + 1)
        local parts = { string.pack("<BdBBB", P.T.ENEMY_SNAPSHOT, time, c, chunks, count) }
        for i = first, last do
            local e = entries[i]
            local spawn = e.spawn or e.pos
            local uid = uid_or_zero(e.uid)
            local flags = (e.flags or 0) & ~(F.HAS_UID | F.HAS_MOTION)
            if uid ~= 0 then flags = flags | F.HAS_UID end
            local motion = e.motion or {}
            if e.motion ~= nil then flags = flags | F.HAS_MOTION end
            parts[#parts + 1] = string.pack(ENEMY_ENTRY, e.net_id, e.kind_hash,
                e.pos.x, e.pos.y, e.pos.z, spawn.x, spawn.y, spawn.z,
                e.yaw or 0, e.hp or 0, e.max_hp or 0, flags, uid,
                clamp_u32(motion.bank), clamp_u32(motion.id), motion.frame or 0)
        end
        out[#out + 1] = table.concat(parts)
    end
    return out
end

-- Client -> host, every ~50 ms: paired = { net_id ... }, every host enemy the client has a
-- living copy of (the host reads those enemies' animation for the client to mirror).
function P.encode_enemy_client(time, paired)
    local np = math.min(#paired, P.MAX_CLIENT_PAIRED)
    local parts = { string.pack("<BdI2", P.T.ENEMY_CLIENT, time, np) }
    for i = 1, np do
        parts[#parts + 1] = string.pack("<I2", paired[i])
    end
    return table.concat(parts)
end

-- Host -> client, ~10 Hz: the host's animals near its player. Returns an array of strings.
-- animal = { guid = "xxxxxxxx-....", pos = {x,y,z}, rot = {x,y,z,w}, routine = int|nil,
--            motion = {bank, id, frame}|nil, dead = bool }. Entries with a bad GUID are skipped.
function P.encode_animals(time, animals)
    local list = {}
    for _, a in ipairs(animals) do
        local g = P.guid_to_bytes(a.guid)
        if g ~= nil then list[#list + 1] = { a = a, g = g } end
    end
    local F = P.ANIMAL_FLAGS
    local per = P.ANIMALS_PER_MESSAGE
    local chunks = math.max(1, math.ceil(#list / per))
    local out = {}
    for c = 1, chunks do
        local first = (c - 1) * per + 1
        local last = math.min(#list, c * per)
        local count = math.max(0, last - first + 1)
        local parts = { string.pack("<BdBBB", P.T.ANIMALS, time, c, chunks, count) }
        for i = first, last do
            local a, g = list[i].a, list[i].g
            local flags = 0
            if a.motion ~= nil then flags = flags | F.HAS_MOTION end
            if a.dead then flags = flags | F.DEAD end
            local routine, has_routine = opt_i32(a.routine)
            if has_routine then flags = flags | F.HAS_ROUTINE end
            local motion = a.motion or {}
            parts[#parts + 1] = string.pack(ANIMAL_ENTRY, g, a.pos.x, a.pos.y, a.pos.z, pack_rot(a.rot), routine,
                clamp_u32(motion.bank), clamp_u32(motion.id), motion.frame or 0, flags)
        end
        out[#out + 1] = table.concat(parts)
    end
    return out
end

-- flags = { {guid="xxxxxxxx-....", value=bool}, ... } -> array of messages
function P.encode_flags(flags)
    local out = {}
    local i = 1
    repeat
        local last = math.min(#flags, i + P.FLAGS_PER_MESSAGE - 1)
        local parts = { "" }
        local n = 0
        for k = i, last do
            local b = P.guid_to_bytes(flags[k].guid)
            if b ~= nil then
                parts[#parts + 1] = b .. string.pack("<B", flags[k].value and 1 or 0)
                n = n + 1
            end
        end
        parts[1] = string.pack("<BB", P.T.FLAGS, n)
        out[#out + 1] = table.concat(parts)
        i = last + 1
    until i > #flags
    return out
end

-- Packs variable-size items into as few messages as fit the payload limit.
-- make_header(chunk, chunks, count) -> string; items are already-packed strings.
local function chunk_items(items, header_size, make_header)
    local groups, cur, size = {}, {}, header_size
    for _, it in ipairs(items) do
        if #cur > 0 and (size + #it > P.MAX_PAYLOAD or #cur >= 255) then
            groups[#groups + 1] = cur
            cur, size = {}, header_size
        end
        cur[#cur + 1] = it
        size = size + #it
    end
    groups[#groups + 1] = cur
    local out = {}
    for c, g in ipairs(groups) do
        out[c] = make_header(c, #groups, #g) .. table.concat(g)
    end
    return out
end

-- Full mode: groups = { {name, words={u32,...}}, ... }
-- Delta mode: groups = { {name, changes={ {word=i (0-based), set=mask, clear=mask}, ... }}, ... }
function P.encode_flag_words(sync_id, mode, groups)
    local items = {}
    for _, g in ipairs(groups) do
        local name = tostring(g.name):sub(1, 255)
        -- Bytes one item may use: payload - message header - name - first/count.
        local room = P.MAX_PAYLOAD - 7 - (1 + #name) - 4
        if mode == P.FLAG_WORDS_MODE.FULL then
            local words = g.words or {}
            local first = 0
            repeat
                local n = math.min(#words - first, room // 4)
                local parts = { string.pack("<s1I2I2", name, first, n) }
                for k = first + 1, first + n do
                    parts[#parts + 1] = string.pack("<I4", clamp_u32(words[k]))
                end
                items[#items + 1] = table.concat(parts)
                first = first + n
            until first >= #words
        else
            local changes = g.changes or {}
            local first = 1
            repeat
                local n = math.min(#changes - first + 1, room // 10)
                local parts = { string.pack("<s1I2I2", name, 0, n) }
                for k = first, first + n - 1 do
                    local c = changes[k]
                    parts[#parts + 1] = string.pack("<I2I4I4", c.word, clamp_u32(c.set), clamp_u32(c.clear))
                end
                items[#items + 1] = table.concat(parts)
                first = first + n
            until first > #changes
        end
    end
    return chunk_items(items, 7, function(c, n, count)
        return string.pack("<BI2BBBB", P.T.FLAG_WORDS, (sync_id or 0) & 0xFFFF, mode, c, n, count)
    end)
end

-- item = { ctx, attr="<raw bytes>", triggers={ {id, done}, ... }, detected=bool,
--          acc={ {kind=1|2, value=n}, ... } }   (accessory kind 1 = float, 2 = uint32)
local function pack_gimmick(item)
    local attr = item.attr or ""
    if #attr > 255 then attr = attr:sub(1, 255) end
    local parts = { pack_ctx(item.ctx), string.pack("<s1", attr) }
    local triggers = item.triggers or {}
    local nt = math.min(#triggers, 64)
    parts[#parts + 1] = string.pack("<B", nt)
    for i = 1, nt do
        parts[#parts + 1] = string.pack("<I4I4", clamp_u32(triggers[i].id), clamp_u32(triggers[i].done))
    end
    parts[#parts + 1] = string.pack("<B", item.detected and 1 or 0)
    local acc = item.acc or {}
    local na = math.min(#acc, 64)
    parts[#parts + 1] = string.pack("<B", na)
    for i = 1, na do
        local a = acc[i]
        if a.kind == 1 then
            parts[#parts + 1] = string.pack("<Bf", 1, a.value or 0)
        else
            parts[#parts + 1] = string.pack("<BI4", 2, clamp_u32(a.value))
        end
    end
    return table.concat(parts)
end

function P.encode_gimmicks(sync_id, mode, items)
    local packed = {}
    for i, it in ipairs(items) do packed[i] = pack_gimmick(it) end
    return chunk_items(packed, 7, function(c, n, count)
        return string.pack("<BI2BBBB", P.T.GIMMICKS, (sync_id or 0) & 0xFFFF, mode, c, n, count)
    end)
end

-- events = { {guid, event=P.OBJECT_EVENT.*, value=int}, ... } -> array of messages
function P.encode_objects(events)
    local out = {}
    local i = 1
    repeat
        local last = math.min(#events, i + P.OBJECTS_PER_MESSAGE - 1)
        local parts = { "" }
        local n = 0
        for k = i, last do
            local e = events[k]
            local b = P.guid_to_bytes(e.guid)
            if b ~= nil then
                parts[#parts + 1] = b .. string.pack("<Bi4", e.event or 0, clamp_i32(e.value or 0))
                n = n + 1
            end
        end
        parts[1] = string.pack("<BB", P.T.OBJECTS, n)
        out[#out + 1] = table.concat(parts)
        i = last + 1
    until i > #events
    return out
end

-- m = { id (chainsaw.TimelineEventDefine.ID), method, chapter, stage, pos={x,y,z}|nil, flags }
function P.encode_cutscene(m)
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    return string.pack("<Bi4s1i4i4fffB", P.T.CUTSCENE, clamp_i32(m.id), (m.method or ""):sub(1, 255),
        clamp_i32(m.chapter or -1), clamp_i32(m.stage or -1), pos.x, pos.y, pos.z, m.flags or 0)
end

function P.encode_world_request(sync_id, what)
    return string.pack("<BI2B", P.T.WORLD_REQUEST, (sync_id or 0) & 0xFFFF, what or 0)
end

function P.encode_world_done(sync_id, what, n_flag_groups, n_gimmicks)
    return string.pack("<BI2BI4I4", P.T.WORLD_DONE, (sync_id or 0) & 0xFFFF, what or 0,
        clamp_u32(n_flag_groups), clamp_u32(n_gimmicks))
end

-- m = { net_id (0 if unknown), kind_hash, pos={x,y,z} (spawn point), amount, flags, uid }
local ENEMY_DAMAGE = "<BI2I4ffffBI4"
function P.encode_enemy_damage(m)
    local uid = uid_or_zero(m.uid)
    local flags = (m.flags or 0) & ~P.DAMAGE_FLAGS.HAS_UID
    if uid ~= 0 then flags = flags | P.DAMAGE_FLAGS.HAS_UID end
    return string.pack(ENEMY_DAMAGE, P.T.ENEMY_DAMAGE, m.net_id or 0, m.kind_hash or 0,
        m.pos.x, m.pos.y, m.pos.z, m.amount or 0, flags, uid)
end

-- m = { item_id, pos={x,y,z}, ctx, stage, only_instance }
-- ctx = the pickup's chainsaw.ContextID (may be nil), stage = its chainsaw.StageID (may be nil),
-- only_instance = the sender saw no other copy of this item in its scene.
local ITEM_TAKEN = "<BI4fffBi4i4BBi4"
function P.encode_item_taken(m)
    local F = P.ITEM_FLAGS
    local flags = m.ctx ~= nil and F.HAS_CTX or 0
    if m.only_instance then flags = flags | F.ONLY_INSTANCE end
    local stage, has_stage = opt_i32(m.stage)
    if has_stage then flags = flags | F.HAS_STAGE end
    local g, idx, k, c = ctx_fields(m.ctx)
    return string.pack(ITEM_TAKEN, P.T.ITEM_TAKEN, m.item_id or 0,
        m.pos.x, m.pos.y, m.pos.z, flags, g, idx, k, c, stage)
end

-- m = { net_id (0 if unknown), kind_hash, pos={x,y,z} (enemy spawn point, for matching),
--       damage, wince, break_, stopping, dir={x,y,z}, weapon, critical, uid }
-- The parameters of a chainsaw.HitController.DamageInfo the sender's player caused.
local ENEMY_HIT = "<BI2I4fffi4ffffffi4BI4"
function P.encode_enemy_hit(m)
    local dir = m.dir or { x = 0, y = 0, z = 0 }
    local damage = opt_i32(m.damage and math.floor(m.damage + 0.5))
    local weapon = opt_i32(m.weapon)
    local uid = uid_or_zero(m.uid)
    local flags = m.critical and P.HIT_FLAGS.CRITICAL or 0
    if uid ~= 0 then flags = flags | P.HIT_FLAGS.HAS_UID end
    return string.pack(ENEMY_HIT, P.T.ENEMY_HIT, m.net_id or 0, m.kind_hash or 0,
        m.pos.x, m.pos.y, m.pos.z, damage, m.wince or 0, m.break_ or 0, m.stopping or 0,
        dir.x, dir.y, dir.z, weapon, flags, uid)
end

-- m = { net_id (host's enemy), item_id, count, pos={x,y,z}, stage }
local ITEM_DROPPED = "<BI2I4i4fffi4B"
function P.encode_item_dropped(m)
    local stage, has_stage = opt_i32(m.stage)
    local count = opt_i32(m.count)
    return string.pack(ITEM_DROPPED, P.T.ITEM_DROPPED, m.net_id or 0, m.item_id or 0, count,
        m.pos.x, m.pos.y, m.pos.z, stage, has_stage and P.DROP_FLAGS.HAS_STAGE or 0)
end

-- One enemy died in the host's world: its net id and (if it has one) its uid.
local ENEMY_DEAD = "<BI2BI4"
function P.encode_enemy_dead(net_id, uid)
    uid = uid_or_zero(uid)
    return string.pack(ENEMY_DEAD, P.T.ENEMY_DEAD, net_id or 0, uid ~= 0 and P.ENEMY_DEAD_FLAGS.HAS_UID or 0, uid)
end

-- The host's world reloaded (checkpoint): every death it reported before is void.
function P.encode_enemy_dead_reset()
    return string.pack(ENEMY_DEAD, P.T.ENEMY_DEAD, P.ENEMY_DEAD_RESET, P.ENEMY_DEAD_FLAGS.RESET, 0)
end

-- The uids of every enemy dead in the host's world. The first message of a list replaces
-- what the receiver knew; the others add to it (the ordered lane keeps them in order).
-- Returns an array of strings (at least one: an empty list is a list too).
function P.encode_enemy_grave(uids)
    local list = {}
    for _, uid in ipairs(uids) do
        uid = uid_or_zero(uid)
        if uid ~= 0 then list[#list + 1] = uid end
    end
    local per = P.GRAVE_PER_MESSAGE
    local chunks = math.max(1, math.ceil(#list / per))
    local out = {}
    for c = 1, chunks do
        local first = (c - 1) * per + 1
        local last = math.min(#list, c * per)
        local count = math.max(0, last - first + 1)
        local parts = { string.pack("<BBBI2", P.T.ENEMY_GRAVE, c, chunks, count) }
        for i = first, last do parts[#parts + 1] = string.pack("<I4", list[i]) end
        out[#out + 1] = table.concat(parts)
    end
    return out
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
    local _, time, px, py, pz, qx, qy, qz, qw, hp, max_hp, flags, area_hash, stage, chapter =
        string.unpack(PLAYER_FORMAT, data)
    return {
        time = time,
        pos = { x = px, y = py, z = pz },
        rot = { x = qx, y = qy, z = qz, w = qw },
        hp = hp, max_hp = max_hp, flags = flags, area_hash = area_hash,
        stage = (flags & P.PLAYER_FLAGS.HAS_STAGE) ~= 0 and stage or nil,
        chapter = (flags & P.PLAYER_FLAGS.HAS_CHAPTER) ~= 0 and chapter or nil,
    }
end

decoders[P.T.ENEMY_SNAPSHOT] = function(data)
    local _, time, chunk, chunks, count, off = string.unpack("<BdBBB", data)
    local m = { time = time, chunk = chunk, chunks = chunks, enemies = {} }
    local F = P.ENEMY_FLAGS
    for i = 1, count do
        local net_id, kind_hash, x, y, z, sx, sy, sz, yaw, hp, max_hp, flags, uid, bank, mid, frame
        net_id, kind_hash, x, y, z, sx, sy, sz, yaw, hp, max_hp, flags, uid, bank, mid, frame, off =
            string.unpack(ENEMY_ENTRY, data, off)
        m.enemies[i] = {
            net_id = net_id, kind_hash = kind_hash,
            pos = { x = x, y = y, z = z }, spawn = { x = sx, y = sy, z = sz },
            yaw = yaw, hp = hp, max_hp = max_hp, flags = flags,
            uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
            motion = (flags & F.HAS_MOTION) ~= 0 and { bank = bank, id = mid, frame = frame } or nil,
        }
    end
    return m
end

decoders[P.T.ENEMY_CLIENT] = function(data)
    local _, time, np, off = string.unpack("<BdI2", data)
    local m = { time = time, paired = {} }
    for i = 1, np do
        m.paired[i], off = string.unpack("<I2", data, off)
    end
    return m
end

decoders[P.T.ANIMALS] = function(data)
    local _, time, chunk, chunks, count, off = string.unpack("<BdBBB", data)
    if chunk < 1 or chunk > chunks then error("bad chunk") end
    local F = P.ANIMAL_FLAGS
    local m = { time = time, chunk = chunk, chunks = chunks, animals = {} }
    for i = 1, count do
        local g, x, y, z, rot, routine, bank, mid, frame, flags
        g, x, y, z, rot, routine, bank, mid, frame, flags, off = string.unpack(ANIMAL_ENTRY, data, off)
        m.animals[i] = {
            guid = P.guid_from_bytes(g),
            pos = { x = x, y = y, z = z },
            rot = unpack_rot(rot),
            routine = (flags & F.HAS_ROUTINE) ~= 0 and routine or nil,
            motion = (flags & F.HAS_MOTION) ~= 0 and { bank = bank, id = mid, frame = frame } or nil,
            dead = (flags & F.DEAD) ~= 0,
        }
    end
    return m
end

decoders[P.T.FLAGS] = function(data)
    local _, n, off = string.unpack("<BB", data)
    local flags = {}
    for i = 1, n do
        if off + 16 > #data then error("truncated") end
        local guid = P.guid_from_bytes(data:sub(off, off + 15))
        local value = string.unpack("<B", data, off + 16)
        off = off + 17
        flags[i] = { guid = guid, value = value ~= 0 }
    end
    return { flags = flags }
end

decoders[P.T.FLAG_WORDS] = function(data)
    local _, sync_id, mode, chunk, chunks, count, off = string.unpack("<BI2BBBB", data)
    if chunk < 1 or chunk > chunks then error("bad chunk") end
    local m = { sync_id = sync_id, mode = mode, chunk = chunk, chunks = chunks, groups = {} }
    for i = 1, count do
        local name, first, n
        name, first, n, off = string.unpack("<s1I2I2", data, off)
        local g = { name = name, first = first }
        if mode == P.FLAG_WORDS_MODE.FULL then
            g.words = {}
            for k = 1, n do
                g.words[k], off = string.unpack("<I4", data, off)
            end
        else
            g.changes = {}
            for k = 1, n do
                local word, set, clear
                word, set, clear, off = string.unpack("<I2I4I4", data, off)
                g.changes[k] = { word = word, set = set, clear = clear }
            end
        end
        m.groups[i] = g
    end
    return m
end

decoders[P.T.GIMMICKS] = function(data)
    local _, sync_id, mode, chunk, chunks, count, off = string.unpack("<BI2BBBB", data)
    if chunk < 1 or chunk > chunks then error("bad chunk") end
    local m = { sync_id = sync_id, mode = mode, chunk = chunk, chunks = chunks, items = {} }
    for i = 1, count do
        local item = {}
        item.ctx, off = unpack_ctx(data, off)
        item.attr, off = string.unpack("<s1", data, off)
        local nt
        nt, off = string.unpack("<B", data, off)
        item.triggers = {}
        for k = 1, nt do
            local id, done
            id, done, off = string.unpack("<I4I4", data, off)
            item.triggers[k] = { id = id, done = done }
        end
        local detected, na
        detected, na, off = string.unpack("<BB", data, off)
        item.detected = detected ~= 0
        item.acc = {}
        for k = 1, na do
            local kind, value
            kind, off = string.unpack("<B", data, off)
            if kind == 1 then
                value, off = string.unpack("<f", data, off)
            else
                value, off = string.unpack("<I4", data, off)
            end
            item.acc[k] = { kind = kind, value = value }
        end
        m.items[i] = item
    end
    return m
end

decoders[P.T.OBJECTS] = function(data)
    local _, n, off = string.unpack("<BB", data)
    local events = {}
    for i = 1, n do
        if off + 20 > #data then error("truncated") end
        local guid = P.guid_from_bytes(data:sub(off, off + 15))
        local event, value = string.unpack("<Bi4", data, off + 16)
        off = off + 21
        events[i] = { guid = guid, event = event, value = value }
    end
    return { events = events }
end

decoders[P.T.CUTSCENE] = function(data)
    local _, id, method, chapter, stage, x, y, z, flags = string.unpack("<Bi4s1i4i4fffB", data)
    return { id = id, method = method, chapter = chapter, stage = stage, pos = { x = x, y = y, z = z }, flags = flags }
end

decoders[P.T.WORLD_REQUEST] = function(data)
    local _, sync_id, what = string.unpack("<BI2B", data)
    return { sync_id = sync_id, what = what }
end

decoders[P.T.WORLD_DONE] = function(data)
    local _, sync_id, what, n_flag_groups, n_gimmicks = string.unpack("<BI2BI4I4", data)
    return { sync_id = sync_id, what = what, n_flag_groups = n_flag_groups, n_gimmicks = n_gimmicks }
end

decoders[P.T.ENEMY_DAMAGE] = function(data)
    local _, net_id, kind_hash, x, y, z, amount, flags, uid = string.unpack(ENEMY_DAMAGE, data)
    return {
        net_id = net_id, kind_hash = kind_hash, pos = { x = x, y = y, z = z }, amount = amount, flags = flags,
        uid = ((flags & P.DAMAGE_FLAGS.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
    }
end

decoders[P.T.ITEM_TAKEN] = function(data)
    local _, item_id, x, y, z, flags, g, idx, k, c, stage = string.unpack(ITEM_TAKEN, data)
    local F = P.ITEM_FLAGS
    return {
        item_id = item_id, pos = { x = x, y = y, z = z },
        ctx = (flags & F.HAS_CTX) ~= 0 and ctx_from(g, idx, k, c) or nil,
        only_instance = (flags & F.ONLY_INSTANCE) ~= 0,
        stage = (flags & F.HAS_STAGE) ~= 0 and stage or nil,
    }
end

decoders[P.T.ENEMY_HIT] = function(data)
    local _, net_id, kind_hash, x, y, z, damage, wince, break_, stopping, dx, dy, dz, weapon, flags, uid =
        string.unpack(ENEMY_HIT, data)
    return {
        net_id = net_id, kind_hash = kind_hash, pos = { x = x, y = y, z = z },
        damage = damage, wince = wince, break_ = break_, stopping = stopping,
        dir = { x = dx, y = dy, z = dz }, weapon = weapon,
        critical = (flags & P.HIT_FLAGS.CRITICAL) ~= 0,
        uid = ((flags & P.HIT_FLAGS.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
    }
end

decoders[P.T.ITEM_DROPPED] = function(data)
    local _, net_id, item_id, count, x, y, z, stage, flags = string.unpack(ITEM_DROPPED, data)
    return {
        net_id = net_id, item_id = item_id, count = count, pos = { x = x, y = y, z = z },
        stage = (flags & P.DROP_FLAGS.HAS_STAGE) ~= 0 and stage or nil,
    }
end

decoders[P.T.ENEMY_DEAD] = function(data)
    local _, net_id, flags, uid = string.unpack(ENEMY_DEAD, data)
    local F = P.ENEMY_DEAD_FLAGS
    return {
        net_id = net_id,
        uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
        reset = (flags & F.RESET) ~= 0,
    }
end

decoders[P.T.ENEMY_GRAVE] = function(data)
    local _, chunk, chunks, count, off = string.unpack("<BBBI2", data)
    if chunk < 1 or chunk > chunks then error("bad chunk") end
    local uids = {}
    for i = 1, count do
        uids[i], off = string.unpack("<I4", data, off)
    end
    return { chunk = chunk, chunks = chunks, uids = uids }
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
