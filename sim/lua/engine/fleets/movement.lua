-- engine/fleets/movement.lua : fleet movement, the way the game moves fleets each tick (GOG 4.5.2,
-- CFleetMovementManager, docs/fleet_movement.md; the pathfinder is engine.fleets.path), over the
-- save's own form:
--
--   fleet.movement_manager = { formation = { scale angle type } coordinate = { x y origin }
--       target = { coordinate = { ... } } target_coordinate = { ... } time_since_last_path_update
--       state = move_idle|move_system|move_wind_up|move_galaxy|move_wind_down|move_jump_anim
--       ftl_windup ftl_winddown path = { node = { coordinate = { ... } ftl = jump_hyperlane } ...
--       date = <ETA> } orbit = { ... } last_ftl_jump = { from to fleet jump_method bypass_from
--       bypass_to } ftl_anim_counter ftl_total_windup }
--   galactic_object.fleet_presence = { <fleet ids> }   (CGalacticObject::_PrecalcFleetPresence)
--
-- API (for the orders and the AI):
--   movement.move_to(fleet_id, target) -> true | false, why
--       target: { system = id } (the system's star) or a coordinate { x =, y =, origin = system }
--       (numbers as the save writes them). Sets the movement target and builds the path at once,
--       as an order's start does (CFleetMovementManager::OnMoveOrderChanged -> SetTarget ->
--       UpdatePath -> CFleetPath::Create); false when the fleet cannot move or there is no route.
--   movement.stop(fleet_id)            CFleetMovementManager::CancelMovement (target and path
--                                      cleared; a fleet in FTL keeps its jump)
--   movement.tick(host, date)          one tick of every fleet: the fleet phase of
--                                      CGameState::MicroUpdate (CFleetMovementManager::MicroUpdate)
--   movement.is_moving(fleet_id)       not move_idle, or a path left
--   movement.arrived(fleet_id)         idle at the coordinate of its last move_to
--   movement.system_of(fleet_id)       the system it is in (nil in FTL)
--   movement.state(fleet_id)           the state's name; movement.path_of(fleet_id) -> nodes
--   movement.speed(fleet_id)           the sublight speed a day (raw CFixedPoint)
--   movement.hooks                     access (closed borders), on_entered (terra incognita ...)
--
-- The target the movement follows stands for the executing order's (the game asks the order each
-- tick: CFleet::GetExecutingOrder()->GetFleetTargetCoordinate); move_to sets it.

local world = require("engine.world")
local defs = require("engine.defs")
local path = require("engine.fleets.path")

local FP, NO_ID = path.FP, path.NO_ID
local raw, text = path.raw, path.text
local fmul, fdiv, idiv = path.fmul, path.fdiv, path.idiv

local movement = {
    stats = { ticks = 0, moved = 0, jumps = 0, arrivals = 0, paths = 0, no_route = 0, windups = 0,
              draws = 0, on_actions = 0, on_action_errors = 0, writes = 0, cancelled = 0,
              speed_default = 0, skipped_bypass = 0 },
    hooks = {},
    errors = {},
}
local S = movement.stats

-- what happened when (movement.log: { tick, fleet, what, system }), for the checks; the first
-- 4000 events
movement.log = {}
function movement.event(st, what, sys)
    if #movement.log < 4000 then
        movement.log[#movement.log + 1] = { tick = S.ticks, fleet = st.fid, what = what, system = sys }
    end
end

-- the states (NMovement::EState) and their save tokens (CFleetMovementManager::WriteMembers, the
-- table at 0x46b34d4 Linux)
local WIND_UP, WIND_DOWN, IDLE, SYSTEM, GALAXY, JUMP_ANIM = 0, 1, 2, 3, 4, 5
local STATE_NAMES = { [0] = "move_wind_up", "move_wind_down", "move_idle", "move_system", "move_galaxy", "move_jump_anim" }
local STATE_OF = {}
for k, v in pairs(STATE_NAMES) do
    STATE_OF[v] = k
end
local METHOD_NAMES = { [0] = "jump_hyperlane", "jump_bypass", "jump_count" }
local METHOD_OF = { jump_hyperlane = 0, jump_bypass = 1, jump_count = 2 }
movement.STATES = STATE_NAMES

local NULL = { x = 0, y = 0, z = 0, origin = NO_ID }

-- ---------------------------------------------------------------------------------------------
-- the save's form

-- every statement of a block whose key is k
local function entries(block, k)
    local out = {}
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == k then
            out[#out + 1] = e
        end
    end
    return out
end

-- a block changed in place reads back as it is now (world's field cache dropped)
local function touched(block)
    world.append(block, "_", "0")
    world.remove_entry(block, block[#block])
end

local function read_coord(b)
    if type(b) ~= "table" then
        return nil
    end
    return {
        x = raw(world.field(b, "x")) or 0, y = raw(world.field(b, "y")) or 0,
        z = raw(world.field(b, "visual_height")) or 0,
        origin = tonumber(world.field(b, "origin")) or NO_ID,
        randomized = world.field(b, "randomized") == "yes" or nil,
    }
end

local function is_null(c)
    return c == nil or (c.origin == NO_ID and c.x == 0 and c.y == 0)
end

-- CCelestialCoordinate::WriteMembers: x, y, origin, randomized when set, visual_height when not 0
local function coord_block(c)
    c = c or NULL
    local b = {}
    world.append(b, "x", text(c.x))
    world.append(b, "y", text(c.y))
    world.append(b, "origin", tostring(c.origin or NO_ID))
    if c.randomized then
        world.append(b, "randomized", "yes")
    end
    if c.z and c.z ~= 0 then
        world.append(b, "visual_height", text(c.z))
    end
    return b
end

local cache = setmetatable({}, { __mode = "k" }) -- movement_manager block -> its state

local function fleet_block(fid)
    return world.object("fleet", fid)
end

local function read_state(fid)
    local f = fleet_block(fid)
    local mm = f and world.field(f, "movement_manager")
    if type(mm) ~= "table" then
        return nil
    end
    local st = cache[mm]
    if st then
        return st
    end
    local target = world.field(mm, "target")
    local p = world.field(mm, "path")
    local nodes = {}
    for _, n in ipairs(world.fields(p, "node")) do
        if type(n) == "table" then
            local c = read_coord(world.field(n, "coordinate")) or path.copy(NULL)
            c.method = METHOD_OF[tostring(world.field(n, "ftl"))] or 0
            c.bypass = tonumber(world.field(n, "bypass"))
            nodes[#nodes + 1] = c
        end
    end
    local lj = world.field(mm, "last_ftl_jump")
    local formation = world.field(mm, "formation")
    st = {
        fid = fid, mm = mm,
        coord = read_coord(world.field(mm, "coordinate")) or path.copy(NULL),
        target = read_coord(type(target) == "table" and world.field(target, "coordinate") or nil),
        tcoord = read_coord(world.field(mm, "target_coordinate")),
        tslpu = tonumber(world.field(mm, "time_since_last_path_update")) or 0,
        state = STATE_OF[tostring(world.field(mm, "state"))] or IDLE,
        windup = tonumber(world.field(mm, "ftl_windup")) or 0,
        winddown = tonumber(world.field(mm, "ftl_winddown")) or 0,
        anim = tonumber(world.field(mm, "ftl_anim_counter")) or 0,
        total_windup = tonumber(world.field(mm, "ftl_total_windup")) or 0,
        path = nodes,
        eta = type(p) == "table" and world.field(p, "date") or nil,
        lj = type(lj) == "table" and {
            from = read_coord(world.field(lj, "from")) or path.copy(NULL),
            to = tonumber(world.field(lj, "to")) or NO_ID,
            fleet = tonumber(world.field(lj, "fleet")) or fid,
            method = METHOD_OF[tostring(world.field(lj, "jump_method"))] or 2,
            bypass_from = tonumber(world.field(lj, "bypass_from")) or NO_ID,
            bypass_to = tonumber(world.field(lj, "bypass_to")) or NO_ID,
        } or { from = path.copy(NULL), to = NO_ID, fleet = fid, method = 2, bypass_from = NO_ID, bypass_to = NO_ID },
        angle = type(formation) == "table" and raw(world.field(formation, "angle")) or 0,
    }
    if is_null(st.target) then
        st.target = nil
    end
    cache[mm] = st
    return st
end
movement.read_state = read_state

local function path_block(st)
    local b = {}
    for _, n in ipairs(st.path) do
        local nb = {}
        world.append(nb, "coordinate", coord_block(n))
        world.append(nb, "ftl", METHOD_NAMES[n.method or 0] or "jump_hyperlane")
        if n.bypass and n.bypass ~= NO_ID then
            world.append(nb, "bypass", tostring(n.bypass))
        end
        world.append(b, "node", nb)
    end
    if st.eta then
        world.append(b, "date", st.eta, true)
    end
    return b
end

local function jump_block(lj)
    local b = {}
    world.append(b, "from", coord_block(lj.from))
    world.append(b, "to", tostring(lj.to or NO_ID))
    world.append(b, "fleet", tostring(lj.fleet or NO_ID))
    world.append(b, "jump_method", METHOD_NAMES[lj.method] or "jump_count")
    world.append(b, "bypass_from", tostring(lj.bypass_from or NO_ID))
    world.append(b, "bypass_to", tostring(lj.bypass_to or NO_ID))
    return b
end

-- the movement manager written back in the game's order (CFleetMovementManager::WriteMembers,
-- 0x298bd10 Linux): formation, coordinate, target, target_coordinate, time_since_last_path_update
-- (not 0), state, ftl_windup (not 0), ftl_winddown (not 0), path, orbit, last_ftl_jump,
-- ftl_anim_counter (not 0), ftl_total_windup (not 0), custom_formation; what else the block holds
-- is kept after
local function write_state(st)
    local mm = st.mm
    local keep = {}
    for _, e in ipairs(mm) do
        if e.op and e.key then
            keep[e.key.text] = keep[e.key.text] or e
        end
    end
    local out = {}
    local function put(k, v, quoted)
        local value = type(v) == "table" and v or { text = tostring(v), quoted = quoted or nil }
        out[#out + 1] = { key = { text = k }, op = "=", value = value }
    end
    local formation = keep.formation and keep.formation.value
    if type(formation) == "table" then
        for _, e in ipairs(formation) do
            if e.op and e.key and e.key.text == "angle" then
                e.value.text = text(st.angle or 0)
            end
        end
        touched(formation)
        out[#out + 1] = keep.formation
    end
    put("coordinate", coord_block(st.coord))
    local tb = {}
    world.append(tb, "coordinate", coord_block(st.target))
    if st.target and keep.target and type(keep.target.value) == "table" then
        -- the anchor (CFleetTargetCoordinate::_Anchor) as it was
        for _, e in ipairs(keep.target.value) do
            if e.op and e.key and e.key.text ~= "coordinate" then
                tb[#tb + 1] = e
            end
        end
    end
    put("target", tb)
    put("target_coordinate", coord_block(st.target and st.tcoord or nil))
    if st.tslpu ~= 0 then
        put("time_since_last_path_update", st.tslpu)
    end
    put("state", STATE_NAMES[st.state] or "move_idle")
    if st.windup ~= 0 then
        put("ftl_windup", st.windup)
    end
    if st.winddown ~= 0 then
        put("ftl_winddown", st.winddown)
    end
    put("path", path_block(st))
    if keep.orbit then
        out[#out + 1] = keep.orbit
    end
    put("last_ftl_jump", jump_block(st.lj))
    if st.anim ~= 0 then
        put("ftl_anim_counter", st.anim)
    end
    if st.total_windup ~= 0 then
        put("ftl_total_windup", st.total_windup)
    end
    if keep.custom_formation then
        out[#out + 1] = keep.custom_formation
    end
    local known = { formation = 1, coordinate = 1, target = 1, target_coordinate = 1,
        time_since_last_path_update = 1, state = 1, ftl_windup = 1, ftl_winddown = 1, path = 1, orbit = 1,
        last_ftl_jump = 1, ftl_anim_counter = 1, ftl_total_windup = 1, custom_formation = 1 }
    for _, e in ipairs(mm) do
        if not (e.op and e.key and known[e.key.text]) then
            out[#out + 1] = e
        end
    end
    for i = #mm, 1, -1 do
        mm[i] = nil
    end
    for i, e in ipairs(out) do
        mm[i] = e
    end
    touched(mm)
    S.writes = S.writes + 1
end

-- ---------------------------------------------------------------------------------------------
-- systems' fleet presence (CGalacticObject::AddPrecalcFleetPresence 0x260ba30 /
-- RemovePrecalcFleetPresence 0x260bc30 Linux): appended when absent, taken out keeping the order;
-- the save leaves out an empty list (written after `initializer`)

local function add_presence(sid, fid)
    local g = sid and sid ~= NO_ID and world.object("system", sid)
    if not g then
        return
    end
    local fp = world.field(g, "fleet_presence")
    if type(fp) ~= "table" then
        fp = {}
        local pos = #g + 1
        for i, e in ipairs(g) do
            if e.op and e.key and (e.key.text == "inner_radius" or e.key.text == "outer_radius" or e.key.text == "starbases") then
                pos = i
                break
            end
        end
        world.insert(g, pos, "fleet_presence", fp)
    end
    for _, v in ipairs(world.list(fp)) do
        if tonumber(v) == fid then
            return
        end
    end
    world.append_value(fp, fid)
end

local function remove_presence(sid, fid)
    local g = sid and sid ~= NO_ID and world.object("system", sid)
    if not g then
        return
    end
    local fp = world.field(g, "fleet_presence")
    if type(fp) ~= "table" then
        return
    end
    world.remove_value(fp, fid)
    if #world.list(fp) == 0 then
        for _, e in ipairs(entries(g, "fleet_presence")) do
            world.remove_entry(g, e)
        end
    end
end
movement.add_presence, movement.remove_presence = add_presence, remove_presence

-- ---------------------------------------------------------------------------------------------
-- speeds

local function economy_mods(kind, id)
    local economy = package.loaded["engine.economy"]
    local ok, M = pcall(function() return economy and economy.modifiers(kind, id) end)
    return ok and M or {}
end

-- a definition's `@variable`: its file's own, else the global scripted variables
-- (common/scripted_variables: top-level `@name = value` statements, not definitions)
local file_vars, global_vars = {}, nil
local function vars_of(file, into)
    into = into or {}
    pcall(function()
        local db = require("simscript.db")
        local source = require("stellar.script.source")
        for _, e in ipairs(source.parse(db.fs, file) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                into[e.key.text] = e.value.text
            end
        end
    end)
    return into
end
local function scripted(v, file)
    if type(v) ~= "string" or v:sub(1, 1) ~= "@" then
        return v
    end
    if file and file_vars[file] == nil then
        file_vars[file] = vars_of(file)
    end
    if file and file_vars[file][v] then
        return file_vars[file][v]
    end
    if not global_vars then
        global_vars = {}
        pcall(function()
            local db = require("simscript.db")
            local source = require("stellar.script.source")
            for _, f in ipairs(source.files(db.fs, "common/scripted_variables", "txt") or {}) do
                vars_of(f, global_vars)
            end
        end)
    end
    return global_vars[v]
end

-- the ship's design's base speed: its growth stage's ship size's max_speed times SHIP_SPEED_SCALE
-- [I: CBaseDesignImplementation +0xf0, set when the design is computed]
local base_speed_cache = {}
local function design_base_speed(sid)
    local s = world.object("ship", sid)
    local impl = s and world.field(s, "ship_design_implementation")
    local design = type(impl) == "table" and tonumber(world.field(impl, "design")) or nil
    local stage = type(impl) == "table" and tonumber(world.field(impl, "growth_stage")) or 0
    local key = tostring(design) .. ":" .. tostring(stage)
    local v = base_speed_cache[key]
    if v == nil then
        v = false
        local d = design and world.object("ship_design", design)
        local stages = d and world.blocks(world.field(d, "growth_stages")) or {}
        local gs = stages[(stage or 0) + 1] or stages[1]
        local size = gs and world.field(gs, "ship_size")
        size = type(size) == "string" and size:gsub('"', "") or size
        local def = size and defs.get("common/ship_sizes", size)
        local ms = def and scripted(defs.field(def.block, "max_speed"), def.file)
        if ms then
            v = fmul(raw(ms), path.defines().SHIP_SPEED_SCALE)
        end
        base_speed_cache[key] = v
    end
    return v or nil
end

-- NShipUtil::CalcMaxSpeed (0x1f62540 Linux), the parts with data here: the base speed times (1 +
-- ship_base_speed_mult), times max(0, 1 + ship_speed_mult + owned_ship_speed_mult), times (1 +
-- ship_military_speed_mult for a military ship, ship_science_speed_mult for a science ship).
-- ship_speed_reduction (ApplyModifierMult(.., ship_speed_reduction, true)) leaves a cruising ship's
-- speed as it is in the game's runs [I: a ship with 0.5 of it moves at its full speed]; the
-- federation and community territory, psionic aura and damage terms are not ported, and the
-- AI empires' civilian ships move 0.7 to 4.7% faster than this in the game (docs/fleet_movement.md).
function movement.ship_speed(sid)
    local base = design_base_speed(sid)
    if not base then
        S.speed_default = S.speed_default + 1
        return nil
    end
    local M = economy_mods("ship", sid) or {}
    local function m(k)
        return raw(M[k] or 0) or 0
    end
    local v = fmul(base, FP + m("ship_base_speed_mult"))
    v = fmul(v, math.max(0, FP + m("ship_speed_mult") + m("owned_ship_speed_mult")))
    local s = world.object("ship", sid)
    local f = s and fleet_block(tonumber(world.field(s, "fleet")))
    local class = f and path.SHIP_CLASS[tostring(world.field(f, "ship_class"))]
    local extra = (class == 0 and m("ship_military_speed_mult") or 0) + (class == 3 and m("ship_science_speed_mult") or 0)
    if extra ~= 0 then
        v = fmul(v, FP + extra)
    end
    return math.max(0, v)
end

-- a check's speeds (STELLAR_FLEET_SPEEDS: a file of `<fleet> <raw speed a day>` lines, measured
-- in the game's runs), in place of the computed ones: to tell the movement's logic from the speed
local overrides
local function override(fid)
    if overrides == nil then
        overrides = false
        local file = os and os.getenv and os.getenv("STELLAR_FLEET_SPEEDS")
        local f = file and io.open(file, "r")
        if f then
            overrides = {}
            for line in f:lines() do
                local a, b = line:match("^(%d+)%s+(%-?%d+)")
                if a then
                    overrides[tonumber(a)] = tonumber(b)
                end
            end
            f:close()
        end
    end
    return overrides and overrides[fid]
end

-- CFleet::CalcMaxSpeed (0x29471b0 Linux): the slowest of the ships with a speed, at least 0.1
local speed_cache = {}
function movement.speed(fid)
    local o = override(fid)
    if o then
        return o
    end
    local f = fleet_block(fid)
    local best
    for _, s in ipairs(world.list(f and world.field(f, "ships"))) do
        local sid = tonumber(s)
        local v = sid and speed_cache[sid]
        if v == nil and sid then
            v = movement.ship_speed(sid) or false
            speed_cache[sid] = v
        end
        if v and v > 0 and (best == nil or v < best) then
            best = v
        end
    end
    best = best or fmul(140 * FP, path.defines().SHIP_SPEED_SCALE)
    return math.max(best, 10000)
end
function movement.invalidate_speeds()
    speed_cache = {}
end

-- CalcFTLSpeed (0x2984e20 Linux): HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED times (1 +
-- ship_interstellar_speed_mult), averaged over the ships, per tick
function movement.ftl_speed(fid)
    local D = path.defines()
    local f = fleet_block(fid)
    local sum, n = 0, 0
    for _, s in ipairs(world.list(f and world.field(f, "ships"))) do
        local M = economy_mods("ship", tonumber(s)) or {}
        sum = sum + fmul(D.HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED, FP + (raw(M.ship_interstellar_speed_mult or 0) or 0))
        n = n + 1
    end
    if n == 0 then
        return 2 * FP -- 0xb504f333 + 0x4afb0ccc wraps to 0x100000000 [I: an empty fleet]
    end
    return fdiv(sum, n * FP)
end

-- NFleet::CalcLowestShipModifier(fleet, ship_windup_mult)
local function lowest_ship_mod(fid, name)
    local f = fleet_block(fid)
    local low
    for _, s in ipairs(world.list(f and world.field(f, "ships"))) do
        local M = economy_mods("ship", tonumber(s)) or {}
        local v = raw(M[name] or 0) or 0
        if low == nil or v < low then
            low = v
        end
    end
    return low or 0
end

-- CFTLJump::CalcFTLWindUp (0x2986870 Linux), a hyperlane jump: HYPERLANE_WINDUP times (1 + the
-- fleet's lowest ship_windup_mult), in ticks
function movement.windup(fid)
    local D = path.defines()
    return idiv(fmul(D.HYPERLANE_WINDUP, FP + lowest_ship_mod(fid, "ship_windup_mult")), FP)
end
-- CFTLJump::CalcFTLWindDown (0x2986b00 Linux): HYPERLANE_WINDDOWN likewise
function movement.winddown(fid)
    local D = path.defines()
    if D.HYPERLANE_WINDDOWN == 0 then
        return 0
    end
    return idiv(fmul(D.HYPERLANE_WINDDOWN, FP + lowest_ship_mod(fid, "ship_windup_mult")), FP)
end

-- CFleetPath::CalcEstimatedDays (0x2988830 Linux): the ticks of each leg (a jump: windup, winddown
-- and the FTL travel; in a system: the distance at the fleet's speed), in days. The speed factors
-- of the first ship's ship_speed_reduction and the star are left out.
local function estimated_days(st)
    local total = 0
    local prev = st.coord
    local speed = movement.speed(st.fid)
    local per_tick = math.max(1, idiv(speed, 10))
    for _, n in ipairs(st.path) do
        if prev.origin ~= n.origin then
            local from, to = path.galactic(prev), path.galactic(n)
            local travel = fdiv(path.distance(from, to), movement.ftl_speed(st.fid))
            total = total + travel + (movement.windup(st.fid) + movement.winddown(st.fid)) * FP
        else
            total = total + fdiv(path.distance(prev, n), per_tick)
        end
        prev = n
    end
    return idiv(total, 10)
end
movement.estimated_days = estimated_days

-- CStellarisDate::AddDays on the save's date text
local function date_add(date, days)
    local y, m, d = tostring(date):match("(%d+)%.(%d+)%.(%d+)")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y then
        return nil
    end
    local n = (y * 12 + (m - 1)) * 30 + (d - 1) + days
    local yy = math.floor(n / 360)
    local rem = n - yy * 360
    return string.format("%d.%02d.%02d", yy, math.floor(rem / 30) + 1, rem % 30 + 1)
end

-- the ETA (CFleetMovementManager::SetPath / UpdatePath): today + the rounded estimate, unless in
-- FTL
local function update_eta(st)
    if st.state == GALAXY then
        return
    end
    local days = estimated_days(st)
    local rounded = idiv(days + FP / 2, FP) -- CFixedPoint::GetRounded
    local today = movement.today
    if today then
        st.eta = date_add(today, rounded) or st.eta
    end
end

-- ---------------------------------------------------------------------------------------------
-- the movement manager

local function data_of(st)
    return path.fleet_data(st.fid)
end

-- whether the fleet may be in a system (CFleet::HasAccess: closed borders, not ported)
local function has_access(st, sys)
    local h = movement.hooks.has_access
    if h then
        return h(st.fid, sys) ~= false
    end
    return true
end

local function clear_path(st)
    if st.state == GALAXY then
        -- SetSizeAndEmplace(min(1, n)): a fleet in FTL keeps the node it flies to
        while #st.path > 1 do
            table.remove(st.path)
        end
    else
        st.path = {}
    end
end

-- CFleetMovementManager::CancelMovement (0x298d440 Linux)
local function cancel(st)
    st.target, st.tcoord = nil, nil
    clear_path(st)
    if st.state == SYSTEM or st.state == WIND_UP then
        st.windup = 0
        st.state = IDLE
    end
    S.cancelled = S.cancelled + 1
end

-- CFleetMovementManager::UpdatePath (0x298c680 Linux)
local function update_path(st, target, force)
    st.tslpu = 0
    if target.origin == NO_ID then
        st.path = {}
    elseif st.coord.origin ~= NO_ID then
        -- in a system
        local last = st.path[#st.path]
        if not force and last then
            if path.same(last, target) then
                update_eta(st)
                return
            end
            if last.origin == target.origin then
                local open = true
                for _, n in ipairs(st.path) do
                    if not has_access(st, n.origin) then
                        open = false
                    end
                end
                if open then
                    last.x, last.y, last.z = target.x, target.y, target.z or 0
                    update_eta(st)
                    return
                end
            end
        end
        local nodes = path.create(st.coord, target, data_of(st))
        S.paths = S.paths + 1
        if not nodes then
            S.no_route = S.no_route + 1
        end
        st.path = nodes or {}
    elseif st.state == GALAXY then
        -- in FTL: from where the jump will come out
        local enter = path.enter_point(st.lj.from, st.lj.to) or path.copy(st.coord)
        local first, last = st.path[1], st.path[#st.path]
        local done = false
        if #st.path > 0 and not force then
            if path.same(first, enter) and path.same(last, target) then
                done = true
            elseif first.origin ~= enter.origin and last.origin ~= target.origin then
                first.x, first.y, first.z = enter.x, enter.y, enter.z
                last.x, last.y, last.z = target.x, target.y, target.z or 0
                done = true
            end
        end
        if not done then
            local nodes = path.create(enter, target, data_of(st))
            S.paths = S.paths + 1
            if not nodes then
                S.no_route = S.no_route + 1
            end
            st.path = nodes or {}
        end
        if #st.path == 0 then
            local e = path.copy(enter)
            e.method = 0
            st.path = { e }
        end
    end
    update_eta(st)
end

-- CFleetMovementManager::UpdateTargetCoordinate(requires_move, target, ...) (0x298cfb0 Linux),
-- with the order's target the movement's own: re-planned when the path is gone or crosses a
-- system the fleet may not enter (or when forced: a teleport); cleared at the target
local function update_target(st, force)
    if not st.target then
        if #st.path > 0 or st.state == SYSTEM then
            cancel(st)
        end
        return
    end
    local need = force
    if not need then
        if #st.path == 0 then
            need = true
        else
            local last
            for _, n in ipairs(st.path) do
                if n.origin ~= last and n.origin ~= NO_ID then
                    if not has_access(st, n.origin) then
                        need = true
                        break
                    end
                end
                last = n.origin
            end
        end
    end
    if not need then
        return
    end
    st.tcoord = path.copy(st.target)
    if not path.same(st.target, st.coord) then
        update_path(st, st.target, true)
        if #st.path ~= 0 then
            return
        end
    end
    -- at the target, or no route: target and path cleared
    st.target, st.tcoord = nil, nil
    if st.state == GALAXY then
        clear_path(st)
    else
        st.path = {}
    end
    if st.state == SYSTEM or st.state == WIND_UP then
        st.windup = 0
        st.state = IDLE
    end
end

-- the angle a fleet faces moving from a to b (CCelestialCoordinate::AngleTo 0x2286700 Linux:
-- CFixedPoint::Atan2 0x42309f0, the octant approximation, minus VFixedPIHalf = 1.571)
local PI4, PI34, PIHALF = 78539, 235619, 157100
local function atan2(y, x)
    local ay = y < 0 and -y or y
    if y == 0 then
        ay = 1
    end
    local a
    if x < 0 then
        a = PI34 - fmul(fdiv(x + ay, ay - x), PI4)
    else
        a = PI4 - fmul(fdiv(x - ay, x + ay), PI4)
    end
    return y < 0 and -a or a
end
movement.atan2 = atan2
local function angle_to(a, b)
    return atan2(b.y - a.y, b.x - a.x) - PIHALF
end

-- CFleetMovementManager::UpdateFormation (0x298ead0 Linux): the formation faces the next node in
-- the system; the ships' places (CFleetFormation::Update -> CShip::UpdatePositionInFleetFormation)
local function update_formation(st)
    if st.coord.origin == NO_ID then
        return
    end
    local n = st.path[1]
    if n and n.origin == st.coord.origin and not path.same(n, st.coord) then
        st.angle = angle_to(st.coord, n)
    end
    st.formation_moved = true
end

-- CFleetMovementManager::MoveTowards (0x298f360 Linux): a tenth of the fleet's speed a tick
local function move_towards(st, to)
    local step = idiv(movement.speed(st.fid), 10)
    st.coord = path.towards(st.coord, to, step, false, false)
    update_formation(st)
    S.moved = S.moved + 1
end

-- the coordinate a fleet flies to in FTL: the galactic coordinate of the node it flies to
-- CFTLJump (from, to, fleet, method, from bypass, to bypass)
local function make_jump(st, to_sys, method, bfrom, bto)
    return { from = path.copy(st.coord), to = to_sys, fleet = st.fid, method = method or 0,
             bypass_from = bfrom or NO_ID, bypass_to = bto or NO_ID }
end

-- the on_actions of a system entered or left, with the game's draws first (one per event scope)
local function on_action(name, fid, sid, from_sid)
    S.on_actions = S.on_actions + 1
    local ok, err = pcall(function()
        local events = package.loaded["simscript.events"] or require("simscript.events")
        local eval = package.loaded["simscript.eval"] or require("simscript.eval")
        local from = eval.new_ctx(eval.S("system", sid))
        events.on_action(name, eval.S("fleet", fid), from)
    end)
    if not ok then
        S.on_action_errors = S.on_action_errors + 1
        if #movement.errors < 10 then
            movement.errors[#movement.errors + 1] = name .. ": " .. tostring(err)
        end
    end
end

local function draw()
    S.draws = S.draws + 1
    return RUST.rand()
end

-- CGalacticObject::OnFleetLeft (0x2603300 Linux): two scopes (two draws), on_leaving_system_fleet
local function on_fleet_left(st, sid)
    draw()
    draw()
    on_action("on_leaving_system_fleet", st.fid, sid)
end

local function owner_of(sid)
    return world.system_owner and world.system_owner[sid]
end

-- CGalacticObject::OnFleetEntered (0x2602960 Linux): terra incognita cleared (the hook), two
-- scopes and on_entering_system_fleet; into another owner's space a CCrudeRandom seeded by one
-- draw and on_crossing_border
local function on_fleet_entered(st, sid, from_sid)
    local h = movement.hooks.on_entered
    if h then
        pcall(h, st.fid, sid, from_sid)
    end
    draw()
    draw()
    on_action("on_entering_system_fleet", st.fid, sid, from_sid)
    if from_sid and from_sid ~= NO_ID and owner_of(from_sid) ~= owner_of(sid) then
        draw()
        on_action("on_crossing_border", st.fid, from_sid, sid)
    end
end

-- CFleetMovementManager::TeleportFleetToCoordinate (0x298e4f0 Linux): out of the old system's
-- presence, to the coordinate facing `angle`, into the new system's presence, the ships snapped to
-- their places; the target re-planned from there (forced)
local function teleport(st, c, angle)
    if st.coord.origin ~= NO_ID then
        remove_presence(st.coord.origin, st.fid)
    end
    st.coord = path.copy(c)
    st.angle = angle or 0
    st.snap = true
    if st.coord.origin ~= NO_ID then
        add_presence(st.coord.origin, st.fid)
    end
    update_target(st, true)
end

-- CFleetMovementManager::EnterFTL (0x298df20 Linux)
local function enter_ftl(st, jump)
    st.lj = jump
    local from_sys = st.coord.origin
    if from_sys ~= NO_ID then
        remove_presence(from_sys, st.fid)
        on_fleet_left(st, from_sys)
    end
    st.state = GALAXY
    table.remove(st.path, 1)
    st.windup, st.total_windup, st.winddown, st.anim = 0, 0, 0, 0
    local sys = path.galaxy()[from_sys]
    local galactic = sys and { x = sys.x, y = sys.y, z = sys.z, origin = NO_ID } or path.galactic(st.coord)
    teleport(st, galactic, 0)
    S.jumps = S.jumps + 1
    movement.event(st, "enter_ftl", from_sys)
end

-- CFleetMovementManager::LeaveFTL (0x298e380 Linux)
local function leave_ftl(st)
    st.winddown = 0
    local wd = movement.winddown(st.fid)
    st.state = wd > 0 and WIND_DOWN or IDLE
    local from_sys = st.lj.from.origin
    local enter = path.enter_point(st.lj.from, st.lj.to) or path.copy(st.coord)
    local angle = atan2(enter.y, enter.x) - (PIHALF + 314200)
    teleport(st, enter, angle)
    on_fleet_entered(st, st.coord.origin, from_sys)
    S.arrivals = S.arrivals + 1
    movement.event(st, "leave_ftl", st.coord.origin)
end

-- CFleetMovementManager::BeginFTLJump (0x298e8b0 Linux): a path to the next system's node, then
-- the windup when the fleet is at its leave point
local function begin_ftl_jump(st, to)
    local nodes = path.create(st.coord, to, data_of(st))
    S.paths = S.paths + 1
    st.path = nodes or {}
    if #st.path <= 1 then
        st.target, st.tcoord = nil, nil
        clear_path(st)
        if st.state == SYSTEM or st.state == WIND_UP then
            st.windup = 0
            st.state = IDLE
        end
        return
    end
    if path.dist_less(st.coord, st.path[1], FP) then
        local nxt = st.path[2]
        st.windup = 0
        st.total_windup = movement.windup(st.fid)
        st.state = WIND_UP
        st.pending_jump = make_jump(st, nxt.origin, nxt.method, st.path[1].bypass, nxt.bypass)
        S.windups = S.windups + 1
        movement.event(st, "wind_up", nxt.origin)
    end
end

-- CFleetMovementManager::UpdateFleetMovementDontReadOthers (0x298efb0 Linux), the parallel part
local function dont_read_others(st)
    local s = st.state
    if s == WIND_DOWN or s == GALAXY or s == JUMP_ANIM then
        return
    end
    if s == IDLE or s == SYSTEM then
        update_target(st, false)
    else
        -- FTL_WIND_UP: _CheckCancelFTLWindup (0x298f4e0 Linux): the order's target is the
        -- movement's own here, so the windup goes on
        return
    end
    if st.target then
        st.tslpu = st.tslpu + 1
        local n = st.path[1]
        if not n then
            return
        end
        if n.origin ~= st.coord.origin then
            begin_ftl_jump(st, n)
            return
        end
        st.state = SYSTEM
        move_towards(st, n)
        if path.near(st.coord, n, FP) then
            table.remove(st.path, 1)
            if #st.path == 0 then
                movement.event(st, "arrived", st.coord.origin)
                cancel(st)
            end
        end
    else
        st.state = IDLE
    end
end

-- CFleetMovementManager::UpdateFTLJump (0x298d650 Linux), in the serial part
local function update_ftl_jump(st)
    local s = st.state
    if s == WIND_UP then
        -- every system of the path must still be open
        local last
        for _, n in ipairs(st.path) do
            if n.origin ~= last and n.origin ~= NO_ID and not has_access(st, n.origin) then
                -- OnMoveOrderChanged: planned again from here
                update_target(st, true)
                if st.state ~= WIND_UP then
                    return
                end
                break
            end
            last = n.origin
        end
        st.windup = st.windup + 1
        if st.windup < st.total_windup then
            return
        end
        local nxt = st.path[2]
        if not nxt then
            cancel(st)
            return
        end
        local jump = make_jump(st, nxt.origin, nxt.method, st.path[1].bypass, nxt.bypass)
        if jump.method == 1 then
            S.skipped_bypass = S.skipped_bypass + 1 -- FTL_JUMP_ANIM: bypasses not ported
            cancel(st)
            return
        end
        enter_ftl(st, jump)
    elseif s == WIND_DOWN then
        st.winddown = st.winddown + 1
        if st.winddown < movement.winddown(st.fid) then
            return
        end
        st.winddown = 0
        st.state = IDLE
    elseif s == GALAXY then
        local n = st.path[1]
        if not n then
            -- GoMIA: not ported (a fleet in FTL with no node)
            return
        end
        local dest = path.galactic(n)
        if st.lj.method ~= 1 then
            st.coord = path.towards(st.coord, dest, movement.ftl_speed(st.fid), false, false)
        else
            st.coord = path.copy(dest)
        end
        if path.same(st.coord, dest) then
            leave_ftl(st)
        end
    elseif s == JUMP_ANIM then
        st.anim = st.anim + 1
        S.skipped_bypass = S.skipped_bypass + 1
    end
end

-- the fleets the movement looks at: mobile (CFleet::IsMobile, the save's properties.mobile) with
-- something to do
local function mobile(f)
    local props = world.field(f, "properties")
    return type(props) == "table" and world.field(props, "mobile") == "yes"
end

local function busy(st)
    return st.state ~= IDLE or #st.path > 0 or st.target ~= nil
end

-- a fleet in combat (CFleet::HasCombat: combat.in_combat_with) moves by the combat's rules
-- (MoveTowards its combat coordinate): not ported, the fleet is left where it is
local function in_combat(f)
    local c = world.field(f, "combat")
    local w = type(c) == "table" and world.field(c, "in_combat_with")
    return type(w) == "table" and #world.blocks(w) > 0
end
movement.in_combat = in_combat

-- ---------------------------------------------------------------------------------------------
-- ships: their places in the formation. CFleetFormation::Update gives every ship its place
-- (CShip::UpdatePositionInFleetFormation: the save's target_coordinate and post_move_angle); a
-- teleport snaps the ships there (CShip::SnapToFormation 0x2acedc0 Linux: coordinate, rotation,
-- forward vector). Ported for single-ship fleets (their place is the fleet's coordinate); the
-- wedge and circle offsets of larger fleets and the ships' own sublight movement toward their
-- places (CShip::InternalUpdateMovement: acceleration, turning) are not.

local PI, TWO_PI = 314200, 628400 -- VFixedPI, VFixedPITwo

-- fixed_int64::sin / cos (0x4230280 / 0x42303c0 Linux): reduced to [0, pi/2], then
-- NFixedInt64Internal::_sinx = x - x^3/6 + x^5/120 (truncated)
local function sinx(x)
    local x2 = fmul(x, x)
    local x3 = fmul(x2, x)
    local x5 = fmul(fmul(x3, x), x)
    return idiv(x5, 120) - idiv(x3, 6) + x
end
local function fsin(a)
    local r = a - idiv(a, 628319) * 628319
    if r < 0 then
        r = r + 628319
    end
    local u = r < 314160 and r or r - 314159
    if u >= 157081 then
        u = 314160 - u
    end
    local s = sinx(u)
    return r < 314160 and s or -s
end
local function fcos(a)
    return fsin(a + 157080)
end
movement.fsin, movement.fcos = fsin, fcos

local function wrap(a)
    while a > PI do
        a = a - TWO_PI
    end
    while a < -PI do
        a = a + TWO_PI
    end
    return a
end

local function set_entry(s, key, value, after)
    for _, e in ipairs(entries(s, key)) do
        e.value = type(value) == "table" and value or { text = value }
        return
    end
    local pos = #s + 1
    if after then
        for i, e in ipairs(s) do
            if e.op and e.key and e.key.text == after then
                pos = i + 1
            end
        end
    end
    world.insert(s, pos, key, value)
end

local function update_ships(st)
    local moved = st.formation_moved
    st.formation_moved = nil
    local f = fleet_block(st.fid)
    local ships = world.list(f and world.field(f, "ships"))
    if #ships ~= 1 then
        return
    end
    local s = world.object("ship", tonumber(ships[1]))
    if not s then
        return
    end
    local place = { x = st.coord.x, y = st.coord.y, z = st.coord.z or 0, origin = st.coord.origin }
    if st.snap or moved then
        set_entry(s, "target_coordinate", coord_block(place), "coordinate")
        set_entry(s, "post_move_angle", text(st.angle or 0), "target_coordinate")
    end
    local lag = false
    if not st.snap then
        -- the ship's own movement toward its place [I: the game's CShip::InternalUpdateMovement
        -- accelerates and turns; here the ship follows at its fleet's speed]
        local c = read_coord(world.field(s, "coordinate"))
        local tc = read_coord(world.field(s, "target_coordinate"))
        if c and tc and c.origin ~= NO_ID and c.origin == tc.origin and not path.same(c, tc) then
            local n = path.towards(c, tc, idiv(movement.speed(st.fid), 10), false, false)
            n.z = c.z
            set_entry(s, "coordinate", coord_block(n))
            lag = not path.same(n, tc)
        end
    end
    if st.snap then
        set_entry(s, "coordinate", coord_block(place))
        for _, e in ipairs(entries(s, "speed")) do
            world.remove_entry(s, e)
        end
        local rot = wrap(st.angle or 0)
        local sn, cs = fsin(rot), fcos(rot)
        local fx, fy = 0, 0
        if sn ~= 0 or cs ~= 0 then
            local ffi = require("ffi")
            local len = (ffi.new("int64_t", cs) * cs + ffi.new("int64_t", sn) * sn)
            -- the integer root, as SnapToFormation inlines it
            local n = len
            local x = n / 2
            if n >= 2 then
                while true do
                    local y = (n / x + x) / 2
                    if y >= x then break end
                    x = y
                end
            else
                x = n
            end
            local l = tonumber(x)
            fx, fy = fdiv(-sn, l), fdiv(cs, l)
        end
        set_entry(s, "rotation", text(rot))
        set_entry(s, "forward_x", text(fx), "rotation")
        set_entry(s, "forward_y", text(fy), "forward_x")
    end
    touched(s)
    return lag
end

-- ---------------------------------------------------------------------------------------------
-- the tick

local active = {} -- fleet id -> true: the fleets busy after the last tick (plus move_to's)

-- CFleetMovementManager::RepairData (0x29924a0 Linux), at the load: a last jump whose fleet is not
-- a fleet is this fleet's, to the system it is in
local function repair(fid, f)
    local mm = world.field(f, "movement_manager")
    local lj = type(mm) == "table" and world.field(mm, "last_ftl_jump")
    if type(lj) ~= "table" then
        return
    end
    local owner = tonumber(world.field(lj, "fleet"))
    if owner and world.object("fleet", owner) then
        return
    end
    local origin = tonumber(world.path(mm, "coordinate", "origin")) or NO_ID
    if world.field(lj, "to") == nil then
        local pos = 1
        for i, e in ipairs(lj) do
            if e.op and e.key and e.key.text == "from" then
                pos = i + 1
            end
        end
        world.insert(lj, pos, "to", tostring(origin))
    else
        world.set(lj, "to", origin)
    end
    world.set(lj, "fleet", fid)
    world.set(lj, "bypass_from", NO_ID)
    world.set(lj, "bypass_to", NO_ID)
    cache[mm] = nil
    S.repaired = (S.repaired or 0) + 1
end

local function scan()
    for _, fid in ipairs(world.all("fleet")) do
        local f = fleet_block(fid)
        if f then
            repair(fid, f)
        end
        if f and mobile(f) then
            local st = read_state(fid)
            if st and busy(st) then
                active[fid] = true
            end
        end
    end
    movement.scanned = true
end

-- movement.tick(host, date): CFleetMovementManager::MicroUpdate (0x298c000 Linux, GOG 0xe25160):
-- every fleet's OnlyChangeSelfPrivate and DontReadOthers (parallel in the game: no draws), then
-- every fleet's UpdateFleetMovementSerial (UpdateFTLJump; the draws of the systems left and
-- entered), then the ships' movement (parallel)
local disabled = os and os.getenv and os.getenv("STELLAR_MOVEMENT") == "off" -- a check's baseline
function movement.tick(host, date)
    if disabled then
        return
    end
    S.ticks = S.ticks + 1
    movement.today = world.meta.date and tostring(world.meta.date) or nil
    if date and date.year then
        movement.today = string.format("%d.%02d.%02d", date.year, date.month or 1, date.day or 1)
    end
    if not movement.scanned then
        scan()
    end
    local ids = {}
    for _, fid in ipairs(world.all("fleet")) do
        if active[fid] then
            ids[#ids + 1] = fid
        end
    end
    local states = {}
    for _, fid in ipairs(ids) do
        local f = fleet_block(fid)
        local st = f and not in_combat(f) and read_state(fid)
        if st then
            states[#states + 1] = st
            st.snap = nil
            dont_read_others(st)
        end
    end
    for _, st in ipairs(states) do
        if st.state == WIND_UP or st.state == WIND_DOWN or st.state == GALAXY or st.state == JUMP_ANIM then
            update_ftl_jump(st)
        end
    end
    for _, st in ipairs(states) do
        write_state(st)
        local lag = update_ships(st)
        if not busy(st) and not lag then
            active[st.fid] = nil
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the API

local function star_of(sid)
    local g = world.object("system", sid)
    for _, p in ipairs(world.fields(g, "planet")) do
        local pl = world.object("planet", tonumber(p))
        local class = pl and tostring(world.field(pl, "planet_class") or "")
        if class:find("star") or class:find("pc_black_hole") or class:find("pc_pulsar") or class:find("pc_neutron") then
            local c = read_coord(world.field(pl, "coordinate"))
            if c then
                c.z = 0
                return c
            end
        end
    end
    return { x = 0, y = 0, z = 0, origin = sid }
end

local last_target = {}

function movement.move_to(fid, target)
    local f = fleet_block(fid)
    if not f or not mobile(f) then
        return false, "not a mobile fleet"
    end
    local st = read_state(fid)
    if not st then
        return false, "no movement manager"
    end
    local t
    if type(target) == "table" and target.system then
        t = star_of(target.system)
    elseif type(target) == "table" and target.origin then
        t = { x = raw(target.x) or 0, y = raw(target.y) or 0, z = 0, origin = tonumber(target.origin) or NO_ID }
    else
        return false, "no target"
    end
    if t.origin == NO_ID then
        return false, "not in a system"
    end
    -- OnMoveOrderChanged -> SetTarget: the target, then UpdatePath (forced: a new target system
    -- or a new place in this one)
    st.target = t
    st.tcoord = path.copy(t)
    movement.today = movement.today or (world.meta.date and tostring(world.meta.date))
    if st.state == IDLE or st.state == SYSTEM then
        if path.same(t, st.coord) then
            st.target, st.tcoord = nil, nil
            st.path = {}
        else
            update_path(st, t, true)
            if #st.path == 0 then
                st.target, st.tcoord = nil, nil
                write_state(st)
                return false, "no route"
            end
        end
    elseif st.state == GALAXY then
        update_path(st, t, true)
    else
        -- winding up (OnMoveOrderChanged keeps the jump when the new path starts the same) or
        -- down: planned when it is idle again
        update_path(st, t, true)
    end
    last_target[fid] = path.copy(t)
    write_state(st)
    active[fid] = true
    return true
end

function movement.stop(fid)
    local st = read_state(fid)
    if not st then
        return false
    end
    cancel(st)
    write_state(st)
    return true
end

function movement.is_moving(fid)
    local st = read_state(fid)
    return st ~= nil and (st.state ~= IDLE or #st.path > 0)
end

function movement.arrived(fid)
    local st = read_state(fid)
    if not st or st.state ~= IDLE or #st.path > 0 then
        return false
    end
    local t = last_target[fid]
    if not t then
        return st.target == nil
    end
    return path.same(t, st.coord)
end

function movement.system_of(fid)
    local st = read_state(fid)
    if not st or st.coord.origin == NO_ID then
        return nil
    end
    return st.coord.origin
end

function movement.state(fid)
    local st = read_state(fid)
    return st and STATE_NAMES[st.state]
end

function movement.path_of(fid)
    local st = read_state(fid)
    return st and st.path
end

function movement.report()
    local parts = {}
    for _, k in ipairs({ "ticks", "moved", "windups", "jumps", "arrivals", "paths", "no_route", "cancelled",
        "draws", "on_actions", "on_action_errors", "skipped_bypass", "speed_default" }) do
        parts[#parts + 1] = k .. " " .. tostring(S[k])
    end
    local p = path.stats
    return string.format("movement: %s; pathfinder: %d searches, %d found, %d failed", table.concat(parts, ", "),
        p.finds, p.found, p.failed)
end

return movement
