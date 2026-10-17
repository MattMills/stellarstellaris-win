-- render/windows/contacts.lua : the diplomacy windows' commands in the simulation (render-buttons-1's
-- views.rs runs `command(...)` of the view `contacts` between days; the windows themselves are
-- render.windows.diplomacy's, laid out by src/diplomacy.rs). docs/windows/diplomacy.md.
--
--   list GAME_DIR ACTOR RECIPIENT          the actions of the recipient's diplomacy window
--   propose GAME_DIR ACTION ACTOR RECIPIENT  an action proposed (render.windows.diplomacy_actions)
--   peace GAME_DIR WAR OPTION PLAYER       a peace offered (render.windows.diplomacy_peace)
--   leave_federation GAME_DIR PLAYER       the player's federation left
--   join_community GAME_DIR PLAYER        the galactic community joined
--   leave_community GAME_DIR PLAYER       the galactic community left
--     (render.windows.diplomacy_membership)
--
-- Each returns a Lua chunk (render.windows.diplomacy_data.serialize).

local M = {}

function M.command(verb, game_dir, a, b, c)
    local A = require("render.windows.diplomacy_actions")
    if verb == "list" then
        return A.list(game_dir, tonumber(a), tonumber(b))
    elseif verb == "propose" then
        return A.apply(game_dir, a, tonumber(b), tonumber(c))
    elseif verb == "peace" then
        return require("render.windows.diplomacy_peace").apply(game_dir, tonumber(a), tonumber(c), b)
    elseif verb == "leave_federation" then
        return require("render.windows.diplomacy_membership").leave_federation(game_dir, tonumber(a))
    elseif verb == "join_community" then
        return require("render.windows.diplomacy_membership").join_community(game_dir, tonumber(a))
    elseif verb == "leave_community" then
        return require("render.windows.diplomacy_membership").leave_community(game_dir, tonumber(a))
    end
    return "return { note = 'no command " .. tostring(verb) .. "' }"
end

return M
