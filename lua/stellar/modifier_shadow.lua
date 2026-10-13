-- modifier_shadow.lua : the Lua graph of the modifier nodes (stellar.graph.nodes) beside the game's
-- node system, checked against it while the game runs: how the graph does as its replacement
-- (docs/modifier_graph.md, "Shadow mode"). Observation only: the game's nodes are read, never
-- written.
--
-- modifier_graph.txt next to the DLL: "shadow" (default off). At the first tick of a game, every
-- registered node is read (values, parts, children) and the mirror built from them, then checked
-- whole. After every pass of the game's CModifierNodeManager::Update (src/dll/modifier_shadow.cpp
-- hands over the nodes it recomputed):
--
--   1. the recomputed nodes are read again, and their parents (the nodes whose children hold them);
--   2. each is given to the mirror (mirror:assign): a node whose own parts changed is a root of
--      the change; the others the game recomputed only because something above them changed, and
--      the graph has to arrive at their new values by itself;
--   3. the graph's values are compared with the game's: every recomputed node, and a window of the
--      other nodes in turn (shadow.WINDOW a pass): nodes the graph may have changed while the game
--      did not recompute them.
--
-- Counted, and logged every month: passes, nodes recomputed, roots, relinked, new and gone nodes,
-- the graph's marks and computes, values compared and mismatched by category; the first mismatches
-- are logged as they are found.
--
--   local shadow = require("stellar.modifier_shadow")
--   shadow.install(found, game)        -- at startup (init.lua)
--   shadow.report()                    -- the counts so far (dev)

local ffi = require("ffi")
local bit = require("bit")
local stellar = require("stellar")
local capture = require("stellar.modifier_capture")
local core = require("stellar.graph.core")
local nodes = require("stellar.graph.nodes")
local util = require("stellar.util")

local band = bit.band

local shadow = { WINDOW = 400, SAMPLES = 60 }

local S = nil   -- the state once installed

local function new_counts()
    return { passes = 0, recomputed = 0, roots = 0, relinked = 0, new_nodes = 0, gone = 0, graph_only = 0, nodes = 0, values = 0,
        exact = 0, bad_values = 0, by_category = {}, marked = 0, computes = 0, seconds = 0, read_seconds = 0 }
end

local function log(fmt, ...)
    stellar.log(string.format("modifiers: shadow: " .. fmt, ...))
end

-- shadow.install(found, game, index_where) -> true | nil, message: hooks the game's node passes; the
-- mirror is built at the first tick of a game. index_where: where the modifier definitions are
-- (stellar.modifier_index.locate, which init.lua ran before installing the index: once the index
-- has replaced GetTypeFromToken, it cannot be located again)
function shadow.install(found, game, index_where)
    local where, why = capture.locate(found, stellar.read)
    if where == nil then
        return nil, why
    end
    if index_where == nil then
        index_where, why = require("stellar.modifier_index").locate(found, stellar.read)
        if index_where == nil then
            return nil, why
        end
    end
    local ok
    ok, why = stellar.modifier_shadow_hook(where.node_update, where.update)
    if not ok then
        return nil, why
    end
    S = { where = where, index_where = index_where, counts = new_counts(), samples = 0,
        window_at = 0, failed = false }
    stellar.modifier_pass = function(ids, count)
        local ok2, err = pcall(shadow.pass, ids, count)
        if not ok2 then
            S.failed = true
            S.mirror = nil
            log("stopped: %s", tostring(err))
        end
    end
    game.before_tick(function()
        if S.mirror == nil and not S.failed then
            local ok2, err = pcall(shadow.start)
            if not ok2 then
                S.failed = true
                log("not started: %s", tostring(err))
            end
        end
    end)
    game.after_day(function(gamestate)
        if S.mirror ~= nil then
            local _, _, day = game.date(gamestate)
            if day == 1 then
                log("%s, the last month: %s", game.date_string(gamestate), shadow.format(S.counts))
                S.counts = new_counts()
            end
        end
    end)
    return true
end

-- the mirror from every node, checked whole
function shadow.start()
    local t0 = util.now()
    local logs = os.getenv("USERPROFILE") .. "\\Documents\\Paradox Interactive\\Stellaris\\logs"
    local names = capture.type_names(logs .. "\\script_documentation\\modifiers.log")
    local defs, ndefs = capture.definitions(S.index_where, names)
    local snap, why = capture.snapshot(S.where)
    if snap == nil then
        error(why)
    end
    local t_read = util.now()
    local g = core.new()
    local mirror = nodes.build(g, defs, snap)
    local invalid = 0
    for _, n in ipairs(snap.nodes) do
        mirror.holders[n.id].full_id = n.full_id
        if n.invalid then
            invalid = invalid + 1
        end
    end
    local made = mirror:materialize()
    local t_built = util.now()
    local report = nodes.new_report(10)
    for _, n in ipairs(snap.nodes) do
        if not n.invalid then
            mirror:compare_node(n, report)
        end
    end
    local st = mirror.stats
    log("built from %d nodes (%d invalid, not compared), %d types (%s names): %d links (%d without a part, %d stale edges left out), %d own parts; %d values made; read in %.0f ms, built in %.0f ms, compared in %.0f ms",
        #snap.nodes, invalid, ndefs, names and "with" or "without", st.edges, st.edges_without_part, st.stale_edges, st.local_parts, made,
        (t_read - t0) * 1000, (t_built - t_read) * 1000, (util.now() - t_built) * 1000)
    log("the mirror at the start: %s", nodes.format_report(report):gsub("\n", " |"))
    -- the snapshot, with the game's children, for offline checks (tools/graph_nodes.lua)
    local path = logs .. "\\stellarstellaris-modifier-nodes-shadow.tsv"
    local written, why2 = nodes.write_capture(snap, path, defs)
    log("the nodes at the start: %s", written and string.format("%d written to %s", written, path) or tostring(why2))
    S.g, S.defs, S.mirror = g, defs, mirror
    snap = nil
    collectgarbage()
    log("Lua memory after the build: %.0f MB", collectgarbage("count") / 1024)
end

-- the parents of node index `id` as stellar.graph.nodes wants them: { id, category, values } now
local function parent_list(parents_idx, id, registry, count, cache)
    local out = {}
    for _, p in ipairs(parents_idx[id] or {}) do
        local t = cache[p]
        if t == nil then
            local node = capture.node_at(registry, count, p)
            if node ~= nil then
                t = { id = p, category = capture.CATEGORIES[ffi.cast("int32_t *", ffi.cast("uint8_t **", node)[0] + 8)[0]] or "?",
                    values = capture.read_values(node) }
                cache[p] = t
            end
        end
        if t ~= nil then
            out[#out + 1] = t
        end
    end
    return out
end

local function sample(c, text)
    if S.samples < shadow.SAMPLES then
        S.samples = S.samples + 1
        log("mismatch: %s", text)
    end
end

-- after a pass of the game's: ids, a string of count uint32 (the nodes it recomputed)
function shadow.pass(ids, count)
    if S == nil or S.mirror == nil then
        return
    end
    local t0 = util.now()
    local mirror, g = S.mirror, S.g
    local c = S.counts
    c.passes = c.passes + 1
    local registry, rcount = capture.registry(S.where)
    if registry == nil then
        return
    end
    local list = ffi.cast("const uint32_t *", ids)
    local fresh, order = {}, {}
    for i = 0, count - 1 do
        local full = list[i]
        local index = band(full, 0xFFFFF)
        if fresh[index] == nil then
            local node, now = capture.node_at(registry, rcount, index)
            if node ~= nil and now == full then
                fresh[index] = capture.read_node(node, registry, rcount)
                order[#order + 1] = index
            end
        end
    end
    if #order == 0 then
        return
    end
    local parents_idx = capture.children_index(S.where)
    -- a parent never seen (registered without being recomputed since the start): read it too
    for _, index in ipairs(order) do
        for _, p in ipairs(parents_idx[index] or {}) do
            local h = mirror.holders[p]
            local node, full = capture.node_at(registry, rcount, p)
            if fresh[p] == nil and node ~= nil and (h == nil or h.full_id ~= full) then
                fresh[p] = capture.read_node(node, registry, rcount)
                order[#order + 1] = p
            end
        end
    end
    local t_read = util.now()
    c.read_seconds = c.read_seconds + (t_read - t0)
    local before = g:stats()
    -- holders first (so that every link finds its parent), a node replaced at its index: the old one is gone
    for _, index in ipairs(order) do
        local n = fresh[index]
        local h = mirror.holders[index]
        if h ~= nil and h.full_id ~= n.full_id then
            mirror:destroy(index)
            c.gone = c.gone + 1
            h = nil
        end
        if h == nil then
            mirror:holder(n).full_id = n.full_id
            c.new_nodes = c.new_nodes + 1
        end
    end
    local cache = {}
    for _, index in ipairs(order) do
        local n = fresh[index]
        local own_changed, links_changed = mirror:assign(n, parent_list(parents_idx, index, registry, rcount, cache))
        c.recomputed = c.recomputed + 1
        if own_changed then
            c.roots = c.roots + 1
        end
        if links_changed then
            c.relinked = c.relinked + 1
        end
    end
    -- the check: the recomputed nodes, then a window of the others
    mirror:forget_types()
    local report = nodes.new_report(0)
    for _, index in ipairs(order) do
        local n = fresh[index]
        if not n.invalid then
            local bad = mirror:compare_node(n, report)
            if bad > 0 and S.samples < shadow.SAMPLES then
                local r = nodes.new_report(3)
                mirror:compare_node(n, r)
                for _, s in ipairs(r.samples) do
                    sample(c, "recomputed " .. s)
                end
            end
        end
    end
    -- the nodes the graph marked (it expects them to change) that the game did not recompute
    local checked = {}
    g:each_pending(core.READ, function(x)
        local h = mirror.tree.owner[x]
        if h ~= nil and fresh[h.key] == nil and not checked[h.key] then
            checked[h.key] = true
        end
    end)
    for index in pairs(checked) do
        local node, full = capture.node_at(registry, rcount, index)
        local h = mirror.holders[index]
        if node ~= nil and h ~= nil and h.full_id == full and node[0x108] == 0 then
            c.graph_only = c.graph_only + 1
            local n = { id = index, category = h.kind, owner = ffi.cast("int32_t *", node + 0xc)[0],
                values = capture.read_values(node) }
            local bad = mirror:compare_node(n, report)
            if bad > 0 and S.samples < shadow.SAMPLES then
                local r = nodes.new_report(3)
                mirror:compare_node(n, r)
                for _, s in ipairs(r.samples) do
                    sample(c, "marked by the graph, not recomputed by the game: " .. s)
                end
            end
        end
    end
    for _ = 1, shadow.WINDOW do
        S.window_at = (S.window_at + 1) % rcount
        local index = S.window_at
        if fresh[index] == nil and not checked[index] then
            local node, full = capture.node_at(registry, rcount, index)
            local h = mirror.holders[index]
            if node == nil then
                if h ~= nil then
                    mirror:destroy(index)
                    c.gone = c.gone + 1
                end
            elseif h ~= nil and h.full_id == full and node[0x108] == 0 then
                local n = { id = index, category = h.kind, owner = ffi.cast("int32_t *", node + 0xc)[0],
                    values = capture.read_values(node) }
                local bad = mirror:compare_node(n, report)
                if bad > 0 and S.samples < shadow.SAMPLES then
                    local r = nodes.new_report(3)
                    mirror:compare_node(n, r)
                    for _, s in ipairs(r.samples) do
                        sample(c, "not recomputed " .. s)
                    end
                end
            end
        end
    end
    local after = g:stats()
    c.marked = c.marked + (after.marked - before.marked)
    c.computes = c.computes + (after.computes - before.computes)
    c.nodes, c.values, c.exact = c.nodes + report.nodes, c.values + report.values, c.exact + report.exact_nodes
    c.bad_values = c.bad_values + report.wrong + report.missing + report.extra
    for cat, rc in pairs(report.categories) do
        local bad = rc.nodes - rc.exact_nodes
        if bad > 0 then
            c.by_category[cat] = (c.by_category[cat] or 0) + bad
        end
    end
    c.seconds = c.seconds + (util.now() - t0)
end

-- shadow.format(counts) -> text
function shadow.format(c)
    local cats = {}
    for cat, n in pairs(c.by_category) do
        cats[#cats + 1] = string.format("%s %d", cat, n)
    end
    table.sort(cats)
    local cpp = stellar.modifier_shadow_stats and stellar.modifier_shadow_stats() or {}
    return string.format("%d passes with recomputes; %d nodes recomputed by the game (%d roots: own parts changed, %d relinked, %d new, %d gone); graph: %d marked, %d computed, %d nodes it changed that the game did not recompute; checked %d nodes (%d values): %d exact, %d values off%s; %.1f ms in Lua (%.1f reading); game passes %s, deferred %s",
        c.passes, c.recomputed, c.roots, c.relinked, c.new_nodes, c.gone, c.marked, c.computes, c.graph_only, c.nodes, c.values, c.exact,
        c.bad_values, #cats > 0 and (" (" .. table.concat(cats, ", ") .. ")") or "", c.seconds * 1000, c.read_seconds * 1000,
        tostring(cpp.passes), tostring(cpp.deferred))
end

-- shadow.report() -> text: the counts of the month so far
function shadow.report()
    if S == nil then
        return "not installed"
    end
    if S.mirror == nil then
        return S.failed and "stopped" or "waiting for a game"
    end
    return shadow.format(S.counts)
end

return shadow
