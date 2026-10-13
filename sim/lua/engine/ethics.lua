-- engine/ethics.lua : the pop groups' ethics (attraction, the drift of `ethos.pops`) and the
-- faction-change remnant (`fractions`), the way the game updates them each day (GOG 4.5.2,
-- docs/ethics.md):
--
-- CCountry::DailyUpdateOnlyChangeSafePrivate (0x6efbf0), the daily `countries_parallel` phase,
-- every 30 days per country ((id + day) % 30 == 0):
--   UpdateCountryEthicsSafePrivate (0x756ba0)  -> the country's `ethics_attraction` (one per ethic:
--                                                 CEthic::CalcCountryAttraction, `country_attraction`)
--
-- CPopGroup::DailyUpdateOnlyChangeSafePrivate (0x676d10), the daily `pop_groups` phase, per pop
-- group, with the day's pool of 1,000 draws:
--   EthicChangeSafePrivate (0x677d00)          -> every POP_ETHOS_DIVERGENCE_INTERVAL days a 5% roll
--                                                 from the noise stream of pool[(id + 1160) % 1000];
--                                                 on success the attraction (FillEthicsAttraction),
--                                                 the target ethos (CPopGroupEthos::RandomizeEthics)
--                                                 and the number of pops that move (a second draw)
--   CheckPopFactionChange (0x675d80)           -> on days without an ethic change: every 30 days per
--                                                 colony (or the day after one) the faction change
--                                                 (CalculateFactionChange 0x674cb0) and its remnant
-- CPopGroup::DailyUpdateSerial (0x677800):
--   the attraction written, the ethos moved toward the target (Resize, AddStat, CalcPopsDiff),
--   OnEthicsDivergence (on_daily_pop_ethics_divergence: empty in vanilla, two global draws, not
--   made: the phase forbids draws).
--
-- Numbers are the game's fixed point (CFixedPoint, int64, 1.0 = 100000) in LuaJIT int64, so the
-- truncations are the game's.
--
--   local ethics = require("engine.ethics")
--   ethics.countries_daily(host, date)        -- the countries' attraction cache (countries_parallel)
--   ethics.pop_groups_daily(host, date)       -- the pop groups' ethics and factions (pop_groups)
--   ethics.attraction(gid[, cached])          -- { [i] = fixed }, total: FillEthicsAttraction
--   ethics.country_attraction(cid)            -- { [i] = fixed }: UpdateCountryEthicsSafePrivate
--   ethics.check()                            -- the save's attraction recomputed, counted
--   ethics.report()

local ffi = require("ffi")
local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local ethics = {
    stats = {
        days = 0, country_updates = 0, countries_changed = 0,
        groups = 0, interval_days = 0, rolls = 0, divergences = 0, pops_changed = 0, pops_moved = 0,
        randomized = 0, cleared = 0, randomize_failed = 0, attraction_written = 0,
        faction_updates = 0, faction_forced = 0, faction_skipped_ethic_change = 0, faction_not_modelled = 0,
        draws_not_made = 0, script_errors = 0, no_pool = 0,
    },
    errors = {},            -- what -> the last error
    events = {},            -- { date, group, n, size } of the ethic changes (the first 200)
    force_faction = {},     -- gid -> true: EPopGroupFlags 2 (a faction evaluation forced the next day)
}

-- ---------------------------------------------------------------------------------------------
-- fixed point (CFixedPoint): int64, 1.0 = 100000; * and / truncate toward zero as the game's do

local I64 = ffi.typeof("int64_t")
local ONE = 100000
local ZERO = I64(0)
local BIG = I64(4294967295)   -- what the game's division by zero gives

local function fmul(a, b) return I64(a) * b / ONE end
local function fdiv(a, b)
    if b == 0 then return BIG end
    return I64(a) * ONE / b
end
local function num(a) return tonumber(a) / ONE end
local function fx(v)          -- a script value (a Lua number) as the game holds it
    if v == nil then return ZERO end
    return I64(math.floor(v * ONE + 0.5))
end
-- the integer nearest to a fixed amount, halves away from zero (the game's `x +- 0.5`, truncated)
local function round_int(x)
    if x < 0 then return tonumber((x - 50000) / ONE) end
    return tonumber((x + 50000) / ONE)
end

-- a decimal of the script files or the save as fixed (5 decimals, the rest cut)
local function fixed_text(s, default)
    s = s and tostring(s)
    if not s or not s:match("^%s*-?%d*%.?%d*%s*$") or s:match("^%s*-?%s*$") then
        return I64(default or 0)
    end
    local neg, ip, fp = s:match("^%s*(-?)(%d*)%.?(%d*)")
    local v = I64(tonumber(ip ~= "" and ip or "0")) * ONE + I64(tonumber(((fp or "") .. "00000"):sub(1, 5)))
    return neg == "-" and -v or v
end
ethics.fixed = { fmul = fmul, fdiv = fdiv, num = num, fixed_text = fixed_text, ONE = ONE }

-- ---------------------------------------------------------------------------------------------
-- defines (common/defines, NGameplay)

local D
local function defines()
    if D == nil then
        local g = defs.get("common/defines", "NGameplay")
        local function f(key, default) return fixed_text(g and defs.field(g.block, key) or default) end
        local function i(key, default) return tonumber(g and defs.field(g.block, key)) or default end
        D = {
            INTERVAL = i("POP_ETHOS_DIVERGENCE_INTERVAL", 18),
            RATE_MULT = f("POP_ETHOS_DIVERGENCE_RATE_MULT", "0.05"),
            SIZE_CHANGE_MIN = f("POP_ETHOS_DIVERGENCE_SIZE_CHANGE_MIN", "0.05"),
            SIZE_CHANGE_MAX = f("POP_ETHOS_DIVERGENCE_SIZE_CHANGE_MAX", "0.1"),
            SHIFT_SPEED_DIVIDER = f("POP_ETHOS_DIVERGENCE_SIZE_SHIFT_SPEED_DIVIDER", "1"),
            MIN_ATTRACTION = f("POP_ETHOS_MIN_ATTRACTION", "1.1"),
            FACTION_CHANCE = f("POP_CHANGE_FACTION_CHANCE", "0.002"),
            FACTION_ETHIC_FACTOR = f("POP_FACTION_ETHIC_ATTRACTION_FACTOR", "0.3"),
        }
    end
    return D
end
ethics.defines = defines

-- ---------------------------------------------------------------------------------------------
-- the ethics (CEthicDatabase): common/ethics in the order read, a pop group's and a country's
-- arrays are indexed by it (CEthic +8)

local DB
local function db()
    if DB == nil then
        DB = { by_name = {} }
        local list = {}
        for name, d in pairs(defs.folder("common/ethics")) do
            if type(d) == "table" and d.block then
                list[#list + 1] = { name = name, def = d }
            end
        end
        table.sort(list, function(a, b)
            if a.def.file ~= b.def.file then return tostring(a.def.file) < tostring(b.def.file) end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
        for i, x in ipairs(list) do
            local b = x.def.block
            local e = {
                name = x.name, index = i - 1, block = b, file = x.def.file,
                pop_attraction = type(defs.field(b, "pop_attraction")) == "table" and defs.field(b, "pop_attraction") or nil,
                country_attraction = type(defs.field(b, "country_attraction")) == "table" and defs.field(b, "country_attraction") or nil,
                -- CEthic +297: use_for_pops (CPopGroupEthos::IsElementValid 0x4565c0)
                use_for_pops = defs.field(b, "use_for_pops") ~= "no",
                regular = defs.field(b, "regular_variant") or x.name,
                -- CEthic +1600: the pop group's modifier pop_<ethic>_attraction_mult
                mult = "pop_" .. x.name .. "_attraction_mult",
            }
            DB[i] = e
            DB.by_name[x.name] = e
        end
    end
    return DB
end
ethics.db = db

-- ---------------------------------------------------------------------------------------------
-- the world

local NONE = 4294967295
local TWO32 = 4294967296
local function u32(x) return x % TWO32 end

local function int(v) return tonumber(v) or 0 end

local function entry(obj, key)
    for i, e in ipairs(obj) do
        if e.op and e.key and e.key.text == key then
            return e, i
        end
    end
end

-- obj's `key = value` (a token or a block): nil removes it; a new one goes after the closest key
-- before it in `order` that obj has (else before the closest after it, else at the end)
local function put(obj, key, value, order)
    local e, i = entry(obj, key)
    if value == nil then
        if e then world.remove_entry(obj, e) return true end
        return false
    end
    if e then
        if type(value) ~= "table" and e.value.text == value then return false end
        world.remove_entry(obj, e)
        world.insert(obj, i, key, value)
        return true
    end
    local at
    if order then
        local k
        for j, name in ipairs(order) do
            if name == key then k = j break end
        end
        if k then
            for j = k - 1, 1, -1 do
                local _, p = entry(obj, order[j])
                if p then at = p + 1 break end
            end
            if not at then
                for j = k + 1, #order do
                    local _, p = entry(obj, order[j])
                    if p then at = p break end
                end
            end
        end
    end
    world.insert(obj, at or (#obj + 1), key, value)
    return true
end

-- CPopGroup::WriteMembers' order (0x673540)
local PG_ORDER = { "key", "planet", "ethos", "factions", "wanted_factions", "factions_attraction", "size",
    "last_month_growth", "month_start_size", "last_month_growth_details", "current_month_growth_details",
    "fractions", "total_attraction", "ethics_attraction", "habitability", "timed_modifier", "flags",
    "variables", "happiness", "power", "crime", "amenities_usage", "housing_usage" }

local function group_key(g)
    local key = world.field(g, "key")
    if type(key) ~= "table" then return nil, nil end
    return tonumber(world.field(key, "species")), world.field(key, "category")
end

local function owner_of_colony(cid)
    local pid = cid and world.colony_planet[cid]
    local p = pid and world.object("planet", pid)
    local o = p and tonumber(world.field(p, "owner"))
    if o == NONE then o = nil end
    return o, pid
end

local function is_sapient(sid)
    local s = sid and world.object("species_db", sid)
    return s ~= nil and world.field(s, "sapient") ~= "no"
end

-- the save's ethos: { [ethic name] = pops }, and the order written
local function read_ethos(g)
    local ethos = world.field(g, "ethos")
    local out = { n = 0 }
    if type(ethos) ~= "table" then return out end
    local names = world.list(world.field(ethos, "ethics"))
    local counts = world.list(world.field(ethos, "pops"))
    for i, name in ipairs(names) do
        out[#out + 1] = { name = name, pops = int(counts[i]) }
    end
    return out
end

local function index_of(name)
    local e = db().by_name[name]
    return e and e.index or 1e9
end

-- CBasePopGroupStat<CEthic>::Sort (0x45df20): by pops, more first; on a tie the ethic first in the
-- database (CPopGroupEthos::ShouldComeBefore 0x4565f0: CEthic +8)
local function sort_stat(st)
    table.sort(st, function(a, b)
        if a.pops ~= b.pops then return a.pops > b.pops end
        return index_of(a.name) < index_of(b.name)
    end)
end

local function copy_stat(st)
    local out = {}
    for i, x in ipairs(st) do out[i] = { name = x.name, pops = x.pops } end
    return out
end

local function stat_total(st)
    local t = 0
    for _, x in ipairs(st) do t = t + x.pops end
    return t
end

-- ClearNullStats (0x45de60): the entries without pops taken out
local function clear_null(st)
    for i = #st, 1, -1 do
        if st[i].pops <= 0 then table.remove(st, i) end
    end
end

-- CBasePopGroupStat<CEthic>::Resize (0x45d390): each ethic's pops scaled to the new size
-- (trunc(size * trunc(pops / total))), the pops left one by one to the largest remainders (ties:
-- more pops, then the first), sorted, the empty ones dropped. A size of 0 or less empties it.
local function resize(st, size)
    if size <= 0 then
        for i = #st, 1, -1 do st[i] = nil end
        return st
    end
    if #st == 0 then return st end
    local total = stat_total(st)
    if total == 0 or total == size then return st end
    local rem, given = {}, 0
    for i, x in ipairs(st) do
        local share = fdiv(I64(x.pops) * ONE, I64(total) * ONE)
        local v = I64(size) * share
        local p = tonumber(v / ONE)
        x.pops = p
        rem[i] = v - I64(p) * ONE
        given = given + p
    end
    local left = size - given
    while left > 0 do
        local best
        for i = 1, #st do
            if rem[i] >= 0 and (best == nil or rem[i] > rem[best] or (rem[i] == rem[best] and st[i].pops > st[best].pops)) then
                best = i
            end
        end
        if not best then break end
        st[best].pops = st[best].pops + 1
        rem[best] = I64(-ONE)
        left = left - 1
    end
    sort_stat(st)
    clear_null(st)
    return st
end
ethics.resize = resize

-- CBasePopGroupStat<CEthic>::AddStat (0x689590): other's pops added ethic by ethic (a new ethic at
-- the end), then sorted
local function add_stat(st, other)
    for _, y in ipairs(other) do
        local found
        for _, x in ipairs(st) do
            if x.name == y.name then found = x break end
        end
        if found then
            found.pops = found.pops + y.pops
        else
            st[#st + 1] = { name = y.name, pops = y.pops }
        end
    end
    sort_stat(st)
    return st
end

-- CalcPopsDiff (0x687720): the pops that changed ethic: min(the gains, the losses)
local function pops_diff(new, old)
    local o = {}
    for _, x in ipairs(old) do o[x.name] = (o[x.name] or 0) + x.pops end
    local seen, gains, losses = {}, 0, 0
    for _, x in ipairs(new) do
        seen[x.name] = true
        local d = x.pops - (o[x.name] or 0)
        if d > 0 then gains = gains + d else losses = losses - d end
    end
    for name, p in pairs(o) do
        if not seen[name] then losses = losses + p end
    end
    return math.min(gains, losses)
end

local function write_ethos(g, st)
    if #st == 0 then
        return put(g, "ethos", nil)
    end
    local names, counts = {}, {}
    for _, x in ipairs(st) do
        names[#names + 1] = { text = x.name, quoted = true }
        counts[#counts + 1] = { text = tostring(x.pops) }
    end
    local e = {}
    world.append(e, "ethics", names)
    world.append(e, "pops", counts)
    return put(g, "ethos", e, PG_ORDER)
end

-- ---------------------------------------------------------------------------------------------
-- modifiers: the economy's source (the graph built from the world, or the capture)

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    if not (economy and economy.has_modifier_source and economy.has_modifier_source()) then
        return {}
    end
    return economy.modifiers(kind, id) or {}
end

-- ---------------------------------------------------------------------------------------------
-- scripts: weights in fixed point

local function err(what, e)
    ethics.stats.script_errors = ethics.stats.script_errors + 1
    ethics.errors[what] = tostring(e)
end

-- value:count_councilors_with_ethic|ETHIC|x| (common/script_values/01_script_values_paragon.txt):
-- 1 + @council_ethic_attraction (0.1) per ruler or councilor of the country with ethic_x; its
-- complex_trigger_modifier (count_owned_leader, mode = add) is not a value operation of the script
-- layer yet, so it is counted here
local council_cache = {}
local function councilors_with_ethic(country, ethic)
    local k = tostring(country) .. "|" .. ethic
    local v = council_cache[k]
    if v ~= nil then return v end
    local c = world.object("country", country)
    local ruler = c and tonumber(world.field(c, "ruler"))
    local councilor = {}
    for _, p in pairs(world.stores["council_positions"] or {}) do
        local l = tonumber(world.field(p, "leader"))
        if l then councilor[l] = true end
    end
    local n = 0
    for _, t in ipairs(world.list(c and world.field(c, "owned_leaders"))) do
        local id = tonumber(t)
        local l = id and world.object("leader", id)
        if l and (id == ruler or councilor[id]) and world.field(l, "ethic") == ethic then n = n + 1 end
    end
    local per = I64(10000)
    local ok, r = pcall(eval.value, { text = "@council_ethic_attraction" }, eval.new_ctx(eval.S("country", country)))
    if ok and tonumber(r) and tonumber(r) ~= 0 then per = fx(tonumber(r)) end
    v = ONE + I64(n) * per
    council_cache[k] = v
    return v
end

-- a value of a weight: a number of the file, or a script value (value:..., a variable) through the
-- script layer
local function value_of(v, ctx, e)
    if v == nil then return ZERO end
    if v.text and tostring(v.text):match("^%s*-?%d*%.?%d+%s*$") then
        return fixed_text(v.text)
    end
    local ce = v.text and tostring(v.text):match("^value:count_councilors_with_ethic|ETHIC|([%w_]+)|")
    if ce and ctx.this.kind == "country" then
        return councilors_with_ethic(ctx.this.id, "ethic_" .. ce)
    end
    local ok, r = pcall(eval.value, v, ctx, e)
    if not ok then
        err("value " .. tostring(v.text), r)
        return ZERO
    end
    return fx(tonumber(r) or 0)
end
-- ethics.value_number(text, ctx) -> a Lua number: value_of for the script helpers
-- (check_variable_arithmetic's `which`)
function ethics.value_number(text, ctx)
    return num(value_of({ text = text }, ctx))
end

local SKIP = {
    factor = true, add = true, mult = true, multiply = true, weight = true, desc = true, base = true,
    subtract = true, value = true,
}

-- a weight block (`base`, `modifier = { factor|add ... triggers }`) as the game's script weight
-- computes it in CFixedPoint: the base, then each modifier whose triggers hold, in order
local function weight(block, ctx)
    local v = ZERO
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text:lower()
            if k == "base" or k == "value" then
                v = value_of(e.value, ctx, e)
            elseif k == "factor" or k == "mult" or k == "multiply" then
                v = fmul(v, value_of(e.value, ctx, e))
            elseif k == "add" then
                v = v + value_of(e.value, ctx, e)
            elseif k == "modifier" and e.value.text == nil then
                local ok, holds = pcall(eval.trigger, e.value, ctx, SKIP)
                if not ok then
                    err("modifier trigger", holds)
                    holds = false
                end
                if holds then
                    for _, x in ipairs(e.value) do
                        if x.op and x.key then
                            local xk = x.key.text:lower()
                            if xk == "factor" or xk == "mult" or xk == "multiply" then
                                v = fmul(v, value_of(x.value, ctx, x))
                            elseif xk == "add" then
                                v = v + value_of(x.value, ctx, x)
                            elseif xk == "subtract" then
                                v = v - value_of(x.value, ctx, x)
                            end
                        end
                    end
                end
            end
        end
    end
    return v
end
ethics.weight = weight

-- ---------------------------------------------------------------------------------------------
-- attraction

-- CEthic::CalcCountryAttraction (0x45a6a0): max(0, the `country_attraction` weight, This = the country);
-- 0 for an ethic without one (the fanatic ones, gestalt)
local function calc_country_attraction(e, country)
    if not e.country_attraction then return ZERO end
    local ctx = eval.new_ctx(eval.S("country", country), nil, nil, e.file)
    local v = weight(e.country_attraction, ctx)
    if v < 0 then v = ZERO end
    return v
end

-- CCountry::UpdateCountryEthicsSafePrivate (0x756ba0): every ethic's country attraction
function ethics.country_attraction(country)
    local out = {}
    for i, e in ipairs(db()) do
        out[i] = calc_country_attraction(e, country)
    end
    return out
end

-- the country's cached attraction (CCountry::_EthicsAttraction +0x2790, the save's `ethics_attraction`)
local country_cache = {}
local function cached_country(country)
    local c = country_cache[country]
    if c == nil then
        c = {}
        local o = world.object("country", country)
        local b = o and world.field(o, "ethics_attraction")
        if type(b) == "table" then
            for i, t in ipairs(world.list(b)) do c[i] = fixed_text(t) end
        end
        country_cache[country] = c
    end
    return c
end

-- CEthic::CalcPopAttraction (0x459e90): max(0, the `pop_attraction` weight (This = the pop group,
-- From = its planet) * (1 + pop_<ethic>_attraction_mult) (CEthic::ApplyPopAttractionModifier 0x45b1d0,
-- not floored before the max))
local function calc_pop_attraction(e, gid, planet, M)
    if not e.pop_attraction then return ZERO end
    local ctx = eval.new_ctx(eval.S("pop_group", gid), planet and eval.S("planet", planet) or nil, nil, e.file)
    local v = weight(e.pop_attraction, ctx)
    local m = M[e.mult]
    if m ~= nil then
        v = fmul(v, ONE + fx(m))
    end
    if v < 0 then v = ZERO end
    return v
end

-- CPopGroup::FillEthicsAttraction (0x683ed0) with CalcAttractionFor (0x683ce0): per ethic the pop
-- attraction times the country's (its cache when `cached`, else computed); the total of those at
-- least POP_ETHOS_MIN_ATTRACTION, the others set to 0 (when no one reaches it: the total of all,
-- none set to 0)
function ethics.attraction(gid, cached)
    local d = defines()
    local g = world.object("pop_groups", gid)
    if not g then return nil end
    local cid = tonumber(world.field(g, "planet"))
    local owner, planet = owner_of_colony(cid)
    local M = modifiers("pop_group", gid)
    local list, total, all = {}, ZERO, ZERO
    local cc = cached and owner and cached_country(owner) or nil
    for i, e in ipairs(db()) do
        local c
        if cached then
            c = cc and cc[i] or ZERO
        else
            c = owner and calc_country_attraction(e, owner) or ZERO
        end
        local a = ZERO
        if c ~= 0 then
            a = fmul(calc_pop_attraction(e, gid, planet, M), c)
        end
        list[i] = a
        all = all + a
        if a >= d.MIN_ATTRACTION then total = total + a end
    end
    if total <= 0 then
        total = all
    else
        for i = 1, #list do
            if list[i] < d.MIN_ATTRACTION then list[i] = ZERO end
        end
    end
    return list, total
end

local function write_attraction(g, list, total)
    local changed = false
    if total == 0 then
        changed = put(g, "total_attraction", nil) or changed
        changed = put(g, "ethics_attraction", nil) or changed
        return changed
    end
    changed = put(g, "total_attraction", world.number_text(num(total)), PG_ORDER) or changed
    local vals = {}
    for i, a in ipairs(list) do vals[i] = { text = world.number_text(num(a)) } end
    local old = world.field(g, "ethics_attraction")
    local same = type(old) == "table"
    if same then
        local ol = world.list(old)
        if #ol ~= #vals then same = false end
        for i = 1, #vals do
            if not same or ol[i] ~= vals[i].text then same = false break end
        end
    end
    if not same then
        put(g, "ethics_attraction", vals, PG_ORDER)
        changed = true
    end
    return changed
end

-- CPopGroupEthos::RandomizeEthics (0x4562e0, no draws despite the name): each ethic with
-- attraction gets round(size * attraction / total) pops (halves away from zero) when it may be a
-- pop's ethic; none got any: all to the most attractive; then validated and resized to the size
local function target_ethos(list, total, size)
    local st = {}
    if size <= 0 or total <= 0 then return st end
    local best
    for i, e in ipairs(db()) do
        local a = list[i]
        if a > 0 then
            if best == nil or a > list[best] then best = i end
            local n = round_int(I64(size) * fdiv(a, total))
            if n > 0 and e.use_for_pops then
                st[#st + 1] = { name = e.regular, pops = n }
            end
        end
    end
    if #st == 0 and best and db()[best].use_for_pops then
        st[1] = { name = db()[best].regular, pops = size }
    end
    sort_stat(st)
    clear_null(st)
    return resize(st, size)
end
ethics.target_ethos = target_ethos

-- ---------------------------------------------------------------------------------------------
-- the noise stream (CNoiseRandom): the pops module's Squirrel3

local noise32
local function noise(position, seed)
    if not noise32 then noise32 = require("engine.pops").noise32 end
    return noise32(position, seed)
end
-- the stream the game makes from a pool value v: position noise(v, 0x5EA6BA9F), seed 0
local function stream(v)
    return { position = noise(u32(v), 1587985055), seed = 0 }
end
-- CNoiseRandom::GetInt64 (0x1b50900): ((noise(p) & 0x7FFFFFFF) << 32) + noise(p + 1); p += 2
local function get_int64(s)
    local a = noise(s.position, s.seed) % 2147483648
    local b = noise(u32(s.position + 1), s.seed)
    s.position = u32(s.position + 2)
    return I64(a) * TWO32 + b
end
ethics.get_int64, ethics.stream = get_int64, stream

-- ---------------------------------------------------------------------------------------------
-- the rules

local rule_cache = {}

local function rule(name, ctx, default)
    local d = defs.get("common/game_rules", name)
    if not d then return default end
    local ok, holds = pcall(eval.trigger, d.block, ctx)
    if not ok then
        err("rule " .. name, holds)
        return default
    end
    return holds and true or false
end

-- CPopGroup::CalcHasRandomEthics (0x683ba0): the species is sapient (CSpecies +0x53c bit 0), has
-- happiness (CPopGroup::HasHappiness) and the rule pop_group_has_random_ethics (This = the species,
-- Root = the group, From = the owner)
local function has_random_ethics(gid, sid, owner)
    if not is_sapient(sid) then return false end
    local script = require("engine.ethics.script")
    if not script.species_has_happiness(sid, owner) then return false end
    local k = "random|" .. tostring(sid) .. "|" .. tostring(owner)
    local v = rule_cache[k]
    if v == nil then
        local ctx = eval.new_ctx(eval.S("species", sid), owner and eval.S("country", owner) or nil)
        ctx.root = eval.S("pop_group", gid)
        v = rule("pop_group_has_random_ethics", ctx, true)
        rule_cache[k] = v
    end
    return v
end

-- CPopGroup::CanJoinFactions (0x6826a0): a sapient species and the rule pop_group_can_join_factions
-- (This = the group, Root = the owner)
local function can_join_factions(gid, sid, owner)
    if not is_sapient(sid) then return false end
    local ctx = eval.new_ctx(eval.S("pop_group", gid))
    ctx.root = owner and eval.S("country", owner) or eval.NONE
    return rule("pop_group_can_join_factions", ctx, false)
end

-- the owner's country type flag ShufflePopEthos (ECountryTypeFlags bit 20: shuffle_pop_ethos in
-- common/country_types)
local shuffle_cache = {}
local function shuffles_pop_ethos(owner)
    local c = owner and world.object("country", owner)
    local t = c and world.field(c, "type")
    if not t then return false end
    local v = shuffle_cache[t]
    if v == nil then
        local d = defs.get("common/country_types", t)
        v = d ~= nil and defs.field(d.block, "shuffle_pop_ethos") == "yes"
        shuffle_cache[t] = v
    end
    return v
end

-- ---------------------------------------------------------------------------------------------
-- the faction-change remnant (`fractions`): CPopGroup::CalculateFactionChange (0x674cb0)

local function read_map(g, key)
    local b = world.field(g, key)
    local out, order = {}, {}
    if type(b) ~= "table" then return out, order, false end
    for _, e in ipairs(b) do
        if e.op and e.key then
            local k = tonumber(e.key.text)
            if k then
                out[k] = fixed_text(e.value.text)
                order[#order + 1] = k
            end
        end
    end
    return out, order, true
end

-- the factions a pop group is in (CFactionsStat, the save's `factions = { objects pops }`) with the
-- pops in none under -1 (CPopGroup::ValidateFactions 0x6820c0 adds them; the save leaves -1 out)
local function current_factions(g, size)
    local f = world.field(g, "factions")
    local out, order, sum = {}, {}, 0
    if type(f) == "table" then
        local objs = world.list(world.field(f, "objects"))
        local pops = world.list(world.field(f, "pops"))
        for i, o in ipairs(objs) do
            local k, n = tonumber(o), int(pops[i])
            if k and n > 0 then
                out[k] = n
                order[#order + 1] = k
                sum = sum + n
            end
        end
    end
    if size - sum > 0 then
        out[-1] = (out[-1] or 0) + size - sum
        table.insert(order, 1, -1)
    end
    return out, order
end

-- whether the group's wanted factions are known: none while its owner has no pop factions and the
-- group wants none (CPopFactionsCountryModule::FillWantedFactionsFor 0x68e8f0 fills nothing when
-- the country has no faction and no potential one); else not modelled
local factions_of = nil
local function owner_has_factions(owner)
    if factions_of == nil then
        factions_of = {}
        for _, id in ipairs(world.all("pop_factions")) do
            local o = tonumber(world.field(world.object("pop_factions", id), "country"))
            if o then factions_of[o] = true end
        end
    end
    return owner ~= nil and factions_of[owner] == true
end

local function wanted_known_empty(g, owner)
    if owner_has_factions(owner) then return false end
    local w = world.field(g, "wanted_factions")
    if type(w) == "table" and #w > 0 then return false end
    return true
end

-- CalculateFactionChange: the pops that want another faction than theirs (half the total absolute
-- difference D), at most size * POP_CHANGE_FACTION_CHANCE of them move: ratio = min(1, that / D);
-- per faction t = difference * ratio (times POP_FACTION_ETHIC_ATTRACTION_FACTOR * the country's pops
-- attraction of its guiding ethic for a faction with one: not met here, -1 has none), not beyond
-- the difference; the remnant: (t + remnant) less its integer part. Returns the new remnant map.
local function faction_change(size, current, corder, wanted, worder, remnant)
    local d = defines()
    local union, seen = {}, {}
    for _, k in ipairs(corder) do if not seen[k] then seen[k] = true union[#union + 1] = k end end
    for _, k in ipairs(worder) do if not seen[k] then seen[k] = true union[#union + 1] = k end end
    local rem = {}
    for k, v in pairs(remnant) do
        if seen[k] then rem[k] = v end
    end
    local diffs, sum = {}, ZERO
    for i, k in ipairs(union) do
        local df = I64((wanted[k] or 0) - (current[k] or 0)) * ONE
        diffs[i] = df
        sum = sum + (df < 0 and -df or df)
    end
    local D = fmul(sum, 50000)
    if D <= 0 then
        -- nothing to move (returns false): the remnant keeps only the factions of the union, as the
        -- cleanup before the check (0x6752ca) left it
        local kept = {}
        for _, k in ipairs(union) do
            if rem[k] then kept[#kept + 1] = { key = k, value = rem[k] } end
        end
        return kept, true
    end
    local c = d.FACTION_CHANCE
    if c < 0 then c = ZERO elseif c > ONE then c = I64(ONE) end
    local amount = fmul(I64(size) * ONE, c)
    local ratio = fdiv(amount, D)
    if ratio > ONE then ratio = I64(ONE) end
    local out = {}
    for i, k in ipairs(union) do
        local df = diffs[i]
        local t = fmul(fmul(df, ratio), ONE)
        if df > 0 then
            if t >= df then t = df end
        else
            if t < df then t = df end
        end
        local x = t + (rem[k] or ZERO)
        local n = x / ONE
        out[#out + 1] = { key = k, value = x - n * ONE }
    end
    return out
end

local function write_fractions(g, list)
    local b = {}
    for _, x in ipairs(list) do
        world.append(b, tostring(x.key), world.number_text(num(x.value)))
    end
    return put(g, "fractions", #b > 0 and b or nil, PG_ORDER)
end

-- ---------------------------------------------------------------------------------------------
-- the day

local function day_count(date)
    return date.year * 360 + (date.month - 1) * 30 + (date.day - 1)
end

local function daily_pool()
    if RUST.daily_pool then
        return RUST.daily_pool()
    end
    return nil
end

-- CPopGroup::EthicChangeSafePrivate (0x677d00) -> the safe values { flags, list, total, target, n },
-- and whether nothing of the ethics changes today (the faction check runs only then)
local function ethic_change(gid, g, size, sid, owner, day, pool)
    local d = defines()
    local s = ethics.stats
    local safe = {}
    if size <= 0 then return safe, true end
    local ethos = read_ethos(g)
    local empty = #ethos == 0
    if not has_random_ethics(gid, sid, owner) then
        if empty then return safe, true end
        safe.clear = true          -- EPopGroupPrivateFlags 1: the ethos cleared in the serial part
        return safe, false
    end
    if empty then
        safe.randomize = true      -- EPopGroupPrivateFlags 8: CPopGroup::RandomizeEthics
        return safe, false
    end
    if not owner or not shuffles_pop_ethos(owner) then return safe, true end
    -- the interval: POP_ETHOS_DIVERGENCE_INTERVAL / (1 + pop_ethics_shift_speed_mult), rounded
    local M = modifiers("pop_group", gid)
    local m = ZERO
    local interval = d.INTERVAL
    if M.pop_ethics_shift_speed_mult ~= nil then
        m = fx(M.pop_ethics_shift_speed_mult)
        local r = ONE + m
        if r <= 0 then return safe, true end
        if r ~= ONE then
            interval = round_int(fdiv(I64(d.INTERVAL) * ONE, r))
        end
    end
    if interval < 1 then interval = 1 end
    if u32(gid + day) % interval ~= 0 then return safe, true end
    s.interval_days = s.interval_days + 1
    if not pool then
        s.no_pool = s.no_pool + 1
        return safe, true
    end
    local st = stream(pool[u32(gid + 1160) % 1000 + 1])
    local v = get_int64(st)
    s.rolls = s.rolls + 1
    if v % ONE >= d.RATE_MULT then return safe, true end
    -- FillEthicsAttraction (the countries' cache), EPopGroupPrivateFlags 32
    safe.list, safe.total = ethics.attraction(gid, true)
    safe.target = target_ethos(safe.list, safe.total, size)
    if #safe.target == 0 then
        s.randomize_failed = s.randomize_failed + 1   -- "Could not randomize ethics for ..."
        safe.n = 0
        return safe, false
    end
    -- the share of the group that changes: a draw in [lo, hi], lo = SIZE_CHANGE_MIN, hi =
    -- SIZE_CHANGE_MAX + clamp(pop_ethics_shift_speed_mult, 0, 1) / SHIFT_SPEED_DIVIDER
    local lo = d.SIZE_CHANGE_MIN
    if lo < 0 then lo = ZERO end
    local hi0 = d.SIZE_CHANGE_MAX
    if hi0 < lo then hi0 = lo end
    local mc = m
    if mc < 0 then mc = ZERO elseif mc > ONE then mc = I64(ONE) end
    local add = ZERO
    if d.SHIFT_SPEED_DIVIDER > 0 then add = fdiv(mc, d.SHIFT_SPEED_DIVIDER) end
    local sum = hi0 + add
    local hi, low = sum, lo
    if lo > sum then hi = lo end
    if lo > sum then low = sum end
    local v2 = get_int64(st)
    local u = low + v2 % (hi - low + 1)
    local x = fmul(I64(size) * ONE, u)
    local n = tonumber(x / ONE)
    if x % ONE ~= 0 and x > 0 then n = n + 1 end
    safe.n = n
    return safe, false
end

-- CPopGroup::CheckPopFactionChange (0x675d80): the faction change on the colony's day ((colony +
-- day) % 30 == 0) or when one is forced (EPopGroupFlags 2, set by an ethic change), for a group that
-- can join factions; here only where the wanted factions are known to be none (no pop faction and
-- no potential one: the 2210 saves)
local module_cache = {}
local function has_faction_module(owner)
    local v = module_cache[owner]
    if v == nil then
        local c = world.object("country", owner)
        local m = c and world.field(c, "modules")
        v = type(m) == "table" and world.field(m, "standard_pop_factions_module") ~= nil
        module_cache[owner] = v
    end
    return v
end

local function faction_check(gid, g, size, sid, owner, cid, day)
    local s = ethics.stats
    -- the owner's CPopFactionsCountryModule (CCountry +10912, valid: its country type has
    -- standard_pop_factions_module, the save's modules block; only `default` in vanilla)
    if not owner or not has_faction_module(owner) then return end
    if not can_join_factions(gid, sid, owner) then return end
    local forced = ethics.force_faction[gid]
    if not forced and u32(cid + day) % 30 ~= 0 then return end
    ethics.force_faction[gid] = nil
    if forced then s.faction_forced = s.faction_forced + 1 end
    if not wanted_known_empty(g, owner) then
        s.faction_not_modelled = s.faction_not_modelled + 1
        return
    end
    local current, corder = current_factions(g, size)
    local remnant = read_map(g, "fractions")
    local out, unchanged = faction_change(size, current, corder, {}, {}, remnant)
    if not unchanged then s.faction_updates = s.faction_updates + 1 end
    write_fractions(g, out)
end

-- CPopGroup::DailyUpdateSerial (0x677800): the ethics' part
local function ethic_serial(gid, g, size, safe, owner, date)
    local s = ethics.stats
    local d = defines()
    if safe.list then
        if write_attraction(g, safe.list, safe.total) then s.attraction_written = s.attraction_written + 1 end
    end
    local changed
    if safe.target and #safe.target > 0 and (safe.n or 0) > 0 then
        local n = safe.n
        local cur = read_ethos(g)
        local old = copy_stat(cur)
        resize(cur, size - n)
        local tmp = resize(add_stat({}, safe.target), n)
        add_stat(cur, tmp)
        clear_null(cur)
        sort_stat(cur)
        resize(cur, size)
        changed = pops_diff(cur, old)
        write_ethos(g, cur)
        s.divergences = s.divergences + 1
        s.pops_moved = s.pops_moved + n
    elseif safe.randomize then
        -- CPopGroup::RandomizeEthics (0x683fc0): the attraction with the country's computed now,
        -- the ethos set to the target
        local list, total = ethics.attraction(gid, false)
        write_attraction(g, list, total)
        local st = target_ethos(list, total, size)
        if #st == 0 then
            s.randomize_failed = s.randomize_failed + 1
        else
            changed = size
            write_ethos(g, st)
        end
        s.randomized = s.randomized + 1
    elseif safe.clear then
        local cur = read_ethos(g)
        changed = stat_total(cur)
        write_ethos(g, {})
        s.cleared = s.cleared + 1
    end
    if (safe.target and #safe.target > 0 and (safe.n or 0) > 0) or safe.randomize or safe.clear then
        -- EPopGroupFlags 2 (_Properties |= 2): the next day's faction evaluation forced
        ethics.force_faction[gid] = true
    end
    if changed and changed > 0 then
        -- CPopGroup::OnEthicsDivergence (0x684640): two global draws (the event scope) and the
        -- on_action on_daily_pop_ethics_divergence (This = the group, From = the owner,
        -- local_num_pops_changed): empty in vanilla; the draws are not made (the phase forbids them)
        s.pops_changed = s.pops_changed + changed
        s.draws_not_made = s.draws_not_made + 2
        if #ethics.events < 200 then
            ethics.events[#ethics.events + 1] = { date = string.format("%d.%02d.%02d", date.year, date.month, date.day),
                group = gid, n = changed, size = size }
        end
    end
end

local function pop_groups_daily(date)
    local s = ethics.stats
    s.days = s.days + 1
    rule_cache = {}
    council_cache = {}
    require("engine.ethics.script").new_day()
    local day = day_count(date)
    local pool = daily_pool()
    for _, gid in ipairs(world.all("pop_groups")) do
        local g = world.object("pop_groups", gid)
        if g and world.field(g, "killed") ~= "yes" then
            local cid = tonumber(world.field(g, "planet"))
            if cid and world.object("colony", cid) and world.colony_planet[cid] then
                s.groups = s.groups + 1
                local size = int(world.field(g, "size"))
                local sid = group_key(g)
                local owner = owner_of_colony(cid)
                local safe, unchanged = ethic_change(gid, g, size, sid, owner, day, pool)
                if unchanged then
                    faction_check(gid, g, size, sid, owner, cid, day)
                elseif owner and ethics.force_faction[gid] or (owner and u32(cid + day) % 30 == 0) then
                    s.faction_skipped_ethic_change = s.faction_skipped_ethic_change + 1
                end
                ethic_serial(gid, g, size, safe, owner, date)
            end
        end
    end
end

-- the countries' attraction cache: every 30 days per country (UpdateCountryEthicsSafePrivate in
-- CCountry::DailyUpdateOnlyChangeSafePrivate), written to the save's `ethics_attraction` where the
-- country has one
local function countries_daily(date)
    local s = ethics.stats
    council_cache = {}
    require("engine.ethics.script").new_day()
    local day = day_count(date)
    for _, cid in ipairs(world.all("country")) do
        if u32(cid + day) % 30 == 0 then
            local c = world.object("country", cid)
            local b = c and world.field(c, "ethics_attraction")
            if type(b) == "table" then
                local list = ethics.country_attraction(cid)
                local vals, texts = {}, {}
                for i, a in ipairs(list) do
                    texts[i] = world.number_text(num(a))
                    vals[i] = { text = texts[i] }
                end
                local old = world.list(b)
                local same = #old == #texts
                for i = 1, #texts do if old[i] ~= texts[i] then same = false end end
                if not same then
                    put(c, "ethics_attraction", vals)
                    s.countries_changed = s.countries_changed + 1
                end
                country_cache[cid] = list
                s.country_updates = s.country_updates + 1
            end
        end
    end
end

local function with_script(f, ...)
    return require("engine.ethics.script").with(f, ...)
end
ethics.with_script = with_script

-- STELLAR_ETHICS=off leaves the phases to the world as it is (an A/B switch for the checks)
ethics.enabled = os.getenv("STELLAR_ETHICS") ~= "off"

function ethics.countries_daily(host, date)
    if not ethics.enabled then return false end
    return with_script(countries_daily, date)
end

function ethics.pop_groups_daily(host, date)
    if not ethics.enabled then return false end
    return with_script(pop_groups_daily, date)
end

-- ---------------------------------------------------------------------------------------------
-- checks

-- ethics.check() -> text: every living pop group's attraction recomputed from the countries' cache
-- (as the game's daily roll does) against its `ethics_attraction` / `total_attraction`, and every
-- country's attraction against its `ethics_attraction`
function ethics.check(verbose)
    local out = {}
    council_cache = {}
    local function run()
        local n, ok_total, ok_all, ok_entries, n_entries, miss = 0, 0, 0, 0, 0, {}
        for _, gid in ipairs(world.all("pop_groups")) do
            local g = world.object("pop_groups", gid)
            local want = g and world.field(g, "ethics_attraction")
            local cid = g and tonumber(world.field(g, "planet"))
            if type(want) == "table" and world.field(g, "killed") ~= "yes" and cid and world.colony_planet[cid] then
                n = n + 1
                local list, total = ethics.attraction(gid, true)
                local wl = world.list(want)
                local all = true
                for i, a in ipairs(list) do
                    n_entries = n_entries + 1
                    if world.number_text(num(a)) == wl[i] then ok_entries = ok_entries + 1 else all = false end
                end
                local tt = world.number_text(num(total)) == tostring(world.field(g, "total_attraction"))
                if tt then ok_total = ok_total + 1 end
                if all and tt then
                    ok_all = ok_all + 1
                elseif #miss < (verbose and 200 or 20) then
                    local got = {}
                    for i, a in ipairs(list) do got[i] = world.number_text(num(a)) end
                    miss[#miss + 1] = string.format("  group %d: total %s (save %s); %s (save %s)", gid,
                        world.number_text(num(total)), tostring(world.field(g, "total_attraction")),
                        table.concat(got, " "), table.concat(wl, " "))
                end
            end
        end
        out[#out + 1] = string.format("pop groups' attraction (the countries' cache): %d of %d groups exact; total %d of %d; entries %d of %d",
            ok_all, n, ok_total, n, ok_entries, n_entries)
        for _, m in ipairs(miss) do out[#out + 1] = m end
        local cn, cok, cmiss = 0, 0, {}
        for _, id in ipairs(world.all("country")) do
            local c = world.object("country", id)
            local want = c and world.field(c, "ethics_attraction")
            if type(want) == "table" then
                cn = cn + 1
                local list = ethics.country_attraction(id)
                local wl = world.list(want)
                local all = true
                local got = {}
                for i, a in ipairs(list) do
                    got[i] = world.number_text(num(a))
                    if got[i] ~= wl[i] then all = false end
                end
                if all then cok = cok + 1 elseif #cmiss < 20 then
                    cmiss[#cmiss + 1] = string.format("  country %d: %s (save %s)", id, table.concat(got, " "), table.concat(wl, " "))
                end
            end
        end
        out[#out + 1] = string.format("countries' attraction: %d of %d exact", cok, cn)
        for _, m in ipairs(cmiss) do out[#out + 1] = m end
    end
    with_script(run)
    out[#out + 1] = ethics.report()
    return table.concat(out, "\n")
end

function ethics.report()
    local s = ethics.stats
    local errs = {}
    for k, v in pairs(ethics.errors) do errs[#errs + 1] = k .. ": " .. v end
    table.sort(errs)
    local used = {}
    local ok, script = pcall(require, "engine.ethics.script")
    if ok then
        for k, v in pairs(script.used) do used[#used + 1] = k .. " " .. v end
        table.sort(used)
    end
    return string.format("ethics: %d days, %d pop group-days; %d interval days, %d rolls, %d divergences "
        .. "(%d pops moved, %d changed ethic), %d randomized, %d cleared, %d failed; %d attraction writes; "
        .. "%d country updates (%d changed); factions: %d remnant updates (%d forced), %d skipped for an ethic "
        .. "change, %d not modelled (factions or potential ones); %d global draws not made "
        .. "(OnEthicsDivergence); %d days without a pool; %d script errors%s%s",
        s.days, s.groups, s.interval_days, s.rolls, s.divergences, s.pops_moved, s.pops_changed, s.randomized,
        s.cleared, s.randomize_failed, s.attraction_written, s.country_updates, s.countries_changed,
        s.faction_updates, s.faction_forced, s.faction_skipped_ethic_change, s.faction_not_modelled,
        s.draws_not_made, s.no_pool, s.script_errors,
        #errs > 0 and (" (" .. table.concat(errs, "; ") .. ")") or "",
        #used > 0 and ("; triggers added: " .. table.concat(used, ", ")) or "")
end

return ethics
