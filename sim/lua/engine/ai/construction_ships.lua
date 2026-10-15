-- engine/ai/construction_ships.lua : the AI's construction ships (docs/stations.md, docs/ai.md
-- section 6), the constructor branch of CAIInteriorMinister::HandleCivilianFleets (GOG 4.5.2
-- 0xbbab50, at 0xbbbf94-0xbbc11b) on the AI's week, in the fleets' order (starbases first):
--
--   a civilian construction ship (shipclass_constructor) not MIA, not between systems, mobile:
--     with an actual order (IsActualOrder), or while the AI's DirtyExpandStrategy flag is set (an
--     outpost finished since the last strategic data): counted, nothing ordered
--     else BuildStation(fleet, taken, first = no construction ship counted yet this week)
--   then CToggleAINeedsStationsCommand when "a construction ship was counted" differs from the
--   AI's NeedsStations flag (kept in Lua: no save writes it, M.needs_stations)
--
-- CAIInteriorMinister::BuildStation (0xbbe150):
--   (not ported: BuildStationForSpecialProject, when not in war mode)
--   FindDepositHolderForOrbitalStation (0xbbd230): one draw of the AI's unsynced generator (the
--     scope's seed, CAIModule::GetRandomInt); the BUILD_ORBITAL_STATION list (3) in its order:
--     the holder not taken this week, no station on it, a class the fleet can build
--     (construction_capabilities), no other construction ship whose executing order goes to that
--     system; a mining or research station: CDepositHolder::CanBuildStation, known orbital
--     resources, and the budget (CanAffordExpenditure of the cost, CanAffordUpkeep of the upkeep
--     less EXPANSION_RESOURCE_GAIN_UPKEEP of a mining station's output); the score -jumps *
--     CONSTRUCTION_SHIP_DISTANCE_PENALTY, the best (a later one on a tie) whose path is clear
--   no holder, or the first construction ship of the week: FindPlanetForStarbase (0xbbc820): the
--     outpost design's cost affordable; the EXPAND_BORDERS list (19) in its order: not a system of
--     ours with a starbase, not taken, CanBuildStation(star, starbase), the path clear, the
--     upkeep (less the system's orbital resources * EXPANSION_RESOURCE_GAIN_UPKEEP) affordable;
--     score = value - jumps * CONSTRUCTION_SHIP_DISTANCE_PENALTY + (draw % EXPANSION_RANDOM_AMOUNT)
--     (one AI draw a candidate), the best above 0
--   nothing: (not ported: megastructures) a fleet outside our systems returns to base
--   else, when the budget pays: CFleetBuildOrbitalStationCommand(fleet, holder, class) posted,
--     its cost withdrawn from the budget, the holder taken
--
-- The command executes after every AI decided (engine.ai): the fleet's orders cleared, then the
-- order (engine.fleets.stations.build_order) through engine.fleets.orders, whose start pays it.
-- STELLAR_AI_CONSTRUCTION=off turns the decisions off.

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local cmds = require("engine.ai.commands")
local defs = require("engine.defs")

local M = {
    stats = { weeks = 0, fleets = 0, busy = 0, dirty = 0, stations = 0, starbases = 0, nothing = 0,
              unaffordable = 0, returns = 0, draws = 0, executed = 0, failed = 0, toggles = 0 },
    decisions = {}, -- { date, country, fleet, kind, target, class }
    -- STELLAR_AI_CONSTRUCTION_TRACE=1: every list 3 candidate looked at, one a line
    trace = os.getenv("STELLAR_AI_CONSTRUCTION_TRACE") and {} or nil,
}
local S = M.stats
local NO_ID = 4294967295

local function stations()
    return require("engine.fleets.stations")
end
local function strategy()
    return require("engine.ai.strategy")
end
local function exploration()
    return require("engine.ai.exploration")
end
local function budget()
    return require("engine.ai.budget")
end
local function rng()
    return require("engine.ai.rng")
end

-- ---------------------------------------------------------------------------------------------
-- defines

local D
local function defines()
    if D == nil then
        local g = defs.get("common/defines", "NAI")
        local function v(k, default)
            return g and tonumber(defs.field(g.block, k)) or default
        end
        D = {
            PENALTY = v("CONSTRUCTION_SHIP_DISTANCE_PENALTY", 20),
            RANDOM = v("EXPANSION_RANDOM_AMOUNT", 50),
            GAIN = v("EXPANSION_RESOURCE_GAIN_UPKEEP", 0.5),
            MIN_HIGH = v("EXPANSION_MIN_VALUE_FOR_HIGH_PRIO", 10),
        }
    end
    return D
end

-- ---------------------------------------------------------------------------------------------
-- fleets

local function fleet(id)
    return world.object("fleet", id)
end

local function prop(f, key)
    local p = world.field(f, "properties")
    return type(p) == "table" and world.field(p, key) == "yes"
end

-- the fleet's construction_capabilities (its ships' ship sizes): CFleet::HasConstructionCapability
-- (0xc5f770), CFleet::HasShipClassConstructionCapability (0xc5f890: 5 mining_station, 6
-- research_station, 9 observation_station, 10 starbase)
local CAPABILITY = { [5] = "mining_station", [6] = "research_station", [9] = "observation_station", [10] = "starbase" }
local cap_cache = {}
local function capabilities(size)
    local c = cap_cache[size]
    if c == nil then
        c = {}
        local d = size and defs.get("common/ship_sizes", size)
        local b = d and defs.field(d.block, "construction_capabilities")
        for _, x in ipairs(type(b) == "table" and world.list(b) or {}) do c[x] = true end
        cap_cache[size] = c
    end
    return c
end
local function can_build_class(f, class)
    local want = CAPABILITY[class]
    if not want then
        return false
    end
    local st = stations()
    for _, s in ipairs(world.list(world.field(f, "ships"))) do
        slice.tick("ai/construction_ships.lua:121")
        local ship = world.object("ship", tonumber(s))
        local sdi = ship and world.field(ship, "ship_design_implementation")
        local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
        if did and capabilities(st.design_size(did))[want] then
            return true
        end
    end
    return false
end
M.can_build_class = can_build_class

-- the system the executing order (the deepest of the current order's chain) goes to
local function executing_target_system(f)
    local chain = exploration().order_chain(f)
    local last = chain[#chain]
    if not last then
        return nil
    end
    local c = world.field(last.body, "coordinate")
    if type(c) == "table" then
        return tonumber(world.field(c, "origin"))
    end
    local dh = world.field(last.body, "deposit_holder")
    local pid = type(dh) == "table" and tonumber(world.field(dh, "id"))
    if pid then
        return strategy().galaxy().system_of[pid]
    end
    local ob = world.field(last.body, "orbitable")
    local p = type(ob) == "table" and tonumber(world.field(ob, "planet"))
    return p and strategy().galaxy().system_of[p] or nil
end

-- NAIUtil::CalcDistance (0xba2d90) [I]: the jumps of the path (strategy.jumps_from)
local function jumps(from, to)
    if from == nil or to == nil then
        return 65535
    end
    if from == to then
        return 0
    end
    return strategy().jumps_from(from)[to] or 65535
end

-- NAIUtil::IsPathClear(fleet, system, real fleets) (0xba20c0) [I]: a path, every system on it
-- without a hostile armed fleet
local function hostile(us, other)
    if other == nil or other == us then
        return false
    end
    local o = require("engine.ai.opinion")
    if o.rflag(o.relation(us, other), "hostile") then
        return true
    end
    return o.at_war(us, other)
end
local by_system, by_key
local function fleets_in(sid, today)
    local key = tostring(world.tree) .. "/" .. tostring(today)
    if by_key ~= key then
        by_key, by_system = key, {}
        for _, fid in ipairs(world.all("fleet")) do
            slice.tick("ai/construction_ships.lua:181")
            local f = fleet(fid)
            local s = f and exploration().system_of(f)
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
local function path_clear(us, from, to, today)
    if from == nil or to == nil then
        return false
    end
    local p = exploration().path(from, to)
    if p == nil then
        return false
    end
    for _, sid in ipairs(p) do
        slice.tick("ai/construction_ships.lua:206")
        for _, fid in ipairs(fleets_in(sid, today)) do
            slice.tick("ai/construction_ships.lua:207")
            local f = fleet(fid)
            if f and not prop(f, "civilian") and (tonumber(world.field(f, "military_power")) or 0) > 0
                and hostile(us, world.fleet_owner[fid]) then
                return false
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the budget

local function minus_gain(upkeep, gains)
    local d = defines()
    local out = {}
    for r, v in pairs(upkeep) do out[r] = v end
    for r, v in pairs(gains) do
        slice.tick("ai/construction_ships.lua:225")
        out[r] = (out[r] or 0) - v * d.GAIN
    end
    return out
end

local function affordable(us, category, cost, upkeep)
    local b = budget()
    return b.can_afford_expenditure(us, category, cost) and b.can_afford_upkeep(us, category, upkeep or {})
end

-- ---------------------------------------------------------------------------------------------
-- FindDepositHolderForOrbitalStation (0xbbd230)

local function station_on(pid)
    local p = world.object("planet", pid)
    local f = p and tonumber(world.field(p, "shipclass_orbital_station"))
    return f ~= nil and world.object("fleet", f) ~= nil
end

local function find_deposit_holder(us, f, fid, taken, constructors, today)
    local st = stations()
    local d = defines()
    rng().draw(us)
    S.draws = S.draws + 1
    local from = exploration().system_of(f)
    local best, best_class, best_score
    for _, e in ipairs(strategy().entries(us, strategy().TYPES.BUILD_ORBITAL_STATION)) do
        slice.tick("ai/construction_ships.lua:252")
        local pid, class = e.id, e.target
        if pid and not taken["0:" .. pid] and world.object("planet", pid) and not station_on(pid)
            and class ~= 14 and can_build_class(f, class) then
            local sid = strategy().galaxy().system_of[pid]
            local other = false
            for _, cf in ipairs(constructors) do
                slice.tick("ai/construction_ships.lua:258")
                if cf ~= fid then
                    local cfl = fleet(cf)
                    if cfl and can_build_class(cfl, class) and executing_target_system(cfl) == sid then
                        other = true
                        break
                    end
                end
            end
            local ok = false
            if not other then
                if class == 5 or class == 6 then
                    if st.can_build_station(us, pid, class) then
                        local gains = st.known_orbital_resources(pid, us)
                        if next(gains) ~= nil then
                            local cost, category = st.stage_table(us, class, "cost")
                            local upkeep = st.stage_table(us, class, "upkeep")
                            if class == 5 then upkeep = minus_gain(upkeep, gains) end
                            ok = affordable(us, category, cost, upkeep)
                        end
                    end
                elseif class == 9 then
                    ok = st.can_build_station(us, pid, class)
                else
                    ok = true
                end
            end
            if ok then
                local score = -jumps(from, sid) * d.PENALTY
                if not (best ~= nil and score < best_score) and path_clear(us, from, sid, today) then
                    best, best_class, best_score = pid, class, score
                end
            end
            if M.trace then
                M.trace[#M.trace + 1] = string.format("%s %d fleet %d list3 planet %d class %d other %s ok %s", today, us, fid, pid, class, tostring(other), tostring(ok))
            end
        end
    end
    return best, best_class
end

-- ---------------------------------------------------------------------------------------------
-- FindPlanetForStarbase (0xbbc820)

local function find_planet_for_starbase(us, c, f, taken, high_prio_only, today)
    local st = stations()
    local d = defines()
    local ai = require("engine.ai")
    if ai.human(us) then
        return nil
    end
    local cost, category = st.stage_table(us, st.CLASS.shipclass_starbase, "cost")
    if not budget().can_afford_expenditure(us, category, cost) then
        return nil
    end
    local upkeep0 = st.stage_table(us, st.CLASS.shipclass_starbase, "upkeep")
    local g = strategy().galaxy()
    local from = exploration().system_of(f)
    local best, best_score = nil, 0
    for _, e in ipairs(strategy().entries(us, strategy().TYPES.EXPAND_BORDERS)) do
        slice.tick("ai/construction_ships.lua:317")
        local pid = e.id
        local sid = pid and g.system_of[pid]
        if sid and not (st.primary_starbase(sid) and world.system_owner[sid] == us) and not taken["0:" .. pid]
            and st.can_build_station(us, pid, st.CLASS.shipclass_starbase)
            and not (high_prio_only and strategy().expansion_value(us, sid) < d.MIN_HIGH)
            and path_clear(us, from, sid, today) then
            local gains = {}
            for _, p in ipairs(g.planets_of[sid] or {}) do
                slice.tick("ai/construction_ships.lua:325")
                for r, v in pairs(st.known_orbital_resources(p, us)) do gains[r] = (gains[r] or 0) + v end
            end
            if budget().can_afford_upkeep(us, category, minus_gain(upkeep0, gains)) then
                local score = (e.value or 0) - jumps(from, sid) * d.PENALTY
                if d.RANDOM > 0 then
                    score = score + rng().draw(us) % d.RANDOM
                    S.draws = S.draws + 1
                end
                if score > best_score then
                    best, best_score = pid, score
                end
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------------------------
-- BuildStation (0xbbe150)

local function command(us, fid, d)
    return {
        kind = "fleet_" .. d.kind, country = us, fleet = fid, target = d.target,
        execute = function()
            local orders = require("engine.fleets.orders")
            local st = stations()
            if d.kind == "build_station" then
                -- CFleetBuildOrbitalStationCommand::Execute (0xa57650): ClearOrders, then AddOrder
                if orders.current(fid) or #orders.queue(fid) > 0 then
                    orders.clear(fid)
                end
                local ok = orders.issue(fid, st.build_order(d.target, d.class, us))
                if ok then
                    S.executed = S.executed + 1
                    return true
                end
            elseif d.kind == "return" then
                if orders.return_to_base(fid) then
                    S.executed = S.executed + 1
                    return true
                end
            end
            S.failed = S.failed + 1
            return false
        end,
    }
end

local function build_station(us, c, fid, f, taken, first, constructors, commands, today)
    local st = stations()
    local holder, class = find_deposit_holder(us, f, fid, taken, constructors, today)
    if holder then
        -- the class: an observation post when the fleet can (never here), else the holder's
        -- orbital deposit's
        local dc = st.orbital_class(holder)
        class = (dc and can_build_class(f, dc)) and dc or nil
    end
    if (holder == nil or first) and can_build_class(f, st.CLASS.shipclass_starbase) then
        local p = find_planet_for_starbase(us, c, f, taken, false, today)
        if p then
            holder, class = p, st.CLASS.shipclass_starbase
        end
    end
    if holder == nil then
        -- nothing to build: outside our systems, back to base (CQueueFleetsOrderCommand of a
        -- CReturnFleetOrder; the stance command before it not modelled)
        local sid = exploration().system_of(f)
        if sid and world.system_owner[sid] ~= us then
            S.returns = S.returns + 1
            commands[#commands + 1] = cmds.make("engine.ai.construction_ships", "command", command, us, fid, { kind = "return" })
            M.decisions[#M.decisions + 1] = { date = today, country = us, fleet = fid, kind = "return" }
        else
            S.nothing = S.nothing + 1
        end
        return false
    end
    if class == nil then
        S.nothing = S.nothing + 1
        return true
    end
    local cost, category = st.stage_table(us, class, "cost")
    local upkeep = {}
    if class ~= st.CLASS.shipclass_starbase then
        upkeep = st.stage_table(us, class, "upkeep")
        if class == st.CLASS.shipclass_mining_station then
            upkeep = minus_gain(upkeep, st.known_orbital_resources(holder, us))
        end
    end
    if not affordable(us, category, cost, upkeep) then
        S.unaffordable = S.unaffordable + 1
        return true
    end
    commands[#commands + 1] = cmds.make("engine.ai.construction_ships", "command", command, us, fid, { kind = "build_station", target = holder, class = class })
    budget().withdraw(us, category, cost)
    taken["0:" .. holder] = true
    if class == st.CLASS.shipclass_starbase then S.starbases = S.starbases + 1 else S.stations = S.stations + 1 end
    M.decisions[#M.decisions + 1] = { date = today, country = us, fleet = fid, kind = "build_station", target = holder,
        class = st.CLASS_NAME[class] }
    return true
end

-- the holders the country's fleets' current orders target (HandleCivilianFleets' first loop)
local TAKEN = {
    survey_planet_order = true, research_anomaly_order = true, colonize_planet_order = true,
    build_orbital_station_order = true, collect_data_fleet_order = true,
    build_megastructure_fleet_order = true, assist_detection_order = true,
}
local function taken_of(fleets)
    local taken = {}
    for _, fid in ipairs(fleets) do
        slice.tick("ai/construction_ships.lua:435")
        local f = fleet(fid)
        for _, o in ipairs(f and exploration().order_chain(f) or {}) do
            slice.tick("ai/construction_ships.lua:437")
            if TAKEN[o.kind] then
                local dh = world.field(o.body, "deposit_holder")
                local t = type(dh) == "table" and tonumber(world.field(dh, "type"))
                local id = type(dh) == "table" and tonumber(world.field(dh, "id"))
                if t and id then
                    taken[t .. ":" .. id] = true
                else
                    local p = tonumber(world.field(o.body, "planet"))
                    if p then taken["0:" .. p] = true end
                end
                break
            end
        end
    end
    return taken
end

-- CToggleAINeedsStationsCommand::Execute (0x6c4a80): NeedsStations (EAICountryFlags 2)
-- flipped. ReadMember reads it as `station`, but no AI block of the 2210-2212 saves (every one
-- with construction ships) has it, so it is kept here, not written [I]: M.needs_stations, from
-- the save's `station` at the first look
M.needs_stations = {}
local function needs_stations(us, ai)
    local v = M.needs_stations[us]
    if v == nil then
        v = world.field(ai, "station") == "yes"
        M.needs_stations[us] = v
    end
    return v
end
local function toggle_needs_stations(us)
    return {
        kind = "toggle_needs_stations", country = us,
        internal = true,   -- the AI's own flag: a worker flips it itself (engine.store.worker)
        execute = function()
            M.needs_stations[us] = not M.needs_stations[us]
            S.toggles = S.toggles + 1
            return true
        end,
    }
end

-- M.weekly(country, today, commands): the construction ships of HandleCivilianFleets
function M.weekly(country, today, commands, host)
    if os.getenv("STELLAR_AI_CONSTRUCTION") == "off" then
        return
    end
    local c = world.object("country", country)
    local ai = c and world.field(c, "ai")
    if type(ai) ~= "table" then
        return
    end
    S.weeks = S.weeks + 1
    local ex = exploration()
    local fleets = ex.owned_fleets(c)
    local taken = taken_of(fleets)
    local constructors = {}
    for _, fid in ipairs(fleets) do
        slice.tick("ai/construction_ships.lua:495")
        local f = fleet(fid)
        if f and world.field(f, "ship_class") == "shipclass_constructor" then
            constructors[#constructors + 1] = fid
        end
    end
    local counted, needs = 0, false
    local dirty = world.field(ai, "dirty_expand_strategy") == "yes"
    for _, fid in ipairs(constructors) do
        slice.tick("ai/construction_ships.lua:503")
        local f = fleet(fid)
        local mm = world.field(f, "movement_manager")
        local between = type(mm) == "table" and world.field(mm, "state") == "move_galaxy"
        if prop(f, "civilian") and prop(f, "mobile") and not prop(f, "mia") and not between then
            S.fleets = S.fleets + 1
            if ex.busy(f) then
                S.busy = S.busy + 1
            elseif dirty then
                S.dirty = S.dirty + 1
            else
                build_station(country, c, fid, f, taken, counted == 0, constructors, commands, today)
            end
            counted = counted + 1
            needs = true
        end
    end
    if needs ~= needs_stations(country, ai) then
        commands[#commands + 1] = toggle_needs_stations(country)
    end
end

function M.log()
    local lines = {}
    for _, d in ipairs(M.decisions) do
        slice.tick("ai/construction_ships.lua:527")
        lines[#lines + 1] = string.format("%s %d fleet %d %s%s%s", d.date or "?", d.country, d.fleet, d.kind,
            d.target and (" " .. d.target) or "", d.class and (" " .. d.class) or "")
    end
    return table.concat(lines, "\n")
end

function M.report()
    return string.format("ai construction ships: %d weeks, %d ships seen (%d busy, %d waiting for the strategic data), %d stations and %d starbases ordered, %d unaffordable, %d returns, %d idle; %d AI draws; commands %d executed, %d failed; %d NeedsStations toggles",
        S.weeks, S.fleets, S.busy, S.dirty, S.stations, S.starbases, S.unaffordable, S.returns, S.nothing, S.draws,
        S.executed, S.failed, S.toggles)
end

M.ctor = { command = command }

return M
