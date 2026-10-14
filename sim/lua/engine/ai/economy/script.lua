-- engine/ai/economy/script.lua : what the AI's budget and plans ask of the script layer that it
-- does not answer yet, installed only while they evaluate (like engine/economy/script.lua, whose
-- engine reads are installed too):
--
--   has_monthly_income = { resource = r value <op> x }: the country's net income of r, last
--       month's (CCountryBudget _LastMonth balance: engine.ai.budget.last_month)
--   resource_expenses_compare = { resource = r value <op> x }: this month's expenses of r
--   country_uses_food, country_uses_consumer_goods: the AI's scripted triggers, whose
--       `if = { limit } else = { }` chain the script layer does not evaluate in a trigger yet
--   uses_district_set: the planet class's district_set
--   is_ai: a country no player plays
--
--   local script = require("engine.ai.economy.script")
--   script.with(f, ...) -> f's results

local eval = require("simscript.eval")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)

local script = { stats = {} }

local TRIG = eval.TRIG
local trig = {}

local function country_of(ctx)
    local sc = ctx.this
    if sc and sc.kind == "country" then
        return sc.id
    end
    return nil
end

trig.has_monthly_income = function(e, ctx)
    local res, op, amount = nil, ">=", 0
    for _, x in ipairs(e.value) do
        slice.tick("ai/economy/script.lua:33")
        if x.op then
            local xk = x.key.text:lower()
            if xk == "resource" then res = x.value.text
            elseif xk == "value" then op = x.op; amount = eval.value(x.value, ctx, x) end
        end
    end
    local c = country_of(ctx)
    if not (c and res) then
        return false
    end
    local lm = require("engine.ai.budget").last_month(c)
    local v = 0
    for side, sign in pairs({ income = 1, expenses = -1 }) do
        slice.tick("ai/economy/script.lua:46")
        for _, t in pairs(lm[side] or {}) do
            slice.tick("ai/economy/script.lua:47")
            v = v + sign * (t[res] or 0)
        end
    end
    return eval.compare(v, op, amount)
end

-- resource_expenses_compare = { resource = r value <op> x }: this month's expenses of r
trig.resource_expenses_compare = function(e, ctx)
    local res, op, amount = nil, "=", 0
    for _, x in ipairs(e.value) do
        slice.tick("ai/economy/script.lua:57")
        if x.op then
            local xk = x.key.text:lower()
            if xk == "resource" then res = x.value.text
            elseif xk == "value" then op = x.op; amount = eval.value(x.value, ctx, x) end
        end
    end
    local c = country_of(ctx)
    if not (c and res) then
        return false
    end
    return eval.compare(require("engine.ai.economy.plans").current_expenses(c, res), op, amount)
end

-- the AI's scripted triggers country_uses_food / country_uses_consumer_goods
-- (common/scripted_triggers/00_scripted_triggers_ai.txt) are an `if = { limit } else = { }` chain,
-- which the script layer does not evaluate in a trigger yet: the same logic here
local function expenses(c, r)
    return require("engine.ai.economy.plans").current_expenses(c, r)
end
local function uninitialized(c)
    return expenses(c, "food") == 0 and expenses(c, "minerals") == 0 and expenses(c, "energy") == 0
end
local function scripted(text, ctx)
    local tree = require("pdxscript").parse(text, "engine.ai.economy.script")
    local ok, v = pcall(eval.trigger, tree, ctx)
    return ok and v or false
end
trig.country_uses_food = function(e, ctx)
    local c = country_of(ctx)
    if not c then return false end
    local v = (uninitialized(c) or expenses(c, "food") > 0) or scripted("country_uses_bio_ships = yes", ctx)
    if e.value.text == "no" then v = not v end
    return v
end
trig.country_uses_consumer_goods = function(e, ctx)
    local c = country_of(ctx)
    if not c then return false end
    local v = uninitialized(c) or scripted("has_valid_civic = civic_machine_obsessional_directive", ctx)
        or expenses(c, "consumer_goods") > 0
    if e.value.text == "no" then v = not v end
    return v
end

-- uses_district_set = <set>: the planet class's `district_set` (common/planet_classes)
local function planet_of(sc)
    local world = require("engine.world")
    if sc.kind == "planet" then
        return sc.id
    end
    if sc.kind == "colony" then
        return world.colony_planet[sc.id]
    end
end
trig.uses_district_set = function(e, ctx)
    local world = require("engine.world")
    local defs = require("engine.defs")
    local pid = planet_of(ctx.this)
    local class = pid and world.field(world.object("planet", pid), "planet_class")
    local d = class and defs.get("common/planet_classes", class)
    local set = d and defs.field(d.block, "district_set")
    return set ~= nil and set == e.value.text
end

-- is_ai = yes/no: a country no player plays (the AI's own scripts ask it: `owner = { is_ai = no }`
-- in the buildings' potentials lets a player build what the AI does not)
trig.is_ai = function(e, ctx)
    local sc = ctx.this
    if not (sc and sc.kind == "country") then
        return false
    end
    local ai = not require("engine.ai").human(sc.id)
    return ai == (e.value.text == "yes")
end

local orig = {}
local installed = 0

local function install()
    for k, f in pairs(trig) do
        slice.tick("ai/economy/script.lua:136")
        orig[k] = TRIG[k]
        TRIG[k] = function(...)
            script.stats[k] = (script.stats[k] or 0) + 1
            return f(...)
        end
    end
end

local function uninstall()
    for k in pairs(trig) do
        slice.tick("ai/economy/script.lua:146")
        TRIG[k] = orig[k]
    end
end

function script.with(f, ...)
    if installed > 0 then
        return f(...)
    end
    installed = installed + 1
    install()
    local args = { ... }
    local res = { pcall(function()
        return require("engine.economy.script").with(f, unpack(args))
    end) }
    uninstall()
    installed = installed - 1
    if not res[1] then
        error(res[2], 0)
    end
    return unpack(res, 2)
end

return script
