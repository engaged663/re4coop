-- screen_watch.lua: our game's transitions and a screen they leave black.
local T = require("testlib")
local ScreenWatch = require("re4coop.screen_watch")

local function make(settings)
    local logs, notes = {}, {}
    local w = ScreenWatch.new({ settings = settings or {},
        log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end,
        notify = function(text, kind) notes[#notes + 1] = { text = text, kind = kind } end })
    return w, logs, notes
end

local function playing(dark, busy)
    return { transition = false, playing = true, busy = busy or false, dark = dark }
end

T.run("black_left_after_a_transition_is_lifted_after_ten_seconds", function()
    local w, logs, notes = make()
    -- The chapter change: black is the game's own.
    for t = 0, 20, 0.5 do
        T.eq(#w:tick(t, { transition = true, dark = { 2, 4 } }), 0, "never during the transition")
    end
    T.eq(w.counters.transitions, 1, "one transition")
    -- Back in play, still black.
    local lifted
    for t = 20.5, 40, 0.5 do
        local l = w:tick(t, playing({ 2, 4 }))
        if #l > 0 and lifted == nil then
            lifted = { t = t, types = l }
            w:lifted(l, t)
        end
    end
    T.check(lifted ~= nil, "lifted")
    T.near(lifted.t - 20.5, ScreenWatch.BLACK_SECONDS, 0.51, "after BLACK_SECONDS of play")
    T.eq(lifted.types[1], 2, "the campaign jumper's fade")
    T.eq(lifted.types[2], 4, "and the event fade")
    T.eq(#notes, 1, "the player is told once")
    T.check(logs[#logs]:find("CAMPAIGN_JUMPER") ~= nil, "logged by name")
    T.near(w:summary(40).last_transition_length, 20, 0.6, "transition length kept")
end)

T.run("nothing_is_lifted_while_a_cutscene_or_a_hold_runs_or_the_player_is_gone", function()
    local w = make()
    for t = 0, 30, 0.5 do
        T.eq(#w:tick(t, playing({ 4 }, true)), 0, "busy: a cutscene / camera / our hold")
    end
    for t = 30, 60, 0.5 do
        T.eq(#w:tick(t, { transition = false, playing = false, busy = false, dark = { 4 } }), 0, "dead or not in game")
    end
    -- The count starts again once it can be judged.
    local first
    for t = 60, 80, 0.5 do
        if #w:tick(t, playing({ 4 })) > 0 and first == nil then first = t end
    end
    T.near(first - 60, ScreenWatch.BLACK_SECONDS, 0.01, "full wait from when it could be judged")
end)

T.run("a_fade_that_comes_back_by_itself_is_left_alone", function()
    local w = make()
    for t = 0, 8, 0.5 do T.eq(#w:tick(t, playing({ 4 })), 0, "short black (a door, a fade between shots)") end
    for t = 8.5, 30, 0.5 do T.eq(#w:tick(t, playing({})), 0, "came back") end
end)

T.run("retries_a_few_times_then_gives_up", function()
    local w = make()
    local lifts = 0
    for t = 0, 200, 0.5 do
        local l = w:tick(t, playing({ 4 })) -- the game ignores the lift: still dark
        lifts = lifts + #l
    end
    T.eq(lifts, ScreenWatch.MAX_LIFTS, "a few tries, never every frame")
end)

T.run("switched_off_lifts_nothing", function()
    local w = make({ fix_black_screen = false })
    for t = 0, 30, 0.5 do T.eq(#w:tick(t, playing({ 2 })), 0, "off") end
end)

T.run("a_long_transition_is_logged_once_with_what_it_does", function()
    local w, logs = make()
    local asked = 0
    local detail = function()
        asked = asked + 1
        return { state = "chainsaw.GameStateInGameChapterChange", phase = 20, saving = true }
    end
    for t = 0, 100, 0.5 do w:tick(t, { transition = true, detail = detail }) end
    T.eq(asked, 1, "detail read once")
    T.eq(w.counters.long_transitions, 1, "counted")
    T.check(logs[1]:find("GameStateInGameChapterChange, phase 20, saving") ~= nil, "logged with its phase")
    T.check(w:summary(100).transition_for > 99, "still in it")
end)

-- After a skip: the camera, skipped, still there and the EVENT layer dark (0.11.2's stuck skip).
local SKIPPED = { camera = 1, id = 10153, skipped = true, play_id = 7, address = 0x100 }

local function after_skip(cams, dark_all)
    return { transition = false, playing = true, busy = #cams > 0, cameras = cams, dark_all = dark_all, dark = {} }
end

T.run("black_long_after_a_skip_is_rescued_once", function()
    local w, logs, notes = make()
    local rescue_at, rescue
    for t = 0, 40, 0.5 do
        local _, r = w:tick(t, after_skip({ SKIPPED }, { 2, 4 }))
        if r ~= nil then
            T.check(rescue == nil, "only once")
            rescue_at, rescue = t, r
            w:rescued(r, t, "4=2/2")
        end
    end
    T.check(rescue ~= nil, "rescued")
    T.near(rescue_at, ScreenWatch.SKIP_STUCK, 0.01, "after SKIP_STUCK")
    T.eq(rescue.end_cameras[1], 7, "the skipped camera is ended")
    T.eq(#rescue.lift, 2, "two layers lifted")
    T.eq(rescue.lift[1], 2, "CAMPAIGN_JUMPER")
    T.eq(rescue.lift[2], 4, "EVENT")
    T.eq(rescue.what, "1:10153", "named")
    T.check(logs[#logs]:find("4=2/2", 1, true) ~= nil, "the fade layers written to the log")
    T.eq(#notes, 1, "the player told")
    T.eq(w.counters.skip_rescues, 1, "counted")
end)

T.run("an_ordinary_skip_is_left_alone", function()
    local w = make()
    -- The skip fades the EVENT layer out for a moment, the camera ends, the picture comes back.
    for t = 0, 1.5, 0.5 do
        local _, r = w:tick(t, after_skip({ SKIPPED }, { 4 }))
        T.eq(r, nil, "no rescue while it skips")
    end
    for t = 2, 40, 0.5 do
        local lift, r = w:tick(t, after_skip({}, {}))
        T.eq(r, nil, "none afterwards")
        T.eq(#lift, 0, "nothing lifted")
    end
    T.eq(w.counters.skips_watched, 1, "watched")
end)

T.run("a_skip_into_a_chapter_change_or_the_next_cutscene_is_not_rescued", function()
    local w = make()
    w:tick(0, after_skip({ SKIPPED }, { 4 }))
    for t = 0.5, 40, 0.5 do
        local _, r = w:tick(t, { transition = true, dark = { 2, 4 } }) -- the bell: a chapter change follows
        T.eq(r, nil, "the transition's black is the game's own")
    end
    local w2 = make()
    w2:tick(0, after_skip({ SKIPPED }, { 4 }))
    local NEXT = { camera = 1, id = 10154, skipped = false, play_id = 8, address = 0x200 }
    for t = 0.5, 40, 0.5 do
        local _, r = w2:tick(t, after_skip({ NEXT }, { 4 }))
        T.eq(r, nil, "the next cutscene owns the screen")
    end
end)

T.finish()
