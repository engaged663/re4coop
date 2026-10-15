-- The lobby's screens (lobby.lua), drawn over the game's own main menu with REFramework's
-- ImGui in the style of RE4's menus: the lobby (the game's settings, the players, each one's
-- loadout, chat, ready / start), joining a host, the multiplayer options; and, while a game the
-- lobby started is loading, the two loaders (bottom left) and the "waiting for the partner"
-- veil over a map that has loaded first.
--
-- Render thread (re.on_frame): it only changes Lua state (lobby.lua, settings) and queues what
-- touches the game (Session:queue). Keyboard and pad come from the game's own menu commands
-- (Decide, Cancel, directions: game_menu.lua reads them on the game thread, lobby.lua passes
-- them here); the mouse from ImGui, which REFramework feeds even with its own menu closed.

local Lobby = require("re4coop.lobby")
local Config = require("re4coop.config")
local P = require("re4coop.protocol")

local UI = {}

-- Colors (ImGui: 0xAABBGGRR).
local C = {
    veil = 0xE6050505,
    shade_top = 0xEA000000,    -- the game's menu stays under it, covered
    shade_bottom = 0xF6000000,
    panel = 0xB40A0A0A,
    panel_edge = 0x38FFFFFF,
    text = 0xFFE6E6E6,
    text_soft = 0xFFC4C4C4,
    dim = 0xFF8A8A8A,
    faint = 0xFF5A5A5A,
    accent = 0xFF1C1CA8,      -- RE4's red
    accent_soft = 0x901C1CA8,
    accent_clear = 0x001C1CA8,
    gold = 0xFF8EC4DA,        -- warm beige for values
    ok = 0xFF74C06F,
    warn = 0xFF3FA6E3,
    err = 0xFF5050E0,
    chat = 0xFFB8DCF0,
    input_bg = 0xC8000000,
    input_hover = 0xD8101010,
    black = 0xFF000000,
}

local KEY_ENTER = 525 -- ImGuiKey_Enter (ImGui 1.92)
local FLAG_ENTER_RETURNS = 64 -- ImGuiInputTextFlags_EnterReturnsTrue
local WINDOW_FLAGS = 1 | 2 | 4 | 8 | 16 | 32 | 128 | 256 | (1 << 16) | (1 << 17) -- no decoration/bg/settings/nav
local COL_TEXT, COL_BORDER, COL_FRAME, COL_FRAME_HOVER, COL_FRAME_ACTIVE = 0, 5, 7, 8, 9
-- Only float style variables are pushed: REFramework's push_style_var takes a float or a
-- Vector2f, and a push it does not take would leave its pop unbalanced (an ImGui assert).
local VAR_WINDOW_BORDER, VAR_FRAME_ROUNDING, VAR_FRAME_BORDER = 4, 12, 13

local st = {
    focus = {},          -- screen -> focused row id
    chat = "",
    text_active = false,
    text_until = 0,
    mouse = nil,         -- { x, y, t } last mouse movement
    last_screen = nil,
    hint = nil,          -- one-line notice under the buttons (why Start is disabled...)
}

-------------------------------------------------------------------------------
-- Drawing helpers
-------------------------------------------------------------------------------

local S = 1.0 -- UI scale (screen height / 1080)

local function px(v) return math.floor(v * S + 0.5) end

local function has(fn) return imgui ~= nil and imgui[fn] ~= nil end

-- push_style_color takes an int: colors as signed 32-bit values (the same bits).
local function push_color(idx, c)
    if c >= 0x80000000 then c = c - 0x100000000 end
    imgui.push_style_color(idx, c)
end

local function with_size(size, fn, ...)
    if not has("push_font_size") then return fn(...) end
    imgui.push_font_size(math.max(8, size * S))
    local ok, a, b = pcall(fn, ...)
    imgui.pop_font_size()
    if not ok then error(a, 0) end
    return a, b
end

local function text_w(s)
    if not has("calc_text_size") then return #s * 7 * S end
    local v = imgui.calc_text_size(s)
    return v and (v.x or v[1]) or (#s * 7)
end

local function text_h()
    if not has("calc_text_size") then return 16 * S end
    local v = imgui.calc_text_size("Ag")
    return v and (v.y or v[2]) or 16
end

local function rect(dl, x, y, w, h, col) dl:add_rect_filled({ x, y }, { x + w, y + h }, col, 0, 0) end
local function frame(dl, x, y, w, h, col, t) dl:add_rect({ x, y }, { x + w, y + h }, col, 0, 0, t or 1) end
local function line(dl, x1, y1, x2, y2, col, t) dl:add_line({ x1, y1 }, { x2, y2 }, col, t or 1) end
local function text(dl, x, y, s, col) dl:add_text({ x, y }, col, s) end
local function grad_h(dl, x, y, w, h, left, right)
    dl:add_rect_filled_multi_color({ x, y }, { x + w, y + h }, left, right, right, left)
end
local function grad_v(dl, x, y, w, h, top, bottom)
    dl:add_rect_filled_multi_color({ x, y }, { x + w, y + h }, top, top, bottom, bottom)
end

local function tri(dl, x, y, size, dir, col)
    if dir < 0 then
        dl:add_triangle_filled({ x, y }, { x + size, y - size }, { x + size, y + size }, col)
    else
        dl:add_triangle_filled({ x + size, y }, { x, y - size }, { x, y + size }, col)
    end
end

-- Text cut to a width (with "...").
local function fit(s, w)
    if text_w(s) <= w then return s end
    local n = #s
    while n > 1 and text_w(s:sub(1, n) .. "...") > w do n = n - 1 end
    -- never cut in the middle of a UTF-8 character
    while n > 1 and (s:byte(n + 1) or 0) >= 0x80 and (s:byte(n + 1) or 0) < 0xC0 do n = n - 1 end
    return s:sub(1, n) .. "..."
end

-- Word wrap into lines no wider than w.
local function wrap(s, w)
    local out, cur = {}, ""
    for word in s:gmatch("%S+") do
        local try = cur == "" and word or (cur .. " " .. word)
        if text_w(try) <= w or cur == "" then
            cur = try
        else
            out[#out + 1] = cur
            cur = word
        end
    end
    if cur ~= "" then out[#out + 1] = cur end
    return out
end

-- An invisible clickable area: clicked, hovered.
local function hit(id, x, y, w, h)
    imgui.set_cursor_screen_pos({ x, y })
    local clicked = imgui.invisible_button(id, { math.max(1, w), math.max(1, h) })
    local hovered = imgui.is_item_hovered()
    return clicked == true, hovered == true
end

local function spinner(dl, cx, cy, r, now, col)
    local a = (now * 5.0) % (2 * math.pi)
    dl:path_clear()
    dl:path_arc_to({ cx, cy }, r, a, a + 4.4, 24)
    dl:path_stroke(col, 0, math.max(2, 2.5 * S))
end

local function check(dl, cx, cy, r, col)
    local t = math.max(2, 2.5 * S)
    line(dl, cx - r * 0.6, cy, cx - r * 0.15, cy + r * 0.5, col, t)
    line(dl, cx - r * 0.15, cy + r * 0.5, cx + r * 0.7, cy - r * 0.55, col, t)
end

-- A section caption with its rule (RE4's thin line with a red start).
local function caption(dl, x, y, w, label)
    with_size(18, function()
        text(dl, x, y, label, C.dim)
    end)
    local ly = y + px(26)
    line(dl, x, ly, x + w, ly, C.panel_edge, 1)
    line(dl, x, ly, x + px(48), ly, C.accent, 2)
    return ly + px(12)
end

-------------------------------------------------------------------------------
-- Rows: the focusable entries of a screen
-------------------------------------------------------------------------------

-- row = { id, label, value, kind = "select" | "toggle" | "button" | "info" | "input",
--         left(), right(), activate(), enabled, value_color }
local function row_enabled(r) return r.enabled ~= false and r.kind ~= "info" end

local function move_focus(rows, cur, d)
    local idx = 1
    for i, r in ipairs(rows) do
        if r.id == cur then idx = i end
    end
    local n = #rows
    for _ = 1, n do
        idx = ((idx - 1 + d) % n) + 1
        if row_enabled(rows[idx]) then return rows[idx].id end
    end
    return cur
end

local function focused_row(rows, id)
    for _, r in ipairs(rows) do
        if r.id == id then return r end
    end
    return nil
end

local function first_enabled(rows)
    for _, r in ipairs(rows) do
        if row_enabled(r) then return r.id end
    end
    return nil
end

-- Keyboard / pad commands of this frame on a screen's rows. on_cancel(focused row).
local function apply_nav(screen, rows, nav, on_cancel)
    local cur = st.focus[screen]
    if focused_row(rows, cur) == nil or not row_enabled(focused_row(rows, cur)) then
        cur = first_enabled(rows)
        st.focus[screen] = cur
    end
    for _, cmd in ipairs(nav) do
        local r = focused_row(rows, cur)
        if cmd == "up" then
            cur = move_focus(rows, cur, -1)
        elseif cmd == "down" then
            cur = move_focus(rows, cur, 1)
        elseif cmd == "left" or cmd == "page_left" then
            if r and r.kind == "button" and r.group then
                cur = move_focus(rows, cur, -1)
            elseif r and r.left then
                r.left()
            end
        elseif cmd == "right" or cmd == "page_right" then
            if r and r.kind == "button" and r.group then
                cur = move_focus(rows, cur, 1)
            elseif r and r.right then
                r.right()
            end
        elseif cmd == "decide" then
            if r and r.activate then r.activate() elseif r and r.right then r.right() end
        elseif cmd == "cancel" then
            local to = on_cancel and on_cancel(r)
            if to ~= nil then cur = to end
        end
        st.focus[screen] = cur
    end
    st.focus[screen] = cur
end

-- One settings row: label on the left, value on the right with arrows (select), a box
-- (toggle) or nothing (button). Returns its height.
local function draw_row(dl, r, x, y, w, focused)
    local h = px(r.height or 40)
    local enabled = r.enabled ~= false
    local clicked, hovered = false, false
    if r.kind ~= "info" then
        clicked, hovered = hit("##row_" .. r.id, x, y, r.hit_w or w, h)
    end
    if hovered and enabled and r.kind ~= "info" and st.mouse_moved then
        st.focus[st.screen] = r.id
        focused = true
    end
    if focused and enabled then
        grad_h(dl, x, y, w, h, C.accent_soft, C.accent_clear)
        rect(dl, x, y, px(4), h, C.accent)
    end
    local label_col = not enabled and C.faint or (focused and C.text or C.text_soft)
    with_size(r.size or 21, function()
        local th = text_h()
        local ty = y + (h - th) / 2
        text(dl, x + px(18), ty, fit(r.label or "", w * 0.55), label_col)
        if r.kind == "select" then
            local v = r.value or ""
            local vw = text_w(v)
            local right = x + w - px(16)
            local arrow = px(7)
            local vcol = not enabled and C.faint or (r.value_color or (focused and C.gold or C.text_soft))
            text(dl, right - arrow * 2 - px(12) - vw, ty, v, vcol)
            if enabled and r.left ~= nil then
                local ax = right - arrow * 2 - px(26) - vw - arrow
                tri(dl, ax, y + h / 2, arrow, -1, focused and C.text or C.dim)
                tri(dl, right - arrow, y + h / 2, arrow, 1, focused and C.text or C.dim)
                if clicked then
                    local mx = imgui.get_mouse().x
                    if mx >= ax - px(8) and mx <= ax + arrow + px(8) then r.left() else r.right() end
                    clicked = false
                end
            end
        elseif r.kind == "toggle" then
            local bx, bs = x + w - px(16) - px(20), px(20)
            local by = y + (h - bs) / 2
            frame(dl, bx, by, bs, bs, enabled and (focused and C.text or C.dim) or C.faint, math.max(1, S * 1.5))
            if r.value then rect(dl, bx + px(4), by + px(4), bs - px(8), bs - px(8), enabled and C.accent or C.faint) end
            local word = r.value and "Sí" or "No"
            text(dl, bx - px(12) - text_w(word), ty, word, enabled and (focused and C.gold or C.dim) or C.faint)
        elseif r.kind == "info" and r.value then
            text(dl, x + w - px(16) - text_w(r.value), ty, r.value, r.value_color or C.dim)
        end
    end)
    if clicked and enabled then
        st.focus[st.screen] = r.id
        if r.activate then r.activate() elseif r.right then r.right() end
    end
    return h
end

-- A button of the bottom bar. Returns its width.
local function draw_button(dl, r, x, y, focused)
    local enabled = r.enabled ~= false
    local w, h
    with_size(20, function()
        w = text_w(r.label) + px(56)
        h = px(46)
    end)
    local clicked, hovered = hit("##btn_" .. r.id, x, y, w, h)
    if hovered and enabled and st.mouse_moved then
        st.focus[st.screen] = r.id
        focused = true
    end
    if focused and enabled then
        rect(dl, x, y, w, h, C.accent)
        frame(dl, x, y, w, h, 0x80FFFFFF, 1)
    else
        rect(dl, x, y, w, h, 0xC0000000)
        frame(dl, x, y, w, h, enabled and C.panel_edge or 0x20FFFFFF, 1)
    end
    with_size(20, function()
        local col = not enabled and C.faint or (focused and C.text or C.text_soft)
        text(dl, x + (w - text_w(r.label)) / 2, y + (h - text_h()) / 2, r.label, col)
    end)
    if clicked then
        st.focus[st.screen] = r.id
        if enabled and r.activate then r.activate() end
    end
    return w
end

-- A text box (ImGui InputText) styled like the rows. Returns changed, value, entered.
local function input_box(id, x, y, w, value, opts)
    opts = opts or {}
    push_color(COL_FRAME, C.input_bg)
    push_color(COL_FRAME_HOVER, C.input_hover)
    push_color(COL_FRAME_ACTIVE, C.input_hover)
    push_color(COL_BORDER, opts.focused and C.accent or C.panel_edge)
    push_color(COL_TEXT, C.text)
    imgui.push_style_var(VAR_FRAME_ROUNDING, 0.0)
    imgui.push_style_var(VAR_FRAME_BORDER, 1.0)
    local changed, v, entered = false, value, false
    local ok, err = pcall(function()
        with_size(opts.size or 20, function()
            imgui.set_cursor_screen_pos({ x, y })
            imgui.push_item_width(w)
            local c, nv = imgui.input_text(id, value or "", opts.enter and FLAG_ENTER_RETURNS or 0)
            imgui.pop_item_width()
            if type(nv) == "string" then v = nv end
            if opts.enter then
                entered = c == true
                changed = v ~= value
            else
                changed = c == true
            end
            if imgui.is_item_active() then
                st.text_active = true
            end
        end)
    end)
    imgui.pop_style_var(2)
    imgui.pop_style_color(5)
    if not ok then error(err, 0) end
    return changed, v, entered
end

-------------------------------------------------------------------------------
-- Common frame of our screens
-------------------------------------------------------------------------------

local function backdrop(dl, W, H)
    grad_v(dl, 0, 0, W, H, C.shade_top, C.shade_bottom)
    -- a darker band behind the content on the left, like the game's menus
    grad_h(dl, 0, 0, W * 0.5, H, 0xC0000000, 0x00000000)
end

local function header(dl, W, H, title, subtitle)
    local x, y = W * 0.06, H * 0.07
    with_size(16, function() text(dl, x, y, "RESIDENT EVIL 4  ·  CO-OP", C.dim) end)
    with_size(46, function() text(dl, x, y + px(22), title, C.text) end)
    local ly = y + px(84)
    line(dl, x, ly, W * 0.94, ly, C.panel_edge, 1)
    line(dl, x, ly, x + px(140), ly, C.accent, 3)
    if subtitle then
        with_size(18, function() text(dl, x, ly + px(10), subtitle, C.dim) end)
    end
    return ly + px(48)
end

local function guide(dl, W, H, parts)
    with_size(17, function()
        local s = table.concat(parts, "     ")
        text(dl, W * 0.94 - text_w(s), H * 0.955, s, C.dim)
    end)
end

local function notice(dl, x, y, msg, col)
    if msg == nil or msg == "" then return end
    with_size(18, function() text(dl, x, y, msg, col or C.dim) end)
end

-------------------------------------------------------------------------------
-- The lobby screen
-------------------------------------------------------------------------------

local function chapter_text(n)
    return ("Capítulo %d"):format(n)
end

local function save_text(save)
    if save == nil then return "..." end
    if save.empty ~= false then return "Vacío" end
    local c = Lobby.chapter_of_id(save.chapter_id)
    local d = Lobby.difficulty_label(save.difficulty)
    return ("%s · %s"):format(c and chapter_text(c) or "?", d)
end

local function loadout_weapons(env, l)
    if l == nil or #l.weapons == 0 then return l and l.desc or "" end
    local names = {}
    local known = env.session.weapon_names or {}
    for _, wp in ipairs(l.weapons) do names[#names + 1] = known[wp] or ("wp" .. wp) end
    return table.concat(names, " + ")
end

local function game_rows(env, view)
    local lobby, s = env.lobby, env.settings
    local host = view.host
    local NEW = P.LOBBY_MODE.NEW
    local rows = {}
    local save = view.save
    rows[#rows + 1] = { id = "file", kind = "select", label = "Guardado multijugador",
        value = ("Coop %d: %s"):format(view.file or 1, save_text(save)), enabled = host,
        left = function() lobby:cycle_file(-1) end, right = function() lobby:cycle_file(1) end }
    local can_continue = save ~= nil and save.empty == false
    rows[#rows + 1] = { id = "mode", kind = "select", label = "Partida",
        value = view.mode == NEW and (can_continue and "Nueva (sobrescribe)" or "Nueva partida") or "Continuar",
        value_color = (view.mode == NEW and can_continue) and C.warn or nil,
        enabled = host and can_continue,
        left = function() lobby:cycle_mode() end, right = function() lobby:cycle_mode() end }
    local chapter_value
    if view.mode == NEW then
        chapter_value = chapter_text(view.chapter or 1)
    else
        chapter_value = (view.chapter or 0) == 0 and "Donde está el guardado" or chapter_text(view.chapter)
    end
    rows[#rows + 1] = { id = "chapter", kind = "select", label = "Capítulo", value = chapter_value, enabled = host,
        left = function() lobby:cycle_chapter(-1) end, right = function() lobby:cycle_chapter(1) end }
    rows[#rows + 1] = { id = "difficulty", kind = "select", label = "Dificultad",
        value = view.mode == NEW and Lobby.difficulty_label(view.difficulty) or "La del guardado",
        enabled = host and view.mode == NEW,
        left = function() lobby:cycle_difficulty(-1) end, right = function() lobby:cycle_difficulty(1) end }
    for i, o in ipairs(Lobby.OPTIONS) do
        local on = ((view.options or 0) >> (i - 1)) & 1 == 1
        rows[#rows + 1] = { id = "opt_" .. o.key, kind = "toggle", label = o.label, value = on, enabled = host,
            height = 34, size = 18, activate = function() lobby:toggle_option(o.key) end,
            left = function() lobby:toggle_option(o.key) end, right = function() lobby:toggle_option(o.key) end }
    end
    return rows
end

local function player_card(dl, x, y, w, p, env, now)
    local h = px(96)
    rect(dl, x, y, w, h, C.panel)
    frame(dl, x, y, w, h, C.panel_edge, 1)
    if p == nil then
        with_size(20, function()
            local dots = ("."):rep(1 + math.floor(now * 2) % 3)
            text(dl, x + px(20), y + px(20), "Esperando a otro jugador" .. dots, C.dim)
        end)
        with_size(16, function()
            text(dl, x + px(20), y + px(54), "Comparte tu dirección (abajo a la derecha)", C.faint)
        end)
        return h
    end
    rect(dl, x, y, px(4), h, p.ready and C.ok or C.faint)
    with_size(24, function() text(dl, x + px(20), y + px(12), fit(p.name or "?", w - px(180)), C.text) end)
    with_size(16, function()
        text(dl, x + px(20), y + px(46), p.host and "ANFITRIÓN" or "INVITADO", C.dim)
        local l = Lobby.loadout(p.loadout)
        text(dl, x + px(20), y + px(68), fit("Equipo: " .. (l and l.name or "?"), w - px(40)), C.text_soft)
    end)
    with_size(18, function()
        local tag, col
        if p.in_lobby == false then
            tag, col = "FUERA DE LA SALA", C.warn
        elseif p.ready then
            tag, col = "LISTO", C.ok
        else
            tag, col = "NO LISTO", C.dim
        end
        local tw = text_w(tag)
        local bx = x + w - tw - px(40)
        frame(dl, bx, y + px(14), tw + px(24), px(30), col, 1)
        text(dl, bx + px(12), y + px(14) + (px(30) - text_h()) / 2, tag, col)
    end)
    return h
end

local function chat_panel(dl, x, y, w, h, env)
    rect(dl, x, y, w, h, C.panel)
    frame(dl, x, y, w, h, C.panel_edge, 1)
    local msgs = env.session.messages or {}
    local lines = {}
    with_size(17, function()
        local lh = text_h() + px(4)
        local max_lines = math.max(1, math.floor((h - px(70)) / lh))
        for i = #msgs, 1, -1 do
            local m = msgs[i]
            local col = C.text_soft
            if m.kind == "chat" then col = C.chat elseif m.kind == "error" then col = C.err
            elseif m.kind == "warn" then col = C.warn elseif m.kind == "good" then col = C.ok end
            local wrapped = wrap(m.text or "", w - px(32))
            for j = #wrapped, 1, -1 do
                table.insert(lines, 1, { wrapped[j], col })
            end
            if #lines >= max_lines then break end
        end
        while #lines > max_lines do table.remove(lines, 1) end
        local ty = y + px(14)
        for _, l in ipairs(lines) do
            text(dl, x + px(16), ty, l[1], l[2])
            ty = ty + lh
        end
    end)
    local connected = env.status.state == "connected"
    local iy = y + h - px(48)
    if connected then
        local _, v, entered = input_box("##lobby_chat", x + px(12), iy, w - px(24), st.chat, { enter = true })
        st.chat = v
        if entered and st.chat ~= "" then
            if env.session:send_chat(st.chat) then st.chat = "" end
        end
        if st.chat == "" and not st.text_active then
            with_size(17, function() text(dl, x + px(24), iy + px(9), "Escribe un mensaje y pulsa Enter...", C.faint) end)
        end
    else
        with_size(17, function() text(dl, x + px(16), iy + px(9), "El chat se activa cuando se una otro jugador", C.faint) end)
    end
end

local function draw_lobby(dl, W, H, env, now, nav)
    local lobby, session, s = env.lobby, env.session, env.settings
    local status = env.status
    local host = session.role == "host"
    local view = lobby:view()
    local title = host and "SALA MULTIJUGADOR" or "SALA DEL ANFITRIÓN"
    local sub
    if status.state == "listening" then
        sub = "Esperando a que alguien se una a tu sala"
    elseif status.state == "connecting" then
        sub = "Conectando..."
    elseif status.state == "connected" then
        sub = ("%s %s  ·  %.0f ms"):format(host and "Con" or "Conectado a", status.partner_name or "?", status.rtt_ms or 0)
    else
        sub = "Sin conexión"
    end
    local top = header(dl, W, H, title, sub)
    local col_w = W * 0.29
    local x1, x2, x3 = W * 0.06, W * 0.38, W * 0.67
    local x3w = W * 0.27

    local rows = {}
    -- Left: the game.
    local y = caption(dl, x1, top, col_w, "LA PARTIDA")
    local host_playing = not host and view == nil and session.partner_state ~= nil
    local grows = {}
    if view ~= nil then
        grows = game_rows(env, view)
    else
        with_size(19, function()
            local msg = host_playing and "El anfitrión ya está jugando (no está en su sala)."
                or "Esperando los datos de la sala del anfitrión..."
            for i, l in ipairs(wrap(msg, col_w)) do text(dl, x1 + px(4), y + (i - 1) * px(26), l, C.dim) end
        end)
        if host_playing then
            grows[#grows + 1] = { id = "join_running", kind = "button", label = "Unirse a su partida en curso",
                activate = function() lobby:join_game_in_progress() end }
        end
    end
    local game_h_end = y
    for i, r in ipairs(grows) do
        rows[#rows + 1] = r
        if r.kind == "button" then
            draw_button(dl, r, x1, y + px(60), st.focus.lobby == r.id)
        else
            if i == 5 then
                y = caption(dl, x1, y + px(16), col_w, host and "OPCIONES DE LA PARTIDA" or "OPCIONES DEL ANFITRIÓN")
            end
            y = y + draw_row(dl, r, x1, y, col_w, st.focus.lobby == r.id)
        end
        game_h_end = y
    end

    -- Middle: the players and my loadout.
    y = caption(dl, x2, top, col_w, "JUGADORES")
    local me = { name = s.player_name, host = host, ready = lobby.me.ready, loadout = lobby.me.loadout, in_lobby = true }
    local partner = lobby.partner
    local them = partner and { name = partner.name, host = not host, ready = partner.ready, loadout = partner.loadout,
        in_lobby = partner.in_lobby } or (status.state == "connected" and { name = status.partner_name, host = not host,
        ready = false, loadout = 1, in_lobby = false } or nil)
    local first, second = me, them
    if not host then first, second = them, me end
    y = y + player_card(dl, x2, y, col_w, first, env, now) + px(10)
    y = y + player_card(dl, x2, y, col_w, second, env, now) + px(22)
    y = caption(dl, x2, y, col_w, "TU EQUIPO INICIAL")
    local l = Lobby.loadout(lobby.me.loadout)
    local lrow = { id = "loadout", kind = "select", label = "Equipo", value = l and l.name or "?",
        left = function() lobby:cycle_loadout(-1) end, right = function() lobby:cycle_loadout(1) end,
        enabled = lobby.start == nil or lobby.start.released }
    rows[#rows + 1] = lrow
    y = y + draw_row(dl, lrow, x2, y, col_w, st.focus.lobby == lrow.id)
    with_size(17, function()
        for i, ln in ipairs(wrap(loadout_weapons(env, l), col_w - px(36))) do
            text(dl, x2 + px(18), y + px(6) + (i - 1) * px(22), ln, C.dim)
        end
    end)

    -- Right: chat and the address to join.
    local cy = caption(dl, x3, top, x3w, "CHAT")
    local chat_h = H * 0.86 - cy - px(150)
    chat_panel(dl, x3, cy, x3w, chat_h, env)
    local ay = cy + chat_h + px(18)
    with_size(17, function()
        if host then
            text(dl, x3, ay, "Tu compañero se une con:", C.dim)
            local addrs = env.addresses or {}
            if #addrs == 0 then
                text(dl, x3, ay + px(24), "(no se encontró ninguna dirección de red)", C.warn)
            end
            for i, a in ipairs(addrs) do
                if i > 3 then break end
                text(dl, x3, ay + px(24) * i, ("%s:%d"):format(a, s.port or 33040), C.gold)
            end
        elseif status.stats and status.stats.peer then
            text(dl, x3, ay, "Conectado a " .. tostring(status.stats.peer), C.dim)
        end
    end)

    -- Bottom bar.
    local by = H * 0.86
    line(dl, x1, by - px(16), W * 0.94, by - px(16), C.panel_edge, 1)
    local buttons = {}
    local can, why = lobby:can_start()
    buttons[#buttons + 1] = { id = "ready", kind = "button", group = true,
        label = lobby.me.ready and "NO ESTOY LISTO" or "ESTOY LISTO", enabled = status.state == "connected",
        activate = function() lobby:toggle_ready() end }
    if host then
        buttons[#buttons + 1] = { id = "start", kind = "button", group = true, label = "COMENZAR", enabled = can,
            activate = function()
                local ok, w = lobby:request_start(now)
                if not ok then st.hint = { text = w, till = now + 4 } end
            end }
    end
    buttons[#buttons + 1] = { id = "options", kind = "button", group = true, label = "OPCIONES",
        activate = function() lobby:open(Lobby.SCREEN.OPTIONS, Lobby.SCREEN.LOBBY) end }
    buttons[#buttons + 1] = { id = "leave", kind = "button", group = true, label = "SALIR DE LA SALA",
        activate = function() session:queue("lobby_leave") end }
    local bx = x1
    for _, b in ipairs(buttons) do
        rows[#rows + 1] = b
        bx = bx + draw_button(dl, b, bx, by, st.focus.lobby == b.id) + px(14)
    end
    local hint = nil
    if host and not can then hint = why
    elseif not host and status.state == "connected" then
        hint = lobby.me.ready and "Esperando a que el anfitrión comience la partida" or "Marca que estás listo"
    end
    if st.hint ~= nil and now > st.hint.till then st.hint = nil end
    notice(dl, x1, by + px(58), st.hint and st.hint.text or hint, st.hint and C.warn or C.dim)
    guide(dl, W, H, { "Enter: Elegir", "Flechas: Cambiar", "Esc: Volver" })

    apply_nav("lobby", rows, nav, function(r)
        if r and r.id == "leave" then
            session:queue("lobby_leave")
            return nil
        end
        return "leave" -- first Cancel: to "leave the lobby"
    end)
end

-------------------------------------------------------------------------------
-- Joining a host
-------------------------------------------------------------------------------

local function draw_join(dl, W, H, env, now, nav)
    local session, s, lobby = env.session, env.settings, env.lobby
    local status = env.status
    local top = header(dl, W, H, "UNIRSE A PARTIDA", "Escribe la dirección del anfitrión (IP o IP:puerto) y conéctate")
    local x, w = W * 0.06, W * 0.42
    local y = caption(dl, x, top, w, "CONEXIÓN")
    local rows = {}
    local busy = status.state == "connecting" or status.state == "connected"
    local function input_row(id, label, key, numeric)
        local iw = w * 0.5
        local r = { id = id, kind = "input", label = label, hit_w = w - iw - px(24) }
        rows[#rows + 1] = r
        local h = draw_row(dl, r, x, y, w, st.focus.join == id)
        local value = tostring(s[key] or "")
        local changed, v = input_box("##join_" .. id, x + w - iw - px(12), y + (h - px(36)) / 2, iw, value,
            { focused = st.focus.join == id })
        if changed and not busy then
            if numeric then
                local n = tonumber(v)
                if n then s[key] = math.floor(n) end
            else
                s[key] = v
            end
        end
        y = y + h
    end
    input_row("name", "Tu nombre", "player_name")
    input_row("address", "Dirección del anfitrión", "last_address")
    input_row("port", "Puerto (UDP)", "port", true)
    input_row("password", "Contraseña (si la hay)", "password")
    y = y + px(26)
    local buttons = {
        { id = "connect", kind = "button", group = true, label = status.state == "connecting" and "CONECTANDO..." or "CONECTAR",
            enabled = not busy, activate = function()
                Config.sanitize(s)
                session:queue("join", s.last_address)
            end },
        { id = "back", kind = "button", group = true, label = "VOLVER", activate = function()
            if status.state == "connecting" then session:queue("leave") end
            lobby:back()
        end },
    }
    local bx = x
    for _, b in ipairs(buttons) do
        rows[#rows + 1] = b
        bx = bx + draw_button(dl, b, bx, y, st.focus.join == b.id) + px(14)
    end
    y = y + px(70)
    if status.state == "connecting" then
        spinner(dl, x + px(12), y + px(12), px(10), now, C.text)
        notice(dl, x + px(34), y, ("Conectando con %s..."):format(tostring(status.stats and status.stats.peer or s.last_address)), C.text_soft)
    elseif status.last_error and status.state == "idle" then
        notice(dl, x, y, "No se pudo conectar: " .. tostring(status.last_error), C.err)
    end
    -- What joining does.
    local hx = W * 0.56
    local hy = caption(dl, hx, top, W * 0.38, "CÓMO FUNCIONA")
    with_size(18, function()
        local tips = {
            "El anfitrión elige \"Host Game\" en su menú Multijugador y te dice su dirección (aparece en su sala).",
            "Por internet, usad una VPN como Radmin VPN o ZeroTier, o abrid el puerto UDP en el router del anfitrión.",
            "Al conectarte entrarás en su sala: allí elegís partida, capítulo y equipo, y los dos marcáis \"Listo\".",
        }
        for _, tip in ipairs(tips) do
            for _, ln in ipairs(wrap(tip, W * 0.36)) do
                text(dl, hx, hy, ln, C.dim)
                hy = hy + px(26)
            end
            hy = hy + px(12)
        end
    end)
    guide(dl, W, H, { "Haz clic en un campo para escribir", "Enter: Elegir", "Esc: Volver" })
    apply_nav("join", rows, nav, function()
        if status.state == "connecting" then session:queue("leave") end
        lobby:back()
        return nil
    end)
end

-------------------------------------------------------------------------------
-- Multiplayer options
-------------------------------------------------------------------------------

local OPTION_GROUPS = {
    { "TU COMPAÑERO", col = 2, {
        { "show_partner", "Ver el personaje de tu compañero" },
        { "partner_audio", "Sus sonidos (disparos, pasos, voz)" },
        { "partner_effects", "Sus efectos (fogonazos)" },
        { "show_nametag", "Su nombre y vida sobre su cabeza" },
        { "hide_partner_in_cutscenes", "Ocultarlo en las escenas" },
        { "show_hud", "Estado de la conexión arriba a la izquierda" },
    } },
    { "ENEMIGOS (LOS DEL ANFITRIÓN)", col = 2, {
        { "enemy_partner_hits", "Sus golpes también hieren al invitado" },
        { "enemy_partner_grabs", "Pueden agarrar al invitado" },
        { "enemy_partner_parry", "Avisos de ataque y parada para el invitado" },
        { "enemy_partner_bosses", "Los jefes también van a por el invitado" },
        { "sync_drops", "Cada uno recibe su botín de cada enemigo" },
    } },
    { "MUNDO COMPARTIDO", col = 1, {
        { "sync_cutscenes", "Las escenas se ven en los dos juegos" },
        { "sync_triggers", "Los eventos de un jugador ocurren para los dos" },
        { "sync_gimmicks", "Puertas, cerraduras, palancas y puzles" },
        { "sync_purposes", "El objetivo más avanzado para los dos" },
        { "follow_host_chapter", "Seguir al anfitrión al siguiente capítulo" },
    } },
}

local function draw_options(dl, W, H, env, now, nav)
    local s, lobby = env.settings, env.lobby
    local top = header(dl, W, H, "OPCIONES MULTIJUGADOR", "Se guardan al volver")
    local rows = {}
    local col_w = W * 0.4
    local xs = { W * 0.06, W * 0.54 }
    local ys = { top, top }
    local function place(col, r)
        rows[#rows + 1] = r
        ys[col] = ys[col] + draw_row(dl, r, xs[col], ys[col], col_w, st.focus.options == r.id)
    end
    -- Column 1: you and the network.
    ys[1] = caption(dl, xs[1], ys[1], col_w, "TÚ")
    local function input_row(col, id, label, key, numeric)
        local iw = col_w * 0.45
        local r = { id = id, kind = "input", label = label, hit_w = col_w - iw - px(24) }
        rows[#rows + 1] = r
        local y = ys[col]
        local h = draw_row(dl, r, xs[col], y, col_w, st.focus.options == id)
        local changed, v = input_box("##opt_" .. id, xs[col] + col_w - iw - px(12), y + (h - px(36)) / 2, iw,
            tostring(s[key] or ""), { focused = st.focus.options == id })
        if changed then
            if numeric then
                local n = tonumber(v)
                if n then s[key] = math.floor(n) end
            else
                s[key] = v
            end
        end
        ys[col] = y + h
    end
    input_row(1, "name", "Tu nombre", "player_name")
    input_row(1, "port", "Puerto (UDP)", "port", true)
    input_row(1, "password", "Contraseña de la sala", "password")
    ys[1] = caption(dl, xs[1], ys[1] + px(10), col_w, "GUARDADOS Y COMIENZO")
    place(1, { id = "coop_host_first_slot", kind = "select", label = "Guardados coop del anfitrión (ranuras)",
        value = ("%d-%d"):format(s.coop_host_first_slot, s.coop_host_first_slot + Lobby.FILES - 1),
        left = function() s.coop_host_first_slot = math.max(1, s.coop_host_first_slot - 1) end,
        right = function() s.coop_host_first_slot = math.min(21 - Lobby.FILES, s.coop_host_first_slot + 1) end })
    place(1, { id = "coop_save_slot", kind = "select", label = "Guardado coop del invitado (ranura)",
        value = tostring(s.coop_save_slot),
        left = function() s.coop_save_slot = math.max(1, s.coop_save_slot - 1) end,
        right = function() s.coop_save_slot = math.min(20, s.coop_save_slot + 1) end })
    place(1, { id = "start_sync", kind = "toggle", label = "Empezar juntos (esperar a que ambos carguen)",
        value = s.start_sync ~= false, activate = function() s.start_sync = not (s.start_sync ~= false) end,
        left = function() s.start_sync = not (s.start_sync ~= false) end, right = function() s.start_sync = not (s.start_sync ~= false) end })
    place(1, { id = "start_timeout", kind = "select", label = "Esperar como mucho",
        value = ("%d s"):format(s.start_timeout or 120),
        left = function() s.start_timeout = math.max(30, (s.start_timeout or 120) - 15) end,
        right = function() s.start_timeout = math.min(600, (s.start_timeout or 120) + 15) end })
    -- Column 2 (and the rest of column 1): the switches.
    for _, group in ipairs(OPTION_GROUPS) do
        local col = group.col
        ys[col] = caption(dl, xs[col], ys[col] + (ys[col] > top and px(10) or 0), col_w, group[1])
        for _, o in ipairs(group[2]) do
            local key = o[1]
            local function flip() s[key] = not (s[key] == true) end
            place(col, { id = key, kind = "toggle", label = o[2], value = s[key] == true, height = 34, size = 18,
                activate = flip, left = flip, right = flip })
        end
    end
    local by = H * 0.88
    local back = { id = "back", kind = "button", label = "GUARDAR Y VOLVER", activate = function()
        Config.sanitize(s)
        if env.json then Config.save(env.json, s) end
        lobby:back()
    end }
    rows[#rows + 1] = back
    draw_button(dl, back, xs[1], by, st.focus.options == back.id)
    guide(dl, W, H, { "Enter: Cambiar", "Esc: Guardar y volver" })
    apply_nav("options", rows, nav, function()
        back.activate()
        return nil
    end)
end

-------------------------------------------------------------------------------
-- While a game the lobby started loads
-------------------------------------------------------------------------------

local function draw_loaders(dl, W, H, loaders, now, alpha)
    local x = px(48)
    local y = H - px(64) - #loaders * px(66)
    for _, l in ipairs(loaders) do
        local h = px(56)
        local w = px(400)
        grad_h(dl, x - px(16), y, w + px(60), h, 0xC0000000, 0x00000000)
        rect(dl, x - px(16), y, px(3), h, l.done and C.ok or C.accent)
        local cx, cy, r = x + px(14), y + h / 2, px(12)
        if l.done then
            dl:add_circle({ cx, cy }, r + px(2), C.ok, 24, math.max(1.5, 2 * S))
            check(dl, cx, cy, r * 0.8, C.ok)
        elseif l.phase == P.LOAD_PHASE.FAILED then
            dl:add_circle({ cx, cy }, r + px(2), C.err, 24, math.max(1.5, 2 * S))
        else
            dl:add_circle({ cx, cy }, r + px(2), 0x30FFFFFF, 24, math.max(1.5, 2 * S))
            spinner(dl, cx, cy, r + px(2), now, C.text)
        end
        with_size(20, function()
            text(dl, x + px(40), y + px(6), fit(l.name or "?", w - px(60)), C.text)
        end)
        with_size(15, function()
            local role = l.host and "ANFITRIÓN" or "INVITADO"
            text(dl, x + px(40), y + px(32), ("%s  ·  %s"):format(role, l.label), l.done and C.ok or C.dim)
        end)
        -- the progress line: a running stripe while loading, full when ready
        local ly, lw = y + h - px(3), w
        rect(dl, x + px(40), ly, lw - px(40), px(2), 0x30FFFFFF)
        if l.done then
            rect(dl, x + px(40), ly, lw - px(40), px(2), C.ok)
        elseif l.phase ~= P.LOAD_PHASE.FAILED then
            local span = (lw - px(40)) * 0.3
            local t = (now * 0.6) % 1.3 - 0.3
            local sx = x + px(40) + math.max(0, t) * (lw - px(40))
            local ex = math.min(x + lw, sx + span)
            if ex > sx then rect(dl, sx, ly, ex - sx, px(2), C.accent) end
        end
        y = y + px(66)
    end
end

local function draw_start(env, now)
    local lobby = env.lobby
    local loaders = lobby:loaders(now)
    if loaders == nil then return false end
    local view = lobby:start_view(now) or {}
    local size = imgui.get_display_size()
    local W, H = size.x or size[1], size.y or size[2]
    S = math.max(0.6, H / 1080)
    local dl = imgui.get_foreground_draw_list()
    if view.waiting then
        rect(dl, 0, 0, W, H, C.veil)
        local partner = lobby.partner and lobby.partner.name or env.session.partner_name or "tu compañero"
        with_size(34, function()
            local t = ("ESPERANDO A %s"):format(partner:upper())
            text(dl, (W - text_w(t)) / 2, H * 0.42, t, C.text)
        end)
        with_size(19, function()
            local t = "Tu mapa ya ha cargado: empezaréis los dos a la vez"
            text(dl, (W - text_w(t)) / 2, H * 0.42 + px(56), t, C.dim)
            if view.can_skip then
                local key = env.session.key_name and env.session.key_name(env.settings.continue_key) or "F8"
                local k = ("Pulsa %s para empezar sin esperar (%.0f s)"):format(key, view.waited or 0)
                text(dl, (W - text_w(k)) / 2, H * 0.42 + px(88), k, C.warn)
            end
        end)
        line(dl, W * 0.35, H * 0.42 + px(46), W * 0.65, H * 0.42 + px(46), C.panel_edge, 1)
        line(dl, W * 0.5 - px(60), H * 0.42 + px(46), W * 0.5 + px(60), H * 0.42 + px(46), C.accent, 2)
    end
    draw_loaders(dl, W, H, loaders, now)
    return true
end

-------------------------------------------------------------------------------
-- Entry
-------------------------------------------------------------------------------

-- A small ring where the mouse is (the game's own cursor may be hidden under our screens).
local function cursor(dl, now)
    local m = imgui.get_mouse()
    if m == nil then return end
    local mx, my = m.x or m[1], m.y or m[2]
    local last = st.mouse
    st.mouse_moved = false
    if last == nil or math.abs(last.x - mx) + math.abs(last.y - my) > 0.5 then
        st.mouse = { x = mx, y = my, t = now }
        st.mouse_moved = last ~= nil
    end
    if now - (st.mouse and st.mouse.t or 0) < 3.0 then
        dl:add_circle({ mx, my }, px(7), 0xE0FFFFFF, 20, math.max(1.5, 1.5 * S))
        dl:add_circle_filled({ mx, my }, px(2), C.accent, 12)
    end
end

-- Is anything of ours on screen (the HUD stays away then)?
function UI.covering(lobby, now)
    if lobby == nil then return false end
    return lobby:is_open() or lobby:loaders(now) ~= nil
end

-- env = { session, lobby, settings, json, now, addresses }
function UI.draw(env)
    local lobby = env.lobby
    if lobby == nil or imgui == nil or imgui.begin_window == nil or imgui.get_display_size == nil then return end
    local now = env.now
    env.status = env.session.status_cached and env.session:status_cached() or env.session:status()
    st.text_active = false
    local ok, err = pcall(draw_start, env, now)
    if not ok then error(err, 0) end
    if not lobby:is_open() then
        st.last_screen = nil
        env.session.ui_text_active = false
        return
    end
    if st.last_screen ~= lobby.screen then
        st.last_screen = lobby.screen
        st.focus[lobby.screen] = nil
        st.hint = nil
    end
    st.screen = lobby.screen
    local size = imgui.get_display_size()
    local W, H = size.x or size[1], size.y or size[2]
    S = math.max(0.6, H / 1080)
    imgui.set_next_window_pos({ 0, 0 }, 0, { 0, 0 })
    imgui.set_next_window_size({ W, H }, 0)
    imgui.push_style_var(VAR_WINDOW_BORDER, 0.0)
    imgui.begin_window("##re4coop_lobby", nil, WINDOW_FLAGS)
    local okD, errD = pcall(function()
        local dl = imgui.get_window_draw_list()
        -- Behind every window (unclipped by our window's padding), over the game's menu.
        backdrop(has("get_background_draw_list") and imgui.get_background_draw_list() or dl, W, H)
        -- Typing in a text box: no menu commands (the game sees the keys too).
        local nav = lobby:take_nav()
        if st.text_active or now < st.text_until then nav = {} end
        cursor(dl, now)
        if lobby.screen == Lobby.SCREEN.LOBBY then
            draw_lobby(dl, W, H, env, now, nav)
        elseif lobby.screen == Lobby.SCREEN.JOIN then
            draw_join(dl, W, H, env, now, nav)
        elseif lobby.screen == Lobby.SCREEN.OPTIONS then
            draw_options(dl, W, H, env, now, nav)
        end
    end)
    imgui.end_window()
    imgui.pop_style_var(1)
    if st.text_active then st.text_until = now + 0.25 end
    env.session.ui_text_active = st.text_active or now < st.text_until
    if not okD then error(errD, 0) end
end

return UI
