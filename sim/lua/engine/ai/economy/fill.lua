-- engine/ai/economy/fill.lua : CAIEconomicStrategy::FillBuildPlan (GOG 4.5.2 0xb45610), the
-- planet part: EstimateAndAppendToBuildPlan<District / Building / Zone> (0xb55f60, 0xb54de0,
-- 0xb58d00) per colony of list C, then ApplyOpportunityCostsToBuildPlan (0xb45010). See
-- docs/ai_economy.md section 4 for the gates and the weight. Not ported: the orbital task, the
-- upgrades and repairs, the zone specialization, the district / building swaps of
-- SpecializeBuildables (their two AI draws are made), SpecializeAllBuildables, the planet
-- designations, the new district's zones in its modifiers.

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")
local rng = require("engine.ai.rng")
local B = require("engine.ai.economy.buildables")
local slots = require("engine.ai.economy.slots")
local plans = require("engine.ai.economy.plans")

local fill = { stats = { candidates = 0, draws = 0, appended = 0, rejected = {} } }

local function reject(why)
    fill.stats.rejected[why] = (fill.stats.rejected[why] or 0) + 1
    return nil
end

local D
local function defines()
    if D then
        return D
    end
    local g = defs.get("common/defines", "NAI")
    local function v(k, default)
        return g and tonumber(defs.field(g.block, k)) or default
    end
    D = {
        AMEN = v("AI_AMENITIES_SCORE_MULT", 3), HOUSING = v("AI_HOUSING_SCORE_MULT", 3),
        CRIME = v("AI_CRIME_REDUCTION_SCORE_MULT", 1.5), CRIME_T = v("AI_CRIME_REDUCTION_THRESHOLD", 15),
        POPS = v("AI_POPS_SCORE_MULT", 0.01), NAVAL = v("AI_NAVAL_CAP_SCORE_MULT", 3),
        AMEN_TARGET = v("AI_PLANET_AMENITY_TARGET", 200), HOUSING_BUF = v("AI_PLANET_HOUSING_TARGET_BUFFER_FACTOR", 0.1),
        GROWTH = v("AI_POP_GROWTH_JOB_TRESHOLD", 0.05), BUFFER = v("AI_INCOME_TARGET_BUFFER_FACTOR", 0.15),
        DEFICIT = v("AI_DEFICIT_SCORE_MULT", 100), PROD = v("AI_RESOURCE_PRODUCTION_SCORE_MULT", 1),
        UNBUILT_POPS = v("AI_UNBUILT_DISTRICT_BOOST_POP_THRESHOLD", 2500), UNBUILT = v("AI_UNBUILT_DISTRICT_BOOST_MULTIPLIER", 2),
        UNZONED = v("AI_UNZONED_DISTRICT_WEIGHT_MULT", 0.25), STORAGE = v("AI_STORAGE_BUILDING_CAPPED_RESOURCE_BOOST", 100),
        D_FACTOR = v("AI_DISTRICT_MAX_OPPORTUNITY_COST_FACTOR", 0.3), D_FALLOFF = v("AI_DISTRICT_OPPORTUNITY_COST_FALLOFF", 0.75),
        D_FREE = v("AI_DISTRICT_MAX_FREE_SLOTS_FOR_OPPORTUNITY_COST", 3), D_MIN = v("AI_DISTRICT_MIN_HYPOTHETICAL_WEIGHT", 50),
        B_FACTOR = v("AI_BUILDING_MAX_OPPORTUNITY_COST_FACTOR", 0.5), B_FALLOFF = v("AI_BUILDING_OPPORTUNITY_COST_FALLOFF", 0.5),
        B_FREE = v("AI_BUILDING_MAX_FREE_SLOTS_FOR_OPPORTUNITY_COST", 3), B_MIN = v("AI_BUILDING_MIN_HYPOTHETICAL_WEIGHT", 100),
    }
    return D
end

local function units()
    return require("engine.economy.units")
end

local function expanded(d)
    return units().expanded(d)
end

local function field(d, key)
    return defs.field(expanded(d), key)
end

local function num(v, ctx)
    if v == nil then return 0 end
    if type(v) == "table" then
        local ok, r = pcall(eval.value, v, ctx)
        return ok and r or 0
    end
    local n = tonumber(v)
    if n then return n end
    local ok, r = pcall(eval.value, { text = v }, ctx)
    return ok and r or 0
end

local function holds(block, ctx)
    return slots.holds(block, ctx)
end

-- ---------------------------------------------------------------------------------------------
-- modifier sets: { [modifier] = value }

local function add_block(M, block, ctx, factor)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.value.text then
            local k = e.key.text
            if k ~= "potential" and k ~= "modifier" then
                M[k] = (M[k] or 0) + num(e.value.text, ctx) * (factor or 1)
            end
        end
    end
end

-- `key = { mods }` and `triggered_key = { potential = { } modifier = { mods } | mods }`
local function collect(M, d, key, ctx, factor)
    for _, e in ipairs(expanded(d)) do
        if e.op and e.key and e.value.text == nil then
            local k = e.key.text
            if k == key then
                add_block(M, e.value, ctx, factor)
            elseif k == "triggered_" .. key then
                local pot = defs.field(e.value, "potential")
                if holds(pot, ctx) then
                    local mod = defs.field(e.value, "modifier")
                    if type(mod) == "table" then
                        add_block(M, mod, ctx, factor)
                    else
                        add_block(M, e.value, ctx, factor)
                    end
                end
            end
        end
    end
end

-- CalcAndApproximateNewModifier (0xb4d2a0): oa * m + a * om + a * m
local function canm(M, C, adds, mults, factor)
    local a, m, oa, om = 0, 0, 0, 1
    for _, k in ipairs(adds) do
        a = a + (M[k] or 0) * factor
        oa = oa + (C[k] or 0)
    end
    for _, k in ipairs(mults) do
        m = m + (M[k] or 0)
        om = om + (C[k] or 0)
    end
    return oa * m + a * om + a * m
end

local AMEN_A, AMEN_M = { "planet_amenities_add", "planet_amenities_no_happiness_add" }, { "planet_amenities_mult", "planet_amenities_no_happiness_mult" }
local CRIME_A, CRIME_M = { "planet_crime_add", "planet_crime_no_happiness_add" }, { "planet_crime_mult", "planet_crime_no_happiness_mult" }

local function misc_terms(approx, M, C, factor)
    approx.amen = approx.amen + canm(M, C, AMEN_A, AMEN_M, factor)
    approx.housing = approx.housing + canm(M, C, { "planet_housing_add" }, { "planet_housing_mult" }, factor)
    approx.crime = approx.crime - canm(M, C, CRIME_A, CRIME_M, factor)
    approx.naval = approx.naval + canm(M, C, { "country_naval_cap_add" }, { "country_naval_cap_mult" }, factor)
    if canm(M, C, { "planet_pop_assembly_add" }, { "planet_pop_assembly_mult" }, factor) > 0 then
        approx.pop = true
    end
end

local function add_table(out, t, f)
    for r, v in pairs(t or {}) do
        out[r] = (out[r] or 0) + v * (f or 1)
    end
end

-- ApproximateProductionAndUpkeepForJob (0xb4fd70): a job's tables and modifiers times amount / 100
local function job_approx(approx, job, amount, info, ctx)
    local d = defs.get("common/pop_jobs", job)
    if not d then
        return
    end
    local economy = require("engine.economy")
    local mult = amount / economy.POP_BULK
    local C = economy.modifiers("colony", info.colony) or {}
    local Mj = {}
    collect(Mj, d, "planet_modifier", ctx)
    collect(Mj, d, "country_modifier", ctx)
    misc_terms(approx, Mj, C, mult)
    for _, t in ipairs(units().templates(economy, "common/pop_jobs", job)) do
        for kind, side in pairs({ produces = "prod", upkeep = "upk" }) do
            local base = {}
            for _, blk in ipairs(t[kind] or {}) do
                if blk.trigger == nil or holds(blk.trigger, ctx) then
                    local m = blk.mult and economy.value_of(blk.mult, ctx) or 1
                    for _, rv in ipairs(blk.values) do
                        local ok, v = pcall(economy.value_of, rv[2], ctx)
                        if ok and v then base[rv[1]] = (base[rv[1]] or 0) + v * m end
                    end
                end
            end
            add_table(approx[side], economy.apply(t.category, kind, base, 1, C, ctx), mult)
        end
    end
end

-- ApproximateProductionAndUpkeepInternal (0xb4d890) and the per-kind front ends
local function approximate(b, d, info, ctx)
    local economy = require("engine.economy")
    local C = economy.modifiers("colony", info.colony) or {}
    local approx = { amen = 0, housing = 0, crime = 0, naval = 0, pop = false, prod = {}, upk = {} }
    -- CalcAIProductionResources: the `ai_resource_production` blocks whose trigger holds
    for _, e in ipairs(expanded(d)) do
        if e.op and e.key and e.key.text == "ai_resource_production" and e.value.text == nil then
            if holds(defs.field(e.value, "trigger"), ctx) then
                for _, x in ipairs(e.value) do
                    if x.op and x.key and x.key.text ~= "trigger" and x.value.text then
                        approx.prod[x.key.text] = (approx.prod[x.key.text] or 0) + num(x.value.text, ctx)
                    end
                end
            end
        end
    end
    add_table(approx.prod, B.produces(b))
    add_table(approx.upk, B.upkeep(b))
    local M = {}
    if b.kind == "district" then
        collect(M, d, "planet_modifier", ctx)
    elseif b.kind == "zone" then
        local level = b.level or 1
        collect(M, d, "district_planet_modifier", ctx, level)
        collect(M, d, "planet_modifier", ctx)
    else
        collect(M, d, "planet_modifier", ctx)
        collect(M, d, "country_modifier", ctx)
    end
    misc_terms(approx, M, C, 1)
    local g = M.logistic_growth_mult or 0
    if g >= defines().GROWTH then approx.pop = true end
    for k, v in pairs(M) do
        local job = k:match("^job_(.+)_add$")
        if job and v > 0 then
            job_approx(approx, job, v, info, ctx)
        end
    end
    return approx
end

-- ---------------------------------------------------------------------------------------------
-- the weight

-- CalcWeightedFulfillment (0xb3f310)
local function wf(need, gain)
    if need <= 0 or gain <= 0 then
        return 0
    end
    return 100 * math.min(gain / need, 1) + math.min(need, gain)
end

-- CalcResourceProductionWeight (0xb51b50)
local function resource_weight(t, P, U)
    local Dn = defines()
    local acc = 0
    local economy = require("engine.economy")
    for _, r in ipairs(economy.resources) do
        local T, F, N, Fo = t.target[r] or 0, t.current[r] or 0, t.needed[r] or 0, t.focus[r] or 0
        local Dd = -F
        local p, u = P[r] or 0, U[r] or 0
        if Fo > 0 and Fo - F > 0 and p - u > 0 then
            acc = acc + 100 * math.min((p - u) / (Fo - F), 1) + (p - u)
        end
        local s = (T > 0 and T * (1 + Dn.BUFFER) or T) - F
        local v
        if s > 0 and p > 0 then
            v = 100 * math.min(p / s, 1) + p
        elseif T < 0 and N < 0 and u > 0 then
            v = 100 * math.min(u / -N, 1) + u
        elseif p > 0 and Dd > 0 then
            v = 100 * math.min(p / Dd, 1) + p
        end
        if v then
            if ((T > 0 or (T == 0 and Fo > 0 and Fo - F > 0)) and Dd > 0) or (T < 0 and F > 0) then
                v = v * Dn.DEFICIT
            end
            acc = acc + v
        end
    end
    return acc * Dn.PROD
end

-- CalcBuildWeight (0xb3f920)
local function build_weight(env, approx, misc)
    local Dn = defines()
    local w = 1 + resource_weight(env.tables, approx.prod, approx.upk)
    w = w + Dn.AMEN * wf(misc.amen, approx.amen)
    w = w + Dn.HOUSING * wf(misc.housing, approx.housing)
    if misc.crime > Dn.CRIME_T then
        w = w + Dn.CRIME * wf(misc.crime, approx.crime)
    end
    if approx.pop then
        w = w + Dn.POPS * math.max(1, env.plan_pops - env.pops)
    end
    w = w + Dn.NAVAL * wf(env.plan_naval - env.naval, approx.naval)
    return w
end

-- CalcMiscNeedsExceptNavalCap (0xb4c060)
local function misc_needs(info)
    local Dn = defines()
    local c = world.object("colony", info.colony)
    local free_amen = tonumber(world.field(c, "free_amenities")) or 0
    local function round(x) return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5) end
    return {
        amen = math.max(0, Dn.AMEN_TARGET - round(free_amen)),
        housing = (tonumber(world.field(c, "housing_usage")) or 0) * Dn.HOUSING_BUF - (tonumber(world.field(c, "free_housing")) or 0),
        crime = tonumber(world.field(c, "crime")) or 0,
    }
end

-- DecreasesTotalDeficits (0xb41300)
local function decreases_deficits(t, P, U)
    local gain, loss, sp, su = 0, 0, 0, 0
    for _, r in ipairs(require("engine.economy").resources) do
        local net = (P[r] or 0) - (U[r] or 0)
        local T, F = t.target[r] or 0, t.current[r] or 0
        sp, su = sp + (P[r] or 0), su + (U[r] or 0)
        if T >= 0 and F < 0 and net > 0 then gain = gain + math.min(net, -F) end
        if T < 0 and F > 0 and net < 0 then loss = loss + math.min(-net, F) end
    end
    return (gain > 0 and sp > su) or loss > 0
end

-- CColony::HasAvailablePopsForAI (0xdaf270): a job of a type that counts_as_available_for_ai with
-- workforce
local function has_available_pops(info)
    local c = world.object("colony", info.colony)
    for _, jid in ipairs(world.list(world.field(c, "pop_jobs"))) do
        local j = world.object("pop_jobs", tonumber(jid))
        local t = j and world.field(j, "type")
        local d = t and defs.get("common/pop_jobs", t)
        if d and field(d, "count_as_available_for_ai") == "yes" and (tonumber(world.field(j, "workforce")) or 0) > 0 then
            return true
        end
    end
    return false
end

-- the colony's designation affinities (colony_types ai_building_set_affinity)
local function affinities(info)
    local c = world.object("colony", info.colony)
    local des = world.field(c, "final_designation")
    local d = des and defs.get("common/colony_types", des)
    local blk = d and field(d, "ai_building_set_affinity")
    local out = {}
    for _, e in ipairs(type(blk) == "table" and blk or {}) do
        if e.op and e.key and e.value.text then out[e.key.text] = tonumber(e.value.text) or 0 end
    end
    return out
end

local function list_of(d, key)
    local out = {}
    local blk = field(d, key)
    for _, e in ipairs(type(blk) == "table" and blk or {}) do
        if e.text then out[#out + 1] = e.text end
    end
    return out
end

-- CalcZoneAffinity: the best affinity of the zone's included building sets (at least 1)
local function zone_affinity(aff, zd)
    local best = 1
    for _, s in ipairs(list_of(zd, "included_building_sets")) do
        if aff[s] and aff[s] > best then best = aff[s] end
    end
    for _, s in ipairs(list_of(zd, "include")) do
        if aff[s] and aff[s] > best then best = aff[s] end
    end
    return best
end

-- ---------------------------------------------------------------------------------------------
-- zones and building slots

local NONE = 4294967295

-- the zone types a district slot may take (the slot's included_zone_sets, not excluded) whose
-- potential and unlock hold, with the slot's own potential / unlock
local slot_cache = {}  -- planet:slot -> zones, for one fill
local slot_zones_raw
local function slot_zones(slot_name, ctx)
    local k = tostring(ctx.this and ctx.this.key) .. ":" .. slot_name
    local v = slot_cache[k]
    if v == nil then
        v = slot_zones_raw(slot_name, ctx)
        slot_cache[k] = v
    end
    return v
end
function slot_zones_raw(slot_name, ctx)
    local sd = defs.get("common/zone_slots", slot_name)
    if not sd then return {} end
    if not holds(field(sd, "potential"), ctx) or not holds(field(sd, "unlock"), ctx) then
        return {}
    end
    local sets = {}
    for _, s in ipairs(list_of(sd, "included_zone_sets")) do sets[s] = true end
    local excl = {}
    for _, s in ipairs(list_of(sd, "exclude")) do excl[s] = true end
    local out = {}
    for name, zd in pairs(defs.folder("common/zones")) do
        if not excl[name] then
            local ok = false
            for _, s in ipairs(list_of(zd, "zone_sets")) do
                if sets[s] or sets[name] then ok = true end
            end
            if ok then out[#out + 1] = name end
        end
    end
    table.sort(out)
    return out
end
fill.slot_zones = slot_zones

local function zone_can_build(zd, ctx)
    if not holds(field(zd, "potential"), ctx) then return false end
    for _, e in ipairs(expanded(zd)) do
        if e.op and e.key and e.key.text == "unlock" and not holds(e.value, ctx) then return false end
    end
    return true
end

-- the empty slots of the colony's districts where zone type z can go: { {district, slot, level} }
local function zone_slots_for(info, z, ctx)
    local out = {}
    local zd = defs.get("common/zones", z)
    if not zd or not zone_can_build(zd, ctx) then return out end
    for _, dist in ipairs(info.list) do
        local dd = defs.get("common/districts", dist.type)
        local slot_names = dd and list_of(dd, "zone_slots") or {}
        for i, sname in ipairs(slot_names) do
            local zid = dist.zones[i]
            if (zid == nil or zid == NONE) and dist.level > 0 then
                for _, cand in ipairs(slot_zones(sname, ctx)) do
                    if cand == z then
                        out[#out + 1] = { district = dist.id, slot = i - 1, level = dist.level }
                    end
                end
            end
        end
    end
    return out
end

-- CZoneType::CalcMaxBuildings: max_buildings, limited to district level / districts_per_building
local function zone_max_buildings(zd, level)
    local max = tonumber(field(zd, "max_buildings")) or 3   -- without one: the 3 slots its zone_building_slots_add gives [I]
    local per = tonumber(field(zd, "districts_per_building"))
    if per and per > 0 then
        max = math.min(max, math.floor(level / per))
    end
    return max
end

-- whether building type t can go into zone type zd (the zone's include / exclude lists and sets)
local function zone_accepts(zd, t, bd)
    for _, x in ipairs(list_of(zd, "exclude")) do
        if x == t then return false end
    end
    local sets = list_of(bd, "building_sets")
    for _, x in ipairs(list_of(zd, "excluded_building_sets")) do
        for _, s in ipairs(sets) do
            if s == x then return false end
        end
    end
    for _, x in ipairs(list_of(zd, "include")) do
        if x == t or x == "all" then return true end
    end
    for _, x in ipairs(list_of(zd, "included_building_sets")) do
        for _, s in ipairs(sets) do
            if s == x then return true end
        end
    end
    return false
end

-- NPlanetBuildingUtil::FindBestBuildingSlot (0xe50660): of the zones (districts in order) where the
-- building can be added (CColony::CanAddBuilding: a free slot, the zone accepts it), the first with
-- the highest ai_priority (CZoneType +4176) -> zone id, its type, free slots
local function building_slot(info, t, bd)
    local best, bestp = nil, -1
    for _, dist in ipairs(info.list) do
        for _, zid in ipairs(dist.zones) do
            if zid ~= NONE then
                local z = world.object("zones", zid)
                local ztype = z and world.field(z, "type")
                local zd = ztype and defs.get("common/zones", ztype)
                if zd then
                    local n = #world.list(world.field(z, "buildings")) + (info.queued_buildings[zid] or 0)
                    local max = zone_max_buildings(zd, dist.level)
                    local prio = tonumber(field(zd, "ai_priority")) or 0
                    if n < max and zone_accepts(zd, t, bd) and prio > bestp then
                        best, bestp = { zid, zd, max - n }, prio
                    end
                end
            end
        end
    end
    if best then
        return best[1], best[2], best[3]
    end
end

-- the colony's buildings by type (with the queued ones)
local function building_counts(info)
    local counts, queued_in = {}, {}
    local c = world.object("colony", info.colony)
    for _, bid in ipairs(world.list(world.field(c, "buildings_cache"))) do
        local b = world.object("buildings", tonumber(bid))
        local t = b and world.field(b, "type")
        if t then counts[t] = (counts[t] or 0) + 1 end
    end
    local p = world.object("planet", info.planet)
    local q = world.object("construction.queue_mgr.queues", tonumber(world.field(p, "build_queue")))
    for _, iid in ipairs(world.list(q and world.field(q, "items"))) do
        local item = world.object("construction.item_mgr.items", tonumber(iid))
        local kind, blk = B.item_kind(item or {})
        if kind == "planet_building" then
            local t = world.field(blk, "building")
            counts[t] = (counts[t] or 0) + 1
            local zid = tonumber(world.field(blk, "zone"))
            if zid then queued_in[zid] = (queued_in[zid] or 0) + 1 end
        end
    end
    return counts, queued_in
end

-- CBuildingType::CanBuild (the parts the 2210 saves need): can_build, potential, allow,
-- planet_limit
-- the country's buildings by type, with the queued ones (empire_limit), for one fill
local empire_counts = {}
local function country_building_counts(country)
    local counts = empire_counts[country]
    if counts then return counts end
    counts = {}
    for _, pid in ipairs(world.planets_of[country] or {}) do
        local col = world.planet_colony[pid]
        local c = col and world.object("colony", col)
        for _, bid in ipairs(world.list(c and world.field(c, "buildings_cache"))) do
            local b = world.object("buildings", tonumber(bid))
            local t = b and world.field(b, "type")
            if t then counts[t] = (counts[t] or 0) + 1 end
        end
    end
    for _, it in pairs(world.stores["construction.item_mgr.items"] or {}) do
        if tonumber(world.field(it, "paying_country")) == country then
            local kind, blk = B.item_kind(it)
            if kind == "planet_building" then
                local t = world.field(blk, "building")
                counts[t] = (counts[t] or 0) + 1
            end
        end
    end
    empire_counts[country] = counts
    return counts
end

-- CBuildingType::CanBuild (the parts the 2210 saves need): the planet's own buildings (no
-- owner_type: corporate branch offices and subject holdings are other countries'), can_build,
-- potential, allow, planet_limit, empire_limit
local function building_can_build(info, t, bd, ctx, counts)
    if field(bd, "owner_type") ~= nil then return false end
    if field(bd, "can_build") == "no" then return false end
    if not holds(field(bd, "potential"), ctx) or not holds(field(bd, "allow"), ctx) then
        return false
    end
    local limit = tonumber(field(bd, "planet_limit"))
    if limit and (counts[t] or 0) >= limit then return false end
    local el = field(bd, "empire_limit")
    if el ~= nil then
        local cctx = eval.new_ctx(eval.S("country", info.owner), nil, nil, bd.file)
        local n = type(el) == "table" and eval.weight(el, cctx, 0) or num(el, cctx)
        if (country_building_counts(info.owner)[t] or 0) >= n then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the candidates

-- the gates common to the kinds, after CanBuild; returns the approximation or nil
local function gates(env, info, b, d, ctx, cost)
    -- cost gate: no income of a resource and not enough of it in stock
    for r, v in pairs(cost) do
        if v > 0 and (env.tables.current[r] or 0) <= 0 and (env.stockpile[r] or 0) < v then
            return reject("cost")
        end
    end
    local dt = field(d, "destroy_trigger")
    if type(dt) == "table" and #dt > 0 and holds(dt, ctx) then
        return reject("destroy_trigger")
    end
    if field(d, "ai_estimate_without_unemployment") ~= "yes" and not info.available_pops then
        return reject("no available pops")
    end
    -- the scope's random seed: one draw of the unsynced AI generator
    rng.draw(env.country)
    fill.stats.draws = fill.stats.draws + 1
    local approx = approximate(b, d, info, ctx)
    local essential = field(d, "is_essential") == "yes"
    if not essential then
        for r, u in pairs(approx.upk) do
            if u > math.max(env.tables.current[r] or 0, 0) then
                if not decreases_deficits(env.tables, approx.prod, approx.upk) then
                    return reject("deficit")
                end
                break
            end
        end
    end
    return approx, essential
end

local function append(items, b, w)
    if w > 1 then
        b.weight = w
        items[#items + 1] = b
        fill.stats.appended = fill.stats.appended + 1
    else
        reject("weight <= 1")
    end
end

local function estimate_districts(env, info, items)
    local aff = affinities(info)
    for _, name in ipairs(env.district_types) do
        local d = defs.get("common/districts", name)
        if slots.has_prerequisites(env.country, expanded(d)) and slots.can_add_district(info, name) then
            fill.stats.candidates = fill.stats.candidates + 1
            local b = { kind = "district", type = name, colony = info.colony, planet = info.planet, owner = env.country }
            local ctx = B.ctx(b)
            local cost = B.cost(b)
            local approx, essential = gates(env, info, b, d, ctx, cost)
            if approx then
                local w = build_weight(env, approx, info.misc) + (essential and 1000 or 0)
                w = (w + num(field(d, "additional_ai_weight"), ctx)) * (field(d, "ai_weight_coefficient") and num(field(d, "ai_weight_coefficient"), ctx) or 1)
                -- CalcDesignationAffinity, CalcUnbuiltDistrictBoost, CalcUnzonedDistrictPenalty
                local da, has_zone, unzoned = 1, false, false
                local have = info.districts[name]
                for i, sname in ipairs(list_of(d, "zone_slots")) do
                    for _, z in ipairs(slot_zones(sname, ctx)) do
                        local zd = defs.get("common/zones", z)
                        if zd then
                            local a = zone_affinity(aff, zd)
                            if a > da then da = a end
                            if holds(field(zd, "potential"), ctx) then
                                has_zone = true
                                if have and have.level > 0 and (have.zones[i] == nil or have.zones[i] == NONE)
                                    and zone_can_build(zd, ctx) then
                                    unzoned = true
                                end
                            end
                        end
                    end
                end
                w = w * da
                if info.pops >= defines().UNBUILT_POPS and not have and not info.queued[name] and has_zone then
                    w = w * defines().UNBUILT
                end
                if unzoned then
                    w = w * defines().UNZONED
                end
                b.cost = cost
                b.group = "planet:" .. info.planet
                append(items, b, w)
            end
        end
    end
end

local function estimate_buildings(env, info, items)
    local aff = affinities(info)
    local counts, queued_in = building_counts(info)
    info.queued_buildings = queued_in
    for _, name in ipairs(env.building_types) do
        local d = defs.get("common/buildings", name)
        if slots.has_prerequisites(env.country, expanded(d)) then
            local b = { kind = "planet_building", type = name, colony = info.colony, planet = info.planet, owner = env.country }
            local ctx = B.ctx(b)
            if building_can_build(info, name, d, ctx, counts) then
                fill.stats.candidates = fill.stats.candidates + 1
                local cost = B.cost(b)
                local approx, essential = gates(env, info, b, d, ctx, cost)
                if approx then
                    local zid, zd, free = building_slot(info, name, d)
                    if zid then
                        local w = build_weight(env, approx, info.misc) + (essential and 1000 or 0)
                            + num(field(d, "additional_ai_weight"), ctx)
                        w = w * (field(d, "ai_weight_coefficient") and num(field(d, "ai_weight_coefficient"), ctx) or 1)
                        local sa = 1
                        for _, s in ipairs(list_of(d, "building_sets")) do
                            if aff[s] and aff[s] > sa then sa = aff[s] end
                        end
                        w = w * sa
                        b.zone, b.cost, b.essential = zid, cost, essential
                        b.group, b.free = "zone:" .. zid, free
                        append(items, b, w)
                    else
                        reject("no building slot")
                    end
                end
            end
        end
    end
end

local function estimate_zones(env, info, items)
    local aff = affinities(info)
    for _, name in ipairs(env.zone_types) do
        local d = defs.get("common/zones", name)
        local b = { kind = "zone", type = name, colony = info.colony, planet = info.planet, owner = env.country }
        local ctx = B.ctx(b)
        local where = zone_slots_for(info, name, ctx)
        if #where > 0 then
            fill.stats.candidates = fill.stats.candidates + 1
            b.district, b.zone_slot, b.level = where[1].district, where[1].slot, where[1].level
            local cost = B.cost(b)
            local approx = gates(env, info, b, d, ctx, cost)
            if approx then
                local w = build_weight(env, approx, info.misc) + num(field(d, "additional_ai_weight"), ctx)
                w = w * (field(d, "ai_weight_coefficient") and num(field(d, "ai_weight_coefficient"), ctx) or 1)
                w = w * zone_affinity(aff, d)
                b.cost = cost
                append(items, b, w)
            end
        end
    end
end

-- ApplyOpportunityCostsToBuildPlan (0xb45010): per planet (districts) and per zone (new
-- buildings), with few free slots left the best item pays for the second best and the others
-- are put aside (x 0.001)
local function opportunity_costs(items, infos)
    local Dn = defines()
    local groups, order = {}, {}
    for i, b in ipairs(items) do
        if b.group then
            local g = groups[b.group]
            if not g then
                local is_d = b.kind == "district"
                g = { items = {}, first = is_d and Dn.D_MIN or Dn.B_MIN, second = is_d and Dn.D_MIN or Dn.B_MIN,
                    best = nil, district = is_d, b = b }
                groups[b.group] = g
                order[#order + 1] = b.group
            end
            g.items[#g.items + 1] = i
            local w = b.weight
            if w > g.second then g.second = w end
            if w > g.first then g.best = i; g.second = g.first; g.first = w end
        end
    end
    for _, key in ipairs(order) do
        local g = groups[key]
        local free, factor, falloff, maxfree
        if g.district then
            local info = infos[g.b.colony]
            free = slots.max_districts(info) - info.levels
            factor, falloff, maxfree = Dn.D_FACTOR, Dn.D_FALLOFF, Dn.D_FREE
        else
            free = g.b.free or 0
            factor, falloff, maxfree = Dn.B_FACTOR, Dn.B_FALLOFF, Dn.B_FREE
        end
        if free <= maxfree then
            local cost = g.second * factor * falloff ^ math.max(free - 1, 0)
            for _, i in ipairs(g.items) do
                if i == g.best then
                    items[i].weight = items[i].weight - cost
                else
                    items[i].weight = items[i].weight * 0.001
                end
            end
        end
    end
end

-- the database order of a folder (files in load order, definitions in file order)
local orders = {}
local function db_order(folder)
    if orders[folder] then return orders[folder] end
    local list = {}
    for name, d in pairs(defs.folder(folder)) do
        list[#list + 1] = { name = name, file = d.file or "", line = d.line or 0 }
    end
    table.sort(list, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    local out = {}
    for i, x in ipairs(list) do out[i] = x.name end
    orders[folder] = out
    return out
end

-- the two SpecializeBuildables tasks: one AI draw each when more than one colony has two or more
-- district types (buildings) to swap (the swaps themselves are not ported)
local function specialization_draws(env, infos, colonies)
    local kept = 0
    for _, c in ipairs(colonies) do
        local info = infos[c.colony]
        local n = 0
        for _, dist in ipairs(info.list) do
            local d = defs.get("common/districts", dist.type)
            if d and field(d, "exempt_from_ai_planet_specialization") ~= "yes" and dist.level > 0 then
                n = n + 1
            end
        end
        if n >= 2 then kept = kept + 1 end
    end
    if kept > 1 then
        rng.draw(env.country)
        fill.stats.draws = fill.stats.draws + 1
    end
end

-- fill.fill(country, plan, tables, listC, listA) -> the build plan's items (unsorted)
function fill.fill(country, plan, tables, listC, listA)
    local c = world.object("country", country)
    local stock = world.path(c, "modules", "standard_economy_module", "resources")
    local stockpile = {}
    for _, e in ipairs(type(stock) == "table" and stock or {}) do
        if e.op and e.key then stockpile[e.key.text] = tonumber(e.value.text) or 0 end
    end
    local env = {
        country = country, tables = tables, stockpile = stockpile,
        plan_pops = tables.pops or 0, pops = tonumber(world.field(c, "num_sapient_pops")) or 0,
        plan_naval = tables.naval_cap or 0, naval = math.floor(tonumber(world.field(c, "naval_capacity")) or 0),
        district_types = db_order("common/districts"), building_types = db_order("common/buildings"),
        zone_types = db_order("common/zones"),
    }
    local items, infos = {}, {}
    slot_cache, empire_counts = {}, {}
    for _, col in ipairs(listC) do
        local info = slots.colony(col)
        info.misc = misc_needs(info)
        info.available_pops = has_available_pops(info)
        info.pops = tonumber(world.field(world.object("colony", col.colony), "num_sapient_pops")) or 0
        info.queued_buildings = {}
        infos[col.colony] = info
    end
    -- the tasks: buildings, districts, (upgrades), two specializations, zones
    for _, col in ipairs(listC) do estimate_buildings(env, infos[col.colony], items) end
    for _, col in ipairs(listC) do estimate_districts(env, infos[col.colony], items) end
    specialization_draws(env, infos, listC)
    specialization_draws(env, infos, listC)
    for _, col in ipairs(listC) do estimate_zones(env, infos[col.colony], items) end
    opportunity_costs(items, infos)
    return items
end

function fill.report()
    local s = fill.stats
    local r = {}
    for k, v in pairs(s.rejected) do r[#r + 1] = k .. " " .. v end
    table.sort(r)
    return string.format("ai build plans: %d candidates, %d AI draws, %d appended; rejected: %s", s.candidates, s.draws,
        s.appended, table.concat(r, ", "))
end

return fill
