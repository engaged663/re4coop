local T = require("testlib")
local Config = require("re4coop.config")

local function fake_json(files)
    return {
        load_file = function(name) return files[name] end,
        dump_file = function(name, t) files[name] = t return true end,
    }
end

T.run("defaults_without_file", function()
    local cfg = Config.load(fake_json({}))
    T.eq(cfg.port, Config.DEFAULTS.port, "port")
    T.eq(cfg.player_name, "Player", "name")
    T.eq(cfg.sync_enemies, true, "sync on by default")
    T.eq(cfg.show_partner, true, "partner's 3D character on by default")
    T.eq(cfg.partner_audio, true, "partner sounds on by default")
    T.eq(cfg.partner_effects, true, "partner effects on by default")
    T.eq(cfg.share_character, true, "our character is shared by default")
    T.eq(cfg.pose_hz, 30, "pose rate")
end)

T.run("settings_from_0_1_are_upgraded", function()
    local files = { [Config.FILE] = { player_name = "Leon", show_ghost = true, ghost_color = 123,
        puppet_enabled = true, puppet_prefab = "_chainsaw/x.pfb", pose_hz = 500 } }
    local cfg = Config.load(fake_json(files))
    T.eq(cfg.player_name, "Leon", "kept")
    T.eq(cfg.show_ghost, nil, "skeleton ghost setting gone")
    T.eq(cfg.puppet_prefab, nil, "manual prefab path gone")
    T.eq(cfg.puppet_enabled, nil, "experimental toggle gone")
    T.eq(cfg.pose_hz, 60, "pose rate clamped")
end)

T.run("loads_and_sanitizes_saved_values", function()
    local files = { [Config.FILE] = { config_version = Config.VERSION, port = 99999, player_name = "", player_hz = 500,
        last_address = "10.0.0.5", enemy_erase = "yes", enemy_interp_delay = 5, enemy_authority = "everyone",
        enemy_anim_layers = 9, roster_hz = 1000, unknown_key = 1 } }
    local cfg = Config.load(fake_json(files))
    T.eq(cfg.port, Config.DEFAULTS.port, "invalid port replaced")
    T.eq(cfg.player_name, "Player", "empty name replaced")
    T.eq(cfg.player_hz, 60, "rate clamped")
    T.eq(cfg.last_address, "10.0.0.5", "address kept")
    T.eq(cfg.enemy_erase, true, "wrong type ignored")
    T.near(cfg.enemy_interp_delay, 0.4, 1e-9, "enemy smoothing clamped")
    T.eq(cfg.enemy_authority, "shared", "unknown authority replaced")
    T.eq(cfg.enemy_anim_layers, 3, "animation layers clamped")
    T.eq(cfg.roster_hz, 20, "roster rate clamped")
    T.eq(cfg.unknown_key, nil, "unknown keys dropped")
end)

T.run("enemy_sync_settings_of_0_7_are_reset_once", function()
    -- 0.7's enemy sync was broken; players switched parts of it off. 0.8 rebuilt it around the
    -- host: those switches come back on once, and the options that could only break it (and
    -- 0.7's ownership switches: the host runs every enemy now) are gone.
    local files = { [Config.FILE] = { config_version = 7, sync_enemies = false, enemy_mirror = false,
        enemy_ownership = false, enemy_motion_sync = false, hit_ownership = false, sync_hp = false,
        sync_deaths = false, enemy_puppet_ai = false, match_radius = 8.0, snap_distance = 3.0, sync_drops = false,
        interp_delay = 0.12 } }
    local json = fake_json(files)
    local cfg = Config.load(json)
    for _, k in ipairs({ "sync_enemies", "enemy_mirror", "enemy_motion_sync" }) do
        T.eq(cfg[k], true, k .. " back on")
    end
    for _, k in ipairs({ "sync_hp", "sync_deaths", "enemy_puppet_ai", "match_radius", "snap_distance",
        "enemy_ownership", "hit_ownership" }) do
        T.eq(cfg[k], nil, k .. " removed")
    end
    T.eq(cfg.sync_drops, false, "an unrelated choice is kept")
    T.near(cfg.interp_delay, 0.12, 1e-9, "same for the 0.7-era rates")
    T.eq(cfg.enemy_erase, true, "dead enemies are erased by default")
    T.near(cfg.enemy_interp_delay, 0.1, 1e-9, "enemy smoothing default")
    cfg.enemy_mirror = false
    Config.save(json, cfg)
    T.eq(Config.load(json).enemy_mirror, false, "switched off again after the upgrade: kept")
end)

T.run("enemy_settings_of_0_8_are_reset_once_for_the_new_enemy_sync", function()
    -- 0.9 rebuilt enemy sync from scratch: switches turned off to work around 0.8 come back,
    -- and 0.8's options that no longer exist are dropped.
    local files = { [Config.FILE] = { config_version = 8, sync_enemies = false, enemy_mirror = false,
        enemy_motion_sync = false, snapshot_hz = 5, enemy_interp_delay = 0.3, enemy_host_only = false,
        client_enemy_hz = 10, replay_partner_hits = true, enemy_erase = false } }
    local cfg = Config.load(fake_json(files))
    for _, k in ipairs({ "sync_enemies", "enemy_mirror", "enemy_motion_sync" }) do
        T.eq(cfg[k], true, k .. " back on")
    end
    T.eq(cfg.snapshot_hz, 20, "state rate back to default")
    T.near(cfg.enemy_interp_delay, 0.1, 1e-9, "smoothing back to default")
    for _, k in ipairs({ "enemy_host_only", "client_enemy_hz", "replay_partner_hits" }) do
        T.eq(cfg[k], nil, k .. " removed")
    end
    T.eq(cfg.enemy_erase, false, "an unrelated choice is kept")
    T.eq(cfg.enemy_authority, "shared", "enemies are shared between the players by default")
    T.eq(cfg.enemy_hit_predict, true, "hits take HP at once by default")
end)

T.run("save_roundtrip", function()
    local files = {}
    local json = fake_json(files)
    local cfg = Config.load(json)
    cfg.player_name = "Ashley"
    cfg.port = 40000
    T.check(Config.save(json, cfg), "saved")
    local again = Config.load(json)
    T.eq(again.player_name, "Ashley", "name persisted")
    T.eq(again.port, 40000, "port persisted")
end)

T.run("unsafe_defaults_of_older_versions_are_reset_once", function()
    -- A 0.6 config saved every setting, including the old defaults that are now experimental.
    local files = { [Config.FILE] = { player_name = "Leon", sync_cutscenes = true,
        travel_reload = true, stage_travel = true, interp_delay = 0.1, snapshot_hz = 15, sync_flags = false } }
    local json = fake_json(files)
    local cfg = Config.load(json)
    T.eq(cfg.sync_cutscenes, false, "cutscene replay back to off")
    T.eq(cfg.travel_reload, false, "automatic reload back to off")
    T.eq(cfg.stage_travel, false, "stage warp back to off")
    T.near(cfg.interp_delay, 0.066, 1e-9, "new interpolation delay")
    T.eq(cfg.snapshot_hz, 20, "new snapshot rate")
    T.eq(cfg.sync_flags, false, "other choices kept")
    T.eq(cfg.player_name, "Leon", "name kept")
    T.eq(cfg.config_version, Config.VERSION, "upgraded")
    -- Switched back on by the player and saved: kept from then on.
    cfg.sync_cutscenes = true
    Config.save(json, cfg)
    T.eq(Config.load(json).sync_cutscenes, true, "the player's own choice sticks")
end)

T.run("experimental_features_are_off_by_default", function()
    local cfg = Config.load(fake_json({}))
    for _, k in ipairs({ "sync_cutscenes", "travel_reload", "stage_travel", "exp_table_reload",
        "exp_force_routine" }) do
        T.eq(cfg[k], false, k)
    end
    T.eq(cfg.hit_ownership, nil, "0.7's ownership switches are gone")
    T.eq(cfg.replay_partner_hits, nil, "the cosmetic hit replay is gone: partner hits run for real")
    T.eq(cfg.sync_animals, true, "animals follow the host")
    T.eq(cfg.sync_drops, true, "per-player loot on")
    T.eq(cfg.profiler, true, "profiler on")
end)

T.run("broken_json_falls_back_to_defaults", function()
    local cfg = Config.load({ load_file = function() error("corrupt file") end })
    T.eq(cfg.port, Config.DEFAULTS.port, "defaults")
end)

T.finish()
