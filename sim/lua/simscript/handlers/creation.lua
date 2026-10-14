-- simscript/handlers/creation.lua : the effects that create or change things (deposits, resources
-- by income, experience, switch, ...), from the GOG 4.5.2 build's effect classes
-- (docs/script_creation.md). An effect that changes the world is queued to the engine (E.push, as
-- eval's engine effects are) and applied at the barrier by its applier in engine.script.creation;
-- one that draws from the game's generator is flushed at once, so that its draws come where the
-- game's do relative to the script's own.
--
-- Loaded by simscript/handlers/init.lua after the runtime and diplomacy modules.

return function(eval)
    local I = eval._internal
    local EFF = eval.EFF
    local E, stats, miss, sync = I.E, I.stats, I.miss, I.sync
    local floor = math.floor

    -- the appliers (engine.systems.effects.*)
    local creation = require("engine.script.creation")
    local SR = require("engine.script.scope_random")

    -- -----------------------------------------------------------------------------------------
    -- the scope random (docs/script_creation.md "Scope random"): each context's random state, made
    -- when it first draws. A scope made from another (eval's push: a scope change, an iterator's
    -- element, an event's scope) starts from a copy of that one's state (CEventScope::Copy,
    -- CEventTarget::GetScope); a scripted effect's context (with_file: `same`) is the same scope; a
    -- root context without one is a default scope's (Init(0)) unless its maker seeded it

    local function rng_of(ctx)
        local r = ctx.rng
        if r then return r end
        if ctx.same then
            r = rng_of(ctx.same)
        elseif ctx.up then
            r = SR.copy(rng_of(ctx.up))
        else
            r = SR.default()
        end
        ctx.rng = r
        return r
    end
    eval.scope_rng = rng_of
    function eval.scope_draw(ctx)
        return SR.draw(rng_of(ctx))
    end
    -- a context's scope made from a value (CEventScope(int): position H(x), seed 0)
    function eval.seed_scope(ctx, x)
        ctx.rng = SR.new(x)
        return ctx
    end
    -- the iterators (eval's iterate_effect): the iterator's own copy of the scope's state; a
    -- random_* pick draws from it (CRandomInListEffect::GetRandomIndex), and the element's scope
    -- continues it; every_* gives each element position H(position + 1) of it
    -- (CEveryInListEffect::ExecuteActual); ordered_* hands it on as it is [I]
    eval.scope_iter = {
        begin = function(ctx) return SR.copy(rng_of(ctx)) end,
        draw = SR.draw,
        element = function(loop, c, kind)
            if kind == "every" then loop.pos = SR.H(loop.pos + 1) end
            c.rng = loop
        end,
    }

    local function trunc(x)
        return x < 0 and -floor(-x) or floor(x)
    end

    -- random = { chance = <int> <effects> } (CRandomEffect::ExecuteActual 0x16e2d60): one draw from
    -- the scope, r % 100 < chance; chance a CIntVariableValue, 0 by default; no modifiers [V]
    EFF["random"] = function(e, ctx)
        if e.value.text ~= nil then return end
        local chance = 0
        for _, x in ipairs(e.value) do
            if x.op and x.key.text:lower() == "chance" then chance = trunc(eval.value(x.value, ctx, x)) end
        end
        if eval.scope_draw(ctx) % 100 < chance then
            eval.effect(e.value, ctx, { chance = true, modifier = true })
        end
    end

    -- the entries of a random_list: { weight (int: the CFixedPoint key with its modifiers,
    -- truncated), block }
    local function list_entries(e, ctx)
        local entries, total = {}, 0
        for _, x in ipairs(e.value) do
            if x.op and x.value.text == nil then
                local base = tonumber(x.key.text) or eval.value(x.key, ctx, x)
                -- the weight as a CFixedPoint, then its integer part
                local w = trunc(floor(eval.weight(x.value, ctx, base) * 100000 + 0.5) / 100000)
                local ok = true
                for _, y in ipairs(x.value) do
                    if y.op and y.key.text:lower() == "trigger" and y.value.text == nil then ok = eval.trigger(y.value, ctx) end
                end
                if ok then
                    entries[#entries + 1] = { w, x.value }
                    total = total + w
                end
            end
        end
        return entries, total
    end

    -- random_list = { <w> = { modifier = { } <effects> } ... } (CRandomListEffect::ExecuteActual
    -- 0x17c5440, NRandomListImpl::ExecuteRandomList): each entry's weight an integer, the sum above
    -- 0: one draw from the scope % the sum; the first entry where the remainder minus the weights
    -- so far goes below 0 [V]
    EFF["random_list"] = function(e, ctx)
        if e.value.text ~= nil then return end
        local entries, total = list_entries(e, ctx)
        if total <= 0 then return end
        local r = eval.scope_draw(ctx) % total
        for _, en in ipairs(entries) do
            r = r - en[1]
            if r < 0 then
                return eval.effect(en[2], ctx, { modifier = true, trigger = true })
            end
        end
    end

    -- locked_random_list (CLockedRandomListEffect::GetOptionIndex 0x17c6190): the scope's position
    -- itself (an int32), no draw: position % the sum, the first entry whose running sum of positive
    -- weights is above it [V]
    EFF["locked_random_list"] = function(e, ctx)
        if e.value.text ~= nil then return end
        local entries, total = list_entries(e, ctx)
        if total == 0 then return end
        local pos = SR.signed_pos(rng_of(ctx))
        local r = math.fmod(pos, total)
        local cum = 0
        for _, en in ipairs(entries) do
            if en[1] > 0 then
                cum = cum + en[1]
                if cum > r then
                    return eval.effect(en[2], ctx, { modifier = true, trigger = true })
                end
            end
        end
    end

    local function where(ctx, e)
        return (ctx and ctx.file or "?") .. ":" .. tostring(e and e.line or "?")
    end
    local function push(t)
        stats.engine = stats.engine + 1
        E.push(t)
    end
    -- an engine effect the engine does not model (counted as eval's are)
    local function unmodelled(lk, ctx, e)
        local m = stats.unmodelled[lk]
        if not m then
            m = { key = lk, count = 0, first = where(ctx, e) }
            stats.unmodelled[lk] = m
        end
        m.count = m.count + 1
        push({ type = "unmodelled", keyword = lk })
    end
    -- the parameters of an effect block: lower-case key -> statement (the first of each)
    local function params(e)
        local out = {}
        if e.value.text == nil then
            for _, x in ipairs(e.value) do
                if x.op and x.key then
                    local k = x.key.text:lower()
                    if out[k] == nil then out[k] = x end
                end
            end
        end
        return out
    end
    local function text_of(x)
        return x and x.value.text and creation.unq(x.value.text) or nil
    end
    -- a value as the game reads it into a CFixedPoint (raw, 1.0 = 100000)
    local function fixed(x, ctx)
        return creation.fp(eval.value(x.value, ctx, x))
    end

    -- -----------------------------------------------------------------------------------------
    -- deposits

    -- add_deposit = <key | random | random_blocker | random_nonblocker> (CAddDepositEffect, token
    -- 11419 / 16916 / 16917 -> modes 3 / 1 / 2): a fixed type is created on the scope's deposit
    -- holder; the random modes draw once (CRandom::GetIntegerForMacro) and pick through
    -- CDepositTypesDatabase::_Randomize, not ported: counted unmodelled, nothing drawn
    EFF["add_deposit"] = function(e, ctx)
        local key = e.value.text and creation.unq(e.value.text)
        if not key then return end
        if key == "random" or key == "random_blocker" or key == "random_nonblocker" then
            return unmodelled("add_deposit = " .. key, ctx, e)
        end
        push({ type = "add_deposit", kind = ctx.this.kind, id = ctx.this.id, deposit = key })
        -- a blocker may draw its swap type (CDeposit::SetType): applied at once
        sync()
    end
    -- remove_deposit = <key | yes> (CRemoveDepositEffect): in a deposit scope `yes` is that deposit
    EFF["remove_deposit"] = function(e, ctx)
        local key = e.value.text and creation.unq(e.value.text)
        if not key or key == "no" then return end
        push({ type = "remove_deposit", kind = ctx.this.kind, id = ctx.this.id, deposit = key ~= "yes" and key or nil })
    end
    EFF["clear_deposits"] = function(e, ctx)
        if e.value.text ~= "yes" then return end
        push({ type = "clear_deposits", kind = ctx.this.kind, id = ctx.this.id })
    end

    -- -----------------------------------------------------------------------------------------
    -- timed modifiers

    -- add_modifier = <key> | { modifier days|months|years multiplier time_multiplier
    -- clear_on_owner_change } (CAddModifierEffect: days an int, -1 by default (permanent);
    -- GetDays: times time_multiplier, truncated; multiplier a CFixedPointVariableValue, 1 by default)
    EFF["add_modifier"] = function(e, ctx)
        local name, days, mult, tmult, clear
        if e.value.text then
            name = creation.unq(e.value.text)
        else
            for _, x in ipairs(e.value) do
                if x.op then
                    local xk = x.key.text:lower()
                    if xk == "modifier" then name = text_of(x)
                    elseif xk == "days" then days = trunc(eval.value(x.value, ctx, x))
                    elseif xk == "months" then days = trunc(eval.value(x.value, ctx, x)) * 30
                    elseif xk == "years" then days = trunc(eval.value(x.value, ctx, x)) * 360
                    elseif xk == "multiplier" then mult = fixed(x, ctx)
                    elseif xk == "time_multiplier" then tmult = fixed(x, ctx)
                    elseif xk == "clear_on_owner_change" then clear = x.value.text == "yes" end
                end
            end
        end
        if not name then return end
        if not I.db.static_modifiers[name] then
            miss("static modifier", name, ctx, e)
            return
        end
        days = days or -1
        if tmult and tmult ~= 100000 then
            days = trunc(creation.fmul(days * 100000, tmult) / 100000)
        end
        push({ type = "add_timed_modifier", kind = ctx.this.kind, id = ctx.this.id, modifier = name,
            days = days, mult = mult, clear = clear })
    end
    -- remove_modifier = <key>
    EFF["remove_modifier"] = function(e, ctx)
        local name = e.value.text and creation.unq(e.value.text)
        if not name then return end
        push({ type = "remove_timed_modifier", kind = ctx.this.kind, id = ctx.this.id, modifier = name })
    end

    -- -----------------------------------------------------------------------------------------
    -- opinion modifiers

    -- the country a `who = <scope>` names (CEventTarget::GetTargetCountry)
    local function who_country(x, ctx)
        local t = x and x.value.text
        if not t then return nil end
        local found, sc = eval.resolve(t, ctx, x)
        if not found or not sc then return nil end
        if sc.kind == "country" then return sc.id end
        local f2, owner = eval.resolve("owner", I.push(ctx, sc), x)
        return f2 and owner and owner.kind == "country" and owner.id or nil
    end

    -- add_opinion_modifier = { who = <country> modifier = <key> }
    EFF["add_opinion_modifier"] = function(e, ctx)
        local p = params(e)
        local key = text_of(p.modifier)
        local who = who_country(p.who, ctx)
        if not key or not who then return end
        push({ type = "add_opinion_modifier", kind = ctx.this.kind, id = ctx.this.id, who = who, modifier = key })
    end
    -- remove_opinion_modifier = { who = <country> | all modifier = <key> }
    EFF["remove_opinion_modifier"] = function(e, ctx)
        local p = params(e)
        local key = text_of(p.modifier)
        if not key or not p.who then return end
        local who = text_of(p.who) == "all" and "all" or who_country(p.who, ctx)
        if not who then return end
        push({ type = "remove_opinion_modifier", kind = ctx.this.kind, id = ctx.this.id, who = who, modifier = key })
    end

    -- -----------------------------------------------------------------------------------------
    -- planets, surveys, countries

    -- change_pc = <class> | { class = <class> inherit_entity = yes } (CChangePlanetClassEffect;
    -- a random list of classes draws from the scope: not ported, counted unmodelled). The class
    -- change draws once from the game's generator: applied at once
    EFF["change_pc"] = function(e, ctx)
        local class = e.value.text and creation.unq(e.value.text)
        if not class then class = text_of(params(e).class) end
        if not class then return end
        if not require("engine.defs").get("common/planet_classes", class) then
            return unmodelled("change_pc (random list)", ctx, e)
        end
        push({ type = "change_pc", kind = ctx.this.kind, id = ctx.this.id, class = class })
        sync()
    end

    -- set_surveyed = { surveyed = yes|no surveyor = <country> } (surveys draw: applied at once)
    EFF["set_surveyed"] = function(e, ctx)
        local p = params(e)
        local who = p.surveyor and who_country(p.surveyor, ctx)
        if not who then return end
        push({ type = "set_surveyed", kind = ctx.this.kind, id = ctx.this.id, surveyor = who,
            surveyed = not p.surveyed or p.surveyed.value.text ~= "no" })
        sync()
    end

    -- add_timeline_event = { type = <definition> date = <date> targets = { <scope> ... } }
    EFF["add_timeline_event"] = function(e, ctx)
        local p = params(e)
        local def = text_of(p.type)
        if not def then return end
        local day = eval.today()
        local d = p.date and p.date.value.text and creation.unq(p.date.value.text)
        if d then
            local y, m, dd = d:match("^(%d+)%.(%d+)%.(%d+)")
            if y then day = tonumber(y) * 360 + (tonumber(m) - 1) * 30 + tonumber(dd) - 1 end
        end
        local targets = {}
        if p.targets and p.targets.value.text == nil then
            for _, x in ipairs(p.targets.value) do
                local t = x.text or (x.op and x.value.text)
                if t then
                    local found, sc = eval.resolve(t, ctx, x)
                    if found and sc and sc.kind ~= "none" then targets[#targets + 1] = { kind = sc.kind, id = sc.id } end
                end
            end
        end
        local c = ctx.this.kind == "country" and ctx.this or select(2, eval.resolve("owner", ctx, e))
        if not c then return end
        push({ type = "add_timeline_event", kind = c.kind, id = c.id, definition = def, date = day, targets = targets })
    end

    -- run_ai_strategic_war_data = yes (CRunAIStrategicWarDataEffect): the AI's war data computed
    -- again; the AI's strategy is engine.ai's, nothing in the world changes here [I]
    EFF["run_ai_strategic_war_data"] = EFF["run_ai_strategic_war_data"] or function() end

    -- export_trigger_value_to_variable = { trigger = <name> parameters = { } variable = <name>
    -- rounded = yes } (CExportTriggerValueToVariableEffect): the trigger's value. The script layer's
    -- triggers compare, they do not return values: a trigger written `<name> <op> <number>` is read by
    -- bisection of `<name> > v` (exact to 1e-5 for what the game keeps as fixed point) [I]; a trigger
    -- with parameters is counted as not implemented
    local function trigger_value(name, ctx, e)
        local key = name:lower()
        -- a fresh block each time: the compiler keys its caches on the block (weakly), so a block
        -- evaluated once is only walked
        local function gt(v)
            local probe = { key = { text = name }, op = ">", value = { text = string.format("%.6f", v) }, line = e.line }
            return eval.trigger({ probe }, ctx)
        end
        local lo, hi = -1, 1
        while gt(hi) and hi < 1e12 do hi = hi * 2 end
        while not gt(lo) and lo > -1e12 do lo = lo * 2 end
        if gt(hi) or not gt(lo) then return nil end
        for _ = 1, 80 do
            local mid = (lo + hi) / 2
            if gt(mid) then lo = mid else hi = mid end
            if hi - lo < 1e-7 then break end
        end
        return floor(hi * 100000 + 0.5) / 100000, key
    end
    EFF["export_trigger_value_to_variable"] = function(e, ctx)
        local p = params(e)
        local name, var = text_of(p.trigger), text_of(p.variable)
        if not name or not var then return end
        if p.parameters then
            return miss("effect", "export_trigger_value_to_variable " .. name .. " (parameters)", ctx, e)
        end
        local v = trigger_value(name, ctx, e)
        if v == nil then
            return miss("effect", "export_trigger_value_to_variable " .. name, ctx, e)
        end
        if p.rounded and p.rounded.value.text == "yes" then v = floor(v + 0.5) end
        stats.script = stats.script + 1
        eval.store.setvar(ctx.this, var, v)
    end

    -- -----------------------------------------------------------------------------------------
    -- event chains, special projects

    -- engine.script.event_save requires simscript.eval, which loads this module: required when used
    local event_save = setmetatable({}, { __index = function(_, k) return require("engine.script.event_save")[k] end })

    -- the country of a scope (CEventScope::GetTargetCountry)
    local function country_of(sc, ctx)
        if not sc or sc.kind == "none" then return nil end
        if sc.kind == "country" then return sc.id end
        local f, owner = eval.resolve("owner", I.push(ctx, sc), nil)
        return f and owner and owner.kind == "country" and owner.id or nil
    end

    -- begin_event_chain = { event_chain = <key> target = <scope> } (the target's country; the scope
    -- kept is the effect's own)
    EFF["begin_event_chain"] = function(e, ctx)
        local p = params(e)
        local chain = text_of(p.event_chain)
        if not chain then return end
        local target = ctx.this
        if p.target and p.target.value.text then
            local f, sc = eval.resolve(p.target.value.text, ctx, p.target)
            if f then target = sc end
        end
        local c = country_of(target, ctx)
        if not c then return end
        push({ type = "begin_event_chain", country = c, chain = chain, scope = event_save.ctx_block(ctx) })
    end
    -- end_event_chain = <key> (the scope's country)
    EFF["end_event_chain"] = function(e, ctx)
        local chain = e.value.text and creation.unq(e.value.text)
        local c = country_of(ctx.this, ctx)
        if not chain or not c then return end
        push({ type = "end_event_chain", country = c, chain = chain })
    end
    -- add_event_chain_counter = { event_chain = <key> counter = <key> amount = <int> }
    EFF["add_event_chain_counter"] = function(e, ctx)
        local p = params(e)
        local chain, counter = text_of(p.event_chain), text_of(p.counter)
        local c = country_of(ctx.this, ctx)
        if not chain or not counter or not c then return end
        local amount = p.amount and trunc(eval.value(p.amount.value, ctx, p.amount)) or 1
        push({ type = "add_event_chain_counter", country = c, chain = chain, counter = counter, amount = amount })
    end

    -- enable_special_project = { name = <key> owner = <scope> location = <scope> } (owner: root by
    -- default; location: this). The AI's wait (AI_wait_days, country scope, from = this scope) and
    -- one draw of the game's generator: applied at once
    EFF["enable_special_project"] = function(e, ctx)
        local p = params(e)
        local key = text_of(p.name)
        if not key then return end
        local owner = ctx.root
        if p.owner and p.owner.value.text then
            local f, sc = eval.resolve(p.owner.value.text, ctx, p.owner)
            if f then owner = sc end
        end
        local c = country_of(owner, ctx)
        if not c then return end
        local loc = ctx.this
        if p.location and p.location.value.text then
            local f, sc = eval.resolve(p.location.value.text, ctx, p.location)
            if f and sc then loc = sc end
        end
        local d = creation.special_project_def(key)
        local wait = 0
        local wb = d and require("engine.defs").field(d.block, "AI_wait_days")
        if type(wb) == "table" then
            local wctx = eval.new_ctx(eval.S("country", c), ctx.this, nil, d.file)
            local ok, v = pcall(eval.weight, wb, wctx, 0)
            if ok then wait = v end
        end
        push({ type = "enable_special_project", country = c, project = key, scope = event_save.ctx_block(ctx),
            location = loc and loc.kind ~= "none" and { kind = loc.kind, id = loc.id } or nil, wait = wait })
        sync()
    end
    -- set_site_progress_locked = yes|no (an archaeological site's or a first contact's)
    EFF["set_site_progress_locked"] = function(e, ctx)
        if not e.value.text then return end
        push({ type = "set_site_progress_locked", kind = ctx.this.kind, id = ctx.this.id, locked = e.value.text == "yes" })
    end

    -- abort_special_project = { type = <key> } (the scope's country)
    EFF["abort_special_project"] = function(e, ctx)
        local p = params(e)
        local key = text_of(p.type) or (e.value.text and creation.unq(e.value.text))
        local c = country_of(ctx.this, ctx)
        if not key or not c then return end
        push({ type = "abort_special_project", country = c, project = key })
    end

    -- -----------------------------------------------------------------------------------------
    -- resources

    -- add_monthly_resource_mult = { resource = <key> value = <v> min = <v> max = <v> mult = <v> }
    -- (CAddMonthlyResourceMultEffect: value, min, max read as CFixedPoint at load; mult a
    -- CFixedPointVariableValue, 1 by default)
    EFF["add_monthly_resource_mult"] = function(e, ctx)
        local p = params(e)
        local res = text_of(p.resource)
        if not res then return end
        push({ type = "add_monthly_resource_mult", kind = ctx.this.kind, id = ctx.this.id, resource = res,
            value = p.value and fixed(p.value, ctx) or 0,
            min = p.min and fixed(p.min, ctx) or nil,
            max = p.max and fixed(p.max, ctx) or nil,
            mult = p.mult and fixed(p.mult, ctx) or nil })
    end

    -- -----------------------------------------------------------------------------------------
    -- leaders

    -- add_experience = <v> (CAddExperience: CFixedPointVariableValue, CLeader::AddExperience)
    EFF["add_experience"] = function(e, ctx)
        local amount = eval.value(e.value, ctx, e)
        push({ type = "add_experience", kind = ctx.this.kind, id = ctx.this.id, amount = amount })
    end

    -- -----------------------------------------------------------------------------------------
    -- switch / inverted_switch (CSwitchEffectBase<0/1>: CTriggerSwitchBase::CalcCaseBody<1/0>):
    -- `trigger = <key>`, then cases `<value> = { }` or `<value> <op> { }` and `default = { }`.
    -- Each case is the trigger `<key> <op> <value>`, read once; the first case whose trigger is true
    -- (inverted: false), else default, runs in the same scope [V]

    local cases_of = setmetatable({}, { __mode = "k" })
    local function cases(e)
        local c = cases_of[e.value]
        if c == nil then
            local p = params(e)
            local key = p.trigger and p.trigger.value.text
            c = { list = {} }
            for _, x in ipairs(e.value) do
                if x.op and x.key and x.value.text == nil then
                    local k = x.key.text:lower()
                    if k == "default" then
                        c.default = x.value
                    elseif k ~= "trigger" and key then
                        local op = x.op
                        local stmt = { key = { text = key }, op = op, value = { text = x.key.text, quoted = x.key.quoted },
                            line = x.line }
                        c.list[#c.list + 1] = { cond = { stmt }, body = x.value }
                    end
                end
            end
            cases_of[e.value] = c
        end
        return c
    end
    local function switch(want)
        return function(e, ctx)
            if e.value.text ~= nil then return end
            local c = cases(e)
            for _, case in ipairs(c.list) do
                if (eval.trigger(case.cond, ctx) and true or false) == want then
                    return eval.effect(case.body, ctx)
                end
            end
            if c.default then
                return eval.effect(c.default, ctx)
            end
        end
    end
    EFF["switch"] = EFF["switch"] or switch(true)
    EFF["inverted_switch"] = EFF["inverted_switch"] or switch(false)
end
