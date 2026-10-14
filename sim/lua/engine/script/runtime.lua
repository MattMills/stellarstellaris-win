-- engine/script/runtime.lua : what the run-time keywords of the script layer read of the world
-- (simscript/handlers/runtime.lua): cosmic storms, megastructures, starbases, councilors, sectors,
-- and the country, planet, fleet and ship fields the save keeps for them. Each reader follows the
-- trigger class's evaluation in the game (GOG 4.5.2 RVAs, docs/script_runtime.md) and reads only
-- what the save writes; what it cannot read is said there, not invented.

local world = require("engine.world")

local R = {}

local NO_ID = 4294967295
local floor = math.floor

local function defs()
    return require("engine.defs")
end
R.defs = defs

-- a reference as the save writes it: an id, or nil for none (4294967295)
local function ref(v)
    v = tonumber(v)
    return (v and v ~= NO_ID) and v or nil
end
R.ref = ref

-- the stores the script layer names by kind that engine.world does not name yet
world.KINDS.cosmic_storm = world.KINDS.cosmic_storm or "storms"
world.KINDS.council_position = world.KINDS.council_position or "council_positions"
world.KINDS.colony = world.KINDS.colony or "colony"
world.KINDS.spy_network = world.KINDS.spy_network or "spy_networks"
world.KINDS.archaeological_site = world.KINDS.archaeological_site or "sites"
world.KINDS.natural_wormhole = world.KINDS.natural_wormhole or "natural_wormholes"
world.KINDS.bypass = world.KINDS.bypass or "bypasses"

local function obj(kind, id)
    return id and world.object(kind, id)
end
R.obj = obj

local function list_has(block, value)
    for _, v in ipairs(world.list(block)) do
        if v == value then return true end
    end
    return false
end
R.list_has = list_has

-- ---------------------------------------------------------------------------------------------
-- the scope's objects

-- R.system_of(kind, id) -> the system (galactic object) id of a scope: a system itself, a planet's
-- (its coordinate's origin), a fleet's, a ship's (its fleet's), a starbase's (its station ship's),
-- a megastructure's (its coordinate's origin), a colony's (its planet's)
function R.system_of(kind, id)
    if kind == "system" then
        return id
    elseif kind == "starbase" then
        local sb = obj("starbase", id)
        return sb and R.system_of("ship", tonumber(world.field(sb, "station")))
    elseif kind == "ship" then
        local s = obj("ship", id)
        return s and R.system_of("fleet", tonumber(world.field(s, "fleet")))
    elseif kind == "fleet" then
        -- a fleet keeps its position in movement_manager.coordinate (the fleet movement's state
        -- when it runs); nil in FTL
        local ok, movement = pcall(require, "engine.fleets.movement")
        if ok and movement.system_of then
            return movement.system_of(id)
        end
        local f = obj("fleet", id)
        local c = f and world.path(f, "movement_manager", "coordinate")
        return type(c) == "table" and ref(world.field(c, "origin")) or nil
    elseif kind == "colony" then
        return R.system_of("planet", world.colony_planet[id])
    elseif kind == "pop_group" then
        local g = obj("pop_group", id)
        local col = g and tonumber(world.field(g, "planet"))
        return col and R.system_of("planet", world.colony_planet[col])
    end
    local o = obj(kind, id)
    local coord = o and world.field(o, "coordinate")
    return type(coord) == "table" and ref(world.field(coord, "origin")) or nil
end

-- R.colony_of(kind, id) -> colony id of a scope (NScriptUtil::GetColonyFromScope 0x9f4ad0: a
-- planet's `colony`, a ship's `colony` (its carrier's), a colony itself; nil for any other scope)
function R.colony_of(kind, id)
    local col
    if kind == "colony" then
        col = id
    elseif kind == "planet" then
        col = world.planet_colony[id]
    elseif kind == "ship" then
        local s = obj("ship", id)
        col = s and ref(world.field(s, "colony"))
    end
    return (col and obj("colony", col)) and col or nil
end

-- R.carrier_of(kind, id) -> kind, id of the scope's colony carrier (NScriptUtil::GetCarrierFromScope
-- 0x9f48a0): a planet itself, a ship itself, a colony's `carrier = { type reference }`; nil else
function R.carrier_of(kind, id)
    if kind == "planet" then
        return obj("planet", id) and "planet" or nil, id
    elseif kind == "ship" then
        return obj("ship", id) and "ship" or nil, id
    elseif kind == "colony" then
        local c = obj("colony", id)
        local carrier = c and world.field(c, "carrier")
        if type(carrier) ~= "table" then return nil end
        local t, r = world.field(carrier, "type"), ref(world.field(carrier, "reference"))
        if t == "planet" or t == "ship" then
            return obj(t, r) and t or nil, r
        end
    end
    return nil
end

-- R.exists(kind, id): the object is in its store (a scope kind the world keeps no store for counts
-- as existing)
function R.exists(kind, id)
    local name = world.KINDS[kind] or kind
    if world.stores[name] == nil then return true end
    return world.stores[name][id] ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- ships and fleets (`ships = { <id> = { fleet ship_design_implementation = { design growth_stage }
-- ... } }`, `fleet = { <id> = { ships = { ... } ... } }`, `ship_design = { <id> = { growth_stages
-- = { { ship_size ... } } } }`)

-- R.fleet_ships(fleet) -> its ship ids, in order
function R.fleet_ships(fid)
    local f = obj("fleet", fid)
    local out = {}
    for _, v in ipairs(world.list(f and world.field(f, "ships"))) do
        out[#out + 1] = tonumber(v)
    end
    return out
end

-- R.design_stage(design, stage) -> the design's growth stage block (stage counted from 0; the first
-- when the index is outside the stages, as CIsSpaceFaunaTrigger reads it), or nil
function R.design_stage(did, stage)
    local d = obj("ship_design", did)
    local stages = world.blocks(d and world.field(d, "growth_stages"))
    stage = tonumber(stage) or 0
    if stage < 0 or stage >= #stages then stage = 0 end
    return stages[stage + 1]
end

-- R.ship_size_of(ship) -> the ship size key of the ship (its design's growth stage's ship_size)
function R.ship_size_of(sid)
    local s = obj("ship", sid)
    local impl = s and world.field(s, "ship_design_implementation")
    if type(impl) ~= "table" then return nil end
    local g = R.design_stage(tonumber(world.field(impl, "design")), world.field(impl, "growth_stage"))
    return g and world.field(g, "ship_size") or nil
end

-- R.ship_size_flag(size, key): the ship size definition (common/ship_sizes) has `key = yes`
function R.ship_size_flag(size, key)
    local d = size and defs().get("common/ship_sizes", size)
    return d ~= nil and defs().field(d.block, key) == "yes"
end

-- ---------------------------------------------------------------------------------------------
-- cosmic storms (`storms = { storms = { <id> = { type ... } } }`, CCosmicStorm::WriteMembers
-- 0xda00c0; a system's `storm = <id>`, CGalacticObject +0x10d0 _StormRef)

-- R.storm_of_system(system) -> the id of the storm the system is inside, or nil
function R.storm_of_system(sid)
    local s = obj("system", sid)
    local storm = s and ref(world.field(s, "storm"))
    return (storm and obj("cosmic_storm", storm)) and storm or nil
end

-- R.storm_type(storm) -> its type (common/cosmic_storms key), or nil
function R.storm_type(storm)
    local o = obj("cosmic_storm", storm)
    return o and world.field(o, "type") or nil
end

-- ---------------------------------------------------------------------------------------------
-- megastructures (`megastructures = { <id> = { type ... } }`)

-- R.megastructures_of(kind, id) -> the megastructure ids CHasMegaStructureTrigger (0x19a56a0) walks:
-- a country's `owned_megastructures` (CCountry +0x2fc0 _MegaStructures), a system's `megastructures`
-- (CGalacticObject +0x508); nil for another scope
function R.megastructures_of(kind, id)
    local field
    if kind == "country" then
        field = "owned_megastructures"
    elseif kind == "system" then
        field = "megastructures"
    else
        return nil
    end
    local o = obj(kind, id)
    local out = {}
    for _, v in ipairs(world.list(o and world.field(o, field))) do
        out[#out + 1] = tonumber(v)
    end
    return out
end

function R.megastructure_type(mid)
    local m = obj("megastructure", mid)
    return m and world.field(m, "type") or nil
end

-- ---------------------------------------------------------------------------------------------
-- countries

-- R.country_setting(country, name): a bit of CCountry +0x2a70 _Settings, written by
-- CCountry::Settings_WriteMembers (0x6dd8f0) as `<name> = yes` when set (is_nomadic, colonizer,
-- rebel, initialized, has_advisor, ...)
function R.country_setting(country, name)
    local c = obj("country", country)
    return c ~= nil and world.field(c, name) == "yes"
end

-- R.covenant_patron(country) -> the patron of the country's covenant, or nil
-- (CShroudCountryModule +0x68 _Covenant, a CPdxOptional<CPatronCovenant>: `modules = {
-- standard_shroud_module = { covenant = { patron = x level = n } } }`, written only when set,
-- CShroudCountryModule::WriteMembers 0x60c000, CPatronCovenant: patron, level)
function R.covenant_patron(country)
    local c = obj("country", country)
    local cov = c and world.path(c, "modules", "standard_shroud_module", "covenant")
    return type(cov) == "table" and world.field(cov, "patron") or nil
end

-- R.crisis_levels(country) -> the crisis levels the country unlocked, in order
-- (CCountry +0x30e8 _pCrisisProgression, its levels array; `crisis_progression = { level = x ... }`)
function R.crisis_levels(country)
    local c = obj("country", country)
    local cp = c and world.field(c, "crisis_progression")
    local out = {}
    for _, v in ipairs(type(cp) == "table" and world.fields(cp, "level") or {}) do
        if type(v) == "string" then out[#out + 1] = v end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- starbases (`starbase_mgr = { starbases = { <id> = { level station modules buildings ... } } }`)

-- the starbase levels in database order (common/starbase_levels, by file and line)
local level_order
local function levels()
    if level_order == nil then
        level_order = {}
        local l = {}
        for name, d in pairs(defs().folder("common/starbase_levels")) do
            l[#l + 1] = { name = name, file = d.file or "", line = d.line or 0, block = d.block }
        end
        table.sort(l, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.line < b.line
        end)
        level_order = l
    end
    return level_order
end

-- R.level_of_size(ship size) -> the first starbase level (in database order) whose `ship_size` is
-- the ship size (CHasStarbaseSizeCompareTrigger::PostInit 0x19c2e00), or nil
local level_of_size_cache = {}
function R.level_of_size(size)
    local v = level_of_size_cache[size]
    if v == nil then
        v = false
        for _, l in ipairs(levels()) do
            if defs().field(l.block, "ship_size") == size then
                v = l.name
                break
            end
        end
        level_of_size_cache[size] = v
    end
    return v or nil
end

-- R.next_level(level) -> the level's `next_level` (CStarbaseLevelType +0x100), or nil
function R.next_level(level)
    local d = defs().get("common/starbase_levels", level)
    return d and defs().field(d.block, "next_level") or nil
end

-- R.level_reaches(from, to): to is reached from `from` by following next_level (from excluded)
function R.level_reaches(from, to)
    local cur, n = R.next_level(from), 0
    while cur and n < 64 do
        if cur == to then return true end
        cur, n = R.next_level(cur), n + 1
    end
    return false
end

-- R.starbase_level(starbase) -> its level (`level = "starbase_level_x"`), or nil
function R.starbase_level(sb)
    local o = obj("starbase", sb)
    local l = o and world.field(o, "level")
    return (type(l) == "string" and defs().get("common/starbase_levels", l)) and l or nil
end

-- ---------------------------------------------------------------------------------------------
-- leaders, councils, sectors

-- R.council_positions_of(country) -> the ids of the council positions of the country's government
-- (`government = { council_positions = { ... } }`; CGovernment's array CCouncilorTypeTrigger reads)
function R.council_positions_of(country)
    local c = obj("country", country)
    local out = {}
    local gov = c and world.field(c, "government")
    for _, v in ipairs(world.list(type(gov) == "table" and world.field(gov, "council_positions") or nil)) do
        out[#out + 1] = tonumber(v)
    end
    return out
end

-- R.council_position_of_leader(leader) -> the council position (its block) the leader holds in its
-- country's government, or nil (CCouncilorTypeTrigger 0x19bed10: the government's positions whose
-- `leader` is the leader)
function R.council_position_of_leader(lid)
    local l = obj("leader", lid)
    local country = l and ref(world.field(l, "country"))
    if not country then return nil end
    for _, pid in ipairs(R.council_positions_of(country)) do
        local p = obj("council_position", pid)
        if p and tonumber(world.field(p, "leader")) == lid then
            return p
        end
    end
    return nil
end

-- R.is_councilor(leader) (CIsCouncilorTrigger 0x19beb90): the ruler of its country, or its
-- `council_location = { type = council_position id = <position> }` names a position
function R.is_councilor(lid)
    local l = obj("leader", lid)
    if not l then return false end
    local c = obj("country", ref(world.field(l, "country")))
    if c and tonumber(world.field(c, "ruler")) == lid then return true end
    local loc = world.field(l, "council_location")
    return type(loc) == "table" and world.field(loc, "type") == "council_position"
        and ref(world.field(loc, "id")) ~= nil
end

-- R.is_sector_capital(colony) (CIsSectorCapitalTrigger 0x1957bf0): the sector of the colony's
-- system (`sector = <id>`, CGalacticObject +0x584) has the colony as its `local_capital`
-- (CSector +0x16c)
function R.is_sector_capital(col)
    local sys = R.system_of("colony", col)
    local s = sys and obj("system", sys)
    local sector = s and ref(world.field(s, "sector"))
    local so = sector and obj("sector", sector)
    return so ~= nil and tonumber(world.field(so, "local_capital")) == col
end

-- ---------------------------------------------------------------------------------------------
-- fleets and ships, more

-- R.fleet_owner(fleet) -> the country whose fleets_manager.owned_fleets lists it (CFleet +0x44c)
function R.fleet_owner(fid)
    return fid and world.fleet_owner and world.fleet_owner[fid] or nil
end

function R.ship_fleet(sid)
    local s = obj("ship", sid)
    return s and ref(world.field(s, "fleet")) or nil
end

-- R.ship_size_field(size, key) -> a field of the ship size definition (class, ship_category, ...)
function R.ship_size_field(size, key)
    local d = size and defs().get("common/ship_sizes", size)
    return d and defs().field(d.block, key) or nil
end

-- R.ship_alive(ship) (CShip::IsAlive): hit points above 0
function R.ship_alive(sid)
    local s = obj("ship", sid)
    return s ~= nil and (tonumber(world.field(s, "hitpoints")) or 0) > 0
end

-- R.fleet_order_names(fleet) -> the names of its current order and that order's sub orders, and of
-- its queued orders (CHasFleetOrderTrigger 0x1992000: `current_order = { <name> = { ... sub_order =
-- { <name> = { } } } }`, `order = { <name> = { } ... }`)
function R.fleet_order_names(fid)
    local f = obj("fleet", fid)
    local out = {}
    if not f then return out end
    local cur = world.field(f, "current_order")
    local n = 0
    while type(cur) == "table" and n < 32 do
        local nxt
        for _, e in ipairs(cur) do
            if e.op and e.key and e.value.text == nil then
                out[#out + 1] = e.key.text
                nxt = world.field(e.value, "sub_order")
                break
            end
        end
        cur, n = nxt, n + 1
    end
    for _, q in ipairs(world.fields(f, "order")) do
        if type(q) == "table" then
            for _, e in ipairs(q) do
                if e.op and e.key and e.value.text == nil then out[#out + 1] = e.key.text end
            end
        end
    end
    return out
end

-- R.fleet_property(fleet, name): `properties = { <name> = yes }` (TFleetFlags::WriteMembers 0xc56210)
function R.fleet_property(fid, name)
    local f = obj("fleet", fid)
    local p = f and world.field(f, "properties")
    return type(p) == "table" and world.field(p, name) == "yes"
end

-- R.owned_fleet_entries(country) -> the blocks of its fleets_manager.owned_fleets, in order
function R.owned_fleet_entries(country)
    local c = obj("country", country)
    return world.blocks(c and world.path(c, "fleets_manager", "owned_fleets"))
end

-- R.owned_fleets(country) -> fleet ids (COwnedFleetListBuilder 0x1813f40: every entry)
function R.owned_fleets(country)
    local out = {}
    for _, e in ipairs(R.owned_fleet_entries(country)) do
        local f = ref(world.field(e, "fleet"))
        if f and obj("fleet", f) then out[#out + 1] = f end
    end
    return out
end

-- R.controlled_fleets(country) -> fleet ids: _ControlledFleets as PostGameStateReadInit (0x917f20)
-- rebuilds it from every country's owned entries: a normal entry is its owner's, a leased or lost one
-- (`ownership_status`) its `debtor`'s
function R.controlled_fleets(country)
    local out = {}
    for _, cid in ipairs(world.all("country")) do
        for _, e in ipairs(R.owned_fleet_entries(cid)) do
            local f = ref(world.field(e, "fleet"))
            if f and obj("fleet", f) then
                local status = world.field(e, "ownership_status")
                local ctrl = cid
                if status ~= nil and status ~= "normal" and status ~= 0 then
                    ctrl = ref(world.field(e, "debtor"))
                end
                if ctrl == country then out[#out + 1] = f end
            end
        end
    end
    return out
end

-- R.alive_ships(fleets) -> the alive ships of the fleets, in order (COwnedShipListBuilder 0x1815c00)
function R.alive_ships(fleets)
    local out = {}
    for _, fid in ipairs(fleets) do
        for _, sid in ipairs(R.fleet_ships(fid)) do
            if R.ship_alive(sid) then out[#out + 1] = sid end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- systems

-- R.primary_starbase(system) -> the first of its `starbases` when it exists (CGalacticObject
-- +0x568; 4294967295 in an unowned system), or nil
function R.primary_starbase(sid)
    local s = obj("system", sid)
    local first = s and world.list(world.field(s, "starbases"))[1]
    local sb = ref(first)
    return (sb and obj("starbase", sb)) and sb or nil
end

-- R.starbase_owner(starbase) -> its station ship's fleet's owner
function R.starbase_owner(sb)
    local o = obj("starbase", sb)
    local station = o and ref(world.field(o, "station"))
    return station and R.fleet_owner(R.ship_fleet(station)) or nil
end

-- R.system_owner(system) -> the owner of its primary starbase (CGalacticObject's ownership cache)
function R.system_owner(sid)
    local sb = R.primary_starbase(sid)
    return sb and R.starbase_owner(sb) or nil
end

-- R.hyperlanes(system) -> the systems its hyperlanes go to, in order (`hyperlane = { { to length } }`)
function R.hyperlanes(sid)
    local s = obj("system", sid)
    local out = {}
    for _, h in ipairs(world.blocks(s and world.field(s, "hyperlane"))) do
        local to = ref(world.field(h, "to"))
        if to then out[#out + 1] = to end
    end
    return out
end

-- R.system_list(system, key) -> the ids of a list field of the system (`natural_wormholes`,
-- `fleet_presence`, `megastructures`, ...)
function R.system_list(sid, key)
    local s = obj("system", sid)
    local out = {}
    for _, v in ipairs(world.list(s and world.field(s, key))) do
        local id = ref(v)
        if id then out[#out + 1] = id end
    end
    return out
end

-- R.capital_system(country) -> the system of the country's capital colony's carrier
function R.capital_system(country)
    local c = obj("country", country)
    local col = c and ref(world.field(c, "capital"))
    local kind, id = col and R.carrier_of("colony", col)
    if not kind then return nil end
    return R.system_of(kind, id)
end

-- ---------------------------------------------------------------------------------------------
-- starbases, more

-- R.starbase_items(starbase, key) -> the values of its `buildings` / `modules` (`<slot> = <key>`)
function R.starbase_items(sb, key)
    local o = obj("starbase", sb)
    local b = o and world.field(o, key)
    local out = {}
    for _, e in ipairs(type(b) == "table" and b or {}) do
        if e.op and e.value and e.value.text then out[#out + 1] = e.value.text end
    end
    return out
end

-- R.starbase_of_station(ship) -> the starbase whose `station` is the ship (CStarbaseManager
-- ::GetStarbaseThruLookup), or nil
function R.starbase_of_station(sid)
    for _, sb in ipairs(world.all("starbase")) do
        if tonumber(world.field(obj("starbase", sb), "station")) == sid then return sb end
    end
    return nil
end

-- the construction items (`construction = { item_mgr = { items = { <id> = { ... } } } }`)
local function construction_items()
    return world.stores["construction.item_mgr.items"] or {}
end
R.construction_items = construction_items

-- R.has_queued_upgrade(starbase) (CStarbase::HasQueuedUpgradeConstruction): an item
-- `buildable_starbase_upgrade = { starbase_upgrade starbase = <id> }`
function R.has_queued_upgrade(sb)
    for _, it in pairs(construction_items()) do
        local u = world.field(it, "buildable_starbase_upgrade")
        if type(u) == "table" and tonumber(world.field(u, "starbase")) == sb then return true end
    end
    return false
end

-- R.country_starbases(country) -> the starbases of the systems whose starbases the country owns
-- (the systems' `starbases`, each one whose owner is the country)
function R.country_starbases(country)
    local out = {}
    for _, sid in ipairs(world.all("system")) do
        for _, v in ipairs(world.list(world.field(obj("system", sid), "starbases"))) do
            local sb = ref(v)
            if sb and obj("starbase", sb) and R.starbase_owner(sb) == country then out[#out + 1] = sb end
        end
    end
    return out
end

-- a define of common/defines (NGameplay, ...), or the default
local function define(group, key, default)
    local g = defs().get("common/defines", group)
    return g and tonumber(defs().field(g.block, key)) or default
end
R.define = define

-- R.starbase_capacity_used(country) (CCountry::CalcStarbaseCapacityUsed 0x749b30): the levels'
-- starbase_capacity_used of the starbases it owns (megastructures' capacity used: none in vanilla,
-- not counted)
function R.starbase_capacity_used(country)
    local n = 0
    for _, sb in ipairs(R.country_starbases(country)) do
        n = n + (tonumber(R.level_field(R.starbase_level(sb), "starbase_capacity_used")) or 0)
    end
    return n
end

-- R.starbase_capacity(country) (CCountry::CalcStarbaseCapacity 0x73bb40): STARBASE_CAPACITY_BASE +
-- STARBASE_CAPACITY_SYSTEM_MULT per owned system + STARBASE_CAPACITY_POP_MULT per pop +
-- country_starbase_capacity_add, times 1 + country_starbase_capacity_mult, rounded down [I: it
-- gives every country's saved starbase_capacity at 2210.01.01]
function R.starbase_capacity(country)
    local systems = 0
    for _, sid in ipairs(world.all("system")) do
        if R.system_owner(sid) == country then systems = systems + 1 end
    end
    local c = obj("country", country)
    local pops = c and tonumber(world.field(c, "num_sapient_pops")) or 0
    local ok, economy = pcall(require, "engine.economy")
    local M = ok and economy.modifiers and economy.modifiers("country", country) or {}
    local v = define("NGameplay", "STARBASE_CAPACITY_BASE", 3) + define("NGameplay", "STARBASE_CAPACITY_SYSTEM_MULT", 0.1) * systems
        + define("NGameplay", "STARBASE_CAPACITY_POP_MULT", 0) * pops + (M.country_starbase_capacity_add or 0)
    v = v * (1 + (M.country_starbase_capacity_mult or 0))
    return math.min(math.floor(v + 1e-9), define("NGameplay", "STARBASE_CAPACITY_MAX", 999))
end

-- R.upgrading_outposts(country) (CCountry::CalcNumUpgradingOutpostStarbases 0x749db0): the systems of
-- the country whose primary starbase is not upgraded (its level has no lower level: the outpost)
-- and has an upgrade queued
function R.upgrading_outposts(country)
    local n = 0
    for _, sid in ipairs(world.all("system")) do
        local sb = R.primary_starbase(sid)
        if sb and R.starbase_owner(sb) == country then
            local level = R.starbase_level(sb)
            if level and R.level_of_size("starbase_outpost") == level and R.has_queued_upgrade(sb) then
                n = n + 1
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- planets, colonies, deposits

-- R.planet_class_flag(planet, key): the planet's class (common/planet_classes) has `key = yes`
function R.planet_class_flag(pid, key)
    local p = obj("planet", pid)
    local class = p and world.field(p, "planet_class")
    local d = class and defs().get("common/planet_classes", class)
    return d ~= nil and defs().field(d.block, key) == "yes"
end

-- R.carrier_deposits(kind, id) -> the deposit ids of a carrier (a planet's, a ship's `deposits`)
function R.carrier_deposits(kind, id)
    local o = obj(kind, id)
    local out = {}
    for _, v in ipairs(world.list(o and world.field(o, "deposits"))) do
        local d = ref(v)
        if d and obj("deposit", d) then out[#out + 1] = d end
    end
    return out
end

function R.deposit_type(did)
    local d = obj("deposit", did)
    return d and world.field(d, "type") or nil
end

-- R.deposit_type_field(type, key) -> a field of the deposit type (common/deposits)
function R.deposit_type_field(dtype, key)
    local d = dtype and defs().get("common/deposits", dtype)
    return d and defs().field(d.block, key) or nil
end

-- R.deposit_is_blocker(type): the deposit type's category (common/deposit_categories) has
-- `blocker = yes` (CDepositCategory +0x49)
function R.deposit_is_blocker(dtype)
    local cat = R.deposit_type_field(dtype, "category")
    local d = cat and defs().get("common/deposit_categories", cat)
    return d ~= nil and defs().field(d.block, "blocker") == "yes"
end

-- R.deposit_has_resources(type) (CDeposit::HasResources: its economic unit's resource table is not
-- empty): the type's `resources = { produces = { ... } }` names a resource [I: produce entries with
-- triggers are not evaluated]
function R.deposit_has_resources(dtype)
    local res = R.deposit_type_field(dtype, "resources")
    if type(res) ~= "table" then return false end
    for _, e in ipairs(res) do
        if e.op and e.key and e.key.text == "produces" and e.value.text == nil then
            for _, x in ipairs(e.value) do
                if x.op and x.key and (x.value.text == nil or (tonumber(x.value.text) or 1) ~= 0) then
                    return true
                end
            end
        end
    end
    return false
end

-- R.deposit_produces(type, resource): the type's `resources = { produces = { <resource> = x } }`
function R.deposit_produces(dtype, res)
    local t = R.deposit_type_field(dtype, "resources")
    for _, e in ipairs(type(t) == "table" and t or {}) do
        if e.op and e.key and e.key.text == "produces" and e.value.text == nil then
            for _, x in ipairs(e.value) do
                if x.op and x.key and x.key.text == res and (tonumber(x.value.text) or 1) ~= 0 then return true end
            end
        end
    end
    return false
end

-- R.colony_field(colony, key)
function R.colony_field(col, key)
    local c = obj("colony", col)
    return c and world.field(c, key)
end

-- R.colony_job(colony, type) -> the first pop job of the colony (`pop_jobs = { ids }`) of the type
-- (CColony::AccessPopJob 0xdb0b10), or nil
function R.colony_job(col, jtype)
    local c = obj("colony", col)
    for _, v in ipairs(world.list(c and world.field(c, "pop_jobs"))) do
        local j = obj("pop_job", tonumber(v))
        if j and world.field(j, "type") == jtype then return j end
    end
    return nil
end

-- R.colony_buildings(colony) -> building ids of its `buildings_cache` (the buildings of its owner)
function R.colony_buildings(col)
    local out = {}
    for _, v in ipairs(world.list(R.colony_field(col, "buildings_cache"))) do
        local b = tonumber(v)
        if b and obj("buildings", b) then out[#out + 1] = b end
    end
    return out
end

-- R.colony_zone_buildings(colony) -> building ids in its districts' zones (`districts` ->
-- `zones` -> `buildings`)
function R.colony_zone_buildings(col)
    local out = {}
    for _, d in ipairs(world.list(R.colony_field(col, "districts"))) do
        for _, z in ipairs(world.list(world.field(obj("districts", tonumber(d)), "zones"))) do
            local zo = obj("zones", ref(z))
            for _, b in ipairs(world.list(zo and world.field(zo, "buildings"))) do
                local bid = ref(b)
                if bid then out[#out + 1] = bid end
            end
        end
    end
    return out
end

function R.building_field(bid, key)
    local b = obj("buildings", bid)
    return b and world.field(b, key)
end

-- ---------------------------------------------------------------------------------------------
-- countries, more

local RESEARCH_INDEX = { physics_research = 1, society_research = 2, engineering_research = 3 }
-- R.stockpile(country, resource) (CStandardEconomyCountryModule::BuildResourceTable 0x7fe7e0): the
-- economy module's resources, research read from tech_status.stored_techpoints (physics, society,
-- engineering)
function R.stockpile(country, res)
    local c = obj("country", country)
    if not c then return 0 end
    local ri = RESEARCH_INDEX[res]
    if ri then
        local v = world.list(world.path(c, "tech_status", "stored_techpoints"))[ri]
        return tonumber(v) or 0
    end
    return tonumber(world.path(c, "modules", "standard_economy_module", "resources", res)) or 0
end

-- R.country_list(country, key) -> the values of a list field of the country (`ascension_perks`,
-- `traditions`, ...)
function R.country_list(country, key)
    local c = obj("country", country)
    return world.list(c and world.field(c, key))
end

-- R.has_edict(country, edict) (CHasEdictTrigger 0x197e730): `edicts = { { edict = x ... } }`, no date
-- check
function R.has_edict(country, edict)
    local c = obj("country", country)
    for _, b in ipairs(world.blocks(c and world.field(c, "edicts"))) do
        if world.field(b, "edict") == edict then return true end
    end
    return false
end

-- R.country_events_field(country, key) -> the blocks of `events = { <key> = { } ... }`
function R.country_events(country, key)
    local c = obj("country", country)
    local ev = c and world.field(c, "events")
    local out = {}
    for _, v in ipairs(type(ev) == "table" and world.fields(ev, key) or {}) do
        if type(v) == "table" then out[#out + 1] = v end
    end
    return out
end

-- R.country_type_field(country, key) -> a field of the country's type (common/country_types)
function R.country_type_field(country, key)
    local c = obj("country", country)
    local t = c and world.field(c, "type")
    local d = t and defs().get("common/country_types", t)
    return d and defs().field(d.block, key) or nil
end

-- R.num_rare_techs(country) (CNumRareTechsTrigger 0x198fe60): its technologies whose definition has
-- `is_rare = yes`
function R.num_rare_techs(country)
    local c = obj("country", country)
    local n = 0
    for _, t in ipairs(world.fields(c and world.field(c, "tech_status"), "technology")) do
        local d = type(t) == "string" and defs().get("common/technology", t)
        if d and defs().field(d.block, "is_rare") == "yes" then n = n + 1 end
    end
    return n
end

-- the galactic community (`galactic_community = { members leader empire passed ... }` in the
-- save's top level; absent fields: no community)
function R.galactic_community()
    local gc = world.meta and world.meta.galactic_community
    return type(gc) == "table" and gc or nil
end

-- R.gc_member(country): in `galactic_community.members`
function R.gc_member(country)
    local gc = R.galactic_community()
    for _, v in ipairs(world.list(gc and world.field(gc, "members"))) do
        if tonumber(v) == country then return true end
    end
    return false
end

-- R.gc_leader() -> the community's `leader` and whether it is an empire (`empire = yes`)
function R.gc_leader()
    local gc = R.galactic_community()
    if not gc then return nil, false end
    return ref(world.field(gc, "leader")), world.field(gc, "empire") == "yes"
end

-- ---------------------------------------------------------------------------------------------
-- plain field readers

R.all = function(kind) return world.all(kind) end
local function field_of(kind)
    return function(id, key)
        local o = obj(kind, id)
        return o and world.field(o, key)
    end
end
R.country_field = field_of("country")
R.planet_field = field_of("planet")
R.system_field = field_of("system")
R.starbase_field = field_of("starbase")
R.fleet_field = field_of("fleet")
R.ship_field = field_of("ship")
R.situation_field = field_of("situation")
R.leader_field = field_of("leader")

-- R.planet_owner(planet) -> its `owner`, or nil
function R.planet_owner(pid)
    return ref(R.planet_field(pid, "owner"))
end

-- R.level_field(level, key) -> a field of a starbase level (common/starbase_levels)
function R.level_field(level, key)
    local d = level and defs().get("common/starbase_levels", level)
    return d and defs().field(d.block, key) or nil
end

-- R.ship_size_prerequisites(size) -> the technologies of its `prerequisites = { ... }`
function R.ship_size_prerequisites(size)
    local p = R.ship_size_field(size, "prerequisites")
    local out = {}
    for _, e in ipairs(type(p) == "table" and p or {}) do
        if e.text then out[#out + 1] = e.text end
    end
    return out
end

-- R.country_type_flag(country, ...) -> a field of the country's type, along a path of blocks
-- (`faction`, `primitive`: the primitive setting, SCountryInstanceProperties IsPrimitive [I])
function R.country_type_flag(country, ...)
    local c = obj("country", country)
    local t = c and world.field(c, "type")
    local d = t and defs().get("common/country_types", t)
    local v = d and d.block
    for _, k in ipairs({ ... }) do
        if type(v) ~= "table" then return nil end
        v = defs().field(v, k)
    end
    return v
end

-- R.tradition_of(key) -> the tradition and the swap (nil) a key names: a tradition (common/traditions
-- key), or a tradition swap's `name` (its tradition, and the swap name)
local swaps_by_name
function R.tradition_of(key)
    if defs().get("common/traditions", key) then return key, nil end
    if swaps_by_name == nil then
        swaps_by_name = {}
        for tname, d in pairs(defs().folder("common/traditions")) do
            for _, e in ipairs(d.block) do
                if e.op and e.key and e.key.text == "tradition_swap" and e.value.text == nil then
                    local n = defs().field(e.value, "name")
                    if n then swaps_by_name[n] = tname end
                end
            end
        end
    end
    local t = swaps_by_name[key]
    return t, t and key or nil
end

-- R.tradition_swaps(tradition) -> { { name, trigger, inherit_effects } } in definition order
function R.tradition_swaps(trad)
    local d = defs().get("common/traditions", trad)
    local out = {}
    for _, e in ipairs(d and d.block or {}) do
        if e.op and e.key and e.key.text == "tradition_swap" and e.value.text == nil then
            local trig = defs().field(e.value, "trigger")
            out[#out + 1] = { name = defs().field(e.value, "name"), trigger = type(trig) == "table" and trig or nil,
                inherit_effects = defs().field(e.value, "inherit_effects") == "yes" }
        end
    end
    return out
end

-- R.federation_field(federation, key) -> a field of its `federation_progression`
function R.federation_field(fid, key)
    local f = obj("federation", fid)
    local p = f and world.field(f, "federation_progression")
    return type(p) == "table" and world.field(p, key) or nil
end

-- R.has_ethic(kind, id, ethic): a pop group's `ethos = { ethics = { ... } }` has it
-- (CPopGroup::HasEthic 0x51a480: presence in the list); a leader's background `ethic` is it
function R.has_ethic(kind, id, ethic)
    local o = obj(kind, id)
    if not o then return false end
    if kind == "leader" then return world.field(o, "ethic") == ethic end
    local ethos = world.field(o, "ethos")
    for _, v in ipairs(world.list(type(ethos) == "table" and world.field(ethos, "ethics") or nil)) do
        if v == ethic then return true end
    end
    for _, b in ipairs(type(ethos) == "table" and world.fields(ethos, "ethic") or {}) do
        if b == ethic or (type(b) == "table" and world.field(b, "ethic") == ethic) then return true end
    end
    return false
end

-- R.spy_network_owner(network) -> its `owner`
function R.spy_network_owner(nid)
    local n = obj("spy_network", nid)
    return n and ref(world.field(n, "owner")) or nil
end

-- R.country_spy_networks(country) -> its `espionage_manager = { spy_networks = { ... } }`
function R.country_spy_networks(country)
    local c = obj("country", country)
    local out = {}
    for _, v in ipairs(world.list(c and world.path(c, "espionage_manager", "spy_networks"))) do
        local n = ref(v)
        if n and obj("spy_network", n) then out[#out + 1] = n end
    end
    return out
end

-- R.last_jump_origin(fleet) -> the system its last FTL jump left (`movement_manager = {
-- last_ftl_jump = { from = { origin } } }`), or nil
function R.last_jump_origin(fid)
    local f = obj("fleet", fid)
    local from = f and world.path(f, "movement_manager", "last_ftl_jump", "from")
    return type(from) == "table" and ref(world.field(from, "origin")) or nil
end

-- R.site_system(site) -> the system of the archaeological site's location
function R.site_system(sid)
    local s = obj("archaeological_site", sid)
    local loc = s and world.field(s, "location")
    if type(loc) ~= "table" then return nil end
    local kinds = { [0] = "ship", [2] = "planet", [3] = "fleet", [4] = "system", [6] = "megastructure" }
    local kind = kinds[tonumber(world.field(loc, "type"))]
    return kind and R.system_of(kind, tonumber(world.field(loc, "id"))) or nil
end

-- R.is_active_resolution(type, can_be_active) (CGalacticCommunity::IsResolutionActive 0x62bc10): the
-- community's `passed` resolutions from the newest: the type -> its can_be_active trigger (with the
-- proposer and target, can_be_active(block, proposer, target)), none -> true; a newer one of the
-- same category that does not allow several active ones -> false. The resolutions are read from the
-- `resolutions` store [I: the saves have no community to show it]
function R.is_active_resolution(rtype, can_be_active)
    local gc = R.galactic_community()
    local passed = gc and world.list(world.field(gc, "passed")) or {}
    local def = defs().get("common/resolutions", rtype)
    local cat = def and defs().field(def.block, "category")
    for i = #passed, 1, -1 do
        local res = obj("resolutions", tonumber(passed[i]))
        local t = res and world.field(res, "type")
        if t == rtype then
            local cba = def and defs().field(def.block, "can_be_active")
            if type(cba) ~= "table" then return true end
            return can_be_active(cba, ref(world.field(res, "country")), ref(world.field(res, "target")))
        end
        local d2 = t and defs().get("common/resolutions", t)
        if cat and d2 and defs().field(d2.block, "category") == cat then
            local cd = defs().get("common/resolution_categories", cat)
            if not (cd and defs().field(cd.block, "multiple_active_resolutions") == "yes") then
                return false
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- situations, federations, galaxy settings, factions, technologies

-- R.situation_stage_key(situation) -> the key of its current stage: `stage = <index>` (0-based)
-- into its type's `stages = { <key> = { } ... }` (common/situations, definition order)
function R.situation_stage_key(sid)
    local s = obj("situation", sid)
    local t = s and world.field(s, "type")
    local d = t and defs().get("common/situations", t)
    local stages = d and defs().field(d.block, "stages")
    local i = s and tonumber(world.field(s, "stage"))
    if type(stages) ~= "table" or not i then return nil end
    local n = 0
    for _, e in ipairs(stages) do
        if e.op and e.key and e.value.text == nil then
            if n == i then return e.key.text end
            n = n + 1
        end
    end
    return nil
end

-- R.situation_has_approach(type, key): the situation type has an approach of that key
function R.situation_has_approach(stype, key)
    local d = stype and defs().get("common/situations", stype)
    local ap = d and defs().field(d.block, "approaches")
    for _, e in ipairs(type(ap) == "table" and ap or {}) do
        if e.op and e.key and e.value.text == nil then
            local name = defs().field(e.value, "name") or e.key.text
            if name == key or e.key.text == key then return true end
        end
    end
    return false
end

-- R.federation_laws(federation) -> { [category] = law } of `federation_progression = { laws = {
-- <category> = <law> } }`
function R.federation_laws(fid)
    local laws = {}
    local f = obj("federation", fid)
    local l = f and world.path(f, "federation_progression", "laws")
    for _, e in ipairs(type(l) == "table" and l or {}) do
        if e.op and e.key and e.value.text then laws[e.key.text] = e.value.text end
    end
    return laws
end

-- R.federation_perks(federation) -> the types of its `federation_progression = { perks = { { level
-- type } } }`
function R.federation_perks(fid)
    local f = obj("federation", fid)
    local out = {}
    for _, b in ipairs(world.blocks(f and world.path(f, "federation_progression", "perks"))) do
        local t = world.field(b, "type")
        if t then out[#out + 1] = t end
    end
    return out
end

-- R.galaxy_field(key) -> a field of the save's `galaxy = { ... }` (the galaxy setup)
function R.galaxy_field(key)
    local g = world.meta and world.meta.galaxy
    return type(g) == "table" and world.field(g, key) or nil
end

-- R.pop_factions(country) -> the pop faction ids of the country (`pop_factions` store, `country`)
function R.pop_factions(country)
    local out = {}
    for _, id in ipairs(world.all("pop_factions")) do
        if tonumber(world.field(obj("pop_factions", id), "country")) == country then out[#out + 1] = id end
    end
    return out
end

function R.pop_faction_field(fid, key)
    local f = obj("pop_factions", fid)
    return f and world.field(f, key)
end

-- R.tech_area(tech) -> its `area` (common/technology)
function R.tech_area(tech)
    local d = defs().get("common/technology", tech)
    return d and defs().field(d.block, "area") or nil
end

-- R.tech_alternatives(country, area) -> the technologies offered in that area (`tech_status = {
-- alternatives = { physics = { ... } society = { ... } engineering = { ... } } }`)
function R.tech_alternatives(country, area)
    local c = obj("country", country)
    local alt = c and world.path(c, "tech_status", "alternatives")
    local a = type(alt) == "table" and world.field(alt, area)
    return world.list(type(a) == "table" and a or nil)
end

-- R.tradition_category(tradition) -> the tradition category (common/tradition_categories) that lists
-- the tradition (its `traditions`, `adoption_bonus` or `finish_bonus`)
local trad_cat
function R.tradition_category(trad)
    if trad_cat == nil then
        trad_cat = {}
        for cname, d in pairs(defs().folder("common/tradition_categories")) do
            local l = defs().field(d.block, "traditions")
            for _, e in ipairs(type(l) == "table" and l or {}) do
                if e.text then trad_cat[e.text] = cname end
            end
            for _, k in ipairs({ "adoption_bonus", "finish_bonus" }) do
                local v = defs().field(d.block, k)
                if type(v) == "string" then trad_cat[v] = cname end
            end
        end
    end
    return trad_cat[trad]
end

-- R.player_events() -> the save's open player events (`player_event = { id event scope country }`)
function R.player_events()
    local out = {}
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "player_event" and e.value.text == nil then out[#out + 1] = e.value end
    end
    return out
end

-- R.leader_traits(leader) -> its `traits` values
function R.leader_traits(lid)
    local l = obj("leader", lid)
    local out = {}
    for _, t in ipairs(l and world.fields(l, "traits") or {}) do
        if type(t) == "string" then out[#out + 1] = t end
    end
    return out
end

-- R.species_traits(species) -> its `traits = { trait = "x" ... }`
function R.species_traits(sid)
    local s = obj("species", sid)
    local out = {}
    local t = s and world.field(s, "traits")
    for _, v in ipairs(type(t) == "table" and world.fields(t, "trait") or {}) do
        if type(v) == "string" then out[#out + 1] = v end
    end
    return out
end

function R.trait_field(trait, key)
    local d = trait and defs().get("common/traits", trait)
    return d and defs().field(d.block, key) or nil
end

-- R.ideal_planet_class(species) -> the ideal_planet_class of the first of its traits that has one
function R.ideal_planet_class(sid)
    for _, t in ipairs(R.species_traits(sid)) do
        local c = R.trait_field(t, "ideal_planet_class")
        if type(c) == "string" then return c end
    end
    return nil
end

-- R.planet_class_field(planet, key) -> a field of the planet's class (common/planet_classes)
function R.planet_class_field(pid, key)
    local p = obj("planet", pid)
    local class = p and world.field(p, "planet_class")
    local d = class and defs().get("common/planet_classes", class)
    return d and defs().field(d.block, key) or nil
end

-- R.orbital_station_class(planet) -> the ship_class of the planet's orbital station fleet
-- (`shipclass_orbital_station = <fleet>`), or nil without one
function R.orbital_station_class(pid)
    local f = ref(R.planet_field(pid, "shipclass_orbital_station"))
    if not (f and obj("fleet", f)) then return nil end
    return R.fleet_field(f, "ship_class") or "shipclass_military"
end

-- R.ai_strategy_count(country, type) -> the entries of that STRATEGIC_DATA_TYPES list in the
-- country's `ai = { strategy = { id target value type } }` (CAIStrategicBase::GetStrategy; the lists
-- engine.ai.strategy keeps: built again monthly for the types it ports, kept as saved for the others)
function R.ai_strategy_count(country, stype)
    local c = obj("country", country)
    local ai = c and world.field(c, "ai")
    local n = 0
    for _, s in ipairs(type(ai) == "table" and world.fields(ai, "strategy") or {}) do
        if type(s) == "table" and tonumber(world.field(s, "type")) == stype then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- spatial objects and sites

-- the ESpatialObjectType of a scope kind (a site's `location = { type id }`)
local SPATIAL = { ship = 0, ambient_object = 1, planet = 2, fleet = 3, megastructure = 6 }
-- R.site_at(kind, id) -> the archaeological site at the scope's spatial object
-- (CArchaeologicalSiteManager::GetSiteFromLocation 0x964de0; a system's: its star, the first of
-- its planets [I]; a starbase's: its station ship), or nil
function R.site_at(kind, id)
    if kind == "archaeological_site" then return obj("archaeological_site", id) and id or nil end
    if kind == "system" then
        local s = obj("system", id)
        kind, id = "planet", s and tonumber(world.fields(s, "planet")[1])
    elseif kind == "starbase" then
        local sb = obj("starbase", id)
        kind, id = "ship", sb and ref(world.field(sb, "station"))
    elseif kind == "colony" then
        kind, id = R.carrier_of("colony", id)
    end
    local t = kind and SPATIAL[kind]
    if t == nil or id == nil then return nil end
    for _, sid in ipairs(world.all("archaeological_site")) do
        local loc = world.field(obj("archaeological_site", sid), "location")
        if type(loc) == "table" and tonumber(world.field(loc, "type")) == t and tonumber(world.field(loc, "id")) == id then
            return sid
        end
    end
    return nil
end

return R
