-- simscript/handlers/init.lua : trigger, effect, scope link and list handlers kept in modules by
-- area, so that several can be worked on at once without sharing eval.lua. Each module is
-- `return function(eval) ... end` and adds to eval.TRIG, eval.EFF, eval.LINKS and eval.LISTS
-- (eval._internal has the walker's helpers: push, compare, list_of, flag_name, ...). A module that
-- does not exist yet is skipped.
--
--   runtime    keywords the simulation hits but did not evaluate (cosmic storms, megastructures,
--              starbases, councilors, ...)
--   diplomacy  war, peace, relations, attitudes between countries, access and borders
--   creation   effects that create or change things (ships, fleets, deposits, modifiers, traits,
--              opinion modifiers, special projects, event chains, ...)
--   objects    effects that make the game's objects (districts, buildings, pops, fleets, ships,
--              leaders, countries, species, galaxy objects): a new game's start script
--   fleet_actions  queue_actions, clear_fleet_actions, auto_move_to_planet, remove_auto_move_target

local AREAS = { "runtime", "diplomacy", "creation", "objects", "fleet_actions" }

return function(eval)
    for _, area in ipairs(AREAS) do
        local name = "simscript.handlers." .. area
        local ok, mod = pcall(require, name)
        if ok then
            mod(eval)
        elseif not tostring(mod):find("module '" .. name .. "' not found", 1, true) then
            error(mod, 0)
        end
    end
end
