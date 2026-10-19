-- simscript/handlers/empire_effects.lua : the empire's effects (species and traits, leaders, the
-- council, policies and edicts, ethics, civics and the government, pop groups and factions) and
-- the random_ / ordered_ iterators over the empire's lists with their `weights` and `inverse`.
-- Loaded by handlers/empire.lua with its helpers (H). docs/script_empire.md has each one's class.

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local sync = I.sync
    local EFF, LISTS = eval.EFF, eval.LISTS

    -- ------------------------------------------------------------------------------------------
    -- iterators: random_<list> = { limit weights <effects> } and ordered_<list> = { limit
    -- order_by position max inverse <effects> } (CRandomIteratorEffect / COrderedIteratorEffect
    -- [I: the weighted draw's arithmetic]); every_<list> is the walker's own

    local SKIP = {}
    for k in pairs(I.ITER_PARAMS) do SKIP[k] = true end
    SKIP.weights, SKIP.inverse = true, true

    local function iterate(kind, lname)
        return function(e, ctx)
            if e.value.text then return end
            local f = LISTS[lname]
            local list = f and f(ctx.this, ctx) or {}
            local limit, order_by, weights, inverse, position, max = nil, nil, nil, false, 0, 1
            for _, x in ipairs(e.value) do
                if x.op and x.key then
                    local xk = x.key.text:lower()
                    if xk == "limit" then limit = x.value
                    elseif xk == "order_by" then order_by = x.value
                    elseif xk == "weights" and x.value.text == nil then weights = x.value
                    elseif xk == "inverse" then inverse = x.value.text == "yes"
                    elseif xk == "position" then position = eval.value(x.value, ctx, x) or 0
                    elseif xk == "max" then max = eval.value(x.value, ctx, x) or 1 end
                end
            end
            local chosen = {}
            for _, s2 in ipairs(list) do
                if not limit or eval.trigger(limit, I.push(ctx, s2)) then chosen[#chosen + 1] = s2 end
            end
            local SR = eval.scope_iter
            local loop = SR and SR.begin(ctx)
            if kind == "random" then
                if #chosen == 0 then return end
                local r = loop and SR.draw(loop) or eval.rand()
                if weights then
                    local ws, total = {}, 0
                    for i, s2 in ipairs(chosen) do
                        ws[i] = math.max(0, eval.weight(weights, I.push(ctx, s2), 1))
                        total = total + ws[i]
                    end
                    if total <= 0 then return end
                    local at = (r % 1000000) / 1000000 * total
                    local pick = chosen[#chosen]
                    for i, w in ipairs(ws) do
                        if at < w then pick = chosen[i] break end
                        at = at - w
                    end
                    chosen = { pick }
                else
                    chosen = { chosen[r % #chosen + 1] }
                end
            else
                local keyed = {}
                for i, s2 in ipairs(chosen) do
                    keyed[i] = { s2, order_by and eval.value(order_by, I.push(ctx, s2), e) or 0, i }
                end
                table.sort(keyed, function(a, b)
                    if a[2] ~= b[2] then
                        if inverse then return a[2] < b[2] end
                        return a[2] > b[2]
                    end
                    return a[3] < b[3]
                end)
                chosen = {}
                for i = position + 1, math.min(#keyed, position + max) do chosen[#chosen + 1] = keyed[i][1] end
            end
            for _, s2 in ipairs(chosen) do
                local c = I.push(ctx, s2)
                if loop then SR.element(loop, c, kind) end
                eval.effect(e.value, c, SKIP)
            end
        end
    end
    for _, l in ipairs({ "existing_species_traits", "owned_pop_species", "pool_leader", "trait_available_for_species",
        "trait_of_species", "galaxy_species", "owned_leader", "owned_species" }) do
        EFF["random_" .. l] = iterate("random", l)
        EFF["ordered_" .. l] = iterate("ordered", l)
    end

    -- ------------------------------------------------------------------------------------------
    -- helpers for the effects

    local unq, obj, field, num, def, dfield = H.unq, H.obj, H.field, H.num, H.def, H.dfield
    local params, text_of, target, tokens, set_of = H.params, H.text_of, H.target, H.tokens, H.set_of
    local stats = I.stats
    local floor = math.floor

    -- an effect that changes the world counts as a script change for the walker's statistics
    local function wrote()
        stats.script = stats.script + 1
    end
    local function int_value(e, ctx)
        local v = eval.value(e.value, ctx, e)
        return v and (v < 0 and -floor(-v) or floor(v)) or nil
    end
    local function today_text()
        return (tostring(world.meta.date or ""):gsub('"', ""))
    end
    local function add_days(days)
        local t = H.now_days() + days
        local y = floor(t / 360)
        local r = t % 360
        return string.format("%d.%02d.%02d", y, floor(r / 30) + 1, r % 30 + 1)
    end
    local function quoted(v) return '"' .. tostring(v) .. '"' end
    -- the scope's leader (a leader scope)
    local function L(ctx) return ctx.this.kind == "leader" and H.leader(ctx.this.id) or nil end
    local function C(ctx) return ctx.this.kind == "country" and obj("country", ctx.this.id) or nil end
    -- a block statement `key = { ... }` set
    local function set_block(o, key, block)
        local en = world.entry(o, key)
        if en then world.set_entry(o, en, block)
        else world.append_entry(o, { key = { text = key }, op = "=", value = block }) end
    end
    local function remove_key(o, key)
        local en = world.entry(o, key)
        if en then world.remove_entry(o, en) return true end
        return false
    end
    -- a leader's traits (repeated `traits = "x"` statements)
    local function remove_leader_trait(l, t)
        for i = #l, 1, -1 do
            local x = l[i]
            if x.op and x.key and x.key.text == "traits" and unq(x.value.text) == t then
                world.remove_entry(l, x)
                return true
            end
        end
        return false
    end
    local function add_leader_trait(l, t)
        if H.set_of(H.leader_traits(l))[t] then return false end
        world.append(l, "traits", t, true)
        return true
    end
    local function name_block(text, literal)
        local b = {}
        world.append(b, "key", text, true)
        if literal then world.append(b, "literal", "yes") end
        return b
    end

    -- ------------------------------------------------------------------------------------------
    -- leaders

    -- add_age / set_age = <int> (CAddAgeEffect, CSetAgeEffect): the leader's `age`
    EFF["add_age"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        world.set(l, "age", num(field(l, "age")) + (int_value(e, ctx) or 0))
        wrote()
    end
    EFF["set_age"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        world.set(l, "age", math.max(0, int_value(e, ctx) or 0))
        wrote()
    end
    -- add_skill / add_skill_without_trait_selection / set_skill (CAddSkillEffect, ...): the
    -- leader's `level`, within 1 and LEADER_MAX_SKILL_CAP [I: the trait selections a level grants
    -- not drawn]
    local function set_level(l, v)
        local cap = 10
        for _, d in pairs(require("engine.defs").folder("common/defines")) do
            local g = H.dfield(d.block, "NGameplay")
            local x = g and tonumber(H.dfield(g, "LEADER_MAX_SKILL_CAP"))
            if x then cap = x end
        end
        world.set(l, "level", math.max(1, math.min(cap, v)))
    end
    EFF["add_skill"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        set_level(l, num(field(l, "level")) + (int_value(e, ctx) or 0))
        wrote()
    end
    EFF["add_skill_without_trait_selection"] = EFF["add_skill"]
    EFF["set_skill"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        set_level(l, int_value(e, ctx) or 1)
        wrote()
    end
    -- the leader traits of a rarity the leader's class may take (common/traits with leader_class
    -- holding the class; their inline script's RARITY) [I]
    local function leader_trait_pool(l, rarity)
        local class = unq(field(l, "class"))
        local out = {}
        for k, d in pairs(require("engine.defs").folder("common/traits")) do
            local b = d.block
            if H.is_leader_trait(b) and set_of(tokens(dfield(b, "leader_class")))[class] then
                local is = dfield(b, "inline_script")
                local r = type(is) == "table" and unq(dfield(is, "RARITY")) or nil
                if r == rarity then out[#out + 1] = k end
            end
        end
        table.sort(out)
        return out
    end
    local function pick_trait(l, key, ctx)
        if key ~= "random_common" and key ~= "random_negative" then return key end
        local pool = leader_trait_pool(l, key == "random_common" and "common" or "negative")
        local have = set_of(H.leader_traits(l))
        local free = {}
        for _, k in ipairs(pool) do if not have[k] then free[#free + 1] = k end end
        if #free == 0 then return nil end
        return free[eval.rand() % #free + 1]
    end
    -- add_trait = <trait>|random_common|random_negative or { trait consume_selection show_message }
    -- (CAddTraitEffect): a leader's `traits`
    EFF["add_trait"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        local key = e.value.text and unq(e.value.text) or text_of(params(e).trait)
        key = key and pick_trait(l, key, ctx)
        if key and add_leader_trait(l, key) then wrote() end
    end
    -- add_timed_trait = { trait days|months|years } (CAddTimedTraitEffect): the trait and its end
    -- (`timed_traits = { { trait days } }`) [I key]
    EFF["add_timed_trait"] = function(e, ctx)
        local l = L(ctx)
        if not l or e.value.text then return end
        local p = params(e)
        local key = text_of(p.trait)
        if not key then return end
        local days = (p.days and eval.value(p.days.value, ctx, p.days)) or (p.months and eval.value(p.months.value, ctx, p.months) * 30)
            or (p.years and eval.value(p.years.value, ctx, p.years) * 360) or 0
        add_leader_trait(l, key)
        local list = world.child(l, "timed_traits")
        local b = {}
        world.append(b, "trait", key, true)
        world.append(b, "days", floor(days))
        world.push(list, b)
        wrote()
    end
    -- remove_trait = <trait>|all_negative (CRemoveTraitEffect)
    local function trait_negative(t)
        local b = H.trait_def(t)
        local is = b and dfield(b, "inline_script")
        local r = type(is) == "table" and unq(dfield(is, "RARITY")) or nil
        return r == "negative" or (tonumber(dfield(b, "cost")) or 0) < 0
    end
    local function remove_traits(l, which)
        local n = 0
        for _, t in ipairs(H.leader_traits(l)) do
            if which == "all" or (which == "negative") == trait_negative(t) then
                if remove_leader_trait(l, t) then n = n + 1 end
            end
        end
        return n
    end
    EFF["remove_trait"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local key = unq(e.value.text)
        local n = key == "all_negative" and remove_traits(l, "negative") or (remove_leader_trait(l, key) and 1 or 0)
        if n > 0 then wrote() end
    end
    EFF["remove_all_traits"] = function(_, ctx) local l = L(ctx) if l and remove_traits(l, "all") > 0 then wrote() end end
    EFF["remove_all_negative_traits"] = function(_, ctx) local l = L(ctx) if l and remove_traits(l, "negative") > 0 then wrote() end end
    EFF["remove_all_positive_traits"] = function(_, ctx) local l = L(ctx) if l and remove_traits(l, "positive") > 0 then wrote() end end
    -- change_background_ethic = <ethic> (CChangeBackgroundEthicEffect): the leader's `ethic`
    EFF["change_background_ethic"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        world.set(l, "ethic", quoted(unq(e.value.text)))
        wrote()
    end
    -- change_leader_class = <class>|<leader target> (CChangeLeaderClassEffect): the leader's `class`
    EFF["change_leader_class"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local sc = target(e, ctx)
        local class = sc and sc.kind == "leader" and unq(field(H.leader(sc.id), "class")) or unq(e.value.text)
        if not def("common/leader_classes", class) then return end
        world.set(l, "class", quoted(class))
        wrote()
    end
    -- change_leader_portrait = <portrait>|<species target> (CChangeLeaderPortraitEffect): the
    -- leader's `portrait` (a species': its portrait)
    EFF["change_leader_portrait"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local sc = target(e, ctx)
        local sid = sc and H.species_of(sc)
        local p = sid and unq(field(H.species(sid), "portrait")) or unq(e.value.text)
        world.set(l, "portrait", quoted(p))
        wrote()
    end
    -- set_gender = <gender> (CSetGenderEffect)
    EFF["set_gender"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        world.set(l, "gender", unq(e.value.text))
        wrote()
    end
    -- set_cooldown = <days> (CSetCooldownEffect): the leader's `cooldown`
    EFF["set_cooldown"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        world.set(l, "cooldown", math.max(0, int_value(e, ctx) or 0))
        wrote()
    end
    -- set_years_served = <leader> (CSetYearsServedEffect): the target's recruitment date
    EFF["set_years_served"] = function(e, ctx)
        local l = L(ctx)
        local sc = target(e, ctx)
        local o = sc and sc.kind == "leader" and H.leader(sc.id)
        if not l or not o then return end
        local d = field(o, "recruitment_date")
        if d then world.set(l, "recruitment_date", quoted(unq(d))) wrote() end
    end

    -- ------------------------------------------------------------------------------------------
    -- the government: civics, origin, type, its cooldown

    local function gov_of(c) return world.child(c, "government") end
    local function civic_list(c) return world.child(gov_of(c), "civics") end
    local function civics_of(c)
        local out = {}
        for _, v in ipairs(world.list(civic_list(c))) do out[#out + 1] = unq(v) end
        return out
    end
    -- force_add_civic = <civic> (CForceAddCivicEffect): the government's civics, unchecked
    EFF["force_add_civic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local civ = unq(e.value.text)
        if set_of(civics_of(c))[civ] or not def("common/governments/civics", civ) then return end
        world.append_value(civic_list(c), civ, true)
        wrote()
    end
    -- force_remove_civic = <civic>|<index> and force_remove_civic_by_index = <index>
    -- (CForceRemoveCivicEffect): a civic out of the government's (an index: 1-based [I])
    local function remove_civic_at(c, i)
        local list = civic_list(c)
        local n = 0
        for k, x in ipairs(list) do
            if x.text then
                n = n + 1
                if n == i then world.remove_at(list, k) return true end
            end
        end
        return false
    end
    EFF["force_remove_civic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local v = unq(e.value.text)
        local i = tonumber(v)
        if i then
            if remove_civic_at(c, i) then wrote() end
            return
        end
        for k, x in ipairs(civic_list(c)) do
            if x.text and unq(x.text) == v then world.remove_at(civic_list(c), k) wrote() return end
        end
    end
    EFF["force_remove_civic_by_index"] = function(e, ctx)
        local c = C(ctx)
        if not c then return end
        local i = int_value(e, ctx)
        if i and remove_civic_at(c, i) then wrote() end
    end
    -- set_origin = <origin> (CSetOriginEffect): the government's origin (the origin's effects not run)
    EFF["set_origin"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local o = unq(e.value.text)
        if not def("common/governments/civics", o) then return end
        world.set(gov_of(c), "origin", quoted(o))
        wrote()
    end
    -- set_country_type = <type> (CSetCountryTypeEffect): the country's `type`
    EFF["set_country_type"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local t = unq(e.value.text)
        if not def("common/country_types", t) then return end
        world.set(c, "type", quoted(t))
        world.set(c, "last_changed_country_type", quoted(today_text()))
        wrote()
    end
    -- set_government_cooldown = <days>|default|no (CSetGovernmentCooldownEffect): government_date
    -- (default: GOVERNMENT_COOLDOWN_YEARS; no: none)
    EFF["set_government_cooldown"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local v = unq(e.value.text)
        if v == "no" then
            if remove_key(c, "government_date") then wrote() end
            return
        end
        local days = v == "default" and 20 * 360 or int_value(e, ctx) or 0
        world.set(c, "government_date", quoted(add_days(days)))
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- policies and the council's agenda

    local function policy_entry(c, group)
        for _, b in ipairs(world.blocks(field(c, "active_policies"))) do
            if unq(field(b, "policy")) == group then return b end
        end
        return nil
    end
    -- set_policy_cooldown = <group> (CSetPolicyCooldownEffect): its entry's date today
    EFF["set_policy_cooldown"] = function(e, ctx)
        local c = C(ctx)
        local b = c and e.value.text and policy_entry(c, unq(e.value.text))
        if not b then return end
        world.set(b, "date", quoted(today_text()))
        wrote()
    end
    -- reset_policy_cooldowns (CResetPolicyCooldownsEffect): every entry's date cleared
    EFF["reset_policy_cooldowns"] = function(_, ctx)
        local c = C(ctx)
        if not c then return end
        for _, b in ipairs(world.blocks(field(c, "active_policies"))) do
            world.set(b, "date", quoted("0.01.01"))
        end
        wrote()
    end
    -- set_council_agenda = <agenda> (CSetCouncilAgendaEffect → CGovernment::SetCouncilAgenda): the
    -- agenda, its progress 0
    EFF["set_council_agenda"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local a = unq(e.value.text)
        if not def("common/council_agendas", a) then return end
        world.set(gov_of(c), "council_agenda", quoted(a))
        world.set(gov_of(c), "council_agenda_progress", 0)
        wrote()
    end
    -- the agenda's cost (CCouncilAgenda::GetCost: agenda_cost)
    local function agenda_cost(c)
        local key = unq(field(gov_of(c), "council_agenda"))
        local b, file = def("common/council_agendas", key)
        local en = b and world.entry(b, "agenda_cost")
        if not en then return nil end
        local ok, v = pcall(eval.value, en.value, eval.new_ctx(S("country", 0), nil, nil, file), en)
        return ok and tonumber(v) or nil
    end
    -- add_council_agenda_progress_percent = <-1..1> (CAddCouncilAgendaProgressPercentEffect): that
    -- part of the agenda's cost
    EFF["add_council_agenda_progress_percent"] = function(e, ctx)
        local c = C(ctx)
        if not c then return end
        local cost = agenda_cost(c)
        if not cost then return end
        local g = gov_of(c)
        local p = num(field(g, "council_agenda_progress")) + cost * (eval.value(e.value, ctx, e) or 0)
        world.set(g, "council_agenda_progress", math.max(0, floor(p * 100000 + 0.5) / 100000))
        wrote()
    end
    -- finish_council_agenda (CFinishCouncilAgendaEffect → CGovernment::FinishAgenda): the agenda's
    -- finish_modifier for COUNCIL_AGENDA_FINISH_MODIFIER_DURATION days, its effect, its cooldown
    -- (council_agenda_cooldowns), no agenda, progress 0
    EFF["finish_council_agenda"] = function(e, ctx)
        local c = C(ctx)
        if not c or e.value.text == "no" then return end
        local g = gov_of(c)
        local key = unq(field(g, "council_agenda"))
        local b, file = def("common/council_agendas", key)
        if not b then return end
        local fm = unq(dfield(b, "finish_modifier"))
        if fm then
            local items = world.child(world.child(c, "timed_modifier"), "items")
            local it = {}
            world.append(it, "modifier", fm, true)
            world.append(it, "days", 3600)
            world.push(items, it)
        end
        local eff = dfield(b, "effect")
        if type(eff) == "table" then eval.effect(eff, eval.new_ctx(ctx.this, nil, nil, file)) end
        local cd = tonumber(dfield(b, "agenda_cooldown")) or 10800
        local entry = {}
        world.append(entry, "council_agenda", key, true)
        world.append(entry, "start_date", add_days(cd), true)
        world.push(world.child(g, "council_agenda_cooldowns"), entry)
        remove_key(g, "council_agenda")
        world.set(g, "council_agenda_progress", 0)
        wrote()
    end
end
