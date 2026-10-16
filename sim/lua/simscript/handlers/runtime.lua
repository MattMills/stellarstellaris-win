-- simscript/handlers/runtime.lua : the keywords the simulation hits at run time that the script
-- layer did not evaluate: cosmic storms, megastructures, starbases, councilors, sectors, and the
-- country, planet, fleet and ship properties the save keeps. Each follows the trigger class's
-- evaluation in the game (GOG 4.5.2; docs/script_runtime.md has the classes, [V] / [I] and what
-- is approximated); the world is read through engine/script/runtime.lua.

return function(eval)
    local I = eval._internal
    local TRIG, LINKS, LISTS = eval.TRIG, eval.LINKS, eval.LISTS
    -- what the tables held before this module (STELLAR_RUNTIME_OFF, at the end)
    local before = { TRIG = {}, LINKS = {}, LISTS = {}, TVAL = {} }
    for name, t in pairs({ TRIG = TRIG, LINKS = LINKS, LISTS = LISTS, TVAL = eval.TVAL }) do
        for k, v in pairs(t) do before[name][k] = v end
    end
    local S, NONE, sync, compare, miss = I.S, I.NONE, I.sync, I.compare, I.miss
    local yes = I.yes

    -- the world's readers (nil without a world: every handler is then false)
    local R
    local function rt()
        if R == nil then
            local ok, mod = pcall(require, "engine.script.runtime")
            R = ok and mod or false
        end
        return R or nil
    end

    -- the scope `<trigger> = <target>` names, or nil
    local function target(e, ctx)
        if not e.value.text then return nil end
        local found, sc = eval.resolve(e.value.text, ctx, e)
        return (found and sc and sc ~= NONE) and sc or nil
    end
    -- the number of `<trigger> <op> <value>` compared with v (false without a v)
    local function compare_num(v, e, ctx)
        if v == nil then return false end
        return compare(v, e.op, eval.value(e.value, ctx, e))
    end
    -- the scope's country: a country itself, else nil
    local function country_id(sc)
        return sc.kind == "country" and sc.id or nil
    end

    -- -----------------------------------------------------------------------------------------
    -- any scope

    -- is_scope_valid = yes/no (CIsScopeValidTrigger 0x1990b20): the scope object is valid (exists)
    TRIG["is_scope_valid"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local valid = sc ~= NONE and sc ~= nil
        if valid and r then
            sync()
            valid = r.exists(sc.kind, sc.id)
        end
        return valid == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- ships and fleets

    -- is_space_fauna = yes/no (CIsSpaceFaunaTrigger 0x1a207c0): the ship size has
    -- is_space_fauna_ship (EShipSizeSettingsType IsSpaceFaunaShip, bit 14 of CShipSize +0xc8): a
    -- ship's (its design's growth stage), a fleet's first ship's; false for a fleet without ships
    -- or another scope
    TRIG["is_space_fauna"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc == NONE then return false end
        sync()
        local ship
        if sc.kind == "ship" then
            ship = sc.id
        elseif sc.kind == "fleet" then
            ship = r.fleet_ships(sc.id)[1]
        end
        local size = ship and r.ship_size_of(ship)
        if not size then return false end
        return r.ship_size_flag(size, "is_space_fauna_ship") == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- cosmic storms

    -- is_inside_storm = yes / no / <storm type> (CIsInsideStormTrigger 0x19ba4d0, a system; any
    -- other scope fails CTrigger::Evaluate's scope check): the system's `storm` names a storm that
    -- exists; with a type, the storm's `type` is it
    TRIG["is_inside_storm"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "system" then return false end
        sync()
        local storm = r.storm_of_system(sc.id)
        if v == "yes" then return storm ~= nil end
        if v == "no" then return storm == nil end
        return storm ~= nil and r.storm_type(storm) == v
    end

    -- -----------------------------------------------------------------------------------------
    -- megastructures

    -- has_megastructure = <type> (CHasMegaStructureTrigger 0x19a56a0): a megastructure of the type
    -- among a country's own (`owned_megastructures`) or a system's (`megastructures`); false for
    -- another scope
    TRIG["has_megastructure"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc == NONE then return false end
        sync()
        local list = r.megastructures_of(sc.kind, sc.id)
        for _, mid in ipairs(list or {}) do
            if r.megastructure_type(mid) == v then return true end
        end
        return false
    end

    -- -----------------------------------------------------------------------------------------
    -- countries

    -- is_nomadic = yes/no (CIsNomadicTrigger 0x19b7410): the country's IsNomadic setting (bit 11 of
    -- CCountry +0x2a70), saved as `is_nomadic = yes`
    TRIG["is_nomadic"] = function(e, ctx)
        local r, c = rt(), country_id(ctx.this)
        if not r or not c then return false end
        sync()
        return r.country_setting(c, "is_nomadic") == yes(e)
    end

    -- has_covenant = <patron> (CHasCovenantTrigger 0x1a23960): the country's shroud module has a
    -- covenant with the patron
    TRIG["has_covenant"] = function(e, ctx)
        local r, c = rt(), country_id(ctx.this)
        if not r or not c or not e.value.text then return false end
        sync()
        local p = r.covenant_patron(c)
        return p ~= nil and p == e.value.text
    end

    -- has_crisis_level = <level> (CHasCrisisLevelTrigger 0x1a1c790): a crisis level the country
    -- unlocked
    TRIG["has_crisis_level"] = function(e, ctx)
        local r, c = rt(), country_id(ctx.this)
        if not r or not c or not e.value.text then return false end
        sync()
        for _, l in ipairs(r.crisis_levels(c)) do
            if l == e.value.text then return true end
        end
        return false
    end

    -- -----------------------------------------------------------------------------------------
    -- starbases

    -- has_starbase_size <op> <ship size> (CHasStarbaseSizeCompareTrigger 0x19c28f0, a starbase):
    -- the starbase's level against the first level whose ship_size is the size, ordered by
    -- next_level: `=` the same level; `>=` / `<=` the same, or after / before it on the chain;
    -- `>` after it; `<` (and any other operator) before it. An invalid starbase or level: false.
    TRIG["has_starbase_size"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "starbase" or not e.value.text then return false end
        sync()
        local level = r.starbase_level(sc.id)
        local want = r.level_of_size(e.value.text)
        if not level or not want then return false end
        local op = e.op
        if op == "=" or op == "==" then return level == want end
        if level == want then return op == ">=" or op == "<=" end
        if op == ">" or op == ">=" then return r.level_reaches(want, level) end
        return r.level_reaches(level, want)
    end

    -- -----------------------------------------------------------------------------------------
    -- leaders and councils

    -- is_councilor_type = <councilor type> (CCouncilorTypeTrigger 0x19bed10, a leader): a council
    -- position of the leader's country's government held by the leader has the type
    TRIG["is_councilor_type"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "leader" or not e.value.text then return false end
        sync()
        local p = r.council_position_of_leader(sc.id)
        return p ~= nil and require("engine.world").field(p, "type") == e.value.text
    end

    -- -----------------------------------------------------------------------------------------
    -- colonies and sectors

    -- is_sector_capital = yes/no (CIsSectorCapitalTrigger 0x1957bf0, a planet, pop group or
    -- colony): the colony is the local capital of its system's sector. Without a colony the
    -- CBoolTrigger's value decides: `= no` holds (_StatusSet +0x221 and not _Status +0x220)
    TRIG["is_sector_capital"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc == NONE then return false end
        sync()
        local col = r.colony_of(sc.kind, sc.id)
        if not col then return not yes(e) end
        return r.is_sector_capital(col) == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- numbers: a comparison trigger and its `trigger:<name>` value from one function. value(sc, r)
    -- -> the number, or nil when the trigger's GetTriggerValue fails (the comparison is then false,
    -- the value 0: CIntTrigger / CValueTrigger::GetFixedPointTriggerValue); kinds: the scopes the
    -- trigger supports (any other: false, and 0)
    local TVAL = eval.TVAL
    local function numeric(name, kinds, value)
        local ok = {}
        for _, k in ipairs(kinds) do ok[k] = true end
        TRIG[name] = function(e, ctx)
            local r, sc = rt(), ctx.this
            if not r or not ok[sc.kind] then return false end
            sync()
            return compare_num(value(sc, r), e, ctx)
        end
        TVAL[name] = function(ctx)
            local r, sc = rt(), ctx.this
            if not r or not ok[sc.kind] then return 0 end
            sync()
            return value(sc, r) or 0
        end
    end
    eval.runtime_numeric = numeric

    -- a block trigger's parameters: { [key] = statement }, keys lowercased
    local function params(e)
        local t = {}
        if e.value.text then return t end
        for _, x in ipairs(e.value) do
            if x.op and x.key then t[x.key.text:lower()] = x end
        end
        return t
    end

    -- -----------------------------------------------------------------------------------------
    -- starbases

    -- has_starbase_building / has_starbase_module = <key> (CHasStarbaseComponentTriggerBase<...>
    -- 0x19c57a0 / 0x19c5a70, a starbase): a building (module) of the starbase is the key; with `!=`
    -- one that is not the key
    for _, spec in ipairs({ { "has_starbase_building", "buildings" }, { "has_starbase_module", "modules" } }) do
        local key = spec[2]
        TRIG[spec[1]] = function(e, ctx)
            local r, sc = rt(), ctx.this
            local v = e.value.text
            if not r or sc.kind ~= "starbase" or not v then return false end
            sync()
            local neq = e.op == "!="
            for _, k in ipairs(r.starbase_items(sc.id, key)) do
                if (k == v) ~= neq then return true end
            end
            return false
        end
    end

    -- used_starbase_capacity_percent <op> x (CUsedStarbaseCapacityPercentTrigger 0x199d0d0, a
    -- country): (the capacity used + the outposts being upgraded) / the capacity; false at capacity
    -- 0. The game recomputes both daily (CCountry +0x33e8, +0x33f0): computed here the same way
    numeric("used_starbase_capacity_percent", { "country" }, function(sc, r)
        local cap = r.starbase_capacity(sc.id)
        if cap == 0 then return nil end
        return (r.starbase_capacity_used(sc.id) + r.upgrading_outposts(sc.id)) / cap
    end)

    -- count_starbase_sizes = { starbase_size = <ship size> count <op> n } (CCountStarbaseSizesTrigger
    -- 0x19c3720, a country): the country's starbases at the size's level or after it on the
    -- next_level chain
    TRIG["count_starbase_sizes"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" or e.value.text then return false end
        local p = params(e)
        local size, cnt = p.starbase_size, p.count
        if not size or not cnt or not size.value.text then return false end
        sync()
        local want = r.level_of_size(size.value.text)
        local n = 0
        for _, sb in ipairs(r.country_starbases(sc.id)) do
            local l = r.starbase_level(sb)
            if l and want and (l == want or r.level_reaches(want, l)) then n = n + 1 end
        end
        return compare(n, cnt.op, eval.value(cnt.value, ctx, cnt))
    end

    -- can_be_upgraded = yes/no (CCanBeUpgradedTrigger 0x19a60d0). A starbase: its level's next_level
    -- exists, it is not occupied, no upgrade is queued, the next level's ship size is potential,
    -- researched and possible for the controller (ship_sizes potential_country, prerequisites,
    -- possible_country) and the next level's upgrade trigger holds. A ship (CShip::CanBeUpgraded
    -- 0x2ac59c0): its design implementation's `upgrade` (the save's CalcLatestUpgradableDesign) is
    -- another design [I: the ship's upgrade flag +0x478 and its fleet's CanUpgrade flag +0x1270 are
    -- taken as set]; a fleet (CFleet::HasShipsThatCanBeUpgraded 0x29426d0): one of its ships can.
    -- A megastructure is not evaluated (a miss).
    local function ship_upgradable(sid)
        local w = require("engine.world")
        local s = w.object("ships", sid)
        local sdi = s and w.field(s, "ship_design_implementation")
        if type(sdi) ~= "table" then return false end
        local up = tonumber(w.field(sdi, "upgrade"))
        return up ~= nil and up ~= 4294967295 and up ~= tonumber(w.field(sdi, "design")) and w.object("ship_design", up) ~= nil
    end
    TRIG["can_be_upgraded"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        if sc.kind ~= "starbase" then
            if sc.kind == "ship" then
                sync()
                return ship_upgradable(sc.id) == yes(e)
            elseif sc.kind == "fleet" then
                sync()
                local any = false
                for _, sid in ipairs(r.fleet_ships(sc.id) or {}) do
                    if ship_upgradable(sid) then any = true break end
                end
                return any == yes(e)
            elseif sc.kind == "megastructure" then
                miss("trigger", "can_be_upgraded (" .. sc.kind .. ")", ctx, e)
                return false
            end
            return not yes(e)
        end
        sync()
        local level = r.starbase_level(sc.id)
        local nxt = level and r.next_level(level)
        local ok = false
        if nxt and not r.has_queued_upgrade(sc.id) then
            local owner = r.starbase_owner(sc.id)
            local size = r.level_field(nxt, "ship_size")
            ok = owner ~= nil
            if ok and size then
                local cctx = eval.new_ctx(S("country", owner), nil, nil, "can_be_upgraded")
                local pot = r.ship_size_field(size, "potential_country")
                local poss = r.ship_size_field(size, "possible_country")
                if type(pot) == "table" and not eval.trigger(pot, cctx) then ok = false end
                if ok and type(poss) == "table" and not eval.trigger(poss, cctx) then ok = false end
                if ok then
                    for _, t in ipairs(r.ship_size_prerequisites(size)) do
                        if not E.has("country", owner, "tech", t) then ok = false break end
                    end
                end
            end
            local up = ok and r.level_field(nxt, "potential")
            if ok and type(up) == "table" then
                ok = eval.trigger(up, eval.new_ctx(sc, nil, nil, "can_be_upgraded"))
            end
        end
        return ok == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- fleets and ships

    -- has_fleet_order = <order> (CHasFleetOrderTrigger 0x1992000, a fleet; a ship: its fleet's): the
    -- current order or one of its sub orders, or a queued order, is of that kind
    TRIG["has_fleet_order"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local fid = sc.kind == "fleet" and sc.id or (sc.kind == "ship" and r.ship_fleet(sc.id)) or nil
        if not fid then return false end
        for _, n in ipairs(r.fleet_order_names(fid)) do
            if n == v then return true end
        end
        return false
    end

    -- the ship size of a ship, of a fleet's first ship, of a starbase's station
    local function scope_ship(sc, r)
        if sc.kind == "ship" then return sc.id end
        if sc.kind == "fleet" then return r.fleet_ships(sc.id)[1] end
        if sc.kind == "starbase" then
            local sb = r.obj("starbase", sc.id)
            return sb and r.ref(require("engine.world").field(sb, "station"))
        end
        return nil
    end

    -- is_ship_size = <ship size> (CIsShipSizeTrigger 0x1955e80): a ship's, a fleet's first ship's,
    -- a starbase's station's
    TRIG["is_ship_size"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local ship = scope_ship(sc, r)
        return ship ~= nil and r.ship_size_of(ship) == v
    end

    -- is_ship_class = <class> (CIsShipClassTrigger 0x1955ab0): a fleet's `ship_class`, a ship's ship
    -- size's `class`
    TRIG["is_ship_class"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local class
        if sc.kind == "fleet" then
            class = r.fleet_field(sc.id, "ship_class")
        elseif sc.kind == "ship" then
            class = r.ship_size_field(r.ship_size_of(sc.id), "class")
        else
            return false
        end
        return (class or "shipclass_military") == v
    end

    -- is_ship_category = <category> (CIsShipCategoryTrigger 0x1a20f30): the ship size's
    -- ship_category, a fleet's first ship's
    TRIG["is_ship_category"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or (sc.kind ~= "ship" and sc.kind ~= "fleet") then return false end
        sync()
        local ship = scope_ship(sc, r)
        local cat = ship and r.ship_size_field(r.ship_size_of(ship), "ship_category")
        return cat ~= nil and cat == v
    end

    -- is_cloaked = yes/no (CIsCloakedTrigger 0x1a20280, a fleet; a ship: its fleet's): the fleet's
    -- Cloaked flag (`properties = { is_cloaked = yes }`)
    TRIG["is_cloaked"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        local fid
        if sc.kind == "fleet" then fid = sc.id elseif sc.kind == "ship" then fid = r.ship_fleet(sc.id) end
        if sc.kind ~= "fleet" and sc.kind ~= "ship" then return false end
        sync()
        return (fid ~= nil and r.fleet_property(fid, "is_cloaked")) == yes(e)
    end

    -- is_reanimated = yes/no (CIsReanimatedTrigger 0x1a20a80, a ship or fleet): the ship size's
    -- IsReanimated setting (`is_reanimated = yes`); a fleet's first ship's; a fleet without ships:
    -- false
    TRIG["is_reanimated"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or (sc.kind ~= "ship" and sc.kind ~= "fleet") then return false end
        sync()
        local ship = scope_ship(sc, r)
        if not ship then return false end
        return r.ship_size_flag(r.ship_size_of(ship), "is_reanimated") == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- systems

    -- has_hyperlane_to = <system | country> (CHasHyperlaneToTrigger 0x19ace80, a system): to a
    -- system, a hyperlane of this one goes there; to a country, the country owns this system or a
    -- system a hyperlane goes to (CCountryBorderManager::CalcIsBorderingSystem with the border
    -- cache fresh)
    TRIG["has_hyperlane_to"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "system" then return false end
        local t = target(e, ctx)
        if not t then return false end
        sync()
        if t.kind == "country" then
            if r.system_owner(sc.id) == t.id then return true end
            for _, n in ipairs(r.hyperlanes(sc.id)) do
                if r.system_owner(n) == t.id then return true end
            end
            return false
        end
        if t.kind ~= "system" then return false end
        for _, n in ipairs(r.hyperlanes(sc.id)) do
            if n == t.id then return true end
        end
        return false
    end

    -- is_capital_system = yes/no (CIsCapitalSystem 0x1957830, a system): the system of its owner's
    -- capital; an unowned system is not
    TRIG["is_capital_system"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "system" then return false end
        sync()
        local owner = r.system_owner(sc.id)
        local is = owner ~= nil and r.capital_system(owner) == sc.id
        return is == yes(e)
    end

    -- has_natural_wormhole = yes/no (CHasWormholeTrigger 0x19b8d00, a system): its
    -- `natural_wormholes` is not empty
    TRIG["has_natural_wormhole"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "system" then return false end
        sync()
        return (#r.system_list(sc.id, "natural_wormholes") > 0) == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- planets, colonies, deposits

    -- num_uncleared_blockers <op> n (CNumUnclearedBlockersTrigger 0x1a08ed0, a planet, ship or
    -- colony): the carrier's deposits whose category is a blocker
    numeric("num_uncleared_blockers", { "planet", "ship", "colony" }, function(sc, r)
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return nil end
        local n = 0
        for _, d in ipairs(r.carrier_deposits(kind, id)) do
            if r.deposit_is_blocker(r.deposit_type(d)) then n = n + 1 end
        end
        return n
    end)

    -- is_colonizable = yes/no (CIsColonizableTrigger 0x19669b0, a planet, ship or colony): a planet
    -- carrier without an owner whose class is colonizable; a ship carrier never; no carrier: false
    TRIG["is_colonizable"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return false end
        local is = false
        if kind == "planet" then
            is = r.planet_owner(id) == nil and r.planet_class_flag(id, "colonizable")
        end
        return is == yes(e)
    end

    -- is_artificial = yes/no (CIsArtificalTrigger 0x195dbe0): the planet's (a colony's or ship's
    -- carrier's) class has is_artificial_planet; another scope: `= no` holds
    TRIG["is_artificial"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if kind ~= "planet" then return not yes(e) end
        return r.planet_class_flag(id, "is_artificial_planet") == yes(e)
    end

    -- has_deposit = yes / no / <deposit type> (CHasDepositTrigger 0x1984910, a planet, ship, colony
    -- or deposit): a deposit: its type, or yes/no whether it has resources; a carrier: a deposit of
    -- the type, or yes/no whether one has resources; no carrier: false
    TRIG["has_deposit"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        if sc.kind == "deposit" then
            local t = r.deposit_type(sc.id)
            if v == "yes" then return r.deposit_has_resources(t) end
            if v == "no" then return not r.deposit_has_resources(t) end
            return t == v
        end
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return false end
        local deps = r.carrier_deposits(kind, id)
        if v == "yes" or v == "no" then
            local any = false
            for _, d in ipairs(deps) do
                if r.deposit_has_resources(r.deposit_type(d)) then any = true break end
            end
            return any == (v == "yes")
        end
        for _, d in ipairs(deps) do
            if r.deposit_type(d) == v then return true end
        end
        return false
    end

    -- has_designation = <designation> (CHasDesignationTrigger 0x1952050, a planet, ship or colony):
    -- the colony's final designation (CColony +0x100, `final_designation`; `designation` is the
    -- manual one)
    TRIG["has_designation"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local col = r.colony_of(sc.kind, sc.id)
        return col ~= nil and r.colony_field(col, "final_designation") == v
    end

    -- has_building = yes / no / <building> (CHasBuildingTrigger 0x196cbc0, a planet, ship or
    -- colony): yes/no whether a zone of the colony holds a building; a building type: one of the
    -- colony's (owner's) buildings is of it (ruined and disabled ones count)
    TRIG["has_building"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local col = r.colony_of(sc.kind, sc.id)
        if not col then return false end
        if v == "yes" or v == "no" then
            return (#r.colony_zone_buildings(col) > 0) == (v == "yes")
        end
        for _, b in ipairs(r.colony_buildings(col)) do
            if r.building_field(b, "type") == v then return true end
        end
        return false
    end

    -- free_amenities <op> n (CFreeAmenitiesTrigger 0x197c050, a planet, ship or colony): the colony's
    -- cached free amenities (`free_amenities`), truncated toward zero; no colony: 0
    numeric("free_amenities", { "planet", "ship", "colony" }, function(sc, r)
        local col = r.colony_of(sc.kind, sc.id)
        local v = col and tonumber(r.colony_field(col, "free_amenities")) or 0
        return v < 0 and math.ceil(v) or math.floor(v)
    end)

    -- last_district_changed / last_building_changed = <type> (CLastChangedDistrictTrigger 0x196f090,
    -- CLastChangedBuildingTrigger 0x196d450, a planet, ship or colony): the colony's
    -- `last_district_changed` / `last_building_changed`
    for _, k in ipairs({ "last_district_changed", "last_building_changed" }) do
        TRIG[k] = function(e, ctx)
            local r, sc = rt(), ctx.this
            local v = e.value.text
            if not r or not v then return false end
            sync()
            local col = r.colony_of(sc.kind, sc.id)
            return col ~= nil and r.colony_field(col, k) == v
        end
    end

    -- has_available_jobs / has_forbidden_jobs = <job> (CHasAvailableJobsTrigger 0x1959f50,
    -- CHasForbiddenJobsTrigger 0x195ab10, a planet, ship or colony): the colony's first job of the
    -- type: workforce_limit - workforce > 0 / workforce_limit < max_workforce
    for _, spec in ipairs({ { "has_available_jobs", function(j, f) return f(j, "workforce_limit") - f(j, "workforce") > 0 end },
        { "has_forbidden_jobs", function(j, f) return f(j, "workforce_limit") < f(j, "max_workforce") end } }) do
        local test = spec[2]
        TRIG[spec[1]] = function(e, ctx)
            local r, sc = rt(), ctx.this
            local v = e.value.text
            if not r or not v then return false end
            sync()
            local col = r.colony_of(sc.kind, sc.id)
            if not col then return false end
            local j = r.colony_job(col, v)
            if not j then return false end
            local w = require("engine.world")
            return test(j, function(o, key) return tonumber(w.field(o, key)) or 0 end)
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- countries

    -- resource_stockpile_percent = { resource = r value <op> x } (CResourceStockpilePercentTrigger
    -- 0x19adf80, a country): the stockpile over the country's maximum of the resource
    -- (CStrategicResource::GetMaximumForCountry: the resource's max, its dynamic capacity and the
    -- country's max modifiers: engine.economy.capacity); a resource without a max: false; a max of
    -- 0: 42949.67295
    TRIG["resource_stockpile_percent"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" or e.value.text then return false end
        local p = params(e)
        local res, val = p.resource and p.resource.value.text, p.value
        if not res or not val then return false end
        sync()
        local economy = package.loaded["engine.economy"] or require("engine.economy")
        local max = economy.capacity and economy.capacity(sc.id, res)
        if max == nil or max < 0 then return false end
        local f = max == 0 and 42949.67295 or r.stockpile(sc.id, res) / max
        return compare(f, val.op, eval.value(val.value, ctx, val))
    end

    -- has_country_resource = { type = r amount <op> x } (CHasCountryResourceTrigger 0x198e780, a
    -- country): the stockpile (research from tech_status.stored_techpoints). The resource converter
    -- path (`>` / `>=` of a country with a converter) is not modelled: no country has one in the saves
    TRIG["has_country_resource"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" or e.value.text then return false end
        local p = params(e)
        local res, amt = p.type and p.type.value.text, p.amount
        if not res or not amt then return false end
        sync()
        return compare(r.stockpile(sc.id, res), amt.op, eval.value(amt.value, ctx, amt))
    end

    -- has_awareness <op> x (CAwarenessTrigger 0x19744d0, a country): `awareness` of a primitive
    -- country (the IsPrimitive instance property: its type's `faction = { primitive = yes }` [I]);
    -- another country: false
    numeric("has_awareness", { "country" }, function(sc, r)
        if r.country_type_flag(sc.id, "faction", "primitive") ~= "yes" then return nil end
        return tonumber(r.country_field(sc.id, "awareness")) or 0
    end)

    -- has_special_project = <project> (CHasSpecialProjectTrigger 0x199b010, a country): a special
    -- project of the key among `events = { special_project = { special_project = "x" } }`
    TRIG["has_special_project"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or sc.kind ~= "country" or not v then return false end
        sync()
        for _, b in ipairs(r.country_events(sc.id, "special_project")) do
            if require("engine.world").field(b, "special_project") == v then return true end
        end
        return false
    end

    -- has_event_chain = <chain> (CHasEventChainTrigger 0x1977850, a country): an active chain (`events =
    -- { event_chain = { event_chain = "x" } }`; completed ones are not)
    TRIG["has_event_chain"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or sc.kind ~= "country" or not v then return false end
        sync()
        for _, b in ipairs(r.country_events(sc.id, "event_chain")) do
            if require("engine.world").field(b, "event_chain") == v then return true end
        end
        return false
    end

    -- has_edict = <edict> (CHasEdictTrigger 0x197e730, a country): in `edicts`, no date check
    TRIG["has_edict"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or sc.kind ~= "country" or not v then return false end
        sync()
        return r.has_edict(sc.id, v)
    end

    -- num_ascension_perks / num_ascension_perk_slots <op> n (CNumAscensionPerksTrigger 0x19a8240 for
    -- both, a country): the ascension perks adopted
    for _, k in ipairs({ "num_ascension_perks", "num_ascension_perk_slots" }) do
        numeric(k, { "country" }, function(sc, r) return #r.country_list(sc.id, "ascension_perks") end)
    end

    -- num_rare_techs <op> n (CNumRareTechsTrigger 0x198fe60, a country)
    numeric("num_rare_techs", { "country" }, function(sc, r) return r.num_rare_techs(sc.id) end)

    -- has_active_tradition = <tradition or tradition swap> (CHasActiveTraditionTrigger 0x19a7500 ->
    -- CCountry::HasActiveTradition 0x74c7a0, a country): the tradition is adopted, and its swap for
    -- the country (the first tradition_swap whose trigger holds): the swap named; with the tradition
    -- named, none applies or it inherits the effects
    TRIG["has_active_tradition"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or sc.kind ~= "country" or not v then return false end
        sync()
        local trad, swap = r.tradition_of(v)
        if not trad then return false end
        local adopted = false
        for _, t in ipairs(r.country_list(sc.id, "traditions")) do
            if t == trad then adopted = true break end
        end
        if not adopted then return false end
        local cctx = eval.new_ctx(sc, nil, nil, "has_active_tradition")
        local active
        for _, s in ipairs(r.tradition_swaps(trad)) do
            if not s.trigger or eval.trigger(s.trigger, cctx) then active = s break end
        end
        if swap then return active ~= nil and active.name == swap end
        return active == nil or active.inherit_effects
    end

    -- galactic community (`galactic_community = { members leader empire ... }`; none in the saves)
    -- is_galactic_community_member = yes/no (CIsGalacticCommunityMemberTrigger 0x1a044c0)
    TRIG["is_galactic_community_member"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" then return false end
        sync()
        return r.gc_member(sc.id) == yes(e)
    end
    -- is_galactic_custodian / is_galactic_emperor = yes/no (0x1a07170 / 0x1a07250): the community's
    -- leader is the country, without / with the Empire flag
    for _, spec in ipairs({ { "is_galactic_custodian", false }, { "is_galactic_emperor", true } }) do
        local want_empire = spec[2]
        TRIG[spec[1]] = function(e, ctx)
            local r, sc = rt(), ctx.this
            if not r or sc.kind ~= "country" then return false end
            sync()
            local leader, empire = r.gc_leader()
            return (leader == sc.id and empire == want_empire) == yes(e)
        end
    end

    -- is_active_resolution = <resolution> (CIsActiveResolutionTrigger 0x1a064d0, any scope): the
    -- newest passed resolution of the type, not superseded by a newer one of its category (unless
    -- the category allows several), whose can_be_active holds
    TRIG["is_active_resolution"] = function(e, ctx)
        local r = rt()
        local v = e.value.text
        if not r or not v then return false end
        sync()
        return r.is_active_resolution(v, function(block, proposer, tgt)
            local c = eval.new_ctx(proposer and S("country", proposer) or NONE,
                tgt and S("country", tgt) or NONE, nil, "is_active_resolution")
            return eval.trigger(block, c)
        end)
    end

    -- has_federation_type = <type> (CHasFederationTypeTrigger 0x1a17fa0, a federation):
    -- `federation_progression = { federation_type }`
    TRIG["has_federation_type"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or sc.kind ~= "federation" or not v then return false end
        sync()
        return r.federation_field(sc.id, "federation_type") == v
    end

    -- situation_progress <op> x (CSituationProgressTrigger 0x19c10e0, a situation): its `progress`
    numeric("situation_progress", { "situation" }, function(sc, r)
        return tonumber(r.situation_field(sc.id, "progress")) or 0
    end)

    -- -----------------------------------------------------------------------------------------
    -- leaders and pop groups

    -- is_councilor = yes/no (CIsCouncilorTrigger 0x19beb90, a leader): the ruler, or in a council
    -- position
    TRIG["is_councilor"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "leader" then return false end
        sync()
        return r.is_councilor(sc.id) == yes(e)
    end

    -- has_ethic = <ethic> on a pop group (its `ethos = { ethics }`, CPopGroup::HasEthic 0x51a480) or a
    -- leader (its background `ethic`, CLeader +0x6d8); a country's stays the property trigger's
    local has_ethic_prop = eval.property("has_ethic")
    TRIG["has_ethic"] = function(e, ctx, lk)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if sc.kind == "pop_group" or sc.kind == "leader" then
            if not r or not v then return false end
            sync()
            return r.has_ethic(sc.kind, sc.id, v)
        end
        if has_ethic_prop then return has_ethic_prop(e, ctx, lk or "has_ethic") end
        return false
    end

    -- has_owner = yes/no on a ship (CHasOwnerTrigger 0x1948730: its fleet's owner exists); the other
    -- scopes stay the property trigger's
    local has_owner_prop = eval.property("has_owner")
    TRIG["has_owner"] = function(e, ctx, lk)
        local r, sc = rt(), ctx.this
        if sc.kind == "ship" then
            if not r then return false end
            sync()
            return (r.fleet_owner(r.ship_fleet(sc.id)) ~= nil) == yes(e)
        end
        if has_owner_prop then return has_owner_prop(e, ctx, lk or "has_owner") end
        return false
    end

    -- triggers whose scope check fails on a scope the property trigger answered for its owner or as
    -- `= no`: has_trait (no planet), is_country_type, is_ai (a country only), is_megastructure_type
    -- (a megastructure only), is_planet_class (a planet, ship or colony carrier's class)
    local function scoped_property(name, kinds)
        local ok = {}
        for _, k in ipairs(kinds) do ok[k] = true end
        local prev = TRIG[name] or eval.property(name)
        TRIG[name] = function(e, ctx, lk)
            if not ok[ctx.this.kind] then return false end
            return prev(e, ctx, lk or name)
        end
    end
    scoped_property("is_country_type", { "country" })
    scoped_property("is_ai", { "country" })
    scoped_property("is_megastructure_type", { "megastructure" })
    TRIG["is_planet_class"] = (function()
        local prev = TRIG["is_planet_class"] or eval.property("is_planet_class")
        return function(e, ctx, lk)
            local sc = ctx.this
            if sc.kind == "ship" then
                local r = rt()
                if not r or not e.value.text then return false end
                sync()
                return r.ship_field(sc.id, "planet_class") == e.value.text
            end
            if sc.kind ~= "planet" and sc.kind ~= "colony" then return false end
            return prev(e, ctx, lk or "is_planet_class")
        end
    end)()

    -- -----------------------------------------------------------------------------------------
    -- scope links

    -- space_owner (CEventTarget::GetScope 0x353390, token 16535): the owner of the system the scope
    -- is in: a country itself; a system's; a planet's, colony's, megastructure's, starbase's,
    -- archaeological site's system's; a fleet's (its movement coordinate, else the last jump's
    -- origin); a ship's fleet's; a spy network's own owner
    local function space_owner(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        sync()
        if cur.kind == "country" then return cur end
        local sid
        if cur.kind == "spy_network" then
            local o = r.spy_network_owner(cur.id)
            return o and S("country", o) or nil
        elseif cur.kind == "fleet" or cur.kind == "ship" then
            local fid = cur.kind == "fleet" and cur.id or r.ship_fleet(cur.id)
            sid = fid and (r.system_of("fleet", fid) or r.last_jump_origin(fid))
        elseif cur.kind == "archaeological_site" then
            sid = r.site_system(cur.id)
        else
            sid = r.system_of(cur.kind, cur.id)
        end
        local o = sid and r.system_owner(sid)
        return o and S("country", o) or nil
    end
    LINKS["space_owner"] = space_owner

    -- owner_or_space_owner (token 16536): the `owner` link when it gives a country, else space_owner
    LINKS["owner_or_space_owner"] = function(cur, ctx)
        local o = LINKS.owner and LINKS.owner(cur, ctx)
        if o and o ~= NONE and o.kind == "country" then return o end
        return space_owner(cur)
    end

    -- orbital_defence (token 16303): a planet's `orbital_defence` fleet (a colony's planet carrier's)
    LINKS["orbital_defence"] = function(cur)
        local r = rt()
        if not r then return nil end
        sync()
        local kind, id = cur.kind, cur.id
        if kind == "colony" then kind, id = r.carrier_of("colony", id) end
        if kind ~= "planet" then return nil end
        local f = r.ref(r.planet_field(id, "orbital_defence"))
        return (f and r.obj("fleet", f)) and S("fleet", f) or nil
    end

    -- sector (token 13120): a system's `sector`; a sector itself; any object in a system: its
    -- system's (leaders, countries and other scopes: none)
    LINKS["sector"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        if cur.kind == "sector" then return cur end
        if cur.kind == "country" or cur.kind == "leader" or cur.kind == "species" then return nil end
        sync()
        local sid = r.system_of(cur.kind, cur.id)
        local sec = sid and r.ref(r.system_field(sid, "sector"))
        return (sec and r.obj("sector", sec)) and S("sector", sec) or nil
    end

    -- archaeological_site (token 15661): the site at the scope's spatial object
    LINKS["archaeological_site"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        sync()
        local s = r.site_at(cur.kind, cur.id)
        return s and S("archaeological_site", s) or nil
    end

    -- carrier (token 17903): a colony's carrier (a planet or a ship)
    LINKS["carrier"] = function(cur)
        local r = rt()
        if not r or cur.kind ~= "colony" then return nil end
        sync()
        local kind, id = r.carrier_of("colony", cur.id)
        return kind and S(kind, id) or nil
    end

    -- fleet (token 11350): a fleet itself; a ship's fleet; a starbase's station's fleet; a colony
    -- carried by a ship: that ship's fleet
    LINKS["fleet"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        if cur.kind == "fleet" then return cur end
        sync()
        local ship
        if cur.kind == "ship" then ship = cur.id
        elseif cur.kind == "starbase" then
            ship = r.ref(r.starbase_field(cur.id, "station"))
        elseif cur.kind == "colony" then
            local kind, id = r.carrier_of("colony", cur.id)
            if kind == "ship" then ship = id end
        end
        local f = ship and r.ship_fleet(ship)
        return (f and r.obj("fleet", f)) and S("fleet", f) or nil
    end

    -- starbase (token 14911): a starbase itself; a system's primary starbase (the first of its
    -- `starbases`; none when that one does not exist); a planet's or colony's system's; a starbase
    -- fleet's (shipclass_starbase): the starbase of its first ship; a ship of class
    -- shipclass_starbase: the starbase it is the station of
    LINKS["starbase"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        if cur.kind == "starbase" then return cur end
        sync()
        local sb
        if cur.kind == "system" then
            sb = r.primary_starbase(cur.id)
        elseif cur.kind == "planet" or cur.kind == "colony" then
            local sid = r.system_of(cur.kind, cur.id)
            sb = sid and r.primary_starbase(sid)
        elseif cur.kind == "fleet" then
            if r.fleet_field(cur.id, "ship_class") == "shipclass_starbase" then
                local s1 = r.fleet_ships(cur.id)[1]
                sb = s1 and r.starbase_of_station(s1)
            end
        elseif cur.kind == "ship" then
            if r.ship_size_field(r.ship_size_of(cur.id), "class") == "shipclass_starbase" then
                sb = r.starbase_of_station(cur.id)
            end
        end
        return sb and S("starbase", sb) or nil
    end

    -- -----------------------------------------------------------------------------------------
    -- lists

    local function scopes(kind, ids)
        local out = {}
        for i, id in ipairs(ids) do out[i] = S(kind, id) end
        return out
    end
    -- neighbor_system (CNeighborSystemListBuilder 0x18174c0, a system): its hyperlanes' systems, in
    -- order, not deduplicated
    LISTS["neighbor_system"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        return scopes("system", r.hyperlanes(sc.id))
    end
    -- owned_fleet (COwnedFleetListBuilder 0x1813f40, a country): every owned fleet entry
    LISTS["owned_fleet"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "country" then return {} end
        sync()
        return scopes("fleet", r.owned_fleets(sc.id))
    end
    -- controlled_fleet (CControlledFleetListBuilder, a country): the fleets it controls
    LISTS["controlled_fleet"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "country" then return {} end
        sync()
        return scopes("fleet", r.controlled_fleets(sc.id))
    end
    -- owned_ship / controlled_ship (COwnedShipListBuilder 0x1815c00, CControlledShipListBuilder
    -- 0x1815ea0, a country or fleet): the alive ships of its owned (controlled) fleets, a fleet's own
    for _, spec in ipairs({ { "owned_ship", "owned_fleets" }, { "controlled_ship", "controlled_fleets" } }) do
        local fleets_of = spec[2]
        LISTS[spec[1]] = function(sc)
            local r = rt()
            if not r then return {} end
            sync()
            if sc.kind == "fleet" then return scopes("ship", r.alive_ships({ sc.id })) end
            if sc.kind ~= "country" then return {} end
            return scopes("ship", r.alive_ships(r[fleets_of](sc.id)))
        end
    end
    -- fleet_in_system (CFleetSystemListBuilder, a system): its fleet presence (`fleet_presence`,
    -- CGalacticObject +0x1038; the fleet movement keeps it)
    LISTS["fleet_in_system"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        local out = {}
        for _, f in ipairs(r.system_list(sc.id, "fleet_presence")) do
            if r.obj("fleet", f) then out[#out + 1] = S("fleet", f) end
        end
        return out
    end
    -- system_megastructure (CSystemMegaStructureListBuilder, a system): its `megastructures`
    LISTS["system_megastructure"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        local out = {}
        for _, m in ipairs(r.system_list(sc.id, "megastructures")) do
            if r.obj("megastructure", m) then out[#out + 1] = S("megastructure", m) end
        end
        return out
    end
    -- system (CSystemListBuilder 0x1817340): every system of the galaxy
    LISTS["system"] = function()
        local r = rt()
        if not r then return {} end
        sync()
        return scopes("system", r.all("system"))
    end
    LISTS["galaxy_system"] = LISTS["galaxy_system"] or LISTS["system"]
    -- archaeological_site (CArchaeologicalSiteListBuilder 0x1812560): every site
    LISTS["archaeological_site"] = function()
        local r = rt()
        if not r then return {} end
        sync()
        return scopes("archaeological_site", r.all("archaeological_site"))
    end
    -- spynetwork (CSpyNetworkListBuilder 0x1813890): a country's espionage_manager.spy_networks;
    -- from any other scope, every spy network
    LISTS["spynetwork"] = function(sc)
        local r = rt()
        if not r then return {} end
        sync()
        if sc.kind == "country" then return scopes("spy_network", r.country_spy_networks(sc.id)) end
        return scopes("spy_network", r.all("spy_network"))
    end

    -- =========================================================================================
    -- the most used keywords of vanilla not reached by the 180-day run (docs/script_runtime.md,
    -- "Vanilla keywords")

    -- a trigger on one scope kind comparing a field read by get(sc, r) with the argument text
    local function equals_field(name, kinds, get)
        local ok = {}
        for _, k in ipairs(kinds) do ok[k] = true end
        TRIG[name] = function(e, ctx)
            local r, sc = rt(), ctx.this
            local v = e.value.text
            if not r or not v or not ok[sc.kind] then return false end
            sync()
            local have = get(sc, r)
            return have ~= nil and have == v
        end
    end
    -- a yes/no trigger: test(sc, r) -> the condition; on another scope `other` (default false)
    local function yes_no_trigger(name, kinds, test, other)
        local ok = {}
        for _, k in ipairs(kinds) do ok[k] = true end
        TRIG[name] = function(e, ctx)
            local r, sc = rt(), ctx.this
            if not r then return false end
            if not ok[sc.kind] then
                if other == "no" then return not yes(e) end
                return false
            end
            sync()
            return (test(sc, r) and true or false) == yes(e)
        end
    end
    local function wfield(o, key) return require("engine.world").field(o, key) end

    -- situations
    -- is_situation_type = <type> (CSituationTypeTrigger 0x19c1630): the situation's `type`
    equals_field("is_situation_type", { "situation" }, function(sc, r) return r.situation_field(sc.id, "type") end)
    -- current_situation_approach = <approach> (CCurrentSituationApproachTrigger 0x19c2010): an
    -- approach of the situation's type, and the situation's `approach`
    TRIG["current_situation_approach"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "situation" then return false end
        sync()
        if not r.situation_has_approach(r.situation_field(sc.id, "type"), v) then return false end
        return r.situation_field(sc.id, "approach") == v
    end
    -- current_stage = <stage> (CCurrentStageTrigger 0x19c1970): the key of the situation's stage
    equals_field("current_stage", { "situation" }, function(sc, r) return r.situation_stage_key(sc.id) end)
    -- situation_monthly_progress <op> x (CSituationMonthlyProgressTrigger 0x19c1470): the latest
    -- monthly progress (+0x220): engine.situations' computed one, else the saved
    -- `last_month_progress` (as engine/situations.lua's own version read it)
    numeric("situation_monthly_progress", { "situation" }, function(sc, r)
        local sit = package.loaded["engine.situations"]
        local m = type(sit) == "table" and sit.monthly and sit.monthly[sc.id]
        if m ~= nil then return m / 100000 end
        return tonumber(r.situation_field(sc.id, "last_month_progress")) or 0
    end)

    -- federations
    -- has_federation_law = <law> (CFederation::HasLaw 0x666e80): the law enacted in its category
    TRIG["has_federation_law"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "federation" then return false end
        sync()
        for _, law in pairs(r.federation_laws(sc.id)) do
            if law == v then return true end
        end
        return false
    end
    -- has_any_federation_law_in_category = <category> (0x1a18c10): a law enacted in the category
    TRIG["has_any_federation_law_in_category"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "federation" then return false end
        sync()
        return r.federation_laws(sc.id)[v] ~= nil
    end
    -- has_federation_perk = <perk> (CHasFederationPerkTrigger 0x1a181b0): an unlocked perk's `type`
    TRIG["has_federation_perk"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "federation" then return false end
        sync()
        for _, p in ipairs(r.federation_perks(sc.id)) do
            if p == v then return true end
        end
        return false
    end
    -- federation_cohesion <op> x (CFederationCohesionTrigger 0x1a17d60)
    numeric("federation_cohesion", { "federation" }, function(sc, r)
        return tonumber(r.federation_field(sc.id, "cohesion")) or 0
    end)

    -- the galactic community and the galaxy setup
    -- has_galactic_emperor / has_galactic_custodian = yes/no (0x1a07440 / 0x1a07330, any scope)
    TRIG["has_galactic_emperor"] = function(e)
        local r = rt()
        if not r then return false end
        sync()
        local leader, empire = r.gc_leader()
        return (leader ~= nil and empire) == yes(e)
    end
    TRIG["has_galactic_custodian"] = function(e)
        local r = rt()
        if not r then return false end
        sync()
        local leader, empire = r.gc_leader()
        return (leader ~= nil and not empire) == yes(e)
    end
    -- is_part_of_galactic_council = yes/no (0x1a04830): the community's leader, or in `council`
    yes_no_trigger("is_part_of_galactic_council", { "country" }, function(sc, r)
        local leader = r.gc_leader()
        if leader == sc.id then return true end
        local gc = r.galactic_community()
        for _, v in ipairs(require("engine.world").list(gc and wfield(gc, "council"))) do
            if tonumber(v) == sc.id then return true end
        end
        return false
    end)
    -- is_galactic_council_established = yes/no (0x1a063e0, any scope): `council_established` set
    TRIG["is_galactic_council_established"] = function(e)
        local r = rt()
        if not r then return false end
        sync()
        local gc = r.galactic_community()
        return (gc ~= nil and wfield(gc, "council_established") ~= nil) == yes(e)
    end
    -- galactic_community_rank <op> n (CGalacticCommunityRankTrigger 0x1a06920): 1 + its index in
    -- `members`, -1 when not a member
    numeric("galactic_community_rank", { "country" }, function(sc, r)
        local gc = r.galactic_community()
        for i, v in ipairs(require("engine.world").list(gc and wfield(gc, "members"))) do
            if tonumber(v) == sc.id then return i end
        end
        return -1
    end)
    -- imperial_authority <op> x (CImperialAuthorityTrigger 0x1a07080, any scope)
    TRIG["imperial_authority"] = function(e, ctx)
        local r = rt()
        if not r then return false end
        sync()
        local gc = r.galactic_community()
        return compare_num(gc and tonumber(wfield(gc, "imperial_authority")) or 0, e, ctx)
    end
    -- galaxy_size = <template> (CGalaxySizeTrigger 0x19b4fc0, any scope): `galaxy = { template }`
    TRIG["galaxy_size"] = function(e)
        local r = rt()
        return r ~= nil and e.value.text ~= nil and r.galaxy_field("template") == e.value.text
    end
    -- num_guaranteed_colonies <op> n (0x1959200, any scope)
    TRIG["num_guaranteed_colonies"] = function(e, ctx)
        local r = rt()
        if not r then return false end
        return compare_num(tonumber(r.galaxy_field("num_guaranteed_colonies")) or 0, e, ctx)
    end
    -- is_difficulty <op> <level> (CIsDifficultyTrigger 0x19776d0, any scope): EDifficulty of
    -- `galaxy = { difficulty }`, a level name or a number on the right
    local DIFFICULTY = { civilian = 0, cadet = 1, ensign = 2, captain = 3, commodore = 4, admiral = 5, grand_admiral = 6 }
    TRIG["is_difficulty"] = function(e, ctx)
        local r = rt()
        if not r then return false end
        local have = DIFFICULTY[tostring(r.galaxy_field("difficulty"))]
        if have == nil then return false end
        local want = e.value.text and DIFFICULTY[e.value.text] or eval.value(e.value, ctx, e)
        return compare(have, e.op, want)
    end
    -- check_galaxy_setup_value = { setting = x value <op> y } (CCheckGalaxySetupValueTrigger
    -- 0x196b4c0, any scope): the galaxy setup's value of the setting (its field of `galaxy`;
    -- mid/end game and victory years from mid_game_start, end_game_start, victory_year: -1 the
    -- defaults 100 / 200 / 300); an unknown setting: -1
    local SETUP_FIELD = { mid_game_year = { "mid_game_start", 100 }, end_game_year = { "end_game_start", 200 },
        victory_year = { "victory_year", 300 } }
    TRIG["check_galaxy_setup_value"] = function(e, ctx)
        local r = rt()
        if not r or e.value.text then return false end
        local p = params(e)
        local setting, val = p.setting and p.setting.value.text, p.value
        if not setting or not val then return false end
        local spec = SETUP_FIELD[setting]
        local v = tonumber(r.galaxy_field(spec and spec[1] or setting))
        if spec and (v == nil or v == -1) then v = spec[2] end
        return compare(v or -1, val.op, eval.value(val.value, ctx, val))
    end

    -- countries
    -- has_tech_option = <technology> (CHasTechnologyOptionTrigger 0x1954d90): among the research
    -- options of the technology's area (`tech_status = { alternatives = { <area> = { } } }`)
    TRIG["has_tech_option"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        local area = r.tech_area(v)
        if not area then return false end
        for _, t in ipairs(r.tech_alternatives(sc.id, area)) do
            if t == v then return true end
        end
        return false
    end
    -- can_research_technology = <technology> (CCountry::CanResearchTechnology 0x72ebb0): every
    -- prerequisite can be researched in turn, and the technology's `potential` holds for the
    -- country (no potential: holds); researched or not does not matter
    TRIG["can_research_technology"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        local cctx = eval.new_ctx(sc, nil, nil, "can_research_technology")
        local memo = {}
        local function can(t, depth)
            if memo[t] ~= nil then return memo[t] end
            local d = r.defs().get("common/technology", t)
            if not d or depth > 64 then memo[t] = false return false end
            memo[t] = true
            local ok = true
            local pre = r.defs().field(d.block, "prerequisites")
            for _, x in ipairs(type(pre) == "table" and pre or {}) do
                if x.text and not can(x.text, depth + 1) then ok = false break end
            end
            if ok then
                local pot = r.defs().field(d.block, "potential")
                if type(pot) == "table" and not eval.trigger(pot, cctx) then ok = false end
            end
            memo[t] = ok
            return ok
        end
        return can(v, 0)
    end
    -- has_pre_ftl_age = <age> (CHasPreFtlAge 0x195e4d0): `preftl_age`
    equals_field("has_pre_ftl_age", { "country" }, function(sc, r) return r.country_field(sc.id, "preftl_age") end)
    -- has_notification_modifier = <modifier> (0x19abb30): in `notification_modifiers`
    TRIG["has_notification_modifier"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        for _, m in ipairs(r.country_list(sc.id, "notification_modifiers")) do
            if m == v then return true end
        end
        return false
    end
    -- has_valid_ai_personality = yes/no (0x1957600): `personality` names a personality
    yes_no_trigger("has_valid_ai_personality", { "country" }, function(sc, r)
        local p = r.country_field(sc.id, "personality")
        return type(p) == "string" and r.defs().get("common/personalities", p) ~= nil
    end)
    -- is_preferred_patron = <patron> (CIsPreferredPatronTrigger 0x1a25530): `is_preferred_patron`
    -- [I: the field's form]
    equals_field("is_preferred_patron", { "country" }, function(sc, r) return r.country_field(sc.id, "is_preferred_patron") end)
    -- is_preferred_weapons = <weapon type> (CIsFavoriteWeaponTrigger 0x199f4c0): the country's
    -- ai_weapon_preference_override, else its personality's weapon_preferences
    equals_field("is_preferred_weapons", { "country" }, function(sc, r)
        local o = r.country_field(sc.id, "ai_weapon_preference_override")
        if type(o) == "string" and o ~= "" then return o end
        local p = r.country_field(sc.id, "personality")
        local d = type(p) == "string" and r.defs().get("common/personalities", p)
        return d and r.defs().field(d.block, "weapon_preferences") or ""
    end)
    -- galaxy_percentage <op> x (CGalaxyPercentageTrigger 0x19962c0): the systems it owns over all
    numeric("galaxy_percentage", { "country" }, function(sc, r)
        local all = r.all("system")
        if #all == 0 then return -1 end
        local n = 0
        for _, sid in ipairs(all) do
            if r.system_owner(sid) == sc.id then n = n + 1 end
        end
        return n / #all
    end)
    -- current_awareness_level <op> <level> (CAwarenessStageTrigger 0x1974790, a primitive country):
    -- the stage of its awareness: < 1 none, < 30 low, < 60 medium, < 100 high, else full
    local AWARENESS = { none = 1, low = 2, medium = 3, high = 4, full = 5 }
    TRIG["current_awareness_level"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" then return false end
        sync()
        if r.country_type_flag(sc.id, "faction", "primitive") ~= "yes" then return false end
        local a = tonumber(r.country_field(sc.id, "awareness")) or 0
        local stage = a < 1 and 1 or a < 30 and 2 or a < 60 and 3 or a < 100 and 4 or 5
        local want = e.value.text and AWARENESS[e.value.text] or eval.value(e.value, ctx, e)
        return compare(stage, e.op, want)
    end
    -- num_cosmic_storms_encountered <op> n (CNumCosmicStormsEncountered 0x19ba810)
    numeric("num_cosmic_storms_encountered", { "country" }, function(sc, r)
        return tonumber(r.country_field(sc.id, "num_cosmic_storms_encountered")) or 0
    end)
    -- num_tradition_categories <op> n (0x197eb30): `tradition_categories`
    numeric("num_tradition_categories", { "country" }, function(sc, r) return #r.country_list(sc.id, "tradition_categories") end)
    -- empire_size <op> n (CEmpireSizeTrigger 0x1985850): the cached `empire_size`
    numeric("empire_size", { "country" }, function(sc, r) return tonumber(r.country_field(sc.id, "empire_size")) or 0 end)
    -- category_last_picked_tradition = <category> (0x1a23160): the category of
    -- `last_picked_tradition`
    TRIG["category_last_picked_tradition"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        local last = r.country_field(sc.id, "last_picked_tradition")
        return type(last) == "string" and r.tradition_category(last) == v
    end
    -- has_failed_special_project_in_log = <project> (CHasSpecialProjectStatusTrigger<Failed>
    -- 0x19e5460): a special project of the key aborted, failed or timed out
    local FAILED = { aborted = true, failed = true, timed_out = true }
    TRIG["has_failed_special_project_in_log"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        for _, b in ipairs(r.country_events(sc.id, "special_project")) do
            if wfield(b, "special_project") == v and FAILED[tostring(wfield(b, "status"))] then return true end
        end
        return false
    end
    -- has_completed_event_chain_counter = { event_chain = x counter = y } (0x1979780): an active chain
    -- of the key whose tracker count of the counter reached the counter's max (`counter = { n ... }`
    -- in counter order of common/event_chains [I])
    TRIG["has_completed_event_chain_counter"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" or e.value.text then return false end
        local p = params(e)
        local chain, counter = p.event_chain and p.event_chain.value.text, p.counter and p.counter.value.text
        if not chain or not counter then return false end
        sync()
        local d = r.defs().get("common/event_chains", chain)
        local cdefs = d and r.defs().field(d.block, "counter")
        local idx, max = nil, nil
        local i = 0
        for _, x in ipairs(type(cdefs) == "table" and cdefs or {}) do
            if x.op and x.key and x.value.text == nil then
                i = i + 1
                if x.key.text == counter then idx, max = i, tonumber(r.defs().field(x.value, "max")) end
            end
        end
        if not idx or not max then return false end
        for _, b in ipairs(r.country_events(sc.id, "event_chain")) do
            if wfield(b, "event_chain") == chain then
                local counts = require("engine.world").list(wfield(b, "counter"))
                return (tonumber(counts[idx]) or 0) >= max
            end
        end
        return false
    end
    -- has_active_event = { <event ids> } or <event> (CHasActiveEventTrigger 0x19b2260 ->
    -- CGameState::HasOpenPlayerEvent): an open player event of one of the ids for the country
    -- (`player_event = { event country }`; AI countries have none)
    TRIG["has_active_event"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" then return false end
        local ids = {}
        if e.value.text then ids[e.value.text] = true else
            for _, x in ipairs(e.value) do if x.text then ids[x.text] = true end end
        end
        sync()
        for _, pe in ipairs(r.player_events()) do
            if ids[tostring(wfield(pe, "event"))] and tonumber(wfield(pe, "country")) == sc.id then return true end
        end
        return false
    end
    -- has_election_type = democratic / oligarchic / none (CHasElectionTypeTrigger 0x195bb10): the
    -- election type of the authority's advanced_authority_swap that applies to the country (the first
    -- whose trigger holds and that sets one), else the authority's
    TRIG["has_election_type"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        local gov = r.country_field(sc.id, "government")
        local auth = type(gov) == "table" and wfield(gov, "authority")
        local d = auth and r.defs().get("common/governments/authorities", auth)
        if not d then return false end
        local t
        local cctx = eval.new_ctx(sc, nil, nil, "has_election_type")
        for _, x in ipairs(d.block) do
            if x.op and x.key and x.key.text == "advanced_authority_swap" and x.value.text == nil then
                local et = r.defs().field(x.value, "election_type")
                local trig = r.defs().field(x.value, "trigger")
                if et and (type(trig) ~= "table" or eval.trigger(trig, cctx)) then t = et break end
            end
        end
        t = t or r.defs().field(d.block, "election_type") or "none"
        return t == v
    end
    -- has_faction = <type> (CHasFactionTrigger 0x198b530): a pop faction of the country of the type
    TRIG["has_faction"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "country" then return false end
        sync()
        for _, f in ipairs(r.pop_factions(sc.id)) do
            if r.pop_faction_field(f, "type") == v then return true end
        end
        return false
    end
    -- the Shroud: is_in_domain, has_patron_relation need the Shroud DLC (bit 30 of _DLCMask), not
    -- in the game's install or the saves: false, as the game evaluates them without it
    local function shroud_enabled() return E.has_dlc and E.has_dlc("The Shroud") or false end
    for _, k in ipairs({ "is_in_domain", "has_patron_relation" }) do
        TRIG[k] = function(e, ctx)
            if ctx.this.kind ~= "country" or not shroud_enabled() then return false end
            miss("trigger", k .. " (with the Shroud)", ctx, e)
            return false
        end
    end

    -- pop factions
    equals_field("is_pop_faction_type", { "pop_faction" }, function(sc, r) return r.pop_faction_field(sc.id, "type") end)
    yes_no_trigger("is_faction_extorted", { "pop_faction" }, function(sc, r) return r.pop_faction_field(sc.id, "extorted") == "yes" end)
    -- support <op> x (CSupportTrigger 0x198b8c0): a faction's `support_percent`; a leader's: the
    -- factions of its country whose type's ethic is the leader's
    numeric("support", { "pop_faction", "leader" }, function(sc, r)
        if sc.kind == "pop_faction" then return tonumber(r.pop_faction_field(sc.id, "support_percent")) or 0 end
        local ethic = r.leader_field(sc.id, "ethic")
        local c = r.ref(r.leader_field(sc.id, "country"))
        if not ethic or not c then return 0 end
        local sum = 0
        for _, f in ipairs(r.pop_factions(c)) do
            local t = r.pop_faction_field(f, "type")
            local d = t and r.defs().get("common/pop_faction_types", t)
            if d and r.defs().field(d.block, "ethic") == ethic then
                sum = sum + (tonumber(r.pop_faction_field(f, "support_percent")) or 0)
            end
        end
        return sum
    end)
    -- list pop_faction (CPopFactionListBuilder 0x1814fb0): a country's factions
    LISTS["pop_faction"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "country" then return {} end
        sync()
        return scopes("pop_faction", r.pop_factions(sc.id))
    end
    require("engine.world").KINDS.pop_faction = require("engine.world").KINDS.pop_faction or "pop_factions"

    -- leaders
    -- is_heir = yes/no (CIsHeirTrigger 0x19bea00): its country's `government = { heir }`
    yes_no_trigger("is_heir", { "leader" }, function(sc, r)
        local c = r.ref(r.leader_field(sc.id, "country"))
        local gov = c and r.country_field(c, "government")
        return type(gov) == "table" and tonumber(wfield(gov, "heir")) == sc.id
    end)
    -- is_immortal = yes/no (CLeader::IsImmortal 0x895700): the Immortal leader flag (2), a trait of
    -- the leader or its species with immortal_leaders = yes [I: the species part], or the game rule
    -- are_all_leaders_forced_immortal for its country
    yes_no_trigger("is_immortal", { "leader" }, function(sc, r)
        local f = tonumber(r.leader_field(sc.id, "leader_flags")) or 0
        if math.floor(f / 2) % 2 == 1 then return true end
        for _, t in ipairs(r.leader_traits(sc.id)) do
            if r.trait_field(t, "immortal_leaders") == "yes" then return true end
        end
        local sp = r.ref(r.leader_field(sc.id, "species"))
        for _, t in ipairs(sp and r.species_traits(sp) or {}) do
            if r.trait_field(t, "immortal_leaders") == "yes" then return true end
        end
        local rule = r.defs().get("common/game_rules", "are_all_leaders_forced_immortal")
        local c = r.ref(r.leader_field(sc.id, "country"))
        if rule and c then
            return eval.trigger(rule.block, eval.new_ctx(S("country", c), nil, nil, rule.file))
        end
        return false
    end)
    -- num_traits <op> n (CNumTraitsTrigger 0x1987760): a leader's traits; a country's founder
    -- species', a pop group's species', a species' own
    numeric("num_traits", { "country", "pop_group", "leader", "species" }, function(sc, r)
        if sc.kind == "leader" then return #r.leader_traits(sc.id) end
        local sid = E.species_of and E.species_of(sc.kind, sc.id)
        return sid and #r.species_traits(sid) or 0
    end)

    -- species rights: has_purge_type, has_living_standard, has_military_service_type = { type = x
    -- country = <who> } (CHasSpeciesRightsTrigger<...> 0x1a2b080 / 0x1a29460 / 0x1a2be90): the
    -- country's (by default the scope's owner) rights for the scope's species
    for _, spec in ipairs({ { "has_purge_type", "purge" }, { "has_living_standard", "living_standard" },
        { "has_military_service_type", "military_service" } }) do
        local key = spec[2]
        TRIG[spec[1]] = function(e, ctx)
            local sc = ctx.this
            if not E.species_right or sc == NONE or e.value.text then return false end
            if sc.kind ~= "pop_group" and sc.kind ~= "leader" and sc.kind ~= "species" then return false end
            local p = params(e)
            local want = p.type and p.type.value.text
            local who
            if p.country and p.country.value.text then
                local f, s2 = eval.resolve(p.country.value.text, ctx, p.country)
                who = f and s2 or nil
            else
                who = LINKS.owner and LINKS.owner(sc, ctx)
            end
            if not want or not who or who.kind ~= "country" then return false end
            sync()
            local sid = E.species_of(sc.kind, sc.id)
            return sid ~= nil and E.species_right(who.id, sid, key) == want
        end
    end

    -- planets, colonies, carriers
    -- the planet a scope's carrier is (a planet; a colony's planet carrier; nil for a ship carrier)
    local function carrier_planet(sc, r)
        local kind, id = r.carrier_of(sc.kind, sc.id)
        return kind == "planet" and id or nil
    end
    -- planet class flags read through the planet scope only (is_star, is_asteroid: a ship or colony
    -- scope never reaches its planet in the game, `= no` holds; is_astral_scar: false)
    yes_no_trigger("is_star", { "planet" }, function(sc, r) return r.planet_class_flag(sc.id, "star") end, "no")
    yes_no_trigger("is_asteroid", { "planet" }, function(sc, r) return r.planet_class_flag(sc.id, "asteroid") end, "no")
    yes_no_trigger("is_astral_scar", { "planet" }, function(sc, r) return r.planet_class_flag(sc.id, "astral_scar") end)
    -- is_ringworld = yes/no (CIsRingworldTrigger 0x195d7a0): the carrier class's ringworld flag
    yes_no_trigger("is_ringworld", { "planet", "colony" }, function(sc, r)
        local p = carrier_planet(sc, r)
        return p ~= nil and r.planet_class_flag(p, "ringworld")
    end)
    -- has_climate = <climate> (CPlanetClimateTrigger 0x1a09670): the carrier class's `climate`
    TRIG["has_climate"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local p = carrier_planet(sc, r)
        return p ~= nil and r.planet_class_field(p, "climate") == v
    end
    -- is_moon = yes/no (CIsMoonTrigger 0x195cb50): the IsMoon planet flag (512 of `binary_flags`);
    -- another scope: `= no` holds
    TRIG["is_moon"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return not yes(e) end
        local is = kind == "planet" and math.floor((tonumber(r.planet_field(id, "binary_flags")) or 0) / 512) % 2 == 1
        return is == yes(e)
    end
    -- has_moon = yes/no (CHasMoonTrigger 0x195cd30): the planet has `moons`; the trigger has no
    -- yes/no field, so `= no` is the same as `= yes`
    TRIG["has_moon"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local p = carrier_planet(sc, r)
        return p ~= nil and #require("engine.world").list(r.planet_field(p, "moons")) > 0
    end
    -- planet_size <op> n (CPlanetSizeTrigger 0x1986400): the carrier's `planet_size`
    numeric("planet_size", { "planet", "ship", "colony" }, function(sc, r)
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if kind ~= "planet" then return nil end
        return tonumber(r.planet_field(id, "planet_size"))
    end)
    -- is_star_class = <star class | system> (CIsStarClassTrigger 0x1953200): the star class of the
    -- system of a planet, a ship or the system itself
    TRIG["is_star_class"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local want = v
        if not v:match("^sc_") then
            local t = target(e, ctx)
            if not t or t.kind ~= "system" then return false end
            want = r.system_field(t.id, "star_class")
        end
        local sid
        if sc.kind == "system" then sid = sc.id
        elseif sc.kind == "planet" or sc.kind == "ship" then sid = r.system_of(sc.kind, sc.id) end
        return sid ~= nil and r.system_field(sid, "star_class") == want
    end
    -- has_planet_modifier = <modifier> (CHasPlanetModifierTrigger 0x19866a0): the planet's
    -- `planet_modifier` entries
    TRIG["has_planet_modifier"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local p = carrier_planet(sc, r)
        if not p then return false end
        for _, m in ipairs(require("engine.world").fields(r.obj("planet", p), "planet_modifier")) do
            if m == v then return true end
        end
        return false
    end
    -- the planet's orbital station: has_mining_station / has_research_station (its fleet's class),
    -- has_orbital_station (any); a ship or another scope: `= no` holds
    for _, spec in ipairs({ { "has_mining_station", "shipclass_mining_station" },
        { "has_research_station", "shipclass_research_station" }, { "has_orbital_station", false } }) do
        local class = spec[2]
        yes_no_trigger(spec[1], { "planet" }, function(sc, r)
            local c = r.orbital_station_class(sc.id)
            return c ~= nil and (not class or c == class)
        end, "no")
    end
    -- has_observation_outpost = yes/no (CHasObservationOutpostTrigger 0x1970e60): the planet's
    -- orbital station is an observation station
    yes_no_trigger("has_observation_outpost", { "planet", "ship", "colony" }, function(sc, r)
        local p = carrier_planet(sc, r)
        return p ~= nil and r.orbital_station_class(p) == "shipclass_observation_station"
    end)
    -- has_deposit_for = <ship class> (CHasDepositForTrigger 0x1984ec0): shipclass_starbase holds;
    -- else the carrier's orbital deposit class: none for an unowned colonizable planet or no
    -- deposits, else the first deposit's type's `station`
    TRIG["has_deposit_for"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return false end
        if v == "shipclass_starbase" then return true end
        if kind == "planet" and r.planet_owner(id) == nil and r.planet_class_flag(id, "colonizable") then return false end
        local d = r.carrier_deposits(kind, id)[1]
        return d ~= nil and r.deposit_type_field(r.deposit_type(d), "station") == v
    end
    -- is_deposit_type / has_deposit_category (a deposit): its type / its type's category
    equals_field("is_deposit_type", { "deposit" }, function(sc, r) return r.deposit_type(sc.id) end)
    equals_field("has_deposit_category", { "deposit" }, function(sc, r) return r.deposit_type_field(r.deposit_type(sc.id), "category") end)
    -- has_any_megastructure = yes/no (CHasAnyMegastructureTrigger 0x19a7a50): a planet's system has
    -- a megastructure at the planet (else `= no` holds); a system has one
    TRIG["has_any_megastructure"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        if sc.kind == "system" then return (#r.system_list(sc.id, "megastructures") > 0) == yes(e) end
        if sc.kind ~= "planet" then return false end
        local sid = r.system_of("planet", sc.id)
        for _, m in ipairs(sid and r.system_list(sid, "megastructures") or {}) do
            local mo = r.obj("megastructure", m)
            if mo and tonumber(wfield(mo, "planet")) == sc.id then return yes(e) end
        end
        return not yes(e)
    end
    -- original_owner = yes/no (COriginalOwnerTrigger 0x19489e0): the carrier's owner is its
    -- original owner; no carrier or owner: `= no` holds
    TRIG["original_owner"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local p = carrier_planet(sc, r)
        local owner = p and r.planet_owner(p)
        if not owner then return not yes(e) end
        return (r.ref(r.planet_field(p, "original_owner")) == owner) == yes(e)
    end
    -- is_terraforming = yes/no (CIsTerraformingTrigger 0x1a09ca0): the planet has a
    -- `scripted_terraform_process` [I: present = running]
    yes_no_trigger("is_terraforming", { "planet", "ship", "colony" }, function(sc, r)
        local p = carrier_planet(sc, r)
        return p ~= nil and r.planet_field(p, "scripted_terraform_process") ~= nil
    end)
    -- is_inside_border = <country> (CIsInsideBorder 0x195c5e0): the owner of the system of a planet,
    -- a ship, a fleet's first ship, or a system is the country
    TRIG["is_inside_border"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        local t = target(e, ctx)
        if not t or t.kind ~= "country" then return false end
        sync()
        local sid
        if sc.kind == "system" then sid = sc.id
        elseif sc.kind == "planet" then sid = r.system_of("planet", sc.id)
        elseif sc.kind == "ship" or sc.kind == "fleet" then
            local fid = sc.kind == "fleet" and sc.id or r.ship_fleet(sc.id)
            if sc.kind == "fleet" and #r.fleet_ships(sc.id) == 0 then return false end
            sid = fid and (r.system_of("fleet", fid) or r.last_jump_origin(fid))
        end
        return sid ~= nil and r.system_owner(sid) == t.id
    end
    -- is_owned_by = <country> (CIsOwnedByTrigger 0x194c930): the scope's owner (the `owner` link)
    -- and the country both exist and are the same
    TRIG["is_owned_by"] = function(e, ctx)
        local t = target(e, ctx)
        if not t or t.kind ~= "country" or ctx.this == NONE then return false end
        local o = LINKS.owner and LINKS.owner(ctx.this, ctx)
        return o ~= nil and o ~= NONE and o.kind == "country" and o.id == t.id
    end
    -- has_ground_combat = yes/no (CHasGroundCombat 0x1958060): the colony's `ground_combat` set
    TRIG["has_ground_combat"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local col = r.colony_of(sc.kind, sc.id)
        local g = col and r.ref(r.colony_field(col, "ground_combat"))
        return (g ~= nil) == yes(e)
    end
    -- num_districts = { type = <district | any> value <op> n } (CNumDistrictsTrigger 0x196f9a0): any:
    -- the levels of the colony's districts; a type: the level of its first district of the type; a
    -- country: summed over its colonies
    TRIG["num_districts"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text then return false end
        local p = params(e)
        local dtype, val = p.type and p.type.value.text or "any", p.value
        if not val then return false end
        sync()
        local function count(col)
            local n = 0
            for _, d in ipairs(require("engine.world").list(r.colony_field(col, "districts"))) do
                local o = r.obj("districts", tonumber(d))
                if o then
                    if dtype == "any" then n = n + (tonumber(wfield(o, "level")) or 0)
                    elseif wfield(o, "type") == dtype then return tonumber(wfield(o, "level")) or 0 end
                end
            end
            return n
        end
        local n = 0
        local col = r.colony_of(sc.kind, sc.id)
        if col then
            n = count(col)
        elseif sc.kind == "country" then
            for _, c in ipairs(require("engine.world").list(r.country_field(sc.id, "owned_planets"))) do
                local cid = tonumber(c)
                if cid and r.obj("colony", cid) then n = n + count(cid) end
            end
        else
            return false
        end
        return compare(n, val.op, eval.value(val.value, ctx, val))
    end
    -- free_housing <op> n (CFreeHousingTrigger 0x197bdf0): the colony's `free_housing`, truncated
    numeric("free_housing", { "planet", "ship", "colony" }, function(sc, r)
        local col = r.colony_of(sc.kind, sc.id)
        local v = col and tonumber(r.colony_field(col, "free_housing")) or 0
        return v < 0 and math.ceil(v) or math.floor(v)
    end)
    -- free_jobs <op> n (CFreeJobsTrigger 0x1959b50): the vacancies of the colony's jobs with a
    -- workforce (workforce_limit - workforce, summed, at least 0)
    numeric("free_jobs", { "planet", "ship", "colony" }, function(sc, r)
        local col = r.colony_of(sc.kind, sc.id)
        if not col then return 0 end
        local sum = 0
        for _, v in ipairs(require("engine.world").list(r.colony_field(col, "pop_jobs"))) do
            local j = r.obj("pop_job", tonumber(v))
            if j and (tonumber(wfield(j, "max_workforce")) or 0) > 0 then
                sum = sum + (tonumber(wfield(j, "workforce_limit")) or 0) - (tonumber(wfield(j, "workforce")) or 0)
            end
        end
        return math.max(0, sum)
    end)
    -- num_assigned_jobs = { job = x value <op> n } (CNumAssignedJobsTrigger 0x199b750): the pop
    -- amounts of the colony's first job of the type (a country's colonies, a system's colonies summed)
    TRIG["num_assigned_jobs"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text then return false end
        local p = params(e)
        local job, val = p.job and p.job.value.text, p.value
        if not job or not val then return false end
        sync()
        local function count(col)
            local j = r.colony_job(col, job)
            local n = 0
            for _, b in ipairs(require("engine.world").blocks(j and wfield(j, "pop_groups"))) do
                n = n + (tonumber(wfield(b, "amount")) or 0)
            end
            return n
        end
        local cols = {}
        local col = r.colony_of(sc.kind, sc.id)
        if col then cols = { col }
        elseif sc.kind == "country" then
            for _, c in ipairs(require("engine.world").list(r.country_field(sc.id, "owned_planets"))) do cols[#cols + 1] = tonumber(c) end
        elseif sc.kind == "system" then
            for _, pid in ipairs(E.system_planets and E.system_planets(sc.id) or {}) do
                local c = r.colony_of("planet", pid)
                if c then cols[#cols + 1] = c end
            end
        else
            return false
        end
        local n = 0
        for _, c in ipairs(cols) do if c and r.obj("colony", c) then n = n + count(c) end end
        return compare(n, val.op, eval.value(val.value, ctx, val))
    end
    -- has_active_building = <building> (CHasActiveBuildingTrigger 0x196d160): one of the colony's
    -- (owner's) buildings of the type that is neither ruined nor disabled
    TRIG["has_active_building"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local col = r.colony_of(sc.kind, sc.id)
        if not col then return false end
        for _, b in ipairs(r.colony_buildings(col)) do
            if r.building_field(b, "type") == v and r.building_field(b, "ruined") ~= "yes"
                and r.building_field(b, "disabled") ~= "yes" then return true end
        end
        return false
    end

    -- pop groups, pop jobs, species
    local function group_species(sc)
        return E.species_of and E.species_of(sc.kind, sc.id)
    end
    -- is_pop_category = <category> (CIsPopCategory 0x1977e60, a pop group): `key = { category }`
    equals_field("is_pop_category", { "pop_group" }, function(sc, r)
        local k = r.obj("pop_group", sc.id) and wfield(r.obj("pop_group", sc.id), "key")
        return type(k) == "table" and wfield(k, "category") or nil
    end)
    -- pop_group_size <op> n (CPopGroupSizeTrigger 0x19b3340): `size`; another scope reads 0
    TRIG["pop_group_size"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local g = sc.kind == "pop_group" and r.obj("pop_group", sc.id)
        return compare_num(g and tonumber(wfield(g, "size")) or 0, e, ctx)
    end
    TVAL["pop_group_size"] = function(ctx)
        local r, sc = rt(), ctx.this
        local g = r and sc.kind == "pop_group" and r.obj("pop_group", sc.id)
        return g and tonumber(wfield(g, "size")) or 0
    end
    -- pop_group_has_trait = <trait> (CPopGroupHasTrait 0x196b790): the group's species' traits
    TRIG["pop_group_has_trait"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "pop_group" then return false end
        sync()
        local sid = group_species(sc)
        for _, t in ipairs(sid and r.species_traits(sid) or {}) do
            if t == v then return true end
        end
        return false
    end
    -- is_robot_pop_group = yes/no (CIsRobotPopGroup 0x1994b30): the species class's archetype is
    -- robotic
    yes_no_trigger("is_robot_pop_group", { "pop_group" }, function(sc, r)
        local sid = group_species(sc)
        local class = sid and E.species_field and E.species_field(sid, "class")
        local cd = type(class) == "string" and r.defs().get("common/species_classes", class)
        local arch = cd and r.defs().field(cd.block, "archetype") or "BIOLOGICAL"
        local ad = r.defs().get("common/species_archetypes", arch)
        return ad ~= nil and r.defs().field(ad.block, "robotic") == "yes"
    end)
    -- is_unemployed = yes/no (CIsUnemployed 0x1978380): the pop group's category (a pop job's job's
    -- category) has is_unemployment_job
    TRIG["is_unemployed"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local cat
        if sc.kind == "pop_group" then
            local k = r.obj("pop_group", sc.id) and wfield(r.obj("pop_group", sc.id), "key")
            cat = type(k) == "table" and wfield(k, "category")
        elseif sc.kind == "pop_job" then
            local jt = wfield(r.obj("pop_job", sc.id), "type")
            local jd = jt and r.defs().get("common/pop_jobs", jt)
            cat = jd and r.defs().field(jd.block, "category")
        else
            return not yes(e)
        end
        local cd = type(cat) == "string" and r.defs().get("common/pop_categories", cat)
        return (cd ~= nil and r.defs().field(cd.block, "is_unemployment_job") == "yes") == yes(e)
    end
    -- has_job_type = <job> (CHasJobType 0x1a1ecf0, a pop job): its `type`
    equals_field("has_job_type", { "pop_job" }, function(sc, r) return wfield(r.obj("pop_job", sc.id), "type") end)
    -- is_exact_same_species = <target> (CIsSameSpeciesBase 0x194d510): the same species object
    TRIG["is_exact_same_species"] = function(e, ctx)
        if not E.species_of or ctx.this == NONE then return false end
        local t = target(e, ctx)
        if not t then return false end
        sync()
        local a, b = E.species_of(ctx.this.kind, ctx.this.id), E.species_of(t.kind, t.id)
        return a ~= nil and a == b
    end
    -- ideal_planet_class = <class | planet> (CIdealPlanetClass 0x195f6c0): the ideal class of the
    -- species (a country's founder species, a pop group's) is it (a planet target: its class)
    TRIG["ideal_planet_class"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        if sc.kind ~= "country" and sc.kind ~= "pop_group" and sc.kind ~= "species" then return false end
        sync()
        local sid = E.species_of and E.species_of(sc.kind, sc.id)
        local ideal = sid and r.ideal_planet_class(sid)
        if not ideal then return false end
        local want = v
        if not r.defs().get("common/planet_classes", v) then
            local t = target(e, ctx)
            if not t or t.kind ~= "planet" then return false end
            want = r.planet_field(t.id, "planet_class")
        end
        return ideal == want
    end
    -- is_ideal_planet_class = { who = <species holder> status = yes/no } (0x1968600, a planet): the
    -- planet's class is the species' ideal class
    TRIG["is_ideal_planet_class"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text then return false end
        local p = params(e)
        if not p.who or not p.who.value.text then return false end
        local f, w = eval.resolve(p.who.value.text, ctx, p.who)
        if not f or not w or w == NONE then return false end
        local status = not p.status or p.status.value.text ~= "no"
        sync()
        local pl = carrier_planet(sc, r)
        if not pl then return false end
        local sid = E.species_of and E.species_of(w.kind, w.id)
        local ideal = sid and r.ideal_planet_class(sid)
        if not sid then return false end
        return (ideal ~= nil and ideal == r.planet_field(pl, "planet_class")) == status
    end
    -- is_scope_type = <scope type> (CIsScopeTypeTrigger 0x19b2630): the scope's EScopeType name
    local SCOPE_NAME = { system = "galactic_object", none = "no_scope", pop_faction = "pop_faction" }
    TRIG["is_scope_type"] = function(e, ctx)
        local sc = ctx.this
        local v = e.value.text
        if not v then return false end
        local name = (sc == NONE or sc == nil) and "no_scope" or (SCOPE_NAME[sc.kind] or sc.kind)
        return name == v
    end
    -- army_type = <type> (CArmyTypeTrigger 0x1972320, an army): its `type`
    equals_field("army_type", { "army" }, function(sc, r) return wfield(r.obj("army", sc.id), "type") end)
    -- is_ambient_object_type = <type> (0x19515a0, an ambient object): its `data`
    require("engine.world").KINDS.ambient_object = require("engine.world").KINDS.ambient_object or "ambient_object"
    equals_field("is_ambient_object_type", { "ambient_object" }, function(sc, r) return wfield(r.obj("ambient_object", sc.id), "data") end)
    -- is_storm_type = <type> (CIsStormType 0x19bbc40, a cosmic storm): its `type`
    equals_field("is_storm_type", { "cosmic_storm" }, function(sc, r) return r.storm_type(sc.id) end)

    -- fleets and ships, more
    -- num_ships <op> n (CNumShipsTrigger 0x1986be0): the alive ships of a country's fleets, a
    -- fleet's, a ship's fleet's
    numeric("num_ships", { "country", "fleet", "ship" }, function(sc, r)
        if sc.kind == "country" then return #r.alive_ships(r.owned_fleets(sc.id)) end
        local fid = sc.kind == "fleet" and sc.id or r.ship_fleet(sc.id)
        return fid and #r.alive_ships({ fid }) or 0
    end)
    -- num_fleets <op> n (CNumFleetsTrigger 0x1986a10): the country's fleets (stations included)
    numeric("num_fleets", { "country" }, function(sc, r) return #r.owned_fleet_entries(sc.id) end)
    -- fleet_size <op> x (CFleetSizeTrigger 0x196c210): the ship sizes' size_multiplier, summed
    numeric("fleet_size", { "fleet" }, function(sc, r)
        local n = 0
        for _, s in ipairs(r.fleet_ships(sc.id)) do
            if r.obj("ship", s) then n = n + (tonumber(r.ship_size_field(r.ship_size_of(s), "size_multiplier")) or 1) end
        end
        return n
    end)
    -- is_mobile / is_civilian = yes/no (CIsMobileTrigger 0x19bd0a0, CIsCivilianTrigger 0x1a1fc20): a
    -- fleet's `properties`; a ship's ship size's is_civilian
    yes_no_trigger("is_mobile", { "fleet" }, function(sc, r) return r.fleet_property(sc.id, "mobile") end)
    yes_no_trigger("is_civilian", { "fleet", "ship" }, function(sc, r)
        if sc.kind == "fleet" then return r.fleet_property(sc.id, "civilian") end
        return r.ship_size_flag(r.ship_size_of(sc.id), "is_civilian")
    end)
    -- is_disabled = yes/no (CIsDisabledTrigger 0x197a980, a fleet): its disabled ships are all its
    -- ships not killed (`cached_disabled_ships`, `cached_killed_ships`); a ship's flag is not read
    yes_no_trigger("is_disabled", { "fleet" }, function(sc, r)
        local n = #r.fleet_ships(sc.id)
        if n == 0 then return false end
        local dis = tonumber(r.fleet_field(sc.id, "cached_disabled_ships")) or 0
        local killed = tonumber(r.fleet_field(sc.id, "cached_killed_ships")) or 0
        return dis > 0 and dis >= n - killed
    end)
    -- has_hp_percentage <op> x (CHasHitPointsPercentageTrigger 0x1967400): a ship's hitpoints over
    -- max_hitpoints; a fleet's summed
    numeric("has_hp_percentage", { "ship", "fleet" }, function(sc, r)
        local ships = sc.kind == "ship" and { sc.id } or r.fleet_ships(sc.id)
        local hp, max = 0, 0
        for _, s in ipairs(ships) do
            hp = hp + (tonumber(r.ship_field(s, "hitpoints")) or 0)
            max = max + (tonumber(r.ship_field(s, "max_hitpoints")) or 0)
        end
        if max <= 0 then return 0 end
        return hp / max
    end)
    -- has_component = <component> (CHasComponentTrigger 0x19ab850, a ship): a component (or a
    -- required component) of its design's current growth stage
    TRIG["has_component"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc.kind ~= "ship" then return false end
        sync()
        local impl = r.ship_field(sc.id, "ship_design_implementation")
        if type(impl) ~= "table" then return false end
        local g = r.design_stage(tonumber(wfield(impl, "design")), wfield(impl, "growth_stage"))
        if not g then return false end
        local w = require("engine.world")
        for _, sec in ipairs(w.fields(g, "section")) do
            for _, comp in ipairs(type(sec) == "table" and w.fields(sec, "component") or {}) do
                if type(comp) == "table" and wfield(comp, "template") == v then return true end
            end
        end
        for _, k in ipairs(w.fields(g, "required_component")) do
            if k == v then return true end
        end
        return false
    end

    -- distance = { source = <scope> min_distance / max_distance <op> x type = euclidean
    -- same_solar_system = yes } (CDistanceTrigger 0x1964df0): the euclidean distance between the
    -- two systems (both in one system: false unless same_solar_system); the hyperlane distance and
    -- jumps (the galaxy's distance cache) are not modelled: a miss
    TRIG["distance"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text or sc == NONE then return false end
        local p = params(e)
        if not p.source or not p.source.value.text then return false end
        local f, src = eval.resolve(p.source.value.text, ctx, p.source)
        if not f or not src or src == NONE then return false end
        local euclid = p.type and p.type.value.text == "euclidean"
        local same = p.same_solar_system and p.same_solar_system.value.text == "yes"
        if not euclid and not same then
            miss("trigger", "distance (hyperlane)", ctx, e)
            return false
        end
        sync()
        local a, b = r.system_of(sc.kind, sc.id), r.system_of(src.kind, src.id)
        if not a or not b then return false end
        if same then
            miss("trigger", "distance (same_solar_system)", ctx, e)
            return false
        end
        if a == b then return false end
        local function xy(sid)
            local c = r.system_field(sid, "coordinate")
            return tonumber(wfield(c, "x")) or 0, tonumber(wfield(c, "y")) or 0
        end
        local ax, ay = xy(a)
        local bx, by = xy(b)
        local d = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
        local function bound(x, ops)
            if not x then return true end
            local lim = eval.value(x.value, ctx, x)
            if lim == 0 then return true end
            if not ops[x.op] then return nil end
            return compare(d, x.op, lim)
        end
        local lo = bound(p.min_distance, { [">"] = true, [">="] = true })
        local hi = bound(p.max_distance, { ["<"] = true, ["<="] = true })
        return lo == true and hi == true
    end

    -- lists: a planet's moons, a carrier's deposits, every species
    LISTS["moon"] = function(sc)
        local r = rt()
        if not r then return {} end
        sync()
        local p = carrier_planet(sc, r)
        local out = {}
        for _, v in ipairs(require("engine.world").list(p and r.planet_field(p, "moons"))) do
            local id = tonumber(v)
            if id and r.obj("planet", id) then out[#out + 1] = S("planet", id) end
        end
        return out
    end
    LISTS["deposit"] = function(sc)
        local r = rt()
        if not r then return {} end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        return kind and scopes("deposit", r.carrier_deposits(kind, id)) or {}
    end
    LISTS["galaxy_species"] = function()
        local r = rt()
        if not r then return {} end
        sync()
        return scopes("species", r.all("species"))
    end

    -- (the contact_country link is engine/first_contact.lua's: a first contact's `country`, as the
    -- game's CFirstContact::GetContactCountry)

    -- has_trait = <trait> (CHasTrait 0x194b8c0; GetTraitsFromScope 0x194b920): a leader's `traits`;
    -- a species' own, a pop group's species', a country's founder species' traits; any other scope
    -- (a planet) fails the scope check
    TRIG["has_trait"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local list
        if sc.kind == "leader" then
            list = r.leader_traits(sc.id)
        elseif sc.kind == "species" or sc.kind == "pop_group" or sc.kind == "country" then
            local sid = E.species_of and E.species_of(sc.kind, sc.id)
            list = sid and r.species_traits(sid) or {}
        else
            return false
        end
        for _, t in ipairs(list) do
            if t == v then return true end
        end
        return false
    end

    -- check_variable_arithmetic = { which = <value> <op> = x ... value <op> y }
    -- (CCheckVariableArithmeticTrigger 0x1969910): `which`, then the arithmetic in order (add,
    -- subtract, multiply, divide, modulo, min, max; a division by 0 fails), compared with `value`
    local ARITH = { add = true, subtract = true, multiply = true, divide = true, modulo = true, min = true, max = true }
    TRIG["check_variable_arithmetic"] = function(e, ctx)
        if e.value.text then return false end
        local acc, cmp
        for _, x in ipairs(e.value) do
            if x.op and x.key then
                local k = x.key.text:lower()
                if k == "which" then
                    acc = eval.value(x.value, ctx, x)
                elseif ARITH[k] and acc then
                    local v = eval.value(x.value, ctx, x)
                    if k == "add" then acc = acc + v
                    elseif k == "subtract" then acc = acc - v
                    elseif k == "multiply" then acc = acc * v
                    elseif k == "divide" then if v == 0 then return false end acc = acc / v
                    elseif k == "modulo" then if v == 0 then return false end acc = acc % v
                    elseif k == "min" then acc = math.max(acc, v)
                    elseif k == "max" then acc = math.min(acc, v) end
                elseif k == "value" then
                    cmp = x
                end
            end
        end
        if not acc or not cmp then return false end
        return compare(acc, cmp.op, eval.value(cmp.value, ctx, cmp))
    end

    -- switch = { trigger = <trigger> <case> = { ... } default = { ... } } as a trigger
    -- (CSwitchTriggerBase<0>::ActualEvaluate 0x19f18b0): the first case for which `<trigger> =
    -- <case>` holds selects its body, else the default; that body is evaluated (no default: true)
    TRIG["switch"] = function(e, ctx)
        if e.value.text then return false end
        local tkey, default
        local cases = {}
        for _, x in ipairs(e.value) do
            if x.op and x.key then
                local k = x.key.text:lower()
                if k == "trigger" then tkey = x.value.text
                elseif k == "default" then default = x.value
                elseif x.value.text == nil then cases[#cases + 1] = x end
            end
        end
        if not tkey then return false end
        for _, c in ipairs(cases) do
            local stmt = { key = { text = tkey }, op = "=", value = { text = c.key.text }, line = c.line }
            if eval.trigger1(stmt, ctx) then return eval.trigger(c.value, ctx) end
        end
        if default then return eval.trigger(default, ctx) end
        return true
    end

    -- is_site_completed = yes/no (CIsArchaeologicalSiteFinishedTrigger 0x1a10c00, an archaeological
    -- site): its stage index (`index`) reached its type's number of stages (`stage` blocks of
    -- common/archaeological_site_types)
    yes_no_trigger("is_site_completed", { "archaeological_site" }, function(sc, r)
        local s = r.obj("archaeological_site", sc.id)
        local t = s and wfield(s, "type")
        local d = t and r.defs().get("common/archaeological_site_types", t)
        if not d then return false end
        local n = 0
        for _, x in ipairs(d.block) do
            if x.op and x.key and x.key.text == "stage" and x.value.text == nil then n = n + 1 end
        end
        return (tonumber(wfield(s, "index")) or 0) >= n
    end)

    -- num_buildings = { type = <building | any> category = c value <op> n owner_type = x
    -- in_construction = yes/no/any disabled = yes/no/any limit = { } } (CNumBuildingsTrigger
    -- 0x196dbf0): the buildings of the type in the colony (its owner's: buildings_cache; disabled
    -- ones as asked; in construction: the queued planet buildings of the type), with `any` the
    -- buildings of its districts' zones (of the category); a country: over its colonies (limit in
    -- each); a system: over its colonies. owner_type other than normal (holdings, branch offices)
    -- and queued buildings of other owners are not counted [I]
    TRIG["num_buildings"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text then return false end
        local p = params(e)
        local btype = p.type and p.type.value.text or "any"
        local val = p.value
        if not val then return false end
        local in_con = p.in_construction and p.in_construction.value.text or "no"
        local disabled = p.disabled and p.disabled.value.text or "any"
        local category = p.category and p.category.value.text
        if category == "any" then category = nil end
        local owner_type = p.owner_type and p.owner_type.value.text or "normal"
        local limit = p.limit and p.limit.value.text == nil and p.limit.value or nil
        sync()
        if btype ~= "any" and category then
            local bd = r.defs().get("common/buildings", btype)
            if not bd or r.defs().field(bd.block, "category") ~= category then
                return compare(0, val.op, eval.value(val.value, ctx, val))
            end
        end
        local function count(col, lctx)
            if limit and not eval.trigger(limit, lctx) then return 0 end
            if owner_type ~= "normal" then return 0 end
            local n = 0
            if btype == "any" then
                for _, b in ipairs(r.colony_zone_buildings(col)) do
                    local bt = r.building_field(b, "type")
                    local bd = category and bt and r.defs().get("common/buildings", bt)
                    if not category or (bd and r.defs().field(bd.block, "category") == category) then n = n + 1 end
                end
                return n
            end
            if in_con ~= "yes" then
                for _, b in ipairs(r.colony_buildings(col)) do
                    if r.building_field(b, "type") == btype then
                        local dis = r.building_field(b, "disabled") == "yes"
                        if disabled == "any" or dis == (disabled == "yes") then n = n + 1 end
                    end
                end
            end
            if in_con ~= "no" then
                local pid = select(2, r.carrier_of("colony", col))
                for _, it in pairs(r.construction_items()) do
                    local qb = wfield(it, "buildable_planet_building")
                    if type(qb) == "table" and wfield(qb, "building") == btype and tonumber(wfield(qb, "planet")) == pid then
                        n = n + 1
                    end
                end
            end
            return n
        end
        local n = 0
        local col = r.colony_of(sc.kind, sc.id)
        if col then
            n = count(col, ctx)
        elseif sc.kind == "country" or sc.kind == "system" then
            local cols = {}
            if sc.kind == "country" then
                for _, c in ipairs(require("engine.world").list(r.country_field(sc.id, "owned_planets"))) do cols[#cols + 1] = tonumber(c) end
            else
                for _, pid in ipairs(E.system_planets and E.system_planets(sc.id) or {}) do
                    local c = r.colony_of("planet", pid)
                    if c then cols[#cols + 1] = c end
                end
            end
            for _, c in ipairs(cols) do
                if c and r.obj("colony", c) then
                    local kind, pid = r.carrier_of("colony", c)
                    n = n + count(c, I.push(ctx, kind and S(kind, pid) or NONE))
                end
            end
        else
            return false
        end
        return compare(n, val.op, eval.value(val.value, ctx, val))
    end

    -- links: sector_capital (a sector's local capital: its colony, given as its planet, the
    -- simulation's scope for a colony [I]); ship (a starbase's station; a colony's or planet's
    -- carrier when it is a ship)
    LINKS["sector_capital"] = function(cur)
        local r = rt()
        if not r or cur.kind ~= "sector" then return nil end
        sync()
        local s = r.obj("sector", cur.id)
        local col = s and r.ref(wfield(s, "local_capital"))
        local kind, id = col and r.carrier_of("colony", col)
        return kind and S(kind, id) or nil
    end
    LINKS["ship"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        if cur.kind == "ship" then return cur end
        sync()
        if cur.kind == "starbase" then
            local st = r.ref(r.starbase_field(cur.id, "station"))
            return (st and r.obj("ship", st)) and S("ship", st) or nil
        end
        if cur.kind == "colony" then
            local kind, id = r.carrier_of("colony", cur.id)
            return kind == "ship" and S("ship", id) or nil
        end
        return nil
    end

    -- num_modifiers <op> n (CNumModifiersTrigger 0x1962520, a planet or colony): the planet's timed
    -- modifiers (`timed_modifier = { items = { } }`; its static planet_modifier entries are not
    -- counted); a ship: false
    numeric("num_modifiers", { "planet", "colony" }, function(sc, r)
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if kind ~= "planet" then return nil end
        local tm = r.planet_field(id, "timed_modifier")
        local items = type(tm) == "table" and wfield(tm, "items")
        return #require("engine.world").blocks(type(items) == "table" and items or nil)
    end)
    -- count_deposits = { type = <deposit> category = <category> count <op> n } (CCountDepositsTrigger
    -- 0x1993950, a planet, ship or colony): the carrier's deposits matching the filters given
    TRIG["count_deposits"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text then return false end
        local p = params(e)
        local dtype = p.type and p.type.value.text
        local cat = p.category and p.category.value.text
        local cnt = p.count
        if not cnt then return false end
        if dtype and not r.defs().get("common/deposits", dtype) then return false end
        if cat and not r.defs().get("common/deposit_categories", cat) then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return false end
        local n = 0
        for _, d in ipairs(r.carrier_deposits(kind, id)) do
            local t = r.deposit_type(d)
            if (not dtype or t == dtype) and (not cat or r.deposit_type_field(t, "category") == cat) then n = n + 1 end
        end
        return compare(n, cnt.op, eval.value(cnt.value, ctx, cnt))
    end

    -- star (token 10778): the star of a system, or of the system a planet, ship, fleet, starbase,
    -- megastructure or ambient object is in (GetStarPlanetObject: its first planet of a star class)
    LINKS["star"] = function(cur)
        local r = rt()
        if not r or cur == NONE then return nil end
        local k = cur.kind
        if k ~= "system" and k ~= "planet" and k ~= "ship" and k ~= "fleet" and k ~= "starbase"
            and k ~= "megastructure" and k ~= "ambient_object" then return nil end
        sync()
        local sid = r.system_of(k, cur.id)
        local p = sid and r.star_planet(sid)
        return p and S("planet", p) or nil
    end
    -- is_homeworld = yes/no (CIsHomeworld 0x1957e00, a planet, ship or colony): the carrier is the
    -- home (`home_planet = { type reference }`, CSpecies +0x28) of its owner's founder species; no
    -- carrier: `= no` holds
    TRIG["is_homeworld"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return not yes(e) end
        local owner = kind == "planet" and r.planet_owner(id) or r.fleet_owner(r.ship_fleet(id))
        local sp = owner and r.ref(r.country_field(owner, "founder_species_ref"))
        local so = sp and r.obj("species", sp)
        local home = so and wfield(so, "home_planet")
        local is = type(home) == "table" and wfield(home, "type") == kind and tonumber(wfield(home, "reference")) == id
        return (is and true or false) == yes(e)
    end
    -- system_planet_colony (a system): its planets that are colonies (CGalacticObject
    -- _PlanetColonies +0x4a8, a cache the save does not hold whole: rebuilt from the planets with a
    -- colony, in the system's planet order [I: the cache's order])
    LISTS["system_planet_colony"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        local out = {}
        for _, pid in ipairs(E.system_planets and E.system_planets(sc.id) or {}) do
            if r.colony_of("planet", pid) then out[#out + 1] = S("planet", pid) end
        end
        return out
    end

    -- lists: envoy (COwnedEnvoyListBuilder 0x18144d0: a country's leaders whose class has
    -- can_be_envoy), system_ambient_object (a system's `ambient_object`)
    LISTS["envoy"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "country" then return {} end
        sync()
        local out = {}
        for _, l in ipairs(E.leaders and E.leaders(sc.id) or {}) do
            local class = r.leader_field(l, "class")
            local d = class and r.defs().get("common/leader_classes", class)
            if d and r.defs().field(d.block, "can_be_envoy") == "yes" then out[#out + 1] = S("leader", l) end
        end
        return out
    end
    LISTS["system_ambient_object"] = function(sc)
        local r = rt()
        if not r or sc.kind ~= "system" then return {} end
        sync()
        local out = {}
        for _, a in ipairs(r.system_list(sc.id, "ambient_object")) do
            if r.obj("ambient_object", a) then out[#out + 1] = S("ambient_object", a) end
        end
        return out
    end

    -- has_envoy_task = { task = <assignment> target = <country> } (CHasEnvoyTaskTrigger 0x1989020, a
    -- leader): its location's assignment (CLeaderLocation +0x4, `location = { assignment }`) is the
    -- task; with a target, the location's country (`id`) is it [I: the target branch read in part]
    TRIG["has_envoy_task"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "leader" or e.value.text then return false end
        local p = params(e)
        local task = p.task and p.task.value.text
        if not task then return false end
        sync()
        local loc = r.leader_field(sc.id, "location")
        if type(loc) ~= "table" or wfield(loc, "assignment") ~= task then return false end
        if p.target and p.target.value.text then
            local f, t = eval.resolve(p.target.value.text, ctx, p.target)
            if not f or not t or t.kind ~= "country" then return false end
            return tonumber(wfield(loc, "id")) == t.id
        end
        return true
    end

    -- the AI's strategic data (CAIStrategicBase::GetStrategy 0x1af290 on CCountry +0x1b28): the
    -- country's `ai = { strategy }` lists as engine.ai.strategy builds them monthly. A list it does
    -- not build yet is the save's, stale after the first month: its trigger is left unanswered
    -- (a miss) until the list is ported (strategy.PORTED)
    local function strategy_ported(t)
        local ok, strategy = pcall(require, "engine.ai.strategy")
        -- list 1 (COLONIZE) is answered as the world holds it (the save's, kept by engine.ai.strategy
        -- until CreateColonizeData's AddColonyData is ported): the AI budget's colonies entries read
        -- it (ai_colonize_plans; docs/ai_fleets.md section 3); STELLAR_AI_LIST1=off leaves it a miss
        if t == 1 and os.getenv("STELLAR_AI_LIST1") ~= "off" then return true end
        return ok and type(strategy) == "table" and strategy.PORTED and strategy.PORTED[t] == true
    end
    -- ai_colonize_plans <op> n (CAIColonizePlans 0x19af8b0): the COLONIZE (1) entries
    numeric("ai_colonize_plans", { "country" }, function(sc, r) return r.ai_strategy_count(sc.id, 1) end)
    local ai_colonize_plans = TRIG["ai_colonize_plans"]
    TRIG["ai_colonize_plans"] = function(e, ctx, lk)
        if not strategy_ported(1) then
            miss("trigger", "ai_colonize_plans", ctx, e)
            return false
        end
        return ai_colonize_plans(e, ctx, lk)
    end
    local ai_colonize_value = TVAL["ai_colonize_plans"]
    TVAL["ai_colonize_plans"] = function(ctx, e)
        if not strategy_ported(1) then return nil end
        return ai_colonize_value(ctx, e)
    end
    -- has_ai_expansion_plan = yes/no (CAIHasExpansionPlans 0x19aff20): an EXPAND_BORDERS (19) entry
    TRIG["has_ai_expansion_plan"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or sc.kind ~= "country" then return false end
        if not strategy_ported(19) then
            miss("trigger", "has_ai_expansion_plan", ctx, e)
            return false
        end
        sync()
        return (r.ai_strategy_count(sc.id, 19) > 0) == yes(e)
    end

    -- districts: CColonyCarrier::CalcMaxDistricts (0xccc980) as engine.ai.economy.slots ports it
    -- (planet size, the defines, the country's and colony's max-district modifiers)
    local function district_info(sc, r)
        local col = r.colony_of(sc.kind, sc.id)
        local kind, pid = col and r.carrier_of("colony", col)
        if kind ~= "planet" then return nil end
        local ok, slots = pcall(require, "engine.ai.economy.slots")
        if not ok then return nil end
        return slots.colony({ colony = col, planet = pid, owner = r.planet_owner(pid) }), slots
    end
    -- free_district_slots <op> n (CFreeDistrictSlotsTrigger 0x197cc10): the max districts minus the
    -- levels of the colony's districts (not the queued ones); no colony: 0
    numeric("free_district_slots", { "planet", "ship", "colony" }, function(sc, r)
        local info, slots = district_info(sc, r)
        if not info then return 0 end
        local built = 0
        for _, d in ipairs(info.list) do built = built + d.level end
        return slots.max_districts(info) - built
    end)
    -- num_free_districts = { type = <district | any> value <op> n } (CNumFreeDistrictsTrigger
    -- 0x196f590): free = the max districts minus the levels with the queued ones; any: free; a
    -- capped type: min(free, its cap minus its levels and queued); an uncapped type already there:
    -- free; one not there yet: free when its potential and allow hold, else 0; no colony: false
    TRIG["num_free_districts"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r or e.value.text then return false end
        local p = params(e)
        local dtype, val = p.type and p.type.value.text or "any", p.value
        if not val then return false end
        sync()
        local info, slots = district_info(sc, r)
        if not info then return false end
        local free = slots.max_districts(info) - info.levels
        local n = free
        if dtype ~= "any" then
            local d = r.defs().get("common/districts", dtype)
            if not d then return false end
            local have = (info.districts[dtype] and info.districts[dtype].level or 0) + (info.queued[dtype] or 0)
            local cap = slots.district_cap(info, d, dtype)
            if cap then
                n = math.min(free, cap - have)
            elseif have == 0 then
                local dctx = slots.ctx(info, d.file)
                local x = slots.expanded(d)
                if not (slots.holds(r.defs().field(x, "potential"), dctx) and slots.holds(r.defs().field(x, "allow"), dctx)) then
                    n = 0
                end
            end
        end
        return compare(n, val.op, eval.value(val.value, ctx, val))
    end

    -- has_strategic_resource = yes / no / <resource> (CHasStrategicResourceTrigger 0x1954570, a
    -- planet or ship carrier): yes/no, a deposit of the carrier has resources (no carrier: `= no`
    -- holds); a resource, a deposit produces it. The deposits' resource tables are read as written,
    -- their produce triggers not evaluated [I] (as has_deposit = yes/no)
    TRIG["has_strategic_resource"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v then return false end
        sync()
        local kind, id = r.carrier_of(sc.kind, sc.id)
        if not kind then return v == "no" end
        for _, d in ipairs(r.carrier_deposits(kind, id)) do
            local t = r.deposit_type(d)
            if v == "yes" or v == "no" then
                if r.deposit_has_resources(t) then return v == "yes" end
            elseif r.deposit_produces(t, v) then
                return true
            end
        end
        return v == "no"
    end

    -- round_to = n in a value block (EScriptMaths RoundTo, CFixedPoint::RoundTo): the nearest
    -- multiple of n [I: RoundTo not read]
    eval.VALUE_OP["round_to"] = function(acc, n)
        if n == 0 then return acc end
        return math.floor(acc / n + 0.5) * n
    end

    -- `pow`: the game's NFixedInt64Internal::ipow (0x1b43a50): 0 to the power 0 is 1, else 0; a
    -- negative base takes the sign of the exponent's fixed point raw value's parity (an even raw
    -- value, as 3.0's 300000, gives a positive result)
    eval.pow = function(b, x)
        if b == 0 then return x == 0 and 1 or 0 end
        if b > 0 then return b ^ x end
        local v = (-b) ^ x
        local raw = math.floor(x * 100000 + 0.5)
        if raw % 2 == 1 then return -v end
        return v
    end

    -- `trigger:<name>` of eval.lua's own comparison triggers (CIntTrigger / CValueTrigger), with
    -- no arguments (CVariableValue::ReadTriggerModifierOrScriptValue 0x34c550)
    TVAL["years_passed"] = function() return math.floor(eval.today() / 360) - 2200 end
    TVAL["mid_game_years_passed"] = function() return math.floor(eval.today() / 360) - 2300 end
    TVAL["end_game_years_passed"] = function() return math.floor(eval.today() / 360) - 2400 end
    TVAL["days_passed"] = function() return eval.today() - 2200 * 360 end
    TVAL["has_base_skill"] = function(ctx)
        if ctx.this.kind ~= "leader" then return 0 end
        sync()
        return tonumber(E.get("leader", ctx.this.id, "has_base_skill")) or 0
    end
    TVAL["fleet_power"] = function(ctx)
        if not E.fleet_power or ctx.this == NONE then return 0 end
        sync()
        return E.fleet_power(ctx.this.kind, ctx.this.id) or 0
    end
    for _, k in ipairs({ "num_owned_planets", "num_colonies" }) do
        TVAL[k] = function(ctx)
            if ctx.this.kind ~= "country" then return 0 end
            sync()
            return tonumber(E.get("country", ctx.this.id, "num_colonies")) or 0
        end
    end
    -- a scripted trigger whose body is one count iterator (pop_amount): the count, as eval
    -- compares it [I]
    setmetatable(TVAL, { __index = function(t, name)
        local db = I.db
        local def = db and db.scripted_triggers[name]
        if not def then return nil end
        local f
        f = function(ctx, e)
            local body = I.scripted_call(def, name, { value = { text = "yes" } }, "trigger")
            local only
            for _, x in ipairs(body or {}) do
                if x.op then
                    if only then return nil end
                    only = x
                end
            end
            return only and eval.count_value(only.key.text:lower(), only.value, I.with_file(ctx, def.file)) or nil
        end
        rawset(t, name, f)
        return f
    end })

    -- STELLAR_RUNTIME_OFF=<name,name,...> (or `all`): those keywords (triggers, links, lists,
    -- trigger values) as they were before this module, to measure what each changes
    local off = os.getenv("STELLAR_RUNTIME_OFF")
    if off and off ~= "" then
        local names = {}
        for n in off:gmatch("[^,%s]+") do names[n:lower()] = true end
        for name, t in pairs({ TRIG = TRIG, LINKS = LINKS, LISTS = LISTS, TVAL = eval.TVAL }) do
            local keys = {}
            for k, v in pairs(t) do
                if v ~= before[name][k] and (names.all or names[k]) then keys[#keys + 1] = k end
            end
            for _, k in ipairs(keys) do t[k] = before[name][k] end
        end
    end
end
