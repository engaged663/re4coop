-- Animal synchronisation: the host's game moves the animals (crows, chickens, fish, bats,
-- rats); the client's copies of the ones near both players follow them.
--
-- Animals are identified by their GameObject GUID (level data, the same on both PCs). About
-- ten times a second the host sends the animals within RADIUS of the client's player
-- (ANIMALS: position, rotation, routine, animation). The client takes each of those copies
-- off its game's update - its own AI stops - and moves it along the host's through an
-- interpolation buffer, playing the host's animation. The host is the only authority: an
-- animal near the client that the host does not report (not loaded in its game) is held -
-- taken off the update where it is - and a puppet without news from the host stays where it
-- is. (With animal_host_only off, those run on their own as in 0.8.)
--
-- Deaths: a host animal that dies (its routine reaches Die/Dead) dies in the client's game
-- with its own death, where the host's copy was. An animal the client's player shoots dies
-- in the client's game at once (the shot sets its routine even while it is a puppet): it is
-- released to play its death, and the kill goes to the host right away (OBJECTS, through
-- object_sync) so it dies there too. A dead animal is never a puppet again.
--
-- Adapter contract (world, see game_world.lua):
--   world:animals_near(points, radius, max) -> { {guid, pos, rot, routine, motion, dead}, ... }  (host)
--   world:animal_local(guid) -> { pos, routine, dead } | nil  (client: our copy, nil when not loaded)
--   world:animal_puppet(guid, on) -> bool                     (client: its own AI off / back on)
--   world:animal_set_transform(guid, pos, rot) -> bool
--   world:animal_set_motion(guid, motion) -> bool
--   world:animal_kill(guid) -> bool                           (dies with its own logic)
--   world:restore_animals()                                   (every animal runs on its own again)

local Interp = require("re4coop.interp")

local AnimalSync = {}
AnimalSync.__index = AnimalSync

local SEND_HZ = 10
AnimalSync.RADIUS = 50.0     -- metres: animals this close to the client's player follow the host
AnimalSync.MAX_ANIMALS = 24  -- host: animals sent per round (the nearest to the client first)
local STALE = 1.0            -- client: a puppet without news for this long runs on its own
local FORGET = 5.0           -- client: a host animal not reported for this long is forgotten
local INTERP_DELAY = 0.15    -- two sends at 10 Hz, plus jitter
local NEAR_FRAME = 20.0      -- client: puppets nearer than this move every frame...
local FAR_STRIDE = 3         -- ...the others every third frame
local LOCAL_CHECK = 0.1      -- client: seconds between looks at a puppet's own routine (was it shot?)
local RETRY = 0.25           -- client: seconds before an animal that could not become a puppet is tried again
local HOLD_SCAN = 0.5        -- client: seconds between looks for animals the host does not report

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...),
--         on_local_kill(guid, routine, now): our player killed a puppet (report it to the host),
--         on_remote_kill(guid, now): we killed our copy because the host's died }
function AnimalSync.new(opts)
    local self = setmetatable({}, AnimalSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self.on_local_kill = opts.on_local_kill or function() end
    self.on_remote_kill = opts.on_remote_kill or function() end
    self:reset()
    return self
end

function AnimalSync:reset()
    self.last_send = -math.huge
    self.frame_n = 0
    self.remote = {}   -- client: guid -> { interp, updated, dead }: the host's animals
    self.puppets = {}  -- client: guid -> { motion, last_check, dist }: our copies that follow them
    self.dead = {}     -- client: guid -> true: died in one of the games; runs its own death
    self.last_hold_scan = -math.huge
    self.counters = { sent = 0, received = 0, puppeted = 0, released = 0, moves = 0, motions = 0,
        kills_applied = 0, kills_reported = 0, held = 0 }
end

function AnimalSync:enabled()
    return self.settings.sync_animals ~= false
end

-- The host is the only authority: no animal near the client runs on its own.
function AnimalSync:host_only()
    return self.settings.animal_host_only ~= false
end

-------------------------------------------------------------------------------
-- Host
-------------------------------------------------------------------------------

function AnimalSync:host_tick(now, world, local_pos, partner_pos)
    local interval = 1.0 / SEND_HZ
    if now - self.last_send < interval then return end
    self.last_send = (now - self.last_send >= 2 * interval) and now or (self.last_send + interval)
    if partner_pos == nil or world.animals_near == nil then return end
    local animals = world:animals_near({ partner_pos }, AnimalSync.RADIUS, AnimalSync.MAX_ANIMALS)
    if #animals == 0 then return end
    for _, msg in ipairs(self.P.encode_animals(now, animals)) do
        self.send(msg, false)
    end
    self.counters.sent = self.counters.sent + #animals
end

-------------------------------------------------------------------------------
-- Client
-------------------------------------------------------------------------------

function AnimalSync:client_on_animals(m, now)
    for _, a in ipairs(m.animals) do
        if a.guid ~= nil then
            local r = self.remote[a.guid]
            if r == nil then
                r = { interp = Interp.new({ delay = INTERP_DELAY, max_delay = 0.3, adaptive = true,
                    max_extrapolate = 0.2, capacity = 12 }) }
                self.remote[a.guid] = r
            end
            r.updated = now
            r.dead = a.dead
            r.interp:push(m.time, now, { pos = a.pos, rot = a.rot, motion = a.motion })
            self.counters.received = self.counters.received + 1
        end
    end
end

-- Our copy runs its own AI again.
function AnimalSync:release(world, guid)
    if self.puppets[guid] == nil then return end
    self.puppets[guid] = nil
    world:animal_puppet(guid, false)
    self.counters.released = self.counters.released + 1
end

-- Every copy runs its own AI again (animal sync switched off, session over).
function AnimalSync:release_all(world)
    for guid in pairs(self.puppets) do
        if world ~= nil then world:animal_puppet(guid, false) end
    end
    self.puppets = {}
    if world ~= nil and world.restore_animals ~= nil then world:restore_animals() end
end

-- Our copy of a living host animal follows it (becoming a puppet first).
function AnimalSync:drive(now, world, guid, r, local_pos)
    local p = self.puppets[guid]
    if p == nil and now - (r.tried or -math.huge) < RETRY then return end
    if p == nil or now - p.last_check >= LOCAL_CHECK then
        r.tried = now
        local mine = world:animal_local(guid)
        if mine == nil then
            self.puppets[guid] = nil -- not loaded here (or gone with its area)
            return
        end
        if mine.dead then
            self.dead[guid] = true
            if p ~= nil then
                -- Our player shot it: it plays its own death, and the host's animal dies too.
                self:release(world, guid)
                self.counters.kills_reported = self.counters.kills_reported + 1
                self.on_local_kill(guid, mine.routine, now)
            end
            return
        end
        if p == nil then
            if not world:animal_puppet(guid, true) then return end
            p = {}
            self.puppets[guid] = p
            self.counters.puppeted = self.counters.puppeted + 1
        end
        p.last_check = now
        p.dist = (local_pos ~= nil and mine.pos ~= nil) and dist(mine.pos, local_pos) or 0
    end
    if p.dist > NEAR_FRAME and self.frame_n % FAR_STRIDE ~= 0 then return end
    local st = r.interp:sample(now)
    if st == nil then return end
    if world:animal_set_transform(guid, st.pos, st.rot) then
        self.counters.moves = self.counters.moves + 1
    end
    if st.motion ~= nil and self.settings.enemy_motion_sync ~= false then
        local key = ("%d:%d"):format(st.motion.bank or 0, st.motion.id or 0)
        if p.motion ~= key and world:animal_set_motion(guid, st.motion) then
            p.motion = key
            self.counters.motions = self.counters.motions + 1
        end
    end
end

-- Host only: the animals near our player the host does not report are taken off our game's
-- update where they are (held). One our player shot plays its own death, and the host is told.
function AnimalSync:hold_unreported(now, world, local_pos)
    if now - self.last_hold_scan < HOLD_SCAN then return end
    self.last_hold_scan = now
    if local_pos == nil or world.animals_near == nil then return end
    for _, a in ipairs(world:animals_near({ local_pos }, AnimalSync.RADIUS, AnimalSync.MAX_ANIMALS)) do
        local guid = a.guid
        if guid ~= nil and self.remote[guid] == nil and not self.dead[guid] then
            local p = self.puppets[guid]
            if a.dead then
                self.dead[guid] = true
                if p ~= nil then
                    self:release(world, guid)
                    self.counters.kills_reported = self.counters.kills_reported + 1
                    self.on_local_kill(guid, a.routine, now)
                end
            elseif p == nil and world:animal_puppet(guid, true) then
                self.puppets[guid] = { last_check = now, dist = dist(a.pos, local_pos) }
                self.counters.held = self.counters.held + 1
            end
        end
    end
end

function AnimalSync:client_tick(now, world, local_pos)
    self.frame_n = self.frame_n + 1
    local host_only = self:host_only()
    for guid, r in pairs(self.remote) do
        if now - r.updated > FORGET then
            if not host_only then self:release(world, guid) end -- host only: held where it is
            self.remote[guid] = nil
        elseif self.dead[guid] then
            self:release(world, guid) -- (already released when it died)
        elseif r.dead then
            -- The host's animal died: ours dies where it followed it to.
            self:release(world, guid)
            self.dead[guid] = true
            if world:animal_kill(guid) then
                self.counters.kills_applied = self.counters.kills_applied + 1
                self.on_remote_kill(guid, now)
            end
        elseif now - r.updated > STALE then
            -- No news from the host: ours acts on its own, or (host only) waits where it is.
            if not host_only then self:release(world, guid) end
        else
            self:drive(now, world, guid, r, local_pos)
        end
    end
    if host_only then self:hold_unreported(now, world, local_pos) end
end

-------------------------------------------------------------------------------

-- Every game frame. players = { local_pos, partner_pos }: the host sends the animals near the client.
function AnimalSync:tick(now, world, players)
    if world == nil then return end
    if not self:enabled() then
        if next(self.puppets) ~= nil then self:release_all(world) end
        return
    end
    local local_pos = players and players.local_pos or nil
    if self.role == "host" then
        self:host_tick(now, world, local_pos, players and players.partner_pos or nil)
    else
        self:client_tick(now, world, local_pos)
    end
end

-- Our game reloaded: its animals are new (the world adapter gave the old ones back).
function AnimalSync:on_local_reload()
    self.puppets = {}
    self.dead = {}
    self.remote = {}
end

function AnimalSync:on_message(m, now)
    if m.type ~= self.P.T.ANIMALS then return false end
    if self.role == "client" and self:enabled() then self:client_on_animals(m, now) end
    return true
end

function AnimalSync:summary()
    local n_remote, n_puppets = 0, 0
    for _ in pairs(self.remote) do n_remote = n_remote + 1 end
    for _ in pairs(self.puppets) do n_puppets = n_puppets + 1 end
    return { role = self.role, remote = n_remote, puppets = n_puppets, counters = self.counters }
end

return AnimalSync
