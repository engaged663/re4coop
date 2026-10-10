-- Host-authoritative enemy synchronisation.
--
-- Both games load the same chapter, so the level spawns the same enemies on both machines.
-- Each side runs its own enemy AI; this module keeps their *outcomes* consistent:
--   * host: numbers its enemies, broadcasts HP/alive/position snapshots, applies damage
--     reported by the client;
--   * client: pairs each host enemy with its own copy (same kind, same spawn point),
--     reports damage it deals, and lowers HP / kills / nudges its copies to match the host.
--
-- Game access goes through an adapter (see game.lua) so this file is pure Lua and is
-- tested offline against a fake world (tests/lua/test_enemy_sync.lua).
--
-- Adapter contract:
--   enemies = { {id=<number>, kind=<string>, pos={x,y,z}, yaw=<number>, hp=<number>,
--               max_hp=<number>, alive=<bool>}, ... }        (passed to tick)
--   game:enemy_set_hp(id, hp) -> bool
--   game:enemy_kill(id) -> bool
--   game:enemy_set_position(id, pos) -> bool

local EnemySync = {}
EnemySync.__index = EnemySync

local HP_EPS = 0.01
local FORGET_AFTER = 5.0          -- seconds an enemy may be missing from the list before we forget it
local DEAD_REPORT_WINDOW = 180.0  -- host keeps advertising recent deaths for late joiners/areas
local DEAD_EVERY_N_SNAPSHOTS = 5  -- ...but only on every Nth snapshot to save bandwidth
local MAX_DEAD_ENTRIES = 90

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function copy3(v)
    return { x = v.x, y = v.y, z = v.z }
end

-- opts: { role="host"|"client", protocol=<protocol module>, send=function(bytes, reliable),
--         settings=<table read live: sync_hp, sync_deaths, snapshot_hz, match_radius, snap_distance>,
--         log=function(fmt, ...) }
function EnemySync.new(opts)
    local self = setmetatable({}, EnemySync)
    self.role = opts.role
    self.P = opts.protocol
    self.send = opts.send
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
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
    self.dead = {}          -- net id -> {kind_hash, pos, spawn, max_hp, time}
    self.next_net_id = 1
    self.last_snapshot = -math.huge
    self.snapshot_count = 0

    -- client
    self.remote = {}        -- net id -> latest host entry (+ .updated)
    self.expected_hp = {}   -- local id -> HP we have already accounted for
    self.self_killed = {}   -- local ids we killed to mirror the host (don't report them back)

    self.counters = { damage_sent = 0, damage_applied = 0, kills_applied = 0, hp_applied = 0, snaps = 0 }
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
            local net_id = self.net_of[id]
            if net_id ~= nil then
                self.net_of[id] = nil
                if self.local_of[net_id] == id then self.local_of[net_id] = nil end
            end
        end
    end
    return by_id
end

-- Closest local enemy of the given kind whose spawn (or, failing that, current position)
-- is within the match radius. `taken` excludes enemies already paired.
function EnemySync:find_match(kind_hash, spawn_pos, cur_pos, taken, want_alive)
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
    return best
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

function EnemySync:host_tick(now, enemies, game)
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
                    max_hp = e.max_hp, time = now,
                }
            end
            self.alive_of[e.id] = e.alive
        end
    end

    for net_id, d in pairs(self.dead) do
        if now - d.time > DEAD_REPORT_WINDOW then
            self.dead[net_id] = nil
        end
    end

    local hz = self.settings.snapshot_hz or 10
    if now - self.last_snapshot < 1.0 / hz then
        return
    end
    self.last_snapshot = now
    self.snapshot_count = self.snapshot_count + 1

    local alive_flag = self.P.ENEMY_FLAGS.ALIVE
    local entries = {}
    for _, e in ipairs(enemies) do
        local net_id = self.net_of[e.id]
        if net_id ~= nil and e.alive then
            entries[#entries + 1] = {
                net_id = net_id, kind_hash = e.kind_hash, pos = e.pos, spawn = self.spawn[e.id],
                yaw = e.yaw, hp = e.hp, max_hp = e.max_hp, flags = alive_flag,
            }
        end
    end
    if self.snapshot_count % DEAD_EVERY_N_SNAPSHOTS == 0 then
        local dead_list = {}
        for net_id, d in pairs(self.dead) do
            dead_list[#dead_list + 1] = { net_id = net_id, d = d }
        end
        table.sort(dead_list, function(a, b) return a.d.time > b.d.time end)
        for i = 1, math.min(#dead_list, MAX_DEAD_ENTRIES) do
            local x = dead_list[i]
            entries[#entries + 1] = {
                net_id = x.net_id, kind_hash = x.d.kind_hash, pos = x.d.pos, spawn = x.d.spawn,
                yaw = 0, hp = 0, max_hp = x.d.max_hp, flags = 0,
            }
        end
    end
    -- Always send at least one (possibly empty) snapshot so the client sees host liveness.
    for _, msg in ipairs(self.P.encode_enemy_snapshots(now, entries)) do
        self.send(msg, false)
    end
    self.counters.snaps = self.counters.snaps + 1
end

function EnemySync:host_on_damage(m, game)
    local id = m.net_id ~= 0 and self.local_of[m.net_id] or nil
    local e = id and self.by_id[id] or nil
    if e == nil then
        local match = self:find_match(m.kind_hash, m.pos, m.pos, {}, true)
        e = match and self.by_id[match] or nil
    end
    if e == nil or not e.alive then
        return false
    end

    local lethal = (m.flags & self.P.DAMAGE_FLAGS.LETHAL) ~= 0
    local new_hp = e.hp - m.amount
    if lethal or new_hp <= HP_EPS then
        if self.settings.sync_deaths ~= false and game:enemy_kill(e.id) then
            e.hp = 0
            self.counters.kills_applied = self.counters.kills_applied + 1
            return true
        end
    elseif self.settings.sync_hp ~= false and game:enemy_set_hp(e.id, new_hp) then
        e.hp = new_hp
        self.counters.damage_applied = self.counters.damage_applied + 1
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Client
-------------------------------------------------------------------------------

function EnemySync:client_on_snapshot(m, now)
    for _, r in ipairs(m.enemies) do
        r.alive = (r.flags & self.P.ENEMY_FLAGS.ALIVE) ~= 0
        r.updated = now
        local prev = self.remote[r.net_id]
        if prev ~= nil and prev.kind_hash ~= r.kind_hash then
            -- Host recycled the id for another enemy: drop the old pairing.
            local id = self.local_of[r.net_id]
            if id ~= nil then self.net_of[id] = nil end
            self.local_of[r.net_id] = nil
        end
        if prev ~= nil and not prev.alive and r.alive and prev.kind_hash == r.kind_hash then
            -- A stale alive snapshot arriving after the death notice; keep it dead.
            r.alive = false
        end
        self.remote[r.net_id] = r
    end
end

function EnemySync:client_on_dead(m, now)
    local r = self.remote[m.net_id]
    if r ~= nil then
        r.alive = false
        r.hp = 0
        r.updated = now
    end
end

function EnemySync:client_tick(now, enemies, game)
    local by_id = self:observe(now, enemies)

    for net_id, r in pairs(self.remote) do
        if now - r.updated > DEAD_REPORT_WINDOW then
            self.remote[net_id] = nil
        end
    end
    for net_id, id in pairs(self.local_of) do
        if by_id[id] == nil or self.remote[net_id] == nil then
            self.local_of[net_id] = nil
            if self.net_of[id] == net_id then self.net_of[id] = nil end
        end
    end

    -- 1) Damage we dealt locally since last tick goes to the host.
    local P = self.P
    for _, e in ipairs(enemies) do
        local expected = self.expected_hp[e.id]
        if expected == nil then
            self.expected_hp[e.id] = e.hp
        elseif e.hp < expected - HP_EPS then
            if not self.self_killed[e.id] then
                local lethal = (not e.alive) or e.hp <= HP_EPS
                self.send(P.encode_enemy_damage({
                    net_id = self.net_of[e.id] or 0,
                    kind_hash = e.kind_hash,
                    pos = self.spawn[e.id] or e.pos,
                    amount = expected - e.hp,
                    flags = lethal and P.DAMAGE_FLAGS.LETHAL or 0,
                }), true)
                self.counters.damage_sent = self.counters.damage_sent + 1
            end
            self.expected_hp[e.id] = e.hp
        elseif e.hp > expected + HP_EPS then
            self.expected_hp[e.id] = e.hp -- regenerated/reset locally
        end
    end

    -- 2) Pair host enemies with ours. Deterministic order keeps both runs identical.
    local unpaired = {}
    for net_id, r in pairs(self.remote) do
        if self.local_of[net_id] == nil then
            unpaired[#unpaired + 1] = net_id
        end
    end
    table.sort(unpaired)
    local taken = {}
    for id in pairs(self.net_of) do taken[id] = true end
    for _, net_id in ipairs(unpaired) do
        local r = self.remote[net_id]
        local id = self:find_match(r.kind_hash, r.spawn or r.pos, r.alive and r.pos or nil, taken, true)
        if id ~= nil then
            self.local_of[net_id] = id
            self.net_of[id] = net_id
            taken[id] = true
        end
    end

    -- 3) Apply the host's outcome to our copies.
    local snap_distance = self.settings.snap_distance or 0
    for net_id, id in pairs(self.local_of) do
        local r, e = self.remote[net_id], by_id[id]
        if e.alive then
            if not r.alive then
                if self.settings.sync_deaths ~= false and game:enemy_kill(id) then
                    self.self_killed[id] = true
                    self.expected_hp[id] = 0
                    self.counters.kills_applied = self.counters.kills_applied + 1
                end
            else
                if self.settings.sync_hp ~= false and r.hp < e.hp - HP_EPS then
                    if game:enemy_set_hp(id, r.hp) then
                        self.expected_hp[id] = r.hp
                        self.counters.hp_applied = self.counters.hp_applied + 1
                    end
                end
                if snap_distance > 0 and dist(e.pos, r.pos) > snap_distance then
                    game:enemy_set_position(id, r.pos)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------

function EnemySync:tick(now, enemies, game)
    if self.role == "host" then
        self:host_tick(now, enemies, game)
    else
        self:client_tick(now, enemies, game)
    end
end

-- Returns true if the message was an enemy message (consumed).
function EnemySync:on_message(m, now, game)
    local T = self.P.T
    if self.role == "host" then
        if m.type == T.ENEMY_DAMAGE then
            self:host_on_damage(m, game)
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
    local n_local, n_paired, n_remote = 0, 0, 0
    for _ in pairs(self.by_id) do n_local = n_local + 1 end
    if self.role == "host" then
        for _ in pairs(self.local_of) do n_paired = n_paired + 1 end
    else
        for _ in pairs(self.local_of) do n_paired = n_paired + 1 end
        for _ in pairs(self.remote) do n_remote = n_remote + 1 end
    end
    return { role = self.role, local_count = n_local, paired = n_paired, remote_count = n_remote, counters = self.counters }
end

return EnemySync
