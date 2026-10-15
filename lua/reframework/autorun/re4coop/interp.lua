-- Snapshot interpolation for the remote player. Snapshots arrive ~20 Hz with jitter; the
-- renderer samples a little in the past (delay) so it always has two snapshots to blend.
-- Pure Lua, unit tested offline.

local Interp = {}
Interp.__index = Interp

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerp3(a, b, t)
    return { x = lerp(a.x, b.x, t), y = lerp(a.y, b.y, t), z = lerp(a.z, b.z, t) }
end

-- Normalised lerp along the shortest arc; plenty for 50 ms gaps.
local function nlerp_quat(a, b, t)
    local dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    local s = dot < 0 and -1 or 1
    local x = lerp(a.x, b.x * s, t)
    local y = lerp(a.y, b.y * s, t)
    local z = lerp(a.z, b.z * s, t)
    local w = lerp(a.w, b.w * s, t)
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-6 then
        return { x = 0, y = 0, z = 0, w = 1 }
    end
    return { x = x / len, y = y / len, z = z / len, w = w / len }
end

Interp.nlerp_quat = nlerp_quat

-- opts.blend(state_a, state_b, t) -> state replaces the default blend (position, rotation,
-- joint positions). t runs past 1 while extrapolating.
-- opts.adaptive: the delay grows above opts.delay when packets arrive with more jitter than it
-- covers (one send interval plus twice the measured jitter), up to opts.max_delay.
function Interp.new(opts)
    opts = opts or {}
    return setmetatable({
        delay = opts.delay or 0.1,          -- seconds of buffering
        max_extrapolate = opts.max_extrapolate or 0.25,
        capacity = opts.capacity or 32,
        blend = opts.blend or Interp.blend,
        adaptive = opts.adaptive or false,
        max_delay = opts.max_delay or 0.25,
        snapshots = {},                     -- sorted by remote time
        offset = nil,                       -- estimate of (local clock - remote clock)
        last_push_local = nil,
        gap = nil,                          -- average remote time between snapshots
        jitter = 0,                         -- average deviation of arrivals from the offset
    }, Interp)
end

function Interp:clear()
    self.snapshots = {}
    self.offset = nil
    self.last_push_local = nil
    self.gap = nil
    self.jitter = 0
    self.last_sample = nil
end

-- Seconds in the past that samples are taken from.
function Interp:effective_delay()
    if not self.adaptive then return self.delay end
    local need = (self.gap or 0) + 2 * self.jitter
    return math.min(self.max_delay, math.max(self.delay, need))
end

-- remote_time: sender's clock when the snapshot was taken; local_time: our clock on arrival.
function Interp:push(remote_time, local_time, state)
    local sample = local_time - remote_time
    if self.offset == nil or math.abs(sample - self.offset) > 1.0 then
        self.offset = sample -- first sample, or the partner restarted their clock
        self.snapshots = {}
    elseif sample < self.offset then
        -- A packet that arrived faster than any before: the true offset is at most this.
        self.offset = lerp(self.offset, sample, 0.5)
    else
        self.offset = lerp(self.offset, sample, 0.02)
    end
    self.last_push_local = local_time
    -- Interarrival jitter (RFC 3550): how much the transit time changes from one snapshot
    -- to the next.
    if self.last_sample ~= nil then
        self.jitter = self.jitter + (math.abs(sample - self.last_sample) - self.jitter) / 16
    end
    self.last_sample = sample

    local snaps = self.snapshots
    local n = #snaps
    if n > 0 then
        local gap = remote_time - snaps[n].time
        if gap > 0 and gap < 1.0 then
            self.gap = self.gap and (self.gap + (gap - self.gap) * 0.1) or gap
        end
    end
    if n > 0 and remote_time <= snaps[n].time then
        if remote_time == snaps[n].time then return end
        -- Out of order: insert in place (rare on LAN).
        local i = n
        while i >= 1 and snaps[i].time > remote_time do i = i - 1 end
        if i >= 1 and snaps[i].time == remote_time then return end
        table.insert(snaps, i + 1, { time = remote_time, state = state })
    else
        snaps[n + 1] = { time = remote_time, state = state }
    end
    while #snaps > self.capacity do
        table.remove(snaps, 1)
    end
end

-- Seconds since the last snapshot arrived (nil if none yet).
function Interp:age(local_now)
    if self.last_push_local == nil then return nil end
    return local_now - self.last_push_local
end

function Interp.blend(sa, sb, t)
    local out = {}
    for k, v in pairs(t < 0.5 and sa or sb) do
        out[k] = v -- discrete fields (hp, flags...) come from the nearer snapshot
    end
    out.pos = lerp3(sa.pos, sb.pos, t)
    if sa.rot and sb.rot then
        out.rot = nlerp_quat(sa.rot, sb.rot, t)
    end
    if sa.joints and sb.joints and #sa.joints == #sb.joints then
        local joints = {}
        for i = 1, #sa.joints do
            joints[i] = lerp3(sa.joints[i], sb.joints[i], t)
        end
        out.joints = joints
    end
    return out
end

-- States with animation layers ({bank, id, frame, speed[, blend, mask, mode]} each): position
-- and rotation blend; each layer blends its frame (and blend rate) while both snapshots play the
-- same motion, otherwise it takes the nearer snapshot's.
function Interp.blend_layers(sa, sb, t)
    local out = Interp.blend(sa, sb, t)
    local la, lb = sa.layers or {}, sb.layers or {}
    local layers = {}
    for i = 1, math.max(#la, #lb) do
        local a, b = la[i], lb[i]
        if a ~= nil and b ~= nil and a.bank == b.bank and a.id == b.id and b.frame >= a.frame then
            layers[i] = { bank = a.bank, id = a.id, frame = a.frame + (b.frame - a.frame) * t, speed = b.speed,
                blend = (a.blend ~= nil and b.blend ~= nil) and (a.blend + (b.blend - a.blend) * t) or b.blend,
                mask = b.mask, mode = b.mode }
        else
            layers[i] = (t < 0.5 and a or b) or a or b
        end
    end
    out.layers = layers
    return out
end

-- The remote time that "now" shows (nil before the first snapshot).
function Interp:target(local_now)
    if self.offset == nil then return nil end
    return local_now - self.offset - self:effective_delay()
end

-- Returns the interpolated state for "now", or nil before the first snapshot.
function Interp:sample(local_now)
    if #self.snapshots == 0 then return nil end
    return self:sample_remote(self:target(local_now))
end

-- The state at remote time `target` (several buffers fed by the same sender can be sampled
-- at the same instant this way).
function Interp:sample_remote(target)
    local snaps = self.snapshots
    local n = #snaps
    if n == 0 or target == nil then return nil end
    if n == 1 then return snaps[1].state end

    if target <= snaps[1].time then
        return snaps[1].state
    end

    for i = 1, n - 1 do
        local a, b = snaps[i], snaps[i + 1]
        if target <= b.time then
            local span = b.time - a.time
            local t = span > 0 and (target - a.time) / span or 1
            return self.blend(a.state, b.state, t)
        end
    end

    -- Past the newest snapshot: extrapolate a little along the last velocity, then hold.
    local a, b = snaps[n - 1], snaps[n]
    local span = b.time - a.time
    if span <= 0 then return b.state end
    local over = math.min(target - b.time, self.max_extrapolate)
    return self.blend(a.state, b.state, 1 + over / span)
end

return Interp
