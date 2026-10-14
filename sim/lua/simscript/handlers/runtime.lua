-- simscript/handlers/runtime.lua : the keywords the simulation hits at run time that the script
-- layer did not evaluate: cosmic storms, megastructures, starbases, councilors, sectors, and the
-- country, planet, fleet and ship properties the save keeps. Each follows the trigger class's
-- evaluation in the game (GOG 4.5.2; docs/script_runtime.md has the classes, [V] / [I] and what
-- is approximated); the world is read through engine/script/runtime.lua.

return function(eval)
    local I = eval._internal
    local TRIG, LINKS, LISTS = eval.TRIG, eval.LINKS, eval.LISTS
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

    -- is_inside_storm = yes / no / <storm type> (CIsInsideStormTrigger 0x19ba4d0, a system): the
    -- system's `storm` names a storm that exists; with a type, the storm's `type` is it
    TRIG["is_inside_storm"] = function(e, ctx)
        local r, sc = rt(), ctx.this
        local v = e.value.text
        if not r or not v or sc == NONE then return false end
        sync()
        local sid = r.system_of(sc.kind, sc.id)
        local storm = sid and r.storm_of_system(sid)
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
end
