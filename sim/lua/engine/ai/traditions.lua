-- engine/ai/traditions.lua : the AI's choice of tradition and ascension perk (docs/traditions.md),
-- in CAIInteriorMinister::MonthlyUpdate (GOG 4.5.2 0xbb40f0) when the country type's AI has
-- `traditions` (and the country was not human recently):
--
-- HandleTraditions (0xbc3250):
--
--   all_completed = every adopted category has its finisher (true with none)
--   all_completed and #categories >= TRADITION_CATEGORIES_MAX: nothing (no draw)
--   for each tradition t of the database, in order, not adopted, with a category c:
--     c not adopted and not all_completed: skipped        (a new category only once all are done)
--     c not adopted and t is not c's adoption: skipped
--     cost = CTraditionType::CalcCost(country)              (the same for every t)
--     t is c's adoption: if c is potential and t possible (IsPossible):
--         the "traditions" budget cannot afford the cost: stop (no draw)
--         w[t] = c's ai_weight                              (CTraditionCategory::CalcAIWeight)
--     c adopted: if t's `possible` holds (FulfillsPossibleTrigger; not the full IsPossible):
--         the budget cannot afford the cost: stop (no draw)
--         w[t] = t's ai_weight                              (CTraditionType::CalcAIWeight)
--   r = the unsynced AI draw (CAICore::_Random, inline)
--   i = GetWeightedRandomInternal(w as CFixedPoint integers, r, fallback none)
--   t = the database's i-th; CanActivate (possible, the cost in the stockpile): post
--   CCountryActivateTraditionCommand (executed after every AI decided: engine.traditions.activate)
--
-- The budget (CCountryAI::CanAffordExpenditure, 0xb78f00) is the AI's expenditure budget of the
-- economic category `traditions` for each resource of the cost, made at the start of the same AI
-- month (CCountryAI::MonthlyUpdate -> UpdateExpenditureBudget, 0xb716b0) from the stockpile and
-- the common/ai_budget expenditure entries of the resource (here, for unity: traditions weight 0.8
-- with desired_min 100000, so the whole stockpile; edicts 0.2 above 300; megastructures):
-- engine.ai.budget's when that module is there, else the same split computed here.
--
-- HandleAscensionPerks (0xbc3880), when the type's AI has `ascension_perks` and the country has a
-- free perk slot (CalcTotalAscensionPerkPoints - its perks > 0): the perks (database order) that
-- CanActivate (slots checked) with a positive ai_weight; one unsynced draw (made even when the list
-- is empty); the weighted pick; CanActivate again; CCountryActivateAscensionPerkCommand.

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")
local traditions = require("engine.traditions")
local rng = require("engine.ai.rng")

local M = {
    stats = { months = 0, maxed = 0, no_budget = 0, draws = 0, none = 0, cannot = 0, picks = 0,
        perk_months = 0, perk_picks = 0 },
    picks = {},     -- { country, tradition, date, candidates = { {name, weight} } }
    months = {},    -- { country, date, outcome } (the AI months seen, for the check)
}

-- ---------------------------------------------------------------------------------------------
-- the AI's expenditure budget (CCountryAI::UpdateExpenditureBudget for one resource)

local entries_cache = {}
local function budget_entries(resource)
    local list = entries_cache[resource]
    if list == nil then
        list = {}
        local all = {}
        for name, d in pairs(defs.folder("common/ai_budget")) do
            all[#all + 1] = { name = name, def = d }
        end
        table.sort(all, function(a, b)
            if a.def.file ~= b.def.file then return tostring(a.def.file) < tostring(b.def.file) end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
        for _, e in ipairs(all) do
            local b = e.def.block
            if defs.field(b, "resource") == resource and defs.field(b, "type") == "expenditure" then
                list[#list + 1] = { name = e.name, block = b, file = e.def.file, category = defs.field(b, "category") }
            end
        end
        entries_cache[resource] = list
    end
    return list
end

-- a value block of a budget entry (CMeanTimeToHappen::GetRawFactor): 0 without one
local function raw_factor(block, ctx)
    if type(block) == "string" then
        local ok, v = pcall(eval.value, { text = block }, ctx)
        return ok and tonumber(v) or tonumber(block) or 0
    elseif type(block) ~= "table" then
        return 0
    end
    local ok, v = pcall(eval.weight, block, ctx, 1)
    return ok and v or 0
end

-- M.expenditure_budget(country, resource) -> { [category] = amount }: per category, the share of
-- the stockpile S. Pass 1: a = S * W / total (W the category's summed weight), at least the
-- desired minimum, at most the desired maximum (a itself without one), at most S; its fraction
-- f = a / S. Pass 2: the budget is max(S * f / sum f, min(desired minimum, S)).
function M.expenditure_budget(country, resource)
    local W, MIN, MAX, order, total = {}, {}, {}, {}, 0
    for _, e in ipairs(budget_entries(resource)) do
        local c = eval.new_ctx(eval.S("country", country), nil, nil, e.file)
        local potential = defs.field(e.block, "potential")
        local ok, holds = true, true
        if type(potential) == "table" then
            ok, holds = pcall(eval.trigger, potential, c)
        end
        if ok and holds and e.category then
            if W[e.category] == nil then
                order[#order + 1] = e.category
                W[e.category], MIN[e.category], MAX[e.category] = 0, 0, 0
            end
            local w = raw_factor(defs.field(e.block, "weight"), c)
            W[e.category] = W[e.category] + w
            total = total + w
            MAX[e.category] = MAX[e.category] + raw_factor(defs.field(e.block, "desired_max"), c)
            MIN[e.category] = MIN[e.category] + raw_factor(defs.field(e.block, "desired_min"), c)
        end
    end
    local S = traditions.stockpile(country, resource)
    local out, frac, sum = {}, {}, 0
    for _, cat in ipairs(order) do
        out[cat] = 0
        if (W[cat] > 0 or MIN[cat] > 0) and S > 0 then
            -- (a total of 0 makes the share the raw 0xffffffff, as the game's zero-extended -1)
            local share = total ~= 0 and W[cat] / total or 42949.67295
            local a = share * S
            local max = MAX[cat] > 0 and MAX[cat] or a
            local v = a < MIN[cat] and MIN[cat] or math.min(a, max)
            v = math.min(v, S)
            frac[cat] = v / S
            sum = sum + frac[cat]
        end
    end
    for _, cat in ipairs(order) do
        local f = frac[cat]
        if f and f > 0 then
            local ratio = sum ~= 0 and f / sum or 42949.67295
            out[cat] = math.max(ratio * S, math.min(MIN[cat], S))
        end
    end
    return out
end

-- the AI's budget module (engine.ai.budget: CCountryAI::MonthlyUpdate's budgets, made on the AI's
-- month before the interior minister runs), when it is there
local budget_mod
local function budget_module()
    if budget_mod == nil then
        budget_mod = package.searchpath("engine.ai.budget", package.path) ~= nil and require("engine.ai.budget") or false
    end
    return budget_mod
end

-- CCountryAI::CanAffordExpenditure(category, cost): for each resource of the cost, the category's
-- budget of it at least the cost (a negative budget with no cost is no obstacle). The budget made
-- this AI month by engine.ai.budget when there is one, else the split computed here.
local function can_afford_expenditure(country, category, cost)
    local b = budget_module()
    if b and b.can_afford_expenditure and b.state and b.state[country] then
        return b.can_afford_expenditure(country, category, cost)
    end
    for r, v in pairs(cost) do
        if v ~= 0 then
            local budget = M.expenditure_budget(country, r)[category] or 0
            if (budget >= 0 or v > 0) and budget < v then
                return false
            end
        end
    end
    return true
end
M.can_afford_expenditure = can_afford_expenditure

-- ---------------------------------------------------------------------------------------------
-- the weights

local function weight_of(block, id, file)
    if type(block) ~= "table" then
        return 1   -- the CMeanTimeToHappen's default factor (1.0)
    end
    local ok, v = pcall(eval.weight, block, eval.new_ctx(eval.S("country", id), nil, nil, file), 1)
    return ok and v or 0
end
-- CTraditionCategory::CalcAIWeight / CTraditionType::CalcAIWeight: the ai_weight block's factor
function M.category_weight(id, cat)
    local c = traditions.category(cat)
    return weight_of(defs.field(c.block, "ai_weight"), id, c.file)
end
function M.tradition_weight(id, name)
    local t = traditions.type(name)
    return weight_of(defs.field(t.block, "ai_weight"), id, t.file)
end

-- a CFixedPoint as its integer (1.0 = 100000)
local function fixed(x)
    return math.floor(x * 100000 + 0.5)
end

-- GetWeightedRandomInternal with the fallback "none": nil when no weight is positive
local function pick(weights, r)
    local total = 0
    for i = 1, #weights do
        if weights[i] > 0 then total = total + weights[i] end
    end
    if total <= 0 then
        return nil
    end
    return rng.weighted(weights, r)
end

-- ---------------------------------------------------------------------------------------------
-- HandleTraditions

local function command(country, name, host)
    return {
        kind = "tradition", country = country, tradition = name, host = host,
        execute = function(cmd, today)
            return traditions.activate(cmd.country, cmd.tradition, cmd.host, today)
        end,
    }
end

function M.handle_traditions(country, today, commands, host)
    M.stats.months = M.stats.months + 1
    local D = traditions.defines()
    local cats = traditions.categories_of(country)
    local all_completed = true
    for _, cat in ipairs(cats) do
        if not traditions.completed_category(country, cat) then
            all_completed = false
        end
    end
    if all_completed and #cats >= D.TRADITION_CATEGORIES_MAX then
        M.stats.maxed = M.stats.maxed + 1
        M.months[#M.months + 1] = { country = country, date = today, outcome = "maxed" }
        return
    end
    local adopted = {}
    for _, n in ipairs(traditions.of(country)) do adopted[n] = true end
    local cat_index = {}
    for i, cat in ipairs(cats) do cat_index[cat] = i end
    local types = traditions.types()
    local weights, candidates = {}, {}
    for i = 1, #types do weights[i] = 0 end
    local cost
    for i, t in ipairs(types) do
        local c = not adopted[t.name] and t.category and traditions.category(t.category)
        if c then
            local idx = cat_index[c.name]
            if (all_completed or idx) and (idx or c.adoption == t.name) then
                cost = cost or traditions.cost(country, t.name)
                if c.adoption == t.name and traditions.category_potential(country, c.name)
                    and traditions.is_possible(country, t.name) then
                    if not can_afford_expenditure(country, "traditions", cost) then
                        M.stats.no_budget = M.stats.no_budget + 1
                        M.months[#M.months + 1] = { country = country, date = today, outcome = "budget", unity = traditions.stockpile(country, "unity") }
                        return
                    end
                    weights[i] = fixed(M.category_weight(country, c.name))
                    candidates[#candidates + 1] = { t.name, weights[i] / 100000 }
                end
                if idx and traditions.fulfills_possible(country, t.name) then
                    if not can_afford_expenditure(country, "traditions", cost) then
                        M.stats.no_budget = M.stats.no_budget + 1
                        M.months[#M.months + 1] = { country = country, date = today, outcome = "budget", unity = traditions.stockpile(country, "unity") }
                        return
                    end
                    weights[i] = fixed(M.tradition_weight(country, t.name))
                    candidates[#candidates + 1] = { t.name, weights[i] / 100000 }
                end
            end
        end
    end
    local r = rng.draw(country)
    M.stats.draws = M.stats.draws + 1
    local i = pick(weights, r)
    if not i then
        M.stats.none = M.stats.none + 1
        M.months[#M.months + 1] = { country = country, date = today, outcome = "none" }
        return
    end
    local name = types[i].name
    if not traditions.can_activate(country, name, true) then
        M.stats.cannot = M.stats.cannot + 1
        M.months[#M.months + 1] = { country = country, date = today, outcome = "cannot " .. name }
        return
    end
    M.stats.picks = M.stats.picks + 1
    M.picks[#M.picks + 1] = { country = country, tradition = name, date = today, candidates = candidates,
        unity = traditions.stockpile(country, "unity"), cost = select(2, traditions.cost(country, name)) }
    M.months[#M.months + 1] = { country = country, date = today, outcome = "pick " .. name }
    commands[#commands + 1] = command(country, name, host)
end

-- ---------------------------------------------------------------------------------------------
-- HandleAscensionPerks

function M.handle_perks(country, today, commands, host)
    M.stats.perk_months = M.stats.perk_months + 1
    local list, weights = {}, {}
    for _, t in ipairs(traditions.perk_types()) do
        if traditions.can_activate(country, t.name, true) then
            local w = fixed(weight_of(defs.field(t.block, "ai_weight"), country, t.file))
            if w > 0 then
                list[#list + 1] = t.name
                weights[#weights + 1] = w
            end
        end
    end
    local r = rng.draw(country)
    M.stats.draws = M.stats.draws + 1
    local i = pick(weights, r)
    if not i then
        return
    end
    local name = list[i]
    if not traditions.can_activate(country, name, true) then
        return
    end
    M.stats.perk_picks = M.stats.perk_picks + 1
    M.picks[#M.picks + 1] = { country = country, tradition = name, date = today, perk = true }
    commands[#commands + 1] = {
        kind = "ascension_perk", country = country, tradition = name, host = host,
        execute = function(cmd, d)
            return traditions.activate(cmd.country, cmd.tradition, cmd.host, d)
        end,
    }
end

-- ---------------------------------------------------------------------------------------------
-- the AI's month (engine.ai: the interior minister's monthly update, in its module order)

-- the country type's AI flags `traditions` (bit 6) and `ascension_perks` (bit 16) of
-- SCountryAISettings (engine.ai.setting): both off in the constructor's default, so on only with
-- `ai = { traditions = yes }` (the default country type has both; fallen empires neither)
function M.setting(country, key)
    return require("engine.ai").setting(country, key)
end

-- STELLAR_AI_TRADITIONS=off turns this module off (to measure a run without it)
local off = os.getenv("STELLAR_AI_TRADITIONS") == "off"

function M.monthly(country, today, commands, host)
    if off or not M.setting(country, "traditions") then
        return
    end
    M.handle_traditions(country, today, commands, host)
    if M.setting(country, "ascension_perks")
        and traditions.perk_points(country) - #traditions.perks_of(country) > 0 then
        M.handle_perks(country, today, commands, host)
    end
    -- (HandlePlanetaryAscension follows in the game: not ported)
end

function M.report()
    local s = M.stats
    return string.format("ai traditions: %d months (%d at the category limit, %d over budget, %d with nothing), %d draws, %d picks (%d not activatable); perks: %d months, %d picks",
        s.months, s.maxed, s.no_budget, s.none, s.draws, s.picks, s.cannot, s.perk_months, s.perk_picks)
end

return M
