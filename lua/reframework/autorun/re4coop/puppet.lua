-- The partner's character in our world.
--
-- Built from the partner's AVATAR: their real body prefab, found automatically from their
-- character id (e.g. _chainsaw/appsystem/character/ch0a0z0/ch0a0z0_body.pfb for Leon),
-- sanitized so it is a pure visual (game logic, physics and animation switched off), plus
-- the costume parts they wear. Every frame it takes their POSE - root placement and the
-- local rotation of every skeleton joint - so whatever the partner's character does (walk,
-- run, crouch, aim, shoot, reload, knife, kick, climb, get grabbed, die) ours does too.
-- Weapons come from the weapon prefabs and hang on the same hand joint. Sounds, effects
-- and shots from ACTIONS are replayed on the matching components.
--
-- If the body prefab cannot be found or loaded, the model is rebuilt from the partner's
-- meshes instead ("mirror" mode).
--
-- All game access goes through the adapter (game.lua); tested against the REFramework mock.

local P = require("re4coop.protocol")

local Puppet = {}
Puppet.__index = Puppet

local LOAD_TIMEOUT = 15.0   -- seconds to wait for a prefab before falling back
local RETRY_AFTER = 3.0     -- seconds before rebuilding a model the game unloaded
local ROT_EPS = 1e-5        -- joint writes that would change less than this are skipped
local FLASH_LIFETIME = 0.4
local FAILED_RETRY = 10.0   -- seconds before trying again after a model could not be built
local EFFECT_MEMORY = 2.0   -- a weapon whose own effects replayed this recently needs no fallback flash

local function new_counters()
    return {
        builds = 0, parts_rebuilt = 0, part_failures = 0, hidden = 0, disabled = 0,
        sounds = 0, effects = 0, shots = 0, flashes = 0, replay_failed = 0, replay_skipped = 0,
        joint_writes = 0,
    }
end

function Puppet.new(game, log)
    local self = setmetatable({}, Puppet)
    self.game = game
    self.log = log or function() end
    self.counters = new_counters()
    self.flashes = {}
    self.flash_prefab = nil
    self.retry_at = nil
    self:reset_model()
    return self
end

function Puppet:reset_model()
    self.state = "idle"   -- idle | loading | ready | failed
    self.mode = nil       -- prefab | mirror
    self.key = nil
    self.avatar = nil
    self.prefab = nil
    self.prefab_path = nil
    self.detail = nil
    self.root, self.root_tf = nil, nil
    self.part_go = {}
    self.created = {}
    self.draw_list = {}
    self.comp_index = {}
    self.jmap, self.tjoints, self.name_of_hash, self.joint_owner = {}, {}, {}, {}
    self.joints_mapped, self.joints_total = 0, 0
    self.weapons = {}
    self.gear_rev = nil
    self.visible = nil
    self.late_writes = false
    self.probe = nil
    self.last_pose = nil
    self.effect_seen = {}
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

-- st: the receiver's render state { avatar, gear, pose } (or nil when there is no partner)
-- opts: { hidden = bool, meshes_only = bool (skip the body prefab) }
function Puppet:update(now, st, opts)
    opts = opts or {}
    self.now = now
    self:expire_flashes(now)
    if st == nil or st.avatar == nil then
        if self.state ~= "idle" then self:destroy() end
        return
    end
    if self.state == "failed" and now >= (self.retry_at or math.huge) then
        self:destroy() -- try again (the failure may have been a loading screen)
    end
    local av = st.avatar
    local key = ("%d|%s|%d|%d|%s"):format(av.rev, av.char_id, #av.parts, #av.joints, tostring(opts.meshes_only))
    if key ~= self.key then
        if now < (self.retry_at or -math.huge) then return end
        self:destroy()
        self.key, self.avatar = key, av
        self:begin_build(now, st, opts.meshes_only)
    end
    if self.state == "loading" then self:continue_build(now, st) end
    if self.state ~= "ready" then return end
    if not self.game:alive(self.root_tf) then
        -- The game unloaded the area, and our objects with it: rebuild in a moment.
        self.log("partner model was unloaded by the game; rebuilding")
        self:destroy()
        self.retry_at = now + RETRY_AFTER
        return
    end

    local visible = st.pose ~= nil and not opts.hidden
    self:set_visible(visible)
    self:update_weapons(now, st)
    if visible then
        self.last_pose = st.pose
        if not self.late_writes then self:apply_pose(st.pose, false) end
    end
end

-- PrepareRendering: runs after the engine's animation update. If something overwrote our
-- pose (a prefab whose animation could not be switched off), write it again here, and from
-- then on every frame.
function Puppet:late_update()
    if self.state ~= "ready" or not self.visible or self.last_pose == nil then return end
    if not self.late_writes then
        local e = self.probe
        if e ~= nil and e.x ~= nil then
            local x, y, z, w = self.game:get_joint_rotation(e.joint)
            if x ~= nil and math.abs(x - e.x) + math.abs(y - e.y) + math.abs(z - e.z) + math.abs(w - e.w) > 1e-3 then
                self.late_writes = true
                self.log("partner model: the engine overwrites the pose; writing it after animation")
            end
        end
    end
    if self.late_writes then
        self:apply_pose(self.last_pose, true)
    end
end

function Puppet:destroy()
    local g = self.game
    self:destroy_weapons()
    for i = #self.created, 1, -1 do
        g:destroy_game_object(self.created[i])
        g:release(self.created[i])
    end
    if self.root ~= nil then
        g:destroy_game_object(self.root)
        g:release(self.root)
    end
    if self.prefab ~= nil then g:release(self.prefab) end
    self:reset_model()
end

-- Script reset / unload: also drop the shared resources.
function Puppet:shutdown()
    self:destroy()
    for _, f in ipairs(self.flashes) do self.game:destroy_game_object(f.go) end
    self.flashes = {}
    if self.flash_prefab then self.game:release(self.flash_prefab) end
    self.flash_prefab = nil
end

function Puppet:is_visible()
    return self.state == "ready" and self.visible == true
end

-------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------

function Puppet:begin_build(now, st, meshes_only)
    local g = self.game
    self.counters.builds = self.counters.builds + 1
    self.build_started = now
    if meshes_only then
        self:build_mirror(st, "built from meshes (option)")
        return
    end
    local path = g:find_body_prefab(self.avatar.char_id)
    self.prefab_path = path
    if path ~= nil then
        self.prefab = g:load_prefab(path)
    end
    if self.prefab ~= nil then
        self.state = "loading"
        self.detail = "loading " .. path
    else
        self:build_mirror(st, path and ("could not load " .. path)
            or ("no body prefab for '" .. tostring(self.avatar.char_id) .. "'"))
    end
end

function Puppet:continue_build(now, st)
    local g = self.game
    if g:prefab_ready(self.prefab) then
        -- Before the first pose arrives, spawn out of sight; it stays hidden until posed.
        local pos = st.pose and st.pose.root_pos or { x = 0, y = -1000, z = 0 }
        local go = g:instantiate(self.prefab, pos)
        if go ~= nil then
            self:assemble_prefab(go)
        else
            self:build_mirror(st, "instantiate failed for " .. self.prefab_path)
        end
    elseif now - self.build_started > LOAD_TIMEOUT then
        self:build_mirror(st, "timed out loading " .. self.prefab_path)
    end
end

-- One costume part rebuilt from its mesh and material, attached like the partner's.
function Puppet:make_part(part)
    local g = self.game
    local go = g:create_mesh_object("re4coop_" .. part.name, part.mesh, part.mdf)
    if go == nil then
        self.counters.part_failures = self.counters.part_failures + 1
        return nil
    end
    g:claim(go)
    local parent = self.part_go[part.parent] or self.root
    g:attach(go, parent, {
        joint = part.parent_joint or "",
        same_joints = (part.flags & P.PART_FLAGS.SAME_JOINTS) ~= 0,
        lpos = part.lpos, lrot = part.lrot,
    })
    self.created[#self.created + 1] = go
    self.counters.parts_rebuilt = self.counters.parts_rebuilt + 1
    return go
end

function Puppet:assemble_prefab(go)
    local g = self.game
    self.mode = "prefab"
    self.detail = self.prefab_path
    self.root, self.root_tf = go, g:transform_of(go)
    local tree = g:collect_tree(go)
    for _, node in ipairs(tree) do g:claim(node.go, "re4coop_" .. g:name_of(node.go)) end
    self.counters.disabled = g:sanitize(tree)

    -- Match the meshes the prefab shows with the parts the partner wears (by mesh path);
    -- fix materials (dirt/blood variants), hide what they do not wear, rebuild the rest.
    local shown = {}
    for _, node in ipairs(tree) do
        local mesh, mdf, comp = g:mesh_info(node.go)
        if mesh ~= nil then
            shown[#shown + 1] = { go = node.go, mesh = mesh:lower(), mdf = (mdf or ""):lower(), comp = comp }
        end
    end
    self.part_go = { [0] = go }
    for i, part in ipairs(self.avatar.parts) do
        local want = part.mesh:lower()
        for _, s in ipairs(shown) do
            if not s.used and s.mesh == want then
                s.used = true
                self.part_go[i] = s.go
                if part.mdf ~= "" and part.mdf:lower() ~= s.mdf then
                    g:set_mesh(s.comp, nil, part.mdf)
                end
                break
            end
        end
    end
    local hidden = {}
    for _, s in ipairs(shown) do
        if not s.used then
            g:set_drawn(s.go, false)
            hidden[s.go] = true
            self.counters.hidden = self.counters.hidden + 1
        end
    end
    for i, part in ipairs(self.avatar.parts) do
        if self.part_go[i] == nil then
            self.part_go[i] = self:make_part(part)
        end
    end

    local is_part = {}
    for i, pgo in pairs(self.part_go) do
        if i > 0 and pgo ~= go then is_part[pgo] = true end
    end
    local root_nodes = {}
    self.draw_list = {}
    for _, node in ipairs(tree) do
        if not hidden[node.go] then self.draw_list[#self.draw_list + 1] = node.go end
        if not is_part[node.go] then root_nodes[#root_nodes + 1] = node.go end
    end
    for _, c in ipairs(self.created) do self.draw_list[#self.draw_list + 1] = c end
    self:finish(root_nodes)
end

function Puppet:build_mirror(st, reason)
    local g = self.game
    if self.prefab ~= nil then
        g:release(self.prefab)
        self.prefab = nil
    end
    self.mode = "mirror"
    self.detail = reason
    local parts = self.avatar.parts
    local main
    for i, part in ipairs(parts) do
        if (part.flags & P.PART_FLAGS.MAIN) ~= 0 then main = i break end
    end
    main = main or (#parts > 0 and 1 or nil)
    -- The root carries the main skeleton (the body mesh), so constrained parts follow it.
    local root, root_has_main
    if main ~= nil then
        root = g:create_mesh_object("re4coop_partner", parts[main].mesh, parts[main].mdf)
        root_has_main = root ~= nil
    end
    root = root or g:create_game_object("re4coop_partner")
    if root ~= nil then g:claim(root) end
    if root == nil then
        self.state = "failed"
        self.detail = reason .. "; could not create a GameObject"
        self.retry_at = (self.now or 0) + FAILED_RETRY
        self.log("partner model failed: " .. self.detail)
        return
    end
    self.root, self.root_tf = root, g:transform_of(root)
    if st and st.pose then g:set_world_transform(self.root_tf, st.pose.root_pos, st.pose.root_rot) end
    self.part_go = { [0] = root }
    if root_has_main then self.part_go[main] = root end
    for i, part in ipairs(parts) do
        if self.part_go[i] == nil then
            self.part_go[i] = self:make_part(part)
        end
    end
    self.draw_list = { root }
    for _, c in ipairs(self.created) do self.draw_list[#self.draw_list + 1] = c end
    self:finish({ root })
end

-- Sound/effect components of `nodes`, indexed the way the sender numbers them.
function Puppet:index_components(nodes)
    local g = self.game
    local index = { by_type = {}, first = {} }
    for _, go in ipairs(nodes) do
        for _, comp in ipairs(g:components(go)) do
            local tname, td = g:type_name(comp)
            local kind = tname and g:mirror_kind_of(td)
            if kind ~= nil then
                local h = P.hash(tname)
                local list = index.by_type[h] or {}
                list[#list + 1] = comp
                index.by_type[h] = list
                index.first[kind] = index.first[kind] or comp
            end
        end
    end
    return index
end

-- Pose index -> joints to write. Parts that follow the root's joints (SameJointsConstraint)
-- only get the joints the root lacks (hair, face).
function Puppet:build_joint_map()
    local g = self.game
    local av = self.avatar
    local index_of = {}
    for i, j in ipairs(av.joints) do index_of[j.hash] = i end
    local jmap, tjoints, names, owners = {}, {}, {}, {}
    local mapped, root_names = {}, {}
    local function add(tf, skip, owner)
        for _, joint in ipairs(g:joint_list(tf)) do
            local name = g:joint_name(joint)
            if name ~= nil then
                local h = P.hash(name)
                if names[h] == nil then names[h], owners[h] = name, owner end
                local idx = index_of[h]
                if idx ~= nil and not (skip and skip[name]) then
                    jmap[#jmap + 1] = { joint = joint, idx = idx, root = skip == nil }
                    mapped[idx] = true
                    if (av.joints[idx].flags & P.JOINT_FLAGS.TRANSLATE) ~= 0 then
                        local list = tjoints[idx] or {}
                        list[#list + 1] = joint
                        tjoints[idx] = list
                    end
                end
                if skip == nil then root_names[name] = true end
            end
        end
    end
    add(self.root_tf, nil, self.root)
    for i, part in ipairs(av.parts) do
        local pgo = self.part_go[i]
        if pgo ~= nil and pgo ~= self.root then
            local same = (part.flags & P.PART_FLAGS.SAME_JOINTS) ~= 0
            add(g:transform_of(pgo), same and root_names or {}, pgo)
        end
    end
    local n = 0
    for _ in pairs(mapped) do n = n + 1 end
    self.jmap, self.tjoints, self.name_of_hash, self.joint_owner = jmap, tjoints, names, owners
    self.joints_mapped, self.joints_total = n, #av.joints
end

function Puppet:finish(root_nodes)
    self.comp_index = { [0] = self:index_components(root_nodes) }
    for i, pgo in pairs(self.part_go) do
        if i > 0 and pgo ~= self.root then
            self.comp_index[i] = self:index_components({ pgo })
        end
    end
    self:build_joint_map()
    self.state = "ready"
    self.visible = nil
    self:set_visible(false) -- until the first pose places it
    self.log(("partner model ready (%s, %d/%d joints): %s"):format(self.mode, self.joints_mapped,
        self.joints_total, self.detail or ""))
end

-------------------------------------------------------------------------------
-- Every frame
-------------------------------------------------------------------------------

function Puppet:set_visible(v)
    if v == self.visible then return end
    self.visible = v
    for _, go in ipairs(self.draw_list) do
        self.game:set_drawn(go, v)
    end
end

function Puppet:apply_pose(pose, force)
    local g = self.game
    g:set_world_transform(self.root_tf, pose.root_pos, pose.root_rot)
    local q = pose.q
    local writes = 0
    for _, e in ipairs(self.jmap) do
        local k = e.idx * 4
        local x, y, z, w = q[k - 3], q[k - 2], q[k - 1], q[k]
        if x ~= nil and (force or e.x == nil
            or math.abs(x - e.x) + math.abs(y - e.y) + math.abs(z - e.z) + math.abs(w - e.w) > ROT_EPS) then
            if g:set_joint_rotation(e.joint, x, y, z, w) then
                e.x, e.y, e.z, e.w = x, y, z, w
                writes = writes + 1
                -- Watch a body joint (not hair/cloth, which their own physics may move).
                if self.probe == nil and e.root and math.abs(w) < 0.95 then self.probe = e end
            end
        end
    end
    for _, t in ipairs(pose.tpos) do
        local list = self.tjoints[t.index]
        if list ~= nil then
            for _, joint in ipairs(list) do g:set_joint_position(joint, t.x, t.y, t.z) end
        end
    end
    self.counters.joint_writes = writes
end

-------------------------------------------------------------------------------
-- Weapons
-------------------------------------------------------------------------------

function Puppet:begin_weapon(now, slot, desc)
    local g = self.game
    local w = { slot = slot, desc = desc, state = "loading", started = now, jmap = {}, draw_list = {} }
    w.path = g:find_weapon_prefab(desc.name)
    if w.path ~= nil then w.prefab = g:load_prefab(w.path) end
    if w.prefab == nil then self:finish_weapon_mirror(w) end
    return w
end

function Puppet:continue_weapon(now, w)
    local g = self.game
    if g:prefab_ready(w.prefab) then
        local go = g:instantiate(w.prefab, { x = 0, y = -1000, z = 0 })
        if go ~= nil then
            self:finish_weapon(w, go, "prefab")
        else
            self:finish_weapon_mirror(w)
        end
    elseif now - w.started > LOAD_TIMEOUT then
        self:finish_weapon_mirror(w)
    end
end

function Puppet:finish_weapon_mirror(w)
    if w.prefab ~= nil then
        self.game:release(w.prefab)
        w.prefab = nil
    end
    local go = w.desc.mesh ~= "" and self.game:create_mesh_object("re4coop_" .. w.desc.name, w.desc.mesh, w.desc.mdf)
    if go then
        self:finish_weapon(w, go, "mirror")
    else
        w.state = "failed"
    end
end

function Puppet:finish_weapon(w, go, mode)
    local g = self.game
    w.go, w.tf, w.mode = go, g:transform_of(go), mode
    local tree = g:collect_tree(go, 3)
    for _, node in ipairs(tree) do
        local name = g:name_of(node.go)
        g:claim(node.go, name:find("^re4coop_") and nil or ("re4coop_" .. name))
    end
    if mode == "prefab" then g:sanitize(tree) end
    local nodes = {}
    for _, node in ipairs(tree) do
        w.draw_list[#w.draw_list + 1] = node.go
        nodes[#nodes + 1] = node.go
    end
    g:attach(go, self.root, { joint = "", same_joints = false })
    w.attached, w.holder = "", self.root
    local index_of = {}
    for i, h in ipairs(w.desc.joints) do index_of[h] = i end
    for _, joint in ipairs(g:joint_list(w.tf)) do
        local name = g:joint_name(joint)
        if name ~= nil then
            local idx = index_of[P.hash(name)]
            if idx ~= nil then w.jmap[#w.jmap + 1] = { joint = joint, idx = idx } end
            if w.muzzle == nil and name:lower():find("muzzle", 1, true) then w.muzzle = joint end
        end
    end
    self.comp_index[P.REF.WEAPON_BASE + w.slot] = self:index_components(nodes)
    w.visible = nil
    self:set_weapon_visible(w, false)
    w.state = "ready"
    self:preload_flash()
end

-- The fallback muzzle flash loads in the background so the first shot already has it.
function Puppet:preload_flash()
    if self.flash_prefab == nil then
        local path = self.game:muzzle_flash_prefab()
        self.flash_prefab = path and self.game:load_prefab(path) or false
    end
end

function Puppet:set_weapon_visible(w, v)
    if v == w.visible then return end
    w.visible = v
    for _, go in ipairs(w.draw_list) do self.game:set_drawn(go, v) end
end

function Puppet:destroy_weapons()
    local g = self.game
    for slot, w in pairs(self.weapons) do
        if w.go ~= nil then
            g:destroy_game_object(w.go)
            g:release(w.go)
        end
        if w.prefab ~= nil then g:release(w.prefab) end
        self.comp_index[P.REF.WEAPON_BASE + slot] = nil
    end
    self.weapons = {}
end

function Puppet:place_weapon(w, wp)
    local g = self.game
    local joint, holder = "", self.root
    if wp.attach ~= nil and wp.attach > 0 then
        local j = self.avatar.joints[wp.attach]
        joint = j and self.name_of_hash[j.hash]
        if joint == nil then
            -- The hand joint does not exist on this model: better hidden than floating.
            self:set_weapon_visible(w, false)
            return
        end
        holder = self.joint_owner[j.hash] or self.root
    end
    if joint ~= w.attached or holder ~= w.holder then
        g:attach(w.go, holder, { joint = joint, same_joints = false })
        w.attached, w.holder = joint, holder
    end
    g:set_local_transform(w.tf, wp.pos, wp.rot)
    local q = wp.q
    for _, e in ipairs(w.jmap) do
        local k = e.idx * 4
        local x, y, z, ww = q[k - 3], q[k - 2], q[k - 1], q[k]
        if x ~= nil and (e.x == nil or math.abs(x - e.x) + math.abs(y - e.y) + math.abs(z - e.z) + math.abs(ww - e.w) > ROT_EPS) then
            if g:set_joint_rotation(e.joint, x, y, z, ww) then
                e.x, e.y, e.z, e.w = x, y, z, ww
            end
        end
    end
end

function Puppet:update_weapons(now, st)
    local gear = st.gear
    local rev = gear and gear.rev or -1
    if rev ~= self.gear_rev then
        self:destroy_weapons()
        self.gear_rev = rev
        for slot, desc in ipairs(gear and gear.weapons or {}) do
            self.weapons[slot] = self:begin_weapon(now, slot, desc)
        end
    end
    local by_slot = {}
    for _, wp in ipairs(st.pose and st.pose.weapons or {}) do by_slot[wp.slot] = wp end
    for _, w in pairs(self.weapons) do
        if w.state == "loading" then self:continue_weapon(now, w) end
        if w.state == "ready" then
            if not self.game:alive(w.tf) then
                w.state = "failed"
            else
                local wp = by_slot[w.slot]
                local vis = self.visible and wp ~= nil and (wp.flags & P.WEAPON_FLAGS.VISIBLE) ~= 0
                self:set_weapon_visible(w, vis)
                if vis then self:place_weapon(w, wp) end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Sounds, effects, shots
-------------------------------------------------------------------------------

function Puppet:go_for_ref(ref)
    if ref == P.REF.BODY or ref == P.REF.HEAD then return self.root end
    if ref > P.REF.WEAPON_BASE then
        local w = self.weapons[ref - P.REF.WEAPON_BASE]
        return (w and w.go) or self.root
    end
    return self.part_go[ref] or self.root
end

function Puppet:find_component(ref, type_hash, idx, kind)
    local index = self.comp_index[ref]
    if index == nil then
        if ref > P.REF.WEAPON_BASE then return nil end -- that weapon is not spawned (yet)
        index = self.comp_index[0]                     -- head and unknown parts: the body
    end
    if index == nil then return nil end
    local list = index.by_type[type_hash]
    local comp = list and (list[idx] or list[1]) or index.first[kind]
    if comp == nil and self.comp_index[0] ~= nil then comp = self.comp_index[0].first[kind] end
    return comp
end

-- opts: { audio = bool, effects = bool }
function Puppet:replay(events, opts)
    if #events == 0 then return end
    if self.state ~= "ready" or not self.visible then
        self.counters.replay_skipped = self.counters.replay_skipped + #events
        return
    end
    local g = self.game
    local resolve = function(ref) return self:go_for_ref(ref) end
    for _, ev in ipairs(events) do
        if ev.kind == P.EVENT.CALL then
            local kind = g:mirror_kind(ev.method)
            if (kind == "sound" and opts.audio) or (kind == "effect" and opts.effects) then
                local comp = self:find_component(ev.part, ev.comp_type, ev.comp_idx, kind)
                if comp ~= nil and g:replay_call(comp, ev, resolve) then
                    if kind == "sound" then
                        self.counters.sounds = self.counters.sounds + 1
                    else
                        self.counters.effects = self.counters.effects + 1
                        if ev.part > P.REF.WEAPON_BASE then self.effect_seen[ev.part - P.REF.WEAPON_BASE] = self.now end
                    end
                else
                    self.counters.replay_failed = self.counters.replay_failed + 1
                end
            end
        elseif ev.kind == P.EVENT.SHOT then
            self.counters.shots = self.counters.shots + 1
            if opts.effects then self:muzzle_flash(ev.slot) end
        end
    end
end

-- Shots whose weapon effects did not come through the effect mirror get the game's
-- generic muzzle flash at the gun's muzzle.
function Puppet:muzzle_flash(slot)
    local w = self.weapons[slot]
    if w == nil or w.state ~= "ready" or not w.visible then return end
    local seen = self.effect_seen[slot]
    if seen ~= nil and self.now - seen < EFFECT_MEMORY then return end
    local g = self.game
    self:preload_flash()
    if not self.flash_prefab or not g:prefab_ready(self.flash_prefab) then return end
    local pos = (w.muzzle and g:joint_world_position(w.muzzle)) or (g:world_transform(w.tf))
    if pos == nil then return end
    local go = g:instantiate(self.flash_prefab, pos)
    if go ~= nil then
        g:claim(go, "re4coop_muzzleflash")
        self.flashes[#self.flashes + 1] = { go = go, t = self.now }
        self.counters.flashes = self.counters.flashes + 1
    end
end

function Puppet:expire_flashes(now)
    if #self.flashes == 0 then return end
    local keep = {}
    for _, f in ipairs(self.flashes) do
        if now - f.t > FLASH_LIFETIME then
            self.game:destroy_game_object(f.go)
            self.game:release(f.go)
        else
            keep[#keep + 1] = f
        end
    end
    self.flashes = keep
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

function Puppet:status()
    local weapons = {}
    for slot, w in pairs(self.weapons) do
        weapons[#weapons + 1] = ("%d:%s (%s%s)"):format(slot, w.desc.name, w.state, w.mode and (", " .. w.mode) or "")
    end
    table.sort(weapons)
    return {
        state = self.state, mode = self.mode, prefab = self.prefab_path, detail = self.detail,
        char_id = self.avatar and self.avatar.char_id or nil,
        parts = self.avatar and #self.avatar.parts or 0,
        joints_mapped = self.joints_mapped, joints_total = self.joints_total,
        weapons = weapons, visible = self.visible, late_writes = self.late_writes,
        counters = self.counters,
    }
end

return Puppet
