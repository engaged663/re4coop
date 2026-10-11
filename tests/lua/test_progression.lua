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
    local g = { pos = { x = x, y = 0, z = 0 }, keys = {}, teleports = {}, cutscene = false, floor = nil }
    function g:read_player_state()
        return { pos = { x = self.pos.x, y = self.pos.y, z = self.pos.z }, rot = { x = 0, y = 0, z = 0, w = 1 },
            hp = 100, max_hp = 100, cutscene = self.cutscene }
    end
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
    T.eq(#w.gb.teleports, 0, "F6 does nothing without a prompt")
end)

T.run("no_prompt_during_cutscenes", function()
    local w = make_world()
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

T.run("key_names", function()
    T.eq(Session.key_name(0x75), "F6", "F6")
    T.eq(Session.key_name(0x7B), "F12", "F12")
    T.eq(Session.key_name(0x54), "T", "letter")
    T.eq(Session.key_name(0x20), "key 0x20", "other")
end)

T.finish()
