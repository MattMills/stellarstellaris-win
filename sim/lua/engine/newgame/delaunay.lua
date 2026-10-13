-- engine/newgame/delaunay.lua : the Delaunay triangulation and the Voronoi cells the galaxy
-- generator takes from Triangle (Shewchuk's, `triangulate` 0x1b7da40, compiled with float
-- coordinates; CPdxTriangulate): for the one Lloyd relaxation of the stars (GenerateStars) and the
-- systems' neighbours (CGameState::GenerateGalacticMap). Bowyer-Watson in doubles: the same
-- triangulation up to ties of cocircular points and float rounding, not Triangle's bits.
--
--   local delaunay = require("engine.newgame.delaunay")
--   local t = delaunay.triangulate(xs, ys)   -- t.tris = { {a, b, c, cx, cy, r2} } (indices into xs)
--   delaunay.edges(t)                        -- { {a, b} } each once, a < b
--   delaunay.relax(xs, ys, t, lo, hi)        -- one Lloyd step (CPdxTriangulate::RelaxPoints)

local delaunay = {}

local function circum(ax, ay, bx, by, cx, cy)
    local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if d == 0 then
        return nil
    end
    local a2, b2, c2 = ax * ax + ay * ay, bx * bx + by * by, cx * cx + cy * cy
    local ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    local uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    local dx, dy = ax - ux, ay - uy
    return ux, uy, dx * dx + dy * dy
end

-- delaunay.triangulate(xs, ys) -> { tris, n }: the points 1..n, a super triangle around them
-- (vertices n+1..n+3, dropped from the result)
function delaunay.triangulate(xs, ys)
    local n = #xs
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, n do
        minx, maxx = math.min(minx, xs[i]), math.max(maxx, xs[i])
        miny, maxy = math.min(miny, ys[i]), math.max(maxy, ys[i])
    end
    local span = math.max(maxx - minx, maxy - miny, 1) * 20
    local mx, my = (minx + maxx) / 2, (miny + maxy) / 2
    local px, py = {}, {}
    for i = 1, n do
        px[i], py[i] = xs[i], ys[i]
    end
    px[n + 1], py[n + 1] = mx - span, my - span
    px[n + 2], py[n + 2] = mx + span, my - span
    px[n + 3], py[n + 3] = mx, my + span
    local tris = {}
    local function add(a, b, c)
        local ux, uy, r2 = circum(px[a], py[a], px[b], py[b], px[c], py[c])
        if ux then
            tris[#tris + 1] = { a, b, c, ux, uy, r2 }
        end
    end
    add(n + 1, n + 2, n + 3)
    for i = 1, n do
        local x, y = px[i], py[i]
        local edges, keep = {}, {}
        for _, t in ipairs(tris) do
            local dx, dy = x - t[4], y - t[5]
            if dx * dx + dy * dy < t[6] then
                -- the cavity: its edges, an edge seen twice is inside it
                for k = 1, 3 do
                    local a, b = t[k], t[k % 3 + 1]
                    local key = a < b and (a * 65536 + b) or (b * 65536 + a)
                    if edges[key] then
                        edges[key] = false
                    else
                        edges[key] = { a, b }
                    end
                end
            else
                keep[#keep + 1] = t
            end
        end
        tris = keep
        for _, e in pairs(edges) do
            if e then
                add(e[1], e[2], i)
            end
        end
    end
    local out = {}
    for _, t in ipairs(tris) do
        if t[1] <= n and t[2] <= n and t[3] <= n then
            out[#out + 1] = t
        end
    end
    return { tris = out, all = tris, n = n }
end

-- the edges between points 1..n, each once
function delaunay.edges(t)
    local seen, out = {}, {}
    for _, tri in ipairs(t.tris) do
        for k = 1, 3 do
            local a, b = tri[k], tri[k % 3 + 1]
            if a > b then
                a, b = b, a
            end
            local key = a * 65536 + b
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = { a, b }
            end
        end
    end
    table.sort(out, function(p, q)
        if p[1] ~= q[1] then
            return p[1] < q[1]
        end
        return p[2] < q[2]
    end)
    return out
end

-- one Lloyd step (CPdxTriangulate::RelaxPoints 0x1b46440, Jacobi): every point whose Voronoi cell
-- is closed (not on the hull) and inside [lo, hi] on both axes moves to the cell's centroid
-- (CPdxTriangulate::Centroid 0x1b50a10: a fan from the first vertex). Returns new xs, ys.
function delaunay.relax(xs, ys, t, lo, hi)
    local n = t.n
    local around = {}
    local hull = {}
    for _, tri in ipairs(t.all) do
        local super = tri[1] > n or tri[2] > n or tri[3] > n
        for k = 1, 3 do
            local v = tri[k]
            if v <= n then
                if super then
                    hull[v] = true
                else
                    local l = around[v]
                    if not l then
                        l = {}
                        around[v] = l
                    end
                    l[#l + 1] = tri
                end
            end
        end
    end
    local nx, ny = {}, {}
    for i = 1, n do
        nx[i], ny[i] = xs[i], ys[i]
        local l = around[i]
        if not hull[i] and l and #l >= 3 then
            -- the cell's vertices (the circumcentres) in order around the point
            local x, y = xs[i], ys[i]
            local cells = {}
            local inside = true
            for _, tri in ipairs(l) do
                local cx, cy = tri[4], tri[5]
                if cx < lo or cx > hi or cy < lo or cy > hi then
                    inside = false
                    break
                end
                cells[#cells + 1] = { cx, cy, math.atan2(cy - y, cx - x) }
            end
            if inside then
                table.sort(cells, function(a, b) return a[3] < b[3] end)
                local sx, sy, area = 0, 0, 0
                local x0, y0 = cells[1][1], cells[1][2]
                for k = 2, #cells - 1 do
                    local x1, y1 = cells[k][1], cells[k][2]
                    local x2, y2 = cells[k + 1][1], cells[k + 1][2]
                    local cross = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
                    area = area + cross
                    sx = sx + (x0 + x1 + x2) * cross
                    sy = sy + (y0 + y1 + y2) * cross
                end
                if area ~= 0 then
                    nx[i], ny[i] = sx / (area * 3), sy / (area * 3)
                end
            end
        end
    end
    return nx, ny
end

return delaunay
