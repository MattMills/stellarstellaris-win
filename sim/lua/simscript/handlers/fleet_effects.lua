-- simscript/handlers/fleet_effects.lua : the fleet package's effects (loaded by handlers/fleet.lua
-- with its helpers F). They write the world directly (engine.world), after the pending engine
-- effects are flushed (sync); ships and fleets are removed through engine.fleets.destroy. [V]
-- marks what the 4.5.2 Linux binary's effect class shows; [I] what is read from the
-- documentation and the save's fields.

return function(eval, F)
    local I = eval._internal
    local EFF = eval.EFF
    local S, NONE, sync = I.S, I.NONE, I.sync
    local world = require("engine.world")
    local num, ref, unq, yes = F.num, F.ref, F.unq, F.yes
    local ship_obj, fleet_obj, army_obj = F.ship_obj, F.fleet_obj, F.army_obj
    local ships_of, fleet_of, fleet_ships = F.ships_of, F.fleet_of, F.fleet_ships

    local stats = { applied = 0 }
    eval.fleet.effect_stats = stats

    local function fmt(v) return string.format("%.5f", v) end
    local function getn(o, k) return num(world.field(o, k)) or 0 end
    local function setn(o, k, v)
        world.set(o, k, fmt(v))
        stats.applied = stats.applied + 1
    end
    local function amount(e, ctx)
        if e.value.text then return eval.value(e.value, ctx, e) end
        local p = F.params(e)
        local x = p.amount or p.value
        return x and eval.value(x.value, ctx, x) or 0
    end
    local function destroy() return require("engine.fleets.destroy") end

    -- -----------------------------------------------------------------------------------------
    -- hit points

    -- shields, then armour, then hull take a flat damage (the ship virtual NCombatRules applies,
    -- each ship of a fleet in turn: CDamageShipEffect::ExecuteActual 0x371d0d0 [V the loop and the
    -- attacker; I the order of the pools]); a ship at 0 hull is destroyed
    local function damage(sid, dmg, killed)
        local s = ship_obj(sid)
        if not s or dmg <= 0 then return end
        local rem = dmg
        for _, k in ipairs({ "shield_hitpoints", "armor_hitpoints", "hitpoints" }) do
            local v = getn(s, k)
            if v > 0 and rem > 0 then
                local take = math.min(v, rem)
                setn(s, k, v - take)
                rem = rem - take
            end
        end
        if getn(s, "hitpoints") <= 0 then killed[#killed + 1] = sid end
    end
    -- damage_ship = <amount> | { amount attacker } (a ship, a fleet: each ship)
    EFF["damage_ship"] = function(e, ctx)
        sync()
        local dmg = amount(e, ctx)
        local killed = {}
        for _, sid in ipairs(ships_of(ctx.this)) do damage(sid, dmg, killed) end
        for _, sid in ipairs(killed) do destroy().ship(sid) end
    end
    -- reduce_hp = <amount> / reduce_hp_percent = <0..1> (a ship): the hull less the amount (the
    -- max hull's fraction), at least 1: it does not kill [I]
    EFF["reduce_hp"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" then return end
        sync()
        local s = ship_obj(sc.id)
        if s then setn(s, "hitpoints", math.max(1, getn(s, "hitpoints") - eval.value(e.value, ctx, e))) end
    end
    EFF["reduce_hp_percent"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" then return end
        sync()
        local s = ship_obj(sc.id)
        if s then
            local cut = getn(s, "max_hitpoints") * eval.value(e.value, ctx, e)
            setn(s, "hitpoints", math.max(1, getn(s, "hitpoints") - cut))
        end
    end
    -- reduce_shield = <amount> (a ship): the shield less the amount, at least 0
    EFF["reduce_shield"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" then return end
        sync()
        local s = ship_obj(sc.id)
        if s then setn(s, "shield_hitpoints", math.max(0, getn(s, "shield_hitpoints") - eval.value(e.value, ctx, e))) end
    end
    -- repair_amount / repair_armor_amount / repair_shield_amount = <amount>, and the _percentage
    -- ones = <0..1> of the max (a ship, a fleet: each ship): the pool up, at most its max
    -- (CRepairAmountEffect 0x371e460 [V the class])
    for name, spec in pairs({
        repair_amount = { "hitpoints", "max_hitpoints", false },
        repair_armor_amount = { "armor_hitpoints", "max_armor_hitpoints", false },
        repair_shield_amount = { "shield_hitpoints", "max_shield_hitpoints", false },
        repair_percentage = { "hitpoints", "max_hitpoints", true },
        repair_armor_percentage = { "armor_hitpoints", "max_armor_hitpoints", true },
        repair_shield_percentage = { "shield_hitpoints", "max_shield_hitpoints", true },
    }) do
        EFF[name] = function(e, ctx)
            sync()
            local v = eval.value(e.value, ctx, e)
            for _, sid in ipairs(ships_of(ctx.this)) do
                local s = ship_obj(sid)
                if s then
                    local max = getn(s, spec[2])
                    local add = spec[3] and max * v or v
                    local now = getn(s, spec[1])
                    if now < max then setn(s, spec[1], math.min(max, now + add)) end
                end
            end
        end
    end
    -- repair_ship = yes (a ship): its hull to its max (CRepairShipEffect 0x371d790 [V the class])
    EFF["repair_ship"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" or not yes(e) then return end
        sync()
        local s = ship_obj(sc.id)
        if s then setn(s, "hitpoints", getn(s, "max_hitpoints")) end
    end
    -- set_disabled = yes/no (a ship): `disabled` (engine.fleets.combat's disabled ship)
    EFF["set_disabled"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" then return end
        sync()
        local s = ship_obj(sc.id)
        if not s then return end
        if yes(e) then
            world.set(s, "disabled", "yes")
        else
            local x = world.entry(s, "disabled")
            if x then world.remove_entry(s, x) end
            world.set(s, "disabled_by_event", "no")
        end
        stats.applied = stats.applied + 1
    end
    -- set_disable_at_health = <0..1> | no (a ship, a fleet: each ship): `disable_at_health`
    EFF["set_disable_at_health"] = function(e, ctx)
        sync()
        local v = e.value.text == "no" and 0 or eval.value(e.value, ctx, e)
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s then setn(s, "disable_at_health", v) end
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- armies

    -- an army removed: from its owner's `owned_armies`, its colony's `army`, its ship, its ground
    -- combat, then the world
    local function remove_from_list(o, key, id)
        local l = o and world.field(o, key)
        if type(l) == "table" then world.remove_value(l, id) end
    end
    local function remove_army(aid)
        local a = army_obj(aid)
        if not a then return false end
        local owner = ref(world.field(a, "owner"))
        if owner then remove_from_list(world.object("country", owner), "owned_armies", aid) end
        local cid = ref(world.field(a, "colony"))
        if cid then remove_from_list(world.object("colony", cid), "army", aid) end
        local sid = ref(world.field(a, "ship"))
        local s = sid and ship_obj(sid)
        if s and ref(world.field(s, "army")) == aid then
            local x = world.entry(s, "army")
            if x then world.remove_entry(s, x) end
        end
        local g = ref(world.field(a, "ground_combat"))
        local gc = g and world.object("ground_combat", g)
        if gc then
            remove_from_list(gc, "attackers", aid)
            remove_from_list(gc, "defenders", aid)
        end
        world.remove("army", aid)
        stats.applied = stats.applied + 1
        return true
    end
    eval.fleet.remove_army = remove_army
    -- remove_army = yes (an army)
    EFF["remove_army"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "army" or not yes(e) then return end
        sync()
        remove_army(sc.id)
    end
    -- remove_all_armies = yes (a planet or ship colony): every army of its colony
    EFF["remove_all_armies"] = function(e, ctx)
        if not yes(e) then return end
        sync()
        local cid = F.colony_of(ctx.this)
        local c = cid and world.object("colony", cid)
        for _, aid in ipairs(c and F.id_list(world.field(c, "army")) or {}) do remove_army(aid) end
    end
    -- damage_army = <amount> (an army): its health less the amount; at 0 it dies (removed) [I]
    EFF["damage_army"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "army" then return end
        sync()
        local a = army_obj(sc.id)
        if not a then return end
        local h = getn(a, "health") - eval.value(e.value, ctx, e)
        if h <= 0 then remove_army(sc.id) else setn(a, "health", h) end
    end

    -- -----------------------------------------------------------------------------------------
    -- removing ships and fleets

    -- the target of `<effect> = <target>` or `{ target = <target> ... }`, and the block's params
    local function target_and_params(e, ctx)
        if e.value.text then return F.target_of(e, ctx), {} end
        local p = F.params(e)
        return F.target_of(p.target, ctx), p
    end
    -- a fleet's commander killed (kill_leader = yes, the default) [I]
    local function kill_commander(fid)
        local f = fleet_obj(fid)
        local l = f and ref(world.field(f, "leader"))
        if l and world.object("leaders", l) then
            local okk, lead = pcall(require, "engine.leaders")
            if okk and lead.kill then pcall(lead.kill, l) end
        end
    end
    -- delete_fleet / destroy_fleet = <fleet> | { target kill_leader destroy_template } (any scope):
    -- the fleet removed (destroy: with its death, on_ship_destroyed... not fired here [I])
    local function remove_fleet(e, ctx)
        local t, p = target_and_params(e, ctx)
        if not t or t.kind ~= "fleet" then return end
        sync()
        if not fleet_obj(t.id) then return end
        if not p.kill_leader or yes(p.kill_leader) then kill_commander(t.id) end
        destroy().fleet(t.id)
        stats.applied = stats.applied + 1
    end
    EFF["delete_fleet"] = remove_fleet
    if not EFF["destroy_fleet"] then EFF["destroy_fleet"] = remove_fleet end
    -- delete_ship / destroy_ship = <ship> (any scope)
    local function remove_ship(e, ctx)
        local t = target_and_params(e, ctx)
        if not t or t.kind ~= "ship" then return end
        sync()
        if not ship_obj(t.id) then return end
        destroy().ship(t.id)
        stats.applied = stats.applied + 1
    end
    EFF["delete_ship"] = remove_ship
    EFF["destroy_ship"] = remove_ship
    -- delete_fleet_naval_cap / destroy_fleet_naval_cap = { target naval_cap kill_leader }: ships of
    -- the fleet removed, last first, up to naval_cap of their size_multiplier [I]
    local function remove_naval_cap(e, ctx)
        local t, p = target_and_params(e, ctx)
        if not t or t.kind ~= "fleet" then return end
        sync()
        local cap = p.naval_cap and eval.value(p.naval_cap.value, ctx, p.naval_cap) or 1
        local ships = fleet_ships(t.id)
        local used = 0
        for i = #ships, 1, -1 do
            local sid = ships[i]
            local size = F.R.ship_size_of(sid)
            local m = size and tonumber(F.R.ship_size_field(size, "size_multiplier")) or 1
            if used + m > cap then break end
            used = used + m
            if i == 1 and (not p.kill_leader or yes(p.kill_leader)) then kill_commander(t.id) end
            destroy().ship(sid)
            stats.applied = stats.applied + 1
        end
    end
    EFF["delete_fleet_naval_cap"] = remove_naval_cap
    EFF["destroy_fleet_naval_cap"] = remove_naval_cap

    -- -----------------------------------------------------------------------------------------
    -- orders

    -- clear_orders = yes (a fleet): every order cleared (engine.fleets.orders)
    EFF["clear_orders"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or not yes(e) then return end
        sync()
        local f = fleet_obj(sc.id)
        if not f then return end
        require("engine.fleets.orders").clear(sc.id)
        stats.applied = stats.applied + 1
    end
    -- order_forced_return = yes (a fleet): its orders cleared, then the return to its home base
    -- (engine.fleets.orders' return_fleet_order) [I]
    EFF["order_forced_return"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or not yes(e) then return end
        sync()
        if not fleet_obj(sc.id) then return end
        local orders = require("engine.fleets.orders")
        orders.clear(sc.id)
        orders.return_to_base(sc.id)
        stats.applied = stats.applied + 1
    end
    -- auto_follow_fleet = { target attack_fleet } (a ship's fleet, a fleet): a follow order on the
    -- target (attack_when_in_range with attack_fleet) and its auto-movement set to it [I]
    EFF["auto_follow_fleet"] = function(e, ctx)
        local fid = fleet_of(ctx.this)
        if not fid or e.value.text then return end
        local p = F.params(e)
        local t = F.target_of(p.target, ctx)
        if not t or t.kind ~= "fleet" then return end
        sync()
        local f = fleet_obj(fid)
        if not f then return end
        local b = {}
        world.append(b, "fleet", t.id)
        world.append(b, "attack_when_in_range", (p.attack_fleet and yes(p.attack_fleet)) and "yes" or "no")
        local orders = require("engine.fleets.orders")
        orders.clear(fid)
        orders.issue(fid, { { key = { text = "follow_order" }, op = "=", value = b } })
        local am = {}
        world.append(am, "type", "auto_move_fleet")
        world.append(am, "auto_move_target", t.id)
        world.append(am, "clear_on_new_orders", "yes")
        local x = world.entry(f, "auto_movement")
        if x then world.remove_entry(f, x) end
        world.append(f, "auto_movement", am)
        stats.applied = stats.applied + 1
    end
    -- set_home_base = <starbase> (a fleet): `home_base` (engine.fleets.orders' return order goes
    -- there) [I]
    EFF["set_home_base"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return end
        local t = F.target_of(e, ctx)
        if not t or t.kind ~= "starbase" then return end
        sync()
        local f = fleet_obj(sc.id)
        if f then world.set(f, "home_base", t.id) stats.applied = stats.applied + 1 end
    end
    -- dismantle = yes (a fleet: an orbital station): removed [I: no refund]
    EFF["dismantle"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or not yes(e) then return end
        sync()
        if fleet_obj(sc.id) and F.is_station(sc.id) then
            destroy().fleet(sc.id)
            stats.applied = stats.applied + 1
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- fleet fields

    -- a fleet's field set from `<effect> = <value>` (a fleet; with `ship` also a ship's fleet)
    local function fleet_setter(name, key, opts)
        opts = opts or {}
        EFF[name] = function(e, ctx)
            local sc = ctx.this
            if sc == NONE then return end
            local fid = (opts.ship and fleet_of(sc)) or (sc.kind == "fleet" and sc.id) or nil
            local country = opts.country and sc.kind == "country" and sc.id or nil
            if not fid and not country then return end
            local v = e.value.text
            if not v then return end
            if opts.number then v = fmt(eval.value(e.value, ctx, e)) else v = unq(v) end
            if opts.valid and not opts.valid[v] then return end
            sync()
            if fid then
                local f = fleet_obj(fid)
                if not f then return end
                if opts.none and v == "none" then
                    local x = world.entry(f, key)
                    if x then world.remove_entry(f, x) end
                else
                    world.set(f, key, v)
                end
            else
                -- a country's default for its fleets (`<key>` on the country) [I]
                local c = world.object("country", country)
                if not c then return end
                world.set(c, key, v)
            end
            stats.applied = stats.applied + 1
        end
    end
    -- set_aggro_range = <int> (a country, a fleet): `aggro_range`
    fleet_setter("set_aggro_range", "aggro_range", { number = true, country = true })
    -- set_aggro_range_measure_from = self | return_point: `aggro_range_measure_from` (0 / 1 as the
    -- save writes it)
    EFF["set_aggro_range_measure_from"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or not e.value.text then return end
        local v = ({ self = "0", return_point = "1" })[unq(e.value.text)]
        if not v then return end
        sync()
        local o = sc.kind == "fleet" and fleet_obj(sc.id) or (sc.kind == "country" and world.object("country", sc.id))
        if o then world.set(o, "aggro_range_measure_from", v) stats.applied = stats.applied + 1 end
    end
    -- set_fleet_bombardment_stance = <stance> (a fleet): `bombardment_stance` (common/
    -- bombardment_stances)
    fleet_setter("set_fleet_bombardment_stance", "bombardment_stance")
    -- set_fauna_fleet_growth_stance = controlled | excessive | none (a country, a fleet):
    -- `space_fauna_growth_stance` (none: back to the country's policy)
    fleet_setter("set_fauna_fleet_growth_stance", "space_fauna_growth_stance",
        { country = true, none = true, valid = { controlled = true, excessive = true, none = true } })
    -- set_formation_scale = <float> (a fleet): `movement_manager.formation.scale`
    EFF["set_formation_scale"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return end
        sync()
        local f = fleet_obj(sc.id)
        local fm = f and world.path(f, "movement_manager", "formation")
        if type(fm) == "table" then setn(fm, "scale", eval.value(e.value, ctx, e)) end
    end
    -- set_fleet_formation = { position = { x y } ... } (a fleet): a custom formation, the ships'
    -- positions in order (`movement_manager.formation = { type = custom position ... }`) [I]
    EFF["set_fleet_formation"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or e.value.text then return end
        sync()
        local f = fleet_obj(sc.id)
        local mm = f and world.field(f, "movement_manager")
        if type(mm) ~= "table" then return end
        local fm = world.field(mm, "formation")
        local scale = type(fm) == "table" and world.field(fm, "scale") or "1"
        local b = {}
        world.append(b, "scale", scale)
        world.append(b, "type", "custom")
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.key.text:lower() == "position" and x.value.text == nil then
                local q = F.params({ value = x.value })
                local pos = {}
                world.append(pos, "x", fmt(q.x and eval.value(q.x.value, ctx, q.x) or 0))
                world.append(pos, "y", fmt(q.y and eval.value(q.y.value, ctx, q.y) or 0))
                world.append(b, "position", pos)
            end
        end
        local old = world.entry(mm, "formation")
        if old then world.remove_entry(mm, old) end
        world.insert(mm, 1, "formation", b)
        stats.applied = stats.applied + 1
    end
    -- set_fleet_settings = { <setting> = yes/no ... } (a fleet): `settings`, every setting not
    -- named back to its default (the block holds only the non-default ones, as the save) [I]
    EFF["set_fleet_settings"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or e.value.text then return end
        sync()
        local f = fleet_obj(sc.id)
        if not f then return end
        local b = {}
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.value.text then world.append(b, x.key.text, x.value.text) end
        end
        local old = world.entry(f, "settings")
        if old then world.remove_entry(f, old) end
        world.append(f, "settings", b)
        stats.applied = stats.applied + 1
    end
    -- set_cloaking_active = yes/no (a fleet): `cloaking_active` [I]
    EFF["set_cloaking_active"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return end
        sync()
        local f = fleet_obj(sc.id)
        if f then world.set(f, "cloaking_active", yes(e) and "yes" or "no") stats.applied = stats.applied + 1 end
    end
    -- lock_animation_state = <state> | none (a ship, a fleet: each ship): `locked_animation_state`
    -- (none clears it) [I]
    EFF["lock_animation_state"] = function(e, ctx)
        if not e.value.text then return end
        sync()
        local v = unq(e.value.text)
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s then
                if v == "none" then
                    local x = world.entry(s, "locked_animation_state")
                    if x then world.remove_entry(s, x) end
                else
                    world.set(s, "locked_animation_state", v, true)
                end
                stats.applied = stats.applied + 1
            end
        end
    end
    -- set_confused = yes/no, set_terrified_by = <attacker>, remove_terrified = yes (a ship, a fleet:
    -- each ship): the combat states, cleared at the end of combat (`confused`, `terrified_by`) [I]
    EFF["set_confused"] = function(e, ctx)
        sync()
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s then
                if yes(e) then world.set(s, "confused", "yes")
                else local x = world.entry(s, "confused") if x then world.remove_entry(s, x) end end
                stats.applied = stats.applied + 1
            end
        end
    end
    EFF["set_terrified_by"] = function(e, ctx)
        local t = F.target_of(e, ctx)
        if not t or (t.kind ~= "ship" and t.kind ~= "fleet") then return end
        sync()
        local by = t.kind == "ship" and t.id or fleet_ships(t.id)[1]
        if not by then return end
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s then world.set(s, "terrified_by", by) stats.applied = stats.applied + 1 end
        end
    end
    EFF["remove_terrified"] = function(e, ctx)
        if not yes(e) then return end
        sync()
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            local x = s and world.entry(s, "terrified_by")
            if x then world.remove_entry(s, x) stats.applied = stats.applied + 1 end
        end
    end
    -- add_growth = <amount> / reset_growth = { } (a ship, a fleet: each ship; not space fauna):
    -- `growth` up / back to 0 [I]
    local function not_fauna(sid)
        local size = F.R.ship_size_of(sid)
        return not (size and F.R.ship_size_flag(size, "is_space_fauna_ship"))
    end
    EFF["add_growth"] = function(e, ctx)
        sync()
        local v = eval.value(e.value, ctx, e)
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s and not_fauna(sid) then setn(s, "growth", getn(s, "growth") + v) end
        end
    end
    EFF["reset_growth"] = function(e, ctx)
        sync()
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s and not_fauna(sid) then setn(s, "growth", 0) end
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- MIA and leases

    local function date_plus(days)
        local today = eval.today and eval.today() or 0
        local d = today + math.floor(days)
        local y = math.floor(d / 360)
        local m = math.floor((d % 360) / 30) + 1
        return string.format("%d.%02d.%02d", y, m, d % 30 + 1)
    end
    -- set_mia = <mia type> (a fleet): MIA (`mia_type`, `mia_from` its place, `return_date` the
    -- type's days (MIA_TIME_MULT... the type's `days` [I])); not for a fleet that cannot go MIA
    EFF["set_mia"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or not e.value.text then return end
        sync()
        local f = fleet_obj(sc.id)
        if not f or world.path(f, "properties", "station") == "yes" then return end
        local key = unq(e.value.text)
        local defs = require("engine.defs")
        local d = defs.get("common/mia_types", key)
        local days = d and tonumber(defs.field(d.block, "days")) or 30
        world.set(f, "mia_type", key)
        world.set(f, "return_date", date_plus(days), true)
        local c = world.path(f, "movement_manager", "coordinate")
        local mf = world.field(f, "mia_from")
        if type(c) == "table" and type(mf) == "table" then
            for _, k in ipairs({ "x", "y", "origin" }) do world.set(mf, k, world.field(c, k)) end
        end
        stats.applied = stats.applied + 1
    end
    -- set_mia_return_delay = <days> (a fleet MIA): `return_date` today + days
    EFF["set_mia_return_delay"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return end
        sync()
        local f = fleet_obj(sc.id)
        if not f or world.field(f, "mia_type") == nil then return end
        world.set(f, "return_date", date_plus(eval.value(e.value, ctx, e)), true)
        stats.applied = stats.applied + 1
    end
    -- return_from_mia = <fleet> (a fleet): an MIA fleet back at once (`mia_type`, `return_date`
    -- removed; its place its mia_from's) [I]
    EFF["return_from_mia"] = function(e, ctx)
        local t = F.target_of(e, ctx) or (ctx.this ~= NONE and ctx.this or nil)
        if not t or t.kind ~= "fleet" then return end
        sync()
        local f = fleet_obj(t.id)
        if not f or world.field(f, "mia_type") == nil then return end
        for _, k in ipairs({ "mia_type", "return_date" }) do
            local x = world.entry(f, k)
            if x then world.remove_entry(f, x) end
        end
        local mf = world.field(f, "mia_from")
        local c = world.path(f, "movement_manager", "coordinate")
        if type(mf) == "table" and type(c) == "table" and ref(world.field(mf, "origin")) then
            for _, k in ipairs({ "x", "y", "origin" }) do world.set(c, k, world.field(mf, k)) end
        end
        stats.applied = stats.applied + 1
    end
    -- give_fleet = { controller days } (a fleet): leased to the controller (`contract = { controller
    -- end_date }`), prolong_fleet_contract = { days }, end_fleet_contract = yes | { initiator reason }
    -- (the contract removed) [I]
    EFF["give_fleet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or e.value.text then return end
        local p = F.params(e)
        local c = F.target_of(p.controller, ctx)
        if not c or c.kind ~= "country" then return end
        sync()
        local f = fleet_obj(sc.id)
        if not f then return end
        local b = {}
        world.append(b, "controller", c.id)
        world.append(b, "end_date", date_plus(p.days and eval.value(p.days.value, ctx, p.days) or 0), true)
        local x = world.entry(f, "contract")
        if x then world.remove_entry(f, x) end
        world.append(f, "contract", b)
        stats.applied = stats.applied + 1
    end
    EFF["prolong_fleet_contract"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or e.value.text then return end
        sync()
        local f = fleet_obj(sc.id)
        local c = f and world.field(f, "contract")
        if type(c) ~= "table" then return end
        local p = F.params(e)
        local d = unq(world.field(c, "end_date"))
        local y, m, dd = (d or ""):match("^(%d+)%.(%d+)%.(%d+)$")
        local today = eval.today and eval.today() or 0
        local left = y and (tonumber(y) * 360 + (tonumber(m) - 1) * 30 + tonumber(dd) - 1 - today) or 0
        world.set(c, "end_date", date_plus(left + (p.days and eval.value(p.days.value, ctx, p.days) or 0)), true)
        stats.applied = stats.applied + 1
    end
    EFF["end_fleet_contract"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or e.value.text == "no" then return end
        sync()
        local f = fleet_obj(sc.id)
        local x = f and world.entry(f, "contract")
        if x then world.remove_entry(f, x) stats.applied = stats.applied + 1 end
    end

    -- -----------------------------------------------------------------------------------------
    -- countries, starbases, federations, debris

    -- set_ship_prefix = <string> (a country): `ship_prefix = { key }`
    EFF["set_ship_prefix"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or not e.value.text then return end
        sync()
        local c = world.object("country", sc.id)
        if not c then return end
        local b = {}
        world.append(b, "key", unq(e.value.text), true)
        local x = world.entry(c, "ship_prefix")
        if x then world.remove_entry(c, x) end
        world.append(c, "ship_prefix", b)
        stats.applied = stats.applied + 1
    end
    -- set_ai_ship_roles = { <size> = <role> | { <role> = <weight> ... } } (a country):
    -- `ai_ship_role_overrides` as the save writes them (one block per role: corvette = { "gunship" =
    -- "70" }); clear_ai_ship_roles = yes removes them
    EFF["set_ai_ship_roles"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or e.value.text then return end
        sync()
        local c = world.object("country", sc.id)
        if not c then return end
        local b = {}
        for _, x in ipairs(e.value) do
            if x.op and x.key then
                if x.value.text then
                    local r = {}
                    world.append(r, unq(x.value.text), "100", true)
                    world.append(b, x.key.text, r)
                else
                    for _, y in ipairs(x.value) do
                        if y.op and y.key and y.value.text then
                            local r = {}
                            world.append(r, unq(y.key.text), unq(y.value.text), true)
                            world.append(b, x.key.text, r)
                        end
                    end
                end
            end
        end
        local old = world.entry(c, "ai_ship_role_overrides")
        if old then world.remove_entry(c, old) end
        world.append(c, "ai_ship_role_overrides", b)
        stats.applied = stats.applied + 1
    end
    EFF["clear_ai_ship_roles"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or not yes(e) then return end
        sync()
        local c = world.object("country", sc.id)
        local x = c and world.entry(c, "ai_ship_role_overrides")
        if x then world.remove_entry(c, x) end
        stats.applied = stats.applied + 1
    end
    -- rebuild_owned_starbase_designs = yes / refresh_auto_generated_ship_designs = yes (a country):
    -- the auto-generated designs marked to be made again (`ship_designs_dirty = yes`: the designer
    -- is not ported) [I]
    for _, name in ipairs({ "rebuild_owned_starbase_designs", "refresh_auto_generated_ship_designs" }) do
        EFF[name] = function(e, ctx)
            local sc = ctx.this
            if sc == NONE or sc.kind ~= "country" or not yes(e) then return end
            sync()
            local c = world.object("country", sc.id)
            if c then world.set(c, "ship_designs_dirty", "yes") stats.applied = stats.applied + 1 end
        end
    end
    -- set_ship_construction_type = <starbase type> | none (a starbase): `ship_construction_type` [I]
    EFF["set_ship_construction_type"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "starbase" or not e.value.text then return end
        sync()
        local sb = world.object("starbases", sc.id)
        if not sb then return end
        local v = unq(e.value.text)
        if v == "none" then
            local x = world.entry(sb, "ship_construction_type")
            if x then world.remove_entry(sb, x) end
        else
            world.set(sb, "ship_construction_type", v, true)
        end
        stats.applied = stats.applied + 1
    end
    -- set_only_leader_builds_fleets = yes/no (a federation): `only_leader_builds_fleets` [I]
    EFF["set_only_leader_builds_fleets"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "federation" then return end
        sync()
        local f = world.object("federation", sc.id)
        if f then world.set(f, "only_leader_builds_fleets", yes(e) and "yes" or "no") stats.applied = stats.applied + 1 end
    end
    -- pass_debris_ownership = { owner } (a debris): `owner` [I]
    EFF["pass_debris_ownership"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "debris" or e.value.text then return end
        local o = F.target_of(F.params(e).owner, ctx)
        if not o or o.kind ~= "country" then return end
        sync()
        local d = world.object("debris", sc.id)
        if d then world.set(d, "owner", o.id) stats.applied = stats.applied + 1 end
    end
    -- owned_fleet_list_tooltip = { limit divider_tooltip } (a country): a tooltip only; the limit
    -- evaluated for each owned fleet, nothing changed (the game's tooltip text)
    EFF["owned_fleet_list_tooltip"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or e.value.text then return end
        sync()
        local limit = F.params(e).limit
        for _, s2 in ipairs(eval.LISTS.owned_fleet and eval.LISTS.owned_fleet(sc, ctx) or {}) do
            if limit then eval.trigger(limit.value, I.push(ctx, s2)) end
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- citizenship and military service

    -- set_citizenship_type / set_military_service_type = { country type cooldown } (a pop group,
    -- leader, species): the country's species rights entry for the species (`species_rights = {
    -- { species citizenship military_service former_* } }`), the old one kept as former_* [I]
    local function species_of(sc)
        if sc.kind == "species" then return sc.id end
        local store = sc.kind == "leader" and "leaders" or "pop_groups"
        local o = world.object(store, sc.id)
        local k = o and world.field(o, "key")
        return type(k) == "table" and ref(world.field(k, "species")) or (o and ref(world.field(o, "species")))
    end
    for name, key in pairs({ set_citizenship_type = "citizenship", set_military_service_type = "military_service" }) do
        EFF[name] = function(e, ctx)
            local sc = ctx.this
            if sc == NONE or e.value.text then return end
            local p = F.params(e)
            local c = F.target_of(p.country, ctx)
            local ty = p.type and unq(p.type.value.text)
            if not c or c.kind ~= "country" or not ty then return end
            sync()
            local sp = species_of(sc)
            local co = world.object("country", c.id)
            if not sp or not co then return end
            local sr = world.field(co, "species_rights")
            if type(sr) ~= "table" then
                world.append(co, "species_rights", {})
                sr = world.field(co, "species_rights")
            end
            local entry
            for _, b in ipairs(world.blocks(sr)) do
                if ref(world.field(b, "species")) == sp then entry = b break end
            end
            if not entry then
                entry = {}
                world.append(entry, "species", sp)
                world.push(sr, entry)
            end
            local old = world.field(entry, key)
            if old then world.set(entry, "former_" .. key, unq(old)) end
            world.set(entry, key, ty)
            if p.cooldown and yes(p.cooldown) then world.set(entry, key .. "_cooldown", date_plus(360), true) end
            stats.applied = stats.applied + 1
        end
    end
end
