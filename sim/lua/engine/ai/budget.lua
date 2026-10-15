-- engine/ai/budget.lua : the AI's budget (docs/ai_economy.md section 2), CCountryAI::MonthlyUpdate
-- (GOG 4.5.2 0xb6ddc0) on the AI's month: SetBudgetArraySize, UpdateUpkeepBudget (0xb70af0),
-- UpdateExpenditureBudget (0xb716b0), with common/ai_budget.
--
-- Per resource, the entries of that resource and type (upkeep 1, expenditure 2) whose potential
-- holds add per budget category (the entry's category) W += weight, MAX += desired_max, MIN +=
-- desired_min; total = sum of W. Then, with S the amount split:
--
--   expenditure: S = the stockpile (CEconomyCountryModule::GetResource)
--   upkeep:      S = last month's summed income (CCountryBudget _LastMonth._Total._SummedIncome);
--                no split at all when total <= 0
--
--   pass 1, each category with W > 0 or MIN > 0:  S <= 0 -> f = 0; else
--       a = (W / total) * S                       (fixed point, truncated)
--       a = min(a, max(resource) * W / total)      (resources with a max: GetMaximumForCountry)
--       MAX <= 0 -> MAX = a;  a < MIN -> a = MIN, else a = min(a, MAX);  a = min(a, S)
--       f = a / S;  F += f
--   pass 2: budget[cat][res] = f > 0 ? max(S * f / F, min(MIN, S)) : 0
--
-- so the whole of S is handed out in proportion to the clamped shares. The budgets are not saved:
-- the save's `ai.budget = { 0 0 0 0 }` is CAICore::_Budget (+0x358, 32 bytes), which only
-- CAICore::CreateBudget writes (zeros); it is left as it is. After a load the arrays are empty
-- until the AI's first month (CanAfford* fail: the index is past the array), as in the game.
--
-- Spending (docs/ai_economy.md section 4):
--   budget.can_afford_expenditure(country, category, cost)   CCountryAI::CanAffordExpenditure (0xb78f00)
--   budget.can_afford_upkeep(country, category, upkeep)      CCountryAI::CanAffordUpkeep (0xb791c0)
--   budget.withdraw(country, category, cost)                 CCountryAI::WithdrawCost (0xb79ba0)
-- with costs as { [res] = number }.

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local defs = require("engine.defs")
local eval = require("simscript.eval")
local fp = require("engine.ai.economy.fixed")
local cats = require("engine.ai.economy.categories")

local budget = {
    stats = { months = 0, potential_errors = 0, withdrawn = 0, affordable = 0, unaffordable = 0 },
    state = {}, -- country -> { expenditure = { [cat] = { [res] = raw } }, upkeep, cached_upkeep, date }
}

local UPKEEP, EXPENDITURE = 1, 2

-- ---------------------------------------------------------------------------------------------
-- the definitions

local ENTRIES -- in database order (files in load order, entries in file order)
local function entries()
    if ENTRIES then
        return ENTRIES
    end
    local list = {}
    for name, d in pairs(defs.folder("common/ai_budget")) do
        slice.tick("ai/budget.lua:53")
        local b = d.block
        local ty = defs.field(b, "type")
        list[#list + 1] = {
            name = name, file = d.file or "", line = d.line or 0,
            resource = defs.field(b, "resource"),
            type = ty == "upkeep" and UPKEEP or ty == "expenditure" and EXPENDITURE or 0,
            category = defs.field(b, "category"),
            potential = defs.field(b, "potential"),
            weight = defs.field(b, "weight"),
            desired_min = defs.field(b, "desired_min"),
            desired_max = defs.field(b, "desired_max"),
        }
    end
    table.sort(list, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    ENTRIES = list
    return list
end

local function resources()
    local economy = require("engine.economy")
    economy.init()
    return economy.resources
end

-- a CScriptableValue (weight / desired_min / desired_max): a number, or a block with a base
-- (`weight`, `base`) and `modifier = { factor add <triggers> }` applied in order (eval.weight);
-- no block is 0; a block without a base starts at `default` (1 for a weight, 0 for a minimum or
-- maximum: `desired_min = { modifier = { add = 250 ... } }` in 01_alloys_budget)
local function scriptable(block, ctx, default)
    if block == nil then
        return 0
    end
    if type(block) ~= "table" then
        return tonumber(block) or 0
    end
    local ok, v = pcall(eval.weight, block, ctx, default or 0)
    if not ok then
        budget.stats.potential_errors = budget.stats.potential_errors + 1
        return 0
    end
    return v or 0
end

local function potential(e, ctx)
    if type(e.potential) ~= "table" then
        return true
    end
    local ok, holds = pcall(eval.trigger, e.potential, ctx)
    if not ok then
        budget.stats.potential_errors = budget.stats.potential_errors + 1
        return false
    end
    return holds and true or false
end

-- ---------------------------------------------------------------------------------------------
-- what is split

local function stockpile(country, res)
    local c = world.object("country", country)
    return tonumber(world.path(c, "modules", "standard_economy_module", "resources", res)) or 0
end

-- a budget page of the save (`budget = { last_month = { income = { cat = { res = v } } ... } }`):
-- { income = { [cat] = { [res] = v } }, expenses = ... } with the trade tables added in
local function save_page(country, page)
    local c = world.object("country", country)
    local p = world.path(c, "budget", page)
    if type(p) ~= "table" then
        return nil
    end
    local out = { income = {}, expenses = {} }
    for _, pair in ipairs({ { "income", "income" }, { "expenses", "expenses" }, { "trade_income", "income" },
        { "trade_expenses", "expenses" } }) do
        local s = world.field(p, pair[1])
        if type(s) == "table" then
            for cat, v in world.statements(s) do
                slice.tick("ai/budget.lua:133")
                if type(v) == "table" then
                    local t = out[pair[2]][cat] or {}
                    for res, x in world.statements(v) do
                        slice.tick("ai/budget.lua:136")
                        t[res] = (t[res] or 0) + (type(x) ~= "table" and tonumber(x) or 0)
                    end
                    out[pair[2]][cat] = t
                end
            end
        end
    end
    return out
end

-- the country's last month (CCountryBudget::_LastMonth): the simulation's month once it ran one
-- (engine.economy.last_month), else the save's `budget.last_month`
function budget.last_month(country)
    local economy = package.loaded["engine.economy"]
    local lm = economy and economy.last_month and economy.last_month[country]
    if lm then
        return lm
    end
    return save_page(country, "last_month") or { income = {}, expenses = {} }
end

local function summed(side)
    local out = {}
    for _, t in pairs(side or {}) do
        slice.tick("ai/budget.lua:160")
        for r, v in pairs(t) do
            slice.tick("ai/budget.lua:161")
            out[r] = (out[r] or 0) + v
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the split (UpdateUpkeepBudget / UpdateExpenditureBudget)

local function split(country, kind, ctx, out)
    local list = entries()
    local income = kind == UPKEEP and summed(budget.last_month(country).income) or nil
    local economy = require("engine.economy")
    for _, res in ipairs(resources()) do
        slice.tick("ai/budget.lua:175")
        local W, MAX, MIN, order = {}, {}, {}, {}
        local total = 0
        for _, e in ipairs(list) do
            slice.tick("ai/budget.lua:178")
            if e.type == kind and e.resource == res and e.category and cats.get(e.category) and potential(e, ctx) then
                local cat = e.category
                if W[cat] == nil then
                    W[cat], MAX[cat], MIN[cat] = 0, 0, 0
                    order[#order + 1] = cat
                end
                local w = fp.from(scriptable(e.weight, ctx, 1))
                W[cat] = W[cat] + w
                total = total + w
                MAX[cat] = MAX[cat] + fp.from(scriptable(e.desired_max, ctx))
                MIN[cat] = MIN[cat] + fp.from(scriptable(e.desired_min, ctx))
            end
        end
        -- the upkeep split stops at a total of 0; the expenditure split goes on (a share of
        -- 42949.67295 then, the game's 0xffffffff, for a minimum without a weight)
        if not (kind == UPKEEP and total <= 0) then
            local S = fp.from(kind == UPKEEP and (income[res] or 0) or stockpile(country, res))
            local cap = economy.capacity(country, res)
            local F, f = 0, {}
            for _, cat in ipairs(order) do
                slice.tick("ai/budget.lua:198")
                f[cat] = W[cat]
                if W[cat] > 0 or MIN[cat] > 0 then
                    if S <= 0 then
                        f[cat] = 0
                    else
                        local share = total ~= 0 and fp.div(W[cat], total) or 4294967295
                        local a = fp.mul(share, S)
                        if cap then
                            local m = fp.mul(fp.from(cap), share)
                            if m < a then a = m end
                        end
                        local mx = MAX[cat] > 0 and MAX[cat] or a
                        if a < MIN[cat] then
                            a = MIN[cat]
                        elseif a > mx then
                            a = mx
                        end
                        if a > S then a = S end
                        f[cat] = fp.div(a, S)
                        F = F + f[cat]
                    end
                end
            end
            for _, cat in ipairs(order) do
                slice.tick("ai/budget.lua:222")
                local t = out[cat]
                if t == nil then
                    t = {}
                    out[cat] = t
                end
                if f[cat] > 0 then
                    local share = F ~= 0 and fp.div(f[cat], F) or 4294967295
                    local v = fp.mul(share, S)
                    local floor_ = MIN[cat] < S and MIN[cat] or S
                    t[res] = v > floor_ and v or floor_
                else
                    t[res] = 0
                end
            end
        end
    end
end

-- CCountryAI::UpdateInternalUpkeepCache / CalcCurrentUpkeep: per budget category, last month's
-- expenses of the category and every category under it (AddBudgetCategoryExpense), plus the upkeep
-- of the country's queued construction in it (ProcessItemForUpkeep; see engine.ai.economy)
local function cached_upkeep(country)
    local expenses = budget.last_month(country).expenses or {}
    local out = {}
    local queued = package.loaded["engine.ai.economy"]
    queued = queued and queued.queued_upkeep and queued.queued_upkeep(country) or {}
    for name, c in pairs(cats.all()) do
        slice.tick("ai/budget.lua:249")
        if c.ai then
            local t = {}
            for _, sub in ipairs(cats.descendants(name)) do
                slice.tick("ai/budget.lua:252")
                for r, v in pairs(expenses[sub] or {}) do
                    slice.tick("ai/budget.lua:253")
                    t[r] = (t[r] or 0) + fp.from(v)
                end
                for r, v in pairs(queued[sub] or {}) do
                    slice.tick("ai/budget.lua:256")
                    t[r] = (t[r] or 0) + fp.from(v)
                end
            end
            out[name] = t
        end
    end
    return out
end

-- budget.monthly(country, today): the AI's month (engine.ai calls it on the country's month
-- counter, before the modules' monthly updates)
function budget.monthly(country, today, commands, host)
    local ctx = eval.new_ctx(eval.S("country", country), nil, nil, "common/ai_budget")
    local b = { expenditure = {}, upkeep = {}, date = today }
    require("engine.ai.economy.script").with(function()
        split(country, UPKEEP, ctx, b.upkeep)
        b.cached_upkeep = cached_upkeep(country)
        split(country, EXPENDITURE, ctx, b.expenditure)
    end)
    budget.state[country] = b
    budget.stats.months = budget.stats.months + 1
    return b
end

-- ---------------------------------------------------------------------------------------------
-- spending

local function nonzero(cost)
    for _, v in pairs(cost or {}) do
        slice.tick("ai/budget.lua:285")
        if v ~= 0 then return true end
    end
    return false
end

-- CanAffordExpenditure (0xb78f00): every resource of the cost within the budget of its budget
-- category (the category to use, or its parent for resources it hands up)
function budget.can_afford_expenditure(country, category, cost)
    local b = budget.state[country]
    if not b then
        return false
    end
    if not nonzero(cost) then
        return true
    end
    local cat = cats.to_use(category)
    for r, c in pairs(cost) do
        slice.tick("ai/budget.lua:302")
        local bc = cats.for_expenditure(cat, r)
        local have = (b.expenditure[bc] or {})[r] or 0
        local want = fp.from(c)
        if want > 0 and have < want then
            budget.stats.unaffordable = budget.stats.unaffordable + 1
            return false
        end
    end
    budget.stats.affordable = budget.stats.affordable + 1
    return true
end

-- CanAffordUpkeep (0xb791c0): with U = the category's current upkeep (the cache) + the new upkeep,
-- for every resource of the new upkeep: U within the upkeep budget of its budget category
function budget.can_afford_upkeep(country, category, upkeep)
    local b = budget.state[country]
    if not b then
        return false
    end
    if not nonzero(upkeep) then
        return true
    end
    local cat = cats.to_use(category)
    local cached = b.cached_upkeep[cat] or {}
    local any = false
    for r, u in pairs(upkeep) do
        slice.tick("ai/budget.lua:328")
        if u > 0 then
            any = true
        end
    end
    if not any then
        return true
    end
    for r, u in pairs(upkeep) do
        slice.tick("ai/budget.lua:336")
        local U = fp.from(u)
        if U ~= 0 then
            U = U + (cached[r] or 0)
        end
        local bc = cats.for_upkeep(cat, r)
        local have = (b.upkeep[bc] or {})[r] or 0
        if have >= 0 then
            if have < U then return false end
        elseif U > 0 then
            return false
        end
    end
    return true
end

-- WithdrawCost (0xb79ba0): each resource of the cost taken from its budget category's budget
function budget.withdraw(country, category, cost)
    local b = budget.state[country]
    if not b then
        return
    end
    local cat = cats.to_use(category)
    for r, c in pairs(cost or {}) do
        slice.tick("ai/budget.lua:359")
        local bc = cats.for_expenditure(cat, r)
        local t = b.expenditure[bc]
        if t == nil then
            t = {}
            b.expenditure[bc] = t
        end
        t[r] = (t[r] or 0) - fp.from(c)
    end
    budget.stats.withdrawn = budget.stats.withdrawn + 1
end

-- budget.get(country, kind, category, res) -> the budget as a number (kind "expenditure" or "upkeep")
function budget.get(country, kind, category, res)
    local b = budget.state[country]
    local t = b and b[kind] and b[kind][category]
    return t and t[res] and fp.to(t[res]) or 0
end

function budget.report()
    local s = budget.stats
    return string.format("ai budget: %d country-months, %d potential/value errors; %d affordable, %d not; %d withdrawals",
        s.months, s.potential_errors, s.affordable, s.unaffordable, s.withdrawn)
end

return budget
