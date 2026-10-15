-- engine/ai : the AI, in Lua (docs/ai.md: the game's AI reverse engineered, and the plan of these
-- modules). CGameState::ProcessAI runs once a day (tick 4): every AI country in the game state's
-- country order decides with the state as it is, posting commands; the commands execute after,
-- in country order (the game: in the next tick's command phase, before anything reads them).
--
-- An AI runs when its country type has `ai = { enabled = yes }`, the country is not a player's,
-- and it has its AI state (`ai = { ... }` in the save). Ported so far, per module:
--
-- - interior minister, daily: the research choice (engine.ai.research), drawing the unsynced AI
--   generator three times a day (engine.ai.rng).
-- - interior minister, weekly: the science ships (engine.ai.exploration: anomalies, surveys,
--   return to base; no AI draws).
--
-- Not ported yet (and so not drawing): the foreign minister's daily diplomacy (its draws on the
-- country's diplomacy day come before the research draws in the game: the stream drifts from the
-- game's after the first such day), war preparation, construction ships and shipyards, military
-- fleets (the budget, economy, traditions and strategy modules have their own headers).

local world = require("engine.world")
local defs = require("engine.defs")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)

local ai = {
    stats = { days = 0, countries = 0, commands = 0, executed = 0 },
}

-- the country type's AI settings (SCountryAISettings flags, CCountryType +0x8c, docs/ai.md section
-- 1): the constructor sets them to 36798, then `ai = { <flag> = yes/no }` sets or clears each
local SETTING_BITS = {
    enabled = 0, declare_war = 1, colonizer = 2, internal_policies = 3, modification = 4,
    government = 5, traditions = 6, construction = 7, limited_construction = 8, starbase_upgrade = 9,
    diplomacy = 10, tech = 11, follow = 12, avoid_enemies = 13, can_use_market = 14, espionage = 15,
    ascension_perks = 16, limited_military_construction = 17, limited_leaders = 18,
}
local SETTING_DEFAULT = 36798
local settings_cache = {}
local function setting(country, key)
    local ty = world.field(world.object("country", country), "type")
    local k = tostring(ty) .. "/" .. key
    local v = settings_cache[k]
    if v == nil then
        local d = ty and defs.get("common/country_types", ty)
        local block = d and defs.field(d.block, "ai")
        local given = type(block) == "table" and defs.field(block, key) or nil
        if given == "yes" or given == "no" then
            v = given == "yes"
        else
            local bit = SETTING_BITS[key]
            v = bit ~= nil and math.floor(SETTING_DEFAULT / 2 ^ bit) % 2 == 1
        end
        settings_cache[k] = v
    end
    return v
end
ai.setting = setting

-- whether the country type's AI runs a module (`ai = { modules = { interior_minister_module ... } }`;
-- personalities' ai_module_overrides are not read yet)
local modules_cache = {}
local function has_module(country, module)
    local ty = world.field(world.object("country", country), "type")
    local set = modules_cache[tostring(ty)]
    if set == nil then
        set = {}
        local d = ty and defs.get("common/country_types", ty)
        local block = d and defs.field(d.block, "ai")
        local mods = type(block) == "table" and defs.field(block, "modules")
        for _, e in ipairs(type(mods) == "table" and mods or {}) do
            if e.text then set[e.text] = true end
        end
        modules_cache[tostring(ty)] = set
    end
    return set[module] or false
end
ai.has_module = has_module

-- the players' countries (`player = { { name country } }`)
local humans
local function human(country)
    if humans == nil then
        humans = {}
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "player" and e.value.text == nil then
                for _, p in ipairs(world.blocks(e.value)) do
                    local c = tonumber(world.field(p, "country"))
                    if c then humans[c] = true end
                end
            end
        end
    end
    return humans[country] or false
end
ai.human = human

local function date_text(date)
    return date and date.year and string.format("%d.%02d.%02d", date.year, date.month, date.day) or nil
end

-- the commands, executed in order after every AI decided
local function execute(cmd, today)
    if cmd.kind == "research" then
        return require("engine.ai.research").queue(cmd.country, cmd.tech, today)
    end
    -- a command of another module: { kind, execute = function(cmd, today) }
    if cmd.execute then
        return cmd.execute(cmd, today)
    end
    return false
end

-- an AI module that may not be written yet (engine.ai.<name>): the module or nil
local present = {}
local function optional(name)
    if present[name] == nil then
        present[name] = package.searchpath(name, package.path) ~= nil
    end
    return present[name] and require(name) or nil
end

-- the AI's day counters (CAICore::Update: _WeekDaysCounter, _MonthDaysCounter, _YearDaysCounter),
-- not saved: at load each starts at id % 7, id % 30, id % 360; each day it goes down by one and at
-- 0 or below the weekly / monthly / yearly update runs and it starts again at 7, 30, 360
local counters = {}
local function tick_counters(country)
    local k = counters[country]
    if k == nil then
        k = { week = country % 7, month = country % 30, year = country % 360 }
        counters[country] = k
    end
    local due = {}
    for name, period in pairs({ week = 7, month = 30, year = 360 }) do
        k[name] = k[name] - 1
        if k[name] <= 0 then
            due[name] = true
            k[name] = period
        end
    end
    return due
end
ai.counters = counters

-- the interior minister's periodic parts, in its modules' order: modules engine.ai.<name> with
-- weekly / monthly / yearly(country, today, commands) functions, called when they are there (the
-- economic plan and build plan come first in CAIInteriorMinister::MonthlyUpdate, the traditions
-- later; in WeeklyUpdate the civilian fleets, engine.ai.exploration, come after the districts and
-- buildings; HandleStarbases and HandleStarbasesDefenses, engine.ai.starbases, between them; the
-- construction ships, engine.ai.construction_ships, are the civilian fleets' constructor branch)
ai.INTERIOR = { "economy", "starbases", "exploration", "construction_ships", "traditions" }

-- whether a country's AI runs (CGameState::ProcessAI's filter)
local function runs(country)
    local c = world.object("country", country)
    return c ~= nil and type(world.field(c, "ai")) == "table" and setting(country, "enabled") and not human(country)
end
ai.runs = runs

-- ai.decide(country, today, due, commands, host): one AI country's day (CAICore::Update), its
-- commands appended to commands; due = { week, month, year } from the day counters. It reads the
-- world and writes only the country's own AI state, so it may run on a worker (engine.store.worker).
function ai.decide(country, today, due, commands, host)
    -- the modules' daily updates (in the country type's module order: military, foreign,
    -- interior, ...; only the interior minister's research is ported), then the weekly, monthly
    -- and yearly ones when their counters are due
    local interior = has_module(country, "interior_minister_module")
    if interior and setting(country, "tech") then
        require("engine.ai.research").daily(country, today, commands)
    end
    -- then the interior minister's armies and ships (engine.ai.shipbuilding: BuildArmies,
    -- BuildShips; CAIInteriorMinister::DailyUpdate after the research)
    local shipbuilding = interior and optional("engine.ai.shipbuilding")
    if shipbuilding and shipbuilding.daily then
        shipbuilding.daily(country, today, commands)
    end
    -- the weekly updates, then the monthly (CCountryAI::MonthlyUpdate: the AI's budget,
    -- engine.ai.budget, before the modules' monthly updates), then the yearly: on a day
    -- where the week and the month are both due, the week's orders use last month's budget
    -- and plan (docs/ai_economy.md section 1)
    for _, period in ipairs({ "week", "month", "year" }) do
        if due[period] then
            if period == "month" then
                local budget = optional("engine.ai.budget")
                if budget and budget.monthly then
                    budget.monthly(country, today, commands, host)
                end
            end
            if interior then
                local fn = ({ week = "weekly", month = "monthly", year = "yearly" })[period]
                for _, name in ipairs(ai.INTERIOR) do
                    slice.check("ai module")
                    local m = optional("engine.ai." .. name)
                    if m and m[fn] then
                        m[fn](country, today, commands, host)
                    end
                end
            end
        end
    end
end

-- the countries' decisions on the workers (STELLAR_PARALLEL=ai; engine.store.worker's `ai` job):
-- each country decides in the worker that always takes it, as ai.decide does here; its unsynced
-- generator, its `ai` block and its commands come back and are applied here in country order
local function decide_on_workers(list, today, commands)
    local parallel = require("engine.store.parallel")
    local rng = require("engine.ai.rng")
    local cmds = require("engine.ai.commands")
    local lines = {}
    for i, c in ipairs(list) do
        local due = tick_counters(c)
        local seed, pos = rng.state(c)
        lines[i] = string.format("%d %d %d %d %d %d", c, due.week and 1 or 0, due.month and 1 or 0,
            due.year and 1 or 0, seed, pos)
    end
    local t0 = RUST.clock()
    local res = {}
    for w, text in ipairs(parallel.run("ai", today .. "\n" .. table.concat(lines, "\n"))) do
        local at, cur = 1, nil
        while at <= #text do
            local tag, len, start = text:match("^(%u)(%d+)\n()", at)
            if not tag then error("ai: worker " .. w .. "'s answer unreadable: " .. text:sub(at, at + 80)) end
            local payload = text:sub(start, start + tonumber(len) - 1)
            at = start + tonumber(len)
            if tag == "C" then
                local c, s, p = payload:match("^(%d+) (%d+) (%d+)$")
                cur = { seed = tonumber(s), position = tonumber(p), commands = {} }
                res[tonumber(c)] = cur
            elseif tag == "O" then
                cur.text = payload
            elseif tag == "E" then
                cur.error = payload
            else
                cur.commands[#cur.commands + 1] = payload
            end
        end
    end
    local t1 = RUST.clock()
    ai.stats.run_seconds = (ai.stats.run_seconds or 0) + (t1 - t0)
    local pdx = require("pdxscript")
    local env = { B = require("engine.store.full").table_of, M = require }
    for _, c in ipairs(list) do
        local r = res[c]
        if not r then error("ai: no worker decided for country " .. c) end
        rng.set_state(c, r.seed, r.position)
        local block = world.field(world.object("country", c), "ai")
        if r.text then
            cmds.merge(block, assert(pdx.parse(r.text)))
            world.retrack(block)
        end
        if r.error then
            ai.stats.errors = (ai.stats.errors or 0) + 1
            ai.stats.first_error = ai.stats.first_error or (c .. ": " .. r.error)
        end
        env.A = function(...)
            local t = block
            for i = 1, select("#", ...) do
                local s = select(i, ...)
                if s == "v" then t = t.value else t = t[s] end
            end
            return t
        end
        for _, line in ipairs(r.commands) do
            commands[#commands + 1] = cmds.rebuild(line, env)
        end
    end
end

-- ai.process(host, date): the day's AI (CGameState::ProcessAI)
function ai.process(host, date)
    local today = date_text(date)
    local commands = {}
    ai.stats.days = ai.stats.days + 1
    local list = {}
    for _, country in ipairs(world.all("country")) do
        slice.tick("ai/init.lua:273")
        if runs(country) then
            ai.stats.countries = ai.stats.countries + 1
            list[#list + 1] = country
        end
    end
    local t0 = RUST.clock()
    if #list > 0 and require("engine.store.parallel").enabled("ai") then
        decide_on_workers(list, today, commands)
    else
        for _, country in ipairs(list) do
            slice.check("ai country")
            ai.decide(country, today, tick_counters(country), commands, host)
        end
    end
    ai.stats.decide_seconds = (ai.stats.decide_seconds or 0) + (RUST.clock() - t0)
    -- STELLAR_AI_LOG=<file>: the day's commands, in order (serial and parallel runs compared)
    local log = os.getenv("STELLAR_AI_LOG")
    if log then
        local f = io.open(log, "a")
        local function flat(t, depth)
            local ks = {}
            for k, v in pairs(t) do
                if type(v) ~= "function" then ks[#ks + 1] = k end
            end
            table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
            local out = {}
            for _, k in ipairs(ks) do
                local v = t[k]
                if type(v) == "table" then
                    out[#out + 1] = tostring(k) .. "={" .. (depth < 3 and flat(v, depth + 1) or "...") .. "}"
                else
                    out[#out + 1] = tostring(k) .. "=" .. tostring(v)
                end
            end
            return table.concat(out, " ")
        end
        for _, cmd in ipairs(commands) do
            f:write(today, " ", tostring(cmd.country), " ", tostring(cmd.kind), " ", flat(cmd, 1), "\n")
        end
        local rng = require("engine.ai.rng")
        for _, c in ipairs(list) do
            f:write(today, " rng ", c, " ", rng.position(c), "\n")
        end
        f:close()
    end
    ai.stats.commands = ai.stats.commands + #commands
    for _, cmd in ipairs(commands) do
        slice.tick("ai command")
        if execute(cmd, today) then
            ai.stats.executed = ai.stats.executed + 1
        end
    end
end

function ai.report()
    local s = ai.stats
    local r = require("engine.ai.research").stats
    local text = string.format("ai: %d days, %d country-days; research: %d draws, %d picks; %d commands, %d executed",
        s.days, s.countries, r.draws, r.picks, s.commands, s.executed)
    text = text .. string.format("; deciding %.2f s", s.decide_seconds or 0)
    if s.run_seconds then
        local p = require("engine.store.parallel").stats
        text = text .. string.format(" (on the workers: the run %.2f s, of which the copy's syncs %.2f s, the jobs %.2f s)", s.run_seconds, p.sync_seconds or 0, p.seconds - (p.sync_seconds or 0))
    end
    if s.errors then
        text = text .. string.format("; %d decisions failed on the workers (first: %s)", s.errors, s.first_error)
    end
    local ex = package.loaded["engine.ai.exploration"]
    if type(ex) == "table" and ex.report then
        text = text .. "\n" .. ex.report()
    end
    local sb = package.loaded["engine.ai.shipbuilding"]
    if type(sb) == "table" and sb.report then
        text = text .. "\n" .. sb.report()
    end
    for _, name in ipairs({ "engine.ai.construction_ships", "engine.ai.starbases" }) do
        local m = package.loaded[name]
        if type(m) == "table" and m.report then
            text = text .. "\n" .. m.report()
        end
    end
    return text
end

return ai
