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
function Interp.new(opts)
    opts = opts or {}
    return setmetatable({
        delay = opts.delay or 0.1,          -- seconds of buffering
        max_extrapolate = opts.max_extrapolate or 0.25,
        capacity = opts.capacity or 32,
        blend = opts.blend or Interp.blend,
        snapshots = {},                     -- sorted by remote time
        offset = nil,                       -- estimate of (local clock - remote clock)
        last_push_local = nil,
    }, Interp)
end

function Interp:clear()
    self.snapshots = {}
    self.offset = nil
    self.last_push_local = nil
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

    local snaps = self.snapshots
    local n = #snaps
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

-- Returns the interpolated state for "now", or nil before the first snapshot.
function Interp:sample(local_now)
    local snaps = self.snapshots
    local n = #snaps
    if n == 0 then return nil end
    if n == 1 then return snaps[1].state end

    local target = local_now - self.offset - self.delay
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
