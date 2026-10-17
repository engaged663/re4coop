-- Game-level message codec. Messages ride inside re4coop_net transport packets; see
-- docs/PROTOCOL.md. Pure Lua (string.pack), no game APIs, so it is unit tested offline.

local P = {}

P.VERSION = 15           -- bump on any incompatible change to the layouts below
P.MOD_VERSION = "0.11.2"
P.MAX_PAYLOAD = 1188     -- re4coop_net.max_payload(): biggest message one datagram carries

P.T = {
    HELLO = 1,          -- reliable, both directions, right after connecting
    PLAYER = 2,         -- unreliable, ~20 Hz, both directions: position, HP, flags
    -- 3 was SKELETON (protocols 1-3, the stick-figure ghost)
    -- 4, 5, 6 were ENEMY_SNAPSHOT, ENEMY_DAMAGE, ENEMY_DEAD (protocols 1-8, the old enemy sync)
    CHAT = 7,           -- reliable
    NOTIFY = 8,         -- reliable, short status notices (died, cutscene, teleported...)
    ITEM_TAKEN = 9,     -- reliable, both directions: a shared pickup (key item) was taken
    FRAG = 10,          -- reliable, one piece of a reliable message bigger than a datagram
    AVATAR = 11,        -- reliable (fragmented), how the sender's character is built
    GEAR = 12,          -- reliable, the weapons the sender's character carries
    POSE = 13,          -- unreliable, ~30 Hz, the full skeleton pose + weapon placement
    ACTIONS = 14,       -- reliable, sounds/effects/shots to replay on the partner's model
    -- 15 was the old ENEMY_HIT (protocols 5-8)
    ITEM_DROPPED = 16,  -- retired in 0.7 (each player rolls their own loot); still decoded, ignored
    -- 17 was ENEMY_CLIENT (protocols 6-8)
    FLAGS = 18,         -- reliable, both directions: scenario flags that turned on (or pulsed), by GUID
    FLAG_WORDS = 19,    -- reliable, both directions: scenario flag bits per group (full copy or masks)
    GIMMICKS = 20,      -- reliable, both directions: gimmick save states (doors, locks, levers...)
    OBJECTS = 21,       -- reliable, both directions: breakables/animals destroyed, by GameObject GUID
    CUTSCENE = 22,      -- reliable, both directions: a cutscene started (the game's own PayloadPlay)
    WORLD_REQUEST = 23, -- reliable, client -> host: send me your whole world state
    WORLD_DONE = 24,    -- reliable, host -> client: end of a full world state transfer
    ENEMY_GRAVE = 25,   -- reliable, host -> client: every enemy dead in the host's world (full list)
    ANIMALS = 26,       -- unreliable, ~10 Hz, host -> client: the host's animals near its player
    -- Enemy sync (protocol 13): the host's game runs every enemy; see enemy_net.lua.
    ENEMY_STATE = 27,   -- unreliable, ~20 Hz, host -> client: the host's enemies (full state)
    ENEMY_HIT = 28,     -- reliable, both directions: a hit the sender's player landed (the host runs the client's)
    ENEMY_DEATH = 29,   -- reliable, host -> client: an enemy died in the host's game (or the host's world reset)
    ENEMY_OWNER = 30,   -- reliable, host -> client: the host's numbering of its enemies (assigned / retired)
    ENEMY_ROSTER = 31,  -- unreliable, ~5 Hz, client -> host: the host's enemies the client has a copy of
    TRIGGER = 32,       -- reliable, both directions: the sender's player set off a level event trigger
    CUTSCENE_SKIP = 33, -- reliable, both directions: the sender's player skipped a cutscene
    DOORS = 34,         -- reliable, both directions: doors near the sender that opened, closed or are held open
    ITEM_GIVE = 35,     -- reliable, both directions: an item the sender's player gave the receiver
    ITEM_GIVE_RESULT = 36, -- reliable, both directions: how much of a given item did not fit
    -- 37 was ENEMY_CLAIM (protocols 10-12: a client's finisher took the enemy over)
    SAVE = 38,          -- reliable, both directions: the sender's game saved (the receiver's game saves too)
    TRAPS = 39,         -- reliable, both directions: traps that went off in the sender's game (bear traps, sensor bombs)
    MECHANISMS = 40,    -- reliable, both directions: a gimmick's scripted sequence / a pushed object moved in the sender's game
    -- Ashley (protocol 11): one Ashley for both games, run by one of them (ashley_sync.lua).
    ASHLEY = 41,        -- unreliable, both directions: the owner's Ashley (~20 Hz, full state) / the other's presence (~2 Hz)
    ASHLEY_OWNER = 42,  -- reliable, host -> client: whose game runs Ashley (or why a switch was refused)
    ASHLEY_SWITCH = 43, -- reliable, client -> host: the client's player asked to switch Ashley over
    PURPOSE = 44,       -- reliable, both directions: the sender's current objective (purpose_sync.lua)
    -- Protocol 12: Ashley's animation in full.
    ASHLEY_BANKS = 45,  -- reliable, owner -> other: the extra motion banks (motlists) her motion has loaded
    -- Protocol 13: the client's player is a second player in the host's game (partner_target.lua).
    ENEMY_FATAL = 46,   -- reliable, client -> host: the client's player started a finisher on a host enemy
    PLAYER_NOISE = 47,  -- unreliable, client -> host: noises the client's player made (enemies hear them)
    PLAYER_DAMAGE = 48, -- reliable, host -> client: a hit the client's character took in the host's game
    -- Protocol 14: parries and grabs of the client's player.
    ACTION_SIGN = 49,   -- unreliable, host -> client: a host enemy's attack warns the client's character (parry/dodge prompt)
    ENEMY_PARRY = 50,   -- reliable, client -> host: the client's player parried a host enemy's attack
    PLAYER_GRAB = 51,   -- reliable, host -> client: a host enemy holds the client's character (or let go)
    GRAB_ESCAPE = 52,   -- reliable, client -> host: the client's player broke free of a host enemy's hold
    -- Protocol 15: the lobby in the game's own main menu, and the synchronized start (lobby.lua).
    LOBBY_SETTINGS = 53, -- reliable, host -> client: the host's choices for the next game (save, chapter, difficulty, options)
    LOBBY_PLAYER = 54,   -- reliable, both directions: the sender's player in the lobby (name, loadout, ready)
    LOBBY_START = 55,    -- reliable, host -> client: both games start the agreed game now
    LOAD_STATE = 56,     -- reliable, both directions: how far the sender's game is with loading the started game
    LOAD_GO = 57,        -- reliable, host -> client: both games have loaded: the map starts now
}

-- LOBBY_SETTINGS / LOBBY_START: a new game, or the co-op save of the chosen file.
P.LOBBY_MODE = { NEW = 0, CONTINUE = 1 }

-- LOAD_STATE phases, in order (a later phase is further along).
P.LOAD_PHASE = {
    NONE = 0,
    STARTING = 1,  -- the game was asked to start; still on the main menu
    LOADING = 2,   -- left the menu: loading screen, no player yet
    SYNCING = 3,   -- client: in the map, taking over the host's world / joining the host
    READY = 4,     -- in the map and held until the partner is ready too
    PLAYING = 5,   -- released: the map runs
    FAILED = 6,    -- the start did not happen in this game (the partner stops waiting for it)
}

-- ASHLEY flags.
P.ASHLEY_FLAGS = {
    PRESENT = 1,   -- the sender's game has an Ashley right now
    OWNER = 2,     -- the sender's game runs her: the message carries her full state
    ALIVE = 4,
    KIDNAPPED = 8, -- carried off by an enemy
    BUSY = 16,     -- she cannot change hands now (kidnapped, down, hiding, on a gimmick)
    HIDDEN = 32,   -- the owner's game does not draw her
}

-- ASHLEY_OWNER reasons: a change, or why the asked-for switch did not happen.
P.ASHLEY_REASON = {
    CHANGED = 0,   -- Ashley now follows `owner` (asked by a player)
    AUTO = 1,      -- the game that ran her has no Ashley any more: she went to the other one
    COOLDOWN = 2,  -- refused: switched less than the cooldown ago
    BUSY = 3,      -- refused: she is kidnapped, down or busy
    ABSENT = 4,    -- refused: the other game has no Ashley here / is not playing
    ANNOUNCE = 5,  -- the current owner, repeated (a client that just connected)
}

-- MECHANISMS: what moved. PORTRAYAL: PortrayalSettings.call(key) on that GameObject; PUSH: a
-- GmPushMove (cart, shelf) was pushed.
P.MECH_KIND = { PORTRAYAL = 1, PUSH = 2 }
P.MAX_MECHS_PER_MESSAGE = 50

-- TRAPS: the kind of trap and what happened to it.
P.TRAP_KIND = { LEG_HOLD = 1, SENSOR_BOMB = 2 }
P.TRAP_EVENT = {
    FIRED = 1,    -- a bear trap snapped shut / a sensor bomb went off (the receiver's plays it)
    REARMED = 2,  -- a bear trap was opened again (by a villager)
    SPENT = 3,    -- already closed / gone before (a joining partner): set without playing it
}
P.MAX_TRAPS_PER_MESSAGE = 60

-- SAVE: what kind of save the sender's game made.
P.SAVE_KIND = { AUTO = 1, MANUAL = 2 }

P.PLAYER_FLAGS = {
    DEAD = 1,
    CUTSCENE = 2,
    AIMING = 4,
    HAS_STAGE = 8,     -- the message carries the player's chainsaw.StageID
    HAS_CHAPTER = 16,  -- the message carries the player's chainsaw.ChapterID
    GATE_WAITING = 32, -- the player is held at a transition until the partner arrives
    INVINCIBLE = 64,   -- the sender's Options ask for invincibility: both players are invincible
}

-- ENEMY_STATE entry flags.
P.ENEMY_STATE_FLAGS = {
    ALIVE = 1,
    HAS_UID = 2,    -- entry carries the enemy's level identity (see "Enemy identity" below)
    HIDDEN = 4,     -- the owner's game does not draw the enemy right now
    HAS_SPAWN = 8,  -- entry carries where the owner first saw the enemy (enemies without a uid)
}

-- ENEMY_STATE entry: what the host's enemy says about the client's player (the client's game
-- shows finisher prompts from it: its own copy of the enemy does not think).
P.PARTNER_INFO = {
    FATAL = 1,       -- EnemyHeadUpdater.isEnableFatal(client's character)
    KNIFE = 2,       -- isEnableKnifeFatal(client's character)
    STEALTH = 4,     -- isEnableStealthKill(client's character)
    TARGETS = 8,     -- the enemy's current target is the client's character
    KNOWN = 128,     -- the host asked the enemy (without it: no answer, never a prompt)
}

-- ENEMY_FATAL kinds: which request the client's player made of the enemy's AI head.
P.FATAL_KIND = {
    KILL = 1,        -- requestFatalKill (knife finish, stomp, a grab that kills)
    STEALTH = 2,     -- requestStealthKill (from behind)
    NORMAL = 3,      -- convertNormalFatalAction (kicks, with their PlayerDefine.FatalType)
}

-- PLAYER_DAMAGE flags.
P.PLAYER_DAMAGE_FLAGS = {
    HAS_UID = 1,     -- the attacking enemy's level identity
    FROM_ENEMY = 2,  -- an enemy hit the client's character (else a hazard: an explosion, a trap...)
    GRAB = 4,        -- the attack is a grab (chainsaw.collision.GrappleUserData, with its priority)
}

-- ACTION_SIGN flags (chainsaw.ActionSignHitInfo).
P.ACTION_SIGN_FLAGS = { JUST = 1, ACT = 2, ANGLE_CHECK = 4, HAS_UID = 8 }

-- ENEMY_PARRY kinds: what the client's player did to the host enemy's attack
-- (chainsaw.IActionSignNotifier).
P.PARRY_KIND = {
    PARRY = 1,       -- onParry: the parry landed (the enemy staggers)
    INPUT = 2,       -- onParryInput: the parry button was pressed during the warning
}

-- GRAB_ESCAPE: how the client's player broke free.
P.ESCAPE_KIND = { MASH = 1, KNIFE = 2 }
P.MAX_NOISES = 16

-- Who owns an enemy (ENEMY_OWNER): its game runs the enemy's AI and sends its state.
P.OWNER = { HOST = 0, CLIENT = 1, NONE = 255 } -- NONE: the host retired that net id

-- ENEMY_ROSTER entry flags.
P.ROSTER_FLAGS = {
    ALIVE = 1,
    LOCAL_RUN = 2, -- protocols 9-12: the client's own AI had been running it (never sent since 13)
}

-- ENEMY_HIT flags.
P.HIT_FLAGS = {
    APPLY = 1,     -- the receiver runs the enemy (the host): run the hit through its game's hit code
    CRITICAL = 2,
    -- 4 was BOUNCE (protocols 9-12: a hit sent back across a change of owner)
    LETHAL = 8,    -- in the sender's game this hit would have killed the enemy
    HAS_UID = 16,
}

-- ENEMY_DEATH flags.
P.DEATH_FLAGS = {
    HAS_UID = 1,
    RESET = 2,      -- the host's world reloaded: every death it reported before is void
    ERASED = 4,     -- the owner removed it without a death (dead in the partner's world before)
    HAS_HIT = 8,    -- the message carries the killing hit
    BY_CLIENT = 16, -- the killing hit was the client's player's (the host ran it)
}

-- Values of a hit (chainsaw.HitController.DamageInfo fields) on the wire: tag of each value.
P.HIT_VALUE = { I32 = 1, F32 = 2, BOOL = 3, VEC3 = 4, U32 = 5, I64 = 6, F64 = 7 }
P.MAX_HIT_FIELDS = 64
P.MAX_ENEMY_LAYERS = 3

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

-- What a CUTSCENE carries: chainsaw.ClapperboardMediator.CameraType of the request.
P.CAMERA = { TIMELINE = 1, MOVIE = 2 }
P.MAX_CUTSCENE_FLAGS = 48  -- start and end flags each (ScenarioFlagManager.FlagInfo group/index pairs)
P.MAX_CUTSCENE_COORDS = 8  -- player placements of a movie (PlayerCoordSetting.Pack)

-- FLAGS entry values.
P.FLAG_VALUE = { OFF = 0, ON = 1, PULSE = 2 } -- PULSE: a trigger-kind variable fired once

-- TRIGGER flags.
P.TRIGGER_FLAGS = {
    ONCE = 1, -- the trigger succeeds once (InteractTrigger.SucceedType.Once): it is done afterwards
    HEAD = 2, -- it was set off by the player's head GameObject (else the body)
}

P.ITEM_FLAGS = {
    HAS_CTX = 1,
    ONLY_INSTANCE = 2, -- the sender's scene had no other copy of this key item
    HAS_STAGE = 4,
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
P.OWNERS_PER_MESSAGE = 95 -- 2 B + 95 * 12 B
P.ROSTER_PER_MESSAGE = 160 -- 11 B + 160 * 7 B
P.ANIMALS_PER_MESSAGE = 23 -- 12 B header + 23 * 49 B entries < 1188 B
P.FLAGS_PER_MESSAGE = 64
P.OBJECTS_PER_MESSAGE = 50 -- 2 B + 50 * 21 B
P.GRAVE_PER_MESSAGE = 290 -- 5 B header + 290 * 4 B uids

-- ENEMY_STATE entry: net id, epoch, flags, uid (ContextID code), kind hash, position, packed
-- rotation, velocity (cm/s), HP, max HP, hit ack, partner info (P.PARTNER_INFO), the finisher
-- type the enemy offers the client (PlayerDefine.FatalType), layer count; then the spawn
-- position (flag HAS_SPAWN) and per animation layer: motion bank, motion id, frame, speed.
local ENEMY_STATE_ENTRY = "<I2BI2I4I4fffI4hhhffI2BBB"
local ENEMY_LAYER = "<I4I4ff"
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

-------------------------------------------------------------------------------
-- Enemies (protocol 13). The host's game runs every enemy and sends its whole state
-- (ENEMY_STATE); the client's game shows them. Hits the client's player lands travel to the
-- host (ENEMY_HIT) and are run through the host's own hit code, as are its finishers
-- (ENEMY_FATAL); the host announces each death (ENEMY_DEATH) with the killing hit. The host
-- numbers its enemies (ENEMY_OWNER) and learns which ones the client has (ENEMY_ROSTER). The
-- host's enemies see, hear and attack the client's character in the host's game; the hits it
-- takes there travel to the client (PLAYER_DAMAGE). See enemy_net.lua and partner_target.lua.
-------------------------------------------------------------------------------

-- Velocity in cm/s as int16 (+-327 m/s).
local function cms(v)
    return clamp_i16((v or 0) * 100.0)
end

-- A hit's values: { {h = FNV-1a of the DamageInfo field name, t = P.HIT_VALUE.*, v = value}, ... }
-- (VEC3 values are {x,y,z}). Values with an unknown tag are skipped.
local HIT_VALUE_FORMAT = { [1] = "<i4", [2] = "<f", [5] = "<I4", [6] = "<i8", [7] = "<d" }

local function pack_hit_fields(fields)
    local V = P.HIT_VALUE
    local parts, n = {}, 0
    for _, f in ipairs(fields or {}) do
        if n >= P.MAX_HIT_FIELDS then break end
        local h, t, v = clamp_u32(f.h), f.t, f.v
        local packed
        if t == V.VEC3 and type(v) == "table" then
            packed = string.pack("<I4Bfff", h, t, tonumber(v.x) or 0, tonumber(v.y) or 0, tonumber(v.z) or 0)
        elseif t == V.BOOL then
            packed = string.pack("<I4BB", h, t, v and 1 or 0)
        elseif t == V.I32 then
            packed = string.pack("<I4Bi4", h, t, clamp_i32(v))
        elseif t == V.U32 then
            packed = string.pack("<I4BI4", h, t, clamp_u32(v))
        elseif t == V.I64 then
            packed = string.pack("<I4Bi8", h, t, math.tointeger(v) or 0)
        elseif t == V.F32 or t == V.F64 then
            packed = string.pack(t == V.F32 and "<I4Bf" or "<I4Bd", h, t, tonumber(v) or 0)
        end
        if packed ~= nil then
            n = n + 1
            parts[n] = packed
        end
    end
    return string.pack("<B", n) .. table.concat(parts)
end

local function unpack_hit_fields(data, off)
    local V = P.HIT_VALUE
    local n
    n, off = string.unpack("<B", data, off)
    local fields = {}
    for i = 1, n do
        local h, t, v
        h, t, off = string.unpack("<I4B", data, off)
        if t == V.VEC3 then
            local x, y, z
            x, y, z, off = string.unpack("<fff", data, off)
            v = { x = x, y = y, z = z }
        elseif t == V.BOOL then
            local b
            b, off = string.unpack("<B", data, off)
            v = b ~= 0
        elseif HIT_VALUE_FORMAT[t] ~= nil then
            v, off = string.unpack(HIT_VALUE_FORMAT[t], data, off)
        else
            error("bad hit value tag")
        end
        fields[i] = { h = h, t = t, v = v }
    end
    return fields, off
end

-- The state of the host's enemies. entry = { net_id, epoch, uid, kind_hash, pos={x,y,z},
-- rot={x,y,z,w}, vel={x,y,z}|nil, hp, max_hp, alive, hidden, spawn={x,y,z}|nil (sent only for
-- enemies without a uid), ack (the last of the receiver's hits applied to this enemy), pinfo
-- (P.PARTNER_INFO bits), ftype (the finisher type it offers the client), layers = { {bank, id,
-- frame, speed}, ... } (at most P.MAX_ENEMY_LAYERS) }.
-- Entries are packed into as few messages as fit the payload; returns an array of strings with
-- at least one message (an empty one says "I own nothing right now").
local STATE_HEADER = "<BdBBB" -- type, time, chunk, chunks, count
local STATE_HEADER_SIZE = 12
function P.encode_enemy_states(time, entries)
    local F = P.ENEMY_STATE_FLAGS
    local packed = {}
    for _, e in ipairs(entries) do
        local uid = uid_or_zero(e.uid)
        local flags = 0
        if e.alive ~= false then flags = flags | F.ALIVE end
        if uid ~= 0 then flags = flags | F.HAS_UID end
        if e.hidden then flags = flags | F.HIDDEN end
        local spawn = uid == 0 and (e.spawn or e.pos) or nil
        if spawn ~= nil then flags = flags | F.HAS_SPAWN end
        local layers = e.layers or {}
        local nl = math.min(#layers, P.MAX_ENEMY_LAYERS)
        local vel = e.vel or { x = 0, y = 0, z = 0 }
        local parts = { string.pack(ENEMY_STATE_ENTRY, (e.net_id or 0) & 0xFFFF, (e.epoch or 0) & 0xFF, flags, uid,
            clamp_u32(e.kind_hash), e.pos.x, e.pos.y, e.pos.z, pack_rot(e.rot), cms(vel.x), cms(vel.y), cms(vel.z),
            e.hp or 0, e.max_hp or 0, (e.ack or 0) & 0xFFFF, (e.pinfo or 0) & 0xFF, (e.ftype or 0) & 0xFF, nl) }
        if spawn ~= nil then parts[#parts + 1] = string.pack("<fff", spawn.x, spawn.y, spawn.z) end
        for i = 1, nl do
            local l = layers[i]
            parts[#parts + 1] = string.pack(ENEMY_LAYER, clamp_u32(l.bank), clamp_u32(l.id), l.frame or 0, l.speed or 1)
        end
        packed[#packed + 1] = table.concat(parts)
    end
    local groups, cur, size = {}, {}, STATE_HEADER_SIZE
    for _, p in ipairs(packed) do
        if #cur > 0 and (size + #p > P.MAX_PAYLOAD or #cur >= 255) then
            groups[#groups + 1] = cur
            cur, size = {}, STATE_HEADER_SIZE
        end
        cur[#cur + 1] = p
        size = size + #p
    end
    groups[#groups + 1] = cur
    local out = {}
    local chunks = math.min(255, #groups)
    for c = 1, chunks do
        local g = groups[c]
        out[c] = string.pack(STATE_HEADER, P.T.ENEMY_STATE, time or 0, c, chunks, #g) .. table.concat(g)
    end
    return out
end

-- A hit the sender's player landed on an enemy. m = { net_id (0 = not paired), epoch, flags
-- (P.HIT_FLAGS: APPLY, LETHAL), critical, uid, kind_hash, pos={x,y,z} (the enemy's
-- identity position: its spawn point without a uid), damage, hp (the enemy's HP in the
-- sender's game before the hit), seq (the sender's hit counter), fields (the DamageInfo values) }
local ENEMY_HIT_HEADER = "<BI2BBI4I4fffffI2"
function P.encode_enemy_hit(m)
    local uid = uid_or_zero(m.uid)
    local flags = (m.flags or 0) & ~P.HIT_FLAGS.HAS_UID
    if uid ~= 0 then flags = flags | P.HIT_FLAGS.HAS_UID end
    if m.critical then flags = flags | P.HIT_FLAGS.CRITICAL end
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    return string.pack(ENEMY_HIT_HEADER, P.T.ENEMY_HIT, (m.net_id or 0) & 0xFFFF, (m.epoch or 0) & 0xFF, flags & 0xFF,
        uid, clamp_u32(m.kind_hash), pos.x, pos.y, pos.z, m.damage or 0, m.hp or 0, (m.seq or 0) & 0xFFFF)
        .. pack_hit_fields(m.fields)
end

-- An enemy of the host's died (or was erased). m = { net_id, epoch, flags (P.DEATH_FLAGS:
-- ERASED, BY_CLIENT), uid, kind_hash, pos={x,y,z} and rot={x,y,z,w} where it died, fields (the
-- killing hit, optional) }.
local ENEMY_DEATH_HEADER = "<BI2BBI4I4fffI4"
function P.encode_enemy_death(m)
    local F = P.DEATH_FLAGS
    local uid = uid_or_zero(m.uid)
    local flags = (m.flags or 0) & ~(F.HAS_UID | F.HAS_HIT)
    if uid ~= 0 then flags = flags | F.HAS_UID end
    if m.fields ~= nil and #m.fields > 0 then flags = flags | F.HAS_HIT end
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    return string.pack(ENEMY_DEATH_HEADER, P.T.ENEMY_DEATH, (m.net_id or 0) & 0xFFFF, (m.epoch or 0) & 0xFF,
        flags & 0xFF, uid, clamp_u32(m.kind_hash), pos.x, pos.y, pos.z, pack_rot(m.rot))
        .. pack_hit_fields((flags & F.HAS_HIT) ~= 0 and m.fields or nil)
end

-- The host's world reloaded (checkpoint): every death it reported before is void.
function P.encode_enemy_reset()
    return P.encode_enemy_death({ net_id = 0, flags = P.DEATH_FLAGS.RESET })
end

-- Host -> client: owners = { {net_id, epoch, owner = P.OWNER.*, uid, hp}, ... } (hp: the
-- host's HP of the enemy when it changed hands, 0 = none). Returns an array of strings (empty
-- for an empty list).
function P.encode_enemy_owners(owners)
    local out = {}
    local per = P.OWNERS_PER_MESSAGE
    for first = 1, #owners, per do
        local last = math.min(#owners, first + per - 1)
        local parts = { string.pack("<BB", P.T.ENEMY_OWNER, last - first + 1) }
        for i = first, last do
            local o = owners[i]
            parts[#parts + 1] = string.pack("<I2BBI4f", (o.net_id or 0) & 0xFFFF, (o.epoch or 0) & 0xFF,
                (o.owner or 0) & 0xFF, uid_or_zero(o.uid), o.hp or 0)
        end
        out[#out + 1] = table.concat(parts)
    end
    return out
end

-- Client -> host: the host enemies the client has a copy of. entries = { {net_id, flags
-- (P.ROSTER_FLAGS), hp}, ... }. Returns an array of strings, at least one.
function P.encode_enemy_roster(time, entries)
    local out = {}
    local per = P.ROSTER_PER_MESSAGE
    local first = 1
    repeat
        local last = math.min(#entries, first + per - 1)
        local parts = { string.pack("<BdI2", P.T.ENEMY_ROSTER, time or 0, math.max(0, last - first + 1)) }
        for i = first, last do
            local e = entries[i]
            parts[#parts + 1] = string.pack("<I2Bf", (e.net_id or 0) & 0xFFFF, (e.flags or 0) & 0xFF, e.hp or 0)
        end
        out[#out + 1] = table.concat(parts)
        first = last + 1
    until first > #entries
    return out
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

-- flags = { {guid="xxxxxxxx-....", value=bool, pulse=bool|nil}, ... } -> array of messages
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
                local v = flags[k].pulse and P.FLAG_VALUE.PULSE or (flags[k].value and P.FLAG_VALUE.ON or P.FLAG_VALUE.OFF)
                parts[#parts + 1] = b .. string.pack("<B", v)
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

-- A cutscene request as the game itself describes it for a remote player
-- (chainsaw.ClapperboardMediator.PayloadPlay), plus where the sender was:
-- m = { camera (P.CAMERA), id, screen, owner_code (u32; 0xFFFFFFFF none), end_portrayal (u32),
--       start_flags = { {group, index}, ... }, end_flags = {...},
--       coords = { {kind, pos={x,y,z}, rot_y, reset_camera, only_npc, only_pc}, ... } (movies),
--       chapter, stage, pos={x,y,z}|nil, flags }
local CUTSCENE_HEAD = "<BBi4i4I4I4i4i4fffB"
local COORD = "<i4ffffBBB"

local function pack_flag_infos(list)
    local n = math.min(#(list or {}), P.MAX_CUTSCENE_FLAGS)
    local parts = { string.pack("<B", n) }
    for i = 1, n do
        parts[#parts + 1] = string.pack("<i4i4", clamp_i32(list[i].group), clamp_i32(list[i].index))
    end
    return table.concat(parts)
end

local function unpack_flag_infos(data, off)
    local n
    n, off = string.unpack("<B", data, off)
    local list = {}
    for i = 1, n do
        local g, idx
        g, idx, off = string.unpack("<i4i4", data, off)
        list[i] = { group = g, index = idx }
    end
    return list, off
end

function P.encode_cutscene(m)
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    local parts = {
        string.pack(CUTSCENE_HEAD, P.T.CUTSCENE, (m.camera or P.CAMERA.TIMELINE) & 0xFF, clamp_i32(m.id),
            clamp_i32(m.screen or 0), clamp_u32(m.owner_code or 0xFFFFFFFF), clamp_u32(m.end_portrayal or 0),
            clamp_i32(m.chapter or -1), clamp_i32(m.stage or -1), pos.x, pos.y, pos.z, m.flags or 0),
        pack_flag_infos(m.start_flags),
        pack_flag_infos(m.end_flags),
    }
    local coords = m.coords or {}
    local nc = math.min(#coords, P.MAX_CUTSCENE_COORDS)
    parts[#parts + 1] = string.pack("<B", nc)
    for i = 1, nc do
        local c = coords[i]
        local p = c.pos or { x = 0, y = 0, z = 0 }
        parts[#parts + 1] = string.pack(COORD, clamp_i32(c.kind), p.x, p.y, p.z, c.rot_y or 0,
            c.reset_camera and 1 or 0, c.only_npc and 1 or 0, c.only_pc and 1 or 0)
    end
    return table.concat(parts)
end

-- m = { guid (the trigger's GameObject), hash (InteractTrigger.get_Hash), trigger_type, once, head,
--       chapter, stage, pos={x,y,z}|nil }
local TRIGGER_FMT = "<Bc16I4BBi4i4fff"

function P.encode_trigger(m)
    local b = P.guid_to_bytes(m.guid)
    if b == nil then return nil end
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    local flags = 0
    if m.once then flags = flags | P.TRIGGER_FLAGS.ONCE end
    if m.head then flags = flags | P.TRIGGER_FLAGS.HEAD end
    return string.pack(TRIGGER_FMT, P.T.TRIGGER, b, clamp_u32(m.hash), (m.trigger_type or 0) & 0xFF, flags,
        clamp_i32(m.chapter or -1), clamp_i32(m.stage or -1), pos.x, pos.y, pos.z)
end

-- m = { seq, item_id (chainsaw.ItemID), count, durability (-1 = none) }
function P.encode_item_give(m)
    return string.pack("<BI4I4i4i4", P.T.ITEM_GIVE, clamp_u32(m.seq), clamp_u32(m.item_id), clamp_i32(m.count or 1),
        clamp_i32(m.durability or -1))
end

-- m = { seq, returned }
function P.encode_item_give_result(m)
    return string.pack("<BI4i4", P.T.ITEM_GIVE_RESULT, clamp_u32(m.seq), clamp_i32(m.returned or 0))
end

-- Client -> host: the client's player started a finisher on a host enemy. m = { net_id, epoch,
-- uid, kind_hash, kind (P.FATAL_KIND), ftype (the PlayerDefine.FatalType of a NORMAL one), pos
-- and yaw of the client's player }.
local ENEMY_FATAL_FORMAT = "<BI2BI4I4Bi4ffff"
function P.encode_enemy_fatal(m)
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    return string.pack(ENEMY_FATAL_FORMAT, P.T.ENEMY_FATAL, (m.net_id or 0) & 0xFFFF, (m.epoch or 0) & 0xFF,
        uid_or_zero(m.uid), clamp_u32(m.kind_hash), (m.kind or 0) & 0xFF, clamp_i32(m.ftype or 0),
        pos.x, pos.y, pos.z, m.yaw or 0)
end

-- Client -> host: noises the client's player made (each a chainsaw.SoundDetectionInfo as the
-- client's game registered it). noises = { {pos={x,y,z}, radius, height, volume, sub (volume
-- lost per second)}, ... } (at most P.MAX_NOISES are sent).
function P.encode_player_noise(noises)
    local n = math.min(#noises, P.MAX_NOISES)
    local parts = { string.pack("<BB", P.T.PLAYER_NOISE, n) }
    for i = 1, n do
        local s = noises[i]
        local pos = s.pos or { x = 0, y = 0, z = 0 }
        parts[#parts + 1] = string.pack("<fffffff", pos.x, pos.y, pos.z, s.radius or 0, s.height or 0,
            s.volume or 0, s.sub or 0)
    end
    return table.concat(parts)
end

-- Host -> client: a hit the client's character took in the host's game (an enemy's attack, an
-- explosion...). m = { seq, net_id (the attacking enemy, 0 = none), uid, kind_hash, from_enemy,
-- attack_id (AttackUserData._AttackHitDataID), key_hash (AttackUserData._KeyNameHash), fields
-- (the hit's DamageInfo, AttackData and body part values, as in ENEMY_HIT) }.
-- grab: the attack is a grab (its GrappleUserData._GrapplePriority in grab_priority).
local PLAYER_DAMAGE_HEADER = "<BI2I2BI4I4i4I4i4"
function P.encode_player_damage(m)
    local F = P.PLAYER_DAMAGE_FLAGS
    local uid = uid_or_zero(m.uid)
    local flags = 0
    if uid ~= 0 then flags = flags | F.HAS_UID end
    if m.from_enemy then flags = flags | F.FROM_ENEMY end
    if m.grab then flags = flags | F.GRAB end
    return string.pack(PLAYER_DAMAGE_HEADER, P.T.PLAYER_DAMAGE, (m.seq or 0) & 0xFFFF, (m.net_id or 0) & 0xFFFF,
        flags, uid, clamp_u32(m.kind_hash), clamp_i32(m.attack_id or -1), clamp_u32(m.key_hash),
        clamp_i32(m.grab_priority or 0)) .. pack_hit_fields(m.fields)
end

-- Host -> client: one of our enemies' attacks warns the client's character (what
-- EnemyActionSignUtility.sendActionSignInfo hands a player's head: chainsaw.ActionSignHitInfo).
-- Sent every frame the warning lasts. m = { net_id, uid, kind_hash, sign_type (ActionSignType),
-- button (ActionSignButton), just, act, angle_check }
local ACTION_SIGN_FORMAT = "<BI2BI4I4i4i4"
function P.encode_action_sign(m)
    local F = P.ACTION_SIGN_FLAGS
    local uid = uid_or_zero(m.uid)
    local flags = 0
    if m.just then flags = flags | F.JUST end
    if m.act then flags = flags | F.ACT end
    if m.angle_check then flags = flags | F.ANGLE_CHECK end
    if uid ~= 0 then flags = flags | F.HAS_UID end
    return string.pack(ACTION_SIGN_FORMAT, P.T.ACTION_SIGN, (m.net_id or 0) & 0xFFFF, flags, uid,
        clamp_u32(m.kind_hash), clamp_i32(m.sign_type or 0), clamp_i32(m.button or 0))
end

-- Client -> host: the client's player parried a host enemy's attack. m = { net_id, uid,
-- kind_hash, kind (P.PARRY_KIND), sign_type }
local ENEMY_PARRY_FORMAT = "<BI2I4I4Bi4"
function P.encode_enemy_parry(m)
    return string.pack(ENEMY_PARRY_FORMAT, P.T.ENEMY_PARRY, (m.net_id or 0) & 0xFFFF, uid_or_zero(m.uid),
        clamp_u32(m.kind_hash), (m.kind or P.PARRY_KIND.PARRY) & 0xFF, clamp_i32(m.sign_type or 0))
end

-- Host -> client: our enemy holds the client's character (held = true) or let go. m = { net_id,
-- uid, kind_hash, held, struggles (presses that break free; 0 = the mod's default), knife (a
-- knife may break free), action (the grab's action hash, EnemyHeadUpdater.requestGrapple) }
local PLAYER_GRAB_FORMAT = "<BI2I4I4BBBI4"
function P.encode_player_grab(m)
    return string.pack(PLAYER_GRAB_FORMAT, P.T.PLAYER_GRAB, (m.net_id or 0) & 0xFFFF, uid_or_zero(m.uid),
        clamp_u32(m.kind_hash), m.held and 1 or 0, math.max(0, math.min(255, math.floor(m.struggles or 0))),
        m.knife and 1 or 0, clamp_u32(m.action))
end

-- Client -> host: the client's player broke free of the host enemy's hold. m = { net_id, uid,
-- kind_hash, how (P.ESCAPE_KIND) }
local GRAB_ESCAPE_FORMAT = "<BI2I4I4B"
function P.encode_grab_escape(m)
    return string.pack(GRAB_ESCAPE_FORMAT, P.T.GRAB_ESCAPE, (m.net_id or 0) & 0xFFFF, uid_or_zero(m.uid),
        clamp_u32(m.kind_hash), (m.how or P.ESCAPE_KIND.MASH) & 0xFF)
end

-- m = { rev, file, mode, chapter, difficulty, options, save_chapter, save_difficulty, save_count, save_empty }
-- file: the host's co-op save file (1-3); chapter: 1-16 (0 = where the save is); difficulty:
-- chainsaw.CampaignManager.Difficulty (10-40); options: bits of Lobby.OPTIONS; save_*: what the
-- chosen file holds (save_chapter is a chainsaw.ChapterID, 0 when empty).
local LOBBY_SETTINGS_FORMAT = "<BI2BBBBI2i4BI2B"
function P.encode_lobby_settings(m)
    return string.pack(LOBBY_SETTINGS_FORMAT, P.T.LOBBY_SETTINGS, (m.rev or 0) & 0xFFFF, (m.file or 1) & 0xFF,
        (m.mode or P.LOBBY_MODE.NEW) & 0xFF, (m.chapter or 0) & 0xFF, (m.difficulty or 20) & 0xFF,
        (m.options or 0) & 0xFFFF, clamp_i32(m.save_chapter or 0), (m.save_difficulty or 0) & 0xFF,
        math.max(0, math.min(0xFFFF, math.floor(m.save_count or 0))), m.save_empty == false and 0 or 1)
end

-- m = { in_lobby, ready, loadout, name }
function P.encode_lobby_player(m)
    return string.pack("<BBBBs1", P.T.LOBBY_PLAYER, m.in_lobby and 1 or 0, m.ready and 1 or 0,
        (m.loadout or 0) & 0xFF, (m.name or ""):sub(1, 64))
end

-- m = { start_id, mode, file, chapter, difficulty, key, chapter_id }
-- key: the chainsaw.CampaignInitialSettingKey a new game starts from; chapter_id: the
-- chainsaw.ChapterID both games play (the chosen chapter, or the one the host's save is in).
local LOBBY_START_FORMAT = "<BI2BBBBi4i4"
function P.encode_lobby_start(m)
    return string.pack(LOBBY_START_FORMAT, P.T.LOBBY_START, (m.start_id or 0) & 0xFFFF,
        (m.mode or P.LOBBY_MODE.NEW) & 0xFF, (m.file or 1) & 0xFF, (m.chapter or 0) & 0xFF,
        (m.difficulty or 20) & 0xFF, clamp_i32(m.key or 0), clamp_i32(m.chapter_id or 0))
end

-- m = { start_id, phase (P.LOAD_PHASE), progress (0-100) }
function P.encode_load_state(m)
    return string.pack("<BI2BB", P.T.LOAD_STATE, (m.start_id or 0) & 0xFFFF, (m.phase or 0) & 0xFF,
        math.max(0, math.min(100, math.floor(m.progress or 0))))
end

function P.encode_load_go(m)
    return string.pack("<BI2", P.T.LOAD_GO, (m.start_id or 0) & 0xFFFF)
end

-- The sender's game saved (P.SAVE_KIND): the receiver's game saves too. m = { kind }
function P.encode_save(m)
    return string.pack("<BB", P.T.SAVE, (m.kind or P.SAVE_KIND.AUTO) & 0xFF)
end

-- mechs = { {guid, kind, key}, ... } -> array of messages
function P.encode_mechanisms(mechs)
    local out = {}
    local i = 1
    while i <= #mechs do
        local last = math.min(#mechs, i + P.MAX_MECHS_PER_MESSAGE - 1)
        local parts, n = {}, 0
        for k = i, last do
            local m = mechs[k]
            local b = P.guid_to_bytes(m.guid)
            if b ~= nil then
                parts[#parts + 1] = b .. string.pack("<BI4", (m.kind or 0) & 0xFF, (m.key or 0) & 0xFFFFFFFF)
                n = n + 1
            end
        end
        if n > 0 then out[#out + 1] = string.pack("<BB", P.T.MECHANISMS, n) .. table.concat(parts) end
        i = last + 1
    end
    return out
end

-- Ashley's state (ashley_sync.lua). m = { time, epoch, flags (P.ASHLEY_FLAGS; OWNER is set from
-- m.owner), pos, rot, hp, max_hp, bank_type (her motion's TargetBankType), layers = { {bank, id,
-- frame, speed, blend, mask, mode}, ... } } (layers and the full state only from the owner). Per
-- layer, besides the motion: its blend rate, joint mask and blend mode (her upper-body and
-- action layers are mixed in with them).
P.MAX_ASHLEY_LAYERS = 8
local ASHLEY_FORMAT = "<BdBBfffI4i4i4I4B"
local ASHLEY_LAYER = "<I4I4fffI4B"
function P.encode_ashley(m)
    local pos = m.pos or { x = 0, y = 0, z = 0 }
    local layers = m.layers or {}
    local nl = math.min(#layers, P.MAX_ASHLEY_LAYERS)
    local parts = { string.pack(ASHLEY_FORMAT, P.T.ASHLEY, m.time or 0, (m.epoch or 0) & 0xFF, (m.flags or 0) & 0xFF,
        pos.x, pos.y, pos.z, pack_rot(m.rot), clamp_i32(m.hp), clamp_i32(m.max_hp), clamp_u32(m.bank_type), nl) }
    for i = 1, nl do
        local l = layers[i]
        parts[#parts + 1] = string.pack(ASHLEY_LAYER, clamp_u32(l.bank), clamp_u32(l.id), l.frame or 0, l.speed or 1,
            l.blend or -1, clamp_u32(l.mask or 0xFFFFFFFF), (l.mode or 0xFF) & 0xFF)
    end
    return table.concat(parts)
end

-- The owner -> the other game: the dynamic motion banks Ashley's motion has (via.motion.
-- DynamicMotionBank: a motlist and the bank it stands for), so a puppet can play every motion
-- hers can. m = { epoch, banks = { { path, bank_id, bank_type, mask_bit, order, flags }, ... } }
-- (flags: 1 OverwriteBankID, 2 OverwriteBankType, 4 OverwriteBankTypeMaskBit). Sent whole; it
-- may need fragments (Session.send_large).
P.MAX_ASHLEY_BANKS = 64
local ASHLEY_BANK = "<I4I4I4i4Bs2"
function P.encode_ashley_banks(m)
    local banks = m.banks or {}
    local n = math.min(#banks, P.MAX_ASHLEY_BANKS)
    local parts = { string.pack("<BBB", P.T.ASHLEY_BANKS, (m.epoch or 0) & 0xFF, n) }
    for i = 1, n do
        local b = banks[i]
        parts[#parts + 1] = string.pack(ASHLEY_BANK, clamp_u32(b.bank_id), clamp_u32(b.bank_type), clamp_u32(b.mask_bit),
            clamp_i32(b.order), (b.flags or 0) & 0xFF, (b.path or ""):sub(1, 1024))
    end
    return table.concat(parts)
end

-- Host -> client: Ashley is run by `owner` (P.OWNER.HOST/CLIENT) since ownership epoch `epoch`;
-- `cooldown`: seconds until she may switch again; `reason`: P.ASHLEY_REASON; `by`: the player
-- who asked (P.OWNER).
function P.encode_ashley_owner(m)
    return string.pack("<BBBfBB", P.T.ASHLEY_OWNER, (m.owner or P.OWNER.HOST) & 0xFF, (m.epoch or 0) & 0xFF,
        m.cooldown or 0, (m.reason or 0) & 0xFF, (m.by or P.OWNER.HOST) & 0xFF)
end

-- Client -> host: switch Ashley over (to the other game than the one running her at `epoch`).
function P.encode_ashley_switch(m)
    return string.pack("<BB", P.T.ASHLEY_SWITCH, (m.epoch or 0) & 0xFF)
end

-- The sender's current objective (chainsaw.gui.PurposeGuiItem). m = { id (PurposeID), priority,
-- message (GUID string), display, delay, mediate }
local PURPOSE_FORMAT = "<BI4i4c16ffB"
function P.encode_purpose(m)
    local g = P.guid_to_bytes(m.message) or string.rep("\0", 16)
    return string.pack(PURPOSE_FORMAT, P.T.PURPOSE, clamp_u32(m.id), clamp_i32(m.priority), g, m.display or 0,
        m.delay or 0, m.mediate and 1 or 0)
end

-- traps = { {guid, kind, event}, ... } -> array of messages
function P.encode_traps(traps)
    local out = {}
    local i = 1
    while i <= #traps do
        local last = math.min(#traps, i + P.MAX_TRAPS_PER_MESSAGE - 1)
        local parts, n = {}, 0
        for k = i, last do
            local t = traps[k]
            local b = P.guid_to_bytes(t.guid)
            if b ~= nil then
                parts[#parts + 1] = b .. string.pack("<BB", (t.kind or 0) & 0xFF, (t.event or 0) & 0xFF)
                n = n + 1
            end
        end
        if n > 0 then out[#out + 1] = string.pack("<BB", P.T.TRAPS, n) .. table.concat(parts) end
        i = last + 1
    end
    return out
end

-- doors = { {guid, open=bool, hold=bool, attr=byte}, ... } -> array of messages
P.MAX_DOORS_PER_MESSAGE = 60
function P.encode_doors(doors)
    local out = {}
    local i = 1
    while i <= #doors do
        local last = math.min(#doors, i + P.MAX_DOORS_PER_MESSAGE - 1)
        local parts, n = {}, 0
        for k = i, last do
            local d = doors[k]
            local b = P.guid_to_bytes(d.guid)
            if b ~= nil then
                parts[#parts + 1] = b .. string.pack("<BB", (d.open and 1 or 0) | (d.hold and 2 or 0), (d.attr or 0) & 0xFF)
                n = n + 1
            end
        end
        out[#out + 1] = string.pack("<BB", P.T.DOORS, n) .. table.concat(parts)
        i = last + 1
    end
    return out
end

-- m = { camera (P.CAMERA), id }
function P.encode_cutscene_skip(m)
    return string.pack("<BBi4", P.T.CUTSCENE_SKIP, (m.camera or P.CAMERA.TIMELINE) & 0xFF, clamp_i32(m.id))
end

function P.encode_world_request(sync_id, what)
    return string.pack("<BI2B", P.T.WORLD_REQUEST, (sync_id or 0) & 0xFFFF, what or 0)
end

function P.encode_world_done(sync_id, what, n_flag_groups, n_gimmicks)
    return string.pack("<BI2BI4I4", P.T.WORLD_DONE, (sync_id or 0) & 0xFFFF, what or 0,
        clamp_u32(n_flag_groups), clamp_u32(n_gimmicks))
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

-- m = { net_id (host's enemy), item_id, count, pos={x,y,z}, stage }
local ITEM_DROPPED = "<BI2I4i4fffi4B"
function P.encode_item_dropped(m)
    local stage, has_stage = opt_i32(m.stage)
    local count = opt_i32(m.count)
    return string.pack(ITEM_DROPPED, P.T.ITEM_DROPPED, m.net_id or 0, m.item_id or 0, count,
        m.pos.x, m.pos.y, m.pos.z, stage, has_stage and P.DROP_FLAGS.HAS_STAGE or 0)
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

decoders[P.T.ENEMY_STATE] = function(data)
    local _, time, chunk, chunks, count, off = string.unpack("<BdBBB", data)
    if chunk < 1 or chunk > chunks then error("bad chunk") end
    local F = P.ENEMY_STATE_FLAGS
    local m = { time = time, chunk = chunk, chunks = chunks, enemies = {} }
    for i = 1, count do
        local net_id, epoch, flags, uid, kind_hash, x, y, z, rot, vx, vy, vz, hp, max_hp, ack, pinfo, ftype, nl
        net_id, epoch, flags, uid, kind_hash, x, y, z, rot, vx, vy, vz, hp, max_hp, ack, pinfo, ftype, nl, off =
            string.unpack(ENEMY_STATE_ENTRY, data, off)
        if nl > P.MAX_ENEMY_LAYERS then error("too many layers") end
        local e = {
            net_id = net_id, epoch = epoch, flags = flags, kind_hash = kind_hash,
            uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
            pos = { x = x, y = y, z = z }, rot = unpack_rot(rot),
            vel = { x = vx / 100.0, y = vy / 100.0, z = vz / 100.0 },
            hp = hp, max_hp = max_hp, ack = ack, pinfo = pinfo, ftype = ftype,
            alive = (flags & F.ALIVE) ~= 0, hidden = (flags & F.HIDDEN) ~= 0,
            layers = {},
        }
        if (flags & F.HAS_SPAWN) ~= 0 then
            local sx, sy, sz
            sx, sy, sz, off = string.unpack("<fff", data, off)
            e.spawn = { x = sx, y = sy, z = sz }
        end
        for l = 1, nl do
            local bank, id, frame, speed
            bank, id, frame, speed, off = string.unpack(ENEMY_LAYER, data, off)
            e.layers[l] = { bank = bank, id = id, frame = frame, speed = speed }
        end
        m.enemies[i] = e
    end
    return m
end

decoders[P.T.ENEMY_HIT] = function(data)
    local _, net_id, epoch, flags, uid, kind_hash, x, y, z, damage, hp, seq, off = string.unpack(ENEMY_HIT_HEADER, data)
    local F = P.HIT_FLAGS
    local fields = unpack_hit_fields(data, off)
    return {
        net_id = net_id, epoch = epoch, flags = flags, kind_hash = kind_hash,
        uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
        pos = { x = x, y = y, z = z }, damage = damage, hp = hp, seq = seq, fields = fields,
        apply = (flags & F.APPLY) ~= 0, lethal = (flags & F.LETHAL) ~= 0,
        critical = (flags & F.CRITICAL) ~= 0,
    }
end

decoders[P.T.ENEMY_DEATH] = function(data)
    local _, net_id, epoch, flags, uid, kind_hash, x, y, z, rot, off = string.unpack(ENEMY_DEATH_HEADER, data)
    local F = P.DEATH_FLAGS
    local fields = unpack_hit_fields(data, off)
    return {
        net_id = net_id, epoch = epoch, flags = flags, kind_hash = kind_hash,
        uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil,
        pos = { x = x, y = y, z = z }, rot = unpack_rot(rot),
        fields = (flags & F.HAS_HIT) ~= 0 and fields or nil,
        reset = (flags & F.RESET) ~= 0, erased = (flags & F.ERASED) ~= 0, by_client = (flags & F.BY_CLIENT) ~= 0,
    }
end

decoders[P.T.ENEMY_OWNER] = function(data)
    local _, n, off = string.unpack("<BB", data)
    local owners = {}
    for i = 1, n do
        local net_id, epoch, owner, uid, hp
        net_id, epoch, owner, uid, hp, off = string.unpack("<I2BBI4f", data, off)
        owners[i] = { net_id = net_id, epoch = epoch, owner = owner, uid = uid ~= 0 and uid or nil,
            hp = hp > 0 and hp or nil }
    end
    return { owners = owners }
end

decoders[P.T.ENEMY_ROSTER] = function(data)
    local _, time, n, off = string.unpack("<BdI2", data)
    local entries = {}
    for i = 1, n do
        local net_id, flags, hp
        net_id, flags, hp, off = string.unpack("<I2Bf", data, off)
        entries[i] = { net_id = net_id, flags = flags, hp = hp,
            alive = (flags & P.ROSTER_FLAGS.ALIVE) ~= 0, local_run = (flags & P.ROSTER_FLAGS.LOCAL_RUN) ~= 0 }
    end
    return { time = time, entries = entries }
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
        flags[i] = { guid = guid, value = value ~= P.FLAG_VALUE.OFF, pulse = value == P.FLAG_VALUE.PULSE }
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
    local _, camera, id, screen, owner_code, end_portrayal, chapter, stage, x, y, z, flags, off =
        string.unpack(CUTSCENE_HEAD, data)
    local m = { camera = camera, id = id, screen = screen, owner_code = owner_code, end_portrayal = end_portrayal,
        chapter = chapter, stage = stage, pos = { x = x, y = y, z = z }, flags = flags }
    m.start_flags, off = unpack_flag_infos(data, off)
    m.end_flags, off = unpack_flag_infos(data, off)
    local nc
    nc, off = string.unpack("<B", data, off)
    m.coords = {}
    for i = 1, nc do
        local kind, cx, cy, cz, rot_y, reset, only_npc, only_pc
        kind, cx, cy, cz, rot_y, reset, only_npc, only_pc, off = string.unpack(COORD, data, off)
        m.coords[i] = { kind = kind, pos = { x = cx, y = cy, z = cz }, rot_y = rot_y, reset_camera = reset ~= 0,
            only_npc = only_npc ~= 0, only_pc = only_pc ~= 0 }
    end
    return m
end

decoders[P.T.TRIGGER] = function(data)
    local _, b, hash, trigger_type, flags, chapter, stage, x, y, z = string.unpack(TRIGGER_FMT, data)
    local F = P.TRIGGER_FLAGS
    return { guid = P.guid_from_bytes(b), hash = hash, trigger_type = trigger_type,
        once = (flags & F.ONCE) ~= 0, head = (flags & F.HEAD) ~= 0,
        chapter = chapter, stage = stage, pos = { x = x, y = y, z = z } }
end

decoders[P.T.ITEM_GIVE] = function(data)
    local _, seq, item_id, count, durability = string.unpack("<BI4I4i4i4", data)
    return { seq = seq, item_id = item_id, count = count, durability = durability }
end

decoders[P.T.ENEMY_FATAL] = function(data)
    local _, net_id, epoch, uid, kind_hash, kind, ftype, x, y, z, yaw = string.unpack(ENEMY_FATAL_FORMAT, data)
    return { net_id = net_id, epoch = epoch, uid = uid ~= 0 and uid or nil, kind_hash = kind_hash, kind = kind,
        ftype = ftype, pos = { x = x, y = y, z = z }, yaw = yaw }
end

decoders[P.T.PLAYER_NOISE] = function(data)
    local _, n, off = string.unpack("<BB", data)
    if n > P.MAX_NOISES then error("too many noises") end
    local noises = {}
    for i = 1, n do
        local x, y, z, radius, height, volume, sub
        x, y, z, radius, height, volume, sub, off = string.unpack("<fffffff", data, off)
        noises[i] = { pos = { x = x, y = y, z = z }, radius = radius, height = height, volume = volume, sub = sub }
    end
    return { noises = noises }
end

decoders[P.T.PLAYER_DAMAGE] = function(data)
    local _, seq, net_id, flags, uid, kind_hash, attack_id, key_hash, grab_priority, off =
        string.unpack(PLAYER_DAMAGE_HEADER, data)
    local F = P.PLAYER_DAMAGE_FLAGS
    return { seq = seq, net_id = net_id, flags = flags, kind_hash = kind_hash,
        uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil, from_enemy = (flags & F.FROM_ENEMY) ~= 0,
        grab = (flags & F.GRAB) ~= 0, grab_priority = grab_priority,
        attack_id = attack_id, key_hash = key_hash, fields = (unpack_hit_fields(data, off)) }
end

decoders[P.T.ACTION_SIGN] = function(data)
    local _, net_id, flags, uid, kind_hash, sign_type, button = string.unpack(ACTION_SIGN_FORMAT, data)
    local F = P.ACTION_SIGN_FLAGS
    return { net_id = net_id, uid = ((flags & F.HAS_UID) ~= 0 and uid ~= 0) and uid or nil, kind_hash = kind_hash,
        sign_type = sign_type, button = button, just = (flags & F.JUST) ~= 0, act = (flags & F.ACT) ~= 0,
        angle_check = (flags & F.ANGLE_CHECK) ~= 0 }
end

decoders[P.T.ENEMY_PARRY] = function(data)
    local _, net_id, uid, kind_hash, kind, sign_type = string.unpack(ENEMY_PARRY_FORMAT, data)
    return { net_id = net_id, uid = uid ~= 0 and uid or nil, kind_hash = kind_hash, kind = kind,
        sign_type = sign_type }
end

decoders[P.T.PLAYER_GRAB] = function(data)
    local _, net_id, uid, kind_hash, held, struggles, knife, action = string.unpack(PLAYER_GRAB_FORMAT, data)
    return { net_id = net_id, uid = uid ~= 0 and uid or nil, kind_hash = kind_hash, held = held ~= 0,
        struggles = struggles, knife = knife ~= 0, action = action }
end

decoders[P.T.LOBBY_SETTINGS] = function(data)
    local _, rev, file, mode, chapter, difficulty, options, save_chapter, save_difficulty, save_count, save_empty =
        string.unpack(LOBBY_SETTINGS_FORMAT, data)
    return { rev = rev, file = file, mode = mode, chapter = chapter, difficulty = difficulty, options = options,
        save_chapter = save_chapter, save_difficulty = save_difficulty, save_count = save_count,
        save_empty = save_empty ~= 0 }
end

decoders[P.T.LOBBY_PLAYER] = function(data)
    local _, in_lobby, ready, loadout, name = string.unpack("<BBBBs1", data)
    return { in_lobby = in_lobby ~= 0, ready = ready ~= 0, loadout = loadout, name = name }
end

decoders[P.T.LOBBY_START] = function(data)
    local _, start_id, mode, file, chapter, difficulty, key, chapter_id = string.unpack(LOBBY_START_FORMAT, data)
    return { start_id = start_id, mode = mode, file = file, chapter = chapter, difficulty = difficulty, key = key,
        chapter_id = chapter_id }
end

decoders[P.T.LOAD_STATE] = function(data)
    local _, start_id, phase, progress = string.unpack("<BI2BB", data)
    return { start_id = start_id, phase = phase, progress = progress }
end

decoders[P.T.LOAD_GO] = function(data)
    local _, start_id = string.unpack("<BI2", data)
    return { start_id = start_id }
end

decoders[P.T.GRAB_ESCAPE] = function(data)
    local _, net_id, uid, kind_hash, how = string.unpack(GRAB_ESCAPE_FORMAT, data)
    return { net_id = net_id, uid = uid ~= 0 and uid or nil, kind_hash = kind_hash, how = how }
end

decoders[P.T.SAVE] = function(data)
    local _, kind = string.unpack("<BB", data)
    return { kind = kind }
end

decoders[P.T.ITEM_GIVE_RESULT] = function(data)
    local _, seq, returned = string.unpack("<BI4i4", data)
    return { seq = seq, returned = returned }
end

decoders[P.T.DOORS] = function(data)
    local _, n = string.unpack("<BB", data)
    local doors, off = {}, 3
    for i = 1, n do
        local guid = P.guid_from_bytes(data:sub(off, off + 15))
        local flags, attr = string.unpack("<BB", data, off + 16)
        off = off + 18
        doors[i] = { guid = guid, open = (flags & 1) ~= 0, hold = (flags & 2) ~= 0, attr = attr }
    end
    return { doors = doors }
end

decoders[P.T.ASHLEY] = function(data)
    local _, time, epoch, flags, x, y, z, rot, hp, max_hp, bank_type, nl, off = string.unpack(ASHLEY_FORMAT, data)
    if nl > P.MAX_ASHLEY_LAYERS then error("too many layers") end
    local F = P.ASHLEY_FLAGS
    local m = { time = time, epoch = epoch, flags = flags, pos = { x = x, y = y, z = z }, rot = unpack_rot(rot),
        hp = hp, max_hp = max_hp, bank_type = bank_type, layers = {},
        present = (flags & F.PRESENT) ~= 0, owner = (flags & F.OWNER) ~= 0, alive = (flags & F.ALIVE) ~= 0,
        kidnapped = (flags & F.KIDNAPPED) ~= 0, busy = (flags & F.BUSY) ~= 0, hidden = (flags & F.HIDDEN) ~= 0 }
    for l = 1, nl do
        local bank, id, frame, speed, blend, mask, mode
        bank, id, frame, speed, blend, mask, mode, off = string.unpack(ASHLEY_LAYER, data, off)
        m.layers[l] = { bank = bank, id = id, frame = frame, speed = speed, blend = blend >= 0 and blend or nil,
            mask = mask ~= 0xFFFFFFFF and mask or nil, mode = mode ~= 0xFF and mode or nil }
    end
    return m
end

decoders[P.T.ASHLEY_BANKS] = function(data)
    local _, epoch, n, off = string.unpack("<BBB", data)
    if n > P.MAX_ASHLEY_BANKS then error("too many banks") end
    local banks = {}
    for i = 1, n do
        local bank_id, bank_type, mask_bit, order, flags, path
        bank_id, bank_type, mask_bit, order, flags, path, off = string.unpack(ASHLEY_BANK, data, off)
        banks[i] = { bank_id = bank_id, bank_type = bank_type, mask_bit = mask_bit, order = order, flags = flags,
            path = path }
    end
    return { epoch = epoch, banks = banks }
end

decoders[P.T.ASHLEY_OWNER] = function(data)
    local _, owner, epoch, cooldown, reason, by = string.unpack("<BBBfBB", data)
    if owner ~= P.OWNER.HOST and owner ~= P.OWNER.CLIENT then error("bad owner") end
    return { owner = owner, epoch = epoch, cooldown = cooldown, reason = reason, by = by }
end

decoders[P.T.PURPOSE] = function(data)
    local _, id, priority, g, display, delay, flags = string.unpack(PURPOSE_FORMAT, data)
    return { id = id, priority = priority, message = P.guid_from_bytes(g), display = display, delay = delay,
        mediate = (flags & 1) ~= 0 }
end

decoders[P.T.ASHLEY_SWITCH] = function(data)
    local _, epoch = string.unpack("<BB", data)
    return { epoch = epoch }
end

decoders[P.T.MECHANISMS] = function(data)
    local _, n = string.unpack("<BB", data)
    local mechs, off = {}, 3
    for i = 1, n do
        local guid = P.guid_from_bytes(data:sub(off, off + 15))
        local kind, key = string.unpack("<BI4", data, off + 16)
        off = off + 21
        mechs[i] = { guid = guid, kind = kind, key = key }
    end
    return { mechs = mechs }
end

decoders[P.T.TRAPS] = function(data)
    local _, n = string.unpack("<BB", data)
    local traps, off = {}, 3
    for i = 1, n do
        local guid = P.guid_from_bytes(data:sub(off, off + 15))
        local kind, event = string.unpack("<BB", data, off + 16)
        off = off + 18
        traps[i] = { guid = guid, kind = kind, event = event }
    end
    return { traps = traps }
end

decoders[P.T.CUTSCENE_SKIP] = function(data)
    local _, camera, id = string.unpack("<BBi4", data)
    return { camera = camera, id = id }
end

decoders[P.T.WORLD_REQUEST] = function(data)
    local _, sync_id, what = string.unpack("<BI2B", data)
    return { sync_id = sync_id, what = what }
end

decoders[P.T.WORLD_DONE] = function(data)
    local _, sync_id, what, n_flag_groups, n_gimmicks = string.unpack("<BI2BI4I4", data)
    return { sync_id = sync_id, what = what, n_flag_groups = n_flag_groups, n_gimmicks = n_gimmicks }
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

decoders[P.T.ITEM_DROPPED] = function(data)
    local _, net_id, item_id, count, x, y, z, stage, flags = string.unpack(ITEM_DROPPED, data)
    return {
        net_id = net_id, item_id = item_id, count = count, pos = { x = x, y = y, z = z },
        stage = (flags & P.DROP_FLAGS.HAS_STAGE) ~= 0 and stage or nil,
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
