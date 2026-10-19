-- simscript/handlers/starbase.lua : the script keywords of starbases, megastructures, systems,
-- bypasses (wormholes, gateways, L-gates), hyperlanes, ambient objects, debris, sectors, psionic
-- auras and borders (docs/script_coverage.md; the package tmp_scriptdocs/packages/starbase.tsv).
-- Each follows the game's documentation (script_documentation: triggers.log, effects.log,
-- scopes.log) and, where it was read, the game's class (4.5.2 Linux build): [V] read in the game's
-- code or saves, [I] inferred from the documentation and the save's form.
--
-- The world is read and written through engine.world (and engine/script/runtime.lua's readers);
-- the save's stores: galactic_object (systems: hyperlane, asteroid_belts, inner_radius, starbases,
-- sector, storm, fleet_presence, megastructures), starbase_mgr.starbases, megastructures, bypasses
-- (type active owner = { type id } lock_country lock_remaining_days is_manual_lock connections
-- linked_to), natural_wormholes (coordinate bypass), ambient_object, debris, sectors (systems
-- local_capital owner type), psionic_auras, rim_galactic_objects, clusters.

local world = require("engine.world")

return function(eval)
    local I = eval._internal
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local S, NONE, compare, yes, sync, E = I.S, I.NONE, I.compare, I.yes, I.sync, I.E

    local NO_ID = 4294967295
    -- the stores of the scope kinds engine.world.KINDS does not name
    local STORE = {
        bypass = "bypasses", ambient_object = "ambient_object", debris = "debris", natural_wormhole = "natural_wormholes",
        cosmic_storm = "storms",
    }

    local R
    local function rt()
        if R == nil then
            local ok, mod = pcall(require, "engine.script.runtime")
            R = ok and mod or false
        end
        return R or nil
    end

    local function obj(kind, id)
        if id == nil then return nil end
        return world.object(STORE[kind] or kind, id)
    end
    local function all(kind)
        return world.all(STORE[kind] or kind) or {}
    end
    local function ref(v)
        local n = tonumber(v)
        if n == nil or n == NO_ID or n < 0 then return nil end
        return n
    end
    local function unq(v)
        if v == nil then return nil end
        return (tostring(v):gsub('"', ""))
    end
    local function scopes(kind, ids)
        local out = {}
        for _, id in ipairs(ids) do
            if obj(kind, id) then out[#out + 1] = S(kind, id) end
        end
        return out
    end
    -- the scope `<keyword> = <target>` names, or nil
    local function target(e, ctx)
        if not e.value.text then return nil end
        local found, sc = eval.resolve(e.value.text, ctx, e)
        return (found and sc and sc ~= NONE) and sc or nil
    end
    -- a block's field `key` (its text, or the block)
    local function param(block, key)
        for _, x in ipairs(type(block) == "table" and block or {}) do
            if x.op and x.key and x.key.text:lower() == key then
                return x.value.text or x.value, x
            end
        end
        return nil
    end
    local bypass_system
    -- a country's capital system: its `capital` colony's carrier's system (R.capital_system's walk;
    -- carrier_of's two values kept: `col and f()` would keep only the first)
    local function capital_system(c)
        local r = rt()
        local o = r and obj("country", c)
        local col = o and ref(world.field(o, "capital"))
        if not col then return nil end
        local kind, id = r.carrier_of("colony", col)
        if not kind then return nil end
        return r.system_of(kind, id)
    end
    local function system_of(sc)
        local r = rt()
        if not r or sc == nil or sc == NONE then return nil end
        sync()
        if sc.kind == "bypass" then
            return bypass_system(sc.id)
        elseif sc.kind == "country" then
            return capital_system(sc.id)
        elseif sc.kind == "ambient_object" or sc.kind == "debris" then
            local o = obj(sc.kind, sc.id)
            local c = o and world.field(o, "coordinate")
            return type(c) == "table" and ref(world.field(c, "origin")) or nil
        end
        return r.system_of(sc.kind, sc.id)
    end
    local function country_of(sc)
        return sc and sc ~= NONE and sc.kind == "country" and sc.id or nil
    end
    local function today()
        return eval.today and eval.today() or 0
    end

    -- -----------------------------------------------------------------------------------------
    -- bypasses: their system (the owner object's: a megastructure, owner type 6, or a natural
    -- wormhole, type 7 [V: the 2210 save's lgate_base and shroud_tunnel]), their connections

    bypass_system = function(bid)
        local b = obj("bypass", bid)
        local o = b and world.field(b, "owner")
        if type(o) ~= "table" then return nil end
        local t, id = tonumber(world.field(o, "type")), ref(world.field(o, "id"))
        local holder = (t == 6 and obj("megastructure", id)) or (t == 7 and obj("natural_wormhole", id)) or nil
        local c = holder and world.field(holder, "coordinate")
        return type(c) == "table" and ref(world.field(c, "origin")) or nil
    end
    local function bypasses_in_system(sid)
        local out = {}
        for _, bid in ipairs(all("bypass")) do
            if bypass_system(bid) == sid then out[#out + 1] = bid end
        end
        return out
    end
    -- the bypasses a bypass leads to: its `connections` (a gateway's), its `linked_to` (a wormhole's)
    local function bypass_links(bid)
        local b = obj("bypass", bid)
        local out = {}
        for _, v in ipairs(world.list(b and world.field(b, "connections"))) do
            local id = ref(v)
            if id and id ~= bid then out[#out + 1] = id end
        end
        local l = b and ref(world.field(b, "linked_to"))
        if l then out[#out + 1] = l end
        return out
    end
    -- the systems one jump away: the hyperlanes', with use_bypasses the active bypasses' too
    local function neighbours(sid, use_bypasses)
        local r = rt()
        local out = r and r.hyperlanes(sid) or {}
        if use_bypasses then
            for _, bid in ipairs(bypasses_in_system(sid)) do
                local b = obj("bypass", bid)
                if b and world.field(b, "active") ~= "no" then
                    for _, other in ipairs(bypass_links(bid)) do
                        local s2 = bypass_system(other)
                        if s2 then out[#out + 1] = s2 end
                    end
                end
            end
        end
        return out
    end

    -- -----------------------------------------------------------------------------------------
    -- psionic auras (`psionic_auras = { psionic_auras = { { country system intensity ... } } }`):
    -- each aura's country, its system and the systems it covers [I: the 2210 save has none]

    local function auras()
        local holder = world.meta and world.meta.psionic_auras
        if holder == nil then
            for _, e in ipairs(world.tree or {}) do
                if e.op and e.key and e.key.text == "psionic_auras" and type(e.value) == "table" then holder = e.value end
            end
        end
        local list = type(holder) == "table" and world.field(holder, "psionic_auras") or holder
        return world.blocks(type(list) == "table" and list or nil) or {}
    end
    local function aura_systems(a)
        local out = {}
        local s = ref(world.field(a, "system"))
        if s then out[#out + 1] = s end
        for _, v in ipairs(world.list(world.field(a, "systems"))) do
            local id = ref(v)
            if id and id ~= s then out[#out + 1] = id end
        end
        return out
    end
    local function aura_of_system(sid)
        for _, a in ipairs(auras()) do
            for _, s in ipairs(aura_systems(a)) do
                if s == sid then return a end
            end
        end
        return nil
    end

    -- -----------------------------------------------------------------------------------------
    -- lists (each gives every_ / random_ / ordered_ / any_ / count_ <name>)

    -- ambient_object: every ambient object (the `ambient_object` store)
    LISTS["ambient_object"] = function()
        sync()
        return scopes("ambient_object", all("ambient_object"))
    end
    -- available_debris (a country): the debris of the special projects available to it (the
    -- debris' `country` / `countries` [I]: a debris without them counts for every country)
    LISTS["available_debris"] = function(sc)
        local c = country_of(sc)
        if not c then return {} end
        sync()
        local out = {}
        for _, id in ipairs(all("debris")) do
            local d = obj("debris", id)
            if d then
                local own = ref(world.field(d, "country"))
                local listed = world.list(world.field(d, "countries"))
                local ok = own == nil and #listed == 0
                if own == c then ok = true end
                for _, v in ipairs(listed) do
                    if ref(v) == c then ok = true end
                end
                if ok then out[#out + 1] = S("debris", id) end
            end
        end
        return out
    end
    -- bypass: every bypass of the galaxy
    LISTS["bypass"] = function()
        sync()
        return scopes("bypass", all("bypass"))
    end
    -- bypass_in_system (a system): the bypasses whose holder is in it
    LISTS["bypass_in_system"] = function(sc)
        if sc.kind ~= "system" then return {} end
        sync()
        return scopes("bypass", bypasses_in_system(sc.id))
    end
    -- country_neighbor_to_system (a system): the owners of the systems one jump away, bypasses
    -- included (the documentation), each once
    LISTS["country_neighbor_to_system"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        local out, seen = {}, {}
        for _, s2 in ipairs(neighbours(sc.id, true)) do
            local o = r.system_owner(s2)
            if o and not seen[o] and obj("country", o) then
                seen[o] = true
                out[#out + 1] = S("country", o)
            end
        end
        return out
    end
    -- galaxy_sector: every sector
    LISTS["galaxy_sector"] = function()
        sync()
        return scopes("sector", all("sector"))
    end
    -- megastructure: every megastructure of the galaxy
    LISTS["megastructure"] = function()
        sync()
        return scopes("megastructure", all("megastructure"))
    end
    -- neighbor_system_euclidean (a system): the systems nearest to it by distance (not by
    -- hyperlanes), nearest first, within NGameplay's SYSTEM_BOTTLENECK_RADIUS-like radius [I: the
    -- systems within 2 x the mean hyperlane length of it]
    local function coord(sid)
        local s = obj("system", sid)
        local c = s and world.field(s, "coordinate")
        if type(c) ~= "table" then return nil end
        return tonumber(world.field(c, "x")) or 0, tonumber(world.field(c, "y")) or 0
    end
    LISTS["neighbor_system_euclidean"] = function(sc)
        if sc.kind ~= "system" then return {} end
        sync()
        local x0, y0 = coord(sc.id)
        if not x0 then return {} end
        local s = obj("system", sc.id)
        local total, n = 0, 0
        for _, h in ipairs(world.blocks(world.field(s, "hyperlane")) or {}) do
            total = total + (tonumber(world.field(h, "length")) or 0)
            n = n + 1
        end
        local radius = 2 * (n > 0 and total / n or 30)
        local near = {}
        for _, sid in ipairs(all("system")) do
            if sid ~= sc.id then
                local x, y = coord(sid)
                if x then
                    local d = math.sqrt((x - x0) ^ 2 + (y - y0) ^ 2)
                    if d <= radius then near[#near + 1] = { sid, d } end
                end
            end
        end
        table.sort(near, function(a, b) return a[2] < b[2] end)
        local out = {}
        for i, v in ipairs(near) do out[i] = S("system", v[1]) end
        return out
    end
    -- pre_ftl_within_border / observed_pre_ftl_within_border (a country or a sector): the pre-FTL
    -- countries (country type primitive [I]) whose capital is in a system the country owns (the
    -- sector holds); observed: an observation station (the planet's shipclass_orbital_station fleet)
    -- of the country orbits that capital
    local function in_border(sc, sid)
        local r = rt()
        if sc.kind == "country" then return r.system_owner(sid) == sc.id end
        if sc.kind == "sector" then
            local sec = obj("sector", sc.id)
            for _, v in ipairs(world.list(sec and world.field(sec, "systems"))) do
                if ref(v) == sid then return true end
            end
        end
        return false
    end
    local function pre_ftl(sc, observed)
        local r = rt()
        if not r or (sc.kind ~= "country" and sc.kind ~= "sector") then return {} end
        sync()
        local watcher = sc.kind == "country" and sc.id or ref(world.field(obj("sector", sc.id) or {}, "owner"))
        local out = {}
        for _, cid in ipairs(all("country")) do
            local c = obj("country", cid)
            local t = c and unq(world.field(c, "type"))
            if t == "primitive" then
                local sid = capital_system(cid)
                if sid and in_border(sc, sid) then
                    local ok = true
                    if observed then
                        ok = false
                        local col = ref(world.field(c, "capital"))
                        local kind, pid
                        if col then kind, pid = r.carrier_of("colony", col) end
                        local f = kind == "planet" and ref(world.field(world.object("planet", pid) or {}, "shipclass_orbital_station"))
                        if f and r.fleet_owner(f) == watcher then ok = true end
                    end
                    if ok then out[#out + 1] = S("country", cid) end
                end
            end
        end
        return out
    end
    LISTS["pre_ftl_within_border"] = function(sc) return pre_ftl(sc, false) end
    LISTS["observed_pre_ftl_within_border"] = function(sc) return pre_ftl(sc, true) end
    -- owned_sector (a country): its sectors (the sectors' `owner`)
    LISTS["owned_sector"] = function(sc)
        local c = country_of(sc)
        if not c then return {} end
        sync()
        local out = {}
        for _, id in ipairs(all("sector")) do
            if ref(world.field(obj("sector", id), "owner")) == c then out[#out + 1] = S("sector", id) end
        end
        return out
    end
    -- rim_system: the galaxy's rim systems (`rim_galactic_objects` [V])
    local function rim_systems()
        local list = world.meta and world.meta.rim_galactic_objects
        if list == nil then
            for _, e in ipairs(world.tree or {}) do
                if e.op and e.key and e.key.text == "rim_galactic_objects" then list = e.value end
            end
        end
        local out = {}
        for _, v in ipairs(world.list(type(list) == "table" and list or nil)) do
            local id = ref(v)
            if id then out[#out + 1] = id end
        end
        return out
    end
    LISTS["rim_system"] = function()
        sync()
        return scopes("system", rim_systems())
    end
    -- starbase_in_network (a starbase): the starbases of its waystation network
    -- (`waystation_networks = { <id> = { waystations = { <starbase> ... } } }`: CWaystationNetwork
    -- ::WriteMembers [V]), itself included
    local function network_of(sb)
        for _, nid in ipairs(world.all("waystation_networks") or {}) do
            local n = world.object("waystation_networks", nid)
            for _, v in ipairs(world.list(n and world.field(n, "waystations"))) do
                if ref(v) == sb then return n end
            end
        end
        return nil
    end
    local function network_members(sb)
        local n = network_of(sb)
        local out = {}
        for _, v in ipairs(world.list(n and world.field(n, "waystations"))) do
            local id = ref(v)
            if id then out[#out + 1] = id end
        end
        return out
    end
    LISTS["starbase_in_network"] = function(sc)
        if sc.kind ~= "starbase" then return {} end
        sync()
        return scopes("starbase", network_members(sc.id))
    end
    -- starbase_in_system (a system): its `starbases` [V]
    LISTS["starbase_in_system"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        return scopes("starbase", r.system_list(sc.id, "starbases"))
    end
    -- system_within_storm / system_added_to_storm / system_removed_from_storm (a cosmic storm): the
    -- storm's `systems`, `systems_added`, `systems_removed` [I: no storm in the 2210 save]
    for _, spec in ipairs({ { "system_within_storm", "systems" }, { "system_added_to_storm", "systems_added" },
        { "system_removed_from_storm", "systems_removed" } }) do
        local key = spec[2]
        LISTS[spec[1]] = function(sc)
            if sc.kind ~= "cosmic_storm" then return {} end
            sync()
            local st = obj("cosmic_storm", sc.id)
            local ids = {}
            for _, v in ipairs(world.list(st and world.field(st, key))) do
                local id = ref(v)
                if id then ids[#ids + 1] = id end
            end
            return scopes("system", ids)
        end
    end
    -- system_with_aura (a country): the systems its psionic auras cover
    LISTS["system_with_aura"] = function(sc)
        local c = country_of(sc)
        if not c then return {} end
        sync()
        local ids = {}
        for _, a in ipairs(auras()) do
            if ref(world.field(a, "country")) == c then
                for _, s in ipairs(aura_systems(a)) do ids[#ids + 1] = s end
            end
        end
        return scopes("system", ids)
    end

    -- -----------------------------------------------------------------------------------------
    -- scope links

    -- aura_owner (a system): the country of the psionic aura covering it
    LINKS["aura_owner"] = function(cur)
        if cur == NONE or cur.kind ~= "system" then return nil end
        sync()
        local a = aura_of_system(cur.id)
        local c = a and ref(world.field(a, "country"))
        return (c and obj("country", c)) and S("country", c) or nil
    end
    -- last_created_system / last_created_ambient_object: the game's last created (the save's
    -- top-level `last_created_system`, `last_created_ambient_object` [V]; this run's own creations
    -- first)
    for _, spec in ipairs({ { "last_created_system", "system" }, { "last_created_ambient_object", "ambient_object" } }) do
        local name, kind = spec[1], spec[2]
        LINKS[name] = function(cur, ctx)
            local created = ctx and ctx.created and ctx.created[kind]
            if created and eval._internal.E and eval._internal.E.resolve then
                sync()
                local id = eval._internal.E.resolve(created)
                if id and obj(kind, id) then return S(kind, id) end
            end
            local id = ref(world.meta and world.meta[name])
            return (id and obj(kind, id)) and S(kind, id) or nil
        end
    end
    -- lock_country (a bypass): the country that locked it (`lock_country` [V])
    LINKS["lock_country"] = function(cur)
        if cur == NONE or cur.kind ~= "bypass" then return nil end
        local b = obj("bypass", cur.id)
        local c = b and ref(world.field(b, "lock_country"))
        return (c and obj("country", c)) and S("country", c) or nil
    end
    -- mining_station (a planet, a colony, a ship carrier): the mining station fleet in its orbit
    -- (the planet's `shipclass_orbital_station` whose class is shipclass_mining_station [I])
    LINKS["mining_station"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        sync()
        local kind, pid = r.carrier_of(cur.kind, cur.id)
        if kind ~= "planet" then return nil end
        local f = ref(world.field(world.object("planet", pid) or {}, "shipclass_orbital_station"))
        local fl = f and obj("fleet", f)
        if fl and unq(world.field(fl, "ship_class")) == "shipclass_mining_station" then return S("fleet", f) end
        return nil
    end
    -- system_star (any object in a system; a country: its capital's system): the system's primary
    -- star (R.star_planet: CGalacticObject::GetStarPlanetObject)
    LINKS["system_star"] = function(cur)
        local r = rt()
        local sid = system_of(cur)
        local p = r and sid and r.star_planet(sid)
        return p and S("planet", p) or nil
    end
    -- target_system (a cosmic storm): the system it heads to (`target` [I])
    LINKS["target_system"] = function(cur)
        if cur == NONE or cur.kind ~= "cosmic_storm" then return nil end
        local st = obj("cosmic_storm", cur.id)
        local s = st and ref(world.field(st, "target") or world.field(st, "target_system"))
        return (s and obj("system", s)) and S("system", s) or nil
    end

    -- -----------------------------------------------------------------------------------------
    -- triggers

    local function num_compare(v, e, ctx)
        if v == nil then return false end
        return compare(v, e.op, eval.value(e.value, ctx, e))
    end
    local function system_field(sc, key)
        if sc == NONE or sc.kind ~= "system" then return nil end
        local s = obj("system", sc.id)
        return s and world.field(s, key)
    end

    -- has_asteroid_belt = yes/no (a system): an `asteroid_belts` entry
    TRIG["has_asteroid_belt"] = function(e, ctx)
        local b = system_field(ctx.this, "asteroid_belts")
        if ctx.this.kind ~= "system" then return false end
        return (#(world.blocks(type(b) == "table" and b or nil) or {}) > 0) == yes(e)
    end
    -- num_asteroid_belts <op> n (a system)
    TRIG["num_asteroid_belts"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local b = system_field(ctx.this, "asteroid_belts")
        return num_compare(#(world.blocks(type(b) == "table" and b or nil) or {}), e, ctx)
    end
    -- inner_radius <op> n (a system): its `inner_radius` [V]
    TRIG["inner_radius"] = function(e, ctx)
        return num_compare(tonumber(system_field(ctx.this, "inner_radius")), e, ctx)
    end
    -- num_planets_in_system <op> n (a system): its planets (the stars included [I])
    TRIG["num_planets_in_system"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local s = obj("system", ctx.this.id)
        return num_compare(s and #world.fields(s, "planet") or 0, e, ctx)
    end
    -- num_galaxy_systems <op> n: the galaxy's systems
    TRIG["num_galaxy_systems"] = function(e, ctx)
        sync()
        return num_compare(#all("system"), e, ctx)
    end
    -- is_rim_system = yes/no (a system): in `rim_galactic_objects`
    TRIG["is_rim_system"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local on = false
        for _, s in ipairs(rim_systems()) do
            if s == ctx.this.id then on = true break end
        end
        return on == yes(e)
    end
    -- is_bridge = yes/no (a system): one of its hyperlanes has `bridge = yes` [V: the save's lanes]
    TRIG["is_bridge"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local s = obj("system", ctx.this.id)
        local on = false
        for _, h in ipairs(world.blocks(s and world.field(s, "hyperlane")) or {}) do
            if world.field(h, "bridge") == "yes" then on = true break end
        end
        return on == yes(e)
    end
    -- has_presence = yes/no (a system): fleets, a starbase, a megastructure or a colonized planet
    TRIG["has_presence"] = function(e, ctx)
        local r = rt()
        if not r or ctx.this.kind ~= "system" then return false end
        sync()
        local sid = ctx.this.id
        local on = #r.system_list(sid, "fleet_presence") > 0 or r.primary_starbase(sid) ~= nil
            or #r.system_list(sid, "megastructures") > 0
        if not on then
            local s = obj("system", sid)
            for _, v in ipairs(s and world.fields(s, "planet") or {}) do
                if world.planet_colony[tonumber(v)] then on = true break end
            end
        end
        return on == yes(e)
    end
    -- has_environmental_effects (a system): a cosmic storm in it, a nebula over it, or its star
    -- class's modifier [I]
    local function in_nebula(sid)
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "nebula" and type(e.value) == "table" then
                for _, v in ipairs(world.fields(e.value, "galactic_object")) do
                    if tonumber(v) == sid then return true end
                end
            end
        end
        return false
    end
    TRIG["has_environmental_effects"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local sid = ctx.this.id
        local on = ref(system_field(ctx.this, "storm")) ~= nil or in_nebula(sid)
        if not on then
            local cls = unq(system_field(ctx.this, "star_class"))
            local defs = require("engine.defs")
            local d = defs and cls and defs.get("common/star_classes", cls)
            on = d ~= nil and defs.field(d.block, "modifier") ~= nil
        end
        return on == (e.value.text ~= "no")
    end
    -- is_on_border (a system): owned, with a neighbour (one jump) owned by no one or by another [I]
    TRIG["is_on_border"] = function(e, ctx)
        local r = rt()
        if not r or ctx.this.kind ~= "system" then return false end
        sync()
        local o = r.system_owner(ctx.this.id)
        local on = false
        if o then
            for _, s2 in ipairs(r.hyperlanes(ctx.this.id)) do
                if r.system_owner(s2) ~= o then on = true break end
            end
        end
        return on == (e.value.text ~= "no")
    end
    -- is_bottleneck_system = yes/no (a system): leaving it, the systems within
    -- NGameplay.SYSTEM_BOTTLENECK_RADIUS jumps split into more than one part [I]
    TRIG["is_bottleneck_system"] = function(e, ctx)
        local r = rt()
        if not r or ctx.this.kind ~= "system" then return false end
        sync()
        local radius = r.define("NGameplay", "SYSTEM_BOTTLENECK_RADIUS", 4)
        local sid = ctx.this.id
        -- the systems within the radius, the scope left out
        local dist, queue = { [sid] = 0 }, { sid }
        local i = 1
        while queue[i] do
            local s = queue[i]
            i = i + 1
            if dist[s] < radius then
                for _, n in ipairs(r.hyperlanes(s)) do
                    if dist[n] == nil then
                        dist[n] = dist[s] + 1
                        queue[#queue + 1] = n
                    end
                end
            end
        end
        local parts, seen = 0, { [sid] = true }
        for _, start in ipairs(r.hyperlanes(sid)) do
            if not seen[start] then
                parts = parts + 1
                local st = { start }
                seen[start] = true
                while #st > 0 do
                    local s = table.remove(st)
                    for _, n in ipairs(r.hyperlanes(s)) do
                        if dist[n] and not seen[n] then
                            seen[n] = true
                            st[#st + 1] = n
                        end
                    end
                end
            end
        end
        return (parts > 1) == yes(e)
    end
    -- num_neighbor_systems = { max_distance = n limit = { ... } } <op> n: the systems within n jumps
    -- (the scope's system's) the limit holds for
    local function neighbor_count(block, ctx)
        local r = rt()
        local sid = system_of(ctx.this)
        if not r or not sid or type(block) ~= "table" or block.text then return nil end
        local _, mx = param(block, "max_distance")
        local maxd = mx and tonumber(eval.value(mx.value, ctx, mx)) or 1
        local limit = param(block, "limit")
        local dist, queue = { [sid] = 0 }, { sid }
        local i, n = 1, 0
        while queue[i] do
            local s = queue[i]
            i = i + 1
            if dist[s] < maxd then
                for _, nb in ipairs(r.hyperlanes(s)) do
                    if dist[nb] == nil then
                        dist[nb] = dist[s] + 1
                        queue[#queue + 1] = nb
                        if type(limit) ~= "table" or eval.trigger(limit, I.push(ctx, S("system", nb))) then n = n + 1 end
                    end
                end
            end
        end
        return n
    end
    TRIG["num_neighbor_systems"] = function(e, ctx)
        local n = neighbor_count(e.value, ctx)
        if not n then return false end
        local _, cx = param(e.value, "count")
        if cx then return compare(n, cx.op, eval.value(cx.value, ctx, cx)) end
        return n > 0
    end
    -- closest_system = { min_steps max_steps use_bypasses limit = { } <triggers> }: the nearest
    -- system (by jumps, min..max) the limit holds for, then the other triggers in it; false without
    -- one
    local function closest(block, ctx)
        local r = rt()
        local sid = system_of(ctx.this)
        if not r or not sid then return nil end
        local function n_of(key, default)
            local _, x = param(block, key)
            return x and tonumber(eval.value(x.value, ctx, x)) or default
        end
        local mn, mx = n_of("min_steps", 0), n_of("max_steps", 999)
        local use = param(block, "use_bypasses") == "yes"
        local limit = param(block, "limit")
        local dist, queue = { [sid] = 0 }, { sid }
        local i = 1
        while queue[i] do
            local s = queue[i]
            i = i + 1
            local d = dist[s]
            if d >= mn and d <= mx and (type(limit) ~= "table" or eval.trigger(limit, I.push(ctx, S("system", s)))) then
                return S("system", s)
            end
            if d < mx then
                for _, nb in ipairs(neighbours(s, use)) do
                    if dist[nb] == nil then
                        dist[nb] = d + 1
                        queue[#queue + 1] = nb
                    end
                end
            end
        end
        return nil
    end
    local CLOSEST_PARAMS = { min_steps = true, max_steps = true, use_bypasses = true, limit = true }
    TRIG["closest_system"] = function(e, ctx)
        if e.value.text then return false end
        sync()
        local s = closest(e.value, ctx)
        if not s then return false end
        return eval.trigger(e.value, I.push(ctx, s), CLOSEST_PARAMS)
    end

    -- starbases
    local function starbase_of(sc)
        if sc == NONE then return nil end
        if sc.kind == "starbase" then return sc.id end
        return nil
    end
    -- the starbases a count looks at: a starbase's own, a system's, a country's
    local function starbases_of(sc)
        local r = rt()
        if not r or sc == NONE then return {} end
        if sc.kind == "starbase" then return { sc.id } end
        if sc.kind == "system" then return r.system_list(sc.id, "starbases") end
        if sc.kind == "country" then return r.country_starbases(sc.id) end
        return {}
    end
    -- the items queued for a starbase (`buildable_starbase_<kind> = { starbase_<kind> slot starbase }`)
    local function queued(sb, kind)
        local r = rt()
        local out = {}
        for _, it in pairs(r and r.construction_items() or {}) do
            local b = world.field(it, "buildable_starbase_" .. kind)
            if type(b) == "table" and tonumber(world.field(b, "starbase")) == sb then
                out[#out + 1] = unq(world.field(b, "starbase_" .. kind) or world.field(b, kind))
            end
        end
        return out
    end
    -- count_starbase_modules / count_starbase_buildings = { type include_being_constructed count }
    -- (a country, a system, a starbase): its starbases' modules (buildings) of the type, or all
    local item_counts = {}
    for _, spec in ipairs({ { "count_starbase_modules", "modules", "module" }, { "count_starbase_buildings", "buildings", "building" } }) do
        local key, kind = spec[2], spec[3]
        local function count_items(block, ctx)
            local r = rt()
            if not r or type(block) ~= "table" or block.text then return nil end
            sync()
            local ty = param(block, "type")
            local building = param(block, "include_being_constructed") == "yes"
            local n = 0
            for _, sb in ipairs(starbases_of(ctx.this)) do
                for _, k in ipairs(r.starbase_items(sb, key)) do
                    if ty == nil or unq(k) == ty then n = n + 1 end
                end
                if building then
                    for _, k in ipairs(queued(sb, kind)) do
                        if ty == nil or k == ty then n = n + 1 end
                    end
                end
            end
            return n
        end
        item_counts[spec[1]] = count_items
        TRIG[spec[1]] = function(e, ctx)
            local n = count_items(e.value, ctx)
            if not n then return false end
            local _, cx = param(e.value, "count")
            if not cx then return n > 0 end
            return compare(n, cx.op, eval.value(cx.value, ctx, cx))
        end
    end
    -- is_starbase_building_module / _building = <key> (a starbase): an item of it queued
    for _, spec in ipairs({ { "is_starbase_building_module", "module" }, { "is_starbase_building_building", "building" } }) do
        local kind = spec[2]
        TRIG[spec[1]] = function(e, ctx)
            local sb = starbase_of(ctx.this)
            if not sb or not e.value.text then return false end
            sync()
            for _, k in ipairs(queued(sb, kind)) do
                if k == e.value.text then return true end
            end
            return false
        end
    end
    -- is_starbase_type = <type> (a starbase): its `type` [V: the save's sshipyard, sfortress ...]
    TRIG["is_starbase_type"] = function(e, ctx)
        local sb = starbase_of(ctx.this)
        local o = sb and obj("starbase", sb)
        return o ~= nil and unq(world.field(o, "type")) == e.value.text
    end
    -- starbase_buildable_is_in_queue_before = { first second } (a starbase): first queued ahead of
    -- second (true with only the first queued)
    TRIG["starbase_buildable_is_in_queue_before"] = function(e, ctx)
        local r = rt()
        local sb = starbase_of(ctx.this)
        if not r or not sb or e.value.text then return false end
        sync()
        local first, second = param(e.value, "first"), param(e.value, "second")
        local o = obj("starbase", sb)
        local q = o and ref(world.field(o, "build_queue"))
        local qb = q and world.object("construction.queue_mgr.queues", q)
        local i1, i2
        for i, v in ipairs(world.list(qb and world.field(qb, "items"))) do
            local it = r.construction_items()[tonumber(v)]
            if it then
                for _, kind in ipairs({ "module", "building", "upgrade" }) do
                    local b = world.field(it, "buildable_starbase_" .. kind)
                    if type(b) == "table" then
                        local k = unq(world.field(b, "starbase_" .. kind))
                        if k == first and not i1 then i1 = i end
                        if k == second and not i2 then i2 = i end
                    end
                end
            end
        end
        if not i1 then return false end
        return i2 == nil or i1 < i2
    end
    -- used_defense_platform_capacity_percent <op> f (a starbase): the platforms (its station
    -- fleet's other ships) over starbase_defense_platform_capacity_add
    TRIG["used_defense_platform_capacity_percent"] = function(e, ctx)
        local r = rt()
        local sb = starbase_of(ctx.this)
        if not r or not sb then return false end
        sync()
        local o = obj("starbase", sb)
        local station = ref(world.field(o, "station"))
        local fid = station and r.ship_fleet(station)
        local used = fid and math.max(0, #r.fleet_ships(fid) - 1) or 0
        local econ = package.loaded["engine.economy"]
        local M = econ and econ.modifiers and econ.modifiers("starbase", sb) or {}
        local cap = M.starbase_defense_platform_capacity_add or 0
        return num_compare(cap > 0 and used / cap or 0, e, ctx)
    end
    -- num_starbases <op> n (a country): the starbases it owns
    TRIG["num_starbases"] = function(e, ctx)
        local r = rt()
        local c = country_of(ctx.this)
        if not r or not c then return false end
        sync()
        return num_compare(#r.country_starbases(c), e, ctx)
    end
    -- used_starbase_capacity / max_starbase_capacity <op> n (a country): CCountry::
    -- CalcStarbaseCapacityUsed, CalcStarbaseCapacity (R)
    TRIG["used_starbase_capacity"] = function(e, ctx)
        local r = rt()
        local c = country_of(ctx.this)
        if not r or not c then return false end
        sync()
        return num_compare(r.starbase_capacity_used(c), e, ctx)
    end
    TRIG["max_starbase_capacity"] = function(e, ctx)
        local r = rt()
        local c = country_of(ctx.this)
        if not r or not c then return false end
        sync()
        return num_compare(r.starbase_capacity(c), e, ctx)
    end
    -- starbase_network_size <op> n (a starbase): its waystation network's starbases
    TRIG["starbase_network_size"] = function(e, ctx)
        local sb = starbase_of(ctx.this)
        if not sb then return false end
        sync()
        return num_compare(#network_members(sb), e, ctx)
    end
    -- waystation_has_remote_collection / waystation_network_has_remote_collection = yes/no (a
    -- starbase): a module or building of its (its network's) with the remote collection modifier
    -- (waystation_remote_collection_add [I])
    local function remote_collection(sb)
        local r = rt()
        local defs = require("engine.defs")
        if not r or not defs then return false end
        for _, key in ipairs({ "modules", "buildings" }) do
            local folder = key == "modules" and "common/starbase_modules" or "common/starbase_buildings"
            for _, k in ipairs(r.starbase_items(sb, key)) do
                local d = defs.get(folder, unq(k))
                local m = d and defs.field(d.block, "station_modifier")
                if type(m) == "table" then
                    for _, x in ipairs(m) do
                        if x.op and x.key and x.key.text:find("remote_collection", 1, true) then return true end
                    end
                end
            end
        end
        return false
    end
    TRIG["waystation_has_remote_collection"] = function(e, ctx)
        local sb = starbase_of(ctx.this)
        if not sb then return false end
        sync()
        return remote_collection(sb) == yes(e)
    end
    TRIG["waystation_network_has_remote_collection"] = function(e, ctx)
        local sb = starbase_of(ctx.this)
        if not sb then return false end
        sync()
        local on = false
        for _, m in ipairs(network_members(sb)) do
            if remote_collection(m) then on = true break end
        end
        return on == yes(e)
    end
    -- is_preferred_starbase_weapons = <weapon type> (a country): its
    -- ai_starbase_weapon_preference_override, else ai_weapon_preference_override [V: the save's
    -- country fields]
    TRIG["is_preferred_starbase_weapons"] = function(e, ctx)
        local c = country_of(ctx.this)
        local o = c and obj("country", c)
        if not o or not e.value.text then return false end
        local p = unq(world.field(o, "ai_starbase_weapon_preference_override")) or unq(world.field(o, "ai_weapon_preference_override"))
        return p == e.value.text
    end

    -- sectors
    -- num_sectors <op> n (a country): its sectors
    TRIG["num_sectors"] = function(e, ctx)
        local c = country_of(ctx.this)
        if not c then return false end
        sync()
        return num_compare(#LISTS["owned_sector"](ctx.this), e, ctx)
    end
    -- has_sector_type = <type> (a sector): its `type` [V]
    TRIG["has_sector_type"] = function(e, ctx)
        if ctx.this.kind ~= "sector" then return false end
        local s = obj("sector", ctx.this.id)
        return s ~= nil and unq(world.field(s, "type")) == e.value.text
    end
    -- governors_skill_in_system = { limit = { <leader triggers> } value <op> n } | <op> n (a system):
    -- the base skill (`level`, without bonus_skill_level) of its colonies' governors (the colony's
    -- `governor` [V: the 2212 save]) the limit holds for, summed (CGovernorsSkillInSystemTrigger::
    -- GetTriggerValue 0x3c39ca0: CGalacticObject::ForEachColony, the limit evaluated per governor
    -- [V the walk; I the sum])
    local function governors_skill(block, ctx)
        if ctx.this == NONE or ctx.this.kind ~= "system" then return nil end
        sync()
        local limit = type(block) == "table" and not block.text and param(block, "limit") or nil
        local total = 0
        local s = obj("system", ctx.this.id)
        local cols = {}
        for _, v in ipairs(world.list(s and world.field(s, "colonies"))) do cols[#cols + 1] = tonumber(v) end
        if #cols == 0 then
            for _, v in ipairs(s and world.fields(s, "planet") or {}) do
                local col = world.planet_colony[tonumber(v)]
                if col then cols[#cols + 1] = col end
            end
        end
        for _, col in ipairs(cols) do
            local c = obj("colony", col)
            local g = c and ref(world.field(c, "governor"))
            local l = g and obj("leader", g)
            if l and (type(limit) ~= "table" or eval.trigger(limit, I.push(ctx, S("leader", g)))) then
                total = total + (tonumber(world.field(l, "level")) or 0)
            end
        end
        return total
    end
    TRIG["governors_skill_in_system"] = function(e, ctx)
        if e.value.text then
            local n = governors_skill(nil, ctx)
            return n ~= nil and num_compare(n, e, ctx)
        end
        local n = governors_skill(e.value, ctx)
        if not n then return false end
        local _, vx = param(e.value, "value")
        if not vx then return n > 0 end
        return compare(n, vx.op, eval.value(vx.value, ctx, vx))
    end

    -- bypasses
    local function bypass_block(sc)
        return sc ~= NONE and sc.kind == "bypass" and obj("bypass", sc.id) or nil
    end
    -- is_bypass_type = <type> (a bypass): its `type` [V]
    TRIG["is_bypass_type"] = function(e, ctx)
        local b = bypass_block(ctx.this)
        return b ~= nil and unq(world.field(b, "type")) == e.value.text
    end
    -- has_lock = yes/no (a bypass): `lock_country` set [V]
    TRIG["has_lock"] = function(e, ctx)
        local b = bypass_block(ctx.this)
        if not b then return false end
        return (ref(world.field(b, "lock_country")) ~= nil) == yes(e)
    end
    -- can_lock_be_renewed = yes/no (a bypass): locked, not by hand, its days running [I]
    TRIG["can_lock_be_renewed"] = function(e, ctx)
        local b = bypass_block(ctx.this)
        if not b then return false end
        local on = ref(world.field(b, "lock_country")) ~= nil and world.field(b, "is_manual_lock") ~= "yes"
        return on == yes(e)
    end
    -- num_active_gateways <op> n: the active gateways of the galaxy (bypass type gateway, active)
    local function active_gateways(owner)
        local r = rt()
        local n = 0
        for _, bid in ipairs(all("bypass")) do
            local b = obj("bypass", bid)
            if b and unq(world.field(b, "type")) == "gateway" and world.field(b, "active") == "yes" then
                if owner == nil then
                    n = n + 1
                else
                    local sid = bypass_system(bid)
                    if sid and r and r.system_owner(sid) == owner then n = n + 1 end
                end
            end
        end
        return n
    end
    TRIG["num_active_gateways"] = function(e, ctx)
        sync()
        return num_compare(active_gateways(nil), e, ctx)
    end
    TRIG["num_owned_active_gateways"] = function(e, ctx)
        local c = country_of(ctx.this)
        if not c then return false end
        sync()
        return num_compare(active_gateways(c), e, ctx)
    end
    -- lgate_enabled: the game's setup enables L-Gates (the galaxy's `lgate_enabled`, else a bypass
    -- of type lgate exists [I])
    TRIG["lgate_enabled"] = function(e, ctx)
        local r = rt()
        local v = r and r.galaxy_field and r.galaxy_field("lgate_enabled")
        local on
        if v ~= nil then on = v == "yes" else
            on = false
            for _, bid in ipairs(all("bypass")) do
                if unq(world.field(obj("bypass", bid), "type")) == "lgate" then on = true break end
            end
        end
        return on == (e.value.text ~= "no")
    end
    -- owns_any_bypass = <type> (a country): a system it owns holds a bypass of the type
    TRIG["owns_any_bypass"] = function(e, ctx)
        local r = rt()
        local c = country_of(ctx.this)
        if not r or not c or not e.value.text then return false end
        sync()
        for _, bid in ipairs(all("bypass")) do
            local b = obj("bypass", bid)
            if b and unq(world.field(b, "type")) == e.value.text then
                local sid = bypass_system(bid)
                if sid and r.system_owner(sid) == c then return true end
            end
        end
        return false
    end
    -- has_seen_any_bypass = <type> / has_seen_specific_bypass = <bypass> (a country): its
    -- `seen_bypass_types` [V] / `seen_bypasses` [I]
    TRIG["has_seen_any_bypass"] = function(e, ctx)
        local c = country_of(ctx.this)
        local o = c and obj("country", c)
        if not o or not e.value.text then return false end
        for _, v in ipairs(world.list(world.field(o, "seen_bypass_types"))) do
            if unq(v) == e.value.text then return true end
        end
        return false
    end
    TRIG["has_seen_specific_bypass"] = function(e, ctx)
        local c = country_of(ctx.this)
        local o = c and obj("country", c)
        local t = target(e, ctx)
        if not o or not t or t.kind ~= "bypass" then return false end
        for _, v in ipairs(world.list(world.field(o, "seen_bypasses"))) do
            if ref(v) == t.id then return true end
        end
        return false
    end

    -- megastructures
    local function mega(sc)
        return sc ~= NONE and sc.kind == "megastructure" and obj("megastructure", sc.id) or nil
    end
    -- is_upgrading = yes/no (a megastructure: an upgrade under way, `upgrade` / its build queue has an
    -- item [I]; a fleet: a ship of it upgrading, `upgrade_progress` > 0 [I])
    TRIG["is_upgrading"] = function(e, ctx)
        local r = rt()
        local sc = ctx.this
        local on = false
        if sc.kind == "megastructure" then
            local m = mega(sc)
            if not m then return false end
            on = world.field(m, "upgrade") ~= nil or world.field(m, "upgrade_finish_date") ~= nil
            local q = ref(world.field(m, "build_queue"))
            local qb = q and world.object("construction.queue_mgr.queues", q)
            if qb and #world.list(world.field(qb, "items")) > 0 then on = true end
        elseif sc.kind == "fleet" and r then
            sync()
            for _, sid in ipairs(r.fleet_ships(sc.id)) do
                local s = obj("ship", sid)
                if s and (tonumber(world.field(s, "upgrade_progress")) or 0) > 0 then on = true break end
            end
        else
            return false
        end
        return on == yes(e)
    end
    -- upgrade_days_left <op> n (a megastructure): the days to its upgrade's end
    -- (`upgrade_finish_date` [I]; none: 0)
    TRIG["upgrade_days_left"] = function(e, ctx)
        local m = mega(ctx.this)
        if not m then return false end
        local d = unq(world.field(m, "upgrade_finish_date"))
        local left = 0
        if d then
            local y, mo, da = d:match("^(%d+)%.(%d+)%.(%d+)$")
            if y then
                local t = (tonumber(y) * 360 + (tonumber(mo) - 1) * 30 + tonumber(da) - 1)
                left = math.max(0, t - today())
            end
        end
        return num_compare(left, e, ctx)
    end
    -- has_overclock = <type> / has_overclock_cooldown = yes/no (a megastructure): its `overclock`,
    -- its `overclock_cooldown` date ahead of today [I]
    TRIG["has_overclock"] = function(e, ctx)
        local m = mega(ctx.this)
        return m ~= nil and unq(world.field(m, "overclock")) == e.value.text
    end
    TRIG["has_overclock_cooldown"] = function(e, ctx)
        local m = mega(ctx.this)
        if not m then return false end
        local until_day = tonumber(world.field(m, "overclock_cooldown_day")) or -1
        return (until_day > today()) == yes(e)
    end
    -- graphical_culture = <key> / <target> (a country, ship, megastructure, species): its
    -- `graphical_culture` (a megastructure's owner's; a species' class's [I]) against the key or
    -- the target's
    local function culture_of(sc)
        if sc == nil or sc == NONE then return nil end
        local o
        if sc.kind == "megastructure" then
            local m = obj("megastructure", sc.id)
            local owner = m and ref(world.field(m, "owner"))
            o = owner and obj("country", owner)
        elseif sc.kind == "species" then
            local s = obj("species", sc.id)
            local cls = s and unq(world.field(s, "class"))
            local defs = require("engine.defs")
            local d = defs and cls and defs.get("common/species_classes", cls)
            return d and unq(defs.field(d.block, "graphical_culture")) or nil
        else
            o = obj(sc.kind, sc.id)
        end
        return o and unq(world.field(o, "graphical_culture")) or nil
    end
    TRIG["graphical_culture"] = function(e, ctx)
        local mine = culture_of(ctx.this)
        if not mine or not e.value.text then return false end
        local t = target(e, ctx)
        if t then return culture_of(t) == mine end
        return mine == e.value.text
    end

    -- psionic auras
    -- has_psionic_aura = yes/no/<type> (a system)
    TRIG["has_psionic_aura"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local a = aura_of_system(ctx.this.id)
        local v = e.value.text
        if v == "yes" then return a ~= nil end
        if v == "no" then return a == nil end
        return a ~= nil and unq(world.field(a, "type")) == v
    end
    -- is_aura_intensity_level = n (a system): its aura's intensity level [I]
    TRIG["is_aura_intensity_level"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local a = aura_of_system(ctx.this.id)
        local lvl = a and tonumber(world.field(a, "intensity_level") or world.field(a, "level") or world.field(a, "intensity"))
        return lvl ~= nil and compare(lvl, e.op, eval.value(e.value, ctx, e))
    end
    -- monthly_intensity_increase <op> f (a system): its aura's monthly increase [I]
    TRIG["monthly_intensity_increase"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local a = aura_of_system(ctx.this.id)
        return num_compare(a and tonumber(world.field(a, "monthly_intensity_increase")) or 0, e, ctx)
    end
    -- count_systems_with_aura <op> n (a country): the systems its auras cover
    TRIG["count_systems_with_aura"] = function(e, ctx)
        if not country_of(ctx.this) then return false end
        return num_compare(#LISTS["system_with_aura"](ctx.this), e, ctx)
    end
    -- count_end_cycle_systems <op> n: the systems under an End Cycle aura (the crisis country's) [I]
    TRIG["count_end_cycle_systems"] = function(e, ctx)
        local n = 0
        for _, a in ipairs(auras()) do
            if (unq(world.field(a, "type")) or ""):find("end_cycle", 1, true) then n = n + #aura_systems(a) end
        end
        return num_compare(n, e, ctx)
    end

    -- storms
    -- is_storm_active_in_storm_sector (a system): a storm exists whose sector (the storm's
    -- `storm_sector` [I]) is the system's
    TRIG["is_storm_active_in_storm_sector"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        local mine = system_field(ctx.this, "storm_sector")
        local on = false
        for _, id in ipairs(all("cosmic_storm")) do
            local st = obj("cosmic_storm", id)
            if st and (mine == nil or world.field(st, "storm_sector") == mine) then on = true break end
        end
        return on == (e.value.text ~= "no")
    end

    -- fleets, colonies
    -- can_access_system = <system> (a fleet): the system's owner none, the fleet's owner, or one
    -- whose borders are open to it (no closed_borders relation [I])
    TRIG["can_access_system"] = function(e, ctx)
        local r = rt()
        local t = target(e, ctx)
        if not r or ctx.this.kind ~= "fleet" or not t or t.kind ~= "system" then return false end
        sync()
        local o = r.system_owner(t.id)
        local mine = r.fleet_owner(ctx.this.id)
        if o == nil or o == mine then return true end
        -- the owner's relation towards the fleet's owner (engine.diplomacy: CRelation's flags)
        return not require("engine.diplomacy").flag(o, mine, "closed_borders")
    end
    -- is_system_locked = yes/no (a planet carrier, a colony, a ship carrier, a fleet): its
    -- `system_locked` [I]
    TRIG["is_system_locked"] = function(e, ctx)
        local r = rt()
        local sc = ctx.this
        if not r or sc == NONE then return false end
        local o
        if sc.kind == "fleet" then o = obj("fleet", sc.id) else
            local kind, id = r.carrier_of(sc.kind, sc.id)
            o = kind and obj(kind, id)
        end
        if not o then return false end
        return (world.field(o, "system_locked") == "yes") == yes(e)
    end
    -- planet_devastation <op> n (a planet, colony, ship carrier): the colony's `devastation` [I]
    TRIG["planet_devastation"] = function(e, ctx)
        local r = rt()
        if not r then return false end
        local col = r.colony_of(ctx.this.kind, ctx.this.id)
        local c = col and obj("colony", col)
        return num_compare(c and tonumber(world.field(c, "devastation")) or 0, e, ctx)
    end
    -- total_system_workforce_with_job_tag = { tags = { } limit = { } value } (a system): the
    -- workforce of its colonies' jobs carrying every tag, the colonies the limit holds for [I]
    local function workforce_total(block, ctx)
        local r = rt()
        if not r or ctx.this.kind ~= "system" or type(block) ~= "table" or block.text then return nil end
        sync()
        local tags = {}
        local tb = param(block, "tags")
        for _, v in ipairs(world.list(type(tb) == "table" and tb or nil)) do tags[#tags + 1] = unq(v) end
        local limit = param(block, "limit")
        local defs = require("engine.defs")
        local total = 0
        local s = obj("system", ctx.this.id)
        for _, v in ipairs(s and world.fields(s, "planet") or {}) do
            local col = world.planet_colony[tonumber(v)]
            if col and (type(limit) ~= "table" or eval.trigger(limit, I.push(ctx, S("colony", col)))) then
                for _, jid in ipairs(world.all("pop_jobs") or {}) do
                    local j = world.object("pop_jobs", jid)
                    if j and tonumber(world.field(j, "planet")) == col then
                        local jt = unq(world.field(j, "type"))
                        local d = defs and jt and defs.get("common/pop_jobs", jt)
                        local have = {}
                        for _, t in ipairs(world.list(d and defs.field(d.block, "tags"))) do have[unq(t)] = true end
                        local ok = #tags > 0
                        for _, t in ipairs(tags) do if not have[t] then ok = false end end
                        if ok then total = total + (tonumber(world.field(j, "workforce")) or 0) end
                    end
                end
            end
        end
        return total
    end
    TRIG["total_system_workforce_with_job_tag"] = function(e, ctx)
        local total = workforce_total(e.value, ctx)
        if not total then return false end
        local _, vx = param(e.value, "value")
        if not vx then return total > 0 end
        return compare(total, vx.op, eval.value(vx.value, ctx, vx))
    end
    -- must_scavenge = yes/no (a debris): its `must_scavenge` [I]
    TRIG["must_scavenge"] = function(e, ctx)
        if ctx.this.kind ~= "debris" then return false end
        local d = obj("debris", ctx.this.id)
        if not d then return false end
        return (world.field(d, "must_scavenge") == "yes") == yes(e)
    end
    -- is_system_connected_to_relay_network = <system> (a system): a path of systems with hyper
    -- relays (a megastructure of type hyper_relay*) from the target to the scope's owner's capital [I]
    TRIG["is_system_connected_to_relay_network"] = function(e, ctx)
        local r = rt()
        local t = target(e, ctx) or ctx.this
        if not r or not t or t.kind ~= "system" then return false end
        sync()
        local owner = r.system_owner(ctx.this.kind == "system" and ctx.this.id or t.id)
        local cap = owner and capital_system(owner)
        if not cap then return false end
        local function relay(sid)
            for _, m in ipairs(r.system_list(sid, "megastructures")) do
                if (r.megastructure_type(m) or ""):find("hyper_relay", 1, true) then return true end
            end
            return false
        end
        if not relay(t.id) then return false end
        local seen, st = { [t.id] = true }, { t.id }
        while #st > 0 do
            local s = table.remove(st)
            if s == cap then return true end
            for _, n in ipairs(r.hyperlanes(s)) do
                if not seen[n] and (relay(n) or n == cap) then
                    seen[n] = true
                    st[#st + 1] = n
                end
            end
        end
        return false
    end

    -- -----------------------------------------------------------------------------------------
    -- effects (engine/script/objects_starbase.lua applies the queued ones)

    local O = eval.objects
    local params, text_of = O.params, O.text_of
    local function engine(t)
        O.push(t)
        sync()
    end
    local function script_work()
        I.stats.script = I.stats.script + 1
    end
    local function num_of(x, ctx)
        if not x then return nil end
        return tonumber(eval.value(x.value, ctx, x))
    end
    local function tgt_of(x, ctx)
        return O.target(x, ctx)
    end
    local function kind_is(ctx, kind)
        return ctx.this ~= NONE and ctx.this.kind == kind
    end

    -- variables (eval's store, as set_variable's): add_variable = { which value } (change_variable's
    -- sum), round_variable_to_closest = { which value } (to the nearest multiple),
    -- set_variable_to_random_value = { which min max rounded } (the scope's draw [I]),
    -- set_saved_date = { key days_from_present expires } (a flag named key, its date saved in the
    -- variable of that name as days since 0.1.1 [I])
    EFF["add_variable"] = function(e, ctx)
        local p = params(e)
        local which = text_of(p.which)
        if not which then return end
        script_work()
        eval.setvar(ctx.this, which, (eval.getvar(ctx.this, which) or 0) + (num_of(p.value, ctx) or 0))
    end
    EFF["round_variable_to_closest"] = function(e, ctx)
        local p = params(e)
        local which, step = text_of(p.which), num_of(p.value, ctx)
        if not which or not step or step == 0 then return end
        script_work()
        local v = eval.getvar(ctx.this, which) or 0
        eval.setvar(ctx.this, which, math.floor(v / step + 0.5) * step)
    end
    EFF["set_variable_to_random_value"] = function(e, ctx)
        local p = params(e)
        local which = text_of(p.which)
        if not which then return end
        local lo, hi = num_of(p.min, ctx) or 0, num_of(p.max, ctx) or 1
        script_work()
        local v = lo + eval.rand() * (hi - lo)
        if p.rounded and p.rounded.value.text == "yes" then v = math.floor(v + 0.5) end
        eval.setvar(ctx.this, which, v)
    end
    EFF["set_saved_date"] = function(e, ctx)
        local p = params(e)
        local key = text_of(p.key)
        if not key then return end
        script_work()
        local expires = num_of(p.expires, ctx)
        eval.store.set_flag(ctx.this, key, expires)
        eval.setvar(ctx.this, key, today() + (num_of(p.days_from_present, ctx) or 0))
    end
    -- set_spawn_system_batch = begin/end: the game batches spawn_system's map work; no state of its
    -- own (the documentation)
    EFF["set_spawn_system_batch"] = function(e, ctx)
        if e.value.text == "begin" or e.value.text == "end" then script_work() end
    end

    -- closest_system = { min_steps max_steps use_bypasses limit <effects> }: the effects in the
    -- nearest system the limit holds for
    EFF["closest_system"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local s = closest(e.value, ctx)
        if s then eval.effect(e.value, I.push(ctx, s), CLOSEST_PARAMS) end
    end
    -- system_in_cluster (every_/random_/...): the systems of the cluster the scope's system is in
    -- (`clusters = { { id position radius objects = { } } }` [V])
    LISTS["system_in_cluster"] = function(sc)
        local sid = system_of(sc)
        if not sid then return {} end
        local holder = world.meta and world.meta.clusters
        for _, c in ipairs(world.blocks(type(holder) == "table" and holder or nil)) do
            local ids, inside = {}, false
            for _, v in ipairs(world.list(world.field(c, "objects"))) do
                local id = ref(v)
                if id then
                    ids[#ids + 1] = id
                    if id == sid then inside = true end
                end
            end
            if inside then return scopes("system", ids) end
        end
        return {}
    end

    -- starbases
    for _, kind in ipairs({ "module", "building" }) do
        -- set_starbase_<kind> = { slot <kind> }
        EFF["set_starbase_" .. kind] = function(e, ctx)
            if not kind_is(ctx, "starbase") then return end
            local p = params(e)
            local item, slot = text_of(p[kind]), num_of(p.slot, ctx)
            if not item or not slot then return end
            engine({ type = "set_starbase_item", id = ctx.this.id, kind = kind, slot = slot, item = item })
        end
        -- remove_starbase_<kind> = { slot (default all) <kind> }
        EFF["remove_starbase_" .. kind] = function(e, ctx)
            if not kind_is(ctx, "starbase") then return end
            local p = params(e)
            local slot = p.slot and p.slot.value.text ~= "all" and num_of(p.slot, ctx) or nil
            engine({ type = "remove_starbase_item", id = ctx.this.id, kind = kind, slot = slot, item = text_of(p[kind]) })
        end
        -- remove_random_starbase_<kind> = { type count }
        EFF["remove_random_starbase_" .. kind] = function(e, ctx)
            if not kind_is(ctx, "starbase") then return end
            local p = params(e)
            engine({ type = "remove_starbase_item", id = ctx.this.id, kind = kind, item = text_of(p.type),
                random = true, count = num_of(p.count, ctx) or 1 })
        end
    end
    for _, spec in ipairs({ { "add_starbase_component", true }, { "remove_starbase_component", false } }) do
        local add = spec[2]
        EFF[spec[1]] = function(e, ctx)
            if not kind_is(ctx, "starbase") then return end
            local c = text_of(params(e).component)
            if not c then return end
            engine({ type = "starbase_component", id = ctx.this.id, component = c, add = add })
        end
    end
    EFF["set_starbase_size"] = function(e, ctx)
        if not kind_is(ctx, "starbase") or not e.value.text then return end
        engine({ type = "set_starbase_size", id = ctx.this.id, size = unq(e.value.text) })
    end

    -- countries
    for _, what in ipairs({ "armor_ratio", "shields_ratio", "weapon_preference" }) do
        EFF["set_ai_starbase_" .. what] = function(e, ctx)
            if not kind_is(ctx, "country") then return end
            local v = what == "weapon_preference" and unq(e.value.text) or num_of(e, ctx)
            if v == nil then return end
            engine({ type = "ai_starbase_override", id = ctx.this.id, what = what, value = v, quoted = what == "weapon_preference" })
        end
        EFF["clear_ai_starbase_" .. what] = function(e, ctx)
            if not kind_is(ctx, "country") or e.value.text ~= "yes" then return end
            engine({ type = "ai_starbase_override", id = ctx.this.id, what = what })
        end
    end
    EFF["add_seen_bypass_type"] = function(e, ctx)
        if not kind_is(ctx, "country") or not e.value.text then return end
        engine({ type = "add_seen_bypass", id = ctx.this.id, bypass_type = unq(e.value.text) })
    end
    EFF["add_seen_bypass"] = function(e, ctx)
        local t = target(e, ctx)
        if not kind_is(ctx, "country") or not t or t.kind ~= "bypass" then return end
        engine({ type = "add_seen_bypass", id = ctx.this.id, bypass = t.id })
    end
    EFF["set_closed_borders"] = function(e, ctx)
        if not kind_is(ctx, "country") then return end
        local p = params(e)
        local who = tgt_of(p.who, ctx)
        if not who or who.kind ~= "country" then return end
        engine({ type = "set_closed_borders", id = ctx.this.id, who = who.id, status = O.yes_of(p.status, true),
            forced = num_of(p.forced, ctx) })
    end

    -- systems
    for _, spec in ipairs({ { "add_hyperlane", "add_hyperlane" }, { "remove_hyperlane", "remove_hyperlane" } }) do
        local ty = spec[2]
        EFF[spec[1]] = function(e, ctx)
            local p = params(e)
            local a, b = tgt_of(p.from, ctx), tgt_of(p.to, ctx)
            local sa, sbb = a and system_of(a), b and system_of(b)
            if not sa or not sbb then return end
            engine({ type = ty, from = sa, to = sbb })
        end
    end
    for _, spec in ipairs({ { "add_asteroid_belt", false }, { "set_asteroid_belt", true } }) do
        local set = spec[2]
        EFF[spec[1]] = function(e, ctx)
            if not kind_is(ctx, "system") then return end
            local p = params(e)
            local belt, radius = text_of(p.type), num_of(p.radius, ctx)
            if not belt or not radius then return end
            engine({ type = "asteroid_belt", id = ctx.this.id, belt = belt, radius = radius, set = set })
        end
    end
    EFF["set_star_class"] = function(e, ctx)
        if not kind_is(ctx, "system") or not e.value.text then return end
        engine({ type = "set_star_class", id = ctx.this.id, class = unq(e.value.text) })
    end

    -- megastructures, bypasses, ambient objects
    local function mega_target(e, ctx)
        local t = target(e, ctx)
        return t and t.kind == "megastructure" and t.id or nil
    end
    for _, name in ipairs({ "delete_megastructure", "remove_megastructure" }) do
        EFF[name] = function(e, ctx)
            local m = mega_target(e, ctx)
            if m then engine({ type = "remove_megastructure", id = m }) end
        end
    end
    EFF["destroy_ambient_object"] = function(e, ctx)
        local t = target(e, ctx)
        if t and t.kind == "ambient_object" then engine({ type = "destroy_ambient_object", id = t.id }) end
    end
    EFF["activate_gateway"] = function(e, ctx)
        local m = mega_target(e, ctx)
        if m then engine({ type = "activate_gateway", id = m }) end
    end
    EFF["link_to"] = function(e, ctx)
        local m = mega_target(e, ctx)
        if kind_is(ctx, "megastructure") and m then engine({ type = "link_to", id = ctx.this.id, target = m }) end
    end
    -- create_bypass = { owner type effect }: the effect runs in the new bypass
    EFF["create_bypass"] = function(e, ctx)
        if not kind_is(ctx, "megastructure") then return end
        local p = params(e)
        local ty = text_of(p.type)
        if not ty then return end
        local h = E.new_handle()
        engine({ type = "create_bypass", id = ctx.this.id, bypass_type = ty, handle = h })
        local id = E.resolve(h)
        if id and p.effect and p.effect.value.text == nil then eval.effect(p.effect.value, I.push(ctx, S("bypass", id))) end
    end
    EFF["lock_bypass"] = function(e, ctx)
        if not kind_is(ctx, "bypass") then return end
        local p = params(e)
        local c = tgt_of(p.country, ctx)
        if not c or c.kind ~= "country" then return end
        engine({ type = "lock_bypass", id = ctx.this.id, country = c.id, duration = num_of(p.duration, ctx) })
    end
    EFF["renew_bypass_lock"] = function(e, ctx)
        if kind_is(ctx, "bypass") and e.value.text == "yes" then engine({ type = "lock_bypass", id = ctx.this.id, renew = true }) end
    end
    EFF["upgrade_megastructure_to"] = function(e, ctx)
        if kind_is(ctx, "megastructure") and e.value.text then
            engine({ type = "upgrade_megastructure", id = ctx.this.id, to = unq(e.value.text) })
        end
    end
    EFF["finish_upgrade"] = function(e, ctx)
        if kind_is(ctx, "megastructure") and e.value.text == "yes" then
            engine({ type = "upgrade_megastructure", id = ctx.this.id, finish = true })
        end
    end
    EFF["set_halted"] = function(e, ctx)
        local d = num_of(e, ctx)
        if kind_is(ctx, "megastructure") and d then engine({ type = "set_halted", id = ctx.this.id, days = d }) end
    end
    EFF["set_overclock"] = function(e, ctx)
        if not kind_is(ctx, "megastructure") then return end
        local oc, cooldown = e.value.text and unq(e.value.text), true
        if not oc then
            local p = params(e)
            oc, cooldown = text_of(p.overclock), O.yes_of(p.cooldown, true)
        end
        if oc then engine({ type = "set_overclock", id = ctx.this.id, overclock = oc, cooldown = cooldown }) end
    end
    -- set_owner of a megastructure (the other scopes: the handlers before this one)
    local prev_owner = EFF["set_owner"]
    EFF["set_owner"] = function(e, ctx, lk)
        if kind_is(ctx, "megastructure") then
            local t = target(e, ctx)
            local c = t and (t.kind == "country" and t.id or nil)
            if c then engine({ type = "set_megastructure_owner", id = ctx.this.id, country = c }) end
            return
        end
        if prev_owner then return prev_owner(e, ctx, lk) end
    end

    -- the graphical side
    local function fields_of(ctx)
        local r = rt()
        local sc = ctx.this
        if sc.kind == "fleet" then return "ship", r and r.fleet_ships(sc.id) or {} end
        if sc.kind == "starbase" then
            local s = obj("starbase", sc.id)
            local st = s and ref(world.field(s, "station"))
            return "ship", { st }
        end
        return sc.kind, { sc.id }
    end
    EFF["set_graphical_culture"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or not e.value.text then return end
        local kinds = { megastructure = true, country = true, ship = true, fleet = true, starbase = true }
        if not kinds[sc.kind] then return end
        sync()
        local store, ids = fields_of(ctx)
        engine({ type = "set_object_field", store = store, ids = ids, key = "graphical_culture", value = unq(e.value.text), quoted = true })
    end
    EFF["set_animation_state"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or not e.value.text or not ({ megastructure = true, ship = true, fleet = true })[sc.kind] then return end
        sync()
        local store, ids = fields_of(ctx)
        engine({ type = "set_object_field", store = store, ids = ids, key = "animation_state", value = unq(e.value.text), quoted = true })
    end
    EFF["trigger_megastructure_icon"] = function(e, ctx)
        if not kind_is(ctx, "planet") then return end
        engine({ type = "set_object_field", store = "planet", id = ctx.this.id, key = "trigger_megastructure_icon",
            value = e.value.text == "no" and "no" or "yes" })
    end

    -- colonies, sectors
    EFF["set_system_locked"] = function(e, ctx)
        local r = rt()
        if not r or ctx.this == NONE then return end
        sync()
        local kind, id = r.carrier_of(ctx.this.kind, ctx.this.id)
        if not kind then return end
        engine({ type = "set_object_field", store = kind, id = id, key = "system_locked", value = e.value.text == "no" and "no" or "yes" })
    end
    local function colony_and_system(ctx)
        local r = rt()
        if not r or ctx.this == NONE then return nil end
        sync()
        local col = r.colony_of(ctx.this.kind, ctx.this.id)
        return col, system_of(ctx.this)
    end
    EFF["set_sector_capital"] = function(e, ctx)
        if e.value.text ~= "yes" then return end
        local col, sid = colony_and_system(ctx)
        local s = sid and obj("system", sid)
        local sec = s and ref(world.field(s, "sector"))
        if col and sec then engine({ type = "set_sector_capital", sector = sec, colony = col }) end
    end
    EFF["create_sector"] = function(e, ctx)
        if e.value.text ~= "yes" then return end
        local col, sid = colony_and_system(ctx)
        local r = rt()
        local owner = sid and r.system_owner(sid)
        if col and owner then engine({ type = "create_sector", system = sid, colony = col, owner = owner }) end
    end
    -- add_planet_devastation = n: the planet's `devastation` (0..100 [I])
    EFF["add_planet_devastation"] = function(e, ctx)
        local r = rt()
        local n = num_of(e, ctx)
        if not r or not n or ctx.this == NONE then return end
        sync()
        local kind, id = r.carrier_of(ctx.this.kind, ctx.this.id)
        local p = kind == "planet" and obj("planet", id)
        if not p then return end
        local v = math.max(0, math.min(100, (tonumber(world.field(p, "devastation")) or 0) + n))
        engine({ type = "set_object_field", store = "planet", id = id, key = "devastation", value = v })
    end

    -- psionic auras
    local function aura_effect(op, e, ctx)
        if not kind_is(ctx, "system") then return end
        local t = { type = "psionic_aura", op = op, system = ctx.this.id }
        if op == "spawn" then
            -- { country } (the documentation) or { owner type } (vanillas: the auras type)
            local p = params(e)
            local c = tgt_of(p.country or p.owner, ctx)
            if not c or c.kind ~= "country" then return end
            t.country, t.aura_type = c.id, text_of(p.type)
        elseif op == "set" or op == "add" then
            t.value = num_of(e, ctx)
            if not t.value then return end
        elseif e.value.text ~= "yes" then
            return
        end
        engine(t)
    end
    EFF["spawn_psionic_aura"] = function(e, ctx) aura_effect("spawn", e, ctx) end
    EFF["destroy_psionic_aura"] = function(e, ctx) aura_effect("destroy", e, ctx) end
    EFF["set_aura_intensity"] = function(e, ctx) aura_effect("set", e, ctx) end
    EFF["add_aura_intensity"] = function(e, ctx) aura_effect("add", e, ctx) end

    -- -----------------------------------------------------------------------------------------
    -- batch 3: the owner of a bypass, stations, nebulas, systems made or moved, debris

    -- owner (a bypass): the owner of its holder, a megastructure's `owner`, else its system's owner
    -- [I]; the other scopes: the link before this one (installed only over one: an owner resolved
    -- elsewhere is not shadowed)
    local prev_owner_link = LINKS["owner"]
    if prev_owner_link then LINKS["owner"] = function(cur, ctx)
        if cur ~= NONE and cur.kind == "bypass" then
            local b = obj("bypass", cur.id)
            local o = b and world.field(b, "owner")
            local c
            if type(o) == "table" and tonumber(world.field(o, "type")) == 6 then
                local m = obj("megastructure", ref(world.field(o, "id")))
                c = m and ref(world.field(m, "owner"))
            end
            if not c then
                local r = rt()
                local sid = bypass_system(cur.id)
                c = r and sid and r.system_owner(sid)
            end
            return (c and obj("country", c)) and S("country", c) or nil
        end
        return prev_owner_link(cur, ctx)
    end end

    local function country_param(x, ctx)
        local t = tgt_of(x, ctx)
        return t and t.kind == "country" and t.id or nil
    end
    -- the planet a station goes to: a planet's (a colony's carrier), a system's star
    local function station_planet(ctx)
        local r = rt()
        if not r or ctx.this == NONE then return nil end
        sync()
        if ctx.this.kind == "system" then return r.star_planet(ctx.this.id) end
        local kind, id = r.carrier_of(ctx.this.kind, ctx.this.id)
        return kind == "planet" and id or nil
    end
    -- create_starbase = { owner size design module building effect } (a planet, a system: its
    -- star): the effect runs in the new starbase
    EFF["create_starbase"] = function(e, ctx)
        local p = params(e)
        local c = country_param(p.owner, ctx)
        local pid = station_planet(ctx)
        if not c or not pid then return end
        local h = E.new_handle()
        engine({ type = "create_starbase", country = c, planet = pid, size = text_of(p.size), design = text_of(p.design),
            module = text_of(p.module), building = text_of(p.building), handle = h })
        local id = E.resolve(h)
        if id and p.effect and p.effect.value.text == nil then eval.effect(p.effect.value, I.push(ctx, S("starbase", id))) end
    end
    -- create_mining_station = { owner } (a planet; an astral rift has no orbital station here)
    EFF["create_mining_station"] = function(e, ctx)
        if ctx.this == NONE or ctx.this.kind == "astral_rift" then return end
        local c = country_param(params(e).owner, ctx)
        local pid = station_planet(ctx)
        if c and pid then engine({ type = "create_mining_station", country = c, planet = pid }) end
    end
    -- create_nebula = { name radius effect } (a system): the effect in every system of the nebula
    EFF["create_nebula"] = function(e, ctx)
        if not kind_is(ctx, "system") then return end
        local p = params(e)
        local radius = num_of(p.radius, ctx) or 100
        local t = { type = "create_nebula", id = ctx.this.id, name = text_of(p.name), radius = radius }
        engine(t)
        if t.systems and p.effect and p.effect.value.text == nil then
            for _, sid in ipairs(t.systems) do eval.effect(p.effect.value, I.push(ctx, S("system", sid))) end
        end
    end

    -- the place of a moved or spawned system: a system min_jumps..max_jumps from the scope's (one
    -- drawn), then min_distance..max_distance from it at a drawn angle [I]; no system (no_scope):
    -- the galaxy's centre
    local function place(p, ctx)
        local r = rt()
        local base = system_of(ctx.this)
        local x, y = 0, 0
        if base and r then
            local lo, hi = num_of(p.min_jumps, ctx) or 0, num_of(p.max_jumps, ctx) or 0
            local dist, queue, at = { [base] = 0 }, { base }, {}
            local i = 1
            while queue[i] do
                local s = queue[i]
                i = i + 1
                if dist[s] >= lo and dist[s] <= hi then at[#at + 1] = s end
                if dist[s] < hi then
                    for _, n in ipairs(r.hyperlanes(s)) do
                        if dist[n] == nil then
                            dist[n] = dist[s] + 1
                            queue[#queue + 1] = n
                        end
                    end
                end
            end
            local pick = #at > 0 and at[math.min(#at, math.floor(eval.rand() * #at) + 1)] or base
            x, y = coord(pick)
        end
        local dmin, dmax = num_of(p.min_distance, ctx) or 0, num_of(p.max_distance, ctx) or 0
        local d = dmin + eval.rand() * math.max(0, dmax - dmin)
        local a = eval.rand() * 2 * math.pi
        return (x or 0) + d * math.cos(a), (y or 0) + d * math.sin(a)
    end
    -- move_system = { target min_jumps max_jumps min_distance max_distance hyperlane
    -- reset_terra_incognita } (a system): placed relative to the target's system
    EFF["move_system"] = function(e, ctx)
        if not kind_is(ctx, "system") then return end
        local p = params(e)
        local t = tgt_of(p.target, ctx)
        if not t then return end
        sync()
        local x, y = place(p, I.push(ctx, t))
        engine({ type = "move_system", id = ctx.this.id, x = x, y = y, hyperlane = O.yes_of(p.hyperlane, false) })
    end
    -- spawn_system = { min_jumps max_jumps min_distance max_distance initializer hyperlane
    -- is_discovered } (relative to the scope): the initializer's star class (`class`; random or
    -- none: drawn by the star classes' spawn_odds [I]); last_created_system
    I.CREATED_KIND.system = I.CREATED_KIND.system or "system"
    EFF["spawn_system"] = function(e, ctx)
        local p = params(e)
        sync()
        local x, y = place(p, ctx)
        local defs = require("engine.defs")
        local init = text_of(p.initializer)
        local d = init and init ~= "random" and defs.get("common/solar_system_initializers", init)
        local cls = d and unq(defs.field(d.block, "class"))
        local name = d and defs.field(d.block, "name")
        if not cls or cls == "random" or not defs.get("common/star_classes", cls) then
            local pool, total = {}, 0
            for k, sd in pairs(defs.folder("common/star_classes")) do
                local w = tonumber(defs.field(sd.block, "spawn_odds")) or 0
                if w > 0 then
                    pool[#pool + 1] = { k, w }
                    total = total + w
                end
            end
            table.sort(pool, function(a, b) return a[1] < b[1] end)
            local roll = eval.rand() * total
            for _, v in ipairs(pool) do
                roll = roll - v[2]
                if roll <= 0 then cls = v[1] break end
            end
        end
        local h = E.new_handle()
        engine({ type = "spawn_system", x = x, y = y, star_class = cls, initializer = init,
            name = type(name) == "string" and unq(name) or nil, hyperlane = O.yes_of(p.hyperlane, true), handle = h })
        if E.resolve(h) then O.created(ctx, "system", h) end
    end

    -- spawn_custom_debris = { for should_add_ship_to_debris must_scavenge must_reanimate
    -- must_research reset_killed_ship_designs reset_killed_ship_stockpile } (a fleet): a debris of
    -- the fleet's ships the trigger holds for (all without one), for the country
    EFF["spawn_custom_debris"] = function(e, ctx)
        local r = rt()
        if not r or not kind_is(ctx, "fleet") then return end
        local p = params(e)
        local c = country_param(p["for"], ctx)
        if not c then return end
        sync()
        local ships = {}
        for _, sid in ipairs(r.fleet_ships(ctx.this.id)) do
            local cond = p.should_add_ship_to_debris
            if not cond or cond.value.text ~= nil or eval.trigger(cond.value, I.push(ctx, S("ship", sid))) then
                ships[#ships + 1] = sid
            end
        end
        engine({ type = "spawn_debris", fleet = ctx.this.id, country = c, ships = ships,
            must_scavenge = O.yes_of(p.must_scavenge, false), must_reanimate = O.yes_of(p.must_reanimate, false),
            must_research = O.yes_of(p.must_research, false) })
    end
    -- destroy_and_spawn_debris_for = <country> (a ship or a fleet): its debris, then it is destroyed
    EFF["destroy_and_spawn_debris_for"] = function(e, ctx)
        local r = rt()
        local t = target(e, ctx)
        if not r or not t or t.kind ~= "country" or ctx.this == NONE then return end
        sync()
        if ctx.this.kind == "ship" then
            local fid = r.ship_fleet(ctx.this.id)
            if fid then
                engine({ type = "spawn_debris", fleet = fid, ship = ctx.this.id, country = t.id, ships = { ctx.this.id }, destroy = true })
            end
        elseif ctx.this.kind == "fleet" then
            engine({ type = "spawn_debris", fleet = ctx.this.id, country = t.id, ships = r.fleet_ships(ctx.this.id), destroy = true })
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- values (complex_trigger_modifier's `trigger = <name> parameters = { }`: eval.TVAL, e.value the
    -- parameter block): the number each trigger compares

    if eval.TVAL then
        eval.TVAL["count_starbase_modules"] = function(ctx, e) return item_counts["count_starbase_modules"](e.value, ctx) end
        eval.TVAL["count_starbase_buildings"] = function(ctx, e) return item_counts["count_starbase_buildings"](e.value, ctx) end
        eval.TVAL["num_neighbor_systems"] = function(ctx, e) return neighbor_count(e.value, ctx) end
        eval.TVAL["total_system_workforce_with_job_tag"] = function(ctx, e) return workforce_total(e.value, ctx) end
        eval.TVAL["governors_skill_in_system"] = function(ctx, e) return governors_skill(e.value, ctx) end
        eval.TVAL["num_galaxy_systems"] = function()
            sync()
            return #all("system")
        end
        -- check_modifier_value (`modifier`): the scope's modifier value, as the trigger reads it
        -- (E.modifier, the graph brought up to date first: engine.script.objects.fresh)
        eval.TVAL["check_modifier_value"] = eval.TVAL["check_modifier_value"] or function(ctx, e)
            local name = type(e.value) == "table" and param(e.value, "modifier")
            if not name or type(name) ~= "string" or ctx.this == NONE or not (E and E.modifier) then return nil end
            sync()
            local objects = require("engine.script.objects")
            if objects.fresh then objects.fresh() end
            return E.modifier(ctx.this.kind, ctx.this.id, name) or 0
        end
    end
end
