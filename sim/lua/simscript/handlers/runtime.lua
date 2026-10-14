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
    -- country): (starbase_capacity_used + the outposts being upgraded) / starbase_capacity; false at
    -- capacity 0. The save's numbers (CCountry +0x33e8, +0x33f0) are recomputed by the game daily;
    -- the simulation reads them as saved
    numeric("used_starbase_capacity_percent", { "country" }, function(sc, r)
        local c = r.obj("country", sc.id)
        local cap = c and tonumber(require("engine.world").field(c, "starbase_capacity")) or 0
        if cap == 0 then return nil end
        local used = tonumber(require("engine.world").field(c, "starbase_capacity_used")) or 0
        return (used + r.upgrading_outposts(sc.id)) / cap
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
    -- possible_country) and the next level's upgrade trigger holds. A ship, fleet or megastructure
    -- needs the design upgrade chain the simulation does not model: not evaluated (a miss).
    TRIG["can_be_upgraded"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        if not r then return false end
        if sc.kind ~= "starbase" then
            if sc.kind == "ship" or sc.kind == "fleet" or sc.kind == "megastructure" then
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
    scoped_property("has_trait", { "country", "pop_group", "leader", "species" })
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
