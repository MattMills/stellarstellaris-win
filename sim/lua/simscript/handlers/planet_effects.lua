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
    -- downgrade_buildings_of_type = <type> (CDowngradeBuildingsOfTypeEffect; the docs write
    -- `= yes`): every building of the type becomes its predecessor [I the type's form]
    EFF["downgrade_buildings_of_type"] = function(e, ctx)
        local want = e.value.text
        if not want then return end
        for _, c in ipairs(scope_colonies(ctx)) do
            local any = false
            for _, b in ipairs(buildings(c)) do
                local t = unq(world.field(b.block, "type"))
                local prev = predecessor(t)
                if prev and (t == want or want == "yes") and not is_capital_building(t) then
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
end
