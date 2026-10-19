-- simscript/handlers/fleet_actions.lua : queue_actions, clear_fleet_actions (engine.fleets.actions),
-- auto_move_to_planet, remove_auto_move_target (engine.fleets.automove). Applied at once (after the
-- pending engine effects): queue_actions makes its actions now, with their draws, as the game does
-- (CQueueFleetActionsEffect::ExecuteActual 0x372c950).
return function(eval)
    local I = eval._internal
    local EFF = eval.EFF
    local sync = I.sync
    local world = require("engine.world")

    -- the scope's fleet: a fleet, or a ship's
    local function fleet_of(ctx)
        local sc = ctx.this
        if not sc or sc.kind == "none" then return nil end
        if sc.kind == "fleet" then return sc.id end
        if sc.kind == "ship" then
            local s = world.object("ships", sc.id) or world.object("ship", sc.id)
            return s and tonumber(world.field(s, "fleet"))
        end
        return nil
    end

    EFF["queue_actions"] = function(e, ctx)
        local fid = fleet_of(ctx)
        if not fid or type(e.value) ~= "table" or e.value.text then return end
        sync()
        require("engine.fleets.actions").queue(fid, e.value, ctx)
    end

    EFF["clear_fleet_actions"] = function(e, ctx)
        local v = e.value and e.value.text
        local sc = ctx.this
        if v and v ~= "this" and v ~= "yes" then
            local found, s = eval.resolve(v, ctx, e.value)
            if found then sc = s end
        end
        local fid = sc and (sc.kind == "fleet" and sc.id or fleet_of({ this = sc }))
        if not fid then return end
        sync()
        require("engine.fleets.actions").clear(fid)
    end

    -- auto_move_to_planet = <target> | { target clear_auto_move_on_arrival (yes) destroy_on_arrival
    -- (no) arrival_effect = <scripted effect> } (CAutoMoveToPlanetEffect 0x3793c30 / 0x3793f00)
    EFF["auto_move_to_planet"] = function(e, ctx)
        local fid = fleet_of(ctx)
        if not fid then return end
        local target, clear, destroy, effect = nil, true, false, nil
        if e.value.text then
            target = e.value.text
        else
            for _, x in ipairs(e.value) do
                if x.op and x.key then
                    local k, t = x.key.text, x.value.text
                    if k == "target" then target = t
                    elseif k == "clear_auto_move_on_arrival" then clear = t == "yes"
                    elseif k == "destroy_on_arrival" then destroy = t == "yes"
                    elseif k == "arrival_effect" then effect = t
                    end
                end
            end
        end
        if not target then return end
        local found, sc = eval.resolve(target, ctx, e.value)
        if not found or not sc or sc.kind ~= "planet" then return end
        sync()
        require("engine.fleets.automove").to_planet(fid, sc.id, clear, destroy, effect)
    end

    -- destroy_fleet = <fleet> | { target kill_leader destroy_template } (CDestroyFleetEffect
    -- 0x372dcc0: CFleet::SetToBeKilled; removed after the phase: engine.fleets.create.kill)
    EFF["destroy_fleet"] = function(e, ctx)
        local v = e.value and e.value.text or "this"
        if e.value and e.value.text == nil then
            -- the block form: its `target` (none: nothing) [I]
            v = nil
            for _, x in ipairs(e.value) do
                if x.op and x.key and x.key.text:lower() == "target" then v = x.value.text end
            end
            if not v then return end
        end
        local sc = ctx.this
        if v ~= "this" then
            local found, s = eval.resolve(v, ctx, e.value)
            if not found then return end
            sc = s
        end
        local fid = sc and (sc.kind == "fleet" and sc.id or fleet_of({ this = sc }))
        if not fid then return end
        sync()
        require("engine.fleets.create").kill(fid)
    end

    -- remove_auto_move_target = yes (CRemoveAutoMoveTargetEffect 0x3795760: the setting reset, the
    -- current and queued orders cancelled)
    EFF["remove_auto_move_target"] = function(e, ctx)
        local fid = fleet_of(ctx)
        if not fid then return end
        sync()
        require("engine.fleets.automove").reset(fid)
        require("engine.fleets.orders").clear(fid)
    end
end
