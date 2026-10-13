-- engine/modifiers/world.lua : the modifier graph of a world, from the world alone: every node of
-- the world (engine.modifiers.structure), its parents linked with the game's filters, its own parts
-- from a supplier (engine.modifiers computes them; a capture's, to check the structure on its own).
-- Nothing of the game's node system is used: this is the rewrite's modifier system.
--
--   local mw = require("engine.modifiers.world")
--   local wg = mw.build(core.new(), defs, st, function(category, owner) return parts end)
--   wg.tree:get(wg.holder("Fleet", 12), "ship_fire_rate_mult")
--   mw.compare(wg, snap, defs)          -- against a capture of the game's nodes
--
-- defs: the graph's definitions (stellar.graph.modifiers); a part: { name, mult, filter, values }
-- (engine.modifiers.fold folds it).

local gmod = require("stellar.graph.modifiers")
local modifiers = require("engine.modifiers")

local M = {}

local TOLERANCE = 100 -- 0.001 in fixed point

-- the category of a capture's node as the structure names it: a megastructure's Orbital node (its
-- filter -1, where a starbase's has its own) is OrbitalMegaStructure
function M.category_of(n)
    if n.category == "Orbital" and n.categories == -1 then
        return "OrbitalMegaStructure"
    end
    return n.category
end
local category_of = M.category_of

-- mw.build(g, defs, st, parts_of) -> { tree, holders, holder(category, owner), links, stats }
function M.build(g, defs, st, parts_of)
    local tree = gmod.new(g, defs)
    local holders = {}
    local list = st:nodes()
    for _, n in ipairs(list) do
        local key = n.category .. ":" .. n.owner
        if holders[key] == nil then
            holders[key] = tree:holder(n.category, n.owner)
        end
    end
    local stats = { nodes = 0, links = 0, missing_parents = 0, parts = 0 }
    for _, n in ipairs(list) do
        local h = holders[n.category .. ":" .. n.owner]
        if not h.built then
            h.built = true
            stats.nodes = stats.nodes + 1
            for _, l in ipairs(st:parents(n.category, n.owner)) do
                local p = holders[l.category .. ":" .. l.owner]
                if p then
                    tree:link_fixed(h, p, l.mult, l.filter)
                    stats.links = stats.links + 1
                else
                    stats.missing_parents = stats.missing_parents + 1
                end
            end
            for j, part in ipairs(parts_of(n.category, n.owner) or {}) do
                local values = modifiers.fold(part, defs)
                if next(values) ~= nil then
                    tree:add(h, (part.name or "part") .. "#" .. j, values)
                    stats.parts = stats.parts + 1
                end
            end
        end
    end
    local wg = { tree = tree, holders = holders, stats = stats }
    function wg.holder(category, owner)
        return holders[category .. ":" .. owner]
    end
    return wg
end

-- every type a holder can have (its own and its parents' that pass the link), memoized per call
local function types_fn(defs)
    local memo = {}
    local band = require("bit").band
    local function types(h)
        local t = memo[h]
        if t ~= nil then
            return t
        end
        t = {}
        memo[h] = t
        for ty, v in pairs(h.values) do
            if v ~= 0 then
                t[ty] = true
            end
        end
        for _, l in ipairs(h.parents) do
            for ty in pairs(types(l.parent)) do
                if l.mask == gmod.ALL or band(defs.cats[ty] or 0, l.mask) ~= 0 then
                    t[ty] = true
                end
            end
        end
        return t
    end
    return types
end

-- mw.compare(wg, snap, defs, cats) -> { [category] = { nodes, exact, values, close, equal, extra,
-- no_holder, by_type = { [type] = count } } }: every value of every node of the capture against the
-- world's graph (cats: only these categories, nil: all)
function M.compare(wg, snap, defs, cats)
    local out = {}
    local types = types_fn(defs)
    for _, n in ipairs(snap.nodes) do
        if cats == nil or cats[n.category] then
            local c = out[n.category]
            if c == nil then
                c = { nodes = 0, exact = 0, values = 0, close = 0, equal = 0, extra = 0, no_holder = 0, by_type = {} }
                out[n.category] = c
            end
            c.nodes = c.nodes + 1
            local h = wg.holder(category_of(n), n.owner)
            if h == nil then
                c.no_holder = c.no_holder + 1
            else
                local bad = 0
                local seen = {}
                for name, want in pairs(n.values) do
                    local id = defs:id(name)
                    seen[id] = true
                    local got = wg.tree:get(h, id)
                    c.values = c.values + 1
                    if got == want then
                        c.equal = c.equal + 1
                    end
                    if math.abs(got - want) <= TOLERANCE then
                        c.close = c.close + 1
                    else
                        bad = bad + 1
                        c.by_type[name] = (c.by_type[name] or 0) + 1
                    end
                end
                for ty in pairs(types(h)) do
                    if not seen[ty] and math.abs(wg.tree:get(h, ty)) > TOLERANCE then
                        bad = bad + 1
                        c.extra = c.extra + 1
                        local name = defs:name(ty)
                        c.by_type[name] = (c.by_type[name] or 0) + 1
                    end
                end
                if bad == 0 then
                    c.exact = c.exact + 1
                end
            end
        end
    end
    return out
end

-- mw.format(result, title) -> text: per category, the nodes within 0.001, the values within 0.001
-- and equal, the most often differing types
function M.format(result, title)
    local lines = { title }
    local cats = {}
    local total = { nodes = 0, exact = 0, values = 0, close = 0, equal = 0, extra = 0 }
    for cat, c in pairs(result) do
        cats[#cats + 1] = cat
        for k in pairs(total) do
            total[k] = total[k] + c[k]
        end
    end
    table.sort(cats, function(a, b) return result[a].values > result[b].values end)
    for _, cat in ipairs(cats) do
        local c = result[cat]
        local top = {}
        for t, k in pairs(c.by_type) do
            top[#top + 1] = { t, k }
        end
        table.sort(top, function(a, b) return a[2] > b[2] end)
        local tl = {}
        for i = 1, math.min(4, #top) do
            tl[i] = top[i][1] .. " " .. top[i][2]
        end
        lines[#lines + 1] = string.format("  %-26s %6d nodes %6d ok; values %7d: %6.2f%% within 0.001, %6.2f%% equal; %4d only in the graph%s%s",
            cat, c.nodes, c.exact, c.values, 100 * c.close / math.max(c.values, 1), 100 * c.equal / math.max(c.values, 1),
            c.extra, c.no_holder > 0 and string.format("; %d nodes not in the world", c.no_holder) or "",
            #tl > 0 and ("; " .. table.concat(tl, ", ")) or "")
    end
    lines[#lines + 1] = string.format("  %-26s %6d nodes %6d ok; values %7d: %6.2f%% within 0.001, %6.2f%% equal; %4d only in the graph",
        "all", total.nodes, total.exact, total.values, 100 * total.close / math.max(total.values, 1),
        100 * total.equal / math.max(total.values, 1), total.extra)
    return table.concat(lines, "\n")
end

return M
