-- simscript/handlers/fleet_triggers.lua : the fleet package's triggers (loaded by
-- handlers/fleet.lua with its helpers F). [V] marks what the 4.5.2 Linux binary's trigger class
-- shows; [I] what is read from the documentation and the save's fields.

return function(eval, F)
    local I = eval._internal
    local TRIG, AMOUNTS = eval.TRIG, I.AMOUNTS
    -- numeric triggers as values (complex_trigger_modifier: eval.TVAL[name](ctx, e), e.value the
    -- `parameters` block)
    eval.TVAL = eval.TVAL or {}
    local TVAL = eval.TVAL
    local S, NONE, sync, compare = I.S, I.NONE, I.sync, I.compare
    local world = require("engine.world")
    local R = F.R
    local num, ref, unq, yes, value, cmp = F.num, F.ref, F.unq, F.yes, F.value, F.cmp
    local ship_obj, fleet_obj, army_obj, design_obj = F.ship_obj, F.fleet_obj, F.army_obj, F.design_obj
    local ships_of, fleet_of, fleet_ships = F.ships_of, F.fleet_of, F.fleet_ships

    local function defs() return require("engine.defs") end
    local function define(group, key, default)
        local d = defs()
        for _, f in pairs(d.folder("common/defines")) do
            local g = d.field(f.block, group)
            local v = type(g) == "table" and tonumber(d.field(g, key))
            if v then return v end
        end
        return default
    end

    -- a ship's numeric field
    local function sfield(sid, key)
        local s = ship_obj(sid)
        return s and num(world.field(s, key)) or nil
    end
    -- the sum of a field over a ship or fleet scope's ships, and of its max field
    local function sums(sc, key, max_key)
        local cur, max, n = 0, 0, 0
        for _, sid in ipairs(ships_of(sc)) do
            cur = cur + (sfield(sid, key) or 0)
            max = max + (sfield(sid, max_key) or 0)
            n = n + 1
        end
        return cur, max, n
    end
    local function ship_scope(ctx)
        local sc = ctx.this
        return sc ~= NONE and sc.kind == "ship" and ship_obj(sc.id) and sc.id or nil
    end

    -- the design and growth stage a ship, design or growth stage scope stands for
    local function design_stage(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "ship" then
            local s = ship_obj(sc.id)
            local sdi = s and world.field(s, "ship_design_implementation")
            if type(sdi) ~= "table" then return nil end
            return ref(world.field(sdi, "design")), num(world.field(sdi, "growth_stage")) or 0
        elseif F.is_design(sc) then
            return sc.id, 0
        elseif sc.kind == "ship_growth_stage" then
            local d, st = tostring(sc.id):match("^(%d+)/(%d+)$")
            return tonumber(d), tonumber(st) or 0
        end
        return nil
    end
    -- a design's growth stage block (`growth_stages = { { ship_size ... } ... }`) and its ship size
    local function stage_block(did, stage)
        local d = design_obj(did)
        local gs = d and world.field(d, "growth_stages")
        local b = type(gs) == "table" and world.blocks(gs)[(stage or 0) + 1]
        return b, b and unq(world.field(b, "ship_size"))
    end
    local function size_of(sc)
        local did, st = design_stage(sc)
        if not did then return nil end
        local _, size = stage_block(did, st)
        return size
    end
    local function size_def(size)
        local d = size and defs().get("common/ship_sizes", size)
        return d and d.block
    end
    local function size_number(size, key)
        local b = size_def(size)
        local v = b and defs().field(b, key)
        local n = tonumber(v)
        if not n and type(v) == "string" then
            local okc, create = pcall(require, "engine.fleets.create")
            local d = defs().get("common/ship_sizes", size)
            n = okc and create.number and create.number(v, d and d.file) or nil
        end
        return n
    end

    -- -----------------------------------------------------------------------------------------
    -- hit points

    -- has_hp / has_max_hp / has_shield_hp / has_max_armor_hp (a ship) <op> <value>: the ship's
    -- hull, max hull, shield, max armour [I]
    for name, key in pairs({ has_hp = "hitpoints", has_max_hp = "max_hitpoints", has_shield_hp = "shield_hitpoints",
        has_max_armor_hp = "max_armor_hitpoints" }) do
        TRIG[name] = function(e, ctx)
            local sid = ship_scope(ctx)
            if not sid then return false end
            sync()
            return cmp(sfield(sid, key) or 0, e, ctx)
        end
    end
    -- has_armor_percentage / has_shield_percentage (a ship, a fleet: its ships together) <op> <0..1>
    for name, k in pairs({ has_armor_percentage = { "armor_hitpoints", "max_armor_hitpoints" },
        has_shield_percentage = { "shield_hitpoints", "max_shield_hitpoints" } }) do
        TRIG[name] = function(e, ctx)
            sync()
            local cur, max, n = sums(ctx.this, k[1], k[2])
            if n == 0 then return false end
            return cmp(max > 0 and cur / max or 0, e, ctx)
        end
    end
    -- is_damaged = yes/no (a ship): its hull under CShip::CalcMaxHitPoints [V 0x3b67940]
    TRIG["is_damaged"] = function(e, ctx)
        local sid = ship_scope(ctx)
        if not sid then return false end
        sync()
        local d = (sfield(sid, "hitpoints") or 0) < (sfield(sid, "max_hitpoints") or 0)
        return d == yes(e)
    end
    -- fleet_integrity (a fleet) <op> <value>: its ships' (shield + hull) over their (max shield +
    -- max hull), as a percentage (0..100) [I: the documented example compares with 100]
    TRIG["fleet_integrity"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return false end
        sync()
        local h, hm, n = sums(sc, "hitpoints", "max_hitpoints")
        local s, sm = sums(sc, "shield_hitpoints", "max_shield_hitpoints")
        if n == 0 then return false end
        local tot = hm + sm
        return cmp(tot > 0 and (h + s) / tot * 100 or 0, e, ctx)
    end
    -- is_being_repaired = yes/no (a ship, a fleet: any of its ships): `is_being_repaired` [I]
    TRIG["is_being_repaired"] = function(e, ctx)
        sync()
        local any = false
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s and world.field(s, "is_being_repaired") == "yes" then any = true break end
        end
        return any == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- fleets

    -- is_in_combat = yes/no (a ship's fleet, a fleet): its combat list not empty [I]
    TRIG["is_in_combat"] = function(e, ctx)
        local fid = fleet_of(ctx.this)
        if not fid then return false end
        sync()
        local f = fleet_obj(fid)
        local l = f and world.path(f, "combat", "in_combat_with")
        local any = type(l) == "table" and #world.blocks(l) > 0
        return any == yes(e)
    end
    -- is_fleet_idle = yes/no (a ship's fleet, a fleet: CFleet::IsFleetIdle [V 0x3ba95e0]): no
    -- current order and not moving [I the inside]
    TRIG["is_fleet_idle"] = function(e, ctx)
        local fid = fleet_of(ctx.this)
        if not fid then return false end
        sync()
        local f = fleet_obj(fid)
        local idle = world.field(f, "current_order") == nil
            and (unq(world.path(f, "movement_manager", "state")) or "move_idle") == "move_idle"
        return idle == yes(e)
    end
    -- is_orbiting_star = yes/no (a ship's fleet, a fleet): its orbitable is its system's star
    TRIG["is_orbiting_star"] = function(e, ctx)
        local fid = fleet_of(ctx.this)
        if not fid then return false end
        sync()
        local k, id = F.orbitable(fid)
        local sys = F.system_of_fleet(fid)
        local star = sys and R.star_planet(sys)
        return (k == "planet" and id == star) == yes(e)
    end
    -- has_auto_move_target = yes/no (a ship's fleet, a fleet): `auto_movement.auto_move_target`
    TRIG["has_auto_move_target"] = function(e, ctx)
        local fid = fleet_of(ctx.this)
        if not fid then return false end
        sync()
        local f = fleet_obj(fid)
        local t = ref(world.path(f, "auto_movement", "auto_move_target"))
        return (t ~= nil) == yes(e)
    end
    -- has_automation_setting = <key> (a fleet): only during automated target selection; false
    -- everywhere else, as documented [V the documentation]
    TRIG["has_automation_setting"] = function(e, ctx)
        local active = ctx.automation_settings
        return active ~= nil and active[unq(e.value.text) or ""] == true
    end
    -- is_garrison = yes/no (a fleet): the fleet's garrison flag (CFleet +0x1271 bit 2 [V
    -- 0x3bf7d90]; the save's `properties.garrison` [I])
    TRIG["is_garrison"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return false end
        sync()
        local f = fleet_obj(sc.id)
        return (f ~= nil and world.path(f, "properties", "garrison") == "yes") == yes(e)
    end
    -- is_leased = yes/no (a fleet): CFleet::GetOwnershipStatus() == 1 [V 0x3bf7260]: a lease
    -- contract gives it to another controller (`contract` on the fleet [I])
    local function lease_of(fid)
        local f = fleet_obj(fid)
        local c = f and world.field(f, "contract")
        return type(c) == "table" and c or nil
    end
    TRIG["is_leased"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return false end
        sync()
        return (lease_of(sc.id) ~= nil) == yes(e)
    end
    -- lease_days (a fleet) <op> <days>: the days left of its lease contract (0 without one) [I]
    TRIG["lease_days"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return false end
        sync()
        local c = lease_of(sc.id)
        local left = 0
        if c then
            local today = eval.today and eval.today() or 0
            local d = unq(world.field(c, "end_date"))
            local y, m, dd = (d or ""):match("^(%d+)%.(%d+)%.(%d+)$")
            if y then left = math.max(0, (tonumber(y) * 360 + (tonumber(m) - 1) * 30 + tonumber(dd) - 1) - today) end
        end
        return cmp(left, e, ctx)
    end
    -- can_go_mia = yes/no (a fleet): not a station, has ships, not already MIA [I]
    TRIG["can_go_mia"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return false end
        sync()
        local f = fleet_obj(sc.id)
        local ok = f ~= nil and world.path(f, "properties", "station") ~= "yes" and #fleet_ships(sc.id) > 0
            and world.field(f, "mia_type") == nil
        return ok == yes(e)
    end
    -- is_constructing = <what> (a ship's fleet, a fleet): its current build order makes it: a
    -- megastructure (any or of a type), a starbase, a mining or research station, an observation
    -- post, or a ship of a class [I]
    TRIG["is_constructing"] = function(e, ctx)
        local fid = fleet_of(ctx.this)
        if not fid then return false end
        sync()
        local want = unq(e.value.text)
        local f = fleet_obj(fid)
        local cur = f and world.field(f, "current_order")
        if type(cur) ~= "table" then return false end
        local mo = world.field(cur, "build_megastructure_order")
        if type(mo) == "table" then
            return want == "megastructure" or unq(world.field(mo, "type")) == want
        end
        local so = world.field(cur, "build_orbital_station_order")
        if type(so) == "table" then
            local class = unq(world.field(so, "class"))
            local map = { shipclass_starbase = "starbase", shipclass_mining_station = "mining_station",
                shipclass_research_station = "research_station", shipclass_observation_station = "observation_post" }
            return map[class] == want or class == want
        end
        return false
    end
    -- has_status = <status> (a ship, a fleet: any ship): the colossus weapon's status (charging,
    -- firing: the ship's `status` [I])
    TRIG["has_status"] = function(e, ctx)
        sync()
        local want = unq(e.value.text)
        for _, sid in ipairs(ships_of(ctx.this)) do
            local s = ship_obj(sid)
            if s and unq(world.field(s, "status")) == want then return true end
        end
        return false
    end
    -- has_cloaking_strength / has_cloaking_detection (a ship, a fleet; a starbase for detection)
    -- <op> <value>: the ships' modifier (ship_cloaking_strength_add / ship_cloaking_detection_add),
    -- the fleet's the highest [I]
    local function ship_modifier(sid, key)
        local okm, economy = pcall(require, "engine.economy")
        local M = okm and economy.modifiers and economy.modifiers("ship", sid) or {}
        return M[key] or 0
    end
    for name, key in pairs({ has_cloaking_strength = "ship_cloaking_strength_add",
        has_cloaking_detection = "ship_cloaking_detection_add" }) do
        TRIG[name] = function(e, ctx)
            local sc = ctx.this
            if sc == NONE then return false end
            sync()
            local ships = ships_of(sc)
            if sc.kind == "starbase" then
                local sb = world.object("starbases", sc.id)
                local st = sb and ref(world.field(sb, "station"))
                ships = st and { st } or {}
            end
            local best
            for _, sid in ipairs(ships) do
                local v = ship_modifier(sid, key)
                if not best or v > best then best = v end
            end
            return best ~= nil and cmp(best, e, ctx)
        end
    end
    -- has_ship_owner_type = country | federation | galactic_community | global_ship_design (a
    -- ship, fleet, design, growth stage): the design's owner type: a global design (owned by no
    -- country's collection: the global designs), a federation's, the community's, else country [I]
    local function design_owner_type(did)
        local d = design_obj(did)
        if not d then return nil end
        local t = unq(world.field(d, "ship_owner_type"))
        if t then return t end
        for _, c in ipairs(world.all("country")) do
            for _, x in ipairs(F.owned_designs(c)) do
                if x == did then return "country" end
            end
        end
        return "global_ship_design"
    end
    TRIG["has_ship_owner_type"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local did = design_stage(sc.kind == "fleet" and S("ship", fleet_ships(sc.id)[1] or -1) or sc)
        return did ~= nil and design_owner_type(did) == unq(e.value.text)
    end

    -- -----------------------------------------------------------------------------------------
    -- designs, sizes, growth

    -- has_role = <role> (a design, a growth stage): the stage's `ai_role` / the design's `role` [I]
    TRIG["has_role"] = function(e, ctx)
        sync()
        local did, st = design_stage(ctx.this)
        if not did then return false end
        local want = unq(e.value.text)
        local d = design_obj(did)
        if d and unq(world.field(d, "role")) == want then return true end
        local b = stage_block(did, st)
        if b and (unq(world.field(b, "role")) == want or unq(world.field(b, "ai_role")) == want) then return true end
        return false
    end
    -- is_designable = yes/no (a ship, a fleet: all ships, a design, a growth stage): its ship
    -- size's `designable` (ship_sizes) [I]
    TRIG["is_designable"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local list = sc.kind == "fleet" and F.scopes("ship", fleet_ships(sc.id)) or { sc }
        if #list == 0 then return false end
        for _, s in ipairs(list) do
            local b = size_def(size_of(s))
            local d = b and defs().field(b, "designable") == "yes"
            if not d then return not yes(e) end
        end
        return yes(e)
    end
    -- ship_size_multiplier (a ship, a growth stage) <op> <v>: its ship size's size_multiplier
    TRIG["ship_size_multiplier"] = function(e, ctx)
        sync()
        local size = size_of(ctx.this)
        if not size then return false end
        return cmp(size_number(size, "size_multiplier") or 1, e, ctx)
    end
    -- (as a value: the size multiplier, 0 without a ship size)
    TVAL["ship_size_multiplier"] = function(ctx)
        sync()
        local size = size_of(ctx.this)
        return size and (size_number(size, "size_multiplier") or 1) or 0
    end
    -- count_ship_size_in_system (a system) = { count limit }: the sum of the size_multiplier of
    -- the ships present for which the limit holds
    if AMOUNTS then
        AMOUNTS["ship_size_in_system"] = {
            list = "ship_in_system",
            weight = function(s)
                sync()
                local size = size_of(s)
                return size and size_number(size, "size_multiplier") or 1
            end,
        }
    end
    -- the ship's growth (bioships: `growth` against the stage's `growth_required` [I])
    local function growth(sid)
        local s = ship_obj(sid)
        return s and num(world.field(s, "growth")) or 0
    end
    local function growth_needed(sc)
        local size = size_of(sc)
        return size and (size_number(size, "growth_required") or size_number(size, "max_growth"))
    end
    -- is_growth_complete = yes/no (a ship): its growth reached what its stage needs
    TRIG["is_growth_complete"] = function(e, ctx)
        local sid = ship_scope(ctx)
        if not sid then return false end
        sync()
        local need = growth_needed(ctx.this)
        local done = need ~= nil and growth(sid) >= need
        return done == yes(e)
    end
    -- bioship_can_grow = yes/no (a ship): a stage needing growth, not complete, not space fauna [I]
    TRIG["bioship_can_grow"] = function(e, ctx)
        local sid = ship_scope(ctx)
        if not sid then return false end
        sync()
        local need = growth_needed(ctx.this)
        local size = size_of(ctx.this)
        local fauna = size and R.ship_size_flag(size, "is_space_fauna_ship")
        local can = need ~= nil and not fauna and growth(sid) < need
        return can == yes(e)
    end
    -- can_be_reanimated = yes/no (a ship, a growth stage): its ship size is space fauna with a
    -- reanimated form (`reanimated_ship_size` / the size's `can_be_reanimated` [I])
    TRIG["can_be_reanimated"] = function(e, ctx)
        sync()
        local size = size_of(ctx.this)
        local b = size_def(size)
        local can = b ~= nil and (defs().field(b, "can_be_reanimated") == "yes"
            or defs().field(b, "reanimated_ship_size") ~= nil)
        return can == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- countries

    -- has_existing_ship_design = <name> (a country): a design of its collection with that name key
    local function design_name(did)
        local d = design_obj(did)
        local n = d and world.field(d, "name")
        if type(n) == "table" then return unq(world.field(n, "key")) end
        return unq(n)
    end
    TRIG["has_existing_ship_design"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        sync()
        local want = unq(e.value.text)
        for _, did in ipairs(F.owned_designs(sc.id)) do
            if design_name(did) == want then return true end
        end
        return false
    end
    -- used_naval_capacity_integer (a country) <op> <n>: `used_naval_capacity`
    TRIG["used_naval_capacity_integer"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        sync()
        local c = world.object("country", sc.id)
        return cmp(math.floor(c and num(world.field(c, "used_naval_capacity")) or 0), e, ctx)
    end
    -- max_naval_capacity (a country) <op> <n>: CCountry::CalcNavalCapacity (engine.ai.navy)
    local function max_cap(sc)
        if sc == NONE or sc.kind ~= "country" then return nil end
        sync()
        local okn, navy = pcall(require, "engine.ai.navy")
        local cap = okn and navy.naval_capacity and navy.naval_capacity(sc.id)
        if cap == nil then
            local c = world.object("country", sc.id)
            cap = c and num(world.field(c, "naval_capacity")) or 0
        end
        return math.floor(cap)
    end
    TRIG["max_naval_capacity"] = function(e, ctx)
        local cap = max_cap(ctx.this)
        return cap ~= nil and cmp(cap, e, ctx)
    end
    -- (as a value, complex_trigger_modifier: the capacity)
    TVAL["max_naval_capacity"] = function(ctx) return max_cap(ctx.this) or 0 end
    -- count_used_naval_cap (a country, ship, fleet) = { limit value <op> n }: the naval cap used
    -- (size_multiplier, military non-civilian ships) of its controlled ships for which limit holds
    local used_cap
    TRIG["count_used_naval_cap"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or e.value.text then return false end
        return F.block_value(e, ctx, used_cap(sc, e.value, ctx))
    end
    -- (as a value: the naval cap used, the `parameters = { limit }` block's limit)
    TVAL["count_used_naval_cap"] = function(ctx, e)
        local sc = ctx.this
        if sc == NONE then return 0 end
        local block = e and type(e.value) == "table" and not e.value.text and e.value or {}
        return used_cap(sc, block, ctx)
    end
    used_cap = function(sc, block, ctx)
        sync()
        local e = { value = block }
        local ships
        if sc.kind == "country" then
            ships = {}
            for _, fid in ipairs(R.controlled_fleets(sc.id)) do
                for _, sid in ipairs(fleet_ships(fid)) do ships[#ships + 1] = sid end
            end
        else
            ships = ships_of(sc)
        end
        local limit
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.key.text:lower() == "limit" then limit = x.value end
        end
        local total = 0
        for _, sid in ipairs(ships) do
            local fid = F.ship_fleet(sid)
            local f = fleet_obj(fid)
            if f and unq(world.field(f, "ship_class")) == "shipclass_military" then
                local s2 = S("ship", sid)
                if not limit or eval.trigger(limit, I.push(ctx, s2)) then
                    total = total + (size_number(size_of(s2), "size_multiplier") or 1)
                end
            end
        end
        return total
    end
    -- is_ai_ship_role = { ship_size role } (a country): the role is among the country's roles for
    -- that size (`ai_ship_role_overrides`, every entry of a weighted block), else the size's own
    -- `ai_ship_data` roles [I]
    TRIG["is_ai_ship_role"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or e.value.text then return false end
        sync()
        local p = F.params(e)
        local size = p.ship_size and unq(p.ship_size.value.text)
        local role = p.role and unq(p.role.value.text)
        if not size or not role then return false end
        local c = world.object("country", sc.id)
        local ov = c and world.field(c, "ai_ship_role_overrides")
        local found_size = false
        if type(ov) == "table" then
            for k, v in world.statements(ov) do
                if unq(k) == size then
                    found_size = true
                    if type(v) == "table" then
                        for rk in world.statements(v) do
                            if unq(rk) == role then return true end
                        end
                    elseif unq(v) == role then
                        return true
                    end
                end
            end
        end
        if found_size then return false end
        local b = size_def(size)
        local ai = b and defs().field(b, "ai_ship_data")
        if type(ai) == "table" then
            for _, x in ipairs(ai) do
                if x.op and x.key and unq(x.key.text) == role then return true end
            end
        end
        return false
    end
    -- num_killed_ships = { target value <op> n } (a country): the ships of the target it destroyed
    -- (the country's `killed_ships = { { country count } }`, kept by engine.fleets.combat [I])
    TRIG["num_killed_ships"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or e.value.text then return false end
        sync()
        local p = F.params(e)
        local t = F.target_of(p.target, ctx)
        local n = 0
        local c = world.object("country", sc.id)
        local l = c and world.field(c, "killed_ships")
        for _, b in ipairs(type(l) == "table" and world.blocks(l) or {}) do
            if t and ref(world.field(b, "country")) == t.id then n = n + (num(world.field(b, "count")) or 0) end
        end
        return F.block_value(e, ctx, n)
    end
    -- num_armies (a country: its armies; a planet or ship colony: its colony's) <op> <n>
    TRIG["num_armies"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local n = 0
        if sc.kind == "country" then
            local c = world.object("country", sc.id)
            n = #(c and F.id_list(world.field(c, "owned_armies")) or {})
        else
            local cid = F.colony_of(sc)
            local c = cid and world.object("colony", cid)
            n = #(c and F.id_list(world.field(c, "army")) or {})
        end
        return cmp(n, e, ctx)
    end
    -- has_army = yes/no (a planet or ship colony): its colony has an army
    TRIG["has_army"] = function(e, ctx)
        sync()
        local cid = F.colony_of(ctx.this)
        local c = cid and world.object("colony", cid)
        local has = c ~= nil and #F.id_list(world.field(c, "army")) > 0
        return has == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- armies

    -- is_army = <target> (an army): the same army
    TRIG["is_army"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "army" then return false end
        local t = F.target_of(e, ctx)
        return t ~= nil and t.kind == "army" and t.id == sc.id
    end
    -- is_ship = <target> (a ship): the same ship
    TRIG["is_ship"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" then return false end
        local t = F.target_of(e, ctx)
        return t ~= nil and t.kind == "ship" and t.id == sc.id
    end
    -- is_defensive_army = yes/no (an army): its army type's `defensive = yes` [I]
    TRIG["is_defensive_army"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "army" then return false end
        sync()
        local a = army_obj(sc.id)
        local t = a and unq(world.field(a, "type"))
        local d = t and defs().get("common/armies", t)
        local def = d ~= nil and defs().field(d.block, "defensive") == "yes"
        return def == yes(e)
    end
    -- is_in_frontline = yes/no (an army): in its ground combat (CArmy::GetGroundCombat [V
    -- 0x3c14890]) and among the combat width's first of its side [I: the width not modelled: in
    -- the combat]
    TRIG["is_in_frontline"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "army" then return false end
        sync()
        local a = army_obj(sc.id)
        local g = a and ref(world.field(a, "ground_combat"))
        return (g ~= nil and world.object("ground_combat", g) ~= nil) == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- bombardment

    -- the fleets bombarding a planet (an `orbital_bombardment_order` on it) [I]
    local function bombarding(pid)
        local out = {}
        for _, fid in ipairs(world.all("fleet")) do
            local f = fleet_obj(fid)
            local cur = f and world.field(f, "current_order")
            local bo = type(cur) == "table" and world.field(cur, "orbital_bombardment_order")
            if type(bo) == "table" and ref(world.field(bo, "planet")) == pid then out[#out + 1] = fid end
        end
        return out
    end
    local function planet_id(sc)
        if sc == NONE then return nil end
        if sc.kind == "planet" then return sc.id end
        return nil
    end
    -- has_orbital_bombardment = yes/no (a planet): a fleet bombards it (COrbitalBombardmentTrigger
    -- 0x3bb9750: the carrier's bombarding fleet [V the call; I the field])
    TRIG["has_orbital_bombardment"] = function(e, ctx)
        local pid = planet_id(ctx.this)
        if not pid then return false end
        sync()
        return (#bombarding(pid) > 0) == yes(e)
    end
    -- has_orbital_bombardment_stance = <stance> (a planet): a fleet bombarding it with that stance
    -- (`ground_support_stance`... the fleet's `bombardment_stance`) [I]
    TRIG["has_orbital_bombardment_stance"] = function(e, ctx)
        local pid = planet_id(ctx.this)
        if not pid then return false end
        sync()
        local want = unq(e.value.text)
        for _, fid in ipairs(bombarding(pid)) do
            local f = fleet_obj(fid)
            if unq(world.field(f, "bombardment_stance")) == want then return true end
        end
        return false
    end

    -- -----------------------------------------------------------------------------------------
    -- distances

    -- an object's system coordinate { x, y, origin } (a fleet's, ship's, planet's, system's (its
    -- galactic position, origin none), starbase's station's, megastructure's)
    local function coord(sc)
        if not sc or sc == NONE then return nil end
        local o, c
        if sc.kind == "fleet" then
            o = fleet_obj(sc.id); c = o and world.path(o, "movement_manager", "coordinate")
        elseif sc.kind == "ship" then
            o = ship_obj(sc.id); c = o and world.field(o, "coordinate")
        elseif sc.kind == "planet" then
            o = world.object("planet", sc.id); c = o and world.field(o, "coordinate")
        elseif sc.kind == "system" then
            o = world.object("galactic_object", sc.id); c = o and world.field(o, "coordinate")
        elseif sc.kind == "megastructure" then
            o = world.object("megastructures", sc.id) or world.object("megastructure", sc.id)
            c = o and world.field(o, "coordinate")
        elseif sc.kind == "starbase" then
            local sb = world.object("starbases", sc.id)
            local st = sb and ref(world.field(sb, "station"))
            o = st and ship_obj(st); c = o and world.field(o, "coordinate")
        end
        if type(c) ~= "table" then return nil end
        return { x = num(world.field(c, "x")) or 0, y = num(world.field(c, "y")) or 0, origin = ref(world.field(c, "origin")) }
    end
    -- the system an object is in
    local function system_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "system" then return sc.id end
        local c = coord(sc)
        if c and c.origin then return c.origin end
        return R.system_of(sc.kind, sc.id)
    end
    -- compare_distance = { closer_object further_object } (an object): closer to the first than
    -- to the second, within one system (CCompareDistanceTrigger 0x3b658a0 [V the class]) [I]
    TRIG["compare_distance"] = function(e, ctx)
        if e.value.text then return false end
        sync()
        local p = F.params(e)
        local a, b = F.target_of(p.closer_object, ctx), F.target_of(p.further_object, ctx)
        local me, ca, cb = coord(ctx.this), coord(a), coord(b)
        if not (me and ca and cb) or ca.origin ~= me.origin or cb.origin ~= me.origin then return false end
        local da = (me.x - ca.x) ^ 2 + (me.y - ca.y) ^ 2
        local db = (me.x - cb.x) ^ 2 + (me.y - cb.y) ^ 2
        return da < db
    end
    -- the hyperlane jumps from a system to the nearest of a set (BFS), or nil
    local function jumps(from, targets)
        if not from then return nil end
        if targets[from] then return 0 end
        local seen, frontier, d = { [from] = true }, { from }, 0
        while #frontier > 0 and d < 1000 do
            d = d + 1
            local nxt = {}
            for _, s in ipairs(frontier) do
                for _, n in ipairs(R.hyperlanes(s)) do
                    if not seen[n] then
                        if targets[n] then return d end
                        seen[n] = true
                        nxt[#nxt + 1] = n
                    end
                end
            end
            frontier = nxt
        end
        return nil
    end
    local function galactic(sys)
        local g = world.object("galactic_object", sys)
        local c = g and world.field(g, "coordinate")
        if type(c) ~= "table" then return nil end
        return num(world.field(c, "x")) or 0, num(world.field(c, "y")) or 0
    end
    -- distance_to_capital (a planet, ship, system) <op> <jumps>: the jumps from its system to its
    -- owner's (the system's owner's) capital system [I]
    TRIG["distance_to_capital"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local sys = system_of(sc)
        local owner = sys and world.system_owner and world.system_owner[sys]
        if not owner and sc.kind == "planet" then owner = R.planet_owner(sc.id) end
        if not owner and sc.kind == "ship" then owner = F.fleet_owner(F.ship_fleet(sc.id) or -1) end
        local cap = owner and R.capital_system(owner)
        local d = cap and jumps(sys, { [cap] = true })
        return d ~= nil and cmp(d, e, ctx)
    end
    -- distance_to_core_percent (any object) <op> <pct>: its system's distance from the galaxy's
    -- centre over the farthest system's, x100 [I]
    local RIM
    TRIG["distance_to_core_percent"] = function(e, ctx)
        sync()
        local sys = system_of(ctx.this)
        if not sys and ctx.this ~= NONE and ctx.this.kind == "country" then sys = R.capital_system(ctx.this.id) end
        local x, y = sys and galactic(sys)
        if not x then return false end
        if not RIM then
            RIM = 0
            for _, s in ipairs(world.all("galactic_object")) do
                local sx, sy = galactic(s)
                if sx then RIM = math.max(RIM, math.sqrt(sx * sx + sy * sy)) end
            end
        end
        local pct = RIM > 0 and math.sqrt(x * x + y * y) / RIM * 100 or 0
        return cmp(pct, e, ctx)
    end
    -- distance_to_empire = { who distance use_bypasses type } (a planet, ship, fleet, system): the
    -- distance from its system to the nearest system the empire owns, hyperlane jumps or galactic
    -- (euclidean) units, at most `distance` [I]
    TRIG["distance_to_empire"] = function(e, ctx)
        if e.value.text then return false end
        sync()
        local p = F.params(e)
        local who = F.target_of(p.who, ctx)
        local sys = system_of(ctx.this)
        if not who or who.kind ~= "country" or not sys then return false end
        local max = p.distance and eval.value(p.distance.value, ctx, p.distance) or 0
        local owned = {}
        local any = false
        for s, o in pairs(world.system_owner or {}) do
            if o == who.id then owned[s] = true any = true end
        end
        if not any then return false end
        if p.type and unq(p.type.value.text) == "euclidean" then
            local x, y = galactic(sys)
            if not x then return false end
            local best
            for s in pairs(owned) do
                local sx, sy = galactic(s)
                if sx then
                    local d = math.sqrt((sx - x) ^ 2 + (sy - y) ^ 2)
                    if not best or d < best then best = d end
                end
            end
            return best ~= nil and best <= max
        end
        local d = jumps(sys, owned)
        return d ~= nil and d <= max
    end
    -- has_access_fleet = <country> (a system): the country may enter it: its own or unowned, or
    -- its owner gives the country access (not closed borders, not at war: engine.diplomacy) [I]
    TRIG["has_access_fleet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "system" then return false end
        local who = F.target_of(e, ctx)
        if not who or who.kind ~= "country" then return false end
        sync()
        local owner = world.system_owner and world.system_owner[sc.id]
        if not owner or owner == who.id then return true end
        local okd, d = pcall(require, "engine.diplomacy")
        if okd and d.at_war_with and d.at_war_with(owner, who.id) then return true end
        if okd and d.relation and d.rflag then
            local rel = d.relation(owner, who.id)
            if rel and d.rflag(rel, "closed_borders") then return false end
        end
        return true
    end
    -- hostile_military_power = { who safety_buffer value <op> n } (a system): the military power of
    -- the fleets there hostile to who (engine.fleets.combat's hostility), x ENEMY_FLEET_POWER_MULT
    -- with safety_buffer [I]
    TRIG["hostile_military_power"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "system" or e.value.text then return false end
        sync()
        local p = F.params(e)
        local who = F.target_of(p.who, ctx)
        if not who then return false end
        local okc, combat = pcall(require, "engine.fleets.combat")
        local total = 0
        for _, fid in ipairs(R.system_list(sc.id, "fleet_presence")) do
            local o = F.fleet_owner(fid)
            if o and okc and combat.hostile and combat.hostile(who.id, o) then
                local f = fleet_obj(fid)
                total = total + (f and num(world.field(f, "military_power")) or 0)
            end
        end
        if p.safety_buffer and yes(p.safety_buffer) then
            total = total * define("NAI", "ENEMY_FLEET_POWER_MULT", 1.2)
        end
        return F.block_value(e, ctx, total)
    end

    -- -----------------------------------------------------------------------------------------
    -- debris

    -- num_ships_in_debris = { ship_size value <op> n } (a debris): its ships of that size
    -- (`debris.ships = { { ship_size count } }` [I])
    local function debris_ships(sc, e)
        sync()
        local p = F.params(e)
        local want = p.ship_size and unq(p.ship_size.value.text)
        local d = world.object("debris", sc.id)
        local n = 0
        local l = d and world.field(d, "ships")
        for _, b in ipairs(type(l) == "table" and world.blocks(l) or {}) do
            if unq(world.field(b, "ship_size")) == want then n = n + (num(world.field(b, "count")) or 1) end
        end
        return n
    end
    TRIG["num_ships_in_debris"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "debris" or e.value.text then return false end
        return F.block_value(e, ctx, debris_ships(sc, e))
    end
    -- (as a value: the count, `parameters = { ship_size }`)
    TVAL["num_ships_in_debris"] = function(ctx, e)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "debris" or not e or e.value.text then return 0 end
        return debris_ships(sc, e)
    end

    -- -----------------------------------------------------------------------------------------
    -- citizenship and military service (pops, pop groups, leaders, species)

    -- the species a pop group, leader or species scope stands for
    local function species_of(sc)
        if sc == NONE then return nil end
        if sc.kind == "species" then return sc.id end
        if sc.kind == "pop_group" or sc.kind == "pop" then
            local g = world.object("pop_groups", sc.id)
            local k = g and world.field(g, "key")
            return type(k) == "table" and ref(world.field(k, "species")) or (g and ref(world.field(g, "species")))
        end
        if sc.kind == "leader" then
            local l = world.object("leaders", sc.id)
            return l and ref(world.field(l, "species"))
        end
        return nil
    end
    -- the country whose rights apply: a pop group's planet owner, a leader's country, else the
    -- species' home country (nil)
    local function rights_country(sc)
        if sc.kind == "pop_group" or sc.kind == "pop" then
            local g = world.object("pop_groups", sc.id)
            local pid = g and ref(world.field(g, "planet"))
            return pid and R.planet_owner(pid)
        elseif sc.kind == "leader" then
            local l = world.object("leaders", sc.id)
            return l and ref(world.field(l, "country"))
        end
        return nil
    end
    -- the country's species rights entry of a species (`species_rights`... the country's
    -- `policies`: the species' `citizenship` / `military_service` [I])
    local function rights(country, species, key)
        local c = country and world.object("country", country)
        local sr = c and world.field(c, "species_rights")
        for _, b in ipairs(type(sr) == "table" and world.blocks(sr) or {}) do
            if ref(world.field(b, "species")) == species then return unq(world.field(b, key)), b end
        end
        return nil
    end
    -- has_citizenship_rights = yes/no: the species has full citizenship (citizenship_full,
    -- _assimilation, _robot_full ... a type whose `rights = yes` [I])
    TRIG["has_citizenship_rights"] = function(e, ctx)
        local sc = ctx.this
        sync()
        local sp = species_of(sc)
        if not sp then return false end
        local country = rights_country(sc)
        local cit = rights(country, sp, "citizenship") or "citizenship_full"
        local d = defs().get("common/species_rights", cit)
        local has
        if d then
            local r = defs().field(d.block, "rights")
            has = r == nil and cit:find("full") ~= nil or r == "yes"
        else
            has = cit:find("full") ~= nil
        end
        return has == yes(e)
    end
    -- former_citizenship_type / former_military_service_type = <type> (a pop group): the type it had
    -- before the last change (`former_citizenship` / `former_military_service` [I])
    for name, key in pairs({ former_citizenship_type = "former_citizenship",
        former_military_service_type = "former_military_service" }) do
        TRIG[name] = function(e, ctx)
            local sc = ctx.this
            sync()
            local sp = species_of(sc)
            if not sp then return false end
            local _, b = rights(rights_country(sc), sp, (key:gsub("^former_", "")))
            return b ~= nil and unq(world.field(b, key)) == unq(e.value.text)
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- distance as a value (complex_trigger_modifier = { trigger = distance parameters = { source
    -- type same_solar_system } }): the number CDistanceTrigger compares (0x1964df0 [V the class]):
    -- with same_solar_system, the two objects' distance inside their system (none apart: 0 [I]);
    -- type = euclidean, the systems' galactic distance; else the hyperlane distance (the lanes'
    -- `length`, shortest path) [I]
    local function lane_distance(from, to)
        if from == to then return 0 end
        local dist, done = { [from] = 0 }, {}
        for _ = 1, 100000 do
            local best, bd
            for s, d in pairs(dist) do
                if not done[s] and (not bd or d < bd) then best, bd = s, d end
            end
            if not best then return nil end
            if best == to then return bd end
            done[best] = true
            local g = world.object("galactic_object", best)
            for _, h in ipairs(g and world.blocks(world.field(g, "hyperlane") or {}) or {}) do
                local t = ref(world.field(h, "to"))
                local len = num(world.field(h, "length")) or 0
                if t and not done[t] and (dist[t] == nil or bd + len < dist[t]) then dist[t] = bd + len end
            end
        end
        return nil
    end
    TVAL["distance"] = function(ctx, e)
        local sc = ctx.this
        if sc == NONE or not e or type(e.value) ~= "table" or e.value.text then return 0 end
        local p = F.params(e)
        local src = F.target_of(p.source, ctx)
        if not src then return 0 end
        sync()
        if p.same_solar_system and yes(p.same_solar_system) then
            local a, b = coord(sc), coord(src)
            if not a or not b or a.origin ~= b.origin then return 0 end
            return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        end
        local sa, sb = system_of(sc), system_of(src)
        if not sa or not sb then return 0 end
        if p.type and unq(p.type.value.text) == "euclidean" then
            local ax, ay = galactic(sa)
            local bx, by = galactic(sb)
            if not ax or not bx then return 0 end
            return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
        end
        return lane_distance(sa, sb) or 0
    end
end
