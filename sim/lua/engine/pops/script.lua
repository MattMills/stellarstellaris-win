-- engine/pops/script.lua : what the game rules of pop growth ask of the script layer that it does
-- not answer yet (simscript/eval.lua), installed only while engine.pops evaluates (script.with(f)),
-- on top of the economy's links and triggers (engine/economy/script.lua: species, owner, planet,
-- is_sapient, has_citizenship_type of a pop group, ...). Each is a candidate for the script layer:
--
-- - species: is_infertile (a trait with `infertile = yes`), is_robotic / is_robotic_species (the
--   archetype's `robotic`), has_species_flag (the species' flags), has_citizenship_type and
--   has_population_control with `country = ...` (the species' rights in that country), is_sapient
--   (`sapient = no` in the save, or a PRESAPIENT archetype), is_same_species = <scope> (a pop
--   group, species, country: its founder species, or leader),
--   is_being_integrated_by (no: not in the save);
-- - custom_tooltip = { ... }: its triggers evaluated (the script layer takes it as true, which made
--   should_force_decline_species hold for every species);
-- - the link owner_main_species (the country's founder species).

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local S = eval.S
local script = { used = {} }

local function count(name)
    script.used[name] = (script.used[name] or 0) + 1
end

local function yes(e) return e.value.text ~= "no" end
local function param(e, key)
    if e.value.text then return e.value.text end
    for _, x in ipairs(e.value) do
        if x.op and x.key.text:lower() == key then return x.value.text end
    end
    return nil
end

local function species_of(sc)
    if sc.kind == "species" then return sc.id end
    if sc.kind == "pop_group" then
        local key = world.field(world.object("pop_groups", sc.id), "key")
        return type(key) == "table" and tonumber(world.field(key, "species")) or nil
    end
    -- a country's species: its founder species (CCountry +0x1574, founder_species_ref) [I]
    if sc.kind == "country" then
        return tonumber(world.field(world.object("country", sc.id), "founder_species_ref"))
    end
    -- a leader's: its species
    if sc.kind == "leader" then
        return tonumber(world.field(world.object("leaders", sc.id), "species"))
    end
    return nil
end

local function traits(sid)
    local t = world.field(world.object("species_db", sid), "traits")
    return type(t) == "table" and world.fields(t, "trait") or {}
end

local function archetype(sid)
    local class = world.field(world.object("species_db", sid), "class")
    local d = class and defs.get("common/species_classes", class)
    return d and defs.field(d.block, "archetype") or "BIOLOGICAL"
end

local function robotic(sid)
    local d = defs.get("common/species_archetypes", archetype(sid))
    return d ~= nil and defs.field(d.block, "robotic") == "yes"
end

local function infertile(sid)
    for _, t in ipairs(traits(sid)) do
        local d = type(t) == "string" and defs.get("common/traits", t)
        if d and defs.field(d.block, "infertile") == "yes" then return true end
    end
    return false
end

local trig = {}
trig.is_infertile = function(e, ctx)
    local sid = species_of(ctx.this)
    return (sid ~= nil and infertile(sid)) == yes(e)
end
trig.is_robotic = function(e, ctx)
    local sid = species_of(ctx.this)
    return (sid ~= nil and robotic(sid)) == yes(e)
end
trig.is_robotic_species = trig.is_robotic
trig.is_sapient = function(e, ctx)
    local sid = species_of(ctx.this)
    if not sid then return false == yes(e) end
    local s = world.object("species_db", sid)
    local sapient = world.field(s, "sapient") ~= "no" and archetype(sid) ~= "PRESAPIENT"
    return sapient == yes(e)
end
trig.has_species_flag = function(e, ctx)
    local sid = species_of(ctx.this)
    local flags = sid and world.field(world.object("species_db", sid), "flags")
    local name = e.value.text
    if type(flags) ~= "table" or not name then return false end
    return world.field(flags, name) ~= nil
end
-- has_citizenship_type = { type = x country = y } of a species (or a pop group: its owner unless
-- country is given)
local economy_script
trig.has_citizenship_type = function(e, ctx, lk)
    local sid = species_of(ctx.this)
    local want = param(e, "type")
    local country
    local ctext = e.value.text == nil and param(e, "country") or nil
    if ctext then
        local ok, sc = eval.resolve(ctext, ctx, e)
        if ok and sc and sc.kind == "country" then country = sc.id end
    end
    if not country and ctx.this.kind == "pop_group" and script.orig.has_citizenship_type then
        return script.orig.has_citizenship_type(e, ctx, lk)
    end
    if not (sid and country) then return false end
    economy_script = economy_script or require("engine.economy.script")
    local r = economy_script.rights and economy_script.rights(country, sid)
    return r ~= nil and world.field(r, "citizenship") == want
end

-- has_population_control = { type = yes/no country = x }: the species' rights in that country
trig.has_population_control = function(e, ctx)
    local sid = species_of(ctx.this)
    local want = param(e, "type")
    local ctext = e.value.text == nil and param(e, "country") or nil
    local country
    if ctext then
        local ok, sc = eval.resolve(ctext, ctx, e)
        if ok and sc and sc.kind == "country" then country = sc.id end
    end
    if not (sid and country) then return false end
    economy_script = economy_script or require("engine.economy.script")
    local r = economy_script.rights and economy_script.rights(country, sid)
    local pc = r and world.field(r, "population_control")
    return pc ~= nil and (pc == "population_control_yes") == (want == "yes")
end
-- is_being_integrated_by = country: the species' subspecies integration (not in the save as such):
-- no
trig.is_being_integrated_by = function(e, ctx)
    return false
end

-- is_same_species = <scope>: this and that scope's species are the same
trig.is_same_species = function(e, ctx)
    local a = species_of(ctx.this)
    if not e.value.text or not a then return false end
    local ok, sc = eval.resolve(e.value.text, ctx, e)
    local b = ok and sc and species_of(sc)
    return b ~= nil and a == b
end

-- custom_tooltip = { fail_text = x success_text = y <triggers> }: the triggers (a bare text: only a
-- tooltip, true)
local TOOLTIP_KEYS = { fail_text = true, success_text = true, text = true }
trig.custom_tooltip = function(e, ctx)
    if e.value.text then return true end
    return eval.trigger(e.value, ctx, TOOLTIP_KEYS)
end

-- owner_main_species: the country's founder species
local links = {}
links.owner_main_species = function(cur, ctx)
    local c = cur
    if cur.kind ~= "country" then
        local o = eval.LINKS.owner and eval.LINKS.owner(cur, ctx)
        c = o
    end
    local s = c and c.kind == "country" and tonumber(world.field(world.object("country", c.id), "founder_species_ref"))
    return s and S("species", s) or nil
end

local TRIG, LINKS = eval.TRIG, eval.LINKS
script.orig, script.orig_links = {}, {}
local installed = 0

-- script.with(f, ...) -> f's results, with the economy's and these triggers in place
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
        for k, g in pairs(links) do
            script.orig_links[k] = LINKS[k]
            LINKS[k] = function(...) count("link " .. k) return g(...) end
        end
        local res = { pcall(f, ...) }
        for k in pairs(trig) do TRIG[k] = script.orig[k] end
        for k in pairs(links) do LINKS[k] = script.orig_links[k] end
        installed = installed - 1
        if not res[1] then
            error(res[2], 0)
        end
        return unpack(res, 2)
    end
    local ok, es = pcall(require, "engine.economy.script")
    if ok and es and es.with then
        return es.with(inner, ...)
    end
    return inner(...)
end

return script
