-- Enemy networking (protocol 13): the host's game runs every enemy; the client's game shows them.
--
-- Both games load the same chapter, so each level spawns the same enemies on both machines.
-- This module keeps the two copies of every enemy one enemy (the RE4 facts behind it are in
-- docs/RESEARCH.md 3.8-3.10 and 3.25):
--
--   * Identity. A level enemy's own ContextID is the serialized ContextID of the spawn param
--     that created it: level data, the same on both PCs. Its code (`uid`) pairs the two copies
--     exactly, wherever each game placed them. Runtime enemies (no uid) pair by kind and spawn
--     point. The host numbers its enemies for the wire (net ids); the client pairs its copies
--     with those numbers.
--
--   * Authority: the host's, always. The host's game runs every enemy's AI, movement, health
--     and death; nothing is shared and nothing changes hands. Every copy in the client's game is
--     a puppet: AI head off, the body's own animation driver locked, and position, full
--     rotation, animation layers (motion, frame, speed), visibility and HP taken from the host's
--     stream. A copy the host's world does not have (not spawned there yet, or gone from it)
--     waits still and unseen.
--
--   * The client's player is a second player in the host's game (partner_target.lua): the
--     host's enemies see, hear and attack the client's character there, as they do the host's.
--     Here that means: the client's hits and finishers on an enemy run in the host's game, and
--     the host tells the client, per enemy, which finishers the enemy offers the client's
--     player (the client's own copy does not think, so it cannot say).
--
--   * State. The host sends the full state of its enemies ~20 times a second (ENEMY_STATE):
--     position, rotation, velocity, HP, max HP, visibility, up to three animation layers and
--     what the enemy says about the client's player (finishers it allows, whether it targets
--     the client). The puppet follows it through an interpolation buffer (transform every frame,
--     animation corrected when it drifts more than a few frames).
--
--   * Damage. A hit the client's player lands is sent to the host (ENEMY_HIT) with every value
--     of the game's DamageInfo, and the host runs it through its own hit code with the client's
--     character as the attacker: same damage, same reaction (flinch, stagger, knock-down, part
--     breaks), and the enemy turns on the client. On the client's side the hit happens too
--     (blood, sounds, part breaks) but can never kill the puppet: the host decides. Its HP
--     follows the host's, and is not raised again until the host acknowledged the hit. Damage a
--     puppet takes from anything else (explosions, falls) is reported to the host as well.
--
--   * Finishers. A stealth kill, knife finish, stomp or kick prompt the client's player acts on
--     is asked of the enemy's AI head (PlayerHeadUpdater.requestFatal & co.). The client's
--     puppet answers from the host's information and the request travels to the host
--     (ENEMY_FATAL), whose game asks its enemy's head the same with the client's character as
--     the attacker: the enemy's side plays in the host's game and its stream shows it here.
--
--   * Death. Only the host decides a death and announces it (ENEMY_DEATH) with where it happened,
--     the killing hit and whether that hit was the client's; the client's game puts its copy
--     there and kills it with that hit (so the death reaction and the loot happen in both games).
--     Deaths are final in both directions: the host keeps the list of every enemy dead in its
--     world ("graveyard": the deaths it saw, the client's kills of enemies it had not loaded, and
--     for a joining client every enemy its save has eliminated), and the client removes such an
--     enemy wherever it shows up: in front of the player it dies, just spawned or far away it is
--     erased the way the game removes a finished enemy (no corpse, never comes back).
--
-- Game access goes through an adapter (game.lua) so this file is pure Lua and is tested
-- offline (tests/lua/test_enemy_net.lua).
--
-- Adapter contract:
--   enemies = { {id, kind, uid|nil, pos={x,y,z}, rot={x,y,z,w}, hp, max_hp, alive,
--                hidden=bool|nil, layers={{bank,id,frame,speed}...}|nil}, ... }   (passed to tick;
--                layers/hidden are read for the ids want_state(id) asks for)
--   game:enemy_set_hp(id, hp) -> bool               (never kills: at least 1)
--   game:enemy_get_hp(id) -> number|nil
--   game:enemy_kill(id, fields|nil, by) -> bool     (dies with its own logic; with the killing hit if given;
--                                                    by = "self" | "partner": whose player's hit it was)
--   game:enemy_erase(id) -> bool                    (optional: removed without a death)
--   game:enemy_revive(uid) -> "spawning"|"forgotten"|"missing"|"dead_here"
--                                                    (optional, client: spawn a host enemy our game has not)
--   game:enemy_restore_spawns(uid|nil) -> n          (optional: undo enemy_erase - alive again)
--   game:enemy_apply_hit(id, hit) -> bool           (optional, host: runs the client's hit through the game's hit code)
--   game:enemy_last_hit(id) -> fields|nil           (optional: the values of the last hit it took)
--   game:enemy_set_puppet(id, on) -> bool           (optional: AI head and animation driver off/on)
--   game:enemy_set_transform(id, pos, rot) -> bool  (optional)
--   game:enemy_set_anim(id, layers) -> bool         (optional)
--   game:enemy_set_visible(id, on) -> bool          (optional)
--   game:enemy_partner_fatal(id, kind, ftype) -> bool (optional, host: the client's finisher on enemy id)
--   game:enemy_partner_info(id, near) -> pinfo, ftype (optional, host: P.PARTNER_INFO bits for the client)
--   game:scan_eliminated(budget) -> done, uids      (optional, host: enemies dead in its save)
--   on_local_fatal(events): finishers our player (client) started on puppets: { {id, kind, ftype,
--   pos, yaw}, ... } (game:take_fatal_events)

local Interp = require("re4coop.interp")

local EnemyNet = {}
EnemyNet.__index = EnemyNet

local HP_EPS = 0.01
local FORGET_AFTER = 5.0       -- seconds an enemy may be missing from our list before it is forgotten
local RETIRED_HOLD = 10.0      -- host: a retired net id is not handed out again for this long
local REMOTE_STALE = 2.0       -- client: a host enemy without news for this long is gone there
local ROSTER_STALE = 1.5       -- host: a client report older than this no longer counts
local PENDING_TIMEOUT = 1.0    -- a hit we forwarded and the host did not acknowledge stops holding our HP
local MAX_RECENT_HITS = 16     -- partner hits kept for drawing shot tracers
local MIRROR_DELAY = 0.1       -- default interpolation delay of puppets
local MIRROR_MIN_MOVE = 0.01   -- metres; smaller corrections are not written
local MIRROR_MIN_TURN = 1e-5   -- 1 - |dot| of two rotations; smaller turns are not written
local MATCH_RADIUS = 3.0       -- enemies without a uid: same kind within this of the spawn point
local SEEN_BEFORE = 1.0        -- an enemy known this long and this close dies visibly...
local VISIBLE_RADIUS = 40.0    -- ...when the partner's world has it dead; otherwise it is erased
local REVIVE_GUARD = 2.0       -- seconds after a death during which "alive" states are stale
local GRAVE_SCAN_BUDGET = 48   -- host: save backups read per tick while listing the dead
local REMOVE_RETRY = 1.0       -- seconds before an enemy that refused to die is tried again
local ERASE_VERIFY = 3.0       -- an erased enemy still alive after this long is killed instead
local CORPSE_GUARD = 3.0       -- host: seconds after our own reload before corpses are news
local FRESH_ANIM = 1.5         -- seconds after our hit in which a puppet plays the host's newest animation
local MISSING_AFTER = 1.5      -- client: a host enemy our game has not spawned for this long is spawned here
local REVIVE_RETRY = 3.0       -- seconds between attempts to spawn the same one
local REVIVE_PER_TICK = 4
local DIED_HERE_GUARD = 15.0   -- an enemy that died in our game is not spawned again for this long
local SPAWN_RANGE = 80.0       -- client: host enemies farther than this from our player are not spawned here
local KILL_CREDIT = 3.0        -- host: a death within this of the client's last hit (and after ours) is the client's kill
local PARTNER_INFO_RANGE = 8.0 -- host: enemies this close to the client's character are asked about its finishers
local PARTNER_TARGET_RANGE = 60.0 -- host: ...and this close, whether they target it

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function copy3(v)
    return { x = v.x, y = v.y, z = v.z }
end

-- u8 epochs: is `a` newer than `b`? (0 = never assigned; the host skips it on wrap)
local function epoch_newer(a, b)
    return a ~= b and ((a - b) & 0xFF) < 0x80
end

-- u16 hit sequence numbers: has `ack` reached `seq`?
local function seq_reached(ack, seq)
    return ((ack - seq) & 0xFFFF) < 0x8000
end

local function rot_delta(a, b)
    if a == nil or b == nil then return 1 end
    local d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    return 1 - math.abs(d)
end

-- Puppet states: position, rotation and animation layers (Interp.blend_layers).
local blend_state = Interp.blend_layers

-- opts: { role="host"|"client", protocol=<protocol module>, send=function(bytes, reliable),
--         settings=<table read live>, log=function(fmt, ...),
--         on_kill=function(local_id, now) (optional: an enemy died here because the host's game killed it) }
-- settings: sync_enemies, enemy_mirror, enemy_motion_sync, enemy_erase, enemy_hit_predict,
--           enemy_interp_delay, enemy_spawn_missing, snapshot_hz, roster_hz
function EnemyNet.new(opts)
    local self = setmetatable({}, EnemyNet)
    self.role = opts.role
    self.P = opts.protocol
    self.send = opts.send
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
    self.on_kill = opts.on_kill or function() end
    self.me = self.role == "host" and self.P.OWNER.HOST or self.P.OWNER.CLIENT
    self.partner = self.role == "host" and self.P.OWNER.CLIENT or self.P.OWNER.HOST
    self:reset()
    return self
end

function EnemyNet:reset()
    self.kind_hashes = {}  -- kind string -> hash (cache)
    self.locals = {}       -- local id -> record (see observe)
    self.id_of_uid = {}    -- uid -> local id (from the latest list)
    self.by_id = {}        -- local id -> latest enemy from the list
    self.nets = {}         -- net id -> shared enemy (see new_net)
    self.retired = {}      -- host: net id -> time it was retired
    self.next_net_id = 1
    self.owner_changes = {} -- host: ENEMY_OWNER entries to send this tick
    self.hit_seq = 0
    self.predicted = {}    -- our forwarded hit seq -> {amount it took here at once, time}
    self.last_state_send = -math.huge
    self.last_roster_send = -math.huge
    self.recent_hits = {}

    -- the dead
    self.dead = {}          -- host: uid -> { time, by = "host"|"client" }: dead in the host's world
    self.dead_count = 0
    self.grave = {}         -- client: uid -> time it was buried
    self.grave_count = 0
    self.dead_net = {}      -- client: net id -> time (host deaths of enemies without a uid)
    self.died_here = {}     -- uid -> time it died in our game (never spawned again right away)
    self.revived = {}       -- client: uid -> time we asked our game to spawn it for the host's world
    self.grave_scan = nil
    self.corpse_guard_until = nil
    self.reloaded = nil

    self.counters = { states_sent = 0, states_received = 0, uid_pairs = 0, spatial_pairs = 0, assigned = 0,
        hits_sent = 0, hits_forwarded = 0, hits_received = 0, hits_applied = 0,
        hits_fallback = 0, hits_unmatched = 0, damage_reported = 0, hp_applied = 0, hp_failed = 0,
        deaths_sent = 0, deaths_received = 0, kills_applied = 0, client_kills = 0, erased = 0, late_kills = 0,
        buried = 0, graves_sent = 0, graves_received = 0, moves = 0, anims = 0, puppet_switches = 0, puppet_lost = 0,
        held = 0, retired = 0, fatals_sent = 0, fatals_unpaired = 0, fatals_received = 0, fatals_applied = 0,
        fatals_failed = 0, partner_info = 0, targeting_partner = 0 }
end

function EnemyNet:kind_hash(kind)
    local h = self.kind_hashes[kind]
    if h == nil then
        h = self.P.hash(kind)
        self.kind_hashes[kind] = h
    end
    return h
end

function EnemyNet:mirroring(game)
    return self.settings.enemy_mirror ~= false and game ~= nil and game.enemy_set_transform ~= nil
end

-------------------------------------------------------------------------------
-- Local enemies
-------------------------------------------------------------------------------

-- Forgets local enemy `id` (gone from the list, or its context now holds another enemy).
function EnemyNet:forget_local(id)
    local l = self.locals[id]
    if l == nil then return end
    self.locals[id] = nil
    local net = l.net_id and self.nets[l.net_id]
    if net ~= nil and net.local_id == id then net.local_id = nil end
end

-- Reads this tick's list into our per-enemy records.
function EnemyNet:observe(now, enemies)
    local by_id, id_of_uid = {}, {}
    for _, e in ipairs(enemies) do
        e.kind_hash = e.kind_hash or self:kind_hash(e.kind)
        local l = self.locals[e.id]
        if l ~= nil and (l.uid ~= (e.uid or false) or l.kind_hash ~= e.kind_hash) then
            self:forget_local(e.id) -- the game reused this context for another enemy
            l = nil
        end
        if l == nil then
            l = { id = e.id, uid = e.uid or false, kind_hash = e.kind_hash, spawn = copy3(e.pos), first_seen = now,
                vel = { x = 0, y = 0, z = 0 } }
            self.locals[e.id] = l
        elseif l.prev_t ~= nil and now > l.prev_t then
            local dt = now - l.prev_t
            local k = math.min(1, dt * 10)
            for _, c in ipairs({ "x", "y", "z" }) do
                local v = (e.pos[c] - l.prev_pos[c]) / dt
                l.vel[c] = l.vel[c] + (v - l.vel[c]) * k
            end
        end
        l.prev_pos, l.prev_t = copy3(e.pos), now
        l.last_seen = now
        l.vanish_checked = nil -- (in our list again: a later disappearance is checked again)
        l.e = e
        by_id[e.id] = e
        if e.uid ~= nil then
            -- Two contexts with one uid (a corpse and its successor): the living one counts.
            local other = id_of_uid[e.uid]
            if other == nil or (e.alive and not by_id[other].alive) then id_of_uid[e.uid] = e.id end
        end
    end
    self.by_id, self.id_of_uid = by_id, id_of_uid
    for id, l in pairs(self.locals) do
        if now - l.last_seen > FORGET_AFTER then self:forget_local(id) end
    end
    return by_id
end

-- The closest local enemy of this kind without a uid whose spawn point (or position) is within
-- MATCH_RADIUS. `taken` excludes enemies already paired.
function EnemyNet:find_spatial(kind_hash, spawn_pos, cur_pos, taken, want_alive)
    local best, best_d = nil, math.huge
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        if e.uid == nil and e.kind_hash == kind_hash and not taken[id] and (not want_alive or e.alive) then
            local d = dist(l.spawn or e.pos, spawn_pos)
            if cur_pos ~= nil then d = math.min(d, dist(e.pos, cur_pos)) end
            if d <= MATCH_RADIUS and d < best_d then best, best_d = id, d end
        end
    end
    return best
end

-- The local enemy a partner message names: by net id, by uid, or by kind and spawn point.
function EnemyNet:resolve(net_id, uid, kind_hash, pos)
    local net = net_id ~= nil and net_id ~= 0 and self.nets[net_id] or nil
    if net ~= nil and net.local_id ~= nil and self.by_id[net.local_id] ~= nil then return net.local_id end
    if uid ~= nil then return self.id_of_uid[uid] end
    if kind_hash ~= nil and pos ~= nil then
        local taken = {}
        for id, l in pairs(self.locals) do
            if l.net_id ~= nil and l.net_id ~= net_id then taken[id] = true end
        end
        return self:find_spatial(kind_hash, pos, pos, taken, true)
    end
    return nil
end

-------------------------------------------------------------------------------
-- The host's enemies (net ids)
-------------------------------------------------------------------------------

function EnemyNet:new_buffer()
    local delay = tonumber(self.settings.enemy_interp_delay) or MIRROR_DELAY
    return Interp.new({ delay = delay, max_delay = math.max(0.25, delay), adaptive = true, max_extrapolate = 0.2,
        capacity = 16, blend = blend_state })
end

-- A host enemy: { net_id, uid|nil, kind_hash, spawn, epoch (0 = the client has no copy yet),
-- local_id, interp, newest (client: the host's latest state), updated, ack (host: the last of
-- the client's hits applied), pending ({seq, time}: client: our last forwarded hit), hit_at
-- { [player] = time }: the last hit of each player }
function EnemyNet:new_net(net_id, uid, kind_hash, spawn)
    local net = { net_id = net_id, uid = uid, kind_hash = kind_hash, spawn = spawn, owner = self.P.OWNER.HOST,
        epoch = 0, ack = 0 }
    self.nets[net_id] = net
    return net
end

function EnemyNet:pair(net, id)
    local old = net.local_id and self.locals[net.local_id]
    if old ~= nil and old.net_id == net.net_id then old.net_id = nil end
    net.local_id = id
    local l = self.locals[id]
    if l ~= nil then
        local prev = l.net_id and self.nets[l.net_id]
        if prev ~= nil and prev ~= net and prev.local_id == id then prev.local_id = nil end
        l.net_id = net.net_id
    end
end

function EnemyNet:unpair(net)
    local l = net.local_id and self.locals[net.local_id]
    if l ~= nil and l.net_id == net.net_id then l.net_id = nil end
    net.local_id = nil
end

-- Whether our game runs the AI of this enemy and decides its death: the host's game, always.
function EnemyNet:runs_here()
    return self.role == "host"
end

-- Host: the next free net id.
function EnemyNet:alloc_net_id(now)
    for _ = 1, 65535 do
        local id = self.next_net_id
        self.next_net_id = id % 65535 + 1
        local r = self.retired[id]
        if self.nets[id] == nil and (r == nil or now - r > RETIRED_HOLD) then
            self.retired[id] = nil
            return id
        end
    end
    return nil
end

-- Host: an enemy left our world (unloaded, despawned): its number is free again, and the
-- client stops pairing it (its copy waits, still and unseen).
function EnemyNet:retire(net, now)
    self.nets[net.net_id] = nil
    self.retired[net.net_id] = now
    if net.client_knows then
        self.owner_changes[#self.owner_changes + 1] = { net_id = net.net_id, epoch = net.epoch,
            owner = self.P.OWNER.NONE, uid = net.uid }
        self.counters.retired = self.counters.retired + 1
    end
end

-- Host: the client has a copy of an enemy we have not numbered for it yet. Our game runs it
-- (as every enemy); the client's copy may have been hit before our level spawned it - damage
-- done stays done.
function EnemyNet:assign_new(now, game)
    for _, net in pairs(self.nets) do
        local e = net.local_id and self.by_id[net.local_id]
        local r = net.roster
        if net.epoch == 0 and e ~= nil and e.alive and r ~= nil and now - r.time <= ROSTER_STALE and r.alive then
            local hp = e.hp
            if r.hp ~= nil and r.hp > HP_EPS and r.hp < e.hp - HP_EPS and game ~= nil
                and game:enemy_set_hp(net.local_id, r.hp) then
                e.hp = r.hp
                hp = r.hp
            end
            net.epoch = 1
            self.owner_changes[#self.owner_changes + 1] = { net_id = net.net_id, epoch = net.epoch,
                owner = self.P.OWNER.HOST, uid = net.uid, hp = hp }
            self.counters.assigned = self.counters.assigned + 1
        end
    end
end

function EnemyNet:flush_owner_changes()
    if #self.owner_changes == 0 then return end
    for _, msg in ipairs(self.P.encode_enemy_owners(self.owner_changes)) do self.send(msg, true) end
    self.owner_changes = {}
end

-------------------------------------------------------------------------------
-- Puppets (client)
-------------------------------------------------------------------------------

-- Our copy's own AI and animation driver off (a puppet of the host's) or on. A puppet the
-- game adapter switched back on by itself (a death it ran, a head the game linked again) is
-- switched off again: otherwise its own AI would run in both games.
function EnemyNet:set_puppet(game, id, on)
    local l = self.locals[id]
    if l == nil or game == nil then return end
    if on then
        if l.puppet and game.enemy_is_puppet ~= nil and not game:enemy_is_puppet(id) then
            l.puppet = nil
            self.counters.puppet_lost = (self.counters.puppet_lost or 0) + 1
        end
        if not l.puppet and game.enemy_set_puppet ~= nil and game:enemy_set_puppet(id, true) then
            l.puppet = true
            self.counters.puppet_switches = self.counters.puppet_switches + 1
        end
    elseif l.puppet then
        if game.enemy_set_puppet ~= nil then game:enemy_set_puppet(id, false) end
        l.puppet = nil
        self.counters.puppet_switches = self.counters.puppet_switches + 1
    end
end

function EnemyNet:set_visible(game, id, on)
    local l = self.locals[id]
    if l == nil or game == nil or game.enemy_set_visible == nil then return end
    if on then
        if l.hidden then
            game:enemy_set_visible(id, true)
            l.hidden = nil
        end
    elseif not l.hidden and game:enemy_set_visible(id, false) then
        l.hidden = true
    end
end

-- Back to the game: AI on, drawn.
function EnemyNet:release(game, id)
    self:set_puppet(game, id, false)
    self:set_visible(game, id, true)
end

function EnemyNet:release_all(game)
    for id, l in pairs(self.locals) do
        if l.puppet or l.hidden then self:release(game, id) end
    end
end

-- Puts each local enemy in the hands it belongs to. Host: our AI runs everything. Client: a
-- copy of a host enemy is its puppet; one the host's world does not have waits, still and
-- unseen, until the host's shows up.
function EnemyNet:control(game)
    local mirror = self:mirroring(game)
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        local net = l.net_id and self.nets[l.net_id]
        if not e.alive or l.self_killed or l.removing ~= nil or not mirror or self.role == "host" then
            if l.puppet or l.hidden then self:release(game, id) end
        elseif net ~= nil then
            self:set_puppet(game, id, true)
            local st = net.newest
            self:set_visible(game, id, not (st ~= nil and st.hidden))
        else
            if not l.puppet or not l.hidden then self.counters.held = self.counters.held + 1 end
            self:set_puppet(game, id, true)
            self:set_visible(game, id, false)
        end
    end
end

-- Client: the host's state onto our puppets' HP (the host's HP wins, but our own forwarded hits
-- keep it from going back up until the host acknowledged them). Not before the host numbered
-- the enemy for us (epoch 0): until then our roster tells it what our copy took before its level
-- spawned the enemy, and that damage stays done (assign_new).
function EnemyNet:reconcile_hp(now, game)
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local e = id and self.by_id[id]
        local st = net.newest
        local l = id and self.locals[id]
        if e ~= nil and e.alive and st ~= nil and st.alive and net.epoch ~= 0 then
            local p = net.pending
            if p ~= nil and (seq_reached(st.ack or 0, p.seq) or now - p.time > PENDING_TIMEOUT) then
                net.pending, p = nil, nil
            end
            local target = st.hp
            if target > HP_EPS and ((e.hp > target + HP_EPS) or (e.hp < target - HP_EPS and p == nil)) then
                if game:enemy_set_hp(id, target) then
                    e.hp = target
                    self.counters.hp_applied = self.counters.hp_applied + 1
                else
                    self.counters.hp_failed = self.counters.hp_failed + 1
                end
            end
            l.expected_hp = e.hp
        end
    end
end

-- Client, every frame: puppets stand where the host's enemies are.
function EnemyNet:frame(now, game)
    if self.role ~= "client" or not self:mirroring(game) then return end
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local l = id and self.locals[id]
        if l ~= nil and l.puppet and net.interp ~= nil then
            local e = self.by_id[id]
            local age = net.interp:age(now)
            if e ~= nil and e.alive and age ~= nil and age < REMOTE_STALE then
                local st = net.interp:sample(now)
                if st ~= nil and (dist(e.pos, st.pos) > MIRROR_MIN_MOVE or rot_delta(e.rot, st.rot) > MIRROR_MIN_TURN) then
                    if game:enemy_set_transform(id, st.pos, st.rot) then
                        e.pos, e.rot = copy3(st.pos), st.rot
                        self.counters.moves = self.counters.moves + 1
                    end
                end
            end
        end
    end
end

-- Client: animation layers onto our puppets (at the tick rate: the game plays the motion on
-- between corrections, the adapter only steps in when a layer plays something else or drifted).
function EnemyNet:apply_anims(now, game)
    if self.role ~= "client" or self.settings.enemy_motion_sync == false or game.enemy_set_anim == nil
        or not self:mirroring(game) then
        return
    end
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local l = id and self.locals[id]
        if l ~= nil and l.puppet and net.interp ~= nil then
            local age = net.interp:age(now)
            local st = age ~= nil and age < REMOTE_STALE and net.interp:sample(now) or nil
            -- Just after our own hit: its reaction as soon as it arrives, not one interpolation
            -- delay later (the position keeps its smooth, delayed track).
            local mine = net.hit_at and net.hit_at[self.me]
            if st ~= nil and mine ~= nil and now - mine <= FRESH_ANIM and net.newest ~= nil
                and net.newest.layers ~= nil and #net.newest.layers > 0 then
                st = { layers = net.newest.layers }
                self.counters.fresh_anims = (self.counters.fresh_anims or 0) + 1
            end
            if st ~= nil and st.layers ~= nil and #st.layers > 0 and game:enemy_set_anim(id, st.layers) then
                self.counters.anims = self.counters.anims + 1
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Deaths
-------------------------------------------------------------------------------

function EnemyNet:bury(uid, now, by)
    if uid == nil then return end
    if self.role == "host" then
        if self.dead[uid] == nil then
            self.dead_count = self.dead_count + 1
            self.counters.buried = self.counters.buried + 1
        end
        self.dead[uid] = { time = now, by = by }
    else
        if self.grave[uid] == nil then
            self.grave_count = self.grave_count + 1
            self.counters.buried = self.counters.buried + 1
        end
        self.grave[uid] = now
    end
end

function EnemyNet:unbury(uid)
    if self.role == "host" then
        if self.dead[uid] ~= nil then
            self.dead[uid] = nil
            self.dead_count = self.dead_count - 1
        end
    elseif self.grave[uid] ~= nil then
        self.grave[uid] = nil
        self.grave_count = self.grave_count - 1
    end
end

-- Whether this enemy is dead in the partner's world (so it must not live in ours).
function EnemyNet:dead_elsewhere(e, net)
    if self.role == "host" then
        local d = e.uid ~= nil and self.dead[e.uid] or nil
        return d ~= nil and d.by == "client"
    end
    return (e.uid ~= nil and self.grave[e.uid] ~= nil) or (net ~= nil and self.dead_net[net.net_id] ~= nil)
end

-- When did the partner's world last see this one die (nil: not recently)?
function EnemyNet:died_at(uid, net_id)
    if self.role == "host" then
        local d = uid ~= nil and self.dead[uid] or nil
        return d and d.time
    end
    return (uid ~= nil and self.grave[uid]) or (net_id ~= nil and self.dead_net[net_id]) or nil
end

-- Client: kills our copy because the host's game decided its death: at the place it died, with
-- the hit that killed it (by_us: our player's hit, which the host ran). Returns true if it died.
function EnemyNet:kill_here(game, id, now, pos, rot, fields, by_us)
    local e = self.by_id[id]
    local l = self.locals[id]
    if e == nil or l == nil or not e.alive or game == nil then return false end
    self:release(game, id)
    if pos ~= nil and game.enemy_set_transform ~= nil and dist(e.pos, pos) < 30 then
        if game:enemy_set_transform(id, pos, rot) then e.pos, e.rot = copy3(pos), rot end
    end
    l.removing = { time = now, how = "kill" }
    if game:enemy_kill(id, fields, by_us and "self" or "partner") then
        l.self_killed = true
        e.hp, e.alive = 0, false
        l.was_alive = false
        self.counters.kills_applied = self.counters.kills_applied + 1
        self.on_kill(id, now)
        return true
    end
    return false
end

-- An enemy dead in the partner's world that still lives in ours. One the player has been near
-- for a while dies visibly with its own logic (animation, ragdoll, loot); one that only just
-- spawned, or is far away, is erased: it simply never shows up. Paces its own retries: a kill
-- the game refused is tried again, an erase that did not despawn it becomes a kill.
function EnemyNet:remove_dead(game, id, e, now, local_pos)
    if game == nil then return false end
    local l = self.locals[id]
    local r = l.removing
    if r ~= nil then
        local wait = r.how == "erase" and ERASE_VERIFY or REMOVE_RETRY
        if now - r.time < wait then return false end
    end
    local visible = now - (l.first_seen or now) >= SEEN_BEFORE
        and (local_pos == nil or dist(e.pos, local_pos) <= VISIBLE_RADIUS)
    local erase = not visible and (r == nil or r.how ~= "erase")
        and self.settings.enemy_erase ~= false and game.enemy_erase ~= nil
    self:release(game, id)
    l.removing = { time = now, how = "kill" }
    if erase and game:enemy_erase(id) then
        l.removing.how = "erase"
        l.self_killed = true
        e.alive = false
        l.was_alive = false
        self.counters.erased = self.counters.erased + 1
        return true
    end
    if game:enemy_kill(id, nil, "partner") then
        l.self_killed = true
        e.hp, e.alive = 0, false
        l.was_alive = false
        self.counters.kills_applied = self.counters.kills_applied + 1
        self.on_kill(id, now)
        return true
    end
    return false
end

-- Host: enemies that left our list this tick while alive. A boss whose death is a cutscene
-- leaves it without ever reaching HP 0 here (El Gigante, docs/RESEARCH.md 3.24). If our game has
-- it eliminated (dead for good), it died: the client's copy dies too. An enemy that only
-- unloaded with its area is not eliminated (the client's copy waits, unseen). Checked once per
-- disappearance, before its number is retired.
function EnemyNet:check_vanished_deaths(now, game)
    if self.role ~= "host" or game == nil or game.enemy_eliminated == nil then return end
    for id, l in pairs(self.locals) do
        if l.last_seen ~= nil and l.last_seen < now and not l.vanish_checked and l.was_alive == true
            and not l.death_sent and not l.self_killed and l.uid and l.e ~= nil then
            l.vanish_checked = true
            local net = l.net_id and self.nets[l.net_id]
            if game:enemy_eliminated(l.uid) == true then
                self:announce_death(game, id, l.e, net, now)
                l.was_alive = false
                self.counters.vanished_deaths = (self.counters.vanished_deaths or 0) + 1
            end
        end
    end
end

-- Host: whether the death of local enemy `l` is the client's kill (the client's hit or
-- finisher was the last one that landed, shortly before).
function EnemyNet:client_kill(l, now)
    local t = l.partner_hit_at
    return t ~= nil and now - t <= KILL_CREDIT and (l.own_hit_at == nil or t >= l.own_hit_at)
end

-- Host: an enemy died in our world: tell the client (with where it died, the hit that killed
-- it and whether that hit was the client's).
function EnemyNet:announce_death(game, id, e, net, now)
    local l = self.locals[id]
    local fields = game ~= nil and game.enemy_last_hit ~= nil and game:enemy_last_hit(id) or nil
    local by_client = self:client_kill(l, now)
    self.send(self.P.encode_enemy_death({
        net_id = net and net.net_id or 0, epoch = net and net.epoch or 0, uid = e.uid, kind_hash = e.kind_hash,
        pos = e.pos, rot = e.rot, fields = fields, flags = by_client and self.P.DEATH_FLAGS.BY_CLIENT or 0,
    }), true)
    self.counters.deaths_sent = self.counters.deaths_sent + 1
    if by_client then self.counters.client_kills = self.counters.client_kills + 1 end
    self:bury(e.uid, now, by_client and "client_hit" or "host")
    l.death_sent = true
end

-- Deaths in our world, and enemies in our world that are dead in the partner's.
function EnemyNet:update_deaths(now, game, local_pos)
    if self.corpse_guard_until == nil then
        -- Just after our own reload the list may still hold the old scene's dead: not news.
        self.corpse_guard_until = self.reloaded and (now + CORPSE_GUARD) or -math.huge
        self.reloaded = nil
    end
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        local net = l.net_id and self.nets[l.net_id]
        local was_alive = l.was_alive
        if was_alive == true and not e.alive and e.uid ~= nil then self.died_here[e.uid] = now end
        if was_alive == true and not e.alive and not l.self_killed and not l.death_sent then
            if self.role == "host" then
                -- It died in our world: ours to announce.
                if net ~= nil or e.uid ~= nil then self:announce_death(game, id, e, net, now) end
            elseif net ~= nil then
                -- A puppet died of something in our game (an explosion...): the host decides.
                self:report_damage(net, e, l, now, l.expected_hp or e.max_hp, true)
            end
        elseif was_alive == nil and not e.alive and e.uid ~= nil and self.role == "host"
            and now >= self.corpse_guard_until and (self.dead[e.uid] == nil or self.dead[e.uid].by == "client") then
            -- A corpse: it died in our world before we saw it (before the session, or while its
            -- area was loading). The client's copy may still be alive.
            self:announce_death(game, id, e, net, now)
        elseif e.alive and self:dead_elsewhere(e, net) then
            if self:remove_dead(game, id, e, now, local_pos) and self.role == "host" then
                self.counters.late_kills = self.counters.late_kills + 1
            end
        end
        l.was_alive = e.alive
    end
end

-------------------------------------------------------------------------------
-- Hits
-------------------------------------------------------------------------------

function EnemyNet:next_seq()
    self.hit_seq = self.hit_seq % 65535 + 1
    return self.hit_seq
end

function EnemyNet:note_hit(net, who, now)
    if net == nil then return end
    net.hit_at = net.hit_at or {}
    net.hit_at[who] = now
end

-- Client: damage our puppet took that the host must apply (no hit of ours explains it: an
-- explosion, a fall...). Sent as a hit without values (the host subtracts HP).
function EnemyNet:report_damage(net, e, l, now, from_hp, lethal)
    local amount = math.max(0, (from_hp or e.hp) - e.hp)
    if amount <= HP_EPS and not lethal then return end
    local P = self.P
    local seq = self:next_seq()
    self.send(P.encode_enemy_hit({
        net_id = net.net_id, epoch = net.epoch, flags = P.HIT_FLAGS.APPLY | (lethal and P.HIT_FLAGS.LETHAL or 0),
        uid = e.uid, kind_hash = e.kind_hash, pos = l.spawn or e.pos, damage = amount, hp = from_hp or e.hp, seq = seq,
    }), true)
    net.pending = { seq = seq, time = now }
    self.counters.damage_reported = self.counters.damage_reported + 1
end

-- events: game:take_hit_events() - hits our player landed: { {id, damage, hp, local_damage,
-- critical, lethal, fields}, ... }. Client: every hit is sent for the host to run. Host: a hit is
-- sent so the client can draw it (shot tracer).
function EnemyNet:on_local_hits(events, now)
    local P = self.P
    for _, ev in ipairs(events or {}) do
        local l = self.locals[ev.id]
        local e = self.by_id[ev.id]
        local net = l and l.net_id and self.nets[l.net_id]
        if l ~= nil and e ~= nil then
            if self.role == "client" and (net ~= nil or e.uid ~= nil) then
                local seq = self:next_seq()
                local flags = P.HIT_FLAGS.APPLY | (ev.lethal and P.HIT_FLAGS.LETHAL or 0)
                self.send(P.encode_enemy_hit({
                    net_id = net and net.net_id or 0, epoch = net and net.epoch or 0, flags = flags, critical = ev.critical,
                    uid = e.uid, kind_hash = e.kind_hash, pos = l.spawn or e.pos, damage = ev.damage or 0,
                    hp = ev.hp or e.hp, seq = seq, fields = ev.fields,
                }), true)
                if net ~= nil then net.pending = { seq = seq, time = now } end
                self.predicted[seq] = { amount = ev.local_damage or 0, time = now }
                -- What the hit took here is ours, not damage to report again.
                l.hit_dropped = (l.hit_dropped or 0) + (ev.local_damage or 0)
                self:note_hit(net, self.me, now)
                self.counters.hits_forwarded = self.counters.hits_forwarded + 1
            elseif self.role == "host" and (net ~= nil or e.uid ~= nil) then
                l.own_hit_at = now
                self.send(P.encode_enemy_hit({
                    net_id = net and net.net_id or 0, epoch = net and net.epoch or 0, critical = ev.critical,
                    uid = e.uid, kind_hash = e.kind_hash, pos = l.spawn or e.pos, damage = ev.damage or 0,
                    hp = ev.hp or e.hp,
                }), true)
                self:note_hit(net, self.me, now)
                self.counters.hits_sent = self.counters.hits_sent + 1
            end
        end
    end
end

-- Host: runs the client's hit on our enemy: through the game's hit code (the client's
-- character as the attacker), else as HP.
function EnemyNet:apply_hit(game, id, e, m, now)
    if game.enemy_apply_hit ~= nil and m.fields ~= nil and #m.fields > 0 and game:enemy_apply_hit(id, m) then
        self.counters.hits_applied = self.counters.hits_applied + 1
        local hp = game.enemy_get_hp and game:enemy_get_hp(id) or nil
        if hp ~= nil then e.hp = hp end
        return true
    end
    -- No hit code to run it through (or a plain damage report): the HP is what counts. A
    -- report that our enemy died in the client's game (its copy there died of something we
    -- cannot replay) is a death: dead stays dead.
    local cur = game.enemy_get_hp ~= nil and game:enemy_get_hp(id) or e.hp
    local new_hp = cur - (m.damage or 0)
    self.counters.hits_fallback = self.counters.hits_fallback + 1
    if new_hp <= HP_EPS or (m.lethal and (m.fields == nil or #m.fields == 0)) then
        if game:enemy_kill(id, m.fields, "partner") then
            e.hp = 0
            return true
        end
        return false
    end
    if game:enemy_set_hp(id, new_hp) then
        e.hp = new_hp
        return true
    end
    return false
end

function EnemyNet:on_partner_hit(m, now, game)
    local net = m.net_id ~= 0 and self.nets[m.net_id] or nil
    if net ~= nil and ((net.uid ~= nil and m.uid ~= nil and net.uid ~= m.uid) or net.kind_hash ~= m.kind_hash) then
        net = nil -- a number since given to another enemy
    end
    local id = self:resolve(net and net.net_id or nil, m.uid, m.kind_hash, m.pos)
    local e = id and self.by_id[id]
    if e == nil then
        self.counters.hits_unmatched = self.counters.hits_unmatched + 1
        -- A kill in the client's game of an enemy ours has not loaded: dead in the shared world.
        if self.role == "host" and m.apply and m.lethal and m.uid ~= nil and self.dead[m.uid] == nil then
            self:bury(m.uid, now, "client")
        end
        return
    end
    if net == nil then
        local l = self.locals[id]
        net = l and l.net_id and self.nets[l.net_id] or nil
    end
    self.counters.hits_received = self.counters.hits_received + 1
    self:note_hit(net, self.partner, now)
    local hits = self.recent_hits
    hits[#hits + 1] = { pos = copy3(e.pos), time = now }
    if #hits > MAX_RECENT_HITS then table.remove(hits, 1) end
    if self.role ~= "host" or not m.apply or not e.alive or game == nil then return end
    local l = self.locals[id]
    if l ~= nil then l.partner_hit_at = now end
    self:apply_hit(game, id, e, m, now)
    -- Its reaction goes out with the next tick, not after the state interval.
    if net ~= nil then
        self.state_due = true
        net.ack = m.seq
    end
end

-- Positions of enemies the partner hit in the last `window` seconds (for shot tracers).
function EnemyNet:recent_partner_hits(now, window)
    local out = {}
    for _, h in ipairs(self.recent_hits) do
        if now - h.time <= window then out[#out + 1] = h end
    end
    return out
end

-- Client: damage our puppets took that none of our forwarded hits explains goes to the host.
function EnemyNet:check_puppet_damage(now)
    if self.role ~= "client" then return end
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        local net = l.net_id and self.nets[l.net_id]
        if e.alive then
            if net ~= nil and not l.self_killed then
                local expected = l.expected_hp
                if expected ~= nil and e.hp < expected - HP_EPS then
                    local unexplained = (expected - e.hp) - (l.hit_dropped or 0)
                    if unexplained > HP_EPS then self:report_damage(net, e, l, now, e.hp + unexplained, false) end
                end
            end
            l.hit_dropped = 0
            l.expected_hp = e.hp
        end
    end
end

-------------------------------------------------------------------------------
-- Finishers
-------------------------------------------------------------------------------

-- Client: our player started finishers on these puppets (their AI head answered from the
-- host's information and did nothing itself): the host's game runs them.
-- events = { {id, kind (P.FATAL_KIND), ftype, pos, yaw}, ... }
function EnemyNet:on_local_fatal(events, now)
    if self.role ~= "client" then return end
    for _, ev in ipairs(events or {}) do
        local l = self.locals[ev.id]
        local e = self.by_id[ev.id]
        local net = l and l.net_id and self.nets[l.net_id]
        if net ~= nil and e ~= nil and e.alive then
            self.send(self.P.encode_enemy_fatal({ net_id = net.net_id, epoch = net.epoch, uid = e.uid,
                kind_hash = e.kind_hash, kind = ev.kind, ftype = ev.ftype, pos = ev.pos, yaw = ev.yaw }), true)
            self:note_hit(net, self.me, now)
            self.counters.fatals_sent = self.counters.fatals_sent + 1
            self.log("enemy %s: finisher by our player - run by the host", tostring(net.net_id))
        else
            self.counters.fatals_unpaired = self.counters.fatals_unpaired + 1
        end
    end
end

-- Host: the client's player started a finisher on one of our enemies: our enemy's AI head is
-- asked the same, with the client's character as the attacker.
function EnemyNet:on_partner_fatal(m, now, game)
    self.counters.fatals_received = self.counters.fatals_received + 1
    local net = m.net_id ~= 0 and self.nets[m.net_id] or nil
    if net ~= nil and net.uid ~= nil and m.uid ~= nil and net.uid ~= m.uid then net = nil end
    local id = self:resolve(net and net.net_id or nil, m.uid, m.kind_hash, nil)
    local e = id and self.by_id[id]
    if e == nil or not e.alive or game == nil or game.enemy_partner_fatal == nil then
        self.counters.fatals_failed = self.counters.fatals_failed + 1
        return
    end
    local l = self.locals[id]
    if l ~= nil then l.partner_hit_at = now end
    self:note_hit(net, self.partner, now)
    if game:enemy_partner_fatal(id, m.kind, m.ftype) then
        self.counters.fatals_applied = self.counters.fatals_applied + 1
        self.state_due = true
    else
        self.counters.fatals_failed = self.counters.fatals_failed + 1
    end
end

-- Host: what each enemy near the client's character says about it (P.PARTNER_INFO bits and
-- the finisher type it offers), sent with its state.
function EnemyNet:update_partner_info(game, players)
    if self.role ~= "host" or game == nil or game.enemy_partner_info == nil then return end
    local ppos = players and players.partner_pos or nil
    local targeting = 0
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        l.pinfo, l.ftype = nil, nil
        if e.alive and ppos ~= nil and l.net_id ~= nil then
            local d = dist(e.pos, ppos)
            if d <= PARTNER_TARGET_RANGE then
                local pinfo, ftype = game:enemy_partner_info(id, d <= PARTNER_INFO_RANGE)
                l.pinfo, l.ftype = pinfo, ftype
                if pinfo ~= nil then
                    self.counters.partner_info = self.counters.partner_info + 1
                    if (pinfo & self.P.PARTNER_INFO.TARGETS) ~= 0 then targeting = targeting + 1 end
                end
            end
        end
    end
    self.targeting_partner = targeting
end

-- Host: the wire identity of local enemy `id`: net_id, uid, kind_hash (nil if unknown).
function EnemyNet:net_of_local(id)
    local l = self.locals[id]
    if l == nil then return nil end
    return l.net_id, l.uid or nil, l.kind_hash
end

-- Client: our copy of the host's enemy net_id / uid (nil when we have none).
function EnemyNet:local_of_net(net_id, uid)
    return self:resolve(net_id ~= 0 and net_id or nil, uid, nil, nil)
end

-- Client: what the host's enemy (our local copy `id`) says about our player: pinfo, ftype, or
-- nil when the host has not said (no fresh state of it).
function EnemyNet:partner_fatal(id)
    local l = self.locals[id]
    local net = l and l.net_id and self.nets[l.net_id]
    local st = net and net.newest
    if st == nil or net.updated == nil or (self.last_tick or 0) - net.updated > REMOTE_STALE then return nil end
    return st.pinfo or 0, st.ftype or 0
end

-------------------------------------------------------------------------------
-- Streams
-------------------------------------------------------------------------------

-- Host: whether the state (animation layers, visibility) of local enemy `id` must be read:
-- the client has a copy of it.
function EnemyNet:wants_state(id)
    if self.role ~= "host" then return false end
    local l = self.locals[id]
    local net = l and l.net_id and self.nets[l.net_id]
    local r = net and net.roster
    return r ~= nil and (self.last_tick or 0) - r.time <= ROSTER_STALE
end

function EnemyNet:send_states(now)
    if self.role ~= "host" then return end
    local hz = self.settings.snapshot_hz or 20
    local interval = 1.0 / hz
    if now - self.last_state_send < interval and not self.state_due then return end
    -- Keep the rate exact (not slowed down by the frame rate), without bursts after a gap.
    if self.state_due and now - self.last_state_send < interval then
        self.last_state_send = now
        self.counters.states_early = (self.counters.states_early or 0) + 1
    else
        self.last_state_send = (now - self.last_state_send >= 2 * interval) and now or (self.last_state_send + interval)
    end
    self.state_due = nil
    local entries = {}
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local e = id and self.by_id[id]
        if e ~= nil and e.alive then
            local l = self.locals[id]
            entries[#entries + 1] = {
                net_id = net.net_id, epoch = net.epoch, uid = e.uid, kind_hash = e.kind_hash, pos = e.pos, rot = e.rot,
                vel = l.vel, hp = e.hp, max_hp = e.max_hp, alive = true, hidden = e.hidden == true,
                spawn = l.spawn, ack = net.ack, layers = e.layers, pinfo = l.pinfo, ftype = l.ftype,
            }
        end
    end
    table.sort(entries, function(a, b) return a.net_id < b.net_id end)
    -- Always at least one (possibly empty) message: the client sees we are alive.
    for _, msg in ipairs(self.P.encode_enemy_states(now, entries)) do self.send(msg, false) end
    self.counters.states_sent = self.counters.states_sent + 1
end

function EnemyNet:on_states(m, now, game)
    if self.role ~= "client" then return end
    self.counters.states_received = self.counters.states_received + 1
    for _, r in ipairs(m.enemies) do self:client_on_state(r, m.time, now, game) end
end

function EnemyNet:push_state(net, remote_time, now, r)
    net.interp = net.interp or self:new_buffer()
    net.interp:push(remote_time, now, { pos = r.pos, rot = r.rot, layers = r.layers })
    net.newest = r
    net.updated = now
end

function EnemyNet:client_on_state(r, remote_time, now, game)
    local net = self.nets[r.net_id]
    if net ~= nil and ((net.uid ~= r.uid) or net.kind_hash ~= r.kind_hash) then
        -- The host gave this number to another enemy: the old pairing is void.
        self:unpair(net)
        self.nets[r.net_id] = nil
        net = nil
    end
    local dead_at = self:died_at(r.uid, r.net_id)
    if dead_at ~= nil and now - dead_at < REVIVE_GUARD then return end -- sent before the death notice
    if r.uid ~= nil and dead_at ~= nil then
        self:unbury(r.uid) -- alive in the host's world again
        if game ~= nil and game.enemy_restore_spawns ~= nil then game:enemy_restore_spawns(r.uid) end
    end
    if net == nil then
        net = self:new_net(r.net_id, r.uid, r.kind_hash, r.spawn or r.pos)
    end
    if epoch_newer(r.epoch, net.epoch) then
        net.epoch = r.epoch
    elseif r.epoch ~= net.epoch then
        return -- from an older numbering
    end
    self:push_state(net, remote_time, now, r)
end

-- Client: pair the host's enemies with ours (by uid, else by kind and spawn point). One our
-- game spawned for the host's world starts where the host's is (its HP follows the host's).
function EnemyNet:pair_remote(game)
    local taken = {}
    for id, l in pairs(self.locals) do
        if l.net_id ~= nil and self.nets[l.net_id] ~= nil then taken[id] = true end
    end
    local unpaired = {}
    for net_id, net in pairs(self.nets) do
        if net.local_id == nil or self.by_id[net.local_id] == nil then unpaired[#unpaired + 1] = net_id end
    end
    table.sort(unpaired)
    for _, net_id in ipairs(unpaired) do
        local net = self.nets[net_id]
        net.local_id = nil
        local id
        if net.uid ~= nil then
            id = self.id_of_uid[net.uid]
            local e = id and self.by_id[id]
            if e == nil or taken[id] or not e.alive or e.kind_hash ~= net.kind_hash then id = nil end
            if id ~= nil then self.counters.uid_pairs = self.counters.uid_pairs + 1 end
        elseif net.newest ~= nil then
            id = self:find_spatial(net.kind_hash, net.spawn or net.newest.pos, net.newest.pos, taken, true)
            if id ~= nil then self.counters.spatial_pairs = self.counters.spatial_pairs + 1 end
        end
        if id ~= nil then
            self:pair(net, id)
            taken[id] = true
            -- It waited unseen until now (or was just spawned here): it starts where the host's is.
            self:place_at_host(net, id, game)
            if net.uid ~= nil and self.revived[net.uid] ~= nil then
                self.revived[net.uid] = nil
                self.counters.revived = (self.counters.revived or 0) + 1
            end
        end
    end
end

-- Client: the host's enemies our game has not spawned at all - our save says they died (a
-- save from another session), we erased them, or their spawn was never permitted here (a
-- trigger only the host's player crossed). The host's world decides which enemies exist:
-- after MISSING_AFTER our game is asked to spawn them (game:enemy_revive); they pair by uid
-- and follow the host's like any other. Only level enemies (a uid), within reach of our
-- player, never one whose body or corpse we still have, nor one that just died here.
function EnemyNet:spawn_missing(now, game, local_pos)
    if game == nil or game.enemy_revive == nil or self.settings.enemy_spawn_missing == false then return end
    for uid, t in pairs(self.died_here) do
        if now - t > DIED_HERE_GUARD then self.died_here[uid] = nil end
    end
    for uid, t in pairs(self.revived) do
        if now - t > 30 then self.revived[uid] = nil end -- never showed up
    end
    local budget = REVIVE_PER_TICK
    for _, net in pairs(self.nets) do
        local st = net.newest
        local wanted = net.uid ~= nil and net.local_id == nil and st ~= nil
            and net.updated ~= nil and now - net.updated < REMOTE_STALE and self.id_of_uid[net.uid] == nil
            and self.died_here[net.uid] == nil
        if not wanted then
            net.missing_since = nil
        else
            net.missing_since = net.missing_since or now
            if budget > 0 and now - net.missing_since >= MISSING_AFTER and now >= (net.revive_at or 0)
                and (local_pos == nil or dist(st.pos, local_pos) <= SPAWN_RANGE) then
                budget = budget - 1
                net.revive_at = now + REVIVE_RETRY
                local r = game:enemy_revive(net.uid)
                local key = "spawn_" .. tostring(r)
                self.counters[key] = (self.counters[key] or 0) + 1
                if r == "spawning" then self.revived[net.uid] = now end
                if r == "spawning" or r == "forgotten" then
                    self.log("enemy %s: alive in the host's world but not in ours - spawning it", tostring(net.net_id))
                end
            end
        end
    end
end

-- Client: our copy, just paired, stands where the host's enemy is.
function EnemyNet:place_at_host(net, id, game)
    local e, st = self.by_id[id], net.newest
    if e == nil or st == nil or game == nil or game.enemy_set_transform == nil then return end
    if dist(e.pos, st.pos) <= MIRROR_MIN_MOVE then return end
    if game:enemy_set_transform(id, st.pos, st.rot) then
        e.pos, e.rot = copy3(st.pos), st.rot
        local l = self.locals[id]
        if l ~= nil then l.prev_pos = copy3(st.pos) end
        self.counters.placed = (self.counters.placed or 0) + 1
    end
end

function EnemyNet:send_roster(now)
    if self.role ~= "client" then return end
    local hz = self.settings.roster_hz or 5
    local interval = 1.0 / hz
    if now - self.last_roster_send < interval then return end
    self.last_roster_send = (now - self.last_roster_send >= 2 * interval) and now or (self.last_roster_send + interval)
    local P = self.P
    local entries = {}
    for net_id, net in pairs(self.nets) do
        local e = net.local_id and self.by_id[net.local_id]
        if e ~= nil and e.alive then
            entries[#entries + 1] = { net_id = net_id, flags = P.ROSTER_FLAGS.ALIVE, hp = e.hp }
        end
    end
    table.sort(entries, function(a, b) return a.net_id < b.net_id end)
    for _, msg in ipairs(P.encode_enemy_roster(now, entries)) do self.send(msg, false) end
end

function EnemyNet:host_on_roster(m, now)
    for _, r in ipairs(m.entries) do
        local net = self.nets[r.net_id]
        if net ~= nil then
            net.roster = { time = now, hp = r.hp, alive = r.alive }
            net.client_knows = true
        end
    end
end

-- Client: the host's numbering of its enemies.
function EnemyNet:client_on_owner(m)
    local P = self.P
    for _, o in ipairs(m.owners) do
        local net = self.nets[o.net_id]
        if o.owner == P.OWNER.NONE then
            -- The host no longer has this enemy: our copy waits, still and unseen (control).
            if net ~= nil and (o.uid == nil or net.uid == o.uid) then
                self:unpair(net)
                self.nets[o.net_id] = nil
            end
        elseif net ~= nil and (o.uid == nil or net.uid == nil or net.uid == o.uid) then
            if epoch_newer(o.epoch, net.epoch) then net.epoch = o.epoch end
        end
    end
end

-------------------------------------------------------------------------------
-- The graveyard (host)
-------------------------------------------------------------------------------

-- A client asked for the graveyard (joining, or its game reloaded): the deaths we saw plus
-- every enemy our save has eliminated. Reading the save's backups takes a few ticks.
function EnemyNet:request_graveyard(now)
    if self.role ~= "host" then return end
    self.grave_scan = { since = now }
end

function EnemyNet:send_graveyard(extra)
    local uids, seen = {}, {}
    for uid in pairs(self.dead) do
        uids[#uids + 1] = uid
        seen[uid] = true
    end
    for _, uid in ipairs(extra or {}) do
        if not seen[uid] then
            uids[#uids + 1] = uid
            seen[uid] = true
        end
    end
    table.sort(uids)
    for _, msg in ipairs(self.P.encode_enemy_grave(uids)) do self.send(msg, true) end
    self.counters.graves_sent = self.counters.graves_sent + 1
end

function EnemyNet:update_graveyard_scan(game)
    if self.grave_scan == nil then return end
    local done, uids = true, nil
    if game ~= nil and game.scan_eliminated ~= nil then done, uids = game:scan_eliminated(GRAVE_SCAN_BUDGET) end
    if done then
        self.grave_scan = nil
        self:send_graveyard(uids)
    end
end

function EnemyNet:client_on_grave(m, now)
    if m.chunk == 1 then
        self.grave, self.grave_count = {}, 0
        self.counters.graves_received = self.counters.graves_received + 1
    end
    for _, uid in ipairs(m.uids) do self:bury(uid, now) end
end

-- Client: an enemy died in the host's game (or the host's world reset).
function EnemyNet:on_death(m, now, game)
    if self.role ~= "client" then return end
    self.counters.deaths_received = self.counters.deaths_received + 1
    if m.reset then
        -- The host reloaded a checkpoint: its dead are alive again, and its enemies have new numbers.
        self.grave, self.grave_count, self.dead_net = {}, 0, {}
        -- What we erased because it was dead there may spawn here again.
        if game ~= nil and game.enemy_restore_spawns ~= nil then game:enemy_restore_spawns(nil) end
        for _, net in pairs(self.nets) do self:unpair(net) end
        self.nets = {}
        return
    end
    local net = m.net_id ~= 0 and self.nets[m.net_id] or nil
    if net ~= nil and net.uid ~= nil and m.uid ~= nil and net.uid ~= m.uid then net = nil end
    self:bury(m.uid, now)
    if m.uid == nil and m.net_id ~= 0 then self.dead_net[m.net_id] = now end
    local id = self:resolve(net and net.net_id or nil, m.uid, m.kind_hash, m.pos)
    if id == nil then return end -- not loaded here: the graveyard removes it when it shows up
    local l = self.locals[id]
    if l == nil or l.self_killed then return end
    if m.erased then
        local e = self.by_id[id]
        if e ~= nil and e.alive then self:remove_dead(game, id, e, now, nil) end
        return
    end
    self:kill_here(game, id, now, m.pos, m.rot, m.fields, m.by_client)
end

-------------------------------------------------------------------------------
-- Tick
-------------------------------------------------------------------------------

-- Our game reloaded (checkpoint, death): every enemy we knew belonged to the old scene (the
-- adapter switched every head and animation driver it had off back on). Host: the enemies
-- came back, so the old deaths no longer describe our world and the client forgets them too.
-- Client: the host's world did not change - its graveyard applies to what our level spawns again.
function EnemyNet:on_local_reload()
    self.locals, self.by_id, self.id_of_uid = {}, {}, {}
    for _, net in pairs(self.nets) do net.local_id = nil end
    if self.role == "host" then
        self.nets, self.owner_changes = {}, {}
        self.retired = {}
        self.reloaded, self.corpse_guard_until = true, nil
        self.dead, self.dead_count = {}, 0
        self.send(self.P.encode_enemy_reset(), true)
    end
end

-- players = { local_pos={x,y,z}|nil, partner_pos={x,y,z}|nil (the partner's character in our
-- world), loading (our area is loading), other_region (the partner is in another region) }.
function EnemyNet:tick(now, enemies, game, players)
    self.last_tick = now
    local local_pos = players and players.local_pos or nil
    for seq, pr in pairs(self.predicted) do
        if now - pr.time > 5.0 then self.predicted[seq] = nil end
    end
    self:observe(now, enemies)
    self:check_vanished_deaths(now, game)
    self:check_puppet_damage(now)

    if self.role == "host" then
        -- Every enemy of ours gets a number; enemies we lost give theirs back.
        for _, e in ipairs(enemies) do
            local l = self.locals[e.id]
            if l.net_id == nil or self.nets[l.net_id] == nil then
                local net_id = self:alloc_net_id(now)
                if net_id ~= nil then
                    local net = self:new_net(net_id, e.uid, e.kind_hash, l.spawn)
                    self:pair(net, e.id)
                end
            end
        end
        for _, net in pairs(self.nets) do
            if net.local_id == nil or self.locals[net.local_id] == nil then self:retire(net, now) end
        end
        self:assign_new(now, game)
        self:flush_owner_changes()
        self:update_graveyard_scan(game)
        self:update_partner_info(game, players)
    else
        for net_id, net in pairs(self.nets) do
            if net.updated ~= nil and now - net.updated > REMOTE_STALE then
                -- The host no longer sends it: gone from its world (our copy waits, unseen).
                self:unpair(net)
                self.nets[net_id] = nil
            end
        end
        for net_id, t in pairs(self.dead_net) do
            if now - t > 60 then self.dead_net[net_id] = nil end
        end
        self:pair_remote(game)
        if not (players and (players.loading or players.other_region)) then self:spawn_missing(now, game, local_pos) end
    end

    self:update_deaths(now, game, local_pos)
    self:control(game)
    if game ~= nil and self.role == "client" then
        self:reconcile_hp(now, game)
        self:apply_anims(now, game)
    end
    self:send_states(now)
    self:send_roster(now)
end

-- Returns true if the message was an enemy message (consumed).
function EnemyNet:on_message(m, now, game)
    local T = self.P.T
    if m.type == T.ENEMY_STATE then
        self:on_states(m, now, game)
    elseif m.type == T.ENEMY_HIT then
        self:on_partner_hit(m, now, game)
    elseif m.type == T.ENEMY_DEATH then
        self:on_death(m, now, game)
    elseif m.type == T.ENEMY_OWNER then
        if self.role == "client" then self:client_on_owner(m) end
    elseif m.type == T.ENEMY_ROSTER then
        if self.role == "host" then self:host_on_roster(m, now) end
    elseif m.type == T.ENEMY_GRAVE then
        if self.role == "client" then self:client_on_grave(m, now) end
    elseif m.type == T.ENEMY_FATAL then
        if self.role == "host" then self:on_partner_fatal(m, now, game) end
    else
        return false
    end
    return true
end

function EnemyNet:summary()
    local n_local, n_uid, n_paired, n_puppets, n_held = 0, 0, 0, 0, 0
    for id, e in pairs(self.by_id) do
        n_local = n_local + 1
        if e.uid ~= nil then n_uid = n_uid + 1 end
        local l = self.locals[id]
        if l.puppet then n_puppets = n_puppets + 1 end
        if l.hidden then n_held = n_held + 1 end
    end
    local now = self.last_tick or 0
    for _, net in pairs(self.nets) do
        local e = net.local_id and self.by_id[net.local_id]
        local paired = e ~= nil
        if self.role == "host" then
            paired = paired and net.roster ~= nil and now - net.roster.time <= ROSTER_STALE
        end
        if paired and e.alive then n_paired = n_paired + 1 end
    end
    local targeting = self.targeting_partner
    if self.role == "client" then
        targeting = 0
        for _, net in pairs(self.nets) do
            local st = net.newest
            if st ~= nil and st.pinfo ~= nil and (st.pinfo & self.P.PARTNER_INFO.TARGETS) ~= 0
                and net.updated ~= nil and now - net.updated <= REMOTE_STALE then
                targeting = targeting + 1
            end
        end
    end
    return { role = self.role, authority = "host", local_count = n_local, with_uid = n_uid, paired = n_paired,
        puppets = n_puppets, held = n_held, targeting_partner = targeting or 0,
        dead_known = self.role == "host" and self.dead_count or self.grave_count,
        listing_dead = self.grave_scan ~= nil, counters = self.counters }
end

return EnemyNet
