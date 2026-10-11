-- Enemy loot: every enemy that dies gives each player their own loot roll.
--
-- RE4 rolls an enemy's drop for the player who gets it (the roll looks at that player's
-- inventory and health). In co-op both games must roll for every death - also for an enemy
-- the partner killed, whose death reaches our game through enemy sync (enemy_kill) and may
-- not run the game's own drop code. So:
--   * the drop hooks (game.lua) report every roll the game makes for one of our enemies;
--   * when an enemy dies in our world because the partner's game killed it, and no roll for
--     it is seen within `wait` seconds, we roll it ourselves (game:request_enemy_drop) -
--     exactly once per enemy;
--   * `wait` is learned from our own kills: how long after a death the game's roll comes;
--   * an enemy kind that died by our own hand without any roll does not drop loot: it is not
--     rolled for the partner's kills either.
-- Nothing is rolled until the hooks have attributed at least one roll to an enemy: until then
-- we could not tell a missing roll from a roll we failed to see (that would double the loot).
--
-- Pickups stay per player: the partner's loot exists only in their world, ours only in ours.
--
-- Pure Lua with an adapter, tested offline (tests/lua/test_drop_sync.lua).
-- Adapter contract:
--   drop events = { {enemy_id=<local enemy id>, droptype=<number|nil>, via=<string>}, ... }
--                 (game:take_drop_events(); nil without the hooks)
--   enemies     = game:list_enemies() records {id, kind, alive, ...} (passed on enemy ticks)
--   game:request_enemy_drop(id, droptype) -> ok, reason

local DropSync = {}
DropSync.__index = DropSync

local DEFAULT_WAIT = 2.5     -- seconds to wait for the game's own roll before rolling ourselves
local MIN_WAIT, MAX_WAIT = 1.0, 8.0
local WAIT_MARGIN = 0.75
local DELAY_SAMPLES = 12
local REMOTE_KILL_WINDOW = 5.0 -- an enemy that dies this soon after enemy sync killed it was the partner's kill
local ROLLED_MEMORY = 60.0
local FORGET_AFTER = 10.0      -- seconds an enemy may be missing from the list before it is forgotten

-- opts: { settings, log = function(fmt, ...) }
function DropSync.new(opts)
    local self = setmetatable({}, DropSync)
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
    self:reset()
    return self
end

function DropSync:reset()
    self.alive = {}         -- enemy id -> last alive flag
    self.seen = {}          -- enemy id -> last time it was in the list
    self.kind = {}          -- enemy id -> kind
    self.deaths = {}        -- enemy id -> {time, kind, remote}
    self.rolled = {}        -- enemy id -> time the game rolled its loot
    self.requested = {}     -- enemy id -> time we rolled it ourselves
    self.game_rolled_after = {} -- enemy id -> true: the game rolled it after we did
    self.remote_kills = {}  -- enemy id -> time enemy sync killed it
    self.no_drop = {}       -- kind -> true: died by our hand without a roll
    self.delays = {}        -- seconds between death and the game's roll, our own kills
    self.wait = DEFAULT_WAIT
    self.hook_proven = false
    self.counters = { rolls_seen = 0, natural = 0, requested = 0, request_failed = 0, gone = 0, doubles = 0,
        no_drop_kinds = 0, partner_kills = 0 }
end

-- The game reloaded: enemy ids are about to be reused. What was learned stays.
function DropSync:forget_enemies()
    self.alive, self.seen, self.kind, self.deaths = {}, {}, {}, {}
    self.rolled, self.requested, self.remote_kills, self.game_rolled_after = {}, {}, {}, {}
end

function DropSync:enabled()
    return self.settings.sync_drops ~= false
end

-- Enemy sync killed enemy `id` in our world because the partner's game did.
function DropSync:on_remote_kill(id, now)
    self.remote_kills[id] = now
end

function DropSync:learn_delay(delay)
    if delay < 0 then delay = 0 end
    local d = self.delays
    d[#d + 1] = delay
    if #d > DELAY_SAMPLES then table.remove(d, 1) end
    local max = 0
    for _, v in ipairs(d) do if v > max then max = v end end
    self.wait = math.max(MIN_WAIT, math.min(MAX_WAIT, max + WAIT_MARGIN))
end

-- Every update. events: game:take_drop_events() (nil without the hooks); enemies: the list
-- from this update's enemy tick, or nil when there was none.
--
-- A death stays on record for MAX_WAIT seconds: our own kills to learn how long the game
-- takes to roll (or that it does not roll for that kind), the partner's kills to notice a
-- game roll that comes after ours (then the wait grows).
function DropSync:update(now, enemies, events, game)
    if not self:enabled() then return end
    for _, ev in ipairs(events or {}) do
        local id = ev.enemy_id
        self.counters.rolls_seen = self.counters.rolls_seen + 1
        self.hook_proven = true
        local first = self.rolled[id] == nil or (self.deaths[id] ~= nil and self.rolled[id] < self.deaths[id].time - MAX_WAIT)
        local ours = self.requested[id] ~= nil and ev.via == "generate" and not self.game_rolled_after[id]
        if self.requested[id] ~= nil and ev.via ~= "generate" and not self.game_rolled_after[id] then
            -- The game rolled after we did (our own request reports itself as "generate").
            self.game_rolled_after[id] = true
            self.counters.doubles = self.counters.doubles + 1
            local d = self.deaths[id]
            if d ~= nil then self:learn_delay(now - d.time) end
        elseif first and not ours then
            self.counters.natural = self.counters.natural + 1
            local d = self.deaths[id]
            if d ~= nil and not d.remote then self:learn_delay(now - d.time) end
        end
        if not ours then self.rolled[id] = now end
        local d = self.deaths[id]
        if d ~= nil and not d.remote then self.deaths[id] = nil end -- our kill: settled
    end

    if enemies ~= nil then
        for _, e in ipairs(enemies) do
            local id = e.id
            if self.alive[id] == true and not e.alive and self.deaths[id] == nil then
                local rk = self.remote_kills[id]
                local remote = rk ~= nil and now - rk <= REMOTE_KILL_WINDOW
                if remote then self.counters.partner_kills = self.counters.partner_kills + 1 end
                local r = self.rolled[id]
                if r ~= nil and now - r <= self.wait then
                    -- The game rolled in the frame the enemy died, before our list noticed.
                    if not remote then self:learn_delay(0) end
                else
                    self.deaths[id] = { time = now, kind = e.kind, remote = remote }
                end
            end
            self.alive[id] = e.alive
            self.seen[id] = now
            self.kind[id] = e.kind
        end
        for id, t in pairs(self.seen) do
            if now - t > FORGET_AFTER then
                self.seen[id], self.alive[id], self.kind[id] = nil, nil, nil
                self.requested[id], self.remote_kills[id], self.game_rolled_after[id] = nil, nil, nil
            end
        end
    end

    for id, d in pairs(self.deaths) do
        local age = now - d.time
        if d.remote then
            if not d.handled and age >= self.wait then
                d.handled = true
                if self.rolled[id] == nil or self.rolled[id] < d.time - self.wait then
                    self:roll(id, d, game)
                end
            end
            if age >= MAX_WAIT then self.deaths[id] = nil end
        elseif age >= MAX_WAIT then
            self.deaths[id] = nil
            if self.hook_proven and not self.no_drop[d.kind] then
                -- Our own kill and the game rolled nothing: this kind does not drop loot.
                self.no_drop[d.kind] = true
                self.counters.no_drop_kinds = self.counters.no_drop_kinds + 1
            end
        end
    end
    for id, t in pairs(self.rolled) do
        if now - t > ROLLED_MEMORY then self.rolled[id] = nil end
    end
    for id, t in pairs(self.remote_kills) do
        if now - t > ROLLED_MEMORY then self.remote_kills[id] = nil end
    end
end

function DropSync:roll(id, d, game)
    if not self.hook_proven or self.no_drop[d.kind] or self.requested[id] ~= nil then return end
    if game == nil or game.request_enemy_drop == nil then return end
    self.requested[id] = d.time
    local ok, why = game:request_enemy_drop(id)
    if ok then
        self.counters.requested = self.counters.requested + 1
    elseif why == "enemy gone" then
        self.counters.gone = self.counters.gone + 1
    else
        self.counters.request_failed = self.counters.request_failed + 1
        self.log("loot roll for the partner's kill failed: %s", tostring(why))
    end
end

function DropSync:summary()
    local state
    if not self:enabled() then
        state = "off"
    elseif not self.hook_proven then
        state = "waiting for the first enemy drop"
    else
        state = ("on (waits %.1f s for the game's roll)"):format(self.wait)
    end
    return { state = state, counters = self.counters, wait = self.wait }
end

return DropSync
