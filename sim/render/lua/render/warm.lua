-- render/warm.lua : the windows' definitions read with the load, not by their first opening
-- (docs/profiling.md section 8). Each window module keeps what it reads of the game's files in
-- a cache of its own the first time it needs it (100 to 150 ms each on 10.5.0.24: the fleet
-- windows' leader traits, the species view's rules, the leaders' portraits, the technologies);
-- warm.run fills those caches in the UI thread's runtime, each step guarded: one that fails is
-- named in the result and left to its window, as before.
--
--   local failed = require("render.warm").run(game_dir)   -- "" or "step: error; ..."

local warm = {}

-- the directories of common/ the windows read through render.windows.empire_common.defs
local DEFS = {
    "common/traits", "common/leader_classes", "common/edicts", "common/governments/councilors",
    "common/council_agendas", "common/policies", "common/planet_classes", "common/static_modifiers",
    "common/species_classes", "common/species_archetypes", "common/policy_categories",
    "common/named_colors", "common/graphical_culture", "common/governments/authorities",
    "common/governments", "common/ethics", "common/districts", "common/defines",
}

local function steps(game_dir)
    return {
        { "empire_common.defs", function()
            local C = require("render.windows.empire_common")
            for _, dir in ipairs(DEFS) do
                C.defs({ game_dir = game_dir }, dir)
            end
        end },
        { "creator_rules.load", function() require("render.creator_rules").load(game_dir) end },
        { "portraits.db", function() require("render.portraits").db(game_dir) end },
        { "scripted_loc.defaults", function() require("render.scripted_loc").defaults(game_dir) end },
        { "technology.definitions", function() require("render.windows.technology").definitions(game_dir) end },
        { "fleet.traits", function() require("render.windows.fleet").traits(game_dir) end },
    }
end

function warm.run(game_dir)
    local failed = {}
    for _, s in ipairs(steps(game_dir)) do
        local ok, err = pcall(s[2])
        if not ok then
            failed[#failed + 1] = s[1] .. ": " .. tostring(err)
        end
    end
    return table.concat(failed, "; ")
end

return warm
