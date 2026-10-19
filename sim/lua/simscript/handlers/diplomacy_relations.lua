-- simscript/handlers/diplomacy_relations.lua : the relations between two countries (communications,
-- contact, trust, threat, relation flags, truces, rivals, guarantees), claims and casus belli,
-- intel and intel reports, envoys, and the AI's attitude behaviours (docs/script_diplomacy.md).
--
-- Each keyword names its class in the Linux 4.5.2 build (/opt/stellaris-headless/re on .24): what
-- its ExecuteActual / ActualEvaluate calls [V], and what is inferred [I]. The fields are the save's
-- (CRelation, CIntelData, CDiplomacyCountryModule, CCasusBelli WriteMembers' names [V]).

return function(eval, H)
    local TRIG, EFF, LINKS = eval.TRIG, eval.EFF, eval.LINKS
    local D, world = H.D, H.world
    local S = H.S
    local sync, yes = H.sync, H.yes
    local floor = math.floor
    local this_country, target_country, param_country, param_text = H.this_country, H.target_country,
        H.param_country, H.param_text
    local compare_value, fixed = H.compare_value, H.fixed

    -- a trigger `<k> = <country>` on a country scope
    local function pair_trigger(f)
        return function(e, ctx)
            local us = this_country(ctx)
            local them = us and target_country(e, ctx)
            if not them then return false end
            sync()
            return f(us, them) == true
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- communications and contact

    -- CCountry::EstablishCommunications [V call; I its body]: both relations get `communications`
    -- and `contact`, the intel towards each other at least INTEL_FROM_COMMUNICATIONS
    local function communicate(a, b)
        if a == b then return end
        for _, p in ipairs({ { a, b }, { b, a } }) do
            local r = H.relation(p[1], p[2], true)
            if r then
                world.set(r, "communications", "yes")
                world.set(r, "contact", "yes")
            end
        end
        H.script_write()
    end
    -- establish_communications = <country> (CEstablishCommunicationsEffect 0x375efa0): with the
    -- message; _no_message (0x375f1c0) without (the same call)
    for _, k in ipairs({ "establish_communications", "establish_communications_no_message" }) do
        EFF[k] = function(e, ctx)
            local us = this_country(ctx)
            local them = us and target_country(e, ctx)
            if not them then return end
            sync()
            communicate(us, them)
        end
    end
    -- remove_communications = <country> [I: CRemoveCommunicationsEffect has no ExecuteActual of its
    -- own in the build read; the documented behaviour]: both relations lose `communications`
    EFF["remove_communications"] = function(e, ctx)
        local us = this_country(ctx)
        local them = us and target_country(e, ctx)
        if not them then return end
        sync()
        H.set_yes(D.relation(us, them), "communications", false)
        H.set_yes(D.relation(them, us), "communications", false)
        H.script_write()
    end
    -- establish_contact = { who location } (CEstablishContactEffect 0x373b910 -> CCountry::Contact):
    -- the location's coordinate is needed (an error without one); both relations get `contact`
    EFF["establish_contact"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "who", ctx)
        if not them or them == us then return end
        if H.param(e.value, "location") and not H.param_scope(e.value, "location", ctx) then return end
        sync()
        for _, p in ipairs({ { us, them }, { them, us } }) do
            local r = H.relation(p[1], p[2], true)
            if r then world.set(r, "contact", "yes") end
        end
        H.script_write()
    end
    -- perc_communications_with_playable <op> x (CPercCommunicationsWithPlayableTrigger 0x3ba3280):
    -- of the other playable countries (type playable), the share we have communications with
    H.num_trigger("perc_communications_with_playable", function(ctx)
        local us = this_country(ctx)
        if not us then return nil end
        local n, with = 0, 0
        for _, id in ipairs(world.all("country")) do
            if id ~= us and D.alive(id) and D.type_key(id, "playable", false) then
                n = n + 1
                if D.flag(us, id, "communications") then with = with + 1 end
            end
        end
        return n > 0 and with / n or 0
    end)

    -- ------------------------------------------------------------------------------------------
    -- trust and threat

    -- add_trust = { amount who } (CAddTrustEffect 0x373abf0): our relation towards who (made if
    -- there is none), its trust (+0x118) plus amount, at most CRelation::GetMaxTrust (NDiplomacy
    -- MAX_TRUST [I: the pacts' lower maxima apply to the monthly growth]), at least 0 [I]; not on
    -- oneself
    EFF["add_trust"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "who", ctx)
        if not them or them == us then return end
        local amount = H.param_value(e.value, "amount", ctx, 0)
        sync()
        local r = H.relation(us, them, true)
        local t = H.num(world.field(r, "trust")) + amount
        local max = H.define("NDiplomacy", "MAX_TRUST", 100)
        if t > max then t = max end
        if t < 0 then t = 0 end
        world.set(r, "trust", fixed(t))
        H.script_write()
    end
    -- add_threat = { who amount } (CAddThreatEffect 0x36ea900): the scope's country (a country, the
    -- owner of a planet, colony, ship or system) gets threat from who (CDiplomacyCountryModule::
    -- AddThreat): a planet's amount x NAI THREAT_PLANET_MULT, a system's x THREAT_SYSTEM_MULT (x
    -- THREAT_STARBASE_MULT with an upgraded starbase); the module's `threats` lists who, our
    -- relation's `threat` grows [I: AddThreat's body]
    local function owner_of(sc)
        local E = rawget(_G, "E")
        if sc.kind == "country" then return sc.id end
        if sc.kind == "system" then return D.system_owner(sc.id) end
        if sc.kind == "planet" or sc.kind == "colony" then
            return E and tonumber(E.get("planet", sc.id, "owner")) or D.ref(world.field(world.object("planet", sc.id), "owner"))
        end
        if sc.kind == "ship" then
            local s = world.object("ship", sc.id)
            local f = s and world.object("fleet", tonumber(world.field(s, "fleet")))
            return f and D.ref(world.field(f, "owner"))
        end
        return nil
    end
    EFF["add_threat"] = function(e, ctx)
        local sc = ctx.this
        if not sc or e.value.text then return end
        local who = param_country(e.value, "who", ctx)
        local amount = H.param_value(e.value, "amount", ctx, 0)
        sync()
        local us = owner_of(sc)
        if not us or not D.alive(us) or not who or who == us then return end
        if sc.kind == "planet" or sc.kind == "colony" then
            amount = amount * H.define("NAI", "THREAT_PLANET_MULT", 1)
        elseif sc.kind == "system" then
            local sb = world.field(world.object("system", sc.id), "starbases")
            local upgraded = type(sb) == "table" and #world.list(sb) > 0
            amount = amount * H.define("NAI", upgraded and "THREAT_STARBASE_MULT" or "THREAT_SYSTEM_MULT", 1)
        end
        local m = world.child(world.child(D.country(us), "modules"), "standard_diplomacy_module")
        H.list_add(m, "threats", who)
        local r = H.relation(us, who, true)
        world.set(r, "threat", fixed(H.num(world.field(r, "threat")) + amount))
        H.script_write()
    end

    -- ------------------------------------------------------------------------------------------
    -- relation flags

    -- set_relation_flag = { who flag } (CSetRelationFlagEffect 0x3741f70): our relation towards who
    -- (made if none), its `flags = { name = <hour> }` (CreateDynamicFlag: `flag@from` names)
    EFF["set_relation_flag"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "who", ctx)
        local name, x = param_text(e.value, "flag")
        if not them or not name then return end
        name = eval._internal.flag_name(name, ctx, x)
        sync()
        local f = world.child(H.relation(us, them, true), "flags")
        H.remove_key(f, name)
        world.append(f, name, H.hour())
        H.script_write()
    end
    -- remove_relation_flag = { who flag } (CRemoveRelationFlagEffect 0x3742730)
    EFF["remove_relation_flag"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "who", ctx)
        local name, x = param_text(e.value, "flag")
        if not them or not name then return end
        name = eval._internal.flag_name(name, ctx, x)
        sync()
        local f = world.field(D.relation(us, them), "flags")
        if type(f) == "table" and H.remove_key(f, name) then H.script_write() end
    end
    -- clear_relations = { target relations = { <flag> ... } } (CClearRelationsEffect 0x37f33f0): our
    -- relation towards target (an error without one), the listed relation flags cleared [I: both
    -- ways; the list's names are CRelation's (`defensive_pact`, `non_aggression_pledge`, ...)]
    EFF["clear_relations"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "target", ctx)
        if not them then return end
        sync()
        local r1, r2 = D.relation(us, them), D.relation(them, us)
        if not r1 then return end
        local x = H.param(e.value, "relations")
        local names = {}
        if x and type(x.value) == "table" and not x.value.text then
            for _, v in ipairs(x.value) do
                local t = v.text or (v.key and v.key.text)
                if t then names[#names + 1] = t end
            end
        end
        for _, n in ipairs(names) do
            H.remove_key(r1, n)
            if r2 then H.remove_key(r2, n) end
        end
        H.script_write()
    end

    -- ------------------------------------------------------------------------------------------
    -- truces, rivals, guarantees

    -- end_truce = <country> (CEndTruceEffect 0x375e6f0): only with a truce (HasTruceWith);
    -- CRelation::EndTruce: our relation's `truce` taken out [I: theirs as well, the truce object
    -- removed when no relation refers to it]
    EFF["end_truce"] = function(e, ctx)
        local us = this_country(ctx)
        local them = us and target_country(e, ctx)
        if not them then return end
        sync()
        if not D.has_truce(us, them) then return end
        local t = D.truce_of(D.relation(us, them)) or D.truce_of(D.relation(them, us))
        H.remove_key(D.relation(us, them), "truce")
        H.remove_key(D.relation(them, us), "truce")
        -- the truce object, when no other relation refers to it
        local used = false
        for _, id in ipairs(world.all("country")) do
            local _, list = D.relations_of(id)
            for _, r in ipairs(list) do
                if D.ref(world.field(r, "truce")) == t then used = true break end
            end
            if used then break end
        end
        if t and not used then world.remove("truce", t) end
        H.script_write()
    end
    -- set_truce = { target type } (CSetTruceEffect 0x375dcd0 -> CGameState::CreateNewTruce): a
    -- truce of the type (war, liberation, alliance, guarantee, none) between us and the target
    -- country, or between the sides of the target war
    local function new_truce(kind, name)
        local tid = H.next_id("truce")
        local t = {}
        world.create("truce", tid, t)
        local nb = name or {}
        if not name then world.append(nb, "key", "", true) end
        world.append(t, "name", nb)
        world.append(t, "start_date", H.date_text(), true)
        world.set(t, "truce_type", kind)
        return tid
    end
    H.new_truce = new_truce
    local function set_truce_between(a, b, tid)
        for _, p in ipairs({ { a, b }, { b, a } }) do
            local r = H.relation(p[1], p[2], true)
            if r then world.set(r, "truce", tid) end
        end
    end
    H.set_truce_between = set_truce_between
    EFF["set_truce"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local t = H.param_scope(e.value, "target", ctx)
        local kind = param_text(e.value, "type") or "war"
        if not t then return end
        sync()
        if t.kind == "war" and D.war_obj(t.id) then
            local tid = new_truce(kind)
            for _, a in ipairs(D.war_side(t.id, "attackers")) do
                for _, d in ipairs(D.war_side(t.id, "defenders")) do set_truce_between(a, d, tid) end
            end
        elseif t.kind == "country" and D.alive(t.id) and t.id ~= us then
            set_truce_between(us, t.id, new_truce(kind))
        else
            return
        end
        H.script_write()
    end
    -- end_rivalry = <country> (CEndRivalryEffect 0x375d7e0): only when rivaling;
    -- CDiplomacyCountryModule::RemoveRival: the module's `rivals` loses it, our relation's `is_rival`
    -- and `rival_date` go [I: the relation's fields]
    EFF["end_rivalry"] = function(e, ctx)
        local us = this_country(ctx)
        local them = us and target_country(e, ctx)
        if not them then return end
        sync()
        if not D.is_rivaling(us, them) then return end
        H.list_remove(D.diplomacy_module(us), "rivals", them)
        local r = D.relation(us, them)
        H.remove_key(r, "is_rival")
        H.remove_key(r, "rival_date")
        H.script_write()
    end
    -- guarantee_country = <country> or { target } (CGuaranteeCountryEffect 0x376fd00): our relation
    -- towards it (made if none) gets `guarantee`; not on oneself
    EFF["guarantee_country"] = function(e, ctx)
        local us = this_country(ctx)
        if not us then return end
        local them = e.value.text and target_country(e, ctx) or param_country(e.value, "target", ctx)
        if not them or them == us then return end
        sync()
        world.set(H.relation(us, them, true), "guarantee", "yes")
        H.script_write()
    end

    -- ------------------------------------------------------------------------------------------
    -- claims (a system's `claims = { { owner claims } }`)

    local function claims_entry(sys, owner, create)
        for _, c in ipairs(world.blocks(world.field(sys, "claims"))) do
            if D.ref(world.field(c, "owner")) == owner then return c end
        end
        if not create then return nil end
        local c = {}
        world.append(c, "owner", owner)
        world.append(c, "claims", 0)
        world.push(world.child(sys, "claims"), c)
        return c
    end
    -- add_claims = { who num_of_claims show_notification } (CAddClaimsEffect 0x3726260 ->
    -- CGalacticObject::AddClaims): not on a system the claimer owns; its claims grow
    EFF["add_claims"] = function(e, ctx)
        if ctx.this.kind ~= "system" or e.value.text then return end
        local sys = world.object("system", ctx.this.id)
        local who = param_country(e.value, "who", ctx)
        if not sys or not who then return end
        local n = H.param_value(e.value, "num_of_claims", ctx, 1)
        sync()
        if D.system_owner(ctx.this.id) == who then return end
        local c = claims_entry(sys, who, true)
        world.set(c, "claims", floor(H.num(world.field(c, "claims")) + n))
        H.script_write()
    end
    -- remove_claims = { who num_of_claims } (CRemoveClaimsEffect 0x3726bc0 ->
    -- CGalacticObject::RemoveClaims): the claims shrink, the entry goes at 0 [I]
    EFF["remove_claims"] = function(e, ctx)
        if ctx.this.kind ~= "system" or e.value.text then return end
        local sys = world.object("system", ctx.this.id)
        local who = param_country(e.value, "who", ctx)
        if not sys or not who then return end
        local n = H.param_value(e.value, "num_of_claims", ctx, 1)
        sync()
        local c = claims_entry(sys, who, false)
        if not c then return end
        local left = floor(H.num(world.field(c, "claims")) - n)
        if left > 0 then
            world.set(c, "claims", left)
        else
            local b = world.field(sys, "claims")
            for i = #b, 1, -1 do
                if b[i] == c then world.remove_at(b, i) end
            end
        end
        H.script_write()
    end

    -- ------------------------------------------------------------------------------------------
    -- casus belli (the diplomacy module's `casus_belli = { { type owner country } }`)

    -- CCasusBelli::AllowCasusBelliBetween [I: its body]: both countries alive, not the same, the
    -- type's `potential` (this = owner, from = target) holds
    local function allow_cb(type_key, owner, target)
        if owner == target or not D.alive(owner) or not D.alive(target) then return false end
        local d = H.def("common/casus_belli", type_key)
        if not d then return false end
        return H.holds(H.def_field(d, "potential"), S("country", owner), S("country", target))
    end
    local function has_cb(m, type_key, target)
        for _, cb in ipairs(world.blocks(m and world.field(m, "casus_belli") or nil)) do
            if D.ref(world.field(cb, "country")) == target and world.field(cb, "type") == type_key then return cb end
        end
        return nil
    end
    local function add_cb(owner, type_key, target)
        local m = world.child(world.child(D.country(owner), "modules"), "standard_diplomacy_module")
        if has_cb(m, type_key, target) then return false end
        local cb = {}
        H.set_quoted(cb, "type", type_key)
        world.append(cb, "owner", owner)
        world.append(cb, "country", target)
        world.push(world.child(m, "casus_belli"), cb)
        return true
    end
    local function remove_cb(owner, type_key, target)
        local m = D.diplomacy_module(owner)
        local list = m and world.field(m, "casus_belli")
        if type(list) ~= "table" then return false end
        for i = #list, 1, -1 do
            local cb = list[i]
            if not cb.text and not cb.op and D.ref(world.field(cb, "country")) == target and world.field(cb, "type") == type_key then
                world.remove_at(list, i)
                return true
            end
        end
        return false
    end
    -- add_casus_belli = { type who days } (CAddCasusBelliEffect 0x378c8f0): AllowCasusBelliBetween,
    -- then CDiplomacyCountryModule::AddCasusBelli; its days (the CB's expiry) are not saved [I:
    -- kept in the script state, eval.state.casus_belli_days]
    EFF["add_casus_belli"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local t = param_text(e.value, "type")
        local who = param_country(e.value, "who", ctx)
        if not t or not who then return end
        sync()
        if not allow_cb(t, us, who) then return end
        if add_cb(us, t, who) then H.script_write() end
        local days = H.param_value(e.value, "days", ctx, nil)
        if days then
            local st = eval.state.casus_belli_days or {}
            eval.state.casus_belli_days = st
            st[us .. ":" .. t .. ":" .. who] = eval.today() + days
        end
    end
    -- check_casus_belli_valid = { target type } (CCheckCasusBelliValidEffect 0x379bc70 ->
    -- UpdateCasusBelliWithTypeAgainst): the type (every type without one) re-evaluated against the
    -- target (every country with relations without one): kept or made when `potential` and
    -- `is_valid` hold, removed otherwise
    EFF["check_casus_belli_valid"] = function(e, ctx)
        local us = this_country(ctx)
        if not us then return end
        local want = not e.value.text and param_text(e.value, "type") or nil
        local target = not e.value.text and param_country(e.value, "target", ctx) or nil
        sync()
        local types = {}
        if want then
            types[1] = want
        else
            for k in pairs(require("engine.defs").folder("common/casus_belli")) do
                types[#types + 1] = k
            end
            table.sort(types)
        end
        local targets = {}
        if target then
            targets[1] = target
        else
            local _, list = D.relations_of(us)
            for _, r in ipairs(list) do
                local c = D.ref(world.field(r, "country"))
                if c and D.alive(c) then targets[#targets + 1] = c end
            end
        end
        local changed = false
        for _, t in ipairs(types) do
            local d = H.def("common/casus_belli", t)
            for _, c in ipairs(targets) do
                local ok = d and allow_cb(t, us, c) and H.holds(H.def_field(d, "is_valid"), S("country", us), S("country", c))
                if ok then
                    changed = add_cb(us, t, c) or changed
                else
                    changed = remove_cb(us, t, c) or changed
                end
            end
        end
        if changed then H.script_write() end
    end

    -- ------------------------------------------------------------------------------------------
    -- intel (the country's `intel_manager = { intel = { { <country> { intel reports stale_intel } } } }`)

    -- the intel data of us on them (CIntelManager::GetIntelData), made when create
    local function intel_data(us, them, create)
        local c = D.country(us)
        local im = c and world.field(c, "intel_manager")
        local list = type(im) == "table" and world.field(im, "intel") or nil
        if type(list) == "table" then
            for _, pair in ipairs(list) do
                local v = pair.value or pair
                if type(v) == "table" and not v.text then
                    -- each element is `{ <country> { ... } }`: a number then a block
                    local id, data
                    for _, x in ipairs(v) do
                        if x.text and not id then id = tonumber(x.text)
                        elseif type(x) == "table" and not x.text and not x.op then data = x end
                        if x.op and x.key and tonumber(x.key.text) then id = tonumber(x.key.text); data = x.value end
                    end
                    if id == them and type(data) == "table" then return data end
                end
            end
        end
        if not create or not c then return nil end
        im = world.child(c, "intel_manager")
        list = world.child(im, "intel")
        local data = {}
        world.append(data, "intel", 0)
        -- (each element reads as `{ <country> = { ... } }`)
        local pair = {}
        world.push(list, pair)
        world.append(pair, tostring(them), data)
        return data
    end
    H.intel_data = intel_data
    local function intel_of(us, them)
        local d = intel_data(us, them, false)
        return d and H.num(world.field(d, "intel")) or 0
    end
    H.intel_of = intel_of
    -- add_intel = { amount who } (CAddIntelEffect 0x3803c40 -> CIntelData::AddIntelValue): only with
    -- intel data between the two (an error otherwise); capped at INTEL_CAP [I], at least 0
    EFF["add_intel"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local who = param_country(e.value, "who", ctx)
        if not who then return end
        local amount = H.param_value(e.value, "amount", ctx, 0)
        sync()
        local d = intel_data(us, who, false)
        if not d then return end
        local v = H.num(world.field(d, "intel")) + amount
        local cap = H.define("NGameplay", "INTEL_CAP", 100)
        if v > cap then v = cap end
        if v < 0 then v = 0 end
        world.set(d, "intel", fixed(v))
        H.script_write()
    end
    -- the reports (`reports = { { category level end_date } }`, CIntelData::SIntelReport [V])
    local function reports(d)
        return world.blocks(d and world.field(d, "reports") or nil)
    end
    -- add_intel_report = { category level days who } (CAddIntelReportEffect 0x38045b0 ->
    -- CIntelData::AddIntelReport): a report of the category at the level until today + days (0:
    -- forever, no end_date)
    EFF["add_intel_report"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local who = param_country(e.value, "who", ctx)
        local cat = param_text(e.value, "category")
        if not who or not cat then return end
        local level = floor(H.param_value(e.value, "level", ctx, 0))
        local days = floor(H.param_value(e.value, "days", ctx, 0))
        sync()
        local d = intel_data(us, who, false)
        if not d then return end
        local r = {}
        world.append(r, "category", cat)
        world.append(r, "level", level)
        if days > 0 then world.append(r, "end_date", H.date_text(eval.today() + days), true) end
        world.push(world.child(d, "reports"), r)
        H.script_write()
    end
    -- clear_intel_report = { category who }: the category's reports removed
    EFF["clear_intel_report"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local who = param_country(e.value, "who", ctx)
        local cat = param_text(e.value, "category")
        if not who or not cat then return end
        sync()
        local d = intel_data(us, who, false)
        local list = d and world.field(d, "reports")
        if type(list) ~= "table" then return end
        local n = 0
        for i = #list, 1, -1 do
            local r = list[i]
            if not r.text and not r.op and world.field(r, "category") == cat then
                world.remove_at(list, i)
                n = n + 1
            end
        end
        if n > 0 then H.script_write() end
    end
    -- the report level of a category: the highest current report's (one past its end_date ignored)
    local function report_level(d, cat)
        local best = 0
        for _, r in ipairs(reports(d)) do
            if world.field(r, "category") == cat then
                local ends = D.date_days(world.field(r, "end_date"))
                if not ends or ends >= eval.today() then
                    best = math.max(best, H.num(world.field(r, "level")))
                end
            end
        end
        return best
    end
    -- the category's level from the intel value (common/intel_levels: the level whose `intel = { lo
    -- hi }` holds it, its <category> field)
    local function level_of_intel(v, cat)
        local defs = require("engine.defs")
        for _, d in pairs(defs.folder("common/intel_levels")) do
            local range = d and defs.field(d.block, "intel")
            if type(range) == "table" then
                local lo, hi = tonumber((range[1] or {}).text), tonumber((range[2] or {}).text)
                if lo and hi and v >= lo and v <= hi then return tonumber(defs.field(d.block, cat)) or 0 end
            end
        end
        return 0
    end
    -- CIntelData::GetIntelCategoryLevel [I]: the higher of the intel's level and the reports'
    local function category_level(us, them, cat)
        local d = intel_data(us, them, false)
        return math.max(level_of_intel(d and H.num(world.field(d, "intel")) or 0, cat), report_level(d, cat))
    end
    H.category_level = category_level
    -- intel = { who value } (CIntelTrigger 0x3c26330): the intel value
    TRIG["intel"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local who = param_country(e.value, "who", ctx)
        if not who then return false end
        sync()
        return compare_value(intel_of(us, who), e, ctx)
    end
    -- has_intel_level = { who category level } (CHasIntelLevelTrigger 0x3c26770)
    TRIG["has_intel_level"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local who = param_country(e.value, "who", ctx)
        local cat = param_text(e.value, "category")
        local x = H.param(e.value, "level")
        if not who or not cat or not x then return false end
        sync()
        return H.compare(category_level(us, who, cat), x.op, eval.value(x.value, ctx, x))
    end
    -- has_intel_report = { who category level } (CHasIntelReportTrigger 0x3c26c10): the reports' level
    TRIG["has_intel_report"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local who = param_country(e.value, "who", ctx)
        local cat = param_text(e.value, "category")
        local x = H.param(e.value, "level")
        if not who or not cat or not x then return false end
        sync()
        local lv = report_level(intel_data(us, who, false), cat)
        local want = eval.value(x.value, ctx, x)
        if x.op == "=" then return lv >= want end
        return H.compare(lv, x.op, want)
    end
    -- an intel item's category and level (common/intel_categories: `<category> = { intel_level = {
    -- items } ... }`, the n-th intel_level block is level n - 1)
    local item_cache
    local function item_of(name)
        if not item_cache then
            item_cache = {}
            local defs = require("engine.defs")
            for cat, d in pairs(defs.folder("common/intel_categories")) do
                local n = 0
                for _, x in ipairs(d and d.block or {}) do
                    if x.op and x.key and x.key.text == "intel_level" and type(x.value) == "table" then
                        for _, it in ipairs(x.value) do
                            if it.text then item_cache[it.text] = { cat = cat, level = n } end
                        end
                        n = n + 1
                    end
                end
            end
        end
        return item_cache[name]
    end
    -- CIntelData::GetIntelAvailability [I]: available when the category's level reaches the item's,
    -- stale when it does not but the data's `stale_intel` keeps it
    local function availability(us, them, name)
        local it = item_of(name)
        if not it then return "none" end
        if category_level(us, them, it.cat) >= it.level then return "available" end
        local d = intel_data(us, them, false)
        local st = d and world.field(d, "stale_intel")
        if type(st) == "table" and (world.field(st, name) ~= nil or H.list_has(st, name)) then return "stale" end
        for _, v in ipairs(type(st) == "table" and world.list(st) or {}) do
            if v == name then return "stale" end
        end
        return "none"
    end
    -- has_intel = { who intel } (CHasIntelTrigger 0x3c271e0), has_stale_intel (0x3c27660)
    for k, want in pairs({ has_intel = "available", has_stale_intel = "stale" }) do
        TRIG[k] = function(e, ctx)
            local us = this_country(ctx)
            if not us or e.value.text then return false end
            local who = param_country(e.value, "who", ctx)
            local name = param_text(e.value, "intel")
            if not who or not name then return false end
            sync()
            return availability(us, who, name) == want
        end
    end
    -- intel_level = { level <op> <name> system } (CIntelLevelTrigger 0x3b9ee00): our intel level of
    -- the system (the country's `intel_level` list by system index) against the named level (none,
    -- low, medium, high, full: 0..4 [I])
    local INTEL_LEVELS = { none = 0, low = 1, medium = 2, high = 3, full = 4 }
    TRIG["intel_level"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local s = H.param_scope(e.value, "system", ctx)
        local x = H.param(e.value, "level")
        if not s or not x then return false end
        local sid = s.kind == "system" and s.id or nil
        if not sid and rawget(_G, "E") and E.system_of then sid = tonumber(E.system_of(s.kind, s.id)) end
        if not sid then return false end
        local want = INTEL_LEVELS[x.value.text or ""] or tonumber(x.value.text)
        if not want then return false end
        local block = world.field(D.country(us), "intel_level")
        local lv = 0
        if type(block) == "table" then lv = tonumber(world.list(block)[(sid % 16777216) + 1]) or 0 end
        return H.compare(lv, x.op, want)
    end

    -- ------------------------------------------------------------------------------------------
    -- envoys (leaders of class envoy, `location = { type assignment id }`)

    local function envoys_of(us)
        local out = {}
        for _, l in ipairs(D.id_list(world.field(D.country(us), "owned_leaders"))) do
            local o = world.object("leader", l)
            if o and tostring(world.field(o, "class") or ""):gsub('"', "") == "envoy" then
                out[#out + 1] = { id = l, block = o, loc = world.field(o, "location") }
            end
        end
        return out
    end
    H.envoys_of = envoys_of
    local function assignment(env)
        local loc = env.loc
        if type(loc) ~= "table" then return nil end
        return world.field(loc, "type"), world.field(loc, "assignment"), D.ref(world.field(loc, "id"))
    end
    -- is_improving_relations_with / is_harming_relations_with = <country> [I: an envoy of ours at the
    -- country (`type = empire`) with that assignment]
    for k, want in pairs({ is_improving_relations_with = "improve_relations", is_harming_relations_with = "harm_relations" }) do
        TRIG[k] = pair_trigger(function(us, them)
            for _, env in ipairs(envoys_of(us)) do
                local t, a, id = assignment(env)
                if t == "empire" and a == want and id == them then return true end
            end
            return false
        end)
    end
    -- num_envoys_to_federation / num_envoys_to_galcom <op> n (CNumEnvoysToFederation 0x3be4fe0: the
    -- country's leaders whose location is the federation / the galactic community)
    for k, want in pairs({ num_envoys_to_federation = "federation", num_envoys_to_galcom = "galactic_community" }) do
        H.num_trigger(k, function(ctx)
            local us = this_country(ctx)
            if not us then return 0 end
            local n = 0
            for _, env in ipairs(envoys_of(us)) do
                if assignment(env) == want then n = n + 1 end
            end
            return n
        end)
    end
    -- envoy_opinion_change = { who value } (CEnvoyOpinionChangeTrigger 0x3b5c140 ->
    -- CRelation::GetEnvoyOpinionEffect): our relation towards who, its envoy_opinion_positive +
    -- envoy_opinion_negative [I: the sum]
    TRIG["envoy_opinion_change"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local who = param_country(e.value, "who", ctx)
        if not who then return false end
        sync()
        local r = D.relation(us, who)
        local v = H.num(r and world.field(r, "envoy_opinion_positive")) + H.num(r and world.field(r, "envoy_opinion_negative"))
        return compare_value(v, e, ctx)
    end
    -- remove_envoys_to = <country> (CRemoveEnvoysToEffect 0x37f38e0): our envoys at the country
    -- (improving or harming relations) and our spy network's envoy against it unassigned
    -- (CLeaderLocation::SetLeader: no location), the country's relation towards us loses them from
    -- its `foreign_envoys` (CleanupForeignEnvoys)
    EFF["remove_envoys_to"] = function(e, ctx)
        local us = this_country(ctx)
        local them = us and target_country(e, ctx)
        if not them then return end
        sync()
        local nets = {}
        for _, id in ipairs(H.all("spy_network")) do
            local n = H.object("spy_network", id)
            if n and D.ref(world.field(n, "owner")) == us and D.ref(world.field(n, "target")) == them then nets[id] = n end
        end
        local n = 0
        for _, env in ipairs(envoys_of(us)) do
            local t, _, id = assignment(env)
            if (t == "empire" and id == them) or (t == "spy_network" and nets[id]) then
                H.remove_key(env.block, "location")
                local loc = {}
                world.append(loc, "type", "none")
                world.append(loc, "assignment", "none")
                world.append(loc, "id", H.NO_ID)
                world.append(env.block, "location", loc)
                H.list_remove(D.relation(them, us), "foreign_envoys", env.id)
                if t == "spy_network" then H.remove_key(nets[id], "leader") end
                n = n + 1
            end
        end
        if n > 0 then H.script_write() end
    end
    -- has_envoy_cooldown = yes/no (CHasEnvoyCooldownTrigger 0x3b9bec0): an envoy (an error
    -- otherwise) whose location's assignment changed recently [I: the leader's `cooldown`-like
    -- fields are not in the saves read; no cooldown]
    TRIG["has_envoy_cooldown"] = function(e, ctx)
        if ctx.this.kind ~= "leader" then return false end
        local o = world.object("leader", ctx.this.id)
        if not o or tostring(world.field(o, "class") or ""):gsub('"', "") ~= "envoy" then return false end
        local cd = D.date_days(world.field(o, "cooldown"))
        return ((cd ~= nil and cd > eval.today())) == yes(e)
    end
    -- envoy_location_country (scopes.log: an envoy to the empire it is appointed to): its location's
    -- country (`type = empire`)
    LINKS["envoy_location_country"] = function(cur)
        if cur.kind ~= "leader" then return nil end
        local o = world.object("leader", cur.id)
        local loc = o and world.field(o, "location")
        if type(loc) ~= "table" or world.field(loc, "type") ~= "empire" then return nil end
        local c = D.ref(world.field(loc, "id"))
        return (c and D.alive(c)) and S("country", c) or nil
    end

    -- ------------------------------------------------------------------------------------------
    -- power, weight, the AI

    -- diplomacy_weight <op> x (CDiplomacyWeightTrigger 0x3b89f40: CCountry +0x2f40, a modifier total
    -- the game recomputes) [I: not in the save; the engine's value when it has one, else the
    -- country's economy, fleet and technology power summed as the base diplomatic weight's
    -- contributions]
    H.num_trigger("diplomacy_weight", function(ctx)
        local us = this_country(ctx)
        if not us then return nil end
        local E = rawget(_G, "E")
        if E and E.diplomatic_weight then return E.diplomatic_weight(us) end
        local c = D.country(us)
        return H.num(world.field(c, "economy_power")) + H.num(world.field(c, "military_power"))
            + H.num(world.field(c, "tech_power"))
    end)
    -- relative_power = { who category value <op> <level> } (CRelativePowerTrigger 0x3bcac00 ->
    -- CalculateRelativePower): our power over theirs in the category (fleet: military_power,
    -- economy, technology; all: weighted by RELATIVE_POWER_FLEET/ECONOMY/TECH_MULT), the ratio's
    -- level: < 1/OVERWHELMING pathetic, < 1/SUPERIOR inferior, <= SUPERIOR equivalent [I: the
    -- boundary], <= OVERWHELMING superior, else overwhelming; a federation sums its members
    local POWER_LEVELS = { pathetic = 0, inferior = 1, equivalent = 2, superior = 3, overwhelming = 4 }
    local function power(ids, cat)
        local p = 0
        for _, id in ipairs(ids) do
            local c = D.country(id)
            local f, ec, t = H.num(world.field(c, "military_power")), H.num(world.field(c, "economy_power")), H.num(world.field(c, "tech_power"))
            if cat == "fleet" then p = p + f
            elseif cat == "economy" then p = p + ec
            elseif cat == "technology" then p = p + t
            else
                p = p + f * H.define("NAI", "RELATIVE_POWER_FLEET_MULT", 2) + ec * H.define("NAI", "RELATIVE_POWER_ECONOMY_MULT", 3)
                    + t * H.define("NAI", "RELATIVE_POWER_TECH_MULT", 1)
            end
        end
        return p
    end
    TRIG["relative_power"] = function(e, ctx)
        if e.value.text then return false end
        local sc = ctx.this
        local ours
        if sc.kind == "country" and D.alive(sc.id) then ours = { sc.id }
        elseif sc.kind == "federation" and D.fed_obj(sc.id) then ours = D.members(sc.id)
        else return false end
        local who = param_country(e.value, "who", ctx)
        local x = H.param(e.value, "value")
        if not who or not x then return false end
        local cat = param_text(e.value, "category") or "all"
        sync()
        local a, b = power(ours, cat), power({ who }, cat)
        local ratio = b > 0 and a / b or (a > 0 and math.huge or 1)
        local sup = H.define("NAI", "RELATIVE_POWER_SUPERIOR", 1.5)
        local over = H.define("NAI", "RELATIVE_POWER_OVERWHELMING", 2.5)
        local lv
        if ratio < 1 / over then lv = 0 elseif ratio < 1 / sup then lv = 1 elseif ratio <= sup then lv = 2
        elseif ratio <= over then lv = 3 else lv = 4 end
        local want = POWER_LEVELS[x.value.text or ""]
        if not want then return false end
        return H.compare(lv, x.op, want)
    end
    -- has_attitude_behavior = { target behavior } (CHasAttitudeBehavior 0x3b60960): the AI's
    -- attitude towards the target (CCountryAI::GetAttitude), its behaviour list (common/
    -- ai_attitudes `behaviour = { attack = yes ... }`) has the named one
    TRIG["has_attitude_behavior"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local them = param_country(e.value, "target", ctx)
        local want = param_text(e.value, "behavior")
        if not them or not want or not D.has_ai(us) then return false end
        sync()
        local att = D.attitude(us, them)
        local d = att and H.def("common/ai_attitudes", att)
        local b = d and H.def_field(d, "behaviour")
        return type(b) == "table" and require("engine.defs").field(b, want) == "yes"
    end
    -- ai_wants_to_negotiate_agreement (CAiWantsToNegotiateAgreementTrigger): the AI's wish to
    -- renegotiate an agreement [I: the AI's agreement evaluation is not ported; an AI subject or
    -- overlord whose agreement's preset no longer matches its terms]
    TRIG["ai_wants_to_negotiate_agreement"] = function(e, ctx)
        local us = this_country(ctx)
        local r = false
        if us and D.has_ai(us) then
            sync()
            for _, a in ipairs(D.agreements()) do
                local o, t = D.ref(world.field(a.block, "owner")), D.ref(world.field(a.block, "target"))
                if o == us or t == us then
                    local td = world.field(a.block, "term_data")
                    if type(td) == "table" and world.field(td, "agreement_preset") == nil then r = true break end
                end
            end
        end
        if e.value.text == "no" then return not r end
        return r
    end

    -- run_ai_strategic_war_data = yes (CRunAIStrategicWarDataEffect 0x37857f0 [V]: the country's AI
    -- (+0x1ad8) gets CCountryAI::SetNeedAIStrategicWarData, a request for its strategic war data to
    -- be computed again; not saved): the request kept in the script state
    -- (eval.state.ai_war_data_requests[country]) for engine.ai
    EFF["run_ai_strategic_war_data"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text ~= "yes" then return end
        local r = eval.state.ai_war_data_requests or {}
        eval.state.ai_war_data_requests = r
        r[us] = true
        H.script_write()
    end

    -- force_show_diplomacy / force_show_espionage = <country> (CForceShowDiplomacyEffectBase
    -- 0x37f3c30): for the local human only, CInGameIdler::ShowDiplomacyView on the target (the
    -- diplomacy or espionage tab); the request is left in the script state (eval.state.ui_request)
    -- for the front end to show
    for k, tab in pairs({ force_show_diplomacy = "diplomacy", force_show_espionage = "espionage" }) do
        EFF[k] = function(e, ctx)
            local us = this_country(ctx)
            local them = us and target_country(e, ctx)
            if not them or not D.flag(us, them, "communications") then return end
            eval.state.ui_request = { view = "diplomacy", tab = tab, country = us, target = them }
            H.script_write()
        end
    end
end
