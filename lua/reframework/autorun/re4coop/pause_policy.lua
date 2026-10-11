-- Which of the game's pauses keep freezing the world during a co-op session.
--
-- RE4 pauses through share.PauseManager: each pause type (inventory, map, files, pause
-- menu, item pickup, typewriter, tutorials, ...) has a parameter saying which parts of the
-- world it freezes. In co-op the partner keeps playing, so a menu must not freeze your
-- world: those pauses are neutralised (they still "happen" for the menus, but freeze
-- nothing). Only pauses that belong to shared or system moments are kept: cutscenes /
-- events and loading, which both players go through together anyway.
-- Pure Lua, tested offline.

local PausePolicy = {}

-- Name fragments (lower case) of pauses that keep their normal effect.
PausePolicy.KEEP = { "event", "movie", "demo", "timeline", "cutscene", "load", "fade", "title",
    "ending", "warp", "boot", "system_reset" }

-- Returns true if a pause with this enum name should freeze nothing while in co-op.
-- mode: "all" (also events), "menus" (default), "off".
function PausePolicy.neutralize(name, mode)
    mode = mode or "menus"
    if mode == "off" then return false end
    if mode == "all" then return true end
    local n = tostring(name or ""):lower()
    if n == "" or n == "none" or n == "invalid" then return false end
    for _, k in ipairs(PausePolicy.KEEP) do
        if n:find(k, 1, true) then return false end
    end
    return true
end

return PausePolicy
