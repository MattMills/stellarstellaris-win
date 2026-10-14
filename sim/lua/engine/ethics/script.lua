-- engine/ethics/script.lua : what the ethics' attraction scripts and the game rules of the pop
-- groups' ethics and factions ask of the script layer that it does not answer yet
-- (simscript/eval.lua), installed only while engine.ethics evaluates (script.with(f)), on top of
-- engine/colonies/script.lua (and through it engine/pops/script.lua, engine/economy/script.lua).
-- Each is a candidate for the script layer:
--
-- - pop_group_has_happiness (a pop group, CPopGroup::HasHappiness 0x67e4a0): the rule
--   species_has_happiness for the group's species, From = the group's owner (the rule
--   pop_group_can_join_factions asks it);
-- - has_citizenship_rights (a pop group or species): the citizenship type of the species' rights in
--   the owner has `is_full_citizenship = yes` (common/species_rights/citizenship_types; the
--   scripted trigger it replaced, commented out in 00_scripted_triggers.txt, said: citizenship_full
--   or citizenship_full_machine);
-- - is_same_species with a country (its founder species: `is_same_species = from.owner`) or a
--   leader;
-- - check_variable_arithmetic (check_variable's comparison: `which = value:x value != 1`);
-- - has_opinion_modifier = { who modifier } (the country's relation with `who`),
--   is_original_owner (a planet) (is_sector_capital, is_councilor_type, has_election_type and
--   has_faction are the script layer's now: simscript/handlers/runtime.lua);
-- - the list enslaved_species (a country's enslaved_species_refs; a planet's enslaved pop groups'
--   species).

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local S = eval.S
local script = { used = {} }

local NONE = 4294967295

local function count(name)
    script.used[name] = (script.used[name] or 0) + 1
end

local function yes(e) return e.value.text ~= "no" end

local function group_species(gid)
    local key = world.field(world.object("pop_groups", gid), "key")
    return type(key) == "table" and tonumber(world.field(key, "species")) or nil
end

local function group_owner(gid)
    local g = world.object("pop_groups", gid)
    local cid = g and tonumber(world.field(g, "planet"))
    local pid = cid and world.colony_planet[cid]
    local p = pid and world.object("planet", pid)
    local o = p and tonumber(world.field(p, "owner"))
    if o == NONE then return nil end
    return o
end

local happiness_cache = {}   -- "species|owner" -> bool, for the day
function script.new_day()
    happiness_cache = {}
end

-- CPopGroup::HasHappiness: the rule species_has_happiness (This = species, From = the owner)
function script.species_has_happiness(sid, owner)
    if not sid then return false end
    local k = tostring(sid) .. "|" .. tostring(owner)
    local v = happiness_cache[k]
    if v == nil then
        local d = defs.get("common/game_rules", "species_has_happiness")
        v = true
        if d then
            local ok, holds = pcall(eval.trigger, d.block, eval.new_ctx(S("species", sid), owner and S("country", owner) or nil))
            v = ok and holds and true or false
            if not ok then count("species_has_happiness error") end
        end
        happiness_cache[k] = v
    end
    return v
end

local trig = {}
trig.pop_group_has_happiness = function(e, ctx)
    local this = ctx.this
    if this.kind ~= "pop_group" then return false == yes(e) end
    return script.species_has_happiness(group_species(this.id), group_owner(this.id)) == yes(e)
end

trig.has_citizenship_rights = function(e, ctx)
    local this = ctx.this
    if this.kind ~= "pop_group" and this.kind ~= "species" then return false == yes(e) end
    local sid = this.kind == "species" and this.id or group_species(this.id)
    local owner = this.kind == "pop_group" and group_owner(this.id) or (ctx.root.kind == "country" and ctx.root.id) or nil
    local economy_script = require("engine.economy.script")
    local r = owner and sid and economy_script.rights and economy_script.rights(owner, sid)
    local citizenship = r and world.field(r, "citizenship")
    local d = citizenship and defs.get("common/species_rights/citizenship_types", citizenship)
    local citizen = d ~= nil and defs.field(d.block, "is_full_citizenship") == "yes"
    return citizen == yes(e)
end

-- the species of a scope: a species, a pop group's, a leader's, a country's founder species
-- (founder_species_ref)
local function species_of(sc)
    if not sc then return nil end
    if sc.kind == "species" then return sc.id end
    if sc.kind == "pop_group" then return group_species(sc.id) end
    if sc.kind == "leader" then return tonumber(world.field(world.object("leader", sc.id), "species")) end
    if sc.kind == "country" then return tonumber(world.field(world.object("country", sc.id), "founder_species_ref")) end
    return nil
end
script.species_of = species_of

-- is_same_species = <scope>: this and that scope's species are the same (a country's: its founder
-- species; `is_same_species = from.owner` in the xenophile attraction)
trig.is_same_species = function(e, ctx)
    local a = species_of(ctx.this)
    if not e.value.text or not a then return false end
    local ok, sc = eval.resolve(e.value.text, ctx, e)
    local b = ok and sc and species_of(sc)
    return b ~= nil and a == b
end

-- check_variable_arithmetic = { which = value:x value <op> n }: check_variable's comparison, the
-- value through engine.ethics' value_number (which counts value:count_councilors_with_ethic itself)
trig.check_variable_arithmetic = function(e, ctx, lk)
    if e.value.text then return false end
    local which, op, val
    for _, x in ipairs(e.value) do
        if x.op and x.key then
            local xk = x.key.text:lower()
            if xk == "which" then which = x.value.text
            elseif xk == "value" then op = x.op; val = eval.value(x.value, ctx, x) end
        end
    end
    if not which then return false end
    local a = require("engine.ethics").value_number(which, ctx)
    return eval.compare(a, op or "=", val or 0)
end

local function country_of(sc)
    if not sc then return nil end
    if sc.kind == "country" then return sc.id end
    return nil
end

-- has_opinion_modifier = { who = <country> modifier = <name> } (a country): this country's relation
-- with `who` holds the opinion modifier (relations_manager's relation { owner country modifier })
trig.has_opinion_modifier = function(e, ctx)
    local c = country_of(ctx.this)
    if not c or e.value.text then return false end
    local who, name
    for _, x in ipairs(e.value) do
        if x.op and x.key then
            local k = x.key.text:lower()
            if k == "who" then
                local ok, sc = eval.resolve(x.value.text, ctx, x)
                who = ok and sc and country_of(sc)
            elseif k == "modifier" then
                name = x.value.text
            end
        end
    end
    if not who or not name then return false end
    local rm = world.field(world.object("country", c), "relations_manager")
    for _, r in ipairs(type(rm) == "table" and world.fields(rm, "relation") or {}) do
        if type(r) == "table" and tonumber(world.field(r, "country")) == who then
            for _, m in ipairs(world.fields(r, "modifier")) do
                if type(m) == "table" and world.field(m, "modifier") == name then return true end
            end
        end
    end
    return false
end

-- is_original_owner (a planet): = yes|no, its original_owner is its owner; = <country>, its
-- original_owner is that country (`is_original_owner = root` in the militarist attraction)
trig.is_original_owner = function(e, ctx)
    if ctx.this.kind ~= "planet" then return false end
    local p = world.object("planet", ctx.this.id)
    local oo = tonumber(world.field(p, "original_owner"))
    local t = e.value.text
    if t == "yes" or t == "no" then
        local o = tonumber(world.field(p, "owner"))
        return (oo ~= nil and oo == o) == (t == "yes")
    end
    local ok, sc = eval.resolve(t or "", ctx, e)
    local c = ok and sc and country_of(sc)
    return c ~= nil and oo == c
end

-- lists
local lists = {}
-- enslaved_species: a country's enslaved_species_refs; a planet's: the species of its enslaved pop
-- groups
lists.enslaved_species = function(sc, ctx)
    local out, seen = {}, {}
    if sc.kind == "country" then
        for _, t in ipairs(world.list(world.field(world.object("country", sc.id), "enslaved_species_refs"))) do
            local s = tonumber(t)
            if s and not seen[s] then seen[s] = true out[#out + 1] = S("species", s) end
        end
    elseif sc.kind == "planet" then
        local col = tonumber(world.field(world.object("planet", sc.id), "colony"))
        local c = col and world.object("colony", col)
        local is_enslaved = eval.TRIG.is_enslaved
        for _, t in ipairs(world.list(c and world.field(c, "pop_groups"))) do
            local gid = tonumber(t)
            local g = gid and world.object("pop_groups", gid)
            if g and world.field(g, "killed") ~= "yes" and is_enslaved then
                local gctx = eval.new_ctx(S("pop_group", gid))
                if is_enslaved({ value = { text = "yes" } }, gctx) then
                    local s = group_species(gid)
                    if s and not seen[s] then seen[s] = true out[#out + 1] = S("species", s) end
                end
            end
        end
    end
    return out
end

local TRIG, LISTS = eval.TRIG, eval.LISTS
script.orig, script.orig_lists = {}, {}
local installed = 0

-- script.with(f, ...) -> f's results, with the colonies', pops', economy's and these triggers in place
function script.with(f, ...)
    local inner = function(...)
        if installed > 0 then
            return f(...)
        end
        installed = installed + 1
        for k, g in pairs(trig) do
            script.orig[k] = TRIG[k]
            TRIG[k] = function(...) count(k) return g(...) end
        end
        for k, g in pairs(lists) do
            script.orig_lists[k] = LISTS[k]
            LISTS[k] = function(...) count("list " .. k) return g(...) end
        end
        local res = { pcall(f, ...) }
        for k in pairs(trig) do TRIG[k] = script.orig[k] end
        for k in pairs(lists) do LISTS[k] = script.orig_lists[k] end
        installed = installed - 1
        if not res[1] then
            error(res[2], 0)
        end
        return unpack(res, 2)
    end
    local ok, colonies = pcall(require, "engine.colonies")
    if ok and colonies and colonies.with_script then
        return colonies.with_script(inner, ...)
    end
    return inner(...)
end

return script
