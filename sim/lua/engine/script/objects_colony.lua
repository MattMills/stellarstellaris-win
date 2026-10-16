-- engine/script/objects_colony.lua : a colony's districts, zones, buildings, pop groups and
-- blockers made by script (add_district, remove_district, add_zone, add_building,
-- remove_building, create_pop_group, clear_blockers, add_blocker), in the save's form:
--
--   districts = { <id> = { zones = { <zone id | 4294967295> ... } type level } }
--   zones     = { <id> = { type buildings = { <building id> ... } } }
--   buildings = { <id> = { type position } }
--   colony    = { ... pop_groups = { } districts = { } buildings_cache = { } ... }
--
-- From the 4.5.2 Linux build (docs/script_objects.md "Colonies"; Linux addresses). A colony is
-- reached from its scope as NScriptUtil::AccessOrCreateColonyFromScope does: a planet's colony, a
-- colony itself, a ship's. None of these effects fires an on_action; remove_district and
-- clear_blockers draw from the game's generator (one per level, one per blocker).

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")
local objects = require("engine.script.objects")

local applied, skipped, unq, NO_ID = objects.applied, objects.skipped, objects.unq, objects.NO_ID

local colony = {}
objects.colony = colony

-- the colony of a scope
local function colony_of(kind, id)
    if kind == "planet" then
        return world.planet_colony[id]
    elseif kind == "colony" then
        return world.object("colony", id) and id or nil
    elseif kind == "ship" then
        return objects.ref(world.field(world.object("ships", id), "colony"))
    end
    return nil
end
colony.colony_of = colony_of

-- the carrier planet of a scope (a planet itself, a colony's)
local function planet_of(kind, id)
    if kind == "planet" then return id end
    local cid = colony_of(kind, id)
    return cid and world.colony_planet[cid]
end
colony.planet_of = planet_of

local function def(folder, key)
    return objects.def(folder, key)
end

-- the names of a definition's list `key = { a b c }`
local function names(block, key)
    local out = {}
    local l = block and defs.field(block, key)
    if type(l) == "table" then
        for _, e in ipairs(l) do
            if e.text then out[#out + 1] = unq(e.text) end
        end
    end
    return out
end
colony.names = names

-- a definition's trigger block evaluated in a planet's scope (true without one; an error counts as
-- true [I])
local function holds(block, key, pid)
    local t = block and defs.field(block, key)
    if type(t) ~= "table" or not pid then return true end
    local eval = package.loaded["simscript.eval"]
    if not eval then return true end
    local ok, r = pcall(eval.trigger, t, eval.new_ctx(eval.S("planet", pid)))
    return not ok or (r and true or false)
end

-- an effect block of a definition run with this = the planet, in a scope made from a draw
local function run_effect(block, key, pid, seed)
    local t = block and defs.field(block, key)
    if type(t) ~= "table" or not pid then return end
    local eval = package.loaded["simscript.eval"]
    if not eval then return end
    local ctx = eval.new_ctx(eval.S("planet", pid))
    if eval.seed_scope then eval.seed_scope(ctx, seed) end
    local ok, err = pcall(eval.effect, t, ctx)
    if not ok then objects.err(key .. ": " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------------------------
-- districts

local function district_ids(c)
    local out = {}
    for _, d in ipairs(world.list(world.field(c, "districts"))) do
        out[#out + 1] = tonumber(d)
    end
    return out
end
colony.district_ids = district_ids

-- the colony's first district of a type: id, block
local function district_of_type(c, dtype)
    for _, did in ipairs(district_ids(c)) do
        local d = world.object("districts", did)
        if d and unq(world.field(d, "type")) == dtype then return did, d end
    end
    return nil
end
colony.district_of_type = district_of_type

-- CGameState::CreateNewZone: a zone of a type, no buildings
local function new_zone(ztype)
    local z = {}
    world.append(z, "type", ztype, true)
    return objects.create("zones", z)
end

-- the district's zone list entries (bare tokens), and the list block
local function zone_cells(d)
    local zl = world.field(d, "zones")
    if type(zl) ~= "table" then zl = world.child(d, "zones") end
    local cells = {}
    for _, e in ipairs(zl) do
        if e.text then cells[#cells + 1] = e end
    end
    return cells, zl
end

-- CGameState::CreateNewDistrict -> CDistrict::InitializeZones (0x24cab90): level 1, one zone entry
-- per zone slot of the type (file order, whatever the slot's unlock), the slot's `start` zone made
-- for a slot that has one (slot_city_government: zone_default), else 4294967295; the district at
-- the end of the colony's list [V]
local function create_district(c, dtype, db)
    local nd = {}
    world.append(nd, "zones", {})
    world.append(nd, "type", dtype, true)
    world.append(nd, "level", 1)
    local did = objects.create("districts", nd)
    local d = world.object("districts", did)
    local zl = world.field(d, "zones")
    for _, slot in ipairs(names(db, "zone_slots")) do
        local sb = def("common/zone_slots", slot)
        local start = sb and defs.field(sb, "start")
        world.append_value(zl, start and new_zone(unq(start)) or NO_ID)
    end
    world.append_value(objects.list_of(c, "districts"), did)
    return did, d
end
colony.create_district = create_district

-- the sum of the colony's district levels
local function district_levels(c)
    local n = 0
    for _, did in ipairs(district_ids(c)) do
        n = n + (tonumber(world.field(world.object("districts", did), "level")) or 0)
    end
    return n
end

-- CColonyCarrier::CalcMaxDistricts (0x28d7180): trunc(planet size x NUM_DISTRICTS_FROM_PLANET_SIZE
-- (1)) + NUM_DISTRICTS_BASE (0) + the carrier's district modifiers: one fixed modifier (taken as
-- planet_max_districts_add), the planet class's (its +0x438: pc_<class>_max_districts_add) and,
-- for artificial / other classes, planet_artificial_ / planet_non_artificial_max_districts_add
-- (modifiers 0x81/0x82 by the class flag) [V for the sum, I for the modifier names]
function colony.max_districts(pid)
    local p = world.object("planet", pid)
    if not p then return 0 end
    objects.fresh()
    local size = tonumber(world.field(p, "planet_size")) or 0
    local E = rawget(_G, "E")
    local function m(name)
        return E and E.modifier and math.floor(E.modifier("planet", pid, name) or 0) or 0
    end
    local class = unq(world.field(p, "planet_class")) or ""
    local cd = def("common/planet_classes", class)
    local artificial = cd and defs.field(cd, "is_artificial") == "yes"
    return math.floor(size) + m("planet_max_districts_add") + m(class .. "_max_districts_add")
        + (artificial and m("planet_artificial_max_districts_add") or m("planet_non_artificial_max_districts_add"))
end

-- free_district_slots (CFreeDistrictSlotsTrigger::GetTriggerValue 0x3b89c20): the carrier's
-- CalcMaxDistricts less the colony's district levels (queued districts not counted [I])
function colony.free_district_slots(pid)
    local cid = world.planet_colony[pid]
    local c = cid and world.object("colony", cid)
    return colony.max_districts(pid) - (c and district_levels(c) or 0)
end

-- CColony::CanAddDistrict (0x2860980) without ignore_cap: the levels below CalcMaxDistricts and the
-- type's below its cap (CalcMaxDistrictsOfType, not traced: the `<type>_max_add` modifier of the
-- planet [I]), an uncapped type exempt (not traced: types without a max modifier [I])
local function can_add(c, pid, dtype, ignore_cap)
    if ignore_cap then return true end
    if district_levels(c) >= colony.max_districts(pid) then return false end
    local E = rawget(_G, "E")
    local max = E and E.modifier and E.modifier("planet", pid, dtype .. "_max_add")
    if not max or max == 0 then return true end
    local _, d = district_of_type(c, dtype)
    local n = d and tonumber(world.field(d, "level")) or 0
    return n < max
end

-- CColony::AddDistrict (0x2860f10): the first district of the type gains a level
-- (CDistrict::Upgrade), else a new one (create_district) [V]
function colony.add_district(cid, dtype, ignore_cap)
    local c = world.object("colony", cid)
    local db = def("common/districts", dtype)
    if not c or not db then return nil end
    if not can_add(c, world.colony_planet[cid], dtype, ignore_cap) then return nil end
    local did, d = district_of_type(c, dtype)
    if d then
        world.set(d, "level", (tonumber(world.field(d, "level")) or 0) + 1)
        return did
    end
    return (create_district(c, dtype, db))
end

-- add_district: t = { kind, id, district, ignore_cap, conversion } (CAddDistrictEffect::ExecuteActual
-- 0x373f340). type_conversion (CDistrictType::GetConversionTypeFor) is not ported: the type as given
function systems.effects.add_district(t)
    local cid = colony_of(t.kind, t.id)
    if not cid then return skipped("add_district", "no colony") end
    if not def("common/districts", t.district) then return skipped("add_district", "unknown district") end
    local did = colony.add_district(cid, t.district, t.ignore_cap)
    return did and applied("add_district") or skipped("add_district", "cap")
end

-- remove_district (CRemoveDistrictEffect 0x373f910 -> CColony::RemoveDistrict 0x2860650): one level
-- of the first district of the type; the colony's government district (the first whose type has
-- more than one zone slot, else the first) never below level 1; a level-1 district goes with its
-- zones (and their buildings). One draw of the game's generator per level removed, seeding the
-- type's on_destroy (run with this = the carrier) [V]
function systems.effects.remove_district(t)
    local cid = colony_of(t.kind, t.id)
    local c = cid and world.object("colony", cid)
    if not c then return skipped("remove_district", "no colony") end
    local did, d = district_of_type(c, t.district)
    if not d then return skipped("remove_district", "no such district") end
    local level = tonumber(world.field(d, "level")) or 1
    local count = math.min(1, level)
    local gov
    for _, x in ipairs(district_ids(c)) do
        local xb = world.object("districts", x)
        if #names(def("common/districts", unq(world.field(xb, "type"))), "zone_slots") > 1 then gov = x break end
    end
    gov = gov or district_ids(c)[1]
    if gov and unq(world.field(world.object("districts", gov), "type")) == t.district and level <= 1 then
        count = count - 1
    end
    local pid = world.colony_planet[cid]
    local db = def("common/districts", t.district)
    for _ = 1, count do
        if level >= 2 then
            level = level - 1
            world.set(d, "level", level)
        else
            for _, z in ipairs(world.list(world.field(d, "zones"))) do
                local zid = objects.ref(z)
                local zb = zid and world.object("zones", zid)
                if zb then
                    for _, b in ipairs(world.list(world.field(zb, "buildings"))) do
                        world.remove("buildings", tonumber(b))
                    end
                    world.remove("zones", zid)
                end
            end
            world.remove_value(world.field(c, "districts"), did)
            world.remove("districts", did)
        end
        run_effect(db, "on_destroy", pid, objects.draw())
    end
    colony.rebuild_cache(c)
    return applied("remove_district")
end

-- ---------------------------------------------------------------------------------------------
-- zones

-- whether a slot allows a zone type: one of the slot's included_zone_sets is a set of the zone
-- (`zone_sets`), the zone not in its `exclude`, and the zone's `potential` holds
-- (CDistrictZoneSlot::IsZoneTypePotential: the allowed list, then the trigger) [I]
local function slot_allows(sb, ztype, pid)
    local zb = def("common/zones", ztype)
    if not sb or not zb then return false end
    for _, x in ipairs(names(sb, "exclude")) do
        if x == ztype then return false end
    end
    local zsets = {}
    for _, s in ipairs(names(zb, "zone_sets")) do zsets[s] = true end
    local ok = false
    for _, s in ipairs(names(sb, "included_zone_sets")) do
        if zsets[s] or s == ztype then ok = true break end
    end
    return ok and holds(zb, "potential", pid)
end
colony.slot_allows = slot_allows

-- CDistrict::FindZoneSlotIndex(scope, zone, 0, 0) (0x24cb800): the first slot without a zone that
-- allows the zone type; -1
local function free_slot_for(d, ztype, pid)
    local db = def("common/districts", unq(world.field(d, "type")))
    local slots = names(db, "zone_slots")
    local cells = zone_cells(d)
    for i, slot in ipairs(slots) do
        local e = cells[i]
        if not (e and objects.ref(e.text)) and slot_allows(def("common/zone_slots", slot), ztype, pid) then
            return i - 1
        end
    end
    return -1
end

-- CDistrict::AddZone / AddOrReplaceZone (0x24cbc10, 0x24cbd10): the slot within the type's slots,
-- the zone list padded with 4294967295 up to it; an occupied slot fails without replace; with
-- replace the new zone is made first, the old one's buildings move to it and it goes (its refund,
-- modifier #158, not ported) -> the zone's id or nil [V]
function colony.add_zone(d, ztype, slot, replace)
    local db = def("common/districts", unq(world.field(d, "type")))
    local nslots = #names(db, "zone_slots")
    if slot < 0 or slot >= nslots then return nil end
    local cells, zl = zone_cells(d)
    while #cells <= slot do
        world.append_value(zl, NO_ID)
        cells = zone_cells(d)
    end
    local e = cells[slot + 1]
    local old = objects.ref(e.text)
    if old and not replace then return nil end
    local zid = new_zone(ztype)
    if old then
        local ob = world.object("zones", old)
        local moved = world.list(ob and world.field(ob, "buildings"))
        if #moved > 0 then
            local bl = world.child(world.object("zones", zid), "buildings")
            for _, b in ipairs(moved) do world.append_value(bl, b) end
        end
        world.remove("zones", old)
    end
    world.set_entry(zl, e, tostring(zid))
    return zid
end

-- add_zone: t = { kind, id, district (a type, or a slot index of the colony's districts), zone,
-- zone_slot, replace } (CAddZoneEffect::ExecuteActual 0x3849560, FindDistrictToBuildZoneTypeInto
-- 0x3849000): the district named, else the first with a free slot allowing the zone; the slot given,
-- else the first free one allowing it [V]
function systems.effects.add_zone(t)
    local cid = colony_of(t.kind, t.id)
    local c = cid and world.object("colony", cid)
    if not c then return skipped("add_zone", "no colony") end
    if not def("common/zones", t.zone) then return skipped("add_zone", "unknown zone") end
    local pid = world.colony_planet[cid]
    local d
    local idx = tonumber(t.district)
    if idx then
        local did = district_ids(c)[idx + 1]
        d = did and world.object("districts", did)
    elseif t.district then
        local _
        _, d = district_of_type(c, t.district)
    else
        for _, did in ipairs(district_ids(c)) do
            local x = world.object("districts", did)
            if free_slot_for(x, t.zone, pid) >= 0 then d = x break end
        end
    end
    if not d then return skipped("add_zone", "no district") end
    local slot = t.zone_slot
    if not slot or slot < 0 then slot = free_slot_for(d, t.zone, pid) end
    if slot < 0 then return skipped("add_zone", "no slot") end
    local zid = colony.add_zone(d, t.zone, slot, t.replace)
    return zid and applied("add_zone") or skipped("add_zone", "slot taken")
end

-- ---------------------------------------------------------------------------------------------
-- buildings

-- the building types each one upgrades from: the base of its line and its depth (a building listed
-- in another's `upgrades`), CBuilding +0x28 root type and +0x1a0 upgrade depth [I]
local upgraded_from
local function line_of(bkey)
    if not upgraded_from then
        upgraded_from = {}
        for name, d in pairs(defs.folder("common/buildings") or {}) do
            for _, u in ipairs(names(d.block, "upgrades")) do
                upgraded_from[u] = upgraded_from[u] or name
            end
        end
    end
    local root, depth, seen = bkey, 0, {}
    while upgraded_from[root] and not seen[root] do
        seen[root] = true
        root = upgraded_from[root]
        depth = depth + 1
    end
    return root, depth
end

local function position_priority(bkey)
    local b = def("common/buildings", bkey)
    return b and tonumber(defs.field(b, "position_priority")) or 200
end

-- the building types a zone type lists (CZoneType +0x1008: `include` keys or `all`, the buildings
-- of its `included_building_sets`, none of its `excluded_building_sets`) [I]
local function building_sets(bb)
    local s = {}
    for _, n in ipairs(names(bb, "building_sets")) do s[n] = true end
    return s
end
local function zone_lists(zb, bkey, bb)
    local sets = building_sets(bb)
    for _, n in ipairs(names(zb, "excluded_building_sets")) do
        if sets[n] then return false end
    end
    for _, n in ipairs(names(zb, "include")) do
        if n == "all" or n == bkey then return true end
    end
    for _, n in ipairs(names(zb, "included_building_sets")) do
        if sets[n] then return true end
    end
    return false
end
colony.zone_lists = zone_lists

-- CZoneType::CanPotentiallyBuild (0x215dde0): listed, and the building's `potential` holds
local function can_build_in(ztype, bkey, bb, pid)
    local zb = def("common/zones", ztype)
    return zb ~= nil and zone_lists(zb, bkey, bb) and holds(bb, "potential", pid)
end

-- CZoneType::CalcMaxBuildings (0x215dea0): max_buildings (NDefines.NGameplay.
-- DEFAULT_MAX_PLANET_BUILDINGS_PER_ZONE, 3, when the zone has none: the CZoneType ctor 0x215c2dd), at most levels / districts_per_building
-- of the district's type; the planet class's modifier (max_buildings_planet_class) not ported
local function max_buildings(zb, d)
    local max = tonumber(defs.field(zb, "max_buildings")) or 3
    local per = tonumber(defs.field(zb, "districts_per_building"))
    if per and per > 0 then
        local n = tonumber(world.field(d, "level")) or 0
        max = math.min(max, math.floor(n / per))
    end
    return max
end

-- the zones of a district in slot order: { index, zone id, zone block }
local function district_zones(d)
    local out = {}
    for i, e in ipairs(zone_cells(d)) do
        local zid = objects.ref(e.text)
        local zb = zid and world.object("zones", zid)
        if zb then out[#out + 1] = { i - 1, zid, zb } end
    end
    return out
end

local function free_building_slots(zb, d)
    local zd = def("common/zones", unq(world.field(zb, "type")))
    return zd and (max_buildings(zd, d) - #world.list(world.field(zb, "buildings"))) or 0
end

-- the colony's buildings_cache rebuilt: districts in order, zones in slot order, buildings in
-- position order (CColony::AddBuilding, after CDistrict::CollectBuildings) [V]
function colony.rebuild_cache(c)
    local cache = objects.list_of(c, "buildings_cache")
    world.replace(cache, {})
    for _, did in ipairs(district_ids(c)) do
        local d = world.object("districts", did)
        for _, z in ipairs(d and district_zones(d) or {}) do
            for _, b in ipairs(world.list(world.field(z[3], "buildings"))) do
                world.append_value(cache, b)
            end
        end
    end
end

-- CZone::AddBuilding (0x2158940): a new building inserted after every building whose line's base
-- has a position_priority not above its own (same line: by depth), the positions renumbered [V]
function colony.zone_add_building(zb, bkey)
    local bl = world.field(zb, "buildings")
    if type(bl) ~= "table" then bl = world.child(zb, "buildings") end
    local root, depth = line_of(bkey)
    local prio = position_priority(root)
    local list = world.list(bl)
    local at = #list + 1
    for i, x in ipairs(list) do
        local ob = world.object("buildings", tonumber(x))
        local ok = ob and unq(world.field(ob, "type"))
        if ok then
            local oroot, odepth = line_of(ok)
            local before
            if oroot ~= root then
                before = prio < position_priority(oroot)
            else
                before = depth < odepth
            end
            if before then at = i break end
        end
    end
    local b = {}
    world.append(b, "type", bkey, true)
    world.append(b, "position", at - 1)
    local id = objects.create("buildings", b)
    world.insert_value(bl, at, tostring(id))
    for i, x in ipairs(world.list(bl)) do
        local ob = world.object("buildings", tonumber(x))
        if ob then world.set(ob, "position", i - 1) end
    end
    return id
end

-- CColony::AddBuilding(triplet, 0x3c) (0x2884320) -> the building's id or nil [V]:
--   the district named (made when the colony has none: TryToAddDistrict), else the first district
--   with a zone of the type named (with room), else the first with a zone that can take the
--   building and has room; else the first district with a free slot allowing a zone that lists it
--   (the zone made); else a new district (TryToAddDistrictFor)
function colony.add_building(cid, bkey, ztype, dtype)
    local c = world.object("colony", cid)
    local bb = def("common/buildings", bkey)
    if not c or not bb then return nil end
    local pid = world.colony_planet[cid]
    local d
    if dtype then
        local _
        _, d = district_of_type(c, dtype)
        if not d then
            local ddb = def("common/districts", dtype)
            if ddb then
                local _x
                _x, d = create_district(c, dtype, ddb)
            end
        end
    end
    local zone
    if not d then
        for _, did in ipairs(district_ids(c)) do
            local x = world.object("districts", did)
            for _, z in ipairs(district_zones(x)) do
                local zt = unq(world.field(z[3], "type"))
                local fits
                if ztype then
                    fits = zt == ztype and free_building_slots(z[3], x) > 0
                else
                    fits = free_building_slots(z[3], x) > 0 and can_build_in(zt, bkey, bb, pid)
                end
                if fits then d, zone = x, z[3] break end
            end
            if d then break end
        end
    elseif ztype then
        for _, z in ipairs(district_zones(d)) do
            if unq(world.field(z[3], "type")) == ztype and free_building_slots(z[3], d) > 0 then zone = z[3] break end
        end
    else
        for _, z in ipairs(district_zones(d)) do
            if free_building_slots(z[3], d) > 0 and can_build_in(unq(world.field(z[3], "type")), bkey, bb, pid) then
                zone = z[3]
                break
            end
        end
    end
    if not zone then
        -- CDistrict::TryToAddZoneFor (0x24cc3d0): the first empty slot one of whose allowed zone
        -- types (the zones of its sets) lists the building and is potential: that zone made
        local candidates = d and { d } or {}
        if not d then
            for _, did in ipairs(district_ids(c)) do candidates[#candidates + 1] = world.object("districts", did) end
        end
        for _, x in ipairs(candidates) do
            local db = def("common/districts", unq(world.field(x, "type")))
            local cells = zone_cells(x)
            for i, slot in ipairs(names(db, "zone_slots")) do
                local e = cells[i]
                if not (e and objects.ref(e.text)) then
                    local sb = def("common/zone_slots", slot)
                    for _, zz in ipairs(objects.ordered("common/zones")) do
                        local zname, zd = zz[1], zz[2]
                        if (not ztype or zname == ztype) and slot_allows(sb, zname, pid) and zone_lists(zd.block, bkey, bb) then
                            local zid = colony.add_zone(x, zname, i - 1, false)
                            zone = zid and world.object("zones", zid)
                            break
                        end
                    end
                end
                if zone then break end
            end
            if zone then d = x break end
        end
    end
    if not zone then
        -- CColony::TryToAddDistrictFor (0x2885080 / 0x2884e40, not traced): the first district type
        -- (database order) whose `potential` holds and one of whose slots starts with, or allows, a
        -- zone that lists the building: a new district, the zone in that slot [I]
        for _, dd in ipairs(objects.ordered("common/districts")) do
            local dname, ddef = dd[1], dd[2].block
            if holds(ddef, "potential", pid) then
                for i, slot in ipairs(names(ddef, "zone_slots")) do
                    local sb = def("common/zone_slots", slot)
                    local start = sb and defs.field(sb, "start")
                    local zname
                    if start and (not ztype or unq(start) == ztype) and zone_lists(def("common/zones", unq(start)) or {}, bkey, bb) then
                        zname = unq(start)
                    elseif not start then
                        for _, zz in ipairs(objects.ordered("common/zones")) do
                            if (not ztype or zz[1] == ztype) and slot_allows(sb, zz[1], pid) and zone_lists(zz[2].block, bkey, bb) then
                                zname = zz[1]
                                break
                            end
                        end
                    end
                    if zname then
                        local _, nd = create_district(c, dname, ddef)
                        local cells = zone_cells(nd)
                        local zid = objects.ref(cells[i] and cells[i].text) or colony.add_zone(nd, zname, i - 1, false)
                        zone = zid and world.object("zones", zid)
                        break
                    end
                end
            end
            if zone then break end
        end
    end
    if not zone then return nil end
    local id = colony.zone_add_building(zone, bkey)
    colony.rebuild_cache(c)
    return id
end

-- add_building: t = { kind, id, building, zone, district } (CPlanetBuildingEffect<SAddBuildingImpl>
-- 0x37de0a0; a branch office building's owner path is not ported)
function systems.effects.add_building(t)
    local cid = colony_of(t.kind, t.id)
    if not cid then return skipped("add_building", "no colony") end
    if not def("common/buildings", t.building) then return skipped("add_building", "unknown building") end
    local id = colony.add_building(cid, t.building, t.zone, t.district)
    return id and applied("add_building") or skipped("add_building", "no zone")
end

-- remove_building (SRemoveBuildingImpl 0x37e1520 -> CColony::RemoveInternallyOwnedBuildingType): the
-- first building of the type (districts, zones, positions in order), the zone's later positions
-- renumbered, the cache rebuilt [V]
function systems.effects.remove_building(t)
    local cid = colony_of(t.kind, t.id)
    local c = cid and world.object("colony", cid)
    if not c then return skipped("remove_building", "no colony") end
    for _, did in ipairs(district_ids(c)) do
        local d = world.object("districts", did)
        for _, z in ipairs(d and district_zones(d) or {}) do
            local bl = world.field(z[3], "buildings")
            for _, x in ipairs(world.list(bl)) do
                local bid = tonumber(x)
                local b = world.object("buildings", bid)
                if b and unq(world.field(b, "type")) == t.building then
                    world.remove_value(bl, bid)
                    world.remove("buildings", bid)
                    for i, y in ipairs(world.list(bl)) do
                        local ob = world.object("buildings", tonumber(y))
                        if ob then world.set(ob, "position", i - 1) end
                    end
                    colony.rebuild_cache(c)
                    return applied("remove_building")
                end
            end
        end
    end
    return skipped("remove_building", "none of that type")
end

-- ---------------------------------------------------------------------------------------------
-- blockers

local function deposit_type(did)
    local d = world.object("deposit", did)
    return d and unq(world.field(d, "type")), d
end
local function is_blocker_type(key)
    local d = def("common/deposits", key)
    local cat = d and unq(defs.field(d, "category"))
    local cb = cat and def("common/deposit_categories", cat)
    return cb ~= nil and defs.field(cb, "blocker") == "yes"
end
colony.is_blocker_type = is_blocker_type

-- clear_blockers = yes (CClearBlockersEffect 0x3755df0 -> CColonyCarrier::ClearBlockers(false)
-- 0x28da140): each blocker deposit of the carrier, in order: one draw of the game's generator
-- seeding its type's on_cleared (this = the carrier, CDepositType::OnCleared 0x249b040), then the
-- deposit it hid (swap_type) takes its place, or it goes [V]
function systems.effects.clear_blockers(t)
    local pid = planet_of(t.kind, t.id)
    local p = pid and world.object("planet", pid)
    if not p then return skipped("clear_blockers", "no planet") end
    local list = world.field(p, "deposits")
    for _, x in ipairs(world.list(list)) do
        local did = tonumber(x)
        local key, d = deposit_type(did)
        if d and is_blocker_type(key) then
            run_effect(def("common/deposits", key), "on_cleared", pid, objects.draw())
            local swap = world.field(d, "swap_type")
            if swap then
                world.set(d, "type", unq(swap))
                local e = world.token_entry(d, "swap_type")
                if e then world.remove_entry(d, e) end
            else
                world.remove_value(list, did)
                world.remove("deposit", did)
            end
        end
    end
    return applied("clear_blockers")
end

-- add_blocker = { type = <key> blocked_deposit = random | none | <deposit> } (CAddBlockerEffect
-- 0x3754010): a new deposit of the blocker type on the carrier; `random` takes the first deposit
-- the blocker can block (no draw): its type becomes the blocker's swap_type and it goes [V]
-- (CanBeBlockerFor: the blocker's blocker_swap_types list, or any non-blocker [I])
function systems.effects.add_blocker(t)
    local pid = planet_of(t.kind, t.id)
    local p = pid and world.object("planet", pid)
    if not p then return skipped("add_blocker", "no planet") end
    local bd = def("common/deposits", t.blocker)
    if not bd then return skipped("add_blocker", "unknown deposit") end
    local swaps = {}
    for _, n in ipairs(names(bd, "blocker_swap_types")) do swaps[n] = true end
    local function can_block(key)
        if not key or is_blocker_type(key) then return false end
        return next(swaps) == nil or swaps[key] == true
    end
    local blocked
    local list = world.field(p, "deposits")
    if t.blocked == "random" then
        for _, x in ipairs(world.list(list)) do
            local key = deposit_type(tonumber(x))
            if can_block(key) then blocked = tonumber(x) break end
        end
    elseif tonumber(t.blocked) then
        local key = deposit_type(tonumber(t.blocked))
        if can_block(key) then blocked = tonumber(t.blocked) end
    end
    local swap = blocked and deposit_type(blocked)
    local nd = {}
    world.append(nd, "type", t.blocker, true)
    if swap then world.append(nd, "swap_type", swap, true) end
    local h = {}
    world.append(h, "type", 0)
    world.append(h, "id", pid)
    world.append(nd, "deposit_holder", h)
    local id = objects.create("deposit", nd)
    world.append_value(objects.list_of(p, "deposits"), id)
    if blocked then
        world.remove_value(world.field(p, "deposits"), blocked)
        world.remove("deposit", blocked)
    end
    return applied("add_blocker")
end

-- ---------------------------------------------------------------------------------------------
-- pop groups

local function int(v)
    return math.floor(tonumber(v) or 0)
end

-- a country's ethics as its pops take them: a fanatic ethic as its plain one [I]
local function country_ethics(country)
    local out = {}
    local c = country and world.object("country", country)
    for _, e in ipairs(world.list(c and world.path(c, "ethos", "ethics"))) do
        local plain = unq(e):gsub("^ethic_fanatic_", "ethic_")
        local seen = false
        for _, o in ipairs(out) do if o == plain then seen = true end end
        if not seen then out[#out + 1] = plain end
    end
    return out
end
colony.country_ethics = country_ethics

local function group_key(g)
    local key = world.field(g, "key")
    if type(key) ~= "table" then return nil end
    return tonumber(world.field(key, "species")), world.field(key, "category") and unq(world.field(key, "category"))
end

local function index_group(cid, gid)
    local pid = world.colony_planet[cid]
    if not pid then return end
    local l = world.pop_groups_of[pid]
    if not l then l = {}; world.pop_groups_of[pid] = l end
    for _, x in ipairs(l) do if x == gid then return end end
    l[#l + 1] = gid
end

-- the colony's first pop group of a species and category (CColony::AccessOrAddPopGroupAddSize)
local function find_group(c, sid, cat)
    for _, gid in ipairs(world.list(world.field(c, "pop_groups"))) do
        local g = world.object("pop_groups", tonumber(gid))
        if g then
            local s, k = group_key(g)
            if s == sid and k == cat then return tonumber(gid), g end
        end
    end
    return nil
end

-- CGameState::CreateNewPopGroup -> CPopGroup::Initialize (0x1e636c0): the key, the colony, at the
-- end of the colony's groups; the group fields of the 2200.01.11 save (can_* taken as yes,
-- habitability 1, happiness 0.5 until the colonies' daily update [I])
local function new_group(cid, sid, cat)
    local g = {}
    for _, f in ipairs({ "can_procreate", "can_crossbreed", "can_vote", "can_fill_worker_job", "can_fill_specialist_job", "can_fill_ruler_job" }) do
        world.append(g, f, "yes")
    end
    local key = {}
    world.append(key, "species", sid)
    world.append(key, "category", cat, true)
    world.append(g, "key", key)
    world.append(g, "planet", cid)
    world.append(g, "factions", {})
    world.append(g, "wanted_factions", {})
    world.append(g, "size", 0)
    world.append(g, "last_month_growth", 0)
    world.append(g, "month_start_size", 0)
    world.append(g, "habitability", 1)
    world.append(g, "happiness", 0.5)
    local gid = objects.create("pop_groups", g)
    world.append_value(objects.list_of(world.object("colony", cid), "pop_groups"), gid)
    index_group(cid, gid)
    return gid, world.object("pop_groups", gid)
end
colony.new_group = new_group

-- the group's ethos (`ethos = { ethics = { } pops = { } }`): CPopGroup::RandomizeEthics
-- (0x1e6abf0, no draws) splits the group's size over the ethics by their attraction; the
-- attraction (CalcAttractionFor) is not ported: the country's ethics, equal shares, the
-- remainder to the first [I]
local function set_ethos(g, ethics)
    local size = int(world.field(g, "size"))
    local eth = world.field(g, "ethos")
    if type(eth) ~= "table" then
        eth = {}
        world.insert(g, 3, "ethos", eth)
        eth = world.field(g, "ethos")
    end
    world.replace(eth, {})
    local en, ct = {}, {}
    local n = #ethics
    for i, x in ipairs(ethics) do
        en[#en + 1] = { text = x, quoted = true }
        local share = n > 0 and (math.floor(size / n) + ((i <= size % n) and 1 or 0)) or 0
        ct[#ct + 1] = { text = tostring(share) }
    end
    world.append(eth, "ethics", en)
    world.append(eth, "pops", ct)
end

-- the colony's sums the save keeps (num_sapient_pops, species_refs; the colony's daily update
-- recomputes the rest)
local function colony_sums(c)
    local total, seen, order = 0, {}, {}
    for _, gid in ipairs(world.list(world.field(c, "pop_groups"))) do
        local g = world.object("pop_groups", tonumber(gid))
        if g then
            local s = group_key(g)
            total = total + int(world.field(g, "size"))
            if s and not seen[s] then seen[s] = true; order[#order + 1] = s end
        end
    end
    world.set(c, "num_sapient_pops", total)
    local refs = objects.list_of(c, "species_refs")
    world.replace(refs, {})
    for _, s in ipairs(order) do world.append_value(refs, s) end
end
colony.sums = colony_sums

-- CColony::AccessOrAddPopGroupAddSize (0x286a7f0) and what create_pop_group does after: n pops of
-- the key join the colony's first group of it, a new group when there is none. Without a category
-- the key's is the null one and NPlanetJobs::AssignPopsToJobs (0x26b78d0, not ported) moves the
-- colony's pops into the categories of their jobs: the pops go where engine.pops puts new pops
-- (its stand-in: the species' civilian or unemployment group) [I]
function colony.add_pops(cid, sid, n, cat, ethics)
    local c = world.object("colony", cid)
    if not c or n <= 0 then return nil end
    local gid, g
    if cat then
        gid, g = find_group(c, sid, cat)
        if not gid then gid, g = new_group(cid, sid, cat) end
    else
        local pops = require("engine.pops")
        gid = pops.target(cid, sid)
        g = gid and world.object("pop_groups", gid)
        if gid then index_group(cid, gid) end
    end
    if not g then return nil end
    world.set(g, "size", int(world.field(g, "size")) + n)
    world.set(g, "month_start_size", int(world.field(g, "month_start_size")) + n)
    if ethics then
        set_ethos(g, ethics)
    end
    colony_sums(c)
    return gid
end

-- create_pop_group: t = { kind, id, species, size (drawn by the script side), category, ethos (a
-- list, or nil: randomized, i.e. the owner's) } -> the group's id
function systems.effects.create_pop_group(t)
    local cid = colony_of(t.kind, t.id)
    if not cid then return skipped("create_pop_group", "no colony") end
    local sid = tonumber(t.species)
    if not sid or not world.object("species_db", sid) then return skipped("create_pop_group", "no species") end
    local ethics = t.ethos
    if not ethics then
        local pid = world.colony_planet[cid]
        ethics = country_ethics(objects.ref(world.field(world.object("planet", pid), "owner")))
    end
    local gid = colony.add_pops(cid, sid, int(t.size), t.category, ethics)
    if not gid then return skipped("create_pop_group", "not added") end
    return applied("create_pop_group", gid)
end

-- change_planet_size = <int> (CChangePlanetSizeEffect::ExecuteActual 0x3740500): the carrier's size
-- (+0x130) plus the value, on a carrier that is a planet [V]
function systems.effects.change_planet_size(t)
    local pid = planet_of(t.kind, t.id)
    local p = pid and world.object("planet", pid)
    if not p then return skipped("change_planet_size", "no planet") end
    world.set(p, "planet_size", (tonumber(world.field(p, "planet_size")) or 0) + (t.amount or 0))
    return applied("change_planet_size")
end

return colony
