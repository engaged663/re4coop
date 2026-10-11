-- 2D overlay: the partner's name tag with distance and HP bar above their character, and
-- the status HUD. The partner themselves is the 3D model (puppet.lua); while that model is
-- not visible (still loading, or unavailable) a small marker at their feet shows where they
-- are. Must run inside re.on_frame (REFramework's draw API is only valid there).

local P = require("re4coop.protocol")

local Overlay = {}

local COLOR_TEXT = 0xFFFFFFFF
local COLOR_HP_BG = 0xC0000000
local COLOR_HP = 0xFF40D040   -- ABGR green
local COLOR_HP_LOW = 0xFF4040E0 -- ABGR red
local COLOR_DOWN = 0xFF2020FF
local COLOR_MARKER = 0xFFFFC040

local TAG_HEIGHT = 2.05 -- metres above the partner's feet

-- game: adapter with world_to_screen/draw_*; state: interpolated PLAYER state;
-- opts: { name, distance, show_nametag, marker = bool }
function Overlay.draw_partner(game, state, opts)
    local dead = ((state.flags or 0) & P.PLAYER_FLAGS.DEAD) ~= 0

    if opts.marker then
        local x, y = game:world_to_screen(state.pos)
        if x then game:draw_circle(x, y, 8, dead and COLOR_DOWN or COLOR_MARKER) end
    end

    if not opts.show_nametag then return end

    local hx, hy = game:world_to_screen({ x = state.pos.x, y = state.pos.y + TAG_HEIGHT, z = state.pos.z })
    if hx == nil then return end

    local label = opts.name or "Partner"
    if opts.distance then
        label = ("%s  %.0fm"):format(label, opts.distance)
    end
    if dead then
        label = label .. "  [DOWN]"
    end
    game:draw_text(label, hx - #label * 3.5, hy - 30, dead and COLOR_DOWN or COLOR_TEXT)

    local max_hp = state.max_hp or 0
    if max_hp > 0 then
        local frac = math.max(0, math.min(1, (state.hp or 0) / max_hp))
        local w, h = 80, 6
        game:draw_rect(hx - w / 2 - 1, hy - 13, w + 2, h + 2, COLOR_HP_BG)
        game:draw_rect(hx - w / 2, hy - 12, w * frac, h, frac < 0.3 and COLOR_HP_LOW or COLOR_HP)
    end
end

-- Compact status text in the top-left corner, plus the newest chat/notice lines.
-- model: puppet status (puppet.lua) or nil.
function Overlay.draw_hud(game, status, messages, now, model)
    local x, y = 12, 12
    local line = "RE4 Co-op: "
    if status.state == "connected" then
        line = line .. ("%s  |  %.0f ms"):format(status.partner_name or "partner", status.rtt_ms or 0)
        if status.partner_distance then
            line = line .. ("  |  %.0f m"):format(status.partner_distance)
        end
        if not status.compatible then
            line = line .. "  |  VERSION MISMATCH"
        elseif model ~= nil and model.state == "loading" then
            line = line .. "  |  loading partner model..."
        elseif model ~= nil and model.state == "failed" then
            line = line .. "  |  partner model unavailable (see Diagnostics)"
        end
    elseif status.state == "listening" then
        line = line .. ("hosting on port %d, waiting for partner"):format(status.stats.local_port or 0)
    elseif status.state == "connecting" then
        line = line .. "connecting..."
    else
        return
    end
    game:draw_text(line, x, y, COLOR_TEXT)
    y = y + 18

    if status.left_behind ~= nil then
        local where = status.left_behind.other_stage and "in another area (%.0f m)" or "%.0f m away"
        local prompt = ("Partner is " .. where .. " - press %s to teleport to them, %s to hide"):format(
            status.left_behind.distance, status.teleport_key_name or "F6", status.snooze_key_name or "F7")
        game:draw_rect(x - 4, y - 2, #prompt * 7 + 8, 18, 0xC0000000)
        game:draw_text(prompt, x, y, 0xFF40E0FF)
        y = y + 22
    end

    local shown = 0
    for i = #messages, 1, -1 do
        local m = messages[i]
        local age = now - m.time
        if age > 8 or shown >= 4 then break end
        local color = COLOR_TEXT
        if m.kind == "error" then color = 0xFF6060FF
        elseif m.kind == "warn" then color = 0xFF40C0FF
        elseif m.kind == "good" then color = 0xFF60FF60
        elseif m.kind == "chat" then color = 0xFFFFE0A0 end
        game:draw_text(m.text, x, y + shown * 16, color)
        shown = shown + 1
    end
end

return Overlay
