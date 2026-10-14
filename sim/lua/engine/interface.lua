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
        is_primitive = function(c) return world.field(c, "type") == "primitive" and "yes" or "no" end,
        -- the capital is a colony id: its planet
        capital = function(c)
            local col = tonumber(world.field(c, "capital"))
            return col and world.colony_planet[col]
        end,
    },
    planet = {
        is_planet_class = function(p) return world.field(p, "planet_class") end,
        -- a planet answers for its owner (the primitives' capital buildings ask it)
        is_primitive = function(p)
            local c = obj("country", tonumber(world.field(p, "owner")))
            return (c and world.field(c, "type") == "primitive") and "yes" or "no"
        end,
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
-- is_being_assimilated (a pop group, CPopGroupIsBeingAssimilatedTrigger): the citizenship its owner
-- gives its species has `is_assimilation = yes`
DERIVED.pop_group.is_being_assimilated = function(g, id)
    local cid = tonumber(world.field(g, "planet"))
    local pid = cid and world.colony_planet[cid]
    local owner = pid and tonumber(world.field(obj("planet", pid), "owner"))
    local sid = E.species_of("pop_group", id)
    local citizenship = owner and sid and E.species_right(owner, sid, "citizenship")
    local d = citizenship and defs().get("common/species_rights/citizenship_types", citizenship)
    return (d and defs().field(d.block, "is_assimilation") == "yes") and "yes" or "no"
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
-- species_portrait: the species' portrait (a pop group's, a leader's, a country's founder species')
local function species_field_is(kind, key)
    return function(o, m, id)
        local sid = E.species_of(kind, id)
        local sp = sid and obj("species", sid)
        return sp ~= nil and world.field(sp, key) == m
    end
end
for _, kind in ipairs({ "species", "pop_group", "leader", "country" }) do
    SETS[kind] = SETS[kind] or {}
    SETS[kind].species_portrait = species_field_is(kind, "portrait")
end
-- E.species_field(species id, key): a field of the species
E.species_field = function(sid, key)
    local sp = sid and obj("species", sid)
    return sp and world.field(sp, key)
end
-- E.base_species(species id): the first of its line (`base_ref` followed while there is one)
E.base_species = function(sid)
    for _ = 1, 16 do
        local base = tonumber(E.species_field(sid, "base_ref"))
        if not base or base == 4294967295 or base == sid then
            return sid
        end
        sid = base
    end
    return sid
end

-- the AI personality (`personality`) and its definition's behaviour (`behaviour = { conqueror =
-- yes ... }`, SPersonalityBehaviour)
SETS.country.has_ai_personality = function(c, m) return world.field(c, "personality") == m end
SETS.country.has_ai_personality_behaviour = function(c, m)
    local p = world.field(c, "personality")
    local d = p and defs().get("common/personalities", p)
    local b = d and defs().field(d.block, "behaviour")
    return type(b) == "table" and defs().field(b, m) == "yes"
end
-- is_criminal_syndicate: the government's criminal heritage civic
DERIVED.country.is_criminal_syndicate = function(c)
    return SETS.country.has_civic(c, "civic_criminal_heritage") and "yes" or "no"
end
-- is_ai (CAiTrigger 0x1949750: no player controls the country): not in the save's `player = { {
-- name country } }` list (every country's `ai = { initialized = yes }`, the player's too)
local humans
local function is_human(id)
    if humans == nil then
        humans = {}
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "player" and e.value.text == nil then
                for _, p in ipairs(world.blocks(e.value)) do
                    local c = tonumber(world.field(p, "country"))
                    if c then humans[c] = true end
                end
            end
        end
    end
    return humans[id] == true
end
DERIVED.country.is_ai = function(c, id) return is_human(id) and "no" or "yes" end
-- is_subject / is_overlord / has_federation: the country's `overlord`, `subjects`, `federation`
local function ref(v)
    v = tonumber(v)
    return (v and v ~= 4294967295) and v or nil
end
DERIVED.country.is_subject = function(c)
    local o = ref(world.field(c, "overlord"))
    return (o and obj("country", o)) and "yes" or "no"
end
DERIVED.country.is_overlord = function(c)
    for _, s in ipairs(world.list(world.field(c, "subjects"))) do
        if obj("country", tonumber(s)) then return "yes" end
    end
    return "no"
end
DERIVED.country.has_federation = function(c)
    local f = ref(world.field(c, "federation"))
    return (f and obj("federation", f)) and "yes" or "no"
end
-- E.federation_of(country id): its federation's id, or nil
E.federation_of = function(id)
    local f = tonumber(world.field(obj("country", id), "federation"))
    return f ~= 4294967295 and f or nil
end
-- the `opinion = { who = <country> value > x }` trigger: the AI's opinion (engine.ai.opinion)
E.opinion_trigger = function(e, ctx)
    return require("engine.ai.opinion").trigger(e, ctx)
end
-- has_unlocked_all_traditions (engine.traditions)
E.unlocked_all_traditions = function(id)
    return require("engine.traditions").unlocked_all(id)
end

-- ---------------------------------------------------------------------------------------------
-- diplomacy: a country's relations (`relations_manager = { relation = { owner country <flag>=yes
-- ... } }`, CRelation::WriteMembers 0x669d30: each bit of the relation's flags is written as
-- `<name> = yes`)

-- E.relation(country, other) -> the country's relation block towards other, or nil
E.relation = function(country, other)
    local rm = world.field(obj("country", country), "relations_manager")
    for _, r in ipairs(world.fields(rm, "relation")) do
        if type(r) == "table" and tonumber(world.field(r, "country")) == other then
            return r
        end
    end
    return nil
end
-- E.relation_flag(country, other, name): the relation's `name = yes`
E.relation_flag = function(country, other, name)
    local r = E.relation(country, other)
    return r ~= nil and world.field(r, name) == "yes"
end
-- E.relations(country) -> the ids of the countries it has a relation with that exist
-- (CRelationListBuilder::BuildIDArray 0x1812e00)
E.relations = function(country)
    local out = {}
    local rm = world.field(obj("country", country), "relations_manager")
    for _, r in ipairs(world.fields(rm, "relation")) do
        local other = type(r) == "table" and tonumber(world.field(r, "country"))
        if other and obj("country", other) then
            out[#out + 1] = other
        end
    end
    return out
end
-- E.num_communications(country): its relations with an existing country and `communications = yes`
-- (CNumCommunicationsTrigger::GetTriggerValue 0x198df10: bit 3 of the relation's flags)
E.num_communications = function(country)
    local n = 0
    local rm = world.field(obj("country", country), "relations_manager")
    for _, r in ipairs(world.fields(rm, "relation")) do
        local other = type(r) == "table" and tonumber(world.field(r, "country"))
        if other and obj("country", other) and world.field(r, "communications") == "yes" then
            n = n + 1
        end
    end
    return n
end
-- E.has_waystation_pact(country, other) (CRelation::HasWaystationPact 0x66bd00): the relation's
-- `waystation_pact = yes` (bit 27), or both in the same federation whose settings grant the pacts
-- (`federation_progression = { waystation_pact = yes }`, set by set_federation_settings)
E.has_waystation_pact = function(country, other)
    if E.relation_flag(country, other, "waystation_pact") then
        return true
    end
    local f = E.federation_of(country)
    if not f or f ~= E.federation_of(other) then
        return false
    end
    return world.path(obj("federation", f), "federation_progression", "waystation_pact") == "yes"
end
-- E.federation_leader(country) -> the `leader` of the country's federation, or nil without one
E.federation_leader = function(country)
    local f = E.federation_of(country)
    local fo = f and obj("federation", f)
    return fo and (ref(world.field(fo, "leader")) or -1) or nil
end
-- E.federation_members(federation) -> country ids (`members = { ... }`)
E.federation_members = function(fid)
    local out = {}
    for _, m in ipairs(world.list(world.field(obj("federation", fid), "members"))) do
        local c = tonumber(m)
        if c and obj("country", c) then out[#out + 1] = c end
    end
    return out
end
-- E.subjects(country) -> country ids (`subjects = { ... }`, CCountry +9840)
E.subjects = function(country)
    local out = {}
    for _, s in ipairs(world.list(world.field(obj("country", country), "subjects"))) do
        local c = tonumber(s)
        if c and obj("country", c) then out[#out + 1] = c end
    end
    return out
end
-- E.overlord(country) -> country id (`overlord = <country>`, CCountry +9776; CHasAnyOverlord
-- 0x19b1df0), or nil
E.overlord = function(country)
    local o = ref(world.field(obj("country", country), "overlord"))
    return (o and obj("country", o)) and o or nil
end

-- ---------------------------------------------------------------------------------------------
-- a country's crisis, relics, focus, special projects, technologies

-- E.has_menace_perk(country, perk) (CHasCrisisPerkTrigger 0x1a1cab0 -> CCountry::HasCrisisPerk
-- 0x72f020): a perk of a crisis level the country unlocked (`crisis_progression = { path = x level =
-- "crisis_level_1" ... }`, CCrisisProgression::WriteMembers 0x569820; the levels' `perks` in
-- common/crisis_levels)
E.has_menace_perk = function(country, perk)
    local cp = world.field(obj("country", country), "crisis_progression")
    for _, level in ipairs(world.fields(cp, "level")) do
        local d = type(level) == "string" and defs().get("common/crisis_levels", level)
        local perks = d and defs().field(d.block, "perks")
        for _, p in ipairs(type(perks) == "table" and perks or {}) do
            if p.text == perk then return true end
        end
    end
    return false
end
-- E.has_relic(country, relic) (CHasRelicTrigger 0x19b2990: CCountry +12336): `relics = { "r_x" }`
E.has_relic = function(country, relic)
    for _, r in ipairs(world.list(world.field(obj("country", country), "relics"))) do
        if r == relic then return true end
    end
    return false
end
-- E.has_active_focus(country, focus) (CHasActiveFocusTrigger 0x1a19860): a card of the country's
-- `focus = { active = { <focus card ids> } }` of that type whose `status` is 0 (not completed)
E.has_active_focus = function(country, focus)
    local f = world.field(obj("country", country), "focus")
    for _, id in ipairs(world.list(world.field(f, "active"))) do
        local card = obj("focus_cards", tonumber(id))
        if card and world.field(card, "type") == focus and (tonumber(world.field(card, "status")) or 0) == 0 then
            return true
        end
    end
    return false
end
-- E.completed_special_project(country, project) (CHasSpecialProjectStatusTrigger<Completed>
-- 0x19e5740): a special project of the country's `events` of that key with `status = completed`
-- (CSpecialProjectInstance status 2)
E.completed_special_project = function(country, project)
    local ev = world.field(obj("country", country), "events")
    for _, sp in ipairs(world.fields(ev, "special_project")) do
        if type(sp) == "table" and world.field(sp, "special_project") == project
            and world.field(sp, "status") == "completed" then
            return true
        end
    end
    return false
end
-- E.num_repeatable_techs(country) (CNumRepeatableTechsTrigger::GetTriggerValue 0x1990580): the
-- levels of the country's technologies whose definition has more than one level (`levels = -1` or
-- > 1)
E.num_repeatable_techs = function(country)
    local ts = world.field(obj("country", country), "tech_status")
    local n, tech = 0, nil
    for _, e in ipairs(type(ts) == "table" and ts or {}) do
        if e.op and e.key then
            if e.key.text == "technology" then
                tech = e.value.text
            elseif e.key.text == "level" and tech then
                local d = defs().get("common/technology", tech)
                local levels = d and tonumber(defs().field(d.block, "levels")) or 1
                if levels < 0 or levels > 1 then
                    n = n + (tonumber(e.value.text) or 0)
                end
                tech = nil
            end
        end
    end
    return n
end
-- E.has_built_species(country) (CHasBuiltSpecies 0x19949c0): `built_species_ref` names a species
E.has_built_species = function(country)
    local s = ref(world.field(obj("country", country), "built_species_ref"))
    return s ~= nil and obj("species", s) ~= nil
end

-- E.identical_species(country) -> { { from, into } ... }: the merges merge_species would make
-- (CMergeSpeciesEffect 0x17b9840 -> CCountry::HandleIdenticalSpeciesMerge 0x71a160): a species of the
-- country's `owned_species_refs`, other than its founder and default species, into another of them
-- with the same base species, the same name, the same traits (in order) and the same species rights
local RIGHTS = { "living_standard", "citizenship", "military_service", "slavery", "purge", "population_control",
    "colonization_control", "migration_control", "subspecies_integration" }
E.identical_species = function(country)
    local c = obj("country", country)
    local list = {}
    for _, s in ipairs(world.list(world.field(c, "owned_species_refs"))) do
        local sid = tonumber(s)
        if sid and obj("species", sid) then list[#list + 1] = sid end
    end
    local function sig(sid)
        local sp = obj("species", sid)
        local name = world.field(sp, "name")
        local parts = { tostring(E.base_species(sid)),
            type(name) == "table" and require("pdxscript").write(name) or tostring(name) }
        for _, t in ipairs(world.fields(world.field(sp, "traits"), "trait")) do parts[#parts + 1] = tostring(t) end
        for _, k in ipairs(RIGHTS) do parts[#parts + 1] = tostring(E.species_right(country, sid, k)) end
        return table.concat(parts, "|")
    end
    local founder = ref(world.field(c, "founder_species_ref"))
    local default = ref(world.field(c, "default_species"))
    local out = {}
    for _, a in ipairs(list) do
        if a ~= founder and a ~= default then
            local sa = sig(a)
            for _, b in ipairs(list) do
                if b ~= a and sig(b) == sa then
                    out[#out + 1] = { a, b }
                    break
                end
            end
        end
    end
    return out
end

-- E.budget_page(country, page) ->{ income = { [cat] = { [res] = v } }, expenses = ... }: the
-- simulation's last month once it ran one (engine.economy.last_month), else the save's `budget =
-- { <page> = { income expenses trade_income trade_expenses } }` (the trade tables in the sides)
E.budget_page = function(country, page)
    local economy = package.loaded["engine.economy"]
    local lm = economy and economy.last_month and economy.last_month[country]
    if lm then
        return lm
    end
    local p = world.path(obj("country", country), "budget", page)
    local out = { income = {}, expenses = {} }
    if type(p) ~= "table" then
        return out
    end
    for _, pair in ipairs({ { "income", "income" }, { "expenses", "expenses" }, { "trade_income", "income" },
        { "trade_expenses", "expenses" } }) do
        local s = world.field(p, pair[1])
        for _, e in ipairs(type(s) == "table" and s or {}) do
            if e.op and e.key and e.value.text == nil then
                local t = out[pair[2]][e.key.text] or {}
                for _, x in ipairs(e.value) do
                    if x.op and x.key then
                        t[x.key.text] = (t[x.key.text] or 0) + (tonumber(x.value.text) or 0)
                    end
                end
                out[pair[2]][e.key.text] = t
            end
        end
    end
    return out
end
-- E.budget_sum(country, page, side, res[, category]): a side's (income, expenses or "balance":
-- income minus expenses) amount of res over all categories, or the category's
E.budget_sum = function(country, page, side, res, category)
    local b = E.budget_page(country, page)
    local v = 0
    for s, sign in pairs({ income = 1, expenses = -1 }) do
        if side == "balance" or side == s then
            for cat, t in pairs(b[s] or {}) do
                if category == nil or cat == category then
                    v = v + (side == "balance" and sign or 1) * (t[res] or 0)
                end
            end
        end
    end
    return v
end
-- E.owned_starbases(country, nonprimary) -> starbase ids (COwnedStarbaseListBuilder 0x1816d50,
-- COwnedNonprimaryStarbaseListBuilder 0x1816ee0): the starbases of the systems whose owner
-- (CStarbase::GetOwner: its station's fleet's) is the country; nonprimary: not the system's
-- primary starbase (CStarbase::IsPrimaryStarbase 0x7dcb00: the first of its `starbases`)
E.owned_starbases = function(country, nonprimary)
    local out = {}
    for _, sid in ipairs(world.all("system")) do
        for i, sb in ipairs(world.list(world.field(obj("system", sid), "starbases"))) do
            local s = tonumber(sb)
            if s and obj("starbase", s) and (not nonprimary or i > 1) and E.owner_of("starbase", s) == country then
                out[#out + 1] = s
            end
        end
    end
    return out
end

-- E.situations(country) -> the ids of the situations of the country (`situations = { situations = {
-- <id> = { country = x ... } } }`)
world.KINDS.situation = world.KINDS.situation or "situations"
E.situations = function(country)
    local out = {}
    for _, id in ipairs(world.all("situation")) do
        if tonumber(world.field(obj("situation", id), "country")) == country then
            out[#out + 1] = id
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- borders, systems, colonies

-- E.systems_within_border(country) -> system ids (CSystemWithinBorderListBuilder 0x1817430: the
-- country's owned systems; the save does not write them: a system's owner is its starbase's,
-- world.system_owner)
E.systems_within_border = function(country)
    local out = {}
    for _, sid in ipairs(world.all("system")) do
        if world.system_owner and world.system_owner[sid] == country then
            out[#out + 1] = sid
        end
    end
    return out
end
-- E.system_planets(system) -> planet ids (`planet = <id>` of the galactic object)
E.system_planets = function(sid)
    local out = {}
    for _, p in ipairs(world.fields(obj("system", sid), "planet")) do
        local id = tonumber(p)
        if id and obj("planet", id) then out[#out + 1] = id end
    end
    return out
end
-- E.starbase_of(kind, id) -> the starbase of a system (its first `starbases`), of a planet (its
-- system's), a starbase itself
E.starbase_of = function(kind, id)
    if kind == "starbase" then
        return id
    elseif kind ~= "system" and kind ~= "planet" then
        return nil
    end
    local sid = kind == "system" and id or E.system_of(kind, id)
    for _, sb in ipairs(world.list(world.field(obj("system", sid), "starbases"))) do
        local s = tonumber(sb)
        if s and s ~= 4294967295 and obj("starbase", s) then
            return s
        end
    end
    return nil
end
-- E.owner_of(kind, id) -> the owner of a starbase, ship or fleet: the country whose fleets_manager
-- owns the fleet (a starbase's: its station ship's fleet)
E.owner_of = function(kind, id)
    if kind == "starbase" then
        kind, id = "ship", tonumber(world.field(obj("starbase", id), "station"))
    end
    if kind == "ship" then
        kind, id = "fleet", tonumber(world.field(obj("ship", id), "fleet"))
    end
    if kind == "fleet" then
        return id and world.fleet_owner and world.fleet_owner[id] or nil
    end
    return nil
end
-- the colony of a scope (NScriptUtil::GetColonyFromScope): a planet's, a pop group's
local function colony_of(kind, id)
    local pid
    if kind == "planet" then
        pid = id
    elseif kind == "pop_group" then
        local col = tonumber(world.field(obj("pop_group", id), "planet"))
        return col and obj("colony", col)
    end
    local col = pid and world.planet_colony[pid]
    return col and obj("colony", col)
end
-- E.branch_office_owner(kind, id) (CHasBranchOfficeTrigger 0x19a0dc0, CColony::HasBranchOffice
-- 0xdcd9c0): the owner of the colony's branch office, or nil: its `externally_owned_buildings = { {
-- building_owner = c owner_type = corporate ... } }` (SBuildingArrayData; owner type 1, corporate)
E.branch_office_owner = function(kind, id)
    local c = colony_of(kind, id)
    for _, b in ipairs(world.blocks(world.field(c, "externally_owned_buildings"))) do
        if world.field(b, "owner_type") == "corporate" then
            return tonumber(world.field(b, "building_owner")) or -1
        end
    end
    return nil
end
-- E.num_districts(kind, id) / E.has_district(kind, id, type) (CHasDistrictTrigger 0x196ed70:
-- CColony::CalcNumDistricts 0xdc95b0, the levels of the colony's districts; CColony::HasDistrict
-- 0xdc8010, a district of the type, any level)
E.num_districts = function(kind, id)
    local c = colony_of(kind, id)
    local n = 0
    for _, d in ipairs(world.list(world.field(c, "districts"))) do
        n = n + (tonumber(world.field(obj("districts", tonumber(d)), "level")) or 0)
    end
    return n
end
E.has_district = function(kind, id, dtype)
    local c = colony_of(kind, id)
    for _, d in ipairs(world.list(world.field(c, "districts"))) do
        if world.field(obj("districts", tonumber(d)), "type") == dtype then return true end
    end
    return false
end
-- E.num_zones(kind, id, type) (CNumZonesTrigger::GetTriggerValue 0x196fed0 ->
-- CColony::CalcNumZonesOfType 0xda8960): the zones of the colony's districts (of the type, or all);
-- for a country the game writes each colony's count over the last one (the last colony's count)
E.num_zones = function(kind, id, ztype)
    local function count(c)
        local n = 0
        for _, d in ipairs(world.list(world.field(c, "districts"))) do
            for _, z in ipairs(world.list(world.field(obj("districts", tonumber(d)), "zones"))) do
                local zid = tonumber(z)
                if zid and zid ~= 4294967295 and (ztype == nil or world.field(obj("zones", zid), "type") == ztype) then
                    n = n + 1
                end
            end
        end
        return n
    end
    if kind == "country" then
        local n = 0
        for _, col in ipairs(world.list(world.field(obj("country", id), "owned_planets"))) do
            n = count(obj("colony", tonumber(col)))
        end
        return n
    end
    return count(colony_of(kind, id))
end
-- E.colonizing_species(kind, id) (CIsUnderColonizationTrigger 0x1966c10): the colony's
-- `colonizing_species` when it names a species
E.colonizing_species = function(kind, id)
    local s = ref(world.field(colony_of(kind, id), "colonizing_species"))
    return (s and obj("species", s)) and s or nil
end
-- E.district_set(kind, id) (CPlanetDistrictSetTrigger 0x1a09320): the planet class's `district_set`
-- (common/planet_classes; "" without)
E.district_set = function(kind, id)
    local pid = kind == "planet" and id or nil
    local class = pid and world.field(obj("planet", pid), "planet_class")
    local d = class and defs().get("common/planet_classes", class)
    return d and defs().field(d.block, "district_set") or ""
end
-- E.controller(kind, id) (CIsControlledByTrigger 0x194c0c0): a planet's `controller`, a
-- starbase's, fleet's or ship's owner
E.controller = function(kind, id)
    if kind == "planet" then
        return ref(world.field(obj("planet", id), "controller"))
    end
    return E.owner_of(kind, id)
end
-- E.species_being_integrated(species, country) (CSpeciesBeingIntegratedTrigger 0x1a27aa0 ->
-- CSpecies::CheckRightsBeingIntegrated 0x3e6e30): the country's species rights module is enabled
-- and the species' subspecies_integration type has `integration = yes`
E.species_being_integrated = function(species, country)
    local module = world.path(obj("country", country), "modules", "standard_species_rights_module")
    if type(module) ~= "table" or world.field(module, "enabled") ~= "yes" then
        return false
    end
    local t = E.species_right(country, species, "subspecies_integration")
    local d = t and defs().get("common/species_rights/subspecies_integration_types", t)
    return d ~= nil and defs().field(d.block, "integration") == "yes"
end
-- E.galactic_community_formed() (CIsGalacticCommunityFormedTrigger 0x1a062f0): the save's
-- `galactic_community = { community_formed = <date> }` (written unless the end of time)
E.galactic_community_formed = function()
    local gc = world.meta and world.meta.galactic_community
    return type(gc) == "table" and world.field(gc, "community_formed") ~= nil
end

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

-- E.has_dlc(name): the DLC is in the save's required_dlcs (the meta's list); with no list, yes
local dlc_set
E.has_dlc = function(name)
    if dlc_set == nil then
        local list = world.meta and world.meta.required_dlcs
        if type(list) ~= "table" then
            return true
        end
        dlc_set = {}
        for _, x in ipairs(list) do
            if x.text then dlc_set[x.text] = true end
        end
    end
    return dlc_set[name] == true
end

-- E.uses_ship_category(country, category): the category is in the ship_kinds of the country's
-- graphical culture (common/graphical_culture); a culture without ship_kinds uses every category
E.uses_ship_category = function(country, category)
    local c = obj("country", country)
    local culture = c and world.field(c, "graphical_culture")
    local d = culture and defs().get("common/graphical_culture", culture)
    if not d then
        return false
    end
    local kinds = defs().field(d.block, "ship_kinds")
    if type(kinds) ~= "table" then
        return true
    end
    for _, k in ipairs(kinds) do
        if k.text == category then return true end
    end
    return false
end

-- E.owned_species(country) -> species ids with pops in the country (its colonies' pop groups)
E.owned_species = function(country)
    local out, seen = {}, {}
    for _, pid in ipairs(E.colonies(country)) do
        for _, gid in ipairs(E.pop_groups(pid)) do
            local g = obj("pop_group", gid)
            local sid = g and world.field(g, "killed") ~= "yes" and E.species_of("pop_group", gid)
            if sid and not seen[sid] then
                seen[sid] = true
                out[#out + 1] = sid
            end
        end
    end
    return out
end

-- E.system_of(kind, id) -> the system an object is in (`solar_system`): a planet's coordinate
-- origin, a fleet's, a ship's fleet's, a system itself
E.system_of = function(kind, id)
    if kind == "system" then
        return id
    end
    if kind == "ship" then
        local s = obj("ship", id)
        return s and E.system_of("fleet", tonumber(world.field(s, "fleet")))
    end
    if kind == "colony" then
        return E.system_of("planet", world.colony_planet[id])
    end
    local o = obj(kind, id)
    local coord = o and world.field(o, "coordinate")
    return type(coord) == "table" and tonumber(world.field(coord, "origin")) or nil
end

-- E.leader_of(kind, id) -> the leader of an object (`leader`): a planet's governor (its colony's),
-- a fleet's (a ship's fleet's) leader, an army's general, a country's ruler
E.leader_of = function(kind, id)
    local l
    if kind == "planet" then
        local col = world.planet_colony[id]
        l = col and tonumber(world.field(obj("colony", col), "governor"))
    elseif kind == "fleet" then
        l = tonumber(world.field(obj("fleet", id), "leader"))
    elseif kind == "ship" then
        local s = obj("ship", id)
        return s and E.leader_of("fleet", tonumber(world.field(s, "fleet")))
    elseif kind == "army" then
        l = tonumber(world.field(obj("army", id), "leader"))
    elseif kind == "country" then
        l = tonumber(world.field(obj("country", id), "ruler"))
    end
    return (l and l ~= 4294967295 and obj("leader", l)) and l or nil
end

-- E.capital_tier(planet) -> the highest capital_tier of its colony's buildings (0 without)
E.capital_tier = function(planet)
    local col = world.planet_colony[planet]
    local c = col and obj("colony", col)
    local tier = 0
    for _, bid in ipairs(world.list(c and world.field(c, "buildings_cache"))) do
        local b = obj("buildings", tonumber(bid))
        local ty = b and world.field(b, "type")
        local d = ty and defs().get("common/buildings", ty)
        local t = d and tonumber(defs().field(d.block, "capital_tier"))
        if t and t > tier then tier = t end
    end
    return tier
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

-- fleets: orders
-- E.is_surveyed(kind, id, country): a planet the country surveyed (CCountry::HasSurveyedDepositHolder),
-- a system all of whose planets it surveyed; E.has_anomaly(kind, id): a planet with an anomaly
-- (engine.fleets.survey)
E.is_surveyed = function(kind, id, country)
    local survey = require("engine.fleets.survey")
    if kind == "planet" then
        return survey.has_surveyed(country, 0, id)
    elseif kind == "system" then
        for _, v in ipairs(world.fields(obj("system", id), "planet")) do
            local p = tonumber(v)
            if p and not survey.has_surveyed(country, 0, p) then return false end
        end
        return obj("system", id) ~= nil
    end
    return false
end
E.has_anomaly = function(kind, id)
    return kind == "planet" and require("engine.fleets.survey").has_anomaly(id) or false
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
