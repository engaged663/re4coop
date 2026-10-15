-- RE4 (2023) adapter, part 7: invincibility of our own player (a testing option; the session
-- turns it on when either player's Options ask for it). Installed into game.lua's Game class.
--
-- What the game offers (re4.exe, the il2cpp dump; docs/RESEARCH.md 3.30):
--   * chainsaw.HitPoint flags Invincible (+0x18), NoDamage (+0x19), NoDeath (+0x1a) and
--     Immortal (+0x1b): HitPoint.checkDead never kills with NoDamage, Immortal or NoDeath on.
--     Our player's are set every frame while invincible (the game may clear them: events,
--     reloads) and given back as they were when it ends; its HP is kept full.
--   * HitController.callbackCheckDamageHit(DamageInfo) - the character's own check that a hit
--     lands (a dodge, invincibility frames); HitManager.hitSetting stops there, before the
--     damage, the reaction and a grab (HitManager.requestGrapple). For our player's controller
--     it answers no: no enemy blow, grab, explosion or trap lands. (The client's game runs the
--     host's enemies' hits through the same check: they are blocked as dodged.)
--   * Deaths that do not go through HP: PlayerHeadUpdater.requestDead(DeadType, callback) (a
--     fall, drowning, an instant kill) and PlayerHeadUpdater.onDead(DamageInfo) on our player's
--     head are skipped, and GameOverMediator.requestGameOver (any game over) is refused.

local Guard = require("re4coop.hookguard")

local M = {}

local HIT_POINT_FLAGS = { "Invincible", "NoDamage", "NoDeath", "Immortal" }

function M.install(Game, H)
    local find_type, address_of = H.find_type, H.address_of

    local function hook_available()
        return type(sdk) == "table" and type(sdk.hook) == "function" and type(sdk.to_managed_object) == "function"
    end

    -- Our player's HitPoint, HitController and AI head (nil when there is no player).
    function Game:invincible_targets()
        local ctx = self:player_context()
        if ctx == nil then return nil end
        local body = self:call(ctx, "get_BodyGameObject")
        return {
            hp = self:call(ctx, "get_HitPoint"),
            hc = body and self:get_component(body, "chainsaw.HitController"),
            head = self:call(ctx, "get_HeadUpdater"),
        }
    end

    -- Every frame: our player is invincible (on) or as the game left it (off). Returns whether
    -- our player is invincible now.
    function Game:set_invincible(on)
        on = on == true
        local st = self.inv
        if st == nil then
            st = { stats = { blocked_hits = 0, blocked_deaths = 0, blocked_game_overs = 0, refills = 0 } }
            self.inv = st
        end
        if on and not st.hooks then self:install_invincible_hooks() end
        local t = self:invincible_targets()
        local hp = t and t.hp
        local hp_addr = address_of(hp)
        if not on then
            if st.on then self:restore_hit_point() end
            st.on, st.hc_addr, st.head_addr = false, nil, nil
            return false
        end
        if hp == nil then
            st.hc_addr, st.head_addr = nil, nil
            return false
        end
        if st.hp_addr ~= hp_addr then
            -- A new HitPoint (a reload, another character): its own flags are what we give back.
            if st.on then self:restore_hit_point() end
            st.saved = {}
            for _, f in ipairs(HIT_POINT_FLAGS) do st.saved[f] = self:call(hp, "get_" .. f) == true end
            st.hp_obj, st.hp_addr = hp, hp_addr
        end
        for _, f in ipairs(HIT_POINT_FLAGS) do
            if self:call(hp, "get_" .. f) ~= true then pcall(hp.call, hp, "set_" .. f, true) end
        end
        local cur = tonumber(self:call(hp, "get_CurrentHitPoint"))
        local max = tonumber(self:call(hp, "get_DefaultHitPoint"))
        if cur ~= nil and max ~= nil and max > 0 and cur < max and self:write_hp(hp, math.floor(max)) then
            st.stats.refills = st.stats.refills + 1
        end
        st.on = true
        st.hc_addr, st.head_addr = address_of(t.hc), address_of(t.head)
        self:cap("invincible", true, ("on: %d hits, %d deaths, %d game overs blocked"):format(st.stats.blocked_hits,
            st.stats.blocked_deaths, st.stats.blocked_game_overs))
        return true
    end

    -- Our player's HitPoint flags back to what they were before.
    function Game:restore_hit_point()
        local st = self.inv
        local hp = st and st.hp_obj
        if hp ~= nil and self:still_valid(hp) then
            for _, f in ipairs(HIT_POINT_FLAGS) do
                pcall(hp.call, hp, "set_" .. f, st.saved and st.saved[f] == true)
            end
        end
        st.hp_obj, st.hp_addr, st.saved = nil, nil, nil
    end

    function Game:invincible_stats()
        return self.inv and self.inv.stats or nil
    end

    function Game:install_invincible_hooks()
        local st = self.inv
        st.hooks = true
        if not hook_available() then
            self:cap("invincible", false, "sdk.hook unavailable (only the HitPoint flags)")
            return
        end
        local game = self
        local function ours(args, key)
            local s = game.inv
            if s == nil or not s.on or s[key] == nil then return false end
            local a
            pcall(function() a = sdk.to_int64(args[2]) end)
            return a == s[key]
        end
        -- Hits: our player's own check answers no.
        local hc_td = find_type("chainsaw.HitController")
        local okC, check = pcall(function() return hc_td and hc_td:get_method("callbackCheckDamageHit") end)
        if okC and check ~= nil then
            local skipped = false
            pcall(Guard.hook, check, function(args)
                skipped = false
                if ours(args, "hc_addr") then
                    skipped = true
                    st.stats.blocked_hits = st.stats.blocked_hits + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval)
                if skipped then
                    skipped = false
                    return sdk.to_ptr(0)
                end
                return retval
            end)
        end
        -- Deaths without a hit.
        local ph_td = find_type("chainsaw.PlayerHeadUpdater")
        for _, name in ipairs({ "requestDead", "onDead" }) do
            local okD, m = pcall(function() return ph_td and ph_td:get_method(name) end)
            if okD and m ~= nil then
                pcall(Guard.hook, m, function(args)
                    if ours(args, "head_addr") then
                        st.stats.blocked_deaths = st.stats.blocked_deaths + 1
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end, function(retval) return retval end)
            end
        end
        -- Game overs.
        local go_td = find_type("chainsaw.GameOverMediator")
        local okG, req = pcall(function() return go_td and go_td:get_method("requestGameOver") end)
        if okG and req ~= nil then
            pcall(Guard.hook, req, function()
                local s = game.inv
                if s ~= nil and s.on then
                    st.stats.blocked_game_overs = st.stats.blocked_game_overs + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval) return retval end)
        end
    end
end

return M
