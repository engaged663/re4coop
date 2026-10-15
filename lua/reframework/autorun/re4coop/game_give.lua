-- RE4 (2023) adapter, part 3: giving an item to the partner from the attache case. Installed
-- into game.lua's Game class (require("re4coop.game_give").install(Game, helpers)); give_sync.lua
-- talks to the game only through these methods.
--
-- How the game does it (re4.exe, docs/RESEARCH.md 3.12):
--   * The command list of the item under the cursor is InventoryManager.getItemCommandMenu
--     (GetCommandMenuArgs {Item, ...}): a Dictionary<ItemCommandType, Boolean> (enabled), drawn
--     in insertion order by ItemCommandMenuGui. The enum is fixed, so the "give" entry is a
--     command type the attache case never offers (ItemCommandType.Store), added last, its label
--     replaced where ItemCommandGui.drawCommand writes it (_CommandText).
--   * ItemWindowGuiState_AttacheCaseSelectCommand.decide runs the chosen command; a type it has
--     no case for ends in transitAttacheCaseDefault (back to the case), so the game itself does
--     nothing for ours: the pre-hook does the giving.
--   * Taking the item out is what the game's own discard does (AttacheCaseDiscard.onDecided):
--     CsInventory.remove(Guid) and the case GUI's VirtualInventory.remove(Guid).
--   * The partner's game makes the item with ChainsawGuiUtil.generateItem (the factory gimmicks
--     that hand out items use) and puts it in the case with CsInventoryController.add(Item,
--     Default): AddItemResult.AddCount says how many fitted.

local Guard = require("re4coop.hookguard")
local M = {}

local GIVE_COMMAND = 13 -- chainsaw.ItemCommandType.Store: never offered by the attache case
local SLOT_DEFAULT = 0  -- chainsaw.InventorySlotType.Default
-- chainsaw.ItemType that can change hands: Ammo, Hurb (recovery), Parts (weapon attachments),
-- Powder (resources), Throwing (grenades), Treasure. Never key items, weapons, knives, money,
-- treasures with gems set in them or anything unique.
M.GIVABLE = { [1] = true, [2] = true, [3] = true, [4] = true, [7] = true, [9] = true }
M.GIVE_COMMAND = GIVE_COMMAND

function M.install(Game, H)
    local singleton, find_type = H.singleton, H.find_type

    -- A hook argument or return value (a pointer) as a managed object, or nil.
    local function managed(v)
        if v == nil then return nil end
        if type(v) == "table" then return v end -- already an object (tests)
        local ok, o = pcall(sdk.to_managed_object, v)
        if ok and o ~= nil and (type(o) == "table" or type(o) == "userdata") then return o end
        return nil
    end

    local function static_call(type_name, method, ...)
        local td = find_type(type_name)
        local m = td and td:get_method(method)
        if m == nil then return nil end
        local ok, r = pcall(m.call, m, nil, ...)
        return ok and r or nil
    end

    -- ItemType of an ItemID (ItemIDDefine.getItemType, static).
    function Game:item_type(item_id)
        return tonumber(static_call("chainsaw.ItemIDDefine", "getItemType", item_id))
    end

    function Game:item_givable(item)
        if item == nil then return false end
        local id = tonumber(self:call(item, "get_ItemId"))
        local count = tonumber(self:call(item, "get_CurrentItemCount")) or 0
        return id ~= nil and count > 0 and M.GIVABLE[self:item_type(id) or -1] == true
    end

    -- give = { enabled() -> bool, label() -> string, on_give({item_id, count, durability}) }
    function Game:install_give_hooks(give)
        self.give = give
        if type(sdk) ~= "table" or sdk.hook == nil then
            self:cap("give_items", false, "sdk.hook unavailable")
            return false
        end
        local done = {}
        -- 1. The give entry, last in the command list of a givable item.
        local inv = find_type("chainsaw.InventoryManager")
        local menu_m = inv and inv:get_method("getItemCommandMenu")
        if menu_m ~= nil and pcall(Guard.hook, menu_m, function(args)
            self.give_menu_item = nil
            local a = managed(args[3])
            if a ~= nil then self.give_menu_item = self:call(a, "get_Item") or (a.get_field and a:get_field("Item")) end
        end, function(retval)
            pcall(self.add_give_entry, self, retval)
            return retval
        end) then done[#done + 1] = "menu" end
        -- 2. Its label.
        local cmd_gui = find_type("chainsaw.gui.commandmenu.ItemCommandGui")
        local draw_m = cmd_gui and cmd_gui:get_method("drawCommand")
        if draw_m ~= nil and pcall(Guard.hook, draw_m, function(args)
            self.give_draw = nil
            if tonumber(sdk.to_int64(args[3])) == GIVE_COMMAND and self.give_offered then
                self.give_draw = managed(args[2])
            end
        end, function(retval)
            local g = self.give_draw
            self.give_draw = nil
            if g ~= nil then pcall(self.label_give_entry, self, g) end
            return retval
        end) then done[#done + 1] = "label" end
        -- 3. Choosing it.
        local state = find_type("chainsaw.ItemWindowGuiState_AttacheCaseSelectCommand")
        local decide_m = state and state:get_method("decide")
        if decide_m ~= nil and pcall(Guard.hook, decide_m, function(args)
            pcall(self.on_give_decided, self, managed(args[2]))
        end, function(retval) return retval end) then done[#done + 1] = "decide" end
        local ok = #done == 3
        self:cap("give_items", ok, ok and "getItemCommandMenu / drawCommand / AttacheCaseSelectCommand.decide hooked"
            or ("only " .. table.concat(done, ", ")))
        return ok
    end

    function Game:add_give_entry(retval)
        self.give_offered = false
        local g = self.give
        if g == nil or not g.enabled() or not self:item_givable(self.give_menu_item) then return end
        local dict = managed(retval)
        if dict == nil then return end
        if self:call(dict, "ContainsKey", GIVE_COMMAND) == true then return end
        if self:call(dict, "Add", GIVE_COMMAND, true) == nil and self:call(dict, "ContainsKey", GIVE_COMMAND) ~= true then
            self:call(dict, "set_Item", GIVE_COMMAND, true)
        end
        self.give_offered = self:call(dict, "ContainsKey", GIVE_COMMAND) == true
    end

    function Game:label_give_entry(cmd_gui)
        local text = cmd_gui.get_field and cmd_gui:get_field("_CommandText")
        local label = self.give and self.give.label() or "Give to partner"
        if text ~= nil then self:call(text, "set_Message", label) end
    end

    -- The player chose a command in the attache case: ours takes the item out of the case and
    -- hands it to the partner (the game then goes back to the case on its own).
    function Game:on_give_decided(state)
        if state == nil or self.give == nil then return end
        local beh = self:call(state, "get__CommandMenuGuiBehavior")
        local menu = beh and beh.get_field and beh:get_field("_ItemCommandMenuGui")
        local cmd = menu and tonumber(self:call(menu, "get_CurrSelectedCommandType"))
        if cmd ~= GIVE_COMMAND then return end
        local param = state.get_field and state:get_field("_CurrEnterParam")
        local target = param and param.get_field and param:get_field("TargetID")
        local ctrl = self:give_inventory_controller(state)
        local item = ctrl and target and self:call(ctrl, "getItem(System.Guid)", target)
        if not self.give.enabled() or not self:item_givable(item) then
            self.give.on_refused("this item cannot be given")
            return
        end
        local ev = { item_id = tonumber(self:call(item, "get_ItemId")),
            count = tonumber(self:call(item, "get_CurrentItemCount")) or 1,
            durability = item.get_field and tonumber(item:get_field("_CurrentDurability")) or -1 }
        -- Out of the case, the way the game's discard does it.
        local inventory = ctrl.get_field and ctrl:get_field("<_CsInventory>k__BackingField")
        if inventory == nil or self:call(inventory, "remove(System.Guid)", target) == false then
            self.give.on_refused("the item could not be taken out of the case")
            return
        end
        local acm = singleton("chainsaw.AttacheCaseManager")
        local holder = acm and acm.get_field and acm:get_field("<AttacheCaseGuiDataHolder>k__BackingField")
        local virtual = holder and holder.get_field and holder:get_field("_Inventory")
        if virtual ~= nil then self:call(virtual, "remove(System.Guid)", target) end
        self.give.on_give(ev)
    end

    -- The case's inventory controller: the open item window's, else the player's own.
    function Game:give_inventory_controller(state)
        local ctrl = state and self:call(state, "get__InventoryController")
        if ctrl ~= nil then return ctrl end
        local beh = state and state.get_field and state:get_field("<_ControlBehavior>k__BackingField")
        ctrl = beh and self:call(beh, "get_CurrInventoryController")
        if ctrl ~= nil then return ctrl end
        local acm = singleton("chainsaw.AttacheCaseManager")
        local holder = acm and acm.get_field and acm:get_field("<AttacheCaseGuiDataHolder>k__BackingField")
        ctrl = holder and holder.get_field and holder:get_field("<CurrInventoryController>k__BackingField")
        if ctrl ~= nil then return ctrl end
        return self:player_inventory_controller()
    end

    -- Our player's attache case controller: PlayerEquipment (a component of the player's body)
    -- holds it; else ChainsawGuiUtil.getInventoryControllers(ContextID) - by its full signature:
    -- an overload with (CharacterKindID, Int32) shares the name - else the case GUI's.
    function Game:player_inventory_controller()
        local ctx = self:player_context()
        local body = self.player_body or (ctx and self:call(ctx, "get_BodyGameObject"))
        local eq = body and self.get_component and self:get_component(body, "chainsaw.PlayerEquipment")
        local ctrl = eq and (self:call(eq, "get_InventoryController")
            or (eq.get_field and eq:get_field("<InventoryController>k__BackingField")))
        if ctrl ~= nil then return ctrl, "PlayerEquipment" end
        local id = ctx and ctx.get_field and ctx:get_field("_ID")
        if id ~= nil then
            local info = static_call("chainsaw.ChainsawGuiUtil", "getInventoryControllers(chainsaw.ContextID)", id)
            ctrl = info and info.get_field and info:get_field("InventoryController")
            if ctrl ~= nil then return ctrl, "getInventoryControllers" end
        end
        local acm = singleton("chainsaw.AttacheCaseManager")
        local holder = acm and acm.get_field and acm:get_field("<AttacheCaseGuiDataHolder>k__BackingField")
        ctrl = holder and holder.get_field and holder:get_field("<CurrInventoryController>k__BackingField")
        if ctrl ~= nil then return ctrl, "AttacheCaseGuiDataHolder" end
        return nil
    end

    -- The item's name in the game's language (ItemManager.get_ItemMessageManager -
    -- not a singleton of its own - .getItemNameMsgId -> via.gui.message.get), or nil.
    function Game:item_name(item_id)
        local im = singleton("chainsaw.ItemManager")
        local mm = im and self:call(im, "get_ItemMessageManager")
        local guid = mm and self:call(mm, "getItemNameMsgId", item_id)
        if guid == nil then return nil end
        local s = static_call("via.gui.message", "get(System.Guid)", guid) or static_call("via.gui.message", "get", guid)
        if type(s) == "string" and s ~= "" then return s end
        return nil
    end

    -- Whether the item window (attache case) is open here: HighwayGuiManager.isItemWindowActive,
    -- the game's own test before it opens it for a pickup (its control behavior exists and is
    -- not waiting to open). Items wait until it is closed.
    function Game:inventory_open()
        local hw = singleton("chainsaw.HighwayGuiManager")
        if hw == nil then return false end
        return self:call(hw, "isItemWindowActive") == true
    end

    -- The partner's item into our case. Returns how many fitted (0..count), or nil and why when
    -- it cannot be tried now.
    function Game:give_receive(item_id, count, durability)
        if self:inventory_open() then return nil, "inventory open" end
        local ctrl, via = self:player_inventory_controller()
        if ctrl == nil then
            self:cap("give_receive", false, "our attache case controller was not found")
            return nil, "no inventory"
        end
        local item = static_call("chainsaw.ChainsawGuiUtil", "generateItem", item_id, count, durability or -1, -1, 0, false)
        if item == nil then
            self:cap("give_receive", false, "ChainsawGuiUtil.generateItem failed")
            return 0, "the item could not be made"
        end
        local r = self:call(ctrl, "add(chainsaw.Item, chainsaw.InventorySlotType)", item, SLOT_DEFAULT)
        if r == nil then
            self:cap("give_receive", false, "CsInventoryController.add failed")
            return 0, "the case did not take it"
        end
        local added = r.get_field and tonumber(r:get_field("AddCount")) or 0
        self:cap("give_receive", true, "into the case via " .. tostring(via))
        return math.max(0, math.min(count, added))
    end
end

return M
