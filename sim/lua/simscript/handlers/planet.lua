-- simscript/handlers/planet.lua : planets, colonies, pop groups, districts, buildings, zones,
-- deposits, jobs and decisions (the planet package of docs/script_coverage.md). Each keyword
-- follows the game's documentation (script_documentation: triggers.log, effects.log, scopes.log)
-- and the trigger or effect class's code in the 4.5.2 Linux binary; [V] read in the code, [I]
-- inferred. The world is read and written through engine.world (planet ids for planet scopes; a
-- colony is its planet's `colony`), the planet engine effects are applied by
-- engine/script/planet.lua.

return function(eval)
    local I = eval._internal
    local TRIG, EFF, LINKS, LISTS, AMOUNTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS, I.AMOUNTS
    local S, NONE, sync, compare, miss, yes = I.S, I.NONE, I.sync, I.compare, I.miss, I.yes
    local world = require("engine.world")
    local NO_ID = 4294967295

    local function unq(v)
        return v and (tostring(v):gsub('"', "")) or nil
    end
    local function ref(v)
        local n = tonumber(v)
        return (n and n ~= NO_ID) and n or nil
    end
    local function ids(list)
        local out = {}
        for _, v in ipairs(world.list(list)) do
            local n = ref(v)
            if n then out[#out + 1] = n end
        end
        return out
    end
    local function scopes(kind, list)
        local out = {}
        for i, id in ipairs(list) do out[i] = S(kind, id) end
        return out
    end
    -- a colony's planet and a planet's colony (engine.world's indexes)
    local function planet_of_colony(cid)
        return cid and world.colony_planet and world.colony_planet[cid] or nil
    end
    local function colony_of_planet(pid)
        return pid and world.planet_colony and world.planet_colony[pid] or nil
    end
    -- the planet a scope is or stands for (a planet, a colony given as its planet)
    local function planet_id(sc)
        if sc == nil or sc == NONE then return nil end
        if sc.kind == "planet" then return sc.id end
        return nil
    end
    local function planet_obj(sc)
        local p = planet_id(sc)
        return p and world.object("planet", p) or nil, p
    end
    local function colony_obj(sc)
        local p = planet_id(sc)
        local c = colony_of_planet(p)
        return c and world.object("colony", c) or nil, c, p
    end
    I.planet_helpers = { planet_of_colony = planet_of_colony, colony_of_planet = colony_of_planet }

    -- the scope `<trigger> = <target>` names (nil when none)
    local function target(e, ctx)
        if not e.value.text then return nil end
        local found, sc = eval.resolve(e.value.text, ctx, e)
        return (found and sc and sc ~= NONE) and sc or nil
    end
    -- a block's `key = value` statements: { key = entry }
    local function params(e)
        local p = {}
        for _, x in ipairs(type(e.value) == "table" and e.value.text == nil and e.value or {}) do
            if x.op and x.key then p[x.key.text:lower()] = x end
        end
        return p
    end
    local function num_value(x, ctx)
        return x and eval.value(x.value, ctx, x) or nil
    end

    -- -----------------------------------------------------------------------------------------
    -- lists (the any_ / count_ / every_ / random_ / ordered_ iterators)

    -- the colonies of a country's list (`owned_planets`, `controlled_colonies`: colony ids) as
    -- their planets
    local function colony_list(country, key)
        local out = {}
        for _, c in ipairs(ids(world.field(world.object("country", country), key))) do
            out[#out + 1] = planet_of_colony(c)
        end
        return out
    end
    -- the colonies of a sector (its systems' colonies of the sector's owner) [I]
    local function sector_colonies(sid)
        local s = world.object("sectors", sid)
        local owner = s and ref(world.field(s, "owner"))
        local out = {}
        if not s then return out end
        local E = I.E
        for _, sys in ipairs(ids(world.field(s, "systems"))) do
            for _, pid in ipairs(E.system_planets and E.system_planets(sys) or {}) do
                local c = colony_of_planet(pid)
                local p = world.object("planet", pid)
                if c and p and ref(world.field(p, "owner")) == owner then out[#out + 1] = pid end
            end
        end
        return out
    end
    -- the colonies (as planets) under a scope: a planet's own; a country's owned; a system's; a
    -- sector's
    local function colonies_under(sc)
        if sc.kind == "planet" then
            return colony_of_planet(sc.id) and { sc.id } or {}
        elseif sc.kind == "country" then
            return colony_list(sc.id, "owned_planets")
        elseif sc.kind == "system" then
            local out = {}
            for _, pid in ipairs(I.E.system_planets and I.E.system_planets(sc.id) or {}) do
                if colony_of_planet(pid) then out[#out + 1] = pid end
            end
            return out
        elseif sc.kind == "sector" then
            return sector_colonies(sc.id)
        end
        return {}
    end

    -- controlled_colony / controlled_planet (CControlledColonyList, CControlledPlanetList): a
    -- country's `controlled_colonies` (colony ids) and `controlled_planets` (planet ids)
    LISTS.controlled_colony = function(sc)
        if sc.kind ~= "country" then return {} end
        sync()
        return scopes("planet", colony_list(sc.id, "controlled_colonies"))
    end
    LISTS.controlled_planet = function(sc)
        if sc.kind ~= "country" then return {} end
        sync()
        return scopes("planet", ids(world.field(world.object("country", sc.id), "controlled_planets")))
    end
    -- galaxy_planet: every planet of the game
    LISTS.galaxy_planet = function()
        sync()
        return scopes("planet", world.all("planet"))
    end
    -- owned_colony: a country's colonies, a sector's
    LISTS.owned_colony = function(sc)
        sync()
        if sc.kind == "country" then return scopes("planet", colony_list(sc.id, "owned_planets")) end
        if sc.kind == "sector" then return scopes("planet", sector_colonies(sc.id)) end
        return {}
    end
    -- owned_pop_group: the pop groups of the colonies under the scope (a planet, a country, a
    -- system, a sector; a pop faction's members [I] not modelled: none)
    LISTS.owned_pop_group = function(sc)
        sync()
        local out = {}
        for _, pid in ipairs(colonies_under(sc)) do
            for _, g in ipairs(I.E.pop_groups(pid)) do out[#out + 1] = S("pop_group", g) end
        end
        return out
    end
    LISTS.pop_group = LISTS.owned_pop_group
    -- owned_pop_job: the colonies' pop jobs (a colony's `pop_jobs`)
    LISTS.owned_pop_job = function(sc)
        sync()
        local out = {}
        for _, pid in ipairs(colonies_under(sc)) do
            local c = world.object("colony", colony_of_planet(pid))
            for _, j in ipairs(ids(c and world.field(c, "pop_jobs"))) do out[#out + 1] = S("job", j) end
        end
        return out
    end
    -- job_pop_group: the pop groups working a job (its `pop_groups = { { pop_group amount } }`)
    LISTS.job_pop_group = function(sc)
        if sc.kind ~= "job" then return {} end
        sync()
        local j = world.object("pop_jobs", sc.id)
        local out = {}
        for _, b in ipairs(world.blocks(j and world.field(j, "pop_groups"))) do
            local g = ref(world.field(b, "pop_group"))
            if g then out[#out + 1] = S("pop_group", g) end
        end
        return out
    end
    -- species_pop_group: every pop group of the species (key.species)
    LISTS.species_pop_group = function(sc)
        if sc.kind ~= "species" then return {} end
        sync()
        local out = {}
        for _, g in ipairs(world.all("pop_groups")) do
            local o = world.object("pop_groups", g)
            if o and tonumber(world.path(o, "key", "species")) == sc.id then out[#out + 1] = S("pop_group", g) end
        end
        return out
    end
    -- count_owned_workforce: the workforce of the owned pop jobs (CCountOwnedWorkforce [I]: the
    -- jobs' `workforce`)
    AMOUNTS.owned_workforce = {
        list = "owned_pop_job",
        weight = function(s)
            sync()
            local j = world.object("pop_jobs", s.id)
            return j and tonumber(world.field(j, "workforce")) or 0
        end,
    }

    -- (their every_ / random_ / ordered_ effects: eval's iterators, with random_'s `weights` and
    -- ordered_'s `inverse`)
    local SKIP = {}
    for k in pairs(I.ITER_PARAMS) do SKIP[k] = true end

    -- weighted_random_owned_pop_group = { limit effects } (CWeightedRandomOwnedPopGroupEffect [I]):
    -- one owned pop group, each weighted by its size
    EFF["weighted_random_owned_pop_group"] = function(e, ctx)
        if e.value.text ~= nil then return end
        local list = LISTS.owned_pop_group(ctx.this)
        local p = params(e)
        local chosen, w, total = {}, {}, 0
        for _, s2 in ipairs(list) do
            if not p.limit or eval.trigger(p.limit.value, eval.push(ctx, s2)) then
                local g = world.object("pop_groups", s2.id)
                local size = g and tonumber(world.field(g, "size")) or 0
                if size > 0 then
                    chosen[#chosen + 1], w[#w + 1], total = s2, size, total + size
                end
            end
        end
        if total <= 0 then return end
        local SR = eval.scope_iter
        local loop = SR and SR.begin(ctx)
        local r = (loop and SR.draw(loop) or I.E.rand()) % total
        local pick
        for i, x in ipairs(w) do
            if r < x then pick = i break end
            r = r - x
        end
        local c = eval.push(ctx, chosen[pick or #chosen])
        if loop then SR.element(loop, c, "random") end
        eval.effect(e.value, c, SKIP)
    end

    -- owned_planet_list_tooltip = { limit } (a tooltip only: the matching colonies listed; no
    -- effect on the game) [I]
    EFF["owned_planet_list_tooltip"] = function() end

    -- -----------------------------------------------------------------------------------------
    -- scope links

    -- capital_scope: a country's capital colony (`capital`, a colony id) as its planet
    LINKS.capital_scope = function(cur)
        if cur.kind ~= "country" then return nil end
        sync()
        local p = planet_of_colony(ref(world.field(world.object("country", cur.id), "capital")))
        return p and S("planet", p) or nil
    end
    -- capital_star: the primary star of the capital's system (its system's star: the planet at the
    -- system's center, `star`) [I]
    LINKS.capital_star = function(cur)
        local cap = LINKS.capital_scope(cur)
        if not cap then return nil end
        local R = require("engine.script.runtime")
        local sys = R.system_of and R.system_of("planet", cap.id)
        local star = sys and R.star_planet and R.star_planet(sys)
        return star and S("planet", star) or nil
    end
    -- planet: the planet an object is on: a planet; a pop group's, a job's, an army's (`colony` /
    -- `planet`), a deposit's holder, a leader's location, a starbase's or megastructure's `planet`
    local function planet_field(kind, store, key)
        local o = world.object(store, kind)
        return o and ref(world.field(o, key))
    end
    LINKS.planet = function(cur)
        if cur == NONE then return nil end
        sync()
        local k, id = cur.kind, cur.id
        local pid
        if k == "planet" then
            return cur
        elseif k == "pop_group" then
            local g = world.object("pop_groups", id)
            pid = planet_of_colony(ref(g and world.field(g, "planet")))
        elseif k == "job" then
            local j = world.object("pop_jobs", id)
            pid = planet_of_colony(ref(j and world.field(j, "planet")))
        elseif k == "army" then
            local a = world.object("army", id)
            pid = planet_of_colony(ref(a and world.field(a, "colony")))
        elseif k == "deposit" then
            local d = world.object("deposit", id)
            local h = d and world.field(d, "deposit_holder")
            if h and tonumber(world.field(h, "type")) == 0 then pid = ref(world.field(h, "id")) end
        elseif k == "leader" then
            local l = world.object("leader", id)
            local loc = l and world.field(l, "location")
            if type(loc) == "table" and unq(world.field(loc, "type")) == "planet" then
                pid = planet_of_colony(ref(world.field(loc, "id")))
            end
        elseif k == "starbase" then
            local sb = world.object("starbases", id)
            pid = ref(sb and world.field(sb, "planet"))
        elseif k == "megastructure" then
            local m = world.object("megastructures", id)
            pid = ref(m and world.field(m, "planet"))
        elseif k == "site" or k == "archaeological_site" then
            local s = world.object("sites", id)
            local loc = s and world.field(s, "location")
            if type(loc) == "table" then pid = ref(world.field(loc, "id")) end
        end
        return pid and S("planet", pid) or nil
    end
    -- planet_owner: the owner of the planet an object is on
    LINKS.planet_owner = function(cur)
        local p = LINKS.planet(cur)
        if not p then return nil end
        local o = world.object("planet", p.id)
        local c = ref(o and world.field(o, "owner"))
        return c and S("country", c) or nil
    end
    -- the planet of a `{ type = planet reference = id }` block (a leader's background, a
    -- species' home)
    local function carrier_ref(b)
        if type(b) ~= "table" then return nil end
        if unq(world.field(b, "type")) ~= "planet" then return nil end
        return ref(world.field(b, "reference"))
    end
    -- background_planet / background_colony: a leader's `background_planet`
    LINKS.background_planet = function(cur)
        if cur.kind ~= "leader" then return nil end
        sync()
        local p = carrier_ref(world.field(world.object("leader", cur.id), "background_planet"))
        return p and world.object("planet", p) and S("planet", p) or nil
    end
    LINKS.background_colony = function(cur)
        local p = LINKS.background_planet(cur)
        return p and colony_of_planet(p.id) and p or nil
    end
    -- home_planet / home_colony: a species' `home_planet` (a pop group's, a leader's: their
    -- species'; a country's: its founder species') [I]
    LINKS.home_planet = function(cur)
        sync()
        local sp
        if cur.kind == "species" then
            sp = cur.id
        elseif I.E.species_of then
            sp = I.E.species_of(cur.kind, cur.id)
        end
        local s = sp and world.object("species", sp)
        local p = s and carrier_ref(world.field(s, "home_planet"))
        return p and world.object("planet", p) and S("planet", p) or nil
    end
    LINKS.home_colony = function(cur)
        local p = LINKS.home_planet(cur)
        return p and colony_of_planet(p.id) and p or nil
    end
    -- branch_office_owner: the planet's branch office's owner (E.branch_office_owner)
    LINKS.branch_office_owner = function(cur)
        if cur.kind ~= "planet" or not I.E.branch_office_owner then return nil end
        sync()
        local c = I.E.branch_office_owner("planet", cur.id)
        return c and S("country", c) or nil
    end
    -- observation_outpost / observation_outpost_owner: the observation station's fleet in orbit
    -- of the planet (a planet keeps its stations by class: `shipclass_<class> = <fleet>`, as
    -- shipclass_orbital_station; the observation post's class shipclass_observation_station [I])
    local function outpost_of(pid)
        local p = world.object("planet", pid)
        local f = p and ref(world.field(p, "shipclass_observation_station"))
        return f and world.object("fleet", f) and f or nil
    end
    LINKS.observation_outpost = function(cur)
        if cur.kind ~= "planet" then return nil end
        sync()
        local f = outpost_of(cur.id)
        return f and S("fleet", f) or nil
    end
    LINKS.observation_outpost_owner = function(cur)
        if cur.kind ~= "planet" then return nil end
        sync()
        local f = outpost_of(cur.id)
        local fl = f and world.object("fleet", f)
        local c = ref(fl and world.field(fl, "owner"))
        return c and S("country", c) or nil
    end
    -- last_added_deposit: the planet's last deposit (its `deposits` list's last) [I]
    LINKS.last_added_deposit = function(cur)
        if cur.kind ~= "planet" then return nil end
        sync()
        local l = ids(world.field(world.object("planet", cur.id), "deposits"))
        return l[#l] and S("deposit", l[#l]) or nil
    end
    -- spawner_planet: an army's spawning colony (`spawning_colony`) as its planet
    LINKS.spawner_planet = function(cur)
        if cur.kind ~= "army" then return nil end
        sync()
        local a = world.object("army", cur.id)
        local p = planet_of_colony(ref(a and world.field(a, "spawning_colony")))
        return p and S("planet", p) or nil
    end

    -- the triggers and effects (handlers/planet_triggers.lua, planet_effects.lua)
    local H = { target = target, params = params, num_value = num_value, ids = ids, ref = ref, unq = unq,
        planet_obj = planet_obj, colony_obj = colony_obj, planet_id = planet_id, colonies_under = colonies_under,
        planet_of_colony = planet_of_colony, colony_of_planet = colony_of_planet, carrier_ref = carrier_ref,
        world = world, NO_ID = NO_ID }
    for _, part in ipairs({ "planet_triggers", "planet_effects" }) do
        local ok, mod = pcall(require, "simscript.handlers." .. part)
        if ok then
            mod(eval, H)
        elseif not tostring(mod):find("module 'simscript.handlers." .. part .. "' not found", 1, true) then
            error(mod, 0)
        end
    end
end
