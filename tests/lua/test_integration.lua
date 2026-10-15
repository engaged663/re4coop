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
mock.files["re4coop.json"] = { player_name = "HostLeon", port = PORT, left_behind_distance = 30, left_behind_seconds = 1,
    config_version = 9 }

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
        out[i] = { id = e.id, kind = e.kind, pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
            rot = { x = 0, y = 0, z = 0, w = 1 }, hp = e.hp, max_hp = e.max_hp, alive = e.alive }
    end
    return out
end
function client_game:enemy_set_hp(id, hp) self.enemies[id].hp = math.max(1, hp) return true end
function client_game:enemy_kill(id, fields, by)
    self.enemies[id].hp = 0
    self.enemies[id].alive = false
    self.enemies[id].killing_hit = fields
    self.enemies[id].killed_by = by
    self.kills = self.kills + 1
    return true
end
client_game.puppet = {}
function client_game:enemy_set_puppet(id, on) self.puppet[id] = on or nil return true end
function client_game:enemy_set_transform(id, pos)
    self.enemies[id].pos = { x = pos.x, y = pos.y, z = pos.z }
    return true
end
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
function client_game:take_hit_events()
    local q = self.hit_queue
    self.hit_queue = {}
    return q
end
-- Finishers our player started on puppets (game_partner.lua's hooks on their AI heads):
-- { {id, kind, ftype, pos, yaw}, ... }.
client_game.fatal_queue = {}
function client_game:take_fatal_events()
    local q = self.fatal_queue
    self.fatal_queue = {}
    return q
end
-- Noises our player made (game_partner.lua's SoundDetectionManager.registerSound hook).
client_game.noise_queue = {}
function client_game:take_noise_events()
    local q = self.noise_queue
    self.noise_queue = {}
    return q
end
-- Hits the host's enemies landed on our character there (game_partner.lua's player_take_hit).
client_game.host_hits = {}
function client_game:player_take_hit(hit, attacker)
    self.host_hits[#self.host_hits + 1] = { hit = hit, attacker = attacker }
    return "applied"
end
-- The host's enemies' warnings our player's head got (player_action_sign), our player's
-- parries of our copies (take_parry_events), the escape presses while held (player_grab_input:
-- grab_presses presses, one a frame) and who let our character go (player_grab_release).
client_game.signs, client_game.parry_queue, client_game.released, client_game.grab_presses = {}, {}, {}, 0
function client_game:player_action_sign(id, m)
    self.signs[#self.signs + 1] = { id = id, m = m }
    return true
end
function client_game:take_parry_events()
    local q = self.parry_queue
    self.parry_queue = {}
    return q
end
function client_game:player_grab_input()
    if self.grab_presses > 0 then
        self.grab_presses = self.grab_presses - 1
        return "mash"
    end
    return nil
end
function client_game:player_grab_release(id, action)
    self.released[#self.released + 1] = { id = id, action = action }
    return true
end
function client_game:take_drop_events()
    local q = self.drop_queue
    self.drop_queue = {}
    return q
end
function client_game:request_enemy_drop(id)
    self.spawned[#self.spawned + 1] = { enemy = id }
    self.drop_queue[#self.drop_queue + 1] = { enemy_id = id, via = "generate" }
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
    mock.run_frame() -- the UI queues the action...
    mock.run_frame() -- ...the next game frame carries it out
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

-- What game.lua's hit hook reports for a hit our player landed (and what it let happen here).
local function client_hit(id, damage, wince)
    local e = client_game.enemies[id]
    local hp = e.hp
    local local_damage = damage
    if client_game.puppet[id] and damage >= hp then local_damage = hp - 1 end
    e.hp = e.hp - local_damage
    client_game.hit_queue[#client_game.hit_queue + 1] = { id = id, damage = damage, hp = hp, local_damage = local_damage,
        lethal = damage >= hp, fields = { { h = P.hash("Damage"), t = P.HIT_VALUE.I32, v = damage },
            { h = P.hash("Wince"), t = P.HIT_VALUE.F32, v = wince } } }
end

T.run("enemy_sync_end_to_end", function()
    -- Both enemies are nearer the host: its game runs them, the client's copies follow.
    T.wait_until(function() return client.enemy_net:summary().paired == 2 end, step, 5)
    T.eq(client.enemy_net:summary().paired, 2, "client paired both enemies")
    T.wait_until(function() return client_game.puppet[1] and client_game.puppet[2] end, step, 5)
    T.eq(client_game.puppet[1], true, "the client's copies are puppets of the host's")

    -- The client shoots enemy 1: the hit runs through the host's own hit code, with its values
    -- (and the attack data of the host's own weapon: the host has shot something before).
    mock.hit(host_e2, 0, 0)
    client_hit(1, 40, 7)
    local ok = T.wait_until(function() return host_e1.hp == 60 end, step, 5)
    T.check(ok, "the host's enemy took the client's hit (hp=" .. host_e1.hp .. ")")
    local r = mock.component(host_e1.body, "chainsaw.HitController").received
    T.eq(r[#r].wince, 7, "and reacted with the client's wince")
    T.eq(r[#r].attacker, partner_model(), "the client's character attacks in the host's game (the enemy turns on it)")

    -- The host's AI walks enemy 1: the client's copy follows.
    host_e1.pos.x, host_e1.pos.z = 7, 1.5
    ok = T.wait_until(function() return math.abs(client_game.enemies[1].pos.x - 7) < 0.05 end, step, 5)
    T.check(ok, "the client's copy follows the host's (x=" .. client_game.enemies[1].pos.x .. ")")

    host_e2.hp = 0 -- host kills enemy 2
    ok = T.wait_until(function() return client_game.enemies[2].alive == false end, step, 5)
    T.check(ok, "client's copy died when the host killed it")
    T.eq(client_game.kills, 1, "exactly one kill applied")
    for _ = 1, 50 do step() end
    T.eq(host_e1.hp, 60, "no damage echo after settling")
    T.eq(client_game.enemies[1].hp, 60, "both agree")
end)

T.run("hits_and_drops_end_to_end", function()
    -- The host shoots enemy 1: the client draws the shot.
    mock.hit(host_e1, 10, 15)
    local ok = T.wait_until(function() return #client.enemy_net:recent_partner_hits(re4coop_net.time(), 5) > 0 end, step, 5)
    T.check(ok, "the client saw the host's hit")
    ok = T.wait_until(function() return client_game.enemies[1].hp == 50 end, step, 5)
    T.check(ok, "and its HP")

    -- A lethal hit from the client never kills the puppet in the client's game: the host
    -- decides, and the client's copy dies from the host's death notice with the killing hit.
    client_game.drop_queue = { { enemy_id = 2, via = "hook" } } -- the client's own loot hooks work
    client_hit(1, 999, 3)
    T.eq(client_game.enemies[1].hp, 1, "the client's game left it alive")
    ok = T.wait_until(function() return host_e1.hp == 0 end, step, 5)
    T.check(ok, "the host's game killed it")
    ok = T.wait_until(function() return client_game.enemies[1].alive == false end, step, 5)
    T.check(ok, "and the client's copy died")
    local kh = client_game.enemies[1].killing_hit
    T.check(kh ~= nil and kh[1] ~= nil, "from the killing hit")
    -- Loot: the client's game did not roll for a death it did not run: it rolls its own.
    ok = T.wait_until(function() return #client_game.spawned > 0 end, step, 6)
    T.check(ok, "the client rolled its own loot for that enemy")
    T.eq(client_game.spawned[1] and client_game.spawned[1].enemy, 1, "from that enemy")
    for _ = 1, 50 do step() end
    T.eq(#client_game.spawned, 1, "exactly once")
end)

-- The host's enemies fight the client's character as a second player of the host's game.
T.run("the_hosts_enemies_see_and_attack_the_client_end_to_end", function()
    local model = partner_model()
    local ok = T.wait_until(function()
        return world.hit_controllers[model] ~= nil and mock.component(model, "chainsaw.TargetMarker") ~= nil
    end, step, 5)
    T.check(ok, "the client's model is a character of the host's game")
    -- What the enemies see: its body updater says which character it is - our stand-in.
    local upd = mock.component(model, "chainsaw.PlayerBodyUpdater")
    local ctx = upd.__fields["<Context>k__BackingField"]
    T.eq(ctx and ctx.__type, "chainsaw.ChCommonPlContext", "a player context of the host's game")
    T.eq(ctx and ctx.kind_id, 100000, "Leon (ch0_a0z0)")
    T.eq(ctx.__fields._BodyUpdater, upd, "whose body is the model")
    T.eq(model.tag, "Player|Character", "tagged like the host's player")
    local marker = mock.component(model, "chainsaw.TargetMarker")
    T.check(marker.enabled ~= false, "with a TargetMarker on")
    ok = T.wait_until(function() return (marker.registrations or 0) == 1 end, step, 3)
    T.check(ok, "registered once")
    ok = T.wait_until(function() return math.abs((ctx.__fields["<Position>k__BackingField"] or {}).x or 0) > 1 end, step, 3)
    T.near(ctx.__fields["<Position>k__BackingField"].x, client_game.player.pos.x, 0.5, "standing where the client is")

    -- A villager near the client, run by the host.
    local host_e4 = mock.make_character("chainsaw.Ch1c0z0Context", { x = 9, y = 0, z = 3 }, 100)
    world.enemies[#world.enemies + 1] = host_e4
    client_game.enemies[3] = { id = 3, kind = "chainsaw.Ch1c0z0Context", pos = { x = 9.1, y = 0, z = 3.1 }, yaw = 0,
        hp = 100, max_hp = 100, alive = true }
    ok = T.wait_until(function() return client_game.puppet[3] == true end, step, 5)
    T.check(ok, "the client's copy is a puppet of the host's")

    -- It goes after the client: the client knows.
    mock.target(host_e4, model)
    ok = T.wait_until(function() return client.enemy_net:summary().targeting_partner == 1 end, step, 5)
    T.check(ok, "the client is told an enemy is after it")

    -- Its attack lands on the model: the client takes the hit.
    T.eq(mock.enemy_attack(host_e4, model, 150, { attack_id = 1100, key = 0x77 }), true, "the hit landed in the host's game")
    ok = T.wait_until(function() return #client_game.host_hits == 1 end, step, 5)
    T.check(ok, "the client got the hit")
    local got = client_game.host_hits[1]
    T.eq(got and got.attacker, 3, "from its copy of that villager")
    T.eq(got and got.hit.attack_id, 1100, "with the attack's identity")
    T.eq(got and got.hit.key_hash, 0x77, "(its key)")
    local dmg
    for _, f in ipairs(got and got.hit.fields or {}) do
        if f.h == P.hash("Damage") then dmg = f.v end
    end
    T.eq(dmg, 150, "and its damage")
    T.eq(#(mock.component(model, "chainsaw.HitController").received or {}), 0, "the model itself took nothing")

    -- The host's own shots never reach the client, and pass its character: their contact is
    -- dropped before the game pools it (and decides the body stops the shot).
    local hm = world.singletons["chainsaw.HitManager"]
    local info = mock.new("chainsaw.HitController.DamageInfo", { data = { Damage = 30, AttackOwnerObject = world.player.body,
        AttackGameObject = world.player.body, DamageGameObject = model,
        AttackUserData = mock.new("chainsaw.collision.AttackUserData"),
        AttackData = mock.new("chainsaw.collision.AttackHitUserData.AttackData") } })
    hm:call("hitSetting", info, world.player.hit_controller, world.hit_controllers[model])
    T.eq(mock.contact(world.player.hit_controller, model), false, "the host's blow passes the client's character")
    local bullet = mock.make_go("bullet")
    local shell = mock.add_component(bullet, "chainsaw.ShellBase")
    shell.__fields["<AttackOwner>k__BackingField"] = world.player.body
    T.eq(mock.contact(mock.add_component(bullet, "chainsaw.HitController"), model), false, "and so does the host's bullet")
    T.eq(mock.contact(mock.component(host_e4.body, "chainsaw.HitController"), model), true, "an enemy's blow still lands")
    T.eq(mock.contact(world.player.hit_controller, host_e4.body), true, "and the host's on enemies")
    run_for(0.5)
    T.eq(#client_game.host_hits, 1, "no friendly fire")

    -- Its attack warns the client's character: the client's player gets the prompt.
    local body_upd = mock.enemy_body_updater(host_e4)
    body_upd.sign, body_upd.just = mock.sign_info({ sign = 0, distance = 3 }), true
    ok = T.wait_until(function() return #client_game.signs > 0 end, step, 5)
    T.check(ok, "the client got the warning")
    T.eq(client_game.signs[1] and client_game.signs[1].id, 3, "from its copy of that villager")
    T.eq(client_game.signs[1] and client_game.signs[1].m.just, true, "with its just-timing")
    body_upd.sign = nil
    -- The client parries its copy: the host's villager staggers, from the client's character.
    client_game.parry_queue = { { id = 3, kind = P.PARRY_KIND.PARRY, sign_type = 0, ok = true } }
    ok = T.wait_until(function() return #(world.parries or {}) > 0 end, step, 5)
    T.check(ok, "the host's villager was parried")
    T.eq(world.parries[1] and world.parries[1].body, body_upd, "that villager")
    T.eq(world.parries[1] and world.parries[1].by, model, "by the client's character")
    -- Its blow still on its way when the client parried is not taken.
    T.eq(mock.enemy_attack(host_e4, model, 80), true, "the blow landed in the host's game")
    run_for(0.5)
    T.eq(#client_game.host_hits, 1, "the parried blow is not taken")

    -- A boss aiming at "the player" itself goes for the client when its hate puts the client first.
    local atc = mock.add_component(host_e4.body, "chainsaw.ActionTargetController", { hate = host_e4.hate })
    atc:call("setTypeTarget(chainsaw.TargetType, via.GameObject)", 4, world.player.body)
    T.eq(atc.target, model, "the client's character")
    mock.target(host_e4, world.player.body)
    atc:call("setTypeTarget(chainsaw.TargetType, via.GameObject)", 4, world.player.body)
    T.eq(atc.target, world.player.body, "the host's player when the host is first")
    mock.target(host_e4, model)

    -- A grab: the villager holds the client's character until the client breaks free.
    run_for(1.2) -- past the parry's shield
    host_e4.head_updater:call("requestGrapple", model, 0x1234)
    T.eq(mock.enemy_attack(host_e4, model, 60, { grapple = true }), true, "a grab lands on the client")
    ok = T.wait_until(function() return #client_game.host_hits == 2 end, step, 5)
    T.check(ok, "the client got the grab")
    T.eq(client_game.host_hits[2] and client_game.host_hits[2].hit.grab, true, "as a grab")
    ok = T.wait_until(function() return client.partner_target.grab ~= nil end, step, 5)
    T.check(ok, "the client knows it is held")
    T.eq(client.partner_target.grab and client.partner_target.grab.id, 3, "by its copy of the villager")
    T.eq(client.partner_target.grab and client.partner_target.grab.action, 0x1234, "with the grab's action")
    local tree = mock.new("chainsaw.Ch1c0z0BehaviorTreeAction_CheckEscapeGrapple",
        { __fields = { NumberOfStruggles = 3, isEnableKnifeEscape = false } })
    local arg = mock.new("via.behaviortree.ActionArg", { owner = host_e4.body })
    tree:call("update", arg)
    ok = T.wait_until(function() return client.partner_target.grab and client.partner_target.grab.struggles == 3 end,
        step, 5)
    T.check(ok, "the presses the villager's escape check wants")
    client_game.grab_presses = 3
    ok = T.wait_until(function() return client.partner_target.grab == nil end, step, 5)
    T.check(ok, "the client broke free")
    T.eq(client_game.released[1] and client_game.released[1].id, 3, "let go by its copy")
    ok = T.wait_until(function()
        tree:call("update", arg)
        return tree.escaped == true
    end, step, 5)
    T.check(ok, "the host's villager's escape check succeeded")
    T.eq(arg.done, true, "and ended")
    T.eq(host_e4.__fields["<GrappleTarget>k__BackingField"], nil, "the villager let go")
    run_for(0.5)
    T.eq(#client_game.released, 1, "let go once")

    -- The client's noise: the host's enemies hear the model make it.
    local before = #world.noises
    client_game.noise_queue = { { pos = { x = 10, y = 0, z = 4 }, radius = 15, height = 3, volume = 0.9, sub = 0.4 } }
    ok = T.wait_until(function() return #world.noises > before end, step, 5)
    T.check(ok, "a sound registered in the host's game")
    local n = world.noises[#world.noises]
    T.eq(n and n.__fields["<OwnerGameObject>k__BackingField"], model, "made by the client's model")
    T.near(n and n.__fields.Volume or 0, 0.9, 1e-6, "as loud as in the client's game")

    -- Finishers: the host's villager says which it offers the client; the client's request runs
    -- on the host's villager with the client's character as the attacker.
    host_e4.fatal_ok, host_e4.fatal_type = true, 2
    ok = T.wait_until(function()
        local pinfo = client.enemy_net:partner_fatal(3)
        return pinfo ~= nil and (pinfo & P.PARTNER_INFO.FATAL) ~= 0
    end, step, 5)
    T.check(ok, "a kick is offered to the client")
    local _, ftype = client.enemy_net:partner_fatal(3)
    T.eq(ftype, 2, "a straight kick")
    local n0 = #world.head_fatals
    client_game.fatal_queue = { { id = 3, kind = P.FATAL_KIND.NORMAL, ftype = 2, pos = client_game.player.pos, yaw = 0 } }
    ok = T.wait_until(function() return #world.head_fatals > n0 end, step, 5)
    T.check(ok, "the host's villager got the request")
    local f = world.head_fatals[#world.head_fatals]
    T.eq(f and f.kind, "normal", "the kick")
    T.eq(f and f.ftype, 2, "its type")
    T.eq(f and f.target, host_e4, "on the host's villager")
    T.eq(f and f.attacker, ctx, "with the client's character as the attacker")
    T.eq(host_e4.head.update_self ~= false, true, "the host's game still runs it")
    client_game.fatal_queue = { { id = 3, kind = P.FATAL_KIND.STEALTH, ftype = 0, pos = client_game.player.pos, yaw = 0 } }
    ok = T.wait_until(function() return world.head_fatals[#world.head_fatals].kind == "stealth" end, step, 5)
    T.check(ok, "a stealth kill too")
    -- It kills the villager in the host's game: the client's copy dies, as the client's kill.
    host_e4.hp = 0
    ok = T.wait_until(function() return client_game.enemies[3].alive == false end, step, 5)
    T.check(ok, "dead for the client too")
    T.eq(client_game.enemies[3].killed_by, "self", "the client's own kill")
end)

T.run("invincibility_either_player_asks_for_covers_both", function()
    -- The client's Options turn it on: the client's game makes its player invincible, and the
    -- host's (the real adapter) its own, from the client's PLAYER flag.
    client_game.invincible_calls = {}
    function client_game:set_invincible(on)
        self.invincible_calls[#self.invincible_calls + 1] = on
        return on
    end
    client_settings.invincible = true
    local ok = T.wait_until(function() return world.player.invincible == true end, step, 5)
    T.check(ok, "the host's player is invincible")
    T.eq(world.player.no_damage, true, "takes no damage")
    T.eq(client_game.invincible_calls[#client_game.invincible_calls], true, "and the client's")
    client_settings.invincible = false
    ok = T.wait_until(function() return world.player.invincible ~= true end, step, 5)
    T.check(ok, "off for the host too")
    T.eq(client_game.invincible_calls[#client_game.invincible_calls], false, "and for the client")
    run_for(0.5)
    local n = #client_game.invincible_calls
    run_for(0.5)
    T.eq(#client_game.invincible_calls, n, "nothing more to do while off")
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
    mock.run_frame() -- queued from the UI...
    mock.run_frame() -- ...written on the game thread
    mock.run_frame() -- (and the UI shows the result)
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
    mock.run_frame()
    T.eq(re4coop_net.state(), "idle", "stop hosting")
    for _, cb in ipairs(mock.callbacks.config_save) do cb() end
    T.eq(mock.files["re4coop.json"].player_name, "HostLeon", "settings saved")
end)

T.finish()
