-- simscript/handlers/objects_fleets.lua : create_fleet, create_ship, set_owner (fleets),
-- set_location (fleets), set_fleet_stance (engine/script/objects_fleets.lua applies them). Loaded
-- by handlers/objects.lua.

return function(eval, O)
    local I = eval._internal
    local EFF = eval.EFF
    local E, sync, NONE, S = I.E, I.sync, I.NONE, I.S
    local params, text_of, target, push = O.params, O.text_of, O.target, O.push
    local unq = require("engine.script.objects").unq
    local world = require("engine.world")

    -- a name as the game reads one into a CPersistentName: a key (localised when it is one)
    local function name_block(text)
        local b = {}
        world.append(b, "key", text, true)
        return b
    end

    -- the effect's own handlers before this module (set_owner and set_location of other scopes go
    -- to them: the galaxy and leaders domains)
    local prev_set_owner = EFF["set_owner"]
    local prev_set_location = EFF["set_location"]

    -- create_fleet = { name = <string> settings = { <flag> = yes/no } set_take_point = yes
    -- parent = <fleet> effect = { } } (CCreateFleet::ExecuteActual 0x36e6070): the fleet made
    -- (CreateNewFleet, SetUpFleet), then, for a non-empty effect, one draw of the scope random makes
    -- the scope it runs in (this = the fleet, prev = the caller) [V]
    EFF["create_fleet"] = function(e, ctx)
        local p = params(e)
        local name
        local nt = text_of(p.name)
        if nt and nt ~= "" then
            local found, sc = eval.resolve(nt, ctx, p.name)
            if not found then name = name_block(nt) end
            -- a scope's name (CEventScope::GetObjectNamePersistent): the scope's own name block
            if found and sc and sc ~= NONE then
                sync()
                local o = world.object(sc.kind, sc.id)
                local nb = o and world.field(o, "name")
                if type(nb) == "table" then name = nb end
            end
        end
        local settings
        if p.settings and p.settings.value.text == nil then
            settings = {}
            for _, x in ipairs(p.settings.value) do
                if x.op and x.key and x.value.text then settings[#settings + 1] = { x.key.text, x.value.text } end
            end
        end
        local h = E.new_handle()
        O.created(ctx, "fleet", h)
        push({ type = "create_fleet", name = name, settings = settings, handle = h })
        sync()
        local fid = E.resolve(h)
        if fid and p.effect and p.effect.value.text == nil and #p.effect.value > 0 then
            local seed = eval.scope_draw(ctx)
            local c2 = I.push(ctx, S("fleet", fid))
            eval.seed_scope(c2, seed)
            eval.effect(p.effect.value, c2)
        end
    end

    -- set_owner = <country> on a fleet (CSetOwnerEffect 0x36e0a80: CFleet::ChangeOwner) [V]
    EFF["set_owner"] = function(e, ctx, lk)
        if ctx.this.kind == "fleet" then
            local sc = target(e, ctx)
            if not sc then return end
            local country = sc.kind == "country" and sc.id
            if not country then
                local f, owner = eval.resolve("owner", I.push(ctx, sc), e)
                country = f and owner and owner.kind == "country" and owner.id
            end
            if not country then return end
            push({ type = "set_fleet_owner", id = ctx.this.id, country = country })
            sync()
            return
        end
        if prev_set_owner then return prev_set_owner(e, ctx, lk) end
        O.unmodelled("set_owner", ctx, e)
    end

    -- create_ship = { name = random | <string> design = <name> random_existing_design = <size>
    -- prefix = yes/no growth_stage = <n> graphical_culture = <target> effect = { } }
    -- (CCreateShipEffect::ExecuteActual 0x36ed2a0) in a fleet scope, or a starbase's (its station's
    -- fleet) [V]
    EFF["create_ship"] = function(e, ctx)
        local sc = ctx.this
        local fid
        if sc.kind == "fleet" then
            fid = sc.id
        elseif sc.kind == "starbase" then
            sync()
            local f, ship = eval.resolve("ship", ctx, e)
            local s = f and ship and world.object("ships", ship.id)
            fid = s and tonumber(world.field(s, "fleet"))
        end
        if not fid then return end
        local p = params(e)
        local t = { type = "create_ship", fleet = fid }
        t.size = text_of(p.random_existing_design)
        local d = text_of(p.design)
        if d == "last_created_design" then
            local found, dsc = eval.resolve("last_created_design", ctx, p.design)
            t.design = found and dsc and dsc.id or nil
        elseif d then
            t.global = d
        end
        local n = text_of(p.name)
        if n == "random" then
            t.name = "random"
        elseif n and n ~= "" then
            local found, nsc = eval.resolve(n, ctx, p.name)
            if not found then
                t.name = name_block(n)
            elseif nsc and nsc ~= NONE then
                sync()
                local o = world.object(nsc.kind, nsc.id)
                local nb = o and world.field(o, "name")
                if type(nb) == "table" then t.name = nb end
            end
        else
            t.unnamed = true
        end
        if p.prefix then t.prefix = O.yes_of(p.prefix, true) end
        if p.growth_stage then t.stage = math.max(0, O.int_of(p.growth_stage, ctx, 1) - 1) end
        local h = E.new_handle()
        t.handle = h
        O.created(ctx, "ship", h)
        push(t)
        sync()
        local sid = E.resolve(h)
        if sid and p.effect and p.effect.value.text == nil and #p.effect.value > 0 then
            local seed = eval.scope_draw(ctx)
            local c2 = I.push(ctx, S("ship", sid))
            eval.seed_scope(c2, seed)
            eval.effect(p.effect.value, c2)
        end
    end

    -- set_fleet_stance = passive | aggressive | evasive
    EFF["set_fleet_stance"] = function(e, ctx)
        if ctx.this.kind ~= "fleet" or not e.value.text then return end
        push({ type = "set_fleet_stance", id = ctx.this.id, stance = unq(e.value.text) })
        sync()
    end

    -- set_location = <target> | { target = <target> distance = <v> angle = <v> | random
    -- direction = in_system | out_system } (CSetLocationEffect) of a fleet
    EFF["set_location"] = function(e, ctx, lk)
        if ctx.this.kind ~= "fleet" then
            if prev_set_location then return prev_set_location(e, ctx, lk) end
            return O.unmodelled("set_location", ctx, e)
        end
        local t = { type = "set_location", id = ctx.this.id }
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
            t.direction = text_of(p.direction)
        end
        if not tgt then return end
        t.target = { kind = tgt.kind, id = tgt.id }
        push(t)
        sync()
    end
end
