-- engine/ai/economy/plan.lua : CAIEconomicStrategy::CreateBuildPlan (GOG 4.5.2 0xb423e0) on the
-- AI's month, after CalcBestEconomicPlan (docs/ai_economy.md sections 3 and 4):
--
--   1. the build plan emptied; no economic plan -> an empty plan (and no orders: the weekly
--      update needs a valid plan)
--   2. CalculateIncomeTargetBasedOnForecast, UpdateIncomeTargetRecords (the save's records)
--   3. the wartime edicts' upkeep out of the needed income (not ported: no wartime edicts in the
--      2210 saves)
--   4. the colonies: listA (no zone and no district queued), listB (no building or district
--      queued and vulnerable: a stronghold at weight 100; not ported, the vulnerable colonies are
--      the military minister's), listC (no building or district queued, not vulnerable)
--   5. FillBuildPlan(tables, listC, listA) (engine.ai.economy.fill)
--   6. DestroySuperfluousDistrictsAndBuildings (not ported)
--   7. an essential building in the plan -> only the essential buildings kept
--   8. stable sort by weight, highest first

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local plans = require("engine.ai.economy.plans")
local B = require("engine.ai.economy.buildables")

local plan = { stats = { months = 0, no_plan = 0 } }

-- the colonies of a country (CCountry::_OwnedColonies): colony ids, in the planets' id order
function plan.colonies(country)
    local out = {}
    for _, pid in ipairs(world.planets_of[country] or {}) do
        slice.tick("ai/economy/plan.lua:26")
        local col = world.planet_colony[pid]
        if col and world.object("colony", col) then
            out[#out + 1] = { colony = col, planet = pid, owner = country }
        end
    end
    return out
end

local function queued_kinds(queue)
    local q = world.object("construction.queue_mgr.queues", queue)
    local kinds = {}
    for _, iid in ipairs(world.list(q and world.field(q, "items"))) do
        slice.tick("ai/economy/plan.lua:38")
        local item = world.object("construction.item_mgr.items", tonumber(iid))
        local kind = item and B.item_kind(item)
        if kind then kinds[kind] = true end
    end
    return kinds
end

-- the buildable's CanBuild when the week posts it (vfunc +96): a district's next level still fits,
-- a zone's slot is still empty, a building's zone is still there
function plan.can_build(country, b)
    local slots = require("engine.ai.economy.slots")
    if b.kind == "district" then
        return slots.can_add_district(slots.colony({ colony = b.colony, planet = b.planet, owner = country }), b.type)
    elseif b.kind == "zone" then
        local d = world.object("districts", b.district)
        local z = d and world.list(world.field(d, "zones"))[b.zone_slot + 1]
        return z ~= nil and tonumber(z) == 4294967295
    elseif b.kind == "planet_building" then
        return world.object("zones", b.zone) ~= nil
    end
    return true
end

function plan.create(country, today)
    plan.stats.months = plan.stats.months + 1
    local p = require("engine.ai.economy.script").with(plans.best, country)
    if not p then
        plan.stats.no_plan = plan.stats.no_plan + 1
        return { valid = false, items = {} }
    end
    local tables = require("engine.ai.economy.script").with(plans.tables, p, country)
    plans.update_records(country, tables.target, today)
    local listA, listC = {}, {}
    for _, c in ipairs(plan.colonies(country)) do
        slice.tick("ai/economy/plan.lua:72")
        local queue = B.queue({ planet = c.planet })
        local kinds = queue and queued_kinds(queue) or {}
        if not kinds.zone and not kinds.district then
            listA[#listA + 1] = c
        end
        if not (kinds.district or kinds.planet_building or kinds.planet_upgrade_building) then
            listC[#listC + 1] = c
        end
    end
    local items = {}
    local fill = package.searchpath("engine.ai.economy.fill", package.path) and require("engine.ai.economy.fill")
    if fill then
        items = require("engine.ai.economy.script").with(fill.fill, country, p, tables, listC, listA) or {}
    end
    -- an essential building keeps only the essential buildings
    local essential = false
    for _, b in ipairs(items) do
        slice.tick("ai/economy/plan.lua:89")
        if b.essential then essential = true end
    end
    if essential then
        local kept = {}
        for _, b in ipairs(items) do
            slice.tick("ai/economy/plan.lua:94")
            if b.essential then kept[#kept + 1] = b end
        end
        items = kept
    end
    -- stable sort, highest weight first
    for i, b in ipairs(items) do b.order = i end
    table.sort(items, function(a, b)
        if a.weight ~= b.weight then return a.weight > b.weight end
        return a.order < b.order
    end)
    local top = {}
    for i = 1, math.min(8, #items) do top[i] = items[i] end
    return { valid = true, plan = p.key, tables = tables, items = items, top = top, date = today }
end

return plan
