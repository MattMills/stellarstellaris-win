-- engine/newgame/systems.lua : filling the systems from common/solar_system_initializers: the
-- star class, the stars and planets with their moons and orbits, asteroid belts, flags, and the
-- initializer trees (neighbor_system). What the game does in its InitializeSystem and
-- InitializeUninitializedSystems (GOG 0x97e5c0) and the init queue around it; docs/newgame.md
-- says which parts follow the disassembly and which are approximations.
--
--   local systems = require("engine.newgame.systems")
--   local ctx = systems.context(fs)                -- the definitions, read once
--   systems.initialize(ctx, sys, "basic_init_01", r, game)
--   systems.initialize_rest(ctx, r, game)          -- every system still without an initializer

local source = require("stellar.script.source")
local scenario = require("engine.newgame.scenario")
local rng = require("engine.newgame.rng")
local fixed = require("engine.newgame.fixed")

local systems = {}

local field, fields = scenario.field, scenario.fields
local pi = math.pi

-- ---------------------------------------------------------------------------------------------
-- definitions

local function parse_files(fs, dir)
    local out = {}
    for _, f in ipairs(source.files(fs, dir, "txt")) do
        out[#out + 1] = { file = f, tree = source.parse(fs, f) or {} }
    end
    return out
end

-- systems.context(fs) -> ctx: the initializers, star classes, planet classes, random lists, names
function systems.context(fs)
    local ctx = { fs = fs, unknown_triggers = {}, unknown_classes = {}, used = {}, missing = {} }
    ctx.initializers = source.definitions(fs, "common/solar_system_initializers")
    ctx.scripted_triggers = source.definitions(fs, "common/scripted_triggers")
    ctx.star_classes = source.definitions(fs, "common/star_classes")
    ctx.star_lists = source.definitions(fs, "common/star_classes/randomizers")
    -- the star classes in database order (the files', then each file's)
    ctx.star_class_order = {}
    for name in pairs(ctx.star_classes) do
        ctx.star_class_order[#ctx.star_class_order + 1] = name
    end
    table.sort(ctx.star_class_order, function(x, y)
        local dx, dy = ctx.star_classes[x], ctx.star_classes[y]
        if dx.file ~= dy.file then
            return dx.file < dy.file
        end
        return dx.line < dy.line
    end)
    -- planet classes and their random lists (`random_list = { name planets }`, all with one key)
    ctx.planet_classes, ctx.planet_class_order, ctx.planet_lists = {}, {}, {}
    for _, pf in ipairs(parse_files(fs, "common/planet_classes")) do
        for _, e in ipairs(pf.tree) do
            if e.op and e.key and type(e.value) == "table" then
                local key = e.key.text
                if key == "random_list" then
                    local name = field(e.value, "name")
                    if name then
                        local list = {}
                        for _, p in ipairs(field(e.value, "planets") or {}) do
                            if p.text then
                                list[#list + 1] = p.text
                            end
                        end
                        ctx.planet_lists[name] = list
                    end
                elseif key:sub(1, 1) ~= "@" then
                    if not ctx.planet_classes[key] then
                        ctx.planet_class_order[#ctx.planet_class_order + 1] = key
                    end
                    ctx.planet_classes[key] = systems.planet_class(fs, key, e.value, pf.file)
                end
            end
        end
    end
    -- names (common/random_names/base): star_names, nebula_names, asteroid prefixes and postfixes
    ctx.names = {}
    for _, pf in ipairs(parse_files(fs, "common/random_names/base")) do
        for _, e in ipairs(pf.tree) do
            if e.op and e.key and type(e.value) == "table" then
                local list = {}
                for _, v in ipairs(e.value) do
                    if v.text then
                        list[#list + 1] = v.text
                    end
                end
                ctx.names[e.key.text] = list
            end
        end
    end
    -- the initializers by usage, in name order (the database's order is the files' [I])
    ctx.by_usage = {}
    local names = {}
    for name in pairs(ctx.initializers) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b)
        local da, db = ctx.initializers[a], ctx.initializers[b]
        if da.file ~= db.file then
            return da.file < db.file
        end
        return da.line < db.line
    end)
    ctx.initializer_order = names
    for _, name in ipairs(names) do
        for _, u in ipairs(fields(ctx.initializers[name].block, "usage")) do
            ctx.by_usage[u] = ctx.by_usage[u] or {}
            table.insert(ctx.by_usage[u], name)
        end
    end
    ctx.uses = {}         -- initializer -> times used (max_instances)
    return ctx
end

-- a planet class's numbers
function systems.planet_class(fs, key, b, file)
    local n = function(k, default)
        local v = scenario.number(fs, field(b, k), file)
        if v == nil then
            return default
        end
        return v
    end
    local c = {
        key = key,
        star = field(b, "star") == "yes",
        asteroid = field(b, "asteroid") == "yes",
        colonizable = field(b, "colonizable") == "yes",
        can_be_moon = field(b, "can_be_moon") ~= "no",
        spawn_odds = n("spawn_odds", 0),
        min_distance = n("min_distance_from_sun", 0),
        max_distance = n("max_distance_from_sun", 1000000),
        extra_orbit_size = n("extra_orbit_size", 0),
        extra_planet_count = n("extra_planet_count", 0),
        chance_of_ring = n("chance_of_ring", 0),
        has_potential = field(b, "potential") ~= nil,
    }
    c.size_min, c.size_max = scenario.interval(fs, field(b, "planet_size"), file)
    c.moon_min, c.moon_max = scenario.interval(fs, field(b, "moon_size"), file)
    c.size_min = c.size_min or 10
    c.size_max = c.size_max or c.size_min
    c.moon_min = c.moon_min or c.size_min
    c.moon_max = c.moon_max or c.size_max
    return c
end

-- ---------------------------------------------------------------------------------------------
-- triggers of usage_odds modifiers and neighbor_system triggers, on a system: the few the
-- initializers use; any other is counted (ctx.unknown_triggers) and the modifier is left out

local function eval(ctx, sys, block, game)
    -- AND of the statements
    for _, e in ipairs(block or {}) do
        if e.op and e.key then
            local r = systems.trigger(ctx, sys, e.key.text, e.value, game)
            if r == nil then
                return nil
            end
            if r ~= (e.op ~= "!=") then
                return false
            end
        end
    end
    return true
end

function systems.trigger(ctx, sys, key, v, game)
    local text = v.text
    if key == "AND" then
        return eval(ctx, sys, v, game)
    elseif key == "OR" then
        local any_unknown = false
        for _, e in ipairs(v) do
            if e.op and e.key then
                local r = systems.trigger(ctx, sys, e.key.text, e.value, game)
                if r == nil then
                    any_unknown = true
                elseif r then
                    return true
                end
            end
        end
        if any_unknown then
            return nil
        end
        return false
    elseif key == "NOT" or key == "NOR" then
        local r = key == "NOT" and eval(ctx, sys, v, game) or systems.trigger(ctx, sys, "OR", v, game)
        if r == nil then
            return nil
        end
        return not r
    elseif key == "NAND" then
        local r = eval(ctx, sys, v, game)
        if r == nil then
            return nil
        end
        return not r
    elseif key == "has_star_flag" then
        return sys.flags[text] ~= nil
    elseif key == "is_in_cluster" then
        return sys.clusters ~= nil and sys.clusters[text] == true
    elseif key == "is_fe_cluster" then
        local yes = sys.clusters ~= nil and sys.clusters.fe == true
        return yes == (text == "yes")
    elseif key == "host_has_dlc" or key == "has_dlc" then
        -- the DLCs the game owns (ctx.dlcs, newgame.generate: the install's); none given: every one
        return ctx.dlcs == nil or ctx.dlcs[text] == true
    elseif key == "is_bottleneck_system" then
        -- a system with one hyperlane [I]
        local yes = #sys.lanes == 1
        return yes == (text == "yes")
    elseif key == "always" then
        return text == "yes"
    elseif key == "has_global_flag" then
        return game.global_flags[text] ~= nil
    elseif key == "has_megastructure" then
        -- none yet: the gateways and relics come from init_effects, not run here
        return false
    elseif key == "any_neighbor_system" and type(v) == "table" then
        local unknown = false
        for _, l in ipairs(sys.lanes) do
            local r = eval(ctx, game.systems[l.to + 1], v, game)
            if r == nil then
                unknown = true
            elseif r then
                return true
            end
        end
        if unknown then
            return nil
        end
        return false
    elseif key == "any_system" and type(v) == "table" then
        local unknown = false
        for _, s in ipairs(game.systems) do
            local r = eval(ctx, s, v, game)
            if r == nil then
                unknown = true
            elseif r then
                return true
            end
        end
        if unknown then
            return nil
        end
        return false
    elseif key == "lgate_enabled" then
        return text == "yes"
    elseif key == "num_marauder_empires_to_spawn" then
        return nil
    elseif key == "is_marauder_cluster" then
        local yes = sys.clusters ~= nil and sys.clusters.marauder == true
        return yes == (text == "yes")
    end
    -- a scripted trigger (has_aquatics = yes: host_has_dlc = "Aquatics Species Pack"), when its
    -- block is one this evaluator knows
    local st = ctx.scripted_triggers and ctx.scripted_triggers[key]
    if st and (text == "yes" or text == "no") then
        local r = eval(ctx, sys, st.block, game)
        if r ~= nil then
            return r == (text == "yes")
        end
    end
    ctx.unknown_triggers[key] = (ctx.unknown_triggers[key] or 0) + 1
    return nil
end

-- usage_odds = 20, or { base = 20 modifier = { factor = 0 add = 1 <triggers> } ... }
local function odds(ctx, sys, v, file, game)
    if v == nil then
        return 1
    end
    if type(v) ~= "table" then
        return scenario.number(ctx.fs, v, file) or 0
    end
    local w = scenario.number(ctx.fs, field(v, "base"), file) or 1
    for _, e in ipairs(v) do
        if e.op and e.key and e.key.text == "modifier" and type(e.value) == "table" then
            local m = e.value
            local cond = {}
            for _, s in ipairs(m) do
                if s.op and s.key and s.key.text ~= "factor" and s.key.text ~= "add" then
                    cond[#cond + 1] = s
                end
            end
            if eval(ctx, sys, cond, game) then
                local add = scenario.number(ctx.fs, field(m, "add"), file)
                local factor = scenario.number(ctx.fs, field(m, "factor"), file)
                if add then
                    w = w + add
                end
                if factor then
                    w = w * factor
                end
            end
        end
    end
    return w
end

-- ---------------------------------------------------------------------------------------------
-- values and picks, as the game draws them

-- CStatInterval<int> (read `x` as { x, 0 }, `{ min max }` as { min, max - min }): the caller draws
-- r first, always; the value is min + (r % (|delta| + 1)) * sign(delta) (0xa09770, 0x87091f)
local function rnd_int(ctx, C, v, file, lo, hi)
    local r = C:int()
    local a, b = scenario.interval(ctx.fs, v, file)
    if a ~= nil then
        lo, hi = a, b
    end
    local delta = hi - lo
    if delta == 0 then
        return lo
    end
    local step = r % (math.abs(delta) + 1)
    return lo + (delta < 0 and -step or step)
end
systems.rnd_int = rnd_int

-- CStatInterval<CFixedPoint>::GetRandom (0xa09430): k = r % 1000, min + trunc(k * 100 * delta /
-- 100000) in raw fixed point: min + k * delta / 1000. r is drawn even when delta is 0
local function rnd_fx(ctx, C, v, file, lo, delta)
    local r = C:int()
    local a, b = scenario.interval(ctx.fs, v, file)
    local lo_raw, delta_raw
    if a ~= nil then
        lo_raw, delta_raw = fixed.from(a), fixed.from(b) - fixed.from(a)
    else
        lo_raw, delta_raw = fixed.from(lo or 0), fixed.from(delta or 0)
    end
    if delta_raw == 0 then
        return lo_raw / fixed.ONE
    end
    local k = r % 1000
    return (lo_raw + fixed.idiv(k * 100 * delta_raw, 100000)) / fixed.ONE
end
systems.rnd_fx = rnd_fx

-- PickRandomClassFromArray (0x4a7a90) / GetRandomClassForOrbit: t = draw % total, t -= w until
-- t <= 0 (the first with cumulative weight >= t); weights in raw fixed point
local function pick_le(r, weights)
    local total = 0
    for i = 1, #weights do
        total = total + weights[i]
    end
    if total <= 0 then
        return nil
    end
    local t = r:int() % total
    for i = 1, #weights do
        t = t - weights[i]
        if t <= 0 then
            return i
        end
    end
    return #weights
end
systems.pick_le = pick_le

-- GetWeightedRandomInternal (0x1b4ad80) on a draw x: total = sum of max(w, 0); none: `default`;
-- t = x % total (for a total over 2^31 - 1: floor(floor(total * 1000 / (2^31 - 1)) * x / 1000));
-- the first with cumulative weight > t
local function pick_gt(x, weights, default)
    local total = 0
    for i = 1, #weights do
        total = total + math.max(weights[i], 0)
    end
    if total <= 0 then
        return default
    end
    local t
    if total <= 2147483647 then
        t = x % total
    else
        t = math.floor(math.floor(total * 1000 / 2147483647) * x / 1000)
    end
    local cum = 0
    for i = 1, #weights do
        cum = cum + math.max(weights[i], 0)
        if cum > t then
            return i
        end
    end
    return default
end
systems.pick_gt = pick_gt

-- ---------------------------------------------------------------------------------------------
-- star classes (CPrescriptedSystem::GetClass 0x507be0): a named class without a draw; `random` or a
-- randomizer (`rl_standard_stars`): a draw r of the global stream seeds a local stream
-- { noise32(r, 0x5EA6BA9F), 0 }, which picks by spawn_odds

local function star_odds(ctx, sc)
    local d = ctx.star_classes[sc]
    return fixed.from(d and scenario.number(ctx.fs, field(d.block, "spawn_odds"), d.file) or 0)
end

function systems.star_class(ctx, C, class)
    local names
    local list = ctx.star_lists[class]
    if list then
        names = {}
        for _, s in ipairs(field(list.block, "stars") or {}) do
            if s.text and ctx.star_classes[s.text] then
                names[#names + 1] = s.text
            end
        end
    elseif class == "random" then
        names = ctx.star_class_order
    elseif ctx.star_classes[class] then
        return class
    else
        ctx.missing[tostring(class)] = (ctx.missing[tostring(class)] or 0) + 1
        return "sc_g"
    end
    local L = rng.new(rng.noise32(C:int(), rng.SEED_SALT), 0)
    local weights = {}
    for i, n in ipairs(names) do
        weights[i] = star_odds(ctx, n)
    end
    local i = pick_le(L, weights)
    return i and names[i] or "sc_g"
end

-- the star class's planet (`planet = { key = pc_g_star }`; multi-star classes list several)
local function star_planet(ctx, sc, index)
    local s = ctx.star_classes[sc]
    local keys = {}
    for _, p in ipairs(s and fields(s.block, "planet") or {}) do
        local k = type(p) == "table" and field(p, "key")
        if k then
            keys[#keys + 1] = k
        end
    end
    return keys[(index or 0) + 1] or keys[1] or "pc_g_star"
end

-- the star class of a star planet class (pc_k_star -> sc_k): the first single-star class with it
function systems.star_of_planet(ctx, key)
    if not ctx.star_of_planet then
        ctx.star_of_planet = {}
        for _, sc in ipairs(ctx.star_class_order) do
            local ps = fields(ctx.star_classes[sc].block, "planet")
            if #ps == 1 and type(ps[1]) == "table" then
                local k = field(ps[1], "key")
                if k and not ctx.star_of_planet[k] then
                    ctx.star_of_planet[k] = sc
                end
            end
        end
    end
    return ctx.star_of_planet[key]
end

-- ---------------------------------------------------------------------------------------------
-- planet classes (CPrescriptedPlanet::CalcPlanetClass 0x506670)

-- GetRandomClassForOrbit (0xd36690): the planet classes in database order but asteroids; the odds
-- the nearest star's class gives (`pc_x = { spawn_odds = f }`, raw) or the class's spawn_odds
-- (colonizable ones x max(habitability, 0.25)); colonizable ones x the scenario's
-- colonizable_planet_odds; those with odds > 0, the distance d within [min, max]_distance_from_sun
-- and, for a moon, can_be_moon; a draw of the generator's stream picks
local function class_for_orbit(ctx, G, game, star_class, d, moon, filter)
    local cfg, sc = game.inputs.config, game.inputs.scenario
    local names, weights = {}, {}
    local s = ctx.star_classes[star_class]
    for _, pc in ipairs(ctx.planet_class_order) do
        local c = ctx.planet_classes[pc]
        if c and not c.asteroid and not c.star and (not filter or filter(pc, c)) then
            local w
            local over = s and field(s.block, pc)
            local f = type(over) == "table" and scenario.number(ctx.fs, field(over, "spawn_odds"), s.file)
            if f and f >= 0 then
                w = f
            else
                w = c.spawn_odds
                if c.colonizable then
                    w = w * math.max(cfg.habitability or 1, 0.25)
                end
            end
            if c.colonizable then
                w = w * (sc.colonizable_planet_odds or 1)
            end
            if w > 0 and d >= c.min_distance and d <= c.max_distance and (not moon or c.can_be_moon) then
                names[#names + 1] = pc
                weights[#weights + 1] = fixed.from(w)
            end
        end
    end
    local i = pick_le(G, weights)
    return i and names[i] or nil
end

local function asteroid_class(ctx, G)
    local names, weights = {}, {}
    for _, pc in ipairs(ctx.planet_class_order) do
        local c = ctx.planet_classes[pc]
        if c and c.asteroid and c.spawn_odds > 0 then
            names[#names + 1] = pc
            weights[#weights + 1] = fixed.from(c.spawn_odds)
        end
    end
    local i = pick_le(G, weights)
    return i and names[i] or nil
end

-- a planet entry's class at distance d from the nearest star (of class st.star)
function systems.calc_class(ctx, G, game, sys, entry, st, moon)
    local class = entry.class or "random"
    local empire = game.init_empire
    if class == "none" then
        return nil
    elseif class == "star" then
        local key = star_planet(ctx, sys.star_class, st.star_index)
        st.star_index = (st.star_index or 0) + 1
        return key
    elseif class == "random" then
        return class_for_orbit(ctx, G, game, st.star, st.d, moon)
    elseif class == "random_colonizable" then
        return class_for_orbit(ctx, G, game, st.star, st.d, moon, function(_, c) return c.colonizable end)
    elseif class == "random_non_colonizable" then
        return class_for_orbit(ctx, G, game, st.star, st.d, moon, function(_, c) return not c.colonizable end)
    elseif class == "random_non_ideal" then
        local ideal = empire and empire.planet_class
        return class_for_orbit(ctx, G, game, st.star, st.d, moon, function(pc) return pc ~= ideal end)
    elseif class == "random_asteroid" then
        return asteroid_class(ctx, G)
    elseif class == "ideal_planet_class" then
        if empire and empire.planet_class then
            return empire.planet_class
        end
        return class_for_orbit(ctx, G, game, st.star, st.d, moon, function(_, c) return c.colonizable end)
    elseif class == "ideal_design_class" then
        if empire and (empire.design_class or empire.planet_class) then
            return empire.design_class or empire.planet_class
        end
        return class_for_orbit(ctx, G, game, st.star, st.d, moon, function(_, c) return c.colonizable end)
            or class_for_orbit(ctx, G, game, st.star, st.d, moon)
    end
    -- a home planet of an empire takes the empire's class; a planet class by name; a random list
    -- of planet classes: a uniform pick (the draw made even if it then fails)
    if entry.home and empire and empire.planet_class then
        return empire.planet_class
    end
    if ctx.planet_classes[class] then
        return class
    end
    local list = ctx.planet_lists[class]
    local k = G:int()
    if list and #list > 0 then
        return list[k % #list + 1]
    end
    ctx.unknown_classes[class] = (ctx.unknown_classes[class] or 0) + 1
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- names

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV",
    "XV", "XVI", "XVII", "XVIII", "XIX", "XX", "XXI", "XXII", "XXIII", "XXIV", "XXV" }

-- a name taken from the random name database (CRandomNameDatabase, filled from
-- common/random_names by FillDatabase): a draw of the stream % the names left, the name swapped
-- with the last and removed (TakeStarName 0x906e10, TakeNebulaName 0x907760: the global stream)
function systems.take_name(ctx, list_name, r)
    ctx.name_db = ctx.name_db or {}
    local list = ctx.name_db[list_name]
    if not list then
        list = {}
        for i, n in ipairs(ctx.names[list_name] or {}) do
            list[i] = n
        end
        ctx.name_db[list_name] = list
    end
    if #list == 0 then
        return list_name
    end
    local k = r:int() % #list + 1
    local name = list[k]
    list[k] = list[#list]
    list[#list] = nil
    return name
end

local function star_name(sys, i, n)
    return { key = string.format("STAR_NAME_%d_OF_%d", i, n), variables = { { "NAME", sys.name } } }
end

local function planet_name(sys, numeral)
    return { key = "PLANET_NAME_FORMAT", variables = { { "PARENT", sys.name },
        { "NUMERAL", { key = ROMAN[numeral] or tostring(numeral), literal = true } } } }
end

local function moon_name(parent, i)
    return { key = "SUBPLANET_NAME_FORMAT", variables = { { "PARENT", parent.name },
        { "NUMERAL", { key = string.char(96 + i), literal = true } } } }
end

local function asteroid_name(ctx)
    local pre, post = ctx.names.asteroid_prefix or { "A" }, ctx.names.asteroid_postfix or { "1" }
    ctx.asteroid_n = (ctx.asteroid_n or 0) + 1
    local n = ctx.asteroid_n
    return { key = "ASTEROID_NAME_FORMAT", variables = {
        { "prefix", pre[n % #pre + 1] }, { "suffix", post[(n * 7) % #post + 1] } } }
end

-- ---------------------------------------------------------------------------------------------
-- planets (CGalacticObject::InitializeSystem 0x870250, CPlanet::InitializePlanet 0xe09f90,
-- InitializeSubPlanets 0x86fb50)

-- the planet entries of a block, in order: `planet = { }`, `change_orbit = x` (an entry of class
-- none and orbit_distance x), `moon = { }` (in a planet: its sub-planets)
local function entries(ctx, block, file, moon_key)
    local out = {}
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text
            if (k == "planet" or (moon_key and k == "moon")) and type(e.value) == "table" then
                local b = e.value
                out[#out + 1] = {
                    block = b, file = file, class = field(b, "class"), count = field(b, "count"),
                    orbit_distance = field(b, "orbit_distance"), orbit_angle = field(b, "orbit_angle"),
                    size = field(b, "size"), has_ring = field(b, "has_ring"), home = field(b, "home_planet") == "yes" or field(b, "starting_planet") == "yes",
                    moon = k == "moon",
                }
            elseif k == "change_orbit" then
                out[#out + 1] = { file = file, class = "none", orbit_distance = e.value.text or e.value, change = true }
            end
        end
    end
    return out
end

local function new_planet(game, sys, class, size, orbit, angle, parent)
    local id = #game.planet_ids
    local p = {
        id = id, system = sys.id, class = class, size = size, orbit = orbit, angle = angle,
        flags = {}, moons = {},
    }
    -- the coordinate: a = angle * 3.142 / 180; parent + (fixmul(-cos a, r), fixmul(-sin a, r))
    local a = fixed.div(fixed.mul(fixed.from(angle), 314200), 18000000)
    local r = fixed.from(orbit)
    local cx, cy = 0, 0
    if parent then
        cx, cy = fixed.from(parent.x), fixed.from(parent.y)
        p.moon_of = parent.id
        parent.moons[#parent.moons + 1] = id
    end
    p.x = fixed.clamp500(cx + fixed.mul(-fixed.cos(a), r)) / fixed.ONE
    p.y = fixed.clamp500(cy + fixed.mul(-fixed.sin(a), r)) / fixed.ONE
    game.planets[id] = p
    game.planet_ids[#game.planet_ids + 1] = id
    sys.planets[#sys.planets + 1] = id
    return p
end

local make_entries

-- one planet entry (count planets, or moons around `parent`); returns the extent reached
local function make_entry(ctx, G, C, game, sys, e, st, parent)
    local count = rnd_int(ctx, C, e.count, e.file, 1, 1)
    local extent = 0
    for _ = 1, count do
        -- the nearest star (none yet: the system's class at distance 0)
        if not parent and #st.stars > 0 then
            local best, bd = nil, math.huge
            for _, s in ipairs(st.stars) do
                local dd = math.abs(st.cum - s.orbit)
                if dd < bd then
                    best, bd = s, dd
                end
            end
            st.d, st.star = bd, best.class
        elseif parent then
            st.d = math.abs(st.parent_d - st.cum)
        end
        -- the class at the distance before this planet's orbit_distance
        local class = systems.calc_class(ctx, G, game, sys, e, st, parent ~= nil)
        st.cum = st.cum + rnd_fx(ctx, C, e.orbit_distance, e.file, 10, 10)
        local c = class and ctx.planet_classes[class]
        if c then
            if c.star then
                st.stars[#st.stars + 1] = { orbit = st.cum, class = systems.star_of_planet(ctx, class) or sys.star_class }
                st.d = 0
            end
            local lo, hi = c.size_min, c.size_max
            if parent then
                lo, hi = c.moon_min, c.moon_max
            end
            local size = rnd_int(ctx, C, e.size, e.file, lo, hi)
            -- RandomizePlanetModifiers (0xe09f20): draws until the pick is no modifier; taken as
            -- one draw that picks none
            C:int()
            st.angle = st.angle + rnd_fx(ctx, C, e.orbit_angle, e.file, 90, 180)
            local p = new_planet(game, sys, class, size, st.cum, st.angle, parent)
            if e.block then
                for _, f in ipairs(field(e.block, "flags") or {}) do
                    if f.text then
                        p.flags[f.text] = game.flag_date
                    end
                end
                p.modifier = field(e.block, "modifier")
                p.anomaly = field(e.block, "anomaly")
            end
            if c.star then
                st.star_planets[#st.star_planets + 1] = p
            elseif c.asteroid then
                p.name = asteroid_name(ctx)
            elseif parent then
                parent.moon_n = (parent.moon_n or 0) + 1
                p.name = moon_name(parent, parent.moon_n)
            else
                st.numeral = st.numeral + 1
                p.name = planet_name(sys, st.numeral)
            end
            if e.home then
                st.home_planets[#st.home_planets + 1] = p
            end
            -- the ring: has_ring if set; else (not a moon) a draw against chance_of_ring
            if e.has_ring == "yes" then
                p.has_ring = true
            elseif e.has_ring == nil and not parent then
                if math.floor(c.chance_of_ring * 100000) > C:int() % 100000 then
                    p.has_ring = true
                end
            end
            -- the planet's init_effect: two draws for its scope; the effect is the script's part
            local ie = e.block and field(e.block, "init_effect")
            if type(ie) == "table" then
                C:int()
                C:int()
                game.init_effects[#game.init_effects + 1] = { kind = "planet", id = p.id, block = ie,
                    file = e.file, initializer = sys.initializer }
            end
            -- the sub-planets (moons), from their own orbit 0 around this one
            local sub = e.block and entries(ctx, e.block, e.file, true) or {}
            local moon_extent = 0
            if #sub > 0 then
                local mst = { cum = 0, angle = 0, stars = {}, star = st.star, d = st.d, parent_d = st.d,
                    numeral = 0, home_planets = st.home_planets, star_planets = st.star_planets }
                moon_extent = make_entries(ctx, G, C, game, sys, sub, mst, p)
            end
            extent = math.max(extent, st.cum + moon_extent)
        end
    end
    return extent
end

function make_entries(ctx, G, C, game, sys, list, st, parent)
    local extent = 0
    for _, e in ipairs(list) do
        extent = math.max(extent, make_entry(ctx, G, C, game, sys, e, st, parent))
    end
    return extent
end

-- ---------------------------------------------------------------------------------------------
-- an initializer applied to a system (CGalacticObject::InitializeSystem 0x870250)

local function register_use(ctx, name)
    ctx.uses[name] = (ctx.uses[name] or 0) + 1
end

-- systems.initialize(ctx, sys, name, G, game[, parent]) -> true | nil, message. G: the generator's
-- stream; the global stream is game.global.
function systems.initialize(ctx, sys, name, G, game, parent)
    local C = game.global
    local def = ctx.initializers[name]
    if not def then
        ctx.missing[name] = (ctx.missing[name] or 0) + 1
        return nil, "no initializer " .. tostring(name)
    end
    local block, file = def.block, def.file
    if field(block, "inline_script") then
        block = source.expand(ctx.fs, block) or block
    end
    register_use(ctx, name)
    ctx.used[name] = (ctx.used[name] or 0) + 1
    sys.initializer = name
    sys.init_parent = parent and parent.id or nil
    game.init_order = game.init_order or {}
    game.init_order[#game.init_order + 1] = sys.id
    sys.star_class = systems.star_class(ctx, C, field(block, "class") or "random")
    local nm = field(block, "name")
    if nm then
        sys.name = nm
    elseif not sys.name then
        local cls = ctx.star_classes[sys.star_class]
        local black = cls and field(cls.block, "class") == "black_hole"
        sys.name = systems.take_name(ctx, black and "black_hole_names" or "star_names", C)
    end
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text == "asteroid_belt" and type(e.value) == "table" then
            sys.belts[#sys.belts + 1] = {
                type = field(e.value, "type") or "rocky_asteroid_belt",
                inner_radius = rnd_fx(ctx, C, field(e.value, "radius"), file, 0, 0),
            }
        end
    end
    for _, f in ipairs(field(block, "flags") or {}) do
        if f.text then
            sys.flags[f.text] = game.flag_date
        end
    end
    local st = { cum = 0, angle = 0, d = 0, star = sys.star_class, stars = {}, numeral = 0,
        home_planets = {}, star_planets = {} }
    local extent = make_entries(ctx, G, C, game, sys, entries(ctx, block, file, false), st, nil)
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text == "orbital_line" then
            C:int()
        end
    end
    for i, p in ipairs(st.star_planets) do
        p.name = star_name(sys, i, #st.star_planets)
    end
    sys.home_planets = st.home_planets
    -- CalculateRadius: inner = max(extent + 30, SYSTEM_MIN_INNER_RADIUS 150), outer = inner + 100
    sys.inner_radius = math.max(extent + 30, 150)
    sys.outer_radius = sys.inner_radius + 100
    -- the initializer's init_effect runs now, on the tree's scope (the script's part)
    local ie = field(block, "init_effect")
    if type(ie) == "table" then
        game.init_effects[#game.init_effects + 1] = { kind = "system", id = sys.id, block = ie, file = file,
            initializer = name }
    end
    sys.def_block, sys.def_file = block, file
    return true
end

-- ---------------------------------------------------------------------------------------------
-- initializer trees (InitializeQueue 0x97ded0, MakeNeighborInitState 0x97d380)

-- the hyperlane jumps and distances from a system (breadth first; Dijkstra on the lengths)
local function paths_from(game, sys)
    local jumps = { [sys.id] = 0 }
    local queue, qi = { sys }, 1
    while qi <= #queue do
        local s = queue[qi]
        qi = qi + 1
        for _, l in ipairs(s.lanes) do
            if jumps[l.to] == nil then
                jumps[l.to] = jumps[s.id] + 1
                queue[#queue + 1] = game.systems[l.to + 1]
            end
        end
    end
    return jumps
end

-- the hyperlane distances from a system (Dijkstra on the lengths, a binary heap)
local function distances_from(game, sys)
    local dist, done = { [sys.id] = 0 }, {}
    local heap = { { 0, sys.id } }
    local function push(d, id)
        heap[#heap + 1] = { d, id }
        local i = #heap
        while i > 1 do
            local p = math.floor(i / 2)
            if heap[p][1] <= heap[i][1] then
                break
            end
            heap[p], heap[i] = heap[i], heap[p]
            i = p
        end
    end
    local function pop()
        local top = heap[1]
        heap[1] = heap[#heap]
        heap[#heap] = nil
        local i = 1
        while true do
            local l, r, m = 2 * i, 2 * i + 1, i
            if heap[l] and heap[l][1] < heap[m][1] then
                m = l
            end
            if heap[r] and heap[r][1] < heap[m][1] then
                m = r
            end
            if m == i then
                break
            end
            heap[m], heap[i] = heap[i], heap[m]
            i = m
        end
        return top
    end
    while #heap > 0 do
        local top = pop()
        local d, id = top[1], top[2]
        if not done[id] then
            done[id] = true
            for _, l in ipairs(game.systems[id + 1].lanes) do
                local nd = d + l.length
                if dist[l.to] == nil or nd < dist[l.to] then
                    dist[l.to] = nd
                    push(nd, l.to)
                end
            end
        end
    end
    return dist
end

local TWO_PI = 2 * math.pi

-- the next neighbour of a state, or nil: each call looks at one neighbor_system entry
local function next_neighbor(ctx, G, game, state, queued)
    local list = state.neighbors
    while state.next <= #list do
        local nb = list[state.next]
        state.next = state.next + 1
        local b, file = nb, state.file
        local name = field(b, "initializer")
        local chance = scenario.number(ctx.fs, field(b, "spawn_chance"), file) or 100
        local roll = G:int() % 100
        if roll <= chance and name and ctx.initializers[name] then
            local sys = state.sys
            local dmin, dmax = scenario.interval(ctx.fs, field(b, "distance"), file)
            local hmin, hmax = scenario.interval(ctx.fs, field(b, "hyperlane_distance"), file)
            local jmin, jmax = scenario.interval(ctx.fs, field(b, "hyperlane_jumps"), file)
            local amin = (scenario.number(ctx.fs, field(b, "min_orientation_angle"), file) or 0) * 3.142 / 180
            local amax = (scenario.number(ctx.fs, field(b, "max_orientation_angle"), file) or 360) * 3.142 / 180
            dmin, dmax = dmin or 0, dmax or 1000
            if not state.jumps then
                state.jumps = paths_from(game, sys)
            end
            if hmin ~= nil and not state.dist then
                state.dist = distances_from(game, sys)
            end
            if not state.order then
                -- the systems by squared distance from this one (stable)
                local order = {}
                for _, t in ipairs(game.systems) do
                    if t ~= sys then
                        local dx, dy = t.x - sys.x, t.y - sys.y
                        order[#order + 1] = { t = t, d2 = dx * dx + dy * dy, a = math.atan2(-dy, -dx) % TWO_PI }
                    end
                end
                table.sort(order, function(x, y)
                    if x.d2 ~= y.d2 then
                        return x.d2 < y.d2
                    end
                    return x.t.id < y.t.id
                end)
                state.order = order
            end
            local trig = field(b, "trigger")
            if type(trig) == "table" and #trig == 0 then
                trig = nil
            end
            for _, o in ipairs(state.order) do
                local t = o.t
                if o.d2 > dmax * dmax then
                    break
                end
                if o.d2 >= dmin * dmin and not t.initializer and not queued[t.id] and not t.owner
                    and o.a >= amin and o.a <= amax then
                    local j = state.jumps[t.id]
                    local hd = state.dist and state.dist[t.id]
                    if (jmin == nil or (j and j >= jmin and j <= jmax)) and (hmin == nil or (hd and hd >= hmin and hd <= hmax)) then
                        local ok = true
                        if trig then
                            G:int()
                            ok = eval(ctx, t, trig, game) ~= false
                        end
                        if ok then
                            return t, name
                        end
                    end
                end
            end
            if state.mandatory then
                local t = systems.create_neighbor_system(ctx, G, game, sys, dmin, dmax, amin, amax)
                if t then
                    return t, name
                end
            end
        end
    end
    return nil
end

-- CreateSystemForNeighbor (0x97c7c0): a new system at a random distance and angle from the
-- parent (SPAWN_SYSTEM_ATTEMPTS = 15 tries, 3 draws each), joined to it by a hyperlane
function systems.create_neighbor_system(ctx, G, game, parent, dmin, dmax, amin, amax)
    local galaxy = require("engine.newgame.galaxy")
    local lanes = require("engine.newgame.lanes")
    local min_dist = game.inputs.shape.stars_min_dist
    for _ = 1, 15 do
        local d = dmin + (G:int() % 1000) * (dmax - dmin) / 1000
        local u = fixed.u(G) / fixed.ONE
        local a = amin + u * (amax - amin)
        local x, y = parent.x - math.cos(a) * d, parent.y - math.sin(a) * d
        local ok = math.abs(x) <= 500 and math.abs(y) <= 500
        for _, s in ipairs(game.systems) do
            if ok and (s.x - x) ^ 2 + (s.y - y) ^ 2 < min_dist * min_dist then
                ok = false
            end
        end
        if ok then
            local s = galaxy.new_system(game, math.floor(x * 100 + 0.5) / 100, math.floor(y * 100 + 0.5) / 100)
            s.partition = parent.partition
            lanes.add(parent, s, math.floor(math.sqrt((parent.x - s.x) ^ 2 + (parent.y - s.y) ^ 2)), false)
            game.created_systems = (game.created_systems or 0) + 1
            return s
        end
    end
    return nil
end

-- InitializeQueue: the systems of the queue initialized, then their neighbours (one per state per
-- round, round-robin) as the next layer, until no layer is left
function systems.run_queue(ctx, G, game, queue)
    local queued = {}
    for _, q in ipairs(queue) do
        queued[q.sys.id] = true
    end
    local processed, total = 0, #queue
    while processed < total do
        for j = processed + 1, total do
            local q = queue[j]
            -- the state's context: an empire's (its ideal planet class), copied to its neighbours
            game.init_empire = q.empire
            systems.initialize(ctx, q.sys, q.name, G, game, q.parent)
            game.init_empire = nil
            local def = ctx.initializers[q.name]
            q.neighbors, q.next, q.file = {}, 1, def and def.file
            q.mandatory = def and field(q.sys.def_block or def.block, "mandatory_neighbors") == "yes"
            for _, e in ipairs(q.sys.def_block or (def and def.block) or {}) do
                if e.op and e.key and e.key.text == "neighbor_system" and type(e.value) == "table" then
                    q.neighbors[#q.neighbors + 1] = e.value
                end
            end
        end
        local new_total = total
        repeat
            local any = false
            for j = processed + 1, total do
                local q = queue[j]
                local t, name = next_neighbor(ctx, G, game, q, queued)
                if t then
                    queued[t.id] = true
                    new_total = new_total + 1
                    queue[new_total] = { sys = t, name = name, parent = q.sys, empire = q.empire }
                    any = true
                end
            end
        until not any
        processed, total = total, new_total
    end
end

-- InitializeWholeTree (0x97e200): a tree from one system (one draw of the global stream seeds the
-- tree's script scope)
function systems.initialize_tree(ctx, G, game, sys, name)
    game.global:int()
    systems.run_queue(ctx, G, game, { { sys = sys, name = name } })
end

-- ---------------------------------------------------------------------------------------------
-- the systems left (InitializeUninitializedSystems 0x97e5c0)

-- scaled_spawn_settings = num_gateways: the setting scales spawn_chance and max_instances
local function settings_scale(ctx, def, game)
    local s = field(def.block, "scaled_spawn_settings")
    if not s then
        return 1
    end
    local v = game.inputs.config[s]
    return tonumber(v) or 1
end

-- GetSpawnChance (0x5089b0): scaled_spawn_chance * systems / 100 rounded when given, else
-- spawn_chance (100); times the setting, rounded
local function spawn_chance(ctx, def, game)
    local b, file = def.block, def.file
    local scaled = scenario.number(ctx.fs, field(b, "scaled_spawn_chance"), file)
    local chance = scenario.number(ctx.fs, field(b, "spawn_chance"), file) or 100
    if scaled and scaled > 0 then
        chance = math.floor(scaled * #game.systems / 100 + 0.5)
    end
    return math.floor(chance * settings_scale(ctx, def, game) + 0.5)
end

-- HasReachedMaxUses (0x50b450): uses >= round(max_instances * the setting)
local function at_max(ctx, def, name, game)
    local max = scenario.number(ctx.fs, field(def.block, "max_instances"), def.file)
    if not max or max < 0 then
        return false
    end
    return (ctx.uses[name] or 0) >= math.floor(max * settings_scale(ctx, def, game) + 0.5)
end

-- GetRandomFromList (0x50a830): the list's initializers not at their most uses, weighted by
-- usage_odds (a primitive system's x the primitive setting), a draw of the generator's stream
function systems.random_from_list(ctx, G, game, sys, names)
    local cand, weights = {}, {}
    local primitive = game.inputs.config.primitive or 1
    for _, name in ipairs(names) do
        local def = ctx.initializers[name]
        if not at_max(ctx, def, name, game) then
            local w = odds(ctx, sys, field(def.block, "usage_odds"), def.file, game)
            if field(def.block, "primitive_system") == "yes" then
                w = w * primitive
            end
            if w >= 0 then
                cand[#cand + 1] = name
                weights[#weights + 1] = fixed.from(w)
            end
        end
    end
    if #cand == 0 then
        return nil
    end
    local x = G:int()
    local i = pick_gt(x, weights, x % #cand + 1)
    return cand[i]
end

-- a randomizer class costs a draw of the global stream when checked (GetClass as a validity check)
local function class_check(ctx, game, name)
    local def = ctx.initializers[name]
    local class = def and field(def.block, "class") or "random"
    if class == "random" or ctx.star_lists[class] then
        game.global:int()
    end
end
systems.class_check = class_check

-- every system without an initializer, in order: a pick, then draw % 100 against its spawn chance;
-- a pick that fails its roll still counts a use (RegisterUse) and the system picks again
function systems.initialize_rest(ctx, G, game)
    local names = ctx.by_usage.misc_system_init or {}
    for _, sys in ipairs(game.systems) do
        if not sys.initializer then
            local chosen
            for _ = 1, 10000 do
                local name = systems.random_from_list(ctx, G, game, sys, names)
                if not name then
                    break
                end
                if G:int() % 100 < spawn_chance(ctx, ctx.initializers[name], game) then
                    chosen = name
                    break
                end
                register_use(ctx, name)
            end
            if not chosen then
                game.failed_systems = (game.failed_systems or 0) + 1
                chosen = "basic_init_01"
            end
            class_check(ctx, game, chosen)
            systems.initialize_tree(ctx, G, game, sys, chosen)
        end
    end
end

return systems
