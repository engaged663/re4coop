-- Co-op session: drives the network connection and decides what to send and apply.
--
-- Dependencies are injected so the whole thing runs in tests without the game:
--   net      : re4coop_net (or a Session object from re4coop_net.new_session())
--   game     : adapter from game.lua (or a fake) - read_player_state, list_enemies, the
--              avatar capture methods listed in avatar.lua, saving (game_save.lua), ...
--   world    : adapter from game_world.lua (or a fake) - scenario flags, gimmicks, breakables,
--              cutscenes, location / warp / chapter switch. Optional: without it the shared
--              world, cutscene replay and travelling to the partner are off.
--   pause    : adapter from game_pause.lua (or a fake). Optional: menus keep pausing.
--   clock    : function() -> seconds
--   settings : live config table (see config.lua)
--   perf     : profiler / breadcrumbs (perf.lua). Optional.
--
-- Threading: update() runs on the game thread (LateUpdateBehavior) and is the only place that
-- changes the game, besides the game's own title screen / main menu update (hooked, also the
-- game thread), which asks on_menu whether to load a save now. The UI and the render-thread
-- fallback (update_network_only) only queue actions (Session:queue) and update Lua state.

local P = require("re4coop.protocol")
local Interp = require("re4coop.interp")
local EnemyNet = require("re4coop.enemy_net")
local PartnerTarget = require("re4coop.partner_target")
local ItemSync = require("re4coop.items_sync")
local Avatar = require("re4coop.avatar")
local DropSync = require("re4coop.drop_sync")
local Gate = require("re4coop.gate")
local FlagSync = require("re4coop.flag_sync")
local GimmickSync = require("re4coop.gimmick_sync")
local ObjectSync = require("re4coop.object_sync")
local DoorSync = require("re4coop.door_sync")
local TrapSync = require("re4coop.trap_sync")
local MechanismSync = require("re4coop.mechanism_sync")
local GiveSync = require("re4coop.give_sync")
local SaveSync = require("re4coop.save_sync")
local AnimalSync = require("re4coop.animal_sync")
local CutsceneSync = require("re4coop.cutscene_sync")
local AshleySync = require("re4coop.ashley_sync")
local PurposeSync = require("re4coop.purpose_sync")
local TriggerSync = require("re4coop.trigger_sync")
local Travel = require("re4coop.travel")
local ScreenWatch = require("re4coop.screen_watch")
local Lobby = require("re4coop.lobby")
local Config = require("re4coop.config")
local Perf = require("re4coop.perf")

local Session = {}
Session.__index = Session

local NOTIFY = {
    DIED = 1,
    REVIVED = 2,
    TELEPORTED = 3,
    INFO = 4,
}
Session.NOTIFY = NOTIFY

local MAX_LOG = 60
local ITEM_TICK_INTERVAL = 0.25 -- seconds between pickup scans (scene search is not free)
local TP_WATCH_SECONDS = 4.0    -- after a teleport, re-teleport if we fell through unloaded ground
local TP_COOLDOWN = 3.0         -- seconds between teleports on demand
local TP_NEAR = 3.0             -- metres: closer than this, a teleport would not move us
local TP_FALL_TOLERANCE = 4.0   -- metres below the target that count as "fell"
local TP_MAX_TRIES = 3
local LOCAL_POS_FRESH = 0.5     -- seconds a local position stays usable for pickup/left-behind logic
-- Partners in different stages (chainsaw.StageID) count as separated from this fraction of
-- the far-away distance on: a partner waiting just behind a door you cannot open is in
-- another stage but may never get far away. Stage borders can run through one area (the
-- research dump showed items from stages 40200 and 40210 loaded together), so players a few
-- metres apart in different stages are not separated.
local STAGE_APART_FACTOR = 0.5
local TRACER_SECONDS = 0.25     -- how long a partner's shot tracer stays on screen
local LOCATION_INTERVAL = 0.5   -- seconds between reads of where we are (chapter, stage)
local FOLLOW_CHAPTER_DELAY = 15.0 -- client: the host has been in a later chapter this long -> follow
local RELOAD_GAP = 2.0          -- seconds without a player that mean the game (re)loaded
local MAX_DEFERRED = 4000
local SETTLE_AFTER_LOAD = 1.0   -- seconds in game before queued world/enemy messages are applied
local TRANSITION_FLAG_HOLD = 2.0 -- the partner's flags wait this long after our transition ends
local SCREEN_INTERVAL = 0.5     -- seconds between looks at the screen fades (screen_watch.lua)
local JOIN_NEW_TIMEOUT = 60.0   -- seconds a new game to join the host may wait for the main menu
local HOST_PLAYING_AGE = 3.0    -- seconds: a host PLAYER message this fresh means the host is in game
local STATUS_MAX_AGE = 0.1      -- status_cached(): seconds a computed status is reused
local TAP_MAX = 1.0             -- seconds: the Ashley key held longer than this is not a tap
local TAP_SETTLE = 0.25         -- seconds after the release the game must still have the focus
-- Keys that, pressed while the Ashley key (Alt) is held, make it part of a shortcut
-- (Alt+Tab, Alt+F4, Alt+Enter, Alt+Esc) rather than a switch.
local SHORTCUT_KEYS = { 0x09, 0x73, 0x0D, 0x1B }

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function yaw_of(q)
    if q == nil then return 0 end
    return math.atan(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
end

local EMPTY = {}

-- Messages that only update state (no game objects) and may be handled while the game
-- loop is not running (title screen, loading).
local OFFLINE_SAFE = {
    [P.T.CHAT] = true, [P.T.NOTIFY] = true, [P.T.HELLO] = true, [P.T.PLAYER] = true,
    [P.T.ITEM_TAKEN] = true, -- only recorded here; the pickup is removed on the next game tick
    [P.T.ITEM_GIVE] = true, [P.T.ITEM_GIVE_RESULT] = true, -- only queued here; placed when in game
    [P.T.SAVE] = true, -- only noted here; our game saves once it can
    [P.T.FRAG] = true, [P.T.AVATAR] = true, [P.T.GEAR] = true, [P.T.POSE] = true, [P.T.ACTIONS] = true,
    -- Ashley: only her owner, epoch and the partner's latest state are recorded here; our
    -- game follows them on the next game tick.
    [P.T.ASHLEY] = true, [P.T.ASHLEY_OWNER] = true, [P.T.ASHLEY_SWITCH] = true, [P.T.ASHLEY_BANKS] = true,
    -- The lobby and the synchronized start: state only (lobby.lua); the game acts on the next tick.
    [P.T.LOBBY_SETTINGS] = true, [P.T.LOBBY_PLAYER] = true, [P.T.LOBBY_START] = true, [P.T.LOAD_STATE] = true,
    [P.T.LOAD_GO] = true,
}

local LOBBY_TYPES = {
    [P.T.LOBBY_SETTINGS] = true, [P.T.LOBBY_PLAYER] = true, [P.T.LOBBY_START] = true, [P.T.LOAD_STATE] = true,
    [P.T.LOAD_GO] = true,
}
local LOBBY_SAVES_EVERY = 2.0 -- seconds between reads of the host's co-op files while the lobby is open

-- Reliable messages that must not be lost but touch game objects: kept until the game loop
-- runs again. Everything else arriving then (enemy snapshots, hits) is resent continuously.
local DEFER = {
    [P.T.ENEMY_HIT] = true, [P.T.ENEMY_DEATH] = true, [P.T.ENEMY_OWNER] = true, [P.T.ENEMY_GRAVE] = true,
    [P.T.ENEMY_FATAL] = true,
    [P.T.FLAGS] = true, [P.T.FLAG_WORDS] = true, [P.T.GIMMICKS] = true, [P.T.OBJECTS] = true,
    [P.T.CUTSCENE] = true, [P.T.CUTSCENE_SKIP] = true, [P.T.TRIGGER] = true, [P.T.WORLD_REQUEST] = true, [P.T.WORLD_DONE] = true,
    [P.T.TRAPS] = true, [P.T.MECHANISMS] = true, [P.T.PURPOSE] = true,
}

local SYNC_NAMES = { "enemy_net", "partner_target", "drop_sync", "flag_sync", "gimmick_sync", "object_sync", "animal_sync",
    "cutscene_sync", "trigger_sync", "door_sync", "trap_sync", "mechanism_sync", "ashley_sync", "purpose_sync" }

function Session.new(opts)
    local self = setmetatable({}, Session)
    self.net = opts.net
    self.game = opts.game
    self.world = opts.world
    self.pause = opts.pause
    self.clock = opts.clock
    self.settings = opts.settings
    self.perf = opts.perf or Perf.NULL
    self.log_sink = opts.log or function() end
    self.actions = {}        -- UI requests, carried out on the game thread (see Session:queue)
    self.messages = {}       -- chat + notices shown in the UI/HUD: {time, text, kind}
    self.deferred = {}       -- reliable messages received while the game loop was not running
    self.frag_id = 0
    self.next_sync_id = 1
    self.avatar_tx = Avatar.new_sender({
        protocol = P,
        settings = self.settings,
        send = function(bytes, reliable, unordered) return self:send(bytes, reliable, unordered) end,
        send_large = function(bytes) return self:send_large(bytes) end,
    })
    self.avatar_rx = Avatar.new_receiver({ protocol = P, settings = self.settings })
    self:reset_peer()
    self.role = "none"
    self.last_error = nil
    self.last_player_send = -math.huge
    self.last_enemy_tick = -math.huge
    self.last_location = -math.huge
    self.local_dead = false
    self.local_cutscene = false
    self.local_transition = false -- our game is changing chapter, over or loading (game:in_transition)
    self.local_stage = nil
    self.local_chapter = nil
    self.local_loc = nil     -- world:location(): {chapter, stage, pos, yaw, loading, playable}
    self.player_id = nil     -- identity of the player context (a new one = the game reloaded)
    self.gate = Gate.new(opts.settings)
    self.held_scale = nil   -- time scale to restore while the gate holds us (nil = not holding)
    -- Our game's transitions, and a screen they leave black (screen_watch.lua).
    self.screen_watch = ScreenWatch.new({ settings = self.settings,
        log = function(fmt, ...) self:log(fmt, ...) end,
        notify = function(text, kind) self:add_message(text, kind) end })
    self.last_screen_tick = -math.huge
    self.last_item_tick = -math.huge
    self.keys_down = {}
    self.left_behind = nil
    self.far_since = nil
    self.prompt_snoozed_until = -math.huge
    self.tp_watch = nil
    self:make_item_sync()
    -- Giving items: one per session object (not per partner), so nothing in flight is lost
    -- when the partner leaves.
    self.give_sync = GiveSync.new({ protocol = P, settings = self.settings,
        send = function(bytes, reliable) return self:send(bytes, reliable) end,
        notify = function(text, kind) self:add_message(text, kind) end,
        partner_name = function() return self.partner_name or "partner" end })
    if self.game ~= nil and self.game.install_give_hooks ~= nil then
        self.game:install_give_hooks({
            enabled = function()
                return self.partner_connected and self.compatible and self.settings.give_items ~= false
            end,
            label = function()
                local fmt = self.settings.give_label or "Give to %s"
                local ok, s = pcall(string.format, fmt, self.partner_name or "partner")
                return ok and s or fmt
            end,
            on_give = function(ev) self.give_sync:on_give(ev, self.clock(), self.game) end,
            on_refused = function(why) self:add_message("Cannot give it: " .. tostring(why), "warn") end,
        })
    end
    -- Saves for both players, and joining from the title screen (one per session object too:
    -- the hooks are installed once).
    self.save_sync = SaveSync.new({ protocol = P, settings = self.settings,
        send = function(bytes, reliable) return self:send(bytes, reliable) end,
        notify = function(text, kind) self:add_message(text, kind) end,
        partner_name = function() return self.partner_name or "partner" end,
        role = function() return self.role end,
        active = function() return self.partner_connected and self.compatible end })
    if self.game ~= nil and self.game.install_save_hooks ~= nil then
        self.game:install_save_hooks({
            redirect = function(slot) return self.save_sync:redirect(slot) end,
            on_save = function(slot, mirrored, from_slot)
                self.save_sync:on_local_save(slot, self.clock(), mirrored, from_slot)
            end,
            continue_slot = function() return self.save_sync:continue_slot(self.clock()) end,
            on_menu = function(where) return self:on_menu(where) end,
        })
    end

    -- The lobby in the game's own main menu (lobby.lua, game_menu.lua): one per session object
    -- too (the menu hooks are installed once).
    self.lobby = Lobby.new({ protocol = P, settings = self.settings,
        send = function(bytes, reliable) return self:send(bytes, reliable) end,
        notify = function(text, kind) self:add_message(text, kind) end,
        role = function() return self.role end,
        active = function() return self.partner_connected and self.compatible end,
        my_name = function() return self.settings.player_name end,
        partner_name = function() return self.partner_name or "Compañero" end })
    self.lobby_hold = false
    if self.game ~= nil and self.game.install_menu_hooks ~= nil and self.settings.lobby_menu ~= false then
        self.game:install_menu_hooks({
            entry = Lobby.ACTION.MULTIPLAYER, section = Lobby.SECTION, labels = Lobby.LABELS,
            mode = function() return self.lobby.menu_mode end,
            covered = function() return self.lobby:covers_menu() end,
            on_decide = function(action) self:on_menu_decide(action) end,
            on_cancel = function() self.lobby:set_menu_mode("main") end,
        })
    end

    if self.world ~= nil and self.world.install_hooks ~= nil then
        self.world:install_hooks({
            on_flag = function(guid, value, pulse)
                if self.flag_sync and self.partner_connected and self.compatible then
                    self.flag_sync:on_local_flag(guid, value, self.clock(), pulse)
                end
            end,
            on_cutscene = function(ev)
                if self.cutscene_sync and self.partner_connected and self.compatible then
                    self.cutscene_sync:on_local_start(ev, self.clock(), self:event_location())
                end
            end,
            on_cutscene_skip = function(ev)
                if self.cutscene_sync and self.partner_connected and self.compatible then
                    self.cutscene_sync:on_local_skip(ev, self.clock())
                end
            end,
            on_trigger = function(ev)
                if self.trigger_sync and self.partner_connected and self.compatible then
                    self.trigger_sync:on_local_trigger(ev, self.clock(), self:event_location())
                end
            end,
            -- Joining at the host's place: where the next loaded game puts us, and the save an
            -- in-game reload loads.
            spawn_spot = function() return self:host_spawn_spot() end,
            reload_slot = function() return self:reload_slot() end,
        })
    end

    -- Resume a session that survived "Reset Scripts" (the plugin keeps it alive).
    local state = self.net.state()
    if state ~= "idle" then
        self.role = self.net.role()
        self:make_syncs()
        if state == "connected" then
            self.partner_connected = true
            self.partner_name = self.net.stats().peer_name
            self:send_hello(true) -- we lost the partner's HELLO and character in the reload
            self:add_message("Resumed existing co-op session after script reload", "info")
        end
    end
    return self
end

-- Readable name for a Windows virtual-key code (F1-F12, letters, digits).
function Session.key_name(vk)
    if vk == nil then return "?" end
    if vk >= 0x70 and vk <= 0x7B then return "F" .. (vk - 0x6F) end
    if vk == 0x12 or vk == 0xA4 or vk == 0xA5 then return "Alt" end
    if (vk >= 0x30 and vk <= 0x39) or (vk >= 0x41 and vk <= 0x5A) then return string.char(vk) end
    return ("key 0x%02X"):format(vk)
end

function Session:log(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    self.log_sink(ok and text or fmt)
end

function Session:add_message(text, kind)
    self.messages[#self.messages + 1] = { time = self.clock(), text = text, kind = kind or "info" }
    while #self.messages > MAX_LOG do
        table.remove(self.messages, 1)
    end
    self:log("%s", text)
end

function Session:reset_peer()
    self.partner_connected = false
    self.partner_name = nil
    self.partner_hello = nil
    self.partner_state = nil     -- last decoded PLAYER message
    self.compatible = true
    self.interp = Interp.new({ delay = (self.settings and self.settings.interp_delay) or 0.066, adaptive = true })
    self.reassembler = P.new_reassembler()
    self.avatar_tx:reset()
    self.avatar_rx:reset()
    for _, name in ipairs(SYNC_NAMES) do
        if self[name] then self[name]:reset() end
    end
    self.join_travel_pending = false
    self.sync_on_join = false
    self.world_sync_pending = nil
    self.world_synced = false -- client: the host's world state arrived at least once
    self.chapter_ahead_since = nil
    self.host_spot = nil      -- client: where the host last stood in play (spawn at the host)
    self.join_new = nil       -- client: a new game to start from the main menu (joining without a save)
    self.deferred = {} -- queued messages belonged to the previous partner
    if self.travel then self.travel:cancel("partner left") end
    if self.save_sync then self.save_sync:reset() end
    if self.world and self.world.disarm_spawn then self.world:disarm_spawn() end
end

-- Creates the per-role sync modules (nothing while not in a session).
function Session:make_syncs()
    if self.role ~= "host" and self.role ~= "client" then
        for _, name in ipairs(SYNC_NAMES) do
            if self[name] then pcall(self[name].reset, self[name]) end -- e.g. doors the partner held open
            self[name] = nil
        end
        self.travel = nil
        return
    end
    local base = {
        role = self.role,
        protocol = P,
        settings = self.settings,
        send = function(bytes, reliable) self:send(bytes, reliable) end,
        log = function(...) self:log(...) end,
        notify = function(text, kind) self:add_message(text, kind) end,
    }
    self.drop_sync = DropSync.new({ settings = self.settings, log = base.log })
    local enemy_opts = {}
    for k, v in pairs(base) do enemy_opts[k] = v end
    enemy_opts.on_kill = function(id, now) self.drop_sync:on_remote_kill(id, now) end
    self.enemy_net = EnemyNet.new(enemy_opts)
    -- The client's player as a second player in the host's game (partner_target.lua).
    local target_opts = {}
    for k, v in pairs(base) do target_opts[k] = v end
    target_opts.enemies = self.enemy_net
    self.partner_target = PartnerTarget.new(target_opts)
    -- Client: our copies of the host's enemies answer our player's finisher checks from what the
    -- host's enemy says (enemy_net), and our player's noises are reported.
    self.game.partner_fatal_query = function(id)
        local en = self.enemy_net
        if en == nil or self.settings.sync_enemies == false then return nil end
        return en:partner_fatal(id)
    end
    self.game.capture_noise = self.role == "client"
    self.flag_sync = FlagSync.new(base)
    self.gimmick_sync = GimmickSync.new(base)
    self.object_sync = ObjectSync.new(base)
    self.door_sync = DoorSync.new(base)
    self.trap_sync = TrapSync.new(base)
    self.mechanism_sync = MechanismSync.new(base)
    self.purpose_sync = PurposeSync.new(base)
    local ashley_opts = {}
    for k, v in pairs(base) do ashley_opts[k] = v end
    ashley_opts.partner_name = function() return self.partner_name or "your partner" end
    ashley_opts.send_large = function(bytes) return self:send_large(bytes) end
    self.ashley_sync = AshleySync.new(ashley_opts)
    local animal_opts = {}
    for k, v in pairs(base) do animal_opts[k] = v end
    -- Animal deaths go through the breakables' channel (OBJECTS) right away.
    animal_opts.on_local_kill = function(guid, routine, now) self.object_sync:report_destroyed(guid, routine, now) end
    animal_opts.on_remote_kill = function(guid, now) self.object_sync:note_applied(guid, now) end
    self.animal_sync = AnimalSync.new(animal_opts)
    local cutscene_opts = {}
    for k, v in pairs(base) do cutscene_opts[k] = v end
    -- While our copy of the partner's cutscene plays, the partner's flags wait: ours sets its
    -- own start and end flags, and what their end flags start must not begin here early.
    cutscene_opts.on_replay = function(started, now)
        if self.flag_sync == nil then return end
        if started then
            self.flag_sync:hold(now or self.clock())
        elseif self.world ~= nil then
            self.flag_sync:release(now or self.clock(), self.world)
        end
    end
    self.cutscene_sync = CutsceneSync.new(cutscene_opts)
    self.trigger_sync = TriggerSync.new(base)
    self.travel = Travel.new({
        settings = self.settings,
        log = base.log,
        notify = base.notify,
        on_sync = function() self:request_world_sync() end,
    })
end
Session.make_enemy_sync = Session.make_syncs -- older name

function Session:make_item_sync()
    self.item_sync = ItemSync.new({
        protocol = P,
        settings = self.settings,
        is_key_item = function(id)
            if self.game.is_key_item then return self.game.is_key_item(id) end
            return false
        end,
        send = function(bytes, reliable) self:send(bytes, reliable) end,
        notify = function(text) self:add_message(text, "warn") end,
    })
end

-------------------------------------------------------------------------------
-- Commands from the UI
-------------------------------------------------------------------------------

-- UI buttons run on the render thread; anything that touches the game is queued here and
-- carried out by update() on the game thread. name: "host" | "join" | "leave" | "teleport" |
-- "travel" | "dump"; arg: join address / dump extra.
function Session:queue(name, arg)
    if #self.actions < 16 then self.actions[#self.actions + 1] = { name = name, arg = arg } end
end

-- in_game = false: from the render thread (only network actions run; the rest wait).
function Session:run_actions(in_game)
    if #self.actions == 0 then return end
    local keep = {}
    for _, a in ipairs(self.actions) do
        if a.name == "host" then
            self:host()
        elseif a.name == "join" then
            self:join(a.arg)
        elseif a.name == "leave" then
            self:leave()
        elseif a.name == "lobby_leave" then
            -- Leaving the lobby screen ends the session it was made for.
            if self.lobby:close() == "leave" and self.role ~= "none" then self:leave() end
        elseif not in_game then
            keep[#keep + 1] = a
        elseif a.name == "teleport" then
            self:request_teleport()
        elseif a.name == "travel" then
            self:travel_to_partner()
        elseif a.name == "ashley" then
            if self.ashley_sync and self.partner_connected then self.ashley_sync:request(self.clock()) end
        elseif a.name == "dump" then
            if self.game.dump_types then
                local ok, runs = self.game:dump_types(a.arg)
                self.dump_result = ok and ("run %d saved - send re4coop_typedump.json and re4coop_research_log.json"):format(runs)
                    or "failed (see REFramework log)"
            end
        end
    end
    self.actions = keep
end

function Session:host()
    local s = self.settings
    local ok, err = self.net.host(s.port, s.player_name, s.password)
    if not ok then
        self.last_error = err
        self:add_message("Could not host: " .. tostring(err), "error")
        return false
    end
    self.role = "host"
    self.last_error = nil
    self:reset_peer()
    self:make_syncs()
    self.item_sync:reset()
    self:add_message(("Hosting on UDP port %d - waiting for partner"):format(s.port), "info")
    return true -- no-pause starts with the next game-thread update
end

function Session:join(address)
    local s = self.settings
    address = (address or s.last_address or ""):match("^%s*(.-)%s*$")
    local host, port = address:match("^([^:]+):(%d+)$")
    host = host or address
    port = tonumber(port) or s.port
    local ok, err = self.net.join(host, port, s.player_name, s.password)
    if not ok then
        self.last_error = err
        self:add_message("Could not join: " .. tostring(err), "error")
        return false
    end
    self.role = "client"
    self.last_error = nil
    self:reset_peer()
    self:make_syncs()
    self.item_sync:reset()
    self:add_message(("Connecting to %s:%d ..."):format(host, port), "info")
    return true
end

-- Everything the session changed in the game goes back to normal.
function Session:restore_game()
    self:apply_hold(false)
    if self.pause and self.pause.set_active then
        self.pause:set_active(false, self.settings.no_pause_mode, false, self.clock())
    end
    if self.game.partner_target_detach then self.game:partner_target_detach() end
    if self.game.restore_enemies then self.game:restore_enemies() end
    if self.game.ashley_restore then self.game:ashley_restore() end
    if self.world and self.world.restore_animals then self.world:restore_animals() end
    if self.world and self.world.disarm_chapter_switch then self.world:disarm_chapter_switch() end
end

function Session:leave()
    self.net.stop()
    if self.lobby then self.lobby:on_disconnected(self.clock()) end
    if self.save_sync then self.save_sync:set_host_slot(nil) end
    if self.role ~= "none" then
        self:add_message("Left the co-op session", "info")
    end
    self.role = "none"
    self.item_sync:reset()
    self:reset_peer()
    self:make_syncs()
    self.gate:reset()
    self.restore_pending = true -- the game side is restored by the next game-thread update
end

-- Undo anything that must not outlive the script (called on "Reset Scripts").
function Session:shutdown()
    self.perf:closing("script reset")
    self:restore_game()
end

-- unordered (reliable only): its own lane, delivered as soon as it arrives (see the plugin).
function Session:send(bytes, reliable, unordered)
    if not self.partner_connected then return false end
    local ok, err
    if unordered then
        ok, err = self.net.send(bytes, reliable, true)
    else
        ok, err = self.net.send(bytes, reliable)
    end
    if not ok then
        self:log("send failed: %s", tostring(err))
    end
    return ok and true or false
end

-- Reliable send of a message that may be bigger than one datagram.
function Session:send_large(bytes)
    if #bytes <= P.MAX_PAYLOAD then
        return self:send(bytes, true)
    end
    if not self.partner_connected then return false end
    self.frag_id = (self.frag_id + 1) & 0xFFFF
    local pieces, err = P.fragment(bytes, self.frag_id)
    if pieces == nil then
        self:log("not sent: %s", tostring(err))
        return false
    end
    for _, piece in ipairs(pieces) do
        if not self:send(piece, true) then return false end
    end
    return true
end

function Session:send_chat(text)
    if text == nil or text == "" then return false end
    if self:send(P.encode_chat(text), true) then
        self:add_message(("%s: %s"):format(self.settings.player_name, text), "chat")
        return true
    end
    return false
end

-- Where the partner is: { chapter, stage, pos, yaw } (pos interpolated), or nil.
function Session:partner_location()
    local m = self.partner_state
    if m == nil then return nil end
    local st = self.interp:sample(self.clock())
    return { chapter = m.chapter, stage = m.stage, pos = st and st.pos or m.pos, yaw = yaw_of(m.rot) }
end

-- True when we can travel (warp across stages, switch chapters) instead of teleporting.
function Session:can_travel()
    return self.travel ~= nil and self.world ~= nil and self.settings.stage_travel ~= false
end

function Session:teleport_to_partner()
    local st = self.interp:sample(self.clock())
    if st == nil then
        self:add_message("No partner position yet", "error")
        return false
    end
    -- The partner is in another stage: the game's own warp loads it first.
    local target = self:partner_location()
    if self:can_travel() and target ~= nil and target.stage ~= nil and self.local_stage ~= nil
        and target.stage ~= self.local_stage then
        return self:travel_to_partner()
    end
    local ok, err = self.game:teleport_player(st.pos)
    if ok then
        self:add_message("Teleported to partner", "info")
        self:send(P.encode_notify(NOTIFY.TELEPORTED, self.settings.player_name .. " teleported to you"), true)
        -- The destination may still be streaming in; watch for a fall and retry.
        self.tp_watch = { target = st.pos, deadline = self.clock() + TP_WATCH_SECONDS, tries = 1 }
        self.left_behind = nil
        self.far_since = nil
    else
        self:add_message("Teleport failed: " .. tostring(err), "error")
    end
    return ok
end

-- Teleport on demand (the teleport key or the panel's button), at any time while playing
-- together: checks what would make it fail or pointless and says why instead.
function Session:request_teleport(now)
    now = now or self.clock()
    local function no(text)
        self:add_message(text, "warn")
        return false
    end
    if not self.partner_connected then return no("Not connected to a partner") end
    local left = (self.tp_ready_at or -math.huge) - now
    if left > 0 then return no(("Teleport ready again in %.0f s"):format(math.ceil(left))) end
    if self.travel ~= nil and self.travel:busy() then return no("Already travelling to your partner") end
    if self.local_cutscene then return no("Not during a cutscene - try again when it ends") end
    local m = self.partner_state
    local partner = self.interp:sample(now)
    local age = self.interp:age(now)
    if m == nil or partner == nil then return no("No partner position yet (is your partner in game?)") end
    if age == nil or age > 3.0 then return no("Your partner is loading or paused - try again in a moment") end
    local pflags = partner.flags or m.flags or 0
    -- A partner held at a transition (frozen in its cutscene) waits for us: that is the time to go.
    if (pflags & P.PLAYER_FLAGS.CUTSCENE) ~= 0 and (pflags & P.PLAYER_FLAGS.GATE_WAITING) == 0 then
        return no("Your partner is in a cutscene - try again when it ends")
    end
    -- Another chapter: only if the partner's stage is not part of our loaded world (a chapter
    -- part can change without changing the map).
    local stage_here = m.stage ~= nil and self.game.stage_active ~= nil and self.game:stage_active(m.stage)
    if m.chapter ~= nil and self.local_chapter ~= nil and m.chapter ~= self.local_chapter and not stage_here then
        if self.role == "client" and self:can_travel() then
            self:add_message("Your partner is in another chapter - loading it...", "warn")
            self.tp_ready_at = now + TP_COOLDOWN
            return self:travel_to_partner()
        end
        return no("Your partner is in another chapter")
    end
    local mine = self:fresh_local_pos(now)
    local same_stage = m.stage == nil or self.local_stage == nil or m.stage == self.local_stage
    if mine ~= nil and same_stage and dist3(partner.pos, mine) < TP_NEAR then
        return no("You are already next to your partner")
    end
    local ok = self:teleport_to_partner()
    if ok then self.tp_ready_at = now + TP_COOLDOWN end
    return ok
end

-- Stage-aware travel to the partner: preloads their stage and warps there, or loads their
-- chapter first (through a reload) when they are in another one.
function Session:travel_to_partner()
    if not self:can_travel() then
        return self:teleport_to_partner()
    end
    local target = self:partner_location()
    if target == nil then
        self:add_message("No partner position yet", "error")
        return false
    end
    self.travel:request({ chapter = target.chapter, stage = target.stage, pos = target.pos, yaw = target.yaw,
        reason = "manual", follow = true })
    self:send(P.encode_notify(NOTIFY.TELEPORTED, self.settings.player_name .. " is travelling to you"), true)
    self.left_behind = nil
    self.far_since = nil
    return true
end

-- Client: ask the host for its complete world state (flags, gimmicks, broken objects).
function Session:request_world_sync()
    if self.role ~= "client" or not self.partner_connected then
        if self.travel then self.travel:sync_done() end
        return false
    end
    local s = self.settings
    local what = 0
    if s.sync_flags ~= false then what = what | P.WORLD.FLAGS end
    if s.sync_gimmicks ~= false then what = what | P.WORLD.GIMMICKS end
    if s.sync_objects ~= false then what = what | P.WORLD.OBJECTS end
    if s.sync_enemies ~= false then what = what | P.WORLD.ENEMIES end
    local id = self.next_sync_id
    self.next_sync_id = id % 65535 + 1
    self.world_sync_pending = id
    self:send(P.encode_world_request(id, what), true)
    self:add_message("Synchronising the world with the host...", "info")
    return true
end

-- Re-teleports if the player fell below the target right after a teleport (the area under
-- the partner had not finished loading). Called with each fresh local position.
function Session:watch_teleport(now, pos)
    local w = self.tp_watch
    if w == nil then return end
    if now > w.deadline then
        self.tp_watch = nil
        return
    end
    if pos.y < w.target.y - TP_FALL_TOLERANCE then
        if w.tries >= TP_MAX_TRIES then
            self.tp_watch = nil
            self:add_message("Teleport destination is not loaded yet - try again in a moment", "error")
            return
        end
        if self.game:teleport_player(w.target) then
            w.tries = w.tries + 1
            w.deadline = now + TP_WATCH_SECONDS
        end
    end
end

-- Partner far away for a while (e.g. they went through a door that needs a key item only
-- they have): offer a teleport so nobody gets softlocked.
function Session:update_left_behind(now)
    local s = self.settings
    local partner = self.interp:sample(now)
    local age = self.interp:age(now)
    local mine = self:fresh_local_pos(now)
    local pflags = partner ~= nil and (partner.flags or 0) or 0
    local partner_chapter = self.partner_state and self.partner_state.chapter
    if self.travel ~= nil and self.travel:busy() then
        self.far_since = nil
        self.left_behind = nil
        return
    end
    if self.gate.holding == nil and (pflags & P.PLAYER_FLAGS.GATE_WAITING) ~= 0 and age ~= nil and age <= 1.5 then
        -- The partner waits for us at a transition: offer the teleport right away (or, when
        -- they are already in the next chapter, tell us to finish this one).
        local ahead = partner_chapter ~= nil and self.local_chapter ~= nil and partner_chapter > self.local_chapter
        -- Across a chapter change a teleport is only safe if the partner's stage exists in our
        -- loaded world (the chapter changed without changing the map).
        if ahead and partner.stage ~= nil and self.game.stage_active ~= nil and self.game:stage_active(partner.stage) then
            ahead = false
        end
        self.far_since = nil
        self.left_behind = {
            distance = mine and dist3(partner.pos, mine) or 0,
            partner_waiting = ahead and "chapter" or "here",
            other_stage = partner.stage ~= nil and self.local_stage ~= nil and partner.stage ~= self.local_stage,
            -- A client can load the host's chapter (F6 reloads into it).
            can_follow = ahead and self.role == "client" and self:can_travel(),
        }
        return
    end
    local cutscene = self.local_cutscene or (pflags & P.PLAYER_FLAGS.CUTSCENE) ~= 0
    if not s.left_behind_prompt or partner == nil or age == nil or age > 1.5 or mine == nil or cutscene
        or self.tp_watch ~= nil or self.gate.holding ~= nil then
        self.far_since = nil
        self.left_behind = nil
        return
    end
    local d = dist3(partner.pos, mine)
    local other_stage = partner.stage ~= nil and self.local_stage ~= nil and partner.stage ~= self.local_stage
    if d < s.left_behind_distance and not (other_stage and d >= s.left_behind_distance * STAGE_APART_FACTOR) then
        self.far_since = nil
        self.left_behind = nil
        return
    end
    self.far_since = self.far_since or now
    if now - self.far_since >= s.left_behind_seconds and now >= self.prompt_snoozed_until then
        self.left_behind = { distance = d, other_stage = other_stage }
    else
        self.left_behind = nil
    end
end

-- Transition gate: hold (freeze) the local game until the partner reaches the transition.
function Session:update_gate(now)
    if self.lobby_hold then
        -- The synchronized start holds our loaded map until the partner's has loaded too.
        self:apply_hold(true)
        return
    end
    local partner = self.interp:sample(now)
    local age = self.interp:age(now)
    local fresh = partner ~= nil and age ~= nil and age <= 1.5
    local pflags = partner ~= nil and (partner.flags or 0) or 0
    local mine = self:fresh_local_pos(now)
    local before = self.gate.holding
    local hold = self.gate:update(now, {
        connected = self.partner_connected and self.compatible and not self.gate_disabled,
        -- A chapter change or a reload of ours is never held: frozen, it could never finish.
        transition = self.local_transition,
        in_game = mine ~= nil,
        event = self.local_cutscene,
        chapter = self.local_chapter,
        stage = self.local_stage,
        pos = mine,
        partner_fresh = fresh,
        partner_event = fresh and (pflags & P.PLAYER_FLAGS.CUTSCENE) ~= 0,
        -- The last chapter the partner reported, even while they are on a loading screen.
        partner_chapter = self.partner_state and self.partner_state.chapter,
        partner_stage = fresh and partner.stage or nil,
        partner_pos = fresh and partner.pos or nil,
        continue_pressed = self:key_pressed(self.settings.continue_key),
    })
    if hold ~= nil and before == nil then
        local key = Session.key_name(self.settings.continue_key)
        if hold == "chapter" then
            self:add_message(("Waiting for %s to reach this chapter - press %s to continue alone")
                :format(self.partner_name or "your partner", key), "warn")
        else
            self:add_message(("Waiting for %s at this transition - press %s to continue alone")
                :format(self.partner_name or "your partner", key), "warn")
        end
    elseif hold == nil and before ~= nil then
        self:add_message("Continuing (" .. tostring(self.gate.last_release) .. ")", "good")
    end
    self:apply_hold(hold ~= nil)
end

-- Our transitions and the screen after them (screen_watch.lua): a transition or event fade
-- still dark while our game plays again, with nothing of its own running, is lifted.
function Session:update_screen(now)
    local g = self.game
    if g.in_transition == nil or g.dark_fades == nil or now - self.last_screen_tick < SCREEN_INTERVAL then return end
    self.last_screen_tick = now
    local transition = self.local_transition
    local playing = not transition and self:fresh_local_pos(now) ~= nil and not self.local_dead
    -- A hold of ours (gate, synchronized start) freezes the game on purpose: not a stuck screen.
    local busy = self.local_cutscene or self.held_scale ~= nil
        or (playing and g.camera_busy ~= nil and g:camera_busy())
    local lift = self.screen_watch:tick(now, {
        transition = transition,
        detail = function() return g.transition_detail and g:transition_detail() or nil end,
        playing = playing,
        busy = busy,
        dark = (playing and not busy) and g:dark_fades() or nil,
    })
    local done = {}
    for _, t in ipairs(lift) do
        if g:lift_fade(t, 0.5) then done[#done + 1] = t end
    end
    self.screen_watch:lifted(done, now)
end

-- Freezes (time scale 0) or restores the local game.
function Session:apply_hold(want)
    local g = self.game
    if want then
        if self.held_scale == nil then
            local cur = g.get_time_scale and g:get_time_scale() or nil
            self.held_scale = (cur ~= nil and cur > 0) and cur or 1.0
            if g.set_time_scale then g:set_time_scale(0) end
        elseif g.get_time_scale and g.set_time_scale and g:get_time_scale() ~= 0 then
            g:set_time_scale(0) -- a new scene loaded while we wait
        end
    elseif self.held_scale ~= nil then
        if g.set_time_scale then g:set_time_scale(self.held_scale) end
        self.held_scale = nil
    end
end

-- The local player's position if it was read recently (nil on menus/loading screens).
-- While our game changes chapter or reloads there is no player in the game either: the
-- player's context lives on, but nothing may act on it (enemies, saves, items, prompts).
function Session:fresh_local_pos(now)
    if self.last_local_pos == nil or self.last_local_pos_time == nil then return nil end
    if now - self.last_local_pos_time > LOCAL_POS_FRESH then return nil end
    if self.local_transition then return nil end
    return self.last_local_pos
end

-- True once per press (edge), via the game adapter's key state.
function Session:key_pressed(vk)
    if vk == nil or vk <= 0 or self.game.is_key_down == nil then return false end
    local down = self.game:is_key_down(vk)
    local was = self.keys_down[vk]
    self.keys_down[vk] = down
    return down and not was
end

function Session:game_focused()
    return self.game.window_focused == nil or self.game:window_focused() ~= false
end

-- True when the Ashley key was tapped: pressed and released within TAP_MAX seconds, with no
-- shortcut key (Tab, F4, Enter, Esc) pressed meanwhile, and the game still has the focus
-- TAP_SETTLE seconds later (REFramework clears its keys when the game loses the focus, so an
-- Alt+Tab looks like a tap). Alt also zooms a scope: a press while our player aims does not
-- count.
function Session:ashley_key_tapped(now)
    local vk = self.settings.ashley_key
    if vk == nil or vk <= 0 or self.game.is_key_down == nil then return false end
    local down = self.game:is_key_down(vk)
    local t = self.ashley_tap
    if down then
        if t == nil then
            t = { since = now, spoiled = self.local_aiming == true }
            self.ashley_tap = t
        end
        for _, k in ipairs(SHORTCUT_KEYS) do
            if self.game:is_key_down(k) then t.spoiled = true end
        end
        if self.local_aiming then t.spoiled = true end
        return false
    end
    self.ashley_tap = nil
    if t ~= nil and not t.spoiled and now - t.since <= TAP_MAX and self:game_focused() then
        self.ashley_tap_at = now
    end
    local at = self.ashley_tap_at
    if at == nil then return false end
    if not self:game_focused() then
        self.ashley_tap_at = nil
    elseif now - at >= TAP_SETTLE then
        self.ashley_tap_at = nil
        return true
    end
    return false
end

function Session:handle_hotkeys(now)
    local s = self.settings
    if self.ashley_sync ~= nil and self:ashley_key_tapped(now) then self.ashley_sync:request(now) end
    local teleport = self:key_pressed(s.teleport_key)
    local snooze = self:key_pressed(s.snooze_key)
    -- The teleport key works at any time; the left-behind prompt only reminds of it.
    if teleport and self.left_behind ~= nil and self.left_behind.partner_waiting == "chapter" then
        if self.left_behind.can_follow then
            self:add_message("Loading your partner's chapter...", "warn")
            self:travel_to_partner()
        else
            self:add_message("Your partner is already in the next chapter - finish this one to join them", "warn")
        end
    elseif teleport then
        self:request_teleport(now)
    elseif self.left_behind ~= nil then
        if snooze and self.left_behind.partner_waiting == nil then
            self.prompt_snoozed_until = now + 120
            self.left_behind = nil
            self:add_message("Teleport prompt hidden for 2 minutes", "info")
        end
    end
end

-------------------------------------------------------------------------------
-- Status for UI/HUD
-------------------------------------------------------------------------------

function Session:status()
    local stats = self.net.stats()
    local now = self.clock()
    local st = {
        role = self.role,
        state = stats.state,
        partner_name = self.partner_name,
        rtt_ms = stats.rtt_ms,
        stats = stats,
        compatible = self.compatible,
        partner_area = self.partner_hello and self.partner_hello.area or nil,
        partner_age = self.interp:age(now),
        last_error = self.last_error,
        local_stage = self.local_stage,
        avatar_tx = self.avatar_tx.counters,
        avatar_rx = self.avatar_rx.counters,
        partner_character = self.avatar_rx.avatar and self.avatar_rx.avatar.char_id or nil,
        local_chapter = self.local_chapter,
        partner_chapter = self.partner_state and self.partner_state.chapter or nil,
        gate = self.gate:summary(now),
        transition = self.local_transition or nil,
        screen = self.screen_watch:summary(now),
        continue_key_name = Session.key_name(self.settings.continue_key),
        world_sync_pending = self.world_sync_pending ~= nil,
    }
    local remote = self.interp:sample(now)
    if remote ~= nil then
        st.partner_pos = remote.pos
        st.partner_hp = remote.hp
        st.partner_max_hp = remote.max_hp
        st.partner_flags = remote.flags
        st.partner_stage = remote.stage
        local mine = self.last_local_pos
        if mine ~= nil then
            local dx, dy, dz = remote.pos.x - mine.x, remote.pos.y - mine.y, remote.pos.z - mine.z
            st.partner_distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        end
    end
    if self.enemy_net then
        st.enemies = self.enemy_net:summary()
        st.partner_hits = self.enemy_net:recent_partner_hits(now, TRACER_SECONDS)
    end
    if self.partner_target then
        st.partner_target = self.partner_target:summary()
        st.grab = st.partner_target.grab
        if self.game.partner_stats then
            local stats, attached = self.game:partner_stats()
            st.partner_target.game = stats
            st.partner_target.game_attached = attached
        end
    end
    if self.drop_sync then
        st.drops = self.drop_sync:summary()
    end
    if self.ashley_sync then st.ashley = self.ashley_sync:summary(now) end
    if self.world ~= nil then
        if self.flag_sync then st.flags = self.flag_sync:summary() end
        if self.gimmick_sync then st.gimmicks = self.gimmick_sync:summary() end
        if self.object_sync then st.objects = self.object_sync:summary() end
        if self.animal_sync then st.animals = self.animal_sync:summary() end
        if self.cutscene_sync then st.cutscenes = self.cutscene_sync:summary() end
        if self.trigger_sync then st.triggers = self.trigger_sync:summary() end
        if self.door_sync then st.doors = self.door_sync:summary() end
        if self.trap_sync then st.traps = self.trap_sync:summary() end
        if self.mechanism_sync then st.mechanisms = self.mechanism_sync:summary() end
        if self.purpose_sync then st.purposes = self.purpose_sync:summary() end
        if self.give_sync then
            st.gives = self.give_sync:summary()
            st.give_waiting = self.give_sync:waiting_items()
        end
        if self.world.counters then st.world_events = self.world.counters end
        st.world_last_not_event = self.world.last_not_event
        if self.travel then st.travel = self.travel:status() end
        -- Joining at the host's place: the armed spawn, what the last one did, an in-game load.
        st.join = { spawn_armed = self.world.spawn_armed ~= nil and self.world:spawn_armed() or false,
            spawn_last = self.world.spawn_last, ingame_load = self.game.ingame_loading,
            host_spot = self.host_spot and { chapter = self.host_spot.chapter, stage = self.host_spot.stage } or nil }
    end
    if self.pause and self.pause.status then st.pause = self.pause:status() end
    if self.save_sync then
        st.saves = self.save_sync:summary()
        st.saves.game = self.game.save_counters
    end
    st.items = self.item_sync:summary()
    if self.lobby then st.lobby = self.lobby:summary() end
    st.left_behind = self.left_behind
    st.teleport_key_name = Session.key_name(self.settings.teleport_key)
    st.snooze_key_name = Session.key_name(self.settings.snooze_key)
    st.ashley_key_name = Session.key_name(self.settings.ashley_key)
    return st
end

-- Interpolated partner PLAYER state (position, HP, flags) for the name tag, or nil.
function Session:partner_render_state()
    if not self.partner_connected then return nil end
    local now = self.clock()
    local age = self.interp:age(now)
    if age == nil or age > 3.0 then return nil end
    return self.interp:sample(now)
end

-- The partner's character for the 3D model: { avatar, gear, pose } or nil.
function Session:partner_avatar(now)
    if not self.partner_connected or not self.compatible then return nil end
    now = now or self.clock()
    local st = self.avatar_rx:state(now)
    if st ~= nil and st.pose ~= nil then
        local age = self.avatar_rx:age(now)
        if age == nil or age > 3.0 then st.pose = nil end -- frozen partner: hide, keep the model
    end
    return st
end

-- True when both games know their chapter and they differ: the partner's model would
-- stand in the wrong map.
function Session:partner_elsewhere()
    local m = self.partner_state
    if m == nil or m.area_hash == nil then return false end
    local mine = self.game:area_name()
    local unknown = P.hash("")
    if mine == nil or mine == "" or m.area_hash == unknown then return false end
    return m.area_hash ~= P.hash(mine)
end

-- Sounds/effects/shots due now on the partner's (delayed) timeline.
function Session:take_partner_events(now)
    if not self.partner_connected or not self.compatible then return EMPTY end
    return self.avatar_rx:take_events(now or self.clock())
end

-------------------------------------------------------------------------------
-- Per-frame work
-------------------------------------------------------------------------------

function Session:send_hello(want_reply)
    self:send(P.encode_hello({
        name = self.settings.player_name,
        area = self.game:area_name() or "",
        flags = want_reply and P.HELLO_FLAGS.WANT_REPLY or 0,
    }), true)
end

function Session:handle_event(ev, now)
    if ev.type == "connected" then
        self.partner_connected = true
        self.partner_name = ev.name
        self.interp:clear()
        self.avatar_tx:reset()
        self.avatar_rx:reset()
        self.reassembler = P.new_reassembler()
        for _, name in ipairs(SYNC_NAMES) do
            if self[name] then self[name]:reset() end
        end
        if self.save_sync then self.save_sync:reset() end
        self:add_message(("%s connected (%s)"):format(ev.name or "Partner", ev.peer or "?"), "good")
        self:send_hello()
        if self.lobby then self.lobby:on_connected() end
        -- The client joins the host's game: go where the host is, with the host's world.
        if self.role == "client" and self.world ~= nil then
            if self.settings.auto_travel ~= false and self.travel ~= nil then
                self.join_travel_pending = true
            else
                self.sync_on_join = true -- no travel, but still take over the host's world state
            end
        elseif self.role == "client" and self.settings.sync_enemies ~= false then
            -- No shared world here, but the enemies dead in the host's world still matter.
            self:send(P.encode_world_request(0, P.WORLD.ENEMIES), true)
        end
    elseif ev.type == "disconnected" or ev.type == "rejected" then
        local who = self.partner_name or "Partner"
        local was_connected = self.partner_connected
        if self.give_sync then self.give_sync:partner_left(now) end
        if self.lobby then self.lobby:on_disconnected(now) end
        self:reset_peer()
        if ev.type == "rejected" then
            self.last_error = ev.data
            self:add_message("Join rejected: " .. tostring(ev.data), "error")
        elseif was_connected then
            self:add_message(("%s disconnected: %s"):format(who, tostring(ev.data)), "error")
        else
            self.last_error = ev.data
            self:add_message(tostring(ev.data), "error")
        end
        self.ai_restore_pending = true -- on the game thread (this may run on the render thread)
        if self.role == "client" then
            self.role = "none"
            self:make_syncs()
        end
    elseif ev.type == "message" then
        -- Our game is changing chapter or reloading: what would touch its world waits until it
        -- plays again, as while the game loop is not running (state that is resent anyway,
        -- like enemy snapshots, goes through).
        if not self:defer_in_transition(ev.data) then self:handle_message(ev.data, now) end
    end
end

-- Keeps a message that touches the world for after our transition; true if it was kept.
function Session:defer_in_transition(data)
    if not self.local_transition or type(data) ~= "string" or #self.deferred >= MAX_DEFERRED then return false end
    local t = data:byte(1)
    if t == nil or not (DEFER[t] or t == P.T.DOORS) then return false end
    self.deferred[#self.deferred + 1] = data
    return true
end

-- Host: a joining client wants our whole world.
function Session:on_world_request(m)
    local world, s = self.world, self.settings
    local n_groups, n_gimmicks = 0, 0
    if world ~= nil then
        if (m.what & P.WORLD.FLAGS) ~= 0 and s.sync_flags ~= false then
            n_groups = self.flag_sync:send_full(m.sync_id, world)
        end
        if (m.what & P.WORLD.GIMMICKS) ~= 0 and s.sync_gimmicks ~= false then
            n_gimmicks = self.gimmick_sync:send_full(m.sync_id, world)
        end
        if (m.what & P.WORLD.OBJECTS) ~= 0 and s.sync_objects ~= false then
            self.object_sync:send_history()
        end
    end
    -- Enemies: the list of every enemy dead in our world follows in a moment (reading our
    -- save's backups takes a few ticks).
    if (m.what & P.WORLD.ENEMIES) ~= 0 and s.sync_enemies ~= false and self.enemy_net then
        self.enemy_net:request_graveyard(self.clock())
    end
    if m.sync_id == 0 then return end -- an enemies-only request (no shared world on the client)
    self:send(P.encode_world_done(m.sync_id, m.what, n_groups, n_gimmicks), true)
    self:add_message(("Sent the world state to %s (%d flag groups, %d gimmicks)")
        :format(self.partner_name or "partner", n_groups, n_gimmicks), "info")
end

function Session:handle_message(data, now)
    local m, err = P.decode(data)
    if m == nil then
        self:log("dropped message: %s", tostring(err))
        return
    end
    local T = P.T
    if m.type == T.FRAG then
        local full = self.reassembler:push(m)
        if full ~= nil and not self:defer_in_transition(full) then
            self:handle_message(full, now)
        end
        return
    end
    if m.type == T.HELLO then
        self.partner_hello = m
        self.partner_name = m.name ~= "" and m.name or self.partner_name
        -- A HELLO means the partner (re)started its session state: describe our character
        -- again, expect theirs again, and re-introduce ourselves if it asked.
        self.avatar_tx:reset()
        self.avatar_rx:reset()
        if m.flags ~= nil and (m.flags & P.HELLO_FLAGS.WANT_REPLY) ~= 0 then
            self:send_hello(false)
        end
        if m.version ~= P.VERSION then
            self.compatible = false
            self:add_message(("Partner runs re4coop %s (protocol %d) but you run %s (protocol %d) - update both to the same version")
                :format(m.mod_version, m.version, P.MOD_VERSION, P.VERSION), "error")
        else
            self.compatible = true
            local mine = self.game:area_name() or ""
            if m.area ~= "" and mine ~= "" and m.area ~= mine and not self.join_travel_pending then
                self:add_message(("Partner is in '%s', you are in '%s' - load the same chapter"):format(m.area, mine), "warn")
            end
        end
        return
    end
    if not self.compatible then return end

    if m.type == T.PLAYER then
        local prev = self.partner_state
        self.partner_state = m
        self.interp:push(m.time, now, m)
        -- Where the partner stands in play (not dead, in a cutscene or a transition): the place a
        -- joining client's game loads and puts it at.
        local busy = P.PLAYER_FLAGS.DEAD | P.PLAYER_FLAGS.CUTSCENE
        if (m.flags & busy) == 0 and m.stage ~= nil and m.chapter ~= nil then
            self.host_spot = { chapter = m.chapter, stage = m.stage, pos = m.pos, rot = m.rot, at = now }
        end
        local dead = (m.flags & P.PLAYER_FLAGS.DEAD) ~= 0
        if prev ~= nil and dead and (prev.flags & P.PLAYER_FLAGS.DEAD) == 0 then
            self:add_message((self.partner_name or "Partner") .. " is down!", "error")
        end
    elseif m.type == T.CHAT then
        self:add_message(("%s: %s"):format(self.partner_name or "Partner", m.text), "chat")
    elseif m.type == T.NOTIFY then
        self:add_message(m.text, "info")
    elseif m.type == T.ITEM_GIVE or m.type == T.ITEM_GIVE_RESULT then
        if self.give_sync then self.give_sync:on_message(m, now) end
    elseif m.type == T.SAVE then
        if self.save_sync then self.save_sync:on_message(m, now) end
    elseif LOBBY_TYPES[m.type] then
        if self.lobby then self.lobby:on_message(m, now, self:menu_open()) end
    elseif m.type == T.ITEM_TAKEN then
        self.item_sync:on_message(m, now)
    elseif m.type == T.ITEM_DROPPED then
        return -- 0.5/0.6 host-rolled drops: each player rolls their own loot now
    elseif m.type == T.WORLD_REQUEST then
        if self.role == "host" then self:on_world_request(m) end
    elseif m.type == T.WORLD_DONE then
        if self.role == "client" and m.sync_id == self.world_sync_pending then
            self.world_sync_pending = nil
            self.world_synced = true
            self:add_message(("World synchronised with the host (%d flag groups, %d gimmicks)")
                :format(m.n_flag_groups, m.n_gimmicks), "good")
            if self.travel then self.travel:sync_done() end
        end
    elseif m.type == T.FLAGS or m.type == T.FLAG_WORDS then
        if self.flag_sync and self.world then self.flag_sync:on_message(m, now, self.world) end
    elseif m.type == T.GIMMICKS then
        if self.gimmick_sync and self.world then self.gimmick_sync:on_message(m, now) end
    elseif m.type == T.OBJECTS then
        if self.object_sync and self.world then self.object_sync:on_message(m, now, self.world) end
    elseif m.type == T.ANIMALS then
        if self.animal_sync and self.world then self.animal_sync:on_message(m, now) end
    elseif m.type == T.CUTSCENE or m.type == T.CUTSCENE_SKIP then
        if self.cutscene_sync and self.world then self.cutscene_sync:on_message(m, now) end
    elseif m.type == T.DOORS then
        if self.door_sync and self.world then self.door_sync:on_message(m, now, self.world) end
    elseif m.type == T.TRAPS then
        if self.trap_sync and self.world then self.trap_sync:on_message(m, now, self.world) end
    elseif m.type == T.MECHANISMS then
        if self.mechanism_sync and self.world then self.mechanism_sync:on_message(m, now) end
    elseif m.type == T.TRIGGER then
        if self.trigger_sync and self.world then self.trigger_sync:on_message(m, now) end
    elseif m.type == T.PURPOSE then
        if self.purpose_sync and self.world then self.purpose_sync:on_message(m, now) end
    elseif m.type == T.ASHLEY or m.type == T.ASHLEY_OWNER or m.type == T.ASHLEY_SWITCH or m.type == T.ASHLEY_BANKS then
        if self.ashley_sync then self.ashley_sync:on_message(m, now) end
    elseif self.avatar_rx:on_message(m, now) then
        return
    elseif m.type == T.PLAYER_NOISE or m.type == T.PLAYER_DAMAGE or m.type == T.ACTION_SIGN or m.type == T.ENEMY_PARRY
        or m.type == T.PLAYER_GRAB or m.type == T.GRAB_ESCAPE then
        if self.partner_target then self.partner_target:on_message(m, now, self.game) end
    elseif self.enemy_net and self.settings.sync_enemies then
        self.enemy_net:on_message(m, now, self.game)
    end
end

function Session:send_player_state(now)
    local st = self.game:read_player_state()
    if st == nil then
        self.player_missing_since = self.player_missing_since or now
        return
    end
    -- A new player context, or a long gap without one, means the game (re)loaded: a
    -- checkpoint brought the enemies back.
    local reloaded = (st.id ~= nil and self.player_id ~= nil and st.id ~= self.player_id)
        or (self.player_missing_since ~= nil and now - self.player_missing_since >= RELOAD_GAP)
    self.player_missing_since = nil
    if st.id ~= nil then self.player_id = st.id end
    if reloaded then self:on_reload(now) end

    self.last_local_pos = st.pos
    self.last_local_rot = st.rot
    self.last_local_pos_time = now
    self.local_aiming = st.aiming and true or false
    self.local_cutscene = st.cutscene and true or false
    self.local_transition = st.transition and true or false
    self.local_stage = st.stage
    self.local_chapter = st.chapter
    self:watch_teleport(now, st.pos)

    local flags = 0
    if st.dead then flags = flags | P.PLAYER_FLAGS.DEAD end
    -- To the partner a transition of ours (a chapter change, a game over) is an event: their
    -- gate does not wait for us, nobody teleports to us and their enemies leave us alone.
    if st.cutscene or st.transition then flags = flags | P.PLAYER_FLAGS.CUTSCENE end
    if st.aiming then flags = flags | P.PLAYER_FLAGS.AIMING end
    if self.gate.holding ~= nil then flags = flags | P.PLAYER_FLAGS.GATE_WAITING end
    if self.settings.invincible == true then flags = flags | P.PLAYER_FLAGS.INVINCIBLE end

    self:send(P.encode_player({
        time = now,
        pos = st.pos,
        rot = st.rot or { x = 0, y = 0, z = 0, w = 1 },
        hp = st.hp, max_hp = st.max_hp,
        flags = flags,
        area_hash = P.hash(self.game:area_name() or ""),
        stage = st.stage,
        chapter = st.chapter,
    }), false)

    if st.dead and not self.local_dead then
        self:send(P.encode_notify(NOTIFY.DIED, self.settings.player_name .. " is down!"), true)
    end
    self.local_dead = st.dead and true or false
end

-- Poses per second to send: the full rate while the partner can see us up close, half
-- beyond POSE_FAR metres, and a trickle while they are in another chapter (reading ~350
-- joints is the biggest cost of sharing our character).
local POSE_FAR = 40.0
local POSE_ELSEWHERE_HZ = 5

function Session:pose_rate(now)
    local full = self.settings.pose_hz or 30
    if self:partner_elsewhere() then return POSE_ELSEWHERE_HZ end
    local partner = self.interp:sample(now)
    local mine = self:fresh_local_pos(now)
    if partner ~= nil and mine ~= nil and dist3(partner.pos, mine) > POSE_FAR then
        return math.max(10, full / 2)
    end
    return full
end

-- The game (re)loaded: cached engine objects and half-done work belong to the old scene.
function Session:on_reload(now)
    self.perf:crumb("session.reload", nil, true)
    if self.game.on_reload then self.game:on_reload() end
    if self.world and self.world.on_reload then self.world:on_reload() end
    if self.enemy_net then self.enemy_net:on_local_reload() end
    if self.animal_sync then self.animal_sync:on_local_reload() end
    if self.drop_sync then self.drop_sync:forget_enemies() end
    self.in_game_since = now
    -- Client: a checkpoint brought back enemies the host has killed since, and put our story
    -- flags and doors behind the host's. Take the host's world again (once it has been taken
    -- over before; joining and travelling ask on their own).
    if self.role == "client" and self.partner_connected and self.compatible and self.world_synced
        and self.world_sync_pending == nil and not self.join_travel_pending
        and (self.travel == nil or not self.travel:busy()) then
        local partner = self.partner_state
        local mine = self.world and self.world:location() or nil
        if partner ~= nil and (partner.chapter == nil or mine == nil or mine.chapter == nil
            or partner.chapter == mine.chapter) then
            self:add_message("Your game reloaded - taking over the host's world again", "info")
            self:request_world_sync()
        end
    end
end

-- Both players' positions: our position decides how enemies dead in the partner's world go,
-- and the host sends the animals near both (the partner only counts in the same region).
function Session:players_info(now)
    local local_pos = self:fresh_local_pos(now)
    local remote = self.interp:sample(now)
    local age = self.interp:age(now)
    if local_pos == nil then return nil end
    -- (our area still loading: no enemy is spawned for the partner's world)
    local loc = self.local_loc
    local loading = loc ~= nil and (loc.loading == true or loc.playable == false)
    if remote == nil or age == nil or age > 2.0 then return { local_pos = local_pos, loading = loading } end
    if remote.stage ~= nil and self.local_stage ~= nil and remote.stage // 1000 ~= self.local_stage // 1000 then
        -- another region: the partner is not near our enemies
        return { local_pos = local_pos, loading = loading, other_region = true }
    end
    return { local_pos = local_pos, partner_pos = remote.pos, loading = loading }
end

-- Host: the client's character in our world, for partner_target.lua: its model (puppet.lua,
-- built from the body prefab and shown), where the client is and their HP, and whether they can
-- be fought (not in a cutscene or dead-and-gone, in our area). nil without a fresh partner state.
function Session:partner_target_info(now)
    local remote = self.interp:sample(now)
    local age = self.interp:age(now)
    if remote == nil or age == nil or age > 2.0 then return nil end
    local flags = remote.flags or 0
    local model = self.partner_model
    local root = model ~= nil and model.target_root ~= nil and model:target_root() or nil
    local loc = self.local_loc
    return {
        root = root, pos = remote.pos, rot = remote.rot, hp = remote.hp, max_hp = remote.max_hp,
        busy = (flags & P.PLAYER_FLAGS.CUTSCENE) ~= 0,
        elsewhere = self:partner_elsewhere(),
        loading = loc ~= nil and (loc.loading == true or loc.playable == false),
    }
end

-- Invincibility (a testing option): our player is invincible while our Options or the
-- connected partner's ask for it (game_invincible.lua), also playing alone.
function Session:update_invincible()
    local game = self.game
    if game.set_invincible == nil then return end
    local mine = self.settings.invincible == true
    local theirs = self.partner_connected == true and self.partner_state ~= nil
        and ((self.partner_state.flags or 0) & P.PLAYER_FLAGS.INVINCIBLE) ~= 0
    local want = mine or theirs
    if not want and not self.invincible_wanted then return end
    if want ~= self.invincible_wanted then
        self.invincible_wanted = want
        if want then
            self:add_message(theirs and not mine and "Invincibility on (your partner turned it on)"
                or "Invincibility on (both players)", "info")
        else
            self:add_message("Invincibility off", "info")
        end
    end
    local ok, on = pcall(game.set_invincible, game, want)
    self.invincible_on = ok and on == true
end

-- No-pause: while hosting or connected, menus do not freeze the world (see game_pause.lua).
function Session:update_pause()
    if self.pause == nil or self.pause.set_active == nil then return end
    local s = self.settings
    local active = s.no_pause ~= false and self.role ~= "none" and self.net.state() ~= "idle"
    self.pause:set_active(active, s.no_pause_mode or "menus", s.no_pause_aggressive == true, self.clock())
end

-- Where we are (chapter, stage, playable), refreshed a few times per second.
function Session:refresh_location(now)
    if self.world == nil or now - self.last_location < LOCATION_INTERVAL then return end
    self.last_location = now
    self.local_loc = self.world:location()
end

-- Where something happens to us right now: chapter, stage and state of the last location
-- read, with our freshest position (an event starts where the player stands).
function Session:event_location()
    local loc = self.local_loc
    if loc == nil then return nil end
    local pos = self:fresh_local_pos(self.clock()) or loc.pos
    return { chapter = loc.chapter, stage = loc.stage, pos = pos, loading = loc.loading, playable = loc.playable,
        cutscene = loc.cutscene }
end

-- Shared world: flags, gimmicks, breakables, cutscenes; joining and following the host.
function Session:update_world(now)
    local world, s = self.world, self.settings
    if world == nil or self.flag_sync == nil then return end

    if self.local_transition then
        -- Our game is changing chapter or reloading (docs/RESEARCH.md 3.33): the partner's
        -- world waits until it plays again - their flags are held, and nothing is applied,
        -- replayed, saved or travelled to in the middle of the game's own loading.
        self.flag_sync:hold(now, TRANSITION_FLAG_HOLD)
        self.cutscene_sync:tick(now, world, self.local_loc, self.travel)
        self.travel:tick(now, world, self:partner_location())
        return
    end

    if world.update then world:update() end
    self.flag_sync:tick(now, world)
    self.gimmick_sync:tick(now, world)
    -- Animal sync finds the animals in the breakables' scan.
    local animals = s.sync_animals ~= false and world.animals_near ~= nil
    self.object_sync:tick(now, world, self:fresh_local_pos(now), animals)
    if world.animals_near ~= nil then self.animal_sync:tick(now, world, self:players_info(now)) end
    self.cutscene_sync:tick(now, world, self.local_loc, self.travel)
    self.trigger_sync:tick(now, world, self:event_location())
    self.door_sync:tick(now, world, self:fresh_local_pos(now))
    self.trap_sync:tick(now, world, self:fresh_local_pos(now))
    local loc = self.local_loc
    self.mechanism_sync:tick(now, world, self:fresh_local_pos(now) ~= nil
        and (loc == nil or (not loc.loading and loc.playable ~= false)), loc ~= nil and loc.loading == true)
    self.purpose_sync:tick(now, world, { chapter = loc and loc.chapter or self.local_chapter,
        ready = self:fresh_local_pos(now) ~= nil and not self.local_cutscene
            and (loc == nil or (not loc.loading and loc.playable ~= false)) })

    local partner = self:partner_location()
    if self.role == "client" and self.sync_on_join and partner ~= nil and self.local_loc ~= nil then
        local same = partner.chapter == nil or self.local_loc.chapter == nil or self.local_loc.chapter == partner.chapter
        if same then
            self.sync_on_join = false
            self:request_world_sync()
        end
    end
    if self.role == "client" and partner ~= nil and not self.travel:busy() then
        if self.join_travel_pending then
            -- Joining: load the host's chapter if needed, take over its world, then warp to it.
            -- In the menus (no player yet) the join's own load runs first (on_menu): it needs
            -- the join still pending to happen, and it already loads the host's place.
            if self:fresh_local_pos(now) == nil then
                if s.auto_load_on_join == false and partner.chapter ~= nil then
                    -- The player loads a save themself: it goes into the host's chapter and place.
                    world:arm_chapter_switch(partner.chapter)
                    if world.arm_spawn and not world:spawn_armed() then world:arm_spawn() end
                end
            elseif self.travel:request({ chapter = partner.chapter, stage = partner.stage, pos = partner.pos,
                yaw = partner.yaw, reason = "join", sync = true, follow = true }) then
                self.join_travel_pending = false
                self:add_message("Joining your partner's game...", "info")
            end
        elseif s.follow_host_chapter ~= false and self.local_loc ~= nil and self.local_loc.playable
            and partner.chapter ~= nil and self.local_chapter ~= nil and partner.chapter > self.local_chapter
            and self.gate.holding == nil then
            -- The host moved on to a later chapter and we did not get there ourselves: follow.
            self.chapter_ahead_since = self.chapter_ahead_since or now
            if now - self.chapter_ahead_since >= FOLLOW_CHAPTER_DELAY then
                self.chapter_ahead_since = nil
                self.travel:request({ chapter = partner.chapter, stage = partner.stage, pos = partner.pos,
                    yaw = partner.yaw, reason = "join", sync = true, follow = true })
                self:add_message("Your partner moved on to the next chapter - following", "warn")
            end
        else
            self.chapter_ahead_since = nil
        end
    end
    self.travel:tick(now, world, partner)
end

-- What the game side must undo once the session ended or the partner left (queued by
-- leave() / the disconnect event, which may run off the game thread).
function Session:apply_pending_restores()
    if self.restore_pending then
        self.restore_pending = false
        self.ai_restore_pending = false
        self:restore_game()
    elseif self.ai_restore_pending then
        self.ai_restore_pending = false
        if self.game.restore_enemies then self.game:restore_enemies() end
        if self.game.ashley_restore then self.game:ashley_restore() end
        if self.world and self.world.restore_animals then self.world:restore_animals() end
    end
end

-- Whether our game may save for the partner now: playing (no cutscene, loading screen or
-- death) for a moment; the client also holds the host's world (not joining or travelling).
function Session:can_save_now(now)
    local loc = self.local_loc
    if self:fresh_local_pos(now) == nil or self.local_cutscene or self.local_dead then return false end
    if loc ~= nil and (loc.loading or loc.playable == false) then return false end
    if now - (self.in_game_since or now) < SETTLE_AFTER_LOAD then return false end
    if self.role == "client" then
        if self.world ~= nil and (not self.world_synced or self.world_sync_pending ~= nil) then return false end
        if self.join_travel_pending or (self.travel ~= nil and self.travel:busy()) then return false end
    end
    return true
end

-- Every frame the game shows its title screen or main menu (where = "title" | "menu"), from
-- the game's own update: true asks the game to load a save now (the client joining a host
-- who is playing loads straight into the host's game).
function Session:on_menu(where)
    local now = self.clock()
    self.menu_where, self.menu_time = where, now
    if self.save_sync == nil then return false end
    -- A game the lobby starts loads the way the lobby says; in the lobby, nothing loads on its
    -- own (unless the client chose to join the host's game in progress).
    local lobby = self.lobby
    if lobby ~= nil and (lobby.start ~= nil or (lobby:is_open() and not lobby.join_running)) then return false end
    local age = self.interp:age(now)
    local partner_in_game = self.partner_state ~= nil and age ~= nil and age < HOST_PLAYING_AGE
    local joining = self.role == "client" and self.partner_connected and self.compatible
        and (self.join_travel_pending or self.sync_on_join)
    local chapter = self.partner_state and self.partner_state.chapter
    local action = self.save_sync:menu_tick(now, { joining = joining, partner_in_game = partner_in_game, where = where,
        can_start_new = where == "menu" and self.game.menu_start_new ~= nil and Lobby.head_key_of_id(chapter) ~= nil },
        self.game)
    if action ~= nil and self.join_travel_pending and self.world ~= nil and self.travel ~= nil and chapter ~= nil then
        if action == "continue" then self.world:arm_chapter_switch(chapter) end -- into the host's chapter
        -- The game loads the host's part of the map and puts us at the host's place.
        if self.world.arm_spawn then self.world:arm_spawn() end
    end
    if action == "new" then self.join_new = { at = now, chapter = chapter } end
    return action == "continue"
end

-- Client: where the host last stood in play, for the next game we load (game_world.lua spawn):
-- { chapter, stage, pos, rot } or nil (unknown, or the host has changed chapter since).
function Session:host_spawn_spot()
    if self.role ~= "client" then return nil end
    local s = self.host_spot
    if s == nil then return nil end
    local cur = self.partner_state
    if cur ~= nil and cur.chapter ~= nil and cur.chapter ~= s.chapter then return nil end
    return { chapter = s.chapter, stage = s.stage, pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
        rot = s.rot and { x = s.rot.x, y = s.rot.y, z = s.rot.z, w = s.rot.w } or nil }
end

-- Client: the save an in-game reload into the host's game loads: our co-op save with the host,
-- else the save we loaded this time, else the newest.
function Session:reload_slot()
    local g = self.game
    if g == nil or g.save_exists == nil then return nil end
    local coop = self.save_sync and self.save_sync:coop_slot()
    if coop ~= nil and g:save_exists(coop) then return coop end
    local last = g.last_loaded_slot and g:last_loaded_slot()
    if last ~= nil and g:save_exists(last) then return last end
    return g.continue_save_slot and g:continue_save_slot() or nil
end

-- Client: the host's player is in its game (its PLAYER stream is fresh; in its lobby or the
-- menus it has no player), not in its lobby.
function Session:host_playing(now)
    if self.role ~= "client" or not (self.partner_connected and self.compatible) or self.partner_state == nil then
        return false
    end
    local age = self.interp:age(now)
    if age == nil or age >= HOST_PLAYING_AGE then return false end
    local p = self.lobby and self.lobby.partner
    return p == nil or not p.in_lobby
end

-- Client joining from the main menu without any save: a new game at the start of the host's
-- chapter part, once the main menu waits for a choice (it comes back at the host's place).
function Session:update_join(now)
    local j = self.join_new
    if j == nil then return end
    if self.role ~= "client" or not (self.partner_connected and self.compatible) then
        self.join_new = nil
        return
    end
    if now - j.at > JOIN_NEW_TIMEOUT then
        self.join_new = nil
        self:add_message("Could not start a new game to join your partner - start one yourself (New Game)", "warn")
        return
    end
    local g = self.game
    local ok_st, st = pcall(g.menu_status, g)
    if not ok_st or st == nil or not st.ready then return end
    self.join_new = nil
    local key = Lobby.head_key_of_id(j.chapter) or 1
    local remote = self.lobby and self.lobby.remote
    local difficulty = remote and remote.difficulty
    if not Lobby.difficulty_valid(difficulty) then difficulty = self.settings.lobby_difficulty end
    if not Lobby.difficulty_valid(difficulty) then difficulty = 20 end
    if self.world and self.world.arm_spawn then self.world:arm_spawn() end
    local ok, why = g:menu_start_new(key, difficulty)
    if not ok then
        self:add_message("Could not start a new game to join your partner: " .. tostring(why), "warn")
    end
end

-- Reliable world/enemy messages received while the game loop was not running. They are
-- applied once the game has been playable for SETTLE_AFTER_LOAD seconds, right after a fresh
-- enemy list, so nothing they touch comes from before the load.
function Session:apply_deferred(now)
    if #self.deferred == 0 then return end
    if self:fresh_local_pos(now) == nil or now - (self.in_game_since or now) < SETTLE_AFTER_LOAD then return end
    local deferred = self.deferred
    self.deferred = {}
    self.perf:crumb("session.deferred", ("%d messages"):format(#deferred))
    for _, data in ipairs(deferred) do
        self:handle_message(data, now)
    end
end

-------------------------------------------------------------------------------
-- The lobby (lobby.lua): the "Multijugador" section of the game's main menu, the lobby
-- screen and the synchronized start
-------------------------------------------------------------------------------

-- The game's main menu list is up (the lobby can show over it).
function Session:menu_open()
    local g = self.game
    if g == nil or g.menu_status == nil then return false end
    local ok, st = pcall(g.menu_status, g)
    return ok and st ~= nil and st.open == true
end

-- One of our entries was chosen in the game's menu (from the game's own decision call).
function Session:on_menu_decide(action)
    local effect = self.lobby:on_menu_decide(action)
    if effect == "host" then
        if self.role == "none" then
            Config.sanitize(self.settings)
            if not self:host() then
                self.lobby:close() -- the error is in the messages; back to the section
            end
        elseif self.role == "client" then
            self:add_message("Ya estás unido a una partida: sal de ella antes de crear una sala", "warn")
            self.lobby:close()
        else
            self.lobby:on_connected() -- already hosting: the lobby greets the partner we have
        end
    end
end

-- Client: our game holds the host's world and stands next to the host (or has nothing to take over).
function Session:lobby_synced()
    if self.role ~= "client" then return true end
    if self.join_travel_pending or self.sync_on_join then return false end
    if self.travel ~= nil and self.travel:busy() then return false end
    return self.world == nil or self.world_synced or self.world_sync_pending == nil
end

-- A start the lobby agreed on: start the game here. a = { role, params, slot }
function Session:run_lobby_action(a, now)
    if a.kind ~= "start" then return end
    local g, p, lobby = self.game, a.params, self.lobby
    local NEW = P.LOBBY_MODE.NEW
    local ok, why
    if g.menu_start_new == nil then
        lobby:start_failed("este juego no tiene menú principal (adaptador)", now)
        return
    end
    self.lobby_chapter_armed = false
    if a.role == "host" then
        self.save_sync:set_host_slot(a.slot) -- the co-op file takes this game's saves
        if p.mode == NEW then
            ok, why = g:menu_start_new(p.key, p.difficulty)
        else
            if p.chapter ~= nil and p.chapter > 0 and self.world ~= nil then
                self.world:arm_chapter_switch(p.chapter_id) -- the save, in the chapter chosen
                self.lobby_chapter_armed = true
            end
            self.save_sync:request_load(a.slot, now)
            ok, why = g:menu_continue(a.slot)
        end
    else
        if p.mode == NEW then
            -- Both games start the same fresh game: there is nothing of the host's to take over.
            self.join_travel_pending, self.sync_on_join = false, false
            self.world_synced = true
            ok, why = g:menu_start_new(p.key, p.difficulty)
        else
            -- Our own progress with the host (its co-op slot) in the host's chapter, then the
            -- usual join: the host's world, next to the host.
            local slot = self.save_sync:coop_slot()
            if self.world ~= nil and p.chapter_id ~= nil and p.chapter_id ~= 0 then
                self.world:arm_chapter_switch(p.chapter_id)
                self.lobby_chapter_armed = true
            end
            if self.world ~= nil then
                if self.settings.auto_travel ~= false and self.travel ~= nil then
                    self.join_travel_pending = true
                else
                    self.sync_on_join = true
                end
            end
            if g:save_exists(slot) then
                self.save_sync:request_load(slot, now)
                ok, why = g:menu_continue(slot)
            else
                -- No co-op save yet: a new game in the host's chapter.
                ok, why = g:menu_start_new(p.key or 1, p.difficulty)
            end
        end
    end
    if not ok then lobby:start_failed(why or "?", now) end
end

-- Every game frame: the game's menu entries, our screens' input, the host's co-op files, the
-- synchronized start and the loadout.
function Session:update_lobby(now)
    local lobby, g = self.lobby, self.game
    if lobby == nil then return end
    if g.menu_tick then g:menu_tick({ mode = lobby.menu_mode, covered = lobby:covers_menu() }) end
    -- A client whose host is already playing goes straight into the host's game.
    if lobby:is_open() and self.role == "client" then lobby:auto_join(now, self:host_playing(now)) end
    if lobby:is_open() then
        if g.gui_commands and not self.ui_text_active then lobby:push_nav(g:gui_commands()) end
        if self.role == "host" and lobby:in_lobby() and g.save_slot_info
            and now - (self.lobby_saves_at or -math.huge) >= LOBBY_SAVES_EVERY then
            self.lobby_saves_at = now
            local infos = {}
            for f = 1, Lobby.FILES do infos[f] = g:save_slot_info(lobby:file_slot(f)) end
            lobby:set_saves(infos)
        end
        if self.weapon_names == nil and g.weapon_name then
            local names = {}
            for _, l in ipairs(Lobby.LOADOUTS) do
                for _, wp in ipairs(l.weapons) do names[wp] = g:weapon_name(wp) end
            end
            self.weapon_names = names
        end
    end
    local a = lobby:take_action()
    while a ~= nil do
        self:run_lobby_action(a, now)
        a = lobby:take_action()
    end
    if lobby.start == nil then
        self.lobby_hold = false
        return
    end
    local in_game = self:fresh_local_pos(now) ~= nil
    local held = self.lobby_hold
    self.lobby_hold = lobby:tick(now, {
        connected = self.partner_connected and self.compatible,
        in_menu = self:menu_open() or (self.menu_time ~= nil and now - self.menu_time < 1.0),
        in_game = in_game,
        loading_screen = g.loading_screen ~= nil and g:loading_screen() or false,
        synced = self:lobby_synced(),
        continue_pressed = held and self:key_pressed(self.settings.continue_key) or false,
    })
    local s = lobby.start
    if s ~= nil and s.released and self.lobby_chapter_armed and self.world ~= nil then
        self.lobby_chapter_armed = false
        self.world:disarm_chapter_switch() -- the load it was for is done
    end
    local loc = self.local_loc
    local playable = in_game and not self.local_cutscene and not self.local_dead
        and (loc == nil or (not loc.loading and loc.playable ~= false))
    local loadout = lobby:take_loadout(now, playable)
    if loadout ~= nil and g.give_loadout then
        local r, why = g:give_loadout(loadout.weapons, Lobby.AMMO_STACKS)
        if r == nil then
            self:add_message("No se pudo dar el equipo inicial: " .. tostring(why), "warn")
        else
            local text = ("Equipo %s: %s"):format(loadout.name, #r.given > 0 and table.concat(r.given, ", ") or "nada")
            if r.full > 0 then text = text .. " (no cupo todo en el maletín)" end
            self:add_message(text, #r.given > 0 and "good" or "warn")
        end
    end
end

-- Network + game sync. Call once per game frame from a game-thread callback.
function Session:update()
    local now = self.clock()
    local perf = self.perf
    if perf.set_tag ~= nil then perf:set_tag((self.role == "host" or self.role == "client") and self.role or nil) end
    self.frame = (self.frame or 0) + 1
    local t0 = perf:start()
    self:run_actions(true)
    -- Our game's own transitions (a chapter change, a game over, a load), every frame: nothing
    -- may act on the game from their first frame on.
    local transition = self.game.in_transition ~= nil and self.game:in_transition() or false
    if transition ~= self.local_transition then
        self.local_transition = transition
        self.last_location = -math.huge -- where we are means something else now: read it again
        perf:crumb("transition", transition and "start" or "end", true)
    end
    self:refresh_location(now)
    for _, ev in ipairs(self.net.poll()) do
        self:handle_event(ev, now)
    end
    self:apply_pending_restores()
    self:update_pause()
    self:update_invincible()
    if self.pause and self.pause.update then self.pause:update(now) end
    local active = self.partner_connected and self.compatible
    local s = self.settings
    if self.game.set_capture then self.game:set_capture(active and s.share_character ~= false) end
    if self.game.set_active then
        self.game:set_active(active, { hits = s.sync_enemies ~= false,
            drops = s.sync_enemies ~= false and s.sync_drops ~= false, gimmicks = s.sync_gimmicks ~= false,
            partner = s.enemy_partner_target ~= false })
    end
    if self.world and self.world.set_active then self.world:set_active(active) end
    if self.give_sync then
        local loc = self.local_loc
        local playable = self:fresh_local_pos(now) ~= nil and not self.local_cutscene
            and (loc == nil or (not loc.loading and loc.playable ~= false))
        self.give_sync:tick(now, self.game, playable)
    end
    if self.save_sync then self.save_sync:tick(now, self.game, self:can_save_now(now)) end
    perf:stop("update.net", t0)
    t0 = perf:start()
    self:update_lobby(now)
    self:update_join(now)
    -- An in-game load into the host's game (travel) leaves the game once the save is read.
    if self.game.ingame_load_tick then self.game:ingame_load_tick() end
    perf:stop("update.lobby", t0)
    if not active then
        -- Game events from before the partner joined are stale by the time we sync.
        if self.game.take_pickup_events then self.game:take_pickup_events() end
        if self.game.take_hit_events then self.game:take_hit_events() end
        if self.game.take_fatal_events then self.game:take_fatal_events() end
        if self.game.take_drop_events then self.game:take_drop_events() end
        if self.game.take_noise_events then self.game:take_noise_events() end
        if self.game.take_partner_damage_events then self.game:take_partner_damage_events() end
        -- No partner: their model is no character of our game.
        if self.game.partner_target_attached and self.game:partner_target_attached() then
            self.game:partner_target_detach()
        end
        if self.partner_target then self.partner_target.attached = false end
        self:update_gate(now) -- releases a hold
        return
    end

    t0 = perf:start()
    local player_interval = 1.0 / (s.player_hz or 20)
    if now - self.last_player_send >= player_interval then
        self.last_player_send = (now - self.last_player_send >= 2 * player_interval) and now or (self.last_player_send + player_interval)
        self:send_player_state(now)
    end
    if self:fresh_local_pos(now) ~= nil then
        self.in_game_since = self.in_game_since or now
    else
        self.in_game_since = nil
    end
    self:update_screen(now)
    perf:stop("update.player", t0)

    if s.share_character ~= false and self.game.avatar_descriptor then
        t0 = perf:start()
        self.avatar_tx.rate = self:pose_rate(now)
        self.avatar_tx:tick(now, self.game)
        perf:stop("update.avatar", t0)
    end

    -- Hits our player landed and enemy loot rolls since the last frame (hooks in game.lua).
    t0 = perf:start()
    local hits = self.game.take_hit_events and self.game:take_hit_events() or nil
    if self.enemy_net and s.sync_enemies and hits ~= nil and #hits > 0 then
        self.enemy_net:on_local_hits(hits, now)
    end
    local fatals = self.game.take_fatal_events and self.game:take_fatal_events() or nil
    if self.enemy_net and s.sync_enemies and fatals ~= nil and #fatals > 0 then
        self.enemy_net:on_local_fatal(fatals, now)
    end
    local drops = self.game.take_drop_events and self.game:take_drop_events() or nil

    local enemies, ticked = nil, false
    local in_game = self:fresh_local_pos(now) ~= nil
    if self.enemy_net and s.sync_enemies and in_game then
        local interval = 1.0 / (s.enemy_tick_hz or 20)
        if now - self.last_enemy_tick >= interval then
            self.last_enemy_tick = (now - self.last_enemy_tick >= 2 * interval) and now or (self.last_enemy_tick + interval)
            local es = self.enemy_net
            enemies = self.game:list_enemies(self:fresh_local_pos(now), function(id) return es:wants_state(id) end)
            if enemies ~= nil then
                ticked = true
                self.enemy_net:tick(now, enemies, self.game, self:players_info(now))
            end
        end
    elseif self.enemy_net and not s.sync_enemies then
        self.enemy_net:release_all(self.game) -- enemy sync switched off: our AI runs everything
    end
    -- The client's player as a second player in the host's game.
    if self.partner_target then
        if self.role == "host" then
            self.partner_target:host_tick(now, self.game, in_game and self:partner_target_info(now) or nil)
        else
            local loc = self.local_loc
            local loading = loc ~= nil and (loc.loading == true or loc.playable == false)
            self.partner_target:client_tick(now, self.game, { playable = in_game and not loading and not self.local_cutscene,
                dead = self.local_dead })
        end
    end
    if self.drop_sync and s.sync_enemies then
        self.drop_sync:update(now, enemies, drops, self.game)
    end
    perf:stop("update.enemies", t0)

    -- Every frame: the host's enemies stand where they are in the host's game (client), and
    -- the client's character stands where the client is (host).
    if self.enemy_net and s.sync_enemies and in_game then
        t0 = perf:start()
        self.enemy_net:frame(now, self.game)
        if self.partner_target and self.role == "host" then
            self.partner_target:host_frame(self.game, self:partner_target_info(now))
        elseif self.partner_target then
            local loc = self.local_loc
            local loading = loc ~= nil and (loc.loading == true or loc.playable == false)
            self.partner_target:client_frame(now, self.game, { playable = not loading and not self.local_cutscene,
                dead = self.local_dead })
        end
        perf:stop("update.mirror", t0)
    end

    if ticked or not s.sync_enemies then self:apply_deferred(now) end

    -- Ashley: one for both games (ashley_sync.lua).
    if self.ashley_sync then
        t0 = perf:start()
        if now - (self.last_ashley_tick or -math.huge) >= 1.0 / 20 then
            self.last_ashley_tick = now
            local loc = self.local_loc
            local loading = loc ~= nil and (loc.loading == true or loc.playable == false)
            self.ashley_sync:tick(now, self.game, { in_game = in_game and not loading,
                local_pos = self:fresh_local_pos(now), local_rot = self.last_local_rot,
                unable = self.local_cutscene or self.local_dead or loading, cutscene = self.local_cutscene })
        end
        if in_game then self.ashley_sync:frame(now, self.game) end
        perf:stop("update.ashley", t0)
    end

    if self.game.list_pickups and now - self.last_item_tick >= ITEM_TICK_INTERVAL and in_game then
        t0 = perf:start()
        self.last_item_tick = now
        local accepted = self.game.take_pickup_events and self.game:take_pickup_events() or nil
        if s.share_key_items then
            local pickups = self.game:list_pickups()
            local pos = self:fresh_local_pos(now)
            local flags = nil
            if self.game.item_get_flags then
                flags = self.game:item_get_flags(self.item_sync:watched_item_ids())
            end
            self.item_sync:tick(now, pickups, pos, self.game, pos ~= nil and not self.local_cutscene,
                accepted, flags)
        end
        perf:stop("update.pickups", t0)
    end

    t0 = perf:start()
    self:update_world(now)
    perf:stop("update.world", t0)
    t0 = perf:start()
    self:update_gate(now)
    self:update_left_behind(now)
    self:handle_hotkeys(now)
    perf:stop("update.gate", t0)
end

-- End of the game frame (PrepareRendering), right after the pose capture: send it now.
function Session:flush_pose(now)
    if not (self.partner_connected and self.compatible) or self.settings.share_character == false then return end
    self.avatar_tx:flush_pose(now, self.game)
end

-- status() for the HUD and the overlay, which ask several times per frame.
function Session:status_cached()
    local now = self.clock()
    local c = self.status_cache
    if c ~= nil and self.status_cache_frame == self.frame and now - self.status_cache_time < STATUS_MAX_AGE then
        return c
    end
    c = self:status()
    self.status_cache, self.status_cache_frame, self.status_cache_time = c, self.frame, now
    return c
end

-- Keeps connect/disconnect events flowing while the game thread callback is not running
-- (title screen, loading). Runs on the render thread: never touches game objects, except to
-- undo a transition-gate hold: if holding stopped the game thread callback, the gate could
-- never release, so it is released here (one time-scale write) and switched off for this
-- session instead.
function Session:update_network_only()
    local now = self.clock()
    if self.held_scale ~= nil then
        self:apply_hold(false)
        self.gate:reset()
        -- Once can be a long frame; twice within a minute means holding stops our loop.
        if self.gate_fallback_time ~= nil and now - self.gate_fallback_time < 60 then
            self.gate_disabled = true
            self:add_message("Transition gate switched off: holding the game stopped the mod's game loop", "error")
        end
        self.gate_fallback_time = now
    end
    self:run_actions(false)
    for _, ev in ipairs(self.net.poll()) do
        if ev.type == "message" then
            local t = type(ev.data) == "string" and ev.data:byte(1) or nil
            if t ~= nil and OFFLINE_SAFE[t] then
                self:handle_message(ev.data, now)
            elseif t ~= nil and DEFER[t] and #self.deferred < MAX_DEFERRED then
                self.deferred[#self.deferred + 1] = ev.data
            end
            -- Other enemy messages are dropped: they refer to objects that are being
            -- (un)loaded, and the host re-sends its full enemy state continuously anyway.
        else
            self:handle_event(ev, now)
        end
    end
    self.in_game_since = nil -- the game loop stopped: queued messages wait until it settles again
    -- Joining from the title screen: whatever save gets loaded next is redirected into the
    -- host's chapter (only a variable is set here; the game applies it when it loads).
    if self.role == "client" and self.join_travel_pending and self.world ~= nil and self.travel ~= nil
        and self.partner_state ~= nil and self.partner_state.chapter ~= nil then
        self.world:arm_chapter_switch(self.partner_state.chapter)
    end
end

return Session
