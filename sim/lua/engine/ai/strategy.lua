-- engine/ai/strategy.lua : the AI's strategic data, the save's `ai = { strategy = { id target value
-- type } ... }` (docs/ai.md section 9). CAIStrategicBase (GOG 4.5.2) holds 33 lists of CAIStrategy
-- { _nVal value, _nTarget target, _nID id, _Token }, one per STRATEGIC_DATA_TYPES; the save writes
-- every list in type order, each stable-sorted by (id, target) (CCountryAI::WriteMembers 0xb73e50),
-- the token not written.
--
-- The lists are not kept: they are built again from the world. Once a month, in
-- CGameState::MonthlyUpdate after the countries' parallel update and before
-- CCountry::MonthlyUpdateSerial, every country with an AI gets CCountryAI::CreateStrategicData
-- (0xb6e0a0, through CCountry::MonthlyUpdateStrategy, a parallel pass): for a `relations = yes`
-- country type, CreateColonizeData (0xb6f280) clears the lists 1, 2, 3, 19, 23, 24, 29 and fills
-- them again from the galaxy; then the modules' CreateStrategicData (the military minister: 6, 14,
-- 15, 17, 18, 22, 25, 26, 28, 30, 32; the interior minister: 31). The same function runs when the
-- country's war state changes (CAIUpdateStrategicData, posted by CCountryAI::DailyUpdate) and for
-- the effect run_ai_strategic_data.
--
-- Ported (CreateColonizeData):
--
--   2  EXPLORE    id = system, target 0, value = max(AI_MAX_DISTANCE - jumps(capital, system), 1),
--                 x 5 when every hyperlane neighbour is ours, x 2 when the system otherwise borders
--                 ours: a system nobody else owns with a star and a planet we have not surveyed,
--                 for a country that colonizes (the type's ai.colonizer, not personality `limited`)
--   23 TERRAFORM  id = planet, target 0, value 1: each surveyed planet of such a system (with a
--                 star), for a country with the feature flag build_terraform_station that does not
--                 colonize (fallen empires), or (colonizers) a planet it cannot colonize
--
-- Kept as the save has them (not built here yet): 1 COLONIZE (AddColonyData, the synced AI draw),
-- 3 BUILD_ORBITAL_STATION (CDepositHolder::CanBuildStation), 19 EXPAND_BORDERS (ShouldExpand),
-- 24 EXPLORE_BYPASS, 29 LOCK_BYPASS, 9 BUILD_SHIP and 10 BUILD_ARMY (CreateNavyBuildData,
-- CreateArmyBuildData), 0 CONQUER (CreateConquerData, claims), and the military minister's lists
-- (fleets).
--
--   strategy.monthly(host, date)   the month's update (systems.lua, monthly.countries_serial)
--   strategy.compute(country)      the ported lists of a country: { {type, id, target, value} }
--   strategy.compare()             the ported lists against the world's own (a loaded save)

local world = require("engine.world")
local defs = require("engine.defs")

local strategy = {
    stats = { months = 0, countries = 0, colonize = 0, entries = 0, kept = 0, seconds = 0 },
}

local NO_ID = 4294967295
local floor = math.floor

-- STRATEGIC_DATA_TYPES (the PDB's enum)
local T = {
    CONQUER = 0, COLONIZE = 1, EXPLORE = 2, BUILD_ORBITAL_STATION = 3, ANTAGONIZE = 4, BEFRIEND = 5,
    PROTECT = 6, INFLUENCE = 7, ALLIANCE = 8, BUILD_SHIP = 9, BUILD_ARMY = 10, BUILD_BUILDING = 11,
    RESEARCH_TECH = 12, GARRISON = 13, HOSTILE_FLEETS = 14, HOSTILE_COUNTRY_FLEET_SYSTEMS = 15,
    CONTAIN = 16, INVADE = 17, ATTACK = 18, EXPAND_BORDERS = 19, UNIT_RATIO = 20, UNIT_BASE = 21,
    DESTROY = 22, TERRAFORM = 23, EXPLORE_BYPASS = 24, DEFEND = 25, FOLLOW = 26, VISIT_CAPITAL = 27,
    GATHER_FOR_WAR = 28, LOCK_BYPASS = 29, SCRIPTED_ACTION = 30, POI_SYSTEMS = 31, RAID = 32,
}
strategy.TYPES = T

-- the lists this module builds (the others of CreateColonizeData's are kept); the stations (3) and
-- the expansion (19) with engine.fleets.stations (CDepositHolder::CanBuildStation)
local PORTED = { [T.EXPLORE] = true, [T.TERRAFORM] = true, [T.BUILD_ORBITAL_STATION] = true, [T.EXPAND_BORDERS] = true }
strategy.PORTED = PORTED

-- ---------------------------------------------------------------------------------------------
-- defines

local D
local function defines()
    if D == nil then
        local function v(group, key, default)
            local g = defs.get("common/defines", group)
            return g and tonumber(defs.field(g.block, key)) or default
        end
        D = {
            AI_MAX_DISTANCE = v("NAI", "AI_MAX_DISTANCE", 200),
            AI_BUDGETING_START_YEARS = v("NAI", "AI_BUDGETING_START_YEARS", 15),
            START_YEAR = v("NGameplay", "START_YEAR", 2200),
            -- the expansion (list 19)
            MAX_EXPANSION_DISTANCE = v("NAI", "MAX_EXPANSION_DISTANCE", 2),
            MAX_EXPANSION_DISTANCE_SUBJECT = v("NAI", "MAX_EXPANSION_DISTANCE_SUBJECT", 2),
            EXPANSION_OWN_PRIORITY = v("NAI", "EXPANSION_OWN_PRIORITY", 1000),
            EXPANSION_CUT_OFF_SYSTEM_PRIORITY = v("NAI", "EXPANSION_CUT_OFF_SYSTEM_PRIORITY", 10),
            EXPANSION_BORDERING_PRIORITY = v("NAI", "EXPANSION_BORDERING_PRIORITY", 500),
            EXPANSION_RESOURCE_PRIORITY = v("NAI", "EXPANSION_RESOURCE_PRIORITY", 2),
            EXPANSION_COLONY_PRIORITY = v("NAI", "EXPANSION_COLONY_PRIORITY", 400),
            EXPANSION_BYPASS_PRIORITY = v("NAI", "EXPANSION_BYPASS_PRIORITY", 10),
        }
    end
    return D
end

-- ---------------------------------------------------------------------------------------------
-- the galaxy: systems in the game's order, their planets, hyperlanes and bypasses, stars

local star_class = {}
local function is_star_class(class)
    local v = star_class[class]
    if v == nil then
        local d = class and defs.get("common/planet_classes", class)
        v = d ~= nil and defs.field(d.block, "star") == "yes"
        star_class[class] = v
    end
    return v
end

local G
local function galaxy()
    if G and G.tree == world.tree then
        return G
    end
    G = { tree = world.tree, systems = {}, planets_of = {}, system_of = {}, lanes = {}, bypasses_of = {},
          bypass_system = {}, star = {}, jumps = {} }
    for _, sid in ipairs(world.all("system")) do
        local s = world.object("system", sid)
        G.systems[#G.systems + 1] = sid
        local planets = {}
        for i, p in ipairs(world.fields(s, "planet")) do
            local pid = tonumber(p)
            if pid then
                planets[#planets + 1] = pid
                G.system_of[pid] = sid
            end
        end
        G.planets_of[sid] = planets
        local lanes = {}
        for _, h in ipairs(world.blocks(world.field(s, "hyperlane"))) do
            local to = tonumber(world.field(h, "to"))
            if to then
                lanes[#lanes + 1] = { to = to, length = tonumber(world.field(h, "length")) or 0 }
            end
        end
        G.lanes[sid] = lanes
        local bps = {}
        for _, b in ipairs(world.list(world.field(s, "bypasses"))) do
            local bid = tonumber(b)
            if bid and bid ~= NO_ID then
                bps[#bps + 1] = bid
                G.bypass_system[bid] = sid
            end
        end
        G.bypasses_of[sid] = bps
        -- the first planet of the system whose class is a star (CPlanetClass IsStar, settings bit 10)
        for _, pid in ipairs(planets) do
            if is_star_class(world.field(world.object("planet", pid), "planet_class")) then
                G.star[sid] = pid
                break
            end
        end
    end
    return G
end
strategy.galaxy = galaxy

-- CGalacticDistanceCache::GetHyperlaneJumps (0xa52140): the jumps of the shortest path by hyperlane
-- length (BuildHyperlaneDistances, an A* by length per pair, its result policy keeping the length
-- and the jumps); 65535 when there is no path. Here a Dijkstra by length from the source, ties to
-- the fewer jumps.
local function jumps_from(src)
    local g = galaxy()
    local t = g.jumps[src]
    if t then
        return t
    end
    local dist, jumps = { [src] = 0 }, { [src] = 0 }
    local heap = { { 0, 0, src } }
    local function less(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end
    local function push(x)
        heap[#heap + 1] = x
        local i = #heap
        while i > 1 do
            local p = floor(i / 2)
            if less(heap[i], heap[p]) then
                heap[i], heap[p] = heap[p], heap[i]
                i = p
            else
                break
            end
        end
    end
    local function pop()
        local top = heap[1]
        local last = heap[#heap]
        heap[#heap] = nil
        if #heap > 0 then
            heap[1] = last
            local i = 1
            while true do
                local l, r, m = 2 * i, 2 * i + 1, i
                if l <= #heap and less(heap[l], heap[m]) then m = l end
                if r <= #heap and less(heap[r], heap[m]) then m = r end
                if m == i then break end
                heap[i], heap[m] = heap[m], heap[i]
                i = m
            end
        end
        return top
    end
    local done = {}
    while #heap > 0 do
        local x = pop()
        local d, j, s = x[1], x[2], x[3]
        if not done[s] and d == dist[s] and j == jumps[s] then
            done[s] = true
            for _, lane in ipairs(g.lanes[s] or {}) do
                local nd, nj = d + lane.length, j + 1
                local od = dist[lane.to]
                if od == nil or nd < od or (nd == od and nj < jumps[lane.to]) then
                    dist[lane.to], jumps[lane.to] = nd, nj
                    push({ nd, nj, lane.to })
                end
            end
        end
    end
    g.jumps[src] = jumps
    return jumps
end
strategy.jumps_from = jumps_from

-- ---------------------------------------------------------------------------------------------
-- the country

local function country(id)
    return world.object("country", id)
end

local function type_def(c)
    local ty = world.field(c, "type")
    return ty and defs.get("common/country_types", ty)
end

-- a country type's `key = yes`
local tflag_cache = {}
local function type_flag(c, key)
    local ty = tostring(world.field(c, "type"))
    local k = ty .. "/" .. key
    local v = tflag_cache[k]
    if v == nil then
        local d = type_def(c)
        v = d ~= nil and defs.field(d.block, key) == "yes"
        tflag_cache[k] = v
    end
    return v
end

-- CCountry +0x1b28's AI colonizes: the type's ai.colonizer (SCountryAISettings bit 2) and the
-- personality not `limited` (SPersonalityBehaviour +0x1d) (0xb6f6c2)
local function colonizes(id)
    local ai = require("engine.ai")
    if not ai.setting(id, "colonizer") then
        return false
    end
    local op = require("engine.ai.opinion")
    return not op.behaviour(id, "limited")
end

-- CTechnologyStatus::HasFeatureFlag: the `feature_flags` of the researched technologies
-- (_FeatureFlags, RebuildFeatureFlags); a type with all_technology_module has every technology
local feature_cache = {}
local function feature_flags_of(tech)
    local f = feature_cache[tech]
    if f == nil then
        f = {}
        local d = defs.get("common/technology", tech)
        local ff = d and defs.field(d.block, "feature_flags")
        for _, x in ipairs(type(ff) == "table" and world.list(ff) or {}) do
            f[x] = true
        end
        feature_cache[tech] = f
    end
    return f
end
local function all_technologies(c)
    local d = type_def(c)
    local mods = d and defs.field(d.block, "modules")
    return type(mods) == "table" and defs.field(mods, "all_technology_module") ~= nil
end
local function has_feature_flag(c, flag)
    if all_technologies(c) then
        for name in pairs(defs.folder("common/technology")) do
            if feature_flags_of(name)[flag] then
                return true
            end
        end
        return false
    end
    local ts = world.field(c, "tech_status")
    for _, t in ipairs(type(ts) == "table" and world.fields(ts, "technology") or {}) do
        if type(t) == "string" and feature_flags_of(t)[flag] then
            return true
        end
    end
    return false
end
strategy.has_feature_flag = has_feature_flag

-- NAIUtil::ListSurveyed (0xba2b30): the planets of surveyed_deposit_holders (type 0), the
-- controlled planets with a colony, the planets of the owned colonies
local function surveyed_set(c)
    local A = {}
    for _, e in ipairs(world.blocks(world.field(c, "surveyed_deposit_holders"))) do
        if tonumber(world.field(e, "type")) == 0 then
            local id = tonumber(world.field(e, "id"))
            if id then A[id] = true end
        end
    end
    for _, p in ipairs(world.list(world.field(c, "controlled_planets"))) do
        local pid = tonumber(p)
        local planet = pid and world.object("planet", pid)
        local col = planet and tonumber(world.field(planet, "colony"))
        if col and col ~= NO_ID then A[pid] = true end
    end
    for _, x in ipairs(world.list(world.field(c, "owned_planets"))) do
        local pid = world.colony_planet[tonumber(x)]
        if pid then A[pid] = true end
    end
    return A
end

-- the capital's system: _Capital (a colony) -> its carrier (the planet) -> the planet's system
local function capital_system(c)
    local col = tonumber(world.field(c, "capital"))
    local pid = col and world.colony_planet[col]
    return pid and galaxy().system_of[pid]
end

local function usable_bypasses(c)
    local set = {}
    for _, b in ipairs(world.list(world.field(c, "usable_bypasses"))) do
        set[tonumber(b)] = true
    end
    return set
end

-- CCountryBorderManager::CalcIsBorderingSystem(system, 0, true) (0xa0e850) for a system nobody else
-- owns: ours, or a hyperlane neighbour ours, or a bypass we can use linked to a bypass of ours
local function borders(id, sid, usable)
    local g = galaxy()
    if world.system_owner[sid] == id then
        return true
    end
    for _, lane in ipairs(g.lanes[sid] or {}) do
        if world.system_owner[lane.to] == id then
            return true
        end
    end
    for _, bid in ipairs(g.bypasses_of[sid] or {}) do
        if usable[bid] then
            for _, other in ipairs(world.list(world.field(world.object("bypasses", bid), "connections"))) do
                local ob = tonumber(other)
                local os = ob and g.bypass_system[ob]
                if usable[ob] and os and world.system_owner[os] == id then
                    return true
                end
            end
        end
    end
    return false
end

-- CCountryBorderManager::IsBorderingOnlyOurSystemsUsingHyperlanes (0xa0f670)
local function only_ours(id, sid)
    for _, lane in ipairs(galaxy().lanes[sid] or {}) do
        if world.system_owner[lane.to] ~= id then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the stations (list 3) and the expansion (list 19): docs/stations.md

local function stations()
    return require("engine.fleets.stations")
end

-- CGalacticObject::HasColonizablePlanet(country, true) (0x86f920) [I]: an unowned planet of a
-- colonizable class
local function has_colonizable_planet(sid)
    local st = stations()
    for _, pid in ipairs(galaxy().planets_of[sid] or {}) do
        if st.colonizable(pid) then
            return true
        end
    end
    return false
end

-- NAIUtil::CalcResourceSum (0xba5520): the known orbital resources of the system's planets,
-- every resource summed
local function resource_sum(id, sid)
    local st = stations()
    local s = 0
    for _, pid in ipairs(galaxy().planets_of[sid] or {}) do
        for _, v in pairs(st.known_orbital_resources(pid, id)) do
            s = s + v
        end
    end
    return s
end

-- NAIUtil::CalcExpansionValue (0xba5390): resources * EXPANSION_RESOURCE_PRIORITY, +
-- EXPANSION_COLONY_PRIORITY with a colonizable planet, + EXPANSION_BYPASS_PRIORITY with a bypass,
-- + EXPANSION_CUT_OFF_SYSTEM_PRIORITY when every neighbour is ours, else
-- EXPANSION_BORDERING_PRIORITY when it borders us
function strategy.expansion_value(id, sid, usable)
    local d = defines()
    local v = resource_sum(id, sid) * d.EXPANSION_RESOURCE_PRIORITY
    if has_colonizable_planet(sid) then
        v = v + d.EXPANSION_COLONY_PRIORITY
    end
    if #(galaxy().bypasses_of[sid] or {}) > 0 then
        v = v + d.EXPANSION_BYPASS_PRIORITY
    end
    if borders(id, sid, usable or usable_bypasses(country(id))) then
        v = v + (only_ours(id, sid) and d.EXPANSION_CUT_OFF_SYSTEM_PRIORITY or d.EXPANSION_BORDERING_PRIORITY)
    end
    return v
end

-- CCountryBorderManager::CalcNumJumpsFromBorder (0xa0f2d0): the fewest jumps (GetJumps) from one
-- of our systems
local function jumps_from_border(sid, own)
    local best = 2147483647
    for _, s in ipairs(own) do
        local j = (s == sid) and 0 or jumps_from(s)[sid]
        if j and j < best then
            best = j
        end
    end
    return best
end

-- NAIUtil::ShouldBuildStarbase(country, system, false) (0xba4fa0): within MAX_EXPANSION_DISTANCE
-- jumps of the border (a subject: MAX_EXPANSION_DISTANCE_SUBJECT); [not modelled: the systems that
-- would anger a fallen empire, CGameRules::WillAngerFallenEmpire]
local function should_build_starbase(c, sid, own)
    local d = defines()
    local overlord = tonumber(world.field(c, "overlord"))
    local max = (overlord and overlord ~= NO_ID) and d.MAX_EXPANSION_DISTANCE_SUBJECT or d.MAX_EXPANSION_DISTANCE
    return jumps_from_border(sid, own) <= max
end
strategy.should_build_starbase = should_build_starbase

-- ---------------------------------------------------------------------------------------------
-- CCountryAI::CreateColonizeData (0xb6f280), the ported lists

function strategy.compute(id)
    local c = country(id)
    local g = galaxy()
    local d = defines()
    local out = {}
    local function add(t, oid, target, value)
        out[#out + 1] = { type = t, id = oid, target = target, value = value }
    end
    -- NeedsSurvey (ECountryTypeFlags bit 21): the surveyed planets, else every planet counts as surveyed
    local A = type_flag(c, "needs_survey") and surveyed_set(c) or nil
    local colonizer = colonizes(id)
    local terraform = has_feature_flag(c, "build_terraform_station")
    local cap = capital_system(c)
    local cap_jumps = cap and jumps_from(cap)
    local usable = usable_bypasses(c)
    local st = stations()
    local own = {}
    for _, sid in ipairs(g.systems) do
        if world.system_owner[sid] == id then own[#own + 1] = sid end
    end
    for _, sid in ipairs(g.systems) do
        local owner = world.system_owner[sid]
        -- the system's owner: nobody, or us (an enemy's, one without access, another's: skipped)
        if owner == nil or owner == id then
            local unsurveyed = false
            if g.star[sid] then
                for _, pid in ipairs(g.planets_of[sid]) do
                    if A and not A[pid] then
                        unsurveyed = true
                    else
                        if not colonizer then
                            if terraform then
                                add(T.TERRAFORM, pid, 0, 1)
                            end
                        end
                        -- a colonizer: the terraform rule (should_colonize_use_terraform),
                        -- CPlanet::CanColonize, NAIUtil::ShouldColonizePlanet, AddColonyData (1)
                        -- and type 23 for what it cannot colonize: not ported (no colonizer has
                        -- build_terraform_station in the 2210-2212 saves); a planet that becomes a
                        -- colony target gets no station check, but a colonizable planet has none
                        -- to pass anyway (the deposit's class needs a planet nobody can colonize)
                        -- the station check, own systems only: an observation post
                        -- (CanBuildStation(P, 9): never here), else the orbital deposit's class
                        if owner == id then
                            local cls = st.orbital_class(pid)
                            if (cls == st.CLASS.shipclass_mining_station or cls == st.CLASS.shipclass_research_station)
                                and st.can_build_station(id, pid, cls) then
                                add(T.BUILD_ORBITAL_STATION, pid, cls, 1)
                            end
                        end
                    end
                end
            end
            -- the expansion: a colonizer, a star, every planet surveyed, a system nobody owns (or
            -- one of ours without a primary starbase: EXPANSION_OWN_PRIORITY);
            -- CanBuildStation(star, starbase) and ShouldExpand
            local star = g.star[sid]
            if colonizer and star and not unsurveyed and (owner == nil or (owner == id and not st.primary_starbase(sid)))
                and st.can_build_station(id, star, st.CLASS.shipclass_starbase) then
                local v
                if owner == id then
                    v = d.EXPANSION_OWN_PRIORITY
                elseif should_build_starbase(c, sid, own) then
                    v = strategy.expansion_value(id, sid, usable)
                end
                v = v and floor(v) or 0
                if v > 0 then
                    add(T.EXPAND_BORDERS, star, 0, v)
                end
            end
            if unsurveyed and colonizer then
                local j
                if cap == nil then
                    j = 65535
                elseif cap == sid then
                    j = 0
                else
                    j = cap_jumps[sid] or 65535
                end
                local v = d.AI_MAX_DISTANCE - j
                if v < 1 then v = 1 end
                if borders(id, sid, usable) then
                    v = only_ours(id, sid) and v * 5 or v * 2
                end
                add(T.EXPLORE, sid, 0, v)
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the save's form

local function entry_of(e)
    local v = e.value
    return {
        type = tonumber(world.field(v, "type")), id = tonumber(world.field(v, "id")),
        target = tonumber(world.field(v, "target")), value = tonumber(world.field(v, "value")),
    }
end

local function block_of(s)
    return {
        { key = { text = "id" }, op = "=", value = { text = string.format("%d", s.id) } },
        { key = { text = "target" }, op = "=", value = { text = string.format("%d", s.target) } },
        { key = { text = "value" }, op = "=", value = { text = string.format("%d", s.value) } },
        { key = { text = "type" }, op = "=", value = { text = string.format("%d", s.type) } },
    }
end

-- CCountryAI::WriteMembers: the lists in type order, each stable-sorted by (id, target)
local function sorted(list)
    for i, s in ipairs(list) do s.n = i end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        if a.id ~= b.id then return a.id < b.id end
        if a.target ~= b.target then return a.target < b.target end
        return a.n < b.n
    end)
    return list
end

-- the AI block's strategies replaced: the ported types from `fresh`, the others kept
local function write(ai, fresh, rebuilt)
    local kept, pos, out = {}, nil, {}
    for i, e in ipairs(ai) do
        if e.op and e.key and e.key.text == "strategy" and e.value.text == nil then
            pos = pos or #out + 1
            local s = entry_of(e)
            if not rebuilt[s.type] then
                kept[#kept + 1] = s
            end
        else
            out[#out + 1] = e
            if pos == nil and e.op and e.key and e.key.text == "prepare_war_date_start" then
                pos = #out
            end
        end
    end
    pos = pos or #out + 1
    local all = {}
    for _, s in ipairs(kept) do all[#all + 1] = s end
    for _, s in ipairs(fresh) do all[#all + 1] = s end
    sorted(all)
    local entries = {}
    for i, s in ipairs(all) do
        entries[i] = { key = { text = "strategy" }, op = "=", value = block_of(s) }
    end
    -- the block rewritten in place: out[1..pos-1], the strategies, out[pos..]
    local n = 0
    local new = {}
    for i = 1, pos - 1 do new[#new + 1] = out[i] end
    for _, e in ipairs(entries) do new[#new + 1] = e end
    for i = pos, #out do new[#new + 1] = out[i] end
    for i = 1, math.max(#ai, #new) do ai[i] = new[i] end
    strategy.stats.kept = strategy.stats.kept + #kept
    return #all
end

local function remove_key(ai, key)
    for i = #ai, 1, -1 do
        local e = ai[i]
        if e.op and e.key and e.key.text == key then
            world.remove_entry(ai, e)
        end
    end
end

-- whether CreateStrategicData runs CreateColonizeData this month (0xb6e188): a crisis progression,
-- the country's month (id % 12 = CGameState +0x128, the month index [I]), the first
-- AI_BUDGETING_START_YEARS years, no colonize data yet, or DirtyExpandStrategy
local function colonize_due(id, c, ai, date)
    local d = defines()
    if world.field(c, "crisis_progression") ~= nil then
        return true
    end
    if date and (id % 12) == ((date.month or 1) - 1) then
        return true
    end
    if date and date.year and date.year - d.START_YEAR < d.AI_BUDGETING_START_YEARS then
        return true
    end
    if world.field(ai, "colonize") ~= "yes" then
        return true
    end
    return world.field(ai, "dirty_expand_strategy") == "yes"
end

-- strategy.entries(country, type) -> { { id, target, value } } in the order the AI walks them: the
-- order CreateColonizeData made them in since the last rebuild here, else (after a load) the
-- save's, which is the order CCountryAI::ReadMember added them
strategy.made = {}
function strategy.entries(id, t)
    local made = strategy.made[id]
    if made then
        return made[t] or {}
    end
    local out = {}
    local c = country(id)
    local ai = c and world.field(c, "ai")
    for _, e in ipairs(type(ai) == "table" and ai or {}) do
        if e.op and e.key and e.key.text == "strategy" and e.value.text == nil then
            local s = entry_of(e)
            if s.type == t then
                out[#out + 1] = { id = s.id, target = s.target, value = s.value }
            end
        end
    end
    return out
end

-- CCountry::MonthlyUpdateStrategy -> CCountryAI::CreateStrategicData, for every country with an AI
function strategy.monthly(host, date)
    -- STELLAR_AI_STRATEGY=off: the lists kept as loaded (an A/B switch for the checks)
    if os.getenv("STELLAR_AI_STRATEGY") == "off" then
        return
    end
    local t0 = os.clock()
    strategy.stats.months = strategy.stats.months + 1
    for _, id in ipairs(world.all("country")) do
        local c = country(id)
        local ai = c and world.field(c, "ai")
        if type(ai) == "table" then
            strategy.stats.countries = strategy.stats.countries + 1
            -- a `relations = yes` type: the colonize data (the InWar flag it also sets from the
            -- country's wars is not written: the wars are not modelled); the conquer data (claims,
            -- list 0), the navy and army build data (9, 10) and the modules' lists are kept
            if type_flag(c, "relations") and colonize_due(id, c, ai, date) then
                strategy.stats.colonize = strategy.stats.colonize + 1
                local fresh = strategy.compute(id)
                -- the lists in memory keep the order they were made in (AddStrategy appends);
                -- the save writes them sorted (strategy.entries)
                local made = {}
                for _, s in ipairs(fresh) do
                    local l = made[s.type]
                    if not l then
                        l = {}
                        made[s.type] = l
                    end
                    l[#l + 1] = { id = s.id, target = s.target, value = s.value }
                end
                strategy.made[id] = made
                strategy.stats.entries = strategy.stats.entries + write(ai, fresh, PORTED)
                -- HasCreatedColonizeData set, DirtyExpandStrategy cleared
                world.set(ai, "colonize", "yes")
                remove_key(ai, "dirty_expand_strategy")
            end
            -- every country: NeedStrategicWarData cleared; _bInitializedStrategy set,
            -- _bRecalculateStrategy cleared
            remove_key(ai, "need_strategic_war_data")
            remove_key(ai, "recalculate")
            world.set(ai, "initialized", "yes")
        end
    end
    strategy.stats.seconds = strategy.stats.seconds + (os.clock() - t0)
end

-- ---------------------------------------------------------------------------------------------
-- checks

-- strategy.compare() -> text: per ported type, the entries computed, the world's, and how many are
-- equal (the same id, target and value, per country)
function strategy.compare(only)
    local by = {}
    local function slot(t)
        by[t] = by[t] or { computed = 0, saved = 0, equal = 0, countries = {} }
        return by[t]
    end
    for _, id in ipairs(world.all("country")) do
        local c = country(id)
        local ai = c and world.field(c, "ai")
        if type(ai) == "table" and type_flag(c, "relations") and (only == nil or only == id) then
            local saved = {}
            for _, e in ipairs(ai) do
                if e.op and e.key and e.key.text == "strategy" and e.value.text == nil then
                    local s = entry_of(e)
                    if PORTED[s.type] then
                        local k = s.type .. ":" .. s.id .. ":" .. s.target .. ":" .. s.value
                        saved[k] = (saved[k] or 0) + 1
                        slot(s.type).saved = slot(s.type).saved + 1
                    end
                end
            end
            local miss = {}
            for _, s in ipairs(strategy.compute(id)) do
                local b = slot(s.type)
                b.computed = b.computed + 1
                local k = s.type .. ":" .. s.id .. ":" .. s.target .. ":" .. s.value
                if (saved[k] or 0) > 0 then
                    saved[k] = saved[k] - 1
                    b.equal = b.equal + 1
                else
                    miss[#miss + 1] = "+" .. k
                end
            end
            for k, n in pairs(saved) do
                for _ = 1, n do miss[#miss + 1] = "-" .. k end
            end
            if #miss > 0 then
                table.sort(miss)
                local t = {}
                for i = 1, math.min(#miss, 12) do t[i] = miss[i] end
                slot(-1).countries[#slot(-1).countries + 1] = string.format("  %d: %d differ: %s", id, #miss, table.concat(t, " "))
            end
        end
    end
    local lines = {}
    for t, b in pairs(by) do
        if t >= 0 then
            lines[#lines + 1] = string.format("type %d: computed %d, saved %d, equal %d", t, b.computed, b.saved, b.equal)
        end
    end
    table.sort(lines)
    for _, l in ipairs(by[-1] and by[-1].countries or {}) do lines[#lines + 1] = l end
    return table.concat(lines, "\n")
end

function strategy.report()
    local s = strategy.stats
    return string.format("ai strategy: %d months, %d country-months, %d colonize data built, %d entries written (%d kept), %.2f s",
        s.months, s.countries, s.colonize, s.entries, s.kept, s.seconds)
end

return strategy
