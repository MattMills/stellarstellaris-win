-- engine/newgame/lanes.lua : the galaxy's partitions and its hyperlanes.
--
-- - PartitionGalaxyForEmpires (GOG 0x980e90, CGalaxyPartitioner 0xa35270-0xa37190): the systems
--   cut into partitions: one around each empire's home system (home_system_partitions), the rest
--   (open_space_partitions); small partitions merged into a neighbour;
-- - GenerateHyperlanes (0x97a7e0 -> 0x8854a0): the Delaunay edges of the systems, split into
--   "islands" (inside a partition) and "bridges" (between two), thinned (ReduceHyperlaneIslandEdges
--   0x884480, ReduceHyperlaneBridgeEdges 0x884a00) and re-added where the thinning cut the galaxy
--   or made a detour of more than 20 jumps (ReAddRemovedEdgeIfNeeded 0x8867d0).
--
-- docs/newgame.md, 5.6 and 5.7.
--
--   local lanes = require("engine.newgame.lanes")
--   lanes.partition(inputs, r, game)    -- game.partitions, system.partition
--   lanes.hyperlanes(inputs, game)      -- system.lanes (draws from the global stream)

local rng = require("engine.newgame.rng")
local fixed = require("engine.newgame.fixed")
local delaunay = require("engine.newgame.delaunay")

local lanes = {}

local function d2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

-- round half away from zero
local function round(v)
    if v >= 0 then
        return math.floor(v + 0.5)
    end
    return -math.floor(-v + 0.5)
end

-- ---------------------------------------------------------------------------------------------
-- partitions

function lanes.partition(inputs, r, game)
    local sc, cfg = inputs.scenario, inputs.config
    local systems = game.systems
    local maxd2 = sc.max_hyperlane_distance * sc.max_hyperlane_distance
    local density = cfg.num_hyperlanes or 1
    local parts, status = {}, {}
    game.partitions, game.partition_of = parts, status

    local function new_partition(seed, settings, home)
        local desired = settings.min_systems
        if settings.max_systems > settings.min_systems then
            desired = settings.min_systems + r:below(settings.max_systems - settings.min_systems)
        end
        local br = round(settings.max_bridges * density) - settings.min_bridges
        local bridges = settings.min_bridges
        if br > 0 then
            bridges = bridges + r:below(br + 1)
        end
        local P = {
            id = #parts, seed = seed, systems = { seed.id }, desired = desired, desired_bridges = bridges,
            bridges = 0, arm = seed.arm or -1, neighbors = {}, home = home,
        }
        parts[#parts + 1] = P
        status[seed.id] = P.id
        return P
    end

    local visited
    -- AddRandomNeighborSystemsToPartition (0xa35270): up to `count` of the system's neighbours
    -- join the partition, picked at random; when its neighbours run out, the search goes on
    -- through them. Returns the count not added.
    local function add_random(P, sys, count)
        local cand = {}
        for _, nid in ipairs(sys.neighbors or {}) do
            local t = systems[nid + 1]
            local st = status[nid]
            if (st == nil or st == P.id) and not visited[nid] and (t.arm or -1) == P.arm and d2(t, sys) <= maxd2 then
                cand[#cand + 1] = t
            end
        end
        local m = #cand
        while count > 0 and m > 0 do
            local k = r:below(m) + 1
            local c = cand[k]
            if status[c.id] ~= P.id then
                status[c.id] = P.id
                P.systems[#P.systems + 1] = c.id
                count = count - 1
            end
            cand[k], cand[m] = cand[m], cand[k]
            m = m - 1
        end
        local i = 1
        while count > 0 and #cand > 0 do
            if i > #cand then
                i = 1
            end
            local c = cand[i]
            visited[c.id] = true
            if add_random(P, c, 1) == 1 then
                cand[i] = cand[#cand]
                cand[#cand] = nil
            else
                count = count - 1
                i = i + 1
            end
        end
        return count
    end

    -- the home partitions, seeded by the home systems in their (shuffled) order
    local home = sc.home_system_partitions
    local active = {}
    for _, sid in ipairs(game.home_systems or {}) do
        local s = systems[sid + 1]
        if status[s.id] == nil then
            local P = new_partition(s, home, true)
            if home.method == "depth_first" then
                visited = { [s.id] = true }
                add_random(P, s, P.desired)
            else
                active[#active + 1] = P
            end
        end
    end
    -- breadth first: one system at a time to each, until each is full or stuck
    while #active > 0 do
        for idx = #active, 1, -1 do
            local P = active[idx]
            if #P.systems >= P.desired then
                table.remove(active, idx)
            else
                visited = { [P.seed.id] = true }
                if add_random(P, P.seed, 1) == 1 then
                    table.remove(active, idx)
                end
            end
        end
    end
    -- the open partitions: every system not in one yet, in order
    local open = sc.open_space_partitions
    local open_active = {}
    for _, s in ipairs(systems) do
        if status[s.id] == nil then
            local P = new_partition(s, open, false)
            if open.method == "breadth_first" then
                open_active[#open_active + 1] = P
            else
                visited = { [s.id] = true }
                add_random(P, s, P.desired)
            end
        end
    end
    while #open_active > 0 do
        for idx = #open_active, 1, -1 do
            local P = open_active[idx]
            if #P.systems >= P.desired then
                table.remove(open_active, idx)
            else
                visited = { [P.seed.id] = true }
                if add_random(P, P.seed, 1) == 1 then
                    table.remove(open_active, idx)
                end
            end
        end
    end
    -- the partitions' neighbours
    local seen = {}
    for _, s in ipairs(systems) do
        local a = status[s.id]
        for _, nid in ipairs(s.neighbors or {}) do
            local b = status[nid]
            if b ~= a then
                local key = a * 100000 + b
                if not seen[key] then
                    seen[key] = true
                    table.insert(parts[a + 1].neighbors, b)
                end
            end
        end
    end
    -- MergeNeighborPartitions (0xa35c00): a partition filled to 60% or less of what it wanted joins
    -- the neighbour closest to it, the one with room preferred (and of its arm)
    for _, P in ipairs(parts) do
        if #P.systems > 0 and P.desired > 0 and #P.systems / P.desired <= 0.6 then
            local best, bestv
            for _, qid in ipairs(P.neighbors) do
                local Q = parts[qid + 1]
                if Q ~= P and Q.desired ~= 0 and #Q.systems > 0 then
                    local m = math.huge
                    for _, a in ipairs(P.systems) do
                        for _, b in ipairs(Q.systems) do
                            m = math.min(m, d2(systems[a + 1], systems[b + 1]))
                        end
                    end
                    local v = math.sqrt(m) + (#Q.systems + #P.systems) / Q.desired
                    if Q.arm ~= P.arm then
                        v = v + 1000
                    end
                    if bestv == nil or v < bestv then
                        best, bestv = Q, v
                    end
                end
            end
            if best then
                for _, sid in ipairs(P.systems) do
                    best.systems[#best.systems + 1] = sid
                    status[sid] = best.id
                end
                best.desired_bridges = math.max(best.desired_bridges, P.desired_bridges)
                for _, nid in ipairs(P.neighbors) do
                    if nid ~= best.id then
                        local dup = false
                        for _, x in ipairs(best.neighbors) do
                            if x == nid then
                                dup = true
                                break
                            end
                        end
                        if not dup then
                            best.neighbors[#best.neighbors + 1] = nid
                        end
                    end
                end
                P.systems, P.desired = {}, 0
            end
        end
    end
    for _, s in ipairs(systems) do
        s.partition = status[s.id]
    end
end

-- ---------------------------------------------------------------------------------------------
-- hyperlanes

-- edges sorted descending by (length, p0, p1), stably (SHyperlaneEdgeComp 0x886ff0)
local function sort_desc(list)
    for i, e in ipairs(list) do
        e.order = i
    end
    table.sort(list, function(a, b)
        if a.d ~= b.d then
            return a.d > b.d
        end
        if a.p0 ~= b.p0 then
            return a.p0 > b.p0
        end
        if a.p1 ~= b.p1 then
            return a.p1 > b.p1
        end
        return a.order < b.order
    end)
end

-- a sub-stream seeded from one draw of the global stream (0x884651)
local function sub_stream(game)
    local g = game.global:int()
    return rng.new(rng.noise32(g, rng.SEED_SALT), 0)
end

-- the adjacency of the surviving edges of the lists: v -> { {w, d} }
local function adjacency(lists)
    local adj = {}
    for _, list in ipairs(lists) do
        for _, e in ipairs(list) do
            if e.p0 >= 0 then
                adj[e.p0] = adj[e.p0] or {}
                adj[e.p1] = adj[e.p1] or {}
                table.insert(adj[e.p0], { e.p1, e.d })
                table.insert(adj[e.p1], { e.p0, e.d })
            end
        end
    end
    return adj
end

local function degree(adj, v)
    return adj[v] and #adj[v] or 0
end

local function unlink(adj, a, b)
    local l = adj[a]
    for i = 1, #l do
        if l[i][1] == b then
            l[i] = l[#l]
            l[#l] = nil
            return
        end
    end
end

-- RemoveIfExceedsEdgeLimit (0x886620): an edge whose two ends both have `limit` lanes or more goes
local function limit_edges(list, adj, removed, limit)
    for _, e in ipairs(list) do
        if e.p0 >= 0 and degree(adj, e.p0) >= limit and degree(adj, e.p1) >= limit then
            removed[#removed + 1] = { p0 = e.p0, p1 = e.p1, d = e.d, e = e }
            unlink(adj, e.p0, e.p1)
            unlink(adj, e.p1, e.p0)
            e.p0 = -1
        end
    end
end

-- ReAddRemovedEdgeIfNeeded (0x8867d0): the removed edges, shortest first; one goes back when its
-- ends are no longer connected, or (if not longer than max_hyperlane_distance) when the way round
-- takes more than 20 jumps (a FIFO label-correcting search, stopped when the far end is reached)
local function re_add(removed, adj, list, maxd)
    local readded = 0
    for i = #removed, 1, -1 do
        local x = removed[i]
        local dist, prev = { [x.p1] = 0 }, {}
        local queue, qi = { x.p1 }, 1
        local reached = false
        while qi <= #queue and not reached do
            local v = queue[qi]
            qi = qi + 1
            for _, wd in ipairs(adj[v] or {}) do
                local w, wgt = wd[1], wd[2]
                if dist[w] == nil or dist[w] > dist[v] + wgt then
                    dist[w] = dist[v] + wgt
                    prev[w] = v
                    queue[#queue + 1] = w
                    if w == x.p0 then
                        reached = true
                        break
                    end
                end
            end
        end
        local again = not reached
        if reached and x.d <= maxd then
            local hops, v = 0, x.p0
            while v ~= x.p1 and v ~= nil and hops < 1000 do
                v = prev[v]
                hops = hops + 1
            end
            again = hops > 20
        end
        if again then
            local e = { p0 = x.p0, p1 = x.p1, d = x.d, fixed = true }
            list[#list + 1] = e
            adj[e.p0] = adj[e.p0] or {}
            adj[e.p1] = adj[e.p1] or {}
            table.insert(adj[e.p0], { e.p1, e.d })
            table.insert(adj[e.p1], { e.p0, e.d })
            x.p0 = -1
            readded = readded + 1
        end
    end
    return readded
end

function lanes.hyperlanes(inputs, game)
    local sc, cfg = inputs.scenario, inputs.config
    local systems = game.systems
    local maxd = sc.max_hyperlane_distance
    local density = cfg.num_hyperlanes or 1
    local max_density = sc.num_hyperlanes_max or 3
    for _, s in ipairs(systems) do
        s.lanes = {}
    end
    if #systems < 3 then
        if #systems == 2 then
            lanes.add(systems[1], systems[2], math.sqrt(d2(systems[1], systems[2])), false)
        end
        return
    end
    -- the Delaunay edges of the systems at whole units, without those across the empty core
    local xs, ys = {}, {}
    local minr2, maxr2 = math.huge, 0
    for i, s in ipairs(systems) do
        xs[i], ys[i] = fixed.trunc(s.x), fixed.trunc(s.y)
        local r2 = s.x * s.x + s.y * s.y
        minr2, maxr2 = math.min(minr2, r2), math.max(maxr2, r2)
    end
    local t = delaunay.triangulate(xs, ys)
    local islands, bridges = {}, {}
    local parts = game.partitions or {}
    for _, e in ipairs(delaunay.edges(t)) do
        local a, b = systems[e[1]], systems[e[2]]
        local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
        local m2 = mx * mx + my * my
        if not (minr2 > 0 and (m2 <= minr2 or m2 >= maxr2)) then
            local edge = { p0 = b.id, p1 = a.id, d = math.floor(math.sqrt(d2(a, b))) }
            if a.partition == b.partition then
                islands[#islands + 1] = edge
            else
                bridges[#bridges + 1] = edge
                edge.pa, edge.pb = parts[a.partition + 1], parts[b.partition + 1]
                if edge.pa then
                    edge.pa.bridges = edge.pa.bridges + 1
                end
                if edge.pb then
                    edge.pb.bridges = edge.pb.bridges + 1
                end
            end
        end
    end

    -- ReduceHyperlaneIslandEdges
    sort_desc(islands)
    local to_remove = 0
    if density > 0 then
        to_remove = math.floor(#islands * 0.15 / density)
    end
    local removed = {}
    local k = 0
    for _, e in ipairs(islands) do
        if e.d > maxd then
            removed[#removed + 1] = { p0 = e.p0, p1 = e.p1, d = e.d, e = e }
            e.p0 = -1
            k = k + 1
        end
    end
    local r1 = sub_stream(game)
    local cand = {}
    for i = k + 1, #islands do
        if islands[i].p0 ~= -1 then
            cand[#cand + 1] = i
        end
    end
    for _ = 1, math.min(to_remove - k, #cand) do
        local j = r1:below(#cand) + 1
        local e = islands[cand[j]]
        cand[j] = cand[#cand]
        cand[#cand] = nil
        removed[#removed + 1] = { p0 = e.p0, p1 = e.p1, d = e.d, e = e }
        e.p0 = -1
    end
    sort_desc(removed)
    local adj = adjacency({ islands })
    if density < max_density then
        local limit = density > 1 and round(4 * density) or 4
        limit_edges(islands, adj, removed, limit)
    end
    local readded_islands = re_add(removed, adj, islands, maxd)
    for _, e in ipairs(islands) do
        if e.p0 >= 0 then
            lanes.add(systems[e.p0 + 1], systems[e.p1 + 1], e.d, false)
        end
    end

    -- ReduceHyperlaneBridgeEdges
    sort_desc(bridges)
    local r2s = sub_stream(game)
    local removed_b = {}
    local bcand = {}
    for i = 1, #bridges do
        bcand[i] = i
    end
    for _ = 1, #bridges do
        local j = r2s:below(#bcand) + 1
        local e = bridges[bcand[j]]
        bcand[j] = bcand[#bcand]
        bcand[#bcand] = nil
        local thin = e.pa and e.pb and e.pa.bridges > e.pa.desired_bridges and e.pb.bridges > e.pb.desired_bridges
            and density < max_density
        if thin or e.d > maxd then
            removed_b[#removed_b + 1] = { p0 = e.p0, p1 = e.p1, d = e.d, e = e }
            e.p0 = -1
            if e.pa then
                e.pa.bridges = e.pa.bridges - 1
            end
            if e.pb then
                e.pb.bridges = e.pb.bridges - 1
            end
        end
    end
    sort_desc(removed_b)
    local badj = adjacency({ bridges, islands })
    if density < max_density then
        local limit = density > 1 and round(4 * density) or 4
        limit_edges(bridges, badj, removed_b, limit)
    end
    local readded_bridges = re_add(removed_b, badj, bridges, maxd)
    for _, e in ipairs(bridges) do
        if e.p0 >= 0 then
            lanes.add(systems[e.p0 + 1], systems[e.p1 + 1], e.d, true)
        end
    end
    game.lane_stats = string.format("%d Delaunay edges (%d islands, %d bridges); %d and %d removed, %d and %d re-added",
        #islands + #bridges - readded_islands - readded_bridges, #islands - readded_islands, #bridges - readded_bridges,
        #removed, #removed_b, readded_islands, readded_bridges)
end

-- a lane both ways (no duplicate check, as the game)
function lanes.add(a, b, length, bridge)
    if a == b then
        return
    end
    a.lanes[#a.lanes + 1] = { to = b.id, length = length, bridge = bridge or nil }
    b.lanes[#b.lanes + 1] = { to = a.id, length = length, bridge = bridge or nil }
end

return lanes
