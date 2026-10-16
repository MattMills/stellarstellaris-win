-- simscript/handlers/objects_colony.lua : a colony's districts, zones, buildings, pop groups and
-- blockers (engine/script/objects_colony.lua applies them). Loaded by handlers/objects.lua.

return function(eval, O)
    local I = eval._internal
    local EFF, TRIG = eval.EFF, eval.TRIG
    local E, sync, NONE = I.E, I.sync, I.NONE
    local params, text_of, target, push = O.params, O.text_of, O.target, O.push
    local unq = require("engine.script.objects").unq
    local world = require("engine.world")

    local function scope(ctx)
        return ctx.this.kind, ctx.this.id
    end

    -- add_district = <key> | { district_type = <key> ignore_cap = yes type_conversion = yes }
    -- (CAddDistrictEffect: +0xe8 the type, +0xf0 ignore_cap, +0xf1 type_conversion)
    EFF["add_district"] = function(e, ctx)
        local key, cap, conv
        if e.value.text then
            key = unq(e.value.text)
        else
            local p = params(e)
            key = text_of(p.district_type) or text_of(p.district)
            cap, conv = O.yes_of(p.ignore_cap, false), O.yes_of(p.type_conversion, false)
        end
        if not key then return end
        local k, id = scope(ctx)
        push({ type = "add_district", kind = k, id = id, district = key, ignore_cap = cap, conversion = conv })
        sync()
    end
    -- remove_district = <key>
    EFF["remove_district"] = function(e, ctx)
        local key = e.value.text and unq(e.value.text)
        if not key then return end
        local k, id = scope(ctx)
        push({ type = "remove_district", kind = k, id = id, district = key })
        sync()
    end
    -- add_zone = { district = <type | slot index> zone = <type> zone_slot = <index> replace = yes }
    EFF["add_zone"] = function(e, ctx)
        local p = params(e)
        local zone = text_of(p.zone)
        if not zone then return end
        local k, id = scope(ctx)
        push({ type = "add_zone", kind = k, id = id, district = text_of(p.district), zone = zone,
            zone_slot = p.zone_slot and O.int_of(p.zone_slot, ctx) or nil, replace = O.yes_of(p.replace, false) })
        sync()
    end
    -- add_building = <key> | { building = <key> zone = <type> district = <type> }
    EFF["add_building"] = function(e, ctx)
        local key, zone, district
        if e.value.text then
            key = unq(e.value.text)
        else
            local p = params(e)
            key, zone, district = text_of(p.building), text_of(p.zone), text_of(p.district)
        end
        if not key then return end
        local k, id = scope(ctx)
        push({ type = "add_building", kind = k, id = id, building = key, zone = zone, district = district })
        sync()
    end
    -- remove_building = <key>
    EFF["remove_building"] = function(e, ctx)
        local key = e.value.text and unq(e.value.text)
        if not key then return end
        local k, id = scope(ctx)
        push({ type = "remove_building", kind = k, id = id, building = key })
        sync()
    end
    -- clear_blockers = yes
    EFF["clear_blockers"] = function(e, ctx)
        if e.value.text ~= "yes" then return end
        local k, id = scope(ctx)
        push({ type = "clear_blockers", kind = k, id = id })
        sync()
    end

    -- change_planet_size = <int>
    EFF["change_planet_size"] = function(e, ctx)
        local k, id = scope(ctx)
        push({ type = "change_planet_size", kind = k, id = id, amount = O.int_of(e, ctx, 0) })
        sync()
    end

    -- free_district_slots <op> n (CFreeDistrictSlotsTrigger::GetTriggerValue 0x3b89c20): a planet's,
    -- a colony's carrier's
    local colony
    TRIG["free_district_slots"] = function(e, ctx)
        colony = colony or require("engine.script.objects_colony")
        if ctx.this == NONE then return false end
        sync()
        local pid = colony.planet_of(ctx.this.kind, ctx.this.id)
        if not pid then return false end
        return I.compare(colony.free_district_slots(pid), e.op, eval.value(e.value, ctx, e))
    end

    -- add_blocker = { type = <deposit> blocked_deposit = random | none | <deposit scope> }
    EFF["add_blocker"] = function(e, ctx)
        local p = params(e)
        local key = text_of(p.type)
        if not key then return end
        local blocked = text_of(p.blocked_deposit)
        if blocked and blocked ~= "random" and blocked ~= "none" then
            local sc = target(p.blocked_deposit, ctx)
            blocked = sc and sc.kind == "deposit" and sc.id or nil
        end
        local k, id = scope(ctx)
        push({ type = "add_blocker", kind = k, id = id, blocker = key, blocked = blocked })
        sync()
    end

    -- export_modifier_to_variable = { modifier = <key> variable = <name> }
    -- (CExportModifierToVariableEffect::ExecuteActual 0x37cda50): the scope's modifier value (0 when
    -- its node has none; the [0,1] clamp of flagged modifiers not ported) into the variable [V]
    EFF["export_modifier_to_variable"] = function(e, ctx)
        local p = params(e)
        local name, var = text_of(p.modifier), text_of(p.variable)
        if not name or not var or ctx.this == NONE then return end
        sync()
        require("engine.script.objects").fresh()
        local v = E.modifier and E.modifier(ctx.this.kind, ctx.this.id, name) or 0
        I.stats.script = I.stats.script + 1
        eval.store.setvar(ctx.this, var, v)
    end

    -- create_pop_group = { species = <target> size = <n> category = <key> ethos = { ethic = <key> }
    -- | random  pop_group = <base> random = <n> effect = { } } (CCreatePopGroupEffect): size
    -- POP_BULK_UNIT_SIZE (100) by default; species from the base group when omitted
    local bulk
    EFF["create_pop_group"] = function(e, ctx)
        local p = params(e)
        local species, base
        if p.pop_group then
            base = target(p.pop_group, ctx)
        end
        if p.species then
            local t = text_of(p.species)
            if t == "last_created" then t = "last_created_species" end
            local found, sc = eval.resolve(t, ctx, p.species)
            if found and sc and sc ~= NONE then
                if sc.kind == "species" then species = sc.id
                elseif E.species_of then sync(); species = E.species_of(sc.kind, sc.id) end
            end
        end
        local category = text_of(p.category)
        if base and base.kind == "pop_group" then
            sync()
            local g = world.object("pop_groups", base.id)
            local key = g and world.field(g, "key")
            if type(key) == "table" then
                species = species or tonumber(world.field(key, "species"))
                category = category or (world.field(key, "category") and unq(world.field(key, "category")))
            end
        end
        if not species then return end
        -- NDefines.NPop.POP_BULK_UNIT_SIZE (common/defines/00_defines.txt)
        bulk = bulk or 100
        -- the size rounded up (a fixed-point value), then the scope random's
        -- GetInteger(max(n - spread, 0), n + spread): one draw, spread or not [V]; the range as
        -- lo + draw % (hi - lo + 1) [I]
        local n = bulk
        if p.size then
            local v = eval.value(p.size.value, ctx, p.size) or bulk
            n = math.ceil(math.floor(v * 100000 + 0.5) / 100000)
        end
        local spread = p.random and O.int_of(p.random, ctx, 0) or 0
        local lo, hi = math.max(n - spread, 0), n + spread
        local size = lo + eval.scope_draw(ctx) % (hi - lo + 1)
        local ethos
        if p.ethos and p.ethos.value.text == nil then
            ethos = {}
            for _, x in ipairs(p.ethos.value) do
                if x.op and x.key.text:lower() == "ethic" and x.value.text then ethos[#ethos + 1] = unq(x.value.text) end
            end
        end
        local h = E.new_handle()
        ctx.created.pop_group = h
        ctx.created.pop = h
        local k, id = scope(ctx)
        push({ type = "create_pop_group", kind = k, id = id, species = species, size = size, category = category,
            ethos = ethos, handle = h })
        sync()
        -- effect = { }: this = the group, in a scope made from one more draw of the scope random
        if p.effect and p.effect.value.text == nil then
            local seed = eval.scope_draw(ctx)
            local gid = E.resolve(h)
            if gid then
                local c2 = I.push(ctx, I.S("pop_group", gid))
                eval.seed_scope(c2, seed)
                eval.effect(p.effect.value, c2)
            end
        end
    end
end
