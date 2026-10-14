-- engine/ai/opinion.lua : a country's opinion of another (docs/ai.md section 3, "Opinion and
-- attitudes in Lua"): CCountry::CalcOurOpinionOfOther (GOG 4.5.2 0x704c20) -> CalcOurOpinionOfOtherNoScopeCopy
-- (0x705110), read from the world as it is (the save's own fields). No random draws.
--
--   local opinion = require("engine.ai.opinion")
--   opinion.of(us, other)          -- an integer in [OPINION_MIN, OPINION_MAX]
--   opinion.terms(us, other)       -- the same, with each term (a breakdown, for checks)
--
-- The scope of every opinion modifier is this = us, from = other. In the game's order:
--
--   us == other                                  -> OPINION_MAX
--   our personality's behaviour enigmatic        -> 0
--   our country type custom_opinion              -> trust of our relation to them (truncated)
--   either country invalid or dead, or our type without relations = yes -> 0
--   the relation's timed modifiers               trunc(sum of their values), as an int16
--   the policies' opinion modifiers              opinion_policy_<policy group>, each one there
--                                                (interference, slavery, orbital_bombardment)
--   at war with them                             opinion_in_war
--   opinion_from_personality, the fanatic purifier, zealot, honor-bound, democratic crusader,
--   holy world and encroaching borders modifiers: their opinion value (script), rounded
--   opinion_crime_corp_branch_offices            value x our colonies with their branch office,
--                                                when its trigger holds
--   opinion_relative_power                       (subjects only) per % of relative power above 1:
--                                                not ported (CalcRelativePowerOfSubjects; no subjects)
--   opinion_trust                                x trust (truncated) when > 0
--   opinion_threat                               x threat (rounded) when > 0
--   opinion_guarantees_independence              they guarantee us
--   opinion_closed_borders                       they have borders, closed them to us, playable
--   opinion_rivalry / opinion_declared_rival     we rival them / else they rival us
--   opinion_mutual_threat                        x the shared threat factor (rounded)
--   opinion_ally_of_ally                         a defensive pact partner in common
--   opinion_mutual_rival                         x rivals in common
--   opinion_rivals_with_ally                     x their rivals that are our allies
--   opinion_allied_to_rival                      x our rivals that are their allies
--   opinion_federation, opinion_federation_associate, opinion_defensive_pact,
--   opinion_subject (fellow subjects), opinion_is_subject (they are our overlord)
--   every triggered opinion modifier (common/opinion_modifiers with a trigger, not
--   block_triggered) whose trigger holds: its value, truncated
--   envoys: trunc(envoy_opinion_positive) + trunc(envoy_opinion_negative)
--           + trunc(accumulated_authority_envoy_effect)
--   clamped to [OPINION_MIN, OPINION_MAX]
--
-- "rounded" is CFixedPoint::GetRounded (half away from zero), "truncated" toward zero, both on
-- the game's fixed point (1.0 = 100000).

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local opinion = { stats = { calls = 0, errors = 0 } }

local NO_ID = 4294967295
local FP = 100000

-- ---------------------------------------------------------------------------------------------
-- fixed point

local floor = math.floor

-- a number as the game's CFixedPoint (an integer, 1.0 = 100000)
local function fp(v)
    v = tonumber(v) or 0
    if v >= 0 then
        return floor(v * FP + 0.5)
    end
    return -floor(-v * FP + 0.5)
end
opinion.fp = fp

-- integer division toward zero (the game's x / 100000)
local function trunc(x)
    if x >= 0 then
        return floor(x / FP)
    end
    return -floor(-x / FP)
end

-- CFixedPoint::GetRounded: (x +- 0.5) toward zero
local function rounded(x)
    if x < 0 then
        return trunc(x - 50000)
    end
    return trunc(x + 50000)
end
opinion.rounded = rounded
opinion.trunc = trunc

-- ---------------------------------------------------------------------------------------------
-- defines

local D
local function defines()
    if D == nil then
        local function v(group, key, default)
            local g = defs.get("common/defines", group)
            return g and tonumber(defs.field(g.block, key)) or default
        end
        D = {
            OPINION_MIN = v("NGameplay", "OPINION_MIN", -1500),
            OPINION_MAX = v("NGameplay", "OPINION_MAX", 1500),
            RELEVANT_DISTANCE = v("NGameplay", "RELEVANT_DISTANCE", 400),
            START_YEAR = v("NGameplay", "START_YEAR", 2200),
            THREAT_SHARED_THREAT_REDUCTION = fp(v("NAI", "THREAT_SHARED_THREAT_REDUCTION", 4)),
            SHARED_THREAT_MULT = fp(v("NAI", "SHARED_THREAT_MULT", 0.5)),
            SHARED_THREAT_MAX = fp(v("NAI", "SHARED_THREAT_MAX", 200)),
            RELATIVE_POWER_FLEET_MULT = v("NGameplay", "RELATIVE_POWER_FLEET_MULT", 2),
            RELATIVE_POWER_ECONOMY_MULT = v("NGameplay", "RELATIVE_POWER_ECONOMY_MULT", 3),
            RELATIVE_POWER_TECH_MULT = v("NGameplay", "RELATIVE_POWER_TECH_MULT", 1),
        }
    end
    return D
end
opinion.defines = defines

-- ---------------------------------------------------------------------------------------------
-- countries

local function country(id)
    return id and world.object("country", id)
end

local function id_field(obj, key)
    local v = tonumber(world.field(obj, key))
    if v == nil or v == NO_ID then
        return nil
    end
    return v
end
opinion.id_field = id_field

-- the country type's flags (ECountryTypeFlags, from common/country_types: a key = yes)
local type_cache = {}
local function type_flag(id, key)
    local ty = world.field(country(id), "type")
    local k = tostring(ty) .. "/" .. key
    local v = type_cache[k]
    if v == nil then
        local d = ty and defs.get("common/country_types", ty)
        v = d ~= nil and defs.field(d.block, key) == "yes"
        type_cache[k] = v
    end
    return v
end
opinion.type_flag = type_flag

-- the personality's behaviour (SPersonalityBehaviour, `behaviour = { conqueror = yes ... }`)
local behaviour_cache = {}
local function behaviour(id, key)
    local p = world.field(country(id), "personality")
    local k = tostring(p) .. "/" .. key
    local v = behaviour_cache[k]
    if v == nil then
        local d = p and defs.get("common/personalities", p)
        local b = d and defs.field(d.block, "behaviour")
        v = type(b) == "table" and defs.field(b, key) == "yes" or false
        behaviour_cache[k] = v
    end
    return v
end
opinion.behaviour = behaviour

function opinion.overlord(id)
    return id_field(country(id), "overlord")
end
function opinion.federation(id)
    return id_field(country(id), "federation")
end

-- a country that is there (the game: valid and alive)
local function alive(id)
    return country(id) ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- relations (the country's relations_manager: relation = { owner country flags ... })

local rel_index = setmetatable({}, { __mode = "k" }) -- relations_manager block -> { n, [other] = rel }
local function relations_of(id)
    local rm = world.field(country(id), "relations_manager")
    if type(rm) ~= "table" then
        return nil, {}
    end
    local key, n = world.key(rm), world.count(rm)
    local idx = rel_index[key]
    if idx == nil or idx.n ~= n then
        idx = { n = n, list = {}, by = {} }
        for _, r in ipairs(world.fields(rm, "relation")) do
            if type(r) == "table" then
                local c = tonumber(world.field(r, "country"))
                if c then
                    idx.list[#idx.list + 1] = r
                    idx.by[c] = r
                end
            end
        end
        rel_index[key] = idx
    end
    return idx.by, idx.list
end
opinion.relations_of = relations_of

-- the relation of a to b (a block), or nil
local function relation(a, b)
    local by = relations_of(a)
    return by and by[b]
end
opinion.relation = relation

-- a relation flag (ERelationFlags, saved as `key = yes`)
local function rflag(rel, key)
    return rel ~= nil and world.field(rel, key) == "yes"
end
opinion.rflag = rflag

local function rnum(rel, key, default)
    local v = rel and tonumber(world.field(rel, key))
    return v or default or 0
end

-- the diplomacy module's lists (`modules = { standard_diplomacy_module = { rivals = { } } }`)
local function diplomacy(id)
    return world.path(country(id), "modules", "standard_diplomacy_module")
end
local function rivals(id)
    local m = diplomacy(id)
    local out = {}
    for _, v in ipairs(world.list(type(m) == "table" and world.field(m, "rivals") or nil)) do
        out[#out + 1] = tonumber(v)
    end
    return out
end
opinion.rivals = rivals

local function contains(list, x)
    for _, v in ipairs(list) do
        if v == x then
            return true
        end
    end
    return false
end

-- CCountry::IsRivaling(a, b): b among a's rivals; IsRivaled(a, b): a among b's
local function is_rivaling(a, b)
    return contains(rivals(a), b)
end
local function is_rivaled(a, b)
    return contains(rivals(b), a)
end
opinion.is_rivaling, opinion.is_rivaled = is_rivaling, is_rivaled

-- CCountry::GetNumSharedRivals(a, b): a's rivals that b rivals too
local function num_shared_rivals(a, b)
    local rb, n = rivals(b), 0
    for _, r in ipairs(rivals(a)) do
        if contains(rb, r) then
            n = n + 1
        end
    end
    return n
end
-- CCountry::GetNumAlliedRivals(a, b): a's rivals whose relation to b has a defensive pact or an
-- alliance (flags 32 | 64)
local function num_allied_rivals(a, b)
    local n = 0
    for _, r in ipairs(rivals(a)) do
        local rel = relation(r, b)
        if rflag(rel, "defensive_pact") or rflag(rel, "alliance") then
            n = n + 1
        end
    end
    return n
end
opinion.num_shared_rivals, opinion.num_allied_rivals = num_shared_rivals, num_allied_rivals

-- CDiplomacyCountryModule::GetNumSharedDefensivePacts(us, other): third countries both have a
-- defensive pact with
local function num_shared_defensive_pacts(us, other)
    local n = 0
    for _, r in ipairs(select(2, relations_of(other))) do
        local c = tonumber(world.field(r, "country"))
        if c ~= other and rflag(r, "defensive_pact") and rflag(relation(us, c), "defensive_pact") then
            n = n + 1
        end
    end
    return n
end

-- CCountry::HasAssociateStatusWith(a, b)
local function associate(a, b)
    local fa = id_field(country(a), "associated_federation")
    if fa and fa == opinion.federation(b) then
        return true
    end
    local f = opinion.federation(a)
    return f ~= nil and f == id_field(country(b), "associated_federation")
end
opinion.associate = associate

-- CCountry::IsAtWarWith: both in one war, on opposite sides (the `war` store)
local function war_side(w, id)
    for _, side in ipairs({ "attackers", "defenders" }) do
        for _, p in ipairs(world.blocks(world.field(w, side))) do
            if tonumber(world.field(p, "country")) == id then
                return side
            end
        end
    end
    return nil
end
local function at_war(a, b)
    for _, wid in ipairs(world.all("war")) do
        local w = world.object("war", wid)
        local sa = w and war_side(w, a)
        if sa then
            local sb = war_side(w, b)
            if sb and sb ~= sa then
                return true
            end
        end
    end
    return false
end
opinion.at_war = at_war

-- CDiplomacyCountryModule::GetSharedThreatFactor(us, other): sum over our threats T of the
-- larger of the two relations' threat to T, x SHARED_THREAT_MULT, at most SHARED_THREAT_MAX
local function shared_threat_factor(us, other)
    local d = defines()
    local m = diplomacy(us)
    local sum = 0
    for _, t in ipairs(world.list(type(m) == "table" and world.field(m, "threats") or nil)) do
        t = tonumber(t)
        local a, b = fp(rnum(relation(other, t), "threat")), fp(rnum(relation(us, t), "threat"))
        sum = sum + math.max(a, b)
    end
    local v = trunc(sum * d.SHARED_THREAT_MULT)
    if v > d.SHARED_THREAT_MAX then
        v = d.SHARED_THREAT_MAX
    end
    -- CCountry::GetSharedThreatFactor: less our threat of them x THREAT_SHARED_THREAT_REDUCTION
    local x = v - trunc(fp(rnum(relation(us, other), "threat")) * d.THREAT_SHARED_THREAT_REDUCTION)
    return x < 0 and 0 or x
end
opinion.shared_threat_factor = shared_threat_factor

-- a game rule (common/game_rules) for a country
local function game_rule(name, id)
    local d = defs.get("common/game_rules", name)
    if not d then
        return true
    end
    local ok, holds = pcall(eval.trigger, d.block, eval.new_ctx(eval.S("country", id), nil, nil, d.file))
    return ok and holds or false
end
opinion.game_rule = game_rule

-- CCountry::CalcRelativePower(a, b) (0x727480): fleet, economy and technology power of a over b
-- (each + 1, fp15), weighted by RELATIVE_POWER_*_MULT; a CFixedPoint
function opinion.relative_power(a, b)
    local d = defines()
    local ca, cb = country(a), country(b)
    local function p(c, key)
        return floor((tonumber(world.field(c, key)) or 0) * 32768 + 0.5) + 32768
    end
    local function div(x, y)
        -- fp15 (x << 15) / y, toward zero
        local q = x * 32768 / y
        return q >= 0 and floor(q) or -floor(-q)
    end
    local F, E, T = floor(d.RELATIVE_POWER_FLEET_MULT * 32768 + 0.5), floor(d.RELATIVE_POWER_ECONOMY_MULT * 32768 + 0.5),
        floor(d.RELATIVE_POWER_TECH_MULT * 32768 + 0.5)
    local total = math.max(F + E + T, 32768)
    local rf = div(p(ca, "military_power"), p(cb, "military_power"))
    local re = div(p(ca, "economy_power"), p(cb, "economy_power"))
    local rt = div(p(ca, "tech_power"), p(cb, "tech_power"))
    local s = floor(rt * T / 32768) + floor(re * E / 32768) + floor(rf * F / 32768)
    local r = div(s, total)
    return floor(r / 32768 * FP + 0.5)
end

-- ---------------------------------------------------------------------------------------------
-- opinion modifiers (common/opinion_modifiers)

local function modifier_def(key)
    return defs.get("common/opinion_modifiers", key)
end
opinion.modifier_def = modifier_def

-- the triggered modifiers (COpinionModifierDatabase::_TriggeredModifiers): a trigger and not
-- block_triggered
local triggered
local function triggered_modifiers()
    if triggered == nil then
        triggered = {}
        local all = {}
        for name, d in pairs(defs.folder("common/opinion_modifiers")) do
            all[#all + 1] = { name = name, def = d }
        end
        table.sort(all, function(a, b)
            if a.def.file ~= b.def.file then return a.def.file < b.def.file end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
        for _, m in ipairs(all) do
            local t = defs.field(m.def.block, "trigger")
            if type(t) == "table" and defs.field(m.def.block, "block_triggered") ~= "yes" then
                triggered[#triggered + 1] = m
            end
        end
    end
    return triggered
end
opinion.triggered_modifiers = triggered_modifiers

-- the policy groups' opinion modifiers (`opinion_policy_<policy group>`), in definition order
local policy_mods
function opinion.policy_modifiers()
    if policy_mods == nil then
        policy_mods = {}
        local groups = {}
        for name, d in pairs(defs.folder("common/policies")) do
            groups[#groups + 1] = { name = name, def = d }
        end
        table.sort(groups, function(a, b)
            if a.def.file ~= b.def.file then return a.def.file < b.def.file end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
        for _, g in ipairs(groups) do
            local key = "opinion_policy_" .. g.name
            local d = modifier_def(key)
            if d then
                policy_mods[#policy_mods + 1] = { name = key, def = d }
            end
        end
    end
    return policy_mods
end

-- COpinionModifier::GetValueNoScopeCopy: the `opinion` value (CMeanTimeToHappen::GetRawFactor:
-- base, then each modifier's factor/add whose triggers hold), as CFixedPoint
local function value_of(def, ctx)
    local o = defs.field(def.block, "opinion")
    if o == nil then
        return 0
    end
    if type(o) ~= "table" then
        return fp(o)
    end
    local ok, v = pcall(eval.weight, o, ctx, 0)
    if not ok then
        opinion.stats.errors = opinion.stats.errors + 1
        return 0
    end
    return fp(v)
end

-- COpinionModifier::CheckTrigger
local function check_trigger(def, ctx)
    local t = defs.field(def.block, "trigger")
    if type(t) ~= "table" then
        return true
    end
    local ok, holds = pcall(eval.trigger, t, ctx)
    if not ok then
        opinion.stats.errors = opinion.stats.errors + 1
        return false
    end
    return holds
end

-- the value of a hardcoded modifier, or nil when the database has no such modifier
local function hard(key, ctx)
    local d = modifier_def(key)
    if not d then
        return nil
    end
    return value_of(d, ctx)
end

-- ---------------------------------------------------------------------------------------------
-- CCountry::CalcOurOpinionOfOtherNoScopeCopy

local function compute(us, other, terms)
    local d = defines()
    local function term(name, v)
        if terms and v ~= 0 then
            terms[#terms + 1] = { name, v }
        end
        return v
    end
    if us == other then
        return d.OPINION_MAX
    end
    if behaviour(us, "enigmatic") then
        return 0
    end
    if type_flag(us, "custom_opinion") then
        return term("custom_opinion_trust", trunc(fp(rnum(relation(us, other), "trust"))))
    end
    if not alive(us) or not alive(other) or not type_flag(us, "relations") then
        return 0
    end
    local rel = relation(us, other)
    local total = 0
    local function add(name, v)
        total = total + term(name, v)
    end
    local ctx_of = {}
    local function ctx(file)
        local c = ctx_of[file or ""]
        if c == nil then
            c = eval.new_ctx(eval.S("country", us), eval.S("country", other), nil, file)
            ctx_of[file or ""] = c
        end
        return c
    end
    local function mctx(key)
        local m = modifier_def(key)
        return m and ctx(m.file)
    end

    -- the timed modifiers: _CachedSum, truncated, as an int16
    if rel then
        local sum = 0
        for _, m in ipairs(world.fields(rel, "modifier")) do
            if type(m) == "table" then
                sum = sum + fp(world.field(m, "value"))
            end
        end
        local t = trunc(sum) % 65536
        if t >= 32768 then
            t = t - 65536
        end
        add("timed", t)
    end

    -- the policies' opinion modifiers: each policy group of common/policies whose
    -- `opinion_policy_<group>` exists (CPolicyGroup::PostReadInit, +0x2f8), whatever the
    -- countries' policies (the modifier's own triggers read them), rounded
    for _, m in ipairs(opinion.policy_modifiers()) do
        add(m.name, rounded(value_of(m.def, ctx(m.def.file))))
    end

    if at_war(us, other) then
        add("opinion_in_war", rounded(hard("opinion_in_war", mctx("opinion_in_war")) or 0))
    end
    add("opinion_from_personality", rounded(hard("opinion_from_personality", mctx("opinion_from_personality")) or 0))

    -- the criminal syndicate's branch offices on our colonies
    local cc = modifier_def("opinion_crime_corp_branch_offices")
    if cc and check_trigger(cc, ctx(cc.file)) then
        -- (our _OwnedColonies, `owned_planets` in the save: colony ids; CColony::
        -- GetBranchOfficeOwner, the colony's `branch_office_owner`)
        local n = 0
        for _, col in ipairs(world.list(world.field(country(us), "owned_planets"))) do
            local c = world.object("colony", tonumber(col))
            if c and id_field(c, "branch_office_owner") == other then
                n = n + 1
            end
        end
        if n > 0 then
            add("opinion_crime_corp_branch_offices", rounded(value_of(cc, ctx(cc.file))) * n)
        end
    end

    for _, key in ipairs({ "opinion_fanatic_purifiers", "opinion_both_fanatic_purifiers",
        "opinion_fanatic_purifiers_vs_xeno", "opinion_zealots_vs_materialists", "opinion_hw_vs_pacifist",
        "opinion_dc_vs_democratic", "opinion_dc_vs_oligarchic", "opinion_dc_vs_autocracy",
        "opinion_desecrated_holy_world", "opinion_encroaching_borders" }) do
        local v = hard(key, mctx(key))
        if v then
            add(key, rounded(v))
        end
    end

    -- a subject's opinion of its overlord's relative power (CalcRelativePowerOfSubjects: not
    -- ported; no subjects in the 2210 saves)
    if opinion.overlord(us) == other then
        opinion.stats.relative_power_of_subjects = (opinion.stats.relative_power_of_subjects or 0) + 1
    end

    -- trust and threat
    local tr = trunc(fp(rnum(rel, "trust")))
    if tr > 0 then
        add("opinion_trust", rounded(hard("opinion_trust", mctx("opinion_trust")) or 0) * tr)
    end
    local th = rounded(fp(rnum(rel, "threat")))
    if th > 0 then
        add("opinion_threat", rounded(hard("opinion_threat", mctx("opinion_threat")) or 0) * th)
    end

    -- they guarantee our independence
    if rflag(relation(other, us), "guarantee") then
        add("opinion_guarantees_independence", rounded(hard("opinion_guarantees_independence",
            mctx("opinion_guarantees_independence")) or 0))
    end
    -- they closed their borders to us
    if game_rule("has_borders", other) and rflag(relation(other, us), "closed_borders")
        and type_flag(other, "playable") then
        add("opinion_closed_borders", rounded(hard("opinion_closed_borders", mctx("opinion_closed_borders")) or 0))
    end
    -- rivalry
    if rflag(rel, "is_rival") then
        add("opinion_rivalry", rounded(hard("opinion_rivalry", mctx("opinion_rivalry")) or 0))
    elseif is_rivaled(us, other) then
        add("opinion_declared_rival", rounded(hard("opinion_declared_rival", mctx("opinion_declared_rival")) or 0))
    end
    local st = rounded(shared_threat_factor(us, other))
    if st > 0 then
        add("opinion_mutual_threat", rounded(hard("opinion_mutual_threat", mctx("opinion_mutual_threat")) or 0) * st)
    end
    if num_shared_defensive_pacts(us, other) > 0 then
        add("opinion_ally_of_ally", rounded(hard("opinion_ally_of_ally", mctx("opinion_ally_of_ally")) or 0))
    end
    local n = num_shared_rivals(us, other)
    if n > 0 then
        add("opinion_mutual_rival", rounded(hard("opinion_mutual_rival", mctx("opinion_mutual_rival")) or 0) * n)
    end
    n = num_allied_rivals(other, us)
    if n > 0 then
        add("opinion_rivals_with_ally", rounded(hard("opinion_rivals_with_ally", mctx("opinion_rivals_with_ally")) or 0) * n)
    end
    n = num_allied_rivals(us, other)
    if n > 0 then
        add("opinion_allied_to_rival", rounded(hard("opinion_allied_to_rival", mctx("opinion_allied_to_rival")) or 0) * n)
    end

    -- the same federation, associates, defensive pact
    local fed = opinion.federation(us)
    if fed and fed == opinion.federation(other) then
        add("opinion_federation", rounded(hard("opinion_federation", mctx("opinion_federation")) or 0))
    end
    if associate(us, other) then
        add("opinion_federation_associate", rounded(hard("opinion_federation_associate",
            mctx("opinion_federation_associate")) or 0))
    end
    if rflag(rel, "defensive_pact") then
        add("opinion_defensive_pact", rounded(hard("opinion_defensive_pact", mctx("opinion_defensive_pact")) or 0))
    end
    -- fellow subjects of one overlord; our overlord
    local ov = opinion.overlord(us)
    if ov and alive(ov) and opinion.overlord(other) == ov
        and id_field(country(us), "rebelling_against") ~= ov and id_field(country(other), "rebelling_against") ~= ov then
        add("opinion_subject", trunc(hard("opinion_subject", mctx("opinion_subject")) or 0))
    end
    if ov == other then
        add("opinion_is_subject", trunc(hard("opinion_is_subject", mctx("opinion_is_subject")) or 0))
    end

    -- the triggered modifiers
    for _, m in ipairs(triggered_modifiers()) do
        local c = ctx(m.def.file)
        if check_trigger(m.def, c) then
            add(m.name, trunc(value_of(m.def, c)))
        end
    end

    -- envoys
    add("envoys", trunc(fp(rnum(rel, "envoy_opinion_positive"))) + trunc(fp(rnum(rel, "envoy_opinion_negative")))
        + trunc(fp(rnum(rel, "accumulated_authority_envoy_effect"))))

    if total < d.OPINION_MIN then
        return d.OPINION_MIN
    elseif total > d.OPINION_MAX then
        return d.OPINION_MAX
    end
    return total
end

-- opinion.of(us, other) -> integer: our opinion of them
function opinion.of(us, other)
    opinion.stats.calls = opinion.stats.calls + 1
    return compute(us, other, nil)
end

-- opinion.terms(us, other) -> opinion, { { name, value } ... }
function opinion.terms(us, other)
    local terms = {}
    local v = compute(us, other, terms)
    return v, terms
end

-- the script layer's `opinion = { who = <scope> value > x }` trigger (COpinionTrigger::
-- GetTriggerValue: this scope's opinion of `who`), registered in simscript as TRIG.opinion
function opinion.trigger(e, ctx)
    local sc = ctx.this
    if not sc or sc.kind ~= "country" or e.value.text ~= nil then
        return false
    end
    local who, op, want
    for _, x in ipairs(e.value) do
        if x.op and x.key then
            local k = x.key.text:lower()
            if k == "who" then
                local found, s2 = eval.resolve(x.value.text, ctx, x)
                who = found and s2 or nil
            elseif k == "value" then
                op, want = x.op, eval.value(x.value, ctx, x)
            end
        end
    end
    if not who or who.kind ~= "country" or not want then
        return false
    end
    return eval.compare(opinion.of(sc.id, who.id), op, want)
end

return opinion
