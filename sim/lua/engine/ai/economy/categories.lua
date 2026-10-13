-- engine/ai/economy/categories.lua : the economic categories as the AI's budget reads them
-- (common/economic_categories; CEconomicCategory: _pParent +0x90, _Children +0x78, _Settings
-- +0x130 bit 1 = use_for_ai_budget, _UseParentForResourcesUpkeepIndexes +0x188,
-- _UseParentForResourcesExpenditureIndexes +0x1a0), docs/ai_economy.md section 2.
--
--   local cats = require("engine.ai.economy.categories")
--   cats.to_use(cat)                 -- CCountryAI::GetEconomicCategoryToUse (0xb78e80)
--   cats.for_expenditure(cat, res)   -- GetBudgetCategoryForResourceExpenditure (0xb79a40)
--   cats.for_upkeep(cat, res)        -- GetBudgetCategoryForResourceUpkeep (0xb79af0)
--   cats.descendants(cat)            -- cat and every category under it

local defs = require("engine.defs")

local cats = {}

local C -- name -> { name, parent, ai, upkeep_parent = { [res] = true }, expenditure_parent, children }

local function list_set(block)
    local set = {}
    if type(block) == "table" then
        for _, e in ipairs(block) do
            if e.text then
                set[e.text] = true
            end
        end
    end
    return set
end

local function load()
    if C then
        return C
    end
    C = {}
    for name, d in pairs(defs.folder("common/economic_categories")) do
        C[name] = {
            name = name,
            parent = defs.field(d.block, "parent"),
            ai = defs.field(d.block, "use_for_ai_budget") == "yes",
            upkeep_parent = list_set(defs.field(d.block, "ai_use_parent_for_resources_upkeep")),
            expenditure_parent = list_set(defs.field(d.block, "ai_use_parent_for_resources_expenditure")),
            children = {},
        }
    end
    for name, c in pairs(C) do
        local p = c.parent and C[c.parent]
        if p then
            p.children[#p.children + 1] = name
        else
            c.parent = nil
        end
    end
    for _, c in pairs(C) do
        table.sort(c.children)
    end
    return C
end

function cats.get(name)
    return load()[name]
end

function cats.all()
    return load()
end

-- GetEconomicCategoryToUse: the category if it has use_for_ai_budget, else the nearest parent that
-- has (at most 100 steps; a category without such a parent ends at its root, which has no budget)
function cats.to_use(name)
    local c = load()[name]
    if not c then
        return name
    end
    if c.ai then
        return name
    end
    for _ = 1, 100 do
        local p = c.parent and C[c.parent]
        if not p or p == c then
            break
        end
        c = p
        if c.ai then
            break
        end
    end
    return c.name
end

-- the budget category of one resource: a category that names the resource in its
-- ai_use_parent_for_resources_<kind> list goes to its parent; otherwise the first category with
-- use_for_ai_budget, walking up
local function for_resource(name, res, field)
    local c = load()[name]
    while c do
        if not c[field][res] and c.ai then
            return c.name
        end
        local p = c.parent and C[c.parent]
        if not p then
            return c.name
        end
        c = p
    end
    return name
end

function cats.for_expenditure(name, res)
    return for_resource(name, res, "expenditure_parent")
end

function cats.for_upkeep(name, res)
    return for_resource(name, res, "upkeep_parent")
end

-- the category and all its descendants (AddBudgetCategoryExpense recurses into _Children)
function cats.descendants(name, out)
    out = out or {}
    local c = load()[name]
    out[#out + 1] = name
    for _, child in ipairs(c and c.children or {}) do
        cats.descendants(child, out)
    end
    return out
end

return cats
