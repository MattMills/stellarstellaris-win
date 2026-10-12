-- graph/core.lua : the standing dependency graph of stellar.graph: numbers, formulas over them,
-- cached values, lazy chunked invalidation, deadline classes and incremental topological levels.
--
-- A node is a value. An input node is set from outside (a modifier's local sum, a job's base
-- output, a stockpile); every other node is a formula over the nodes linked into it:
--
--   sum      base + sum(coef * x)               (kept up to date with deltas, see below)
--   clamp    min(max(base + sum(coef * x), lo), hi)
--   product  base * prod(coef * x)
--   min/max  min/max(base, coef * x, ...)
--   func     f(g, node), any Lua function of the inputs (it must not change the graph)
--
-- Every value is cached. Nothing is computed when something changes:
--
-- * g:set(input, x) is O(1): it records the input in the frontier.
-- * g:mark(budget) processes the frontier in chunks: it gives each input's change to its direct
--   dependents (a delta for sums) and marks everything downstream dirty, once (a dirty node is not
--   visited again until it is computed). Marking is pessimistic; computing is exact.
-- * Dirty nodes wait in buckets by deadline class and level: that is the list of pending
--   invalidations (g:pending()) at the end of a tick.
-- * g:run(class, budget) computes up to `budget` dirty nodes needed by `class`, lowest level first,
--   so that inputs are always computed before the nodes that read them. A node whose inputs did
--   not actually change is only unmarked (early cutoff). A sum whose inputs changed takes the
--   accumulated delta, O(1) whatever its number of inputs, with a full recompute every
--   DELTA_LIMIT updates against rounding drift.
-- * g:get(node) is always exact: it finishes marking if needed, then computes the dirty part of
--   the node's inputs (and only that) in level order. A clean node costs a lookup.
--
-- Deadline classes, most urgent first: FRAME (the UI shows it this frame), TICK (the simulation
-- reads it at the next tick), DAY (the daily update), MONTH (the monthly update) and READ (only
-- when read). A node's need is the most urgent class of itself and everything that reads it, kept
-- up to date as classes and edges change, so a node needed by a FRAME node is a FRAME node too.
-- stellar.graph.schedule spreads the work over frames by these deadlines.
--
-- The order is a level per node: inputs have a lower level than the nodes that read them. Linking
-- raises the levels that need it (and refuses a cycle); levels never go down, which keeps them a
-- valid order. Nodes and edges live in flat malloc'd arrays (stellar.graph.buffer); each node's
-- inputs and dependents are blocks of these arrays with back-pointers, so an edge is removed in
-- O(1) once found.
--
--   local core = require("stellar.graph.core")
--   local g = core.new()
--   local a, b = g:input(2), g:input(3)
--   local s = g:sum(1)                  -- s = 1 + 2a + b
--   g:link(a, s, 2)
--   g:link(b, s)
--   g:get(s)                            --> 8
--   g:set(a, 5)                         -- O(1), nothing computed
--   g:set_class(s, core.TICK)
--   g:mark(1e9)                         -- the end of the tick: the pending list is complete
--   g:pending()                         --> { frontier = 0, total = 1, dirty = { 0, 1, 0, 0, 0 }, ... }
--   g:run(core.TICK, 100)               -- s = 14
--
-- Node ids are integers from 1. A graph is single-threaded and must not be changed from inside a
-- func node.

local bit = require("bit")
local buffer = require("stellar.graph.buffer")

local band, bor, bnot = bit.band, bit.bor, bit.bnot
local huge = math.huge
local abs = math.abs

local M = {}

-- operations
local INPUT, SUM, PRODUCT, MIN, MAX, CLAMP, FUNC = 0, 1, 2, 3, 4, 5, 6
M.INPUT, M.SUM, M.PRODUCT, M.MIN, M.MAX, M.CLAMP, M.FUNC = INPUT, SUM, PRODUCT, MIN, MAX, CLAMP, FUNC
M.OP_NAMES = { [0] = "input", "sum", "product", "min", "max", "clamp", "func" }

-- deadline classes, most urgent first
local FRAME, TICK, DAY, MONTH, READ = 1, 2, 3, 4, 5
local NCLASS = 5
M.FRAME, M.TICK, M.DAY, M.MONTH, M.READ, M.NCLASS = FRAME, TICK, DAY, MONTH, READ, NCLASS
M.CLASS_NAMES = { "frame", "tick", "day", "month", "read" }

-- node flags
local DIRTY = 1     -- marked: to compute (or to unmark if no input changed)
local FRONTIER = 2  -- its dependents are not marked yet (an input: its change is not given yet)
local CHANGED = 4   -- an input, the base or the edges changed since it was computed
local FULL = 8      -- recompute from all inputs (not from the accumulated delta)
local DEAD = 16     -- a free id

-- delta updates of a sum between two full recomputes
local DELTA_LIMIT = 64
M.DELTA_LIMIT = DELTA_LIMIT

local DEFAULT_BASE = { [INPUT] = 0, [SUM] = 0, [PRODUCT] = 1, [MIN] = huge, [MAX] = -huge, [CLAMP] = 0, [FUNC] = 0 }

-- core.new(options) -> graph. options: nodes, edges (initial capacities), epsilon (a change
-- smaller than epsilon * (1 + |value|) is not propagated; 0, the default, propagates any change)
function M.new(options)
    options = options or {}
    local g = {}
    local eps = options.epsilon or 0

    -- nodes: ids 1..nn, arrays sized ncap + 1
    local ncap = math.max(options.nodes or 1024, 16)
    local nn, alive = 0, 0
    local free_ids, nfree = {}, 0

    local op = buffer.new("uint8_t", ncap + 1)
    local flags = buffer.new("uint8_t", ncap + 1)
    local class = buffer.new("uint8_t", ncap + 1)
    local need = buffer.new("uint8_t", ncap + 1)
    local ndelta = buffer.new("uint8_t", ncap + 1)
    local level = buffer.new("int32_t", ncap + 1)
    local visit = buffer.new("uint32_t", ncap + 1)
    local value = buffer.new("double", ncap + 1)
    local base = buffer.new("double", ncap + 1)
    local acc = buffer.new("double", ncap + 1)      -- sum and clamp: the unclamped sum
    local pending = buffer.new("double", ncap + 1)  -- sum and clamp: deltas not applied yet
    local lo_v = buffer.new("double", ncap + 1)     -- clamp bounds
    local hi_v = buffer.new("double", ncap + 1)
    local in_off = buffer.new("int32_t", ncap + 1)
    local in_cnt = buffer.new("int32_t", ncap + 1)
    local in_cap = buffer.new("int32_t", ncap + 1)
    local out_off = buffer.new("int32_t", ncap + 1)
    local out_cnt = buffer.new("int32_t", ncap + 1)
    local out_cap = buffer.new("int32_t", ncap + 1)

    -- edges: an input slot (source, coefficient, index of its slot in the source's dependents)
    -- and a dependent slot (node, index of its slot in the node's inputs)
    local icap = math.max(options.edges or 4096, 16)
    local ocap = icap
    local itop, otop = 0, 0
    local in_src = buffer.new("int32_t", icap)
    local in_coef = buffer.new("double", icap)
    local in_back = buffer.new("int32_t", icap)
    local out_dst = buffer.new("int32_t", ocap)
    local out_back = buffer.new("int32_t", ocap)
    local in_free, out_free = {}, {}  -- [block size] = { n = count, offsets... }
    local nedges = 0

    local funcs = {}
    local frontier, nfront = {}, 0
    local bk = {}  -- bk[class][level] = { n = count, node ids... } (stale entries are skipped)
    for c = 1, NCLASS do
        bk[c] = {}
    end
    local lvl_n = {}  -- [level] = bucket entries at that level, all classes
    local lo, hi = 1, 0
    local ndirty = { 0, 0, 0, 0, 0 }
    local epoch = 0

    -- counters
    local n_computes, n_cutoffs, n_deltas, n_fulls, n_changes, n_sets, n_marked, n_pulls = 0, 0, 0, 0, 0, 0, 0, 0

    -- storage --------------------------------------------------------------------------------

    local function grow_nodes(want)
        local new = ncap
        while new < want do
            new = new * 2
        end
        local a, b = ncap + 1, new + 1
        op = buffer.grow(op, "uint8_t", a, b)
        flags = buffer.grow(flags, "uint8_t", a, b)
        class = buffer.grow(class, "uint8_t", a, b)
        need = buffer.grow(need, "uint8_t", a, b)
        ndelta = buffer.grow(ndelta, "uint8_t", a, b)
        level = buffer.grow(level, "int32_t", a, b)
        visit = buffer.grow(visit, "uint32_t", a, b)
        value = buffer.grow(value, "double", a, b)
        base = buffer.grow(base, "double", a, b)
        acc = buffer.grow(acc, "double", a, b)
        pending = buffer.grow(pending, "double", a, b)
        lo_v = buffer.grow(lo_v, "double", a, b)
        hi_v = buffer.grow(hi_v, "double", a, b)
        in_off = buffer.grow(in_off, "int32_t", a, b)
        in_cnt = buffer.grow(in_cnt, "int32_t", a, b)
        in_cap = buffer.grow(in_cap, "int32_t", a, b)
        out_off = buffer.grow(out_off, "int32_t", a, b)
        out_cnt = buffer.grow(out_cnt, "int32_t", a, b)
        out_cap = buffer.grow(out_cap, "int32_t", a, b)
        ncap = new
    end

    local function in_alloc(size)
        local fl = in_free[size]
        if fl ~= nil and fl.n > 0 then
            local off = fl[fl.n]
            fl[fl.n] = nil
            fl.n = fl.n - 1
            return off
        end
        if itop + size > icap then
            local new = icap
            while new < itop + size do
                new = new * 2
            end
            in_src = buffer.grow(in_src, "int32_t", icap, new)
            in_coef = buffer.grow(in_coef, "double", icap, new)
            in_back = buffer.grow(in_back, "int32_t", icap, new)
            icap = new
        end
        local off = itop
        itop = itop + size
        return off
    end

    local function out_alloc(size)
        local fl = out_free[size]
        if fl ~= nil and fl.n > 0 then
            local off = fl[fl.n]
            fl[fl.n] = nil
            fl.n = fl.n - 1
            return off
        end
        if otop + size > ocap then
            local new = ocap
            while new < otop + size do
                new = new * 2
            end
            out_dst = buffer.grow(out_dst, "int32_t", ocap, new)
            out_back = buffer.grow(out_back, "int32_t", ocap, new)
            ocap = new
        end
        local off = otop
        otop = otop + size
        return off
    end

    local function release(free, off, size)
        local fl = free[size]
        if fl == nil then
            fl = { n = 0 }
            free[size] = fl
        end
        fl.n = fl.n + 1
        fl[fl.n] = off
    end

    -- room for one more input of v / dependent of u
    local function in_reserve(v)
        local cnt, cap = in_cnt[v], in_cap[v]
        if cnt < cap then
            return
        end
        local size = cap == 0 and 1 or cap * 2
        local off2 = in_alloc(size)
        local off = in_off[v]
        for k = 0, cnt - 1 do
            in_src[off2 + k] = in_src[off + k]
            in_coef[off2 + k] = in_coef[off + k]
            in_back[off2 + k] = in_back[off + k]
        end
        if cap > 0 then
            release(in_free, off, cap)
        end
        in_off[v] = off2
        in_cap[v] = size
    end

    local function out_reserve(u)
        local cnt, cap = out_cnt[u], out_cap[u]
        if cnt < cap then
            return
        end
        local size = cap == 0 and 1 or cap * 2
        local off2 = out_alloc(size)
        local off = out_off[u]
        for j = 0, cnt - 1 do
            out_dst[off2 + j] = out_dst[off + j]
            out_back[off2 + j] = out_back[off + j]
        end
        if cap > 0 then
            release(out_free, off, cap)
        end
        out_off[u] = off2
        out_cap[u] = size
    end

    -- dirty marking -------------------------------------------------------------------------

    local function enqueue(n)
        local l = level[n]
        local b = bk[need[n]][l]
        if b == nil then
            b = { n = 0 }
            bk[need[n]][l] = b
        end
        local k = b.n + 1
        b[k] = n
        b.n = k
        lvl_n[l] = (lvl_n[l] or 0) + 1
        if l < lo then
            lo = l
        end
        if l > hi then
            hi = l
        end
    end

    -- mark n dirty (with its dependents later, through the frontier)
    local function touch(n)
        local f = flags[n]
        if band(f, DIRTY) == 0 then
            if band(f, FRONTIER) == 0 then
                nfront = nfront + 1
                frontier[nfront] = n
            end
            flags[n] = bor(f, DIRTY + FRONTIER)
            local c = need[n]
            ndirty[c] = ndirty[c] + 1
            enqueue(n)
            n_marked = n_marked + 1
        end
    end

    -- an input, the base or an edge of v changed: d is the change of its sum (sum and clamp)
    local function changed_input(v, d)
        local o = op[v]
        if (o == SUM or o == CLAMP) and d - d == 0 then
            pending[v] = pending[v] + d
            flags[v] = bor(flags[v], CHANGED)
        else
            flags[v] = bor(flags[v], CHANGED + FULL)
        end
        touch(v)
    end

    -- n's value changed by d: give it to the dependents
    local function push(n, d)
        local finite = d - d == 0
        local off = out_off[n]
        for j = off, off + out_cnt[n] - 1 do
            local v = out_dst[j]
            local o = op[v]
            local f = flags[v]
            if (o == SUM or o == CLAMP) and finite then
                pending[v] = pending[v] + in_coef[in_off[v] + out_back[j]] * d
                f = bor(f, CHANGED)
            else
                f = bor(f, CHANGED + FULL)
            end
            flags[v] = f
            if band(f, DIRTY) == 0 then
                touch(v)
            end
        end
    end

    -- process the frontier: at most `budget` work units (a node and its dependents)
    local function mark(budget)
        local work = 0
        while nfront > 0 and work < budget do
            local u = frontier[nfront]
            frontier[nfront] = nil
            nfront = nfront - 1
            local f = flags[u]
            if band(f, FRONTIER) ~= 0 then
                flags[u] = band(f, bnot(FRONTIER))
                if op[u] == INPUT then
                    local d = base[u] - value[u]
                    if d ~= 0 then
                        value[u] = base[u]
                        push(u, d)
                    end
                else
                    local off = out_off[u]
                    for j = off, off + out_cnt[u] - 1 do
                        touch(out_dst[j])
                    end
                end
                work = work + 1 + out_cnt[u]
            end
        end
        return work
    end

    -- computing -----------------------------------------------------------------------------

    local function compute(n)
        local f = flags[n]
        local c = need[n]
        ndirty[c] = ndirty[c] - 1
        if band(f, CHANGED) == 0 then
            flags[n] = band(f, bnot(DIRTY + FULL))
            n_cutoffs = n_cutoffs + 1
            return
        end
        local o = op[n]
        local old = value[n]
        local new
        if (o == SUM or o == CLAMP) and band(f, FULL) == 0 and ndelta[n] < DELTA_LIMIT then
            local a = acc[n] + pending[n]
            acc[n] = a
            pending[n] = 0
            ndelta[n] = ndelta[n] + 1
            if o == SUM then
                new = a
            else
                new = a < lo_v[n] and lo_v[n] or (a > hi_v[n] and hi_v[n] or a)
            end
            n_deltas = n_deltas + 1
        else
            local off = in_off[n]
            local last = off + in_cnt[n] - 1
            if o == SUM or o == CLAMP then
                local a = base[n]
                for k = off, last do
                    a = a + in_coef[k] * value[in_src[k]]
                end
                acc[n] = a
                pending[n] = 0
                ndelta[n] = 0
                if o == SUM then
                    new = a
                else
                    new = a < lo_v[n] and lo_v[n] or (a > hi_v[n] and hi_v[n] or a)
                end
            elseif o == PRODUCT then
                local p = base[n]
                for k = off, last do
                    p = p * (in_coef[k] * value[in_src[k]])
                end
                new = p
            elseif o == MIN then
                local m = base[n]
                for k = off, last do
                    local x = in_coef[k] * value[in_src[k]]
                    if x < m then
                        m = x
                    end
                end
                new = m
            elseif o == MAX then
                local m = base[n]
                for k = off, last do
                    local x = in_coef[k] * value[in_src[k]]
                    if x > m then
                        m = x
                    end
                end
                new = m
            elseif o == FUNC then
                new = funcs[n](g, n)
            else
                new = base[n]
            end
            n_fulls = n_fulls + 1
        end
        flags[n] = band(f, bnot(DIRTY + CHANGED + FULL))
        n_computes = n_computes + 1
        if new ~= old then
            local d = new - old
            if eps > 0 and abs(d) <= eps * (1 + abs(old)) then
                return
            end
            value[n] = new
            n_changes = n_changes + 1
            push(n, d)
        end
    end

    -- compute the dirty inputs of n (all of them are dirty: marking is complete) and n, by level
    local pull_stack, pull_list = {}, {}
    local pull_n = 0
    local function by_level(a, b)
        return level[a] < level[b]
    end
    local function pull(n)
        n_pulls = n_pulls + 1
        epoch = epoch + 1
        if epoch >= 0x7fffffff then
            for i = 0, nn do
                visit[i] = 0
            end
            epoch = 1
        end
        local st, ns = pull_stack, 1
        st[1] = n
        visit[n] = epoch
        local list, nl = pull_list, 0
        while ns > 0 do
            local x = st[ns]
            ns = ns - 1
            nl = nl + 1
            list[nl] = x
            local off = in_off[x]
            for k = off, off + in_cnt[x] - 1 do
                local s = in_src[k]
                if band(flags[s], DIRTY) ~= 0 and visit[s] ~= epoch then
                    visit[s] = epoch
                    ns = ns + 1
                    st[ns] = s
                end
            end
        end
        for i = nl + 1, pull_n do
            list[i] = nil
        end
        pull_n = nl
        if nl > 1 then
            table.sort(list, by_level)
        end
        for i = 1, nl do
            local x = list[i]
            if band(flags[x], DIRTY) ~= 0 then
                compute(x)
            end
        end
    end

    -- compute up to `budget` dirty nodes whose need is `c` or more urgent, lowest level first
    local function run(c, budget)
        if nfront > 0 then
            mark(huge)
        end
        local work = 0
        local l = lo
        while l <= hi and work < budget do
            for k = 1, c do
                local b = bk[k][l]
                if b ~= nil then
                    local m = b.n
                    while m > 0 and work < budget do
                        local x = b[m]
                        b[m] = nil
                        m = m - 1
                        lvl_n[l] = lvl_n[l] - 1
                        work = work + 1
                        if band(flags[x], DIRTY) ~= 0 and level[x] == l and need[x] == k then
                            compute(x)
                        end
                    end
                    b.n = m
                end
            end
            if work >= budget then
                break
            end
            if l == lo and (lvl_n[l] or 0) == 0 then
                lo = l + 1
            end
            l = l + 1
        end
        return work
    end

    -- deadline classes ----------------------------------------------------------------------

    local function set_need(x, c)
        local old = need[x]
        if old ~= c then
            need[x] = c
            if band(flags[x], DIRTY) ~= 0 then
                ndirty[old] = ndirty[old] - 1
                ndirty[c] = ndirty[c] + 1
                enqueue(x)
            end
        end
    end

    -- u's need becomes c or more urgent, and so do its inputs'
    local need_stack = {}
    local function lower_need(u, c)
        if need[u] <= c then
            return
        end
        set_need(u, c)
        local st, ns = need_stack, 1
        st[1] = u
        while ns > 0 do
            local x = st[ns]
            ns = ns - 1
            local off = in_off[x]
            for k = off, off + in_cnt[x] - 1 do
                local s = in_src[k]
                if need[s] > c then
                    set_need(s, c)
                    ns = ns + 1
                    st[ns] = s
                end
            end
        end
    end

    -- recompute u's need from its class and its dependents; when it becomes less urgent, its
    -- inputs' may too
    local refresh_stack = {}
    local function refresh_need(u)
        local st, ns = refresh_stack, 1
        st[1] = u
        while ns > 0 do
            local x = st[ns]
            ns = ns - 1
            if band(flags[x], DEAD) == 0 then
                local c = class[x]
                local off = out_off[x]
                for j = off, off + out_cnt[x] - 1 do
                    local d = need[out_dst[j]]
                    if d < c then
                        c = d
                    end
                end
                local old = need[x]
                if c > old then
                    set_need(x, c)
                    local io = in_off[x]
                    for k = io, io + in_cnt[x] - 1 do
                        ns = ns + 1
                        st[ns] = in_src[k]
                    end
                elseif c < old then
                    lower_need(x, c)
                end
            end
        end
    end

    -- levels --------------------------------------------------------------------------------

    local function set_level(x, l)
        level[x] = l
        if band(flags[x], DIRTY) ~= 0 then
            enqueue(x)
        end
    end

    -- v's level becomes l and its dependents' rise as needed; true if u was reached (u -> v
    -- would close a cycle). Levels stay a valid order either way.
    local level_stack = {}
    local function raise(v, l, u)
        local cycle = false
        set_level(v, l)
        local st, ns = level_stack, 1
        st[1] = v
        while ns > 0 do
            local x = st[ns]
            ns = ns - 1
            if x == u then
                cycle = true
            end
            local lx = level[x]
            local off = out_off[x]
            for j = off, off + out_cnt[x] - 1 do
                local w = out_dst[j]
                if level[w] <= lx then
                    set_level(w, lx + 1)
                    ns = ns + 1
                    st[ns] = w
                end
            end
        end
        return cycle
    end

    -- edges ---------------------------------------------------------------------------------

    -- remove the k-th input of v (and the matching dependent slot of its source)
    local function remove_edge(v, k)
        local io = in_off[v]
        local u = in_src[io + k]
        local j = in_back[io + k]
        local last = in_cnt[v] - 1
        if k ~= last then
            local s, b = in_src[io + last], in_back[io + last]
            in_src[io + k] = s
            in_coef[io + k] = in_coef[io + last]
            in_back[io + k] = b
            out_back[out_off[s] + b] = k
        end
        in_cnt[v] = last
        local oo = out_off[u]
        local olast = out_cnt[u] - 1
        if j ~= olast then
            local w, b = out_dst[oo + olast], out_back[oo + olast]
            out_dst[oo + j] = w
            out_back[oo + j] = b
            in_back[in_off[w] + b] = j
        end
        out_cnt[u] = olast
        nedges = nedges - 1
        return u
    end

    -- the index of the input slot of the edge u -> v, or nil
    local function find_edge(u, v)
        if in_cnt[v] <= out_cnt[u] then
            local off = in_off[v]
            for i = in_cnt[v] - 1, 0, -1 do
                if in_src[off + i] == u then
                    return i
                end
            end
        else
            local off = out_off[u]
            for i = out_cnt[u] - 1, 0, -1 do
                if out_dst[off + i] == v then
                    return out_back[off + i]
                end
            end
        end
        return nil
    end

    local function check_node(n, what)
        if type(n) ~= "number" or n < 1 or n > nn or n % 1 ~= 0 or band(flags[n], DEAD) ~= 0 then
            error(string.format("stellar.graph: %s: no node %s", what, tostring(n)), 3)
        end
    end

    -- public ---------------------------------------------------------------------------------

    -- g:add(op, base, class) -> node
    function g:add(o, b, c)
        if DEFAULT_BASE[o] == nil then
            error("stellar.graph: unknown operation " .. tostring(o), 2)
        end
        c = c or READ
        if c < FRAME or c > READ then
            error("stellar.graph: unknown class " .. tostring(c), 2)
        end
        local n
        if nfree > 0 then
            n = free_ids[nfree]
            free_ids[nfree] = nil
            nfree = nfree - 1
        else
            if nn + 1 > ncap then
                grow_nodes(nn + 1)
            end
            nn = nn + 1
            n = nn
        end
        if b == nil then
            b = DEFAULT_BASE[o]
        end
        op[n] = o
        flags[n] = 0
        class[n] = c
        need[n] = c
        ndelta[n] = 0
        level[n] = 1
        visit[n] = 0
        base[n] = b
        acc[n] = 0
        pending[n] = 0
        lo_v[n] = -huge
        hi_v[n] = huge
        in_off[n] = 0
        in_cnt[n] = 0
        in_cap[n] = 0
        out_off[n] = 0
        out_cnt[n] = 0
        out_cap[n] = 0
        alive = alive + 1
        if o == INPUT then
            value[n] = b
        else
            value[n] = 0
            changed_input(n, b)  -- computed when first needed
        end
        return n
    end

    function g:input(x, c) return g:add(INPUT, x or 0, c) end
    function g:sum(b, c) return g:add(SUM, b, c) end
    function g:product(b, c) return g:add(PRODUCT, b, c) end
    function g:min(b, c) return g:add(MIN, b, c) end
    function g:max(b, c) return g:add(MAX, b, c) end

    function g:clamp(lo_bound, hi_bound, b, c)
        local n = g:add(CLAMP, b, c)
        lo_v[n] = lo_bound or -huge
        hi_v[n] = hi_bound or huge
        return n
    end

    -- f(g, node) -> number; read the inputs with g:in_value(node, k)
    function g:func(f, c)
        local n = g:add(FUNC, 0, c)
        funcs[n] = f
        return n
    end

    -- g:link(u, v, coef): v reads u (with a coefficient, 1 by default)
    function g:link(u, v, coef)
        check_node(u, "link")
        check_node(v, "link")
        coef = coef or 1
        if op[v] == INPUT then
            error("stellar.graph: link: node " .. v .. " is an input", 2)
        end
        if u == v or (level[u] >= level[v] and raise(v, level[u] + 1, u)) then
            error(string.format("stellar.graph: link %d -> %d would make a cycle", u, v), 2)
        end
        in_reserve(v)
        out_reserve(u)
        local k, j = in_cnt[v], out_cnt[u]
        local io, oo = in_off[v] + k, out_off[u] + j
        in_src[io] = u
        in_coef[io] = coef
        in_back[io] = j
        out_dst[oo] = v
        out_back[oo] = k
        in_cnt[v] = k + 1
        out_cnt[u] = j + 1
        nedges = nedges + 1
        if need[v] < need[u] then
            lower_need(u, need[v])
        end
        changed_input(v, coef * value[u])
    end

    -- g:unlink(u, v) -> true if there was an edge u -> v (one of them, if several)
    function g:unlink(u, v)
        check_node(u, "unlink")
        check_node(v, "unlink")
        local k = find_edge(u, v)
        if k == nil then
            return false
        end
        local coef = in_coef[in_off[v] + k]
        remove_edge(v, k)
        changed_input(v, -coef * value[u])
        refresh_need(u)
        return true
    end

    function g:set_coef(u, v, coef)
        check_node(u, "set_coef")
        check_node(v, "set_coef")
        local k = find_edge(u, v)
        if k == nil then
            error(string.format("stellar.graph: set_coef: no edge %d -> %d", u, v), 2)
        end
        local i = in_off[v] + k
        local d = (coef - in_coef[i]) * value[u]
        in_coef[i] = coef
        changed_input(v, d)
    end

    -- set an input: O(1), the change reaches the graph when the frontier is marked
    function g:set(u, x)
        if op[u] ~= INPUT or band(flags[u], DEAD) ~= 0 then
            error("stellar.graph: set: node " .. tostring(u) .. " is not an input", 2)
        end
        base[u] = x
        n_sets = n_sets + 1
        local f = flags[u]
        if band(f, FRONTIER) == 0 and x ~= value[u] then
            flags[u] = bor(f, FRONTIER)
            nfront = nfront + 1
            frontier[nfront] = u
        end
    end

    -- the base of a formula (the constant of a sum, the factor of a product, ...)
    function g:set_base(n, b)
        check_node(n, "set_base")
        if op[n] == INPUT then
            return g:set(n, b)
        end
        local d = b - base[n]
        base[n] = b
        if d ~= 0 or op[n] ~= SUM then
            changed_input(n, d)
        end
    end

    function g:set_clamp(n, lo_bound, hi_bound)
        check_node(n, "set_clamp")
        lo_v[n] = lo_bound or -huge
        hi_v[n] = hi_bound or huge
        flags[n] = bor(flags[n], CHANGED + FULL)
        touch(n)
    end

    function g:set_class(n, c)
        check_node(n, "set_class")
        class[n] = c
        if c < need[n] then
            lower_need(n, c)
        else
            refresh_need(n)
        end
    end

    -- remove a node and its edges (its dependents lose its contribution)
    function g:remove(n)
        check_node(n, "remove")
        while out_cnt[n] > 0 do
            local oo = out_off[n] + out_cnt[n] - 1
            local v, k = out_dst[oo], out_back[oo]
            local coef = in_coef[in_off[v] + k]
            remove_edge(v, k)
            changed_input(v, -coef * value[n])
        end
        while in_cnt[n] > 0 do
            local u = remove_edge(n, in_cnt[n] - 1)
            refresh_need(u)
        end
        if in_cap[n] > 0 then
            release(in_free, in_off[n], in_cap[n])
        end
        if out_cap[n] > 0 then
            release(out_free, out_off[n], out_cap[n])
        end
        in_cap[n], out_cap[n] = 0, 0
        if band(flags[n], DIRTY) ~= 0 then
            ndirty[need[n]] = ndirty[need[n]] - 1
        end
        flags[n] = DEAD
        funcs[n] = nil
        nfree = nfree + 1
        free_ids[nfree] = n
        alive = alive - 1
    end

    -- the exact value of a node (an input: the last value set)
    function g:get(n)
        if op[n] == INPUT then
            return base[n]
        end
        if nfront > 0 then
            mark(huge)
        end
        if band(flags[n], DIRTY) ~= 0 then
            pull(n)
        end
        return value[n]
    end

    -- the cached value, possibly stale
    function g:peek(n) return value[n] end
    function g:is_dirty(n) return band(flags[n], DIRTY) ~= 0 end
    function g:op(n) return op[n] end
    function g:base(n) return base[n] end
    function g:level(n) return level[n] end
    function g:class(n) return class[n] end
    function g:need(n) return need[n] end
    function g:alive(n) return n >= 1 and n <= nn and band(flags[n], DEAD) == 0 end

    -- inputs of a node, k from 0 (for func nodes)
    function g:nin(n) return in_cnt[n] end
    function g:in_node(n, k) return in_src[in_off[n] + k] end
    function g:in_coef(n, k) return in_coef[in_off[n] + k] end
    function g:in_value(n, k) return value[in_src[in_off[n] + k]] end
    function g:nout(n) return out_cnt[n] end
    function g:out_node(n, j) return out_dst[out_off[n] + j] end

    -- mark up to `budget` work units of the frontier; -> work done
    function g:mark(budget) return mark(budget or huge) end

    -- compute up to `budget` nodes needed by class c (or more urgent); -> work done
    function g:run(c, budget) return run(c or READ, budget or huge) end
    function g:flush(c) return run(c or READ, huge) end

    -- the pending invalidations: { frontier, total, dirty = { [class] = n }, lo, hi }
    function g:pending()
        local r = { frontier = nfront, total = 0, dirty = {}, lo = lo, hi = hi }
        for c = 1, NCLASS do
            r.dirty[c] = ndirty[c]
            r.total = r.total + ndirty[c]
        end
        return r
    end

    -- dirty nodes needed by class c or more urgent (marking must be complete for an exact count)
    function g:dirty_count(c)
        local t = 0
        for k = 1, c or NCLASS do
            t = t + ndirty[k]
        end
        return t
    end

    function g:frontier_size() return nfront end

    -- f(node, class, level) for every pending dirty node needed by class c or more urgent, in
    -- the order run would compute them
    function g:each_pending(c, f)
        if nfront > 0 then
            mark(huge)
        end
        for l = lo, hi do
            for k = 1, c or NCLASS do
                local b = bk[k][l]
                if b ~= nil then
                    for i = b.n, 1, -1 do
                        local x = b[i]
                        if band(flags[x], DIRTY) ~= 0 and level[x] == l and need[x] == k then
                            f(x, k, l)
                        end
                    end
                end
            end
        end
    end

    function g:count() return alive, nedges end

    function g:stats()
        return {
            nodes = alive, edges = nedges, capacity = ncap, edge_capacity = icap,
            computes = n_computes, cutoffs = n_cutoffs, deltas = n_deltas, fulls = n_fulls,
            changes = n_changes, sets = n_sets, marked = n_marked, pulls = n_pulls,
            frontier = nfront, levels = hi,
            bytes = (ncap + 1) * (5 + 4 + 4 + 6 * 8 + 6 * 4) + icap * 16 + ocap * 8,
        }
    end

    -- check every invariant (for tests): edges and back-pointers, levels, needs, marking, and
    -- the cached value of every clean node against its formula. -> true or false, message
    function g:check(tolerance)
        tolerance = tolerance or 1e-9
        local nd = { 0, 0, 0, 0, 0 }
        for n = 1, nn do
            if band(flags[n], DEAD) == 0 then
                local io = in_off[n]
                for k = 0, in_cnt[n] - 1 do
                    local s, j = in_src[io + k], in_back[io + k]
                    if band(flags[s], DEAD) ~= 0 then
                        return false, string.format("node %d reads dead node %d", n, s)
                    end
                    if out_dst[out_off[s] + j] ~= n or out_back[out_off[s] + j] ~= k then
                        return false, string.format("edge %d -> %d: bad back-pointer", s, n)
                    end
                    if level[s] >= level[n] then
                        return false, string.format("edge %d -> %d: levels %d >= %d", s, n, level[s], level[n])
                    end
                    if need[s] > need[n] then
                        return false, string.format("edge %d -> %d: need %d > %d", s, n, need[s], need[n])
                    end
                end
                local oo = out_off[n]
                for j = 0, out_cnt[n] - 1 do
                    local v, k = out_dst[oo + j], out_back[oo + j]
                    if in_src[in_off[v] + k] ~= n or in_back[in_off[v] + k] ~= j then
                        return false, string.format("edge %d -> %d: bad dependent slot", n, v)
                    end
                    if nfront == 0 and band(flags[n], DIRTY) ~= 0 and band(flags[v], DIRTY) == 0 then
                        return false, string.format("node %d is dirty, its dependent %d is not", n, v)
                    end
                end
                if need[n] > class[n] then
                    return false, string.format("node %d: need %d > class %d", n, need[n], class[n])
                end
                if band(flags[n], DIRTY) ~= 0 then
                    nd[need[n]] = nd[need[n]] + 1
                elseif op[n] ~= INPUT and op[n] ~= FUNC and nfront == 0 then
                    local o, x = op[n], nil
                    if o == SUM or o == CLAMP then
                        x = base[n]
                        for k = 0, in_cnt[n] - 1 do
                            x = x + in_coef[io + k] * value[in_src[io + k]]
                        end
                        if o == CLAMP then
                            x = math.min(math.max(x, lo_v[n]), hi_v[n])
                        end
                    elseif o == PRODUCT then
                        x = base[n]
                        for k = 0, in_cnt[n] - 1 do
                            x = x * in_coef[io + k] * value[in_src[io + k]]
                        end
                    elseif o == MIN or o == MAX then
                        x = base[n]
                        for k = 0, in_cnt[n] - 1 do
                            local y = in_coef[io + k] * value[in_src[io + k]]
                            if (o == MIN and y < x) or (o == MAX and y > x) then
                                x = y
                            end
                        end
                    end
                    local tol = math.max(tolerance * (1 + abs(x)), eps * (1 + abs(x)) * 4)
                    if x ~= value[n] and not (abs(x - value[n]) <= tol) then
                        return false, string.format("node %d (%s): cached %.17g, formula %.17g", n, M.OP_NAMES[o], value[n], x)
                    end
                end
            end
        end
        for c = 1, NCLASS do
            if nd[c] ~= ndirty[c] then
                return false, string.format("class %d: %d dirty nodes, counted %d", c, nd[c], ndirty[c])
            end
        end
        return true
    end

    -- release the arrays (the graph is unusable afterwards)
    function g:free()
        for _, p in ipairs({ op, flags, class, need, ndelta, level, visit, value, base, acc, pending, lo_v, hi_v,
            in_off, in_cnt, in_cap, out_off, out_cnt, out_cap, in_src, in_coef, in_back, out_dst, out_back }) do
            buffer.free(p)
        end
        op = nil
        nn, alive = 0, 0
    end

    -- free the arrays when the graph is collected
    local sentinel = newproxy(true)
    getmetatable(sentinel).__gc = function()
        if op ~= nil then
            g:free()
        end
    end
    g._sentinel = sentinel

    return g
end

return M
