-- simscript/events.lua : events, on_actions, delayed events, MTTH, and the AI's option choice.
--
-- Events and their queues are script state: they live here. The engine says when (pulses and
-- engine on_actions through host.on_action, each scope's day through host.scope_daily_events);
-- what fires, with which trigger, chance and option, is decided in Lua.
--
-- The game's random model (GOG 4.5.2; docs/script_creation.md "Scope random", "Events"):
-- - an event's scope carries its own random state (engine.script.scope_random, eval.scope_rng): the
--   script's draws (random, random_list, random_* iterators, a delayed event's random days, the
--   scope of an event an effect fires) come from it, not from the game's generator;
-- - the game's generator (E.rand) is drawn only where the game draws it: the AI's option choice
--   (CEventManager::TriggerEvent), an on_action's random_events pick
--   (COnActionList::GetRandomValidEvent), and the MTTH roll (not ported: see run_mtth).
-- Delayed events written in the save (a planet's `delayed_event`, a country's
-- standard_event_module `delayed_event`) are loaded with their scopes and kept there as they count
-- down (CDelayedEventManager).

local db = require("simscript.db")
local eval = require("simscript.eval")
local SR = require("engine.script.scope_random")

local M = {}
local S, NONE = eval.S, eval.NONE
local state, stats = eval.state, eval.stats

state.delayed = {}      -- scope key -> array of delayed entries (see queue_delayed)
local mtth_by_kind = {} -- scope kind -> array of events with mean_time_to_happen

stats.fired = {}        -- event id -> count
stats.fired_total = 0
stats.trigger_failed = 0
stats.on_actions = {}   -- name -> count
stats.on_action_events = 0
stats.options = 0
stats.option_draws = 0
stats.human_options = 0
stats.mtth_rolls = 0
stats.delayed_queued = 0
stats.delayed_loaded = 0
stats.delayed_fired = 0
stats.random_event_draws = 0
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

local floor = math.floor
local function trunc(x)
    return x < 0 and -floor(-x) or floor(x)
end

-- ---------------------------------------------------------------------------------------------
-- the human players (the save's `player = { { name country } }`): their events are opened for them,
-- not chosen by the AI

local humans
local function is_human(country)
    if humans == nil then
        humans = {}
        local world = package.loaded["engine.world"]
        for _, e in ipairs(world and world.tree or {}) do
            if e.op and e.key and e.key.text == "player" and e.value.text == nil then
                for _, p in ipairs(world.blocks(e.value)) do
                    local c = tonumber(world.field(p, "country"))
                    if c then humans[c] = true end
                end
            end
        end
    end
    return country ~= nil and humans[country] == true
end

-- the country an event is for (CEventScope::GetTargetCountry: the scope's country or owner)
local function target_country(ctx)
    local sc = ctx.this
    if sc.kind == "country" then return sc.id end
    local found, owner = eval.resolve("owner", ctx, nil)
    return found and owner and owner.kind == "country" and owner.id or nil
end

-- ---------------------------------------------------------------------------------------------
-- options

local function option_ok(opt, ctx)
    for _, x in ipairs(opt) do
        if x.op then
            local k = x.key.text:lower()
            if (k == "trigger" or k == "allow") and x.value.text == nil and not eval.trigger(x.value, ctx) then
                return false
            end
        end
    end
    return true
end

local function ai_chance(opt, ctx)
    for _, x in ipairs(opt) do
        if x.op and x.key.text:lower() == "ai_chance" and x.value.text == nil then
            return eval.weight(x.value, ctx, 1)
        end
    end
    return 1
end

-- the AI's option (CEventManager::TriggerEvent 0x3f6170): the valid options' ai_chance summed (raw
-- fixed point); one draw of the game's generator, r = draw % 100; each option's share
-- trunc(100 * chance / total) (as the game divides, by total / 100) accumulated, the first option
-- with r <= the sum taken; none (rounding, or no positive chance): the first valid option [V]
local function choose_option(ev, ctx)
    local valid, total = {}, 0
    for i, opt in ipairs(ev.options) do
        if option_ok(opt, ctx) then
            local w = floor(ai_chance(opt, ctx) * 100000 + 0.5)
            valid[#valid + 1] = { opt, w, i }
            if w > 0 then total = total + w end
        end
    end
    if #valid == 0 then
        return nil
    end
    if total <= 0 then
        return valid[1][1]
    end
    local per = trunc(total / 100)
    stats.option_draws = stats.option_draws + 1
    local r = eval.rand() % 100
    local cum = 0
    for _, v in ipairs(valid) do
        local pct = per ~= 0 and trunc(trunc(v[2] * 100000 / per) / 100000) or 0
        cum = cum + pct
        if r <= cum then
            return v[1]
        end
    end
    return valid[1][1]
end

-- ---------------------------------------------------------------------------------------------
-- firing

-- the event run in its scope ctx (CEventManager::TriggerEvent): immediate, the option (the AI's
-- choice; a human's event takes its first valid option at once [I]), after. The trigger is the
-- caller's (CEvent::IsValid where the game checks it).
-- after each root effect (immediate, option, after): what the game does at the end of
-- CRootEffect::Execute (its modifier nodes updated: engine.script.creation)
local function after_root()
    local c = package.loaded["engine.script.creation"]
    if c and c.after_root_effect then
        eval.sync()
        c.after_root_effect()
    end
end

local function run(ev, ctx)
    local id = ev.id
    stats.fired[id] = (stats.fired[id] or 0) + 1
    stats.fired_total = stats.fired_total + 1
    if ev.once then state.fired_once[id] = true end
    if ev.immediate then eval.effect(ev.immediate, ctx); after_root() end
    if #ev.options > 0 then
        local opt
        if is_human(target_country(ctx)) and not ev.hidden then
            stats.human_options = stats.human_options + 1
            -- the renderer's event windows hear of it (render.windows.events_data)
            if M.opened then M.opened(ev, ctx) end
            for _, o in ipairs(ev.options) do
                if option_ok(o, ctx) then opt = o; break end
            end
        else
            opt = choose_option(ev, ctx)
        end
        if opt then
            stats.options = stats.options + 1
            eval.effect(opt, ctx, OPTION_PARAMS)
            after_root()
        end
    end
    if ev.after then eval.effect(ev.after, ctx); after_root() end
    return true
end

-- the event's pre_triggers and trigger in its scope (CEvent::IsValid, with the pre-triggers' scope
-- checks)
local function valid(ev, ctx)
    if ev.pre_triggers and not eval.trigger(ev.pre_triggers, ctx) then
        return false
    end
    if ev.trigger and not eval.trigger(ev.trigger, ctx) then
        return false
    end
    return true
end

local function event_of(id)
    local ev = db.events[id]
    if not ev then
        stats.unknown_events[id] = (stats.unknown_events[id] or 0) + 1
    end
    return ev
end

-- fires an event now in a scope made for it: trigger, immediate, the option, after. rng: the
-- scope's random state (shared with the caller's scope when given, e.g. an on_action's events)
-- the save's event state read once the world is there (engine.script.event_save sets M.ensure)
local function ensure()
    if M.ensure then M.ensure() end
end

function M.fire(id, scope, from_ctx, from_scope, rng)
    ensure()
    local ev = event_of(id)
    if not ev then
        return false
    end
    if ev.once and state.fired_once[id] then
        return false
    end
    local targets = {}
    if from_ctx then
        for k, v in pairs(from_ctx.targets or {}) do targets[k] = v end
    end
    local ctx = eval.new_ctx(scope, from_scope or (from_ctx and from_ctx.this) or NONE, targets, ev.file)
    if from_ctx then ctx.fromfrom = from_ctx.from or NONE end
    if rng then ctx.rng = rng end
    if not valid(ev, ctx) then
        stats.trigger_failed = stats.trigger_failed + 1
        return false
    end
    return run(ev, ctx)
end

-- ---------------------------------------------------------------------------------------------
-- delayed events (CDelayedEventManager: AddEvent appends; DailyUpdateThreaded counts each down from
-- the list's end, and those at 0 whose event is valid go to the day's fire list; DailyUpdateSerial
-- fires them in that order, the trigger checked again [V])

-- a delayed entry: { id, days, scope (this), from, fromfrom, root, targets, rng, block }; block is
-- the save's `delayed_event = { }` when the save keeps it (engine.script.event_save)
local function queue_entry(key, entry)
    local l = state.delayed[key]
    if not l then l = {}; state.delayed[key] = l end
    l[#l + 1] = entry
end
M.queue_entry = queue_entry

-- the from chain a delayed event's scope keeps (CDelayedEventManager::AddEvent copies the scope and
-- its from scopes, trimmed to 7: CEventScope::TrimFroms): { this, rng, from_rec }; the firing
-- scope's random state as it is when the event is queued [V]
local function from_record(this, rng, up, depth)
    depth = depth or 1
    if depth > 7 then return nil end
    local rec = { this = this, rng = rng and SR.copy(rng) or nil }
    if up then rec.from_rec = from_record(up.this, up.rng, up.from_rec, depth + 1) end
    return rec
end
M.from_record = from_record

local function queue_delayed(id, ctx, days, from_scope, firing, from_rng)
    local targets = {}
    for k, v in pairs(ctx.targets) do targets[k] = v end
    local entry = { id = id, days = days, scope = ctx.this, from = from_scope or ctx.from, fromfrom = ctx.fromfrom,
        root = ctx.root, targets = targets, rng = eval.scope_rng(ctx) }
    if from_scope then
        entry.from_rec = from_record(from_scope, from_rng, nil)
    elseif firing then
        entry.from_rec = from_record(firing.this, eval.scope_rng(firing), firing.from_rec)
    end
    entry.due = eval.today() + days
    queue_entry(ctx.this.key, entry)
    stats.delayed_queued = stats.delayed_queued + 1
    if M.on_queued then M.on_queued(entry) end
end

-- the scope of an event fired by an effect (CFireEventEffect::InitializeScope 0x16e0570): this the
-- firing scope's object, from the firing scope; its random state H(draw + the object's id), the
-- draw from the firing scope; each `scopes = { from = x }` entry one more draw from the firing
-- scope, its own scope made from it (CEventScope(int)) [V]
local function event_scope(e, ctx, scopes)
    local d = eval.scope_draw(ctx)
    local nctx = eval.new_ctx(ctx.this, ctx.this, nil, ctx.file)
    for k, v in pairs(ctx.targets) do nctx.targets[k] = v end
    nctx.fromfrom = ctx.from
    nctx.rng = SR.new(d + (tonumber(ctx.this.id) or 0))
    local from, from_rng
    for _, y in ipairs(scopes or {}) do
        local dy = eval.scope_draw(ctx)
        if y.op and y.key.text:lower() == "from" and y.value.text then
            local f, sc = eval.resolve(y.value.text, ctx, y)
            if f then from, from_rng = sc, SR.new(dy) end
        end
    end
    if from then nctx.from = from end
    -- the from scope as the new scope sees it: the firing scope itself (its state as it goes on)
    nctx.from_rec = from and { this = from, rng = from_rng }
        or { this = ctx.this, rng = eval.scope_rng(ctx), from_rec = ctx.from_rec }
    return nctx, from, from_rng
end

-- `country_event = { id = x days = 10 random = 5 scopes = { from = ... } }` (CFireEventEffect::
-- ExecuteActual 0x16e0d70): the scope first; days > 0 with random: days + a draw from the firing
-- scope % random; days > 0: delayed; else the trigger in the new scope, then the event [V]
function eval.fire_event_effect(kind, e, ctx)
    local id, days, rnd, scopes = nil, 0, 0, nil
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
                elseif k == "scopes" and x.value.text == nil then scopes = x.value end
            end
        end
    end
    if not id then return end
    ensure()
    stats.script = stats.script + 1
    local nctx, from, from_rng = event_scope(e, ctx, scopes)
    days, rnd = trunc(days), trunc(rnd)
    if days > 0 then
        if rnd ~= 0 then days = days + eval.scope_draw(ctx) % rnd end
        return queue_delayed(id, nctx, days, from, ctx, from_rng)
    end
    local ev = event_of(id)
    if not ev or (ev.once and state.fired_once[id]) then return end
    -- an event fired at once reads engine state: the barrier first
    eval.sync()
    nctx.file = ev.file
    if not valid(ev, nctx) then
        stats.trigger_failed = stats.trigger_failed + 1
        return
    end
    run(ev, nctx)
end

-- ---------------------------------------------------------------------------------------------
-- on_actions (COnActionDatabase::PerformEvent 0x3fa2d0): each listed event that is valid, in order,
-- then one of the random events. The events share the on_action's scope (one random state, rng:
-- the caller's when it has one, else a default scope's). The random pick
-- (COnActionList::GetRandomValidEvent 0x3f9a20): the valid events and the empty entries (`0`), by
-- weight; when the sum is above 0, one draw of the game's generator % the sum [V]

function M.on_action(name, scope, from_ctx, rng)
    ensure()
    stats.on_actions[name] = (stats.on_actions[name] or 0) + 1
    local oa = db.on_actions[name]
    if not oa then return end
    rng = rng or SR.default()
    local ctx = eval.new_ctx(scope, from_ctx and from_ctx.this or NONE, nil, oa.file)
    for _, t in ipairs(oa.triggers) do
        if not eval.trigger(t, ctx) then return end
    end
    -- the events' from is the on_action's from (the caller's from_ctx.this), fromfrom its from
    local from_scope = from_ctx and from_ctx.this or NONE
    for _, id in ipairs(oa.events) do
        stats.on_action_events = stats.on_action_events + 1
        M.fire(id, scope, from_ctx, from_scope, rng)
    end
    if #oa.random_events > 0 then
        local list, total = {}, 0
        for _, r in ipairs(oa.random_events) do
            local w = floor(r[1])
            if r[2] == "0" then
                list[#list + 1] = { w, nil }
                total = total + w
            else
                local ev = event_of(r[2])
                if ev and not (ev.once and state.fired_once[r[2]]) then
                    local ectx = eval.new_ctx(scope, from_scope, nil, ev.file)
                    if from_ctx then
                        ectx.fromfrom = from_ctx.from or NONE
                        for k, v in pairs(from_ctx.targets or {}) do ectx.targets[k] = v end
                    end
                    ectx.rng = rng
                    if valid(ev, ectx) then
                        list[#list + 1] = { w, ev, ectx }
                        total = total + w
                    end
                end
            end
        end
        if total > 0 then
            stats.random_event_draws = stats.random_event_draws + 1
            local x = eval.rand() % total
            for _, r in ipairs(list) do
                x = x - r[1]
                if x < 0 then
                    if r[2] then
                        stats.on_action_events = stats.on_action_events + 1
                        run(r[2], r[3])
                    end
                    break
                end
            end
        end
    end
    for _, b in ipairs(oa.effects) do
        eval.effect(b, ctx)
    end
end
eval.on_action = function(name, scope, ctx, rng) return M.on_action(name, scope, ctx, rng) end

-- the delayed events of one scope that are due today, from the list's end; each still valid fires
-- in its saved scope
function M.run_delayed(key)
    local l = state.delayed[key]
    if not l or #l == 0 then return end
    local today = eval.today()
    local due = {}
    for i = #l, 1, -1 do
        local d = l[i]
        if d.due <= today then
            due[#due + 1] = d
            -- CPdxArray::SwapToTailRemoveAt: the last entry takes its place
            l[i] = l[#l]
            l[#l] = nil
            if M.on_removed then M.on_removed(d) end
        elseif M.on_tick then
            M.on_tick(d, d.due - today)
        end
    end
    for _, d in ipairs(due) do
        local ev = event_of(d.id)
        if ev and not (ev.once and state.fired_once[d.id]) then
            local ctx = eval.new_ctx(d.scope, d.from or NONE, d.targets, ev.file)
            ctx.fromfrom = d.fromfrom or NONE
            ctx.root = d.root or d.scope
            ctx.rng = d.rng
            ctx.from_rec = d.from_rec
            if valid(ev, ctx) then
                stats.delayed_fired = stats.delayed_fired + 1
                eval.sync()
                run(ev, ctx)
            else
                stats.trigger_failed = stats.trigger_failed + 1
            end
        end
    end
end

-- mean time to happen: the chance per daily check is 1 - 2^(-1/mtth_days) (half the scopes
-- that keep meeting the trigger have fired by the MTTH). Not the game's yet: the game rolls each
-- country's and colony's MTTH events from a stream of the daily pool
-- (CStandardEventCountryModule::DailyUpdateOnlyChangeSafePrivate 0x84c670: pool[(id + 4696) % 1000],
-- CNoiseRandom::GetInt64 % 1000000 against CEvent::GetChance); here one draw of the game's
-- generator per roll, as before [I]
function M.run_mtth(scope)
    local l = mtth_by_kind[scope.kind]
    if not l then return end
    for _, ev in ipairs(l) do
        if not (ev.once and state.fired_once[ev.id]) then
            local ctx = eval.new_ctx(scope, NONE, nil, ev.file)
            if valid(ev, ctx) then
                local days = eval.weight(ev.mtth, ctx, 360)
                stats.mtth_rolls = stats.mtth_rolls + 1
                if days > 0 then
                    local p = 1 - 2 ^ (-1 / days)
                    if eval.rand() % 1000000 < p * 1000000 then
                        run(ev, ctx)
                    end
                end
            end
        end
    end
end

function M.scope_day(kind, id)
    ensure()
    local sc = S(kind, id)
    M.run_delayed(sc.key)
    M.run_mtth(sc)
end

-- the day's delayed events of scopes without a daily call of their own (none, leaders, pops, fleets,
-- and the planets without a colony: CPlanet::DailyUpdateUnhabitableSerial)
function M.global_day()
    ensure()
    local keys = {}
    local world = package.loaded["engine.world"]
    for k in pairs(state.delayed) do
        local pid = k:sub(1, 7) == "planet:" and tonumber(k:sub(8))
        if pid then
            if world and world.pop_groups_of and not world.pop_groups_of[pid] then keys[#keys + 1] = k end
        elseif k:sub(1, 8) ~= "country:" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do M.run_delayed(k) end
end

-- the save's delayed events and global event targets, read and kept in the save's form (when the
-- engine's world is there)
require("engine.script.event_save").install(M)

return M
