-- engine/fleets/script.lua : the engine effects the fleet package's script effects push
-- (simscript/handlers/fleet_create.lua): armies and ship designs made by script. Each applier
-- returns the id it made (the handle's: last_created_army, last_created_design) or nil.
--
--   create_army    t = { colony | ship, owner, species, army_type, name } (CCreateArmyEffect [I]): an army in
--                  the colony (or on a ship: t.ship), health and morale 200 x the army type's
--                  `health` / `morale` (the save's: defense_army 1.25 -> 250 [V the save]), in the
--                  owner's `owned_armies` and the colony's `army`
--   create_ship_design  t = { design (a global design's name), country (ftl's) } [I]: a copy of the
--                  global design in the ship_design store

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")

local script = { stats = { armies = 0, designs = 0 } }
local S = script.stats

local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
local function objects() return require("engine.script.objects") end

local BASE_HEALTH, BASE_MORALE = 200, 200

local function army_type(t)
    local d = t and defs.get("common/armies", t)
    return d and d.block
end

function systems.effects.create_army(t)
    local tb = army_type(t.army_type)
    if not tb then return nil end
    local h = BASE_HEALTH * (tonumber(defs.field(tb, "health")) or 1)
    local m = BASE_MORALE * (tonumber(defs.field(tb, "morale")) or 1)
    local a = {}
    if t.name then
        local n = {}
        world.append(n, "key", t.name, true)
        world.append(a, "name", n)
    end
    world.append(a, "type", t.army_type, true)
    world.append(a, "health", string.format("%.5f", h))
    world.append(a, "max_health", string.format("%.5f", h))
    world.append(a, "jump_drive_cooldown", "0.01.01", true)
    if t.owner then world.append(a, "owner", t.owner) end
    if t.species then world.append(a, "species", t.species) end
    if t.colony then world.append(a, "colony", t.colony) end
    if t.ship then world.append(a, "ship", t.ship) end
    if defs.field(tb, "has_morale") ~= "no" then world.append(a, "morale", string.format("%.5f", m)) end
    local aid = objects().create("army", a)
    local c = t.owner and world.object("country", t.owner)
    local owned = c and world.field(c, "owned_armies")
    if c and type(owned) ~= "table" then
        world.append(c, "owned_armies", {})
        owned = world.field(c, "owned_armies")
    end
    if type(owned) == "table" then world.append_value(owned, aid) end
    local col = t.colony and world.object("colony", t.colony)
    if col then
        local l = world.field(col, "army")
        if type(l) ~= "table" then
            world.append(col, "army", {})
            l = world.field(col, "army")
        end
        world.append_value(l, aid)
    end
    if t.ship then
        local s = world.object("ships", t.ship)
        if s then world.set(s, "army", aid) end
    end
    S.armies = S.armies + 1
    return aid
end

-- a design copied (its name, growth stages and flags) into a new ship_design entry
local function copy_block(b)
    local px = require("pdxscript")
    return px.parse(px.write(b), "ship_design")
end
function systems.effects.create_ship_design(t)
    local fleets = objects().fleets
    local src = t.design and fleets and fleets.designs.global(t.design)
    local d = src and world.object("ship_design", src)
    if not d then return nil end
    local did = objects().create("ship_design", copy_block(d))
    S.designs = S.designs + 1
    return did
end

function script.report()
    return string.format("fleet script: %d armies, %d designs made", S.armies, S.designs)
end

return script
