-- render/newgame_setup.lua : the new game's setup state: the empire design chosen on the empire
-- selection (a prescripted one, random, or the empire creator's) and the galaxy settings of the
-- galaxy settings screen, with the game's defaults and allowed values; what Play hands to the
-- galaxy generator (engine.newgame: setup.settings gives scenario.read's settings).
--
--   local setup = require("render.newgame_setup")
--   local state = setup.new(game_dir)                 -- RENDER_NEWGAME
--   setup.step(state, token, +1 / -1)                 -- a spinner's or slider's arrow
--   setup.set(state, token, value)
--   setup.text(state, token, loc)                     -- the value as the screen shows it
--   setup.settings(state)                             -- { scenario, shape, empires, ... }
--   setup.set_design(state, design)                   -- the empire creator's result
--
-- The settings' list (tabs, categories, which show) is common/gamesetup_settings; each setting's
-- control, values and default are its picker's (CGameSetup*Picker, 4.5.2 Linux; the defines
-- NGameplay ..._MIN / _MAX / _DEFAULT / _SLIDER_INTERVAL; map/setup_scenarios for the galaxy's
-- counts): docs/windows/newgame_flow.md.

local source = require("stellar.script.source")
local gfx = require("render.gfx")
local get = gfx.get
local dlc = require("render.newgame_dlc")
local scenario = require("engine.newgame.scenario")

local setup = {}

local function each(block, key, f)
    key = key:lower()
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key then
            f(e.value)
        end
    end
end

local function define(game_dir, key, default)
    local v = scenario.define(game_dir, "NGameplay", key)
    return tonumber(type(v) == "string" and v or nil) or default
end

-- ---------------------------------------------------------------- the settings list

-- common/gamesetup_settings: { { categories = { { name, settings = { { token, game_mode, visible } } } } } }
function setup.tabs(game_dir)
    local tabs = {}
    for _, f in ipairs(source.files(game_dir, "common/gamesetup_settings", "txt")) do
        for _, top in ipairs(source.parse(game_dir, f) or {}) do
            -- a tab: an anonymous block { categories = { ... } }
            if type(top) == "table" and not top.op and top.text == nil then
                local tab = { categories = {} }
                each(top, "categories", function(cats)
                    for _, c in ipairs(cats) do
                        if type(c) == "table" and not c.op and c.text == nil then
                            local cat = { name = get(c, "name"), settings = {} }
                            each(c, "settings", function(ss)
                                for _, sb in ipairs(ss) do
                                    if type(sb) == "table" and not sb.op and sb.text == nil then
                                        cat.settings[#cat.settings + 1] = {
                                            token = get(sb, "setting"), game_mode = get(sb, "game_mode") or "all",
                                            visible = get(sb, "visible"),
                                        }
                                    end
                                end
                            end)
                            tab.categories[#tab.categories + 1] = cat
                        end
                    end
                end)
                tabs[#tabs + 1] = tab
            end
        end
    end
    return tabs
end

-- ---------------------------------------------------------------- the settings

-- a multiplier's text: "1x", "0.25x" (trailing zeros dropped)
local function times(v)
    local s = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
    return s .. "x"
end
local function plain(v)
    return string.format("%d", math.floor(v + 0.5))
end

-- the settings' definitions, by token: kind (spinner: named options; slider: a number between
-- min and max by step; checkbox; shapes: the shape icons; precursors), label, values / range,
-- default (a value, or a function of the state), the text of a value.
-- [V]/[I] per field: docs/windows/newgame_flow.md section 3.
function setup.definitions(game_dir)
    local D = {}
    local function slider(token, label, key, unit, fmt)
        D[token] = {
            kind = "slider", label = label,
            min = define(game_dir, key .. "_MIN", 0), max = define(game_dir, key .. "_MAX", 1),
            step = define(game_dir, key .. (unit or "_SLIDER_INTERVAL"), 1),
            default = define(game_dir, key .. "_DEFAULT", 1), format = fmt or times,
        }
    end
    D.difficulty = {
        kind = "spinner", label = "FE_DIFFICULTY", bar = true,
        options = {
            { "civilian", "DIFFICULTY_CIVILIAN" }, { "cadet", "DIFFICULTY_CADET" }, { "ensign", "DIFFICULTY_ENSIGN" },
            { "captain", "DIFFICULTY_CAPTAIN" }, { "commodore", "DIFFICULTY_COMMODORE" },
            { "admiral", "DIFFICULTY_ADMIRAL" }, { "grand_admiral", "DIFFICULTY_GRAND_ADMIRAL" },
        },
        default = "ensign",
    }
    D.ironman = { kind = "checkbox", label = "FE_IRONMAN", default = false, on = "ENABLED", off = "DISABLED" }
    D.galaxy_size = { kind = "spinner", label = "GALAXY_SIZE", options = {}, default = "medium" }
    D.galaxy_shape = { kind = "shapes", label = "GALAXY_SHAPE", default = "elliptical" }
    D.num_hyperlanes = { kind = "slider", label = "NUM_HYPERLANES", scenario = "num_hyperlanes", format = times }
    D.num_empires = { kind = "slider", label = "NUM_EMPIRES", scenario = "num_empires", randomize = true, format = plain }
    D.num_advanced_empires = { kind = "slider", label = "NUM_ADVANCED_EMPIRES", scenario = "advanced_empires", randomize = true, format = plain }
    D.num_fallen_empires = { kind = "slider", label = "NUM_FALLEN_EMPIRES", scenario = "fallen_empires", randomize = true, format = plain }
    D.num_marauder_empires = { kind = "slider", label = "NUM_MARAUDER_EMPIRES", scenario = "marauder_empires", randomize = true, format = plain }
    D.num_nomad_empires = { kind = "slider", label = "NUM_NOMAD_EMPIRES", scenario = "nomad_empires", randomize = true, format = plain }
    D.crisis_type = { kind = "spinner", label = "CRISIS_TYPE_LABEL", options = {}, default = nil }
    D.crises = { kind = "slider", label = "FE_CRISES", min = 0, max = 25, step = 0.25, default = 1, format = times }
    D.scaling = { kind = "spinner", label = "FE_SCALING_DIFFICULTY", options = { { false, "SCALING_OFF" }, { true, "SCALING_ON" } }, default = false }
    D.fallen_empire_strength_scale = { kind = "slider", label = "FALLEN_EMPIRE_STRENGTH_LABEL", min = 0.25, max = 5, step = 0.25, default = 1, format = times }
    D.difficulty_adjusted_ai_modifiers = { kind = "checkbox", label = "DIFFICULTY_ADJUSTED_AI_MODIFIERS", default = false, on = "ENABLED", off = "DISABLED" }
    D.aggressiveness = { kind = "spinner", label = "FE_AGGRESSIVENESS", options = { { "low", "AGGRESSIVENESS_LOW" }, { "normal", "AGGRESSIVENESS_NORMAL" }, { "high", "AGGRESSIVENESS_HIGH" } }, default = "normal" }
    slider("logistic_ceiling", "FE_LOGISTIC_CEILING", "LOGISTIC_CEILING")
    slider("growth_scale", "FE_GROWTH_SCALE", "GROWTH_SCALE")
    slider("technology", "FE_TECH_SPEED", "TECH_COST")
    slider("traditions", "FE_TRADITION_SPEED", "TRADITION_COST")
    D.technology_difficulty_scale = { kind = "spinner", label = "FE_TECH_SPEED_DIFFICULTY_SCALE", options = { { false, "DIFF_TECH_SCALING_OFF" }, { true, "DIFF_TECH_SCALING_NORMAL" } }, default = true }
    slider("naval_capacity_mult", "NAVY_SIZE_TITLE", "NAVAL_CAPACITY_MULT")
    slider("command_limit_galaxy_mult", "COMMAND_LIMIT", "COMMAND_LIMIT_MULT")
    slider("logistics_fleet_upkeep_costs", "FE_LOGISTICS_FLEET_UPKEEP", "LOGISTICS_FLEET_UPKEEP", "_INTERVAL")
    slider("logistics_planet_deficit_costs", "FE_LOGISTICS_PLANET_DEFICIT", "LOGISTICS_PLANET_DEFICIT", "_INTERVAL")
    D.transfer_speed = { kind = "spinner", label = "TRANSFER_SPEED", options = { { "fast", "TRANSFER_SPEED_FAST" } }, default = "fast" }
    D.colonizable_planet_odds = { kind = "slider", label = "NUM_HABITABLE_WORLDS", min = 0.25, max = 5, step = 0.25, default = 1, format = times }
    D.primitive_odds = { kind = "slider", label = "NUM_PRIMITIVE_WORLDS", min = 0, max = 5, step = 0.25, default = 1, format = times }
    D.player_locations = { kind = "spinner", label = "PLAYER_LOCATIONS", options = { { "normal", "player_locations_normal" } }, default = "normal" }
    D.clustered = { kind = "spinner", label = "FE_CLUSTERED_STARTS", options = { { true, "player_locations_normal" }, { false, "player_locations_random" } }, default = true }
    D.advanced_starts_near_player = { kind = "checkbox", label = "FE_ADVANCED_NEAR_PLAYER", default = false, on = "ENABLED", off = "DISABLED" }
    D.num_gateways = { kind = "slider", label = "NUM_GATEWAYS", scenario = "num_gateways", format = times }
    D.num_wormhole_pairs = { kind = "slider", label = "NUM_WORMHOLES", scenario = "num_wormhole_pairs", format = times }
    D.num_guaranteed_colonies = {
        kind = "slider", label = "FE_GUARANTEED_COLONIES", min = define(game_dir, "GUARANTEED_COLONIES_MIN", 0),
        max = define(game_dir, "GUARANTEED_COLONIES_MAX", 2), step = 1,
        default = define(game_dir, "GUARANTEED_COLONIES_DEFAULT", 2), format = plain,
    }
    D.resource_abundance = {
        kind = "slider", label = "RESOURCE_ABUNDANCE", min = define(game_dir, "RESOURCE_ABUNDANCE_MIN", 0),
        max = define(game_dir, "RESOURCE_ABUNDANCE_MAX", 5), step = 1,
        default = define(game_dir, "RESOURCE_ABUNDANCE_DEFAULT", 2), format = times,
    }
    D.disabled_precursors = { kind = "precursors", label = "GALAXY_SETTINGS_CATEGORY_PRECURSORS", default = {} }
    D.mid_game_start = { kind = "slider", label = "FE_MID_GAME", min = define(game_dir, "MID_GAME_START_MIN", 25), max = define(game_dir, "MID_GAME_START_MAX", 400), step = define(game_dir, "START_YEAR_SLIDER_INTERVAL", 25), default = define(game_dir, "MID_GAME_START_DEFAULT", 100), format = plain }
    D.end_game_start = { kind = "slider", label = "FE_END_GAME", min = define(game_dir, "END_GAME_START_MIN", 50), max = define(game_dir, "END_GAME_START_MAX", 800), step = define(game_dir, "START_YEAR_SLIDER_INTERVAL", 25), default = define(game_dir, "END_GAME_START_DEFAULT", 200), format = plain }
    D.victory_year = { kind = "slider", label = "FE_VICTORY", min = define(game_dir, "VICTORY_YEAR_MIN", 100), max = define(game_dir, "VICTORY_YEAR_MAX", 1050), step = define(game_dir, "VICTORY_YEAR_SLIDER_INTERVAL", 50), default = define(game_dir, "VICTORY_YEAR_DEFAULT", 300), format = plain }
    D.lgate_enabled = { kind = "checkbox", label = "FE_LGATE", default = true, on = "ENABLED", off = "DISABLED" }
    D.caravaneers_enabled = { kind = "checkbox", label = "FE_CARAVANEERS", default = true, on = "ENABLED", off = "DISABLED" }
    return D
end

-- ---------------------------------------------------------------- the galaxy sizes and shapes

-- the setup scenarios the size spinner offers, by priority: { name, num_stars, block, file }
function setup.sizes(game_dir)
    local out = {}
    for name, sc in pairs(scenario.setup_scenarios(game_dir)) do
        if not sc.static then
            out[#out + 1] = {
                name = name, block = sc.block, file = sc.file,
                num_stars = scenario.number(game_dir, get(sc.block, "num_stars"), sc.file) or 0,
                priority = scenario.number(game_dir, get(sc.block, "priority"), sc.file) or 0,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.name < b.name
    end)
    return out
end

-- the scenario's counts: name -> { min, max, default } for the sliders that follow the galaxy
-- size (num_empires = { min max }, num_empire_default, ...)
local function scenario_ranges(game_dir, size)
    local b, f = size.block, size.file
    local n = function(k, d)
        return scenario.number(game_dir, get(b, k), f) or d
    end
    local r = {}
    local lo, hi = scenario.interval(game_dir, get(b, "num_empires"), f)
    r.num_empires = { min = lo or 0, max = hi or 0, default = n("num_empire_default", 0), step = 1 }
    r.advanced_empires = { min = 0, max = hi or 0, default = n("advanced_empire_default", 0), step = 1 }
    r.fallen_empires = { min = 0, max = n("fallen_empire_max", 0), default = n("fallen_empire_default", 0), step = 1 }
    r.marauder_empires = { min = 0, max = n("marauder_empire_max", 0), default = n("marauder_empire_default", 0), step = 1 }
    r.nomad_empires = { min = 0, max = n("nomad_empire_max", 0), default = n("nomad_empire_default", 0), step = 1 }
    lo, hi = scenario.interval(game_dir, get(b, "num_hyperlanes"), f)
    r.num_hyperlanes = { min = lo or 0.5, max = hi or 3, default = n("num_hyperlanes_default", 1), step = 0.25 }
    r.num_gateways = { min = 0, max = 5, default = n("num_gateways_default", 1), step = 0.25 }
    r.num_wormhole_pairs = { min = 0, max = 5, default = n("num_wormhole_pairs_default", 1), step = 0.25 }
    return r
end

-- ---------------------------------------------------------------- the empire designs

-- the empire selection's list: Random, Create New, the prescripted designs whose `playable`
-- passes (file order), the user's designs (none here)
function setup.designs(game_dir, dlcs)
    local out = { { kind = "random" }, { kind = "custom" } }
    for _, f in ipairs(source.files(game_dir, "prescripted_countries", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                local b = e.value
                local playable = get(b, "playable")
                if playable == nil or dlc.eval(game_dir, dlcs, playable) then
                    out[#out + 1] = { kind = "prescripted", key = e.key.text, block = b, file = f }
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- the state

-- a new setup: the designs listed (the first prescripted one selected), the galaxy settings at
-- their defaults
function setup.new(game_dir, dlc_names)
    local state = {
        game_dir = game_dir, dlcs = dlc.set(dlc_names), mode = "single_player",
        tabs = setup.tabs(game_dir), defs = setup.definitions(game_dir), sizes = setup.sizes(game_dir),
        tab = 1, scroll = { select = 0, setup = 0 }, galaxy = {}, random = {},
    }
    state.designs = setup.designs(game_dir, state.dlcs)
    for i, d in ipairs(state.designs) do
        if d.kind == "prescripted" then
            state.selected = i
            break
        end
    end
    state.selected = state.selected or 1
    setup.select(state, state.selected)
    for _, s in ipairs(state.sizes) do
        state.defs.galaxy_size.options[#state.defs.galaxy_size.options + 1] = { s.name, s.name }
    end
    setup.reset_galaxy(state)
    return state
end

-- the design list's entry i chosen: state.empire
function setup.select(state, i)
    state.selected = i
    local d = state.designs[i]
    if not d then
        return
    end
    if d.kind == "prescripted" then
        state.empire = { kind = "prescripted", key = d.key, design = d.block }
    elseif d.kind == "random" then
        -- the player's empire made at random: the game randomizes a design (not modelled here);
        -- a playable prescripted design drawn at random stands in for it [I], kept until another
        -- entry is chosen (the preview stays the game's random one)
        local pool = {}
        for _, e in ipairs(state.designs) do
            if e.kind == "prescripted" then
                pool[#pool + 1] = e
            end
        end
        -- the front end's own generator, seeded once by the clock (CCrudeRandom's clock seed)
        if not state.rng_seeded then
            math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
            state.rng_seeded = true
        end
        local pick = #pool > 0 and pool[math.random(#pool)] or nil
        state.empire = pick and { kind = "prescripted", key = pick.key, design = pick.block, random = true } or { kind = "random" }
    elseif d.kind == "custom" then
        state.empire = { kind = "custom", design = d.design }
    end
end

-- the empire creator's result: a design shaped like a prescripted_countries entry
function setup.set_design(state, design)
    local entry = { kind = "custom", design = design, user = true }
    -- the user's designs follow the prescripted ones (and stay selected)
    state.designs[#state.designs + 1] = entry
    state.selected = #state.designs
    state.empire = { kind = "custom", design = design }
end

-- the size chosen: its scenario's ranges
local function size_of(state)
    local name = state.galaxy.galaxy_size
    for _, s in ipairs(state.sizes) do
        if s.name == name then
            return s
        end
    end
    return state.sizes[1]
end

-- a setting's range now: { min, max, step } (the scenario's for the galaxy's counts)
function setup.range(state, token)
    local d = state.defs[token]
    if d.scenario then
        local s = size_of(state)
        return s and scenario_ranges(state.game_dir, s)[d.scenario] or { min = 0, max = 0, step = 1, default = 0 }
    end
    return d
end

local function default_of(state, token)
    local d = state.defs[token]
    if d.scenario then
        return setup.range(state, token).default
    end
    if type(d.default) == "function" then
        return d.default(state)
    end
    if type(d.default) == "table" then
        local t = {}
        for k, v in pairs(d.default) do
            t[k] = v
        end
        return t
    end
    return d.default
end

-- every setting at its default (Reset to Default; a new setup)
function setup.reset_galaxy(state)
    state.galaxy, state.random = {}, {}
    -- the size first: the counts follow it
    state.galaxy.galaxy_size = default_of(state, "galaxy_size")
    for token in pairs(state.defs) do
        if token ~= "galaxy_size" then
            state.galaxy[token] = default_of(state, token)
        end
        if state.defs[token].randomize then
            state.random[token] = false
        end
    end
end

local function clamp_step(v, r)
    local s = r.step or 1
    v = r.min + math.floor((v - r.min) / s + 0.5) * s
    return math.max(r.min, math.min(r.max, v))
end

-- a value set: a slider's snapped to its step within its range; the size resets the counts
function setup.set(state, token, value)
    local d = state.defs[token]
    if not d then
        return
    end
    if d.kind == "slider" then
        value = clamp_step(value, setup.range(state, token))
    end
    state.galaxy[token] = value
    if token == "galaxy_size" then
        for t, dd in pairs(state.defs) do
            if dd.scenario then
                state.galaxy[t] = default_of(state, t)
            end
        end
    end
end

-- an arrow: the next or previous option, or a step of the slider
function setup.step(state, token, dir)
    local d = state.defs[token]
    if d.kind == "spinner" then
        local i = 1
        for k, o in ipairs(d.options) do
            if o[1] == state.galaxy[token] then
                i = k
            end
        end
        i = math.max(1, math.min(#d.options, i + dir))
        setup.set(state, token, d.options[i][1])
    elseif d.kind == "slider" then
        local r = setup.range(state, token)
        setup.set(state, token, (state.galaxy[token] or r.min) + dir * (r.step or 1))
    elseif d.kind == "checkbox" then
        state.galaxy[token] = not state.galaxy[token]
    end
end

-- a slider's position (0..1)
function setup.fraction(state, token)
    local r = setup.range(state, token)
    if r.max <= r.min then
        return 0
    end
    return ((state.galaxy[token] or r.min) - r.min) / (r.max - r.min)
end

-- the text of a setting's value
function setup.text(state, token, loc)
    local d = state.defs[token]
    local v = state.galaxy[token]
    local L = function(k)
        return loc and loc.has(k) and loc.get(k) or k
    end
    if d.kind == "spinner" then
        for _, o in ipairs(d.options) do
            if o[1] == v then
                if token == "galaxy_size" then
                    return setup.size_text(state, v, loc)
                end
                return L(o[2])
            end
        end
        return tostring(v)
    elseif d.kind == "slider" then
        return d.format(v or 0)
    elseif d.kind == "checkbox" then
        return L(v and d.on or d.off)
    end
    return ""
end

-- a galaxy size's text: "Medium (600 Stars)"
function setup.size_text(state, name, loc)
    local n = 0
    for _, s in ipairs(state.sizes) do
        if s.name == name then
            n = s.num_stars
        end
    end
    local title = loc and loc.has(name) and loc.get(name) or name
    return string.format("%s (%d Stars)", title, n)
end

-- which settings a tab shows: { { name, tokens = { ... } } } (game_mode and visible applied)
function setup.categories(state, tab)
    local out = {}
    for _, c in ipairs((state.tabs[tab] or {}).categories or {}) do
        local cat = { name = c.name, tokens = {} }
        for _, s in ipairs(c.settings) do
            local mode_ok = s.game_mode == "all" or s.game_mode == state.mode
            local vis_ok = s.visible == nil or dlc.eval(state.game_dir, state.dlcs, s.visible)
            if mode_ok and vis_ok and state.defs[s.token] then
                cat.tokens[#cat.tokens + 1] = s.token
            end
        end
        if #cat.tokens > 0 then
            out[#out + 1] = cat
        end
    end
    return out
end

-- ---------------------------------------------------------------- what Play hands on

-- engine.newgame.scenario.read's settings (and the rest of the galaxy = { } block's), the design
function setup.settings(state)
    local g = state.galaxy
    return {
        scenario = g.galaxy_size, shape = g.galaxy_shape,
        empires = g.num_empires, advanced_empires = g.num_advanced_empires,
        fallen_empires = g.num_fallen_empires, marauders = g.num_marauder_empires, nomads = g.num_nomad_empires,
        random_empires = state.random.num_empires, random_advanced_empires = state.random.num_advanced_empires,
        random_fallen_empires = state.random.num_fallen_empires, random_marauder_empires = state.random.num_marauder_empires,
        num_hyperlanes = g.num_hyperlanes, num_gateways = g.num_gateways, num_wormhole_pairs = g.num_wormhole_pairs,
        habitability = g.colonizable_planet_odds, primitive = g.primitive_odds, crises = g.crises,
        crisis_type = g.crisis_type, difficulty = g.difficulty, ironman = g.ironman, scaling = g.scaling,
        fallen_empire_strength_scale = g.fallen_empire_strength_scale,
        difficulty_adjusted_ai_modifiers = g.difficulty_adjusted_ai_modifiers, aggressiveness = g.aggressiveness,
        logistic_ceiling = g.logistic_ceiling, growth_scale = g.growth_scale,
        technology = g.technology, traditions = g.traditions, technology_difficulty_scale = g.technology_difficulty_scale,
        naval_capacity_mult = g.naval_capacity_mult, command_limit_galaxy_mult = g.command_limit_galaxy_mult,
        logistics_fleet_upkeep_costs = g.logistics_fleet_upkeep_costs, logistics_planet_deficit_costs = g.logistics_planet_deficit_costs,
        transfer_speed = g.transfer_speed, player_locations = g.player_locations, clustered = g.clustered,
        advanced_starts_near_player = g.advanced_starts_near_player, num_guaranteed_colonies = g.num_guaranteed_colonies,
        resource_abundance = g.resource_abundance, disabled_precursors = g.disabled_precursors,
        mid_game_start = g.mid_game_start, end_game_start = g.end_game_start, victory_year = g.victory_year,
        lgate_enabled = g.lgate_enabled, caravaneers_enabled = g.caravaneers_enabled,
        empire = state.empire,
    }
end

-- the settings in a line (the log's)
function setup.summary(state)
    if not state then
        return "no setup"
    end
    local s = setup.settings(state)
    local e = state.empire or {}
    return string.format("empire %s%s, %s %s, %d AI empires (%d advanced, %d fallen), difficulty %s, hyperlanes %sx",
        e.kind or "?", e.key and (" " .. e.key) or "", tostring(s.scenario), tostring(s.shape),
        s.empires or 0, s.advanced_empires or 0, s.fallen_empires or 0, tostring(s.difficulty), tostring(s.num_hyperlanes))
end

return setup
