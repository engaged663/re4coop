-- Avatar sync: everything the partner needs to show our character as a fully animated 3D
-- model, and the receiving side that turns their messages into a render state.
--
--   AVATAR  (reliable)   what the character is built from: character id (picks the body
--                        prefab), costume/body parts (mesh + material), and the ordered
--                        list of skeleton joints the pose stream animates
--   GEAR    (reliable)   the weapons the character carries
--   POSE    (unreliable) root placement + every joint's local rotation + weapon placement,
--                        ~30 Hz. Copying the final pose (after animation, IK and physics)
--                        reproduces every state - walking, aiming, shooting, reloading,
--                        melee, ladders, grabs, deaths - without knowing any animation ids
--   ACTIONS (reliable)   sound/effect calls and shots, replayed on the partner's model in
--                        sync with the (delayed) animation
--
-- Pure Lua: game access goes through the adapter (game.lua), so it is tested offline.
--
-- Sender adapter contract:
--   game:avatar_descriptor(now) -> nil | { sig, char_id, body_name, parts, joints }
--   game:gear_descriptor(now)   -> nil | { sig, weapons }
--   game:request_pose()            ask for a capture at the end of the frame
--   game:take_pose(now)         -> nil | { time, sig, gear_sig, root_pos, root_rot, flags, q, tpos, weapons }
--   game:drain_events()         -> { {kind, time, ...}, ... }

local Interp = require("re4coop.interp")

local Avatar = {}

local EMPTY = {}
local STALE_EVENT = 1.0   -- seconds behind the animation after which an event is dropped
local MAX_QUEUED_EVENTS = 256
local TELEPORT = 2.5      -- metres between two poses that mean a jump, not movement
local MAX_EXTRAPOLATE = 0.1
-- When a pose is late, joints keep moving for up to one more pose interval (blend t up to 2)
-- instead of freezing; the root keeps moving for up to MAX_EXTRAPOLATE seconds.
local JOINT_MAX_T = 2.0

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerp3(a, b, t)
    return { x = lerp(a.x, b.x, t), y = lerp(a.y, b.y, t), z = lerp(a.z, b.z, t) }
end

-------------------------------------------------------------------------------
-- Sender
-------------------------------------------------------------------------------

local Sender = {}
Sender.__index = Sender

-- opts: { protocol, send = function(bytes, reliable), send_large = function(bytes) -> ok,
--         settings = { pose_hz } }
function Avatar.new_sender(opts)
    local self = setmetatable({}, Sender)
    self.P = opts.protocol
    self.send = opts.send
    self.send_large = opts.send_large
    self.settings = opts.settings or {}
    self.avatar_rev = 0
    self.gear_rev = 0
    self.counters = { avatars = 0, gears = 0, poses = 0, pose_bytes = 0, events = 0 }
    self:reset()
    return self
end

-- The partner (re)started its session state: describe ourselves again.
function Sender:reset()
    self.sent_avatar_sig = nil
    self.sent_gear_sig = nil
    self.last_request = -math.huge
end

function Sender:tick(now, game)
    local P = self.P
    local desc = game:avatar_descriptor(now)
    if desc == nil then
        game:drain_events() -- nothing to attach them to (menus, loading)
        return
    end
    if desc.sig ~= self.sent_avatar_sig then
        self.avatar_rev = self.avatar_rev % 65535 + 1
        local ok = self.send_large(P.encode_avatar({
            rev = self.avatar_rev, char_id = desc.char_id, body_name = desc.body_name,
            parts = desc.parts, joints = desc.joints,
        }))
        if ok then
            self.sent_avatar_sig = desc.sig
            self.counters.avatars = self.counters.avatars + 1
        end
    end

    local gear = game:gear_descriptor(now)
    local gear_sig = gear and gear.sig or ""
    if gear_sig ~= self.sent_gear_sig then
        self.gear_rev = self.gear_rev % 65535 + 1
        if self.send_large(P.encode_gear({ rev = self.gear_rev, weapons = gear and gear.weapons or EMPTY })) then
            self.sent_gear_sig = gear_sig
            self.counters.gears = self.counters.gears + 1
        end
    end

    local events = game:drain_events()
    if #events > 0 then
        local m = { time = now, events = {} }
        for i, ev in ipairs(events) do
            ev.dt = (ev.time or now) - now
            m.events[i] = ev
        end
        -- Sounds and effects carry their own timestamps: the unordered reliable lane delivers
        -- them as soon as they arrive, and a lost one never holds back the world messages.
        for _, bytes in ipairs(P.encode_actions(m)) do
            self.send(bytes, true, true)
        end
        self.counters.events = self.counters.events + #events
    end

    -- Poses: a capture is requested at pose_hz; the game adapter reads it at the end of the
    -- frame (after animation) and flush_pose sends it right away. send_pose here covers a
    -- pose that is still waiting, or an in-place read when the end-of-frame callback is not
    -- running.
    local interval = 1.0 / (self.rate or self.settings.pose_hz or 30)
    if now - self.last_request >= interval then
        self.last_request = (now - self.last_request >= 2 * interval) and now or (self.last_request + interval)
        self:send_pose(now, game)
        game:request_pose()
    end
end

-- End of frame, right after the capture (see game:capture_pose_late).
function Sender:flush_pose(now, game)
    if self.sent_avatar_sig == nil then return end
    self:send_pose(now, game)
end

function Sender:send_pose(now, game)
    local pose = game:take_pose(now)
    -- Only a pose captured with the descriptors the partner has can be decoded by them.
    if pose == nil or pose.sig ~= self.sent_avatar_sig or (pose.gear_sig or "") ~= self.sent_gear_sig then return end
    local P = self.P
    for _, bytes in ipairs(P.encode_pose({
        time = pose.time or now, avatar_rev = self.avatar_rev, gear_rev = self.gear_rev,
        flags = pose.flags, root_pos = pose.root_pos, root_rot = pose.root_rot,
        q = pose.q, tpos = pose.tpos, weapons = pose.weapons,
    })) do
        self.send(bytes, false)
        self.counters.pose_bytes = self.counters.pose_bytes + #bytes
    end
    self.counters.poses = self.counters.poses + 1
end

-------------------------------------------------------------------------------
-- Receiver
-------------------------------------------------------------------------------

local function nlerp_into(out, k, sa, sb, t)
    local ax, ay, az, aw = sa[k - 3], sa[k - 2], sa[k - 1], sa[k]
    local bx, by, bz, bw = sb[k - 3], sb[k - 2], sb[k - 1], sb[k]
    if ax == nil or bx == nil then
        out[k - 3], out[k - 2], out[k - 1], out[k] = bx or ax, by or ay, bz or az, bw or aw
        return
    end
    if ax * bx + ay * by + az * bz + aw * bw < 0 then
        bx, by, bz, bw = -bx, -by, -bz, -bw
    end
    local x, y, z, w = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-9 then
        out[k - 3], out[k - 2], out[k - 1], out[k] = 0, 0, 0, 1
    else
        out[k - 3], out[k - 2], out[k - 1], out[k] = x / len, y / len, z / len, w / len
    end
end

local function blend_weapons(wa, wb, t)
    local by_slot = {}
    for _, w in ipairs(wb) do by_slot[w.slot] = w end
    local out = {}
    for _, a in ipairs(wa) do
        local b = by_slot[a.slot]
        if b == nil or b.attach ~= a.attach then
            out[#out + 1] = t < 0.5 and a or (b or a)
        else
            local q = {}
            for k = 4, math.min(#a.q, #b.q), 4 do nlerp_into(q, k, a.q, b.q, t) end
            out[#out + 1] = {
                slot = a.slot, flags = t < 0.5 and a.flags or b.flags, attach = a.attach,
                pos = lerp3(a.pos, b.pos, t), rot = Interp.nlerp_quat(a.rot, b.rot, t), q = q,
            }
        end
    end
    return out
end

-- Blends two decoded POSE chunks. Joints extrapolate at most one pose interval (JOINT_MAX_T);
-- the root position up to MAX_EXTRAPOLATE seconds, which keeps a running partner moving
-- smoothly through a lost packet.
local function make_chunk_blend()
    local qbuf = {}
    return function(sa, sb, t)
        if sa.first ~= sb.first or sa.count ~= sb.count then
            return t < 0.5 and sa or sb
        end
        local tj = t < 0 and 0 or (t > JOINT_MAX_T and JOINT_MAX_T or t)
        local tq = t < 0 and 0 or (t > 1 and 1 or t)
        for k = 4, sa.count * 4, 4 do
            nlerp_into(qbuf, k, sa.q, sb.q, tj)
        end
        local out = { first = sa.first, count = sa.count, q = qbuf, chunk = sa.chunk }
        if sa.root_pos and sb.root_pos then
            local a, b = sa.root_pos, sb.root_pos
            local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
            if dx * dx + dy * dy + dz * dz > TELEPORT * TELEPORT then
                out.root_pos = tq < 0.5 and a or b -- teleport/door: jump, do not slide or overshoot
            else
                out.root_pos = lerp3(a, b, t)
            end
            out.root_rot = Interp.nlerp_quat(sa.root_rot, sb.root_rot, tq)
            out.flags = tq < 0.5 and sa.flags or sb.flags
            out.weapons = blend_weapons(sa.weapons or EMPTY, sb.weapons or EMPTY, tq)
            local tb = {}
            for _, b in ipairs(sb.tpos or EMPTY) do tb[b.index] = b end
            local tpos = {}
            for _, a in ipairs(sa.tpos or EMPTY) do
                local b = tb[a.index]
                tpos[#tpos + 1] = b and { index = a.index, x = lerp(a.x, b.x, tq), y = lerp(a.y, b.y, tq), z = lerp(a.z, b.z, tq) } or a
            end
            out.tpos = tpos
        end
        return out
    end
end

local Receiver = {}
Receiver.__index = Receiver

-- opts: { protocol, settings = { interp_delay } }
function Avatar.new_receiver(opts)
    local self = setmetatable({}, Receiver)
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.counters = { avatars = 0, gears = 0, poses = 0, stale_poses = 0, events = 0, stale_events = 0 }
    self:reset()
    return self
end

function Receiver:reset()
    self.avatar = nil
    self.gear = nil
    self.chunks = {}   -- chunk index -> Interp of decoded POSE chunks
    self.events = {}   -- { t = sender time, ev = event }
    self.q = {}        -- assembled flat joint rotations, reused every frame
end

function Receiver:chunk_interp(c)
    local it = self.chunks[c]
    if it == nil then
        it = Interp.new({ delay = self.settings.interp_delay or 0.066, max_extrapolate = MAX_EXTRAPOLATE,
            blend = make_chunk_blend(), adaptive = true })
        self.chunks[c] = it
    end
    return it
end

-- Returns true if the message was an avatar message.
function Receiver:on_message(m, now)
    local T = self.P.T
    if m.type == T.AVATAR then
        self.avatar = m
        self.chunks = {} -- joint order changed: old poses no longer apply
        self.q = {}
        self.counters.avatars = self.counters.avatars + 1
    elseif m.type == T.GEAR then
        self.gear = m
        self.counters.gears = self.counters.gears + 1
    elseif m.type == T.POSE then
        local ok = self.avatar ~= nil and m.avatar_rev == self.avatar.rev
        if ok then
            -- Weapons described by an older GEAR would land on the wrong models.
            if m.weapons ~= nil and (self.gear == nil or m.gear_rev ~= self.gear.rev) then
                m.weapons = {}
            end
            self:chunk_interp(m.chunk):push(m.time, now, m)
            self.counters.poses = self.counters.poses + 1
        else
            self.counters.stale_poses = self.counters.stale_poses + 1
        end
    elseif m.type == T.ACTIONS then
        for _, ev in ipairs(m.events) do
            self.events[#self.events + 1] = { t = m.time + (ev.dt or 0), ev = ev }
        end
        while #self.events > MAX_QUEUED_EVENTS do
            table.remove(self.events, 1)
        end
        self.counters.events = self.counters.events + #m.events
    else
        return false
    end
    return true
end

-- Seconds since the last pose arrived, or nil.
function Receiver:age(now)
    local main = self.chunks[1]
    return main and main:age(now) or nil
end

-- Render state for "now": { avatar, gear, pose = {root_pos, root_rot, flags, weapons, tpos, q} }.
-- pose is nil until the first POSE for the current AVATAR arrives.
function Receiver:state(now)
    if self.avatar == nil then return nil end
    local st = { avatar = self.avatar, gear = self.gear }
    local main = self.chunks[1]
    -- Every chunk is sampled at the instant chunk 1 shows: one body, one moment.
    local target = main and main:target(now)
    local root = main and main:sample_remote(target)
    if root == nil or root.root_pos == nil then
        return st
    end
    local q = self.q
    for c, it in pairs(self.chunks) do
        local s = c == 1 and root or it:sample_remote(target)
        if s ~= nil then
            local base = (s.first - 1) * 4
            local sq = s.q
            for k = 1, s.count * 4 do
                q[base + k] = sq[k]
            end
        end
    end
    st.pose = {
        root_pos = root.root_pos, root_rot = root.root_rot, flags = root.flags or 0,
        weapons = root.weapons or EMPTY, tpos = root.tpos or EMPTY, q = q,
    }
    return st
end

-- Events whose time has come on the delayed timeline the animation is shown on.
function Receiver:take_events(now)
    if #self.events == 0 then return EMPTY end
    local main = self.chunks[1]
    if main == nil or main.offset == nil then
        -- No pose stream to sync with: play them as they arrive.
        local due = {}
        for i, e in ipairs(self.events) do due[i] = e.ev end
        self.events = {}
        return due
    end
    local cutoff = now - main.offset - main:effective_delay()
    local due, keep = {}, {}
    for _, e in ipairs(self.events) do
        if e.t <= cutoff then
            if cutoff - e.t <= STALE_EVENT then
                due[#due + 1] = e.ev
            else
                self.counters.stale_events = self.counters.stale_events + 1
            end
        else
            keep[#keep + 1] = e
        end
    end
    self.events = keep
    return due
end

return Avatar
