-- engine/colonies.lua : the colonies' and pop groups' daily recalculations, the way the game does them
-- each day (GOG 4.5.2, docs/colonies.md):
--
-- NColonyUpdate::DailyParallelUpdate (0xe3a340), the daily `colonies_parallel` phase, per colony
-- CColony::DailyUpdateSelfDontReadOthers (0xdbc410 -> 0xddbe50):
--   CalcEmployablePops                         -> employable_pops
--   MicroUpdateCachedValues (0xdd5190)         -> num_sapient_pops, total_housing, housing_usage,
--                                                 free_housing, amenities, amenities_usage,
--                                                 free_amenities, stability, crime
--   CalcCachedUnemployedPopStatus (0xdc16b0)   -> unemploy_pop, civilian
-- from the colony's modifier node and its pop groups' cached values (those of the previous day:
-- the pop groups' phase comes later in the day).
--
-- CPopGroup::DailyUpdateOnlyChangeSafePrivate (0x676d10) + DailyUpdateSelfDoNotReadOthers
-- (0x677400), the game's daily `pop_groups` phase, per pop group:
--   happiness (CalcHappinessWithModifier 0x67e820), power (BASE_POLITICAL_POWER and two
--   multipliers), crime (CalcCrime 0x67f7b0, from the previous day's happiness), amenities_usage
--   (CalcAmenitiesUsage 0x67ffa0). colonies.pop_groups_daily does this; until the tick calls it in
--   the pop group phase, daily_serial calls it at its end (nothing between the two phases changes
--   what it reads).
--
-- Numbers are the game's fixed point (CFixedPoint, int64, 1.0 = 100000) in LuaJIT int64, so the
-- truncations are the game's. No random draws: the parallel phase forbids them.
--
--   local colonies = require("engine.colonies")
--   colonies.daily_parallel(host, date)   -- the colonies' day
--   colonies.daily_serial(host, date)     -- the pop groups' day (see above)
--   colonies.colony_values(cid)           -- { stability = <fixed>, ... } without writing
--   colonies.pop_group_values(gid[, size])-- { happiness = <fixed>, ... } without writing
--   colonies.micro_update(cid)            -- MicroUpdateCachedValues written (after a size change)
--   colonies.report()

local ffi = require("ffi")
local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local colonies = {
    stats = {
        days = 0, colony_updates = 0, pop_group_updates = 0, colonies_changed = 0, groups_changed = 0,
        rule_errors = 0, borrowed_modifiers = 0, no_modifiers = 0,
    },
    rule_errors = {},   -- rule name -> the last error
}

-- ---------------------------------------------------------------------------------------------
-- fixed point (CFixedPoint): int64, 1.0 = 100000; * and / truncate toward zero as the game's do

local I64 = ffi.typeof("int64_t")
local ONE = 100000
local ZERO = I64(0)
local BIG = I64(4294967295)   -- what the game's division by zero gives

local function fx(v)          -- a number of the capture (fixed / 1e5) as the game holds it
    if v == nil then return ZERO end
    return I64(math.floor(v * ONE + 0.5))
end
local function fmul(a, b)
    return I64(a) * b / ONE
end
local function fdiv(a, b)
    if b == 0 then return BIG end
    return I64(a) * ONE / b
end
local function fmax(a, b) if a > b then return a end return b end
local function fmin(a, b) if a < b then return a end return b end
local function num(a)         -- fixed -> a Lua number (for the save's text)
    return tonumber(a) / ONE
end
colonies.fixed = { fx = fx, fmul = fmul, fdiv = fdiv, num = num, ONE = ONE }

-- a decimal of the script files as fixed (5 decimals, the rest cut)
local function fixed_text(s, default)
    s = s and tostring(s)
    if not s or not s:match("^%s*-?%d*%.?%d*%s*$") then
        return I64(default or 0)
    end
    local neg, ip, fp = s:match("^%s*(-?)(%d*)%.?(%d*)")
    local v = I64(tonumber(ip ~= "" and ip or "0")) * ONE + I64(tonumber(((fp or "") .. "00000"):sub(1, 5)))
    return neg == "-" and -v or v
end

-- ---------------------------------------------------------------------------------------------
-- defines (common/defines)

local D
local function defines()
    if D == nil then
        local function f(group, key, default)
            local g = defs.get("common/defines", group)
            return fixed_text(g and defs.field(g.block, key) or default)
        end
        local function s(group, key, default)
            local g = defs.get("common/defines", group)
            local v = g and defs.field(g.block, key)
            return v and tostring(v):gsub('"', "") or default
        end
        D = {
            -- NGameplay
            BASE_AMENITIES_USAGE = f("NGameplay", "BASE_AMENITIES_USAGE", "500"),
            MIN_PLANET_STABILITY = f("NGameplay", "MIN_PLANET_STABILITY", "0"),
            BASE_PLANET_STABILITY = f("NGameplay", "BASE_PLANET_STABILITY", "50"),
            MAX_PLANET_STABILITY = f("NGameplay", "MAX_PLANET_STABILITY", "100"),
            ADDITIONAL_PLANET_STABILITY_LIMIT = f("NGameplay", "ADDITIONAL_PLANET_STABILITY_LIMIT", "15"),
            LOW_HAPPINESS_STABILITY_EFFECT = f("NGameplay", "LOW_HAPPINESS_STABILITY_EFFECT", "-50"),
            HIGH_HAPPINESS_STABILITY_EFFECT = f("NGameplay", "HIGH_HAPPINESS_STABILITY_EFFECT", "30"),
            POP_CRIME = f("NGameplay", "POP_CRIME", "0.02"),
            MIN_PLANET_CRIME = f("NGameplay", "MIN_PLANET_CRIME", "0"),
            MAX_PLANET_CRIME = f("NGameplay", "MAX_PLANET_CRIME", "100"),
            AI_FULL_RIGHTS_POLICY_FLAG = s("NGameplay", "AI_FULL_RIGHTS_POLICY_FLAG", "ai_full_rights"),
            -- NPop
            BASE_HAPPINESS = f("NPop", "BASE_HAPPINESS", "0.5"),
            BASE_POLITICAL_POWER = f("NPop", "BASE_POLITICAL_POWER", "0.01"),
            MIN_PP_POSITIVE = f("NPop", "MIN_POLITICAL_POWER_POSITIVE_STABILITY_IMPACT", "0"),
            MAX_PP_POSITIVE = f("NPop", "MAX_POLITICAL_POWER_POSITIVE_STABILITY_IMPACT", "20"),
            MIN_PP_NEGATIVE = f("NPop", "MIN_POLITICAL_POWER_NEGATIVE_STABILITY_IMPACT", "0.05"),
            MAX_PP_NEGATIVE = f("NPop", "MAX_POLITICAL_POWER_NEGATIVE_STABILITY_IMPACT", "20"),
        }
    end
    return D
end
colonies.defines = defines

-- ---------------------------------------------------------------------------------------------
-- the world

local NONE = 4294967295

local function int(v)
    return tonumber(v) or 0
end

-- the first `key = value` statement of obj and its position (engine.world.entry: by the key index
-- with the world in the store)
local function entry(obj, key)
    return world.entry(obj, key)
end

-- obj's `key = value` in the save's order: value nil removes it; a new one goes after the closest
-- key before it in `order` that obj has (else before the closest after it, else at the end)
local function put(obj, key, value, order)
    local e = entry(obj, key)
    if value == nil then
        if e then world.remove_entry(obj, e) return true end
        return false
    end
    local text = type(value) == "string" and value or world.number_text(value)
    if e then
        if e.value.text == text then return false end
        world.set(obj, key, text)
        return true
    end
    local at
    if order then
        local k
        for i, name in ipairs(order) do
            if name == key then k = i break end
        end
        if k then
            for i = k - 1, 1, -1 do
                local _, j = entry(obj, order[i])
                if j then at = j + 1 break end
            end
            if not at then
                for i = k + 1, #order do
                    local _, j = entry(obj, order[i])
                    if j then at = j break end
                end
            end
        end
    end
    world.insert(obj, at or (#obj + 1), key, text)
    return true
end

-- a fixed value as the save writes it, or nil for the field's default (left out by WriteMembers)
local function fixed_or_nil(v, default)
    if v == default then return nil end
    return num(v)
end

local function group_key(g)
    local key = world.field(g, "key")
    if type(key) ~= "table" then return nil, nil end
    return tonumber(world.field(key, "species")), world.field(key, "category")
end

local function living_groups(c)
    local out = {}
    for _, t in ipairs(world.list(world.field(c, "pop_groups"))) do
        local id = tonumber(t)
        local g = id and world.object("pop_groups", id)
        if g and world.field(g, "killed") ~= "yes" then
            out[#out + 1] = id
        end
    end
    return out
end

local function species_obj(sid)
    return sid and world.object("species_db", sid)
end

-- CSpecies settings bit 0 (IsSapient): the save's `sapient = no` clears it
local function is_sapient(sid)
    local s = species_obj(sid)
    return s ~= nil and world.field(s, "sapient") ~= "no"
end

-- the species' archetype (common/species_classes: archetype) and its definition
local archetype_cache = {}
local function archetype(sid)
    local s = species_obj(sid)
    local class = s and world.field(s, "class")
    if not class then return nil end
    local a = archetype_cache[class]
    if a == nil then
        local d = defs.get("common/species_classes", class)
        a = d and defs.field(d.block, "archetype") or false
        archetype_cache[class] = a
    end
    return a or nil
end
local function archetype_def(name)
    return name and defs.get("common/species_archetypes", name)
end
-- CSpeciesClass -> archetype _bRobotic
local function is_robotic(sid)
    local d = archetype_def(archetype(sid))
    return d ~= nil and defs.field(d.block, "robotic") == "yes"
end

-- a pop category's definition (common/pop_categories)
local category_cache = {}
local function category_def(name)
    if not name then return nil end
    local c = category_cache[name]
    if c == nil then
        local d = defs.get("common/pop_categories", name)
        c = d and {
            civilian = defs.field(d.block, "is_civilian_job") == "yes",
            unemployment = defs.field(d.block, "is_unemployment_job") == "yes",
        } or false
        category_cache[name] = c
    end
    return c or nil
end

-- the colony's owner (its planet's owner)
local function owner_of(cid)
    local pid = world.colony_planet[cid]
    local p = pid and world.object("planet", pid)
    local o = p and tonumber(world.field(p, "owner"))
    if o == NONE then o = nil end
    return o, pid
end

local function has_policy_flag(country, flag)
    local c = country and world.object("country", country)
    local flags = c and world.field(c, "policy_flags")
    if type(flags) ~= "table" then return false end
    for _, t in ipairs(world.list(flags)) do
        if t == flag then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- modifiers: the economy's source (the capture until the graph is built from the world)

local function source_modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    if not (economy and economy.has_modifier_source and economy.has_modifier_source()) then
        return nil
    end
    return economy.modifiers(kind, id)
end

local function mod(M, name)
    return fx(M and M[name])
end

-- a pop group's node; one the source does not have (a group made after the capture) borrows the
-- node of a group of the same species on the same colony (a stand-in, counted)
local function pop_group_modifiers(gid, g)
    local M = source_modifiers("pop_group", gid)
    if M then return M end
    local cid = tonumber(world.field(g, "planet"))
    local c = cid and world.object("colony", cid)
    local sid = group_key(g)
    if c then
        local fallback
        for _, other in ipairs(living_groups(c)) do
            if other ~= gid then
                local og = world.object("pop_groups", other)
                local M2 = source_modifiers("pop_group", other)
                if M2 then
                    if group_key(og) == sid then
                        colonies.stats.borrowed_modifiers = colonies.stats.borrowed_modifiers + 1
                        return M2
                    end
                    fallback = fallback or M2
                end
            end
        end
        if fallback then
            colonies.stats.borrowed_modifiers = colonies.stats.borrowed_modifiers + 1
            return fallback
        end
    end
    colonies.stats.no_modifiers = colonies.stats.no_modifiers + 1
    return {}
end

-- ---------------------------------------------------------------------------------------------
-- the game rules (common/game_rules) through the script layer

local rule_cache = {}   -- (rule, this, from) -> bool, for the day

local function rule(name, ctx, default)
    local d = defs.get("common/game_rules", name)
    if not d then return default end
    local ok, holds = pcall(eval.trigger, d.block, ctx)
    if not ok then
        colonies.stats.rule_errors = colonies.stats.rule_errors + 1
        colonies.rule_errors[name] = tostring(holds)
        return default
    end
    return holds and true or false
end

local function cached_rule(name, kind, id, from, default)
    local k = name .. "|" .. kind .. "|" .. tostring(id) .. "|" .. tostring(from)
    local v = rule_cache[k]
    if v == nil then
        local ctx = eval.new_ctx(eval.S(kind, id), from and eval.S("country", from) or nil)
        v = rule(name, ctx, default)
        rule_cache[k] = v
    end
    return v
end

-- CPopGroup::HasHappiness (0x67e4a0): CCountry::SpeciesHasHappiness (the country's cache of the rule)
-- or the rule species_has_happiness (This = species, From = the owner)
local function has_happiness(sid, owner)
    if not sid then return false end
    return cached_rule("species_has_happiness", "species", sid, owner, true)
end

-- CPopGroup::HasHappinessEffects (0x67e5a0): a robotic species' pops count only with the owner's
-- AI_FULL_RIGHTS_POLICY_FLAG; then HasHappiness
local function has_happiness_effects(sid, owner)
    if is_robotic(sid) and not has_policy_flag(owner, defines().AI_FULL_RIGHTS_POLICY_FLAG) then
        return false
    end
    return has_happiness(sid, owner)
end

-- CGameRules::IsPsionicSpecies: rule is_psionic_species (This = species)
local function is_psionic(sid)
    return sid ~= nil and cached_rule("is_psionic_species", "species", sid, nil, false)
end

-- CGameRules::PopGroupGeneratesCrime: rule pop_group_generates_crime (This = the pop group); a
-- stand-in when the script layer cannot evaluate it: the species is sapient
local function generates_crime(gid, sid)
    return cached_rule("pop_group_generates_crime", "pop_group", gid, nil, is_sapient(sid))
end

-- ---------------------------------------------------------------------------------------------
-- the pop group's day: CPopGroup::DailyUpdateOnlyChangeSafePrivate (0x676d10)

local ARCHETYPE_HAPPINESS = {}
local function archetype_happiness(M, sid)
    local name = archetype(sid)
    local d = archetype_def(name)
    -- CSpeciesArchetype _bUsesModifiers (+0x229) and its _PopHappinessModifier (+0x1b0):
    -- <archetype>_pop_happiness (some are defined lower case)
    if not d or defs.field(d.block, "uses_modifiers") == "no" then return ZERO end
    local names = ARCHETYPE_HAPPINESS[name]
    if not names then
        names = { name .. "_pop_happiness", name:lower() .. "_pop_happiness" }
        ARCHETYPE_HAPPINESS[name] = names
    end
    for _, n in ipairs(names) do
        if M[n] then return fx(M[n]) end
    end
    return ZERO
end

-- colonies.pop_group_values(gid[, size]) -> { happiness, power, crime, amenities_usage,
-- has_happiness } (fixed), from the group's node, its size (or `size`), and its cached happiness
-- (the previous day's, which CalcCrime reads)
function colonies.pop_group_values(gid, size)
    local d = defines()
    local g = world.object("pop_groups", gid)
    if not g then return nil end
    size = size or int(world.field(g, "size"))
    local sid, cat = group_key(g)
    local cid = tonumber(world.field(g, "planet"))
    local owner = cid and owner_of(cid)
    local M = pop_group_modifiers(gid, g)
    local out = {}

    -- happiness (CalcHappinessWithModifier 0x67e820): BASE_HAPPINESS + pop_happiness + the
    -- archetype's + pop_citizen_happiness (groups that can vote: EPopGroupFlags bit 5, the save's
    -- can_vote, set the day before) + pop_cat_<category>_happiness, within [0, 1]; BASE_HAPPINESS
    -- for a group without happiness
    local has = has_happiness(sid, owner)
    out.has_happiness = has
    if has then
        local h = d.BASE_HAPPINESS + mod(M, "pop_happiness") + archetype_happiness(M, sid)
        if world.field(g, "can_vote") == "yes" then
            h = h + mod(M, "pop_citizen_happiness")
        end
        if cat then
            h = h + mod(M, "pop_cat_" .. cat .. "_happiness")
        end
        if h < 0 then h = ZERO elseif h > ONE then h = I64(ONE) end
        out.happiness = h
    else
        out.happiness = d.BASE_HAPPINESS
    end

    -- political power: size * BASE_POLITICAL_POWER * max(0, 1 + pop_political_power), then
    -- CModifier::ApplyModifierMult with the category's pop_cat_<category>_political_power
    local p = I64(size) * d.BASE_POLITICAL_POWER
    p = fmul(p, fmax(ZERO, ONE + mod(M, "pop_political_power")))
    if cat then
        p = fmul(p, fmax(ZERO, ONE + mod(M, "pop_cat_" .. cat .. "_political_power")))
    end
    out.power = p

    -- crime (CalcCrime 0x67f7b0): size * POP_CRIME * (1 - the cached happiness), 0 when the group
    -- generates no crime
    local cached = world.field(g, "happiness")
    local hprev = cached and fixed_text(cached) or I64(ONE)   -- left out of the save at 1.0
    if generates_crime(gid, sid) then
        out.crime = fmul(I64(size) * d.POP_CRIME, ONE - hprev)
    else
        out.crime = ZERO
    end

    -- amenities usage (CalcAmenitiesUsage 0x67ffa0): size * (base + add + no_happiness base + add)
    -- * max(0, 1 + mult + no_happiness_mult + the organic or robotic mult + the psionic mult), at
    -- least 0
    local base = mod(M, "pop_amenities_usage_base") + mod(M, "pop_amenities_usage_add")
        + mod(M, "pop_amenities_usage_no_happiness_base") + mod(M, "pop_amenities_usage_no_happiness_add")
    local mult = ONE + mod(M, "pop_amenities_usage_mult") + mod(M, "pop_amenities_usage_no_happiness_mult")
    if is_robotic(sid) then
        mult = mult + mod(M, "pop_amenities_usage_robotic_mult")
    else
        mult = mult + mod(M, "pop_amenities_usage_organic_mult")
    end
    if is_psionic(sid) then
        mult = mult + mod(M, "pop_amenities_usage_psionic_mult")
    end
    local u = fmul(I64(size) * base, fmax(ZERO, mult))
    if u < 0 then u = ZERO end
    out.amenities_usage = u
    return out
end

local PG_ORDER = { "ethics_attraction", "habitability", "timed_modifier", "flags", "variables", "happiness",
    "power", "crime", "amenities_usage", "housing_usage" }

-- the values written in the save's form (CPopGroup::WriteMembers: happiness when not 1, the others
-- when not 0)
local function write_pop_group(g, v)
    local changed = false
    changed = put(g, "happiness", fixed_or_nil(v.happiness, I64(ONE)), PG_ORDER) or changed
    changed = put(g, "power", fixed_or_nil(v.power, ZERO), PG_ORDER) or changed
    changed = put(g, "crime", fixed_or_nil(v.crime, ZERO), PG_ORDER) or changed
    changed = put(g, "amenities_usage", fixed_or_nil(v.amenities_usage, ZERO), PG_ORDER) or changed
    return changed
end

-- colonies.pop_groups_daily(host, date): every living pop group of a colony, computed from the
-- world as it is, then written (DailyUpdateOnlyChangeSafePrivate, then DailyUpdateSelfDoNotReadOthers)
local function pop_groups_daily()
    local s = colonies.stats
    local values = {}
    local order = {}
    for _, cid in ipairs(world.all("colony")) do
        local c = world.object("colony", cid)
        if c and world.colony_planet[cid] then
            for _, gid in ipairs(living_groups(c)) do
                values[gid] = colonies.pop_group_values(gid)
                order[#order + 1] = gid
            end
        end
    end
    for _, gid in ipairs(order) do
        local g = world.object("pop_groups", gid)
        if write_pop_group(g, values[gid]) then
            s.groups_changed = s.groups_changed + 1
        end
        s.pop_group_updates = s.pop_group_updates + 1
    end
end

-- ---------------------------------------------------------------------------------------------
-- the colony's day: CColony::MicroUpdateCachedValues (0xdd5190) and the counts of
-- DailyUpdateSelfDontReadOthers

local function group_fixed(g, key, default)
    local v = world.field(g, key)
    if v == nil then return default end
    return fixed_text(v)
end

-- CColony::CalcAverageHappiness (0xdb4a50): the happiness of the sapient, living groups (BASE_HAPPINESS
-- for those without happiness effects) weighted by their political power, the power held within
-- [MIN, MAX]_POLITICAL_POWER_<NEGATIVE|POSITIVE>_STABILITY_IMPACT by the side of BASE_HAPPINESS the
-- group is on; nil when no power
local function average_happiness(c, owner)
    local d = defines()
    local sum, weight = ZERO, ZERO
    for _, gid in ipairs(living_groups(c)) do
        local g = world.object("pop_groups", gid)
        local sid = group_key(g)
        if is_sapient(sid) then
            local h = d.BASE_HAPPINESS
            if has_happiness_effects(sid, owner) then
                h = group_fixed(g, "happiness", I64(ONE))
            end
            local p = group_fixed(g, "power", ZERO)
            local lo, hi
            if h < d.BASE_HAPPINESS then
                lo, hi = d.MIN_PP_NEGATIVE, d.MAX_PP_NEGATIVE
            else
                lo, hi = d.MIN_PP_POSITIVE, d.MAX_PP_POSITIVE
            end
            if p < lo then p = lo elseif p > hi then p = hi end
            sum = sum + fmul(p, h)
            weight = weight + p
        end
    end
    if weight <= 0 then return nil end
    return fdiv(sum, weight)
end

-- CColony::IsColony (0xdbb330): being colonized, or sapient pops (the owner's country type flag
-- that also makes one is not modelled)
local function is_colony(c, sapient)
    local cs = tonumber(world.field(c, "colonizing_species"))
    if cs and cs ~= NONE then return true end
    return sapient > 0
end

-- colonies.colony_values(cid) -> the colony's cached values (fixed for the CFixedPoint ones,
-- integers for the counts), from its node and its pop groups' cached values
function colonies.colony_values(cid)
    local d = defines()
    local c = world.object("colony", cid)
    if not c then return nil end
    local owner = owner_of(cid)
    local M = source_modifiers("colony", cid) or {}
    local groups = living_groups(c)
    local out = {}

    -- CalcEmployablePops: the living groups' sizes; CalcSapientPopAmount: the groups of sapient
    -- species (killed ones too: they are empty)
    local employable, sapient = 0, 0
    for _, t in ipairs(world.list(world.field(c, "pop_groups"))) do
        local gid = tonumber(t)
        local g = gid and world.object("pop_groups", gid)
        if g then
            local size = int(world.field(g, "size"))
            if world.field(g, "killed") ~= "yes" then employable = employable + size end
            if is_sapient(group_key(g)) then sapient = sapient + size end
        end
    end
    out.employable_pops, out.num_sapient_pops = employable, sapient
    local colony = is_colony(c, sapient)

    -- housing: max(0, planet_housing_add) * max(0, 1 + planet_housing_mult); the groups' usage
    local housing = fmul(fmax(ZERO, mod(M, "planet_housing_add")), fmax(ZERO, ONE + mod(M, "planet_housing_mult")))
    local husage, ausage, pcrime = ZERO, ZERO, ZERO
    for _, gid in ipairs(groups) do
        local g = world.object("pop_groups", gid)
        husage = husage + group_fixed(g, "housing_usage", ZERO)
        ausage = ausage + group_fixed(g, "amenities_usage", ZERO)
        pcrime = pcrime + group_fixed(g, "crime", ZERO)
    end
    out.total_housing, out.housing_usage, out.free_housing = housing, husage, housing - husage

    -- amenities (CalcAmenities 0xdb3730): max(0, planet_amenities_add + no_happiness_add) *
    -- max(0, 1 + planet_amenities_mult + no_happiness_mult); usage: the groups' + BASE_AMENITIES_USAGE
    if colony then
        local add = fmax(ZERO, mod(M, "planet_amenities_add") + mod(M, "planet_amenities_no_happiness_add"))
        local mult = fmax(ZERO, ONE + mod(M, "planet_amenities_mult") + mod(M, "planet_amenities_no_happiness_mult"))
        out.amenities = fmul(add, mult)
        out.amenities_usage = ausage + d.BASE_AMENITIES_USAGE
    else
        out.amenities, out.amenities_usage = ZERO, ZERO
    end
    out.free_amenities = out.amenities - out.amenities_usage

    -- stability (CalcPlanetStability 0xdb3a40)
    if not colony then
        out.stability = ZERO
    elseif (tonumber(world.field(c, "colonizing_species")) or NONE) ~= NONE then
        out.stability = d.BASE_PLANET_STABILITY
    else
        local base = d.BASE_PLANET_STABILITY + fmin(mod(M, "planet_stability_add_with_limit"), d.ADDITIONAL_PLANET_STABILITY_LIMIT)
            + mod(M, "planet_stability_add")
        local st = fmul(base, fmax(ZERO, ONE + mod(M, "planet_stability_mult")))
        local h = average_happiness(c, owner)
        out.average_happiness = h
        if h then
            local effect
            if h < d.BASE_HAPPINESS then
                local r = d.BASE_HAPPINESS ~= 0 and fdiv(h, d.BASE_HAPPINESS) or BIG
                effect = fmul(ONE - r, d.LOW_HAPPINESS_STABILITY_EFFECT)
            else
                local span = ONE - d.BASE_HAPPINESS
                local r = span ~= 0 and fdiv(h - d.BASE_HAPPINESS, span) or BIG
                effect = fmul(r, d.HIGH_HAPPINESS_STABILITY_EFFECT)
            end
            st = st + effect
        end
        out.stability = fmin(fmax(st, d.MIN_PLANET_STABILITY), d.MAX_PLANET_STABILITY)
    end

    -- crime (CalcPlanetCrime 0xdb4d80): (the groups' crime + planet_crime_add + no_happiness_add) *
    -- max(0, 1 + planet_crime_mult + no_happiness_mult), within [max(MIN_PLANET_CRIME,
    -- planet_crime_floor_add), MAX_PLANET_CRIME]
    if colony then
        local add = mod(M, "planet_crime_add") + mod(M, "planet_crime_no_happiness_add")
        local floor = fmax(d.MIN_PLANET_CRIME, mod(M, "planet_crime_floor_add"))
        local mult = fmax(ZERO, ONE + mod(M, "planet_crime_mult") + mod(M, "planet_crime_no_happiness_mult"))
        local cr = fmul(pcrime + add, mult)
        if cr < floor then cr = floor elseif cr > d.MAX_PLANET_CRIME then cr = d.MAX_PLANET_CRIME end
        out.crime = cr
    else
        out.crime = ZERO
    end

    -- CalcCachedUnemployedPopStatus (0xdc16b0): civilians, the groups of a category with
    -- is_civilian_job (NPopUtil::FilterOutGroups); the unemployed, the groups working the colony's
    -- jobs whose category has is_unemployment_job (CPopJob's groups are not in the save: the jobs
    -- update links them; a group works the jobs of its own category, so: the groups of such a
    -- category)
    local civilian, unemployed = 0, 0
    for _, gid in ipairs(groups) do
        local g = world.object("pop_groups", gid)
        local _, cat = group_key(g)
        local cd = category_def(cat)
        if cd and cd.civilian then civilian = civilian + int(world.field(g, "size")) end
        if cd and cd.unemployment then unemployed = unemployed + int(world.field(g, "size")) end
    end
    out.civilian, out.unemploy_pop = civilian, unemployed
    return out
end

local C_ORDER = { "pop_to_kill_from_devastation", "stability", "crime", "amenities", "amenities_usage",
    "free_amenities", "free_housing", "total_housing", "housing_usage", "employable_pops", "unemploy_pop",
    "civilian", "num_sapient_pops", "manual_designation_changed_date" }

local function count_or_nil(n)
    if n == 0 then return nil end
    return n
end

-- the colony's values in the save's form (CColony::WriteMembers: the fixed ones always, the counts
-- when not 0)
local function write_colony(c, v, opts)
    local changed = false
    local function w(key, value) changed = put(c, key, value, C_ORDER) or changed end
    w("stability", num(v.stability))
    w("crime", num(v.crime))
    w("amenities", num(v.amenities))
    w("amenities_usage", num(v.amenities_usage))
    w("free_amenities", num(v.free_amenities))
    if not (opts and opts.no_housing) then
        w("free_housing", num(v.free_housing))
        w("total_housing", num(v.total_housing))
        w("housing_usage", num(v.housing_usage))
    end
    w("employable_pops", count_or_nil(v.employable_pops))
    if not (opts and opts.no_counts) then
        w("unemploy_pop", count_or_nil(v.unemploy_pop))
        w("civilian", count_or_nil(v.civilian))
    end
    w("num_sapient_pops", count_or_nil(v.num_sapient_pops))
    return changed
end

-- colonies.micro_update(cid): CColony::MicroUpdateCachedValues written (what the game does after a
-- pop group's size changed, CColony::OnAddPops / OnRemovePops: the counts of the day stay)
function colonies.micro_update(cid)
    local c = world.object("colony", cid)
    if not c then return false end
    return write_colony(c, colonies.colony_values(cid), { no_counts = true })
end

-- ---------------------------------------------------------------------------------------------
-- the phases

local function with_script(f, ...)
    return require("engine.colonies.script").with(f, ...)
end
colonies.with_script = with_script

local function colonies_daily()
    local s = colonies.stats
    rule_cache = {}
    s.days = s.days + 1
    for _, cid in ipairs(world.all("colony")) do
        local c = world.object("colony", cid)
        if c and world.colony_planet[cid] then
            if write_colony(c, colonies.colony_values(cid)) then
                s.colonies_changed = s.colonies_changed + 1
            end
            s.colony_updates = s.colony_updates + 1
        end
    end
end

-- NColonyUpdate::DailyParallelUpdate: every colony's CColony::DailyUpdateSelfDontReadOthers (the
-- cached values; no random draws)
function colonies.daily_parallel(host, date)
    return with_script(colonies_daily)
end

-- the pop groups' day (CPopGroup::DailyUpdateOnlyChangeSafePrivate and
-- DailyUpdateSelfDoNotReadOthers in the game's pop group phase, which comes after the colonies')
function colonies.pop_groups_daily(host, date)
    rule_cache = {}
    return with_script(pop_groups_daily)
end

-- NColonyUpdate::DailySerialUpdate: the jobs, on_actions, construction, events and ground combat
-- of CColony::DailyUpdateSerial are not modelled here. The pop groups' day runs in the pop group
-- phase (systems.lua: daily.pop_groups calls colonies.pop_groups_daily); set pop_groups_in_serial
-- to run it here instead.
colonies.pop_groups_in_serial = false
function colonies.daily_serial(host, date)
    if colonies.pop_groups_in_serial then
        colonies.pop_groups_daily(host, date)
    end
end

function colonies.report()
    local s = colonies.stats
    local errs = {}
    for k, v in pairs(colonies.rule_errors) do errs[#errs + 1] = k .. ": " .. v end
    table.sort(errs)
    return string.format("colonies: %d days, %d colony updates (%d changed), %d pop group updates (%d changed); "
        .. "%d pop group nodes borrowed from a sibling, %d without a node; %d rule errors%s", s.days, s.colony_updates,
        s.colonies_changed, s.pop_group_updates, s.groups_changed, s.borrowed_modifiers, s.no_modifiers,
        s.rule_errors, #errs > 0 and (" (" .. table.concat(errs, "; ") .. ")") or "")
end

return colonies
