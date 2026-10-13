-- engine/ai/economy/buildables.lua : the planet buildables the AI plans and queues (a district's
-- next level, a zone in a district's slot, a building in a zone, a building's upgrade), what they
-- cost, use and make, and their construction item in the save's form (docs/ai_economy.md
-- section 5). A buildable:
--
--   { kind = "district" | "zone" | "planet_building" | "planet_upgrade_building",
--     type = <district / zone / building key>, colony, planet, owner,
--     district = <district id> (zone), zone_slot = <0-based slot> (zone),
--     zone = <zone id> (building), upgrade_building = <building id> (upgrade) }
--
-- Costs and upkeep: the definition's `resources` tables (their triggers in the planet's scope),
-- with the colony's modifiers for the category chain (engine.economy.apply: cost, upkeep and
-- produces mults), as CBuildable*::CalcCost / CalcUpkeep give them.

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local B = {}

local FOLDER = { district = "common/districts", zone = "common/zones", planet_building = "common/buildings",
    planet_upgrade_building = "common/buildings" }
B.FOLDER = FOLDER

function B.def(b)
    return defs.get(FOLDER[b.kind], b.type)
end

local function economy()
    local e = require("engine.economy")
    e.init()
    return e
end

local function template(b)
    local d = B.def(b)
    if not d then
        return nil
    end
    local block = defs.field(require("engine.economy.units").expanded(d), "resources")
    return block and economy().template(block, d.file), d
end

-- the planet's scope, with the building country as `from` (the cost tables' `from? = { ... }`)
function B.ctx(b)
    local d = B.def(b)
    local owner = b.owner or tonumber(world.field(world.object("planet", b.planet), "owner"))
    return eval.new_ctx(eval.S("planet", b.planet), owner and eval.S("country", owner) or nil, nil, d and d.file or "?")
end

-- the economic category of the buildable (its `resources = { category = ... }`)
function B.category(b)
    local t = template(b)
    return t and t.category or (b.kind == "district" and "planet_districts" or b.kind == "zone" and "planet_zones"
        or "planet_buildings")
end

-- the table (cost / upkeep / produces) of the buildable, as { [res] = value }, with the colony's
-- modifiers
function B.table(b, kind)
    local t = template(b)
    if not t then
        return {}
    end
    local ctx = B.ctx(b)
    local e = economy()
    local base = {}
    for _, blk in ipairs(t[kind] or {}) do
        local ok, holds = true, true
        if blk.trigger then
            ok, holds = pcall(eval.trigger, blk.trigger, ctx)
        end
        if ok and holds then
            local m = blk.mult and e.value_of(blk.mult, ctx) or 1
            if m ~= 0 then
                for _, rv in ipairs(blk.values) do
                    local okv, v = pcall(e.value_of, rv[2], ctx)
                    if okv and v then
                        base[rv[1]] = (base[rv[1]] or 0) + v * m
                    end
                end
            end
        end
    end
    local M = e.modifiers("colony", b.colony) or {}
    local out = e.apply(t.category, kind, base, 1, M, ctx)
    return out
end

function B.cost(b)
    return B.table(b, "cost")
end

function B.upkeep(b)
    return B.table(b, "upkeep")
end

function B.produces(b)
    return B.table(b, "produces")
end

-- the build time (CBuildable*::CalcBuildTime: the definition's base_buildtime)
function B.build_time(b)
    local d = B.def(b)
    local v = d and defs.field(require("engine.economy.units").expanded(d), "base_buildtime")
    if type(v) == "table" then
        return eval.value(v, B.ctx(b)) or 0
    end
    local n = tonumber(v)
    if n then
        return n
    end
    if v then
        local ok, r = pcall(eval.value, { text = v }, B.ctx(b))
        return ok and r or 0
    end
    return 0
end

-- the item's `buildable_<kind> = { ... }` fields, in the game's order
function B.fields(b)
    if b.kind == "district" then
        return { { "district", b.type, true }, { "planet", b.colony } }
    elseif b.kind == "zone" then
        return { { "zone", b.type, true }, { "planet", b.colony }, { "district", b.district }, { "zone_slot", b.zone_slot } }
    elseif b.kind == "planet_building" then
        return { { "building", b.type, true }, { "planet", b.colony }, { "zone", b.zone } }
    else
        return { { "building", b.type, true }, { "planet", b.colony }, { "upgrade_building", b.upgrade_building } }
    end
end

-- the colony's planet build queue (planet.build_queue)
function B.queue(b)
    local p = world.object("planet", b.planet)
    return p and tonumber(world.field(p, "build_queue"))
end

-- the kinds a queue item is (the buildable_<kind> key)
function B.item_kind(item)
    for _, e in ipairs(item) do
        if e.op and e.key and e.value.text == nil and e.key.text:sub(1, 10) == "buildable_" then
            return e.key.text:sub(11), e.value
        end
    end
end

-- CColony::HasQueuedBuildingOrDistrictConstruction (0xdd0ab0): the planet's queue holds a
-- building (or an upgrade) or a district
function B.has_queued_construction(queue)
    local q = world.object("construction.queue_mgr.queues", queue)
    if not q then
        return false
    end
    for _, iid in ipairs(world.list(world.field(q, "items"))) do
        local item = world.object("construction.item_mgr.items", tonumber(iid))
        local kind = item and B.item_kind(item)
        if kind == "district" or kind == "planet_building" or kind == "planet_upgrade_building" then
            return true
        end
    end
    return false
end

return B
