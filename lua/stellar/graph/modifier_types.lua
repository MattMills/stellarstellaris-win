-- graph/modifier_types.lua : the game's modifier types, made without its modifiers.log: the types
-- the game defines in code (stellar.graph.modifier_types_static) and the ones it generates from
-- its databases (resources, economic categories, jobs, districts, ship sizes, ...), each with its
-- categories, in the order the game registers them.
--
--   local types = require("stellar.graph.modifier_types")
--   local list = types.generate(folder)   -- { { name, categories }, ... }
--   defs:read_game(folder)                 -- stellar.graph.modifiers: the same, into a definitions
--
-- folder(name) -> the definitions of a database folder, { [key] = { block, file, line } }, as
-- stellar.script.source.definitions (and engine.defs.folder) return them: the folder's files in
-- load order, a later definition replacing an earlier one. categories: a list of the labels
-- modifiers.log prints (stellar.graph.modifiers.CATEGORY).
--
-- The rules were read off the 4.5.2 modifiers.log against the vanilla databases; every type of that
-- log is made, with its categories (tools/modifier_types_test.lua).

local static = require("stellar.graph.modifier_types_static")

local M = {}

-- a definition's entries ------------------------------------------------------------------------

-- the folder's definitions in load order (file, then line)
local function ordered(folder, name)
    local defs = folder(name) or {}
    local list = {}
    for key, def in pairs(defs) do
        list[#list + 1] = { key = key, block = def.block or {}, file = def.file or "", line = def.line or 0 }
    end
    table.sort(list, function(a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        if a.line ~= b.line then
            return a.line < b.line
        end
        return a.key < b.key
    end)
    return list
end

-- the text of the first `key = value` of a block, or nil
local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function yes(block, key)
    return field(block, key) == "yes"
end

-- the bare words of a list block, in order
local function words(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = e.text
        end
    end
    return out
end

local function set_of(list)
    local s = {}
    for _, w in ipairs(list) do
        s[w] = true
    end
    return s
end

-- the generators, in the order the game registers its types ----------------------------------

-- the label of an economic category's `modifier_category` (none: Economic Units)
local ECONOMY_CATEGORY = {
    army = "Armies", colony = "Colony", country = "Countries", deposit = "Deposits", espionage = "Espionage",
    leader = "Leaders", megastructure = "Megastructures", planet = "Planets", pop_group = "Pops", ship = "Ships",
    starbase = "Starbases",
}
-- the kinds of resource modifier an economic category generates, in the order the game makes them
local ECONOMY_KINDS = { "cost", "produces", "upkeep", "logistics" }

-- the resources (common/strategic_resources), in load order
local function resources(folder)
    local out = {}
    for _, d in ipairs(ordered(folder, "common/strategic_resources")) do
        out[#out + 1] = d.key
    end
    return out
end

local GENERATORS = {}
local function generator(name, f)
    GENERATORS[#GENERATORS + 1] = { name = name, f = f }
end

-- the types the game defines in code
generator("static", function(emit)
    for _, t in ipairs(static.TYPES) do
        emit(t[1], static.CATEGORIES[t[2]])
    end
end)

-- per resource: its stockpile cap and the starbase collection types
generator("resources", function(emit, folder, ctx)
    for _, r in ipairs(ctx.resources) do
        emit("country_resource_max_" .. r .. "_add", { "Countries" })
        emit("starbase_stockpile_" .. r .. "_capacity_add", { "Waystations" })
        emit("starbase_stockpile_" .. r .. "_capacity_mult", { "Waystations" })
        emit("starbase_collected_system_" .. r .. "_add", { "Starbases" })
        emit("starbase_collected_system_" .. r .. "_mult", { "Starbases", "Waystations" })
        emit("ship_starbase_stockpile_" .. r .. "_collection_rate_add", { "Ships" })
        emit("ship_starbase_stockpile_" .. r .. "_collection_rate_mult", { "Ships" })
        emit("starbase_collected_colony_" .. r .. "_add", { "Waystations" })
    end
end)

-- espionage operation categories
generator("espionage_operation_categories", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/espionage_operation_categories")) do
        local c = d.key
        emit(c .. "_speed_mult", { "Espionage" })
        emit(c .. "_difficulty_add", { "Espionage" })
        emit(c .. "_difficulty_mult", { "Espionage" })
        emit("hostile_" .. c .. "_difficulty_add", { "Espionage" })
        emit("hostile_" .. c .. "_difficulty_mult", { "Espionage" })
        emit(c .. "_skill_add", { "Espionage" })
        emit(c .. "_skill_mult", { "Espionage" })
    end
end)

-- economic categories: a block is read in order; a triggered modifier is made where it is declared
-- (with the modifier category declared so far), the category's own generated modifiers at its end
generator("economic_categories", function(emit, folder, ctx)
    for _, d in ipairs(ordered(folder, "common/economic_categories")) do
        local label = nil
        local add, mult = {}, {}
        local function cats()
            return { label or "Economic Units", "AI Economy" }
        end
        for _, e in ipairs(d.block) do
            local k = e.op and e.key and e.key.text
            if k == "modifier_category" then
                label = ECONOMY_CATEGORY[e.value.text] or label
            elseif k == "generate_add_modifiers" then
                for _, w in ipairs(words(e.value)) do
                    add[w] = true
                end
            elseif k == "generate_mult_modifiers" then
                for _, w in ipairs(words(e.value)) do
                    mult[w] = true
                end
            elseif k and k:match("^triggered_[%w_]+_modifier$") and type(e.value) == "table" then
                local kind = k:match("^triggered_([%w_]+)_modifier$")
                local key = field(e.value, "key")
                local types = set_of(words(field(e.value, "modifier_types")))
                if key then
                    local c = cats()
                    if types.mult then
                        emit(key .. "_" .. kind .. "_mult", c)
                    end
                    for _, r in ipairs(ctx.resources) do
                        if types.add then
                            emit(key .. "_" .. r .. "_" .. kind .. "_add", c)
                        end
                        if types.mult then
                            emit(key .. "_" .. r .. "_" .. kind .. "_mult", c)
                        end
                    end
                end
            end
        end
        local c = cats()
        for _, r in ipairs(ctx.resources) do
            for _, kind in ipairs(ECONOMY_KINDS) do
                if add[kind] then
                    emit(d.key .. "_" .. r .. "_" .. kind .. "_add", c)
                end
                if mult[kind] then
                    emit(d.key .. "_" .. r .. "_" .. kind .. "_mult", c)
                end
            end
        end
        for _, kind in ipairs(ECONOMY_KINDS) do
            if mult[kind] then
                emit(d.key .. "_" .. kind .. "_mult", c)
            end
        end
    end
end)

-- species archetypes that use modifiers: trait points and picks, happiness; growth for the
-- organic ones (whose happiness type is named in lower case)
generator("species_archetypes", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/species_archetypes")) do
        if field(d.block, "uses_modifiers") ~= "no" then
            local a = d.key
            emit(a .. "_species_trait_points_add", { "Countries" })
            emit(a .. "_species_trait_picks_add", { "Countries" })
            if yes(d.block, "robotic") then
                emit(a .. "_pop_happiness", { "Pops" })
            else
                emit(a:lower() .. "_pop_happiness", { "Pops" })
                emit(a .. "_logistic_growth_mult", { "Pops" })
                emit(a .. "_bonus_pop_growth", { "Pops" })
                emit(a .. "_bonus_pop_growth_mult", { "Pops" })
            end
        end
    end
end)

generator("ethics", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/ethics")) do
        emit("pop_" .. d.key .. "_attraction_mult", { "Pops" })
    end
end)

generator("bypass", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/bypass")) do
        emit(d.key .. "_empire_windup_mult", { "Countries" })
        emit(d.key .. "_ship_windup_mult", { "Ships" })
        emit(d.key .. "_megastructure_bypass_windup_mult", { "Megastructures" })
    end
end)

generator("buildings", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/buildings")) do
        emit("planet_" .. d.key .. "_build_speed_mult", { "Colony" })
    end
end)

generator("zones", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/zones")) do
        emit("planet_" .. d.key .. "_build_speed_mult", { "Colony" })
    end
end)

generator("districts", function(emit, folder)
    local list = ordered(folder, "common/districts")
    for _, d in ipairs(list) do
        emit(d.key .. "_max_add", { "Colony" })
        emit(d.key .. "_max_mult", { "Colony" })
    end
    for _, d in ipairs(list) do
        emit("planet_" .. d.key .. "_build_speed_mult", { "Colony" })
    end
end)

-- (random_list is a list of planet classes, not one)
generator("planet_classes", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/planet_classes")) do
        if d.key ~= "random_list" then
            emit(d.key .. "_habitability", { "Habitability" })
            emit(d.key .. "_max_buildings_add", { "Colony" })
            emit(d.key .. "_max_districts_add", { "Colony" })
        end
    end
end)

generator("ship_sizes", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/ship_sizes")) do
        for _, s in ipairs(static.SHIP_SIZE_STATS) do
            emit("shipsize_" .. d.key .. "_" .. s[1], static.CATEGORIES[s[2]])
        end
    end
end)

generator("pop_categories", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/pop_categories")) do
        emit("pop_cat_" .. d.key .. "_happiness", { "Pops" })
        emit("pop_cat_" .. d.key .. "_political_power", { "Pops" })
        emit("pop_cat_" .. d.key .. "_bonus_workforce_mult", { "Pops" })
    end
end)

-- jobs (the automated workforce only for one that can be automated)
generator("pop_jobs", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/pop_jobs")) do
        local j = d.key
        emit("job_" .. j .. "_add", { "Colony" })
        emit("job_" .. j .. "_per_pop", { "Colony" })
        emit("job_" .. j .. "_per_crime", { "Colony" })
        emit("pop_" .. j .. "_workforce_mult", { "Pops" })
        emit("pop_" .. j .. "_bonus_workforce_mult", { "Pops" })
        emit("job_" .. j .. "_max_workforce_add", { "Colony" })
        emit("job_" .. j .. "_max_workforce_mult", { "Colony" })
        if field(d.block, "can_be_automated") ~= "no" then
            emit("job_" .. j .. "_automated_workforce_mult", { "Colony" })
        end
    end
end)

generator("resolution_categories", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/resolution_categories")) do
        emit(d.key .. "_vote_strength_mult", { "Countries" })
    end
end)

-- anomaly categories
generator("anomalies", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/anomalies")) do
        emit(d.key .. "_research_speed_mult", { "Leaders" })
    end
end)

-- a situation sized by `total_progress` (section weights) gets its two max progress types
generator("situations", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/situations")) do
        if field(d.block, "total_progress") ~= nil then
            emit(d.key .. "_max_progress_add", { "Countries" })
            emit(d.key .. "_max_progress_mult", { "Countries" })
        end
    end
end)

generator("espionage_operation_types", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/espionage_operation_types")) do
        local c = d.key
        emit(c .. "_speed_mult", { "Espionage" })
        emit(c .. "_difficulty_add", { "Espionage" })
        emit(c .. "_difficulty_mult", { "Espionage" })
        emit("hostile_" .. c .. "_difficulty_add", { "Espionage" })
        emit("hostile_" .. c .. "_difficulty_mult", { "Espionage" })
        emit(c .. "_skill_add", { "Espionage" })
        emit(c .. "_skill_mult", { "Espionage" })
    end
end)

generator("megastructures", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/megastructures")) do
        emit("megastructure_" .. d.key .. "_build_speed_mult", { "Megastructures" })
    end
end)

generator("country_types", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/country_types")) do
        emit("damage_vs_country_type_" .. d.key .. "_mult", { "Ships" })
    end
end)

generator("technology_categories", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/technology/category")) do
        emit("category_" .. d.key .. "_research_speed_mult", { "Countries" })
        emit("category_" .. d.key .. "_draw_chance_mult", { "Countries" })
    end
end)

-- leader classes (the country's cap of a class only for one with a leader_capacity)
generator("leader_classes", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/leader_classes")) do
        local c = d.key
        emit(c .. "_exp_gain", { "Leaders" })
        emit(c .. "_skill_levels", { "Leaders" })
        emit(c .. "_skill_add", { "Leaders" })
        emit(c .. "_initial_skill", { "Leaders" })
        if field(d.block, "leader_capacity") ~= nil then
            emit("country_" .. c .. "_cap_add", { "Countries" })
        end
        emit(c .. "_lifespan_add", { "Leaders" })
        emit(c .. "_lifespan_mult", { "Leaders" })
    end
end)

-- the types script defines (common/scripted_modifiers), with the category it gives them (none: all).
-- Vanilla uses colony, country, fleet, leader, pop_group and ship; the other names are those of the
-- folder's README, their labels not checked against a log.
local SCRIPTED_CATEGORY = {
    all = "All", pop = "Pops", pop_group = "Pops", ship = "Ships", station = "Space Stations", fleet = "Fleets",
    country = "Countries", army = "Armies", leader = "Leaders", planet = "Planets", colony = "Colony",
    component = "Ship Components", pop_faction = "Pop Factions", deposit = "Deposits", megastructure = "Megastructures",
    habitability = "Habitability", starbase = "Starbases", economic_unit = "Economic Units", system = "Star Systems",
    federation = "Federations", espionage = "Espionage",
}
generator("scripted_modifiers", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/scripted_modifiers")) do
        emit(d.key, { SCRIPTED_CATEGORY[field(d.block, "category") or "all"] or "All" })
    end
end)

generator("councilors", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/governments/councilors")) do
        emit(d.key .. "_exp_gain", { "Leaders" })
    end
end)

-- patrons with modifiers (add_modifier = yes)
generator("patrons", function(emit, folder)
    for _, d in ipairs(ordered(folder, "common/patrons")) do
        if yes(d.block, "add_modifier") then
            emit("add_attunement_" .. d.key, { "Countries" })
            emit(d.key .. "_attunement_mult", { "Countries" })
        end
    end
end)

-- types.generate(folder) -> { { name, categories }, ... } in the game's order, each name once (a
-- later registration of a name changes its categories, not its place)
function M.generate(folder)
    local out, at = {}, {}
    local function emit(name, categories)
        local i = at[name]
        if i then
            out[i][2] = categories
        else
            out[#out + 1] = { name, categories }
            at[name] = #out
        end
    end
    local ctx = { resources = resources(folder) }
    for _, g in ipairs(GENERATORS) do
        g.f(emit, folder, ctx)
    end
    return out
end

M.GENERATORS = GENERATORS

return M
