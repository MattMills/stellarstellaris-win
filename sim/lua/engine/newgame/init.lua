-- engine/newgame : a new game without a save. What the game does from the galaxy setup screen to
-- the first day (CFrontEndIdler::LaunchNewGame -> CGameState::GenerateNewGalaxy ->
-- CGalaxyGenerator::Generate -> GenerateFromRandomScenario, then InitPostGalaxyCreation), in Lua
-- from the game's own files (map/setup_scenarios, map/galaxy, common/solar_system_initializers,
-- common/star_classes, common/planet_classes, ...), read in place. The result is a world in the
-- save's form (engine/newgame/save.lua): the text of a `gamestate` that engine.load / world.load
-- read as they read a save. docs/newgame.md is the reverse engineering it follows.
--
--   local newgame = require("engine.newgame")
--   local game = newgame.generate(game_dir, { scenario = "tiny", shape = "elliptical",
--                                             empires = 3, seed = 1234 })
--   game.text      -- the gamestate
--   game.meta_text -- the save's meta
--   game.summary   -- what was made
--
-- The order (GenerateFromRandomScenario, GOG 0x98bfe0):
--   1. the setup's random counts (empires etc.), the galaxy's rotation   (draws, generator stream)
--   2. GenerateStars, GenerateNebula, GenerateGalacticMap
--   3. CreateEmpireStartClusters, PlaceEmpires, PartitionGalaxyForEmpires
--   4. the empires' designs, species classes, governments, species
--   5. CreateResouceClusters, GenerateHyperlanes
--   6. InitEmpireSystems, GenerateSingleEmpire (each), fallen empires, AssignBaseSpecies
--   7. InitializeUninitializedSystems (every other system), GenerateGalacticMap again
--   8. ConnectDividedEmpirePartitions, advanced empires, ConnectEmpireSystems,
--      ProcessNeighbourContact, precursors, resource regions, cosmic storm clusters
-- Steps this version does not do yet are listed in game.summary and in docs/newgame.md.

local source = require("stellar.script.source")
local rng = require("engine.newgame.rng")
local scenario = require("engine.newgame.scenario")
local galaxy = require("engine.newgame.galaxy")
local systems = require("engine.newgame.systems")
local lanes = require("engine.newgame.lanes")
local empires = require("engine.newgame.empires")
local save = require("engine.newgame.save")

local newgame = {}
newgame.rng, newgame.scenario, newgame.galaxy, newgame.systems, newgame.save = rng, scenario, galaxy, systems, save

local EPOCH_HOURS = 43800000

-- the date's hours (CDate) and text
local function date_hours(year, month, day)
    return EPOCH_HOURS + ((year * 360) + (month - 1) * 30 + (day - 1)) * 24
end
newgame.date_hours = date_hours

-- the DLCs the save says it was made with (every one the game has: the initializers' DLC checks
-- are answered yes)
local DLCS = {
    "Ancient Relics Story Pack", "Anniversary Portraits", "Apocalypse", "Aquatics Species Pack",
    "Distant Stars Story Pack", "Federations", "Horizon Signal", "Leviathans Story Pack",
    "Lithoids Species Pack", "Megacorp", "Necroids Species Pack", "Nemesis", "Overlord",
    "Plantoids Species Pack",
}

-- the galaxy = { } block (CGalaxyConfiguration::WriteMembers): { key, value, quoted }
local function galaxy_settings(inputs, game)
    local cfg, sc = inputs.config, inputs.scenario
    return {
        { "template", sc.name, true },
        { "shape", inputs.shape.name, true },
        { "num_empires", cfg.empires },
        { "num_advanced_empires", cfg.advanced_empires },
        { "num_fallen_empires", cfg.fallen_empires },
        { "num_marauder_empires", cfg.marauders },
        { "num_nomad_empires", cfg.nomads },
        { "habitability", cfg.habitability },
        { "resource_abundance", 1 },
        { "primitive", cfg.primitive },
        { "advanced_starts_near_player", false },
        { "caravaneers_enabled", true },
        { "crises", cfg.crises },
        { "technology", 1 },
        { "traditions", 1 },
        { "naval_capacity_mult", 1 },
        { "command_limit_galaxy_mult", 1 },
        { "logistic_ceiling_v2", 5 },
        { "growth_scale", 0.25 },
        { "clustered", cfg.clustered },
        { "random_empires", false },
        { "random_fallen_empires", false },
        { "random_marauder_empires", false },
        { "random_nomad_empires", false },
        { "random_advanced_empires", false },
        { "core_radius", math.floor(game.core_radius + 0.5) },
        { "player_locations", cfg.player_locations },
        { "difficulty", cfg.difficulty },
        { "aggressiveness", "normal" },
        { "crisis_type", "any" },
        { "scaling", "scaling_off" },
        { "technology_difficulty_scale", "scaling_normal" },
        { "lgate_enabled", true },
        { "name", string.format("newgame-%s-%d", sc.name, cfg.seed), true },
        { "ironman", false },
        { "num_gateways", cfg.num_gateways },
        { "num_wormhole_pairs", cfg.num_wormhole_pairs },
        { "num_hyperlanes", cfg.num_hyperlanes },
        { "mid_game_start", 100 },
        { "end_game_start", 200 },
        { "victory_year", 300 },
        { "num_guaranteed_colonies", 2 },
        { "difficulty_adjusted_ai_modifiers", false },
        { "fallen_empire_strength_scale", 1 },
        { "logistics_fleet_upkeep_costs", 1 },
        { "logistics_planet_deficit_costs", 1 },
    }
end

local function count_keys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function top(t, n)
    local l = {}
    for k, v in pairs(t) do
        l[#l + 1] = { k, v }
    end
    table.sort(l, function(a, b)
        if a[2] ~= b[2] then
            return a[2] > b[2]
        end
        return tostring(a[1]) < tostring(b[1])
    end)
    local out = {}
    for i = 1, math.min(n, #l) do
        out[i] = l[i][1] .. " " .. l[i][2]
    end
    return table.concat(out, ", ")
end

-- newgame.generate(game_dir_or_fs, settings) -> game: see the top of this file. settings:
-- scenario ("tiny"), shape (the scenario's first), empires, fallen_empires, marauders, nomads,
-- advanced_empires, num_hyperlanes, num_gateways, num_wormhole_pairs, habitability, primitive,
-- seed (the galaxy seed, CGalaxyGenerator::Generate's; default: from the global stream as
-- GenerateNewGalaxy does), global_seed (written as random_seed), name, start_year.
function newgame.generate(fs, settings)
    settings = settings or {}
    local t0 = RUST.clock()
    if type(fs) == "string" then
        fs = source.filesystem(fs)
    end
    local inputs = scenario.read(fs, settings)
    local global = rng.global()
    local seed = settings.seed
    if seed == nil then
        -- GenerateNewGalaxy: one draw of the global stream gives the generator's seed
        seed = rng.seed_from_global(global:int())
    end
    inputs.config.seed = seed
    local r = rng.stream(seed)
    local year = inputs.config.start_year
    local game = {
        inputs = inputs, seed = seed, rng = r, global = global,
        systems = {}, planets = {}, planet_ids = {}, nebulas = {}, clusters = {},
        global_flags = {},
        init_effects = {},
        date = string.format("%d.01.01", year),
        flag_date = date_hours(year, 1, 1),
        name = settings.name or "New Game",
        dlcs = DLCS,
        steps = {},
    }
    local function step(name, f)
        local t = RUST.clock()
        local p = r.draws
        f()
        game.steps[#game.steps + 1] = string.format("%s %.2fs %d draws", name, RUST.clock() - t, r.draws - p)
    end
    local ctx
    step("definitions", function()
        ctx = systems.context(fs)
    end)
    game.ctx = ctx
    game.defines = scenario.defines(fs).NGameplay or {}
    step("parameters", function()
        game.params = galaxy.parameters(inputs, r)
    end)
    step("stars", function()
        galaxy.stars(inputs, r, game)
    end)
    step("nebulas", function()
        galaxy.nebulas(inputs, r, game, function() return systems.take_name(ctx, "nebula_names", global) end)
    end)
    step("galactic map", function()
        galaxy.galactic_map(game)
    end)
    step("start clusters", function()
        galaxy.clusters(inputs, r, game)
    end)
    step("place empires", function()
        galaxy.place_empires(inputs, r, game)
    end)
    step("partitions", function()
        lanes.partition(inputs, r, game)
    end)
    step("designs", function()
        empires.designs(ctx, inputs, r, game)
    end)
    step("resource clusters", function()
        galaxy.resource_clusters(inputs, r, game)
    end)
    step("hyperlanes", function()
        lanes.hyperlanes(inputs, game)
    end)
    step("empire systems", function()
        empires.init_systems(ctx, inputs, r, game)
        game.init_effects_empires = #game.init_effects
    end)
    step("empires", function()
        empires.finish(ctx, inputs, r, game)
    end)
    step("systems", function()
        systems.initialize_rest(ctx, r, game)
    end)
    step("galactic map", function()
        galaxy.galactic_map(game)
    end)
    -- the save's `index` of a system (0-63; what it is was not traced): a hash of the id, not a
    -- draw
    for _, s in ipairs(game.systems) do
        s.index = rng.noise31(s.id, rng.SEED_SALT) % 64
    end
    -- the rim: the systems farthest out (rim_galactic_objects) [I]
    game.rim = {}
    game.galaxy = galaxy_settings(inputs, game)
    game.random_seed = settings.global_seed or 0
    game.random_count = global.draws
    game.meta_planets = game.meta_planets or 0
    local tree = save.gamestate(game)
    game.text = save.write(tree)
    game.meta_text = save.meta(game)

    -- the summary
    local lanes, moons, stars, belts = 0, 0, 0, 0
    for _, s in ipairs(game.systems) do
        lanes = lanes + #s.lanes
        belts = belts + #s.belts
    end
    for _, id in ipairs(game.planet_ids) do
        local p = game.planets[id]
        if p.moon_of then
            moons = moons + 1
        end
        if ctx.planet_classes[p.class] and ctx.planet_classes[p.class].star then
            stars = stars + 1
        end
    end
    local classes, inits = {}, {}
    for _, s in ipairs(game.systems) do
        classes[s.star_class] = (classes[s.star_class] or 0) + 1
        inits[s.initializer or "?"] = (inits[s.initializer or "?"] or 0) + 1
    end
    local lines = {
        string.format("newgame: %s %s, galaxy seed %d: %d systems, %d hyperlanes, %d planets (%d stars, %d moons), %d asteroid belts, %d nebulas, %d clusters, galaxy radius %.1f",
            inputs.scenario.name, inputs.shape.name, seed, #game.systems, lanes / 2, #game.planet_ids, stars, moons, belts,
            #game.nebulas, #game.clusters, game.galaxy_radius or 0),
        "  star classes: " .. top(classes, 12),
        string.format("  initializers (%d): %s", count_keys(inits), top(inits, 12)),
        "  steps: " .. table.concat(game.steps, "; "),
        "  hyperlanes: " .. tostring(game.lane_stats),
        string.format("  generator draws %d, global draws %d; %.2f s", r.draws, global.draws, RUST.clock() - t0),
    }
    if next(ctx.unknown_triggers) then
        lines[#lines + 1] = "  triggers not evaluated (their modifiers left out): " .. top(ctx.unknown_triggers, 12)
    end
    if next(ctx.unknown_classes) then
        lines[#lines + 1] = "  planet classes picked as random: " .. top(ctx.unknown_classes, 12)
    end
    if next(ctx.missing) then
        lines[#lines + 1] = "  missing: " .. top(ctx.missing, 12)
    end
    if game.empire_summary then
        lines[#lines + 1] = game.empire_summary
    end
    game.summary = table.concat(lines, "\n")
    return game
end

-- newgame.generate_text(game_dir, settings) -> gamestate, meta, summary (for the Rust side)
function newgame.generate_text(game_dir, settings)
    local game = newgame.generate(game_dir, settings)
    newgame.last = game
    return game.text, game.meta_text, game.summary
end

-- newgame.start_script([game]) -> report: the script's part of game creation, run by the script
-- layer (simscript) on the generated world once engine.load has read it in this Lua state, in the
-- game's order:
--   1. the init_effects of the empires' systems and their neighbours (InitializeSystem runs them
--      as each system is made: its planets', then its own);
--   2. per empire (InitEmpireShared 0x9793c0): empire_init_add_technologies (country),
--      empire_init_capital_colony (the capital colony: buildings, districts, pops),
--      empire_init_create_ships (country);
--   3. the init_effects of the other systems (InitializeUninitializedSystems);
--   4. on_game_start, then on_game_start_country for each country (CGameState::OnNewGameStarted
--      0x272000, CCountry::OnNewGameStarted 0x746e00).
-- The engine effects the script queues are applied at a barrier after each; those the engine
-- does not model yet are counted (engine.report).
function newgame.start_script(game)
    game = game or newgame.last
    if not game then
        return "start script: no game generated in this state"
    end
    local eval = require("simscript.eval")
    local events = require("simscript.events")
    local stats = eval.stats
    local s0, e0 = stats.script, stats.engine
    local errors, ran = {}, { effects = 0, on_actions = 0 }
    local function barrier()
        if E.pending and E.pending() > 0 then
            E.flush()
        end
    end
    local function guarded(what, f)
        local ok, err = pcall(f)
        if not ok then
            errors[#errors + 1] = what .. ": " .. tostring(err)
        end
        barrier()
    end
    -- the init_effects of one system share its tree's scope: the event targets one saves are the
    -- others' (`exists = event_target:GuardiansTradersPlanet` guards the enclaves' planets) [I]
    local targets_of = {}
    local R = require("engine.script.runtime")
    local function init_effects(from, to)
        for i = from, to do
            local ie = game.init_effects[i]
            if ie then
                local kind = ie.kind == "system" and "system" or "planet"
                local sys = kind == "system" and ie.id or R.system_of("planet", ie.id) or -1
                targets_of[sys] = targets_of[sys] or {}
                guarded(string.format("%s %d init_effect (%s)", kind, ie.id, tostring(ie.initializer)), function()
                    eval.effect(ie.block, eval.new_ctx(eval.S(kind, ie.id), nil, targets_of[sys], ie.file))
                end)
                ran.effects = ran.effects + 1
            end
        end
    end
    -- the capital colony as CreateNewColony leaves it: no pops (empires.lua's stand-in pops, for a
    -- world without the script, are taken out; game_start.12's generate_start_pops makes them)
    local world = require("engine.world")
    local function empty_colony(cid)
        local c = world.object("colony", cid)
        if not c then return end
        local list = world.field(c, "pop_groups")
        for _, g in ipairs(world.list(list)) do
            world.remove("pop_groups", tonumber(g))
        end
        if type(list) == "table" then
            world.replace(list, {})
        end
        world.index()
    end
    -- what the country's creation makes before the script: the ruler (CCountry::CreateRulerFromDesign
    -- 0x2343060: an official for a regular empire [I: the design's ruler class]) and the policies
    -- (CCountry::UpdatePolicies -> InitializePolicy: the max-ai_weight options; when the game first
    -- runs it for a new country is not traced [I])
    local objects = require("engine.script.objects")
    local function country_setup(e)
        local c = world.object("country", e.index)
        if not c then return end
        -- the stockpile empires.lua stands in with: the script gives it (give_starting_resources_effect)
        local res = world.path(c, "modules", "standard_economy_module", "resources")
        if type(res) == "table" then world.replace(res, {}) end
        if not world.field(c, "ruler") then
            local gestalt = false
            for _, x in ipairs(e.ethics or {}) do
                if x == "ethic_gestalt_consciousness" then gestalt = true end
            end
            -- the design's ruler (name, gender, trait, leader_class), else a class drawn from the
            -- authority's ruler council position (ChooseLeaderClassFromData's random_ruler: one draw)
            local defs = require("engine.defs")
            local r = type(e.ruler) == "table" and e.ruler or nil
            local function rf(k)
                local v = r and defs.field(r, k)
                return type(v) == "string" and v:gsub('^"(.*)"$', "%1") or nil
            end
            local class = rf("leader_class")
            if not class then
                local ad = e.authority and defs.get("common/governments/authorities", e.authority)
                local pos = ad and defs.field(ad.block, "ruler_council_position")
                local pd = pos and defs.get("common/governments/councilors", pos)
                local lc = pd and defs.field(pd.block, "leader_class")
                local list = {}
                for _, x in ipairs(type(lc) == "table" and lc or {}) do
                    if x.text then list[#list + 1] = x.text end
                end
                class = #list > 0 and list[RUST.rand() % #list + 1] or "official"
            end
            local name
            if rf("name") then
                name = {}
                local fn = {}
                world.append(fn, "key", rf("name"), true)
                world.append(name, "full_names", fn)
                world.append(name, "use_full_regnal_name", "yes")
            end
            local lid = objects.leaders.create({ country = e.index, class = class, name = name, gender = rf("gender"),
                traits = rf("trait") and { { 0, rf("trait") } } or nil })
            if lid then world.set(c, "ruler", lid) end
        end
        -- the start technologies (start_tech = yes) whose potential and starting_potential hold
        -- for the country, evaluated by the script layer: the generator's own filter only knows a
        -- few triggers (empires.lua start_techs) [I: the game's CCountry tech init order]
        local defs = require("engine.defs")
        local have = {}
        for _, t in ipairs(world.fields(world.field(c, "tech_status"), "technology")) do
            if type(t) == "string" then have[(t:gsub('"', ""))] = true end
        end
        for _, d in ipairs(objects.ordered("common/technology")) do
            local name, b = d[1], d[2].block
            if not have[name] and defs.field(b, "start_tech") == "yes" then
                local ok = true
                for _, key in ipairs({ "potential", "starting_potential" }) do
                    local pot = defs.field(b, key)
                    if ok and type(pot) == "table" then
                        local good, r = pcall(eval.trigger, pot, eval.new_ctx(eval.S("country", e.index)))
                        ok = good and r and true or false
                    end
                end
                if ok then require("engine.research").add_technology(e.index, name) end
            end
        end
        objects.leaders.initialize_policies(e.index)
        -- the starbase's station: a design of its level's size (the country's default starport
        -- design, objects_fleets' designs.default; the 2200.01.11 save's stations have their
        -- auto-generated starbase_<level> design)
        local sb = e.system and e.system.starbase and world.object("starbases", e.system.starbase)
        local station = sb and tonumber(world.field(sb, "station"))
        local ship = station and world.object("ships", station)
        if ship and world.field(ship, "ship_design_implementation") == nil then
            local level = tostring(world.field(sb, "level") or ""):gsub('"', ""):gsub("^starbase_level_", "starbase_")
            local did = objects.fleets.designs.default(e.index, level)
            if did then
                local sdi = {}
                world.append(sdi, "design", did)
                world.append(sdi, "upgrade", 4294967295)
                world.append(sdi, "growth_stage", 0)
                world.insert(ship, 3, "ship_design_implementation", sdi)
            end
        end
        -- the station's fleet at the station (its movement_manager's coordinate, which the sensors
        -- and the systems' presence read; empires.lua writes the ship's only)
        local fid = ship and tonumber(world.field(ship, "fleet"))
        local fl = fid and world.object("fleet", fid)
        local sc = ship and world.field(ship, "coordinate")
        if fl and type(sc) == "table" and world.field(fl, "movement_manager") == nil then
            local mm, c = {}, {}
            for _, k in ipairs({ "x", "y", "origin" }) do
                local v = world.field(sc, k)
                if v ~= nil then world.append(c, k, v) end
            end
            world.append(mm, "coordinate", c)
            world.append(mm, "state", "move_idle")
            world.append(fl, "movement_manager", mm)
            local g = world.object("galactic_object", tonumber(world.field(sc, "origin")))
            if g then
                local fp = world.field(g, "fleet_presence")
                if type(fp) ~= "table" then fp = world.child(g, "fleet_presence") end
                world.append_value(fp, fid)
            end
        end
    end
    -- the modifier graph brought up to date when read, not after every event (creation.defer)
    local creation = require("engine.script.creation")
    creation.defer = objects.touch
    local split = game.init_effects_empires or #game.init_effects
    local clock = RUST.clock
    local t = { clock() }
    init_effects(1, split)
    t[2] = clock()
    for _, e in ipairs(game.empires or {}) do
        guarded("country setup " .. e.index, function() country_setup(e) end)
        for _, oa in ipairs({ "empire_init_add_technologies", "empire_init_capital_colony", "empire_init_create_ships" }) do
            local scope = eval.S("country", e.index)
            if oa == "empire_init_capital_colony" then
                -- the colony as the simulation scopes one: its planet (the carrier; the links
                -- and the save runs give a colony as its planet)
                scope = e.home and eval.S("planet", e.home.id) or eval.S("colony", e.colony)
                empty_colony(e.colony)
            end
            guarded(oa .. " " .. e.index, function()
                -- empire_init_capital_colony: from the founder species (InitEmpireShared)
                local from = oa == "empire_init_capital_colony" and e.species_id
                    and eval.new_ctx(eval.S("species", e.species_id)) or nil
                events.on_action(oa, scope, from)
            end)
            ran.on_actions = ran.on_actions + 1
        end
    end
    t[3] = clock()
    init_effects(split + 1, #game.init_effects)
    t[4] = clock()
    guarded("on_game_start", function()
        events.on_action("on_game_start", eval.NONE, nil)
    end)
    ran.on_actions = ran.on_actions + 1
    for _, e in ipairs(game.empires or {}) do
        guarded("on_game_start_country " .. e.index, function()
            events.on_action("on_game_start_country", eval.S("country", e.index), nil)
        end)
        ran.on_actions = ran.on_actions + 1
    end
    creation.defer = nil
    objects.fresh()
    t[5] = clock()
    -- the jobs update the game runs before the first save (twice a day from the first day,
    -- CColony::EnsurePopJobsAreUpToDate as colonies change): the colonies' jobs made from their
    -- buildings, districts and zones, the pops into them (engine.jobs); then the emptied pop
    -- groups, which the game removes the next day
    guarded("jobs", function()
        objects.fresh()
        local jobs = require("engine.jobs")
        jobs.update()
        jobs.update()
        require("engine.pops").remove_killed()
        world.index()
        ran.jobs = jobs.report()
    end)
    local lines = {
        string.format("start script: %d init_effects and %d on_actions run; %d script effects, %d engine effects queued; %d errors",
            ran.effects, ran.on_actions, stats.script - s0, stats.engine - e0, #errors),
        string.format("  in %.2f s: empires' systems %.2f, empires %.2f, other systems %.2f, game start %.2f",
            t[5] - t[1], t[2] - t[1], t[3] - t[2], t[4] - t[3], t[5] - t[4]),
    }
    if ran.jobs then lines[#lines + 1] = ran.jobs end
    for i = 1, math.min(8, #errors) do
        lines[#lines + 1] = "  error: " .. errors[i]
    end
    return table.concat(lines, "\n")
end

return newgame
