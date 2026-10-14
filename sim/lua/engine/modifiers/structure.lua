-- engine/modifiers/structure.lua : the game's modifier nodes of a world (a save) and who reads whom.
-- Every object with a modifier node (EModifierNodeCategory, docs/modifiers.md) is a node (category,
-- owner: the object's id in the save), and its parents are the nodes its CalculateModifier adds with
-- AddModifierNode(parent, mult, mask): a planet reads its country's node, a ship its fleet's, a pop
-- group its colony's. stellar.graph.nodes links them; engine.modifiers gives each node its own parts.
--
-- The rules are the game's own edges (_ChildNodes of every node in the 2211.07.01 snapshot, 32,798
-- edges; sim/tools/modifier_structure.lua compares them):
--   Country   <- StarbaseCountry of each starbase it owns; Federation (its leader only)
--   Planet    <- its system's GalacticObjectCosmicStorm, -PsionicAura; for a country that reads its
--                systems (see S:reads_systems): -Leader, StarbaseSystem of every starbase there,
--                Sector (not the sector's capital planet); its country (owner, else the controller
--                of its system; two masks: colonized or not); CountryRelayNetwork of its system's
--                owner in a system with access to the relay network; StarbasePlanet of the system's
--                starbase it hosts (the planet the station orbits); MegaStructureSystem of each
--                megastructure in the system (some types are read by the fleets instead: not modelled)
--   Colony    <- Planet; its system's GalacticObjectBuilding
--   PopGroup  <- Colony; Country (Habitability mask); a killed one nothing
--   Fleet     <- its system's GalacticObjectTimed, -CosmicStorm, -PsionicAura, and as a planet
--                -Leader, StarbaseSystem, Sector; its country, or for a starbase's own fleet the
--                Starbase; Orbital of the starbase it is docked at
--   Ship      <- Fleet; a starbase's defense platforms (its fleet's ships but the station) its
--                StarbaseDefensePlatform
--   Army      <- Country; Colony; the LeaderSkill of the general of its fleet
--   Leader, MegaStructure <- Country; SpyNetwork <- Country, the LeaderSkill of its leader
--   Starbase  <- Country; StarbaseExternal (its own); its system's GalacticObjectLeader, Sector,
--                CountryRelayNetwork
-- A link's filter is the child node's category filter (CModifier::_Categories, M.FILTER) for the
-- calls that pass no mask, or the mask the captures show for the five that do; every multiplier is 1.
--
--   local structure = require("engine.modifiers.structure")
--   local st = structure.new(world, defs)
--   for _, n in ipairs(st:nodes()) do ... st:parents(n.category, n.owner) ... end

local M = {}

local NONE = 4294967295

-- each category's own category filter (_Categories), as the captures show it on every node
M.FILTER = {
    Country = 1354747902, CountryRelayNetwork = 1354747902, Federation = 4194304, GalacticCommunity = 536870912,
    Planet = 1074432514, Colony = 1074430466, PopGroup = 688130, Fleet = 1342882558, Ship = 268484732,
    Army = 524800, Leader = 525312, LeaderSkill = -1, Sector = 1077926654, SpyNetwork = 8912896,
    GalacticObjectTimed = 1076878078, GalacticObjectLeader = 1077926654, GalacticObjectCosmicStorm = 1077926654,
    GalacticObjectPsionicAura = 1077926654, GalacticObjectPopJob = 1077926654, GalacticObjectBuilding = 1077926654,
    Starbase = 1345241726, StarbaseExternal = 1076806270, StarbaseCountry = -1, StarbaseSystem = 1074317566,
    StarbasePlanet = 1074449022, StarbaseDefensePlatform = 540796, Orbital = 1074282750,
    MegaStructure = 606588, MegaStructureSystem = 1074317566,
    -- a megastructure's Orbital node (the game's category Orbital, as a starbase's; told apart here, as
    -- both have the same owner ids: in a capture, by its filter)
    OrbitalMegaStructure = -1,
}

-- the links whose call passes a mask: the part's filter as the captures show it
M.MASKED = {
    ["Fleet<Sector"] = 1074447102,
    ["PopGroup<Country"] = 131072,
    ["Ship<StarbaseDefensePlatform"] = 49276,
    ["Starbase<Sector"] = 1076789762,
}
-- a planet reads its country with one mask when it is colonized, another when not
M.PLANET_COUNTRY = { colonized = 1074300930, uncolonized = 557056 }

-- M.MASKED by child category, then parent category (st:parents reads it for every link)
local MASKED_BY = {}
for k, v in pairs(M.MASKED) do
    local child, parent = k:match("^(.-)<(.*)$")
    MASKED_BY[child] = MASKED_BY[child] or {}
    MASKED_BY[child][parent] = v
end

local function unq(s)
    if type(s) ~= "string" then
        return s
    end
    return (s:gsub('^"(.*)"$', "%1"))
end

local function id_of(v)
    v = tonumber(v)
    if v == nil or v == NONE or v < 0 then
        return nil
    end
    return v
end

local S = {}
S.__index = S

-- structure.new(world, defs) -> st: the relations indexed (defs: engine.defs, for the country types)
function M.new(world, defs)
    local self = setmetatable({ world = world, defs = defs or require("engine.defs") }, S)
    self:index()
    return self
end

local function list_ids(w, obj, key)
    local out = {}
    local b = w.field(obj, key)
    if type(b) == "table" then
        for _, e in ipairs(b) do
            local id = e.text and id_of(unq(e.text))
            if id then
                out[#out + 1] = id
            end
        end
    end
    return out
end

-- the bare blocks of a list block
local function blocks_of(b)
    local out = {}
    if type(b) == "table" then
        for _, e in ipairs(b) do
            if not e.op and e.text == nil then
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- the system an object is in (its coordinate's origin)
local function system_of(w, obj)
    local coord = obj and w.field(obj, "coordinate")
    return type(coord) == "table" and id_of(w.field(coord, "origin")) or nil
end

local function push(t, k, v)
    local l = t[k]
    if l == nil then
        l = {}
        t[k] = l
    end
    l[#l + 1] = v
end

function S:index()
    local w = self.world
    -- a fleet's owner (the country whose fleets_manager owns it)
    self.fleet_owner = {}
    for _, cid in ipairs(w.all("country")) do
        local fm = w.field(w.object("country", cid), "fleets_manager")
        for _, b in ipairs(blocks_of(type(fm) == "table" and w.field(fm, "owned_fleets") or nil)) do
            local f = id_of(w.field(b, "fleet"))
            if f then
                self.fleet_owner[f] = cid
            end
        end
    end
    -- colonies: their planet
    self.planet_of_colony = {}
    for _, pid in ipairs(w.all("planet")) do
        local c = id_of(w.field(w.object("planet", pid), "colony"))
        if c then
            self.planet_of_colony[c] = pid
        end
    end
    -- sectors: their systems, their capital's planet
    self.sector_of_system, self.sector_capital = {}, {}
    for _, sid in ipairs(w.all("sectors")) do
        local o = w.object("sectors", sid)
        for _, sys in ipairs(list_ids(w, o, "systems")) do
            self.sector_of_system[sys] = sid
        end
        local cap = id_of(w.field(o, "local_capital"))
        if cap and self.planet_of_colony[cap] then
            self.sector_capital[self.planet_of_colony[cap]] = sid
        end
    end
    -- systems: their starbases, relay network access, planets, megastructures
    self.starbases_of_system, self.system_of_starbase, self.relay_system = {}, {}, {}
    for _, gid in ipairs(w.all("galactic_object")) do
        local o = w.object("galactic_object", gid)
        for _, sb in ipairs(list_ids(w, o, "starbases")) do
            push(self.starbases_of_system, gid, sb)
            self.system_of_starbase[sb] = gid
        end
        if w.field(o, "has_access_to_relay_network") == "yes" then
            self.relay_system[gid] = true
        end
    end
    self.megastructures_of_system = {}
    for _, mid in ipairs(w.all("megastructures")) do
        local sys = system_of(w, w.object("megastructures", mid))
        if sys then
            push(self.megastructures_of_system, sys, mid)
        end
    end
    -- starbases: their station, its fleet, the owner (the fleet's)
    self.starbase_owner, self.starbase_of_fleet, self.station_of = {}, {}, {}
    for _, sb in ipairs(w.all("starbases")) do
        local station = id_of(w.field(w.object("starbases", sb), "station"))
        local ship = station and w.object("ships", station)
        local fleet = ship and id_of(w.field(ship, "fleet"))
        self.station_of[sb] = station
        if fleet then
            self.starbase_of_fleet[fleet] = sb
            self.starbase_owner[sb] = self.fleet_owner[fleet]
        end
    end
    -- the planet a starbase is at: the one its station's fleet orbits
    self.starbase_at_planet = {}
    for fleet, sb in pairs(self.starbase_of_fleet) do
        local mm = self:fleet_movement(fleet)
        local orbit = mm and w.field(mm, "orbit")
        local at = type(orbit) == "table" and w.field(orbit, "orbitable")
        local pid = type(at) == "table" and id_of(w.field(at, "planet"))
        if pid then
            push(self.starbase_at_planet, pid, sb)
        end
    end
    self.starbases_of = {}
    for sb, owner in pairs(self.starbase_owner) do
        push(self.starbases_of, owner, sb)
    end
    for _, l in pairs(self.starbases_of) do
        table.sort(l)
    end
    -- a system's owner: its first starbase's owner
    self.system_owner = {}
    for sys, l in pairs(self.starbases_of_system) do
        self.system_owner[sys] = self.starbase_owner[l[1]]
    end
    -- federations: their leader
    self.federation_led = {}
    for _, fid in ipairs(w.all("federation")) do
        local leader = id_of(w.field(w.object("federation", fid), "leader"))
        if leader then
            self.federation_led[leader] = fid
        end
    end
    -- the general of each fleet: the leader of an army embarked in it
    self.fleet_general = {}
    for _, aid in ipairs(w.all("army")) do
        local a = w.object("army", aid)
        local leader, ship = id_of(w.field(a, "leader")), id_of(w.field(a, "ship"))
        local s = ship and w.object("ships", ship)
        local fleet = s and id_of(w.field(s, "fleet"))
        if leader and fleet then
            self.fleet_general[fleet] = leader
        end
    end
    self.reads_cache = {}
end

-- whether a country's objects read their system's leader, starbase and sector nodes: not for the
-- country types without a government (space critters, caravaneer fleets, factions) or enclaves
function S:reads_systems(country)
    if country == nil then
        return true
    end
    local r = self.reads_cache[country]
    if r == nil then
        local o = self.world.object("country", country)
        local ty = o and unq(self.world.field(o, "type"))
        local d = ty and self.defs.get("common/country_types", ty)
        r = true
        if d then
            local f = self.defs.field
            if f(d.block, "government") == "no" or f(d.block, "is_enclave") == "yes" then
                r = false
            end
        end
        self.reads_cache[country] = r
    end
    return r
end

function S:fleet_movement(fid)
    local mm = self.world.field(self.world.object("fleet", fid), "movement_manager")
    return type(mm) == "table" and mm or nil
end

-- the nodes of the world: { { category, owner } } (the categories the game registers for each object)
function S:nodes()
    local w = self.world
    local out = {}
    local function add(category, store)
        for _, id in ipairs(w.all(store)) do
            out[#out + 1] = { category = category, owner = id }
        end
    end
    add("Country", "country")
    add("CountryRelayNetwork", "country")
    add("Planet", "planet")
    add("Colony", "colony")
    add("PopGroup", "pop_groups")
    add("Fleet", "fleet")
    add("Ship", "ships")
    add("Army", "army")
    add("Leader", "leaders")
    add("LeaderSkill", "leaders")
    add("Sector", "sectors")
    add("SpyNetwork", "spy_networks")
    add("Federation", "federation")
    out[#out + 1] = { category = "GalacticCommunity", owner = 0 }
    for _, c in ipairs({ "GalacticObjectTimed", "GalacticObjectLeader", "GalacticObjectCosmicStorm",
        "GalacticObjectPsionicAura", "GalacticObjectPopJob", "GalacticObjectBuilding" }) do
        add(c, "galactic_object")
    end
    for _, c in ipairs({ "Starbase", "StarbaseExternal", "StarbaseCountry", "StarbaseSystem", "StarbasePlanet",
        "StarbaseDefensePlatform", "Orbital" }) do
        add(c, "starbases")
    end
    add("MegaStructure", "megastructures")
    add("MegaStructureSystem", "megastructures")
    add("OrbitalMegaStructure", "megastructures")
    return out
end

-- st:parents(category, owner) -> { { category, owner, mult, filter } }: the node's parents
function S:parents(category, owner)
    local w = self.world
    local out = {}
    local masked = MASKED_BY[category]
    local function link(pcat, powner, filter)
        if powner ~= nil then
            out[#out + 1] = { category = pcat, owner = powner, mult = 100000,
                filter = filter or (masked and masked[pcat]) or M.FILTER[category] }
        end
    end
    -- the system nodes a planet or fleet reads
    local function system_nodes(sys, country, timed)
        if sys == nil then
            return
        end
        if timed then
            link("GalacticObjectTimed", sys)
        end
        link("GalacticObjectCosmicStorm", sys)
        link("GalacticObjectPsionicAura", sys)
        if self:reads_systems(country) then
            link("GalacticObjectLeader", sys)
            for _, sb in ipairs(self.starbases_of_system[sys] or {}) do
                link("StarbaseSystem", sb)
            end
            return true
        end
    end
    if category == "Country" then
        for _, sb in ipairs(self.starbases_of[owner] or {}) do
            link("StarbaseCountry", sb)
        end
        link("Federation", self.federation_led[owner])
    elseif category == "Planet" then
        local p = w.object("planet", owner)
        local sys = system_of(w, p)
        local colonized = id_of(w.field(p, "colony")) ~= nil
        local country = id_of(w.field(p, "owner")) or id_of(w.field(p, "controller"))
        if system_nodes(sys, country, false) and self.sector_capital[owner] == nil then
            link("Sector", self.sector_of_system[sys])
        end
        if country then
            link("Country", country, colonized and M.PLANET_COUNTRY.colonized or M.PLANET_COUNTRY.uncolonized)
        end
        if sys and self.relay_system[sys] then
            link("CountryRelayNetwork", self.system_owner[sys])
        end
        for _, sb in ipairs(self.starbase_at_planet[owner] or {}) do
            link("StarbasePlanet", sb)
        end
        for _, mid in ipairs(sys and self.megastructures_of_system[sys] or {}) do
            link("MegaStructureSystem", mid)
        end
    elseif category == "Colony" then
        local pid = self.planet_of_colony[owner]
        link("Planet", pid)
        link("GalacticObjectBuilding", pid and system_of(w, w.object("planet", pid)))
    elseif category == "PopGroup" then
        local g = w.object("pop_groups", owner)
        -- a killed pop group keeps its node, and reads nothing
        if w.field(g, "killed") == "yes" then
            return out
        end
        local colony = id_of(w.field(g, "planet"))
        link("Colony", colony)
        local pid = colony and self.planet_of_colony[colony]
        link("Country", pid and id_of(w.field(w.object("planet", pid), "owner")))
    elseif category == "Fleet" then
        local mm = self:fleet_movement(owner)
        local sys = mm and system_of(w, mm)
        local country = self.fleet_owner[owner]
        local starbase = self.starbase_of_fleet[owner]
        if system_nodes(sys, country, true) then
            link("Sector", self.sector_of_system[sys])
        end
        if starbase then
            link("Starbase", starbase)
        else
            link("Country", country)
        end
        local orbit = mm and w.field(mm, "orbit")
        local at = type(orbit) == "table" and w.field(orbit, "orbitable")
        link("Orbital", type(at) == "table" and id_of(w.field(at, "starbase")) or nil)
    elseif category == "Ship" then
        local s = w.object("ships", owner)
        local fleet = id_of(w.field(s, "fleet"))
        link("Fleet", fleet)
        local sb = fleet and self.starbase_of_fleet[fleet]
        if sb and self.station_of[sb] ~= owner then
            link("StarbaseDefensePlatform", sb)
        end
    elseif category == "Army" then
        local a = w.object("army", owner)
        link("Country", id_of(w.field(a, "owner")))
        link("Colony", id_of(w.field(a, "colony")))
        local ship = id_of(w.field(a, "ship"))
        local s = ship and w.object("ships", ship)
        local fleet = s and id_of(w.field(s, "fleet"))
        link("LeaderSkill", fleet and self.fleet_general[fleet])
    elseif category == "Leader" then
        link("Country", id_of(w.field(w.object("leaders", owner), "country")))
    elseif category == "SpyNetwork" then
        local o = w.object("spy_networks", owner)
        link("Country", id_of(w.field(o, "owner")))
        link("LeaderSkill", id_of(w.field(o, "leader")))
    elseif category == "Starbase" then
        link("Country", self.starbase_owner[owner])
        link("StarbaseExternal", owner)
        local sys = self.system_of_starbase[owner]
        if sys then
            link("GalacticObjectLeader", sys)
            link("Sector", self.sector_of_system[sys])
            if self.relay_system[sys] then
                link("CountryRelayNetwork", self.system_owner[sys])
            end
        end
    elseif category == "MegaStructure" then
        link("Country", id_of(w.field(w.object("megastructures", owner), "owner")))
    end
    return out
end

return M
