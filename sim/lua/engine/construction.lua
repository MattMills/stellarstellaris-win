-- engine/construction.lua : construction queues, the way the game advances them each day (GOG
-- 4.5.2, CConstructionManager::DailyUpdate -> CConstructionQueueManager::DailyUpdate, per queue
-- CConstructionQueue::DailyUpdate, then CConstructionQueueItemManager::DailyUpdate finishing what is
-- done), on the save's stores:
--
--   construction.queue_mgr.queues: { items = { ids } owner location = { type id } simultaneous type
--                                    disabled }
--   construction.item_mgr.items:   { queue paying_country progress progress_needed resources
--                                    buildable_<kind> = { ... } }
--
-- Each day, a queue that is not disabled advances its first `simultaneous` items, from the last of
-- them to the first: progress += the buildable's speed (CBuildable*::CalcProgressionSpeed); an item
-- that reaches progress_needed is done: taken out of its queue and finished (OnFinished).
--
-- Speeds, from the modifier node of the colony the item is on, or of the starbase:
--   district  1 + planet_building_build_speed_mult + planet_<district>_build_speed_mult
--             (CDistrictType::CalcBuildSpeed)
--   zone      1 + planet_building_build_speed_mult + planet_<zone>_build_speed_mult (CZoneType)
--   building  1 + planet_building_build_speed_mult + planet_<building>_build_speed_mult (CBuildingType)
--   army      1 + planet_army_build_speed_mult (CBuildableArmy::CalcProgressionSpeed 0x26d0180 Linux)
--   ship      1 + starbase_shipyard_artificial_build_speed_mult + starbase_shipyard_build_speed_mult
--             (+ starbase_defensive_war_ship_build_speed_mult in a defensive war)
--             + shipsize_<size>_build_speed_mult, of the orbitable's economic modifiers (the
--             starbase's node) (CBuildableShipBase<CBuildableShip>::CalcProgressionSpeed 0x21a4e40)
--   starbase upgrade  1 + starbase_upgrade_speed_mult (CBuildableStarbaseUpgrade 0x21b5700)
--   starbase module   1 + starbase_module_build_speed_mult (CBuildableStarbaseModule 0x21b3d00)
--   starbase building 1 + starbase_building_build_speed_mult (CBuildableStarbaseBuilding 0x21b2b30)
-- Defense platforms, decisions, deposit blockers: not modelled yet (their items stay, counted).
--
-- Finished (OnFinished):
--   district  the colony's district of that type gains a level; two draws, on_district_complete
--   zone      a zone created in its district's slot; two draws, on_zone_complete
--   building  created and added to its zone; two draws, on_building_complete (an upgrade: the
--             building's type, on_building_upgraded)
--   ship      CBuildableShip::OnFinished (0x219a660 Linux): the ship from its design at the
--             orbitable, in a fleet of the owner there it can merge with or a new fleet in orbit
--             (engine.fleets.create.around_orbital), then FireOnShipBuiltOnAction: two draws,
--             on_ship_built
--   army      CBuildableArmy::OnFinished (0x26cfac0 Linux): CGameState::CreateNewArmy (the army
--             name list's sequential name), on_army_recruited (two draws), NPlanetArmies::AddOrEmbark:
--             a defensive army stays on the colony, any other goes to orbit in a transport
--             (CArmy::MoveToOrbit: the country's latest transport design, a new transport fleet in
--             orbit of the planet), then one draw for CArmyType::OnBuilt
--   starbase upgrade  CStarbase::SetLevel: the level, the station's size (the level's ship_size)
--             in its design, then CShip::FireOnShipUpgradedAction: one draw, on_ship_upgraded
--   starbase module / building  CStarbase::SetModule / SetBuilding in the slot; a module's
--             on_finished effect after one draw
-- New ids: the next index past the highest in the store (and the free slots first for ships,
-- fleets and armies: engine.fleets.create.allocate), generation 0.
-- Not modelled yet: the starbase's rebuild of its station design (CStarbase::UpgradeStationDesign:
-- the utilities and components regenerated) and RecalcCachedModifiers, the refunds of aborted
-- items, colony ships' colonies (CGameState::CreateColonyInsideShip), arkships, the messages.

local world = require("engine.world")
local live = require("engine.store.live")   -- the store's copy of what exploration reads (docs/data_layer.md)

local construction = {
    stats = { advanced = 0, finished = 0, not_modelled = {}, finish_not_modelled = {}, draws = 0,
              on_actions = 0, on_action_errors = 0, ships = 0, armies = 0, starbase_items = 0 },
    finished = {}, -- { kind, planet, date, ship, fleet, army, starbase }
    failures = {}, -- what could not be finished, and why
}

local QUEUES, ITEMS = "construction.queue_mgr.queues", "construction.item_mgr.items"
local NO_ID = 4294967295

-- STELLAR_SHIPBUILD=off: the kinds ported with the ships left out (ships, starbase items, the
-- armies' creation, the planet items' draws and on_actions), as before them (a check's baseline)
local OFF = os.getenv("STELLAR_SHIPBUILD") == "off"
construction.OFF = OFF

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers(kind, id) or {}
end

-- the colony modifier node of an item (a buildable's `planet` is a colony id in 4.5, like a pop
-- group's and a capital)
local function colony_mods(colony)
    return modifiers("colony", colony or -1)
end

local function buildable(item)
    for _, e in ipairs(item) do
        if e.op and e.key and e.value.text == nil and e.key.text:sub(1, 10) == "buildable_" then
            return e.key.text:sub(11), e.value
        end
    end
end

local function create()
    return require("engine.fleets.create")
end

-- a ship buildable's orbitable (orbitable = { starbase = id } or { planet = id }): kind, id
local function orbitable(b)
    local o = world.field(b, "orbitable")
    if type(o) ~= "table" then
        return nil
    end
    for _, k in ipairs({ "starbase", "planet" }) do
        local id = tonumber(world.field(o, k))
        if id and id ~= NO_ID then
            return k, id
        end
    end
    return nil
end

local function ship_design(b)
    local sdi = world.field(b, "ship_design_implementation")
    return type(sdi) == "table" and tonumber(world.field(sdi, "design")) or nil,
        type(sdi) == "table" and tonumber(world.field(sdi, "growth_stage")) or 0
end

-- the owner of a starbase: its station's fleet's
local function starbase_owner(sb)
    local s = world.object("starbases", sb)
    local st = s and tonumber(world.field(s, "station"))
    local ship = st and world.object("ships", st)
    local fleet = ship and tonumber(world.field(ship, "fleet"))
    return fleet and world.fleet_owner[fleet] or nil
end
construction.starbase_owner = starbase_owner

-- the orbitable's economic modifiers (CFleetOrbitalSlotHandle::GetEconomicModifiers): the
-- starbase's node, or the colony of a planet
local function orbitable_mods(kind, id)
    if kind == "starbase" then
        return modifiers("starbase", id)
    end
    local colony = world.planet_colony and world.planet_colony[id]
    return colony and colony_mods(colony) or {}
end

local function in_defensive_war(country)
    -- CCountry::IsInDefensiveWar [I]: a war whose defenders list the country
    for _, wid in ipairs(world.all("war")) do
        local w = world.object("war", wid)
        for _, d in ipairs(world.blocks(world.field(w, "defenders"))) do
            if tonumber(world.field(d, "country")) == country then
                return true
            end
        end
    end
    return false
end

-- construction.speed(item) -> the daily progress, or nil (a kind not modelled)
function construction.speed(item)
    local kind, b = buildable(item)
    if not kind then
        return nil
    end
    local planet = tonumber(world.field(b, "planet"))
    if kind == "district" or kind == "zone" or kind == "planet_building" or kind == "planet_upgrade_building" then
        local key = world.field(b, (kind == "planet_building" or kind == "planet_upgrade_building") and "building" or kind)
        local M = colony_mods(planet)
        return 1 + (M.planet_building_build_speed_mult or 0) + (M["planet_" .. tostring(key) .. "_build_speed_mult"] or 0), kind
    elseif kind == "army" then
        local M = colony_mods(planet)
        return 1 + (M.planet_army_build_speed_mult or 0), kind
    elseif OFF then
        return nil, kind
    elseif kind == "ship" then
        local okind, oid = orbitable(b)
        local did, stage = ship_design(b)
        local info = did and create().design_info(did, stage)
        if not okind or not info then
            return nil, kind
        end
        local M = orbitable_mods(okind, oid)
        local sb = info.size_block
        local fauna = sb and require("engine.defs").field(sb, "is_space_fauna") == "yes"
        local speed = 1 + (M[fauna and "starbase_shipyard_space_fauna_build_speed_mult" or "starbase_shipyard_artificial_build_speed_mult"] or 0)
            + (M.starbase_shipyard_build_speed_mult or 0)
            + (M["shipsize_" .. tostring(info.size) .. "_build_speed_mult"] or 0)
        local owner = okind == "starbase" and starbase_owner(oid) or nil
        if owner and (M.starbase_defensive_war_ship_build_speed_mult or 0) ~= 0 and in_defensive_war(owner) then
            speed = speed + M.starbase_defensive_war_ship_build_speed_mult
        end
        return speed, kind
    elseif kind == "starbase_upgrade" or kind == "starbase_module" or kind == "starbase_building" then
        local sb = tonumber(world.field(b, "starbase"))
        local M = sb and modifiers("starbase", sb) or {}
        local key = ({ starbase_upgrade = "starbase_upgrade_speed_mult", starbase_module = "starbase_module_build_speed_mult",
                       starbase_building = "starbase_building_build_speed_mult" })[kind]
        return 1 + (M[key] or 0), kind
    end
    return nil, kind
end

-- the next id of a store: one index past the highest in use (generation 0)
local function next_id(store)
    local max = -1
    for _, id in ipairs(world.all(store)) do
        local index = id % 16777216
        if index > max then
            max = index
        end
    end
    return max + 1
end

local function draw()
    construction.stats.draws = construction.stats.draws + 1
    return RUST.rand()
end

-- an on_action through the script layer: this, from as { kind, id }
local function on_action(name, this, from)
    construction.stats.on_actions = construction.stats.on_actions + 1
    local ok = pcall(function()
        local events = package.loaded["simscript.events"] or require("simscript.events")
        local eval = package.loaded["simscript.eval"] or require("simscript.eval")
        events.on_action(name, eval.S(this[1], this[2]), from and eval.new_ctx(eval.S(from[1], from[2])) or nil)
    end)
    if not ok then
        construction.stats.on_action_errors = construction.stats.on_action_errors + 1
    end
end

-- the colony's planet, the scope of the planets' on_actions ("This = Colony")
local function colony_scope(colony)
    local p = world.colony_planet and world.colony_planet[colony]
    return { "planet", p or colony }
end

-- the two event scopes and the on_action of a planet item's completion (CBuildableDistrict::
-- OnFinished 0x217e940 Linux: two GetIntegerForMacro, then the on_action; the headless profile:
-- two draws a district, two a zone)
local function planet_done(name, colony)
    if OFF then
        return
    end
    draw()
    draw()
    on_action(name, colony_scope(colony))
end

-- ---------------------------------------------------------------------------------------------
-- armies

local function unq(v)
    if type(v) == "string" then
        return (v:gsub('^"(.*)"$', "%1"))
    end
    return v
end

-- the army type's name in the country's name list's army_names (CNameListManager::
-- TakeSequentialArmyName): the type's own entry, else generic; `%SEQ%` with fmt = the sequential
-- name and num = the lowest number the country's armies of that name do not use [I]
local function army_name(country, army_type)
    local defs = require("engine.defs")
    local c = world.object("country", country)
    local nl = c and unq(world.field(c, "name_list"))
    local d = nl and defs.get("common/name_lists", nl)
    local an = d and defs.field(d.block, "army_names")
    local t = defs.get("common/armies", army_type)
    local key = t and unq(defs.field(t.block, "name_list_key")) or army_type
    local entry = type(an) == "table" and (defs.field(an, key) or defs.field(an, army_type) or defs.field(an, "generic"))
    local seq = type(entry) == "table" and unq(defs.field(entry, "sequential_name"))
    if not seq then
        local n = {}
        world.append(n, "key", "FALLBACK_ARMY_NAME_INT", true)
        return n
    end
    local used = {}
    for _, aid in ipairs(world.all("army")) do
        local a = world.object("army", aid)
        if tonumber(world.field(a, "owner")) == country then
            local nb = world.field(a, "name")
            if type(nb) == "table" and unq(world.field(nb, "key")) == "%SEQ%" then
                local fmt, num
                for _, v in ipairs(world.blocks(world.field(nb, "variables"))) do
                    local k = unq(world.field(v, "key"))
                    local val = world.field(v, "value")
                    local vk = type(val) == "table" and unq(world.field(val, "key"))
                    if k == "fmt" then fmt = vk elseif k == "num" then num = tonumber(vk) end
                end
                if fmt == seq and num then used[num] = true end
            end
        end
    end
    local n = 1
    while used[n] do n = n + 1 end
    local nb = {}
    world.append(nb, "key", "%SEQ%", true)
    local fmt = {}
    world.append(fmt, "key", seq, true)
    local num = {}
    world.append(num, "key", tostring(n), true)
    local function var(k, v)
        local b = {}
        world.append(b, "key", k, true)
        world.append(b, "value", v)
        return b
    end
    world.append(nb, "variables", { var("fmt", fmt), var("num", num) })
    return nb
end
construction.army_name = army_name

-- an army of the same owner and type as the reference for its health and morale [I]; without one
-- the type's health and morale times 200
local function army_stats(country, army_type)
    for _, aid in ipairs(world.all("army")) do
        local a = world.object("army", aid)
        if tonumber(world.field(a, "owner")) == country and unq(world.field(a, "type")) == army_type then
            return tonumber(world.field(a, "max_health")) or 200, tonumber(world.field(a, "max_health")) or 200,
                tonumber(world.field(a, "morale")) or 200
        end
    end
    local defs = require("engine.defs")
    local t = defs.get("common/armies", army_type)
    local h = t and tonumber(defs.field(t.block, "health")) or 1
    local m = t and tonumber(defs.field(t.block, "morale")) or 1
    return 200 * h, 200 * h, 200 * m
end

-- the country's latest design of a ship class (CCountry::GetLatestShipDesignOfClass): the last
-- of its ship_design_collection whose size is of that class [I]
local function latest_design(country, class)
    local c = world.object("country", country)
    local coll = c and world.path(c, "ship_design_collection", "ship_design")
    local best
    for _, v in ipairs(world.list(coll)) do
        local info = create().design_info(tonumber(v))
        if info and info.class == class then
            best = tonumber(v)
        end
    end
    return best
end
construction.latest_design = latest_design

local function add_owned_army(country, aid)
    local c = world.object("country", country)
    if not c then
        return
    end
    local l = world.field(c, "owned_armies")
    if type(l) ~= "table" then
        l = world.child(c, "owned_armies")
    end
    world.append_value(l, aid)
    live.touch("country", country)
end

-- CArmy::MoveToOrbit (0x22305e0 Linux): the transport ship (the army's name), a new transport
-- fleet in orbit of the planet (CPlanet::EnterOrbit: three draws), AddShip (two draws), and one
-- draw more [I] (the profile: five a transport)
local function move_to_orbit(aid, a, country, planet, date)
    local C = create()
    local design = latest_design(country, "shipclass_transport")
    if not design then
        return nil, "no transport design"
    end
    local p = world.object("planet", planet)
    local at = p and C.read_coord(world.field(p, "coordinate"))
    local sid = C.ship{ country = country, design = design, coordinate = at, date = date,
                        name = C.copy(world.field(a, "name")), army = aid, named_by = "army" }
    if not sid then
        return nil, "no ship"
    end
    local fid = C.fleet{ country = country, ship_class = "shipclass_transport", civilian = false, coordinate = at }
    local f = world.object("fleet", fid)
    -- the fleet's name now (CFleet::CreateName with its first ship): TRANS_FLEET_NAME
    world.insert(f, 1, "name", C.transport_fleet_name(country))
    local _, slot_at = C.enter_orbit(fid, "planet", planet)
    local s = world.object("ships", sid)
    if slot_at and s then
        local P = require("engine.fleets.path")
        for _, k in ipairs({ "coordinate", "target_coordinate" }) do
            local cb = world.field(s, k)
            if type(cb) == "table" then
                world.set(cb, "x", P.text(slot_at.x))
                world.set(cb, "y", P.text(slot_at.y))
            end
        end
    end
    C.add_ship(fid, sid)
    draw()
    return sid, fid
end

-- CBuildableArmy::OnFinished
local function finish_army(b, date)
    local colony = tonumber(world.field(b, "planet"))
    local planet = colony and world.colony_planet and world.colony_planet[colony]
    local p = planet and world.object("planet", planet)
    local country = p and tonumber(world.field(p, "owner"))
    local army_type = unq(world.field(b, "army_type"))
    if not (country and army_type) then
        return false, "army: no colony or owner for colony " .. tostring(colony)
    end
    local defs = require("engine.defs")
    local t = defs.get("common/armies", army_type)
    local defensive = t and defs.field(t.block, "defensive") == "yes"
    local aid, entry = create().allocate("army")
    local health, max_health, morale = army_stats(country, army_type)
    local a = {}
    world.append(a, "name", army_name(country, army_type))
    world.append(a, "type", army_type, true)
    world.append(a, "health", health)
    world.append(a, "max_health", max_health)
    world.append(a, "jump_drive_cooldown", "0.01.01", true)
    world.append(a, "owner", country)
    world.append(a, "species", tonumber(world.field(b, "species")) or NO_ID)
    create().place("army", aid, entry, a)
    add_owned_army(country, aid)
    -- on_army_recruited (CArmy::PerformBuildingOnAction: two scopes; this = the colony, from = the army)
    draw()
    draw()
    on_action("on_army_recruited", colony_scope(colony), { "army", aid })
    local sid, fid
    if defensive then
        world.append(a, "colony", colony)
    else
        local why
        sid, fid = move_to_orbit(aid, a, country, planet, date)
        if sid then
            world.append(a, "ship", sid)
        else
            world.append(a, "colony", colony)
        end
    end
    world.append(a, "morale", morale)
    -- CArmyType::OnBuilt(colony, one draw)
    draw()
    construction.stats.armies = construction.stats.armies + 1
    return true, nil, { army = aid, ship = sid, fleet = fid }
end

-- ---------------------------------------------------------------------------------------------
-- starbases

local function set_slot(block, slot, value)
    for _, e in ipairs(block) do
        if e.op and e.key and tonumber(e.key.text) == slot then
            e.value = { text = value }
            return
        end
    end
    block[#block + 1] = { key = { text = tostring(slot) }, op = "=", value = { text = value } }
    table.sort(block, function(x, y) return (tonumber(x.key and x.key.text) or 0) < (tonumber(y.key and y.key.text) or 0) end)
end

-- CStarbase::SetLevel (0x2030f30 Linux): the level; the station's size in its design (the
-- level's ship_size; the rebuild of its utilities is not modelled); FireOnShipUpgradedAction
local function finish_starbase_upgrade(b)
    local defs = require("engine.defs")
    local sbid = tonumber(world.field(b, "starbase"))
    local sb = sbid and world.object("starbases", sbid)
    local level = unq(world.field(b, "starbase_upgrade"))
    if not (sb and level) then
        return false, "starbase upgrade: no starbase " .. tostring(sbid)
    end
    for _, e in ipairs(sb) do
        if e.op and e.key and e.key.text == "level" then e.value.text, e.value.quoted = level, true end
    end
    local ld = defs.get("common/starbase_levels", level)
    local size = ld and unq(defs.field(ld.block, "ship_size"))
    local sdi = world.field(sb, "ship_design_implementation")
    local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
    local d = did and world.object("ship_design", did)
    local gs = d and world.blocks(world.field(d, "growth_stages"))[1]
    if gs and size then
        for _, e in ipairs(gs) do
            if e.op and e.key and e.key.text == "ship_size" then e.value.text, e.value.quoted = size, true end
        end
    end
    local station = tonumber(world.field(sb, "station"))
    draw()
    if station then
        on_action("on_ship_upgraded", { "ship", station })
    end
    construction.stats.starbase_items = construction.stats.starbase_items + 1
    return true, nil, { starbase = sbid }
end

-- CStarbase::SetModule / SetBuilding (0x202d890 / 0x202da50 Linux) in the item's slot; a
-- module's on_finished effect after one draw (CBuildableStarbaseModule::OnFinished 0x21b2f70)
local function finish_starbase_part(kind, b)
    local defs = require("engine.defs")
    local sbid = tonumber(world.field(b, "starbase"))
    local sb = sbid and world.object("starbases", sbid)
    local key = unq(world.field(b, kind == "starbase_module" and "starbase_module" or "starbase_building")
        or world.field(b, kind == "starbase_module" and "module" or "building"))
    local slot = tonumber(world.field(b, "slot")) or tonumber(world.field(b, "index"))
    if not (sb and key and slot) then
        return false, kind .. ": no starbase, type or slot"
    end
    local list = world.field(sb, kind == "starbase_module" and "modules" or "buildings")
    if type(list) ~= "table" then
        list = world.child(sb, kind == "starbase_module" and "modules" or "buildings")
    end
    set_slot(list, slot, key)
    if kind == "starbase_module" then
        local md = defs.get("common/starbase_modules", key)
        local effect = md and defs.field(md.block, "on_finished")
        if type(effect) == "table" then
            draw()
            pcall(function()
                local eval = package.loaded["simscript.eval"] or require("simscript.eval")
                local effects = require("simscript.effects")
                effects.run(effect, eval.new_ctx(eval.S("starbase", sbid)))
            end)
        end
    end
    construction.stats.starbase_items = construction.stats.starbase_items + 1
    return true, nil, { starbase = sbid }
end

-- ---------------------------------------------------------------------------------------------

local function finish(item, kind, b, date)
    local planet = tonumber(world.field(b, "planet"))
    if kind == "district" then
        -- the colony's district of that type
        local want = world.field(b, "district")
        local colony = planet
        local c = colony and world.object("colony", colony)
        if not c then
            return false, "district: no colony " .. tostring(colony)
        end
        for _, did in ipairs(world.list(world.field(c, "districts"))) do
            local d = world.object("districts", tonumber(did))
            if d and world.field(d, "type") == want then
                world.set(d, "level", (tonumber(world.field(d, "level")) or 0) + 1)
                planet_done("on_district_complete", colony)
                return true
            end
        end
        return false, "district: colony " .. tostring(colony) .. " has no " .. tostring(want)
    elseif kind == "planet_upgrade_building" then
        -- the building becomes the upgrade (upgrade_building: the building's id)
        local bl = world.object("buildings", tonumber(world.field(b, "upgrade_building")))
        if not bl then
            return false, "upgrade: no building " .. tostring(world.field(b, "upgrade_building"))
        end
        world.set(bl, "type", world.field(b, "building"))
        planet_done("on_building_upgraded", planet)
        return true
    elseif kind == "zone" then
        local d = world.object("districts", tonumber(world.field(b, "district")))
        local slot = tonumber(world.field(b, "zone_slot"))
        local zones = d and world.field(d, "zones")
        local values = {}
        for _, e in ipairs(type(zones) == "table" and zones or {}) do
            if e.text then values[#values + 1] = e end
        end
        if not (slot and values[slot + 1]) then
            return false
        end
        local id = next_id("zones")
        local z = {}
        world.append(z, "type", world.field(b, "zone"), true)
        world.append(z, "buildings", {})
        world.create("zones", id, z)
        values[slot + 1].text = tostring(id)
        planet_done("on_zone_complete", planet)
        return true
    elseif kind == "planet_building" then
        local z = world.object("zones", tonumber(world.field(b, "zone")))
        if not z then
            return false
        end
        local id = next_id("buildings")
        local bl = {}
        world.append(bl, "type", world.field(b, "building"), true)
        world.append(bl, "position", #world.list(world.field(z, "buildings")))
        world.create("buildings", id, bl)
        world.append_value(world.child(z, "buildings"), id)
        planet_done("on_building_complete", planet)
        return true
    elseif kind == "ship" then
        local okind, oid = orbitable(b)
        local did = ship_design(b)
        local owner = okind == "starbase" and starbase_owner(oid)
            or (okind == "planet" and tonumber(world.field(world.object("planet", oid), "owner")))
        if not (okind and did and owner) then
            return false, "ship: no orbitable, design or owner"
        end
        local C = create()
        local sid, fid, merged = C.around_orbital{ country = owner, design = did, orbitable = { kind = okind, id = oid }, date = date }
        if not sid then
            return false, "ship: " .. tostring(merged or "not created")
        end
        C.on_ship_built(sid, { kind = okind, id = oid })
        construction.stats.ships = construction.stats.ships + 1
        return true, nil, { ship = sid, fleet = fid, merged = merged, design = did, country = owner }
    elseif OFF then
        return nil
    elseif kind == "army" then
        return finish_army(b, date)
    elseif kind == "starbase_upgrade" then
        return finish_starbase_upgrade(b)
    elseif kind == "starbase_module" or kind == "starbase_building" then
        return finish_starbase_part(kind, b)
    end
    return nil
end

-- construction.daily(date): every queue's day
function construction.daily(date)
    local items = world.stores[ITEMS]
    local queues = world.stores[QUEUES]
    if not items or not queues then
        return
    end
    local today = date and date.year and string.format("%d.%02d.%02d", date.year, date.month, date.day) or nil
    local done = {}
    for _, qid in ipairs(world.all(QUEUES)) do
        local q = queues[qid]
        if q and world.field(q, "disabled") ~= "yes" then
            local list = world.field(q, "items")
            local ids = world.list(list)
            local n = math.min(#ids, tonumber(world.field(q, "simultaneous")) or 1)
            for i = n, 1, -1 do
                local iid = tonumber(ids[i])
                local item = iid and items[iid]
                if item then
                    local speed, kind = construction.speed(item)
                    if speed then
                        local progress = (tonumber(world.field(item, "progress")) or 0) + speed
                        world.set(item, "progress", math.floor(progress * 100000 + 0.5) / 100000)
                        construction.stats.advanced = construction.stats.advanced + 1
                        if progress >= (tonumber(world.field(item, "progress_needed")) or math.huge) then
                            world.remove_value(list, iid)
                            done[#done + 1] = iid
                        end
                    else
                        kind = kind or "?"
                        construction.stats.not_modelled[kind] = (construction.stats.not_modelled[kind] or 0) + 1
                    end
                end
            end
        end
    end
    -- CConstructionQueueItemManager::DailyUpdate: the finished items
    for _, iid in ipairs(done) do
        local item = items[iid]
        local kind, b = buildable(item)
        local ok, why, made = finish(item, kind, b, today)
        if ok then
            construction.stats.finished = construction.stats.finished + 1
            local rec = { kind = kind, planet = world.field(b, "planet"), date = today, item = iid,
                          country = tonumber(world.field(item, "paying_country")) }
            for k, v in pairs(made or {}) do rec[k] = v end
            construction.finished[#construction.finished + 1] = rec
        else
            construction.stats.finish_not_modelled[kind] = (construction.stats.finish_not_modelled[kind] or 0) + 1
            construction.failures[#construction.failures + 1] = string.format("%s %s: %s", tostring(today), kind, why or "not modelled")
        end
        world.remove(ITEMS, iid)
    end
end

local function list(t)
    local out = {}
    for k, v in pairs(t) do
        out[#out + 1] = k .. " " .. v
    end
    table.sort(out)
    return table.concat(out, ", ")
end

function construction.report()
    local s = construction.stats
    local text = string.format("construction: %d item-days advanced, %d finished (%d ships, %d armies, %d starbase items); %d draws, %d on_actions (%d errors); not modelled: item-days of %s; finishing of %s",
        s.advanced, s.finished, s.ships, s.armies, s.starbase_items, s.draws, s.on_actions, s.on_action_errors,
        list(s.not_modelled), list(s.finish_not_modelled))
    for _, f in ipairs(construction.finished) do
        if f.kind == "ship" or f.kind == "army" or f.kind:sub(1, 8) == "starbase" then
            text = text .. string.format("\n  %s %s country %s: ship %s fleet %s%s army %s starbase %s design %s",
                tostring(f.date), f.kind, tostring(f.country), tostring(f.ship), tostring(f.fleet),
                f.merged and " (merged)" or "", tostring(f.army), tostring(f.starbase), tostring(f.design))
        end
    end
    local c = package.loaded["engine.fleets.create"]
    if type(c) == "table" and c.report then
        text = text .. "\n" .. c.report()
    end
    return text
end

return construction
