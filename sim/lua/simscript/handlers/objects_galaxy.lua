-- simscript/handlers/objects_galaxy.lua : create_species, create_country, create_colony, set_owner /
-- set_controller / set_capital of planets, prevent_anomaly, add_anomaly, set_planet_entity,
-- set_deposit, create_ambient_object (and set_location of one), spawn_megastructure,
-- spawn_natural_wormhole, link_wormholes; the links capital_star and colony
-- (engine/script/objects_countries.lua and objects_galaxy.lua apply them). Loaded by
-- handlers/objects.lua.

return function(eval, O)
    local I = eval._internal
    local EFF, LINKS = eval.EFF, eval.LINKS
    local E, sync, NONE, S = I.E, I.sync, I.NONE, I.S
    local params, text_of, target, push = O.params, O.text_of, O.target, O.push
    local objects = require("engine.script.objects")
    local unq = objects.unq
    local world = require("engine.world")
    local SR = require("engine.script.scope_random")
    local R = require("engine.script.runtime")
    local FP = 100000

    -- the scope random's GetFixedPoint (CNoiseRandom::GetFixedPoint 0x4235ab0: GetInt64 % 100000,
    -- two positions) as a fraction, and GetInteger
    local function fp(ctx)
        return SR.int64_mod(eval.scope_rng(ctx), FP) / FP
    end
    local function int(ctx)
        return eval.scope_draw(ctx)
    end
    -- a scope made from one draw (of the scope random, or of the game's generator), this = sc
    local function child(ctx, sc, seed)
        local c2 = I.push(ctx, sc)
        eval.seed_scope(c2, seed)
        return c2
    end
    local function run(block, c2)
        if block and block.value.text == nil and #block.value > 0 then eval.effect(block.value, c2) end
    end
    local function nonempty(x)
        return x and x.value.text == nil and #x.value > 0
    end
    local function country_of(sc, ctx)
        if not sc or sc == NONE then return nil end
        if sc.kind == "country" then return sc.id end
        local f, owner = eval.resolve("owner", I.push(ctx, sc), nil)
        return f and owner and owner.kind == "country" and owner.id or nil
    end
    local function species_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "species" then return sc.id end
        if E.species_of then sync(); return E.species_of(sc.kind, sc.id) end
        return nil
    end
    local function list_of_names(x, key)
        local out = {}
        if x and x.value.text == nil then
            for _, y in ipairs(x.value) do
                if y.op and y.key and y.key.text:lower() == key and y.value.text then out[#out + 1] = unq(y.value.text) end
            end
        end
        return out
    end
    local function last(kind)
        return function(ctx, h) O.created(ctx, kind, h) end
    end

    -- ------------------------------------------------------------------------------------------
    -- links

    -- capital_star: a country's capital's system's star
    LINKS["capital_star"] = function(cur)
        if cur.kind ~= "country" then return nil end
        sync()
        local cap = E.get("country", cur.id, "capital")
        local sys = cap and R.system_of("planet", cap)
        local star = sys and R.star_planet(sys)
        return star and S("planet", star) or nil
    end
    -- colony: a planet's colony (the simulation scopes a colony as its planet)
    if LINKS["colony"] == nil then
        LINKS["colony"] = function(cur)
            if cur.kind == "planet" then
                sync()
                return world.planet_colony[cur.id] and cur or nil
            end
            return nil
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- triggers the start script's galaxy events need

    -- starting_system = yes/no: the system is a country's starting system (`starting_system`)
    eval.TRIG["starting_system"] = function(e, ctx)
        local want = e.value.text ~= "no"
        if ctx.this.kind ~= "system" then return not want end
        sync()
        local is = false
        for _, cid in ipairs(world.all("country")) do
            if tonumber(world.field(world.object("country", cid), "starting_system")) == ctx.this.id then is = true break end
        end
        return is == want
    end

    -- distance in its hyperlane form (CDistanceTrigger::ActualEvaluate 0x3b635e0 ->
    -- CGalacticDistanceCache::GetDistance without a country): the shortest path over the hyperlanes,
    -- the lanes' `length` summed [I: the cache's metric]; min/max_distance compared as the euclidean
    -- form does; jumps and bypass_empire stay misses (the runtime module's handler)
    local dist_cache = { n = -1 }
    local function lane_distances(src)
        local nsys = #world.all("galactic_object")
        if dist_cache.n ~= nsys then dist_cache = { n = nsys } end
        local d = dist_cache[src]
        if d then return d end
        d = { [src] = 0 }
        local done = {}
        local frontier = { src }
        while #frontier > 0 do
            local bi, best = 1, frontier[1]
            for i, s in ipairs(frontier) do
                if d[s] < d[best] then bi, best = i, s end
            end
            table.remove(frontier, bi)
            if not done[best] then
                done[best] = true
                local g = world.object("galactic_object", best)
                local hl = world.field(g, "hyperlane")
                for _, h in ipairs(world.blocks(type(hl) == "table" and hl or nil)) do
                    if type(h) == "table" then
                        local to = tonumber(world.field(h, "to"))
                        local len = tonumber(world.field(h, "length")) or 0
                        if to and not done[to] then
                            local nd = d[best] + len
                            if d[to] == nil or nd < d[to] then
                                if d[to] == nil then frontier[#frontier + 1] = to end
                                d[to] = nd
                            end
                        end
                    end
                end
            end
        end
        dist_cache[src] = d
        return d
    end
    local prev_distance = eval.TRIG["distance"]
    eval.TRIG["distance"] = function(e, ctx)
        if e.value.text or ctx.this == NONE then return prev_distance and prev_distance(e, ctx) or false end
        local p = params(e)
        local euclid = p.type and p.type.value.text == "euclidean"
        if euclid or p.same_solar_system or p.min_jumps or p.max_jumps or p.bypass_empire or not p.source then
            return prev_distance and prev_distance(e, ctx) or false
        end
        local f, src = eval.resolve(p.source.value.text or "", ctx, p.source)
        if not f or not src or src == NONE then return false end
        sync()
        local a, b = R.system_of(ctx.this.kind, ctx.this.id), R.system_of(src.kind, src.id)
        if not a or not b then return false end
        local d = lane_distances(b)[a]
        if not d then return false end
        local function bound(x, ops)
            if not x then return true end
            local lim = eval.value(x.value, ctx, x)
            if lim == 0 then return true end
            if not ops[x.op] then return nil end
            return I.compare(d, x.op, lim)
        end
        return bound(p.min_distance, { [">"] = true, [">="] = true }) == true
            and bound(p.max_distance, { ["<"] = true, ["<="] = true }) == true
    end

    -- ------------------------------------------------------------------------------------------
    -- planets

    EFF["prevent_anomaly"] = function(e, ctx)
        if ctx.this.kind ~= "planet" or not e.value.text then return end
        push({ type = "prevent_anomaly", id = ctx.this.id, value = e.value.text == "yes" })
    end
    EFF["add_anomaly"] = function(e, ctx)
        if ctx.this.kind ~= "planet" then return end
        local p = params(e)
        local cat = text_of(p.category)
        if not cat then return end
        push({ type = "add_anomaly", id = ctx.this.id, category = cat })
    end
    EFF["set_planet_entity"] = function(e, ctx)
        if ctx.this.kind ~= "planet" then return end
        local p = params(e)
        push({ type = "set_planet_entity", id = ctx.this.id, entity = text_of(p.entity), picture = text_of(p.picture) })
    end
    EFF["set_deposit"] = function(e, ctx)
        local pid = ctx.this.kind == "planet" and ctx.this.id
        if not pid or not e.value.text then return end
        push({ type = "set_deposit", id = pid, deposit = unq(e.value.text) })
        sync()
    end

    -- ------------------------------------------------------------------------------------------
    -- species and countries

    -- create_species (CCreateSpecies::ExecuteActual 0x36e2b00)
    EFF["create_species"] = function(e, ctx)
        local p = params(e)
        local t = { type = "create_species", name = text_of(p.name), plural = text_of(p.plural),
            class = text_of(p.class), portrait = text_of(p.portrait), gender = text_of(p.gender),
            name_list = text_of(p.name_list) or text_of(p.namelist) }
        if t.class == "this" or (t.class and eval.resolve(t.class, ctx, p.class)) then
            local f, sc = eval.resolve(t.class == "this" and "this" or t.class, ctx, p.class)
            local sid = f and species_of(sc)
            local sp = sid and world.object("species_db", sid)
            t.class = sp and unq(world.field(sp, "class")) or nil
        end
        if t.class == "random_pre_ftl" then t.pre_ftl = true end
        if t.name_list == "random" or t.name_list == "random_class" then t.name_list = nil end
        local hw = target(p.homeworld, ctx)
        t.homeworld = hw and hw.kind == "planet" and hw.id or nil
        if p.traits then
            if p.traits.value.text then
                t.traits = { unq(p.traits.value.text) }
            else
                t.traits = list_of_names(p.traits, "trait")
            end
        end
        local h = E.new_handle()
        t.handle = h
        last("species")(ctx, h)
        push(t)
        sync()
        local sid = E.resolve(h)
        if sid and nonempty(p.effect) then
            run(p.effect, child(ctx, S("species", sid), int(ctx)))
        end
    end

    -- create_country (CCreateCountry::ExecuteActual 0x3700620): the country, then for a non-empty
    -- effect one scope draw making its scope, then always one more for on_country_created [V]
    EFF["create_country"] = function(e, ctx)
        local p = params(e)
        local t = { type = "create_country" }
        t.ctype = text_of(p.type) or "default"
        t.name = text_of(p.name)
        t.adjective = text_of(p.adjective)
        local sp = text_of(p.species)
        if sp == "last_created" then sp = "last_created_species" end
        if sp and sp ~= "random" then
            local f, sc = eval.resolve(sp, ctx, p.species)
            if f then t.species = species_of(sc)
            else
                for _, sid in ipairs(world.all("species_db")) do
                    local s = world.object("species_db", sid)
                    if unq(world.path(s, "name", "key") or "") == sp then t.species = sid end
                end
            end
        end
        if p.flag then
            if p.flag.value.text then t.flag = unq(p.flag.value.text) else t.flag = p.flag.value end
        end
        if p.ethos then
            if p.ethos.value.text == "random" then t.ethos = "random"
            else
                local found, sc = p.ethos.value.text and eval.resolve(p.ethos.value.text, ctx, p.ethos)
                if found and sc and sc.kind == "country" then
                    sync()
                    t.ethos = {}
                    for _, x in ipairs(world.list(world.path(world.object("country", sc.id), "ethos", "ethics"))) do t.ethos[#t.ethos + 1] = unq(x) end
                else
                    t.ethos = list_of_names(p.ethos, "ethic")
                end
            end
        end
        t.authority = text_of(p.authority)
        if p.civics then
            if p.civics.value.text then t.civics = { unq(p.civics.value.text) }
            else t.civics = list_of_names(p.civics, "civic") end
        end
        t.origin = text_of(p.origin)
        if p.default_ships then t.default_ships = O.yes_of(p.default_ships, true) end
        t.graphical_culture = text_of(p.graphical_culture)
        t.name_list = text_of(p.name_list)
        if t.name_list == "random" then t.name_list = nil end
        if ctx.this.kind == "planet" then t.planet = ctx.this.id end
        local h = E.new_handle()
        t.handle = h
        last("country")(ctx, h)
        push(t)
        sync()
        local cid = E.resolve(h)
        if not cid then return end
        if nonempty(p.effect) then
            run(p.effect, child(ctx, S("country", cid), int(ctx)))
        end
        local seed = int(ctx)
        local ok = pcall(function()
            require("simscript.events").on_action("on_country_created", S("country", cid), nil, SR.new(seed))
        end)
        if not ok then I.miss("effect", "on_country_created", ctx, e) end
    end

    -- create_colony = { owner = <country> species = <target> ethos = ... }
    EFF["create_colony"] = function(e, ctx)
        if ctx.this.kind ~= "planet" then return end
        local p = params(e)
        local owner = country_of(target(p.owner, ctx), ctx)
        if not owner then return end
        push({ type = "create_colony", kind = "planet", id = ctx.this.id, owner = owner })
        sync()
    end

    -- set_owner / set_controller of a planet; the fleet handler takes fleets first
    local prev_owner = EFF["set_owner"]
    EFF["set_owner"] = function(e, ctx, lk)
        if ctx.this.kind == "planet" or ctx.this.kind == "colony" then
            local c = country_of(target(e, ctx), ctx)
            if not c then return end
            push({ type = "set_planet_owner", kind = ctx.this.kind, id = ctx.this.id, country = c })
            sync()
            return
        end
        if prev_owner then return prev_owner(e, ctx, lk) end
    end
    EFF["set_controller"] = function(e, ctx)
        if ctx.this.kind ~= "planet" and ctx.this.kind ~= "colony" then return O.unmodelled("set_controller", ctx, e) end
        local c = country_of(target(e, ctx), ctx)
        if not c then return end
        push({ type = "set_planet_controller", kind = ctx.this.kind, id = ctx.this.id, country = c })
        sync()
    end
    EFF["set_capital"] = function(e, ctx)
        if e.value.text ~= "yes" then return end
        push({ type = "set_capital", kind = ctx.this.kind, id = ctx.this.id })
        sync()
    end

    -- ------------------------------------------------------------------------------------------
    -- ambient objects

    -- an interval `{ min = a max = b }` and CStatInterval::GetRandom(r): min + width * (|r| % 1000)
    -- / 1000 [V]
    local function interval(x, ctx)
        if not x or x.value.text then return nil end
        local lo, hi = 0, 0
        for _, y in ipairs(x.value) do
            if y.op and y.key then
                local k = y.key.text:lower()
                if k == "min" then lo = eval.value(y.value, ctx, y) or 0
                elseif k == "max" then hi = eval.value(y.value, ctx, y) or 0 end
            end
        end
        return { lo, hi }
    end
    local function rnd(iv, r)
        if not iv then return 0 end
        return iv[1] + (iv[2] - iv[1]) * (math.abs(r) % 1000) / 1000
    end

    -- create_ambient_object (0x37312c0): the place (a system: a random angle and a triangular radius
    -- within its inner_radius, six positions; a planet: its orbital slot 7, no draw; else the
    -- object's place), the entity offset (two draws when its max is above 0), the height (one draw,
    -- always), all from the scope random; an effect: one more draw making its scope [V]
    EFF["create_ambient_object"] = function(e, ctx)
        local p = params(e)
        local typ = text_of(p.type)
        if not typ then return end
        local L = p.location and target(p.location, ctx) or ctx.this
        if not L or L == NONE then return end
        sync()
        local x, y, origin = 0, 0, nil
        if L.kind == "system" then
            local a = fp(ctx) * 2 * math.pi
            local s = fp(ctx) + fp(ctx)
            if s > 1 then s = 2 - s end
            local g = world.object("galactic_object", L.id)
            local inner = tonumber(world.field(g, "inner_radius")) or 0
            x, y, origin = inner * s * math.cos(a), inner * s * math.sin(a), L.id
        elseif L.kind == "planet" then
            local pl = world.object("planet", L.id)
            local c = pl and world.field(pl, "coordinate")
            local px = c and tonumber(world.field(c, "x")) or 0
            local py = c and tonumber(world.field(c, "y")) or 0
            local size = pl and tonumber(world.field(pl, "planet_size")) or 0
            local d = math.max(0, (size - 10) * 0.33) + 10
            x, y, origin = px + d - 2, py + d + 2, R.system_of("planet", L.id)
        else
            x, y, origin = objects.galaxy.coord_of(world.KINDS[L.kind] and L.kind or L.kind, L.id)
            x, y = x or 0, y or 0
            origin = origin or R.system_of(L.kind, L.id)
        end
        local off = { x = 0, y = 0, z = 0 }
        local eo = interval(p.entity_offset, ctx)
        if eo and math.max(eo[1], eo[2]) > 0 then
            local deg = rnd(interval(p.entity_offset_angle, ctx), int(ctx))
            local a = math.rad(deg)
            local dist = rnd(eo, int(ctx))
            off.x, off.z = -math.sin(a) * dist, math.cos(a) * dist
        end
        off.y = rnd(interval(p.entity_offset_height, ctx), int(ctx))
        local attach
        if (O.yes_of(p.use_3d_location, false) and L.kind ~= "system") or O.yes_of(p.is_wreck, false) then
            if L.kind == "planet" then attach = { type = 2, id = L.id } end
        end
        local h = E.new_handle()
        last("ambient_object")(ctx, h)
        -- (`type` is the effect's, `data` the object's type)
        local q = { type = "create_ambient_object", x = x, y = y, origin = origin, offset = off, attach = attach,
            scale = p.scale and eval.value(p.scale.value, ctx, p.scale) or 1,
            entity_scale_to_size = O.yes_of(p.entity_scale_to_size, false), handle = h }
        q.data = typ
        I.stats.engine = I.stats.engine + 1
        E.push(q)
        sync()
        local aid = E.resolve(h)
        if aid and nonempty(p.effect) then
            run(p.effect, child(ctx, S("ambient_object", aid), int(ctx)))
        end
    end

    -- set_location of an ambient object (the fleet handler takes fleets)
    local prev_loc = EFF["set_location"]
    EFF["set_location"] = function(e, ctx, lk)
        if ctx.this.kind ~= "ambient_object" then
            if prev_loc then return prev_loc(e, ctx, lk) end
            return
        end
        local t = { type = "set_ambient_location", id = ctx.this.id }
        local tgt
        if e.value.text then
            tgt = target(e, ctx)
        else
            local p = params(e)
            tgt = target(p.target, ctx)
            if p.distance then t.distance = eval.value(p.distance.value, ctx, p.distance) end
            local a = text_of(p.angle)
            if a == "random" then t.random_angle = true
            elseif p.angle then t.angle = eval.value(p.angle.value, ctx, p.angle) end
        end
        if not tgt then return end
        t.target = { kind = tgt.kind, id = tgt.id }
        push(t)
        sync()
    end

    -- ------------------------------------------------------------------------------------------
    -- megastructures and wormholes

    local function system_radii(sys)
        local g = world.object("galactic_object", sys)
        return tonumber(world.field(g, "inner_radius")) or 0, tonumber(world.field(g, "outer_radius")) or 0
    end

    -- spawn_megastructure (CSpawnMegaStructureEffect::ExecuteActual 0x3777450): the place (given:
    -- coords_from's, or the scope's, or the planet's, moved by orbit_distance at orbit_angle; random_pos:
    -- two fixed-point draws of the scope random, the radius between the system's inner and outer
    -- radius [I for the type's other placement modes]), then init_effect in a scope from one draw of
    -- the game's generator [V]
    EFF["spawn_megastructure"] = function(e, ctx)
        local p = params(e)
        local typ = text_of(p.type)
        if not typ then return end
        sync()
        local sys = ctx.this.kind == "system" and ctx.this.id or R.system_of(ctx.this.kind, ctx.this.id)
        if not sys then return end
        local planet = target(p.planet, ctx)
        local x, y = 0, 0
        if O.yes_of(p.random_pos, false) then
            local inner, outer = system_radii(sys)
            local r = inner + fp(ctx) * (outer - inner)
            local span = math.rad(p.orbit_angle and eval.value(p.orbit_angle.value, ctx, p.orbit_angle) or 360)
            local a = fp(ctx) * span
            x, y = r * math.cos(a), r * math.sin(a)
            if planet and planet.kind == "planet" then
                local px, py = objects.galaxy.coord_of("planet", planet.id)
                x, y = x + (px or 0), y + (py or 0)
            end
        else
            local base = target(p.coords_from, ctx) or (ctx.this.kind ~= "system" and ctx.this) or planet
            if base and base ~= NONE and base.kind ~= "system" then
                local bx, by = objects.galaxy.coord_of(base.kind, base.id)
                x, y = bx or 0, by or 0
            end
            local d = p.orbit_distance and eval.value(p.orbit_distance.value, ctx, p.orbit_distance) or 0
            local a = math.rad(p.orbit_angle and eval.value(p.orbit_angle.value, ctx, p.orbit_angle) or 0)
            x, y = x + d * math.cos(a), y + d * math.sin(a)
        end
        local owner = country_of(target(p.owner, ctx), ctx)
        local h = E.new_handle()
        last("megastructure")(ctx, h)
        local q = { type = "spawn_megastructure", x = x, y = y, origin = sys, owner = owner,
            planet = planet and planet.kind == "planet" and planet.id or nil, handle = h }
        q.mtype = typ
        E.push(q)
        I.stats.engine = I.stats.engine + 1
        sync()
        local mid = E.resolve(h)
        if mid and nonempty(p.init_effect) then
            run(p.init_effect, child(ctx, S("megastructure", mid), E.rand()))
        end
    end

    -- spawn_natural_wormhole (CSpawnWormholeEffect 0x378af90, NEffectUtil::CalcCoordinatesBeyondGravityWell
    -- 0x384afc0): random_pos: the radius inner + fixed point x span (span = outer - inner, at most
    -- orbit_distance), the angle fixed point x orbit_angle, two fixed-point draws of the scope random
    -- (the hyperlane distance check that retries is not ported) [V]; init_effect in a scope from one
    -- draw of the game's generator, this = the bypass
    EFF["spawn_natural_wormhole"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return end
        local p = params(e)
        sync()
        local sys = ctx.this.id
        local inner, outer = system_radii(sys)
        local od = p.orbit_distance and eval.value(p.orbit_distance.value, ctx, p.orbit_distance) or 0
        local oa = p.orbit_angle and eval.value(p.orbit_angle.value, ctx, p.orbit_angle) or 0
        local x, y
        local inplace = target(p.in_place_of, ctx)
        if inplace then
            x, y = objects.galaxy.coord_of(inplace.kind, inplace.id)
        elseif O.yes_of(p.random_pos, false) then
            local span = outer - inner
            if od > 0 and od < span then span = od end
            local r = inner + fp(ctx) * span
            local a = fp(ctx) * math.rad(oa)
            x, y = r * math.cos(a), r * math.sin(a)
        else
            local r, a = inner + od, math.rad(oa)
            x, y = r * math.cos(a), r * math.sin(a)
        end
        local h = E.new_handle()
        local q = { type = "spawn_natural_wormhole", x = x or 0, y = y or 0, origin = sys, entity = text_of(p.graphics_entity_name),
            handle = h }
        q.btype = text_of(p.bypass_type)
        E.push(q)
        I.stats.engine = I.stats.engine + 1
        sync()
        local bid = E.resolve(h)
        if bid and nonempty(p.init_effect) then
            run(p.init_effect, child(ctx, S("bypass", bid), E.rand()))
        end
    end

    -- get_galaxy_setup_value = { setting = <key> which = <variable> scale_by = <v> }
    -- (CGetGalaxySetupValueEffect::ExecuteActual 0x37d0410): the galaxy setup's value (the save's
    -- `galaxy = { }`: an int setting as fixed point, a fixed one as it is) times scale_by (fixed
    -- point, truncated) into the scope's variable [V]
    -- variables of a scope without an object (on_game_start's: `local_wormholes_num`) are the
    -- event scope's own (CEventScope's variables): kept here, the world's store wraps them
    local LOCALS = {}
    local function scope_locals()
        local st = eval.store
        if not st or st.objects_locals then return end
        local get, set = st.getvar, st.setvar
        eval.store = setmetatable({
            objects_locals = true,
            getvar = function(sc, name)
                if sc == nil or sc == NONE or sc.kind == "none" then return LOCALS[name] end
                return get(sc, name)
            end,
            setvar = function(sc, name, v)
                if sc == nil or sc == NONE or sc.kind == "none" then LOCALS[name] = v return end
                return set(sc, name, v)
            end,
        }, { __index = st })
    end
    EFF["get_galaxy_setup_value"] = function(e, ctx)
        scope_locals()
        local p = params(e)
        local setting, which = text_of(p.setting), text_of(p.which)
        if not setting or not which then return end
        local g = world.meta.galaxy
        local v = type(g) == "table" and tonumber(world.field(g, setting)) or 0
        local scale = p.scale_by and eval.value(p.scale_by.value, ctx, p.scale_by) or 1
        local raw = math.floor(v * FP + 0.5) * math.floor(scale * FP + 0.5)
        local r = raw / FP
        r = (r < 0 and -math.floor(-r) or math.floor(r)) / FP
        I.stats.script = I.stats.script + 1
        eval.store.setvar(ctx.this, which, r)
    end

    EFF["link_wormholes"] = function(e, ctx)
        local tgt = target(e, ctx)
        if not tgt or (ctx.this.kind ~= "system" and ctx.this.kind ~= "bypass") then return end
        push({ type = "link_wormholes", kind = ctx.this.kind, id = ctx.this.id, target = { kind = tgt.kind, id = tgt.id } })
        sync()
    end
end
