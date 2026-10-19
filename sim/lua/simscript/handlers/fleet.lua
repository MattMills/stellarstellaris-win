-- simscript/handlers/fleet.lua : the fleets', ships', armies', designs' and combat's keywords (the
-- script coverage package `fleet`, docs/script_coverage.md): their iterator lists, scope links,
-- triggers and effects. Each follows the game's documentation (script_documentation 4.5.2) and,
-- where marked [V], the class in the 4.5.2 Linux binary; [I] marks what is inferred from the
-- documentation and the save's fields. The world is the save's: `fleet`, `ships`, `army`,
-- `ship_design`, `ground_combat` (engine.fleets.armies), `colony` (`army`, `carrier`), `planets`
-- (`shipclass_orbital_station`, `orbital_defence`, `orbit`), the country's `owned_armies`,
-- `ship_design_collection`, `fleets_manager`.
--
-- Scopes: a design is `ship_design` (the scope the checker names `design` too); a growth stage is
-- `ship_growth_stage` with the id "<design>/<stage>".

return function(eval)
    local I = eval._internal
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local S, NONE, sync, compare = I.S, I.NONE, I.sync, I.compare
    local world = require("engine.world")
    local R = require("engine.script.runtime")

    local NO_ID = 4294967295

    -- -----------------------------------------------------------------------------------------
    -- helpers

    local function num(v) return tonumber(v) end
    local function ref(v)
        local n = tonumber(v)
        return n and n ~= NO_ID and n or nil
    end
    local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
    local function yes(e) return e.value.text ~= "no" end
    local function value(e, ctx) return eval.value(e.value, ctx, e) end
    local function cmp(v, e, ctx)
        if v == nil then return false end
        return compare(v, e.op, value(e, ctx))
    end
    local function scopes(kind, ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = S(kind, id) end
        return out
    end
    local function ship_obj(id) return id and (world.object("ships", id) or world.object("ship", id)) end
    local function fleet_obj(id) return id and world.object("fleet", id) end
    local function army_obj(id) return id and world.object("army", id) end
    local function design_obj(id) return id and world.object("ship_design", id) end
    local function is_design(sc) return sc.kind == "ship_design" or sc.kind == "design" end

    -- a block's ids: `key = { 1 2 3 }` or the blocks' `key2 = id`
    local function id_list(v, key2)
        local out = {}
        if type(v) ~= "table" then
            local n = ref(v)
            if n then out[1] = n end
            return out
        end
        for _, x in ipairs(world.list(v)) do
            local n = ref(x)
            if n then out[#out + 1] = n end
        end
        if #out == 0 and key2 then
            for _, b in ipairs(world.blocks(v)) do
                local n = ref(world.field(b, key2))
                if n then out[#out + 1] = n end
            end
        end
        return out
    end

    local function fleet_ships(fid)
        local f = fleet_obj(fid)
        return f and id_list(world.field(f, "ships")) or {}
    end
    local function ship_fleet(sid)
        local s = ship_obj(sid)
        return s and ref(world.field(s, "fleet"))
    end
    -- the ships a ship or fleet scope stands for (a fleet's all)
    local function ships_of(sc)
        if not sc or sc == NONE then return {} end
        if sc.kind == "ship" then return ship_obj(sc.id) and { sc.id } or {} end
        if sc.kind == "fleet" then return fleet_ships(sc.id) end
        return {}
    end
    -- the fleet a ship or fleet scope stands for
    local function fleet_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "fleet" then return fleet_obj(sc.id) and sc.id end
        if sc.kind == "ship" then return ship_fleet(sc.id) end
        return nil
    end
    local function fleet_owner(fid)
        return world.fleet_owner and world.fleet_owner[fid] or R.fleet_owner(fid)
    end
    -- a planet, colony or ship colony's colony id (the scope `colony` is a planet or a ship)
    local function colony_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "planet" then return world.planet_colony and world.planet_colony[sc.id] end
        if sc.kind == "colony" then return sc.id end
        if sc.kind == "ship" then return R.colony_of and R.colony_of("ship", sc.id) or nil end
        return nil
    end
    local function system_of_fleet(fid)
        local f = fleet_obj(fid)
        return f and ref(world.path(f, "movement_manager", "coordinate", "origin"))
    end
    -- a fleet's orbitable: kind, id (`movement_manager.orbit.orbitable = { planet | starbase |
    -- megastructure = id }`)
    local function orbitable(fid)
        local f = fleet_obj(fid)
        local ob = f and world.path(f, "movement_manager", "orbit", "orbitable")
        if type(ob) ~= "table" then return nil end
        for _, k in ipairs({ "planet", "starbase", "megastructure" }) do
            local id = ref(world.field(ob, k))
            if id then return k, id end
        end
        return nil
    end
    -- the value of a block's `value <op> x` statement compared with v
    local function block_value(e, ctx, v, key)
        key = key or "value"
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.key.text:lower() == key then
                return v ~= nil and compare(v, x.op, eval.value(x.value, ctx, x))
            end
        end
        return false
    end
    local function params(e)
        local p = {}
        if type(e.value) == "table" and not e.value.text then
            for _, x in ipairs(e.value) do
                if x.op and x.key then p[x.key.text:lower()] = x end
            end
        end
        return p
    end
    local function target_of(x, ctx)
        local t = x and x.value and x.value.text
        if not t then return nil end
        local found, sc = eval.resolve(t, ctx, x)
        return found and sc and sc ~= NONE and sc or nil
    end

    -- -----------------------------------------------------------------------------------------
    -- lists (every_ / random_ / ordered_ / any_ / count_)

    -- combatant_fleet (a fleet): the fleets in its combat list (`combat.in_combat_with`,
    -- engine.fleets.combat) [I]
    LISTS["combatant_fleet"] = function(sc)
        if sc.kind ~= "fleet" then return {} end
        sync()
        local f = fleet_obj(sc.id)
        local l = f and world.path(f, "combat", "in_combat_with")
        local out = {}
        for _, b in ipairs(type(l) == "table" and world.blocks(l) or {}) do
            local id = ref(world.field(b, "fleet"))
            if id and fleet_obj(id) then out[#out + 1] = S("fleet", id) end
        end
        return out
    end
    -- fleet_in_orbit (a planet, starbase, megastructure; a ship colony's ship): the fleets whose
    -- orbitable it is [I]
    LISTS["fleet_in_orbit"] = function(sc)
        local kind = sc.kind
        if kind ~= "planet" and kind ~= "starbase" and kind ~= "megastructure" then return {} end
        sync()
        local out = {}
        for _, fid in ipairs(world.all("fleet")) do
            local k, id = orbitable(fid)
            if k == kind and id == sc.id then out[#out + 1] = S("fleet", fid) end
        end
        return out
    end
    -- galaxy_fleet: every fleet of the game
    LISTS["galaxy_fleet"] = function()
        sync()
        local out = {}
        for _, fid in ipairs(world.all("fleet")) do
            if fleet_obj(fid) then out[#out + 1] = S("fleet", fid) end
        end
        return out
    end
    -- ground_combat_attacker / ground_combat_defender (a planet or ship colony): the armies of its
    -- colony's ground combat (`colony.ground_combat` -> `ground_combat = { attackers defenders }`)
    local function ground_side(side)
        return function(sc)
            local cid = colony_of(sc)
            if not cid then return {} end
            sync()
            local c = world.object("colony", cid)
            local g = c and ref(world.field(c, "ground_combat"))
            local gc = g and world.object("ground_combat", g)
            if not gc then return {} end
            local out = {}
            for _, aid in ipairs(id_list(world.field(gc, side))) do
                if army_obj(aid) then out[#out + 1] = S("army", aid) end
            end
            return out
        end
    end
    LISTS["ground_combat_attacker"] = ground_side("attackers")
    LISTS["ground_combat_defender"] = ground_side("defenders")
    -- orbital_station (a country, a system): the orbital station fleets (mining, research and
    -- observation stations: CFleet::IsOrbitalStation [I: the classes the saves give the planets'
    -- `shipclass_orbital_station` fleets]) the country owns, or in the system
    local STATION = { shipclass_mining_station = true, shipclass_research_station = true,
        shipclass_observation_station = true }
    local function is_station(fid)
        local f = fleet_obj(fid)
        return f and STATION[unq(world.field(f, "ship_class"))] or false
    end
    LISTS["orbital_station"] = function(sc)
        sync()
        local out = {}
        if sc.kind == "country" then
            for _, fid in ipairs(R.owned_fleets(sc.id)) do
                if is_station(fid) then out[#out + 1] = S("fleet", fid) end
            end
        elseif sc.kind == "system" then
            for _, fid in ipairs(R.system_list(sc.id, "fleet_presence")) do
                if is_station(fid) then out[#out + 1] = S("fleet", fid) end
            end
        end
        return out
    end
    -- owned_army (a country): `owned_armies`
    LISTS["owned_army"] = function(sc)
        if sc.kind ~= "country" then return {} end
        sync()
        local c = world.object("country", sc.id)
        local out = {}
        for _, aid in ipairs(c and id_list(world.field(c, "owned_armies")) or {}) do
            if army_obj(aid) then out[#out + 1] = S("army", aid) end
        end
        return out
    end
    -- owned_design (a country): `ship_design_collection.ship_design`
    local function owned_designs(country)
        local c = world.object("country", country)
        local col = c and world.field(c, "ship_design_collection")
        return type(col) == "table" and id_list(world.field(col, "ship_design")) or {}
    end
    LISTS["owned_design"] = function(sc)
        if sc.kind ~= "country" then return {} end
        sync()
        local out = {}
        for _, did in ipairs(owned_designs(sc.id)) do
            if design_obj(did) then out[#out + 1] = S("ship_design", did) end
        end
        return out
    end
    -- planet_army (a planet or ship colony): its colony's armies (`colony.army`) not in a ground
    -- combat, whoever owns them
    LISTS["planet_army"] = function(sc)
        local cid = colony_of(sc)
        if not cid then return {} end
        sync()
        local c = world.object("colony", cid)
        local out = {}
        for _, aid in ipairs(c and id_list(world.field(c, "army")) or {}) do
            local a = army_obj(aid)
            if a and not ref(world.field(a, "ground_combat")) then out[#out + 1] = S("army", aid) end
        end
        return out
    end
    -- ship_in_system (a system): the ships of the fleets present (`fleet_presence`)
    LISTS["ship_in_system"] = function(sc)
        if sc.kind ~= "system" then return {} end
        sync()
        local out = {}
        for _, fid in ipairs(R.system_list(sc.id, "fleet_presence")) do
            for _, sid in ipairs(fleet_ships(fid)) do
                if ship_obj(sid) then out[#out + 1] = S("ship", sid) end
            end
        end
        return out
    end
    -- system_ship_colony (a system): the colonies carried by a ship (`carrier = { type = ship }`)
    -- in it, as their ships
    LISTS["system_ship_colony"] = function(sc)
        if sc.kind ~= "system" then return {} end
        sync()
        local out = {}
        for _, cid in ipairs(world.all("colony")) do
            local c = world.object("colony", cid)
            local car = c and world.field(c, "carrier")
            if type(car) == "table" and unq(world.field(car, "type")) == "ship" then
                local sid = ref(world.field(car, "reference"))
                local fid = sid and ship_fleet(sid)
                if fid and system_of_fleet(fid) == sc.id then out[#out + 1] = S("ship", sid) end
            end
        end
        return out
    end

    -- -----------------------------------------------------------------------------------------
    -- scope links

    -- last_created_fleet / _ship / _army / _design: the game state's last created object
    -- (CGameState +0x920 fleet, +0x924 ship, +0x930 design [V, handlers/objects.lua]); the
    -- context's own, else the game's (eval.last_created)
    for _, k in ipairs({ "fleet", "ship", "army", "design" }) do
        local kind = I.CREATED_KIND[k] or (k == "design" and "ship_design" or k)
        LINKS["last_created_" .. k] = function(_, ctx)
            local h = ctx and ctx.created and ctx.created[k]
            if not h then return nil end
            sync()
            local id = I.E.resolve(h)
            return id and S(kind, id) or nil
        end
    end
    -- design (a ship): its design (`ship_design_implementation.design`)
    LINKS["design"] = function(cur)
        if cur == NONE or cur.kind ~= "ship" then return nil end
        sync()
        local s = ship_obj(cur.id)
        local d = s and ref(world.path(s, "ship_design_implementation", "design"))
        return d and S("ship_design", d) or nil
    end
    -- ship_growth_stage (a ship): its design's current growth stage
    LINKS["ship_growth_stage"] = function(cur)
        if cur == NONE or cur.kind ~= "ship" then return nil end
        sync()
        local s = ship_obj(cur.id)
        local sdi = s and world.field(s, "ship_design_implementation")
        local d = type(sdi) == "table" and ref(world.field(sdi, "design"))
        if not d then return nil end
        return S("ship_growth_stage", d .. "/" .. (num(world.field(sdi, "growth_stage")) or 0))
    end
    -- orbit: the planet the object orbits: a fleet's orbitable planet (a ship's, an army's
    -- transport's, a starbase's station's fleet's), a planet's own `orbit` (a moon's planet) [I]
    LINKS["orbit"] = function(cur)
        if cur == NONE then return nil end
        sync()
        local fid
        if cur.kind == "fleet" then
            fid = cur.id
        elseif cur.kind == "ship" then
            fid = ship_fleet(cur.id)
        elseif cur.kind == "army" then
            local a = army_obj(cur.id)
            local sid = a and ref(world.field(a, "ship"))
            if sid then fid = ship_fleet(sid)
            else
                local cid = a and ref(world.field(a, "colony"))
                local pid = cid and world.colony_planet and world.colony_planet[cid]
                return pid and S("planet", pid) or nil
            end
        elseif cur.kind == "starbase" then
            local sb = world.object("starbases", cur.id) or world.object("starbase", cur.id)
            local st = sb and ref(world.field(sb, "station"))
            fid = st and ship_fleet(st)
        elseif cur.kind == "planet" then
            local p = world.object("planet", cur.id)
            local o = p and ref(world.field(p, "orbit"))
            return o and world.object("planet", o) and S("planet", o) or nil
        end
        if not fid then return nil end
        local k, id = orbitable(fid)
        if k == "planet" then return S("planet", id) end
        return nil
    end
    -- orbital_station / orbital_defence (a planet or ship colony): the planet's
    -- `shipclass_orbital_station` / `orbital_defence` fleet
    local function planet_fleet(key)
        return function(cur)
            if cur == NONE then return nil end
            local pid = cur.kind == "planet" and cur.id or nil
            if not pid then return nil end
            sync()
            local p = world.object("planet", pid)
            local f = p and ref(world.field(p, key))
            return f and fleet_obj(f) and S("fleet", f) or nil
        end
    end
    LINKS["orbital_station"] = planet_fleet("shipclass_orbital_station")
    LINKS["orbital_defence"] = planet_fleet("orbital_defence")
    -- army_leader (a planet): the leader of its colony's armies (the first army with one) [I]
    LINKS["army_leader"] = function(cur)
        if cur == NONE then return nil end
        local cid = colony_of(cur)
        if not cid then return nil end
        sync()
        local c = world.object("colony", cid)
        for _, aid in ipairs(c and id_list(world.field(c, "army")) or {}) do
            local a = army_obj(aid)
            local l = a and ref(world.field(a, "leader"))
            if l and world.object("leaders", l) then return S("leader", l) end
        end
        return nil
    end
    -- first_ / second_ / third_damaging_country (a fleet): the countries that dealt it the most
    -- damage, ranked (recorded with the fleet setting record_damaging_country: the fleet's
    -- `damaging_countries = { { country damage } ... }` [I]); nil without a record
    local function damaging(rank)
        return function(cur)
            if cur == NONE or cur.kind ~= "fleet" then return nil end
            sync()
            local f = fleet_obj(cur.id)
            local l = f and world.field(f, "damaging_countries")
            if type(l) ~= "table" then return nil end
            local rows = {}
            for _, b in ipairs(world.blocks(l)) do
                local c = ref(world.field(b, "country"))
                if c then rows[#rows + 1] = { c, num(world.field(b, "damage")) or 0 } end
            end
            table.sort(rows, function(a, b) return a[2] > b[2] end)
            local r = rows[rank]
            return r and world.object("country", r[1]) and S("country", r[1]) or nil
        end
    end
    LINKS["first_damaging_country"] = damaging(1)
    LINKS["second_damaging_country"] = damaging(2)
    LINKS["third_damaging_country"] = damaging(3)

    -- the module's internals for the triggers and effects below (fleet_effects)
    eval.fleet = {
        num = num, ref = ref, unq = unq, yes = yes, value = value, cmp = cmp, scopes = scopes,
        ship_obj = ship_obj, fleet_obj = fleet_obj, army_obj = army_obj, design_obj = design_obj,
        is_design = is_design, id_list = id_list, fleet_ships = fleet_ships, ship_fleet = ship_fleet,
        ships_of = ships_of, fleet_of = fleet_of, fleet_owner = fleet_owner, colony_of = colony_of,
        system_of_fleet = system_of_fleet, orbitable = orbitable, block_value = block_value,
        params = params, target_of = target_of, owned_designs = owned_designs, is_station = is_station,
        R = R, NO_ID = NO_ID,
    }
    require("simscript.handlers.fleet_triggers")(eval, eval.fleet)
    require("simscript.handlers.fleet_effects")(eval, eval.fleet)
    require("simscript.handlers.fleet_create")(eval, eval.fleet)
end
