-- Profiler and crash breadcrumbs.
--
--   * Profiler: the mod's work is timed in named spans ("update", "update.enemies",
--     "partner", ...). Names without a dot are top-level work; their sum is what the mod
--     costs per frame. Every second the averages, the worst frame and the number of frames
--     that took longer than SPIKE_MS are published for the Diagnostics panel, and every
--     FILE_INTERVAL seconds they are written to reframework/data/re4coop_perf.json.
--   * Breadcrumbs: before the mod does something that changes the game (kills an enemy,
--     reloads a save table, warps, spawns...), it records a breadcrumb. The most recent ones
--     are kept in reframework/data/re4coop_breadcrumb.json: "urgent" ones (rare, risky
--     calls) are written right away, the rest at most twice a second. If the game crashes,
--     the file says what the mod did last and in which frame.
--
-- Pure Lua; the clock and the json writer are injected (tests/lua/test_perf.lua).

local Perf = {}
Perf.__index = Perf

local WINDOW = 1.0          -- seconds per published measurement
local SPIKE_MS = 4.0        -- a frame where the mod took longer than this is a spike
local FILE_INTERVAL = 10.0  -- seconds between writes of the perf file
local CRUMB_RING = 48
local CRUMB_FLUSH = 0.5     -- seconds between writes of ordinary breadcrumbs
local CRUMB_MIN_GAP = 0.05  -- urgent breadcrumbs: at most 20 file writes per second
local TOP_SPANS = 12

Perf.PERF_FILE = "re4coop_perf.json"
Perf.CRUMB_FILE = "re4coop_breadcrumb.json"

-- opts: { clock = function() -> seconds, json = { dump_file }, version = <string>,
--         settings = <live config (profiler, perf_file)>, calls = function() -> game call count,
--         wall = function() -> <date string> }
function Perf.new(opts)
    local self = setmetatable({}, Perf)
    self.clock = opts.clock or os.clock
    self.json = opts.json
    self.version = opts.version or "?"
    self.settings = opts.settings or {}
    self.calls = opts.calls
    self.wall = opts.wall or function()
        local ok, t = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ")
        return ok and t or nil
    end
    self.frame_t = {}        -- name -> seconds spent in the current frame
    self.frame_n = {}        -- name -> calls in the current frame
    self.acc = {}            -- name -> { sum, max, n } over the current window
    self.frames = 0
    self.frame_no = 0
    self.window_start = nil
    self.window_calls = nil
    self.window_frame_sum, self.window_frame_max, self.window_spikes = 0, 0, 0
    self.result = nil        -- last published window (see Perf:summary)
    self.last_file = -math.huge
    self.crumbs = {}         -- ring, oldest first
    self.crumb_dirty = false
    self.last_crumb_write = -math.huge
    self.crumb_writes = 0
    return self
end

function Perf:enabled()
    return self.settings.profiler ~= false
end

-------------------------------------------------------------------------------
-- Spans
-------------------------------------------------------------------------------

function Perf:start()
    return self.clock()
end

function Perf:stop(name, t0)
    local dt = self.clock() - t0
    local ft = self.frame_t
    ft[name] = (ft[name] or 0) + dt
    self.frame_n[name] = (self.frame_n[name] or 0) + 1
    return dt
end

-- pcall(fn, ...) timed under `name`. Returns pcall's first two results.
function Perf:pcall(name, fn, ...)
    local t0 = self.clock()
    local ok, err = pcall(fn, ...)
    self:stop(name, t0)
    return ok, err
end

local function is_top(name)
    return name:find(".", 1, true) == nil
end

-- Closes the current frame. Call once per game frame (start of the game-thread callback).
function Perf:end_frame(now)
    self.frame_no = self.frame_no + 1
    if self.window_start == nil then
        self.window_start = now
        self.window_calls = self.calls and self.calls() or nil
    end
    local total = 0
    local acc = self.acc
    for name, t in pairs(self.frame_t) do
        local a = acc[name]
        if a == nil then
            a = { sum = 0, max = 0, n = 0 }
            acc[name] = a
        end
        a.sum = a.sum + t
        if t > a.max then a.max = t end
        a.n = a.n + (self.frame_n[name] or 0)
        if is_top(name) then total = total + t end
        self.frame_t[name] = nil
        self.frame_n[name] = nil
    end
    self.frames = self.frames + 1
    self.window_frame_sum = self.window_frame_sum + total
    if total > self.window_frame_max then self.window_frame_max = total end
    if total * 1000 > SPIKE_MS then self.window_spikes = self.window_spikes + 1 end

    local elapsed = now - self.window_start
    if elapsed >= WINDOW then
        self:publish(now, elapsed)
    end
    if self.crumb_dirty and now - self.last_crumb_write >= CRUMB_FLUSH then
        self:flush_crumbs(now)
    end
    if self.settings.perf_file ~= false and self.result ~= nil and now - self.last_file >= FILE_INTERVAL then
        self:write_file(now)
    end
end

function Perf:publish(now, elapsed)
    local frames = math.max(self.frames, 1)
    local spans = {}
    for name, a in pairs(self.acc) do
        spans[#spans + 1] = {
            name = name,
            avg_ms = a.sum / frames * 1000,
            max_ms = a.max * 1000,
            calls = a.n / frames,
        }
    end
    table.sort(spans, function(x, y)
        if x.avg_ms ~= y.avg_ms then return x.avg_ms > y.avg_ms end
        return x.name < y.name
    end)
    local calls_now = self.calls and self.calls() or nil
    self.result = {
        spans = spans,
        frame_avg_ms = self.window_frame_sum / frames * 1000,
        frame_max_ms = self.window_frame_max * 1000,
        spikes = self.window_spikes,
        fps = self.frames / elapsed,
        game_calls_per_s = (calls_now and self.window_calls) and (calls_now - self.window_calls) / elapsed or nil,
        window = elapsed,
        frame = self.frame_no,
    }
    self.acc = {}
    self.frames = 0
    self.window_start = now
    self.window_calls = calls_now
    self.window_frame_sum, self.window_frame_max, self.window_spikes = 0, 0, 0
end

-- The last published second: { spans = { {name, avg_ms, max_ms, calls}, ... } (busiest first),
-- frame_avg_ms, frame_max_ms, spikes, fps, game_calls_per_s } or nil before the first one.
function Perf:summary()
    return self.result
end

local function top(spans, n)
    local out = {}
    for i = 1, math.min(#spans, n) do
        local s = spans[i]
        out[i] = { name = s.name, avg_ms = math.floor(s.avg_ms * 1000 + 0.5) / 1000,
            max_ms = math.floor(s.max_ms * 1000 + 0.5) / 1000, calls = math.floor(s.calls * 100 + 0.5) / 100 }
    end
    return out
end

function Perf:write_file(now)
    self.last_file = now
    if self.json == nil or self.result == nil then return false end
    local r = self.result
    local data = {
        mod_version = self.version, written = self.wall(), frame = self.frame_no,
        frame_avg_ms = r.frame_avg_ms, frame_max_ms = r.frame_max_ms, spikes_per_s = r.spikes / r.window,
        fps = r.fps, game_calls_per_s = r.game_calls_per_s, spans = top(r.spans, 40),
    }
    return (pcall(self.json.dump_file, Perf.PERF_FILE, data))
end

-------------------------------------------------------------------------------
-- Breadcrumbs
-------------------------------------------------------------------------------

-- Records what the mod is about to do. urgent = rare and risky (write the file now).
function Perf:crumb(step, detail, urgent)
    local now = self.clock()
    local ring = self.crumbs
    local last = ring[#ring]
    if last ~= nil and last.step == step and last.detail == detail and last.frame == self.frame_no then
        last.n = last.n + 1
        last.t = now
    else
        ring[#ring + 1] = { step = step, detail = detail, t = now, frame = self.frame_no, n = 1 }
        if #ring > CRUMB_RING then table.remove(ring, 1) end
    end
    self.crumb_dirty = true
    if urgent then self:flush_crumbs(now) end
end

function Perf:flush_crumbs(now)
    if not self.crumb_dirty or self.json == nil then return false end
    if now - self.last_crumb_write < CRUMB_MIN_GAP then return false end -- written on a later frame
    self.last_crumb_write = now
    self.crumb_dirty = false
    local recent = {}
    for i = #self.crumbs, 1, -1 do
        local c = self.crumbs[i]
        recent[#recent + 1] = { step = c.step, detail = c.detail, frame = c.frame, n = c.n,
            ago_ms = math.floor((now - c.t) * 1000 + 0.5) }
    end
    local data = {
        mod_version = self.version, written = self.wall(), frame = self.frame_no,
        last = recent[1], recent = recent,
        perf = self.result and top(self.result.spans, 8) or nil,
    }
    self.crumb_writes = self.crumb_writes + 1
    return (pcall(self.json.dump_file, Perf.CRUMB_FILE, data))
end

-- The script is unloading on purpose: say so, so the file does not look like a crash.
function Perf:closing(why)
    self:crumb("closed", why)
    self.last_crumb_write = -math.huge
    self:flush_crumbs(self.clock())
end

-------------------------------------------------------------------------------
-- No-op stand-in for code that runs without a profiler (tests, adapters on their own).
-------------------------------------------------------------------------------

local Null = {}
Null.__index = Null
function Null.start() return 0 end
function Null.stop() return 0 end
function Null.pcall(_, _, fn, ...) return pcall(fn, ...) end
function Null.crumb() end
function Null.end_frame() end
function Null.summary() return nil end
function Null.flush_crumbs() return false end
function Null.closing() end
function Null.enabled() return false end
Perf.NULL = setmetatable({ frame_no = 0 }, Null)

return Perf
