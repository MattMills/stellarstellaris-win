-- graph/nodes.lua : the game's modifier nodes, every one of them, as a stellar.graph.modifiers
-- tree: the Lua graph in place of the game's node system (docs/modifiers.md, "Per-object modifier
-- nodes"; docs/modifier_graph.md).
--
-- Every object with modifiers has a node (NModifierNode::CModifierNode) whose value set is the sum
-- of its parts (CModifier::_Added): each part a whole value set added with a multiplier (fixed
-- point, 1.0 = 100000, each entry truncated toward zero) and a category filter (a type passes when
-- its categories meet the filter; 0 and -1 pass everything). A part is a parent node
-- (AddModifierNode: a clone of the parent's values) or one of the node's own sources (static,
-- timed and triggered modifiers, traits, technologies, a ship's components, ...). Here a node is a
-- holder, its parents are links and its own parts are local sources:
--
--     value(H, T) = own(H, T) + sum over the links P -> H: trunc(mult * value(P, T)), T passes
--
-- so every value the game holds is a node of the graph: a change marks the types it changes,
-- below the holder it changes, where the game rebuilds every node below it, whole.
--
-- A snapshot of the game's nodes (stellar.modifier_capture: read in the game, or a capture file):
--
--   { nodes = { { id =, category =, owner =, values = { [type] = v }, parts = { { mult =,
--     filter =, values = { [type] = v } }, ... }, children = { id, ... } or nil }, ... } }
--
-- values in raw fixed point, types by name; children are the ids of the nodes that read the node
-- (_ChildNodes, registered by AddModifierNode). With children, each parent is matched to the part
-- that is its clone, and the parents that added nothing are linked too. Without them (an older
-- capture) a part equal to the values of a node of a category it reads (M.READS) is taken for that
-- node: right for every value, but where several nodes have the same values the choice is a guess.
--
--   local nodes = require("stellar.graph.nodes")
--   local snap = nodes.read_capture(text)
--   local mirror = nodes.build(core.new(), defs, snap)
--   local report = mirror:compare(snap)     -- every value of every node against the game's
--   nodes.format_report(report)

local bit = require("bit")
local modifiers = require("stellar.graph.modifiers")

local band = bit.band
local fmod = math.fmod

local M = {}

-- EModifierNodeCategory (4.5.2 PDB), as stellar.modifier_capture names them
M.CATEGORIES = {
    [0] = "CountryRelayNetwork", "Country", "GalacticObjectTimed", "GalacticObjectLeader",
    "GalacticObjectCosmicStorm", "GalacticObjectPsionicAura", "GalacticObjectPopJob", "GalacticObjectBuilding",
    "LeaderSkill", "Federation", "GalacticCommunity", "EspionageOperation", "Sector", "SpyNetwork", "Orbital",
    "CosmicStorm", "Planet", "Colony", "AstralRift", "Leader", "MegaStructure", "MegaStructureSystem", "PopGroup",
    "Fleet", "StarbaseExternal", "StarbaseCountry", "StarbaseSystem", "StarbasePlanet", "StarbaseDefensePlatform",
    "Starbase", "Army", "Ship", "WaystationNetworkSystem", "WaystationNetworkCountry",
}

-- The categories each category reads: the declared dependencies of each node type (the
-- SDependencies of CModifierNode<...>, docs/modifiers.md). The PDB names of Colony, PopGroup and
-- Army are truncated; their lists are completed with the parents the 2210 capture shows them
-- reading by content with a filter of their own (PopGroup <- Country: Habitability). Only used
-- without the children of a capture.
M.READS = {
    Country = { "Federation", "StarbaseCountry", "WaystationNetworkCountry" },
    EspionageOperation = { "SpyNetwork" },
    SpyNetwork = { "Country", "LeaderSkill" },
    Planet = { "GalacticObjectLeader", "Sector", "StarbaseSystem", "CountryRelayNetwork", "GalacticObjectCosmicStorm",
        "GalacticObjectPsionicAura", "Country", "StarbasePlanet", "MegaStructureSystem" },
    Colony = { "Planet", "Ship" },
    AstralRift = { "Country" },
    Leader = { "Country" },
    MegaStructure = { "LeaderSkill", "Country" },
    PopGroup = { "Colony", "Country" },
    Fleet = { "GalacticObjectTimed", "GalacticObjectLeader", "Sector", "Orbital", "LeaderSkill", "Country",
        "GalacticObjectPsionicAura", "GalacticObjectCosmicStorm", "Starbase", "StarbaseSystem", "MegaStructureSystem" },
    Starbase = { "GalacticObjectLeader", "Sector", "StarbaseExternal", "GalacticObjectCosmicStorm",
        "GalacticObjectPsionicAura", "Country", "CountryRelayNetwork", "WaystationNetworkSystem" },
    Army = { "LeaderSkill", "Country", "Colony", "Ship" },
    Ship = { "Fleet", "StarbaseDefensePlatform", "StarbasePlanet" },
}

local function passes(defs, t, filter)
    if filter == 0 or filter == -1 then
        return true
    end
    return band(defs:categories(t), filter) ~= 0
end

-- the game's addition of an entry with a multiplier: value * mult / 100000, truncated toward zero
local function fixed_scale(x, mult)
    if mult == 100000 then
        return x
    end
    local p = x * mult
    return (p - fmod(p, 100000)) / 100000
end
M.fixed_scale = fixed_scale

-- a canonical text of a value set: what a part and the node it is a clone of share
local function key_of(values)
    local list = {}
    for t, v in pairs(values) do
        list[#list + 1] = string.format("%s=%d", t, v)
    end
    table.sort(list)
    return table.concat(list, ",")
end
M.key_of = key_of

-- reading a capture file ------------------------------------------------------------------------

local function parse_values(s)
    local map = {}
    if s ~= nil and s ~= "" then
        for k, v in s:gmatch("([^,=]+)=(-?%d+)") do
            map[k] = (map[k] or 0) + tonumber(v)
        end
    end
    return map
end

-- nodes.read_capture(text) -> snapshot: a stellar.modifier_capture.dump file (id, category, owner,
-- invalid, values, parts, and children when the capture has them)
function M.read_capture(text)
    local snap = { nodes = {}, has_children = false }
    local first = true
    for line in text:gmatch("[^\n]+") do
        if first then
            first = false
        else
            local cols = {}
            for field in (line:gsub("\r$", "") .. "\t"):gmatch("([^\t]*)\t") do
                cols[#cols + 1] = field
            end
            local id = tonumber(cols[1])
            if id ~= nil then
                local n = { id = id, category = cols[2], owner = tonumber(cols[3]), invalid = cols[4] ~= "0",
                    values = parse_values(cols[5]), parts = {} }
                if cols[6] ~= nil and cols[6] ~= "" then
                    for p in cols[6]:gmatch("[^;]+") do
                        local mult, filter, pv = p:match("^(-?%d+)|(-?%d+)|(.*)$")
                        if mult then
                            n.parts[#n.parts + 1] = { mult = tonumber(mult), filter = tonumber(filter), values = parse_values(pv) }
                        end
                    end
                end
                if cols[7] ~= nil then
                    snap.has_children = true
                    n.children = {}
                    for c in cols[7]:gmatch("%d+") do
                        n.children[#n.children + 1] = tonumber(c)
                    end
                    n.depth, n.categories = tonumber(cols[8]), tonumber(cols[9])
                end
                snap.nodes[#snap.nodes + 1] = n
            end
        end
    end
    return snap
end

-- nodes.write_capture(snap, path, defs) -> nodes written | nil, message: a snapshot in the format
-- of stellar.modifier_capture.dump (nodes.read_capture reads it back); types by their names in defs
function M.write_capture(snap, path, defs)
    local f = io.open(path, "w")
    if f == nil then
        return nil, "cannot write " .. tostring(path)
    end
    local function text(values)
        local list = {}
        for t, v in pairs(values) do
            list[#list + 1] = string.format("%s=%d", defs and defs:name(t) or tostring(t), v)
        end
        return table.concat(list, ",")
    end
    f:write("id\tcategory\towner\tinvalid\tvalues\tparts\tchildren\tdepth\tcategories\n")
    for _, n in ipairs(snap.nodes) do
        local parts = {}
        for _, p in ipairs(n.parts) do
            parts[#parts + 1] = string.format("%d|%d|%s", p.mult, p.filter, text(p.values))
        end
        f:write(string.format("%d\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\n", n.id, n.category, n.owner or 0, n.invalid and 1 or 0,
            text(n.values), table.concat(parts, ";"), table.concat(n.children or {}, ","), n.depth or 0, n.categories or -1))
    end
    f:close()
    return #snap.nodes
end

-- the tree ----------------------------------------------------------------------------------------

local function reads_table()
    local reads = {}
    for cat, list in pairs(M.READS) do
        reads[cat] = {}
        for _, p in ipairs(list) do
            reads[cat][p] = true
        end
    end
    return reads
end

-- the content keys of a node and its parts (a parent read for matching has values only)
local function prepare(n)
    if n.key == nil then
        n.key = key_of(n.values)
        for _, p in ipairs(n.parts or {}) do
            p.key = key_of(p.values)
        end
    end
end

-- nodes.parts_key(n) -> the text of a node as read: its parts (multiplier, filter, content) and
-- values. Two reads of a node give the same text unless the game rebuilt it in between.
function M.parts_key(n)
    prepare(n)
    local list = {}
    for _, p in ipairs(n.parts or {}) do
        list[#list + 1] = string.format("%d|%d|%s", p.mult, p.filter, p.key)
    end
    table.sort(list)
    return table.concat(list, ";") .. "#" .. n.key
end

-- nodes.new(g, defs) -> mirror: an empty tree of the game's nodes; nodes.build fills it from a
-- snapshot, mirror:assign keeps a node up to date from a fresh read of it
function M.new(g, defs)
    local tree = modifiers.new(g, defs)
    local mirror = { g = g, defs = defs, tree = tree, holders = {}, kinds = {}, index = nil, stats = {
        nodes = 0, parts = 0, parent_parts = 0, local_parts = 0, unparted = 0, edges = 0, edges_without_part = 0,
        edges_guessed_filter = 0, dead_children = 0, by_content = 0, ambiguous = 0, stale_edges = 0,
    } }
    local st = mirror.stats
    local reads = reads_table()

    -- the holder of a node (made if new)
    function mirror:holder(n)
        local h = self.holders[n.id]
        if h == nil then
            h = tree:holder(n.category, n.id)
            self.holders[n.id] = h
        end
        return h
    end

    -- a holder and its links removed (a node unregistered: its object is gone). Its children lose
    -- their link to it: their next assign links them again, whatever their parents are then (a
    -- new node at the same index has the same id).
    function mirror:destroy(id)
        local h = self.holders[id]
        if h ~= nil then
            for child in pairs(h.children) do
                child.links_key = nil
            end
            tree:destroy(h)
            self.holders[id] = nil
        end
    end

    -- the links seen, by kind (child category < parent category): filter|mult -> count; a link whose
    -- parent added nothing (no part to read them from) takes the kind's most common
    local function learn(child, parent, mult, filter)
        local kind = child.category .. "<" .. parent.category
        local s = mirror.kinds[kind]
        if s == nil then
            s = {}
            mirror.kinds[kind] = s
        end
        local k = filter .. "|" .. mult
        s[k] = (s[k] or 0) + 1
    end
    local function learned(child, parent)
        local best, most = nil, 0
        for k, c in pairs(mirror.kinds[child.category .. "<" .. parent.category] or {}) do
            if c > most then
                best, most = k, c
            end
        end
        if best == nil then
            -- a kind never seen with a part: most AddModifierNode calls pass no mask, and the
            -- part's filter is then the child's own category filter (_Categories; in the 2210
            -- capture 17 of the 22 kinds that have parts); the others are learned from their parts
            return child.categories or -1, 100000, false
        end
        local filter, mult = best:match("^(-?%d+)|(-?%d+)$")
        return tonumber(filter), tonumber(mult), true
    end

    -- which part of n is each parent's clone: -> { { parent, part index or nil } }, used parts.
    -- parents: the nodes whose children hold n; nil: found by content (mirror.index, M.READS).
    local function match(n, parents)
        local found, used = {}, {}
        if parents ~= nil then
            for _, p in ipairs(parents) do
                prepare(p)
                local j = nil
                if p.key ~= "" then
                    for k, part in ipairs(n.parts) do
                        if not used[k] and part.key == p.key then
                            j = k
                            break
                        end
                    end
                end
                if j then
                    used[j] = true
                end
                found[#found + 1] = { p, j }
            end
        else
            local can = reads[n.category] or {}
            for j, part in ipairs(n.parts) do
                local pick, count = nil, 0
                for _, c in ipairs(mirror.index and mirror.index[part.key] or {}) do
                    if c ~= n and can[c.category] then
                        count = count + 1
                        pick = pick or c
                    end
                end
                if pick then
                    used[j] = true
                    found[#found + 1] = { pick, j, count }
                end
            end
        end
        return found, used
    end

    -- mirror:learn(n, parents): the kinds of n's links that have a part (nodes.build does it for
    -- every node before assigning any)
    function mirror:learn(n, parents)
        prepare(n)
        local found = match(n, parents)
        for _, f in ipairs(found) do
            if f[2] then
                local part = n.parts[f[2]]
                learn(n, f[1], part.mult, part.filter)
            end
        end
    end

    -- mirror:assign(n, parents) -> own_changed, links_changed: the holder of n made to read what
    -- the game's node does, from a fresh read of it (values, parts) and its parents (the nodes whose
    -- children hold it, read as well; nil: by content): links for the parents, with the multiplier
    -- and filter of the part that is their clone (or of their kind, when they added nothing), and
    -- the other parts as its own sources. Nothing changes in the graph if neither did.
    function mirror:assign(n, parents)
        prepare(n)
        local h = self:holder(n)
        local found, used = match(n, parents)
        local links, keys = {}, {}
        for _, f in ipairs(found) do
            local p, j = f[1], f[2]
            local mult, filter
            if j then
                mult, filter = n.parts[j].mult, n.parts[j].filter
                st.parent_parts = st.parent_parts + 1
                if f[3] then
                    st.by_content = st.by_content + 1
                    if f[3] > 1 then
                        st.ambiguous = st.ambiguous + 1
                    end
                end
            else
                local known
                filter, mult, known = learned(n, p)
                -- a parent that would have added something has no part: the edge is stale (the
                -- game drops a child from _ChildNodes only when that parent invalidates it; a
                -- child invalidated otherwise, a ship moved to another fleet, stays listed)
                for t, v in pairs(p.values) do
                    if v ~= 0 and passes(defs, t, filter) then
                        p = nil
                        break
                    end
                end
                if p == nil then
                    st.stale_edges = st.stale_edges + 1
                else
                    st.edges_without_part = st.edges_without_part + 1
                    if not known then
                        st.edges_guessed_filter = st.edges_guessed_filter + 1
                    end
                end
            end
            if p ~= nil then
                links[#links + 1] = { p.id, mult, filter }
                keys[#keys + 1] = string.format("%d|%d|%d", p.id, mult, filter)
            end
        end
        table.sort(keys)
        local links_key = table.concat(keys, ";")
        local own, own_keys = {}, {}
        for j, part in ipairs(n.parts) do
            if not used[j] then
                own[#own + 1] = part
                own_keys[#own_keys + 1] = string.format("%d|%d|%s", part.mult, part.filter, part.key)
                st.local_parts = st.local_parts + 1
            end
        end
        local unparted = #n.parts == 0 and n.key ~= ""
        if unparted then
            -- values set outside AddModifier (the Federation node's)
            own_keys[1] = "values|" .. n.key
            st.unparted = st.unparted + 1
        end
        table.sort(own_keys)
        local own_key = table.concat(own_keys, ";")

        local links_changed = links_key ~= h.links_key
        if links_changed then
            local old = {}
            for _, l in ipairs(h.parents) do
                old[l.parent] = true
            end
            for parent in pairs(old) do
                tree:unlink(h, parent)
            end
            for _, l in ipairs(links) do
                local parent = self.holders[l[1]]
                if parent ~= nil then
                    tree:link_fixed(h, parent, l[2], l[3])
                    st.edges = st.edges + 1
                end
            end
            h.links_key = links_key
        end
        local own_changed = own_key ~= h.own_key
        if own_changed then
            for name in pairs(h.sources) do
                tree:remove(h, name)
            end
            for j, part in ipairs(own) do
                local values = {}
                for t, v in pairs(part.values) do
                    if passes(defs, t, part.filter) then
                        values[t] = fixed_scale(v, part.mult)
                    end
                end
                tree:add(h, "part" .. j, values)
            end
            if unparted then
                tree:add(h, "values", n.values)
            end
            h.own_key = own_key
        end
        h.parts_key = M.parts_key(n)
        return own_changed, links_changed
    end

    -- every type a holder can have: its own and its parents' that pass the link (memoized until
    -- mirror:forget_types)
    local memo = {}
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
                if l.mask == modifiers.ALL or band(defs.cats[ty] or 0, l.mask) ~= 0 then
                    t[ty] = true
                end
            end
        end
        return t
    end
    mirror.types = types
    function mirror:forget_types()
        memo = {}
    end

    -- mirror:materialize() -> nodes made: every (holder, type) that can be non-zero, as the game
    -- holds every value of every node
    function mirror:materialize()
        local made = 0
        for _, h in pairs(self.holders) do
            for ty in pairs(types(h)) do
                if h.nodes[ty] == nil then
                    made = made + 1
                end
                tree:node(h, ty)
            end
        end
        return made
    end

    -- mirror:values(id) -> { [type name] = value } of a node, from the graph (non-zero values)
    function mirror:values(id)
        local h = self.holders[id]
        local out = {}
        for ty in pairs(types(h)) do
            local v = tree:get(h, ty)
            if v ~= 0 then
                out[defs:name(ty)] = v
            end
        end
        return out
    end

    -- mirror:compare_node(n, report): one node of a snapshot against the graph (counts into
    -- report, see mirror:compare) -> how many values differ
    function mirror:compare_node(n, report)
        local h = self.holders[n.id]
        local c = report.categories[n.category]
        if c == nil then
            c = { nodes = 0, values = 0, exact_nodes = 0, wrong = 0, missing = 0, extra = 0 }
            report.categories[n.category] = c
        end
        c.nodes = c.nodes + 1
        report.nodes = report.nodes + 1
        local bad = 0
        local function sample(text)
            if #report.samples < (report.max_samples or 20) then
                report.samples[#report.samples + 1] = text
            end
        end
        if h == nil then
            bad = 1
            c.missing = c.missing + 1
            report.missing = report.missing + 1
            sample(string.format("%s %d (owner %s): no holder", n.category, n.id, tostring(n.owner)))
        else
            local seen_t = {}
            for name, want in pairs(n.values) do
                local ty = defs:id(name)
                seen_t[ty] = true
                local got = tree:get(h, ty)
                c.values = c.values + 1
                report.values = report.values + 1
                if got ~= want then
                    bad = bad + 1
                    if got == 0 then
                        c.missing, report.missing = c.missing + 1, report.missing + 1
                    else
                        c.wrong, report.wrong = c.wrong + 1, report.wrong + 1
                    end
                    sample(string.format("%s %d (owner %s) %s: game %d, graph %d", n.category, n.id, tostring(n.owner),
                        tostring(defs:name(ty)), want, got))
                end
            end
            for ty in pairs(types(h)) do
                if not seen_t[ty] then
                    local got = tree:get(h, ty)
                    if got ~= 0 then
                        bad = bad + 1
                        c.extra, report.extra = c.extra + 1, report.extra + 1
                        sample(string.format("%s %d (owner %s) %s: game none, graph %d", n.category, n.id,
                            tostring(n.owner), tostring(defs:name(ty)), got))
                    end
                end
            end
        end
        if bad == 0 then
            c.exact_nodes = c.exact_nodes + 1
            report.exact_nodes = report.exact_nodes + 1
        end
        return bad
    end

    -- mirror:compare(snap) -> report: every value of every node of snap against the graph's:
    -- { nodes, values, exact_nodes, wrong, missing (in the graph), extra (only in the graph),
    -- categories = { [category] = the same counts }, samples = { text } }
    function mirror:compare(other)
        local report = M.new_report()
        for _, n in ipairs(other.nodes) do
            self:compare_node(n, report)
        end
        return report
    end

    -- mirror:descendants(id) -> the nodes below a node (the game rebuilds all of them when it is
    -- invalidated with an all-pass mask), as a count
    function mirror:descendants(id)
        local seen_h, count = {}, 0
        local function walk(h)
            for child in pairs(h.children) do
                if not seen_h[child] then
                    seen_h[child] = true
                    count = count + 1
                    walk(child)
                end
            end
        end
        walk(self.holders[id])
        return count
    end

    return mirror
end

function M.new_report(max_samples)
    return { categories = {}, samples = {}, nodes = 0, values = 0, exact_nodes = 0, wrong = 0, missing = 0, extra = 0,
        max_samples = max_samples or 20 }
end

-- nodes.parents(snap) -> { [child id] = { parent node, ... } }, dead: from the snapshot's children
function M.parents(snap)
    local by_id, parents, dead = {}, {}, 0
    for _, n in ipairs(snap.nodes) do
        by_id[n.id] = n
    end
    for _, n in ipairs(snap.nodes) do
        for _, c in ipairs(n.children or {}) do
            if by_id[c] ~= nil then
                local list = parents[c]
                if list == nil then
                    list = {}
                    parents[c] = list
                end
                list[#list + 1] = n
            else
                dead = dead + 1
            end
        end
    end
    return parents, dead
end

-- nodes.build(g, defs, snap) -> mirror: a holder per node, links for its parents, its own parts as
-- sources. mirror.stats says how each part and edge was taken.
function M.build(g, defs, snap)
    local mirror = M.new(g, defs)
    local st = mirror.stats
    for _, n in ipairs(snap.nodes) do
        prepare(n)
        mirror:holder(n)
        st.nodes = st.nodes + 1
        st.parts = st.parts + #n.parts
    end
    local parents
    if snap.has_children then
        parents, st.dead_children = M.parents(snap)
    else
        mirror.index = {}
        for _, n in ipairs(snap.nodes) do
            if n.key ~= "" then
                local list = mirror.index[n.key]
                if list == nil then
                    list = {}
                    mirror.index[n.key] = list
                end
                list[#list + 1] = n
            end
        end
    end
    -- the kinds of the links first, for the parents that added nothing
    for _, n in ipairs(snap.nodes) do
        mirror:learn(n, parents and (parents[n.id] or {}))
    end
    for _, n in ipairs(snap.nodes) do
        mirror:assign(n, parents and (parents[n.id] or {}))
    end
    return mirror
end

-- nodes.format_report(report) -> text
function M.format_report(report)
    local lines = { string.format("%d nodes, %d of them exact; %d values: %d wrong, %d missing in the graph, %d only in the graph",
        report.nodes, report.exact_nodes, report.values, report.wrong, report.missing, report.extra) }
    local cats = {}
    for name, c in pairs(report.categories) do
        cats[#cats + 1] = { name, c }
    end
    table.sort(cats, function(a, b) return a[2].nodes > b[2].nodes end)
    for _, e in ipairs(cats) do
        local c = e[2]
        lines[#lines + 1] = string.format("  %-26s %6d nodes %6d exact %7d values %5d wrong %5d missing %5d extra",
            e[1], c.nodes, c.exact_nodes, c.values, c.wrong, c.missing, c.extra)
    end
    for _, s in ipairs(report.samples) do
        lines[#lines + 1] = "  " .. s
    end
    return table.concat(lines, "\n")
end

return M
