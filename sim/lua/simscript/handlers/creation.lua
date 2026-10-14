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
