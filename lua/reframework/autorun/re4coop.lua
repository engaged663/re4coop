-- RE4 (2023) LAN co-op - entry point loaded by REFramework from reframework/autorun.
--
-- Requires reframework/plugins/re4coop_net.dll (provides the `re4coop_net` UDP API).
-- Open the REFramework menu (Insert) -> "RE4 Co-op (LAN)" to host or join.

local function log_info(msg)
    if log and log.info then log.info("[re4coop] " .. msg) end
end

if tostring(reframework:get_game_name()):lower() ~= "re4" then
    log_info("not RE4, co-op script disabled")
    return
end

if re4coop_net == nil then
    re.on_draw_ui(function()
        if imgui.tree_node("RE4 Co-op (LAN)") then
            imgui.text_colored("re4coop_net.dll is not loaded.", 0xFF6060FF)
            imgui.text("Copy re4coop_net.dll into <RE4 folder>/reframework/plugins/ and restart the game.")
            imgui.text("Check reframework/re2_framework_log.txt or the Plugins tab for load errors.")
            imgui.tree_pop()
        end
    end)
    log_info("re4coop_net plugin missing")
    return
end

local Config = require("re4coop.config")
local Game = require("re4coop.game")
local Session = require("re4coop.session")
local Puppet = require("re4coop.puppet")
local Overlay = require("re4coop.overlay")
local UI = require("re4coop.ui")
local P = require("re4coop.protocol")

local settings = Config.load(json)
local game = Game.new(log_info, re4coop_net.time)
local session = Session.new({
    net = re4coop_net,
    game = game,
    clock = re4coop_net.time,
    settings = settings,
    log = log_info,
})
local puppet = Puppet.new(game, log_info)

local last_game_tick = -math.huge
local reported_error = {}

local function report_once(where, err)
    local key = where .. tostring(err)
    if not reported_error[key] then
        reported_error[key] = true
        log_info(("error in %s: %s"):format(where, tostring(err)))
        session:add_message(("re4coop error in %s (see log)"):format(where), "error")
    end
end

-- The partner's character: built from their body prefab, posed from their POSE stream,
-- replaying their sounds, effects and shots.
local function update_partner(now)
    if not settings.show_partner then
        if puppet.state ~= "idle" then puppet:destroy() end
        session:take_partner_events(now) -- drop them, the model is off
        return
    end
    local st = session:partner_avatar(now)
    local hidden = session:partner_elsewhere()
    if settings.hide_partner_in_cutscenes and not hidden then
        local cut = P.POSE_FLAGS.CUTSCENE
        hidden = (st ~= nil and st.pose ~= nil and (st.pose.flags & cut) ~= 0) or game:is_cutscene()
    end
    puppet:update(now, st, { hidden = hidden, meshes_only = settings.partner_meshes_only })
    puppet:replay(session:take_partner_events(now), {
        audio = settings.partner_audio, effects = settings.partner_effects,
    })
end

-- Game thread: networking, reading the player, enemy sync, the partner's model. Runs after
-- behaviours have updated this frame so positions/HP are settled.
re.on_application_entry("LateUpdateBehavior", function()
    local now = re4coop_net.time()
    last_game_tick = now
    local ok, err = pcall(session.update, session)
    if not ok then report_once("update", err) end

    local ok2, err2 = pcall(update_partner, now)
    if not ok2 then report_once("partner model", err2) end
end)

-- End of the game frame, after animation, IK and physics: read our final pose for the
-- partner, and make sure the partner's model shows the pose we gave it.
re.on_application_entry("PrepareRendering", function()
    local ok, err = pcall(game.capture_pose_late, game, re4coop_net.time())
    if not ok then report_once("pose capture", err) end
    local ok2, err2 = pcall(puppet.late_update, puppet)
    if not ok2 then report_once("partner pose", err2) end
end)

-- Render thread: only drawing, plus network service while the game loop is not ticking.
re.on_frame(function()
    local now = re4coop_net.time()
    if now - last_game_tick > 0.5 then
        local ok, err = pcall(session.update_network_only, session)
        if not ok then report_once("network", err) end
    end

    local state = session:partner_render_state()
    if state ~= nil and (settings.show_nametag or not puppet:is_visible()) then
        local status = session:status()
        local ok, err = pcall(Overlay.draw_partner, game, state, {
            name = status.partner_name,
            distance = status.partner_distance,
            show_nametag = settings.show_nametag,
            marker = not puppet:is_visible(),
        })
        if not ok then report_once("overlay", err) end
    end

    if settings.show_hud then
        local ok, err = pcall(Overlay.draw_hud, game, session:status(), session.messages, now,
            settings.show_partner and puppet:status() or nil)
        if not ok then report_once("hud", err) end
    end
end)

re.on_draw_ui(function()
    local ok, err = pcall(UI.draw, session, game, settings, json, puppet)
    if not ok then report_once("ui", err) end
end)

re.on_config_save(function()
    Config.save(json, settings)
end)

re.on_script_reset(function()
    -- Keep the network session alive across script reloads (the plugin owns it); just
    -- remove anything we spawned into the world.
    pcall(puppet.shutdown, puppet)
    Config.save(json, settings)
end)

log_info("loaded (mod " .. P.MOD_VERSION .. ")")
