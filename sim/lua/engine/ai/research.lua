-- engine/ai/research.lua : the AI's choice of research (docs/ai.md section 4), in
-- CAIInteriorMinister::DailyUpdate (GOG 4.5.2 0xbb39a0), for the areas physics, society,
-- engineering in order:
--
--   r = the country's unsynced AI draw          (every day, every area, used or not)
--   tech = CTechnologyStatus::GetTechToResearch(area, r)
--   a technology: CResearchTechnologyCommand -> QueueResearch (appended to the area's queue)
--
-- GetTechToResearch (0x81e090): nothing when the area's queue holds a valid technology (or an
-- active special project); else among tech_status.alternatives.<area>, with maxCost the highest
-- cost (CTechnology::GetCost) of them:
--
--   w(t) = CanQueueResearch(t) ? max(GetAIWeight(t, maxCost), 1) : 0       (fp15)
--   GetAIWeight = ai_weight (factor and modifiers, the country as scope)
--                 * AI_TECHNOLOGY_INFINITELY_REPEATABLE_WEIGHT_MULT (levels = -1)
--                 * AI_TECHNOLOGY_RARE_WEIGHT_MULT (is_rare)
--                 * max(maxCost / max(cost, 1), 1) ^ 2
--   index = the weighted pick of r (engine.ai.rng.weighted)

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local defs = require("engine.defs")
local eval = require("simscript.eval")
local research = require("engine.research")
local rng = require("engine.ai.rng")

local airesearch = { stats = { draws = 0, picks = 0, none = 0 }, picks = {} }

local D
local function defines()
    if D == nil then
        local g = defs.get("common/defines", "NAI")
        local function v(key, default)
            return g and tonumber(defs.field(g.block, key)) or default
        end
        D = {
            REPEATABLE = v("AI_TECHNOLOGY_INFINITELY_REPEATABLE_WEIGHT_MULT", 0.01),
            RARE = v("AI_TECHNOLOGY_RARE_WEIGHT_MULT", 1.5),
        }
    end
    return D
end

-- a weight block as the game's CMeanTimeToHappen reads it: `weight`/`factor` the base, then each
-- `modifier = { factor = x add = y <triggers> }` whose triggers hold, in order
local function weight_of(block, ctx)
    if block == nil then
        return 1
    end
    if block.text then
        return eval.value(block, ctx, block)
    end
    local acc = 1
    for _, e in ipairs(block) do
        slice.tick("ai/research.lua:53")
        local k = e.op and e.key and e.key.text
        if k == "weight" or k == "factor" or k == "base" then
            acc = eval.value(e.value, ctx, e)
        end
    end
    for _, e in ipairs(block) do
        slice.tick("ai/research.lua:59")
        if e.op and e.key and e.key.text == "modifier" and e.value.text == nil then
            local cond, factor, add = {}, nil, nil
            for _, x in ipairs(e.value) do
                slice.tick("ai/research.lua:62")
                local k = x.op and x.key and x.key.text
                if k == "factor" or k == "weight" then
                    factor = eval.value(x.value, ctx, x)
                elseif k == "add" then
                    add = eval.value(x.value, ctx, x)
                else
                    cond[#cond + 1] = x
                end
            end
            local ok, holds = pcall(eval.trigger, cond, ctx)
            if ok and holds then
                acc = acc * (factor or 1) + (add or 0)
            end
        end
    end
    return acc
end
airesearch.weight_of = weight_of

local function queue_items(status, area)
    local q = world.field(status, area .. "_queue")
    return type(q) == "table" and q or nil, type(q) == "table" and world.blocks(q) or {}
end

-- CTechnologyStatus::CanQueueResearch: a technology the country can research and has not queued
local function can_queue(country, status, name)
    local t = research.tech(name)
    if not t then
        return false
    end
    local d = t.def.block
    local levels = tonumber(defs.field(d, "levels"))
    local level = research.level(country, name)
    if level and not (levels == -1 or (levels and level < levels)) then
        return false
    end
    for _, e in ipairs(d) do
        slice.tick("ai/research.lua:99")
        if e.op and e.key and e.key.text == "prerequisites" and e.value.text == nil then
            for _, p in ipairs(e.value) do
                slice.tick("ai/research.lua:101")
                if p.text and not research.level(country, p.text) then
                    return false
                end
            end
        end
    end
    local potential = defs.field(d, "potential")
    if type(potential) == "table" then
        local ok, holds = pcall(eval.trigger, potential, eval.new_ctx(eval.S("country", country), nil, nil, t.def.file))
        if ok and not holds then
            return false
        end
    end
    for _, item in ipairs(select(2, queue_items(status, t.area or ""))) do
        slice.tick("ai/research.lua:115")
        if world.field(item, "technology") == name then
            return false
        end
    end
    return true
end

-- GetAIWeight
function airesearch.ai_weight(country, name, max_cost)
    local t = research.tech(name)
    local d = defines()
    local ctx = eval.new_ctx(eval.S("country", country), nil, nil, t.def.file)
    local w = weight_of(defs.field(t.def.block, "ai_weight"), ctx)
    if tonumber(defs.field(t.def.block, "levels")) == -1 then
        w = w * d.REPEATABLE
    end
    if t.rare then
        w = w * d.RARE
    end
    local cost = math.max(research.cost(country, name) or 1, 1)
    local ratio = math.max(max_cost / cost, 1)
    return w * ratio * ratio
end

-- GetTechToResearch(area, r) -> a technology or nil
function airesearch.tech_to_research(country, status, area, r)
    local _, items = queue_items(status, area)
    for _, item in ipairs(items) do
        slice.tick("ai/research.lua:143")
        if world.field(item, "technology") or world.field(item, "special_project") then
            return nil
        end
    end
    local alts = world.field(world.field(status, "alternatives"), area)
    local list = world.list(alts)
    if #list == 0 then
        return nil
    end
    local max_cost = 0
    for _, name in ipairs(list) do
        slice.tick("ai/research.lua:154")
        max_cost = math.max(max_cost, research.cost(country, name) or 0)
    end
    local weights = {}
    for i, name in ipairs(list) do
        slice.tick("ai/research.lua:158")
        if can_queue(country, status, name) then
            weights[i] = rng.fp15(math.max(airesearch.ai_weight(country, name, max_cost), 1))
        else
            weights[i] = 0
        end
    end
    -- (with no weight the game falls back to r % n; that technology cannot be queued, so the
    -- command it posts does nothing)
    local i = rng.weighted(weights, r)
    return i and weights[i] > 0 and list[i] or nil
end

-- CTechnologyStatus::QueueResearch: the technology appended to its area's queue
function airesearch.queue(country, name, today)
    local c = world.object("country", country)
    local status = world.field(c, "tech_status")
    local t = research.tech(name)
    if type(status) ~= "table" or not t or not can_queue(country, status, name) then
        return false
    end
    local q = world.child(status, t.area .. "_queue")
    local item = {}
    world.append(item, "technology", name, true)
    world.append(item, "date", today, true)
    world.push(q, item)
    return true
end

-- the day's research choices of one AI country; returns the commands (queued by engine.ai)
function airesearch.daily(country, today, commands)
    local status = world.field(world.object("country", country), "tech_status")
    for _, area in ipairs(research.AREAS) do
        slice.tick("ai/research.lua:190")
        local r = rng.draw(country)
        airesearch.stats.draws = airesearch.stats.draws + 1
        local name = type(status) == "table" and airesearch.tech_to_research(country, status, area, r) or nil
        if name then
            commands[#commands + 1] = { kind = "research", country = country, tech = name }
            airesearch.stats.picks = airesearch.stats.picks + 1
            airesearch.picks[#airesearch.picks + 1] = { country = country, area = area, tech = name, date = today }
        end
    end
end

return airesearch
