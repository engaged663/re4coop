-- Scenario flag synchronisation. RE4's story progress lives in chainsaw.ScenarioFlagManager:
-- thousands of GUID-addressed bits (objectives, map reveals, unlocked doors, one-time
-- events, collected items, animals killed, cutscenes watched...). Keeping these bits equal
-- on both machines is what makes the two games "the same world": level triggers, portrayals
-- (the game's scripted sequences), cutscenes and spawners all react to flags turning on, so a
-- flag one player's event sets makes the same things happen in the partner's game.
--
-- Two paths:
--   * Events: the adapter sees every flag change the game makes (the value-changed events of
--     GlobalUserDataManager, docs/RESEARCH.md 3.11) and reports flags that turned on, and
--     trigger-kind flags that fired. They are batched into FLAGS messages and applied on the
--     other side through the game's own setter, so everything that reacts to a flag reacts on
--     both machines.
--   * Words: the whole flag state, as 32-bit words per flag group. Used for the full copy a
--     joining client receives from the host, and as the live path when the event hooks are
--     not available (diffs of the words every few seconds: bits that turned on).
--
-- Flags only ever travel *on*. In normal play the game never clears a scenario flag; flags go
-- back off only when a game loads an older state (a checkpoint after a death), and that must
-- never undo the partner's world.
--
-- Flags that flip back and forth quickly (per-machine state) are muted for a while so the two
-- games do not fight over them. While the partner's cutscene plays here (cutscene_sync), the
-- partner's flags wait (hold/release): our copy of the cutscene sets its own start and end
-- flags at its own time, and what the partner's end flags start must not begin in our game
-- before our cutscene has ended.
--
-- Adapter contract (world):
--   world:flag_set(guid, value) -> bool        world:flag_check(guid) -> bool|nil
--   world:flag_pulse(guid) -> bool             (fires a trigger-kind flag)
--   world:flag_hooks_active() -> bool
--   world:flag_words_snapshot() -> { [group_name] = {u32, ...} } | nil
--   world:flag_words_apply(group_name, word_index0, set_mask, clear_mask) -> bool
--   world:flag_words_apply_full(groups) -> bool   (groups = { {name, words}, ... })

local FlagSync = {}
FlagSync.__index = FlagSync

local ECHO_WINDOW = 5.0        -- a local change equal to a remote one we applied this recently is an echo
local TOGGLE_WINDOW = 10.0
local TOGGLE_LIMIT = 6         -- more changes than this inside the window mutes the flag
local MUTE_TIME = 60.0
local FLUSH_INTERVAL = 0.05
local WORDS_INTERVAL = 5.0     -- reading the whole flag table is not free: only now and then
local FULL_TIMEOUT = 20.0
local HOLD_MAX = 600.0         -- a hold never outlives this (a cutscene that never ended for us)

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...) }
function FlagSync.new(opts)
    local self = setmetatable({}, FlagSync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self:reset()
    return self
end

function FlagSync:reset()
    self.pending = {}        -- ordered list of {guid, value, pulse}
    self.last_local = {}     -- guid -> last value seen locally (ours or applied from the partner)
    self.pending_index = {}  -- guid -> index in pending
    self.last_flush = -math.huge
    self.applying = false
    self.remote_applied = {} -- guid -> {value, time}
    self.toggles = {}        -- key -> {times...}
    self.muted = {}          -- key -> until
    self.baseline = nil      -- words: last local snapshot
    self.expect = {}         -- "group|word" -> {set=mask, clear=mask} changes we caused
    self.last_words = -math.huge
    self.full_parts = {}     -- sync_id -> {chunks=n, got={}, groups={}}
    self.hold_until = nil    -- partner flags wait until this time (or release())
    self.held = {}           -- ordered list of {guid, value, pulse} received while holding
    self.counters = { sent = 0, received = 0, applied = 0, muted = 0, words_sent = 0, words_applied = 0,
        full_applied = 0, pulses = 0, held = 0 }
end

function FlagSync:enabled()
    return self.settings.sync_flags ~= false
end

-- Records a change of `key`; returns false if the key is (now) muted.
function FlagSync:note_change(key, now)
    local until_t = self.muted[key]
    if until_t ~= nil then
        if now < until_t then return false end
        self.muted[key] = nil
    end
    local times = self.toggles[key]
    if times == nil then
        times = {}
        self.toggles[key] = times
    end
    times[#times + 1] = now
    while #times > 0 and now - times[1] > TOGGLE_WINDOW do
        table.remove(times, 1)
    end
    if #times > TOGGLE_LIMIT then
        self.muted[key] = now + MUTE_TIME
        self.toggles[key] = nil
        self.counters.muted = self.counters.muted + 1
        self.log("flag %s keeps changing; not syncing it for %ds", tostring(key), MUTE_TIME)
        return false
    end
    return true
end

function FlagSync:is_muted(key, now)
    local until_t = self.muted[key]
    return until_t ~= nil and now < until_t
end

-------------------------------------------------------------------------------
-- Holding the partner's flags (while their cutscene plays here)
-------------------------------------------------------------------------------

function FlagSync:hold(now, seconds)
    self.hold_until = now + math.min(seconds or HOLD_MAX, HOLD_MAX)
end

function FlagSync:holding(now)
    if self.hold_until == nil then return false end
    if now >= self.hold_until then
        self.hold_until = nil
        return false
    end
    return true
end

-- Applies everything that waited, in arrival order.
function FlagSync:release(now, world)
    self.hold_until = nil
    if #self.held == 0 then return end
    local held = self.held
    self.held = {}
    self:apply_flags(held, now, world)
end

-------------------------------------------------------------------------------
-- Event path (GUIDs)
-------------------------------------------------------------------------------

-- The local game turned a flag on (value = true) or off (false), or fired a trigger-kind flag
-- (pulse). Flags going off are local (a reload) and never sent, but the flag is news again the
-- next time it turns on.
function FlagSync:on_local_flag(guid, value, now, pulse)
    if not self:enabled() or self.applying then return false end
    guid = self.P.normalize_guid(guid)
    if guid == nil then return false end
    value = value and true or false
    if not value and not pulse then
        self.last_local[guid] = false
        return false
    end
    local rec = self.remote_applied[guid]
    if pulse then
        if rec ~= nil and now - rec.time < ECHO_WINDOW then return false end -- the partner's pulse we fired
    else
        -- Games often re-set a flag to the value it already has (every frame, every load):
        -- only real changes count.
        if self.last_local[guid] == true then return false end
        self.last_local[guid] = true
        if rec ~= nil and rec.value == true and now - rec.time < ECHO_WINDOW then
            return false -- our own application of the partner's change
        end
    end
    if not self:note_change(guid, now) then return false end
    local i = self.pending_index[guid]
    if i ~= nil then
        self.pending[i].value = true
        self.pending[i].pulse = self.pending[i].pulse or pulse or nil
    else
        self.pending[#self.pending + 1] = { guid = guid, value = true, pulse = pulse or nil }
        self.pending_index[guid] = #self.pending
    end
    return true
end

function FlagSync:flush(now)
    if #self.pending == 0 or now - self.last_flush < FLUSH_INTERVAL then return end
    self.last_flush = now
    for _, msg in ipairs(self.P.encode_flags(self.pending)) do
        self.send(msg, true)
    end
    self.counters.sent = self.counters.sent + #self.pending
    self.pending = {}
    self.pending_index = {}
end

-- Applies the partner's flags (list of {guid, value, pulse}). Clears are ignored: a partner
-- whose game went back to an older state must not take ours with it.
function FlagSync:apply_flags(list, now, world)
    for _, f in ipairs(list) do
        if f.guid ~= nil and (f.value or f.pulse) and self:note_change(f.guid, now) then
            if f.pulse then
                self.applying = true
                local ok = world:flag_pulse(f.guid)
                self.applying = false
                if ok then self.counters.pulses = self.counters.pulses + 1 end
                self.remote_applied[f.guid] = { value = true, time = now }
            else
                local cur = world:flag_check(f.guid)
                if cur ~= true then
                    self.applying = true
                    local ok = world:flag_set(f.guid, true)
                    self.applying = false
                    if ok then
                        self.counters.applied = self.counters.applied + 1
                    end
                end
                self.remote_applied[f.guid] = { value = true, time = now }
                self.last_local[f.guid] = true
            end
        end
    end
end

function FlagSync:on_flags(m, now, world)
    if not self:enabled() then return end
    self.counters.received = self.counters.received + #m.flags
    if self:holding(now) then
        for _, f in ipairs(m.flags) do self.held[#self.held + 1] = f end
        self.counters.held = self.counters.held + #m.flags
        return
    end
    if #self.held > 0 then self:release(now, world) end -- a hold that just ran out: in order
    self:apply_flags(m.flags, now, world)
end

-------------------------------------------------------------------------------
-- Words path (whole groups)
-------------------------------------------------------------------------------

local function word_key(group, word)
    return group .. "|" .. word
end

-- Remembers bit changes we are about to cause locally so the next diff ignores them.
function FlagSync:expect_change(group, word, set, clear)
    local k = word_key(group, word)
    local e = self.expect[k]
    if e == nil then
        e = { set = 0, clear = 0 }
        self.expect[k] = e
    end
    e.set = (e.set | set) & ~clear
    e.clear = (e.clear | clear) & ~set
end

-- Diffs the local words against the last snapshot; returns delta groups for FLAG_WORDS
-- (bits that turned on only).
function FlagSync:diff_words(snap, now)
    local base = self.baseline
    local out = {}
    for name, words in pairs(snap) do
        local old = base[name]
        if old ~= nil then
            local changes = {}
            for i = 1, #words do
                local o, n = old[i] or 0, words[i]
                if o ~= n then
                    local set = n & ~o
                    local k = word_key(name, i - 1)
                    local e = self.expect[k]
                    if e ~= nil then
                        set = set & ~e.set
                        self.expect[k] = nil
                    end
                    if set ~= 0 and self:note_change(k, now) then
                        changes[#changes + 1] = { word = i - 1, set = set, clear = 0 }
                    end
                end
            end
            if #changes > 0 then
                out[#out + 1] = { name = name, changes = changes }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function FlagSync:words_tick(now, world)
    if now - self.last_words < (self.settings.flag_words_interval or WORDS_INTERVAL) then return end
    self.last_words = now
    if world:flag_hooks_active() then
        -- With working hooks the event path carries every change: no need to read the table.
        self.baseline = nil
        self.expect = {}
        return
    end
    local snap = world:flag_words_snapshot()
    if snap == nil then return end
    if self.baseline == nil then
        self.baseline = snap
        return
    end
    local delta = self:diff_words(snap, now)
    self.baseline = snap
    if #delta > 0 then
        for _, msg in ipairs(self.P.encode_flag_words(0, self.P.FLAG_WORDS_MODE.DELTA, delta)) do
            self.send(msg, true)
        end
        self.counters.words_sent = self.counters.words_sent + #delta
    end
end

-- Host: the complete flag state, for a joining client.
function FlagSync:send_full(sync_id, world)
    local snap = world:flag_words_snapshot()
    if snap == nil then return 0 end
    local groups = {}
    for name, words in pairs(snap) do
        groups[#groups + 1] = { name = name, words = words }
    end
    table.sort(groups, function(a, b) return a.name < b.name end)
    for _, msg in ipairs(self.P.encode_flag_words(sync_id, self.P.FLAG_WORDS_MODE.FULL, groups)) do
        self.send(msg, true)
    end
    return #groups
end

function FlagSync:apply_full(groups, world)
    local snap = world:flag_words_snapshot() or {}
    for _, g in ipairs(groups) do
        local cur = snap[g.name]
        if cur ~= nil then
            for i, w in ipairs(g.words) do
                local o = cur[i] or 0
                if o ~= w then
                    self:expect_change(g.name, i - 1, w & ~o, o & ~w)
                end
            end
        end
    end
    self.applying = true
    local ok = world:flag_words_apply_full(groups)
    self.applying = false
    if ok then
        self.counters.full_applied = self.counters.full_applied + 1
    end
    return ok
end

function FlagSync:on_flag_words(m, now, world)
    if not self:enabled() then return end
    if m.mode == self.P.FLAG_WORDS_MODE.FULL then
        local part = self.full_parts[m.sync_id]
        if part == nil or part.chunks ~= m.chunks then
            part = { chunks = m.chunks, got = {}, n = 0, groups = {}, time = now }
            self.full_parts[m.sync_id] = part
        end
        if not part.got[m.chunk] then
            part.got[m.chunk] = m.groups
            part.n = part.n + 1
        end
        for id, p in pairs(self.full_parts) do
            if now - p.time > FULL_TIMEOUT then self.full_parts[id] = nil end
        end
        if part.n < part.chunks then return end
        self.full_parts[m.sync_id] = nil
        -- Reassemble groups that were split across chunks.
        local by_name, order = {}, {}
        for c = 1, part.chunks do
            for _, g in ipairs(part.got[c] or {}) do
                local acc = by_name[g.name]
                if acc == nil then
                    acc = { name = g.name, words = {} }
                    by_name[g.name] = acc
                    order[#order + 1] = acc
                end
                for k, w in ipairs(g.words) do
                    acc.words[g.first + k] = w
                end
            end
        end
        self:apply_full(order, world)
        return
    end
    for _, g in ipairs(m.groups) do
        for _, c in ipairs(g.changes) do
            local k = word_key(g.name, c.word)
            if c.set ~= 0 and self:note_change(k, now) then
                self:expect_change(g.name, c.word, c.set, 0)
                self.applying = true
                local ok = world:flag_words_apply(g.name, c.word, c.set, 0)
                self.applying = false
                if ok then
                    self.counters.words_applied = self.counters.words_applied + 1
                end
            end
        end
    end
end

-------------------------------------------------------------------------------

function FlagSync:tick(now, world)
    if not self:enabled() then
        self.pending, self.pending_index = {}, {}
        return
    end
    self:flush(now)
    self:words_tick(now, world)
    if #self.held > 0 and not self:holding(now) then self:release(now, world) end
    for guid, rec in pairs(self.remote_applied) do
        if now - rec.time > ECHO_WINDOW then self.remote_applied[guid] = nil end
    end
end

function FlagSync:on_message(m, now, world)
    local T = self.P.T
    if m.type == T.FLAGS then
        self:on_flags(m, now, world)
        return true
    elseif m.type == T.FLAG_WORDS then
        self:on_flag_words(m, now, world)
        return true
    end
    return false
end

function FlagSync:summary()
    local muted = 0
    for _ in pairs(self.muted) do muted = muted + 1 end
    return { counters = self.counters, muted_now = muted, holding = self.hold_until ~= nil and #self.held or nil }
end

return FlagSync
