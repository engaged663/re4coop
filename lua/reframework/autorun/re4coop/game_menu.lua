-- RE4 (2023) adapter, part 5: the game's own main menu. Our "Multijugador" entry (above
-- "Opciones") and its section (Host Game, Join Game, Multiplayer Options, Back) are entries of
-- the game's own menu list, drawn by the game; our lobby screen covers the menu; a co-op game
-- starts the way the menu's New Game and Continue start one. Installed into game.lua's Game
-- class (require("re4coop.game_menu").install(Game, helpers)); session.lua talks to the game
-- only through these methods.
--
-- How the game does it (re4.exe, docs/RESEARCH.md 3.31):
--   * GameStateMainMenu opens the menu window in its phase ShowMainMenu_Menu_Open (9):
--     GuiManager.open(MainMenu) with itself as the OpenParam applier, then phase WaitMainMenu
--     (10). The window's applyGuiParam(OpenParam) (0x141905a30) - only while it is closed (step
--     WaitOpen) - runs setup() (0x1419dead0) and draw() (0x141930e60). setup() builds
--     ActualMenuList (+0x1e8) from the serialized _MenuList (+0x1f0), keeping what
--     isAvliableAction accepts (any action type it does not know), gives the ScrollList
--     ModeSelectList (+0x228) that many rows (set_ItemCount, set_ItemMax) and hooks its
--     SelectionChanged; draw() writes each row's text: the row's ListIndex ->
--     ActualMenuList[i]._ItemText -> MessageManager.getMessage. A changed selection draws again
--     (onSelectionChanged). The ScrollList keeps its cursor from one opening to the next.
--   * lateUpdateOnActive (0x141977bf0) takes Decide (GuiInputManager.isTrigger) on the selected
--     row (ActualMenuList[cursor], unchecked), sets isDecided (+0x220) and calls
--     OpenParam.OnDecided(actionType), which is GameStateMainMenu.onDecidedMainMenu
--     (0x141b5bba0): a switch on the action type. Play, Extra, Bonus... close the window
--     (GuiManager.close(MainMenu)); coming back (LeaveStoryMenu) the game opens it again in phase 9.
--   * Our entries go into _MenuList before setup() runs, so the game builds, sizes, draws and
--     selects them as its own (the list it built for the game's entries is kept). Our section
--     and back are swapped into the open menu (ActualMenuList, the ScrollList's rows, cursor,
--     draw()), from the session's frame, never from inside setup().
--   * REFramework's SystemArray.get_elements hands the C++ vector to Lua as a sol2 container
--     (userdata), not a table: arrays are read with get_size / get_element. 0.11.0 took that
--     for an empty array, so the menu kept one row - ours, without a text: an invisible menu.
--   * New Game: the story menu sets _SelectedCampaignKey (a Nullable<CampaignInitialSettingKey>:
--     HasValue at +0x80, the key at +0x84); onDecidedDefficultySelectMenu(difficulty)
--     (0x141b5bab0) writes IngameSetupArgument and goes to phase StartPointDecided (35), whose
--     update calls CampaignManager.initializeForStartingCampaign(key) and goes to Decided (56);
--     with no story menu open (isDeactivatedTitleSceneGui) the game goes in.
--   * Continue: the game intent and findContinueSave (game_save.lua) load the slot we ask for.
--   * The menu window is never hidden under our screens (ChainsawGuiBehaviorBase.setVisible
--     stops its lateUpdateOnActive).
--   * What the menu looks like goes to reframework/data/re4coop_menu.json a moment after each
--     opening (Game:menu_snapshot), for the in-game reports.

local Guard = require("re4coop.hookguard")
local M = {}

local MENU_BEH = "chainsaw.MainMenuGuiBehavior"
local MENU_ITEM = "chainsaw.MainMenuGuiBehavior.MenuItem"
local MENU_STATE = "chainsaw.GameStateMainMenu"
local GUI_MANAGER = "chainsaw.GuiManager"
local GUI_INPUT = "chainsaw.GuiInputManager"
local HIGHWAY = "chainsaw.HighwayGuiManager"

M.ACTION_OPTION = 3          -- chainsaw.MainMenuActionType.Option
M.ACTION_EXIT = 4            -- .Exit
M.PHASE_WAIT_MAIN_MENU = 10  -- chainsaw.GameStateMainMenu.Phase.WaitMainMenu
M.PHASE_START_POINT = 35     -- .StartPointDecided
M.GUI_MAIN_MENU = 5          -- chainsaw.GuiType.MainMenu
M.GUI_LOADING = 71           -- chainsaw.GuiType.Loading
M.RENDER_DEFAULT = 2         -- chainsaw.RenderOutputType.Default
M.RENDER_COMMON = 3
M.STORY_NEW_GAME = 4         -- chainsaw.StoryMenuActionType.NewGame
M.KEY_HAS_VALUE = 0x80       -- GameStateMainMenu._SelectedCampaignKey.HasValue
M.KEY_VALUE = 0x84           -- GameStateMainMenu._SelectedCampaignKey.Value
M.MENU_GONE = 1.0            -- seconds without the menu's own update: the menu is gone
M.DEBUG_FILE = "re4coop_menu.json"
M.DEBUG_DELAY = 2.0          -- seconds after an opening: what the menu looks like goes to DEBUG_FILE
M.DEBUG_KEEP = 8             -- snapshots kept in DEBUG_FILE

-- chainsaw.GuiCommandType: the commands every menu of the game reads (keyboard, mouse buttons
-- and pad alike).
M.COMMANDS = {
    decide = 3786011693, cancel = 1883353458, up = 201991506, down = 2450535976,
    left = 4067573900, right = 717819916, page_left = 2288036994, page_right = 658298596,
}
M.COMMAND_ORDER = { "decide", "cancel", "up", "down", "left", "right", "page_left", "page_right" }

function M.install(Game, H)
    local singleton, find_type = H.singleton, H.find_type

    local function managed(v)
        if v == nil then return nil end
        if type(v) == "table" then return v end -- already an object (tests)
        local ok, o = pcall(sdk.to_managed_object, v)
        if ok and o ~= nil and (type(o) == "table" or type(o) == "userdata") then return o end
        return nil
    end

    local function int_arg(v)
        local ok, n = pcall(sdk.to_int64, v)
        if not ok or n == nil then return nil end
        n = n & 0xFFFFFFFF
        if n >= 0x80000000 then n = n - 0x100000000 end
        return n
    end

    local function field(obj, name)
        if obj == nil or obj.get_field == nil then return nil end
        local ok, v = pcall(obj.get_field, obj, name)
        if ok then return v end
        return nil
    end

    local function set_field(obj, name, v)
        if obj == nil or obj.set_field == nil then return false end
        return (pcall(obj.set_field, obj, name, v))
    end

    -- A System.Array's elements, in order. get_elements gives a Lua table only in some
    -- REFramework builds (a sol2 container, userdata, in others): then get_size / get_element.
    local function elements(arr)
        if arr == nil then return {} end
        local ok, list = pcall(function() return arr:get_elements() end)
        if ok and type(list) == "table" then return list end
        local out = {}
        local okN, n = pcall(function() return arr:get_size() end)
        n = okN and tonumber(n) or 0
        for i = 0, n - 1 do
            local okE, e = pcall(function() return arr:get_element(i) end)
            if not okE or e == nil then break end
            out[i + 1] = e
        end
        return out
    end

    local function static_call(type_name, method, ...)
        local td = find_type(type_name)
        local m = td and td:get_method(method)
        if m == nil then return nil end
        local ok, r = pcall(m.call, m, nil, ...)
        return ok and r or nil
    end

    ---------------------------------------------------------------------------
    -- Our entries in the menu list
    ---------------------------------------------------------------------------

    -- h = { entry = action of "Multijugador", section = { actions }, labels = { [action] = text },
    --       mode() -> "main" | "mp", covered() -> bool, on_decide(action), on_cancel() }
    function Game:install_menu_hooks(h)
        self.menu_h = h
        -- base: the game's own entries of the window base_of; arrays: our _MenuList per mode;
        -- built: the ActualMenuList setup() built per mode; live: lists we made for a mode
        -- setup() never built; prepared / applied: the mode setup() is building / the menu shows;
        -- cursor_to: the row the cursor goes to once the window is up; active: its own update ran
        -- since it opened.
        self.menu = { beh = nil, seen = -math.huge, base = nil, base_of = nil, arrays = {}, built = {}, live = {},
            prepared = nil, applied = nil, label_name = nil, covered = nil, cursor_to = nil, active = false,
            items = {}, snapshots = {}, debug_at = nil, debug_reason = nil, state_seen = false,
            counters = { setups = 0, built = 0, swaps = 0, texts = 0, decided = 0, blocked = 0, cancels = 0 } }
        if type(sdk) ~= "table" or sdk.hook == nil then
            self:cap("menu_entries", false, "sdk.hook unavailable")
            return false
        end
        local done = {}
        local beh_td = find_type(MENU_BEH)

        -- 1. setup: the list it builds from (_MenuList) is the list of our mode (pre); what it
        --    built (post).
        local setup_m = beh_td and beh_td:get_method("setup")
        local in_setup = nil
        if setup_m ~= nil and pcall(Guard.hook, setup_m, function(args)
            in_setup = managed(args[2])
            if in_setup ~= nil then
                local ok, err = pcall(self.menu_prepare, self, in_setup)
                if not ok then self:cap("menu_list", false, tostring(err)) end
            end
        end, function(retval)
            local beh = in_setup
            in_setup = nil
            if beh ~= nil then
                local ok, err = pcall(self.menu_on_setup, self, beh)
                if not ok then self:cap("menu_list", false, tostring(err)) end
            end
            return retval
        end) then done[#done + 1] = "setup" end

        -- 2. draw (post): the game wrote every row's text; ours get theirs.
        local draw_m = beh_td and beh_td:get_method("draw")
        local in_draw = nil
        if draw_m ~= nil and pcall(Guard.hook, draw_m, function(args)
            in_draw = managed(args[2])
        end, function(retval)
            local beh = in_draw
            in_draw = nil
            if beh ~= nil then pcall(self.menu_write_texts, self, beh) end
            return retval
        end) then done[#done + 1] = "draw" end

        -- 3. lateUpdateOnActive (pre): no input for the menu while our screen covers it; Cancel
        --    in our section goes back to the game's entries.
        local late_m = beh_td and beh_td:get_method("lateUpdateOnActive")
        if late_m ~= nil and pcall(Guard.hook, late_m, function(args)
            local beh = managed(args[2])
            local m = self.menu
            if beh ~= nil then m.beh, m.seen, m.active = beh, self.clock(), true end
            local okC, covered = pcall(h.covered)
            if okC and covered then
                m.counters.blocked = m.counters.blocked + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            local okM, mode = pcall(h.mode)
            if okM and mode == "mp" and m.applied == "mp" and field(beh, "isDecided") ~= true
                and self:gui_trigger("cancel") then
                m.counters.cancels = m.counters.cancels + 1
                pcall(h.on_cancel)
            end
        end, function(retval) return retval end) then done[#done + 1] = "input" end

        -- 4. onDecidedMainMenu (pre): our entries are ours (the game's switch has no case for
        --    them and must not see them).
        local state_td = find_type(MENU_STATE)
        local decide_m = state_td and state_td:get_method("onDecidedMainMenu")
        if decide_m ~= nil and pcall(Guard.hook, decide_m, function(args)
            local action = int_arg(args[3])
            local st = managed(args[2])
            if st ~= nil then self.main_menu_state, self.menu_state_seen = st, self.clock() end
            if action ~= nil and h.labels[action] ~= nil then
                self.menu.counters.decided = self.menu.counters.decided + 1
                self.menu.swap_failed = nil -- a new choice: a list may be tried again
                pcall(h.on_decide, action)
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(retval) return retval end) then done[#done + 1] = "decide" end

        local ok = #done == 4
        self:cap("menu_entries", ok, ok and "MainMenuGuiBehavior setup / draw / lateUpdateOnActive, onDecidedMainMenu hooked"
            or ("only " .. table.concat(done, ", ")))
        return ok
    end

    -- Our MenuItem for an action (made once, kept for good: the menu's arrays point at it).
    function Game:menu_item(action)
        local items = self.menu.items
        if items[action] ~= nil then return items[action] end
        local ok, item = pcall(sdk.create_instance, MENU_ITEM)
        if not ok or item == nil then return nil end
        pcall(item.add_ref_permanent, item)
        if not set_field(item, "_ActionType", action) then return nil end
        items[action] = item
        return item
    end

    local function action_of(entry)
        return tonumber(field(entry, "_ActionType"))
    end

    -- The list for a mode: "main" = the game's own entries with "Multijugador" above Options
    -- (else above Exit, else last); "mp" = our section alone.
    function Game:menu_list_for(mode)
        local h = self.menu_h
        local out = {}
        if mode == "mp" then
            for _, action in ipairs(h.section) do
                local item = self:menu_item(action)
                if item == nil then return nil end
                out[#out + 1] = item
            end
            return out
        end
        local entry = self:menu_item(h.entry)
        if entry == nil then return nil end
        local base = self.menu.base or {}
        local at = nil
        for i, e in ipairs(base) do
            local a = action_of(e)
            if a == M.ACTION_OPTION then at = i break end
            if a == M.ACTION_EXIT and at == nil then at = i end
        end
        for i, e in ipairs(base) do
            if i == at then out[#out + 1] = entry end
            if h.labels[action_of(e)] == nil then out[#out + 1] = e end
        end
        if at == nil then out[#out + 1] = entry end
        return out
    end

    -- A MenuItem[] of ours (kept for good: the menu points at it).
    local function item_array(list)
        local okA, a = pcall(sdk.create_managed_array, MENU_ITEM, #list)
        if not okA or a == nil then error("the menu list could not be made") end
        pcall(a.add_ref_permanent, a)
        for i, item in ipairs(list) do a[i - 1] = item end
        return a
    end

    -- The game's own entries of window `beh` (its _MenuList the first time we see it; ours are
    -- left out, so an array of ours read again gives the same).
    function Game:menu_base(beh)
        local m = self.menu
        if m.base_of == beh then return m.base end
        local src = field(beh, "_MenuList")
        if src == nil then error("the menu has no _MenuList") end
        pcall(src.add_ref_permanent, src) -- the game's own array outlives our replacing it
        local base = {}
        for _, e in ipairs(elements(src)) do
            if self.menu_h.labels[action_of(e)] == nil then base[#base + 1] = e end
        end
        if #base == 0 then error("the menu's _MenuList is empty") end
        m.base, m.base_of, m.arrays, m.built, m.live, m.label_name = base, beh, {}, {}, {}, nil
        return base
    end

    -- What setup() builds the list of `mode` from (an array of ours, made once per window).
    function Game:menu_source(mode)
        local m = self.menu
        if m.arrays[mode] ~= nil then return m.arrays[mode] end
        local list = self:menu_list_for(mode)
        if list == nil or #list == 0 then error("our menu entries could not be made") end
        m.arrays[mode] = item_array(list)
        return m.arrays[mode]
    end

    -- Before setup(): the menu's _MenuList - what setup() builds the list from - becomes the list
    -- of our mode: the game's own entries with ours. Errors leave the game's own list as it is.
    function Game:menu_prepare(beh)
        local m = self.menu
        m.prepared = nil
        m.beh, m.seen = beh, self.clock()
        self:menu_base(beh)
        local okM, mode = pcall(self.menu_h.mode)
        mode = (okM and mode == "mp") and "mp" or "main"
        local arr = self:menu_source(mode)
        self:menu_cursor_before(beh, elements(arr), mode)
        if not set_field(beh, "_MenuList", arr) then error("_MenuList could not be set") end
        m.prepared = mode
        m.counters.built = m.counters.built + 1
    end

    -- The ScrollList keeps its cursor from one opening to the next and lateUpdateOnActive reads
    -- ActualMenuList[cursor] unchecked: before a list of another length is built (the window is
    -- closed then), the cursor goes to its row in the new list if that row exists in the old one
    -- too, else inside the new list; the rest waits until the window is up again (menu_tick).
    -- Our section starts on its first row; back from it, the cursor is on "Multijugador".
    function Game:menu_cursor_before(beh, list, mode)
        local m = self.menu
        m.cursor_to = nil
        local target = nil
        if m.applied ~= nil and m.applied ~= mode then
            target = 0
            if mode == "main" then
                for i, item in ipairs(list) do
                    if action_of(item) == self.menu_h.entry then target = i - 1 end
                end
            end
        end
        local scroll = field(beh, "ModeSelectList")
        if scroll == nil then return end
        local cur = tonumber(self:call(scroll, "get_SelectedIndex"))
        local count = tonumber(self:call(scroll, "get_ItemCount"))
        local SET = "setSelectedIndex(System.Int32, System.Boolean)"
        if target ~= nil and count ~= nil and target < count then
            if cur ~= target then self:call(scroll, SET, target, true) end
            return
        end
        if cur ~= nil and cur >= #list then self:call(scroll, SET, 0, true) end
        m.cursor_to = target
    end

    -- After setup(): what the game built from our list (kept: the list of that mode, as the game
    -- filters it, when we swap back to it).
    function Game:menu_on_setup(beh)
        local m = self.menu
        local now = self.clock()
        m.beh, m.seen, m.active = beh, now, false
        m.counters.setups = m.counters.setups + 1
        m.applied, m.covered, m.swap_failed = m.prepared, nil, nil
        m.debug_at, m.debug_reason = now + M.DEBUG_DELAY, "opened"
        local actual = field(beh, "ActualMenuList")
        local n = #elements(actual)
        if m.applied ~= nil then
            if n > 0 and m.base_of == beh then
                pcall(actual.add_ref_permanent, actual)
                m.built[m.applied] = actual
            end
            self:cap("menu_list", n > 0, ("%d entries (%s)"):format(n, m.applied))
        end
    end

    -- The list of `mode` for the open menu: the one setup() built for it, else ours as setup()
    -- would keep it (the game's own isAvliableAction).
    function Game:menu_live_array(beh, mode)
        local m = self.menu
        if m.built[mode] ~= nil then return m.built[mode] end
        if m.live[mode] ~= nil then return m.live[mode] end
        local kept = {}
        for _, item in ipairs(self:menu_list_for(mode) or {}) do
            local a = action_of(item)
            if self:call(beh, "isAvliableAction(chainsaw.MainMenuActionType)", a) ~= false then kept[#kept + 1] = item end
        end
        if #kept == 0 then error("our menu entries could not be made") end
        m.live[mode] = item_array(kept)
        return m.live[mode]
    end

    -- Our section (or the game's entries again) into the open menu, from the session's frame:
    -- ActualMenuList, the ScrollList's rows (set_ItemCount / set_ItemMax rebuild them on a live
    -- list), the cursor (never past the end of the list it points into: lateUpdateOnActive reads
    -- ActualMenuList[cursor] unchecked) - on the first row of our section, on "Multijugador"
    -- back from it - and the texts (draw()). _MenuList follows, for the next opening.
    function Game:menu_swap(beh, mode)
        local m = self.menu
        self:menu_base(beh)
        local arr = self:menu_live_array(beh, mode)
        local list = elements(arr)
        local n = #list
        if n == 0 then error("the menu list could not be read") end
        local target = 0
        if mode == "main" then
            for i, item in ipairs(list) do
                if action_of(item) == self.menu_h.entry then target = i - 1 end
            end
        end
        local scroll = field(beh, "ModeSelectList")
        if scroll == nil then error("the menu has no ScrollList") end
        local SET = "setSelectedIndex(System.Int32, System.Boolean)"
        local cur = tonumber(self:call(scroll, "get_SelectedIndex"))
        if cur == nil or cur < 0 or cur >= n then self:call(scroll, SET, 0, true) end
        if not set_field(beh, "ActualMenuList", arr) then error("ActualMenuList could not be set") end
        self:call(scroll, "set_ItemCount(System.UInt32)", n)
        self:call(scroll, "set_ItemMax(System.UInt32)", n)
        self:call(scroll, SET, target, false)
        set_field(beh, "isDecided", false)
        set_field(beh, "_MenuList", self:menu_source(mode))
        m.applied, m.cursor_to = mode, nil
        m.counters.swaps = m.counters.swaps + 1
        self:call(beh, "draw") -- every row's text (ours through the draw hook)
        self.perf:crumb("menu.swap", mode, true)
        self:cap("menu_list", true, ("%d entries (%s)"):format(n, mode))
        m.debug_at, m.debug_reason = self.clock() + M.DEBUG_DELAY, "swapped"
    end

    -- A via.gui.Text (or one derived from it: MaterialText).
    local function is_text(self, obj)
        local tn, td = self:type_name(obj)
        if tn == "via.gui.Text" or tn == "via.gui.MaterialText" then return true end
        if td ~= nil and td.is_a ~= nil then
            local ok, r = pcall(td.is_a, td, "via.gui.Text")
            return ok and r == true
        end
        return false
    end

    -- Text objects under a GUI control (depth-first, a few levels).
    local function texts_under(self, ctrl, out, depth)
        local c = self:call(ctrl, "get_Child")
        local n = 0
        while c ~= nil and n < 48 do
            if is_text(self, c) then out[#out + 1] = c end
            if depth < 6 then texts_under(self, c, out, depth + 1) end
            c = self:call(c, "get_Next")
            n = n + 1
        end
        return out
    end

    -- The name of the Text that holds a row's label: the one whose message differs between the
    -- game's own rows (other texts of a row are the same in every row, or empty).
    function Game:menu_learn_label(rows, list)
        local seen = {} -- name -> { [message] = true }
        local native = 0
        for _, row in ipairs(rows) do
            local i = tonumber(self:call(row, "get_ListIndex"))
            local entry = i and list[i + 1]
            if entry ~= nil and self.menu_h.labels[action_of(entry)] == nil then
                native = native + 1
                for _, t in ipairs(texts_under(self, row, {}, 0)) do
                    local name, msg = self:call(t, "get_Name"), self:call(t, "get_Message")
                    if type(name) == "string" and type(msg) == "string" and msg ~= "" then
                        seen[name] = seen[name] or {}
                        seen[name][msg] = true
                    end
                end
            end
        end
        if native < 2 then return nil end
        local best, best_n = nil, 1
        for name, msgs in pairs(seen) do
            local n = 0
            for _ in pairs(msgs) do n = n + 1 end
            if n > best_n then best, best_n = name, n end
        end
        return best
    end

    -- Our rows' labels, after the game's draw() wrote its own (for ours: empty).
    function Game:menu_write_texts(beh)
        local h = self.menu_h
        if h == nil then return end
        local list = elements(field(beh, "ActualMenuList"))
        local scroll = field(beh, "ModeSelectList")
        local rows = elements(self:call(scroll, "get_Items"))
        local m = self.menu
        -- Learned once per window from the game's own rows (our section alone has none: it
        -- keeps what the game's entries taught).
        if m.label_name == nil then m.label_name = self:menu_learn_label(rows, list) end
        for _, row in ipairs(rows) do
            local i = tonumber(self:call(row, "get_ListIndex"))
            local entry = i and list[i + 1]
            local label = entry and h.labels[action_of(entry)]
            if label ~= nil then
                for _, t in ipairs(texts_under(self, row, {}, 0)) do
                    local name, msg = self:call(t, "get_Name"), self:call(t, "get_Message")
                    -- Known label text: that one. Not learned (our section alone): every empty text.
                    if (m.label_name and name == m.label_name) or (not m.label_name and (msg == nil or msg == "")) then
                        if msg ~= label then
                            self:call(t, "set_Message", label)
                            m.counters.texts = m.counters.texts + 1
                        end
                    end
                end
            end
        end
    end

    -- The menu's window while it is up, else nil: its own lateUpdateOnActive ran recently, or the
    -- main menu state's update (game_save.lua's hook) did (the window may not update while the
    -- game has other things on screen).
    function Game:menu_behavior()
        local m = self.menu
        if m == nil or m.beh == nil then return nil end
        local now = self.clock()
        local state_alive = now - (self.menu_state_seen or -math.huge) <= M.MENU_GONE
        if now - m.seen > M.MENU_GONE and not state_alive then
            -- What it was built from (base, arrays) stays: the same window opens again later.
            m.beh, m.covered, m.active = nil, nil, false
            return nil
        end
        return m.beh
    end

    -- Every game frame. The list of our mode into the open menu (menu_swap); the cursor where
    -- menu_cursor_before could not put it, once the window is up. The menu stays visible under
    -- our screens (their backdrop covers it): while covered only its input is held
    -- (lateUpdateOnActive's pre-hook), and when uncovered it takes decisions again.
    -- want = { mode = "main" | "mp", covered = bool }
    function Game:menu_tick(want)
        local m = self.menu
        if m == nil then return false end
        local now = self.clock()
        if not m.state_seen and self:menu_state() ~= nil then
            -- The main menu state runs (from the title on): a snapshot even if the window never
            -- opens for us.
            m.state_seen = true
            if m.debug_at == nil then m.debug_at, m.debug_reason = now + M.DEBUG_DELAY + 1.0, "menu state" end
        end
        if m.debug_at ~= nil and now >= m.debug_at then
            m.debug_at = nil
            self:menu_write_debug(m.debug_reason or "opened")
        end
        local beh = self:menu_behavior()
        if beh == nil then return false end
        local up = m.active and now - m.seen <= M.MENU_GONE -- its own update runs: open and active
        -- Our list: on a mode change; or once when the window was already open as the script
        -- loaded (Reset Scripts on the menu: setup() never seen). Not when setup() ran without
        -- our list (the game's own list stays), nor again after a swap that failed.
        local swap = m.applied ~= want.mode and (m.applied ~= nil or m.counters.setups == 0)
        if swap and up and m.swap_failed ~= want.mode then
            local ok, err = pcall(self.menu_swap, self, beh, want.mode)
            if not ok then
                m.swap_failed = want.mode
                set_field(beh, "isDecided", false)
                self:cap("menu_list", false, tostring(err))
                self:menu_write_debug("swap failed")
            end
        elseif m.cursor_to ~= nil and up then
            local scroll = field(beh, "ModeSelectList")
            self:call(scroll, "setSelectedIndex(System.Int32, System.Boolean)", m.cursor_to, false)
            m.cursor_to = nil
        end
        if m.covered ~= want.covered then
            m.covered = want.covered
            if not want.covered then set_field(beh, "isDecided", false) end
        end
        return true
    end

    local function window_open(self)
        local gm = singleton(GUI_MANAGER)
        if gm == nil then return nil end
        return self:call(gm, "isOpen(chainsaw.GuiType, chainsaw.RenderOutputType, chainsaw.IGuiKey)", M.GUI_MAIN_MENU,
            M.RENDER_DEFAULT, nil) == true
    end

    ---------------------------------------------------------------------------
    -- What the menu looks like (reframework/data/re4coop_menu.json)
    ---------------------------------------------------------------------------

    local function plain(v)
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then return v end
        if v == nil then return nil end
        return tostring(v)
    end

    local function actions_of(arr)
        local out = {}
        for _, e in ipairs(elements(arr)) do out[#out + 1] = action_of(e) or -1 end
        return out
    end

    function Game:menu_snapshot(reason)
        local m = self.menu
        local snap = { reason = reason, t = self.clock(), applied = m.applied, prepared = m.prepared,
            swap_failed = m.swap_failed, cursor_to = m.cursor_to, label_name = m.label_name,
            active = m.active, counters = {}, caps = {} }
        if type(os) == "table" and os.date then snap.time = os.date("%Y-%m-%d %H:%M:%S") end
        for k, v in pairs(m.counters) do snap.counters[k] = v end
        for _, k in ipairs({ "menu_entries", "menu_list", "menu_start" }) do
            local c = self.caps[k]
            if c ~= nil then snap.caps[k] = (c.ok and "ok: " or "FAILED: ") .. tostring(c.detail) end
        end
        local st = self:menu_state()
        snap.phase = st and plain(self:call(st, "get_CurrPhase")) or nil
        snap.window_open = window_open(self)
        local beh = m.beh or m.base_of
        if beh == nil then return snap end
        snap.step = plain(self:call(beh, "get_CurrStep"))
        snap.is_active = plain(self:call(beh, "get_IsActive"))
        snap.decided = plain(field(beh, "isDecided"))
        snap.menu_list = actions_of(field(beh, "_MenuList"))
        snap.actual = actions_of(field(beh, "ActualMenuList"))
        local gui = field(beh, "_GUI")
        if gui ~= nil then
            snap.gui = { enabled = plain(self:call(gui, "get_Enabled")) }
            local view = self:call(gui, "get_View")
            if view ~= nil then
                snap.gui.view_visible = plain(self:call(view, "get_Visible"))
                snap.gui.view_play_state = plain(self:call(view, "get_PlayState"))
            end
        end
        local scroll = field(beh, "ModeSelectList")
        if scroll ~= nil then
            snap.scroll = { count = plain(self:call(scroll, "get_ItemCount")), max = plain(self:call(scroll, "get_ItemMax")),
                selected = plain(self:call(scroll, "get_SelectedIndex")), visible = plain(self:call(scroll, "get_Visible")),
                play_state = plain(self:call(scroll, "get_PlayState")), rows = {} }
            for n, row in ipairs(elements(self:call(scroll, "get_Items"))) do
                if n > 16 then break end
                local r = { index = plain(self:call(row, "get_ListIndex")), visible = plain(self:call(row, "get_Visible")),
                    play_state = plain(self:call(row, "get_PlayState")), texts = {} }
                for _, t in ipairs(texts_under(self, row, {}, 0)) do
                    local name = plain(self:call(t, "get_Name")) or "?"
                    r.texts[#r.texts + 1] = name .. " = " .. tostring(plain(self:call(t, "get_Message")))
                end
                snap.scroll.rows[#snap.scroll.rows + 1] = r
            end
        end
        return snap
    end

    -- The last few snapshots into reframework/data/re4coop_menu.json.
    function Game:menu_write_debug(reason)
        local m = self.menu
        local ok, snap = pcall(self.menu_snapshot, self, reason)
        if not ok then snap = { reason = reason, error = tostring(snap) } end
        m.snapshots[#m.snapshots + 1] = snap
        while #m.snapshots > M.DEBUG_KEEP do table.remove(m.snapshots, 1) end
        if type(json) ~= "table" or json.dump_file == nil then return false end
        return (pcall(json.dump_file, M.DEBUG_FILE, { snapshots = m.snapshots }))
    end

    -- The menu took a decision for one of our entries: take input again.
    function Game:menu_release_decision()
        local beh = self:menu_behavior()
        if beh ~= nil then set_field(beh, "isDecided", false) end
    end

    ---------------------------------------------------------------------------
    -- Input, state
    ---------------------------------------------------------------------------

    function Game:gui_trigger(name)
        local gim = singleton(GUI_INPUT)
        local cmd = M.COMMANDS[name]
        if gim == nil or cmd == nil then return false end
        return self:call(gim, "isTrigger(chainsaw.GuiCommandType, System.Boolean)", cmd, true) == true
    end

    -- The menu commands triggered this frame: { "decide", "up", ... }.
    function Game:gui_commands()
        local gim = singleton(GUI_INPUT)
        local out = {}
        if gim == nil then return out end
        for _, name in ipairs(M.COMMAND_ORDER) do
            if self:call(gim, "isTrigger(chainsaw.GuiCommandType, System.Boolean)", M.COMMANDS[name], true) == true then
                out[#out + 1] = name
            end
        end
        return out
    end

    -- The main menu's state object (from its update / decision hooks) while the menu runs.
    function Game:menu_state()
        if self.main_menu_state == nil then return nil end
        if self.clock() - (self.menu_state_seen or -math.huge) > M.MENU_GONE then return nil end
        return self.main_menu_state
    end

    -- { open (the menu's list is up), phase, ready (waiting for a choice) }
    function Game:menu_status()
        local st = self:menu_state()
        local phase = st and tonumber(self:call(st, "get_CurrPhase")) or nil
        return { open = self:menu_behavior() ~= nil, phase = phase, ready = phase == M.PHASE_WAIT_MAIN_MENU }
    end

    -- The game's loading screen is up.
    function Game:loading_screen()
        local gm = singleton(GUI_MANAGER)
        if gm == nil then return false end
        for _, render in ipairs({ M.RENDER_DEFAULT, M.RENDER_COMMON }) do
            if self:call(gm, "isOpen(chainsaw.GuiType, chainsaw.RenderOutputType, chainsaw.IGuiKey)", M.GUI_LOADING,
                render, nil) == true then
                return true
            end
        end
        return false
    end

    ---------------------------------------------------------------------------
    -- Starting a game
    ---------------------------------------------------------------------------

    -- A new game from the main menu, from start point `key` (chainsaw.CampaignInitialSettingKey),
    -- at `difficulty`, the way New Game -> difficulty select does it. true | nil, why.
    function Game:menu_start_new(key, difficulty)
        local st = self:menu_state()
        if st == nil then return nil, "el menú principal no está abierto" end
        local phase = tonumber(self:call(st, "get_CurrPhase"))
        if phase ~= M.PHASE_WAIT_MAIN_MENU then return nil, ("el menú principal está ocupado (fase %s)"):format(tostring(phase)) end
        self.perf:crumb("menu.start_new", tostring(key), true)
        -- What Play -> New Game would have chosen.
        set_field(st, "<ModeMenuSelected>k__BackingField", 0)   -- ModeMenuActionType.OfflineSolo: the story
        set_field(st, "<MainMenuSelected>k__BackingField", 0)   -- MainMenuActionType.Play
        set_field(st, "<StoryMenuSelected>k__BackingField", M.STORY_NEW_GAME)
        local okK = pcall(function()
            st:write_dword(M.KEY_VALUE, key)
            st:write_byte(M.KEY_HAS_VALUE, 1)
        end)
        if not okK or st:read_dword(M.KEY_VALUE) ~= key or st:read_byte(M.KEY_HAS_VALUE) ~= 1 then
            return nil, "no se pudo elegir el punto de inicio"
        end
        -- The menu window closes the way Play closes it.
        local gm = singleton(GUI_MANAGER)
        if gm ~= nil then
            self:call(gm, "close(chainsaw.GuiType, System.Boolean, chainsaw.RenderOutputType)", M.GUI_MAIN_MENU, false,
                M.RENDER_DEFAULT)
        end
        self:call(st, "onDecidedDefficultySelectMenu(chainsaw.CampaignManager.Difficulty)", difficulty)
        local now_phase = tonumber(self:call(st, "get_CurrPhase"))
        if now_phase ~= M.PHASE_START_POINT then
            return nil, ("el juego no aceptó la dificultad (fase %s)"):format(tostring(now_phase))
        end
        self:cap("menu_start", true, ("new game from key %d, difficulty %d"):format(key, difficulty))
        return true
    end

    -- Continue with the save in `slot` (game_save.lua's game intent; findContinueSave returns the
    -- slot the session's save sync asks for). true | nil, why.
    function Game:menu_continue(slot)
        if not self:save_exists(slot) then return nil, ("la ranura %d está vacía"):format(slot) end
        if not self:request_continue() then return nil, "el juego no aceptó cargar" end
        self:cap("menu_start", true, ("continue from slot %d"):format(slot))
        return true
    end

    -- What a save slot holds: { empty, chapter_id, difficulty, count, cleared } or nil.
    function Game:save_slot_info(slot)
        local hw = singleton(HIGHWAY)
        local mgr = hw and self:call(hw, "get_SaveLoadMenuGuiManager")
        local detail = mgr and self:call(mgr, "getSaveSlotInfoDetail(System.Int32)", slot)
        if detail == nil then return nil end
        local empty = field(detail, "<IsEmpty>k__BackingField")
        if empty == nil then empty = self:call(detail, "get_IsEmpty") end
        local info = field(detail, "<Info>k__BackingField")
        if empty == true or info == nil then return { empty = true } end
        return { empty = false, chapter_id = tonumber(field(info, "ChapterID")), difficulty = tonumber(field(info, "Difficulty")),
            count = tonumber(field(info, "SaveCount")) or 0, cleared = field(info, "JustMainCampaignCleared") == true }
    end

    ---------------------------------------------------------------------------
    -- Loadout
    ---------------------------------------------------------------------------

    function Game:weapon_item_id(weapon_id)
        return tonumber(static_call("chainsaw.ItemIDDefine", "getItemID(chainsaw.WeaponID)", weapon_id))
    end

    -- The game's name of a weapon (nil when the game cannot tell yet).
    function Game:weapon_name(weapon_id)
        local id = self:weapon_item_id(weapon_id)
        return id and self:item_name(id) or nil
    end

    local function generate(item_id, count, ammo_id, ammo_count)
        return static_call("chainsaw.ChainsawGuiUtil", "generateItem", item_id, count, -1, ammo_id or -1, ammo_count or 0, false)
    end

    -- Weapons (chainsaw.WeaponID) into our attache case, loaded, each with `stacks` stacks of its
    -- ammo. Returns { given = names, failed = n, full = n } or nil, why.
    function Game:give_loadout(weapons, stacks)
        if self:inventory_open() then return nil, "el maletín está abierto" end
        local ctrl = self:player_inventory_controller()
        if ctrl == nil then return nil, "no se encontró el maletín" end
        local out = { given = {}, failed = 0, full = 0 }
        local function add(item)
            local r = self:call(ctrl, "add(chainsaw.Item, chainsaw.InventorySlotType)", item, 0)
            local n = r and r.get_field and tonumber(r:get_field("AddCount")) or 0
            return n > 0
        end
        for _, wp in ipairs(weapons or {}) do
            local item_id = self:weapon_item_id(wp)
            local probe = item_id and generate(item_id, 1)
            local ammo = nil
            if probe ~= nil then
                local usable = elements(self:call(probe, "get_UsableAmmoList"))
                local first = usable[1]
                if type(first) == "table" or type(first) == "userdata" then
                    first = field(first, "mValue") or field(first, "value__")
                end
                ammo = tonumber(first)
            end
            local mag = probe and tonumber(self:call(probe, "get_DefaultAmmoMax")) or 0
            local weapon = item_id and (ammo and generate(item_id, 1, ammo, mag) or probe)
            if weapon == nil then
                out.failed = out.failed + 1
            elseif not add(weapon) then
                out.full = out.full + 1
            else
                out.given[#out.given + 1] = self:item_name(item_id) or ("wp" .. tostring(wp))
                if ammo ~= nil then
                    local a = generate(ammo, 1)
                    local stack = a and tonumber(self:call(a, "get_StackMax")) or 0
                    stack = math.max(1, math.min(stack > 0 and stack or 30, 200))
                    for _ = 1, stacks or 1 do
                        local box = generate(ammo, stack)
                        if box == nil then out.failed = out.failed + 1 break end
                        if not add(box) then out.full = out.full + 1 break end
                    end
                end
            end
        end
        self:cap("loadout", #out.given > 0, ("%d weapons given, %d failed, %d did not fit"):format(#out.given, out.failed, out.full))
        return out
    end
end

return M
