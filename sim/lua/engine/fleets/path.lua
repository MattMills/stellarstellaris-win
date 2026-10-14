-- engine/fleets/path.lua : the game's fleet pathfinder and the fixed-point geometry movement uses
-- (GOG 4.5.2; the Linux build's symbols for the inlined parts; docs/fleet_movement.md).
--
--   local path = require("engine.fleets.path")
--   path.create(from, to, data)   -> nodes | nil     CFleetPath::Create (GOG 0xe21390); data =
--                                    path.fleet_data(fleet_id) (SFleetPathfindData)
--   path.find(data, a, b)         -> { {system, method} } | nil, cost
--                                    FindPath (GOG 0xaff330) -> CAStarAlgorithm<..>::Find
--   path.leave_point(from, to_system), path.enter_point(from, to_system, fleet)
--                                    CFTLJump::CalcFTLLeaveSystemPoint / CalcFTLEnterSystemPoint
--   path.towards(from, to, step, no_clamp, relative)   CCelestialCoordinate::CalcTowards
--   path.near(a, b, d), path.distance(a, b)             CCelestialCoordinate::IsNear, CalcDistance
--
-- Coordinates are tables { x, y, z, origin } of raw CFixedPoint integers (int64 in the game, 1.0 =
-- 100000; held in Lua numbers, products and quotients done in int64): x, y the position (in a
-- system: relative to its star; in the galaxy: the galactic position), z the display height (the
-- save's visual_height), origin the system's id or 4294967295 (interstellar). A path node adds
-- `method` (EPathJumpMethod: 0 jump_hyperlane, 1 jump_bypass) and `bypass` (a TPdxRef<CBypass>).
--
-- Pathfinding [V] (FindPath 0x1e1d910 -> FindPathHyperlane -> FindPathInternal 0x1e1d3d0 -> the
-- access variant, since the movement's settings always have CheckAccess): Dijkstra over the
-- systems (SNoHeuristics), the game's binary heap and its tie rule; a hyperlane costs
-- HYPERLANE_WINDUP + 1 + length / HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED (151 + the saved integer
-- length), twice that into a system the country knows hostiles in (not at war), plus
-- FLEET_PATHFINDING_COSMIC_STORM_WEIGHT into a storm. Not ported: bypasses (gateways, wormholes,
-- L-gates: the adjacencies after the hyperlanes), hostiles and storms (no data: their terms are 0),
-- closed borders (CCountry::HasAccessLevelCached / IsSystemRestrictedCached: every system open),
-- FTL inhibitors and magnets.

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local defs = require("engine.defs")
local ffi = require("ffi")

local I64 = ffi.typeof("int64_t")
local FP = 100000
local NO_ID = 4294967295

local path = { FP = FP, NO_ID = NO_ID, stats = { finds = 0, found = 0, failed = 0, creates = 0 } }

-- ---------------------------------------------------------------------------------------------
-- CFixedPoint on raw integers

-- the save's text of a CFixedPoint ("115.35842", "-0.5", "33") -> its raw integer, exactly
local function raw(v)
    if v == nil then
        return nil
    end
    if type(v) == "number" then
        local r = v * FP
        return r >= 0 and math.floor(r + 0.5) or -math.floor(-r + 0.5)
    end
    local s = tostring(v)
    local neg, int, frac = s:match("^(%-?)(%d*)%.?(%d*)$")
    if not int then
        return raw(tonumber(s) or 0)
    end
    frac = (frac .. "00000"):sub(1, 5)
    local r = (tonumber(int) or 0) * FP + tonumber(frac)
    return neg == "-" and -r or r
end
path.raw = raw

-- a raw integer as the save writes it: five decimals, trailing zeros dropped
local function text(r)
    r = math.floor(r)
    local neg = r < 0
    if neg then
        r = -r
    end
    local int, frac = math.floor(r / FP), r % FP
    local s = tostring(int)
    if frac ~= 0 then
        s = s .. "." .. (string.format("%05d", frac):gsub("0+$", ""))
    end
    if neg and (int ~= 0 or frac ~= 0) then
        s = "-" .. s
    end
    return s
end
path.text = text

-- a * b / 100000 and a * 100000 / b, truncated toward zero (the game's operator* and operator/
-- on values inside its fast range, which every coordinate and speed here is)
local function fmul(a, b)
    return tonumber(I64(a) * I64(b) / FP)
end
local function fdiv(a, b)
    if b == 0 then
        return 4294967295 -- the game's x / 0 (0xffffffff)
    end
    return tonumber(I64(a) * FP / I64(b))
end
-- the integer division the game writes as x / n (toward zero)
local function idiv(a, n)
    return tonumber(I64(a) / I64(n))
end
path.fmul, path.fdiv, path.idiv = fmul, fdiv, idiv

-- the integer square root of an int64 (Newton from n / 2, as CalcTowards inlines it)
local function isqrt(n)
    if n < 2 then
        return n
    end
    local x = n / 2
    while true do
        local y = (n / x + x) / 2
        if y >= x then
            return x
        end
        x = y
    end
end

-- ---------------------------------------------------------------------------------------------
-- coordinates

function path.coord(x, y, origin, z)
    return { x = x or 0, y = y or 0, z = z or 0, origin = origin or NO_ID }
end
local function copy(c)
    return { x = c.x, y = c.y, z = c.z or 0, origin = c.origin, randomized = c.randomized }
end
path.copy = copy

function path.same(a, b)
    return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.origin == b.origin
end

-- CCelestialCoordinate::CalcTowards (0x2286740 Linux): from towards to by step. A step past the
-- target gives the target (its origin too) unless no_clamp; relative gives the step itself.
function path.towards(from, to, step, no_clamp, relative)
    local dx, dy = to.x - from.x, to.y - from.y
    if dx == 0 and dy == 0 then
        return copy(to)
    end
    local dist = tonumber(isqrt(I64(dx) * dx + I64(dy) * dy))
    if dist <= step and not no_clamp then
        if not relative then
            return copy(to)
        end
        return { x = dx, y = dy, z = (to.z or 0) - (from.z or 0), origin = from.origin }
    end
    local x0, y0, z0 = from.x, from.y, from.z or 0
    if relative then
        x0, y0, z0 = 0, 0, 0
    end
    local function part(d)
        return dist == 0 and 4294967295 or fdiv(fmul(d, step), dist)
    end
    return { x = x0 + part(dx), y = y0 + part(dy), z = z0 + part((to.z or 0) - (from.z or 0)), origin = from.origin }
end

-- CCelestialDistance (CCelestialCoordinate::CalcDistance 0x2284b60): the squared distance, with
-- 100 times the precision when both offsets are under 0.1
local function sqdist(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local small = math.abs(dx) < 10000 and math.abs(dy) < 10000
    if small then
        dx, dy = dx * 100, dy * 100
    end
    return (I64(dx) * dx) / FP + (I64(dy) * dy) / FP, small
end
-- CCelestialDistance::IsLessThan(CFixedPoint) (0x2286f50)
local function dist_less(a, b, d)
    local sq, small = sqdist(a, b)
    if small then
        if d > 999999 then
            return true
        end
        d = d * 100
    end
    return sq < (I64(d) * d) / FP
end
path.dist_less = dist_less

-- CCelestialCoordinate::IsNear(c, d) (0x2285090): in the same system and closer than d
function path.near(a, b, d)
    return a.origin == b.origin and dist_less(a, b, d)
end

-- the distance (CCelestialDistance::CalcDistance: the root of the squared distance)
function path.distance(a, b)
    local sq, small = sqdist(a, b)
    local r = tonumber(isqrt(sq * FP))
    return small and math.floor(r / 100) or r
end

-- ---------------------------------------------------------------------------------------------
-- the galaxy: systems, hyperlanes, radii (static after the load)

local galaxy
function path.galaxy()
    if galaxy then
        return galaxy
    end
    galaxy = {}
    for _, id in ipairs(world.all("system")) do
        slice.tick("fleets/path.lua:197")
        local g = world.object("system", id)
        local c = world.field(g, "coordinate")
        local lanes = {}
        for _, h in ipairs(world.blocks(world.field(g, "hyperlane"))) do
            local to = tonumber(world.field(h, "to"))
            if to then
                -- CHyperlane::ReadMember (0x1c7dd50 Linux): `length` read as a CFixedPoint
                lanes[#lanes + 1] = { to = to, len = raw(world.field(h, "length")) or 0 }
            end
        end
        galaxy[id] = {
            id = id,
            x = raw(world.field(c, "x")) or 0, y = raw(world.field(c, "y")) or 0,
            z = raw(world.field(c, "visual_height")) or 0,
            inner = raw(world.field(g, "inner_radius")) or 150 * FP,
            lanes = lanes,
            storm = tonumber(world.field(g, "storm")),
        }
    end
    return galaxy
end
function path.reset()
    galaxy = nil
end

-- a system's galactic coordinate (CGalacticObject::_Coordinate)
local function system_coord(s)
    return { x = s.x, y = s.y, z = s.z, origin = NO_ID }
end

-- CCelestialCoordinate::GetGalacticCoordinate (0x2286660): itself in the galaxy, its system's
-- coordinate in a system
function path.galactic(c)
    if c.origin == NO_ID then
        return c
    end
    local s = path.galaxy()[c.origin]
    return s and system_coord(s) or c
end

local DEF
local function define(group, key, default)
    local g = defs.get("common/defines", group)
    local v = g and defs.field(g.block, key)
    return v ~= nil and v or default
end
function path.defines()
    if not DEF then
        DEF = {
            HYPERLANE_WINDUP = raw(define("NShip", "HYPERLANE_WINDUP", "150")),
            HYPERLANE_WINDDOWN = raw(define("NShip", "HYPERLANE_WINDDOWN", "0")),
            HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED = raw(define("NShip", "HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED", "1")),
            SHIP_SPEED_SCALE = raw(define("NShip", "SHIP_SPEED_SCALE", "0.045")),
            FLEET_BASE_FORMATION_SCALE = raw(define("NShip", "FLEET_BASE_FORMATION_SCALE", "3")),
            LIMITED_EXPLORATION = tonumber(define("NGameplay", "LIMITED_EXPLORATION", "1")) == 1,
            CAN_TRAVEL_BETWEEN_UNEXPLORED_SYSTEMS = define("NShip", "CAN_TRAVEL_BETWEEN_UNEXPLORED_SYSTEMS", "no") == "yes",
            FLEET_PATHFINDING_COSMIC_STORM_WEIGHT = raw(define("NGameplay", "FLEET_PATHFINDING_COSMIC_STORM_WEIGHT", "10")),
        }
    end
    return DEF
end

-- CGalacticObject::CalcFTLPointWith (0x260d110 / 0x260d010 Linux): the point of a system at 1.05
-- times its inner radius toward another system's galactic coordinate, in the system
local function ftl_point(s, other_galactic)
    local p = path.towards(system_coord(s), other_galactic, fmul(s.inner, 105000), true, true)
    p.origin = s.id
    return p
end
path.ftl_point = ftl_point

-- CalcClosestPointOutsideOfGravityWell (0x2987310 Linux): a point inside the inner radius pushed
-- out to 1.05 times it, on its own bearing
local function outside_gravity_well(c)
    local s = path.galaxy()[c.origin]
    if not s then
        return copy(c)
    end
    local sq = (I64(c.x) * c.x) / FP + (I64(c.y) * c.y) / FP
    if (I64(s.inner) * s.inner) / FP <= sq then
        return copy(c)
    end
    local d = tonumber(isqrt(I64(c.x) * c.x + I64(c.y) * c.y))
    if d == 0 then
        return copy(c)
    end
    return { x = fdiv(fmul(fmul(s.inner, c.x), 105000), d), y = fdiv(fmul(fmul(s.inner, c.y), 105000), d), z = 0, origin = c.origin }
end

-- CFTLJump::CalcFTLLeaveSystemPoint (0x2986de0 Linux), a hyperlane jump: the from system's FTL
-- point toward the destination
function path.leave_point(from, to_system)
    local g = path.galaxy()
    local src, dst = g[from.origin], g[to_system]
    if not src or not dst or from.origin == to_system then
        return outside_gravity_well(from)
    end
    return ftl_point(src, system_coord(dst))
end

-- CFTLJump::CalcFTLEnterSystemPoint (0x2987a90 Linux), a hyperlane jump: the destination's FTL
-- point toward where the jump starts (its system). A hostile FTL magnet in the destination
-- (_PrecalcFTLMagnetPresence: FTL_MAGNET_DISTANCE from it toward the star) is not ported.
function path.enter_point(from, to_system)
    local dst = path.galaxy()[to_system]
    if not dst then
        return nil
    end
    return ftl_point(dst, path.galactic(from))
end

-- ---------------------------------------------------------------------------------------------
-- the fleet's pathfinding data (SFleetPathfindData::SFleetPathfindData 0x29ef3d0 Linux)

local function country_of_fleet(fid)
    return world.fleet_owner and world.fleet_owner[fid]
end

local function list_set(block)
    if type(block) ~= "table" then
        return nil
    end
    local s, any = {}, false
    for _, v in ipairs(world.list(block)) do
        slice.tick("path lists")
        s[tonumber(v)] = true
        any = true
    end
    return any and s or nil
end
local function list_array(block)
    if type(block) ~= "table" then
        return nil
    end
    local a = {}
    for _, v in ipairs(world.list(block)) do
        slice.tick("path lists")
        a[#a + 1] = tonumber(v)
    end
    return #a > 0 and a or nil
end

-- the ship class of a fleet (CFleet::GetShipClass, the save's ship_class), as EShipClass
local SHIP_CLASS = {
    shipclass_military = 0, shipclass_constructor = 1, shipclass_colonizer = 2, shipclass_science_ship = 3,
    shipclass_transport = 4, shipclass_mining_station = 5, shipclass_research_station = 6,
    shipclass_military_station = 7, shipclass_habitat_station = 8, shipclass_observation_station = 9,
    shipclass_starbase = 10, shipclass_military_special = 11,
}
path.SHIP_CLASS = SHIP_CLASS

-- SFleetPathfindData: the flags (bit 0 may enter unexplored systems, 1 evasive, 2 at war, 3 has an
-- FTL drive, 4 CAN_TRAVEL_BETWEEN_UNEXPLORED_SYSTEMS), the controller's knowledge, the system
-- the last jump left from (a fleet may always go back the lane it came)
function path.fleet_data(fid)
    local f = world.object("fleet", fid)
    local D = path.defines()
    local cid = country_of_fleet(fid)
    local c = cid and world.object("country", cid)
    local class = SHIP_CLASS[tostring(world.field(f, "ship_class"))] or 0
    -- CFleet::CanExplore (0x294e330 Linux): a military or science fleet led by a commander or a
    -- scientist [I: the leader's class flags as "has a leader"]
    -- CFleet::GetLeader: the leader of a ship of the fleet (the save keeps it on the ship)
    local leader = tonumber(world.field(f, "leader"))
    if not leader or leader == NO_ID then
        for _, s in ipairs(world.list(world.field(f, "ships"))) do
            local l = tonumber(world.field(world.object("ship", tonumber(s)), "leader"))
            if l and l ~= NO_ID then
                leader = l
                break
            end
        end
    end
    local can_explore = (class == 0 or class == 3) and leader ~= nil and leader ~= NO_ID
    local lj = world.path(f, "movement_manager", "last_ftl_jump", "from", "origin")
    return {
        fleet = fid, country = cid, class = class,
        explore = can_explore,
        ftl = true, -- CFleet::HasFTL: the first ship's hyperdrive [I: every mobile fleet has one]
        travel_unexplored = D.CAN_TRAVEL_BETWEEN_UNEXPLORED_SYSTEMS,
        last_from = tonumber(lj),
        -- the country's caches the pathfinder reads, as the save keeps them (engine.exploration
        -- writes them): the systems in hyperlane range, the intel level per system index
        range = c and list_set(world.field(c, "hyperlane_systems")) or nil,
        intel = c and list_array(world.field(c, "intel_level")) or nil,
    }
end

-- CCountry::DoesSystemRequireExplorationCached (0x23b1420 Linux): LIMITED_EXPLORATION and no
-- intel on the system
local function requires_exploration(data, sys)
    if not path.defines().LIMITED_EXPLORATION or not data.intel then
        return false
    end
    local level = data.intel[(sys % 16777216) + 1]
    return level ~= nil and level == 0
end
local function in_range(data, sys)
    return data.range == nil or data.range[sys] == true
end

-- (anonymous)::CanUseHyperlanesFromSystem (0x29f2010 Linux)
local function can_use_hyperlanes(data, from, to)
    if data.last_from == to then
        return true
    end
    if not in_range(data, from) then
        return false
    end
    if not data.explore and not in_range(data, to) then
        return false
    end
    if not data.travel_unexplored and requires_exploration(data, from) and requires_exploration(data, to)
        and not data.explore then
        return false
    end
    return true
end

-- the access hooks (closed borders, restricted systems, known hostiles): not ported, every
-- system open; movement.access may replace them
path.hooks = {
    has_access = function(data, sys) return true end,       -- CCountry::HasAccessLevelCached
    restricted = function(data, sys) return false end,      -- CCountry::IsSystemRestrictedCached
    hostiles = function(data, sys) return false end,        -- CCountry::HasSystemHostilesCached
}

-- ValidateAdjacency<SFleetPathfindData, SFleetPathfindAccessData> (0x29fbfe0 Linux), a hyperlane:
-- 1 skip, 2 closed for the search, 0 open
local function validate(data, from, to)
    if from == to then
        return 1
    end
    if not data.ftl then
        return 1
    end
    if not can_use_hyperlanes(data, from, to) then
        return 1
    end
    if not path.hooks.has_access(data, to) then
        return 2
    end
    -- EvalShared: evasive fleets avoid known hostiles (hooks.hostiles), unexplored systems need
    -- an exploring fleet, restricted systems are closed
    if data.evasive and path.hooks.hostiles(data, to) then
        return 2
    end
    if not data.explore and requires_exploration(data, to) then
        return 2
    end
    if path.hooks.restricted(data, to) then
        return 2
    end
    return 0
end

-- SFindFleetPathCostFunc::Eval<SFleetPathfindAccessData> (0x29fc220 Linux) over
-- SAStarHyperlaneWithBypassCostFuncBase::Eval (0x2622660 Linux)
local function cost(data, lane, to)
    local D = path.defines()
    local c = D.HYPERLANE_WINDUP + FP + fdiv(lane.len, D.HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED)
    if not data.at_war and path.hooks.hostiles(data, to) then
        c = fmul(c, 2 * FP)
    end
    local s = path.galaxy()[to]
    if s and s.storm and s.storm ~= NO_ID and path.hooks.storm and path.hooks.storm(s.storm) then
        c = c + D.FLEET_PATHFINDING_COSMIC_STORM_WEIGHT
    end
    return c
end

-- the search: CAStarAlgorithm<CAStarHyperlaneWithBypassConfigPolicy<..>, CFindFleetPathResultPolicy,
-- short>::Find, inlined in FindPath(SFleetPathfindData, SFleetPathfindAccessData, ...) (0x29ef690
-- Linux): a binary heap of (cost, node); popped nodes are closed; a node reached again at the same
-- cost takes the parent with the shorter chain
function path.find(data, from, to)
    path.stats.finds = path.stats.finds + 1
    local g = path.galaxy()
    if not g[from] or not g[to] then
        path.stats.failed = path.stats.failed + 1
        return nil
    end
    if from == to then
        return {}, 0
    end
    local node, state, pos = {}, {}, {}
    local hc, hi, n = {}, {}, 0 -- the heap, 0-based: hc[k] its cost, hi[k] its system
    local function swap(a, b)
        hc[a], hc[b] = hc[b], hc[a]
        hi[a], hi[b] = hi[b], hi[a]
        pos[hi[a]], pos[hi[b]] = a, b
    end
    local function up(k)
        while k > 0 do
            local p = math.floor((k - 1) / 2)
            if hc[p] <= hc[k] then
                break
            end
            swap(p, k)
            k = p
        end
    end
    local function chain(nd)
        local c = 0
        while nd do
            c = c + 1
            nd = nd.parent
        end
        return c
    end
    node[from] = { sys = from, cost = 0 }
    hc[0], hi[0], n, pos[from] = 0, from, 1, 0
    while n > 0 do
        slice.tick("path search")
        -- pop: the last to the root, sifted down over the first n - 1
        swap(0, n - 1)
        local i = 0
        while true do
            local r, l = 2 * i + 2, 2 * i + 1
            local cand
            if r > n - 2 or hc[i] <= hc[r] then
                if l > n - 2 then
                    break
                end
                cand = hc[i] <= hc[l] and i or l
            else
                cand = hc[r] <= hc[l] and r or l
            end
            if cand == i then
                break
            end
            swap(i, cand)
            i = cand
        end
        n = n - 1
        local cur = hi[n]
        state[cur] = 2
        local nd = node[cur]
        if cur == to then
            local out = {}
            while nd.parent do
                table.insert(out, 1, { system = nd.sys, method = nd.bypass and 1 or 0 })
                nd = nd.parent
            end
            path.stats.found = path.stats.found + 1
            return out, node[to].cost
        end
        for _, lane in ipairs(g[cur].lanes) do
            local nb = lane.to
            if g[nb] and state[nb] ~= 2 then
                local v = validate(data, cur, nb)
                if v == 2 then
                    state[nb] = 2
                elseif v == 0 then
                    local c = cost(data, lane, nb) + nd.cost
                    if state[nb] == 1 then
                        local o = node[nb]
                        if c < o.cost or (c == o.cost and chain(nd) < chain(o.parent)) then
                            o.parent, o.cost, o.bypass = nd, c, false
                            hc[pos[nb]] = c
                            up(pos[nb])
                        end
                    else
                        node[nb] = { sys = nb, parent = nd, cost = c, bypass = false }
                        state[nb] = 1
                        hc[n], hi[n], pos[nb] = c, nb, n
                        n = n + 1
                        up(n - 1)
                    end
                end
            end
        end
    end
    path.stats.failed = path.stats.failed + 1
    return nil
end

-- CFleetPath::Create(from, to, null, fleet, settings) (0x29880d0 Linux): in another system the
-- route's systems, for each jump its leave point (in a system) and enter point; then the target
-- itself (jump_hyperlane). nil when no route.
function path.create(from, to, data)
    path.stats.creates = path.stats.creates + 1
    local nodes = {}
    if from.origin ~= to.origin then
        local route = path.find(data, from.origin, to.origin)
        if not route then
            return nil
        end
        local cur = from
        for _, step in ipairs(route) do
            if step.method == 1 then
                return nil -- bypass jumps: not ported
            end
            if cur.origin ~= NO_ID then
                local lp = path.leave_point(cur, step.system)
                lp.method = step.method
                nodes[#nodes + 1] = lp
            end
            local ep = path.enter_point(cur, step.system)
            ep.method = step.method
            nodes[#nodes + 1] = ep
            cur = ep
        end
    end
    if to.origin ~= NO_ID then
        local t = copy(to)
        t.method = 0
        nodes[#nodes + 1] = t
    end
    return nodes
end

return path
