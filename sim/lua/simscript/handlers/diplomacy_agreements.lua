-- simscript/handlers/diplomacy_agreements.lua : subject agreements and subjects
-- (docs/script_diplomacy.md): making a subject, the agreement's preset, terms and rules, loyalty and
-- the specialist conversion, and the triggers on them.
--
-- An agreement is the save's `agreements = { agreements = { <id> = { owner target active_status
-- date_added date_changed term_data subject_specialization } } }` (CAgreement::WriteMembers
-- 0x220b6d0 [V]); its term_data has the rules (`can_subject_be_integrated can_subject_do_diplomacy
-- can_subject_vote has_access has_sensors joins_overlord_wars calls_overlord_to_war
-- subject_expansion_type`), `agreement_preset` and the `discrete_terms` / `resource_terms` lists of
-- `{ key value }` (as the game's save after set_subject_of shows). The subject has `overlord`,
-- `subject_date` and `loyalty`, the overlord `subjects`, both relations `subject = yes`.

return function(eval, H)
    local TRIG, EFF, LISTS = eval.TRIG, eval.EFF, eval.LISTS
    local D, world = H.D, H.world
    local S = H.S
    local sync, yes = H.sync, H.yes
    local this_country, target_country, param_country, param_text = H.this_country, H.target_country,
        H.param_country, H.param_text

    local function agreement(ctx) return H.scoped(ctx, "agreement") end
    local function term_data(a, create)
        if create then return world.child(a, "term_data") end
        local t = world.field(a, "term_data")
        return type(t) == "table" and t or nil
    end
    -- a discrete or resource term's value (`{ key value }` in the list)
    local function term_entry(td, list, key)
        for _, b in ipairs(world.blocks(td and world.field(td, list) or nil)) do
            if world.field(b, "key") == key then return b end
        end
        return nil
    end
    local function term_value(td, key)
        local b = term_entry(td, "discrete_terms", key) or term_entry(td, "resource_terms", key)
        return b and world.field(b, "value") or nil
    end
    local function set_term(td, list, key, value)
        local b = term_entry(td, list, key)
        if not b then
            b = {}
            world.append(b, "key", key)
            world.append(b, "value", value)
            world.push(world.child(td, list), b)
        else
            world.set(b, "value", value)
        end
    end

    -- the rules (CAgreementTermData::Set*: the term_data's fields), each from its effect's value;
    -- a discrete term's activate_effect sets them (common/agreement_term_values)
    local RULES = {
        set_rule_can_subject_be_integrated = { "can_subject_be_integrated", { yes = "yes", no = "no" } },
        set_rule_can_subject_do_diplomacy = { "can_subject_do_diplomacy", { yes = "yes", no = "no" } },
        set_rule_can_subject_vote = { "can_subject_vote", { yes = "yes", no = "no" } },
        set_rule_can_subject_expand = { "subject_expansion_type",
            { can_expand = "can_expand", can_expand_with_tithe = "can_expand_with_tithe", cannot_expand = "cannot_expand" } },
        set_rule_join_overlord_wars = { "joins_overlord_wars", { none = "none", defensive = "defensive", offensive = "offensive", all = "all" } },
        set_rule_join_subject_wars = { "calls_overlord_to_war", { none = "none", defensive = "defensive", offensive = "offensive", all = "all" } },
        set_rule_subject_has_access = { "has_access", { yes = "yes", no = "no" } },
        set_rule_subject_has_sensors = { "has_sensors", { yes = "yes", no = "no" } },
    }
    -- set_rule_* = <value> (CSetRule*Effect 0x37d17a0..0x37d2080): the agreement's rule; a subject
    -- that may no longer do diplomacy loses its rivals and is no one's rival
    -- (ClearRivalsAndReverseRivals); one that may vote again has its voting rights checked
    for k, spec in pairs(RULES) do
        EFF[k] = function(e, ctx)
            local _, a = agreement(ctx)
            local v = a and spec[2][e.value.text or ""]
            if not v then return end
            sync()
            world.set(term_data(a, true), spec[1], v)
            if k == "set_rule_can_subject_do_diplomacy" and v == "no" then
                local subj = D.ref(world.field(a, "target"))
                if subj then
                    local m = D.diplomacy_module(subj)
                    for _, r in ipairs(D.rivals(subj)) do
                        H.list_remove(m, "rivals", r)
                        H.remove_key(D.relation(subj, r), "is_rival")
                    end
                    for _, id in ipairs(world.all("country")) do
                        if D.is_rivaling(id, subj) then
                            H.list_remove(D.diplomacy_module(id), "rivals", subj)
                            H.remove_key(D.relation(id, subj), "is_rival")
                        end
                    end
                end
            end
            H.script_write()
        end
    end

    -- a term value's activate_effect (common/agreement_term_values), the agreement's scope
    local function activate(aid, value)
        local d = H.def("common/agreement_term_values", value)
        if d then H.run(H.def_field(d, "activate_effect"), S("agreement", aid), nil) end
    end
    -- the terms of a block `{ key value ... }` (a preset's term_data, set_agreement_terms) applied:
    -- discrete terms set and activated, resource subsidies (resource_subsidies_<r> = n) set
    local function apply_terms(aid, a, block)
        local td = term_data(a, true)
        for _, x in ipairs(block or {}) do
            if x.op and x.key and x.value.text then
                local k, v = x.key.text, x.value.text
                if k:match("^resource_subsidies_") then
                    set_term(td, "resource_terms", k, v)
                elseif H.def("common/agreement_terms", k) then
                    set_term(td, "discrete_terms", k, v)
                    activate(aid, v)
                end
            elseif type(x) == "table" and not x.text and not x.op then
                -- `{ key value }` entries (a preset's discrete_terms / resource_terms lists)
                local k, v = world.field(x, "key"), world.field(x, "value")
                if k and v then
                    if k:match("^resource_subsidies_") then set_term(td, "resource_terms", k, v)
                    else set_term(td, "discrete_terms", k, v); activate(aid, v) end
                end
            end
        end
    end
    -- a preset's terms (common/agreement_presets `term_data = { discrete_terms = { { key value } }
    -- resource_terms = { ... } }`)
    local function apply_preset(aid, a, preset, terms)
        local d = H.def("common/agreement_presets", preset)
        if not d then return false end
        H.set_quoted(term_data(a, true), "agreement_preset", preset)
        if terms then
            local td = H.def_field(d, "term_data")
            if type(td) == "table" then
                for _, list in ipairs({ "discrete_terms", "resource_terms" }) do
                    local l = require("engine.defs").field(td, list)
                    if type(l) == "table" then apply_terms(aid, a, l) end
                end
            end
        end
        return true
    end

    -- set_agreement_preset = { preset apply_terms } (CSetAgreementPresetEffect 0x37d3200): the
    -- preset, its terms applied unless apply_terms = no (EnsureTermsArePossible not modelled)
    EFF["set_agreement_preset"] = function(e, ctx)
        local aid, a = agreement(ctx)
        if not a or e.value.text then return end
        local preset = param_text(e.value, "preset")
        if not preset then return end
        sync()
        if apply_preset(aid, a, preset, param_text(e.value, "apply_terms") ~= "no") then
            world.set(a, "date_changed", H.date_text())
            H.script_write()
        end
    end
    -- set_agreement_terms = { <term> = <value> resource_subsidies_<r> = n ... }
    -- (CSetAgreementTermsEffect 0x37d2880: SetDiscreteValue / SetResourceValue)
    EFF["set_agreement_terms"] = function(e, ctx)
        local aid, a = agreement(ctx)
        if not a or e.value.text then return end
        sync()
        apply_terms(aid, a, e.value)
        world.set(a, "date_changed", H.date_text())
        H.script_write()
    end
    -- agreement_preset = <preset> (CAgreementPresetTrigger 0x3c0d590)
    TRIG["agreement_preset"] = function(e, ctx)
        local _, a = agreement(ctx)
        local td = a and term_data(a)
        return td ~= nil and tostring(world.field(td, "agreement_preset") or ""):gsub('"', "") == e.value.text
    end
    -- has_term_value = { term value } (CHasTermValueTrigger 0x3c0c8d0: GetDiscreteValue)
    TRIG["has_term_value"] = function(e, ctx)
        local _, a = agreement(ctx)
        if not a or e.value.text then return false end
        local t, v = param_text(e.value, "term"), param_text(e.value, "value")
        return t ~= nil and term_value(term_data(a), t) == v
    end

    -- the specialization (`subject_specialization = { subject_conversion_process = { progress
    -- in_progress done ignore } level experience }`): active with a specialist_type term other than
    -- specialist_none and no conversion running [I: CSubjectSpecialization::IsActive]
    local function specialist(a) return term_value(term_data(a), "specialist_type") or "specialist_none" end
    TRIG["has_active_specialization"] = function(e, ctx)
        local _, a = agreement(ctx)
        if not a or not e.value.text then return false end
        local sp = specialist(a)
        local proc = world.path(a, "subject_specialization", "subject_conversion_process")
        local converting = type(proc) == "table" and world.field(proc, "in_progress") == "yes"
        if sp == "specialist_none" or converting then return false end
        return e.value.text == "any" or e.value.text == sp
    end
    -- convert_to_specialist = <type / none> (CConvertToSpecialistEffect 0x37d2250): none finishes
    -- the conversion at specialist_none (FinishConversion); a type starts its conversion
    -- (StartConversion: the process in progress from 0, its target kept as `type` [I])
    EFF["convert_to_specialist"] = function(e, ctx)
        local aid, a = agreement(ctx)
        local v = e.value.text
        if not a or not v then return end
        if v ~= "none" and not H.def("common/specialist_subject_types", v) then return end
        sync()
        local ss = world.child(a, "subject_specialization")
        local proc = world.child(ss, "subject_conversion_process")
        if v == "none" then
            set_term(term_data(a, true), "discrete_terms", "specialist_type", "specialist_none")
            activate(aid, "specialist_none")
            world.set(proc, "in_progress", "no")
            world.set(proc, "done", "no")
            world.set(proc, "progress", 0)
            H.remove_key(proc, "type")
        else
            world.set(proc, "in_progress", "yes")
            world.set(proc, "done", "no")
            world.set(proc, "progress", 0)
            world.set(proc, "type", v)
        end
        H.script_write()
    end
    -- add_loyalty = <n> (CAddLoyaltyEffect 0x37d3440): the agreement's subject (target), its
    -- loyalty plus n within SUBJECT_LOYALTY_MIN..MAX [I: the bounds]
    EFF["add_loyalty"] = function(e, ctx)
        local _, a = agreement(ctx)
        local subj = a and D.ref(world.field(a, "target"))
        if not subj or not D.alive(subj) then return end
        local v = H.value(e, ctx)
        sync()
        local c = D.country(subj)
        local l = H.num(world.field(c, "loyalty")) + v
        l = math.max(H.define("NGameplay", "SUBJECT_LOYALTY_MIN", -100), math.min(H.define("NGameplay", "SUBJECT_LOYALTY_MAX", 100), l))
        world.set(c, "loyalty", H.fixed(l))
        H.script_write()
    end

    -- a new agreement's rules before its preset's terms set theirs [I]
    local DEFAULT_RULES = {
        { "can_subject_be_integrated", "no" }, { "can_subject_do_diplomacy", "yes" }, { "can_subject_vote", "no" },
        { "has_access", "yes" }, { "has_sensors", "no" }, { "joins_overlord_wars", "none" },
        { "calls_overlord_to_war", "none" }, { "subject_expansion_type", "can_expand" },
    }

    -- the overlord dropped (CCountry::ClearOverlord): the subject's `overlord`, the overlord's
    -- `subjects`, both relations' `subject`, their agreement
    local function clear_overlord(subj)
        local o = D.overlord(subj) or D.ref(world.field(D.country(subj), "overlord"))
        if not o then return end
        H.remove_key(D.country(subj), "overlord")
        H.remove_key(D.country(subj), "subject_date")
        H.list_remove(D.country(o), "subjects", subj)
        H.remove_key(D.relation(subj, o), "subject")
        H.remove_key(D.relation(o, subj), "subject")
        local ag = D.agreement(o, subj)
        if ag then world.remove(H.STORE.agreement, ag.id) end
    end
    -- set_subject_of = { who use_demanded_terms allow_instant_negotiation preset } (CSetSubjectOfEffect
    -- 0x37676c0): the old overlord cleared; with an agreement already between the two only its
    -- preset changes; else CCountry::SetNewOverlord: `overlord`, `subject_date`, the overlord's
    -- `subjects`, `subject = yes` both ways, a new agreement (owner = overlord, target = subject) with
    -- the preset's terms (preset_vassal without one [I: the default preset])
    EFF["set_subject_of"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local who = param_country(e.value, "who", ctx)
        if not who or who == us then return end
        local preset = param_text(e.value, "preset") or "preset_vassal"
        sync()
        local existing = D.agreement(who, us)
        if existing and D.ref(world.field(existing.block, "owner")) == who then
            apply_preset(existing.id, existing.block, preset, true)
            H.script_write()
            return
        end
        clear_overlord(us)
        local c = D.country(us)
        world.set(c, "overlord", who)
        world.append(c, "subject_date", H.date_text(), true)
        H.list_add(D.country(who), "subjects", us)
        for _, p in ipairs({ { us, who }, { who, us } }) do
            world.set(H.relation(p[1], p[2], true), "subject", "yes")
        end
        local aid = H.next_id("agreement")
        local a = {}
        world.create(H.STORE.agreement, aid, a)
        world.append(a, "owner", who)
        world.append(a, "target", us)
        world.append(a, "active_status", "active")
        world.append(a, "date_added", H.date_text(), true)
        world.append(a, "date_changed", H.date_text(), true)
        local td = world.child(a, "term_data")
        for _, kv in ipairs(DEFAULT_RULES) do world.set(td, kv[1], kv[2]) end
        apply_preset(aid, a, preset, true)
        local ss = world.child(a, "subject_specialization")
        local proc = world.child(ss, "subject_conversion_process")
        world.set(proc, "progress", 0)
        world.set(proc, "in_progress", "no")
        world.set(proc, "done", "no")
        world.set(proc, "ignore", "no")
        world.set(ss, "level", 0)
        world.set(ss, "experience", 0)
        if world.field(c, "loyalty") == nil then world.set(c, "loyalty", 0) end
        H.script_write()
    end

    -- vassals <op> n (CVassalsTrigger 0x3ba4ef0): the subjects whose agreement's preset
    -- (CalcSubjectAgreementPreset) is the vassal preset
    H.num_trigger("vassals", function(ctx)
        local us = this_country(ctx)
        if not us then return nil end
        local n = 0
        for _, s in ipairs(D.subjects(us)) do
            local ag = D.agreement(us, s)
            local td = ag and world.field(ag.block, "term_data")
            if type(td) == "table" and tostring(world.field(td, "agreement_preset") or ""):gsub('"', "") == "preset_vassal" then n = n + 1 end
        end
        return n
    end)
    -- subject_can_diplomacy = <country> (CSubjectCanDiplomacy 0x3ba5350 -> CalcCanDoDiplomacy): a
    -- subject (an error otherwise) whose agreement lets it do diplomacy [I: the target is not read]
    TRIG["subject_can_diplomacy"] = function(e, ctx)
        local us = this_country(ctx)
        local o = us and D.overlord(us)
        if not o then return false end
        local ag = D.agreement(o, us)
        local td = ag and world.field(ag.block, "term_data")
        return type(td) == "table" and world.field(td, "can_subject_do_diplomacy") == "yes"
    end
    -- has_secret_fealty_from_subject_of = <country> (CHasSecretFealtyFromSubjectOfTrigger
    -- 0x3c16580): a subject of the target (its `subjects`) whose relation towards us has
    -- `secret_fealty`
    TRIG["has_secret_fealty_from_subject_of"] = function(e, ctx)
        local us = this_country(ctx)
        local them = us and target_country(e, ctx)
        if not them then return false end
        for _, s in ipairs(D.subjects(them)) do
            if D.flag(s, us, "secret_fealty") then return true end
        end
        return false
    end

    -- any_agreement / every_agreement / ... (a country's agreements, as overlord or subject; every
    -- agreement without a country)
    LISTS["agreement"] = function(sc)
        local out = {}
        for _, a in ipairs(D.agreements()) do
            local o, t = D.ref(world.field(a.block, "owner")), D.ref(world.field(a.block, "target"))
            if not sc or sc.kind ~= "country" or o == sc.id or t == sc.id then out[#out + 1] = S("agreement", a.id) end
        end
        return out
    end
end
