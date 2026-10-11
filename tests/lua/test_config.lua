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
    local files = { [Config.FILE] = { port = 99999, player_name = "", player_hz = 500, last_address = "10.0.0.5",
        sync_hp = "yes", unknown_key = 1 } }
    local cfg = Config.load(fake_json(files))
    T.eq(cfg.port, Config.DEFAULTS.port, "invalid port replaced")
    T.eq(cfg.player_name, "Player", "empty name replaced")
    T.eq(cfg.player_hz, 60, "rate clamped")
    T.eq(cfg.last_address, "10.0.0.5", "address kept")
    T.eq(cfg.sync_hp, true, "wrong type ignored")
    T.eq(cfg.unknown_key, nil, "unknown keys dropped")
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

T.run("broken_json_falls_back_to_defaults", function()
    local cfg = Config.load({ load_file = function() error("corrupt file") end })
    T.eq(cfg.port, Config.DEFAULTS.port, "defaults")
end)

T.finish()
