-- Enemy networking (protocol 9): one shared set of enemies for both games.
--
-- Both games load the same chapter, so each level spawns the same enemies on both machines.
-- This module keeps the two copies of every enemy one enemy (the RE4 facts behind it are in
-- docs/RESEARCH.md 3.8-3.10):
--
--   * Identity. A level enemy's own ContextID is the serialized ContextID of the spawn param
--     that created it: level data, the same on both PCs. Its code (`uid`) pairs the two copies
--     exactly, wherever each game placed them. Runtime enemies (no uid) pair by kind and spawn
--     point. The host numbers its enemies for the wire (net ids); the client pairs its copies
--     with those numbers.
--
--   * Authority. Every enemy has exactly one owner: the game that runs its AI, movement,
--     health and death. The other game shows a puppet: AI head off, the body's own animation
--     driver locked, and position, full rotation, animation layers (motion, frame, speed),
--     visibility and HP taken from the owner's stream. The host decides who owns what and
--     tells the client (ENEMY_OWNER); every change of owner bumps the enemy's ownership
--     *epoch*, and state or hits of an older epoch are ignored, so two games never run one
--     enemy at the same time. With enemy_authority = "shared" (default) an enemy goes to the
--     player it is closer to (with a margin, a hold time and a minimum time with its owner),
--     so enemies fight both players: RE4's AI can only target the player of its own game. With
--     "host" the host's game runs every enemy.
--
--   * State. The owner sends the full state of its enemies ~20 times a second (ENEMY_STATE):
--     position, rotation, velocity, HP, max HP, visibility and up to three animation layers.
--     The puppet follows it through an interpolation buffer (transform every frame, animation
--     corrected when it drifts more than a few frames).
--
--   * Damage. A hit our player lands on an enemy the partner owns is sent to the owner
--     (ENEMY_HIT) with every value of the game's DamageInfo, and the owner runs it through its
--     own hit code: same damage, same reaction (flinch, stagger, knock-down, part breaks), same
--     result. On our side the hit happens too (blood, sounds, part breaks) but can never kill
--     the puppet: the owner decides. Our HP follows the owner's, and is not raised again until
--     the owner acknowledged the hit. Damage our puppet takes from anything else (explosions,
--     falls) is reported to the owner as well.
--
--   * Finishers. A stealth kill, grab, knife finish or stomp is asked of the enemy's own AI
--     head (PlayerHeadUpdater.requestFatal & co.), which a puppet has switched off: the request
--     would wait while the owner's game ran the enemy on (it chased the other player and died
--     only when it changed hands). The game whose player starts one takes the enemy over at
--     once - the host directly, the client with ENEMY_CLAIM (its game runs the enemy from that
--     moment; the host hands it over) - and keeps it while the finisher plays out.
--
--   * Death. Only the owner decides a death and announces it (ENEMY_DEATH) with where it
--     happened and the killing hit; the other game puts its copy there and kills it with that
--     same hit (so the death reaction and the loot happen in both games). Deaths are final in
--     both directions: the host keeps the list of every enemy dead in its world ("graveyard":
--     the deaths it saw, the client's kills, and for a joining client every enemy its save
--     has eliminated), and an enemy dead in the partner's world is removed wherever it shows
--     up: in front of the player it dies, just spawned or far away it is erased the way the
--     game removes a finished enemy (no corpse, never comes back).
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
--   game:enemy_kill(id, fields|nil) -> bool         (dies with its own logic; with the killing hit if given)
--   game:enemy_erase(id) -> bool                    (optional: removed without a death)
--   game:enemy_restore_spawns(uid|nil) -> n          (optional: undo enemy_erase - alive again)
--   game:enemy_apply_hit(id, hit) -> bool           (optional: runs a partner's hit through the game's hit code)
--   game:enemy_last_hit(id) -> fields|nil           (optional: the values of the last hit it took)
--   game:enemy_set_puppet(id, on) -> bool           (optional: AI head and animation driver off/on)
--   game:enemy_set_transform(id, pos, rot) -> bool  (optional)
--   game:enemy_set_anim(id, layers) -> bool         (optional)
--   game:enemy_set_visible(id, on) -> bool          (optional)
--   game:scan_eliminated(budget) -> done, uids      (optional, host: enemies dead in its save)
--   on_local_fatal(ids): the enemies our player started a finisher on (game:take_fatal_events;
--   the adapter switches such a puppet back on when may_fatal(id) allows it)

local Interp = require("re4coop.interp")

local EnemyNet = {}
EnemyNet.__index = EnemyNet

local HP_EPS = 0.01
local FORGET_AFTER = 5.0       -- seconds an enemy may be missing from our list before it is forgotten
local RETIRED_HOLD = 10.0      -- host: a retired net id is not handed out again for this long
local REMOTE_STALE = 2.0       -- an enemy the partner owns without news for this long is gone there
local ROSTER_STALE = 1.5       -- host: a client report older than this no longer counts
local PENDING_TIMEOUT = 1.0    -- a hit we forwarded and the owner did not acknowledge stops holding our HP
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
local SNAP_EXTRAPOLATE = 0.25  -- seconds of velocity used when taking an enemy over
-- Ownership (host, shared authority).
local OWN_MARGIN = 3.0         -- metres the other player must be closer by before an enemy changes hands
local OWN_HOLD = 0.75          -- seconds that must last
local OWN_MIN = 2.5            -- seconds an enemy stays with its owner at least
local HIT_BIAS = 4.0           -- metres of advantage for the player who hit it last...
local HIT_BIAS_TIME = 3.0      -- ...within this many seconds
local OWN_MAX_RANGE = 80.0     -- a player farther than this from the enemy never gets it
local FATAL_HOLD = 10.0        -- seconds an enemy stays with the player finishing it (stealth kill, grab...)
local CLAIM_WAIT = 1.5         -- client: seconds a claimed enemy runs here before the host's answer

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function copy3(v)
    return { x = v.x, y = v.y, z = v.z }
end

-- u8 ownership epochs: is `a` newer than `b`? (0 = never assigned; the host skips it on wrap)
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

-- Puppet states: position and rotation blend; each animation layer blends its frame while
-- both snapshots play the same motion, otherwise it takes the nearer snapshot's.
local function blend_state(sa, sb, t)
    local out = Interp.blend(sa, sb, t)
    local la, lb = sa.layers or {}, sb.layers or {}
    local layers = {}
    for i = 1, math.max(#la, #lb) do
        local a, b = la[i], lb[i]
        if a ~= nil and b ~= nil and a.bank == b.bank and a.id == b.id and b.frame >= a.frame then
            layers[i] = { bank = a.bank, id = a.id, frame = a.frame + (b.frame - a.frame) * t, speed = b.speed }
        else
            layers[i] = (t < 0.5 and a or b) or a or b
        end
    end
    out.layers = layers
    return out
end

-- opts: { role="host"|"client", protocol=<protocol module>, send=function(bytes, reliable),
--         settings=<table read live>, log=function(fmt, ...),
--         on_kill=function(local_id, now) (optional: an enemy died here because the partner's game killed it) }
-- settings: sync_enemies, enemy_authority ("shared"|"host"), enemy_mirror, enemy_motion_sync,
--           enemy_erase, enemy_hit_predict, enemy_interp_delay, snapshot_hz, roster_hz
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
    self.locals = {}       -- local id -> record (see track)
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
    self.grave_scan = nil
    self.corpse_guard_until = nil
    self.reloaded = nil

    self.counters = { states_sent = 0, states_received = 0, uid_pairs = 0, spatial_pairs = 0, owner_changes = 0,
        taken_over = 0, handed_over = 0, hits_sent = 0, hits_forwarded = 0, hits_received = 0, hits_applied = 0,
        hits_fallback = 0, hits_bounced = 0, hits_unmatched = 0, damage_reported = 0, hp_applied = 0, hp_failed = 0,
        deaths_sent = 0, deaths_received = 0, kills_applied = 0, erased = 0, late_kills = 0, buried = 0,
        graves_sent = 0, graves_received = 0, moves = 0, anims = 0, puppet_switches = 0, held = 0, retired = 0,
        fatals = 0, claims_sent = 0, claims_granted = 0, claims_refused = 0 }
end

function EnemyNet:kind_hash(kind)
    local h = self.kind_hashes[kind]
    if h == nil then
        h = self.P.hash(kind)
        self.kind_hashes[kind] = h
    end
    return h
end

function EnemyNet:shared()
    return self.settings.enemy_authority ~= "host"
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
-- Shared enemies (net ids) and ownership
-------------------------------------------------------------------------------

function EnemyNet:new_buffer()
    local delay = tonumber(self.settings.enemy_interp_delay) or MIRROR_DELAY
    return Interp.new({ delay = delay, max_delay = math.max(0.25, delay), adaptive = true, max_extrapolate = 0.2,
        capacity = 16, blend = blend_state })
end

-- A shared enemy: { net_id, uid|nil, kind_hash, spawn, owner, epoch (0 = never assigned),
-- local_id, interp, newest (the partner's latest state), updated, ack (owner: the last of the
-- partner's hits applied), pending ({seq, time}: our last forwarded hit), last_hit {who, time} }
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

-- Whether our game runs this shared enemy's AI. Host: everything it has not handed to the
-- client. Client: what the host handed it, and (shared authority) its own copies the host has
-- not assigned yet.
function EnemyNet:runs_here(net)
    if self.role == "host" then return net.owner == self.P.OWNER.HOST end
    if net.epoch == 0 then return self:shared() end
    return net.owner == self.P.OWNER.CLIENT
end

-- Whether our game is this enemy's authority: it sends its state and decides its death.
function EnemyNet:authority_here(net)
    if self.role == "host" then return net.owner == self.P.OWNER.HOST end
    return net.epoch ~= 0 and net.owner == self.P.OWNER.CLIENT
end

-- Whether a hit on it must be run by the partner's game.
function EnemyNet:partner_owns(net)
    if self.role == "host" then return net.owner == self.P.OWNER.CLIENT end
    return net.owner == self.P.OWNER.HOST -- (unassigned = the host's)
end

-- Takes an enemy over: our copy continues from the partner's latest state.
function EnemyNet:take_over(net, game, now, hp)
    local id = net.local_id
    local e = id and self.by_id[id]
    local st = net.newest
    local l = id and self.locals[id]
    if e ~= nil and e.alive and game ~= nil then
        -- (an enemy we claimed already runs here, in the middle of our player's finisher: it
        -- stays where it is)
        if st ~= nil and net.updated ~= nil and game.enemy_set_transform ~= nil and not self:claimed(l) then
            local age = math.min(SNAP_EXTRAPOLATE, math.max(0, now - net.updated))
            local v = st.vel or { x = 0, y = 0, z = 0 }
            local pos = { x = st.pos.x + v.x * age, y = st.pos.y + v.y * age, z = st.pos.z + v.z * age }
            if game:enemy_set_transform(id, pos, st.rot) then
                e.pos, e.rot = pos, st.rot
            end
        end
        local target = hp or (st and st.hp)
        if target ~= nil and target > HP_EPS and math.abs(e.hp - target) > HP_EPS then
            target = math.min(target, e.hp) -- taking over never heals: damage stays done
            if game:enemy_set_hp(id, target) then e.hp = target end
        end
        self:set_puppet(game, id, false)
        if self.locals[id] then self.locals[id].expected_hp = e.hp end
    end
    net.interp, net.newest, net.pending = nil, nil, nil
    self.counters.taken_over = self.counters.taken_over + 1
end

-- The partner's game runs this enemy from now on.
function EnemyNet:hand_over(net, game)
    net.interp, net.newest, net.pending = nil, nil, nil
    net.ack = 0
    if net.local_id ~= nil then self:set_puppet(game, net.local_id, true) end
    self.counters.handed_over = self.counters.handed_over + 1
end

-- Applies an owner assignment (both roles).
function EnemyNet:set_owner(net, owner, epoch, game, now, hp)
    local was_here = self:runs_here(net)
    local was_owner, was_epoch = net.owner, net.epoch
    net.owner, net.epoch = owner, epoch
    net.owner_since = now
    local claimed_l = net.local_id and self.locals[net.local_id]
    if was_owner == owner and was_epoch ~= 0 then
        if claimed_l ~= nil then claimed_l.claim_until = nil end
        return
    end
    self.counters.owner_changes = self.counters.owner_changes + 1
    if owner == self.me then
        -- A copy our game already ran (an unassigned one) simply goes on; a puppet continues
        -- from where the partner's enemy is.
        if not was_here then self:take_over(net, game, now, hp) end
        if hp ~= nil and net.local_id ~= nil then
            -- The host's HP when it handed the enemy over (it may have taken damage there).
            local e = self.by_id[net.local_id]
            if e ~= nil and e.alive and hp > HP_EPS and hp < e.hp - HP_EPS and game:enemy_set_hp(net.local_id, hp) then
                e.hp = hp
                self.locals[net.local_id].expected_hp = hp
            end
        end
        -- Ours now, and already dead here without its death ever announced (it died while it
        -- was the partner's - a report that crossed the change of hands): ours to announce.
        local e = net.local_id and self.by_id[net.local_id]
        if e ~= nil and not e.alive and claimed_l ~= nil and claimed_l.was_alive == false
            and not claimed_l.death_sent and not claimed_l.self_killed then
            self:announce_death(game, net.local_id, e, net, now)
        end
    else
        -- Hits our player landed while our game still ran it, after the host's last look at
        -- it (`hp`: its HP when it decided), would be lost: they go to the new owner.
        local e = net.local_id and self.by_id[net.local_id]
        local l = net.local_id and self.locals[net.local_id]
        if hp ~= nil and e ~= nil and e.alive and was_here and was_epoch ~= 0 and e.hp < hp - HP_EPS then
            self:report_damage(net, e, l, now, hp, false)
        end
        self:hand_over(net, game)
    end
    if claimed_l ~= nil then claimed_l.claim_until = nil end -- the host answered our claim
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

-- Host: a shared enemy left our world (unloaded, despawned): its number is free again, and
-- the client stops pairing it.
function EnemyNet:retire(net, now)
    self.nets[net.net_id] = nil
    self.retired[net.net_id] = now
    if net.client_knows then
        self.owner_changes[#self.owner_changes + 1] = { net_id = net.net_id, epoch = net.epoch,
            owner = self.P.OWNER.NONE, uid = net.uid }
        self.counters.retired = self.counters.retired + 1
    end
end

function EnemyNet:assign(net, owner, now, hp)
    net.epoch = net.epoch % 255 + 1
    self.owner_changes[#self.owner_changes + 1] = { net_id = net.net_id, epoch = net.epoch, owner = owner,
        uid = net.uid, hp = hp }
    net.last_transfer = now
    net.want = nil
end

-- Host: who should run each enemy the client has a copy of.
function EnemyNet:decide_owners(now, game, players)
    local P = self.P
    local host_pos = players and players.local_pos or nil
    local client_pos = players and not players.partner_busy and players.partner_pos or nil
    local shared = self:shared() and client_pos ~= nil and host_pos ~= nil
    for _, net in pairs(self.nets) do
        local e = net.local_id and self.by_id[net.local_id]
        local r = net.roster
        local has_copy = r ~= nil and now - r.time <= ROSTER_STALE and r.alive
        if e ~= nil and e.alive then
            local desired = P.OWNER.HOST
            if has_copy and shared then
                local dh, dc = dist(e.pos, host_pos), dist(e.pos, client_pos)
                local lh = net.last_hit
                if lh ~= nil and now - lh.time <= HIT_BIAS_TIME then
                    if lh.who == P.OWNER.HOST then dh = dh - HIT_BIAS else dc = dc - HIT_BIAS end
                end
                if dc > OWN_MAX_RANGE then
                    desired = P.OWNER.HOST
                elseif net.epoch == 0 then
                    desired = dc < dh and P.OWNER.CLIENT or P.OWNER.HOST
                elseif net.owner == P.OWNER.HOST then
                    desired = (dc + OWN_MARGIN < dh) and P.OWNER.CLIENT or P.OWNER.HOST
                else
                    desired = (dh + OWN_MARGIN < dc) and P.OWNER.HOST or P.OWNER.CLIENT
                end
            end
            -- A finisher in progress keeps the enemy with the player doing it.
            local f = net.fatal
            if f ~= nil and now >= f.till then net.fatal, f = nil, nil end
            if f ~= nil and (f.who == P.OWNER.HOST or has_copy) then desired = f.who end
            if net.epoch == 0 then
                if has_copy then
                    -- First assignment, at once. The client's copy may have been fought already
                    -- (it ran there before our level spawned it): damage done stays done.
                    local hp = e.hp
                    if r.hp ~= nil and r.hp > HP_EPS and r.hp < e.hp - HP_EPS and desired == P.OWNER.HOST
                        and game ~= nil and game:enemy_set_hp(net.local_id, r.hp) then
                        e.hp = r.hp
                        hp = r.hp
                    end
                    self:assign(net, desired, now, hp)
                    self:set_owner(net, desired, net.epoch, game, now)
                end
            elseif not has_copy then
                if net.owner == P.OWNER.CLIENT and (r == nil or now - r.time > ROSTER_STALE) then
                    -- The client lost its copy (its area unloaded, its game reloaded): ours runs again.
                    self:assign(net, P.OWNER.HOST, now, e.hp)
                    self:set_owner(net, P.OWNER.HOST, net.epoch, game, now)
                end
            elseif desired ~= net.owner then
                if net.want == nil or net.want.owner ~= desired then net.want = { owner = desired, since = now } end
                if now - net.want.since >= OWN_HOLD and now - (net.last_transfer or -math.huge) >= OWN_MIN then
                    local hp = e.hp
                    if desired == P.OWNER.HOST and net.newest ~= nil then hp = net.newest.hp end
                    self:assign(net, desired, now, hp)
                    self:set_owner(net, desired, net.epoch, game, now)
                end
            else
                net.want = nil
            end
        end
    end
end

function EnemyNet:flush_owner_changes()
    if #self.owner_changes == 0 then return end
    for _, msg in ipairs(self.P.encode_enemy_owners(self.owner_changes)) do self.send(msg, true) end
    self.owner_changes = {}
end

-------------------------------------------------------------------------------
-- Puppets
-------------------------------------------------------------------------------

-- Our copy's own AI and animation driver off (a puppet of the partner's) or on.
function EnemyNet:set_puppet(game, id, on)
    local l = self.locals[id]
    if l == nil or game == nil then return end
    if on then
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

-- Puts each local enemy in the hands it belongs to.
function EnemyNet:control(game)
    local mirror = self:mirroring(game)
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        local net = l.net_id and self.nets[l.net_id]
        if not e.alive or l.self_killed or l.removing ~= nil then
            if l.puppet or l.hidden then self:release(game, id) end
        elseif not mirror then
            if l.puppet or l.hidden then self:release(game, id) end
        elseif net ~= nil then
            if self:runs_here(net) or self:claimed(l) then
                self:release(game, id)
            else
                self:set_puppet(game, id, true)
                local st = net.newest
                self:set_visible(game, id, not (st ~= nil and st.hidden))
            end
        elseif self.role == "client" and not self:shared() then
            -- Host authority: the host's game does not run this one (not loaded there, or not
            -- paired yet). It waits, still and unseen, until the host's shows up.
            if not l.puppet or not l.hidden then self.counters.held = self.counters.held + 1 end
            self:set_puppet(game, id, true)
            self:set_visible(game, id, false)
        else
            self:release(game, id)
        end
    end
end

-- The partner's state onto our puppets' HP (owner's HP wins, but our own forwarded hits keep
-- it from going back up until the owner acknowledged them).
function EnemyNet:reconcile_hp(now, game)
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local e = id and self.by_id[id]
        local st = net.newest
        local l = id and self.locals[id]
        if e ~= nil and e.alive and st ~= nil and st.alive and not self:runs_here(net) and not self:claimed(l) then
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

-- Every frame: puppets stand where the partner's enemies are.
function EnemyNet:frame(now, game)
    if not self:mirroring(game) then return end
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local l = id and self.locals[id]
        if l ~= nil and l.puppet and net.interp ~= nil and not self:runs_here(net) then
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

-- Animation layers onto our puppets (at the tick rate: the game plays the motion on between
-- corrections, the adapter only steps in when a layer plays something else or drifted).
function EnemyNet:apply_anims(now, game)
    if self.settings.enemy_motion_sync == false or game.enemy_set_anim == nil or not self:mirroring(game) then return end
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local l = id and self.locals[id]
        if l ~= nil and l.puppet and net.interp ~= nil and not self:runs_here(net) then
            local age = net.interp:age(now)
            local st = age ~= nil and age < REMOTE_STALE and net.interp:sample(now) or nil
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

-- Kills our copy because the partner's world decided its death: at the place it died, with
-- the hit that killed it. Returns true if it died.
function EnemyNet:kill_here(game, id, now, pos, rot, fields)
    local e = self.by_id[id]
    local l = self.locals[id]
    if e == nil or l == nil or not e.alive or game == nil then return false end
    self:release(game, id)
    if pos ~= nil and game.enemy_set_transform ~= nil and dist(e.pos, pos) < 30 then
        if game:enemy_set_transform(id, pos, rot) then e.pos, e.rot = copy3(pos), rot end
    end
    l.removing = { time = now, how = "kill" }
    if game:enemy_kill(id, fields) then
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
    if game:enemy_kill(id, nil) then
        l.self_killed = true
        e.hp, e.alive = 0, false
        l.was_alive = false
        self.counters.kills_applied = self.counters.kills_applied + 1
        self.on_kill(id, now)
        return true
    end
    return false
end

-- An enemy whose death we decide died in our world: tell the partner (with where it died and
-- the hit that killed it).
function EnemyNet:announce_death(game, id, e, net, now)
    local l = self.locals[id]
    local fields = game ~= nil and game.enemy_last_hit ~= nil and game:enemy_last_hit(id) or nil
    self.send(self.P.encode_enemy_death({
        net_id = net and net.net_id or 0, epoch = net and net.epoch or 0, uid = e.uid, kind_hash = e.kind_hash,
        pos = e.pos, rot = e.rot, fields = fields,
    }), true)
    self.counters.deaths_sent = self.counters.deaths_sent + 1
    if self.role == "host" then self:bury(e.uid, now, "host") end
    if net ~= nil and self.role == "client" then self.dead_net[net.net_id] = now end
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
        if was_alive == true and not e.alive and not l.self_killed and not l.death_sent then
            -- It died in our world. Ours to decide: the owner's death, or (no owner yet) a death
            -- in a game that ran it, or one our player's finisher took over (claimed: the host's
            -- answer may still be on its way). A puppet's death is the owner's call: it is
            -- reported as damage.
            if net == nil or self:authority_here(net) or (net.epoch == 0 and self:runs_here(net)) or self:claimed(l) then
                if net ~= nil or e.uid ~= nil then self:announce_death(game, id, e, net, now) end
            elseif net ~= nil then
                self:report_damage(net, e, l, now, l.expected_hp or e.max_hp, true)
            end
        elseif was_alive == nil and not e.alive and e.uid ~= nil and self.role == "host"
            and now >= self.corpse_guard_until and (self.dead[e.uid] == nil or self.dead[e.uid].by ~= "host") then
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
    if net ~= nil then net.last_hit = { who = who, time = now } end
end

-- Damage our puppet took that the owner must apply (no hit of ours explains it: an explosion,
-- a fall...). Sent as a hit without values (the owner subtracts HP).
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
-- critical, lethal, fields}, ... }. A hit on an enemy the partner runs is sent for the owner to
-- apply; any other is sent so the partner can draw it (shot tracer).
function EnemyNet:on_local_hits(events, now)
    local P = self.P
    for _, ev in ipairs(events or {}) do
        local l = self.locals[ev.id]
        local e = self.by_id[ev.id]
        local net = l and l.net_id and self.nets[l.net_id]
        if l ~= nil and e ~= nil then
            if net ~= nil and self:partner_owns(net) and not self:claimed(l) then
                local seq = self:next_seq()
                local flags = P.HIT_FLAGS.APPLY | (ev.lethal and P.HIT_FLAGS.LETHAL or 0)
                self.send(P.encode_enemy_hit({
                    net_id = net.net_id, epoch = net.epoch, flags = flags, critical = ev.critical, uid = e.uid,
                    kind_hash = e.kind_hash, pos = l.spawn or e.pos, damage = ev.damage or 0, hp = ev.hp or e.hp,
                    seq = seq, fields = ev.fields,
                }), true)
                net.pending = { seq = seq, time = now }
                self.predicted[seq] = { amount = ev.local_damage or 0, time = now }
                -- What the hit took here is ours, not damage to report again.
                l.hit_dropped = (l.hit_dropped or 0) + (ev.local_damage or 0)
                self:note_hit(net, self.me, now)
                self.counters.hits_forwarded = self.counters.hits_forwarded + 1
            elseif net ~= nil or e.uid ~= nil then
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

-- Runs a partner's hit on our enemy (we own it): through the game's hit code, else as HP.
function EnemyNet:apply_hit(game, id, e, m, now)
    if game.enemy_apply_hit ~= nil and m.fields ~= nil and #m.fields > 0 and game:enemy_apply_hit(id, m) then
        self.counters.hits_applied = self.counters.hits_applied + 1
        local hp = game.enemy_get_hp and game:enemy_get_hp(id) or nil
        if hp ~= nil then e.hp = hp end
        return true
    end
    -- No hit code to run it through (or a plain damage report): the HP is what counts. A
    -- report that our enemy died in the partner's game (its copy there died of something we
    -- cannot replay) is a death: dead stays dead.
    local cur = game.enemy_get_hp ~= nil and game:enemy_get_hp(id) or e.hp
    local new_hp = cur - (m.damage or 0)
    self.counters.hits_fallback = self.counters.hits_fallback + 1
    if new_hp <= HP_EPS or (m.lethal and (m.fields == nil or #m.fields == 0)) then
        if game:enemy_kill(id, m.fields) then
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
    local P = self.P
    local net = m.net_id ~= 0 and self.nets[m.net_id] or nil
    if net ~= nil and ((net.uid ~= nil and m.uid ~= nil and net.uid ~= m.uid) or net.kind_hash ~= m.kind_hash) then
        net = nil -- a number since given to another enemy
    end
    local id = self:resolve(net and net.net_id or nil, m.uid, m.kind_hash, m.pos)
    local e = id and self.by_id[id]
    if e == nil then
        self.counters.hits_unmatched = self.counters.hits_unmatched + 1
        -- A kill in the partner's game of an enemy ours has not loaded: dead in the shared world.
        if self.role == "host" and m.apply and m.lethal and m.uid ~= nil
            and (self.dead[m.uid] == nil or self.dead[m.uid].by ~= "host") then
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
    if not (m.apply or m.bounce) or not e.alive or game == nil then return end

    if net ~= nil and m.bounce and self.role == "client" and epoch_newer(m.epoch, net.epoch) then
        -- The host sent our hit back because the enemy is ours now (its notice is still on the way).
        self:set_owner(net, self.P.OWNER.CLIENT, m.epoch, game, now)
    end
    local ours = net == nil or self:runs_here(net)
    if net ~= nil and self.role == "client" and net.epoch == 0 then ours = false end
    if ours then
        if m.bounce then
            -- Our own hit, back to us: it already took its HP here; it runs in full now.
            local pr = self.predicted[m.seq]
            if pr ~= nil and pr.amount > HP_EPS and game:enemy_set_hp(id, e.hp + pr.amount) then
                e.hp = e.hp + pr.amount
            end
            self.predicted[m.seq] = nil
        end
        self:apply_hit(game, id, e, m, now)
        if net ~= nil and not m.bounce then net.ack = m.seq end
        if net ~= nil and m.bounce then net.pending = nil end
    elseif net ~= nil and not m.bounce then
        -- The partner thought we run it, but it changed hands meanwhile: it runs it now.
        m.flags = (m.flags & ~P.HIT_FLAGS.APPLY) | P.HIT_FLAGS.BOUNCE
        m.epoch = net.epoch
        self.send(P.encode_enemy_hit(m), true)
        self.counters.hits_bounced = self.counters.hits_bounced + 1
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

-- Damage our puppets took that none of our forwarded hits explains goes to the owner.
function EnemyNet:check_puppet_damage(now)
    for id, e in pairs(self.by_id) do
        local l = self.locals[id]
        local net = l.net_id and self.nets[l.net_id]
        if e.alive then
            if net ~= nil and not self:runs_here(net) and not l.self_killed and not self:claimed(l) then
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

-- Client: whether our game runs this enemy because our player started a finisher on it and the
-- host has not answered yet.
function EnemyNet:claimed(l)
    return l ~= nil and l.claim_until ~= nil and (self.last_tick or 0) <= l.claim_until
end

-- Whether our game may take enemy `id` over for a finisher our player starts on it (the
-- adapter switches a puppet back on right away when it may).
function EnemyNet:may_fatal(id)
    if self.role ~= "host" and not self:shared() then return false end -- host authority: never here
    local e = self.by_id[id]
    return e ~= nil and e.alive
end

-- Our player started a finisher on these local enemies: their game is ours now.
function EnemyNet:on_local_fatal(ids, now, game)
    local P = self.P
    for _, id in ipairs(ids or {}) do
        local l = self.locals[id]
        local e = self.by_id[id]
        local net = l and l.net_id and self.nets[l.net_id]
        if net ~= nil and e ~= nil and e.alive and self:may_fatal(id) then
            self.counters.fatals = self.counters.fatals + 1
            if self.role == "host" then
                net.fatal = { who = P.OWNER.HOST, till = now + FATAL_HOLD }
                if net.owner ~= P.OWNER.HOST then
                    self:assign(net, P.OWNER.HOST, now, e.hp)
                    self:set_owner(net, P.OWNER.HOST, net.epoch, game, now)
                end
            else
                if not self:runs_here(net) then
                    l.claim_until = now + CLAIM_WAIT
                    self:set_puppet(game, id, false)
                end
                -- (also when it is ours already: the host keeps it with us while it plays out)
                self.send(P.encode_enemy_claim({ net_id = net.net_id, epoch = net.epoch }), true)
                self.counters.claims_sent = self.counters.claims_sent + 1
            end
            self.log("enemy %s: finisher by our player - %s", tostring(net.net_id),
                self.role == "host" and "taken over" or "claimed from the host")
        end
    end
end

-- Host: the client's player started a finisher on one of our enemies.
function EnemyNet:host_on_claim(m, now, game)
    local P = self.P
    local net = self.nets[m.net_id]
    local e = net and net.local_id and self.by_id[net.local_id]
    local f = net and net.fatal
    if net == nil or e == nil or not e.alive or not self:shared()
        or (f ~= nil and f.who == P.OWNER.HOST and now < f.till) then
        -- Gone, dead, host authority, or our own player is finishing it: it stays ours (the
        -- client's claim runs out and its copy follows ours again).
        self.counters.claims_refused = self.counters.claims_refused + 1
        return
    end
    net.fatal = { who = P.OWNER.CLIENT, till = now + FATAL_HOLD }
    if net.owner ~= P.OWNER.CLIENT then
        self:assign(net, P.OWNER.CLIENT, now, e.hp)
        self:set_owner(net, P.OWNER.CLIENT, net.epoch, game, now)
    else
        -- Already the client's: confirm it (the claim may have crossed our notice).
        self.owner_changes[#self.owner_changes + 1] = { net_id = net.net_id, epoch = net.epoch,
            owner = P.OWNER.CLIENT, uid = net.uid, hp = e.hp }
    end
    self.counters.claims_granted = self.counters.claims_granted + 1
end

-------------------------------------------------------------------------------
-- Streams
-------------------------------------------------------------------------------

-- Whether the state (animation layers, visibility) of local enemy `id` must be read: we run
-- it and the partner has a copy of it.
function EnemyNet:wants_state(id)
    local l = self.locals[id]
    local net = l and l.net_id and self.nets[l.net_id]
    if net == nil or not self:authority_here(net) then return false end
    if self.role == "client" then return true end
    local r = net.roster
    return r ~= nil and (self.last_tick or 0) - r.time <= ROSTER_STALE
end

function EnemyNet:send_states(now)
    local hz = self.settings.snapshot_hz or 20
    local interval = 1.0 / hz
    if now - self.last_state_send < interval then return end
    -- Keep the rate exact (not slowed down by the frame rate), without bursts after a gap.
    self.last_state_send = (now - self.last_state_send >= 2 * interval) and now or (self.last_state_send + interval)
    local entries = {}
    for _, net in pairs(self.nets) do
        local id = net.local_id
        local e = id and self.by_id[id]
        if e ~= nil and e.alive and self:authority_here(net) then
            local l = self.locals[id]
            entries[#entries + 1] = {
                net_id = net.net_id, epoch = net.epoch, uid = e.uid, kind_hash = e.kind_hash, pos = e.pos, rot = e.rot,
                -- (an enemy we hid ourselves a moment ago is not hidden by its game)
                vel = l.vel, hp = e.hp, max_hp = e.max_hp, alive = true, hidden = e.hidden == true and not l.hidden,
                spawn = l.spawn, ack = net.ack, layers = e.layers,
            }
        end
    end
    table.sort(entries, function(a, b) return a.net_id < b.net_id end)
    -- Always at least one (possibly empty) message: the partner sees we are alive.
    for _, msg in ipairs(self.P.encode_enemy_states(now, entries)) do self.send(msg, false) end
    self.counters.states_sent = self.counters.states_sent + 1
end

function EnemyNet:on_states(m, now, game)
    self.counters.states_received = self.counters.states_received + 1
    for _, r in ipairs(m.enemies) do
        if self.role == "host" then
            local net = self.nets[r.net_id]
            if net ~= nil and net.owner == self.P.OWNER.CLIENT and r.epoch == net.epoch and r.alive then
                self:push_state(net, m.time, now, r)
            end
        else
            self:client_on_state(r, m.time, now, game)
        end
    end
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
        self:set_owner(net, self.P.OWNER.HOST, r.epoch, game, now, r.hp)
    elseif r.epoch ~= net.epoch then
        return -- from before an owner change
    end
    if net.owner ~= self.P.OWNER.HOST then return end
    self:push_state(net, remote_time, now, r)
end

-- Client: pair the host's enemies with ours (by uid, else by kind and spawn point).
function EnemyNet:pair_remote()
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
        end
    end
end

function EnemyNet:send_roster(now)
    local hz = self.settings.roster_hz or 5
    local interval = 1.0 / hz
    if now - self.last_roster_send < interval then return end
    self.last_roster_send = (now - self.last_roster_send >= 2 * interval) and now or (self.last_roster_send + interval)
    local P = self.P
    local entries = {}
    for net_id, net in pairs(self.nets) do
        local e = net.local_id and self.by_id[net.local_id]
        if e ~= nil and e.alive then
            local flags = P.ROSTER_FLAGS.ALIVE
            if net.epoch == 0 and self:runs_here(net) then flags = flags | P.ROSTER_FLAGS.LOCAL_RUN end
            entries[#entries + 1] = { net_id = net_id, flags = flags, hp = e.hp }
        end
    end
    table.sort(entries, function(a, b) return a.net_id < b.net_id end)
    for _, msg in ipairs(P.encode_enemy_roster(now, entries)) do self.send(msg, false) end
end

function EnemyNet:host_on_roster(m, now)
    local seen = {}
    for _, r in ipairs(m.entries) do
        local net = self.nets[r.net_id]
        if net ~= nil then
            net.roster = { time = now, hp = r.hp, alive = r.alive, local_run = r.local_run }
            net.client_knows = true
            seen[r.net_id] = true
        end
    end
end

-- Client: an owner assignment from the host.
function EnemyNet:client_on_owner(m, now, game)
    local P = self.P
    for _, o in ipairs(m.owners) do
        local net = self.nets[o.net_id]
        if o.owner == P.OWNER.NONE then
            -- The host no longer has this enemy: our copy is on its own again.
            if net ~= nil and (o.uid == nil or net.uid == o.uid) then
                local id = net.local_id
                self:unpair(net)
                self.nets[o.net_id] = nil
                if id ~= nil then self:release(game, id) end
            end
        elseif net ~= nil and (o.uid == nil or net.uid == nil or net.uid == o.uid) then
            if epoch_newer(o.epoch, net.epoch) then self:set_owner(net, o.owner, o.epoch, game, now, o.hp) end
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

function EnemyNet:on_death(m, now, game)
    self.counters.deaths_received = self.counters.deaths_received + 1
    if m.reset then
        -- The host reloaded a checkpoint: its dead are alive again, and its enemies have new numbers.
        self.grave, self.grave_count, self.dead_net = {}, 0, {}
        -- What we erased because it was dead there may spawn here again.
        if game ~= nil and game.enemy_restore_spawns ~= nil then game:enemy_restore_spawns(nil) end
        for _, net in pairs(self.nets) do
            if net.local_id ~= nil then self:release(game, net.local_id) end
            self:unpair(net)
        end
        self.nets = {}
        return
    end
    local net = m.net_id ~= 0 and self.nets[m.net_id] or nil
    if net ~= nil and net.uid ~= nil and m.uid ~= nil and net.uid ~= m.uid then net = nil end
    if self.role == "host" then
        if m.uid ~= nil and (self.dead[m.uid] == nil or self.dead[m.uid].by ~= "host") then
            self:bury(m.uid, now, "client")
        end
    else
        self:bury(m.uid, now)
        if m.uid == nil and m.net_id ~= 0 then self.dead_net[m.net_id] = now end
    end
    local id = self:resolve(net and net.net_id or nil, m.uid, m.kind_hash, m.pos)
    if id == nil then return end -- not loaded here: the graveyard removes it when it shows up
    local l = self.locals[id]
    if l == nil or l.self_killed then return end
    if m.erased then
        local e = self.by_id[id]
        if e ~= nil and e.alive then self:remove_dead(game, id, e, now, nil) end
        return
    end
    self:kill_here(game, id, now, m.pos, m.rot, m.fields)
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

-- players = { local_pos={x,y,z}|nil, partner_pos={x,y,z}|nil }: where both players are
-- (ownership, and how an enemy dead in the partner's world goes).
function EnemyNet:tick(now, enemies, game, players)
    self.last_tick = now
    local local_pos = players and players.local_pos or nil
    for seq, pr in pairs(self.predicted) do
        if now - pr.time > 5.0 then self.predicted[seq] = nil end
    end
    self:observe(now, enemies)
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
        for _, net in pairs(self.nets) do
            if net.owner == self.P.OWNER.CLIENT and net.updated ~= nil and now - net.updated > REMOTE_STALE then
                net.roster = nil -- no news from the client about it: ours again (decide_owners)
            end
        end
        self:decide_owners(now, game, players)
        self:flush_owner_changes()
        self:update_graveyard_scan(game)
    else
        for net_id, net in pairs(self.nets) do
            if net.owner == self.P.OWNER.HOST and net.updated ~= nil and now - net.updated > REMOTE_STALE then
                -- The host no longer sends it: gone from its world.
                local id = net.local_id
                self:unpair(net)
                self.nets[net_id] = nil
                if id ~= nil then self:release(game, id) end
            end
        end
        for net_id, t in pairs(self.dead_net) do
            if now - t > 60 then self.dead_net[net_id] = nil end
        end
        self:pair_remote()
    end

    self:update_deaths(now, game, local_pos)
    self:control(game)
    if game ~= nil then
        self:reconcile_hp(now, game)
        self:apply_anims(now, game)
    end
    self:send_states(now)
    if self.role == "client" then self:send_roster(now) end
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
        if self.role == "client" then self:client_on_owner(m, now, game) end
    elseif m.type == T.ENEMY_ROSTER then
        if self.role == "host" then self:host_on_roster(m, now) end
    elseif m.type == T.ENEMY_GRAVE then
        if self.role == "client" then self:client_on_grave(m, now) end
    elseif m.type == T.ENEMY_CLAIM then
        if self.role == "host" then self:host_on_claim(m, now, game) end
    else
        return false
    end
    return true
end

function EnemyNet:summary()
    local n_local, n_uid, n_paired, n_here, n_partner, n_puppets, n_held = 0, 0, 0, 0, 0, 0, 0
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
        if paired and e.alive then
            n_paired = n_paired + 1
            if self:runs_here(net) then n_here = n_here + 1 else n_partner = n_partner + 1 end
        end
    end
    return { role = self.role, authority = self:shared() and "shared" or "host", local_count = n_local,
        with_uid = n_uid, paired = n_paired, run_here = n_here, run_by_partner = n_partner, puppets = n_puppets,
        held = n_held, dead_known = self.role == "host" and self.dead_count or self.grave_count,
        listing_dead = self.grave_scan ~= nil, counters = self.counters }
end

return EnemyNet
