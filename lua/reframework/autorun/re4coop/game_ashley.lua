-- RE4 (2023) adapter, part 5: Ashley. Installed into game.lua's Game class
-- (require("re4coop.game_ashley").install(Game, helpers)); ashley_sync.lua talks to the game
-- only through these methods.
--
-- What re4.exe does with Ashley (docs/RESEARCH.md 3.23, read with REA):
--   * She is the partner character ch2_a1z0 (CharacterKindID 200030): a PartnerBaseContext in
--     CharacterManager.PartnerContextList (getPartnerContextRef returns the first partner).
--   * Her AI is her head (Ch2a1z0HeadUpdater, a PartnerHeadUpdater): it follows the player it
--     reads from CharacterManager's player list (updateFollowTargetPosition), and its action
--     unit (PartnerNpcActionUpdaterUnit.updateKidnapped) rewrites IsPermitKidnapped (+0x470)
--     every frame. Enemies grab her only while that flag is set
--     (Ch1c0NPCTargetDriver_Ch2a1z0.startTarget).
--   * CharacterContext.setTransform(pos, rot) is the game's own character teleport (stores the
--     transform and tells every listener of the context, the body among them).
--   * Other Ashleys: a scripted "doll" NPC (CharacterManager.DollNpcContextList, a
--     DollNpcBaseContext, spawned by a DollNpcSpawnParam) or a second partner can be of her
--     kind too. Each character comes from a level spawn param; its invalidateSpawn(true)
--     (0x1424edb70) sets the Invalidated status bit, and updateSpawn (0x142559670) then destroys
--     the character and keeps it from spawning while that spawn param lives (the game's own
--     removal; the enemy sync's enemy_erase uses it too).
--
-- A puppet (the partner's game runs her): her head stops updating (she no longer thinks,
-- follows or reacts by herself), her animation state machine is off, IsPermitKidnapped and
-- IsPermitAttacked are cleared (enemies of our game leave her alone; with her head off nothing
-- sets them again) and her HitPoint takes no damage. Her transform is written like an enemy
-- puppet's (game_enemies.lua: body_set_transform).
--
-- Her animation (docs/RESEARCH.md 3.23, "Ashley's animation"). With her animation state machine
-- off, nothing in our game changes her motion but us, so the puppet gets everything the owner's
-- motion plays with:
--   * Every layer (up to 8): motion bank and id, frame and speed, and its blend rate, joint mask
--     and blend mode (her upper-body and action layers are mixed in with them).
--   * Motion.TargetBankType (+0x300): which variant of a bank is used. Her state machine writes
--     it all the time (PartnerBehaviorTreeAction_MFSM_OverwriteBankType.onUpdate 0x142388310:
--     weapon category + 1 | Battle, Water, Situation, Vital_Caution...), and a motion only in a
--     variant our game has not selected cannot be found - changeMotion then plays nothing new.
--   * The dynamic motion banks (via.motion.DynamicMotionBank: a motlist and the bank it stands
--     for) the owner's game added to her for an action or a gimmick
--     (CharacterDynamicMotionBankAttacher -> MotionController.addDynamicMotionBank 0x140f81bd0).
--     The puppet loads the same motlists and adds them the same way; they go again when she
--     stops being a puppet.

local M = {}

local ASHLEY_KIND = 200030 -- chainsaw.CharacterKindID.ch2_a1z0
local ANIM_DRIVERS = { ["via.motion.MotionFsm2"] = true, ["via.motion.MotionFsm"] = true }
local ASHLEY_LAYERS = 8
local FRAME_TOLERANCE = 4.0     -- frames a puppet's layer may drift before it is moved
local SPEED_TOLERANCE = 0.02
local BLEND_TOLERANCE = 0.02
local MOTION_BLEND_FRAMES = 6.0 -- interpolation frames when a layer changes motion
local MISSING_RETRY = 0.5       -- seconds between attempts at a motion our game could not find
local CHANGE_MOTION = "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"
local MOTION_CONTROLLER = "chainsaw.MotionController"
local DYNAMIC_BANK = "via.motion.DynamicMotionBank"
local MOTLIST = "via.motion.MotionListResource"
-- chainsaw.Npc.State bits during which she cannot change hands: Down, Rescue, ReactionBearTrap,
-- ReactionGrapple, IronBallCrane, GrappleHelp, GrappleEscape, HidingLocker, CatchLegHoldTrap,
-- UseGmHandle, UseGmPuzzleChair.
local BUSY_STATES = 1 | 131072 | 67108864 | 134217728 | (1 << 48) | (1 << 49) | (1 << 50) | (1 << 54) | (1 << 55)
    | (1 << 57) | (1 << 58)

function M.install(Game, H)
    local singleton, address_of, type_name_of = H.singleton, H.address_of, H.type_name_of
    local v3, q4 = H.v3, H.q4
    local CHARACTER_MANAGER = H.CHARACTER_MANAGER

    local function is_ashley(self, ctx)
        return ctx ~= nil and tonumber(self:call(ctx, "get_KindID")) == ASHLEY_KIND
    end

    -- How her puppet's animation went (Diagnostics).
    local function anim_stats(self)
        local st = self.ashley_anim
        if st == nil then
            st = { changes = 0, seeks = 0, blends = 0, masks = 0, missing = 0, failed = 0, bank_types = 0, banks = 0 }
            self.ashley_anim = st
        end
        return st
    end
    local remove_bank -- (defined with the dynamic motion banks below)

    -- The locks a puppet keeps: no grabbing, no attacks, no damage from our game.
    local function lock(self, ctx, hp)
        pcall(ctx.call, ctx, "set_IsPermitKidnapped", false)
        pcall(ctx.call, ctx, "set_IsPermitAttacked", false)
        if hp ~= nil then pcall(hp.call, hp, "set_NoDamage", true) end
    end

    -- Every character of her kind in our game: { ctx, addr, doll } - the partners first, then
    -- the doll NPCs.
    local function all_ashleys(self, cm)
        local out, seen = {}, {}
        local function walk(list, doll)
            local n = list and tonumber(self:call(list, "get_Count")) or 0
            for i = 0, n - 1 do
                local ctx = self:call(list, "get_Item", i)
                local addr = ctx and address_of(ctx)
                if addr ~= nil and not seen[addr] and is_ashley(self, ctx) then
                    seen[addr] = true
                    out[#out + 1] = { ctx = ctx, addr = addr, doll = doll }
                end
            end
        end
        walk(self:call(cm, "get_PartnerContextList"), false)
        walk(self:call(cm, "get_DollNpcContextList"), true)
        return out
    end

    -- Ashley's context in our game right now (the partner we already use while she exists,
    -- else the first partner of her kind), or nil. Never a doll.
    function Game:ashley_context()
        local cm = singleton(CHARACTER_MANAGER)
        if cm == nil then return nil end
        local keep = self.ashley_puppet and self.ashley_puppet.ctx_addr or self.ashley and self.ashley.ctx_addr
        local first = nil
        for _, a in ipairs(all_ashleys(self, cm)) do
            if not a.doll then
                if a.addr == keep then return a.ctx end
                first = first or a.ctx
            end
        end
        if first ~= nil then return first end
        local ctx = self:call(cm, "getPartnerContextRef")
        if is_ashley(self, ctx) then return ctx end
        return nil
    end

    -- The Ashleys of our game other than ours: { key, doll } each (a doll NPC of her kind, a
    -- second partner). Their contexts are kept for ashley_remove_extra.
    function Game:ashley_extras()
        local cm = singleton(CHARACTER_MANAGER)
        local out, ctxs = {}, {}
        self.ashley_extra_ctx = ctxs
        if cm == nil then return out end
        local main = self:ashley_context()
        local main_addr = main and address_of(main)
        for _, a in ipairs(all_ashleys(self, cm)) do
            if a.addr ~= main_addr then
                ctxs[a.addr] = a.ctx
                out[#out + 1] = { key = a.addr, doll = a.doll }
            end
        end
        return out
    end

    -- Removes another Ashley from our game: its spawn param's invalidateSpawn(true) despawns
    -- it (the game's own way; it does not spawn again while that spawn param lives - a reload of
    -- its area spawns it again, and then it is removed again). One without a spawn param of its
    -- own can no longer think, be grabbed, hurt or seen. "erased", "hidden" or false.
    function Game:ashley_remove_extra(key)
        local ctx = self.ashley_extra_ctx and self.ashley_extra_ctx[key]
        if ctx == nil then return false end
        local main = self:ashley_context()
        local main_sp = main and self:call(main, "get_CharacterSpawnParam")
        local sp = self:call(ctx, "get_CharacterSpawnParam")
        self.perf:crumb("ashley.extra", nil, true)
        if sp ~= nil and self:alive(sp) and (main_sp == nil or address_of(main_sp) ~= address_of(sp))
            and pcall(sp.call, sp, "invalidateSpawn", true) then
            self:cap("ashley_extra", true, "another Ashley removed (CharacterSpawnParam.invalidateSpawn)")
            return "erased"
        end
        local head = self:call(ctx, "get_HeadGameObject")
        if head ~= nil and self:go_alive(head) then pcall(head.call, head, "set_UpdateSelf", false) end
        lock(self, ctx, self:call(ctx, "get_HitPoint"))
        local body = self:call(ctx, "get_BodyGameObject")
        local n = 0
        if body ~= nil and self:go_alive(body) then
            for _, node in ipairs(self:collect_tree(body, 4)) do
                if pcall(node.go.call, node.go, "set_DrawSelf", false) then n = n + 1 end
            end
        end
        self:cap("ashley_extra", n > 0, ("another Ashley without a spawn param: head off, %d objects hidden"):format(n))
        return n > 0 and "hidden" or false
    end

    -- Her cached objects (body, transform, motion layers), renewed when her context or body
    -- changes (a reload, a costume change).
    function Game:ashley_info()
        local ctx = self:ashley_context()
        if ctx == nil then return nil end
        local addr = address_of(ctx)
        local body = self:call(ctx, "get_BodyGameObject")
        local body_addr = body and address_of(body)
        local info = self.ashley
        if info == nil or info.ctx_addr ~= addr or info.body_addr ~= body_addr then
            info = { ctx = ctx, ctx_addr = addr, body = body, body_addr = body_addr,
                transform = body and self:call(body, "get_Transform") or false, max_layers = ASHLEY_LAYERS }
            self.ashley = info
        end
        info.ctx = ctx
        if not info.transform or not self:alive(info.transform) then return nil end
        return info
    end

    -- { pos, rot, hp, max_hp, alive, kidnapped, busy, hidden, layers (full only) } or nil.
    function Game:ashley_read(full)
        local info = self:ashley_info()
        if info == nil then
            self:cap("ashley", false, "no Ashley in our game")
            return nil
        end
        local ctx = info.ctx
        local pos = v3(self:call(info.transform, "get_Position")) or v3(self:call(ctx, "get_Position"))
        if pos == nil then return nil end
        local st = { pos = pos, rot = q4(self:call(info.transform, "get_Rotation")) or { x = 0, y = 0, z = 0, w = 1 } }
        local hp = self:call(ctx, "get_HitPoint")
        st.hp = hp and tonumber(self:call(hp, "get_CurrentHitPoint")) or 0
        st.max_hp = hp and tonumber(self:call(hp, "get_DefaultHitPoint")) or 0
        st.alive = hp == nil or self:call(hp, "get_IsLive") ~= false
        st.kidnapped = self:call(ctx, "get_IsKidnapped") == true
        local state = math.tointeger(self:call(ctx, "get_PartnerState")) or 0
        st.busy = st.kidnapped or not st.alive or (state & BUSY_STATES) ~= 0
        st.hidden = info.body and self:call(info.body, "get_DrawSelf") == false or false
        if full then
            st.layers = self:ashley_read_layers(info)
            local motion = self:enemy_motion(info)
            st.bank_type = motion and tonumber(self:call(motion, "get_TargetBankType")) or nil
        end
        self:cap("ashley", true, type_name_of(ctx) or "?")
        return st
    end

    function Game:ashley_set_puppet(on)
        local p = self.ashley_puppet
        if not on then
            if p ~= nil then self:ashley_unpuppet() end
            return true
        end
        local info = self:ashley_info()
        if info == nil then return false end
        local ctx = info.ctx
        local hp = self:call(ctx, "get_HitPoint")
        if p ~= nil and p.ctx_addr == info.ctx_addr then
            lock(self, ctx, hp) -- every tick: nothing in our game may grab or hurt her
            return true
        end
        if p ~= nil then self:ashley_unpuppet() end -- another Ashley (our game reloaded)
        local head = self:call(ctx, "get_HeadGameObject")
        if head == nil or not self:go_alive(head) then
            self:cap("ashley_puppet", false, "no head GameObject")
            return false
        end
        self.perf:crumb("ashley.puppet", nil, true)
        if not pcall(head.call, head, "set_UpdateSelf", false) then
            self:cap("ashley_puppet", false, "head set_UpdateSelf failed")
            return false
        end
        local drivers = {}
        if self.settings.enemy_anim_lock ~= false and info.body then
            for _, comp in ipairs(self:components(info.body)) do
                local tname = type_name_of(comp)
                if tname ~= nil and ANIM_DRIVERS[tname] and self:call(comp, "get_Enabled") ~= false
                    and pcall(comp.call, comp, "set_Enabled", false) then
                    drivers[#drivers + 1] = comp
                end
            end
        end
        local no_damage = hp and self:call(hp, "get_NoDamage") == true or false
        lock(self, ctx, hp)
        self.ashley_puppet = { ctx_addr = info.ctx_addr, head = head, upd = self:call(ctx, "get_HeadUpdater"),
            drivers = drivers, hp = hp, no_damage = no_damage }
        self:cap("ashley_puppet", true, ("head off, %d animation driver(s) off, no grabs, no damage"):format(#drivers))
        return true
    end

    -- Our Ashley drawn (on) or not: her body and everything attached to it. Only what was drawn
    -- is hidden, and exactly that is drawn again.
    function Game:ashley_set_visible(on)
        local h = self.ashley_hidden
        if on then
            if h == nil then return true end
            self.ashley_hidden = nil
            self:draw_again(h.gos)
            return true
        end
        local info = self:ashley_info()
        if info == nil or not info.body then return false end
        if h ~= nil and h.ctx_addr == info.ctx_addr then return true end
        if h ~= nil then self:draw_again(h.gos) end -- (another Ashley now: our game reloaded)
        local gos = {}
        for _, node in ipairs(self:collect_tree(info.body, 4)) do
            if self:call(node.go, "get_DrawSelf") ~= false and pcall(node.go.call, node.go, "set_DrawSelf", false) then
                gos[#gos + 1] = node.go
            end
        end
        self.perf:crumb("ashley.hide", nil, true)
        self.ashley_hidden = { ctx_addr = info.ctx_addr, gos = gos }
        self:cap("ashley_hide", #gos > 0, ("%d objects hidden"):format(#gos))
        return true
    end

    -- She runs on her own again: head and animation back on, her HitPoint as it was, drawn. Her
    -- grab and attack permissions are the head's own: it sets them again from its next update.
    function Game:ashley_unpuppet()
        self:ashley_set_visible(true)
        local p = self.ashley_puppet
        if p == nil then return end
        self.ashley_puppet = nil
        self.perf:crumb("ashley.unpuppet", nil, true)
        for _, comp in ipairs(p.drivers or {}) do
            if self:alive(comp) then pcall(comp.call, comp, "set_Enabled", true) end
        end
        -- (the enemies' rule: a head not linked to a character is never switched on - see wake_head)
        if p.head ~= nil then self:wake_head({ go = p.head, upd = p.upd }) end
        if p.hp ~= nil then pcall(p.hp.call, p.hp, "set_NoDamage", p.no_damage) end
        -- Her animation as her own game had it: the banks we added go, her bank variant comes
        -- back (her state machine sets it again from its next update anyway).
        local info = self.ashley
        local motion = info and info.ctx_addr == p.ctx_addr and self:enemy_motion(info)
        if motion ~= nil and self:alive(motion) then
            for _, b in pairs(p.added or {}) do remove_bank(self, info, motion, b) end
            if p.bank_type then pcall(motion.call, motion, "set_TargetBankType", p.bank_type) end
        end
        if info ~= nil then info.asked = nil end
    end

    function Game:ashley_is_puppet()
        return self.ashley_puppet ~= nil
    end

    function Game:ashley_set_transform(pos, rot)
        local info = self:ashley_info()
        return info ~= nil and self:body_set_transform(info, pos, rot)
    end

    -- Her layers: motion bank and id, frame, speed, blend rate, joint mask, blend mode.
    function Game:ashley_read_layers(info)
        local out = {}
        for i = 0, self:layer_count(info) - 1 do
            local layer = self:enemy_layer(info, i)
            if layer == nil then break end
            local bank = tonumber(self:call(layer, "get_MotionBankID"))
            local mid = tonumber(self:call(layer, "get_MotionID"))
            if bank == nil or mid == nil then break end
            out[#out + 1] = { bank = bank, id = mid, frame = tonumber(self:call(layer, "get_Frame")) or 0,
                speed = tonumber(self:call(layer, "get_Speed")) or 1,
                blend = tonumber(self:call(layer, "get_BlendRate")),
                mask = tonumber(self:call(layer, "get_JointMaskID")),
                mode = tonumber(self:call(layer, "get_BlendMode")) }
        end
        return #out > 0 and out or nil
    end

    -- Her motion's bank variant (Motion.TargetBankType) as the owner's.
    function Game:ashley_set_bank_type(value)
        local info = self:ashley_info()
        local motion = info and self:enemy_motion(info)
        if motion == nil or value == nil then return false end
        local cur = tonumber(self:call(motion, "get_TargetBankType"))
        if cur == value then return true end
        local p = self.ashley_puppet
        if p ~= nil and p.bank_type == nil then p.bank_type = cur or false end
        local ok = pcall(motion.call, motion, "set_TargetBankType", value)
        if ok then anim_stats(self).bank_types = anim_stats(self).bank_types + 1 end
        return ok
    end

    -- Plays the owner's animation on our puppet. First the bank variant (so her motions are
    -- found), then per layer: another motion -> changeMotion (blended); the same one drifted ->
    -- set_Frame; speed, blend rate, joint mask and blend mode as the owner's. A motion asked for
    -- that the layer still does not play is one our game could not find (counted; asked again
    -- every MISSING_RETRY, e.g. once its motlist is here).
    function Game:ashley_set_anim(layers, bank_type)
        local info = self:ashley_info()
        if info == nil then return false end
        local stats = anim_stats(self)
        if bank_type ~= nil then self:ashley_set_bank_type(bank_type) end
        local now = self.clock()
        info.asked = info.asked or {}
        for i = 1, math.min(#layers, self:layer_count(info)) do
            local t = layers[i]
            local layer = self:enemy_layer(info, i - 1)
            if layer == nil then break end
            local bank = tonumber(self:call(layer, "get_MotionBankID"))
            local mid = tonumber(self:call(layer, "get_MotionID"))
            local asked = info.asked[i]
            if bank ~= t.bank or mid ~= t.id then
                local again = asked ~= nil and asked.bank == t.bank and asked.id == t.id
                if again and not asked.missing then
                    asked.missing = true
                    stats.missing = stats.missing + 1
                    stats.last_missing = ("bank %d motion %d (bank type %s)"):format(t.bank, t.id, tostring(bank_type))
                end
                if not again or now - asked.at >= MISSING_RETRY then
                    self.perf:crumb("ashley.motion")
                    if pcall(function() layer:call(CHANGE_MOTION, t.bank, t.id, t.frame or 0.0, MOTION_BLEND_FRAMES, 2, 0) end) then
                        stats.changes = stats.changes + 1
                        if again then asked.at = now else info.asked[i] = { bank = t.bank, id = t.id, at = now } end
                    else
                        stats.failed = stats.failed + 1
                        self:cap("ashley_motion", false, "changeMotion failed")
                        return false
                    end
                end
            else
                info.asked[i] = nil
                local frame = tonumber(self:call(layer, "get_Frame"))
                if frame ~= nil and math.abs(frame - (t.frame or 0)) > FRAME_TOLERANCE
                    and self:layer_seek(layer, t.frame or 0) then
                    stats.seeks = stats.seeks + 1
                end
            end
            if t.speed ~= nil then
                local speed = tonumber(self:call(layer, "get_Speed"))
                if speed ~= nil and math.abs(speed - t.speed) > SPEED_TOLERANCE then pcall(layer.call, layer, "set_Speed", t.speed) end
            end
            if t.blend ~= nil then
                local blend = tonumber(self:call(layer, "get_BlendRate"))
                if blend ~= nil and math.abs(blend - t.blend) > BLEND_TOLERANCE
                    and pcall(layer.call, layer, "set_BlendRate", t.blend) then
                    stats.blends = stats.blends + 1
                end
            end
            if t.mask ~= nil and tonumber(self:call(layer, "get_JointMaskID")) ~= t.mask
                and pcall(layer.call, layer, "set_JointMaskID", t.mask) then
                stats.masks = stats.masks + 1
            end
            if t.mode ~= nil and tonumber(self:call(layer, "get_BlendMode")) ~= t.mode then
                pcall(layer.call, layer, "set_BlendMode", t.mode)
            end
        end
        if not self.caps.ashley_motion or not self.caps.ashley_motion.ok then
            self:cap("ashley_motion", true, "layers (motion, frame, speed, blend, joint mask, mode) + TargetBankType")
        end
        return true
    end

    -- A dynamic motion bank's identity: its motlist and the bank it stands for.
    local function bank_key(b)
        return ("%s|%d|%d|%d"):format(b.path or "", b.bank_id or 0, b.bank_type or 0, b.mask_bit or 0)
    end
    M.bank_key = bank_key

    local function read_bank(self, b)
        local holder = self:call(b, "get_MotionList")
        local path = holder and self:call(holder, "get_ResourcePath")
        if type(path) ~= "string" or path == "" then return nil end
        local flags = (self:call(b, "get_OverwriteBankID") == true and 1 or 0)
            | (self:call(b, "get_OverwriteBankType") == true and 2 or 0)
            | (self:call(b, "get_OverwriteBankTypeMaskBit") == true and 4 or 0)
        return { path = path, bank_id = tonumber(self:call(b, "get_BankID")) or 0,
            bank_type = tonumber(self:call(b, "get_BankType")) or 0,
            mask_bit = tonumber(self:call(b, "get_BankTypeMaskBit")) or 0,
            order = tonumber(self:call(b, "get_Order")) or 0, flags = flags }
    end

    -- The dynamic motion banks her motion has now: { banks = {...}, key }.
    function Game:ashley_read_banks()
        local info = self:ashley_info()
        local motion = info and self:enemy_motion(info)
        if motion == nil then return nil end
        local n = tonumber(self:call(motion, "getDynamicMotionBankCount")) or 0
        local banks, keys = {}, {}
        for i = 0, n - 1 do
            local b = self:call(motion, "getDynamicMotionBank", i)
            local e = b and read_bank(self, b)
            if e ~= nil then
                banks[#banks + 1] = e
                keys[#keys + 1] = bank_key(e)
            end
        end
        return { banks = banks, key = table.concat(keys, ";") }
    end

    local function motion_controller(self, info)
        if info.motion_controller == nil then
            info.motion_controller = (info.body and self:get_component(info.body, MOTION_CONTROLLER)) or false
        end
        return info.motion_controller or nil
    end

    -- A dynamic motion bank for `e`: its motlist loaded, the bank it stands for set.
    local function make_bank(self, e)
        local holder = self:resource_holder(MOTLIST, e.path)
        if holder == nil then return nil end
        local ok, b = pcall(sdk.create_instance, DYNAMIC_BANK)
        if not ok or b == nil then
            local td = sdk.find_type_definition and sdk.find_type_definition(DYNAMIC_BANK)
            ok, b = pcall(function() return td:create_instance() end)
            if not ok or b == nil then return nil end
        end
        pcall(function() b = b:add_ref() end)
        local okset = pcall(function()
            b:call("set_MotionList", holder)
            b:call("set_BankID", e.bank_id)
            b:call("set_BankType", e.bank_type)
            b:call("set_BankTypeMaskBit", e.mask_bit)
            b:call("set_Order", e.order)
            b:call("set_OverwriteBankID", (e.flags & 1) ~= 0)
            b:call("set_OverwriteBankType", (e.flags & 2) ~= 0)
            b:call("set_OverwriteBankTypeMaskBit", (e.flags & 4) ~= 0)
        end)
        return okset and b or nil
    end

    -- Through her MotionController (the game's way), else straight into her motion's list.
    local function add_bank(self, info, motion, b)
        local mc = motion_controller(self, info)
        if mc ~= nil and pcall(mc.call, mc, "addDynamicMotionBank", b) then return true end
        local n = tonumber(self:call(motion, "getDynamicMotionBankCount")) or 0
        return pcall(motion.call, motion, "setDynamicMotionBankCount", n + 1)
            and pcall(motion.call, motion, "setDynamicMotionBank", n, b)
    end

    remove_bank = function(self, info, motion, b)
        local mc = motion_controller(self, info)
        if mc ~= nil and pcall(mc.call, mc, "removeDynamicMotionBank", b) then return true end
        local n = tonumber(self:call(motion, "getDynamicMotionBankCount")) or 0
        local list, found = {}, false
        local addr = address_of(b)
        for i = 0, n - 1 do
            local x = self:call(motion, "getDynamicMotionBank", i)
            if x ~= nil and address_of(x) == addr then found = true else list[#list + 1] = x end
        end
        if not found then return false end
        for i, x in ipairs(list) do pcall(motion.call, motion, "setDynamicMotionBank", i - 1, x) end
        return pcall(motion.call, motion, "setDynamicMotionBankCount", #list)
    end

    -- Our puppet gets the owner's dynamic motion banks (`banks`, identified by `key`): the ones
    -- her motion does not have yet are added; the ones we added that the owner's no longer has
    -- are taken away. Banks our own game gave her stay.
    function Game:ashley_set_banks(banks, key)
        local p = self.ashley_puppet
        local info = p and self:ashley_info()
        local motion = info and self:enemy_motion(info)
        if motion == nil then return false end
        if p.banks_key == key then return true end
        local want = {}
        for _, e in ipairs(banks) do want[bank_key(e)] = e end
        p.added = p.added or {}
        for k, b in pairs(p.added) do
            if not want[k] then
                remove_bank(self, info, motion, b)
                p.added[k] = nil
            end
        end
        local have = {}
        local mine = self:ashley_read_banks()
        for _, e in ipairs(mine and mine.banks or {}) do have[bank_key(e)] = true end
        local all = true
        for k, e in pairs(want) do
            if not have[k] and p.added[k] == nil then
                local b = make_bank(self, e)
                if b ~= nil and add_bank(self, info, motion, b) then
                    p.added[k] = b
                    anim_stats(self).banks = anim_stats(self).banks + 1
                else
                    all = false
                end
            end
        end
        if all then p.banks_key = key end
        self:cap("ashley_banks", all, all and "the owner's dynamic motion banks (MotionController.addDynamicMotionBank)"
            or "a dynamic motion bank could not be added")
        return all
    end

    -- Never kills: our game does not decide whether she goes down.
    function Game:ashley_set_hp(value)
        local info = self:ashley_info()
        local hp = info and self:call(info.ctx, "get_HitPoint")
        if hp == nil then return false end
        return self:write_hp(hp, math.max(1, math.floor(value)))
    end

    -- The game's own character teleport (CharacterContext.setTransform), and her body there too.
    function Game:ashley_warp(pos, rot)
        local info = self:ashley_info()
        if info == nil then return false end
        rot = rot or { x = 0, y = 0, z = 0, w = 1 }
        self.perf:crumb("ashley.warp", nil, true)
        local ok = pcall(function()
            info.ctx:call("setTransform(via.vec3, via.Quaternion)", Vector3f.new(pos.x, pos.y, pos.z),
                Quaternion.new(rot.w, rot.x, rot.y, rot.z))
        end)
        local moved = self:body_set_transform(info, pos, rot)
        self:cap("ashley_warp", ok or moved, ok and "CharacterContext.setTransform" or "transform + CharacterController.warp")
        return ok or moved
    end

    -- Session over / partner gone: she is ours again.
    function Game:ashley_restore()
        self:ashley_unpuppet()
    end

    -- Our game reloaded: put back what we changed (if it still exists) and forget her objects.
    function Game:reload_ashley()
        self:ashley_unpuppet()
        self.ashley = nil
        self.ashley_extra_ctx = nil
    end
end

return M
