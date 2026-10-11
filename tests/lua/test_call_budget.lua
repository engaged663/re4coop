-- Call budget: how many engine calls the mod makes per second of play, and in its worst
-- frame. The real entry script hosts against the mocked RE4 with 10 enemies, 90 pickups and a
-- connected partner (animated model, enemy sync, key items, shared world), on a simulated
-- 60 fps clock. Every engine call the mock sees is counted (method calls, field reads,
-- liveness checks). v0.6 made ~90,000 calls per second in game; the budget here keeps the
-- per-frame work from growing back.
local T = require("testlib")
local mock = require("mock_reframework")

local PORT = 45000 + (os.time() % 3000)
local real_time = re4coop_net.time
local fake_now = 1000.0
re4coop_net.time = function() return fake_now end -- the mod's clock (both sessions use it)

local world = mock.install()
world.player = mock.make_player({ x = 0, y = 0, z = 0 })
world.enemies = {}
for i = 1, 10 do
    world.enemies[i] = mock.make_character(i % 2 == 0 and "chainsaw.Ch1c0z0Context" or "chainsaw.Ch1d0z0Context",
        { x = 4 + i, y = 0, z = (i % 3) * 3 }, 100 + i)
end
for i = 1, 90 do
    mock.make_drop_item(i % 15 == 0 and (119235200 + i) or 112800000, { x = i, y = 0, z = -5 },
        { category = 3, kind = 0, group = 40200, index = i })
end
mock.files["re4coop.json"] = { player_name = "Host", port = PORT, config_version = 7 }

for name in pairs(package.loaded) do
    if name:find("^re4coop") then package.loaded[name] = nil end
end
dofile(TEST_ROOT .. "/lua/reframework/autorun/re4coop.lua")

local P = require("re4coop.protocol")
local Session = require("re4coop.session")
local Config = require("re4coop.config")

local function wrap(obj)
    return setmetatable({}, { __index = function(_, k)
        local f = obj[k]
        if f == nil then return re4coop_net[k] end
        return function(...) return f(obj, ...) end
    end })
end

-- The client: a fake game with Leon (body skeleton + face/hair joints), one weapon, the same
-- ten enemies and a moving pose.
local joints = {}
for _, n in ipairs(mock.LEON_JOINTS) do joints[#joints + 1] = n end
for _, n in ipairs({ "Jaw", "L_Eye", "R_Eye", "Hair_0", "Hair_1" }) do joints[#joints + 1] = n end
local cg = { pos = { x = 6, y = 0, z = 2 }, wanted = false, events = {}, phase = 0 }
function cg:read_player_state()
    return { pos = { x = self.pos.x, y = 0, z = self.pos.z }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 1000, max_hp = 1000 }
end
function cg:avatar_descriptor()
    local js = {}
    for i, n in ipairs(joints) do js[i] = { hash = P.hash(n), flags = n == "Hip" and P.JOINT_FLAGS.TRANSLATE or 0 } end
    return { sig = "leon", char_id = "ch0a0z0", body_name = "ch0a0z0_body", joints = js, parts = {
        { name = "cha000_00", mesh = mock.MESH.body, mdf = mock.MDF.body, parent = 0, flags = P.PART_FLAGS.SAME_JOINTS | P.PART_FLAGS.MAIN, parent_joint = "" },
        { name = "cha000_10", mesh = mock.MESH.face, mdf = mock.MDF.face, parent = 0, flags = P.PART_FLAGS.SAME_JOINTS, parent_joint = "" },
        { name = "cha000_20", mesh = mock.MESH.hair, mdf = mock.MDF.hair, parent = 0, flags = P.PART_FLAGS.SAME_JOINTS, parent_joint = "" },
    } }
end
function cg:gear_descriptor()
    local js = {}
    for i, n in ipairs(mock.WEAPON_JOINTS) do js[i] = P.hash(n) end
    return { sig = "sg09", weapons = { { name = "wp4000", mesh = mock.MESH.sg09, mdf = mock.MDF.sg09, flags = 0, joints = js } } }
end
function cg:request_pose() self.wanted = true end
function cg:take_pose(now)
    if not self.wanted then return nil end
    self.wanted = false
    self.phase = self.phase + 0.05
    local q = {}
    for i = 1, #joints do
        local a = 0.3 * math.sin(self.phase + i * 0.1)
        q[#q + 1], q[#q + 2], q[#q + 3], q[#q + 4] = 0, 0, math.sin(a / 2), math.cos(a / 2)
    end
    return { time = now, sig = "leon", gear_sig = "sg09", flags = 0, root_pos = { x = self.pos.x, y = 0, z = self.pos.z },
        root_rot = { x = 0, y = 0, z = 0, w = 1 }, q = q, tpos = {}, weapons = {} }
end
function cg:drain_events() local e = self.events self.events = {} return e end
function cg:list_enemies()
    local out = {}
    for i, e in ipairs(world.enemies) do
        out[i] = { id = i, kind = e.__type, pos = { x = e.pos.x, y = 0, z = e.pos.z }, yaw = 0, hp = e.hp, max_hp = e.max_hp,
            alive = e.hp > 0 }
    end
    return out
end
function cg:enemy_set_hp() return true end
function cg:enemy_kill() return true end
function cg:enemy_set_position() return true end
function cg:area_name() return "1" end
function cg:is_key_down() return false end

local settings = Config.load(nil)
settings.player_name, settings.port = "Client", PORT
local client = Session.new({ net = wrap(re4coop_net.new_session()), game = cg, clock = re4coop_net.time, settings = settings })

-- One frame: 1/60 s of game time; a moment of real time so loopback packets arrive.
local function frame()
    fake_now = fake_now + 1 / 60
    mock.run_frame()
    client:update()
    local t = real_time()
    while real_time() - t < 0.0005 do end
end

T.run("connect", function()
    mock.press["Host game"] = true
    frame()
    frame()
    T.check(client:join("127.0.0.1:" .. PORT), "join")
    local ok = T.wait_until(function()
        local m = mock.find("re4coop_ch0a0z0_body")[1]
        return client.partner_connected and m ~= nil and m.draw_self ~= false
    end, frame, 10)
    T.check(ok, "connected and the partner's model is up")
    for _ = 1, 180 do frame() end -- settle: enemies paired, scans done once
end)

T.run("steady_state_budget", function()
    local start = mock.calls
    local worst, worst_at = 0, 0
    local frames = 300 -- 5 seconds of play
    for i = 1, frames do
        cg.pos.x = 6 + math.sin(i / 30) -- the partner walks around
        local before = mock.calls
        frame()
        local n = mock.calls - before
        if n > worst then worst, worst_at = n, i end
    end
    local per_second = (mock.calls - start) / (frames / 60)
    print(("  %.0f engine calls per second, worst frame %d calls (frame %d)"):format(per_second, worst, worst_at))
    -- The mock's skeleton has ~30 joints where RE4's has ~350, so joint work weighs less here.
    T.check(per_second < 12000, ("engine calls per second within budget: %.0f"):format(per_second))
    T.check(worst < 1500, ("no frame does a burst of work: worst %d calls"):format(worst))
end)

T.run("idle_without_partner_costs_almost_nothing", function()
    client:leave()
    for _ = 1, 30 do frame() end
    mock.press["Stop hosting"] = true
    frame()
    frame()
    for _ = 1, 60 do frame() end
    local start = mock.calls
    for _ = 1, 120 do frame() end
    local per_second = (mock.calls - start) / 2
    print(("  single player: %.0f engine calls per second"):format(per_second))
    T.check(per_second < 600, ("single player stays cheap: %.0f calls/s"):format(per_second))
end)

re4coop_net.time = real_time
T.finish()
