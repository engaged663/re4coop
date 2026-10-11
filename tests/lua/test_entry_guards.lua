-- The entry script must stay quiet outside RE4 and explain itself when the plugin is missing.
local T = require("testlib")
local mock = require("mock_reframework")

local function run_entry()
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    dofile(TEST_ROOT .. "/lua/reframework/autorun/re4coop.lua")
end

T.run("disabled_outside_re4", function()
    mock.install({ game_name = "re2" })
    run_entry()
    T.eq(#mock.callbacks.frame + #mock.callbacks.entry + #mock.callbacks.ui, 0, "registers nothing")
end)

T.run("explains_missing_plugin", function()
    mock.install()
    local saved = re4coop_net
    re4coop_net = nil
    local ok, err = pcall(run_entry)
    re4coop_net = saved
    T.check(ok, "no error without the plugin: " .. tostring(err))
    T.eq(#mock.callbacks.frame, 0, "no per-frame work")
    T.eq(#mock.callbacks.ui, 1, "one UI panel")
    mock.callbacks.ui[1]()
    local found = false
    for _, s in ipairs(mock.imgui_texts) do
        if s:find("re4coop_net.dll is not loaded") then found = true end
    end
    T.check(found, "tells the user what to install")
end)

T.run("broken_world_adapter_does_not_stop_the_mod", function()
    local world = mock.install()
    world.player = mock.make_player({ x = 0, y = 0, z = 0 })
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    -- A game patch that breaks the world adapter's constructor.
    local World = require("re4coop.game_world")
    World.new = function() error("type layout changed") end
    local ok, err = pcall(dofile, TEST_ROOT .. "/lua/reframework/autorun/re4coop.lua")
    T.check(ok, "entry script still loads: " .. tostring(err))
    T.check(#mock.callbacks.entry > 0 and #mock.callbacks.ui > 0, "game loop and UI registered")
    mock.press["Host game"] = true
    mock.run_frame() -- the UI queues the action...
    mock.run_frame() -- ...and the next game frame carries it out
    T.eq(re4coop_net.state(), "listening", "hosting works without the shared world")
    re4coop_net.stop()
    local logged = false
    for _, l in ipairs(mock.logs) do
        if l:find("world adapter disabled") then logged = true end
    end
    T.check(logged, "the reason is logged")
end)

T.run("partner_with_other_protocol_version_is_flagged", function()
    local P = require("re4coop.protocol")
    local Session = require("re4coop.session")
    local Config = require("re4coop.config")
    local sent = {}
    local fake_net = {
        state = function() return "idle" end, role = function() return "none" end,
        poll = function() return {} end, send = function(b) sent[#sent + 1] = b return true end,
        stats = function() return { state = "connected" } end,
    }
    local fake_game = { area_name = function() return "" end }
    local s = Session.new({ net = fake_net, game = fake_game, clock = function() return 0 end,
        settings = Config.load(nil) })
    s.partner_connected = true
    s:handle_message(string.pack("<BI2", P.T.HELLO, P.VERSION + 1), 0)
    T.eq(s.compatible, false, "marked incompatible")
    local warned = false
    for _, m in ipairs(s.messages) do
        if m.text:find("update both") then warned = true end
    end
    T.check(warned, "user told to update")
    -- Game messages are ignored while incompatible.
    s:handle_message(P.encode_chat("hi"), 0)
    T.eq(#s.messages, 1, "chat ignored while incompatible")
end)

T.run("partner_in_another_chapter_is_flagged", function()
    local P = require("re4coop.protocol")
    local Session = require("re4coop.session")
    local Config = require("re4coop.config")
    local fake_net = {
        state = function() return "idle" end, role = function() return "none" end,
        poll = function() return {} end, send = function() return true end,
        stats = function() return { state = "connected" } end,
    }
    local my_area = "5"
    local fake_game = { area_name = function() return my_area end }
    local s = Session.new({ net = fake_net, game = fake_game, clock = function() return 0 end,
        settings = Config.load(nil) })
    s.partner_connected = true
    local function player_in(area)
        s:handle_message(P.encode_player({ time = 0, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 },
            area_hash = P.hash(area) }), 0)
    end
    player_in("5")
    T.eq(s:partner_elsewhere(), false, "same chapter")
    player_in("7")
    T.eq(s:partner_elsewhere(), true, "different chapter")
    player_in("")
    T.eq(s:partner_elsewhere(), false, "partner's chapter unknown")
    player_in("7")
    my_area = nil
    T.eq(s:partner_elsewhere(), false, "our chapter unknown")
end)

T.finish()
