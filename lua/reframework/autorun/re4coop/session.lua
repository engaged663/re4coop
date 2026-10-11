-- Co-op session: drives the network connection and decides what to send and apply.
--
-- Dependencies are injected so the whole thing runs in tests without the game:
--   net    : re4coop_net (or a Session object from re4coop_net.new_session())
--   game   : adapter from game.lua (or a fake) - read_player_state, list_enemies, ...
--   clock  : function() -> seconds
--   settings : live config table (see config.lua)

local P = require("re4coop.protocol")
local Interp = require("re4coop.interp")
local EnemySync = require("re4coop.enemy_sync")
local ItemSync = require("re4coop.items_sync")

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

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Session.new(opts)
    local self = setmetatable({}, Session)
    self.net = opts.net
    self.game = opts.game
    self.clock = opts.clock
    self.settings = opts.settings
    self.log_sink = opts.log or function() end
    self.messages = {}       -- chat + notices shown in the UI/HUD: {time, text, kind}
    self:reset_peer()
    self.role = "none"
    self.last_error = nil
    self.last_player_send = -math.huge
    self.last_enemy_tick = -math.huge
    self.local_skeleton_sig = nil
    self.local_dead = false
    self.local_cutscene = false
    self.last_item_tick = -math.huge
    self.keys_down = {}
    self.left_behind = nil
    self.far_since = nil
    self.prompt_snoozed_until = -math.huge
    self.tp_watch = nil
    self:make_item_sync()

    -- Resume a session that survived "Reset Scripts" (the plugin keeps it alive).
    local state = self.net.state()
    if state ~= "idle" then
        self.role = self.net.role()
        self:make_enemy_sync()
        if state == "connected" then
            self.partner_connected = true
            self.partner_name = self.net.stats().peer_name
            self:send_hello(true) -- we lost the partner's HELLO/SKELETON in the reload
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
    self.partner_parents = nil   -- skeleton parent table
    self.compatible = true
    self.interp = Interp.new({ delay = (self.settings and self.settings.interp_delay) or 0.1 })
    self.local_skeleton_sig = nil
    if self.enemy_sync then self.enemy_sync:reset() end
end

function Session:make_enemy_sync()
    if self.role ~= "host" and self.role ~= "client" then
        self.enemy_sync = nil
        return
    end
    self.enemy_sync = EnemySync.new({
        role = self.role,
        protocol = P,
        settings = self.settings,
        send = function(bytes, reliable) self:send(bytes, reliable) end,
        log = function(...) self:log(...) end,
    })
end

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
    self:make_enemy_sync()
    self.item_sync:reset()
    self:add_message(("Hosting on UDP port %d - waiting for partner"):format(s.port), "info")
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
    self:make_enemy_sync()
    self.item_sync:reset()
    self:add_message(("Connecting to %s:%d ..."):format(host, port), "info")
    return true
end

function Session:leave()
    self.net.stop()
    if self.role ~= "none" then
        self:add_message("Left the co-op session", "info")
    end
    self.role = "none"
    self.enemy_sync = nil
    self.item_sync:reset()
    self:reset_peer()
end

function Session:send(bytes, reliable)
    if not self.partner_connected then return false end
    local ok, err = self.net.send(bytes, reliable)
    if not ok then
        self:log("send failed: %s", tostring(err))
    end
    return ok
end

function Session:send_chat(text)
    if text == nil or text == "" then return false end
    if self:send(P.encode_chat(text), true) then
        self:add_message(("%s: %s"):format(self.settings.player_name, text), "chat")
        return true
    end
    return false
end

function Session:teleport_to_partner()
    local st = self.interp:sample(self.clock())
    if st == nil then
        self:add_message("No partner position yet", "error")
        return false
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
    local cutscene = self.local_cutscene or (partner ~= nil and ((partner.flags or 0) & P.PLAYER_FLAGS.CUTSCENE) ~= 0)
    if not s.left_behind_prompt or partner == nil or age == nil or age > 1.5 or mine == nil or cutscene
        or self.tp_watch ~= nil then
        self.far_since = nil
        self.left_behind = nil
        return
    end
    local d = dist3(partner.pos, mine)
    if d < s.left_behind_distance then
        self.far_since = nil
        self.left_behind = nil
        return
    end
    self.far_since = self.far_since or now
    if now - self.far_since >= s.left_behind_seconds and now >= self.prompt_snoozed_until then
        self.left_behind = { distance = d }
    else
        self.left_behind = nil
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
            self:teleport_to_partner()
        elseif snooze then
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
    }
    local remote = self.interp:sample(now)
    if remote ~= nil then
        st.partner_pos = remote.pos
        st.partner_hp = remote.hp
        st.partner_max_hp = remote.max_hp
        st.partner_flags = remote.flags
        local mine = self.last_local_pos
        if mine ~= nil then
            local dx, dy, dz = remote.pos.x - mine.x, remote.pos.y - mine.y, remote.pos.z - mine.z
            st.partner_distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        end
    end
    if self.enemy_sync then
        st.enemies = self.enemy_sync:summary()
    end
    st.items = self.item_sync:summary()
    st.left_behind = self.left_behind
    st.teleport_key_name = Session.key_name(self.settings.teleport_key)
    st.snooze_key_name = Session.key_name(self.settings.snooze_key)
    return st
end

-- Interpolated partner state for rendering (ghost/puppet), or nil.
function Session:partner_render_state()
    if not self.partner_connected then return nil end
    local now = self.clock()
    local age = self.interp:age(now)
    if age == nil or age > 3.0 then return nil end
    local st = self.interp:sample(now)
    if st == nil then return nil end
    return st, self.partner_parents
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
    self.local_skeleton_sig = nil -- force a SKELETON resend
end

function Session:handle_event(ev, now)
    if ev.type == "connected" then
        self.partner_connected = true
        self.partner_name = ev.name
        self.interp:clear()
        if self.enemy_sync then self.enemy_sync:reset() end
        self:add_message(("%s connected (%s)"):format(ev.name or "Partner", ev.peer or "?"), "good")
        self:send_hello()
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
        if self.role == "client" then
            self.role = "none"
            self.enemy_sync = nil
        end
    elseif ev.type == "message" then
        self:handle_message(ev.data, now)
    end
end

function Session:handle_message(data, now)
    local m, err = P.decode(data)
    if m == nil then
        self:log("dropped message: %s", tostring(err))
        return
    end
    local T = P.T
    if m.type == T.HELLO then
        self.partner_hello = m
        self.partner_name = m.name ~= "" and m.name or self.partner_name
        -- A HELLO means the partner (re)started its session state: resend our skeleton, and
        -- re-introduce ourselves if it asked.
        self.local_skeleton_sig = nil
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
            if m.area ~= "" and mine ~= "" and m.area ~= mine then
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
    elseif m.type == T.SKELETON then
        self.partner_parents = m.parents
    elseif m.type == T.CHAT then
        self:add_message(("%s: %s"):format(self.partner_name or "Partner", m.text), "chat")
    elseif m.type == T.NOTIFY then
        self:add_message(m.text, "info")
    elseif m.type == T.ITEM_TAKEN then
        self.item_sync:on_message(m)
    elseif self.enemy_sync and self.settings.sync_enemies then
        self.enemy_sync:on_message(m, now, self.game)
    end
end

function Session:send_player_state(now)
    local st = self.game:read_player_state()
    if st == nil then return end
    self.last_local_pos = st.pos
    self.last_local_pos_time = now
    self.local_cutscene = st.cutscene and true or false
    self:watch_teleport(now, st.pos)

    if st.parents ~= nil then
        local sig = table.concat(st.parents, ",")
        if sig ~= self.local_skeleton_sig then
            if self:send(P.encode_skeleton(st.parents), true) then
                self.local_skeleton_sig = sig
            end
        end
    end

    local flags = 0
    if st.dead then flags = flags | P.PLAYER_FLAGS.DEAD end
    if st.cutscene then flags = flags | P.PLAYER_FLAGS.CUTSCENE end
    if st.aiming then flags = flags | P.PLAYER_FLAGS.AIMING end

    self:send(P.encode_player({
        time = now,
        pos = st.pos,
        rot = st.rot or { x = 0, y = 0, z = 0, w = 1 },
        hp = st.hp, max_hp = st.max_hp,
        flags = flags,
        area_hash = P.hash(self.game:area_name() or ""),
        joints = st.joints,
    }), false)

    if st.dead and not self.local_dead then
        self:send(P.encode_notify(NOTIFY.DIED, self.settings.player_name .. " is down!"), true)
    end
    self.local_dead = st.dead and true or false
end

-- Network + game sync. Call once per game frame from a game-thread callback.
function Session:update()
    local now = self.clock()
    for _, ev in ipairs(self.net.poll()) do
        self:handle_event(ev, now)
    end
    if not self.partner_connected or not self.compatible then
        return
    end

    local s = self.settings
    if now - self.last_player_send >= 1.0 / (s.player_hz or 20) then
        self.last_player_send = now
        self:send_player_state(now)
    end

    if self.enemy_sync and s.sync_enemies and now - self.last_enemy_tick >= 1.0 / (s.enemy_tick_hz or 20) then
        self.last_enemy_tick = now
        local enemies = self.game:list_enemies()
        if enemies ~= nil then
            self.enemy_sync:tick(now, enemies, self.game)
        end
    end

    if s.share_key_items and self.game.list_pickups and now - self.last_item_tick >= ITEM_TICK_INTERVAL then
        self.last_item_tick = now
        local pos = self:fresh_local_pos(now)
        self.item_sync:tick(now, self.game:list_pickups(), pos, self.game, pos ~= nil and not self.local_cutscene)
    end

    self:update_left_behind(now)
    self:handle_hotkeys(now)
end

-- Keeps connect/disconnect events flowing while the game thread callback is not running
-- (title screen, loading). Never touches game objects.
function Session:update_network_only()
    local now = self.clock()
    for _, ev in ipairs(self.net.poll()) do
        if ev.type == "message" then
            -- Enemy messages are dropped here: they refer to objects that are being (un)loaded,
            -- and the host re-sends its full enemy state continuously anyway.
            local m = P.decode(ev.data)
            if m ~= nil and (m.type == P.T.CHAT or m.type == P.T.NOTIFY or m.type == P.T.HELLO
                or m.type == P.T.PLAYER or m.type == P.T.SKELETON or m.type == P.T.ITEM_TAKEN) then
                self:handle_message(ev.data, now)
            end
        else
            self:handle_event(ev, now)
        end
    end
end

return Session
