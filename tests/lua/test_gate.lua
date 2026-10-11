-- Transition gate: who waits for whom at cutscenes and chapter changes, and when they go on.
local T = require("testlib")
local Gate = require("re4coop.gate")

local function base()
    return {
        connected = true, in_game = true, event = false, chapter = 21100, stage = 43300, pos = { x = 0, y = 0, z = 0 },
        partner_fresh = true, partner_event = false, partner_chapter = 21100, partner_stage = 43300,
        partner_pos = { x = 60, y = 0, z = 0 }, continue_pressed = false,
    }
end

local function make(settings)
    settings = settings or {}
    for k, v in pairs({ transition_gate = true, gate_grace = 1.5, gate_radius = 10.0 }) do
        if settings[k] == nil then settings[k] = v end
    end
    local g = { gate = Gate.new(settings), now = 0, s = base() }
    function g:run(seconds, step)
        step = step or 0.1
        local last
        local t = 0
        while t < seconds - 1e-9 do
            self.now = self.now + step
            t = t + step
            last = self.gate:update(self.now, self.s)
            self.s.continue_pressed = false
        end
        return last
    end
    return g
end

T.run("short_events_never_hold", function()
    local g = make()
    g.s.event = true
    T.eq(g:run(1.2), nil, "door animation (1.2 s) passes")
    g.s.event = false
    T.eq(g:run(1), nil, "still open")
end)

T.run("long_event_holds_until_partner_arrives", function()
    local g = make()
    g.s.event = true
    T.eq(g:run(1.4), nil, "not before the grace period")
    T.eq(g:run(0.3), "event", "held: partner is 60 m away")
    T.eq(g:run(5), "event", "still waiting")
    g.s.partner_pos = { x = 5, y = 0, z = 0 } -- partner teleported next to us
    T.eq(g:run(0.5), "event", "arrived moments ago")
    T.eq(g:run(0.7), nil, "released after standing nearby for a second")
    T.eq(g.gate.last_release, "partner arrived", "reason")
    T.eq(g:run(5), nil, "this event is not held again")
end)

T.run("partner_entering_the_same_event_releases", function()
    local g = make()
    g.s.event = true
    g:run(2)
    T.eq(g.gate.holding, "event", "holding")
    g.s.partner_pos = { x = 20, y = 0, z = 0 }
    g.s.partner_event = true -- their copy of the cutscene started
    T.eq(g:run(0.1), nil, "both in the event: go")
end)

T.run("partner_in_another_event_far_away_is_not_ready", function()
    local g = make()
    g.s.event = true
    g.s.partner_event = true
    g.s.partner_stage = 43410
    g.s.partner_pos = { x = 200, y = 0, z = 0 }
    T.eq(g:run(2), "event", "a different cutscene elsewhere does not count")
end)

T.run("partner_already_there_means_no_hold", function()
    local g = make()
    g.s.partner_pos = { x = 4, y = 0, z = 0 }
    g:run(2)
    g.s.event = true
    T.eq(g:run(3), nil, "partner standing with us: the event just plays")
end)

T.run("continue_key_releases_without_rehold", function()
    local g = make()
    g.s.event = true
    g:run(2)
    g.s.continue_pressed = true
    T.eq(g:run(0.1), nil, "continue alone")
    T.eq(g.gate.last_release, "continued alone", "reason")
    T.eq(g:run(5), nil, "same event not held again")
    g.s.event = false
    g:run(1)
    g.s.event = true
    T.eq(g:run(2), "event", "the next event holds again")
end)

T.run("disconnect_releases", function()
    local g = make()
    g.s.event = true
    g:run(2)
    g.s.connected = false
    T.eq(g:run(0.1), nil, "released")
    T.eq(g.gate.last_release, "partner disconnected", "reason")
end)

T.run("partner_loading_keeps_the_hold", function()
    local g = make()
    g.s.event = true
    g:run(2)
    g.s.partner_fresh = false -- partner on a loading screen after teleporting
    T.eq(g:run(3), "event", "still waiting")
end)

T.run("chapter_gate_waits_for_the_partner", function()
    local g = make()
    g:run(1) -- both in 21100
    g.s.chapter = 21200 -- we went through to the next part
    T.eq(g:run(0.1), "chapter", "held at the start of the new part")
    g.s.partner_fresh = false -- partner finishing the part / loading
    T.eq(g:run(10), "chapter", "still waiting")
    g.s.partner_fresh = true
    g.s.partner_chapter = 21200
    T.eq(g:run(0.1), nil, "partner arrived")
end)

T.run("chapter_gate_not_on_joining_from_different_saves", function()
    local g = make()
    g.s.chapter, g.s.partner_chapter = 22100, 21100
    T.eq(g:run(5), nil, "chapters never matched in this session: no hold")
end)

T.run("chapter_gate_skip_lasts_until_chapters_match", function()
    local g = make()
    g:run(1)
    g.s.chapter = 21200
    g:run(0.1)
    g.s.continue_pressed = true
    T.eq(g:run(0.1), nil, "continued alone")
    T.eq(g:run(5), nil, "not held again")
    g.s.partner_chapter = 21200
    g:run(0.5)
    g.s.chapter = 21300
    T.eq(g:run(0.1), "chapter", "next chapter change holds again")
end)

T.run("partner_ahead_does_not_hold_us", function()
    local g = make()
    g:run(1)
    g.s.partner_chapter = 21200
    T.eq(g:run(3), nil, "the player behind is never frozen")
end)

T.run("switched_off", function()
    local g = make({ transition_gate = false })
    g.s.event = true
    T.eq(g:run(5), nil, "never holds")
    local g2 = make()
    g2.s.event = true
    g2:run(2)
    g2.gate.settings.transition_gate = false
    T.eq(g2:run(0.1), nil, "switching it off releases")
end)

T.finish()
