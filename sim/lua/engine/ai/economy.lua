-- engine/ai/economy.lua : the interior minister's economy (docs/ai_economy.md): the economic plan
-- and the build plan on the AI's month, the construction orders on its week.
--
-- Monthly (CAIInteriorMinister::MonthlyUpdate, GOG 4.5.2 0xbb40f0), when the country type's AI has
-- `construction` (SCountryAISettings bit 7): CAIEconomicStrategy::CalcBestEconomicPlan (0xb4c190)
-- then CreateBuildPlan (0xb423e0): the plan (engine.ai.economy.plan) is kept until the next week.
--
-- Weekly (CAIInteriorMinister::WeeklyUpdate 0xbb3d10 -> BuildAndUpgradeDistrictsAndBuildings
-- 0xbc1f90), when the AI has `construction`: nothing without a current economic plan or with an
-- empty build plan; else, in the plan's order:
--
--   the item fails lambda_1 (0xbc25c0)            -> stop
--       the colony is valid and has no building or district queued (HasQueuedBuildingOrDistrictConstruction),
--       its planet's queue is valid and not disabled, the buildable can be built,
--       CanAffordExpenditure(category, cost),
--       CanAffordUpkeep(category, upkeep of the resources it does not make) or
--       CanTradeForResources(that upkeep - last month's balance)
--   post CAddBuildableToQueueCommand (AddAICommandWithCostForPosting: the cost withdrawn from
--   the expenditure budget)
--   a district (or a zone into an occupied slot) -> the next item; anything else -> stop
--
-- and the build plan is emptied (RemoveAll), so a plan is used by one week. The commands execute
-- after every AI decided (engine.ai): the item is added to the planet's queue and the cost taken
-- from the stockpile (engine.ai.economy.orders); engine.construction builds it.

local world = require("engine.world")
local defs = require("engine.defs")
local budget = require("engine.ai.budget")
local B = require("engine.ai.economy.buildables")
local orders = require("engine.ai.economy.orders")

local M = {
    stats = { plans = 0, plan_items = 0, weeks = 0, posted = 0, executed = 0, failed = 0, stops = {} },
    plans = {},   -- country -> { items = { buildable ... } }, the build plan until the next week
    posted = {},  -- { date, country, kind, type, colony } of every command posted
}


local function stop(why)
    M.stats.stops[why] = (M.stats.stops[why] or 0) + 1
end

-- ---------------------------------------------------------------------------------------------
-- monthly: the plans

function M.monthly(country, today, commands, host)
    local ai = require("engine.ai")
    if not ai.setting(country, "construction") then
        return
    end
    local plan = require("engine.ai.economy.plan")
    local p = plan.create(country, today)
    M.plans[country] = p
    M.stats.plans = M.stats.plans + 1
    M.stats.plan_items = M.stats.plan_items + #(p and p.items or {})
end

-- ---------------------------------------------------------------------------------------------
-- weekly: the orders

local function last_balance(country)
    local lm = budget.last_month(country)
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

local ALLOWED_TO_BUY
local function allowed_to_buy()
    if ALLOWED_TO_BUY == nil then
        ALLOWED_TO_BUY = {}
        local g = defs.get("common/defines", "NAI")
        local v = g and defs.field(g.block, "AI_ALLOWED_TO_BUY")
        for _, e in ipairs(type(v) == "table" and v or {}) do
            if e.text then ALLOWED_TO_BUY[e.text] = true end
        end
    end
    return ALLOWED_TO_BUY
end

-- CAIEconomicStrategy::CanTradeForResources (0xb4c5c0): every resource short is one the AI may buy
-- (NAI AI_ALLOWED_TO_BUY) and the market sells it (CMarket::CanBuyResource: a tradable resource and
-- the energy for one unit; energy is what pays, so it is not bought)
local function can_trade_for(country, need)
    local allowed = allowed_to_buy()
    local c = world.object("country", country)
    local energy = tonumber(world.path(c, "modules", "standard_economy_module", "resources", "energy")) or 0
    for r, v in pairs(need) do
        if v > 0 then
            if not allowed[r] or r == "energy" or energy < 1 then
                return false
            end
        end
    end
    return true
end

-- lambda_1 of BuildAndUpgradeDistrictsAndBuildings: whether the item can be posted now
function M.can_post(country, b)
    local colony = world.object("colony", b.colony)
    local planet = world.object("planet", b.planet)
    if not (colony and planet) or tonumber(world.field(planet, "owner")) ~= country then
        return false, "colony"
    end
    local queue = B.queue(b)
    if not queue or B.has_queued_construction(queue) then
        return false, "queued construction"
    end
    local q = world.object("construction.queue_mgr.queues", queue)
    if not q or world.field(q, "disabled") == "yes" then
        return false, "queue"
    end
    local plan = require("engine.ai.economy.plan")
    if plan.can_build and not plan.can_build(country, b) then
        return false, "cannot build"
    end
    local category = B.category(b)
    b.cost = b.cost or B.cost(b)
    if not budget.can_afford_expenditure(country, category, b.cost) then
        return false, "expenditure"
    end
    -- the upkeep of the resources the buildable does not make itself (HandleCalcProduces: the
    -- upkeep of a resource with a net production >= 0 is left out)
    local up, made = B.upkeep(b), B.produces(b)
    local need = {}
    for r, v in pairs(up) do
        if (made[r] or 0) - v < 0 then
            need[r] = v
        end
    end
    if budget.can_afford_upkeep(country, category, need) then
        return true
    end
    local balance = last_balance(country)
    local short = {}
    for r, v in pairs(need) do
        short[r] = v - (balance[r] or 0)
    end
    if can_trade_for(country, short) then
        return true
    end
    return false, "upkeep"
end

local COST_ORDER
local function cost_order()
    if COST_ORDER == nil then
        local economy = require("engine.economy")
        economy.init()
        COST_ORDER = economy.resources
    end
    return COST_ORDER
end

-- the command: CAddBuildableToQueueCommand, executed after every AI decided
local function command(country, b, today)
    return {
        kind = "ai_add_buildable", country = country, buildable = b,
        execute = function(cmd, date)
            local o = cmd.buildable
            -- CAddBuildableToQueueCommand::IsValid at execution: the queue is there and the
            -- country can pay
            if not orders.can_pay(country, o.cost) then
                M.stats.failed = M.stats.failed + 1
                return false
            end
            local id, why = orders.add {
                country = country, queue = B.queue(o), kind = o.kind, fields = B.fields(o),
                cost = o.cost, cost_order = cost_order(), build_time = B.build_time(o),
            }
            if id then
                M.stats.executed = M.stats.executed + 1
                o.item = id
                return true
            end
            M.stats.failed = M.stats.failed + 1
            return false
        end,
    }
end

function M.weekly(country, today, commands, host)
    local ai = require("engine.ai")
    if not ai.setting(country, "construction") then
        return
    end
    M.stats.weeks = M.stats.weeks + 1
    local p = M.plans[country]
    if not (p and p.valid and p.items and #p.items > 0) then
        return
    end
    require("engine.ai.economy.script").with(M.post_orders, country, p, today, commands)
    -- RemoveAll: the build plan is used once
    p.items = {}
end

function M.post_orders(country, p, today, commands)
    for _, b in ipairs(p.items) do
        local ok, why = M.can_post(country, b)
        if not ok then
            stop(why or "?")
            break
        end
        -- AddAICommandWithCostForPosting: affordable (again) -> post and withdraw
        local category = B.category(b)
        if budget.can_afford_expenditure(country, category, b.cost) then
            commands[#commands + 1] = command(country, b, today)
            budget.withdraw(country, category, b.cost)
            M.stats.posted = M.stats.posted + 1
            M.posted[#M.posted + 1] = { date = today, country = country, kind = b.kind, type = b.type, colony = b.colony,
                weight = b.weight }
        end
        -- a district, or a zone into a slot that has a zone, lets the next item go too
        if not (b.kind == "district" or (b.kind == "zone" and b.replaces)) then
            break
        end
    end
end

-- ProcessItemForUpkeep (for the budget's upkeep cache): the upkeep of the country's queued planet
-- items, per economic category
function M.queued_upkeep(country)
    local out = {}
    local items = world.stores["construction.item_mgr.items"] or {}
    for _, it in pairs(items) do
        if tonumber(world.field(it, "paying_country")) == country then
            local kind, blk = B.item_kind(it)
            local b
            if kind == "district" then
                b = { kind = kind, type = world.field(blk, "district") }
            elseif kind == "zone" then
                b = { kind = kind, type = world.field(blk, "zone") }
            elseif kind == "planet_building" or kind == "planet_upgrade_building" then
                b = { kind = kind, type = world.field(blk, "building") }
            end
            if b then
                b.colony = tonumber(world.field(blk, "planet"))
                b.planet = b.colony and world.colony_planet[b.colony]
                b.owner = country
                if b.planet then
                    local ok, up = pcall(B.upkeep, b)
                    if ok then
                        local cat = B.category(b)
                        local t = out[cat] or {}
                        for r, v in pairs(up) do
                            t[r] = (t[r] or 0) + v
                        end
                        out[cat] = t
                    end
                end
            end
        end
    end
    return out
end

function M.report()
    local s = M.stats
    local stops = {}
    for k, v in pairs(s.stops) do
        stops[#stops + 1] = k .. " " .. v
    end
    table.sort(stops)
    local lines = {
        string.format("ai economy: %d plans (%d items), %d weeks, %d orders posted, %d executed, %d failed; weeks stopped by: %s",
            s.plans, s.plan_items, s.weeks, s.posted, s.executed, s.failed, table.concat(stops, ", ")),
        budget.report(), orders.report(),
    }
    return table.concat(lines, "\n")
end

return M
