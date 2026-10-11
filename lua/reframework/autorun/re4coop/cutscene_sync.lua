-- Cutscene synchronisation: when one player triggers a cutscene (a timeline event), the
-- partner's game plays the same one, so both watch it and both games run its consequences
-- (flags it sets, doors it opens, where it leaves the characters). If the partner is in
-- another area, they are first brought next to the player who triggered it.
--
-- Adapter contract (world):
--   world:cutscene_playing() -> <event id> | true (playing, id unknown) | nil
--   world:cutscene_play(id, method) -> bool
-- Travel (optional): travel:request(target) / travel:busy()

local CutsceneSync = {}
CutsceneSync.__index = CutsceneSync

local DEDUPE_WINDOW = 15.0   -- the same cutscene from both sides within this window is one cutscene
local SEEN_WINDOW = 60.0     -- we played/triggered it this recently: the partner's notice is old news
local PENDING_TIMEOUT = 60.0
local MAX_TRIES = 5
local FAR = 30.0

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...), notify(text, kind) }
function CutsceneSync.new(opts)
    local self = setmetatable({}, CutsceneSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self.notify = opts.notify or function() end
    self:reset()
    return self
end

function CutsceneSync:reset()
    self.pending = nil
    self.replaying = false
    self.suppress = {}  -- id -> until (we are replaying the partner's cutscene)
    self.sent = {}      -- id -> time we announced it
    self.played = {}    -- id -> time we played or triggered it
    self.counters = { sent = 0, received = 0, played = 0, dropped = 0 }
end

function CutsceneSync:enabled()
    return self.settings.sync_cutscenes ~= false
end

-- The local game started a cutscene (adapter hook or detection).
function CutsceneSync:on_local_start(id, method, now, loc)
    if not self:enabled() or id == nil then return false end
    if self.replaying then return false end
    local s = self.suppress[id]
    if s ~= nil and now < s then return false end
    self.played[id] = now
    local t = self.sent[id]
    if t ~= nil and now - t < DEDUPE_WINDOW then
        -- Repeated calls for the same cutscene (some request methods run every frame while it
        -- plays) keep the window open instead of announcing it again.
        self.sent[id] = now
        return false
    end
    self.sent[id] = now
    if self.pending ~= nil and self.pending.id == id then
        self.pending = nil -- we reached it ourselves
    end
    loc = loc or {}
    self.send(self.P.encode_cutscene({
        id = id, method = method, chapter = loc.chapter, stage = loc.stage, pos = loc.pos,
        flags = self.P.CUTSCENE_FLAGS.LOCAL_TRIGGER,
    }), true)
    self.counters.sent = self.counters.sent + 1
    return true
end

function CutsceneSync:on_cutscene(m, now)
    if not self:enabled() then return end
    self.counters.received = self.counters.received + 1
    local seen = self.played[m.id]
    if seen ~= nil and now - seen < SEEN_WINDOW then
        return -- both triggered it, or we already watched it
    end
    self.pending = { id = m.id, method = m.method, stage = m.stage, chapter = m.chapter, pos = m.pos,
        time = now, tries = 0 }
end

function CutsceneSync:drop(why)
    if self.pending ~= nil then
        self.log("cutscene %d not replayed: %s", self.pending.id, why)
        self.counters.dropped = self.counters.dropped + 1
    end
    self.pending = nil
end

-- loc = { chapter, stage, pos, loading, playable }
function CutsceneSync:tick(now, world, loc, travel)
    local p = self.pending
    if p == nil or not self:enabled() then return end
    if now - p.time > PENDING_TIMEOUT then
        return self:drop("timed out")
    end
    local playing = world:cutscene_playing()
    if playing == p.id then
        self.played[p.id] = now
        self.pending = nil
        return
    end
    if playing ~= nil then return end -- let the current one finish
    if loc == nil or loc.loading or not loc.playable then return end
    if p.chapter ~= nil and p.chapter >= 0 and loc.chapter ~= nil and loc.chapter >= 0 and loc.chapter ~= p.chapter then
        return self:drop("partner is in another chapter")
    end

    local far = p.stage ~= nil and p.stage >= 0 and loc.stage ~= nil and loc.stage ~= p.stage
    if not far and p.pos ~= nil and loc.pos ~= nil and (p.pos.x ~= 0 or p.pos.y ~= 0 or p.pos.z ~= 0) then
        far = dist(p.pos, loc.pos) > FAR
    end
    if far and travel ~= nil and self.settings.cutscene_travel ~= false then
        if not p.travel_requested then
            p.travel_requested = true
            self.notify("Partner started a cutscene - joining them", "info")
            travel:request({ chapter = p.chapter, stage = p.stage, pos = p.pos, reason = "cutscene" })
            return
        end
        if travel:busy() then return end
    end

    self.replaying = true
    self.suppress[p.id] = now + 20
    local ok = world:cutscene_play(p.id, p.method)
    self.replaying = false
    if ok then
        self.played[p.id] = now
        self.counters.played = self.counters.played + 1
        self.pending = nil
    else
        p.tries = p.tries + 1
        if p.tries >= MAX_TRIES then self:drop("the game refused to play it") end
    end
end

function CutsceneSync:on_message(m, now)
    if m.type == self.P.T.CUTSCENE then
        self:on_cutscene(m, now)
        return true
    end
    return false
end

function CutsceneSync:summary()
    return { counters = self.counters, pending = self.pending and self.pending.id or nil }
end

return CutsceneSync
