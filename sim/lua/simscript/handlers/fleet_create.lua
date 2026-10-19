-- simscript/handlers/fleet_create.lua : the fleet package's effects that make or change fleets,
-- ships, armies and designs (loaded by handlers/fleet.lua with its helpers F). Fleets and ships are
-- made through the objects module's engine effects (create_fleet, create_ship, set_fleet_owner:
-- engine/script/objects_fleets.lua), armies and designs through engine/fleets/script.lua; each sets
-- the last_created_* it makes. [I] unless marked.

return function(eval, F)
    local I = eval._internal
    local EFF = eval.EFF
    local S, NONE, sync = I.S, I.NONE, I.sync
    local E = I.E
    local world = require("engine.world")
    local R = F.R
    local num, ref, unq, yes = F.num, F.ref, F.unq, F.yes
    local O = eval.objects
    require("engine.fleets.script")

    local function push(t)
        if O and O.push then O.push(t) else E.push(t) end
    end
    local function created(ctx, kind, h)
        if O and O.created then O.created(ctx, kind, h) else ctx.created[kind] = h end
    end
    local function text_of(x) return x and x.value and x.value.text and unq(x.value.text) or nil end

    -- -----------------------------------------------------------------------------------------
    -- designs

    local function size_class(size)
        return size and R.ship_size_field(size, "class")
    end
    local function design_size(did, stage)
        local d = F.design_obj(did)
        local gs = d and world.field(d, "growth_stages")
        local b = type(gs) == "table" and world.blocks(gs)[(stage or 0) + 1]
        return b and unq(world.field(b, "ship_size"))
    end
    local function size_mult(size)
        return size and tonumber(R.ship_size_field(size, "size_multiplier")) or 1
    end
    -- a design named by a key, a target or last_created_design: its id
    local function design_of(x, ctx)
        if not x then return nil end
        local t = x.value.text
        if not t then return nil end
        local found, sc = eval.resolve(t, ctx, x)
        if found then return sc and sc ~= NONE and F.is_design(sc) and sc.id or nil end
        local fleets = require("engine.script.objects").fleets
        return fleets and fleets.designs.global(unq(t)) or nil
    end
    -- the country's military designs (their first stage a designable military size)
    local function military_designs(country)
        local out = {}
        for _, did in ipairs(F.owned_designs(country)) do
            local size = design_size(did, 0)
            if size_class(size) == "shipclass_military" then out[#out + 1] = did end
        end
        return out
    end
    local function collection(country)
        local c = world.object("country", country)
        if not c then return nil end
        local col = world.field(c, "ship_design_collection")
        if type(col) ~= "table" then
            world.append(c, "ship_design_collection", {})
            col = world.field(c, "ship_design_collection")
        end
        local l = world.field(col, "ship_design")
        if type(l) ~= "table" then
            world.append(col, "ship_design", {})
            l = world.field(col, "ship_design")
        end
        return l
    end

    -- create_ship_design = { design ftl } (any scope): a new design, a copy of the global design,
    -- for last_created_design (CCreateShipDesignEffect: the ftl's country's drive, not modelled)
    EFF["create_ship_design"] = function(e, ctx)
        if e.value.text then return end
        local p = F.params(e)
        local name = text_of(p.design)
        if not name then return end
        local h = E.new_handle()
        created(ctx, "design", h)
        push({ type = "create_ship_design", design = name, handle = h })
        sync()
    end
    -- add_ship_design / remove_ship_design = <design> (a country): its collection gains / loses it
    EFF["add_ship_design"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return end
        sync()
        local did = design_of(e, ctx)
        local l = did and collection(sc.id)
        if not l then return end
        for _, x in ipairs(F.id_list(l)) do if x == did then return end end
        world.append_value(l, did)
        F.effect_stats.applied = F.effect_stats.applied + 1
    end
    EFF["remove_ship_design"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return end
        sync()
        local did = design_of(e, ctx)
        local l = did and collection(sc.id)
        if l then world.remove_value(l, did) F.effect_stats.applied = F.effect_stats.applied + 1 end
    end
    -- add_global_ship_design / remove_global_ship_design = <design> (any scope): the game's global
    -- designs (`ship_designs.global_ship_design = { { name ship_design } }`)
    local function globals()
        local sd = world.meta and world.meta.ship_designs
        if type(sd) ~= "table" then
            world.meta.ship_designs = {}
            sd = world.meta.ship_designs
        end
        local g = world.field(sd, "global_ship_design")
        if type(g) ~= "table" then
            world.append(sd, "global_ship_design", {})
            g = world.field(sd, "global_ship_design")
        end
        return g
    end
    EFF["add_global_ship_design"] = function(e, ctx)
        sync()
        local did = design_of(e, ctx)
        if not did then return end
        local g = globals()
        for _, b in ipairs(world.blocks(g)) do
            if ref(world.field(b, "ship_design")) == did then return end
        end
        local b = {}
        local d = F.design_obj(did)
        local n = d and world.field(d, "name")
        if type(n) == "table" then world.append(b, "name", n) end
        world.append(b, "ship_design", did)
        world.push(g, b)
        F.effect_stats.applied = F.effect_stats.applied + 1
    end
    EFF["remove_global_ship_design"] = function(e, ctx)
        sync()
        local did = design_of(e, ctx)
        if not did then return end
        local g = globals()
        for _, b in ipairs(world.blocks(g)) do
            if ref(world.field(b, "ship_design")) == did then
                for i, x in ipairs(g) do
                    if x == b or x.value == b then table.remove(g, i) break end
                end
                F.effect_stats.applied = F.effect_stats.applied + 1
                return
            end
        end
    end
    -- set_ship_design = { design random_existing_design } (a ship, a fleet: each ship): the ship's
    -- design changed (its hit points the new design's)
    EFF["set_ship_design"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local p = F.params(e)
        local did = design_of(p.design, ctx)
        if not did and p.random_existing_design then
            local fid = F.fleet_of(ctx.this)
            local owner = fid and F.fleet_owner(fid)
            local fleets = require("engine.script.objects").fleets
            did = owner and fleets and fleets.designs.find_random(owner, text_of(p.random_existing_design)) or nil
        end
        if not did then return end
        local create = require("engine.fleets.create")
        for _, sid in ipairs(F.ships_of(ctx.this)) do
            local s = F.ship_obj(sid)
            local sdi = s and world.field(s, "ship_design_implementation")
            if type(sdi) == "table" then
                world.set(sdi, "design", did)
                world.set(sdi, "upgrade", F.NO_ID)
                world.set(sdi, "growth_stage", 0)
                local owner = F.fleet_owner(F.ship_fleet(sid) or -1)
                if create.hit_points then
                    local hull, armor, shield = create.hit_points(owner, did, 0)
                    if hull then
                        for k, v in pairs({ hitpoints = hull, max_hitpoints = hull, armor_hitpoints = armor,
                            max_armor_hitpoints = armor, shield_hitpoints = shield, max_shield_hitpoints = shield }) do
                            world.set(s, k, string.format("%.5f", v or 0))
                        end
                    end
                end
                F.effect_stats.applied = F.effect_stats.applied + 1
            end
        end
    end
    -- set_auto_upgrade_components = yes/no (a design): `upgrade_ship_components`
    EFF["set_auto_upgrade_components"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or not F.is_design(sc) then return end
        sync()
        local d = F.design_obj(sc.id)
        if d then
            world.set(d, "upgrade_ship_components", yes(e) and "yes" or "no")
            F.effect_stats.applied = F.effect_stats.applied + 1
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- fleets

    -- a fleet made with ships of the designs (owner set first, then the ships), its effect run in
    -- its scope (this = the fleet): the fleet's id
    local function make_fleet(ctx, owner, name, design_ids, effect)
        local h = E.new_handle()
        created(ctx, "fleet", h)
        local nb
        if name and name ~= "" then
            nb = {}
            world.append(nb, "key", name, true)
        end
        push({ type = "create_fleet", name = nb, handle = h })
        sync()
        local fid = E.resolve(h)
        if not fid then return nil end
        if owner then push({ type = "set_fleet_owner", id = fid, country = owner }) end
        for _, did in ipairs(design_ids) do
            local hs = E.new_handle()
            created(ctx, "ship", hs)
            push({ type = "create_ship", fleet = fid, design = did, handle = hs, name = "random" })
        end
        sync()
        F.effect_stats.applied = F.effect_stats.applied + 1
        if effect and effect.value.text == nil and #effect.value > 0 then
            local c2 = I.push(ctx, S("fleet", fid))
            if eval.scope_draw and eval.seed_scope then eval.seed_scope(c2, eval.scope_draw(ctx)) end
            eval.effect(effect.value, c2)
        end
        return fid
    end
    -- the designs listed by `ship_designs = { NAME | { design weight min max } }`, else nil
    local function listed_designs(p, ctx)
        local x = p.ship_designs
        if not x or x.value.text then return nil end
        local out = {}
        for _, it in ipairs(x.value) do
            if it.text then
                local did = design_of({ value = { text = it.text } }, ctx)
                if did then out[#out + 1] = { did = did, weight = 1 } end
            elseif it.value and it.value.text == nil and not it.key then
                local q = F.params({ value = it.value })
                local did = design_of(q.design, ctx)
                if did then
                    out[#out + 1] = { did = did, weight = q.weight and eval.value(q.weight.value, ctx, q.weight) or 1,
                        min = q.min and eval.value(q.min.value, ctx, q.min) or 0,
                        max = q.max and eval.value(q.max.value, ctx, q.max) or nil }
                end
            elseif it.op and it.key then
                local did = design_of({ value = { text = it.key.text } }, ctx)
                if did then out[#out + 1] = { did = did, weight = 1 } end
            end
        end
        return out
    end
    -- the AI's fraction of a design's size (ship_sizes' `ai_ship_data.fraction.base`, 1 without)
    local function fraction_of(did)
        local size = design_size(did, 0)
        local d = size and require("engine.defs").get("common/ship_sizes", size)
        local ai = d and require("engine.defs").field(d.block, "ai_ship_data")
        local fr = type(ai) == "table" and require("engine.defs").field(ai, "fraction")
        local v = type(fr) == "table" and tonumber(require("engine.defs").field(fr, "base")) or tonumber(fr)
        return v or 1
    end
    -- ships chosen deterministically: each next ship the design furthest under its share of the
    -- naval size so far, until `size` (naval cap) is reached (or passed, with can_overflow)
    local function balanced(entries, size, overflow)
        local out, used, count = {}, 0, {}
        local total = 0
        for _, en in ipairs(entries) do total = total + en.weight end
        if total <= 0 or #entries == 0 then return out end
        for _ = 1, 1000 do
            if used >= size then break end
            local best, bd
            for i, en in ipairs(entries) do
                local want = en.weight / total * (#out + 1)
                local d = want - (count[i] or 0)
                if not bd or d > bd then best, bd = i, d end
            end
            local en = entries[best]
            local m = size_mult(design_size(en.did, 0))
            if used + m > size and not overflow then break end
            out[#out + 1] = en.did
            count[best] = (count[best] or 0) + 1
            used = used + m
        end
        return out
    end
    local function defaults(country)
        local out = {}
        for _, did in ipairs(military_designs(country)) do out[#out + 1] = { did = did, weight = fraction_of(did) } end
        return out
    end
    -- create_balanced_fleet = { name size can_overflow ship_designs effect } (a country)
    EFF["create_balanced_fleet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or e.value.text then return end
        sync()
        local p = F.params(e)
        local size = p.size and eval.value(p.size.value, ctx, p.size) or 0
        local entries = listed_designs(p, ctx) or defaults(sc.id)
        for _, en in ipairs(entries) do if not p.ship_designs then en.weight = fraction_of(en.did) end end
        local overflow = not p.can_overflow or yes(p.can_overflow)
        make_fleet(ctx, nil, text_of(p.name), balanced(entries, size, overflow), p.effect)
    end
    -- create_random_fleet = { name size can_overflow ship_designs = { NAME | { design weight min max } }
    -- effect } (a country): each entry's min first, then picks weighted at random (one scope draw
    -- each) within the max, until size
    EFF["create_random_fleet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" or e.value.text then return end
        sync()
        local p = F.params(e)
        local size = p.size and eval.value(p.size.value, ctx, p.size) or 0
        local entries = listed_designs(p, ctx) or defaults(sc.id)
        local overflow = not p.can_overflow or yes(p.can_overflow)
        local out, used, count = {}, 0, {}
        for i, en in ipairs(entries) do
            for _ = 1, math.floor(en.min or 0) do
                out[#out + 1] = en.did
                count[i] = (count[i] or 0) + 1
                used = used + size_mult(design_size(en.did, 0))
            end
        end
        for _ = 1, 1000 do
            if used >= size then break end
            local total, live = 0, {}
            for i, en in ipairs(entries) do
                if not en.max or (count[i] or 0) < en.max then
                    live[#live + 1] = i
                    total = total + en.weight
                end
            end
            if total <= 0 then break end
            local draw = eval.scope_draw and eval.scope_draw(ctx) or RUST.rand()
            local r = (draw % 1000000) / 1000000 * total
            local pick = live[#live]
            for _, i in ipairs(live) do
                if r < entries[i].weight then pick = i break end
                r = r - entries[i].weight
            end
            local m = size_mult(design_size(entries[pick].did, 0))
            if used + m > size and not overflow then break end
            out[#out + 1] = entries[pick].did
            count[pick] = (count[pick] or 0) + 1
            used = used + m
        end
        make_fleet(ctx, nil, text_of(p.name), out, p.effect)
    end
    -- create_fleet_from_naval_cap = <fraction> | { fraction can_overflow ship_owner_type } (a
    -- country): a fleet of its military designs, balanced, of that fraction of its naval capacity,
    -- owned by it
    EFF["create_fleet_from_naval_cap"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return end
        sync()
        local frac, overflow = 0, true
        if e.value.text then
            frac = eval.value(e.value, ctx, e)
        else
            local p = F.params(e)
            frac = p.fraction and eval.value(p.fraction.value, ctx, p.fraction) or 0
            overflow = not p.can_overflow or yes(p.can_overflow)
        end
        local okn, navy = pcall(require, "engine.ai.navy")
        local cap = okn and navy.naval_capacity and navy.naval_capacity(sc.id) or 0
        make_fleet(ctx, sc.id, nil, balanced(defaults(sc.id), cap * frac, overflow), nil)
    end
    -- create_military_fleet = { owner scaled_size effect } (any scope): a fleet of the owner's
    -- military designs, balanced, scaled_size x its naval capacity's tenth [I], owned by it
    EFF["create_military_fleet"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local p = F.params(e)
        local owner = F.target_of(p.owner, ctx)
        if not owner or owner.kind ~= "country" then return end
        local scale = p.scaled_size and eval.value(p.scaled_size.value, ctx, p.scaled_size) or 1
        local okn, navy = pcall(require, "engine.ai.navy")
        local cap = okn and navy.naval_capacity and navy.naval_capacity(owner.id) or 0
        make_fleet(ctx, owner.id, nil, balanced(defaults(owner.id), math.max(1, cap * 0.1 * scale), true), p.effect)
    end
    -- create_smaller_size_creature_in_fleet = <count> | { count effect } (a ship): ships of the
    -- next smaller size of the creature's family (the size whose `next_size`... the ship size the
    -- design's stage grows from: the previous growth stage) in its fleet [I]
    EFF["create_smaller_size_creature_in_fleet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "ship" then return end
        sync()
        local n, effect = 1, nil
        if e.value.text then n = eval.value(e.value, ctx, e)
        else
            local p = F.params(e)
            n = p.count and eval.value(p.count.value, ctx, p.count) or 1
            effect = p.effect
        end
        local s = F.ship_obj(sc.id)
        local sdi = s and world.field(s, "ship_design_implementation")
        local did = type(sdi) == "table" and ref(world.field(sdi, "design"))
        local stage = type(sdi) == "table" and num(world.field(sdi, "growth_stage")) or 0
        local fid = F.ship_fleet(sc.id)
        if not did or not fid or stage < 1 then return end
        for _ = 1, math.floor(n) do
            local hs = E.new_handle()
            created(ctx, "ship", hs)
            push({ type = "create_ship", fleet = fid, design = did, stage = stage - 1, handle = hs, name = "random" })
            sync()
            local sid = E.resolve(hs)
            F.effect_stats.applied = F.effect_stats.applied + 1
            if sid and effect and effect.value.text == nil then eval.effect(effect.value, I.push(ctx, S("ship", sid))) end
        end
    end
    -- reanimate_space_fauna = { fleet } (a ship, a debris): the fauna ship (the debris' ships)
    -- brought back as ships of the reanimated size in the fleet [I: a copy of the design in the
    -- given fleet, full hit points]
    EFF["reanimate_space_fauna"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or e.value.text then return end
        sync()
        local p = F.params(e)
        local t = F.target_of(p.fleet, ctx)
        if not t or t.kind ~= "fleet" then return end
        local dids = {}
        if sc.kind == "ship" then
            local s = F.ship_obj(sc.id)
            local d = s and ref(world.path(s, "ship_design_implementation", "design"))
            if d then dids[1] = d end
        end
        for _, did in ipairs(dids) do
            local hs = E.new_handle()
            created(ctx, "ship", hs)
            push({ type = "create_ship", fleet = t.id, design = did, handle = hs, name = "random" })
        end
        sync()
        if #dids > 0 then F.effect_stats.applied = F.effect_stats.applied + 1 end
    end
    -- transfer_galactic_defense_force_fleets = <country> (a country): its GDF fleets (owned fleets
    -- of galactic_community designs) given to the target
    EFF["transfer_galactic_defense_force_fleets"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return end
        local t = F.target_of(e, ctx)
        if not t or t.kind ~= "country" then return end
        sync()
        for _, fid in ipairs(R.owned_fleets(sc.id)) do
            local f = F.fleet_obj(fid)
            if f and unq(world.field(f, "ship_owner_type")) == "galactic_community" then
                push({ type = "set_fleet_owner", id = fid, country = t.id })
            end
        end
        sync()
    end
    -- delete_dimensional_fleet = <fleet> | { target } (any scope): the dimensional fleet removed [I]
    EFF["delete_dimensional_fleet"] = function(e, ctx)
        local t = e.value.text and F.target_of(e, ctx) or F.target_of(F.params(e).target, ctx)
        if not t or t.kind ~= "fleet" then return end
        sync()
        if F.fleet_obj(t.id) then
            require("engine.fleets.destroy").fleet(t.id)
            F.effect_stats.applied = F.effect_stats.applied + 1
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- armies

    -- the species of `species = <target> | random`: the target's, else the owner's founder
    local function species_of(x, ctx, owner)
        local t = x and F.target_of(x, ctx)
        if t then
            if t.kind == "species" then return t.id end
            if t.kind == "country" then
                local c = world.object("country", t.id)
                return c and ref(world.field(c, "founder_species_ref"))
            end
            local o = world.object(t.kind == "pop_group" and "pop_groups" or t.kind, t.id)
            local k = o and world.field(o, "key")
            return type(k) == "table" and ref(world.field(k, "species")) or (o and ref(world.field(o, "species")))
        end
        local c = owner and world.object("country", owner)
        return c and ref(world.field(c, "founder_species_ref"))
    end
    -- create_army = { name owner species type } (a planet or ship colony): an army on its colony
    EFF["create_army"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local cid = F.colony_of(ctx.this)
        if not cid then return end
        local p = F.params(e)
        local owner = F.target_of(p.owner, ctx)
        local oid = owner and owner.kind == "country" and owner.id or nil
        local h = E.new_handle()
        created(ctx, "army", h)
        push({ type = "create_army", colony = cid, owner = oid, species = species_of(p.species, ctx, oid),
            army_type = text_of(p.type), name = text_of(p.name), handle = h })
        sync()
    end
    -- create_army_transport = { ship_name graphical_culture army_name army_type species } (a
    -- fleet): a transport ship in the fleet carrying a new army
    EFF["create_army_transport"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" or e.value.text then return end
        sync()
        local p = F.params(e)
        local owner = F.fleet_owner(sc.id)
        local fleets = require("engine.script.objects").fleets
        local did = owner and fleets and fleets.designs.find_random(owner, "transport") or nil
        local hs = E.new_handle()
        created(ctx, "ship", hs)
        local nb
        local sn = text_of(p.ship_name)
        if sn then nb = {} world.append(nb, "key", sn, true) end
        push({ type = "create_ship", fleet = sc.id, design = did, size = not did and "transport" or nil,
            handle = hs, name = nb or "random" })
        sync()
        local sid = E.resolve(hs)
        if not sid then return end
        local h = E.new_handle()
        created(ctx, "army", h)
        push({ type = "create_army", ship = sid, owner = owner, species = species_of(p.species, ctx, owner),
            army_type = text_of(p.army_type), name = text_of(p.army_name), handle = h })
        sync()
    end
    -- modify_army = { name owner species type } (an army): its fields changed (the owner's army
    -- lists moved)
    EFF["modify_army"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "army" or e.value.text then return end
        sync()
        local a = F.army_obj(sc.id)
        if not a then return end
        local p = F.params(e)
        local n = text_of(p.name)
        if n then
            local nb = {}
            world.append(nb, "key", n, true)
            local x = world.entry(a, "name")
            if x then world.remove_entry(a, x) end
            world.append(a, "name", nb)
        end
        local ty = text_of(p.type)
        if ty then world.set(a, "type", ty, true) end
        local owner = F.target_of(p.owner, ctx)
        if owner and owner.kind == "country" then
            local old = ref(world.field(a, "owner"))
            if old ~= owner.id then
                local oc = old and world.object("country", old)
                local l = oc and world.field(oc, "owned_armies")
                if type(l) == "table" then world.remove_value(l, sc.id) end
                local nc = world.object("country", owner.id)
                local nl = nc and world.field(nc, "owned_armies")
                if nc and type(nl) ~= "table" then world.append(nc, "owned_armies", {}) nl = world.field(nc, "owned_armies") end
                if type(nl) == "table" then world.append_value(nl, sc.id) end
                world.set(a, "owner", owner.id)
            end
        end
        if p.species then
            local sp = species_of(p.species, ctx, ref(world.field(a, "owner")))
            if sp then world.set(a, "species", sp) end
        end
        F.effect_stats.applied = F.effect_stats.applied + 1
    end
end
