-- game_menu.lua against a mock of the game's main menu (shapes from re4.exe, docs/RESEARCH.md
-- 3.31): GameStateMainMenu opens the window in phase 9 (setup, then draw) and waits in phase 10;
-- MainMenuGuiBehavior.setup builds ActualMenuList from _MenuList (what isAvliableAction keeps)
-- and sizes the ScrollList; draw writes each row's label from its entry; lateUpdateOnActive
-- reads the menu commands; GameStateMainMenu.onDecidedMainMenu takes the decision; a new game
-- goes through _SelectedCampaignKey (+0x80/+0x84) and onDecidedDefficultySelectMenu. Arrays'
-- get_elements give a container, not a table, as REFramework's do (0.11.0 read them as empty).
local T = require("testlib")
local mock = require("mock_reframework")

local world = mock.install({ elements_container = true })

-- An array's elements, the way REFramework allows (get_size / get_element).
local function items_of(arr)
    local out = {}
    for i = 0, arr:get_size() - 1 do out[i + 1] = arr:get_element(i) end
    return out
end
local UNAVAILABLE = { [-1] = true, [8] = true, [9] = true } -- isAvliableAction: never these
world.player = mock.make_player({ x = 0, y = 0, z = 0 })

local NATIVE = { [0] = "Historia", [1] = "Contenido extra", [2] = "Bonificaciones", [3] = "Opciones", [4] = "Salir" }
local SELF_DRAWN = {} -- labels draw() wrote last, per row

-- REManagedObject raw access (offsets from the object), as REFramework has it.
do
    local o = mock.new("System.Object")
    local Managed = getmetatable(o)
    local function raw(self)
        local r = rawget(self, "__raw")
        if r == nil then r = {} rawset(self, "__raw", r) end
        return r
    end
    for _, w in ipairs({ "byte", "dword" }) do
        Managed["write_" .. w] = function(self, off, v) raw(self)[off] = v end
        Managed["read_" .. w] = function(self, off) return raw(self)[off] or 0 end
    end
end

mock.class("chainsaw.MainMenuGuiBehavior.MenuItem", "System.Object", {}, { _ActionType = "chainsaw.MainMenuActionType" })
mock.class("via.gui.PlayObject", "System.Object", {
    get_Next = { 0, function(self) return self.next end },
    get_Child = { 0, function(self) return self.child end },
    get_Name = { 0, function(self) return self.name end },
})
mock.class("via.gui.Text", "via.gui.PlayObject", {
    get_Message = { 0, function(self) return self.msg or "" end },
    set_Message = { 1, function(self, s) self.msg = s end },
})
mock.class("via.gui.SelectItem", "via.gui.PlayObject", {
    get_ListIndex = { 0, function(self) return self.index end },
})

local function make_row(i)
    -- A row: a panel with the label text, a constant text and a badge text (empty).
    local label = mock.new("via.gui.Text", { name = "txt_label" })
    local const = mock.new("via.gui.Text", { name = "txt_deco", msg = "~" })
    local badge = mock.new("via.gui.Text", { name = "txt_badge", msg = "" })
    local panel = mock.new("via.gui.PlayObject", { name = "pnl" })
    panel.child, label.next, const.next = label, const, badge
    local row = mock.new("via.gui.SelectItem", { index = i - 1, child = panel, label = label, const = const, badge = badge })
    return row
end

mock.class("via.gui.ScrollList", "System.Object", {
    get_Items = { 0, function(self) return mock.typed_array("via.gui.SelectItem", self.rows) end },
    get_SelectedIndex = { 0, function(self) return self.selected or 0 end },
    get_ItemCount = { 0, function(self) return self.count or 0 end },
    ["set_ItemCount(System.UInt32)"] = { 1, function(self, n)
        self.count = n
        self.count_calls = (self.count_calls or 0) + 1
        if (self.selected or 0) >= n then self.max_selected_seen = self.selected end
    end },
    ["set_ItemMax(System.UInt32)"] = { 1, function(self, n)
        self.max = n
        self.rows = {}
        for i = 1, n do self.rows[i] = make_row(i) end
    end },
    ["setSelectedIndex(System.Int32, System.Boolean)"] = { 2, function(self, i)
        self.selected = i
        self.cursor_sets = (self.cursor_sets or 0) + 1
        if self.owner then self.owner:call("draw") end -- SelectionChanged -> onSelectionChanged -> draw
    end },
})

mock.class("chainsaw.MainMenuGuiBehavior", "System.Object", {
    setup = { 0, function(self)
        local list = {}
        for _, e in ipairs(items_of(self.__fields._MenuList)) do
            if not UNAVAILABLE[e.__fields._ActionType] then list[#list + 1] = e end
        end
        local arr = mock.typed_array("chainsaw.MainMenuGuiBehavior.MenuItem", list)
        self.__fields.ActualMenuList = arr
        local scroll = self.__fields.ModeSelectList
        scroll:call("set_ItemCount(System.UInt32)", #list)
        scroll:call("set_ItemMax(System.UInt32)", #list)
        self.__fields.isDecided = false
    end },
    draw = { 0, function(self)
        self.draws = (self.draws or 0) + 1
        local list = items_of(self.__fields.ActualMenuList)
        for _, row in ipairs(self.__fields.ModeSelectList.rows) do
            local entry = list[row.index + 1]
            local a = entry and entry.__fields._ActionType
            row.label.msg = NATIVE[a] or "" -- MessageManager.getMessage of an empty Guid: ""
            SELF_DRAWN[row.index] = row.label.msg
        end
    end },
    lateUpdateOnActive = { 0, function(self)
        self.updates = (self.updates or 0) + 1
        if world.decide and not self.__fields.isDecided then
            world.decide = false
            self.__fields.isDecided = true
            local list = items_of(self.__fields.ActualMenuList)
            local a = list[self.__fields.ModeSelectList.selected + 1].__fields._ActionType
            world.menu_state:call("onDecidedMainMenu", a)
        end
    end },
    ["setVisible(System.Boolean)"] = { 1, function(self, v) self.visible = v end },
    ["isAvliableAction(chainsaw.MainMenuActionType)"] = { 1, function(self, a) return not UNAVAILABLE[a] end },
}, { ActualMenuList = "x", _MenuList = "x", ModeSelectList = "x", isDecided = "System.Boolean", RequiemBannerBehavior = "x" })

mock.class("chainsaw.GameStateMainMenu", "System.Object", {
    get_CurrPhase = { 0, function(self) return self.phase end },
    onDecidedMainMenu = { 1, function(self, a) self.native_decisions = (self.native_decisions or 0) + 1 self.last = a end },
    ["onDecidedDefficultySelectMenu(chainsaw.CampaignManager.Difficulty)"] = { 1, function(self, d)
        if self.phase ~= 54 then
            self.difficulty = d
            self.phase = 35
        end
    end },
}, { ["<ModeMenuSelected>k__BackingField"] = "i", ["<MainMenuSelected>k__BackingField"] = "i",
    ["<StoryMenuSelected>k__BackingField"] = "i" })

mock.class("chainsaw.GuiManager", "System.Object", {
    ["close(chainsaw.GuiType, System.Boolean, chainsaw.RenderOutputType)"] = { 3, function(self, gui, suspend, render)
        self.closed = { gui, suspend, render }
        self.closes = (self.closes or 0) + 1
        if gui == 5 then world.window_open = false end
    end },
    ["isOpen(chainsaw.GuiType, chainsaw.RenderOutputType, chainsaw.IGuiKey)"] = { 3, function(self, gui, render)
        if gui == 5 then return world.window_open == true and render == 2 end
        return gui == 71 and world.loading_open == true and render == 2
    end },
})
mock.class("chainsaw.GuiInputManager", "System.Object", {
    ["isTrigger(chainsaw.GuiCommandType, System.Boolean)"] = { 2, function(self, cmd) return world.triggers[cmd] == true end },
})
world.triggers = {}
world.singletons["chainsaw.GuiManager"] = mock.new("chainsaw.GuiManager")
world.singletons["chainsaw.GuiInputManager"] = mock.new("chainsaw.GuiInputManager")

-- Saves.
mock.class("chainsaw.gui.SaveSlotInfo", "System.Object", {}, { ChapterID = "i", Difficulty = "i", SaveCount = "i" })
mock.class("chainsaw.gui.SaveSlotInfoDetail", "System.Object", {}, { ["<IsEmpty>k__BackingField"] = "b", ["<Info>k__BackingField"] = "x" })
mock.class("chainsaw.SaveLoadMenuGuiManager", "System.Object", {
    ["getSaveSlotInfoDetail(System.Int32)"] = { 1, function(self, slot)
        local s = world.saves[slot]
        if s == nil then
            return mock.new("chainsaw.gui.SaveSlotInfoDetail", { __fields = { ["<IsEmpty>k__BackingField"] = true } })
        end
        local info = mock.new("chainsaw.gui.SaveSlotInfo", { __fields = { ChapterID = s.chapter, Difficulty = s.difficulty, SaveCount = 4 } })
        return mock.new("chainsaw.gui.SaveSlotInfoDetail", { __fields = { ["<IsEmpty>k__BackingField"] = false, ["<Info>k__BackingField"] = info } })
    end },
})
mock.class("chainsaw.HighwayGuiManager", "System.Object", {
    get_SaveLoadMenuGuiManager = { 0, function() return world.save_menu end },
})
world.saves = { [18] = { chapter = 23200, difficulty = 30 } }
world.save_menu = mock.new("chainsaw.SaveLoadMenuGuiManager")
world.singletons["chainsaw.HighwayGuiManager"] = mock.new("chainsaw.HighwayGuiManager")

-- Items.
mock.class("chainsaw.Item", "System.Object", {
    get_StackMax = { 0, function(self) return self.stack or 50 end },
    get_UsableAmmoList = { 0, function(self) return mock.typed_array("System.Int32", self.ammo_list or {}) end },
    get_DefaultAmmoMax = { 0, function(self) return self.mag or 0 end },
})
mock.class("chainsaw.ItemIDDefine", "System.Object", {
    ["getItemID(chainsaw.WeaponID)"] = { 1, function(_, wp) return wp * 1000 end, nil, { static = true } },
})
world.generated = {}
mock.class("chainsaw.ChainsawGuiUtil", "System.Object", {
    generateItem = { 6, function(_, id, count, durability, ammo, ammo_count)
        local item
        if id >= 4000000 then
            item = mock.new("chainsaw.Item", { id = id, count = count, ammo_list = { 112800000 + (id // 1000) % 100 }, mag = 10,
                loaded = ammo_count, ammo = ammo })
        else
            item = mock.new("chainsaw.Item", { id = id, count = count, stack = 50 })
        end
        world.generated[#world.generated + 1] = item
        return item
    end, nil, { static = true } },
})
mock.class("chainsaw.InventoryController", "System.Object", {
    ["add(chainsaw.Item, chainsaw.InventorySlotType)"] = { 2, function(self, item)
        self.added = self.added or {}
        if #self.added >= (self.room or 99) then return mock.new("chainsaw.AddResult", { __fields = { AddCount = 0 } }) end
        self.added[#self.added + 1] = item
        return mock.new("chainsaw.AddResult", { __fields = { AddCount = item.count } })
    end },
})
mock.class("chainsaw.AddResult", "System.Object", {}, { AddCount = "i" })

local Game = require("re4coop.game")
local clock = { t = 0 }
local game = Game.new(function() end, function() return clock.t end)

-- The game's main menu.
local function make_window(acts)
    local list = {}
    for _, a in ipairs(acts) do
        list[#list + 1] = mock.new("chainsaw.MainMenuGuiBehavior.MenuItem", { __fields = { _ActionType = a } })
    end
    local scroll = mock.new("via.gui.ScrollList", { rows = {} })
    local banner = mock.new("chainsaw.MainMenuGuiBehavior", {})
    local beh = mock.new("chainsaw.MainMenuGuiBehavior", { __fields = {
        _MenuList = mock.typed_array("chainsaw.MainMenuGuiBehavior.MenuItem", list), ModeSelectList = scroll,
        RequiemBannerBehavior = banner, isDecided = false } })
    scroll.owner = beh
    return beh, scroll, banner
end

local beh, scroll, banner = make_window({ 0, 1, 2, 3, 4 })
world.menu_state = mock.new("chainsaw.GameStateMainMenu", { phase = 9 })

local LABELS = { [0x4D50] = "Multijugador", [0x4D51] = "Host Game", [0x4D52] = "Join Game", [0x4D53] = "Multiplayer Options",
    [0x4D54] = "Back" }
local want = { mode = "main", covered = false, decided = {}, cancels = 0 }
local ok = game:install_menu_hooks({ entry = 0x4D50, section = { 0x4D51, 0x4D52, 0x4D53, 0x4D54 }, labels = LABELS,
    mode = function() return want.mode end, covered = function() return want.covered end,
    on_decide = function(a) want.decided[#want.decided + 1] = a end,
    on_cancel = function() want.cancels = want.cancels + 1 end })

-- One game frame: GameStateMainMenu.update (game_save.lua's hook sees it; phase 9 opens the
-- window: applyGuiParam runs setup, then draw; then phase 10), the window's own update while
-- it is open, then the session's menu_tick.
local function frame(dt)
    local st = world.menu_state
    game.main_menu_state, game.menu_state_seen = st, clock.t
    if st.phase == 9 and not world.window_open then
        world.window_open = true
        beh:call("setup")
        beh:call("draw")
        st.phase = 10
    end
    if world.window_open then beh:call("lateUpdateOnActive") end
    game:menu_tick(want)
    clock.t = clock.t + (dt or 0.1)
end

local function frames(n, dt)
    for _ = 1, n do frame(dt) end
end

local function actions_in(arr)
    local out = {}
    for _, e in ipairs(items_of(arr)) do out[#out + 1] = e.__fields._ActionType end
    return table.concat(out, ",")
end

local function actions(b) return actions_in((b or beh).__fields.ActualMenuList) end

local function row_label(i, s) return (s or scroll).rows[i].label.msg end

T.run("hooks_installed", function()
    T.eq(ok, true, "four hooks")
    T.eq(game:capabilities().menu_entries.ok, true, "capability")
end)

T.run("multijugador_above_options", function()
    frame() -- the title: the game opens the menu
    T.eq(world.window_open, true, "the window is open")
    T.eq(actions(), "0,1,2,19792,3,4", "our entry before Options, in the list setup() built")
    T.eq(scroll.count, 6, "six rows")
    T.eq(scroll.max, 6, "six row objects")
    T.eq(scroll.count_calls, 1, "the list was sized once, by setup() itself")
    T.eq(scroll.cursor_sets, nil, "the cursor untouched")
    T.eq(row_label(4), "Multijugador", "our label")
    T.eq(row_label(5), "Opciones", "the game's own")
    T.eq(row_label(1), "Historia", "the game's own")
    T.eq(scroll.rows[4].const.msg, "~", "other texts of the row untouched")
    T.eq(scroll.rows[4].badge.msg, "", "badge untouched (label text learned from the game's rows)")
    beh:call("draw") -- a later selection change
    T.eq(row_label(4), "Multijugador", "kept after every draw")
    T.eq(game:capabilities().menu_list.ok, true, "menu_list")
    frames(3)
    T.eq(game.menu.counters.swaps, 0, "nothing swapped while nothing changes")
end)

T.run("choosing_our_entry_is_ours", function()
    scroll.selected = 3
    world.decide = true
    beh:call("lateUpdateOnActive")
    T.eq(want.decided[1], 0x4D50, "the session got Multijugador")
    T.eq(world.menu_state.native_decisions, nil, "the game's switch never saw it")
    scroll.selected = 4
    beh.__fields.isDecided = false
    world.decide = true
    beh:call("lateUpdateOnActive")
    T.eq(world.menu_state.native_decisions, 1, "the game's own Options still go to the game")
end)

T.run("our_section_replaces_the_entries", function()
    beh.__fields.isDecided = true -- Multijugador decided
    scroll.selected = 5           -- the cursor on Exit (index 5), past the end of our section
    want.mode = "mp"
    frame()
    T.eq(actions(), "19793,19794,19795,19796", "Host Game, Join Game, Multiplayer Options, Back")
    T.eq(row_label(1), "Host Game", "labels")
    T.eq(row_label(4), "Back", "labels")
    T.eq(scroll.rows[1].badge.msg, "", "the label text the game's rows taught")
    T.eq(scroll.selected, 0, "cursor on the first")
    T.eq(scroll.max_selected_seen == nil or scroll.max_selected_seen < 4, true, "never past the end of the shorter list")
    T.eq(beh.__fields.isDecided, false, "the menu takes input again")
    T.eq(world.window_open, true, "the window stays open")
    T.eq(actions_in(beh.__fields._MenuList), "19793,19794,19795,19796", "the next opening builds our section too")
    T.eq(world.menu_state.native_decisions, 1, "the game decided nothing")
    world.triggers[1883353458] = true -- Cancel
    beh:call("lateUpdateOnActive")
    world.triggers[1883353458] = nil
    T.eq(want.cancels, 1, "Cancel in our section goes back")
    want.mode = "main"
    frame()
    T.eq(actions(), "0,1,2,19792,3,4", "the game's entries again (the list setup() built)")
    T.eq(scroll.selected, 3, "cursor back on Multijugador")
    T.eq(row_label(5), "Opciones", "their texts")
    T.eq(game.menu.counters.swaps, 2, "two swaps")
end)

T.run("a_window_with_entries_the_game_leaves_out", function()
    -- A new window (back on the title after playing) whose _MenuList has a store entry the game
    -- never shows (9): our swap back uses the list the game built, without it.
    local b2, s2 = make_window({ 0, 1, 2, 6, 9, 3, 4 })
    local old_beh, old_scroll = beh, scroll
    beh, scroll = b2, s2
    world.window_open = false
    world.menu_state.phase = 9
    frame()
    T.eq(actions(), "0,1,2,6,19792,3,4", "its own entries with ours, as setup() keeps them")
    T.eq(row_label(5), "Multijugador", "its label text learned again")
    scroll.selected = 4
    want.mode = "mp"
    frame()
    T.eq(actions(), "19793,19794,19795,19796", "our section")
    want.mode = "main"
    frame()
    T.eq(actions(), "0,1,2,6,19792,3,4", "back: still without the entry the game leaves out")
    T.eq(scroll.selected, 4, "on Multijugador")
    beh, scroll = old_beh, old_scroll
    world.window_open = false
    world.menu_state.phase = 9
    frames(2)
    T.eq(actions(), "0,1,2,19792,3,4", "the first window again")
end)

T.run("a_swap_that_fails_is_not_tried_again_until_the_next_choice", function()
    local list_ctrl = beh.__fields.ModeSelectList
    beh.__fields.ModeSelectList = nil -- something the swap needs is missing
    want.mode = "mp"
    frame()
    T.eq(game:capabilities().menu_list.ok, false, "reported")
    local file = mock.files["re4coop_menu.json"]
    local last = file and file.snapshots[#file.snapshots]
    T.eq(last and last.reason, "swap failed", "what the menu looked like is in re4coop_menu.json")
    T.eq(beh.__fields.isDecided, false, "the menu takes input")
    local swaps = game.menu.counters.swaps
    frames(10)
    T.eq(game.menu.counters.swaps, swaps, "not tried again and again")
    T.eq(actions(), "0,1,2,19792,3,4", "the menu as it was")
    beh.__fields.ModeSelectList = list_ctrl
    scroll.selected = 3
    world.decide = true -- Multijugador chosen again
    frame()
    T.eq(actions(), "19793,19794,19795,19796", "a new choice: swapped")
    want.mode = "main"
    frame()
    T.eq(actions(), "0,1,2,19792,3,4", "back")
end)

T.run("snapshot_after_an_opening", function()
    world.window_open = false
    world.menu_state.phase = 9
    frames(25) -- 2.5 s after the opening
    local file = mock.files["re4coop_menu.json"]
    local last = file and file.snapshots[#file.snapshots]
    T.eq(last and last.reason, "opened", "written")
    T.eq(last and last.applied, "main", "mode")
    T.eq(last and table.concat(last.actual, ","), "0,1,2,19792,3,4", "the list")
    T.eq(last and table.concat(last.menu_list, ","), "0,1,2,19792,3,4", "what it was built from")
    T.eq(last and last.scroll and last.scroll.count, 6, "rows")
    T.eq(last and last.scroll and #last.scroll.rows, 6, "every row")
    T.eq(last and last.phase, 10, "phase")
    T.eq(#file.snapshots <= 8, true, "a few kept")
end)

T.run("a_menu_open_before_the_script_gets_our_entries", function()
    -- Reset Scripts with the menu up: the window's update is seen, setup() never was; the game's
    -- own list (with an entry it leaves out) is what the window has.
    local native = {}
    for _, a in ipairs({ 0, 1, 2, 9, 3, 4 }) do
        native[#native + 1] = mock.new("chainsaw.MainMenuGuiBehavior.MenuItem", { __fields = { _ActionType = a } })
    end
    beh.__fields._MenuList = mock.typed_array("chainsaw.MainMenuGuiBehavior.MenuItem", native)
    local m = game.menu
    m.applied, m.base_of, m.base, m.built, m.live = nil, nil, nil, {}, {}
    m.counters.setups = 0
    frame()
    T.eq(m.applied, "main", "our list")
    T.eq(actions(), "0,1,2,19792,3,4", "with our entry, without what isAvliableAction refuses")
    T.eq(row_label(4), "Multijugador", "labelled")
end)

T.run("covered_menu_takes_no_input_and_is_never_hidden", function()
    want.covered = true
    game:menu_tick(want)
    T.eq(beh.visible, nil, "the menu window is never hidden (our backdrop covers it)")
    T.eq(banner.visible, nil, "nor its banner")
    local before = beh.updates or 0
    world.decide = true
    beh:call("lateUpdateOnActive")
    T.eq(beh.updates or 0, before, "its update skipped")
    T.eq(world.decide, true, "nothing decided under our screen")
    world.decide = false
    want.covered = false
    beh.__fields.isDecided = true
    game:menu_tick(want)
    T.eq(beh.__fields.isDecided, false, "it takes input again")
end)

T.run("the_menu_is_found_again_after_a_long_lobby", function()
    -- 0.11.0: the menu window did not update for a while under the lobby and was forgotten.
    want.covered = true
    game:menu_tick(want)
    for i = 1, 30 do
        clock.t = clock.t + 0.5           -- 15 s in the lobby: the window's own update not seen...
        game.menu_state_seen = clock.t    -- ...the main menu state's update is (game_save.lua's hook)
        game:menu_tick(want)
    end
    want.covered = false
    beh.__fields.isDecided = true
    T.eq(game:menu_tick(want), true, "the menu is still known")
    T.eq(beh.__fields.isDecided, false, "and takes input again")
    T.eq(beh.visible, nil, "never hidden")
end)

T.run("menu_commands", function()
    world.triggers[3786011693] = true
    world.triggers[2450535976] = true
    local cmds = game:gui_commands()
    T.eq(table.concat(cmds, ","), "decide,down", "decide and down")
    world.triggers = {}
end)

T.run("new_game_from_a_chapter_start", function()
    local st = world.menu_state
    local r, why = game:menu_start_new(9, 30)
    T.eq(r, true, "started: " .. tostring(why))
    T.eq(st:read_byte(0x80), 1, "_SelectedCampaignKey has a value")
    T.eq(st:read_dword(0x84), 9, "chapter 4's start point")
    T.eq(st.__fields["<StoryMenuSelected>k__BackingField"], 4, "as New Game")
    T.eq(st.__fields["<ModeMenuSelected>k__BackingField"], 0, "the story")
    T.eq(st.difficulty, 30, "difficulty")
    T.eq(st.phase, 35, "StartPointDecided")
    local closed = world.singletons["chainsaw.GuiManager"].closed
    T.eq(closed and closed[1], 5, "the menu window closed")
    local r2 = game:menu_start_new(9, 30)
    T.eq(r2, nil, "not twice (the menu is busy)")
end)

T.run("loading_screen_and_saves", function()
    T.eq(game:loading_screen(), false, "no loading screen")
    world.loading_open = true
    T.eq(game:loading_screen(), true, "loading screen up")
    world.loading_open = false
    local info = game:save_slot_info(18)
    T.eq(info.empty, false, "slot 18 holds a save")
    T.eq(info.chapter_id, 23200, "chapter")
    T.eq(info.difficulty, 30, "difficulty")
    T.eq(game:save_slot_info(19).empty, true, "slot 19 empty")
end)

T.run("loadout_into_the_case", function()
    local ctrl = mock.new("chainsaw.InventoryController", {})
    game.player_inventory_controller = function() return ctrl end
    game.inventory_open = function() return false end
    game.item_name = function(_, id) return "Item " .. id end
    local r = game:give_loadout({ 4002, 4100 }, 2)
    T.check(r ~= nil, "given")
    T.eq(#r.given, 2, "two weapons")
    T.eq(#ctrl.added, 6, "two weapons and two stacks of ammo each")
    T.eq(ctrl.added[1].loaded, 10, "the weapon comes loaded")
    T.eq(ctrl.added[1].ammo, 112800002, "with its own ammo")
    T.eq(ctrl.added[2].count, 50, "full stacks")
    local small = mock.new("chainsaw.InventoryController", { room = 1 })
    game.player_inventory_controller = function() return small end
    local r2 = game:give_loadout({ 4002, 4100 }, 1)
    T.eq(r2.full > 0, true, "what does not fit is counted")
    game.inventory_open = function() return true end
    T.eq(game:give_loadout({ 4002 }, 1), nil, "not while the case is open")
end)

T.finish()
