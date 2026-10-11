-- Settings, persisted with REFramework's json API to reframework/data/re4coop.json.

local Config = {}

Config.FILE = "re4coop.json"

Config.DEFAULTS = {
    player_name = "Player",
    last_address = "192.168.1.",
    port = 33040,
    password = "",

    -- network rates
    player_hz = 20,
    pose_hz = 30,         -- partner model pose updates per second
    enemy_tick_hz = 20,
    snapshot_hz = 10,
    interp_delay = 0.10,

    -- enemy sync
    sync_enemies = true,
    sync_hp = true,
    sync_deaths = true,
    match_radius = 3.0,   -- metres between spawn points to treat two enemies as the same one
    snap_distance = 0.0,  -- client: teleport enemies further than this from the host's copy (0 = off)
    replay_partner_hits = true, -- enemies visibly react to the partner's hits (cosmetic replay)
    sync_drops = true,    -- enemies drop the same item for both players (the host's roll)

    -- progression
    share_key_items = true,       -- a key item exists once: the partner's copy disappears when you take it
    left_behind_prompt = true,    -- offer a teleport when the partner is far away for a while
    left_behind_distance = 35.0,  -- metres
    left_behind_seconds = 6.0,
    teleport_key = 0x75,          -- F6 (Windows virtual-key code): accept the teleport prompt
    snooze_key = 0x76,            -- F7: hide the prompt for 2 minutes
    transition_gate = true,       -- wait at cutscenes/chapter changes until the partner arrives
    gate_grace = 1.5,             -- seconds an event must last before it holds you (doors etc. don't)
    gate_radius = 10.0,           -- metres: a partner this close counts as arrived
    continue_key = 0x77,          -- F8: stop waiting and continue alone

    -- partner character
    show_partner = true,               -- the partner's animated 3D character, built from their body prefab
    partner_audio = true,              -- replay their sounds (gunshots, footsteps, reloads, voice) on the model
    partner_effects = true,            -- replay their muzzle flashes and other effects
    hide_partner_in_cutscenes = true,
    partner_meshes_only = false,       -- build the partner from meshes instead of their body prefab
    share_character = true,            -- send our character (prefab, costume, pose) to the partner
    show_nametag = true,
    show_hud = true,
}

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- json: REFramework's `json` table (load_file/dump_file) or a stand-in for tests.
function Config.load(json)
    local cfg = copy(Config.DEFAULTS)
    if json ~= nil then
        local ok, saved = pcall(json.load_file, Config.FILE)
        if ok and type(saved) == "table" then
            for k, default in pairs(Config.DEFAULTS) do
                local v = saved[k]
                if v ~= nil and type(v) == type(default) then
                    cfg[k] = v
                end
            end
        end
    end
    Config.sanitize(cfg)
    return cfg
end

function Config.sanitize(cfg)
    cfg.port = math.floor(tonumber(cfg.port) or Config.DEFAULTS.port)
    if cfg.port < 1 or cfg.port > 65535 then cfg.port = Config.DEFAULTS.port end
    cfg.player_name = tostring(cfg.player_name):sub(1, 32)
    if cfg.player_name == "" then cfg.player_name = Config.DEFAULTS.player_name end
    cfg.player_hz = math.max(5, math.min(60, cfg.player_hz))
    cfg.pose_hz = math.max(10, math.min(60, cfg.pose_hz))
    cfg.enemy_tick_hz = math.max(5, math.min(60, cfg.enemy_tick_hz))
    cfg.snapshot_hz = math.max(2, math.min(30, cfg.snapshot_hz))
    cfg.interp_delay = math.max(0.0, math.min(0.5, cfg.interp_delay))
    cfg.match_radius = math.max(0.5, math.min(20.0, cfg.match_radius))
    cfg.snap_distance = math.max(0.0, math.min(50.0, cfg.snap_distance))
    cfg.left_behind_distance = math.max(10.0, math.min(500.0, cfg.left_behind_distance))
    cfg.left_behind_seconds = math.max(1.0, math.min(120.0, cfg.left_behind_seconds))
    cfg.teleport_key = math.floor(cfg.teleport_key)
    cfg.snooze_key = math.floor(cfg.snooze_key)
    if cfg.teleport_key < 1 or cfg.teleport_key > 254 then cfg.teleport_key = Config.DEFAULTS.teleport_key end
    if cfg.snooze_key < 1 or cfg.snooze_key > 254 then cfg.snooze_key = Config.DEFAULTS.snooze_key end
    cfg.continue_key = math.floor(cfg.continue_key)
    if cfg.continue_key < 1 or cfg.continue_key > 254 then cfg.continue_key = Config.DEFAULTS.continue_key end
    cfg.gate_grace = math.max(0.2, math.min(10.0, cfg.gate_grace))
    cfg.gate_radius = math.max(3.0, math.min(50.0, cfg.gate_radius))
    return cfg
end

function Config.save(json, cfg)
    if json == nil then return false end
    local ok = pcall(json.dump_file, Config.FILE, cfg)
    return ok
end

return Config
