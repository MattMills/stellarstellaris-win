-- engine/ai/exploration.lua : the AI's science ships (docs/ai.md section 6, "Science ships"), the
-- science branch of CAIInteriorMinister::HandleCivilianFleets (GOG 4.5.2 0xbbab50), on the AI's
-- week (CAIInteriorMinister::WeeklyUpdate, after the districts and buildings).
--
-- HandleCivilianFleets, for the science ships:
--
--   taken: the deposit holders (and, for a survey, their systems) that the country's fleets' current
--     orders target (the current order and its sub_order chain: survey_planet, research_anomaly,
--     colonize_planet, build_orbital_station, collect_data, build_megastructure, assist_detection)
--   the country's fleets (fleets_manager.owned_fleets, the controlled fleets in order), starbases
--   first (a stable partition)
--   each civilian fleet that is not MIA, not moving between systems (MOVING_IN_GALAXY) and mobile:
--     a science ship (shipclass_science_ship):
--       no leader (CFleet::GetLeader: a ship's `leader`) -> ReturnToBase
--       the type's AI has `tech` -> ResearchAndSurvey
--
-- ResearchAndSurvey (0xbc1760): nothing while the fleet does an actual order (its current order's
-- IsActualOrder: every order but the stance pseudo-orders aggressive_stance_fleet_order and
-- evade_hostiles_order); else the first of these that acts:
--
--   (not ported) the cloaking command (the Paragon cloaking DLC bit), astral rifts and archaeology
--   (when more than one science ship is free: count_if lambda_2), special projects, LockWormhole
--   SearchForAnomalies (0xbbf6c0)  the country's anomalies (events.anomalies) in order: the planet's
--                                  deposit holder not taken, CPlanet::HasAnomaly (the planet is in
--                                  the list), NAIUtil::IsPathClear(fleet, planet's system, real
--                                  fleets) -> CFleetResearchAnomalyCommand; the planet taken
--   (not ported) ExploreWormhole
--   SurveySystems (0xbc0380)       below
--   (not ported) CaptureSpaceCritters
--   ReturnToBase (0xbc12e0)        not when the fleet orbits a planet of its own country; the
--                                  stance to passive, a return_fleet order (CQueueFleetsOrderCommand
--                                  of a CReturnFleetOrder; CGoMIACommand when that is not valid)
--
-- SurveySystems: the EXPLORE strategy list (ai.strategy type 2, engine.ai.strategy), each system
-- that is valid, not fully surveyed (CCountry::HasFullySurveyedSystem), not in the minister's
-- _BlockedSystems (cleared on the AI's month) and not taken this week:
--
--   score = trunc(value * (SURVEY_COLONIZABLE_SYSTEM_MULTIPLIER if the system's intel level is
--           HIGH (3) and it has a colonizable planet) / (1 + 0.5 * jumps(fleet's system, system)))
--
-- stable-sorted by the highest score; in that order the first system that
--   CGalacticObject::CanSurvey (access; not a foreign system with communications), has no enemy
--   fleet in it (checked when the type needs surveys and the system is visited or its intel is
--   HIGH) and to which NAIUtil::IsPathClear (the path's systems safe for the fleet: no hostile
--   armed fleet in a system of HIGH intel, or of lower intel with stored hostile intel) gets
--   CFleetSurveyDepositHolderCommand(fleet, system); the system is taken. A system that fails a
--   check is added to _BlockedSystems.
--
-- The commands execute after every AI decided (engine.ai): through engine.fleets.orders when that
-- module is there and runs the order type (a survey: the fleet's orders dropped, then
-- orders.survey for each planet of survey_queue, the game's QueueOrders order; an anomaly:
-- orders.research_anomaly; a return: orders.return_to_base); otherwise they are recorded only
-- (M.decisions), the fleets left as they are. STELLAR_AI_FLEETS=off turns the decisions off.
--
-- Checked against the headless game (docs/ai.md section 6, "Science ships"). None of this draws
-- from the AI's generators (the orders' start draws from the synchronized one, in engine.fleets).

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local cmds = require("engine.ai.commands")
local defs = require("engine.defs")

local M = {
    stats = { weeks = 0, fleets = 0, busy = 0, anomaly = 0, survey = 0, ["return"] = 0, nothing = 0,
        blocked = 0, executed = 0, recorded = 0 },
    decisions = {},  -- { date, country, fleet, kind = "research_anomaly" / "survey" / "return", target, system }
    blocked = {},    -- country -> { [system] = true } (CAIInteriorMinister::_BlockedSystems)
}

local NO_ID = 4294967295

local function strategy()
    return require("engine.ai.strategy")
end
local function op()
    return require("engine.ai.opinion")
end

-- ---------------------------------------------------------------------------------------------
-- defines

local D
local function defines()
    if D == nil then
        local g = defs.get("common/defines", "NAI")
        D = {
            COLONIZABLE_MULT = g and tonumber(defs.field(g.block, "SURVEY_COLONIZABLE_SYSTEM_MULTIPLIER")) or 2,
        }
    end
    return D
end

-- ---------------------------------------------------------------------------------------------
-- fleets

local function fleet(id)
    return world.object("fleet", id)
end

-- the fleet's properties (`properties = { civilian = yes mobile = yes ... }`, EFleetFlags)
local function prop(f, key)
    local p = world.field(f, "properties")
    return type(p) == "table" and world.field(p, key) == "yes"
end

-- the fleet's system: movement_manager.coordinate.origin; moving between systems
-- (MOVING_IN_GALAXY) the last jump's destination (HandleCivilianFleets 0xbbb111)
local function system_of(f)
    local mm = world.field(f, "movement_manager")
    if type(mm) ~= "table" then
        return nil
    end
    if world.field(mm, "state") == "move_galaxy" then
        local j = world.field(mm, "last_ftl_jump")
        local to = type(j) == "table" and tonumber(world.field(j, "to"))
        if to and to ~= NO_ID then
            return to
        end
    end
    local c = world.field(mm, "coordinate")
    local o = type(c) == "table" and tonumber(world.field(c, "origin"))
    return o ~= NO_ID and o or nil
end
M.system_of = system_of

local function moving_in_galaxy(f)
    local mm = world.field(f, "movement_manager")
    return type(mm) == "table" and world.field(mm, "state") == "move_galaxy"
end

-- CFleet::GetLeader: the leader of the fleet's ships (a ship's `leader`)
local function leader_of(f)
    for _, s in ipairs(world.list(world.field(f, "ships"))) do
        slice.tick("ai/exploration.lua:133")
        local ship = world.object("ship", tonumber(s))
        local l = ship and tonumber(world.field(ship, "leader"))
        if l and l ~= NO_ID and world.object("leader", l) then
            return l
        end
    end
    return nil
end
M.leader_of = leader_of

-- the current order's chain: { {kind, body} } (current_order = { <kind> = { ... sub_order = { <kind> = {} } } })
local function order_chain(f)
    local out = {}
    local block = world.field(f, "current_order")
    while type(block) == "table" do
        slice.tick("ai/exploration.lua:148")
        local kind, body
        for _, e in ipairs(block) do
            slice.tick("ai/exploration.lua:150")
            if e.op and e.key and type(e.value) == "table" then
                kind, body = e.key.text, e.value
                break
            end
        end
        if kind == nil then
            break
        end
        out[#out + 1] = { kind = kind, body = body }
        block = world.field(body, "sub_order")
    end
    return out
end
M.order_chain = order_chain

-- CFleetOrder::IsActualOrder: false for the stance pseudo-orders (CAggressiveStanceFleetOrder,
-- CEvadeHostilesFleetOrder), true for the others; no current order: idle
local NOT_ACTUAL = { aggressive_stance_fleet_order = true, evade_hostiles_order = true }
local function busy(f)
    local chain = order_chain(f)
    return chain[1] ~= nil and not NOT_ACTUAL[chain[1].kind]
end
M.busy = busy

-- the save's deposit holder reference { type id } -> "type:id"
local function dh_key(block)
    if type(block) ~= "table" then
        return nil
    end
    local t, id = tonumber(world.field(block, "type")), tonumber(world.field(block, "id"))
    return t and id and (t .. ":" .. id) or nil
end

-- an order's target planet (`planet = id`, `orbitable = { planet = id }`)
local function order_planet(body)
    local p = tonumber(world.field(body, "planet"))
    if p then
        return p
    end
    local o = world.field(body, "orbitable")
    return type(o) == "table" and tonumber(world.field(o, "planet")) or nil
end

-- ---------------------------------------------------------------------------------------------
-- the galaxy: fleets by system, intel

local index_key, by_system
local function fleets_in(sid)
    local key = tostring(world.tree) .. "/" .. tostring(M.today)
    if index_key ~= key then
        index_key, by_system = key, {}
        for _, fid in ipairs(world.all("fleet")) do
            slice.tick("ai/exploration.lua:201")
            local f = fleet(fid)
            local s = f and system_of(f)
            if s then
                local l = by_system[s]
                if not l then
                    l = {}
                    by_system[s] = l
                end
                l[#l + 1] = fid
            end
        end
    end
    return by_system[sid] or {}
end

-- CCountry::GetIntelLevel(system): the country's `intel_level` (one per system, by id); read again
-- each AI day (the intel changes it in place)
local intel_cache = setmetatable({}, { __mode = "k" })
local function intel_level(c, sid)
    local list = world.field(c, "intel_level")
    if type(list) ~= "table" then
        return 0
    end
    local arr = intel_cache[list]
    if arr == nil or arr.day ~= M.today then
        arr = { day = M.today }
        for i, v in ipairs(world.list(list)) do
            slice.tick("ai/exploration.lua:230")
            arr[i - 1] = tonumber(v) or 0
        end
        intel_cache[list] = arr
    end
    return arr[sid] or 0
end
M.intel_level = intel_level

-- the stored intel's hostiles of a system (`intel = { { object = <system> hostile = { ... } } }`)
local function stored_hostiles(c, sid)
    for _, e in ipairs(world.blocks(world.field(c, "intel"))) do
        slice.tick("ai/exploration.lua:241")
        if tonumber(world.field(e, "object")) == sid then
            local h = world.field(e, "hostile")
            return type(h) == "table" and #world.blocks(h) or 0
        end
    end
    return 0
end

local function visited(c, sid)
    for _, v in ipairs(world.list(world.field(c, "visited_objects"))) do
        slice.tick("ai/exploration.lua:251")
        if tonumber(v) == sid then
            return true
        end
    end
    return false
end

-- the fleet's owner (fleets_manager.owned_fleets)
local function owner_of(fid)
    return world.fleet_owner and world.fleet_owner[fid]
end

-- CCountry::GetAlignmentToCountryCached == Enemy / IsHostileCached: at war, or the relation's
-- `hostile = yes` (space fauna, marauders, first-contact hostility) [I]
local function hostile(us, other)
    if other == nil or other == us then
        return false
    end
    local o = op()
    if o.rflag(o.relation(us, other), "hostile") then
        return true
    end
    return o.at_war(us, other)
end

-- a fleet that counts as present: ships left (not all killed or disabled), not event-locked or MIA
local function present(f)
    local n = #world.list(world.field(f, "ships"))
    if n == 0 then
        return false
    end
    local gone = (tonumber(world.field(f, "cached_killed_ships")) or 0)
    local dis = tonumber(world.field(f, "cached_disabled_ships")) or 0
    if dis > 0 and dis >= n - gone then
        return false
    end
    return not prop(f, "event_locked") and not prop(f, "mia")
end

-- SurveySystems' check of the target (0xbc093d-0xbc0a77): an enemy fleet in the system
local function enemy_fleet_in(us, sid)
    for _, fid in ipairs(fleets_in(sid)) do
        slice.tick("ai/exploration.lua:293")
        local f = fleet(fid)
        if f and present(f) and not prop(f, "cloaked") and hostile(us, owner_of(fid)) then
            return true
        end
    end
    return false
end

-- NAIUtil::IsSystemSafeFor (0xba2430) for a fleet of no military power: unsafe with a hostile
-- non-civilian fleet of some military power in the system; below HIGH intel, without `real`, only
-- when the stored intel lists hostiles there
local function system_safe(us, c, sid, real)
    if not real and intel_level(c, sid) < 3 and stored_hostiles(c, sid) == 0 then
        return true
    end
    for _, fid in ipairs(fleets_in(sid)) do
        slice.tick("ai/exploration.lua:309")
        local f = fleet(fid)
        if f and not prop(f, "civilian") and present(f) and not prop(f, "cloaked")
            and hostile(us, owner_of(fid)) and (tonumber(world.field(f, "military_power")) or 0) > 0 then
            return false
        end
    end
    return true
end

-- the shortest hyperlane path (by length, ties to fewer jumps, as strategy.jumps_from): the systems
-- after the start, nil when there is none
local function path(from, to)
    local g = strategy().galaxy()
    if from == to then
        return {}
    end
    local dist, jumps, prev = { [from] = 0 }, { [from] = 0 }, {}
    local open = { from }
    local done = {}
    while #open > 0 do
        slice.tick("ai/exploration.lua:329")
        -- the open system of the least (length, jumps); a linear scan (the graph is ~600 systems)
        local bi = 1
        for i = 2, #open do
            slice.tick("ai/exploration.lua:332")
            local a, b = open[i], open[bi]
            if dist[a] < dist[b] or (dist[a] == dist[b] and jumps[a] < jumps[b]) then
                bi = i
            end
        end
        local s = table.remove(open, bi)
        if s == to then
            break
        end
        done[s] = true
        for _, lane in ipairs(g.lanes[s] or {}) do
            slice.tick("ai/exploration.lua:343")
            local n = lane.to
            if not done[n] then
                local nd, nj = dist[s] + lane.length, jumps[s] + 1
                if dist[n] == nil then
                    dist[n], jumps[n], prev[n] = nd, nj, s
                    open[#open + 1] = n
                elseif nd < dist[n] or (nd == dist[n] and nj < jumps[n]) then
                    dist[n], jumps[n], prev[n] = nd, nj, s
                end
            end
        end
    end
    if prev[to] == nil then
        return nil
    end
    local out, s = {}, to
    while s ~= from do
        slice.tick("ai/exploration.lua:360")
        table.insert(out, 1, s)
        s = prev[s]
    end
    return out
end
M.path = path

-- NAIUtil::IsPathClear(fleet, system, real) (0xba20c0 -> 0xba1f80): the same system, or a path
-- whose systems (the target too) are all safe
local function path_clear(us, c, from, to, real)
    if from == nil or to == nil then
        return false
    end
    local p = path(from, to)
    if p == nil then
        return false
    end
    for _, sid in ipairs(p) do
        slice.tick("ai/exploration.lua:378")
        if not system_safe(us, c, sid, real) then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- surveys

-- the country's surveyed planets (surveyed_deposit_holders type 0)
local surveyed_cache = setmetatable({}, { __mode = "k" })
local function surveyed(c)
    local list = world.field(c, "surveyed_deposit_holders")
    if type(list) ~= "table" then
        return {}
    end
    local set = surveyed_cache[list]
    if set == nil or set.n ~= #list or set.day ~= M.today then
        set = { n = #list, day = M.today }
        for _, e in ipairs(world.blocks(list)) do
            slice.tick("ai/exploration.lua:399")
            if tonumber(world.field(e, "type")) == 0 then
                local id = tonumber(world.field(e, "id"))
                if id then set[id] = true end
            end
        end
        surveyed_cache[list] = set
    end
    return set
end

-- CCountry::HasFullySurveyedSystem (0x717220): auto-surveyed (a type that needs surveys, the
-- system ours), or every planet of the system surveyed
local function fully_surveyed(us, c, sid)
    local o = op()
    local needs = o.type_flag(us, "needs_survey")
    if needs and world.system_owner[sid] == us then
        return true
    end
    if not needs then
        return true
    end
    local s = surveyed(c)
    for _, pid in ipairs(strategy().galaxy().planets_of[sid] or {}) do
        slice.tick("ai/exploration.lua:422")
        if not s[pid] then
            return false
        end
    end
    return true
end

-- CGalacticObject::HasColonizablePlanet (0x86f920) [I]: an unowned planet of a class with
-- `colonizable = yes`
local colonizable_class = {}
local function has_colonizable_planet(sid)
    for _, pid in ipairs(strategy().galaxy().planets_of[sid] or {}) do
        slice.tick("ai/exploration.lua:434")
        local p = world.object("planet", pid)
        local cls = p and world.field(p, "planet_class")
        if cls then
            local v = colonizable_class[cls]
            if v == nil then
                local d = defs.get("common/planet_classes", cls)
                v = d ~= nil and defs.field(d.block, "colonizable") == "yes"
                colonizable_class[cls] = v
            end
            if v and world.field(p, "owner") == nil then
                return true
            end
        end
    end
    return false
end

-- CGalacticObject::CanSurvey(country, 3) (0x86e390): not a system another country owns that we
-- have communications with, nor one whose owner closed its borders to us [I] (HasAccess)
local function can_survey(us, sid)
    local owner = world.system_owner[sid]
    if owner == nil or owner == us then
        return true
    end
    local o = op()
    if o.rflag(o.relation(us, owner), "communications") then
        return false
    end
    return not o.rflag(o.relation(owner, us), "closed_borders")
end

-- the EXPLORE strategy entries of the country's AI block, in the block's order
local function explore_entries(c)
    local ai = world.field(c, "ai")
    local out = {}
    if type(ai) ~= "table" then
        return out
    end
    local T = strategy().TYPES.EXPLORE
    for _, e in ipairs(ai) do
        slice.tick("ai/exploration.lua:474")
        if e.op and e.key and e.key.text == "strategy" and type(e.value) == "table" then
            if tonumber(world.field(e.value, "type")) == T then
                out[#out + 1] = { id = tonumber(world.field(e.value, "id")), value = tonumber(world.field(e.value, "value")) or 0 }
            end
        end
    end
    return out
end

-- the planets a survey of the system queues, in order (CFleetSurveyDepositHolderCommand::Execute
-- 0xa59940 and QueueOrders 0xa59340): the system's planets (its `planet` order) the country has not
-- surveyed (none in an auto-surveyed system); from a start point, each time the nearest one left
-- (squared distance, the first of equal ones) and the next measured from it. The start point: the
-- fleet's position when it is in the system, else the system's FTL point toward the fleet's system
-- (CGalacticObject::CalcFTLPointWith 0x86d0d0: 1.05 * inner_radius from the star toward the other
-- system's galactic position).
local function xy(block)
    local cb = type(block) == "table" and world.field(block, "coordinate")
    if type(cb) ~= "table" then
        return nil
    end
    local x, y = tonumber(world.field(cb, "x")), tonumber(world.field(cb, "y"))
    return x and y and { x, y } or nil
end
local function survey_queue(us, c, f, sid)
    local o = op()
    if o.type_flag(us, "needs_survey") and world.system_owner[sid] == us then
        return {}
    end
    local s = surveyed(c)
    local left = {}
    for _, pid in ipairs(strategy().galaxy().planets_of[sid] or {}) do
        slice.tick("ai/exploration.lua:506")
        local p = world.object("planet", pid)
        local at = p and xy(p)
        if at and not s[pid] then
            left[#left + 1] = { pid = pid, at = at }
        end
    end
    local from = system_of(f)
    local mm = world.field(f, "movement_manager")
    local here = type(mm) == "table" and xy(mm)
    local px, py = 0, 0
    if from == sid and here then
        px, py = here[1], here[2]
    else
        local sys = world.object("system", sid)
        local other = from and world.object("system", from)
        local a, b = sys and xy(sys), other and xy(other)
        local r = 1.05 * (tonumber(sys and world.field(sys, "inner_radius")) or 0)
        if a and b then
            local dx, dy = b[1] - a[1], b[2] - a[2]
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0 then
                px, py = dx / len * r, dy / len * r
            end
        end
    end
    local out = {}
    while #left > 0 do
        slice.tick("ai/exploration.lua:533")
        local best, bd
        for i, e in ipairs(left) do
            slice.tick("ai/exploration.lua:535")
            local dx, dy = e.at[1] - px, e.at[2] - py
            local d = dx * dx + dy * dy
            if bd == nil or d < bd then
                best, bd = i, d
            end
        end
        local e = table.remove(left, best)
        out[#out + 1] = e.pid
        px, py = e.at[1], e.at[2]
    end
    return out
end
M.survey_queue = survey_queue

local function survey_systems(us, c, f, fid, taken, blocked)
    local from = system_of(f)
    local g = strategy().galaxy()
    local jumps = from and strategy().jumps_from(from) or {}
    local needs = op().type_flag(us, "needs_survey")
    local mult = defines().COLONIZABLE_MULT
    local cands = {}
    for _, e in ipairs(explore_entries(c)) do
        slice.tick("ai/exploration.lua:557")
        local sid = e.id
        if sid and g.planets_of[sid] and not fully_surveyed(us, c, sid) and not blocked[sid] and not taken.systems[sid] then
            local v = e.value
            if intel_level(c, sid) == 3 and has_colonizable_planet(sid) then
                v = v * mult
            end
            local j = (sid == from) and 0 or (jumps[sid] or 65535)
            -- the game's fixed point: value * 1.0 / (1.0 + 0.5 * jumps), truncated to an int
            local score = math.floor(v * 100000 / (100000 + 50000 * j))
            cands[#cands + 1] = { sid = sid, score = score, n = #cands }
        end
    end
    table.sort(cands, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.n < b.n
    end)
    for _, x in ipairs(cands) do
        slice.tick("ai/exploration.lua:574")
        local sid = x.sid
        local ok = can_survey(us, sid)
        if ok and needs and (visited(c, sid) or intel_level(c, sid) == 3) then
            ok = not enemy_fleet_in(us, sid)
        end
        if ok and path_clear(us, c, from, sid, false) then
            taken.systems[sid] = true
            return { kind = "survey", target = sid, system = sid, planets = survey_queue(us, c, f, sid) }
        end
        blocked[sid] = true
        M.stats.blocked = M.stats.blocked + 1
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- anomalies

local function anomalies_of(c)
    local ev = world.field(c, "events")
    local out = {}
    for _, v in ipairs(world.list(type(ev) == "table" and world.field(ev, "anomalies") or nil)) do
        slice.tick("ai/exploration.lua:596")
        out[#out + 1] = tonumber(v)
    end
    return out
end

local function search_anomalies(us, c, f, taken)
    local from = system_of(f)
    local g = strategy().galaxy()
    for _, pid in ipairs(anomalies_of(c)) do
        slice.tick("ai/exploration.lua:605")
        local p = pid and world.object("planet", pid)
        if p and world.field(p, "anomaly") ~= nil and not taken.dh["0:" .. pid] then
            local sid = g.system_of[pid]
            if sid and path_clear(us, c, from, sid, true) then
                taken.dh["0:" .. pid] = true
                return { kind = "research_anomaly", target = pid, system = sid }
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- return to base

-- the colony's planet's controller (or owner)
local function capital_ok(c)
    local col = tonumber(world.field(c, "capital"))
    return col ~= nil and world.colony_planet[col] ~= nil
end

local function orbit_planet(f)
    local mm = world.field(f, "movement_manager")
    local orbit = type(mm) == "table" and world.field(mm, "orbit")
    local ob = type(orbit) == "table" and world.field(orbit, "orbitable")
    local p = type(ob) == "table" and tonumber(world.field(ob, "planet"))
    return p ~= NO_ID and p or nil
end

local function return_to_base(us, c, f)
    if busy(f) or not capital_ok(c) then
        return nil
    end
    local p = orbit_planet(f)
    local planet = p and world.object("planet", p)
    if planet then
        local ctrl = tonumber(world.field(planet, "controller")) or tonumber(world.field(planet, "owner"))
        if ctrl == us then
            return nil
        end
    end
    return { kind = "return" }
end

-- ---------------------------------------------------------------------------------------------
-- the week

-- the targets of the country's fleets' current orders (HandleCivilianFleets, first loop)
local TAKEN_ORDERS = {
    survey_planet_order = true, research_anomaly_order = true, colonize_planet_order = true,
    build_orbital_station_order = true, collect_data_fleet_order = true,
    build_megastructure_fleet_order = true, assist_detection_order = true,
}
local function taken_of(fleets)
    local taken = { dh = {}, systems = {} }
    local g = strategy().galaxy()
    for _, fid in ipairs(fleets) do
        slice.tick("ai/exploration.lua:662")
        local f = fleet(fid)
        for _, o in ipairs(f and order_chain(f) or {}) do
            slice.tick("ai/exploration.lua:664")
            if TAKEN_ORDERS[o.kind] then
                local k = dh_key(world.field(o.body, "deposit_holder"))
                local p = order_planet(o.body)
                if k == nil and p then
                    k = "0:" .. p
                end
                if k then
                    taken.dh[k] = true
                    if o.kind == "survey_planet_order" then
                        local pid = tonumber(k:match(":(%d+)$"))
                        local sid = pid and g.system_of[pid]
                        if sid then taken.systems[sid] = true end
                    end
                end
                break
            end
        end
    end
    return taken
end

local function owned_fleets(c)
    local out = {}
    for _, e in ipairs(world.blocks(world.path(c, "fleets_manager", "owned_fleets"))) do
        slice.tick("ai/exploration.lua:688")
        local fid = tonumber(world.field(e, "fleet"))
        if fid and fleet(fid) then
            out[#out + 1] = fid
        end
    end
    -- the stable partition: starbases first
    local first, rest = {}, {}
    for _, fid in ipairs(out) do
        slice.tick("ai/exploration.lua:696")
        if world.field(fleet(fid), "ship_class") == "shipclass_starbase" then
            first[#first + 1] = fid
        else
            rest[#rest + 1] = fid
        end
    end
    for _, fid in ipairs(rest) do first[#first + 1] = fid end
    return first
end
M.owned_fleets = owned_fleets

-- the fleet orders module (engine.fleets.orders), when it is there
local orders_present
local function fleet_orders()
    if orders_present == nil then
        orders_present = package.searchpath("engine.fleets.orders", package.path) ~= nil
    end
    return orders_present and require("engine.fleets.orders") or nil
end

-- the order types the orders module runs (its own and engine.fleets.survey's)
local function runs(orders, ty)
    if orders.TYPES and orders.TYPES[ty] then
        return true
    end
    local ok, survey = pcall(require, "engine.fleets.survey")
    return ok and type(survey) == "table" and survey.TYPES ~= nil and survey.TYPES[ty] ~= nil
end

-- CFleetSurveyDepositHolderCommand / CFleetResearchAnomalyCommand (not queued): the fleet's current
-- order and queue dropped (CFleet::CancelCurrentOrder without starting the next, ClearQueuedOrders),
-- then the new orders added in order
local function replace_orders(orders, fid)
    if orders.current(fid) or #orders.queue(fid) > 0 then
        orders.clear(fid)
    end
end

-- the command posted for a decision, executed after every AI decided: through the orders module
-- for the order types it runs, else recorded only (the fleet left as it is)
local function command(country, fid, d, today)
    return {
        kind = "fleet_" .. d.kind, country = country, fleet = fid, target = d.target,
        execute = function(cmd)
            local orders = fleet_orders()
            local done = false
            if orders and d.kind == "survey" and runs(orders, "survey_planet_order") then
                replace_orders(orders, fid)
                for _, pid in ipairs(d.planets or {}) do
                    slice.tick("ai/exploration.lua:745")
                    if orders.survey(fid, pid) then
                        done = true
                    end
                end
            elseif orders and d.kind == "research_anomaly" and runs(orders, "research_anomaly_order") then
                replace_orders(orders, fid)
                done = orders.research_anomaly(fid, d.target) and true or false
            elseif orders and d.kind == "return" and runs(orders, "return_fleet_order") then
                -- CReturnFleetOrder as the AI posts it (the save: home_base = no, exclude_allied = no)
                if orders.return_to_base then
                    done = orders.return_to_base(fid) and true or false
                else
                    done = orders.issue(fid, { return_fleet_order = { exclude_allied = "no", home_base = "no" } }) and true or false
                end
            end
            if done then
                M.stats.executed = M.stats.executed + 1
                return true
            end
            M.stats.recorded = M.stats.recorded + 1
            return false
        end,
    }
end

-- M.weekly(country, today, commands): CAIInteriorMinister::HandleCivilianFleets, science ships
function M.weekly(country, today, commands, host)
    -- STELLAR_AI_FLEETS=off: no science-ship decisions (an A/B switch for the checks)
    if os.getenv("STELLAR_AI_FLEETS") == "off" then
        return
    end
    local ai = require("engine.ai")
    local c = world.object("country", country)
    if not c then
        return
    end
    M.stats.weeks = M.stats.weeks + 1
    M.today = today
    local tech = ai.setting(country, "tech")
    local fleets = owned_fleets(c)
    local taken = taken_of(fleets)
    local blocked = M.blocked[country]
    if blocked == nil then
        blocked = {}
        M.blocked[country] = blocked
    end
    for _, fid in ipairs(fleets) do
        slice.tick("ai/exploration.lua:792")
        local f = fleet(fid)
        if f and world.field(f, "ship_class") == "shipclass_science_ship" and prop(f, "civilian")
            and prop(f, "mobile") and not prop(f, "mia") and not moving_in_galaxy(f) then
            M.stats.fleets = M.stats.fleets + 1
            local d
            if leader_of(f) == nil then
                d = return_to_base(country, c, f)
            elseif tech then
                if busy(f) then
                    M.stats.busy = M.stats.busy + 1
                else
                    d = search_anomalies(country, c, f, taken)
                        or survey_systems(country, c, f, fid, taken, blocked)
                        or return_to_base(country, c, f)
                end
            end
            if d then
                local sk = d.kind == "research_anomaly" and "anomaly" or d.kind
                M.stats[sk] = (M.stats[sk] or 0) + 1
                M.decisions[#M.decisions + 1] = { date = today, country = country, fleet = fid,
                    kind = d.kind, target = d.target, system = d.system, planets = d.planets }
                commands[#commands + 1] = cmds.make("engine.ai.exploration", "command", command, country, fid, d, today)
            else
                M.stats.nothing = M.stats.nothing + 1
            end
        end
    end
end

-- the AI's month: _BlockedSystems emptied (CAIInteriorMinister::MonthlyUpdate 0xbb419b)
function M.monthly(country)
    M.blocked[country] = nil
end

-- M.log() -> text: the decisions, one a line ("date country fleet kind target")
function M.log()
    local lines = {}
    for _, d in ipairs(M.decisions) do
        slice.tick("ai/exploration.lua:830")
        lines[#lines + 1] = string.format("%s %d fleet %d %s %s%s", d.date or "?", d.country, d.fleet, d.kind,
            d.target and tostring(d.target) or "", d.planets and (" planets " .. table.concat(d.planets, " ")) or "")
    end
    return table.concat(lines, "\n")
end

function M.report()
    local s = M.stats
    return string.format("ai exploration: %d weeks, %d science ships seen (%d busy), %d anomalies, %d surveys, %d returns, %d idle; %d systems blocked; commands %d executed, %d recorded",
        s.weeks, s.fleets, s.busy, s.anomaly or 0, s.survey or 0, s["return"] or 0, s.nothing, s.blocked, s.executed, s.recorded)
end

M.ctor = { command = command }

return M
