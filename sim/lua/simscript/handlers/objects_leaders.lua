-- simscript/handlers/objects_leaders.lua : create_leader, set_leader, assign_leader, set_policy,
-- add_council_agenda_progress (engine/script/objects_leaders.lua applies them). Loaded by
-- handlers/objects.lua.

return function(eval, O)
    local I = eval._internal
    local EFF = eval.EFF
    local E, sync, NONE, S = I.E, I.sync, I.NONE, I.S
    local params, text_of, target, push = O.params, O.text_of, O.target, O.push
    local unq = require("engine.script.objects").unq
    local world = require("engine.world")

    local function species_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "species" then return sc.id end
        if E.species_of then sync(); return E.species_of(sc.kind, sc.id) end
        return nil
    end

    -- create_leader = { class name species skill set_age gender traits = { N = <trait> }
    -- hide_leader skip_background_generation effect = { } ... } (CCreateLeader::ExecuteActual
    -- 0x37acb00 -> anon::CreateLeader 0x36d32a0): a country's; last_created_leader (CGameState
    -- +0x928) is the leader from then on; a non-empty effect runs in a scope made from one draw of
    -- the scope random [V]
    EFF["create_leader"] = function(e, ctx)
        if ctx.this.kind ~= "country" then return end
        local p = params(e)
        local t = { type = "create_leader", kind = "country", id = ctx.this.id }
        local class = text_of(p.class)
        if class and class ~= "random" and class ~= "random_ruler" then t.class = class end
        local sp = text_of(p.species)
        if sp == "last_created" then sp = "last_created_species" end
        if sp then
            local found, sc = eval.resolve(sp, ctx, p.species)
            if found then t.species = species_of(sc) end
        end
        local n = text_of(p.name)
        if n and n ~= "random" and n ~= "" then
            local b = {}
            world.append(b, "full_names", (function() local k = {}; world.append(k, "key", n, true); return k end)())
            world.append(b, "use_full_regnal_name", "yes")
            t.name = b
        end
        if p.skill then t.skill = O.int_of(p.skill, ctx) end
        if p.set_age then t.age = O.int_of(p.set_age, ctx) end
        t.gender = text_of(p.gender)
        t.hidden = O.yes_of(p.hide_leader, false)
        t.skip_background = O.yes_of(p.skip_background_generation, false)
        if p.traits and p.traits.value.text == nil then
            t.traits = {}
            for _, x in ipairs(p.traits.value) do
                if x.op and x.key and x.value.text then
                    t.traits[#t.traits + 1] = { tonumber(x.key.text) or 0, unq(x.value.text) }
                end
            end
        end
        local h = E.new_handle()
        t.handle = h
        O.created(ctx, "leader", h)
        push(t)
        sync()
        local lid = E.resolve(h)
        if lid and p.effect and p.effect.value.text == nil and #p.effect.value > 0 then
            local seed = eval.scope_draw(ctx)
            local c2 = I.push(ctx, S("leader", lid))
            eval.seed_scope(c2, seed)
            eval.effect(p.effect.value, c2)
        end
    end

    local function leader_target(e, ctx)
        local sc = target(e, ctx)
        return sc and sc.kind == "leader" and sc.id or nil
    end

    -- set_leader = <leader> (a fleet's)
    EFF["set_leader"] = function(e, ctx)
        if ctx.this.kind ~= "fleet" then return O.unmodelled("set_leader", ctx, e) end
        local lid = leader_target(e, ctx)
        if not lid then return end
        push({ type = "set_fleet_leader", id = ctx.this.id, leader = lid })
        sync()
    end

    -- assign_leader = <leader> (CAssignLeaderEffect 0x37467c0): to the scope (a planet or colony:
    -- governor; a fleet)
    EFF["assign_leader"] = function(e, ctx)
        local lid = leader_target(e, ctx)
        if not lid then return end
        push({ type = "assign_leader", kind = ctx.this.kind, id = ctx.this.id, leader = lid })
        sync()
    end

    -- set_policy = { policy = <group> option = <option> cooldown = yes/no }
    EFF["set_policy"] = function(e, ctx)
        if ctx.this.kind ~= "country" then return end
        local p = params(e)
        local pol, opt = text_of(p.policy), text_of(p.option)
        if not pol or not opt then return end
        push({ type = "set_policy", id = ctx.this.id, policy = pol, option = opt, cooldown = O.yes_of(p.cooldown, false) })
        sync()
    end

    -- add_council_agenda_progress = <value>
    EFF["add_council_agenda_progress"] = function(e, ctx)
        if ctx.this.kind ~= "country" then return end
        push({ type = "add_council_agenda_progress", id = ctx.this.id, amount = eval.value(e.value, ctx, e) or 0 })
    end

    -- the council (engine/script/objects_leaders.lua): unlock_council_slots = N (a country's; the
    -- Galactic Paragons DLC's), set_council_position_to_council = <type> (a country's),
    -- set_council_position = <type> (a leader's)
    EFF["unlock_council_slots"] = function(e, ctx)
        if ctx.this.kind ~= "country" then return end
        push({ type = "unlock_council_slots", id = ctx.this.id, amount = O.int_of(e, ctx) or 0,
            paragons = not E.has_dlc or E.has_dlc("Galactic Paragons") })
        sync()
    end
    EFF["set_council_position_to_council"] = function(e, ctx)
        if ctx.this.kind ~= "country" or not e.value.text then return end
        push({ type = "set_council_position_to_council", id = ctx.this.id, ctype = unq(e.value.text) })
        sync()
    end
    EFF["set_council_position"] = function(e, ctx)
        if ctx.this.kind ~= "leader" or not e.value.text then return end
        push({ type = "set_council_position", leader = ctx.this.id, ctype = unq(e.value.text) })
        sync()
    end
end
