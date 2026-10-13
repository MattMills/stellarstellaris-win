-- engine/interface.lua : `E`, what the script layer (simscript/eval.lua, events.lua) reads of the
-- engine and sends to it, over the world loaded from a save (engine.world) and the definitions of
-- the vanilla files (engine.defs). Every read is of the save's own fields (the game's
-- WriteMembers names); what nothing reads yet is counted (E.unread), not invented.
--
-- Engine effects (create_ship, add_building, add_resource, ...) are queued (E.push) and applied at
-- the barriers (E.flush) by the engine's systems (engine.systems); an effect no system applies yet
-- is counted by keyword.

local world = require("engine.world")

E = E or {}

local stats = {
    unread = {},        -- "kind.field" -> count of reads with no source in the save yet
    unapplied = {},     -- effect keyword -> count
    applied = 0,
}
E.stats = stats

local function unread(key)
    stats.unread[key] = (stats.unread[key] or 0) + 1
end

local function obj(kind, id)
    return world.object(kind, id)
end

local function ids_of_list(block)
    local out = {}
    for _, t in ipairs(world.list(block)) do
        out[#out + 1] = tonumber(t)
    end
    return out
end

-- the values of every `key = value` statement of a block, as a set
local function values_set(block, key)
    local set = {}
    for _, v in ipairs(world.fields(block, key)) do
        if type(v) == "string" then
            set[v] = true
        end
    end
    return set
end

-- ---------------------------------------------------------------------------------------------
-- time and randomness: the platform's (sim/src: the date, the game's RNG)

E.date = function() return RUST.date() end
E.rand = function() return RUST.rand() end

-- ---------------------------------------------------------------------------------------------
-- the objects

E.countries = function()
    return world.all("country")
end

-- a country's planets (its `owned_planets`: colony ids, given as their planets), or every
-- owned planet
E.colonies = function(owner)
    if owner then
        local out = {}
        for _, c in ipairs(ids_of_list(world.field(obj("country", owner), "owned_planets"))) do
            out[#out + 1] = world.colony_planet[c]
        end
        return out
    end
    local out = {}
    for o, list in pairs(world.planets_of) do
        for _, id in ipairs(list) do
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

E.pop_groups = function(planet)
    return world.pop_groups_of[planet] or {}
end

E.leaders = function(country)
    return ids_of_list(world.field(obj("country", country), "owned_leaders"))
end

-- ---------------------------------------------------------------------------------------------
-- fields: E.get(kind, id, name). A name the save has is read as it is; the others are derived
-- from the save's fields here (a trigger's name, as the script layer asks for it)

local function government(c, key)
    return world.field(world.field(c, "government"), key)
end
-- `ethos = { ethics = { "ethic_x" ... } }` (4.5)
local function has_ethic(c, ethic)
    for _, v in ipairs(world.list(world.field(world.field(c, "ethos"), "ethics"))) do
        if v == ethic then return true end
    end
    return false
end

local DERIVED = {
    country = {
        is_country_type = function(c) return world.field(c, "type") end,
        is_ai = function(c)
            local ai = world.field(c, "ai")
            return (type(ai) == "table" and world.field(ai, "initialized") == "yes") and "yes" or "no"
        end,
        is_gestalt = function(c) return has_ethic(c, "ethic_gestalt_consciousness") and "yes" or "no" end,
        is_machine_empire = function(c) return government(c, "authority") == "auth_machine_intelligence" and "yes" or "no" end,
        is_hive_empire = function(c) return government(c, "authority") == "auth_hive_mind" and "yes" or "no" end,
        is_megacorp = function(c) return government(c, "authority") == "auth_corporate" and "yes" or "no" end,
        num_colonies = function(c) return #world.list(world.field(c, "owned_planets")) end,
        num_leaders = function(c) return #world.list(world.field(c, "owned_leaders")) end,
        num_pops = function(c) return world.field(c, "num_sapient_pops") end,
        last_increased_tech = function(c) return world.path(c, "tech_status", "last_increased_tech") end,
        -- the capital is a colony id: its planet
        capital = function(c)
            local col = tonumber(world.field(c, "capital"))
            return col and world.colony_planet[col]
        end,
    },
    planet = {
        is_planet_class = function(p) return world.field(p, "planet_class") end,
        has_owner = function(p) return world.field(p, "owner") ~= nil and "yes" or "no" end,
        is_capital = function(p, id)
            local owner = world.field(p, "owner")
            local col = world.planet_colony[id]
            return (owner and col and world.field(obj("country", owner), "capital") == col) and "yes" or "no"
        end,
        is_colony = function(p, id) return (world.planet_colony[id] and "yes") or "no" end,
        num_pops = function(p) return world.field(p, "num_sapient_pops") end,
    },
    megastructure = {
        is_megastructure_type = function(m) return world.field(m, "type") end,
    },
    leader = {
        leader_class = function(l) return world.field(l, "class") end,
        is_leader_tier = function(l) return world.field(l, "tier") end,
        -- hidden: a bit of the saved leader_flags (CLeader::_LeaderFlags); taken as bit 9 (512),
        -- the bit only the gestalt council nodes have in the 2210 saves (inferred from the leader
        -- cap the game applies, not read from the code)
        is_hidden = function(l)
            local f = tonumber(world.field(l, "leader_flags")) or 0
            return (math.floor(f / 512) % 2 == 1) and "yes" or "no"
        end,
        has_base_skill = function(l) return tonumber(world.field(l, "level")) end,
        is_ruler = function(l, id)
            local c = obj("country", tonumber(world.field(l, "country")))
            return (c and tonumber(world.field(c, "ruler")) == id) and "yes" or "no"
        end,
    },
    pop_group = {
        -- its `planet` is its colony's id: the colony's planet
        colony = function(g)
            local col = tonumber(world.field(g, "planet"))
            return col and world.colony_planet[col]
        end,
    },
}

E.get = function(kind, id, name)
    local o = obj(kind, id)
    if o == nil then
        return nil
    end
    local d = DERIVED[kind] and DERIVED[kind][name]
    if d then
        return d(o, id)
    end
    local v = world.field(o, name)
    if v == nil or type(v) == "table" then
        unread(kind .. "." .. name)
        return nil
    end
    return v
end

-- sets: E.has(kind, id, set, member), `set` the trigger's name (has_ethic, has_civic, ...)
local SETS = {
    country = {
        has_ethic = function(c, m) return has_ethic(c, m) end,
        has_civic = function(c, m)
            for _, v in ipairs(world.list(world.field(world.field(c, "government"), "civics"))) do
                if v == m then return true end
            end
            return false
        end,
        has_authority = function(c, m) return government(c, "authority") == m end,
        has_origin = function(c, m) return government(c, "origin") == m end,
        has_government = function(c, m) return government(c, "type") == m end,
        tech = function(c, m) return values_set(world.field(c, "tech_status"), "technology")[m] == true end,
        has_policy_flag = function(c, m)
            for _, v in ipairs(world.list(world.field(c, "policy_flags"))) do
                if v == m then return true end
            end
            return false
        end,
        has_tradition = function(c, m)
            for _, v in ipairs(world.list(world.field(c, "traditions"))) do
                if v == m then return true end
            end
            return false
        end,
        has_ascension_perk = function(c, m)
            for _, v in ipairs(world.list(world.field(c, "ascension_perks"))) do
                if v == m then return true end
            end
            return false
        end,
    },
}
SETS.country.has_valid_civic = SETS.country.has_civic
-- a leader's traits are repeated `traits = "x"`; a species' are `traits = { trait = "x" ... }`
SETS.leader = {
    has_trait = function(l, m) return values_set(l, "traits")[m] == true end,
}
-- a pop group's traits are its species'
local function species_has_trait(sp, m)
    return values_set(world.field(sp, "traits"), "trait")[m] == true
end
SETS.pop_group = {
    has_trait = function(g, m)
        local key = world.field(g, "key")
        local sp = type(key) == "table" and world.object("species", tonumber(world.field(key, "species")))
        return sp ~= nil and sp ~= false and species_has_trait(sp, m)
    end,
}
SETS.species = {
    has_trait = function(s, m) return values_set(world.field(s, "traits"), "trait")[m] == true end,
}

-- ---------------------------------------------------------------------------------------------
-- species: an object's species, and what the species triggers read (class -> archetype in
-- common/species_classes and common/species_archetypes; trait properties in common/traits)

-- E.species_of(kind, id) -> the species id of a scope (`species` link): a pop group's
-- key.species, a leader's or army's species, a country's founder species (its main species), a
-- species itself
E.species_of = function(kind, id)
    if kind == "species" then
        return id
    end
    local o = obj(kind, id)
    if o == nil then
        return nil
    end
    if kind == "pop_group" then
        local key = world.field(o, "key")
        return type(key) == "table" and tonumber(world.field(key, "species")) or nil
    elseif kind == "leader" or kind == "army" then
        return tonumber(world.field(o, "species"))
    elseif kind == "country" then
        return tonumber(world.field(o, "founder_species_ref"))
    end
    return nil
end
-- E.species_right(country, species, key) -> the country's right `key` (citizenship,
-- population_control, ...) for a species: its block of the species rights module (matched by
-- species_index), else the module's default
E.species_right = function(country, species, key)
    local c = obj("country", country)
    local module = c and world.path(c, "modules", "standard_species_rights_module")
    if type(module) ~= "table" then
        return nil
    end
    local found
    for _, e in ipairs(module) do
        if e.op and e.value.text == nil then
            if tonumber(world.field(e.value, "species_index")) == species then
                found = e.value
            end
            for _, b in ipairs(world.blocks(e.value)) do
                if tonumber(world.field(b, "species_index")) == species then
                    found = b
                end
            end
        end
    end
    found = found or world.field(module, "default")
    return type(found) == "table" and world.field(found, key) or nil
end
-- E.founder_species(country) -> species id (`founder_species`)
E.founder_species = function(country)
    local c = obj("country", country)
    return c and tonumber(world.field(c, "founder_species_ref")) or nil
end

local function defs()
    return require("engine.defs")
end
local function archetype_of(sp)
    local class = world.field(sp, "class")
    local d = class and defs().get("common/species_classes", class)
    return d and defs().field(d.block, "archetype") or "BIOLOGICAL"
end
local function trait_property(sp, key, want)
    for name in pairs(values_set(world.field(sp, "traits"), "trait")) do
        local d = defs().get("common/traits", name)
        if d and defs().field(d.block, key) == want then
            return true
        end
    end
    return false
end
DERIVED.species = {
    is_archetype = function(sp) return archetype_of(sp) end,
    is_species_class = function(sp) return world.field(sp, "class") end,
    is_robotic = function(sp)
        local d = defs().get("common/species_archetypes", archetype_of(sp))
        return (d and defs().field(d.block, "robotic") == "yes") and "yes" or "no"
    end,
    is_sapient = function(sp)
        if archetype_of(sp) == "PRESAPIENT" or trait_property(sp, "sapient", "no") then
            return "no"
        end
        return "yes"
    end,
    is_infertile = function(sp) return trait_property(sp, "infertile", "yes") and "yes" or "no" end,
}
DERIVED.species.is_robotic_species = DERIVED.species.is_robotic
-- a pop group (or leader) answers its species' properties
for _, kind in ipairs({ "pop_group", "leader" }) do
    DERIVED[kind] = DERIVED[kind] or {}
    for _, prop in ipairs({ "is_sapient", "is_infertile", "is_robotic", "is_robotic_species", "is_archetype" }) do
        DERIVED[kind][prop] = DERIVED[kind][prop] or function(_, id)
            local sid = E.species_of(kind, id)
            local sp = sid and obj("species", sid)
            return sp and DERIVED.species[prop](sp, sid) or nil
        end
    end
end
-- is_species_class: the species' class (a pop group's, a country's founder species')
local function species_class_is(kind)
    return function(o, m, id)
        local sid = E.species_of(kind, id)
        local sp = sid and obj("species", sid)
        return sp ~= nil and world.field(sp, "class") == m
    end
end
SETS.species.is_species_class = function(sp, m) return world.field(sp, "class") == m end
SETS.pop_group.is_species_class = species_class_is("pop_group")
SETS.country = SETS.country or {}
SETS.country.is_species_class = species_class_is("country")

E.has = function(kind, id, set, member)
    local o = obj(kind, id)
    if o == nil then
        return false
    end
    local f = SETS[kind] and SETS[kind][set]
    if f then
        return f(o, member, id) and true or false
    end
    unread(kind .. "." .. set)
    return false
end

-- a country's stockpile of a resource
E.resource = function(country, res)
    return world.path(obj("country", country), "modules", "standard_economy_module", "resources", res) or 0
end

E.income = function(country, res)
    unread("country.income")
    return nil
end

-- modifiers: the modifier graph (lua/stellar/graph) once it is fed from the world; until then 0
-- a modifier's value on a scope's node, from the engine's modifier source (the economy's: the
-- world's graph or the game's capture)
E.modifier = function(kind, id, name)
    local economy = package.loaded["engine.economy"]
    if economy and economy.has_modifier_source and economy.has_modifier_source() then
        local m = economy.modifiers(kind, id)
        return m and m[name] or 0
    end
    unread("modifier")
    return 0
end

-- E.neighbors(country) -> ids: the countries its relations mark as bordering (`relations_manager =
-- { relation = { country = x borders = yes ... } }`)
E.neighbors = function(country)
    local c = obj("country", country)
    local out = {}
    local rm = c and world.field(c, "relations_manager")
    for _, r in ipairs(world.fields(rm, "relation")) do
        if type(r) == "table" and world.field(r, "borders") == "yes" then
            local other = tonumber(world.field(r, "country"))
            if other then out[#out + 1] = other end
        end
    end
    return out
end
-- E.megastructures(country) -> ids of the megastructures it owns
E.megastructures = function(country)
    local out = {}
    for _, id in ipairs(world.all("megastructure")) do
        local m = obj("megastructure", id)
        if m and tonumber(world.field(m, "owner")) == country then
            out[#out + 1] = id
        end
    end
    return out
end
-- E.has_deficit(kind, id, resource): a country with none of the resource left and a month's balance
-- below zero (the budget the economy computed, else the save's)
E.has_deficit = function(kind, id, res)
    if kind ~= "country" then
        return false
    end
    local stock = E.resource(id, res)
    if stock == nil or stock > 0 then
        return false
    end
    local economy = package.loaded["engine.economy"]
    local b = economy and ((economy.last_month and economy.last_month[id]) or economy.save_budget(id))
    if not b then
        return false
    end
    local sum = 0
    for side, sign in pairs({ income = 1, expenses = -1 }) do
        for _, t in pairs(b[side] or {}) do
            sum = sum + sign * (t[res] or 0)
        end
    end
    return sum < 0
end

-- fleet power: a fleet's military_power; a country's, the sum over the fleets it owns
E.fleet_power = function(kind, id)
    if kind == "fleet" then
        local f = obj("fleet", id)
        return f and tonumber(world.field(f, "military_power")) or 0
    elseif kind == "country" then
        local sum = 0
        for fid, owner in pairs(world.fleet_owner or {}) do
            if owner == id then
                local f = obj("fleet", fid)
                sum = sum + (f and tonumber(world.field(f, "military_power")) or 0)
            end
        end
        return sum
    end
    return 0
end

-- a timed modifier (`timed_modifier = { items = { { modifier = x days = n } } }`)
E.has_modifier = function(kind, id, source)
    local o = obj(kind, id)
    local items = world.field(world.field(o, "timed_modifier"), "items")
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" and world.field(item, "modifier") == source then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- engine effects: queued, applied at the barrier by the systems that model them

local queue, handles, next_handle = {}, {}, 0

E.push = function(t)
    queue[#queue + 1] = t
end
E.pending = function()
    return #queue
end
E.new_handle = function()
    next_handle = next_handle + 1
    return next_handle
end
E.resolve = function(h)
    return handles[h]
end

-- E.flush() -> applied: the queue, in order, each effect to the system that models it
E.flush = function()
    local systems = require("engine.systems")
    local q = queue
    queue = {}
    local applied = 0
    for _, t in ipairs(q) do
        local apply = systems.effects[t.type]
        local created = apply and apply(t)
        if created ~= nil and created ~= false then
            if t.handle and type(created) == 'number' then
                handles[t.handle] = created
            end
            applied = applied + 1
        else
            local k = t.type == 'unmodelled' and tostring(t.keyword) or tostring(t.type)
            stats.unapplied[k] = (stats.unapplied[k] or 0) + 1
        end
    end
    stats.applied = stats.applied + applied
    return applied
end

return E
