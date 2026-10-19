-- engine/pops.lua : the colonies' monthly pop growth, assembly, decline and colonization, the way the
-- game does them each month (GOG 4.5.2, docs/pops.md):
--
-- NColonyUpdate::MonthlyUpdate (0xe3a7c0), in the monthly `colonies` phase:
--   1. CPopGroup::UpdateCanProcreate on every pop group (parallel)       -- the save's flags are kept
--   2. NColonyUpdate::MonthlyParallelUpdate, per colony:
--        CColony::CalcAutoMigrationSafePrivate                           -- not modelled
--        CColonyDemographyCalculator::MonthlyUpdateSafePrivate           -- pops.demography: growth,
--          (random value: the month's pool at (colony + 266) % 1000)        assembly and decline
--        CColony::CalcTableIncludePops (upkeep, produces, profits)      -- from the month's budget
--        UpdateDesignation, MonthlyAutoModUpdate                         -- not modelled
--   3. NColonyUpdate::MonthlySerialUpdate -> CColony::MonthlyUpdateSerial, per colony:
--        GrowColonists (colonizing; pool at (colony + 6601) % 1000), ApplyAutoMigrationResults (not
--        modelled), ApplyMonthlyGrowth, ApplyMonthlyAssembly, ApplyMonthlyDecline
--   4. NPlanetJobs::UpdatePopJobs, twice                                  -- engine.jobs (the new pops
--                                                                            first in pops.target's group)
--   5. CColony::UpdateCachedGrowth, per colony: the pop groups' and the colony's growth of the month
--
-- Before it, the day's housing (CPopGroup::CalcHousingUsage in the daily pop group phase, which the
-- tick does not hook yet: pops.daily), which the growth reads.
--
-- Numbers are the game's fixed point (CFixedPoint, int64, 1.0 = 100000), computed with LuaJIT int64
-- so that truncations are the game's. The modifiers are the economy's source (the capture until the
-- graph is built from the world). The random values come from the month's pool of 1,000 draws of the
-- global generator (CGameState::MonthlyUpdate draws it first); the platform does not hand it over
-- yet, so pops draws it at the start of the phase (RUST.monthly_pool when there is one).
--
--   local pops = require("engine.pops")
--   pops.monthly(host, date)              -- the month (the colonies phase)
--   pops.daily(host, date)                -- the day's housing (for the daily pop group phase)
--   pops.demography(colony, value[, opts])-- a colony's month: { groups, species, assembly, ... }
--   pops.report()

local ffi = require("ffi")
local bit = require("bit")
local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")
local script = require("engine.pops.script")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)

local pops = {
    stats = {
        months = 0, colonies = 0, growth_events = 0, grown = 0, expected = 0,
        colonized = 0, colonization_done = 0, assembled = 0, declined = 0,
        groups_created = 0, groups_removed = 0, no_target = 0, rule_errors = 0,
        skipped = {},
    },
    last = {},      -- colony id -> the last month's demography (pops.demography's result)
}

-- ---------------------------------------------------------------------------------------------
-- fixed point (CFixedPoint): int64, 1.0 = 100000; * and / truncate toward zero as the game's do

local I64 = ffi.typeof("int64_t")
local ONE = 100000
local ZERO = I64(0)
local BIG = I64(4294967295)   -- what the game's division by zero gives (0xFFFFFFFF)

local function fx(v)          -- a number as the game holds it (the capture's values are fixed / 1e5)
    if v == nil then return ZERO end
    return I64(math.floor(v * ONE + 0.5))
end
local function ifx(n)         -- an integer as fixed
    return I64(n) * ONE
end
local function fmul(a, b)
    return I64(a) * b / ONE
end
local function fdiv(a, b)
    if b == 0 then return BIG end
    return I64(a) * ONE / b
end
local function trunc(a)       -- the integer part of a fixed value, as a Lua number
    return tonumber(I64(a) / ONE)
end
local function num(a)
    return tonumber(a) / ONE
end
pops.fixed = { fx = fx, fmul = fmul, fdiv = fdiv, trunc = trunc, num = num, ONE = ONE }

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
local function define(group, key)
    local g = defs.get("common/defines", group)
    return g and defs.field(g.block, key)
end
local function defines()
    if D == nil then
        local function f(group, key, default) return fixed_text(define(group, key) or default) end
        local function i(group, key, default) return tonumber(define(group, key)) or default end
        D = {
            BASE_POP_GROWTH = f("NPop", "BASE_POP_GROWTH", "1"),
            LOGISTIC_R = f("NPop", "LOGISTIC_POP_GROWTH_R", "0.0025"),
            LOGISTIC_FLOOR = f("NPop", "LOGISTIC_POP_GROWTH_FLOOR", "0.1"),
            LOGISTIC_MIN_POPS = i("NPop", "LOGISTIC_POP_GROWTH_MIN_POPS", 10),
            LOGISTIC_LOWER_THRESHOLD = f("NPop", "LOGISTIC_POP_GROWTH_LOWER_THRESHOLD", "0"),
            MAX_CARRYING_CAPACITY = i("NPop", "MAX_CARRYING_CAPACITY", 50000),
            OVERCROWDING_NO_GROWTH = f("NPop", "OVERCROWDING_NO_GROWTH_THRESHOLD", "1.15"),
            OVERCROWDING_ABS_NO_GROWTH = i("NPop", "OVERCROWDING_ABSOLUTE_THRESHOLD_FOR_NO_GROWTH", 5),
            OVERCROWDING_DECLINE = f("NPop", "OVERCROWDING_DECLINE_THRESHOLD", "1.25"),
            OVERCROWDING_NO_ASSEMBLY = f("NPop", "OVERCROWDING_NO_ASSEMBLY_THRESHOLD", "1.15"),
            OVERCROWDING_MACHINE_DECLINE = f("NPop", "OVERCROWDING_MACHINE_DECLINE_THRESHOLD", "1.25"),
            OVERCROWDING_MACHINE_ABS = i("NPop", "OVERCROWDING_MACHINE_ABSOLUTE_THRESHOLD_FOR_NO_GROWTH", 5),
            MACHINE_ASSEMBLY_WHEN_OVERCROWDED = f("NPop", "MACHINE_ASSEMBLY_WHEN_OVERCROWDED", "0"),
            BASE_POP_DECLINE = f("NPop", "BASE_POP_DECLINE", "5"),
            BASE_POP_ASSEMBLY = f("NPop", "BASE_POP_ASSEMBLY", "0"),
            NEWLY_ASSEMBLED_POP_TARGET_RANK = i("NPop", "NEWLY_ASSEMBLED_POP_TARGET_RANK", 1),
            COLONY_POPS_REQUIRED = i("NPop", "COLONY_POPS_REQUIRED", 100),
            COLONY_MONTHLY_GROWTH = f("NEconomy", "COLONY_MONTHLY_GROWTH", "3"),
            GROWTH_SCALE_MAGNITUDE_OFFSET = f("NGameplay", "GROWTH_SCALE_MAGNITUDE_OFFSET", "10000"),
            NUM_DISTRICTS_BASE = i("NGameplay", "NUM_DISTRICTS_BASE", 0),
            NUM_DISTRICTS_FROM_PLANET_SIZE = f("NGameplay", "NUM_DISTRICTS_FROM_PLANET_SIZE", "1"),
        }
        -- the galaxy's settings (CGalaxyConfiguration: logistic_ceiling_v2 _vLogisticCeiling +0xf0,
        -- growth_scale _vGrowthScale +0xf8)
        local galaxy = world.meta.galaxy
        D.LOGISTIC_CEILING = fixed_text(type(galaxy) == "table" and world.field(galaxy, "logistic_ceiling_v2") or nil, 5 * ONE)
        D.GROWTH_SCALE = fixed_text(type(galaxy) == "table" and world.field(galaxy, "growth_scale") or nil, 25000)
    end
    return D
end
pops.defines = defines

-- ---------------------------------------------------------------------------------------------
-- the noise generator (CNoiseRandom: Squirrel3 with a fourth round; docs/simulation.md section 3)

local TWO32 = 4294967296
local function mul32(a, b)
    local alo, ahi = a % 65536, (a - a % 65536) / 65536
    local blo, bhi = b % 65536, (b - b % 65536) / 65536
    local mid = (alo * bhi + ahi * blo) % 65536
    return (mid * 65536 + alo * blo) % TWO32
end
local function u32(x) return x % TWO32 end
local function noise32(position, seed)
    local x = u32(seed + mul32(u32(position), 0xB5297A4D))
    x = u32(bit.bxor(x, bit.rshift(x, 8)))
    x = u32(x + 0x68E31DA4)
    x = u32(bit.bxor(x, bit.lshift(x, 8)))
    x = mul32(x, 0x1B56C4E9)
    x = u32(bit.bxor(x, bit.rshift(x, 8)))
    x = mul32(x, 0x92D68CA2)
    x = u32(bit.bxor(x, bit.rshift(x, 8)))
    return x
end
pops.noise32 = noise32

-- the local stream the game makes from one random value v: { position = noise32(v, 0x5EA6BA9F),
-- seed = 0 } (MonthlyUpdateSafePrivate 0xe51790, GrowColonists 0xdc1410)
local function stream(v)
    return { position = noise32(u32(v), 1587985055), seed = 0 }
end
-- CNoiseRandom::GetInt64 (0x1b50900) mod 100000: ((a & 0x7FFFFFFF) << 32) + b, a and b the noise of
-- two positions; the position advances by 2
local function int64_mod_one(s)
    local a = noise32(s.position, s.seed) % 2147483648
    local b = noise32(u32(s.position + 1), s.seed)
    s.position = u32(s.position + 2)
    return ((a % ONE) * (TWO32 % ONE) + b) % ONE
end
-- the game's rounding of a fixed amount: the integer part, plus one when the draw's remainder is
-- not above the fraction
local function round_random(amount, s)
    local n = trunc(amount)
    local frac = tonumber(I64(amount) - ifx(n))
    if int64_mod_one(s) <= frac then
        n = n + 1
    end
    return n
end
pops.stream, pops.round_random = stream, round_random

-- the month's pool of 1,000 random values (CGameState::MonthlyUpdate 0x26169a,
-- CRandom::GetIntegersForMacro(1000))
local function monthly_pool()
    if RUST.monthly_pool then
        return RUST.monthly_pool()
    end
    local pool = {}
    for i = 1, 1000 do
        pool[i] = RUST.rand()
    end
    return pool
end

-- ---------------------------------------------------------------------------------------------
-- the world

local NONE = 4294967295

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers(kind, id) or {}
end
local function mod(M, name)
    return fx(M[name])
end

local function int(v)
    return tonumber(v) or 0
end

local function colony_groups(c)
    local out = {}
    for _, t in ipairs(world.list(world.field(c, "pop_groups"))) do
        local id = tonumber(t)
        slice.tick("pops groups")
        local g = id and world.object("pop_groups", id)
        if g and world.field(g, "killed") ~= "yes" then
            out[#out + 1] = id
        end
    end
    return out
end

local function group_key(g)
    local key = world.field(g, "key")
    if type(key) ~= "table" then
        return nil, nil
    end
    return tonumber(world.field(key, "species")), world.field(key, "category")
end

local function flag(g, name)
    return world.field(g, name) == "yes"
end

local function species_obj(sid)
    return sid and world.object("species_db", sid)
end

-- CSpecies::GetBaseSpecies: base_ref, followed
local function base_species(sid)
    local seen = 0
    while sid and seen < 8 do
        local s = species_obj(sid)
        local b = s and tonumber(world.field(s, "base_ref"))
        if not b or b == NONE or b == sid then
            break
        end
        sid, seen = b, seen + 1
    end
    return sid
end

local function is_sapient(sid)
    local s = species_obj(sid)
    return not (s and world.field(s, "sapient") == "no")
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
-- CSpeciesArchetype::GrowthUsesModifiers: `uses_modifiers` (default yes) and not robotic (the
-- archetype's own growth modifiers <ARCHETYPE>_logistic_growth_mult, _bonus_pop_growth(_mult))
local function archetype_growth_mods(name)
    if not name then return false end
    local d = defs.get("common/species_archetypes", name)
    if not d then return false end
    return defs.field(d.block, "uses_modifiers") ~= "no" and defs.field(d.block, "robotic") ~= "yes"
end

-- a scripted rule of common/game_rules in a context: whether it holds; `default` when there is no
-- such rule or the script layer cannot evaluate it (counted)
pops.rule_errors = {}
local function rule(name, ctx, default)
    local d = defs.get("common/game_rules", name)
    if not d then
        return default
    end
    local ok, holds = pcall(eval.trigger, d.block, ctx)
    if not ok then
        pops.stats.rule_errors = pops.stats.rule_errors + 1
        pops.rule_errors[name] = tostring(holds)
        return default
    end
    return holds and true or false
end

local function planet_ctx(pid, from, fromfrom)
    local ctx = eval.new_ctx(eval.S("planet", pid), from)
    if fromfrom then ctx.fromfrom = fromfrom end
    return ctx
end

-- the colony's owner (its planet's owner) and the owner's country type
local function owner_of(cid)
    local pid = world.colony_planet[cid]
    local p = pid and world.object("planet", pid)
    local o = p and tonumber(world.field(p, "owner"))
    if o == NONE then o = nil end
    return o, pid, p
end

-- the country type's pop_growth (CCountryType flag HasPopGrowth, bit 38)
local function has_pop_growth(country)
    local c = country and world.object("country", country)
    if not c then return false end
    local t = world.field(c, "type") or "default"
    local d = defs.get("common/country_types", t)
    return d ~= nil and defs.field(d.block, "pop_growth") == "yes"
end

-- CGameRules::EvaluateIsFounderSpeciesUsing(rule): root = the country, from = its founder species
local founder_cache = {}
local function founder_uses(rule_name, country)
    local k = rule_name .. "/" .. tostring(country)
    local v = founder_cache[k]
    if v == nil then
        local c = country and world.object("country", country)
        local fs = c and tonumber(world.field(c, "founder_species_ref"))
        if not c then
            v = false
        else
            local ctx = eval.new_ctx(eval.S("country", country), fs and eval.S("species", fs) or nil)
            v = rule(rule_name, ctx, false)
        end
        founder_cache[k] = v
    end
    return v
end

-- the country's employable pops (CCountry::DailyUpdateSelfDontReadOthers: the sum of its colonies')
local function country_employable(country)
    local c = world.object("country", country)
    local n = 0
    for _, t in ipairs(world.list(c and world.field(c, "owned_planets"))) do
        local col = world.object("colony", tonumber(t))
        n = n + int(col and world.field(col, "employable_pops"))
    end
    return n
end

-- CCountry::GetGrowthScale (0x73b9f0): 1 + growth_scale * employable / max(1, MAGNITUDE_OFFSET),
-- in the 48.15 fixed point (fpml), back to CFixedPoint rounded
local function to_q15(f)
    f = I64(f)
    local ip = f / ONE
    local fr = f - ip * ONE
    return ip * 32768 + fr * 32768 / ONE
end
local scale_cache = {}
local function growth_scale(country)
    local s = scale_cache[country]
    if s then return s end
    local d = defines()
    local gs, off = to_q15(d.GROWTH_SCALE), to_q15(d.GROWTH_SCALE_MAGNITUDE_OFFSET)
    if off < 32768 then off = I64(32768) end
    local q = gs * (I64(country_employable(country)) * 32768) / off + 32768
    local ip = q / 32768
    local fr = q - ip * 32768
    local x = fr * ONE
    if x <= 0 then x = x - 1 end
    s = ip * ONE + (x + 16384) / 32768
    scale_cache[country] = s
    return s
end
pops.growth_scale = growth_scale

-- ---------------------------------------------------------------------------------------------
-- carrying capacity

local function planet_class(p)
    local c = p and world.field(p, "planet_class")
    return c and defs.get("common/planet_classes", c), c
end

-- a number of a definition, `@variables` resolved (the file's own, then common/scripted_variables)
local function def_number(def, key)
    local v = def and defs.field(def.block, key)
    if type(v) ~= "string" then return nil end
    local seen = 0
    while v and v:sub(1, 1) == "@" and seen < 8 do
        local db = require("simscript.db")
        local name = v:sub(2)
        local fv = def.file and db.filevars(def.file)
        v = (fv and fv[name]) or db.globalvars[name]
        seen = seen + 1
    end
    return tonumber(v)
end

-- CColony::CalcNumDistricts(colony, true): the levels of its districts, and the district items of its
-- planet's build queue
local function num_districts(c, p, cid)
    local n = 0
    for _, t in ipairs(world.list(world.field(c, "districts"))) do
        local d = world.object("districts", tonumber(t))
        n = n + int(d and world.field(d, "level"))
    end
    local q = p and world.object("construction.queue_mgr.queues", tonumber(world.field(p, "build_queue")))
    for _, t in ipairs(world.list(q and world.field(q, "items"))) do
        local item = world.object("construction.item_mgr.items", tonumber(t))
        local b = item and world.field(item, "buildable_district")
        if type(b) == "table" and tonumber(world.field(b, "planet")) == cid then
            n = n + 1
        end
    end
    return n
end

-- CColonyCarrier::CalcMaxDistricts(false) (0xccc980)
local function max_districts(p, M)
    local d = defines()
    local cd, cname = planet_class(p)
    local block = cd and cd.block
    local size = int(world.field(p, "planet_size"))
    local total = d.NUM_DISTRICTS_BASE + trunc(fmul(ifx(size), d.NUM_DISTRICTS_FROM_PLANET_SIZE))
        + trunc(mod(M, tostring(cname) .. "_max_districts_add"))
    local inherit = not block or defs.field(block, "inherit_country_district_modifiers") ~= "no"
    if inherit then
        total = total + trunc(mod(M, "planet_max_districts_add"))
        local artificial = block and defs.field(block, "is_artificial_planet") == "yes"
        total = total + trunc(mod(M, artificial and "planet_artificial_max_districts_add" or "planet_non_artificial_max_districts_add"))
        local mult = mod(M, "planet_max_districts_mult") + ONE
        if mult < 0 then mult = ZERO end
        total = trunc(fmul(ifx(total), mult))
    end
    return math.max(1, total)
end

-- CColonyDemographyCalculator::CalcCarryingCapacityFromDistricts (0xe550e0): the free districts times
-- the planet class's carry_cap_per_free_district, and planet_carry_cap_add
local function capacity_from_districts(cid, c, p, M)
    local cd = planet_class(p)
    local per = def_number(cd, "carry_cap_per_free_district") or 0
    local maxd, numd = max_districts(p, M), num_districts(c, p, cid)
    local add = mod(M, "planet_carry_cap_add")
    if add < 0 then add = ZERO end
    return ifx((maxd - numd) * per) + add, maxd, numd
end

-- CColonyDemographyCalculator::CalcLogisticGrowthModifier (0xe525b0)
local function logistic_growth(size, from_districts, free_housing)
    local d = defines()
    local n = math.max(size, d.LOGISTIC_MIN_POPS)
    local K = from_districts + ifx(size) + free_housing
    local cap = ifx(d.MAX_CARRYING_CAPACITY)
    if K > cap then K = cap end
    if K < ONE then K = I64(ONE) end
    local ratio = fdiv(ifx(n * n), K)
    local lg = fmul(d.LOGISTIC_R, ifx(n) - ratio - ONE)
    local filled = fdiv(ifx(n), K)
    if filled < d.LOGISTIC_LOWER_THRESHOLD and lg < ONE then
        return I64(ONE)
    end
    return lg
end
pops.logistic_growth = logistic_growth

-- CColony::IsOvercrowdingHaltingGrowthGeneric (0xdb5bf0)
local function overcrowded(c, threshold, absolute)
    local free = fx(tonumber(world.field(c, "free_housing")))
    if free >= 0 then return false end
    local housing = fx(tonumber(world.field(c, "total_housing")))
    local usage = fx(tonumber(world.field(c, "housing_usage")))
    if usage - housing < ifx(absolute) then return false end
    if housing == 0 then return BIG >= threshold end
    return fdiv(usage, housing) >= threshold
end

-- ---------------------------------------------------------------------------------------------
-- growth: CColonyDemographyCalculator

-- the size of a pop group as the demography sees it (opts.size_of: a probe's override)
local function size_of(gid, g, opts)
    if opts and opts.size_of then
        return opts.size_of(gid, g)
    end
    return int(world.field(g, "size"))
end

-- the triggered_planet_growth_habitability_modifier blocks of the species' traits, in the planet's
-- scope (CTraitSet::ApplyTriggeredColonyModifiers: this = planet, from = species, fromfrom = country)
local function trait_growth_mods(sid, pid, country)
    local out = {}
    local s = species_obj(sid)
    local traits = s and world.field(s, "traits")
    if type(traits) ~= "table" then return out end
    for _, t in ipairs(world.fields(traits, "trait")) do
        local d = defs.get("common/traits", t)
        if d then
            for _, e in ipairs(d.block) do
                if e.op and e.key.text == "triggered_planet_growth_habitability_modifier" and e.value.text == nil then
                    local ctx = planet_ctx(pid, eval.S("species", sid), country and eval.S("country", country) or nil)
                    local potential = defs.field(e.value, "potential")
                    local ok, holds = true, true
                    if type(potential) == "table" then
                        ok, holds = pcall(eval.trigger, potential, ctx)
                    end
                    if ok and holds then
                        local m = I64(ONE)
                        local mv = defs.field(e.value, "mult")
                        if mv then
                            local okv, v = pcall(eval.value, { text = mv }, ctx)
                            m = fx(okv and tonumber(v) or 1)
                        end
                        for _, x in ipairs(e.value) do
                            if x.op and x.value.text and x.key.text ~= "mult" then
                                local v = tonumber(x.value.text)
                                if v then
                                    out[x.key.text] = (out[x.key.text] or ZERO) + fmul(fx(v), m)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

-- CPopGroup::CalcMonthlyGrowthMultiplier (0x6808c0): max(0, 1 + logistic_growth_mult (+ the
-- founder's founder_species_growth_mult) (+ <ARCHETYPE>_logistic_growth_mult) + the traits' triggered
-- colony modifiers of the same)
local function growth_multiplier(gid, sid, pid, country, ctx_cache)
    local M = modifiers("pop_group", gid)
    local sum = mod(M, "logistic_growth_mult")
    local founder = founder_uses("founder_species_uses_logistic_growth_mult", country)
    if founder then
        sum = sum + mod(M, "founder_species_growth_mult")
    end
    local arch = archetype(sid)
    if archetype_growth_mods(arch) then
        sum = sum + mod(M, arch .. "_logistic_growth_mult")
    end
    local key = tostring(sid) .. "/" .. tostring(pid)
    local T = ctx_cache[key]
    if T == nil then
        T = trait_growth_mods(sid, pid, country)
        ctx_cache[key] = T
    end
    sum = sum + (T.logistic_growth_mult or ZERO)
    if archetype_growth_mods(arch) then
        sum = sum + (T[arch .. "_logistic_growth_mult"] or ZERO)
    end
    if founder then
        sum = sum + (T.founder_species_growth_mult or ZERO)
    end
    local m = sum + ONE
    if m < 0 then m = ZERO end
    return m
end

-- CPopGroup::CalcMonthlyBonusGrowth (0x680df0): (bonus_pop_growth (+ archetype's)) * (1 +
-- bonus_pop_growth_mult (+ archetype's) (+ founder_species_growth_mult when the founder uses the bonus
-- growth mult)), when the rule species_uses_bonus_growth holds
local function bonus_growth(gid, sid, pid, country)
    local M = modifiers("pop_group", gid)
    local arch = archetype(sid)
    local uses = archetype_growth_mods(arch)
    local add = mod(M, "bonus_pop_growth")
    if uses then add = add + mod(M, arch .. "_bonus_pop_growth") end
    if add == 0 then
        return ZERO
    end
    local ctx = eval.new_ctx(eval.S("species", sid), nil)
    ctx.root = eval.S("planet", pid)
    if not rule("species_uses_bonus_growth", ctx, true) then
        return ZERO
    end
    local mult = mod(M, "bonus_pop_growth_mult") + ONE
    if uses then mult = mult + mod(M, arch .. "_bonus_pop_growth_mult") end
    if founder_uses("founder_species_uses_bonus_growth_mult", country) then
        mult = mult + mod(M, "founder_species_growth_mult")
    end
    return fmul(add, mult)
end

-- CColonyDemographyCalculator::CalcBaseSpeciesGrowthData (0xe51fd0): the procreating pop groups'
-- sizes by base species (all crossbreeding ones together under -1 when the colony crossbreeds),
-- each's logistic growth, rescaled so that their sum is within [LOGISTIC_POP_GROWTH_FLOOR, the
-- galaxy's logistic_ceiling_v2]
local function base_species_growth(cid, c, p, pid, groups, M, opts)
    local d = defines()
    local data, order = {}, {}
    if not rule("can_pops_grow_on_colony", planet_ctx(pid), true) then
        return data, order, "rule"
    end
    if overcrowded(c, d.OVERCROWDING_NO_GROWTH, d.OVERCROWDING_ABS_NO_GROWTH) then
        return data, order, "overcrowded"
    end
    local crossbreed = rule("can_crossbreed_species_on_colony", planet_ctx(pid), false)
    for _, gid in ipairs(groups) do
        local g = world.object("pop_groups", gid)
        if flag(g, "can_procreate") then
            local sid = group_key(g)
            local k = (crossbreed and flag(g, "can_crossbreed")) and -1 or base_species(sid)
            local e = data[k]
            if not e then
                e = { size = 0, lg = ZERO }
                data[k] = e
                order[#order + 1] = k
            end
            e.size = e.size + size_of(gid, g, opts)
        end
    end
    local districts, maxd, numd = capacity_from_districts(cid, c, p, M)
    data.max_districts, data.num_districts = maxd, numd
    local free_housing = fx(tonumber(world.field(c, "free_housing")))
    local total = ZERO
    for _, k in ipairs(order) do
        local e = data[k]
        e.lg = logistic_growth(e.size, districts, free_housing)
        total = total + e.lg
    end
    if total > 0 then
        local target
        if d.LOGISTIC_FLOOR > total then
            target = d.LOGISTIC_FLOOR
        elseif total > d.LOGISTIC_CEILING then
            target = d.LOGISTIC_CEILING
        end
        if target then
            local scale = fdiv(target, total)
            for _, k in ipairs(order) do
                data[k].lg = fmul(data[k].lg, scale)
            end
        end
    end
    return data, order, nil, districts
end

-- CColonyDemographyCalculator::CalcGrowthForPopGroup (0xe528b0)
local function growth_for_group(gid, g, base, pid, country, opts, cache)
    local d = defines()
    local sid = group_key(g)
    local k = (flag(g, "can_procreate") and flag(g, "can_crossbreed") and base[-1]) and -1 or base_species(sid)
    local e = base[k]
    local G = ZERO
    if e and e.size > 0 and flag(g, "can_procreate") then
        G = fmul(d.BASE_POP_GROWTH, e.lg)
        if G ~= 0 then
            G = fmul(G, growth_multiplier(gid, sid, pid, country, cache))
            G = fmul(G, fdiv(ifx(size_of(gid, g, opts)), ifx(e.size)))
        end
    end
    G = G + bonus_growth(gid, sid, pid, country)
    if not (opts and opts.no_scale) then
        G = fdiv(G, growth_scale(country))
    end
    return G
end

-- ---------------------------------------------------------------------------------------------
-- assembly and decline

-- the species' own modifier (CSpecies +472): its traits' `modifier` blocks
local species_mod_cache = {}
local function species_modifier(sid)
    local m = species_mod_cache[sid]
    if m then return m end
    m = {}
    local s = species_obj(sid)
    local traits = s and world.field(s, "traits")
    for _, t in ipairs(type(traits) == "table" and world.fields(traits, "trait") or {}) do
        local d = defs.get("common/traits", t)
        local b = d and defs.field(d.block, "modifier")
        if type(b) == "table" then
            for _, x in ipairs(b) do
                local v = x.op and x.value.text and tonumber(x.value.text)
                if v then m[x.key.text] = (m[x.key.text] or ZERO) + fx(v) end
            end
        end
    end
    species_mod_cache[sid] = m
    return m
end

-- CModifier::CalcModifierMult: max(min, 1 + v), or max(min, 1 - v) for a reduction (the
-- definition's minimum is not in the files: 0 here)
local function mult_of(v, reduction)
    local m = reduction and (I64(ONE) - (v or ZERO)) or (I64(ONE) + (v or ZERO))
    if m < 0 then m = ZERO end
    return m
end

-- CColonyDemographyCalculator::CalcMonthlyPopAssemblyAmount (0xe54190)
local function assembly_amount(c, pid, sid, country, M)
    local d = defines()
    if overcrowded(c, d.OVERCROWDING_NO_ASSEMBLY, d.OVERCROWDING_MACHINE_ABS) then
        return d.MACHINE_ASSEMBLY_WHEN_OVERCROWDED
    end
    local A = d.BASE_POP_ASSEMBLY + mod(M, "planet_pop_assembly_add")
    local founder = founder_uses("founder_species_uses_assembly", country)
    if sid then
        local SM = species_modifier(sid)
        local T = trait_growth_mods(sid, pid, country)
        A = fmul(A, mult_of(SM.planet_pop_assembly_mult))
        A = fmul(A, mult_of(T.planet_pop_assembly_mult))
        if founder then
            A = fmul(A, mult_of(SM.founder_species_growth_mult))
            A = fmul(A, mult_of(T.founder_species_growth_mult))
        end
        A = fmul(A, mult_of(T.planet_pop_assembly_reduction, true))
    end
    A = fmul(A, mult_of(mod(M, "planet_pop_assembly_mult")))
    A = fmul(A, mult_of(mod(M, "planet_pop_assembly_reduction"), true))
    if founder then
        A = fmul(A, mult_of(mod(M, "founder_species_growth_mult")))
    end
    return fdiv(A, growth_scale(country))
end

-- CColonyDemographyCalculator::CalcBestSpeciesToAssemble (0xe53740): the owner's built species,
-- its founder species, then its other species, those the rule can_species_be_assembled allows
-- (This = species, Root = colony); the best by CCountry::CalcAssemblyScoreForSpecies (not modelled:
-- the first allowed one here), ties to the one with more pops on the colony
local function best_species_to_assemble(c, pid, country)
    local cobj = world.object("country", country)
    local list, seen = {}, {}
    local function add(sid)
        if sid and sid ~= NONE and not seen[sid] and species_obj(sid) then
            seen[sid] = true
            list[#list + 1] = sid
        end
    end
    add(tonumber(world.field(cobj, "built_species_ref")))
    add(tonumber(world.field(cobj, "founder_species_ref")))
    for _, gid in ipairs(colony_groups(c)) do
        add((group_key(world.object("pop_groups", gid))))
    end
    for _, sid in ipairs(list) do
        local ctx = eval.new_ctx(eval.S("species", sid), nil)
        ctx.root = eval.S("planet", pid)
        if rule("can_species_be_assembled", ctx, false) then
            return sid
        end
    end
    return nil
end

-- CColonyDemographyCalculator::ShouldDecline (0xe53f30): a species that cannot live on the planet
-- (species_can_live_on_planet) or is forced to (should_force_decline_species), or an overcrowded
-- colony (housing usage / housing at OVERCROWDING_(MACHINE_)DECLINE_THRESHOLD); purged pops
-- (unless in ground combat): not modelled
local function should_decline(c, cid, pid, sid)
    local d = defines()
    local ctx = eval.new_ctx(eval.S("species", sid), nil)
    ctx.root = eval.S("planet", pid)
    if rule("species_can_live_on_planet", ctx, true) == false then
        return true
    end
    local fctx = eval.new_ctx(eval.S("species", sid), eval.S("planet", pid))
    if rule("should_force_decline_species", fctx, false) then
        return true
    end
    local arch = archetype(sid)
    local ad = arch and defs.get("common/species_archetypes", arch)
    local robotic = ad ~= nil and defs.field(ad.block, "robotic") == "yes"
    local threshold = robotic and d.OVERCROWDING_NO_ASSEMBLY or d.OVERCROWDING_NO_GROWTH
    local absolute = robotic and d.OVERCROWDING_MACHINE_ABS or d.OVERCROWDING_ABS_NO_GROWTH
    if not overcrowded(c, threshold, absolute) then
        return false
    end
    local housing = fx(tonumber(world.field(c, "total_housing")))
    local usage = fx(tonumber(world.field(c, "housing_usage")))
    local ratio = housing == 0 and BIG or fdiv(usage, housing)
    return ratio >= (robotic and d.OVERCROWDING_MACHINE_DECLINE or d.OVERCROWDING_DECLINE)
end

-- CColonyDemographyCalculator::CalcMonthlyDeclineAmount (0xe53970): BASE_POP_DECLINE (a purge's
-- own rate when purged: not modelled) * max(0, 1 + pop_decline_speed)
local function decline_amount(gid)
    local M = modifiers("pop_group", gid)
    return fmul(defines().BASE_POP_DECLINE, mult_of(mod(M, "pop_decline_speed")))
end

-- pops.demography(colony id, random value[, opts]) -> the month's demography of a colony
-- (CColonyDemographyCalculator::MonthlyUpdateSafePrivate, 0xe514a0): { groups = { { id, growth,
-- decline } } in the colony's order, species = { { species, growth (fixed, then rounded), expected,
-- decline, group } }, assembly = { species, amount } }, or one with `skipped`
local function demography(cid, rv, opts)
    local c = world.object("colony", cid)
    local out = { groups = {}, species = {}, skipped = nil }
    if not c then
        out.skipped = "no colony"
        return out
    end
    local country, pid, p = owner_of(cid)
    local groups = colony_groups(c)
    for i, gid in ipairs(groups) do
        out.groups[i] = { id = gid, growth = ZERO, decline = ZERO }
    end
    local colonizing = tonumber(world.field(c, "colonizing_species"))
    if colonizing and colonizing ~= NONE then
        out.skipped = "colonizing"
    elseif not country or not world.object("country", country) then
        out.skipped = "no owner"
    elseif not has_pop_growth(country) then
        out.skipped = "country type without pop_growth"
    end
    local M = modifiers("colony", cid)
    local can_decline = rule("can_pops_decline_on_colony", planet_ctx(pid), true)
    if not out.skipped then
        local base, _, why, districts = base_species_growth(cid, c, p, pid, groups, M, opts)
        out.why, out.districts, out.base = why, districts, base
        local cache = {}
        for i, gid in ipairs(groups) do
            local g = world.object("pop_groups", gid)
            local G = growth_for_group(gid, g, base, pid, country, opts, cache)
            out.groups[i].raw = G
            if G > 0 then
                out.groups[i].growth = G
            end
        end
        -- assembly: the integer part, and one more when the colony's stream's first draw is not
        -- above the fraction (a stream of its own, from the same position as the growth's)
        if rule("can_pops_assemble_on_colony", planet_ctx(pid), true) then
            local sid = best_species_to_assemble(c, pid, country)
            if sid then
                local A = assembly_amount(c, pid, sid, country, M)
                if A > 0 then
                    local n = round_random(A, stream(rv or 0))
                    if n > 0 then
                        out.assembly = { species = sid, amount = n, expected = A }
                    end
                end
            end
        end
    end
    -- decline: the integer part (no random part), per pop group
    out.can_decline = can_decline
    if can_decline then
        for i, gid in ipairs(groups) do
            local g = world.object("pop_groups", gid)
            local sid = group_key(g)
            if sid and should_decline(c, cid, pid, sid) then
                local n = trunc(decline_amount(gid))
                if n > 0 then
                    out.groups[i].decline = ifx(n)
                end
            end
        end
    end
    -- the species' scores: summed in the order of the colony's pop groups, the group to grow the
    -- largest group of the species with a score (MonthlyUpdateSafePrivate 0xe51946)
    local by, largest = {}, {}
    for _, gs in ipairs(out.groups) do
        if gs.growth ~= 0 or gs.decline ~= 0 then
            local g = world.object("pop_groups", gs.id)
            local sid = group_key(g)
            local s = by[sid]
            local size = size_of(gs.id, g, opts)
            if not s then
                s = { species = sid, growth = ZERO, decline = ZERO, group = gs.id }
                by[sid] = s
                out.species[#out.species + 1] = s
                largest[sid] = size
            elseif size > largest[sid] then
                s.group, largest[sid] = gs.id, size
            end
            s.growth = s.growth + gs.growth
            s.decline = s.decline + gs.decline
        end
    end
    -- the growth rounded with the colony's stream (0xe51adc)
    local s = stream(rv or 0)
    for _, sp in ipairs(out.species) do
        sp.expected = sp.growth
        sp.amount = round_random(sp.growth, s)
    end
    return out
end
function pops.demography(cid, rv, opts)
    return script.with(demography, cid, rv, opts)
end

-- ---------------------------------------------------------------------------------------------
-- changing the world: sizes, growth details, ethics

local function set_int(g, key, n)
    world.set(g, key, n)
end

-- a `key = { key="X" value=n ... }` details block as an ordered map
local function read_details(block)
    local map, order = {}, {}
    if type(block) ~= "table" then return map, order end
    local k
    for _, e in ipairs(block) do
        if e.op and e.key.text == "key" then
            k = e.value.text
        elseif e.op and e.key.text == "value" and k then
            if map[k] == nil then order[#order + 1] = k end
            map[k] = (map[k] or 0) + int(e.value.text)
        end
    end
    return map, order
end

local function details_block(map)
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys)   -- NPopUtil::WriteGrowthDetails sorts by key
    local b = {}
    for _, k in ipairs(keys) do
        world.append(b, "key", k, true)
        world.append(b, "value", map[k])
    end
    return b
end

-- the entry of `key` in obj (the statement) and its position (engine.world.entry: by the key index
-- with the world in the store)
local function entry(obj, key)
    return world.entry(obj, key)
end

-- obj's `key = value`: replaced in place, or inserted after the first of `after` that is there (at
-- the end when none is); value nil removes it
local function replace_field(obj, key, value, after)
    local e, i = entry(obj, key)
    if e then
        world.remove_entry(obj, e)
        if value ~= nil then
            world.insert(obj, i, key, value)
        end
        return
    end
    if value == nil then
        return
    end
    local pos = #obj + 1
    for _, a in ipairs(after or {}) do
        local _, j = entry(obj, a)
        if j then
            pos = j + 1
            break
        end
    end
    world.insert(obj, pos, key, value)
end

-- obj's `key = { details }` (the game writes the block only when it has entries)
local function write_details(obj, key, map, after)
    replace_field(obj, key, next(map) ~= nil and details_block(map) or nil, after)
end

-- the pop group's current month's details (CPopGroup::_CurrentMonthGrowthDetails)
local current_details = {}   -- gid -> map (written back at UpdateCachedGrowth)
local colony_details = {}    -- colony id -> map (SMonthlyGrowthData::_GrowthDetails of the current month)

local function group_details(gid)
    local m = current_details[gid]
    if not m then
        local g = world.object("pop_groups", gid)
        m = read_details(world.field(g, "current_month_growth_details"))
        current_details[gid] = m
    end
    return m
end
local function colony_detail_map(cid)
    local m = colony_details[cid]
    if not m then
        local c = world.object("colony", cid)
        local cur = world.field(c, "current_month_growth_data")
        m = read_details(type(cur) == "table" and world.field(cur, "current_month_growth_details") or nil)
        colony_details[cid] = m
    end
    return m
end

-- CPopGroup::AddGrowthDetail / CColony::AddGrowthDetail (MIGRATION split into IMMIGRATION and
-- EMIGRATION by sign)
local function add_detail(gid, cid, key, n, to_colony)
    local m = group_details(gid)
    m[key] = (m[key] or 0) + n
    if to_colony and cid then
        local ck = key
        if key == "GROWTH_CAT_MIGRATION" then
            ck = n < 0 and "GROWTH_CAT_EMIGRATION" or "GROWTH_CAT_IMMIGRATION"
            n = math.abs(n)
        end
        local cm = colony_detail_map(cid)
        cm[ck] = (cm[ck] or 0) + n
    end
end

-- CBasePopGroupStat<CEthic>::Resize (0x45d390): the ethics' pops scaled to the group's size, the
-- remainder one by one to the largest fractions (ties: the larger count, then the first), sorted by
-- count, empty ones dropped
local function resize_ethos(g, size)
    local ethos = world.field(g, "ethos")
    if type(ethos) ~= "table" then return end
    local ethics = world.field(ethos, "ethics")
    local popsb = world.field(ethos, "pops")
    if type(ethics) ~= "table" or type(popsb) ~= "table" then return end
    local names, counts = world.list(ethics), {}
    for i, t in ipairs(world.list(popsb)) do counts[i] = int(t) end
    local total = 0
    for _, n in ipairs(counts) do total = total + n end
    if total == 0 or total == size or #names ~= #counts then return end
    local rem, given = {}, 0
    for i, n in ipairs(counts) do
        local share = fdiv(ifx(n), ifx(total))
        local x = I64(size) * share
        local p = tonumber(x / ONE)
        counts[i] = p
        rem[i] = x - I64(p) * ONE
        given = given + p
    end
    local left = size - given
    while left > 0 do
        local best
        for i = 1, #counts do
            if rem[i] >= 0 and (best == nil or rem[i] > rem[best] or (rem[i] == rem[best] and counts[i] > counts[best])) then
                best = i
            end
        end
        if not best then break end
        counts[best] = counts[best] + 1
        rem[best] = I64(-ONE)
        left = left - 1
    end
    local idx = {}
    for i = 1, #counts do idx[i] = i end
    table.sort(idx, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b
    end)
    local nb, cb = {}, {}
    for _, i in ipairs(idx) do
        if counts[i] > 0 then
            nb[#nb + 1] = { text = names[i], quoted = true }
            cb[#cb + 1] = { text = tostring(counts[i]) }
        end
    end
    replace_field(ethos, "ethics", nb)
    replace_field(ethos, "pops", cb)
end

-- the colonies whose caches change this month
local touched = {}

-- CPopGroup::AddSize (0x67d720): the size, the colony's caches, the ethics, the detail
local function add_size(gid, cid, n, detail)
    local g = world.object("pop_groups", gid)
    local size = int(world.field(g, "size"))
    if n < 0 and n < -size then n = -size end
    if n == 0 then return 0 end
    size = size + n
    set_int(g, "size", size)
    resize_ethos(g, size)
    if detail then add_detail(gid, cid, detail, n, true) end
    touched[cid] = true
    return n
end

-- ---------------------------------------------------------------------------------------------
-- where new pops go (NPlanetJobs::UpdatePopJobs, not modelled: a stand-in)
--
-- The game adds the month's pops to a pop group of the species without a category (SPopGroupKey
-- with the null CPopCategory; CColony::AccessOrAddPopGroupAddSize), then the jobs update moves them
-- into the categories of the jobs they take (CPopGroup::MoveSizeFrom: the moved pops' details go
-- with them, the emptied group is killed). Here they go at once to the species' group of a civilian
-- or unemployment category (is_civilian_job, is_unemployment_job), else its group of the lowest
-- rank, else a new group (civilian, or slave_unemployment for an enslaved species).

local category_cache = {}
local function category_info(name)
    local c = category_cache[name]
    if c == nil then
        local d = name and defs.get("common/pop_categories", name)
        c = {
            rank = d and tonumber(defs.field(d.block, "rank")) or 0,
            fallback = d and (defs.field(d.block, "is_civilian_job") == "yes" or defs.field(d.block, "is_unemployment_job") == "yes") or false,
            display = d and defs.field(d.block, "display_category") or name,
        }
        category_cache[name] = c
    end
    return c
end
pops.category_info = category_info

local function is_enslaved_on(c, sid)
    for _, t in ipairs(world.list(world.field(c, "enslaved_species_refs"))) do
        if tonumber(t) == sid then return true end
    end
    return false
end

-- the next index of the pop group store (generation 0)
local function next_group_id()
    local max = -1
    for _, id in ipairs(world.all("pop_groups")) do
        slice.tick("pops.lua:1111")
        local index = id % 16777216
        if index > max then max = index end
    end
    return max + 1
end

local function create_group(cid, sid, category, like)
    local id = next_group_id()
    local g = {}
    local pid_key = {}
    world.append(pid_key, "species", sid)
    world.append(pid_key, "category", category, true)
    for _, f in ipairs({ "can_procreate", "can_crossbreed", "can_vote", "can_fill_worker_job", "can_fill_specialist_job", "can_fill_ruler_job" }) do
        if like and world.field(like, f) == "yes" then world.append(g, f, "yes") end
    end
    world.append(g, "key", pid_key)
    world.append(g, "planet", cid)
    local ethos = like and world.field(like, "ethos")
    if type(ethos) == "table" then
        local e = {}
        local names = {}
        for _, t in ipairs(world.list(world.field(ethos, "ethics"))) do names[#names + 1] = { text = t, quoted = true } end
        local counts = {}
        for _ in ipairs(names) do counts[#counts + 1] = { text = "0" } end
        world.append(e, "ethics", names)
        world.append(e, "pops", counts)
        world.append(g, "ethos", e)
    end
    world.append(g, "factions", {})
    world.append(g, "wanted_factions", {})
    world.append(g, "size", 0)
    world.append(g, "last_month_growth", 0)
    world.append(g, "month_start_size", 0)
    world.create("pop_groups", id, g)
    local c = world.object("colony", cid)
    world.append_value(world.child(c, "pop_groups"), id)
    pops.stats.groups_created = pops.stats.groups_created + 1
    return id
end

-- pops.create_group(colony, species, category[, like]) -> a new group at the end of the colony's
-- list (CColony::AddPopGroup 0x286a6e0), in the world's index of the planet's groups
function pops.create_group(cid, sid, category, like)
    local id = create_group(cid, sid, category, like)
    local pid = world.colony_planet[cid]
    if pid and world.pop_groups_of then
        local l = world.pop_groups_of[pid]
        if not l then l = {}; world.pop_groups_of[pid] = l end
        l[#l + 1] = id
    end
    return id
end

-- the ethics' pops of a group: { names }, { counts }
local function ethos_counts(g)
    local ethos = world.field(g, "ethos")
    if type(ethos) ~= "table" then return nil end
    local names, counts = world.list(world.field(ethos, "ethics")), {}
    for i, t in ipairs(world.list(world.field(ethos, "pops"))) do counts[i] = int(t) end
    return names, counts
end

local function write_ethos(g, names, counts)
    local ethos = world.field(g, "ethos")
    if type(ethos) ~= "table" then return end
    local idx = {}
    for i = 1, #names do idx[i] = i end
    table.sort(idx, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b
    end)
    local nb, cb = {}, {}
    for _, i in ipairs(idx) do
        if counts[i] > 0 then
            nb[#nb + 1] = { text = names[i], quoted = true }
            cb[#cb + 1] = { text = tostring(counts[i]) }
        end
    end
    replace_field(ethos, "ethics", nb)
    replace_field(ethos, "pops", cb)
end

-- pops.move_size(dst, src, n, detail, colony): CPopGroup::MoveSizeFrom (0x1e6d090): n (at most
-- the source's size) pops from src to dst, their ethics with them (the source resized, the
-- difference to the target by ethic [I]); an emptied source leaves the colony (CColony::
-- RemovePopGroup 0x286ab70: the last group swapped into its place), is killed, and its month's
-- details go to the target; the detail +n on the target and -n on the source, less what came with
-- the source's details
function pops.move_size(dst, src, n, detail, cid)
    local gs, gd = world.object("pop_groups", src), world.object("pop_groups", dst)
    if not gs or not gd or n <= 0 then return 0 end
    local size = int(world.field(gs, "size"))
    if n > size then n = size end
    if n <= 0 then return 0 end
    local names, before = ethos_counts(gs)
    set_int(gs, "size", size - n)
    resize_ethos(gs, size - n)
    if names and #names == #before then
        local an, after = ethos_counts(gs)
        local amap = {}
        for i, x in ipairs(an or {}) do amap[x] = after[i] or 0 end
        local dn, dc = ethos_counts(gd)
        if dn and #dn == #dc then
            local at = {}
            for i, x in ipairs(dn) do at[x] = i end
            for i, x in ipairs(names) do
                local moved = before[i] - (amap[x] or 0)
                if moved > 0 then
                    if not at[x] then
                        dn[#dn + 1] = x
                        dc[#dc + 1] = 0
                        at[x] = #dn
                    end
                    dc[at[x]] = dc[at[x]] + moved
                end
            end
            write_ethos(gd, dn, dc)
        end
    end
    set_int(gd, "size", int(world.field(gd, "size")) + n)
    local carried = 0
    if size - n <= 0 then
        local c = cid and world.object("colony", cid)
        local list = c and world.field(c, "pop_groups")
        if type(list) == "table" then
            local last, at
            for i, e in ipairs(list) do
                if e.text ~= nil then
                    last = i
                    if tonumber(e.text) == src and not at then at = i end
                end
            end
            if at then
                if at ~= last then world.set_text(list, at, list[last].text) end
                world.remove_at(list, last)
            end
        end
        world.set(gs, "killed", "yes")
        local sd = group_details(src)
        local dd = group_details(dst)
        for k, v in pairs(sd) do
            dd[k] = (dd[k] or 0) + v
            carried = carried + v
        end
        pops.stats.groups_killed = (pops.stats.groups_killed or 0) + 1
    end
    add_detail(dst, cid, detail, n - carried, true)
    add_detail(src, cid, detail, -(n - carried), true)
    touched[cid] = true
    return n
end

-- pops.target(colony, species[, rank]) -> the pop group new pops of the species go to
function pops.target(cid, sid, rank)
    local c = world.object("colony", cid)
    local best, best_rank, best_size, fallback
    local any
    for _, gid in ipairs(colony_groups(c)) do
        local g = world.object("pop_groups", gid)
        local s, cat = group_key(g)
        if s == sid then
            any = any or g
            local info = category_info(cat)
            local size = int(world.field(g, "size"))
            if rank then
                if info.rank == rank and (fallback == nil or size < fallback[2]) then
                    fallback = { gid, size }
                end
            elseif info.fallback then
                if fallback == nil or size > fallback[2] then fallback = { gid, size } end
            elseif best == nil or info.rank < best_rank or (info.rank == best_rank and size > best_size) then
                best, best_rank, best_size = gid, info.rank, size
            end
        end
    end
    if fallback then return fallback[1] end
    if best and not rank then return best end
    if rank then return nil end
    pops.stats.no_target = pops.stats.no_target + 1
    return create_group(cid, sid, is_enslaved_on(c, sid) and "slave_unemployment" or "civilian", any)
end

-- the month's pops of a species into the colony (AccessOrAddPopGroupAddSize with the null category,
-- then the jobs' move): the target's size, its details (the detail, and PROMOTION 0 from the move)
local function add_new_pops(cid, sid, n, detail, gid)
    gid = gid or pops.target(cid, sid)
    if not gid then return nil end
    add_size(gid, cid, n, detail)
    add_detail(gid, cid, "GROWTH_CAT_PROMOTION", 0, true)
    return gid
end

-- ---------------------------------------------------------------------------------------------
-- the serial part

-- an on_action of the pops (the script layer: this, from; fromfrom and local_pop_amount are not
-- passed yet)
local function fire(host, name, this, from)
    if not host then return end
    local events = require("simscript.events")
    -- events.on_action takes the on_action's from as from_ctx.this (and fromfrom as its from)
    local ctx = eval.new_ctx(from or eval.NONE)
    local ok = pcall(events.on_action, name, this, ctx)
    if not ok then pops.stats.on_action_errors = (pops.stats.on_action_errors or 0) + 1 end
end

-- CColony::OnAddPops -> ExecuteAddPopOnAction (0xdad9b0): two draws for the scopes, then
-- on_pop_group_added (this = the pop group, from = the colony)
local function on_added(host, cid, gid)
    RUST.rand()
    RUST.rand()
    local pid = world.colony_planet[cid]
    fire(host, "on_pop_group_added", eval.S("pop_group", gid), pid and eval.S("planet", pid) or nil)
end

-- CColony::ApplyMonthlyGrowth (0xdbf1e0): one draw for the on_action's scopes, then per species
-- with growth: the pops added (GROWTH_CAT_GROWTH), on_pop_growth (this = the colony, from = the
-- owner, fromfrom = the pop group)
local function apply_growth(host, cid, demo)
    RUST.rand()
    local country, pid = owner_of(cid)
    local any = false
    for _, sp in ipairs(demo.species) do
        if sp.amount and sp.amount > 0 then
            local gid = add_new_pops(cid, sp.species, sp.amount, "GROWTH_CAT_GROWTH")
            if gid then
                any = true
                pops.stats.growth_events = pops.stats.growth_events + 1
                pops.stats.grown = pops.stats.grown + sp.amount
                on_added(host, cid, gid)
                if pid then
                    fire(host, "on_pop_growth", eval.S("planet", pid), country and eval.S("country", country) or nil)
                end
            end
        end
    end
    return any
end

-- CColony::ApplyMonthlyAssembly (0xdbfc70): when there is an assembly, one draw, the pops added to
-- the species' smallest pop group of the category rank NEWLY_ASSEMBLED_POP_TARGET_RANK (else
-- without a category: the jobs' stand-in), GROWTH_CAT_ASSEMBLY, on_pop_assembly
local function apply_assembly(host, cid, demo)
    local a = demo.assembly
    if not a or a.amount == 0 then return false end
    RUST.rand()
    local country, pid = owner_of(cid)
    local gid = pops.target(cid, a.species, defines().NEWLY_ASSEMBLED_POP_TARGET_RANK)
    if gid then
        add_size(gid, cid, a.amount, "GROWTH_CAT_ASSEMBLY")
    else
        gid = add_new_pops(cid, a.species, a.amount, "GROWTH_CAT_ASSEMBLY")
    end
    if not gid then return false end
    pops.stats.assembled = pops.stats.assembled + a.amount
    on_added(host, cid, gid)
    if pid then
        fire(host, "on_pop_assembly", eval.S("planet", pid), country and eval.S("country", country) or nil)
    end
    return true
end

-- CColony::ApplyMonthlyDecline (0xdc0160): one draw, then per species with decline: from the
-- colony's last pop group of the species on, the pops taken (GROWTH_CAT_DECLINE) until the amount is
-- reached (on_pop_displaced / on_pop_purged for purged pops: not modelled)
local function apply_decline(host, cid, demo)
    RUST.rand()
    local c = world.object("colony", cid)
    local any = false
    for _, sp in ipairs(demo.species) do
        local n = trunc(sp.decline or ZERO)
        while n > 0 do
            local last
            for _, gid in ipairs(colony_groups(c)) do
                local g = world.object("pop_groups", gid)
                if group_key(g) == sp.species and int(world.field(g, "size")) > 0 then
                    last = gid
                end
            end
            if not last then break end
            local size = int(world.field(world.object("pop_groups", last), "size"))
            local take = math.min(n, size)
            add_size(last, cid, -take, "GROWTH_CAT_DECLINE")
            if int(world.field(world.object("pop_groups", last), "size")) == 0 then
                -- emptied: out of the colony, killed (CColony::RemovePopGroup, the ToBeKilled flag)
                world.remove_value(world.child(c, "pop_groups"), last)
                world.set(world.object("pop_groups", last), "killed", "yes")
            end
            n = n - take
            any = true
            pops.stats.declined = pops.stats.declined + take
        end
    end
    return any
end

-- CColony::GrowColonists (0xdc1390): a colony being colonized grows by COLONY_MONTHLY_GROWTH * (1 +
-- planet_colony_development_speed_mult), rounded with the colony's stream, into its colonizing
-- species (GROWTH_CAT_COLONIZATION); done at COLONY_POPS_REQUIRED: the colony placed
-- (CColony::CheckAndHandleColonizationFinished -> CPlanet::PlaceColony: engine.fleets.colonize)
local function grow_colonists(host, cid, rv)
    local c = world.object("colony", cid)
    local sid = c and tonumber(world.field(c, "colonizing_species"))
    if not sid or sid == NONE then return end
    local d = defines()
    local M = modifiers("colony", cid)
    local rate = fmul(d.COLONY_MONTHLY_GROWTH, mod(M, "planet_colony_development_speed_mult") + ONE)
    if rate < 0 then rate = ZERO end
    local n = round_random(rate, stream(rv))
    if n <= 0 then return end
    local gid = add_new_pops(cid, sid, n, "GROWTH_CAT_COLONIZATION")
    if gid then on_added(host, cid, gid) end
    pops.stats.colonized = pops.stats.colonized + n
    local total = 0
    for _, gid in ipairs(colony_groups(c)) do
        total = total + int(world.field(world.object("pop_groups", gid), "size"))
    end
    if total >= d.COLONY_POPS_REQUIRED then
        pops.stats.colonization_done = pops.stats.colonization_done + 1
        require("engine.fleets.colonize").place_colony(cid)
    end
end

-- ---------------------------------------------------------------------------------------------
-- the month's bookkeeping: CColony::UpdateCachedGrowth (0xdb6430)

-- the colony's sizes: total, and per species (sum, and per display category)
local function colony_sizes(c)
    local total, species, order = 0, {}, {}
    for _, gid in ipairs(colony_groups(c)) do
        local g = world.object("pop_groups", gid)
        local sid, cat = group_key(g)
        local size = int(world.field(g, "size"))
        total = total + size
        local s = species[sid]
        if not s then
            s = { size = 0, cats = {} }
            species[sid] = s
            order[#order + 1] = sid
        end
        s.size = s.size + size
        local dc = category_info(cat).display or cat
        if dc then
            s.cats[dc] = (s.cats[dc] or 0) + size
        end
    end
    return total, species, order
end

-- SMonthlyGrowthData as read from the save: { start, growth, species = { [sid] = { start, growth, cats
-- = { [cat] = { start, growth } } } }, details }
local function read_growth_data(b)
    local data = { start = 0, growth = 0, species = {}, order = {} }
    if type(b) ~= "table" then return data end
    local gs = world.field(b, "growth_and_size")
    data.start, data.growth = int(world.field(gs, "month_start_size")), int(world.field(gs, "growth"))
    local sp = world.field(b, "species")
    local k
    for _, e in ipairs(type(sp) == "table" and sp or {}) do
        if e.op and e.key.text == "key" then
            k = tonumber(e.value.text)
        elseif e.op and e.key.text == "value" and k and e.value.text == nil then
            local sgs = world.field(e.value, "growth_and_size")
            local s = { start = int(world.field(sgs, "month_start_size")), growth = int(world.field(sgs, "growth")), cats = {}, corder = {} }
            local cats = world.field(e.value, "categories")
            local ck
            for _, x in ipairs(type(cats) == "table" and cats or {}) do
                if x.op and x.key.text == "key" then
                    ck = x.value.text
                elseif x.op and x.key.text == "value" and ck and x.value.text == nil then
                    s.cats[ck] = { start = int(world.field(x.value, "month_start_size")), growth = int(world.field(x.value, "growth")) }
                    s.corder[#s.corder + 1] = ck
                end
            end
            data.species[k] = s
            data.order[#data.order + 1] = k
        end
    end
    return data
end

local function growth_and_size(start, growth)
    local b = {}
    world.append(b, "month_start_size", start)
    world.append(b, "growth", growth)
    return b
end

local function write_growth_data(data, details)
    local b = {}
    world.append(b, "growth_and_size", growth_and_size(data.start, data.growth))
    local sids = {}
    for sid in pairs(data.species) do sids[#sids + 1] = sid end
    table.sort(sids)
    local sp = {}
    for _, sid in ipairs(sids) do
        local s = data.species[sid]
        local v = {}
        world.append(v, "growth_and_size", growth_and_size(s.start, s.growth))
        local cats = {}
        local ckeys = {}
        for ck in pairs(s.cats) do ckeys[#ckeys + 1] = ck end
        table.sort(ckeys)
        for _, ck in ipairs(ckeys) do
            world.append(cats, "key", ck, true)
            world.append(cats, "value", growth_and_size(s.cats[ck].start, s.cats[ck].growth))
        end
        world.append(v, "categories", cats)
        world.append(sp, "key", sid)
        world.append(sp, "value", v)
    end
    world.append(b, "species", sp)
    if details and next(details) then
        world.append(b, "current_month_growth_details", details_block(details))
    end
    return b
end

-- the colony's caches that follow its pops (CColony::OnAddPops: CalcEmployablePops,
-- UpdateSpeciesInformation; MicroUpdateCachedValues: CalcSapientPopAmount)
local function update_colony_caches(cid, c)
    local total, species = colony_sizes(c)
    local sapient = 0
    for sid, s in pairs(species) do
        if is_sapient(sid) then sapient = sapient + s.size end
    end
    if entry(c, "employable_pops") then world.set(c, "employable_pops", total) end
    if entry(c, "num_sapient_pops") then world.set(c, "num_sapient_pops", sapient) end
    local info = world.field(c, "species_information")
    if type(info) == "table" then
        for _, e in ipairs(info) do
            if e.op and e.value.text == nil then
                local sid = tonumber(e.key.text)
                local s = species[sid]
                local n = s and s.size or 0
                local old = int(world.field(e.value, "num_pops"))
                local ens = tonumber(world.field(e.value, "num_enslaved"))
                world.set(e.value, "num_pops", n)
                if ens and ens == old then
                    world.set(e.value, "num_enslaved", n)
                end
            end
        end
    end
end

local function update_cached_growth(cid)
    local c = world.object("colony", cid)
    if not c then return end
    -- the pop groups (CPopGroup::UpdateCachedGrowth 0x67de70)
    for _, gid in ipairs(colony_groups(c)) do
        local g = world.object("pop_groups", gid)
        local size = int(world.field(g, "size"))
        set_int(g, "last_month_growth", size - int(world.field(g, "month_start_size")))
        set_int(g, "month_start_size", size)
        local cur = current_details[gid] or read_details(world.field(g, "current_month_growth_details"))
        write_details(g, "last_month_growth_details", cur, { "month_start_size" })
        write_details(g, "current_month_growth_details", {}, {})
        current_details[gid] = nil
    end
    -- the colony: the current month finished (SetAsLastMonth), a new one (ResetAsCurrentMonth)
    local total, species, order = colony_sizes(c)
    local cur = read_growth_data(world.field(c, "current_month_growth_data"))
    cur.growth = total - cur.start
    for sid, s in pairs(cur.species) do
        local now = species[sid]
        s.growth = (now and now.size or 0) - s.start
        for ck, cs in pairs(s.cats) do
            cs.growth = (now and now.cats[ck] or 0) - cs.start
        end
    end
    local details = colony_details[cid] or read_details((function()
        local b = world.field(c, "current_month_growth_data")
        return type(b) == "table" and world.field(b, "current_month_growth_details") or nil
    end)())
    colony_details[cid] = nil
    local fresh = { start = total, growth = 0, species = {} }
    for _, sid in ipairs(order) do
        local s = species[sid]
        local cats = {}
        for ck, n in pairs(s.cats) do cats[ck] = { start = n, growth = 0 } end
        fresh.species[sid] = { start = s.size, growth = 0, cats = cats }
    end
    replace_field(c, "last_month_growth_data", write_growth_data(cur, details), { "buildings_cache" })
    replace_field(c, "current_month_growth_data", write_growth_data(fresh, nil), { "last_month_growth_data" })
end

-- ---------------------------------------------------------------------------------------------
-- the colonies' resource tables (NColonyUpdate::MonthlyParallelUpdate lambda 13:
-- CColony::CalcTableIncludePops<1>/<2> into upkeep and produces, profits = produces - upkeep; the
-- tables swapped in by lambda 14), from the month's budget: what the colony's own economic units
-- (jobs, buildings, districts, zones, pop groups, deposits) produce and use
-- (engine.economy's colony_tables, computed in the budget phase just before)

local function resource_block(values, resources)
    local b = {}
    for _, r in ipairs(resources) do
        local v = values[r]
        if v and math.abs(v) >= 0.000005 then
            world.append(b, r, math.floor(v * ONE + (v >= 0 and 0.5 or -0.5)) / ONE)
        end
    end
    return b
end

local function update_colony_tables()
    local economy = package.loaded["engine.economy"]
    local tables = economy and economy.colony_tables
    local resources = economy and economy.resources
    if not tables or not resources or next(tables) == nil then
        return 0
    end
    local n = 0
    for _, cid in ipairs(world.all("colony")) do
        slice.tick("pops.lua:1512")
        local c = world.object("colony", cid)
        if c and entry(c, "produces") then
            local t = tables[cid] or { income = {}, expenses = {} }
            local profits = {}
            for r, v in pairs(t.income) do profits[r] = (profits[r] or 0) + v end
            for r, v in pairs(t.expenses) do profits[r] = (profits[r] or 0) - v end
            replace_field(c, "upkeep", resource_block(t.expenses, resources))
            replace_field(c, "produces", resource_block(t.income, resources))
            replace_field(c, "profits", resource_block(profits, resources))
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- the day's housing (CPopGroup::DailyUpdateOnlyChangeSafePrivate -> CalcHousingUsage 0x67fd60, in the
-- daily pop group phase, which the tick does not hook yet: pops.daily)

-- CPopGroup::CalcHousingUsage: max(0, size * (pop_housing_usage_base + pop_housing_usage_add) *
-- max(min, 1 + pop_housing_usage_mult))
function pops.housing_usage(gid, size)
    local M = modifiers("pop_group", gid)
    local base = mod(M, "pop_housing_usage_base") + mod(M, "pop_housing_usage_add")
    local u = fmul(I64(size) * base, mult_of(mod(M, "pop_housing_usage_mult")))
    if u < 0 then u = ZERO end
    return u
end

-- the colony's housing: planet_housing_add * (1 + planet_housing_mult) of its modifier node (the
-- colony's cached housing; the formula checked on the 2210.01.01 save's 49 colonies, the function
-- not traced)
function pops.total_housing(cid)
    local M = modifiers("colony", cid)
    if M.planet_housing_add == nil then return nil end
    local h = fmul(mod(M, "planet_housing_add"), mult_of(mod(M, "planet_housing_mult")))
    if h < 0 then h = ZERO end
    return h
end

-- the colonies' own day (engine.colonies: MicroUpdateCachedValues), when it is there
local function colonies_module()
    if pops.colonies == nil then
        pops.colonies = package.searchpath("engine.colonies", package.path) and require("engine.colonies") or false
    end
    return pops.colonies or nil
end

-- pops.daily(host, date): the pop groups' housing usage, and (without engine.colonies, which
-- computes them in the colonies' phase as the game does) their colonies' housing, the sum of the
-- usage, the free housing left
function pops.daily(host, date)
    local own_colonies = colonies_module() == nil
    for _, cid in ipairs(world.all("colony")) do
        slice.tick("pops.lua:1566")
        local c = world.object("colony", cid)
        slice.tick("pops colony")
        if c and entry(c, "housing_usage") then
            local total = ZERO
            for _, gid in ipairs(colony_groups(c)) do
                local g = world.object("pop_groups", gid)
                slice.tick("pops housing")
                local u = pops.housing_usage(gid, int(world.field(g, "size")))
                total = total + u
                if entry(g, "housing_usage") then
                    world.set(g, "housing_usage", num(u))
                end
            end
            if own_colonies then
                pops.colony_housing(cid, c, total)
            end
        end
    end
end

-- a colony's housing from its groups' usage (the colonies' phase does it when engine.colonies is
-- there)
function pops.colony_housing(cid, c, total)
    world.set(c, "housing_usage", num(total))
    local housing = pops.total_housing(cid)
    if housing then
        world.set(c, "total_housing", num(housing))
    else
        housing = fx(tonumber(world.field(c, "total_housing")))
    end
    world.set(c, "free_housing", num(housing - total))
end

-- ---------------------------------------------------------------------------------------------
-- the month

-- the pop groups the game killed: emptied and taken out of their colony (killed = yes); the game
-- removes them in the next day's pop group phase (empty groups killed), here at the month's start
local function remove_killed()
    local list = {}
    for _, id in ipairs(world.all("pop_groups")) do
        slice.tick("pops.lua:1606")
        local g = world.object("pop_groups", id)
        if g and world.field(g, "killed") == "yes" and int(world.field(g, "size")) == 0 then
            list[#list + 1] = id
        end
    end
    for _, id in ipairs(list) do
        world.remove("pop_groups", id)
        pops.stats.groups_removed = pops.stats.groups_removed + 1
    end
end

local function reset_caches()
    founder_cache, scale_cache = {}, {}
end
pops.remove_killed = remove_killed
-- pops.add_size(gid, cid, n, detail): a pop group's size changed by n (its ethos with it, the
-- month's detail): the script's kill_pop_group / sacrifice_pop_group (handlers/planet_effects.lua)
pops.add_size = add_size

-- pops.monthly(host, date): NColonyUpdate::MonthlyUpdate's pops
local monthly
function pops.monthly(host, date)
    return script.with(monthly, host, date)
end
monthly = function(host, date)
    local s = pops.stats
    s.months = s.months + 1
    reset_caches()
    remove_killed()
    local pool = monthly_pool()
    local colonies = {}
    for _, cid in ipairs(world.all("colony")) do
        slice.tick("pops.lua:1634")
        local c = world.object("colony", cid)
        if c and world.colony_planet[cid] then
            colonies[#colonies + 1] = cid
        end
    end
    s.colonies = #colonies
    -- the day's pop group update runs before the month's (DailyUpdate, then MonthlyUpdate): its
    -- housing, which the growth reads (free_housing), from the sizes as they are (pops.daily; the
    -- daily phase is not hooked yet)
    pops.daily(host, date)
    -- the parallel part: the colonies' tables, every colony's demography, from the world as it is
    s.tables = (s.tables or 0) + update_colony_tables()
    local demo = {}
    for _, cid in ipairs(colonies) do
        slice.check("pops demography")
        demo[cid] = demography(cid, pool[(cid + 266) % 1000 + 1])
        pops.last[cid] = demo[cid]
        if demo[cid].skipped then
            s.skipped[demo[cid].skipped] = (s.skipped[demo[cid].skipped] or 0) + 1
        end
        for _, sp in ipairs(demo[cid].species) do
            s.expected = s.expected + num(sp.expected)
        end
    end
    -- the serial part
    for _, cid in ipairs(colonies) do
        slice.check("pops growth")
        grow_colonists(host, cid, pool[(cid + 6601) % 1000 + 1])
        apply_growth(host, cid, demo[cid])
        apply_assembly(host, cid, demo[cid])
        apply_decline(host, cid, demo[cid])
    end
    -- NPlanetJobs::UpdatePopJobs, twice (unless a cheat flag): the month's new pops into jobs
    -- (engine.jobs; the new pops went to their species' civilian group, pops.target)
    local ok_jobs, jobs = pcall(require, "engine.jobs")
    if ok_jobs and jobs and not jobs.off then
        jobs.update(colonies)
        jobs.update(colonies)
    end
    -- the caches that follow the pops, the month's growth
    local col = colonies_module()
    for _, cid in ipairs(colonies) do
        local c = world.object("colony", cid)
        slice.tick("pops caches")
        if touched[cid] then
            update_colony_caches(cid, c)
            -- the game recomputes a colony's cached values after a size change
            -- (MicroUpdateCachedValues: housing, amenities, stability, ...)
            if col and col.micro_update then
                col.micro_update(cid)
            end
        end
        update_cached_growth(cid)
    end
    touched = {}
    reset_caches()
    local economy = package.loaded["engine.economy"]
    if economy and economy.invalidate then economy.invalidate() end
end

function pops.report()
    local s = pops.stats
    local skipped = {}
    for k, v in pairs(s.skipped) do skipped[#skipped + 1] = k .. " " .. v end
    table.sort(skipped)
    return string.format("pops: %d months over %d colonies: %d pops grown in %d growth events (%.1f expected), "
        .. "%d colonists (%d colony-months at the colony size: completion not modelled), %d assembled, %d declined; "
        .. "%d colony tables written; %d pop groups created, %d killed ones removed, %d rule errors, %d on_action errors; "
        .. "colonies without growth: %s", s.months, s.colonies, s.grown, s.growth_events, s.expected, s.colonized,
        s.colonization_done, s.assembled, s.declined, s.tables or 0, s.groups_created, s.groups_removed, s.rule_errors,
        s.on_action_errors or 0, table.concat(skipped, ", "))
end

return pops
