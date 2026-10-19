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
    local d = package.loaded["engine.diplomacy"]
    return d and d.today and d.today() or 0
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
    world.append_value(l, quoted and ('"' .. tostring(v) .. '"') or v)
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
            world.set(s, "level", '"' .. name .. '"')
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
        world.set(c, key, t.quoted and ('"' .. t.value .. '"') or t.value)
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
                world.set(b, "type", '"' .. t.belt .. '"')
                return applied("asteroid_belt")
            end
        end
    end
    local b = {}
    world.append(b, "type", '"' .. t.belt .. '"')
    world.append(b, "inner_radius", t.radius)
    world.push(belts, b)
    return applied("asteroid_belt")
end
function systems.effects.set_star_class(t)
    local s = obj("galactic_object", t.id)
    local d = defs.get("common/star_classes", t.class)
    if not s or not d then return skipped("set_star_class", s and "unknown class" or "no system") end
    world.set(s, "star_class", '"' .. t.class .. '"')
    local pb = defs.field(d.block, "planet")
    local pc = type(pb) == "table" and unq(defs.field(pb, "key")) or nil
    local R = require("engine.script.runtime")
    local star = R.star_planet(t.id)
    local p = star and obj("planet", star)
    if p and pc then world.set(p, "planet_class", '"' .. pc .. '"') end
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
    world.append(b, "type", '"' .. t.bypass_type .. '"')
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
    return string.format('"%d.%02d.%02d"', y, m, d)
end
function systems.effects.upgrade_megastructure(t)
    local m = obj("megastructures", t.id)
    if not m then return skipped("upgrade_megastructure", "no megastructure") end
    if t.finish then
        local to = unq(world.field(m, "upgrade"))
        if not to then return skipped("upgrade_megastructure", "no upgrade") end
        world.set(m, "type", '"' .. to .. '"')
        remove_field(m, "upgrade")
        remove_field(m, "upgrade_finish_date")
        remove_field(m, "halted_days")
        return applied("upgrade_megastructure")
    end
    local d = defs.get("common/megastructures", t.to)
    if not d then return skipped("upgrade_megastructure", "unknown type") end
    world.set(m, "upgrade", '"' .. t.to .. '"')
    local days = tonumber(defs.field(d.block, "build_time")) or 0
    world.set(m, "upgrade_finish_date", date_text(today() + days))
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
    world.set(m, "overclock", '"' .. t.overclock .. '"')
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
            world.set(o, t.key, t.quoted and ('"' .. tostring(t.value) .. '"') or t.value)
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
    world.append(name, "key", '"' .. (t.name or "NEW_SECTOR") .. '"')
    world.append(s, "name", name)
    local l = {}
    world.push(l, { text = tostring(t.system) })
    world.append(s, "systems", l)
    world.append(s, "local_capital", t.colony)
    world.append(s, "owner", t.owner)
    world.append(s, "auto_expand", "yes")
    world.append(s, "type", '"' .. (t.sector_type or "normal_sector") .. '"')
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
            if t.aura_type then world.set(a, "type", ' .. t.aura_type .. ') end
            return applied("psionic_aura")
        end
        local b = {}
        world.append(b, "country", t.country)
        world.append(b, "system", t.system)
        if t.aura_type then world.append(b, "type", ' .. t.aura_type .. ') end
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
