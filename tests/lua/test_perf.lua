-- perf.lua: profiler windows, spikes, the perf file and crash breadcrumbs.
local T = require("testlib")
local Perf = require("re4coop.perf")

local function make(settings)
    local env = { t = 0, files = {}, writes = 0, calls = 0 }
    env.json = { dump_file = function(name, data)
        env.files[name] = data
        env.writes = env.writes + 1
        return true
    end }
    env.perf = Perf.new({ clock = function() return env.t end, json = env.json, version = "test",
        settings = settings or {}, calls = function() return env.calls end, wall = function() return "now" end })
    -- One game frame of 1/60 s in which `work` = { name = seconds, ... } is spent.
    function env:frame(work)
        for name, sec in pairs(work or {}) do
            local t0 = self.perf:start()
            self.t = self.t + sec
            self.perf:stop(name, t0)
        end
        self.t = self.t + 1 / 60
        self.perf:end_frame(self.t)
    end
    return env
end

T.run("averages_worst_frame_and_spikes", function()
    local env = make()
    for i = 1, 70 do
        env.calls = env.calls + 100
        env:frame({ update = 0.001, ["update.enemies"] = 0.0004, partner = (i == 30) and 0.006 or 0.0005 })
    end
    local r = env.perf:summary()
    T.check(r ~= nil, "published after a second")
    T.near(r.frame_avg_ms, 1.5, 0.2, "average per frame: top-level spans only (update + partner)")
    T.near(r.frame_max_ms, 7.0, 0.01, "worst frame")
    T.eq(r.spikes, 1, "one frame over 4 ms")
    T.eq(r.spans[1].name, "update", "busiest span first")
    local enemies
    for _, s in ipairs(r.spans) do if s.name == "update.enemies" then enemies = s end end
    T.near(enemies.avg_ms, 0.4, 0.01, "nested span measured too")
    T.eq(enemies.calls, 1, "once per frame")
    T.check(r.game_calls_per_s ~= nil and r.game_calls_per_s > 5000 and r.game_calls_per_s < 7000,
        "engine calls per second: " .. tostring(r.game_calls_per_s))
    T.check(r.fps > 50 and r.fps < 61, "frames per second (each fake frame is 1/60 s plus the work): " .. r.fps)
end)

T.run("pcall_spans_and_errors", function()
    local env = make()
    local ok, err = env.perf:pcall("update", function() error("boom") end)
    T.eq(ok, false, "error returned like pcall")
    T.check(tostring(err):find("boom"), "with the message")
    local ok2, v = env.perf:pcall("update", function(a, b) return a + b end, 2, 3)
    T.check(ok2 and v == 5, "results passed through")
    local nok, nv = Perf.NULL:pcall("x", function() return 7 end)
    T.check(nok and nv == 7, "the no-op profiler still runs the function")
end)

T.run("perf_file_every_ten_seconds", function()
    local env = make()
    for _ = 1, 60 * 25 do env:frame({ update = 0.0005 }) end
    local data = env.files[Perf.PERF_FILE]
    T.check(data ~= nil, "written")
    T.eq(data.mod_version, "test", "with the version")
    T.check(data.spans[1].name == "update", "spans")
    local env2 = make({ perf_file = false })
    for _ = 1, 60 * 12 do env2:frame({ update = 0.0005 }) end
    T.eq(env2.files[Perf.PERF_FILE], nil, "not written when switched off")
end)

T.run("breadcrumbs_urgent_and_throttled", function()
    local env = make()
    env:frame()
    env.perf:crumb("enemy.mirror")
    T.eq(env.files[Perf.CRUMB_FILE], nil, "ordinary breadcrumb: not written at once")
    env.perf:crumb("enemy.kill", "chainsaw.Ch1c0z0Context", true)
    local f = env.files[Perf.CRUMB_FILE]
    T.check(f ~= nil, "urgent breadcrumb written right away")
    T.eq(f.last.step, "enemy.kill", "last step first")
    T.eq(f.last.detail, "chainsaw.Ch1c0z0Context", "with its detail")
    T.eq(f.recent[2].step, "enemy.mirror", "earlier steps follow")
    local writes = env.writes
    for i = 1, 50 do env.perf:crumb("drop.request", tostring(i), true) end
    T.eq(env.writes, writes, "at most 20 urgent writes a second")
    env:frame()
    env.t = env.t + 0.6
    env:frame()
    T.eq(env.files[Perf.CRUMB_FILE].last.detail, "50", "pending breadcrumbs flushed within half a second")
    for _ = 1, 200 do env.perf:crumb("same") end
    T.check(#env.perf.crumbs <= 48, "the ring is bounded")
    T.eq(env.perf.crumbs[#env.perf.crumbs].n, 200, "repeats in one frame are counted, not stored")
    env.perf:closing("script reset")
    T.eq(env.files[Perf.CRUMB_FILE].last.step, "closed", "a clean unload is marked")
end)

T.run("each_copy_of_the_game_keeps_its_own_crash_file", function()
    local Perf = require("re4coop.perf")
    T.eq(Perf.file_name("re4coop_breadcrumb.json", nil), "re4coop_breadcrumb.json", "alone: the usual name")
    T.eq(Perf.file_name("re4coop_breadcrumb.json", "host"), "re4coop_breadcrumb_host.json", "the host's")
    T.eq(Perf.file_name("re4coop_perf.json", "client"), "re4coop_perf_client.json", "the client's")
end)

T.finish()
