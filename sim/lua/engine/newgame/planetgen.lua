-- engine/newgame/planetgen.lua : what a new planet gets as it is made: its planet modifiers
-- (CPlanet::RandomizePlanetModifiers) and its deposits (CColonyCarrier::RandomizeDeposits), drawn
-- from the global stream as the game draws them (Linux 4.5.2, measured: docs/newgame.md, 9).
--
--   local planetgen = require("engine.newgame.planetgen")
--   planetgen.context(ctx)                       -- once: the deposit and modifier types
--   planetgen.randomize_modifiers(ctx, game, p, C)
--   planetgen.randomize_deposits(ctx, game, p, C)
--
-- p: { class, size, system, moon_of, primary, modifiers = { name, ... }, deposit_types = { type, ... } }.

local source = require("stellar.script.source")
local scenario = require("engine.newgame.scenario")
local fixed = require("engine.newgame.fixed")
local rng = require("engine.newgame.rng")

local planetgen = {}

local field = scenario.field
local ONE = fixed.ONE
local number

-- ---------------------------------------------------------------------------------------------
-- definitions

-- the entries of a folder's files, in the game's order (the files by name, the entries in order)
local function entries_of(fs, dir)
    local out = {}
    local files = source.files(fs, dir, "txt")
    table.sort(files)
    for _, f in ipairs(files) do
        for _, e in ipairs(source.parse(fs, f) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.key.text:sub(1, 1) ~= "@" then
                local block = source.expand(fs, e.value) or e.value
                out[#out + 1] = { name = e.key.text, block = block, file = f }
            end
        end
    end
    return out
end

function planetgen.context(ctx)
    if ctx.deposit_types then
        return ctx
    end
    local fs = ctx.fs
    ctx.deposit_categories = {}
    for _, c in ipairs(entries_of(fs, "common/deposit_categories")) do
        ctx.deposit_categories[c.name] = { name = c.name, blocker = field(c.block, "blocker") == "yes" }
    end
    ctx.deposit_types = {}
    ctx.deposit_type_by_name = {}
    for _, d in ipairs(entries_of(fs, "common/deposits")) do
        local b = d.block
        local t = {
            name = d.name, block = b, file = d.file,
            null = field(b, "is_null") == "yes",
            colonizable = field(b, "is_for_colonizable") == "yes",
            minmax = field(b, "use_for_min_max_adjustments") == "yes",
            category = field(b, "category") and ctx.deposit_categories[field(b, "category")] or nil,
            potential = field(b, "potential"),
            drop_weight = field(b, "drop_weight"),
            planet_modifier = field(b, "planet_modifier"),
        }
        ctx.deposit_types[#ctx.deposit_types + 1] = t
        ctx.deposit_type_by_name[d.name] = t
    end
    -- the district types in database order, with what RandomizeDeposits reads: the deposit-made
    -- maximum's bounds (min_for_deposits_on_planet +0xe5c, max_for_deposits_on_planet +0xe60) and
    -- is_uncapped
    ctx.district_types = {}
    for _, d in ipairs(entries_of(fs, "common/districts")) do
        local b = d.block
        ctx.district_types[#ctx.district_types + 1] = {
            name = d.name, file = d.file,
            -- the capacity modifiers: <shared_capacity_modifier>_max_add / _max_mult (melting and
            -- hollow mountains share mining's)
            pool = field(b, "shared_capacity_modifier") or d.name,
            min = number(ctx, field(b, "min_for_deposits_on_planet"), d.file) or 0,
            max = number(ctx, field(b, "max_for_deposits_on_planet"), d.file) or 0,
            is_uncapped = field(b, "is_uncapped"),
        }
    end
    ctx.planet_modifier_types = {}
    for _, m in ipairs(entries_of(fs, "common/planet_modifiers")) do
        local b = m.block
        ctx.planet_modifier_types[#ctx.planet_modifier_types + 1] = {
            name = m.name, block = b, file = m.file,
            null = field(b, "is_null") == "yes",
            potential = field(b, "potential"),
            spawn_chance = field(b, "spawn_chance"),
        }
    end
    ctx.unknown_planet_triggers = ctx.unknown_planet_triggers or {}
    return ctx
end

-- ---------------------------------------------------------------------------------------------
-- triggers on a planet (the subset the deposits and the planet modifiers use)

function number(ctx, v, file)
    if type(v) == "table" then
        v = v.text
        if v == nil then
            return nil
        end
    end
    return scenario.number(ctx.fs, v, file)
end

local function compare(op, a, b)
    if op == "<" then return a < b end
    if op == ">" then return a > b end
    if op == "<=" then return a <= b end
    if op == ">=" then return a >= b end
    if op == "!=" then return a ~= b end
    return a == b
end

local eval

local function class_of(ctx, p)
    return ctx.planet_classes[p.class] or {}
end

-- one statement; nil when the evaluator does not know it (counted)
local function trigger(ctx, game, p, e, file)
    local key = e.key.text
    local v = e.value
    local text = type(v) == "table" and nil or v.text
    local yes = text == "yes"
    local sys = game.systems[p.system + 1]
    if key == "AND" then
        return eval(ctx, game, p, v, file)
    elseif key == "OR" then
        local unknown = false
        for _, s in ipairs(v) do
            if s.op and s.key then
                local r = trigger(ctx, game, p, s, file)
                if r == nil then
                    unknown = true
                elseif r == (s.op ~= "!=") then
                    return true
                end
            end
        end
        if unknown then return nil end
        return false
    elseif key == "NOT" or key == "NOR" then
        local r
        if key == "NOT" then
            r = eval(ctx, game, p, v, file)
        else
            r = trigger(ctx, game, p, { key = { text = "OR" }, value = v, op = "=" }, file)
        end
        if r == nil then return nil end
        return not r
    elseif key == "NAND" then
        local r = eval(ctx, game, p, v, file)
        if r == nil then return nil end
        return not r
    elseif key == "always" then
        return yes
    elseif key == "is_planet_class" then
        return p.class == text
    elseif key == "planet_size" then
        return compare(e.op, p.size, number(ctx, v, file) or 0)
    elseif key == "is_star" then
        return (class_of(ctx, p).star == true) == yes
    elseif key == "is_primary_star" then
        return (class_of(ctx, p).star == true and p.primary == true) == yes
    elseif key == "is_asteroid" then
        return (class_of(ctx, p).asteroid == true) == yes
    elseif key == "is_colonizable" then
        return (class_of(ctx, p).colonizable == true) == yes
    elseif key == "is_moon" then
        return (p.moon_of ~= nil) == yes
    elseif key == "has_moon" then
        return (#(p.moons or {}) > 0) == yes
    elseif key == "num_moons" then
        return compare(e.op, #(p.moons or {}), number(ctx, v, file) or 0)
    elseif key == "num_modifiers" then
        return compare(e.op, #(p.modifiers or {}), number(ctx, v, file) or 0)
    elseif key == "has_planet_modifier" or key == "has_modifier" then
        for _, m in ipairs(p.modifiers or {}) do
            if m == text then return true end
        end
        return false
    elseif key == "has_deposit" then
        if text == nil then
            return #(p.deposit_types or {}) > 0
        end
        for _, d in ipairs(p.deposit_types or {}) do
            if d.name == text then return true end
        end
        return false
    elseif key == "uses_district_set" then
        return (class_of(ctx, p).district_set or "standard") == text
    elseif key == "has_carrier_flag" or key == "is_capital" then
        return not yes and false or false
    elseif key == "owner_or_space_owner" or key == "space_owner" then
        return false
    elseif key == "has_climate" then
        return class_of(ctx, p).climate == text
    elseif key == "has_planet_flag" then
        -- the planet's prescripted flags come after its deposits (CPlanet::InitializePlanet)
        return (p.gen_flags or {})[text] ~= nil
    elseif key == "has_star_flag" then
        return sys.flags[text] ~= nil
    elseif key == "is_inside_nebula" then
        return (sys.nebula ~= nil) == yes
    elseif key == "solar_system" or key == "star" then
        local systems = require("engine.newgame.systems")
        local unknown = false
        for _, s in ipairs(v) do
            if s.op and s.key then
                local r = systems.trigger(ctx, sys, s.key.text, s.value, game)
                if r == nil then
                    unknown = true
                elseif r ~= (s.op ~= "!=") then
                    return false
                end
            end
        end
        if unknown then return nil end
        return true
    elseif key == "exists" then
        -- nothing is owned or controlled while the galaxy is made
        if text == "owner" or text == "controller" or text == "space_owner" or text == "from"
            or text == "owner_or_space_owner" then
            return false
        end
        return nil
    elseif key == "owner" or key == "controller" then
        return false
    elseif key == "has_origin" then
        return false
    elseif key == "is_special_colony_type" then
        return not yes
    elseif key == "host_has_dlc" or key == "has_dlc" then
        return ctx.dlcs == nil or ctx.dlcs[text] == true
    end
    local st = ctx.scripted_triggers and ctx.scripted_triggers[key]
    if st and (yes or text == "no") then
        local r = eval(ctx, game, p, st.block, st.file)
        if r == nil then return nil end
        return r == yes
    end
    ctx.unknown_planet_triggers[key] = (ctx.unknown_planet_triggers[key] or 0) + 1
    return nil
end

-- the AND of a block's statements; nil when one is unknown (and none fails)
function eval(ctx, game, p, block, file)
    local unknown = false
    for _, e in ipairs(block or {}) do
        if e.op and e.key then
            local r = trigger(ctx, game, p, e, file)
            if r == nil then
                unknown = true
            elseif e.op == "!=" and type(e.value) ~= "table" then
                if r then return false end
            elseif not r then
                return false
            end
        end
    end
    if unknown then return nil end
    return true
end
planetgen.eval = eval

-- a potential: an unknown statement counts as failing (the summary lists them)
local function passes(ctx, game, p, block, file)
    if block == nil then
        return true
    end
    return eval(ctx, game, p, block, file) == true
end

-- CMeanTimeToHappen::GetRawFactor (Linux 0x1d580e0): the base (`base`, `weight` or a top-level
-- `factor`, else 0: a deposit with no drop_weight never spawns), then each modifier whose triggers pass, its operation in fixed point
-- (factor: fixmul, add: plus); raw fixed point
local function mtth(ctx, game, p, block, file, default)
    if block == nil then
        return fixed.from(default or 0)
    end
    if type(block) ~= "table" then
        return fixed.from(number(ctx, block, file) or 0)
    end
    local base = field(block, "base") or field(block, "weight") or field(block, "factor")
    local w = base and fixed.from(number(ctx, base, file) or 0) or fixed.from(default or 0)
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text == "modifier" and type(e.value) == "table" then
            local cond, ops = {}, {}
            for _, s in ipairs(e.value) do
                if s.op and s.key then
                    local k = s.key.text
                    if k == "factor" or k == "add" or k == "weight" then
                        ops[#ops + 1] = { k, fixed.from(number(ctx, s.value, file) or 0) }
                    else
                        cond[#cond + 1] = s
                    end
                end
            end
            if eval(ctx, game, p, cond, file) == true then
                for _, o in ipairs(ops) do
                    if o[1] == "factor" then
                        w = fixed.mul(w, o[2])
                    elseif o[1] == "add" then
                        w = w + o[2]
                    else
                        w = o[2]
                    end
                end
            end
        end
    end
    return w
end
planetgen.mtth = mtth

-- GetWeightedRandom (Linux 0x4274810): weights raw fixed point, the negative ones as 0; t = r %
-- total (a total past 2^31: floor(floor(total * 1000 / (2^31 - 1)) * r / 1000)); the first index
-- whose running sum passes t; nil for a zero total
local function weighted(weights, r)
    local total = 0
    for i = 1, #weights do
        if weights[i] > 0 then
            total = total + weights[i]
        end
    end
    if total <= 0 then
        return nil
    end
    local t
    if total < 2147483648 then
        t = r % total
    else
        t = math.floor(math.floor(total * 1000 / 2147483647) * r / 1000)
    end
    local sum = 0
    for i = 1, #weights do
        if weights[i] > 0 then
            sum = sum + weights[i]
            if sum > t then
                return i
            end
        end
    end
    return nil
end
planetgen.weighted = weighted

-- ---------------------------------------------------------------------------------------------
-- planet modifiers

-- CPlanet::RandomizePlanetModifiers (Linux 0x2a61a40): a global draw r, the pick of
-- CPlanetModifierDatabase::GetRandomModifier(planet, r) (0x2a8f400: a stream of its own from r,
-- its first value the scope's, its second the weighted pick over every modifier's spawn_chance,
-- 0 where the potential fails), again until the pick is the null modifier
function planetgen.randomize_modifiers(ctx, game, p, C)
    planetgen.context(ctx)
    p.modifiers = p.modifiers or {}
    for _ = 1, 64 do
        local r = C:int()
        local local_stream = rng.new(rng.noise32(r, rng.SEED_SALT), 0)
        local_stream:int()
        local weights = {}
        for i, m in ipairs(ctx.planet_modifier_types) do
            local w = 0
            if passes(ctx, game, p, m.potential, m.file) then
                w = mtth(ctx, game, p, m.spawn_chance, m.file, 0)
            end
            weights[i] = math.max(w, 0)
        end
        local roll = local_stream:int()
        local i = weighted(weights, roll)
        local m = i and ctx.planet_modifier_types[i]
        if os.getenv and os.getenv("NEWGAME_MODIFIER_DEBUG") then
            local parts = {}
            for k, w in ipairs(weights) do
                if w > 0 then parts[#parts + 1] = ctx.planet_modifier_types[k].name .. "=" .. w end
            end
            io.stderr:write("modifier ", C.draws, " ", tostring(p.class), " size ", tostring(p.size), " -> ", m and m.name or "none", ": ", table.concat(parts, " "), string.char(10))
        end
        if not m or m.null then
            return
        end
        p.modifiers[#p.modifiers + 1] = m.name
    end
end

-- ---------------------------------------------------------------------------------------------
-- deposits

local function category_count(p, cat)
    local n = 0
    for _, t in ipairs(p.deposit_types or {}) do
        if t.category == cat then
            n = n + 1
        end
    end
    return n
end

-- CDepositTypesDatabase::_Randomize (Linux 0x249be70) with r: the types in order, null ones left
-- out when `no_null`, is_for_colonizable matching the planet, the potential passing; the weight
-- the drop_weight, the null deposit's divided by the abundance, each divided by 1 + 0.25 x the
-- deposits of its category already there; the pick by GetWeightedRandom(r); nil for none or null
local function random_deposit(ctx, game, p, r, no_null, only)
    local colonizable = class_of(ctx, p).colonizable == true
    local abundance = fixed.from(game.inputs.config.resource_abundance or 2)
    local per = fixed.from(tonumber((game.defines or {}).DEPOSIT_USED_CATEGORY_WEIGHT) or 0.25)
    local weights = {}
    for i, t in ipairs(ctx.deposit_types) do
        local w = 0
        local ok = true
        if no_null and t.null then
            ok = false
        end
        if ok and not t.null and t.colonizable ~= colonizable then
            ok = false
        end
        if ok and only == "blockers" and not (t.category and t.category.blocker) then
            ok = false
        elseif ok and only == "non_blockers" and t.category and t.category.blocker then
            ok = false
        end
        if ok and passes(ctx, game, p, t.potential, t.file) then
            w = mtth(ctx, game, p, t.drop_weight, t.file, 0)
            if t.null and abundance > 0 then
                w = fixed.div(w, abundance)
            end
            if t.category then
                local d = ONE + fixed.mul(category_count(p, t.category) * ONE, per)
                if d > 0 then
                    w = fixed.div(w, d)
                end
            end
        end
        weights[i] = math.max(w, 0)
    end
    local dbg = os.getenv and os.getenv("NEWGAME_DEPOSIT_DEBUG")
    if dbg and tonumber(dbg) == p.id then
        local parts = {}
        for k, w in ipairs(weights) do
            if w > 0 then parts[#parts + 1] = ctx.deposit_types[k].name .. "=" .. w end
        end
        io.stderr:write("deposit weights planet ", p.id, " ", tostring(p.class), " r ", r, ": ", table.concat(parts, " "), string.char(10))
    end
    local i = weighted(weights, r)
    local t = i and ctx.deposit_types[i]
    if not t or t.null then
        return nil
    end
    return t
end
planetgen.random_deposit = random_deposit

-- a deposit made (CGameState::CreateNewDeposit): a blocker draws once for its swap type
-- (CDeposit::SetSwapTypeForBlocker) [M: one draw each]
local function add_deposit(ctx, game, p, t, C)
    p.deposit_types = p.deposit_types or {}
    p.deposit_types[#p.deposit_types + 1] = t
    -- every deposit made, in order (the game's deposit ids count the ones removed later too)
    game.deposit_log = game.deposit_log or {}
    game.deposit_log[#game.deposit_log + 1] = { t.name, p.id }
    if t.category and t.category.blocker then
        C:int()
    end
end

-- a type's value of a planet modifier, as GetAddedDistrictMaxOfType reads it (raw fixed point)
local function modifier_value(ctx, t, name)
    for _, e in ipairs(t.planet_modifier or {}) do
        if e.op and e.key and e.key.text == name then
            return fixed.from(number(ctx, e.value, t.file) or 0)
        end
    end
    return 0
end

-- the district's deposit-made maximum: the sum of the deposits' <district>_max_add, times 1 + the
-- sum of their <district>_max_mult (RandomizeDeposits 0x28d941a-0x28d96f4): its add and mult as
-- raw fixed point, and the total
local function district_total(ctx, p, d)
    local add, mult = 0, ONE
    for _, t in ipairs(p.deposit_types or {}) do
        add = add + modifier_value(ctx, t, d.pool .. "_max_add")
        mult = mult + modifier_value(ctx, t, d.pool .. "_max_mult")
    end
    return add, mult, fixed.trunc(fixed.mul(add, mult) / ONE)
end

-- CDepositType::GetAddedDistrictMaxOfType (Linux 0x249b600): how much the maximum (add_i x
-- mult_i, the totals as integers) moves when a deposit of the type is removed (the drop) or added
-- (the gain)
local function added_district_max(ctx, t, add_i, mult_i, d, removing)
    local a = modifier_value(ctx, t, d.pool .. "_max_add")
    local m = modifier_value(ctx, t, d.pool .. "_max_mult")
    local base = add_i * mult_i
    if removing then
        return base - fixed.trunc(fixed.mul(add_i * ONE - a, mult_i * ONE - m) / ONE)
    end
    return fixed.trunc(fixed.mul(add_i * ONE + a, mult_i * ONE + m) / ONE) - base
end

local function coin(C)
    return C:int() % 2 == 1
end

-- the district caps (RandomizeDeposits 0x28d93b7-0x28d9bd7) [M: transcribed]: each capped
-- district type in turn, its deposit-made maximum brought under max_for_deposits_on_planet by
-- removing use_for_min_max_adjustments deposits, or over min_for_deposits_on_planet by adding
-- them, the one that fits best first (a coin flip on ties)
local function district_caps(ctx, game, p, C)
    for _, d in ipairs(ctx.district_types) do
        local uncapped = d.is_uncapped and eval(ctx, game, p, d.is_uncapped, d.file) == true
        if not uncapped then
            local add, mult, cur = district_total(ctx, p, d)
            local add_i, mult_i = fixed.trunc(add / ONE), fixed.trunc(mult / ONE)
            if os.getenv and tonumber(os.getenv("NEWGAME_DEPOSIT_DEBUG") or "") == p.id and (d.min > 0 or cur > 0) then
                io.stderr:write("district ", d.name, " cur ", cur, " add ", add, " mult ", mult, " min ", d.min, " max ", d.max, string.char(10))
            end
            if d.max < cur then
                local excess = cur - d.max
                while excess > 0 and #p.deposit_types > 0 do
                    local best, bestv
                    for _, t in ipairs(p.deposit_types) do
                        if t.minmax then
                            local amt = added_district_max(ctx, t, add_i, mult_i, d, true)
                            if amt > 0 then
                                local after = cur - amt
                                if after > 0 then
                                    local db = math.abs((bestv or 0) - excess)
                                    local dn = math.abs(after - excess)
                                    local better
                                    if dn < db then
                                        better = true
                                    elseif dn ~= db then
                                        better = false
                                    else
                                        better = coin(C)
                                    end
                                    if best == nil or better or after - excess == 0 then
                                        best, bestv = t, after
                                        if after - excess == 0 then
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if not best then
                        break
                    end
                    for i, t in ipairs(p.deposit_types) do
                        if t == best then
                            table.remove(p.deposit_types, i)
                            break
                        end
                    end
                    excess = excess - bestv
                end
            else
                local need = d.min - cur
                while need > 0 do
                    local best, bestamt = nil, 0
                    for _, t in ipairs(ctx.deposit_types) do
                        if t.minmax then
                            local amt = added_district_max(ctx, t, add_i, mult_i, d, false)
                            if amt > 0 and passes(ctx, game, p, t.potential, t.file) then
                                local db = math.abs(bestamt - need)
                                local dn = math.abs(amt - need)
                                local better
                                if dn < db then
                                    better = true
                                elseif dn ~= db then
                                    better = false
                                else
                                    better = coin(C)
                                end
                                if best == nil or better or amt - need == 0 then
                                    best, bestamt = t, amt
                                    if amt - need == 0 then
                                        break
                                    end
                                end
                            end
                        end
                    end
                    if not best then
                        break
                    end
                    add_deposit(ctx, game, p, best, C)
                    need = need - bestamt
                end
            end
        end
    end
end

-- a deposit re-typed in place (CDeposit::RandomizeDepositNonBlockersOnly / BlockersOnly): a draw,
-- _Randomize over the non-blockers (or the blockers) with no null deposit
local function retype(ctx, game, p, i, C, only)
    local r = C:int()
    local t = random_deposit(ctx, game, p, r, true, only)
    if t then
        p.deposit_types[i] = t
        game.deposit_log[#game.deposit_log + 1] = { t.name .. "(retyped)", p.id }
    end
end

-- the blocker counts (RandomizeDeposits 0x28d9bdc-0x28d9fef) [M: transcribed]: under
-- MIN_UNBLOCKED_DEPOSITS non-blockers, the use_for_min_max_adjustments blocker of the lowest
-- drop_weight becomes a non-blocker (from 0; a coin flip on ties), as many times as missing; else
-- under MIN_BLOCKED_DEPOSITS blockers, the non-blocker of the highest becomes a blocker
local function blocker_counts(ctx, game, p, C)
    local D = game.defines or {}
    local blockers, others = 0, 0
    for _, t in ipairs(p.deposit_types) do
        if t.category and t.category.blocker then
            blockers = blockers + 1
        else
            others = others + 1
        end
    end
    local function pick(want_blocker, highest)
        local best, bestw = nil, 0
        for i, t in ipairs(p.deposit_types) do
            local is_blocker = t.category and t.category.blocker or false
            if is_blocker == want_blocker and t.minmax then
                local w = mtth(ctx, game, p, t.drop_weight, t.file, 0)
                local take
                if (highest and w > bestw) or (not highest and w < bestw) then
                    take = true
                elseif w == bestw then
                    take = coin(C) or best == nil
                else
                    take = best == nil
                end
                if take then
                    best, bestw = i, w
                end
            end
        end
        return best
    end
    local missing = (tonumber(D.MIN_UNBLOCKED_DEPOSITS) or 3) - others
    if missing > 0 then
        for _ = 1, missing do
            local i = pick(true, false)
            if not i then break end
            retype(ctx, game, p, i, C, "non_blockers")
        end
        return
    end
    missing = (tonumber(D.MIN_BLOCKED_DEPOSITS) or 1) - blockers
    for _ = 1, missing do
        local i = pick(false, true)
        if not i then break end
        retype(ctx, game, p, i, C, "blockers")
    end
end

-- CColonyCarrier::ClearBlockers (Linux 0x28da140) for a prescripted planet's deposit_blockers =
-- none: each blocker becomes a non-blocker
function planetgen.clear_blockers(ctx, game, p, C)
    for i, t in ipairs(p.deposit_types or {}) do
        if t.category and t.category.blocker then
            retype(ctx, game, p, i, C, "non_blockers")
        end
    end
end

-- CColonyCarrier::RandomizeDeposits (Linux 0x28d8e10): the rolls, the district caps, the blocker
-- counts
function planetgen.randomize_deposits(ctx, game, p, C)
    planetgen.context(ctx)
    p.deposit_types = {}
    local cls = class_of(ctx, p)
    if cls.artificial then
        return
    end
    local cfg = game.inputs.config
    local abundance = cfg.resource_abundance or 2
    local D = game.defines or {}
    local function def(name, dflt)
        return tonumber(D[name]) or dflt
    end
    if abundance <= def("RESOURCE_ABUNDANCE_MIN", 0) then
        return
    end
    local size = fixed.from(p.size or 0)
    local fixed_n, random_n
    if cls.colonizable then
        fixed_n = def("COLONY_DEPOSITS_FIXED_BASE", 5) + fixed.trunc(fixed.mul(size, fixed.from(def("COLONY_DEPOSITS_FIXED_FROM_SIZE", 0.2))) / ONE)
        random_n = def("COLONY_DEPOSITS_RANDOM_BASE", 2) + fixed.trunc(fixed.mul(size, fixed.from(def("COLONY_DEPOSITS_RANDOM_FROM_SIZE", 0.2))) / ONE)
    else
        fixed_n = def("NON_COLONY_DEPOSITS_FIXED_BASE", 1) + fixed.trunc(fixed.mul(size, fixed.from(def("NON_COLONY_DEPOSITS_FIXED_FROM_SIZE", 0))) / ONE)
        random_n = def("NON_COLONY_DEPOSITS_RANDOM_BASE", 0) + fixed.trunc(fixed.mul(size, fixed.from(def("NON_COLONY_DEPOSITS_RANDOM_FROM_SIZE", 0))) / ONE)
    end
    local extra = 0
    if random_n > 0 then
        extra = C:int() % (random_n + 1)
    end
    -- no null deposit for a colonizable planet or a star (class flags & 0x480, 0x400 the star:
    -- measured, every star of the reference has one) or at the maximum abundance
    local no_null = cls.colonizable or cls.star or abundance >= def("RESOURCE_ABUNDANCE_MAX", 5)
    for _ = 1, fixed_n + extra do
        local r = C:int()
        local t = random_deposit(ctx, game, p, r, no_null)
        if t then
            add_deposit(ctx, game, p, t, C)
        end
    end
    district_caps(ctx, game, p, C)
    blocker_counts(ctx, game, p, C)
end

return planetgen
