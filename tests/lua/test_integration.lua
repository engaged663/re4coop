-- End to end: the real entry script (re4coop.lua) runs as the HOST against the mocked
-- REFramework/RE4 environment, and a second Session acts as the CLIENT with a fake game.
-- They talk over real UDP on 127.0.0.1 through the real re4coop_net bindings.
local T = require("testlib")
local mock = require("mock_reframework")

local PORT = 43000 + (os.time() % 4000)

local world = mock.install()
world.player = mock.make_character("chainsaw.PlayerBaseContext", { x = 0, y = 0, z = 0 }, 1200)
local host_e1 = mock.make_character("chainsaw.Ch1c0z0Context", { x = 5, y = 0, z = 0 }, 100)
local host_e2 = mock.make_character("chainsaw.Ch1d0z0Context", { x = 0, y = 0, z = 8 }, 300)
world.enemies = { host_e1, host_e2 }
mock.files["re4coop.json"] = { player_name = "HostLeon", port = PORT }

local function run_entry_script()
    for name in pairs(package.loaded) do
        if name:find("^re4coop") then package.loaded[name] = nil end
    end
    dofile(TEST_ROOT .. "/lua/reframework/autorun/re4coop.lua")
end

run_entry_script()

local function host_frame()
    for _, cb in ipairs(mock.callbacks.entry) do cb.fn() end
    for _, cb in ipairs(mock.callbacks.frame) do cb() end
    for _, cb in ipairs(mock.callbacks.ui) do cb() end
end

-- Client: Session + fake game, using an independent network session object.
local Session = require("re4coop.session")
local Config = require("re4coop.config")

local function wrap(obj)
    return setmetatable({}, { __index = function(_, k)
        local f = obj[k]
        if f == nil then return re4coop_net[k] end
        return function(...) return f(obj, ...) end
    end })
end

local client_game = {
    player = { pos = { x = 10, y = 0, z = 4 }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 900, max_hp = 1000,
        joints = { { x = 10, y = 1, z = 4 }, { x = 10, y = 1.6, z = 4 } }, parents = { 0, 1 } },
    enemies = {
        { id = 1, kind = "chainsaw.Ch1c0z0Context", pos = { x = 5.3, y = 0, z = 0.2 }, yaw = 0, hp = 100, max_hp = 100, alive = true },
        { id = 2, kind = "chainsaw.Ch1d0z0Context", pos = { x = -0.2, y = 0, z = 8.1 }, yaw = 0, hp = 300, max_hp = 300, alive = true },
    },
    kills = 0,
}
function client_game:read_player_state()
    local p = self.player
    return { pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z }, rot = p.rot, hp = p.hp, max_hp = p.max_hp,
        joints = p.joints, parents = p.parents, dead = p.hp <= 0 }
end
function client_game:list_enemies()
    local out = {}
    for i, e in ipairs(self.enemies) do
        out[i] = { id = e.id, kind = e.kind, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z }, yaw = 0,
            hp = e.hp, max_hp = e.max_hp, alive = e.alive }
    end
    return out
end
function client_game:enemy_set_hp(id, hp) self.enemies[id].hp = hp return true end
function client_game:enemy_kill(id) self.enemies[id].hp = 0 self.enemies[id].alive = false self.kills = self.kills + 1 return true end
function client_game:enemy_set_position() return true end
function client_game:area_name() return "1" end
function client_game:teleport_player() return true end

local client_settings = Config.load(nil)
client_settings.player_name = "ClientAshley"
client_settings.port = PORT
local client_net_obj = re4coop_net.new_session()
local client = Session.new({ net = wrap(client_net_obj), game = client_game, clock = re4coop_net.time,
    settings = client_settings })

local function step()
    host_frame()
    client:update()
end

local function host_messages_contain(pattern)
    for _, s in ipairs(mock.logs) do
        if s:find(pattern) then return true end
    end
    return false
end

T.run("host_via_ui_button", function()
    mock.press["Host game"] = true
    host_frame()
    T.eq(re4coop_net.state(), "listening", "host listening after clicking Host game")
    T.check(host_messages_contain("Hosting on UDP port " .. PORT), "host log mentions port")
end)

T.run("client_joins_and_handshakes", function()
    T.check(client:join("127.0.0.1:" .. PORT), "join started")
    local ok = T.wait_until(function()
        return client.partner_connected and client.partner_hello ~= nil and re4coop_net.state() == "connected"
    end, step, 5)
    T.check(ok, "connected + HELLO received")
    T.eq(client.partner_name, "HostLeon", "client knows host name")
    T.eq(re4coop_net.stats().peer_name, "ClientAshley", "host knows client name")
    T.eq(client.partner_hello.area, "1", "host reports chapter from CampaignManager")
end)

T.run("player_states_and_ghosts", function()
    local ok = T.wait_until(function()
        return client:partner_render_state() ~= nil and mock.draw_calls.line > 0
    end, step, 5)
    T.check(ok, "both sides render the partner")
    local st, parents = client:partner_render_state()
    T.eq(#st.joints, 19, "host skeleton joints arrive at the client")
    T.eq(#parents, 19, "with parent table")
    T.near(st.max_hp, 1200, 1e-6, "host HP visible to client")
    local saw_name = false
    for _, s in ipairs(mock.draw_calls.texts) do
        if s:find("ClientAshley") then saw_name = true end
    end
    T.check(saw_name, "host draws client's name tag / HUD")
end)

T.run("enemy_sync_end_to_end", function()
    -- Let the client pair its enemies with the host's snapshot.
    T.wait_until(function() return client.enemy_sync:summary().paired == 2 end, step, 5)
    T.eq(client.enemy_sync:summary().paired, 2, "client paired both enemies")

    client_game.enemies[1].hp = 60 -- client shoots enemy 1 for 40
    local ok = T.wait_until(function() return host_e1.hp == 60 end, step, 5)
    T.check(ok, "host enemy took the client's damage via chainsaw.HitPoint setter (hp=" .. host_e1.hp .. ")")

    host_e2.hp = 0 -- host kills enemy 2
    ok = T.wait_until(function() return client_game.enemies[2].alive == false end, step, 5)
    T.check(ok, "client's copy died when the host killed it")
    T.eq(client_game.kills, 1, "exactly one kill applied")
    for _ = 1, 50 do step() end
    T.eq(host_e1.hp, 60, "no damage echo after settling")
end)

T.run("chat_and_teleport", function()
    T.check(client:send_chat("buenas, vamos"), "chat sent")
    local ok = T.wait_until(function() return host_messages_contain("ClientAshley: buenas, vamos") end, step, 5)
    T.check(ok, "host received chat")

    mock.press["Teleport to partner"] = true
    step()
    T.check(world.player.pos.x > 5, "host teleported towards client (x=" .. world.player.pos.x .. ")")
    T.eq(world.player.warped, 1, "CharacterController.warp used")
    ok = T.wait_until(function()
        for _, m in ipairs(client.messages) do
            if m.text:find("teleported to you") then return true end
        end
        return false
    end, step, 5)
    T.check(ok, "client notified about the teleport")
end)

T.run("script_reset_keeps_connection", function()
    for _, cb in ipairs(mock.callbacks.reset) do cb() end
    mock.callbacks.entry, mock.callbacks.frame, mock.callbacks.ui = {}, {}, {}
    mock.callbacks.config_save, mock.callbacks.reset = {}, {}
    run_entry_script()
    for _ = 1, 20 do step() end
    T.eq(re4coop_net.state(), "connected", "still connected after Reset Scripts")
    T.check(host_messages_contain("Resumed existing co%-op session"), "resumed")
    local before = mock.draw_calls.line
    T.wait_until(function() return mock.draw_calls.line > before end, step, 3)
    T.check(mock.draw_calls.line > before, "ghost still drawn by the reloaded script")
end)

T.run("client_leaves_host_keeps_listening", function()
    client:leave()
    local ok = T.wait_until(function() return host_messages_contain("ClientAshley disconnected") end, step, 5)
    T.check(ok, "host told about the departure")
    T.eq(re4coop_net.state(), "listening", "host back to listening for a rejoin")
    mock.press["Stop hosting"] = true
    host_frame()
    T.eq(re4coop_net.state(), "idle", "stop hosting")
    for _, cb in ipairs(mock.callbacks.config_save) do cb() end
    T.eq(mock.files["re4coop.json"].player_name, "HostLeon", "settings saved")
end)

T.finish()
