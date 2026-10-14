-- engine/ai/economy/plans.lua : the AI's economic plans (common/economic_plans) and its income
-- targets, docs/ai_economy.md section 3.
--
--   CAIEconomicStrategy::CalcBestEconomicPlan (0xb4c190): one unsynced AI draw (the scope seed of
--       the ai_weight modifiers); of the potential plans with a weight > 0, the heaviest unfulfilled
--       one, else the lightest (first in database order on ties)
--   CAIEconomicPlan::IsFulfilled (0xb51520): last month's net income covers every positive target
--       of CalculateIncomeTarget(noScale)
--   CAIEconomicPlan::CalculateIncomeTarget (0xb51600): income + the plain subplans; with a forecast,
--       the scaling subplans again and again while the forecast covers the target; + the optional
--       subplans; + the optional scaling ones times the passes
--   GetFocus (0xb52b60), GetPops (0xb52c90), GetNavalCap (0xb52f80)
--   CAIEconomicStrategy::CalculateIncomeTargetBasedOnForecast (0xb44050): the tables the build
--       weights read: income target T, needed N = T - F, current income F, focus, deficit -F
--   CCountryAI::UpdateIncomeTargetRecords (0xb7be60): the save's ai_resource_target_records and
--       last_valid_resource_targets / floors

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")
local fp = require("engine.ai.economy.fixed")
local rng = require("engine.ai.rng")

local plans = { stats = { picks = {}, draws = 0, record_updates = 0 } }

local function resources()
    local economy = require("engine.economy")
    economy.init()
    return economy.resources
end

-- ---------------------------------------------------------------------------------------------
-- reading the plans (CAIEconomicPlan::ReadMember 0xb50da0)

local function value_of(v, file)
    if v == nil then
        return 0
    end
    if v.text then
        local n = tonumber(v.text)
        if n then
            return n
        end
        local ok, r = pcall(eval.value, v, eval.new_ctx(eval.NONE, nil, nil, file))
        return ok and r or 0
    end
    return 0
end

local function resource_table(block, file)
    local t = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key then
            t[e.key.text] = (t[e.key.text] or 0) + value_of(e.value, file)
        end
    end
    return t
end

local function read_plan(block, file, name)
    local p = { name = name, file = file, income = {}, focus = {}, pops = 0, naval_cap = 0, subplans = {} }
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text
            if k == "ai_weight" then
                p.weight = e.value
            elseif k == "potential" then
                p.potential = e.value
            elseif k == "income" then
                for r, v in pairs(resource_table(e.value, file)) do p.income[r] = v end
            elseif k == "focus" then
                for r, v in pairs(resource_table(e.value, file)) do p.focus[r] = v end
            elseif k == "pops" then
                p.pops = math.floor(value_of(e.value, file))
            elseif k == "naval_cap" then
                p.naval_cap = math.floor(value_of(e.value, file))
            elseif k == "set_name" then
                p.name = e.value.text
            elseif k == "scaling" then
                p.scaling = e.value.text == "yes"
            elseif k == "optional" then
                p.optional = e.value.text == "yes"
            elseif k == "subplan" and e.value.text == nil then
                local s = read_plan(e.value, file, nil)
                -- a subplan with a name already there replaces it (the last one moved in its place)
                local dup
                for i, o in ipairs(p.subplans) do
                    if o.name == s.name then dup = i end
                end
                if dup then
                    p.subplans[dup] = p.subplans[#p.subplans]
                    p.subplans[#p.subplans] = nil
                end
                p.subplans[#p.subplans + 1] = s
            end
        end
    end
    return p
end

local PLANS
function plans.all()
    if PLANS then
        return PLANS
    end
    local db = require("simscript.db")
    local source = require("stellar.script.source")
    local list = {}
    for name, d in pairs(defs.folder("common/economic_plans")) do
        list[#list + 1] = { name = name, d = d }
    end
    table.sort(list, function(a, b)
        if a.d.file ~= b.d.file then return (a.d.file or "") < (b.d.file or "") end
        return (a.d.line or 0) < (b.d.line or 0)
    end)
    PLANS = {}
    for _, x in ipairs(list) do
        local block = source.expand(db.fs, x.d.block, {}, 0, "file: " .. tostring(x.d.file))
        PLANS[#PLANS + 1] = read_plan(block, x.d.file, x.name)
        PLANS[#PLANS].key = x.name
    end
    return PLANS
end

-- ---------------------------------------------------------------------------------------------
-- the plan functions

local function potential(p, ctx)
    if type(p.potential) ~= "table" or #p.potential == 0 then
        return true
    end
    local ok, holds = pcall(eval.trigger, p.potential, ctx)
    return ok and holds and true or false
end

local function subplans(p, ctx, scaling, optional)
    local out = {}
    for _, s in ipairs(p.subplans) do
        if (s.scaling or false) == scaling and (s.optional or false) == optional and potential(s, ctx) then
            out[#out + 1] = s
        end
    end
    return out
end

local function add_into(out, t, times)
    for r, v in pairs(t) do
        out[r] = (out[r] or 0) + v * (times or 1)
    end
end

local function covered(forecast, out)
    for r, v in pairs(out) do
        if v > 0 and (forecast[r] or 0) < v then
            return false
        end
    end
    return true
end

-- CalculateIncomeTarget(plan, country, forecast | nil, noScale) -> { [res] = target }
function plans.income_target(p, ctx, forecast, no_scale)
    local out = {}
    add_into(out, p.income)
    for _, s in ipairs(subplans(p, ctx, false, false)) do
        add_into(out, plans.income_target(s, ctx, forecast, no_scale))
    end
    local passes = 0
    if not no_scale and forecast and next(forecast) then
        local added = true
        while covered(forecast, out) and added and passes < 10000 do
            added = false
            for _, s in ipairs(subplans(p, ctx, true, false)) do
                local t = plans.income_target(s, ctx, forecast, false)
                local any = false
                for _, v in pairs(t) do
                    if v > 0 then any = true end
                end
                if any then
                    add_into(out, t)
                    added = true
                end
            end
            passes = passes + 1
        end
    end
    for _, s in ipairs(subplans(p, ctx, false, true)) do
        add_into(out, plans.income_target(s, ctx, forecast, no_scale))
    end
    if not no_scale then
        for _, s in ipairs(subplans(p, ctx, true, true)) do
            add_into(out, plans.income_target(s, ctx, forecast, false), passes)
        end
    end
    return out
end

function plans.focus(p, ctx)
    local out = {}
    add_into(out, p.focus)
    for _, s in ipairs(p.subplans) do
        if potential(s, ctx) then
            add_into(out, plans.focus(s, ctx))
        end
    end
    return out
end

-- GetPops / GetNavalCap: the plan's amount and its plain subplans', then the scaling subplans'
-- added until the amount passes the current one
local function amount(p, ctx, field, current)
    local n = p[field] or 0
    local scal = {}
    for _, s in ipairs(p.subplans) do
        if potential(s, ctx) then
            local v = amount(s, ctx, field, current)
            if v ~= 0 then
                if s.scaling then scal[#scal + 1] = s else n = n + v end
            end
        end
    end
    for _, s in ipairs(scal) do
        local v = amount(s, ctx, field, current)
        local guard = 0
        while current > n and v > 0 and guard < 100000 do
            n = n + v
            guard = guard + 1
        end
    end
    return n
end

function plans.pops(p, ctx, country)
    local c = world.object("country", country)
    return amount(p, ctx, "pops", tonumber(world.field(c, "num_sapient_pops")) or 0)
end

function plans.naval_cap(p, ctx, country)
    local c = world.object("country", country)
    return amount(p, ctx, "naval_cap", math.floor(tonumber(world.field(c, "naval_capacity")) or 0))
end

-- last month's net income per resource (CCountryBudget _LastMonth._Total._SummedBalance)
function plans.last_balance(country)
    local lm = require("engine.ai.budget").last_month(country)
    local out = {}
    for side, sign in pairs({ income = 1, expenses = -1 }) do
        for _, t in pairs(lm[side] or {}) do
            for r, v in pairs(t) do
                out[r] = (out[r] or 0) + sign * v
            end
        end
    end
    return out
end

-- this month's budget (CCountryBudget::_CurrentMonth): the save's `budget.current_month` until
-- the simulation ran a month, then the month it applied (engine.economy.last_month)
function plans.current_page(country)
    local economy = package.loaded["engine.economy"]
    if economy and economy.last_month and economy.last_month[country] then
        return economy.last_month[country]
    end
    return economy and economy.save_budget and economy.save_budget(country) or { income = {}, expenses = {} }
end

-- this month's projected net income (_CurrentMonth._Total._SummedBalance)
function plans.current_balance(country)
    local cm = plans.current_page(country)
    local out = {}
    for side, sign in pairs({ income = 1, expenses = -1 }) do
        for _, t in pairs(cm and cm[side] or {}) do
            for r, v in pairs(t) do
                out[r] = (out[r] or 0) + sign * v
            end
        end
    end
    return out
end

-- this month's expenses of a resource (resource_expenses_compare)
function plans.current_expenses(country, res)
    local v = 0
    for _, t in pairs(plans.current_page(country).expenses or {}) do
        v = v + (t[res] or 0)
    end
    return v
end

function plans.is_fulfilled(p, ctx, country)
    local t = plans.income_target(p, ctx, nil, true)
    local any = false
    for _, v in pairs(t) do
        if v ~= 0 then any = true end
    end
    if not any and #p.subplans == 0 then
        return true
    end
    local inc = plans.last_balance(country)
    for r, v in pairs(t) do
        if v > 0 and (inc[r] or 0) < v then
            return false
        end
    end
    return true
end

-- CalcBestEconomicPlan -> plan | nil
function plans.best(country)
    -- the draw that seeds the ai_weight modifiers' scope (unsynced AI generator)
    rng.draw(country)
    plans.stats.draws = plans.stats.draws + 1
    local ctx = eval.new_ctx(eval.S("country", country), nil, nil, "common/economic_plans")
    local best, bestw, low, loww
    for _, p in ipairs(plans.all()) do
        if potential(p, ctx) then
            local ok, w = pcall(eval.weight, p.weight or {}, ctx, 1)
            w = ok and fp.from(w) or 0
            if w > 0 then
                if not low or w < loww then low, loww = p, w end
                if (not best or w > bestw) and not plans.is_fulfilled(p, ctx, country) then
                    best, bestw = p, w
                end
            end
        end
    end
    local pick = best or low
    if pick then
        plans.stats.picks[pick.key] = (plans.stats.picks[pick.key] or 0) + 1
    end
    return pick
end

-- CalculateIncomeTargetBasedOnForecast -> { target, needed, current, focus, deficit } (numbers per
-- resource). The forecast's free jobs and build queue (CalculateEffectsOfFreeJobsAndBuildQueue)
-- are not added yet.
function plans.tables(p, country)
    local ctx = eval.new_ctx(eval.S("country", country), nil, nil, "common/economic_plans")
    local F = plans.current_balance(country)
    local T = plans.income_target(p, ctx, F, false)
    local t = { target = T, current = F, needed = {}, focus = plans.focus(p, ctx), deficit = {} }
    for _, r in ipairs(resources()) do
        t.needed[r] = (T[r] or 0) - (F[r] or 0)
        t.deficit[r] = -(F[r] or 0)
    end
    t.pops = plans.pops(p, ctx, country)
    t.naval_cap = plans.naval_cap(p, ctx, country)
    return t
end

-- ---------------------------------------------------------------------------------------------
-- UpdateIncomeTargetRecords: the save's ai_resource_target_records (+0x408),
-- last_valid_resource_targets (+0x428), ai_resource_target_floors (+0x440),
-- last_valid_resource_floors (+0x460)

local THR, EXP
local function defines()
    if THR == nil then
        local g = defs.get("common/defines", "NAI")
        THR = fp.from(g and tonumber(defs.field(g.block, "AI_RESOURCE_TARGET_VALID_THRESHOLD")) or 0.75)
        EXP = g and tonumber(defs.field(g.block, "AI_RESOURCE_TARGET_EXPIRATION_MONTHS")) or 24
    end
end

local function months(d)
    local y, m = tostring(d):match("^(%d+)%.(%d+)")
    return (tonumber(y) or 0) * 12 + (tonumber(m) or 1) - 1
end

local function read_table(block)
    local t = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.value.text then
            t[e.key.text] = fp.from(tonumber(e.value.text) or 0)
        end
    end
    return t
end

local function write_table(ai, key, t, after)
    local block = world.field(ai, key)
    if type(block) ~= "table" then
        if not next(t) then
            return
        end
        block = {}
        local pos
        for i, e in ipairs(ai) do
            if e.op and e.key and e.key.text == after then pos = i end
        end
        if pos then
            world.insert(ai, pos + 1, key, block)
        else
            world.append(ai, key, block)
        end
    end
    for i = #block, 1, -1 do
        block[i] = nil
    end
    world.wrote(block)
    for _, r in ipairs(resources()) do
        local v = t[r]
        if v and v ~= 0 then
            world.append(block, r, fp.to(v))
        end
    end
end

local function read_dates(block, n)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then out[#out + 1] = e.text end
    end
    if #out ~= n then
        out = {}
        for i = 1, n do out[i] = "0.01.01" end
    end
    return out
end

local function write_dates(ai, key, dates)
    local block = world.field(ai, key)
    if type(block) ~= "table" then
        block = {}
        world.append(ai, key, block)
    end
    for i = #block, 1, -1 do
        block[i] = nil
    end
    for _, d in ipairs(dates) do
        block[#block + 1] = { text = d, quoted = true }
    end
    world.wrote(block)
end

function plans.update_records(country, target, today)
    defines()
    local ai = world.field(world.object("country", country), "ai")
    if type(ai) ~= "table" then
        return
    end
    local res = resources()
    local n = #res
    local rec = read_table(world.field(ai, "ai_resource_target_records"))
    local flo = read_table(world.field(ai, "ai_resource_target_floors"))
    local rd = read_dates(world.field(ai, "last_valid_resource_targets"), n)
    local fd = read_dates(world.field(ai, "last_valid_resource_floors"), n)
    local now = months(today)
    for i, r in ipairs(res) do
        local T = fp.from(target[r] or 0)
        local R = rec[r] or 0
        if R > 0 or T > 0 then
            if fp.mul(R, THR) <= T then
                rec[r] = math.max(R, T)
                rd[i] = today
            elseif now - months(rd[i]) > EXP then
                rec[r] = math.max(T, 0)
            end
        end
        local L = flo[r] or 0
        if L < 0 or T < 0 then
            if fp.mul(L, THR) >= T then
                flo[r] = math.min(L, T)
                fd[i] = today
            elseif now - months(fd[i]) > EXP then
                flo[r] = math.min(T, 0)
            end
        end
    end
    write_table(ai, "ai_resource_target_records", rec)
    write_dates(ai, "last_valid_resource_targets", rd)
    write_table(ai, "ai_resource_target_floors", flo, "last_valid_resource_targets")
    write_dates(ai, "last_valid_resource_floors", fd)
    plans.stats.record_updates = plans.stats.record_updates + 1
end

return plans
