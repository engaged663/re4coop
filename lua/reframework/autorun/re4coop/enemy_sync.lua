-- Enemy synchronisation: one shared set of enemies across both games.
--
-- Both games load the same chapter, so the level spawns the same enemies on both machines.
-- This module makes them behave as one:
--   * Identity: the host numbers its enemies; the client pairs each host enemy with its own
--     copy (same kind, same spawn point, or the same level spawner once spawner IDs have
--     proven to match across machines).
--   * Health and death: the host is authoritative. Damage the client deals is sent to the
--     host; the host's HP and deaths are applied to the client's copies. Deaths of enemies
--     the client had no copy of are re-advertised, so a partner who arrives later finds the
--     room already cleared; kills the client made where the host had no copy are applied
--     when the host's level spawns those enemies.
--   * Movement and AI ("ownership"): each enemy is run by the machine whose player is closer
--     to it (with hysteresis). The other machine mirrors it - position, facing and animation
--     follow the owner's copy through an interpolation buffer, and its own AI is switched
--     off - so enemies near the client chase and attack the client for real, and both
--     screens show them in the same place doing the same thing.
--   * Hits: each side sends the hits its own player lands (ENEMY_HIT, from the game's damage
--     callback). An enemy the partner is shooting moves to the partner's game (ownership
--     follows the fight), so it reacts to their shots there with its own logic, and both
--     screens show that reaction. Optionally (experimental) the other side also replays the
--     hit on its copy. HP still flows through the damage/HP sync above.
--
-- Game access goes through an adapter (see game.lua) so this file is pure Lua and is
-- tested offline against fake worlds (tests/lua/test_enemy_sync.lua).
--
-- Adapter contract:
--   enemies = { {id=<number>, kind=<string>, pos={x,y,z}, yaw=<number>, hp=<number>,
--               max_hp=<number>, alive=<bool>, ctx=<ContextID table or nil>,
--               motion={bank,id,frame}|nil}, ... }  (passed to tick)
--   game:enemy_set_hp(id, hp) -> bool
--   game:enemy_kill(id) -> bool
--   game:enemy_set_position(id, pos) -> bool
--   game:enemy_get_hp(id) -> number|nil   (optional: current HP, fresher than the last list)
--   game:enemy_replay_hit(id, hit) -> ok, kept   (optional: replays the partner's hit so the
--       enemy visibly reacts; `kept` = HP the replay took that could not be put back)
--   game:enemy_set_transform(id, pos, yaw) -> bool  (optional: mirroring)
--   game:enemy_set_motion(id, motion) -> bool       (optional: animation mirroring)
--   game:enemy_set_ai(id, on) -> bool               (optional: switch a mirrored enemy's AI off)

local Interp = require("re4coop.interp")

local EnemySync = {}
EnemySync.__index = EnemySync

local HP_EPS = 0.01
local FORGET_AFTER = 5.0          -- seconds an enemy may be missing from the list before we forget it
local DEAD_REPORT_WINDOW = 600.0  -- host keeps advertising deaths the client did not witness
local DEAD_STALE = 3.0            -- client: a death not advertised again for this long is over
local PENDING_KILL_WINDOW = 600.0 -- host: client kills of enemies the host had not loaded yet
local MAX_PENDING_KILLS = 64
local CREDIT_SECONDS = 2.0        -- HP a replay could not put back is not reported as our damage
local MAX_RECENT_HITS = 16        -- partner hits kept for drawing shot tracers
local PAIRED_TIMEOUT = 1.5        -- host: a client report older than this no longer counts
local OWNER_HYSTERESIS = 2.0      -- metres the other player must be closer by to take an enemy over
local OWNER_HOLD = 0.6            -- seconds that must stay true before ownership moves
local HIT_WINDOW = 3.0            -- the player who hit an enemy this recently runs it
local HIT_HOLD = 0.2              -- ...after this much hold (the fight decides quickly)
local DEAD_EVERY_N = 10           -- deaths the client did not witness: re-advertised every Nth snapshot...
local DEAD_PER_SNAPSHOT = 30      -- ...this many at a time, in turn
local MIRROR_DELAY = 0.1          -- interpolation delay for mirrored enemies
local MIRROR_STALE = 1.0          -- stop mirroring when the owner's data is older than this
local MIRROR_MIN_MOVE = 0.01      -- metres; smaller corrections are not written

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function copy3(v)
    return { x = v.x, y = v.y, z = v.z }
end

-- Mirrored enemy states blend position and facing (the short way round) and take the
-- animation from the nearer snapshot.
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

local function new_buffer()
    return Interp.new({ delay = MIRROR_DELAY, max_extrapolate = 0.2, capacity = 16, blend = blend_enemy })
end

-- opts: { role="host"|"client", protocol=<protocol module>, send=function(bytes, reliable),
--         settings=<table read live>, log=function(fmt, ...),
--         on_kill=function(local_id, now) (optional: we killed an enemy because the partner's game did) }
-- settings: sync_hp, sync_deaths, snapshot_hz, match_radius, snap_distance, replay_partner_hits,
--           enemy_mirror, enemy_ownership, enemy_motion_sync, enemy_puppet_ai, client_enemy_hz
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
    self.last_seen = {}     -- local id -> time
    self.by_id = {}         -- local id -> latest enemy record

    -- host
    self.net_of = {}        -- local id -> net id
    self.local_of = {}      -- net id -> local id
    self.alive_of = {}      -- local id -> last known alive flag
    self.dead = {}          -- net id -> {kind_hash, pos, spawn, max_hp, time, ctx, client_had}
    self.next_net_id = 1
    self.last_snapshot = -math.huge
    self.snapshot_count = 0
    self.owner = {}         -- net id -> "client" when the client runs it (absent = host)
    self.owner_pending = {} -- net id -> {want, since}
    self.client_paired = {} -- net id -> time the client last reported having a copy
    self.client_interp = {} -- net id -> interpolation buffer of the client's copy
    self.pending_kills = {} -- client kills the host could not match yet: {kind_hash, pos, time}
    self.last_hit = {}      -- net id -> {who = "host"|"client", time}
    self.dead_cursor = 0

    -- client
    self.remote = {}        -- net id -> latest host entry (+ .updated, .interp, .client_owned)
    self.expected_hp = {}   -- local id -> HP we have already accounted for
    self.self_killed = {}   -- local ids we killed to mirror the host (don't report them back)
    self.last_client_send = -math.huge

    -- both
    self.mirror_motion = {} -- local id -> "bank:id" last applied
    self.ai_off = {}        -- local id -> true while its AI is switched off (mirrored)
    self.hit_credit = {}    -- local id -> {amount, time}
    self.recent_hits = {}   -- partner hits: {pos, time}

    self.counters = { damage_sent = 0, damage_applied = 0, damage_failed = 0, kills_applied = 0, hp_applied = 0,
        hp_failed = 0, snaps = 0, id_matches = 0, hits_sent = 0, hits_received = 0, hits_replayed = 0,
        hits_unmatched = 0, mirrored = 0, motions = 0, ai_switched = 0, ownership_changes = 0, late_kills = 0,
        pending_kills = 0 }
    self.trust = { agree = 0, disagree = 0 } -- spawner-ID pairing evidence this session
end

function EnemySync:kind_hash(kind)
    local h = self.kind_hashes[kind]
    if h == nil then
        h = self.P.hash(kind)
        self.kind_hashes[kind] = h
    end
    return h
end

-- Records per-enemy bookkeeping shared by both roles.
function EnemySync:observe(now, enemies)
    local by_id = {}
    for _, e in ipairs(enemies) do
        by_id[e.id] = e
        e.kind_hash = e.kind_hash or self:kind_hash(e.kind)
        if self.spawn[e.id] == nil then
            self.spawn[e.id] = copy3(e.pos)
        end
        self.last_seen[e.id] = now
    end
    self.by_id = by_id

    for id, t in pairs(self.last_seen) do
        if now - t > FORGET_AFTER then
            self.last_seen[id] = nil
            self.spawn[id] = nil
            self.expected_hp[id] = nil
            self.self_killed[id] = nil
            self.alive_of[id] = nil
            self.mirror_motion[id] = nil
            self.ai_off[id] = nil
            local net_id = self.net_of[id]
            if net_id ~= nil then
                self.net_of[id] = nil
                if self.local_of[net_id] == id then self.local_of[net_id] = nil end
            end
        end
    end
    return by_id
end

-- Local enemy that is the same level enemy as a remote one. `taken` excludes enemies
-- already paired. Returns id, how ("spawner" | "spatial").
--
--  1. Same spawner (CharacterContext.get_SpawnerID, from level data) and same kind, when that
--     spawner ID belongs to exactly one candidate (a spawner can create several enemies), the
--     spawn points are within ID_MATCH_RADIUS, and - when `require_trust` - spawner pairing
--     has been confirmed this session (see note_spatial_pair).
--  2. Otherwise the closest enemy of the same kind whose spawn (or current position) is
--     within the match radius.
local ID_MATCH_RADIUS = 25.0
local TRUST_AFTER = 3 -- spatial pairings whose spawner IDs agreed before spawner pairing is used

function EnemySync:spawner_trusted()
    return self.trust.agree >= TRUST_AFTER and self.trust.disagree == 0
end

-- Records whether a pairing made by position also agrees on spawner ID. One disagreement
-- disables spawner pairing for the session: then the IDs are not a cross-machine identity.
function EnemySync:note_spatial_pair(remote_ctx, local_id)
    local e = self.by_id[local_id]
    local a, b = self.P.ctx_key(remote_ctx), e and self.P.ctx_key(e.ctx)
    if a == nil or b == nil then return end
    if a == b then
        self.trust.agree = self.trust.agree + 1
    else
        self.trust.disagree = self.trust.disagree + 1
    end
end

function EnemySync:find_match(kind_hash, spawn_pos, cur_pos, taken, want_alive, ctx, require_trust)
    local key = self.P.ctx_key(ctx)
    if key ~= nil and (not require_trust or self:spawner_trusted()) then
        local found, count = nil, 0
        for id, e in pairs(self.by_id) do
            if e.kind_hash == kind_hash and self.P.ctx_key(e.ctx) == key then
                count = count + 1
                if not taken[id] and (not want_alive or e.alive)
                    and dist(self.spawn[id] or e.pos, spawn_pos) <= ID_MATCH_RADIUS then
                    found = id
                end
            end
        end
        if found ~= nil and count == 1 then
            self.counters.id_matches = self.counters.id_matches + 1
            return found, "spawner"
        end
    end
    local radius = self.settings.match_radius or 3.0
    local best, best_d = nil, math.huge
    for id, e in pairs(self.by_id) do
        if e.kind_hash == kind_hash and not taken[id] and (not want_alive or e.alive) then
            local d = dist(self.spawn[id] or e.pos, spawn_pos)
            if cur_pos ~= nil then
                d = math.min(d, dist(e.pos, cur_pos))
            end
            if d <= radius and d < best_d then
                best, best_d = id, d
            end
        end
    end
    return best, best and "spatial" or nil
end

-------------------------------------------------------------------------------
-- Mirroring (shared by both roles)
-------------------------------------------------------------------------------

-- Whether enemies the other machine runs are mirrored here (needs the transform writer).
function EnemySync:mirroring(game)
    return self.settings.enemy_mirror ~= false and game ~= nil and game.enemy_set_transform ~= nil
end

-- Whether the partner's game mirrors this local enemy from ours (so its animation must be
-- read and sent): host - the client has a copy and does not run it itself; client - the host
-- handed it to us. Decided from the previous tick's state.
function EnemySync:wants_motion(id)
    local net_id = self.net_of[id]
    if net_id == nil then return false end
    if self.role == "host" then
        local t = self.client_paired[net_id]
        return t ~= nil and self.owner[net_id] ~= "client" and (self.last_tick or 0) - t <= PAIRED_TIMEOUT
    end
    local r = self.remote[net_id]
    return r ~= nil and r.client_owned == true
end

-- Switches a local enemy's own AI off while it is mirrored, and back on when it is not.
function EnemySync:set_ai(game, id, on)
    if game == nil or game.enemy_set_ai == nil then return end
    if not on and self.settings.enemy_puppet_ai == false then on = true end
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

-- Writes a mirrored transform (and animation) onto a local enemy.
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
-- only a missed flinch on the partner's screen.
function EnemySync:on_local_hits(events, now)
    for _, ev in ipairs(events or {}) do
        local e = self.by_id[ev.id]
        local net_id = self.net_of[ev.id]
        if net_id ~= nil and self.role == "host" then
            self.last_hit[net_id] = { who = "host", time = now }
        end
        if e ~= nil and (net_id ~= nil or self.role == "client") then
            self.send(self.P.encode_enemy_hit({
                net_id = net_id or 0, kind_hash = e.kind_hash, pos = self.spawn[ev.id] or e.pos,
                damage = ev.damage, wince = ev.wince, break_ = ev.break_, stopping = ev.stopping,
                dir = ev.dir, weapon = ev.weapon, critical = ev.critical,
            }), false)
            self.counters.hits_sent = self.counters.hits_sent + 1
        end
    end
end

function EnemySync:on_partner_hit(m, now, game)
    local id
    if self.role == "host" then
        id = m.net_id ~= 0 and self.local_of[m.net_id] or nil
        if id == nil then id = self:find_match(m.kind_hash, m.pos, m.pos, {}, true, nil) end
    else
        id = self.local_of[m.net_id]
    end
    local e = id and self.by_id[id] or nil
    if e == nil then
        self.counters.hits_unmatched = self.counters.hits_unmatched + 1
        return
    end
    self.counters.hits_received = self.counters.hits_received + 1
    if self.role == "host" and self.net_of[id] ~= nil then
        self.last_hit[self.net_of[id]] = { who = "client", time = now }
    end
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
        if self.local_of[id] == nil and self.dead[id] == nil then
            return id
        end
    end
    return nil
end

function EnemySync:client_has(net_id, now)
    local t = self.client_paired[net_id]
    return t ~= nil and now - t <= PAIRED_TIMEOUT
end

function EnemySync:set_owner(net_id, owner)
    local cur = self.owner[net_id] or "host"
    self.owner_pending[net_id] = nil
    if cur == owner then return end
    self.owner[net_id] = owner ~= "host" and owner or nil
    if owner == "host" then
        self.client_interp[net_id] = nil
    end
    self.counters.ownership_changes = self.counters.ownership_changes + 1
end

-- Decides which machine runs an enemy: the one whose player is closer.
function EnemySync:update_owner(net_id, e, players, now)
    local cur = self.owner[net_id] or "host"
    if not self:client_has(net_id, now) or not e.alive then
        if cur ~= "host" then self:set_owner(net_id, "host") end
        return
    end
    local want, hold
    local hit = self.last_hit[net_id]
    if self.settings.hit_ownership ~= false and hit ~= nil and now - hit.time <= HIT_WINDOW then
        -- Whoever is fighting it runs it: their shots hit an enemy their own game controls.
        want, hold = hit.who, HIT_HOLD
    else
        local dh = dist(e.pos, players.local_pos)
        local dc = dist(e.pos, players.partner_pos)
        if cur == "host" then
            want = (dc + OWNER_HYSTERESIS < dh) and "client" or "host"
        else
            want = (dh + OWNER_HYSTERESIS < dc) and "host" or "client"
        end
        hold = OWNER_HOLD
    end
    if want == cur then
        self.owner_pending[net_id] = nil
        return
    end
    local p = self.owner_pending[net_id]
    if p == nil or p.want ~= want then
        self.owner_pending[net_id] = { want = want, since = now }
        p = self.owner_pending[net_id]
    end
    if now - p.since >= hold then
        self:set_owner(net_id, want)
    end
end

-- Client kills of enemies the host did not have loaded: applied once the host's level spawns them.
function EnemySync:apply_pending_kills(now, game)
    local n = #self.pending_kills
    if n == 0 then return end
    local taken = {}
    for i = n, 1, -1 do
        local k = self.pending_kills[i]
        if now - k.time > PENDING_KILL_WINDOW then
            table.remove(self.pending_kills, i)
        else
            local id = self:find_match(k.kind_hash, k.pos, nil, taken, true, nil)
            if id ~= nil then
                taken[id] = true
                table.remove(self.pending_kills, i)
                if self.settings.sync_deaths ~= false and game:enemy_kill(id) then
                    self.by_id[id].hp = 0
                    self.counters.late_kills = self.counters.late_kills + 1
                    self.on_kill(id, now)
                end
            end
        end
    end
end

function EnemySync:host_tick(now, enemies, game, players)
    self:observe(now, enemies)

    for _, e in ipairs(enemies) do
        local net_id = self.net_of[e.id]
        if net_id == nil then
            net_id = self:alloc_net_id()
            if net_id ~= nil then
                self.net_of[e.id] = net_id
                self.local_of[net_id] = e.id
            end
        end
        if net_id ~= nil then
            local was_alive = self.alive_of[e.id]
            if was_alive ~= false and not e.alive then
                if was_alive == true then
                    self.send(self.P.encode_enemy_dead(net_id), true)
                end
                self.dead[net_id] = {
                    kind_hash = e.kind_hash, pos = copy3(e.pos), spawn = self.spawn[e.id],
                    max_hp = e.max_hp, time = now, ctx = e.ctx,
                    -- A client with a copy kills it from ENEMY_DEAD; only deaths it did not
                    -- witness are re-advertised (for when its level spawns the enemy later).
                    client_had = self:client_has(net_id, now),
                }
                self:set_owner(net_id, "host")
            end
            self.alive_of[e.id] = e.alive
        end
    end

    for net_id, d in pairs(self.dead) do
        if now - d.time > DEAD_REPORT_WINDOW then
            self.dead[net_id] = nil
        end
    end
    for net_id, t in pairs(self.client_paired) do
        if now - t > 30 then self.client_paired[net_id] = nil end
    end
    for net_id, h in pairs(self.last_hit) do
        if now - h.time > HIT_WINDOW then self.last_hit[net_id] = nil end
    end
    self:apply_pending_kills(now, game)

    -- Ownership: who runs each enemy's AI.
    local ownership = self.settings.enemy_ownership ~= false and self:mirroring(game)
        and players ~= nil and players.local_pos ~= nil and players.partner_pos ~= nil
    for _, e in ipairs(enemies) do
        local net_id = self.net_of[e.id]
        if net_id ~= nil then
            if ownership then
                self:update_owner(net_id, e, players, now)
            elseif self.owner[net_id] ~= nil then
                self:set_owner(net_id, "host")
            end
            if self.owner[net_id] == nil then self:release_mirror(game, e.id) end
        end
    end
    for net_id in pairs(self.owner) do
        if self.local_of[net_id] == nil then self.owner[net_id] = nil end
    end

    local hz = self.settings.snapshot_hz or 20
    local interval = 1.0 / hz
    if now - self.last_snapshot < interval then
        return
    end
    -- Keep the rate exact (not slowed down by the frame rate), without bursts after a gap.
    self.last_snapshot = (now - self.last_snapshot >= 2 * interval) and now or (self.last_snapshot + interval)
    self.snapshot_count = self.snapshot_count + 1

    local F = self.P.ENEMY_FLAGS
    local entries = {}
    for _, e in ipairs(enemies) do
        local net_id = self.net_of[e.id]
        if net_id ~= nil and e.alive then
            local flags = F.ALIVE
            if self.owner[net_id] == "client" then flags = flags | F.CLIENT_OWNED end
            entries[#entries + 1] = {
                net_id = net_id, kind_hash = e.kind_hash, pos = e.pos, spawn = self.spawn[e.id],
                yaw = e.yaw, hp = e.hp, max_hp = e.max_hp, flags = flags, ctx = e.ctx, motion = e.motion,
            }
        end
    end
    if self.snapshot_count % DEAD_EVERY_N == 0 then
        -- Deaths the client did not witness (it had no copy then), a few at a time in turn:
        -- its level may spawn those enemies later, and they must arrive dead.
        local dead_list = {}
        for net_id, d in pairs(self.dead) do
            if not d.client_had then
                dead_list[#dead_list + 1] = { net_id = net_id, d = d }
            end
        end
        table.sort(dead_list, function(a, b) return a.net_id < b.net_id end)
        local n = #dead_list
        local first = n > 0 and (self.dead_cursor % n) or 0
        local count = math.min(n, DEAD_PER_SNAPSHOT)
        self.dead_cursor = first + count
        for k = 0, count - 1 do
            local x = dead_list[(first + k) % n + 1]
            entries[#entries + 1] = {
                net_id = x.net_id, kind_hash = x.d.kind_hash, pos = x.d.pos, spawn = x.d.spawn,
                yaw = 0, hp = 0, max_hp = x.d.max_hp, flags = 0, ctx = x.d.ctx,
            }
        end
    end
    -- Always send at least one (possibly empty) snapshot so the client sees host liveness.
    for _, msg in ipairs(self.P.encode_enemy_snapshots(now, entries)) do
        self.send(msg, false)
    end
    self.counters.snaps = self.counters.snaps + 1
end

function EnemySync:host_frame(now, game)
    for net_id, owner in pairs(self.owner) do
        if owner == "client" then
            local id = self.local_of[net_id]
            local e = id and self.by_id[id]
            local buf = self.client_interp[net_id]
            if e ~= nil and e.alive and buf ~= nil then
                local age = buf:age(now)
                if age ~= nil and age < MIRROR_STALE then
                    local st = buf:sample(now)
                    if st ~= nil then self:apply_mirror(game, id, e, st) end
                else
                    -- The client stopped sending this one: run it here until it does again.
                    self:release_mirror(game, id)
                end
            end
        end
    end
end

function EnemySync:host_on_damage(m, game, now)
    local id = m.net_id ~= 0 and self.local_of[m.net_id] or nil
    local e = id and self.by_id[id] or nil
    if e == nil then
        local match = self:find_match(m.kind_hash, m.pos, m.pos, {}, true, m.ctx)
        e = match and self.by_id[match] or nil
    end
    local lethal = (m.flags & self.P.DAMAGE_FLAGS.LETHAL) ~= 0
    if e == nil then
        -- The client killed an enemy our level has not spawned (yet), or no longer has loaded:
        -- kill it when it does.
        if lethal and #self.pending_kills < MAX_PENDING_KILLS then
            self.pending_kills[#self.pending_kills + 1] = { kind_hash = m.kind_hash, pos = copy3(m.pos), time = now or 0 }
            self.counters.pending_kills = self.counters.pending_kills + 1
        end
        return false
    end
    if not e.alive then
        return false
    end

    -- HP a replayed hit already took (and could not be put back) is not taken twice.
    local amount = m.amount - self:take_credit(e.id, m.amount, now or 0)
    if amount <= HP_EPS and not lethal then
        return true
    end
    -- Current HP, not the value from our last enemy list: the enemy may have lost HP since
    -- then (the host's own shots), which must not be overwritten.
    local cur = game.enemy_get_hp ~= nil and game:enemy_get_hp(e.id) or nil
    local new_hp = (cur or e.hp) - amount
    if lethal or new_hp <= HP_EPS then
        if self.settings.sync_deaths ~= false and game:enemy_kill(e.id) then
            e.hp = 0
            self.counters.kills_applied = self.counters.kills_applied + 1
            self.on_kill(e.id, now or 0)
            return true
        end
    elseif self.settings.sync_hp ~= false then
        if game:enemy_set_hp(e.id, new_hp) then
            e.hp = new_hp
            self.counters.damage_applied = self.counters.damage_applied + 1
            return true
        end
        self.counters.damage_failed = self.counters.damage_failed + 1
    end
    return false
end

function EnemySync:host_on_client_state(m, now)
    for _, net_id in ipairs(m.paired) do
        self.client_paired[net_id] = now
    end
    for _, s in ipairs(m.states) do
        self.client_paired[s.net_id] = now
        if self.local_of[s.net_id] ~= nil and self.owner[s.net_id] == "client" then
            local buf = self.client_interp[s.net_id]
            if buf == nil then
                buf = new_buffer()
                self.client_interp[s.net_id] = buf
            end
            buf:push(m.time, now, { pos = s.pos, yaw = s.yaw, motion = s.motion })
        end
    end
end

-- Our game reloaded (checkpoint, death): the enemies came back, so the old deaths and the
-- partner's kills no longer describe them. The client is told to forget them too.
function EnemySync:on_local_reload()
    if self.role == "host" then
        self.dead = {}
        self.pending_kills = {}
        self.send(self.P.encode_enemy_dead(self.P.ENEMY_DEAD_RESET), true)
    end
end

-------------------------------------------------------------------------------
-- Client
-------------------------------------------------------------------------------

function EnemySync:client_on_snapshot(m, now)
    local F = self.P.ENEMY_FLAGS
    for _, r in ipairs(m.enemies) do
        r.alive = (r.flags & F.ALIVE) ~= 0
        r.client_owned = (r.flags & F.CLIENT_OWNED) ~= 0
        r.updated = now
        local prev = self.remote[r.net_id]
        if prev ~= nil and prev.kind_hash ~= r.kind_hash then
            -- Host recycled the id for another enemy: drop the old pairing.
            local id = self.local_of[r.net_id]
            if id ~= nil then self.net_of[id] = nil end
            self.local_of[r.net_id] = nil
            prev = nil
        end
        if prev ~= nil and not prev.alive and r.alive and prev.kind_hash == r.kind_hash then
            -- A stale alive snapshot arriving after the death notice; keep it dead.
            r.alive = false
        end
        if r.alive then
            r.interp = prev and prev.interp or new_buffer()
            r.interp:push(m.time, now, { pos = r.pos, yaw = r.yaw, motion = r.motion })
        end
        r.was_paired = prev ~= nil and prev.was_paired or nil
        self.remote[r.net_id] = r
    end
end

function EnemySync:client_on_dead(m, now)
    if m.net_id == self.P.ENEMY_DEAD_RESET then
        -- The host reloaded a checkpoint: its dead enemies are alive again.
        for net_id, r in pairs(self.remote) do
            if not r.alive then
                self.remote[net_id] = nil
                local id = self.local_of[net_id]
                if id ~= nil then
                    self.local_of[net_id] = nil
                    if self.net_of[id] == net_id then self.net_of[id] = nil end
                end
            end
        end
        return
    end
    local r = self.remote[m.net_id]
    if r ~= nil then
        r.alive = false
        r.hp = 0
        r.updated = now
        r.interp = nil
    end
end

function EnemySync:client_kill(game, id, now)
    if self.settings.sync_deaths == false or self.self_killed[id] then return false end
    if game:enemy_kill(id) then
        self.self_killed[id] = true
        self.expected_hp[id] = 0
        self.counters.kills_applied = self.counters.kills_applied + 1
        self.on_kill(id, now or 0)
        return true
    end
    return false
end

function EnemySync:client_tick(now, enemies, game)
    local by_id = self:observe(now, enemies)

    for net_id, r in pairs(self.remote) do
        -- A death the host stopped advertising is over (we had a copy, or the host reloaded).
        if now - r.updated > (r.alive and DEAD_REPORT_WINDOW or DEAD_STALE) then
            self.remote[net_id] = nil
        end
    end
    for net_id, id in pairs(self.local_of) do
        if by_id[id] == nil or self.remote[net_id] == nil then
            self.local_of[net_id] = nil
            if self.net_of[id] == net_id then self.net_of[id] = nil end
            if by_id[id] ~= nil then self:release_mirror(game, id) end
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
                    kind_hash = e.kind_hash,
                    pos = self.spawn[e.id] or e.pos,
                    amount = math.max(0, amount),
                    flags = lethal and P.DAMAGE_FLAGS.LETHAL or 0,
                    -- The host has no evidence of its own about spawner IDs: only send one
                    -- once this session has proven they match across machines.
                    ctx = self:spawner_trusted() and e.ctx or nil,
                }), true)
                self.counters.damage_sent = self.counters.damage_sent + 1
            end
            self.expected_hp[e.id] = e.hp
        elseif e.hp > expected + HP_EPS then
            self.expected_hp[e.id] = e.hp -- regenerated/reset locally
        end
    end

    -- 2) Pair host enemies with ours. Living host enemies first, so a dead record never takes
    --    a new enemy that spawned where it died (waves) from its living twin; then by net id,
    --    which keeps both runs deterministic.
    local unpaired = {}
    for net_id, r in pairs(self.remote) do
        -- A dead enemy we already had a copy of is settled: it must not take a new enemy
        -- that spawned where it died.
        if self.local_of[net_id] == nil and (r.alive or not r.was_paired) then
            unpaired[#unpaired + 1] = net_id
        end
    end
    local remote = self.remote
    table.sort(unpaired, function(a, b)
        local la, lb = remote[a].alive, remote[b].alive
        if la ~= lb then return la end
        return a < b
    end)
    local taken = {}
    for id in pairs(self.net_of) do taken[id] = true end
    local remote_key_count = {}
    for _, r in pairs(self.remote) do
        local key = self.P.ctx_key(r.ctx)
        if key ~= nil then remote_key_count[key] = (remote_key_count[key] or 0) + 1 end
    end
    for _, net_id in ipairs(unpaired) do
        local r = self.remote[net_id]
        local key = self.P.ctx_key(r.ctx)
        -- A spawner ID shared by several host enemies identifies none of them.
        local ctx = (key ~= nil and remote_key_count[key] == 1) and r.ctx or nil
        local id, how = self:find_match(r.kind_hash, r.spawn or r.pos, r.alive and r.pos or nil, taken, true, ctx, true)
        if id ~= nil then
            self.local_of[net_id] = id
            self.net_of[id] = net_id
            taken[id] = true
            r.was_paired = true
            if how == "spatial" then self:note_spatial_pair(r.ctx, id) end
        end
    end

    -- 3) Apply the host's outcome to our copies.
    local mirror = self:mirroring(game)
    local snap_distance = self.settings.snap_distance or 0
    for net_id, id in pairs(self.local_of) do
        local r, e = self.remote[net_id], by_id[id]
        if e.alive then
            if not r.alive then
                self:release_mirror(game, id) -- the death plays out with its own logic
                self:client_kill(game, id, now)
            else
                if self.settings.sync_hp ~= false and r.hp < e.hp - HP_EPS then
                    if game:enemy_set_hp(id, r.hp) then
                        self.expected_hp[id] = r.hp
                        self.counters.hp_applied = self.counters.hp_applied + 1
                    else
                        self.counters.hp_failed = self.counters.hp_failed + 1
                    end
                end
                if not mirror and snap_distance > 0 and dist(e.pos, r.pos) > snap_distance then
                    game:enemy_set_position(id, r.pos)
                end
                if r.client_owned or not mirror then self:release_mirror(game, id) end
            end
        end
    end

    -- 4) Tell the host which enemies we have, and where the ones we run are.
    local hz = self.settings.client_enemy_hz or 20
    local interval = 1.0 / hz
    if now - self.last_client_send >= interval then
        self.last_client_send = (now - self.last_client_send >= 2 * interval) and now or (self.last_client_send + interval)
        local share = self.settings.enemy_mirror ~= false
        local states, paired = {}, {}
        for net_id, id in pairs(self.local_of) do
            local r, e = self.remote[net_id], by_id[id]
            if e.alive and r.alive then
                if r.client_owned and share then
                    states[#states + 1] = { net_id = net_id, pos = e.pos, yaw = e.yaw, motion = e.motion }
                else
                    paired[#paired + 1] = net_id
                end
            end
        end
        table.sort(states, function(a, b) return a.net_id < b.net_id end)
        table.sort(paired)
        self.send(P.encode_enemy_client(now, states, paired), false)
    end
end

function EnemySync:client_frame(now, game)
    for net_id, id in pairs(self.local_of) do
        local r, e = self.remote[net_id], self.by_id[id]
        if r ~= nil and e ~= nil and e.alive and r.alive and not r.client_owned and r.interp ~= nil then
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

-- players = { local_pos={x,y,z}|nil, partner_pos={x,y,z}|nil } (the host uses them for ownership)
function EnemySync:tick(now, enemies, game, players)
    self.last_tick = now
    if self.role == "host" then
        self:host_tick(now, enemies, game, players)
    else
        self:client_tick(now, enemies, game)
    end
end

-- Every game frame: moves the enemies the other machine runs.
function EnemySync:frame(now, game)
    if not self:mirroring(game) then
        if next(self.ai_off) ~= nil then self:release_all(game) end
        return
    end
    if self.role == "host" then
        self:host_frame(now, game)
    else
        self:client_frame(now, game)
    end
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
        end
    end
    return false
end

function EnemySync:summary()
    local n_local, n_paired, n_remote, n_client_owned, n_ai_off = 0, 0, 0, 0, 0
    for _ in pairs(self.by_id) do n_local = n_local + 1 end
    for _ in pairs(self.local_of) do n_paired = n_paired + 1 end
    for _ in pairs(self.ai_off) do n_ai_off = n_ai_off + 1 end
    if self.role == "host" then
        for _, o in pairs(self.owner) do
            if o == "client" then n_client_owned = n_client_owned + 1 end
        end
    else
        for _, r in pairs(self.remote) do
            n_remote = n_remote + 1
            if r.alive and r.client_owned then n_client_owned = n_client_owned + 1 end
        end
    end
    return { role = self.role, local_count = n_local, paired = n_paired, remote_count = n_remote,
        client_owned = n_client_owned, mirrored_now = n_ai_off, counters = self.counters,
        spawner_trust = self.trust, spawner_trusted = self:spawner_trusted() }
end

return EnemySync
