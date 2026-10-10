-- RE4 (2023) LAN co-op - entry point loaded by REFramework from reframework/autorun.
--
-- Requires reframework/plugins/re4coop_net.dll (provides the `re4coop_net` UDP API).
-- Open the REFramework menu (Insert) -> "RE4 Co-op (LAN)" to host or join.

local function log_info(msg)
    if log and log.info then log.info("[re4coop] " .. msg) end
end

if reframework:get_game_name() ~= "re4" then
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
local Ghost = require("re4coop.ghost")
local UI = require("re4coop.ui")

local settings = Config.load(json)
local game = Game.new(log_info)
local session = Session.new({
    net = re4coop_net,
    game = game,
    clock = re4coop_net.time,
    settings = settings,
    log = log_info,
})

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

-- Game thread: networking, reading the player, enemy sync, puppet. Runs after behaviours
-- have updated this frame so positions/HP are settled.
re.on_application_entry("LateUpdateBehavior", function()
    last_game_tick = re4coop_net.time()
    local ok, err = pcall(session.update, session)
    if not ok then report_once("update", err) end

    if settings.puppet_enabled then
        local state = session:partner_render_state()
        local ok2, err2 = pcall(game.update_puppet, game, true, settings.puppet_prefab, state)
        if not ok2 then report_once("puppet", err2) end
    elseif game.puppet ~= nil then
        pcall(game.destroy_puppet, game)
    end
end)

-- Render thread: only drawing, plus network service while the game loop is not ticking.
re.on_frame(function()
    local now = re4coop_net.time()
    if now - last_game_tick > 0.5 then
        local ok, err = pcall(session.update_network_only, session)
        if not ok then report_once("network", err) end
    end

    if settings.show_ghost then
        local state, parents = session:partner_render_state()
        if state ~= nil then
            local status = session:status()
            local ok, err = pcall(Ghost.draw, game, state, parents, {
                name = status.partner_name,
                color = settings.ghost_color,
                show_nametag = settings.show_nametag,
                distance = status.partner_distance,
            })
            if not ok then report_once("ghost", err) end
        end
    end

    if settings.show_hud then
        local ok, err = pcall(Ghost.draw_hud, game, session:status(), session.messages, now)
        if not ok then report_once("hud", err) end
    end
end)

re.on_draw_ui(function()
    local ok, err = pcall(UI.draw, session, game, settings, json)
    if not ok then report_once("ui", err) end
end)

re.on_config_save(function()
    Config.save(json, settings)
end)

re.on_script_reset(function()
    -- Keep the network session alive across script reloads (the plugin owns it); just
    -- remove anything we spawned into the world.
    pcall(game.destroy_puppet, game)
    Config.save(json, settings)
end)

log_info("loaded (mod " .. require("re4coop.protocol").MOD_VERSION .. ")")
