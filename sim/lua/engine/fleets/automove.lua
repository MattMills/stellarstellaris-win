-- engine/fleets/automove.lua : the fleets' auto-movement (SFleetAutoMoveSettings, the save's
-- `auto_movement = { type auto_move_target clear_auto_move_on_arrival clear_on_new_orders
-- destroy_on_arrival has_arrived arrival_effect }`), from the disassembly of 4.5.2 (headless/re
-- notes: actions_wait_automove.md) [V]:
--
--   automove.save_orbit_targets()   CFleet::SaveOrbitTarget (0x2922560) from the fleets' daily Self
--                                   pass: a fleet idle in orbit that can move gets type 1 on its
--                                   planet with clear_on_new_orders (before the serial pass)
--   automove.handle(fid, host)      CFleet::HandleAutoMovement (0x2924cb0), after the fleet's orders
--                                   in its daily serial update
--   automove.on_order(fid)          CFleet::AddOrder: a new order resets a setting with
--                                   clear_on_new_orders
--   automove.to_planet(fid, pid, clear, destroy, effect)   the auto_move_to_planet effect
--   automove.reset(fid)             SFleetAutoMoveSettings::Reset (remove_auto_move_target,
--                                   clear_fleet_actions)
--
-- The fleet targets (auto_move_attack_fleet, auto_move_follow_fleet: armadas, the AI) are kept as
-- they are, not run.

local world = require("engine.world")
local live = require("engine.store.live")

local automove = { stats = { saved = 0, arrivals = 0, orders = 0, resets = 0, effects = 0, draws = 0 } }
local S = automove.stats

local function num(v) return tonumber(v) end
local function fleet(fid) return world.object("fleet", fid) end
local function orders() return package.loaded["engine.fleets.orders"] or require("engine.fleets.orders") end

local function settings(f) local b = world.field(f, "auto_movement"); return type(b) == "table" and b or nil end
local function flag(b, key) return world.field(b, key) == "yes" end

local function remove_block(f)
    for _, e in ipairs(f) do
        if e.op and e.key and e.key.text == "auto_movement" then
            world.remove_entry(f, e)
            return true
        end
    end
    return false
end
function automove.reset(fid)
    local f = fleet(fid)
    if f and remove_block(f) then
        S.resets = S.resets + 1
        live.touch("fleet", fid)
    end
end

-- the fleet's flags (properties) and ship counters
local function property(f, key)
    local p = world.field(f, "properties")
    return type(p) == "table" and world.field(p, key) == "yes"
end
-- CFleet::CanTakeAutoMoveTarget (0x2928a40): mobile and active ships (none removed, or fewer
-- removed than the ships alive)
local function can_take(f)
    if not property(f, "mobile") then return false end
    local ships = #world.list(world.field(f, "ships") or nil)
    local killed = num(world.field(f, "cached_killed_ships")) or 0
    local removed = num(world.field(f, "cached_combined_removed_ships")) or 0
    return ships == 0 or removed <= 0 or removed < ships - killed
end
local function orbit_planet(f)
    local ob = world.path(f, "movement_manager", "orbit", "orbitable")
    return type(ob) == "table" and num(world.field(ob, "planet")) or nil
end
local function in_ftl(f)
    local st = world.path(f, "movement_manager", "state")
    return st == "move_galaxy" or st == "move_wind_up" or st == "move_wind_down"
end
-- an "actual" order: one the fleet was given (not the idle ones)
local function current_order(fid)
    return orders().current(fid)
end

local function write_settings(f, fid, fields)
    remove_block(f)
    local b = {}
    world.append(b, "type", fields.type)
    if fields.target then world.append(b, "auto_move_target", fields.target) end
    if fields.clear then world.append(b, "clear_auto_move_on_arrival", "yes") end
    if fields.clear_on_new_orders then world.append(b, "clear_on_new_orders", "yes") end
    if fields.destroy then world.append(b, "destroy_on_arrival", "yes") end
    if fields.has_arrived then world.append(b, "has_arrived", "yes") end
    if fields.effect then world.append(b, "arrival_effect", fields.effect, true) end
    world.append(f, "auto_movement", b)
    live.touch("fleet", fid)
end

-- CFleet::SaveOrbitTarget, for every fleet in orbit with no order and no auto-movement that can take
-- a target (CFleet::DailyUpdateSelfDontReadOthers 0x2921014; no draws)
function automove.save_orbit_targets()
    for _, fid in ipairs(world.all("fleet")) do
        local f = fleet(fid)
        if f and not settings(f) then
            local pid = orbit_planet(f)
            if pid and world.object("planet", pid) and not current_order(fid) and can_take(f)
                and #world.list(world.field(f, "ships") or nil) > 0 then
                write_settings(f, fid, { type = "auto_move_planet", target = pid, clear_on_new_orders = true })
                S.saved = S.saved + 1
            end
        end
    end
end

-- CFleet::AddOrder: a fleet given an order loses an auto-movement set with clear_on_new_orders
function automove.on_order(fid)
    local f = fleet(fid)
    local b = f and settings(f)
    if b and flag(b, "clear_on_new_orders") then automove.reset(fid) end
end

-- the auto_move_to_planet effect (CFleet::AutoMoveToPlanet 0x294e5a0): no order yet (the next
-- daily HandleAutoMovement makes it); clear_on_new_orders off
function automove.to_planet(fid, pid, clear, destroy, effect)
    local f = fleet(fid)
    if not f or not world.object("planet", pid) or not can_take(f) then return end
    write_settings(f, fid, { type = "auto_move_planet", target = pid, clear = clear or destroy, destroy = destroy,
        effect = effect })
    S.effects = S.effects + 1
end

-- CFleet::HandleAutoMoveArrival (0x2928cf0): once (has_arrived); reset first with
-- clear_auto_move_on_arrival (the arrival effect then not run); three draws, the scopes of the
-- owner (this), the fleet (from) and the planet (fromfrom); on_fleet_auto_move_arrival; the
-- arrival effect (this = the fleet); killed with destroy_on_arrival
local function arrival(fid, f, b, pid, host)
    if flag(b, "has_arrived") then return end
    local clear, destroy = flag(b, "clear_auto_move_on_arrival"), flag(b, "destroy_on_arrival")
    local effect = world.field(b, "arrival_effect")
    world.set(b, "has_arrived", "yes")
    live.touch("fleet", fid)
    if clear then automove.reset(fid); effect = nil end
    RUST.rand(); RUST.rand(); RUST.rand()
    S.draws = S.draws + 3
    S.arrivals = S.arrivals + 1
    local owner = world.fleet_owner and world.fleet_owner[fid]
    local E = package.loaded["simscript.eval"] or require("simscript.eval")
    local events = package.loaded["simscript.events"] or require("simscript.events")
    pcall(events.on_action, "on_fleet_auto_move_arrival", owner and E.S("country", owner) or E.NONE,
        E.new_ctx(E.S("fleet", fid), E.S("planet", pid)))
    if effect and effect ~= "" then
        local name = tostring(effect):gsub('^"(.*)"$', "%1")
        pcall(E.effect, { { key = { text = name }, op = "=", value = { text = "yes" } } },
            E.new_ctx(E.S("fleet", fid), E.S("planet", pid)))
    end
    if destroy then
        require("engine.fleets.create").kill(fid)
    end
end

-- CFleet::HandleAutoMovement (daily, after the fleet's orders)
function automove.handle(fid, host)
    local f = fleet(fid)
    local b = f and settings(f)
    if not b then return end
    local ty = world.field(b, "type")
    if ty == "auto_move_none" then automove.reset(fid); return end
    if not can_take(f) then automove.reset(fid); return end
    if ty ~= "auto_move_planet" then return end
    local pid = num(world.field(b, "auto_move_target"))
    if not pid or not world.object("planet", pid) then automove.reset(fid); return end
    if orbit_planet(f) == pid then
        return arrival(fid, f, b, pid, host)
    end
    -- CFleet::ShouldInitiateAutoMove (0x29290b0): not moving to a point, not in FTL, no order
    local cur = current_order(fid)
    if cur == "move_to_system_point_order" or in_ftl(f) or cur then return end
    S.orders = S.orders + 1
    -- the order is the fleet's own (AddOrder not internal): with clear_on_new_orders the setting
    -- goes at once (the fleet still flies back)
    orders().orbit(fid, pid)
end

function automove.report()
    return string.format("auto-movement: %d orbit targets saved, %d arrivals (%d draws), %d orders, %d effects, %d resets",
        S.saved, S.arrivals, S.draws, S.orders, S.effects, S.resets)
end

return automove
