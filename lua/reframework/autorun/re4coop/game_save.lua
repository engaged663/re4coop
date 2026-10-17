-- RE4 (2023) adapter, part 4: saving and loading. Installed into game.lua's Game class
-- (require("re4coop.game_save").install(Game, helpers)); save_sync.lua talks to the game only
-- through these methods.
--
-- How the game does it (re4.exe, docs/RESEARCH.md 3.15):
--   * Every game save goes through chainsaw.SaveFlowController.start(slotId, args): the
--     autosave points (AutoSaveSetting.triggerProcess, slot 0), the chapter-end autosave
--     (GameStateInGameChapterChange.startAutoSave) and the typewriter's save menu
--     (SaveLoadMenuGuiBehavior, the chosen slot). share.SaveDataManager
--     .requestStartSaveGameDataFlow(slotId, args) is a jump to it. The flow queues the request,
--     writes the slot, then records the slot's description (chapter, stage, difficulty...)
--     for the Load Game list and writes the system save. Slots: 0 = autosave, 1-20 = the list.
--   * Continue (main menu, and after a game over) loads SaveLoadMenuGuiManager.findContinueSave(): the newest of
--     slots 0-20 as a SaveSlotInfoDetail; getSaveSlotInfoDetail(slot) builds the same for any
--     slot (IsEmpty when it holds no save).
--   * chainsaw.UDSManagerApp.<_IsRequestGameIntent> with RequestGameIntentMode MainGame (0):
--     GameStateTitle.update skips to the main menu (skipStateGameIntent) and
--     GameStateMainMenu.update, from any menu, goes to Continue (onGameIntentEnterInMainMenu
--     -> phase CheckGameClearData) without waiting for its windows to close; Decided resets
--     the request (resetRequestGameIntent).
--   * Loading in game (the pause menu's Load Game, docs/RESEARCH.md 3.34): the save is read with
--     SaveDataManager.setPlayLoadData(slot == 0, slot) + enqueueLoadRequest(slot, args) - what the
--     main menu's Continue does - and waits as LoadedGamedataApplyable; then
--     InGameMenuGuiBehavior's load callback leaves the game: HighwayGuiManager
--     .setFixInGameStateExit(), ClapperboardMediator.clearRequestTimeline() and
--     MainModeManager.requestToChangeGameState(GameStateInGameCleanup, Argument { NextState =
--     GameStateIngameSetup }). The cleanup unloads the map and hands over to the in-game setup,
--     which applies the loaded save and builds the campaign jump (game_world.lua spawn).

local Guard = require("re4coop.hookguard")
local M = {}

local SAVE_MANAGER = "share.SaveDataManager"
local SAVE_ARGS = "chainsaw.ChainsawGameSaveRequestArgs"
local LOAD_ARGS = "share.GameLoadRequestArgs"
local UDS = "chainsaw.UDSManagerApp"
local MAIN_MODE = "share.MainModeManager"
local HIGHWAY = "chainsaw.HighwayGuiManager"
local CLAPPERBOARD = "chainsaw.ClapperboardMediator"
local CLEANUP = "chainsaw.GameStateInGameCleanup"
local CLEANUP_ARG = "chainsaw.GameStateInGameCleanup.Argument"
local SETUP = "chainsaw.GameStateIngameSetup"
local INTENT_FIELD = "<_IsRequestGameIntent>k__BackingField"
local INTENT_MAIN_GAME = 0 -- chainsaw.UDSManagerApp.GameIntentMode.MainGame
M.LIST_SLOTS = 20          -- share.AppSaveSlot.Campaign1001_GameSaveEnd
M.LOAD_TIMEOUT = 30.0      -- seconds an in-game load may take to read the save
local LOAD_PICKUP = 0.5    -- seconds the save system may take to start on a queued load
local DEFAULT_DIFFICULTY = 10 -- what the pause menu's cleanup argument carries (unused unless changed)

function M.install(Game, H)
    local singleton, find_type = H.singleton, H.find_type

    local function managed(v)
        if v == nil then return nil end
        if type(v) == "table" then return v end -- already an object (tests)
        local ok, o = pcall(sdk.to_managed_object, v)
        if ok and o ~= nil and (type(o) == "table" or type(o) == "userdata") then return o end
        return nil
    end

    -- An Int32 hook argument.
    local function int_arg(v)
        local ok, n = pcall(sdk.to_int64, v)
        if not ok or n == nil then return nil end
        n = n & 0xFFFFFFFF
        if n >= 0x80000000 then n = n - 0x100000000 end
        return n
    end

    local function ptr(v)
        if sdk.to_ptr ~= nil then return sdk.to_ptr(v) end
        return v
    end

    -- h = { redirect(slot) -> slot, on_save(slot, mirrored, from_slot), continue_slot() -> slot | nil,
    --       on_menu(where) -> bool (where: "title" | "menu") }
    function Game:install_save_hooks(h)
        self.save_hooks = h
        self.save_counters = { saves = 0, redirected = 0, continue_swaps = 0, intents = 0, menu_frames = 0 }
        if type(sdk) ~= "table" or sdk.hook == nil then
            self:cap("save_sync", false, "sdk.hook unavailable")
            self:cap("join_load", false, "sdk.hook unavailable")
            return false
        end
        -- 1. Every save: report it, and send the client's autosaves to its co-op slot.
        local flow = find_type("chainsaw.SaveFlowController")
        local start_m = flow and flow:get_method("start")
        local saves_ok = start_m ~= nil and pcall(Guard.hook, start_m, function(args)
            local slot = int_arg(args[3])
            if slot == nil then return end
            local mirrored = self.save_mirroring == true
            local to = slot
            if not mirrored then
                local ok, r = pcall(h.redirect, slot)
                if ok and type(r) == "number" and r ~= slot then
                    to = r
                    args[3] = ptr(r)
                    self.save_counters.redirected = self.save_counters.redirected + 1
                end
            end
            self.save_counters.saves = self.save_counters.saves + 1
            pcall(h.on_save, to, mirrored, slot)
        end, function(retval) return retval end)
        self:cap("save_sync", saves_ok, saves_ok and "SaveFlowController.start hooked" or "SaveFlowController.start not found")

        -- 2. Joining from the menus: Continue loads the co-op slot; the menus run Continue.
        local done = {}
        local menu_mgr = find_type("chainsaw.SaveLoadMenuGuiManager")
        local cont_m = menu_mgr and menu_mgr:get_method("findContinueSave")
        if cont_m ~= nil and pcall(Guard.hook, cont_m, function(args)
            self.continue_mgr = managed(args[2])
        end, function(retval)
            local ok, swapped = pcall(self.swap_continue_save, self)
            if ok and swapped ~= nil then return ptr(swapped) end
            return retval
        end) then done[#done + 1] = "continue" end
        for _, s in ipairs({ { "chainsaw.GameStateTitle", "title" }, { "chainsaw.GameStateMainMenu", "menu" } }) do
            local td = find_type(s[1])
            local upd = td and td:get_method("update")
            local where = s[2]
            if upd ~= nil and pcall(Guard.hook, upd, function(args)
                self.save_counters.menu_frames = self.save_counters.menu_frames + 1
                self.menu_seen = where
                self.menu_seen_time = self.clock()
                if where == "menu" then
                    -- The main menu's state object: the lobby starts games through it (game_menu.lua).
                    self.main_menu_state = managed(args[2]) or self.main_menu_state
                    self.menu_state_seen = self.menu_seen_time
                end
                local ok, want = pcall(h.on_menu, where)
                if ok and want then self:request_continue() end
            end, function(retval) return retval end) then done[#done + 1] = where end
        end
        local load_ok = #done == 3 and find_type(UDS) ~= nil
        self:cap("join_load", load_ok, load_ok and "findContinueSave / title / main menu hooked"
            or ("only " .. table.concat(done, ", ")))
        -- 3. Loading in game (joining or following the host from the middle of a game).
        local sdm_t = find_type(SAVE_MANAGER)
        local ingame_ok = sdm_t ~= nil and sdm_t:get_method("enqueueLoadRequest") ~= nil
            and find_type(LOAD_ARGS) ~= nil and find_type(CLEANUP_ARG) ~= nil and find_type(SETUP) ~= nil
            and find_type(MAIN_MODE) ~= nil
        self:cap("ingame_load", ingame_ok, ingame_ok and "Load Game in game (in-game cleanup -> setup)"
            or "SaveDataManager.enqueueLoadRequest / GameStateInGameCleanup not found")
        return saves_ok
    end

    -- findContinueSave's result, replaced by the co-op slot's save while the join load runs.
    function Game:swap_continue_save()
        local h = self.save_hooks
        local slot = h and h.continue_slot and h.continue_slot() or nil
        local mgr = self.continue_mgr
        if slot == nil or mgr == nil then return nil end
        local detail = self:call(mgr, "getSaveSlotInfoDetail", slot)
        if detail == nil then return nil end
        local empty = detail.get_field and detail:get_field("<IsEmpty>k__BackingField")
        if empty == nil then empty = self:call(detail, "get_IsEmpty") end
        local info = detail.get_field and detail:get_field("<Info>k__BackingField")
        if empty == true or info == nil then return nil end
        self.continue_detail = detail -- keeps it alive while the game uses it
        self.save_counters.continue_swaps = self.save_counters.continue_swaps + 1
        return detail
    end

    -- Asks the menus to run Continue (the game's own "game intent" path).
    function Game:request_continue()
        local uds = singleton(UDS)
        if uds == nil then return false end
        self:call(uds, "set_RequestGameIntentMode", INTENT_MAIN_GAME)
        if self:call(uds, "set__IsRequestGameIntent", true) == nil then
            pcall(uds.set_field, uds, INTENT_FIELD, true)
        end
        local on = self:call(uds, "get_IsRequestGameIntent")
        if on == nil and uds.get_field then on = uds:get_field(INTENT_FIELD) end
        if on == true then self.save_counters.intents = self.save_counters.intents + 1 end
        self.perf:crumb("save.request_continue", tostring(on), true)
        return on == true
    end

    -- Our game can start a save now: in normal play (never in the middle of a chapter change,
    -- whose own autosave and loading wait for the save system), the save system idle and
    -- nothing excluding saving.
    function Game:save_can()
        if self.in_transition ~= nil and self:in_transition() then return false, "the game is changing chapter or loading" end
        local sdm = singleton(SAVE_MANAGER)
        if sdm == nil then return false, "no save system" end
        if self:call(sdm, "get_IsBusy") == true then return false, "the game is saving or loading" end
        if self:call(sdm, "checkExcludeGameSave") == true then return false, "the game does not allow saving now" end
        return true
    end

    -- Starts a save into `slot` the way the game's autosave does (the save icon, the slot's
    -- description for the Load Game list, the system save).
    function Game:save_now(slot)
        local sdm = singleton(SAVE_MANAGER)
        if sdm == nil then return nil, "no save system" end
        local ok, args = pcall(sdk.create_instance, SAVE_ARGS)
        if not ok or args == nil then return nil, "cannot create the save request" end
        args = self:hold(args, 120.0) -- queued by the save flow: alive until the save is written (Game:hold)
        self:call(sdm, "setPlayLoadData(System.Boolean)", false)
        self.save_mirroring = true
        local before = self.save_counters and self.save_counters.saves or 0
        local okc, err = pcall(function() return sdm:call("requestStartSaveGameDataFlow", slot, args) end)
        self.save_mirroring = false
        if not okc then return nil, tostring(err) end
        self.perf:crumb("save.mirror", tostring(slot), true)
        if self.save_counters ~= nil and self.save_counters.saves == before then
            return nil, "the save flow did not start"
        end
        return true
    end

    function Game:save_exists(slot)
        local sdm = singleton(SAVE_MANAGER)
        return sdm ~= nil and self:call(sdm, "isExistSaveData", slot) == true
    end

    -- A main campaign save Continue can load (autosave or slots 1-20).
    function Game:any_save()
        local sdm = singleton(SAVE_MANAGER)
        if sdm == nil then return false end
        for slot = 0, M.LIST_SLOTS do
            if self:call(sdm, "isExistSaveData", slot) == true then return true end
        end
        return false
    end

    -- The main campaign slot our game last loaded successfully, or nil.
    function Game:last_loaded_slot()
        local sdm = singleton(SAVE_MANAGER)
        local slot = sdm and tonumber(self:call(sdm, "get_LastLoadSuccessedGameSlot")) or nil
        if slot == nil or slot < 0 or slot > M.LIST_SLOTS then return nil end
        return slot
    end

    -- The slot Continue would load (the newest main campaign save), or nil.
    function Game:continue_save_slot()
        local hw = singleton(HIGHWAY)
        local mgr = hw and self:call(hw, "get_SaveLoadMenuGuiManager") or self.continue_mgr
        local detail = mgr and self:call(mgr, "findContinueSave")
        if detail == nil then return nil end
        local empty = detail.get_field and detail:get_field("<IsEmpty>k__BackingField")
        local info = detail.get_field and detail:get_field("<Info>k__BackingField")
        if empty == true or info == nil then return nil end
        local slot = tonumber(info.get_field and info:get_field("SlotIndex"))
        if slot == nil or slot < 0 or slot > M.LIST_SLOTS then return nil end
        return slot
    end

    ---------------------------------------------------------------------------
    -- Loading in game (the pause menu's Load Game)
    ---------------------------------------------------------------------------

    -- Starts reading `slot` while in game; ingame_load_tick() leaves the game for the in-game
    -- setup once it is read. true | nil, why.
    function Game:ingame_load(slot)
        local l = self.ingame_loading
        if l ~= nil and l.phase == "loading" then return nil, "a load is already running" end
        local cap = self.caps and self.caps.ingame_load
        if cap ~= nil and not cap.ok then return nil, "loading in game is not available" end
        local sdm = singleton(SAVE_MANAGER)
        if sdm == nil then return nil, "no save system" end
        if self:call(sdm, "get_IsBusy") == true then return nil, "the game is saving or loading" end
        if not self:save_exists(slot) then return nil, ("slot %d is empty"):format(slot) end
        local okA, args = pcall(sdk.create_instance, LOAD_ARGS)
        if not okA or args == nil then return nil, "cannot create the load request" end
        args = self:hold(args, 120.0) -- the queued request keeps a copy; ours lives until it is read
        self:call(sdm, "setPlayLoadData(System.Boolean, System.Int32)", slot == 0, slot)
        local ok, err = pcall(function()
            return sdm:call("enqueueLoadRequest(System.Int32, share.SaveLoadRequestArgs)", slot, args)
        end)
        if not ok then return nil, tostring(err) end
        -- A save read before and never applied would look like ours: then ours must be seen running.
        local stale = self:call(sdm, "get_LoadedGamedataApplyable") == true
        self.ingame_loading = { slot = slot, at = self.clock(), phase = "loading", busy_seen = false, stale = stale }
        self.save_counters = self.save_counters or {}
        self.save_counters.ingame_loads = (self.save_counters.ingame_loads or 0) + 1
        self.perf:crumb("save.ingame_load", tostring(slot), true)
        return true
    end

    -- Leaves the game for the in-game setup the way the pause menu's load callback does.
    function Game:ingame_load_leave()
        local mm = singleton(MAIN_MODE)
        if mm == nil then return nil, "no game state manager" end
        local okA, arg = pcall(sdk.create_instance, CLEANUP_ARG)
        local okN, next_state = pcall(sdk.typeof, SETUP)
        local okC, cleanup = pcall(sdk.typeof, CLEANUP)
        if not okA or arg == nil or not okN or next_state == nil or not okC or cleanup == nil then
            return nil, "cannot build the state change"
        end
        arg = self:hold(arg, 60.0)
        if not pcall(arg.set_field, arg, "NextState", next_state) then return nil, "cannot set the next state" end
        pcall(arg.set_field, arg, "Difficulty", DEFAULT_DIFFICULTY)
        local hw = singleton(HIGHWAY)
        if hw ~= nil then self:call(hw, "setFixInGameStateExit") end
        local clap = singleton(CLAPPERBOARD)
        if clap ~= nil then self:call(clap, "clearRequestTimeline") end
        local ok, err = pcall(function()
            return mm:call("requestToChangeGameState(System.Type, share.GameStateArgument)", cleanup, arg)
        end)
        if not ok then return nil, tostring(err) end
        self.perf:crumb("save.ingame_load_leave", nil, true)
        return true
    end

    -- Every game frame: an in-game load whose save is read leaves the game; one that failed or
    -- timed out is dropped. Returns the load's state (nil when none runs).
    function Game:ingame_load_tick()
        local l = self.ingame_loading
        if l == nil or l.phase ~= "loading" then return l end
        local sdm = singleton(SAVE_MANAGER)
        local now = self.clock()
        if sdm == nil then
            l.phase, l.why = "failed", "no save system"
            return l
        end
        if self:call(sdm, "get_IsBusy") == true then
            l.busy_seen = true
            return l
        end
        if not l.busy_seen and (l.stale or now - l.at < LOAD_PICKUP) then
            if now - l.at > M.LOAD_TIMEOUT then
                l.phase, l.why = "failed", "the load did not start"
                self.log(("in-game load of slot %d failed: %s"):format(l.slot, l.why))
            end
            return l
        end
        if self:call(sdm, "get_LoadedGamedataApplyable") ~= true then
            if l.busy_seen or now - l.at > M.LOAD_TIMEOUT then
                l.phase, l.why = "failed", l.busy_seen and "the save could not be read" or "the load did not start"
                self.log(("in-game load of slot %d failed: %s"):format(l.slot, l.why))
            end
            return l
        end
        local ok, why = self:ingame_load_leave()
        l.phase, l.why, l.left_at = ok and "left" or "failed", why, now
        self.log(ok and ("in-game load of slot %d: leaving for the in-game setup"):format(l.slot)
            or ("in-game load of slot %d: could not leave the game (%s)"):format(l.slot, tostring(why)))
        return l
    end
end

return M
