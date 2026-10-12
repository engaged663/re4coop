-- Session-level progression features: left-behind teleport prompt, hotkeys, teleport retry
-- after falling through unloaded ground, and key-item messages during loading screens.
local T = require("testlib")
local P = require("re4coop.protocol")
local Session = require("re4coop.session")
local Config = require("re4coop.config")

-- In-memory "network" joining two sessions.
local function make_net_pair()
    local a, b = { inbox = {} }, { inbox = {} }
    local function make(me, other)
        return {
            state = function() return "connected" end,
            role = function() return me.role end,
            stats = function() return { state = "connected", peer_name = other.name, rtt_ms = 1 } end,
            poll = function()
                local out = me.inbox
                me.inbox = {}
                return out
            end,
            send = function(bytes, reliable)
                table.insert(other.inbox, { type = "message", data = bytes, reliable = reliable })
                return true
            end,
            stop = function() end,
        }
    end
    a.role, a.name, b.role, b.name = "host", "A", "client", "B"
    return make(a, b), make(b, a)
end

local function make_game(x)
    local g = { pos = { x = x, y = 0, z = 0 }, keys = {}, teleports = {}, cutscene = false, floor = nil,
        chapter = 21100, time_scale = 1.0 }
    function g:read_player_state()
        return { pos = { x = self.pos.x, y = self.pos.y, z = self.pos.z }, rot = { x = 0, y = 0, z = 0, w = 1 },
            hp = 100, max_hp = 100, cutscene = self.cutscene, stage = self.stage, chapter = self.chapter }
    end
    function g:get_time_scale() return self.time_scale end
    function g:set_time_scale(v) self.time_scale = v return true end
    function g:list_enemies() return {} end
    function g:area_name() return "" end
    function g:is_key_down(vk) return self.keys[vk] == true end
    function g:teleport_player(pos)
        self.teleports[#self.teleports + 1] = pos
        -- `floor` simulates unloaded ground: you land, then fall to it.
        self.pos = { x = pos.x, y = self.floor or pos.y, z = pos.z }
        return true
    end
    return g
end

local function make_world()
    local now = 0
    local clock = function() return now end
    local net_a, net_b = make_net_pair()
    local w = { ga = make_game(0), gb = make_game(0) }
    w.sa = Session.new({ net = net_a, game = w.ga, clock = clock, settings = Config.load(nil) })
    w.sb = Session.new({ net = net_b, game = w.gb, clock = clock, settings = Config.load(nil) })
    function w:advance(seconds, step)
        step = step or 0.05
        local t = 0
        while t < seconds - 1e-9 do
            now = now + step
            t = t + step
            self.sa:update()
            self.sb:update()
        end
    end
    function w:now() return now end
    w.sa.role, w.sb.role = "host", "client"
    w.sa:make_enemy_sync()
    w.sb:make_enemy_sync()
    w.sa.partner_connected, w.sb.partner_connected = true, true
    return w
end

T.run("prompt_appears_after_partner_stays_far", function()
    local w = make_world()
    w:advance(1)
    T.eq(w.sb.left_behind, nil, "no prompt while together")
    w.ga.pos = { x = 60, y = 0, z = 0 } -- A went through a door B cannot open
    w:advance(3)
    T.eq(w.sb.left_behind, nil, "not before left_behind_seconds")
    w:advance(4)
    T.check(w.sb.left_behind ~= nil and w.sb.left_behind.distance > 55, "prompt shown")
    T.check(w.sb:status().left_behind ~= nil, "exposed to the HUD")
    w.ga.pos = { x = 5, y = 0, z = 0 }
    w:advance(1)
    T.eq(w.sb.left_behind, nil, "prompt clears when back together")
end)

T.run("different_stage_prompts_at_shorter_distance", function()
    local w = make_world() -- far-away distance 35 m: another stage counts from 17.5 m
    w.ga.stage, w.gb.stage = 40200, 40200
    w.ga.pos = { x = 20, y = 0, z = 0 } -- through a door, same stage: not "far"
    w:advance(8)
    T.eq(w.sb.left_behind, nil, "same stage at 20 m: no prompt")
    w.ga.stage = 40210 -- the door led into the next stage
    w:advance(3)
    T.eq(w.sb.left_behind, nil, "not before left_behind_seconds")
    w:advance(4)
    T.check(w.sb.left_behind ~= nil and w.sb.left_behind.other_stage, "prompt: partner in another stage")
    T.eq(w.sb:status().partner_stage, 40210, "partner stage in status")
    T.eq(w.sb:status().local_stage, 40200, "own stage in status")
    w.ga.pos = { x = 10, y = 0, z = 0 } -- e.g. looting a house that belongs to the next stage
    w:advance(8)
    T.eq(w.sb.left_behind, nil, "10 m apart across a stage border: no prompt")
    w.ga.pos = { x = 20, y = 0, z = 0 }
    w.ga.stage = nil -- stage unreadable on A: distance rule only
    w:advance(8)
    T.eq(w.sb.left_behind, nil, "unknown stage falls back to distance")
end)

T.run("f6_teleports_and_notifies_partner", function()
    local w = make_world()
    w.ga.pos = { x = 60, y = 2, z = 0 }
    w:advance(7)
    T.check(w.sb.left_behind ~= nil, "prompt shown")
    w.gb.keys[0x75] = true
    w:advance(0.1)
    T.eq(#w.gb.teleports, 1, "teleported once (edge-triggered, key still held)")
    T.near(w.gb.teleports[1].x, 60, 0.5, "to the partner")
    w:advance(0.5)
    T.eq(#w.gb.teleports, 1, "holding F6 does not repeat")
    T.eq(w.sb.left_behind, nil, "prompt cleared")
    local told = false
    for _, m in ipairs(w.sa.messages) do
        if m.text:find("teleported to you") then told = true end
    end
    T.check(told, "partner notified")
end)

T.run("f7_snoozes_the_prompt", function()
    local w = make_world()
    w.ga.pos = { x = 80, y = 0, z = 0 }
    w:advance(7)
    T.check(w.sb.left_behind ~= nil, "prompt shown")
    w.gb.keys[0x76] = true
    w:advance(0.1)
    w.gb.keys[0x76] = false
    T.eq(w.sb.left_behind, nil, "hidden")
    w:advance(30)
    T.eq(w.sb.left_behind, nil, "still hidden 30 s later")
    T.eq(#w.gb.teleports, 0, "no teleport")
    w.gb.keys[0x75] = true
    w:advance(0.1)
    T.eq(#w.gb.teleports, 1, "F6 still teleports: the key works without the prompt")
end)

T.run("f6_works_any_time", function()
    local w = make_world()
    w.ga.pos = { x = 12, y = 0, z = 0 } -- just around the corner: no prompt
    w:advance(1)
    T.eq(w.sb.left_behind, nil, "no prompt")
    w.gb.keys[0x75] = true
    w:advance(0.1)
    w.gb.keys[0x75] = false
    T.eq(#w.gb.teleports, 1, "teleported")
    T.near(w.gb.teleports[1].x, 12, 0.5, "to the partner")
    -- Again at once: it recharges for a moment.
    w.ga.pos = { x = 40, y = 0, z = 0 }
    w:advance(0.5)
    w.gb.keys[0x75] = true
    w:advance(0.1)
    w.gb.keys[0x75] = false
    T.eq(#w.gb.teleports, 1, "not twice within the cooldown")
    local said = false
    for _, m in ipairs(w.sb.messages) do
        if m.text:find("ready again") then said = true end
    end
    T.check(said, "told when it is ready")
    w:advance(3)
    w.gb.keys[0x75] = true
    w:advance(0.1)
    w.gb.keys[0x75] = false
    T.eq(#w.gb.teleports, 2, "then again")
end)

T.run("f6_says_why_it_cannot_teleport", function()
    local w = make_world()
    local function last_message() return w.sb.messages[#w.sb.messages].text end
    local function press()
        w.gb.keys[0x75] = true
        w:advance(0.1)
        w.gb.keys[0x75] = false
        w:advance(0.1)
    end
    w.ga.pos = { x = 1, y = 0, z = 0 }
    w:advance(1)
    press()
    T.eq(#w.gb.teleports, 0, "next to the partner: nothing to do")
    T.check(last_message():find("already next to") ~= nil, "said so")
    w.ga.pos = { x = 50, y = 0, z = 0 }
    w.ga.cutscene = true
    w.sa.settings.transition_gate = false
    w:advance(1)
    press()
    T.eq(#w.gb.teleports, 0, "partner in a cutscene")
    T.check(last_message():find("cutscene") ~= nil, "said so")
    w.ga.cutscene = false
    w.gb.cutscene = true
    w.sb.settings.transition_gate = false
    w:advance(1)
    press()
    T.eq(#w.gb.teleports, 0, "we are in a cutscene")
    w.gb.cutscene = false
    w.ga.chapter = 22100
    w:advance(1)
    press()
    T.eq(#w.gb.teleports, 0, "partner in another chapter")
    T.check(last_message():find("another chapter") ~= nil, "said so")
end)

T.run("no_prompt_during_cutscenes", function()
    local w = make_world()
    -- Without the transition gate a cutscene never prompts (with it, see the gate tests).
    w.sa.settings.transition_gate, w.sb.settings.transition_gate = false, false
    w.ga.pos = { x = 90, y = 0, z = 0 }
    w.gb.cutscene = true
    w:advance(10)
    T.eq(w.sb.left_behind, nil, "local cutscene")
    w.gb.cutscene = false
    w.ga.cutscene = true
    w:advance(10)
    T.eq(w.sb.left_behind, nil, "partner in a cutscene")
end)

T.run("teleport_retries_after_falling_through_unloaded_ground", function()
    local w = make_world()
    w.ga.pos = { x = 100, y = 10, z = 0 }
    w:advance(0.5)
    w.gb.floor = -30 -- the ground under the partner is not loaded yet
    T.check(w.sb:teleport_to_partner(), "teleport")
    w:advance(1.0)
    T.eq(#w.gb.teleports, 3, "re-teleported up to the retry limit")
    local warned = false
    for _, m in ipairs(w.sb.messages) do
        if m.text:find("not loaded yet") then warned = true end
    end
    T.check(warned, "user told to try again")
    w.gb.floor = nil
    T.check(w.sb:teleport_to_partner(), "teleport again")
    w:advance(1.0)
    T.eq(#w.gb.teleports, 4, "no retry when the landing holds")
end)

T.run("item_taken_during_loading_is_kept", function()
    local w = make_world()
    w.sa:send(P.encode_item_taken({ item_id = 119235200, pos = { x = 1, y = 0, z = 0 },
        ctx = { category = 5, kind = 0, group = 1, index = 1 } }), true)
    w.sb:update_network_only() -- game loop not ticking (loading screen)
    T.eq(w.sb.item_sync.counters.taken_by_partner, 1, "recorded")
end)

T.run("gate_holds_at_a_long_event_until_partner_teleports_in", function()
    local w = make_world()
    w.gb.pos = { x = 80, y = 0, z = 0 }
    w:advance(1)
    w.ga.cutscene = true -- A triggers the chapter's ending cutscene
    w:advance(2)
    T.eq(w.sa.gate.holding, "event", "A waits")
    T.eq(w.ga.time_scale, 0, "A's game is frozen")
    local lb = w.sb.left_behind
    T.check(lb ~= nil and lb.partner_waiting == "here", "B is told right away (no delay)")
    T.eq(w.sb:status().left_behind.partner_waiting, "here", "shown on B's HUD")
    T.eq(w.sa:status().gate.holding, "event", "shown on A's HUD")
    w.gb.keys[0x75] = true -- B presses F6
    w:advance(0.1)
    w.gb.keys[0x75] = false
    T.eq(#w.gb.teleports, 1, "B teleported to A")
    w:advance(1.5)
    T.eq(w.sa.gate.holding, nil, "A released once B stood nearby")
    T.eq(w.ga.time_scale, 1.0, "A's game runs again")
    local told = false
    for _, m in ipairs(w.sa.messages) do
        if m.text:find("partner arrived") then told = true end
    end
    T.check(told, "A is told why it continues")
end)

T.run("gate_continue_key_and_shutdown_restore_time", function()
    local w = make_world()
    w.gb.pos = { x = 80, y = 0, z = 0 }
    w.ga.time_scale = 0.5 -- someone uses a slow-motion setting
    w.ga.cutscene = true
    w:advance(2)
    T.eq(w.ga.time_scale, 0, "frozen")
    w.ga.keys[0x77] = true -- F8
    w:advance(0.1)
    w.ga.keys[0x77] = false
    T.eq(w.sa.gate.holding, nil, "continued alone")
    T.eq(w.ga.time_scale, 0.5, "previous time scale restored")
    w.ga.cutscene = false
    w:advance(0.5)
    w.ga.cutscene = true
    w:advance(2)
    T.eq(w.ga.time_scale, 0, "next event frozen again")
    w.sa:shutdown() -- "Reset Scripts"
    T.eq(w.ga.time_scale, 0.5, "never left frozen")
end)

T.run("gate_releases_on_disconnect", function()
    local w = make_world()
    w.gb.pos = { x = 80, y = 0, z = 0 }
    w.ga.cutscene = true
    w:advance(2)
    T.eq(w.ga.time_scale, 0, "frozen")
    w.sa.partner_connected = false
    w.sa:update()
    T.eq(w.ga.time_scale, 1.0, "released when the partner is gone")
end)

T.run("chapter_gate_holds_the_player_ahead", function()
    local w = make_world()
    w:advance(1)
    w.ga.chapter = 21200 -- A reached the next part of the chapter
    w:advance(0.5)
    T.eq(w.sa.gate.holding, "chapter", "A waits")
    T.eq(w.ga.time_scale, 0, "frozen")
    T.check(w.sb.left_behind ~= nil and w.sb.left_behind.partner_waiting == "chapter", "B is told to finish the part")
    w.gb.keys[0x75] = true
    w:advance(0.1)
    w.gb.keys[0x75] = false
    T.eq(#w.gb.teleports, 0, "no teleport across chapters")
    w.gb.chapter = 21200
    w:advance(0.5)
    T.eq(w.sa.gate.holding, nil, "B arrived: A continues")
    T.eq(w.ga.time_scale, 1.0, "running")
end)

T.run("chapter_wait_allows_teleport_when_partner_stage_is_loaded", function()
    local w = make_world()
    w.ga.stage, w.gb.stage = 43300, 43300
    w.gb.pos = { x = 40, y = 0, z = 0 }
    function w.gb:stage_active(stage) return stage == 43300 end
    w:advance(1)
    w.ga.chapter = 21200 -- the chapter part changed without a new map
    w:advance(0.5)
    T.eq(w.sb.left_behind and w.sb.left_behind.partner_waiting, "here", "same map: teleport offered")
    w.gb.keys[0x75] = true
    w:advance(0.1)
    T.eq(#w.gb.teleports, 1, "teleported")
end)

T.run("gate_hold_that_stops_the_game_loop_is_undone", function()
    local w = make_world()
    w.gb.pos = { x = 80, y = 0, z = 0 }
    w.ga.cutscene = true
    w:advance(2)
    T.eq(w.ga.time_scale, 0, "frozen")
    w.sa:update_network_only() -- the game-thread callback stopped running
    T.eq(w.ga.time_scale, 1.0, "released")
    w:advance(2)
    T.eq(w.ga.time_scale, 0, "a single stall may have been a long frame: held again")
    w.sa:update_network_only() -- stalled again
    T.eq(w.ga.time_scale, 1.0, "released")
    w:advance(3)
    T.eq(w.ga.time_scale, 1.0, "gate stays off this session (no freeze/unfreeze loop)")
end)

T.run("gate_switched_off_never_freezes", function()
    local w = make_world()
    w.sa.settings.transition_gate = false
    w.gb.pos = { x = 80, y = 0, z = 0 }
    w.ga.cutscene = true
    w:advance(3)
    T.eq(w.ga.time_scale, 1.0, "not frozen")
end)

T.run("key_names", function()
    T.eq(Session.key_name(0x75), "F6", "F6")
    T.eq(Session.key_name(0x7B), "F12", "F12")
    T.eq(Session.key_name(0x54), "T", "letter")
    T.eq(Session.key_name(0x20), "key 0x20", "other")
end)

T.finish()
