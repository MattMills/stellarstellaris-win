-- simscript/handlers/diplomacy.lua : war, peace and diplomacy: triggers, values, scope links and
-- iterators about wars, relations, attitudes, pacts, rivals, access and borders, federations, the
-- galactic community, subjects and overlords (docs/script_diplomacy.md has each keyword's class,
-- its semantics in the GOG 4.5.2 build and what is approximated). The world is read through
-- engine.diplomacy, the same functions the AI's opinion and attitudes and the fleets' access use.
--
-- Numeric triggers (`num_rivals > 1`) are also values (`value = trigger:num_rivals`): VALUE[k](ctx)
-- is the trigger's GetTriggerValue, registered in eval.TRIGGER_VALUES when eval has it.

return function(eval)
    local I = eval._internal
    local S, NONE, compare, push, yes = I.S, I.NONE, I.compare, I.push, I.yes
    local flag_name = I.flag_name
    local TRIG, LINKS, LISTS = eval.TRIG, eval.LINKS, eval.LISTS
    local D = require("engine.diplomacy")
    local world = require("engine.world")
    local floor = math.floor

    local VALUE = {}

    -- ------------------------------------------------------------------------------------------
    -- helpers

    local function sync() I.sync() end

    -- the scope's country (only a country scope: CScopeObjectReference::GetCountry gives the null
    -- country for another scope)
    local function this_country(ctx)
        local sc = ctx.this
        if sc and sc.kind == "country" and D.alive(sc.id) then return sc.id end
        return nil
    end
    -- the country a `<trigger> = <target>` names
    local function target_country(e, ctx)
        if not e.value.text then return nil end
        local found, sc = eval.resolve(e.value.text, ctx, e)
        if found and sc and sc.kind == "country" and D.alive(sc.id) then return sc.id end
        return nil
    end
    -- a block parameter's scope (`who = root`)
    local function param_scope(block, key, ctx)
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key and x.value.text then
                local found, sc = eval.resolve(x.value.text, ctx, x)
                if found then return sc end
            end
        end
        return nil
    end
    local function param_text(block, key)
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key then return x.value.text, x end
        end
        return nil
    end
    -- `<trigger> <op> <value>`, or `<trigger> = { value <op> n ... }`
    local function compare_value(v, e, ctx)
        if v == nil then return false end
        if e.value.text then
            return compare(v, e.op, eval.value(e.value, ctx, e))
        end
        local _, x = param_text(e.value, "value")
        if not x then return false end
        return compare(v, x.op, eval.value(x.value, ctx, x))
    end
    local function countries_scopes(ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = S("country", id) end
        return out
    end
    -- a CFixedPoint as the game compares it: the saved number (five decimals)
    local function fixed(v)
        local n = tonumber(v)
        if not n then return 0 end
        return floor(n * 100000 + 0.5) / 100000
    end

    -- a trigger `<k> = <country>` on a country scope: f(us, them) -> bool
    local function pair_trigger(f)
        return function(e, ctx)
            local us = this_country(ctx)
            if not us then return false end
            local them = target_country(e, ctx)
            if not them then return false end
            sync()
            return f(us, them) == true
        end
    end
    -- a yes/no trigger on a country scope: f(us) -> bool. Another scope reads the null country
    -- (f false, so `= no` holds), unless strict (the trigger tests the country first: false)
    local function bool_trigger(f, strict)
        return function(e, ctx)
            local us = this_country(ctx)
            if not us then
                if strict then return false end
                return false == yes(e)
            end
            sync()
            return (f(us) == true) == yes(e)
        end
    end
    -- a numeric trigger: value(ctx) -> number or nil; also a value (trigger:<k>)
    local function num_trigger(k, value)
        VALUE[k] = value
        TRIG[k] = function(e, ctx)
            sync()
            return compare_value(value(ctx), e, ctx)
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- wars

    -- is_at_war = yes/no (CIsAt War::ActualEvaluate 0x1958260): the country's wars (CCountry +0x2bb4)
    TRIG["is_at_war"] = bool_trigger(D.at_war)
    -- is_at_war_with = <c> (CIsAtWarWithTrigger 0x194e280): the relation's wars
    TRIG["is_at_war_with"] = pair_trigger(D.at_war_with)
    -- has_opinion_modifier = { who = <country> modifier = <key> } (a country): its relation with
    -- `who` holds the opinion modifier (the relation's `modifier = { modifier = <key> }`). The
    -- galactic community's galcom.61 removes opinion_fellow_galcom_member with it when a member
    -- leaves, as the game's save shows. (engine/ethics/script.lua installed the same only while the
    -- ethics evaluate.)
    TRIG["has_opinion_modifier"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local sc = param_scope(e.value, "who", ctx)
        local who = sc and sc.kind == "country" and sc.id or nil
        local key = param_text(e.value, "modifier")
        if not who or not key then return false end
        sync()
        local r = D.relation(us, who)
        for _, m in ipairs(r and world.fields(r, "modifier") or {}) do
            if type(m) == "table" and world.field(m, "modifier") == key then return true end
        end
        return false
    end
    -- recently_lost_war = yes/no (CRecentlyLostWarTrigger 0x1958460): months since last_date_war_lost
    -- <= TRUCE_YEARS * 12 (months: year * 12 + day of year / 30)
    local function months(days) return floor(days / 360) * 12 + floor((days % 360) / 30) end
    TRIG["recently_lost_war"] = function(e, ctx)
        local us = this_country(ctx)
        if not us then return false == yes(e) end
        local lost = D.last_war_lost(us) or 0
        local truce_years = 10
        local defs = require("engine.defs")
        local g = defs.get("common/defines", "NGameplay")
        truce_years = g and tonumber(defs.field(g.block, "TRUCE_YEARS")) or truce_years
        return (months(eval.today()) - months(lost) <= truce_years * 12) == yes(e)
    end
    -- years_of_peace <op> n, years_of_peace = { value <op> n delay = d } (CYearsOfPeaceTrigger
    -- 0x19592b0): max(0, year(today) - delay - year(last_date_at_war))
    local function years_of_peace(ctx, delay)
        local us = this_country(ctx)
        if not us then return nil end
        local at = D.last_at_war(us) or 0
        local v = floor(eval.today() / 360) - (delay or 0) - floor(at / 360)
        return v < 0 and 0 or v
    end
    VALUE["years_of_peace"] = function(ctx) return years_of_peace(ctx, 0) end
    TRIG["years_of_peace"] = function(e, ctx)
        local delay = 0
        if not e.value.text then
            local t, x = param_text(e.value, "delay")
            if t then delay = eval.value(x.value, ctx, x) end
        end
        return compare_value(years_of_peace(ctx, delay), e, ctx)
    end

    -- the wars a country is in, as scopes
    LISTS["war"] = function(sc)
        if sc.kind ~= "country" then return {} end
        local out = {}
        for i, w in ipairs(D.wars_of(sc.id)) do out[i] = S("war", w) end
        return out
    end
    LISTS["war_participant"] = function(sc)
        if sc.kind ~= "war" then return {} end
        return countries_scopes(D.war_participants(sc.id))
    end
    LISTS["attacker"] = function(sc)
        if sc.kind ~= "war" then return {} end
        return countries_scopes(D.war_side(sc.id, "attackers"))
    end
    LISTS["defender"] = function(sc)
        if sc.kind ~= "war" then return {} end
        return countries_scopes(D.war_side(sc.id, "defenders"))
    end
    -- is_war_participant = { who = <c> side = attackers / defenders / <country> } (CIsWarParticipantTrigger
    -- 0x1998ef0): in a war scope, who is on the side (no side: in the war; a country: on its side);
    -- in a country scope the country, and the war from `war = <target>`
    TRIG["is_war_participant"] = function(e, ctx)
        if e.value.text then return false end
        local sc = ctx.this
        local war, who
        if sc.kind == "war" then
            war = sc.id
            local w = param_scope(e.value, "who", ctx)
            who = w and w.kind == "country" and w.id
        elseif sc.kind == "country" then
            who = sc.id
            local w = param_scope(e.value, "war", ctx)
            war = w and w.kind == "war" and w.id
        end
        if not war or not who or not D.war_obj(war) or not D.alive(who) then return false end
        sync()
        local side = param_text(e.value, "side")
        local my = D.side_in(war, who)
        if side == "attackers" or side == "defenders" then
            return my == side
        elseif side == nil or side == "none" then
            return my ~= nil
        end
        local s2 = param_scope(e.value, "side", ctx)
        local other = s2 and s2.kind == "country" and s2.id
        if not other then return false end
        local os = D.side_in(war, other)
        return my ~= nil and os ~= nil and my == os
    end
    -- the war's main attacker / defender (scopes.log `attacker`, `defender`): the side's participant
    -- called as `primary`, else its first [I]
    local function main_of(w, side)
        local first
        for _, p in ipairs(world.blocks(world.field(D.war_obj(w), side))) do
            local c = D.ref(world.field(p, "country"))
            if c then
                if world.field(p, "call_type") == "primary" then return c end
                first = first or c
            end
        end
        return first
    end
    LINKS["attacker"] = function(cur)
        if cur.kind ~= "war" then return nil end
        local c = main_of(cur.id, "attackers")
        return c and S("country", c) or nil
    end
    LINKS["defender"] = function(cur)
        if cur.kind ~= "war" then return nil end
        local c = main_of(cur.id, "defenders")
        return c and S("country", c) or nil
    end
    -- using_war_goal = { type = <wg> owner = <c> } (CUsingWarGoalTrigger 0x19c4470): the war goal of
    -- the owner's side (its attackers' `attacker_war_goal`, else `defender_war_goal`) is of the type
    local function war_goal_type(w, side)
        local g = world.field(D.war_obj(w), side .. "_war_goal")
        return type(g) == "table" and world.field(g, "type") or nil
    end
    TRIG["using_war_goal"] = function(e, ctx)
        if e.value.text or ctx.this.kind ~= "war" or not D.war_obj(ctx.this.id) then return false end
        local o = param_scope(e.value, "owner", ctx)
        if not o or o.kind ~= "country" or not D.alive(o.id) then return false end
        local want = param_text(e.value, "type")
        local side = D.side_in(ctx.this.id, o.id) == "attackers" and "attacker" or "defender"
        return want ~= nil and war_goal_type(ctx.this.id, side) == want
    end
    -- is_total_war = yes/no (CIsTotalWarTrigger 0x19c4870): the attackers' war goal type has
    -- `total_war = yes` (common/war_goals) [I: the flag's name, CWarGoalType +0x56c]
    TRIG["is_total_war"] = function(e, ctx)
        if ctx.this.kind ~= "war" then return false end
        local t = war_goal_type(ctx.this.id, "attacker")
        local defs = require("engine.defs")
        local d = t and defs.get("common/war_goals", t)
        return ((d ~= nil and defs.field(d.block, "total_war") == "yes") == yes(e))
    end
    -- attacker_war_exhaustion / defender_war_exhaustion <op> x (CAttackerWarExhaustionTrigger
    -- 0x1958700 / 0x19588c0): the war's attacker_war_exhaustion (CWar +0x118 / +0x120)
    for _, side in ipairs({ "attacker", "defender" }) do
        num_trigger(side .. "_war_exhaustion", function(ctx)
            if ctx.this.kind ~= "war" then return nil end
            return fixed(world.field(D.war_obj(ctx.this.id), side .. "_war_exhaustion"))
        end)
    end

    -- ------------------------------------------------------------------------------------------
    -- relations

    -- relation flags, `<trigger> = <country>`: the scope's relation towards it (CCountry::GetRelationFlag)
    local FLAG_TRIGGERS = {
        has_embassy = "embassy",                    -- CHasEmbassyTrigger 0x19a2ef0, bit 18
        has_defensive_pact = "defensive_pact",      -- CCountry::HasDefensivePactWith 0x7032e0, bit 5
        has_non_aggression_pact = "non_aggression_pledge", -- CHasNonAggressionPactTrigger 0x19a17e0, bit 10
        is_guaranteeing = "guarantee",              -- CCountry::IsGuaranteedBy(target, this) 0x703280, bit 8
        is_forced_friendly = "friendly",            -- CHasForcedRelationTrigger<SHasForcedFriendlyImpl>, bit 2
        is_forced_neutral = "neutral",              -- <SHasForcedNeutralityImpl>, bit 1
    }
    for k, f in pairs(FLAG_TRIGGERS) do
        TRIG[k] = pair_trigger(function(us, them) return D.flag(us, them, f) end)
    end
    -- has_established_contact = <c> (CHasEstablishedContactTrigger 0x19793b0): itself, or bit 16
    TRIG["has_established_contact"] = pair_trigger(function(us, them)
        return us == them or D.flag(us, them, "contact")
    end)
    -- the pacts a federation may grant (CRelation::Has*(true))
    TRIG["has_commercial_pact"] = pair_trigger(D.has_commercial_pact)
    TRIG["has_research_agreement"] = pair_trigger(D.has_research_agreement)
    TRIG["has_migration_access"] = pair_trigger(D.has_migration_pact)
    TRIG["has_diplo_migration_treaty"] = pair_trigger(D.has_migration_pact)
    -- has_rival = <c> (CHasRival 0x19b07f0): CCountry::IsRivaling
    TRIG["has_rival"] = pair_trigger(D.is_rivaling)
    -- has_truce = <c> (CHasTruceTrigger 0x1988a60): CCountry::HasTruceWith
    TRIG["has_truce"] = pair_trigger(D.has_truce)
    -- has_association_status = <c> (CCountry::HasAssociateStatusWith 0x716860)
    TRIG["has_association_status"] = pair_trigger(D.associate)
    -- has_closed_borders = <c> (CHasClosedBordersTrigger 0x19a3e20): bit 15 and
    -- CCountry::CanControlAccessFor(this, target) (0x71c460: not a subject's or the overlord's, not
    -- in one federation, no forced open borders, the target needs border access) [I: the subject
    -- agreements' and the primitive rules are not ported]
    TRIG["has_closed_borders"] = pair_trigger(function(us, them)
        if not D.flag(us, them, "closed_borders") then return false end
        if D.overlord(us) == them or D.overlord(them) == us then return false end
        local f = D.federation(us)
        if f and f == D.federation(them) then return false end
        -- the target needs border access, or its type is playable (CCountryType flag bit 1)
        if not D.property(them, "needs_border_access") and not D.type_key(them, "playable", false) then
            return false
        end
        local forced = D.date_days(world.field(D.relation(us, them), "forced_open_borders"))
        return not (forced and forced >= eval.today())
    end)
    -- is_hostile = <c> (CCountry::IsHostile 0x702100) [I: the relation's hostile flag; the parent
    -- country, forced neutrality and diplomatic-wars rules are not ported]
    TRIG["is_hostile"] = pair_trigger(function(us, them)
        if us == them then return false end
        if D.flag(us, them, "neutral") or D.flag(us, them, "friendly") then return false end
        return D.flag(us, them, "hostile") or D.at_war_with(us, them)
    end)
    -- has_relation_flag = { who = <c> flag = <name> } and reverse_has_relation_flag
    -- (CHasRelationFlagTrigger 0x197d3f0): the relation's `flags = { name = date }` (of this towards
    -- who, or of who towards this)
    local function relation_flag_trigger(reverse)
        return function(e, ctx)
            if e.value.text then return false end
            local us = this_country(ctx)
            local w = param_scope(e.value, "who", ctx)
            local them = w and w.kind == "country" and w.id
            local name = param_text(e.value, "flag")
            if not us or not them or not name then return false end
            sync()
            local rel = reverse and D.relation(them, us) or D.relation(us, them)
            local flags = rel and world.field(rel, "flags")
            if type(flags) ~= "table" then return false end
            -- present: set (a timed flag is removed when it runs out, as engine.scriptstate's)
            return #world.fields(flags, flag_name(name, ctx, e)) > 0
        end
    end
    TRIG["has_relation_flag"] = relation_flag_trigger(false)
    TRIG["reverse_has_relation_flag"] = relation_flag_trigger(true)

    -- num_<pacts> <op> n (CNumDiplomacyRelationsTrigger<CDiplomacyCountryModule::GetNum*>
    -- 0x19c8b30..0x19c8ef0): the diplomacy module's counters (UpdateDiplomaticCache)
    local NUMS = {
        num_defensive_pacts = "defensive_pacts", num_guarantees = "guarantees",
        num_non_aggression_pacts = "naps", num_commercial_pacts = "commercial_pacts",
        num_waystation_pacts = "waystation_pacts", num_research_agreements = "research_agreements",
        num_migration_pacts = "migration_pacts", num_rivals = "rivalries",
        num_closed_borders = "closed_borders", num_truces = "truces",
    }
    for k, field in pairs(NUMS) do
        num_trigger(k, function(ctx)
            local us = this_country(ctx)
            if not us then return 0 end
            return D.counts(us)[field]
        end)
    end

    -- any_rival_country (CRivalCountryListBuilder): the diplomacy module's rivals, in order
    LISTS["rival_country"] = function(sc)
        if sc.kind ~= "country" then return {} end
        local out = {}
        for _, r in ipairs(D.rivals(sc.id)) do
            if D.alive(r) then out[#out + 1] = S("country", r) end
        end
        return out
    end

    -- trust = { who = <c> value <op> n } (CTrustTrigger 0x1960850): the relation's trust, truncated
    TRIG["trust"] = function(e, ctx)
        if e.value.text then return false end
        local us = this_country(ctx)
        local w = param_scope(e.value, "who", ctx)
        if not us or not w or w.kind ~= "country" then return false end
        sync()
        local t = tonumber(world.field(D.relation(us, w.id), "trust")) or 0
        return compare_value(t >= 0 and floor(t) or -floor(-t), e, ctx)
    end
    -- highest_threat <op> x (CHighestThreat 0x19b1f50 -> CDiplomacyCountryModule::GetLargestThreat
    -- 0x6a3940): the largest threat of the relations towards the module's threats, at least 0
    num_trigger("highest_threat", function(ctx)
        local us = this_country(ctx)
        if not us then return nil end
        local best = 0
        for _, t in ipairs(D.threats(us)) do
            local v = fixed(world.field(D.relation(us, t), "threat"))
            if v > best then best = v end
        end
        return best
    end)
    -- their_opinion = { who = <c> value <op> n } (CTheirOpinionTrigger 0x1961900): who's opinion of
    -- this (engine.ai.opinion)
    TRIG["their_opinion"] = function(e, ctx)
        if e.value.text then return false end
        local us = this_country(ctx)
        local w = param_scope(e.value, "who", ctx)
        if not us or not w or w.kind ~= "country" or not D.alive(w.id) then return false end
        sync()
        return compare_value(require("engine.ai.opinion").of(w.id, us), e, ctx)
    end

    -- opinion_level = { who = <c> level <op> terrible/poor/neutral/good/excellent }
    -- (COpinionLevelTrigger 0x1960e90, CalculateOpinion 0x1961450): the two opinions summed (ours of
    -- who and who's of us), > OPINION_EXCELLENT excellent (4), > OPINION_GOOD good (3), <
    -- OPINION_TERRIBLE terrible (0), >= OPINION_POOR neutral (2), else poor (1); compared as levels
    local LEVELS = { terrible = 0, poor = 1, neutral = 2, good = 3, excellent = 4 }
    local function gameplay_define(k, default)
        local defs = require("engine.defs")
        local g = defs.get("common/defines", "NGameplay")
        return g and tonumber(defs.field(g.block, k)) or default
    end
    TRIG["opinion_level"] = function(e, ctx)
        if e.value.text then return false end
        local us = this_country(ctx)
        local w = param_scope(e.value, "who", ctx)
        local name, x = param_text(e.value, "level")
        if not us or not w or w.kind ~= "country" or not D.alive(w.id) or not name then return false end
        sync()
        local op = require("engine.ai.opinion")
        local sum = op.of(us, w.id) + op.of(w.id, us)
        local lv
        if sum > gameplay_define("OPINION_EXCELLENT", 750) then lv = 4
        elseif sum > gameplay_define("OPINION_GOOD", 300) then lv = 3
        elseif sum < gameplay_define("OPINION_TERRIBLE", -750) then lv = 0
        elseif sum >= gameplay_define("OPINION_POOR", -300) then lv = 2
        else lv = 1 end
        return compare(lv, x.op, LEVELS[name] or 5)
    end

    -- has_casus_belli = { target = <c> type = <cb> } (CHasCasusBelliTrigger 0x19b99b0): not itself,
    -- communications with the target, both types with `diplomatic_wars`; then the module's
    -- `casus_belli = { { type owner country } }` towards the target (of the type, when given)
    TRIG["has_casus_belli"] = function(e, ctx)
        if e.value.text then return false end
        local us = this_country(ctx)
        local t = param_scope(e.value, "target", ctx)
        if not us or not t or t.kind ~= "country" or not D.alive(t.id) or t.id == us then return false end
        if not D.flag(us, t.id, "communications") then return false end
        if not D.type_key(us, "diplomatic_wars", false) or not D.type_key(t.id, "diplomatic_wars", false) then
            return false
        end
        local want = param_text(e.value, "type")
        local m = D.diplomacy_module(us)
        for _, cb in ipairs(world.blocks(m and world.field(m, "casus_belli") or nil)) do
            if D.ref(world.field(cb, "country")) == t.id and (want == nil or world.field(cb, "type") == want) then
                return true
            end
        end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- the AI's attitudes (CIsAttitudeTrigger<SIs*Impl>, 0x19e77b0..0x19eb5a0): the target valid,
    -- the scope's country has an AI, CCountryAI::GetAttitude(target) is the database's attitude of
    -- that name (CAIAttitudesDatabase::Init caches them by name)
    local ATTITUDES = {
        is_hostile_to = { "hostile" }, is_friendly_to = { "friendly" }, is_protective_to = { "protective" },
        is_domineering_to = { "domineering" }, is_cordial_to = { "cordial" }, is_threatened_to = { "threatened" },
        is_overlord_to = { "overlord" }, is_loyal_to = { "loyal" }, is_disloyal_to = { "disloyal" },
        is_angry_to = { "angry" }, is_berserker_to = { "berserker" }, is_enigmatic_to = { "enigmatic" },
        is_patronizing_to = { "patronizing" }, is_custodial_to = { "custodial" },
        is_dismissive_to = { "dismissive" }, is_imperious_to = { "imperious" }, is_arrogant_to = { "arrogant" },
        is_belligerent_to = { "belligerent" },
        -- unfriendly: unfriendly or rival; neutral: wary, receptive or neutral
        is_unfriendly_to = { "unfriendly", "rival" }, is_neutral_to = { "wary", "receptive", "neutral" },
    }
    for k, names in pairs(ATTITUDES) do
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        TRIG[k] = pair_trigger(function(us, them)
            if not D.has_ai(us) then return false end
            return set[D.attitude(us, them)] == true
        end)
    end
    -- is_rival = <c> (CIsAttitudeTrigger<SIsRivalImpl> 0x19e8000): an AI, and CCountry::IsRivaling
    TRIG["is_rival"] = pair_trigger(function(us, them)
        return D.has_ai(us) and D.is_rivaling(us, them)
    end)

    -- ------------------------------------------------------------------------------------------
    -- subjects and overlords

    -- has_overlord = <c> (CHasOverlord 0x19b1ae0): this's overlord is the target
    TRIG["has_overlord"] = pair_trigger(function(us, them)
        return D.ref(world.field(D.country(us), "overlord")) == them
    end)
    -- has_subject = <c> (CHasSubject 0x19b1160): the target's overlord is this
    TRIG["has_subject"] = pair_trigger(function(us, them)
        return D.ref(world.field(D.country(them), "overlord")) == us
    end)
    -- has_any_overlord = yes/no (CHasAnyOverlord 0x19b1df0)
    TRIG["has_any_overlord"] = bool_trigger(function(us) return D.overlord(us) ~= nil end, true)
    -- subjects <op> n (CSubjectsTrigger 0x198f520): the count of the subjects array
    num_trigger("subjects", function(ctx)
        local us = this_country(ctx)
        return us and D.num_subjects(us) or 0
    end)

    -- ------------------------------------------------------------------------------------------
    -- federations: the scope's federation (a country's, CScopeObjectReference::GetFederation)

    local function fed_of(ctx)
        local sc = ctx.this
        if sc.kind == "federation" then return D.fed_obj(sc.id) and sc.id or nil end
        if sc.kind == "country" then return D.federation(sc.id) end
        return nil
    end
    -- has_federation = yes/no (CHasFederationTrigger): the country's federation is valid
    TRIG["has_federation"] = function(e, ctx)
        local us = this_country(ctx)
        if not us then return false == yes(e) end
        return (D.federation(us) ~= nil) == yes(e)
    end
    -- has_federation_type = <type> (CHasFederationTypeTrigger 0x1a17fa0): the progression's type
    TRIG["has_federation_type"] = function(e, ctx)
        local f = fed_of(ctx)
        local p = f and D.fed_progression(f)
        return p ~= nil and world.field(p, "federation_type") == e.value.text
    end
    -- federation_level / federation_experience / federation_cohesion (0x1a183e0, 0x1a178d0,
    -- 0x1a17d60): the progression's levels, experience, cohesion
    for k, field in pairs({ federation_level = "levels", federation_experience = "experience",
        federation_cohesion = "cohesion" }) do
        num_trigger(k, function(ctx)
            local f = fed_of(ctx)
            local p = f and D.fed_progression(f)
            if not p then return 0 end
            return fixed(world.field(p, field))
        end)
    end
    -- num_members / num_associates (0x1a18600 / 0x1a18810): the federation's arrays' counts
    num_trigger("num_members", function(ctx)
        local f = fed_of(ctx)
        return f and #D.id_list(world.field(D.fed_obj(f), "members")) or 0
    end)
    num_trigger("num_associates", function(ctx)
        local f = fed_of(ctx)
        return f and #D.associates(f) or 0
    end)
    -- has_federation_perk = <perk> (0x1a181b0): a perk of the progression of that type
    TRIG["has_federation_perk"] = function(e, ctx)
        local f = fed_of(ctx)
        local p = f and D.fed_progression(f)
        if not p then return false end
        for _, b in ipairs(world.blocks(world.field(p, "perks"))) do
            if world.field(b, "type") == e.value.text then return true end
        end
        return false
    end
    -- has_federation_law = <law> (CFederation::HasLaw): the law enacted in its category
    TRIG["has_federation_law"] = function(e, ctx)
        local f = fed_of(ctx)
        local p = f and D.fed_progression(f)
        local laws = p and world.field(p, "laws")
        if type(laws) ~= "table" then return false end
        for _, x in ipairs(laws) do
            if x.op and x.value and x.value.text == e.value.text then return true end
        end
        return false
    end
    -- has_any_federation_law_in_category = <category> (CFederationProgression::GetEnactedLaw)
    TRIG["has_any_federation_law_in_category"] = function(e, ctx)
        local f = fed_of(ctx)
        local p = f and D.fed_progression(f)
        local laws = p and world.field(p, "laws")
        return type(laws) == "table" and world.field(laws, e.value.text or "") ~= nil
    end
    -- has_federation_setting = <setting> (CHasFederationSetting 0x1a18c40): the settings byte
    TRIG["has_federation_setting"] = function(e, ctx)
        local f = fed_of(ctx)
        return f ~= nil and D.fed_setting(f, e.value.text or "")
    end
    -- any_federation_ally (CFederationAllyListBuilder): the other members of the country's federation
    LISTS["federation_ally"] = function(sc)
        if sc.kind ~= "country" then return {} end
        local f = D.federation(sc.id)
        if not f then return {} end
        local out = {}
        for _, m in ipairs(D.members(f)) do
            if m ~= sc.id then out[#out + 1] = S("country", m) end
        end
        return out
    end
    -- any_associate (CFederationListAssociatesBuilder)
    LISTS["associate"] = function(sc)
        local f = sc.kind == "federation" and sc.id or (sc.kind == "country" and D.federation(sc.id))
        return f and countries_scopes(D.associates(f)) or {}
    end
    -- federation_leader (scopes.log: a federation's leading empire): its `leader`
    LINKS["federation_leader"] = function(cur)
        local f = cur.kind == "federation" and cur.id or (cur.kind == "country" and D.federation(cur.id))
        local l = f and D.ref(world.field(D.fed_obj(f), "leader"))
        return (l and D.alive(l)) and S("country", l) or nil
    end
    -- any_federation (CFederationListBuilder): every federation
    LISTS["federation"] = function()
        local out = {}
        for _, f in ipairs(world.all("federation")) do out[#out + 1] = S("federation", f) end
        return out
    end

    -- ------------------------------------------------------------------------------------------
    -- the galactic community (CGalacticCommunity, CGameState +0x760)

    -- is_galactic_community_member = yes/no (0x1a044b0): the members list
    TRIG["is_galactic_community_member"] = bool_trigger(D.gc_is_member)
    -- is_part_of_galactic_council = yes/no (0x1a04820): the leader, or the council list
    TRIG["is_part_of_galactic_council"] = function(e, ctx)
        local us = ctx.this.kind == "country" and ctx.this.id or nil
        local r = false
        if us then
            if D.gc_leader() == us then
                r = true
            else
                for _, c in ipairs(D.gc_council()) do
                    if c == us then r = true break end
                end
            end
        end
        return r == yes(e)
    end
    -- is_galactic_emperor / is_galactic_custodian = yes/no (0x1a07250 / 0x1a07170): the leader
    -- when the Galactic Empire is (not) formed, compared with the scope's country id (-1 for
    -- another scope)
    local function holder_trigger(empire)
        return function(e, ctx)
            local holder = (D.gc_empire() == empire) and (D.gc_leader() or -1) or -1
            local id = ctx.this.kind == "country" and ctx.this.id or -1
            return (holder == id) == yes(e)
        end
    end
    TRIG["is_galactic_emperor"] = holder_trigger(true)
    TRIG["is_galactic_custodian"] = holder_trigger(false)
    -- has_galactic_emperor / has_galactic_custodian = yes/no: there is such a leader
    TRIG["has_galactic_emperor"] = function(e)
        return (D.gc_empire() and D.gc_leader() ~= nil) == yes(e)
    end
    TRIG["has_galactic_custodian"] = function(e)
        return (not D.gc_empire() and D.gc_leader() ~= nil) == yes(e)
    end
    -- is_galactic_council_established = yes/no (0x1a063e0): the council_established date set
    TRIG["is_galactic_council_established"] = function(e) return D.gc_council_established() == yes(e) end
    -- is_years_since_community_formation <op> n (0x1a05eb0): -1 when not formed, else the years
    num_trigger("is_years_since_community_formation", function()
        local formed = D.date_days(world.field(D.community(), "community_formed"))
        if not formed then return -1 end
        return floor(eval.today() / 360) - floor(formed / 360)
    end)
    -- is_active_resolution = <resolution> (CGalacticCommunity::IsResolutionActive 0x62bc10): the
    -- newest passed resolution of the type, unless a newer one of the same category replaced it
    -- [I: CResolutionType::CanBeActive and the category's stacking flag are not read]
    TRIG["is_active_resolution"] = function(e)
        local want = e.value.text
        if not want then return false end
        local passed = D.gc_passed_types()
        for i = #passed, 1, -1 do
            if passed[i] == want then return true end
        end
        return false
    end
    -- galactic_community_rank <op> n (0x1a06920): the place in `members` (kept in diplomatic weight
    -- order by the game) + 1, -1 when not a member
    num_trigger("galactic_community_rank", function(ctx)
        local us = ctx.this.kind == "country" and ctx.this.id or nil
        for i, m in ipairs(D.gc_members()) do
            if m == us then return i end
        end
        return -1
    end)
    -- num_council_positions <op> n (0x1a06790): the community's council size (`council_positions`,
    -- CGalacticCommunity +0x2ec)
    num_trigger("num_council_positions", function()
        return tonumber(world.field(D.community(), "council_positions")) or 0
    end)
    -- is_permanent_councillor = yes/no (0x1a06b10): in `permanent_council`
    TRIG["is_permanent_councillor"] = function(e, ctx)
        local us = ctx.this.kind == "country" and ctx.this.id or -1
        local r = false
        for _, c in ipairs(D.id_list(world.field(D.community(), "permanent_council"))) do
            if c == us then r = true break end
        end
        return r == yes(e)
    end
    -- any_galcom_member / any_council_member (CGalcomMemberListBuilder,
    -- CGalacticCouncilMemberListBuilder)
    LISTS["galcom_member"] = function() return countries_scopes(D.gc_members()) end
    LISTS["council_member"] = function()
        local out, seen = {}, {}
        local l = D.gc_leader()
        if l then out[1] = S("country", l); seen[l] = true end
        for _, c in ipairs(D.gc_council()) do
            if not seen[c] then out[#out + 1] = S("country", c) end
        end
        return out
    end

    -- ------------------------------------------------------------------------------------------
    -- borders

    -- the system a scope is in (a planet's, a ship's fleet's, a fleet's, a system)
    local function system_of(sc)
        if sc.kind == "system" then return sc.id end
        local E = rawget(_G, "E")
        if E and E.system_of then
            local s = E.system_of(sc.kind, sc.id)
            if s then return tonumber(s) end
        end
        return nil
    end
    -- is_within_borders_of = <c> (CIsWithinBordersOfTrigger 0x194c540), is_inside_border = <c>
    -- (CIsInsideBorder 0x195c5e0): the owner of the scope's system is the target
    local function within(e, ctx)
        local them = target_country(e, ctx)
        if not them or ctx.this == NONE then return false end
        sync()
        local s = system_of(ctx.this)
        return s ~= nil and D.system_owner(s) == them
    end
    TRIG["is_within_borders_of"] = within
    TRIG["is_inside_border"] = within
    -- is_neighbor_of = <c> (CIsNeighborOfTrigger<SNeighborOfImpl> 0x19e7090): a country: its
    -- relation towards the target borders (bit 4); another scope: its system borders the target's
    -- (CCountryBorderManager::CalcIsBorderingSystem: owned by it or a hyperlane away [I])
    TRIG["is_neighbor_of"] = function(e, ctx)
        local them = target_country(e, ctx)
        if not them or ctx.this == NONE then return false end
        sync()
        if ctx.this.kind == "country" then
            return D.flag(ctx.this.id, them, "borders")
        end
        local s = system_of(ctx.this)
        if not s then return false end
        if D.system_owner(s) == them then return true end
        for _, h in ipairs(world.blocks(world.field(world.object("system", s), "hyperlane"))) do
            local to = tonumber(world.field(h, "to"))
            if to and D.system_owner(to) == them then return true end
        end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- claims

    -- the game rule can_add_claim (CGameRules::CanAddClaim 0x5b9570): this = the system, root = the
    -- claimer
    local function can_add_claim(sid, us)
        local defs = require("engine.defs")
        local d = defs.get("common/game_rules", "can_add_claim")
        if not d then return true end
        local ctx = eval.new_ctx(S("system", sid), nil, nil, d.file)
        ctx.root = S("country", us)
        local ok, holds = pcall(eval.trigger, d.block, ctx)
        return ok and holds == true
    end
    -- the country's intel level of a system (its `intel_level` list by system index, as the
    -- pathfinder's DoesSystemRequireExplorationCached reads it) [I: CCountry::GetIntelLevel]
    local intel_cache = setmetatable({}, { __mode = "k" })
    local function intel_level(us, sid)
        local block = world.field(D.country(us), "intel_level")
        if type(block) ~= "table" then return 0 end
        local a = intel_cache[block]
        if not a or a.n ~= #block then
            a = { n = #block }
            for i, v in ipairs(world.list(block)) do a[i] = tonumber(v) end
            intel_cache[block] = a
        end
        return a[(sid % 16777216) + 1] or 0
    end
    -- CGalacticObject::IsClaimableBy(system, us, true, true) (0x864b50): not ours (its primary
    -- starbase's owner, else its owner), some intel, an owner we have communications with, and the
    -- game rule can_add_claim (the war-ally test is skipped for potential claims)
    local function claimable_by(sid, us)
        local owner = D.system_owner(sid)
        if owner == us then return false end
        if intel_level(us, sid) == 0 then return false end
        if not owner or not D.alive(owner) then return false end
        if not D.flag(us, owner, "communications") then return false end
        return can_add_claim(sid, us)
    end
    -- a valid claim of us on the system (its `claims = { { owner claims } }`) [I: CClaim::IsValid]
    local function has_claim_on(sid, us)
        for _, c in ipairs(world.blocks(world.field(world.object("system", sid), "claims"))) do
            if tonumber(world.field(c, "owner")) == us and (tonumber(world.field(c, "claims")) or 0) > 0 then
                return true
            end
        end
        return false
    end
    -- CCountry::CanMakePotentialClaimOnCountry(us, other) (0x72ea70): the other's capital system is
    -- claimable, or we already claim one of its systems
    local function potential_claim_on(us, other)
        local E = rawget(_G, "E")
        local cap = E and E.get("country", other, "capital")
        local csys = cap and E.system_of and tonumber(E.system_of("planet", cap))
        if csys and claimable_by(csys, us) then return true end
        for _, sid in ipairs(D.systems_of(other)) do
            if has_claim_on(sid, us) then return true end
        end
        return false
    end
    -- the claims of us on a system (`claims = { { owner claims } }`, CGalacticObject::GetClaimsBy)
    local function claims_on(sid, us)
        for _, c in ipairs(world.blocks(world.field(world.object("system", sid), "claims"))) do
            if tonumber(world.field(c, "owner")) == us then return tonumber(world.field(c, "claims")) or 0 end
        end
        return 0
    end
    -- has_claim = <system / planet / country> (CHasClaimTrigger 0x19ac130): a valid claim on the
    -- system (a planet's system); a country: CDiplomacyCountryModule::HasClaim, a claim on one of its
    -- systems [I]
    TRIG["has_claim"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or not e.value.text then return false end
        local found, t = eval.resolve(e.value.text, ctx, e)
        if not found or not t or t == NONE then return false end
        sync()
        if t.kind == "system" then return has_claim_on(t.id, us) end
        if t.kind == "planet" then
            local s = system_of(t)
            return s ~= nil and has_claim_on(s, us)
        end
        if t.kind == "country" then
            for _, sid in ipairs(D.systems_of(t.id)) do
                if has_claim_on(sid, us) then return true end
            end
        end
        return false
    end
    -- num_claims_on_system = { target = <system> value <op> n } (CNumClaimsOnSystem 0x1a14140): our
    -- claims' count on the system
    TRIG["num_claims_on_system"] = function(e, ctx)
        if e.value.text then return false end
        local us = this_country(ctx)
        local t = param_scope(e.value, "target", ctx)
        local s = t and system_of(t)
        if not us or not s then return false end
        return compare_value(claims_on(s, us), e, ctx)
    end

    -- has_potential_claims = yes/no (CHasPotentialClaimsTrigger 0x19ac650 ->
    -- CCountry::HasPotentialClaimTarget 0x72e9c0): over the country's relations
    TRIG["has_potential_claims"] = function(e, ctx)
        local us = this_country(ctx)
        local r = false
        if us then
            sync()
            local _, list = D.relations_of(us)
            for _, rel in ipairs(list) do
                local other = tonumber(world.field(rel, "country"))
                if other and D.alive(other) and potential_claim_on(us, other) then
                    r = true
                    break
                end
            end
        end
        return r == yes(e)
    end

    -- ------------------------------------------------------------------------------------------
    -- values from triggers (`trigger:<name>`), when eval has the table

    if eval.TRIGGER_VALUES then
        for k, f in pairs(VALUE) do
            eval.TRIGGER_VALUES[k] = function(ctx)
                sync()
                return f(ctx) or 0
            end
        end
    end
    eval.diplomacy_values = VALUE

    -- the fleets' access (engine.diplomacy fills the pathfinder's and the movement's hooks)
    D.install_access_hooks()
end
