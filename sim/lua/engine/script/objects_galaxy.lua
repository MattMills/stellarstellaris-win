-- engine/script/objects_galaxy.lua : the galaxy's objects made or changed by script
-- (prevent_anomaly, create_ambient_object and its set_location, set_planet_entity, set_deposit,
-- add_anomaly, spawn_megastructure, spawn_natural_wormhole, link_wormholes), from the 4.5.2 Linux
-- build (docs/script_objects.md "Galaxy objects"). The draws of an ambient object's place and of a
-- random position are the executing scope's (the script side draws them and passes the values);
-- the game's generator's are made here.

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")
local objects = require("engine.script.objects")

local applied, skipped, unq, NO_ID = objects.applied, objects.skipped, objects.unq, objects.NO_ID
local draw = objects.draw
local FP = 100000

local galaxy = {}
objects.galaxy = galaxy

local function num(v)
    return world.number_text(math.floor(v * FP + (v >= 0 and 0.5 or -0.5)) / FP)
end
local function coord_block(x, y, origin)
    local c = {}
    world.append(c, "x", num(x))
    world.append(c, "y", num(y))
    world.append(c, "origin", origin or NO_ID)
    return c
end
local function coord_of(kind, id)
    local o = world.object(kind, id)
    local c = o and world.field(o, "coordinate")
    if type(c) ~= "table" then return nil end
    return tonumber(world.field(c, "x")) or 0, tonumber(world.field(c, "y")) or 0, objects.ref(world.field(c, "origin"))
end
galaxy.coord_of = coord_of

-- prevent_anomaly = yes/no (0x3750da0): bit 3 of the planet's binary_flags (64 when the save has
-- none) [V]
function systems.effects.prevent_anomaly(t)
    local p = world.object("planet", t.id)
    if not p then return skipped("prevent_anomaly", "no planet") end
    local f = tonumber(world.field(p, "binary_flags")) or 64
    local base = f - (math.floor(f / 8) % 2) * 8
    world.set(p, "binary_flags", base + (t.value and 8 or 0))
    return applied("prevent_anomaly")
end

-- add_anomaly = { category = <key> target = <country> } (0x373d030): the planet's `anomaly` [V]
function systems.effects.add_anomaly(t)
    local p = world.object("planet", t.id)
    if not p then return skipped("add_anomaly", "no planet") end
    if world.field(p, "anomaly") ~= nil then world.set(p, "anomaly", t.category)
    else world.append(p, "anomaly", t.category, true) end
    return applied("add_anomaly")
end

-- set_planet_entity = { entity graphical_culture picture atmosphere_* } (0x377f830): the planet's
-- entity_name (a culture's asset name not ported: the name as given), picture override [V]
function systems.effects.set_planet_entity(t)
    local p = world.object("planet", t.id)
    if not p then return skipped("set_planet_entity", "no planet") end
    if t.entity then
        if world.field(p, "entity_name") ~= nil then world.set(p, "entity_name", t.entity)
        else world.append(p, "entity_name", t.entity, true) end
    end
    if t.picture then
        if world.field(p, "picture") ~= nil then world.set(p, "picture", t.picture)
        else world.append(p, "picture", t.picture, true) end
    end
    return applied("set_planet_entity")
end

-- set_deposit = <key | random> (0x3755860): every deposit of the planet goes
-- (CColonyCarrier::ClearDeposits), then one of the type (CreateNewDeposit, engine.script.creation's
-- add_deposit); random draws once and picks through CDepositTypesDatabase::Randomize (not ported:
-- the deposits cleared only)
function systems.effects.set_deposit(t)
    local p = world.object("planet", t.id)
    if not p then return skipped("set_deposit", "no planet") end
    systems.effects.clear_deposits({ kind = "planet", id = t.id })
    if t.deposit == "random" then
        draw()
        return skipped("set_deposit", "random")
    end
    systems.effects.add_deposit({ kind = "planet", id = t.id, deposit = t.deposit })
    return applied("set_deposit")
end

-- ---------------------------------------------------------------------------------------------
-- ambient objects

-- the ambient object's system list (CGalacticObject::AddAmbientObject: at the end)
local function attach_to_system(aid, sys, old)
    if old and old ~= sys then
        local g = world.object("galactic_object", old)
        local l = g and world.field(g, "ambient_object")
        if type(l) == "table" then world.remove_value(l, aid) end
    end
    local g = sys and world.object("galactic_object", sys)
    if g then
        local l = objects.list_of(g, "ambient_object")
        for _, x in ipairs(world.list(l)) do if tonumber(x) == aid then return end end
        world.append_value(l, aid)
    end
end

-- create_ambient_object: t = { type, x, y, origin, offset = { x, y, z }, attach = { kind, id },
-- scale, entity_scale_to_size } -> id (CGameState::CreateNewAmbientObject 0x1b4b2c0; the save form
-- of the 2200.01.11 save's ambient objects) [V]
function systems.effects.create_ambient_object(t)
    local a = {}
    world.append(a, "coordinate", coord_block(t.x, t.y, t.origin))
    world.append(a, "data", t.data, true)
    local props = {}
    world.append(props, "coordinate", coord_block(t.x, t.y, t.origin))
    local att = {}
    world.append(att, "type", t.attach and t.attach.type or 10)
    world.append(att, "id", t.attach and t.attach.id or NO_ID)
    world.append(props, "attach", att)
    local off = {}
    for _, v in ipairs({ t.offset and t.offset.x or 0, t.offset and t.offset.y or 0, t.offset and t.offset.z or 0 }) do
        off[#off + 1] = { text = num(v) }
    end
    world.append(props, "offset", off)
    world.append(props, "scale", num(t.scale or 1))
    local face = {}
    world.append(face, "type", 10)
    world.append(face, "id", NO_ID)
    world.append(props, "entity_face_object", face)
    if t.entity_scale_to_size then world.append(props, "entity_scale_to_size", "yes") end
    world.append(props, "appear_state", t.appear_state or "", true)
    world.append(a, "properties", props)
    local id = objects.create("ambient_object", a)
    attach_to_system(id, t.origin, nil)
    return applied("create_ambient_object", id)
end

-- set_location of an ambient object (CSetLocationEffect, scope type 0x400): the target's place
-- moved by distance at the angle (random: one draw of the game's generator, (r % 100000) / 1e5 x
-- 360 degrees); CAmbientObject::SetCoordinate (the system lists) [V]
function systems.effects.set_ambient_location(t)
    local a = world.object("ambient_object", t.id)
    if not a then return skipped("set_location", "no ambient object") end
    local x, y, sys = coord_of(t.target.kind, t.target.id)
    if not x then return skipped("set_location", "no target place") end
    local deg = t.angle or 0
    if t.random_angle then deg = (draw() % 100000) / 100000 * 360 end
    local r = math.rad(deg)
    local d = t.distance or 0
    x, y = x + d * math.cos(r), y + d * math.sin(r)
    local _, _, old = coord_of("ambient_object", t.id)
    for _, blk in ipairs({ world.field(a, "coordinate"), world.path(a, "properties", "coordinate") }) do
        if type(blk) == "table" then
            world.set(blk, "x", num(x))
            world.set(blk, "y", num(y))
            world.set(blk, "origin", sys or NO_ID)
        end
    end
    attach_to_system(t.id, sys, old)
    return applied("set_location")
end

-- ---------------------------------------------------------------------------------------------
-- megastructures and bypasses

local function new_bypass(btype, owner_type, owner_id, active)
    local b = {}
    world.append(b, "type", btype, true)
    world.append(b, "active", active and "yes" or "no")
    world.append(b, "connections", {})
    local o = {}
    world.append(o, "type", owner_type)
    world.append(o, "id", owner_id)
    world.append(b, "owner", o)
    world.append(b, "lock_country", NO_ID)
    world.append(b, "lock_remaining_days", -1)
    world.append(b, "is_manual_lock", "no")
    return objects.create("bypasses", b)
end

-- the bypasses of a type connected to each other (the gateways' network: connections = the others
-- of that type) [I]
local function connect_all(btype)
    local ids = {}
    for _, bid in ipairs(world.all("bypasses")) do
        if unq(world.field(world.object("bypasses", bid), "type")) == btype then ids[#ids + 1] = bid end
    end
    for _, a in ipairs(ids) do
        local b = world.object("bypasses", a)
        local cl = objects.list_of(b, "connections")
        world.replace(cl, {})
        for _, o in ipairs(ids) do
            if o ~= a then world.append_value(cl, o) end
        end
    end
end

-- spawn_megastructure: t = { type, x, y, origin, owner, planet, name } (CGameState::CreateNewMegaStructure
-- 0x1b48340, CMegaStructure::Initialize 0x2a35bc0: the system's list, the planet's
-- `megastructure`, a bypass for a type with one), then OnBuildComplete's five draws and the
-- init_effect's draw (the script side runs it) [V]
function systems.effects.spawn_megastructure(t)
    local md = defs.get("common/megastructures", t.mtype)
    if not md then return skipped("spawn_megastructure", "unknown type") end
    local m = {}
    world.append(m, "type", t.mtype, true)
    world.append(m, "coordinate", coord_block(t.x, t.y, t.origin))
    if t.owner then world.append(m, "owner", t.owner) end
    world.append(m, "planet", t.planet or NO_ID)
    world.append(m, "orbitals", {})
    world.append(m, "build_queue", NO_ID)
    world.append(m, "dismantle_progress", 0)
    world.append(m, "dismantle_finish_date", "0.01.01", true)
    local id = objects.create("megastructures", m)
    local mb = world.object("megastructures", id)
    local btype = unq(defs.field(md.block, "bypass_type"))
    if btype then
        local bid = new_bypass(btype, 6, id, false)
        world.insert(mb, 5, "bypass", bid)
        local g = world.object("galactic_object", t.origin)
        if g then world.append_value(objects.list_of(g, "bypasses"), bid) end
        connect_all(btype)
    end
    local g = world.object("galactic_object", t.origin)
    if g then world.append_value(objects.list_of(g, "megastructures"), id) end
    if t.planet then
        local p = world.object("planet", t.planet)
        if p then
            if world.field(p, "megastructure") ~= nil then world.set(p, "megastructure", id)
            else world.append(p, "megastructure", id) end
        end
    end
    for _ = 1, 5 do draw() end
    return applied("spawn_megastructure", id)
end

-- spawn_natural_wormhole: t = { type, x, y, origin, entity } (CGameState::CreateNewWormhole
-- 0x1b484b0: the system's list, its bypass (owner type 7)) [V]
function systems.effects.spawn_natural_wormhole(t)
    local w = {}
    world.append(w, "coordinate", coord_block(t.x, t.y, t.origin))
    local id = objects.create("natural_wormholes", w)
    local wb = world.object("natural_wormholes", id)
    local bid = new_bypass(t.btype or "wormhole", 7, id, true)
    world.append(wb, "bypass", bid)
    world.append(wb, "graphics_entity_name", t.entity or "", true)
    local g = world.object("galactic_object", t.origin)
    if g then
        world.append_value(objects.list_of(g, "natural_wormholes"), id)
        world.append_value(objects.list_of(g, "bypasses"), bid)
    end
    return applied("spawn_natural_wormhole", bid)
end

-- link_wormholes: two systems' first wormholes' bypasses (or two bypasses) linked both ways
-- (CGameState::LinkWormholes 0x1b3f350: linked_to, and the connections) [V]
local function bypass_of(kind, id)
    if kind == "bypass" then return id end
    if kind == "system" then
        local g = world.object("galactic_object", id)
        local wid = tonumber(world.list(g and world.field(g, "natural_wormholes"))[1])
        local w = wid and world.object("natural_wormholes", wid)
        return w and tonumber(world.field(w, "bypass"))
    end
    return nil
end
function systems.effects.link_wormholes(t)
    local a, b = bypass_of(t.kind, t.id), bypass_of(t.target.kind, t.target.id)
    local ab, bb = a and world.object("bypasses", a), b and world.object("bypasses", b)
    if not ab or not bb then return skipped("link_wormholes", "no wormhole") end
    for _, x in ipairs({ { ab, b }, { bb, a } }) do
        local blk, other = x[1], x[2]
        if world.field(blk, "linked_to") ~= nil then world.set(blk, "linked_to", other)
        else world.insert(blk, 3, "linked_to", other) end
        local cl = objects.list_of(blk, "connections")
        world.replace(cl, {})
        world.append_value(cl, other)
        local acl = world.field(blk, "active_connections")
        if type(acl) ~= "table" then acl = world.child(blk, "active_connections") end
        world.replace(acl, {})
        world.append_value(acl, other)
    end
    return applied("link_wormholes")
end

return galaxy
