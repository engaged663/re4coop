-- Ashley for both players: one Ashley in the shared world.
--
-- Each player's game has its own Ashley (the partner character ch2_a1z0), whose AI follows
-- that game's player. In co-op exactly one of the two games runs her, her owner: the host's
-- when the session starts. There she is the game's own Ashley, following the owner's player.
-- In the other game she is a puppet (docs/RESEARCH.md 3.23): her AI head is switched off,
-- enemies there may neither grab nor attack her and our game takes no HP from her; she stands,
-- moves and animates where the owner's Ashley is (ASHLEY, ~20 Hz, interpolated like the
-- enemies the partner's game runs).
--
-- The switch key (Alt by default) sends her to the other player: from then on the other game
-- runs her and its AI makes her follow its player, while ours becomes the puppet. Either
-- player can press it; the host decides (ASHLEY_SWITCH -> ASHLEY_OWNER), so two presses at
-- once switch once. A switch waits the cooldown (5 s) after the last one, and is refused while
-- she is kidnapped, down or busy (hiding, on a gimmick) or the other game has no Ashley. A
-- game that takes her over far from its player (another area) brings her next to the player.
-- If the game running her has no Ashley for a while (a part of the story without her there)
-- while the other game has her, she goes over by herself.
--
-- Adapter contract (game):
--   game:ashley_read(full) -> { pos, rot, hp, max_hp, alive, kidnapped, busy, hidden, layers } | nil
--                             (nil: no Ashley in our game now; layers only when `full`)
--   game:ashley_set_puppet(on) -> bool   (on: also asked again every tick; re-asserts the locks)
--   game:ashley_set_transform(pos, rot) -> bool
--   game:ashley_set_anim(layers) -> bool
--   game:ashley_set_hp(hp) -> bool        (never kills)
--   game:ashley_warp(pos, rot) -> bool    (the game's own character teleport)

local Interp = require("re4coop.interp")

local AshleySync = {}
AshleySync.__index = AshleySync

local STATE_HZ = 20
local PRESENCE_INTERVAL = 0.5 -- seconds between the non-owner's reports (does it have an Ashley, is she busy)
local STALE = 2.0             -- the owner's state older than this is not mirrored
local PARTNER_FRESH = 2.0     -- the partner's report older than this counts as unknown
local ABSENT_AUTO = 5.0       -- the owner without an Ashley this long while the other game has her: she goes over
local WARP_DISTANCE = 20.0    -- metres: taken over farther than this from our player, she is brought to us
local WARP_BEHIND = 1.5       -- metres behind our player she lands
local MIN_MOVE = 0.01
local MIN_TURN = 1e-5
local DEFAULT_COOLDOWN = 5.0

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function rot_delta(a, b)
    if a == nil or b == nil then return 1 end
    local d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    return 1 - math.abs(d)
end

-- opts: { role, protocol, settings, send(bytes, reliable), log(fmt, ...), notify(text, kind),
--         partner_name() }
function AshleySync.new(opts)
    local self = setmetatable({}, AshleySync)
    self.role = opts.role
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send
    self.log = opts.log or function() end
    self.notify = opts.notify or function() end
    self.partner_name = opts.partner_name or function() return "your partner" end
    self:reset()
    return self
end

-- A new partner (or none): she starts with the host again. What our game changed on her is
-- put back by the session (game:ashley_restore).
function AshleySync:reset()
    local O = self.P.OWNER
    self.owner = O.HOST
    self.epoch = 0
    self.cooldown_until = -math.huge
    self.interp = Interp.new({ delay = tonumber(self.settings.enemy_interp_delay) or 0.1, max_delay = 0.25,
        adaptive = true, max_extrapolate = 0.2, capacity = 16, blend = Interp.blend_layers })
    self.newest = nil        -- the owner's latest state (when the partner runs her)
    self.partner = nil       -- the partner's latest report: { present, busy, owner, time }
    self.local_state = nil   -- our Ashley at the last tick (nil: none)
    self.puppet = false      -- ours is a puppet of the partner's
    self.took_over = false   -- she just became ours: bring her to our player if she is far away
    self.announced = false
    self.last_state = -math.huge
    self.last_presence = -math.huge
    self.owner_absent_since = nil
    self.mirror_pos, self.mirror_rot = nil, nil
    self.counters = { sent = 0, received = 0, switches = 0, refused = 0, requests = 0, stale = 0, puppets = 0,
        warps = 0, moves = 0, anims = 0, auto = 0 }
end

function AshleySync:enabled()
    return self.settings.ashley_coop ~= false
end

function AshleySync:me()
    return self.role == "host" and self.P.OWNER.HOST or self.P.OWNER.CLIENT
end

function AshleySync:other(owner)
    local O = self.P.OWNER
    return owner == O.HOST and O.CLIENT or O.HOST
end

-- Whether our game runs her.
function AshleySync:runs_here()
    return self.owner == self:me()
end

function AshleySync:cooldown()
    return tonumber(self.settings.ashley_cooldown) or DEFAULT_COOLDOWN
end

function AshleySync:cooldown_left(now)
    return math.max(0, self.cooldown_until - now)
end

-- The partner's report, if it is recent.
function AshleySync:partner_report(now)
    local p = self.partner
    if p == nil or now - p.time > PARTNER_FRESH then return nil end
    return p
end

function AshleySync:owner_text(owner)
    return owner == self:me() and "you" or self.partner_name()
end

-- She now runs in `owner`'s game since `epoch`.
function AshleySync:set_owner(owner, epoch, now)
    local changed = owner ~= self.owner
    self.owner, self.epoch = owner, epoch
    if not changed then return false end
    self.counters.switches = self.counters.switches + 1
    self.owner_absent_since = nil
    if self:runs_here() then
        self.took_over = true
    else
        self.took_over = false
        self.interp:clear()
        self.newest = nil
        self.mirror_pos, self.mirror_rot = nil, nil
    end
    return true
end

-------------------------------------------------------------------------------
-- Switching
-------------------------------------------------------------------------------

local function refusal_text(self, reason, now)
    local R = self.P.ASHLEY_REASON
    if reason == R.COOLDOWN then
        return ("Ashley can switch again in %d s"):format(math.max(1, math.ceil(self:cooldown_left(now))))
    elseif reason == R.BUSY then
        return "Ashley cannot switch now (kidnapped, down or busy)"
    elseif reason == R.ABSENT then
        local to = self:other(self.owner)
        return ("Ashley cannot go to %s now (no Ashley there, or in a cutscene)"):format(
            to == self:me() and "you" or self.partner_name())
    end
    return "Ashley cannot switch now"
end

-- Our player pressed the switch key.
function AshleySync:request(now)
    if not self:enabled() then return false end
    if self:cooldown_left(now) > 0 then
        self.notify(refusal_text(self, self.P.ASHLEY_REASON.COOLDOWN, now), "warn")
        return false
    end
    if self.role == "host" then
        return self:switch(now, self.P.OWNER.HOST)
    end
    self.counters.requests = self.counters.requests + 1
    self.send(self.P.encode_ashley_switch({ epoch = self.epoch }), true)
    return true
end

-- Host: why she cannot go over to the other game now, or nil.
function AshleySync:blocked(now)
    local O, R = self.P.OWNER, self.P.ASHLEY_REASON
    local mine = self.local_state
    local theirs = self:partner_report(now)
    local owner_busy, new_has
    if self.owner == O.HOST then
        owner_busy = mine ~= nil and mine.busy
        -- (a non-owner reports BUSY when its player cannot take her: cutscene, down, loading)
        new_has = theirs ~= nil and theirs.present and not theirs.busy
    else
        owner_busy = theirs ~= nil and theirs.busy
        new_has = mine ~= nil and not self.local_unable
    end
    if owner_busy then return R.BUSY end
    if not new_has then return R.ABSENT end
    return nil
end

-- Host: a switch asked by `by` (P.OWNER: whose player pressed the key).
function AshleySync:switch(now, by)
    local R = self.P.ASHLEY_REASON
    local why = nil
    if self:cooldown_left(now) > 0 then
        why = R.COOLDOWN
    else
        why = self:blocked(now)
    end
    if why ~= nil then
        self.counters.refused = self.counters.refused + 1
        if by == self.P.OWNER.HOST then
            self.notify(refusal_text(self, why, now), "warn")
        else
            self:send_owner(now, why, by)
        end
        return false
    end
    self:give(now, self:other(self.owner), R.CHANGED, by)
    return true
end

-- Host: she goes over to `owner`.
function AshleySync:give(now, owner, reason, by)
    local epoch = (self.epoch + 1) & 0xFF
    self:set_owner(owner, epoch, now)
    if reason == self.P.ASHLEY_REASON.CHANGED then self.cooldown_until = now + self:cooldown() end
    self:send_owner(now, reason, by)
    self.notify(("Ashley now follows %s"):format(self:owner_text(owner)), "good")
end

function AshleySync:send_owner(now, reason, by)
    self.send(self.P.encode_ashley_owner({ owner = self.owner, epoch = self.epoch, cooldown = self:cooldown_left(now),
        reason = reason, by = by or self.P.OWNER.HOST }), true)
end

-------------------------------------------------------------------------------
-- Messages
-------------------------------------------------------------------------------

function AshleySync:on_message(m, now)
    local T = self.P.T
    if m.type == T.ASHLEY then
        self.counters.received = self.counters.received + 1
        self.partner = { present = m.present, busy = m.busy, owner = m.owner, time = now }
        if m.owner and not self:runs_here() and m.epoch == self.epoch and m.present then
            self.interp:push(m.time, now, { pos = m.pos, rot = m.rot, layers = m.layers, hp = m.hp, hidden = m.hidden })
            self.newest = m
            self.newest_at = now
        elseif m.owner and m.epoch ~= self.epoch then
            self.counters.stale = self.counters.stale + 1
        end
        return true
    elseif m.type == T.ASHLEY_OWNER then
        if self.role ~= "client" then return true end
        local R = self.P.ASHLEY_REASON
        self.cooldown_until = now + (m.cooldown or 0)
        local changed = self:set_owner(m.owner, m.epoch, now)
        if m.reason == R.COOLDOWN or m.reason == R.BUSY or m.reason == R.ABSENT then
            self.counters.refused = self.counters.refused + 1
            self.notify(refusal_text(self, m.reason, now), "warn") -- (only our own requests are refused to us)
        elseif changed and m.reason ~= R.ANNOUNCE then
            self.notify(("Ashley now follows %s"):format(self:owner_text(m.owner)), "good")
        end
        return true
    elseif m.type == T.ASHLEY_SWITCH then
        if self.role ~= "host" or not self:enabled() then return true end
        if m.epoch ~= self.epoch then
            self.counters.stale = self.counters.stale + 1 -- asked about a switch that already happened
            self:send_owner(now, self.P.ASHLEY_REASON.ANNOUNCE, self.P.OWNER.CLIENT)
            return true
        end
        self:switch(now, self.P.OWNER.CLIENT)
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Every tick
-------------------------------------------------------------------------------

-- Where she lands next to our player: WARP_BEHIND metres behind them.
local function behind(pos, rot)
    local fx, fz = 0, 1
    if rot ~= nil then
        fx = 2 * (rot.x * rot.z + rot.w * rot.y)
        fz = 1 - 2 * (rot.x * rot.x + rot.y * rot.y)
    end
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 1e-6 then fx, fz, len = 0, 1, 1 end
    return { x = pos.x - fx / len * WARP_BEHIND, y = pos.y, z = pos.z - fz / len * WARP_BEHIND }
end

-- ctx: { in_game, local_pos, local_rot, unable (cutscene, dead, loading: our player cannot take
-- her) }
function AshleySync:tick(now, game, ctx)
    ctx = ctx or {}
    if not self:enabled() or game == nil or game.ashley_read == nil then
        self:release(game)
        return
    end
    local here = self:runs_here()
    local st = ctx.in_game and game:ashley_read(here) or nil
    self.local_state = st
    self.local_unable = ctx.unable and true or false
    local F, R = self.P.ASHLEY_FLAGS, self.P.ASHLEY_REASON

    if self.role == "host" then
        if not self.announced then
            self.announced = true
            self:send_owner(now, R.ANNOUNCE, self.P.OWNER.HOST)
        end
        self:check_absent_owner(now, ctx)
    end
    -- Loading, a menu: we say nothing (a game that is only loading has not lost her).
    if not ctx.in_game then return end

    if here then
        if self.puppet then
            game:ashley_set_puppet(false)
            self.puppet = false
        end
        if self.took_over and st ~= nil then
            self.took_over = false
            if ctx.local_pos ~= nil and dist(st.pos, ctx.local_pos) > WARP_DISTANCE and game.ashley_warp ~= nil
                and game:ashley_warp(behind(ctx.local_pos, ctx.local_rot), ctx.local_rot) then
                self.counters.warps = self.counters.warps + 1
            end
        end
        if st ~= nil and now - self.last_state >= 1.0 / STATE_HZ then
            self.last_state = now
            self:send_state(now, st, F.OWNER)
        elseif st == nil and now - self.last_presence >= PRESENCE_INTERVAL then
            self.last_presence = now
            self:send_state(now, nil, F.OWNER)
        end
        return
    end

    -- The partner's game runs her: ours follows theirs.
    local fresh = self.newest_at ~= nil and now - self.newest_at < STALE
    if st ~= nil and (self.puppet or fresh) then
        if game:ashley_set_puppet(true) then
            if not self.puppet then self.counters.puppets = self.counters.puppets + 1 end
            self.puppet = true
        end
    end
    if self.puppet and st ~= nil and fresh then
        local s = self.interp:sample(now)
        if s ~= nil then
            if s.layers ~= nil and #s.layers > 0 and self.settings.enemy_motion_sync ~= false
                and game:ashley_set_anim(s.layers) then
                self.counters.anims = self.counters.anims + 1
            end
            if s.hp ~= nil and s.hp > 0 and st.hp ~= s.hp then game:ashley_set_hp(s.hp) end
        end
    end
    if now - self.last_presence >= PRESENCE_INTERVAL then
        self.last_presence = now
        self:send_state(now, st, 0)
    end
end

-- Host: the game running her has had no Ashley for a while, ours / the partner's has her.
function AshleySync:check_absent_owner(now, ctx)
    local O = self.P.OWNER
    local theirs = self:partner_report(now)
    local owner_absent, other_has
    if self.owner == O.HOST then
        owner_absent = ctx.in_game and self.local_state == nil
        other_has = theirs ~= nil and theirs.present
    else
        owner_absent = theirs ~= nil and not theirs.present
        other_has = self.local_state ~= nil
    end
    if not (owner_absent and other_has) then
        self.owner_absent_since = nil
        return
    end
    self.owner_absent_since = self.owner_absent_since or now
    if now - self.owner_absent_since >= ABSENT_AUTO then
        self.counters.auto = self.counters.auto + 1
        self:give(now, self:other(self.owner), self.P.ASHLEY_REASON.AUTO, O.HOST)
    end
end

function AshleySync:send_state(now, st, flags)
    local F = self.P.ASHLEY_FLAGS
    if st ~= nil then
        flags = flags | F.PRESENT
        if st.alive ~= false then flags = flags | F.ALIVE end
        if st.kidnapped then flags = flags | F.KIDNAPPED end
        if st.busy or self.local_unable then flags = flags | F.BUSY end
        if st.hidden then flags = flags | F.HIDDEN end
    end
    local full = st ~= nil and (flags & F.OWNER) ~= 0
    self.send(self.P.encode_ashley({ time = now, epoch = self.epoch, flags = flags,
        pos = st and st.pos, rot = st and st.rot, hp = st and st.hp or 0, max_hp = st and st.max_hp or 0,
        layers = full and st.layers or nil }), false)
    self.counters.sent = self.counters.sent + 1
end

-- Every frame: our puppet stands where the owner's Ashley is.
function AshleySync:frame(now, game)
    if not self.puppet or self:runs_here() or game == nil or game.ashley_set_transform == nil then return end
    if self.newest_at == nil or now - self.newest_at >= STALE then return end
    local s = self.interp:sample(now)
    if s == nil then return end
    if self.mirror_pos ~= nil and dist(self.mirror_pos, s.pos) <= MIN_MOVE and rot_delta(self.mirror_rot, s.rot) <= MIN_TURN then
        return
    end
    if game:ashley_set_transform(s.pos, s.rot) then
        self.mirror_pos, self.mirror_rot = s.pos, s.rot
        self.counters.moves = self.counters.moves + 1
    end
end

-- Our Ashley runs on her own again (switched off, partner gone).
function AshleySync:release(game)
    if self.puppet and game ~= nil and game.ashley_set_puppet ~= nil then game:ashley_set_puppet(false) end
    self.puppet = false
end

function AshleySync:summary(now)
    local theirs = self:partner_report(now)
    return {
        enabled = self:enabled(),
        mine = self:runs_here(),
        owner_name = self:owner_text(self.owner),
        epoch = self.epoch,
        cooldown = self:cooldown_left(now),
        puppet = self.puppet,
        here = self.local_state ~= nil,
        partner_has = theirs ~= nil and theirs.present or false,
        counters = self.counters,
    }
end

return AshleySync
