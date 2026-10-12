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

local M = {}

local SAVE_MANAGER = "share.SaveDataManager"
local SAVE_ARGS = "chainsaw.ChainsawGameSaveRequestArgs"
local UDS = "chainsaw.UDSManagerApp"
local INTENT_FIELD = "<_IsRequestGameIntent>k__BackingField"
local INTENT_MAIN_GAME = 0 -- chainsaw.UDSManagerApp.GameIntentMode.MainGame
M.LIST_SLOTS = 20          -- share.AppSaveSlot.Campaign1001_GameSaveEnd

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
        local saves_ok = start_m ~= nil and pcall(sdk.hook, start_m, function(args)
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
        if cont_m ~= nil and pcall(sdk.hook, cont_m, function(args)
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
            if upd ~= nil and pcall(sdk.hook, upd, function()
                self.save_counters.menu_frames = self.save_counters.menu_frames + 1
                self.menu_seen = where
                local ok, want = pcall(h.on_menu, where)
                if ok and want then self:request_continue() end
            end, function(retval) return retval end) then done[#done + 1] = where end
        end
        local load_ok = #done == 3 and find_type(UDS) ~= nil
        self:cap("join_load", load_ok, load_ok and "findContinueSave / title / main menu hooked"
            or ("only " .. table.concat(done, ", ")))
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

    -- Our game can start a save now: the save system is idle and nothing excludes saving.
    function Game:save_can()
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
end

return M
