-- Travel state machine against a fake world: warps, stage preloads, chapter switches.
local T = require("testlib")
local Travel = require("re4coop.travel")

local function make_world(opts)
    opts = opts or {}
    local w = { loc = opts.loc, preloads = {}, warps = {}, armed = nil, reloads = 0, refuse = opts.refuse or 0,
        no_arrive = opts.no_arrive }
    function w:location() return self.loc end
    function w:preload_stage(stage) self.preloads[#self.preloads + 1] = stage return true end
    function w:warp(stage, pos, yaw)
        self.warps[#self.warps + 1] = { stage = stage, pos = pos }
        if self.refuse > 0 then
            self.refuse = self.refuse - 1
            return false
        end
        if not self.no_arrive then
            self.loc.stage = stage or self.loc.stage
            self.loc.pos = { x = pos.x, y = pos.y, z = pos.z }
        end
        return true
    end
    function w:arm_chapter_switch(chapter) self.armed = chapter return true end
    function w:disarm_chapter_switch() self.armed = nil end
    -- The in-game Load Game into `chapter`, at the partner's place (refused: no save to load).
    function w:trigger_reload(chapter)
        self.reloads = self.reloads + 1
        if opts.reload_refused then return false, "no saved game to load" end
        self.reload_chapter = chapter
        if chapter ~= nil then self.armed = chapter end
        return true
    end
    -- What the game does when the player picks Continue with a switch armed.
    function w:load()
        self.loc = { chapter = self.armed or (self.loc and self.loc.chapter), stage = 1, pos = { x = 0, y = 0, z = 0 },
            playable = true }
    end
    return w
end

local function make_travel(settings)
    local log = { notes = {}, syncs = 0 }
    local tr
    tr = Travel.new({ settings = settings or {}, notify = function(text, kind) log.notes[#log.notes + 1] = { text, kind } end,
        on_sync = function() log.syncs = log.syncs + 1 end })
    return tr, log
end

local function run(tr, world, seconds, partner, now0)
    local now = now0 or 0
    for _ = 1, math.floor(seconds / 0.05) do
        now = now + 0.05
        tr:tick(now, world, partner)
        if not tr:busy() then break end
    end
    return now
end

local function noted(log, pattern)
    for _, n in ipairs(log.notes) do
        if n[1]:find(pattern) then return true end
    end
    return false
end

T.run("same_stage_warps_directly", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    local tr, log = make_travel()
    T.check(tr:request({ chapter = 21100, stage = 40200, pos = { x = 50, y = 1, z = 50 }, reason = "manual" }), "accepted")
    run(tr, world, 5)
    T.eq(tr:busy(), false, "done")
    T.eq(tr.result, "arrived", "arrived")
    T.eq(#world.warps, 1, "one warp")
    T.eq(#world.preloads, 0, "no preload needed")
    T.near(world.loc.pos.x, 50, 1e-6, "landed next to the partner")
    T.check(noted(log, "Arrived"), "player told")
end)

T.run("other_stage_is_preloaded_first", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    local tr = make_travel()
    tr:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "manual" })
    local now = run(tr, world, 1.0)
    T.eq(#world.warps, 0, "not yet")
    T.check(#world.preloads >= 2 and #world.preloads <= 3, "stage requested again while preloading, twice a second")
    T.eq(world.preloads[1], 43300, "the partner's stage")
    run(tr, world, 5, nil, now)
    T.eq(world.loc.stage, 43300, "warped into the stage")
    T.eq(tr.result, "arrived", "arrived")
end)

T.run("other_chapter_reloads_then_syncs_then_warps", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    local tr, log = make_travel()
    tr:request({ chapter = 22200, stage = 46100, pos = { x = 300, y = -7, z = -10 }, reason = "join", sync = true })
    local now = run(tr, world, 1)
    T.eq(world.armed, 22200, "chapter switch armed")
    T.eq(world.reloads, 1, "reload triggered")
    T.eq(tr.state, "chapter", "waiting for the load")
    world.loc = { chapter = 21100, loading = true, playable = false }  -- loading screen
    now = run(tr, world, 1, nil, now)
    world:load()                                                       -- Continue -> redirected load
    T.eq(world.loc.chapter, 22200, "loaded into the partner's chapter")
    now = run(tr, world, 3, nil, now)
    T.eq(world.armed, nil, "switch disarmed after use")
    T.eq(log.syncs, 1, "world sync requested")
    T.eq(tr.state, "sync_wait", "waiting for the world state")
    tr:sync_done()
    run(tr, world, 5, nil, now)
    T.eq(world.loc.stage, 46100, "warped to the partner")
    T.eq(tr.result, "arrived", "arrived")
end)

T.run("title_screen_leaves_the_load_to_the_join", function()
    local world = make_world({ loc = nil })
    local tr, log = make_travel()
    tr:request({ chapter = 23100, stage = 50100, pos = { x = 1, y = 2, z = 3 }, reason = "join" })
    local now = run(tr, world, 2)
    T.eq(world.armed, 23100, "armed")
    T.eq(world.reloads, 0, "no reload from the title screen")
    T.check(not noted(log, "Load any save"), "the join's own load runs: nothing to ask of the player")
    world:load()
    run(tr, world, 6, nil, now)
    T.eq(world.loc.chapter, 23100, "in the partner's chapter")
    T.eq(world.loc.stage, 50100, "and next to them")
    -- With the join's own load switched off, the player is told what to do.
    local world2 = make_world({ loc = nil })
    local tr2, log2 = make_travel({ auto_load_on_join = false })
    tr2:request({ chapter = 23100, stage = 50100, pos = { x = 1, y = 2, z = 3 }, reason = "join" })
    run(tr2, world2, 2)
    T.check(noted(log2, "Load any save"), "player told what to do")
end)

-- A join in our own chapter, the partner in a part of the map our game has not loaded: the
-- in-game reload loads it and puts us there (a plain warp would land in nothing).
T.run("joining_where_the_partners_area_is_not_loaded_reloads_there", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    function world:stage_loaded(stage) return stage == 40200 end
    local tr, log = make_travel()
    tr:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "join", sync = true })
    local now = run(tr, world, 1)
    T.eq(world.reloads, 1, "reload started")
    T.eq(world.reload_chapter, 21100, "into our (the partner's) chapter")
    T.eq(#world.warps, 0, "no warp into an area that is not there")
    T.check(noted(log, "Loading your partner's area"), "player told")
    now = run(tr, world, 3, nil, now)
    T.eq(tr.state, "chapter", "waits for the reload, though the chapter already matches")
    T.eq(log.syncs, 0, "no world sync before it")
    world.loc = { chapter = 21100, loading = true, playable = false } -- the game leaves the map
    now = run(tr, world, 1, nil, now)
    -- The reload comes back where the partner is (game_world.lua spawn).
    world.loc = { chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, playable = true }
    now = run(tr, world, 3, nil, now)
    T.eq(log.syncs, 1, "then the partner's world")
    tr:sync_done()
    run(tr, world, 3, nil, now)
    T.eq(tr.result, "arrived", "arrived")
    T.eq(#world.warps, 0, "already next to the partner: no warp")
end)

T.run("joining_where_the_partners_area_is_loaded_warps", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    function world:stage_loaded() return true end
    local tr = make_travel()
    tr:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "join" })
    run(tr, world, 6)
    T.eq(world.reloads, 0, "no reload")
    T.eq(tr.result, "arrived", "warped")
    -- Unknown (no stage information): the warp as before.
    local world2 = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    function world2:stage_loaded() return nil end
    local tr2 = make_travel()
    tr2:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "join" })
    run(tr2, world2, 6)
    T.eq(world2.reloads, 0, "no reload when unknown")
    -- Only a join: a manual travel keeps the game's warp.
    local world3 = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    function world3:stage_loaded() return false end
    local tr3 = make_travel()
    tr3:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "manual" })
    run(tr3, world3, 6)
    T.eq(world3.reloads, 0, "no reload for a manual travel")
end)

T.run("a_reload_that_is_refused_or_never_starts_falls_back", function()
    -- Refused (no save to load, switched off): another chapter asks the player.
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true },
        reload_refused = true })
    local tr, log = make_travel()
    tr:request({ chapter = 22200, stage = 46100, pos = { x = 300, y = -7, z = -10 }, reason = "join" })
    run(tr, world, 1)
    T.eq(world.reloads, 1, "tried")
    T.check(noted(log, "Load any save"), "the player is asked to load one")
    T.eq(world.armed, 22200, "the load they make goes into the partner's chapter")
    local off = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    local tr_off = make_travel({ join_reload = false })
    tr_off:request({ chapter = 22200, stage = 46100, pos = { x = 300, y = -7, z = -10 }, reason = "join" })
    run(tr_off, off, 1)
    T.eq(off.reloads, 0, "switched off: no reload")
    -- Started, but the game never leaves: in our chapter, the warp after all.
    local stuck = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    function stuck:stage_loaded() return false end
    local tr2 = make_travel()
    tr2:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "join" })
    local now = run(tr2, stuck, 20)
    T.eq(tr2.state, "chapter", "still waiting for it")
    run(tr2, stuck, 30, nil, now)
    T.eq(tr2.result, "arrived", "gave up waiting, then warped")
    -- The load reports it gave up: no waiting at all.
    local failed = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    function failed:stage_loaded() return false end
    function failed:reload_failed() return true end
    local tr3 = make_travel()
    tr3:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "join" })
    run(tr3, failed, 5)
    T.eq(tr3.result, "arrived", "warped at once")
end)

T.run("playing_in_the_wrong_chapter_offers_one_reload", function()
    local world = make_world({ loc = { chapter = 21100, loading = true, playable = false } })
    local tr = make_travel()
    tr:request({ chapter = 22100, stage = 45200, pos = { x = 0, y = 0, z = 0 }, reason = "join" })
    local now = run(tr, world, 1)
    T.eq(world.reloads, 0, "not while loading")
    world.loc = { chapter = 21100, stage = 1, pos = { x = 0, y = 0, z = 0 }, playable = true }
    run(tr, world, 2, nil, now)
    T.eq(world.reloads, 1, "one reload once playable")
end)

T.run("follow_tracks_the_partner", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    local tr = make_travel()
    tr:request({ chapter = 21100, stage = 40200, pos = { x = 10, y = 0, z = 0 }, reason = "join", follow = true })
    run(tr, world, 5, { chapter = 21100, stage = 40200, pos = { x = 80, y = 0, z = 0 } })
    T.near(world.loc.pos.x, 80, 1e-6, "went where the partner is now")
end)

T.run("refused_warps_retry_then_fail", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true },
        refuse = 1 })
    local tr = make_travel()
    tr:request({ chapter = 21100, stage = 40200, pos = { x = 30, y = 0, z = 0 } })
    run(tr, world, 10)
    T.eq(tr.result, "arrived", "second attempt worked")
    local stuck = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true },
        no_arrive = true })
    local tr2, log2 = make_travel()
    tr2:request({ chapter = 21100, stage = 40200, pos = { x = 30, y = 0, z = 0 } })
    run(tr2, stuck, 40)
    T.eq(tr2:busy(), false, "gave up")
    T.check(tr2.result ~= "arrived", "reported failure: " .. tostring(tr2.result))
    T.check(noted(log2, "Could not reach partner"), "player told")
    T.eq(#stuck.warps, 3, "three attempts")
end)

-- The bell in the village (cutscene that ends chapter 1-1): a client that watched it from far
-- away was sent to where it took place - in the middle of its own chapter change.
T.run("nothing_moves_while_the_game_changes_chapter", function()
    local world = make_world({ loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, loading = true,
        playable = false, transition = true } })
    local tr = make_travel()
    tr:request({ chapter = 21100, stage = 43300, pos = { x = 48, y = 2, z = -55 }, reason = "join" })
    local now = run(tr, world, 5)
    T.eq(tr.state, "start", "waits")
    T.eq(#world.preloads + #world.warps, 0, "no stage requested, no warp")
    T.eq(world.armed, nil, "no chapter switch armed")
    T.eq(world.reloads, 0, "no reload")
    world.loc = { chapter = 21100, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true }
    run(tr, world, 6, nil, now)
    T.eq(tr.result, "arrived", "goes once the game plays again")
end)

T.run("a_cutscene_join_never_switches_chapter", function()
    -- The cutscene took place in 21100 and changed our game to 21200 when it ended.
    local world = make_world({ loc = { chapter = 21200, stage = 40200, pos = { x = 0, y = 0, z = 0 }, playable = true } })
    local tr, log = make_travel()
    tr:request({ chapter = 21100, stage = 40200, pos = { x = 50, y = 0, z = 0 }, reason = "cutscene" })
    run(tr, world, 3)
    T.eq(tr:busy(), false, "dropped")
    T.eq(tr.result, "chapter changed", "why")
    T.eq(world.armed, nil, "never armed")
    T.eq(world.reloads, 0, "never a game over to reload the old chapter")
    T.eq(#world.warps, 0, "no warp")
    T.eq(#log.notes, 0, "nothing to tell")
end)

T.run("requests_without_a_destination_are_refused", function()
    local tr = make_travel()
    T.eq(tr:request({ reason = "join" }), false, "nothing to go to")
    T.eq(tr:busy(), false, "idle")
end)

T.finish()
