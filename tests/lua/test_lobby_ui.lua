-- lobby_ui.lua against a recording ImGui: every screen draws without errors, shows what the
-- lobby holds, and mouse clicks and the game's menu commands reach the lobby.
local T = require("testlib")
local P = require("re4coop.protocol")
local Lobby = require("re4coop.lobby")
local Config = require("re4coop.config")

-- A recording ImGui (REFramework's bindings as lobby_ui.lua uses them).
local rec = { texts = {}, clicks = {}, hovered = nil, inputs = {}, windows = 0, open_windows = 0, size_stack = 0,
    style_vars = 0, style_colors = 0, active_input = nil }
local current_id = nil
local function draw_list()
    local dl = {}
    local function noop() end
    for _, n in ipairs({ "add_rect_filled", "add_rect", "add_line", "add_rect_filled_multi_color", "add_triangle_filled",
        "path_clear", "path_arc_to", "path_stroke", "add_circle", "add_circle_filled" }) do
        dl[n] = function(self, ...)
            for _, v in ipairs({ ... }) do
                if type(v) == "table" then assert(#v == 2, "vectors are {x, y}") end
            end
        end
    end
    dl.add_text = function(self, pos, col, s)
        assert(type(pos) == "table" and #pos == 2, "text position")
        assert(type(s) == "string", "text")
        rec.texts[#rec.texts + 1] = s
    end
    return dl
end
local DL = draw_list()
_G.imgui = {
    push_font_size = function(s) assert(s > 0) rec.size_stack = rec.size_stack + 1 end,
    pop_font_size = function() rec.size_stack = rec.size_stack - 1 end,
    calc_text_size = function(s) return { x = #s * 9, y = 18 } end,
    set_cursor_screen_pos = function(p) assert(#p == 2) end,
    invisible_button = function(id, size)
        assert(size[1] >= 1 and size[2] >= 1, "button size")
        current_id = id
        if rec.clicks[id] then rec.clicks[id] = nil return true end
        return false
    end,
    is_item_hovered = function() return rec.hovered ~= nil and current_id == rec.hovered end,
    push_style_color = function(_, c)
        -- REFramework takes an int (or a Vector4f): a color outside the int range would not push.
        assert(math.type(c) == "integer" and c >= -0x80000000 and c <= 0x7FFFFFFF, "color as a signed int")
        rec.style_colors = rec.style_colors + 1
    end,
    pop_style_color = function(n) rec.style_colors = rec.style_colors - (n or 1) end,
    push_style_var = function(_, v)
        assert(type(v) == "number", "only float style vars (a table would not push)")
        rec.style_vars = rec.style_vars + 1
    end,
    pop_style_var = function(n) rec.style_vars = rec.style_vars - (n or 1) end,
    push_item_width = function() end,
    pop_item_width = function() end,
    input_text = function(id, v, flags)
        current_id = id
        local typed = rec.inputs[id]
        if typed ~= nil then
            rec.inputs[id] = nil
            if typed.enter then return (flags & 64) ~= 0, typed.text end
            return true, typed.text
        end
        return false, v
    end,
    is_item_active = function() return rec.active_input ~= nil and current_id == rec.active_input end,
    get_mouse = function() return { x = 10, y = 10 } end,
    get_display_size = function() return { x = 1920, y = 1080 } end,
    get_foreground_draw_list = function() return DL end,
    get_window_draw_list = function() return DL end,
    get_background_draw_list = function() return DL end,
    set_next_window_pos = function() end,
    set_next_window_size = function() end,
    begin_window = function() rec.windows = rec.windows + 1 rec.open_windows = rec.open_windows + 1 return true end,
    end_window = function() rec.open_windows = rec.open_windows - 1 end,
}

local LobbyUI = require("re4coop.lobby_ui")

local function drew(pattern)
    for _, s in ipairs(rec.texts) do
        if s:find(pattern, 1, true) then return true end
    end
    return false
end

local function fake_session(role, lobby_holder)
    local s = { role = role, messages = {}, queued = {}, sent_chat = {}, weapon_names = { [4002] = "Red9", [4003] = "Blacktail" },
        partner_name = role == "host" and "Ada" or "Leon", partner_state = nil }
    s.status_text = { state = "connected", partner_name = s.partner_name, rtt_ms = 42, stats = { peer = "10.0.0.2:33040" } }
    function s:status_cached() return self.status_text end
    function s:status() return self.status_text end
    function s:queue(name, arg) self.queued[#self.queued + 1] = { name = name, arg = arg } end
    function s:send_chat(text)
        self.sent_chat[#self.sent_chat + 1] = text
        self.messages[#self.messages + 1] = { text = "Me: " .. text, kind = "chat", time = 0 }
        return true
    end
    s.key_name = function(vk) return vk == 0x77 and "F8" or "?" end
    return s
end

local function make_lobby(role, settings)
    local sent = {}
    local l = Lobby.new({ protocol = P, settings = settings,
        send = function(b) sent[#sent + 1] = b return true end, notify = function() end,
        role = function() return role end, active = function() return true end,
        my_name = function() return settings.player_name end,
        partner_name = function() return role == "host" and "Ada" or "Leon" end })
    return l, sent
end

-- The UI's clock only goes forward (as in the game): `now` is relative to the test's start.
local base = 0
local last = 0
local function draw(session, lobby, settings, now)
    rec.texts = {}
    rec.windows = 0
    last = math.max(last + 0.05, base + (now or 0))
    LobbyUI.draw({ session = session, lobby = lobby, settings = settings, json = nil, now = last,
        addresses = { "192.168.1.5", "26.0.0.7" } })
    T.eq(rec.open_windows, 0, "every window closed")
    T.eq(rec.size_stack, 0, "every font size popped")
    T.eq(rec.style_vars, 0, "every style var popped")
    T.eq(rec.style_colors, 0, "every style color popped")
end

T.run("nothing_drawn_without_a_screen_or_start", function()
    local settings = Config.load(nil)
    local lobby = make_lobby("host", settings)
    local session = fake_session("host")
    draw(session, lobby, settings)
    T.eq(rec.windows, 0, "no window")
    T.eq(#rec.texts, 0, "nothing")
    T.eq(LobbyUI.covering(lobby, 1), false, "HUD may show")
end)

T.run("host_lobby_screen", function()
    local settings = Config.load(nil)
    settings.player_name = "Leon"
    local lobby = make_lobby("host", settings)
    local session = fake_session("host")
    session.messages = { { text = "Ada: hola", kind = "chat", time = 0 } }
    lobby:open(Lobby.SCREEN.LOBBY)
    lobby:set_saves({ { empty = false, chapter_id = 22200, difficulty = 20, count = 3 }, { empty = true }, { empty = true } })
    lobby.partner = { name = "Ada", in_lobby = true, ready = true, loadout = 2 }
    draw(session, lobby, settings)
    T.eq(rec.windows, 1, "one full-screen window")
    T.check(drew("SALA MULTIJUGADOR"), "title")
    T.check(drew("Capítulo 5"), "the co-op save's chapter")
    T.check(drew("Ada"), "the partner")
    T.check(drew("LISTO"), "ready tag")
    T.check(drew("Ada: hola"), "chat")
    T.check(drew("192.168.1.5:33040"), "address to join")
    T.check(drew("COMENZAR"), "start button")
    T.check(drew("Marca que estás listo"), "why the host cannot start yet")
    T.eq(LobbyUI.covering(lobby, 1), true, "HUD stays away")

    -- Keyboard / pad: down to the mode row, right switches to a new game.
    lobby:push_nav({ "down", "right" })
    draw(session, lobby, settings)
    T.eq(lobby:mode(), P.LOBBY_MODE.NEW, "mode changed by the menu commands")
    draw(session, lobby, settings)
    T.check(drew("Nueva (sobrescribe)"), "warns it overwrites the co-op save")

    -- Mouse: the ready button, then start.
    rec.clicks["##btn_ready"] = true
    draw(session, lobby, settings)
    T.eq(lobby.me.ready, true, "ready by click")
    lobby.partner.ready = true
    rec.clicks["##btn_start"] = true
    draw(session, lobby, settings, 2)
    T.check(lobby.start ~= nil, "start by click")
    T.eq(lobby.screen, nil, "the lobby screen gives way to the loading")

    -- Chat typed and sent with Enter.
    lobby:open(Lobby.SCREEN.LOBBY)
    rec.inputs["##lobby_chat"] = { text = "vamos", enter = true }
    draw(session, lobby, settings)
    T.eq(session.sent_chat[1], "vamos", "chat sent")
end)

T.run("cancel_goes_to_leave_then_leaves", function()
    local settings = Config.load(nil)
    local lobby = make_lobby("client", settings)
    local session = fake_session("client")
    lobby:open(Lobby.SCREEN.LOBBY)
    draw(session, lobby, settings)
    T.check(drew("Esperando los datos de la sala del anfitrión"), "client before the host's data")
    lobby:push_nav({ "cancel" })
    draw(session, lobby, settings)
    T.eq(#session.queued, 0, "first Cancel only moves to 'leave'")
    lobby:push_nav({ "cancel" })
    draw(session, lobby, settings)
    T.eq(session.queued[1] and session.queued[1].name, "lobby_leave", "second Cancel leaves")
end)

T.run("client_with_a_host_already_playing", function()
    local settings = Config.load(nil)
    local lobby = make_lobby("client", settings)
    local session = fake_session("client")
    session.partner_state = { chapter = 21200 }
    lobby:open(Lobby.SCREEN.LOBBY)
    draw(session, lobby, settings)
    T.check(drew("El anfitrión ya está jugando"), "told")
    rec.clicks["##btn_join_running"] = true
    draw(session, lobby, settings)
    T.eq(lobby.join_running, true, "joins the game in progress")
    T.eq(lobby.screen, nil, "lobby closed")
end)

T.run("typing_suppresses_menu_commands", function()
    base = last + 10
    local settings = Config.load(nil)
    local lobby = make_lobby("host", settings)
    local session = fake_session("host")
    lobby:open(Lobby.SCREEN.LOBBY)
    rec.active_input = "##lobby_chat"
    draw(session, lobby, settings, 5)
    T.eq(session.ui_text_active, true, "the session knows the player is typing")
    local file = lobby.cfg.file
    lobby:push_nav({ "right" })
    draw(session, lobby, settings, 5.1)
    T.eq(lobby.cfg.file, file, "arrow keys typed into the chat do not change the game")
    rec.active_input = nil
    draw(session, lobby, settings, 6)
    T.eq(session.ui_text_active, false, "typing over")
end)

T.run("join_and_options_screens", function()
    base = last + 10
    local settings = Config.load(nil)
    local lobby = make_lobby("none", settings)
    local session = fake_session("none")
    session.status_text = { state = "idle", stats = {} }
    lobby:open(Lobby.SCREEN.JOIN)
    draw(session, lobby, settings)
    T.check(drew("UNIRSE A PARTIDA"), "join title")
    rec.inputs["##join_address"] = { text = "26.1.2.3:33041" }
    draw(session, lobby, settings)
    T.eq(settings.last_address, "26.1.2.3:33041", "address typed")
    rec.clicks["##btn_connect"] = true
    draw(session, lobby, settings)
    T.eq(session.queued[1] and session.queued[1].name, "join", "connect queued")
    T.eq(session.queued[1] and session.queued[1].arg, "26.1.2.3:33041", "to that address")
    session.status_text = { state = "idle", last_error = "timed out", stats = {} }
    draw(session, lobby, settings)
    T.check(drew("No se pudo conectar: timed out"), "error shown")
    lobby:push_nav({ "cancel" })
    draw(session, lobby, settings)
    T.eq(lobby.screen, nil, "back to the menu section")

    lobby:open(Lobby.SCREEN.OPTIONS, "menu")
    draw(session, lobby, settings)
    T.check(drew("OPCIONES MULTIJUGADOR"), "options title")
    local was = settings.show_partner
    rec.clicks["##row_show_partner"] = true
    draw(session, lobby, settings)
    T.eq(settings.show_partner, not was, "a switch flipped by click")
    rec.clicks["##btn_back"] = true
    draw(session, lobby, settings)
    T.eq(lobby.screen, nil, "saved and back")
end)

T.run("loaders_and_waiting_veil", function()
    base = last + 10
    local settings = Config.load(nil)
    settings.player_name = "Leon"
    local lobby = make_lobby("host", settings)
    local session = fake_session("host")
    lobby.partner = { name = "Ada", in_lobby = true, ready = true, loadout = 1 }
    lobby:begin_start({ start_id = 1, mode = P.LOBBY_MODE.NEW, file = 1, chapter = 1, difficulty = 20, key = 1, chapter_id = 21100 }, base)
    lobby:take_action()
    lobby.start.phase = P.LOAD_PHASE.LOADING
    draw(session, lobby, settings, 1)
    T.check(drew("Leon"), "my loader")
    T.check(drew("Ada"), "the partner's loader")
    T.check(drew("Cargando el mapa..."), "loading")
    T.eq(rec.windows, 0, "loaders need no window")
    lobby:tick(base + 2, { connected = true, in_game = true })
    lobby:tick(base + 3, { connected = true, in_game = true })
    draw(session, lobby, settings, 3)
    T.check(drew("ESPERANDO A ADA"), "the waiting veil names the partner")
    lobby.start.can_skip = true
    draw(session, lobby, settings, 3)
    T.check(drew("Pulsa F8"), "how to skip")
end)

T.finish()
