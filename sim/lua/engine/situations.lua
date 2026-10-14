-- engine/situations.lua : situations (common/situations), the way the game advances them (GOG
-- 4.5.2, docs/situations.md), on the save's store
--
--   situations = { situations = { 0 = { country = 29 target = { type = none id = 0 }
--       type = "pre_ftl_tech_progress_situation" progress = 1360.125 last_month_progress = 0.3125
--       approach = "approach_revolt_do_nothing" stage_durations = { { start = 0 end = 1920 } }
--       stage_flags = { yes } flags = { ... } stage = 0 } } }
--
-- Once a month, in CGameState::MonthlyUpdate:
--
-- 1. after the budget, in the parallel per-country lambda (`CGameState::MonthlyUpdate'::`21'::
--    <lambda_1>, 0x262d20), each situation's monthly progress is computed into its private cache
--    (CSituation::SSafePrivate::_LatestMonthlyProgress, +0x38): CSituation::GetMonthlyProgress
--    (0x619a50) = CMeanTimeToHappen::GetRawFactor (0x342930) of the type's `monthly_progress`
--    (CSituationType +0x5c0) with the situation as scope: `base` (0 when absent: the type's
--    constructor), then each `modifier` whose triggers hold applies its add / subtract / mult in
--    order, in CFixedPoint. Skipped: a situation to be killed (+0x660) or locked (+0x661), 0 when
--    locked; a non-permanent one outside [start, end) (it has finished);
-- 2. in CCountry::MonthlyUpdateSerial, after the leaders' experience and before the country's
--    monthly pulse, CCountryEventManager::MonthlyUpdateSerial (0x804c90) runs
--    CSituation::HandleMonthlyTickSerial (0x61c240) on each of the country's situations, then
--    destroys those marked to be killed (CGameState::DestroySituation):
--      to be killed or locked: nothing; finished: nothing (an error is logged unless an event of
--      it is open); else one draw for the event scope (line 898); with section weights the stage
--      durations rebuilt (RebuildStageDurations, not modelled: the save's are kept);
--      last_month_progress = the cache; progress += the cache; HandleProgressChanged(draw);
--      the type's `on_monthly` (an on_action named after the type, COnActionDatabase::
--      PerformEvent on CSituationType +0x508) unless it has finished.
--
-- CSituation::HandleProgressChanged (0x61f910): the progress clamped to [start - 1, end]
-- (permanent: [start, end]); CSituation::UpdateStage (0x61f060); then, not permanent, below the
-- start: `on_fail` (CSituationType +0x1d8), at or above the end: `on_progress_complete` (+0x118),
-- each with one draw for its scope (lines 1318, 1324) when called with draw.
-- CSituation::UpdateStage: the stage is the first whose `end` the progress has not reached (at most
-- the last); a change walks the stages in between one by one (the UpdateStage lambda, 0x61f190):
-- the index set, one draw (line 1205), the stage's `on_enter`; the first time (stage_flags) one
-- more draw (line 1251) and `on_first_enter`.
--
-- start = the first stage duration's `start` (the type's start_value when there are none), end =
-- the last one's `end`. CSituation::HasFinished (0x61a4f0): not permanent and progress outside
-- [start, end).
--
-- Not modelled: the creation of situations by the engine (deficits: CCountry::MonthlyUpdateSerial
-- -> HasResourceShortage -> CCountryEventManager::StartSituation; start_situation), approaches
-- (the AI's choice, their upkeep), the situations' modifiers (the modifier graph builds them),
-- section weights (RebuildStageDurations), the dead_situation store.

local world = require("engine.world")
local defs = require("engine.defs")

world.KINDS.situation = world.KINDS.situation or "situations"

local situations = {
    stats = { months = 0, computed = 0, ticked = 0, finished = 0, locked = 0, stage_changes = 0,
        on_fail = 0, on_complete = 0, on_monthly = 0, destroyed = 0, section_weights = 0, errors = 0,
        unknown_types = 0 },
    errors = {},
    monthly = {},   -- situation id -> its cached monthly progress (CFixedPoint), SSafePrivate +0x0
}

local FP = 100000
local NO_ID = 4294967295

-- a number as a CFixedPoint (the save writes 5 decimals: exact)
local function fp(v)
    v = tonumber(v) or 0
    if v >= 0 then
        return math.floor(v * FP + 0.5)
    end
    return -math.floor(-v * FP + 0.5)
end
local function trunc(x)
    return x >= 0 and math.floor(x) or -math.floor(-x)
end
-- CFixedPoint operator*: (a * b) / 100000 truncated toward zero, computed as the game's
-- overflow-safe path does (a = q * 100000 + r: q * b + (r * b) / 100000), exact in doubles
local function fmul(a, b)
    local q = trunc(a / FP)
    local r = a - q * FP
    return q * b + trunc(r * b / FP)
end
situations.fp, situations.fmul = fp, fmul

local function yes(v)
    return v == "yes"
end

local function eval()
    return require("simscript.eval")
end

-- ---------------------------------------------------------------------------------------------
-- the types (common/situations), read once

local type_cache = {}
local function stype(key)
    local t = type_cache[key]
    if t ~= nil then
        return t or nil
    end
    local d = defs.get("common/situations", key)
    if not d then
        type_cache[key] = false
        return nil
    end
    local b = d.block
    t = { key = key, file = d.file, block = b, stages = {},
        permanent = defs.field(b, "permanent") == "yes",
        start_value = tonumber(defs.field(b, "start_value")) or 0,
        section_weights = defs.field(b, "total_progress") ~= nil,
        monthly_progress = defs.field(b, "monthly_progress"),
        on_monthly = defs.field(b, "on_monthly"),
        on_fail = defs.field(b, "on_fail"),
        on_progress_complete = defs.field(b, "on_progress_complete") }
    local stages = defs.field(b, "stages")
    for _, e in ipairs(type(stages) == "table" and stages or {}) do
        if e.op and e.key and e.value.text == nil then
            t.stages[#t.stages + 1] = { key = e.key.text, block = e.value,
                on_enter = defs.field(e.value, "on_enter"), on_first_enter = defs.field(e.value, "on_first_enter") }
        end
    end
    type_cache[key] = t
    return t
end
situations.type = stype

-- the type's `on_monthly` as an on_action named after the type (the game's COnActionList; the
-- README: "technically, this is an on_action called <the situation's key>"), registered with the
-- script layer's on_actions the first time
local function on_monthly_action(t)
    if t.on_action ~= nil then
        return t.on_action or nil
    end
    local db = require("simscript.db")
    local b = t.on_monthly
    if type(b) ~= "table" or db.on_actions[t.key] then
        t.on_action = db.on_actions[t.key] and t.key or false
        return t.on_action or nil
    end
    local oa = { name = t.key, events = {}, random_events = {}, triggers = {}, effects = {}, file = t.file }
    for _, x in ipairs(b) do
        if x.op and x.key and x.value.text == nil then
            local k = x.key.text:lower()
            if k == "events" then
                for _, id in ipairs(x.value) do
                    if id.text then oa.events[#oa.events + 1] = id.text end
                end
            elseif k == "random_events" then
                for _, r in ipairs(x.value) do
                    if r.op and r.value.text then
                        oa.random_events[#oa.random_events + 1] = { tonumber(r.key.text) or 0, r.value.text, r.line }
                    end
                end
            elseif k == "trigger" then
                oa.triggers[#oa.triggers + 1] = x.value
            elseif k == "effect" then
                oa.effects[#oa.effects + 1] = x.value
            end
        end
    end
    db.on_actions[t.key] = oa
    t.on_action = t.key
    return t.key
end

-- ---------------------------------------------------------------------------------------------
-- a situation's state in the save

local function durations(s)
    local out = {}
    for _, b in ipairs(world.blocks(world.field(s, "stage_durations"))) do
        out[#out + 1] = { start = fp(world.field(b, "start")), stop = fp(world.field(b, "end")) }
    end
    return out
end

-- start and end of the bar (HasFinished, HandleProgressChanged)
local function bounds(s, t)
    local d = durations(s)
    local start = d[1] and d[1].start or fp(t and t.start_value or 0)
    local stop = d[#d] and d[#d].stop or 0
    return start, stop, d
end

local function progress_of(s)
    return fp(world.field(s, "progress"))
end
local function set_progress(s, v)
    world.set(s, "progress", v / FP)
end

-- CSituation::HasFinished (0x61a4f0)
local function has_finished(s, t)
    if t and t.permanent then
        return false
    end
    local start, stop = bounds(s, t)
    local p = progress_of(s)
    return p < start or p >= stop
end
situations.has_finished = function(id)
    local s = world.object("situation", id)
    return s ~= nil and has_finished(s, stype(world.field(s, "type")))
end

-- an effect block run on the situation's scope; an error is caught and counted (a phase is not cut
-- short by one situation)
local function run_effect(block, sid, t, what)
    if type(block) ~= "table" then
        return
    end
    local ev = eval()
    local ok, err = pcall(ev.effect, block, ev.new_ctx(ev.S("situation", sid), nil, nil, t.file))
    if not ok then
        situations.stats.errors = situations.stats.errors + 1
        if #situations.errors < 10 then
            situations.errors[#situations.errors + 1] = string.format("%s %s: %s", t.key, what, tostring(err))
        end
    end
end

local function draw()
    return E.rand()
end

-- the stage_flags list (`stage_flags = { yes no }`), one per stage
local function stage_flags(s)
    local b = world.field(s, "stage_flags")
    if type(b) ~= "table" then
        b = world.child(s, "stage_flags")
    end
    return b
end

-- `CSituation::UpdateStage'::`2'::<lambda_1> (0x61f190): stage i entered
local function enter_stage(s, sid, t, i, with_draw)
    local st = t.stages[i + 1]
    if not st then
        return
    end
    if with_draw then
        draw() -- line 1205: the scope's random
    end
    world.set(s, "stage", i)
    situations.stats.stage_changes = situations.stats.stage_changes + 1
    run_effect(st.on_enter, sid, t, "on_enter")
    -- the first time: the stage's flag, on_first_enter
    local flags = stage_flags(s)
    local entries = {}
    for _, e in ipairs(flags) do
        if e.text then entries[#entries + 1] = e end
    end
    local f = entries[i + 1]
    if not (f and f.text == "yes") then
        for k = #entries + 1, i + 1 do
            world.append_value(flags, "no")
            entries[k] = flags[#flags]
        end
        world.set_entry(flags, entries[i + 1], "yes")
        if with_draw then
            draw() -- line 1251
        end
        run_effect(st.on_first_enter, sid, t, "on_first_enter")
    end
end

-- CSituation::UpdateStage (0x61f060)
local function update_stage(s, sid, t, with_draw)
    local d = durations(s)
    local p = progress_of(s)
    local n = #d
    local new = 0
    for _, x in ipairs(d) do
        if p < x.stop then break end
        new = new + 1
    end
    if new > n - 1 then new = n - 1 end
    local cur = tonumber(world.field(s, "stage")) or -1
    if new == cur then
        return
    end
    if cur < 0 then
        enter_stage(s, sid, t, new, with_draw)
    elseif new > cur then
        for i = cur + 1, new do enter_stage(s, sid, t, i, with_draw) end
    else
        for i = cur - 1, new, -1 do enter_stage(s, sid, t, i, with_draw) end
    end
end

-- CSituation::HandleProgressChanged (0x61f910)
local function progress_changed(s, sid, t, with_draw)
    local start, stop = bounds(s, t)
    local lower = t.permanent and start or start - FP
    local p = progress_of(s)
    if p < lower then
        set_progress(s, lower)
    elseif p > stop then
        set_progress(s, stop)
    end
    update_stage(s, sid, t, with_draw)
    if t.permanent then
        return
    end
    p = progress_of(s)
    if p < start then
        if with_draw then draw() end -- line 1318
        situations.stats.on_fail = situations.stats.on_fail + 1
        run_effect(t.on_fail, sid, t, "on_fail")
    elseif p >= stop then
        if with_draw then draw() end -- line 1324
        situations.stats.on_complete = situations.stats.on_complete + 1
        run_effect(t.on_progress_complete, sid, t, "on_progress_complete")
    end
end
situations.progress_changed = function(id, with_draw)
    local s = world.object("situation", id)
    local t = s and stype(world.field(s, "type"))
    if t then progress_changed(s, id, t, with_draw) end
end

-- ---------------------------------------------------------------------------------------------
-- the monthly progress: CMeanTimeToHappen::GetRawFactor of `monthly_progress`, in CFixedPoint

local MODIFIER_PARAMS = { add = true, subtract = true, mult = true, multiply = true, factor = true,
    desc = true, weight = true, base = true }

local function apply(acc, k, v)
    if k == "add" then return acc + v
    elseif k == "subtract" then return acc - v
    elseif k == "mult" or k == "multiply" or k == "factor" then return fmul(acc, v)
    end
    return acc
end

local function raw_factor(block, ctx)
    local ev = eval()
    local acc = 0
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text:lower()
            if k == "base" or k == "weight" then
                acc = fp(ev.value(e.value, ctx, e))
            elseif k == "add" or k == "subtract" or k == "mult" or k == "multiply" or k == "factor" then
                acc = apply(acc, k, fp(ev.value(e.value, ctx, e)))
            elseif k == "modifier" and e.value.text == nil then
                if ev.trigger(e.value, ctx, MODIFIER_PARAMS) then
                    for _, x in ipairs(e.value) do
                        if x.op and x.key then
                            local xk = x.key.text:lower()
                            if xk == "add" or xk == "subtract" or xk == "mult" or xk == "multiply" or xk == "factor" then
                                acc = apply(acc, xk, fp(ev.value(x.value, ctx, x)))
                            end
                        end
                    end
                end
            end
        end
    end
    return acc
end
situations.raw_factor = raw_factor

-- CSituation::GetMonthlyProgress (0x619a50)
local function monthly_progress_of(s, sid, t)
    if yes(world.field(s, "locked")) then
        return 0
    end
    if type(t.monthly_progress) ~= "table" then
        return 0
    end
    local ev = eval()
    return raw_factor(t.monthly_progress, ev.new_ctx(ev.S("situation", sid), nil, nil, t.file))
end

-- `CGameState::MonthlyUpdate'::`21'::<lambda_1> (0x262d20): every situation's monthly progress
-- (no random draws: the game computes it in parallel, between the budget and the countries'
-- serial update)
function situations.monthly_progress(host, date)
    situations.stats.months = situations.stats.months + 1
    for _, sid in ipairs(world.all("situation")) do
        local s = world.object("situation", sid)
        local t = s and stype(world.field(s, "type"))
        if t and not yes(world.field(s, "to_be_killed")) and not yes(world.field(s, "locked"))
            and (t.permanent or not has_finished(s, t)) then
            situations.monthly[sid] = monthly_progress_of(s, sid, t)
            situations.stats.computed = situations.stats.computed + 1
        elseif s and not t then
            situations.stats.unknown_types = situations.stats.unknown_types + 1
        end
    end
end

-- CSituation::HandleMonthlyTickSerial (0x61c240)
local function tick(host, sid)
    local s = world.object("situation", sid)
    local t = s and stype(world.field(s, "type"))
    if not t then
        return
    end
    if yes(world.field(s, "to_be_killed")) or yes(world.field(s, "locked")) then
        situations.stats.locked = situations.stats.locked + 1
        return
    end
    if has_finished(s, t) then
        situations.stats.finished = situations.stats.finished + 1
        return
    end
    situations.stats.ticked = situations.stats.ticked + 1
    draw() -- line 898: the random of the situation's event scope
    if t.section_weights then
        situations.stats.section_weights = situations.stats.section_weights + 1
    end
    local m = situations.monthly[sid]
    if m == nil then
        m = fp(world.field(s, "last_month_progress"))
    end
    world.set(s, "last_month_progress", m / FP)
    if not has_finished(s, t) then
        set_progress(s, progress_of(s) + m)
        progress_changed(s, sid, t, true)
    end
    -- (UpdateTriggeredBlockedDescriptions: the interface's)
    if world.object("situation", sid) and not has_finished(s, t) then
        local name = on_monthly_action(t)
        if name then
            situations.stats.on_monthly = situations.stats.on_monthly + 1
            host.on_action(name, "situation", sid)
        end
    end
end

-- the situations of a country, in their order (CCountryEventManager's array: the store's)
local function of_country(country)
    local out = {}
    for _, sid in ipairs(world.all("situation")) do
        if tonumber(world.field(world.object("situation", sid), "country")) == country then
            out[#out + 1] = sid
        end
    end
    return out
end
situations.of_country = of_country

-- CCountryEventManager::MonthlyUpdateSerial (0x804c90), the situations' part: each of the
-- country's situations ticked, then those to be killed destroyed
function situations.country_monthly(host, date, country)
    for _, sid in ipairs(of_country(country)) do
        tick(host, sid)
        local s = world.object("situation", sid)
        if s and yes(world.field(s, "to_be_killed")) then
            world.remove("situation", sid)
            situations.monthly[sid] = nil
            situations.stats.destroyed = situations.stats.destroyed + 1
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- what the script layer reads of situations, where simscript does not have it yet (registered
-- only when absent: simscript.eval's own definition wins)

local function install()
    local ev = eval()
    local S, L, T, EFF = ev.S, ev.LINKS, ev.TRIG, ev.EFF
    -- owner: a situation's country (CSituation::_Country, the save's `country`)
    local base_owner = L.owner
    L.owner = function(cur, ctx)
        if cur.kind == "situation" then
            local c = tonumber(world.field(world.object("situation", cur.id), "country"))
            return (c and c ~= NO_ID and world.object("country", c)) and S("country", c) or nil
        end
        return base_owner(cur, ctx)
    end
    -- target: a situation's target (CSituation::_Target, `target = { type = planet id = 3 }`)
    if not L.target then
        local KIND = { country = "country", planet = "planet", galactic_object = "system", leader = "leader",
            fleet = "fleet", ship = "ship", species = "species", federation = "federation", starbase = "starbase" }
        L.target = function(cur)
            if cur.kind ~= "situation" then return nil end
            local tg = world.field(world.object("situation", cur.id), "target")
            local kind = type(tg) == "table" and KIND[tostring(world.field(tg, "type"))]
            local id = kind and tonumber(world.field(tg, "id"))
            return (id and world.object(kind, id)) and S(kind, id) or nil
        end
    end
    -- current_awareness_level = low (a country's `awareness`; the NGameplay AWARENESS_*_LIMIT
    -- bounds, exclusive: unaware < 1 <= low < 30 <= medium < 60 <= high < 100 <= full)
    if not T.current_awareness_level then
        local function level(a)
            if a < 1 then return "unaware" elseif a < 30 then return "low" elseif a < 60 then return "medium"
            elseif a < 100 then return "high" end
            return "full"
        end
        T.current_awareness_level = function(e, ctx)
            if ctx.this.kind ~= "country" then return false end
            local a = tonumber(world.field(world.object("country", ctx.this.id), "awareness")) or 0
            local want = tostring(e.value.text)
            if want == "partial" then want = "medium" end
            return level(a) == want
        end
    end
    -- situation_monthly_progress > x: the situation's cached monthly progress (SSafePrivate)
    if not T.situation_monthly_progress then
        T.situation_monthly_progress = function(e, ctx)
            if ctx.this.kind ~= "situation" then return false end
            local m = situations.monthly[ctx.this.id]
            if m == nil then m = fp(world.field(world.object("situation", ctx.this.id), "last_month_progress")) end
            return ev.compare(m / FP, e.op, ev.value(e.value, ctx, e))
        end
    end
    if not T.current_situation_approach then
        T.current_situation_approach = function(e, ctx)
            if ctx.this.kind ~= "situation" then return false end
            return world.field(world.object("situation", ctx.this.id), "approach") == e.value.text
        end
    end
    -- destroy_situation = this: the situation marked to be killed (CSituation +0x660), destroyed
    -- after its country's monthly update
    if not EFF.destroy_situation then
        EFF.destroy_situation = function(e, ctx)
            local found, sc = ev.resolve(e.value.text or "this", ctx, e)
            if not found then sc = ctx.this end
            if sc and sc.kind == "situation" and world.object("situation", sc.id) then
                world.set(world.object("situation", sc.id), "to_be_killed", "yes")
            end
        end
    end
end
install()

function situations.report()
    local st = situations.stats
    local s = string.format("situations: %d months, %d progress computed, %d ticked (%d finished, %d locked), %d stage changes, %d on_fail, %d on_progress_complete, %d on_monthly, %d destroyed, %d errors",
        st.months, st.computed, st.ticked, st.finished, st.locked, st.stage_changes, st.on_fail, st.on_complete,
        st.on_monthly, st.destroyed, st.errors)
    for _, m in ipairs(situations.errors) do s = s .. "\n  error: " .. m end
    return s
end

return situations
