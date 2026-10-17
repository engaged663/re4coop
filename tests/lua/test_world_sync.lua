-- Flag, gimmick, object, cutscene and event trigger synchronisation between two simulated
-- games (host and client), every message going through the real protocol encoder/decoder.
local T = require("testlib")
local P = require("re4coop.protocol")
local FlagSync = require("re4coop.flag_sync")
local GimmickSync = require("re4coop.gimmick_sync")
local ObjectSync = require("re4coop.object_sync")
local CutsceneSync = require("re4coop.cutscene_sync")
local TriggerSync = require("re4coop.trigger_sync")
local DoorSync = require("re4coop.door_sync")

local function guid(i)
    return ("%08x-1111-2222-3333-%012x"):format(i, i)
end

-- A fake game world implementing the world adapter contracts.
local function make_world(name)
    local w = { name = name, flags = {}, set_calls = 0, hooks_active = true, groups = { Main = { 0, 0, 0 }, Side = { 0 } },
        gimmicks = {}, objects = {}, stage = 100, playing = nil, played = {}, done = {}, own = {}, applied_objects = {},
        pulses = {}, triggers = {}, trigger_log = {} }

    -- Flags by GUID. Like the game's setters, a set runs the change event (and so the hook);
    -- only flags turning on (or pulsing) are reported, as the adapter does.
    function w:flag_set(g, v)
        self.set_calls = self.set_calls + 1
        local was = self.flags[g]
        self.flags[g] = v
        if self.on_flag and v and not was then self.on_flag(g, true) end
        return true
    end
    function w:flag_pulse(g)
        self.pulses[#self.pulses + 1] = g
        if self.on_flag then self.on_flag(g, true, true) end
        return true
    end
    function w:flag_check(g) return self.flags[g] or false end
    function w:flag_hooks_active() return self.hooks_active end
    function w:game_sets_flag(g, v) -- the game itself
        local was = self.flags[g]
        self.flags[g] = v
        if self.on_flag and (v or was) then self.on_flag(g, v) end
    end
    function w:game_pulses_flag(g)
        if self.on_flag then self.on_flag(g, true, true) end
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
        g[word + 1] = g[word + 1] | set -- like the adapter: bits turning on only
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
    function w:gimmicks_snapshot(_, keys)
        local out = {}
        self.snapshots = (self.snapshots or 0) + 1
        for k, g in pairs(self.gimmicks) do
            if keys == nil or keys[k] then out[k] = {
                ctx = g.ctx, attr = g.attr, triggers = { table.unpack(g.triggers) }, detected = g.detected,
                acc = { table.unpack(g.acc) } } end
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

    -- Cutscenes: the game plays a "play once" cutscene through its PayloadPlay; our replays
    -- of the partner's payloads are not reported (the adapter's hook knows its own calls).
    local function key(ev) return (ev.camera or 1) .. ":" .. ev.id end
    function w:cutscene_playing() return self.playing end
    function w:cutscene_done(camera, id) return self.done[(camera or 1) .. ":" .. id] == true end
    function w:cutscene_play(ev)
        if self.refuse_cutscenes then return false, "refused" end
        self.played[#self.played + 1] = ev
        self.playing, self.playing_key = true, key(ev)
        self.done[key(ev)] = true
        return true
    end
    function w:game_plays_cutscene(ev) -- the game itself (a trigger, a gimmick...)
        if self.done[key(ev)] then return false end
        self.own[#self.own + 1] = ev
        self.playing, self.playing_key = true, key(ev)
        self.done[key(ev)] = true
        if self.on_cutscene then self.on_cutscene(ev) end
        return true
    end
    -- Skips: the game skips the playing camera (InputSkip) unless it cannot be skipped.
    function w:cutscene_skip(camera, id)
        if not self.playing or self.playing_key ~= (camera or 1) .. ":" .. id then return "missing" end
        self.skips = self.skips or {}
        self.skips[#self.skips + 1] = self.playing_key
        self.playing, self.playing_key = nil, nil
        return "skipped"
    end
    function w:player_skips() -- our player skips the playing cutscene
        local k = self.playing_key
        self.playing, self.playing_key = nil, nil
        local camera, id = k:match("^(%d+):(%d+)$")
        if self.on_skip then self.on_skip({ camera = tonumber(camera), id = tonumber(id) }) end
    end

    -- Level triggers: { [guid..":"..hash] = { once, done, runs, not_event } } loaded here.
    function w:add_trigger(g, hash, once, not_event)
        self.triggers[g .. ":" .. hash] = { once = once ~= false, done = false, runs = 0, not_event = not_event }
    end
    function w:trigger_run(ev)
        local t = self.triggers[ev.guid .. ":" .. ev.hash]
        if t == nil then return "missing" end
        if t.once and t.done then return "done" end
        if t.not_event then return "refused" end
        t.done = t.once
        t.runs = t.runs + 1
        self.trigger_log[#self.trigger_log + 1] = "run " .. ev.guid
        return "run"
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
    pair.host_world.on_flag = function(g, v, pulse) pair.host:on_local_flag(g, v, pair.now, pulse) end
    pair.client_world.on_flag = function(g, v, pulse) pair.client:on_local_flag(g, v, pair.now, pulse) end
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

T.run("flags_only_ever_travel_on", function()
    local pair = flag_pair()
    pair.host_world:game_sets_flag(guid(3), true)
    pair:step(3, pair.tick)
    T.eq(pair.client_world.flags[guid(3)], true, "on replicated")
    -- The host's game goes back to a checkpoint: its flags go off. The client's stay.
    pair.host_world:game_sets_flag(guid(3), false)
    pair:step(3, pair.tick)
    T.eq(pair.client_world.flags[guid(3)], true, "a reload never undoes the partner's world")
    -- ...and when the host's game sets it again, it is news again (but already set here).
    local applied = pair.client.counters.applied
    pair.host_world:game_sets_flag(guid(3), true)
    pair:step(3, pair.tick)
    T.eq(pair.host.counters.sent, 2, "sent again after it went off and on")
    T.eq(pair.client.counters.applied, applied, "no redundant set when equal")
end)

T.run("pulsed_flags_fire_in_the_partners_game", function()
    local pair = flag_pair()
    pair.host_world:game_pulses_flag(guid(4)) -- a trigger-kind flag fires
    pair:step(3, pair.tick)
    T.eq(pair.client_world.pulses[1], guid(4), "fired there")
    T.eq(pair.client.counters.pulses, 1, "counted")
    T.eq(pair.client.counters.sent, 0, "not fired back")
    pair.now = pair.now + 6
    pair.host_world:game_pulses_flag(guid(4))
    pair:step(3, pair.tick)
    T.eq(#pair.client_world.pulses, 2, "every time it fires")
end)

T.run("partner_flags_wait_while_their_cutscene_plays_here", function()
    local pair = flag_pair()
    pair.client:hold(pair.now)
    pair.host_world:game_sets_flag(guid(11), true) -- the host's cutscene ended: its end flag
    pair:step(3, pair.tick)
    T.eq(pair.client_world.flags[guid(11)], nil, "held while our copy of the cutscene plays")
    T.eq(pair.client:summary().holding, 1, "shown as waiting")
    pair.client:release(pair.now, pair.client_world)
    T.eq(pair.client_world.flags[guid(11)], true, "applied when it ended")
    -- A hold never lasts forever.
    pair.client:hold(pair.now, 1)
    pair.host_world:game_sets_flag(guid(12), true)
    pair:step(30, pair.tick)
    T.eq(pair.client_world.flags[guid(12)], true, "released by the timeout")
    -- A hold that runs out just as more flags arrive: the waiting ones first, none forgotten.
    pair.client:hold(pair.now, 1)
    pair.client:on_flags({ flags = { { guid = guid(13), value = true } } }, pair.now, pair.client_world)
    pair.now = pair.now + 2
    pair.client:on_flags({ flags = { { guid = guid(14), value = true } } }, pair.now, pair.client_world)
    T.eq(pair.client_world.flags[guid(13)], true, "the held flag applied")
    T.eq(pair.client_world.flags[guid(14)], true, "and the new one")
    T.eq(pair.client:summary().holding, nil, "nothing left waiting")
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
    for i = 1, 16 do
        pair.host_world:game_sets_flag(guid(5), i % 2 == 0)
        pair:step(2, pair.tick)
    end
    T.check(pair.host.counters.muted >= 1, "flag muted after flapping")
    local sent = pair.host.counters.sent
    pair.host_world:game_sets_flag(guid(5), false)
    pair.host_world:game_sets_flag(guid(5), true)
    pair:step(2, pair.tick)
    T.eq(pair.host.counters.sent, sent, "muted flag not sent")
    pair.now = pair.now + 61
    pair.host_world:game_sets_flag(guid(5), false)
    pair.host_world:game_sets_flag(guid(5), true)
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
    pair.host_world.groups.Main[2] = 0x4 -- clear bit 0 (the host reloaded)
    pair:step(10, pair.tick)
    T.eq(pair.client_world.groups.Main[2], 0x5, "a cleared bit is never applied")
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
    local k5 = P.ctx_key({ category = 1, kind = 0, group = 5, index = 0 })
    local announced = {}
    function pair.host_world:gimmick_dirty_keys()
        local k = announced
        announced = {}
        return k
    end
    pair.host_world:set_gimmick(5, "\5\0", 1) -- the host opens a door...
    dirty, announced = true, { [k5] = true }      -- ...and the game calls GimmickManager.pushDirtyList
    pair:step(16, pair.tick)                      -- 0.8 s: long before the next periodic scan
    T.check(pair.client_world.gimmicks[k5] ~= nil and pair.client_world.gimmicks[k5].attr == "\5\0",
        "client's door opened within a second")
    T.eq(pair.host.counters.scans, scans, "no full scan")
    T.eq(pair.host.counters.targeted, 1, "only the announced gimmick was read")
end)

T.run("announced_change_without_keys_triggers_a_full_scan", function()
    local pair = gimmick_pair()
    pair.host.settings.gimmick_interval = 10
    pair:step(5, pair.tick)
    local scans = pair.host.counters.scans
    local dirty = false
    function pair.host_world:gimmicks_dirty()
        local d = dirty
        dirty = false
        return d
    end
    pair.host_world:set_gimmick(6, "\6\0", 1)
    dirty = true
    pair:step(30, pair.tick)
    local k6 = P.ctx_key({ category = 1, kind = 0, group = 6, index = 0 })
    T.eq(pair.client_world.gimmicks[k6] and pair.client_world.gimmicks[k6].attr, "\6\0", "sent within 1.5 s")
    T.eq(pair.host.counters.scans, scans + 1, "one extra full scan")
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
    pair.replays = {}
    local function on_replay(who) return function(started) pair.replays[#pair.replays + 1] = { who, started } end end
    pair.host = CutsceneSync.new({ role = "host", protocol = P, settings = {}, on_replay = on_replay("host"),
        send = function(b) table.insert(pair.to_client, b) end })
    pair.client = CutsceneSync.new({ role = "client", protocol = P, settings = {}, on_replay = on_replay("client"),
        send = function(b) table.insert(pair.to_host, b) end })
    pair.deliver = function(self)
        local tc, th = self.to_client, self.to_host
        self.to_client, self.to_host = {}, {}
        for _, b in ipairs(tc) do self.client:on_message(assert(P.decode(b)), self.now) end
        for _, b in ipairs(th) do self.host:on_message(assert(P.decode(b)), self.now) end
    end
    pair.host_world.on_cutscene = function(ev) pair.host:on_local_start(ev, pair.now, pair.host_loc) end
    pair.client_world.on_cutscene = function(ev) pair.client:on_local_start(ev, pair.now, pair.client_loc) end
    pair.host_world.on_skip = function(ev) pair.host:on_local_skip(ev, pair.now) end
    pair.client_world.on_skip = function(ev) pair.client:on_local_skip(ev, pair.now) end
    pair.tick = function(p)
        p.host:tick(p.now, p.host_world, p.host_loc, p.travel)
        p.client:tick(p.now, p.client_world, p.client_loc, p.travel)
    end
    return pair
end

local CHURCH = { camera = 1, id = 20130, screen = 3, owner_code = 0x1234, end_portrayal = 0xAB,
    start_flags = { { group = 0, index = 5 } }, end_flags = { { group = 2, index = 9 } } }

T.run("cutscene_plays_for_both_once", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene({ camera = 1, id = 10157 }) -- host walks into the trigger
    pair:step(25, pair.tick)
    T.eq(#pair.client_world.played, 1, "client plays it")
    T.eq(pair.client_world.played[1].id, 10157, "same cutscene")
    T.eq(pair.host.counters.sent, 1, "host announced once")
    T.eq(pair.client.counters.sent, 0, "client's replay is not announced back")
    T.eq(#pair.host_world.played, 0, "host not asked to replay its own cutscene")
end)

T.run("the_partners_payload_plays_here_whole", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene(CHURCH)
    pair:step(25, pair.tick)
    local ev = pair.client_world.played[1]
    T.check(ev ~= nil, "played")
    T.eq(ev.screen, 3, "same screen")
    T.eq(ev.owner_code, 0x1234, "same data owner (continues its scripted sequence here)")
    T.eq(ev.end_portrayal, 0xAB, "same next step")
    T.eq(ev.start_flags[1].index, 5, "start flags (set by our copy)")
    T.eq(ev.end_flags[1].group, 2, "end flags (set by our copy when it ends)")
    T.eq(pair.replays[1][1], "client", "the session hears the replay start (partner flags wait)")
    T.eq(pair.replays[1][2], true, "started")
    pair.client_world.playing = nil -- it ends here
    pair:step(2, pair.tick)
    T.eq(pair.replays[2][2], false, "and end (partner flags go through)")
end)

T.run("cutscene_triggered_by_both_is_one_cutscene", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene(CHURCH)
    pair.client_world:game_plays_cutscene(CHURCH)
    pair:step(25, pair.tick)
    T.eq(#pair.host_world.played, 0, "host played only its own")
    T.eq(#pair.client_world.played, 0, "client played only its own")
end)

T.run("a_cutscene_our_game_starts_by_itself_meanwhile_is_not_played_twice", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene(CHURCH)
    pair:step(1, pair.tick)
    -- The host's trigger arrived too and our game started the same cutscene itself.
    pair.client_world:game_plays_cutscene(CHURCH)
    pair:step(25, pair.tick)
    T.eq(#pair.client_world.played, 0, "no second copy")
end)

T.run("a_cutscene_this_save_already_saw_is_skipped", function()
    local pair = cutscene_pair()
    pair.client_world.done["1:20130"] = true
    pair.host_world:game_plays_cutscene(CHURCH)
    pair:step(25, pair.tick)
    T.eq(#pair.client_world.played, 0, "never twice in one save")
    T.eq(pair.client.counters.already_seen, 1, "counted")
end)

T.run("partner_far_away_watches_at_once_and_joins_afterwards", function()
    local pair = cutscene_pair()
    pair.client_loc.stage = 200
    pair.host_world:game_plays_cutscene(CHURCH)
    pair:step(2, pair.tick) -- 0.1 s
    T.eq(#pair.client_world.played, 1, "played at once, without travelling first")
    T.eq(#pair.travel.requests, 0, "no travel before it")
    pair:step(20, pair.tick)
    T.eq(#pair.travel.requests, 0, "nor while it plays")
    pair.client_world.playing = nil -- it ends
    pair:step(2, pair.tick)
    T.eq(#pair.travel.requests, 1, "then the client joins the host")
    T.eq(pair.travel.requests[1].stage, 100, "in the host's stage")
end)

T.run("partner_nearby_starts_after_a_short_grace", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene(CHURCH)
    pair:step(2, pair.tick)
    T.eq(#pair.client_world.played, 0, "its own game may start it first")
    pair:step(6, pair.tick) -- 0.4 s
    T.eq(#pair.client_world.played, 1, "played within a third of a second")
    pair.client_world.playing = nil
    pair:step(3, pair.tick)
    T.eq(#pair.travel.requests, 0, "no travel: it was there")
end)

T.run("cutscene_in_another_chapter_is_dropped", function()
    local pair = cutscene_pair()
    pair.client_loc.chapter = 22200
    pair.host_world:game_plays_cutscene({ camera = 1, id = 30000 })
    pair:step(25, pair.tick)
    T.eq(#pair.client_world.played, 0, "not replayed")
    T.eq(pair.client.counters.dropped, 1, "dropped with a reason")
end)

T.run("a_refused_replay_is_retried_then_dropped", function()
    local pair = cutscene_pair()
    pair.client_world.refuse_cutscenes = true
    pair.host_world:game_plays_cutscene(CHURCH)
    pair:step(40, pair.tick)
    T.eq(pair.client.counters.dropped, 1, "dropped after a few tries")
    T.eq(#pair.replays, 0, "no replay started")
end)

T.run("skipping_a_cutscene_skips_it_for_both", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene({ camera = 1, id = 300 })
    pair:step(30, pair.tick) -- the client plays it too
    T.eq(pair.client_world.playing_key, "1:300", "both watch it")
    pair.host_world:player_skips()
    pair:step(3, pair.tick)
    T.eq(pair.client_world.skips and pair.client_world.skips[1], "1:300", "skipped in the client's game")
    T.eq(pair.client.counters.skips_applied, 1, "counted")
    T.eq(pair.client.counters.skips_sent, 0, "not sent back")
    T.eq(pair.host.counters.skips_received, 0, "no echo")
end)

T.run("a_skip_reaches_a_cutscene_that_starts_later", function()
    local pair = cutscene_pair()
    pair.client_world.playing = true -- the client's game is busy with another cutscene
    pair.host_world:game_plays_cutscene({ camera = 1, id = 301 })
    pair:step(3, pair.tick)
    pair.host_world:player_skips() -- the host skips before the client's copy started
    pair:step(3, pair.tick)
    T.eq(pair.client:summary().skips_waiting, 1, "the skip waits for the cutscene")
    pair.client_world.playing = nil -- the other one ends
    pair:step(30, pair.tick)
    T.eq(#pair.client_world.played, 1, "the client's copy started")
    T.eq(pair.client_world.skips and pair.client_world.skips[1], "1:301", "and was skipped at once")
    -- A skip for a cutscene that never plays here is forgotten.
    pair.client:on_skip({ camera = 1, id = 999 }, pair.now)
    pair.now = pair.now + 100
    pair:step(2, pair.tick)
    T.eq(pair.client:summary().skips_waiting, nil, "forgotten")
end)

-- docs/RESEARCH.md 3.36: a skip that landed in our copy's first frames left the screen black.
-- The adapter answers "waiting" until a player here could skip it; the skip waits that long.
T.run("a_skip_waits_until_our_copy_can_be_skipped", function()
    local pair = cutscene_pair()
    pair.host_world:game_plays_cutscene({ camera = 2, id = 10153 }) -- reported as a movie
    pair:step(30, pair.tick)
    local cw = pair.client_world
    local plain = cw.cutscene_skip
    local asked, ready_at = 0, pair.now + 2.0
    function cw:cutscene_skip(camera, id, now)
        asked = asked + 1
        T.eq(id, 10153, "same cutscene")
        if now < ready_at then return "waiting" end
        return plain(self, 2, id)
    end
    pair.host_world:player_skips()
    pair:step(5, pair.tick)
    T.eq(pair.client:summary().skips_waiting, 1, "waits while the copy cannot be skipped")
    T.eq(cw.skips, nil, "not skipped yet")
    pair:step(40, pair.tick)
    T.eq(cw.skips and cw.skips[1], "2:10153", "skipped once it can be")
    T.eq(pair.client.counters.skips_applied, 1, "counted")
    T.eq(pair.client:summary().skips_waiting, nil, "nothing waits")
    T.check(asked > 2, "asked again while waiting")
end)

T.run("a_skip_of_a_cutscene_skipped_here_already_is_dropped", function()
    local pair = cutscene_pair()
    function pair.client_world:cutscene_skip() return "done" end
    pair.client:on_skip({ camera = 1, id = 77 }, pair.now)
    pair:step(2, pair.tick)
    T.eq(pair.client:summary().skips_waiting, nil, "dropped: both skipped it")
    T.eq(pair.client.counters.skips_applied, 0, "nothing applied")
    -- A skip of one that is neither playing nor coming here waits only a little.
    pair.client_world.cutscene_skip = function() return "missing" end
    pair.client:on_skip({ camera = 1, id = 78 }, pair.now)
    pair:step(2, pair.tick)
    T.eq(pair.client:summary().skips_waiting, 1, "waits a moment for our copy")
    pair.now = pair.now + 11
    pair:step(2, pair.tick)
    T.eq(pair.client:summary().skips_waiting, nil, "then forgotten")
end)

-- docs/RESEARCH.md 3.37: both games run the same level, so ours asked for the host's cutscene
-- itself while our copy of it played (its own trigger or timer); the game queued that request
-- and showed the cutscene a second time.
T.run("our_game_asking_again_for_the_partners_cutscene_is_a_repeat", function()
    local pair = cutscene_pair()
    local logs = {}
    pair.client.log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
    local BELL = { camera = 2, id = 10011 }
    pair.host_world:game_plays_cutscene(BELL)
    pair:step(30, pair.tick)
    T.eq(#pair.client_world.played, 1, "our copy of the host's cutscene plays")
    T.eq(pair.client:on_local_start({ camera = 2, id = 10011 }, pair.now, pair.client_loc), "repeat",
        "our game asks for it again meanwhile")
    T.eq(pair.client:on_local_start({ camera = 1, id = 10011 }, pair.now, pair.client_loc), "repeat", "by its number")
    pair:step(5, pair.tick)
    T.eq(pair.client.counters.sent, 0, "never announced to the host")
    T.eq(pair.client.counters.repeats, 2, "counted")
    T.check(logs[#logs]:find("not shown twice", 1, true) ~= nil, "logged")
    -- Our copy ends; the game asks again a little later: still that copy's cutscene.
    pair.client_world.playing = nil
    pair:step(2, pair.tick)
    pair.now = pair.now + 30
    T.eq(pair.client:on_local_start(BELL, pair.now, pair.client_loc), "repeat", "half a minute after it ended")
    -- Another cutscene, or the same one long after: our game's own, as always.
    T.eq(pair.client:on_local_start({ camera = 1, id = 10013 }, pair.now, pair.client_loc), true, "another one is sent")
    pair.now = pair.now + 61
    T.eq(pair.client:on_local_start(BELL, pair.now, pair.client_loc), true, "a minute on it is the game's own again")
end)

T.run("a_copy_that_never_showed_here_does_not_hold_our_own_back", function()
    local pair = cutscene_pair()
    function pair.client_world:cutscene_play(ev) self.played[#self.played + 1] = ev return true end -- never shows
    pair.host_world:game_plays_cutscene({ camera = 2, id = 10011 })
    pair:step(30, pair.tick)
    T.eq(#pair.client_world.played, 1, "asked to play")
    pair.now = pair.now + 16
    pair:step(2, pair.tick) -- START_TIMEOUT: it counts as over
    T.eq(pair.client:summary().replaying, nil, "over")
    T.eq(pair.client:on_local_start({ camera = 2, id = 10011 }, pair.now, pair.client_loc), true,
        "our game's own request goes ahead")
end)

T.run("skips_can_be_switched_off", function()
    local pair = cutscene_pair()
    pair.client.settings.sync_skips = false
    pair.host_world:game_plays_cutscene({ camera = 1, id = 302 })
    pair:step(30, pair.tick)
    pair.host_world:player_skips()
    pair:step(3, pair.tick)
    T.eq(pair.client_world.skips, nil, "the client watches it to the end")
end)

-------------------------------------------------------------------------------
-- Event triggers
-------------------------------------------------------------------------------

local function trigger_pair(settings)
    local pair = make_pair(TriggerSync, settings)
    pair.host_loc = { chapter = 21100, stage = 100, pos = { x = 0, y = 0, z = 0 }, playable = true }
    pair.client_loc = { chapter = 21100, stage = 100, pos = { x = 5, y = 0, z = 0 }, playable = true }
    pair.deliver = function(self)
        local tc, th = self.to_client, self.to_host
        self.to_client, self.to_host = {}, {}
        for _, b in ipairs(tc) do self.client:on_message(assert(P.decode(b)), self.now) end
        for _, b in ipairs(th) do self.host:on_message(assert(P.decode(b)), self.now) end
    end
    pair.tick = function(p)
        p.host:tick(p.now, p.host_world, p.host_loc)
        p.client:tick(p.now, p.client_world, p.client_loc)
    end
    return pair
end

local AMBUSH = { guid = guid(500), hash = 0xC0FFEE, trigger_type = 1, once = true }

T.run("an_event_trigger_runs_in_the_partners_game_too", function()
    local pair = trigger_pair()
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc) -- the host walks into the area
    pair:step(3, pair.tick)
    T.eq(pair.client_world.trigger_log[1], "run " .. guid(500), "run in the client's game")
    T.eq(pair.client.counters.run, 1, "counted")
    -- The client's own player walks in later: done, nothing happens twice.
    T.eq(pair.client_world:trigger_run(AMBUSH), "done", "done here now")
    T.eq(pair.host.counters.sent, 1, "sent once")
end)

T.run("a_far_partners_game_keeps_the_event_for_when_its_player_gets_there", function()
    local pair = trigger_pair()
    pair.client_loc.pos = { x = 200, y = 0, z = 0 }
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc)
    pair:step(3, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "not run from 200 m away")
    pair.now = pair.now + 21
    pair:step(2, pair.tick)
    T.eq(pair.client.counters.missed, 1, "missed")
    local t = pair.client_world.triggers[AMBUSH.guid .. ":" .. AMBUSH.hash]
    T.eq(t.done, false, "never marked done: the client's game runs it when its player walks in")
    T.eq(pair.client:summary().queued, 0, "nothing left waiting")
end)

T.run("a_partner_who_gets_there_in_time_runs_it", function()
    local pair = trigger_pair()
    pair.client_loc.stage, pair.client_loc.pos = 300, { x = 200, y = 0, z = 0 }
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc)
    pair:step(10, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "elsewhere")
    pair.client_loc.stage, pair.client_loc.pos = 100, { x = 10, y = 0, z = 0 } -- the client arrives
    pair:step(10, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "its area is not loaded yet")
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.now = pair.now + 2
    pair:step(2, pair.tick)
    T.eq(pair.client_world.trigger_log[1], "run " .. guid(500), "run once loaded")
end)

T.run("a_trigger_that_is_no_event_in_our_game_is_refused", function()
    local pair = trigger_pair()
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true, true)
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc)
    pair:step(3, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "not run")
    T.eq(pair.client.counters.refused, 1, "refused once, not retried")
    T.eq(pair.client:summary().queued, 0, "nothing left waiting")
end)

T.run("a_trigger_without_our_location_is_not_sent", function()
    local pair = trigger_pair()
    T.eq(pair.host:on_local_trigger(AMBUSH, pair.now, nil), false, "nowhere")
    T.eq(pair.host.counters.sent, 0, "not sent")
end)

T.run("a_partner_in_a_cutscene_runs_the_event_when_playable", function()
    local pair = trigger_pair()
    pair.client_loc.playable = false
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc)
    pair:step(10, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "waits")
    pair.client_loc.playable = true
    pair:step(15, pair.tick)
    T.eq(pair.client_world.trigger_log[1], "run " .. guid(500), "runs once playable")
end)

T.run("both_setting_it_off_is_one_event", function()
    local pair = trigger_pair()
    pair.host_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc)
    pair.client:on_local_trigger(AMBUSH, pair.now, pair.client_loc)
    pair:step(5, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "client ran it itself only")
    T.eq(#pair.host_world.trigger_log, 0, "host ran it itself only")
    T.eq(pair.host.counters.dupes + pair.client.counters.dupes, 2, "recognised as the same event")
end)

T.run("another_chapter_drops_it", function()
    local pair = trigger_pair()
    pair.client_loc.chapter = 22100
    pair.client_world:add_trigger(AMBUSH.guid, AMBUSH.hash, true)
    pair.host:on_local_trigger(AMBUSH, pair.now, pair.host_loc)
    pair:step(3, pair.tick)
    T.eq(#pair.client_world.trigger_log, 0, "not applied")
    T.eq(pair.client.counters.dropped, 1, "dropped")
end)

-------------------------------------------------------------------------------
-- Doors
-------------------------------------------------------------------------------

-- A game's doors as GmDoor behaves: open bit -> opens; closes when neither slot keeps it open.
local function door_world(loaded)
    local w = { doors = {} }
    for _, g in ipairs(loaded) do w.doors[g] = { open = false, attr = 0, host = false, guest = false, pos = { x = 0, y = 0, z = 0 } } end
    function w:doors_near(pos, radius)
        local out = {}
        for g, d in pairs(self.doors) do
            local dx = d.pos.x - pos.x
            if math.abs(dx) <= radius then out[g] = { open = d.open, hold = d.host, attr = d.attr } end
        end
        return out
    end
    function w:door_apply(g, st)
        local d = self.doors[g]
        if d == nil then return "missing" end
        d.guest = st.hold and true or false
        if st.open and not d.open then d.attr = st.attr | 1 end
        return "done"
    end
    function w:doors_release() for _, d in pairs(self.doors) do d.guest = false end end
    function w:update() -- the game's door logic
        for _, d in pairs(self.doors) do
            if not d.open and (d.attr & 1) ~= 0 then d.open = true
            elseif d.open and not d.host and not d.guest then d.open, d.attr = false, d.attr & 0xFE end
        end
    end
    return w
end

local DOOR = guid(700)

local function door_pair()
    local pair = make_pair(DoorSync)
    pair.host_world, pair.client_world = door_world({ DOOR }), door_world({ DOOR })
    pair.host_pos, pair.client_pos = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
    pair.tick = function(p)
        p.host_world:update()
        p.client_world:update()
        p.host:tick(p.now, p.host_world, p.host_pos)
        p.client:tick(p.now, p.client_world, p.client_pos)
    end
    return pair
end

T.run("a_door_opened_by_one_player_opens_and_stays_open_for_both", function()
    local pair = door_pair()
    pair:step(4, pair.tick)
    T.eq(pair.host.counters.sent, 0, "closed doors are not news")
    -- The client opens the door and walks through it.
    local cd = pair.client_world.doors[DOOR]
    cd.host, cd.attr = true, 2 | 1
    pair:step(6, pair.tick)
    local hd = pair.host_world.doors[DOOR]
    T.eq(hd.open, true, "open in the host's game")
    T.eq(hd.attr & 2, 2, "on the same side")
    pair:step(40, pair.tick)
    T.eq(hd.open, true, "and it stays open while the client is in it")
    T.eq(cd.open, true, "the client's too")
    -- The client walks on: it closes in both games.
    cd.host = false
    pair:step(10, pair.tick)
    T.eq(cd.open, false, "closed for the client")
    T.eq(hd.open, false, "and for the host")
end)

T.run("a_door_stays_open_while_either_player_is_in_it", function()
    local pair = door_pair()
    local cd, hd = pair.client_world.doors[DOOR], pair.host_world.doors[DOOR]
    cd.host, cd.attr = true, 1
    pair:step(6, pair.tick)
    hd.host = true -- the host steps into the open door too
    cd.host = false -- the client walks on
    pair:step(20, pair.tick)
    T.eq(cd.open, true, "the client's door stays open: the host is in it")
    T.eq(hd.open, true, "the host's too")
    hd.host = false
    pair:step(10, pair.tick)
    T.eq(cd.open and hd.open, false, "closed once nobody is in it")
end)

T.run("a_partner_walking_away_from_an_open_door_releases_it", function()
    local pair = door_pair()
    local cd, hd = pair.client_world.doors[DOOR], pair.host_world.doors[DOOR]
    cd.host, cd.attr = true, 1
    pair:step(6, pair.tick)
    T.eq(hd.open, true, "open for the host")
    pair.client_pos = { x = 200, y = 0, z = 0 } -- the client runs off (the door leaves its range)
    cd.host = true -- its game still thinks it holds it
    pair:step(6, pair.tick)
    T.eq(hd.guest, false, "the host's door is no longer held for the client")
end)

T.run("a_door_not_loaded_yet_waits_a_little", function()
    local pair = door_pair()
    pair.host_world.doors[DOOR] = nil -- the host has not loaded that area
    local cd = pair.client_world.doors[DOOR]
    cd.host, cd.attr = true, 1
    pair:step(6, pair.tick)
    T.eq(pair.host:summary().queued, 1, "waiting")
    pair.host_world.doors[DOOR] = { open = false, attr = 0, host = false, guest = false, pos = { x = 0, y = 0, z = 0 } }
    pair:step(12, pair.tick)
    T.eq(pair.host_world.doors[DOOR].open, true, "opened once loaded")
    T.eq(pair.host:summary().queued, 0, "nothing waits")
end)

T.run("doors_can_be_switched_off", function()
    local pair = door_pair()
    pair.host.settings.sync_doors = false
    local cd = pair.client_world.doors[DOOR]
    cd.host, cd.attr = true, 1
    pair:step(6, pair.tick)
    T.eq(pair.host_world.doors[DOOR].open, false, "not applied")
end)

T.finish()
