-- The lobby (0.11): the "Multijugador" section of the game's own main menu, the room where the
-- host and the client agree on the next game (co-op save, chapter, difficulty, options, each
-- player's loadout) and say they are ready, and the synchronized start: once both games were
-- asked to start, each one holds its map as soon as it has loaded, until the partner's has
-- loaded too; then both maps start together.
--
-- Pure Lua (tests/lua/test_lobby.lua): no game APIs. session.lua carries out what the lobby
-- asks for (take_action) and tells it what the game is doing (tick's env), lobby_ui.lua draws
-- it, game_menu.lua puts its entries into the game's main menu (docs/RESEARCH.md 3.31).

local Lobby = {}
Lobby.__index = Lobby

Lobby.SCREEN = { JOIN = "join", OPTIONS = "options", LOBBY = "lobby" }

-- Our entries in the game's main menu, as chainsaw.MainMenuActionType values. The game's own
-- are 0-9 (Play, Extra, Bonus, Option, Exit, Mercenaries, Store...); any other value passes
-- MainMenuGuiBehavior.isAvliableAction and reaches GameStateMainMenu.onDecidedMainMenu, where
-- game_menu.lua takes it before the game does.
Lobby.ACTION = { MULTIPLAYER = 0x4D50, HOST = 0x4D51, JOIN = 0x4D52, OPTIONS = 0x4D53, BACK = 0x4D54 }
Lobby.LABELS = {
    [Lobby.ACTION.MULTIPLAYER] = "Multijugador",
    [Lobby.ACTION.HOST] = "Host Game",
    [Lobby.ACTION.JOIN] = "Join Game",
    [Lobby.ACTION.OPTIONS] = "Multiplayer Options",
    [Lobby.ACTION.BACK] = "Back",
}
-- The section that replaces the menu's entries once "Multijugador" is chosen.
Lobby.SECTION = { Lobby.ACTION.HOST, Lobby.ACTION.JOIN, Lobby.ACTION.OPTIONS, Lobby.ACTION.BACK }

-- The 16 chapters of the main story: the chainsaw.ChapterID each one plays in and the
-- chainsaw.CampaignInitialSettingKey a new game starts it from (Campaign1001_Master for the
-- first: a new game from the very beginning; Campaign1001_ChpX_Y_Head for the others, the
-- game's own chapter starts with their own inventory).
Lobby.CHAPTERS = {
    { n = 1, id = 21100, key = 1 },  { n = 2, id = 21200, key = 7 },  { n = 3, id = 21300, key = 8 },
    { n = 4, id = 22100, key = 9 },  { n = 5, id = 22200, key = 10 }, { n = 6, id = 22300, key = 11 },
    { n = 7, id = 23100, key = 12 }, { n = 8, id = 23200, key = 13 }, { n = 9, id = 23300, key = 14 },
    { n = 10, id = 24100, key = 15 }, { n = 11, id = 24200, key = 16 }, { n = 12, id = 24300, key = 17 },
    { n = 13, id = 25100, key = 18 }, { n = 14, id = 25200, key = 19 }, { n = 15, id = 25300, key = 20 },
    { n = 16, id = 25400, key = 21 },
}
-- ChapterIDs before chapter 1's first part (the drive, the first house) count as chapter 1.
local EXTRA_CHAPTER_IDS = { [20100] = 1, [21000] = 1 }

Lobby.DIFFICULTIES = {
    { id = 10, label = "Asistido" },
    { id = 20, label = "Estándar" },
    { id = 30, label = "Extremo" },
    { id = 40, label = "Profesional" },
}

-- Loadouts: weapons (chainsaw.WeaponID) added to the player's attache case when the game
-- starts, each with AMMO_STACKS stacks of its own ammo. The game names them (game_menu.lua);
-- the categories are the game's numbering: wp40xx handguns, 41xx shotguns, 42xx rifles,
-- 44xx submachine guns, 45xx magnums, 4600 the bolt thrower.
Lobby.LOADOUTS = {
    { id = 1, name = "Sin cambios", desc = "Empiezas con lo que te dé la partida", weapons = {} },
    { id = 2, name = "Pistolero", desc = "Dos pistolas y munición", weapons = { 4002, 4003 } },
    { id = 3, name = "Escopetero", desc = "Dos escopetas y cartuchos", weapons = { 4100, 4102 } },
    { id = 4, name = "Tirador", desc = "Fusil de cerrojo, fusil semiautomático y balas", weapons = { 4200, 4201 } },
    { id = 5, name = "Asalto", desc = "Subfusil, fusil de asalto y munición", weapons = { 4400, 4202 } },
    { id = 6, name = "Artillero", desc = "Mágnum, lanzavirotes y munición", weapons = { 4500, 4600 } },
}
Lobby.AMMO_STACKS = 2

-- Game options the host sets in the lobby (its own settings; the client sees them).
Lobby.OPTIONS = {
    { key = "enemy_partner_target", label = "Los enemigos atacan a los dos jugadores" },
    { key = "ashley_coop", label = "Una sola Ashley para los dos (Alt la cambia)" },
    { key = "share_key_items", label = "Objetos clave compartidos" },
    { key = "sync_saves", label = "Guardar la partida de los dos a la vez" },
    { key = "transition_gate", label = "Esperar al compañero en escenas y capítulos" },
    { key = "no_pause", label = "Los menús no pausan el juego" },
    { key = "give_items", label = "Dar objetos al compañero desde el maletín" },
    { key = "invincible", label = "Invencibles (para pruebas)" },
}

Lobby.FILES = 3 -- co-op save files of the host (Config: coop_host_first_slot ..)

local SEND_EVERY = 1.0       -- seconds between LOAD_STATE repeats while starting
local SETTLE = 0.75          -- seconds in the map before it counts as loaded
local START_TIMEOUT = 45.0   -- seconds the game may stay on the menu after being asked to start
local RELEASED_SHOWN = 2.5   -- seconds the loaders stay on screen once the map runs
local FINISH_AFTER = 60.0    -- seconds after the start the lobby forgets it (loadout given or not)
local LOADOUT_DELAY = 1.5    -- seconds after the start, in control of the player, before the loadout

local PHASE_LABEL = {
    [0] = "Esperando...", "Preparando la partida...", "Cargando el mapa...", "Sincronizando con el anfitrión...",
    "Listo", "En juego", "No pudo empezar",
}

local function wrap(i, n)
    return ((i - 1) % n) + 1
end

local function index_of(list, pred)
    for i, v in ipairs(list) do
        if pred(v) then return i end
    end
    return nil
end

-- opts = { protocol, settings, send(bytes, reliable), notify(text, kind), role() -> "host" | "client" |
--          "none", active() -> partner connected and compatible, my_name(), partner_name() }
function Lobby.new(opts)
    local self = setmetatable({}, Lobby)
    self.P = opts.protocol
    self.settings = opts.settings or {}
    self.send = opts.send or function() return false end
    self.notify = opts.notify or function() end
    self.role = opts.role or function() return "none" end
    self.active = opts.active or function() return false end
    self.my_name = opts.my_name or function() return self.settings.player_name or "Player" end
    self.partner_name = opts.partner_name or function() return "Partner" end
    local s = self.settings
    self.cfg = {
        rev = 0,
        file = math.max(1, math.min(Lobby.FILES, math.floor(tonumber(s.lobby_file) or 1))),
        mode = self.P.LOBBY_MODE.CONTINUE,
        chapter = math.max(1, math.min(#Lobby.CHAPTERS, math.floor(tonumber(s.lobby_chapter) or 1))),
        jump = 0, -- continuing a save: 0 = where the save is, else the chapter to go to
        difficulty = Lobby.difficulty_valid(s.lobby_difficulty) and s.lobby_difficulty or 20,
    }
    self.saves = {}           -- host: [file] = { empty, chapter_id, difficulty, count } (from the game)
    self.remote = nil         -- client: the host's last LOBBY_SETTINGS
    self.me = { ready = false, loadout = Lobby.loadout(s.lobby_loadout) and s.lobby_loadout or 1 }
    self.partner = nil        -- { name, in_lobby, ready, loadout }
    self.screen = nil         -- nil | Lobby.SCREEN.*
    self.screen_from = nil    -- the screen to go back to (Options opened from the lobby)
    self.menu_mode = "main"   -- the game's menu: "main" (with our entry) | "mp" (our section)
    self.start = nil          -- the synchronized start in progress (see begin_start)
    self.next_start_id = 1
    self.actions = {}         -- for session.lua (take_action)
    self.nav = {}             -- menu commands (decide, cancel, up, ...) for lobby_ui.lua
    self.join_running = false -- client: join the host's game in progress (the old join from the menu)
    self.counters = { starts = 0, released = 0, skipped = 0, failed = 0, loadouts = 0 }
    return self
end

-------------------------------------------------------------------------------
-- Tables
-------------------------------------------------------------------------------

function Lobby.chapter_of_id(chapter_id)
    if chapter_id == nil then return nil end
    if EXTRA_CHAPTER_IDS[chapter_id] then return EXTRA_CHAPTER_IDS[chapter_id] end
    for _, c in ipairs(Lobby.CHAPTERS) do
        if c.id == chapter_id then return c.n end
    end
    return nil
end

-- The start key of the chapter a ChapterID belongs to (a new game there), or nil.
function Lobby.key_of_id(chapter_id)
    local n = Lobby.chapter_of_id(chapter_id)
    return n and Lobby.CHAPTERS[n].key or nil
end

function Lobby.difficulty_valid(id)
    return index_of(Lobby.DIFFICULTIES, function(d) return d.id == id end) ~= nil
end

function Lobby.difficulty_label(id)
    local i = index_of(Lobby.DIFFICULTIES, function(d) return d.id == id end)
    return i and Lobby.DIFFICULTIES[i].label or "?"
end

function Lobby.loadout(id)
    local i = index_of(Lobby.LOADOUTS, function(l) return l.id == id end)
    return i and Lobby.LOADOUTS[i] or nil
end

function Lobby.phase_label(phase)
    return PHASE_LABEL[phase or 0] or "?"
end

-- The save slot of the host's co-op file (1..FILES).
function Lobby:file_slot(file)
    local first = math.floor(tonumber(self.settings.coop_host_first_slot) or 17)
    return first + (file or 1) - 1
end

-------------------------------------------------------------------------------
-- Screens and the game's menu
-------------------------------------------------------------------------------

function Lobby:is_open()
    return self.screen ~= nil
end

function Lobby:in_lobby()
    return self.screen == Lobby.SCREEN.LOBBY
end

-- The game's menu is covered (hidden, no input): one of our screens is up, or a start is on
-- its way out of the menu.
function Lobby:covers_menu()
    if self.screen ~= nil then return true end
    local s = self.start
    return s ~= nil and not s.released and not s.left_menu and s.phase ~= self.P.LOAD_PHASE.FAILED
end

function Lobby:open(screen, from)
    local was_lobby = self:in_lobby()
    self.screen = screen
    self.screen_from = from
    self.nav = {}
    if screen == Lobby.SCREEN.LOBBY and not was_lobby then
        self.me.ready = false
        self:send_player()
        if self.role() == "host" then self:send_settings() end
    end
end

-- Back from the current screen: Options opened from the lobby go back to it; anything else
-- goes back to the game's menu (our section).
function Lobby:back()
    if self.screen == Lobby.SCREEN.OPTIONS and self.screen_from == Lobby.SCREEN.LOBBY then
        self.screen, self.screen_from = Lobby.SCREEN.LOBBY, nil
        return nil
    end
    return self:close()
end

-- Closes our screens. Leaving the lobby tells the partner; returns "leave" when the session
-- should end too (the lobby was its reason to exist).
function Lobby:close()
    local was_lobby = self:in_lobby()
    self.screen, self.screen_from = nil, nil
    self.nav = {}
    self.menu_mode = "mp"
    if was_lobby then
        self.me.ready = false
        self:send_player()
        return "leave"
    end
    return nil
end

-- Client whose host is already playing (not in its lobby): leave the lobby screen and let the
-- game load into the host's game the way joining from the menu always did (save_sync.lua).
function Lobby:join_game_in_progress()
    self.screen, self.screen_from = nil, nil
    self.menu_mode = "mp"
    self.join_running = true
    self.me.ready = false
    self:send_player()
end

function Lobby:set_menu_mode(mode)
    self.menu_mode = mode == "mp" and "mp" or "main"
end

-- One of our entries was chosen in the game's menu. Returns what the session must do:
-- "host" (start hosting), "handled", or nil (not ours).
function Lobby:on_menu_decide(action)
    local A = Lobby.ACTION
    if action == A.MULTIPLAYER then
        self:set_menu_mode("mp")
        return "handled"
    elseif action == A.HOST then
        self:open(Lobby.SCREEN.LOBBY)
        return "host"
    elseif action == A.JOIN then
        -- Already connected to a host (back on the menu after playing): straight to its lobby.
        self:open((self.role() == "client" and self.active()) and Lobby.SCREEN.LOBBY or Lobby.SCREEN.JOIN)
        return "handled"
    elseif action == A.OPTIONS then
        self:open(Lobby.SCREEN.OPTIONS, "menu")
        return "handled"
    elseif action == A.BACK then
        self:set_menu_mode("main")
        return "handled"
    end
    return nil
end

-- Menu commands of this frame (game thread) for the UI (render thread).
function Lobby:push_nav(cmds)
    for _, c in ipairs(cmds or {}) do
        if #self.nav < 16 then self.nav[#self.nav + 1] = c end
    end
end

function Lobby:take_nav()
    local n = self.nav
    if #n == 0 then return n end
    self.nav = {}
    return n
end

function Lobby:push_action(a)
    if #self.actions < 8 then self.actions[#self.actions + 1] = a end
end

function Lobby:take_action()
    if #self.actions == 0 then return nil end
    return table.remove(self.actions, 1)
end

-------------------------------------------------------------------------------
-- The host's choices
-------------------------------------------------------------------------------

function Lobby:option_bits()
    local bits = 0
    for i, o in ipairs(Lobby.OPTIONS) do
        if self.settings[o.key] == true then bits = bits | (1 << (i - 1)) end
    end
    return bits
end

-- Host: what the game says its co-op files hold. infos[file] = { empty, chapter_id, difficulty, count }.
function Lobby:set_saves(infos)
    local changed = false
    infos = infos or {}
    for file = 1, Lobby.FILES do
        -- A slot the game could not read this time keeps what it said before (no flicker).
        if infos[file] == nil then infos[file] = self.saves[file] end
        local a, b = self.saves[file], infos[file]
        if (a == nil) ~= (b == nil) or (a and b and (a.empty ~= b.empty or a.chapter_id ~= b.chapter_id
            or a.difficulty ~= b.difficulty or a.count ~= b.count)) then
            changed = true
        end
    end
    self.saves = infos
    if changed and self.role() == "host" then self:bump() end
end

-- The mode the host's choice amounts to: an empty file can only start a new game.
function Lobby:mode()
    local P = self.P
    local info = self.saves[self.cfg.file]
    if self.cfg.mode == P.LOBBY_MODE.CONTINUE and info ~= nil and not info.empty then return P.LOBBY_MODE.CONTINUE end
    return P.LOBBY_MODE.NEW
end

-- What the lobby screen shows as the game's settings: the host's own (host) or the host's last
-- LOBBY_SETTINGS (client; nil until it arrives).
function Lobby:view()
    if self.role() == "client" then
        local r = self.remote
        if r == nil then return nil end
        return { file = r.file, mode = r.mode, chapter = r.chapter, difficulty = r.difficulty, options = r.options,
            save = { empty = r.save_empty, chapter_id = r.save_chapter, difficulty = r.save_difficulty, count = r.save_count },
            host = false }
    end
    local mode = self:mode()
    return { file = self.cfg.file, mode = mode,
        chapter = mode == self.P.LOBBY_MODE.NEW and self.cfg.chapter or self.cfg.jump,
        difficulty = self.cfg.difficulty, options = self:option_bits(), save = self.saves[self.cfg.file], host = true }
end

function Lobby:bump()
    self.cfg.rev = (self.cfg.rev + 1) & 0xFFFF
    self.me.ready = false -- the game changed: everyone confirms again
    if self.partner then self.partner.ready = false end
    self:send_settings()
    self:send_player()
end

local function editable(self)
    return self.role() ~= "client" and (self.start == nil or self.start.released)
end

function Lobby:cycle_file(d)
    if not editable(self) then return end
    self.cfg.file = wrap(self.cfg.file + d, Lobby.FILES)
    self.settings.lobby_file = self.cfg.file
    self.cfg.jump = 0
    self:bump()
end

function Lobby:cycle_mode()
    if not editable(self) then return end
    local P = self.P
    local info = self.saves[self.cfg.file]
    if info == nil or info.empty then
        self.cfg.mode = P.LOBBY_MODE.NEW
        return
    end
    self.cfg.mode = self:mode() == P.LOBBY_MODE.NEW and P.LOBBY_MODE.CONTINUE or P.LOBBY_MODE.NEW
    self:bump()
end

-- New game: the chapter it starts in (1-16). Continuing: 0 (where the save is) or a chapter.
function Lobby:cycle_chapter(d)
    if not editable(self) then return end
    if self:mode() == self.P.LOBBY_MODE.NEW then
        self.cfg.chapter = wrap(self.cfg.chapter + d, #Lobby.CHAPTERS)
        self.settings.lobby_chapter = self.cfg.chapter
    else
        self.cfg.jump = (self.cfg.jump + d) % (#Lobby.CHAPTERS + 1)
    end
    self:bump()
end

function Lobby:cycle_difficulty(d)
    if not editable(self) then return end
    local i = index_of(Lobby.DIFFICULTIES, function(x) return x.id == self.cfg.difficulty end) or 2
    self.cfg.difficulty = Lobby.DIFFICULTIES[wrap(i + d, #Lobby.DIFFICULTIES)].id
    self.settings.lobby_difficulty = self.cfg.difficulty
    self:bump()
end

function Lobby:toggle_option(key)
    if not editable(self) then return end
    self.settings[key] = not (self.settings[key] == true)
    self:bump()
end

-------------------------------------------------------------------------------
-- The players
-------------------------------------------------------------------------------

function Lobby:cycle_loadout(d)
    if self.start ~= nil and not self.start.released then return end
    local i = index_of(Lobby.LOADOUTS, function(l) return l.id == self.me.loadout end) or 1
    self.me.loadout = Lobby.LOADOUTS[wrap(i + d, #Lobby.LOADOUTS)].id
    self.settings.lobby_loadout = self.me.loadout
    self:send_player()
end

function Lobby:set_ready(ready)
    if self.start ~= nil and not self.start.released then return end
    self.me.ready = ready and true or false
    self:send_player()
end

function Lobby:toggle_ready()
    self:set_ready(not self.me.ready)
end

function Lobby:send_player()
    if not self.active() then return false end
    return self.send(self.P.encode_lobby_player({ in_lobby = self:in_lobby(), ready = self.me.ready,
        loadout = self.me.loadout, name = self.my_name() }), true)
end

function Lobby:send_settings()
    if self.role() ~= "host" or not self.active() or not self:in_lobby() then return false end
    local v = self:view()
    local save = v.save or {}
    return self.send(self.P.encode_lobby_settings({ rev = self.cfg.rev, file = v.file, mode = v.mode,
        chapter = v.chapter, difficulty = v.difficulty, options = v.options, save_chapter = save.chapter_id or 0,
        save_difficulty = save.difficulty or 0, save_count = save.count or 0,
        save_empty = save.empty ~= false }), true)
end

-- Can the host start now? true, or false and why (shown on the start button).
function Lobby:can_start()
    if self.role() ~= "host" then return false, "Solo el anfitrión puede comenzar" end
    if self.start ~= nil and not self.start.released then return false, "La partida ya está empezando" end
    if not self.active() then return false, "Esperando a que se una otro jugador" end
    local p = self.partner
    if p == nil or not p.in_lobby then return false, "El otro jugador aún no está en la sala" end
    if not self.me.ready then return false, "Marca que estás listo" end
    if not p.ready then return false, ("Esperando a que %s esté listo"):format(p.name or "tu compañero") end
    return true
end

-------------------------------------------------------------------------------
-- Network
-------------------------------------------------------------------------------

function Lobby:on_connected()
    self.partner = nil
    self.remote, self.remote_rev = nil, nil
    self.join_running = false
    if self.screen == Lobby.SCREEN.JOIN then self:open(Lobby.SCREEN.LOBBY) end
    if self:in_lobby() then
        self.me.ready = false
        self:send_player()
        self:send_settings()
    end
end

function Lobby:on_disconnected(now)
    local name = self.partner and self.partner.name
    self.partner = nil
    self.remote, self.remote_rev = nil, nil
    self.me.ready = false
    local s = self.start
    if s ~= nil and not s.released then
        self:release(now or 0, "partner_left")
        self.notify(("%s se ha desconectado: tu partida sigue sin esperar"):format(name or "Tu compañero"), "warn")
    end
end

-- menu_open: the game shows its main menu (a client can be brought into the host's lobby).
function Lobby:on_message(m, now, menu_open)
    local T, P = self.P.T, self.P
    if m.type == T.LOBBY_SETTINGS then
        if self.role() ~= "client" then return true end
        local first = self.remote == nil
        local changed = self.remote_rev ~= nil and m.rev ~= self.remote_rev
        self.remote, self.remote_rev = m, m.rev
        if changed and self.me.ready then
            -- The host changed the game: confirm again.
            self.me.ready = false
            self:send_player()
        end
        if first and self.screen == nil and menu_open and self.start == nil then
            self:open(Lobby.SCREEN.LOBBY)
        end
        return true
    elseif m.type == T.LOBBY_PLAYER then
        local before = self.partner
        self.partner = { name = m.name ~= "" and m.name or self.partner_name(), in_lobby = m.in_lobby,
            ready = m.ready, loadout = m.loadout }
        if before == nil and m.in_lobby then
            self.notify(("%s ha entrado en la sala"):format(self.partner.name), "good")
        elseif before ~= nil and before.in_lobby and not m.in_lobby then
            self.notify(("%s ha salido de la sala"):format(self.partner.name), "warn")
        elseif before ~= nil and m.ready ~= before.ready and m.in_lobby then
            self.notify(("%s %s"):format(self.partner.name, m.ready and "está listo" or "ya no está listo"),
                m.ready and "good" or "info")
        end
        return true
    elseif m.type == T.LOBBY_START then
        if self.role() ~= "client" then return true end
        self:begin_start(m, now)
        return true
    elseif m.type == T.LOAD_STATE then
        local s = self.start
        if s ~= nil and m.start_id == s.id then
            s.partner_phase = m.phase
            s.partner_progress = m.progress
        end
        return true
    elseif m.type == T.LOAD_GO then
        local s = self.start
        if s ~= nil and m.start_id == s.id and not s.released then self:release(now, "go") end
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- The synchronized start
-------------------------------------------------------------------------------

-- Host: start now (both ready). Returns true, or false and why.
function Lobby:request_start(now)
    local ok, why = self:can_start()
    if not ok then return false, why end
    local P = self.P
    local cfg = self.cfg
    local mode = self:mode()
    local params = { start_id = self.next_start_id & 0xFFFF, mode = mode, file = cfg.file, difficulty = cfg.difficulty }
    self.next_start_id = self.next_start_id + 1
    if mode == P.LOBBY_MODE.NEW then
        local c = Lobby.CHAPTERS[cfg.chapter] or Lobby.CHAPTERS[1]
        params.chapter, params.key, params.chapter_id = c.n, c.key, c.id
    else
        local info = self.saves[cfg.file] or {}
        local c = cfg.jump > 0 and Lobby.CHAPTERS[cfg.jump] or nil
        params.chapter = cfg.jump
        params.chapter_id = c and c.id or info.chapter_id or 0
        params.key = Lobby.key_of_id(params.chapter_id) or 1
    end
    self.send(P.encode_lobby_start(params), true)
    self:begin_start(params, now)
    return true
end

-- Both: the game was agreed; ask session.lua to start it and follow the loading.
function Lobby:begin_start(params, now)
    local P = self.P
    self.start = { id = params.start_id, params = params, since = now, phase = P.LOAD_PHASE.STARTING,
        phase_since = now, partner_phase = P.LOAD_PHASE.STARTING, partner_progress = 0, last_sent = -math.huge,
        released = false, left_menu = false, loadout = self.me.loadout, loadout_pending = true }
    self.counters.starts = self.counters.starts + 1
    self.screen, self.screen_from = nil, nil
    self.menu_mode = "main" -- back on the menu after playing: the game's own entries
    self.me.ready = false
    if self.partner then self.partner.ready = false end
    self.join_running = false
    self:push_action({ kind = "start", role = self.role(), params = params, slot = self:file_slot(params.file) })
    self:send_load_state(now)
    local c = params.chapter_id ~= 0 and Lobby.chapter_of_id(params.chapter_id) or nil
    self.notify(("La partida empieza: %s%s"):format(params.mode == P.LOBBY_MODE.NEW and "nueva partida" or "continuar",
        c and (", capítulo " .. c) or ""), "good")
end

-- session.lua could not start the game here (why: text).
function Lobby:start_failed(why, now)
    local s = self.start
    if s == nil or s.released then return end
    s.phase = self.P.LOAD_PHASE.FAILED
    s.phase_since = now
    s.why = why
    s.loadout_pending = false
    self.counters.failed = self.counters.failed + 1
    self:send_load_state(now)
    self.notify("No se pudo empezar la partida: " .. tostring(why), "error")
end

function Lobby:send_load_state(now)
    local s = self.start
    if s == nil then return end
    s.last_sent = now
    self.send(self.P.encode_load_state({ start_id = s.id, phase = s.phase, progress = s.progress or 0 }), true)
end

function Lobby:release(now, why)
    local s = self.start
    if s == nil or s.released then return end
    s.released = true
    s.released_at = now
    s.why = why
    if s.phase ~= self.P.LOAD_PHASE.FAILED then s.phase = self.P.LOAD_PHASE.PLAYING end
    self.counters.released = self.counters.released + 1
    if why == "skipped" then self.counters.skipped = self.counters.skipped + 1 end
    if self.active() then self:send_load_state(now) end
    if why == "go" then self.notify("¡Los dos habéis cargado: comienza la partida!", "good") end
end

-- Every game frame. env = { connected, in_menu, in_game, loading_screen, synced, continue_pressed }
-- Returns true while our game must be held (its map has loaded; the partner's has not).
function Lobby:tick(now, env)
    local s = self.start
    if s == nil then return false end
    local P = self.P
    local L = P.LOAD_PHASE
    if s.released or s.phase == L.FAILED then
        local since = s.released_at or s.phase_since or now
        if now - since > FINISH_AFTER then self.start = nil end
        if s.phase == L.FAILED and not s.released then s.released, s.released_at = true, now end
        return false
    end
    if not env.connected then
        self:on_disconnected(now)
        return false
    end
    if not env.in_menu then s.left_menu = true end

    local phase
    if env.in_game and not env.loading_screen then
        s.in_game_since = s.in_game_since or now
        if now - s.in_game_since < SETTLE then
            phase = L.LOADING
        elseif env.synced == false then
            phase = L.SYNCING
        else
            phase = L.READY
        end
    else
        s.in_game_since = nil
        phase = s.left_menu and L.LOADING or L.STARTING
    end
    if phase == L.STARTING and now - s.since > START_TIMEOUT then
        self:start_failed("el juego no salió del menú", now)
        return false
    end
    if phase ~= s.phase then
        s.phase, s.phase_since = phase, now
        self:send_load_state(now)
    elseif now - s.last_sent >= SEND_EVERY then
        self:send_load_state(now)
    end

    if phase ~= L.READY then
        s.ready_since = nil
        return false
    end
    s.ready_since = s.ready_since or now
    if self.settings.start_sync == false then
        self:release(now, "no_wait") -- this player chose not to wait (Multiplayer Options)
        return false
    end
    local pp = s.partner_phase or L.NONE
    if pp == L.FAILED then
        self:release(now, "partner_failed")
        self.notify("La partida de tu compañero no pudo empezar: continúas sin esperar", "warn")
        return false
    end
    if pp == L.PLAYING then
        self:release(now, "partner_playing")
        return false
    end
    if self.role() == "host" and pp >= L.READY then
        self.send(P.encode_load_go({ start_id = s.id }), true)
        self:release(now, "go")
        return false
    end
    local wait = tonumber(self.settings.start_timeout) or 120
    s.can_skip = now - s.ready_since >= math.min(wait, 15)
    if s.can_skip and env.continue_pressed then
        self:release(now, "skipped")
        self.notify("Continúas sin esperar a tu compañero", "warn")
        return false
    end
    if now - s.ready_since >= wait then
        self:release(now, "timeout")
        self.notify("Tu compañero tarda demasiado: la partida empieza sin esperar", "warn")
        return false
    end
    return true
end

-- The loadout to give now (once, after the start, while the player is in control), or nil.
function Lobby:take_loadout(now, playable)
    local s = self.start
    if s == nil or not s.released or not s.loadout_pending or not playable then return nil end
    if now - (s.released_at or now) < LOADOUT_DELAY then return nil end
    s.loadout_pending = false
    local l = Lobby.loadout(s.loadout)
    if l == nil or #l.weapons == 0 then return nil end
    self.counters.loadouts = self.counters.loadouts + 1
    return l
end

-------------------------------------------------------------------------------
-- What the screens show
-------------------------------------------------------------------------------

-- The two loaders (bottom left while the game starts): host first.
function Lobby:loaders(now)
    local s = self.start
    if s == nil then return nil end
    if s.released and now - (s.released_at or now) > RELEASED_SHOWN then return nil end
    local host = self.role() == "host"
    local mine = { name = self.my_name(), host = host, phase = s.phase, me = true }
    local theirs = { name = self.partner and self.partner.name or self.partner_name(), host = not host,
        phase = s.partner_phase or 0, me = false }
    if s.released and s.why == "go" then theirs.phase = self.P.LOAD_PHASE.PLAYING end
    local list = host and { mine, theirs } or { theirs, mine }
    for _, l in ipairs(list) do
        l.label = Lobby.phase_label(l.phase)
        l.done = l.phase >= self.P.LOAD_PHASE.READY and l.phase ~= self.P.LOAD_PHASE.FAILED
    end
    return list
end

-- { waiting (our map is loaded and held), can_skip, waited } while the start runs, else nil.
function Lobby:start_view(now)
    local s = self.start
    if s == nil then return nil end
    return { waiting = not s.released and s.phase == self.P.LOAD_PHASE.READY, can_skip = s.can_skip == true,
        waited = s.ready_since and (now - s.ready_since) or 0, released = s.released, phase = s.phase,
        partner_phase = s.partner_phase, why = s.why }
end

function Lobby:summary()
    local s = self.start
    return { screen = self.screen, menu_mode = self.menu_mode, partner = self.partner, me = self.me,
        start = s and { id = s.id, phase = s.phase, partner_phase = s.partner_phase, released = s.released, why = s.why } or nil,
        counters = self.counters }
end

return Lobby
