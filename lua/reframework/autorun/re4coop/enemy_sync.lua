-- Enemy synchronisation: the host's game runs every enemy; the client's game shows them.
--
-- Both games load the same chapter, so the level spawns the same enemies on both machines.
-- The host is the single authority (the RE4 facts behind it: docs/RESEARCH.md 3.8):
--   * Identity: every enemy the level places carries the ContextID of the spawn param that
--     created it, which is level data and therefore the same on both PCs. Its code (`uid`)
--     pairs the host's enemy with the client's copy exactly - whatever position, spawn point
--     or order each game spawned it in. Enemies created at runtime (no uid) are paired by
--     kind and position.
--   * Movement and AI: the host's AI runs every enemy, all the time - an enemy never changes
--     hands. The client's copy of each enemy the host has is a puppet: its own AI is switched
--     off, and its position, facing and animation follow the host's enemy through an
--     interpolation buffer. Enemies the host has not loaded (yet) run in the client's game
--     with their own AI until the host's level spawns them.
--   * Health: the host's HP is applied to the client's copies. Damage the client's player
--     deals is sent to the host and applied there.
--   * Deaths: the host keeps the list of enemies dead in its world ("the graveyard"): every
--     death it sees, every kill the client makes, and - for a joining client - every enemy
--     its save already has eliminated (CharacterManager's backup table). The client removes
--     those enemies wherever they show up in its own world: one dying in front of the player
--     dies with its own death animation (and loot); one that only now spawned, or is far
--     away, is removed the way the game removes a finished enemy (eliminated + despawned), so
--     it never appears and never comes back. Kills the client makes where the host has not
--     loaded the enemy wait in the host's graveyard until its level spawns it.
--   * Hits: each side sends the hits its own player lands (ENEMY_HIT: shot tracers and,
--     experimental, a cosmetic replay on the other side's copy).
--
-- Game access goes through an adapter (see game.lua) so this file is pure Lua and is
-- tested offline against fake worlds (tests/lua/test_enemy_sync.lua).
--
-- Adapter contract:
--   enemies = { {id=<number>, kind=<string>, uid=<level identity or nil>, pos={x,y,z},
--               yaw=<number>, hp=<number>, max_hp=<number>, alive=<bool>,
--               motion={bank,id,frame}|nil}, ... }  (passed to tick)
--   game:enemy_set_hp(id, hp) -> bool
--   game:enemy_kill(id) -> bool                    (the enemy dies with its own logic)
--   game:enemy_erase(id) -> bool                   (optional: removed without dying)
--   game:enemy_get_hp(id) -> number|nil            (optional: current HP, fresher than the last list)
--   game:enemy_replay_hit(id, hit) -> ok, kept     (optional, experimental)
--   game:enemy_set_transform(id, pos, yaw) -> bool (optional, client: puppets follow the host)
--   game:enemy_set_motion(id, motion) -> bool      (optional, client: puppets play the host's animation)
--   game:enemy_set_ai(id, on) -> bool              (optional, client: a puppet's own AI is off)
--   game:scan_eliminated(budget) -> done, uids     (optional, host: enemies dead in its save)

local Interp = require("re4coop.interp")

local EnemySync = {}
EnemySync.__index = EnemySync

local HP_EPS = 0.01
local FORGET_AFTER = 5.0          -- seconds an enemy may be missing from the list before we forget it
local CREDIT_SECONDS = 2.0        -- HP a replay could not put back is not reported as our damage
local MAX_RECENT_HITS = 16        -- partner hits kept for drawing shot tracers
local PAIRED_TIMEOUT = 1.5        -- host: a client report older than this no longer counts
local REMOTE_STALE = 2.0          -- client: a host enemy not in a snapshot for this long is gone
local MIRROR_DELAY = 0.1          -- default interpolation delay of the client's puppets
local MIRROR_STALE = 1.0          -- a puppet without news from the host for this long runs its own AI
local MIRROR_MIN_MOVE = 0.01      -- metres; smaller corrections are not written
local MATCH_RADIUS = 3.0          -- enemies without a uid: same kind within this of the spawn point
local SEEN_BEFORE = 1.0           -- an enemy known this long and this close dies visibly...
local VISIBLE_RADIUS = 40.0       -- ...when the partner's world has it dead; otherwise it is erased
local REVIVE_GUARD = 2.0          -- seconds after a death during which "alive" snapshots are stale
local GRAVE_SCAN_BUDGET = 48      -- host: save backups read per tick while listing the dead
local REMOVE_RETRY = 1.0          -- seconds before an enemy that refused to die is tried again
local ERASE_VERIFY = 3.0          -- an erased enemy still alive after this long is killed instead
local CORPSE_GUARD = 3.0          -- host: seconds after our own reload before corpses are news

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function copy3(v)
    return { x = v.x, y = v.y, z = v.z }
end

-- Puppet states blend position and facing (the short way round) and take the animation from
-- the nearer snapshot.
local function blend_enemy(sa, sb, t)
    local d = ((sb.yaw or 0) - (sa.yaw or 0) + math.pi) % (2 * math.pi) - math.pi
    return {
        pos = {
            x = sa.pos.x + (sb.pos.x - sa.pos.x) * t,
            y = sa.pos.y + (sb.pos.y - sa.pos.y) * t,
            z = sa.pos.z + (sb.pos.z - sa.pos.z) * t,
        },
        yaw = ((sa.yaw or 0) + d * t + math.pi) % (2 * math.pi) - math.pi,
        motion = t < 0.5 and sa.motion or sb.motion,
    }
end

-- opts: { role="host"|"client", protocol=<protocol module>, send=function(bytes, reliable),
--         settings=<table read live>, log=function(fmt, ...),
--         on_kill=function(local_id, now) (optional: an enemy died here because the partner's game killed it) }
-- settings: sync_enemies, enemy_mirror, enemy_motion_sync, enemy_erase, enemy_interp_delay,
--           snapshot_hz, client_enemy_hz, replay_partner_hits
function EnemySync.new(opts)
    local self = setmetatable({}, EnemySync)
    self.role = opts.role
    self.P = opts.protocol
    self.send = opts.send
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
    self.on_kill = opts.on_kill or function() end
    self:reset()
    return self
end

function EnemySync:reset()
    self.kind_hashes = {}   -- kind string -> hash (cache)
    self.spawn = {}         -- local id -> first-seen position
    self.first_seen = {}    -- local id -> time it was first seen
    self.last_seen = {}     -- local id -> time
    self.by_id = {}         -- local id -> latest enemy record
    self.uid_of = {}        -- local id -> uid it was first seen with
    self.id_of_uid = {}     -- uid -> local id (from the latest list)

    -- host
    self.net_of = {}        -- local id -> net id
    self.local_of = {}      -- net id -> local id
    self.alive_of = {}      -- local id -> last known alive flag
    self.next_net_id = 1
    self.last_snapshot = -math.huge
    self.client_paired = {} -- net id -> time the client last reported having a copy
    self.dead = {}          -- uid -> { time, by = "host"|"client" }: dead in the host's world
    self.dead_count = 0
    self.grave_scan = nil   -- a client asked for the graveyard: { since } while the backups are read
    self.corpse_guard_until = nil -- set on the first tick: corpses seen before this are not news
    self.reloaded = nil

    -- client
    self.remote = {}        -- net id -> latest host entry (+ .updated, .interp)
    self.grave = {}         -- uid -> time it was buried (dead in the host's world)
    self.grave_count = 0
    self.dead_net = {}      -- net id -> time: host deaths of enemies without a uid
    self.expected_hp = {}   -- local id -> HP we have already accounted for
    self.self_killed = {}   -- local ids we killed or erased for the host (don't report them back)
    self.last_client_send = -math.huge

    -- both
    self.removing = {}      -- local id -> {time, how = "erase"|"kill"}: our last try to remove it (dead in the partner's world)
    self.mirror_motion = {} -- local id -> "bank:id" last applied
    self.ai_off = {}        -- local id -> true while its AI is switched off (a puppet of the host's enemy)
    self.hit_credit = {}    -- local id -> {amount, time}
    self.recent_hits = {}   -- partner hits: {pos, time}

    self.counters = { damage_sent = 0, damage_applied = 0, damage_failed = 0, kills_applied = 0, erased = 0,
        hp_applied = 0, hp_failed = 0, snaps = 0, uid_pairs = 0, spatial_pairs = 0, hits_sent = 0,
        hits_received = 0, hits_replayed = 0, hits_unmatched = 0, mirrored = 0, motions = 0, ai_switched = 0,
        late_kills = 0, buried = 0, graves_sent = 0, graves_received = 0 }
end

function EnemySync:kind_hash(kind)
    local h = self.kind_hashes[kind]
    if h == nil then
        h = self.P.hash(kind)
        self.kind_hashes[kind] = h
    end
    return h
end

-- Drops everything we knew about local enemy `id` (it is gone, or its context now holds
-- another enemy).
function EnemySync:forget(id)
    self.last_seen[id] = nil
    self.spawn[id] = nil
    self.first_seen[id] = nil
    self.uid_of[id] = nil
    self.expected_hp[id] = nil
    self.self_killed[id] = nil
    self.alive_of[id] = nil
    self.mirror_motion[id] = nil
    self.ai_off[id] = nil
    self.removing[id] = nil
    self.hit_credit[id] = nil
    local net_id = self.net_of[id]
    if net_id ~= nil then
        self.net_of[id] = nil
        if self.local_of[net_id] == id then self.local_of[net_id] = nil end
    end
end

-- Records per-enemy bookkeeping shared by both roles.
function EnemySync:observe(now, enemies)
    local by_id, id_of_uid = {}, {}
    for _, e in ipairs(enemies) do
        e.kind_hash = e.kind_hash or self:kind_hash(e.kind)
        local known = self.last_seen[e.id] ~= nil
        if known and (self.uid_of[e.id] ~= (e.uid or false) or (self.by_id[e.id] and self.by_id[e.id].kind ~= e.kind)) then
            -- The game reused this context for another enemy.
            self:forget(e.id)
            known = false
        end
        if not known then
            self.spawn[e.id] = copy3(e.pos)
            self.first_seen[e.id] = now
            self.uid_of[e.id] = e.uid or false
        end
        self.last_seen[e.id] = now
        by_id[e.id] = e
        if e.uid ~= nil then
            -- Two contexts with one uid (a corpse and its successor): the living one counts.
            local other = id_of_uid[e.uid]
            if other == nil or (e.alive and not by_id[other].alive) then id_of_uid[e.uid] = e.id end
        end
    end
    self.by_id = by_id
    self.id_of_uid = id_of_uid

    for id, t in pairs(self.last_seen) do
        if now - t > FORGET_AFTER then self:forget(id) end
    end
    return by_id
end

-- The closest local enemy of the same kind without a uid whose spawn (or current position)
-- is within MATCH_RADIUS: how enemies created at runtime are paired. `taken` excludes
-- enemies already paired.
function EnemySync:find_spatial(kind_hash, spawn_pos, cur_pos, taken, want_alive)
    local best, best_d = nil, math.huge
    for id, e in pairs(self.by_id) do
        if e.uid == nil and e.kind_hash == kind_hash and not taken[id] and (not want_alive or e.alive) then
            local d = dist(self.spawn[id] or e.pos, spawn_pos)
            if cur_pos ~= nil then d = math.min(d, dist(e.pos, cur_pos)) end
            if d <= MATCH_RADIUS and d < best_d then
                best, best_d = id, d
            end
        end
    end
    return best
end

-- The local enemy a partner message refers to: by net id pairing, by uid, or (enemies
-- without a uid, host side) by kind and spawn point.
function EnemySync:resolve(net_id, uid, kind_hash, pos)
    local id = (net_id ~= nil and net_id ~= 0) and self.local_of[net_id] or nil
    if id ~= nil and self.by_id[id] ~= nil then return id end
    if uid ~= nil then
        id = self.id_of_uid[uid]
        if id ~= nil then return id end
        return nil
    end
    if self.role == "host" and kind_hash ~= nil and pos ~= nil then
        return self:find_spatial(kind_hash, pos, pos, {}, true)
    end
    return nil
end

-------------------------------------------------------------------------------
-- Removing enemies that are dead in the partner's world (both roles)
-------------------------------------------------------------------------------

-- The enemy dies here because it is dead in the partner's world. One the player has been
-- near for a while dies visibly with its own logic (animation, ragdoll, loot); one that only
-- just spawned, or is far away, is erased: it simply never shows up. Called on every tick
-- while the enemy is still listed alive: a kill the game refused is tried again, and an
-- erase that did not despawn it becomes a kill. Returns true when an action was taken.
function EnemySync:remove_dead(game, id, e, now, local_pos)
    if game == nil then return false end
    local r = self.removing[id]
    if r ~= nil then
        local wait = r.how == "erase" and ERASE_VERIFY or REMOVE_RETRY
        if now - r.time < wait then return false end
    end
    local visible = now - (self.first_seen[id] or now) >= SEEN_BEFORE
        and (local_pos == nil or dist(e.pos, local_pos) <= VISIBLE_RADIUS)
    local erase = not visible and (r == nil or r.how ~= "erase")
        and self.settings.enemy_erase ~= false and game.enemy_erase ~= nil
    self:release_mirror(game, id) -- an erased enemy's head goes back to the pool; a dying one needs its AI
    self.removing[id] = { time = now, how = "kill" }
    if erase and game:enemy_erase(id) then
        self.removing[id].how = "erase"
        self.self_killed[id] = true
        self.expected_hp[id] = 0
        e.alive = false
        self.counters.erased = self.counters.erased + 1
        return true
    end
    if game:enemy_kill(id) then
        self.self_killed[id] = true
        self.expected_hp[id] = 0
        e.hp, e.alive = 0, false
        self.counters.kills_applied = self.counters.kills_applied + 1
        self.on_kill(id, now)
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Puppets (client)
-------------------------------------------------------------------------------

-- Whether the client's copies follow the host's enemies (needs the transform writer).
function EnemySync:mirroring(game)
    return self.settings.enemy_mirror ~= false and game ~= nil and game.enemy_set_transform ~= nil
end

function EnemySync:new_buffer()
    local delay = tonumber(self.settings.enemy_interp_delay) or MIRROR_DELAY
    return Interp.new({ delay = delay, max_delay = math.max(0.25, delay), adaptive = true, max_extrapolate = 0.2,
        capacity = 16, blend = blend_enemy })
end

-- Whether this local enemy's animation must be read and sent: host - the client has a copy
-- of it (a puppet that plays it). The client never sends animations.
function EnemySync:wants_motion(id)
    if self.role ~= "host" then return false end
    local net_id = self.net_of[id]
    if net_id == nil then return false end
    local t = self.client_paired[net_id]
    return t ~= nil and (self.last_tick or 0) - t <= PAIRED_TIMEOUT
end

-- Switches a local enemy's own AI off while it is a puppet, and back on when it is not.
function EnemySync:set_ai(game, id, on)
    if game == nil or game.enemy_set_ai == nil then return end
    if on then
        if self.ai_off[id] then
            game:enemy_set_ai(id, true)
            self.ai_off[id] = nil
            self.counters.ai_switched = self.counters.ai_switched + 1
        end
    elseif not self.ai_off[id] then
        if game:enemy_set_ai(id, false) then
            self.ai_off[id] = true
            self.counters.ai_switched = self.counters.ai_switched + 1
        end
    end
end

-- Every local enemy runs its own AI again (mirroring or enemy sync switched off).
function EnemySync:release_all(game)
    for id in pairs(self.ai_off) do self:release_mirror(game, id) end
end

-- Writes the host enemy's transform (and animation) onto our puppet.
function EnemySync:apply_mirror(game, id, e, st)
    self:set_ai(game, id, false)
    if dist(e.pos, st.pos) > MIRROR_MIN_MOVE or math.abs((e.yaw or 0) - (st.yaw or 0)) > 1e-3 then
        if game:enemy_set_transform(id, st.pos, st.yaw) then
            e.pos = copy3(st.pos)
            e.yaw = st.yaw
            self.counters.mirrored = self.counters.mirrored + 1
        end
    end
    if self.settings.enemy_motion_sync ~= false and st.motion ~= nil and game.enemy_set_motion ~= nil then
        local key = ("%d:%d"):format(st.motion.bank or 0, st.motion.id or 0)
        if self.mirror_motion[id] ~= key and game:enemy_set_motion(id, st.motion) then
            self.mirror_motion[id] = key
            self.counters.motions = self.counters.motions + 1
        end
    end
end

-- The enemy is ours to run again: its AI back on, no animation to keep in step with.
function EnemySync:release_mirror(game, id)
    self:set_ai(game, id, true)
    self.mirror_motion[id] = nil
end

-------------------------------------------------------------------------------
-- Hits
-------------------------------------------------------------------------------

function EnemySync:add_credit(id, amount, now)
    local c = self.hit_credit[id]
    if c == nil or now - c.time > CREDIT_SECONDS then c = { amount = 0 } end
    c.amount, c.time = c.amount + amount, now
    self.hit_credit[id] = c
end

-- Returns how much of `amount` is covered by credit (and uses it up).
function EnemySync:take_credit(id, amount, now)
    local c = self.hit_credit[id]
    if c == nil then return 0 end
    if now - c.time > CREDIT_SECONDS then
        self.hit_credit[id] = nil
        return 0
    end
    local used = math.min(c.amount, amount)
    c.amount = c.amount - used
    if c.amount <= HP_EPS then self.hit_credit[id] = nil end
    return used
end

-- events: game:take_hit_events() - hits our player landed. Sent unreliably: a lost hit is
-- only a missed tracer (or flinch, with the experimental replay) on the partner's screen.
function EnemySync:on_local_hits(events, now)
    for _, ev in ipairs(events or {}) do
        local e = self.by_id[ev.id]
        local net_id = self.net_of[ev.id]
        if e ~= nil and (net_id ~= nil or e.uid ~= nil or self.role == "client") then
            self.send(self.P.encode_enemy_hit({
                net_id = net_id or 0, uid = e.uid, kind_hash = e.kind_hash, pos = self.spawn[ev.id] or e.pos,
                damage = ev.damage, wince = ev.wince, break_ = ev.break_, stopping = ev.stopping,
                dir = ev.dir, weapon = ev.weapon, critical = ev.critical,
            }), false)
            self.counters.hits_sent = self.counters.hits_sent + 1
        end
    end
end

function EnemySync:on_partner_hit(m, now, game)
    local id = self:resolve(m.net_id, m.uid, m.kind_hash, m.pos)
    local e = id and self.by_id[id] or nil
    if e == nil then
        self.counters.hits_unmatched = self.counters.hits_unmatched + 1
        return
    end
    self.counters.hits_received = self.counters.hits_received + 1
    local hits = self.recent_hits
    hits[#hits + 1] = { pos = copy3(e.pos), time = now }
    if #hits > MAX_RECENT_HITS then table.remove(hits, 1) end
    if self.settings.replay_partner_hits == true and e.alive and game ~= nil and game.enemy_replay_hit ~= nil then
        local ok, kept = game:enemy_replay_hit(id, m)
        if ok then
            self.counters.hits_replayed = self.counters.hits_replayed + 1
            if kept ~= nil and kept > HP_EPS then self:add_credit(id, kept, now) end
        end
    end
end

-- Positions of enemies the partner hit in the last `window` seconds (for shot tracers).
function EnemySync:recent_partner_hits(now, window)
    local out = {}
    for _, h in ipairs(self.recent_hits) do
        if now - h.time <= window then out[#out + 1] = h end
    end
    return out
end

-------------------------------------------------------------------------------
-- Host
-------------------------------------------------------------------------------

function EnemySync:alloc_net_id()
    for _ = 1, 65535 do
        local id = self.next_net_id
        self.next_net_id = id % 65535 + 1
        if self.local_of[id] == nil then
            return id
        end
    end
    return nil
end

-- Records a death in the host's world.
function EnemySync:bury(uid, now, by)
    if uid == nil then return end
    if self.dead[uid] == nil then
        self.dead_count = self.dead_count + 1
        self.counters.buried = self.counters.buried + 1
    end
    self.dead[uid] = { time = now, by = by }
end

-- A client asked for the graveyard (joining, or its game reloaded): the deaths we saw plus
-- every enemy our save has eliminated. Reading the save's backups takes a few ticks.
function EnemySync:request_graveyard(now)
    if self.role ~= "host" then return end
    self.grave_scan = { since = now }
end

function EnemySync:send_graveyard(extra)
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
    for _, msg in ipairs(self.P.encode_enemy_grave(uids)) do
        self.send(msg, true)
    end
    self.counters.graves_sent = self.counters.graves_sent + 1
end

function EnemySync:host_tick(now, enemies, game, players)
    self:observe(now, enemies)
    local local_pos = players and players.local_pos or nil
    if self.corpse_guard_until == nil then
        -- Just after our own reload the list may still hold the old scene's dead: not news.
        self.corpse_guard_until = self.reloaded and (now + CORPSE_GUARD) or -math.huge
        self.reloaded = nil
    end

    for _, e in ipairs(enemies) do
        local net_id = self.net_of[e.id]
        if net_id == nil then
            net_id = self:alloc_net_id()
            if net_id ~= nil then
                self.net_of[e.id] = net_id
                self.local_of[net_id] = e.id
            end
        end
        local was_alive = self.alive_of[e.id]
        if was_alive == true and not e.alive then
            -- Died in our world (our shot, the client's damage, or the game itself).
            if net_id ~= nil then self.send(self.P.encode_enemy_dead(net_id, e.uid), true) end
            self:bury(e.uid, now, "host")
        elseif was_alive == nil and not e.alive and e.uid ~= nil and now >= self.corpse_guard_until
            and (self.dead[e.uid] == nil or self.dead[e.uid].by ~= "host") then
            -- A corpse: it died in our world before we saw it (before the session, or while
            -- its area was loading). The client's copy may still be alive.
            if net_id ~= nil then self.send(self.P.encode_enemy_dead(net_id, e.uid), true) end
            self:bury(e.uid, now, "host")
        elseif e.alive and e.uid ~= nil then
            local d = self.dead[e.uid]
            if d ~= nil and d.by == "client" then
                -- The client killed it while our level had not spawned it: it dies here now.
                if self:remove_dead(game, e.id, e, now, local_pos) then
                    self.counters.late_kills = self.counters.late_kills + 1
                end
            end
        end
        self.alive_of[e.id] = e.alive
    end

    for net_id, t in pairs(self.client_paired) do
        if now - t > 30 or self.local_of[net_id] == nil then self.client_paired[net_id] = nil end
    end

    -- The graveyard for a client that asked for it.
    if self.grave_scan ~= nil then
        local done, uids = true, nil
        if game ~= nil and game.scan_eliminated ~= nil then
            done, uids = game:scan_eliminated(GRAVE_SCAN_BUDGET)
        end
        if done then
            self.grave_scan = nil
            self:send_graveyard(uids)
        end
    end

    local hz = self.settings.snapshot_hz or 20
    local interval = 1.0 / hz
    if now - self.last_snapshot < interval then
        return
    end
    -- Keep the rate exact (not slowed down by the frame rate), without bursts after a gap.
    self.last_snapshot = (now - self.last_snapshot >= 2 * interval) and now or (self.last_snapshot + interval)

    local F = self.P.ENEMY_FLAGS
    local entries = {}
    for _, e in ipairs(enemies) do
        local net_id = self.net_of[e.id]
        if net_id ~= nil and e.alive then
            entries[#entries + 1] = {
                net_id = net_id, uid = e.uid, kind_hash = e.kind_hash, pos = e.pos, spawn = self.spawn[e.id],
                yaw = e.yaw, hp = e.hp, max_hp = e.max_hp, flags = F.ALIVE, motion = e.motion,
            }
        end
    end
    -- Always send at least one (possibly empty) snapshot so the client sees host liveness.
    for _, msg in ipairs(self.P.encode_enemy_snapshots(now, entries)) do
        self.send(msg, false)
    end
    self.counters.snaps = self.counters.snaps + 1
end

function EnemySync:host_on_damage(m, game, now)
    now = now or 0
    local id = self:resolve(m.net_id, m.uid, m.kind_hash, m.pos)
    local e = id and self.by_id[id] or nil
    local lethal = (m.flags & self.P.DAMAGE_FLAGS.LETHAL) ~= 0
    if e == nil then
        -- The client killed an enemy our level has not spawned (or no longer has loaded): it
        -- is dead in the shared world, and dies here when our level spawns it.
        if lethal and m.uid ~= nil and (self.dead[m.uid] == nil or self.dead[m.uid].by ~= "host") then
            self:bury(m.uid, now, "client")
        end
        return false
    end
    if not e.alive then
        return false
    end

    -- HP a replayed hit already took (and could not be put back) is not taken twice.
    local amount = m.amount - self:take_credit(e.id, m.amount, now)
    if amount <= HP_EPS and not lethal then
        return true
    end
    -- Current HP, not the value from our last enemy list: the enemy may have lost HP since
    -- then (the host's own shots), which must not be overwritten.
    local cur = game.enemy_get_hp ~= nil and game:enemy_get_hp(e.id) or nil
    local new_hp = (cur or e.hp) - amount
    if lethal or new_hp <= HP_EPS then
        if game:enemy_kill(e.id) then
            e.hp = 0
            self.counters.kills_applied = self.counters.kills_applied + 1
            self.on_kill(e.id, now)
            return true
        end
    else
        if game:enemy_set_hp(e.id, new_hp) then
            e.hp = new_hp
            self.counters.damage_applied = self.counters.damage_applied + 1
            return true
        end
        self.counters.damage_failed = self.counters.damage_failed + 1
    end
    return false
end

-- ENEMY_CLIENT: the host enemies the client has a living copy of (we read their animation).
function EnemySync:host_on_client_state(m, now)
    for _, net_id in ipairs(m.paired) do
        self.client_paired[net_id] = now
    end
end

-- Our game reloaded (checkpoint, death): every enemy we knew belonged to the old scene (the
-- game adapter switched every head we had off back on). Host: the enemies came back, so the
-- old deaths no longer describe our world, and the client is told to forget them too.
-- Client: the host's world did not change - its graveyard stays and applies to the enemies
-- our reloaded level spawns again.
function EnemySync:on_local_reload()
    for id in pairs(self.last_seen) do self:forget(id) end
    self.by_id, self.id_of_uid = {}, {}
    self.ai_off, self.mirror_motion, self.removing = {}, {}, {}
    self.local_of, self.net_of = {}, {}
    if self.role == "host" then
        self.client_paired = {}
        self.reloaded, self.corpse_guard_until = true, nil
        self.dead = {}
        self.dead_count = 0
        self.send(self.P.encode_enemy_dead_reset(), true)
    end
end

-------------------------------------------------------------------------------
-- Client
-------------------------------------------------------------------------------

function EnemySync:client_bury(uid, now)
    if uid == nil then return end
    if self.grave[uid] == nil then
        self.grave_count = self.grave_count + 1
        self.counters.buried = self.counters.buried + 1
    end
    self.grave[uid] = now
end

function EnemySync:client_unbury(uid)
    if self.grave[uid] ~= nil then
        self.grave[uid] = nil
        self.grave_count = self.grave_count - 1
    end
end

function EnemySync:client_on_snapshot(m, now)
    local F = self.P.ENEMY_FLAGS
    for _, r in ipairs(m.enemies) do
        r.alive = (r.flags & F.ALIVE) ~= 0
        r.updated = now
        local prev = self.remote[r.net_id]
        if prev ~= nil and (prev.kind_hash ~= r.kind_hash or prev.uid ~= r.uid) then
            -- The host recycled the net id for another enemy: drop the old pairing.
            local id = self.local_of[r.net_id]
            if id ~= nil and self.net_of[id] == r.net_id then self.net_of[id] = nil end
            self.local_of[r.net_id] = nil
            prev = nil
        end
        local dead_at = (r.uid ~= nil and self.grave[r.uid]) or self.dead_net[r.net_id]
        if dead_at ~= nil and now - dead_at < REVIVE_GUARD then
            -- A snapshot sent before the death notice: it is dead.
            r.alive = false
        elseif r.alive and r.uid ~= nil and self.grave[r.uid] ~= nil then
            -- Alive in the host's world again (its game reloaded or respawned it).
            self:client_unbury(r.uid)
        end
        if r.alive then
            r.interp = prev and prev.interp or self:new_buffer()
            r.interp:push(m.time, now, { pos = r.pos, yaw = r.yaw, motion = r.motion })
            self.remote[r.net_id] = r
        elseif prev ~= nil then
            prev.alive = false
            prev.interp = nil
        end
    end
end

function EnemySync:client_on_dead(m, now)
    if m.reset then
        -- The host reloaded a checkpoint: its dead enemies are alive again.
        self.grave = {}
        self.grave_count = 0
        self.dead_net = {}
        return
    end
    self:client_bury(m.uid, now)
    if m.uid == nil and m.net_id ~= 0 then self.dead_net[m.net_id] = now end
    local r = self.remote[m.net_id]
    if r ~= nil then
        r.alive = false
        r.hp = 0
        r.interp = nil
    end
end

-- The host's whole graveyard: the first message replaces what we knew.
function EnemySync:client_on_grave(m, now)
    if m.chunk == 1 then
        self.grave = {}
        self.grave_count = 0
        self.counters.graves_received = self.counters.graves_received + 1
    end
    for _, uid in ipairs(m.uids) do self:client_bury(uid, now) end
end

function EnemySync:client_tick(now, enemies, game, players)
    local by_id = self:observe(now, enemies)
    local local_pos = players and players.local_pos or nil

    for net_id, r in pairs(self.remote) do
        if now - r.updated > REMOTE_STALE then self.remote[net_id] = nil end
    end
    for net_id, t in pairs(self.dead_net) do
        if now - t > 60 then self.dead_net[net_id] = nil end
    end
    for net_id, id in pairs(self.local_of) do
        local r = self.remote[net_id]
        if by_id[id] == nil or r == nil then
            self.local_of[net_id] = nil
            if self.net_of[id] == net_id then self.net_of[id] = nil end
            if by_id[id] ~= nil then self:release_mirror(game, id) end -- the host no longer has it: ours to run
        end
    end

    -- 1) Damage we dealt locally since last tick goes to the host.
    local P = self.P
    for _, e in ipairs(enemies) do
        local expected = self.expected_hp[e.id]
        if expected == nil then
            self.expected_hp[e.id] = e.hp
        elseif e.hp < expected - HP_EPS then
            -- HP a replayed partner hit took (and could not be put back) is not our damage.
            local amount = (expected - e.hp) - self:take_credit(e.id, expected - e.hp, now)
            local lethal = (not e.alive) or e.hp <= HP_EPS
            if not self.self_killed[e.id] and (amount > HP_EPS or lethal) then
                self.send(P.encode_enemy_damage({
                    net_id = self.net_of[e.id] or 0,
                    uid = e.uid,
                    kind_hash = e.kind_hash,
                    pos = self.spawn[e.id] or e.pos,
                    amount = math.max(0, amount),
                    flags = lethal and P.DAMAGE_FLAGS.LETHAL or 0,
                }), true)
                self.counters.damage_sent = self.counters.damage_sent + 1
            end
            self.expected_hp[e.id] = e.hp
        elseif e.hp > expected + HP_EPS then
            self.expected_hp[e.id] = e.hp -- regenerated/reset locally
        end
    end

    -- 2) Pair the host's enemies with ours: by uid (exact), else by kind and spawn point.
    local taken = {}
    for id in pairs(self.net_of) do taken[id] = true end
    local unpaired = {}
    for net_id, r in pairs(self.remote) do
        if r.alive and self.local_of[net_id] == nil then unpaired[#unpaired + 1] = net_id end
    end
    table.sort(unpaired)
    for _, net_id in ipairs(unpaired) do
        local r = self.remote[net_id]
        local id
        if r.uid ~= nil then
            id = self.id_of_uid[r.uid]
            local e = id and by_id[id]
            if e == nil or taken[id] or not e.alive or e.kind_hash ~= r.kind_hash then id = nil end
            if id ~= nil then self.counters.uid_pairs = self.counters.uid_pairs + 1 end
        else
            id = self:find_spatial(r.kind_hash, r.spawn or r.pos, r.pos, taken, true)
            if id ~= nil then self.counters.spatial_pairs = self.counters.spatial_pairs + 1 end
        end
        if id ~= nil then
            self.local_of[net_id] = id
            self.net_of[id] = net_id
            taken[id] = true
        end
    end

    -- 3) Enemies dead in the host's world go here too (remove_dead paces its own retries).
    for _, e in ipairs(enemies) do
        if e.alive then
            local net_id = self.net_of[e.id]
            local dead = (e.uid ~= nil and self.grave[e.uid] ~= nil)
                or (net_id ~= nil and self.dead_net[net_id] ~= nil)
            if dead then self:remove_dead(game, e.id, e, now, local_pos) end
        end
    end

    -- 4) Apply the host's outcome to our copies.
    local mirror = self:mirroring(game)
    for net_id, id in pairs(self.local_of) do
        local r, e = self.remote[net_id], by_id[id]
        if not e.alive then
            -- Our player killed the puppet: its death needs its own AI (the host is told by
            -- the damage report, and its death notice follows).
            if self.ai_off[id] then self:release_mirror(game, id) end
        elseif r.alive and not self.self_killed[id] then
            if r.hp < e.hp - HP_EPS then
                if game:enemy_set_hp(id, r.hp) then
                    self.expected_hp[id] = r.hp
                    self.counters.hp_applied = self.counters.hp_applied + 1
                else
                    self.counters.hp_failed = self.counters.hp_failed + 1
                end
            end
            if not mirror then self:release_mirror(game, id) end
        end
    end

    -- 5) Tell the host which of its enemies we have (it sends their animation).
    local hz = self.settings.client_enemy_hz or 20
    local interval = 1.0 / hz
    if now - self.last_client_send >= interval then
        self.last_client_send = (now - self.last_client_send >= 2 * interval) and now or (self.last_client_send + interval)
        local paired = {}
        for net_id, id in pairs(self.local_of) do
            local r, e = self.remote[net_id], by_id[id]
            if e.alive and r.alive then paired[#paired + 1] = net_id end
        end
        table.sort(paired)
        self.send(P.encode_enemy_client(now, paired), false)
    end
end

-- Every frame: our puppets follow the host's enemies.
function EnemySync:client_frame(now, game)
    for net_id, id in pairs(self.local_of) do
        local r, e = self.remote[net_id], self.by_id[id]
        if r ~= nil and e ~= nil and e.alive and r.alive and r.interp ~= nil and not self.self_killed[id] then
            local age = r.interp:age(now)
            if age ~= nil and age < MIRROR_STALE then
                local st = r.interp:sample(now)
                if st ~= nil then self:apply_mirror(game, id, e, st) end
            else
                self:release_mirror(game, id) -- no news from the host: let our copy act
            end
        end
    end
end

-------------------------------------------------------------------------------

-- players = { local_pos={x,y,z}|nil, partner_pos={x,y,z}|nil }: the local position decides
-- how an enemy dead in the partner's world goes (visible death or erased).
function EnemySync:tick(now, enemies, game, players)
    self.last_tick = now
    if self.role == "host" then
        self:host_tick(now, enemies, game, players)
    else
        self:client_tick(now, enemies, game, players)
    end
end

-- Every game frame (client): the puppets follow the host's enemies. The host's enemies all
-- run on their own.
function EnemySync:frame(now, game)
    if self.role ~= "client" then return end
    if not self:mirroring(game) then
        if next(self.ai_off) ~= nil then self:release_all(game) end
        return
    end
    self:client_frame(now, game)
end

-- Returns true if the message was an enemy message (consumed).
function EnemySync:on_message(m, now, game)
    local T = self.P.T
    if m.type == T.ENEMY_HIT then
        self:on_partner_hit(m, now, game)
        return true
    end
    if self.role == "host" then
        if m.type == T.ENEMY_DAMAGE then
            self:host_on_damage(m, game, now)
            return true
        elseif m.type == T.ENEMY_CLIENT then
            self:host_on_client_state(m, now)
            return true
        end
    else
        if m.type == T.ENEMY_SNAPSHOT then
            self:client_on_snapshot(m, now)
            return true
        elseif m.type == T.ENEMY_DEAD then
            self:client_on_dead(m, now)
            return true
        elseif m.type == T.ENEMY_GRAVE then
            self:client_on_grave(m, now)
            return true
        end
    end
    return false
end

function EnemySync:summary()
    local n_local, n_paired, n_remote, n_ai_off, n_uid = 0, 0, 0, 0, 0
    for _, e in pairs(self.by_id) do
        n_local = n_local + 1
        if e.uid ~= nil then n_uid = n_uid + 1 end
    end
    for _ in pairs(self.ai_off) do n_ai_off = n_ai_off + 1 end
    if self.role == "host" then
        -- Our enemies the client has a copy of.
        local now = self.last_tick or 0
        for net_id, t in pairs(self.client_paired) do
            if self.local_of[net_id] ~= nil and now - t <= PAIRED_TIMEOUT then n_paired = n_paired + 1 end
        end
    else
        for _ in pairs(self.local_of) do n_paired = n_paired + 1 end
        for _ in pairs(self.remote) do n_remote = n_remote + 1 end
    end
    return { role = self.role, local_count = n_local, with_uid = n_uid, paired = n_paired, remote_count = n_remote,
        puppets = n_ai_off,
        dead_known = self.role == "host" and self.dead_count or self.grave_count,
        listing_dead = self.grave_scan ~= nil, counters = self.counters }
end

return EnemySync
