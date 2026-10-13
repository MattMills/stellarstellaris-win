-- engine/research.lua : research, the way CTechnologyStatus::DailyResearch (GOG 4.5.2, 0x818de0,
-- called from CCountry::DailyUpdateSerial after the country's events) does it, on the save's
-- tech_status:
--
--   tech_status = { technology = "tech_x" level = 1 ...
--                   physics_queue = { { progress = 959.31163 technology = "tech_fusion_power" date = "2205.12.02" } }
--                   society_queue = { ... } engineering_queue = { ... }
--                   stored_techpoints = { 0 0 0 } alternatives = { physics = { ... } ... } }
--
-- Once a month, on the month's second day (day 1 counting from 0), each area's research goes to
-- its queue (CTechnologyStatus::CalcResearchPerMonth):
--
--   R       the area's resource (physics_research, ...) in the country's budget balance of the
--           month (CCountryBudget current month, total summed balance)
--   A     = max(0, R * (1 + efficiency))
--   B     = min(R, max(0, stored))           the stored points drawn, at most the month's research
--   each queued technology in turn: progress += A + B, stored -= B, A = 0 (the first takes A)
--   stored += A                              what no technology took (an empty queue keeps it)
--
-- efficiency (CTechnologyStatus::CalcResearchEfficiency), for the first technology of the queue:
--   all_technology_research_speed + country_<area>_tech_research_speed
--   + category_<c>_research_speed_mult for each of its categories
--   + rare_ / dangerous_ / insight_tech_research_speed_mult by its flags
--   + TECH_RESEARCH_NO_LEADER_PENALTY without a head of research (CGovernment::GetHeadScientist: the
--     leader of a council position of COUNCIL_RESEARCH_POSITIONS)
--   (+ the tech sharing of research agreements, GetTechSharingMult: not modelled yet)
--
-- A queued technology is done when its progress reaches its cost (CTechQueueItem::IsDone,
-- CTechnology::GetCost):
--
--   cost = round(base * (fe + penalty) * (1 + subject_tech_cost_mult, when the overlord has it)
--                * (1 + <area>_tech_cost_mult) * galaxy.technology)
--   fe = TECH_COST_MULT_FALLEN_EMPIRE for a fallen empire's country type, else 1
--   penalty = EMPIRE_SIZE_TECH_COST_PENALTY * max(0, empire_size - admin cap)
--             * (1 + empire_size_penalty_mult) * (1 + tech_cost_empire_size_mult)
--   admin cap = (EMPIRE_SIZE_BASE + country_admin_cap_add) * (1 + country_admin_cap_mult)
--
-- Done (CTechnologyStatus::DoResearchTechnologyCompleted): the technology added (or its level
-- raised), on_tech_increased, the item taken out of the queue. Not modelled yet: the alternatives
-- drawn again (UpdateTechAlternatives), the next technology the AI queues (the AI phase), special
-- projects in the queues (left as they are), component upgrades, messages.
--
-- The modifiers are the economy's source (engine.economy: the capture until the graph is built
-- from the world); the month's research is the budget the economy computed (economy.last_month),
-- or before its first month the save's own budget.current_month.

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local research = {
    AREAS = { "physics", "society", "engineering" },
    stats = { months = 0, added = 0, completed = 0, queues_emptied = 0, projects_by_days = 0,
        projects_research = 0, projects_done = 0, projects_unknown = 0, unknown_techs = 0, no_budget = 0,
        no_leader = 0 },
    completed = {},   -- { { country, tech, date } } in the order they happened
}

local AREA_INDEX = { physics = 1, society = 2, engineering = 3 }

-- ---------------------------------------------------------------------------------------------
-- the defines (common/defines), read once

local D
local function define(group, key)
    -- common/defines: the groups are the definitions (`NGameplay = { EMPIRE_SIZE_BASE = 100 }`)
    local g = defs.get("common/defines", group)
    local v = g and defs.field(g.block, key)
    if v ~= nil then
        return v
    end
    for _, d in pairs(defs.folder("common/defines")) do
        v = defs.field(d.block, key)
        if v ~= nil then return v end
    end
    return nil
end
local function defines()
    if D then
        return D
    end
    D = {
        EMPIRE_SIZE_BASE = tonumber(define("NGameplay", "EMPIRE_SIZE_BASE")) or 100,
        EMPIRE_SIZE_TECH_COST_PENALTY = tonumber(define("NGameplay", "EMPIRE_SIZE_TECH_COST_PENALTY")) or 0.002,
        TECH_COST_MULT_FALLEN_EMPIRE = tonumber(define("NGameplay", "TECH_COST_MULT_FALLEN_EMPIRE")) or 2,
        TECH_RESEARCH_NO_LEADER_PENALTY = tonumber(define("NGameplay", "TECH_RESEARCH_NO_LEADER_PENALTY")) or -0.25,
        TECH_COST_DIFFICULTY_SCALE_MULT = tonumber(define("NGameplay", "TECH_COST_DIFFICULTY_SCALE_MULT")) or 0.025,
        RESEARCH_POSITIONS = {},
    }
    local positions = define("NGameplay", "COUNCIL_RESEARCH_POSITIONS")
    for _, e in ipairs(type(positions) == "table" and positions or {}) do
        if e.text then
            D.RESEARCH_POSITIONS[e.text] = true
        end
    end
    return D
end

-- ---------------------------------------------------------------------------------------------
-- the technologies (common/technology)

local tech_cache = {}
local function tech(name)
    local t = tech_cache[name]
    if t ~= nil then
        return t or nil
    end
    local d = defs.get("common/technology", name)
    if not d then
        tech_cache[name] = false
        return nil
    end
    local b = d.block
    t = { name = name, def = d, area = defs.field(b, "area"), categories = {},
        rare = defs.field(b, "is_rare") == "yes", dangerous = defs.field(b, "is_dangerous") == "yes",
        insight = defs.field(b, "is_insight") == "yes" }
    local cats = defs.field(b, "category")
    for _, e in ipairs(type(cats) == "table" and cats or {}) do
        if e.text then
            t.categories[#t.categories + 1] = e.text
        end
    end
    tech_cache[name] = t
    return t
end
research.tech = tech

local function modifiers_of(country)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers("country", country) or {}
end

-- the galaxy settings (the save's `galaxy = { technology = 1 difficulty = ensign
-- technology_difficulty_scale = scaling_normal ... }`, CGalaxyConfiguration): the technology cost
-- (_vTechCost), and the difficulty and its tech cost scaling as the game numbers them
-- (GetDifficultyEnumFromToken, GetDifficultyTechScalingEnumFromToken)
local DIFFICULTY = { civilian = 0, cadet = 1, ensign = 2, captain = 3, commodore = 4, admiral = 5, grand_admiral = 6 }
local TECH_SCALING = { scaling_off = 0, scaling_low = 1, scaling_normal = 2, scaling_high = 3, scaling_extreme = 4 }
local galaxy
local function galaxy_settings()
    if galaxy == nil then
        local g = {}
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "galaxy" and e.value.text == nil then
                g = e.value
            end
        end
        galaxy = {
            tech_cost = tonumber(world.field(g, "technology")) or 1,
            difficulty = DIFFICULTY[world.field(g, "difficulty") or ""] or 2,
            tech_scaling = TECH_SCALING[world.field(g, "technology_difficulty_scale") or ""] or 2,
        }
    end
    return galaxy
end

-- the base cost (CTechnology::GetCostForLevel): `cost = @tierNcostM`, or a weight-like block
-- (`cost = { factor = @tier2cost2 modifier = { factor = 0.75 <triggers> } }`), in the country's scope
local function base_cost(t, country)
    local b = t.def.block
    local v
    for _, e in ipairs(b) do
        if e.op and e.key and e.key.text == "cost" then
            v = e.value
        end
    end
    if v == nil then
        return 0
    end
    local ctx = eval.new_ctx(eval.S("country", country), nil, nil, t.def.file)
    local acc = 0
    if v.text then
        acc = eval.value(v, ctx, v)
    end
    for _, e in ipairs(v.text and {} or v) do
        local k = e.op and e.key and e.key.text
        if k == "factor" or k == "base" then
            acc = eval.value(e.value, ctx, e)
        end
    end
    for _, e in ipairs(v.text and {} or v) do
        if e.op and e.key and e.key.text == "modifier" and e.value.text == nil then
            local cond, factor, add = {}, nil, nil
            for _, x in ipairs(e.value) do
                local k = x.op and x.key and x.key.text
                if k == "factor" then
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
    -- CTechnology::GetCostForLevel: the cost per level times the level to research (the levels
    -- researched + 1), then the difficulty's scaling by tier, rounded
    local per = defs.field(b, "cost_per_level")
    if per ~= nil then
        local level = (research.level(country, t.name) or 0) + 1
        acc = acc + level * eval.value({ text = tostring(per) }, ctx)
    end
    local g = galaxy_settings()
    local scale = defines().TECH_COST_DIFFICULTY_SCALE_MULT * (tonumber(defs.field(b, "tier")) or 0)
        * g.difficulty * g.tech_scaling
    return math.floor(acc * (1 + scale) + 0.5)
end

local function is_fallen_empire(c)
    local ty = world.field(c, "type")
    local d = ty and defs.get("common/country_types", ty)
    return d and defs.field(d.block, "fallen_empire") == "yes" or false
end

-- research.level(country, tech) -> the level the country has of a technology, or nil
function research.level(country, name)
    local status = world.field(world.object("country", country), "tech_status")
    if type(status) ~= "table" then
        return nil
    end
    local found
    for _, e in ipairs(status) do
        if e.op and e.key then
            local k = e.key.text
            if k == "technology" then
                found = e.value.text == name
            elseif k == "level" and found then
                return tonumber(e.value.text) or 1
            end
        end
    end
    return nil
end

-- research.cost(country, tech) -> the research points the technology needs (CTechnology::GetCost)
function research.cost(country, name)
    local t = tech(name)
    if not t then
        return nil
    end
    local d = defines()
    local c = world.object("country", country)
    local M = modifiers_of(country)
    local admin_cap = (d.EMPIRE_SIZE_BASE + (M.country_admin_cap_add or 0))
        * math.max(0, 1 + (M.country_admin_cap_mult or 0))
    local excess = math.max(0, (tonumber(world.field(c, "empire_size")) or 0) - admin_cap)
    local penalty = d.EMPIRE_SIZE_TECH_COST_PENALTY * excess * math.max(0, 1 + (M.empire_size_penalty_mult or 0))
        * (1 + (M.tech_cost_empire_size_mult or 0))
    local mult = (is_fallen_empire(c) and d.TECH_COST_MULT_FALLEN_EMPIRE or 1) + penalty
    local overlord = tonumber(world.field(c, "overlord"))
    if overlord and overlord ~= 4294967295 and (M.subject_tech_cost_mult or 0) ~= 0
        and research.level(overlord, name) then
        mult = mult * (1 + M.subject_tech_cost_mult)
    end
    mult = mult * (1 + (M[(t.area or "") .. "_tech_cost_mult"] or 0))
    return math.floor(base_cost(t, country) * mult * galaxy_settings().tech_cost + 0.5)
end

-- ---------------------------------------------------------------------------------------------
-- the month's research and its efficiency

local heads -- country -> whether it has a head of research (rebuilt each month)
local function head_of_research(country)
    if heads == nil then
        heads = {}
        local d = defines()
        local store = world.stores.council_positions
        for _, id in ipairs(world.all("council_positions")) do
            local p = store[id]
            if p and d.RESEARCH_POSITIONS[world.field(p, "type") or ""] then
                local leader = tonumber(world.field(p, "leader"))
                if leader and leader ~= 4294967295 and world.object("leader", leader) then
                    heads[tonumber(world.field(p, "country")) or -1] = true
                end
            end
        end
    end
    return heads[country] or false
end

-- research.efficiency(country, area, tech) -> the research speed bonus of the area's first technology
function research.efficiency(country, area, t)
    local M = modifiers_of(country)
    local e = (M.all_technology_research_speed or 0) + (M["country_" .. area .. "_tech_research_speed"] or 0)
    if t then
        for _, c in ipairs(t.categories) do
            e = e + (M["category_" .. c .. "_research_speed_mult"] or 0)
        end
        if t.rare then e = e + (M.rare_tech_research_speed_mult or 0) end
        if t.dangerous then e = e + (M.dangerous_tech_research_speed_mult or 0) end
        if t.insight then e = e + (M.insight_tech_research_speed_mult or 0) end
    end
    if not head_of_research(country) then
        e = e + defines().TECH_RESEARCH_NO_LEADER_PENALTY
        research.stats.no_leader = research.stats.no_leader + 1
    end
    return e
end

-- research.month(country, area) -> the area's research of the month (the budget's balance), or nil
function research.month(country, area)
    local economy = package.loaded["engine.economy"]
    local budget = economy and economy.last_month and economy.last_month[country]
    if budget == nil and economy then
        research.save_budgets = research.save_budgets or {}
        budget = research.save_budgets[country]
        if budget == nil then
            budget = economy.save_budget(country) or false
            research.save_budgets[country] = budget
        end
    end
    if not budget then
        return nil
    end
    local r, sum = area .. "_research", 0
    for side, sign in pairs({ income = 1, expenses = -1 }) do
        for _, res in pairs(budget[side] or {}) do
            sum = sum + sign * (res[r] or 0)
        end
    end
    return sum
end

-- ---------------------------------------------------------------------------------------------
-- the queues

local function item_field(item, key)
    for _, e in ipairs(item) do
        if e.op and e.key and e.key.text == key then
            return e
        end
    end
end

-- research.add_technology(country, tech): the technology added at level 1, or its level raised
-- (CTechnologyStatus::IncreaseTechnologyLevel), after the other technologies of tech_status
function research.add_technology(country, name)
    local c = world.object("country", country)
    if not c then
        return false
    end
    local status = world.child(c, "tech_status")
    local last, found
    for i, e in ipairs(status) do
        if e.op and e.key then
            local k = e.key.text
            if k == "technology" then
                found = e.value.text == name
                last = i
            elseif k == "level" then
                if found then
                    e.value.text = tostring((tonumber(e.value.text) or 1) + 1)
                    return true
                end
                last = i
            end
        end
    end
    local pos = (last or 0) + 1
    world.insert(status, pos, "technology", name, true)
    world.insert(status, pos + 1, "level", 1)
    return true
end

-- the stored_techpoints block's three values (the tokens, changed in place)
local function stored(status)
    local block = world.field(status, "stored_techpoints")
    if type(block) ~= "table" then
        block = world.child(status, "stored_techpoints")
        for _ = 1, 3 do
            world.append_value(block, 0)
        end
    end
    local values = {}
    for _, e in ipairs(block) do
        if e.text then
            values[#values + 1] = e
        end
    end
    return values
end
local today -- the date as the save writes it, for research.completed

local function complete(host, country, queue, item, name)
    research.add_technology(country, name)
    world.remove_entry(queue, item)
    research.stats.completed = research.stats.completed + 1
    research.completed[#research.completed + 1] = { country = country, tech = name, date = today }
    if host and host.on_action then
        host.on_action("on_tech_increased", "country", country)
    end
end

-- the special project types (common/special_projects: `special_project = { key = "X" cost = 1500
-- days_to_research = 0 ... }` blocks, all with the same name), by key
local project_types
function research.project_type(key)
    if project_types == nil then
        project_types = {}
        local source = require("stellar.script.source")
        local fs = require("simscript.db").fs
        for _, file in ipairs(source.files(fs, "common/special_projects", "txt")) do
            for _, e in ipairs(source.parse(fs, file) or {}) do
                if e.op and e.key and e.value.text == nil then
                    local k = defs.field(e.value, "key")
                    if k then
                        project_types[k] = { key = k, cost = tonumber(defs.field(e.value, "cost")) or 0,
                            days = tonumber(defs.field(e.value, "days_to_research")) or 0 }
                    end
                end
            end
        end
    end
    return project_types[key]
end

-- research.project_of(country, id) -> the type key of one of the country's special projects
-- (`events = { special_project = { id = 2 special_project = "AMOEBAS_PROJECT" ... } }`)
function research.project_of(country, id)
    local events = world.field(world.object("country", country), "events")
    for _, p in ipairs(world.fields(events, "special_project")) do
        if type(p) == "table" and tonumber(world.field(p, "id")) == id then
            return world.field(p, "special_project")
        end
    end
end

-- one area of one country, one day (day: the day of the month counting from 0)
local function area_day(host, country, status, area, day)
    local queue = world.field(status, area .. "_queue")
    if type(queue) ~= "table" then
        queue = nil
    end
    local items = queue and world.blocks(queue) or {}
    local monthly = day == 1
    local A, B, values, slot
    if monthly then
        local R = research.month(country, area)
        if R == nil then
            research.stats.no_budget = research.stats.no_budget + 1
            return
        end
        values = stored(status)
        slot = values[AREA_INDEX[area]]
        local s = slot and tonumber(slot.text) or 0
        -- the efficiency of the first technology still to research
        local first
        for _, item in ipairs(items) do
            local te = item_field(item, "technology")
            local t = te and tech(te.value.text)
            if t then
                first = t
                break
            end
        end
        A = math.max(0, R * (1 + research.efficiency(country, area, first)))
        B = math.min(R, math.max(0, s))
        research.stats.months = research.stats.months + 1
    end
    -- the month's research to an item: progress += A + B, the stored points drawn, A taken
    local function add_month(item)
        local pe = item_field(item, "progress")
        local add = A + B
        local progress = (pe and tonumber(pe.value.text) or 0) + add
        if add > A and slot then
            slot.text = world.number_text((tonumber(slot.text) or 0) - (add - A))
        end
        research.stats.added = research.stats.added + add
        A = A - math.min(add, A)
        progress = math.floor(progress * 100000 + 0.5) / 100000
        if pe then
            pe.value.text = world.number_text(progress)
        else
            world.insert(item, 1, "progress", progress)
        end
        return progress
    end
    local emptied = #items > 0
    local halted = false -- a special project with a research cost holds back what comes after it
    for _, item in ipairs(items) do
        local te = item_field(item, "technology")
        local name = te and te.value.text
        local sp = item_field(item, "special_project")
        if sp then
            emptied = false
            local key = research.project_of(country, tonumber(sp.value.text))
            local pt = key and research.project_type(key)
            if not pt then
                research.stats.projects_unknown = research.stats.projects_unknown + 1
            elseif pt.days > 0 or pt.cost <= 0 then
                -- by days, where a ship works on it (CSpecialProjectInstance::CanProgress): not modelled
                research.stats.projects_by_days = research.stats.projects_by_days + 1
            else
                if monthly and not halted then
                    local progress = add_month(item)
                    research.stats.projects_research = research.stats.projects_research + 1
                    if progress >= pt.cost then
                        -- CCountryEventManager::CompleteSpecialProject: not modelled yet
                        research.stats.projects_done = research.stats.projects_done + 1
                    end
                end
                halted = true
            end
        elseif not name or not tech(name) then
            research.stats.unknown_techs = research.stats.unknown_techs + 1
            emptied = false
        else
            local pe = item_field(item, "progress")
            local progress = pe and tonumber(pe.value.text) or 0
            local cost = research.cost(country, name)
            if progress >= cost then
                complete(host, country, queue, item, name)
            elseif monthly and not halted then
                local added = A + B
                progress = add_month(item)
                if added > 0 and progress >= cost then
                    complete(host, country, queue, item, name)
                else
                    emptied = false
                end
            else
                emptied = false
            end
        end
    end
    if emptied then
        research.stats.queues_emptied = research.stats.queues_emptied + 1
    end
    if monthly and slot and A > 0 then
        slot.text = world.number_text((tonumber(slot.text) or 0) + A)
    end
end

-- research.daily(host, date): every country's research for the day (in the countries' serial phase)
function research.daily(host, date)
    local day = date and date.day and (date.day - 1) or nil
    if day == nil then
        local days = math.floor((E.date() - 43800000) / 24)
        day = days % 30
    end
    if day == 1 then
        heads = nil
    end
    today = date and date.year and string.format("%d.%02d.%02d", date.year, date.month, date.day) or nil
    for _, country in ipairs(world.all("country")) do
        local c = world.object("country", country)
        local status = c and world.field(c, "tech_status")
        if type(status) == "table" then
            for _, area in ipairs(research.AREAS) do
                area_day(host, country, status, area, day)
            end
        end
    end
end

-- research.report() -> text
function research.report()
    local s = research.stats
    return string.format("research: %d monthly area updates, %.1f points added, %d technologies completed, "
        .. "%d queues emptied (the AI's next pick is not modelled); special projects: %d months of research to "
        .. "them, %d reached their cost (completion not modelled), %d day-items by days (not modelled), %d unknown; "
        .. "%d unknown technologies, %d area updates without a budget, %d without a head of research",
        s.months, s.added, s.completed, s.queues_emptied, s.projects_research, s.projects_done, s.projects_by_days,
        s.projects_unknown, s.unknown_techs, s.no_budget, s.no_leader)
end

return research
