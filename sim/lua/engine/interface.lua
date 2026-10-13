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

E.has = function(kind, id, set, member)
    local o = obj(kind, id)
    if o == nil then
        return false
    end
    local f = SETS[kind] and SETS[kind][set]
    if f then
        return f(o, member) and true or false
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
E.modifier = function(kind, id, name)
    unread("modifier")
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
