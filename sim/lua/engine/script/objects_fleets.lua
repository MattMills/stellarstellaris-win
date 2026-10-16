-- engine/script/objects_fleets.lua : fleets, ships and ship designs made by script (create_fleet,
-- create_ship, set_owner on a fleet, set_location, set_fleet_stance), over the constructors of
-- engine/fleets/create.lua, from the 4.5.2 Linux build (docs/script_objects.md "Fleets and ships").
--
-- Designs: `design = "NAME"` is a global design (common/global_ship_designs), made in the
-- ship_design store when first used (CShipDesignManager::GetOrCreateGlobalShipDesign);
-- `random_existing_design = <ship size>` picks among the country's designs with a growth stage of
-- that size (CCountry::FindRandomShipDesignFromSize: one draw) and, when it has none, makes one
-- (CCountry::CreateAndAddDefaultShipDesign). The game's ship designer behind the latter is not
-- ported: designs.default makes a design of the start's shape (the 2200.01.11 save's: the size's
-- section of the highest ai_weight, the best researched component of each required set, armor and
-- shields in the utility slots, the best researched weapon in the weapon slots) [I].

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")
local objects = require("engine.script.objects")
local create = require("engine.fleets.create")

local applied, skipped, unq, NO_ID = objects.applied, objects.skipped, objects.unq, objects.NO_ID

local fleets = {}
objects.fleets = fleets
local designs = {}
fleets.designs = designs

-- ---------------------------------------------------------------------------------------------
-- templates in the game's database order (the files in load order, then in each file)

local ordered_cache = {}
local function ordered(folder)
    local l = ordered_cache[folder]
    if l then return l end
    l = {}
    local ok, db = pcall(require, "simscript.db")
    local source = require("stellar.script.source")
    if ok and db and db.fs then
        for _, file in ipairs(source.files(db.fs, folder, "txt")) do
            local tree = source.parse(db.fs, file)
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.value.text == nil then
                    local b = e.value
                    if folder == "common/component_templates" or folder == "common/section_templates" then
                        local key = unq(defs.field(b, "key"))
                        if key then l[#l + 1] = { key = key, kind = e.key.text, block = b, file = file } end
                    else
                        l[#l + 1] = { key = e.key.text, kind = e.key.text, block = b, file = file }
                    end
                end
            end
        end
    end
    ordered_cache[folder] = l
    return l
end

local function names(block, key)
    local out = {}
    local l = block and defs.field(block, key)
    if type(l) == "table" then
        for _, e in ipairs(l) do
            if e.text then out[#out + 1] = unq(e.text) end
        end
    end
    return out
end

-- the country's technologies, as a set
local function techs(country)
    local c = world.object("country", country)
    local s = {}
    for _, t in ipairs(world.fields(c and world.field(c, "tech_status"), "technology")) do
        if type(t) == "string" then s[unq(t)] = true end
    end
    return s
end

local function researched(block, have)
    for _, t in ipairs(names(block, "prerequisites")) do
        if not have[t] then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- designs

local function collection(country)
    local c = world.object("country", country)
    if not c then return nil end
    local sdc = world.field(c, "ship_design_collection")
    if type(sdc) ~= "table" then sdc = world.child(c, "ship_design_collection") end
    local l = world.field(sdc, "ship_design")
    if type(l) ~= "table" then l = world.child(sdc, "ship_design") end
    return l
end

local function design_stages(did)
    local d = world.object("ship_design", did)
    local out = {}
    for _, gs in ipairs(world.blocks(d and world.field(d, "growth_stages"))) do
        out[#out + 1] = unq(world.field(gs, "ship_size"))
    end
    return out
end

-- CCountry::FindRandomShipDesignFromSize (0x2373280): every (design, stage) of the country's
-- ship_design_collection, in order, whose stage has the size; one draw of the game's generator
-- picks list[draw % n] when there is any; the stage is not kept (stage 0) [V]
function designs.find_random(country, size)
    local list = {}
    for _, x in ipairs(world.list(collection(country))) do
        local did = tonumber(x)
        for _, s in ipairs(design_stages(did)) do
            if s == size then list[#list + 1] = did end
        end
    end
    if #list == 0 then return nil end
    return list[objects.draw() % #list + 1]
end

-- the section of a size and slot: the highest ai_weight (weight, 1 without one), the first of
-- equals [I]
local function section_for(size, slot)
    local best, bw
    for _, t in ipairs(ordered("common/section_templates")) do
        if unq(defs.field(t.block, "ship_size")) == size and unq(defs.field(t.block, "fits_on_slot")) == slot then
            local aw = defs.field(t.block, "ai_weight")
            local w = type(aw) == "table" and tonumber(defs.field(aw, "weight")) or 1
            if not best or w > bw then best, bw = t, w end
        end
    end
    return best
end

-- the size family a required component goes with (the reactors' and combat computers' potential
-- triggers ship_uses_<family>_reactors etc., not evaluated): STARBASE_ for starbases, PLATFORM_ for
-- military stations, else the corvette's [I]
local FAMILIES = { "CORVETTE", "DESTROYER", "CRUISER", "BATTLESHIP", "TITAN", "COLOSSUS", "JUGGERNAUT",
    "STARBASE", "PLATFORM", "ION_CANNON", "FRIGATE", "FE_", "BIO", "MAULER", "WEAVER", "HARBINGER" }
local function family_of(size)
    if size:match("^starbase") then return "STARBASE" end
    if size:match("^military_station") then return "PLATFORM" end
    return "CORVETTE"
end
local function key_family(key)
    for _, f in ipairs(FAMILIES) do
        if key:find(f, 1, true) then return f end
    end
    return nil
end

-- the best researched component of a set for a size: the last researched one (the highest tier)
-- of the size's family, else of no family [I]
local function required_for(set, size, have)
    local fam = family_of(size)
    local pick, generic
    for _, c in ipairs(ordered("common/component_templates")) do
        if unq(defs.field(c.block, "component_set")) == set and researched(c.block, have) then
            local kf = key_family(c.key)
            if kf == fam then pick = c.key
            elseif kf == nil then generic = c.key end
        end
    end
    return pick or generic
end

-- the components of a weapon slot (its template's size: small_turret -> small): the first
-- researched weapon of that size with prerequisites (the start's mass drivers) [I]
local function weapon_for(slot_template, have)
    local sz = slot_template:match("^(%a+)_")
    for _, c in ipairs(ordered("common/component_templates")) do
        if c.kind == "weapon_component_template" and unq(defs.field(c.block, "size")) == sz
            and #names(c.block, "prerequisites") > 0 and researched(c.block, have) then
            return c.key
        end
    end
    return nil
end

local function utility(kind, size, have)
    local key = string.upper(size) .. "_" .. kind .. "_1"
    for _, c in ipairs(ordered("common/component_templates")) do
        if c.key == key then return researched(c.block, have) and key or nil end
    end
    return nil
end

-- designs.default(country, size) -> design id: CCountry::CreateAndAddDefaultShipDesign, the start's
-- design of a size (see the head of the file), in the country's collection
function designs.default(country, size)
    local sd = defs.get("common/ship_sizes", size)
    if not sd then return nil end
    local have = techs(country)
    local c = world.object("country", country)
    local gs = {}
    world.append(gs, "ship_size", size, true)
    local slots = defs.field(sd.block, "section_slots")
    for _, e in ipairs(type(slots) == "table" and slots or {}) do
        local slot = e.op and e.key and unq(e.key.text)
        local t = slot and section_for(size, slot)
        if t then
            local sec = {}
            world.append(sec, "template", t.key, true)
            world.append(sec, "slot", slot, true)
            for _, cs in ipairs(world.fields(t.block, "component_slot")) do
                if type(cs) == "table" then
                    local sname, stemp = unq(world.field(cs, "name")), unq(world.field(cs, "template"))
                    local w = stemp and weapon_for(stemp, have)
                    if sname and w then
                        local comp = {}
                        world.append(comp, "slot", sname, true)
                        world.append(comp, "template", w, true)
                        world.append(sec, "component", comp)
                    end
                end
            end
            for _, sz in ipairs({ "small", "medium", "large" }) do
                local n = tonumber(defs.field(t.block, sz .. "_utility_slots")) or 0
                for i = 1, n do
                    local which = (i == 2) and utility("SHIELD", sz, have) or nil
                    which = which or utility("ARMOR", sz, have)
                    if which then
                        local comp = {}
                        world.append(comp, "slot", string.upper(sz) .. "_UTILITY_" .. i, true)
                        world.append(comp, "template", which, true)
                        world.append(sec, "component", comp)
                    end
                end
            end
            local aux = tonumber(defs.field(t.block, "aux_utility_slots")) or 0
            for i = 1, aux do
                local which = "REACTOR_BOOSTER_1"
                local ok = false
                for _, x in ipairs(ordered("common/component_templates")) do
                    if x.key == which then ok = researched(x.block, have) break end
                end
                if ok then
                    local comp = {}
                    world.append(comp, "slot", "AUX_UTILITY_" .. i, true)
                    world.append(comp, "template", which, true)
                    world.append(sec, "component", comp)
                end
            end
            world.append(gs, "section", sec)
        end
    end
    for _, set in ipairs(world.fields(sd.block, "required_component_set")) do
        local key = type(set) == "string" and required_for(unq(set), size, have)
        if key then world.append(gs, "required_component", key, true) end
    end
    local d = {}
    local nm = {}
    world.append(nm, "key", "NAME_" .. size, true)
    world.append(d, "name", nm)
    world.append(d, "auto_gen_design", "yes")
    world.append(d, "upgrade_ship_components", "yes")
    local gc = c and world.field(c, "graphical_culture")
    if gc then world.append(d, "graphical_culture", unq(gc), true) end
    world.append(d, "growth_stages", { gs })
    local did = objects.create("ship_design", d)
    local l = collection(country)
    if l then world.append_value(l, did) end
    designs.made = (designs.made or 0) + 1
    return did
end

-- designs.global(name) -> design id: a design of common/global_ship_designs, made in the ship_design
-- store when first asked for (CShipDesignManager::GetOrCreateGlobalShipDesign) [V for the lookup;
-- the store form as the 2200.01.11 save's global designs: name, growth_stages]
local global_ids = {}
function designs.global(name)
    if global_ids[name] then return global_ids[name] end
    for _, did in ipairs(world.all("ship_design")) do
        local d = world.object("ship_design", did)
        local k = d and world.path(d, "name", "key")
        if k and unq(k) == name then
            global_ids[name] = did
            return did
        end
    end
    for _, t in ipairs(ordered("common/global_ship_designs")) do
        if t.kind == "ship_design" and unq(defs.field(t.block, "name")) == name then
            local d = {}
            local nm = {}
            world.append(nm, "key", name, true)
            world.append(d, "name", nm)
            for _, k in ipairs({ "is_special_buildable" }) do
                local v = defs.field(t.block, k)
                if v then world.append(d, k, v) end
            end
            local gs = {}
            for _, e in ipairs(t.block) do
                if e.op and e.key then
                    local k = e.key.text
                    if k == "ship_size" or k == "section" or k == "required_component" then
                        world.append(gs, k, e.value.text and unq(e.value.text) or e.value,
                            e.value.text and k ~= "ship_size" or (k == "ship_size"))
                    end
                end
            end
            world.append(d, "growth_stages", { gs })
            local did = objects.create("ship_design", d)
            global_ids[name] = did
            return did
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- fleets

-- CGameState::CreateNewFleet (0x1b46d90) and CCreateFleet::SetUpFleet (0x36e6340): no owner, the
-- name when one is given (an empty one is named by its first ship: CFleet::CreateName), the
-- settings mask when not the default (the save's `settings = { }` block) [V]
function systems.effects.create_fleet(t)
    local fid = create.fleet({ country = nil })
    if not fid then return skipped("create_fleet", "not made") end
    local f = world.object("fleet", fid)
    if t.name then
        world.insert(f, 1, "name", t.name)
    end
    if t.settings and #t.settings > 0 then
        local s = {}
        for _, kv in ipairs(t.settings) do world.append(s, kv[1], kv[2]) end
        world.append(f, "settings", s)
    end
    return applied("create_fleet", fid)
end

-- set_owner on a fleet (CSetOwnerEffect 0x36e0a80 -> CFleet::ChangeOwner(country, 0, 6)): the
-- country's owned fleet (owner and controller), no draws for a fleet that is not a station [V]
function systems.effects.set_fleet_owner(t)
    local f = world.object("fleet", t.id)
    if not f or not world.object("country", t.country) then return skipped("set_owner", "no fleet or country") end
    local old = world.fleet_owner[t.id]
    if old == t.country then return applied("set_owner") end
    if old then
        local c = world.object("country", old)
        local owned = c and world.path(c, "fleets_manager", "owned_fleets")
        for _, e in ipairs(type(owned) == "table" and owned or {}) do
            if not e.op and not e.text and tonumber(world.field(e, "fleet")) == t.id then
                world.remove_entry(owned, e)
                break
            end
        end
    end
    create.add_owned_fleet(t.country, t.id)
    return applied("set_owner")
end

-- create_ship: t = { fleet, design (id) | size (random_existing_design) | global (a name), name
-- ("random" | a name block | nil), prefix, stage } (CCreateShipEffect::ExecuteActual 0x36ed2a0) [V]:
-- the country is the fleet's controller; the ship made (CreateNewShip: its own name drawn), the
-- effect's name over it (random: drawn again; given; none: empty), added to the fleet (AddShip:
-- two draws and on_ship_enter_fleet), the first ship making the fleet civilian (evasive)
function systems.effects.create_ship(t)
    local fid = t.fleet
    local f = world.object("fleet", fid)
    if not f then return skipped("create_ship", "no fleet") end
    local country = world.fleet_owner[fid]
    -- a fleet without an owner (its owner a country the script did not make) gets no ship [I: the
    -- game makes it with the null country]
    if not country then return skipped("create_ship", "no owner") end
    local did
    if t.global then
        did = designs.global(t.global)
    elseif t.size and country then
        did = designs.find_random(country, t.size)
        if not did then
            -- NUtil::CanBuildShipOfSize then CreateAndAddDefaultShipDesign, and the pick again
            -- the AI's designer (engine.ai.designer, branch ai-fleets: CCountry::CreateShipDesign) when
            -- it is there, else the stand-in
            local ok, designer = pcall(require, "engine.ai.designer")
            local made
            if ok and type(designer) == "table" and designer.design_for then
                made = designer.design_for(country, t.size)
            else
                made = designs.default(country, t.size)
            end
            if made then did = designs.find_random(country, t.size) end
        end
    elseif t.design then
        did = t.design
    end
    if not did then return skipped("create_ship", "no design") end
    local stage = t.stage or 0
    local sid, info = create.ship({ country = country, design = did, stage = stage, fleet = fid,
        coordinate = nil })
    if not sid then return skipped("create_ship", "not made") end
    local s = world.object("ships", sid)
    -- the effect's own name
    if t.name == "random" then
        local name, key = create.ship_name(country, info)
        if t.prefix ~= false then
            local c = world.object("country", country)
            local prefix = c and world.field(c, "ship_prefix")
            if type(prefix) == "table" and world.field(prefix, "key") then
                local pb = {}
                world.append(pb, "key", "PREFIX_NAME_FORMAT", true)
                local vars = {}
                local v1 = {}
                world.append(v1, "key", "NAME", true)
                world.append(v1, "value", name)
                local v2 = {}
                world.append(v2, "key", "PREFIX", true)
                world.append(v2, "value", prefix)
                world.append(pb, "variables", { v1, v2 })
                name = pb
            end
        end
        create.add_ship_name(country, key)
        local e = world.token_entry(s, "name") or world.entry(s, "name")
        if e then world.set_entry(s, e, name) end
    elseif type(t.name) == "table" then
        local e = world.entry(s, "name")
        if e then world.set_entry(s, e, t.name) end
    elseif t.name == nil and t.unnamed then
        local e = world.entry(s, "name")
        if e then world.remove_entry(s, e) end
    end
    -- the fleet's place: the ship at the fleet's coordinate (CFleet::AddShip -> ResetToCoordinate)
    local mmc = world.path(f, "movement_manager", "coordinate")
    if type(mmc) == "table" then
        for _, k in ipairs({ "coordinate", "target_coordinate" }) do
            local sc = world.field(s, k)
            if type(sc) == "table" then
                for _, kk in ipairs({ "x", "y", "origin" }) do
                    local v = world.field(mmc, kk)
                    if v ~= nil then world.set(sc, kk, v) end
                end
            end
        end
    end
    create.add_ship(fid, sid)
    -- the first ship: CFleet::SetIsCivilian (properties civilian, stance evasive)
    if #world.list(world.field(f, "ships")) == 1 and info and info.civilian then
        local props = world.field(f, "properties")
        if type(props) == "table" and world.field(props, "civilian") == nil then
            world.insert(props, 1, "civilian", "yes")
        end
        world.set(f, "fleet_stance", "evasive")
    end
    return applied("create_ship", sid)
end

-- set_fleet_stance (CSetFleetStanceEffect 0x37689a0 -> CFleet::SupportsFleetStance): evasive not
-- for a military fleet, aggressive not for a civilian one, an immobile fleet only passive [V]
function systems.effects.set_fleet_stance(t)
    local f = world.object("fleet", t.id)
    if not f then return skipped("set_fleet_stance", "no fleet") end
    local props = world.field(f, "properties")
    local civilian = type(props) == "table" and world.field(props, "civilian") == "yes"
    local mobile = type(props) == "table" and world.field(props, "mobile") == "yes"
    local class = unq(world.field(f, "ship_class")) or "shipclass_military"
    if not mobile and t.stance ~= "passive" then return skipped("set_fleet_stance", "immobile") end
    if t.stance == "evasive" and class == "shipclass_military" then return skipped("set_fleet_stance", "military") end
    if t.stance == "aggressive" and civilian then return skipped("set_fleet_stance", "civilian") end
    world.set(f, "fleet_stance", t.stance)
    return applied("set_fleet_stance")
end

-- set_location of a fleet: t = { id (fleet), target = { kind, id }, distance, angle, random_angle,
-- direction } (CSetLocationEffect::ExecuteActual 0x36eb4e0) [V]:
--   Path A (a planet target, no distance/angle/direction): CPlanet::EnterOrbit with teleport, the
--     formation angle the angle to the planet; OnEnteredOrbit's three draws;
--   Path B: the target's place moved by distance at the angle (random: one draw, (r % 100000) /
--     1e5 x 360 degrees), the fleet teleported there;
--   both: CGalacticObject::MakeContactOnFleetEntered, two draws, on_entering_system_fleet (this =
--   the fleet, from = the system).
local R = require("engine.script.runtime")
function systems.effects.set_location(t)
    local f = world.object("fleet", t.id)
    if not f then return skipped("set_location", "not a fleet") end
    local tk, tid = t.target.kind, t.target.id
    local sys = R.system_of(tk, tid)
    if not sys then return skipped("set_location", "no system") end
    local P = require("engine.fleets.path")
    if tk == "planet" and not t.distance and not t.angle and not t.random_angle and not t.direction then
        local slot, at = create.enter_orbit(t.id, "planet", tid)
        if at then
            local p = world.object("planet", tid)
            local pc = p and world.field(p, "coordinate")
            local px = pc and tonumber(world.field(pc, "x")) or 0
            local py = pc and tonumber(world.field(pc, "y")) or 0
            local formation = world.path(f, "movement_manager", "formation")
            if type(formation) == "table" then
                local a = math.atan2(-(px * 100000 - at.x), py * 100000 - at.y)
                world.set(formation, "angle", P.text(math.floor(a * 100000 + 0.5)))
            end
        end
    else
        local o = world.object(tk, tid)
        local c = o and world.field(o, "coordinate")
        local x = c and tonumber(world.field(c, "x")) or 0
        local y = c and tonumber(world.field(c, "y")) or 0
        local deg = t.angle or 0
        if t.random_angle then
            deg = (objects.draw() % 100000) / 100000 * 360
        elseif t.direction then
            local star = R.star_planet and R.star_planet(sys)
            local sp = star and world.object("planet", star)
            local sc = sp and world.field(sp, "coordinate")
            local sx = sc and tonumber(world.field(sc, "x")) or 0
            local sy = sc and tonumber(world.field(sc, "y")) or 0
            deg = math.deg(math.atan2(sy - y, sx - x)) + (t.angle or 0) + (t.direction == "in_system" and 180 or 0)
        end
        local a = math.rad(deg)
        local d = t.distance or 0
        y = y - d * math.sin(a)
        x = x - d * math.cos(a)
        local mm = world.field(f, "movement_manager")
        local mc = type(mm) == "table" and world.field(mm, "coordinate")
        if type(mc) == "table" then
            world.set(mc, "x", x)
            world.set(mc, "y", y)
            world.set(mc, "origin", sys)
        end
        local formation = type(mm) == "table" and world.field(mm, "formation")
        if type(formation) == "table" then world.set(formation, "angle", P.text(math.floor(a * 100000 + 0.5))) end
        local g = world.object("galactic_object", sys)
        if g then world.append_value(objects.list_of(g, "fleet_presence"), t.id) end
    end
    -- the fleet's ships at its place
    local mc = world.path(f, "movement_manager", "coordinate")
    for _, x in ipairs(world.list(world.field(f, "ships"))) do
        local s = world.object("ships", tonumber(x))
        for _, k in ipairs({ "coordinate", "target_coordinate" }) do
            local sc = s and world.field(s, k)
            if type(sc) == "table" and type(mc) == "table" then
                for _, kk in ipairs({ "x", "y", "origin" }) do
                    local v = world.field(mc, kk)
                    if v ~= nil then world.set(sc, kk, v) end
                end
            end
        end
    end
    local cc = world.path(f, "combat", "coordinate")
    if type(cc) == "table" then world.set(cc, "origin", sys) end
    objects.draw()
    objects.draw()
    local eval = package.loaded["simscript.eval"]
    if eval then objects.on_action("on_entering_system_fleet", eval.S("fleet", t.id), eval.S("system", sys)) end
    return applied("set_location")
end

return fleets
