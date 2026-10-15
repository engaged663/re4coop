-- RE4 (2023) adapter, part 6: the partner's player as a second player in our game. Installed
-- into game.lua's Game class; partner_target.lua and enemy_net.lua talk to the game only
-- through these methods. The research behind it is docs/RESEARCH.md 3.25.
--
-- Host: RE4's AI targets characters, not "the player". An enemy finds a target through its
-- TargetSensor (sight: every registered chainsaw.TargetMarker whose GameObject tag it looks for;
-- hearing: SoundDetectionManager's sounds; damage: a hit's AttackOwnerObject) and then asks the
-- target GameObject for its CharacterContext (getComponent of its body updater ->
-- BodyUpdater.<Context>); EnemyHeadUpdater.checkFindToCharacter accepts any context but
-- Ashley's. Its HateController keeps a hate value per target GameObject, and its
-- ActionTargetController chases and attacks the most hated one. Attacks land through
-- HitManager.hitSetting(info, attacker, damaged), which finds the damaged character's
-- HitController in HitManager.HitControllerList by GameObject.
--
-- So the partner's model (their real body prefab, built by puppet.lua) becomes a character
-- of our game:
--   * a stand-in context: a chainsaw.ChCommonPlContext (the player context class) made by us,
--     kind ch0_a0z0, whose position, rotation and HP follow the partner, and whose body updater
--     is the model's; the model's body updater (BodyUpdater.<Context>, a plain field write -
--     setContextRef would run entryContext) points back at it;
--   * a TargetMarker on the model with the tag of our own player's marker, so enemies see it;
--   * its damage colliders on and its HitController in HitManager's list, so enemy attacks
--     land on it; such a hit is taken off the model (callbackDamageHit skipped) and sent to the
--     partner, whose game runs it on their real character;
--   * the partner's noises registered as sounds the model makes, so enemies hear them;
--   * finishers the partner's player starts are asked of our enemy's AI head with the stand-in
--     as the attacker (requestFatalKill / requestStealthKill / convertNormalFatalAction - what
--     PlayerHeadUpdater.requestFatal & co. do with the player's own context);
--   * our own player's shots and blows pass the model: their contact is dropped before
--     HitController.poolDamage pools the damage and decides the model shields the attack;
--   * an enemy attack that warns the model (EnemyActionSignUtility: the parry/dodge prompt) is
--     reported, and the partner's parry runs as EnemyBodyUpdater.onParry(model) on our enemy;
--   * an enemy may grab the model (its own grab, held until the partner breaks free: the
--     enemy's escape check - a CheckEscapeGrapple behavior tree action - then succeeds);
--   * bosses that aim at "the player" themselves (ActionTargetController.setTypeTarget with
--     TargetType.ManualPlayer) aim at the model instead when their own hate puts it first.
--
-- Client: the noises our player makes are reported (SoundDetectionManager.registerSound), our
-- copies of the host's enemies answer the finisher checks of our player's target selector from
-- the host's information and hand the requests to the host, and a hit the host's enemies landed
-- on our character there is run on our real character the way HitManager.hitSetting runs one -
-- a grab through HitManager.hitSetting itself, with our copy of the enemy as the grabber. The
-- host's warnings reach our player's head (PlayerHeadUpdater.onHitActionSign), and our player's
-- parries of our copies go to the host.

local P = require("re4coop.protocol")
local Guard = require("re4coop.hookguard")

local M = {}

local STAND_IN_TYPE = "chainsaw.ChCommonPlContext"
local LEON_KIND = 100000                   -- chainsaw.CharacterKindID.ch0_a0z0
local STAND_IN_GROUP, STAND_IN_INDEX = 14, 4094 -- a ContextID no level or runtime character uses
local MARKER_TYPE = "chainsaw.TargetMarker"
local MARKER_OFFSET = { x = 0, y = 1.3, z = 0 } -- what enemies look at without target joints: the chest
local MARKER_REGISTER_WAIT = 1.0           -- seconds for a never-started marker to register itself
local BODY_UPDATER = "chainsaw.BodyUpdater"
local HIT_CONTROLLER = "chainsaw.HitController"
local HIT_MANAGER = "chainsaw.HitManager"
local SOUND_MANAGER = "chainsaw.SoundDetectionManager"
local SOUND_INFO = "chainsaw.SoundDetectionInfo"
local DAMAGE_INFO = "chainsaw.HitController.DamageInfo"
local ATTACK_DATA = "chainsaw.collision.AttackHitUserData.AttackData"
local ATTACK_USER_DATA = "chainsaw.collision.AttackUserData"
local COLLIDERS = "via.physics.Colliders"
local NON_LETHAL_OPTION = 4                -- AttackData._Option bit: the hit leaves 1 HP (hitSetting)
local MAX_EVENTS = 32
local HIT_HOLD = 5.0
local NOISE_HOLD = 30.0
local PART_KEY, SIDE_KEY = "DamageUserData.Parts", "DamageUserData.PartsSide"
local CHEST = 1
local ENEMY_BODY = "chainsaw.EnemyBodyUpdater"
local SHELL = "chainsaw.ShellBase"
local SIGN_UTILITY = "chainsaw.EnemyActionSignUtility"
local SIGN_HIT_INFO = "chainsaw.ActionSignHitInfo"
local ACTION_TARGET = "chainsaw.ActionTargetController"
local GRAPPLE_USER_DATA = "chainsaw.collision.GrappleUserData"
local MANUAL_PLAYER = 4                    -- chainsaw.TargetType.ManualPlayer: the enemy aims at "the player" itself
local SIGN_RANGE = 10.0                    -- host: enemies this close to the model may be warning it
local TARGETER_STALE = 0.5                 -- host: an enemy not reported targeting the model for this long is not watched
local RELEASE_FALLBACK = 0.5               -- host: seconds before an escape no behavior tree took is forced
-- share.hid.Command hashes the enemies' escape checks read (CheckEscapeGrapple.updateTargetPL).
local MASH_HASH, KNIFE_ESCAPE_HASH = 0x0ED27DB6, 0x38324405
-- Behavior tree actions that decide when a grabbed character breaks free (one per enemy kind).
local ESCAPE_TREES = { "chainsaw.Ch1b7z0BehaviorTreeAction_CheckEscapeGrapple",
    "chainsaw.Ch1c0z0BehaviorTreeAction_CheckEscapeGrapple", "chainsaw.Ch1d2z0BehaviorTreeAction_MFSM_CheckEscapeGrapple",
    "chainsaw.Ch1d3z0BehaviorTreeAction_MFSM_CheckEscapeGrapple", "chainsaw.Ch1d4z0BehaviorTreeAction_CheckEscapeGrapple",
    "chainsaw.Ch1f0z0BehaviorTreeAction_MFSM_CheckEscapeGrapple", "chainsaw.Ch1f2z0BehaviorTreeAction_CheckEscapeGrapple",
    "chainsaw.Ch1f7z0BehaviorTreeAction_CheckEscapeGrapple", "chainsaw.Ch4f9z0BehaviorTreeAction_CheckEscapeGrapple",
    "chainsaw.Ch4faz0BehaviorTreeAction_CheckEscapeGrapple", "chainsaw.Ch4faz1BehaviorTreeAction_CheckEscapeGrapple",
    "chainsaw.Ch4fbz0BehaviorTreeAction_CheckEscapeGrapple", "chainsaw.EnemyBehaviorTreeAction_MFSM_CheckEscapeGrapple",
    "chainsaw.ch4fez0BehaviorTreeAction_CheckEscapeGrapple" }
-- Bosses that pick "the nearest player" themselves (setTargetNearPlayer), from the game's players.
local NEAR_TARGET_HEADS = { "chainsaw.Ch1f0z0HeadUpdater", "chainsaw.Ch4f9z0HeadUpdater" }
-- Enemy bodies whose parry answer (IActionSignNotifier) our player's parry asks.
local PARRY_BODIES = { ENEMY_BODY, "chainsaw.Ch1d4z0BodyUpdater" }

-- Enemy AI head methods our player's finishers go through (docs/RESEARCH.md 3.25): the target
-- selector asks the queries (PlayerTargetSelector.checkTargetType), PlayerHeadUpdater's requests
-- make the requests. Every enemy kind overrides some of them.
local HEAD_QUERIES = { isEnableFatal = "fatal", isEnableKnifeFatal = "knife", isEnableStealthKill = "stealth",
    getAvailableFatalType = "ftype" }
local HEAD_REQUESTS = { requestFatalKill = P.FATAL_KIND.KILL, requestStealthKill = P.FATAL_KIND.STEALTH,
    convertNormalFatalAction = P.FATAL_KIND.NORMAL }

function M.install(Game, H)
    local singleton, find_type, address_of, type_name_of = H.singleton, H.find_type, H.address_of, H.type_name_of
    local v3 = H.v3

    local function hook_available()
        return type(sdk) == "table" and type(sdk.hook) == "function" and type(sdk.to_managed_object) == "function"
    end

    local function is_a(obj, type_name)
        local _, td = type_name_of(obj)
        local ok, r = pcall(function() return td ~= nil and td:is_a(type_name) end)
        return ok and r == true
    end

    local function get_field(obj, name)
        if obj == nil then return nil end
        local ok, v = pcall(obj.get_field, obj, name)
        if ok then return v end
        return nil
    end

    local function set_field(obj, name, v)
        if obj == nil then return false end
        return (pcall(obj.set_field, obj, name, v))
    end

    local function value_of(fields, key)
        local h = P.hash(key)
        for _, f in ipairs(fields or {}) do
            if f.h == h then return f.v end
        end
        return nil
    end

    local function raw_int(raw)
        local ok, v = pcall(sdk.to_int64, raw)
        if ok and type(v) == "number" then return v end
        return tonumber(raw)
    end

    local function method_function(m)
        local ok, fn = pcall(function() return m:get_function() end)
        return ok and fn or nil
    end

    -- The overloads of `name` in type `td` with `nparams` parameters.
    local function methods_named(td, name, nparams)
        local out = {}
        local ok, ms = pcall(function() return td:get_methods() end)
        if not ok or ms == nil then return out end
        for _, m in ipairs(ms) do
            local okN, mn = pcall(m.get_name, m)
            local okP, np = pcall(m.get_num_params, m)
            if okN and mn == name and okP and (nparams == nil or np == nparams) then out[#out + 1] = m end
        end
        return out
    end

    local function dist(a, b)
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local function new_partner_state()
        return { attached = false, upds = {}, colliders = {}, stats = { attach = 0, detach = 0, hits_seen = 0,
            hits_sent = 0, friendly = 0, grabs_blocked = 0, not_enemy = 0, noises_applied = 0, noise_failed = 0,
            fatals_run = 0, fatals_refused = 0, lost = 0, player_hits = 0, player_blocked = 0, player_failed = 0,
            noises_heard = 0, prompts = 0, requests = 0, shots_passed = 0, signs = 0, parries_run = 0,
            parries_failed = 0, parry_inputs = 0, grabs = 0, releases = 0, releases_forced = 0, boss_redirects = 0,
            player_signs = 0, player_parries = 0, player_parried = 0, player_grabs = 0, player_grab_failed = 0,
            player_released = 0 },
            damage_uds = {}, gos = {}, grab_actions = {}, grab_struggles = {}, grab_knife = {}, escape_pending = {} }
    end

    function Game:partner_state()
        local st = self.ptarget
        if st == nil then
            st = new_partner_state()
            self.ptarget = st
            self.partner_damage_events = {}
            self.noise_events = {}
            self.sign_events = {}
            self.parry_events = {}
            self.sign_infos = {}
            self.partner_targeters = {}
            self.fatal_events = self.fatal_events or {}
            self.puppet_heads = self.puppet_heads or {}
            self.head_hooks = { types = {}, fns = {} }
        end
        return st
    end

    ---------------------------------------------------------------------------
    -- Host: the stand-in context
    ---------------------------------------------------------------------------

    -- The ContextID the stand-in carries (never registered: CharacterManager does not know it).
    function Game:stand_in_id()
        local okC, id = pcall(sdk.create_instance, "chainsaw.ContextID")
        if not okC or id == nil then return nil end
        set_field(id, "_Category", 0)
        set_field(id, "_Kind", 0)
        set_field(id, "_Group", STAND_IN_GROUP)
        set_field(id, "_Index", STAND_IN_INDEX)
        return id
    end

    -- Our chainsaw.ChCommonPlContext for the partner (made once, kept for the session: enemies
    -- may hold it in their action targets). Its constructor (CharacterContext's) makes its
    -- HitPoint, timers and lists; initialize() gives it its identity and kind.
    function Game:stand_in()
        local st = self:partner_state()
        if st.ctx ~= nil and self:still_valid(st.ctx) then return st.ctx end
        local okC, ctx = pcall(sdk.create_instance, STAND_IN_TYPE)
        if not okC or ctx == nil then
            self:cap("partner_context", false, STAND_IN_TYPE .. " could not be created")
            return nil
        end
        ctx = self:keep(ctx)
        if ctx == nil then return nil end
        if self:call(ctx, "get_HitPoint") == nil then pcall(ctx.call, ctx, ".ctor") end
        local id = self:stand_in_id()
        local zero, ident = Vector3f.new(0, 0, 0), Quaternion.new(1, 0, 0, 0)
        if id ~= nil then
            id = self:keep(id)
            -- initialize(id, kind, spawn id, position, rotation, AccessoryID[]): an empty array
            -- rather than null for the accessories it copies.
            local okA, acc = pcall(sdk.create_managed_array, "chainsaw.AccessoryID", 0)
            acc = okA and acc ~= nil and self:keep(acc) or nil
            pcall(ctx.call, ctx, "initialize", id, LEON_KIND, id, zero, ident, acc)
        end
        set_field(ctx, "<KindID>k__BackingField", LEON_KIND)
        set_field(ctx, "<Setupped>k__BackingField", true)
        if self:call(ctx, "get_HitPoint") == nil then
            self:cap("partner_context", false, "the stand-in context has no HitPoint")
            return nil
        end
        st.ctx = ctx
        return ctx
    end

    -- The partner's model is a character of our game from now on (see the top of this file).
    -- opts: { hits = bool (enemy attacks land on it), grabs = bool, parry = bool (their warnings are
    -- reported), bosses = bool (bosses aiming at "the player" may aim at it) }.
    -- Returns true when enemies can find it (stand-in + body updater + marker).
    function Game:partner_target_attach(root, opts)
        local st = self:partner_state()
        opts = opts or {}
        local addr = address_of(root)
        if st.attached and st.root_addr == addr then return true end
        if st.attached then self:partner_target_detach() end
        if root == nil or addr == nil or not self:go_alive(root) then return false end
        self.perf:crumb("partner.attach", nil, true)
        local ctx = self:stand_in()
        if ctx == nil then return false end

        -- The model's body updater(s) answer "which character is this GameObject". The game
        -- reaches them (and the root) through our stand-in: they are kept referenced, so a model
        -- the game destroys never leaves a pointer to freed memory behind (see Game:keep).
        self:keep(root)
        local upds = {}
        for _, comp in ipairs(self:components(root)) do
            if is_a(comp, BODY_UPDATER) and set_field(comp, "<Context>k__BackingField", ctx) then
                upds[#upds + 1] = self:keep(comp) or comp
            end
        end
        if #upds == 0 then
            self:cap("partner_context", false, "the partner's model has no body updater")
            return false
        end
        set_field(ctx, "_BodyUpdater", upds[1])
        st.ctx, st.root, st.root_addr, st.upds = ctx, root, addr, upds
        st.attached, st.since = true, self.clock()
        st.stats.attach = st.stats.attach + 1
        self:cap("partner_context", true, ("stand-in %s on %d body updater(s)"):format(STAND_IN_TYPE, #upds))

        st.grabs = opts.grabs == true
        st.parry = opts.parry ~= false
        st.bosses = opts.bosses ~= false
        st.gos = { [addr] = true }
        if opts.hits ~= false then self:partner_hit_target(root, upds[1]) end
        self:partner_marker(root)
        return st.marker ~= nil
    end

    -- Enemy attacks land on the model: its damage colliders on, its HitController in
    -- HitManager's list (and pointing at the body updater for "whose hit controller is this").
    function Game:partner_hit_target(root, upd)
        local st = self:partner_state()
        local hc = self:get_component(root, HIT_CONTROLLER)
        if hc == nil then
            self:cap("partner_hits", false, "the partner's model has no HitController")
            return
        end
        if get_field(hc, "<ContextAccessor>k__BackingField") == nil then
            set_field(hc, "<ContextAccessor>k__BackingField", upd)
        end
        if get_field(hc, "<Delegate>k__BackingField") == nil or get_field(hc, "<DamageCalcInfo>k__BackingField") == nil then
            -- HitManager.hitSetting reads both without a check.
            self:cap("partner_hits", false, "the model's HitController was never constructed")
            return
        end
        local n = 0
        for _, node in ipairs(self:collect_tree(root, 4)) do
            local ga = address_of(node.go)
            if ga ~= nil then st.gos[ga] = true end
            for _, comp in ipairs(self:components(node.go)) do
                if type_name_of(comp) == COLLIDERS and self:damage_only(comp) then
                    -- Their DamageUserData: what our own attacks' contacts are recognised by.
                    self:damage_user_datas(comp, st.damage_uds)
                    if self:call(comp, "get_Enabled") == false and pcall(comp.call, comp, "set_Enabled", true) then
                        st.colliders[#st.colliders + 1] = comp
                        n = n + 1
                    end
                end
            end
        end
        local hm = singleton(HIT_MANAGER)
        local ok = hm ~= nil and pcall(hm.call, hm, "registerHitController", hc)
        if ok then
            st.hc, st.hc_addr = self:keep(hc) or hc, address_of(hc)
        end
        self:cap("partner_hits", ok and n > 0, ("%s, %d damage collider set(s) on"):format(
            ok and "HitController registered" or "HitManager.registerHitController failed", n))
    end

    -- Whether every collider of a via.physics.Colliders is a damage collider (DamageUserData):
    -- only those are switched on - a sensor or press collider would make the model trigger
    -- events, doors and traps, or push things around in our game.
    function Game:damage_only(cols)
        local n = tonumber(self:call(cols, "getCollidersCount")) or 0
        if n <= 0 then return false end
        for i = 0, math.min(n, 128) - 1 do
            local col = self:call(cols, "getColliders", i)
            local ud = col and self:call(col, "get_UserData")
            local tname = ud and type_name_of(ud) or nil
            if tname == nil or not tname:find("DamageUserData", 1, true) then return false end
        end
        return true
    end

    -- The addresses of the DamageUserData of a via.physics.Colliders' colliders, into `set`.
    function Game:damage_user_datas(cols, set)
        local n = tonumber(self:call(cols, "getCollidersCount")) or 0
        for i = 0, math.min(n, 128) - 1 do
            local col = self:call(cols, "getColliders", i)
            local ud = col and self:call(col, "get_UserData")
            local a = address_of(ud)
            if a ~= nil then set[a] = true end
        end
    end

    -- Our own player's TargetMarker (body or head): the tag enemies look for.
    function Game:player_marker()
        local ctx = self:player_context()
        for _, getter in ipairs({ "get_BodyGameObject", "get_HeadGameObject" }) do
            local go = ctx and self:call(ctx, getter)
            local m = go and self:get_component(go, MARKER_TYPE)
            if m ~= nil then return m, go end
        end
        return nil
    end

    -- Enemies see the model: a TargetMarker on it, registered under our player's tag.
    function Game:partner_marker(root)
        local st = self:partner_state()
        local _, mine_go = self:player_marker()
        local tag = mine_go and self:call(mine_go, "get_Tag") or nil
        local marker = self:get_component(root, MARKER_TYPE)
        local created = false
        local cur_tag = self:call(root, "get_Tag")
        if tag ~= nil and cur_tag ~= tag then
            -- register() files the marker under its GameObject's tag: set it first.
            if marker ~= nil and self:call(marker, "get_IsRegistered") == true then pcall(marker.call, marker, "unregister") end
            pcall(root.call, root, "set_Tag", tag)
        end
        if marker == nil then
            marker = self:add_component(root, MARKER_TYPE)
            created = marker ~= nil
        end
        if marker == nil then
            self:cap("partner_seen", false, "no TargetMarker on the partner's model and none could be added")
            return
        end
        marker = self:keep(marker) or marker
        set_field(marker, "_UseTargetJoint", false)
        set_field(marker, "_TargetOffset", Vector3f.new(MARKER_OFFSET.x, MARKER_OFFSET.y, MARKER_OFFSET.z))
        pcall(marker.call, marker, "set_Enabled", true)
        st.marker, st.marker_created, st.marker_since = marker, created, self.clock()
        st.marker_tag = tag
        self:cap("partner_seen", true, ("TargetMarker %s, tag %s"):format(created and "added" or "on", tostring(tag)))
    end

    -- A marker that never started (sanitized before its first update) registers itself when
    -- enabled; one that is still not registered after a moment is registered here. Never twice:
    -- TargetMarker.register adds without checking, and a stale entry would break every enemy's
    -- sight once the model is gone.
    function Game:partner_marker_check()
        local st = self:partner_state()
        local m = st.marker
        if m == nil or st.marker_checked or not self:alive(m) then return end
        if self:call(m, "get_IsRegistered") == true then
            st.marker_checked = true
        elseif self.clock() - (st.marker_since or 0) >= MARKER_REGISTER_WAIT then
            st.marker_checked = true
            pcall(m.call, m, "register")
            self:cap("partner_seen", self:call(m, "get_IsRegistered") == true, "TargetMarker registered by the mod")
        end
    end

    -- Every frame while attached: the stand-in stands where the partner's model is, with the
    -- partner's HP. pos/rot: the partner's root; hp/max_hp from their PLAYER state.
    function Game:partner_target_update(pos, rot, hp, max_hp)
        local st = self:partner_state()
        if not st.attached then return false end
        if not self:go_alive(st.root) then
            -- The game unloaded the model (puppet.lua rebuilds it): the HitController and the
            -- marker went with it (their onDestroy unregisters them).
            st.stats.lost = st.stats.lost + 1
            self:partner_target_detach(true)
            return false
        end
        local ctx = st.ctx
        if pos ~= nil then
            local v = Vector3f.new(pos.x, pos.y, pos.z)
            set_field(ctx, "<Position>k__BackingField", v)
            set_field(ctx, "<LastValidPosition>k__BackingField", v)
            st.pos = { x = pos.x, y = pos.y, z = pos.z }
        end
        if rot ~= nil then
            local q = Quaternion.new(rot.w, rot.x, rot.y, rot.z)
            set_field(ctx, "<Rotation>k__BackingField", q)
            set_field(ctx, "<LastValidRotation>k__BackingField", q)
        end
        if hp ~= nil then
            local hpo = self:call(ctx, "get_HitPoint")
            if hpo ~= nil then
                if max_hp ~= nil and max_hp > 0 then set_field(hpo, "<DefaultHitPoint>k__BackingField", math.floor(max_hp)) end
                local want = math.max(0, math.floor(hp))
                if st.hp_written ~= want and self:write_hp(hpo, want) then st.hp_written = want end
            end
        end
        self:partner_marker_check()
        if st.parry then self:partner_sign_poll() end
        return true
    end

    -- The partner's model is no character of our game any more: enemies forget it, its
    -- marker and colliders go off. gone: the model was already destroyed.
    function Game:partner_target_detach(gone)
        local st = self:partner_state()
        if not st.attached then return end
        self.perf:crumb("partner.detach", nil, true)
        st.stats.detach = st.stats.detach + 1
        local root = st.root
        -- Enemies chasing it let go (HateController.lose; EnemyHeadUpdater.<HateController>).
        if root ~= nil then
            for _, ctx in pairs(self.enemy_ctx or {}) do
                local upd = self:call(ctx, "get_HeadUpdater")
                local hate = upd and get_field(upd, "<HateController>k__BackingField")
                if hate ~= nil then pcall(hate.call, hate, "lose", root) end
            end
        end
        if not gone then
            if st.marker ~= nil and self:alive(st.marker) then pcall(st.marker.call, st.marker, "set_Enabled", false) end
            for _, c in ipairs(st.colliders) do
                if self:alive(c) then pcall(c.call, c, "set_Enabled", false) end
            end
            local hm = singleton(HIT_MANAGER)
            if hm ~= nil and st.hc ~= nil and self:alive(st.hc) then pcall(hm.call, hm, "unregisterHitController", st.hc) end
            for _, u in ipairs(st.upds) do
                if self:alive(u) then set_field(u, "<Context>k__BackingField", nil) end
            end
        end
        -- Enemies may still hold the stand-in as their action target's context for a moment:
        -- its body is no model any more (CharacterContext.get_BodyGameObject reads _BodyUpdater).
        if st.ctx ~= nil then set_field(st.ctx, "_BodyUpdater", nil) end
        st.attached, st.root, st.root_addr, st.upds, st.colliders = false, nil, nil, {}, {}
        st.hc, st.hc_addr, st.marker, st.marker_checked = nil, nil, nil, nil
        st.damage_uds, st.gos, st.grab_actions, st.escape_pending, st.pos = {}, {}, {}, {}, nil
        self.sign_events = {}
        self.partner_targeters = {}
    end

    function Game:partner_target_attached()
        local st = self.ptarget
        return st ~= nil and st.attached == true
    end

    ---------------------------------------------------------------------------
    -- Host: hits the partner's model takes
    ---------------------------------------------------------------------------

    -- HitManager.hitSetting(info, attacker, damaged) with the model as the damaged character.
    -- Returns true to skip the hit: our own player's (no friendly fire), and a grab (its
    -- enemy would hold a model that never struggles) unless grabs are allowed.
    function Game:partner_hit_setting(info, attacker_hc)
        local st = self:partner_state()
        if not st.attached then return true end
        local owner = attacker_hc and self:call(attacker_hc, "get_GameObject")
        if self.player_objects[address_of(owner) or false] then
            st.stats.friendly = st.stats.friendly + 1
            return true
        end
        local au = self:call(info, "get_AttackUserData")
        if au ~= nil and not st.grabs and self:call(au, "get_IsGrapple") == true then
            st.stats.grabs_blocked = st.stats.grabs_blocked + 1
            return true
        end
        return false
    end

    -- HitController.callbackDamageHit on the model: the hit is the partner's to take (sent),
    -- the model takes nothing. Returns true when `hc` is the model's.
    function Game:partner_damage_hit(hc, info)
        local st = self.ptarget
        if st == nil or st.hc_addr == nil or address_of(hc) ~= st.hc_addr then return false end
        st.stats.hits_seen = st.stats.hits_seen + 1
        -- Which enemy: its body owns the attack (a thrown weapon carries its thrower as owner).
        local id
        for _, getter in ipairs({ "get_AttackOwnerObject", "get_AttackGameObject" }) do
            local go = self:call(info, getter)
            id = go and self.enemy_by_body[address_of(go) or false]
            if id ~= nil then break end
        end
        if id == nil then
            -- An explosion, a trap...: it happens in the partner's game as well.
            st.stats.not_enemy = st.stats.not_enemy + 1
            return true
        end
        local au = self:call(info, "get_AttackUserData")
        local ev = {
            id = id, fields = self:read_damage_fields(info),
            attack_id = tonumber(au and get_field(au, "_AttackHitDataID")) or -1,
            key_hash = tonumber(au and get_field(au, "_KeyNameHash")) or 0,
        }
        if au ~= nil and self:call(au, "get_IsGrapple") == true then
            -- A grab: the partner's game rebuilds it as a grab (GrappleUserData), with its priority.
            ev.grab, ev.grab_priority = true, tonumber(get_field(au, "_GrapplePriority")) or 0
        end
        local q = self.partner_damage_events
        if #q < MAX_EVENTS then q[#q + 1] = ev end
        st.stats.hits_sent = st.stats.hits_sent + 1
        self:cap("partner_damage", true, ("%d enemy hits on the partner's model"):format(st.stats.hits_sent))
        return true
    end

    function Game:take_partner_damage_events()
        self:partner_state()
        local q = self.partner_damage_events
        if #q == 0 then return q end
        self.partner_damage_events = {}
        return q
    end

    function Game:install_partner_hooks()
        if self.partner_hooks_installed then return end
        self.partner_hooks_installed = true
        if not hook_available() then return end
        local game = self
        -- hitSetting: friendly fire and grabs on the partner's model.
        local hm_td = find_type(HIT_MANAGER)
        local okM, hs = pcall(function() return hm_td and hm_td:get_method("hitSetting") end)
        if okM and hs ~= nil then
            local skipped = false
            pcall(Guard.hook, hs, function(args)
                skipped = false
                if not game.active or game.ptarget == nil or game.ptarget.hc_addr == nil then return end
                local skip = false
                pcall(function()
                    local damaged = sdk.to_managed_object(args[5])
                    if address_of(damaged) ~= game.ptarget.hc_addr then return end
                    skip = game:partner_hit_setting(sdk.to_managed_object(args[3]), sdk.to_managed_object(args[4]))
                end)
                if skip then
                    skipped = true
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
        -- While we ask our enemies about the partner's finishers, the knife the partner's
        -- character has is assumed (see enemy_partner_info).
        local ph_td = find_type("chainsaw.PlayerHeadUpdater")
        local okK, hk = pcall(function() return ph_td and ph_td:get_method("hasKnife") end)
        if okK and hk ~= nil then
            local probed = false
            pcall(Guard.hook, hk, function()
                probed = false
                if game.knife_probe then
                    probed = true
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(retval)
                if probed then
                    probed = false
                    return sdk.to_ptr(1)
                end
                return retval
            end)
        end
        self:install_partner_hooks_v2()
        -- The partner's noises: SoundDetectionManager.registerSound.
        local sm_td = find_type(SOUND_MANAGER)
        local okR, rs = pcall(function() return sm_td and sm_td:get_method("registerSound") end)
        if okR and rs ~= nil then
            local ok = pcall(Guard.hook, rs, function(args)
                if not game.active or not game.capture_noise then return end
                pcall(function() game:on_sound(sdk.to_managed_object(args[3])) end)
            end, function(retval) return retval end)
            self:cap("noise_hook", ok, ok and "SoundDetectionManager.registerSound" or "sdk.hook failed")
        else
            self:cap("noise_hook", false, "SoundDetectionManager.registerSound not found")
        end
    end


    ---------------------------------------------------------------------------
    -- Hooks for shots, warnings, parries, grabs and bosses (0.10.1, docs/RESEARCH.md 3.26)
    ---------------------------------------------------------------------------

    function Game:install_partner_hooks_v2()
        local game = self
        -- Host: our own attacks pass the partner's model. HitController.poolDamage(collisionInfo,
        -- attackUserData, damageUserData, childToParent) runs on the attacker's controller for every
        -- contact: it pools the damage and asks shieldingDecision whether the body stops the attack.
        local hc_td = find_type(HIT_CONTROLLER)
        local okP, pd = pcall(function() return hc_td and hc_td:get_method("poolDamage") end)
        if okP and pd ~= nil then
            local ok = pcall(Guard.hook, pd, function(args)
                local st = game.ptarget
                if not game.active or st == nil or not st.attached then return end
                local skip = false
                pcall(function()
                    if not st.damage_uds[raw_int(args[5]) or false] then return end
                    skip = game:partner_pool_damage(sdk.to_managed_object(args[2]))
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(retval) return retval end)
            self:cap("partner_shots", ok, ok and "HitController.poolDamage" or "sdk.hook failed")
        else
            self:cap("partner_shots", false, "HitController.poolDamage not found")
        end

        -- Host: an enemy attack warns the model (EnemyActionSignUtility.sendActionSignInfo(owner,
        -- target, info): the model has no player head to show it, so the partner's game does).
        local su_td = find_type(SIGN_UTILITY)
        for _, m in ipairs(su_td and methods_named(su_td, "sendActionSignInfo", 3) or {}) do
            pcall(Guard.hook, m, function(args)
                local st = game.ptarget
                if not game.active or st == nil or not st.attached or not st.parry then return end
                local skip = false
                pcall(function()
                    if not st.gos[raw_int(args[4]) or false] then return end
                    skip = true
                    game:partner_sign(sdk.to_managed_object(args[3]), sdk.to_managed_object(args[5]), nil)
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(retval) return retval end)
        end

        -- Host: the enemy that grabs the model, and with which action (EnemyHeadUpdater.requestGrapple).
        local eh_td = find_type("chainsaw.EnemyHeadUpdater")
        local okG, rg = pcall(function() return eh_td and eh_td:get_method("requestGrapple") end)
        if okG and rg ~= nil then
            pcall(Guard.hook, rg, function(args)
                local st = game.ptarget
                if not game.active or st == nil or not st.attached then return end
                pcall(function()
                    if not st.gos[raw_int(args[3]) or false] then return end
                    game:partner_grab_started(sdk.to_managed_object(args[2]), (raw_int(args[4]) or 0) & 0xFFFFFFFF)
                end)
            end, function(retval) return retval end)
        end

        -- Host: the partner broke free: the grabbing enemy's escape check succeeds (each enemy
        -- kind has its own CheckEscapeGrapple action; derived kinds may share one body).
        local seen = {}
        local n_trees = 0
        for _, tname in ipairs(ESCAPE_TREES) do
            local td = find_type(tname)
            local okU, upd = pcall(function() return td and td:get_method("update") end)
            local fn = okU and upd and method_function(upd) or nil
            if upd ~= nil and (fn == nil or not seen[fn]) then
                if fn ~= nil then seen[fn] = true end
                if pcall(Guard.hook, upd, function(args)
                    local st = game.ptarget
                    if not game.active or st == nil or not st.attached then return end
                    local skip = false
                    pcall(function()
                        skip = game:partner_escape_tree(sdk.to_managed_object(args[2]), sdk.to_managed_object(args[3]))
                    end)
                    if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
                end, function(retval) return retval end) then n_trees = n_trees + 1 end
            end
        end
        self:cap("partner_grab", n_trees > 0, ("%d escape checks watched"):format(n_trees))

        -- Host: bosses aiming at "the player" themselves (ActionTargetController.setTypeTarget(type,
        -- target[, offset]) with TargetType.ManualPlayer and our player's body).
        local at_td = find_type(ACTION_TARGET)
        local n_boss = 0
        for _, np in ipairs({ 2, 3 }) do
            for _, m in ipairs(at_td and methods_named(at_td, "setTypeTarget", np) or {}) do
                local okT, types = pcall(m.get_param_types, m)
                local okN, tn = pcall(function() return types[2]:get_full_name() end)
                if okT and okN and tn == "via.GameObject" then
                    if pcall(Guard.hook, m, function(args)
                        local st = game.ptarget
                        if not game.active or st == nil or not st.attached or not st.bosses then return end
                        pcall(function()
                            if ((raw_int(args[3]) or -1) & 0xFFFFFFFF) ~= MANUAL_PLAYER then return end
                            if not game.player_objects[raw_int(args[4]) or false] then return end
                            if game:boss_prefers_partner(sdk.to_managed_object(args[2])) then
                                args[4] = sdk.to_ptr(st.root)
                                st.stats.boss_redirects = st.stats.boss_redirects + 1
                                game:cap("partner_bosses", true, ("%d boss targets turned to the partner"):format(
                                    st.stats.boss_redirects))
                            end
                        end)
                    end, function(retval) return retval end) then n_boss = n_boss + 1 end
                end
            end
        end
        if n_boss == 0 then self:cap("partner_bosses", false, "ActionTargetController.setTypeTarget not found") end
        for _, tname in ipairs(NEAR_TARGET_HEADS) do
            local td = find_type(tname)
            local okN, m = pcall(function() return td and td:get_method("setTargetNearPlayer") end)
            if okN and m ~= nil then
                pcall(Guard.hook, m, function() game.near_intent = true end, function(retval)
                    game.near_intent = false
                    return retval
                end)
            end
        end

        -- Client: our player's parry of one of our copies of the host's enemies
        -- (IActionSignNotifier.onParry / onParryInput on the copy's body).
        for _, tname in ipairs(PARRY_BODIES) do
            local td = find_type(tname)
            local okO, op = pcall(function() return td and td:get_method("onParry") end)
            if okO and op ~= nil then
                local cur = nil
                pcall(Guard.hook, op, function(args)
                    cur = nil
                    if not game.active or next(game.puppets or {}) == nil then return end
                    pcall(function()
                        local id = game:puppet_of_body(sdk.to_managed_object(args[2]))
                        if id ~= nil then cur = { id = id, sign = raw_int(args[4]) or 0 } end
                    end)
                end, function(retval)
                    local c = cur
                    cur = nil
                    if c ~= nil then
                        local ok = false
                        pcall(function()
                            local r = sdk.to_managed_object(retval)
                            ok = r ~= nil and r:call("get_Successful") == true
                        end)
                        game:queue_parry(c.id, P.PARRY_KIND.PARRY, c.sign, ok)
                    end
                    return retval
                end)
            end
            local okI, oi = pcall(function() return td and td:get_method("onParryInput") end)
            if okI and oi ~= nil then
                pcall(Guard.hook, oi, function(args)
                    if not game.active or next(game.puppets or {}) == nil then return end
                    pcall(function()
                        local id = game:puppet_of_body(sdk.to_managed_object(args[2]))
                        if id ~= nil then game:queue_parry(id, P.PARRY_KIND.INPUT, 0, true) end
                    end)
                end, function(retval) return retval end)
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Host: our attacks pass the model
    ---------------------------------------------------------------------------

    -- A contact of `attacker_hc`'s attack on the model: true (dropped) unless it is an enemy's.
    -- Whose: the controller's AttackOwner or GameObject, else a shell's (bullet, bolt) owner.
    function Game:partner_pool_damage(attacker_hc)
        local st = self.ptarget
        local go = self:call(attacker_hc, "get_GameObject")
        local shell = go and self:get_component(go, SHELL)
        local cands = { self:call(attacker_hc, "get_AttackOwner") or false, go or false,
            shell and get_field(shell, "<AttackOwner>k__BackingField") or false }
        for _, o in ipairs(cands) do
            local a = o and address_of(o)
            if a ~= nil then
                if self.enemy_by_body[a] then return false end
                if self.player_objects[a] then
                    st.stats.shots_passed = st.stats.shots_passed + 1
                    self:cap("partner_shots", true, ("%d of our shots passed the partner"):format(st.stats.shots_passed))
                    return true
                end
            end
        end
        return false
    end

    ---------------------------------------------------------------------------
    -- Host: warnings and parries
    ---------------------------------------------------------------------------

    -- Whether enemy `id`'s most hated target is the model.
    function Game:enemy_targets_partner(id)
        local st = self.ptarget
        local upd = self:enemy_head(id)
        local hate = upd and get_field(upd, "<HateController>k__BackingField")
        local cur = hate and get_field(hate, "<CurrentTarget>k__BackingField")
        local go = cur and get_field(cur, "<TargetGameObject>k__BackingField")
        return go ~= nil and st ~= nil and address_of(go) == st.root_addr
    end

    -- Enemy (body GameObject `owner_go`) warns the model with `info` (an EnemyActionSignInfo):
    -- remembered for the partner (one per enemy and frame). just: its "just" timing, if known.
    function Game:partner_sign(owner_go, info, just)
        local st = self.ptarget
        local id = owner_go and self.enemy_by_body[address_of(owner_go) or false]
        if id == nil or info == nil then return false end
        if just == nil then just = get_field(info, "_JustTiming") == true end
        self.sign_events[id] = { id = id, sign_type = tonumber(get_field(info, "_SignType")) or 0,
            button = tonumber(get_field(info, "_ButtonSetting")) or 0, just = just,
            act = get_field(info, "_ActTiming") == true, angle_check = get_field(info, "_TargetAngleCheck") == true }
        st.stats.signs = st.stats.signs + 1
        self:cap("partner_parry", true, ("%d warnings for the partner"):format(st.stats.signs))
        return true
    end

    -- Every frame: the enemies whose target is the model (enemy_partner_info, a few times a
    -- second) and whose attack warns now (EnemyBodyUpdater's action sign), within the warning's
    -- reach - also when the warning's collider never touched the model.
    function Game:partner_sign_poll()
        local st = self.ptarget
        local mp = st.pos
        if mp == nil or next(self.partner_targeters) == nil then return end
        local now = self.clock()
        for id, seen in pairs(self.partner_targeters) do
            local ctx = self.enemy_ctx[id]
            if ctx == nil or now - seen > TARGETER_STALE then
                self.partner_targeters[id] = nil
            else
                local body = self:call(ctx, "get_BodyUpdater")
                if body ~= nil and self:call(body, "checkEnableActionSign") == true then
                    local p = v3(self:call(ctx, "get_Position"))
                    local info = self:call(body, "getActionSignInfo")
                    local d = tonumber(info and get_field(info, "_Distance")) or 0
                    if p ~= nil and info ~= nil and dist(p, mp) <= SIGN_RANGE and (d <= 0 or dist(p, mp) <= d + 0.5) then
                        self:partner_sign(self:call(body, "get_GameObject"), info,
                            self:call(body, "checkJustTimingActionSign") == true)
                    end
                end
            end
        end
    end

    function Game:take_sign_events()
        local st = self:partner_state()
        local out = {}
        for _, ev in pairs(self.sign_events) do out[#out + 1] = ev end
        if #out > 0 then self.sign_events = {} end
        return out
    end

    -- The partner's player parried enemy `id` (P.PARRY_KIND): our enemy's body is told, with the
    -- model as the parrying character - it staggers as from our own player's parry.
    function Game:enemy_partner_parry(id, kind, sign_type)
        local st = self:partner_state()
        local ctx = self.enemy_ctx[id]
        local body = ctx and self:call(ctx, "get_BodyUpdater")
        if body == nil or not st.attached or st.root == nil or self:enemy_head(id) == nil then
            st.stats.parries_failed = st.stats.parries_failed + 1
            return false
        end
        self.perf:crumb("enemy.partner_parry", tostring(kind), "now")
        if kind == P.PARRY_KIND.INPUT then
            local ok = pcall(body.call, body, "onParryInput")
            if ok then st.stats.parry_inputs = st.stats.parry_inputs + 1 end
            return ok
        end
        -- The stand-in has no head here: EnemyHeadUpdater.notifyParry skips the parrying knife's
        -- wear (the partner's game wore its own knife down).
        local r = self:call(body, "onParry", st.root, sign_type or 0)
        if r ~= nil then
            st.stats.parries_run = st.stats.parries_run + 1
            self:cap("partner_parry", true, ("%d parries of the partner run"):format(st.stats.parries_run))
            return true
        end
        st.stats.parries_failed = st.stats.parries_failed + 1
        return false
    end

    ---------------------------------------------------------------------------
    -- Host: grabs
    ---------------------------------------------------------------------------

    -- The enemy whose AI head is `head`.
    function Game:enemy_of_head(head)
        local a = address_of(head)
        if a == nil then return nil end
        for id, ctx in pairs(self.enemy_ctx) do
            if address_of(self:call(ctx, "get_HeadUpdater")) == a then return id end
        end
        return nil
    end

    function Game:partner_grab_started(head, action)
        local st = self.ptarget
        local id = self:enemy_of_head(head)
        if id == nil then return end
        st.grab_actions[id] = action
        st.stats.grabs = st.stats.grabs + 1
        self:cap("partner_grab", true, ("%d grabs on the partner"):format(st.stats.grabs))
    end

    -- Our enemies holding the model now: { [id] = {action, struggles, knife} }. Escapes no
    -- behavior tree took within RELEASE_FALLBACK are forced here.
    function Game:partner_grabbers(now)
        local st = self.ptarget
        local out = {}
        if st == nil or not st.attached then return out end
        for id, ctx in pairs(self.enemy_ctx) do
            local g = get_field(ctx, "<GrappleTarget>k__BackingField")
            if g ~= nil and st.gos[address_of(g) or false] then
                out[id] = { action = st.grab_actions[id] or 0, struggles = st.grab_struggles[id], knife = st.grab_knife[id] }
            end
        end
        for id, at in pairs(st.escape_pending) do
            if out[id] == nil then
                st.escape_pending[id] = nil
            elseif now - at >= RELEASE_FALLBACK then
                st.escape_pending[id] = nil
                self:force_release(id, out[id].action)
                out[id] = nil
            end
        end
        return out
    end

    -- The partner broke free of enemy `id`: its escape check succeeds on its next update.
    function Game:enemy_partner_release(id, how)
        local st = self:partner_state()
        if self.enemy_ctx[id] == nil then return false end
        st.escape_pending[id] = self.clock()
        return true
    end

    -- No escape check took it (an enemy kind without one, or not running): the grab is undone
    -- the way a rejected grab is (EnemyHeadUpdater.onRejectGrapple), and the target let go.
    function Game:force_release(id, action)
        local st = self.ptarget
        local head = self:enemy_head(id)
        if head == nil then return end
        pcall(head.call, head, "onRejectGrapple", action or 0)
        pcall(head.call, head, "clearGrappleTarget")
        st.stats.releases_forced = st.stats.releases_forced + 1
    end

    -- A CheckEscapeGrapple action of an enemy holding someone, before its update. Returns true
    -- when it was made to succeed (the partner broke free of that enemy).
    function Game:partner_escape_tree(action, arg)
        local st = self.ptarget
        local t = self:typeof(ENEMY_BODY)
        local body = t and self:call(arg, "getComponent(System.Type)", t)
        local go = body and self:call(body, "get_GameObject")
        local id = go and self.enemy_by_body[address_of(go) or false]
        if id == nil then return false end
        if st.grab_struggles[id] == nil then
            local n = tonumber(get_field(action, "NumberOfStruggles"))
            if n ~= nil and n > 0 then st.grab_struggles[id] = math.floor(n) end
            local k = get_field(action, "isEnableKnifeEscape")
            if k ~= nil then st.grab_knife[id] = k == true end
        end
        if st.escape_pending[id] == nil then return false end
        st.escape_pending[id] = nil
        pcall(action.call, action, "onSuccessfulEscape", arg)
        if not pcall(arg.call, arg, "notifyActionEnd") then return false end
        st.stats.releases = st.stats.releases + 1
        self:cap("partner_grab", true, ("%d escapes of the partner"):format(st.stats.releases))
        return true
    end

    ---------------------------------------------------------------------------
    -- Host: bosses
    ---------------------------------------------------------------------------

    -- An enemy's ActionTargetController is about to aim at our player as "the player": should it
    -- aim at the model? Yes when its own hate puts the model first, or - for the bosses that
    -- pick the nearest player themselves - when the model is nearer.
    function Game:boss_prefers_partner(ctl)
        local st = self.ptarget
        local hate = self:call(ctl, "get_HateController")
        local cur = hate and get_field(hate, "<CurrentTarget>k__BackingField")
        local go = cur and get_field(cur, "<TargetGameObject>k__BackingField")
        if go ~= nil and address_of(go) == st.root_addr then return true end
        if not self.near_intent or st.pos == nil then return false end
        local me = self:call(ctl, "get_GameObject")
        local tr = me and self:call(me, "get_Transform")
        local p = tr and v3(self:call(tr, "get_Position"))
        local mine = self:player_context()
        local pp = mine and v3(self:call(mine, "get_Position"))
        return p ~= nil and pp ~= nil and dist(p, st.pos) < dist(p, pp)
    end

    ---------------------------------------------------------------------------
    -- Client: the host's warnings, our parries, the host's grabs
    ---------------------------------------------------------------------------

    -- The enemy id of a body updater, when that enemy is one of our copies of the host's enemies.
    function Game:puppet_of_body(body)
        local go = body and self:call(body, "get_GameObject")
        local id = go and self.enemy_by_body[address_of(go) or false]
        if id ~= nil and self.puppets[id] ~= nil then return id end
        return nil
    end

    function Game:queue_parry(id, kind, sign_type, ok)
        local st = self:partner_state()
        local q = self.parry_events
        if #q < MAX_EVENTS then q[#q + 1] = { id = id, kind = kind, sign_type = sign_type or 0, ok = ok } end
        if kind == P.PARRY_KIND.PARRY then
            st.stats.player_parries = st.stats.player_parries + 1
            if ok then st.stats.player_parried = st.stats.player_parried + 1 end
        end
    end

    function Game:take_parry_events()
        self:partner_state()
        local q = self.parry_events
        if #q == 0 then return q end
        self.parry_events = {}
        return q
    end

    -- The host's enemy (our copy `id`) warns our character (m: the ACTION_SIGN message): our
    -- player's head gets it as from our own game's enemy - the parry/dodge prompt, and our
    -- parry then asks our copy (IActionSignNotifier, see install_partner_hooks_v2).
    function Game:player_action_sign(id, m)
        local st = self:partner_state()
        local info = self:live_enemy(id)
        local body = info and info.body
        local ctx = self:player_context()
        local head = ctx and self:call(ctx, "get_HeadUpdater")
        if body == nil or head == nil then return false end
        local hi = self.sign_infos[id]
        if hi == nil or not self:still_valid(hi) then
            local okC, obj = pcall(sdk.create_instance, SIGN_HIT_INFO)
            if not okC or obj == nil then
                self:cap("partner_parry", false, SIGN_HIT_INFO .. " could not be created")
                return false
            end
            hi = self:keep(obj)
            if hi == nil then return false end
            self.sign_infos[id] = hi
        end
        set_field(hi, "OwnerGameObject", body)
        set_field(hi, "SignType", m.sign_type or 0)
        set_field(hi, "ButtonType", m.button or 0)
        set_field(hi, "JustTiming", m.just == true)
        set_field(hi, "ActTiming", m.act == true)
        set_field(hi, "TargetAngleCheck", m.angle_check == true)
        local ok = pcall(head.call, head, "onHitActionSign", hi)
        if ok then st.stats.player_signs = st.stats.player_signs + 1 end
        self:cap("partner_parry", ok, ok and ("%d warnings of the host's enemies shown"):format(st.stats.player_signs)
            or "PlayerHeadUpdater.onHitActionSign failed")
        return ok
    end

    -- Whether our character is held by an enemy now.
    function Game:player_grabbed()
        local ctx = self:player_context()
        return ctx ~= nil and self:call(ctx, "get_IsInGrappleDamage") == true
    end

    -- Our player's escape input this frame while held: "knife" (and a knife allowed), "mash", or
    -- nil - the presses the enemies' own escape checks count (share.hid.Command.isTrigger).
    function Game:player_grab_input(knife)
        local ctx = self:player_context()
        local head = ctx and self:call(ctx, "get_HeadUpdater")
        local cmd = head and get_field(head, "<Command>k__BackingField")
        if cmd == nil then return nil end
        if knife and self:call(cmd, "isTrigger(System.UInt32)", KNIFE_ESCAPE_HASH) == true
            and self:call(head, "hasKnife") ~= false then
            return "knife"
        end
        if self:call(cmd, "isTrigger(System.UInt32)", MASH_HASH) == true then return "mash" end
        return nil
    end

    -- Our character is let go by our copy `id` of the host's enemy (we broke free, or the host's
    -- enemy let go): the copy's grab is undone as a rejected one (which also drops the motion
    -- it lent our character) and our character leaves its grab action.
    function Game:player_grab_release(id, action)
        local st = self:partner_state()
        local ctx = id and self.enemy_ctx[id]
        local head = ctx and self:call(ctx, "get_HeadUpdater")
        if head ~= nil then
            pcall(head.call, head, "onRejectGrapple", action or 0)
            pcall(head.call, head, "clearGrappleTarget")
        end
        if self:player_grabbed() then
            local pctx = self:player_context()
            local body = pctx and self:call(pctx, "get_BodyUpdater")
            if body ~= nil then pcall(body.call, body, "set_RequestCancelGrappleAction", true) end
        end
        st.stats.player_released = st.stats.player_released + 1
        return true
    end

    ---------------------------------------------------------------------------
    -- Noises
    ---------------------------------------------------------------------------

    -- Client: a sound our player made (its owner or requester is our player's body or head).
    function Game:on_sound(info)
        if info == nil then return end
        local owner = get_field(info, "<OwnerGameObject>k__BackingField")
        local req = get_field(info, "<RequestGameObject>k__BackingField")
        if not (self.player_objects[address_of(owner) or false] or self.player_objects[address_of(req) or false]) then
            return
        end
        local pos = v3(get_field(info, "Position"))
        if pos == nil then return end
        local q = self:partner_noise_queue()
        if #q >= MAX_EVENTS then table.remove(q, 1) end
        q[#q + 1] = { pos = pos, radius = tonumber(get_field(info, "Radius")) or 0,
            height = tonumber(get_field(info, "Height")) or 0, volume = tonumber(get_field(info, "Volume")) or 0,
            sub = tonumber(get_field(info, "SubVolumePerSec")) or 0 }
        local st = self:partner_state()
        st.stats.noises_heard = st.stats.noises_heard + 1
    end

    function Game:partner_noise_queue()
        self:partner_state()
        return self.noise_events
    end

    function Game:take_noise_events()
        local q = self:partner_noise_queue()
        if #q == 0 then return q end
        self.noise_events = {}
        return q
    end

    -- Host: the partner's noise, made by their model in our world (enemies hear it and look
    -- for its owner).
    function Game:partner_noise(n)
        local st = self:partner_state()
        if not st.attached then return false end
        local sm = singleton(SOUND_MANAGER)
        local okC, info = pcall(sdk.create_instance, SOUND_INFO)
        if sm == nil or not okC or info == nil then
            st.stats.noise_failed = st.stats.noise_failed + 1
            return false
        end
        info = self:hold(info, NOISE_HOLD)
        set_field(info, "Position", Vector3f.new(n.pos.x, n.pos.y, n.pos.z))
        set_field(info, "Radius", n.radius or 0)
        set_field(info, "Height", n.height or 0)
        set_field(info, "Volume", n.volume or 0)
        set_field(info, "SubVolumePerSec", n.sub or 0)
        set_field(info, "<OwnerGameObject>k__BackingField", st.root)
        set_field(info, "<RequestGameObject>k__BackingField", st.root)
        local ok = pcall(sm.call, sm, "registerSound", info)
        if ok then
            st.stats.noises_applied = st.stats.noises_applied + 1
        else
            st.stats.noise_failed = st.stats.noise_failed + 1
        end
        self:cap("partner_heard", ok, ok and ("%d noises of the partner"):format(st.stats.noises_applied)
            or "SoundDetectionManager.registerSound failed")
        return ok
    end

    ---------------------------------------------------------------------------
    -- Host: finishers of the partner's player, and what our enemies say about them
    ---------------------------------------------------------------------------

    function Game:enemy_head(id)
        local ctx = self.enemy_ctx[id]
        local upd = ctx and self:call(ctx, "get_HeadUpdater")
        if upd == nil or not self:head_linked(upd) then return nil end
        return upd
    end

    -- The partner's player started a finisher on enemy `id`: its AI head gets the request our
    -- own player's PlayerHeadUpdater would have made, with the stand-in as the attacker.
    function Game:enemy_partner_fatal(id, kind, ftype)
        local st = self:partner_state()
        local upd = self:enemy_head(id)
        if upd == nil or not st.attached or st.ctx == nil then
            st.stats.fatals_refused = st.stats.fatals_refused + 1
            return false
        end
        self.perf:crumb("enemy.partner_fatal", tostring(kind), "now")
        local r
        if kind == P.FATAL_KIND.KILL then
            r = self:call(upd, "requestFatalKill", st.ctx)
        elseif kind == P.FATAL_KIND.STEALTH then
            r = self:call(upd, "requestStealthKill", st.ctx)
        elseif kind == P.FATAL_KIND.NORMAL then
            r = self:call(upd, "convertNormalFatalAction", st.ctx, ftype or 0)
        end
        if r == true then
            st.stats.fatals_run = st.stats.fatals_run + 1
            self:cap("partner_fatal", true, ("%d finishers of the partner run"):format(st.stats.fatals_run))
            return true
        end
        st.stats.fatals_refused = st.stats.fatals_refused + 1
        return false
    end

    -- What enemy `id` says about the partner's player: P.PARTNER_INFO bits and the finisher
    -- type it offers (near: also ask the finisher checks). nil while not attached.
    function Game:enemy_partner_info(id, near)
        local st = self.ptarget
        if st == nil or not st.attached or st.ctx == nil then return nil end
        local upd = self:enemy_head(id)
        if upd == nil then return nil end
        local I = P.PARTNER_INFO
        local pinfo, ftype = I.KNOWN, 0
        local hate = get_field(upd, "<HateController>k__BackingField")
        local cur = hate and get_field(hate, "<CurrentTarget>k__BackingField")
        local go = cur and get_field(cur, "<TargetGameObject>k__BackingField")
        if go ~= nil and address_of(go) == st.root_addr then
            pinfo = pinfo | I.TARGETS
            -- Its warnings are looked for every frame (partner_sign_poll).
            self.partner_targeters[id] = self.clock()
        end
        if near then
            local ctx = st.ctx
            -- Some checks ask the attacker's own head whether it has a knife
            -- (PlayerHeadUpdater.hasKnife, virtual +0x318: EnemyHeadUpdater.isEnableKnifeFatal, the
            -- bosses' isEnableFatal). The stand-in has no head: for these pure queries it borrows
            -- our player's, whose hasKnife answers yes (install_partner_hooks) - the partner's game
            -- adds its own player's answer (puppet_fatal_answer).
            local mine = self:player_context()
            local head = mine and self:call(mine, "get_HeadUpdater") or nil
            if head ~= nil then
                set_field(ctx, "_HeadUpdater", head)
                self.knife_probe = true
            end
            if self:call(upd, "isEnableFatal", ctx) == true then pinfo = pinfo | I.FATAL end
            if self:call(upd, "isEnableKnifeFatal", ctx) == true then pinfo = pinfo | I.KNIFE end
            if self:call(upd, "isEnableStealthKill", ctx, false) == true then pinfo = pinfo | I.STEALTH end
            ftype = math.tointeger(tonumber(self:call(upd, "getAvailableFatalType")) or 0) or 0
            if head ~= nil then
                self.knife_probe = false
                set_field(ctx, "_HeadUpdater", nil)
            end
        end
        return pinfo, ftype
    end

    ---------------------------------------------------------------------------
    -- Client: our copies of the host's enemies answer our player's finishers
    ---------------------------------------------------------------------------

    -- A puppet's AI head (enemy_set_puppet): its finisher methods are hooked (once per method
    -- body: enemy kinds share and override them).
    function Game:watch_puppet_head(id, upd)
        self:partner_state()
        local a = address_of(upd)
        if a == nil then return end
        self.puppet_heads[a] = id
        local tname, td = type_name_of(upd)
        local hh = self.head_hooks
        if tname == nil or hh.types[tname] or not hook_available() then return end
        hh.types[tname] = true
        local game = self
        local function hook(name, kind, query)
            local okM, m = pcall(function() return td:get_method(name) end)
            if not okM or m == nil then return end
            local fn = method_function(m)
            if fn ~= nil and hh.fns[fn] then return end
            if fn ~= nil then hh.fns[fn] = true end
            local answer = nil
            pcall(Guard.hook, m, function(args)
                answer = nil
                if not game.active then return end
                local pid
                pcall(function() pid = game.puppet_heads[address_of(sdk.to_managed_object(args[2])) or false] end)
                if pid == nil then return end
                if query then
                    answer = game:puppet_fatal_answer(pid, kind)
                else
                    answer = game:puppet_fatal_request(pid, kind, kind == P.FATAL_KIND.NORMAL and raw_int(args[4]) or 0)
                end
                if answer ~= nil then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(retval)
                local a2 = answer
                answer = nil
                if a2 ~= nil then return sdk.to_ptr(a2) end
                return retval
            end)
        end
        for name, kind in pairs(HEAD_QUERIES) do hook(name, kind, true) end
        for name, kind in pairs(HEAD_REQUESTS) do hook(name, kind, false) end
    end

    function Game:forget_puppet_head(upd)
        local a = address_of(upd)
        if a ~= nil and self.puppet_heads ~= nil then self.puppet_heads[a] = nil end
    end

    -- Our player's target selector asks puppet `id`: the host's answer (or no, without one).
    function Game:puppet_fatal_answer(id, what)
        local st = self:partner_state()
        st.stats.prompts = st.stats.prompts + 1
        local q = self.partner_fatal_query
        local pinfo, ftype
        if q ~= nil then pinfo, ftype = q(id) end
        local I = P.PARTNER_INFO
        if pinfo == nil or (pinfo & I.KNOWN) == 0 then pinfo, ftype = 0, 0 end
        if what == "ftype" then return math.tointeger(ftype or 0) or 0 end
        local bit = (what == "fatal" and I.FATAL) or (what == "knife" and I.KNIFE) or I.STEALTH
        if (pinfo & bit) == 0 then return 0 end
        if what == "knife" then
            -- The host's enemy allows it; whether our player has a knife is ours to say.
            local ctx = self:player_context()
            local head = ctx and self:call(ctx, "get_HeadUpdater")
            if head ~= nil and self:call(head, "hasKnife") == false then return 0 end
        end
        return 1
    end

    -- Our player asks puppet `id` for a finisher: the host's game runs it (take_fatal_events);
    -- here the request is granted at once (our player's side plays) and the puppet does nothing.
    function Game:puppet_fatal_request(id, kind, ftype)
        local st = self:partner_state()
        st.stats.requests = st.stats.requests + 1
        local ps = self.last_player_pose
        local ev = { id = id, kind = kind, ftype = (ftype or 0) & 0xFF,
            pos = ps and ps.pos or nil, yaw = ps and ps.yaw or 0 }
        local q = self.fatal_events
        for _, v in ipairs(q) do
            if v.id == id and v.kind == kind then return 1 end
        end
        if #q < MAX_EVENTS then q[#q + 1] = ev end
        self.perf:crumb("enemy.fatal_request", tostring(kind), true)
        return 1
    end

    ---------------------------------------------------------------------------
    -- Client: a hit our character took in the host's game
    ---------------------------------------------------------------------------

    -- One of our player's damage colliders (body part `part`, side `side`; else the chest; else
    -- any): collider, DamageUserData | nil.
    function Game:player_damage_collider(hc, part, side)
        local cols = hc and self:call(hc, "get_Colliders")
        local n = cols and tonumber(self:call(cols, "getCollidersCount")) or 0
        local best, best_score = nil, -1
        for i = 0, math.min(n, 128) - 1 do
            local col = self:call(cols, "getColliders", i)
            local ud = col and self:call(col, "get_UserData")
            local tname = ud and type_name_of(ud) or nil
            if tname ~= nil and tname:find("DamageUserData", 1, true) then
                local parts = tonumber(get_field(ud, "Parts"))
                local s = tonumber(get_field(ud, "PartsSide"))
                local score = 0
                if part ~= nil and parts == part then
                    score = (side == nil or s == side) and 4 or 3
                elseif parts == CHEST then
                    score = 2
                end
                if score > best_score then best, best_score = { col, ud }, score end
                if score == 4 then break end
            end
        end
        if best == nil then return nil, nil end
        return best[1], best[2]
    end

    -- The AttackUserData a replayed enemy hit carries (HitController.playDamageSe reads it):
    -- one per attack, made once and kept. A grab's is a GrappleUserData (get_IsGrapple answers
    -- yes) with the grab's priority.
    function Game:attack_user_data(attack_id, key_hash, grab, priority)
        self.attack_uds = self.attack_uds or {}
        local key = tostring(attack_id) .. ":" .. tostring(key_hash) .. (grab and (":g" .. tostring(priority)) or "")
        local au = self.attack_uds[key]
        if au ~= nil then return au end
        local okC, obj = pcall(sdk.create_instance, grab and GRAPPLE_USER_DATA or ATTACK_USER_DATA)
        if not okC or obj == nil then return nil end
        obj = self:keep(obj)
        if obj == nil then return nil end
        set_field(obj, "_AttackHitDataID", attack_id or -1)
        set_field(obj, "_KeyNameHash", key_hash or 0)
        if grab then set_field(obj, "_GrapplePriority", priority or 0) end
        self.attack_uds[key] = obj
        return obj
    end

    -- The attack's own data: HitManager's catalog by the attack's id and key (the same data in
    -- both games), else a copy of one of our player's carrying the attack's values.
    function Game:enemy_attack_data(attack_id, key_hash, fields)
        if attack_id ~= nil and attack_id >= 0 then
            local hm = singleton(HIT_MANAGER)
            local ad = hm and self:call(hm, "getAttackData", attack_id, key_hash or 0)
            if ad ~= nil and type_name_of(ad) == ATTACK_DATA then return ad, true end
        end
        local tpl = self:hit_template(nil)
        if tpl == nil then return nil, false end
        return self:attack_data_for(tpl, fields), false
    end

    -- The host's enemy `attacker_id` (our copy of it, or nil) hit our character in the host's
    -- game: the hit runs on our real character the way HitManager.hitSetting runs one - kill
    -- decided by our HP, our character's own damage check (a dodge, invincibility), the
    -- non-lethal attacks' last HP, then callbackDamageHit (damage, reaction, death).
    -- A grab (hit.grab) runs through HitManager.hitSetting itself with our copy of the enemy as
    -- the grabber: our character's dodge checks, then the grab the copy plays on our character
    -- (HitManager.requestGrapple); without a copy, only the grab's damage.
    -- hit = { fields, attack_id, key_hash, grab, grab_priority }. Returns "applied" | "blocked" | "failed".
    function Game:player_take_hit(hit, attacker_id)
        local st = self:partner_state()
        local ctx = self:player_context()
        local body = ctx and self:call(ctx, "get_BodyGameObject")
        local hc = body and self:get_component(body, HIT_CONTROLLER)
        if hc == nil then
            st.stats.player_failed = st.stats.player_failed + 1
            return "failed"
        end
        local okC, d = pcall(sdk.create_instance, DAMAGE_INFO)
        if not okC or d == nil then
            st.stats.player_failed = st.stats.player_failed + 1
            return "failed"
        end
        d = self:hold(d, HIT_HOLD)
        self:write_damage_fields(d, hit.fields)
        local ad, exact = self:enemy_attack_data(hit.attack_id, hit.key_hash, hit.fields)
        local au = self:attack_user_data(hit.attack_id, hit.key_hash, hit.grab, hit.grab_priority)
        if ad == nil or au == nil or not (pcall(d.call, d, "set_AttackUserData", au) and pcall(d.call, d, "set_AttackData", ad)) then
            st.stats.player_failed = st.stats.player_failed + 1
            self:cap("partner_damage", false, "no attack data for an enemy hit on our character")
            return "failed"
        end
        if exact then st.stats.exact_attacks = (st.stats.exact_attacks or 0) + 1 end
        local col, du = self:player_damage_collider(hc, value_of(hit.fields, PART_KEY), value_of(hit.fields, SIDE_KEY))
        if du == nil then
            st.stats.player_failed = st.stats.player_failed + 1
            return "failed"
        end
        local info = attacker_id and self:live_enemy(attacker_id)
        local attacker = info and info.body or body
        pcall(d.call, d, "set_DamageCollidable", col)
        pcall(d.call, d, "set_DamageUserData", du)
        pcall(d.call, d, "set_AttackOwnerObject", attacker)
        pcall(d.call, d, "set_AttackGameObject", attacker)
        pcall(d.call, d, "set_DamageGameObject", body)
        pcall(d.call, d, "set_WeaponGameObject", nil)
        pcall(d.call, d, "set_ChildHitController", nil)
        pcall(d.call, d, "set_AttackCollidable", nil)
        if hit.grab and info ~= nil and self.settings.enemy_partner_grabs ~= false then
            local r = self:player_take_grab(d, info.body, hc)
            if r ~= nil then return r end
        end
        local damage = tonumber(self:call(d, "get_Damage")) or 0
        pcall(d.call, d, "set_IsKill", self:call(hc, "checkKill", damage) == true)
        self.perf:crumb("player.hit_from_host", nil, "now")
        if self:call(hc, "callbackCheckDamageHit", d) == false then
            st.stats.player_blocked = st.stats.player_blocked + 1
            return "blocked"
        end
        local option = tonumber(get_field(ad, "_Option")) or 0
        if (option & NON_LETHAL_OPTION) ~= 0 and self:call(hc, "checkKill", damage) == true then
            local cur = tonumber(self:call(hc, "get_CurrentHitPoint")) or 1
            pcall(d.call, d, "set_Damage", math.max(0, math.floor(cur) - 1))
            damage = tonumber(self:call(d, "get_Damage")) or 0
        end
        pcall(d.call, d, "set_IsKill", self:call(hc, "checkKill", damage) == true)
        local calc = get_field(hc, "<DamageCalcInfo>k__BackingField")
        if calc ~= nil then pcall(calc.call, calc, "copy", d) end
        self.replaying_player = true
        local ok = pcall(hc.call, hc, "callbackDamageHit", d)
        self.replaying_player = false
        if not ok then
            st.stats.player_failed = st.stats.player_failed + 1
            self:cap("partner_damage", false, "callbackDamageHit on our character failed")
            return "failed"
        end
        st.stats.player_hits = st.stats.player_hits + 1
        self:cap("partner_damage", true, ("%d hits from the host's enemies taken"):format(st.stats.player_hits))
        return "applied"
    end

    -- A grab of our copy of the host's enemy (body `attacker`) on our character (HitController
    -- `hc`), DamageInfo `d` ready: the game's own hit code runs it. nil when it could not run (the
    -- caller falls back to the damage alone).
    function Game:player_take_grab(d, attacker, hc)
        local st = self:partner_state()
        local ahc = attacker and self:get_component(attacker, HIT_CONTROLLER)
        local hm = singleton(HIT_MANAGER)
        if ahc == nil or hm == nil then return nil end
        self.perf:crumb("player.grab_from_host", nil, "now")
        self.replaying_player = true
        local ok = pcall(hm.call, hm, "hitSetting", d, ahc, hc)
        self.replaying_player = false
        if not ok then
            st.stats.player_grab_failed = st.stats.player_grab_failed + 1
            self:cap("partner_grab", false, "HitManager.hitSetting failed for a grab on our character")
            return nil
        end
        st.stats.player_grabs = st.stats.player_grabs + 1
        self:cap("partner_grab", true, ("%d grabs of the host's enemies on our character"):format(st.stats.player_grabs))
        return "applied"
    end

    function Game:partner_stats()
        local st = self:partner_state()
        return st.stats, st.attached
    end
end

return M
