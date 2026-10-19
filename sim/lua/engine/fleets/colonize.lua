-- engine/fleets/colonize.lua : a colony ship colonizing a planet, as the game does it (4.5.2 Linux;
-- the RE notes: scratchpad re4/SPEC_orders.md section 1, summarised in docs/windows/fleet.md):
--
--   colonize_planet_order = { planet progress [resource] [name] <base> }   (CColonizePlanetFleetOrder)
--     start   StartOrder (0x29ab7a0): a tick, then progress = 0
--     tick    TickOrder (0x29ab7c0): a civilian fleet of exactly one colonizer ship; in orbit of the
--             planet and idle: progress + 1 (the sub-order dropped); else its orbit sub-order
--     done    IsDone (0x29ac1f0): progress >= 10 (hard-coded: ten days in orbit)
--     finish  Finish (0x29aba20): the head ship's colonization_data { species designation
--             automation }; Colonize (0x29abcf0): the planet's owner and controller set, the colony
--             colonizing the species (colonizing_species), the planet's anomaly removed,
--             on_colonization_started (this = the planet, from = the ship); the ship killed
--   the colony then grows its colonists monthly (engine.pops grow_colonists) and is placed at
--   COLONY_POPS_REQUIRED (colonize.place_colony, CPlanet::PlaceColony 0x2a65190): the capital
--   buildings removed, the colony shelter added, colonizing_species cleared, colonize_date set,
--   on_colonized.
--
--   colonize.order(planet[, name]) -> the order block for orders.issue (CFleetColonizePlanetCommand)
--   colonize.check(fleet, planet) -> true | false, the game's failure key (IsValid / CanColonize)
--   colonize.place_colony(colony) -> true when placed
--   colonize.data(fleet) -> { species, designation, automation } | nil (the head ship's)
-- Not done: the planet's RandomizeName, the advisor's voice, the pending designation command
-- (CSetPendingColonyDesignationCommand), the habitability test's modifiers (the species' traits'
-- habitability only), the colony automation settings.

local world = require("engine.world")

local colonize = { stats = { landed = 0, placed = 0, refused = 0 } }
local S = colonize.stats

local NO_ID = 4294967295
local ONE = 100000

local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
local function ref(v)
    local n = tonumber(v)
    return n and n ~= NO_ID and n or nil
end

local function head_ship(f)
    return ref(world.list(world.field(f, "ships") or {})[1])
end

local function on_action(name, this, from)
    local ok, create = pcall(require, "engine.fleets.create")
    if ok and create.on_action then pcall(create.on_action, name, this, from) end
end

local function today()
    local ok, l = pcall(require, "engine.leaders")
    if ok and l.today_text then return l.today_text() end
    return world.meta and world.meta.date and unq(world.meta.date) or "2200.01.01"
end

-- the head ship's colonization_data (CFleet::GetColonizationData)
function colonize.data(f)
    local sid = head_ship(f)
    local s = sid and world.object("ships", sid)
    local d = s and world.field(s, "colonization_data")
    if type(d) ~= "table" then return nil end
    return { species = ref(world.field(d, "species")), designation = unq(world.field(d, "designation")),
             automation = world.field(d, "automation") }
end

local function surveyed(country, pid)
    local ok, survey = pcall(require, "engine.fleets.survey")
    if not ok then return true end
    local ok2, r = pcall(survey.has_surveyed, country, 0, pid)
    return ok2 and r
end

-- a species' habitability on a planet (as the planet view's colonize window shows it): its traits'
-- `<class>_habitability` modifiers, aquatic +0.2 on a wet climate's class and -0.2 elsewhere,
-- clamped to 0..1 [I: the generic habitability modifiers not added]
local trait_hab = {}
function colonize.habitability(species, pid)
    local p = world.object("planet", pid)
    local s = species and world.object("species", species)
    local class = p and unq(world.field(p, "planet_class"))
    if not s or not class then return 0 end
    local defs = require("engine.defs")
    local okc, create = pcall(require, "engine.fleets.create")
    local hab, aquatic = 0, false
    for _, t in ipairs(world.fields(s, "traits")) do
        for _, name in ipairs(type(t) == "table" and world.fields(t, "trait") or { t }) do
            name = unq(name)
            local key = name .. "/" .. class
            if trait_hab[key] == nil then
                local d = defs.get("common/traits", name)
                local m = d and defs.field(d.block, "modifier")
                local v = type(m) == "table" and defs.field(m, class .. "_habitability")
                local n = tonumber(v)
                if not n and type(v) == "string" and okc and create.number then n = create.number(v, d.file) end
                trait_hab[key] = n or 0
            end
            hab = hab + trait_hab[key]
            aquatic = aquatic or name == "trait_aquatic"
        end
    end
    if aquatic then
        local d = defs.get("common/planet_classes", class)
        local climate = d and unq(defs.field(d.block, "climate"))
        hab = hab + (climate == "wet" and 0.2 or -0.2)
    end
    return math.max(0, math.min(1, hab))
end

-- CFleetColonizePlanetCommand::IsValid and CPlanet::CanColonize (0x2a68860), the keys the game shows
-- [V the keys; I the order of the tests]
function colonize.check(fid, pid)
    local f = world.object("fleet", fid)
    local p = world.object("planet", pid)
    if not f or not p then return false, "FLEETORDER_INVALID" end
    if world.path(f, "properties", "station") == "yes" then return false, "FLEETORDER_INVALID" end
    if unq(world.field(f, "ship_class")) ~= "shipclass_colonizer" then return false, "FLEETORDER_INVALID" end
    local country = world.fleet_owner and world.fleet_owner[fid]
    if ref(world.field(p, "owner")) then return false, "COLONIZABLE_HAS_OWNER" end
    local okst, st = pcall(require, "engine.fleets.stations")
    if okst and st.colonizable and not st.colonizable(pid) then return false, "COLONIZABLE_NEVER" end
    if world.field(p, "anomaly") ~= nil then return false, "COLONIZABLE_ANOMALY" end
    if country and not surveyed(country, pid) then return false, "COLONIZABLE_UNSURVEYED" end
    -- inside the country's borders [V: the game's tooltip "Can only colonize planets inside our
    -- borders." on an unclaimed system's planet]
    local sys = tonumber(world.path(p, "coordinate", "origin"))
    local so = sys and world.system_owner and world.system_owner[sys]
    if so ~= country then
        return false, so and "COLONIZABLE_INSIDE_OTHER_BORDERS" or "COLONIZABLE_INSIDE_BORDERS"
    end
    local d = colonize.data(f)
    if not d or not d.species or colonize.habitability(d.species, pid) <= 0 then
        return false, "HABITABILTIY_TOO_LOW"
    end
    return true
end

-- the order block (CColonizePlanetFleetOrder(planet, name)): progress 0, the name when given
function colonize.order(pid, name)
    local b = {}
    world.append(b, "planet", pid)
    world.append(b, "progress", 0)
    if name and name ~= "" then
        local n = {}
        world.append(n, "key", name, true)
        world.append(b, "name", n)
    end
    return { { key = { text = "colonize_planet_order" }, op = "=", value = b } }
end

local function progress(o) return math.floor((tonumber(world.field(o.block, "progress")) or 0) * ONE + 0.5) end
local function planet_of(o) return ref(world.field(o.block, "planet")) end

-- Colonize (0x29abcf0): false when the species is missing, the planet another's, or a colony is
-- under colonization there
local function do_colonize(pid, country, data, fid, sid)
    if not data or not data.species then return false end
    local p = world.object("planet", pid)
    local owner = p and ref(world.field(p, "owner"))
    if not p or (owner and owner ~= country) then return false end
    local cid = world.planet_colony[pid]
    local c = cid and world.object("colony", cid)
    if c and ref(world.field(c, "colonizing_species")) then return false end
    require("engine.script.objects_colony")
    local countries = require("engine.script.objects_countries")
    local had_date = world.field(p, "colonize_date") ~= nil
    countries.set_planet_owner(pid, country)
    countries.set_planet_controller(pid, country)
    -- (colonize_date is the placement's, CPlanet::PlaceColony: set_planet_owner's own taken back)
    if not had_date then
        local e = world.entry(p, "colonize_date")
        if e then world.remove_entry(p, e) end
    end
    cid = world.planet_colony[pid]
    c = cid and world.object("colony", cid)
    if c then
        world.set(c, "colonizing_species", data.species)
        if data.designation then world.set(c, "final_designation", data.designation, true) end
    end
    local a = world.entry(p, "anomaly")
    if a then world.remove_entry(p, a) end
    on_action("on_colonization_started", { "planet", pid }, sid and { "ship", sid } or nil)
    return true
end

local order = {}
colonize.order_type = order

function order.tick(o, fid, f, orders)
    local ships = world.list(world.field(f, "ships") or {})
    if world.path(f, "properties", "civilian") ~= "yes" or #ships ~= 1 then return end
    if unq(world.field(f, "ship_class")) ~= "shipclass_colonizer" then return end
    local pid = planet_of(o)
    if not pid then return end
    if orders.in_orbit_of(fid, f, pid) then
        orders.clear_sub_order(o)
        world.set(o.block, "progress", (progress(o) + ONE) / ONE)
        return
    end
    orders.tick_orbit_sub_order(o, fid, f, pid)
end

function order.start(o, fid, f, orders)
    order.tick(o, fid, f, orders)
    world.set(o.block, "progress", 0)
end

function order.is_done(o)
    return progress(o) >= 10 * ONE
end

function order.finish(o, fid, f, orders)
    local pid = planet_of(o)
    if not pid or #world.list(world.field(f, "ships") or {}) == 0 or not orders.in_orbit_of(fid, f, pid) then
        S.refused = S.refused + 1
        return
    end
    local country = world.fleet_owner and world.fleet_owner[fid]
    local sid = head_ship(f)
    if do_colonize(pid, country, colonize.data(f), fid, sid) then
        S.landed = S.landed + 1
        local name = world.path(o.block, "name", "key")
        if name then
            local p = world.object("planet", pid)
            local n = {}
            world.append(n, "key", unq(name), true)
            local e = world.entry(p, "name")
            if e then world.remove_entry(p, e) end
            world.append(p, "name", n)
        end
        require("engine.fleets.destroy").ship(sid)
    else
        S.refused = S.refused + 1
    end
end

-- CPlanet::PlaceColony (0x2a65190) and CColony::Initialize (0x287b440): the colony established

function colonize.place_colony(cid)
    local c = world.object("colony", cid)
    local pid = world.colony_planet and world.colony_planet[cid]
    local p = pid and world.object("planet", pid)
    if not c or not p then return false end
    local country = ref(world.field(p, "owner"))
    -- RemoveCapitalBuildings: every building type with `capital = yes`, each of them there
    local okc, colony = pcall(require, "engine.script.objects_colony")
    local remove = require("engine.systems").effects.remove_building
    local okd, defs = pcall(require, "engine.defs")
    local objects = require("engine.script.objects")
    for _, d in ipairs(okd and objects.ordered("common/buildings") or {}) do
        if defs.field(d[2].block, "capital") == "yes" then
            for _ = 1, 8 do
                local okr, r = pcall(remove, { kind = "colony", id = cid, building = d[1] })
                if not okr or not r then break end
            end
        end
    end
    -- the colony shelter (CColonyShelterDatabase::GetShelterForPlanetClass [I: the plain shelter])
    if okc and colony.add_building then pcall(colony.add_building, cid, "building_colony_shelter") end
    local e = world.entry(c, "colonizing_species")
    if e then world.remove_entry(c, e) end
    world.set(p, "colonize_date", today(), true)
    on_action("on_colonized", { "planet", pid }, country and { "country", country } or nil)
    S.placed = S.placed + 1
    return true
end

function colonize.report()
    return string.format("colonize: %d landed, %d placed, %d refused", S.landed, S.placed, S.refused)
end

return colonize
