-- Settings, persisted with REFramework's json API to reframework/data/re4coop.json.

local Config = {}

Config.FILE = "re4coop.json"

-- Bumped when defaults change for safety: settings saved by an older version take the new
-- default for the keys listed in Config.RESET_ON_UPGRADE.
Config.VERSION = 10

Config.DEFAULTS = {
    config_version = Config.VERSION,
    player_name = "Player",
    last_address = "192.168.1.",
    port = 33040,
    password = "",

    -- network rates
    player_hz = 20,
    pose_hz = 30,         -- partner model pose updates per second
    enemy_tick_hz = 20,
    snapshot_hz = 20,     -- states per second of the enemies your game runs
    roster_hz = 5,        -- client: reports of the host's enemies it has a copy of, per second
    interp_delay = 0.066, -- seconds the partner is shown in the past (smooths network jitter)

    -- enemy sync (enemy_net.lua): every enemy is run by one game, its owner; the other shows it.
    -- Pairing is by the level's own enemy IDs.
    sync_enemies = true,
    enemy_authority = "shared", -- "shared": each enemy is run by the game of the player it is closer to
                                -- (enemies fight both players); "host": the host's game runs every enemy.
                                -- The host's setting decides.
    enemy_mirror = true,        -- enemies the partner's game runs stand and move where the partner's are
    enemy_motion_sync = true,   -- those enemies (and animals) also play the partner's animation
    enemy_anim_lock = true,     -- their own animation state machine is switched off (only the partner's animation plays)
    enemy_anim_layers = 2,      -- animation layers sent per enemy (1-3)
    enemy_hit_predict = true,   -- your hits on them take HP at once (never the last HP: the owner decides deaths)
    enemy_kill_with_hit = true, -- an enemy the partner's game killed dies here from the same killing hit
    enemy_erase = true,         -- enemies dead in the partner's world that only now spawn here never appear (no corpse)
    enemy_spawn_missing = true, -- client: enemies alive in the host's world that our game never spawned are spawned
    enemy_interp_delay = 0.1,   -- seconds the partner's enemies are shown in the past (smoothness vs. delay)
    sync_drops = true,        -- every enemy that dies gives each player their own loot roll, also the partner's kills
    sync_animals = true,      -- crows, chickens, fish, bats and rats near the client move as in the host's game
    animal_host_only = true,  -- client: animals the host's game does not report stay where they are

    -- shared world
    sync_flags = true,        -- story/scenario flags: objectives, map, doors, items taken, events seen
    sync_gimmicks = true,     -- gimmick states: locks, keys used, levers, shutters, puzzles
    sync_objects = true,      -- breakables and animals: crates, barrels, pots, crows, chickens...
    sync_doors = true,        -- a door is open in both games while either player keeps it open
    sync_traps = true,        -- bear traps that close and sensor bombs that go off do so in both games
    sync_mechanisms = true,   -- levers, big doors, valves, shelves, carts...: what one player moves moves in both games
    give_items = true,        -- "Give to <partner>" in the attache case's item commands
    give_label = "Give to %s", -- its text (%s = the partner's name)
    sync_object_states = false, -- experimental: also mirror other state changes of those objects
    sync_cutscenes = true,    -- a cutscene one player's game starts plays in the partner's game too
    cutscene_travel = true,   -- a partner who watched your cutscene from far away joins you when it ends
    sync_skips = true,        -- skipping a cutscene skips it in the partner's game too
    sync_triggers = true,     -- a scripted event one player walks into also runs in the partner's game

    -- joining and travelling
    auto_travel = true,         -- client: on joining, load the host's chapter and appear next to them
    follow_host_chapter = true, -- client: follow the host into the next chapter if you do not get there yourself
    auto_load_on_join = true,   -- client: joining from the title screen / main menu loads a save at once (the co-op slot, else the latest)

    -- saving
    sync_saves = true,          -- a save either game makes (autosave or typewriter) makes the partner's game save too
    coop_save_slot = 20,        -- client: the slot (1-20) its saves with the host go to, its autosaves included

    -- pauses
    no_pause = true,             -- while hosting or connected, menus and the inventory do not pause the game
    no_pause_mode = "menus",     -- "menus" (cutscenes and loading still pause), "all", "off"
    no_pause_aggressive = false, -- also refuse the pause requests themselves (if a menu still pauses)

    -- progression
    share_key_items = true,       -- a key item exists once: the partner's copy disappears when you take it
    left_behind_prompt = true,    -- remind of the teleport key when the partner is far away for a while
    left_behind_distance = 35.0,  -- metres
    left_behind_seconds = 6.0,
    teleport_key = 0x75,          -- F6 (Windows virtual-key code): teleport to the partner, any time
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

    -- diagnostics
    profiler = true,   -- time the mod's work (Diagnostics > Performance)
    perf_file = true,  -- write the measurements to reframework/data/re4coop_perf.json every 10 s

    -- experimental: features that change the game in ways not proven safe yet (off by default)
    travel_reload = false,       -- load the partner's chapter by triggering game over -> Continue
    stage_travel = false,        -- teleports to another stage preload it and use the game's warp
    exp_force_routine = false,   -- break objects by forcing their state machine into a "broken" state
    enemy_replay_mutilation = false, -- the partner's hits (and kills) may also burst heads and break limbs here (crashed the game)
}

-- Keys that take their (new) default once when a config saved before that config version is
-- loaded: version 7 (0.7) made 0.6's risky defaults experimental (crashes, stutter); version 8
-- (0.8) rebuilt enemy sync around the host, so switches turned off to work around 0.7's
-- problems come back on; version 9 (0.9) rebuilt enemy sync from scratch (enemy_net.lua), so the
-- enemy switches start from their defaults once more. (Gone: 0.7's enemy_ownership and
-- hit_ownership, 0.8's enemy_host_only - now enemy_authority - and the cosmetic hit replay
-- replay_partner_hits - partner hits now run for real in the enemy owner's game.) Version 10
-- (0.9.1) rebuilt cutscene sync on the game's own PayloadPlay and made it a default, next to
-- the new event trigger sync. (Gone: exp_table_reload - partner flags no longer reload the
-- flag table.)
Config.RESET_ON_UPGRADE = {
    [7] = { "interp_delay", "snapshot_hz", "replay_partner_hits", "sync_cutscenes", "travel_reload", "stage_travel" },
    [8] = { "sync_enemies", "enemy_mirror", "enemy_motion_sync" },
    [9] = { "sync_enemies", "enemy_mirror", "enemy_motion_sync", "snapshot_hz", "enemy_interp_delay" },
    [10] = { "sync_cutscenes", "sync_flags", "sync_triggers" },
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
            local reset = {}
            local saved_version = tonumber(saved.config_version) or 0
            for version, keys in pairs(Config.RESET_ON_UPGRADE) do
                if saved_version < version then
                    for _, k in ipairs(keys) do reset[k] = true end
                end
            end
            for k, default in pairs(Config.DEFAULTS) do
                local v = saved[k]
                if v ~= nil and type(v) == type(default) and not reset[k] then
                    cfg[k] = v
                end
            end
            cfg.config_version = Config.VERSION
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
    cfg.roster_hz = math.max(2, math.min(20, cfg.roster_hz))
    if cfg.enemy_authority ~= "shared" and cfg.enemy_authority ~= "host" then
        cfg.enemy_authority = Config.DEFAULTS.enemy_authority
    end
    cfg.enemy_anim_layers = math.max(1, math.min(3, math.floor(cfg.enemy_anim_layers)))
    if cfg.no_pause_mode ~= "menus" and cfg.no_pause_mode ~= "all" and cfg.no_pause_mode ~= "off" then
        cfg.no_pause_mode = Config.DEFAULTS.no_pause_mode
    end
    cfg.snapshot_hz = math.max(2, math.min(30, cfg.snapshot_hz))
    cfg.interp_delay = math.max(0.0, math.min(0.5, cfg.interp_delay))
    cfg.enemy_interp_delay = math.max(0.03, math.min(0.4, cfg.enemy_interp_delay))
    cfg.left_behind_distance = math.max(10.0, math.min(500.0, cfg.left_behind_distance))
    cfg.left_behind_seconds = math.max(1.0, math.min(120.0, cfg.left_behind_seconds))
    if type(cfg.give_label) ~= "string" or cfg.give_label == "" then cfg.give_label = Config.DEFAULTS.give_label end
    cfg.teleport_key = math.floor(cfg.teleport_key)
    cfg.snooze_key = math.floor(cfg.snooze_key)
    if cfg.teleport_key < 1 or cfg.teleport_key > 254 then cfg.teleport_key = Config.DEFAULTS.teleport_key end
    if cfg.snooze_key < 1 or cfg.snooze_key > 254 then cfg.snooze_key = Config.DEFAULTS.snooze_key end
    cfg.continue_key = math.floor(cfg.continue_key)
    if cfg.continue_key < 1 or cfg.continue_key > 254 then cfg.continue_key = Config.DEFAULTS.continue_key end
    cfg.gate_grace = math.max(0.2, math.min(10.0, cfg.gate_grace))
    cfg.gate_radius = math.max(3.0, math.min(50.0, cfg.gate_radius))
    cfg.coop_save_slot = math.max(1, math.min(20, math.floor(cfg.coop_save_slot)))
    return cfg
end

function Config.save(json, cfg)
    if json == nil then return false end
    local ok = pcall(json.dump_file, Config.FILE, cfg)
    return ok
end

return Config
