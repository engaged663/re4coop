-- Control panel inside the REFramework menu (press Insert in game): host/join, partner
-- status, chat, sync options and diagnostics.

local Config = require("re4coop.config")
local P = require("re4coop.protocol")

local UI = {}

local COLOR_OK = 0xFF60FF60
local COLOR_WARN = 0xFF40C0FF
local COLOR_ERR = 0xFF6060FF
local COLOR_DIM = 0xFFA0A0A0

local chat_draft = ""
local dump_result = nil

local function text_input(label, value)
    local changed, v = imgui.input_text(label, value, 0)
    if changed then return true, v end
    return false, value
end

local function checkbox(settings, key, label)
    local changed, v = imgui.checkbox(label, settings[key])
    if changed then settings[key] = v end
    return changed
end

local function slider_float(settings, key, label, lo, hi, fmt)
    local changed, v = imgui.slider_float(label, settings[key], lo, hi, fmt or "%.2f")
    if changed then settings[key] = v end
    return changed
end

local function slider_int(settings, key, label, lo, hi)
    local changed, v = imgui.slider_int(label, settings[key], lo, hi)
    if changed then settings[key] = v end
    return changed
end

local function draw_connection(session, settings, status)
    local idle = status.state == "idle"

    local changed
    changed, settings.player_name = text_input("Your name", settings.player_name)
    if idle then
        local port_changed, port = imgui.drag_int("Port (UDP)", settings.port, 1, 1, 65535)
        if port_changed then settings.port = port end
        changed, settings.password = text_input("Session password (optional)", settings.password)
        imgui.separator()

        if imgui.button("Host game") then
            Config.sanitize(settings)
            session:host()
        end
        imgui.same_line()
        imgui.text_colored("your partner joins with one of these addresses:", COLOR_DIM)
        local addrs = re4coop_net.local_addresses()
        if #addrs == 0 then
            imgui.text("  (no LAN address found - check your network connection)")
        end
        for _, a in ipairs(addrs) do
            imgui.text(("  %s:%d"):format(a, settings.port))
        end

        imgui.separator()
        changed, settings.last_address = text_input("Host IP (or IP:port)", settings.last_address)
        if imgui.button("Join game") then
            Config.sanitize(settings)
            session:join(settings.last_address)
        end
    else
        if imgui.button(status.role == "host" and "Stop hosting" or "Disconnect") then
            session:leave()
        end
    end

    if status.last_error and idle then
        imgui.text_colored("Last error: " .. tostring(status.last_error), COLOR_ERR)
    end
end

local function draw_status(session, status)
    local stats = status.stats
    if status.state == "connected" then
        imgui.text_colored(("Connected to %s (%s)"):format(status.partner_name or "?", stats.peer or "?"), COLOR_OK)
        imgui.text(("Ping %.0f ms  |  sent %d KB  |  received %d KB  |  resends %d"):format(
            stats.rtt_ms or 0, (stats.bytes_sent or 0) // 1024, (stats.bytes_recv or 0) // 1024, stats.resends or 0))
        if not status.compatible then
            imgui.text_colored("Partner runs an incompatible re4coop version - sync paused", COLOR_ERR)
        end
        if status.partner_pos then
            local hp = ""
            if status.partner_max_hp and status.partner_max_hp > 0 then
                hp = ("  |  HP %d/%d"):format(math.floor(status.partner_hp or 0), math.floor(status.partner_max_hp))
            end
            imgui.text(("Partner %.1f m away%s"):format(status.partner_distance or 0, hp))
            if status.left_behind ~= nil then
                imgui.text_colored(("You may be left behind - press %s or the button below"):format(
                    status.teleport_key_name or "F6"), COLOR_WARN)
            end
            if imgui.button("Teleport to partner") then
                session:teleport_to_partner()
            end
        else
            imgui.text_colored("Waiting for partner position (are they in game?)", COLOR_WARN)
        end
        if status.partner_area then
            imgui.text_colored("Partner chapter/area: " .. status.partner_area, COLOR_DIM)
        end
        if status.enemies then
            local e = status.enemies
            imgui.text(("Enemies: %d local, %d paired%s"):format(e.local_count, e.paired,
                e.role == "client" and (", %d from host"):format(e.remote_count) or ""))
        end
        if status.items and status.items.taken > 0 then
            local c = status.items.counters
            imgui.text(("Key items: %d taken by you, %d by partner"):format(c.taken_by_me, c.taken_by_partner))
        end
    elseif status.state == "listening" then
        imgui.text_colored(("Hosting on UDP port %d - waiting for partner..."):format(stats.local_port or 0), COLOR_WARN)
    elseif status.state == "connecting" then
        imgui.text_colored(("Connecting to %s ..."):format(stats.peer or "?"), COLOR_WARN)
    else
        imgui.text("Not connected")
    end
end

local function draw_chat(session, status)
    if status.state ~= "connected" then return end
    if imgui.tree_node("Chat & log") then
        local changed
        changed, chat_draft = text_input("Message", chat_draft)
        imgui.same_line()
        if imgui.button("Send") and chat_draft ~= "" then
            if session:send_chat(chat_draft) then chat_draft = "" end
        end
        for i = #session.messages, math.max(1, #session.messages - 15), -1 do
            local m = session.messages[i]
            local color = 0xFFFFFFFF
            if m.kind == "error" then color = COLOR_ERR elseif m.kind == "warn" then color = COLOR_WARN
            elseif m.kind == "good" then color = COLOR_OK end
            imgui.text_colored(m.text, color)
        end
        imgui.tree_pop()
    end
end

local function draw_options(settings)
    if imgui.tree_node("Options") then
        imgui.text_colored("Partner display", COLOR_DIM)
        checkbox(settings, "show_ghost", "Show partner ghost (skeleton)")
        checkbox(settings, "show_nametag", "Show name tag + HP bar")
        checkbox(settings, "show_hud", "Show status HUD (top-left)")
        local changed, color = imgui.color_edit("Ghost color", settings.ghost_color) -- ABGR, same as draw.*
        if changed then settings.ghost_color = color end

        imgui.separator()
        imgui.text_colored("Enemy sync (host is authoritative)", COLOR_DIM)
        checkbox(settings, "sync_enemies", "Sync enemies")
        checkbox(settings, "sync_hp", "Sync enemy HP / damage")
        checkbox(settings, "sync_deaths", "Sync enemy deaths")
        slider_float(settings, "match_radius", "Pairing radius (m)", 0.5, 10.0)
        slider_float(settings, "snap_distance", "Client: snap enemies further than (m, 0 = off)", 0.0, 20.0)

        imgui.separator()
        imgui.text_colored("Progression", COLOR_DIM)
        checkbox(settings, "share_key_items", "Key items exist once (partner's copy disappears when you take one)")
        checkbox(settings, "left_behind_prompt", "Offer a teleport when the partner is far away")
        slider_float(settings, "left_behind_distance", "Far-away distance (m)", 10.0, 200.0, "%.0f")
        slider_float(settings, "left_behind_seconds", "...for at least (s)", 1.0, 60.0, "%.0f")

        imgui.separator()
        imgui.text_colored("Network", COLOR_DIM)
        slider_int(settings, "player_hz", "Player updates per second", 5, 60)
        slider_int(settings, "snapshot_hz", "Enemy snapshots per second (host)", 2, 30)
        slider_float(settings, "interp_delay", "Interpolation delay (s)", 0.0, 0.5)

        imgui.separator()
        imgui.text_colored("Experimental", COLOR_DIM)
        checkbox(settings, "puppet_enabled", "Spawn a character model for the partner (may crash!)")
        local pchanged, path = text_input("Prefab path (.pfb)", settings.puppet_prefab)
        if pchanged then settings.puppet_prefab = path end
        imgui.tree_pop()
    end
end

local function draw_diagnostics(game, session_status)
    if imgui.tree_node("Diagnostics") then
        local version, proto = re4coop_net.version()
        imgui.text(("re4coop %s  |  plugin %s (net protocol %d)  |  game protocol %d"):format(
            P.MOD_VERSION, version, proto, P.VERSION))
        for name, cap in pairs(game:capabilities()) do
            imgui.text_colored(("%s %s: %s"):format(cap.ok and "[ok]" or "[--]", name, cap.detail), cap.ok and COLOR_OK or COLOR_WARN)
        end
        if session_status and session_status.enemies then
            local c = session_status.enemies.counters
            imgui.text(("enemy sync: damage sent %d, applied %d, failed %d | hp mirrored %d, failed %d | kills %d | id pairs %d"):format(
                c.damage_sent, c.damage_applied, c.damage_failed, c.hp_applied, c.hp_failed, c.kills_applied, c.id_matches))
        end
        if session_status and session_status.items then
            local c = session_status.items.counters
            imgui.text(("key items: tracked %d | taken by me %d, by partner %d | removed %d, remove failed %d"):format(
                session_status.items.tracked, c.taken_by_me, c.taken_by_partner, c.removed, c.remove_failed))
        end
        if imgui.button("Write research dump (reframework/data/re4coop_typedump.json)") then
            dump_result = game:dump_types() and "written - please send this file" or "failed (see REFramework log)"
        end
        if dump_result then
            imgui.same_line()
            imgui.text_colored(dump_result, COLOR_DIM)
        end
        imgui.tree_pop()
    end
end

function UI.draw(session, game, settings, json)
    if not imgui.tree_node("RE4 Co-op (LAN)") then return end
    local status = session:status()
    draw_status(session, status)
    imgui.separator()
    draw_connection(session, settings, status)
    imgui.separator()
    draw_chat(session, status)
    draw_options(settings)
    draw_diagnostics(game, status)
    if imgui.button("Save settings") then
        Config.sanitize(settings)
        Config.save(json, settings)
    end
    imgui.tree_pop()
end

return UI
