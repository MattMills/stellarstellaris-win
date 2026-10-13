-- graph_test.lua : unit tests of stellar.graph (the dependency graph engine, its scheduler and
-- the modifier and economy layers), offline, without the game.
--
--   luajit tools/graph_test.lua [seed] [rounds]
--
-- The random tests build graphs of a few hundred nodes, change them at random (inputs, edges,
-- coefficients, classes, removals) between partial runs, and compare every value with a naive
-- evaluation from scratch. Bounded: a few seconds.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/lua/?.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;" .. package.path

local core = require("stellar.graph.core")

local seed = tonumber(arg and arg[1]) or 12345
local rounds = tonumber(arg and arg[2]) or 40
math.randomseed(seed)

local failures, passed = 0, 0
local function test(name, f)
    local ok, err = xpcall(f, debug.traceback)
    if ok then
        passed = passed + 1
        io.write(string.format("ok    %s\n", name))
    else
        failures = failures + 1
        io.write(string.format("FAIL  %s\n%s\n", name, tostring(err)))
    end
    io.flush()
end

local function near(a, b, tol)
    tol = tol or 1e-9
    return a == b or math.abs(a - b) <= tol * (1 + math.abs(a) + math.abs(b))
end

local function eq(a, b, what, tol)
    if not near(a, b, tol) then
        error(string.format("%s: expected %.17g, got %.17g", what or "value", b, a), 2)
    end
end

local function ok_check(g)
    local ok, msg = g:check()
    if not ok then
        error("invariant: " .. msg, 2)
    end
end

-- naive evaluation of a node from scratch (funcs: h[node] = function(values) ... end)
local function naive(g, n, memo, h, bounds)
    local v = memo[n]
    if v ~= nil then
        return v
    end
    local o = g:op(n)
    if o == core.INPUT then
        v = g:base(n)
    else
        local xs = {}
        for k = 0, g:nin(n) - 1 do
            xs[#xs + 1] = g:in_coef(n, k) * naive(g, g:in_node(n, k), memo, h, bounds)
        end
        if o == core.SUM or o == core.CLAMP then
            v = g:base(n)
            for _, x in ipairs(xs) do
                v = v + x
            end
            if o == core.CLAMP then
                local b = bounds[n]
                v = math.min(math.max(v, b[1]), b[2])
            end
        elseif o == core.PRODUCT then
            v = g:base(n)
            for _, x in ipairs(xs) do
                v = v * x
            end
        elseif o == core.MIN then
            v = g:base(n)
            for _, x in ipairs(xs) do
                v = math.min(v, x)
            end
        elseif o == core.MAX then
            v = g:base(n)
            for _, x in ipairs(xs) do
                v = math.max(v, x)
            end
        elseif o == core.FUNC then
            local raw = {}
            for k = 0, g:nin(n) - 1 do
                raw[#raw + 1] = naive(g, g:in_node(n, k), memo, h, bounds)
            end
            v = h[n](raw)
        end
    end
    memo[n] = v
    return v
end

-- core ---------------------------------------------------------------------------------------

test("formulas", function()
    local g = core.new({ nodes = 16, edges = 16 })
    local a, b, c = g:input(2), g:input(3), g:input(-4)
    local s = g:sum(1)
    g:link(a, s, 2)
    g:link(b, s)
    eq(g:get(s), 8, "sum")
    local p = g:product(0.5)
    g:link(a, p)
    g:link(b, p, 2)
    eq(g:get(p), 6, "product")
    local mn, mx = g:min(), g:max()
    for _, x in ipairs({ a, b, c }) do
        g:link(x, mn)
        g:link(x, mx)
    end
    eq(g:get(mn), -4, "min")
    eq(g:get(mx), 3, "max")
    local cl = g:clamp(0, 5)
    g:link(s, cl)
    eq(g:get(cl), 5, "clamp")
    local f = g:func(function(gg, n) return gg:in_value(n, 0) ^ 2 + gg:in_value(n, 1) end)
    g:link(a, f)
    g:link(c, f)
    eq(g:get(f), 0, "func")
    g:set(a, 3)
    eq(g:get(s), 10, "sum after set")
    eq(g:get(cl), 5, "clamp after set")
    eq(g:get(f), 5, "func after set")
    eq(g:get(p), 9, "product after set")
    ok_check(g)
end)

test("lazy: nothing computed before it is needed", function()
    local g = core.new()
    local a = g:input(1)
    local s = g:sum()
    g:link(a, s)
    local t = g:sum()
    g:link(s, t, 10)
    eq(g:get(t), 10, "t")
    local before = g:stats().computes
    for i = 1, 100 do
        g:set(a, i)
    end
    eq(g:stats().computes, before, "computes after sets")
    eq(g:frontier_size(), 1, "one input in the frontier")
    g:mark(1e9)
    local p = g:pending()
    eq(p.frontier, 0, "frontier drained")
    eq(p.total, 2, "two dirty nodes")
    eq(g:stats().computes, before, "marking computes nothing")
    eq(g:get(t), 1000, "t")
    eq(g:stats().computes - before, 2, "two computes")
    eq(g:get(t), 1000, "cached")
    eq(g:stats().computes - before, 2, "no compute for a clean read")
    ok_check(g)
end)

test("early cutoff", function()
    local g = core.new()
    local a = g:input(10)
    local cl = g:clamp(0, 5)
    g:link(a, cl)
    local t = g:sum()
    g:link(cl, t)
    local u = g:product(2)
    g:link(t, u)
    eq(g:get(u), 10, "u")
    g:set(a, 20)  -- the clamp absorbs it
    g:mark(1e9)
    eq(g:pending().total, 3, "three marked")
    local s0 = g:stats()
    g:flush()
    local s1 = g:stats()
    eq(s1.computes - s0.computes, 1, "only the clamp is computed")
    eq(s1.cutoffs - s0.cutoffs, 2, "the others are unmarked")
    eq(g:get(u), 10, "u")
    ok_check(g)
end)

test("delta sums: O(1) updates, no drift", function()
    local g = core.new()
    local s = g:sum()
    local ins = {}
    for i = 1, 1000 do
        ins[i] = g:input(i * 0.1)
        g:link(ins[i], s, 1 + (i % 3))
    end
    local function exact()
        local t = 0
        for i = 1, 1000 do
            t = t + (1 + (i % 3)) * g:base(ins[i])
        end
        return t
    end
    eq(g:get(s), exact(), "initial", 1e-12)
    for r = 1, 500 do
        g:set(ins[math.random(1000)], math.random() * 100 - 50)
        if r % 7 == 0 then
            eq(g:get(s), exact(), "after updates", 1e-10)
        end
    end
    eq(g:get(s), exact(), "final", 1e-10)
    local st = g:stats()
    if st.deltas == 0 or st.fulls == 0 then
        error("expected both delta and full computes")
    end
    ok_check(g)
end)

test("edges: link, unlink, set_coef, set_base, remove", function()
    local g = core.new({ nodes = 16, edges = 16 })
    local a, b = g:input(1), g:input(2)
    local s = g:sum(10)
    g:link(a, s, 3)
    g:link(b, s, 4)
    eq(g:get(s), 21, "s")
    g:set_coef(a, s, -1)
    eq(g:get(s), 17, "set_coef")
    g:unlink(b, s)
    eq(g:get(s), 9, "unlink")
    g:set_base(s, 0)
    eq(g:get(s), -1, "set_base")
    g:link(b, s)
    g:link(b, s)  -- twice: counted twice
    eq(g:get(s), 3, "duplicate edge")
    g:unlink(b, s)
    eq(g:get(s), 1, "one duplicate removed")
    g:remove(a)
    eq(g:get(s), 2, "removed input")
    local c = g:input(5)
    g:link(c, s, 2)
    eq(g:get(s), 12, "reused id")
    ok_check(g)
    -- many dependents, removed from the middle
    local hub = g:input(1)
    local deps = {}
    for i = 1, 50 do
        deps[i] = g:sum()
        g:link(hub, deps[i], i)
    end
    for i = 1, 50, 3 do
        g:unlink(hub, deps[i])
    end
    g:set(hub, 2)
    for i = 1, 50 do
        eq(g:get(deps[i]), (i - 1) % 3 == 0 and 0 or 2 * i, "dependent " .. i)
    end
    ok_check(g)
end)

test("cycles are refused", function()
    local g = core.new()
    local a = g:sum()
    local b = g:sum()
    local c = g:sum()
    g:link(a, b)
    g:link(b, c)
    local ok = pcall(g.link, g, c, a)
    if ok then
        error("cycle accepted")
    end
    ok = pcall(g.link, g, a, a)
    if ok then
        error("self loop accepted")
    end
    ok_check(g)
    -- levels after many relinks stay a valid order
    local x = g:input(1)
    g:link(x, a)
    eq(g:get(c), 1, "chain")
    ok_check(g)
end)

test("needs follow classes and edges", function()
    local g = core.new()
    local a = g:input(1)
    local s = g:sum()
    local t = g:sum()
    g:link(a, s)
    g:link(s, t)
    eq(g:need(s), core.READ, "read by default")
    g:set_class(t, core.FRAME)
    eq(g:need(s), core.FRAME, "s needed by a frame node")
    eq(g:need(a), core.FRAME, "a too")
    local u = g:sum(0, core.TICK)
    g:link(s, u)
    eq(g:need(s), core.FRAME, "still frame")
    g:set_class(t, core.READ)
    eq(g:need(s), core.TICK, "relaxed to tick (u)")
    g:unlink(s, u)
    eq(g:need(s), core.READ, "relaxed to read")
    g:get(t)
    g:get(u)
    g:set(a, 5)
    g:set_class(u, core.MONTH)
    g:link(s, u)
    g:set_class(t, core.TICK)
    g:mark(1e9)
    local p = g:pending()
    eq(p.dirty[core.TICK], 2, "s and t by the tick")
    eq(p.dirty[core.MONTH], 1, "u by the month")
    g:run(core.TICK, 1e9)
    eq(g:pending().total, 1, "u left")
    eq(g:peek(t), 5, "t computed")
    eq(g:is_dirty(u) and 1 or 0, 1, "u still dirty")
    eq(g:get(u), 5, "u on read")
    ok_check(g)
end)

test("budgeted runs compute in level order", function()
    local g = core.new()
    local a = g:input(1)
    local prev = a
    local chain = {}
    for i = 1, 200 do
        local s = g:sum(0, core.TICK)
        g:link(prev, s)
        chain[i] = s
        prev = s
    end
    eq(g:get(prev), 1, "chain end")
    g:set(a, 2)
    g:mark(10)  -- partial marking
    if g:frontier_size() == 0 then
        error("expected a partial mark")
    end
    local steps = 0
    while g:pending().total > 0 or g:frontier_size() > 0 do
        g:run(core.TICK, 7)
        steps = steps + 1
        if steps > 1000 then
            error("no progress")
        end
        ok_check(g)
    end
    for i = 1, 200 do
        eq(g:peek(chain[i]), 2, "node " .. i)
    end
end)

test("each_pending lists the invalidations in compute order", function()
    local g = core.new()
    local a = g:input(1)
    local s = g:sum(0, core.TICK)
    local t = g:sum(0, core.MONTH)
    g:link(a, s)
    g:link(s, t)
    g:flush()
    g:set(a, 2)
    local seen = {}
    g:each_pending(core.READ, function(n, c, l)
        seen[#seen + 1] = { n, c, l }
    end)
    eq(#seen, 2, "two pending")
    eq(seen[1][1], s, "s first")
    eq(seen[1][2], core.TICK, "s by the tick")
    eq(seen[2][1], t, "t second")
end)

test("random graphs against a naive evaluation", function()
    for r = 1, rounds do
        local g = core.new({ nodes = 32, edges = 32, epsilon = 0 })
        local h, bounds = {}, {}
        local nodes, inputs = {}, {}
        local function add_random()
            local kind = math.random(10)
            local n
            if kind <= 3 then
                n = g:input(math.random(-5, 5))
                inputs[#inputs + 1] = n
            elseif kind <= 6 then
                n = g:sum(math.random(-3, 3))
            elseif kind == 7 then
                n = g:product(1)
            elseif kind == 8 then
                local lo_b = math.random(-5, 0)
                local hi_b = lo_b + math.random(0, 10)
                n = g:clamp(lo_b, hi_b)
                bounds[n] = { lo_b, hi_b }
            elseif kind == 9 then
                n = math.random(2) == 1 and g:min(100) or g:max(-100)
            else
                n = g:func(function(gg, x)
                    local t = 0
                    for k = 0, gg:nin(x) - 1 do
                        t = t + math.abs(gg:in_value(x, k))
                    end
                    return 0.5 * t + gg:nin(x)
                end)
                h[n] = function(xs)
                    local t = 0
                    for _, v in ipairs(xs) do
                        t = t + math.abs(v)
                    end
                    return 0.5 * t + #xs
                end
            end
            nodes[#nodes + 1] = n
            if math.random(4) == 1 then
                g:set_class(n, math.random(1, 5))
            end
            return n
        end
        for _ = 1, 60 do
            add_random()
        end
        local function random_link()
            local u, v = nodes[math.random(#nodes)], nodes[math.random(#nodes)]
            if g:alive(u) and g:alive(v) and g:op(v) ~= core.INPUT and u ~= v then
                local coef = ({ 1, 1, 2, -1, 0.5 })[math.random(5)]
                if g:op(v) == core.PRODUCT and g:nin(v) >= 3 then
                    return
                end
                pcall(g.link, g, u, v, coef)
            end
        end
        for _ = 1, 120 do
            random_link()
        end
        local function compare(what)
            local memo = {}
            for _, n in ipairs(nodes) do
                if g:alive(n) then
                    local want = naive(g, n, memo, h, bounds)
                    local got = g:get(n)
                    if not near(got, want, 1e-7) then
                        error(string.format("round %d, %s: node %d (%s): got %.17g, want %.17g", r, what, n,
                            core.OP_NAMES[g:op(n)], got, want))
                    end
                end
            end
            ok_check(g)
        end
        compare("initial")
        for step = 1, 80 do
            local what = math.random(12)
            if what <= 4 and #inputs > 0 then
                local u = inputs[math.random(#inputs)]
                if g:alive(u) and g:op(u) == core.INPUT then
                    g:set(u, math.random(-10, 10) + math.random())
                end
            elseif what <= 6 then
                random_link()
            elseif what == 7 then
                local v = nodes[math.random(#nodes)]
                if g:alive(v) and g:nin(v) > 0 then
                    g:unlink(g:in_node(v, math.random(0, g:nin(v) - 1)), v)
                end
            elseif what == 8 then
                local v = nodes[math.random(#nodes)]
                if g:alive(v) and g:nin(v) > 0 then
                    g:set_coef(g:in_node(v, math.random(0, g:nin(v) - 1)), v, math.random(-3, 3))
                end
            elseif what == 9 then
                local v = nodes[math.random(#nodes)]
                if g:alive(v) and g:op(v) ~= core.FUNC then
                    g:set_base(v, math.random(-4, 4))
                end
            elseif what == 10 then
                local v = nodes[math.random(#nodes)]
                if g:alive(v) then
                    g:set_class(v, math.random(1, 5))
                end
            elseif what == 11 then
                local v = nodes[math.random(#nodes)]
                if g:alive(v) and math.random(3) == 1 then
                    g:remove(v)
                    h[v], bounds[v] = nil, nil
                else
                    add_random()
                end
            else
                g:mark(math.random(0, 20))
                g:run(math.random(1, 5), math.random(0, 30))
            end
            if step % 10 == 0 then
                compare("step " .. step)
            end
        end
        compare("end")
        g:free()
    end
end)

-- modifiers -------------------------------------------------------------------------------------

local modifiers = require("stellar.graph.modifiers")
local economy = require("stellar.graph.economy")
local schedule = require("stellar.graph.schedule")

test("modifier tree: sources, links, categories, scale", function()
    local g = core.new()
    local defs = modifiers.definitions()
    local n = defs:read_log(table.concat({
        "[16:33:13][modifier.cpp:2274]: ",
        " == MODIFIER DOCUMENTATION ==",
        "- ship_fire_rate_mult, Category: Ships",
        "- country_unity_produces_mult, Category: Countries",
        "- pop_happiness, Category: Pops",
        "- planet_miners_minerals_produces_mult, Category: AI Economy, Colony",
    }, "\n"))
    eq(n, 4, "definitions read")
    eq(defs:categories("ship_fire_rate_mult"), 16508, "Ships mask")
    eq(defs:categories("planet_miners_minerals_produces_mult"), 16777216 + 1073741824, "two labels")
    local tree = modifiers.new(g, defs)
    local country = tree:holder("country", 1)
    local fleet = tree:holder("fleet", 1)
    local ship = tree:holder("ship", 1)
    tree:link(fleet, country)
    tree:link(ship, fleet, 1, defs:mask("Ships"))
    tree:add(country, "tech", { ship_fire_rate_mult = 0.1, country_unity_produces_mult = 0.2 })
    tree:add(fleet, "admiral", { ship_fire_rate_mult = 0.05 })
    tree:add(ship, "component", { ship_fire_rate_mult = 0.25 })
    eq(g:count(), 0, "no node before a read")
    eq(tree:get(ship, "ship_fire_rate_mult"), 0.4, "ship fire rate")
    eq(g:count(), 3, "three nodes: ship, fleet, country")
    eq(tree:get(ship, "country_unity_produces_mult"), 0, "a country modifier does not reach the ship")
    eq(tree:get(fleet, "country_unity_produces_mult"), 0.2, "it reaches the fleet (mask all)")
    tree:add(country, "tech", { ship_fire_rate_mult = 0.3 })  -- replaces the source
    eq(tree:get(ship, "ship_fire_rate_mult"), 0.6, "replaced source")
    tree:remove(fleet, "admiral")
    eq(tree:get(ship, "ship_fire_rate_mult"), 0.55, "removed source")
    tree:set_scale(ship, fleet, 0.5)
    eq(tree:get(ship, "ship_fire_rate_mult"), 0.4, "scaled parent")
    -- the ship moves to another fleet of another country
    local country2 = tree:holder("country", 2)
    local fleet2 = tree:holder("fleet", 2)
    tree:link(fleet2, country2)
    tree:add(country2, "tech", { ship_fire_rate_mult = 1 })
    tree:unlink(ship, fleet)
    eq(tree:get(ship, "ship_fire_rate_mult"), 0.25, "unlinked")
    tree:link(ship, fleet2, 1, defs:mask("Ships"))
    eq(tree:get(ship, "ship_fire_rate_mult"), 1.25, "relinked")
    tree:destroy(country2)
    eq(tree:get(ship, "ship_fire_rate_mult"), 0.25, "country destroyed")
    ok_check(g)
end)

test("modifier tree: a change marks only its type below it", function()
    local g = core.new()
    local defs = modifiers.definitions()
    local tree = modifiers.new(g, defs)
    local country = tree:holder("country", 1)
    local ships = {}
    for i = 1, 100 do
        local fleet = tree:holder("fleet", i)
        tree:link(fleet, country)
        ships[i] = tree:holder("ship", i)
        tree:link(ships[i], fleet)
        tree:get(ships[i], "a")
        tree:get(ships[i], "b")
    end
    tree:add(country, "edict", { a = 1 })
    g:mark(1e9)
    eq(g:pending().total, 201, "country a, 100 fleets a, 100 ships a")
    eq(tree:get(ships[50], "a"), 1, "ship a")
    eq(tree:get(ships[50], "b"), 0, "ship b untouched")
    ok_check(g)
end)

test("modifier tree: fixed-point links truncate each entry, a pair linked twice", function()
    local g = core.new()
    local defs = modifiers.definitions()
    defs:read_log("- a, Category: Ships\n- b, Category: Countries\n")
    local tree = modifiers.new(g, defs)
    local parent = tree:holder("country", 1)
    local child = tree:holder("pop", 1)
    tree:add(parent, "x", { a = 3, b = -3 })
    tree:link_fixed(child, parent, 50000)          -- half, truncated toward zero
    eq(tree:get(child, "a"), 1, "trunc(1.5)")
    eq(tree:get(child, "b"), -1, "trunc(-1.5)")
    tree:add(parent, "x", { a = 7, b = -7 })
    eq(tree:get(child, "a"), 3, "trunc(3.5) after a change")
    eq(tree:get(child, "b"), -3, "trunc(-3.5) after a change")
    tree:link_fixed(child, parent, 100000, defs:mask("Ships"))  -- the same parent again, ship types only
    eq(tree:get(child, "a"), 10, "both links")
    eq(tree:get(child, "b"), -3, "the second link filters b out")
    tree:unlink(child, parent)
    eq(tree:get(child, "a"), 0, "unlink removes both")
    eq(#child.parents, 0, "no link left")
    ok_check(g)
end)

test("nodes: a capture rebuilt from its parts, with children and by content", function()
    local nodes = require("stellar.graph.nodes")
    local log = "- a, Category: Ships\n- b, Category: Countries\n- c, Category: Pops\n"
    -- a country, two fleets with the same values, a ship in each (same values too), a pop group
    -- reading the country at a third; the ships read their fleets' ship types only
    local rows = {
        "id\tcategory\towner\tinvalid\tvalues\tparts\tchildren\tdepth\tcategories",
        "1\tCountry\t0\t0\ta=100,b=300\t100000|-1|a=100,b=300\t2,4,6\t1\t-1",
        "2\tFleet\t10\t0\ta=100,b=300\t100000|-1|a=100,b=300\t3\t1\t-1",
        "3\tShip\t20\t0\ta=150\t100000|16508|a=100,b=300;100000|-1|a=50\t\t1\t-1",
        "4\tPopGroup\t30\t0\ta=33,b=99,c=-1\t33333|-1|a=100,b=300;50000|-1|c=-3\t\t1\t-1",
        "5\tShip\t21\t0\ta=150\t100000|16508|a=100,b=300;100000|-1|a=50\t\t1\t-1",
        "6\tFleet\t11\t0\ta=100,b=300\t100000|-1|a=100,b=300\t5\t1\t-1",
    }
    for _, children in ipairs({ true, false }) do
        local text = table.concat(rows, "\n")
        if not children then
            text = text:gsub("\t[^\t\n]*\t[^\t\n]*\t[^\t\n]*\n", "\n"):gsub("\t[^\t\n]*\t[^\t\n]*\t[^\t\n]*$", "")
        end
        local snap = nodes.read_capture(text)
        eq(snap.has_children and 1 or 0, children and 1 or 0, "children read")
        local g = core.new()
        local defs = modifiers.definitions()
        defs:read_log(log)
        local mirror = nodes.build(g, defs, snap)
        mirror:materialize()
        local report = mirror:compare(snap)
        if report.exact_nodes ~= 6 then
            error(nodes.format_report(report))
        end
        eq(mirror.stats.local_parts, 4, "the country's, the two ships' own, the pop group's own")
        if children then
            eq(mirror.holders[5].parents[1].parent.key, 6, "ship 5 reads fleet 6 (the children say so)")
            eq(mirror.stats.ambiguous, 0, "nothing guessed")
        else
            eq(mirror.stats.ambiguous > 0 and 1 or 0, 1, "fleets with the same values: a guess")
        end
        -- a technology on the country: both ships, the pop group at a third, truncated
        mirror.tree:add(mirror.holders[1], "tech", { a = 1000 })
        eq(mirror.tree:get(mirror.holders[3], "a"), 1150, "ship 3")
        eq(mirror.tree:get(mirror.holders[5], "a"), 1150, "ship 5")
        eq(mirror.tree:get(mirror.holders[4], "a"), 366, "trunc(1100 * 0.33333)")
        eq(mirror.tree:get(mirror.holders[3], "b"), 0, "the ship's filter keeps b out")
        ok_check(g)
    end
end)

test("nodes: passes of the game given to the mirror (roots, cascades, a relink)", function()
    local nodes = require("stellar.graph.nodes")
    local function capture_text(country_a, ship3_fleet)
        -- what the game holds after recomputing: a technology on the country (country_a), ship 3
        -- in fleet 2 or fleet 6
        local f = country_a
        local rows = {
            "id\tcategory\towner\tinvalid\tvalues\tparts\tchildren\tdepth\tcategories",
            string.format("1\tCountry\t0\t0\ta=%d,b=300\t100000|-1|a=100,b=300%s\t2,4,6\t1\t-1", f,
                f ~= 100 and string.format(";100000|-1|a=%d", f - 100) or ""),
            string.format("2\tFleet\t10\t0\ta=%d,b=300\t100000|-1|a=%d,b=300\t%s\t1\t-1", f, f, ship3_fleet == 2 and "3" or ""),
            string.format("3\tShip\t20\t0\ta=%d\t100000|16508|a=%d,b=300;100000|-1|a=50\t\t1\t-1", f + 50, f),
            string.format("4\tPopGroup\t30\t0\ta=%d,b=99,c=-1\t33333|-1|a=%d,b=300;50000|-1|c=-3\t\t1\t-1",
                nodes.fixed_scale(f, 33333), f),
            string.format("5\tShip\t21\t0\ta=%d\t100000|16508|a=%d,b=300;100000|-1|a=50\t\t1\t-1", f + 50, f),
            string.format("6\tFleet\t11\t0\ta=%d,b=300\t100000|-1|a=%d,b=300\t%s\t1\t-1", f, f, ship3_fleet == 6 and "3,5" or "5"),
        }
        return table.concat(rows, "\n")
    end
    local g = core.new()
    local defs = modifiers.definitions()
    defs:read_log("- a, Category: Ships\n- b, Category: Countries\n- c, Pops\n")
    local mirror = nodes.build(g, defs, nodes.read_capture(capture_text(100, 2)))
    mirror:materialize()
    -- the parents as the shadow reads them after a pass: values only
    local function values_only(all)
        local out = {}
        for child, list in pairs(all) do
            out[child] = {}
            for _, p in ipairs(list) do
                out[child][#out[child] + 1] = { id = p.id, category = p.category, values = p.values }
            end
        end
        return out
    end
    -- pass 1: a technology (+1000 a) on the country; the game recomputes everything below it
    local snap = nodes.read_capture(capture_text(1100, 2))
    local parents = values_only(nodes.parents(snap))
    local roots, relinked = 0, 0
    for _, n in ipairs(snap.nodes) do
        local own, links = mirror:assign(n, parents[n.id] or {})
        roots = roots + (own and 1 or 0)
        relinked = relinked + (links and 1 or 0)
    end
    eq(roots, 1, "one root: the country")
    eq(relinked, 0, "no link changed")
    mirror:forget_types()
    local report = mirror:compare(snap)
    if report.exact_nodes ~= 6 then
        error(nodes.format_report(report))
    end
    -- pass 2: ship 3 moves to fleet 6 (the game recomputes the ship only)
    snap = nodes.read_capture(capture_text(1100, 6))
    parents = values_only(nodes.parents(snap))
    local ship = nil
    for _, n in ipairs(snap.nodes) do
        if n.id == 3 then
            ship = n
        end
    end
    local own, links = mirror:assign(ship, parents[3])
    eq(own and 1 or 0, 0, "the ship's own parts did not change")
    eq(links and 1 or 0, 1, "relinked")
    eq(mirror.holders[3].parents[1].parent.key, 6, "ship 3 reads fleet 6 now")
    mirror:forget_types()
    report = mirror:compare(snap)
    if report.exact_nodes ~= 6 then
        error(nodes.format_report(report))
    end
    ok_check(g)
end)

-- economy -----------------------------------------------------------------------------------------

test("economy: the game's formula", function()
    local g = core.new()
    local defs = modifiers.definitions()
    local tree = modifiers.new(g, defs)
    local cats = economy.categories()
    cats:add("planet_jobs", { add = { produces = true }, mult = { produces = true, upkeep = true } })
    cats:add("planet_miners", { parent = "planet_jobs", add = { produces = true, upkeep = true }, mult = { produces = true },
        triggered = { { table = "produces", key = "miners_gestalt", mult = true, add = true } } })
    local names = cats:generated("planet_miners", { "energy", "minerals" })
    eq(#names, 12, "generated names")
    eq(#cats:chain("planet_miners"), 2, "chain")
    local eco = economy.new(tree, cats, { resources = { "energy", "minerals" } })
    local country = tree:holder("country", 1)
    local colony = tree:holder("colony", 1)
    tree:link(colony, country)
    local miner = eco:unit(colony, { category = "planet_miners", produces = { { values = { minerals = 4 } } },
        upkeep = { { values = { energy = 1 } } } }, 3)  -- 3 bulk units of workforce
    local out = miner.produces.minerals
    eq(g:get(out), 12, "no modifiers")
    tree:add(country, "edict", { planet_miners_produces_mult = 0.1, planet_jobs_minerals_produces_mult = 0.2 })
    eq(g:get(out), 12 * 1.3, "mults of the chain")
    tree:add(colony, "building", { planet_miners_minerals_produces_add = 1 })
    eq(g:get(out), 3 * 5 * 1.3, "own add")
    tree:add(colony, "parent_add", { planet_jobs_minerals_produces_add = 5 })
    eq(g:get(out), 3 * 5 * 1.3, "the parent's add is not used")
    tree:add(country, "malus", { planet_jobs_produces_mult = -3 })
    eq(g:get(out), 3 * 5 * 0.1, "clamped at -0.9")
    tree:remove(country, "malus")
    tree:add(colony, "gestalt", { miners_gestalt_produces_mult = 0.5, miners_gestalt_minerals_produces_add = 2 })
    eq(g:get(out), 3 * 5 * 1.3, "triggered terms off")
    g:set(eco:trigger(colony, "planet_miners", 1), 1)
    eq(g:get(out), 3 * 7 * 1.8, "triggered terms on")
    eco:set_scale(miner, 1)
    eq(g:get(out), 7 * 1.8, "scale")
    eq(g:get(miner.upkeep.energy), 1, "upkeep")
    ok_check(g)
end)

test("economy: triggered resource blocks and totals", function()
    local g = core.new()
    local tree = modifiers.new(g, modifiers.definitions())
    local cats = economy.categories()
    cats:add("planet_farmers", { mult = { produces = true } })
    local eco = economy.new(tree, cats, { resources = { "food" } })
    local colony = tree:holder("colony", 1)
    local swap = g:input(0)
    local farmer = eco:unit(colony, { category = "planet_farmers", produces = {
        { values = { food = 6 } },
        { values = { food = -2 }, trigger = swap },
    } }, 2)
    local total = eco:total(core.MONTH)
    g:link(farmer.produces.food, total)
    eq(g:get(total), 12, "untriggered")
    g:set(swap, 1)
    eq(g:get(total), 8, "triggered block")
    tree:add(colony, "x", { planet_farmers_produces_mult = 0.5 })
    eq(g:get(total), 12, "mult")
    ok_check(g)
end)

-- schedule ----------------------------------------------------------------------------------------

test("schedule: work spread over frames before its deadline", function()
    local g = core.new()
    local t = 0
    local clock = function() return t end
    local s = schedule.new(g, { fps = 10, budget = 0, tick = 1, clock = clock, chunk = 1 })
    -- 100 TICK nodes, 100 MONTH nodes, 10 FRAME nodes, 50 READ nodes behind one input
    local a = g:input(0)
    local tick_nodes, month_nodes, frame_nodes, read_nodes = {}, {}, {}, {}
    local function make(list, k, c)
        for i = 1, k do
            local n = g:sum(0, c)
            g:link(a, n, i)
            list[i] = n
        end
    end
    make(tick_nodes, 100, core.TICK)
    make(month_nodes, 100, core.MONTH)
    make(frame_nodes, 10, core.FRAME)
    make(read_nodes, 50, core.READ)
    g:flush()
    s:after_tick()  -- a tick just ended at t = 0
    g:set(a, 1)
    s:after_tick()
    t = 0
    -- the next tick is 1 s away: 10 frames; each frame takes ~1/10 of the tick work
    local f = s:frame()
    eq(g:pending().dirty[core.FRAME], 0, "frame nodes done in the first frame")
    local left = g:dirty_count(core.TICK)
    if left < 80 or left > 95 then
        error("expected about 90 tick nodes left after one frame, got " .. left)
    end
    for i = 1, 8 do
        t = t + 0.1
        s:frame()
    end
    local before = g:dirty_count(core.TICK)
    t = 0.95
    s:frame()
    eq(g:dirty_count(core.TICK), 0, "tick work done by the last frame (" .. before .. " left before)")
    eq(s:before_tick(), 0, "nothing left for the barrier")
    if g:dirty_count(core.MONTH) == 0 then
        error("month work should still be pending (spread over the month)")
    end
    eq(g:pending().dirty[core.READ], 50, "read nodes never computed")
    eq(g:get(read_nodes[7]), 7, "read node on read")
    ok_check(g)
end)

test("schedule: paused, the barrier, day and month", function()
    local g = core.new()
    local t = 0
    local s = schedule.new(g, { fps = 60, budget = 0, tick = nil, clock = function() return t end })
    local a = g:input(0)
    local tickn, dayn, monthn = g:sum(0, core.TICK), g:sum(0, core.DAY), g:sum(0, core.MONTH)
    g:link(a, tickn)
    g:link(a, dayn)
    g:link(a, monthn)
    g:flush()
    g:set(a, 1)
    s:after_tick()
    s:frame()  -- paused, no budget: nothing
    eq(g:pending().total, 3, "nothing done while paused without budget")
    s:set_date(29, 9)  -- the next tick ends the month
    eq(s:before_tick(), 3, "the barrier does all three")
    s:set_date(0, 0)
    g:set(a, 2)
    s:after_tick()
    eq(s:before_tick(), 1, "a plain tick: the tick node only")
    eq(g:pending().total, 2, "day and month left")
    local p = s:plan()
    eq(p[core.TICK].frames, math.huge, "paused: no tick deadline")
    ok_check(g)
end)

io.write(string.format("\n%d passed, %d failed (seed %d)\n", passed, failures, seed))
os.exit(failures == 0 and 0 or 1)
