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
mock.files["re4coop.json"] = { player_name = "HostLeon", port = PORT, left_behind_distance = 30, left_behind_seconds = 1 }

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
client_game.pickups, client_game.removed = {}, {}
function client_game.is_key_item(id) return id >= 119000000 and id <= 119999999 end
function client_game:list_pickups()
    local out = {}
    for i, p in ipairs(self.pickups) do out[i] = { id = p.id, item_id = p.item_id, pos = p.pos, ctx = p.ctx } end
    return out
end
function client_game:remove_pickup(id)
    for i, p in ipairs(self.pickups) do
        if p.id == id then
            table.remove(self.pickups, i)
            self.removed[#self.removed + 1] = p.item_id
            return true
        end
    end
    return false
end
function client_game:is_key_down() return false end

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

-- Keeps both sides running for real time (pickup scans run every 0.25 s).
local function run_for(seconds)
    T.wait_until(function() return false end, step, seconds)
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

T.run("key_items_exist_once", function()
    local COG, FUEL = 119235200, 119273600
    local cog_ctx = { category = 5, kind = 0, group = 31, index = 4 }
    local fuel_ctx = { category = 5, kind = 0, group = 31, index = 5 }

    -- Client picks up the Wooden Cog: the host's copy disappears.
    local cog_h = mock.make_drop_item(COG, { x = 1, y = 0, z = 0 }, cog_ctx)
    client_game.pickups = { { id = 1, item_id = COG, pos = { x = 1, y = 0, z = 0 }, ctx = cog_ctx } }
    client_game.player.pos = { x = 1.5, y = 0, z = 0 }
    run_for(0.6)
    table.remove(client_game.pickups, 1)
    local ok = T.wait_until(function() return cog_h.go.destroyed == true end, step, 5)
    T.check(ok, "host's Wooden Cog removed through chainsaw.DropItem's GameObject")

    -- Host picks up the Boat Fuel: the client's copy disappears.
    local fuel_h = mock.make_drop_item(FUEL, { x = 0.5, y = 0, z = 0 }, fuel_ctx)
    client_game.pickups = { { id = 2, item_id = FUEL, pos = { x = 0.5, y = 0, z = 0 }, ctx = fuel_ctx } }
    run_for(0.6)
    mock.remove_drop(fuel_h)
    ok = T.wait_until(function() return client_game.removed[1] == FUEL end, step, 5)
    T.check(ok, "client's Boat Fuel removed")
    T.check(host_messages_contain("Partner picked up a key item"), "host was told about the Cog")

    -- Host picks up the Church Insignia 20 m from where the game says it stands (the proximity
    -- heuristic would refuse): the game's DropItem.onAcceptPickup callback confirms it.
    local INSIGNIA = 119257600
    local herb_h = mock.make_drop_item(112800000, { x = 0, y = 0, z = 1 }, { category = 2, kind = 0, group = 12, index = 90 })
    local ins_ctx = { category = 3, kind = 0, group = 40210, index = 6 }
    local ins_h = mock.make_drop_item(INSIGNIA, { x = 20, y = 0, z = 0 }, ins_ctx)
    client_game.pickups = { { id = 3, item_id = INSIGNIA, pos = { x = 20, y = 0, z = 0 }, ctx = ins_ctx } }
    run_for(0.6)
    mock.pickup(herb_h) -- an ordinary pickup proves the callback
    run_for(0.6)
    mock.pickup(ins_h)
    ok = T.wait_until(function() return client_game.removed[2] == INSIGNIA end, step, 5)
    T.check(ok, "client's Church Insignia removed via the confirmed pickup")
    client_game.player.pos = { x = 10, y = 0, z = 4 }
    run_for(0.5) -- let the host's view of the client catch up
end)

T.run("research_dump_button_while_connected", function()
    mock.press["Write research dump (adds a run to reframework/data/)"] = true
    host_frame()
    local log = mock.files["re4coop_research_log.json"]
    T.check(log ~= nil and #log.runs == 1, "research log written from the UI")
    T.eq(log.runs[1].session.role, "host", "session state included")
    T.check(log.runs[1].session.items.counters.confirmed >= 1, "item sync counters included")
    T.eq(mock.files["re4coop_typedump.json"].runs, 1, "type dump written")
    local shown = false
    for _, t in ipairs(mock.imgui_texts) do
        if t:find("run 1 saved", 1, true) then shown = true end
    end
    T.check(shown, "UI confirms the run")
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

T.run("left_behind_prompt_and_hotkey", function()
    client_game.player.pos = { x = 80, y = 0, z = 4 } -- client went through a door the host cannot open
    -- The prompt waits out the 4 s post-teleport watch from the previous test, then 1 s far away.
    local ok = T.wait_until(function()
        for _, s in ipairs(mock.draw_calls.texts) do
            if s:find("press F6 to teleport") then return true end
        end
        return false
    end, step, 8)
    T.check(ok, "host HUD shows the teleport prompt")
    mock.keys[0x75] = true
    step()
    mock.keys[0x75] = false
    T.check(world.player.pos.x > 70, "F6 teleported the host to the client (x=" .. world.player.pos.x .. ")")
    client_game.player.pos = { x = 10, y = 0, z = 4 }
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
