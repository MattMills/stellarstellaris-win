-- render/windows/events_commands.lua : the commands of the event windows, the Situation Log and
-- Discoveries that change the world, run in the simulation's runtime (views.rs `command`: an
-- action `cmd:events_data:VERB:ARG...`, events_data.command passes the verbs it does not know here).
-- docs/windows/events.md.
--
--   effect TEXT                 a script effect run for the player's country (the game's console
--                               `effect`): granting minor artifacts, a relic, ... for a test
--   start_situation TYPE        a situation of the type for the player's country, as
--                               CCountryEventManager::StartSituation makes one (the simulation's
--                               situations module then runs it)
--   approach SITUATION KEY      the situation's approach changed (the approach button)
--   pin KIND KEY, track KIND KEY  a Situation Log entry pinned (to Priorities) or tracked (its map
--                               marker) or not (CTrackSituationLogEntryCommand, the pin's command)
--   relic KEY                   the relic activated (CActivateRelicCommand)
--
-- Each returns what it did, or why not. They change the world through engine.world's writers.

local world = require("engine.world")

local M = {}

M.pinned = M.pinned or {}    -- "kind:key" -> true (CCountryPinTrackingManager, for the session [I])
M.tracked = M.tracked or {}  -- "kind:key" -> true

local NONE = 4294967295

local function strip(v)
    return type(v) == "string" and (v:gsub('"', "")) or v
end

local function player()
    return require("render.windows.events_data").player()
end

local function eval()
    local ev = package.loaded["simscript.eval"]
    local sdb = package.loaded["simscript.db"]
    if ev and ev.effect and sdb and type(sdb.events) == "table" and next(sdb.events) then
        return ev
    end
    return nil
end

-- a definition, its inline scripts expanded (engine.defs, loaded with the simulation)
local function def(folder, key)
    local ok, defs = pcall(require, "engine.defs")
    local d = ok and defs.get(folder, key)
    return d and (d.block or d)
end

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function blocks(block, key)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key and e.value.text == nil then
            out[#out + 1] = e.value
        end
    end
    return out
end

local function parse(text, name)
    local tree, err = require("pdxscript").parse(text, name or "command")
    if not tree then
        error(tostring(err))
    end
    return tree
end

-- the effect `block` in the scope `kind id` (the player's country by default)
local function run_effect(block, kind, id)
    local ev = eval()
    if not ev or type(block) ~= "table" then
        return false
    end
    local ctx = ev.new_ctx(ev.S(kind or "country", id or player()), ev.NONE, {})
    ev.effect(block, ctx)
    return true
end

-- a trigger in the scope `kind id` (the simulation's evaluator); true when there is none
local function holds(block, kind, id)
    if type(block) ~= "table" then
        return true
    end
    local ev = eval()
    if not ev then
        return false
    end
    local ctx = ev.new_ctx(ev.S(kind, id), ev.NONE, {})
    local ok, r = pcall(ev.trigger, block, ctx)
    return ok and r and true or false
end

-- a resource table's cost paid from the country's stockpile (as empire_commands' pay): false, and
-- nothing paid, when the stockpile is short
local function pay(country, cost)
    local c = world.object("country", country)
    local r = world.path(c or {}, "modules", "standard_economy_module", "resources")
    if type(cost) ~= "table" or not r then
        return type(cost) ~= "table"
    end
    local want = {}
    local ev = eval()
    local ctx = ev and ev.new_ctx(ev.S("country", country), ev.NONE, {})
    for _, e in ipairs(cost) do
        -- (an amount through the evaluator: @activation_cost and the like)
        local amount = e.op and e.key and e.value.text and (tonumber(e.value.text) or (ev and ev.value(e.value, ctx)))
        if amount then
            want[e.key.text] = amount
            if (tonumber(world.field(r, e.key.text)) or 0) < want[e.key.text] then
                return false
            end
        end
    end
    for k, v in pairs(want) do
        world.set(r, k, (tonumber(world.field(r, k)) or 0) - v)
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- add_relic = KEY (CAddRelicEffect), where the simulation has none: the country's `relics` list

local function install_effects()
    local ev = package.loaded["simscript.eval"]
    if not ev or not ev.EFF or ev.EFF.add_relic then
        return
    end
    ev.EFF.add_relic = function(e, ctx)
        if ctx.this.kind ~= "country" or not e.value.text then
            return
        end
        local c = world.object("country", ctx.this.id)
        if not c then
            return
        end
        local list = world.child(c, "relics")
        local key = strip(e.value.text)
        for _, v in ipairs(list) do
            if strip(v.text) == key then
                return
            end
        end
        world.append_value(list, key, true)
    end
end

-- ---------------------------------------------------------------------------------------------

function M.effect(text)
    if not eval() then
        return "no simulation"
    end
    install_effects()
    run_effect(parse(text, "effect"))
    return "effect done"
end

-- a situation (CCountryEventManager::StartSituation): its type's stages make its durations, the
-- initial progress (at least the start value), the default approach; then its on_start
function M.start_situation(type_key)
    local d = def("common/situations", type_key)
    if not d then
        return "no situation type " .. tostring(type_key)
    end
    local pid = player()
    local ids = world.all("situation")
    local id = 0
    for _, i in ipairs(ids) do
        if i >= id then
            id = i + 1
        end
    end
    local start = tonumber(get(d, "start_value")) or 0
    local progress = math.max(start, tonumber(get(d, "initial_progress")) or start)
    local durations, flags = {}, {}
    local last = start
    for _, st in ipairs(blocks(d, "stages")) do
        for _, e in ipairs(st) do
            if e.op and e.key and e.value.text == nil then
                local e_end = tonumber(get(e.value, "end")) or last
                durations[#durations + 1] = string.format("{ start=%s end=%s }", last, e_end)
                flags[#flags + 1] = "no"
                last = e_end
            end
        end
    end
    local approach
    for _, a in ipairs(blocks(d, "approach")) do
        if get(a, "default") == "yes" then
            approach = strip(get(a, "name"))
        end
    end
    approach = approach or strip(get(blocks(d, "approach")[1], "name")) or ""
    local text = string.format([[country=%d
target={ type=country id=%d opener_id=%d }
type="%s"
progress=%s
last_month_progress=0
approach="%s"
stage_durations={ %s }
stage_flags={ %s }
stage=0]], pid, pid, NONE, type_key, progress, approach, table.concat(durations, " "), table.concat(flags, " "))
    local block = parse(text, "situation")
    world.create("situation", id, block)
    local on_start = get(d, "on_start")
    if type(on_start) == "table" then
        pcall(run_effect, on_start, "situation", id)
    end
    return string.format("situation %d %s, progress %s, approach %s", id, type_key, progress, approach)
end

-- the situation's approaches as the Situation Log lists them: { key, icon, icon_background,
-- potential, allow } (their potential and allow evaluated in the situation's scope)
function M.approaches(sid, type_key)
    local d = def("common/situations", type_key)
    local out = {}
    for _, a in ipairs(blocks(d, "approach")) do
        local key = strip(get(a, "name"))
        if key then
            out[#out + 1] = {
                key = key, icon = strip(get(a, "icon")), icon_background = strip(get(a, "icon_background")),
                potential = holds(get(a, "potential"), "situation", sid), allow = holds(get(a, "allow"), "situation", sid),
            }
        end
    end
    return out
end

-- CSetSituationApproachCommand [I: read off the approach's definition]: its potential and allow
-- hold, its cost paid; the approach set and its on_select run
function M.approach(sid, key)
    sid = tonumber(sid)
    local s = world.object("situation", sid or -1)
    if not s or tonumber(world.field(s, "country")) ~= player() then
        return "no situation " .. tostring(sid)
    end
    local d = def("common/situations", strip(world.field(s, "type")))
    for _, a in ipairs(blocks(d, "approach")) do
        if strip(get(a, "name")) == key then
            if not holds(get(a, "potential"), "situation", sid) then
                return "not potential"
            end
            if not holds(get(a, "allow"), "situation", sid) then
                return "not allowed"
            end
            if not pay(player(), get(get(a, "resources") or {}, "cost")) then
                return "cannot pay"
            end
            world.set(s, "approach", key)
            local on_select = get(a, "on_select")
            if type(on_select) == "table" then
                pcall(run_effect, on_select, "situation", sid)
            end
            return "approach " .. key
        end
    end
    return "no approach " .. tostring(key)
end

function M.toggle(set, kind, key)
    local k = tostring(kind) .. ":" .. tostring(key)
    set[k] = not set[k] or nil
    return k .. (set[k] and " on" or " off")
end

-- CActivateRelicCommand [I: the relic's definition]: owned, `possible` holds, the cost paid; then
-- its active_effect, and the country's last activated relic
function M.relic(key)
    local pid = player()
    local c = world.object("country", pid)
    local owned = false
    for _, v in ipairs(world.list(world.field(c or {}, "relics") or {})) do
        if strip(v) == key then
            owned = true
        end
    end
    if not owned then
        return "not owned " .. tostring(key)
    end
    local d = def("common/relics", key)
    if not d then
        return "no relic " .. tostring(key)
    end
    if not holds(get(d, "possible"), "country", pid) then
        return "not possible"
    end
    if not pay(pid, get(get(d, "resources") or {}, "cost")) then
        return "cannot pay"
    end
    pcall(run_effect, get(d, "active_effect"), "country", pid)
    world.set(c, "last_activated_relic", key)
    return "relic " .. key .. " activated"
end

-- the dispatcher (events_data.command's other verbs)
function M.command(verb, a, b)
    install_effects()
    if verb == "effect" then
        return M.effect(a)
    elseif verb == "start_situation" then
        return M.start_situation(a)
    elseif verb == "approach" then
        return M.approach(a, b)
    elseif verb == "pin" then
        return M.toggle(M.pinned, a, b)
    elseif verb == "track" then
        return M.toggle(M.tracked, a, b)
    elseif verb == "relic" then
        return M.relic(a)
    end
    return "no command " .. tostring(verb)
end

return M
