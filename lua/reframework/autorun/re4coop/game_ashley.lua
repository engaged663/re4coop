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
--
-- A puppet (the partner's game runs her): her head stops updating (she no longer thinks,
-- follows or reacts by herself), her animation state machine is off, IsPermitKidnapped and
-- IsPermitAttacked are cleared (enemies of our game leave her alone; with her head off nothing
-- sets them again) and her HitPoint takes no damage. Her transform and animation layers are
-- written like an enemy puppet's (game_enemies.lua: body_set_transform / body_set_anim).

local M = {}

local ASHLEY_KIND = 200030 -- chainsaw.CharacterKindID.ch2_a1z0
local ANIM_DRIVERS = { ["via.motion.MotionFsm2"] = true, ["via.motion.MotionFsm"] = true }
local ASHLEY_LAYERS = 3
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

    -- Ashley's context in our game right now, or nil.
    function Game:ashley_context()
        local cm = singleton(CHARACTER_MANAGER)
        if cm == nil then return nil end
        local list = self:call(cm, "get_PartnerContextList")
        local n = list and tonumber(self:call(list, "get_Count")) or 0
        for i = 0, n - 1 do
            local ctx = self:call(list, "get_Item", i)
            if is_ashley(self, ctx) then return ctx end
        end
        local ctx = self:call(cm, "getPartnerContextRef")
        if is_ashley(self, ctx) then return ctx end
        return nil
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
        if full then st.layers = self:read_layers(info) end
        self:cap("ashley", true, type_name_of(ctx) or "?")
        return st
    end

    -- The locks a puppet keeps: no grabbing, no attacks, no damage from our game.
    local function lock(self, ctx, hp)
        pcall(ctx.call, ctx, "set_IsPermitKidnapped", false)
        pcall(ctx.call, ctx, "set_IsPermitAttacked", false)
        if hp ~= nil then pcall(hp.call, hp, "set_NoDamage", true) end
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

    -- She runs on her own again: head and animation back on, her HitPoint as it was. Her grab
    -- and attack permissions are the head's own: it sets them again from its next update.
    function Game:ashley_unpuppet()
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
    end

    function Game:ashley_is_puppet()
        return self.ashley_puppet ~= nil
    end

    function Game:ashley_set_transform(pos, rot)
        local info = self:ashley_info()
        return info ~= nil and self:body_set_transform(info, pos, rot)
    end

    function Game:ashley_set_anim(layers)
        local info = self:ashley_info()
        return info ~= nil and self:body_set_anim(info, layers)
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
    end
end

return M
