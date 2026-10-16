-- engine/newgame/galaxy.lua : the galaxy's map: the parameters and the stars, the nebulas, the
-- systems' neighbours, the start clusters, the empires' home systems and the resource clusters:
-- what CGalaxyGenerator::GenerateFromRandomScenario (GOG 0x98bfe0) does before the hyperlanes
-- (engine/newgame/lanes.lua) and the systems (engine/newgame/systems.lua): GenerateStars
-- (0x974860), GenerateNebula (0x9762f0), CGameState::GenerateGalacticMap (0x26d5d0),
-- CreateEmpireStartClusters (0x97f2c0), PlaceEmpires (0x9805e0), CreateResouceClusters (0x97fdd0).
-- docs/newgame.md, section 5.
--
--   local galaxy = require("engine.newgame.galaxy")
--   game.params = galaxy.parameters(inputs, r)
--   galaxy.stars(inputs, r, game)          -- game.systems[i] = { id, x, y, rx, ry, ... }
--   galaxy.nebulas(inputs, r, game, take_name)
--   galaxy.galactic_map(game)              -- system.neighbors, game.galaxy_radius
--   galaxy.clusters(inputs, r, game)       -- game.clusters (start clusters)
--   galaxy.place_empires(inputs, r, game)  -- game.home_systems
--   galaxy.resource_clusters(inputs, r, game)

local fixed = require("engine.newgame.fixed")
local delaunay = require("engine.newgame.delaunay")
local triangle = require("engine.newgame.triangle")

local galaxy = {}

local pi = math.pi

local function dist2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end
galaxy.dist2 = dist2

-- a grid of cells for neighbour queries
local function grid(cell)
    local g = { cell = cell, cells = {} }
    function g.key(x, y)
        return math.floor(x / cell) * 100003 + math.floor(y / cell)
    end
    function g.add(p)
        local k = g.key(p.x, p.y)
        local c = g.cells[k]
        if not c then
            c = {}
            g.cells[k] = c
        end
        c[#c + 1] = p
    end
    -- calls f(p) for every point within r of (x, y) (r <= a few cells)
    function g.near(x, y, r, f)
        local n = math.ceil(r / cell)
        local cx, cy = math.floor(x / cell), math.floor(y / cell)
        local r2 = r * r
        for i = cx - n, cx + n do
            for j = cy - n, cy + n do
                local c = g.cells[i * 100003 + j]
                if c then
                    for _, p in ipairs(c) do
                        local dx, dy = p.x - x, p.y - y
                        if dx * dx + dy * dy <= r2 then
                            if f(p) == false then
                                return false
                            end
                        end
                    end
                end
            end
        end
        return true
    end
    return g
end
galaxy.grid = grid

-- ---------------------------------------------------------------------------------------------
-- stars

-- the parameters GenerateFromRandomScenario (0x98c0d8-0x98c7ff) gives GenerateStars and
-- GenerateNebula (SGalaxyGenerationParameters), in raw fixed point, with the draws it makes before
-- the stars: the random empire counts (only with the random settings, not drawn here: the counts
-- are the settings') and, for shapes with arms, the arms' rotation (2 * trunc(u * 314200 / 1e5))
function galaxy.parameters(inputs, r)
    local sc, shape, cfg = inputs.scenario, inputs.shape, inputs.config
    local F = fixed.from
    local P = {}
    P.num_stars = sc.num_stars
    P.num_core = fixed.idiv(sc.num_stars * F(shape.num_stars_core_perc), fixed.ONE)
    P.num_disk = sc.num_stars - P.num_core
    P.total_rad = F(sc.radius)
    P.core_rad = fixed.mul(P.total_rad, F(shape.core_radius_perc))
    P.disk_rad = P.total_rad - P.core_rad
    P.min_dist = F(shape.stars_min_dist)
    P.nebulas = sc.num_nebulas
    P.nebula_radius = fixed.idiv(F(sc.nebula_size), 2)
    P.nebula_min_dist = F(sc.nebula_min_dist)
    P.num_arms = shape.num_arms
    if shape.num_arms > 0 and shape.arms then
        P.arm_rots = F(shape.arms.tightness_winding)
        P.arm_width = F(shape.arms.width)
        P.fuzz = F(shape.arms.fuzz)
        P.omega = F(shape.arms.seperation)
        P.arm_rot_offset = 2 * fixed.idiv(fixed.u(r) * 314200, fixed.ONE)
    end
    if shape.ring then
        P.has_ring = true
        P.ring_width = fixed.mul(P.total_rad, F(shape.ring.width))
        P.ring_offset = fixed.mul(P.total_rad, F(shape.ring.offset))
    end
    -- the empires the galaxy is made for: the AI empires and the humans (one)
    P.humans = 1
    P.countries = (cfg.empires or 0) + P.humans
    return P
end

-- GenerateStars (0x974860): num_stars minus the empires' count of stars, each a radius (linear in
-- a draw, between the core and the radius) and an angle (uniform; for arms, wound with the radius
-- and spread by the arm's width and fuzz), at least stars_min_dist from every star before it (10000
-- tries per star); then one Lloyd relaxation over the Delaunay triangulation of the stars and 256
-- points on a circle at 0.9 x the core radius. Coordinates on a 0.01 grid. docs/newgame.md, 5.1.
function galaxy.stars(inputs, r, game)
    local P = game.params
    local target = P.num_stars - math.max(P.countries, P.humans)
    local ONE = fixed.ONE
    local mul, div, u = fixed.mul, fixed.div, fixed.u
    local stars = {}
    local g = grid(P.min_dist / ONE + 1)
    local tries = 10000
    game.star_attempts = 0
    while #stars < target do
        game.star_attempts = game.star_attempts + 1
        local R
        if P.has_ring then
            R = mul(u(r), P.ring_width) + P.ring_offset + P.core_rad
        elseif #stars < P.num_disk then
            R = P.core_rad + mul(u(r), P.disk_rad)
        else
            R = mul(u(r), P.core_rad)
        end
        local rad, arm = nil, -1
        if (P.num_arms or 0) <= 0 then
            local deg = mul(u(r), 360 * ONE)
            rad = div(mul(deg, 314159), 18000000)
        else
            local wind = P.disk_rad == 0 and 0 or mul(mul(div(R, P.disk_rad), P.arm_rots), P.disk_rad)
            local w = mul(u(r), P.arm_width)
            arm = r:below(P.num_arms)
            local f = 2 * mul(u(r), P.fuzz) - P.fuzz
            rad = div(mul(w + wind + arm * P.omega + f, 314159), 18000000) + P.arm_rot_offset
        end
        local x, y = mul(fixed.cos(rad), R), mul(fixed.sin(rad), R)
        -- the distance test, against every star so far (by the grid: the same answer)
        local close = not g.near(x / ONE, y / ONE, P.min_dist / ONE + 1, function(s)
            if fixed.closer(x - s.rx, y - s.ry, P.min_dist) then
                return false
            end
        end)
        if close then
            if tries < 1 then
                game.star_failure = string.format("stars_min_dist: %d of %d stars", #stars, target)
                break
            end
            tries = tries - 1
        else
            local s = { rx = fixed.clamp500(x), ry = fixed.clamp500(y), x = x / ONE, y = y / ONE, arm = arm }
            s.x, s.y = s.rx / ONE, s.ry / ONE
            stars[#stars + 1] = s
            g.add(s)
            tries = 10000
        end
    end
    -- the relaxation: points in 0.01 units (float), the dummies on a circle at 0.9 core radius
    local xs, ys = {}, {}
    for i, s in ipairs(stars) do
        xs[i] = fixed.trunc(s.rx / 1000)
        ys[i] = fixed.trunc(s.ry / 1000)
    end
    local dummies = tonumber(game.defines.GALAXY_GENERATION_CENTER_DUMMY_POINTS) or 256
    if dummies > 0 then
        local step = fixed.idiv(62831800000, dummies * ONE)
        for k = 0, dummies - 1 do
            local a = k * step
            local vx = mul(mul(mul(fixed.cos(a), P.core_rad), 90000), 100 * ONE)
            local vy = mul(mul(mul(fixed.sin(a), P.core_rad), 90000), 100 * ONE)
            xs[#xs + 1] = fixed.trunc(vx / ONE)
            ys[#ys + 1] = fixed.trunc(vy / ONE)
        end
    end
    local iterations = tonumber(game.defines.GALAXY_GENERATION_RELAX_ITERATIONS) or 1
    for _ = 1, iterations do
        local t = delaunay.triangulate(xs, ys)
        xs, ys = delaunay.relax(xs, ys, t, -50000, 50000)
    end
    for i, s in ipairs(stars) do
        local sys = galaxy.new_system(game, fixed.trunc(xs[i]) / 100, fixed.trunc(ys[i]) / 100)
        sys.arm = s.arm >= 0 and s.arm or nil
    end
    game.core_radius = P.core_rad / ONE
    galaxy.radius(game)
end

-- CGameState::GenerateGalacticMap (0x26d5d0): the systems' neighbours, the Delaunay edges between
-- systems (at whole units, with 64 points on a circle at 1.414 x the farthest system and, with a
-- core, 64 at 0.5 x the nearest) whose midpoint lies between the nearest and the farthest
-- system's distance; and galaxy_radius. No draws.
function galaxy.galactic_map(game)
    local xs, ys = {}, {}
    local minr2, maxr2 = math.huge, 0
    for i, s in ipairs(game.systems) do
        xs[i], ys[i] = fixed.trunc(s.x), fixed.trunc(s.y)
        local r2 = s.x * s.x + s.y * s.y
        minr2, maxr2 = math.min(minr2, r2), math.max(maxr2, r2)
    end
    local n = #xs
    local rings = { math.sqrt(maxr2) * 1.414 }
    if (game.core_radius or 0) > 0 then
        rings[2] = math.sqrt(minr2) * 0.5
    end
    for _, R in ipairs(rings) do
        for k = 0, 63 do
            local a = fixed.idiv(k * 628400, 64)
            xs[#xs + 1] = fixed.trunc(R * fixed.cos(a) / fixed.ONE)
            ys[#ys + 1] = fixed.trunc(-R * fixed.sin(a) / fixed.ONE)
        end
    end
    for _, s in ipairs(game.systems) do
        s.neighbors = {}
    end
    -- the edges in Triangle's order (triangle.lua): each system's neighbours in that order
    for _, e in ipairs(triangle.edges(xs, ys)) do
        local a, b = e[1], e[2]
        if a <= n and b <= n then
            local sa, sb = game.systems[a], game.systems[b]
            local mx, my = (sa.x + sb.x) / 2, (sa.y + sb.y) / 2
            local m2 = mx * mx + my * my
            if (game.core_radius or 0) <= 0 or (m2 > minr2 and m2 < maxr2) then
                sa.neighbors[#sa.neighbors + 1] = sb.id
                sb.neighbors[#sb.neighbors + 1] = sa.id
            end
        end
    end
    galaxy.radius(game)
end

-- the galaxy's radius as the save writes it (galaxy_radius, CGameState::GenerateGalacticMap):
-- the farthest system from the centre
function galaxy.radius(game)
    local far = 0
    for _, s in ipairs(game.systems) do
        far = math.max(far, s.x * s.x + s.y * s.y)
    end
    game.galaxy_radius = math.sqrt(far)
end

-- a new system at (x, y): the next id
function galaxy.new_system(game, x, y)
    local s = {
        id = #game.systems, x = x, y = y, rx = fixed.from(x), ry = fixed.from(y),
        planets = {}, lanes = {}, belts = {}, flags = {}, index = 0,
    }
    game.systems[#game.systems + 1] = s
    return s
end

-- ---------------------------------------------------------------------------------------------
-- nebulas (GenerateNebula): num_nebulas centres at least nebula_min_dist apart; the systems
-- within the radius are the nebula's

-- GenerateNebula (0x9762f0): a nebula is centred on a system drawn at random (draw31 % systems) that
-- is at least nebula_min_dist from the nebulas before it (10000 tries each); its name is taken from
-- the random name database with a draw of the global stream (CRandomNameDatabase::TakeNebulaName
-- 0x907760); its radius is nebula_size / 2; NGalaxyGenerator::AssignGalacticObjectsToNebula
-- (0x977ca0) gives it every system closer than the radius not in a nebula yet.
function galaxy.nebulas(inputs, r, game, take_name)
    local P = game.params
    game.nebulas = {}
    if P.nebulas <= 0 or #game.systems == 0 then
        return
    end
    local tries = 10000
    while #game.nebulas < P.nebulas do
        local s = game.systems[r:below(#game.systems) + 1]
        local ok = true
        for _, n in ipairs(game.nebulas) do
            if fixed.closer(s.rx - n.rx, s.ry - n.ry, P.nebula_min_dist) then
                ok = false
                break
            end
        end
        if tries < 1 then
            return
        end
        if ok then
            local n = { x = s.x, y = s.y, rx = s.rx, ry = s.ry, radius = P.nebula_radius / fixed.ONE, systems = {} }
            n.name = take_name and take_name() or ("Nebula " .. (#game.nebulas + 1))
            for _, t in ipairs(game.systems) do
                if not t.nebula and fixed.closer(n.rx - t.rx, n.ry - t.ry, P.nebula_radius, 10000) then
                    n.systems[#n.systems + 1] = t.id
                    t.nebula = n
                end
            end
            game.nebulas[#game.nebulas + 1] = n
            tries = 10000
        else
            tries = tries - 1
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- start clusters (CreateEmpireStartClusters 0x97f2c0, no draws): with the cluster_count method
-- one_every_x_empire, ceil(countries / value) clusters (constant: value), at most max, at least
-- one; cluster i at cluster_distance_from_core in direction i * 2pi / n (2pi = 6.284), y negated;
-- its systems are those closer than cluster_radius (the save: clusters = { { id =
-- "start_cluster_0" position radius objects } })

function galaxy.clusters(inputs, r, game)
    local sc, P = inputs.scenario, game.params
    game.clusters = {}
    if sc.cluster_radius <= 0 then
        return
    end
    local cc = sc.cluster_count
    local N = P.countries
    local n = 0
    if cc.method == "one_every_x_empire" then
        n = math.floor((N - 1 + cc.value) / math.max(cc.value, 1))
    elseif cc.method == "constant" then
        n = cc.value
    end
    if cc.max and cc.max ~= -1 and cc.max > 0 then
        n = math.min(n, cc.max)
    end
    n = math.max(n, 1)
    local ONE = fixed.ONE
    local step = fixed.div(628400, n * ONE)
    local dist = fixed.from(sc.cluster_distance_from_core)
    local radius = fixed.from(sc.cluster_radius)
    for i = 0, n - 1 do
        local a = i * step
        local cx, cy = fixed.mul(dist, fixed.cos(a)), fixed.mul(dist, -fixed.sin(a))
        local c = { id = "start_cluster_" .. i, rx = cx, ry = cy, x = cx / ONE, y = cy / ONE,
            radius = sc.cluster_radius, objects = {} }
        for _, s in ipairs(game.systems) do
            local dx, dy = s.rx - cx, s.ry - cy
            if fixed.mul(dx, dx) + fixed.mul(dy, dy) < fixed.mul(radius, radius) then
                c.objects[#c.objects + 1] = s.id
                s.clusters = s.clusters or {}
                s.clusters[c.id] = true
            end
        end
        game.clusters[#game.clusters + 1] = c
    end
end

-- ---------------------------------------------------------------------------------------------
-- PlaceEmpires (0x9805e0): the empires' home systems. Clustered starts (the setting `clustered`,
-- player_locations not random): cluster c gets (countries + c) / clusters empires; each goes to the
-- first system of the cluster minimising |ideal - d|, over the systems whose squared distance d to
-- the empires already in the cluster is at least the minimum (or that have none there yet: d =
-- -1, so the first goes to the cluster's first system); then the list is shuffled twice
-- (ShuffleArray 0x98e0e0: forward and backward Fisher-Yates, 2 (n - 1) draws). Random starts: a
-- random system farther than RANDOM_START_DISTANCE (75) from the others, 1000 tries each.

function galaxy.place_empires(inputs, r, game)
    local cfg, shape, P = inputs.config, inputs.shape, game.params
    local N = P.countries
    local homes, taken = {}, {}
    local ideal, minsq = shape.countries_ideal_sq, shape.countries_min_sq
    if cfg.clustered and cfg.player_locations ~= "random" and #game.clusters > 0 then
        local nc = #game.clusters
        for ci, c in ipairs(game.clusters) do
            local k = math.floor((N + ci - 1) / nc)
            local d = {}
            local here = {}
            for _ = 1, k do
                local best, bestv
                for _, sid in ipairs(c.objects) do
                    if not taken[sid] then
                        local dv = d[sid] or -1
                        if dv < 0 or dv >= minsq then
                            local v = math.abs(ideal - dv)
                            if bestv == nil or v < bestv then
                                best, bestv = sid, v
                            end
                        end
                    end
                end
                if best == nil then
                    for _, sid in ipairs(c.objects) do
                        if not taken[sid] then
                            best = sid
                            break
                        end
                    end
                end
                if best then
                    taken[best] = true
                    homes[#homes + 1] = best
                    local b = game.systems[best + 1]
                    for _, sid in ipairs(c.objects) do
                        local dd = dist2(game.systems[sid + 1], b)
                        if d[sid] == nil or d[sid] < 0 or dd < d[sid] then
                            d[sid] = dd
                        end
                    end
                    here[#here + 1] = best
                end
            end
        end
        local n = #homes
        for i = 1, n - 1 do
            local j = i + r:below(n - i + 1)
            homes[i], homes[j] = homes[j], homes[i]
        end
        for i = n, 2, -1 do
            local j = r:below(i) + 1
            homes[i], homes[j] = homes[j], homes[i]
        end
    else
        for _ = 1, N do
            for _ = 1, 1000 do
                local s = game.systems[r:below(#game.systems) + 1]
                local ok = not taken[s.id]
                if ok then
                    for _, h in ipairs(homes) do
                        if math.sqrt(dist2(game.systems[h + 1], s)) <= 75 then
                            ok = false
                            break
                        end
                    end
                end
                if ok then
                    taken[s.id] = true
                    homes[#homes + 1] = s.id
                    break
                end
            end
        end
    end
    game.home_systems = homes
end

-- ---------------------------------------------------------------------------------------------
-- resource clusters (CreateResouceClusters 0x97fdd0): six pie slices around the centre in a
-- shuffled order from a random offset: resource_cluster_<k> (the initializers' is_in_cluster)

function galaxy.resource_clusters(inputs, r, game)
    local order = { 0, 1, 2, 3, 4, 5 }
    for i = 1, 6 do
        local j = i + r:below(6 - i + 1)
        order[i], order[j] = order[j], order[i]
    end
    local off = fixed.mul(628400, fixed.u(r))
    local slice = fixed.idiv(628400, 6)
    for i = 0, 5 do
        local a0 = i * slice + off
        local a1 = (i == 5) and off + 628400 or (i + 1) * slice + off
        local id = "resource_cluster_" .. order[i + 1]
        for _, s in ipairs(game.systems) do
            -- CFixedPoint::Atan2 (not decoded) less 1.571, brought within the slice's turn [I]
            local a = math.floor(math.atan2(s.y, s.x) * fixed.ONE) - 157100
            while a < a0 do
                a = a + 628400
            end
            while a >= a0 + 628400 do
                a = a - 628400
            end
            if a >= a0 and a < a1 then
                s.clusters = s.clusters or {}
                s.clusters[id] = true
            end
        end
    end
end

return galaxy
