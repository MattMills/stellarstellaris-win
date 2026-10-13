-- engine/economy/world_source.lua : the engine's modifier source from the world alone, the
-- rewrite's own modifier system (engine.modifiers.world: every node of the world, its links and its
-- own parts, `mult = modifier:x` references resolved from a first build), in place of the game's
-- capture (engine/economy/capture.lua). It answers the same question for every system:
--
--   f(kind, id) -> { [modifier name] = value as a float } | nil      (nil: no such node)
--
-- kind is the engine's (colony, planet, pop_group, country, ship, fleet, leader, starbase, army,
-- megastructure, sector, federation, spy_network); a colony's node is keyed by the colony id, a
-- planet's by the planet id, as the game's.
--
-- The graph is built from the world as it is when built; the engine builds it again in the monthly
-- modifier phase (the game updates its nodes daily: between two builds the values are held). The
-- modifier types (names, categories) come from the game's modifier documentation
-- (script_documentation/modifiers.log), STELLAR_MODIFIER_TYPES.
--
--   local ws = require("engine.economy.world_source")
--   local source, why = ws.new(types_log_path)
--   economy.set_modifier_source(source.get)
--   source.rebuild()                   -- the world changed (a month passed)

local M = {}

M.CATEGORY = {
    colony = "Colony", planet = "Planet", pop_group = "PopGroup", country = "Country", ship = "Ship",
    fleet = "Fleet", leader = "Leader", starbase = "Starbase", army = "Army", megastructure = "MegaStructure",
    sector = "Sector", federation = "Federation", spy_network = "SpyNetwork",
}

local function read_file(path)
    local f = path and io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

-- ws.new(types_log) -> source | nil, message: source.get(kind, id), source.rebuild(), source.stats
function M.new(types_log)
    local ok_mw, mw = pcall(require, "engine.modifiers.world")
    if not ok_mw or not mw.world_graph or not mw.values then
        return nil, "engine.modifiers.world has no world_graph/values (the modifiers branch is not merged)"
    end
    local text = read_file(types_log)
    if not text then
        return nil, "no modifier types at " .. tostring(types_log) .. " (STELLAR_MODIFIER_TYPES)"
    end
    local gmod = require("stellar.graph.modifiers")
    local defs = gmod.definitions()
    defs:read_log(text)
    text = nil
    local world = require("engine.world")
    local edefs = require("engine.defs")
    local okdb, db = pcall(require, "simscript.db")
    local fs = okdb and db.fs or nil

    local source = { stats = { builds = 0, seconds = 0, asked = 0, missing = 0 } }
    local wg, cache
    function source.rebuild()
        local t0 = RUST.clock()
        wg = mw.world_graph({ defs = defs, world = world, edefs = edefs, fs = fs })
        wg.defs = wg.defs or defs
        cache = {}
        source.stats.builds = source.stats.builds + 1
        source.stats.seconds = source.stats.seconds + (RUST.clock() - t0)
        local economy = package.loaded["engine.economy"]
        if economy and economy.invalidate then
            economy.invalidate()
        end
    end
    function source.get(kind, id)
        if wg == nil then
            source.rebuild()
        end
        local cat = M.CATEGORY[kind] or kind
        local key = cat .. ":" .. tostring(id)
        local v = cache[key]
        if v == nil then
            v = mw.values(wg, cat, id) or false
            cache[key] = v
            source.stats.asked = source.stats.asked + 1
            if v == false then
                source.stats.missing = source.stats.missing + 1
            end
        end
        return v or nil
    end
    function source.report()
        local s = source.stats
        return string.format("modifiers: from the world (engine.modifiers.world), %d builds in %.1f s, %d nodes asked, %d not in the world",
            s.builds, s.seconds, s.asked, s.missing)
    end
    return source
end

return M
