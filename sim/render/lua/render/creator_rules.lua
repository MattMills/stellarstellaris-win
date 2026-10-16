-- render/creator_rules.lua : the empire creator's rules (docs/windows/newgame_creator.md): what
-- each editor lists, which choices are allowed, the points and picks, and the design's errors, as
-- the game's empire designer has them (4.5.2 Linux: CCustomizeSpeciesView and its editors,
-- IsEmpireDesignValid). No GUI here: render.creator draws the screens over these.
--
--   local rules = require("render.creator_rules")
--   local R = rules.load(game_dir)              -- the definitions, read once
--   local d = rules.default_design(R)           -- a new design (CEmpireDesign "default")
--   rules.click_ethic(R, d, "ethic_xenophile")  -- the editors' clicks, with the game's rules
--   local errors = rules.errors(R, d, editor)   -- { { key, args } }: the game's texts' keys
--
-- A design is a plain table in the shape of a prescripted country (prescripted_countries/):
--   { key, name, adjective, ship_prefix, spawn_enabled,
--     species = { class, portrait, name, plural, adjective, name_list, gender, traits = {...} },
--     authority, government, civics = {...}, ethics = {...}, origin,
--     room, planet_name, planet_class, system_name, initializer,
--     graphical_culture, city_graphical_culture, ship_color,
--     empire_flag = { icon = { category, file }, background = { category, file }, colors = { 4 } },
--     ruler = { name, gender, portrait, texture, attachment, clothes, leader_class, traits = {...},
--               ruler_title, ruler_title_female, heir_title, heir_title_female, biography },
--     biography }
-- Strings are localisation keys or the player's own text (the game keeps both the same way).

local C = require("render.windows.empire_common")

local rules = {}

-- the editors (NEmpireDesignEditor::EditorType, the menu's static s_MenuButtonSections [V]):
-- type number, menu button (customize_species.gui), editor window (customize_species_editors.gui)
rules.EDITORS = {
    { id = 0, key = "portrait", button = "species_portrait", window = "species_portrait_editor", label = "PORTRAIT" },
    { id = 2, key = "ethics", button = "empire_ethics_and_government", window = "empire_ethics_and_government_editor", label = "ETHICS_AND_GOVERNMENT" },
    { id = 1, key = "origin", button = "empire_origin", window = "empire_origin_editor", label = "EMPIRE_ORIGIN" },
    { id = 5, key = "traits", button = "species_traits", window = "species_traits_editor", label = "TRAITS" },
    { id = 4, key = "name_list", button = "species_name_list", window = "empire_name_list_editor", label = "CUSTOMIZE_NAME_LISTS" },
    { id = 3, key = "names", button = "species_name", window = "species_name_editor", label = "SPECIES_EMPIRE_NAME" },
    { id = 10, key = "homeworld", button = "planet_class", window = "planet_class_editor", label = "GOVERNMENT_VIEW_CAPITAL_LABEL" },
    { id = 12, key = "advisor", button = "empire_advisor", window = "empire_advisor_editor", label = "EMPIRE_ADVISOR" },
    { id = 13, key = "flag", button = "empire_flag", window = "empire_flag_editor", label = "EMPIRE_FLAG" },
    { id = 11, key = "city", button = "planet_city_gfx_culture", window = "planet_city_gfx_culture_editor", label = "CITY_GRAPHICS" },
    { id = 14, key = "shipset", button = "ship_gfx_culture", window = "ship_gfx_culture_browser_editor", label = "SHIPSETS_LABEL" },
    { id = 15, key = "ruler", button = "species_ruler", window = "species_ruler_editor", label = "RULER_EDITOR_APPEARANCE" },
    { id = 16, key = "ruler_traits", button = "ruler_traits", window = "ruler_traits_editor", label = "RULER_EDITOR_TRAITS" },
}
-- the menu's sections (customize_species.gui's menu entries) and their buttons, in order
rules.SECTIONS = {
    { window = "customize_species_view_menu_entry_background",
      editors = { "portrait", "ethics", "origin", "traits", "name_list", "names", "homeworld" } },
    { window = "customize_species_view_menu_entry_empire", editors = { "advisor", "flag", "city", "shipset" } },
    { window = "customize_species_view_menu_entry_ruler", editors = { "ruler", "ruler_traits" } },
}
rules.BY_KEY = {}
for _, e in ipairs(rules.EDITORS) do
    rules.BY_KEY[e.key] = e
end

-- ---------------------------------------------------------------------------------------------
-- small helpers

local field, raw_field = C.field, C.raw_field

local function strip(s)
    return type(s) == "string" and (s:gsub('"', "")) or s
end

-- every `key = value` of a block with that key, unquoted (a block's value as its table)
local function fields(block, key)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            out[#out + 1] = e.value.text and strip(e.value.text) or e.value
        end
    end
    return out
end

-- the bare tokens of a block, unquoted
local function tokens(block)
    return C.strings(block)
end

local function set(list)
    local s = {}
    for _, v in ipairs(list or {}) do
        s[v] = true
    end
    return s
end

local function contains(list, v)
    for i, x in ipairs(list or {}) do
        if x == v then
            return i
        end
    end
    return nil
end

local function copy(t)
    if type(t) ~= "table" then
        return t
    end
    local o = {}
    for k, v in pairs(t) do
        o[k] = copy(v)
    end
    return o
end
rules.copy = copy

-- ---------------------------------------------------------------------------------------------
-- the definitions

local cache = {}

local function ordered(ctx, dir)
    local defs = C.defs(ctx, dir)
    local out = {}
    for _, name in ipairs(C.def_order(ctx, dir)) do
        if defs[name] and not out[name] then
            out[#out + 1] = name
            out[name] = true
        end
    end
    local list = {}
    for _, n in ipairs(out) do
        list[#list + 1] = n
    end
    return list, defs
end

local function num(ctx, dir, name, v, default)
    return C.number(ctx, dir, name, v) or default
end

-- the DLCs installed (dlc/*/*.dlc: `name = "..."`), by name
local function installed_dlcs(game_dir)
    local out = {}
    local source = require("stellar.script.source")
    local dirs = RENDER_SUBDIRS and RENDER_SUBDIRS("dlc") or {}
    for _, d in ipairs(dirs) do
        for _, f in ipairs(source.files(game_dir, d, "dlc") or {}) do
            local tree = source.parse(game_dir, f)
            local n = tree and field(tree, "name")
            if n then
                out[#out + 1] = n
            end
        end
    end
    return out
end

function rules.load(game_dir)
    if cache[game_dir] then
        return cache[game_dir]
    end
    local ctx = { game_dir = game_dir }
    local R = { ctx = ctx }

    -- ethics (common/ethics): cost, category and its value (the grid's place), playable
    local names, defs = ordered(ctx, "common/ethics")
    R.ethics, R.ethic = {}, {}
    for _, k in ipairs(names) do
        local b = defs[k]
        if field(b, "category") then
            local e = {
                key = k, block = b, cost = num(ctx, "common/ethics", k, field(b, "cost"), 1),
                category = field(b, "category"), value = tonumber(field(b, "category_value")) or 0,
                playable = raw_field(b, "playable"), tags = tokens(raw_field(b, "tags")),
                fanatic = field(b, "fanatic_variant"), regular = field(b, "regular_variant"),
            }
            R.ethics[#R.ethics + 1] = e
            R.ethic[k] = e
        end
    end

    -- authorities, civics, origins (common/governments)
    local function govs(dir)
        local list, by = {}, {}
        local ns, ds = ordered(ctx, dir)
        for _, k in ipairs(ns) do
            local b = ds[k]
            local g = {
                key = k, block = b, potential = raw_field(b, "potential"), possible = raw_field(b, "possible"),
                playable = raw_field(b, "playable"), cost = tonumber(field(b, "cost")) or 1,
                is_origin = field(b, "is_origin") == "yes", pickable = field(b, "pickable_at_start") ~= "no",
                traits = fields(raw_field(b, "traits"), "trait"), soft_traits = fields(raw_field(b, "soft_traits"), "trait"),
                icon = field(b, "icon"), picture = field(b, "picture"),
                initializers = tokens(raw_field(b, "initializers")),
                secondary = raw_field(b, "has_secondary_species"),
                council = field(b, "ruler_council_position"),
            }
            list[#list + 1] = g
            by[k] = g
        end
        return list, by
    end
    R.authorities, R.authority = govs("common/governments/authorities")
    local civics, civic = govs("common/governments/civics")
    R.civics, R.civic, R.origins = {}, civic, {}
    for _, g in ipairs(civics) do
        if g.is_origin then
            R.origins[#R.origins + 1] = g
        else
            R.civics[#R.civics + 1] = g
        end
    end
    R.governments = select(2, govs("common/governments"))
    R.government_order = ordered(ctx, "common/governments")
    R.councilors = C.defs(ctx, "common/governments/councilors")

    -- species archetypes (points, picks, inherit_trait_points_from)
    local ans, ads = ordered(ctx, "common/species_archetypes")
    R.archetype = {}
    for _, k in ipairs(ans) do
        local b = ads[k]
        R.archetype[k] = {
            key = k, points = num(ctx, "common/species_archetypes", k, field(b, "species_trait_points")),
            picks = num(ctx, "common/species_archetypes", k, field(b, "species_max_traits")),
            inherit = field(b, "inherit_trait_points_from"), robotic = field(b, "robotic") == "yes",
        }
    end
    for _, a in pairs(R.archetype) do
        local p = a.inherit and R.archetype[a.inherit]
        if p then
            a.points = a.points or p.points
            a.picks = a.picks or p.picks
        end
        a.points, a.picks = a.points or 0, a.picks or 0
    end

    -- species classes (common/species_classes)
    local cns, cds = ordered(ctx, "common/species_classes")
    R.class = {}
    for _, k in ipairs(cns) do
        local b = cds[k]
        R.class[k] = {
            key = k, archetype = field(b, "archetype") or "BIOLOGICAL", possible = raw_field(b, "possible"),
            playable = raw_field(b, "playable") or field(b, "playable"), traits = fields(b, "trait"),
            culture = field(b, "graphical_culture"), gender = field(b, "gender") ~= "no",
            points = tonumber(field(b, "species_trait_points")), picks = tonumber(field(b, "species_max_traits")),
        }
    end

    -- portraits: categories (common/portrait_categories) of sets (common/portrait_sets), each set a
    -- species class's portraits (plain ones, and conditional ones when `playable`)
    local sns, sds = ordered(ctx, "common/portrait_sets")
    R.portrait_set = {}
    for _, k in ipairs(sns) do
        local b = sds[k]
        local s = { key = k, class = field(b, "species_class"), portraits = tokens(raw_field(b, "portraits")), conditional = {} }
        for _, cp in ipairs(fields(b, "conditional_portraits")) do
            if type(cp) == "table" then
                s.conditional[#s.conditional + 1] = {
                    playable = raw_field(cp, "playable"), portraits = tokens(raw_field(cp, "portraits")),
                }
            end
        end
        R.portrait_set[k] = s
    end
    local pns, pds = ordered(ctx, "common/portrait_categories")
    R.portrait_categories = {}
    for _, k in ipairs(pns) do
        local b = pds[k]
        R.portrait_categories[#R.portrait_categories + 1] = {
            key = k, name = field(b, "name"), sets = tokens(raw_field(b, "sets")),
            playable = raw_field(b, "playable"),
        }
    end

    -- species traits (common/traits without leader_class); starting ruler traits
    local tns, tds = ordered(ctx, "common/traits")
    R.traits, R.trait, R.ruler_traits = {}, {}, {}
    for _, k in ipairs(tns) do
        local b = tds[k]
        local t = {
            key = k, block = b, cost = num(ctx, "common/traits", k, field(b, "cost"), 0),
            initial = field(b, "initial") ~= "no", opposites = tokens(raw_field(b, "opposites")),
            archetypes = tokens(raw_field(b, "allowed_archetypes")), classes = tokens(raw_field(b, "species_class")),
            portraits = tokens(raw_field(b, "portrait_override")),
            allowed_origins = tokens(raw_field(b, "allowed_origins")), forbidden_origins = tokens(raw_field(b, "forbidden_origins")),
            allowed_civics = tokens(raw_field(b, "allowed_civics")), forbidden_civics = tokens(raw_field(b, "forbidden_civics")),
            allowed_ethics = tokens(raw_field(b, "allowed_ethics")), forbidden_ethics = tokens(raw_field(b, "forbidden_ethics")),
            planet_classes = tokens(raw_field(b, "allowed_planet_classes")),
            sorting = tonumber(field(b, "sorting_priority")) or 0, icon = field(b, "icon"),
            leader_class = tokens(raw_field(b, "leader_class")), starting_ruler = field(b, "starting_ruler_trait") == "yes",
            dlc = raw_field(b, "potential_crossbreeding_chance") and nil,
        }
        if type(raw_field(b, "cost")) == "table" then
            t.cost = num(ctx, "common/traits", k, field(raw_field(b, "cost"), "base"), 0)
        end
        R.trait[k] = t
        if t.starting_ruler then
            R.ruler_traits[#R.ruler_traits + 1] = t
        elseif #t.leader_class == 0 and not field(b, "leader_trait") then
            R.traits[#R.traits + 1] = t
        end
    end

    -- leader classes (common/leader_classes): max_trait_points, can_rule_empire
    local lns, lds = ordered(ctx, "common/leader_classes")
    R.leader_classes, R.leader_class = {}, {}
    for _, k in ipairs(lns) do
        local b = lds[k]
        local l = { key = k, points = tonumber(field(b, "max_trait_points")) or 0, can_rule = field(b, "can_rule_empire") ~= "no" }
        R.leader_classes[#R.leader_classes + 1] = l
        R.leader_class[k] = l
    end

    -- name lists (common/name_lists): category, `randomized`, `playable`
    local nns, nds = ordered(ctx, "common/name_lists")
    R.name_lists, R.name_list = {}, {}
    for _, k in ipairs(nns) do
        local b = nds[k]
        local n = { key = k, block = b, category = field(b, "category"), playable = raw_field(b, "playable") or field(b, "playable"),
            selectable = raw_field(b, "selectable") }
        R.name_lists[#R.name_lists + 1] = n
        R.name_list[k] = n
    end

    -- graphical cultures (ship sets and cities): `selectable`
    local gns, gds = ordered(ctx, "common/graphical_culture")
    R.cultures, R.culture = {}, {}
    for _, k in ipairs(gns) do
        local b = gds[k]
        local g = { key = k, selectable = raw_field(b, "selectable") or field(b, "selectable"), ship_color = field(b, "ship_color") == "yes" }
        R.cultures[#R.cultures + 1] = g
        R.culture[k] = g
    end

    -- the home world's planet classes (common/planet_classes: colonizable with a climate)
    local qns, qds = ordered(ctx, "common/planet_classes")
    R.planet_classes, R.planet_class = {}, {}
    for _, k in ipairs(qns) do
        local b = qds[k]
        local p = { key = k, climate = field(b, "climate"), colonizable = field(b, "colonizable") == "yes",
            initial = field(b, "initial") == "yes", starting_planet = field(b, "starting_planet") == "yes" }
        R.planet_classes[#R.planet_classes + 1] = p
        R.planet_class[k] = p
    end

    -- the starting systems the player may pick (usage = custom_empire)
    local ins, ids = ordered(ctx, "common/solar_system_initializers")
    R.initializers, R.initializer = {}, {}
    for _, k in ipairs(ins) do
        local b = ids[k]
        local u = field(b, "usage")
        R.initializer[k] = { key = k, usage = u, name = field(b, "name") }
        if u == "custom_empire" then
            R.initializers[#R.initializers + 1] = R.initializer[k]
        end
    end

    R.scripted_triggers = C.defs(ctx, "common/scripted_triggers")

    -- defines
    R.ethic_points = tonumber(C.define(ctx, "NGameplay", "ETHOS_MAX_POINTS")) or 3
    R.min_ethic_points = tonumber(C.define(ctx, "NSpecies", "MIN_ETHIC_POINTS")) or 3
    R.civic_points = tonumber(C.define(ctx, "NGameplay", "GOVERNMENT_CIVIC_POINTS_BASE")) or 2

    R.dlcs_installed = installed_dlcs(game_dir)
    R.owned = set(R.dlcs_installed)
    cache[game_dir] = R
    return R
end

-- the DLCs owned (the names the game's host_has_dlc takes); nil: every one installed
function rules.set_owned(R, names)
    R.owned = set(names or R.dlcs_installed)
end

-- ---------------------------------------------------------------------------------------------
-- triggers and requirement lists

-- the configuration a design gives the government triggers (SEthicGovernmentConfiguration::
-- CreateWithDesignAndDefaultCountryType [V]): its ethics, authority, civics, origin, country
-- type, species class and archetype, graphical culture, traits
function rules.config(R, d)
    local civics = set(d.civics)
    local cls = R.class[d.species and d.species.class or ""]
    return {
        ethics = set(d.ethics), authority = d.authority, civics = civics, origin = d.origin,
        country_type = "default", species_class = d.species and d.species.class,
        species_archetype = cls and cls.archetype, graphical_culture = d.graphical_culture,
        traits = set(d.species and d.species.traits), design = d,
    }
end

local function is_gestalt(cfg)
    return cfg.ethics.ethic_gestalt_consciousness or cfg.authority == "auth_hive_mind" or cfg.authority == "auth_machine_intelligence"
end

-- a plain trigger block (playable, selectable): true/false. Unknown triggers are false and are
-- listed in R.unknown_triggers [I: the game's script layer evaluates them]
function rules.trigger(R, block, cfg, depth)
    depth = depth or 0
    if block == nil then
        return true
    end
    if type(block) == "string" then
        return block ~= "no"
    end
    cfg = cfg or { ethics = {}, civics = {}, traits = {} }
    local test
    local function all(b)
        for _, e in ipairs(b) do
            if e.op and e.key and not test(e.key.text, e.value.text and strip(e.value.text) or e.value, e.op) then
                return false
            end
        end
        return true
    end
    local function any(b)
        for _, e in ipairs(b) do
            if e.op and e.key and test(e.key.text, e.value.text and strip(e.value.text) or e.value, e.op) then
                return true
            end
        end
        return false
    end
    local function yes(v)
        return v == "yes"
    end
    test = function(k, v)
        if k == "AND" or k == "this" or k == "owner" or k == "from" then
            return type(v) == "table" and all(v)
        elseif k == "OR" then
            return type(v) == "table" and any(v)
        elseif k == "NOT" or k == "NOR" then
            return type(v) == "table" and not any(v)
        elseif k == "NAND" then
            return type(v) == "table" and not all(v)
        elseif k == "always" then
            return yes(v)
        elseif k == "host_has_dlc" or k == "has_dlc" then
            return R.owned[v] == true
        elseif k == "has_global_flag" or k == "has_country_flag" then
            return false
        elseif k == "is_nomadic" or k == "is_wilderness_empire" or k == "is_ai" then
            return not yes(v)
        elseif k == "is_gestalt" then
            return (is_gestalt(cfg) and true or false) == yes(v)
        elseif k == "is_hive_empire" then
            return (cfg.authority == "auth_hive_mind") == yes(v)
        elseif k == "is_machine_empire" then
            return (cfg.authority == "auth_machine_intelligence") == yes(v)
        elseif k == "has_ethic" then
            return cfg.ethics[v] == true
        elseif k == "has_civic" or k == "has_valid_civic" then
            return cfg.civics[v] == true
        elseif k == "has_authority" then
            return cfg.authority == v
        elseif k == "has_origin" then
            return cfg.origin == v
        elseif k == "is_species_class" then
            return cfg.species_class == v
        elseif k == "has_trait" then
            return cfg.traits[v] == true
        end
        local st = R.scripted_triggers[k]
        if st and depth < 16 then
            local r = rules.trigger(R, st, cfg, depth + 1)
            if type(v) == "string" and v == "no" then
                return not r
            end
            return r
        end
        R.unknown_triggers = R.unknown_triggers or {}
        R.unknown_triggers[k] = true
        return false
    end
    return all(block)
end

-- the value a requirement list's key tests, as a set or a value
local function config_values(cfg, key)
    if key == "ethics" then
        return cfg.ethics
    elseif key == "civics" then
        return cfg.civics
    elseif key == "traits" then
        return cfg.traits
    end
    local v
    if key == "authority" then
        v = cfg.authority
    elseif key == "origin" then
        v = cfg.origin
    elseif key == "country_type" then
        v = cfg.country_type
    elseif key == "species_class" then
        v = cfg.species_class
    elseif key == "species_archetype" then
        v = cfg.species_archetype
    elseif key == "graphical_culture" then
        v = cfg.graphical_culture
    end
    return v and { [v] = true } or {}
end

-- a list block (`value = x`, OR, NOT, NOR, text) on a set of values
local function list_ok(block, have)
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text
            if k == "value" then
                if not have[strip(e.value.text)] then
                    return false
                end
            elseif k == "OR" or k == "NOT" or k == "NOR" or k == "AND" then
                local vals = fields(e.value, "value")
                local hit = 0
                for _, v in ipairs(vals) do
                    if have[v] then
                        hit = hit + 1
                    end
                end
                if k == "OR" and hit == 0 then
                    return false
                elseif (k == "NOT" or k == "NOR") and hit > 0 then
                    return false
                elseif k == "AND" and hit < #vals then
                    return false
                end
            end
        end
    end
    return true
end

-- a requirement list (common/governments/99_README_GOVERNMENT.txt: potential, possible): true
-- when the configuration meets it
function rules.requirements(R, block, cfg)
    if type(block) ~= "table" then
        return true
    end
    local function eval(b, mode)
        local results = {}
        for _, e in ipairs(b) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local k = e.key.text
                local r
                if k == "AND" then
                    r = eval(e.value, "and")
                elseif k == "OR" then
                    r = eval(e.value, "or")
                elseif k == "NOT" or k == "NOR" then
                    r = not eval(e.value, "or")
                else
                    r = list_ok(e.value, config_values(cfg, k))
                end
                results[#results + 1] = r
            end
        end
        if mode == "or" then
            for _, r in ipairs(results) do
                if r then
                    return true
                end
            end
            return #results == 0
        end
        for _, r in ipairs(results) do
            if not r then
                return false
            end
        end
        return true
    end
    return eval(block, "and")
end

-- ---------------------------------------------------------------------------------------------
-- the default design

-- CEmpireDesign("default") with its species' fallbacks, as the creator opens a new design
-- [I: the first portrait of the first category, the game's frames: Humanoid, Prosperous
-- Unification, Organic, Continental, Humanoid name list, Mammalian ships]
function rules.default_design(R)
    local first = rules.category_portraits(R, R.portrait_categories[1] and R.portrait_categories[1].key or "humanoids")[1]
    local d = {
        key = "", name = "", adjective = "", ship_prefix = "", spawn_enabled = "yes",
        species = {
            class = first and first.class or "HUM", portrait = first and first.portrait or "human",
            name = "", plural = "", adjective = "", name_list = "HUM1", gender = "not_set", traits = {},
        },
        authority = nil, government = nil, civics = {}, ethics = {}, origin = "origin_default",
        room = "", planet_name = "", planet_class = "pc_continental", system_name = "", initializer = "",
        graphical_culture = "mammalian_01", city_graphical_culture = "mammalian_01",
        -- the flag: the game rolls one (CEmpireDesign::RandomizeFlag, its random stream); this is
        -- one it rolled, as its Save wrote it [I]
        empire_flag = {
            icon = { category = "domination", file = "domination_11.dds" },
            background = { category = "backgrounds", file = "circle.dds" },
            colors = { "orange", "indigo", "black", "orange", "orange", "indigo" },
        },
        -- the ruler: the game's Save of a new design: human_female_04 (Phenotype 4 / 5), clothes 4
        -- (Clothing 5 / 7) [V]
        ruler = { name = "", gender = "female", portrait = first and first.portrait or "human", texture = 0,
            attachment = 0, clothes = 4, phenotype = 3, leader_class = "official", traits = {},
            ruler_title = "", ruler_title_female = "", heir_title = "", heir_title_female = "", biography = "" },
        room = "default_room",
        biography = "", literal = {},
    }
    rules.apply_class_traits(R, d)
    local po = rules.portrait_options(R, d)
    d.ruler.portrait = po.phenotypes[po.phenotype] or d.ruler.portrait
    return d
end

-- the species class's forced traits (trait = in common/species_classes: trait_organic ...) and
-- the origin's and civics' (`traits = { trait = }`) on the design's species, the others kept
function rules.apply_class_traits(R, d)
    local forced = {}
    for _, t in ipairs(rules.required_traits(R, d)) do
        forced[t] = true
    end
    -- drop forced traits of other classes / origins (those not chosen freely: cost 0, not initial)
    local keep = {}
    for _, t in ipairs(d.species.traits) do
        local def = R.trait[t]
        local auto = def and (not def.initial)
        if forced[t] or not auto then
            keep[#keep + 1] = t
        end
    end
    for t in pairs(forced) do
        if not contains(keep, t) then
            table.insert(keep, 1, t)
        end
    end
    d.species.traits = keep
end

-- NEmpireDesignEditor::FindRequiredTraits [I]: the class's traits, the origin's, the civics'
function rules.required_traits(R, d)
    local out = {}
    local cls = R.class[d.species.class or ""]
    for _, t in ipairs(cls and cls.traits or {}) do
        out[#out + 1] = t
    end
    local o = R.civic[d.origin or ""]
    for _, t in ipairs(o and o.traits or {}) do
        out[#out + 1] = t
    end
    for _, c in ipairs(d.civics or {}) do
        local g = R.civic[c]
        for _, t in ipairs(g and g.traits or {}) do
            out[#out + 1] = t
        end
    end
    local a = R.authority[d.authority or ""]
    for _, t in ipairs(a and a.traits or {}) do
        out[#out + 1] = t
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- portraits (CSpeciesPortraitEditor)

-- a category's portraits: { { portrait, class, set } } in the sets' order (plain ones, then
-- conditional ones whose `playable` holds)
function rules.category_portraits(R, category)
    local cat
    for _, c in ipairs(R.portrait_categories) do
        if c.key == category or c.name == category then
            cat = c
        end
    end
    local out = {}
    for _, sk in ipairs(cat and cat.sets or {}) do
        local s = R.portrait_set[sk]
        if s then
            for _, p in ipairs(s.portraits) do
                out[#out + 1] = { portrait = p, class = s.class, set = sk }
            end
            -- (conditional ones whose `playable` fails are listed locked: the game shows unowned
            -- content unless Hide Unowned Content is ticked)
            for _, cp in ipairs(s.conditional) do
                local ok = rules.trigger(R, cp.playable)
                for _, p in ipairs(cp.portraits) do
                    out[#out + 1] = { portrait = p, class = s.class, set = sk, locked = not ok or nil }
                end
            end
        end
    end
    -- the playable ones first, then the locked ones, each in order [V: the game's Save of a new
    -- design has `human` (the humans set's first), not the cybernetic set's that comes before it;
    -- its frame shows the locked portraits in the last row]
    local open, locked = {}, {}
    for _, p in ipairs(out) do
        table.insert(p.locked and locked or open, p)
    end
    for _, p in ipairs(locked) do
        open[#open + 1] = p
    end
    return open
end

-- the categories the editor lists (CSpeciesPortraitEditor::IsCategoryEligible [I]: its class is
-- playable and the category has portraits)
function rules.portrait_categories(R)
    local out = {}
    for _, c in ipairs(R.portrait_categories) do
        local ps = rules.category_portraits(R, c.key)
        local cls = R.class[c.name or ""] or (ps[1] and R.class[ps[1].class])
        local playable = cls and rules.trigger(R, cls.playable)
        if #ps > 0 and playable ~= false and rules.trigger(R, c.playable) then
            out[#out + 1] = { key = c.key, name = c.name, count = #ps }
        end
    end
    return out
end

function rules.set_portrait(R, d, portrait, class)
    d.species.portrait = portrait
    if class and class ~= d.species.class then
        d.species.class = class
        rules.apply_class_traits(R, d)
    end
    d.ruler.portrait = portrait
end

-- the portraits' definitions (gfx/portraits/portraits: `portraits = { name = {...} }` and
-- `portrait_groups = { name = { default game_setup = { add = { trigger portraits } } } }`) and
-- the asset selectors (gfx/portraits/asset_selectors), read once
local function portrait_db(R)
    if R.portrait_db then
        return R.portrait_db
    end
    local source = require("stellar.script.source")
    local db = { portraits = {}, groups = {}, selectors = {} }
    for _, f in ipairs(source.files(R.ctx.game_dir, "gfx/portraits/portraits", "txt") or {}) do
        for _, e in ipairs(source.parse(R.ctx.game_dir, f) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local into = e.key.text == "portraits" and db.portraits or e.key.text == "portrait_groups" and db.groups
                for _, x in ipairs(into and e.value or {}) do
                    if x.op and x.key and type(x.value) == "table" then
                        into[x.key.text] = x.value
                    end
                end
            end
        end
    end
    for _, f in ipairs(source.files(R.ctx.game_dir, "gfx/portraits/asset_selectors", "txt") or {}) do
        for _, e in ipairs(source.parse(R.ctx.game_dir, f) or {}) do
            if e.op and e.key and type(e.value) == "table" then
                db.selectors[e.key.text] = e.value
            end
        end
    end
    R.portrait_db = db
    return db
end

-- the distinct texture files an asset selector names (its options) [I: the editor's spinners
-- step through them, CEmpireRulerEditor::ChangeOutfitOption]
local function selector_options(sel)
    local seen, n = {}, 0
    local function walk(t, depth)
        for _, e in ipairs(type(t) == "table" and t or {}) do
            local s = (e.text and e.text) or (e.op and e.key and e.key.text)
            if s and s:find("%.dds") and not seen[s] then
                seen[s] = true
                n = n + 1
            end
            if e.op and type(e.value) == "table" and depth < 5 then
                if e.value.text and e.value.text:find("%.dds") and not seen[e.value.text] then
                    seen[e.value.text] = true
                    n = n + 1
                elseif not e.value.text then
                    walk(e.value, depth + 1)
                end
            end
        end
    end
    walk(sel, 0)
    return math.max(1, n)
end

-- the ruler's portrait options: { phenotypes = { portrait names }, textures, attachments, clothes,
-- attachment_label } for the design's portrait (a group: its game_setup portraits for the
-- ruler's gender) [I]
function rules.portrait_options(R, d)
    local db = portrait_db(R)
    local key = d.species.portrait or ""
    local list = {}
    local g = db.groups[key]
    if g then
        local gs = raw_field(g, "game_setup")
        for _, add in ipairs(fields(gs, "add")) do
            if type(add) == "table" then
                local trig = raw_field(add, "trigger")
                local ruler = trig and raw_field(trig, "ruler")
                local ok = true
                if ruler then
                    ok = false
                    local function scan(t)
                        for _, e in ipairs(t) do
                            if e.op and e.key and e.key.text == "gender" and strip(e.value.text) == d.ruler.gender then
                                ok = true
                            elseif e.op and type(e.value) == "table" and not e.value.text then
                                scan(e.value)
                            end
                        end
                    end
                    scan(ruler)
                end
                if ok then
                    for _, p in ipairs(tokens(raw_field(add, "portraits"))) do
                        list[#list + 1] = p
                    end
                end
            end
        end
    end
    if #list == 0 then
        list = { key }
    end
    local i = math.max(1, math.min(#list, (d.ruler.phenotype or 0) + 1))
    local p = db.portraits[list[i]] or {}
    local tex = tokens(raw_field(p, "character_textures"))
    local att = field(p, "attachment_selector")
    local clo = field(p, "clothes_selector")
    return {
        phenotypes = list, phenotype = i,
        textures = math.max(1, #tex),
        attachments = (att and att ~= "no_texture" and db.selectors[att]) and selector_options(db.selectors[att]) or 1,
        clothes = (clo and db.selectors[clo]) and selector_options(db.selectors[clo]) or 1,
        attachment_label = field(p, "custom_attachment_label"),
    }
end

-- the ruler's titles (the government type's ruler_title / _female, heir_title / _female)
-- [I: with no authority chosen the game's frame shows President: gov_representative_democracy's]
function rules.ruler_titles(R, d)
    local g = R.governments[d.government or "gov_representative_democracy"] or {}
    local b = g.block or {}
    local a = R.authority[d.authority or ""]
    local heir = a and field(a.block, "has_heir") == "yes"
    return {
        ruler = field(b, "ruler_title"), ruler_female = field(b, "ruler_title_female"),
        heir = heir and field(b, "heir_title") or nil, heir_female = heir and field(b, "heir_title_female") or nil,
    }
end

-- ---------------------------------------------------------------------------------------------
-- ethics (CEmpireEthicsGovEditor::OnClickEthic, CCountryEthos::CanExchangeEthic / AddEthic [V])

function rules.ethic_cost(R, d)
    local s = 0
    for _, k in ipairs(d.ethics) do
        s = s + (R.ethic[k] and R.ethic[k].cost or 0)
    end
    return s
end

function rules.ethic_points_left(R, d)
    return R.ethic_points - rules.ethic_cost(R, d)
end

function rules.ethic_playable(R, d, key)
    local e = R.ethic[key]
    return e and rules.trigger(R, e.playable, rules.config(R, d))
end

-- whether the ethic can be added: its cost within the points the other categories leave
function rules.can_add_ethic(R, d, key)
    local e = R.ethic[key]
    if not e or contains(d.ethics, key) then
        return false
    end
    local left = R.ethic_points
    for _, k in ipairs(d.ethics) do
        local o = R.ethic[k]
        if o and o.category ~= e.category then
            left = left - o.cost
        end
    end
    return e.cost <= left and rules.ethic_playable(R, d, key) ~= false
end

-- a click: a chosen ethic is removed; another is added in place of its category's
function rules.click_ethic(R, d, key)
    local i = contains(d.ethics, key)
    if i then
        table.remove(d.ethics, i)
    elseif rules.can_add_ethic(R, d, key) then
        local e = R.ethic[key]
        for j = #d.ethics, 1, -1 do
            local o = R.ethic[d.ethics[j]]
            if o and o.category == e.category then
                table.remove(d.ethics, j)
            end
        end
        -- kept in the ethics' database order (the game's Save writes ethic_fanatic_egalitarian
        -- before ethic_xenophile, chosen the other way round) [V]
        d.ethics[#d.ethics + 1] = key
        local index = {}
        for i, x in ipairs(R.ethics) do
            index[x.key] = i
        end
        table.sort(d.ethics, function(x, y)
            return (index[x] or 0) < (index[y] or 0)
        end)
    else
        return false
    end
    rules.after_government_change(R, d)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- authority, civics, government type

function rules.authority_listed(R, d, a)
    return rules.requirements(R, a.potential, rules.config(R, d)) and a.key ~= "auth_ancient_machine_intelligence"
end

function rules.authority_ok(R, d, key)
    local a = R.authority[key]
    return a and rules.requirements(R, a.possible, rules.config(R, d)) and rules.trigger(R, a.playable, rules.config(R, d))
end

function rules.authorities(R, d)
    local out = {}
    local cfg = rules.config(R, d)
    for _, a in ipairs(R.authorities) do
        if rules.requirements(R, a.potential, cfg) and rules.trigger(R, a.playable, cfg) ~= false then
            out[#out + 1] = a
        end
    end
    return out
end

function rules.click_authority(R, d, key)
    if not rules.authority_ok(R, d, key) then
        return false
    end
    d.authority = key
    rules.after_government_change(R, d)
    return true
end

function rules.civic_cost(R, d)
    local s = 0
    for _, c in ipairs(d.civics) do
        s = s + (R.civic[c] and R.civic[c].cost or 1)
    end
    return s
end

function rules.civic_points_left(R, d)
    return R.civic_points - rules.civic_cost(R, d)
end

-- the civics the list shows: those whose potential and possible hold with the design as it is,
-- and the chosen ones [I: the game's frame lists no civic whose ethics are missing (Agrarian
-- Idyll, Beacon of Liberty) before ethics are chosen]
function rules.civic_list(R, d)
    local out = {}
    local cfg = rules.config(R, d)
    local chosen = set(d.civics)
    for _, g in ipairs(R.civics) do
        local cfg_without = cfg
        if chosen[g.key] then
            cfg_without = rules.config(R, d)
            cfg_without.civics[g.key] = nil
        end
        if chosen[g.key] or (g.pickable and rules.requirements(R, g.potential, cfg) and rules.requirements(R, g.possible, cfg_without)
            and rules.trigger(R, g.playable, cfg) ~= false) then
            out[#out + 1] = g
        end
    end
    table.sort(out, function(a, b)
        return a.key < b.key
    end)
    return out
end

function rules.civic_ok(R, d, key)
    local g = R.civic[key]
    if not g then
        return false
    end
    local cfg = rules.config(R, d)
    return rules.requirements(R, g.potential, cfg) and rules.requirements(R, g.possible, cfg)
        and rules.trigger(R, g.playable, cfg)
end

function rules.click_civic(R, d, key)
    local i = contains(d.civics, key)
    if i then
        table.remove(d.civics, i)
    else
        local g = R.civic[key]
        if not g or rules.civic_points_left(R, d) < g.cost or not rules.civic_ok(R, d, key) then
            return false
        end
        d.civics[#d.civics + 1] = key
    end
    rules.after_government_change(R, d)
    return true
end

-- CEmpireEthicsGovEditor::AssignGovernmentType [I]: the government type with the highest weight
-- whose `possible` holds (weights not read: the first possible in file order of the civic, ethic
-- then authority governments)
function rules.government(R, d)
    local cfg = rules.config(R, d)
    local best
    for _, k in ipairs(R.government_order) do
        local g = R.governments[k]
        if g and g.possible and rules.trigger(R, g.possible, cfg) then
            best = best or k
        end
    end
    return best
end

function rules.after_government_change(R, d)
    -- an authority or civic no longer possible stays (the editor marks it invalid) [I]
    d.government = rules.government(R, d)
    rules.apply_class_traits(R, d)
end

-- ---------------------------------------------------------------------------------------------
-- origins (CEmpireOriginEditor)

-- the origins the editor lists (potential), the playable ones (their DLC owned) first, then the
-- others, each in file order [I: the game's frame: Prosperous Unification, then Overlord's
-- origins (owned) before the base game's later ones]
function rules.origin_list(R, d)
    local owned, other = {}, {}
    local cfg = rules.config(R, d)
    for _, g in ipairs(R.origins) do
        if g.pickable and rules.requirements(R, g.potential, cfg) then
            if rules.trigger(R, g.playable, cfg) then
                owned[#owned + 1] = g
            else
                other[#other + 1] = g
            end
        end
    end
    for _, g in ipairs(other) do
        owned[#owned + 1] = g
    end
    return owned
end

-- a graphical culture's name: the species class that uses it ("Humanoid" for humanoid_01: the
-- game's "$CULTURE$ City", CITY_GRAPHICS_NAME) [I]
function rules.culture_class(R, culture)
    local best
    for k, c in pairs(R.class) do
        if c.culture == culture and (not best or k < best) and not k:match("^PRE_") then
            best = k
        end
    end
    return best
end

function rules.origin_ok(R, d, key)
    local g = R.civic[key]
    if not g then
        return false
    end
    local cfg = rules.config(R, d)
    return rules.requirements(R, g.possible, cfg) and rules.trigger(R, g.playable, cfg)
end

function rules.select_origin(R, d, key)
    if not R.civic[key] then
        return false
    end
    d.origin = key
    rules.after_government_change(R, d)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- species traits (CSpeciesTraitsEditor, CTraitSet::CanAddTrait, IsSpeciesDesignTraitsValid [V])

function rules.archetype(R, d)
    local cls = R.class[d.species.class or ""]
    return R.archetype[cls and cls.archetype or "BIOLOGICAL"] or { points = 2, picks = 5 }
end

function rules.trait_points(R, d)
    local cls = R.class[d.species.class or ""]
    return (cls and cls.points) or rules.archetype(R, d).points
end

function rules.trait_picks(R, d)
    local cls = R.class[d.species.class or ""]
    return (cls and cls.picks) or rules.archetype(R, d).picks
end

function rules.trait_cost(R, d)
    local s = 0
    for _, t in ipairs(d.species.traits) do
        s = s + (R.trait[t] and R.trait[t].cost or 0)
    end
    return s
end

-- picks count the traits whose cost is not 0 (species_max_traits: "doesn't count those with cost == 0")
function rules.traits_picked(R, d)
    local n = 0
    for _, t in ipairs(d.species.traits) do
        if R.trait[t] and R.trait[t].cost ~= 0 then
            n = n + 1
        end
    end
    return n
end

function rules.trait_points_left(R, d)
    return rules.trait_points(R, d) - rules.trait_cost(R, d)
end

function rules.trait_picks_left(R, d)
    return rules.trait_picks(R, d) - rules.traits_picked(R, d)
end

local function trait_for_species(R, d, t)
    if contains(t.portraits, d.species.portrait) then
        return true
    end
    local cls = R.class[d.species.class or ""]
    local arch = cls and cls.archetype or "BIOLOGICAL"
    if #t.archetypes > 0 and not contains(t.archetypes, arch) then
        return false
    end
    if #t.classes > 0 and not contains(t.classes, d.species.class) then
        return false
    end
    return true
end

local function trait_for_government(R, d, t)
    if #t.allowed_origins > 0 and not contains(t.allowed_origins, d.origin) then
        return false
    end
    if contains(t.forbidden_origins, d.origin) then
        return false
    end
    local civ = set(d.civics)
    if #t.allowed_civics > 0 then
        local ok = false
        for _, c in ipairs(t.allowed_civics) do
            ok = ok or civ[c] == true
        end
        if not ok then
            return false
        end
    end
    for _, c in ipairs(t.forbidden_civics) do
        if civ[c] then
            return false
        end
    end
    return true
end

local function trait_for_ethics(R, d, t)
    local eth = set(d.ethics)
    if #t.allowed_ethics > 0 then
        local ok = false
        for _, e in ipairs(t.allowed_ethics) do
            ok = ok or eth[e] == true
        end
        if not ok then
            return false
        end
    end
    for _, e in ipairs(t.forbidden_ethics) do
        if eth[e] then
            return false
        end
    end
    return true
end

local function trait_for_planet(R, d, t)
    return #t.planet_classes == 0 or contains(t.planet_classes, d.planet_class)
end

-- CSpeciesTraitsEditor::ShouldShowTrait: initial, for the species (portrait override, archetype,
-- class), the origin and civics, the home world's class, the DLC
function rules.trait_shown(R, d, key)
    local t = R.trait[key]
    if not t or not t.initial then
        return false
    end
    if t.key:match("^trait_pc_.*_preference$") then
        return false
    end
    return trait_for_species(R, d, t) and trait_for_government(R, d, t) and trait_for_planet(R, d, t)
end

-- the list of traits the editor shows (its available list: not chosen ones), sorted as the game
-- sorts them [I: sorting_priority, then cost descending, then key]
function rules.trait_list(R, d)
    local out = {}
    for _, t in ipairs(R.traits) do
        if rules.trait_shown(R, d, t.key) and not contains(d.species.traits, t.key) and t.cost ~= 0 then
            out[#out + 1] = t
        end
    end
    table.sort(out, function(a, b)
        if (a.cost > 0) ~= (b.cost > 0) then
            return a.cost > 0
        end
        return a.key < b.key
    end)
    return out
end

-- CSpeciesTraitsEditor::CanAddTrait: shown, the ethics, picks (cost != 0), no opposite, not
-- chosen; points are not checked here (overspending is the design's error,
-- TOO_MANY_TRAIT_POINTS_USED, IsSpeciesDesignTraitsValid) [V]
function rules.can_add_trait(R, d, key)
    local t = R.trait[key]
    if not t or not rules.trait_shown(R, d, key) or not trait_for_ethics(R, d, t) then
        return false, "hidden"
    end
    if contains(d.species.traits, key) then
        return false, "ALREADY_HAVE_THIS_TRAIT"
    end
    if t.cost ~= 0 and rules.trait_picks_left(R, d) <= 0 then
        return false, "TOO_MANY_TRAITS"
    end
    for _, o in ipairs(t.opposites) do
        if contains(d.species.traits, o) then
            return false, "HAS_OPPOSITE_TRAIT"
        end
    end
    for _, s in ipairs(d.species.traits) do
        local st = R.trait[s]
        if st and contains(st.opposites, key) then
            return false, "HAS_OPPOSITE_TRAIT"
        end
    end
    return true
end

function rules.click_trait(R, d, key)
    local i = contains(d.species.traits, key)
    if i then
        if contains(rules.required_traits(R, d), key) then
            return false
        end
        table.remove(d.species.traits, i)
        return true
    end
    if not rules.can_add_trait(R, d, key) then
        return false
    end
    d.species.traits[#d.species.traits + 1] = key
    return true
end

-- ---------------------------------------------------------------------------------------------
-- ruler traits (CRulerTraitEditor)

function rules.ruler_classes(R, d)
    local a = R.authority[d.authority or ""]
    local pos = a and a.council and R.councilors[a.council]
    local out = {}
    if pos then
        for _, k in ipairs(tokens(raw_field(pos, "leader_class"))) do
            if R.leader_class[k] then
                out[#out + 1] = k
            end
        end
    else
        for _, l in ipairs(R.leader_classes) do
            if l.can_rule then
                out[#out + 1] = l.key
            end
        end
    end
    return out
end

function rules.ruler_trait_list(R, d)
    local out = {}
    for _, t in ipairs(R.ruler_traits) do
        if contains(t.leader_class, d.ruler.leader_class) and trait_for_government(R, d, t) then
            out[#out + 1] = t
        end
    end
    return out
end

function rules.ruler_points_left(R, d)
    local l = R.leader_class[d.ruler.leader_class or ""]
    local s = 0
    for _, t in ipairs(d.ruler.traits) do
        s = s + (R.trait[t] and R.trait[t].cost or 0)
    end
    return (l and l.points or 0) - s
end

function rules.click_ruler_trait(R, d, key)
    local i = contains(d.ruler.traits, key)
    if i then
        table.remove(d.ruler.traits, i)
        return true
    end
    local t = R.trait[key]
    if not t or (t.cost > 0 and t.cost > rules.ruler_points_left(R, d)) then
        return false
    end
    d.ruler.traits[#d.ruler.traits + 1] = key
    return true
end

function rules.set_ruler_class(R, d, key)
    if d.ruler.leader_class ~= key then
        d.ruler.leader_class = key
        d.ruler.traits = {}
    end
end

-- ---------------------------------------------------------------------------------------------
-- validation (IsEmpireDesignValid per editor type [V]: the checks and their texts' keys)

-- errors(R, d, editor_key) -> { { key = loc key, args = { NAME = value } } }
function rules.errors(R, d, editor)
    local out = {}
    local function add(key, args)
        out[#out + 1] = { key = key, args = args }
    end
    local cfg = rules.config(R, d)
    local sp = d.species
    if editor == "ruler_traits" then
        if rules.ruler_points_left(R, d) < 0 then
            add("GAMESETUP_LEADER_TOO_MANY_TRAIT_POINTS_USED")
        end
        if d.authority and not contains(rules.ruler_classes(R, d), d.ruler.leader_class) then
            add("GAMESETUP_LEADER_WRONG_CLASS_FOR_AUTHORITY")
        end
        for _, t in ipairs(d.ruler.traits) do
            local def = R.trait[t]
            if def and not contains(def.leader_class, d.ruler.leader_class) then
                add("GAMESETUP_LEADER_WRONG_CLASS_FOR_TRAIT", { TRAIT = t })
            end
        end
    elseif editor == "ruler" then
        if (d.ruler.name or "") == "" then
            add("GAMESETUP_LEADER_NAME_MISSING")
        end
        local cls = R.class[sp.class or ""]
        if cls and cls.gender and not (d.ruler.gender == "male" or d.ruler.gender == "female") then
            add("GAMESETUP_LEADER_GENDER_MISSING")
        end
    elseif editor == "names" then
        if (sp.name or "") == "" or (sp.plural or "") == "" or (sp.adjective or "") == "" then
            add("EMPIRE_DESIGN_SPECIES_NAME_MISSING_FIELD")
        end
        if (d.name or "") == "" then
            add("EMPIRE_DESIGN_MISSING_EMPIRE_NAME")
        end
        if (d.adjective or "") == "" then
            add("EMPIRE_DESIGN_MISSING_EMPIRE_ADJECTIVE")
        end
    elseif editor == "name_list" then
        if not R.name_list[sp.name_list or ""] then
            add("EMPIRE_DESIGN_MISSING_NAME_LIST")
        end
    elseif editor == "homeworld" then
        local pc = R.planet_class[d.planet_class or ""]
        if not pc then
            add("EMPIRE_DESIGN_MISSING_PLANET_CLASS")
        elseif not pc.colonizable then
            add("EMPIRE_DESIGN_INVALID_PLANET_CLASS")
        end
        if (d.planet_name or "") == "" then
            add("EMPIRE_DESIGN_MISSING_HOME_WORLD_NAME")
        end
        if (d.system_name or "") == "" then
            add("EMPIRE_DESIGN_MISSING_HOME_SYSTEM_NAME")
        end
        if (d.initializer or "") ~= "" and not R.initializer[d.initializer] then
            add("EMPIRE_DESIGN_INVALID_INITIALIZER", { NAME = d.initializer })
        end
    elseif editor == "origin" then
        local o = R.civic[d.origin or ""]
        if not o or not o.is_origin then
            add("GAMESETUP_COUNTRY_INVALID_ORIGIN")
        elseif not rules.requirements(R, o.possible, cfg) then
            add("GAMESETUP_COUNTRY_INVALID_ORIGIN")
        elseif not rules.trigger(R, o.playable, cfg) then
            add("GAMESETUP_CONTENT_NOT_PLAYABLE", { CONTENT = d.origin })
        end
    elseif editor == "ethics" then
        local cost = rules.ethic_cost(R, d)
        if cost > R.ethic_points then
            add("NOT_ENOUGH_ETHIC_POINTS")
        end
        if cost < R.min_ethic_points then
            add("CUSTOMIZATION_TOO_FEW_ETHIC_POINTS")
        end
        for _, e in ipairs(d.ethics) do
            if not rules.ethic_playable(R, d, e) then
                add("GAMESETUP_CONTENT_NOT_PLAYABLE", { CONTENT = e })
            end
        end
        if not d.authority or not R.authority[d.authority] or not rules.requirements(R, R.authority[d.authority].possible, cfg) then
            add("GAMESETUP_COUNTRY_INVALID_AUTHORITY")
        elseif not rules.trigger(R, R.authority[d.authority].playable, cfg) then
            add("GAMESETUP_CONTENT_NOT_PLAYABLE", { CONTENT = d.authority })
        end
        if rules.civic_cost(R, d) > R.civic_points then
            add("GAMESETUP_COUNTRY_CIVICS_TOO_EXPENSIVE")
        end
        for _, c in ipairs(d.civics) do
            local g = R.civic[c]
            if not g or not rules.requirements(R, g.potential, cfg) or not rules.requirements(R, g.possible, cfg) then
                add("GAMESETUP_COUNTRY_CIVIC_INVALID", { CIVIC = c })
            elseif not rules.trigger(R, g.playable, cfg) then
                add("GAMESETUP_CONTENT_NOT_PLAYABLE", { CONTENT = c })
            end
        end
        local cls = R.class[sp.class or ""]
        if cls and not rules.requirements(R, cls.possible, cfg) then
            add("GAMESETUP_SPECIES_CLASS_GOVERNMENT_NOT_ALLOWED", { CLASS = sp.class })
        end
    elseif editor == "traits" then
        local seen = {}
        for _, t in ipairs(sp.traits) do
            if seen[t] then
                add("DUPLICATE_TRAIT", { TRAIT = t })
            end
            seen[t] = true
        end
        for _, t in ipairs(rules.required_traits(R, d)) do
            if not seen[t] then
                add("REQUIRED_TRAIT_MISSING", { TRAIT = t })
            end
        end
        for _, t in ipairs(sp.traits) do
            local def = R.trait[t]
            if def and not contains(rules.required_traits(R, d), t) then
                if not def.initial then
                    add("TRAIT_INVALID_INITIAL", { TRAIT = t })
                elseif not trait_for_species(R, d, def) or not trait_for_government(R, d, def)
                    or not trait_for_ethics(R, d, def) or not trait_for_planet(R, d, def) then
                    add("TRAIT_INVALID_INITIAL", { TRAIT = t })
                end
                for _, o in ipairs(def.opposites) do
                    if seen[o] then
                        add("HAS_OPPOSITE_TRAIT", { TRAIT = o })
                    end
                end
            end
        end
        if rules.trait_points_left(R, d) < 0 then
            add("TOO_MANY_TRAIT_POINTS_USED")
        end
        if rules.trait_picks_left(R, d) < 0 then
            add("TOO_MANY_TRAITS")
        end
    elseif editor == "portrait" then
        if not sp.portrait or sp.portrait == "" then
            add("EMPIRE_DESIGN_NO_PORTRAIT")
        end
    elseif editor == "city" or editor == "shipset" then
        local k = editor == "city" and d.city_graphical_culture or d.graphical_culture
        local g = R.culture[k or ""]
        if not g then
            add("EMPIRE_DESIGN_INVALID_GFX_CULTURE")
        elseif not rules.trigger(R, g.selectable, cfg) then
            add("EMPIRE_DESIGN_UNAVAILABLE_GFX_CULTURE")
        end
    end
    return out
end

-- every editor's errors: { [editor key] = errors } and whether the design is valid
function rules.validate(R, d)
    local all, ok = {}, true
    for _, e in ipairs(rules.EDITORS) do
        local errs = rules.errors(R, d, e.key)
        all[e.key] = errs
        if #errs > 0 then
            ok = false
        end
    end
    return ok, all
end

-- ---------------------------------------------------------------------------------------------
-- the design as the game writes a user's design (user_empire_designs_v3.4.txt, read from the
-- game's own Save of a design made in its creator [V]): names as `{ key literal = yes }` blocks
-- (a localisation key without literal), the empire adjective through %ADJ%, the ruler's name in
-- full_names, the flag's six colours. engine/newgame reads it as a design block (ng-start).

local function q(s)
    s = tostring(s or "")
    -- (a quote in the player's text would end the string: kept out, as an apostrophe [I])
    return '"' .. (s:gsub('"', "'")) .. '"'
end

function rules.to_text(d, key)
    local lit = d.literal or {}
    key = key or (d.key ~= "" and d.key) or (d.name ~= "" and d.name) or "user_design"
    local L = {}
    local function w(s)
        L[#L + 1] = s
    end
    local function name(indent, k, v, literal)
        w(indent .. k .. "=")
        w(indent .. "{")
        w(indent .. "\tkey=" .. q(v))
        if literal then
            w(indent .. "\tliteral=yes")
        end
        w(indent .. "}")
    end
    w(q(key) .. "=")
    w("{")
    w("\tkey=" .. q(key))
    name("\t", "ship_prefix", d.ship_prefix or "", lit.ship_prefix and (d.ship_prefix or "") ~= "")
    local sp = d.species
    w("\tspecies=")
    w("\t{")
    w("\t\tclass=" .. q(sp.class))
    w("\t\tportrait=" .. q(sp.portrait))
    name("\t\t", "species_name", sp.name, lit.species_name)
    name("\t\t", "species_plural", sp.plural, lit.species_plural)
    name("\t\t", "species_adjective", sp.adjective, lit.species_adjective)
    w("\t\tname_list=" .. q(sp.name_list))
    w("\t\tgender=" .. (sp.gender or "not_set"))
    for _, t in ipairs(sp.traits or {}) do
        w("\t\ttrait=" .. q(t))
    end
    w("\t}")
    name("\t", "name", d.name, lit.name)
    if lit.adjective then
        w("\tadjective=")
        w("\t{")
        w("\t\tkey=\"%ADJ%\"")
        w("\t\tvariables=")
        w("\t\t{")
        w("\t\t\t{")
        w("\t\t\t\tkey=\"adjective\"")
        name("\t\t\t\t", "value", d.adjective, true)
        w("\t\t\t}")
        w("\t\t}")
        w("\t}")
    else
        name("\t", "adjective", d.adjective, false)
    end
    if d.authority then
        w("\tauthority=" .. q(d.authority))
    end
    if #(d.civics or {}) > 0 then
        local cv = {}
        for _, c in ipairs(d.civics) do
            cv[#cv + 1] = q(c)
        end
        w("\tcivics={ " .. table.concat(cv, " ") .. " }")
    end
    if d.government then
        w("\tgovernment=" .. q(d.government))
    end
    w("\tis_nomadic=no")
    name("\t", "planet_name", d.planet_name, lit.planet_name)
    w("\tplanet_class=" .. q(d.planet_class))
    w("\tship_size=\"civilian_arkship_tier_1\"")
    name("\t", "system_name", d.system_name, lit.system_name)
    w("\tinitializer=" .. q(d.initializer or ""))
    w("\tgraphical_culture=" .. q(d.graphical_culture))
    w("\tcity_graphical_culture=" .. q(d.city_graphical_culture))
    local f = d.empire_flag or {}
    w("\tempire_flag=")
    w("\t{")
    w("\t\ticon=")
    w("\t\t{")
    w("\t\t\tcategory=" .. q(f.icon and f.icon.category))
    w("\t\t\tfile=" .. q(f.icon and f.icon.file))
    w("\t\t}")
    w("\t\tbackground=")
    w("\t\t{")
    w("\t\t\tcategory=" .. q(f.background and f.background.category or "backgrounds"))
    w("\t\t\tfile=" .. q(f.background and f.background.file))
    w("\t\t}")
    w("\t\tcolors=")
    w("\t\t{")
    for _, c in ipairs(f.colors or {}) do
        w("\t\t\t" .. q(c))
    end
    w("\t\t}")
    w("\t}")
    local r = d.ruler or {}
    w("\truler=")
    w("\t{")
    w("\t\tgender=" .. (r.gender or "female"))
    w("\t\tname=")
    w("\t\t{")
    name("\t\t\t", "full_names", r.name or "", lit.ruler_name)
    w("\t\t}")
    w("\t\tportrait=" .. q(r.portrait or sp.portrait))
    w("\t\ttexture=" .. tostring(r.texture or 0))
    w("\t\tevolution_mask=0")
    w("\t\tattachment=" .. tostring(r.attachment or 0))
    w("\t\tclothes=" .. tostring(r.clothes or 0))
    for _, t in ipairs(r.traits or {}) do
        w("\t\ttrait=" .. q(t))
    end
    w("\t\tleader_class=" .. q(r.leader_class or "official"))
    w("\t}")
    w("\tspawn_as_fallen=no")
    w("\tignore_portrait_duplication=no")
    w("\troom=" .. q((d.room and d.room ~= "") and d.room or "default_room"))
    w("\tspawn_enabled=" .. (d.spawn_enabled or "yes"))
    for _, e in ipairs(d.ethics or {}) do
        w("\tethic=" .. q(e))
    end
    w("\torigin=" .. q(d.origin))
    w("}")
    return table.concat(L, "\n") .. "\n"
end

-- the design's block (the parse tree of its text: what empires.lua's designs hold)
function rules.to_block(d, key)
    local pdx = require("pdxscript")
    local tree = pdx.parse(rules.to_text(d, key), "creator")
    for _, e in ipairs(tree or {}) do
        if e.op and e.key and type(e.value) == "table" then
            return e.value, e.key.text
        end
    end
    return nil
end

-- a design table from a prescripted country's block (prescripted_countries/) or a user design's
-- (user_empire_designs_v3.4.txt: names as `{ key literal = yes }` blocks): what the creator
-- edits when the player picks Edit on it
function rules.from_block(b, key)
    local literal = {}
    local function f(blk, k)
        local v = raw_field(blk, k)
        if type(v) == "string" then
            return strip(v)
        end
        -- a name block: its key (the template's variable for %ADJ%), literal or a key
        if type(v) == "table" and (raw_field(v, "key") or raw_field(v, "full_names")) then
            local n = raw_field(v, "full_names") or v
            local kk = strip(raw_field(n, "key"))
            if kk == "%ADJ%" then
                for _, var in ipairs(type(raw_field(v, "variables")) == "table" and raw_field(v, "variables") or {}) do
                    local val = type(var) == "table" and raw_field(var, "value")
                    if type(val) == "table" then
                        n, kk = val, strip(raw_field(val, "key"))
                    end
                end
            end
            if field(n, "literal") == "yes" then
                literal[k] = true
            end
            return kk
        end
        return v
    end
    local sp = f(b, "species") or {}
    local fl = f(b, "empire_flag") or {}
    local ru = f(b, "ruler") or {}
    local function part(t, k)
        local p = f(t, k)
        return type(p) == "table" and { category = f(p, "category"), file = f(p, "file") } or nil
    end
    local d = {
        key = key or "", name = f(b, "name") or "", adjective = f(b, "adjective") or "",
        ship_prefix = f(b, "ship_prefix") or "", spawn_enabled = f(b, "spawn_enabled") or "yes",
        literal = literal,
        species = {
            class = f(sp, "class") or "HUM", portrait = f(sp, "portrait") or "",
            name = f(sp, "name") or f(sp, "species_name") or "",
            plural = f(sp, "plural") or f(sp, "species_plural") or "",
            adjective = f(sp, "adjective") or f(sp, "species_adjective") or "",
            name_list = f(sp, "name_list") or "", gender = f(sp, "gender") or "not_set", traits = fields(sp, "trait"),
        },
        authority = f(b, "authority"), government = f(b, "government"), civics = tokens(raw_field(b, "civics")),
        ethics = fields(b, "ethic"), origin = f(b, "origin") or "origin_default",
        room = f(b, "room") or "", planet_name = f(b, "planet_name") or "", planet_class = f(b, "planet_class") or "pc_continental",
        system_name = f(b, "system_name") or "", initializer = f(b, "initializer") or "",
        graphical_culture = f(b, "graphical_culture") or "mammalian_01",
        city_graphical_culture = f(b, "city_graphical_culture") or f(b, "graphical_culture") or "mammalian_01",
        empire_flag = { icon = part(fl, "icon") or {}, background = part(fl, "background") or {}, colors = tokens(raw_field(fl, "colors")) },
        ruler = {
            name = f(ru, "name") or "", gender = f(ru, "gender") or "female", portrait = f(ru, "portrait") or f(sp, "portrait"),
            texture = tonumber(f(ru, "texture")) or 0, attachment = tonumber(f(ru, "attachment")) or 0,
            clothes = tonumber(f(ru, "clothes")) or 0, leader_class = f(ru, "leader_class") or "official",
            traits = fields(ru, "trait"), ruler_title = "", ruler_title_female = "", heir_title = "", heir_title_female = "",
            biography = "",
        },
        biography = "",
    }
    -- which names are the player's own text (literal = yes) rather than localisation keys
    local function is_lit(blk, k)
        local v = raw_field(blk, k)
        if type(v) ~= "table" then
            return false
        end
        local n = raw_field(v, "full_names") or v
        if strip(raw_field(n, "key")) == "%ADJ%" then
            for _, var in ipairs(type(raw_field(v, "variables")) == "table" and raw_field(v, "variables") or {}) do
                local val = type(var) == "table" and raw_field(var, "value")
                if type(val) == "table" then
                    n = val
                end
            end
        end
        return field(n, "literal") == "yes"
    end
    d.literal = {
        name = is_lit(b, "name"), adjective = is_lit(b, "adjective"), planet_name = is_lit(b, "planet_name"),
        system_name = is_lit(b, "system_name"), species_name = is_lit(sp, "species_name"),
        species_plural = is_lit(sp, "species_plural"), species_adjective = is_lit(sp, "species_adjective"),
        ruler_name = is_lit(ru, "name"), ship_prefix = is_lit(b, "ship_prefix"),
    }
    d.ruler.phenotype = 0
    d.empire_flag.colors = #d.empire_flag.colors > 0 and d.empire_flag.colors or { "null", "null", "null", "null" }
    return d
end

return rules
