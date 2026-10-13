-- graph_nodes.lua : the game's modifier nodes rebuilt as the Lua graph (stellar.graph.nodes) from
-- a capture of a live game (stellar.modifier_capture.dump), and checked value by value; then what a
-- change costs in the graph and in the game's node system. Offline.
--
--   luajit tools/graph_nodes.lua <capture.tsv> <modifiers.log>
--
-- 1. reads the capture and modifiers.log (the same session's: type k is line k);
-- 2. builds the tree: a holder per node, parents as links (from the capture's children, or by
--    content in an older capture), the other parts as sources;
-- 3. makes every value the game holds (every (node, type) that can be non-zero) and compares each
--    with the game's, exactly (fixed point);
-- 4. per country: one type changed on the country; the graph's marked and recomputed nodes, against
--    the nodes the game rebuilds (every node below the country, whole).
-- Bounded: a few seconds.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/lua/?.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;" .. package.path

local core = require("stellar.graph.core")
local modifiers = require("stellar.graph.modifiers")
local nodes = require("stellar.graph.nodes")

local clock = os.clock
local t_start = clock()
local function say(fmt, ...)
    io.write(string.format("[%6.2fs] " .. fmt .. "\n", clock() - t_start, ...))
    io.flush()
end

local function read(path)
    local f = io.open(path, "rb")
    if f == nil then
        say("cannot read %s", tostring(path))
        os.exit(1)
    end
    local text = f:read("*a")
    f:close()
    return text
end

local capture_path, log_path = arg and arg[1], arg and arg[2]
if not (capture_path and log_path) then
    say("usage: luajit tools/graph_nodes.lua <capture.tsv> <modifiers.log>")
    os.exit(1)
end

-- 1.
local defs = modifiers.definitions()
local ndefs = defs:read_log(read(log_path))
local snap = nodes.read_capture(read(capture_path))
local nparts, nvalues = 0, 0
for _, n in ipairs(snap.nodes) do
    nparts = nparts + #n.parts
    for _ in pairs(n.values) do
        nvalues = nvalues + 1
    end
end
say("%d definitions; %d nodes, %d values, %d parts; children in the capture: %s", ndefs, #snap.nodes, nvalues, nparts,
    tostring(snap.has_children))

-- 2.
local g = core.new()
local t0 = clock()
local mirror = nodes.build(g, defs, snap)
local st = mirror.stats
say("built in %.0f ms: %d parts as parents, %d own (sources), %d nodes with values and no parts; %d links (%d without a part, %d of them of a kind never seen with a part: the child's categories as their filter; %d stale edges left out); %s",
    (clock() - t0) * 1000, st.parent_parts, st.local_parts, st.unparted, st.edges, st.edges_without_part,
    st.edges_guessed_filter, st.stale_edges, snap.has_children and string.format("%d children not in the registry", st.dead_children)
    or string.format("parents found by content, %d of them among several nodes with the same values", st.ambiguous))
local kinds = {}
for kind, s in pairs(mirror.kinds) do
    local total, list = 0, {}
    for k, c in pairs(s) do
        total = total + c
        list[#list + 1] = string.format("%s x%d", k, c)
    end
    table.sort(list)
    kinds[#kinds + 1] = { kind, total, table.concat(list, ", ") }
end
table.sort(kinds, function(a, b) return a[2] > b[2] end)
for _, k in ipairs(kinds) do
    say("  link %-40s %5d  (filter|mult: %s)", k[1], k[2], k[3])
end

-- 3.
t0 = clock()
local made = mirror:materialize()
local count, edges = g:count()
say("materialized %d values in %.0f ms: the graph has %d nodes and %d edges", made, (clock() - t0) * 1000, count, edges)
t0 = clock()
local report = mirror:compare(snap)
say("compared in %.0f ms:\n%s", (clock() - t0) * 1000, nodes.format_report(report))
t0 = clock()
local reads = 0
for _, n in ipairs(snap.nodes) do
    for name in pairs(n.values) do
        mirror.tree:get(mirror.holders[n.id], name)
        reads = reads + 1
    end
end
local dt = clock() - t0
say("a clean read of every value: %d in %.1f ms (%.0f ns each)", reads, dt * 1000, dt / reads * 1e9)
local ok, msg = g:check()
say("graph invariants: %s", ok and "ok" or msg)

-- 4. one type changed on each country
local function most_common_type(category)
    local counts = {}
    for _, n in ipairs(snap.nodes) do
        if n.category == category then
            for name in pairs(n.values) do
                counts[name] = (counts[name] or 0) + 1
            end
        end
    end
    local best, most = nil, 0
    for name, c in pairs(counts) do
        if c > most then
            best, most = name, c
        end
    end
    return best
end
local ship_type = most_common_type("Ship")
local total_marked, total_computed, total_rebuilt, total_rebuilt_values, countries = 0, 0, 0, 0, 0
local values_of = {}
for _, n in ipairs(snap.nodes) do
    local c = 0
    for _ in pairs(n.values) do
        c = c + 1
    end
    values_of[n.id] = c
end
t0 = clock()
for _, n in ipairs(snap.nodes) do
    if n.category == "Country" then
        local h = mirror.holders[n.id]
        g:flush()
        local before = g:stats()
        mirror.tree:add(h, "test", { [ship_type] = 1000 })
        g:mark(1e9)
        local marked = g:pending().total
        g:flush()
        local computed = g:stats().computes - before.computes
        mirror.tree:remove(h, "test")
        g:flush()
        -- the game: every node below the country rebuilt, every value of it re-added
        local below, values = 0, 0
        local seen = {}
        local function walk(x)
            for child in pairs(x.children) do
                if not seen[child] then
                    seen[child] = true
                    below = below + 1
                    values = values + values_of[child.key]
                    walk(child)
                end
            end
        end
        walk(h)
        total_marked, total_computed = total_marked + marked, total_computed + computed
        total_rebuilt, total_rebuilt_values = total_rebuilt + below + 1, total_rebuilt_values + values + values_of[n.id]
        countries = countries + 1
    end
end
dt = clock() - t0
if countries > 0 then
    say("%s changed on each of %d countries (%.2f ms each, with the undo): the graph marks %.0f nodes and computes %.0f a country; the game rebuilds %.0f nodes, %.0f values",
        ship_type, countries, dt * 1000 / countries, total_marked / countries, total_computed / countries,
        total_rebuilt / countries, total_rebuilt_values / countries)
end
local after = mirror:compare(snap)
say("after the changes and their undo: %d of %d nodes exact", after.exact_nodes, after.nodes)
os.exit((report.exact_nodes == report.nodes and after.exact_nodes == after.nodes) and 0 or 1)
