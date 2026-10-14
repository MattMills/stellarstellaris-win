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
