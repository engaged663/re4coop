-- Cutscene synchronisation: when one player's game starts a cutscene (a timeline event) or a
-- movie, the partner's game plays the same one, so both watch it and both games run its
-- consequences (the flags it sets, the scripted sequence it continues, where it leaves the
-- characters). It starts in the partner's game at once, wherever their player is; a partner who
-- was far away is brought next to the player who started it when it ends.
--
-- RE4 prepared this itself (docs/RESEARCH.md 3.11): every story cutscene is requested "play
-- once" through chainsaw.ClapperboardMediator, and calcRequest then packs the request into a
-- PayloadPlay - camera type and ID, screen, start and end flags, the data owner whose scripted
-- sequence continues when it ends, that next step, and the player placements of a movie - and
-- plays it through procPayloadPlay. The adapter reports every payload our game plays; the
-- partner's game plays the same payload through its own procPayloadPlay, so its copy sets its
-- own start/end flags, places its own player and continues its own scripted sequence when it
-- ends, exactly as if its own player had started it.
--
-- Adapter contract (world):
--   world:cutscene_playing() -> true | nil
--   world:cutscene_done(camera, id) -> bool|nil   (this save already played it: never twice)
--   world:cutscene_play(ev) -> bool, why          (ev as P.encode_cutscene / the decoded message)
--   world:cutscene_skip(camera, id, now) -> "skipped" | "waiting" | "done" | "missing" | "failed"
--
-- Skips: when one player skips a cutscene (the game's skip button), the same cutscene is
-- skipped in the partner's game too - once a player there could skip it: playing, its start
-- fade over, its skip prompt up for a moment (a skip that landed in the cutscene's first frames
-- left the screen black, docs/RESEARCH.md 3.36). The game skips it the way its own button does,
-- so a cutscene that cannot be skipped there is not.
--
-- Both games run the same level, so the game whose copy is the partner's often asks for the
-- same cutscene itself a moment later (its own trigger or timer). Its game would queue that
-- request behind our copy and show the cutscene a second time; started inside the fade of a
-- skip, that second showing stayed black for good (docs/RESEARCH.md 3.37). on_local_start
-- answers "repeat" for it and the adapter drops it.
-- Travel (optional): travel:request(target) / travel:busy()
-- opts.on_replay(started, now): a replay of the partner's cutscene started / ended here

local CutsceneSync = {}
CutsceneSync.__index = CutsceneSync

local DEDUPE_WINDOW = 15.0   -- the same cutscene from both sides within this window is one cutscene
local SEEN_WINDOW = 60.0     -- we played/triggered it this recently: the partner's notice is old news
local PENDING_TIMEOUT = 60.0
local GRACE = 0.3            -- seconds a notice waits: our own game may start the same cutscene by itself
                             -- (the partner's trigger or flags just arrived here too)
local MAX_TRIES = 5
local MAX_PENDING = 4
local FAR = 30.0
local START_TIMEOUT = 15.0   -- a replay that never shows up as playing here counts as over
local SKIP_WINDOW = 60.0     -- a partner's skip waits at most this long for the cutscene to be skippable here
local SKIP_MISSING = 10.0    -- ...and this long for it to start here, unless a replay of it is on its way
local REPEAT_WINDOW = 60.0   -- our game asking for a cutscene its partner's copy ended this recently: a repeat

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function key_of(ev)
    return tostring(ev.camera or 1) .. ":" .. tostring(ev.id)
end
CutsceneSync.key_of = key_of

-- A movie request plays the timeline of the same number on PC: the game reports its start as a
-- movie and its skip as a timeline (docs/RESEARCH.md 3.36). Skips match by the number alone.
local function id_of(k)
    return tostring(k):match(":(%-?%d+)$") or tostring(k)
end

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...), notify(text, kind), on_replay }
function CutsceneSync.new(opts)
    local self = setmetatable({}, CutsceneSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self.notify = opts.notify or function() end
    self.on_replay = opts.on_replay or function() end
    self:reset()
    return self
end

function CutsceneSync:reset()
    if self.replay ~= nil then
        self.replay = nil
        self.on_replay(false, nil)
    end
    self.pending = {}   -- notices waiting to be played here: {ev, time, tries, not_before}
    self.sent = {}      -- key -> time we announced it
    self.played = {}    -- key -> time we played or triggered it
    self.replay = nil   -- {key, started, seen}: our copy of the partner's cutscene
    self.replayed = {}  -- cutscene number -> time our copy of it ended after playing here
    self.skips = {}     -- key -> {ev, time}: partner skips waiting for that cutscene to play here
    self.skipped = {}   -- key -> time we skipped it for the partner (not reported back)
    self.counters = { sent = 0, received = 0, played = 0, dropped = 0, already_seen = 0, skips_sent = 0,
        skips_received = 0, skips_applied = 0, repeats = 0 }
end

function CutsceneSync:enabled()
    return self.settings.sync_cutscenes ~= false
end

-- Our game asks for a cutscene it is showing - or showed a moment ago - as the partner's copy.
function CutsceneSync:is_repeat(ev, now)
    local id = tostring(ev.id)
    if self.replay ~= nil and id_of(self.replay.key) == id then return true end
    local t = self.replayed[id]
    return t ~= nil and now - t < REPEAT_WINDOW
end

-- The local game started a cutscene (adapter hook on procPayloadPlay).
-- ev = { camera, id, screen, owner_code, end_portrayal, start_flags, end_flags, coords }
-- Returns true when it was sent to the partner, "repeat" when it must not play here (the
-- partner's copy of it is that cutscene here), false otherwise.
function CutsceneSync:on_local_start(ev, now, loc)
    if not self:enabled() or ev == nil or ev.id == nil then return false end
    local k = key_of(ev)
    if self:is_repeat(ev, now) then
        self.counters.repeats = self.counters.repeats + 1
        self.log("cutscene %s: our game asked for it again after the partner's copy - not shown twice", k)
        return "repeat"
    end
    self.played[k] = now
    for i = #self.pending, 1, -1 do
        if key_of(self.pending[i].ev) == k then table.remove(self.pending, i) end -- we reached it ourselves
    end
    local t = self.sent[k]
    if t ~= nil and now - t < DEDUPE_WINDOW then
        self.sent[k] = now
        return false
    end
    self.sent[k] = now
    loc = loc or {}
    self.log("cutscene %s started here: sent to the partner", k)
    self.send(self.P.encode_cutscene({
        camera = ev.camera, id = ev.id, screen = ev.screen, owner_code = ev.owner_code,
        end_portrayal = ev.end_portrayal, start_flags = ev.start_flags, end_flags = ev.end_flags, coords = ev.coords,
        chapter = loc.chapter, stage = loc.stage, pos = loc.pos, flags = self.P.CUTSCENE_FLAGS.LOCAL_TRIGGER,
    }), true)
    self.counters.sent = self.counters.sent + 1
    return true
end

function CutsceneSync:on_cutscene(m, now)
    if not self:enabled() then return end
    self.counters.received = self.counters.received + 1
    local k = key_of(m)
    local seen = self.played[k]
    if seen ~= nil and now - seen < SEEN_WINDOW then
        self.log("cutscene %s from the partner: ours already played it %.0f s ago", k, now - seen)
        return -- both triggered it, or we already watched it
    end
    self.log("cutscene %s from the partner (chapter %s, stage %s)", k, tostring(m.chapter), tostring(m.stage))
    for _, p in ipairs(self.pending) do
        if key_of(p.ev) == k then return end
    end
    if #self.pending >= MAX_PENDING then
        self:drop(1, "too many cutscenes waiting")
    end
    self.pending[#self.pending + 1] = { ev = m, time = now, tries = 0, not_before = now + GRACE }
end

function CutsceneSync:drop(i, why)
    local p = table.remove(self.pending, i)
    if p ~= nil then
        self.log("cutscene %s not replayed: %s", key_of(p.ev), why)
        self.counters.dropped = self.counters.dropped + 1
    end
end

function CutsceneSync:end_replay(now)
    local r = self.replay
    if r == nil then return end
    if r.seen and now ~= nil then self.replayed[id_of(r.key)] = now end
    self.replay = nil
    self.on_replay(false, now)
end

-- loc = { chapter, stage, pos, loading, playable, transition }
function CutsceneSync:tick(now, world, loc, travel)
    -- Our game is between two moments of play: a cutscene that ends a chapter (the bell in the
    -- village ends chapter 1-1) goes on into the game's own chapter change, behind a black
    -- screen. Our copy of the partner's cutscene lasts until the game plays again (their
    -- flags keep waiting), nothing starts here and nobody travels.
    if loc ~= nil and loc.transition then
        if self.replay ~= nil then self.replay.transition = true end
        return
    end
    if next(self.skips) ~= nil and world.cutscene_skip ~= nil then self:apply_skips(now, world) end
    local playing = world:cutscene_playing()
    -- Our copy of the partner's cutscene: over once it played and stopped (or never began).
    local r = self.replay
    if r ~= nil then
        if playing then
            r.seen = true
        elseif r.seen or now - r.started > START_TIMEOUT then
            self:end_replay(now)
            -- We watched it from far away: now join the partner where it happened - unless
            -- it changed the chapter (both games start the next part at its own start point)
            -- or we are not playing yet.
            local j = r.join
            if j ~= nil and loc ~= nil and loc.chapter ~= nil and j.chapter ~= nil and j.chapter >= 0
                and loc.chapter ~= j.chapter then
                self.log("cutscene %s: not joining the partner, it changed the chapter (%s -> %s)", r.key,
                    tostring(j.chapter), tostring(loc.chapter))
                j = nil
            elseif j ~= nil and r.transition then
                self.log("cutscene %s: not joining the partner, our game went through a transition", r.key)
                j = nil
            end
            if j ~= nil and travel ~= nil and not travel:busy() then
                self.notify("Joining your partner where the cutscene took place", "info")
                travel:request(j)
            end
        end
    end

    local p = self.pending[1]
    if p == nil then return end
    if not self:enabled() then
        self.pending = {}
        return
    end
    local ev = p.ev
    local k = key_of(ev)
    if now - p.time > PENDING_TIMEOUT then
        return self:drop(1, "timed out")
    end
    local far = loc ~= nil and ev.stage ~= nil and ev.stage >= 0 and loc.stage ~= nil and loc.stage ~= ev.stage
    if loc ~= nil and not far and ev.pos ~= nil and loc.pos ~= nil and (ev.pos.x ~= 0 or ev.pos.y ~= 0 or ev.pos.z ~= 0) then
        far = dist(ev.pos, loc.pos) > FAR
    end
    -- Nearby, our own game may start the same cutscene by itself in a moment (the trigger that
    -- started it arrives too); far away it cannot, so the cutscene starts at once.
    if not far and now < p.not_before then return end
    if world:cutscene_done(ev.camera, ev.id) == true then
        -- Our game already played it (our own copy of the event started it, or this save saw it).
        self.played[k] = now
        table.remove(self.pending, 1)
        self.counters.already_seen = self.counters.already_seen + 1
        self.log("cutscene %s not replayed: this game has already played it", k)
        return
    end
    if playing then return end -- let the current one finish
    if loc == nil or loc.loading or not loc.playable then return end
    if ev.chapter ~= nil and ev.chapter >= 0 and loc.chapter ~= nil and loc.chapter >= 0 and loc.chapter ~= ev.chapter then
        return self:drop(1, "partner is in another chapter")
    end

    -- The cutscene starts here right away, wherever our player is: it plays the same in both
    -- games at the same time. A player who was far away joins the partner when it ends.
    local ok, why = world:cutscene_play(ev)
    if ok then
        self.log("cutscene %s replayed here%s", k, far and " (we were far away)" or "")
        self.played[k] = now
        self.counters.played = self.counters.played + 1
        table.remove(self.pending, 1)
        self:end_replay(now)
        self.replay = { key = k, started = now, seen = false }
        if far and self.settings.cutscene_travel ~= false then
            self.replay.join = { chapter = ev.chapter, stage = ev.stage, pos = ev.pos, reason = "cutscene" }
        end
        self.on_replay(true, now)
    else
        p.tries = p.tries + 1
        if p.tries >= MAX_TRIES then self:drop(1, "the game refused to play it (" .. tostring(why) .. ")") end
    end
end

-- Our player skipped a cutscene (adapter: its PlayWork's DoneSkip turned on).
function CutsceneSync:on_local_skip(ev, now)
    if not self:enabled() or ev == nil or ev.id == nil then return false end
    local k = key_of(ev)
    local t = self.skipped[k]
    if t ~= nil and now - t < SKIP_WINDOW then return false end -- the partner's skip we applied
    self.send(self.P.encode_cutscene_skip({ camera = ev.camera, id = ev.id }), true)
    self.counters.skips_sent = self.counters.skips_sent + 1
    self.log("cutscene %s: we skipped it (sent to the partner)", k)
    return true
end

function CutsceneSync:on_skip(m, now)
    if not self:enabled() or self.settings.sync_skips == false then return end
    self.counters.skips_received = self.counters.skips_received + 1
    self.skips[key_of(m)] = { ev = { camera = m.camera, id = m.id }, time = now }
    self.log("cutscene %s: the partner skipped it", key_of(m))
    for k, t in pairs(self.skipped) do
        if now - t > SKIP_WINDOW then self.skipped[k] = nil end
    end
end

-- A replay of that cutscene (by its number) is on its way here (waiting, or started and not
-- seen ending).
function CutsceneSync:replay_coming(k)
    local id = id_of(k)
    if self.replay ~= nil and id_of(self.replay.key) == id then return true end
    for _, p in ipairs(self.pending) do
        if tostring(p.ev.id) == id then return true end
    end
    return false
end

-- Partner skips: applied once that cutscene plays here and a player here could skip it
-- (world:cutscene_skip waits for that: docs/RESEARCH.md 3.36). Dropped when ours was skipped
-- already, or when it never comes.
function CutsceneSync:apply_skips(now, world)
    for k, s in pairs(self.skips) do
        if now - s.time > SKIP_WINDOW then
            self.skips[k] = nil
            self.log("cutscene %s: the partner's skip expired (never skippable here)", k)
        else
            local r, why = world:cutscene_skip(s.ev.camera, s.ev.id, now)
            if r == "skipped" then
                self.skips[k] = nil
                self.skipped[k] = now
                self.counters.skips_applied = self.counters.skips_applied + 1
                self.log("cutscene %s: the partner's skip applied here after %.1f s", k, now - s.time)
            elseif r == "done" or r == "failed" then
                self.skips[k] = nil
                self.log("cutscene %s: the partner's skip not applied (%s)", k, r == "done" and "skipped here already" or "failed")
            elseif r == "missing" and now - s.time > SKIP_MISSING and not self:replay_coming(k) then
                self.skips[k] = nil -- it played and ended here, or never comes
                self.log("cutscene %s: the partner's skip dropped (not playing here)", k)
            elseif r == "waiting" and why ~= s.why then
                s.why = why
                self.log("cutscene %s: the partner's skip waits (%s)", k, tostring(why))
            end
        end
    end
end

function CutsceneSync:on_message(m, now)
    if m.type == self.P.T.CUTSCENE then
        self:on_cutscene(m, now)
        return true
    elseif m.type == self.P.T.CUTSCENE_SKIP then
        self:on_skip(m, now)
        return true
    end
    return false
end

function CutsceneSync:summary()
    local p = self.pending[1]
    local skips = 0
    for _ in pairs(self.skips) do skips = skips + 1 end
    return { counters = self.counters, pending = p and key_of(p.ev) or nil, skips_waiting = skips > 0 and skips or nil,
        replaying = self.replay and self.replay.key or nil }
end

return CutsceneSync
