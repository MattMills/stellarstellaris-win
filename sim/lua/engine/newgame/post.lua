-- engine/newgame/post.lua : what CGameState::InitPostGalaxyCreation (GOG 0x264340) makes of the
-- generated world that the engine's own passes then keep (docs/newgame.md 6.5,
-- docs/windows/newgame_start.md): each country's terra incognita, all of it unknown, then cleared
-- in the country's sensor range. The clearing is the engine's (engine.exploration: the load's
-- pass, CCountry::ClearTerraIncognitaInSensorRange); here only the empty maps it clears.
--
--   require("engine.newgame.post").run()   -- on the loaded, started world

local world = require("engine.world")

local post = {}

-- CTerraIncognitaMap: size x size, runs of unknown (0) and known (255) from unknown; the game's
-- day 0 has one per country, `systems` the systems cleared (docs/exploration.md)
local function empty_map(size)
    local ti = {}
    local function set(key, value)
        ti[#ti + 1] = { key = { text = key }, op = "=", value = value }
    end
    set("size", { text = tostring(size) })
    set("data", { { text = tostring(size * size) } })
    set("systems", {})
    return ti
end

-- post.run() -> report: the maps given to the countries without one, then the exploration's load
-- pass (sensor range, intel, the known hyperlanes, the maps cleared)
function post.run()
    local defines = require("engine.defs").defines and require("engine.defs").defines() or nil
    local size = defines and defines.NGraphics and tonumber(defines.NGraphics.TI_TEXTURE_SIZE) or 256
    local added = 0
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        if c and world.field(c, "terra_incognita") == nil then
            world.append(c, "terra_incognita", empty_map(size))
            added = added + 1
        end
    end
    local ok, exploration = pcall(require, "engine.exploration")
    if not ok then
        return "post: " .. added .. " terra incognita maps; no exploration module: " .. tostring(exploration)
    end
    -- the owners and colonies the world indexes, made again after the start script's objects
    if world.index then world.index() end
    exploration.load_pass()
    local cleared = exploration.stats and exploration.stats.ti_cleared or 0
    -- the player's (country 0) systems known, for the comparison with the game's day 0
    local known = {}
    local c0 = world.object("country", 0)
    local ti = c0 and world.field(c0, "terra_incognita")
    local systems = type(ti) == "table" and world.field(ti, "systems")
    for _, e in ipairs(type(systems) == "table" and systems or {}) do
        known[#known + 1] = e.text
    end
    return string.format("post: terra incognita for %d countries, %d systems cleared in sensor range; country 0 knows { %s }",
        added, cleared, table.concat(known, " "))
end

return post
