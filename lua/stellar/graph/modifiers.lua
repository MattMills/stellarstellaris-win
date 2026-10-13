-- graph/modifiers.lua : the game's modifiers as nodes of a stellar.graph.core graph.
--
-- In the game every object with modifiers (country, planet, colony, pop group, fleet, ship,
-- leader, starbase, ...) has a modifier node (NModifierNode::CModifierNode, docs/modifiers.md): a
-- CModifier holding the sum of everything that applies to the object, rebuilt whole by the
-- object's CalculateModifier whenever anything in it is invalidated, and read by the objects
-- below it (a ship reads its fleet's, a fleet its country's, ...), scaled and filtered by
-- modifier category. Here the same tree is kept per modifier type. A holder is an object's
-- modifier, and the value of type T on holder H is one sum node:
--
--     value(H, T) = local(H, T) + sum over the parents P of H: scale(H, P) * value(P, T)
--
-- local(H, T) is the sum of the sources added to H (static modifiers, traits, edicts, timed
-- modifiers, ...); a parent passes T only when T's categories meet the link's category mask.
-- Nodes are made on demand: only the (holder, type) pairs that are read, and what they read,
-- exist. A change of one type on a country marks only that type's nodes below it, where the game
-- rebuilds every modifier of every object below it.
--
--   local modifiers = require("stellar.graph.modifiers")
--   local defs = modifiers.definitions()
--   defs:read_log(text)                            -- modifiers.log (logs/script_documentation)
--   local tree = modifiers.new(g, defs)
--   local country = tree:holder("country", 1)
--   local fleet = tree:holder("fleet", 7)
--   local ship = tree:holder("ship", 42)
--   tree:link(fleet, country)                     -- the fleet reads the country's modifiers
--   tree:link(ship, fleet, 1, defs:mask("Ships")) -- only ship modifiers pass
--   tree:add(country, "edict:x", { ship_fire_rate_mult = 0.1 })
--   tree:get(ship, "ship_fire_rate_mult")         --> 0.1
--   tree:node(ship, "ship_fire_rate_mult")        -- its graph node, to build formulas on
--
-- Modifier types are named or numbered (defs:id(name)); unknown names are added to the
-- definitions (without categories) when first used.

local bit = require("bit")

local band, bor = bit.band, bit.bor
local fmod = math.fmod

local M = {}

M.ALL = -1  -- a mask every category passes

-- ModifierCategory (4.5.2, from the PDB): the bit of each label modifiers.log prints. "Ships" is
-- the whole ship mask (stations and the four kinds of ship), "All" every bit.
M.CATEGORY = {
    Pops = 2, ["Orbital Stations"] = 4, ["Space Stations"] = 8, ["Military Ships"] = 16,
    ["Civilian Ships"] = 32, ["Science Ships"] = 64, Fleets = 128, Countries = 256, Armies = 512,
    Leaders = 1024, Planets = 2048, ["Ship Components"] = 4096, ["Pop Factions"] = 8192,
    ["Transport Ships"] = 16384, Deposits = 32768, Megastructures = 65536, Habitability = 131072,
    Starbases = 262144, ["Economic Units"] = 524288, ["Star Systems"] = 1048576, Waystations = 2097152,
    Federations = 4194304, Espionage = 8388608, ["AI Economy"] = 16777216, ["Ship Design Stats"] = 33554432,
    ["Astral Rift"] = 67108864, ["Cosmic Storm Influence Field"] = 134217728, ["Owned Ships"] = 268435456,
    ["Galactic Community"] = 536870912, Colony = 1073741824,
    Ships = 16508, All = -1,
}

-- definitions ----------------------------------------------------------------------------------

-- modifiers.definitions() -> defs: modifier types (names, ids) and their categories (the game's
-- ModifierCategory mask; labels as modifiers.log prints them: "Pops", "Ships", "Economic Units")
function M.definitions()
    local d = { names = {}, ids = {}, cats = {}, category_bits = {}, n = 0 }

    -- the mask of a category label: the game's bit, or a free bit for a label it does not have
    function d:category(name)
        local b = M.CATEGORY[name] or self.category_bits[name]
        if b == nil then
            error("stellar.graph.modifiers: unknown modifier category '" .. tostring(name) .. "'", 2)
        end
        return b
    end

    -- the mask of category names: d:mask("Ships", "Fleets") or d:mask({ "Ships" })
    function d:mask(...)
        local names = select("#", ...) == 1 and type((...)) == "table" and (...) or { ... }
        local m = 0
        for _, name in ipairs(names) do
            m = bor(m, self:category(name))
        end
        return m
    end

    -- d:add(name, categories) -> id; categories: a mask, or a list of names
    function d:add(name, categories)
        local id = self.ids[name]
        if id == nil then
            self.n = self.n + 1
            id = self.n
            self.ids[name] = id
            self.names[id] = name
        end
        if type(categories) == "table" then
            categories = self:mask(categories)
        end
        self.cats[id] = categories or self.cats[id] or 0
        return id
    end

    -- the id of a type (a name or an id); unknown names are added
    function d:id(t)
        if type(t) == "number" then
            return t
        end
        return self.ids[t] or self:add(t)
    end

    function d:name(id) return self.names[id] end
    function d:categories(t) return self.cats[self:id(t)] or 0 end

    -- read modifiers.log ("- name, Category: A, B" lines); -> number of definitions read
    function d:read_log(text)
        local count = 0
        for line in text:gmatch("[^\n]+") do
            local name, cats = line:match("^%- ([%w_]+), Category: ([^\r]*)")
            if name then
                local list = {}
                for c in cats:gmatch("[^,]+") do
                    list[#list + 1] = c:match("^%s*(.-)%s*$")
                end
                self:add(name, list)
                count = count + 1
            end
        end
        return count
    end

    return d
end

-- the tree --------------------------------------------------------------------------------------

-- modifiers.new(g, defs) -> tree
function M.new(g, defs)
    -- owner[node], type_of[node]: the holder and the type of a value node
    local tree = { g = g, defs = defs, holders = {}, nholders = 0, nnodes = 0, owner = {}, type_of = {} }
    local ALL = M.ALL

    local function passes(t, mask)
        if mask == ALL then
            return true
        end
        return band(defs.cats[t] or 0, mask) ~= 0
    end

    -- the game's addition of an entry with a multiplier (CModifier::AddModifierEntry): value *
    -- mult / 100000 in fixed point, truncated toward zero; exact in doubles below 2^53
    local function fixed_scale(x, mult)
        local p = x * mult
        return (p - fmod(p, 100000)) / 100000
    end

    -- the edge of a link for type t: the parent's node pn into the child's node n. A fixed-point
    -- link goes through a node of its own per type that truncates as the game does.
    local function connect(link, pn, n, t)
        if link.fixed == nil then
            g:link(pn, n, link.scale)
            return
        end
        local f = g:func(function(gr, x)
            return fixed_scale(gr:in_value(x, 0), link.fixed)
        end)
        g:link(pn, f)
        g:link(f, n)
        link.via[t] = f
    end

    local function disconnect(link, pn, n, t)
        if link.fixed == nil then
            g:unlink(pn, n)
            return
        end
        local f = link.via[t]
        if f ~= nil then
            g:remove(f)
            link.via[t] = nil
        end
    end

    -- the value node of type t (an id) on holder h, made on demand with its parents' nodes
    local function node(h, t)
        local n = h.nodes[t]
        if n ~= nil then
            return n
        end
        n = g:sum(h.values[t] or 0)
        h.nodes[t] = n
        tree.owner[n], tree.type_of[n] = h, t
        tree.nnodes = tree.nnodes + 1
        for _, link in ipairs(h.parents) do
            if passes(t, link.mask) then
                connect(link, node(link.parent, t), n, t)
            end
        end
        return n
    end

    -- tree:holder(kind, key) -> the holder of an object (made if new)
    function tree:holder(kind, key)
        local byk = self.holders[kind]
        if byk == nil then
            byk = {}
            self.holders[kind] = byk
        end
        local h = byk[key]
        if h == nil then
            h = { kind = kind, key = key, parents = {}, children = {}, values = {}, sources = {}, nodes = {} }
            byk[key] = h
            self.nholders = self.nholders + 1
        end
        return h
    end

    function tree:find(kind, key)
        local byk = self.holders[kind]
        return byk and byk[key]
    end

    -- child reads parent's modifiers, times scale (1), the types whose categories meet mask (all)
    function tree:link(child, parent, scale, mask)
        scale = scale or 1
        mask = mask or ALL
        for _, link in ipairs(child.parents) do
            if link.parent == parent then
                error("stellar.graph.modifiers: already linked", 2)
            end
        end
        local link = { parent = parent, scale = scale, mask = mask }
        child.parents[#child.parents + 1] = link
        parent.children[child] = link
        for t, n in pairs(child.nodes) do
            if passes(t, mask) then
                g:link(node(parent, t), n, scale)
            end
        end
    end

    -- the game's AddModifierNode(child, parent, mult, filter) with values in raw fixed point (1.0 =
    -- 100000): child reads parent's values times mult / 100000, each entry truncated toward zero,
    -- the types whose categories meet the filter (0 and -1: all). Unlike tree:link, a pair can be
    -- linked more than once (the game adds some parents twice, with different filters); unlink
    -- removes every link of the pair. -> the link
    function tree:link_fixed(child, parent, mult, filter)
        if filter == 0 or filter == -1 or filter == nil then
            filter = ALL
        end
        local link = { parent = parent, scale = 1, mask = filter }
        if mult ~= nil and mult ~= 100000 then
            link.fixed, link.via = mult, {}
        end
        child.parents[#child.parents + 1] = link
        parent.children[child] = link
        for t, n in pairs(child.nodes) do
            if passes(t, filter) then
                connect(link, node(parent, t), n, t)
            end
        end
        return link
    end

    function tree:unlink(child, parent)
        local found = false
        for i = #child.parents, 1, -1 do
            local link = child.parents[i]
            if link.parent == parent then
                for t, n in pairs(child.nodes) do
                    local pn = parent.nodes[t]
                    if pn ~= nil and passes(t, link.mask) then
                        disconnect(link, pn, n, t)
                    end
                end
                table.remove(child.parents, i)
                found = true
            end
        end
        if found then
            parent.children[child] = nil
        end
        return found
    end

    function tree:set_scale(child, parent, scale)
        for _, link in ipairs(child.parents) do
            if link.parent == parent then
                if link.fixed ~= nil then
                    error("stellar.graph.modifiers: set_scale of a fixed-point link (unlink and link it again)", 2)
                end
                link.scale = scale
                for t, n in pairs(child.nodes) do
                    local pn = parent.nodes[t]
                    if pn ~= nil and passes(t, link.mask) then
                        g:set_coef(pn, n, scale)
                    end
                end
                return true
            end
        end
        return false
    end

    local function add_value(h, t, v)
        local x = (h.values[t] or 0) + v
        h.values[t] = x
        local n = h.nodes[t]
        if n ~= nil then
            g:set_base(n, x)
        end
    end

    -- add (or replace) a source on a holder: values = { [type name or id] = value }
    function tree:add(h, source, values)
        if h.sources[source] ~= nil then
            self:remove(h, source)
        end
        local stored = {}
        for t, v in pairs(values) do
            local id = defs:id(t)
            stored[id] = (stored[id] or 0) + v
            add_value(h, id, v)
        end
        h.sources[source] = stored
    end

    function tree:remove(h, source)
        local stored = h.sources[source]
        if stored == nil then
            return false
        end
        for t, v in pairs(stored) do
            add_value(h, t, -v)
        end
        h.sources[source] = nil
        return true
    end

    -- the node of a type on a holder (to read it or build formulas on it)
    function tree:node(h, t)
        return node(h, defs:id(t))
    end

    -- the exact value of a type on a holder
    function tree:get(h, t)
        return g:get(node(h, defs:id(t)))
    end

    -- the local sum of a type on a holder (its own sources, not its parents')
    function tree:local_value(h, t)
        return h.values[defs:id(t)] or 0
    end

    -- remove a holder: its links and its nodes (the children lose what they read from it)
    function tree:destroy(h)
        for child in pairs(h.children) do
            self:unlink(child, h)
        end
        while #h.parents > 0 do
            self:unlink(h, h.parents[#h.parents].parent)
        end
        for t, n in pairs(h.nodes) do
            g:remove(n)
            tree.owner[n], tree.type_of[n] = nil, nil
            tree.nnodes = tree.nnodes - 1
        end
        h.nodes = {}
        local byk = self.holders[h.kind]
        if byk ~= nil and byk[h.key] == h then
            byk[h.key] = nil
            self.nholders = self.nholders - 1
        end
    end

    return tree
end

return M
