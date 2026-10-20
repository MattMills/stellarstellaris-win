-- engine/newgame/empires.lua : the empires of a new game: their design (species, government, flag,
-- names), the home system from its initializer, the home planet, and the objects the engine makes
-- for them (species, country, capital colony, starbase, fleets). What the generator does in
-- CalcDesignsForEmpires (GOG 0x988900), GenerateEmpireSpecies (0x9816e0),
-- RandomizeEmpireGovernments (0x988a10), InitEmpireSystems (0x984eb0), GenerateSingleEmpire
-- (0x97a210) and InitEmpireShared (0x9793c0) (the home systems are PlaceEmpires', galaxy.lua);
-- docs/newgame.md, section 6.4, says what follows the game and what stands in for script the
-- engine does not run yet.
--
--   local empires = require("engine.newgame.empires")
--   empires.designs(ctx, inputs, G, game)       -- after the partitions: game.empires
--   empires.init_systems(ctx, inputs, G, game)  -- after the hyperlanes: the home system trees
--   empires.finish(ctx, inputs, G, game)        -- home planets, the stores in the save's form

local source = require("stellar.script.source")
local scenario = require("engine.newgame.scenario")
local systems = require("engine.newgame.systems")
local save = require("engine.newgame.save")

local empires = {}

local field, fields = scenario.field, scenario.fields
local NONE = save.NONE

-- ---------------------------------------------------------------------------------------------
-- definitions

-- a design's name as save.lua's B:name writes it: a text (a prescripted design's `name =
-- "NAME_..."`) as is; a name block (user_empire_designs' and the empire creator's `name = { key =
-- "United Nations" literal = yes variables = { { key = "adjective" value = { ... } } } }`) as
-- { key, literal, variables = { { name, value } } }
local function name_of(v)
    if type(v) ~= "table" then
        return v
    end
    local key = field(v, "key")
    if type(key) ~= "string" then
        return nil
    end
    local n = { key = key, literal = field(v, "literal") == "yes" or nil }
    local vars = field(v, "variables")
    if type(vars) == "table" then
        n.variables = {}
        for _, item in ipairs(vars) do
            if type(item) == "table" and not item.op then
                local k = field(item, "key")
                local value = name_of(field(item, "value"))
                if k and value then
                    n.variables[#n.variables + 1] = { k, value }
                end
            end
        end
    end
    return n
end
empires.name_of = name_of

local function texts(block)
    local out = {}
    for _, v in ipairs(type(block) == "table" and block or {}) do
        if v.text then
            out[#out + 1] = v.text
        end
    end
    return out
end

-- the empire designs of prescripted_countries/ (CEmpireDesign): name -> { block, file, order }
local function designs(fs)
    local out, order = {}, {}
    for _, f in ipairs(source.files(fs, "prescripted_countries", "txt")) do
        for _, e in ipairs(source.parse(fs, f) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.key.text:sub(1, 1) ~= "@" then
                if not out[e.key.text] then
                    order[#order + 1] = e.key.text
                end
                out[e.key.text] = { name = e.key.text, block = e.value, file = f }
            end
        end
    end
    return out, order
end

-- the start technologies: start_tech = yes, with no potential, or one the default empire passes
-- (is_nomadic = no, is_machine_empire = no ...: the simple ones) [I]
local function start_techs(fs)
    local out = {}
    local defs = source.definitions(fs, "common/technology")
    local names = {}
    for name in pairs(defs) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b)
        local da, db = defs[a], defs[b]
        if da.file ~= db.file then
            return da.file < db.file
        end
        return da.line < db.line
    end)
    for _, name in ipairs(names) do
        local b = defs[name].block
        if field(b, "start_tech") == "yes" then
            local pot = field(b, "starting_potential") or field(b, "potential")
            local ok = true
            for _, e in ipairs(type(pot) == "table" and pot or {}) do
                if e.op and e.key then
                    local k, v = e.key.text, e.value.text
                    if k == "is_nomadic" or k == "is_machine_empire" or k == "is_gestalt" or k == "is_hive_empire"
                        or k == "is_lithoid_empire" or k == "country_uses_bio_ships" or k == "is_wilderness_empire"
                        or k == "is_infernal_empire" or k == "is_void_dweller_empire" or k == "uses_cloaking" then
                        ok = ok and v == "no"
                    elseif k == "has_origin" or k == "has_valid_civic" or k == "has_civic" or k == "has_authority"
                        or k == "has_ethic" or k == "has_country_flag" then
                        ok = ok and e.op == "!="
                    elseif k == "NOT" or k == "NOR" or k == "NAND" then
                        -- a negated condition about something the default empire does not have
                    else
                        ok = false
                    end
                end
            end
            if ok then
                out[#out + 1] = name
            end
        end
    end
    return out
end

-- species_names: class -> { { name, plural, home_planet, home_system, name_list } }
local function species_names(fs)
    local out = {}
    for _, f in ipairs(source.files(fs, "common/species_names", "txt")) do
        for _, e in ipairs(source.parse(fs, f) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.key.text ~= "named_lists" then
                local list = out[e.key.text] or {}
                out[e.key.text] = list
                for _, s in ipairs(e.value) do
                    if s.op and type(s.value) == "table" then
                        list[#list + 1] = {
                            key = s.key.text, name = field(s.value, "name"), plural = field(s.value, "plural"),
                            home_planet = field(s.value, "home_planet"), home_system = field(s.value, "home_system"),
                            name_list = field(s.value, "name_list"),
                        }
                    end
                end
            end
        end
    end
    return out
end

function empires.context(ctx)
    if ctx.designs then
        return ctx
    end
    ctx.designs, ctx.design_order = designs(ctx.fs)
    empires.add_user_designs(ctx, ctx.designs_text)
    ctx.start_techs = start_techs(ctx.fs)
    ctx.species_names = species_names(ctx.fs)
    return ctx
end

-- ---------------------------------------------------------------------------------------------
-- placement (PlaceEmpires): home systems apart by the shape's countries distances

local function dist2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

-- empires.place(inputs, r, game, n) -> n systems. Candidates are the start clusters' systems when
-- the galaxy is clustered (one empire per cluster first), else every system; a draw that is closer
-- than the ideal squared distance to a home already placed is drawn again, then the minimum
-- distance is accepted, then any [I] (docs/newgame.md: PlaceEmpires)
function empires.place(inputs, r, game, n)
    local shape = inputs.shape
    local homes, taken = {}, {}
    local pools = {}
    for _, c in ipairs(game.clusters) do
        local pool = {}
        for _, sid in ipairs(c.objects) do
            pool[#pool + 1] = game.systems[sid + 1]
        end
        if #pool > 0 then
            pools[#pools + 1] = pool
        end
    end
    local all = {}
    for _, s in ipairs(game.systems) do
        if not s.nebula then
            all[#all + 1] = s
        end
    end
    local function ok(s, sq)
        if taken[s.id] or s.initializer then
            return false
        end
        for _, h in ipairs(homes) do
            if dist2(h, s) < sq then
                return false
            end
        end
        return true
    end
    for i = 1, n do
        local pool = pools[(i - 1) % math.max(1, #pools) + 1] or all
        if i > #pools then
            pool = all
        end
        local chosen
        for _, sq in ipairs({ shape.countries_ideal_sq, shape.countries_min_sq, 0 }) do
            for _ = 1, 200 do
                local s = pool[r:below(#pool) + 1]
                if ok(s, sq) then
                    chosen = s
                    break
                end
            end
            if chosen then
                break
            end
        end
        if not chosen then
            break
        end
        taken[chosen.id] = true
        homes[#homes + 1] = chosen
    end
    return homes
end

-- ---------------------------------------------------------------------------------------------
-- the user's designs (settings.designs_text: a user_empire_designs file, the same form as
-- prescripted_countries): name -> { block, file, user = true }, in file order
function empires.add_user_designs(ctx, text)
    ctx.user_design_order = {}
    if not text or text == "" then
        return
    end
    local tree = require("pdxscript").parse(text, "user_empire_designs_v3.4.txt") or {}
    for _, e in ipairs(tree) do
        if e.op and e.key and type(e.value) == "table" then
            local name = e.key.text:gsub('^"(.*)"$', "%1")
            ctx.designs[name] = { name = name, block = e.value, file = "user_empire_designs_v3.4.txt", user = true }
            ctx.user_design_order[#ctx.user_design_order + 1] = name
        end
    end
end

-- a design's `playable` (CEmpireDesign::IsPlayable 0x25068e0: the trigger, when there is one); a
-- scripted trigger's name (playable = has_aquatics) is that trigger
local function playable(ctx, d)
    local p = field(d.block, "playable")
    if p == nil then
        return true
    end
    local block = p
    if type(p) ~= "table" then
        local st = ctx.scripted_triggers and ctx.scripted_triggers[p]
        if not st then
            return true
        end
        block = st.block
    end
    local yes = true
    for _, e in ipairs(block) do
        if e.op and e.key then
            local r = systems.trigger(ctx, nil, e.key.text, e.value, nil)
            if r == false or (r ~= nil and r ~= (e.op ~= "!=")) then
                yes = false
            end
        end
    end
    return yes
end

-- the configuration's designs (CGalaxyConfiguration::ImportEmpireDesigns 0x19f85b0 Linux): the
-- user's, then the prescripted ones that are playable, in the database's order [V: measured, the
-- 26 designs of a default setup]
function empires.design_pool(ctx)
    local pool = {}
    for _, name in ipairs(ctx.user_design_order or {}) do
        pool[#pool + 1] = name
    end
    for _, name in ipairs(ctx.design_order) do
        if playable(ctx, ctx.designs[name]) then
            pool[#pool + 1] = name
        end
    end
    return pool
end

local SPAWN = { always = 2, yes = 1 }

-- designs (CalcDesignsForEmpires 0x262cca0 Linux, its per-empire GetEmpireDesignForStaticGalaxyEmpire
-- 0x262c620) [V]: an empire slot a human holds gets the human's design; otherwise the candidates
-- are the configuration's designs not used yet with spawn_enabled = always (forced) or yes; forced
-- ones: one G draw % their count; else, with yes ones: G % 1000 < CUSTOM_EMPIRE_SPAWN_CHANCE (50:
-- 5%), then one G draw % their count; else (and with no candidates) a randomized design, which is
-- not modelled: false in the list. The game also skips a design whose species portrait another
-- spawned one uses (unless ignore_portrait_duplication) [I: not modelled]
function empires.pick_designs(ctx, r, n, player, defines)
    local chance = defines and tonumber(defines.CUSTOM_EMPIRE_SPAWN_CHANCE) or 50
    local pool = empires.design_pool(ctx)
    local out, used = {}, {}
    for slot = 1, n do
        local d
        if slot == 1 and player and ctx.designs[player] then
            d = player
        else
            local forced, yes = {}, {}
            for _, name in ipairs(pool) do
                local m = SPAWN[field(ctx.designs[name].block, "spawn_enabled") or ""]
                if m and not used[name] then
                    if m == 2 then
                        forced[#forced + 1] = name
                    else
                        yes[#yes + 1] = name
                    end
                end
            end
            if #forced > 0 then
                d = forced[r:below(#forced) + 1]
            elseif #yes > 0 and r:below(1000) < chance then
                d = yes[r:below(#yes) + 1]
            end
        end
        out[slot] = d or false
        if d then
            used[d] = true
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the empire from its design

local function ideal_class(design_species, design)
    local pc = field(design, "planet_class")
    if pc then
        return pc
    end
    for _, t in ipairs(fields(design_species, "trait")) do
        local c = t:match("^trait_(pc_[%w_]+)_preference$")
        if c then
            return c
        end
    end
    return "pc_continental"
end

-- the origins' home system initializers (common/governments/civics: `initializers = { ... }`)
local function origin_initializers(ctx)
    if not ctx.origin_inits then
        ctx.origin_inits = {}
        local defs = source.definitions(ctx.fs, "common/governments/civics")
        for name, d in pairs(defs) do
            local list = texts(field(d.block, "initializers"))
            if #list > 0 then
                ctx.origin_inits[name] = list
            end
        end
    end
    return ctx.origin_inits
end

-- empires.design(ctx, game, design_name, index) -> empire: what the design gives (CEmpireDesign;
-- CalcDesignsForEmpires, GenerateEmpireSpecies, RandomizeEmpireGovernments)
function empires.design(ctx, game, design_name, index)
    local d = ctx.designs[design_name]
    local b = d.block
    local sp = field(b, "species") or {}
    local e = {
        index = index, design = design_name, country = index,
        name = name_of(field(b, "name")) or design_name, adjective = name_of(field(b, "adjective")),
        species = {
            class = field(sp, "class") or "MAM", portrait = field(sp, "portrait") or "mam1",
            -- (a user design's species names are species_name / species_plural / species_adjective)
            name = name_of(field(sp, "name") or field(sp, "species_name")) or "SPEC_Human",
            plural = name_of(field(sp, "plural") or field(sp, "species_plural")) or "SPEC_Human_pl",
            adjective = name_of(field(sp, "adjective") or field(sp, "species_adjective")),
            name_list = field(sp, "name_list") or "HUMAN1",
            traits = fields(sp, "trait"),
        },
        authority = field(b, "authority") or "auth_democratic",
        government = field(b, "government"),
        civics = texts(field(b, "civics")),
        ethics = fields(b, "ethic"),
        origin = field(b, "origin") or "origin_default",
        planet_name = name_of(field(b, "planet_name")),
        system_name = name_of(field(b, "system_name")),
        initializer = field(b, "initializer"),
        graphical_culture = field(b, "graphical_culture") or "mammalian_01",
        city_graphical_culture = field(b, "city_graphical_culture") or field(b, "graphical_culture") or "mammalian_01",
        flag = field(b, "empire_flag"),
        ship_prefix = field(b, "ship_prefix"),
        ruler = field(b, "ruler"),
    }
    e.planet_class = ideal_class(sp, b)
    if e.initializer == "" then
        e.initializer = nil
    end
    -- an origin with initializers gives the first valid one (RandomizeEmpireGovernments 0x9890cd)
    if not e.initializer then
        for _, name in ipairs(origin_initializers(ctx)[e.origin] or {}) do
            if ctx.initializers[name] then
                e.initializer = name
                break
            end
        end
    end
    return e
end

-- InitEmpireSystems (0x984eb0): ReorderPlayerLocations, then each empire's home system queued with
-- its initializer (the design's, else GetRandomFromList over usage = empire_init with the
-- generator's stream), its context (the ideal planet class) and a scope (a draw of the global stream); one InitializeQueue for all:
-- the empires' systems first, then their neighbours layer by layer
function empires.init_systems(ctx, inputs, G, game)
    local homes = {}
    for _, sid in ipairs(game.home_systems or {}) do
        homes[#homes + 1] = game.systems[sid + 1]
    end
    -- ReorderPlayerLocations (0x984960, player_locations = normal): each human's slot swapped
    -- with a random one
    local humans = math.min((game.params and game.params.humans) or 1, #homes)
    for i = 1, humans do
        local j = G:int() % #homes + 1
        homes[i], homes[j] = homes[j], homes[i]
    end
    local queue = {}
    for i, e in ipairs(game.empires) do
        local sys = homes[i]
        if sys then
            e.system = sys
            if not e.initializer then
                e.initializer = systems.random_from_list(ctx, G, game, sys, ctx.by_usage.empire_init or {})
                    or "random_empire_init_01"
            end
            systems.class_check(ctx, game, e.initializer)
            -- no draw of the generator here (measured: InitEmpireSystems draws G only in
            -- ReorderPlayerLocations and GetRandomFromList before the queue)
            game.global:int()
            -- the design's system name comes with the home planet (InitHomePlanet): the system
            -- still takes a star name first (measured: a TakeStarName draw)
            queue[#queue + 1] = { sys = sys, name = e.initializer, empire = e }
        end
    end
    systems.run_queue(ctx, G, game, queue)
end

-- InitHomePlanet (0x9785a0): the home planet is one of the system's home_planet = yes planets
-- (draw % count of the generator's stream); none: the last planet, its class changed to the ideal
function empires.home_planet(ctx, G, game, e)
    local sys = e.system
    local homes = sys.home_planets or {}
    local home
    if #homes > 0 then
        home = homes[G:int() % #homes + 1]
    else
        for i = #sys.planets, 1, -1 do
            local p = game.planets[sys.planets[i]]
            local c = ctx.planet_classes[p.class]
            if c and not c.star then
                home = p
                break
            end
        end
    end
    e.home = home
    if e.system_name then
        -- the planets' and moons' names made from the system's (PLANET_NAME_FORMAT's PARENT,
        -- systems.lua) follow it: "Sol II", not the generated name's [I]
        local old = sys.name
        local function rename(n, depth)
            if type(n) ~= "table" or depth > 4 then return end
            for _, kv in ipairs(n.variables or {}) do
                if kv[2] == old then
                    kv[2] = e.system_name
                else
                    rename(kv[2], depth + 1)
                end
            end
        end
        for _, pid in ipairs(sys.planets) do
            local p = game.planets[pid]
            if p then rename(p.name, 0) end
        end
        sys.name = e.system_name
    end
    if home then
        home.class = e.planet_class
        if e.planet_name then
            home.name = e.planet_name
        end
    end
    sys.flags.empire_home_system = sys.flags.empire_home_system or game.flag_date
end

-- ---------------------------------------------------------------------------------------------
-- the save's objects: species_db, country, colony, pop_groups, starbase_mgr, ships, fleet

-- the default origin's capital at the first day, as the 2200.01.11 save's origin_default empires
-- show it (generate_start_pops etc. are script; until the engine runs them this stands in) [I]
local START_POPS = { { "ruler", 200 }, { "specialist", 1300 }, { "worker", 1900 }, { "civilian", 1800 } }
local START_RESOURCES = {
    { "energy", 200 }, { "minerals", 200 }, { "food", 200 }, { "influence", 100 }, { "unity", 50 },
    { "trade", 200 }, { "consumer_goods", 100 }, { "alloys", 200 },
}

local function name_block(key)
    return { key = key }
end

function empires.objects(ctx, inputs, r, game)
    local species_db = save.block()
    -- the dummy species the save keeps at 0
    local dummy = species_db:child("0")
    dummy:child("traits")
    local hp = dummy:child("home_planet")
    hp:set("type", "planet")
    hp:set("reference", NONE)
    dummy:set("gender", "not_set")

    local country = save.block()
    local colony = save.block()
    local pop_groups = save.block()
    local starbase_mgr = save.block()
    local starbases = starbase_mgr:child("starbases")
    local ships = save.block()
    local fleets = save.block()
    -- the construction queues (CConstructionManager::CreateQueue): the capital's planet and army
    -- queues, the starbase's and its shipyard's, four an empire in that order (the game's new
    -- game: queues 0..3 for the first empire, 4..7 for the next)
    local construction = save.block()
    local queues = construction:child("queue_mgr"):child("queues")
    local next_queue = 0
    local function queue(owner, loc_type, loc_id, kind)
        local q = queues:child(tostring(next_queue))
        q:set("owner", owner)
        local loc = q:child("location")
        loc:set("type", loc_type)
        loc:set("id", loc_id)
        q:set("simultaneous", 1)
        q:set("type", kind)
        next_queue = next_queue + 1
        return next_queue - 1
    end
    local next_pop, next_ship, next_fleet = 0, 0, 0

    for _, e in ipairs(game.empires) do
        local sid = e.index + 1
        e.species_id = sid
        -- species
        local s = species_db:child(tostring(sid))
        s:str("name_list", e.species.name_list)
        s:name("name", e.species.name)
        s:name("plural", e.species.plural)
        s:name("adjective", { key = "%ADJECTIVE%", variables = { { "adjective", e.species.name } } })
        s:str("class", e.species.class)
        s:str("portrait", e.species.portrait)
        local tr = s:child("traits")
        for _, t in ipairs(e.species.traits) do
            tr:str("trait", t)
        end
        local shp = s:child("home_planet")
        shp:set("type", "planet")
        shp:set("reference", e.home and e.home.id or NONE)
        s:set("gender", "not_set")

        -- colony (the capital) and its pop groups
        local col_id = e.index
        e.colony = col_id
        local c = colony:child(tostring(col_id))
        local groups = {}
        for _, pg in ipairs(START_POPS) do
            local g = pop_groups:child(tostring(next_pop))
            groups[#groups + 1] = next_pop
            next_pop = next_pop + 1
            g:set("can_procreate", true)
            local key = g:child("key")
            key:set("species", sid)
            key:str("category", pg[1])
            g:set("planet", col_id)
            local eth = g:child("ethos"):child("ethics")
            for _, x in ipairs(e.ethics) do
                eth:value(x:gsub("_fanatic", ""), true)
            end
            g:set("size", pg[2])
            g:set("month_start_size", pg[2])
            g:set("habitability", 1)
            g:set("happiness", 0.5)
        end
        c:list("pop_groups", groups)
        c:set("final_designation", "col_capital", true)
        local spr = c:child("species_refs")
        spr:value(sid)
        -- the colony's carrier (CColony +0xf70, the save's `carrier = { type reference }`)
        local car = c:child("carrier")
        car:set("type", "planet")
        car:set("reference", e.home and e.home.id or NONE)
        if e.home then
            e.home.colony = col_id
            e.home.owner = e.index
            e.home.original_owner = e.index
            e.home.colonize_date = game.date
            e.home.size = math.max(e.home.size, 16)
        end

        -- the starbase, its station (a ship) and the station's fleet
        local sb_id = e.index
        local station = next_ship
        next_ship = next_ship + 1
        local fleet_id = next_fleet
        next_fleet = next_fleet + 1
        local home_id = e.home and e.home.id or NONE
        queue(e.index, 2, home_id, "planet")
        queue(e.index, 2, home_id, "army")
        local build_q = queue(e.index, 0, station, "starbase")
        local yard_q = queue(e.index, 0, station, "ships")
        local sb = starbases:child(tostring(sb_id))
        sb:str("level", "starbase_level_starport")
        sb:str("type", "sshipyard")
        sb:set("build_queue", build_q)
        sb:set("shipyard_build_queue", yard_q)
        sb:set("station", station)
        sb:set("construction_type", "starbase_shipyard")
        local sh = ships:child(tostring(station))
        sh:set("fleet", fleet_id)
        sh:name("name", { key = "STARBASE_STATION_NAME_FORMAT_NON_PRIMARY",
            variables = { { "PLANET", e.system.name } } })
        sh:str("graphical_culture", e.graphical_culture)
        sh:coordinate("coordinate", 0, -25, e.system.id)
        local fl = fleets:child(tostring(fleet_id))
        fl:name("name", { key = "shipclass_starbase_name", variables = { { "PLANET", e.system.name } } })
        fl:list("ships", { station })
        fl:set("ship_class", "shipclass_starbase")
        -- (CFleet's properties: a station, an orbital station, as the game's new game writes them;
        -- what reads a fleet's kind reads them there: the outliner, the windows, the system view)
        local props = fl:child("properties")
        props:set("station", true)
        props:set("orbital_station", true)
        e.fleets = { fleet_id }
        e.system.starbase = sb_id
        e.system.colonies = { col_id }

        -- the country
        local k = country:child(tostring(e.index))
        k:set("initialized", true)
        local flag = k:child("flag")
        if type(e.flag) == "table" then
            for _, kv in ipairs(e.flag) do
                if kv.op and kv.key then
                    flag[#flag + 1] = kv
                end
            end
        else
            flag:list("colors", { "blue", "black", "null", "null" }, true)
        end
        k:name("name", e.name)
        k:name("adjective", e.adjective or e.name)
        local ts = k:child("tech_status")
        for _, t in ipairs(ctx.start_techs) do
            ts:str("technology", t)
            ts:set("level", 1)
        end
        k:list("stored_techpoints", { 0, 0, 0 })
        k:str("graphical_culture", e.graphical_culture)
        k:str("city_graphical_culture", e.city_graphical_culture)
        k:set("capital", col_id)
        k:set("founder_species_ref", sid)
        k:child("ethos"):list("ethics", e.ethics, true)
        local gov = k:child("government")
        if e.government then
            gov:str("type", e.government)
        end
        gov:str("authority", e.authority)
        gov:list("civics", e.civics, true)
        gov:str("origin", e.origin)
        k:str("name_list", e.species.name_list)
        k:set("starting_system", e.system.id)
        -- the home system surveyed: NGalaxyGenerator::CreateStarbaseWithDesign calls
        -- CCountry::AddSurveyedSystem for the starbase's owner [V]; the game's 2200 saves list the
        -- system's planets as { type = 0 id = N }, in id order
        local surveyed = k:child("surveyed_deposit_holders")
        local pids = {}
        for _, pid in ipairs(e.system.planets or {}) do
            pids[#pids + 1] = pid
        end
        table.sort(pids)
        for _, pid in ipairs(pids) do
            local h = surveyed:item()
            h:set("type", 0)
            h:set("id", pid)
        end
        k:child("owned_leaders")
        k:list("owned_planets", { col_id })
        k:list("controlled_colonies", { col_id })
        k:list("controlled_planets", { e.home and e.home.id or NONE })
        k:str("type", "default")
        local res = k:child("modules"):child("standard_economy_module"):child("resources")
        for _, kv in ipairs(START_RESOURCES) do
            res:set(kv[1], kv[2])
        end
        local owned = k:child("fleets_manager"):child("owned_fleets")
        for _, f in ipairs(e.fleets) do
            owned:item():set("fleet", f)
        end
        k:str("customization", "default")
        k:set("starbase_capacity_used", 1)
        k:set("starbase_capacity", 3)
        local os = k:child("owned_species_refs")
        os:value(sid)
    end
    game.species_db = species_db
    game.last_created_species_ref = #game.empires
    game.country = country
    game.last_created_country = #game.empires > 0 and #game.empires - 1 or NONE
    game.before_systems = { { "pop_groups", pop_groups } }
    game.before_planets = { { "starbase_mgr", starbase_mgr }, { "colony", colony } }
    game.after_country = { { "ships", ships }, { "fleet", fleets }, { "construction", construction } }
    if #game.empires > 0 then
        game.players = { { name = "player", country = 0 } }
        game.meta_flag = (function()
            local f = save.block()
            for _, kv in ipairs(type(game.empires[1].flag) == "table" and game.empires[1].flag or {}) do
                if kv.op then
                    f[#f + 1] = kv
                end
            end
            return f
        end)()
        game.meta_fleets = next_fleet
        game.meta_planets = 1
    end
end

-- the empires' phases, in GenerateFromRandomScenario's order:
-- empires.designs after the partitions (CalcDesignsForEmpires, the species, the governments),
-- empires.init_systems after the hyperlanes, empires.finish after it (GenerateSingleEmpire each:
-- the home planet, the country, the capital, the starbase)
function empires.designs(ctx, inputs, G, game)
    empires.context(ctx)
    local homes = game.home_systems or {}
    local player = inputs.config.player_design
    -- the player's own design (the empire creator's: one `key = { ... }` in the form of
    -- user_empire_designs.txt): a design beside the prescripted ones, never an AI's pick
    local text = inputs.config.player_design_text
    if text and text ~= "" then
        local tree = assert(require("pdxscript").parse(text, "player_design"))
        for _, e in ipairs(tree) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                ctx.designs[e.key.text] = { name = e.key.text, block = e.value, file = "player_design" }
                player = e.key.text
                break
            end
        end
    end
    local names = empires.pick_designs(ctx, G, #homes, player, game.defines)
    -- a randomized design (CEmpireDesign randomization: species, names, ethics, government, flag)
    -- is not modelled: the first unused spawn_enabled design stands in for it, without draws
    game.randomized_designs = 0
    local taken = {}
    for i = 1, #homes do
        if names[i] then
            taken[names[i]] = true
        end
    end
    for i = 1, #homes do
        if not names[i] then
            game.randomized_designs = game.randomized_designs + 1
            for _, name in ipairs(empires.design_pool(ctx)) do
                if not taken[name] and field(ctx.designs[name].block, "spawn_enabled") then
                    names[i], taken[name] = name, true
                    break
                end
            end
        end
    end
    game.empires = {}
    for i = 1, #homes do
        local name = names[i]
        if name then
            game.empires[#game.empires + 1] = empires.design(ctx, game, name, #game.empires)
        end
    end
end

function empires.finish(ctx, inputs, G, game)
    local placed = {}
    for _, e in ipairs(game.empires) do
        if e.system then
            empires.home_planet(ctx, G, game, e)
            e.index, e.country = #placed, #placed
            placed[#placed + 1] = e
        end
    end
    game.empires = placed
    empires.objects(ctx, inputs, G, game)
    local parts = {}
    for _, e in ipairs(game.empires) do
        parts[#parts + 1] = string.format("%d %s (%s, %s) at system %s, home %s %s", e.index, e.design, e.species.class,
            tostring(e.initializer), e.system and e.system.id or "-", e.home and e.home.class or "none",
            e.home and ("planet " .. e.home.id) or "")
    end
    game.empire_summary = "  empires: " .. table.concat(parts, "; ")
end

return empires
