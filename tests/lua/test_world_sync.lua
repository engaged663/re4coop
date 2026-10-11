-- Flag, gimmick, object and cutscene synchronisation between two simulated games (host and
-- client), every message going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local FlagSync = require("re4coop.flag_sync")
local GimmickSync = require("re4coop.gimmick_sync")
local ObjectSync = require("re4coop.object_sync")
local CutsceneSync = require("re4coop.cutscene_sync")

local function guid(i)
    return ("%08x-1111-2222-3333-%012x"):format(i, i)
end

-- A fake game world implementing the world adapter contracts.
local function make_world(name)
    local w = { name = name, flags = {}, set_calls = 0, hooks_active = true, groups = { Main = { 0, 0, 0 }, Side = { 0 } },
        gimmicks = {}, objects = {}, stage = 100, playing = nil, played = {}, applied_objects = {} }

    -- Flags by GUID. The setter "fires the game's hook", like requestSetFlag would.
    function w:flag_set(g, v)
        self.set_calls = self.set_calls + 1
        self.flags[g] = v
        if self.on_flag then self.on_flag(g, v) end
        return true
    end
    function w:flag_check(g) return self.flags[g] or false end
    function w:flag_hooks_active() return self.hooks_active end
    function w:game_sets_flag(g, v) -- the game itself
        self.flags[g] = v
        if self.on_flag then self.on_flag(g, v) end
    end

    -- Flag words.
    function w:flag_words_snapshot()
        local out = {}
        for n, words in pairs(self.groups) do
            out[n] = { table.unpack(words) }
        end
        return out
    end
    function w:flag_words_apply(group, word, set, clear)
        local g = self.groups[group]
        if g == nil or g[word + 1] == nil then return false end
        g[word + 1] = (g[word + 1] | set) & ~clear
        return true
    end
    function w:flag_words_apply_full(groups)
        for _, g in ipairs(groups) do
            local mine = self.groups[g.name]
            if mine then
                for i, v in pairs(g.words) do mine[i] = v end
            end
        end
        self.full_applied = (self.full_applied or 0) + 1
        return true
    end

    -- Gimmicks.
    function w:set_gimmick(i, attr, done)
        local ctx = { category = 1, kind = 0, group = i, index = 0 }
        self.gimmicks[P.ctx_key(ctx)] = { ctx = ctx, attr = attr, triggers = { { id = i, done = done or 0 } },
            detected = false, acc = {} }
    end
    function w:gimmicks_snapshot()
        local out = {}
        for k, g in pairs(self.gimmicks) do
            out[k] = { ctx = g.ctx, attr = g.attr, triggers = { table.unpack(g.triggers) }, detected = g.detected,
                acc = { table.unpack(g.acc) } }
        end
        return out
    end
    function w:gimmicks_apply(items)
        self.gimmick_applies = (self.gimmick_applies or 0) + 1
        for _, it in ipairs(items) do
            self.gimmicks[P.ctx_key(it.ctx)] = { ctx = it.ctx, attr = it.attr, triggers = it.triggers,
                detected = it.detected, acc = it.acc }
        end
        return true
    end

    -- Objects.
    function w:add_object(g, kind, pos, routine)
        self.objects[g] = { kind = kind, pos = pos, routine = routine or 0, terminal = false }
    end
    function w:objects_scan()
        local out = {}
        for g, o in pairs(self.objects) do
            out[g] = { kind = o.kind, pos = o.pos, routine = o.routine, terminal = o.terminal }
        end
        return { stage = self.stage, objects = out }
    end
    function w:object_apply(g, event, value)
        local o = self.objects[g]
        if o == nil then return "missing" end
        self.applied_objects[#self.applied_objects + 1] = { guid = g, event = event, value = value }
        if event == P.OBJECT_EVENT.DESTROYED then
            if value >= 0 then
                o.routine = value
                o.terminal = true
            else
                self.objects[g] = nil
            end
        end
        return "done"
    end

    -- Cutscenes.
    function w:cutscene_playing() return self.playing end
    function w:cutscene_play(id, method)
        self.played[#self.played + 1] = { id = id, method = method }
        self.playing = id
        if self.on_cutscene then self.on_cutscene(id, method) end -- the hook fires on our own call
        return true
    end

    return w
end

local function make_pair(Class, settings)
    settings = settings or {}
    local pair = { now = 0, host_world = make_world("host"), client_world = make_world("client"), to_host = {},
        to_client = {}, sent = { host = 0, client = 0 } }
    pair.host = Class.new({ role = "host", protocol = P, settings = settings,
        send = function(b) table.insert(pair.to_client, b) pair.sent.host = pair.sent.host + 1 end })
    pair.client = Class.new({ role = "client", protocol = P, settings = settings,
        send = function(b) table.insert(pair.to_host, b) pair.sent.client = pair.sent.client + 1 end })
    function pair:deliver()
        local tc, th = self.to_client, self.to_host
        self.to_client, self.to_host = {}, {}
        for _, b in ipairs(tc) do self.client:on_message(assert(P.decode(b)), self.now, self.client_world) end
        for _, b in ipairs(th) do self.host:on_message(assert(P.decode(b)), self.now, self.host_world) end
    end
    function pair:step(n, tick)
        for _ = 1, n or 1 do
            self.now = self.now + 0.05
            if tick then tick(self) end
            self:deliver()
        end
    end
    return pair
end

-------------------------------------------------------------------------------
-- Flags
-------------------------------------------------------------------------------

local function flag_pair(settings)
    local pair = make_pair(FlagSync, settings)
    pair.host_world.on_flag = function(g, v) pair.host:on_local_flag(g, v, pair.now) end
    pair.client_world.on_flag = function(g, v) pair.client:on_local_flag(g, v, pair.now) end
    pair.tick = function(p)
        p.host:tick(p.now, p.host_world)
        p.client:tick(p.now, p.client_world)
    end
    return pair
end

T.run("flags_replicate_both_ways_without_echo", function()
    local pair = flag_pair()
    pair.host_world:game_sets_flag(guid(1), true)    -- host opens a door / picks up a key...
    pair.client_world:game_sets_flag(guid(2), true)  -- ...client kills a crow
    pair:step(5, pair.tick)
    T.eq(pair.client_world.flags[guid(1)], true, "client got the host's flag")
    T.eq(pair.host_world.flags[guid(2)], true, "host got the client's flag")
    T.eq(pair.host.counters.sent, 1, "host sent one flag")
    T.eq(pair.client.counters.sent, 1, "client sent one flag (no echo of the host's)")
    pair:step(20, pair.tick)
    T.eq(pair.host.counters.sent + pair.client.counters.sent, 2, "nothing bounces back later")
end)

T.run("flags_clear_and_repeated_sets", function()
    local pair = flag_pair()
    pair.host_world:game_sets_flag(guid(3), true)
    pair:step(3, pair.tick)
    pair.host_world:game_sets_flag(guid(3), false)
    pair:step(3, pair.tick)
    T.eq(pair.client_world.flags[guid(3)], false, "clear replicated")
    local applied = pair.client.counters.applied
    pair.host_world:flag_set(guid(9), true)
    pair.client_world.flags[guid(9)] = true -- partner already has it
    pair:step(3, pair.tick)
    T.eq(pair.client.counters.applied, applied, "no redundant set when equal")
end)

T.run("repeated_sets_of_the_same_value_are_not_resent", function()
    local pair = flag_pair()
    for _ = 1, 30 do
        pair.host_world:game_sets_flag(guid(7), true) -- the game re-sets it every frame
        pair:step(1, pair.tick)
    end
    T.eq(pair.host.counters.sent, 1, "sent once")
    T.eq(pair.host.counters.muted, 0, "not mistaken for flapping")
end)

T.run("oscillating_flags_are_muted", function()
    local pair = flag_pair()
    for i = 1, 12 do
        pair.host_world:game_sets_flag(guid(5), i % 2 == 0)
        pair:step(2, pair.tick)
    end
    T.check(pair.host.counters.muted >= 1, "flag muted after flapping")
    local sent = pair.host.counters.sent
    pair.host_world:game_sets_flag(guid(5), true)
    pair:step(2, pair.tick)
    T.eq(pair.host.counters.sent, sent, "muted flag not sent")
    pair.now = pair.now + 61
    pair.host_world:game_sets_flag(guid(5), false)
    pair:step(2, pair.tick)
    T.eq(pair.host.counters.sent, sent + 1, "unmuted after the mute time")
end)

T.run("full_flag_copy_for_a_joining_client", function()
    local pair = flag_pair()
    local big = {}
    for i = 1, 900 do big[i] = i * 7 end
    pair.host_world.groups = { Main = big, Side = { 0xDEADBEEF } }
    local cmain = {}
    for i = 1, 900 do cmain[i] = 0 end
    pair.client_world.groups = { Main = cmain, Side = { 1 } }
    local n = pair.host:send_full(42, pair.host_world)
    T.eq(n, 2, "two groups")
    pair:deliver()
    T.eq(pair.client_world.full_applied, 1, "applied once, after the last chunk")
    T.eq(pair.client_world.groups.Main[900], 900 * 7, "last word")
    T.eq(pair.client_world.groups.Side[1], 0xDEADBEEF, "side group")
    -- The client's word diff must not send the host's state back (expectations).
    pair.client_world.hooks_active = false
    pair.client.baseline = { Main = cmain, Side = { 1 } }
    pair:step(50, pair.tick)
    T.eq(pair.client.counters.words_sent, 0, "no delta echo after a full copy")
end)

T.run("word_deltas_when_setter_hooks_are_missing", function()
    local pair = flag_pair({ flag_words_interval = 0.1 })
    pair.host_world.hooks_active = false
    pair.client_world.hooks_active = false
    pair:step(5, pair.tick) -- baselines
    pair.host_world.groups.Main[2] = 0x5      -- set bits 0 and 2 of word 1
    pair.client_world.groups.Side[1] = 0x100  -- client side change
    pair:step(10, pair.tick)
    T.eq(pair.client_world.groups.Main[2], 0x5, "set bits arrived")
    T.eq(pair.host_world.groups.Side[1], 0x100, "client's bits arrived")
    local sent = pair.host.counters.words_sent + pair.client.counters.words_sent
    pair:step(20, pair.tick)
    T.eq(pair.host.counters.words_sent + pair.client.counters.words_sent, sent, "no echo")
    pair.host_world.groups.Main[2] = 0x4 -- clear bit 0
    pair:step(10, pair.tick)
    T.eq(pair.client_world.groups.Main[2], 0x4, "cleared bit arrived")
end)

-------------------------------------------------------------------------------
-- Gimmicks
-------------------------------------------------------------------------------

local function gimmick_pair()
    local pair = make_pair(GimmickSync, { gimmick_interval = 0.1 })
    pair.deliver = function(self)
        local tc, th = self.to_client, self.to_host
        self.to_client, self.to_host = {}, {}
        for _, b in ipairs(tc) do self.client:on_message(assert(P.decode(b)), self.now) end
        for _, b in ipairs(th) do self.host:on_message(assert(P.decode(b)), self.now) end
    end
    pair.tick = function(p)
        p.host:tick(p.now, p.host_world)
        p.client:tick(p.now, p.client_world)
    end
    for i = 1, 3 do
        pair.host_world:set_gimmick(i, "\0\0")
        pair.client_world:set_gimmick(i, "\0\0")
    end
    pair:step(5, pair.tick)
    return pair
end

T.run("gimmick_changes_replicate_and_host_referees", function()
    local pair = gimmick_pair()
    pair.host_world:set_gimmick(1, "\1\0", 1)    -- host unlocks a door with a key
    pair:step(30, pair.tick)
    local k1 = P.ctx_key({ category = 1, kind = 0, group = 1, index = 0 })
    T.eq(pair.client_world.gimmicks[k1].attr, "\1\0", "client door unlocked")
    T.eq(pair.client_world.gimmicks[k1].triggers[1].done, 1, "trigger marked done")
    T.eq(pair.client.counters.sent, 0, "client did not echo")
    pair.client_world:set_gimmick(2, "\0\4")     -- client pulls a lever
    pair:step(30, pair.tick)
    local k2 = P.ctx_key({ category = 1, kind = 0, group = 2, index = 0 })
    T.eq(pair.host_world.gimmicks[k2].attr, "\0\4", "host applied the client's change")
    local sent = pair.host.counters.sent + pair.client.counters.sent
    pair:step(40, pair.tick)
    T.eq(pair.host.counters.sent + pair.client.counters.sent, sent, "settled: no endless re-broadcast")
end)

T.run("gimmick_change_announced_by_the_game_is_sent_at_once", function()
    local pair = gimmick_pair()
    pair.host.settings.gimmick_interval = 10 -- periodic scans are rare here
    pair:step(5, pair.tick)                  -- both have read their tables once
    local scans = pair.host.counters.scans
    local dirty = false
    function pair.host_world:gimmicks_dirty()
        local d = dirty
        dirty = false
        return d
    end
    pair.host_world:set_gimmick(5, "\5\0", 1) -- the host opens a door...
    dirty = true                                  -- ...and the game calls GimmickManager.pushDirtyList
    pair:step(16, pair.tick)                      -- 0.8 s: long before the next periodic scan
    local k5 = P.ctx_key({ category = 1, kind = 0, group = 5, index = 0 })
    T.check(pair.client_world.gimmicks[k5] ~= nil and pair.client_world.gimmicks[k5].attr == "\5\0",
        "client's door opened within a second")
    T.eq(pair.host.counters.scans, scans + 1, "one extra scan, triggered by the announcement")
end)

T.run("new_gimmick_records_never_overwrite_the_partners", function()
    local pair = gimmick_pair()
    pair:step(5, pair.tick)
    local dirty = false
    function pair.client_world:gimmicks_dirty()
        local d = dirty
        dirty = false
        return d
    end
    -- The host opened door 7 long ago; the client has never loaded it.
    pair.host_world:set_gimmick(7, "\1\1", 1)
    pair:step(20, pair.tick)
    local k7 = P.ctx_key({ category = 1, kind = 0, group = 7, index = 0 })
    T.eq(pair.client_world.gimmicks[k7] and pair.client_world.gimmicks[k7].attr, "\1\1", "client has the open door")
    -- Now the client's area loads it with its initial state and the game announces it.
    pair.client_world.gimmicks[k7] = nil
    pair:step(5, pair.tick)
    pair.client_world:set_gimmick(7, "\0\0", 0)
    dirty = true
    pair:step(20, pair.tick)
    T.eq(pair.host_world.gimmicks[k7].attr, "\1\1", "the host's open door is not closed by a new record")
    T.eq(pair.client_world.gimmicks[k7].attr, "\1\1", "and the client gets the host's state back")
    -- A whole area loading (many new records at once) is not sent at all.
    local sent = pair.client.counters.sent
    for i = 100, 140 do pair.client_world:set_gimmick(i, "\0", 0) end
    dirty = true
    pair:step(20, pair.tick)
    T.eq(pair.client.counters.sent, sent, "area load not broadcast")
    -- A gimmick whose record appears with its first change reaches a partner without one.
    pair.client_world:set_gimmick(200, "\9", 1)
    dirty = true
    pair:step(20, pair.tick)
    local k200 = P.ctx_key({ category = 1, kind = 0, group = 200, index = 0 })
    T.eq(pair.host_world.gimmicks[k200] and pair.host_world.gimmicks[k200].attr, "\9", "new record added on the host")
end)

T.run("gimmick_conflict_converges_to_the_host", function()
    local pair = gimmick_pair()
    pair.host_world:set_gimmick(3, "\7\0")
    pair.client_world:set_gimmick(3, "\9\0")
    pair:step(40, pair.tick)
    local k3 = P.ctx_key({ category = 1, kind = 0, group = 3, index = 0 })
    T.eq(pair.host_world.gimmicks[k3].attr, pair.client_world.gimmicks[k3].attr, "both agree")
end)

T.run("gimmick_full_table_for_a_joining_client", function()
    local pair = gimmick_pair()
    for i = 10, 200 do pair.host_world:set_gimmick(i, string.rep("\3", 16), 1) end
    pair:step(5, pair.tick)
    pair.to_client = {}
    T.eq(pair.host:send_full(5, pair.host_world), 194, "all items")
    pair:step(20, pair.tick)
    local k = P.ctx_key({ category = 1, kind = 0, group = 150, index = 0 })
    T.check(pair.client_world.gimmicks[k] ~= nil and pair.client_world.gimmicks[k].attr == string.rep("\3", 16),
        "client has the host's whole table")
end)

-------------------------------------------------------------------------------
-- Objects
-------------------------------------------------------------------------------

local function object_pair()
    local pair = make_pair(ObjectSync)
    pair.host_pos = { x = 0, y = 0, z = 0 }
    pair.client_pos = { x = 0, y = 0, z = 0 }
    pair.tick = function(p)
        p.host:tick(p.now, p.host_world, p.host_pos)
        p.client:tick(p.now, p.client_world, p.client_pos)
    end
    for _, w in ipairs({ pair.host_world, pair.client_world }) do
        w:add_object(guid(100), "chainsaw.GmWoodBox", { x = 2, y = 0, z = 0 })
        w:add_object(guid(101), "chainsaw.GmCrow", { x = 5, y = 0, z = 0 })
        w:add_object(guid(102), "chainsaw.GmBottle", { x = 3, y = 0, z = 1 })
    end
    pair:step(12, pair.tick)
    return pair
end

T.run("broken_crate_and_killed_crow_replicate", function()
    local pair = object_pair()
    pair.host_world.objects[guid(100)].routine = 2      -- crate breaks
    pair.host_world.objects[guid(100)].terminal = true
    pair.client_world.objects[guid(101)].routine = 2    -- client shoots the crow
    pair.client_world.objects[guid(101)].terminal = true
    pair:step(12, pair.tick)
    T.eq(pair.client_world.objects[guid(100)].terminal, true, "client crate broke")
    T.eq(pair.host_world.objects[guid(101)].terminal, true, "host crow died")
    T.eq(pair.host.counters.sent + pair.client.counters.sent, 2, "one event each, no echo")
    pair.host_world.objects[guid(102)] = nil             -- bottle shattered and removed
    pair:step(12, pair.tick)
    T.check(pair.client_world.objects[guid(102)] == nil, "vanished bottle removed on the client")
end)

T.run("area_unload_is_not_destruction", function()
    local pair = object_pair()
    for i = 1, 8 do pair.host_world:add_object(guid(200 + i), "chainsaw.GmWoodBox", { x = i, y = 0, z = 0 }) end
    pair:step(12, pair.tick)
    pair.host_world.objects = {} -- the whole area unloads
    pair:step(12, pair.tick)
    T.eq(pair.host.counters.sent, 0, "nothing reported")
    local far = object_pair()
    far.host_world.objects[guid(101)].pos = { x = 500, y = 0, z = 0 }
    far:step(12, far.tick)
    far.host_world.objects[guid(101)] = nil -- far away: streamed out, not killed
    far:step(12, far.tick)
    T.eq(far.host.counters.sent, 0, "far vanish ignored")
end)

T.run("events_wait_for_objects_that_are_not_loaded", function()
    local pair = object_pair()
    pair.host_world:add_object(guid(300), "chainsaw.GmWoodBox", { x = 1, y = 0, z = 1 })
    pair:step(12, pair.tick)
    pair.host_world.objects[guid(300)].routine = 2
    pair.host_world.objects[guid(300)].terminal = true
    pair:step(12, pair.tick)
    T.check(pair.client.pending[guid(300)] ~= nil, "client keeps it for later")
    pair.client_world:add_object(guid(300), "chainsaw.GmWoodBox", { x = 1, y = 0, z = 1 }) -- client arrives
    pair:step(12, pair.tick)
    T.eq(pair.client_world.objects[guid(300)].terminal, true, "applied on arrival")
    T.eq(pair.client.counters.sent, 0, "and not reported back")
end)

T.run("history_for_a_joining_client", function()
    local pair = object_pair()
    pair.host_world.objects[guid(100)].routine = 2
    pair.host_world.objects[guid(100)].terminal = true
    pair:step(12, pair.tick)
    local late = make_world("late")
    late:add_object(guid(100), "chainsaw.GmWoodBox", { x = 2, y = 0, z = 0 })
    local sync = ObjectSync.new({ role = "client", protocol = P, settings = {}, send = function() end })
    pair.to_client = {}
    T.eq(pair.host:send_history(), 1, "one destroyed object")
    for _, b in ipairs(pair.to_client) do sync:on_message(assert(P.decode(b)), pair.now, late) end
    T.eq(late.objects[guid(100)].terminal, true, "late joiner's crate already broken")
end)

-------------------------------------------------------------------------------
-- Cutscenes
-------------------------------------------------------------------------------

local function cutscene_pair()
    local pair = make_pair(CutsceneSync)
    pair.host_loc = { chapter = 21100, stage = 100, pos = { x = 0, y = 0, z = 0 }, playable = true }
    pair.client_loc = { chapter = 21100, stage = 100, pos = { x = 3, y = 0, z = 0 }, playable = true }
    pair.travel = { requests = {}, busy_flag = false }
    function pair.travel:request(t) self.requests[#self.requests + 1] = t self.busy_flag = true return true end
    function pair.travel:busy() return self.busy_flag end
    pair.deliver = function(self)
        local tc, th = self.to_client, self.to_host
        self.to_client, self.to_host = {}, {}
        for _, b in ipairs(tc) do self.client:on_message(assert(P.decode(b)), self.now) end
        for _, b in ipairs(th) do self.host:on_message(assert(P.decode(b)), self.now) end
    end
    pair.host_world.on_cutscene = function(id, m) pair.host:on_local_start(id, m, pair.now, pair.host_loc) end
    pair.client_world.on_cutscene = function(id, m) pair.client:on_local_start(id, m, pair.now, pair.client_loc) end
    pair.tick = function(p)
        p.host:tick(p.now, p.host_world, p.host_loc, p.travel)
        p.client:tick(p.now, p.client_world, p.client_loc, p.travel)
    end
    return pair
end

T.run("cutscene_plays_for_both_once", function()
    local pair = cutscene_pair()
    pair.host_world:cutscene_play(10157, "requestPlay") -- host walks into the trigger
    pair:step(5, pair.tick)
    T.eq(#pair.client_world.played, 1, "client plays it")
    T.eq(pair.client_world.played[1].id, 10157, "same cutscene")
    T.eq(pair.client_world.played[1].method, "requestPlay", "same method")
    T.eq(pair.host.counters.sent, 1, "host announced once")
    T.eq(pair.client.counters.sent, 0, "client's replay is not announced back")
    T.eq(#pair.host_world.played, 1, "host not asked to replay its own cutscene")
end)

T.run("cutscene_triggered_by_both_is_one_cutscene", function()
    local pair = cutscene_pair()
    pair.host_world:cutscene_play(20130, "requestPlay")
    pair.client_world:cutscene_play(20130, "requestPlay")
    pair:step(10, pair.tick)
    T.eq(#pair.host_world.played, 1, "host played it once")
    T.eq(#pair.client_world.played, 1, "client played it once")
end)

T.run("partner_far_away_travels_first", function()
    local pair = cutscene_pair()
    pair.client_loc.stage = 200
    pair.host_world:cutscene_play(20130, "requestPlay")
    pair:step(3, pair.tick)
    T.eq(#pair.travel.requests, 1, "client asked to travel")
    T.eq(pair.travel.requests[1].stage, 100, "to the host's stage")
    T.eq(#pair.client_world.played, 0, "not played while travelling")
    pair.travel.busy_flag = false
    pair.client_loc.stage = 100
    pair:step(3, pair.tick)
    T.eq(#pair.client_world.played, 1, "played after arriving")
end)

T.run("cutscene_in_another_chapter_is_dropped", function()
    local pair = cutscene_pair()
    pair.client_loc.chapter = 22200
    pair.host_world:cutscene_play(30000, "requestPlay")
    pair:step(5, pair.tick)
    T.eq(#pair.client_world.played, 0, "not replayed")
    T.eq(pair.client.counters.dropped, 1, "dropped with a reason")
end)

T.finish()
