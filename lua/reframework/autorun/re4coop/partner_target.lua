-- The client's player as a second player in the host's game (protocols 13-14).
--
-- The host's game runs every enemy (enemy_net.lua). RE4's AI only fights characters of its own
-- game, so the client's character - the partner's model puppet.lua builds from their real body
-- prefab - becomes one there (game_partner.lua, docs/RESEARCH.md 3.25): the host's enemies see
-- it, hear it, chase it and attack it with their own AI, exactly as they do the host's player,
-- and nothing changes hands.
--
--   Host: while the client's model is up (built from the prefab, drawn, not in a cutscene, in
--   our area), it is attached as a character of our game, and every frame its stand-in context
--   follows the client (position, rotation, HP). The noises the client's player makes
--   (PLAYER_NOISE) are made by the model in our world. Every hit an enemy lands on the model
--   is the client's to take: it travels (PLAYER_DAMAGE) with the hit's values and the attack's
--   identity.
--
--   Client: the noises our player makes are reported to the host. A hit the host's enemies
--   landed on our character there runs on our real character (its damage, reaction, death),
--   one interpolation delay later - when our copy of the enemy shows the blow.
--
--   Parries (protocol 14): the host's enemies' attacks that warn the client's character
--   (ACTION_SIGN, every frame of the warning) reach our player's head one interpolation delay
--   later, so our player gets the parry/dodge prompt with the blow it sees; our player's parry
--   of our copy goes to the host (ENEMY_PARRY), whose enemy staggers - and the host's hit of that
--   attack, still on its way, is not taken.
--
--   Grabs (protocol 14): a host enemy may grab the client's character; it holds it in the host's
--   game until the client breaks free. The grab itself arrives as a hit (PLAYER_DAMAGE, grab
--   flag: our copy of the enemy grabs our character) and the hold as PLAYER_GRAB. Our player
--   breaks free with the presses the game's own escape check counts (mash, or the knife) and
--   tells the host (GRAB_ESCAPE); a hold the host's enemy ends lets our character go.
--
-- Game access goes through the adapter (game.lua / game_partner.lua); pure Lua, tested offline
-- (tests/lua/test_partner_target.lua).
--
-- Adapter contract:
--   host:   game:partner_target_attach(root, {hits, grabs, parry, bosses}) -> bool;
--           game:partner_target_update(pos, rot, hp, max_hp) -> bool; game:partner_target_detach();
--           game:partner_target_attached(); game:partner_noise(noise) -> bool;
--           game:take_partner_damage_events() -> { {id (local enemy), fields, attack_id, key_hash,
--           grab, grab_priority}, ... }; game:take_sign_events() -> { {id, sign_type, button, just,
--           act, angle_check}, ... }; game:enemy_partner_parry(id, kind, sign_type) -> bool;
--           game:partner_grabbers(now) -> { [id] = {action, struggles, knife} };
--           game:enemy_partner_release(id, how) -> bool
--   client: game:take_noise_events() -> { {pos, radius, height, volume, sub}, ... };
--           game:player_take_hit(hit, attacker_local_id|nil) -> "applied"|"blocked"|"failed";
--           game:player_action_sign(id, m) -> bool; game:take_parry_events() -> { {id, kind,
--           sign_type, ok}, ... }; game:player_grab_input(knife) -> "mash"|"knife"|nil;
--           game:player_grab_release(id|nil, action) -> bool
--   enemies (opts.enemies): enemies:net_of_local(id) -> net_id, uid, kind_hash;
--           enemies:local_of_net(net_id, uid, kind_hash) -> id|nil

local PartnerTarget = {}
PartnerTarget.__index = PartnerTarget

local NOISE_INTERVAL = 0.1   -- client: noises are sent at most this often (batched)
local NOISE_MERGE = 0.25     -- client: the same noise again this soon and this close is not news...
local NOISE_MERGE_DIST = 0.5 -- ...(footsteps repeat every step)
local MAX_NOISE_QUEUE = 32
local HIT_DELAY = 0.1        -- client: a host hit lands this much later (default: the enemy interpolation delay)
local MAX_HIT_QUEUE = 32
local ATTACH_RETRY = 2.0     -- host: seconds before trying again after the model could not be attached
local SIGN_STALE = 0.15      -- client: a warning not repeated by the host for this long is over
local PARRY_SHIELD = 1.0     -- client: after a parry of an enemy, its hits still on their way are not taken
local GRAB_STRUGGLES = 8     -- client: presses that break free when the host's enemy did not say
local GRAB_MAX_HOLD = 15.0   -- host: a hold on the client's character never lasts longer than this
local GRAB_RESEND = 1.0      -- host: an ongoing hold is repeated this often (reliable, but cheap)

-- A host enemy's key on the wire: its number, else its level identity.
local function wire_key(net_id, uid)
    if net_id ~= nil and net_id ~= 0 then return net_id end
    return "u" .. tostring(uid)
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts: { role, protocol, send = function(bytes, reliable), settings, log, enemies (enemy_net) }
-- settings: enemy_partner_target (the master switch), enemy_partner_hits, enemy_partner_grabs,
--           enemy_partner_noise, enemy_partner_parry, enemy_partner_bosses, enemy_interp_delay
function PartnerTarget.new(opts)
    local self = setmetatable({}, PartnerTarget)
    self.role = opts.role
    self.P = opts.protocol
    self.send = opts.send
    self.settings = opts.settings or {}
    self.log = opts.log or function() end
    self.enemies = opts.enemies
    self:reset()
    return self
end

function PartnerTarget:reset()
    self.attached = false
    self.attach_failed_at = nil
    self.noise_in = {}      -- host: the client's noises waiting for our game
    self.noise_out = {}     -- client: our noises waiting to be sent
    self.last_noise_send = -math.huge
    self.recent_noise = {}  -- client: { pos, time } of the noises sent lately (merging repeats)
    self.hits_in = {}       -- client: host hits waiting for their moment
    self.signs = {}         -- client: net_id -> { m, at (shown from), last (heard) }: the host's warnings
    self.parried = {}       -- client: host enemy (wire key) -> time until which its hits are not taken
    self.grabs_in = {}      -- client: PLAYER_GRAB messages waiting for their moment
    self.grab = nil         -- client: the hold on our character { net_id, uid, kind_hash, id, action, struggles, knife, presses, since }
    self.grabbed = {}       -- host: local enemy id -> { net_id, uid, kind_hash, action, struggles, knife, since, sent }
    self.seq = 0
    self.last_seq = nil
    self.counters = { attaches = 0, attach_failed = 0, detaches = 0, noises_sent = 0, noises_merged = 0,
        noises_received = 0, noises_applied = 0, hits_sent = 0, hits_unpaired = 0, hits_received = 0,
        hits_applied = 0, hits_blocked = 0, hits_failed = 0, hits_dropped = 0, hits_parried = 0, signs_sent = 0,
        signs_received = 0, signs_shown = 0, parries_sent = 0, parries_received = 0, parries_applied = 0,
        parries_failed = 0, grabs_sent = 0, grabs_received = 0, escapes_sent = 0, escapes_received = 0,
        escapes_applied = 0, holds_ended = 0, holds_timed_out = 0 }
end

function PartnerTarget:enabled()
    return self.settings.sync_enemies ~= false and self.settings.enemy_partner_target ~= false
end

-------------------------------------------------------------------------------
-- Host
-------------------------------------------------------------------------------

-- info = { root (the client's model root GameObject, or nil when it is not up as a prefab),
-- pos, rot (the client's interpolated root), hp, max_hp, busy (in a cutscene), elsewhere (in
-- another area), loading (our area is loading) }
function PartnerTarget:host_tick(now, game, info)
    local want = self:enabled() and info ~= nil and info.root ~= nil and not info.busy and not info.elsewhere
        and not info.loading
    if want and self.attached and not game:partner_target_attached() then
        self.attached = false -- the adapter let go (the model was unloaded)
    end
    if want and not self.attached then
        if self.attach_failed_at == nil or now - self.attach_failed_at >= ATTACH_RETRY then
            local ok = game:partner_target_attach(info.root, { hits = self.settings.enemy_partner_hits ~= false,
                grabs = self.settings.enemy_partner_grabs ~= false, parry = self.settings.enemy_partner_parry ~= false,
                bosses = self.settings.enemy_partner_bosses ~= false })
            if ok then
                self.attached, self.attach_failed_at = true, nil
                self.counters.attaches = self.counters.attaches + 1
                self.log("partner's character is now a target of our enemies")
            else
                self.attach_failed_at = now
                self.counters.attach_failed = self.counters.attach_failed + 1
                if game.partner_target_attached ~= nil and game:partner_target_attached() then game:partner_target_detach() end
            end
        end
    elseif not want and self.attached then
        game:partner_target_detach()
        self.attached = false
        self.counters.detaches = self.counters.detaches + 1
    end
    if self.attached then
        self:apply_noises(game)
    else
        self.noise_in = {}
    end
    self:send_hits(game)
    self:send_signs(game)
    self:update_holds(now, game)
end

-- Every frame (host): the stand-in follows the client's character.
function PartnerTarget:host_frame(game, info)
    if not self.attached or info == nil then return end
    if not game:partner_target_update(info.pos, info.rot, info.hp, info.max_hp) then
        self.attached = false
    end
end

function PartnerTarget:apply_noises(game)
    if self.settings.enemy_partner_noise == false then
        self.noise_in = {}
        return
    end
    local q = self.noise_in
    self.noise_in = {}
    for _, n in ipairs(q) do
        if game:partner_noise(n) then self.counters.noises_applied = self.counters.noises_applied + 1 end
    end
end

-- Enemy hits the client's model took in our game: the client's to take.
function PartnerTarget:send_hits(game)
    local events = game.take_partner_damage_events and game:take_partner_damage_events() or nil
    if events == nil or #events == 0 then return end
    for _, ev in ipairs(events) do
        local net_id, uid, kind_hash = nil, nil, nil
        if self.enemies ~= nil and ev.id ~= nil then net_id, uid, kind_hash = self.enemies:net_of_local(ev.id) end
        if net_id == nil and uid == nil then
            self.counters.hits_unpaired = self.counters.hits_unpaired + 1
        end
        self.seq = self.seq % 65535 + 1
        self.send(self.P.encode_player_damage({ seq = self.seq, net_id = net_id or 0, uid = uid,
            kind_hash = kind_hash or 0, from_enemy = ev.id ~= nil, attack_id = ev.attack_id, key_hash = ev.key_hash,
            grab = ev.grab, grab_priority = ev.grab_priority, fields = ev.fields }), true)
        self.counters.hits_sent = self.counters.hits_sent + 1
    end
end

-- The warnings our enemies' attacks gave the client's model since the last tick (the newest
-- per enemy): the client's player gets the prompt.
function PartnerTarget:send_signs(game)
    local events = game.take_sign_events and game:take_sign_events() or nil
    if events == nil or #events == 0 then return end
    if not self.attached or self.settings.enemy_partner_parry == false then return end
    for _, ev in ipairs(events) do
        local net_id, uid, kind_hash = nil, nil, nil
        if self.enemies ~= nil then net_id, uid, kind_hash = self.enemies:net_of_local(ev.id) end
        if net_id ~= nil or uid ~= nil then
            self.send(self.P.encode_action_sign({ net_id = net_id or 0, uid = uid, kind_hash = kind_hash or 0,
                sign_type = ev.sign_type, button = ev.button, just = ev.just, act = ev.act,
                angle_check = ev.angle_check }), false)
            self.counters.signs_sent = self.counters.signs_sent + 1
        end
    end
end

-- Our enemies holding the client's model: each hold (and its end) goes to the client; a hold
-- that lasts too long is ended (the client may never get its prompt).
function PartnerTarget:update_holds(now, game)
    local holding = (self.attached and game.partner_grabbers) and game:partner_grabbers(now) or {}
    for id, g in pairs(holding) do
        local h = self.grabbed[id]
        if h == nil then
            local net_id, uid, kind_hash = nil, nil, nil
            if self.enemies ~= nil then net_id, uid, kind_hash = self.enemies:net_of_local(id) end
            h = { net_id = net_id or 0, uid = uid, kind_hash = kind_hash or 0, since = now, sent = -math.huge }
            self.grabbed[id] = h
        end
        local changed = h.action ~= g.action or h.struggles ~= g.struggles or h.knife ~= g.knife
        h.action, h.struggles, h.knife = g.action, g.struggles, g.knife
        if now - h.since >= GRAB_MAX_HOLD and not h.timed_out then
            h.timed_out = true
            self.counters.holds_timed_out = self.counters.holds_timed_out + 1
            if game.enemy_partner_release then game:enemy_partner_release(id, 0) end
        end
        if changed or now - h.sent >= GRAB_RESEND then
            h.sent = now
            self.send(self.P.encode_player_grab({ net_id = h.net_id, uid = h.uid, kind_hash = h.kind_hash, held = true,
                struggles = h.struggles or 0, knife = h.knife == true, action = h.action or 0 }), true)
            self.counters.grabs_sent = self.counters.grabs_sent + 1
        end
    end
    for id, h in pairs(self.grabbed) do
        if holding[id] == nil then
            self.grabbed[id] = nil
            self.counters.holds_ended = self.counters.holds_ended + 1
            self.send(self.P.encode_player_grab({ net_id = h.net_id, uid = h.uid, kind_hash = h.kind_hash, held = false,
                action = h.action or 0 }), true)
        end
    end
end

-- The client's player parried (or pressed parry at) one of our enemies' attacks.
function PartnerTarget:host_on_parry(m, game)
    self.counters.parries_received = self.counters.parries_received + 1
    local id = self:local_enemy(m)
    if id == nil or not self.attached or game.enemy_partner_parry == nil then
        self.counters.parries_failed = self.counters.parries_failed + 1
        return
    end
    if game:enemy_partner_parry(id, m.kind, m.sign_type) then
        self.counters.parries_applied = self.counters.parries_applied + 1
    else
        self.counters.parries_failed = self.counters.parries_failed + 1
    end
end

-- The client's player broke free of one of our enemies.
function PartnerTarget:host_on_escape(m, game)
    self.counters.escapes_received = self.counters.escapes_received + 1
    local id = self:local_enemy(m)
    if id ~= nil and game.enemy_partner_release ~= nil and game:enemy_partner_release(id, m.how) then
        self.counters.escapes_applied = self.counters.escapes_applied + 1
    end
end

-- Our local enemy for a message naming the host's enemy (net_id, uid).
function PartnerTarget:local_enemy(m)
    if self.enemies == nil or (m.net_id == 0 and m.uid == nil) then return nil end
    return self.enemies:local_of_net(m.net_id, m.uid, m.kind_hash)
end

function PartnerTarget:host_on_noise(m)
    if not self.attached then return end
    for _, n in ipairs(m.noises or {}) do
        if #self.noise_in >= MAX_NOISE_QUEUE then table.remove(self.noise_in, 1) end
        self.noise_in[#self.noise_in + 1] = n
        self.counters.noises_received = self.counters.noises_received + 1
    end
end

-------------------------------------------------------------------------------
-- Client
-------------------------------------------------------------------------------

-- info = { playable (in game, not in a cutscene nor loading), dead }
function PartnerTarget:client_tick(now, game, info)
    local noises = game.take_noise_events and game:take_noise_events() or nil
    if self:enabled() and self.settings.enemy_partner_noise ~= false then
        for _, n in ipairs(noises or {}) do self:queue_noise(now, n) end
        if #self.noise_out > 0 and now - self.last_noise_send >= NOISE_INTERVAL then
            self.last_noise_send = now
            local batch = {}
            for i = 1, math.min(#self.noise_out, self.P.MAX_NOISES) do batch[i] = self.noise_out[i] end
            for _ = 1, #batch do table.remove(self.noise_out, 1) end
            self.send(self.P.encode_player_noise(batch), false)
            self.counters.noises_sent = self.counters.noises_sent + #batch
        end
    else
        self.noise_out = {}
    end
    self:send_parries(now, game)
    self:land_grabs(now, game, info)
    self:land_hits(now, game, info)
end

-- Every frame (client): the host's warnings stay on our player's head while the host repeats
-- them, and the escape presses of a hold are counted.
function PartnerTarget:client_frame(now, game, info)
    local playable = info ~= nil and info.playable and not info.dead
    for net_id, sg in pairs(self.signs) do
        if now - sg.last > SIGN_STALE then
            self.signs[net_id] = nil
        elseif playable and now >= sg.at and self:enabled() and self.settings.enemy_partner_parry ~= false then
            local id = self:local_enemy(sg.m)
            if id ~= nil and game.player_action_sign ~= nil and game:player_action_sign(id, sg.m) then
                self.counters.signs_shown = self.counters.signs_shown + 1
            end
        end
    end
    local g = self.grab
    if g ~= nil and playable and game.player_grab_input ~= nil then
        local input = game:player_grab_input(g.knife)
        if input == "knife" then
            self:escape(game, self.P.ESCAPE_KIND.KNIFE)
        elseif input == "mash" then
            g.presses = g.presses + 1
            if g.presses >= g.struggles then self:escape(game, self.P.ESCAPE_KIND.MASH) end
        end
    elseif g ~= nil and info ~= nil and info.dead then
        self.grab = nil
    end
end

-- Our player broke free: our character is let go here at once, the host's enemy lets go there.
function PartnerTarget:escape(game, how)
    local g = self.grab
    if g == nil then return end
    self.grab = nil
    self.send(self.P.encode_grab_escape({ net_id = g.net_id, uid = g.uid, kind_hash = g.kind_hash, how = how }), true)
    self.counters.escapes_sent = self.counters.escapes_sent + 1
    if game.player_grab_release ~= nil then game:player_grab_release(g.id, g.action) end
    self.log("broke free of the host's enemy %s", tostring(g.net_id))
end

-- Our player's parries of our copies: to the host. A landed parry also shields our character
-- from that enemy's hits still on their way (the host's enemy struck the model before it heard).
function PartnerTarget:send_parries(now, game)
    local events = game.take_parry_events and game:take_parry_events() or nil
    if events == nil or #events == 0 then return end
    for _, ev in ipairs(events) do
        local net_id, uid, kind_hash = nil, nil, nil
        if self.enemies ~= nil then net_id, uid, kind_hash = self.enemies:net_of_local(ev.id) end
        if (net_id ~= nil or uid ~= nil) and self:enabled() and self.settings.enemy_partner_parry ~= false then
            self.send(self.P.encode_enemy_parry({ net_id = net_id or 0, uid = uid, kind_hash = kind_hash or 0,
                kind = ev.kind, sign_type = ev.sign_type }), true)
            self.counters.parries_sent = self.counters.parries_sent + 1
            if ev.kind == self.P.PARRY_KIND.PARRY and ev.ok then
                self.parried[wire_key(net_id or 0, uid)] = now + PARRY_SHIELD
            end
        end
    end
end

function PartnerTarget:client_on_sign(m, now)
    self.counters.signs_received = self.counters.signs_received + 1
    if not self:enabled() or self.settings.enemy_partner_parry == false then return end
    local key = wire_key(m.net_id, m.uid)
    local sg = self.signs[key]
    local delay = math.max(0, math.min(tonumber(self.settings.enemy_interp_delay) or HIT_DELAY, 0.5))
    if sg == nil then
        self.signs[key] = { m = m, at = now + delay, last = now }
    else
        sg.m, sg.last = m, now
    end
end

function PartnerTarget:client_on_grab(m, now)
    self.counters.grabs_received = self.counters.grabs_received + 1
    if #self.grabs_in >= MAX_HIT_QUEUE then table.remove(self.grabs_in, 1) end
    local delay = math.max(0, math.min(tonumber(self.settings.enemy_interp_delay) or HIT_DELAY, 0.5))
    self.grabs_in[#self.grabs_in + 1] = { m = m, at = now + delay }
end

-- Holds whose moment came (with the grab's hit, one interpolation delay late).
function PartnerTarget:land_grabs(now, game, info)
    if #self.grabs_in == 0 then return end
    local keep = {}
    for _, h in ipairs(self.grabs_in) do
        if h.at > now then
            keep[#keep + 1] = h
        else
            self:apply_grab(h.m, now, game, info)
        end
    end
    self.grabs_in = keep
end

function PartnerTarget:apply_grab(m, now, game, info)
    local g = self.grab
    local same = g ~= nil and g.net_id == m.net_id and g.uid == m.uid
    if m.held then
        if not self:enabled() or self.settings.enemy_partner_grabs == false then return end
        if info ~= nil and info.dead then return end
        if same then
            -- The host repeats an ongoing hold: what it learnt since (presses, knife).
            if (m.struggles or 0) > 0 then g.struggles = m.struggles end
            g.knife = m.knife
            return
        end
        if g ~= nil then
            -- Another enemy holds us now: the first one let go.
            if game.player_grab_release then game:player_grab_release(g.id, g.action) end
        end
        self.grab = { net_id = m.net_id, uid = m.uid, kind_hash = m.kind_hash, id = self:local_enemy(m),
            action = m.action or 0, struggles = (m.struggles or 0) > 0 and m.struggles or GRAB_STRUGGLES,
            knife = m.knife == true, presses = 0, since = now }
    elseif same then
        -- The host's enemy let go (it was hurt, killed, or its hold ended).
        self.grab = nil
        if game.player_grab_release then game:player_grab_release(g.id, g.action) end
    end
end

-- What the HUD shows while our character is held: { presses, struggles, knife } or nil.
function PartnerTarget:grab_status()
    local g = self.grab
    if g == nil then return nil end
    return { presses = g.presses, struggles = g.struggles, knife = g.knife }
end

function PartnerTarget:queue_noise(now, n)
    for i = #self.recent_noise, 1, -1 do
        if now - self.recent_noise[i].time > NOISE_MERGE then table.remove(self.recent_noise, i) end
    end
    for _, r in ipairs(self.recent_noise) do
        if dist(r.pos, n.pos) <= NOISE_MERGE_DIST and math.abs((r.volume or 0) - (n.volume or 0)) < 1e-3 then
            self.counters.noises_merged = self.counters.noises_merged + 1
            return
        end
    end
    self.recent_noise[#self.recent_noise + 1] = { pos = n.pos, volume = n.volume, time = now }
    if #self.noise_out >= MAX_NOISE_QUEUE then table.remove(self.noise_out, 1) end
    self.noise_out[#self.noise_out + 1] = n
end

function PartnerTarget:client_on_damage(m, now)
    self.counters.hits_received = self.counters.hits_received + 1
    if not self:enabled() or self.settings.enemy_partner_hits == false then
        self.counters.hits_dropped = self.counters.hits_dropped + 1
        return
    end
    if #self.hits_in >= MAX_HIT_QUEUE then
        table.remove(self.hits_in, 1)
        self.counters.hits_dropped = self.counters.hits_dropped + 1
    end
    local delay = tonumber(self.settings.enemy_interp_delay) or HIT_DELAY
    self.hits_in[#self.hits_in + 1] = { m = m, at = now + math.max(0, math.min(delay, 0.5)) }
end

-- Host hits whose moment came: on our real character (not while it cannot be hit: loading,
-- a cutscene, already dead).
function PartnerTarget:land_hits(now, game, info)
    if #self.hits_in == 0 then return end
    local playable = info ~= nil and info.playable and not info.dead
    local keep = {}
    for _, h in ipairs(self.hits_in) do
        if h.at > now then
            keep[#keep + 1] = h
        elseif not playable then
            self.counters.hits_dropped = self.counters.hits_dropped + 1
        else
            local m = h.m
            local attacker = nil
            if self.enemies ~= nil and (m.net_id ~= 0 or m.uid ~= nil) then
                attacker = self.enemies:local_of_net(m.net_id, m.uid, m.kind_hash)
            end
            local shield = self.parried[wire_key(m.net_id, m.uid)]
            local r
            if shield ~= nil and now <= shield and not m.grab then
                r = "parried"
            else
                r = game.player_take_hit and game:player_take_hit(m, attacker) or "failed"
            end
            if r == "applied" then
                self.counters.hits_applied = self.counters.hits_applied + 1
            elseif r == "parried" then
                self.counters.hits_parried = self.counters.hits_parried + 1
            elseif r == "blocked" then
                self.counters.hits_blocked = self.counters.hits_blocked + 1
            else
                self.counters.hits_failed = self.counters.hits_failed + 1
            end
        end
    end
    self.hits_in = keep
end

-------------------------------------------------------------------------------

-- Returns true if the message was ours (consumed). game: for the host's parries and escapes.
function PartnerTarget:on_message(m, now, game)
    local T = self.P.T
    if m.type == T.PLAYER_NOISE then
        if self.role == "host" then self:host_on_noise(m) end
    elseif m.type == T.PLAYER_DAMAGE then
        if self.role == "client" then self:client_on_damage(m, now) end
    elseif m.type == T.ACTION_SIGN then
        if self.role == "client" then self:client_on_sign(m, now) end
    elseif m.type == T.PLAYER_GRAB then
        if self.role == "client" then self:client_on_grab(m, now) end
    elseif m.type == T.ENEMY_PARRY then
        if self.role == "host" and game ~= nil then self:host_on_parry(m, game) end
    elseif m.type == T.GRAB_ESCAPE then
        if self.role == "host" and game ~= nil then self:host_on_escape(m, game) end
    else
        return false
    end
    return true
end

-- The session ended or switched off: our game lets go of the client's model (host), our
-- character is let go (client).
function PartnerTarget:shutdown(game)
    if self.attached and game ~= nil and game.partner_target_detach ~= nil then game:partner_target_detach() end
    if self.grab ~= nil and game ~= nil and game.player_grab_release ~= nil then
        game:player_grab_release(self.grab.id, self.grab.action)
    end
    self:reset()
end

function PartnerTarget:summary()
    return { role = self.role, attached = self.attached, counters = self.counters, grab = self:grab_status() }
end

return PartnerTarget
