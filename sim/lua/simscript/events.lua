-- simscript/events.lua : events, on_actions, delayed events, MTTH, and the AI's option choice.
--
-- Events and their queues are script state: they live here. The engine says when (pulses and
-- engine on_actions through host.on_action, each scope's day through host.scope_daily_events);
-- what fires, with which trigger, chance and option, is decided in Lua with the game's RNG (E.rand).

local db = require("simscript.db")
local eval = require("simscript.eval")

local M = {}
local S, NONE = eval.S, eval.NONE
local state, stats = eval.state, eval.stats

state.delayed = {}      -- scope key -> array of { due, id, scope, from, targets }
local mtth_by_kind = {} -- scope kind -> array of events with mean_time_to_happen

stats.fired = {}        -- event id -> count
stats.fired_total = 0
stats.trigger_failed = 0
stats.on_actions = {}   -- name -> count
stats.on_action_events = 0
stats.options = 0
stats.mtth_rolls = 0
stats.delayed_queued = 0
stats.unknown_events = {}

local OPTION_PARAMS = {
    name = true, trigger = true, allow = true, ai_chance = true, custom_tooltip = true,
    default_hide_option = true, is_dialog_only = true, response_text = true, exclusive_trigger = true,
    custom_gui = true, tooltip = true, sound = true, highlight = true, fail_text = true,
    is_exclusive_option = true, show_unlock_hint = true, title = true, desc = true,
}

function M.index()
    for _, ev in ipairs(db.event_list) do
        if ev.mtth and not ev.triggered_only then
            local k = ev.scope_kind or "none"
            local l = mtth_by_kind[k]
            if not l then l = {}; mtth_by_kind[k] = l end
            l[#l + 1] = ev
        end
    end
    return mtth_by_kind
end

-- the AI stand-in's option choice: valid options weighted by ai_chance, drawn with the game's RNG
local function choose_option(ev, ctx)
    local valid, total = {}, 0
    for _, opt in ipairs(ev.options) do
        local ok, w = true, 1
        for _, x in ipairs(opt) do
            if x.op then
                local k = x.key.text:lower()
                if k == "trigger" and x.value.text == nil then ok = ok and eval.trigger(x.value, ctx)
                elseif k == "ai_chance" and x.value.text == nil then w = eval.weight(x.value, ctx, 1) end
            end
        end
        if ok and w > 0 then
            local iw = math.floor(w * 1000)
            if iw > 0 then
                valid[#valid + 1] = { opt, iw }
                total = total + iw
            end
        end
    end
    if total == 0 then
        return ev.options[1]
    end
    local r = eval.rand() % total
    for _, v in ipairs(valid) do
        if r < v[2] then return v[1] end
        r = r - v[2]
    end
    return valid[#valid][1]
end

-- fires an event now: trigger, immediate, the chosen option, after
function M.fire(id, scope, from_ctx, from_scope)
    local ev = db.events[id]
    if not ev then
        stats.unknown_events[id] = (stats.unknown_events[id] or 0) + 1
        return false
    end
    if ev.once and state.fired_once[id] then
        return false
    end
    local targets = {}
    if from_ctx then
        for k, v in pairs(from_ctx.targets) do targets[k] = v end
    end
    local ctx = eval.new_ctx(scope, from_scope or (from_ctx and from_ctx.this) or NONE, targets, ev.file)
    if from_ctx then ctx.fromfrom = from_ctx.from end
    if ev.pre_triggers and not eval.trigger(ev.pre_triggers, ctx) then
        stats.trigger_failed = stats.trigger_failed + 1
        return false
    end
    if ev.trigger and not eval.trigger(ev.trigger, ctx) then
        stats.trigger_failed = stats.trigger_failed + 1
        return false
    end
    stats.fired[id] = (stats.fired[id] or 0) + 1
    stats.fired_total = stats.fired_total + 1
    if ev.once then state.fired_once[id] = true end
    if ev.immediate then eval.effect(ev.immediate, ctx) end
    if #ev.options > 0 then
        local opt = choose_option(ev, ctx)
        stats.options = stats.options + 1
        eval.effect(opt, ctx, OPTION_PARAMS)
    end
    if ev.after then eval.effect(ev.after, ctx) end
    return true
end

local function queue_delayed(id, scope, ctx, days)
    local l = state.delayed[scope.key]
    if not l then l = {}; state.delayed[scope.key] = l end
    local targets = {}
    for k, v in pairs(ctx.targets) do targets[k] = v end
    l[#l + 1] = { due = eval.today() + days, id = id, scope = scope, from = ctx.this, targets = targets }
    stats.delayed_queued = stats.delayed_queued + 1
end

-- `country_event = { id = x days = 10 random = 5 scopes = { from = ... } }`
function eval.fire_event_effect(kind, e, ctx)
    local id, days, rnd, from = nil, 0, 0, nil
    if e.value.text then
        id = e.value.text
    else
        for _, x in ipairs(e.value) do
            if x.op then
                local k = x.key.text:lower()
                if k == "id" then id = x.value.text
                elseif k == "days" then days = eval.value(x.value, ctx, x)
                elseif k == "months" then days = eval.value(x.value, ctx, x) * 30
                elseif k == "years" then days = eval.value(x.value, ctx, x) * 360
                elseif k == "random" or k == "random_days" then rnd = eval.value(x.value, ctx, x)
                elseif k == "scopes" and x.value.text == nil then
                    for _, y in ipairs(x.value) do
                        if y.op and y.key.text:lower() == "from" and y.value.text then
                            local f, sc = eval.resolve(y.value.text, ctx, y)
                            if f then from = sc end
                        end
                    end
                end
            end
        end
    end
    if not id then return end
    stats.script = stats.script + 1
    if rnd > 0 then days = days + eval.rand() % (math.floor(rnd) + 1) end
    if days > 0 then
        return queue_delayed(id, ctx.this, ctx, math.floor(days))
    end
    -- an event fired at once reads engine state: the barrier first
    eval.sync()
    M.fire(id, ctx.this, ctx, from)
end

function M.on_action(name, scope, from_ctx)
    stats.on_actions[name] = (stats.on_actions[name] or 0) + 1
    local oa = db.on_actions[name]
    if not oa then return end
    local ctx = eval.new_ctx(scope, from_ctx and from_ctx.this or NONE, nil, oa.file)
    for _, t in ipairs(oa.triggers) do
        if not eval.trigger(t, ctx) then return end
    end
    for _, id in ipairs(oa.events) do
        stats.on_action_events = stats.on_action_events + 1
        M.fire(id, scope, ctx)
    end
    if #oa.random_events > 0 then
        local total = 0
        for _, r in ipairs(oa.random_events) do total = total + math.floor(r[1]) end
        if total > 0 then
            local x = eval.rand() % total
            for _, r in ipairs(oa.random_events) do
                if x < r[1] then
                    if r[2] ~= "0" then
                        stats.on_action_events = stats.on_action_events + 1
                        M.fire(r[2], scope, ctx)
                    end
                    break
                end
                x = x - math.floor(r[1])
            end
        end
    end
    for _, b in ipairs(oa.effects) do
        eval.effect(b, ctx)
    end
end
eval.on_action = function(name, scope, ctx) return M.on_action(name, scope, ctx) end

-- delayed events of one scope that are due
function M.run_delayed(key)
    local l = state.delayed[key]
    if not l or #l == 0 then return end
    local today = eval.today()
    local keep, due = {}, {}
    for _, d in ipairs(l) do
        if d.due <= today then due[#due + 1] = d else keep[#keep + 1] = d end
    end
    state.delayed[key] = keep
    for _, d in ipairs(due) do
        M.fire(d.id, d.scope, { this = d.from, from = NONE, targets = d.targets }, d.from)
    end
end

-- mean time to happen: the chance per daily check is 1 - 2^(-1/mtth_days) (half the scopes
-- that keep meeting the trigger have fired by the MTTH)
function M.run_mtth(scope)
    local l = mtth_by_kind[scope.kind]
    if not l then return end
    for _, ev in ipairs(l) do
        if not (ev.once and state.fired_once[ev.id]) then
            local ctx = eval.new_ctx(scope, NONE, nil, ev.file)
            if (not ev.pre_triggers or eval.trigger(ev.pre_triggers, ctx)) and (not ev.trigger or eval.trigger(ev.trigger, ctx)) then
                local days = eval.weight(ev.mtth, ctx, 360)
                stats.mtth_rolls = stats.mtth_rolls + 1
                if days > 0 then
                    local p = 1 - 2 ^ (-1 / days)
                    if eval.rand() % 1000000 < p * 1000000 then
                        M.fire(ev.id, scope, nil)
                    end
                end
            end
        end
    end
end

function M.scope_day(kind, id)
    local sc = S(kind, id)
    M.run_delayed(sc.key)
    M.run_mtth(sc)
end

-- the day's delayed events of scopes without a daily call of their own (none, leaders, pops)
function M.global_day()
    local keys = {}
    for k in pairs(state.delayed) do
        if not (k:sub(1, 8) == "country:" or k:sub(1, 7) == "planet:") then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do M.run_delayed(k) end
end

return M
