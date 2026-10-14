-- simscript/eval.lua : evaluates PDXScript trees (triggers, effects, script values, weights).
--
-- Script state (flags, variables, event targets, temp lists) lives here, in Lua. Engine state is
-- read through E (filled by sim/src/lua_host.rs for each call); engine effects are pushed to the
-- engine queue with E.push. Before any read of engine state, pending engine effects are flushed
-- (E.flush: the barrier for reads after writes and for last_created_*), so a read sees every
-- effect queued before it, as in the game, where effects apply at once.
--
-- Anything not implemented is recorded (kind, keyword, count, first file:line) in stats.missing
-- and evaluates to false (trigger) or does nothing (effect); documented engine effects without a
-- model are pushed as "unmodelled" engine effects and counted in stats.unmodelled.

local db = require("simscript.db")

local M = {}
local E = _G.E

local floor = math.floor

-- ---------------------------------------------------------------------------------------------
-- scopes

local scopes = {}
local NONE = { kind = "none", id = 0, key = "none" }
M.NONE = NONE
local function S(kind, id)
    if kind == nil or kind == "none" or id == nil then
        return NONE
    end
    local k = kind .. ":" .. id
    local s = scopes[k]
    if not s then
        s = { kind = kind, id = id, key = k }
        scopes[k] = s
    end
    return s
end
M.S = S

-- ---------------------------------------------------------------------------------------------
-- script state and statistics

local state = { flags = {}, vars = {}, global_flags = {}, global_targets = {}, fired_once = {} }
M.state = state

local stats = {
    script = 0, engine = 0, flushes = 0, trigger_evals = 0, effect_runs = 0,
    missing = {}, unmodelled = {},
}
M.stats = stats

local function where(ctx, e)
    return (ctx and ctx.file or "?") .. ":" .. tostring(e and e.line or "?")
end

local function miss(kind, key, ctx, e)
    local k = kind .. " " .. key
    local m = stats.missing[k]
    if not m then
        m = { kind = kind, key = key, count = 0, first = where(ctx, e) }
        stats.missing[k] = m
    end
    m.count = m.count + 1
end
M.miss = miss

function M.today()
    return floor((E.date() - 43800000) / 24)
end

local function sync()
    if E.pending() > 0 then
        E.flush()
        stats.flushes = stats.flushes + 1
    end
end
M.sync = sync

local function rand()
    return E.rand()
end
M.rand = rand

-- ---------------------------------------------------------------------------------------------
-- contexts

-- ctx: { this, root, from, fromfrom, prev, prevprev, prevprevprev, prevprevprevprev, targets,
-- lists, created, file }
function M.new_ctx(this, from, targets, file)
    return {
        this = this or NONE, root = this or NONE, from = from or NONE, fromfrom = NONE,
        prev = NONE, prevprev = NONE, prevprevprev = NONE, prevprevprevprev = NONE,
        targets = targets or {}, lists = {}, created = {}, file = file,
    }
end

local function push(ctx, sc)
    return {
        this = sc, root = ctx.root, from = ctx.from, fromfrom = ctx.fromfrom, prev = ctx.this,
        prevprev = ctx.prev, prevprevprev = ctx.prevprev, prevprevprevprev = ctx.prevprevprev,
        targets = ctx.targets, lists = ctx.lists, created = ctx.created, file = ctx.file,
    }
end
M.push = push

local function with_file(ctx, file)
    if ctx.file == file then
        return ctx
    end
    local c = push(ctx, ctx.this)
    c.prev, c.prevprev, c.file = ctx.prev, ctx.prevprev, file
    c.prevprevprev, c.prevprevprevprev = ctx.prevprevprev, ctx.prevprevprevprev
    return c
end

-- ---------------------------------------------------------------------------------------------
-- scope links

-- a country id as the save writes it: 0 is a country (the first one); 4294967295 is none
local NO_ID = 4294967295
local function country(o)
    o = tonumber(o)
    return (o and o ~= NO_ID) and S("country", o) or nil
end

local function owner_of(sc)
    sync()
    if sc.kind == "planet" then
        return country(E.get("planet", sc.id, "owner"))
    elseif sc.kind == "pop_group" then
        local p = E.get("pop_group", sc.id, "colony")
        return p and country(E.get("planet", p, "owner")) or nil
    elseif sc.kind == "leader" then
        return country(E.get("leader", sc.id, "country"))
    elseif E.owner_of then -- a starbase's, ship's, fleet's: its fleet's owner
        return country(E.owner_of(sc.kind, sc.id))
    end
    return nil
end

local CREATED_KIND = { pop_group = "pop_group", pop = "pop_group", leader = "leader" }

local LINKS = {
    this = function(cur) return cur end,
    root = function(_, ctx) return ctx.root end,
    from = function(_, ctx) return ctx.from end,
    fromfrom = function(_, ctx) return ctx.fromfrom end,
    prev = function(_, ctx) return ctx.prev end,
    prevprev = function(_, ctx) return ctx.prevprev end,
    prevprevprev = function(_, ctx) return ctx.prevprevprev or NONE end,
    prevprevprevprev = function(_, ctx) return ctx.prevprevprevprev or NONE end,
    owner = function(cur) return owner_of(cur) end,
    controller = function(cur) return owner_of(cur) end,
    capital_scope = function(cur)
        if cur.kind ~= "country" then return nil end
        sync()
        local c = E.get("country", cur.id, "capital")
        return c and S("planet", c) or nil
    end,
    planet = function(cur)
        if cur.kind == "planet" then return cur end
        if cur.kind == "pop_group" then
            sync()
            local c = E.get("pop_group", cur.id, "colony")
            return c and S("planet", c) or nil
        end
        return nil
    end,
    ruler = function(cur)
        if cur.kind ~= "country" then return nil end
        sync()
        local l = E.leaders(cur.id)[1]
        return l and S("leader", l) or nil
    end,
    -- species (scopes.log): an object's species; a country's founding species; the main species of
    -- the owner (a country's own: its founder species)
    species = function(cur)
        if not E.species_of then return nil end
        sync()
        local s = E.species_of(cur.kind, cur.id)
        return s and S("species", s) or nil
    end,
    founder_species = function(cur)
        if cur.kind ~= "country" or not E.founder_species then return nil end
        sync()
        local s = E.founder_species(cur.id)
        return s and S("species", s) or nil
    end,
}
LINKS.owner_main_species = function(cur)
    if not E.founder_species then return nil end
    local c = cur.kind == "country" and cur or owner_of(cur)
    if not c then return nil end
    sync()
    local s = E.founder_species(c.id)
    return s and S("species", s) or nil
end
LINKS.owner_species = LINKS.owner_main_species
-- solar_system: the system an object is in; leader: a planet's governor, a fleet's leader, an
-- army's general, a country's ruler
LINKS.solar_system = function(cur)
    if not E.system_of then return nil end
    sync()
    local s = E.system_of(cur.kind, cur.id)
    return s and S("system", s) or nil
end
LINKS.leader = function(cur)
    if not E.leader_of then return nil end
    sync()
    local l = E.leader_of(cur.kind, cur.id)
    return l and S("leader", l) or nil
end
-- overlord: a country's overlord (`overlord = <country>`)
LINKS.overlord = function(cur)
    if cur.kind ~= "country" or not E.overlord then return nil end
    sync()
    local o = E.overlord(cur.id)
    return o and S("country", o) or nil
end
-- federation: a country's federation
LINKS.federation = function(cur)
    if cur.kind == "federation" then return cur end
    if cur.kind ~= "country" or not E.federation_of then return nil end
    sync()
    local f = E.federation_of(cur.id)
    return f and S("federation", f) or nil
end
-- starbase: a system's starbase, a planet's (its system's), a starbase itself
LINKS.starbase = function(cur)
    if not E.starbase_of then return nil end
    sync()
    local s = E.starbase_of(cur.kind, cur.id)
    return s and S("starbase", s) or nil
end
M.LINKS = LINKS

-- resolve a scope reference (`owner`, `root.owner.capital_scope`, `event_target:x`,
-- `last_created_leader`): found (is a scope reference), scope or nil
function M.resolve(text, ctx, e)
    local cur = ctx.this
    local first = true
    for part in text:gmatch("[^%.]+") do
        local p = part:gsub("%?$", "")
        local lp = p:lower()
        local nxt
        local link = LINKS[lp]
        if link then
            nxt = link(cur, ctx)
        elseif lp:sub(1, 13) == "event_target:" or lp:sub(1, 6) == "scope:" then
            local name = p:match(":(.*)$")
            nxt = ctx.targets[name] or state.global_targets[name]
        elseif lp:sub(1, 13) == "last_created_" then
            local k = CREATED_KIND[lp:sub(14)]
            local h = ctx.created[lp:sub(14)]
            if not k then
                miss("scope link", lp, ctx, e)
                return true, nil
            end
            if h then
                sync() -- the barrier: the created object exists only after the flush
                local id = E.resolve(h)
                nxt = id and S(k, id) or nil
            end
        elseif first then
            return false
        else
            miss("scope link", lp, ctx, e)
            return true, nil
        end
        first = false
        if nxt == nil then
            return true, nil
        end
        cur = nxt
    end
    if first then
        return false
    end
    return true, cur
end

-- ---------------------------------------------------------------------------------------------
-- values

local VALUE_OPS = {
    add = true, subtract = true, factor = true, multiply = true, mult = true, divide = true,
    modulo = true, base = true, value = true, weight = true, min = true, max = true,
}

local function var_raw(name, ctx)
    local fv = db.filevars(ctx.file)
    local v = fv and fv[name]
    if v == nil then
        v = db.globalvars[name]
    end
    return v
end

local value_text

-- inline math: @[ expr ] / @\[ expr ]
local function mathexpr(text, ctx, e)
    local s = text:gsub("^@\\?%[", ""):gsub("%]$", "")
    local pos = 1
    local function skip()
        pos = s:find("[^%s]", pos) or (#s + 1)
    end
    local expr
    local function atom()
        skip()
        local c = s:sub(pos, pos)
        if c == "(" then
            pos = pos + 1
            local v = expr()
            skip()
            pos = pos + 1 -- ')'
            return v
        elseif c == "-" then
            pos = pos + 1
            return -atom()
        elseif c == "|" then
            pos = pos + 1
            local v = expr()
            skip()
            pos = pos + 1
            return math.abs(v)
        end
        local num = s:match("^%d+%.?%d*", pos)
        if num then
            pos = pos + #num
            return tonumber(num)
        end
        local id = s:match("^@?[%w_]+", pos)
        if id then
            pos = pos + #id
            return value_text("@" .. id:gsub("^@", ""), ctx, e)
        end
        error("bad inline math: " .. text)
    end
    local function term()
        local v = atom()
        while true do
            skip()
            local c = s:sub(pos, pos)
            if c == "*" then pos = pos + 1; v = v * atom()
            elseif c == "/" then pos = pos + 1; local d = atom(); v = d ~= 0 and v / d or 0
            elseif c == "%" then pos = pos + 1; local d = atom(); v = d ~= 0 and v % d or 0
            else return v end
        end
    end
    expr = function()
        local v = term()
        while true do
            skip()
            local c = s:sub(pos, pos)
            if c == "+" then pos = pos + 1; v = v + term()
            elseif c == "-" then pos = pos + 1; v = v - term()
            else return v end
        end
    end
    local ok, v = pcall(expr)
    if ok and type(v) == "number" then
        return v
    end
    miss("value", "inline math", ctx, e)
    return 0
end

-- Where the script state lives (M.store): by default in this module's own tables; a world loaded
-- from a save installs a store over the save's objects (engine/scriptstate.lua), so the flags and
-- variables are the save's, and saved with it.
M.store = {
    getvar = function(sc, name)
        local t = state.vars[sc.key]
        return t and t[name]
    end,
    setvar = function(sc, name, v)
        local t = state.vars[sc.key]
        if not t then
            t = {}
            state.vars[sc.key] = t
        end
        t[name] = v
    end,
    -- has_flag(sc, name) / set_flag(sc, name, days | nil for ever) / remove_flag(sc, name);
    -- sc == nil: the global flags
    has_flag = function(sc, name)
        local t = sc and state.flags[sc.key] or (sc == nil and state.global_flags)
        local v = t and t[name]
        if v == nil then return false end
        if v == true then return true end
        return v > M.today()
    end,
    set_flag = function(sc, name, days)
        local t
        if sc == nil then
            t = state.global_flags
        else
            t = state.flags[sc.key]
            if not t then
                t = {}
                state.flags[sc.key] = t
            end
        end
        t[name] = days and (M.today() + days) or true
    end,
    remove_flag = function(sc, name)
        local t = sc and state.flags[sc.key] or (sc == nil and state.global_flags)
        if t then t[name] = nil end
    end,
}
local function getvar(sc, name) return M.store.getvar(sc, name) end
local function setvar(sc, name, v) return M.store.setvar(sc, name, v) end
M.getvar, M.setvar = getvar, setvar

function value_text(t, ctx, e)
    local n = tonumber(t)
    if n then
        return n
    end
    if t == "yes" then return 1 elseif t == "no" then return 0 end
    if t:sub(1, 1) == "@" then
        if t:sub(2, 2) == "[" or t:sub(2, 3) == "\\[" then
            return mathexpr(t, ctx, e)
        end
        local raw = var_raw(t:sub(2), ctx)
        if raw then
            return value_text(raw, ctx, e)
        end
        miss("value", "@" .. t:sub(2), ctx, e)
        return 0
    end
    if t:sub(1, 6) == "value:" then
        return M.script_value(t:sub(7), ctx, e)
    end
    if t:sub(1, 8) == "trigger:" then
        miss("value", t, ctx, e)
        return 0
    end
    if t:sub(1, 9) == "modifier:" then
        sync()
        return E.modifier(ctx.this.kind, ctx.this.id, t:sub(10))
    end
    -- a variable, possibly behind a scope chain (`owner.my_var`)
    local sc, name = ctx.this, t
    local chain, last = t:match("^(.*)%.([^%.]+)$")
    if chain then
        local found, s2 = M.resolve(chain, ctx, e)
        if found then
            if not s2 then return 0 end
            sc, name = s2, last
        end
    end
    local v = getvar(sc, name)
    if v ~= nil then
        return v
    end
    local sv = db.script_values[t]
    if sv then
        return M.script_value(t, ctx, e)
    end
    return 0 -- an unset variable is 0 in the game
end
M.value_text = value_text

function M.value(v, ctx, e)
    if v == nil then
        return 0
    end
    if v.text then
        return value_text(v.text, ctx, e or v)
    end
    return M.value_block(v, ctx)
end

local trigger, effect -- forward

local function apply_ops(b, ctx, acc, only_ops)
    local taken = false
    for _, e in ipairs(b) do
        if e.op and e.key and not (only_ops and not VALUE_OPS[e.key.text:lower()]) then
            local k = e.key.text:lower()
            if k == "base" or k == "value" or k == "set" then
                acc = M.value(e.value, ctx, e)
            elseif k == "add" then acc = acc + M.value(e.value, ctx, e)
            elseif k == "subtract" then acc = acc - M.value(e.value, ctx, e)
            elseif k == "mult" or k == "multiply" or k == "factor" then acc = acc * M.value(e.value, ctx, e)
            elseif k == "divide" then local d = M.value(e.value, ctx, e); if d ~= 0 then acc = acc / d end
            elseif k == "modulo" then local d = M.value(e.value, ctx, e); if d ~= 0 then acc = acc % d end
            elseif k == "min" then acc = math.max(acc, M.value(e.value, ctx, e))
            elseif k == "max" then acc = math.min(acc, M.value(e.value, ctx, e))
            elseif k == "abs" then acc = math.abs(acc)
            elseif k == "round" then acc = floor(acc + 0.5)
            elseif k == "floor" then acc = floor(acc)
            elseif k == "ceiling" then acc = math.ceil(acc)
            elseif k == "modifier" and e.value.text == nil then
                if trigger(e.value, ctx, VALUE_OPS) then
                    acc = apply_ops(e.value, ctx, acc, true)
                end
            elseif k == "if" or k == "else_if" or k == "else" then
                if k == "if" then taken = false end
                if not taken and e.value.text == nil then
                    local lim
                    for _, x in ipairs(e.value) do
                        if x.op and x.key.text:lower() == "limit" then lim = x.value end
                    end
                    if k == "else" or not lim or trigger(lim, ctx) then
                        taken = true
                        acc = apply_ops(e.value, ctx, acc)
                    end
                end
            elseif k == "limit" or k == "weight" or k == "desc" or k == "display_name" then
                -- handled by the caller or not a value operation
            else
                -- `count_owned_pop_amount = { limit = { ... } }`: the iterator's count
                local n = e.value.text == nil and M.count_value and M.count_value(k, e.value, ctx)
                if n then
                    acc = n
                else
                    local found, sc = M.resolve(e.key.text, ctx, e)
                    if found and e.value.text == nil then
                        if sc then acc = apply_ops(e.value, push(ctx, sc), acc) end
                    else
                        miss("value op", k, ctx, e)
                    end
                end
            end
        end
    end
    return acc
end

function M.value_block(b, ctx)
    return apply_ops(b, ctx, 0)
end

function M.script_value(spec, ctx, e)
    local parts = {}
    for p in (spec .. "|"):gmatch("([^|]*)|") do
        parts[#parts + 1] = p
    end
    local name = parts[1]
    local def = db.script_values[name]
    if not def then
        miss("value", "value:" .. name, ctx, e)
        return 0
    end
    local args = {}
    for i = 2, #parts - 1, 2 do
        if parts[i] ~= "" then
            args[#args + 1] = { parts[i], parts[i + 1] or "" }
        end
    end
    local block, msg = db.instance("value", def, name, args)
    if not block then
        miss("value", "instantiate " .. name, ctx, e)
        return 0
    end
    return apply_ops(block, with_file(ctx, def.file), 0)
end

-- weights: ai_chance, mean_time_to_happen, random_list entries, weight blocks
function M.weight(b, ctx, base)
    local acc = base or 1
    for _, e in ipairs(b) do
        if e.op and e.key then
            local k = e.key.text:lower()
            if k == "base" or k == "factor" or k == "weight" or k == "days" then
                acc = M.value(e.value, ctx, e)
            elseif k == "months" then acc = M.value(e.value, ctx, e) * 30
            elseif k == "years" then acc = M.value(e.value, ctx, e) * 360
            elseif k == "add" then acc = acc + M.value(e.value, ctx, e)
            elseif k == "multiply" or k == "mult" then acc = acc * M.value(e.value, ctx, e)
            elseif k == "modifier" and e.value.text == nil then
                if trigger(e.value, ctx, VALUE_OPS) then
                    for _, x in ipairs(e.value) do
                        if x.op then
                            local xk = x.key.text:lower()
                            if xk == "factor" or xk == "multiply" or xk == "mult" then acc = acc * M.value(x.value, ctx, x)
                            elseif xk == "add" then acc = acc + M.value(x.value, ctx, x)
                            elseif xk == "subtract" then acc = acc - M.value(x.value, ctx, x)
                            end
                        end
                    end
                end
            elseif k == "complex_trigger_modifier" or k == "opinion_modifier" or k == "modifier" then
                miss("weight op", k, ctx, e)
            end
        end
    end
    return acc
end

local function compare(a, op, b)
    if op == "=" or op == "==" then return a == b
    elseif op == ">" then return a > b
    elseif op == "<" then return a < b
    elseif op == ">=" then return a >= b
    elseif op == "<=" then return a <= b
    elseif op == "!=" then return a ~= b
    end
    return false
end
M.compare = compare

-- ---------------------------------------------------------------------------------------------
-- flags

local function flag_name(text, ctx, e)
    local base, ref = text:match("^(.-)@(.+)$")
    if base and not ref:find("^%[") then
        local found, sc = M.resolve(ref, ctx, e)
        if found then
            return base .. "@" .. (sc and sc.id or "none")
        end
    end
    return text
end


-- ---------------------------------------------------------------------------------------------
-- lists (iterators)

local function map_scopes(kind, ids)
    local out = {}
    for i, id in ipairs(ids) do
        out[i] = S(kind, id)
    end
    return out
end

local function pop_groups_of(sc)
    sync()
    local out = {}
    local cols
    if sc.kind == "planet" then
        cols = { sc.id }
    elseif sc.kind == "country" then
        cols = E.colonies(sc.id)
    else
        return out
    end
    for _, c in ipairs(cols) do
        for _, p in ipairs(E.pop_groups(c)) do
            out[#out + 1] = S("pop_group", p)
        end
    end
    return out
end

local LISTS = {
    owned_planet = function(sc) if sc.kind ~= "country" then return {} end sync() return map_scopes("planet", E.colonies(sc.id)) end,
    country = function() sync() return map_scopes("country", E.countries()) end,
    owned_pop_group = pop_groups_of,
    pop_group = pop_groups_of,
    owned_leader = function(sc) if sc.kind ~= "country" then return {} end sync() return map_scopes("leader", E.leaders(sc.id)) end,
}
LISTS.owned_colony = LISTS.owned_planet
LISTS.playable_country = LISTS.country
LISTS.leader = LISTS.owned_leader
LISTS.neighbor_country = function(sc)
    if sc.kind ~= "country" or not E.neighbors then return {} end
    sync()
    return map_scopes("country", E.neighbors(sc.id))
end
LISTS.owned_species = function(sc)
    if sc.kind ~= "country" or not E.owned_species then return {} end
    sync()
    return map_scopes("species", E.owned_species(sc.id))
end
LISTS.owned_megastructure = function(sc)
    if sc.kind ~= "country" or not E.megastructures then return {} end
    sync()
    return map_scopes("megastructure", E.megastructures(sc.id))
end
-- relation: the countries a country has a relation with (CRelationListBuilder)
LISTS.relation = function(sc)
    if sc.kind ~= "country" or not E.relations then return {} end
    sync()
    return map_scopes("country", E.relations(sc.id))
end
-- situation: a country's situations
LISTS.situation = function(sc)
    if sc.kind ~= "country" or not E.situations then return {} end
    sync()
    return map_scopes("situation", E.situations(sc.id))
end
-- member: a federation's members (a country's: its federation's)
LISTS.member = function(sc)
    if not E.federation_members then return {} end
    sync()
    local f = sc.kind == "federation" and sc.id or (sc.kind == "country" and E.federation_of(sc.id))
    return f and map_scopes("country", E.federation_members(f)) or {}
end
-- subject: a country's subjects
LISTS.subject = function(sc)
    if sc.kind ~= "country" or not E.subjects then return {} end
    sync()
    return map_scopes("country", E.subjects(sc.id))
end
-- system_within_border / planet_within_border: the systems a country owns, and their planets
LISTS.system_within_border = function(sc)
    if sc.kind ~= "country" or not E.systems_within_border then return {} end
    sync()
    return map_scopes("system", E.systems_within_border(sc.id))
end
-- owned_starbase / owned_nonprimary_starbase: the starbases a country owns (not the systems' primary
-- ones)
LISTS.owned_starbase = function(sc)
    if sc.kind ~= "country" or not E.owned_starbases then return {} end
    sync()
    return map_scopes("starbase", E.owned_starbases(sc.id, false))
end
LISTS.owned_nonprimary_starbase = function(sc)
    if sc.kind ~= "country" or not E.owned_starbases then return {} end
    sync()
    return map_scopes("starbase", E.owned_starbases(sc.id, true))
end
LISTS.system_planet = function(sc)
    if sc.kind ~= "system" or not E.system_planets then return {} end
    sync()
    return map_scopes("planet", E.system_planets(sc.id))
end
LISTS.planet_within_border = function(sc)
    if sc.kind ~= "country" or not E.systems_within_border then return {} end
    sync()
    local out = {}
    for _, sid in ipairs(E.systems_within_border(sc.id)) do
        for _, pid in ipairs(E.system_planets(sid)) do
            out[#out + 1] = S("planet", pid)
        end
    end
    return out
end
M.LISTS = LISTS

-- iterators that count amounts, not items: count_owned_pop_amount sums the pop groups' sizes
local AMOUNTS = {
    owned_pop_amount = {
        list = "owned_pop_group",
        weight = function(s)
            sync()
            return tonumber(E.get("pop_group", s.id, "size")) or 0
        end,
    },
}
M.AMOUNTS = AMOUNTS

local function list_of(name, block, ctx, e)
    if AMOUNTS[name] then
        name = AMOUNTS[name].list
    end
    if name == "in_list" then
        local lname
        for _, x in ipairs(block) do
            if x.op and x.key.text:lower() == "list" then lname = x.value.text end
        end
        return ctx.lists[lname or ""] or {}
    end
    local f = LISTS[name]
    if not f then
        return nil
    end
    return f(ctx.this, ctx)
end

-- ---------------------------------------------------------------------------------------------
-- triggers

local TRIG = {}
M.TRIG = TRIG
local ITER_PARAMS = { limit = true, count = true, list = true, order_by = true, position = true, max = true,
    min = true, check_range_bounds = true, weight = true, text = true, fail_text = true }

local function scripted_call(def, name, e, kind)
    if e.value.text then
        return db.instance(kind, def, name, {})
    end
    local args = {}
    for _, x in ipairs(e.value) do
        if x.op and x.key then
            args[#args + 1] = { x.key.text, x.value.text or db.pdxscript.write(x.value) }
        end
    end
    return db.instance(kind, def, name, args)
end

-- one statement
local function trigger1(e, ctx)
    stats.trigger_evals = stats.trigger_evals + 1
    local key = e.key.text
    local lk = key:lower()
    local h = TRIG[lk]
    if h then
        return h(e, ctx, lk)
    end
    local found, sc = M.resolve(key, ctx, e)
    if found then
        if e.value.text then -- `owner = root`: the same scope
            local f2, other = M.resolve(e.value.text, ctx, e)
            return f2 and sc ~= nil and sc == other
        end
        if not sc then return false end
        return trigger(e.value, push(ctx, sc))
    end
    local it, lname = lk:match("^(any)_(.+)$")
    if not it then it, lname = lk:match("^(count)_(.+)$") end
    if it and e.value.text == nil then
        local list = list_of(lname, e.value, ctx, e)
        if list then
            if it == "any" then
                for _, s2 in ipairs(list) do
                    if trigger(e.value, push(ctx, s2), ITER_PARAMS) then return true end
                end
                return false
            end
            local op, want = ">=", 1
            for _, x in ipairs(e.value) do
                if x.op and x.key.text:lower() == "count" then
                    op = x.op; want = x.value.text == "all" and -1 or M.value(x.value, ctx, x)
                end
            end
            local n, total = M.count_items(lname, list, e.value, ctx)
            if want == -1 then return n == total end
            return compare(n, op, want)
        end
        miss("iterator", lk, ctx, e)
        return false
    end
    local def = db.scripted_triggers[key]
    if def then
        -- `pop_amount > 10`: a scripted trigger whose body is one count iterator, compared as a
        -- number (the comparison takes the iterator's count)
        local tv = e.value.text
        if tv and tv ~= "yes" and tv ~= "no" then
            local body = scripted_call(def, key, { value = { text = "yes" } }, "trigger")
            local only
            for _, x in ipairs(body or {}) do
                if x.op then
                    if only then only = false break end
                    only = x
                end
            end
            local n = only and M.count_value(only.key.text:lower(), only.value, with_file(ctx, def.file))
            if n then
                return compare(n, e.op, M.value(e.value, ctx, e))
            end
        end
        local body = scripted_call(def, key, e, "trigger")
        if not body then
            miss("trigger", "instantiate " .. key, ctx, e)
            return false
        end
        local r = trigger(body, with_file(ctx, def.file))
        if e.value.text == "no" then r = not r end
        return r
    end
    local fk = lk:match("^has_(.+)_flag$")
    if fk == "policy" then fk = nil end   -- has_policy_flag: the country's policies, not a script flag
    if fk and e.value.text then
        if fk == "global" then
            return M.store.has_flag(nil, flag_name(e.value.text, ctx, e))
        end
        return M.store.has_flag(ctx.this, flag_name(e.value.text, ctx, e))
    end
    if M.property(lk) and e.value.text then
        return M.property(lk)(e, ctx, lk)
    end
    if lk:sub(1, 1) == "@" or lk:find("^%$") then
        miss("trigger", "unresolved " .. key:sub(1, 1), ctx, e)
        return false
    end
    miss("trigger", lk, ctx, e)
    return false
end

-- M.count_items(lname, list, block, ctx) -> n, total: the items of an iterator's list for which
-- its limit and its triggers hold (weighted by the amount for the *_amount iterators), and the
-- whole list's weight
function M.count_items(lname, list, block, ctx)
    local amount = AMOUNTS[lname]
    local limit
    for _, x in ipairs(block) do
        if x.op and x.key.text:lower() == "limit" then limit = x.value end
    end
    local n, total = 0, 0
    for _, s2 in ipairs(list) do
        local w = amount and amount.weight(s2) or 1
        total = total + w
        local c2 = push(ctx, s2)
        if (not limit or trigger(limit, c2)) and trigger(block, c2, ITER_PARAMS) then n = n + w end
    end
    return n, total
end

-- M.count_value(key, block, ctx) -> the number a `count_<list> = { limit ... }` stands for, or nil
-- when key is not such an iterator
function M.count_value(key, block, ctx)
    local lname = key:match("^count_(.+)$")
    if not lname or type(block) ~= "table" or block.text then
        return nil
    end
    local list = list_of(lname, block, ctx, nil)
    if not list then
        return nil
    end
    return (M.count_items(lname, list, block, ctx))
end

-- a block: AND of its statements (keys in skip are parameters, not triggers)
trigger = function(b, ctx, skip)
    local taken = false
    for _, e in ipairs(b) do
        if e.op and e.key then
            local lk = e.key.text:lower()
            if not (skip and skip[lk]) then
                if lk == "if" or lk == "else_if" or lk == "else" then
                    if lk == "if" then taken = false end
                    if not taken and e.value.text == nil then
                        local lim
                        for _, x in ipairs(e.value) do
                            if x.op and x.key.text:lower() == "limit" then lim = x.value end
                        end
                        if lk == "else" or not lim or trigger(lim, ctx) then
                            taken = true
                            if not trigger(e.value, ctx, { limit = true }) then return false end
                        end
                    end
                elseif not trigger1(e, ctx) then
                    return false
                end
            end
        end
    end
    return true
end
M.trigger = trigger
M.trigger1 = trigger1

local function yes(e) return e.value.text ~= "no" end

-- an `if = { limit = { } ... }` with the `else_if` / `else` statements after it is one trigger of
-- its block, in any block (OR, NOT, calc_true_if as well as AND): the game's reader chains them onto
-- the if (CTriggerCollectionBase::ReadMember -> CIfTrigger::AddElse 0x1993910), and
-- CIfTrigger::ActualEvaluate (0x1993380) is the body of the first whose limit holds, true when none
-- does. if_chain(b, i, ctx) -> its result, and the index of the statement after the chain
local LIMIT_ONLY = { limit = true }
local function if_chain(b, i, ctx)
    local result, taken = true, false
    while true do
        local e = b[i]
        local lk = e.key.text:lower()
        if not taken and e.value.text == nil then
            local lim
            for _, x in ipairs(e.value) do
                if x.op and x.key.text:lower() == "limit" then lim = x.value end
            end
            if lk == "else" or not lim or trigger(lim, ctx) then
                taken = true
                result = trigger(e.value, ctx, LIMIT_ONLY)
            end
        end
        local j = i + 1
        while b[j] and not (b[j].op and b[j].key) do j = j + 1 end
        local nk = b[j] and b[j].key.text:lower()
        if lk == "else" or (nk ~= "else_if" and nk ~= "else") then
            return result, j
        end
        i = j
    end
end
M.if_chain = if_chain

-- the triggers of a block that hold (an if chain counted as one; keys in skip are parameters):
-- their number, stopping at the first when first_only
local function holding(b, ctx, first_only, skip)
    local n, i = 0, 1
    while b[i] do
        local x = b[i]
        local r = false
        if x.op and x.key then
            local lk = x.key.text:lower()
            if lk == "if" then
                r, i = if_chain(b, i, ctx)
            else
                -- (an else_if / else not after an if: the game's reader rejects it)
                r = not (skip and skip[lk]) and lk ~= "else_if" and lk ~= "else" and trigger1(x, ctx)
                i = i + 1
            end
        else
            i = i + 1
        end
        if r then
            n = n + 1
            if first_only then return n end
        end
    end
    return n
end

TRIG["and"] = function(e, ctx) return trigger(e.value, ctx) end
TRIG["or"] = function(e, ctx) return holding(e.value, ctx, true) > 0 end
TRIG["not"] = function(e, ctx) -- NOT = { a b } is true when none holds
    return holding(e.value, ctx, true) == 0
end
TRIG["nor"] = TRIG["not"]
TRIG["nand"] = function(e, ctx) return not trigger(e.value, ctx) end
TRIG["hidden_trigger"] = TRIG["and"]
TRIG["custom_tooltip"] = function(e, ctx)
    if e.value.text then return true end
    return trigger(e.value, ctx, { text = true, fail_text = true, success_text = true })
end
TRIG["custom_tooltip_fail"] = TRIG["custom_tooltip"]
local AMOUNT = { amount = true }
TRIG["calc_true_if"] = function(e, ctx)
    local amount = 1
    for _, x in ipairs(e.value) do
        if x.op and x.key.text:lower() == "amount" then amount = M.value(x.value, ctx, x) end
    end
    return holding(e.value, ctx, false, AMOUNT) >= amount
end
TRIG["always"] = function(e) return yes(e) end
TRIG["exists"] = function(e, ctx)
    local found, sc = M.resolve(e.value.text or "", ctx, e)
    local r = found and sc ~= nil and sc ~= NONE
    if not found then miss("scope link", "exists " .. tostring(e.value.text), ctx, e) end
    return r
end
TRIG["is_same_value"] = function(e, ctx)
    local f, sc = M.resolve(e.value.text or "", ctx, e)
    return f and sc == ctx.this
end
TRIG["is_same_empire"] = TRIG["is_same_value"]
TRIG["has_global_flag"] = function(e, ctx) return M.store.has_flag(nil, flag_name(e.value.text, ctx, e)) end
TRIG["is_variable_set"] = function(e, ctx)
    local name = e.value.text or ""
    local found, sc = false, ctx.this
    local chain, last = name:match("^(.*)%.([^%.]+)$")
    if chain then
        found, sc = M.resolve(chain, ctx, e)
        if found then name = last else sc = ctx.this end
    end
    return sc ~= nil and getvar(sc, name) ~= nil
end
TRIG["check_variable"] = function(e, ctx)
    local which, op, val
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk == "which" then which = x.value.text
            elseif xk == "value" then op = x.op; val = M.value(x.value, ctx, x) end
        end
    end
    if not which then return false end
    return compare(value_text(which, ctx, e), op or "=", val or 0)
end
TRIG["years_passed"] = function(e, ctx)
    return compare(floor(M.today() / 360) - 2200, e.op, M.value(e.value, ctx, e))
end
TRIG["has_modifier"] = function(e, ctx)
    sync()
    return E.has_modifier(ctx.this.kind, ctx.this.id, e.value.text or "")
end
TRIG["has_technology"] = function(e, ctx)
    local c = ctx.this.kind == "country" and ctx.this or owner_of(ctx.this)
    if not c then return false end
    sync()
    return E.has("country", c.id, "tech", e.value.text or "")
end
TRIG["has_resource"] = function(e, ctx)
    local res, op, amount = nil, ">=", 0
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk == "type" then res = x.value.text
            elseif xk == "amount" then op = x.op; amount = M.value(x.value, ctx, x) end
        end
    end
    local c = ctx.this.kind == "country" and ctx.this or owner_of(ctx.this)
    if not (c and res) then return false end
    sync()
    local have = E.resource(c.id, res)
    if have == nil then miss("trigger", "has_resource " .. res, ctx, e); return false end
    return compare(have, op, amount)
end
TRIG["resource_stockpile_compare"] = function(e, ctx)
    local res, op, amount = nil, ">=", 0
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk == "resource" then res = x.value.text
            elseif xk == "value" then op = x.op; amount = M.value(x.value, ctx, x) end
        end
    end
    local c = ctx.this.kind == "country" and ctx.this or owner_of(ctx.this)
    if not (c and res) then return false end
    sync()
    local have = E.resource(c.id, res)
    if have == nil then return false end
    return compare(have, op, amount)
end
-- has_dlc: the save's DLCs (E.has_dlc reads its required_dlcs; yes without a world)
TRIG["has_dlc"] = function(e)
    if E.has_dlc and e.value.text then return E.has_dlc(e.value.text) end
    return true
end
-- the tutorial is off; the mid and end game start 100 and 200 years in (the default game rules)
TRIG["is_tutorial_level"] = function(e, ctx) return compare(0, e.op, M.value(e.value, ctx, e)) end
TRIG["mid_game_years_passed"] = function(e, ctx)
    return compare(floor(M.today() / 360) - 2300, e.op, M.value(e.value, ctx, e))
end
TRIG["end_game_years_passed"] = function(e, ctx)
    return compare(floor(M.today() / 360) - 2400, e.op, M.value(e.value, ctx, e))
end
TRIG["host_has_dlc"] = TRIG["has_dlc"]
TRIG["is_multiplayer"] = function(e) return not yes(e) end
TRIG["is_ironman"] = function(e) return not yes(e) end

-- uses_ship_category = <category>: the country's graphical culture's ship kinds
TRIG["uses_ship_category"] = function(e, ctx)
    if not E.uses_ship_category or ctx.this == NONE or ctx.this.kind ~= "country" or not e.value.text then return false end
    sync()
    return E.uses_ship_category(ctx.this.id, e.value.text) and true or false
end
-- capital_tier <op> n: the highest capital tier of the planet's colony's buildings
TRIG["capital_tier"] = function(e, ctx)
    if not E.capital_tier or ctx.this == NONE then return false end
    local planet = ctx.this.kind == "planet" and ctx.this.id
    if not planet then return false end
    sync()
    return compare(E.capital_tier(planet), e.op, M.value(e.value, ctx, e))
end
-- has_deficit = <resource>: a country out of the resource with a negative balance
TRIG["has_deficit"] = function(e, ctx)
    if not E.has_deficit or ctx.this == NONE or not e.value.text then return false end
    sync()
    return E.has_deficit(ctx.this.kind, ctx.this.id, e.value.text) and true or false
end
-- fleet_power > N: the scope's fleet power (a fleet's military power; a country's fleets')
TRIG["fleet_power"] = function(e, ctx)
    if not E.fleet_power or ctx.this == NONE then return false end
    sync()
    return compare(E.fleet_power(ctx.this.kind, ctx.this.id) or 0, e.op, M.value(e.value, ctx, e))
end
-- check_modifier_value = { modifier = x value > y }: the scope's modifier node value
TRIG["check_modifier_value"] = function(e, ctx)
    if e.value.text or ctx.this == NONE then return false end
    local name, op, want
    for _, x in ipairs(e.value) do
        local xk = x.op and x.key.text:lower()
        if xk == "modifier" then name = x.value.text
        elseif xk == "value" then op = x.op; want = M.value(x.value, ctx, x) end
    end
    if not name or not want then return false end
    sync()
    return compare(E.modifier(ctx.this.kind, ctx.this.id, name) or 0, op, want)
end
-- the species of this scope and of the target scope `<trigger> = <target>` (nil when either has none)
local function species_pair(e, ctx)
    if not E.species_of or not e.value.text then return nil end
    local found, other = M.resolve(e.value.text, ctx, e)
    if not found or not other or other == NONE or ctx.this == NONE then return nil end
    sync()
    local a = E.species_of(ctx.this.kind, ctx.this.id)
    local b = E.species_of(other.kind, other.id)
    if a == nil or b == nil then return nil end
    return a, b
end
-- is_same_species = <target>: both scopes' species are the same
TRIG["is_same_species"] = function(e, ctx)
    local a, b = species_pair(e, ctx)
    return a ~= nil and a == b
end
-- is_same_species_class = <target>: both species have the same class
TRIG["is_same_species_class"] = function(e, ctx)
    local a, b = species_pair(e, ctx)
    if a == nil or not E.species_field then return false end
    local ca = E.species_field(a, "class")
    return ca ~= nil and ca == E.species_field(b, "class")
end
-- is_subspecies = <target>: a different species of the same line (`base_ref`)
TRIG["is_subspecies"] = function(e, ctx)
    local a, b = species_pair(e, ctx)
    if a == nil or a == b or not E.base_species then return false end
    return E.base_species(a) == E.base_species(b)
end
-- is_in_federation_with = <country>: both in the same federation
TRIG["is_in_federation_with"] = function(e, ctx)
    if not E.federation_of or not e.value.text or ctx.this == NONE or ctx.this.kind ~= "country" then return false end
    local found, other = M.resolve(e.value.text, ctx, e)
    if not found or not other or other == NONE or other.kind ~= "country" then return false end
    sync()
    local f = E.federation_of(ctx.this.id)
    return f ~= nil and f == E.federation_of(other.id)
end
-- opinion = { who = <country> value > x }: the AI's opinion of who (engine.ai.opinion)
TRIG["opinion"] = function(e, ctx)
    if not E.opinion_trigger then return false end
    sync()
    return E.opinion_trigger(e, ctx)
end
-- has_unlocked_all_traditions = yes/no (engine.traditions)
TRIG["has_unlocked_all_traditions"] = function(e, ctx)
    if not E.unlocked_all_traditions or ctx.this == NONE or ctx.this.kind ~= "country" then return false end
    sync()
    return (E.unlocked_all_traditions(ctx.this.id) and true or false) == (e.value.text ~= "no")
end
-- has_citizenship_type = { country = <who> type = <type> } and has_population_control = { country
-- = <who> type = bool/<type> }: the country's species rights for the scope's species (the scope's
-- owner when no country is given)
local function species_right_trigger(key, none)
    return function(e, ctx)
        if not E.species_right or e.value.text ~= nil or ctx.this == NONE then return false end
        local who, want
        for _, x in ipairs(e.value) do
            local xk = x.op and x.key.text:lower()
            if xk == "country" and x.value.text then
                local found, sc = M.resolve(x.value.text, ctx, x)
                who = found and sc or nil
            elseif xk == "type" then
                want = x.value.text
            end
        end
        who = who or (ctx.this.kind == "country" and ctx.this) or owner_of(ctx.this)
        if not who or who.kind ~= "country" then return false end
        sync()
        local sid = E.species_of(ctx.this.kind, ctx.this.id)
        local have = sid and E.species_right(who.id, sid, key)
        if want == "yes" or want == "no" then
            return ((have ~= nil and have ~= none) and "yes" or "no") == want
        end
        return have ~= nil and have == want
    end
end
TRIG["has_citizenship_type"] = species_right_trigger("citizenship", nil)
TRIG["has_population_control"] = species_right_trigger("population_control", "population_control_no")
-- has_slavery_type = { country = <who> type = <slavery type> } (CHasSpeciesRightsTrigger<SHasSlaveryType>)
TRIG["has_slavery_type"] = species_right_trigger("slavery", nil)

-- the country `<trigger> = <target>` names (nil when it does not name one)
local function target_country(e, ctx)
    if not e.value.text then return nil end
    local found, sc = M.resolve(e.value.text, ctx, e)
    return (found and sc and sc.kind == "country") and sc or nil
end
-- `<trigger> <op> <value>` against a number, or false when there is none
local function compare_num(v, e, ctx)
    if v == nil then return false end
    return compare(v, e.op, M.value(e.value, ctx, e))
end
local function yes_no(e) return e.value.text == "yes" or e.value.text == "no" end

-- relation flags: `<trigger> = <country>` is the scope country's relation towards the country
-- (CCountryRelationsManager::GetRelation, its flags written `<name> = yes` by
-- CRelation::WriteMembers 0x669d30): is_under_societal_enlightenment
-- (CIsUnderSocietalEnlightenmentTrigger 0x1a13120, bit 23), is_under_open_technological_enlightenment
-- (0x1a13440, bit 24), is_under_stratified_technological_enlightenment (0x1a13760, bit 25),
-- has_pre_ftl_trade (CHasPreFtlTradeTrigger 0x1a13a80, bit 26)
for _, k in ipairs({ "is_under_societal_enlightenment", "is_under_open_technological_enlightenment",
    "is_under_stratified_technological_enlightenment", "has_pre_ftl_trade" }) do
    TRIG[k] = function(e, ctx)
        local other = ctx.this.kind == "country" and E.relation_flag and target_country(e, ctx)
        if not other then return false end
        sync()
        return E.relation_flag(ctx.this.id, other.id, k)
    end
end
-- has_waystation_pact = <country> (CHasWaystationPactTrigger 0x19a2740): the relation's pact, or a
-- federation's (E.has_waystation_pact)
TRIG["has_waystation_pact"] = function(e, ctx)
    local other = ctx.this.kind == "country" and E.has_waystation_pact and target_country(e, ctx)
    if not other then return false end
    sync()
    return E.has_waystation_pact(ctx.this.id, other.id)
end
-- has_communications = <country> (CHasCommunicationsTrigger 0x198d8c0: bit 3 of the relation, false
-- towards itself)
TRIG["has_communications"] = function(e, ctx)
    local other = ctx.this.kind == "country" and E.relation_flag and target_country(e, ctx)
    if not other or other == ctx.this then return false end
    sync()
    return E.relation_flag(ctx.this.id, other.id, "communications")
end
-- is_federation_leader = yes/no (CIsFederationLeaderTrigger 0x1971120): the country's federation's
-- `leader` (false without a federation)
TRIG["is_federation_leader"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.federation_leader then return false end
    sync()
    local leader = E.federation_leader(ctx.this.id)
    if leader == nil then return false end
    return (leader == ctx.this.id) == yes(e)
end
-- num_communications <op> n: the country's relations with communications
TRIG["num_communications"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.num_communications then return false end
    sync()
    return compare_num(E.num_communications(ctx.this.id), e, ctx)
end
-- is_controlled_by = <country> (CIsControlledByTrigger 0x194c0c0): a planet's controller, a
-- starbase's, fleet's or ship's owner
TRIG["is_controlled_by"] = function(e, ctx)
    local other = E.controller and ctx.this ~= NONE and target_country(e, ctx)
    if not other then return false end
    sync()
    return E.controller(ctx.this.kind, ctx.this.id) == other.id
end

-- a country's crisis, relics, focus, special projects, technologies (engine/interface.lua says
-- where each is in the save)
-- has_menace_perk = <perk> (CHasCrisisPerkTrigger 0x1a1cab0): a perk of an unlocked crisis level
TRIG["has_menace_perk"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.has_menace_perk or not e.value.text then return false end
    sync()
    return E.has_menace_perk(ctx.this.id, e.value.text)
end
-- has_crisis_perk: the same trigger class
TRIG["has_crisis_perk"] = TRIG["has_menace_perk"]
-- has_relic = <relic> (CHasRelicTrigger 0x19b2990): the country's relics
TRIG["has_relic"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.has_relic or not e.value.text then return false end
    sync()
    return E.has_relic(ctx.this.id, e.value.text)
end
-- has_active_focus = <focus card type> (CHasActiveFocusTrigger 0x1a19860): an active, not completed
-- focus card of the type
TRIG["has_active_focus"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.has_active_focus or not e.value.text then return false end
    sync()
    return E.has_active_focus(ctx.this.id, e.value.text)
end
-- has_completed_special_project_in_log = <project> (CHasSpecialProjectStatusTrigger<Completed>
-- 0x19e5740): a completed special project of the key
TRIG["has_completed_special_project_in_log"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.completed_special_project or not e.value.text then return false end
    sync()
    return E.completed_special_project(ctx.this.id, e.value.text)
end
-- num_repeatable_techs <op> n (CNumRepeatableTechsTrigger 0x1990580): the levels of the
-- multi-level technologies researched
TRIG["num_repeatable_techs"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.num_repeatable_techs then return false end
    sync()
    return compare_num(E.num_repeatable_techs(ctx.this.id), e, ctx)
end
-- has_built_species = yes/no (CHasBuiltSpecies 0x19949c0): the country's built species exists
TRIG["has_built_species"] = function(e, ctx)
    if ctx.this.kind ~= "country" or not E.has_built_species then return false end
    sync()
    return E.has_built_species(ctx.this.id) == yes(e)
end
-- num_unique_species <op> n (CNumSpeciesTrigger<SExactNumSpeciesCounter> 0x19e5000: a country's
-- CCountry::ListExactSpecies 0x6f99c0, the distinct species of its colonies' pop groups; a
-- planet's, its pop groups')
TRIG["num_unique_species"] = function(e, ctx)
    local sc = ctx.this
    if not E.owned_species or not E.species_of then return false end
    sync()
    local n = 0
    if sc.kind == "country" then
        n = #E.owned_species(sc.id)
    elseif sc.kind == "planet" then
        local seen = {}
        for _, g in ipairs(E.pop_groups(sc.id)) do
            local s = E.species_of("pop_group", g)
            if s and not seen[s] then seen[s] = true; n = n + 1 end
        end
    end
    return compare_num(n, e, ctx)
end
-- is_being_integrated_by = <country> (CSpeciesBeingIntegratedTrigger 0x1a27aa0): the scope's
-- species' subspecies integration in the country integrates
TRIG["is_being_integrated_by"] = function(e, ctx)
    local other = E.species_being_integrated and ctx.this ~= NONE and target_country(e, ctx)
    if not other then return false end
    sync()
    local sid = E.species_of(ctx.this.kind, ctx.this.id)
    return sid ~= nil and E.species_being_integrated(sid, other.id)
end
-- has_monthly_income = { resource = r value <op> x } (CHasMonthlyIncomeTrigger 0x1992c90): the
-- country's net income of r last month (the budget's last_month: income minus expenses)
TRIG["has_monthly_income"] = function(e, ctx)
    if e.value.text or ctx.this.kind ~= "country" or not E.budget_sum then return false end
    local res, op, amount = nil, ">=", 0
    for _, x in ipairs(e.value) do
        local xk = x.op and x.key.text:lower()
        if xk == "resource" then res = x.value.text
        elseif xk == "value" then op = x.op; amount = M.value(x.value, ctx, x) end
    end
    if not res then return false end
    sync()
    return compare(E.budget_sum(ctx.this.id, "last_month", "balance", res), op, amount)
end
-- resource_income_compare / resource_expenses_compare = { resource = r value <op> x [category = c] }
-- (CResourceCompareTrigger<SResourceIncomeCompare / SResourceExpensesCompare> 0x19e3b70,
-- GetResourceAmount 0x19ae6e0 / 0x19ae780) on this month's budget (current_month), over all
-- categories or the category's: the "income" one reads the balance, income minus expenses
-- (CCountry +0x1f90, _Budget._CurrentMonth._Total._SummedBalance), not the gross income
local function budget_compare(side)
    return function(e, ctx)
        if e.value.text or ctx.this.kind ~= "country" or not E.budget_sum then return false end
        local res, op, amount, category = nil, "=", 0, nil
        for _, x in ipairs(e.value) do
            local xk = x.op and x.key.text:lower()
            if xk == "resource" then res = x.value.text
            elseif xk == "category" then category = x.value.text
            elseif xk == "value" then op = x.op; amount = M.value(x.value, ctx, x) end
        end
        if not res then return false end
        sync()
        return compare(E.budget_sum(ctx.this.id, "current_month", side, res, category), op, amount)
    end
end
TRIG["resource_income_compare"] = budget_compare("balance")
TRIG["resource_expenses_compare"] = budget_compare("expenses")
-- num_owned_colonies <op> n (CNumOwnedColoniesTrigger::GetTriggerValue 0x1959a30): the country's
-- colonies (`owned_planets`, colony ids)
TRIG["num_owned_colonies"] = function(e, ctx)
    if ctx.this.kind ~= "country" then return false end
    sync()
    return compare_num(tonumber(E.get("country", ctx.this.id, "num_colonies")) or 0, e, ctx)
end

-- colonies (a planet's, a pop group's)
-- has_branch_office = yes / no / <country> (CHasBranchOfficeTrigger 0x19a0dc0): the colony has a
-- branch office (of the country)
TRIG["has_branch_office"] = function(e, ctx)
    if not E.branch_office_owner or ctx.this == NONE then return false end
    sync()
    local owner = E.branch_office_owner(ctx.this.kind, ctx.this.id)
    if yes_no(e) then return (owner ~= nil) == yes(e) end
    local other = target_country(e, ctx)
    return other ~= nil and owner == other.id
end
-- has_district = yes / no / <district type> (CHasDistrictTrigger 0x196ed70)
TRIG["has_district"] = function(e, ctx)
    if not E.has_district or ctx.this == NONE or not e.value.text then return false end
    sync()
    if yes_no(e) then return (E.num_districts(ctx.this.kind, ctx.this.id) > 0) == yes(e) end
    return E.has_district(ctx.this.kind, ctx.this.id, e.value.text)
end
-- num_zones <op> n, or num_zones = { type = <zone type> value <op> n } (CNumZonesTrigger 0x196fed0)
TRIG["num_zones"] = function(e, ctx)
    if not E.num_zones or ctx.this == NONE then return false end
    local ztype, op, want = nil, e.op, nil
    if e.value.text then
        want = M.value(e.value, ctx, e)
    else
        for _, x in ipairs(e.value) do
            local xk = x.op and x.key.text:lower()
            if xk == "type" then ztype = x.value.text
            elseif xk == "value" then op = x.op; want = M.value(x.value, ctx, x) end
        end
    end
    sync()
    return compare(E.num_zones(ctx.this.kind, ctx.this.id, ztype), op, want or 0)
end
-- is_under_colonization = yes/no (CIsUnderColonizationTrigger 0x1966c10): the colony's colonizing
-- species (false without a colony)
TRIG["is_under_colonization"] = function(e, ctx)
    if not E.colonizing_species or ctx.this == NONE then return false end
    sync()
    if ctx.this.kind == "planet" and not E.get("planet", ctx.this.id, "colony") then return false end
    return (E.colonizing_species(ctx.this.kind, ctx.this.id) ~= nil) == yes(e)
end
-- uses_district_set = <set> (CPlanetDistrictSetTrigger 0x1a09320): the planet class's district_set
TRIG["uses_district_set"] = function(e, ctx)
    if not E.district_set or ctx.this.kind ~= "planet" or not e.value.text then return false end
    sync()
    return E.district_set(ctx.this.kind, ctx.this.id) == e.value.text
end

-- the galaxy
-- is_galactic_community_formed = yes/no (CIsGalacticCommunityFormedTrigger 0x1a062f0)
TRIG["is_galactic_community_formed"] = function(e)
    if not E.galactic_community_formed then return false end
    return E.galactic_community_formed() == yes(e)
end
-- days_passed <op> n (CDaysPassedTrigger::GetTriggerValue 0x1959010): (year - START_YEAR) * 360 +
-- the day of the year, the days since 2200.01.01
TRIG["days_passed"] = function(e, ctx)
    return compare(M.today() - 2200 * 360, e.op, M.value(e.value, ctx, e))
end

-- numeric engine reads: key -> scope kind, field
local NUMS = {
    num_owned_planets = { "country", "num_colonies" },
    num_colonies = { "country", "num_colonies" },
    num_pops = { nil, "num_pops" },
    num_leaders = { "country", "num_leaders" },
    has_base_skill = { "leader", "has_base_skill" },
}
for k, spec in pairs(NUMS) do
    TRIG[k] = function(e, ctx)
        local sc = ctx.this
        local kind = spec[1] or sc.kind
        if kind ~= sc.kind then return false end
        sync()
        local field = spec[2]
        if sc.kind == "planet" and field == "num_pops" then field = "pops" end
        local v = E.get(sc.kind, sc.id, field)
        return compare(tonumber(v) or 0, e.op, M.value(e.value, ctx, e))
    end
end

-- property triggers: engine properties the world exposes as attributes (`is_country_type =
-- default`, `is_ai = no`) or sets (`has_ethic = ethic_x`); the Rust World's attrs/sets are keyed
-- by the trigger's name
local PROP_ATTR = {
    is_country_type = true, is_ai = true, is_gestalt = true, is_machine_empire = true,
    is_hive_empire = true, is_megacorp = true, is_planet_class = true, is_capital = true,
    is_homeworld = true, has_owner = true, is_colony = true, is_primitive = true,
    is_fallen_empire = true, is_crisis_faction = true, is_pirate = true, is_galactic_custodian = true,
    is_galactic_emperor = true, is_lithoid_empire = true,
    -- engine state the sample world does not have (no wars, federations, subjects): absent = no
    is_at_war = true, is_subject = true, is_overlord = true, has_federation = true, is_nomadic = true,
    is_councilor = true, is_galactic_community_member = true, is_ruler = true, is_in_federation = true,
    -- species (and pop groups, leaders: their species')
    is_sapient = true, is_infertile = true, is_robotic = true, is_robotic_species = true, is_archetype = true,
    last_increased_tech = true, is_megastructure_type = true,
    leader_class = true, is_leader_tier = true, is_hidden = true, is_being_assimilated = true,
    is_criminal_syndicate = true,
}
local PROP_SET = {
    has_ethic = true, has_civic = true, has_valid_civic = true, has_authority = true, has_origin = true,
    has_government = true, has_designation = true, has_trait = true, has_policy_flag = true,
    has_tradition = true, has_ascension_perk = true, has_edict = true, has_building = true,
    is_species_class = true, is_species = true, has_covenant = true, has_crisis_level = true,
    has_ai_personality = true, has_active_tradition = true, has_deposit = true, has_event_chain = true,
    has_ai_personality_behaviour = true, species_portrait = true,
}
local function property_trigger(e, ctx, lk)
    local sc = ctx.this
    if sc == NONE then return false end
    sync()
    local v = e.value.text
    if PROP_SET[lk] then
        local set = lk
        if lk == "has_building" then set = "building" elseif lk == "has_edict" then set = "edict" end
        return E.has(sc.kind, sc.id, set, v)
    end
    local have = E.get(sc.kind, sc.id, lk)
    if v == "yes" or v == "no" then
        return (have == "yes" or have == true) == (v == "yes")
    end
    return have ~= nil and tostring(have) == v
end
function M.property(lk)
    if PROP_ATTR[lk] or PROP_SET[lk] then return property_trigger end
    return nil
end

-- fleets: orders
-- is_surveyed = { who = <country> status = yes/no } (CIsSurveyedTrigger): the country surveyed the
-- planet (CCountry::HasSurveyedDepositHolder: auto-surveyed or in its surveyed_deposit_holders),
-- or every planet of the system (E.is_surveyed, engine.fleets.survey)
TRIG["is_surveyed"] = function(e, ctx)
    local sc = ctx.this
    if sc == NONE or e.value.text ~= nil or not E.is_surveyed then return false end
    local who, status = nil, true
    for _, x in ipairs(e.value) do
        if x.op and x.key then
            local k = x.key.text:lower()
            if k == "who" and x.value.text then
                local f, s = M.resolve(x.value.text, ctx, x)
                if f then who = s end
            elseif k == "status" then
                status = x.value.text ~= "no"
            end
        end
    end
    if not who or who == NONE or who.kind ~= "country" then return false end
    sync()
    return (E.is_surveyed(sc.kind, sc.id, who.id) == true) == status
end
-- has_anomaly = yes/no (CHasAnomalyTrigger): the planet has an anomaly (E.has_anomaly)
TRIG["has_anomaly"] = function(e, ctx)
    local sc = ctx.this
    if sc == NONE or not E.has_anomaly then return false end
    sync()
    return (E.has_anomaly(sc.kind, sc.id) == true) == yes(e)
end

-- ---------------------------------------------------------------------------------------------
-- effects

local EFF = {}
M.EFF = EFF

local function count_script() stats.script = stats.script + 1 end

local function push_engine(t)
    stats.engine = stats.engine + 1
    E.push(t)
end

local function unmodelled(lk, ctx, e)
    local m = stats.unmodelled[lk]
    if not m then
        m = { key = lk, count = 0, first = where(ctx, e) }
        stats.unmodelled[lk] = m
    end
    m.count = m.count + 1
    push_engine({ type = "unmodelled", keyword = lk })
end

local function iterate_effect(kind, lname, e, ctx)
    local list = list_of(lname, e.value, ctx, e)
    if not list then
        miss("iterator", kind .. "_" .. lname, ctx, e)
        return
    end
    local limit, order_by, position, max = nil, nil, 0, 1
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk == "limit" then limit = x.value
            elseif xk == "order_by" then order_by = x.value
            elseif xk == "position" then position = M.value(x.value, ctx, x)
            elseif xk == "max" then max = M.value(x.value, ctx, x) end
        end
    end
    local chosen = {}
    for _, s2 in ipairs(list) do
        if not limit or trigger(limit, push(ctx, s2)) then chosen[#chosen + 1] = s2 end
    end
    if kind == "random" then
        if #chosen == 0 then return end
        chosen = { chosen[rand() % #chosen + 1] }
    elseif kind == "ordered" then
        local keyed = {}
        for i, s2 in ipairs(chosen) do
            keyed[i] = { s2, order_by and M.value(order_by, push(ctx, s2), e) or 0, i }
        end
        table.sort(keyed, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[3] < b[3] end)
        chosen = {}
        for i = position + 1, math.min(#keyed, position + max) do
            chosen[#chosen + 1] = keyed[i][1]
        end
    end
    for _, s2 in ipairs(chosen) do
        effect(e.value, push(ctx, s2), ITER_PARAMS)
    end
end

local EVENT_EFFECT = {}
for k in pairs(db.EVENT_KINDS) do EVENT_EFFECT[k] = true end

local function effect1(e, ctx)
    stats.effect_runs = stats.effect_runs + 1
    local key = e.key.text
    local lk = key:lower()
    local h = EFF[lk]
    if h then
        return h(e, ctx, lk)
    end
    if EVENT_EFFECT[lk] then
        return M.fire_event_effect(lk, e, ctx)
    end
    local found, sc = M.resolve(key, ctx, e)
    if found then
        if sc and e.value.text == nil then effect(e.value, push(ctx, sc)) end
        return
    end
    local kind, lname = lk:match("^(every)_(.+)$")
    if not kind then kind, lname = lk:match("^(random)_(.+)$") end
    if not kind then kind, lname = lk:match("^(ordered)_(.+)$") end
    if kind and e.value.text == nil then
        return iterate_effect(kind, lname, e, ctx)
    end
    local def = db.scripted_effects[key]
    if def then
        if e.value.text == "no" then return end
        local body = scripted_call(def, key, e, "effect")
        if not body then
            miss("effect", "instantiate " .. key, ctx, e)
            return
        end
        return effect(body, with_file(ctx, def.file))
    end
    local verb, fk = lk:match("^(set)_(.+)_flag$")
    if not verb then verb, fk = lk:match("^(remove)_(.+)_flag$") end
    if verb and e.value.text then
        local name = flag_name(e.value.text, ctx, e)
        count_script()
        local sc = fk ~= "global" and ctx.this or nil
        if verb == "set" then
            M.store.set_flag(sc, name, nil)
        else
            M.store.remove_flag(sc, name)
        end
        return
    end
    fk = lk:match("^set_timed_(.+)_flag$")
    if fk and e.value.text == nil then
        local name, days = nil, 0
        for _, x in ipairs(e.value) do
            if x.op then
                local xk = x.key.text:lower()
                if xk == "flag" then name = flag_name(x.value.text, ctx, x)
                elseif xk == "days" then days = M.value(x.value, ctx, x)
                elseif xk == "months" then days = M.value(x.value, ctx, x) * 30
                elseif xk == "years" then days = M.value(x.value, ctx, x) * 360 end
            end
        end
        if name then
            count_script()
            M.store.set_flag(fk ~= "global" and ctx.this or nil, name, days)
        end
        return
    end
    if db.doc_effects[lk] then
        return unmodelled(lk, ctx, e)
    end
    miss("effect", lk, ctx, e)
end

effect = function(b, ctx, skip)
    local taken = false
    for _, e in ipairs(b) do
        if e.op and e.key then
            local lk = e.key.text:lower()
            if not (skip and skip[lk]) then
                if lk == "if" or lk == "else_if" or lk == "else" then
                    if lk == "if" then taken = false end
                    if not taken and e.value.text == nil then
                        local lim
                        for _, x in ipairs(e.value) do
                            if x.op and x.key.text:lower() == "limit" then lim = x.value end
                        end
                        if lk == "else" or not lim or trigger(lim, ctx) then
                            taken = true
                            effect(e.value, ctx, { limit = true })
                        end
                    end
                else
                    effect1(e, ctx)
                end
            end
        end
    end
end
M.effect = effect
M.effect1 = effect1

local function noop() end
EFF["hidden_effect"] = function(e, ctx) if e.value.text == nil then effect(e.value, ctx) end end
EFF["custom_tooltip"] = noop
EFF["tooltip"] = noop
EFF["log"] = noop
EFF["log_error"] = noop
EFF["set_update_modifiers_batch"] = noop
EFF["optimize_memory"] = noop
EFF["while"] = function(e, ctx)
    local n, limit = nil, nil
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk == "count" then n = M.value(x.value, ctx, x) elseif xk == "limit" then limit = x.value end
        end
    end
    local i = 0
    while i < (n or 1000) do
        if limit and not trigger(limit, ctx) then break end
        effect(e.value, ctx, { count = true, limit = true })
        i = i + 1
    end
end
EFF["random"] = function(e, ctx)
    local chance = 100
    for _, x in ipairs(e.value) do
        if x.op and x.key.text:lower() == "chance" then chance = M.value(x.value, ctx, x) end
    end
    local c = M.weight(e.value, ctx, chance)
    if (rand() % 10000) < c * 100 then
        effect(e.value, ctx, { chance = true, modifier = true })
    end
end
EFF["random_list"] = function(e, ctx)
    local entries, total = {}, 0
    for _, x in ipairs(e.value) do
        if x.op and x.value.text == nil then
            local w = M.weight(x.value, ctx, tonumber(x.key.text) or M.value(x.key, ctx, x))
            local ok = true
            for _, y in ipairs(x.value) do
                if y.op and y.key.text:lower() == "trigger" then ok = trigger(y.value, ctx) end
            end
            if ok and w > 0 then
                entries[#entries + 1] = { x.value, floor(w * 1000) }
                total = total + floor(w * 1000)
            end
        end
    end
    if total <= 0 then return end
    local r = rand() % total
    for _, en in ipairs(entries) do
        if r < en[2] then
            return effect(en[1], ctx, { modifier = true, trigger = true })
        end
        r = r - en[2]
    end
end
EFF["locked_random_list"] = EFF["random_list"]

local function var_effect(op)
    return function(e, ctx)
        local which, val
        if e.value.text then which = e.value.text else
            for _, x in ipairs(e.value) do
                if x.op then
                    local xk = x.key.text:lower()
                    if xk == "which" then which = x.value.text
                    elseif xk == "value" then val = M.value(x.value, ctx, x) end
                end
            end
        end
        if not which then return end
        count_script()
        local cur = getvar(ctx.this, which) or 0
        local v = val or 0
        if op == "set" then cur = v
        elseif op == "change" then cur = cur + v
        elseif op == "subtract" then cur = cur - v
        elseif op == "multiply" then cur = cur * v
        elseif op == "divide" then if v ~= 0 then cur = cur / v end
        elseif op == "modulo" then if v ~= 0 then cur = cur % v end
        elseif op == "round" then cur = floor(cur + 0.5)
        elseif op == "floor" then cur = floor(cur)
        elseif op == "ceiling" then cur = math.ceil(cur)
        elseif op == "abs" then cur = math.abs(cur)
        elseif op == "clear" then cur = nil end
        setvar(ctx.this, which, cur)
    end
end
for _, op in ipairs({ "set", "change", "subtract", "multiply", "divide", "modulo", "round", "floor", "ceiling", "abs" }) do
    EFF[op .. "_variable"] = var_effect(op)
end
EFF["clear_variable"] = var_effect("clear")
EFF["remove_variable"] = var_effect("clear")
EFF["clamp_variable"] = function(e, ctx)
    local which, lo, hi
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk == "which" then which = x.value.text
            elseif xk == "min" then lo = M.value(x.value, ctx, x)
            elseif xk == "max" then hi = M.value(x.value, ctx, x) end
        end
    end
    if not which then return end
    count_script()
    local v = getvar(ctx.this, which) or 0
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    setvar(ctx.this, which, v)
end
EFF["save_event_target_as"] = function(e, ctx) count_script(); ctx.targets[e.value.text] = ctx.this end
EFF["save_global_event_target_as"] = function(e, ctx) count_script(); state.global_targets[e.value.text] = ctx.this end
EFF["clear_global_event_target"] = function(e) count_script(); state.global_targets[e.value.text] = nil end
EFF["clear_global_event_targets"] = function() count_script(); state.global_targets = {} end
EFF["add_to_temp_list"] = function(e, ctx)
    count_script()
    local l = ctx.lists[e.value.text]
    if not l then l = {}; ctx.lists[e.value.text] = l end
    l[#l + 1] = ctx.this
end
EFF["remove_from_temp_list"] = function(e, ctx)
    count_script()
    local l = ctx.lists[e.value.text] or {}
    for i = #l, 1, -1 do if l[i] == ctx.this then table.remove(l, i) end end
end
EFF["fire_on_action"] = function(e, ctx)
    local name
    if e.value.text then name = e.value.text else
        for _, x in ipairs(e.value) do
            if x.op and x.key.text:lower() == "on_action" then name = x.value.text end
        end
    end
    if name then M.on_action(name, ctx.this, ctx) end
end

-- engine effects with a model in the Rust engine
EFF["add_resource"] = function(e, ctx)
    if e.value.text then return unmodelled("add_resource", ctx, e) end
    local mult = 1
    for _, x in ipairs(e.value) do
        if x.op and x.key.text:lower() == "mult" then mult = M.value(x.value, ctx, x) end
    end
    for _, x in ipairs(e.value) do
        if x.op then
            local xk = x.key.text:lower()
            if xk ~= "mult" and xk ~= "reset_resource_storage" then
                push_engine({ type = "add_resource", kind = ctx.this.kind, id = ctx.this.id, resource = x.key.text,
                    amount = M.value(x.value, ctx, x) * mult })
            end
        end
    end
end
EFF["add_modifier"] = function(e, ctx)
    local name, days
    if e.value.text then name = e.value.text else
        for _, x in ipairs(e.value) do
            if x.op then
                local xk = x.key.text:lower()
                if xk == "modifier" then name = x.value.text
                elseif xk == "days" then days = M.value(x.value, ctx, x)
                elseif xk == "months" then days = M.value(x.value, ctx, x) * 30
                elseif xk == "years" then days = M.value(x.value, ctx, x) * 360 end
            end
        end
    end
    if not name then return end
    if days and days < 0 then days = nil end
    local entries = db.static_modifiers[name]
    if not entries then miss("static modifier", name, ctx, e) end
    push_engine({ type = "add_modifier", kind = ctx.this.kind, id = ctx.this.id, source = name,
        days = days and floor(days), entries = entries or {} })
end
EFF["create_pop_group"] = function(e, ctx)
    local species, size = "unknown", 1
    if e.value.text == nil then
        for _, x in ipairs(e.value) do
            if x.op then
                local xk = x.key.text:lower()
                if xk == "species" then species = x.value.text or species
                elseif xk == "size" or xk == "count" then size = M.value(x.value, ctx, x) end
            end
        end
    end
    local h = E.new_handle()
    ctx.created.pop_group = h
    ctx.created.pop = h
    push_engine({ type = "create_pop_group", kind = ctx.this.kind, id = ctx.this.id, species = species, size = size, handle = h })
end
EFF["create_leader"] = function(e, ctx)
    local h = E.new_handle()
    ctx.created.leader = h
    push_engine({ type = "create_leader", kind = ctx.this.kind, id = ctx.this.id, handle = h })
end
EFF["give_technology"] = function(e, ctx)
    local tech = e.value.text
    if not tech then
        for _, x in ipairs(e.value) do
            if x.op and x.key.text:lower() == "tech" then tech = x.value.text end
        end
    end
    if tech then push_engine({ type = "give_technology", kind = ctx.this.kind, id = ctx.this.id, tech = tech }) end
end
EFF["kill_leader"] = function(e, ctx)
    if ctx.this.kind == "leader" then push_engine({ type = "kill_leader", kind = "leader", id = ctx.this.id }) end
end
-- merge_species = yes (CMergeSpeciesEffect 0x17b9840, on a country): the country's identical species
-- merged (E.identical_species). Without any (none in the 2210 saves) it does nothing; a merge itself
-- (CCountry::HandleIdenticalSpeciesMerge 0x71a160: the merged species' pop groups re-keyed to the
-- other and joined, the founder species moved) is not modelled yet: it is pushed unmodelled
EFF["merge_species"] = function(e, ctx)
    if e.value.text ~= "yes" or ctx.this.kind ~= "country" or not E.identical_species then return end
    sync()
    if #E.identical_species(ctx.this.id) > 0 then
        unmodelled("merge_species", ctx, e)
    end
end

-- the status of a keyword for the coverage report: "lua" (implemented here), "scripted",
-- "scope", "iterator", "property", "flag", "event", "engine-unmodelled" (an effect pushed to the
-- engine without a model) or nil
function M.status(kind, key)
    local lk = key:lower()
    if lk == "if" or lk == "else_if" or lk == "else" then return "lua" end
    if kind == "trigger" then
        if TRIG[lk] then return "lua" end
        if M.property(lk) then return "property" end
        if lk:match("^has_.+_flag$") then return "flag" end
        if db.scripted_triggers[key] then return "scripted" end
        local it, l = lk:match("^(any)_(.+)$")
        if not it then it, l = lk:match("^(count)_(.+)$") end
        if it then return (LISTS[l] or l == "in_list") and "iterator" or nil end
    else
        if EFF[lk] then return "lua" end
        if EVENT_EFFECT[lk] then return "event" end
        if lk:match("^set_.+_flag$") or lk:match("^remove_.+_flag$") or lk:match("^set_timed_.+_flag$") then return "flag" end
        if db.scripted_effects[key] then return "scripted" end
        local it, l = lk:match("^(every)_(.+)$")
        if not it then it, l = lk:match("^(random)_(.+)$") end
        if not it then it, l = lk:match("^(ordered)_(.+)$") end
        if it then return (LISTS[l] or l == "in_list") and "iterator" or nil end
        if db.doc_effects[lk] then return "engine-unmodelled" end
    end
    local first = lk:match("^([^%.]+)")
    first = first:gsub("%?$", "")
    if LINKS[first] or first:sub(1, 13) == "event_target:" or first:sub(1, 13) == "last_created_" then
        return "scope"
    end
    return nil
end

return M
