-- Draws the partner as a "ghost": skeleton lines through their real joint positions, a name
-- tag with distance and an HP bar. Needs nothing from the game but world_to_screen, so it
-- works in every chapter regardless of which character models are loaded.
-- Must run inside re.on_frame (REFramework's draw API is only valid there).

local P = require("re4coop.protocol")

local Ghost = {}

local COLOR_TEXT = 0xFFFFFFFF
local COLOR_HP_BG = 0xC0000000
local COLOR_HP = 0xFF40D040   -- ABGR green
local COLOR_HP_LOW = 0xFF4040E0 -- ABGR red
local COLOR_DOWN = 0xFF2020FF

local function head_position(state)
    if state.joints and #state.joints > 0 then
        local top = state.joints[1]
        for _, j in ipairs(state.joints) do
            if j.y > top.y then top = j end
        end
        return { x = top.x, y = top.y + 0.25, z = top.z }
    end
    return { x = state.pos.x, y = state.pos.y + 1.9, z = state.pos.z }
end

-- game: adapter with world_to_screen/draw_*; state: interpolated PLAYER state;
-- parents: SKELETON parent table (may be nil); opts: { name, color, show_nametag, distance }
function Ghost.draw(game, state, parents, opts)
    local color = opts.color or 0xFFFFC040
    local dead = ((state.flags or 0) & P.PLAYER_FLAGS.DEAD) ~= 0
    if dead then color = COLOR_DOWN end

    -- Skeleton
    local joints = state.joints
    if joints and #joints > 0 then
        local screen = {}
        for i, j in ipairs(joints) do
            local x, y = game:world_to_screen(j)
            if x ~= nil then screen[i] = { x, y } end
        end
        if parents and #parents == #joints then
            for i = 1, #joints do
                local p = parents[i]
                local a, b = screen[i], p and p > 0 and screen[p] or nil
                if a and b then
                    game:draw_line(a[1], a[2], b[1], b[2], color)
                end
            end
        end
        for i = 1, #joints do
            local a = screen[i]
            if a then game:draw_circle(a[1], a[2], 2.5, color) end
        end
    else
        -- No joints yet: a simple marker at the feet.
        local x, y = game:world_to_screen(state.pos)
        if x then game:draw_circle(x, y, 8, color) end
    end

    if not opts.show_nametag then return end

    local hx, hy = game:world_to_screen(head_position(state))
    if hx == nil then return end

    local label = opts.name or "Partner"
    if opts.distance then
        label = ("%s  %.0fm"):format(label, opts.distance)
    end
    if dead then
        label = label .. "  [DOWN]"
    end
    game:draw_text(label, hx - #label * 3.5, hy - 30, COLOR_TEXT)

    local max_hp = state.max_hp or 0
    if max_hp > 0 then
        local frac = math.max(0, math.min(1, (state.hp or 0) / max_hp))
        local w, h = 80, 6
        game:draw_rect(hx - w / 2 - 1, hy - 13, w + 2, h + 2, COLOR_HP_BG)
        game:draw_rect(hx - w / 2, hy - 12, w * frac, h, frac < 0.3 and COLOR_HP_LOW or COLOR_HP)
    end
end

-- Compact status text in the top-left corner, plus the newest chat/notice lines.
function Ghost.draw_hud(game, status, messages, now)
    local x, y = 12, 12
    local line = "RE4 Co-op: "
    if status.state == "connected" then
        line = line .. ("%s  |  %.0f ms"):format(status.partner_name or "partner", status.rtt_ms or 0)
        if status.partner_distance then
            line = line .. ("  |  %.0f m"):format(status.partner_distance)
        end
        if not status.compatible then
            line = line .. "  |  VERSION MISMATCH"
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

return Ghost
