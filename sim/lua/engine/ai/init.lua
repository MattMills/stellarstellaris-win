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
--
-- Not ported yet (and so not drawing): the foreign minister's daily diplomacy (its draws on the
-- country's diplomacy day come before the research draws in the game: the stream drifts from the
-- game's after the first such day), war preparation, the budget, construction, fleets.

local world = require("engine.world")
local defs = require("engine.defs")

local ai = {
    stats = { days = 0, countries = 0, commands = 0, executed = 0 },
}

-- the country type's AI settings (SCountryAISettings): a flag is on unless the type says no
local settings_cache = {}
local function setting(country, key)
    local ty = world.field(world.object("country", country), "type")
    local k = tostring(ty) .. "/" .. key
    local v = settings_cache[k]
    if v == nil then
        local d = ty and defs.get("common/country_types", ty)
        local block = d and defs.field(d.block, "ai")
        if type(block) ~= "table" then
            v = false
        elseif key == "enabled" then
            v = defs.field(block, "enabled") == "yes"
        else
            v = defs.field(block, key) ~= "no"
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
    return false
end

-- ai.process(host, date): the day's AI (CGameState::ProcessAI)
function ai.process(host, date)
    local today = date_text(date)
    local commands = {}
    local research = require("engine.ai.research")
    ai.stats.days = ai.stats.days + 1
    for _, country in ipairs(world.all("country")) do
        local c = world.object("country", country)
        if c and type(world.field(c, "ai")) == "table" and setting(country, "enabled") and not human(country) then
            ai.stats.countries = ai.stats.countries + 1
            -- the modules' daily updates, in the country type's module order (military, foreign,
            -- interior, ...): only the interior minister's research is ported
            if setting(country, "tech") and has_module(country, "interior_minister_module") then
                research.daily(country, today, commands)
            end
        end
    end
    ai.stats.commands = ai.stats.commands + #commands
    for _, cmd in ipairs(commands) do
        if execute(cmd, today) then
            ai.stats.executed = ai.stats.executed + 1
        end
    end
end

function ai.report()
    local s = ai.stats
    local r = require("engine.ai.research").stats
    return string.format("ai: %d days, %d country-days; research: %d draws, %d picks; %d commands, %d executed",
        s.days, s.countries, r.draws, r.picks, s.commands, s.executed)
end

return ai
