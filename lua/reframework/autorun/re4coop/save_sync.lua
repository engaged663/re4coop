-- Saves for both players, and joining a game in progress from the title screen.
--
-- Saving: every save either game makes (an autosave at a checkpoint or at the end of a
-- chapter, or the player's own save at a typewriter) is reported to the partner (SAVE), whose
-- game then saves too:
--   * the host into its autosave slot (0);
--   * the client into its co-op slot (setting `coop_save_slot`, a normal manual slot, 20 by
--     default, so it also shows in the Load Game list).
-- While connected the client's own autosaves go to the co-op slot as well: its single-player
-- autosave stays as it was, and two copies of the game on one PC (which share their saves)
-- never write the same file at the same moment. A save the player makes at a typewriter goes
-- where they chose; the client's is then also written to its co-op slot, so that slot always
-- holds its latest progress with the host. A save already made by both (both players walked through the same
-- autosave point, or both changed chapter) is not made twice: a report within DEDUPE seconds
-- of our own save is that same save. A partner's save waits until our game can save (in game,
-- no cutscene or loading screen, the save system idle; the client also waits until it holds
-- the host's world), for up to WAIT seconds.
--
-- Joining from the title screen or the main menu (client): the game asks the player to load a
-- save or start a new one. Instead the mod uses the game's own "game intent" path (what a
-- console uses to start an activity from the system menu): the menus are skipped and
-- Continue runs on its own. Continue loads the co-op slot when it holds a save (the save the
-- client made in its last session with a host), else the latest save, and the chapter switch
-- (game_world.lua) puts it into the host's chapter; the game then loads the host's part of the
-- map and the client appears at the host's place (game_world.lua spawn, armed by the session),
-- takes over the host's world and is next to the host. Without any save, a new game starts at
-- the beginning of the host's chapter from the main menu, and comes back at the host's place
-- the same way. Continue after a game over also loads the newest save:
-- for a connected client whose co-op slot holds this session's progress, that slot (two copies
-- of the game on one PC share their saves, and the newest may be the host's).
--
-- Games started from the lobby (lobby.lua, 0.11) play in a co-op save of their own: the host's
-- chosen co-op file (a slot of its own, set_host_slot) takes the host's autosaves and the
-- client's saves made for it, exactly as the client's co-op slot does for the client; the
-- single-player autosave stays as it was. The lobby also loads a given slot through Continue
-- (request_load).
--
-- Game contract:
--   game:save_can() -> true | false, why       our game can start a save now
--   game:save_now(slot) -> true | nil, why     starts a save through the game's own save flow
--   game:save_exists(slot) -> bool
--   game:any_save() -> bool                    there is a main campaign save to load

local SaveSync = {}
SaveSync.__index = SaveSync

SaveSync.AUTOSAVE_SLOT = 0   -- share.AppSaveSlot.Campaign1001_Auto
SaveSync.FIRST_SLOT = 1      -- Campaign1001_GameSaveStart
SaveSync.LAST_SLOT = 20      -- Campaign1001_GameSaveEnd (the Load Game list)
SaveSync.CAMPAIGN_LIMIT = 99 -- Campaign1001_GameSaveLimit: slots past it belong to other modes

local DEDUPE = 10.0             -- seconds: a save this close to another one is the same save
local WAIT = 90.0               -- seconds a partner's save may wait for our game to be able to save
local RETRY = 1.0               -- seconds between attempts while it waits
local WAIT_NOTICE = 5.0         -- a partner's save still waiting after this long is announced
local JOIN_LOAD_TIMEOUT = 30.0  -- seconds still in the menus after asking for the load = it did not happen

-- opts: { protocol, settings, send(bytes, reliable), notify(text, kind), partner_name(),
--         role() -> "host" | "client" | "none", active() -> partner connected and compatible }
function SaveSync.new(opts)
    local self = setmetatable({}, SaveSync)
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.notify = opts.notify or function() end
    self.partner_name = opts.partner_name or function() return "partner" end
    self.role = opts.role or function() return "none" end
    self.active = opts.active or function() return false end
    self.counters = { own = 0, redirected = 0, sent = 0, received = 0, mirrored = 0, same = 0, given_up = 0,
        copies = 0, join_loads = 0 }
    self:reset()
    return self
end

-- A new partner (or none): nothing of the previous one's is pending.
function SaveSync:reset()
    self.pending = nil -- { since, kind, next_try, why, noticed }: the partner saved, we have not yet
    self.copy = nil    -- { since, next_try, why }: the client saved elsewhere, its co-op slot follows
    self.join = nil    -- { at, coop, failed } | { at, new = true } | { none = true }: the load asked for while joining
    self.title_told = nil -- the player was told the title screen waits for a button (no save to load)
    -- The co-op slot (client's, or the host's lobby file) holds this session's progress.
    self.coop_current = self.host_slot ~= nil
    self.forced = nil  -- { slot, at }: the lobby asked Continue to load this slot
end

-- Host: the slot of the co-op file the lobby started (nil: saves go where the game puts them).
function SaveSync:set_host_slot(slot)
    self.host_slot = slot
    if slot ~= nil then self.coop_current = true end
end

-- The lobby asks the game's Continue to load `slot` (see continue_slot).
function SaveSync:request_load(slot, now)
    self.forced = { slot = slot, at = now }
end

-- Our own co-op slot in this session: the client's, or the host's lobby file (nil without one).
function SaveSync:my_coop_slot()
    if self.role() == "client" then return self:coop_slot() end
    if self.role() == "host" then return self.host_slot end
    return nil
end

function SaveSync:enabled()
    return self.settings.sync_saves ~= false
end

function SaveSync:coop_slot()
    local s = math.floor(tonumber(self.settings.coop_save_slot) or SaveSync.LAST_SLOT)
    if s < SaveSync.FIRST_SLOT or s > SaveSync.LAST_SLOT then s = SaveSync.LAST_SLOT end
    return s
end

local function slot_text(slot)
    if slot == SaveSync.AUTOSAVE_SLOT then return "autosave" end
    return ("slot %d"):format(slot)
end

-------------------------------------------------------------------------------
-- Saves our game makes
-------------------------------------------------------------------------------

-- The slot a save our game is starting goes to (called from the game's save flow): while
-- connected, the client's autosaves go to its co-op slot.
function SaveSync:redirect(slot)
    if slot ~= SaveSync.AUTOSAVE_SLOT then return slot end
    if self.role() == "client" and self.active() and self:enabled() then
        self.counters.redirected = self.counters.redirected + 1
        return self:coop_slot()
    end
    -- A host playing a lobby game: its co-op file takes its autosaves (also with the partner gone).
    if self.role() == "host" and self.host_slot ~= nil then
        self.counters.redirected = self.counters.redirected + 1
        return self.host_slot
    end
    return slot
end

-- Our game started a save into `slot` (after redirect). from_slot: the slot the game asked
-- for; mirrored: the save is the one we made for the partner's (never reported back).
function SaveSync:on_local_save(slot, now, mirrored, from_slot)
    if slot == nil or slot < 0 or slot > SaveSync.CAMPAIGN_LIMIT then return end -- not the main story
    self.last_save, self.last_slot = now, slot
    local mine = self:my_coop_slot()
    if mine ~= nil and slot == mine and (self.active() or self.role() == "host") then self.coop_current = true end
    if mirrored then
        self.counters.mirrored = self.counters.mirrored + 1
        return
    end
    self.counters.own = self.counters.own + 1
    if self.pending ~= nil and now - self.pending.since < DEDUPE then
        -- The partner's save we were waiting for, made by our own game anyway.
        self.pending = nil
        self.counters.same = self.counters.same + 1
    end
    if not self.active() or not self:enabled() then return end
    local auto = (from_slot or slot) == SaveSync.AUTOSAVE_SLOT
    self.send(self.P.encode_save({ kind = auto and self.P.SAVE_KIND.AUTO or self.P.SAVE_KIND.MANUAL }), true)
    self.counters.sent = self.counters.sent + 1
    if mine ~= nil and slot ~= mine then
        self.copy = { since = now, next_try = now } -- a typewriter save: the co-op slot follows
    end
end

-------------------------------------------------------------------------------
-- The partner's saves
-------------------------------------------------------------------------------

function SaveSync:on_message(m, now)
    if m.type ~= self.P.T.SAVE then return false end
    self.counters.received = self.counters.received + 1
    if not self:enabled() then return true end
    if self.last_save ~= nil and now - self.last_save < DEDUPE then
        self.counters.same = self.counters.same + 1 -- our game just saved too
        return true
    end
    self.pending = { since = now, kind = m.kind, next_try = now }
    return true
end

-- The slot our game saves into for the partner.
function SaveSync:mirror_slot()
    if self.role() == "host" then return self.host_slot or SaveSync.AUTOSAVE_SLOT end
    return self:coop_slot()
end

-- One attempt at a save into our mirror slot for `entry` (pending or copy): true once made.
local function try_save(self, now, game, ready, entry)
    if not ready then
        entry.why = "not in game"
        return false
    end
    if game == nil or game.save_now == nil or now < entry.next_try then return false end
    entry.next_try = now + RETRY
    local can, why = true, nil
    if game.save_can ~= nil then can, why = game:save_can() end
    if not can then
        entry.why = why or "the game cannot save now"
        return false
    end
    local ok, err = game:save_now(self:mirror_slot())
    if not ok then
        entry.why = err or "the save did not start"
        return false
    end
    -- That save holds our latest state: it serves both the partner's save and the copy.
    self.pending, self.copy = nil, nil
    return true
end

-- ready: our game is in a state to save (in game, no cutscene or loading screen; the client
-- holds the host's world).
function SaveSync:tick(now, game, ready)
    if not self:enabled() then
        self.pending, self.copy = nil, nil
        return
    end
    local p = self.pending
    if p ~= nil then
        if now - p.since > WAIT then
            self.pending = nil
            self.counters.given_up = self.counters.given_up + 1
            self.notify(("%s saved, but your game could not save with them (%s)"):format(self.partner_name(),
                p.why or "not in game"), "warn")
        else
            if not p.noticed and now - p.since >= WAIT_NOTICE then
                p.noticed = true
                self.notify(("%s saved - your game saves as soon as it can"):format(self.partner_name()), "info")
            end
            if try_save(self, now, game, ready, p) then
                local slot = self:mirror_slot()
                self.notify(("Saved with %s (%s)"):format(self.partner_name(), slot_text(slot)), "good")
            end
        end
    end
    local c = self.copy
    if c ~= nil then
        if now - c.since > WAIT then
            self.copy = nil
            self.counters.given_up = self.counters.given_up + 1
        elseif try_save(self, now, game, ready, c) then
            self.counters.copies = self.counters.copies + 1
            self.notify(("Your save is in your co-op slot too (slot %d)"):format(self:mirror_slot()), "info")
        end
    end
end

-------------------------------------------------------------------------------
-- Joining from the title screen / main menu
-------------------------------------------------------------------------------

-- Called every frame the game shows its title screen or main menu. ctx = { joining (the
-- client is joining the host), partner_in_game, where ("title" | "menu"), can_start_new (the
-- main menu can start a new game in the host's chapter) }. Returns, once, what the game must do
-- now: "continue" (load a save) or "new" (there is none: a new game); nil otherwise.
function SaveSync:menu_tick(now, ctx, game)
    if self.role() ~= "client" or not ctx.joining or self.settings.auto_load_on_join == false then return nil end
    local j = self.join
    if j == nil then
        if not ctx.partner_in_game then return nil end
        if game == nil or game.any_save == nil or not game:any_save() then
            if ctx.can_start_new then
                self.join = { at = now, new = true }
                self.counters.join_loads = self.counters.join_loads + 1
                self.notify(("You have no saved game: starting a new one in %s's chapter..."):format(self.partner_name()),
                    "info")
                return "new"
            end
            if ctx.where == "title" then
                -- The main menu can start one: the title screen only waits for a button.
                if not self.title_told then
                    self.title_told = true
                    self.notify(("You have no saved game: press a button - a new game in %s's chapter starts from the main menu")
                        :format(self.partner_name()), "info")
                end
                return nil
            end
            self.join = { none = true }
            self.notify(("You have no saved game to load: start one (New Game), then load it to join %s")
                :format(self.partner_name()), "warn")
            return nil
        end
        local coop = game.save_exists ~= nil and game:save_exists(self:coop_slot()) or false
        self.join = { at = now, coop = coop }
        self.coop_current = coop
        self.counters.join_loads = self.counters.join_loads + 1
        if coop then
            self.notify(("Loading your co-op save (slot %d) into %s's game..."):format(self:coop_slot(),
                self.partner_name()), "info")
        else
            self.notify(("Loading your latest save into %s's game..."):format(self.partner_name()), "info")
        end
        return "continue"
    end
    if j.at ~= nil and not j.new and not j.failed and now - j.at > JOIN_LOAD_TIMEOUT then
        j.failed = true
        self.notify(("The save did not load - load one yourself (Continue or Load Game) to join %s")
            :format(self.partner_name()), "warn")
    end
    return nil
end

-- The slot Continue loads instead of the newest save (the game's own choice, nil): the co-op
-- slot while the load we asked for on joining runs, and, for a connected client whose co-op
-- slot holds this session's progress, after a game over too (two copies of the game on one PC
-- share their saves: the newest save may be the host's).
function SaveSync:continue_slot(now)
    local f = self.forced
    if f ~= nil and now - f.at <= 2 * JOIN_LOAD_TIMEOUT then return f.slot end
    if self.host_slot ~= nil and self.coop_current and self.role() == "host" then return self.host_slot end
    local j = self.join
    if j ~= nil and j.coop and j.at ~= nil and now - j.at <= 2 * JOIN_LOAD_TIMEOUT then return self:coop_slot() end
    if self.coop_current and self.role() == "client" and self.active() and self:enabled() then
        return self:coop_slot()
    end
    return nil
end

function SaveSync:summary()
    return { counters = self.counters, queued = (self.pending ~= nil and 1 or 0) + (self.copy ~= nil and 1 or 0),
        coop_slot = self:my_coop_slot() or self:coop_slot(), host_slot = self.host_slot }
end

return SaveSync
