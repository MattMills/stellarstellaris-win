-- simscript/handlers/empire.lua : the empire's script keywords: species and their traits, leaders,
-- the council and its agendas, policies and edicts, ethics, civics and the government, pop
-- factions and pop groups (docs/script_empire.md has each keyword's class in the 4.5.2 Linux build,
-- its semantics there and what is approximated). The world is read and written through
-- engine.world; the game's definitions through engine.defs.
--
-- Numeric triggers are also values (`value = trigger:<name>`): eval.TVAL[name](ctx).

return function(eval)
    local I = eval._internal
    local S, NONE, compare, push, yes, sync = I.S, I.NONE, I.compare, I.push, I.yes, I.sync
    local TRIG, EFF, LINKS, LISTS, TVAL = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS, eval.TVAL
    local E = I.E
    local world = require("engine.world")
    local floor = math.floor

    -- ------------------------------------------------------------------------------------------
    -- helpers

    local function unq(v)
        return type(v) == "string" and (v:gsub('"', "")) or v
    end
    local function obj(kind, id)
        if kind == nil or id == nil then return nil end
        return world.object(kind, id)
    end
    local function field(o, k)
        return o and world.field(o, k)
    end
    local function num(v)
        return tonumber(v) or 0
    end
    local function defs()
        return require("engine.defs")
    end
    -- a definition's block (engine.defs), and its file
    local function def(dir, key)
        if not key then return nil end
        local d = defs().get(dir, key)
        return d and d.block, d and d.file
    end
    local function dfield(block, key)
        return block and defs().field(block, key)
    end
    -- the tokens of a list block (`tags = { a b }`)
    local function tokens(block)
        local out = {}
        if type(block) ~= "table" then return out end
        for _, x in ipairs(block) do
            if x.text then out[#out + 1] = unq(x.text) end
        end
        return out
    end
    local function set_of(list)
        local s = {}
        for _, k in ipairs(list) do s[k] = true end
        return s
    end
    -- a block trigger's or effect's parameters: { [key] = statement } (the first of each), keys
    -- lowercased
    local function params(e)
        local t = {}
        if e.value.text then return t end
        for _, x in ipairs(e.value) do
            if x.op and x.key then
                local k = x.key.text:lower()
                if t[k] == nil then t[k] = x end
            end
        end
        return t
    end
    local function text_of(x)
        return x and x.value.text and unq(x.value.text) or nil
    end
    -- the scope a statement's text names (`who = root`), or nil
    local function target(x, ctx)
        if not x or not x.value.text then return nil end
        local found, sc = eval.resolve(x.value.text, ctx, x)
        if found and sc and sc ~= NONE then return sc end
        return nil
    end
    -- `<trigger> <op> <value>`, or `<trigger> = { value <op> n }`
    local function compare_value(v, e, ctx)
        if v == nil then return false end
        if e.value.text then
            return compare(v, e.op, eval.value(e.value, ctx, e))
        end
        local p = params(e)
        local x = p.value
        if not x then return false end
        return compare(v, x.op, eval.value(x.value, ctx, x))
    end
    -- a numeric trigger on some scope kinds; also a value (trigger:<name>): value(sc, ctx, e) ->
    -- number or nil (nil: the comparison false, the value 0)
    local function numeric(name, kinds, value)
        local ok = kinds and set_of(kinds)
        TRIG[name] = function(e, ctx)
            local sc = ctx.this
            if ok and not ok[sc.kind] then return false end
            sync()
            return compare_value(value(sc, ctx, e), e, ctx)
        end
        TVAL[name] = function(ctx, e)
            local sc = ctx.this
            if ok and not ok[sc.kind] then return 0 end
            sync()
            return value(sc, ctx, e) or 0
        end
    end
    -- a yes/no trigger: f(sc, ctx, e) -> bool or nil (nil: false for both yes and no)
    local function boolean(name, kinds, f)
        local ok = kinds and set_of(kinds)
        TRIG[name] = function(e, ctx)
            local sc = ctx.this
            if ok and not ok[sc.kind] then return false end
            sync()
            local r = f(sc, ctx, e)
            if r == nil then return false end
            return r == yes(e)
        end
    end
    local function today()
        return eval.today()
    end
    -- days since 1.1.1 of a "y.m.d" date (360-day years)
    local function days_of(d)
        local y, m, dd = tostring(d or ""):gsub('"', ""):match("^(-?%d+)%.(%d+)%.(%d+)")
        if not y then return nil end
        return (tonumber(y) * 12 + tonumber(m) - 1) * 30 + tonumber(dd) - 1
    end
    local function now_days()
        return days_of(tostring(world.meta.date or "")) or 0
    end
    local function country_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "country" then return sc.id end
        -- (a leader's country, a pop group's planet's owner)
        if sc.kind == "leader" then
            local l = world.object("leader", sc.id)
            local c = l and tonumber(world.field(l, "country"))
            if c then return c end
        elseif sc.kind == "pop_group" then
            local g = world.object("pop_groups", sc.id)
            local p = g and tonumber(world.field(g, "planet"))
            if p and E.owner_of then return E.owner_of("planet", p) end
        end
        if E and E.owner_of then
            local o = E.owner_of(sc.kind, sc.id)
            if o then return o end
        end
        return nil
    end
    local function country(sc)
        local id = country_of(sc)
        return id and obj("country", id), id
    end
    local function gov(c)
        return field(c, "government")
    end
    -- the colony of a planet scope (world.planet_colony), and the planet of a colony
    local function colony_of_planet(pid)
        return world.planet_colony and world.planet_colony[pid] or nil
    end
    -- the pop groups of a scope: a pop group; a planet's; a country's (its planets'); a pop faction's
    local function pop_groups(sc)
        local out = {}
        if sc.kind == "pop_group" then
            out[1] = sc.id
        elseif sc.kind == "planet" then
            for _, g in ipairs(world.pop_groups_of[sc.id] or {}) do out[#out + 1] = g end
        elseif sc.kind == "country" then
            for _, p in ipairs(E.colonies(sc.id)) do
                for _, g in ipairs(world.pop_groups_of[p] or {}) do out[#out + 1] = g end
            end
        elseif sc.kind == "pop_faction" then
            local f = obj("pop_factions", sc.id)
            for _, g in ipairs(world.list(field(f, "pop_groups"))) do out[#out + 1] = tonumber(g) end
        elseif sc.kind == "sector" then
            local s = obj("sector", sc.id)
            local systems = set_of(world.list(field(s, "systems")))
            local c = obj("country", tonumber(field(s, "owner")))
            for _, p in ipairs(c and E.colonies(tonumber(field(s, "owner"))) or {}) do
                local pl = obj("planet", p)
                local coord = field(pl, "coordinate")
                if coord and systems[tostring(field(coord, "origin"))] then
                    for _, g in ipairs(world.pop_groups_of[p] or {}) do out[#out + 1] = g end
                end
            end
        end
        return out
    end
    local function group(id)
        return obj("pop_groups", id)
    end
    local function group_size(g)
        return num(field(group(g), "size"))
    end
    local function group_species(g)
        local key = field(group(g), "key")
        return type(key) == "table" and tonumber(field(key, "species")) or nil
    end
    local function group_category(g)
        local key = field(group(g), "key")
        return type(key) == "table" and unq(field(key, "category")) or nil
    end
    -- a pop group's planet and owner
    local function group_planet(g)
        return tonumber(field(group(g), "planet"))
    end
    local function group_owner(g)
        local p = group_planet(g)
        return p and E.owner_of and E.owner_of("planet", p) or nil
    end
    -- the species of a scope (E.species_of: a pop group's, a leader's, an army's, a country's
    -- founder species, a species itself)
    local function species_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "species" then return sc.id end
        return E.species_of and E.species_of(sc.kind, sc.id) or nil
    end
    local function species(id)
        return obj("species", id)
    end
    local function base_of(sid)
        local s = species(sid)
        return s and (tonumber(field(s, "base_ref")) or sid) or nil
    end
    local function species_traits(sid)
        local out = {}
        for _, t in ipairs(world.fields(field(species(sid), "traits"), "trait") or {}) do
            out[#out + 1] = unq(type(t) == "table" and t.text or t)
        end
        return out
    end
    local function class_archetype(class)
        local b = def("common/species_classes", class)
        return unq(dfield(b, "archetype")) or "BIOLOGICAL"
    end
    local function archetype_of(sid)
        return class_archetype(unq(field(species(sid), "class")))
    end
    local function robotic_archetype(a)
        local b = def("common/species_archetypes", a)
        return b ~= nil and dfield(b, "robotic") == "yes"
    end
    -- a trait's definition, its cost (a number; a scripted cost evaluated in the country's scope)
    local function trait_def(key)
        return def("common/traits", key)
    end
    local function trait_cost(key, cid)
        local b, file = trait_def(key)
        local v = dfield(b, "cost")
        if tonumber(v) then return tonumber(v) end
        if type(v) == "table" and cid then
            local ok, r = pcall(eval.value, v, eval.new_ctx(S("country", cid), nil, nil, file), nil)
            if ok and tonumber(r) then return tonumber(r) end
        end
        return 0
    end
    local function is_leader_trait(b)
        return b ~= nil and dfield(b, "leader_class") ~= nil
    end
    -- the country's leaders (owned_leaders) and its recruitable ones (the leader module's pool)
    local function owned_leaders(c)
        local out = {}
        for _, k in ipairs(world.list(field(c, "owned_leaders"))) do out[#out + 1] = tonumber(k) end
        return out
    end
    local function pool_leaders(c)
        local out = {}
        for _, k in ipairs(world.list(world.path(c, "modules", "standard_leader_module", "leaders"))) do
            out[#out + 1] = tonumber(k)
        end
        return out
    end
    local function leader(id)
        return obj("leader", id)
    end
    local function leader_traits(l)
        local out = {}
        for _, t in ipairs(world.fields(l, "traits") or {}) do
            out[#out + 1] = unq(type(t) == "table" and t.text or t)
        end
        return out
    end
    -- the species rights entry of a species in a country (standard_species_rights_module: the
    -- species' own entry, the primary's, else the default)
    local function rights_entry(cid, sid)
        local c = obj("country", cid)
        local m = world.path(c, "modules", "standard_species_rights_module")
        if type(m) ~= "table" then return nil, false end
        local primary = field(m, "primary")
        if type(primary) == "table" and tonumber(field(primary, "species_index")) == sid then return primary, true end
        for _, b in ipairs(world.blocks(field(m, "species_rights"))) do
            if tonumber(field(b, "species_index")) == sid then return b, true end
        end
        return field(m, "default"), false
    end
    -- the ethics of a country (ethos.ethics) and of a pop group (ethos.ethics with their pops)
    local function country_ethics(c)
        local out = {}
        for _, v in ipairs(world.list(world.path(c, "ethos", "ethics"))) do out[#out + 1] = unq(v) end
        return out
    end
    local function group_ethics(g)
        local o = group(g)
        local names = world.list(world.path(o, "ethos", "ethics"))
        local pops = world.list(world.path(o, "ethos", "pops"))
        local out = {}
        for i, n in ipairs(names) do out[#out + 1] = { unq(n), tonumber(pops[i]) or 0 } end
        return out
    end
    local function councils(c)
        local out = {}
        for _, k in ipairs(world.list(field(gov(c), "council_positions"))) do
            local p = obj("council_positions", tonumber(k))
            if p then out[#out + 1] = p end
        end
        return out
    end

    -- ------------------------------------------------------------------------------------------
    -- lists (iterators: any_ / every_ / random_ / ordered_ / count_)

    local function scopes(kind, ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = S(kind, id) end
        return out
    end
    -- the species traits (common/traits without leader_class), in the database's order [I: by key]
    local species_trait_keys
    local function all_species_traits()
        if not species_trait_keys then
            species_trait_keys = {}
            for k, d in pairs(defs().folder("common/traits")) do
                if not is_leader_trait(d.block) then species_trait_keys[#species_trait_keys + 1] = k end
            end
            table.sort(species_trait_keys)
        end
        return species_trait_keys
    end
    -- existing_species_traits (no scope): every species trait
    LISTS["existing_species_traits"] = function()
        return scopes("trait", all_species_traits())
    end
    -- owned_pop_species: the species of the country's pop groups, each once (exact species)
    LISTS["owned_pop_species"] = function(sc)
        if sc.kind ~= "country" then return {} end
        sync()
        local out, seen = {}, {}
        for _, g in ipairs(pop_groups(sc)) do
            local s = group_species(g)
            if s and not seen[s] and group_size(g) > 0 then
                seen[s] = true
                out[#out + 1] = S("species", s)
            end
        end
        return out
    end
    -- pool_leader: the country's recruitable leaders
    LISTS["pool_leader"] = function(sc)
        if sc.kind ~= "country" then return {} end
        sync()
        return scopes("leader", pool_leaders(obj("country", sc.id)))
    end
    -- trait_of_species: the scope's species' traits
    LISTS["trait_of_species"] = function(sc)
        local sid = species_of(sc)
        if not sid then return {} end
        sync()
        return scopes("trait", species_traits(sid))
    end
    -- trait_available_for_species: the species traits the species has not, allowed for its
    -- archetype (allowed_archetypes) [I: the DLC lock not read]
    LISTS["trait_available_for_species"] = function(sc)
        local sid = species_of(sc)
        if not sid then return {} end
        sync()
        local have = set_of(species_traits(sid))
        local arch = archetype_of(sid)
        local out = {}
        for _, k in ipairs(all_species_traits()) do
            if not have[k] then
                local b = trait_def(k)
                local allowed = tokens(dfield(b, "allowed_archetypes"))
                if #allowed == 0 or set_of(allowed)[arch] then out[#out + 1] = S("trait", k) end
            end
        end
        return out
    end
    -- the species on a planet / in a country's or fleet's pops: exact (each sub-species) or by base
    local function scope_species(sc, by_base)
        local out, seen = {}, {}
        local groups
        if sc.kind == "ship" or sc.kind == "fleet" then
            groups = {}
        else
            groups = pop_groups(sc)
        end
        for _, g in ipairs(groups) do
            local s = group_species(g)
            if s and group_size(g) > 0 then
                local k = by_base and base_of(s) or s
                if k and not seen[k] then
                    seen[k] = true
                    out[#out + 1] = S("species", k)
                end
            end
        end
        return out
    end
    LISTS["exact_species"] = function(sc) sync() return scope_species(sc, false) end
    LISTS["species"] = function(sc) sync() return scope_species(sc, true) end

    -- ------------------------------------------------------------------------------------------
    -- scope links

    -- a country's (or the object's owner's) heir: the government's heir [I: government.heir]
    LINKS["heir"] = function(cur)
        local c = country(cur)
        local h = tonumber(field(gov(c), "heir")) or tonumber(field(c, "heir"))
        return h and leader(h) and S("leader", h) or nil
    end
    -- built_species: a country's built_species_ref
    LINKS["built_species"] = function(cur)
        if cur.kind ~= "country" then return nil end
        local s = tonumber(field(obj("country", cur.id), "built_species_ref"))
        return s and species(s) and S("species", s) or nil
    end
    -- creator: a leader's country of origin (`creator`)
    LINKS["creator"] = function(cur)
        if cur.kind ~= "leader" then return nil end
        local c = tonumber(field(leader(cur.id), "creator"))
        return c and obj("country", c) and S("country", c) or nil
    end
    -- pop_faction: a pop group's faction (its `factions`' first), a leader's (the faction it
    -- leads), a faction itself
    LINKS["pop_faction"] = function(cur)
        if cur.kind == "pop_faction" then return cur end
        if cur.kind == "pop_group" then
            local f = world.list(field(group(cur.id), "factions"))[1]
            return f and S("pop_faction", tonumber(f)) or nil
        end
        if cur.kind == "leader" then
            for _, fid in ipairs(world.all("pop_factions")) do
                if tonumber(field(obj("pop_factions", fid), "leader")) == cur.id then return S("pop_faction", fid) end
            end
        end
        return nil
    end
    -- the species growing, assembling, declining on a planet (the colony's growth: its pop
    -- groups' last month growth) [I: the colony's growth species fields not in the save]
    local function growth_species(cur, which)
        local pid = cur.kind == "planet" and cur.id or nil
        if not pid then return nil end
        local best, bv
        for _, g in ipairs(world.pop_groups_of[pid] or {}) do
            local s = group_species(g)
            local robo = s and robotic_archetype(archetype_of(s))
            local v = num(field(group(g), "last_month_growth"))
            local fits = (which == "growing" and v > 0 and not robo) or (which == "assembling" and v > 0 and robo)
                or (which == "declining" and v < 0)
            if fits and (bv == nil or math.abs(v) > bv) then best, bv = s, math.abs(v) end
        end
        return best and S("species", best) or nil
    end
    LINKS["growing_species"] = function(cur) sync() return growth_species(cur, "growing") end
    LINKS["assembling_species"] = function(cur) sync() return growth_species(cur, "assembling") end
    LINKS["declining_species"] = function(cur) sync() return growth_species(cur, "declining") end
    -- unhappiest_pop: the pop group of the scope with the lowest happiness
    LINKS["unhappiest_pop"] = function(cur)
        sync()
        local best, bv
        for _, g in ipairs(pop_groups(cur)) do
            local h = tonumber(field(group(g), "happiness"))
            if h and group_size(g) > 0 and (bv == nil or h < bv) then best, bv = g, h end
        end
        return best and S("pop_group", best) or nil
    end
    -- last_created_pop_faction: the faction a create_pop_faction made (its handle)
    I.CREATED_KIND.pop_faction = I.CREATED_KIND.pop_faction or "pop_faction"
    I.CREATED_KIND.species = I.CREATED_KIND.species or "species"

    local H = {
        I = I, S = S, E = E, NONE = NONE, world = world, unq = unq, obj = obj, field = field, num = num,
        def = def, dfield = dfield, tokens = tokens, set_of = set_of, params = params, text_of = text_of,
        target = target, compare_value = compare_value, numeric = numeric, boolean = boolean,
        days_of = days_of, now_days = now_days, country_of = country_of, country = country, gov = gov,
        pop_groups = pop_groups, group = group, group_size = group_size, group_species = group_species,
        group_category = group_category, group_owner = group_owner, group_planet = group_planet,
        species_of = species_of, species = species, base_of = base_of, species_traits = species_traits,
        archetype_of = archetype_of, class_archetype = class_archetype, robotic_archetype = robotic_archetype,
        trait_def = trait_def, trait_cost = trait_cost, is_leader_trait = is_leader_trait,
        owned_leaders = owned_leaders, pool_leaders = pool_leaders, leader = leader,
        leader_traits = leader_traits, rights_entry = rights_entry, country_ethics = country_ethics,
        group_ethics = group_ethics, councils = councils, scopes = scopes, all_species_traits = all_species_traits,
        scope_species = scope_species, colony_of_planet = colony_of_planet, now_days = now_days,
    }
    -- the triggers and the effects, in their own files
    require("simscript.handlers.empire_triggers")(eval, H)
    require("simscript.handlers.empire_effects")(eval, H)
end
