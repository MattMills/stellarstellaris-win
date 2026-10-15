-- engine/leaders.lua : leader experience, the way the game gives it each month (GOG 4.5.2):
--
-- CCountry::MonthlyUpdateSerial (with a government):
--   the ruler          LEADER_RULER_EXPERIENCE
--   the heir           LEADER_HEIR_EXPERIENCE
--   each councilor     LEADER_COUNCILOR_MONTHLY_EXPERIENCE (the government's council positions)
-- CStandardLeaderCountryModule::MonthlyUpdateSerial: every owned leader whose class can have traits
--   (can_have_traits, ELeaderClassAbility bit 14), not the ruler and not idle (CLeader::IsIdle: no
--   location and not on the council)          LEADER_ASSIGNED_MONTHLY_EXPERIENCE
--
-- CLeader::AddExperience(amount):
--   nothing at the skill cap (CLeader::CalcSkillCap: min(LEADER_MAX_SKILL_CAP, LEADER_BASE_SKILL_CAP
--   + leader_skill_levels + <class>_skill_levels))
--   amount * max(0, 1 + species_leader_exp_gain + <class>_exp_gain
--                    + on the council: councilor_exp_gain + <position type>_exp_gain)
--          * LEADER_CAPACITY_XP_SCALE ^ (leaders of the class over the class's cap)
--     (CCountry::CalcLeaderCapExceededXpPenalty: the cap is the class's leader_capacity +
--     country_leader_cap_add + country_<class>_cap_add, 0 for none; the leaders counted are those
--     of the game rule should_count_towards_leader_cap)
--   experience += it; then while below the cap and experience >= the next level's requirement
--   (sum over k from LEADER_SKILL_MIN to the level of BASE + k * SCALE): experience -= it, level + 1
--   (CLeader::LevelUp; the traits it offers are not modelled yet)
--
-- The modifiers are the economy's source (the capture until the graph is built from the world).
-- Not modelled: the experience of fleet orders (surveys, anomalies, reconnaissance), combat,
-- special projects, archaeology and effects (add_experience goes through leaders.add_experience).

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local defs = require("engine.defs")
local eval = require("simscript.eval")

local leaders = {
    stats = { given = 0, amount = 0, level_ups = 0, at_cap = 0, over_cap_penalties = 0 },
}

local D
local function define(group, key, default)
    local g = defs.get("common/defines", group)
    local v = g and tonumber(defs.field(g.block, key))
    return v or default
end
local function defines()
    if D == nil then
        D = {
            RULER = define("NGameplay", "LEADER_RULER_EXPERIENCE", 12),
            HEIR = define("NGameplay", "LEADER_HEIR_EXPERIENCE", 1),
            COUNCILOR = define("NGameplay", "LEADER_COUNCILOR_MONTHLY_EXPERIENCE", 5),
            ASSIGNED = define("NGameplay", "LEADER_ASSIGNED_MONTHLY_EXPERIENCE", 5),
            SKILL_MIN = define("NGameplay", "LEADER_SKILL_MIN", 1),
            BASE_CAP = define("NGameplay", "LEADER_BASE_SKILL_CAP", 10),
            MAX_CAP = define("NGameplay", "LEADER_MAX_SKILL_CAP", 10),
            REQ_BASE = define("NGameplay", "LEADER_EXPERIENCE_REQUIREMENT_BASE_VALUE", 100),
            REQ_SCALE = define("NGameplay", "LEADER_EXPERIENCE_REQUIREMENT_SCALE_VALUE", 300),
            XP_SCALE = define("NGameplay", "LEADER_CAPACITY_XP_SCALE", 0.85),
        }
    end
    return D
end

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers(kind, id) or {}
end

local function class_def(class)
    local d = class and defs.get("common/leader_classes", class)
    return d and d.block
end

-- the council: leader -> position type, from each government's own council_positions (the list
-- CCountry::MonthlyUpdateSerial walks); the ruler sits on the council too, in the ruler's seat of the
-- authority (councilor_ruler_<authority>), which is not in that list
local council, rulers
local function council_of()
    if council == nil then
        council, rulers = {}, {}
        for _, country in ipairs(world.all("country")) do
            slice.tick("leaders.lua:77")
            local c = world.object("country", country)
            local gov = world.field(c, "government")
            if type(gov) == "table" then
                for _, pid in ipairs(world.list(world.field(gov, "council_positions"))) do
                    local p = world.object("council_positions", tonumber(pid))
                    local l = p and tonumber(world.field(p, "leader"))
                    if l and l ~= 4294967295 then
                        council[l] = world.field(p, "type")
                    end
                end
                local ruler = tonumber(world.field(c, "ruler"))
                local auth = tostring(world.field(gov, "authority") or ""):gsub("^auth_", "")
                if ruler and ruler ~= 4294967295 then
                    rulers[ruler] = country
                    council[ruler] = council[ruler] or ("councilor_ruler_" .. auth)
                end
            end
        end
    end
    return council
end

-- CGameRules::CanCountryChangeCouncilors (common/game_rules can_country_change_councilors)
local change_cache
local function can_change_councilors(country)
    change_cache = change_cache or {}
    local v = change_cache[country]
    if v == nil then
        v = true
        local rule = defs.get("common/game_rules", "can_country_change_councilors")
        if rule then
            local ok, holds = pcall(eval.trigger, rule.block, eval.new_ctx(eval.S("country", country), nil, nil, rule.file))
            v = not ok or holds and true or false
        end
        change_cache[country] = v
    end
    return v
end

-- the experience the next level needs (CLeader::AddExperience's loop)
function leaders.requirement(level)
    local d = defines()
    local need = 0
    for k = d.SKILL_MIN, level do
        need = need + d.REQ_BASE + k * d.REQ_SCALE
    end
    return need
end

function leaders.skill_cap(id, l)
    local d = defines()
    local M = modifiers("leader", id)
    local class = world.field(l, "class")
    local cap = d.BASE_CAP + (M.leader_skill_levels or 0) + (M[tostring(class) .. "_skill_levels"] or 0)
    return math.min(d.MAX_CAP, math.floor(cap))
end

-- the leader cap penalty of a country for a class: XP_SCALE ^ (counted leaders - cap), or 1
local penalty_cache = {}
local function cap_penalty(country, class)
    local key = tostring(country) .. "/" .. tostring(class)
    local p = penalty_cache[key]
    if p then
        return p
    end
    p = 1
    local cd = class_def(class)
    local base = cd and tonumber(defs.field(cd, "leader_capacity"))
    if base == nil and cd then
        local v = defs.field(cd, "leader_capacity")
        base = v and tonumber(eval.value({ text = tostring(v) }, eval.new_ctx(eval.S("country", country), nil, nil, (defs.get("common/leader_classes", class) or {}).file)))
    end
    if base and base > 0 then
        local M = modifiers("country", country)
        local cap = math.floor(base + (M.country_leader_cap_add or 0) + (M["country_" .. class .. "_cap_add"] or 0) + 0.5)
        local rule = defs.get("common/game_rules", "should_count_towards_leader_cap")
        local used = 0
        local c = world.object("country", country)
        for _, lid in ipairs(world.list(world.field(c, "owned_leaders"))) do
            local l = world.object("leaders", tonumber(lid))
            if l and world.field(l, "class") == class then
                local counts = true
                if rule then
                    local ok, holds = pcall(eval.trigger, rule.block, eval.new_ctx(eval.S("leader", tonumber(lid)), nil, nil, rule.file))
                    counts = not ok or holds
                end
                if counts then
                    used = used + 1
                end
            end
        end
        if used > cap then
            p = defines().XP_SCALE ^ (used - cap)
            leaders.stats.over_cap_penalties = leaders.stats.over_cap_penalties + 1
        end
    end
    penalty_cache[key] = p
    return p
end

-- leaders.add_experience(id, amount): CLeader::AddExperience
function leaders.add_experience(id, amount)
    local l = world.object("leaders", id)
    if not l or not amount or amount == 0 then
        return
    end
    local exp = tonumber(world.field(l, "experience")) or 0
    if amount < 0 then
        world.set(l, "experience", exp + amount)
        return
    end
    local level = tonumber(world.field(l, "level")) or defines().SKILL_MIN
    local cap = leaders.skill_cap(id, l)
    if level >= cap then
        leaders.stats.at_cap = leaders.stats.at_cap + 1
        return
    end
    local M = modifiers("leader", id)
    local class = tostring(world.field(l, "class"))
    local mult = 1 + (M.species_leader_exp_gain or 0) + (M[class .. "_exp_gain"] or 0)
    local position = council_of()[id]
    if position then
        mult = mult + (M.councilor_exp_gain or 0) + (M[position .. "_exp_gain"] or 0)
    end
    amount = amount * math.max(0, mult)
    local owner = tonumber(world.field(l, "country"))
    if owner then
        amount = amount * cap_penalty(owner, class)
    end
    exp = exp + amount
    leaders.stats.given = leaders.stats.given + 1
    leaders.stats.amount = leaders.stats.amount + amount
    while level < cap and exp >= leaders.requirement(level) do
        exp = exp - leaders.requirement(level)
        level = level + 1
        leaders.stats.level_ups = leaders.stats.level_ups + 1
    end
    world.set(l, "experience", math.floor(exp * 100000 + 0.5) / 100000)
    world.set(l, "level", level)
end

-- CLeader::IsIdle: not at a location (a fleet, planet, army, federation, ...); where the country
-- cannot change its councilors (gestalts), the ruler and the councilors are not idle either
local function is_idle(id, l, country)
    local loc = world.field(l, "location")
    local ty = type(loc) == "table" and world.field(loc, "type") or nil
    if ty ~= nil and ty ~= "none" then
        return false
    end
    if not can_change_councilors(country) and council_of()[id] then
        return false
    end
    return true
end

-- leaders.monthly(): every country's leaders' experience of the month (the countries' monthly
-- serial phase)
function leaders.monthly()
    council, penalty_cache, change_cache = nil, {}, nil
    local d = defines()
    for _, country in ipairs(world.all("country")) do
        slice.tick("leaders.lua:238")
        local c = world.object("country", country)
        local gov = world.field(c, "government")
        local ruler = tonumber(world.field(c, "ruler"))
        if type(gov) == "table" then
            if ruler and ruler ~= 4294967295 then
                leaders.add_experience(ruler, d.RULER)
            end
            local heir = tonumber(world.field(gov, "heir"))
            if heir and heir ~= 4294967295 then
                leaders.add_experience(heir, d.HEIR)
            end
        end
        for _, lid in ipairs(world.list(world.field(c, "owned_leaders"))) do
            local id = tonumber(lid)
            local l = id and world.object("leaders", id)
            if l then
                if council_of()[id] and id ~= ruler then
                    leaders.add_experience(id, d.COUNCILOR)
                end
                local cd = class_def(world.field(l, "class"))
                local traits = not cd or defs.field(cd, "can_have_traits") ~= "no"
                if traits and id ~= ruler and not is_idle(id, l, country) then
                    leaders.add_experience(id, d.ASSIGNED)
                end
            end
        end
    end
end

function leaders.report()
    local s = leaders.stats
    return string.format("leaders: %d experience gains, %.1f experience, %d level ups (traits not offered yet), "
        .. "%d at the skill cap, %d classes over the leader cap", s.given, s.amount, s.level_ups, s.at_cap,
        s.over_cap_penalties)
end

return leaders
