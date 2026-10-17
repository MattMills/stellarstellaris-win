-- engine/fleets/follow.lua : follow_order (CFollowFleetOrder), the order a right click on a fleet
-- gives (CFollowFleetCommand; docs/windows/fleet.md "Right click"): the fleet moves to where the
-- followed fleet is, again whenever it has moved on, until that fleet is gone or the order
-- cancelled. Its block, as the game writes it (WriteMembers 0x29b3210 [V]):
--
--   follow_order = { fleet = <id> coordinate = { x y origin } has_triggered_message = no
--                    attack_when_in_range = yes|no cancelled = no ... }
--
-- coordinate: where the followed fleet was when the move was last set [I]. attack_when_in_range:
-- the follow and attack of a military fleet; the combat itself is not ported (engine.fleets.
-- movement leaves a fleet in combat where it is), so the attack is the follow here [not done].
-- Registered in engine.fleets.orders' TYPES (orders.TYPES.follow_order).

local world = require("engine.world")

local follow = {}

local NO_ID = 4294967295

local function movement()
    local name = "engine.fleets.movement"
    if package.loaded[name] then return package.loaded[name] end
    local ok, m = pcall(require, name)
    return ok and m or nil
end

local function coord(b)
    if type(b) ~= "table" then return nil end
    return { x = tonumber(world.field(b, "x")) or 0, y = tonumber(world.field(b, "y")) or 0, origin = tonumber(world.field(b, "origin")) or NO_ID }
end

local function fleet_coord(f)
    return coord(world.path(f, "movement_manager", "coordinate"))
end

-- within a unit of each other in the same system
local function near(a, b, d)
    return a and b and a.origin == b.origin and (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= (d or 1) ^ 2
end

local function target(o)
    local id = tonumber(world.field(o.block, "fleet"))
    return id, id and world.object("fleet", id)
end

local function set_coordinate(o, c)
    local b = world.field(o.block, "coordinate")
    if type(b) ~= "table" then
        b = world.child(o.block, "coordinate")
    end
    world.set(b, "x", c.x)
    world.set(b, "y", c.y)
    world.set(b, "origin", c.origin)
end

-- the move to the followed fleet: set when the fleet is not there and the followed fleet has
-- moved since the last one (or the fleet is not moving)
local function chase(o, fid, f)
    local _, t = target(o)
    local tc = t and fleet_coord(t)
    local mc = fleet_coord(f)
    if not tc or tc.origin == NO_ID or near(mc, tc) then
        return
    end
    local m = movement()
    if not (m and m.move_to) then
        return
    end
    local last = coord(world.field(o.block, "coordinate"))
    local moving = m.is_moving and m.is_moving(fid)
    if not moving or not near(last, tc) then
        m.move_to(fid, { x = tc.x, y = tc.y, origin = tc.origin })
        set_coordinate(o, tc)
    end
end

follow.order = {
    start = function(o, fid, f) chase(o, fid, f) end,
    tick = function(o, fid, f) chase(o, fid, f) end,
    is_done = function(o)
        local _, t = target(o)
        return t == nil or world.field(o.block, "cancelled") == "yes"
    end,
    finish = function() end,
}

return follow
