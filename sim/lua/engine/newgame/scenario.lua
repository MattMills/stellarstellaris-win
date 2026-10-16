-- engine/newgame/scenario.lua : the inputs of game creation, read in place from the game's files.
--
-- - map/setup_scenarios/*.txt: `setup_scenario = { name = "tiny" num_stars = 200 radius = 200 ... }`
--   (CGalaxyTemplateDatabase, CRandomGalaxyTemplate::ReadMember 0x510fa0);
-- - map/galaxy/galaxy_shapes.txt: `elliptical = { core_radius_perc stars_min_dist countries ... }`
--   (CGalaxyShapeDatabase, CGalaxyShape::ReadMember 0x5138c0);
-- - common/defines: NGameplay GALAXY_GENERATION_* and the rest of the defines;
-- - common/scripted_variables: the global `@name = value`, for numbers written as variables.
--
--   local scenario = require("engine.newgame.scenario")
--   local inputs = scenario.read(game_dir, settings)   -- see scenario.read

local source = require("stellar.script.source")

local scenario = {}

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end
scenario.field = field

local function fields(block, key)
    local out = {}
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            out[#out + 1] = e.value.text or e.value
        end
    end
    return out
end
scenario.fields = fields

-- the global scripted variables (common/scripted_variables), name without '@' -> text
local globals
function scenario.globals(fs)
    if globals == nil then
        globals = {}
        for _, file in ipairs(source.files(fs, "common/scripted_variables", "txt")) do
            for _, e in ipairs(source.parse(fs, file) or {}) do
                if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                    globals[e.key.text:sub(2)] = e.value.text
                end
            end
        end
    end
    return globals
end

-- the variables of one file (`@x = 1` at its top level), cached
local file_vars = {}
function scenario.file_vars(fs, file)
    local v = file_vars[file]
    if v == nil then
        v = {}
        for _, e in ipairs(file and source.parse(fs, file) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                v[e.key.text:sub(2)] = e.value.text
            end
        end
        file_vars[file] = v
    end
    return v
end

-- a number from a token's text: a literal, or a scripted variable of the file or a global one
function scenario.number(fs, text, file, depth)
    if type(text) == "number" then
        return text
    end
    local n = tonumber(text)
    if n then
        return n
    end
    if type(text) == "string" and text:sub(1, 1) == "@" and (depth or 0) < 8 then
        local name = text:sub(2)
        local r = scenario.file_vars(fs, file)[name] or scenario.globals(fs)[name]
        if r then
            return scenario.number(fs, r, file, (depth or 0) + 1)
        end
    end
    return nil
end

-- a value written `x = 10` or `x = { min = 5 max = 15 }` -> min, max (numbers), or nil
function scenario.interval(fs, v, file)
    if type(v) == "table" then
        local lo = scenario.number(fs, field(v, "min"), file)
        local hi = scenario.number(fs, field(v, "max"), file)
        if lo or hi then
            return lo or hi, hi or lo
        end
        return nil
    end
    local n = scenario.number(fs, v, file)
    if n then
        return n, n
    end
    return nil
end

-- the defines: namespace -> KEY -> text or block (files in name order, later values replace)
local defines
function scenario.defines(fs)
    if defines == nil then
        defines = {}
        for _, f in ipairs(source.files(fs, "common/defines", "txt")) do
            for _, top in ipairs(source.parse(fs, f) or {}) do
                if top.op and top.key and type(top.value) == "table" then
                    local ns = defines[top.key.text] or {}
                    defines[top.key.text] = ns
                    for _, e in ipairs(top.value) do
                        if e.op and e.key then
                            ns[e.key.text] = e.value.text or e.value
                        end
                    end
                end
            end
        end
    end
    return defines
end

function scenario.define(fs, ns, key)
    local d = scenario.defines(fs)[ns]
    return d and d[key]
end

-- every setup scenario: name -> { block, file }
function scenario.setup_scenarios(fs)
    local out = {}
    for _, f in ipairs(source.files(fs, "map/setup_scenarios", "txt")) do
        for _, e in ipairs(source.parse(fs, f) or {}) do
            if e.op and e.key and e.key.text == "setup_scenario" and type(e.value) == "table" then
                local name = field(e.value, "name")
                if name then
                    out[name] = { block = e.value, file = f }
                end
            elseif e.op and e.key and e.key.text == "static_galaxy_scenario" and type(e.value) == "table" then
                local name = field(e.value, "name")
                if name then
                    out[name] = { block = e.value, file = f, static = true }
                end
            end
        end
    end
    return out
end

-- every galaxy shape: name -> { block, file }
function scenario.shapes(fs)
    local out = {}
    for _, f in ipairs(source.files(fs, "map/galaxy", "txt")) do
        for _, e in ipairs(source.parse(fs, f) or {}) do
            if e.op and e.key and type(e.value) == "table" then
                out[e.key.text] = { block = e.value, file = f }
            end
        end
    end
    return out
end

local function num(fs, v, file, default)
    local n = scenario.number(fs, v, file)
    if n == nil then
        return default
    end
    return n
end

local function partitioner(fs, block, file)
    block = type(block) == "table" and block or {}
    return {
        max_systems = num(fs, field(block, "max_systems"), file, 0),
        min_systems = num(fs, field(block, "min_systems"), file, 0),
        min_bridges = num(fs, field(block, "min_bridges"), file, 0),
        max_bridges = num(fs, field(block, "max_bridges"), file, 0),
        method = field(block, "method") or "breadth_first",
    }
end

-- scenario.read(game_dir_or_fs, settings) -> inputs: the setup scenario and shape the settings
-- name (settings.scenario, default "tiny"; settings.shape, default the scenario's first supported
-- shape), as numbers, with the settings applied (the galaxy setup screen's choices: empires,
-- fallen_empires, marauders, nomads, advanced_empires, num_hyperlanes, num_gateways,
-- num_wormhole_pairs, ...; a missing setting takes the scenario's default)
function scenario.read(fs, settings)
    settings = settings or {}
    local name = settings.scenario or "tiny"
    local all = scenario.setup_scenarios(fs)
    local sc = all[name]
    if not sc then
        local names = {}
        for k in pairs(all) do
            names[#names + 1] = k
        end
        table.sort(names)
        error("no setup scenario " .. tostring(name) .. " (there are: " .. table.concat(names, ", ") .. ")")
    end
    local b, file = sc.block, sc.file
    local s = {
        name = name, file = file, block = b,
        num_stars = num(fs, field(b, "num_stars"), file, 200),
        radius = num(fs, field(b, "radius"), file, 200),
        priority = num(fs, field(b, "priority"), file, 0),
        num_empire_default = num(fs, field(b, "num_empire_default"), file, 3),
        fallen_empire_default = num(fs, field(b, "fallen_empire_default"), file, 0),
        fallen_empire_max = num(fs, field(b, "fallen_empire_max"), file, 0),
        marauder_empire_default = num(fs, field(b, "marauder_empire_default"), file, 0),
        marauder_empire_max = num(fs, field(b, "marauder_empire_max"), file, 0),
        nomad_empire_default = num(fs, field(b, "nomad_empire_default"), file, 0),
        nomad_empire_max = num(fs, field(b, "nomad_empire_max"), file, 0),
        advanced_empire_default = num(fs, field(b, "advanced_empire_default"), file, 0),
        colonizable_planet_odds = num(fs, field(b, "colonizable_planet_odds"), file, 1),
        primitive_odds = num(fs, field(b, "primitive_odds"), file, 1),
        crisis_strength = num(fs, field(b, "crisis_strength"), file, 1),
        cluster_radius = num(fs, field(b, "cluster_radius"), file, 0),
        cluster_distance_from_core = num(fs, field(b, "cluster_distance_from_core"), file, 0),
        max_hyperlane_distance = num(fs, field(b, "max_hyperlane_distance"), file, 50),
        num_nebulas = num(fs, field(b, "num_nebulas"), file, 0),
        nebula_size = num(fs, field(b, "nebula_size"), file, 0),
        nebula_min_dist = num(fs, field(b, "nebula_min_dist"), file, 0),
        num_wormhole_pairs_default = num(fs, field(b, "num_wormhole_pairs_default"), file, 0),
        num_gateways_default = num(fs, field(b, "num_gateways_default"), file, 0),
        num_hyperlanes_default = num(fs, field(b, "num_hyperlanes_default"), file, 1),
        home_system_partitions = partitioner(fs, field(b, "home_system_partitions"), file),
        open_space_partitions = partitioner(fs, field(b, "open_space_partitions"), file),
        supports_shape = fields(b, "supports_shape"),
    }
    s.num_empires_min, s.num_empires_max = scenario.interval(fs, field(b, "num_empires"), file)
    s.num_hyperlanes_min, s.num_hyperlanes_max = scenario.interval(fs, field(b, "num_hyperlanes"), file)
    local cc = field(b, "cluster_count")
    s.cluster_count = {
        method = type(cc) == "table" and field(cc, "method") or "constant",
        value = type(cc) == "table" and num(fs, field(cc, "value"), file, 0) or 0,
        max = type(cc) == "table" and num(fs, field(cc, "max"), file, 0) or 0,
    }

    local shapes = scenario.shapes(fs)
    local shape_name = settings.shape or s.supports_shape[1] or "elliptical"
    local sh = shapes[shape_name]
    if not sh then
        error("no galaxy shape " .. tostring(shape_name))
    end
    local sb, sf = sh.block, sh.file
    local countries = field(sb, "countries")
    local fallen = field(sb, "fallen_empires")
    local arms = field(sb, "arms")
    local ring = field(sb, "ring")
    local shape = {
        name = shape_name, block = sb,
        core_radius_perc = num(fs, field(sb, "core_radius_perc"), sf, 0),
        num_stars_core_perc = num(fs, field(sb, "num_stars_core_perc"), sf, 0),
        stars_min_dist = num(fs, field(sb, "stars_min_dist"), sf, 10),
        countries_ideal_sq = num(fs, field(countries, "ideal_sq_dist_between"), sf, 5625),
        countries_min_sq = num(fs, field(countries, "min_sq_dist_between"), sf, 2500),
        fallen_ideal_sq = num(fs, field(fallen, "ideal_sq_dist_between"), sf, 15625),
        fallen_min_sq = num(fs, field(fallen, "min_sq_dist_between"), sf, 5625),
        num_arms = num(fs, field(sb, "num_arms"), sf, 0),
        has_ring = ring ~= nil,
    }
    if type(arms) == "table" then
        shape.arms = {
            tightness_winding = num(fs, field(arms, "tightness_winding"), sf, 1),
            width = num(fs, field(arms, "width"), sf, 80),
            fuzz = num(fs, field(arms, "fuzz"), sf, 25),
            seperation = num(fs, field(arms, "seperation"), sf, 180),
        }
    end
    if type(ring) == "table" then
        shape.ring = {
            width = num(fs, field(ring, "width"), sf, 0.5),
            offset = num(fs, field(ring, "offset"), sf, 0.4),
        }
    end

    -- the settings, defaulted from the scenario (CGalaxyConfiguration; galaxy = { } in the save)
    local cfg = {
        empires = settings.empires or s.num_empire_default,
        fallen_empires = settings.fallen_empires or s.fallen_empire_default,
        marauders = settings.marauders or s.marauder_empire_default,
        nomads = settings.nomads or s.nomad_empire_default,
        advanced_empires = settings.advanced_empires or s.advanced_empire_default,
        num_hyperlanes = settings.num_hyperlanes or s.num_hyperlanes_default,
        num_gateways = settings.num_gateways or s.num_gateways_default,
        num_wormhole_pairs = settings.num_wormhole_pairs or s.num_wormhole_pairs_default,
        habitability = settings.habitability or s.colonizable_planet_odds,
        primitive = settings.primitive or s.primitive_odds,
        crises = settings.crises or s.crisis_strength,
        difficulty = settings.difficulty or "ensign",
        player_locations = settings.player_locations or "normal",
        clustered = settings.clustered ~= false,
        seed = settings.seed or 0,
        start_year = settings.start_year or 2200,
        player_design = settings.player_design,
        player_design_text = settings.player_design_text,
    }
    return { scenario = s, shape = shape, config = cfg }
end

return scenario
