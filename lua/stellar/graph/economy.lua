-- graph/economy.lua : resource production, upkeep, costs and logistics as graph formulas over
-- modifier values (stellar.graph.modifiers): the game's economic categories and resource tables.
--
-- The game's formula for one entry of a resource table (docs/modifiers.md, from
-- CEconomicUnitBase::ApplyModifiersToTable<N> in 4.5.2): an entry of category C, read on a holder
-- H (the modifier node the unit reads: the colony's for jobs, the pop group's own, the country's
-- for ship designs), with a scale s (workforce / 100 for a job, size / 100 for a pop group):
--
--   out = s * (base + A) * (1 + max(MIN_MULT, G + P))
--
--   base  the table's amounts, each block counted when its trigger holds
--   A     C's own add modifier for the resource, C_<res>_<table>_add (the parents' are not used)
--   G     the global mults of C and of every ancestor, <a>_<table>_mult
--   P     the per-resource mults of C and of every ancestor, <a>_<res>_<table>_mult
--   MIN_MULT  NDefines.NEconomy.MIN_ECONOMIC_MODIFIER_MULT, -0.9 in vanilla
--
-- Triggered category modifiers (triggered_<table>_modifier = { key = K ... }) add their terms
-- (K_<res>_<table>_add/_mult, K_<table>_mult) when their trigger holds. Triggers are script: here
-- each is an input node (1 or 0) that the script layer sets.
--
-- In the graph: one clamp node per (holder, category, table, resource) for the factor, shared by
-- every unit of that category on the holder; per entry a sum (base + A) and a product
-- (s * sum * factor). A change of one mult on the country marks the factors that read it and the
-- entries below them, nothing else.
--
--   local economy = require("stellar.graph.economy")
--   local cats = economy.categories()
--   cats:read(pdxscript.parse(text))           -- common/economic_categories/*.txt
--   local eco = economy.new(tree, cats, { resources = { "energy", "minerals", ... } })
--   local job = eco:unit(colony, { category = "planet_miners", produces = { { values = { minerals = 4 } } } }, 1.0)
--   g:get(job.produces.minerals)
--   eco:set_scale(job, workforce / 100)

local core = require("stellar.graph.core")

local M = {}

M.TABLES = { "cost", "produces", "upkeep", "logistics" }
M.MIN_MULT = -0.9

local TABLE = {}
for i, t in ipairs(M.TABLES) do
    TABLE[t] = i
end

-- categories --------------------------------------------------------------------------------------

local function words(block)
    local list = {}
    if type(block) == "table" then
        for _, e in ipairs(block) do
            if e.text then
                list[#list + 1] = e.text
            end
        end
    end
    return list
end

-- economy.categories() -> cats: the economic categories (name -> { parent, add = { [table] =
-- true }, mult = { ... }, triggered = { { table, key, add, mult, trigger } }, modifier_category })
function M.categories()
    local c = { list = {}, byname = {} }

    function c:add(name, spec)
        spec = spec or {}
        local cat = {
            name = name, parent = spec.parent, add = spec.add or {}, mult = spec.mult or {},
            triggered = spec.triggered or {}, modifier_category = spec.modifier_category, hidden = spec.hidden,
        }
        if self.byname[name] == nil then
            self.list[#self.list + 1] = cat
        end
        self.byname[name] = cat
        return cat
    end

    function c:get(name) return self.byname[name] end

    -- read a parsed file of common/economic_categories (a pdxscript tree); -> categories read
    function c:read(tree)
        local count = 0
        for _, e in ipairs(tree) do
            if e.op == "=" and e.key and type(e.value) == "table" and e.value.text == nil then
                local spec = { add = {}, mult = {}, triggered = {} }
                for _, m in ipairs(e.value) do
                    local k = m.key and m.key.text
                    if k == "parent" and m.value.text then
                        spec.parent = m.value.text
                    elseif k == "generate_add_modifiers" then
                        for _, w in ipairs(words(m.value)) do
                            spec.add[w] = true
                        end
                    elseif k == "generate_mult_modifiers" then
                        for _, w in ipairs(words(m.value)) do
                            spec.mult[w] = true
                        end
                    elseif k == "modifier_category" and m.value.text then
                        spec.modifier_category = m.value.text
                    elseif k == "hidden" and m.value.text then
                        spec.hidden = m.value.text == "yes"
                    elseif k and k:match("^triggered_(%a+)_modifier$") and type(m.value) == "table" then
                        local t = { table = k:match("^triggered_(%a+)_modifier$") }
                        for _, f in ipairs(m.value) do
                            local fk = f.key and f.key.text
                            if fk == "key" then
                                t.key = f.value.text
                            elseif fk == "modifier_types" then
                                for _, w in ipairs(words(f.value)) do
                                    t[w] = true
                                end
                            elseif fk == "trigger" then
                                t.trigger = f.value
                            end
                        end
                        spec.triggered[#spec.triggered + 1] = t
                    end
                end
                self:add(e.key.text, spec)
                count = count + 1
            end
        end
        return count
    end

    -- the category and its ancestors, nearest first
    function c:chain(name)
        local list, seen = {}, {}
        local cat = self.byname[name]
        while cat ~= nil and not seen[cat] do
            seen[cat] = true
            list[#list + 1] = cat
            cat = cat.parent and self.byname[cat.parent]
        end
        return list
    end

    -- the modifier names a category generates (the game's rules, docs/modifiers.md)
    function c:generated(name, resources)
        local cat, names = self.byname[name], {}
        if cat == nil then
            return names
        end
        for _, t in ipairs(M.TABLES) do
            if cat.mult[t] then
                names[#names + 1] = name .. "_" .. t .. "_mult"
                for _, r in ipairs(resources) do
                    names[#names + 1] = name .. "_" .. r .. "_" .. t .. "_mult"
                end
            end
            if cat.add[t] then
                for _, r in ipairs(resources) do
                    names[#names + 1] = name .. "_" .. r .. "_" .. t .. "_add"
                end
            end
        end
        for _, t in ipairs(cat.triggered) do
            if t.key then
                if t.mult then
                    names[#names + 1] = t.key .. "_" .. t.table .. "_mult"
                end
                for _, kind in ipairs({ "add", "mult" }) do
                    if t[kind] then
                        for _, r in ipairs(resources) do
                            names[#names + 1] = t.key .. "_" .. r .. "_" .. t.table .. "_" .. kind
                        end
                    end
                end
            end
        end
        return names
    end

    return c
end

-- formulas ----------------------------------------------------------------------------------------

-- economy.new(tree, cats, options) -> eco; options: resources (names), min_mult (-0.9)
function M.new(tree, cats, options)
    options = options or {}
    local g = tree.g
    local eco = { tree = tree, g = g, cats = cats, resources = options.resources or {}, min_mult = options.min_mult or M.MIN_MULT }
    local factors = setmetatable({}, { __mode = "k" })   -- holder -> { key -> node }
    local triggers = setmetatable({}, { __mode = "k" })  -- holder -> { key -> input node }

    -- the trigger input of a triggered category modifier on a holder (1 or 0, set by the script
    -- layer; 0 until then)
    function eco:trigger(holder, category, index)
        local th = triggers[holder]
        if th == nil then
            th = {}
            triggers[holder] = th
        end
        local key = category .. "#" .. index
        local n = th[key]
        if n == nil then
            n = g:input(0)
            th[key] = n
        end
        return n
    end

    -- add value(holder, name) * gate (an input node, or nil for always) into the sum node s
    local function add_term(s, holder, name, gate)
        local v = tree:node(holder, name)
        if gate == nil then
            g:link(v, s)
        else
            local p = g:product(1)
            g:link(gate, p)
            g:link(v, p)
            g:link(p, s)
        end
    end

    -- the factor 1 + max(min_mult, G + P) of (category, table, resource) on a holder
    function eco:factor(holder, category, table_name, resource)
        local fh = factors[holder]
        if fh == nil then
            fh = {}
            factors[holder] = fh
        end
        local key = category .. "|" .. table_name .. "|" .. resource
        local n = fh[key]
        if n ~= nil then
            return n
        end
        n = g:clamp(1 + self.min_mult, math.huge, 1)
        for _, cat in ipairs(cats:chain(category)) do
            if cat.mult[table_name] then
                add_term(n, holder, cat.name .. "_" .. table_name .. "_mult")
                add_term(n, holder, cat.name .. "_" .. resource .. "_" .. table_name .. "_mult")
            end
            for i, t in ipairs(cat.triggered) do
                if t.table == table_name and t.mult and t.key then
                    local gate = self:trigger(holder, cat.name, i)
                    add_term(n, holder, t.key .. "_" .. table_name .. "_mult", gate)
                    add_term(n, holder, t.key .. "_" .. resource .. "_" .. table_name .. "_mult", gate)
                end
            end
        end
        fh[key] = n
        return n
    end

    -- one entry: s * (base + A) * factor; base and scale are nodes (scale: nil for 1); -> the
    -- product node, the sum node (base + A)
    function eco:entry(holder, category, table_name, resource, base, scale)
        local sum = g:sum(0)
        g:link(base, sum)
        local cat = cats:get(category)
        if cat ~= nil then
            if cat.add[table_name] then
                add_term(sum, holder, category .. "_" .. resource .. "_" .. table_name .. "_add")
            end
            for i, t in ipairs(cat.triggered) do
                if t.table == table_name and t.add and t.key then
                    add_term(sum, holder, t.key .. "_" .. resource .. "_" .. table_name .. "_add", self:trigger(holder, category, i))
                end
            end
        end
        local out = g:product(1)
        if scale ~= nil then
            g:link(scale, out)
        end
        g:link(sum, out)
        g:link(self:factor(holder, category, table_name, resource), out)
        return out, sum
    end

    -- a unit: spec = { category = C, produces = blocks, upkeep = blocks, cost = ..., logistics = ... }
    -- where blocks = { { values = { [resource] = amount }, trigger = input node or nil }, ... };
    -- -> unit = { [table] = { [resource] = node }, scale = input node }
    function eco:unit(holder, spec, scale)
        local unit = { holder = holder, spec = spec, scale = g:input(scale or 1) }
        for _, t in ipairs(M.TABLES) do
            local blocks = spec[t]
            if blocks ~= nil then
                local bases = {}
                for _, b in ipairs(blocks) do
                    for r, amount in pairs(b.values) do
                        local base = bases[r]
                        if base == nil then
                            base = g:sum(0)
                            bases[r] = base
                        end
                        if b.trigger ~= nil then
                            g:link(b.trigger, base, amount)
                        else
                            g:set_base(base, g:base(base) + amount)
                        end
                    end
                end
                local out = {}
                for r, base in pairs(bases) do
                    out[r] = self:entry(holder, spec.category, t, r, base, unit.scale)
                end
                unit[t] = out
            end
        end
        return unit
    end

    function eco:set_scale(unit, scale)
        g:set(unit.scale, scale)
    end

    -- a total: a sum node; add entries with g:link(entry, total, count)
    function eco:total(class)
        return g:sum(0, class or core.READ)
    end

    return eco
end

return M
