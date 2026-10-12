-- Control panel inside the REFramework menu (press Insert in game): host/join, partner
-- status, chat, sync options and diagnostics. This runs on the render thread: buttons that
-- change the game only queue the action (Session:queue); the game thread carries it out.

local Config = require("re4coop.config")
local P = require("re4coop.protocol")

local UI = {}

local COLOR_OK = 0xFF60FF60
local COLOR_WARN = 0xFF40C0FF
local COLOR_ERR = 0xFF6060FF
local COLOR_DIM = 0xFFA0A0A0

local chat_draft = ""

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
            session:queue("host")
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
            session:queue("join", settings.last_address)
        end
    else
        if imgui.button(status.role == "host" and "Stop hosting" or "Disconnect") then
            session:queue("leave")
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
                session:queue("teleport")
            end
            imgui.same_line()
            imgui.text_colored(("(or %s, any time)"):format(status.teleport_key_name or "F6"), COLOR_DIM)
            if session:can_travel() then
                imgui.same_line()
                if imgui.button("Travel to partner (loads their area or chapter)") then
                    session:queue("travel")
                end
            end
            local tr = status.travel
            if tr ~= nil and tr.state ~= "idle" then
                imgui.text_colored(("Travelling to partner (%s): %s"):format(tr.reason or "?", tr.state), COLOR_WARN)
            elseif tr ~= nil and tr.result ~= nil and tr.result ~= "arrived" then
                imgui.text_colored("Last travel: " .. tostring(tr.result), COLOR_DIM)
            end
            for _, w in ipairs(status.give_waiting or {}) do
                imgui.text_colored("Item waiting for your case (close it to receive): " .. w, COLOR_WARN)
            end
            if status.world_sync_pending then
                imgui.text_colored("Receiving the host's world state...", COLOR_WARN)
            end
        else
            imgui.text_colored("Waiting for partner position (are they in game?)", COLOR_WARN)
        end
        if status.partner_area then
            imgui.text_colored("Partner chapter/area: " .. status.partner_area, COLOR_DIM)
        end
        if status.partner_stage or status.local_stage then
            imgui.text_colored(("Stage: you %s, partner %s"):format(tostring(status.local_stage or "?"),
                tostring(status.partner_stage or "?")), COLOR_DIM)
        end
        if status.partner_character then
            imgui.text_colored("Partner character: " .. status.partner_character, COLOR_DIM)
        end
        if status.enemies then
            local e = status.enemies
            imgui.text(("Enemies: %d here, %d shared with your partner (your game runs %d, theirs %d), %d dead in the shared world"):format(
                e.local_count, e.paired, e.run_here or 0, e.run_by_partner or 0, e.dead_known or 0))
        end
        if status.animals and status.animals.role == "client" and status.animals.puppets > 0 then
            imgui.text_colored(("Animals: %d following the host's"):format(status.animals.puppets), COLOR_DIM)
        end
        if status.pause and status.pause.active then
            imgui.text_colored(("No-pause on: %d menu pauses keep the world running"):format(status.pause.patched or 0), COLOR_DIM)
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
        imgui.text_colored("Partner", COLOR_DIM)
        checkbox(settings, "show_partner", "Show partner's character (animated 3D model)")
        checkbox(settings, "partner_audio", "Partner sounds (gunshots, footsteps, reloads, voice)")
        checkbox(settings, "partner_effects", "Partner effects (muzzle flash)")
        checkbox(settings, "hide_partner_in_cutscenes", "Hide partner during cutscenes")
        checkbox(settings, "partner_meshes_only", "Build partner from meshes only (if the body prefab misbehaves)")
        checkbox(settings, "share_character", "Send my character to the partner")
        checkbox(settings, "show_nametag", "Show name tag + HP bar")
        checkbox(settings, "show_hud", "Show status HUD (top-left)")

        imgui.separator()
        imgui.text_colored("Enemies and animals (each enemy is run by one game; the other shows it)", COLOR_DIM)
        checkbox(settings, "sync_enemies", "Sync enemies (every creature: villagers, dogs, bosses...)")
        if imgui.button("Who runs enemies: " .. tostring(settings.enemy_authority)) then
            settings.enemy_authority = settings.enemy_authority == "shared" and "host" or "shared"
        end
        imgui.same_line()
        imgui.text_colored("shared = the closer player's game (enemies attack both), host = the host's game (host decides)", COLOR_DIM)
        checkbox(settings, "enemy_mirror", "Enemies your partner's game runs stand and move where theirs are")
        checkbox(settings, "enemy_motion_sync", "...and play their animation (also animals)")
        checkbox(settings, "enemy_anim_lock", "...with their own animation state machine switched off")
        slider_int(settings, "enemy_anim_layers", "...animation layers sent per enemy", 1, 3)
        checkbox(settings, "enemy_hit_predict", "Your hits on them take HP at once (the owner still decides deaths)")
        checkbox(settings, "enemy_kill_with_hit", "Enemies your partner kills die here from the same killing hit")
        checkbox(settings, "enemy_erase", "Enemies your partner already killed never appear in your game (no corpse)")
        checkbox(settings, "enemy_spawn_missing", "Client: enemies alive in the host's game appear in yours too (even if your save had them dead)")
        slider_float(settings, "enemy_interp_delay", "Enemy smoothing (seconds behind; higher = smoother, later)", 0.03, 0.4)
        checkbox(settings, "sync_drops", "Every enemy that dies gives each player their own loot (also your partner's kills)")
        checkbox(settings, "sync_animals", "Animals near the client (crows, chickens, fish...) move as in the host's game")

        imgui.separator()
        imgui.text_colored("Shared world", COLOR_DIM)
        checkbox(settings, "sync_flags", "Story progress: objectives, map, doors, items taken, events")
        checkbox(settings, "sync_cutscenes", "A cutscene one player's game starts plays for both")
        checkbox(settings, "cutscene_travel", "...and a partner who watched it from far away joins you afterwards")
        checkbox(settings, "sync_skips", "...and skipping it skips it for both")
        checkbox(settings, "sync_triggers", "A scripted event one player walks into also runs for the partner")
        checkbox(settings, "sync_gimmicks", "Doors, locks, levers, puzzles")
        checkbox(settings, "sync_doors", "Doors swing open and stay open in both games while either player is in them")
        checkbox(settings, "sync_traps", "Traps: a bear trap that snaps shut or a sensor bomb that goes off does so in both games")
        checkbox(settings, "sync_mechanisms", "Mechanisms: levers, big doors, valves, shelves, carts... move in both games, with their in-game camera")
        checkbox(settings, "give_items", "'Give to partner' in the attache case's item commands")
        checkbox(settings, "sync_objects", "Breakables and animal deaths (crates, barrels, crows...)")
        checkbox(settings, "sync_object_states", "Experimental: other state changes of those objects")

        imgui.separator()
        imgui.text_colored("Joining and travelling", COLOR_DIM)
        checkbox(settings, "auto_travel", "Client: on joining, go to the host's chapter and area")
        checkbox(settings, "follow_host_chapter", "Client: follow the host into the next chapter")
        checkbox(settings, "auto_load_on_join", "Client: joining from the title screen loads your co-op save (or your latest) at once")

        imgui.separator()
        imgui.text_colored("Saving", COLOR_DIM)
        checkbox(settings, "sync_saves", "When either game saves (autosave or typewriter), the partner's game saves too")
        slider_int(settings, "coop_save_slot", "Client: co-op save slot (your autosaves go there too while connected)", 1, 20)

        imgui.separator()
        imgui.text_colored("Pauses", COLOR_DIM)
        checkbox(settings, "no_pause", "While hosting or connected, menus and the inventory do not pause the game")
        if imgui.button("Mode: " .. tostring(settings.no_pause_mode)) then
            local order = { menus = "all", all = "off", off = "menus" }
            settings.no_pause_mode = order[settings.no_pause_mode] or "menus"
        end
        imgui.same_line()
        imgui.text_colored("menus = cutscenes and loading still pause, all = nothing pauses", COLOR_DIM)
        checkbox(settings, "no_pause_aggressive", "Also refuse pause requests (if a menu still pauses)")

        imgui.separator()
        imgui.text_colored("Progression", COLOR_DIM)
        checkbox(settings, "share_key_items", "Key items exist once (partner's copy disappears when you take one)")
        checkbox(settings, "left_behind_prompt", "Remind me of the teleport key when the partner is far away")
        slider_float(settings, "left_behind_distance", "Far-away distance (m)", 10.0, 200.0, "%.0f")
        slider_float(settings, "left_behind_seconds", "...for at least (s)", 1.0, 60.0, "%.0f")
        checkbox(settings, "transition_gate", "Wait for the partner at cutscenes and chapter changes (F8 skips)")
        slider_float(settings, "gate_grace", "...only events longer than (s)", 0.2, 10.0, "%.1f")
        slider_float(settings, "gate_radius", "...partner counts as arrived within (m)", 3.0, 50.0, "%.0f")

        imgui.separator()
        imgui.text_colored("Network", COLOR_DIM)
        slider_int(settings, "player_hz", "Player updates per second", 5, 60)
        slider_int(settings, "pose_hz", "Character pose updates per second", 10, 60)
        slider_int(settings, "snapshot_hz", "Enemy states per second (the enemies your game runs)", 2, 30)
        slider_float(settings, "interp_delay", "Interpolation delay (s)", 0.0, 0.5)

        imgui.separator()
        imgui.text_colored("Diagnostics", COLOR_DIM)
        checkbox(settings, "profiler", "Measure the mod's cost per frame (Diagnostics > Performance)")
        checkbox(settings, "perf_file", "...and write it to reframework/data/re4coop_perf.json")

        imgui.separator()
        imgui.text_colored("Experimental (may crash the game - off by default)", COLOR_WARN)
        checkbox(settings, "stage_travel", "Teleports to another area preload it and use the game's warp")
        checkbox(settings, "travel_reload", "Load the partner's chapter automatically (game over -> Continue)")
        checkbox(settings, "exp_force_routine", "Break objects by forcing their state machine")
        checkbox(settings, "enemy_replay_mutilation", "Your partner's hits and kills also burst heads and break limbs in your game (crashed the game)")
        imgui.tree_pop()
    end
end

local function counters_text(c)
    local keys = {}
    for k in pairs(c or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = ("%s %s"):format(k, tostring(c[k])) end
    return table.concat(parts, ", ")
end

local function draw_models(status, game, puppet)
    local desc = game.avatar
    if desc ~= nil then
        imgui.text(("Your character: %s, %d parts, %d animated joints"):format(desc.char_id, #desc.parts, #desc.joints))
    else
        imgui.text_colored("Your character: not in game", COLOR_DIM)
    end
    imgui.text_colored("Sent: " .. counters_text(status.avatar_tx), COLOR_DIM)
    imgui.text_colored("Received: " .. counters_text(status.avatar_rx), COLOR_DIM)
    if puppet ~= nil then
        local p = puppet:status()
        local color = p.state == "ready" and COLOR_OK or (p.state == "failed" and COLOR_ERR or COLOR_WARN)
        imgui.text_colored(("Partner model: %s%s%s"):format(p.state, p.mode and (" (" .. p.mode .. ")") or "",
            p.char_id and (" - " .. p.char_id) or ""), color)
        if p.detail then imgui.text_colored("  " .. p.detail, COLOR_DIM) end
        if p.state == "ready" then
            imgui.text(("  %d parts, %d/%d joints animated%s"):format(p.parts, p.joints_mapped, p.joints_total,
                p.late_writes and ", pose written after animation" or ""))
            if #p.weapons > 0 then imgui.text("  weapons: " .. table.concat(p.weapons, ", ")) end
        end
        imgui.text_colored("  " .. counters_text(p.counters), COLOR_DIM)
    end
end

local function draw_performance(perf, game)
    local r = perf and perf:summary()
    if r == nil then
        imgui.text_colored("Performance: measuring... (enable it under Options > Diagnostics)", COLOR_DIM)
        return
    end
    local color = (r.frame_avg_ms > 2.0 or r.frame_max_ms > 8.0) and COLOR_WARN or COLOR_OK
    imgui.text_colored(("Performance: %.2f ms per frame on average, worst frame %.2f ms, %d frames over 4 ms in the last second, %.0f fps"):format(
        r.frame_avg_ms, r.frame_max_ms, r.spikes, r.fps), color)
    if r.game_calls_per_s then
        imgui.text_colored(("  %.0f engine calls per second through the adapter"):format(r.game_calls_per_s), COLOR_DIM)
    end
    for i = 1, math.min(#r.spans, 10) do
        local sp = r.spans[i]
        imgui.text_colored(("  %-18s %6.3f ms avg  %6.3f ms max  %5.1f calls/frame"):format(sp.name, sp.avg_ms, sp.max_ms, sp.calls),
            COLOR_DIM)
    end
    imgui.text_colored("  after a crash, send reframework/data/re4coop_breadcrumb.json (what the mod did last)", COLOR_DIM)
end

local function draw_diagnostics(session, game, session_status, puppet, perf)
    if imgui.tree_node("Diagnostics") then
        draw_performance(perf, game)
        imgui.separator()
        local version, proto = re4coop_net.version()
        imgui.text(("re4coop %s  |  plugin %s (net protocol %d)  |  game protocol %d"):format(
            P.MOD_VERSION, version, proto, P.VERSION))
        local names = {}
        for name in pairs(game:capabilities()) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local cap = game:capabilities()[name]
            imgui.text_colored(("%s %s: %s"):format(cap.ok and "[ok]" or "[--]", name, cap.detail), cap.ok and COLOR_OK or COLOR_WARN)
        end
        if session_status and session_status.enemies then
            local en = session_status.enemies
            local c = en.counters
            imgui.text(("enemy sync (%s authority): %d of %d enemies here have a level ID | pairs by ID %d, by position %d"):format(
                en.authority or "?", en.with_uid or 0, en.local_count or 0, c.uid_pairs, c.spatial_pairs))
            imgui.text(("enemy owners: %d run here, %d by the partner | changes %d, taken over %d, handed over %d, retired %d"):format(
                en.run_here or 0, en.run_by_partner or 0, c.owner_changes, c.taken_over, c.handed_over, c.retired))
            imgui.text(("enemy finishers: ours %d | claims sent %d, granted %d, refused %d"):format(
                c.fatals or 0, c.claims_sent or 0, c.claims_granted or 0, c.claims_refused or 0))
            imgui.text(("enemy states: sent %d, received %d | puppets %d, held %d | moves %d, animations %d, switches %d"):format(
                c.states_sent, c.states_received, en.puppets or 0, en.held or 0, c.moves, c.anims, c.puppet_switches))
            imgui.text(("enemy hits: forwarded %d, shown %d, received %d, run %d, as HP %d, bounced %d, unmatched %d, other damage %d | HP set %d, failed %d"):format(
                c.hits_forwarded, c.hits_sent, c.hits_received, c.hits_applied, c.hits_fallback, c.hits_bounced,
                c.hits_unmatched, c.damage_reported, c.hp_applied, c.hp_failed))
            imgui.text(("enemy deaths: %d dead in the shared world%s | sent %d, received %d, killed here %d, erased %d, late %d | lists sent %d, received %d"):format(
                en.dead_known or 0, en.listing_dead and " (reading the save...)" or "", c.deaths_sent, c.deaths_received,
                c.kills_applied, c.erased, c.late_kills, c.graves_sent, c.graves_received))
        end
        if session_status and session_status.animals then
            local an = session_status.animals
            local c = an.counters
            imgui.text(("animals: %s | %d at the host, %d following | sent %d, received %d, moves %d, animations %d, deaths applied %d, reported %d"):format(
                an.role, an.remote, an.puppets, c.sent, c.received, c.moves, c.motions, c.kills_applied, c.kills_reported))
        end
        local function sync_line(label, summary)
            if summary == nil then return end
            local text = label .. ": " .. counters_text(summary.counters)
            if summary.muted_now and summary.muted_now > 0 then text = text .. (" | muted %d"):format(summary.muted_now) end
            if summary.queued and summary.queued > 0 then text = text .. (" | queued %d"):format(summary.queued) end
            if summary.destroyed_known then text = text .. (" | known destroyed %d"):format(summary.destroyed_known) end
            if summary.pending then text = text .. (" | waiting for cutscene %s"):format(tostring(summary.pending)) end
            if summary.replaying then text = text .. (" | playing partner's cutscene %s"):format(tostring(summary.replaying)) end
            if summary.holding then text = text .. (" | %d partner flags wait for the cutscene"):format(summary.holding) end
            if summary.skips_waiting then text = text .. (" | %d partner skips wait for their cutscene"):format(summary.skips_waiting) end
            imgui.text(text)
        end
        if session_status then
            sync_line("flags", session_status.flags)
            sync_line("cutscenes", session_status.cutscenes)
            sync_line("event triggers", session_status.triggers)
            if session_status.world_events then
                local we = session_status.world_events
                imgui.text(("seen in our game: flag changes %d, cutscenes %d, skips %d, event triggers %d (other triggers %d%s)"):format(
                    we.flag_events or 0, we.cutscene_events or 0, we.skip_events or 0, we.trigger_events or 0,
                    we.trigger_not_event or 0,
                    session_status.world_last_not_event and (", last: " .. session_status.world_last_not_event) or ""))
                imgui.text(("partner gimmick states applied here: %d (%d wait for their area)"):format(
                    we.gimmicks_applied or 0, we.gimmicks_waiting or 0))
            end
            sync_line("gimmicks", session_status.gimmicks)
            sync_line("doors", session_status.doors)
            sync_line("traps", session_status.traps)
            sync_line("mechanisms", session_status.mechanisms)
            sync_line("items given", session_status.gives)
            if session_status.saves then
                local sv = session_status.saves
                local c, g = sv.counters, sv.game or {}
                imgui.text(("saves: ours %d (autosaves to slot %d: %d), sent %d | partner's %d -> saved here %d, already saved %d, gave up %d%s | join loads %d (co-op save used %d, menu asked %d)"):format(
                    c.own, sv.coop_slot or 0, c.redirected, c.sent, c.received, c.mirrored, c.same, c.given_up,
                    (sv.queued or 0) > 0 and " | 1 waiting" or "", c.join_loads, g.continue_swaps or 0, g.intents or 0))
            end
            sync_line("objects", session_status.objects)
            if session_status.travel then
                imgui.text(("travel: %s (%s)"):format(session_status.travel.state, tostring(session_status.travel.result or "-")))
            end
            if session_status.pause then
                local pz = session_status.pause
                imgui.text(("no-pause: %s, mode %s, %d pause types neutralised, %d requests refused"):format(
                    pz.active and "on" or "off", tostring(pz.mode), pz.patched or 0, pz.blocked or 0))
                if pz.names and #pz.names > 0 then
                    imgui.text_colored("  " .. table.concat(pz.names, ", "), COLOR_DIM)
                end
            end
        end
        if session_status and session_status.items then
            local c = session_status.items.counters
            imgui.text(("key items: tracked %d | taken by me %d, by partner %d | removed %d, remove failed %d"):format(
                session_status.items.tracked, c.taken_by_me, c.taken_by_partner, c.removed, c.remove_failed))
            imgui.text(("pickup detection: item flags %s, game callback %s | flag %d, callback %d, heuristic %d, unconfirmed %d, remove had no effect %d"):format(
                session_status.items.flags or "?", session_status.items.hook or "?", c.flag, c.confirmed, c.heuristic,
                c.unconfirmed_ignored, c.remove_ineffective))
            for _, e in ipairs(session_status.items.events or {}) do
                imgui.text_colored(("  %.1f s: %s"):format(e.t, e.text), COLOR_DIM)
            end
        end
        if session_status and session_status.drops then
            local c = session_status.drops.counters
            imgui.text(("loot: %s | game rolls %d (enemies %d), partner kills %d -> rolled by us %d, failed %d, gone %d, doubles %d, kinds without loot %d"):format(
                session_status.drops.state, c.rolls_seen, c.natural, c.partner_kills, c.requested, c.request_failed,
                c.gone, c.doubles, c.no_drop_kinds))
        end
        if session_status and session_status.gate then
            local g = session_status.gate
            imgui.text(("transition gate: %s | chapter you %s, partner %s | last release: %s"):format(
                g.holding and ("holding (" .. g.holding .. ")") or "open", tostring(session_status.local_chapter or "?"),
                tostring(session_status.partner_chapter or "?"), tostring(g.last_release or "-")))
        end
        imgui.separator()
        draw_models(session_status, game, puppet)
        if imgui.button("Write research dump (adds a run to reframework/data/)") then
            -- Built here, written on the game thread (it reads enemies, pickups and objects).
            local extra = session_status and {
                role = session_status.role, enemies = session_status.enemies, items = session_status.items,
                drops = session_status.drops, gate = session_status.gate,
                flags = session_status.flags, gimmicks = session_status.gimmicks, objects = session_status.objects,
                cutscenes = session_status.cutscenes, triggers = session_status.triggers,
                world_events = session_status.world_events, world_last_not_event = session_status.world_last_not_event,
                travel = session_status.travel, pause = session_status.pause,
                local_stage = session_status.local_stage, partner_stage = session_status.partner_stage,
                character_sent = session_status.avatar_tx, character_received = session_status.avatar_rx,
                partner_model = puppet and puppet:status() or nil,
                local_chapter = session_status.local_chapter, partner_chapter = session_status.partner_chapter,
            } or nil
            session.dump_result = "writing on the next game frame..."
            session:queue("dump", extra)
        end
        if session.dump_result then
            imgui.same_line()
            imgui.text_colored(session.dump_result, COLOR_DIM)
        end
        imgui.tree_pop()
    end
end

function UI.draw(session, game, settings, json, puppet, perf)
    if not imgui.tree_node("RE4 Co-op (LAN)") then return end
    local status = session.status_cached and session:status_cached() or session:status()
    draw_status(session, status)
    imgui.separator()
    draw_connection(session, settings, status)
    imgui.separator()
    draw_chat(session, status)
    draw_options(settings)
    draw_diagnostics(session, game, status, puppet, perf)
    if imgui.button("Save settings") then
        Config.sanitize(settings)
        Config.save(json, settings)
    end
    imgui.tree_pop()
end

return UI
