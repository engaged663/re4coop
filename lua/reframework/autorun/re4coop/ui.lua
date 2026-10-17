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
            local ash = status.ashley
            if ash ~= nil and ash.enabled and (ash.here or ash.partner_has) then
                local who = ash.mine and "you" or (status.partner_name or "your partner")
                local line = ("Ashley follows %s"):format(who)
                if ash.cooldown > 0 then line = line .. (" (can switch in %d s)"):format(math.ceil(ash.cooldown)) end
                imgui.text(line)
                imgui.same_line()
                if imgui.button(ash.mine and "Send Ashley to partner" or "Call Ashley to me") then
                    session:queue("ashley")
                end
                imgui.same_line()
                imgui.text_colored(("(or tap %s)"):format(status.ashley_key_name or "Alt"), COLOR_DIM)
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
            local who = session.role == "host" and "your game runs them" or "the host's game runs them"
            imgui.text(("Enemies: %d here, %d paired with the %s (%s), %d dead in the shared world"):format(
                e.local_count, e.paired, session.role == "host" and "client's" or "host's", who, e.dead_known or 0))
            if (e.targeting_partner or 0) > 0 then
                local whom = session.role == "host" and "your partner" or "you"
                imgui.text_colored(("%d enemies are after %s"):format(e.targeting_partner, whom), COLOR_WARN)
            end
        end
        if status.partner_target and session.role == "host" then
            local pt = status.partner_target
            imgui.text_colored(pt.attached and "Your partner is a target of your enemies (they see, hear and attack them)"
                or "Your partner is not a target of your enemies right now (not in your area, in a cutscene, or their model is not up)",
                pt.attached and COLOR_OK or COLOR_DIM)
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
        imgui.text_colored("Testing", COLOR_DIM)
        checkbox(settings, "invincible", "Invincibility: no player takes damage, is grabbed or dies (also your partner's, while connected)")

        imgui.separator()
        imgui.text_colored("Enemies and animals (the host's game runs every enemy; the client's shows them)", COLOR_DIM)
        checkbox(settings, "sync_enemies", "Sync enemies (every creature: villagers, dogs, bosses...)")
        checkbox(settings, "enemy_partner_target", "Host: your enemies see, hear, chase and attack your partner too (they are a second player in your game)")
        checkbox(settings, "enemy_partner_hits", "...and their attacks on your partner hurt them (client: you take the hits of the host's enemies)")
        checkbox(settings, "enemy_partner_noise", "...and they hear your partner's shots, steps and reloads")
        checkbox(settings, "enemy_partner_grabs", "...and may grab your partner (they break free in their own game)")
        checkbox(settings, "enemy_partner_parry", "...and warn your partner of their attacks, so your partner can parry them")
        checkbox(settings, "enemy_partner_bosses", "...and bosses go for your partner when your partner is the one they hate most")
        checkbox(settings, "enemy_mirror", "Client: the host's enemies stand and move where they are in the host's game")
        checkbox(settings, "enemy_motion_sync", "...and play their animation (also animals)")
        checkbox(settings, "enemy_anim_lock", "...with their own animation state machine switched off")
        slider_int(settings, "enemy_anim_layers", "...animation layers sent per enemy", 1, 3)
        checkbox(settings, "enemy_hit_predict", "Client: your hits on them take HP at once (the host still decides deaths)")
        checkbox(settings, "enemy_kill_with_hit", "Client: enemies the host's game kills die here from the same killing hit (crashed the game)")
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
        checkbox(settings, "gimmick_reactions", "Puzzles, locks and item slots the partner completes react in your game too (unlock, open, solve)")
        checkbox(settings, "sync_purposes", "Objectives: both players see the more advanced objective")
        checkbox(settings, "ashley_coop", "Ashley: one Ashley for both players (starts with the host; tap Alt to send her to the other player)")
        checkbox(settings, "ashley_single", "Ashley: remove any other Ashley that shows up (in both games)")
        checkbox(settings, "give_items", "'Give to partner' in the attache case's item commands")
        checkbox(settings, "sync_objects", "Breakables and animal deaths (crates, barrels, crows...)")
        checkbox(settings, "sync_object_states", "Experimental: other state changes of those objects")

        imgui.separator()
        imgui.text_colored("Joining and travelling", COLOR_DIM)
        checkbox(settings, "auto_travel", "Client: on joining, go to the host's chapter and area")
        checkbox(settings, "follow_host_chapter", "Client: follow the host into the next chapter")
        checkbox(settings, "auto_load_on_join", "Client: joining a host who plays loads straight into the host's place (co-op save, else your latest, else a new game)")
        checkbox(settings, "join_reload", "Client: in game, a host in another chapter or area is reached through the game's own Load Game")

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
        checkbox(settings, "fix_black_screen", "Bring the picture back if the screen stays black after a chapter change or cutscene")

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
            imgui.text(("enemy sync (host authority): %d of %d enemies here have a level ID | pairs by ID %d, by position %d | numbered for the client %d, retired %d"):format(
                en.with_uid or 0, en.local_count or 0, c.uid_pairs, c.spatial_pairs, c.assigned, c.retired))
            imgui.text(("enemy finishers of the client: sent %d (unpaired %d), received %d, run %d, refused %d | enemies asked about the client %d, after the client now %d"):format(
                c.fatals_sent, c.fatals_unpaired, c.fatals_received, c.fatals_applied, c.fatals_failed, c.partner_info,
                en.targeting_partner or 0))
            imgui.text(("enemy states: sent %d, received %d | puppets %d, held %d | moves %d, animations %d, switches %d, placed %d"):format(
                c.states_sent, c.states_received, en.puppets or 0, en.held or 0, c.moves, c.anims, c.puppet_switches,
                c.placed or 0))
            imgui.text(("enemy hits: forwarded %d, shown %d, received %d, run %d, as HP %d, unmatched %d, other damage %d | HP set %d, failed %d"):format(
                c.hits_forwarded, c.hits_sent, c.hits_received, c.hits_applied, c.hits_fallback,
                c.hits_unmatched, c.damage_reported, c.hp_applied, c.hp_failed))
            imgui.text(("enemy deaths: %d dead in the shared world%s | sent %d (client's kills %d), received %d, killed here %d, erased %d, late %d | lists sent %d, received %d"):format(
                en.dead_known or 0, en.listing_dead and " (reading the save...)" or "", c.deaths_sent, c.client_kills,
                c.deaths_received, c.kills_applied, c.erased, c.late_kills, c.graves_sent, c.graves_received))
        end
        if session_status and session_status.partner_target then
            local pt = session_status.partner_target
            local c = pt.counters
            local g = pt.game or {}
            if pt.role == "host" then
                imgui.text(("client as a target: %s | attached %d, failed %d, released %d, model lost %d | noises received %d, made %d (failed %d)"):format(
                    pt.attached and "ON" or "off", c.attaches, c.attach_failed, c.detaches, g.lost or 0,
                    c.noises_received, g.noises_applied or 0, g.noise_failed or 0))
                imgui.text(("hits on the client's model: %d seen, %d sent to the client (not by an enemy %d, ours %d, grabs blocked %d) | finishers run %d, refused %d"):format(
                    g.hits_seen or 0, c.hits_sent, g.not_enemy or 0, g.friendly or 0, g.grabs_blocked or 0,
                    g.fatals_run or 0, g.fatals_refused or 0))
                imgui.text(("our shots past the client %d | warnings for the client %d, sent %d | parries of the client: received %d, run %d, failed %d (presses %d)"):format(
                    g.shots_passed or 0, g.signs or 0, c.signs_sent, c.parries_received, g.parries_run or 0,
                    c.parries_failed, g.parry_inputs or 0))
                imgui.text(("grabs on the client %d, holds sent %d, ended %d, timed out %d | escapes received %d, by the escape check %d, forced %d | boss targets turned to the client %d"):format(
                    g.grabs or 0, c.grabs_sent, c.holds_ended, c.holds_timed_out, c.escapes_received,
                    g.releases or 0, g.releases_forced or 0, g.boss_redirects or 0))
            else
                imgui.text(("our player for the host's enemies: noises heard %d, sent %d (merged %d) | finisher checks %d, requests %d"):format(
                    g.noises_heard or 0, c.noises_sent, c.noises_merged, g.prompts or 0, g.requests or 0))
                imgui.text(("hits from the host's enemies: received %d, taken %d, blocked (dodged) %d, failed %d, dropped %d | exact attack data %d"):format(
                    c.hits_received, c.hits_applied, c.hits_blocked, c.hits_failed, c.hits_dropped, g.exact_attacks or 0))
                imgui.text(("warnings from the host's enemies: received %d, shown %d | our parries %d (landed %d), sent %d | hits parried %d"):format(
                    c.signs_received, c.signs_shown, g.player_parries or 0, g.player_parried or 0, c.parries_sent,
                    c.hits_parried))
                imgui.text(("held by the host's enemies: holds %d, grabs run %d (failed %d) | escapes %d, let go %d%s"):format(
                    c.grabs_received, g.player_grabs or 0, g.player_grab_failed or 0, c.escapes_sent,
                    g.player_released or 0, pt.grab and (" | HELD %d/%d"):format(pt.grab.presses, pt.grab.struggles) or ""))
            end
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
            if summary.last_missing then text = text .. (" | last motion not found here: %s"):format(summary.last_missing) end
            if summary.skips_waiting then text = text .. (" | %d partner skips wait for their cutscene"):format(summary.skips_waiting) end
            imgui.text(text)
        end
        if session_status then
            sync_line("flags", session_status.flags)
            sync_line("cutscenes", session_status.cutscenes)
            sync_line("event triggers", session_status.triggers)
            if session_status.world_events then
                local we = session_status.world_events
                imgui.text(("seen in our game: flag changes %d, cutscenes %d (asked again for the partner's, dropped: %d), skips %d, event triggers %d (other triggers %d%s)"):format(
                    we.flag_events or 0, we.cutscene_events or 0, we.cutscene_repeats or 0, we.skip_events or 0, we.trigger_events or 0,
                    we.trigger_not_event or 0,
                    session_status.world_last_not_event and (", last: " .. session_status.world_last_not_event) or ""))
                imgui.text(("partner gimmick states applied here: %d (%d wait for their area), %d reacted live, %d partner effects muted"):format(
                    we.gimmicks_applied or 0, we.gimmicks_waiting or 0, we.gimmick_reactions or 0, we.muted_effects or 0))
            end
            sync_line("gimmicks", session_status.gimmicks)
            sync_line("doors", session_status.doors)
            sync_line("traps", session_status.traps)
            sync_line("mechanisms", session_status.mechanisms)
            sync_line("objectives", session_status.purposes)
            sync_line("ashley", session_status.ashley)
            sync_line("items given", session_status.gives)
            if session_status.saves then
                local sv = session_status.saves
                local c, g = sv.counters, sv.game or {}
                imgui.text(("saves: ours %d (autosaves to slot %d: %d), sent %d | partner's %d -> saved here %d, already saved %d, gave up %d%s | join loads %d (co-op save used %d, menu asked %d)"):format(
                    c.own, sv.coop_slot or 0, c.redirected, c.sent, c.received, c.mirrored, c.same, c.given_up,
                    (sv.queued or 0) > 0 and " | 1 waiting" or "", c.join_loads, g.continue_swaps or 0, g.intents or 0))
            end
            if session_status.lobby then
                local lb = session_status.lobby
                local c = lb.counters
                local s = lb.start
                imgui.text(("lobby: screen %s, menu %s | starts %d, together %d (skipped %d), failed %d, loadouts given %d%s"):format(
                    tostring(lb.screen or "-"), tostring(lb.menu_mode), c.starts, c.released, c.skipped, c.failed, c.loadouts,
                    s and (" | start %d: ours %s, partner's %s%s"):format(s.id, P.LOAD_PHASE and tostring(s.phase) or "?",
                        tostring(s.partner_phase), s.released and (" (" .. tostring(s.why) .. ")") or "") or ""))
            end
            local mc = game.menu and game.menu.counters
            if mc then
                imgui.text(("main menu: opened %d, lists %d, labels written %d, our entries chosen %d, input held %d frames, back %d"):format(
                    mc.setups, mc.built, mc.texts, mc.decided, mc.blocked, mc.cancels))
            end
            sync_line("objects", session_status.objects)
            if session_status.travel then
                imgui.text(("travel: %s (%s)"):format(session_status.travel.state, tostring(session_status.travel.result or "-")))
            end
            local jn = session_status.join
            if jn then
                local last, load = jn.spawn_last, jn.ingame_load
                imgui.text(("join at the host's place: %s; last %s; in-game load %s; host seen at %s"):format(
                    jn.spawn_armed and "armed" or "-",
                    last and ("%s%d moved%s"):format(
                        last.kind == "chapter start" and ("chapter %s start: "):format(tostring(last.chapter)) or "",
                        last.moved or 0, last.why and (" (" .. tostring(last.why) .. ")") or "") or "-",
                    load and ("slot %s %s%s"):format(tostring(load.slot), tostring(load.phase),
                        load.why and (" (" .. tostring(load.why) .. ")") or "") or "-",
                    jn.host_spot and ("chapter %s stage %s"):format(tostring(jn.host_spot.chapter), tostring(jn.host_spot.stage)) or "-"))
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
        if session_status and session_status.screen then
            local sc = session_status.screen
            imgui.text(("game transitions: %s | %d so far, last %s s, %d over 45 s (%s) | black screens lifted: %d"):format(
                sc.transition_for and ("in one for %.0f s"):format(sc.transition_for) or "playing",
                sc.counters.transitions, sc.last_transition_length and ("%.1f"):format(sc.last_transition_length) or "-",
                sc.counters.long_transitions, tostring(sc.last_detail or "-"), sc.counters.lifts))
            imgui.text(("skipped cutscenes watched: %d | black after a skip, brought back: %d (%s)"):format(
                sc.counters.skips_watched or 0, sc.counters.skip_rescues or 0, tostring(sc.last_rescue or "-")))
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
                travel = session_status.travel, join = session_status.join, pause = session_status.pause,
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
