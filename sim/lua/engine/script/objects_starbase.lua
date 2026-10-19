-- engine/script/objects_starbase.lua : the engine side of the starbase package's effects
-- (simscript/handlers/starbase.lua queues them): starbase modules, buildings, components and size;
-- megastructures (removal, upgrades, overclocks, halts, links, bypass creation), bypasses
-- (gateways, locks), hyperlanes, asteroid belts, star classes, ambient objects, sectors, psionic
-- auras, the AI's starbase design overrides, closed borders. Each applier writes the world in the
-- save's own form (the 2210.01.01 save's: [V] where the save shows the field, [I] where the field
-- is inferred from the documentation).

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")
local objects = require("engine.script.objects")

local applied, skipped, unq, NO_ID, ref = objects.applied, objects.skipped, objects.unq, objects.NO_ID, objects.ref

local sb = {}
objects.starbase = sb

local function obj(kind, id)
    return id ~= nil and world.object(kind, id) or nil
end
local function today()
    return require("engine.diplomacy").today() or 0
end
-- `key = "text"`: a quoted string (the parser keeps the text without its quotes, quoted = true)
local function set_quoted(o, key, text)
    world.set(o, key, text)
    local t = world.token_entry(o, key)
    if t then t.value.quoted = true end
end
local function remove_field(o, key)
    local e = world.token_entry(o, key)
    if e then world.remove_entry(o, e) end
    local b = world.entry and world.entry(o, key)
    if b and b.value and b.value.text == nil then world.remove_entry(o, b) end
end
-- a list block's values: add one (once), take one out
local function list_add(o, key, v, quoted)
    local l = objects.list_of(o, key)
    for _, x in ipairs(l) do
        if x.text and unq(x.text) == tostring(v) then return false end
    end
    world.append_value(l, v, quoted)
    return true
end
local function list_del(o, key, v)
    local l = o and world.field(o, key)
    if type(l) ~= "table" then return false end
    local n = #l
    for i = #l, 1, -1 do
        if l[i].text and unq(l[i].text) == tostring(v) then world.remove_entry(l, l[i]) end
    end
    return #l < n
end
local function set_list(o, key, values)
    local l = objects.list_of(o, key)
    local entries = {}
    for i, v in ipairs(values) do entries[i] = { text = tostring(v) } end
    world.replace(l, entries)
end
local function system_of_coord(o)
    local c = o and world.field(o, "coordinate")
    return type(c) == "table" and ref(world.field(c, "origin")) or nil
end

-- ---------------------------------------------------------------------------------------------
-- starbases: `modules = { 0 = shipyard 1 = ... }`, `buildings = { 0 = crew_quarters }` keyed by
-- slot (the script's slot is 1-indexed: the save's key is slot - 1 [V: vanilla's slot = 1 places
-- the first]), `level = "starbase_level_starport"` [V]; standalone components [I]

local function items_block(s, kind)
    return objects.list_of(s, kind == "module" and "modules" or "buildings")
end
-- set_starbase_module / set_starbase_building = { slot item }
function systems.effects.set_starbase_item(t)
    local s = obj("starbase", t.id)
    if not s then return skipped("set_starbase_" .. t.kind, "no starbase") end
    local slot = tonumber(t.slot)
    if not slot or slot < 1 then return skipped("set_starbase_" .. t.kind, "no slot") end
    local folder = t.kind == "module" and "common/starbase_modules" or "common/starbase_buildings"
    if not defs.get(folder, t.item) then return skipped("set_starbase_" .. t.kind, "unknown " .. t.kind) end
    local b = items_block(s, t.kind)
    local key = tostring(slot - 1)
    for _, e in ipairs(b) do
        if e.op and e.key and e.key.text == key then
            world.set_entry(b, e, t.item)
            return applied("set_starbase_" .. t.kind)
        end
    end
    world.append(b, key, t.item)
    return applied("set_starbase_" .. t.kind)
end
-- remove_starbase_module / _building = { slot (default all) item (optional; all: any) }; the
-- random removal picks its slots here (the game's generator [I])
function systems.effects.remove_starbase_item(t)
    local s = obj("starbase", t.id)
    if not s then return skipped("remove_starbase_" .. t.kind, "no starbase") end
    local b = items_block(s, t.kind)
    local match = {}
    for _, e in ipairs(b) do
        if e.op and e.key and e.value.text then
            local slot = tonumber(e.key.text) + 1
            local item = unq(e.value.text)
            local ok = (t.slot == nil or t.slot == slot)
            if t.item and t.item ~= "all" and t.item ~= item then ok = false end
            if ok then match[#match + 1] = e end
        end
    end
    if t.random then
        local pick = {}
        local n = math.min(t.count or 1, #match)
        for _ = 1, n do
            local i = math.floor(objects.draw() * #match) + 1
            pick[#pick + 1] = table.remove(match, math.min(i, #match))
        end
        match = pick
    end
    if #match == 0 then return skipped("remove_starbase_" .. t.kind, "nothing to remove") end
    for _, e in ipairs(match) do world.remove_entry(b, e) end
    return applied("remove_starbase_" .. t.kind)
end
-- add_starbase_component / remove_starbase_component = { component }: `components = { "KEY" }` [I]
function systems.effects.starbase_component(t)
    local s = obj("starbase", t.id)
    if not s then return skipped("starbase_component", "no starbase") end
    if t.add then
        list_add(s, "components", t.component, true)
        return applied("starbase_component")
    end
    if not list_del(s, "components", t.component) then return skipped("starbase_component", "not there") end
    return applied("starbase_component")
end
-- set_starbase_size = <ship size>: the level whose ship_size it is (common/starbase_levels)
function systems.effects.set_starbase_size(t)
    local s = obj("starbase", t.id)
    if not s then return skipped("set_starbase_size", "no starbase") end
    for name, d in pairs(defs.folder("common/starbase_levels")) do
        if unq(defs.field(d.block, "ship_size")) == t.size then
            set_quoted(s, "level", name)
            return applied("set_starbase_size")
        end
    end
    return skipped("set_starbase_size", "no level of that size")
end

-- ---------------------------------------------------------------------------------------------
-- countries: the AI's starbase design overrides (`ai_starbase_weapon_preference_override`,
-- `ai_starbase_armor_ratio_override`, `ai_starbase_shields_ratio_override` [V]), the bypasses seen
-- (`seen_bypass_types = { "gateway" }` [V], `seen_bypasses` [I]), closed borders (the relation's
-- `closed_borders = yes` [V: ERelationFlags bit 15])

function systems.effects.ai_starbase_override(t)
    local c = obj("country", t.id)
    if not c then return skipped("ai_starbase_override", "no country") end
    local key = "ai_starbase_" .. t.what .. "_override"
    if t.value == nil then
        remove_field(c, key)
    else
        if t.quoted then set_quoted(c, key, t.value) else world.set(c, key, t.value) end
    end
    return applied("ai_starbase_override")
end
function systems.effects.add_seen_bypass(t)
    local c = obj("country", t.id)
    if not c then return skipped("add_seen_bypass", "no country") end
    if t.bypass_type then
        list_add(c, "seen_bypass_types", t.bypass_type, true)
    else
        if not obj("bypasses", t.bypass) then return skipped("add_seen_bypass", "no bypass") end
        list_add(c, "seen_bypasses", t.bypass)
    end
    return applied("add_seen_bypass")
end
function systems.effects.set_closed_borders(t)
    local D = require("engine.diplomacy")
    local rel = D.relation(t.id, t.who)
    if not rel then return skipped("set_closed_borders", "no relation") end
    if t.status then world.set(rel, "closed_borders", "yes") else remove_field(rel, "closed_borders") end
    if t.forced then world.set(rel, "closed_borders_forced_until", today() + t.forced * 360) end
    return applied("set_closed_borders")
end

-- ---------------------------------------------------------------------------------------------
-- systems: hyperlanes (`hyperlane = { { to length } }`, both systems', the length the distance
-- rounded [V: the save's whole lengths]), asteroid belts (`asteroid_belts = { { type inner_radius }
-- }` [V]), the star class (`star_class`, the primary star's `planet_class`: the class's
-- `planet = { key }` [V: common/star_classes])

local function lanes(sid)
    local s = obj("galactic_object", sid)
    return s and objects.list_of(s, "hyperlane")
end
local function lane_to(sid, to)
    for _, h in ipairs(world.blocks(lanes(sid))) do
        if tonumber(world.field(h, "to")) == to then return h end
    end
    return nil
end
function systems.effects.add_hyperlane(t)
    local a, b = obj("galactic_object", t.from), obj("galactic_object", t.to)
    if not a or not b or t.from == t.to then return skipped("add_hyperlane", "no systems") end
    if lane_to(t.from, t.to) then return skipped("add_hyperlane", "already linked") end
    local function xy(s)
        local c = world.field(s, "coordinate")
        return tonumber(world.field(c, "x")) or 0, tonumber(world.field(c, "y")) or 0
    end
    local ax, ay = xy(a)
    local bx, by = xy(b)
    local len = math.floor(math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) + 0.5)
    for _, p in ipairs({ { t.from, t.to }, { t.to, t.from } }) do
        local h = {}
        world.append(h, "to", p[2])
        world.append(h, "length", len)
        world.push(lanes(p[1]), h)
    end
    return applied("add_hyperlane")
end
function systems.effects.remove_hyperlane(t)
    local done = false
    for _, p in ipairs({ { t.from, t.to }, { t.to, t.from } }) do
        local h = lane_to(p[1], p[2])
        if h then
            world.remove_entry(lanes(p[1]), h)
            done = true
        end
    end
    if not done then return skipped("remove_hyperlane", "no hyperlane") end
    return applied("remove_hyperlane")
end
-- add_asteroid_belt / set_asteroid_belt = { radius type }: add one; set: the one at that radius
-- replaced (added when there is none [I])
function systems.effects.asteroid_belt(t)
    local s = obj("galactic_object", t.id)
    if not s then return skipped("asteroid_belt", "no system") end
    if not defs.get("common/asteroid_belts", t.belt) then return skipped("asteroid_belt", "unknown type") end
    local belts = objects.list_of(s, "asteroid_belts")
    if t.set then
        for _, b in ipairs(world.blocks(belts)) do
            if tonumber(world.field(b, "inner_radius")) == t.radius then
                set_quoted(b, "type", t.belt)
                return applied("asteroid_belt")
            end
        end
    end
    local b = {}
    world.append(b, "type", t.belt, true)
    world.append(b, "inner_radius", t.radius)
    world.push(belts, b)
    return applied("asteroid_belt")
end
function systems.effects.set_star_class(t)
    local s = obj("galactic_object", t.id)
    local d = defs.get("common/star_classes", t.class)
    if not s or not d then return skipped("set_star_class", s and "unknown class" or "no system") end
    set_quoted(s, "star_class", t.class)
    local pb = defs.field(d.block, "planet")
    local pc = type(pb) == "table" and unq(defs.field(pb, "key")) or nil
    local R = require("engine.script.runtime")
    local star = R.star_planet(t.id)
    local p = star and obj("planet", star)
    if p and pc then set_quoted(p, "planet_class", pc) end
    return applied("set_star_class")
end

-- ---------------------------------------------------------------------------------------------
-- megastructures and bypasses: a megastructure's `bypass`; a bypass's `owner = { type = 6 (a
-- megastructure) | 7 (a natural wormhole) id }`, `active`, `connections`, `active_connections`,
-- `linked_to`, `lock_country`, `lock_remaining_days`, `is_manual_lock` [V]; the systems'
-- `megastructures`, `bypasses`, `ambient_object` lists [V]

local function remove_bypass(bid)
    local b = obj("bypasses", bid)
    if not b then return end
    for _, other in ipairs(world.all("bypasses")) do
        local o = obj("bypasses", other)
        if o and other ~= bid then
            list_del(o, "connections", bid)
            list_del(o, "active_connections", bid)
            if ref(world.field(o, "linked_to")) == bid then remove_field(o, "linked_to") end
        end
    end
    for _, sid in ipairs(world.all("galactic_object")) do
        list_del(obj("galactic_object", sid), "bypasses", bid)
    end
    world.remove("bypasses", bid)
end
-- delete_megastructure / remove_megastructure = <target>: gone, with its bypass
function systems.effects.remove_megastructure(t)
    local m = obj("megastructures", t.id)
    if not m then return skipped("remove_megastructure", "no megastructure") end
    local bid = ref(world.field(m, "bypass"))
    if bid then remove_bypass(bid) end
    local sid = system_of_coord(m)
    if sid then list_del(obj("galactic_object", sid), "megastructures", t.id) end
    world.remove("megastructures", t.id)
    return applied("remove_megastructure")
end
-- destroy_ambient_object = <target>
function systems.effects.destroy_ambient_object(t)
    local a = obj("ambient_object", t.id)
    if not a then return skipped("destroy_ambient_object", "no ambient object") end
    local sid = system_of_coord(a)
    if sid then list_del(obj("galactic_object", sid), "ambient_object", t.id) end
    world.remove("ambient_object", t.id)
    return applied("destroy_ambient_object")
end
-- the active gateways' `active_connections`: the active ones among their connections
local function refresh_gateways()
    for _, bid in ipairs(world.all("bypasses")) do
        local b = obj("bypasses", bid)
        if b and world.field(b, "connections") ~= nil and not world.field(b, "linked_to") then
            local act = {}
            if world.field(b, "active") == "yes" then
                for _, v in ipairs(world.list(world.field(b, "connections"))) do
                    local o = obj("bypasses", tonumber(v))
                    if o and world.field(o, "active") == "yes" then act[#act + 1] = v end
                end
            end
            if #act > 0 or world.field(b, "active_connections") ~= nil then set_list(b, "active_connections", act) end
        end
    end
end
-- activate_gateway = <megastructure>: its bypass active, the gateway network's connections made
function systems.effects.activate_gateway(t)
    local m = obj("megastructures", t.id)
    local bid = m and ref(world.field(m, "bypass"))
    local b = bid and obj("bypasses", bid)
    if not b then return skipped("activate_gateway", "no bypass") end
    world.set(b, "active", "yes")
    refresh_gateways()
    return applied("activate_gateway")
end
-- link_to = <megastructure>: the two megastructures' bypasses linked both ways
function systems.effects.link_to(t)
    local ma, mb = obj("megastructures", t.id), obj("megastructures", t.target)
    local a, b = ma and ref(world.field(ma, "bypass")), mb and ref(world.field(mb, "bypass"))
    local ab, bb = a and obj("bypasses", a), b and obj("bypasses", b)
    if not ab or not bb or a == b then return skipped("link_to", "no bypasses") end
    for _, x in ipairs({ { ab, b }, { bb, a } }) do
        world.set(x[1], "linked_to", x[2])
        list_add(x[1], "connections", x[2])
        if world.field(x[1], "active") == "yes" then list_add(x[1], "active_connections", x[2]) end
    end
    return applied("link_to")
end
-- create_bypass = { owner type }: a new bypass of the megastructure (its `bypass`), in its system
function systems.effects.create_bypass(t)
    local m = obj("megastructures", t.id)
    if not m then return skipped("create_bypass", "no megastructure") end
    if not defs.get("common/bypass", t.bypass_type) then return skipped("create_bypass", "unknown type") end
    local b = {}
    world.append(b, "type", t.bypass_type, true)
    world.append(b, "active", "yes")
    local o = {}
    world.append(o, "type", 6)
    world.append(o, "id", t.id)
    world.append(b, "owner", o)
    world.append(b, "lock_country", NO_ID)
    world.append(b, "lock_remaining_days", -1)
    world.append(b, "is_manual_lock", "no")
    local id = objects.create("bypasses", b)
    world.set(m, "bypass", id)
    local sid = system_of_coord(m)
    if sid then list_add(obj("galactic_object", sid), "bypasses", id) end
    return applied("create_bypass", id)
end
-- lock_bypass = { country duration } / renew_bypass_lock: lock_country, its days
-- (renewed: NGameplay DIMENSIONAL_LOCK_EXPIRATION_TIME, as when built [I])
function systems.effects.lock_bypass(t)
    local b = obj("bypasses", t.id)
    if not b then return skipped("lock_bypass", "no bypass") end
    if t.renew then
        if not ref(world.field(b, "lock_country")) then return skipped("lock_bypass", "not locked") end
        local R = require("engine.script.runtime")
        world.set(b, "lock_remaining_days", R.define("NGameplay", "DIMENSIONAL_LOCK_EXPIRATION_TIME", 3600))
        return applied("lock_bypass")
    end
    if not obj("country", t.country) then return skipped("lock_bypass", "no country") end
    world.set(b, "lock_country", t.country)
    world.set(b, "lock_remaining_days", t.duration or -1)
    return applied("lock_bypass")
end
-- upgrade_megastructure_to = <type>: `upgrade = "<type>"`, `upgrade_finish_date` its build time
-- ahead [I]; finish_upgrade: the type becomes the upgrade's; set_halted = n days (-1: for ever):
-- `halted_days` [I]
local function date_text(day)
    local y = math.floor(day / 360)
    local m = math.floor((day % 360) / 30) + 1
    local d = day % 30 + 1
    return string.format("%d.%02d.%02d", y, m, d)
end
function systems.effects.upgrade_megastructure(t)
    local m = obj("megastructures", t.id)
    if not m then return skipped("upgrade_megastructure", "no megastructure") end
    if t.finish then
        local to = unq(world.field(m, "upgrade"))
        if not to then return skipped("upgrade_megastructure", "no upgrade") end
        set_quoted(m, "type", to)
        remove_field(m, "upgrade")
        remove_field(m, "upgrade_finish_date")
        remove_field(m, "halted_days")
        return applied("upgrade_megastructure")
    end
    local d = defs.get("common/megastructures", t.to)
    if not d then return skipped("upgrade_megastructure", "unknown type") end
    set_quoted(m, "upgrade", t.to)
    local days = tonumber(defs.field(d.block, "build_time")) or 0
    set_quoted(m, "upgrade_finish_date", date_text(today() + days))
    return applied("upgrade_megastructure")
end
function systems.effects.set_halted(t)
    local m = obj("megastructures", t.id)
    if not m then return skipped("set_halted", "no megastructure") end
    world.set(m, "halted_days", t.days)
    return applied("set_halted")
end
-- set_overclock = <type> | { overclock cooldown }: `overclock`, the cooldown's end day
-- `overclock_cooldown_day` (the type's cooldown, NGameplay MEGASTRUCTURE_OVERCLOCK_COOLDOWN [I])
function systems.effects.set_overclock(t)
    local m = obj("megastructures", t.id)
    local d = defs.get("common/megastructure_overclock_types", t.overclock)
    if not m or not d then return skipped("set_overclock", m and "unknown type" or "no megastructure") end
    set_quoted(m, "overclock", t.overclock)
    if t.cooldown then
        local R = require("engine.script.runtime")
        local days = tonumber(defs.field(d.block, "cooldown")) or R.define("NGameplay", "MEGASTRUCTURE_OVERCLOCK_COOLDOWN", 360)
        world.set(m, "overclock_cooldown_day", today() + days)
    end
    return applied("set_overclock")
end
-- set_owner of a megastructure: its `owner` [V: the save's owned ones]
function systems.effects.set_megastructure_owner(t)
    local m = obj("megastructures", t.id)
    if not m or not obj("country", t.country) then return skipped("set_megastructure_owner", "no megastructure") end
    world.set(m, "owner", t.country)
    return applied("set_megastructure_owner")
end

-- ---------------------------------------------------------------------------------------------
-- the graphical side, kept so a save or a trigger reads it: `graphical_culture` (graphical_culture
-- reads it), `animation_state`, a planet's `trigger_megastructure_icon` [I]

function systems.effects.set_object_field(t)
    local ids = t.ids or { t.id }
    local any = false
    for _, id in ipairs(ids) do
        local o = obj(t.store, id)
        if o then
            if t.quoted then set_quoted(o, t.key, tostring(t.value)) else world.set(o, t.key, t.value) end
            any = true
        end
    end
    if not any then return skipped("set_object_field", "no object") end
    return applied("set_object_field")
end

-- ---------------------------------------------------------------------------------------------
-- colonies and sectors: `system_locked` of the carrier [I]; a sector's `local_capital` [V]; a new
-- sector (`sectors = { id = { name systems local_capital owner type } }` [V])

function systems.effects.set_sector_capital(t)
    local s = obj("sectors", t.sector)
    if not s or not obj("colony", t.colony) then return skipped("set_sector_capital", "no sector") end
    world.set(s, "local_capital", t.colony)
    return applied("set_sector_capital")
end
function systems.effects.create_sector(t)
    local sys = obj("galactic_object", t.system)
    if not sys then return skipped("create_sector", "no system") end
    if ref(world.field(sys, "sector")) then return skipped("create_sector", "in a sector") end
    local s = {}
    local name = {}
    world.append(name, "key", t.name or "NEW_SECTOR", true)
    world.append(s, "name", name)
    local l = {}
    world.push(l, { text = tostring(t.system) })
    world.append(s, "systems", l)
    world.append(s, "local_capital", t.colony)
    world.append(s, "owner", t.owner)
    world.append(s, "auto_expand", "yes")
    world.append(s, "type", t.sector_type or "normal_sector", true)
    local id = objects.create("sectors", s)
    world.set(sys, "sector", id)
    local c = obj("country", t.owner)
    if c then list_add(c, "sectors", id) end
    return applied("create_sector", id)
end

-- ---------------------------------------------------------------------------------------------
-- psionic auras: `psionic_auras = { psionic_auras = { { country system type intensity } } }` [I: the
-- 2210 save's holder is empty]

local function aura_holder()
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "psionic_auras" and e.value.text == nil then
            local inner = world.field(e.value, "psionic_auras")
            if type(inner) ~= "table" then inner = world.child(e.value, "psionic_auras") end
            return inner
        end
    end
    if not world.tree then return nil end
    local outer = {}
    world.tree[#world.tree + 1] = { key = { text = "psionic_auras" }, op = "=", value = outer }
    world.meta.psionic_auras = outer
    return world.child(outer, "psionic_auras")
end
sb.aura_holder = aura_holder
local function aura_at(sid)
    local h = aura_holder()
    for _, a in ipairs(world.blocks(h)) do
        if tonumber(world.field(a, "system")) == sid then return a, h end
    end
    return nil, h
end
function systems.effects.psionic_aura(t)
    local a, h = aura_at(t.system)
    if t.op == "spawn" then
        if not obj("country", t.country) or not obj("galactic_object", t.system) then return skipped("psionic_aura", "no country") end
        if a then
            world.set(a, "country", t.country)
            if t.aura_type then set_quoted(a, "type", t.aura_type) end
            return applied("psionic_aura")
        end
        local b = {}
        world.append(b, "country", t.country)
        world.append(b, "system", t.system)
        if t.aura_type then world.append(b, "type", t.aura_type, true) end
        world.append(b, "intensity", 0)
        world.push(h, b)
        return applied("psionic_aura")
    end
    if not a then return skipped("psionic_aura", "no aura") end
    if t.op == "destroy" then
        world.remove_entry(h, a)
    elseif t.op == "set" then
        world.set(a, "intensity", t.value)
    else
        world.set(a, "intensity", (tonumber(world.field(a, "intensity")) or 0) + t.value)
    end
    return applied("psionic_aura")
end

-- ---------------------------------------------------------------------------------------------
-- stations made by script: create_starbase (CGalacticObject::CreateStarbase through
-- engine.fleets.stations.create: the station ship, its fleet, the starbase record, the system's
-- ownership and borders), then its size, module and building; create_mining_station (the planet's
-- shipclass_orbital_station). The station rules (one starbase per planet, one station per planet,
-- a design of the class) are stations.can_create's; the costs are not paid (an effect)

local function stations()
    return require("engine.fleets.stations")
end
function systems.effects.create_starbase(t)
    local st = stations()
    if not obj("country", t.country) or not obj("planet", t.planet) then return skipped("create_starbase", "no owner or planet") end
    local fid, why = st.create(t.country, t.planet, st.CLASS.shipclass_starbase)
    if not fid then return skipped("create_starbase", why or "not made") end
    local built = st.built[#st.built]
    local sbid = built and built.fleet == fid and built.starbase
    if not sbid then return skipped("create_starbase", "no starbase record") end
    if t.size then systems.effects.set_starbase_size({ id = sbid, size = t.size }) end
    if t.design then
        local did = objects.fleets and objects.fleets.designs.global(t.design)
        local s = obj("starbase", sbid)
        local sdi = s and world.field(s, "ship_design_implementation")
        if did and type(sdi) == "table" then world.set(sdi, "design", did) end
        local ship = s and obj("ships", ref(world.field(s, "station")))
        local ssdi = ship and world.field(ship, "ship_design_implementation")
        if did and type(ssdi) == "table" then world.set(ssdi, "design", did) end
    end
    if t.module then systems.effects.set_starbase_item({ id = sbid, kind = "module", slot = 1, item = t.module }) end
    if t.building then systems.effects.set_starbase_item({ id = sbid, kind = "building", slot = 1, item = t.building }) end
    return applied("create_starbase", sbid)
end
function systems.effects.create_mining_station(t)
    local st = stations()
    if not obj("country", t.country) or not obj("planet", t.planet) then return skipped("create_mining_station", "no owner or planet") end
    local fid, why = st.create(t.country, t.planet, st.CLASS.shipclass_mining_station)
    if not fid then return skipped("create_mining_station", why or "not made") end
    return applied("create_mining_station", fid)
end

-- ---------------------------------------------------------------------------------------------
-- nebulas: top-level `nebula = { coordinate = { x y origin randomized visual_height } name = { key }
-- radius galactic_object = <id> ... }` [V: the save's nine]; the systems within the radius of the
-- centre's system (t.systems: the handler runs the effect in each)

function systems.effects.create_nebula(t)
    local s = obj("galactic_object", t.id)
    if not s or not world.tree then return skipped("create_nebula", "no system") end
    local c = world.field(s, "coordinate")
    local x0, y0 = tonumber(world.field(c, "x")) or 0, tonumber(world.field(c, "y")) or 0
    local n = {}
    local cb = {}
    world.append(cb, "x", x0)
    world.append(cb, "y", y0)
    world.append(cb, "origin", NO_ID)
    world.append(cb, "randomized", "yes")
    world.append(cb, "visual_height", 0)
    world.append(n, "coordinate", cb)
    local nb = {}
    world.append(nb, "key", t.name or "NEBULA", true)
    world.append(n, "name", nb)
    world.append(n, "radius", t.radius)
    t.systems = {}
    for _, sid in ipairs(world.all("galactic_object")) do
        local o = obj("galactic_object", sid)
        local oc = o and world.field(o, "coordinate")
        if type(oc) == "table" then
            local dx = (tonumber(world.field(oc, "x")) or 0) - x0
            local dy = (tonumber(world.field(oc, "y")) or 0) - y0
            if dx * dx + dy * dy <= t.radius * t.radius then
                world.append(n, "galactic_object", sid)
                t.systems[#t.systems + 1] = sid
            end
        end
    end
    world.tree[#world.tree + 1] = { key = { text = "nebula" }, op = "=", value = n }
    return applied("create_nebula")
end

-- ---------------------------------------------------------------------------------------------
-- systems made or moved by script: the position the handler drew (x, y); hyperlane = yes: the
-- system's lanes replaced by one to the nearest system [I]

local function nearest_system(sid, x, y)
    local best, bd
    for _, other in ipairs(world.all("galactic_object")) do
        if other ~= sid then
            local o = obj("galactic_object", other)
            local oc = o and world.field(o, "coordinate")
            if type(oc) == "table" then
                local dx = (tonumber(world.field(oc, "x")) or 0) - x
                local dy = (tonumber(world.field(oc, "y")) or 0) - y
                local d = dx * dx + dy * dy
                if not bd or d < bd then best, bd = other, d end
            end
        end
    end
    return best
end
local function relink(sid, x, y)
    local s = obj("galactic_object", sid)
    for _, h in ipairs(world.blocks(world.field(s, "hyperlane"))) do
        local to = tonumber(world.field(h, "to"))
        if to then systems.effects.remove_hyperlane({ from = sid, to = to }) end
    end
    local n = nearest_system(sid, x, y)
    if n then systems.effects.add_hyperlane({ from = sid, to = n }) end
end
function systems.effects.move_system(t)
    local s = obj("galactic_object", t.id)
    local c = s and world.field(s, "coordinate")
    if type(c) ~= "table" then return skipped("move_system", "no system") end
    world.set(c, "x", math.floor(t.x * 100 + 0.5) / 100)
    world.set(c, "y", math.floor(t.y * 100 + 0.5) / 100)
    if t.hyperlane then relink(t.id, t.x, t.y) end
    return applied("move_system")
end
-- spawn_system: the system (`galactic_object`: coordinate, name, star_class, hyperlane,
-- initializer, radii, starbases, sector, index, storm [V: save.lua write_system's form]) and its
-- star (the class's planet class [V: common/star_classes `planet = { key }`]); the initializer's
-- other planets are not made [I]; last_created_system
function systems.effects.spawn_system(t)
    local cls = t.star_class
    local d = cls and defs.get("common/star_classes", cls)
    if not d then return skipped("spawn_system", "no star class") end
    local s = {}
    local c = {}
    world.append(c, "x", math.floor(t.x * 100 + 0.5) / 100)
    world.append(c, "y", math.floor(t.y * 100 + 0.5) / 100)
    world.append(c, "origin", NO_ID)
    world.append(c, "randomized", "yes")
    world.append(c, "visual_height", 3.65056)
    world.append(s, "coordinate", c)
    local nm = {}
    world.append(nm, "key", t.name or "NEW_SYSTEM", true)
    world.append(s, "name", nm)
    local sid = objects.new_id("galactic_object")
    -- the star
    local pb = defs.field(d.block, "planet")
    local pc = type(pb) == "table" and unq(defs.field(pb, "key")) or nil
    local pid
    if pc then
        local p = {}
        world.append(p, "planet_class", pc, true)
        world.append(p, "planet_size", tonumber(defs.field(d.block, "planet_size")) or 30)
        world.append(p, "carrier_binary_flags", 3)
        world.append(p, "build_queue", NO_ID)
        local pn = {}
        world.append(pn, "key", t.name or "NEW_SYSTEM", true)
        world.append(p, "name", pn)
        local pcoord = {}
        world.append(pcoord, "x", 0)
        world.append(pcoord, "y", 0)
        world.append(pcoord, "origin", sid)
        world.append(p, "coordinate", pcoord)
        world.append(p, "orbit", 0)
        world.append(p, "last_bombardment", "0.01.01", true)
        world.append(p, "planet_orbitals", {})
        world.append(p, "bombardment_damage", 0)
        world.append(p, "entity", 0)
        pid = objects.create("planet", p)
        world.append(s, "planet", pid)
    end
    world.append(s, "star_class", cls, true)
    world.append(s, "hyperlane", {})
    world.append(s, "initializer", t.initializer or "", true)
    world.append(s, "inner_radius", 0)
    world.append(s, "outer_radius", 0)
    local sb = {}
    world.push(sb, { text = tostring(NO_ID) })
    world.append(s, "starbases", sb)
    world.append(s, "sector", NO_ID)
    world.append(s, "index", #world.all("galactic_object"))
    world.append(s, "storm", NO_ID)
    world.create("galactic_object", sid, s)
    if t.hyperlane then relink(sid, t.x, t.y) end
    objects.set_meta("last_created_system", sid)
    return applied("spawn_system", sid)
end

-- ---------------------------------------------------------------------------------------------
-- debris (`debris = { id = { country from_country from_fleet_name coordinate resources
-- stockpile_resources ship_size component date killed must_scavenge must_reanimate must_research }
-- }`: CDebris::WriteMembers 0x290aab0 [V the keys; I the values]): the ships' sizes and their
-- designs' components; destroy: the ships (or the fleet) taken away after

local function design_components(did)
    local d = did and obj("ship_design", did)
    local out = {}
    for _, sec in ipairs(d and world.fields(d, "section") or {}) do
        if type(sec) == "table" then
            for _, comp in ipairs(world.fields(sec, "component")) do
                local tpl = type(comp) == "table" and unq(world.field(comp, "template"))
                if tpl then out[#out + 1] = tpl end
            end
        end
    end
    return out
end
function systems.effects.spawn_debris(t)
    local f = obj("fleet", t.fleet)
    if not f or not obj("country", t.country) then return skipped("spawn_debris", "no fleet or country") end
    local R = require("engine.script.runtime")
    local b = {}
    world.append(b, "country", t.country)
    world.append(b, "from_country", R.fleet_owner(t.fleet) or NO_ID)
    local name = world.field(f, "name")
    if type(name) == "table" then world.append(b, "from_fleet_name", require("engine.fleets.create").copy(name)) end
    local mc = world.path(f, "movement_manager", "coordinate")
    local c = {}
    for _, k in ipairs({ "x", "y", "origin" }) do
        world.append(c, k, type(mc) == "table" and world.field(mc, k) or (k == "origin" and NO_ID or 0))
    end
    world.append(b, "coordinate", c)
    world.append(b, "resources", {})
    world.append(b, "stockpile_resources", {})
    local seen = {}
    for _, sid in ipairs(t.ships) do
        local size = R.ship_size_of(sid)
        if size then world.append(b, "ship_size", size, true) end
        local ship = obj("ships", sid)
        local sdi = ship and world.field(ship, "ship_design_implementation")
        for _, tpl in ipairs(design_components(type(sdi) == "table" and ref(world.field(sdi, "design")) or nil)) do
            if not seen[tpl] then
                seen[tpl] = true
                world.append(b, "component", tpl, true)
            end
        end
    end
    world.append(b, "date", date_text(today()), true)
    world.append(b, "killed", #t.ships)
    for _, k in ipairs({ "must_scavenge", "must_reanimate", "must_research" }) do
        world.append(b, k, t[k] and "yes" or "no")
    end
    local id = objects.create("debris", b)
    if t.destroy then
        if t.ship then
            require("engine.fleets.destroy").ship(t.ship)
        else
            require("engine.fleets.create").kill(t.fleet)
        end
    end
    return applied("spawn_debris", id)
end
