-- engine/economy/units.lua : the economic units of the world, kind by kind (the game registers 22
-- kinds with CEconomicUnitManager: pop jobs, pop groups, colonies, planets, ships, starbases,
-- armies, leaders, megastructures, sectors, ...). Each kind is a function(economy) that lists its
-- units and adds them to the budgets with economy.unit(country, template, scale, M, ctx, label).

local defs = require("engine.defs")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local world = require("engine.world")

local units = {}
units.order = {}

local function kind(name, f)
    units.order[#units.order + 1] = name
    units[name] = f
end

local NONE_ID = 4294967295

local function num(v)
    return tonumber(v) or 0
end

local function ids(block)
    local out = {}
    for _, t in ipairs(world.list(block)) do
        out[#out + 1] = tonumber(t)
    end
    return out
end

-- a definition's block with its top-level inline scripts expanded (a job's resources can come
-- from one: `inline_script = { script = shroud/jobs/colonist_job ... }`), once
local expanded_blocks = setmetatable({}, { __mode = "k" })
local function expanded(def)
    local b = def and def.block
    if b == nil then return {} end
    local x = expanded_blocks[b]
    if x == nil then
        x = b
        for _, e in ipairs(b) do
            if e.op and e.key and e.key.text:lower() == "inline_script" then
                local db = require("simscript.db")
                local source = require("stellar.script.source")
                x = source.expand(db.fs, b, {}, 0, "file: " .. tostring(def.file))
                break
            end
        end
        expanded_blocks[b] = x
    end
    return x
end
units.expanded = expanded

-- the `resources = { }` blocks of a definition (some have more than one key: resources,
-- overlord_resources, automation_resources, ...)
local function blocks_of(def, key)
    local out = {}
    for _, e in ipairs(expanded(def)) do
        if e.op and e.key and e.key.text == key and e.value.text == nil then
            out[#out + 1] = e.value
        end
    end
    return out
end
units.blocks_of = blocks_of

local function templates(economy, folder, name, key)
    local d = defs.get(folder, name)
    if d == nil then
        return {}, nil
    end
    local list = {}
    for _, b in ipairs(blocks_of(d, key or "resources")) do
        list[#list + 1] = economy.template(b, d.file)
    end
    return list, d
end
units.templates = templates

-- the colonies: colony id -> { planet, owner }, from the planets' `colony` field
local function colonies()
    local out = {}
    for _, pid in ipairs(world.all("planet")) do
        slice.tick("economy/units.lua:83")
        local p = world.object("planet", pid)
        local c = world.field(p, "colony")
        if c ~= nil then
            out[#out + 1] = { colony = tonumber(c), planet = pid, owner = tonumber(world.field(p, "owner")), obj = p }
        end
    end
    return out
end
units.colonies = colonies

local missing = {}
units.missing = missing
local function miss(what)
    missing[what] = (missing[what] or 0) + 1
end

-- ---------------------------------------------------------------------------------------------
-- pop jobs: scale max(0, (workforce + bonus) / 100), the colony's modifiers, in the planet's scope

kind("jobs", function(economy)
    local growth_left = {}   -- pop group -> its growth of the month not yet taken out of a job
    for _, col in ipairs(colonies()) do
        economy.current_colony = col.colony
        local c = world.object("colony", col.colony)
        local M = economy.modifiers("colony", col.colony)
        for _, jid in ipairs(ids(world.field(c, "pop_jobs"))) do
            local job = world.object("pop_job", jid)
            local wf = num(world.field(job, "workforce")) + num(world.field(job, "bonus_workforce"))
            local s = math.max(0, wf / economy.POP_BULK)
            -- before the month's growth (economy.before_growth): a job with room (uncapped, max
            -- -1: civilians, peasants, unemployment; or below its max) took its pop groups'
            -- growth; it is taken out (once per pop group)
            local maxw = num(world.field(job, "max_workforce"))
            if economy.before_growth and s > 0 and (maxw < 0 or num(world.field(job, "workforce")) < maxw) then
                local now, before = 0, 0
                for _, a in ipairs(world.blocks(world.field(job, "pop_groups"))) do
                    local amount = num(world.field(a, "amount"))
                    local gid = tonumber(world.field(a, "pop_group"))
                    local left = growth_left[gid]
                    if left == nil then
                        left = num(world.field(world.object("pop_group", gid), "last_month_growth"))
                    end
                    local take = left > 0 and math.min(left, amount) or left
                    growth_left[gid] = left - take
                    now = now + amount
                    before = before + amount - take
                end
                if now > 0 then s = s * math.max(0, before) / now end
            end
            if s > 0 then
                local type = world.field(job, "type")
                local list, d = templates(economy, "common/pop_jobs", type)
                if d == nil then miss("pop_job " .. tostring(type)) end
                for _, t in ipairs(list) do
                    economy.unit(col.owner, t, s, M, economy.ctx("planet", col.planet, d.file), "job " .. type .. " #" .. jid)
                end
                -- the automated part of the workforce: the job's pop category's automation_resources
                local auto = num(world.field(job, "automated_workforce"))
                local pcat = d and defs.field(expanded(d), "category")
                if auto > 0 and pcat then
                    local alist, ad = templates(economy, "common/pop_categories", pcat, "automation_resources")
                    for _, t in ipairs(alist) do
                        economy.unit(col.owner, t, auto / economy.POP_BULK, M, economy.ctx("planet", col.planet, ad.file),
                            "automation " .. type .. " #" .. jid)
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- buildings, districts and zones of a colony: the colony's modifiers, in the planet's scope

kind("buildings", function(economy)
    for _, col in ipairs(colonies()) do
        economy.current_colony = col.colony
        local c = world.object("colony", col.colony)
        local M = economy.modifiers("colony", col.colony)
        for _, bid in ipairs(ids(world.field(c, "buildings_cache"))) do
            local b = world.object("buildings", bid)
            local type = b and world.field(b, "type")
            local list, d = templates(economy, "common/buildings", type)
            if d == nil then miss("building " .. tostring(type)) end
            for _, t in ipairs(list) do
                economy.unit(col.owner, t, 1, M, economy.ctx("planet", col.planet, d.file), "building " .. type .. " #" .. bid)
            end
        end
    end
end)

kind("districts", function(economy)
    for _, col in ipairs(colonies()) do
        economy.current_colony = col.colony
        local c = world.object("colony", col.colony)
        local M = economy.modifiers("colony", col.colony)
        for _, did in ipairs(ids(world.field(c, "districts"))) do
            local dd = world.object("districts", did)
            local type = dd and world.field(dd, "type")
            local level = num(world.field(dd, "level"))
            if level > 0 then
                local list, d = templates(economy, "common/districts", type)
                if d == nil then miss("district " .. tostring(type)) end
                for _, t in ipairs(list) do
                    economy.unit(col.owner, t, level, M, economy.ctx("planet", col.planet, d.file), "district " .. type .. " #" .. did)
                end
            end
            for _, zid in ipairs(ids(world.field(dd, "zones"))) do
                if zid ~= NONE_ID then
                    local z = world.object("zones", zid)
                    local ztype = z and world.field(z, "type")
                    local list, d = templates(economy, "common/zones", ztype)
                    if d == nil then miss("zone " .. tostring(ztype)) end
                    for _, t in ipairs(list) do
                        economy.unit(col.owner, t, 1, M, economy.ctx("planet", col.planet, d.file), "zone " .. ztype .. " #" .. zid)
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- pop groups: scale size / 100, the pop group's own modifiers, in its scope. The tables: the
-- species archetype's (planet_pops), each trait's (planet_pops_traits), the pop category's.

local function species_traits(species)
    local out = {}
    local t = world.field(species, "traits")
    for _, v in ipairs(world.fields(t, "trait")) do
        if type(v) == "string" then out[#out + 1] = v end
    end
    return out
end
units.species_traits = species_traits

local function archetype_of(species)
    local class = world.field(species, "class")
    local d = class and defs.get("common/species_classes", class)
    return d and defs.field(d.block, "archetype") or "BIOLOGICAL"
end
units.archetype_of = archetype_of

kind("pop_groups", function(economy)
    -- a pop group's `planet` is its colony's id
    local owner_of = {}
    for _, col in ipairs(colonies()) do
        owner_of[col.colony] = col.owner
    end
    for _, gid in ipairs(world.all("pop_group")) do
        slice.tick("economy/units.lua:233")
        local g = world.object("pop_group", gid)
        local colony = tonumber(world.field(g, "planet"))
        local owner = colony and owner_of[colony]
        local size = economy.pop_size(g)
        -- the colony's tables (its deficits) see the pop group before the month's resettlement
        -- too (the colony update comes before it in the monthly update; the budget after)
        local colony_size = size
        if economy.before_growth then
            colony_size = num(world.field(g, "size")) - num(world.field(g, "last_month_growth"))
        end
        if owner and (size > 0 or colony_size > 0) then
            economy.current_colony = colony
            local M = economy.modifiers("pop_group", gid)
            local key = world.field(g, "key")
            local species = world.object("species_db", tonumber(world.field(key, "species")))
            local category = world.field(key, "category")
            local passes = { { size, nil } }
            if colony_size ~= size then
                passes = { { size, "budget" }, { colony_size, "colony" } }
            end
            for _, pass in ipairs(passes) do
                local s = math.max(0, pass[1]) / economy.POP_BULK
                economy.add_to = pass[2]
                local function run(folder, name, label)
                    local list, d = templates(economy, folder, name)
                    for _, t in ipairs(list) do
                        economy.unit(owner, t, s, M, economy.ctx("pop_group", gid, d.file), label .. " #" .. gid)
                    end
                end
                if s > 0 then
                    if species then
                        run("common/species_archetypes", archetype_of(species), "archetype")
                        for _, trait in ipairs(species_traits(species)) do
                            run("common/traits", trait, "trait " .. trait)
                        end
                    end
                    if category then
                        run("common/pop_categories", category, "pop category " .. category)
                    end
                end
            end
            economy.add_to = nil
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- countries: the country type's table (country_base) and the country container's units (tables
-- with a category and no amounts: the category's add modifiers, e.g.
-- country_power_projection_influence_produces_add), the country's modifiers, in its scope

kind("countries", function(economy)
    local container = {}
    local coll = defs.get("common/country_container", "collection")
    for _, e in ipairs(coll and coll.block or {}) do
        if e.op and e.key and e.value.text == nil then
            local r = defs.field(e.value, "resources")
            if type(r) == "table" then
                container[#container + 1] = { name = e.key.text, t = economy.template(r, coll.file) }
            end
        end
    end
    for _, cid in ipairs(world.all("country")) do
        slice.tick("economy/units.lua:296")
        local c = world.object("country", cid)
        local M = economy.modifiers("country", cid)
        local ctype = world.field(c, "type")
        local list, d = templates(economy, "common/country_types", ctype)
        for _, t in ipairs(list) do
            economy.unit(cid, t, 1, M, economy.ctx("country", cid, d.file), "country type " .. tostring(ctype))
        end
        for _, u in ipairs(container) do
            economy.unit(cid, u.t, 1, M, economy.ctx("country", cid, coll.file), "container " .. u.name)
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- leaders: the leader class's table, the leader's modifiers, in its scope

kind("leaders", function(economy)
    for _, cid in ipairs(world.all("country")) do
        slice.tick("economy/units.lua:314")
        local c = world.object("country", cid)
        for _, lid in ipairs(ids(world.field(c, "owned_leaders"))) do
            local l = world.object("leader", lid)
            if l then
                local class = world.field(l, "class")
                local list, d = templates(economy, "common/leader_classes", class)
                if d == nil then miss("leader class " .. tostring(class)) end
                local M = economy.modifiers("leader", lid)
                for _, t in ipairs(list) do
                    economy.unit(cid, t, 1, M, economy.ctx("leader", lid, d.file), "leader " .. tostring(class) .. " #" .. lid)
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- fleets, ships, starbases: the owner of a fleet (the countries' fleets_manager.owned_fleets)

local function fleet_owners()
    local out = {}
    for _, cid in ipairs(world.all("country")) do
        slice.tick("economy/units.lua:336")
        local c = world.object("country", cid)
        local owned = world.path(c, "fleets_manager", "owned_fleets")
        for _, e in ipairs(type(owned) == "table" and owned or {}) do
            local f = e.op == nil and type(e) == "table" and world.field(e, "fleet")
            if f == nil and e.value and e.value.text == nil then f = world.field(e.value, "fleet") end
            if f then out[tonumber(f)] = cid end
        end
    end
    return out
end
units.fleet_owners = fleet_owners

local function ship_owner(owners, sid)
    local s = world.object("ship", sid)
    local f = s and tonumber(world.field(s, "fleet"))
    return f and owners[f]
end
units.ship_owner = ship_owner

-- deposits: orbital ones (station = <ship class>) produce for the owner of the planet's orbital
-- station; the others for the owner of the colony they are on
kind("deposits", function(economy)
    local owners = fleet_owners()
    for _, did in ipairs(world.all("deposit")) do
        slice.tick("economy/units.lua:360")
        local dep = world.object("deposit", did)
        local holder = world.field(dep, "deposit_holder")
        local htype, hid = world.field(holder, "type"), tonumber(world.field(holder, "id"))
        local dtype = world.field(dep, "type")
        local d = defs.get("common/deposits", dtype)
        if d == nil then
            miss("deposit " .. tostring(dtype))
        elseif htype == 0 and hid then
            local p = world.object("planet", hid)
            local owner
            if defs.field(d.block, "station") then
                -- the planet's orbital station: a fleet
                local station = tonumber(world.field(p, "shipclass_orbital_station"))
                owner = station and owners[station]
            elseif world.field(p, "colony") then
                owner = tonumber(world.field(p, "owner"))
            end
            if owner then
                local M = economy.modifiers("planet", hid)
                for _, b in ipairs(blocks_of(d, "resources")) do
                    economy.unit(owner, economy.template(b, d.file), 1, M, economy.ctx("planet", hid, d.file), "deposit " .. dtype .. " #" .. did)
                end
            end
        end
    end
end)

-- starbases: their modules' and buildings' tables, the starbase's modifiers, in its scope
kind("starbases", function(economy)
    local owners = fleet_owners()
    for _, sbid in ipairs(world.all("starbase")) do
        slice.tick("economy/units.lua:391")
        local sb = world.object("starbase", sbid)
        local owner = ship_owner(owners, tonumber(world.field(sb, "station")))
        if owner then
            local M = economy.modifiers("starbase", sbid)
            for _, part in ipairs({ { "modules", "common/starbase_modules" }, { "buildings", "common/starbase_buildings" } }) do
                local block = world.field(sb, part[1])
                for _, e in ipairs(type(block) == "table" and block or {}) do
                    if e.op and e.value.text then
                        local list, d = templates(economy, part[2], e.value.text)
                        if d == nil then miss(part[1] .. " " .. e.value.text) end
                        for _, t in ipairs(list) do
                            economy.unit(owner, t, 1, M, economy.ctx("starbase", sbid, d.file), part[1] .. " " .. e.value.text .. " #" .. sbid)
                        end
                    end
                end
            end
        end
    end
end)

-- ship designs: the component templates by key (common/component_templates: repeated
-- `*_component_template = { key = ... }`)
local component_index
local function components(economy)
    if component_index == nil then
        component_index = {}
        local db = require("simscript.db")
        local source = require("stellar.script.source")
        for _, file in ipairs(source.files(db.fs, "common/component_templates", "txt")) do
            local tree = source.parse(db.fs, file)
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.value.text == nil then
                    local key = defs.field(e.value, "key")
                    if key then
                        component_index[key] = { block = e.value, file = file }
                    end
                end
            end
        end
    end
    return component_index
end
units.components = components

local STATION_CLASSES = {
    shipclass_starbase = true, shipclass_mining_station = true, shipclass_research_station = true,
    shipclass_observation_station = true,
}

-- a fleet in orbit of its owner's (movement_manager.orbit.orbitable: a starbase of the owner, or
-- a planet of the owner or in a system the owner holds)
local function in_own_orbit(owners, fleet, owner)
    local o = world.path(fleet, "movement_manager", "orbit", "orbitable")
    if type(o) ~= "table" then return false end
    local sb = tonumber(world.field(o, "starbase"))
    if sb then
        return ship_owner(owners, tonumber(world.field(world.object("starbase", sb), "station"))) == owner
    end
    local pid = tonumber(world.field(o, "planet"))
    if pid then
        local p = world.object("planet", pid)
        if tonumber(world.field(p, "owner")) == owner then return true end
        local system = tonumber(world.path(p, "coordinate", "origin"))
        return system ~= nil and world.system_owner ~= nil and world.system_owner[system] == owner
    end
    return false
end
units.in_own_orbit = in_own_orbit

-- naval capacity: (NAVAL_CAPACITY_BASE + country_naval_cap_add) * (1 + country_naval_cap_mult);
-- the military ships of a country over it pay their upkeep times used / capacity
local function over_capacity(economy, cid)
    local c = world.object("country", cid)
    local used = tonumber(world.field(c, "used_naval_capacity")) or 0
    if used <= 0 then return 1 end
    local base = 50
    for _, d in pairs(defs.folder("common/defines")) do
        local v = defs.field(defs.field(d.block, "NCountry") or {}, "NAVAL_CAPACITY_BASE")
        if v then base = tonumber(v) or base end
    end
    local M = economy.modifiers("country", cid) or {}
    local cap = (base + (M.country_naval_cap_add or 0)) * (1 + (M.country_naval_cap_mult or 0))
    if cap <= 0 or used <= cap then return 1 end
    return used / cap
end
units.over_capacity = over_capacity

-- ships: the ship size's table and each component's (unless the size's components_add_to_cost =
-- no), the ship's modifiers, in its scope. A mobile ship in orbit of its owner pays its upkeep
-- times (1 + ship_orbit_upkeep_mult); a military ship, times the country's over-capacity factor.
kind("ships", function(economy)
    local owners = fleet_owners()
    local comps = components(economy)
    local over = {}
    for _, sid in ipairs(world.all("ship")) do
        slice.tick("economy/units.lua:486")
        local s = world.object("ship", sid)
        local owner = ship_owner(owners, sid)
        local fleet = world.object("fleet", tonumber(world.field(s, "fleet")))
        local impl = world.field(s, "ship_design_implementation")
        local design = world.object("ship_design", tonumber(world.field(impl, "design")))
        if owner and design then
            local stage = tonumber(world.field(impl, "growth_stage")) or 0
            local stages = world.field(design, "growth_stages")
            local g
            local i = 0
            for _, e in ipairs(type(stages) == "table" and stages or {}) do
                if e.op == nil and e.text == nil then
                    if i == stage then g = e end
                    i = i + 1
                elseif e.value and e.value.text == nil then
                    if i == stage then g = e.value end
                    i = i + 1
                end
            end
            if g then
                local M = economy.modifiers("ship", sid)
                local size = world.field(g, "ship_size")
                local list, d = templates(economy, "common/ship_sizes", size)
                if d == nil then miss("ship size " .. tostring(size)) end
                local station = STATION_CLASSES[world.field(fleet, "ship_class")]
                    or (d and defs.field(d.block, "is_space_station") == "yes")
                local factor = 1
                if not station and M and in_own_orbit(owners, fleet, owner) then
                    factor = 1 + (M.ship_orbit_upkeep_mult or 0)
                end
                if not station and d and defs.field(d.block, "class") == "shipclass_military" then
                    if over[owner] == nil then over[owner] = over_capacity(economy, owner) end
                    factor = factor * over[owner]
                end
                local opts = factor ~= 1 and { upkeep = factor } or nil
                for _, t in ipairs(list) do
                    economy.unit(owner, t, 1, M, economy.ctx("ship", sid, d.file), "ship size " .. tostring(size) .. " #" .. sid, nil, opts)
                end
                local function component(key)
                    local cd = comps[key]
                    if cd == nil then
                        miss("component " .. tostring(key))
                        return
                    end
                    for _, b in ipairs(blocks_of(cd, "resources")) do
                        economy.unit(owner, economy.template(b, cd.file), 1, M, economy.ctx("ship", sid, cd.file), "component " .. key .. " #" .. sid, nil, opts)
                    end
                end
                if not (d and defs.field(d.block, "components_add_to_cost") == "no") then
                    for _, sec in ipairs(world.fields(g, "section")) do
                        for _, comp in ipairs(world.fields(sec, "component")) do
                            component(world.field(comp, "template"))
                        end
                    end
                    for _, key in ipairs(world.fields(g, "required_component")) do
                        component(key)
                    end
                end
            end
        end
    end
end)

-- armies: the army type's table, the army's modifiers, in its scope
kind("armies", function(economy)
    for _, aid in ipairs(world.all("army")) do
        slice.tick("economy/units.lua:552")
        local a = world.object("army", aid)
        local owner = tonumber(world.field(a, "owner"))
        local atype = world.field(a, "type")
        if owner and atype then
            local list, d = templates(economy, "common/armies", atype)
            if d == nil then miss("army " .. tostring(atype)) end
            local M = economy.modifiers("army", aid)
            for _, t in ipairs(list) do
                economy.unit(owner, t, 1, M, economy.ctx("army", aid, d.file), "army " .. atype .. " #" .. aid)
            end
        end
    end
end)

-- diplomacy (common/diplomacy_economy): `once` units per country, `per_relation` units per
-- relation (this = the country, from = the other), each when its trigger holds; the country's
-- modifiers
kind("diplomacy", function(economy)
    local eval = require("simscript.eval")
    local function entries(name)
        local d = defs.get("common/diplomacy_economy", name)
        local out = {}
        for _, e in ipairs(d and d.block or {}) do
            if e.op and e.key and e.value.text == nil then
                local r = defs.field(e.value, "resources")
                if type(r) == "table" then
                    out[#out + 1] = { name = e.key.text, trigger = defs.field(e.value, "trigger"), t = economy.template(r, d.file), file = d.file }
                end
            end
        end
        return out
    end
    local once, per = entries("once"), entries("per_relation")
    for _, cid in ipairs(world.all("country")) do
        slice.tick("economy/units.lua:586")
        local M = economy.modifiers("country", cid)
        for _, u in ipairs(once) do
            local ctx = eval.new_ctx(eval.S("country", cid), nil, nil, u.file)
            if type(u.trigger) ~= "table" or eval.trigger(u.trigger, ctx) then
                economy.unit(cid, u.t, 1, M, ctx, "diplomacy " .. u.name)
            end
        end
        local rm = world.field(world.object("country", cid), "relations_manager")
        for _, r in ipairs(world.fields(rm, "relation")) do
            local other = type(r) == "table" and tonumber(world.field(r, "country"))
            if other and world.object("country", other) then
                for _, u in ipairs(per) do
                    local ctx = eval.new_ctx(eval.S("country", cid), eval.S("country", other), nil, u.file)
                    if type(u.trigger) ~= "table" or eval.trigger(u.trigger, ctx) then
                        economy.unit(cid, u.t, 1, M, ctx, "diplomacy " .. u.name .. " with " .. other)
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- after the units: the costs computed from the budgets

-- planetary deficits (NDefines.NEconomy.COLONY_DEFICIT_ECONOMIC_CATEGORY): every colony's local
-- deficit of a resource (what its own units use beyond what they produce) costs trade, times the
-- resource's deficit_trade_conversion_mult (common/strategic_resources; resources without one
-- cost nothing); the capital's deficit is first covered by the country's base income
-- (country_base) of the resource
kind("deficits", function(economy)
    local conv = {}
    for name, d in pairs(defs.folder("common/strategic_resources")) do
        local m = tonumber(defs.field(d.block, "deficit_trade_conversion_mult"))
        if m then conv[name] = math.abs(m) end
    end
    local cols = {}
    for col in pairs(economy.colony_tables) do cols[#cols + 1] = col end
    table.sort(cols)
    for _, col in ipairs(cols) do
        local ct = economy.colony_tables[col]
        local country = ct.country
        local capital = tonumber(world.field(world.object("country", country), "capital")) == col
        local base = capital and economy.budget_entry(country, "income", "country_base") or {}
        local cost = 0
        for r, m in pairs(conv) do
            local d = (ct.expenses[r] or 0) - (ct.income[r] or 0) - (base[r] or 0)
            if d > 0 then
                cost = cost + d * m
            end
        end
        if cost > 0 then
            economy.add(country, "expenses", economy.DEFICIT_CATEGORY, "trade", cost, "deficits of colony #" .. col)
        end
    end
end)

-- the trade policy (TRADE_POLICY_ECONOMIC_CATEGORY): the country's net trade of the month is
-- spent and converted by its trade_conversions (resource = rate), e.g. energy 0.5, trade 0.5
kind("trade_policy", function(economy)
    local category = economy.TRADE_POLICY_CATEGORY
    for _, cid in ipairs(world.all("country")) do
        slice.tick("economy/units.lua:648")
        local c = world.object("country", cid)
        local b = economy.budget_of(cid)
        local net = 0
        for cat, res in pairs(b.income) do
            if cat ~= category then net = net + (res.trade or 0) end
        end
        for cat, res in pairs(b.expenses) do
            if cat ~= category then net = net - (res.trade or 0) end
        end
        if net > 0 then
            local conversions = world.field(c, "trade_conversions")
            local any = false
            for _, e in ipairs(type(conversions) == "table" and conversions or {}) do
                if e.op and e.value.text then
                    any = true
                    economy.add(cid, "income", category, e.key.text, net * (tonumber(e.value.text) or 0), "trade conversion")
                end
            end
            if any then
                economy.add(cid, "expenses", category, "trade", net, "trade conversion")
            end
        end
    end
end)

return units
