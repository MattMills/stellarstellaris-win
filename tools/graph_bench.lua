-- graph_bench.lua : a bounded benchmark of stellar.graph on a synthetic late game: countries,
-- fleets, ships and planets with modifiers, read the way tooltips and the simulation read them.
--
--   luajit tools/graph_bench.lua [ships] [types] [ticks]
--
-- Defaults: 10000 ships (1000 fleets, 50 countries, 2000 planets), 20 modifier types read per
-- ship, 200 simulated ticks. Every phase prints its time; the whole run takes seconds. The
-- baseline "rebuild" phase does what the game does on an invalidation (rebuild the whole modifier
-- of every object below the change, every type it holds) for the same change, for comparison.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/lua/?.lua;" .. package.path

local bit = require("bit")
local core = require("stellar.graph.core")
local modifiers = require("stellar.graph.modifiers")
local schedule = require("stellar.graph.schedule")
local util = require("stellar.util")

local NSHIPS = tonumber(arg and arg[1]) or 10000
local NREAD = tonumber(arg and arg[2]) or 20
local NTICKS = tonumber(arg and arg[3]) or 200
local NFLEETS = math.max(1, math.floor(NSHIPS / 10))
local NCOUNTRIES = 50
local NPLANETS = 2000
local NTYPES = 400        -- modifier types in the definitions
local SHIP_TYPES = 120    -- the types that concern ships (the first ones)

if NSHIPS > 200000 then
    error("graph_bench: at most 200000 ships")
end
math.randomseed(7)
local now = util.now

local function phase(name, f)
    collectgarbage("collect")
    local t0 = now()
    local r = f()
    local dt = now() - t0
    io.write(string.format("%-58s %9.3f ms%s\n", name, dt * 1000, r and ("  " .. r) or ""))
    io.flush()
    return dt
end

local g = core.new({ nodes = 4096, edges = 16384 })
local defs = modifiers.definitions()
local SHIPS, COUNTRIES, PLANETS = defs:mask("Ships"), defs:mask("Countries"), defs:mask("Planets")
local tnames = {}
for i = 1, NTYPES do
    tnames[i] = "type_" .. i
    defs:add(tnames[i], i <= SHIP_TYPES and SHIPS or (i % 2 == 0 and COUNTRIES or PLANETS))
end
local tree = modifiers.new(g, defs)

local countries, fleets, ships, planets = {}, {}, {}, {}
local fleet_of, country_of_fleet = {}, {}
local function random_values(k, from, to)
    local v = {}
    for _ = 1, k do
        v[tnames[math.random(from, to)]] = math.random(1, 20) / 100
    end
    return v
end

phase(string.format("build %d countries, %d fleets, %d ships, %d planets", NCOUNTRIES, NFLEETS, NSHIPS, NPLANETS), function()
    for c = 1, NCOUNTRIES do
        countries[c] = tree:holder("country", c)
        for s = 1, 40 do
            tree:add(countries[c], "source" .. s, random_values(4, 1, NTYPES))
        end
    end
    for f = 1, NFLEETS do
        fleets[f] = tree:holder("fleet", f)
        local c = (f - 1) % NCOUNTRIES + 1
        country_of_fleet[f] = c
        tree:link(fleets[f], countries[c])
        tree:add(fleets[f], "leader", random_values(3, 1, SHIP_TYPES))
    end
    for s = 1, NSHIPS do
        ships[s] = tree:holder("ship", s)
        local f = (s - 1) % NFLEETS + 1
        fleet_of[s] = f
        tree:link(ships[s], fleets[f], 1, SHIPS)
        for k = 1, 3 do
            tree:add(ships[s], "component" .. k, random_values(5, 1, SHIP_TYPES))
        end
    end
    for p = 1, NPLANETS do
        planets[p] = tree:holder("planet", p)
        tree:link(planets[p], countries[(p - 1) % NCOUNTRIES + 1], 1, PLANETS)
        tree:add(planets[p], "buildings", random_values(10, SHIP_TYPES + 1, NTYPES))
    end
end)

-- the types each ship's tooltip reads
local reads = {}
for i = 1, NREAD do
    reads[i] = defs:id(tnames[(i * 7) % SHIP_TYPES + 1])
end

phase(string.format("materialize %d types on every ship (first read)", NREAD), function()
    local t = 0
    for s = 1, NSHIPS do
        local h = ships[s]
        for i = 1, NREAD do
            t = t + tree:get(h, reads[i])
        end
    end
    local st = g:stats()
    return string.format("%d nodes, %d edges, %.1f MB arrays, %.1f MB Lua", st.nodes, st.edges, st.bytes / 2 ^ 20,
        collectgarbage("count") / 1024)
end)

local ship_nodes = {}
for s = 1, NSHIPS do
    local ns = {}
    for i = 1, NREAD do
        ns[i] = tree:node(ships[s], reads[i])
    end
    ship_nodes[s] = ns
end

local function read_all()
    local t = 0
    for s = 1, NSHIPS do
        local ns = ship_nodes[s]
        for i = 1, NREAD do
            t = t + g:get(ns[i])
        end
    end
    return t
end

local nreads = NSHIPS * NREAD
local dt = phase(string.format("tooltip reads, all clean (%d reads)", nreads), read_all)
io.write(string.format("    %.1f ns per clean read\n", dt / nreads * 1e9))

-- one country-level change (an edict on one type)
local c1 = countries[1]
local before = g:stats()
phase("country edict on 1 type: add (O(1))", function()
    tree:add(c1, "edict_test", { [tnames[reads[1]]] = 0.25 })
end)
phase("  mark (end of tick)", function()
    g:mark(1e18)
    local p = g:pending()
    return string.format("%d dirty", p.total)
end)
phase("  read every ship's tooltip again (pulls what changed)", read_all)
local after = g:stats()
io.write(string.format("    computes %d, cutoffs %d\n", after.computes - before.computes, after.cutoffs - before.cutoffs))

-- the same change, the game's way: an invalidation rebuilds the whole modifier of every node
-- below it (CModifierNodeBase::Update: clear, then CalculateModifier adds every source and the
-- parent's whole modifier), every type each one holds, for each read of any one of them
phase("baseline: the game's rebuild for the same change (Lua tables)", function()
    local entries, objects = 0, 1
    local cmap = {}
    for t, v in pairs(c1.values) do
        cmap[t] = v
        entries = entries + 1
    end
    for f = 1, NFLEETS do
        if country_of_fleet[f] == 1 then
            local fl = fleets[f]
            local fmap = {}
            for t, v in pairs(cmap) do
                fmap[t] = v
                entries = entries + 1
            end
            for t, v in pairs(fl.values) do
                fmap[t] = (fmap[t] or 0) + v
                entries = entries + 1
            end
            objects = objects + 1
            for child in pairs(fl.children) do
                local smap = {}
                for t, v in pairs(fmap) do
                    if bit.band(defs.cats[t] or 0, SHIPS) ~= 0 then
                        smap[t] = v
                        entries = entries + 1
                    end
                end
                for t, v in pairs(child.values) do
                    smap[t] = (smap[t] or 0) + v
                    entries = entries + 1
                end
                objects = objects + 1
            end
        end
    end
    return string.format("%d modifiers rebuilt, %d entries added", objects, entries)
end)

-- many changes at once: every country changes 5 types
before = g:stats()
phase("every country changes 5 types (sets)", function()
    for c = 1, NCOUNTRIES do
        tree:add(countries[c], "edict_wide", random_values(5, 1, NTYPES))
    end
end)
phase("  mark", function()
    g:mark(1e18)
    return string.format("%d dirty", g:pending().total)
end)
phase("  flush everything", function()
    g:flush()
end)
after = g:stats()
io.write(string.format("    computes %d, deltas %d, fulls %d, cutoffs %d, changes %d\n", after.computes - before.computes,
    after.deltas - before.deltas, after.fulls - before.fulls, after.cutoffs - before.cutoffs, after.changes - before.changes))

-- ship churn: components change on 10% of the ships
phase(string.format("%d ships change a component", math.floor(NSHIPS / 10)), function()
    for s = 1, NSHIPS, 10 do
        tree:add(ships[s], "component1", random_values(5, 1, SHIP_TYPES))
    end
    g:flush()
end)

-- fleet moves: 1% of the ships change fleet
phase(string.format("%d ships change fleet (relink %d types each)", math.floor(NSHIPS / 100), NREAD), function()
    for s = 1, NSHIPS, 100 do
        local f = fleet_of[s]
        local f2 = (f % NFLEETS) + 1
        tree:unlink(ships[s], fleets[f])
        tree:link(ships[s], fleets[f2], 1, SHIPS)
        fleet_of[s] = f2
    end
    g:flush()
end)

local ok, msg = g:check(1e-6)
io.write("invariants: " .. (ok and "ok" or ("FAILED: " .. msg)) .. "\n")
do
    -- spot check against the definition: value = local + parents
    local bad = 0
    for s = 1, NSHIPS, 97 do
        local h = ships[s]
        local f = fleets[fleet_of[s]]
        local c = countries[country_of_fleet[fleet_of[s]]]
        for i = 1, NREAD do
            local t = reads[i]
            local want = (h.values[t] or 0) + (f.values[t] or 0) + (c.values[t] or 0)
            if math.abs(tree:get(h, t) - want) > 1e-9 then
                bad = bad + 1
            end
        end
    end
    io.write(string.format("spot check of ship values: %s\n", bad == 0 and "ok" or (bad .. " wrong")))
end

-- a simulated session: ticks at a game speed, frames at 60 fps, a 2 ms budget per frame; some
-- nodes are needed every tick (the simulation), some monthly (the budget), the open tooltip every
-- frame. Time is simulated (the clock advances by the real time spent computing plus the frame).
do
    local fake = 0
    local function clock()
        return fake + now()
    end
    local s = schedule.new(g, { fps = 60, budget = 0.002, tick = 0.1, clock = clock })
    -- classes: ships of country 1 are read every tick (combat), fleets' values monthly
    for sh = 1, NSHIPS do
        if country_of_fleet[fleet_of[sh]] == 1 then
            g:set_class(ship_nodes[sh][1], core.TICK)
        end
    end
    for f = 1, NFLEETS do
        g:set_class(tree:node(fleets[f], reads[2]), core.MONTH)
    end
    local tooltip = {}
    for sh = 1, math.min(NSHIPS, 200) do  -- an open fleet tooltip: 200 ships, all types
        for i = 1, NREAD do
            tooltip[#tooltip + 1] = ship_nodes[sh][i]
            g:set_class(ship_nodes[sh][i], core.FRAME)
        end
    end
    local frames, max_frame, total_frame = 0, 0, 0
    local frames_per_tick = 6  -- 0.1 s per tick at 60 fps
    local t0 = now()
    for tick = 1, NTICKS do
        -- the tick: the game changes things
        s:before_tick()
        for _ = 1, 3 do
            local c = math.random(NCOUNTRIES)
            tree:add(countries[c], "edict_wide", random_values(5, 1, NTYPES))
        end
        for _ = 1, 20 do
            local sh = math.random(NSHIPS)
            tree:add(ships[sh], "component2", random_values(5, 1, SHIP_TYPES))
        end
        s:after_tick()
        for _ = 1, frames_per_tick do
            local a = now()
            s:frame()
            for _, n in ipairs(tooltip) do  -- the UI reads the tooltip
                g:get(n)
            end
            local ft = now() - a
            frames = frames + 1
            total_frame = total_frame + ft
            if ft > max_frame then
                max_frame = ft
            end
            fake = fake + 1 / 60
        end
    end
    local st = s.stats
    io.write(string.format("simulated %d ticks, %d frames in %.2f s: graph work per frame avg %.3f ms, max %.3f ms\n",
        NTICKS, frames, now() - t0, total_frame / frames * 1000, max_frame * 1000))
    io.write(string.format("    barrier (missed) work %d nodes in %.3f ms total, frames over budget %d, done by class %s\n",
        st.barrier_work, st.barrier_time * 1000, st.over_budget, table.concat(st.done, "/")))
    local ok2, msg2 = g:check(1e-6)
    io.write("invariants after the session: " .. (ok2 and "ok" or ("FAILED: " .. msg2)) .. "\n")
end
