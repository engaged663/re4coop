-- Travel: brings the local player to the partner, wherever they are.
--   * Same chapter: preload the partner's stage, then warp next to them (a live warp, the
--     same technique RE4 uses internally: CharacterManager.requestWarp with a StageIdentifier).
--   * Other chapter (or still on the title screen): the next save load is redirected into
--     the partner's chapter. In game, the load starts right away (the game's own Load Game,
--     setting join_reload) and comes back at the partner's place; on the title screen or in
--     the menus the join's own load does it (save_sync.lua). Once the chapter is running, the
--     world state is synchronised and the warp follows (if still needed).
--   * Joining in the same chapter while the partner's part of the map is not loaded here: the
--     same reload, so the player never lands in an area that is not there.
--
-- Adapter contract (world):
--   world:location() -> { chapter, stage, pos, yaw, loading=bool, playable=bool, transition=bool } | nil
--     (transition: the game is changing chapter, over or loading - a travel waits it out)
--   world:preload_stage(stage) -> bool
--   world:warp(stage, pos, yaw) -> bool
--   world:arm_chapter_switch(chapter) -> bool
--   world:disarm_chapter_switch()
--   world:trigger_reload(chapter) -> true | false, why   (in game: load into `chapter` at the partner's place)
--   world:reload_failed() -> bool                          (optional: that load gave up)
--   world:stage_loaded(stage) -> bool | nil                (optional: the stage is part of our loaded map)

local Travel = {}
Travel.__index = Travel

local ARRIVED = 6.0          -- metres from the target that count as "there"
local PRELOAD_TIME = 1.5     -- seconds to keep preloading another stage before warping
local PRELOAD_REPEAT = 0.5   -- seconds between repeated preload requests
local VERIFY_TIME = 6.0
local SETTLE_TIME = 2.0      -- after a load, wait this long before syncing/warping
local SYNC_TIMEOUT = 15.0
local CHAPTER_TIMEOUT = 600.0
local RELOAD_START_TIMEOUT = 35.0 -- seconds an in-game reload may take to leave the game
local MAX_TRIES = 3
local LOAD_YOURSELF = "Load any save (or press Continue) to join your partner's chapter"

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function known(v)
    return v ~= nil and v >= 0
end

-- opts: { settings, log(fmt, ...), notify(text, kind), on_sync(target) }
function Travel.new(opts)
    local self = setmetatable({}, Travel)
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
    self.notify = opts.notify or function() end
    self.on_sync = opts.on_sync or function() end
    self.state = "idle"
    self.target = nil
    self.result = nil
    return self
end

function Travel:busy()
    return self.state ~= "idle"
end

-- target = { chapter, stage, pos={x,y,z}, yaw, reason="join"|"manual"|"cutscene",
--            sync=<bool: run on_sync before warping>, follow=<bool: chase the partner> }
function Travel:request(target)
    if target == nil or (target.pos == nil and not known(target.chapter)) then
        return false
    end
    self.target = target
    self.state = "start"
    self.tries = 0
    self.since = nil
    self.sync_pending = false
    self.sync_started = false
    self.arrived_at = nil
    self.armed = false
    self.armed_chapter = nil
    self.reload_tried = false
    self.wait_reload = nil
    self.result = nil
    return true
end

-- In game: reloads our game into the partner's chapter, at the partner's place (the world's
-- in-game Load Game). true once it started.
function Travel:reload(now, world, t)
    if self.settings.join_reload == false then return false end
    local ok, why = world:trigger_reload(known(t.chapter) and t.chapter or nil)
    if not ok then
        self.log("reload into the partner's game refused: %s", tostring(why))
        return false
    end
    if known(t.chapter) then
        self.armed = true
        self.armed_chapter = t.chapter
    end
    self.reload_tried = true
    self.wait_reload = { since = now, left = false }
    self.notify("Loading your partner's area - you will appear next to them", "info")
    self:set_state("chapter", now)
    return true
end

function Travel:cancel(why)
    if self.state ~= "idle" then
        self.result = why or "cancelled"
        self.log("travel cancelled: %s", self.result)
    end
    self.state = "idle"
    self.target = nil
    self.armed = false
end

function Travel:sync_done()
    self.sync_pending = false
end

function Travel:set_state(state, now)
    self.state = state
    self.since = now
end

function Travel:fail(why, world)
    self.result = why
    self.notify("Could not reach partner: " .. why, "error")
    if self.armed and world ~= nil then world:disarm_chapter_switch() end
    self.armed = false
    self.state = "idle"
    self.target = nil
end

local function landing(pos)
    return { x = pos.x, y = pos.y + 0.1, z = pos.z - 0.8 }
end

-- partner = { chapter, stage, pos, yaw } (latest known; used when target.follow is set)
function Travel:tick(now, world, partner)
    if self.state == "idle" then return end
    local t = self.target
    if t.follow and partner ~= nil and partner.pos ~= nil then
        t.pos, t.stage, t.yaw = partner.pos, partner.stage, partner.yaw
        if known(partner.chapter) then t.chapter = partner.chapter end
    end
    local loc = world:location()
    self.since = self.since or now

    if self.state == "start" then
        -- Our game is changing chapter or reloading: decide once it plays again (its chapter is
        -- the one it is changing to only then).
        if loc ~= nil and loc.transition then return end
        local in_game = loc ~= nil and loc.playable and not loc.loading
        -- A cutscene's join is a walk to where it took place, never a chapter switch: a
        -- cutscene that ends a chapter has already taken both games to the next one.
        if t.reason == "cutscene" and known(t.chapter) and loc ~= nil and known(loc.chapter) and loc.chapter ~= t.chapter then
            self.result = "chapter changed"
            self.state = "idle"
            self.target = nil
            return
        end
        if known(t.chapter) and (loc == nil or (known(loc.chapter) and loc.chapter ~= t.chapter)) then
            if not world:arm_chapter_switch(t.chapter) then
                return self:fail("chapter switching is not available", world)
            end
            self.armed = true
            self.armed_chapter = t.chapter
            self.reload_tried = in_game
            if in_game then
                if self:reload(now, world, t) then return end
                self.notify(LOAD_YOURSELF, "warn")
            elseif self.settings.auto_load_on_join == false then
                -- In the menus the join loads a save on its own (save_sync.lua), unless switched off.
                self.notify(LOAD_YOURSELF, "warn")
            end
            return self:set_state("chapter", now)
        end
        if not in_game then return end
        -- Joining in our chapter, but the partner's part of the map is not loaded here: load it.
        if t.reason == "join" and known(t.stage) and loc.stage ~= t.stage and world.stage_loaded ~= nil
            and world:stage_loaded(t.stage) == false and self:reload(now, world, t) then
            return
        end
        return self:set_state(t.sync and "sync_wait" or "preload", now)
    end

    if self.state == "chapter" then
        if now - self.since > CHAPTER_TIMEOUT then
            return self:fail("the chapter was not loaded", world)
        end
        -- Our in-game reload: wait until the game has left the map, then for it to play again.
        local w = self.wait_reload
        if w ~= nil and not w.left then
            if loc == nil or loc.loading or loc.transition then
                w.left = true
            elseif now - w.since > RELOAD_START_TIMEOUT or (world.reload_failed ~= nil and world:reload_failed()) then
                self.wait_reload = nil
                self.log("the reload into the partner's game did not start")
                if known(t.chapter) and known(loc.chapter) and loc.chapter ~= t.chapter then
                    self.notify(LOAD_YOURSELF, "warn")
                end
            else
                return
            end
        end
        local in_game = loc ~= nil and loc.playable and not loc.loading
        if in_game and (not known(t.chapter) or loc.chapter == t.chapter) then
            if self.armed then world:disarm_chapter_switch() end
            self.armed = false
            self.wait_reload = nil
            self.arrived_at = self.arrived_at or now
            if now - self.arrived_at >= SETTLE_TIME then
                self.arrived_at = nil
                return self:set_state(t.sync and "sync_wait" or "preload", now)
            end
            return
        end
        self.arrived_at = nil
        if in_game then
            -- Playing, but still in another chapter: (re)arm and reload once.
            if self.armed_chapter ~= t.chapter then
                self.armed = world:arm_chapter_switch(t.chapter)
                self.armed_chapter = t.chapter
            end
            if not self.reload_tried then
                self.reload_tried = true
                if not self:reload(now, world, t) then self.notify(LOAD_YOURSELF, "warn") end
            end
        end
        return
    end

    if loc == nil or loc.loading or not loc.playable then
        return -- wait for the game to be playable again
    end

    if self.state == "sync_wait" then
        if not self.sync_started then
            self.sync_started = true
            self.sync_pending = true
            self.on_sync(t)
            return
        end
        if not self.sync_pending or now - self.since > SYNC_TIMEOUT then
            self.sync_started = false
            self.sync_pending = false
            return self:set_state("preload", now)
        end
        return
    end

    if t.pos == nil then
        return self:fail("partner position unknown", world)
    end

    if self.state == "preload" then
        local same_stage = not known(t.stage) or loc.stage == t.stage
        if same_stage and loc.pos ~= nil and dist(loc.pos, t.pos) <= ARRIVED then
            return self:finish(now)
        end
        if not same_stage then
            if (self.last_preload or -math.huge) + PRELOAD_REPEAT <= now then
                self.last_preload = now
                world:preload_stage(t.stage)
            end
            if now - self.since < PRELOAD_TIME then return end
        end
        return self:set_state("warp", now)
    end

    if self.state == "warp" then
        if world:warp(t.stage, landing(t.pos), t.yaw) then
            return self:set_state("verify", now)
        end
        self.tries = self.tries + 1
        if self.tries >= MAX_TRIES then return self:fail("the warp was refused", world) end
        return self:set_state("preload", now)
    end

    if self.state == "verify" then
        local same_stage = not known(t.stage) or not known(loc.stage) or loc.stage == t.stage
        if same_stage and loc.pos ~= nil and dist(loc.pos, t.pos) <= ARRIVED then
            return self:finish(now)
        end
        if now - self.since > VERIFY_TIME then
            self.tries = self.tries + 1
            if self.tries >= MAX_TRIES then return self:fail("the warp did not arrive", world) end
            return self:set_state("preload", now)
        end
    end
end

function Travel:finish(now)
    local reason = self.target and self.target.reason
    self.result = "arrived"
    self.state = "idle"
    self.target = nil
    if reason ~= "cutscene" then
        self.notify("Arrived next to your partner", "good")
    end
end

function Travel:status()
    return { state = self.state, result = self.result, reason = self.target and self.target.reason }
end

return Travel
