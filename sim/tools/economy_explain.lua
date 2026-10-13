-- tools/economy_explain.lua : the units behind one country's budget entries, against the save.
-- Run after the economy check (sim/tests/economy.rs with ECONOMY_LUA=<this file>); set
-- EXPLAIN_COUNTRY (id) and EXPLAIN_CATEGORY (a category, or a Lua pattern), optionally
-- EXPLAIN_RESOURCE and EXPLAIN_MAX (units listed, default 40).

local economy = require("engine.economy")
local world = require("engine.world")

local country = tonumber(os.getenv("EXPLAIN_COUNTRY") or "0")
local pattern = os.getenv("EXPLAIN_CATEGORY") or "."
local resource = os.getenv("EXPLAIN_RESOURCE")
local max = tonumber(os.getenv("EXPLAIN_MAX") or "40")

economy.explain_on = true
economy.compute()
local lines = {}
local c = world.object("country", country)
lines[#lines + 1] = string.format("country %d: type %s, %d planets", country, tostring(world.field(c, "type")),
    #world.list(world.field(c, "owned_planets")))
local want = economy.save_budget(country) or { income = {}, expenses = {} }
local got = economy.budget(country)
for _, side in ipairs({ "income", "expenses" }) do
    local cats = {}
    for cat in pairs(want[side]) do cats[cat] = true end
    for cat in pairs(got[side]) do cats[cat] = true end
    local list = {}
    for cat in pairs(cats) do
        if cat:match(pattern) then list[#list + 1] = cat end
    end
    table.sort(list)
    for _, cat in ipairs(list) do
        local rs = {}
        for r in pairs(want[side][cat] or {}) do rs[r] = true end
        for r in pairs(got[side][cat] or {}) do rs[r] = true end
        for r in pairs(rs) do
            if resource == nil or resource == r then
                lines[#lines + 1] = string.format("%-8s %-36s %-20s save %12.5f  computed %12.5f", side, cat, r,
                    want[side][cat] and want[side][cat][r] or 0, got[side][cat] and got[side][cat][r] or 0)
            end
        end
    end
end
local n = 0
for _, u in ipairs(economy.contributions(country)) do
    if u[2]:match(pattern) and (resource == nil or resource == u[3]) then
        n = n + 1
        if n <= max then
            lines[#lines + 1] = string.format("  %-8s %-30s %-18s %12.5f  %s", u[1], u[2], u[3], u[4], tostring(u[5]))
        end
    end
end
lines[#lines + 1] = string.format("(%d units)", n)
return table.concat(lines, "\n")
