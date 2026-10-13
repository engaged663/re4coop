-- Objectives for both players: the objective on screen is the more advanced of the two games'.
--
-- RE4 computes the current objective itself (chainsaw.PurposeManager, docs/RESEARCH.md 3.24):
-- every frame it asks GameConditionCollector for the purpose whose conditions hold - story
-- flags, but also items the player holds, sub-progress, the chapter - and only ever moves on
-- to one of higher priority. Flags cross between the games; held items do not (a key item exists
-- once), so the player who did not pick up the key, place the item or solve the puzzle kept the
-- old objective. Each game reports its objective (PURPOSE: id, priority, message) when it
-- changes; a game whose own objective is less advanced takes the partner's through the game's
-- own updateMainPurpose (the objective banner shows it, exactly as when its own conditions
-- change). Only within the same chapter: purpose IDs carry the chapter (2203 = chapter 2-2,
-- ChapterID 22200).
--
-- Adapter contract (world):
--   world:purpose_read() -> { id, priority, message, display, mediate, delay } | nil
--   world:purpose_apply(p) -> bool   (true once it is ours)

local PurposeSync = {}
PurposeSync.__index = PurposeSync

local READ_INTERVAL = 1.0 -- seconds between reads of our objective
local RESEND = 20.0       -- ours again now and then (a partner who reloaded recomputed theirs)
local RETRY = 10.0        -- a partner objective our game did not take is tried again after this

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function PurposeSync.new(opts)
    local self = setmetatable({}, PurposeSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function PurposeSync:reset()
    self.remote = nil         -- the partner's latest objective
    self.last_sent = nil      -- "id:priority" of ours last sent
    self.last_sent_at = -math.huge
    self.last_read = -math.huge
    self.refused = {}         -- "id:priority" -> time our game did not take it
    self.elsewhere = {}       -- "id:priority" -> true: seen while we were in another chapter (counted once)
    self.counters = { sent = 0, received = 0, applied = 0, refused = 0, other_chapter = 0 }
end

function PurposeSync:enabled()
    return self.settings.sync_purposes ~= false
end

-- The chapter a purpose ID belongs to, as ChapterID's chapter part (2203 -> 22 = ChapterID 22200).
local function purpose_chapter(id)
    return math.floor((id or 0) / 100)
end

local function chapter_code(chapter)
    if chapter == nil then return nil end
    return math.floor((chapter % 10000) / 100)
end

local function key_of(p)
    return ("%d:%d"):format(p.id or 0, p.priority or 0)
end

function PurposeSync:on_message(m, now)
    if m.type ~= self.P.T.PURPOSE then return false end
    self.counters.received = self.counters.received + 1
    m.time = now
    self.remote = m
    return true
end

-- ctx: { ready (playing: no loading screen, no cutscene), chapter (our ChapterID) }
function PurposeSync:tick(now, world, ctx)
    if not self:enabled() or world == nil or world.purpose_read == nil then return end
    ctx = ctx or {}
    if not ctx.ready or now - self.last_read < READ_INTERVAL then return end
    self.last_read = now
    local mine = world:purpose_read()

    -- The partner is further on in this chapter: theirs.
    local r = self.remote
    if r ~= nil and (mine == nil or (r.priority or 0) > (mine.priority or 0)) then
        local k = key_of(r)
        if chapter_code(ctx.chapter) ~= purpose_chapter(r.id) then
            if not self.elsewhere[k] then self.counters.other_chapter = self.counters.other_chapter + 1 end
            self.elsewhere[k] = true
        elseif self.refused[k] == nil or now - self.refused[k] >= RETRY then
            if world:purpose_apply(r) then
                self.counters.applied = self.counters.applied + 1
                self.refused[k] = nil
                mine = world:purpose_read() or r
                self.last_sent = key_of(mine) -- (theirs now: nothing new to tell them)
            else
                self.counters.refused = self.counters.refused + 1
                self.refused[k] = now
            end
        end
    end

    -- Ours, when it changed (and now and then).
    if mine ~= nil and mine.message ~= nil then
        local k = key_of(mine)
        if k ~= self.last_sent or now - self.last_sent_at >= RESEND then
            self.last_sent, self.last_sent_at = k, now
            self.send(self.P.encode_purpose(mine), true)
            self.counters.sent = self.counters.sent + 1
        end
    end
end

function PurposeSync:summary()
    return { counters = self.counters, partner = self.remote and self.remote.id or nil }
end

return PurposeSync
