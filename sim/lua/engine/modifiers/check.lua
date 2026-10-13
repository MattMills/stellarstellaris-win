-- engine/modifiers/check.lua : the modifier sources (engine.modifiers) against a capture of the
-- game's modifier nodes (stellar.modifier_capture: every node's values and parts, the same moment
-- as the save).
--
-- The graph (stellar.graph.nodes) is built from the capture: a holder per node, its parents linked,
-- its other parts as its own sources. Then, per category, every node's own sources are replaced by
-- the parts engine.modifiers computes from the save and the vanilla files, and every value of the
-- category's nodes is compared with the game's (the parents still the capture's, so a category is
-- measured on its own sources); finally all modelled categories at once.
--
--   local check = require("engine.modifiers.check")
--   print(check.run({ nodes_tsv = path, types_log = path }))
--
-- Per category: nodes exact; values within 0.001 of the game's (and with no own source at all, for
-- reference); own parts matched (a part the game's node has, after its multiplier and filter, found
-- among the computed ones); own values (each node's sum of own parts, per type) matched; the
-- modifier types that differ most often, and the game's parts not found.

local core = require("stellar.graph.core")
local gmod = require("stellar.graph.modifiers")
local nodes = require("stellar.graph.nodes")
local modifiers = require("engine.modifiers")

local M = {}

local TOLERANCE = 100 -- 0.001 in fixed point

local function read(path)
    local f, msg = io.open(path, "rb")
    if not f then
        error("cannot read " .. tostring(path) .. ": " .. tostring(msg))
    end
    local t = f:read("*a")
    f:close()
    return t
end

local function key_of(values)
    local l = {}
    for t, v in pairs(values) do
        if v ~= 0 then
            l[#l + 1] = t .. "=" .. v
        end
    end
    table.sort(l)
    return table.concat(l, ",")
end

local function top(t, n)
    local l = {}
    for k, v in pairs(t) do
        l[#l + 1] = { k, v }
    end
    table.sort(l, function(a, b)
        local x, y = type(a[2]) == "table" and a[2].count or a[2], type(b[2]) == "table" and b[2].count or b[2]
        if x ~= y then
            return x > y
        end
        return a[1] < b[1]
    end)
    local out = {}
    for i = 1, math.min(n, #l) do
        out[i] = l[i]
    end
    return out, #l
end

-- the own sources of a holder, by name (the graph's, folded)
local function own_of(h)
    local out = {}
    for name, stored in pairs(h.sources) do
        out[name] = stored
    end
    return out
end

-- replace a holder's own sources: -> the previous ones
local function replace(tree, h, sources)
    local old = {}
    for name, stored in pairs(h.sources) do
        old[name] = stored
    end
    for name in pairs(old) do
        tree:remove(h, name)
    end
    for name, values in pairs(sources) do
        tree:add(h, name, values)
    end
    return old
end

-- compare the nodes of the given categories (nil: all) -> { [category] = counts }
local function compare(mirror, snap, cats, defs, detail)
    local out = {}
    mirror:forget_types()
    for _, n in ipairs(snap.nodes) do
        if cats == nil or cats[n.category] then
            local c = out[n.category]
            if c == nil then
                c = { nodes = 0, exact = 0, values = 0, close = 0, extra = 0, by_type = {} }
                out[n.category] = c
            end
            c.nodes = c.nodes + 1
            local h = mirror.holders[n.id]
            local bad = 0
            local seen = {}
            for name, want in pairs(n.values) do
                local id = defs:id(name)
                seen[id] = true
                local got = mirror.tree:get(h, id)
                c.values = c.values + 1
                if math.abs(got - want) <= TOLERANCE then
                    c.close = c.close + 1
                end
                if got ~= want then
                    bad = bad + 1
                    if detail then
                        c.by_type[name] = (c.by_type[name] or 0) + 1
                    end
                end
            end
            for ty in pairs(mirror.types(h)) do
                if not seen[ty] then
                    local got = mirror.tree:get(h, ty)
                    if got ~= 0 then
                        bad = bad + 1
                        c.extra = c.extra + 1
                        if detail then
                            local name = defs:name(ty)
                            c.by_type[name] = (c.by_type[name] or 0) + 1
                        end
                    end
                end
            end
            if bad == 0 then
                c.exact = c.exact + 1
            end
        end
    end
    return out
end

-- check.run(opts) -> report text. opts: nodes_tsv, types_log (the capture and its modifiers.log;
-- without one, the types are made from engine.defs: stellar.graph.modifier_types),
-- categories (default engine.modifiers.CATEGORIES), src (engine.modifiers sources, default made
-- from engine.defs and engine.world, which must be loaded), samples (lines of detail per category)
function M.run(opts)
    local clock = RUST and RUST.clock or os.clock
    local t0 = clock()
    local lines = {}
    local function p(...)
        lines[#lines + 1] = string.format(...)
    end
    local defs = gmod.definitions()
    if opts.types_log then
        defs:read_log(read(opts.types_log))
    else
        defs:read_game(require("engine.defs").folder)
    end
    local snap = nodes.read_capture(read(opts.nodes_tsv))
    local mirror = nodes.build(core.new(), defs, snap)
    mirror:materialize()
    -- the megastructures' Orbital nodes, OrbitalMegaStructure (their ids are also starbases')
    require("engine.modifiers.world").mark_megastructures(snap, require("engine.world"))
    p("capture: %d nodes; graph built in %.1f s", #snap.nodes, clock() - t0)
    local src = opts.src or modifiers.new({ types = defs, game_dir = opts.game_dir, fs = opts.fs })
    local cats = opts.categories or modifiers.CATEGORIES
    local nsamples = opts.samples or 12

    -- a multiplier that is another modifier's value (`mult = modifier:x`, `planet.modifier:x`, a
    -- job's output modifier), read from the graph as the capture has it, on the node S:ref_node
    -- names
    local node_of = {}
    for _, n in ipairs(snap.nodes) do
        node_of[n.category .. ":" .. tostring(n.owner)] = n.id
    end
    src.resolve_ref = function(ref)
        local cat, owner = src:ref_node(ref)
        local id = cat and owner ~= nil and node_of[cat .. ":" .. tostring(owner)]
        if not id then
            return nil
        end
        return mirror.tree:get(mirror.holders[id], ref.type)
    end

    -- every node's parts, computed
    local computed, by_cat = {}, {}
    local t1 = clock()
    for _, n in ipairs(snap.nodes) do
        for _, cat in ipairs(cats) do
            if n.category == cat then
                local parts = src:parts(cat, n.owner) or {}
                computed[n.id] = parts
                local l = by_cat[cat] or {}
                by_cat[cat] = l
                l[#l + 1] = n
            end
        end
    end
    p("sources computed in %.2f s (%d values not resolved; definitions not found: %d kinds)", clock() - t1,
        src.stats.unresolved, select(2, top(src.stats.missing, 0)))
    local summary = {}
    for _, cat in ipairs(cats) do
        local list = by_cat[cat] or {}
        local tree = mirror.tree
        -- own parts: the game's (the holder's sources, folded) and the computed ones (folded)
        local game_parts, mine_parts, matched = 0, 0, 0
        local own_types, own_close = 0, 0
        local missing_by_type, missing_parts, extra_parts, extra_by_name = {}, {}, {}, {}
        local saved = {}
        local zero_parts = 0
        for _, n in ipairs(list) do
            local h = mirror.holders[n.id]
            local game = own_of(h)
            local mine = {}
            local count = {}
            local names = {}
            for i, part in ipairs(computed[n.id]) do
                local v = modifiers.fold(part, defs)
                if next(v) then
                    local name = part.name .. "#" .. i
                    mine[name] = v
                    local k = key_of(v)
                    count[k] = (count[k] or 0) + 1
                    names[k] = part.name
                    mine_parts = mine_parts + 1
                end
            end
            local gsum, msum = {}, {}
            for _, stored in pairs(game) do
                local named = {}
                for t, v in pairs(stored) do
                    named[defs:name(t)] = v
                    gsum[defs:name(t)] = (gsum[defs:name(t)] or 0) + v
                end
                local k = key_of(named)
                if k == "" then
                    zero_parts = zero_parts + 1
                else
                    game_parts = game_parts + 1
                    if (count[k] or 0) > 0 then
                        count[k] = count[k] - 1
                        matched = matched + 1
                    else
                        local first = k:match("^([^=]+)") or "?"
                        local e = missing_parts[k] or { count = 0, node = n.id }
                        missing_parts[k] = e
                        e.count = e.count + 1
                    end
                end
            end
            for k, c in pairs(count) do
                if c > 0 then
                    local nm = names[k]:gsub(":.*", "")
                    extra_by_name[nm] = (extra_by_name[nm] or 0) + c
                    local e = extra_parts[names[k]] or { count = 0 }
                    extra_parts[names[k]] = e
                    e.count = e.count + c
                end
            end
            for _, v in pairs(mine) do
                for t, x in pairs(v) do
                    msum[t] = (msum[t] or 0) + x
                end
            end
            local all = {}
            for t in pairs(gsum) do all[t] = true end
            for t in pairs(msum) do all[t] = true end
            for t in pairs(all) do
                local a, b = gsum[t] or 0, msum[t] or 0
                if a ~= 0 or b ~= 0 then
                    own_types = own_types + 1
                    if math.abs(a - b) <= TOLERANCE then
                        own_close = own_close + 1
                    else
                        local e = missing_by_type[t] or { count = 0, game = a, mine = b, node = n.owner }
                        missing_by_type[t] = e
                        e.count = e.count + 1
                    end
                end
            end
            saved[n.id] = { game = game, mine = mine }
            if opts.show and opts.show[cat .. ":" .. tostring(n.owner)] then
                p("  node %d (%s %s): the game's own parts:", n.id, cat, tostring(n.owner))
                for _, stored in pairs(game) do
                    local named = {}
                    for t, v in pairs(stored) do
                        named[defs:name(t)] = v
                    end
                    p("    %s", key_of(named))
                end
                p("  computed:")
                for name, v in pairs(mine) do
                    p("    %-40s %s", name, key_of(v))
                end
            end
        end
        -- the category's values with no own source, then with the computed ones
        local only = { [cat] = true }
        for _, n in ipairs(list) do
            replace(tree, mirror.holders[n.id], {})
        end
        local none = compare(mirror, snap, only, defs)[cat] or {}
        for _, n in ipairs(list) do
            replace(tree, mirror.holders[n.id], saved[n.id].mine)
        end
        local got = compare(mirror, snap, only, defs, true)[cat] or { nodes = 0, exact = 0, values = 0, close = 0, extra = 0, by_type = {} }
        for _, n in ipairs(list) do
            replace(tree, mirror.holders[n.id], saved[n.id].game)
        end
        local function pct(a, b)
            return b > 0 and 100 * a / b or 100
        end
        summary[#summary + 1] = { cat = cat, got = got, none = none, game_parts = game_parts, matched = matched,
            own_types = own_types, own_close = own_close, saved = saved }
        p("")
        p("%s: %d nodes, %d exact (%.1f%%); values %d of %d within 0.001 (%.1f%%; %.1f%% with no own source), %d only in the graph",
            cat, got.nodes, got.exact, pct(got.exact, got.nodes), got.close, got.values, pct(got.close, got.values),
            pct(none.close or 0, none.values or 0), got.extra)
        p("  own parts: %d of the game's %d matched (%.1f%%; %d computed; %d of the game's add nothing); own values %d of %d types matched (%.1f%%)",
            matched, game_parts, pct(matched, game_parts), mine_parts, zero_parts, own_close, own_types, pct(own_close, own_types))
        local l, nt = top(missing_by_type, 25)
        p("  own values that differ, by type (%d types; nodes, last game / computed, node owner):", nt)
        for i = 1, math.min(nsamples * 2, #l) do
            local x = l[i]
            p("    %5d  %-56s game %d, computed %d (owner %s)", x[2].count, x[1], x[2].game, x[2].mine, tostring(x[2].node))
        end
        l, nt = top(missing_parts, nsamples)
        p("  the game's parts not computed (%d kinds; count, values):", nt)
        for _, x in ipairs(l) do
            p("    %5d  %s", x[2].count, x[1]:sub(1, 220))
        end
        l, nt = top(extra_parts, nsamples)
        p("  computed parts not in the game's (%d sources):", nt)
        for _, x in ipairs(l) do
            p("    %5d  %s", x[2].count, x[1])
        end
    end

    -- all the categories at once
    local list_all = {}
    for _, s in ipairs(summary) do
        for id, v in pairs(s.saved) do
            replace(mirror.tree, mirror.holders[id], v.mine)
        end
        list_all[s.cat] = true
    end
    local all = compare(mirror, snap, list_all, defs, true)
    p("")
    p("all modelled categories at once (the parents' sources computed too):")
    for _, s in ipairs(summary) do
        local c = all[s.cat] or { nodes = 0, exact = 0, values = 0, close = 0, by_type = {} }
        local l = top(c.by_type, 6)
        local o = {}
        for _, x in ipairs(l) do
            o[#o + 1] = x[1] .. " " .. x[2]
        end
        p("  %-10s %6d nodes %6d exact; values %7d of %7d within 0.001 (%.1f%%); most often differing: %s", s.cat, c.nodes,
            c.exact, c.close, c.values, c.values > 0 and 100 * c.close / c.values or 100, table.concat(o, ", "))
    end
    for _, s in ipairs(summary) do
        for id, v in pairs(s.saved) do
            replace(mirror.tree, mirror.holders[id], v.game)
        end
    end
    local function list(t, n)
        local l, nt = top(t, n)
        local o = {}
        for _, x in ipairs(l) do
            o[#o + 1] = x[1] .. " x" .. x[2]
        end
        return nt, table.concat(o, ", ")
    end
    p("definitions not found (%d): %s", list(src.stats.missing, 10))
    p("keys read that are neither types nor known groups (%d): %s", list(src.stats.unknown, 15))
    p("triggers evaluated: %d, %d true, %d failed to evaluate", src.stats.triggers, src.stats.triggers_true, src.stats.trigger_errors)
    if src.eval then
        local miss = {}
        for k, m in pairs(src.eval.stats.missing) do
            miss[k] = m.count
        end
        p("  what the script layer does not answer yet, as these triggers read it (%d kinds): %s", list(miss, 20))
        if E and E.stats and E.stats.unread then
            p("  reads the interface does not answer from the save (%d kinds): %s", list(E.stats.unread, 25))
        end
    end
    p("done in %.1f s", clock() - t0)
    return table.concat(lines, "\n"), summary
end

return M
