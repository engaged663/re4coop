-- RE4 (2023) adapter, part 2: enemies and hits. Installed into game.lua's Game class
-- (require("re4coop.game_enemies").install(Game, helpers)); enemy_net.lua talks to the game
-- only through these methods (its "adapter contract").
--
-- What the enemy sync needs from the game, and how it is done (docs/RESEARCH.md 3.8-3.10):
--   * Reading: CharacterManager.get_EnemyContextList(); per context its HitPoint, its body
--     GameObject (Transform: position and full rotation; via.motion.Motion: the animation
--     layers - motion bank, motion id, frame, speed) and its level identity (ContextID code).
--   * Puppets: an enemy the partner's game runs has its AI head switched off
--     (HeadGameObject.set_UpdateSelf(false), pool-safe: see wake_head) and its body's
--     animation state machine (via.motion.MotionFsm2) disabled, so nothing but the partner's
--     stream moves it: transform writes (+ CharacterController.warp) and motion layer writes
--     (TreeLayer.changeMotion / set_Frame / set_Speed).
--   * Hits: HitController.callbackDamageHit(DamageInfo) runs for every hit on a character. A
--     pre-hook reads every primitive value of the DamageInfo (found by reflection, so nothing
--     about its layout is hard-coded), and for a puppet makes sure our game cannot kill it (the
--     owner decides). A partner's hit is run through the same callback with those values.
--   * Deaths: HitPoint.dead() (or HP 0), preceded by the killing hit when we have it;
--     erasing = CharacterSpawnParam.invalidateSpawn(true), undone when the partner's world
--     brings the enemy back (never CharacterContext.eliminate(): that one is permanent and ends
--     up in the save).

local P = require("re4coop.protocol")

local M = {}

-- Enemies further than this from the local player are read in full only every
-- FAR_ENEMY_EVERY ticks (rotation, max HP, animation, body check); HP, position and alive
-- state are read for every enemy on every tick.
local NEAR_ENEMY = 50.0
local FAR_ENEMY_EVERY = 4
-- The body components that choose an enemy's animation by themselves (switched off on puppets).
local ANIM_DRIVERS = { ["via.motion.MotionFsm2"] = true, ["via.motion.MotionFsm"] = true }
local DEFAULT_LAYERS = 2        -- animation layers read and written per enemy (setting enemy_anim_layers)
local FRAME_TOLERANCE = 4.0     -- frames a puppet's layer may drift before it is moved
local SPEED_TOLERANCE = 0.02
local MOTION_BLEND_FRAMES = 6.0 -- interpolation frames when a puppet's layer changes motion
local MAX_HIT_EVENTS = 64
local DAMAGE_INFO = "chainsaw.HitController.DamageInfo"
-- Object fields of a DamageInfo (and its HitInfo/ContactInfo parents) and what a replayed hit
-- carries in them: "attacker" = our live body, "target" = the enemy's body, "go" = kept if the
-- GameObject is alive, "comp" = kept if the component is alive, "clear" = null. AttackGameObject
-- is never null: RagdollUnit.onDamageHit (a killing hit that throws the body) reads its position
-- without a check - a null one crashed the game (docs/RESEARCH.md 3.13). DamageCollidable and
-- DamageUserData are the enemy's own (build_hit).
local HIT_OBJECT_FIELDS = {
    { "AttackOwnerObject", "attacker" }, { "WeaponGameObject", "go" }, { "AttackGameObject", "attacker" },
    { "DamageGameObject", "target" }, { "ChildHitController", "comp" }, { "AttackCollidable", "clear" },
    { "DamageCollidable", "clear" },
}
local CHEST = 1 -- chainsaw.character.BodyParts.Chest: the part a replayed hit lands on
local HIT_HOLD = 5.0 -- seconds a DamageInfo we built keeps an engine reference after the hit (Game:hold)
-- DamageInfo values that only mean something in the game that made them are not copied.
local HIT_FIELD_EXCLUDE = { "serial", "unique", "handle", "address", "pointer", "ptr", "frame", "time" }
local HIT_VALUE_TYPES = {
    ["System.Int32"] = P.HIT_VALUE.I32, ["System.Int16"] = P.HIT_VALUE.I32, ["System.SByte"] = P.HIT_VALUE.I32,
    ["System.Byte"] = P.HIT_VALUE.I32, ["System.UInt16"] = P.HIT_VALUE.I32, ["System.UInt32"] = P.HIT_VALUE.U32,
    ["System.Int64"] = P.HIT_VALUE.I64, ["System.UInt64"] = P.HIT_VALUE.I64, ["System.Single"] = P.HIT_VALUE.F32,
    ["System.Double"] = P.HIT_VALUE.F64, ["System.Boolean"] = P.HIT_VALUE.BOOL, ["via.vec3"] = P.HIT_VALUE.VEC3,
    ["via.Float3"] = P.HIT_VALUE.VEC3,
}

function M.install(Game, H)
    local singleton, find_type, address_of, type_name_of = H.singleton, H.find_type, H.address_of, H.type_name_of
    local v3, q4, dist, field_type_name, field_is_static = H.v3, H.q4, H.dist, H.field_type_name, H.field_is_static
    local type_hierarchy = H.type_hierarchy
    local CHARACTER_MANAGER = H.CHARACTER_MANAGER

    local function hook_available()
        return type(sdk) == "table" and type(sdk.hook) == "function" and type(sdk.to_managed_object) == "function"
    end

    local function excluded(name)
        local l = name:lower()
        for _, w in ipairs(HIT_FIELD_EXCLUDE) do
            if l:find(w, 1, true) then return true end
        end
        return false
    end

    function Game:init_enemies()
        self.enemy_ctx = {}     -- id -> context object from the latest list_enemies()
        self.enemy_info = {}    -- id -> cached per-context data (see list_enemies)
        self.enemy_by_body = {} -- body GameObject address -> enemy id
        self.puppets = {}       -- id -> { go = head, upd = HeadUpdater, drivers = {components we disabled} }
        self.parked_heads = {}  -- head address -> { go, upd }: switched off and in the game's pool
        self.enemy_hidden = {}  -- id -> { body_addr, gos = {GameObjects we stopped drawing} }
        self.parked_bodies = {} -- body address -> gos: hidden by us when its enemy left the list
        self.last_hits = {}     -- id -> values of the last hit it took (any attacker)
        -- The attack data of our own player's real hits (docs/RESEARCH.md 3.13): a hit we run
        -- for the partner needs them - HitController.playDamageSe dereferences
        -- DamageInfo.AttackUserData without a check (a null one crashed the game).
        -- `refs` only grows: a kept object is never let go of (REFramework would release it, and
        -- one the game freed with its resource must never be released again - see still_valid).
        self.hit_templates = { by_weapon = {}, any = nil, refs = {} }
        self.erased_spawns = {} -- uid (or "id:<id>") -> spawn param we invalidated (enemy_erase)
        self.hit_events = {}
        self.fatal_events = {} -- enemies our player started a finisher on (see on_local_fatal)
        self.hit_stats = { seen = 0, by_player = 0, other_owner = 0, not_enemy = 0, clamped = 0, applied = 0,
            apply_failed = 0, kills_with_hit = 0, fields = 0 }
        self.anim_stats = { changes = 0, seeks = 0, speeds = 0, failed = 0 }
        self.elim_scan = nil
    end

    -- The game reloaded: put back what we switched off (pooled heads and bodies outlive a
    -- checkpoint) and forget every cached enemy object.
    function Game:reload_enemies()
        for id in pairs(self.puppets) do self:restore_puppet(id) end
        for id in pairs(self.enemy_hidden) do self:park_body(id) end
        self.enemy_ctx, self.enemy_info, self.enemy_by_body = {}, {}, {}
        self.puppets, self.last_hits, self.hit_events, self.fatal_events = {}, {}, {}, {}
        self.elim_scan = nil
    end

    ---------------------------------------------------------------------------
    -- Identity
    ---------------------------------------------------------------------------

    -- Per-context data that does not change (kind, level identity) or is validated before use
    -- (body, transform, motion). A context whose body changed holds a new enemy.
    function Game:new_enemy_info(ctx, body, body_addr)
        local uid = self:read_enemy_uid(ctx)
        return {
            kind = type_name_of(ctx) or "unknown",
            uid = uid or false,
            body = body,
            body_addr = body_addr,
            transform = body and self:call(body, "get_Transform") or false,
            rot = { x = 0, y = 0, z = 0, w = 1 },
            max_hp = 0,
            tick = 0,
        }
    end

    ---------------------------------------------------------------------------
    -- Reading
    ---------------------------------------------------------------------------

    -- local_pos: the local player's position (enemies near it are read in full every tick).
    -- want_state(id) -> bool (optional): also read these enemies' animation layers and
    -- visibility (the partner shows them).
    function Game:list_enemies(local_pos, want_state)
        local cm = singleton(CHARACTER_MANAGER)
        if cm == nil then return nil end
        local list = self:call(cm, "get_EnemyContextList")
        if list == nil then
            self:cap("enemy_list", false, "get_EnemyContextList failed")
            return nil
        end
        local count = tonumber(self:call(list, "get_Count")) or 0
        self:cap("enemy_list", true, ("%d enemy contexts"):format(count))

        local out, ctx_by_id, by_body, infos = {}, {}, {}, {}
        local old = self.enemy_info
        local with_id = 0
        for i = 0, count - 1 do
            local ctx = self:call(list, "get_Item", i)
            local id = ctx and address_of(ctx)
            local hp = id and self:call(ctx, "get_HitPoint")
            if hp ~= nil then
                local info = old[id]
                local near = local_pos == nil or info == nil or info.pos == nil or dist(info.pos, local_pos) <= NEAR_ENEMY
                local full = info == nil or near or (info.tick % FAR_ENEMY_EVERY) == 0
                if full then
                    local body = self:call(ctx, "get_BodyGameObject")
                    local body_addr = body and address_of(body)
                    if info == nil or info.body_addr ~= body_addr then
                        if info ~= nil then self:restore_enemy(id) end -- a new character in this context
                        info = self:new_enemy_info(ctx, body, body_addr)
                        self.last_hits[id] = nil
                        self:unpark_body(body_addr)
                    end
                end
                info.tick = info.tick + 1
                -- Only enemies whose body still exists: a dissolving or unloading enemy keeps its
                -- context a little longer, and nothing may be written to it any more.
                if info.transform and (not full or self:alive(info.transform)) then
                    local pos = v3(self:call(info.transform, "get_Position")) or v3(self:call(ctx, "get_Position"))
                    if pos ~= nil then
                        info.pos = pos
                        infos[id] = info
                        ctx_by_id[id] = ctx
                        if info.body_addr ~= nil then by_body[info.body_addr] = id end
                        if info.uid then with_id = with_id + 1 end
                        local cur = tonumber(self:call(hp, "get_CurrentHitPoint")) or 0
                        local want = want_state ~= nil and want_state(id) or false
                        if full then
                            info.max_hp = tonumber(self:call(hp, "get_DefaultHitPoint")) or info.max_hp
                            info.rot = q4(self:call(info.transform, "get_Rotation")) or info.rot
                            if want then
                                info.layers = self:read_layers(info)
                                info.hidden = info.body and self:call(info.body, "get_DrawSelf") == false or false
                            end
                        end
                        if not want then info.layers, info.hidden = nil, nil end
                        out[#out + 1] = {
                            id = id, kind = info.kind, uid = info.uid or nil, pos = pos, rot = info.rot, hp = cur,
                            max_hp = info.max_hp, alive = self:call(hp, "get_IsLive") ~= false,
                            hidden = info.hidden, layers = info.layers,
                        }
                    end
                end
            end
        end
        self.enemy_ctx, self.enemy_info, self.enemy_by_body = ctx_by_id, infos, by_body
        -- An enemy that left the list (area unload, despawn) while it was a puppet: the game
        -- pools heads and bodies and gives them to the next enemies it spawns, so they must
        -- run again (see wake_head for when a head may be switched on).
        for id in pairs(self.puppets) do
            if ctx_by_id[id] == nil then self:restore_puppet(id) end
        end
        for id in pairs(self.enemy_hidden) do
            if ctx_by_id[id] == nil then self:park_body(id) end
        end
        for id in pairs(self.last_hits) do
            if ctx_by_id[id] == nil then self.last_hits[id] = nil end
        end
        if #out > 0 then
            self:cap("enemy_uid", with_id > 0, ("%d of %d enemies have a level identity"):format(with_id, #out))
        end
        return out
    end

    -- The cached data of an enemy whose body is still there right now, or nil.
    function Game:live_enemy(id)
        local info = self.enemy_info[id]
        if info == nil or self.enemy_ctx[id] == nil or not self:alive(info.transform) then return nil end
        return info
    end

    function Game:enemy_motion(info)
        if info.motion == nil then
            info.motion = (info.body and self:get_component(info.body, "via.motion.Motion")) or false
        end
        return info.motion or nil
    end

    function Game:enemy_layer(info, i)
        info.layer_objs = info.layer_objs or {}
        local l = info.layer_objs[i]
        if l == nil then
            local motion = self:enemy_motion(info)
            l = (motion and self:call(motion, "getLayer", i)) or false
            info.layer_objs[i] = l
        end
        return l or nil
    end

    function Game:layer_count(info)
        if info.layer_count == nil then
            local motion = self:enemy_motion(info)
            local n = motion and tonumber(self:call(motion, "getLayerCount")) or nil
            local want = math.min(P.MAX_ENEMY_LAYERS, math.max(1, math.floor(tonumber(self.settings.enemy_anim_layers) or DEFAULT_LAYERS)))
            info.layer_count = math.min(want, n or 1)
        end
        return info.layer_count
    end

    -- What the enemy is animating: per layer motion bank, motion id, frame and speed.
    function Game:read_layers(info)
        local out = {}
        for i = 0, self:layer_count(info) - 1 do
            local layer = self:enemy_layer(info, i)
            if layer == nil then break end
            local bank = tonumber(self:call(layer, "get_MotionBankID"))
            local mid = tonumber(self:call(layer, "get_MotionID"))
            if bank == nil or mid == nil then break end
            out[#out + 1] = { bank = bank, id = mid, frame = tonumber(self:call(layer, "get_Frame")) or 0,
                speed = tonumber(self:call(layer, "get_Speed")) or 1 }
        end
        return #out > 0 and out or nil
    end

    ---------------------------------------------------------------------------
    -- HP
    ---------------------------------------------------------------------------

    function Game:enemy_get_hp(id)
        local ctx = self:live_enemy(id) and self.enemy_ctx[id]
        local hp = ctx and self:call(ctx, "get_HitPoint")
        return hp and tonumber(self:call(hp, "get_CurrentHitPoint")) or nil
    end

    -- Never kills: deaths go through enemy_kill (with the game's own death logic).
    function Game:enemy_set_hp(id, value)
        local ctx = self:live_enemy(id) and self.enemy_ctx[id]
        local hp = ctx and self:call(ctx, "get_HitPoint")
        if hp == nil then return false end
        self.perf:crumb("enemy.set_hp", self.enemy_info[id].kind)
        return self:write_hp(hp, math.max(1, value))
    end

    ---------------------------------------------------------------------------
    -- Puppets: AI head and animation driver
    ---------------------------------------------------------------------------

    -- Switches enemy `id` into a puppet (on) or back to its own game (off). A puppet's AI head
    -- stops updating (it no longer thinks, targets or attacks on its own) and its body's
    -- animation state machine is disabled (it plays only what we write into its motion layers).
    -- Heads are pooled (CharacterInstanceCoordinator.HeadPoolList): one we switched off must
    -- never go back to the pool switched off - and must never be switched on while it sits in
    -- the pool, because CharacterHeadUpdater.update reads Context+0x148 without a null check
    -- (re4.exe 0x1412733c0, the crash of 2026-10-11). See wake_head.
    function Game:enemy_set_puppet(id, on)
        local p = self.puppets[id]
        if not on then
            if p ~= nil then self:restore_puppet(id) end
            return true
        end
        if p ~= nil then return true end
        local info = self:live_enemy(id)
        local ctx = info and self.enemy_ctx[id]
        if ctx == nil then return false end
        local head = self:call(ctx, "get_HeadGameObject")
        if head == nil or not self:go_alive(head) then
            self:cap("enemy_puppet", false, "no head GameObject")
            return false
        end
        local upd = self:call(ctx, "get_HeadUpdater")
        self.perf:crumb("enemy.puppet", info.kind)
        if not pcall(head.call, head, "set_UpdateSelf", false) then
            self:cap("enemy_puppet", false, "head set_UpdateSelf failed")
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
        self.puppets[id] = { go = head, upd = upd, drivers = drivers }
        self:cap("enemy_puppet", true, ("head off, %d animation driver(s) off"):format(#drivers))
        return true
    end

    -- Whether enemy `id` is a puppet here (its AI head and animation driver off by us).
    function Game:enemy_is_puppet(id)
        return self.puppets[id] ~= nil
    end

    -- The enemy runs on its own again: its animation driver back on, its head back on (or
    -- parked until the game links it to its next enemy).
    function Game:restore_puppet(id)
        local p = self.puppets[id]
        if p == nil then return end
        self.puppets[id] = nil
        for _, comp in ipairs(p.drivers or {}) do
            if self:alive(comp) then pcall(comp.call, comp, "set_Enabled", true) end
        end
        self:wake_head(p)
    end

    -- Whether a head's updater is linked to a character (HeadUpdater.Context set). A head in
    -- the game's pool has none, and must not update.
    function Game:head_linked(upd)
        return upd ~= nil and self:alive(upd) and self:call(upd, "get_Context") ~= nil
    end

    -- Switches a head we switched off back on if it is linked to a character now; a pooled
    -- head is parked until the game links it to its next enemy (service_heads).
    function Game:wake_head(entry)
        if entry == nil or not self:go_alive(entry.go) then return true end
        if not self:head_linked(entry.upd) then
            local addr = address_of(entry.go)
            if addr ~= nil then self.parked_heads[addr] = { go = entry.go, upd = entry.upd } end
            return false
        end
        self.perf:crumb("enemy.ai", "restore")
        pcall(entry.go.call, entry.go, "set_UpdateSelf", true)
        return true
    end

    -- Every frame (cheap: only while we parked heads): a parked head the game linked to a new
    -- enemy runs again; one that was destroyed is forgotten.
    function Game:service_heads()
        if next(self.parked_heads) == nil then return end
        local now = self.clock()
        if now - (self.heads_checked or -math.huge) < 0.1 then return end
        self.heads_checked = now
        for addr, entry in pairs(self.parked_heads) do
            if not self:go_alive(entry.go) then
                self.parked_heads[addr] = nil
            elseif self:head_linked(entry.upd) then
                self.parked_heads[addr] = nil
                self.perf:crumb("enemy.ai", "relinked")
                pcall(entry.go.call, entry.go, "set_UpdateSelf", true)
            end
        end
    end

    -- Everything we changed on enemy `id` goes back (its context now holds another enemy).
    function Game:restore_enemy(id)
        self:restore_puppet(id)
        self:park_body(id)
        self.last_hits[id] = nil
    end

    -- Every enemy runs and is drawn again (session ended, script reset).
    function Game:restore_enemies()
        for id in pairs(self.puppets) do self:restore_puppet(id) end
        self.puppets = {}
        for id in pairs(self.enemy_hidden) do
            if not self:enemy_set_visible(id, true) then self:park_body(id) end
        end
        self.enemy_hidden = {}
        for addr, gos in pairs(self.parked_bodies) do
            self:draw_again(gos)
            self.parked_bodies[addr] = nil
        end
    end
    Game.restore_enemy_ai = Game.restore_enemies -- older name

    ---------------------------------------------------------------------------
    -- Puppets: transform, animation, visibility
    ---------------------------------------------------------------------------

    -- Our copy stands where the partner's enemy is: position and full rotation, with the
    -- CharacterController warped so physics does not pull it back. Runs every frame for every
    -- puppet, so the body is checked right before each write.
    function Game:enemy_set_transform(id, pos, rot)
        local info = self:live_enemy(id)
        local tf = info and info.transform
        if not tf then return false end
        self.n_calls = self.n_calls + 2
        local ok = pcall(tf.call, tf, "set_Position", Vector3f.new(pos.x, pos.y, pos.z))
        if ok and rot ~= nil then
            ok = pcall(tf.call, tf, "set_Rotation", Quaternion.new(rot.w, rot.x, rot.y, rot.z))
        end
        if not ok then
            self:cap("enemy_mirror", false, "set_Position/set_Rotation failed")
            return false
        end
        if info.cc == nil then
            info.cc = self:get_component(info.body, "via.physics.CharacterController") or false
        end
        if info.cc then self:call(info.cc, "warp") end
        if not self.caps.enemy_mirror or not self.caps.enemy_mirror.ok then
            self:cap("enemy_mirror", true, "transform + CharacterController.warp")
        end
        return true
    end

    function Game:layer_seek(layer, frame)
        if pcall(layer.call, layer, "set_Frame", frame) then return true end
        return false
    end

    -- Plays the partner's animation on our puppet. Per layer: another motion -> changeMotion
    -- (bank, motion, its current frame, blend frames); the same motion but more than
    -- FRAME_TOLERANCE frames apart -> set_Frame (or changeMotion without blending); another
    -- speed -> set_Speed. Between corrections the game plays the motion on by itself.
    function Game:enemy_set_anim(id, layers)
        local info = self:live_enemy(id)
        if info == nil then return false end
        for i = 1, math.min(#layers, self:layer_count(info)) do
            local target = layers[i]
            local layer = self:enemy_layer(info, i - 1)
            if layer == nil then break end
            local bank = tonumber(self:call(layer, "get_MotionBankID"))
            local mid = tonumber(self:call(layer, "get_MotionID"))
            if bank ~= target.bank or mid ~= target.id then
                self.perf:crumb("enemy.motion")
                local ok = pcall(function()
                    layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                        target.bank, target.id, target.frame or 0.0, MOTION_BLEND_FRAMES, 2, 0)
                end)
                if ok then
                    self.anim_stats.changes = self.anim_stats.changes + 1
                else
                    self.anim_stats.failed = self.anim_stats.failed + 1
                    self:cap("enemy_motion", false, "changeMotion failed")
                    return false
                end
            else
                local frame = tonumber(self:call(layer, "get_Frame"))
                if frame ~= nil and math.abs(frame - (target.frame or 0)) > FRAME_TOLERANCE then
                    local ok = self:layer_seek(layer, target.frame or 0)
                        or pcall(function()
                            layer:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                                target.bank, target.id, target.frame or 0.0, 0.0, 0, 0)
                        end)
                    if ok then
                        self.anim_stats.seeks = self.anim_stats.seeks + 1
                        end
                end
            end
            if target.speed ~= nil then
                local speed = tonumber(self:call(layer, "get_Speed"))
                if speed ~= nil and math.abs(speed - target.speed) > SPEED_TOLERANCE
                    and pcall(layer.call, layer, "set_Speed", target.speed) then
                    self.anim_stats.speeds = self.anim_stats.speeds + 1
                end
            end
        end
        if not self.caps.enemy_motion or not self.caps.enemy_motion.ok then
            self:cap("enemy_motion", true, "TreeLayer.changeMotion / set_Frame / set_Speed")
        end
        return true
    end

    -- An enemy is drawn (on) or not. Its body and everything attached to it (weapons,
    -- accessories) stop drawing; only the objects that were drawn are hidden, and exactly those
    -- are drawn again.
    function Game:enemy_set_visible(id, on)
        local hidden = self.enemy_hidden[id]
        if on then
            if hidden == nil then return true end
            self.enemy_hidden[id] = nil
            self:draw_again(hidden.gos)
            return true
        end
        if hidden ~= nil then return true end
        local info = self:live_enemy(id)
        if info == nil or not info.body then return false end
        local gos = {}
        for _, node in ipairs(self:collect_tree(info.body, 4)) do
            if self:call(node.go, "get_DrawSelf") ~= false and pcall(node.go.call, node.go, "set_DrawSelf", false) then
                gos[#gos + 1] = node.go
            end
        end
        self.perf:crumb("enemy.hide", info.kind)
        self.enemy_hidden[id] = { body_addr = info.body_addr, gos = gos }
        self:cap("enemy_hide", #gos > 0, ("%d objects hidden"):format(#gos))
        return true
    end

    function Game:draw_again(gos)
        for _, go in ipairs(gos or {}) do
            if self:go_alive(go) then pcall(go.call, go, "set_DrawSelf", true) end
        end
    end

    -- The enemy left the list while hidden: its body is destroyed, or kept by the game to be
    -- reused. A reused body is drawn again when an enemy shows up with it (unpark_body).
    function Game:park_body(id)
        local hidden = self.enemy_hidden[id]
        self.enemy_hidden[id] = nil
        if hidden == nil or hidden.body_addr == nil then return end
        self.parked_bodies[hidden.body_addr] = hidden.gos
    end

    function Game:unpark_body(body_addr)
        local gos = body_addr and self.parked_bodies[body_addr]
        if gos == nil then return end
        self.parked_bodies[body_addr] = nil
        self:draw_again(gos)
    end

    ---------------------------------------------------------------------------
    -- Hits: every value of a DamageInfo, by reflection
    ---------------------------------------------------------------------------

    -- The primitive fields of chainsaw.HitController.DamageInfo and its parents (HitInfo,
    -- ContactInfo...): { {name, hash, tag}, ... } and by_hash. Both games run the same build, so
    -- the same names (hashed with FNV-1a) address the same values on both sides.
    function Game:damage_schema()
        if self.dmg_schema ~= nil then return self.dmg_schema or nil end
        local td = find_type(DAMAGE_INFO)
        if td == nil then
            self.dmg_schema = false
            self:cap("hit_values", false, DAMAGE_INFO .. " not found")
            return nil
        end
        local list, by_hash, seen = {}, {}, {}
        for _, t in ipairs(type_hierarchy(td, 6)) do
            local ok, fields = pcall(t.get_fields, t)
            for _, f in ipairs(ok and fields or {}) do
                local okn, name = pcall(f.get_name, f)
                if okn and name ~= nil and not seen[name] and not field_is_static(f) and not excluded(name) then
                    seen[name] = true
                    local ft = field_type_name(f) or ""
                    local tag = HIT_VALUE_TYPES[ft]
                    if tag == nil then
                        local ftd = find_type(ft)
                        local okE, isenum = pcall(function() return ftd ~= nil and ftd:is_a("System.Enum") end)
                        if okE and isenum then tag = P.HIT_VALUE.I32 end
                    end
                    if tag ~= nil then
                        local entry = { name = name, hash = P.hash(name), tag = tag }
                        list[#list + 1] = entry
                        by_hash[entry.hash] = entry
                    end
                end
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        self.dmg_schema = { list = list, by_hash = by_hash }
        self.hit_stats.fields = #list
        self:cap("hit_values", #list > 0, ("%d DamageInfo values"):format(#list))
        return self.dmg_schema
    end

    -- Every value of a DamageInfo as { {h, t, v}, ... }.
    function Game:read_damage_fields(info)
        local schema = self:damage_schema()
        if schema == nil then return nil end
        local out = {}
        for _, f in ipairs(schema.list) do
            local ok, v = pcall(info.get_field, info, f.name)
            if ok and v ~= nil then
                if f.tag == P.HIT_VALUE.VEC3 then
                    if type(v) == "userdata" or type(v) == "table" then
                        out[#out + 1] = { h = f.hash, t = f.tag, v = { x = v.x or 0, y = v.y or 0, z = v.z or 0 } }
                    end
                elseif f.tag == P.HIT_VALUE.BOOL then
                    out[#out + 1] = { h = f.hash, t = f.tag, v = v == true }
                elseif type(v) == "number" then
                    out[#out + 1] = { h = f.hash, t = f.tag, v = v }
                end
            end
        end
        return out
    end

    function Game:write_damage_fields(info, fields)
        local schema = self:damage_schema()
        if schema == nil then return 0 end
        local n = 0
        for _, f in ipairs(fields or {}) do
            local s = schema.by_hash[f.h]
            if s ~= nil and s.tag == f.t then
                local v = f.v
                if f.t == P.HIT_VALUE.VEC3 then v = Vector3f.new(v.x, v.y, v.z) end
                if pcall(info.set_field, info, s.name, v) then n = n + 1 end
            end
        end
        return n
    end

    function Game:remember_player_objects(body, head)
        local objs = {}
        local a, b = address_of(body), address_of(head)
        if a then objs[a] = true end
        if b then objs[b] = true end
        self.player_objects = objs
        self.player_body = body
    end

    -- Enemy id whose body owns this HitController (directly, or as the damage owner / parent).
    function Game:enemy_for_hit_controller(hc)
        local go = self:call(hc, "get_GameObject")
        local id = self.enemy_by_body[address_of(go) or false]
        if id ~= nil then return id end
        local owner = self:call(hc, "get_DamageOwner")
        id = self.enemy_by_body[address_of(owner) or false]
        if id ~= nil then return id end
        local parent = self:call(hc, "get_ParentHitController")
        local pgo = parent and self:call(parent, "get_GameObject")
        return self.enemy_by_body[address_of(pgo) or false]
    end

    -- Every hit on an enemy: its values are kept (the killing hit of a death we announce), and
    -- a hit our player landed is reported (enemy_net sends it to the owner or as a tracer). On
    -- a puppet the hit may never kill: the owner decides (enemy_hit_predict off: it takes no
    -- HP here at all, our HP just follows the owner's).
    function Game:on_enemy_hit(hc, info)
        local stats = self.hit_stats
        stats.seen = stats.seen + 1
        local id = self:enemy_for_hit_controller(hc)
        if id == nil then
            stats.not_enemy = stats.not_enemy + 1
            return
        end
        local fields = self:read_damage_fields(info)
        self.last_hits[id] = fields
        local owner = self:call(info, "get_AttackOwnerObject")
        if not self.player_objects[address_of(owner) or false] then
            stats.other_owner = stats.other_owner + 1
            return
        end
        stats.by_player = stats.by_player + 1
        self:remember_hit_template(info)
        local ctx = self.enemy_ctx[id]
        local hp_obj = ctx and self:call(ctx, "get_HitPoint")
        local hp = hp_obj and tonumber(self:call(hp_obj, "get_CurrentHitPoint")) or nil
        local damage = tonumber(self:call(info, "get_Damage")) or 0
        local local_damage = damage
        local lethal = hp ~= nil and damage >= hp
        if self.puppets[id] ~= nil then
            if self.settings.enemy_hit_predict == false then
                local_damage = 0
            elseif lethal then
                local_damage = math.max(0, math.floor((hp or 1) - 1))
            end
            if local_damage ~= damage then
                pcall(info.call, info, "set_Damage", local_damage)
                pcall(info.call, info, "set_IsKill", false)
                stats.clamped = stats.clamped + 1
            end
        end
        if #self.hit_events < MAX_HIT_EVENTS then
            self.hit_events[#self.hit_events + 1] = {
                id = id, damage = damage, hp = hp, local_damage = local_damage, lethal = lethal,
                critical = self:call(info, "get_IsCritical") == true, fields = fields,
            }
        end
    end

    function Game:install_hit_hook()
        self.hit_hook_installed = true
        self.replaying = false
        if not hook_available() then
            self:cap("hit_hook", false, "sdk.hook unavailable")
            return
        end
        local td = find_type("chainsaw.HitController")
        local okM, m = pcall(function() return td and td:get_method("callbackDamageHit") end)
        if not okM or m == nil then
            self:cap("hit_hook", false, "HitController.callbackDamageHit not found")
            return
        end
        local game = self
        local ok = pcall(sdk.hook, m, function(args)
            if game.active and not game.replaying then
                pcall(function()
                    local hc = sdk.to_managed_object(args[2])
                    local info = sdk.to_managed_object(args[3])
                    if hc ~= nil and info ~= nil then game:on_enemy_hit(hc, info) end
                end)
            end
        end, function(retval) return retval end)
        self:cap("hit_hook", ok, ok and "HitController.callbackDamageHit" or "sdk.hook failed")
        -- Guard: a hit we run never reaches the damage sound without attack data (the null
        -- dereference in playDamageSe that crashed the partner's game).
        local okS, se = pcall(function() return td:get_method("playDamageSe") end)
        if okS and se ~= nil then
            pcall(sdk.hook, se, function(args)
                if not game.replaying then return end
                local skip = false
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    skip = info == nil or info:call("get_AttackUserData") == nil or info:call("get_AttackData") == nil
                end)
                if skip then
                    game.hit_stats.se_skipped = (game.hit_stats.se_skipped or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval) return retval end)
        end
        -- Finishers (stealth kill, grab, knife finish, stomp): PlayerHeadUpdater.requestFatal /
        -- requestKnifeFatal / requestStompFatal hand the request to the target's AI head
        -- (CharacterContext._HeadUpdater) - which a puppet has switched off. See on_local_fatal.
        local ptd = find_type("chainsaw.PlayerHeadUpdater")
        local fatal_hooked = 0
        for _, name in ipairs({ "requestFatal", "requestKnifeFatal", "requestStompFatal" }) do
            local okF, fm = pcall(function() return ptd and ptd:get_method(name) end)
            if okF and fm ~= nil and pcall(sdk.hook, fm, function(args)
                if not game.active then return end
                pcall(function()
                    local head = sdk.to_managed_object(args[2])
                    local sel = head and head:call("get_TargetSelectorDriver")
                    local target = sel and sel:call("get_LockonTarget")
                    local id = target and address_of(target)
                    if id ~= nil then game:on_local_fatal(id) end
                end)
            end, function(retval) return retval end) then
                fatal_hooked = fatal_hooked + 1
            end
        end
        self:cap("fatal_hook", fatal_hooked > 0, ("%d finisher request(s) watched"):format(fatal_hooked))
        -- Guard: the body thrown by a killing hit (RagdollUnit.onDamageHit, maybe a frame later)
        -- never gets a hit without the attacker's GameObject or the damage data - the original
        -- dereferences both without a check (the crash at re4.exe+0x37959f8). Only adds force.
        local rtd = find_type("chainsaw.RagdollUnit")
        local okR, rm = pcall(function() return rtd and rtd:get_method("onDamageHit") end)
        if okR and rm ~= nil then
            pcall(sdk.hook, rm, function(args)
                if not game.active then return end
                local skip = false
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    skip = info == nil or info:call("get_AttackGameObject") == nil
                        or info:call("get_DamageUserData") == nil
                end)
                if skip then
                    game.hit_stats.ragdoll_skipped = (game.hit_stats.ragdoll_skipped or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval) return retval end)
        end
        self:install_mutilation_guard()
        self:damage_schema()
    end

    -- No mutilation from a hit we run (a partner's hit, or the killing hit of a death the
    -- partner's game decided): only its reaction and the death. On a death the villagers draw
    -- lots for a head burst (lotteryBreakHead) and break the part (onPartsBreak ->
    -- requestPartsBreak -> triggerPartsBreakEffect): run from our replayed killing hit, the
    -- break effect crashed the game in WindManager.attachWindSettingEffect (re4.exe+0x326e37f,
    -- three times, docs/RESEARCH.md 3.16). Our own player's hits mutilate as always.
    -- { type, method, returns a Boolean }. Never a method whose code is a shared stub
    -- (CharacterHeadUpdater.onPartsBreak is the empty method of tens of thousands of types).
    local MUTILATION_METHODS = {
        { "chainsaw.Ch1c0HeadUpdaterCommon", "lotteryBreakHead", true },
        { "chainsaw.Ch1c0HeadUpdaterCommon", "onPartsBreak", false },
        { "chainsaw.Ch1c0BodyUpdaterCommon", "requestPartsBreak", false },
        { "chainsaw.EnemyHeadUpdater", "onPartsBreak", false },
        { "chainsaw.CharacterBodyUpdater", "onPartsBreak", false },
        { "chainsaw.Ch1d4z0HeadUpdater", "onPartsBreak", false },
        { "chainsaw.Ch1d4z0BodyUpdater", "onPartsBreak", false },
    }

    local function method_function(m)
        local ok, fn = pcall(function() return m:get_function() end)
        return ok and fn or nil
    end

    function Game:install_mutilation_guard()
        local game = self
        local stub
        do
            local ch = find_type("chainsaw.CharacterHeadUpdater")
            local okS, sm = pcall(function() return ch and ch:get_method("onPartsBreak") end)
            stub = okS and sm and method_function(sm) or nil
        end
        local seen, hooked = {}, 0
        for _, spec in ipairs(MUTILATION_METHODS) do
            local td = find_type(spec[1])
            local okM, m = pcall(function() return td and td:get_method(spec[2]) end)
            local fn = okM and m and method_function(m) or nil
            if okM and m ~= nil and (fn == nil or (fn ~= stub and not seen[fn])) then
                if fn ~= nil then seen[fn] = true end
                local returns_bool, skipped = spec[3], false
                if pcall(sdk.hook, m, function()
                    skipped = false
                    if game.replaying and game.settings.enemy_replay_mutilation ~= true then
                        skipped = true
                        game.hit_stats.mutilations_skipped = (game.hit_stats.mutilations_skipped or 0) + 1
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end, function(retval)
                    local was = skipped
                    skipped = false
                    if was and returns_bool then return sdk.to_ptr(0) end -- false: no head burst
                    return retval
                end) then hooked = hooked + 1 end
            end
        end
        self:cap("no_mutilation", hooked > 0, ("%d parts-break method(s) guarded on replayed hits"):format(hooked))
    end

    -- Hits the local player landed on enemies since the last call:
    -- { {id, damage, hp, local_damage, lethal, critical, fields}, ... } or nil without the hook.
    function Game:take_hit_events()
        if self.caps.hit_hook == nil or not self.caps.hit_hook.ok then return nil end
        local out = self.hit_events
        if #out == 0 then return out end
        self.hit_events = {}
        return out
    end

    -- Our player starts a finisher on enemy `id` (inside the game's request, before the enemy's
    -- AI head receives it). A puppet's head is off: it would keep the request and do nothing
    -- while the partner's game ran the enemy on - the enemy chased the partner and only died
    -- when it changed hands seconds later. If `fatal_filter(id)` allows it (enemy sync: our game
    -- may take the enemy over), its head and animation driver go back on right here, so the
    -- finisher plays out in our game; enemy_net takes the enemy over (take_fatal_events).
    function Game:on_local_fatal(id)
        if self.enemy_ctx[id] == nil then return end
        if self.fatal_filter ~= nil and not self.fatal_filter(id) then return end
        self.perf:crumb("enemy.fatal", self.enemy_info[id] and self.enemy_info[id].kind, true)
        if self.puppets[id] ~= nil then self:restore_puppet(id) end
        for _, v in ipairs(self.fatal_events) do
            if v == id then return end
        end
        if #self.fatal_events < MAX_HIT_EVENTS then self.fatal_events[#self.fatal_events + 1] = id end
    end

    -- Enemies our player started a finisher on since the last call: { id, ... }.
    function Game:take_fatal_events()
        local out = self.fatal_events or {}
        if #out > 0 then self.fatal_events = {} end
        return out
    end

    function Game:enemy_last_hit(id)
        return self.last_hits[id]
    end

    -- Makes every object field of a hit we run safe: our live body as the attacker, the enemy
    -- as the damaged object, other objects only while they still exist. False if no live
    -- attacker exists.
    function Game:sanitize_damage_info(info, target_body)
        local body = self.player_body
        if body == nil or not self:go_alive(body) then return false end
        for _, f in ipairs(HIT_OBJECT_FIELDS) do
            local name, rule = f[1], f[2]
            local value
            if rule == "attacker" then
                value = body
            elseif rule == "target" then
                value = target_body
            elseif rule == "go" or rule == "comp" then
                local cur = self:call(info, "get_" .. name)
                local alive = cur ~= nil and (rule == "go" and self:go_alive(cur) or self:alive(cur))
                value = alive and cur or nil
            end
            pcall(info.call, info, "set_" .. name, value)
        end
        return true
    end

    -- A kept engine object is still the object we kept: a managed object of the same type. The
    -- game frees resource data (a weapon's attack data, an enemy kind's damage data) with its
    -- resource, whatever references we hold: handing such a pointer to a setter made the game
    -- add a reference to freed memory (an access violation in HitInfo.set_DamageUserData, and a
    -- crash in the engine's own threads a few minutes later; docs/RESEARCH.md 3.17).
    function Game:still_valid(obj, type_name)
        local a = address_of(obj)
        if a == nil then return false end
        local ok, managed = pcall(sdk.is_managed_object, a)
        if not ok or not managed then return false end
        return type_name == nil or type_name_of(obj) == type_name
    end

    -- The attack data to put in a hit we run: the template of `weapon`, else the latest one,
    -- else any other still valid. Templates no longer valid are dropped (their objects stay in
    -- `refs`, never released).
    function Game:hit_template(weapon)
        local t = self.hit_templates
        local function usable(tpl)
            return tpl ~= nil and self:still_valid(tpl.au, tpl.au_type) and self:still_valid(tpl.ad, tpl.ad_type)
        end
        local function stale()
            self.hit_stats.stale_templates = (self.hit_stats.stale_templates or 0) + 1
        end
        local tpl = weapon ~= nil and t.by_weapon[weapon] or nil
        if tpl ~= nil and not usable(tpl) then
            t.by_weapon[weapon], tpl = nil, nil
            stale()
        end
        if tpl == nil and t.any ~= nil then
            if usable(t.any) then tpl = t.any else t.any = nil stale() end
        end
        if tpl == nil then
            for w, other in pairs(t.by_weapon) do
                if usable(other) then
                    tpl, t.any = other, other
                    break
                end
                t.by_weapon[w] = nil
                stale()
            end
        end
        return tpl
    end

    -- Keeps a managed object alive while we hold it (REFramework releases what nothing refers to).
    function Game:keep(obj)
        local a = address_of(obj)
        if a == nil then return nil end
        local refs = self.hit_templates.refs
        if refs[a] == nil then
            pcall(obj.add_ref, obj)
            refs[a] = obj
        end
        return refs[a]
    end

    -- Remembers the attack data of a real hit by our player (by weapon; the latest one too),
    -- with the types they had, to check them again before each use (still_valid).
    function Game:remember_hit_template(info)
        local au = self:call(info, "get_AttackUserData")
        local ad = self:call(info, "get_AttackData")
        if au == nil or ad == nil then return end
        local t = self.hit_templates
        local tpl = { au = self:keep(au), ad = self:keep(ad), au_type = type_name_of(au), ad_type = type_name_of(ad) }
        if tpl.au == nil or tpl.ad == nil or tpl.au_type == nil or tpl.ad_type == nil then return end
        local weapon = tonumber(self:call(info, "get_WeaponID"))
        if weapon ~= nil then t.by_weapon[weapon] = tpl end
        t.any = tpl
        self:cap("hit_templates", true, ("attack data of %d weapon(s)"):format((function()
            local n = 0
            for _ in pairs(t.by_weapon) do n = n + 1 end
            return n
        end)()))
    end

    -- One of the enemy's own damage colliders (its HitController's Colliders) and its
    -- DamageUserData - the chest one when there is one: collider, user data | nil.
    function Game:enemy_damage_collider(info)
        local hc = info.body and self:get_component(info.body, "chainsaw.HitController")
        local cols = hc and self:call(hc, "get_Colliders")
        local n = cols and tonumber(self:call(cols, "getCollidersCount")) or 0
        local first_col, first_ud
        for i = 0, math.min(n, 128) - 1 do
            local col = self:call(cols, "getColliders", i)
            local ud = col and self:call(col, "get_UserData")
            local tname = ud and self:still_valid(ud) and type_name_of(ud) or nil
            if tname ~= nil and tname:find("DamageUserData", 1, true) then
                local okP, parts = pcall(ud.get_field, ud, "Parts")
                if okP and tonumber(parts) == CHEST then return col, ud end
                first_col, first_ud = first_col or col, first_ud or ud
            end
        end
        return first_col, first_ud
    end

    -- A fresh DamageInfo carrying a hit's values (nil if one cannot be built: no live attacker,
    -- no attack data yet, or no damage data for the enemy). The game reads these without a
    -- check: AttackUserData/AttackData in the damage sound (HitController.playDamageSe),
    -- AttackGameObject and DamageUserData when a killing hit throws the body
    -- (RagdollUnit.onDamageHit -> addForceFromPointForce). Each null one crashed the game.
    function Game:build_hit(info, fields)
        local okC, d = pcall(sdk.create_instance, DAMAGE_INFO)
        if not okC or d == nil then return nil end
        d = self:hold(d, HIT_HOLD) -- the game frees an unreferenced DamageInfo mid-hit (see Game:hold)
        self:write_damage_fields(d, fields)
        if not self:sanitize_damage_info(d, info.body) then return nil end
        local weapon = tonumber(self:call(d, "get_WeaponID"))
        local tpl = self:hit_template(weapon)
        if tpl == nil then
            self.hit_stats.no_template = (self.hit_stats.no_template or 0) + 1
            return nil
        end
        if not (pcall(d.call, d, "set_AttackUserData", tpl.au) and pcall(d.call, d, "set_AttackData", tpl.ad)) then
            return nil
        end
        if self:call(d, "get_AttackUserData") == nil or self:call(d, "get_AttackData") == nil then return nil end
        -- The enemy's own collider and damage data, read from it now: never kept from an earlier
        -- hit (the game frees an enemy kind's data with its resource).
        local col, du = self:enemy_damage_collider(info)
        if du ~= nil then
            pcall(d.call, d, "set_DamageCollidable", col)
            pcall(d.call, d, "set_DamageUserData", du)
        end
        if self:call(d, "get_DamageUserData") == nil or self:call(d, "get_AttackGameObject") == nil then
            self.hit_stats.no_damage_data = (self.hit_stats.no_damage_data or 0) + 1
            return nil
        end
        return d
    end

    -- Runs a hit through the enemy's HitController (our own hook does not report it).
    function Game:run_hit(id, d)
        local info = self:live_enemy(id)
        local hc = info and info.body and self:get_component(info.body, "chainsaw.HitController")
        if hc == nil then return false end
        self.replaying = true
        local ok = pcall(hc.call, hc, "callbackDamageHit", d)
        self.replaying = false
        return ok
    end

    -- Runs the partner's hit on our enemy (we own it): the same values its game computed, so
    -- the same damage and the same reaction. hit = { damage, fields, critical }.
    function Game:enemy_apply_hit(id, hit)
        local info = self:live_enemy(id)
        if info == nil or hit.fields == nil or #hit.fields == 0 then return false end
        local d = self:build_hit(info, hit.fields)
        if d == nil then
            self.hit_stats.apply_failed = self.hit_stats.apply_failed + 1
            self:cap("hit_apply", false, "cannot build a DamageInfo")
            return false
        end
        self.perf:crumb("enemy.apply_hit", info.kind, "now")
        local ok = self:run_hit(id, d)
        if ok then
            self.last_hits[id] = hit.fields
            self.hit_stats.applied = self.hit_stats.applied + 1
            self:cap("hit_apply", true, ("%d partner hits run"):format(self.hit_stats.applied))
        else
            self.hit_stats.apply_failed = self.hit_stats.apply_failed + 1
            self:cap("hit_apply", false, "callbackDamageHit failed")
        end
        return ok
    end

    ---------------------------------------------------------------------------
    -- Deaths
    ---------------------------------------------------------------------------

    -- Our copy dies because the partner's game decided it: with its own logic (death
    -- animation, ragdoll, loot), from the killing hit when we have it (same direction, same
    -- kind of death), else HitPoint.dead() / HP 0.
    function Game:enemy_kill(id, fields)
        local info = self:live_enemy(id)
        local ctx = info and self.enemy_ctx[id]
        local hp = ctx and self:call(ctx, "get_HitPoint")
        if hp == nil then return false end
        self.perf:crumb("enemy.kill", info.kind, "now")
        self:restore_puppet(id) -- its death needs its AI and animation driver
        if fields ~= nil and #fields > 0 and self.settings.enemy_kill_with_hit ~= false then
            local d = self:build_hit(info, fields)
            if d ~= nil then
                local cur = tonumber(self:call(hp, "get_CurrentHitPoint")) or 0
                pcall(d.call, d, "set_Damage", math.floor(cur) + 1)
                pcall(d.call, d, "set_IsKill", true)
                if self:run_hit(id, d) then
                    local after = tonumber(self:call(hp, "get_CurrentHitPoint"))
                    if (after ~= nil and after <= 0) or self:call(hp, "get_IsLive") == false then
                        self.hit_stats.kills_with_hit = self.hit_stats.kills_with_hit + 1
                        return true
                    end
                end
            end
        end
        if self.kill_method ~= nil then
            local m = self:method(hp, self.kill_method)
            if m ~= nil and pcall(m.call, m, hp) then return true end
        end
        return self:write_hp(hp, 0)
    end

    -- Removes an enemy that is already dead in the partner's world: its spawn param's
    -- invalidateSpawn(true) despawns it now (updateSpawn: suspend, destroy body and head) and
    -- keeps it from spawning while it stays invalid. No death animation, no corpse, no loot.
    -- Never CharacterContext.eliminate(): that marks the character's backup eliminated for good -
    -- it is written into the save, so the enemy would be gone from this save forever, also after
    -- the partner's world brought it back (a checkpoint reload). If the area reloads, the
    -- spawn param is new and spawns the enemy again: the graveyard erases it again then.
    -- False when the enemy has no spawn param.
    function Game:enemy_erase(id)
        local info = self:live_enemy(id)
        local ctx = info and self.enemy_ctx[id]
        if ctx == nil then return false end
        local sp = self:call(ctx, "get_CharacterSpawnParam")
        if sp == nil or not self:alive(sp) then
            self:cap("enemy_erase", false, "enemy without a spawn param (killed instead)")
            return false
        end
        self.perf:crumb("enemy.erase", info.kind, true)
        self:restore_puppet(id) -- its pooled head and body are reused later
        local ok = pcall(sp.call, sp, "invalidateSpawn", true)
        if ok then
            pcall(sp.add_ref, sp)
            self.erased_spawns[info.uid or ("id:" .. tostring(id))] = sp
        end
        self:cap("enemy_erase", ok, ok and "CharacterSpawnParam.invalidateSpawn (undone when the enemy comes back)"
            or "invalidateSpawn failed")
        return ok
    end

    -- The partner's world has these enemies alive again (uid; nil = all, after its checkpoint
    -- reload): their spawn params may spawn them again here. Returns how many were restored.
    function Game:enemy_restore_spawns(uid)
        local n = 0
        for key, sp in pairs(self.erased_spawns) do
            if uid == nil or key == uid then
                if self:alive(sp) and pcall(sp.call, sp, "invalidateSpawn", false) then n = n + 1 end
                self.erased_spawns[key] = nil
            end
        end
        if n > 0 then self.perf:crumb("enemy.restore_spawns", tostring(n)) end
        return n
    end

    -- Host: the uids of every enemy our save has eliminated. The game keeps the state of every
    -- character it unloaded in CharacterManager.CharacterBackupDB (ConcurrentDictionary of
    -- ContextID code -> chainsaw.CharacterBackup, saved with the game); a backup with
    -- _IsEliminated set is an enemy that died and must never spawn again. Reads `budget`
    -- backups per call from a snapshot of the table (get_Values copies it). Returns done, uids.
    function Game:scan_eliminated(budget)
        local s = self.elim_scan
        if s == nil then
            local cm = singleton(CHARACTER_MANAGER)
            local db = cm and self:call(cm, "get_CharacterBackupDB")
            local values = db and self:call(db, "get_Values")
            if values == nil then
                self:cap("enemy_backups", false, "CharacterManager.CharacterBackupDB not readable")
                return true, {}
            end
            s = { values = values, n = tonumber(self:call(values, "get_Count")) or 0, i = 0, uids = {} }
            self.elim_scan = s
        end
        local stop = math.min(s.n, s.i + (budget or 64))
        while s.i < stop do
            local b = self:call(s.values, "get_Item", s.i)
            s.i = s.i + 1
            if b ~= nil and self:call(b, "get_IsEliminated") == true then
                local cid = self:call(b, "get_ContextID")
                if P.character_id_stable(H.context_id_table(cid)) then
                    local code = math.tointeger(tonumber(self:call(cid, "get_Code")))
                    if code ~= nil and code > 0 and code <= 0xFFFFFFFF then s.uids[#s.uids + 1] = code end
                end
            end
        end
        if s.i < s.n then return false, nil end
        self.elim_scan = nil
        self:cap("enemy_backups", true, ("%d of %d saved characters eliminated"):format(#s.uids, s.n))
        return true, s.uids
    end
end

return M
