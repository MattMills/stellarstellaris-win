-- simscript/handlers/diplomacy_common.lua : the helpers the diplomacy handlers share
-- (handlers/diplomacy.lua and its parts: diplomacy_relations, diplomacy_wars, diplomacy_federations,
-- diplomacy_agreements, diplomacy_espionage). They read the world through engine.diplomacy and
-- write the save's own fields (the game's WriteMembers names, read in the 4.5.2 Linux binary with
-- the token table), so a save written after an effect has its change.
--
--   local H = require("simscript.handlers.diplomacy_common")(eval)

return function(eval)
    local I = eval._internal
    local S, NONE, compare, yes, sync = I.S, I.NONE, I.compare, I.yes, I.sync
    local stats = I.stats
    local D = require("engine.diplomacy")
    local world = require("engine.world")
    local defs = require("engine.defs")
    local floor = math.floor

    local H = { D = D, world = world, defs = defs, S = S, NONE = NONE, NO_ID = 4294967295 }

    function H.script_write() stats.script = stats.script + 1 end

    -- the scope's country (a country scope only)
    function H.this_country(ctx)
        local sc = ctx.this
        if sc and sc.kind == "country" and D.alive(sc.id) then return sc.id end
        return nil
    end
    -- the scope a text names (`= root`, `= event_target:x`), or nil
    function H.scope_of(text, ctx, e)
        if not text then return nil end
        local found, sc = eval.resolve(text, ctx, e)
        if found and sc and sc ~= NONE then return sc end
        return nil
    end
    -- the country a text names
    function H.country_of(text, ctx, e)
        local sc = H.scope_of(text, ctx, e)
        if sc and sc.kind == "country" and D.alive(sc.id) then return sc.id end
        return nil
    end
    -- `<k> = <country>`: the country the statement's value names
    function H.target_country(e, ctx)
        if not e.value.text then return nil end
        return H.country_of(e.value.text, ctx, e)
    end
    -- a block parameter's statement, its text, its scope, its country
    function H.param(block, key)
        if type(block) ~= "table" or block.text then return nil end
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key then return x end
        end
        return nil
    end
    function H.param_text(block, key)
        local x = H.param(block, key)
        return x and x.value.text or nil, x
    end
    function H.param_scope(block, key, ctx)
        local x = H.param(block, key)
        if not x or not x.value.text then return nil end
        return H.scope_of(x.value.text, ctx, x)
    end
    function H.param_country(block, key, ctx)
        local sc = H.param_scope(block, key, ctx)
        if sc and sc.kind == "country" and D.alive(sc.id) then return sc.id end
        return nil
    end
    -- a parameter's number (a value, a variable, a script value)
    function H.param_value(block, key, ctx, default)
        local x = H.param(block, key)
        if not x then return default end
        return eval.value(x.value, ctx, x)
    end
    -- the statement's own value: a yes/no, a number
    function H.bool(e) return e.value.text == "yes" end
    function H.value(e, ctx) return eval.value(e.value, ctx, e) end
    -- `<trigger> <op> <value>`, or `<trigger> = { value <op> n }`
    function H.compare_value(v, e, ctx)
        if v == nil then return false end
        if e.value.text then return compare(v, e.op, eval.value(e.value, ctx, e)) end
        local x = H.param(e.value, "value")
        if not x then return false end
        return compare(v, x.op, eval.value(x.value, ctx, x))
    end
    -- a CFixedPoint as the game keeps it (five decimals)
    function H.fixed(v)
        local n = tonumber(v)
        if not n then return 0 end
        return floor(n * 100000 + 0.5) / 100000
    end
    function H.num(v) return tonumber(v) or 0 end
    function H.countries_scopes(ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = S("country", id) end
        return out
    end
    -- a define (common/defines, the last file's value wins)
    function H.define(cat, key, default)
        local g = defs.get("common/defines", cat)
        return g and tonumber(defs.field(g.block, key)) or default
    end

    -- dates: today (eval.today's days) as the save writes it, the hour the flags hold
    function H.date_text(d)
        d = d or eval.today()
        return string.format("%d.%02d.%02d", floor(d / 360), floor((d % 360) / 30) + 1, d % 30 + 1)
    end
    function H.hour() return I.E.date() end

    -- writers -------------------------------------------------------------------------------------

    -- a key's first entry taken out of a block
    function H.remove_key(obj, key)
        if type(obj) ~= "table" then return false end
        local e = world.entry(obj, key)
        if e then
            world.remove_entry(obj, e)
            return true
        end
        return false
    end
    -- every entry of a key taken out
    function H.remove_all(obj, key)
        local n = 0
        while H.remove_key(obj, key) do n = n + 1 end
        return n
    end
    -- `key = yes` set, or taken out
    function H.set_yes(obj, key, on)
        if type(obj) ~= "table" then return end
        if on then
            world.set(obj, key, "yes")
        else
            H.remove_key(obj, key)
        end
    end
    -- a quoted string set (the save writes it in quotes)
    function H.set_quoted(obj, key, text)
        local t = world.token_entry(obj, key)
        if t then
            t.value.text = tostring(text)
            t.value.quoted = true
        else
            world.append(obj, key, tostring(text), true)
        end
    end
    -- an id list (`key = { 1 2 3 }`): has, add (at the end), remove
    function H.list_has(block, v)
        for _, x in ipairs(type(block) == "table" and world.list(block) or {}) do
            if tonumber(x) == v then return true end
        end
        return false
    end
    function H.list_add(obj, key, v)
        local b = world.child(obj, key)
        if not H.list_has(b, v) then world.append_value(b, tostring(v)) end
        return b
    end
    function H.list_remove(obj, key, v)
        local b = world.field(obj, key)
        if type(b) == "table" then world.remove_value(b, tostring(v)) end
    end

    -- the relation of a towards b (CCountry::AccessOrCreateNewRelation: made when there is none,
    -- `relation = { owner country }` in the relations manager)
    function H.relation(a, b, create)
        local r = D.relation(a, b)
        if r or not create then return r end
        local c = D.country(a)
        if not c or not D.alive(b) then return nil end
        local rm = world.child(c, "relations_manager")
        r = {}
        world.append(r, "owner", a)
        world.append(r, "country", b)
        world.append(rm, "relation", r)
        return r
    end

    -- the objects of the stores the world's KINDS does not name: a scope kind -> its store
    H.STORE = {
        agreement = "agreements", spy_network = "spy_networks", espionage_operation = "operations",
        espionage_asset = "espionage_assets", resolution = "resolution", truce = "truce",
    }
    function H.object(kind, id)
        return world.object(H.STORE[kind] or kind, id)
    end
    function H.all(kind)
        return world.all(H.STORE[kind] or kind)
    end
    -- a new object's id in a store (the next index after the highest)
    function H.next_id(kind)
        return world.next_index(H.STORE[kind] or kind)
    end

    -- the scope's object of a kind (a scope of that kind only), its id and block
    function H.scoped(ctx, kind)
        local sc = ctx.this
        if not sc or sc.kind ~= kind then return nil end
        local o = H.object(kind, sc.id)
        if not o then return nil end
        return sc.id, o
    end

    -- a top-level block of the save (the galactic community)
    function H.top(key)
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == key and e.value.text == nil then return e.value end
        end
        return nil
    end

    -- the definitions of a common/ folder (engine.defs), a definition's field
    function H.def(folder, key)
        return key and defs.get(folder, key) or nil
    end
    function H.def_field(d, key)
        return d and defs.field(d.block, key) or nil
    end

    -- a CScriptedTrigger-style evaluation of a definition's trigger block: this, from
    function H.holds(block, this, from)
        if type(block) ~= "table" then return true end
        local ctx = eval.new_ctx(this, from)
        local ok, r = pcall(eval.trigger, block, ctx)
        return ok and r == true
    end
    -- an effect block run in a scope (this, from)
    function H.run(block, this, from)
        if type(block) ~= "table" then return end
        local ctx = eval.new_ctx(this, from)
        pcall(eval.effect, block, ctx)
    end
    -- an on_action fired (this, from)
    function H.on_action(name, this, from)
        local ok, events = pcall(require, "simscript.events")
        if ok and events.on_action then
            pcall(events.on_action, name, this, eval.new_ctx(from or this, this))
        end
    end

    -- records a keyword that is not modelled on this path (stats.unmodelled)
    function H.unmodelled(key, ctx, e)
        local m = stats.unmodelled[key]
        if not m then
            m = { key = key, count = 0, first = (ctx and ctx.file or "?") .. ":" .. tostring(e and e.line or "?") }
            stats.unmodelled[key] = m
        end
        m.count = m.count + 1
    end

    -- numeric triggers that are also values (`trigger:<k>`): value(ctx) -> number or nil
    H.VALUE = {}
    function H.num_trigger(k, value)
        H.VALUE[k] = value
        eval.TRIG[k] = function(e, ctx)
            sync()
            return H.compare_value(value(ctx), e, ctx)
        end
        if eval.TRIGGER_VALUES then
            eval.TRIGGER_VALUES[k] = function(ctx)
                sync()
                return value(ctx) or 0
            end
        end
    end

    H.sync, H.yes, H.compare = sync, yes, compare
    return H
end
