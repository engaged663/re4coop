-- End to end: the real entry script (re4coop.lua) runs as the HOST against the mocked
-- REFramework/RE4 environment, and a second Session acts as the CLIENT with a fake game.
-- They talk over real UDP on 127.0.0.1 through the real re4coop_net bindings.
local T = require("testlib")
local mock = require("mock_reframework")

local PORT = 43000 + (os.time() % 4000)

local world = mock.install()
world.player = mock.make_player({ x = 0, y = 0, z = 0 })
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

local P = require("re4coop.protocol")

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

-- The client's own Leon, as its game.lua would describe it: same character, costume and
-- weapon as the mock's, posed with every joint turned 30 degrees about z.
local client_joints = {}
for _, n in ipairs(mock.LEON_JOINTS) do client_joints[#client_joints + 1] = n end
for _, n in ipairs({ "Jaw", "L_Eye", "R_Eye", "Hair_0", "Hair_1" }) do client_joints[#client_joints + 1] = n end
local CLIENT_ROT = { x = 0, y = 0, z = 0.2588190, w = 0.9659258 }

local client_game = {
    player = { pos = { x = 10, y = 0, z = 4 }, rot = { x = 0, y = 0, z = 0, w = 1 }, hp = 900, max_hp = 1000 },
    enemies = {
        { id = 1, kind = "chainsaw.Ch1c0z0Context", pos = { x = 5.3, y = 0, z = 0.2 }, yaw = 0, hp = 100, max_hp = 100, alive = true },
        { id = 2, kind = "chainsaw.Ch1d0z0Context", pos = { x = -0.2, y = 0, z = 8.1 }, yaw = 0, hp = 300, max_hp = 300, alive = true },
    },
    kills = 0,
    events = {},
    wanted = false,
}
function client_game:read_player_state()
    local p = self.player
    return { pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z }, rot = p.rot, hp = p.hp, max_hp = p.max_hp, dead = p.hp <= 0 }
end
function client_game:avatar_descriptor()
    local joints = {}
    for i, n in ipairs(client_joints) do
        joints[i] = { hash = P.hash(n), flags = n == "Hip" and P.JOINT_FLAGS.TRANSLATE or 0 }
    end
    return {
        sig = "client-leon", char_id = "ch0a0z0", body_name = "ch0a0z0_body", joints = joints,
        parts = {
            { name = "cha000_00", mesh = mock.MESH.body, mdf = mock.MDF.body, parent = 0, flags = P.PART_FLAGS.SAME_JOINTS | P.PART_FLAGS.MAIN, parent_joint = "" },
            { name = "cha000_10", mesh = mock.MESH.face, mdf = mock.MDF.face, parent = 0, flags = P.PART_FLAGS.SAME_JOINTS, parent_joint = "" },
            { name = "cha000_20", mesh = mock.MESH.hair, mdf = mock.MDF.hair, parent = 0, flags = P.PART_FLAGS.SAME_JOINTS, parent_joint = "" },
        },
    }
end
function client_game:gear_descriptor()
    local joints = {}
    for i, n in ipairs(mock.WEAPON_JOINTS) do joints[i] = P.hash(n) end
    return { sig = "sg09", weapons = { { name = "wp4000", mesh = mock.MESH.sg09, mdf = mock.MDF.sg09, flags = 0, joints = joints } } }
end
function client_game:request_pose() self.wanted = true end
function client_game:take_pose(now)
    if not self.wanted then return nil end
    self.wanted = false
    local q = {}
    for _ = 1, #client_joints do
        q[#q + 1], q[#q + 2], q[#q + 3], q[#q + 4] = CLIENT_ROT.x, CLIENT_ROT.y, CLIENT_ROT.z, CLIENT_ROT.w
    end
    local hand
    for i, n in ipairs(client_joints) do if n == "R_WepHand" then hand = i end end
    return {
        time = now, sig = "client-leon", gear_sig = "sg09", flags = 0,
        root_pos = { x = self.player.pos.x, y = self.player.pos.y, z = self.player.pos.z },
        root_rot = { x = 0, y = 0, z = 0, w = 1 }, q = q, tpos = { { index = 2, x = 0, y = 0.95, z = 0 } },
        weapons = { { slot = 1, flags = P.WEAPON_FLAGS.VISIBLE, attach = hand, pos = { x = 0.03, y = 0, z = 0.1 },
            rot = { x = 0, y = 0, z = 0, w = 1 }, q = {} } },
    }
end
function client_game:drain_events()
    local e = self.events
    self.events = {}
    return e
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
-- Hits and drops (game.lua hooks on a real client).
client_game.replays, client_game.hit_queue, client_game.drop_queue, client_game.spawned = {}, {}, {}, {}
function client_game:enemy_replay_hit(id, hit)
    self.replays[#self.replays + 1] = { id = id, wince = hit.wince }
    return true, 0
end
function client_game:take_hit_events()
    local q = self.hit_queue
    self.hit_queue = {}
    return q
end
function client_game:take_drop_events()
    local q = self.drop_queue
    self.drop_queue = {}
    return q
end
function client_game:set_drop_suppress(set) self.suppress = set end
function client_game:spawn_drop(item_id, count, pos, stage)
    self.spawned[#self.spawned + 1] = { item_id = item_id, count = count, pos = pos }
    return true
end

local client_settings = Config.load(nil)
client_settings.player_name = "ClientLeon"
client_settings.port = PORT
local client_net_obj = re4coop_net.new_session()
local client = Session.new({ net = wrap(client_net_obj), game = client_game, clock = re4coop_net.time,
    settings = client_settings })

local function step()
    mock.run_frame()
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

-- The host's copy of the client's character (renamed so it never passes for the real player).
local function partner_model()
    return mock.find("re4coop_ch0a0z0_body")[1]
end

local function angle(a, b)
    local dot = math.abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w)
    return 2 * math.deg(math.acos(math.min(1, dot)))
end

T.run("host_via_ui_button", function()
    mock.press["Host game"] = true
    mock.run_frame()
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
    T.eq(re4coop_net.stats().peer_name, "ClientLeon", "host knows client name")
    T.eq(client.partner_hello.area, "1", "host reports chapter from CampaignManager")
end)

T.run("host_shows_the_client_as_an_animated_leon", function()
    local ok = T.wait_until(function()
        local m = partner_model()
        return m ~= nil and m.draw_self ~= false and mock.joint(m.transform, "Spine_1").writes ~= nil
    end, step, 5)
    T.check(ok, "partner model spawned, visible and posed")
    local m = partner_model()
    T.check(world.instantiated and world.instantiated[1] == mock.PREFAB.leon_body,
        "built from Leon's body prefab, found from the character id")
    T.near(m.transform.wpos.x, 10, 1e-3, "at the client's position")
    T.check(angle(mock.joint(m.transform, "R_Forearm").lrot, CLIENT_ROT) < 0.3, "in the client's pose")
    T.check(angle(mock.joint(mock.find("re4coop_cha000_10")[1].transform, "Jaw").lrot, CLIENT_ROT) < 0.3,
        "face joints too")
    T.near(mock.joint(m.transform, "Hip").lpos.y, 0.95, 2e-3, "hip height")
    T.eq(mock.component(m, "via.motion.Motion").enabled, false, "its own animation is off")
    ok = T.wait_until(function()
        local w = mock.find("re4coop_wp4000")[1]
        return w ~= nil and w.draw_self ~= false
    end, step, 5)
    T.check(ok, "client's SG-09 R in the model's hand")
    local w = mock.find("re4coop_wp4000")[1]
    T.eq(w.transform.parent_joint, "R_WepHand", "in the right hand")
    -- No stick figure any more: just the name tag and HP bar.
    local saw_name = false
    for _, s in ipairs(mock.draw_calls.texts) do
        if s:find("ClientLeon") then saw_name = true end
    end
    T.check(saw_name, "name tag drawn")
    T.eq(mock.draw_calls.line, 0, "no skeleton lines")
end)

T.run("client_receives_the_hosts_character", function()
    local ok = T.wait_until(function()
        local st = client:partner_avatar()
        return st ~= nil and st.pose ~= nil and st.gear ~= nil
    end, step, 5)
    T.check(ok, "avatar, gear and pose arrived")
    local st = client:partner_avatar()
    T.eq(st.avatar.char_id, "ch0a0z0", "host's character id")
    T.eq(#st.avatar.parts, 3, "host's costume parts")
    T.eq(st.avatar.parts[1].mesh, mock.MESH.body, "with their meshes")
    T.eq(#st.avatar.joints, #mock.LEON_JOINTS + 5, "and the full skeleton")
    T.eq(st.gear.weapons[1].name, "wp4000", "host's weapon")
    -- The host's mock Leon has a recognisable pose (see mock.make_player).
    local j5 = world.player.body.transform.joints[5].lrot
    local q = st.pose.q
    T.check(angle({ x = q[17], y = q[18], z = q[19], w = q[20] }, j5) < 0.3, "host's joint 5 rotation")
    T.near(st.pose.root_pos.x, world.player.pos.x, 1e-3, "host's position")
end)

T.run("sounds_and_shots_cross_over", function()
    -- Client side: its game captured a gunshot sound and a shot.
    local trigger = P.hash("via.wwise.WwiseContainer::trigger(System.UInt32)")
    world.sounds = {}
    local before_flashes = world.flashes or 0
    client_game.events = {
        { kind = P.EVENT.CALL, time = re4coop_net.time(), part = P.REF.WEAPON_BASE + 1,
            comp_type = P.hash("chainsaw.WwiseContainerApp"), comp_idx = 1, method = trigger,
            args = { { tag = P.ARG.U32, value = 4000123 } } },
        { kind = P.EVENT.SHOT, time = re4coop_net.time(), slot = 1 },
    }
    local ok = T.wait_until(function()
        for _, s in ipairs(world.sounds) do
            if s.id == 4000123 then return true end
        end
        return false
    end, step, 5)
    T.check(ok, "the client's gunshot plays on the host, from the model's gun")
    for _, s in ipairs(world.sounds) do
        if s.id == 4000123 then T.eq(s.go, "re4coop_wp4000", "positioned at the model's weapon") end
    end
    -- Each event plays when the delayed timeline reaches its own time, so the shot (stamped a
    -- moment after the sound) can come one frame later.
    ok = T.wait_until(function() return (world.flashes or 0) > before_flashes end, step, 2)
    T.check(ok, "muzzle flash at the model's gun")

    -- Host side: its Leon's footstep reaches the client.
    world.player.sound:call("trigger(System.UInt32)", 777)
    world.player.gun:call("shoot")
    local got_sound, got_shot = false, false
    ok = T.wait_until(function()
        for _, ev in ipairs(client:take_partner_events()) do
            if ev.kind == P.EVENT.CALL and ev.args[1] and ev.args[1].value == 777 then got_sound = true end
            if ev.kind == P.EVENT.SHOT then got_shot = true end
        end
        return got_sound and got_shot
    end, step, 5)
    T.check(ok, "host's sound and shot delivered to the client")
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

T.run("hits_and_drops_end_to_end", function()
    -- Host shoots enemy 1: the hooked HitController.callbackDamageHit reports it, the client replays it.
    mock.hit(host_e1, 10, 15)
    local ok = T.wait_until(function() return #client_game.replays > 0 end, step, 5)
    T.check(ok, "client replayed the host's hit")
    T.eq(client_game.replays[1] and client_game.replays[1].id, 1, "on its copy of enemy 1")
    T.eq(client_game.replays[1] and client_game.replays[1].wince, 15, "with the host's wince")
    local hp_after_host_hit = host_e1.hp

    -- Client shoots enemy 1: the host replays it through the real game adapter.
    client_game.hit_queue = { { id = 1, damage = 30, wince = 7, break_ = 0, stopping = 0,
        dir = { x = 0, y = 0, z = 1 }, weapon = 4000, critical = false } }
    ok = T.wait_until(function()
        local r = mock.component(host_e1.body, "chainsaw.HitController").received
        return r ~= nil and r[#r].wince == 7
    end, step, 5)
    T.check(ok, "host's enemy reacted to the client's hit")
    local r = mock.component(host_e1.body, "chainsaw.HitController").received
    T.eq(r[#r].damage, 1, "cosmetic replay")
    T.eq(host_e1.hp, hp_after_host_hit, "replay did not change the host's HP")

    -- Enemy 2 (killed by the host earlier) drops ammo: the client gets the same item.
    client_game.drop_queue = { { enemy_id = 2, droptype = 65536 } } -- the client's own drop hook works
    run_for(0.6)
    T.eq(client_game.suppress and client_game.suppress[1], true, "client skips its own rolls for paired enemies")
    mock.enemy_drop(host_e2, 112806400)
    ok = T.wait_until(function() return #client_game.spawned > 0 end, step, 5)
    T.check(ok, "client spawned the host's drop")
    T.eq(client_game.spawned[1] and client_game.spawned[1].item_id, 112806400, "same item")
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
    mock.run_frame()
    local log = mock.files["re4coop_research_log.json"]
    T.check(log ~= nil and #log.runs == 1, "research log written from the UI")
    T.eq(log.runs[1].session.role, "host", "session state included")
    T.eq(log.runs[1].session.partner_model.state, "ready", "partner model status included")
    T.eq(log.runs[1].session.partner_model.char_id, "ch0a0z0", "and which character it shows")
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
    local ok = T.wait_until(function() return host_messages_contain("ClientLeon: buenas, vamos") end, step, 5)
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

T.run("script_reset_keeps_connection_and_rebuilds_the_model", function()
    local old_model = partner_model()
    for _, cb in ipairs(mock.callbacks.reset) do cb() end
    T.check(old_model.destroyed, "model removed on script reset")
    -- REFramework drops the old Lua state's hooks with it.
    for _, td in pairs(mock.classes) do
        for _, m in pairs(td.methods) do m.hooks = nil end
    end
    mock.hooks = {}
    mock.callbacks.entry, mock.callbacks.frame, mock.callbacks.ui = {}, {}, {}
    mock.callbacks.config_save, mock.callbacks.reset = {}, {}
    run_entry_script()
    for _ = 1, 20 do step() end
    T.eq(re4coop_net.state(), "connected", "still connected after Reset Scripts")
    T.check(host_messages_contain("Resumed existing co%-op session"), "resumed")
    local ok = T.wait_until(function()
        local m = partner_model()
        return m ~= nil and m ~= old_model and m.draw_self ~= false
    end, step, 5)
    T.check(ok, "the reloaded script rebuilt the partner's model")
end)

T.run("client_leaves_host_keeps_listening", function()
    client:leave()
    local ok = T.wait_until(function() return host_messages_contain("ClientLeon disconnected") end, step, 5)
    T.check(ok, "host told about the departure")
    T.eq(re4coop_net.state(), "listening", "host back to listening for a rejoin")
    T.check(partner_model() == nil, "partner model removed")
    T.eq(#mock.find("re4coop_wp4000"), 0, "and their weapon")
    mock.press["Stop hosting"] = true
    mock.run_frame()
    T.eq(re4coop_net.state(), "idle", "stop hosting")
    for _, cb in ipairs(mock.callbacks.config_save) do cb() end
    T.eq(mock.files["re4coop.json"].player_name, "HostLeon", "settings saved")
end)

T.finish()
