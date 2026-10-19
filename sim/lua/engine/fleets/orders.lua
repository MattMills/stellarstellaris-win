-- engine/fleets/orders.lua : fleet orders, the way the game keeps and runs them (GOG 4.5.2,
-- docs/fleet_orders.md): one current order and a queue per fleet, in the save's own form:
--
--   fleet = { ... order_id = <the next order id>
--             current_order = { <type> = { <its fields> sub_order = { <type> = { ... } }
--                                          can_reach order_id commissioner } }
--             order = { <type> = { ... } <type> = { ... } ... } ... }
--
-- Each day (CFleet::DailyUpdateSerial -> CFleet::HandleOrders, the fleets' serial part of the daily
-- ships_fleets_armies phase), fleet by fleet in the database's order:
--   - no current order: the first queued one starts (CFleet::StartFirstQueuedOrder);
--   - while the current order should be cancelled: cancelled, the next one started;
--   - not done: ticked (TickOrder); done (now or after the tick): finished (Finish), the next one
--     started the same day.
-- Starting an order (StartFirstQueuedOrder): out of the queue, StartOrder, then for a civilian fleet
-- with ships two draws and on_ship_order (this = the head ship, from = the country).
--
-- API (for the AI and the engine):
--   orders.issue(fleet_id, order[, opts]) -> order id | false
--       order: the save's form, a block `{ survey_planet_order = { deposit_holder = { type = 0
--       id = 12 } } }` (a parsed block, or the Lua table orders.block turns into one); opts.front:
--       in front of the queue, the current order pushed back (CFleet::AddOrder's flag), else at the
--       queue's end. The order gets the fleet's next order_id; can_reach / commissioner are added
--       as the game writes them. Starts at once when the fleet has no current order.
--   orders.survey(fleet_id, planet_id[, opts])          survey_planet_order
--   orders.research_anomaly(fleet_id, planet_id[, opts]) research_anomaly_order
--   orders.orbit(fleet_id, planet_id[, opts])           orbit_planet_order
--   orders.move_to(fleet_id, { x, y, origin }[, opts])  move_to_system_point_order
--   orders.current(fleet_id) -> type, block | nil;  orders.queue(fleet_id) -> { { type, block } }
--   orders.cancel_current(fleet_id), orders.clear(fleet_id)
--   orders.daily(host, date)        the day of every fleet's orders (wired in engine.systems)
--   orders.TYPES[type] = { start, tick, is_done, finish, should_cancel, is_possible }
--
-- Order types: survey_planet_order and research_anomaly_order (engine.fleets.survey);
-- orbit_planet_order and move_to_system_point_order (here; the movement itself is
-- engine.fleets.movement's when it is there: without it a move is done only where the fleet is
-- already); build_orbital_station_order (the progress; the station it builds not modelled);
-- aggressive_stance_fleet_order, colonize_planet_order, excavate_archaeological_site_fleet_order
-- and the others: kept as they are, counted.

local world = require("engine.world")
local eval = require("simscript.eval")
local live = require("engine.store.live")   -- the store's copy of what exploration reads (docs/data_layer.md)
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)

local orders = {
    stats = { days = 0, ticked = {}, finished = {}, started = {}, cancelled = 0, issued = 0, refused = 0,
              not_modelled = {}, ship_order_events = 0, stations_not_built = 0, entered_orbit = 0, left_orbit = 0 },
}
local S = orders.stats
local NO_ID = 4294967295
local ONE = 100000

local function count(t, k)
    t[k] = (t[k] or 0) + 1
end

-- ---------------------------------------------------------------------------------------------
-- the save's form

local function entry(key, value)
    return { key = { text = key }, op = "=", value = value }
end

local function find_entry(block, key)
    for i, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e, i
        end
    end
    return nil
end

local function remove_key(block, key)
    local e = find_entry(block, key)
    if e then
        world.remove_entry(block, e)
    end
end

-- the first `type = { }` statement of a block: type, its block, the statement
local function first_order(block)
    if type(block) ~= "table" then
        return nil
    end
    for _, e in ipairs(block) do
        if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
            return e.key.text, e.value, e
        end
    end
    return nil
end

local function number_text(v)
    return world.number_text(v)
end

-- orders.block(t) -> a parsed block from a Lua table: { key = value | { ... } }, an array part for
-- the statements in order ({ "key", value } pairs), numbers written as the save writes them
function orders.block(t)
    if type(t) ~= "table" then
        return t
    end
    if t[1] ~= nil and type(t[1]) == "table" and t[1].op then
        return t -- already a parsed block
    end
    local b = {}
    local function add(k, v)
        if type(v) == "table" then
            b[#b + 1] = entry(k, orders.block(v))
        else
            b[#b + 1] = entry(k, { text = type(v) == "number" and number_text(v) or tostring(v) })
        end
    end
    for _, kv in ipairs(t) do
        if type(kv) == "table" and kv[1] then add(kv[1], kv[2]) end
    end
    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do add(k, t[k]) end
    return b
end

local function fleet(fid)
    return world.object("fleet", fid)
end

-- an order handle: { type, block, holder = the block holding its statement, entry }
local function handle(holder, e)
    return { type = e.key.text, block = e.value, holder = holder, entry = e }
end

local function current_handle(f)
    local cur = world.field(f, "current_order")
    local ty, b, e = first_order(cur)
    if ty then
        return handle(cur, e)
    end
    return nil
end

local function queue_block(f, create)
    local q = world.field(f, "order")
    if type(q) == "table" then
        return q
    end
    if not create then
        return nil
    end
    q = {}
    -- after current_order (or order_id, or the movement manager), as the game writes it
    local _, pos = find_entry(f, "current_order")
    if not pos then _, pos = find_entry(f, "order_id") end
    if not pos then _, pos = find_entry(f, "movement_manager") end
    world.insert(f, (pos or #f) + 1, "order", q)
    return q
end

local function queue_handles(f)
    local q = queue_block(f, false)
    local out = {}
    for _, e in ipairs(q or {}) do
        if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
            out[#out + 1] = handle(q, e)
        end
    end
    return out
end

function orders.current(fid)
    local f = fleet(fid)
    local h = f and current_handle(f)
    if h then
        return h.type, h.block
    end
    return nil
end

function orders.queue(fid)
    local f = fleet(fid)
    local out = {}
    for _, h in ipairs(f and queue_handles(f) or {}) do
        out[#out + 1] = { h.type, h.block }
    end
    return out
end

-- every statement of a block taken out (through the world, which keeps its field index)
local function empty(block)
    for i = #block, 1, -1 do
        world.remove_entry(block, block[i])
    end
end

-- the fleet's current order set to the order `ty = block` (nil: none, the field removed)
local function set_current(f, ty, block)
    if ty == nil then
        remove_key(f, "current_order")
        return nil
    end
    local cur = world.field(f, "current_order")
    if type(cur) ~= "table" then
        cur = {}
        local _, pos = find_entry(f, "order_id")
        if not pos then _, pos = find_entry(f, "movement_manager") end
        world.insert(f, (pos or #f) + 1, "current_order", cur)
    end
    empty(cur)
    world.append(cur, ty, block)
    return handle(cur, cur[#cur])
end

local function drop_empty_queue(f)
    local q = queue_block(f, false)
    if q and #queue_handles(f) == 0 then
        remove_key(f, "order")
    end
end

-- ---------------------------------------------------------------------------------------------
-- the fleet's state the orders read

local function ships_of(f)
    local out = {}
    for _, t in ipairs(world.list(world.field(f, "ships"))) do
        out[#out + 1] = tonumber(t)
    end
    return out
end

local function property(f, name)
    local p = world.field(f, "properties")
    return type(p) == "table" and world.field(p, name) == "yes"
end

local function mm_of(f)
    local mm = world.field(f, "movement_manager")
    return type(mm) == "table" and mm or nil
end

local function coord(b)
    if type(b) ~= "table" then
        return nil
    end
    return { x = tonumber(world.field(b, "x")) or 0, y = tonumber(world.field(b, "y")) or 0,
             origin = tonumber(world.field(b, "origin")) }
end

local function movement()
    local name = "engine.fleets.movement"
    if package.loaded[name] then
        return package.loaded[name]
    end
    if package.searchpath(name, package.path) then
        local ok, m = pcall(require, name)
        if ok then return m end
    end
    return nil
end

-- what the fleet orbits (movement_manager.orbit.orbitable = { planet = id } or { starbase = id }):
-- kind, id, its slot
local function orbitable_of(f)
    local mm = mm_of(f)
    local o = mm and world.field(mm, "orbit")
    local ob = type(o) == "table" and world.field(o, "orbitable")
    if type(ob) ~= "table" then
        return nil
    end
    for _, k in ipairs({ "planet", "starbase" }) do
        local id = tonumber(world.field(ob, k))
        if id then
            return k, id, tonumber(world.field(o, "index"))
        end
    end
    return nil
end
-- the planet the fleet orbits, its slot
local function orbit_of(f)
    local k, id, index = orbitable_of(f)
    if k == "planet" then
        return id, index
    end
    return nil
end

-- the fleet in orbit of the planet and idle (CFleet orbit target and CFleetMovementManager state)
function orders.in_orbit_of(fid, f, pid)
    local p = orbit_of(f)
    if p ~= pid then
        return false
    end
    local m = movement()
    if m and m.is_moving and m.is_moving(fid) then
        return false
    end
    local mm = mm_of(f)
    local state = mm and world.field(mm, "state")
    return state == nil or state == "move_idle"
end

-- the slot coordinate of a planet's orbit (COrbitalSlotHandleBase::CalcFreeOrbitCoordinateInternal,
-- [I] from the saves: slot 0 at + (0.33 size + 2.7) on both axes; other slots turned by 90 degrees)
local function orbit_coordinate(pid, index)
    local p = world.object("planet", pid)
    local c = coord(world.field(p, "coordinate"))
    if not c then
        return nil
    end
    local d = 0.33 * (tonumber(world.field(p, "planet_size")) or 10) + 2.7
    local dirs = { { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }
    local dir = dirs[(index or 0) % 4 + 1]
    return { x = c.x + dir[1] * d, y = c.y + dir[2] * d, origin = c.origin }
end

local function free_slot(p)
    local used = {}
    local po = world.field(p, "planet_orbitals")
    for _, e in ipairs(type(po) == "table" and po or {}) do
        if e.op and e.key and tonumber(e.key.text) then used[tonumber(e.key.text)] = true end
    end
    local i = 0
    while used[i] do i = i + 1 end
    return i
end

-- a starbase's system star (the system's first planet), and the starbase's orbit coordinate:
-- [I] from the saves, the star's coordinate + (d + 9, -(d + 9)), d = 0.33 size + 2.7
local function starbase_system(sbid)
    for _, sys in ipairs(world.all("galactic_object")) do
        slice.tick("fleets/orders.lua:333")
        for _, v in ipairs(world.list(world.field(world.object("galactic_object", sys), "starbases"))) do
            if tonumber(v) == sbid then return sys end
        end
    end
    return nil
end
local function starbase_orbit_coordinate(sbid)
    local sys = starbase_system(sbid)
    local g = sys and world.object("galactic_object", sys)
    local star = g and world.object("planet", tonumber(world.field(g, "planet")))
    local c = star and coord(world.field(star, "coordinate"))
    if not c then
        return nil
    end
    local d = 0.33 * (tonumber(world.field(star, "planet_size")) or 20) + 2.7 + 9
    return { x = c.x + d, y = c.y - d, origin = c.origin }
end

-- NScriptUtil::OnFleetEnterOrbit / OnFleetLeaveOrbit<CPlanet / CStarbase> (Linux 0x2a72aa0,
-- 0x2a72c80): two draws for the scopes (the orbitable, the fleet), then the fleet on_action
-- on_fleet_enter_orbit / on_fleet_leave_orbit (this = the fleet, from = the orbitable) [V]. Made by
-- CPlanet::OnFleetEnteredOrbit for every fleet entering a planet's orbit and by CPlanet::LeaveOrbit
-- for every fleet that was in it (its orbital bombardment check between draws nothing)
local function orbit_event(name, fid, kind, id)
    RUST.rand()
    RUST.rand()
    S.orbit_events = (S.orbit_events or 0) + 1
    local events = package.loaded["simscript.events"] or require("simscript.events")
    pcall(events.on_action, name, eval.S("fleet", fid), eval.new_ctx(eval.S(kind == "starbase" and "starbase" or "planet", id)))
end
orders.orbit_event = orbit_event

-- COrbitalSlotHandleBase::EnterOrbit: a planet's first free slot (planet_orbitals = { <slot> =
-- <fleet> }, movement_manager.orbit = { orbitable = { planet } index }); a starbase's (orbitable =
-- { starbase } index = -1)
function orders.enter_orbit(fid, f, id, kind)
    kind = kind or "planet"
    local mm = mm_of(f)
    local p = kind == "planet" and world.object("planet", id)
    if not mm or (kind == "planet" and not p) or (kind == "starbase" and not world.object("starbases", id)) then
        return false
    end
    orders.leave_orbit(fid, f)
    local slot = -1
    live.touch("fleet", fid)
    if p then
        slot = free_slot(p)
        world.append(world.child(p, "planet_orbitals"), tostring(slot), fid)
    end
    local o = world.field(mm, "orbit")
    if type(o) ~= "table" then
        o = world.child(mm, "orbit")
    end
    empty(o)
    local ob = {}
    world.append(ob, kind, id)
    world.append(o, "orbitable", ob)
    world.append(o, "index", slot)
    S.entered_orbit = S.entered_orbit + 1
    orbit_event("on_fleet_enter_orbit", fid, kind, id)
    return true
end

-- CPlanet::LeaveOrbit / COrbitalSlotHandleBase::LeaveOrbit: out of the planet's slot, the orbit
-- block emptied
function orders.leave_orbit(fid, f)
    local kind, pid = orbitable_of(f)
    if not kind then
        return false
    end
    local p = kind == "planet" and world.object("planet", pid)
    local po = p and world.field(p, "planet_orbitals")
    if type(po) == "table" then
        for i = #po, 1, -1 do
            local e = po[i]
            if e.op and tonumber(e.value.text) == fid then
                world.remove_entry(po, e)
            end
        end
    end
    local o = world.field(mm_of(f), "orbit")
    if type(o) == "table" then
        empty(o)
    end
    S.left_orbit = S.left_orbit + 1
    live.touch("fleet", fid)
    orders.orbit_event("on_fleet_leave_orbit", fid, kind, pid)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- sub-orders

local function sub_order(o)
    local s = world.field(o.block, "sub_order")
    local ty, b, e = first_order(s)
    if ty then
        return handle(s, e)
    end
    return nil
end

-- CFleetOrder::ClearSubOrder
function orders.clear_sub_order(o)
    remove_key(o.block, "sub_order")
end

local function set_sub_order(o, ty, block)
    orders.clear_sub_order(o)
    local s = {}
    s[1] = entry(ty, block)
    -- before can_reach (the base class's fields come after the order's own)
    local _, pos = find_entry(o.block, "can_reach")
    world.insert(o.block, pos or (#o.block + 1), "sub_order", s)
    return handle(s, s[1])
end

local function coordinate_block(c)
    local b = {}
    world.append(b, "x", c.x)
    world.append(b, "y", c.y)
    world.append(b, "origin", c.origin or NO_ID)
    return b
end

local function base_fields(b, order_id)
    world.append(b, "can_reach", "yes")
    if order_id then world.append(b, "order_id", order_id) end
    world.append(b, "commissioner", NO_ID)
end

local function near(a, b)
    return a and b and a.origin == b.origin and math.abs(a.x - b.x) < 0.01 and math.abs(a.y - b.y) < 0.01
end

-- CMoveToSystemPointFleetOrder::IsDone (Linux 0x29a3a70): in the target's system and less than 1.0
-- from it (CCelestialDistance::IsLessThan(CFixedPoint 100000)) [V]; the movement stops within that
-- distance of its last node, short of the point itself
local function arrived_at(a, b)
    if not (a and b and a.origin == b.origin) then
        return false
    end
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy < 1
end

local TYPES = {}
orders.TYPES = TYPES

-- move_to_system_point_order (CMoveToSystemPointFleetOrder): the movement manager moves the fleet;
-- done when it is at the coordinate (IsDone 0xcdad20)
local move_order = {}
TYPES.move_to_system_point_order = move_order
function move_order.target(o)
    return coord(world.field(o.block, "coordinate"))
end
function move_order.start(o, fid, f)
    local m = movement()
    local t = move_order.target(o)
    -- CFleetMovementManager::OnMoveOrderChanged (0x298db90): a fleet in orbit given a move
    -- elsewhere leaves the orbit at once (CPlanet::LeaveOrbit: its two draws, on_fleet_leave_orbit)
    if t and orbitable_of(f) and not arrived_at(coord(world.field(mm_of(f), "coordinate")), t) then
        orders.leave_orbit(fid, f)
    end
    if m and m.move_to and t then
        m.move_to(fid, { x = t.x, y = t.y, origin = t.origin })
    end
end
function move_order.is_done(o, fid, f)
    local t = move_order.target(o)
    local m = movement()
    if m and m.arrived then
        local ok, a = pcall(m.arrived, fid)
        if ok and a then
            local here = coord(world.field(mm_of(f), "coordinate"))
            if not here or arrived_at(here, t) then return true end
        end
        if ok and m.is_moving and m.is_moving(fid) then return false end
    end
    local here = coord(world.field(mm_of(f), "coordinate"))
    if arrived_at(here, t) then
        return true
    end
    -- a move from another system that ends further out (the movement idle off its point): the
    -- last leg again, in the system [I]
    if m and m.move_to and t and here and here.origin == t.origin and not (m.is_moving and m.is_moving(fid)) then
        m.move_to(fid, { x = t.x, y = t.y, origin = t.origin })
    end
    return false
end
function move_order.tick() end
function move_order.finish() end

-- orbit_planet_order (COrbitPlanetFleetOrder): a move to the planet's free orbit slot (made at the
-- first tick), then EnterOrbit; done in orbit (IsDone 0xcdc150: CFleetMovementManager::IsInOrbit)
local orbit_order = {}
TYPES.orbit_planet_order = orbit_order
-- the orbitable: kind (planet / starbase), id
function orbit_order.target(o)
    local ob = world.field(o.block, "orbitable")
    for _, k in ipairs({ "planet", "starbase" }) do
        local id = tonumber(world.field(ob, k))
        if id then return k, id end
    end
    return nil
end
function orbit_order.planet(o)
    local k, id = orbit_order.target(o)
    return k == "planet" and id or nil
end
local function orbiting(f, kind, id)
    local k, i = orbitable_of(f)
    return k ~= nil and k == kind and i == id
end
function orbit_order.is_done(o, fid, f)
    local kind, id = orbit_order.target(o)
    return kind ~= nil and orbiting(f, kind, id)
end
function orbit_order.tick(o, fid, f)
    local kind, id = orbit_order.target(o)
    if not kind or orbiting(f, kind, id) then
        return
    end
    local p = kind == "planet" and world.object("planet", id)
    if kind == "planet" and not p then
        return
    end
    local sub = sub_order(o)
    if sub and sub.type == "move_to_system_point_order" then
        if move_order.is_done(sub, fid, f) then
            orders.clear_sub_order(o)
            orders.enter_orbit(fid, f, id, kind)
        end
        return
    end
    -- TickOrder (0xcdb660): out of another orbit, a move to the free slot's coordinate
    orders.leave_orbit(fid, f)
    local t = p and orbit_coordinate(id, free_slot(p)) or (kind == "starbase" and starbase_orbit_coordinate(id))
    if not t then
        return
    end
    local b = {}
    world.append(b, "coordinate", coordinate_block(t))
    base_fields(b, nil)
    local h = set_sub_order(o, "move_to_system_point_order", b)
    move_order.start(h, fid, f)
    if move_order.is_done(h, fid, f) then
        orders.clear_sub_order(o)
        orders.enter_orbit(fid, f, id, kind)
    end
end
function orbit_order.start(o, fid, f)
    orbit_order.tick(o, fid, f)
end
function orbit_order.finish() end

-- the star of a planet's system (its first planet), for orbit_planet_order.star
local function star_of(pid)
    local p = world.object("planet", pid)
    local sys = p and tonumber(world.field(world.field(p, "coordinate"), "origin"))
    local g = sys and world.object("galactic_object", sys)
    local first = g and world.field(g, "planet")
    return tonumber(first)
end

-- an order's orbit sub-order ticked, or made and started (the survey's, the anomaly's: a planet;
-- the return's: a starbase, kind "starbase")
function orders.tick_orbit_sub_order(o, fid, f, pid, kind)
    kind = kind or "planet"
    local sub = sub_order(o)
    if sub and sub.type == "orbit_planet_order" then
        local k, id = orbit_order.target(sub)
        if k == kind and id == pid then
            orbit_order.tick(sub, fid, f)
            return
        end
    end
    local b = {}
    local ob = {}
    world.append(ob, kind, pid)
    world.append(b, "orbitable", ob)
    local star
    if kind == "planet" then
        star = star_of(pid)
    else
        local sys = starbase_system(pid)
        local g = sys and world.object("galactic_object", sys)
        star = g and tonumber(world.field(g, "planet"))
    end
    if star then
        local sb = {}
        world.append(sb, "planet", star)
        world.append(b, "star", sb)
    end
    world.append(b, "merge_fleet", "none")
    base_fields(b, nil)
    local h = set_sub_order(o, "orbit_planet_order", b)
    orbit_order.start(h, fid, f)
end

-- build_orbital_station_order (CBuildOrbitalStationFleetOrder): progress +=
-- CONSTRUCTION_SHIP_WORK_SPEED_MULT a day in position, done at 100 (CFleetOrder::GetNeededProgress
-- 0x1b1140); the station's creation (Finish 0xce0290) not modelled: counted
local station_order = {}
TYPES.build_orbital_station_order = station_order
local function station_speed()
    local defs = require("engine.defs")
    local g = defs.get("common/defines", "NGameplay")
    local v = g and tonumber(defs.field(g.block, "CONSTRUCTION_SHIP_WORK_SPEED_MULT"))
    return math.floor((v or 1) * ONE + 0.5)
end
local function station_progress(o)
    return math.floor((tonumber(world.field(o.block, "progress")) or 0) * ONE + 0.5)
end
function station_order.is_done(o)
    return station_progress(o) >= 100 * ONE
end
-- the order's start, tick and finish are engine.fleets.stations' when it is there (the cost paid,
-- the move to the build position, the station created: docs/stations.md)
local function stations()
    local name = "engine.fleets.stations"
    -- STELLAR_STATIONS=off: the order's progress only, nothing built (a comparison without them)
    if os.getenv("STELLAR_STATIONS") == "off" then
        return nil
    end
    if package.loaded[name] then
        return package.loaded[name]
    end
    if package.searchpath(name, package.path) then
        local ok, m = pcall(require, name)
        if ok then return m end
    end
    return nil
end
function station_order.tick(o, fid, f)
    local st = stations()
    if st then
        return st.order.tick(o, fid, f, orders)
    end
    local sub = sub_order(o)
    if sub then
        local T = TYPES[sub.type]
        if T and T.is_done and T.is_done(sub, fid, f) then
            orders.clear_sub_order(o)
        else
            if T and T.tick then T.tick(sub, fid, f, orders) end
            return
        end
    end
    world.set(o.block, "progress", (station_progress(o) + station_speed()) / ONE)
end
function station_order.start(o, fid, f, _, host)
    local st = stations()
    if st then
        return st.order.start(o, fid, f, orders, host)
    end
end
function station_order.should_cancel(o, fid, f, _, host)
    local st = stations()
    if st and st.order.should_cancel then
        return st.order.should_cancel(o, fid, f, orders, host)
    end
    return false
end
function station_order.finish(o, fid, f, _, host)
    local st = stations()
    if st then
        return st.order.finish(o, fid, f, orders, host)
    end
    S.stations_not_built = S.stations_not_built + 1
end

-- return_fleet_order (CReturnFleetOrder, [I] from the saves: `exclude_allied home_base` and an
-- orbit sub-order of a starbase): to the starbase of its country's capital system, done in its
-- orbit
local return_order = {}
TYPES.return_fleet_order = return_order
local function home_starbase(fid)
    -- a home base set by script (set_home_base) when its starbase still exists [I]
    local f = world.object("fleet", fid)
    local hb = f and tonumber(world.field(f, "home_base"))
    if hb and world.object("starbases", hb) then return hb end
    local country = world.fleet_owner[fid]
    local c = country and world.object("country", country)
    local col = c and tonumber(world.field(c, "capital"))
    local pid = col and (world.colony_planet[col] or col)
    local p = pid and world.object("planet", pid)
    local sys = p and tonumber(world.field(world.field(p, "coordinate"), "origin"))
    local g = sys and world.object("galactic_object", sys)
    return g and tonumber(world.list(world.field(g, "starbases"))[1]) or nil
end
function return_order.target(o, fid)
    local sub = sub_order(o)
    if sub and sub.type == "orbit_planet_order" then
        local k, id = orbit_order.target(sub)
        if k == "starbase" then return id end
    end
    return home_starbase(fid)
end
function return_order.is_done(o, fid, f)
    local sb = return_order.target(o, fid)
    return sb == nil or orbiting(f, "starbase", sb)
end
function return_order.tick(o, fid, f)
    local sb = return_order.target(o, fid)
    if sb then orders.tick_orbit_sub_order(o, fid, f, sb, "starbase") end
end
return_order.start = return_order.tick
function return_order.finish(o)
    orders.clear_sub_order(o)
end

-- follow_order (CFollowFleetOrder): engine.fleets.follow (the right click on a fleet)
TYPES.follow_order = require("engine.fleets.follow").order

-- colonize_planet_order (CColonizePlanetFleetOrder): engine.fleets.colonize
TYPES.colonize_planet_order = require("engine.fleets.colonize").order_type
-- land_armies_order (CLandArmiesFleetOrder): engine.fleets.armies
TYPES.land_armies_order = require("engine.fleets.armies").order_type
-- upgrade_design_at_orbitable_fleet_order (CUpgradeDesignAtOrbitableFleetOrder): engine.fleets.upgrade
TYPES.upgrade_design_at_orbitable_fleet_order = require("engine.fleets.upgrade").order_type

-- the orders the engine does not run yet (combat, archaeology): kept, never done
local KEPT = { aggressive_stance_fleet_order = true,
               excavate_archaeological_site_fleet_order = true }

local function T_of(o)
    if TYPES[o.type] then
        return TYPES[o.type]
    end
    local survey = require("engine.fleets.survey")
    return survey.TYPES[o.type]
end

local function call(o, name, fid, f, host)
    local T = T_of(o)
    local fn = T and T[name]
    if not fn then
        return nil
    end
    return fn(o, fid, f, orders, host)
end

-- ---------------------------------------------------------------------------------------------
-- the queue

local function head_ship(f)
    return ships_of(f)[1]
end

-- CFleetOrder::OnShipOrder (0xcd97a0): a civilian fleet with ships: two draws for the scopes, then
-- on_ship_order (this = the head ship, from = the fleet's country)
local function on_ship_order(fid, f)
    if not property(f, "civilian") or #ships_of(f) == 0 then
        return
    end
    RUST.rand()
    RUST.rand()
    S.ship_order_events = S.ship_order_events + 1
    local country = world.fleet_owner[fid]
    local events = package.loaded["simscript.events"] or require("simscript.events")
    pcall(events.on_action, "on_ship_order", eval.S("ship", head_ship(f)), eval.new_ctx(country and eval.S("country", country) or eval.NONE))
end

-- CFleet::StartFirstQueuedOrder (0xc6a0c0)
local function start_first_queued(fid, f, host)
    if current_handle(f) then
        return nil
    end
    local q = queue_handles(f)
    local first = q[1]
    if not first then
        return nil
    end
    world.remove_entry(first.holder, first.entry)
    drop_empty_queue(f)
    local h = set_current(f, first.type, first.block)
    count(S.started, h.type)
    call(h, "start", fid, f, host)
    local now = current_handle(f)
    if now and world.same(now.block, h.block) then
        on_ship_order(fid, f)
    end
    return h
end
orders.start_first_queued = function(fid) local f = fleet(fid); return f and start_first_queued(fid, f) end

-- CFleet::CancelCurrentOrder: the current order gone, the next one started
function orders.cancel_current(fid, f, host)
    f = f or fleet(fid)
    if not f then
        return
    end
    local h = current_handle(f)
    if h then
        call(h, "cancel", fid, f, host)
        set_current(f, nil)
        S.cancelled = S.cancelled + 1
    end
    start_first_queued(fid, f, host)
end

-- CFleet::ClearOrders
function orders.clear(fid)
    local f = fleet(fid)
    if not f then
        return
    end
    set_current(f, nil)
    remove_key(f, "order")
end

-- CFleet::HandleOrders (0xc62460)
local function handle_orders(fid, f, host)
    local h = current_handle(f)
    if not h then
        if #queue_handles(f) > 0 then
            start_first_queued(fid, f, host)
        end
        return
    end
    -- ShouldCancel: an order whose target is gone
    local guard = 0
    while h and guard < 100 do
        guard = guard + 1
        local cancel = call(h, "should_cancel", fid, f, host)
        if not cancel then
            break
        end
        set_current(f, nil)
        S.cancelled = S.cancelled + 1
        start_first_queued(fid, f, host)
        h = current_handle(f)
    end
    if not h then
        return
    end
    local T = T_of(h)
    if not T then
        count(S.not_modelled, h.type)
        return
    end
    if not call(h, "is_done", fid, f, host) then
        call(h, "tick", fid, f, host)
        count(S.ticked, h.type)
    end
    h = current_handle(f)
    if h and call(h, "is_done", fid, f, host) then
        call(h, "finish", fid, f, host)
        count(S.finished, h.type)
        local now = current_handle(f)
        if now and world.same(now.block, h.block) then
            set_current(f, nil)
        end
        if #queue_handles(f) > 0 then
            start_first_queued(fid, f, host)
        end
    end
end

-- orders.daily(host, date): every fleet's orders (CFleet::DailyUpdateSerial's HandleOrders), in
-- the fleet database's order
function orders.daily(host, date)
    -- STELLAR_FLEET_ORDERS=off: the orders not run (a comparison without them)
    if orders.off == nil then
        orders.off = os.getenv("STELLAR_FLEET_ORDERS") == "off"
    end
    if orders.off then
        return
    end
    S.days = S.days + 1
    for _, fid in ipairs(world.all("fleet")) do
        slice.tick("fleets/orders.lua:850")
        local f = fleet(fid)
        if f and (world.field(f, "current_order") or world.field(f, "order")) then
            local h = current_handle(f)
            if h and KEPT[h.type] then
                count(S.not_modelled, h.type)
            else
                slice.check("fleet orders")
                handle_orders(fid, f, host)
            end
        end
        -- CFleet::HandleAutoMovement, after the fleet's orders (engine.fleets.automove)
        if f and world.field(f, "auto_movement") then
            local am = package.loaded["engine.fleets.automove"] or require("engine.fleets.automove")
            am.handle(fid, host)
        end
    end
end

-- CFleet::AddOrder (0xc69dd0)
function orders.issue(fid, order, opts)
    opts = type(opts) == "table" and opts or {}
    local f = fleet(fid)
    if not f then
        S.refused = S.refused + 1
        return false
    end
    local b = orders.block(order)
    local ty, ob, e = first_order(b)
    if not ty then
        S.refused = S.refused + 1
        return false
    end
    local n = (current_handle(f) and 1 or 0) + #queue_handles(f)
    if n >= 100 then
        S.refused = S.refused + 1
        return false
    end
    -- CFleet::AddOrder: an auto-move set with clear_on_new_orders reset (engine.fleets.automove)
    if world.field(f, "auto_movement") then
        local am = package.loaded["engine.fleets.automove"] or require("engine.fleets.automove")
        am.on_order(fid)
    end
    local id = tonumber(world.field(f, "order_id")) or 0
    if id < 0 or id == NO_ID then id = 0 end
    if not find_entry(f, "order_id") then
        local _, pos = find_entry(f, "movement_manager")
        world.insert(f, (pos or #f) + 1, "order_id", id + 1)
    else
        world.set(f, "order_id", id + 1)
    end
    -- the base fields as the game writes them
    if not find_entry(ob, "can_reach") then world.append(ob, "can_reach", "yes") end
    remove_key(ob, "order_id")
    local _, cpos = find_entry(ob, "can_reach")
    world.insert(ob, cpos + 1, "order_id", id)
    if not find_entry(ob, "commissioner") then world.append(ob, "commissioner", NO_ID) end
    local cur = current_handle(f)
    if cur and cur.type == "aggressive_stance_fleet_order" then
        set_current(f, nil)
        cur = nil
    end
    local q = queue_block(f, true)
    if opts.front then
        if cur then
            orders.clear_sub_order(cur)
            world.insert(q, 1, cur.type, cur.block)
            set_current(f, nil)
        end
        world.insert(q, 1, ty, ob)
    else
        world.append(q, ty, ob)
    end
    S.issued = S.issued + 1
    local first = queue_handles(f)[1]
    if not current_handle(f) and first and world.same(first.block, ob) then
        start_first_queued(fid, f, opts.host)
    end
    return id
end

-- helpers for the orders the AI gives most

local function holder_block(ty, id)
    local b = {}
    world.append(b, "type", ty)
    world.append(b, "id", id)
    return b
end

function orders.survey(fid, pid, opts)
    local b = {}
    world.append(b, "deposit_holder", holder_block(0, pid))
    world.append(b, "progress", 0)
    return orders.issue(fid, { entry("survey_planet_order", b) }, opts)
end

function orders.research_anomaly(fid, pid, opts)
    local b = {}
    world.append(b, "planet", pid)
    return orders.issue(fid, { entry("research_anomaly_order", b) }, opts)
end

function orders.orbit(fid, pid, opts)
    local b = {}
    local ob = {}
    world.append(ob, "planet", pid)
    world.append(b, "orbitable", ob)
    local star = star_of(pid)
    if star then
        local sb = {}
        world.append(sb, "planet", star)
        world.append(b, "star", sb)
    end
    world.append(b, "merge_fleet", "none")
    return orders.issue(fid, { entry("orbit_planet_order", b) }, opts)
end

function orders.move_to(fid, c, opts)
    local b = {}
    world.append(b, "coordinate", coordinate_block(c))
    return orders.issue(fid, { entry("move_to_system_point_order", b) }, opts)
end

-- orders.survey_system(fleet, system[, opts]) -> the orders issued: a survey of every planet of the
-- system the fleet's country has not surveyed, nearest first from the fleet's position in the
-- system (the system's centre from outside), each then the nearest to the last ([I]: the order the
-- game's queues show)
function orders.survey_system(fid, system, opts)
    local f = fleet(fid)
    local g = world.object("galactic_object", system)
    local country = world.fleet_owner[fid]
    if not f or not g or not country then
        return false
    end
    local survey = require("engine.fleets.survey")
    local queued = {}
    for _, h in ipairs(queue_handles(f)) do
        if h.type == "survey_planet_order" then
            queued[tonumber(world.field(world.field(h.block, "deposit_holder"), "id"))] = true
        end
    end
    local cur = current_handle(f)
    if cur and cur.type == "survey_planet_order" then
        queued[tonumber(world.field(world.field(cur.block, "deposit_holder"), "id"))] = true
    end
    local left = {}
    for _, v in ipairs(world.fields(g, "planet")) do
        local pid = tonumber(v)
        if pid and not queued[pid] and not survey.has_surveyed(country, 0, pid) then
            local c = coord(world.field(world.object("planet", pid), "coordinate"))
            if c then left[#left + 1] = { id = pid, x = c.x, y = c.y } end
        end
    end
    local here = coord(world.field(mm_of(f), "coordinate"))
    local x, y = 0, 0
    if here and here.origin == system then
        x, y = here.x, here.y
    elseif here then
        -- from outside: where the fleet will come in (CFTLJump::CalcFTLEnterSystemPoint,
        -- engine.fleets.path.enter_point) [V: the game's queue from the galaxy view starts with
        -- Toarus I, the body nearest the hyperlane's entry from Ithni Zerak, not the star]
        local okp, path = pcall(require, "engine.fleets.path")
        if okp and path.enter_point then
            local ok, e = pcall(path.enter_point, path.coord(path.raw(here.x), path.raw(here.y), here.origin), system)
            if ok and e then x, y = e.x / ONE, e.y / ONE end
        end
    end
    local n = 0
    while #left > 0 do
        local best, bd
        for i, p in ipairs(left) do
            local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
            if not bd or d < bd then best, bd = i, d end
        end
        local p = table.remove(left, best)
        x, y = p.x, p.y
        if orders.survey(fid, p.id, opts) then n = n + 1 end
    end
    return n > 0 and n or false
end

-- orders.return_to_base(fleet[, opts]): return_fleet_order, to the starbase of the country's capital
-- system
function orders.return_to_base(fid, opts)
    local b = {}
    world.append(b, "exclude_allied", "no")
    world.append(b, "home_base", "no")
    return orders.issue(fid, { entry("return_fleet_order", b) }, opts)
end

local function list(t)
    local out = {}
    for k, v in pairs(t) do
        out[#out + 1] = k .. " " .. v
    end
    table.sort(out)
    return table.concat(out, ", ")
end

function orders.report()
    return string.format("fleet orders: %d days; started %s; ticked %s; finished %s; %d cancelled, %d issued, %d refused; "
        .. "%d on_ship_order; orbits %d entered, %d left; %d stations not built; not run: %s",
        S.days, list(S.started), list(S.ticked), list(S.finished), S.cancelled, S.issued, S.refused,
        S.ship_order_events, S.entered_orbit, S.left_orbit, S.stations_not_built, list(S.not_modelled))
        .. "\n" .. require("engine.fleets.survey").report()
        .. (package.loaded["engine.fleets.stations"] and ("\n" .. package.loaded["engine.fleets.stations"].report()) or "")
end

return orders
