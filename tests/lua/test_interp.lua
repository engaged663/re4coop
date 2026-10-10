local T = require("testlib")
local Interp = require("re4coop.interp")

local function state(x, t)
    return { pos = { x = x, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = t, flags = 0,
        joints = { { x = x, y = 1, z = 0 } } }
end

T.run("interpolates_between_snapshots", function()
    local it = Interp.new({ delay = 0.1 })
    T.check(it:sample(0) == nil, "nothing before first snapshot")
    -- Remote clock is 1000 s ahead; snapshots every 50 ms moving 1 m each; 20 ms latency.
    for i = 0, 10 do
        it:push(1000 + i * 0.05, i * 0.05 + 0.02, state(i, i))
    end
    -- At local 0.47 the renderer looks at remote time 0.47 - 0.02 - 0.1 = 0.35 -> x = 7.
    local s = it:sample(0.47)
    T.near(s.pos.x, 7, 1e-3, "x at 0.35")
    T.near(s.joints[1].x, 7, 1e-3, "joints follow")
    local s2 = it:sample(0.4825) -- remote 0.3625 -> x = 7.25
    T.near(s2.pos.x, 7.25, 1e-3, "mid-way")
end)

T.run("extrapolates_briefly_then_holds", function()
    local it = Interp.new({ delay = 0.0, max_extrapolate = 0.25 })
    it:push(0.0, 0.0, state(0))
    it:push(0.1, 0.1, state(1))
    T.near(it:sample(0.15).pos.x, 1.5, 1e-3, "extrapolated 50 ms")
    T.near(it:sample(5.0).pos.x, 3.5, 1e-3, "capped at 250 ms")
end)

T.run("handles_out_of_order_and_duplicates", function()
    local it = Interp.new({ delay = 0.0 })
    it:push(0.0, 0.0, state(0))
    it:push(0.2, 0.2, state(2))
    it:push(0.1, 0.21, state(1)) -- late
    it:push(0.2, 0.22, state(99)) -- duplicate timestamp ignored
    T.eq(#it.snapshots, 3, "3 unique snapshots")
    T.near(it:sample(0.15).pos.x, 1.5, 0.05, "late packet used for interpolation")
end)

T.run("partner_clock_restart_resets_buffer", function()
    local it = Interp.new({ delay = 0.0 })
    it:push(500.0, 1.0, state(5))
    it:push(500.1, 1.1, state(6))
    it:push(0.0, 1.2, state(0)) -- partner restarted their game: clock jumped back
    T.eq(#it.snapshots, 1, "old snapshots dropped")
    T.near(it:sample(1.2).pos.x, 0, 1e-6, "uses new timeline")
end)

T.run("quaternion_shortest_path", function()
    local a = { x = 0, y = 0, z = 0, w = 1 }
    local b = { x = 0, y = 0, z = 0, w = -1 } -- same rotation, opposite sign
    local q = Interp.nlerp_quat(a, b, 0.5)
    T.near(math.abs(q.w), 1, 1e-6, "no flip through zero")
end)

T.finish()
