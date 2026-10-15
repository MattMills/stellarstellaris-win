-- engine/ai/economy/slots.lua : what can be built on a colony (game rules the AI asks through
-- CBuildable*::CanBuild), docs/ai_economy.md section 4:
--
--   CColony::CanAddDistrict (0xdc8430): not under colonization; the districts (levels, with the
--       queued ones) under CColonyCarrier::CalcMaxDistricts (0xccc980: planet size *
--       NUM_DISTRICTS_FROM_PLANET_SIZE + NUM_DISTRICTS_BASE + the country's pc_<class>_max_districts_add
--       + planet_max_districts_add + planet_(non_)artificial_max_districts_add); a capped type
--       (CDistrictType::IsUncapped 0x48ed50: an `is_uncapped` trigger that fails) under its
--       CalcMaxDistrictsOfType (district_<type>_max_add)
--   CDistrictType::CanBuild: potential, allow (planet scope), prerequisites
--
--   local slots = require("engine.ai.economy.slots")
--   slots.colony(colony) -> { colony, planet, owner, districts = { [type] = { id, level } }, ... }

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local defs = require("engine.defs")
local eval = require("simscript.eval")

local slots = {}

-- a definition's block with its inline scripts expanded (engine.economy.units, cached)
local function expanded(d)
    return require("engine.economy.units").expanded(d)
end
slots.expanded = expanded

local function economy()
    return require("engine.economy")
end

local function holds(block, ctx)
    if type(block) ~= "table" or #block == 0 then
        return true
    end
    local ok, v = pcall(eval.trigger, block, ctx)
    return ok and v and true or false
end
slots.holds = holds

function slots.ctx(c, file)
    return eval.new_ctx(eval.S("planet", c.planet), c.owner and eval.S("country", c.owner) or nil, nil, file or "?")
end

-- the technologies a definition needs (prerequisites = { tech ... })
function slots.has_prerequisites(country, block)
    local pre = defs.field(block, "prerequisites")
    if type(pre) ~= "table" then
        return true
    end
    local research = require("engine.research")
    for _, e in ipairs(pre) do
        slice.tick("ai/economy/slots.lua:51")
        if e.text and not research.level(country, e.text) then
            return false
        end
    end
    return true
end

-- the colony's districts, zones and queue
function slots.colony(c)
    local col = world.object("colony", c.colony)
    local info = { colony = c.colony, planet = c.planet, owner = c.owner, districts = {}, list = {}, levels = 0 }
    for _, did in ipairs(world.list(col and world.field(col, "districts"))) do
        slice.tick("ai/economy/slots.lua:63")
        local d = world.object("districts", tonumber(did))
        if d then
            local t = world.field(d, "type")
            local level = tonumber(world.field(d, "level")) or 0
            local zones = {}
            for _, z in ipairs(world.list(world.field(d, "zones"))) do
                slice.tick("ai/economy/slots.lua:69")
                zones[#zones + 1] = tonumber(z)
            end
            local entry = { id = tonumber(did), type = t, level = level, zones = zones }
            info.districts[t] = entry
            info.list[#info.list + 1] = entry
            info.levels = info.levels + level
        end
    end
    -- the queued districts count (CalcNumDistricts with the queue)
    info.queued = {}
    local p = world.object("planet", c.planet)
    local q = world.object("construction.queue_mgr.queues", tonumber(world.field(p, "build_queue")))
    for _, iid in ipairs(world.list(q and world.field(q, "items"))) do
        slice.tick("ai/economy/slots.lua:82")
        local item = world.object("construction.item_mgr.items", tonumber(iid))
        local B = require("engine.ai.economy.buildables")
        local kind, b = B.item_kind(item or {})
        if kind == "district" then
            local t = world.field(b, "district")
            info.queued[t] = (info.queued[t] or 0) + 1
            info.levels = info.levels + 1
        end
    end
    return info
end

local NUM_BASE, NUM_SIZE
local function defines()
    if NUM_BASE == nil then
        local g = defs.get("common/defines", "NGameplay")
        NUM_BASE = g and tonumber(defs.field(g.block, "NUM_DISTRICTS_BASE")) or 0
        NUM_SIZE = g and tonumber(defs.field(g.block, "NUM_DISTRICTS_FROM_PLANET_SIZE")) or 1
    end
end

function slots.max_districts(info)
    defines()
    local p = world.object("planet", info.planet)
    local size = tonumber(world.field(p, "planet_size")) or 0
    local class = world.field(p, "planet_class")
    local M = economy().modifiers("colony", info.colony) or {}
    local C = economy().modifiers("country", info.owner) or {}
    local artificial = false
    local pc = class and defs.get("common/planet_classes", class)
    if pc and defs.field(pc.block, "is_artificial") == "yes" then
        artificial = true
    end
    local n = math.floor(size * NUM_SIZE) + NUM_BASE + (C[tostring(class) .. "_max_districts_add"] or 0)
        + (M.planet_max_districts_add or 0)
        + (artificial and (M.planet_artificial_max_districts_add or 0) or (M.planet_non_artificial_max_districts_add or 0))
    local mult = M.planet_max_districts_mult or 0
    if mult ~= 0 then
        n = math.floor(n * (1 + mult))
    end
    return n
end

-- a district type's cap on the colony, or nil (uncapped)
function slots.district_cap(info, d, t)
    local unc = defs.field(expanded(d), "is_uncapped")
    if unc == nil then
        return nil
    end
    if type(unc) == "table" and holds(unc, slots.ctx(info, d.file)) then
        return nil
    end
    local M = economy().modifiers("colony", info.colony) or {}
    local n = M[t .. "_max_add"] or 0
    local mult = M[t .. "_max_mult"] or 0
    if mult ~= 0 then
        n = n * (1 + mult)
    end
    return math.floor(n)
end

-- CColony::CanAddDistrict + CDistrictType::CanBuild for the next level of a type
function slots.can_add_district(info, t)
    local d = defs.get("common/districts", t)
    if not d then
        return false
    end
    if info.levels >= slots.max_districts(info) then
        return false
    end
    local cap = slots.district_cap(info, d, t)
    if cap then
        local have = (info.districts[t] and info.districts[t].level or 0) + (info.queued[t] or 0)
        if have >= cap then
            return false
        end
    end
    local ctx = slots.ctx(info, d.file)
    if not holds(defs.field(expanded(d), "potential"), ctx) or not holds(defs.field(expanded(d), "allow"), ctx) then
        return false
    end
    return slots.has_prerequisites(info.owner, expanded(d))
end

return slots
