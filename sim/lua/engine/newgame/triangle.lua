-- engine/newgame/triangle.lua : the Delaunay triangulation of J. R. Shewchuk's Triangle, the way
-- the game runs it (CPdxTriangulate, triangulate("pczAevnQ")), for the order of its edges.
--
-- The game reads the triangulation's edges in Triangle's own output order (writeedges): the
-- triangles in the order they were made, each one's three edges in turn, an edge written by the
-- triangle with the lower address (or by the only one, on the hull). CGameState::GenerateGalacticMap
-- builds every system's neighbour list (CGalacticObject::_GalacticNeighbors) in that order, and the
-- partitioner draws its candidates from those lists (docs/newgame.md, 5.4 and 5.6), so the order
-- decides the partitions, and through them the hyperlanes. This is Triangle's default algorithm
-- for the switches the game gives: divide and conquer with Dwyer's alternating cuts
-- (divconqdelaunay, alternateaxes, divconqrecurse, mergehulls), the bounding ghost triangles
-- removed (removeghosts), the triangles in allocation order. None is deleted later (no holes,
-- `c` keeps the convex hull), so the order is that of maketriangle.
--
-- The vertex sort and the medians of Triangle draw random pivots, which only reorder vertices
-- inside the halves that are split again, so for distinct vertices the result does not depend on
-- them. The predicates are evaluated in doubles: exact for the integer coordinates the game gives
-- (the systems' whole units and the rings' truncated points), where the products stay below 2^53.
--
--   local triangle = require("engine.newgame.triangle")
--   local edges = triangle.edges(xs, ys)   -- { { i, j }, ... } 1-based indices into xs/ys

local triangle = {}

local PLUS1 = { [0] = 1, 2, 0 }
local MINUS1 = { [0] = 2, 0, 1 }

-- a triangle: n[0..2] neighbour triangles, no[0..2] their orientations, v[0..2] its corners (the
-- apex of orientation k is v[k], the origin v[PLUS1[k]], the destination v[MINUS1[k]]; 0: none)
local function mesh()
    local M = { pool = {} }
    local dummy = { n = {}, no = {}, v = { [0] = 0, 0, 0 }, index = -1, dummy = true }
    dummy.n[0], dummy.n[1], dummy.n[2] = dummy, dummy, dummy
    dummy.no[0], dummy.no[1], dummy.no[2] = 0, 0, 0
    M.dummy = dummy
    return M
end

local function make(M)
    local d = M.dummy
    local t = { n = { [0] = d, d, d }, no = { [0] = 0, 0, 0 }, v = { [0] = 0, 0, 0 }, index = #M.pool }
    M.pool[#M.pool + 1] = t
    return t
end

-- oriented triangles are (t, o) pairs
local function org(t, o) return t.v[PLUS1[o]] end
local function dest(t, o) return t.v[MINUS1[o]] end
local function apex(t, o) return t.v[o] end
local function setorg(t, o, v) t.v[PLUS1[o]] = v end
local function setdest(t, o, v) t.v[MINUS1[o]] = v end
local function setapex(t, o, v) t.v[o] = v end
local function sym(t, o) return t.n[o], t.no[o] end
local function bond(t1, o1, t2, o2)
    t1.n[o1], t1.no[o1] = t2, o2
    t2.n[o2], t2.no[o2] = t1, o1
end

function triangle.edges(xs, ys)
    local n = #xs
    local X, Y = xs, ys
    local function ccw(a, b, c)
        return (X[a] - X[c]) * (Y[b] - Y[c]) - (Y[a] - Y[c]) * (X[b] - X[c])
    end
    local function incircle(a, b, c, d)
        local adx, ady = X[a] - X[d], Y[a] - Y[d]
        local bdx, bdy = X[b] - X[d], Y[b] - Y[d]
        local cdx, cdy = X[c] - X[d], Y[c] - Y[d]
        local alift = adx * adx + ady * ady
        local blift = bdx * bdx + bdy * bdy
        local clift = cdx * cdx + cdy * cdy
        return alift * (bdx * cdy - cdx * bdy) + blift * (cdx * ady - adx * cdy) + clift * (adx * bdy - bdx * ady)
    end
    local M = mesh()

    -- divconqdelaunay: sort by x then y, drop duplicates, alternate the axes
    local arr = {}
    for i = 1, n do
        arr[i] = i
    end
    local function less(axis)
        if axis == 0 then
            return function(a, b)
                if X[a] ~= X[b] then return X[a] < X[b] end
                return Y[a] < Y[b]
            end
        end
        return function(a, b)
            if Y[a] ~= Y[b] then return Y[a] < Y[b] end
            return X[a] < X[b]
        end
    end
    table.sort(arr, less(0))
    local uniq = {}
    for i = 1, #arr do
        local v = arr[i]
        local u = uniq[#uniq]
        if not u or X[u] ~= X[v] or Y[u] ~= Y[v] then
            uniq[#uniq + 1] = v
        end
    end
    arr = uniq
    local function sorted_range(lo, cnt, axis)
        local tmp = {}
        for i = 1, cnt do
            tmp[i] = arr[lo + i - 1]
        end
        table.sort(tmp, less(axis))
        for i = 1, cnt do
            arr[lo + i - 1] = tmp[i]
        end
    end
    -- alternateaxes: a median cut on the axis, the halves cut on the other (subsets of two or
    -- three by x)
    local function alternate(lo, cnt, axis)
        local divider = math.floor(cnt / 2)
        if cnt <= 3 then
            axis = 0
        end
        sorted_range(lo, cnt, axis)
        if cnt - divider >= 2 then
            if divider >= 2 then
                alternate(lo, divider, 1 - axis)
            end
            alternate(lo + divider, cnt - divider, 1 - axis)
        end
    end
    local total = #arr
    local divider = math.floor(total / 2)
    if total - divider >= 2 then
        if divider >= 2 then
            alternate(1, divider, 1)
        end
        alternate(1 + divider, total - divider, 1)
    end

    -- mergehulls
    local function merge(fl, flo, il, ilo, ir, iro, fr, fro, axis)
        local ild, ila = dest(il, ilo), apex(il, ilo)
        local iro_, ira = org(ir, iro), apex(ir, iro)
        local t, o
        if axis == 1 then
            -- horizontal cuts: the extremal pointers to the topmost and bottommost vertices
            local flp, fla = org(fl, flo), apex(fl, flo)
            while Y[fla] < Y[flp] do
                flo = PLUS1[flo]
                fl, flo = sym(fl, flo)
                flp = fla
                fla = apex(fl, flo)
            end
            local ct, co = sym(il, ilo)
            local cv = apex(ct, co)
            while Y[cv] > Y[ild] do
                il, ilo = ct, PLUS1[co]
                ila = ild
                ild = cv
                ct, co = sym(il, ilo)
                cv = apex(ct, co)
            end
            while Y[ira] < Y[iro_] do
                iro = PLUS1[iro]
                ir, iro = sym(ir, iro)
                iro_ = ira
                ira = apex(ir, iro)
            end
            local frp = dest(fr, fro)
            ct, co = sym(fr, fro)
            cv = apex(ct, co)
            while Y[cv] > Y[frp] do
                fr, fro = ct, PLUS1[co]
                frp = cv
                ct, co = sym(fr, fro)
                cv = apex(ct, co)
            end
        end
        -- a line tangent to and below both hulls
        repeat
            local changed = false
            if ccw(ild, ila, iro_) > 0 then
                ilo = MINUS1[ilo]
                il, ilo = sym(il, ilo)
                ild = ila
                ila = apex(il, ilo)
                changed = true
            end
            if ccw(ira, iro_, ild) > 0 then
                iro = PLUS1[iro]
                ir, iro = sym(ir, iro)
                iro_ = ira
                ira = apex(ir, iro)
                changed = true
            end
        until not changed
        local lct, lco = sym(il, ilo)
        local rct, rco = sym(ir, iro)
        -- the bottom bounding triangle
        local bt = make(M)
        local bo = 0
        bond(bt, bo, il, ilo)
        bo = PLUS1[bo]
        bond(bt, bo, ir, iro)
        bo = PLUS1[bo]
        setorg(bt, bo, iro_)
        setdest(bt, bo, ild)
        if ild == org(fl, flo) then
            fl, flo = bt, PLUS1[bo]
        end
        if iro_ == dest(fr, fro) then
            fr, fro = bt, MINUS1[bo]
        end
        local ll, lr = ild, iro_
        local ul, ur = apex(lct, lco), apex(rct, rco)
        while true do
            local lfin = ul == 0 or ccw(ul, ll, lr) <= 0
            local rfin = ur == 0 or ccw(ur, ll, lr) <= 0
            if lfin and rfin then
                -- the top bounding triangle
                local nt = make(M)
                local no = 0
                setorg(nt, no, ll)
                setdest(nt, no, lr)
                bond(nt, no, bt, bo)
                no = PLUS1[no]
                bond(nt, no, rct, rco)
                no = PLUS1[no]
                bond(nt, no, lct, lco)
                if axis == 1 then
                    local flp, frp = org(fl, flo), dest(fr, fro)
                    local fra = apex(fr, fro)
                    local ct, co = sym(fl, flo)
                    local cv = apex(ct, co)
                    while cv ~= 0 and X[cv] < X[flp] do
                        fl, flo = ct, MINUS1[co]
                        flp = cv
                        ct, co = sym(fl, flo)
                        cv = apex(ct, co)
                    end
                    while fra ~= 0 and X[fra] > X[frp] do
                        fro = MINUS1[fro]
                        fr, fro = sym(fr, fro)
                        frp = fra
                        fra = apex(fr, fro)
                    end
                end
                return fl, flo, fr, fro
            end
            if not lfin then
                -- eliminate edges from the left triangulation
                local et, eo = sym(lct, MINUS1[lco])
                local na = apex(et, eo)
                if na ~= 0 then
                    local bad = incircle(ll, lr, ul, na) > 0
                    while bad do
                        eo = PLUS1[eo]
                        local tct, tco = sym(et, eo)
                        eo = PLUS1[eo]
                        local sct, sco = sym(et, eo)
                        bond(et, eo, tct, tco)
                        bond(lct, lco, sct, sco)
                        lco = PLUS1[lco]
                        local oct, oco = sym(lct, lco)
                        eo = MINUS1[eo]
                        bond(et, eo, oct, oco)
                        setorg(lct, lco, ll)
                        setdest(lct, lco, 0)
                        setapex(lct, lco, na)
                        setorg(et, eo, 0)
                        setdest(et, eo, ul)
                        setapex(et, eo, na)
                        ul = na
                        et, eo = sct, sco
                        na = apex(et, eo)
                        if na ~= 0 then
                            bad = incircle(ll, lr, ul, na) > 0
                        else
                            bad = false
                        end
                    end
                end
            end
            if not rfin then
                -- eliminate edges from the right triangulation
                local et, eo = sym(rct, PLUS1[rco])
                local na = apex(et, eo)
                if na ~= 0 then
                    local bad = incircle(ll, lr, ur, na) > 0
                    while bad do
                        eo = MINUS1[eo]
                        local tct, tco = sym(et, eo)
                        eo = MINUS1[eo]
                        local sct, sco = sym(et, eo)
                        bond(et, eo, tct, tco)
                        bond(rct, rco, sct, sco)
                        rco = MINUS1[rco]
                        local oct, oco = sym(rct, rco)
                        eo = PLUS1[eo]
                        bond(et, eo, oct, oco)
                        setorg(rct, rco, 0)
                        setdest(rct, rco, lr)
                        setapex(rct, rco, na)
                        setorg(et, eo, ur)
                        setdest(et, eo, 0)
                        setapex(et, eo, na)
                        ur = na
                        et, eo = sct, sco
                        na = apex(et, eo)
                        if na ~= 0 then
                            bad = incircle(ll, lr, ur, na) > 0
                        else
                            bad = false
                        end
                    end
                end
            end
            -- the finished flags are those computed before the eliminations (Triangle's)
            if lfin or (not rfin and incircle(ul, ll, lr, ur) > 0) then
                -- knit with an edge from the lower left to the upper right
                bond(bt, bo, rct, rco)
                bt, bo = rct, MINUS1[rco]
                setdest(bt, bo, ll)
                lr = ur
                rct, rco = sym(bt, bo)
                ur = apex(rct, rco)
            else
                -- knit with an edge from the upper left to the lower right
                bond(bt, bo, lct, lco)
                bt, bo = lct, PLUS1[lco]
                setorg(bt, bo, lr)
                ll = ul
                lct, lco = sym(bt, bo)
                ul = apex(lct, lco)
            end
        end
    end

    -- divconqrecurse: returns farleft, farright (oriented triangles)
    local function recurse(lo, cnt, axis)
        if cnt == 2 then
            local fl, fr = make(M), make(M)
            local flo, fro = 0, 0
            setorg(fl, flo, arr[lo])
            setdest(fl, flo, arr[lo + 1])
            setorg(fr, fro, arr[lo + 1])
            setdest(fr, fro, arr[lo])
            bond(fl, flo, fr, fro)
            flo, fro = MINUS1[flo], PLUS1[fro]
            bond(fl, flo, fr, fro)
            flo, fro = MINUS1[flo], PLUS1[fro]
            bond(fl, flo, fr, fro)
            -- the origin of farleft is the first vertex
            return fr, MINUS1[fro], fr, fro
        elseif cnt == 3 then
            local mid, t1, t2, t3 = make(M), make(M), make(M), make(M)
            local mo, o1, o2, o3 = 0, 0, 0, 0
            local a, b, c = arr[lo], arr[lo + 1], arr[lo + 2]
            local area = ccw(a, b, c)
            if area == 0 then
                -- three collinear vertices: two edges
                setorg(mid, mo, a)
                setdest(mid, mo, b)
                setorg(t1, o1, b)
                setdest(t1, o1, a)
                setorg(t2, o2, c)
                setdest(t2, o2, b)
                setorg(t3, o3, b)
                setdest(t3, o3, c)
                bond(mid, mo, t1, o1)
                bond(t2, o2, t3, o3)
                mo = PLUS1[mo]
                o1 = MINUS1[o1]
                o2 = PLUS1[o2]
                o3 = MINUS1[o3]
                bond(mid, mo, t3, o3)
                bond(t1, o1, t2, o2)
                mo = PLUS1[mo]
                o1 = MINUS1[o1]
                o2 = PLUS1[o2]
                o3 = MINUS1[o3]
                bond(mid, mo, t1, o1)
                bond(t2, o2, t3, o3)
                return t1, o1, t2, o2
            end
            setorg(mid, mo, a)
            setdest(t1, o1, a)
            setorg(t3, o3, a)
            if area > 0 then
                setdest(mid, mo, b)
                setorg(t1, o1, b)
                setdest(t2, o2, b)
                setapex(mid, mo, c)
                setorg(t2, o2, c)
                setdest(t3, o3, c)
            else
                setdest(mid, mo, c)
                setorg(t1, o1, c)
                setdest(t2, o2, c)
                setapex(mid, mo, b)
                setorg(t2, o2, b)
                setdest(t3, o3, b)
            end
            bond(mid, mo, t1, o1)
            mo = PLUS1[mo]
            bond(mid, mo, t2, o2)
            mo = PLUS1[mo]
            bond(mid, mo, t3, o3)
            o1 = MINUS1[o1]
            o2 = PLUS1[o2]
            bond(t1, o1, t2, o2)
            o1 = MINUS1[o1]
            o3 = MINUS1[o3]
            bond(t1, o1, t3, o3)
            o2 = PLUS1[o2]
            o3 = MINUS1[o3]
            bond(t2, o2, t3, o3)
            if area > 0 then
                return t1, o1, t2, o2
            end
            return t1, o1, t1, PLUS1[o1]
        end
        local div = math.floor(cnt / 2)
        local fl, flo, il, ilo = recurse(lo, div, 1 - axis)
        local ir, iro, fr, fro = recurse(lo + div, cnt - div, 1 - axis)
        return merge(fl, flo, il, ilo, ir, iro, fr, fro, axis)
    end

    local edges = {}
    if total < 2 then
        return edges
    end
    local hl, hlo = recurse(1, total, 0)
    -- removeghosts: the bounding triangles (those with no apex) are deleted
    local dt, dob = sym(hl, MINUS1[hlo])
    local start_t, start_o = hl, hlo
    local dis_t, dis_o = hl, hlo
    repeat
        local dead_t = dis_t
        local dead_o = PLUS1[dis_o]
        dis_t, dis_o = sym(dis_t, MINUS1[dis_o])
        dis_t.n[dis_o], dis_t.no[dis_o] = M.dummy, 0
        local nt, no = sym(dead_t, dead_o)
        dead_t.dead = true
        dis_t, dis_o = nt, no
    until dis_t == start_t and dis_o == start_o
    local _ = dt and dob
    -- writeedges: the live triangles in allocation order, each edge once
    for _, t in ipairs(M.pool) do
        if not t.dead then
            for o = 0, 2 do
                local s = t.n[o]
                if s.dummy or t.index < s.index then
                    edges[#edges + 1] = { org(t, o), dest(t, o) }
                end
            end
        end
    end
    return edges
end

return triangle
