-- simscript/host.lua : the entry points sim/src/lua_host.rs calls (the ScriptHost trait).
--
-- Each call returns what it did: (script effects applied, engine effects queued). Errors inside
-- one event are caught and counted (stats.errors) so one bad event does not stop a pulse.

local db = require("simscript.db")
local eval = require("simscript.eval")
local events = require("simscript.events")

local host = {}
local stats = eval.stats
stats.errors = 0
stats.error_messages = {}

local function guarded(f, ...)
    local ok, err = pcall(f, ...)
    if not ok then
        stats.errors = stats.errors + 1
        if #stats.error_messages < 10 then
            stats.error_messages[#stats.error_messages + 1] = tostring(err)
        end
    end
end

-- events.fire, guarded: an error in one event does not abort its caller
local fire = events.fire
events.fire = function(...)
    local ok, r = pcall(fire, ...)
    if not ok then
        stats.errors = stats.errors + 1
        if #stats.error_messages < 10 then
            stats.error_messages[#stats.error_messages + 1] = tostring(r)
        end
        return false
    end
    return r
end

local function counted(f, ...)
    local s0, e0 = stats.script, stats.engine
    guarded(f, ...)
    return stats.script - s0, stats.engine - e0
end

function host.init(game_dir, docs_dir)
    db.load(game_dir, docs_dir)
    events.index()
end

function host.eval_trigger(id, kind, sid)
    local def = db.scripted_triggers[id]
    if not def then
        eval.miss("trigger", id)
        return false
    end
    local body = db.instance("trigger", def, id, {})
    if not body then return false end
    return eval.trigger(body, eval.new_ctx(eval.S(kind, sid), nil, nil, def.file))
end

-- a scripted effect by name, or an event by id
function host.run_effect(id, kind, sid)
    return counted(function()
        local sc = eval.S(kind, sid)
        local def = db.scripted_effects[id]
        if def then
            local body = db.instance("effect", def, id, {})
            if body then eval.effect(body, eval.new_ctx(sc, nil, nil, def.file)) end
        elseif db.events[id] then
            events.fire(id, sc, nil)
        else
            eval.miss("effect", id)
        end
    end)
end

-- seed: the value the game made the on_action's scope from (CEventScope(int)), when the engine
-- drew one; else the scope is a default one's (simscript/events.lua)
function host.on_action(name, kind, sid, seed)
    local rng = seed and require("engine.script.scope_random").new(seed) or nil
    return counted(events.on_action, name, eval.S(kind, sid), nil, rng)
end

function host.weight()
    return nil
end

function host.daily_script_state()
    guarded(events.global_day)
end

function host.scope_daily_events(kind, sid)
    return counted(events.scope_day, kind, sid)
end

local function sorted_by_count(t, n)
    local l = {}
    for k, v in pairs(t) do
        l[#l + 1] = type(v) == "table" and v or { key = k, count = v }
        if type(v) ~= "table" then l[#l].key = k end
    end
    table.sort(l, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return tostring(a.kind or "") .. a.key < tostring(b.kind or "") .. b.key
    end)
    local out = {}
    for i = 1, math.min(n or #l, #l) do out[i] = l[i] end
    return out, #l
end

function host.report()
    local out = {}
    local function p(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local c = db.counts
    p("load: %d events, %d on_actions, %d scripted triggers, %d scripted effects, %d script values, %d static modifiers, %d scripted variables, %d load errors, %.1f s",
        c.events, c.on_actions, c.scripted_triggers, c.scripted_effects, c.script_values, c.static_modifiers,
        c.scripted_variables, c.load_errors, c.seconds)
    local fired, nfired = sorted_by_count(stats.fired, 30)
    p("run: %d events fired (%d distinct), %d stopped by their trigger, %d options chosen, %d MTTH checks, %d delayed queued",
        stats.fired_total, nfired, stats.trigger_failed, stats.options, stats.mtth_rolls, stats.delayed_queued)
    p("     %d script effects, %d engine effects queued, %d flushes inside effects, %d trigger evaluations, %d effect statements, %d Lua errors",
        stats.script, stats.engine, stats.flushes, stats.trigger_evals, stats.effect_runs, stats.errors)
    if eval.compiler then p("%s", eval.compiler.report()) end
    local oas = sorted_by_count(stats.on_actions)
    local l = {}
    for _, o in ipairs(oas) do l[#l + 1] = o.key .. " " .. o.count end
    p("on_actions fired: %s", table.concat(l, ", "))
    p("events fired (top 30):")
    for _, f in ipairs(fired) do p("  %6d  %s", f.count, f.key) end
    local miss, nmiss = sorted_by_count(stats.missing, 40)
    local hits = 0
    for _, m in pairs(stats.missing) do hits = hits + m.count end
    p("not implemented, hit while running: %d keywords, %d hits (top 40: kind keyword hits first-location)", nmiss, hits)
    for _, m in ipairs(miss) do p("  %-12s %-45s %7d  %s", m.kind, m.key, m.count, m.first) end
    local un, nun = sorted_by_count(stats.unmodelled, 25)
    p("engine effects queued without an engine model: %d keywords (top 25)", nun)
    for _, m in ipairs(un) do p("  %-45s %7d  %s", m.key, m.count, m.first) end
    local unk, nunk = sorted_by_count(stats.unknown_events, 10)
    if nunk > 0 then
        p("events referenced but not defined: %d", nunk)
        for _, m in ipairs(unk) do p("  %-45s %7d", m.key, m.count) end
    end
    for _, m in ipairs(stats.error_messages) do p("error: %s", m) end
    return table.concat(out, "\n")
end

function host.coverage()
    return require("simscript.coverage").run()
end

return host
