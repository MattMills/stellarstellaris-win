-- simscript/handlers/planet_effects.lua : the planet package's effects (loaded by
-- handlers/planet.lua). Each writes the world (engine.world) in its scope's colony or planet, as
-- the effect class's Execute does in the 4.5.2 Linux binary ([V] read there, [I] inferred; the
-- notes: /root/wp/re_script.md on .24).

return function(eval, H)
    local I = eval._internal
    local EFF = eval.EFF
    local S, NONE, sync, yes = I.S, I.NONE, I.sync, I.yes
    local world = H.world
    local ref, unq, ids, params, target = H.ref, H.unq, H.ids, H.params, H.target
    local defs = require("engine.defs")
    local objects = require("engine.script.objects")
    local colony = objects.colony or require("engine.script.objects_colony")
    local stats = { written = 0 }
    H.effect_stats = stats
    -- an engine effect queued (as handlers/objects.lua's push: counted, E.push)
    local function push(t)
        I.stats.engine = I.stats.engine + 1
        I.E.push(t)
    end

    local function def(folder, key)
        local d = key and defs.get(folder, key)
        return d and d.block or nil
    end
    local function dfield(block, key)
        return block and defs.field(block, key) or nil
    end
    local function names(block, key)
        local out = {}
        local l = block and defs.field(block, key)
        for _, x in ipairs(type(l) == "table" and l or {}) do
            if x.text then out[#out + 1] = unq(x.text) end
        end
        return out
    end
    -- the scope's planet and colony (sync first: what earlier statements pushed is applied)
    local function scope_colony(ctx)
        sync()
        local c, cid, pid = H.colony_obj(ctx.this)
        return c, cid, pid
    end
    local function scope_planet(ctx)
        sync()
        local p, pid = H.planet_obj(ctx.this)
        return p, pid
    end
    -- one draw of the game's generator (objects.draw: the script objects' stream)
    local function draw()
        return objects.draw and objects.draw() or I.E.rand()
    end
    local function on_action(name, ...)
        if objects.on_action then pcall(objects.on_action, name, ...) end
    end

    -- the colony's buildings in the order of its buildings_cache: { id, block, zone block }
    local function buildings(c)
        local zone_of = {}
        for _, did in ipairs(ids(world.field(c, "districts"))) do
            local d = world.object("districts", did)
            for _, z in ipairs(ids(d and world.field(d, "zones"))) do
                local zb = world.object("zones", z)
                for _, b in ipairs(ids(zb and world.field(zb, "buildings"))) do zone_of[b] = zb end
            end
        end
        local out = {}
        for _, b in ipairs(ids(world.field(c, "buildings_cache"))) do
            local bb = world.object("buildings", b)
            if bb then out[#out + 1] = { id = b, block = bb, zone = zone_of[b] } end
        end
        return out
    end
    H.buildings = buildings
    -- a building out of its zone and the store, the zone's positions renumbered
    local function remove_building(c, b)
        if b.zone then
            local bl = world.field(b.zone, "buildings")
            world.remove_value(bl, tostring(b.id))
            world.remove_value(bl, b.id)
            for i, x in ipairs(ids(bl)) do
                local xb = world.object("buildings", x)
                if xb then world.set(xb, "position", i - 1) end
            end
        end
        world.remove("buildings", b.id)
    end
    local function is_capital_building(btype)
        return dfield(def("common/buildings", btype), "capital") == "yes"
    end
    local function done(c)
        colony.rebuild_cache(c)
        stats.written = stats.written + 1
    end

    -- -----------------------------------------------------------------------------------------
    -- buildings

    -- remove_all_buildings = yes (CRemoveAllBuildingsEffect): every building of the colony
    EFF["remove_all_buildings"] = function(e, ctx)
        if not yes(e) then return end
        local c = scope_colony(ctx)
        if not c then return end
        for _, b in ipairs(buildings(c)) do remove_building(c, b) end
        done(c)
    end
    -- remove_random_building = yes (CRemoveLastBuiltBuildingEffect, a planet: CColony::
    -- RemoveRandomBuilding): one of the colony's non-capital buildings (weight 1 each, a capital
    -- 0), picked with a draw of the game's generator [V]
    EFF["remove_random_building"] = function(e, ctx)
        if not yes(e) or ctx.this.kind ~= "planet" then return end
        local c = scope_colony(ctx)
        if not c then return end
        local cands = {}
        for _, b in ipairs(buildings(c)) do
            if not is_capital_building(unq(world.field(b.block, "type"))) then cands[#cands + 1] = b end
        end
        if #cands == 0 then return end
        remove_building(c, cands[draw() % #cands + 1])
        done(c)
    end
    -- the colony's first building of a type (or, for random_no_capital, a random non-capital one)
    local function building_of_type(c, btype, pred)
        for _, b in ipairs(buildings(c)) do
            if unq(world.field(b.block, "type")) == btype and (not pred or pred(b)) then return b end
        end
    end
    -- disable_building = <type> (CDisableBuildingEffect): one enabled building of the type
    -- disabled (`disabled = yes`)
    EFF["disable_building"] = function(e, ctx)
        local c = scope_colony(ctx)
        local b = c and e.value.text and building_of_type(c, e.value.text, function(x) return world.field(x.block, "disabled") ~= "yes" end)
        if not b then return end
        world.set(b.block, "disabled", "yes")
        done(c)
    end
    -- ruin_building = <type> | random_no_capital (CRuinBuildingEffect): one building ruined
    -- (`ruined = yes`); random_no_capital: one of the non-capital ones, picked with a draw
    EFF["ruin_building"] = function(e, ctx)
        local c = scope_colony(ctx)
        local v = e.value.text
        if not c or not v then return end
        local b
        if v == "random_no_capital" then
            local cands = {}
            for _, x in ipairs(buildings(c)) do
                if world.field(x.block, "ruined") ~= "yes" and not is_capital_building(unq(world.field(x.block, "type"))) then
                    cands[#cands + 1] = x
                end
            end
            if #cands == 0 then return end
            -- (SRuinBuildingImpl::GetRandomBuilding: the scope's own random state) [V]
            local r = eval.scope_draw and eval.scope_draw(ctx) or draw()
            b = cands[r % #cands + 1]
        else
            b = building_of_type(c, v, function(x) return world.field(x.block, "ruined") ~= "yes" end)
        end
        if not b then return end
        world.set(b.block, "ruined", "yes")
        done(c)
    end
    -- repair_building = <type> (CRepairBuildingEffect): one ruined building of the type repaired;
    -- repair_all_buildings = yes: every one
    local function repair(b)
        local en = world.entry(b.block, "ruined")
        if en then world.remove_entry(b.block, en) end
    end
    -- (CColony::RepairBuildingType: SetRuined(false), the type's OnRepaired, two draws [V])
    EFF["repair_building"] = function(e, ctx)
        local c = scope_colony(ctx)
        local b = c and e.value.text and building_of_type(c, e.value.text, function(x) return world.field(x.block, "ruined") == "yes" end)
        if not b then return end
        repair(b)
        draw()
        draw()
        done(c)
    end
    EFF["repair_all_buildings"] = function(e, ctx)
        if not yes(e) then return end
        local c = scope_colony(ctx)
        if not c then return end
        local any = false
        for _, b in ipairs(buildings(c)) do
            if world.field(b.block, "ruined") == "yes" then
                repair(b)
                draw()
                any = true
            end
        end
        if any then done(c) end
    end

    -- the building a type upgrades from (the one listing it in `upgrades`)
    local upgraded_from
    local function predecessor(btype)
        if not upgraded_from then
            upgraded_from = {}
            for name, d in pairs(defs.folder("common/buildings") or {}) do
                for _, u in ipairs(names(d.block, "upgrades")) do
                    upgraded_from[u] = upgraded_from[u] or name
                end
            end
        end
        return upgraded_from[btype]
    end
    H.predecessor = predecessor
    -- a colony block's planet (scope_colonies records it)
    local planet_of_block = setmetatable({}, { __mode = "k" })
    -- the planets of a planet or a country scope (a country: its colonies)
    local function scope_colonies(ctx)
        sync()
        local sc = ctx.this
        local out = {}
        for _, pid in ipairs(sc ~= NONE and H.colonies_under(sc) or {}) do
            local cid = H.colony_of_planet(pid)
            local c = cid and world.object("colony", cid)
            if c then
                out[#out + 1] = c
                planet_of_block[c] = pid
            end
        end
        return out
    end
    -- CColony::DowngradeBuilding: the lower tier in its place (ReplaceBuilding; the refund **[I]**
    -- not ported), two draws, on_building_downgraded (this = the colony's planet) [V]
    local function downgrade(c, b, prev)
        world.set(b.block, "type", '"' .. prev .. '"')
        draw()
        draw()
        local pid = planet_of_block[c]
        if pid then on_action("on_building_downgraded", eval.S("planet", pid)) end
    end
    -- downgrade_all_buildings = yes (a planet or a country: CDowngradeAllBuildingsEffect): every
    -- non-capital building with a predecessor becomes it (tier 1 buildings stay)
    EFF["downgrade_all_buildings"] = function(e, ctx)
        if not yes(e) then return end
        for _, c in ipairs(scope_colonies(ctx)) do
            local any = false
            for _, b in ipairs(buildings(c)) do
                local t = unq(world.field(b.block, "type"))
                local prev = predecessor(t)
                if prev and not is_capital_building(t) then
                    downgrade(c, b, prev)
                    any = true
                end
            end
            if any then done(c) end
        end
    end
    -- downgrade_buildings_of_type = <type> (CDowngradeBuildingsOfTypeEffect: only the buildings
    -- of the given type [V]; the docs' `= yes` names no type, so nothing)
    EFF["downgrade_buildings_of_type"] = function(e, ctx)
        local want = e.value.text
        if not want then return end
        for _, c in ipairs(scope_colonies(ctx)) do
            local any = false
            for _, b in ipairs(buildings(c)) do
                local t = unq(world.field(b.block, "type"))
                local prev = predecessor(t)
                if prev and t == want and not is_capital_building(t) then
                    downgrade(c, b, prev)
                    any = true
                end
            end
            if any then done(c) end
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- districts and zones

    -- remove_all_districts = yes (CRemoveAllDistrictsEffect): every district with its zones and
    -- their buildings
    EFF["remove_all_districts"] = function(e, ctx)
        if not yes(e) then return end
        local c = scope_colony(ctx)
        if not c then return end
        local dl = world.field(c, "districts")
        for _, did in ipairs(ids(dl)) do
            local d = world.object("districts", did)
            for _, z in ipairs(ids(d and world.field(d, "zones"))) do
                local zb = world.object("zones", z)
                for _, b in ipairs(ids(zb and world.field(zb, "buildings"))) do world.remove("buildings", b) end
                world.remove("zones", z)
            end
            world.remove("districts", did)
        end
        if type(dl) == "table" then world.replace(dl, {}) end
        done(c)
    end
    -- remove_random_district = yes (CRemoveRandomDistrictEffect): one level of a district, the
    -- type picked with a draw weighted by its level ("bigger district is more likely") [I the
    -- weights]; remove_district's applier removes it
    EFF["remove_random_district"] = function(e, ctx)
        if not yes(e) then return end
        local c, cid, pid = scope_colony(ctx)
        if not c then return end
        local cands, total = {}, 0
        for _, did in ipairs(ids(world.field(c, "districts"))) do
            local d = world.object("districts", did)
            local lvl = d and tonumber(world.field(d, "level")) or 0
            if lvl > 0 then
                cands[#cands + 1] = { unq(world.field(d, "type")), lvl }
                total = total + lvl
            end
        end
        if total == 0 then return end
        local r = draw() % total
        local pick
        for _, x in ipairs(cands) do
            if r < x[2] then pick = x[1] break end
            r = r - x[2]
        end
        push({ type = "remove_district", kind = "planet", id = pid, district = pick or cands[#cands][1] })
        sync()
    end
    -- remove_zone = { district zone zone_slot all } (CRemoveZoneEffect): the district (a type, or
    -- a slot index of the colony's districts), the zone in its slot (or, all = yes, every zone of
    -- the type) taken out with its buildings, the slot left empty (4294967295)
    EFF["remove_zone"] = function(e, ctx)
        local c = scope_colony(ctx)
        if not c then return end
        local p = params(e)
        local dsel = p.district and p.district.value.text
        local ztype = p.zone and unq(p.zone.value.text)
        local slot = p.zone_slot and tonumber(eval.value(p.zone_slot.value, ctx, p.zone_slot))
        local all = p.all and p.all.value.text == "yes"
        local dlist = ids(world.field(c, "districts"))
        local targets = {}
        if tonumber(dsel) then
            targets[1] = dlist[tonumber(dsel) + 1]
        else
            for _, did in ipairs(dlist) do
                local d = world.object("districts", did)
                if d and (not dsel or unq(world.field(d, "type")) == dsel) then targets[#targets + 1] = did end
            end
        end
        local any = false
        for _, did in ipairs(targets) do
            local d = world.object("districts", did)
            local zl = d and world.field(d, "zones")
            for i, x in ipairs(type(zl) == "table" and zl or {}) do
                local zid = x.text and ref(x.text)
                local zb = zid and world.object("zones", zid)
                local hit = zb and (not ztype or unq(world.field(zb, "type")) == ztype)
                    and (all or slot == nil or slot == i - 1)
                if hit then
                    for _, b in ipairs(ids(world.field(zb, "buildings"))) do world.remove("buildings", b) end
                    world.remove("zones", zid)
                    world.set_entry(zl, x, tostring(H.NO_ID))
                    any = true
                    if not all then break end
                end
            end
            if any and not all then break end
        end
        if any then done(c) end
    end

    -- validate_planet_buildings_and_districts = yes (CValidatePlanetBuildingsAndDistrictsEffect):
    -- buildings and districts whose `potential` no longer holds removed (a building with a
    -- `convert_to` that holds converted [I: removed here]); validate_and_repair_...: then every
    -- ruined building repaired
    local function holds(block, pid)
        local t = block and defs.field(block, "potential")
        if type(t) ~= "table" then return true end
        local ok, r = pcall(eval.trigger, t, eval.new_ctx(S("planet", pid)))
        return not ok or r == true
    end
    local function validate(c, pid)
        local any = false
        for _, b in ipairs(buildings(c)) do
            local bd = def("common/buildings", unq(world.field(b.block, "type")))
            if bd and not holds(bd, pid) then
                remove_building(c, b)
                any = true
            end
        end
        for _, did in ipairs(ids(world.field(c, "districts"))) do
            local d = world.object("districts", did)
            local dd = d and def("common/districts", unq(world.field(d, "type")))
            if dd and not holds(dd, pid) then
                push({ type = "remove_district", kind = "planet", id = pid, district = unq(world.field(d, "type")) })
                any = true
            end
        end
        sync()
        return any
    end
    EFF["validate_planet_buildings_and_districts"] = function(e, ctx)
        if not yes(e) then return end
        local c, _, pid = scope_colony(ctx)
        if c and validate(c, pid) then done(c) end
    end
    EFF["validate_and_repair_planet_buildings_and_districts"] = function(e, ctx)
        if not yes(e) then return end
        local c, _, pid = scope_colony(ctx)
        if not c then return end
        validate(c, pid)
        for _, b in ipairs(buildings(c)) do
            if world.field(b.block, "ruined") == "yes" then repair(b) end
        end
        done(c)
    end
    -- -----------------------------------------------------------------------------------------
    -- the second batch (the notes: /root/wp/re_script.md on .24, "Effects")

    local countries = require("engine.script.objects_countries")
    local systems = require("engine.systems")
    local function today_days() return H.today and H.today() or 0 end
    local function date_text(days)
        local y = math.floor(days / 360)
        local r = days % 360
        return string.format("%d.%02d.%02d", y, math.floor(r / 30) + 1, r % 30 + 1)
    end
    local function key_block(text)
        local b = {}
        world.append(b, "key", text, true)
        return b
    end
    local function target_country(x, ctx)
        local t = x and x.value and x.value.text and select(2, eval.resolve(x.value.text, ctx, x))
        if not t or t == NONE then return nil end
        if t.kind == "country" then return t.id end
        local _, o = eval.resolve("owner", eval.push(ctx, t), nil)
        return o and o ~= NONE and o.kind == "country" and o.id or nil
    end
    local function written()
        stats.written = stats.written + 1
    end
    local function set_bit(p, bit, on)
        local f = tonumber(world.field(p, "binary_flags")) or 0
        local has = math.floor(f / 2 ^ bit) % 2 == 1
        if has == on then return false end
        world.set(p, "binary_flags", on and f + 2 ^ bit or f - 2 ^ bit)
        return true
    end

    -- -----------------------------------------------------------------------------------------
    -- the planet

    -- set_planet_name = "name" (CSetPlanetNameEffect, a planet): the planet's `name`
    EFF["set_planet_name"] = function(e, ctx)
        local p = scope_planet(ctx)
        if not p or ctx.this.kind ~= "planet" or not e.value.text then return end
        local nb = world.field(p, "name")
        if type(nb) ~= "table" then
            local x = world.entry(p, "name")
            if x then world.remove_entry(p, x) end
            nb = world.child(p, "name")
        end
        world.replace(nb, {})
        world.append(nb, "key", unq(e.value.text), true)
        written()
    end
    -- set_planet_size = n (CSetPlanetSizeEffect): `planet_size`, no clamp, nothing recalculated
    EFF["set_planet_size"] = function(e, ctx)
        local p = scope_planet(ctx)
        if not p then return end
        local n = math.floor(eval.value(e.value, ctx, e))
        world.set(p, "planet_size", n)
        written()
    end
    -- set_ring = yes/no (CSetRingEffect): bit 8 of the planet's flags
    EFF["set_ring"] = function(e, ctx)
        local p = scope_planet(ctx)
        if not p then return end
        if set_bit(p, 8, yes(e)) then written() end
    end
    -- clear_planet_modifiers = yes (CClearPlanetModifiersEffect): the planet's modifiers
    -- (`planet_modifier`) and their timed items gone
    local function clear_planet_modifiers(p, pid)
        local names = {}
        for i = #p, 1, -1 do
            local x = p[i]
            if x.op and x.key and x.key.text == "planet_modifier" then
                names[#names + 1] = unq(x.value.text)
                world.remove_entry(p, x)
            end
        end
        for _, n in ipairs(names) do
            pcall(systems.effects.remove_timed_modifier, { kind = "planet", id = pid, modifier = n })
        end
        return #names
    end
    EFF["clear_planet_modifiers"] = function(e, ctx)
        if not yes(e) then return end
        local p, pid = scope_planet(ctx)
        if not p then return end
        if clear_planet_modifiers(p, pid) > 0 then written() end
    end
    -- reroll_planet_modifiers = yes (CRerollPlanetModifiersEffect: CPlanet::
    -- RebuildPlanetModifiers): cleared, then RandomizePlanetModifiers: a weighted pick among the
    -- planet modifiers whose potential holds (their spawn_chance in the planet's scope), again
    -- while the pick is not pm_null, at most three [I the loop's bound]
    EFF["reroll_planet_modifiers"] = function(e, ctx)
        if not yes(e) then return end
        local p, pid = scope_planet(ctx)
        if not p then return end
        clear_planet_modifiers(p, pid)
        local sc = eval.new_ctx(S("planet", pid))
        for _ = 1, 3 do
            local cands, total = {}, 0
            for name, d in pairs(defs.folder("common/planet_modifiers") or {}) do
                local pot = defs.field(d.block, "potential")
                local ok = type(pot) ~= "table" or eval.trigger(pot, sc)
                local sp = defs.field(d.block, "spawn_chance")
                if ok and type(sp) == "table" then
                    local w = math.max(0, eval.weight(sp, sc, 0))
                    if w > 0 then
                        cands[#cands + 1] = { name, w }
                        total = total + w
                    end
                end
            end
            if total <= 0 then break end
            table.sort(cands, function(a, b) return a[1] < b[1] end)
            local r = (draw() % 1000000) / 1000000 * total
            local pick
            for _, x in ipairs(cands) do
                if r < x[2] then pick = x[1] break end
                r = r - x[2]
            end
            pick = pick or cands[#cands][1]
            if pick == "pm_null" then break end
            world.append(p, "planet_modifier", pick, true)
        end
        written()
    end

    -- the deposit types of a category (not blockers) whose potential holds, weighted by their
    -- drop_weight in the planet's scope
    local function deposit_candidates(pid, pred)
        local sc = eval.new_ctx(S("planet", pid))
        local out, total = {}, 0
        for name, d in pairs(defs.folder("common/deposits") or {}) do
            if pred(name, d.block) then
                local pot = defs.field(d.block, "potential")
                if type(pot) ~= "table" or eval.trigger(pot, sc) then
                    local dw = defs.field(d.block, "drop_weight")
                    local w = type(dw) == "table" and eval.weight(dw, sc, 0) or 0
                    if w > 0 then
                        out[#out + 1] = { name, w }
                        total = total + w
                    end
                end
            end
        end
        table.sort(out, function(a, b) return a[1] < b[1] end)
        return out, total
    end
    local function pick_weighted(cands, total)
        if total <= 0 then return nil end
        local r = (draw() % 1000000) / 1000000 * total
        for _, x in ipairs(cands) do
            if r < x[2] then return x[1] end
            r = r - x[2]
        end
        return cands[#cands][1]
    end
    local function is_blocker(block)
        local cat = unq(defs.field(block, "category"))
        local cd = cat and def("common/deposit_categories", cat)
        return dfield(cd, "blocker") == "yes"
    end
    -- add_deposit_category_effect = <category> (CAddDepositCategoryEffect, a planet): a random
    -- non-blocker deposit of the category (a draw of the game's generator), add_deposit's applier
    EFF["add_deposit_category_effect"] = function(e, ctx)
        local p, pid = scope_planet(ctx)
        local cat = e.value.text
        if not p or not cat then return end
        local cands, total = deposit_candidates(pid, function(_, b)
            return unq(defs.field(b, "category")) == cat and not is_blocker(b)
        end)
        local t = pick_weighted(cands, total)
        if not t then return end
        push({ type = "add_deposit", kind = "planet", id = pid, deposit = t })
        sync()
    end
    -- reroll_deposits = yes (CRerollDepositsEffect: CColonyCarrier::RandomizeDeposits): the
    -- planet's deposits gone, then COLONY_DEPOSITS_FIXED_BASE (5) + size x 0.2 picks among the
    -- deposit types (non-blockers first, by drop_weight) [I: the game's rolls per category and
    -- district caps are simplified]
    EFF["reroll_deposits"] = function(e, ctx)
        if not yes(e) then return end
        local p, pid = scope_planet(ctx)
        if not p then return end
        local dl = world.field(p, "deposits")
        for _, did in ipairs(ids(dl)) do world.remove("deposit", did) end
        if type(dl) == "table" then world.replace(dl, {}) end
        local n = 5 + math.floor((tonumber(world.field(p, "planet_size")) or 0) * 0.2)
        local cands, total = deposit_candidates(pid, function(_, b) return not is_blocker(b) end)
        for _ = 1, n do
            local t = pick_weighted(cands, total)
            if t then push({ type = "add_deposit", kind = "planet", id = pid, deposit = t }) end
        end
        sync()
        written()
    end

    -- remove_planet = yes (CRemovePlanetEffect: CPlanet::SetToBeKilled): its colony destroyed,
    -- the planet out of its system and the store [I: the game makes a dead planet in its place]
    local destroy_colony
    EFF["remove_planet"] = function(e, ctx)
        if not yes(e) then return end
        local p, pid = scope_planet(ctx)
        if not p then return end
        if H.colony_of_planet(pid) then destroy_colony(pid, false) end
        local sys = tonumber(world.path(p, "coordinate", "origin"))
        local g = sys and world.object("galactic_object", sys)
        if g then
            for i = #g, 1, -1 do
                local x = g[i]
                if x.op and x.key and x.key.text == "planet" and tonumber(x.value.text) == pid then world.remove_entry(g, x) end
            end
        end
        world.remove("planet", pid)
        written()
    end

    -- spawn_planet = { class location orbit_distance orbit_angle size init_effect name }
    -- (CSpawnPlanetEffect, a system): a new planet of the class in the system, at the location's
    -- orbit (orbit_distance and orbit_angle from it), its size, its init effect run on it [I the
    -- coordinates' rules; the name: the class's]
    EFF["spawn_planet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "system" then return end
        sync()
        local pr = params(e)
        local class = pr.class and unq(pr.class.value.text)
        if not class or not def("common/planet_classes", class) then return end
        local g = world.object("galactic_object", sc.id)
        if not g then return end
        local function interval(x, dflt)
            if not x then return dflt end
            if x.value.text then return eval.value(x.value, ctx, x) end
            local lo, hi = 0, 0
            for _, y in ipairs(x.value) do
                if y.op and y.key and y.key.text == "min" then lo = eval.value(y.value, ctx, y) end
                if y.op and y.key and y.key.text == "max" then hi = eval.value(y.value, ctx, y) end
            end
            return lo + (hi - lo) * (draw() % 1000) / 1000
        end
        local dist = interval(pr.orbit_distance, 30)
        local angle = interval(pr.orbit_angle, 0)
        local size = math.floor(interval(pr.size, tonumber(dfield(def("common/planet_classes", class), "entity_scale")) or 10))
        local cx, cy = 0, 0
        local loc = pr.location and pr.location.value.text and select(2, eval.resolve(pr.location.value.text, ctx, pr.location))
        if loc and loc ~= NONE and loc.kind == "planet" then
            local lp = world.object("planet", loc.id)
            cx = tonumber(world.path(lp, "coordinate", "x")) or 0
            cy = tonumber(world.path(lp, "coordinate", "y")) or 0
        end
        local a = math.rad(angle)
        local coord = {}
        world.append(coord, "x", cx + dist * math.cos(a))
        world.append(coord, "y", cy + dist * math.sin(a))
        world.append(coord, "origin", sc.id)
        local blk = {}
        world.append(blk, "name", key_block(pr.name and unq(pr.name.value.text) or class))
        world.append(blk, "planet_class", class, true)
        world.append(blk, "coordinate", coord)
        world.append(blk, "orbit", dist)
        world.append(blk, "planet_size", size)
        world.append(blk, "binary_flags", 64)
        world.append(blk, "deposits", {})
        local pid = objects.create("planet", blk)
        world.append(g, "planet", pid)
        if pr.init_effect and pr.init_effect.value.text == nil then
            eval.effect(pr.init_effect.value, eval.push(ctx, S("planet", pid)))
        end
        ctx.created = ctx.created or {}
        written()
    end

    -- -----------------------------------------------------------------------------------------
    -- the colony

    -- set_colony_type = <type> (CSetColonyTypeEffect: SetManualDesignation): the colony's
    -- manual `designation`
    EFF["set_colony_type"] = function(e, ctx)
        local c = scope_colony(ctx)
        if not c or not e.value.text or not def("common/colony_types", e.value.text) then return end
        world.set(c, "designation", e.value.text)
        for _, x in ipairs(c) do
            if x.op and x.key and x.key.text == "designation" then x.value.quoted = true end
        end
        written()
    end
    -- set_planet_purge_type = <type> / clear_planet_purge_type = yes: the colony's purge type
    -- (CColony +0x118, `purge_type` [I key])
    EFF["set_planet_purge_type"] = function(e, ctx)
        local c = scope_colony(ctx)
        if not c or not e.value.text then return end
        world.set(c, "purge_type", e.value.text)
        written()
    end
    EFF["clear_planet_purge_type"] = function(e, ctx)
        if not yes(e) then return end
        local c = scope_colony(ctx)
        local x = c and world.entry(c, "purge_type")
        if x then
            world.remove_entry(c, x)
            written()
        end
    end
    -- change_colony_foundation_date = n (a planet): `colonize_date` + n days; a date after today:
    -- nothing (logged)
    EFF["change_colony_foundation_date"] = function(e, ctx)
        local p = scope_planet(ctx)
        if not p or ctx.this.kind ~= "planet" then return end
        local d0 = H.days_of and H.days_of(world.field(p, "colonize_date"))
        if not d0 then return end
        local d1 = d0 + math.floor(eval.value(e.value, ctx, e))
        if d1 > today_days() then return end
        world.set(p, "colonize_date", '"' .. date_text(d1) .. '"')
        written()
    end
    -- check_planet_employment = yes (CCheckPlanetEmploymentEffect: CColony::UpdatePopJobs)
    EFF["check_planet_employment"] = function(e, ctx)
        local c, cid = scope_colony(ctx)
        if not c then return end
        local ok, jobs = pcall(require, "engine.jobs")
        if ok and jobs.update then
            pcall(jobs.update, { cid })
            written()
        end
    end
    -- calculate_modifier = yes (CCalculateModifierEffect, a planet or a country): the modifiers
    -- invalidated and recalculated (engine.economy's next read rebuilds them)
    EFF["calculate_modifier"] = function(e, ctx)
        if not yes(e) then return end
        local sc = ctx.this
        if sc == NONE or (sc.kind ~= "planet" and sc.kind ~= "country") then return end
        sync()
        local okc, creation = pcall(require, "engine.script.creation")
        if okc and type(creation) == "table" then creation.modifiers_changed = true end
        local oke, economy = pcall(require, "engine.economy")
        if oke and economy.invalidate then pcall(economy.invalidate, sc.kind == "planet" and "colony" or "country", sc.id) end
        written()
    end

    -- start_colony = { owner species ethos } (CCreateOrStartColonyEffect<SStartColony>): the
    -- carrier owned and controlled by the owner (not if another owns it), colonizing the species
    -- (else the owner's founder species), its anomaly gone
    EFF["start_colony"] = function(e, ctx)
        local p, pid = scope_planet(ctx)
        if not p then return end
        local pr = params(e)
        local owner = target_country(pr.owner, ctx)
        if not owner then return end
        local cur = ref(world.field(p, "owner"))
        if cur and cur ~= owner then return end
        local sp
        if pr.species and pr.species.value.text then
            local _, s = eval.resolve(pr.species.value.text, ctx, pr.species)
            if s and s ~= NONE then sp = s.kind == "species" and s.id or (I.E.species_of and I.E.species_of(s.kind, s.id)) end
        end
        sp = sp or (I.E.founder_species and I.E.founder_species(owner))
        countries.set_planet_owner(pid, owner)
        countries.set_planet_controller(pid, owner)
        local c = world.object("colony", H.colony_of_planet(pid))
        if c and sp then world.set(c, "colonizing_species", sp) end
        local an = world.entry(p, "anomaly")
        if an then world.remove_entry(p, an) end
        written()
    end
    -- add_colony_progress = f (CAddColonyProgressEffect, a planet): f x COLONY_POPS_REQUIRED (100)
    -- pops of the colonizing species added (a colony being colonized); the colonization's end is
    -- the monthly update's
    EFF["add_colony_progress"] = function(e, ctx)
        local c, cid = scope_colony(ctx)
        if not c or ctx.this.kind ~= "planet" then return end
        local sp = ref(world.field(c, "colonizing_species"))
        if not sp then return end
        local n = math.floor(eval.value(e.value, ctx, e) * 100)
        if n <= 0 then return end
        colony.add_pops(cid, sp, n, nil, nil)
        written()
    end
    -- destroy_colony = yes (CDestroyColonyEffect: CPlanet::DestroyColony): on_colony_destroyed
    -- (this = the planet), then the colony gone: its pop groups, districts, zones, buildings and
    -- armies; the planet without owner and controller; the countries' lists and indexes
    destroy_colony = function(pid, fire)
        local cid = H.colony_of_planet(pid)
        local c = cid and world.object("colony", cid)
        local p = world.object("planet", pid)
        if not c or not p then return false end
        if fire ~= false then on_action("on_colony_destroyed", eval.S("planet", pid)) end
        for _, g in ipairs(ids(world.field(c, "pop_groups"))) do world.remove("pop_groups", g) end
        for _, did in ipairs(ids(world.field(c, "districts"))) do
            local d = world.object("districts", did)
            for _, z in ipairs(ids(d and world.field(d, "zones"))) do
                local zb = world.object("zones", z)
                for _, b in ipairs(ids(zb and world.field(zb, "buildings"))) do world.remove("buildings", b) end
                world.remove("zones", z)
            end
            world.remove("districts", did)
        end
        for _, a in ipairs(ids(world.field(c, "army"))) do world.remove("army", a) end
        for _, k in ipairs({ "owner", "controller" }) do
            local who = ref(world.field(p, k))
            local oc = who and world.object("country", who)
            if oc then
                for _, l in ipairs({ "owned_planets", "controlled_colonies" }) do
                    local lb = world.field(oc, l)
                    if type(lb) == "table" then
                        world.remove_value(lb, tostring(cid))
                        world.remove_value(lb, cid)
                    end
                end
                local cp = world.field(oc, "controlled_planets")
                if type(cp) == "table" then
                    world.remove_value(cp, tostring(pid))
                    world.remove_value(cp, pid)
                end
                if world.planets_of and world.planets_of[who] then
                    for i = #world.planets_of[who], 1, -1 do
                        if world.planets_of[who][i] == pid then table.remove(world.planets_of[who], i) end
                    end
                end
            end
            local x = world.entry(p, k)
            if x then world.remove_entry(p, x) end
        end
        local x = world.entry(p, "colony")
        if x then world.remove_entry(p, x) end
        world.remove("colony", cid)
        if world.planet_colony then world.planet_colony[pid] = nil end
        if world.colony_planet then world.colony_planet[cid] = nil end
        if world.pop_groups_of then world.pop_groups_of[pid] = nil end
        return true
    end
    EFF["destroy_colony"] = function(e, ctx)
        if not yes(e) then return end
        local _, _, pid = scope_colony(ctx)
        if pid and destroy_colony(pid) then written() end
    end
    -- conquer = <country> (CConquerEffect, a planet): owner then controller the country
    EFF["conquer"] = function(e, ctx)
        local p, pid = scope_planet(ctx)
        if not p or ctx.this.kind ~= "planet" then return end
        local c = target_country(e, ctx)
        if not c then return end
        countries.set_planet_owner(pid, c)
        countries.set_planet_controller(pid, c)
        written()
    end
    -- create_rebels = { name authority civics species ethos effect } (CCreateRebelsEffect): a new
    -- country (engine countries.create), the colony its capital and its own, rebelling against
    -- the old owner; its `effect` run in it; on_country_created [I: the techs, designs, contacts
    -- and opinions the game copies are not]
    EFF["create_rebels"] = function(e, ctx)
        local c, cid, pid = scope_colony(ctx)
        if not c then return end
        local old = ref(world.field(world.object("planet", pid), "owner"))
        if not old then return end
        local pr = params(e)
        local sp
        if pr.species and pr.species.value.text then
            local _, s = eval.resolve(pr.species.value.text, ctx, pr.species)
            if s and s ~= NONE then sp = s.kind == "species" and s.id or (I.E.species_of and I.E.species_of(s.kind, s.id)) end
        end
        sp = sp or (I.E.founder_species and I.E.founder_species(old))
        local ethos
        if pr.ethos and pr.ethos.value.text == nil then
            ethos = {}
            for _, x in ipairs(pr.ethos.value) do
                if x.op and x.key and x.key.text == "ethic" then ethos[#ethos + 1] = unq(x.value.text) end
            end
        elseif pr.ethos then
            ethos = "random"
        end
        local civics
        if pr.civics and pr.civics.value.text == nil then
            civics = {}
            for _, x in ipairs(pr.civics.value) do
                if x.op and x.key and x.key.text == "civic" then civics[#civics + 1] = unq(x.value.text) end
            end
        end
        local id = countries.create({
            ctype = "default", species = sp, name = pr.name and unq(pr.name.value.text) or "random",
            authority = pr.authority and unq(pr.authority.value.text) or "random", ethos = ethos or "random", civics = civics,
        })
        if not id then return end
        local nc = world.object("country", id)
        countries.set_planet_owner(pid, id)
        countries.set_planet_controller(pid, id)
        world.set(nc, "capital", cid)
        world.set(nc, "rebelling_against", old)
        if pr.effect and pr.effect.value.text == nil then
            eval.effect(pr.effect.value, eval.push(ctx, S("country", id)))
        end
        on_action("on_country_created", eval.S("country", id))
        written()
    end
    -- select_decision = { name } (CSelectPlanetDecisionEffect): a decision whose potential holds
    -- on the colony, enacted later as the command does it (engine/construction_planet: queued as
    -- a decision item when it has an enactment time, else its effect run) [V: posted, not run at
    -- once]
    EFF["select_decision"] = function(e, ctx)
        local c, cid, pid = scope_colony(ctx)
        if not c then return end
        local pr = params(e)
        local name = pr.name and unq(pr.name.value.text)
        local d = name and def("common/decisions", name)
        if not d then return end
        local pot = defs.field(d, "potential")
        if type(pot) == "table" and not eval.trigger(pot, eval.new_ctx(S("planet", pid))) then return end
        local owner = ref(world.field(world.object("planet", pid), "owner"))
        local time = tonumber(defs.field(d, "enactment_time")) or 0
        local queue = ref(world.field(world.object("planet", pid), "build_queue"))
        if time > 0 and queue then
            local orders = require("engine.ai.economy.orders")
            orders.add({ country = owner, colony = cid, queue = queue, kind = "decision",
                fields = { { "decision", name, true }, { "planet", cid } }, cost = {}, cost_order = {}, build_time = time })
        else
            local eff = defs.field(d, "effect")
            if type(eff) == "table" then eval.effect(eff, eval.new_ctx(S("planet", pid), owner and S("country", owner) or nil)) end
        end
        written()
    end

    -- -----------------------------------------------------------------------------------------
    -- terraforming (engine/construction_planet.lua's process on the planet: `terraform_process =
    -- { terraform_type progress total player_started_terraform scripted }`; the game's timed and
    -- scripted processes)

    local cp = require("engine.construction_planet")
    local function process(p)
        local b = world.field(p, "terraform_process")
        return type(b) == "table" and b or nil
    end
    -- the class a start effect names: `class`, a random list (a draw of the scope's random state),
    -- a target planet's class, else the scope species' ideal class
    local function target_class(e, ctx)
        local v
        if e.value.text then
            v = e.value.text
        else
            local pr = params(e)
            v = pr.class and pr.class.value.text
            if not v and pr.class then
                local opts = {}
                for _, x in ipairs(pr.class.value) do
                    if x.text then opts[#opts + 1] = unq(x.text) end
                end
                if #opts > 0 then
                    local r = eval.scope_draw and eval.scope_draw(ctx) or draw()
                    v = opts[r % #opts + 1]
                end
            end
        end
        if v and def("common/planet_classes", unq(v)) then return unq(v) end
        if v then
            local _, t = eval.resolve(v, ctx, e)
            if t and t ~= NONE and t.kind == "planet" then
                return unq(world.field(world.object("planet", t.id), "planet_class"))
            end
        end
        return nil
    end
    -- the terraform links (common/terraform: every `terraform_link`, all of one name, in file
    -- order; render.windows.planet's reader, which the simulation does not load)
    local link_cache
    local link_file = setmetatable({}, { __mode = "k" })
    local function terraform_links()
        if link_cache then return link_cache end
        local source = require("stellar.script.source")
        local fs = defs.fs
        local out = {}
        -- the file's own `@name = value` variables put in place (the costs and durations use them)
        local function subst(b, vars)
            for _, y in ipairs(b) do
                local v = y.op and y.value
                if v and v.text and v.text:sub(1, 1) == "@" and vars[v.text:sub(2)] then
                    v.text = vars[v.text:sub(2)]
                elseif type(v) == "table" and v.text == nil then
                    subst(v, vars)
                end
            end
        end
        for _, short in ipairs(fs and source.files(fs, "common/terraform", "txt") or {}) do
            local tree = source.parse(fs, short) or {}
            local vars = {}
            for _, x in ipairs(tree) do
                if x.op and x.key and x.key.text:sub(1, 1) == "@" and x.value and x.value.text then
                    vars[x.key.text:sub(2)] = x.value.text
                end
            end
            for _, x in ipairs(tree) do
                if x.op == "=" and x.key and x.key.text == "terraform_link" and type(x.value) == "table" then
                    local ok, v = pcall(source.expand, fs, x.value, nil, 0, "file: " .. short)
                    v = ok and v or x.value
                    subst(v, vars)
                    out[#out + 1] = v
                    link_file[v] = short
                end
            end
        end
        link_cache = out
        return out
    end
    -- the link from a class to another (from, to, duration, resources)
    local function link_of(from, to)
        for _, l in ipairs(terraform_links()) do
            if unq(defs.field(l, "from")) == from and unq(defs.field(l, "to")) == to then return l end
        end
    end
    local function country_of_planet(p)
        local o = ref(world.field(p, "owner"))
        if o then return o end
        local sys = tonumber(world.path(p, "coordinate", "origin"))
        return sys and world.system_owner and world.system_owner[sys] or nil
    end
    -- the process finished (Finish + FinishTerraformation): the class (change_pc), the planet
    -- terraformed (bit 11, terraformed_by), on_terraforming_complete (two draws) with a country
    local function finish_process(pid, p, b, who)
        local to = unq(world.field(b, "terraform_type"))
        cp.cancel_terraform(pid)
        if to then pcall(systems.effects.change_pc, { kind = "planet", id = pid, class = to }) end
        set_bit(p, 11, true)
        if who then
            world.set(p, "terraformed_by", who)
            on_action("on_terraforming_complete", eval.S("planet", pid), eval.S("country", who))
        end
    end
    -- start_terraform_process = <class> | { class inherit_entity } (CStartTerraformProcessEffect):
    -- the link from the planet's class to the target; without one nothing; the link's cost
    -- charged to the owner (else the system's owner), a timed process of its duration,
    -- on_terraforming_begun
    EFF["start_terraform_process"] = function(e, ctx)
        local p, pid = scope_planet(ctx)
        if not p then return end
        local to = target_class(e, ctx)
        local from = unq(world.field(p, "planet_class"))
        local link = to and link_of(from, to)
        if not link then return end
        local who = country_of_planet(p)
        if process(p) then cp.cancel_terraform(pid) end
        -- the cost: the link's resources' cost blocks (their triggers in the planet's scope) with the
        -- colony's cost modifiers (engine.economy, as render.windows.planet.def_cost)
        local cost = {}
        local ok, econ = pcall(require, "engine.economy")
        local rb = defs.field(link, "resources")
        local t = ok and rb and econ.init and (econ.init() or true) and econ.template(rb, link_file[link] or "")
        if who and t then
            local cctx = eval.new_ctx(S("planet", pid), S("country", who))
            for _, b in ipairs(t.cost or {}) do
                if not b.trigger or eval.trigger(b.trigger, cctx) then
                    local m = b.mult and econ.value_of(b.mult, cctx) or 1
                    for _, rv in ipairs(b.values) do
                        cost[rv[1]] = (cost[rv[1]] or 0) + (econ.value_of(rv[2], cctx) or 0) * m
                    end
                end
            end
            local cid = H.colony_of_planet(pid)
            local oka, applied = pcall(econ.apply, t.category or "terraforming", "cost", cost, 1, cid and econ.modifiers("colony", cid) or {}, cctx)
            if oka and type(applied) == "table" then cost = applied end
            local stock = world.path(world.object("country", who), "modules", "standard_economy_module", "resources")
            for r, v in pairs(cost) do
                if type(stock) == "table" and v ~= 0 then
                    world.set(stock, r, (tonumber(world.field(stock, r)) or 0) - v)
                end
            end
        end
        cp.start_terraform(pid, to, tonumber(defs.field(link, "duration")) or 1)
        on_action("on_terraforming_begun", eval.S("planet", pid), who and eval.S("country", who) or nil)
        written()
    end
    -- start_terraform_progress = <class> (CStartScriptedTerraformProcessEffect): a scripted
    -- process (no link, no cost; any existing one cancelled), its total 1 (the progress effects'
    -- fractions) [I the total], on_terraforming_begun
    EFF["start_terraform_progress"] = function(e, ctx)
        local p, pid = scope_planet(ctx)
        if not p then return end
        local to = target_class(e, ctx)
        if not to then return end
        if process(p) then cp.cancel_terraform(pid) end
        cp.start_terraform(pid, to, 1)
        local b = process(p)
        if b then world.append(b, "scripted", "yes") end
        local who = country_of_planet(p)
        on_action("on_terraforming_begun", eval.S("planet", pid), who and eval.S("country", who) or nil)
        written()
    end
    -- stop_terraform_process = <target> (CStopTerraformProcessEffect): the process deleted, no
    -- refund; cancel_terraformation = yes (CCancelTerraformEffect): the same while terraforming
    EFF["stop_terraform_process"] = function(e, ctx)
        local p, pid = scope_planet(ctx)
        if p and process(p) and cp.cancel_terraform(pid) then written() end
    end
    EFF["cancel_terraformation"] = function(e, ctx)
        if not yes(e) then return end
        local p, pid = scope_planet(ctx)
        if p and process(p) and cp.cancel_terraform(pid) then written() end
    end
    -- add_terraform_progress = f / set_terraform_progress = f (CAdd/CSetScriptedTerraformProcess
    -- Effect): the progress plus (or set to) f; at the total the process finishes
    -- (on_terraforming_complete with a country, when the progress is above 0)
    local function terraform_progress(e, ctx, set)
        local p, pid = scope_planet(ctx)
        local b = p and process(p)
        if not b then return end
        local v = eval.value(e.value, ctx, e)
        local prog = set and v or (tonumber(world.field(b, "progress")) or 0) + v
        world.set(b, "progress", prog)
        if prog >= (tonumber(world.field(b, "total")) or 1) then
            finish_process(pid, p, b, prog > 0 and country_of_planet(p) or nil)
        end
        written()
    end
    EFF["add_terraform_progress"] = function(e, ctx) return terraform_progress(e, ctx, false) end
    EFF["set_terraform_progress"] = function(e, ctx) return terraform_progress(e, ctx, true) end
    -- finish_terraformation = yes (CFinishTerraformationEffect): the process finished now
    EFF["finish_terraformation"] = function(e, ctx)
        if not yes(e) then return end
        local p, pid = scope_planet(ctx)
        local b = p and process(p)
        if not b then return end
        finish_process(pid, p, b, country_of_planet(p))
        written()
    end
    -- add_terraformation_total_time_mult = f (CAddTerraformationTimeEffect): a timed process's
    -- multiplier + f, its total the initial days x the multiplier (no completion check)
    EFF["add_terraformation_total_time_mult"] = function(e, ctx)
        local p = scope_planet(ctx)
        local b = p and process(p)
        if not b or world.field(b, "scripted") == "yes" then return end
        local initial = tonumber(world.field(b, "initial_total")) or tonumber(world.field(b, "total")) or 0
        if not world.field(b, "initial_total") then world.append(b, "initial_total", initial) end
        local mult = (tonumber(world.field(b, "total_days_mult")) or 1) + eval.value(e.value, ctx, e)
        world.set(b, "total_days_mult", mult)
        world.set(b, "total", initial * mult)
        written()
    end

    -- -----------------------------------------------------------------------------------------
    -- pops

    -- kill_pop_group / sacrifice_pop_group = { pop_group amount | percentage random
    -- growth_category } (CKillPopGroupEffect, CSacrificePopGroupEffect): n pops of the group
    -- (with `random`, one draw of the scope's random state in [n - r, n + r], made even at 0),
    -- clamped to its size; the group out of its colony when emptied; a sacrifice fires
    -- on_pop_sacrificed (even at 0)
    local function kill_pops(e, ctx, sacrifice)
        local pr = params(e)
        if not pr.pop_group or not pr.pop_group.value.text then return end
        sync()
        local _, g = eval.resolve(pr.pop_group.value.text, ctx, pr.pop_group)
        if not g or g == NONE or g.kind ~= "pop_group" then return end
        local gb = world.object("pop_groups", g.id)
        if not gb then return end
        local size = tonumber(world.field(gb, "size")) or 0
        local n
        if pr.amount then
            n = eval.value(pr.amount.value, ctx, pr.amount)
        elseif pr.percentage then
            n = eval.value(pr.percentage.value, ctx, pr.percentage) * size
        else
            n = 0
        end
        if pr.random then
            local r = eval.value(pr.random.value, ctx, pr.random)
            local d = eval.scope_draw and eval.scope_draw(ctx) or draw()
            n = (n - r) + (2 * r) * ((d % 100000) / 100000)
        end
        n = math.floor(math.max(0, math.min(size, n)))
        local cid = ref(world.field(gb, "planet"))
        local pops = require("engine.pops")
        local cat = pr.growth_category and unq(pr.growth_category.value.text) or "GROWTH_CAT_OTHER"
        if n > 0 and pops.add_size then
            pops.add_size(g.id, cid, -n, cat)
            if (tonumber(world.field(gb, "size")) or 0) <= 0 then
                local c = world.object("colony", cid)
                local l = c and world.field(c, "pop_groups")
                if type(l) == "table" then
                    world.remove_value(l, tostring(g.id))
                    world.remove_value(l, g.id)
                end
                world.set(gb, "killed", "yes")
            end
            written()
        end
        if sacrifice then
            draw()
            draw()
            draw()
            on_action("on_pop_sacrificed", eval.S("pop_group", g.id))
            written()
        end
    end
    EFF["kill_pop_group"] = function(e, ctx) return kill_pops(e, ctx, false) end
    EFF["sacrifice_pop_group"] = function(e, ctx) return kill_pops(e, ctx, true) end

    -- -----------------------------------------------------------------------------------------
    -- holdings and branch offices: the colony's `externally_owned_buildings = { { owner_type
    -- building_owner buildings = { ids } } }` (the block E.branch_office_owner reads) [I the
    -- layout]

    local function external(c, owner_type, owner, create)
        local list = world.field(c, "externally_owned_buildings")
        for _, b in ipairs(world.blocks(list)) do
            if unq(world.field(b, "owner_type")) == owner_type and ref(world.field(b, "building_owner")) == owner then return b end
        end
        if not create then return nil end
        if type(list) ~= "table" then
            world.append(c, "externally_owned_buildings", {})
            list = world.field(c, "externally_owned_buildings")
        end
        local b = {}
        world.append(b, "owner_type", owner_type)
        world.append(b, "building_owner", owner)
        world.append(b, "buildings", {})
        world.push(list, b)
        return b
    end
    H.external = external
    -- add_holding = { holding owner } (CAddHoldingEffect): a building of the type owned by the
    -- country (CColony::AddBuilding with an owner), in the colony's holdings
    EFF["add_holding"] = function(e, ctx)
        local c = scope_colony(ctx)
        local pr = params(e)
        local t = pr.holding and unq(pr.holding.value.text)
        local owner = target_country(pr.owner, ctx)
        if not c or not t or not owner or not def("common/buildings", t) then return end
        local bb = {}
        world.append(bb, "type", t, true)
        world.append(bb, "owner", owner)
        local bid = objects.create("buildings", bb)
        world.append_value(world.child(external(c, "holding", owner, true), "buildings"), bid)
        written()
    end
    -- remove_holding = { holding owner } (CRemoveHoldingEffect: RemoveBuildingType(type, owner))
    EFF["remove_holding"] = function(e, ctx)
        local c = scope_colony(ctx)
        local pr = params(e)
        local t = pr.holding and unq(pr.holding.value.text)
        local owner = target_country(pr.owner, ctx)
        local b = c and t and owner and external(c, "holding", owner, false)
        if not b then return end
        local l = world.field(b, "buildings")
        for _, bid in ipairs(ids(l)) do
            local bb = world.object("buildings", bid)
            if bb and unq(world.field(bb, "type")) == t then
                world.remove_value(l, tostring(bid))
                world.remove_value(l, bid)
                world.remove("buildings", bid)
                written()
                return
            end
        end
    end
    -- establish_branch_office = <country> (CEstablishBranchOfficeEffect): the colony's branch
    -- office of the country (owner_type corporate)
    EFF["establish_branch_office"] = function(e, ctx)
        local c = scope_colony(ctx)
        local owner = c and target_country(e, ctx)
        if not owner then return end
        if I.E.branch_office_owner and I.E.branch_office_owner("planet", H.planet_id(ctx.this)) then return end
        external(c, "corporate", owner, true)
        written()
    end
    -- close_branch_office = yes (CCloseBranchOfficeEffect): the branch office and its buildings gone
    EFF["close_branch_office"] = function(e, ctx)
        if not yes(e) then return end
        local c = scope_colony(ctx)
        local list = c and world.field(c, "externally_owned_buildings")
        for _, b in ipairs(world.blocks(list)) do
            if unq(world.field(b, "owner_type")) == "corporate" then
                for _, bid in ipairs(ids(world.field(b, "buildings"))) do world.remove("buildings", bid) end
                world.remove_entry(list, b)
                written()
                return
            end
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- countries, species, leaders

    -- create_point_of_interest = { id name desc event_chain location } (CCreatePointOfInterest
    -- Effect): a point of interest of the scope's country (`points_of_interest` [I key]), located
    -- at `location` (else the scope)
    EFF["create_point_of_interest"] = function(e, ctx)
        sync()
        local c = H.scope_country and H.scope_country(ctx)
        local pr = params(e)
        local id = pr.id and unq(pr.id.value.text)
        if not c or not id then return end
        local loc = ctx.this
        if pr.location and pr.location.value.text then
            local _, t = eval.resolve(pr.location.value.text, ctx, pr.location)
            if t and t ~= NONE then loc = t end
        end
        local oc = world.object("country", c)
        local list = world.field(oc, "points_of_interest")
        if type(list) ~= "table" then
            world.append(oc, "points_of_interest", {})
            list = world.field(oc, "points_of_interest")
        end
        local b = {}
        world.append(b, "id", id, true)
        for _, k in ipairs({ "name", "desc", "event_chain" }) do
            if pr[k] then world.append(b, k, unq(pr[k].value.text), true) end
        end
        local lb = {}
        world.append(lb, "type", loc.kind)
        world.append(lb, "id", loc.id)
        world.append(b, "location", lb)
        world.push(list, b)
        written()
    end
    -- remove_point_of_interest = <id> (a planet or a country): the scope's country's point of
    -- interest of the id
    EFF["remove_point_of_interest"] = function(e, ctx)
        sync()
        local c = H.scope_country and H.scope_country(ctx)
        if not c or not e.value.text then return end
        local list = world.field(world.object("country", c), "points_of_interest")
        for _, b in ipairs(world.blocks(list)) do
            if unq(world.field(b, "id")) == e.value.text then
                world.remove_entry(list, b)
                written()
                return
            end
        end
    end
    -- set_custom_capital_location = <target> (a country): `custom_capital_location = { type id }`
    EFF["set_custom_capital_location"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return end
        sync()
        local t = target(e, ctx)
        if not t then return end
        local b = world.child(world.object("country", sc.id), "custom_capital_location")
        world.replace(b, {})
        world.append(b, "type", t.kind)
        world.append(b, "id", t.id)
        written()
    end
    -- set_colonization_controls = { country type cooldown } (CSetSpeciesRightsEffect<
    -- SSetColonizationControl>): the country's species rights for the species:
    -- colonization_control_yes / _no, the old one kept as former_colonization_control; with
    -- cooldown the change's date
    EFF["set_colonization_controls"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return end
        sync()
        local pr = params(e)
        local sp = sc.kind == "species" and sc.id or (I.E.species_of and I.E.species_of(sc.kind, sc.id))
        local c = target_country(pr.country, ctx)
        if not c then
            local _, o = eval.resolve("owner", ctx, nil)
            c = o and o ~= NONE and o.kind == "country" and o.id or nil
        end
        if not sp or not c then return end
        local val = pr.type and pr.type.value.text
        if val == "yes" or val == "no" then val = "colonization_control_" .. val end
        if not val then return end
        local module = world.path(world.object("country", c), "modules", "standard_species_rights_module")
        if type(module) ~= "table" then return end
        local rights
        for _, x in ipairs(module) do
            if x.op and x.value.text == nil then
                if tonumber(world.field(x.value, "species_index")) == sp then rights = x.value end
                for _, b in ipairs(world.blocks(x.value)) do
                    if tonumber(world.field(b, "species_index")) == sp then rights = b end
                end
            end
        end
        if not rights then
            local list = world.field(module, "species_rights")
            if type(list) ~= "table" then
                world.append(module, "species_rights", {})
                list = world.field(module, "species_rights")
            end
            rights = {}
            world.append(rights, "species_index", sp)
            world.push(list, rights)
        end
        local old = unq(world.field(rights, "colonization_control"))
        if old == val then return end
        world.set(rights, "colonization_control", '"' .. val .. '"')
        if old then world.set(rights, "former_colonization_control", '"' .. old .. '"') end
        if pr.cooldown and pr.cooldown.value.text == "yes" then
            world.set(rights, "last_changed_colonization_control", '"' .. tostring(world.meta and world.meta.date or ""):gsub('"', "") .. '"')
        end
        written()
    end
    -- set_habitability_trait = { trait } (a species: CSetHabitabilityTrait): its planet class
    -- preference trait (a trait with a `<class>_habitability` of 1, `trait_pc_*_preference`)
    -- removed, the trait added
    EFF["set_habitability_trait"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "species" then return end
        sync()
        local pr = params(e)
        local t = pr.trait and unq(pr.trait.value.text)
        local s = world.object("species", sc.id)
        if not t or not s then return end
        local tb = world.field(s, "traits")
        if type(tb) ~= "table" then return end
        for i = #tb, 1, -1 do
            local x = tb[i]
            local n = x.op and x.key and x.key.text == "trait" and unq(x.value.text)
            if n and (n:match("^trait_pc_.*_preference$") or n:match("^trait_auto_mod_")) then world.remove_entry(tb, x) end
        end
        world.append(tb, "trait", t, true)
        written()
    end
    -- change_background_job = <job> (a leader: CLeader::SetBackgroundJob): the leader's `job`,
    -- not for a gestalt's leader
    EFF["change_background_job"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "leader" or not e.value.text then return end
        sync()
        local l = world.object("leader", sc.id)
        if not l or tostring(world.field(l, "ethic")):find("gestalt") then return end
        world.set(l, "job", '"' .. e.value.text .. '"')
        written()
    end
    -- export_modifier_duration_to_variable = { modifier variable } (CExportModifierDuration
    -- ToVariableEffect): the days left of the scope's timed modifier into the variable (none: 0)
    EFF["export_modifier_duration_to_variable"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return end
        sync()
        local pr = params(e)
        local m = pr.modifier and unq(pr.modifier.value.text)
        local var = pr.variable and unq(pr.variable.value.text)
        if not m or not var then return end
        local store = ({ planet = "planet", country = "country", pop_group = "pop_groups", fleet = "fleet" })[sc.kind]
        local o = store and world.object(store, sc.id)
        local days = 0
        for _, item in ipairs(world.blocks(o and world.path(o, "timed_modifier", "items"))) do
            if unq(world.field(item, "modifier")) == m then days = tonumber(world.field(item, "days")) or 0 end
        end
        eval.store.setvar(sc, var, days)
        I.stats.script = (I.stats.script or 0) + 1
    end
    -- steal_planet_output = { planet who resource max_amount percentage mode ... }
    -- (CStealPlanetOutputEffect): the planet's colony's production (its `produces`) x percentage,
    -- each resource capped at max_amount and (stealing) at the victim's stockpile; taken from the
    -- victim (mode steal), given to the thief country
    EFF["steal_planet_output"] = function(e, ctx)
        local pr = params(e)
        local pid = H.planet_id(ctx.this)
        if pr.planet and pr.planet.value.text then
            local _, t = eval.resolve(pr.planet.value.text, ctx, pr.planet)
            if t and t ~= NONE and t.kind == "planet" then pid = t.id end
        end
        sync()
        local c = pid and world.object("colony", H.colony_of_planet(pid))
        local thief = target_country(pr.who, ctx)
        local victim = pid and ref(world.field(world.object("planet", pid), "owner"))
        if not c or not thief or thief == victim then return end
        local pct = pr.percentage and eval.value(pr.percentage.value, ctx, pr.percentage) or 1
        local max = pr.max_amount and eval.value(pr.max_amount.value, ctx, pr.max_amount) or 0
        local want = pr.resource and unq(pr.resource.value.text) or "all"
        local steal = not pr.mode or unq(pr.mode.value.text) ~= "duplicate"
        local function stock(country)
            return world.path(world.object("country", country), "modules", "standard_economy_module", "resources")
        end
        local vs, ts = victim and stock(victim), stock(thief)
        if type(ts) ~= "table" then return end
        local any = false
        for k, v in world.statements(world.field(c, "produces") or {}) do
            local n = tonumber(v)
            if n and n > 0 and (want == "all" or want == k) then
                local amt = n * pct
                if max > 0 then amt = math.min(amt, max) end
                if steal and type(vs) == "table" then
                    amt = math.min(amt, tonumber(world.field(vs, k)) or 0)
                    world.set(vs, k, (tonumber(world.field(vs, k)) or 0) - amt)
                end
                if amt > 0 then
                    world.set(ts, k, (tonumber(world.field(ts, k)) or 0) + amt)
                    any = true
                end
            end
        end
        if any then written() end
    end
end
