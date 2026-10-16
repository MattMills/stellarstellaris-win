-- simscript/handlers/objects.lua : the effects that make the game's objects, the ones a new game's
-- start script runs (docs/newgame.md section 8, docs/script_objects.md): a colony's districts,
-- zones, buildings and pops; fleets and ships; leaders; policies; countries and species
-- (guardians, primitives); ambient objects, megastructures, wormholes. From the 4.5.2 Linux
-- build's effect classes (their ExecuteActual). Each effect is queued to the engine (E.push) and
-- applied by its applier (engine/script/objects.lua and the files it loads); an effect whose
-- result the script reads next (last_created_*, a count) or that draws from the game's generator
-- is applied at once (sync), so that its draws come where the game's do.
--
-- Loaded by simscript/handlers/init.lua after the creation module.

return function(eval)
    local I = eval._internal
    local EFF, TRIG = eval.EFF, eval.TRIG
    local E, stats, miss, sync, S, NONE = I.E, I.stats, I.miss, I.sync, I.S, I.NONE

    local objects = require("engine.script.objects")
    local unq = objects.unq
    local floor = math.floor

    local function where(ctx, e)
        return (ctx and ctx.file or "?") .. ":" .. tostring(e and e.line or "?")
    end
    local function push(t)
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
        return x and x.value.text and unq(x.value.text) or nil
    end
    local function yes_of(x, default)
        if not x or not x.value.text then return default end
        return x.value.text == "yes"
    end
    local function trunc(x)
        return x < 0 and -floor(-x) or floor(x)
    end
    local function int_of(x, ctx, default)
        if not x then return default end
        local v = eval.value(x.value, ctx, x)
        return v and trunc(v) or default
    end
    -- a scope named by `key = <target>` (nil when there is no such parameter or it names nothing)
    local function target(x, ctx)
        local t = x and x.value.text
        if not t then return nil end
        local found, sc = eval.resolve(t, ctx, x)
        if found then return (sc and sc ~= NONE) and sc or nil end
        return nil
    end
    -- the scope's colony carrier: kind, id (NScriptUtil::GetCarrierFromScope)
    local R = require("engine.script.runtime")
    local function carrier(ctx)
        sync()
        local sc = ctx.this
        if not sc or sc == NONE then return nil end
        return R.carrier_of(sc.kind, sc.id)
    end
    local function scope_t(sc)
        return sc and sc ~= NONE and { kind = sc.kind, id = sc.id } or nil
    end
    -- last_created_<kind>: the game keeps them in the game state, not in a scope (CGameState +0x920
    -- fleet, +0x924 ship, +0x928 leader, +0x930 design; the species', country's and ambient
    -- object's likewise [V for those four]): one table for every context, which each context's
    -- own `created` falls back to
    local LAST = {}
    eval.last_created = LAST
    local CK = I.CREATED_KIND
    for k, v in pairs({ fleet = "fleet", ship = "ship", country = "country", species = "species",
        ambient_object = "ambient_object", design = "ship_design", megastructure = "megastructure",
        army = "army", deposit = "deposit" }) do
        if CK[k] == nil then CK[k] = v end
    end
    local LAST_MT = { __index = LAST }
    local new_ctx = eval.new_ctx
    function eval.new_ctx(...)
        local c = new_ctx(...)
        if c.created and getmetatable(c.created) == nil then setmetatable(c.created, LAST_MT) end
        return c
    end
    local function created(ctx, kind, h)
        ctx.created[kind] = h
        LAST[kind] = h
    end

    eval.objects = { params = params, text_of = text_of, target = target, push = push, unmodelled = unmodelled,
        int_of = int_of, yes_of = yes_of, scope_t = scope_t, created = created }

    -- -----------------------------------------------------------------------------------------
    -- triggers

    -- carrier_is_type = planet|ship (CCarrierIsTypeTrigger::ActualEvaluate 0x3c16200): the token of
    -- the scope's colony carrier's type (CColonyCarrierRefSerializer::GetTokenFromCarrierType of
    -- CScopeObjectReference::GetColonyCarrierRef) is the one given; no carrier: false [V]
    TRIG["carrier_is_type"] = function(e, ctx)
        local want = e.value.text and unq(e.value.text)
        local kind = carrier(ctx)
        return kind ~= nil and kind == want
    end

    -- check_modifier_value: the graph brought up to date first when the objects changed it
    -- (engine.script.objects.fresh)
    local check_mv = TRIG["check_modifier_value"]
    if check_mv then
        TRIG["check_modifier_value"] = function(e, ctx)
            sync()
            objects.fresh()
            return check_mv(e, ctx)
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- the domains
    for _, name in ipairs({ "colony", "fleets", "leaders", "countries", "galaxy" }) do
        local ok, mod = pcall(require, "simscript.handlers.objects_" .. name)
        if ok then
            mod(eval, eval.objects)
        elseif not tostring(mod):find("module 'simscript.handlers.objects_" .. name .. "' not found", 1, true) then
            error(mod, 0)
        end
    end
end
