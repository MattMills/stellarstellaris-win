-- engine/fleets/stations.lua : the stations construction ships build (GOG 4.5.2, docs/stations.md):
-- the build order (CBuildOrbitalStationFleetOrder) started, ticked and finished, and what finishing
-- one puts in the world, in the save's own form:
--
--   an orbital station (mining, research, observation; EShipClass 5, 6, 9): a station ship and its
--     fleet in orbit of the planet; the planet's shipclass_orbital_station, its controller
--   a starbase (an outpost, EShipClass 10): the station ship and its fleet, a `starbases` entry with
--     its own construction queue and its own copy of the country's outpost design; the system's
--     `starbases` (the first entry is the primary starbase), so the system's owner; the planet's
--     orbital_defence and controller; the borders recomputed (CGameState::CalcBorders), the
--     system's sector, on_system_gained
--
-- The order (fleet = { current_order = { build_orbital_station_order = { deposit_holder = { type
-- id } progress cost in_progress class ship_design = { design upgrade growth_stage } resources = {
-- } sub_order can_reach order_id commissioner } } }):
--
--   start   CBuildOrbitalStationFleetOrder::StartOrder (0xcdf390): the resources held refunded, the
--           cost (CalcCost 0xce1eb0) paid from the stockpile into `resources`, progress 0; the
--           order cancelled when the stockpile cannot pay
--   tick    TickOrder (0xcdfac0): away from the build position (GetTargetCoord 0xcdf7e0: 5.0 from
--           the station's place toward the fleet) a move sub-order; there, progress +=
--           CONSTRUCTION_SHIP_WORK_SPEED_MULT
--   done    IsDone (0xce0f50): progress >= 100 (CFleetOrder::GetNeededProgress 0x1b1140)
--   finish  Finish (0xce0290): CDepositHolder::CanCreateOrbitalStation, CalcShipDesign (0xce0170),
--           CDepositHolder::CreateOrbitalStation (0xd93c80 -> 0xd945a0); a starbase on the
--           system's star: CGameState::CalcBorders (0x2550f0); an AI country building a starbase:
--           CFleetSetExpansionFlag (0xa6a020: ai.dirty_expand_strategy)
--
-- API:
--   stations.order                     { start, tick, is_done, finish } (engine.fleets.orders runs
--                                      build_orbital_station_order through it)
--   stations.create(country, planet, class[, builder fleet]) -> station fleet | nil, why
--   stations.build_order(fleet, planet, class) -> the order block (the save's form, for
--                                      orders.issue): CFleetBuildOrbitalStationCommand's order
--   stations.cost(country, planet, class) -> { res = amount }   CalcCost
--   stations.station_coordinate(planet, class) -> raw { x y origin }, stations.target_coordinate
--   stations.latest_design(country, class) -> design id   GetLatestOrbitalShipDesignOfClass
--   stations.new_id(store) -> id, entry; stations.place(store, id, entry, block): the databases'
--                                      ids (index | generation << 24, free slots first)
--   stations.update_borders(countries)  NBordersUtil::CalcBorders and the diplomacy border caches
--   stations.CLASS[token] -> EShipClass, stations.CLASS_NAME[n]
-- Not modelled: the starbase's modules and buildings (an outpost has none), the defense
-- platforms, CCountry::AbandonOrDisbandStationsAndStructures / TakeAbandoned..., the subject's
-- expansion tithe, the relations' border_range, the station's on_entered_orbit side effects, the
-- messages and telemetry.

local world = require("engine.world")
local defs = require("engine.defs")
local path = require("engine.fleets.path")
local ffi = require("ffi")
local live = require("engine.store.live")   -- the store's copy of what exploration reads (docs/data_layer.md)

local I64 = ffi.typeof("int64_t")
local raw, text, fmul, fdiv = path.raw, path.text, path.fmul, path.fdiv
local FP, NO_ID, GEN = 100000, 4294967295, 16777216

local stations = {
    stats = { started = 0, paid = 0, cancelled = 0, ticked = 0, moves = 0, finished = 0, built = {},
              failed = 0, draws = 0, on_actions = 0, borders = 0, sectors = 0, refunded = 0 },
    built = {},     -- { date, country, class, planet, system, fleet, ship, starbase }
    failures = {},
}
local S = stations.stats

-- EShipClass (the PDB's enum) and the save's tokens
local CLASS = {
    shipclass_military = 0, shipclass_constructor = 1, shipclass_colonizer = 2, shipclass_science_ship = 3,
    shipclass_transport = 4, shipclass_mining_station = 5, shipclass_research_station = 6,
    shipclass_military_station = 7, shipclass_observation_station = 9, shipclass_starbase = 10,
}
local CLASS_NAME = {}
for k, v in pairs(CLASS) do CLASS_NAME[v] = k end
stations.CLASS, stations.CLASS_NAME = CLASS, CLASS_NAME

local function count(t, k)
    t[k] = (t[k] or 0) + 1
end

local function today()
    local e = package.loaded["engine"]
    if e and e.date_text then
        local ok, d = pcall(e.date_text)
        if ok and d then return d end
    end
    return world.meta.date and tostring(world.meta.date):gsub('"', "") or "?"
end

-- ---------------------------------------------------------------------------------------------
-- defines

local D
local function defines()
    if D then
        return D
    end
    local function v(key, default)
        for _, g in ipairs({ "NGameplay", "NEconomy", "NAI" }) do
            local d = defs.get("common/defines", g)
            local x = d and defs.field(d.block, key)
            if x ~= nil then
                return tonumber(x) or x
            end
        end
        return default
    end
    D = {
        WORK_SPEED = v("CONSTRUCTION_SHIP_WORK_SPEED_MULT", 1),
        OFFSET = v("CONSTRUCTION_SHIP_STATION_OFFSET", 5),
        MIN_SIZE = v("PLANET_ORBIT_DISTANCE_MIN_SIZE", 10),
        SIZE_SCALE = v("PLANET_ORBIT_DISTANCE_SIZE_SCALE", 0.33),
        STATION_DIST = v("PLANET_STATION_ORBIT_DISTANCE", 6),
        STARBASE_DIST = v("STARBASE_ORBIT_DISTANCE", 15),
        BASE_LEVEL = v("STARBASE_BASE_LEVEL", "starbase_level_outpost"),
        EXP_BASE = v("EXPANSION_COST_BASE", 75),
        EXP_DIST = v("EXPANSION_COST_DISTANCE", 75),
        EXP_MAX = v("EXPANSION_COST_MAX", 1000),
    }
    return D
end
stations.defines = defines

-- ---------------------------------------------------------------------------------------------
-- the save's form: blocks

local function entry(key, value)
    return { key = { text = key }, op = "=", value = value }
end

local function tok(v, quoted)
    return { text = type(v) == "number" and world.number_text(v) or tostring(v), quoted = quoted or nil }
end

local function find(block, key)
    for i, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e, i
        end
    end
    return nil
end

local function remove_key(block, key)
    local e = find(block, key)
    while e do
        world.remove_entry(block, e)
        e = find(block, key)
    end
end

-- a deep copy of a parsed block (statements, bare values, anonymous blocks)
local function copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = copy(x)
    end
    return out
end
stations.copy = copy

-- `key = value` set in place, or inserted after the first of `after` present (else at the end)
local function put(block, key, value, after)
    local v = type(value) == "table" and value or tok(value)
    local e, i = find(block, key)
    if e then
        -- through the world, which keeps its field index
        if v.text ~= nil and e.value.text ~= nil then
            world.set(block, key, v.text)
            e.value.quoted = v.quoted
        else
            world.remove_entry(block, e)
            world.insert(block, i, key, v)
        end
        return
    end
    local pos = #block + 1
    for _, a in ipairs(after or {}) do
        local _, i = find(block, a)
        if i then
            pos = i + 1
            break
        end
    end
    world.insert(block, pos, key, v)
end

local function coord_block(c)
    local b = {}
    world.append(b, "x", text(c.x))
    world.append(b, "y", text(c.y))
    world.append(b, "origin", c.origin or NO_ID)
    return b
end

local function read_coord(b)
    if type(b) ~= "table" then
        return nil
    end
    local x, y = world.field(b, "x"), world.field(b, "y")
    if x == nil or y == nil then
        return nil
    end
    -- the raw text: world.field gives numbers, raw() reads them back exactly (5 decimals)
    local ex, ey = find(b, "x"), find(b, "y")
    return { x = raw(ex.value.text), y = raw(ey.value.text), origin = tonumber(world.field(b, "origin")) or NO_ID }
end

-- a top-level token of the gamestate (last_created_fleet ...)
local function set_meta(key, value)
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == key and e.value.text ~= nil then
            world.set_entry(world.tree, e, value)
            world.meta[key] = tonumber(value) or value
            return
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- ids: TPdxRefDatabase<T>::CreateNewObject, index | generation << 24. The free slots are the
-- save's `id = none` entries, in ascending index order at load; a slot freed since is pushed in
-- front (the economy orders' rule, docs/ai_economy.md section 6); without a free slot, one past
-- the highest index.

local alloc = {}
local function allocator(store)
    local a = alloc[store]
    if a then
        return a
    end
    a = { free = {}, gen = {}, live = {}, max = -1 }
    for _, e in ipairs(world.store_blocks[store] or {}) do
        if e.op and e.key then
            local id = tonumber(e.key.text)
            if id then
                local index = id % GEN
                a.gen[index] = math.floor(id / GEN)
                if index > a.max then a.max = index end
                if e.value.text == "none" then
                    a.free[#a.free + 1] = index
                else
                    a.live[id] = true
                end
            end
        end
    end
    table.sort(a.free)
    alloc[store] = a
    return a
end

local function collect_freed(a, store)
    local st = world.stores[store] or {}
    local gone = {}
    for id in pairs(a.live) do
        if st[id] == nil then gone[#gone + 1] = id end
    end
    table.sort(gone)
    for _, id in ipairs(gone) do
        a.live[id] = nil
        local index = id % GEN
        a.gen[index] = math.floor(id / GEN)
        table.insert(a.free, 1, index)
    end
    for _, id in ipairs(world.all(store)) do
        if not a.live[id] then
            a.live[id] = true
            local index = id % GEN
            if a.gen[index] == nil or a.gen[index] < math.floor(id / GEN) then a.gen[index] = math.floor(id / GEN) end
            if index > a.max then a.max = index end
            -- a slot someone else took again is not free any more
            for i = #a.free, 1, -1 do
                if a.free[i] == index then table.remove(a.free, i) end
            end
        end
    end
end

-- the ship and fleet creation module (engine.fleets.create), when it is there: one allocator for
-- every store, so the ids others make and free are seen the same way
local function creator()
    local name = "engine.fleets.create"
    if package.loaded[name] then
        return package.loaded[name]
    end
    if package.searchpath(name, package.path) then
        local ok, m = pcall(require, name)
        if ok and type(m) == "table" then return m end
    end
    return nil
end

-- stations.new_id(store) -> id, the entry of a reused slot (its `id = none`)
function stations.new_id(store)
    local cr = creator()
    if cr and cr.allocate then
        return cr.allocate(store)
    end
    local a = allocator(store)
    collect_freed(a, store)
    local index = table.remove(a.free, 1)
    local old
    if index == nil then
        a.max = a.max + 1
        index = a.max
        old = -1
    else
        old = a.gen[index] or 0
    end
    local g = old + 1
    if old < 0 then g = 0 end
    a.gen[index] = g
    local id = index + g * GEN
    -- a freed slot (`<old id> = none`) the object takes
    local e = old >= 0 and world.none_slot(store, index, GEN) or nil
    a.live[id] = true
    return id, e
end

-- stations.place(store, id, entry, block): a reused slot keeps its place in the store (`old = none`
-- becomes the object), a new one goes at the end
function stations.place(store, id, e, block)
    local cr = creator()
    if cr and cr.place then
        return cr.place(store, id, e, block)
    end
    return world.place(store, id, e, block, GEN)
end

-- ---------------------------------------------------------------------------------------------
-- the galaxy

local function planet(pid)
    return world.object("planet", pid)
end

local function system_of_planet(pid)
    local p = planet(pid)
    local c = p and world.field(p, "coordinate")
    return type(c) == "table" and tonumber(world.field(c, "origin")) or nil
end

local star_cache = {}
local function is_star_class(class)
    local v = star_cache[class]
    if v == nil then
        local d = class and defs.get("common/planet_classes", class)
        v = d ~= nil and defs.field(d.block, "star") == "yes"
        star_cache[class] = v
    end
    return v
end

-- CGalacticObject::GetStarPlanetObject: the first planet of the system whose class is a star
local function star_of(sid)
    local g = world.object("system", sid)
    for _, v in ipairs(world.fields(g, "planet")) do
        local pid = tonumber(v)
        local p = pid and planet(pid)
        if p and is_star_class(world.field(p, "planet_class")) then
            return pid
        end
    end
    return nil
end
stations.star_of = star_of

local function lanes(sid)
    local out = {}
    for _, h in ipairs(world.blocks(world.field(world.object("system", sid), "hyperlane"))) do
        local to = tonumber(world.field(h, "to"))
        if to then out[#out + 1] = to end
    end
    return out
end
stations.lanes = lanes

-- the primary starbase of a system (`starbases = { <primary> <others> }`, 4294967295 for none)
local function primary_starbase(sid)
    local g = world.object("system", sid)
    local l = world.list(g and world.field(g, "starbases"))
    local sb = tonumber(l[1])
    if sb and sb ~= NO_ID and world.object("starbases", sb) then
        return sb
    end
    return nil
end
stations.primary_starbase = primary_starbase

-- the owner of a starbase: its station ship's fleet's owner
local function starbase_owner(sb)
    local s = world.object("starbases", sb)
    local ship = s and tonumber(world.field(s, "station"))
    local f = ship and tonumber(world.field(world.object("ship", ship), "fleet"))
    return f and world.fleet_owner[f]
end
stations.starbase_owner = starbase_owner

-- ---------------------------------------------------------------------------------------------
-- designs

local function design_block(did)
    return did and world.object("ship_design", did)
end

local function stages(b)
    local gs = type(b) == "table" and world.field(b, "growth_stages")
    return world.blocks(type(gs) == "table" and gs or nil)
end

local function design_size(did)
    local st = stages(design_block(did))[1]
    return st and world.field(st, "ship_size")
end
stations.design_size = design_size

local class_of_size = {}
local function size_class(size)
    local c = class_of_size[size]
    if c == nil then
        local d = size and defs.get("common/ship_sizes", size)
        c = d and defs.field(d.block, "class") or false
        class_of_size[size] = c
    end
    return c or nil
end
stations.size_class = size_class

local function base_level_size()
    local d = defs.get("common/starbase_levels", defines().BASE_LEVEL)
    return d and defs.field(d.block, "ship_size") or "starbase_outpost"
end

-- CCountry::GetLatestOrbitalShipDesignOfClass (0x70deb0) -> GetLatestShipDesignOfClass: the
-- country's ship_design_collection from its last design back, the first whose growth stage's ship
-- size is of the class (for starbases the lowest, [I] the base level's size: one design of each
-- in every country of the 2210 save)
function stations.latest_design(country, class)
    local c = world.object("country", country)
    local coll = c and world.field(c, "ship_design_collection")
    local list = world.list(type(coll) == "table" and world.field(coll, "ship_design") or nil)
    local want = CLASS_NAME[class]
    local base = class == CLASS.shipclass_starbase and base_level_size() or nil
    local fallback
    for i = #list, 1, -1 do
        local did = tonumber(list[i])
        local size = did and design_size(did)
        if size and size_class(size) == want then
            if base == nil or size == base then
                return did
            end
            fallback = fallback or did
        end
    end
    return fallback
end

-- a block's text, for comparing designs' components
local function sig(b)
    if type(b) ~= "table" then
        return tostring(b)
    end
    if b.text then
        return b.text
    end
    local parts = {}
    for _, e in ipairs(b) do
        if e.op and e.key then
            parts[#parts + 1] = e.key.text .. "=" .. sig(e.value)
        else
            parts[#parts + 1] = sig(e)
        end
    end
    return "{" .. table.concat(parts, " ") .. "}"
end

-- CStarbase::Initialize (0x7cdd90): a starbase gets its own design, a copy of the station's
-- (CGameState::CreateNewShipDesign(copy), auto_gen_design cleared: `+0x30 &= ~8`)
local function copy_design(did)
    local src = design_block(did)
    if not src then
        return did
    end
    local id, e = stations.new_id("ship_design")
    local b = copy(src)
    remove_key(b, "auto_gen_design")
    stations.place("ship_design", id, e, b)
    set_meta("last_created_design", id)
    return id
end

-- ---------------------------------------------------------------------------------------------
-- where things go

-- CDepositHolder::CalcOrbitalStationCoordinate (0xd90930): the planet's coordinate moved by
-- d = max(0, (size - PLANET_ORBIT_DISTANCE_MIN_SIZE) * PLANET_ORBIT_DISTANCE_SIZE_SCALE) + the
-- class's distance: a starbase (+d, -d) with STARBASE_ORBIT_DISTANCE, an orbital station (-d, -d)
-- with PLANET_STATION_ORBIT_DISTANCE; raw CFixedPoint
function stations.station_coordinate(pid, class)
    local p = planet(pid)
    local c = p and read_coord(world.field(p, "coordinate"))
    if not c then
        return nil
    end
    local d = defines()
    local size = math.floor(tonumber(world.field(p, "planet_size")) or 0)
    local dd = fmul((size - d.MIN_SIZE) * FP, raw(d.SIZE_SCALE))
    if dd < 0 then dd = 0 end
    if class == CLASS.shipclass_starbase then
        dd = dd + raw(d.STARBASE_DIST)
        return { x = c.x + dd, y = c.y - dd, origin = c.origin }
    end
    dd = dd + raw(d.STATION_DIST)
    return { x = c.x - dd, y = c.y - dd, origin = c.origin }
end

local function isqrt(n)
    n = I64(n)
    if n < 2 then
        return tonumber(n)
    end
    local x = n / 2
    while true do
        local y = (n / x + x) / 2
        if y >= x then
            return tonumber(x)
        end
        x = y
    end
end

local function fleet_coord(f)
    local mm = world.field(f, "movement_manager")
    return type(mm) == "table" and read_coord(world.field(mm, "coordinate")) or nil
end

-- CBuildOrbitalStationFleetOrder::GetTargetCoord (0xcdf7e0): the station's place +
-- CONSTRUCTION_SHIP_STATION_OFFSET * (fleet - place) / |fleet - place| (the fleet's x and y as
-- they are, whatever system it is in; the head ship's size factor (+0x658) 1 [I])
function stations.target_coordinate(pid, class, f)
    local st = stations.station_coordinate(pid, class)
    local fc = f and fleet_coord(f)
    if not st or not fc then
        return st
    end
    local dx, dy = fc.x - st.x, fc.y - st.y
    local off = raw(defines().OFFSET)
    local a, b = fmul(fmul(off, dx), FP), fmul(fmul(off, dy), FP)
    local dist = isqrt(I64(dx) * dx + I64(dy) * dy)
    local ox, oy
    if dist == 0 then
        ox, oy = 4294967295, 4294967295 -- the game's x / 0
    else
        ox, oy = fdiv(a, dist), fdiv(b, dist)
    end
    return { x = st.x + ox, y = st.y + oy, origin = st.origin }
end

-- ---------------------------------------------------------------------------------------------
-- costs

local function economy()
    local e = package.loaded["engine.economy"] or require("engine.economy")
    e.init()
    return e
end

local function country_mods(country)
    local e = economy()
    local ok, M = pcall(e.modifiers, "country", country)
    return ok and M or {}
end

-- the jumps from the country's nearest system to sid (CCountryBorderManager::CalcNumJumpsSystemClaim
-- [I]: a breadth-first search over the hyperlanes from the country's systems); 0 for its own
function stations.jumps_to_territory(country, sid)
    if world.system_owner[sid] == country then
        return 0
    end
    local seen, frontier, n = { [sid] = true }, { sid }, 0
    while #frontier > 0 and n < 64 do
        n = n + 1
        local next_f = {}
        for _, s in ipairs(frontier) do
            for _, t in ipairs(lanes(s)) do
                if not seen[t] then
                    if world.system_owner[t] == country then
                        return n
                    end
                    seen[t] = true
                    next_f[#next_f + 1] = t
                end
            end
        end
        frontier = next_f
    end
    return 65535
end

-- CCountry::CalcExpansionInfluenceCost (0x72d2b0): 0 for an own system; else
-- min(EXPANSION_COST_MAX, (EXPANSION_COST_BASE + max(0, (jumps - 1) * EXPANSION_COST_DISTANCE) *
-- (1 + country_starbase_influence_cost_distance_mult)) * (1 + country_starbase_influence_cost_mult))
function stations.expansion_influence(country, sid)
    if world.system_owner[sid] == country then
        return 0
    end
    local d = defines()
    local M = country_mods(country)
    local j = stations.jumps_to_territory(country, sid)
    local dist = math.max(0, (j - 1) * d.EXP_DIST) * (1 + (M.country_starbase_influence_cost_distance_mult or 0))
    local v = (d.EXP_BASE + dist) * (1 + (M.country_starbase_influence_cost_mult or 0))
    if d.EXP_MAX >= 0 and v > d.EXP_MAX then v = d.EXP_MAX end
    return v
end

-- NEconomyUtil::GetOrbitalStationConstructionCost (the latest design's growth stage as an economic
-- unit: its ship size's `resources` cost blocks, triggers with the country as from, through the
-- country's cost modifiers of the category chain), plus for a starbase on the system's star the
-- expansion's influence (CBuildOrbitalStationFleetOrder::CalcCost 0xce1eb0)
-- stations.stage_table(country, class, kind) -> { res = amount }, the economic category: the latest
-- design's growth stage as an economic unit (CShipGrowthStageEconomicUnit(country, stage, the
-- country's modifiers)), its `cost` (CalcTable<0>) or `upkeep` (CalcUpkeep)
function stations.stage_table(country, class, kind)
    local did = stations.latest_design(country, class)
    return stations.size_table(country, did and design_size(did), kind)
end

-- stations.size_table(country, ship size, kind) -> { res = amount }, the economic category: a ship
-- size's `resources` table as the country's economic unit
function stations.size_table(country, size, kind)
    local out, category = {}, nil
    local sd = size and defs.get("common/ship_sizes", size)
    if sd then
        local e = economy()
        local units = require("engine.economy.units")
        local block = defs.field(units.expanded(sd), "resources")
        local t = block and e.template(block, sd.file)
        if t then
            category = t.category
            local eval = require("simscript.eval")
            local ctx = eval.new_ctx(eval.S("country", country), eval.S("country", country), nil, sd.file)
            local base = {}
            for _, blk in ipairs(t[kind] or {}) do
                local ok, holds = true, true
                if blk.trigger then
                    ok, holds = pcall(eval.trigger, blk.trigger, ctx)
                end
                if ok and holds then
                    local m = blk.mult and e.value_of(blk.mult, ctx) or 1
                    for _, rv in ipairs(blk.values) do
                        local okv, v = pcall(e.value_of, rv[2], ctx)
                        if okv and v then
                            base[rv[1]] = (base[rv[1]] or 0) + v * m
                        end
                    end
                end
            end
            out = e.apply(t.category, kind, base, 1, country_mods(country), ctx)
        end
    end
    return out, category
end

function stations.cost(country, pid, class)
    local out = stations.stage_table(country, class, "cost")
    local sid = system_of_planet(pid)
    if class == CLASS.shipclass_starbase and sid and star_of(sid) == pid then
        out.influence = (out.influence or 0) + stations.expansion_influence(country, sid)
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the stockpile

local function stock_block(country)
    local c = world.object("country", country)
    local module = world.path(c, "modules", "standard_economy_module")
    return type(module) == "table" and world.child(module, "resources") or nil
end

local function resources_of(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.value.text then
            out[e.key.text] = tonumber(e.value.text) or 0
        end
    end
    return out
end

local function add_stock(country, res, delta)
    local stock = stock_block(country)
    if not stock then
        return
    end
    local now = raw(world.field(stock, res) or 0)
    world.set(stock, res, text(now + raw(delta)))
end

-- CEconomyCountryModule's CanAfford (vfunc +0xb0) [I]: every positive cost covered by the stockpile
local function can_afford(country, cost)
    local stock = stock_block(country)
    if not stock then
        return false
    end
    for r, v in pairs(cost) do
        if v > 0 and (tonumber(world.field(stock, r)) or 0) < v then
            return false
        end
    end
    return true
end
stations.can_afford = can_afford

-- ---------------------------------------------------------------------------------------------
-- the order

local function order_fields(o)
    local dh = world.field(o.block, "deposit_holder")
    local ty = type(dh) == "table" and tonumber(world.field(dh, "type")) or 0
    local id = type(dh) == "table" and tonumber(world.field(dh, "id")) or nil
    local class = CLASS[world.field(o.block, "class")] or CLASS.shipclass_mining_station
    return ty, id, class
end

local function sub_order(o)
    local s = world.field(o.block, "sub_order")
    if type(s) ~= "table" then
        return nil
    end
    for _, e in ipairs(s) do
        if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
            return { type = e.key.text, block = e.value, holder = s, entry = e }
        end
    end
    return nil
end

local function movement()
    local name = "engine.fleets.movement"
    if package.loaded[name] then
        return package.loaded[name]
    end
    if package.searchpath(name, package.path) then
        local ok, m = pcall(require, name)
        if ok then return m end
    end
    return nil
end

local function orbits(f, pid)
    local mm = world.field(f, "movement_manager")
    local orbit = type(mm) == "table" and world.field(mm, "orbit")
    local ob = type(orbit) == "table" and world.field(orbit, "orbitable")
    return type(ob) == "table" and tonumber(world.field(ob, "planet")) == pid
end

local function set_progress(o, r)
    world.set(o.block, "progress", text(r))
end
local function progress(o)
    local e = find(o.block, "progress")
    return e and raw(e.value.text) or 0
end

local O = {}
stations.order = O

-- StartOrder (0xcdf390)
function O.start(o, fid, f, orders)
    S.started = S.started + 1
    local country = world.fleet_owner[fid]
    local ty, pid, class = order_fields(o)
    local held = world.field(o.block, "resources")
    if country then
        for r, v in pairs(resources_of(held)) do
            if v ~= 0 then
                add_stock(country, r, v)
                S.refunded = S.refunded + 1
            end
        end
    end
    local res = type(held) == "table" and held or nil
    if res then
        for i = #res, 1, -1 do world.remove_entry(res, res[i]) end
    end
    local cost = (country and pid) and stations.cost(country, pid, class) or {}
    if country and can_afford(country, cost) then
        if not res then
            res = {}
            put(o.block, "resources", res, { "ship_design", "class" })
        end
        for _, r in ipairs(economy().resources or {}) do
            local v = cost[r]
            if v and v ~= 0 then
                world.append(res, r, text(raw(v)))
                add_stock(country, r, -v)
            end
        end
        set_progress(o, 0)
        S.paid = S.paid + 1
        return
    end
    -- CancelCurrentOrder(fleet, 1)
    S.cancelled = S.cancelled + 1
    if orders and orders.cancel_current then
        orders.cancel_current(fid, f)
    end
end

-- TickOrder (0xcdfac0)
function O.tick(o, fid, f, orders)
    local _, pid, class = order_fields(o)
    local sub = sub_order(o)
    if not orbits(f, pid) then
        local here = fleet_coord(f)
        local t = pid and stations.target_coordinate(pid, class, f)
        local there = here and t and here.origin == t.origin and math.abs(here.x - t.x) <= 2 and math.abs(here.y - t.y) <= 2
        if not there then
            if sub == nil then
                -- a CMoveToSystemPointFleetOrder to the build position (OnMoveOrderChanged)
                if not t then
                    return
                end
                local b = {}
                world.append(b, "coordinate", coord_block(t))
                world.append(b, "can_reach", "yes")
                world.append(b, "commissioner", NO_ID)
                -- before can_reach (the base class's fields come after the order's own)
                local _, ci = find(o.block, "can_reach")
                world.insert(o.block, ci or (#o.block + 1), "sub_order", { entry("move_to_system_point_order", b) })
                local m = movement()
                if m and m.move_to then
                    m.move_to(fid, { x = text(t.x), y = text(t.y), origin = t.origin })
                end
                S.moves = S.moves + 1
                return
            end
            local T = orders and orders.TYPES and orders.TYPES[sub.type]
            if T and T.tick then T.tick(sub, fid, f, orders) end
            if not (T and T.is_done and T.is_done(sub, fid, f)) then
                -- the game's movement asks the executing order for its target every tick
                -- (GetFleetTargetCoordinate), so a fleet the movement left within 1.0 of the
                -- sub-order's coordinate (IsNear) goes on to it; the movement port follows the
                -- target move_to gave it, so it is given again [I: a day later than the game]
                local m = movement()
                local sc = read_coord(world.field(sub.block, "coordinate"))
                if m and m.move_to and m.is_moving and sc and not m.is_moving(fid) then
                    m.move_to(fid, { x = text(sc.x), y = text(sc.y), origin = sc.origin })
                    S.moves = S.moves + 1
                end
                return
            end
            -- arrived: the sub-order done (the game deletes it and builds from the next day;
            -- [I] the saves' orders reach the position on the tick before: the same day here)
        end
    end
    if sub then
        remove_key(o.block, "sub_order")
    end
    local d = defines()
    set_progress(o, progress(o) + raw(d.WORK_SPEED))
    S.ticked = S.ticked + 1
end

function O.is_done(o)
    return progress(o) >= 100 * FP
end

-- ShouldCancel (0xce1e80): !IsPossibleExceptPathfinding [I, its main checks]: the planet gone, a
-- station of the class on it already, a starbase in the system, the system another country's;
-- cancelled, the order's resources go back (OrderUnQueued 0xcdedc0)
function O.should_cancel(o, fid, f)
    local country = world.fleet_owner[fid]
    local _, pid, class = order_fields(o)
    local ok = country ~= nil and pid ~= nil and planet(pid) ~= nil and stations.can_create(country, pid, class)
    if ok then
        local owner = world.system_owner[system_of_planet(pid)]
        ok = owner == nil or owner == country
    end
    if ok then
        return false
    end
    if country then
        for r, v in pairs(resources_of(world.field(o.block, "resources"))) do
            if v ~= 0 then
                add_stock(country, r, v)
                S.refunded = S.refunded + 1
            end
        end
    end
    S.cancelled = S.cancelled + 1
    return true
end

-- Finish (0xce0290)
function O.finish(o, fid, f, orders, host)
    local country = world.fleet_owner[fid]
    local ty, pid, class = order_fields(o)
    if not country or ty ~= 0 or not pid then
        S.failed = S.failed + 1
        stations.failures[#stations.failures + 1] = string.format("%s fleet %d: no country or not a planet", today(), fid)
        return
    end
    local ok, why = stations.create(country, pid, class, fid)
    if not ok then
        S.failed = S.failed + 1
        stations.failures[#stations.failures + 1] = string.format("%s fleet %d planet %d: %s", today(), fid, pid, tostring(why))
    end
end

-- stations.build_order(planet, class[, country]) -> the order in the save's form, as
-- CFleetBuildOrbitalStationCommand makes it and OrderQueued fills it (ship_design: CalcShipDesign)
function stations.build_order(pid, class, country)
    local b = {}
    local dh = {}
    world.append(dh, "type", 0)
    world.append(dh, "id", pid)
    world.append(b, "deposit_holder", dh)
    world.append(b, "progress", 0)
    world.append(b, "cost", 0)
    world.append(b, "in_progress", "no")
    world.append(b, "class", CLASS_NAME[class])
    local sd = {}
    world.append(sd, "design", (country and stations.latest_design(country, class)) or NO_ID)
    world.append(sd, "upgrade", NO_ID)
    world.append(sd, "growth_stage", 0)
    world.append(b, "ship_design", sd)
    world.append(b, "resources", {})
    return { entry("build_orbital_station_order", b) }
end

-- ---------------------------------------------------------------------------------------------
-- the objects: reference ships for what the design gives (hit points, sections, weapons)

local ref_index, ref_key
local function refs()
    local key = tostring(world.tree) .. "/" .. #world.all("ship")
    if ref_index and ref_key == key then
        return ref_index
    end
    ref_index = { by_design = {}, by_sig = {}, by_size = {} }
    ref_key = key
    for _, sid in ipairs(world.all("ship")) do
        local s = world.object("ship", sid)
        local sdi = s and world.field(s, "ship_design_implementation")
        local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
        if did then
            local fl = tonumber(world.field(s, "fleet"))
            local owner = fl and world.fleet_owner[fl]
            if ref_index.by_design[did] == nil then ref_index.by_design[did] = sid end
            local b = design_block(did)
            if b then
                local g = sig(world.field(b, "growth_stages"))
                local k = tostring(owner) .. "|" .. g
                if ref_index.by_sig[k] == nil then ref_index.by_sig[k] = sid end
                if ref_index.by_sig[g] == nil then ref_index.by_sig[g] = sid end
                local size = design_size(did)
                if size then
                    local ks = tostring(owner) .. "|" .. size
                    if ref_index.by_size[ks] == nil then ref_index.by_size[ks] = sid end
                    if ref_index.by_size[size] == nil then ref_index.by_size[size] = sid end
                end
            end
        end
    end
    return ref_index
end

local function ref_ship(country, did)
    local r = refs()
    local b = design_block(did)
    local g = b and sig(world.field(b, "growth_stages"))
    local size = design_size(did)
    return (g and r.by_sig[tostring(country) .. "|" .. g]) or r.by_design[did] or (g and r.by_sig[g])
        or (size and r.by_size[tostring(country) .. "|" .. size]) or (size and r.by_size[size])
end

-- a name block: `key` with the variable PLANET = the planet's name
local function planet_name_var(key, pid)
    local n = {}
    world.append(n, "key", key)
    local var = {}
    world.append(var, "key", "PLANET")
    world.append(var, "value", copy(world.field(planet(pid), "name")) or {})
    local vars = { var }
    world.append(n, "variables", vars)
    return n
end

local ROT_NAMES = { "post_move_angle", "rotation" }

-- the ship's place and facing (TeleportFleetToCoordinate -> CShip::SnapToFormation): rotation the
-- angle, forward (-sin, cos) normalized, the game's fixed-point sin and cos
local function facing(angle)
    local m = movement()
    local sn, cs = m.fsin(angle), m.fcos(angle)
    local fx, fy = 0, 0
    if sn ~= 0 or cs ~= 0 then
        local l = isqrt(I64(cs) * cs + I64(sn) * sn)
        fx, fy = fdiv(-sn, l), fdiv(cs, l)
    end
    return fx, fy
end

-- the new ship block, the reference's with this ship's own fields
local function ship_block(country, pid, class, did, fleet_id, at, angle, name)
    local rid = ref_ship(country, did)
    local ref = rid and world.object("ship", rid)
    local b = {}
    world.append(b, "fleet", fleet_id)
    world.append(b, "name", name)
    world.append(b, "reserve", 0)
    local sdi = {}
    world.append(sdi, "design", did)
    world.append(sdi, "upgrade", NO_ID)
    world.append(sdi, "growth_stage", 0)
    world.append(b, "ship_design_implementation", sdi)
    local c = world.object("country", country)
    local gc = ref and world.field(ref, "graphical_culture") or (c and world.field(c, "graphical_culture"))
    if gc then world.append(b, "graphical_culture", tok(gc, true)) end
    local section = ref and world.field(ref, "section")
    if type(section) == "table" then
        world.append(b, "section", copy(section))
    end
    world.append(b, "coordinate", coord_block(at))
    world.append(b, "target_coordinate", coord_block(at))
    world.append(b, "post_move_angle", text(angle))
    -- the hit points: the design's maxima (the reference's), full
    for _, k in ipairs({ "hitpoints", "shield_hitpoints", "armor_hitpoints", "max_hitpoints",
                         "max_shield_hitpoints", "max_armor_hitpoints" }) do
        local mk = k:sub(1, 4) == "max_" and k or ("max_" .. k)
        local v = ref and (find(ref, mk) or find(ref, k))
        if v then world.append(b, k, tok(v.value.text)) end
    end
    local fx, fy = facing(angle)
    world.append(b, "rotation", text(angle))
    world.append(b, "forward_x", text(fx))
    world.append(b, "forward_y", text(fy))
    world.append(b, "upgrade_progress", 0)
    local nwi = ref and find(ref, "next_weapon_index")
    if nwi then world.append(b, "next_weapon_index", tok(nwi.value.text)) end
    world.append(b, "created_this_update", "no")
    world.append(b, "targeting_module", {})
    world.append(b, "combat_action", 1)
    for _, k in ipairs({ "disable_at_health", "enable_at_health" }) do
        local v = ref and find(ref, k)
        if v then world.append(b, k, tok(v.value.text)) end
    end
    world.append(b, "construction_date", today())
    world.append(b, "maturation_date", "0.01.01")
    return b, rid
end

local function null_coord()
    return coord_block({ x = 0, y = 0, origin = NO_ID })
end

-- the new fleet block (CGameState::CreateNewFleet, CFleet::AddShip, then the station's place),
-- the reference fleet's combat, stats and properties (its settled form: the next day's)
local function fleet_block(pid, class, ship_id, ref_fleet, at, angle, sid, name)
    local b = {}
    world.append(b, "name", name)
    local ships = {}
    world.append_value(ships, ship_id)
    world.append(b, "ships", ships)
    local combat = ref_fleet and world.field(ref_fleet, "combat")
    combat = type(combat) == "table" and copy(combat) or nil
    if combat then
        local cc = world.field(combat, "coordinate")
        if type(cc) == "table" then world.set(cc, "origin", sid) end
        world.append(b, "combat", combat)
    end
    for _, k in ipairs({ "fleet_stats", "ground_support_stance" }) do
        local v = ref_fleet and find(ref_fleet, k)
        if v then world.append(b, k, copy(v.value)) end
    end
    world.append(b, "ship_class", CLASS_NAME[class])
    local v = ref_fleet and find(ref_fleet, "space_fauna_growth_stance")
    world.append(b, "space_fauna_growth_stance", v and copy(v.value) or tok("excessive"))
    world.append(b, "mia_from", null_coord())
    local mm = {}
    local formation = {}
    local rmm = ref_fleet and world.field(ref_fleet, "movement_manager")
    local rf = type(rmm) == "table" and world.field(rmm, "formation")
    world.append(formation, "scale", 1)
    world.append(formation, "angle", text(angle))
    world.append(formation, "type", type(rf) == "table" and world.field(rf, "type") or (class == CLASS.shipclass_starbase and "circle" or "wedge"))
    world.append(mm, "formation", formation)
    world.append(mm, "coordinate", coord_block(at))
    local target = {}
    world.append(target, "coordinate", null_coord())
    world.append(mm, "target", target)
    world.append(mm, "target_coordinate", null_coord())
    world.append(mm, "state", "move_idle")
    local p = {}
    world.append(p, "date", "0.01.01")
    world.append(mm, "path", p)
    local orbit, ob = {}, {}
    world.append(ob, "planet", pid)
    world.append(orbit, "orbitable", ob)
    world.append(orbit, "index", -1)
    world.append(mm, "orbit", orbit)
    local lj = {}
    world.append(lj, "from", null_coord())
    world.append(lj, "fleet", NO_ID)
    world.append(lj, "jump_method", "jump_count")
    world.append(lj, "bypass_from", NO_ID)
    world.append(lj, "bypass_to", NO_ID)
    world.append(mm, "last_ftl_jump", lj)
    world.append(b, "movement_manager", mm)
    local props = ref_fleet and world.field(ref_fleet, "properties")
    if type(props) == "table" then
        props = copy(props)
        remove_key(props, "dirty_cloaking_strength")
    else
        props = {}
        world.append(props, "station", "yes")
        world.append(props, "valid_for_combat", "yes")
        world.append(props, "orbital_station", "yes")
    end
    world.append(b, "properties", props)
    for _, k in ipairs({ "hit_points", "military_power", "diplomacy_weight" }) do
        local x = ref_fleet and find(ref_fleet, k)
        world.append(b, k, x and tok(x.value.text) or tok("0.00000"))
    end
    for _, k in ipairs({ "cached_killed_ships", "cached_disabled_ships", "cached_disengaged_ships", "cached_combined_removed_ships" }) do
        world.append(b, k, 0)
    end
    world.append(b, "commanding_armada", "none")
    return b
end

-- the country's owned fleets (fleets_manager.owned_fleets = { { fleet = id } ... }), the new one
-- in id order [I]
local function add_owned_fleet(country, fid)
    local c = world.object("country", country)
    local fm = c and world.child(c, "fleets_manager")
    if not fm then
        return
    end
    local owned = world.field(fm, "owned_fleets")
    if type(owned) ~= "table" then
        owned = {}
        world.insert(fm, 1, "owned_fleets", owned)
    end
    local e = {}
    world.append(e, "fleet", fid)
    local pos = #owned + 1
    for i, x in ipairs(owned) do
        if not x.op and not x.text then
            local id = tonumber(world.field(x, "fleet"))
            if id and id > fid then
                pos = i
                break
            end
        end
    end
    world.insert_value(owned, pos, e)
    world.fleet_owner[fid] = country
    live.touch("country", country)
end

-- CPlanet::SetController (0xdf8690): the old controller's controlled_planets without it, the new
-- one's with it (appended); the events of occupation only for an owned planet (not a station's)
local function set_controller(pid, country)
    local p = planet(pid)
    local old = tonumber(world.field(p, "controller"))
    if old == country then
        return
    end
    live.touch("planet", pid)
    live.touch("country", old)
    live.touch("country", country)
    if old then
        local oc = world.object("country", old)
        local l = oc and world.field(oc, "controlled_planets")
        if type(l) == "table" then world.remove_value(l, pid) end
    end
    if find(p, "controller") then
        put(p, "controller", country)
    else
        -- before planet_orbitals when the save has it, else after last_bombardment
        local _, oi = find(p, "planet_orbitals")
        if oi then
            world.insert(p, oi, "controller", country)
        else
            put(p, "controller", country, { "last_bombardment", "orbit", "coordinate" })
        end
    end
    local c = world.object("country", country)
    local l = c and world.field(c, "controlled_planets")
    if c and type(l) ~= "table" then
        l = {}
        put(c, "controlled_planets", l, { "owned_planets", "controlled_colonies" })
    end
    if l then world.append_value(l, pid) end
end

local function set_planet_station(pid, class, fid)
    local p = planet(pid)
    if class == CLASS.shipclass_starbase then
        put(p, "orbital_defence", fid, { "shipclass_orbital_station", "planet_orbitals", "controller", "last_bombardment" })
    else
        put(p, "shipclass_orbital_station", fid, { "planet_orbitals", "controller", "last_bombardment" })
    end
end

-- ---------------------------------------------------------------------------------------------
-- the starbase

-- CConstructionManager::CreateQueue (type 2, starbase), owner the ship's
local function create_queue(country, ship_id)
    local store = "construction.queue_mgr.queues"
    if not world.store_blocks[store] then
        return NO_ID
    end
    local id, e = stations.new_id(store)
    local q = {}
    world.append(q, "owner", country)
    local loc = {}
    world.append(loc, "type", 0)
    world.append(loc, "id", ship_id)
    world.append(q, "location", loc)
    world.append(q, "simultaneous", 1)
    world.append(q, "type", "starbase")
    stations.place(store, id, e, q)
    return id
end

-- CGalacticObject::CreateStarbase (0x865ad0) -> CGameState::CreateNewStarbase ->
-- CStarbaseManager::CreateStarbase (0x966b20) -> CStarbase::Initialize (0x7cdd90)
local function create_starbase(country, sid, pid, ship_id, design)
    local id, e = stations.new_id("starbases")
    local queue = create_queue(country, ship_id)
    local b = {}
    world.append(b, "level", tok(defines().BASE_LEVEL, true))
    world.append(b, "build_queue", queue)
    world.append(b, "shipyard_build_queue", NO_ID)
    local sdi = {}
    world.append(sdi, "design", design)
    world.append(sdi, "upgrade", NO_ID)
    world.append(sdi, "growth_stage", 0)
    world.append(b, "ship_design_implementation", sdi)
    world.append(b, "station", ship_id)
    world.append(b, "orbitals", {})
    stations.place("starbases", id, e, b)
    -- the system's starbases: the primary first (on the star), the others after
    live.touch("system", sid)
    local g = world.object("system", sid)
    local list = world.field(g, "starbases")
    if type(list) ~= "table" then
        list = {}
        put(g, "starbases", list, { "fleet_presence", "outer_radius", "inner_radius" })
    end
    if star_of(sid) == pid then
        local first
        for _, v in ipairs(list) do
            if v.text then first = v break end
        end
        if first then
            world.set_entry(list, first, id)
        else
            world.append_value(list, id)
        end
    else
        if #world.list(list) == 0 then world.append_value(list, NO_ID) end
        world.append_value(list, id)
    end
    return id
end

-- ---------------------------------------------------------------------------------------------
-- ownership and borders

-- the country's relation with another (relations_manager.relation = { owner country ... })
local function relations_of(c)
    local rm = world.field(c, "relations_manager")
    local out = {}
    for _, r in ipairs(type(rm) == "table" and world.fields(rm, "relation") or {}) do
        if type(r) == "table" then
            out[#out + 1] = r
        end
    end
    return out
end

-- CCountryBorderManager::CalcIsBorderingCountry [I]: a hyperlane from one of our systems to one of
-- theirs
local function owned_systems(country)
    local out = {}
    for _, sid in ipairs(world.all("system")) do
        if world.system_owner[sid] == country then out[#out + 1] = sid end
    end
    return out
end

local function borders_country(a, b, systems_of)
    for _, sid in ipairs(systems_of[a] or {}) do
        for _, t in ipairs(lanes(sid)) do
            if world.system_owner[t] == b then
                return true
            end
        end
    end
    return false
end

-- NBordersUtil::CalcBorders (0x960490) for the countries whose systems changed, then their
-- diplomacy modules' UpdateBorderCache: `borders` = the systems within the borders (the owned
-- systems), each relation's `borders = yes` (bordering either way)
function stations.update_borders(countries)
    local systems_of = {}
    for _, sid in ipairs(world.all("system")) do
        local o = world.system_owner[sid]
        if o then
            local l = systems_of[o]
            if not l then
                l = {}
                systems_of[o] = l
            end
            l[#l + 1] = sid
        end
    end
    for _, country in ipairs(countries) do
        local c = world.object("country", country)
        local dm = c and world.path(c, "modules", "standard_diplomacy_module")
        if type(dm) == "table" and find(dm, "borders") then
            world.set(dm, "borders", #(systems_of[country] or {}))
        end
        for _, r in ipairs(c and relations_of(c) or {}) do
            local other = tonumber(world.field(r, "country"))
            if other and other ~= country then
                local b = borders_country(country, other, systems_of) or borders_country(other, country, systems_of)
                local has = world.field(r, "borders") == "yes"
                if b and not has then
                    put(r, "borders", "yes", { "contact", "communications", "truce", "num_hostile_acts" })
                    S.borders = S.borders + 1
                    live.touch("country", country)
                elseif not b and has then
                    remove_key(r, "borders")
                    S.borders = S.borders + 1
                    live.touch("country", country)
                end
                -- the other side's relation
                local oc = world.object("country", other)
                for _, r2 in ipairs(oc and relations_of(oc) or {}) do
                    if tonumber(world.field(r2, "country")) == country then
                        local has2 = world.field(r2, "borders") == "yes"
                        if b and not has2 then
                            put(r2, "borders", "yes", { "contact", "communications", "truce", "num_hostile_acts" })
                            live.touch("country", other)
                        elseif not b and has2 then
                            remove_key(r2, "borders")
                            live.touch("country", other)
                        end
                    end
                end
            end
        end
    end
end

-- NSectorManager::Update (0x946d00) for the new system: AddSystemToBestSector (0x947760): of the
-- country's sectors (the last first), those within the sector type's max_jumps (+
-- sector_max_jumps_add) of the sector's capital through systems of the same sector or of none,
-- the one whose type's system_scores is highest (core 100, normal 1)
local function sector_score(stype)
    local d = defs.get("common/sector_types", stype)
    local sc = d and defs.field(d.block, "system_scores")
    return tonumber(type(sc) == "table" and defs.field(sc, "base") or nil) or 0
end
local function sector_max_jumps(stype, country)
    local d = defs.get("common/sector_types", stype)
    local mj = tonumber(d and defs.field(d.block, "max_jumps")) or 0
    return mj + math.floor(country_mods(country).sector_max_jumps_add or 0)
end
local function sector_of_system(sid)
    local g = world.object("system", sid)
    local s = tonumber(world.field(g, "sector"))
    return s ~= NO_ID and s or nil
end

local function assign_sector(country, sid)
    if sector_of_system(sid) then
        return
    end
    local c = world.object("country", country)
    local owned = world.list(world.path(c, "sectors", "owned"))
    local best, best_score
    for i = #owned, 1, -1 do
        local sec = tonumber(owned[i])
        local s = sec and world.object("sectors", sec)
        if s and world.field(s, "auto_expand") ~= "no" then
            local stype = world.field(s, "type")
            local cap = tonumber(world.field(s, "local_capital"))
            local cap_pid = cap and (world.colony_planet[cap] or cap)
            local from = cap_pid and system_of_planet(cap_pid)
            local maxj = sector_max_jumps(stype, country)
            -- jumps through systems of this sector or of none
            local ok = false
            if from then
                local seen, frontier = { [from] = true }, { from }
                for _ = 1, maxj do
                    local nf = {}
                    for _, x in ipairs(frontier) do
                        for _, t in ipairs(lanes(x)) do
                            if not seen[t] then
                                seen[t] = true
                                if t == sid then ok = true end
                                local ts = sector_of_system(t)
                                if ts == nil or ts == sec then nf[#nf + 1] = t end
                            end
                        end
                    end
                    frontier = nf
                    if ok then break end
                end
                if from == sid then ok = true end
            end
            if ok then
                local score = sector_score(stype)
                if best_score == nil or score > best_score then
                    best, best_score = sec, score
                end
            end
        end
    end
    if best then
        local s = world.object("sectors", best)
        world.append_value(world.child(s, "systems"), sid)
        world.set(world.object("system", sid), "sector", best)
        S.sectors = S.sectors + 1
    end
end

local function on_action(name, this, from)
    local ok, events = pcall(require, "simscript.events")
    local eval = require("simscript.eval")
    if ok and events and events.on_action then
        S.on_actions = S.on_actions + 1
        pcall(events.on_action, name, this, eval.new_ctx(from))
    end
end

-- the system's new owner: world.system_owner, the borders, the sector, on_system_gained
-- (CGalacticObject::OnOwnershipUpdated 0x86d5d0: its three scopes from a CCrudeRandom, no draws)
local function owner_changed(sid, old, new)
    world.system_owner[sid] = new
    local list = { new }
    if old then list[2] = old end
    stations.update_borders(list)
    assign_sector(new, sid)
    local eval = require("simscript.eval")
    if old then on_action("on_system_lost", eval.S("country", old), eval.S("system", sid)) end
    on_action("on_system_gained", eval.S("country", new), eval.S("system", sid))
end

-- CFleetSetExpansionFlag::Execute (0xa6a020): the AI's DirtyExpandStrategy (2048), posted by
-- Finish for an AI country and executed with the next commands [I: set here at once]; the save
-- writes it last in the ai block (the game's 2210.03.10 output)
local function set_expansion_flag(country)
    local c = world.object("country", country)
    local ai = c and world.field(c, "ai")
    if type(ai) ~= "table" or world.field(ai, "dirty_expand_strategy") == "yes" then
        return
    end
    world.append(ai, "dirty_expand_strategy", "yes")
end

local function human(country)
    local ok, ai = pcall(require, "engine.ai")
    return ok and ai and ai.human and ai.human(country)
end

-- ---------------------------------------------------------------------------------------------
-- CDepositHolder::CreateOrbitalStation

-- CDepositHolder::CanCreateOrbitalStation (0xd93050) [I, the parts the saves need]: a design of the
-- class; a planet; no station of the class on it already; a starbase: none in the system (primary)
function stations.can_create(country, pid, class)
    local p = planet(pid)
    if not p then
        return false, "no planet"
    end
    if not stations.latest_design(country, class) then
        return false, "no design of the class"
    end
    if class == CLASS.shipclass_starbase then
        local f = tonumber(world.field(p, "orbital_defence"))
        if f and world.object("fleet", f) then
            return false, "the planet has an orbital defence"
        end
        local sid = system_of_planet(pid)
        if sid and star_of(sid) == pid and primary_starbase(sid) then
            return false, "the system has a starbase"
        end
    else
        local f = tonumber(world.field(p, "shipclass_orbital_station"))
        if f and world.object("fleet", f) then
            return false, "the planet has a station"
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- where a station can go (for the AI and its strategy lists)

local function has_tech(country, tech)
    local c = world.object("country", country)
    local ts = c and world.field(c, "tech_status")
    for _, t in ipairs(type(ts) == "table" and world.fields(ts, "technology") or {}) do
        if t == tech then
            return true
        end
    end
    return false
end
stations.has_tech = has_tech

local colonizable_cache = {}
local function colonizable_class(class)
    local v = colonizable_cache[class]
    if v == nil then
        local d = class and defs.get("common/planet_classes", class)
        v = d ~= nil and defs.field(d.block, "colonizable") == "yes"
        colonizable_cache[class] = v
    end
    return v
end
-- CDepositHolder's IsColonizable (vfunc +0xa8) [I]: no owner, a colonizable planet class
function stations.colonizable(pid)
    local p = planet(pid)
    return p ~= nil and world.field(p, "owner") == nil and colonizable_class(world.field(p, "planet_class"))
end

local function deposit_def(did)
    local dep = world.object("deposit", did)
    local ty = dep and world.field(dep, "type")
    return ty and defs.get("common/deposits", ty)
end

-- CDepositHolder::GetOrbitalDepositClass (0xd92540): none (14) for a colonizable
-- planet or one without deposits; else the first deposit's `station`
function stations.orbital_class(pid)
    local p = planet(pid)
    if not p or stations.colonizable(pid) then
        return nil
    end
    local first = tonumber(world.list(world.field(p, "deposits"))[1])
    local d = first and deposit_def(first)
    local st = d and defs.field(d.block, "station")
    return st and CLASS[st] or nil
end

-- a strategic resource the country can see (its `prerequisites` researched: every technology
-- listed, one of each `OR = { ... }`)
local prereq_cache = {}
local function resource_known(country, res)
    local pre = prereq_cache[res]
    if pre == nil then
        pre = {}
        local d = defs.get("common/strategic_resources", res)
        local b = d and defs.field(d.block, "prerequisites")
        for _, e in ipairs(type(b) == "table" and b or {}) do
            if e.text then
                pre[#pre + 1] = { e.text }
            elseif e.op and e.key and e.key.text == "OR" and type(e.value) == "table" then
                pre[#pre + 1] = world.list(e.value)
            end
        end
        prereq_cache[res] = pre
    end
    for _, any in ipairs(pre) do
        local ok = false
        for _, t in ipairs(any) do
            if has_tech(country, t) then
                ok = true
                break
            end
        end
        if not ok then
            return false
        end
    end
    return true
end

-- CDepositHolder::CalcKnownOrbitalResources (0xd91210) [I]: nothing for a colonizable planet;
-- else what its orbital deposits (those with a `station`) produce, the strategic resources too
-- (the 2210.01.01 lists 19 count them whether their technology is researched or not)
function stations.known_orbital_resources(pid, country)
    local out = {}
    local p = planet(pid)
    if not p or stations.colonizable(pid) then
        return out
    end
    for _, v in ipairs(world.list(world.field(p, "deposits"))) do
        local d = deposit_def(tonumber(v))
        if d and defs.field(d.block, "station") then
            local res = defs.field(d.block, "resources")
            local prod = type(res) == "table" and defs.field(res, "produces")
            for _, e in ipairs(type(prod) == "table" and prod or {}) do
                if e.op and e.key and e.value.text and tonumber(e.value.text) then
                    out[e.key.text] = (out[e.key.text] or 0) + tonumber(e.value.text)
                end
            end
        end
    end
    return out
end

-- the country's intel level of a system (intel_level, one byte a system by id)
local intel_cache = setmetatable({}, { __mode = "k" })
local function intel_level(country, sid)
    local c = world.object("country", country)
    local list = c and world.field(c, "intel_level")
    if type(list) ~= "table" then
        return 0
    end
    local arr = intel_cache[list]
    if arr == nil or arr.n ~= #list then
        arr = { n = #list }
        for i, v in ipairs(world.list(list)) do arr[i - 1] = tonumber(v) or 0 end
        intel_cache[list] = arr
    end
    return arr[sid] or 0
end

local function surveyed(country, pid)
    local c = world.object("country", country)
    for _, e in ipairs(world.blocks(c and world.field(c, "surveyed_deposit_holders"))) do
        if tonumber(world.field(e, "type")) == 0 and tonumber(world.field(e, "id")) == pid then
            return true
        end
    end
    -- auto-surveyed: a type without needs_survey, or an own system (HasAutoSurveyedSystem)
    local d = c and defs.get("common/country_types", world.field(c, "type"))
    if not (d and defs.field(d.block, "needs_survey") == "yes") then
        return true
    end
    return world.system_owner[system_of_planet(pid)] == country
end

-- CDepositHolder::CanBuildStation (0xd949f0) -> CPlanet::CanBuildStation (0xe00c90) [I, the parts
-- the 2210 saves need]: a design of the class; the system known (intel level above 0); for an
-- orbital station the planet surveyed, no station on it yet, the resource of its deposit visible
-- (HasResourceForGetPrerequisites), not in another country's system, no megastructure; for a
-- starbase no primary starbase of another country in the system (CAN_BUILD_STATION_BORDERS) and
-- none on the planet. Observation posts (the pre-FTL rules): not modelled, never.
function stations.can_build_station(country, pid, class)
    local p = planet(pid)
    if not p or not stations.latest_design(country, class) then
        return false
    end
    local sid = system_of_planet(pid)
    if not sid or intel_level(country, sid) <= 0 then
        return false
    end
    if class == CLASS.shipclass_observation_station then
        return false
    end
    if class == CLASS.shipclass_starbase then
        local f = tonumber(world.field(p, "orbital_defence"))
        if f and world.object("fleet", f) then
            return false
        end
        local sb = primary_starbase(sid)
        if sb then
            return false
        end
        local owner = world.system_owner[sid]
        return owner == nil or owner == country
    end
    if not surveyed(country, pid) then
        return false
    end
    local f = tonumber(world.field(p, "shipclass_orbital_station"))
    if f and world.object("fleet", f) then
        return false
    end
    local owner = world.system_owner[sid]
    if owner ~= nil and owner ~= country then
        return false
    end
    if stations.orbital_class(pid) ~= class then
        return false
    end
    -- the deposit's resources visible
    local first = tonumber(world.list(world.field(p, "deposits"))[1])
    local d = first and deposit_def(first)
    local res = d and defs.field(d.block, "resources")
    local prod = type(res) == "table" and defs.field(res, "produces")
    for _, e in ipairs(type(prod) == "table" and prod or {}) do
        if e.op and e.key and not resource_known(country, e.key.text) then
            return false
        end
    end
    local flags = world.field(p, "flags")
    if type(flags) == "table" and world.field(flags, "has_megastructure") ~= nil then
        return false
    end
    return true
end

-- stations.create(country, planet, class[, builder]) -> fleet | nil, why
function stations.create(country, pid, class, builder)
    local ok, why = stations.can_create(country, pid, class)
    if not ok then
        return nil, why
    end
    local sid = system_of_planet(pid)
    local design = stations.latest_design(country, class)
    -- CreateOrbitalStation(fleet, design): two draws (the scopes), on_building_<ship size> (this =
    -- the builder's ship, from = the planet)
    if builder then
        RUST.rand()
        RUST.rand()
        S.draws = S.draws + 2
        local f = world.object("fleet", builder)
        local head = f and tonumber(world.list(world.field(f, "ships"))[1])
        local eval = require("simscript.eval")
        on_action("on_building_" .. tostring(design_size(design)), head and eval.S("ship", head) or eval.NONE, eval.S("planet", pid))
    end
    -- CGameState::CreateNewOrbitalStation (0x268b10): the ship; CreateNewFleet (0x2698e0): the
    -- fleet (last_created_fleet); CFleet::AddShip
    local ship_id, ship_e = stations.new_id("ships")
    local fleet_id, fleet_e = stations.new_id("fleet")
    local at = stations.station_coordinate(pid, class)
    local p = planet(pid)
    local pc = read_coord(world.field(p, "coordinate"))
    local m = movement()
    local angle = (m and m.atan2 and pc) and (m.atan2(pc.y - at.y, pc.x - at.x) - 157100) or 0
    local cname = CLASS_NAME[class] .. "_name"
    local ship_design = design
    if class == CLASS.shipclass_starbase then
        ship_design = copy_design(design)
    end
    local sname = class == CLASS.shipclass_starbase and planet_name_var("STARBASE_STATION_NAME_FORMAT_NON_PRIMARY", pid)
        or planet_name_var(cname, pid)
    local sblock, rid = ship_block(country, pid, class, ship_design, fleet_id, at, angle, sname)
    local ref = rid and world.object("ship", rid)
    local ref_fleet = ref and world.object("fleet", tonumber(world.field(ref, "fleet")))
    stations.place("ships", ship_id, ship_e, sblock)
    local fblock = fleet_block(pid, class, ship_id, ref_fleet, at, angle, sid, planet_name_var(cname, pid))
    stations.place("fleet", fleet_id, fleet_e, fblock)
    set_meta("last_created_fleet", fleet_id)
    add_owned_fleet(country, fleet_id)
    -- the system's presence (TeleportFleetToCoordinate)
    if m and m.add_presence then m.add_presence(sid, fleet_id) end
    local sb
    local old_owner = sid and world.system_owner[sid]
    if class == CLASS.shipclass_starbase then
        sb = create_starbase(country, sid, pid, ship_id, ship_design)
    end
    set_planet_station(pid, class, fleet_id)
    -- the holder's vfunc +0x70 (the controller), not for an observation station
    if class ~= CLASS.shipclass_observation_station then
        set_controller(pid, country)
    end
    -- Finish: a starbase on the star: the ownership and CalcBorders; an AI country: the expansion flag
    if class == CLASS.shipclass_starbase and star_of(sid) == pid then
        if old_owner ~= country then
            owner_changed(sid, old_owner, country)
        end
        if not human(country) then
            set_expansion_flag(country)
        end
    end
    S.finished = S.finished + 1
    count(S.built, CLASS_NAME[class])
    stations.built[#stations.built + 1] = { date = today(), country = country, class = CLASS_NAME[class], planet = pid,
        system = sid, fleet = fleet_id, ship = ship_id, starbase = sb, builder = builder }
    return fleet_id
end

-- ---------------------------------------------------------------------------------------------

function stations.log()
    local lines = {}
    for _, b in ipairs(stations.built) do
        lines[#lines + 1] = string.format("%s %d %s planet %d system %d fleet %d ship %d%s", b.date, b.country, b.class,
            b.planet, b.system or -1, b.fleet, b.ship, b.starbase and (" starbase " .. b.starbase) or "")
    end
    for _, f in ipairs(stations.failures) do
        lines[#lines + 1] = "failed: " .. f
    end
    return table.concat(lines, "\n")
end

function stations.report()
    local parts = {}
    for k, v in pairs(S.built) do parts[#parts + 1] = k:gsub("^shipclass_", "") .. " " .. v end
    table.sort(parts)
    return string.format("stations: %d orders started (%d paid, %d cancelled, %d refunds), %d build-days, %d moves; built %d (%s), %d failed; %d draws, %d on_actions, %d border flags, %d sectors",
        S.started, S.paid, S.cancelled, S.refunded, S.ticked, S.moves, S.finished, table.concat(parts, ", "), S.failed,
        S.draws, S.on_actions, S.borders, S.sectors)
end

return stations
