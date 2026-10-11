-- Co-op session: drives the network connection and decides what to send and apply.
--
-- Dependencies are injected so the whole thing runs in tests without the game:
--   net      : re4coop_net (or a Session object from re4coop_net.new_session())
--   game     : adapter from game.lua (or a fake) - read_player_state, list_enemies, the
--              avatar capture methods listed in avatar.lua, ...
--   world    : adapter from game_world.lua (or a fake) - scenario flags, gimmicks, breakables,
--              cutscenes, location / warp / chapter switch. Optional: without it the shared
--              world, cutscene replay and travelling to the partner are off.
--   pause    : adapter from game_pause.lua (or a fake). Optional: menus keep pausing.
--   clock    : function() -> seconds
--   settings : live config table (see config.lua)

local P = require("re4coop.protocol")
local Interp = require("re4coop.interp")
local EnemySync = require("re4coop.enemy_sync")
local ItemSync = require("re4coop.items_sync")
local Avatar = require("re4coop.avatar")
local DropSync = require("re4coop.drop_sync")
local Gate = require("re4coop.gate")
local FlagSync = require("re4coop.flag_sync")
local GimmickSync = require("re4coop.gimmick_sync")
local ObjectSync = require("re4coop.object_sync")
local CutsceneSync = require("re4coop.cutscene_sync")
local Travel = require("re4coop.travel")

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
    [P.T.FRAG] = true, [P.T.AVATAR] = true, [P.T.GEAR] = true, [P.T.POSE] = true, [P.T.ACTIONS] = true,
}

-- Reliable messages that must not be lost but touch game objects: kept until the game loop
-- runs again. Everything else arriving then (enemy snapshots, hits) is resent continuously.
local DEFER = {
    [P.T.ENEMY_DAMAGE] = true, [P.T.ENEMY_DEAD] = true,
    [P.T.FLAGS] = true, [P.T.FLAG_WORDS] = true, [P.T.GIMMICKS] = true, [P.T.OBJECTS] = true,
    [P.T.CUTSCENE] = true, [P.T.WORLD_REQUEST] = true, [P.T.WORLD_DONE] = true,
}

local SYNC_NAMES = { "enemy_sync", "drop_sync", "flag_sync", "gimmick_sync", "object_sync", "cutscene_sync" }

function Session.new(opts)
    local self = setmetatable({}, Session)
    self.net = opts.net
    self.game = opts.game
    self.world = opts.world
    self.pause = opts.pause
    self.clock = opts.clock
    self.settings = opts.settings
    self.log_sink = opts.log or function() end
    self.messages = {}       -- chat + notices shown in the UI/HUD: {time, text, kind}
    self.deferred = {}       -- reliable messages received while the game loop was not running
    self.frag_id = 0
    self.next_sync_id = 1
    self.avatar_tx = Avatar.new_sender({
        protocol = P,
        settings = self.settings,
        send = function(bytes, reliable) return self:send(bytes, reliable) end,
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
    self.local_stage = nil
    self.local_chapter = nil
    self.local_loc = nil     -- world:location(): {chapter, stage, pos, yaw, loading, playable}
    self.player_id = nil     -- identity of the player context (a new one = the game reloaded)
    self.gate = Gate.new(opts.settings)
    self.held_scale = nil   -- time scale to restore while the gate holds us (nil = not holding)
    self.last_item_tick = -math.huge
    self.keys_down = {}
    self.left_behind = nil
    self.far_since = nil
    self.prompt_snoozed_until = -math.huge
    self.tp_watch = nil
    self:make_item_sync()

    if self.world ~= nil and self.world.install_hooks ~= nil then
        self.world:install_hooks({
            on_flag = function(guid, value)
                if self.flag_sync and self.partner_connected and self.compatible then
                    self.flag_sync:on_local_flag(guid, value, self.clock())
                end
            end,
            on_cutscene = function(id, method)
                if self.cutscene_sync and self.partner_connected and self.compatible then
                    self.cutscene_sync:on_local_start(id, method, self.clock(), self.local_loc)
                end
            end,
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
    self.interp = Interp.new({ delay = (self.settings and self.settings.interp_delay) or 0.1 })
    self.reassembler = P.new_reassembler()
    self.avatar_tx:reset()
    self.avatar_rx:reset()
    for _, name in ipairs(SYNC_NAMES) do
        if self[name] then self[name]:reset() end
    end
    self.join_travel_pending = false
    self.sync_on_join = false
    self.world_sync_pending = nil
    self.chapter_ahead_since = nil
    self.deferred = {} -- queued messages belonged to the previous partner
    if self.travel then self.travel:cancel("partner left") end
end

-- Creates the per-role sync modules (nothing while not in a session).
function Session:make_syncs()
    if self.role ~= "host" and self.role ~= "client" then
        for _, name in ipairs(SYNC_NAMES) do self[name] = nil end
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
    self.enemy_sync = EnemySync.new(base)
    self.drop_sync = DropSync.new({
        role = self.role,
        protocol = P,
        settings = self.settings,
        enemy_sync = self.enemy_sync,
        is_key_item = function(id) return self.game.is_key_item ~= nil and self.game.is_key_item(id) end,
        send = base.send,
        log = base.log,
    })
    self.flag_sync = FlagSync.new(base)
    self.gimmick_sync = GimmickSync.new(base)
    self.object_sync = ObjectSync.new(base)
    self.cutscene_sync = CutsceneSync.new(base)
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
    self:update_pause()
    return true
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
    self:update_pause()
    return true
end

-- Everything the session changed in the game goes back to normal.
function Session:restore_game()
    self:apply_hold(false)
    if self.pause and self.pause.set_active then
        self.pause:set_active(false, self.settings.no_pause_mode, false, self.clock())
    end
    if self.game.restore_enemy_ai then self.game:restore_enemy_ai() end
    if self.world and self.world.disarm_chapter_switch then self.world:disarm_chapter_switch() end
end

function Session:leave()
    self.net.stop()
    if self.role ~= "none" then
        self:add_message("Left the co-op session", "info")
    end
    self.role = "none"
    self.item_sync:reset()
    self:reset_peer()
    self:make_syncs()
    self.gate:reset()
    self:restore_game()
end

-- Undo anything that must not outlive the script (called on "Reset Scripts").
function Session:shutdown()
    self:restore_game()
end

function Session:send(bytes, reliable)
    if not self.partner_connected then return false end
    local ok, err = self.net.send(bytes, reliable)
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
    local partner = self.interp:sample(now)
    local age = self.interp:age(now)
    local fresh = partner ~= nil and age ~= nil and age <= 1.5
    local pflags = partner ~= nil and (partner.flags or 0) or 0
    local mine = self:fresh_local_pos(now)
    local before = self.gate.holding
    local hold = self.gate:update(now, {
        connected = self.partner_connected and self.compatible and not self.gate_disabled,
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
function Session:fresh_local_pos(now)
    if self.last_local_pos == nil or self.last_local_pos_time == nil then return nil end
    if now - self.last_local_pos_time > LOCAL_POS_FRESH then return nil end
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

function Session:handle_hotkeys(now)
    local s = self.settings
    local teleport = self:key_pressed(s.teleport_key)
    local snooze = self:key_pressed(s.snooze_key)
    if self.left_behind ~= nil then
        if teleport then
            if self.left_behind.partner_waiting == "chapter" then
                if self.left_behind.can_follow then
                    self:add_message("Loading your partner's chapter...", "warn")
                    self:travel_to_partner()
                else
                    self:add_message("Your partner is already in the next chapter - finish this one to join them", "warn")
                end
            else
                self:teleport_to_partner()
            end
        elseif snooze and self.left_behind.partner_waiting == nil then
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
    if self.enemy_sync then
        st.enemies = self.enemy_sync:summary()
        st.partner_hits = self.enemy_sync:recent_partner_hits(now, TRACER_SECONDS)
    end
    if self.drop_sync then
        st.drops = self.drop_sync:summary()
    end
    if self.world ~= nil then
        if self.flag_sync then st.flags = self.flag_sync:summary() end
        if self.gimmick_sync then st.gimmicks = self.gimmick_sync:summary() end
        if self.object_sync then st.objects = self.object_sync:summary() end
        if self.cutscene_sync then st.cutscenes = self.cutscene_sync:summary() end
        if self.travel then st.travel = self.travel:status() end
    end
    if self.pause and self.pause.status then st.pause = self.pause:status() end
    st.items = self.item_sync:summary()
    st.left_behind = self.left_behind
    st.teleport_key_name = Session.key_name(self.settings.teleport_key)
    st.snooze_key_name = Session.key_name(self.settings.snooze_key)
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
        self:add_message(("%s connected (%s)"):format(ev.name or "Partner", ev.peer or "?"), "good")
        self:send_hello()
        -- The client joins the host's game: go where the host is, with the host's world.
        if self.role == "client" and self.world ~= nil then
            if self.settings.auto_travel ~= false and self.travel ~= nil then
                self.join_travel_pending = true
            else
                self.sync_on_join = true -- no travel, but still take over the host's world state
            end
        end
    elseif ev.type == "disconnected" or ev.type == "rejected" then
        local who = self.partner_name or "Partner"
        local was_connected = self.partner_connected
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
        if self.game.restore_enemy_ai then self.game:restore_enemy_ai() end
        if self.role == "client" then
            self.role = "none"
            self:make_syncs()
            self:update_pause()
        end
    elseif ev.type == "message" then
        self:handle_message(ev.data, now)
    end
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
    -- Enemies need nothing extra: deaths the client did not see are re-advertised anyway.
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
        if full ~= nil then
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
        local dead = (m.flags & P.PLAYER_FLAGS.DEAD) ~= 0
        if prev ~= nil and dead and (prev.flags & P.PLAYER_FLAGS.DEAD) == 0 then
            self:add_message((self.partner_name or "Partner") .. " is down!", "error")
        end
    elseif m.type == T.CHAT then
        self:add_message(("%s: %s"):format(self.partner_name or "Partner", m.text), "chat")
    elseif m.type == T.NOTIFY then
        self:add_message(m.text, "info")
    elseif m.type == T.ITEM_TAKEN then
        self.item_sync:on_message(m, now)
    elseif m.type == T.ITEM_DROPPED then
        -- Without enemy sync our own rolls are not skipped, so the host's item would be extra.
        if self.drop_sync and self.settings.sync_enemies then
            self.drop_sync:on_message(m, now, self.game, self.local_stage)
        end
    elseif m.type == T.WORLD_REQUEST then
        if self.role == "host" then self:on_world_request(m) end
    elseif m.type == T.WORLD_DONE then
        if self.role == "client" and m.sync_id == self.world_sync_pending then
            self.world_sync_pending = nil
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
    elseif m.type == T.CUTSCENE then
        if self.cutscene_sync and self.world then self.cutscene_sync:on_message(m, now) end
    elseif self.avatar_rx:on_message(m, now) then
        return
    elseif self.enemy_sync and self.settings.sync_enemies then
        self.enemy_sync:on_message(m, now, self.game)
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
    if reloaded and self.enemy_sync then self.enemy_sync:on_local_reload() end

    self.last_local_pos = st.pos
    self.last_local_pos_time = now
    self.local_cutscene = st.cutscene and true or false
    self.local_stage = st.stage
    self.local_chapter = st.chapter
    self:watch_teleport(now, st.pos)

    local flags = 0
    if st.dead then flags = flags | P.PLAYER_FLAGS.DEAD end
    if st.cutscene then flags = flags | P.PLAYER_FLAGS.CUTSCENE end
    if st.aiming then flags = flags | P.PLAYER_FLAGS.AIMING end
    if self.gate.holding ~= nil then flags = flags | P.PLAYER_FLAGS.GATE_WAITING end

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

-- Both players' positions for enemy ownership (the partner only counts in the same region).
function Session:players_info(now)
    local local_pos = self:fresh_local_pos(now)
    local remote = self.interp:sample(now)
    local age = self.interp:age(now)
    if local_pos == nil then return nil end
    if remote == nil or age == nil or age > 2.0 then return { local_pos = local_pos } end
    if remote.stage ~= nil and self.local_stage ~= nil and remote.stage // 1000 ~= self.local_stage // 1000 then
        return { local_pos = local_pos } -- another region: the partner is not near our enemies
    end
    return { local_pos = local_pos, partner_pos = remote.pos }
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

-- Shared world: flags, gimmicks, breakables, cutscenes; joining and following the host.
function Session:update_world(now)
    local world, s = self.world, self.settings
    if world == nil or self.flag_sync == nil then return end

    if world.update then world:update() end
    self.flag_sync:tick(now, world)
    self.gimmick_sync:tick(now, world)
    self.object_sync:tick(now, world, self:fresh_local_pos(now))
    self.cutscene_sync:tick(now, world, self.local_loc, self.travel)

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
            if self.travel:request({ chapter = partner.chapter, stage = partner.stage, pos = partner.pos,
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

-- Network + game sync. Call once per game frame from a game-thread callback.
function Session:update()
    local now = self.clock()
    if #self.deferred > 0 then
        local deferred = self.deferred
        self.deferred = {}
        for _, data in ipairs(deferred) do
            self:handle_message(data, now)
        end
    end
    self:refresh_location(now)
    for _, ev in ipairs(self.net.poll()) do
        self:handle_event(ev, now)
    end
    self:update_pause()
    if self.pause and self.pause.update then self.pause:update(now) end
    local active = self.partner_connected and self.compatible
    if self.game.set_capture then self.game:set_capture(active and self.settings.share_character ~= false) end
    if self.world and self.world.set_active then self.world:set_active(active) end
    if not active then
        -- Game events from before the partner joined are stale by the time we sync.
        if self.game.take_pickup_events then self.game:take_pickup_events() end
        if self.game.take_hit_events then self.game:take_hit_events() end
        if self.game.take_drop_events then self.game:take_drop_events() end
        if self.game.set_drop_suppress then self.game:set_drop_suppress(nil) end
        self:update_gate(now) -- releases a hold
        return
    end

    local s = self.settings
    if now - self.last_player_send >= 1.0 / (s.player_hz or 20) then
        self.last_player_send = now
        self:send_player_state(now)
    end

    if s.share_character ~= false and self.game.avatar_descriptor then
        self.avatar_tx:tick(now, self.game)
    end

    -- Hits our player landed, and enemy drops, since the last frame (hooks in game.lua).
    local hits = self.game.take_hit_events and self.game:take_hit_events() or nil
    if self.enemy_sync and s.sync_enemies and hits ~= nil then
        self.enemy_sync:on_local_hits(hits, now)
    end
    local drops = self.game.take_drop_events and self.game:take_drop_events() or nil
    local drops_on = self.drop_sync ~= nil and self.drop_sync:enabled() and s.sync_enemies
    if drops_on then
        self.drop_sync:on_drop_events(now, drops)
        self.drop_sync:update_pairs(now, self.game)
    elseif self.game.set_drop_suppress then
        self.game:set_drop_suppress(nil) -- enemy pairing is off: never skip our own rolls
    end

    if self.enemy_sync and s.sync_enemies then
        -- The animation is only read while enemies are mirrored with their animation.
        self.game.read_motion = s.enemy_mirror ~= false and s.enemy_motion_sync ~= false
        if now - self.last_enemy_tick >= 1.0 / (s.enemy_tick_hz or 20) then
            self.last_enemy_tick = now
            local enemies = self.game:list_enemies()
            if enemies ~= nil then
                self.enemy_sync:tick(now, enemies, self.game, self:players_info(now))
            end
        end
        -- Every frame: enemies the partner's game runs follow their copies smoothly.
        self.enemy_sync:frame(now, self.game)
    elseif self.enemy_sync then
        self.enemy_sync:release_all(self.game) -- enemy sync switched off: our AI runs everything
    end

    if self.game.list_pickups and now - self.last_item_tick >= ITEM_TICK_INTERVAL then
        self.last_item_tick = now
        local accepted = self.game.take_pickup_events and self.game:take_pickup_events() or nil
        if s.share_key_items or drops_on then
            local pickups = self.game:list_pickups()
            if s.share_key_items then
                local pos = self:fresh_local_pos(now)
                local flags = nil
                if self.game.item_get_flags then
                    flags = self.game:item_get_flags(self.item_sync:watched_item_ids())
                end
                self.item_sync:tick(now, pickups, pos, self.game, pos ~= nil and not self.local_cutscene,
                    accepted, flags)
            end
            if drops_on then
                self.drop_sync:on_pickups(now, pickups, self.local_stage)
            end
        end
    end

    self:update_world(now)
    self:update_gate(now)
    self:update_left_behind(now)
    self:handle_hotkeys(now)
end

-- Keeps connect/disconnect events flowing while the game thread callback is not running
-- (title screen, loading). Never touches game objects, except to undo a transition-gate hold:
-- if holding stopped the game thread callback, the gate could never release, so it is
-- released here and switched off for this session instead.
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
    -- Joining from the title screen: whatever save gets loaded next is redirected into the
    -- host's chapter (only a variable is set here; the game applies it when it loads).
    if self.role == "client" and self.join_travel_pending and self.world ~= nil and self.travel ~= nil
        and self.partner_state ~= nil and self.partner_state.chapter ~= nil then
        self.world:arm_chapter_switch(self.partner_state.chapter)
    end
end

return Session
