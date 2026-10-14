-- engine/economy/script.lua : what the economy's resource tables ask of the script layer that it
-- does not answer yet (simscript/eval.lua, engine/interface.lua), installed only while the economy
-- evaluates its tables (script.with(f)) and taken out after, so the rest of the engine is not
-- changed. Each is a candidate for the script layer itself:
--
-- - links: `owner` and `planet` of a pop group (its `planet` field is its colony's id, not a
--   planet's), `species` of a pop group or leader, `colony` of a planet (the planet);
-- - triggers on pop groups: has_trait (the species' traits), is_enslaved, is_being_purged,
--   is_sapient, is_robot_pop_group, is_pop_category, is_unemployed, has_living_standard,
--   has_citizenship_type (the owner's species rights); leaders: is_heir, has_envoy_task;
--   starbases: has_starbase_building, is_scope_valid; ships: has_component.

local defs = require("engine.defs")
local world = require("engine.world")
local eval = require("simscript.eval")

local S = eval.S
local script = { used = {} }

local function count(name)
    script.used[name] = (script.used[name] or 0) + 1
end

-- ---------------------------------------------------------------------------------------------
-- the world, as the triggers need it

-- colony id -> planet id, kept between evaluations: a hit is checked against the planet's own
-- `colony` field, and a miss or a stale hit scans the planets again, at most once per
-- script.with (the scan had been redone on every script.with: 30% of the monthly rebuild)
local colony_planet = {}
local scanned = false
local function planet_of_colony(c)
    if c == nil then return nil end
    local pid = colony_planet[c]
    if pid ~= nil and not scanned then
        local p = world.object("planet", pid)
        if p ~= nil and tonumber(world.field(p, "colony")) == c then return pid end
    end
    if not scanned then
        colony_planet = {}
        for _, id in ipairs(world.all("planet")) do
            local col = world.field(world.object("planet", id), "colony")
            if col ~= nil then colony_planet[tonumber(col)] = id end
        end
        scanned = true
    end
    return colony_planet[c]
end
script.planet_of_colony = planet_of_colony

local function group(id) return world.object("pop_group", id) end

local function group_species(id)
    return tonumber(world.field(world.field(group(id), "key"), "species"))
end

local function group_planet(id)
    return planet_of_colony(tonumber(world.field(group(id), "planet")))
end

local function group_owner(id)
    local p = group_planet(id)
    return p and tonumber(world.field(world.object("planet", p), "owner"))
end

local function species_traits(sid)
    local set = {}
    local t = world.field(world.object("species_db", sid), "traits")
    for _, v in ipairs(world.fields(t, "trait")) do
        if type(v) == "string" then set[v] = true end
    end
    return set
end

local function archetype(sid)
    local class = world.field(world.object("species_db", sid), "class")
    local d = class and defs.get("common/species_classes", class)
    return d and defs.field(d.block, "archetype") or "BIOLOGICAL"
end

-- the species rights of a species in a country: its own entry, else the primary species', else
-- the default
local function rights(country, sid)
    local m = world.path(world.object("country", country), "modules", "standard_species_rights_module")
    if type(m) ~= "table" then return nil end
    for _, e in ipairs(world.blocks(world.field(m, "species_rights"))) do
        if tonumber(world.field(e, "species_index")) == sid then return e end
    end
    local primary = world.field(m, "primary")
    if primary and tonumber(world.field(primary, "species_index")) == sid then return primary end
    if archetype(sid) == "ROBOT" or archetype(sid) == "MACHINE" then
        local built = world.field(m, "built_species")
        if built then return built end
    end
    return world.field(m, "default")
end
script.rights = rights

local function group_right(id, key)
    local owner = group_owner(id)
    local r = owner and rights(owner, group_species(id))
    return r and world.field(r, key)
end

local function pop_category_def(id)
    local cat = world.field(world.field(group(id), "key"), "category")
    return cat, cat and defs.get("common/pop_categories", cat)
end

-- ---------------------------------------------------------------------------------------------
-- links and triggers

local LINKS, TRIG = eval.LINKS, eval.TRIG
local orig_links, orig_trig = {}, {}

local links = {}
local NO_ID = 4294967295
local function country_scope(o)
    o = tonumber(o)
    return (o and o ~= NO_ID and world.object("country", o)) and S("country", o) or nil
end
-- (eval's owner of a planet takes country 0 for no owner)
links.owner = function(cur, ctx)
    if cur.kind == "pop_group" then
        return country_scope(group_owner(cur.id))
    elseif cur.kind == "planet" then
        return country_scope(world.field(world.object("planet", cur.id), "owner"))
    elseif cur.kind == "army" then
        return country_scope(world.field(world.object("army", cur.id), "owner"))
    elseif cur.kind == "ship" or cur.kind == "starbase" or cur.kind == "fleet" then
        local fleet = cur.id
        if cur.kind == "starbase" then
            cur = { kind = "ship", id = tonumber(world.field(world.object("starbase", cur.id), "station")) }
        end
        if cur.kind == "ship" then
            fleet = tonumber(world.field(world.object("ship", cur.id), "fleet"))
        end
        return country_scope(fleet and world.fleet_owner and world.fleet_owner[fleet])
    end
    return orig_links.owner(cur, ctx)
end
links.controller = links.owner
links.planet = function(cur, ctx)
    if cur.kind == "pop_group" then
        local p = group_planet(cur.id)
        return p and S("planet", p) or nil
    end
    return orig_links.planet(cur, ctx)
end
links.colony = function(cur, ctx)
    if cur.kind == "planet" then return cur end
    if cur.kind == "pop_group" then return links.planet(cur, ctx) end
    return nil
end
links.species = function(cur)
    if cur.kind == "pop_group" then
        local s = group_species(cur.id)
        return s and S("species", s) or nil
    elseif cur.kind == "leader" then
        local s = tonumber(world.field(world.object("leader", cur.id), "species"))
        return s and S("species", s) or nil
    elseif cur.kind == "species" then
        return cur
    end
    return nil
end
links.owner_species = function(cur, ctx)
    local o = links.owner(cur, ctx)
    if cur.kind == "country" then o = cur end
    local s = o and tonumber(world.field(world.object("country", o.id), "founder_species_ref"))
    return s and S("species", s) or nil
end
links.founder_species = function(cur)
    if cur.kind ~= "country" then return nil end
    local s = tonumber(world.field(world.object("country", cur.id), "founder_species_ref"))
    return s and S("species", s) or nil
end

local function yes(e) return e.value.text ~= "no" end
local function param(e, key)
    if e.value.text then return e.value.text end
    for _, x in ipairs(e.value) do
        if x.op and x.key.text:lower() == key then return x.value.text end
    end
    return nil
end

local trig = {}
trig.has_trait = function(e, ctx, lk)
    local sc = ctx.this
    if sc.kind == "pop_group" or sc.kind == "species" then
        local sid = sc.kind == "pop_group" and group_species(sc.id) or sc.id
        return species_traits(sid)[e.value.text or ""] == true
    end
    return eval.property(lk)(e, ctx, lk)
end
-- a pop group's flags, from its species rights in its owner
local function citizenship(id)
    return group_right(id, "citizenship")
end
trig.is_enslaved = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false == yes(e) end
    return (citizenship(ctx.this.id) == "citizenship_slavery") == yes(e)
end
trig.is_being_purged = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false == yes(e) end
    return (citizenship(ctx.this.id) == "citizenship_purge") == yes(e)
end
trig.is_sapient = function(e, ctx)
    local sc = ctx.this
    local sid = sc.kind == "pop_group" and group_species(sc.id) or (sc.kind == "species" and sc.id)
    if not sid then return false == yes(e) end
    return (archetype(sid) ~= "PRESAPIENT") == yes(e)
end
trig.is_robot_pop_group = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false == yes(e) end
    local a = archetype(group_species(ctx.this.id))
    return (a == "ROBOT" or a == "MACHINE") == yes(e)
end
trig.is_pop_category = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false end
    return (pop_category_def(ctx.this.id)) == e.value.text
end
trig.is_unemployed = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false == yes(e) end
    local _, d = pop_category_def(ctx.this.id)
    local u = d and defs.field(d.block, "is_unemployment_job") == "yes"
    return (u == true) == yes(e)
end
trig.has_living_standard = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false end
    return group_right(ctx.this.id, "living_standard") == param(e, "type")
end
trig.has_citizenship_type = function(e, ctx)
    if ctx.this.kind ~= "pop_group" then return false end
    return citizenship(ctx.this.id) == param(e, "type")
end
-- leaders: the ruler is the country's `ruler`; the heir its `heir`, or (the save writes none) the
-- leader with trait_imperial_heir who is not the ruler
local function leader_country(id)
    local o = tonumber(world.field(world.object("leader", id), "country"))
    return o and world.object("country", o)
end
local function is_ruler(id)
    local c = leader_country(id)
    return c ~= nil and tonumber(world.field(c, "ruler")) == id
end
trig.is_ruler = function(e, ctx)
    if ctx.this.kind ~= "leader" then return eval.property("is_ruler")(e, ctx, "is_ruler") end
    return is_ruler(ctx.this.id) == yes(e)
end
trig.is_heir = function(e, ctx)
    if ctx.this.kind ~= "leader" then return false == yes(e) end
    local c = leader_country(ctx.this.id)
    local heir = c and tonumber(world.field(c, "heir"))
    local r
    if heir then
        r = heir == ctx.this.id
    else
        local traits = world.fields(world.object("leader", ctx.this.id), "traits")
        r = false
        for _, t in ipairs(traits) do
            if t == "trait_imperial_heir" then r = not is_ruler(ctx.this.id) end
        end
    end
    return r == yes(e)
end
trig.is_councilor = function(e, ctx)
    if ctx.this.kind ~= "leader" then return false == yes(e) end
    local cp = world.stores["council_positions"] or {}
    local r = false
    for _, p in pairs(cp) do
        if tonumber(world.field(p, "leader")) == ctx.this.id then r = true break end
    end
    return r == yes(e)
end
trig.has_envoy_task = function(e, ctx)
    if ctx.this.kind ~= "leader" then return false end
    local task = world.path(world.object("leader", ctx.this.id), "location", "assignment")
    local want = param(e, "task")
    return want ~= nil and task == want
end
-- starbases
trig.has_starbase_building = function(e, ctx)
    if ctx.this.kind ~= "starbase" then return false end
    local b = world.field(world.object("starbase", ctx.this.id), "buildings")
    for _, x in ipairs(type(b) == "table" and b or {}) do
        if x.op and x.value.text == e.value.text then return true end
    end
    return false
end
trig.is_scope_valid = function(e, ctx)
    return (ctx.this ~= nil and ctx.this ~= eval.NONE) == yes(e)
end

-- planets
local function planet_class_def(pid)
    local class = world.field(world.object("planet", pid), "planet_class")
    return class and defs.get("common/planet_classes", class), class
end
local function planet_colony(pid)
    return world.object("colony", tonumber(world.field(world.object("planet", pid), "colony")))
end
trig.has_climate = function(e, ctx)
    if ctx.this.kind ~= "planet" then return false end
    local d = planet_class_def(ctx.this.id)
    return d ~= nil and defs.field(d.block, "climate") == e.value.text
end
trig.is_ringworld = function(e, ctx)
    if ctx.this.kind ~= "planet" then return false == yes(e) end
    local d, class = planet_class_def(ctx.this.id)
    local r = (d and defs.field(d.block, "ringworld") == "yes") or (class and class:find("ringworld") ~= nil)
    return (r and true or false) == yes(e)
end
trig.has_active_building = function(e, ctx)
    if ctx.this.kind ~= "planet" then return false end
    local c = planet_colony(ctx.this.id)
    for _, bid in ipairs(world.list(world.field(c, "buildings_cache"))) do
        if world.field(world.object("buildings", tonumber(bid)), "type") == e.value.text then return true end
    end
    return false
end
-- num_zones = N, or num_zones = { type = zone_x value >= N }
trig.num_zones = function(e, ctx)
    if ctx.this.kind ~= "planet" then return false end
    local ztype, op, want = nil, e.op, nil
    if e.value.text then
        want = eval.value(e.value, ctx, e)
    else
        for _, x in ipairs(e.value) do
            if x.op then
                local k = x.key.text:lower()
                if k == "type" then ztype = x.value.text
                elseif k == "value" then op = x.op; want = eval.value(x.value, ctx, x) end
            end
        end
    end
    local c = planet_colony(ctx.this.id)
    local n = 0
    for _, did in ipairs(world.list(world.field(c, "districts"))) do
        for _, z in ipairs(world.list(world.field(world.object("districts", tonumber(did)), "zones"))) do
            local zid = tonumber(z)
            if zid ~= NO_ID and (ztype == nil or world.field(world.object("zones", zid), "type") == ztype) then
                n = n + 1
            end
        end
    end
    return eval.compare(n, op, want or 0)
end
-- species (of a species, pop group or leader scope)
local function scope_species(sc)
    if sc.kind == "species" then return sc.id end
    if sc.kind == "pop_group" then return group_species(sc.id) end
    if sc.kind == "leader" then return tonumber(world.field(world.object("leader", sc.id), "species")) end
    return nil
end
trig.is_robotic = function(e, ctx)
    local sid = scope_species(ctx.this)
    if not sid then return false == yes(e) end
    local d = defs.get("common/species_archetypes", archetype(sid))
    return ((d and defs.field(d.block, "robotic") == "yes") or false) == yes(e)
end
trig.is_archetype = function(e, ctx)
    local sid = scope_species(ctx.this)
    return sid ~= nil and archetype(sid) == e.value.text
end
-- any scope
local SCOPE_TYPES = { pop_group = "pop_group", planet = "planet", country = "country", ship = "ship", fleet = "fleet",
    leader = "leader", starbase = "starbase", army = "army", species = "species" }
trig.is_scope_type = function(e, ctx)
    return SCOPE_TYPES[ctx.this.kind] == e.value.text
end
-- ships: a component of the ship's design
trig.has_component = function(e, ctx)
    if ctx.this.kind ~= "ship" then return false end
    local s = world.object("ship", ctx.this.id)
    local impl = world.field(s, "ship_design_implementation")
    local design = world.object("ship_design", tonumber(world.field(impl, "design")))
    local want = e.value.text
    for _, g in ipairs(world.blocks(world.field(design, "growth_stages"))) do
        for _, sec in ipairs(world.fields(g, "section")) do
            for _, comp in ipairs(world.fields(sec, "component")) do
                if world.field(comp, "template") == want then return true end
            end
        end
        for _, key in ipairs(world.fields(g, "required_component")) do
            if key == want then return true end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- diplomacy: a country's relations (relations_manager.relation = { owner country <flag>=yes })

local function relation(country, other)
    local rm = world.field(world.object("country", country), "relations_manager")
    for _, r in ipairs(world.fields(rm, "relation")) do
        if type(r) == "table" and tonumber(world.field(r, "country")) == other then return r end
    end
    return nil
end
script.relation = relation

local function other_of(e, ctx)
    local found, sc = eval.resolve(e.value.text or "", ctx, e)
    return found and sc and sc.kind == "country" and sc.id or nil
end

local RELATION_FLAGS = {
    has_rival = "is_rival", has_commercial_pact = "commercial_pact", has_research_agreement = "research_agreement",
    has_diplo_migration_treaty = "migration_access", has_migration_access = "migration_access",
    has_embassy = "embassy", has_closed_borders = "closed_borders", has_defensive_pact = "defensive_pact",
    has_non_aggression_pact = "non_aggression_pact", is_guaranteeing = "guarantee",
}
for trig_name, flag in pairs(RELATION_FLAGS) do
    trig[trig_name] = function(e, ctx)
        if ctx.this.kind ~= "country" then return false end
        local other = other_of(e, ctx)
        local r = other and relation(ctx.this.id, other)
        return r ~= nil and world.field(r, flag) == "yes"
    end
end

-- a country's ethics: `ethos = { ethics = { "x" ... } }` in a 4.5 save
local function country_has_ethic(cid, ethic)
    local ethos = world.field(world.object("country", cid), "ethos")
    for _, v in ipairs(world.list(world.field(ethos, "ethics"))) do
        if v == ethic then return true end
    end
    for _, v in ipairs(world.fields(ethos, "ethic")) do
        if v == ethic then return true end
    end
    return false
end
trig.has_ethic = function(e, ctx, lk)
    if ctx.this.kind ~= "country" then return eval.property(lk)(e, ctx, lk) end
    return country_has_ethic(ctx.this.id, e.value.text)
end
trig.is_gestalt = function(e, ctx, lk)
    if ctx.this.kind ~= "country" then return eval.property(lk)(e, ctx, lk) end
    return country_has_ethic(ctx.this.id, "ethic_gestalt_consciousness") == yes(e)
end

-- a country's traditions (adopted, the save's `traditions` list)
trig.has_active_tradition = function(e, ctx)
    if ctx.this.kind ~= "country" then return false end
    for _, v in ipairs(world.list(world.field(world.object("country", ctx.this.id), "traditions"))) do
        if v == e.value.text then return true end
    end
    return false
end

-- (eval reads has_policy_flag as a script flag, has_<x>_flag)
trig.has_policy_flag = function(e, ctx)
    local sc = ctx.this
    if sc.kind ~= "country" then return false end
    for _, v in ipairs(world.list(world.field(world.object("country", sc.id), "policy_flags"))) do
        if v == e.value.text then return true end
    end
    return false
end

-- envoys: a leader of the country assigned to improve or harm relations with the other
local function envoy_task(country, other, task)
    for _, lid in ipairs(world.list(world.field(world.object("country", country), "owned_leaders"))) do
        local loc = world.field(world.object("leader", tonumber(lid)), "location")
        if type(loc) == "table" and world.field(loc, "assignment") == task and tonumber(world.field(loc, "id")) == other then
            return true
        end
    end
    return false
end
trig.is_improving_relations_with = function(e, ctx)
    local other = ctx.this.kind == "country" and other_of(e, ctx)
    return other and envoy_task(ctx.this.id, other, "improve_relations") or false
end
trig.is_harming_relations_with = function(e, ctx)
    local other = ctx.this.kind == "country" and other_of(e, ctx)
    return other and envoy_task(ctx.this.id, other, "harm_relations") or false
end

-- federations: the federation whose members list the country
local function federation_of(country)
    for fid, f in pairs(world.stores["federation"] or {}) do
        for _, m in ipairs(world.list(world.field(f, "members"))) do
            if tonumber(m) == country then return fid end
        end
    end
    return nil
end
trig.has_federation = function(e, ctx)
    if ctx.this.kind ~= "country" then return false == yes(e) end
    return (federation_of(ctx.this.id) ~= nil) == yes(e)
end
links.federation = function(cur)
    if cur.kind ~= "country" then return nil end
    local f = federation_of(cur.id)
    return f and S("federation", f) or nil
end
trig.has_federation_perk = function(e, ctx)
    if ctx.this.kind ~= "federation" then return false end
    local p = world.path(world.object("federation", ctx.this.id), "federation_progression", "perks")
    for _, v in ipairs(world.list(p)) do
        if v == e.value.text then return true end
    end
    return false
end
trig.has_federation_law = function(e, ctx)
    if ctx.this.kind ~= "federation" then return false end
    local laws = world.path(world.object("federation", ctx.this.id), "federation_progression", "laws")
    for _, x in ipairs(type(laws) == "table" and laws or {}) do
        if x.op and x.value.text == e.value.text then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- script values: `value:name|PARAM|@var|`: the caller's scripted variables are resolved where the
-- call is written (the game substitutes them in the caller's file), and the
-- `complex_trigger_modifier` op of a value's block (ship_size_cost_resource_percent) is evaluated

local db = require("simscript.db")

local function var_of(name, file)
    local fv = db.filevars(file)
    local v = fv and fv[name]
    if v == nil then v = db.globalvars[name] end
    return v
end

-- the ship size definition of a ship (its design's growth stage)
local function ship_size_def(sid)
    local s = world.object("ship", sid)
    local impl = world.field(s, "ship_design_implementation")
    local design = world.object("ship_design", tonumber(world.field(impl, "design")))
    local stage = tonumber(world.field(impl, "growth_stage")) or 0
    local g = world.blocks(world.field(design, "growth_stages"))[stage + 1]
    local size = g and world.field(g, "ship_size")
    return size and defs.get("common/ship_sizes", size)
end
script.ship_size_def = ship_size_def

trig.is_space_fauna = function(e, ctx)
    local sc = ctx.this
    local r = false
    if sc.kind == "ship" then
        local d = ship_size_def(sc.id)
        r = d ~= nil and defs.field(d.block, "is_space_fauna_ship") == "yes"
    elseif sc.kind == "fleet" then
        for _, sid in ipairs(world.list(world.field(world.object("fleet", sc.id), "ships"))) do
            local d = ship_size_def(tonumber(sid))
            if d and defs.field(d.block, "is_space_fauna_ship") == "yes" then r = true break end
        end
    end
    return r == yes(e)
end

-- the cost table of a ship's size: { [res] = amount }, and its total
local function ship_size_cost(sid)
    local d = ship_size_def(sid)
    if not d then return {}, 0 end
    local economy = require("engine.economy")
    local units = require("engine.economy.units")
    local cost, total = {}, 0
    for _, b in ipairs(units.blocks_of(d, "resources")) do
        local t = economy.template(b, d.file)
        local ctx = eval.new_ctx(S("ship", sid), nil, nil, d.file)
        for _, blk in ipairs(t.cost) do
            if blk.trigger == nil or eval.trigger(blk.trigger, ctx) then
                local m = blk.mult and economy.value_of(blk.mult, ctx) or 1
                for _, rv in ipairs(blk.values) do
                    local v = economy.value_of(rv[2], ctx) * m
                    cost[rv[1]] = (cost[rv[1]] or 0) + v
                    total = total + v
                end
            end
        end
    end
    return cost, total
end

local COMPLEX = {
    ship_size_cost_resource_percent = function(params, ctx)
        if ctx.this.kind ~= "ship" then return nil end
        local cost, total = ship_size_cost(ctx.this.id)
        if total == 0 then return 0 end
        return (cost[params.resource] or 0) / total
    end,
}

local function complex_op(acc, e, ctx)
    local name, mode, params, potential = nil, "mult", {}, nil
    for _, x in ipairs(e.value) do
        if x.op then
            local k = x.key.text:lower()
            if k == "trigger" then name = x.value.text
            elseif k == "mode" then mode = x.value.text
            elseif k == "potential" then potential = x.value
            elseif k == "parameters" and x.value.text == nil then
                for _, p in ipairs(x.value) do
                    if p.op then params[p.key.text] = p.value.text end
                end
            end
        end
    end
    if potential and not eval.trigger(potential, ctx) then return acc end
    local f = name and COMPLEX[name]
    local v = f and f(params, ctx)
    if v == nil then
        count("complex_trigger_modifier " .. tostring(name) .. " (not evaluated)")
        return acc
    end
    if mode == "add" then return acc + v end
    return acc * v
end

-- a value block with complex_trigger_modifier ops: each op in turn, the others through eval
local function value_with_complex(block, ctx)
    local acc = 0
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text:lower()
            if k == "complex_trigger_modifier" and e.value.text == nil then
                acc = complex_op(acc, e, ctx)
            else
                acc = eval.value_block({ { key = { text = "base" }, op = "=", value = { text = tostring(acc) } }, e }, ctx)
            end
        end
    end
    return acc
end

local function has_complex(block)
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text:lower() == "complex_trigger_modifier" then return true end
    end
    return false
end

local orig_script_value
local function script_value(spec, ctx, e)
    -- the caller's @variables
    spec = spec:gsub("|@([%w_]+)", function(name)
        local v = var_of(name, ctx.file)
        return v ~= nil and ("|" .. v) or ("|@" .. name)
    end)
    local parts = {}
    for p in (spec .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
    local name = parts[1]
    local def = db.script_values[name]
    if def then
        local args = {}
        for i = 2, #parts - 1, 2 do
            if parts[i] ~= "" then args[#args + 1] = { parts[i], parts[i + 1] or "" } end
        end
        local block = db.instance("value", def, name, args)
        if block and has_complex(block) then
            count("script value " .. name)
            local c2 = eval.push(ctx, ctx.this)
            c2.prev, c2.prevprev, c2.file = ctx.prev, ctx.prevprev, def.file
            return value_with_complex(block, c2)
        end
    end
    return orig_script_value(spec, ctx, e)
end

local installed = 0

-- the counting wrappers, made once (links and trig are complete when the module has loaded)
local wrapped_links, wrapped_trig

local function install()
    if wrapped_links == nil then
        wrapped_links, wrapped_trig = {}, {}
        for k, f in pairs(links) do
            wrapped_links[k] = function(...) count("link " .. k) return f(...) end
        end
        for k, f in pairs(trig) do
            wrapped_trig[k] = function(...) count("trigger " .. k) return f(...) end
        end
    end
    for k, w in pairs(wrapped_links) do
        orig_links[k] = LINKS[k]
        LINKS[k] = w
    end
    for k, w in pairs(wrapped_trig) do
        orig_trig[k] = TRIG[k]
        TRIG[k] = w
    end
    orig_script_value = eval.script_value
    eval.script_value = script_value
end

local function uninstall()
    for k in pairs(links) do LINKS[k] = orig_links[k] end
    for k in pairs(trig) do TRIG[k] = orig_trig[k] end
    eval.script_value = orig_script_value
end

-- script.with(f, ...) -> f's results, with the economy's links and triggers in place
function script.with(f, ...)
    if installed > 0 then
        return f(...)
    end
    installed = installed + 1
    scanned = false
    install()
    local res = { pcall(f, ...) }
    uninstall()
    installed = installed - 1
    if not res[1] then
        error(res[2], 0)
    end
    return unpack(res, 2)
end

return script
