-- engine/economy.lua : every country's monthly budget, income and expenses by economic category and
-- resource, from the world (a save), the definitions (the vanilla files) and a modifier source, the
-- way the game's CEconomicUnitManager::CalculateTablesOrUpdateBudget does it (docs/modifiers.md,
-- "The economy").
--
-- An economic unit is a resource table (`resources = { category = C produces = { ... } upkeep = {
-- ... } }` of a job, building, district, pop category, trait, ship size, ...) on an object, with a
-- scale s (workforce / 100 for a job, size / 100 for a pop group, 1 for a building, the level for
-- a district) and the modifier node M of the object it reads (the colony's for jobs, buildings and
-- districts, the pop group's own, ...). For each table T (produces -> income, upkeep -> expenses):
--
--   base[r] = s * sum of the blocks whose trigger holds (times their multiplier)
--   base[r] += s * (M[C_r_T_add] + the triggered adds of C whose trigger holds)   (own category)
--   out[r]  = base[r] * (1 + max(MIN_ECONOMIC_MODIFIER_MULT, G + P[r]))
--
-- with G = the sum over C and its ancestors of M[a_T_mult] and P[r] of M[a_r_T_mult] (plus their
-- triggered mults). Files:
--
-- - engine/economy/units.lua: the unit kinds (jobs and their automation, buildings, districts and
--   zones, pop groups, country types and the country container, leaders, deposits, starbases,
--   ships, armies, diplomacy), then the costs computed from the budgets (planetary deficits, the
--   trade policy);
-- - engine/economy/script.lua: what the tables ask of the script layer that it does not answer
--   yet, installed only while the economy evaluates (links, triggers, script values);
-- - engine/economy/capture.lua: the modifier source from the game's capture of its modifier nodes.
--
--   local economy = require("engine.economy")
--   economy.set_modifier_source(f)     -- f(kind, id) -> { [modifier] = value } | nil
--   economy.use_capture(path)          -- or the capture's nodes as the source
--   economy.budget(country_id)         -- { income = { [cat] = { [res] = v } }, expenses = ... }
--   economy.monthly()                  -- the month's balance added to every country's stockpile
--   economy.check()                    -- the budgets against the save's budget.current_month
--
-- The save is written after the monthly update: its budget was computed before the month's pop
-- growth. economy.check sets economy.before_growth (sizes and uncapped jobs taken back to before
-- the growth); economy.monthly computes from the world as it is.

local defs = require("engine.defs")
local world = require("engine.world")
local eval = require("simscript.eval")
local db = require("simscript.db")
local source = require("stellar.script.source")
local graph_economy = require("stellar.graph.economy")

local economy = {
    TABLES = { produces = "income", upkeep = "expenses" },
    MIN_MULT = -0.9,     -- NDefines.NEconomy.MIN_ECONOMIC_MODIFIER_MULT (read from common/defines)
    POP_BULK = 100,      -- NDefines.NPop.POP_BULK_UNIT_SIZE
}

-- ---------------------------------------------------------------------------------------------
-- the modifier source: one function, swappable (engine.modifiers once it is built)

local modifier_source = function() return nil end
local has_source = false

-- economy.set_modifier_source(f): f(kind, id) -> { [modifier name] = value } | nil, kind one of
-- colony, planet, pop_group, country, ship, fleet, leader, starbase, army, megastructure
function economy.set_modifier_source(f)
    modifier_source = f
    has_source = f ~= nil
    economy.invalidate()
end

-- whether a modifier source is set (the tick runs the economy only then)
function economy.has_modifier_source()
    return has_source
end

function economy.modifiers(kind, id)
    return modifier_source(kind, id)
end

-- economy.use_capture(path) -> true | nil, message: the game's captured modifier nodes as the source
function economy.use_capture(path)
    local f, message = require("engine.economy.capture").load(path)
    if not f then
        return nil, message
    end
    economy.set_modifier_source(f)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the definitions: economic categories, resources, defines

local cats, resources, resource_set
local function init()
    if cats then
        return
    end
    cats = graph_economy.categories()
    local tree = {}
    for name, d in pairs(defs.folder("common/economic_categories")) do
        tree[#tree + 1] = { op = "=", key = { text = name }, value = d.block }
    end
    cats:read(tree)
    resources, resource_set = {}, {}
    local list = {}
    for name, d in pairs(defs.folder("common/strategic_resources")) do
        list[#list + 1] = { name = name, file = d.file, line = d.line or 0 }
    end
    table.sort(list, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    for _, r in ipairs(list) do
        resources[#resources + 1] = r.name
        resource_set[r.name] = true
    end
    -- the defines (common/defines: NDefines = { NEconomy = { MIN_ECONOMIC_MODIFIER_MULT = -0.9 } })
    local function define(group, key)
        for _, d in pairs(defs.folder("common/defines")) do
            local v = defs.field(defs.field(d.block, group) or {}, key)
            if v ~= nil then return v end
        end
        for _, d in pairs(defs.folder("common/defines")) do
            local v = defs.field(d.block, key)
            if v ~= nil then return v end
        end
    end
    economy.MIN_MULT = tonumber(define("NEconomy", "MIN_ECONOMIC_MODIFIER_MULT")) or economy.MIN_MULT
    economy.POP_BULK = tonumber(define("NPop", "POP_BULK_UNIT_SIZE")) or economy.POP_BULK
    economy.DEFICIT_CATEGORY = define("NEconomy", "COLONY_DEFICIT_ECONOMIC_CATEGORY") or "planet_resource_deficit"
    economy.TRADE_POLICY_CATEGORY = define("NEconomy", "TRADE_POLICY_ECONOMIC_CATEGORY") or "trade_policy"
    economy.categories, economy.resources, economy.resource_set = cats, resources, resource_set
end
economy.init = init

-- ---------------------------------------------------------------------------------------------
-- resource tables: a `resources = { ... }` block, its inline scripts expanded, as a template
-- { category, file, produces = { block, ... }, upkeep = { ... } }; a block { trigger, mult,
-- values = { { res, value } } }

local templates = setmetatable({}, { __mode = "k" })

local function lower_key(e)
    return e.key and e.key.text:lower()
end

function economy.template(block, file)
    if block == nil then
        return nil
    end
    local t = templates[block]
    if t ~= nil then
        return t or nil
    end
    init()
    local expanded = source.expand(db.fs, block, {}, 0, "file: " .. tostring(file))
    t = { file = file, produces = {}, upkeep = {}, cost = {} }
    for _, e in ipairs(expanded) do
        if e.op and e.key then
            local k = lower_key(e)
            if k == "category" then
                t.category = e.value.text
            elseif (k == "produces" or k == "upkeep" or k == "cost") and e.value.text == nil then
                local b = { values = {} }
                for _, x in ipairs(e.value) do
                    if x.op and x.key then
                        local xk = lower_key(x)
                        if xk == "trigger" then
                            b.trigger = x.value
                        elseif xk == "multiplier" or xk == "mult" then
                            b.mult = x.value
                        elseif resource_set[x.key.text] then
                            b.values[#b.values + 1] = { x.key.text, x.value }
                        end
                    end
                end
                local list = t[k]
                list[#list + 1] = b
            end
        end
    end
    templates[block] = t
    return t
end

-- `trigger:<name>` values (a trigger's numeric value in the scope): what the resource tables use
economy.TRIGGER_VALUES = {
    -- a leader's skill: its level, and with its bonus levels
    has_base_skill = function(sc)
        if sc.kind ~= "leader" then return nil end
        return tonumber(world.field(world.object("leader", sc.id), "level")) or 0
    end,
    has_total_skill = function(sc)
        if sc.kind ~= "leader" then return nil end
        local l = world.object("leader", sc.id)
        return (tonumber(world.field(l, "level")) or 0) + (tonumber(world.field(l, "bonus_skill_level")) or 0)
    end,
    num_ascension_perks = function(sc)
        if sc.kind ~= "country" then return nil end
        return #world.list(world.field(world.object("country", sc.id), "ascension_perks"))
    end,
    num_owned_planets = function(sc)
        if sc.kind ~= "country" then return nil end
        return #world.list(world.field(world.object("country", sc.id), "owned_planets"))
    end,
}
economy.trigger_values_missing = {}

-- the value of a token or block with the script layer, numbers taken as they are
local function value_of(v, ctx)
    local text = v.text
    local n = text and tonumber(text)
    if n then
        return n
    end
    if text and text:sub(1, 8) == "trigger:" then
        local f = economy.TRIGGER_VALUES[text:sub(9)]
        local r = f and f(ctx.this)
        if r == nil then
            economy.trigger_values_missing[text] = (economy.trigger_values_missing[text] or 0) + 1
            return 0
        end
        return r
    end
    return eval.value(v, ctx, v)
end
economy.value_of = value_of

-- the base table of a template's table kind in a scope: { [res] = amount }, or nil when empty
local function base_table(t, kind, ctx)
    local out
    for _, b in ipairs(t[kind]) do
        if b.trigger == nil or eval.trigger(b.trigger, ctx) then
            local m = b.mult and value_of(b.mult, ctx) or 1
            if m ~= 0 then
                for _, rv in ipairs(b.values) do
                    out = out or {}
                    out[rv[1]] = (out[rv[1]] or 0) + value_of(rv[2], ctx) * m
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the formula: CEconomicUnitBase::ApplyModifiersToTable<N>

-- a triggered category modifier holds in this scope (evaluated only when M has a value for it)
local function triggered_holds(t, ctx)
    return t.trigger == nil or eval.trigger(t.trigger, ctx)
end

local function nonzero(M, name)
    local v = M[name]
    return v ~= nil and v ~= 0 and v or nil
end

-- economy.apply(category, table_kind, base, s, M, ctx) -> { [res] = value } (base already without s)
function economy.apply(category, kind, base, s, M, ctx)
    local out = {}
    for r, v in pairs(base or {}) do
        out[r] = v * s
    end
    if M == nil or next(M) == nil then
        return out
    end
    local cat = cats:get(category)
    if cat ~= nil then
        -- 3. adds, own category only
        if cat.add[kind] then
            for _, r in ipairs(resources) do
                local a = nonzero(M, category .. "_" .. r .. "_" .. kind .. "_add")
                if a then
                    out[r] = (out[r] or 0) + s * a
                end
            end
        end
        for _, t in ipairs(cat.triggered) do
            if t.table == kind and t.add and t.key then
                local held
                for _, r in ipairs(resources) do
                    local a = nonzero(M, t.key .. "_" .. r .. "_" .. kind .. "_add")
                    if a then
                        if held == nil then held = triggered_holds(t, ctx) end
                        if held then
                            out[r] = (out[r] or 0) + s * a
                        end
                    end
                end
            end
        end
    end
    -- 5-7. the mults of the chain
    local G = 0
    local P = {}
    for _, c in ipairs(cats:chain(category)) do
        if c.mult[kind] then
            G = G + (M[c.name .. "_" .. kind .. "_mult"] or 0)
            for r in pairs(out) do
                P[r] = (P[r] or 0) + (M[c.name .. "_" .. r .. "_" .. kind .. "_mult"] or 0)
            end
        end
        for _, t in ipairs(c.triggered) do
            if t.table == kind and t.key then
                local held
                if t.mult then
                    local g = nonzero(M, t.key .. "_" .. kind .. "_mult")
                    if g then
                        held = triggered_holds(t, ctx)
                        if held then G = G + g end
                    end
                end
                for r in pairs(out) do
                    local p = t.mult and nonzero(M, t.key .. "_" .. r .. "_" .. kind .. "_mult")
                    if p then
                        if held == nil then held = triggered_holds(t, ctx) end
                        if held then P[r] = (P[r] or 0) + p end
                    end
                end
            end
        end
    end
    for r, v in pairs(out) do
        local m = 1 + math.max(economy.MIN_MULT, G + (P[r] or 0))
        out[r] = m > 0 and v * m or 0
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- budgets

local budgets            -- country id -> { income = { [cat] = { [res] = v } }, expenses = ... }
local contributions      -- country id -> { { side, cat, res, value, unit } } when explaining
economy.explain_on = false

function economy.invalidate()
    budgets = nil
end

local function budget_of(country)
    local b = budgets[country]
    if b == nil then
        b = { income = {}, expenses = {} }
        budgets[country] = b
    end
    return b
end
economy.budget_of = budget_of

-- the budget so far of (country, side, category): { [res] = v }
function economy.budget_entry(country, side, category)
    return budget_of(country)[side][category] or {}
end

-- the colony whose units are being added (economy.colony_tables: colony id -> { income = { [res]
-- = v }, expenses = ... }, what the colony's own units produce and use: its deficits)
economy.current_colony = nil
economy.colony_tables = {}

-- economy.add(country, side, category, res, value[, unit]): an amount into a budget directly
economy.add_to = nil   -- nil: the budget and the colony's tables; "budget" or "colony": one of them
function economy.add(country, side, category, res, value, unit)
    if country == nil or value == 0 or value == nil then
        return
    end
    local col = economy.current_colony
    if col ~= nil and economy.add_to ~= "budget" then
        local ct = economy.colony_tables[col]
        if ct == nil then
            ct = { income = {}, expenses = {}, country = country }
            economy.colony_tables[col] = ct
        end
        ct[side][res] = (ct[side][res] or 0) + value
    end
    if economy.add_to == "colony" then
        return
    end
    local b = budget_of(country)[side]
    local c = b[category]
    if c == nil then
        c = {}
        b[category] = c
    end
    c[res] = (c[res] or 0) + value
    if economy.explain_on then
        local l = contributions[country]
        if l == nil then
            l = {}
            contributions[country] = l
        end
        l[#l + 1] = { side, category, res, value, unit }
    end
end

-- economy.unit(country, template, s, M, ctx[, label[, category[, factors]]]): one economic unit
-- into its country's budget (produces -> income, upkeep -> expenses); factors: { [table] = f },
-- what the unit's kind multiplies a table's result by (a ship in orbit, ...)
function economy.unit(country, t, s, M, ctx, label, category, factors)
    if t == nil or country == nil then
        return
    end
    category = category or t.category
    for kind, side in pairs(economy.TABLES) do
        local base = base_table(t, kind, ctx)
        local cat = cats:get(category)
        local adds = cat ~= nil and M ~= nil and (cat.add[kind] or #cat.triggered > 0)
        if base ~= nil or adds then
            local out = economy.apply(category, kind, base, s, M, ctx)
            local f = factors and factors[kind] or 1
            for r, v in pairs(out) do
                economy.add(country, side, category, r, v * f, label)
            end
        end
    end
end

-- the scope of a unit for its triggers and values
function economy.ctx(kind, id, file)
    return eval.new_ctx(eval.S(kind, id), nil, nil, file)
end

-- the size of a pop group the budget counts. The budget is computed in the monthly update before
-- the month's pop growth; a save written at the monthly update holds the sizes after it, and the
-- growth (last_month_growth): economy.before_growth (set by economy.check) takes it out.
economy.before_growth = false
-- the growth of the month that came after the budget: last_month_growth_details' GROWTH and
-- PROMOTION (resettlement happens during the month, before it); last_month_growth without details
function economy.growth_after_budget(g)
    local details = world.field(g, "last_month_growth_details")
    if type(details) ~= "table" then
        return tonumber(world.field(g, "last_month_growth")) or 0
    end
    local n, key = 0, nil
    for _, e in ipairs(details) do
        if e.op and e.key.text == "key" then
            key = e.value.text
        elseif e.op and e.key.text == "value" then
            if key ~= "GROWTH_CAT_RESETTLE" then n = n + (tonumber(e.value.text) or 0) end
        end
    end
    return n
end

function economy.pop_size(g)
    local size = tonumber(world.field(g, "size")) or 0
    if economy.before_growth then
        size = size - economy.growth_after_budget(g)
    end
    return size
end

-- economy.compute(): every country's budget, from every unit kind
function economy.compute()
    init()
    budgets, contributions = {}, {}
    economy.colony_tables, economy.current_colony = {}, nil
    local units = require("engine.economy.units")
    economy.timings = {}
    require("engine.economy.script").with(function()
        for _, kind in ipairs(units.order) do
            local t0 = RUST.clock()
            units[kind](economy)
            economy.current_colony = nil
            economy.timings[kind] = RUST.clock() - t0
        end
    end)
    return budgets
end

local function ensure()
    if budgets == nil then
        economy.compute()
    end
end

-- economy.budget(country) -> { income = { [cat] = { [res] = v } }, expenses = { ... } }
function economy.budget(country)
    ensure()
    return budgets[country] or { income = {}, expenses = {} }
end

-- economy.contributions(country) -> the units behind a budget (economy.explain_on before compute)
function economy.contributions(country)
    ensure()
    return contributions[country] or {}
end

-- economy.balance(country) -> { [res] = income - expenses } of its budget
function economy.balance(country)
    local b = economy.budget(country)
    local balance = {}
    for side, sign in pairs({ income = 1, expenses = -1 }) do
        for _, res in pairs(b[side]) do
            for r, v in pairs(res) do
                balance[r] = (balance[r] or 0) + sign * v
            end
        end
    end
    return balance
end

-- economy.monthly() -> the budgets applied: every country's balance of the month added to its
-- stockpile (CCountryBudget::EndMonthlyUpdate -> CEconomyCountryModule::AddResources), through
-- world.set on modules.standard_economy_module.resources (countries without that module have no
-- stockpile). The budget is computed from the world as it is (the month's modifier update done
-- before), kept as economy.last_month, then dropped. A stockpile stays within 0 and its cap
-- (economy.capacity). Research is not stockpiled: it goes to the technologies being researched
-- (not modelled yet, so it is left out). Not modelled yet: what a deficit does (situations,
-- deficit modifiers).

-- economy.capacity(country, r) -> the most of resource r the country can store, or nil (no cap): the
-- resource's `max`, its `dynamic_capacity` (base, and the adds of the modifiers whose triggers hold
-- for the country), and the country's country_resource_max_add and country_resource_max_<r>_add
function economy.capacity(country, r)
    local def = defs.get("common/strategic_resources", r)
    local max = def and tonumber(defs.field(def.block, "max"))
    if not max then
        return nil
    end
    -- `fixed_max_amount = yes` (influence): the max as written, no capacity added
    if defs.field(def.block, "fixed_max_amount") == "yes" then
        return max
    end
    local dyn = def and defs.field(def.block, "dynamic_capacity")
    if type(dyn) == "table" then
        max = max + (tonumber(defs.field(dyn, "base")) or 0)
        local ctx = economy.ctx("country", country, def.file)
        for _, e in ipairs(dyn) do
            if e.op and e.key.text == "modifier" and e.value.text == nil then
                -- (a modifier's `subtract`, alloys': a value operation, not a trigger)
                local add = (tonumber(defs.field(e.value, "add")) or 0) - (tonumber(defs.field(e.value, "subtract")) or 0)
                local cond = {}
                for _, x in ipairs(e.value) do
                    if not (x.op and (x.key.text == "add" or x.key.text == "subtract" or x.key.text == "factor")) then
                        cond[#cond + 1] = x
                    end
                end
                local ok, holds = pcall(eval.trigger, cond, ctx)
                if ok and holds then
                    max = max + add
                end
            end
        end
    end
    local m = economy.modifiers("country", country) or {}
    return max + (m.country_resource_max_add or 0) + (m["country_resource_max_" .. r .. "_add"] or 0)
end

function economy.monthly()
    local before = economy.before_growth
    economy.before_growth = false
    economy.compute()
    economy.before_growth = before
    for _, country in ipairs(world.all("country")) do
        local c = world.object("country", country)
        local module = world.path(c, "modules", "standard_economy_module")
        local stock = type(module) == "table" and world.child(module, "resources")
        if budgets[country] and stock then
            local balance = economy.balance(country)
            for _, r in ipairs(resources) do
                local v = balance[r]
                if v and v ~= 0 and not r:find("_research$") then
                    local now = tonumber(world.field(stock, r)) or 0
                    local new = math.max(0, now + v)
                    local cap = economy.capacity(country, r)
                    if cap and new > cap then
                        new = math.max(now, cap)  -- a cap stops growth; it does not take away
                    end
                    -- the stockpile is fixed point, 5 decimals
                    world.set(stock, r, math.floor(new * 100000 + 0.5) / 100000)
                end
            end
        end
    end
    economy.last_month = budgets
    budgets = nil
    return economy.last_month
end

-- ---------------------------------------------------------------------------------------------
-- the check against the save's budget.current_month

local function save_budget(country)
    local c = world.object("country", country)
    local cm = world.path(c, "budget", "current_month")
    local out = { income = {}, expenses = {} }
    if type(cm) ~= "table" then
        return nil
    end
    for side in pairs(out) do
        local s = world.field(cm, side)
        for _, e in ipairs(type(s) == "table" and s or {}) do
            if e.op and e.key and e.value.text == nil then
                local res = {}
                for _, x in ipairs(e.value) do
                    if x.op and x.key then
                        res[x.key.text] = tonumber(x.value.text) or 0
                    end
                end
                out[side][e.key.text] = res
            end
        end
    end
    return out
end
economy.save_budget = save_budget

-- economy.check([rel]) -> report: every (country, side, category, resource) of the save's
-- budgets and of the computed ones, matched within rel (0.1%) or 1e-4
function economy.check(rel)
    rel = rel or 0.001
    if not economy.before_growth then
        economy.before_growth = true
        budgets = nil
    end
    ensure()
    local entries = {}
    for _, country in ipairs(world.all("country")) do
        local want = save_budget(country)
        if want then
            local got = budgets[country] or { income = {}, expenses = {} }
            for _, side in ipairs({ "income", "expenses" }) do
                local keys = {}
                for cat, res in pairs(want[side]) do
                    for r in pairs(res) do keys[cat .. "\0" .. r] = true end
                end
                for cat, res in pairs(got[side]) do
                    for r, v in pairs(res) do
                        if math.abs(v) > 1e-9 then keys[cat .. "\0" .. r] = true end
                    end
                end
                for k in pairs(keys) do
                    local cat, r = k:match("^(.-)%z(.*)$")
                    local w = want[side][cat] and want[side][cat][r] or 0
                    local g = got[side][cat] and got[side][cat][r] or 0
                    local ok = math.abs(g - w) <= math.max(rel * math.abs(w), 1e-4)
                    entries[#entries + 1] = { country = country, side = side, cat = cat, res = r, want = w, got = g, ok = ok }
                end
            end
        end
    end
    local report = { entries = entries, total = #entries, matched = 0, by_cat = {} }
    for _, e in ipairs(entries) do
        local c = report.by_cat[e.cat]
        if c == nil then
            c = { total = 0, matched = 0, abs = 0 }
            report.by_cat[e.cat] = c
        end
        c.total = c.total + 1
        c.abs = c.abs + math.abs(e.want)
        if e.ok then
            c.matched = c.matched + 1
            report.matched = report.matched + 1
        end
    end
    return report
end

-- economy.format_check(report[, n]) -> text: the shares overall and per category, the n biggest
-- differences
function economy.format_check(report, n)
    n = n or 40
    local lines = {}
    lines[#lines + 1] = string.format("economy: %d of %d budget entries within 0.1%% (%.1f%%)", report.matched,
        report.total, 100 * report.matched / math.max(1, report.total))
    local list = {}
    for cat, c in pairs(report.by_cat) do
        list[#list + 1] = { cat = cat, c = c }
    end
    table.sort(list, function(a, b)
        if a.c.total ~= b.c.total then return a.c.total > b.c.total end
        return a.cat < b.cat
    end)
    for _, x in ipairs(list) do
        lines[#lines + 1] = string.format("  %-40s %4d/%-4d %5.1f%%  (|save| %.1f)", x.cat, x.c.matched, x.c.total,
            100 * x.c.matched / x.c.total, x.c.abs)
    end
    local bad = {}
    for _, e in ipairs(report.entries) do
        if not e.ok then bad[#bad + 1] = e end
    end
    table.sort(bad, function(a, b) return math.abs(a.got - a.want) > math.abs(b.got - b.want) end)
    lines[#lines + 1] = string.format("biggest differences (%d entries off):", #bad)
    for i = 1, math.min(n, #bad) do
        local e = bad[i]
        lines[#lines + 1] = string.format("  country %-10d %-8s %-36s %-22s save %12.5f  computed %12.5f", e.country, e.side,
            e.cat, e.res, e.want, e.got)
    end
    return table.concat(lines, "\n")
end

return economy
