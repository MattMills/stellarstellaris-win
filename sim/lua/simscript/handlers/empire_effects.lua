-- simscript/handlers/empire_effects.lua : the empire's effects (species and traits, leaders, the
-- council, policies and edicts, ethics, civics and the government, pop groups and factions).
-- Loaded by handlers/empire.lua with its helpers (H). docs/script_empire.md has each one's class.

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local sync = I.sync
    local EFF, LISTS = eval.EFF, eval.LISTS

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
    local function name_block(text, literal)
        local b = {}
        world.append(b, "key", text, true)
        if literal then world.append(b, "literal", "yes") end
        return b
    end

    -- ------------------------------------------------------------------------------------------
    -- the government: authority, civics, origin, type, its cooldown, edicts

    local SR = require("engine.script.scope_random")
    local function gov_of(c) return world.child(c, "government") end
    local function civic_list(c) return world.child(gov_of(c), "civics") end
    local function civics_of(c)
        local out = {}
        for _, v in ipairs(world.list(field(gov_of(c), "civics"))) do out[#out + 1] = unq(v) end
        return out
    end
    local function define(group, key, default)
        return H.define and H.define(group, key, default) or default
    end
    -- an on_action of the country, its scope random a copy of the effect's [I: the seed]
    local function fire(name, scope, ctx)
        local ok = pcall(require("simscript.events").on_action, name, scope, nil, SR.copy(eval.scope_rng(ctx)))
        if not ok then I.miss("effect", name, ctx, nil) end
    end
    -- a folder's definitions in the database's order (the files' load order, then the line)
    local ordered_cache = {}
    local function ordered(folder)
        local list = ordered_cache[folder]
        if list then return list end
        list = {}
        for name, d in pairs(require("engine.defs").folder(folder)) do
            if type(d) == "table" and d.block then list[#list + 1] = { name = name, def = d } end
        end
        table.sort(list, function(a, b)
            if a.def.file ~= b.def.file then return tostring(a.def.file) < tostring(b.def.file) end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
        ordered_cache[folder] = list
        return list
    end
    H.ordered = ordered
    -- a government restriction block (a civic's or authority's potential / possible: `ethics`,
    -- `authority`, `civics`, `origin`, `species_class`, `species_archetype`, `country_type`, each
    -- with value / OR / NOR / NOT / AND of values) against a configuration (sets of names)
    local RESTRICT = { ethics = true, authority = true, civics = true, origin = true, species_class = true,
        species_archetype = true, country_type = true }
    local function values_hold(b, set, mode)
        local any, all = false, true
        for _, x in ipairs(b) do
            if x.op and x.key then
                local k = x.key.text
                local r
                if k == "value" then r = set[unq(x.value.text)] == true
                elseif k == "OR" and type(x.value) == "table" then r = values_hold(x.value, set, "or")
                elseif k == "NOR" and type(x.value) == "table" then r = not values_hold(x.value, set, "or")
                elseif k == "NOT" and type(x.value) == "table" then r = not values_hold(x.value, set, "or")
                elseif k == "AND" and type(x.value) == "table" then r = values_hold(x.value, set, "and")
                end
                if r ~= nil then
                    if r then any = true else all = false end
                end
            end
        end
        if mode == "or" then return any end
        return all
    end
    local function restrictions_hold(b, config)
        if type(b) ~= "table" then return true end
        for _, x in ipairs(b) do
            if x.op and x.key and RESTRICT[x.key.text] and type(x.value) == "table" then
                if not values_hold(x.value, config[x.key.text] or {}, "and") then return false end
            end
        end
        return true
    end
    local function config_of(c, auth, civics, ethics_list)
        local set = function(list) local s = {} for _, v in ipairs(list) do s[v] = true end return s end
        local sid = tonumber(field(c, "founder_species_ref"))
        local sp = sid and H.species(sid)
        return {
            ethics = set(ethics_list or H.country_ethics(c)), authority = { [auth or ""] = true },
            civics = set(civics), origin = { [unq(field(gov_of(c), "origin")) or ""] = true },
            species_class = { [sp and unq(field(sp, "class")) or ""] = true },
            species_archetype = { [sid and H.archetype_of(sid) or ""] = true },
            country_type = { [unq(field(c, "type")) or ""] = true },
        }
    end
    local function same_list(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do if a[i] ~= b[i] then return false end end
        return true
    end
    local TITLE_KEYS = { "ruler_title", "ruler_title_female", "heir_title", "heir_title_female" }
    -- CCountry::ClearCustomRulerTitles (0x23803c0) [V]: the four custom titles (the country's) out
    local function clear_titles(c)
        local n = 0
        for _, k in ipairs(TITLE_KEYS) do if remove_key(c, k) then n = n + 1 end end
        return n
    end
    -- CCountry::SetGovernmentAndCivics (0x2341ee0 → 0x237f650) [V]: the same authority, civics (in
    -- order) and origin: nothing. A new authority with an election under way: one global draw.
    -- on_pre_government_changed, the government written, government_date today (+
    -- GOVERNMENT_COOLDOWN_YEARS with cooldown), the custom titles cleared,
    -- on_post_government_changed, then one global draw (UpdateNextElectionDate; next_election not
    -- recomputed [I]; nor the government's type, councillors or heir [I])
    local function set_government(ctx, cid, c, auth, civics, origin, cooldown)
        local g = gov_of(c)
        local cur_auth, cur_origin = unq(field(g, "authority")), unq(field(g, "origin"))
        origin = origin or cur_origin
        if auth == cur_auth and origin == cur_origin and same_list(civics, civics_of(c)) then return false end
        if auth ~= cur_auth and field(c, "election") ~= nil then eval.rand() end
        local scope = S("country", cid)
        fire("on_pre_government_changed", scope, ctx)
        if auth then world.set(g, "authority", quoted(auth)) end
        local list = {}
        for _, v in ipairs(civics) do list[#list + 1] = { text = v, quoted = true } end
        set_block(g, "civics", list)
        if origin then world.set(g, "origin", quoted(origin)) end
        local years = cooldown and define("NGameplay", "GOVERNMENT_COOLDOWN_YEARS", 20) or 0
        world.set(c, "government_date", quoted(add_days(years * 360)))
        clear_titles(c)
        fire("on_post_government_changed", scope, ctx)
        eval.rand()
        return true
    end
    H.set_government = set_government

    local function civic_cost(name)
        local b = def("common/governments/civics", name)
        return b and tonumber(dfield(b, "cost")) or 1
    end
    local function weight_of(b, file, ctx)
        local rw = dfield(b, "random_weight")
        if type(rw) ~= "table" then return 1 end
        return eval.weight(rw, eval.new_ctx(ctx.this, nil, nil, file)) or 0
    end
    -- ChooseAuthorityForFilling (0x26a0230) [V]: the authorities whose potential and possible hold,
    -- weighted by random_weight, one global draw
    local function random_authority(c, ctx, civics)
        local cands, ws = {}, {}
        for _, x in ipairs(ordered("common/governments/authorities")) do
            local b = x.def.block
            local cfg = config_of(c, x.name, civics)
            if restrictions_hold(dfield(b, "potential"), cfg) and restrictions_hold(dfield(b, "possible"), cfg) then
                cands[#cands + 1] = x.name
                ws[#ws + 1] = H.raw(weight_of(b, x.def.file, ctx))
            end
        end
        return H.weighted(cands, ws, eval.rand())
    end
    -- DoFillCivics (0x269d410) [V]: while civic points are left, one global draw per pick among the
    -- civics (database order) not chosen, not origins, affordable, whose potential and possible hold
    -- and whose random_weight is over 0
    local function fill_civics(c, ctx, auth, civics, pts)
        while pts > 0 do
            local chosen = {}
            for _, v in ipairs(civics) do chosen[v] = true end
            local cfg = config_of(c, auth, civics)
            local cands, ws = {}, {}
            for _, x in ipairs(ordered("common/governments/civics")) do
                local b = x.def.block
                if not chosen[x.name] and dfield(b, "is_origin") ~= "yes" and civic_cost(x.name) <= pts
                    and restrictions_hold(dfield(b, "potential"), cfg) and restrictions_hold(dfield(b, "possible"), cfg) then
                    local w = weight_of(b, x.def.file, ctx)
                    if w > 0 then
                        cands[#cands + 1] = x.name
                        ws[#ws + 1] = H.raw(w)
                    end
                end
            end
            local pick = H.weighted(cands, ws, eval.rand())
            if not pick then break end
            civics[#civics + 1] = pick
            pts = pts - civic_cost(pick)
        end
        return civics
    end
    -- CCountry::CalcTotalCivicPoints: GOVERNMENT_CIVIC_POINTS_BASE + the country's civic points [I]
    local function civic_points(cid)
        local m = E.modifier and tonumber(E.modifier("country", cid, "country_civic_points")) or 0
        return define("NGameplay", "GOVERNMENT_CIVIC_POINTS_BASE", 2) + math.max(0, m)
    end
    local function has_government(c)
        local ct = def("common/country_types", unq(field(c, "type")))
        return not (ct and dfield(ct, "government") == "no")
    end
    -- change_government = random | <authority> | { authority = random|<key> civics = random|{ civic
    -- = <key>|random ... } cooldown remove_invalid_civics } (CChangeGovernmentEffect 0x37245e0) [V]:
    -- a country type with a government; a random authority (one draw) and random civics filled
    -- (one draw a pick) [I: the restrictions solver's other checks]; SetGovernmentAndCivics
    EFF["change_government"] = function(e, ctx)
        local c = C(ctx)
        if not c or not has_government(c) then return end
        local cid = ctx.this.id
        local auth = unq(field(gov_of(c), "authority"))
        local civics = civics_of(c)
        local auth_random, civ_random, cooldown, remove_invalid = false, false, true, false
        if e.value.text then
            local v = unq(e.value.text)
            if v == "random" then
                auth_random, civ_random, civics = true, true, {}
            else
                auth = v
            end
        else
            local p = params(e)
            local a = p.authority and unq(p.authority.value.text)
            if a == "random" then auth_random = true elseif a then auth = a end
            if p.civics then
                if p.civics.value.text == "random" then
                    civ_random, civics = true, {}
                elseif not p.civics.value.text then
                    civics = {}
                    for _, x in ipairs(p.civics.value) do
                        if x.op and x.key and x.key.text == "civic" and x.value.text then
                            local v = unq(x.value.text)
                            if v == "random" then civ_random = true else civics[#civics + 1] = v end
                        end
                    end
                end
            end
            if p.cooldown then cooldown = p.cooldown.value.text ~= "no" end
            if p.remove_invalid_civics then remove_invalid = p.remove_invalid_civics.value.text == "yes" end
        end
        if auth_random then auth = random_authority(c, ctx, civics) or auth end
        if civ_random then
            if remove_invalid then
                local kept = {}
                for _, v in ipairs(civics) do
                    local b = def("common/governments/civics", v)
                    if b and restrictions_hold(dfield(b, "possible"), config_of(c, auth, civics)) then kept[#kept + 1] = v end
                end
                civics = kept
            end
            local pts = civic_points(cid)
            for _, v in ipairs(civics) do pts = pts - civic_cost(v) end
            civics = fill_civics(c, ctx, auth, civics, pts)
        end
        if set_government(ctx, cid, c, auth, civics, nil, cooldown) then wrote() end
    end
    -- force_add_civic = <civic> (CForceAddCivicEffect 0x3713ab0) [V]: appended, unchecked;
    -- SetGovernmentAndCivics with the cooldown
    EFF["force_add_civic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local civics = civics_of(c)
        civics[#civics + 1] = unq(e.value.text)
        if set_government(ctx, ctx.this.id, c, unq(field(gov_of(c), "authority")), civics, nil, true) then wrote() end
    end
    -- force_remove_civic = <civic> (CForceRemoveCivicEffect 0x3714000) [V]: every occurrence out
    EFF["force_remove_civic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local v = unq(e.value.text)
        local civics = {}
        for _, x in ipairs(civics_of(c)) do if x ~= v then civics[#civics + 1] = x end end
        if set_government(ctx, ctx.this.id, c, unq(field(gov_of(c), "authority")), civics, nil, true) then wrote() end
    end
    -- force_remove_civic_by_index = <1-based index> (CForceRemoveCivicByIndexEffect 0x3714440) [V]
    EFF["force_remove_civic_by_index"] = function(e, ctx)
        local c = C(ctx)
        if not c then return end
        local i = int_value(e, ctx)
        local civics = civics_of(c)
        if not i or i <= 0 or i > #civics then return end
        table.remove(civics, i)
        if set_government(ctx, ctx.this.id, c, unq(field(gov_of(c), "authority")), civics, nil, true) then wrote() end
    end
    -- set_origin = <origin> (CSetOriginEffect 0x37147e0) [V]: SetGovernmentAndCivics without the
    -- cooldown (government_date today); the origin's own effects not run
    EFF["set_origin"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        if set_government(ctx, ctx.this.id, c, unq(field(gov_of(c), "authority")), civics_of(c), unq(e.value.text), false) then
            wrote()
        end
    end
    -- copy_ethos_and_authority = <country> (CCopyCountryAspectEffect<SCopyEthosAndAuthorityImpl>
    -- 0x379ccc0) [V]: the target's ethics and authority, the scope's civics kept,
    -- SetGovernmentAndCivics with the cooldown [I: the restrictions solver's re-pick not modelled;
    -- nor RandomizeRuler, the new ruler it makes]
    EFF["copy_ethos_and_authority"] = function(e, ctx)
        local c = C(ctx)
        local t = target(e, ctx)
        local o = t and t.kind == "country" and obj("country", t.id)
        if not c or not o then return end
        H.write_country_ethics(c, H.country_ethics(o))
        set_government(ctx, ctx.this.id, c, unq(field(gov_of(o), "authority")), civics_of(c), nil, true)
        wrote()
    end
    -- set_country_type = <type> (CSetCountryTypeEffect 0x3723100 → CCountry::SetCountryType 0x233d4f0)
    -- [V]: the same type: nothing; `type`, last_changed_country_type today, on_country_type_changed
    -- [I: the modules rebuilt from the new type and the pre-FTL room not modelled]
    EFF["set_country_type"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local t = unq(e.value.text)
        if not def("common/country_types", t) or unq(field(c, "type")) == t then return end
        world.set(c, "type", quoted(t))
        world.set(c, "last_changed_country_type", quoted(today_text()))
        fire("on_country_type_changed", ctx.this, ctx)
        wrote()
    end
    -- set_government_cooldown = <days>|default|no (CSetGovernmentCooldownEffect 0x3714b30) [V]:
    -- government_date = today + the days (no: 0; default: GOVERNMENT_COOLDOWN_YEARS)
    EFF["set_government_cooldown"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local v = unq(e.value.text)
        local days = v == "no" and 0 or v == "default" and define("NGameplay", "GOVERNMENT_COOLDOWN_YEARS", 20) * 360
            or int_value(e, ctx) or 0
        world.set(c, "government_date", quoted(add_days(days)))
        wrote()
    end
    -- advanced_authority_refresh (CAdvancedAuthorityRefreshEffect 0x37eb970 → CGovernment::
    -- AssignMatchingType 0x1c13950 → GenerateType 0x1c56e50) [V]: the government's `type`: the
    -- common/governments types in load order whose `possible` holds (this the country), each weighed
    -- by its `weight`; one replaces the pick when the pick's weight is not above 0 or its own is
    -- higher; none: no `type`. No draw, no on_action
    EFF["advanced_authority_refresh"] = function(e, ctx)
        local c = C(ctx)
        if not c or e.value.text == "no" then return end
        local g = gov_of(c)
        local pick, pw
        for _, x in ipairs(ordered("common/governments")) do
            local b, file = x.def.block, x.def.file
            local sc = eval.new_ctx(ctx.this, nil, nil, file)
            local pos = dfield(b, "possible")
            if type(pos) ~= "table" or #pos == 0 or eval.trigger(pos, sc) == true then
                local wb = dfield(b, "weight")
                local w = type(wb) == "table" and eval.weight(wb, sc, 0) or tonumber(wb) or 0
                if pick == nil or pw <= 0 or w > pw then pick, pw = x.name, w end
            end
        end
        local cur = unq(field(g, "type"))
        if pick == cur then return end
        if pick then world.set(g, "type", quoted(pick)) else remove_key(g, "type") end
        wrote()
    end
    -- add_edict = <edict> (CAddEdictEffect 0x38035b0 → CCountry::AddEdict 0x2398d90) [V]: active
    -- already: nothing; its cost paid (unchecked; the cost's multiplier not applied [I]); one global
    -- draw seeds the scope its `effect` runs in; on_edict_activated; the entry (length <= 0:
    -- perpetual, date 0)
    EFF["add_edict"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local key = unq(e.value.text)
        local b, file = def("common/edicts", key)
        if not b then return end
        local list = world.child(c, "edicts")
        for _, x in ipairs(world.blocks(list)) do
            if unq(field(x, "edict")) == key then return end
        end
        local res = dfield(b, "resources")
        local cost = type(res) == "table" and dfield(res, "cost")
        local stock = world.path(c, "modules", "standard_economy_module", "resources")
        if type(cost) == "table" and type(stock) == "table" then
            local cctx = eval.new_ctx(ctx.this, nil, nil, file)
            for _, x in ipairs(cost) do
                if x.op and x.key and x.key.text ~= "multiplier" and def("common/strategic_resources", x.key.text) then
                    local v = tonumber(eval.value(x.value, cctx, x)) or 0
                    world.set(stock, x.key.text, num(field(stock, x.key.text)) - v)
                end
            end
        end
        local ectx = eval.seed_scope(eval.new_ctx(ctx.this, nil, nil, file), eval.rand())
        local eff = dfield(b, "effect")
        if type(eff) == "table" then eval.effect(eff, ectx) end
        fire("on_edict_activated", ctx.this, ectx)
        local len = world.entry(b, "length")
        local length = len and tonumber(eval.value(len.value, ectx, len)) or 0
        local en = {}
        world.append(en, "edict", key, true)
        if length > 0 then
            world.append(en, "date", add_days(length), true)
        else
            world.append(en, "date", "-5070.07.21", true)
            world.append(en, "perpetual", "yes")
        end
        world.append(en, "start_date", today_text(), true)
        world.push(list, en)
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
    -- set_policy_cooldown = <group> (CSetPolicyCooldownEffect 0x3760650 → ChangePolicy) [V]: the
    -- group's entry's date today (no entry: nothing)
    EFF["set_policy_cooldown"] = function(e, ctx)
        local c = C(ctx)
        local b = c and e.value.text and policy_entry(c, unq(e.value.text))
        if not b then return end
        world.set(b, "date", quoted(today_text()))
        H.last_policy[ctx.this.id] = unq(e.value.text)
        wrote()
    end
    -- reset_policy_cooldowns (CResetPolicyCooldownsEffect 0x3760f10) [V]: every entry's date 0 (the
    -- key left out)
    EFF["reset_policy_cooldowns"] = function(_, ctx)
        local c = C(ctx)
        if not c then return end
        local n = 0
        for _, b in ipairs(world.blocks(field(c, "active_policies"))) do
            if remove_key(b, "date") then n = n + 1 end
        end
        if n > 0 then wrote() end
    end
    -- set_council_agenda = <agenda> (CSetCouncilAgendaEffect 0x376aee0 → CGovernment::
    -- SetCouncilAgenda 0x1c11620) [V]: the same: nothing; the agenda and progress 0 (cooldowns and
    -- potential not checked); one global draw seeds the scope its init_effect runs in
    EFF["set_council_agenda"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local a = unq(e.value.text)
        local b, file = def("common/council_agendas", a)
        if not b then return end
        local g = gov_of(c)
        if unq(field(g, "council_agenda")) == a then return end
        world.set(g, "council_agenda", quoted(a))
        world.set(g, "council_agenda_progress", 0)
        local ectx = eval.seed_scope(eval.new_ctx(ctx.this, nil, nil, file), eval.rand())
        local init = dfield(b, "init_effect")
        if type(init) == "table" then eval.effect(init, ectx) end
        wrote()
    end
    -- the agenda's cost (CCouncilAgenda::GetCost: agenda_cost) [I: the empire size penalty]
    local function agenda_cost(c, cid)
        local key = unq(field(gov_of(c), "council_agenda"))
        local b, file = def("common/council_agendas", key)
        local en = b and world.entry(b, "agenda_cost")
        if not en then return nil end
        local ok, v = pcall(eval.value, en.value, eval.new_ctx(S("country", cid), nil, nil, file), en)
        return ok and tonumber(v) or nil
    end
    -- add_council_agenda_progress_percent = <-1..1> (CAddCouncilAgendaProgressPercentEffect
    -- 0x376b5e0) [V]: the value clamped to [-1, 1], times the cost (fixed, truncated); the progress
    -- at least 0, not capped, not finished here
    EFF["add_council_agenda_progress_percent"] = function(e, ctx)
        local c = C(ctx)
        if not c then return end
        local cost = agenda_cost(c, ctx.this.id)
        if not cost then return end
        local g = gov_of(c)
        local v = math.max(-100000, math.min(100000, H.raw(eval.value(e.value, ctx, e))))
        local d = H.raw(cost) * v
        d = (d < 0 and -floor(-d / 100000) or floor(d / 100000))
        local p = math.max(0, H.raw(num(field(g, "council_agenda_progress"))) + d)
        world.set(g, "council_agenda_progress", p / 100000)
        wrote()
    end
    -- finish_council_agenda (CFinishCouncilAgendaEffect 0x3803510 → CFinishAgendaCommand →
    -- CGovernment::FinishAgenda 0x1c11da0) [V]: an agenda set (progress not checked): its
    -- finish_modifier for agenda_finish_modifier_duration (else COUNCIL_AGENDA_FINISH_MODIFIER_DURATION)
    -- days; one global draw seeds the scope its `effect` runs in; its cooldown (the end date:
    -- agenda_cooldown, else COUNCIL_AGENDA_COOLDOWN); no agenda, progress 0; one global draw and
    -- on_agenda_finished. The game runs it as a command after the effect [I: here at once]
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
            world.append(it, "days", tonumber(dfield(b, "agenda_finish_modifier_duration"))
                or define("NGameplay", "COUNCIL_AGENDA_FINISH_MODIFIER_DURATION", 3600))
            world.push(items, it)
        end
        local ectx = eval.seed_scope(eval.new_ctx(ctx.this, nil, nil, file), eval.rand())
        local eff = dfield(b, "effect")
        if type(eff) == "table" then eval.effect(eff, ectx) end
        local cd = tonumber(dfield(b, "agenda_cooldown")) or define("NGameplay", "COUNCIL_AGENDA_COOLDOWN", 10800)
        local entry = {}
        world.append(entry, "council_agenda", key, true)
        world.append(entry, "start_date", add_days(cd), true)
        world.push(world.child(g, "council_agenda_cooldowns"), entry)
        remove_key(g, "council_agenda")
        remove_key(g, "council_agenda_progress")
        local octx = eval.seed_scope(eval.new_ctx(ctx.this), eval.rand())
        fire("on_agenda_finished", ctx.this, octx)
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- the council, the heir, names and titles

    -- set_heir = <leader> (CSetHeirEffect): the government's heir
    EFF["set_heir"] = function(e, ctx)
        local c = C(ctx)
        local sc = target(e, ctx)
        if not c or not sc or sc.kind ~= "leader" then return end
        world.set(gov_of(c), "heir", sc.id)
        wrote()
    end
    -- remove_from_empire_council (CRemoveFromEmpireCouncilEffect): the leader off its council
    -- position (the position's leader none, the leader's council_location removed)
    EFF["remove_from_empire_council"] = function(e, ctx)
        local l = L(ctx)
        if not l or e.value.text == "no" then return end
        local cl = field(l, "council_location")
        local pid = type(cl) == "table" and tonumber(field(cl, "id"))
        local p = pid and obj("council_positions", pid)
        if p then world.set(p, "leader", 4294967295) end
        if remove_key(l, "council_location") or p then wrote() end
    end
    -- a parsed block copied (key, op, value, text, quoted)
    local function copy_node(x)
        if type(x) ~= "table" then return x end
        local out = {}
        for k, v in pairs(x) do out[k] = copy_node(v) end
        return out
    end
    -- a CPersistentName: `{ key = "<text>" }` (a block given: copied)
    local function persistent(v)
        if type(v) == "table" and v.text == nil then return copy_node(v) end
        return name_block(unq(type(v) == "table" and v.text or v), false)
    end
    -- CCountry::SetCustomName (0x23455d0) [V]: name, the adjective `%ADJECTIVE%` of it, custom_name
    local function set_country_name(c, name)
        set_block(c, "name", name)
        local key = unq(field(name, "key")) or ""
        local adj = {}
        world.append(adj, "key", "%ADJECTIVE%", true)
        local var = {}
        world.append(var, "key", "adjective", true)
        local inner = {}
        world.append(inner, "key", key, true)
        world.append_entry(var, { key = { text = "value" }, op = "=", value = inner })
        local vars = {}
        world.push(vars, var)
        world.append_entry(adj, { key = { text = "variables" }, op = "=", value = vars })
        set_block(c, "adjective", adj)
        world.set(c, "custom_name", "yes")
    end
    -- set_empire_name = <name> (CSetEmpireNameEffect 0x3774a50) [V]: SetCustomName [I: the
    -- substrings not evaluated]
    EFF["set_empire_name"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local t = unq(e.value.text)
        if t == "" then return end
        set_country_name(c, name_block(t, false))
        wrote()
    end
    -- set_name = <name> | <target> | { key variables } | random (CSetNameEffect 0x37191f0) [V]: a
    -- target's name copied, else the name; a country: SetCustomName; a leader: name = { full_names
    -- }; others their `name`; species are not a scope of it. random: a new name from the scope's
    -- name list [I: not modelled, reported]
    EFF["set_name"] = function(e, ctx)
        if ctx.this == NONE or ctx.this.kind == "species" then return end
        local o = world.object(ctx.this.kind, ctx.this.id)
        if not o then return end
        if e.value.text == "random" then I.miss("effect", "set_name = random", ctx, e) return end
        local name
        local sc = e.value.text and target(e, ctx)
        if sc and sc ~= NONE then
            local n = field(world.object(sc.kind, sc.id), "name")
            if type(n) == "table" then
                local fn = field(n, "full_names")
                name = copy_node(type(fn) == "table" and fn or n)
            end
        else
            name = persistent(e.value)
        end
        if not name or (unq(field(name, "key")) or "") == "" then return end
        if ctx.this.kind == "country" then
            set_country_name(o, name)
        elseif ctx.this.kind == "leader" then
            local nb = {}
            world.append_entry(nb, { key = { text = "full_names" }, op = "=", value = name })
            set_block(o, "name", nb)
        else
            set_block(o, "name", name)
        end
        wrote()
    end
    -- set_male_ruler_title / set_female_ruler_title / set_male_heir_title / set_female_heir_title =
    -- <text> (CSetRulerHeirTitleEffect<...> 0x37b1ff0 ...) [V]: the country's ruler_title /
    -- ruler_title_female / heir_title / heir_title_female = { key }; an empty text: nothing
    local function title_effect(key)
        return function(e, ctx)
            local c = C(ctx)
            if not c or not e.value.text then return end
            local t = unq(e.value.text)
            if t == "" then return end
            set_block(c, key, name_block(t, false))
            wrote()
        end
    end
    EFF["set_male_ruler_title"] = title_effect("ruler_title")
    EFF["set_female_ruler_title"] = title_effect("ruler_title_female")
    EFF["set_male_heir_title"] = title_effect("heir_title")
    EFF["set_female_heir_title"] = title_effect("heir_title_female")
    -- the government type's ruler title (common/governments: ruler_title / ruler_title_female)
    local function gov_title(c, key)
        local t = unq(field(world.child(c, "government"), "type"))
        local b = t and def("common/governments", t)
        local v = b and dfield(b, key)
        return v and unq(v) or nil
    end
    -- set_ruler_title_male / set_ruler_title_female = <name> (CSetRulerTitleMaleEffect 0x37b41e0,
    -- ...Female 0x37b4930) [V]: that title, and the other gender's current one (custom, else the
    -- government type's) written as custom too; the heir's untouched [I: substrings not evaluated]
    local function ruler_title(key, other)
        return function(e, ctx)
            local c = C(ctx)
            if not c then return end
            local name = persistent(e.value)
            if (unq(field(name, "key")) or "") == "" then return end
            set_block(c, key, name)
            if type(field(c, other)) ~= "table" then
                local t = gov_title(c, other)
                if t then set_block(c, other, name_block(t, false)) end
            end
            wrote()
        end
    end
    EFF["set_ruler_title_male"] = ruler_title("ruler_title", "ruler_title_female")
    EFF["set_ruler_title_female"] = ruler_title("ruler_title_female", "ruler_title")
    -- clear_custom_ruler_and_heir_titles (CClearCustomRulerAndHeirTitlesEffect 0x37b2fd0) [V]
    EFF["clear_custom_ruler_and_heir_titles"] = function(_, ctx)
        local c = C(ctx)
        if not c then return end
        local n = 0
        for _, k in ipairs({ "ruler_title", "ruler_title_female", "heir_title", "heir_title_female" }) do
            if remove_key(c, k) then n = n + 1 end
        end
        if n > 0 then wrote() end
    end
    -- set_council_position_title_male / _female = { position_tag title }
    -- (CSetCouncilPositionTitleMaleEffect 0x37b5090, ...Female 0x37b5860 → CCountry::
    -- SetCustomCouncilTitle 0x23940b0) [V]: the position's entries in custom_council_titles out, one
    -- appended: { council_position male female } with the other gender's custom title kept
    local function council_title(which)
        return function(e, ctx)
            local c = C(ctx)
            if not c or e.value.text then return end
            local p = params(e)
            local tag, t = unq(text_of(p.position_tag)), unq(text_of(p.title))
            if not tag or not t or not def("common/governments/councilors", tag) then return end
            local titles = world.child(c, "custom_council_titles")
            local other = which == "male" and "female" or "male"
            local keep = ""
            for _, x in ipairs(world.blocks(titles)) do
                if unq(field(x, "council_position")) == tag then
                    keep = unq(field(x, other)) or keep
                    world.remove_entry(titles, x)
                end
            end
            local entry = {}
            world.append(entry, "council_position", tag, true)
            world.append(entry, "male", which == "male" and t or keep, true)
            world.append(entry, "female", which == "female" and t or keep, true)
            world.push(titles, entry)
            wrote()
        end
    end
    EFF["set_council_position_title_male"] = council_title("male")
    EFF["set_council_position_title_female"] = council_title("female")
    -- room_name_override = <text> (CRoomNameOverrideEffect 0x3795ad0) [V]: the country's `room`; an
    -- empty text removes it
    EFF["room_name_override"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local t = unq(e.value.text)
        if t == "" then
            if remove_key(c, "room") then wrote() end
            return
        end
        world.set(c, "room", quoted(t))
        wrote()
    end
    -- randomize_flag_symbol = <category> (CRandomizeFlagSymbolEffect 0x376b9b0 → CEmpireFlag::
    -- RandomizeSymbol 0x19ee9b0) [V]: one global draw s; the flag's icon category; a CCrudeRandom(s)
    -- draw picks among the category's textures (flags/<category>/, in name order [I: the database's
    -- order]); used_symbols not touched
    local flag_files = {}
    local function category_textures(cat)
        local list = flag_files[cat]
        if list then return list end
        list = {}
        local ok, files = pcall(RUST.list_files, os.getenv("STELLARIS_DIR") or "", "flags")
        if ok and type(files) == "table" then
            for _, f in ipairs(files) do
                local c2, name = tostring(f):match("flags/([^/]+)/([^/]+%.dds)$")
                if c2 == cat then list[#list + 1] = name end
            end
        end
        table.sort(list)
        flag_files[cat] = list
        return list
    end
    EFF["randomize_flag_symbol"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local cat = unq(e.value.text)
        local s = eval.rand()
        local icon = world.child(world.child(c, "flag"), "icon")
        world.set(icon, "category", quoted(cat))
        local list = category_textures(cat)
        if #list > 0 then
            local r = SR.new(s)
            local x = require("engine.newgame.rng").noise32(r.pos, r.seed)
            local bit = require("bit")
            local n = bit.bxor(bit.band(x, 0x7FFFFFFE), bit.rshift(x, 8))
            if n < 0 then n = n + 4294967296 end
            world.set(icon, "file", quoted(list[n % #list + 1]))
        end
        wrote()
    end
    -- set_empire_flag = { icon background colors } (CSetEmpireFlagEffect 0x37750b0 → CCountry::
    -- SetEmpireFlag 0x2341970) [V]: the country's flag replaced [I: the top-level used_color and
    -- used_symbols entries it adds not written]
    EFF["set_empire_flag"] = function(e, ctx)
        local c = C(ctx)
        if not c or e.value.text then return end
        set_block(c, "flag", copy_node(e.value))
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- kill_leader (replaces eval.lua's, which read only a leader scope)

    local function push_engine(t)
        stats.engine = stats.engine + 1
        E.push(t)
    end
    -- kill_leader = yes | { class ability show_notification fire } (CKillLeaderEffect): the scoped
    -- leader; the scoped object's leader (a planet's governor, a fleet's, an army's); a country's
    -- leaders of the classes or with the abilities named (none named: its ruler [I]). The death
    -- itself is the engine's (systems.effects.kill_leader)
    EFF["kill_leader"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return end
        if sc.kind == "leader" then
            push_engine({ type = "kill_leader", kind = "leader", id = sc.id })
            sync()
            return
        end
        if sc.kind == "country" then
            local c = obj("country", sc.id)
            if not c then return end
            local classes, abilities = {}, {}
            if e.value.text == nil then
                for _, x in ipairs(e.value) do
                    if x.op and x.key and x.value.text then
                        local k = x.key.text:lower()
                        if k == "class" then classes[unq(x.value.text)] = true
                        elseif k == "ability" then abilities[unq(x.value.text)] = true end
                    end
                end
            end
            local victims = {}
            if next(classes) == nil and next(abilities) == nil then
                local r = tonumber(field(c, "ruler"))
                if r then victims[1] = r end
            else
                for _, id in ipairs(H.owned_leaders(c)) do
                    local l = H.leader(id)
                    local class = l and unq(field(l, "class"))
                    local hit = class and classes[class]
                    if not hit and next(abilities) then
                        local cb = def("common/leader_classes", class)
                        for a in pairs(abilities) do
                            if cb and dfield(cb, a) == "yes" then hit = true end
                        end
                    end
                    if hit then victims[#victims + 1] = id end
                end
            end
            for _, id in ipairs(victims) do push_engine({ type = "kill_leader", kind = "leader", id = id }) end
            if #victims > 0 then sync() end
            return
        end
        local lid = E.leader_of and E.leader_of(sc.kind, sc.id)
        if lid then
            push_engine({ type = "kill_leader", kind = "leader", id = lid })
            sync()
        end
    end
end
