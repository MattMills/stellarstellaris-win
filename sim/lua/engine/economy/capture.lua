-- engine/economy/capture.lua : a modifier source for the economy from the game's capture of its
-- modifier nodes at one moment (stellar.modifier_capture: `modifier-nodes-<date>.tsv`, read with
-- stellar.graph.nodes.read_capture). Until the engine's own modifier nodes are built
-- (engine.modifiers), this answers "the modifier values of the node an economic unit reads" with
-- the game's final values of that node.
--
--   local capture = require("engine.economy.capture")
--   local source = capture.load("/opt/stellaris-captures/modifier-nodes-2210.tsv")
--   source("colony", 0)      -- { planet_jobs_produces_mult = 0.07947, ... } or nil
--
-- A node kind of the economy is one of the game's EModifierNodeCategory: colony (Colony, owned
-- by the colony id), planet, pop_group, country, ship, fleet, leader, starbase, army,
-- megastructure, sector, federation.

local nodes = require("stellar.graph.nodes")

local M = {}

-- the economy's node kinds -> the capture's categories
M.CATEGORY = {
    colony = "Colony", planet = "Planet", pop_group = "PopGroup", country = "Country", ship = "Ship",
    fleet = "Fleet", leader = "Leader", starbase = "Starbase", army = "Army", megastructure = "MegaStructure",
    sector = "Sector", federation = "Federation", spy_network = "SpyNetwork",
}

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

-- capture.load(path) -> source(kind, id) -> { [modifier name] = value } | nil; nil, message when
-- the file is not there. Values are the game's fixed point read as numbers (1.0 = 100000 -> 1.0).
function M.load(path)
    local text = read_file(path)
    if text == nil then
        return nil, "no capture at " .. tostring(path)
    end
    local snap = nodes.read_capture(text)
    text = nil
    local by = {}   -- category -> { [owner] = values }
    for _, n in ipairs(snap.nodes) do
        if not n.invalid or next(n.values) ~= nil then
            local t = by[n.category]
            if t == nil then
                t = {}
                by[n.category] = t
            end
            local values = {}
            for k, v in pairs(n.values) do
                values[k] = v / 100000
            end
            -- an owner with several nodes of a category (rare): the first one
            if t[n.owner] == nil then
                t[n.owner] = values
            end
        end
    end
    snap = nil
    local function source(kind, id)
        local cat = M.CATEGORY[kind] or kind
        local t = by[cat]
        return t and t[id]
    end
    return source, by
end

return M
