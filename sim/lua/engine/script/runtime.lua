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

-- R.colony_of(kind, id) -> colony id of a scope (NScriptUtil::GetColonyFromScope: a planet's, a pop
-- group's, a colony itself), or nil
function R.colony_of(kind, id)
    if kind == "colony" then
        return obj("colony", id) and id or nil
    elseif kind == "planet" then
        return world.planet_colony[id]
    elseif kind == "pop_group" then
        local g = obj("pop_group", id)
        local col = g and tonumber(world.field(g, "planet"))
        return col and obj("colony", col) and col or nil
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

return R
