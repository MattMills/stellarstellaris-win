-- engine/fleets/create.lua : ships and fleets made from a design, the way the game makes them (GOG
-- 4.5.2 and the Linux 4.5.2 build with its symbols; docs/shipbuilding.md), in the save's own form.
--
-- API (engine.construction for the shipyards and the armies, engine.ai.shipbuilding, the stations):
--
--   create.allocate(store) -> id, entry
--       TPdxRefDatabase<T>::CreateNewObject: index | generation << 24; the free slots are the save's
--       `id = none` entries (ascending at load), a slot freed since is pushed in front; without
--       one, the index past the highest. The store is looked at on every call, so ids others made
--       (engine.fleets.stations' own allocator) are seen.
--   create.place(store, id, entry, block): a reused slot keeps its place in the save
--   create.ship{ country =, design =, coordinate = { x =, y =, origin = } (raw CFixedPoint),
--                date = "Y.MM.DD", name = <a name block> (given: no name drawn, as an army's
--                transport), stage = growth stage } -> ship id
--       CGameState::CreateNewShip (0x1b44ae0 Linux): the name (TakeRandomShipName: two draws a
--       try until a name the country has not used, then GetShipNameWithRomanNumerals and the
--       country's ship_prefix in PREFIX_NAME_FORMAT, CCountry::AddShipNameKey), CShip::Initialize
--       (the sections and their weapons from the design), the hit points (create.hit_points), at
--       rotation pi (CShip::ResetToRotation(VFixedPI)).
--   create.fleet{ country =, ship_class =, civilian =, coordinate = } -> fleet id
--       CGameState::CreateNewFleet (0x1b46d90): CFleet::Initialize (owner: the country's
--       fleets_manager.owned_fleets), the save's form of a fleet that never moved.
--   create.add_ship(fleet, ship) -> true
--       CFleet::AddShip (0x292d430): the fleet's ships (by size), the ship's fleet and `reserve`,
--       the fleet's name with its first ship (CFleet::CreateName), its hit points, the fleet
--       template (CFleetTemplateManager::OnShipAdded), the country's naval capacity used, then
--       NScriptUtil::OnShipEnterFleet: two draws and on_ship_enter_fleet (this = fleet, from = ship).
--   create.enter_orbit(fleet, kind, id) -> slot
--       CFleetOrbitalSlotHandle::EnterOrbitInternal: the first free slot of the planet's
--       planet_orbitals or the starbase's orbitals, the fleet at that slot, then
--       CFleet::OnEnteredOrbit's three draws (the headless profile: 3 a call, 168 calls in 180 days).
--   create.find_merge_fleet(country, kind, id, ship) -> fleet | nil
--       CFleetOrbitalSlotHandle::FindMergeFleet (NFleet::CanMergeShipWithFleet): a fleet of the
--       country in orbit there that is neither civilian, a station nor a transport fleet.
--   create.around_orbital{ country =, design =, orbitable = { kind =, id = }, date = }
--       -> ship, fleet, merged
--       the shipyard's ship (CBuildableShip::OnFinished 0x219a660: CreateShipAroundOrbital,
--       FindMergeFleet, else CreateFleetAroundOrbital and AddShip).
--   create.on_ship_built(ship, orbitable): FireOnShipBuiltOnAction (0x219b100): two draws (the
--       scopes), on_ship_built (this = the ship, from = the planet or the starbase).
--   create.station{ country =, design =, orbit = { kind = "planet"|"starbase", id = },
--                   coordinate =, date =, name =, ship_class = } -> ship, fleet
--       for the stations: a ship and a fleet of its own in orbit (no merge, no on_ship_built).
--   create.hit_points(country, design[, stage]) -> hull, armor, shield (floats, as the save writes)
--   create.design_info(design[, stage]) -> { size, size_block, class, civilian, sections, ... }
--   create.orbit_coordinate(kind, id, slot), create.orbital_coordinate(kind, id): the places
--   create.transport_fleet_name(country): TRANS_FLEET_NAME with the country's
--       next_transport_fleet_number (advanced)
--   create.ship_name(country, info): the name drawn (TakeRandomShipName), without the prefix
--
-- Not modelled: military power (the fleet's and country's military_power, diplomacy_weight stay
-- as they are; a new fleet starts at 0), the ship's experience (ship_starting_experience_add),
-- rarity modifiers, arkships, the hero and space fauna branches, the ship's own movement to its
-- place in the formation (it is made at the orbit's place), cloaking.

local world = require("engine.world")
local defs = require("engine.defs")
local live = require("engine.store.live")   -- the store's copy of what exploration reads (docs/data_layer.md)

local create = {
    stats = { ships = 0, fleets = 0, merged = 0, draws = 0, name_tries = 0, on_actions = 0,
              on_action_errors = 0, templates = 0, orbits = 0 },
    errors = {},
}
local S = create.stats

local GEN, NO_ID, FP = 16777216, 4294967295, 100000
local PI = 314200 -- VFixedPI (engine.fleets.movement)

-- EShipClass (the PDB's enum) by the save's token
local CLASS = {
    shipclass_military = 0, shipclass_constructor = 1, shipclass_colonizer = 2, shipclass_science_ship = 3,
    shipclass_transport = 4, shipclass_mining_station = 5, shipclass_research_station = 6,
    shipclass_military_station = 7, shipclass_observation_station = 9, shipclass_starbase = 10,
}
create.CLASS = CLASS

local function draw()
    S.draws = S.draws + 1
    return RUST.rand()
end

local function err(msg)
    if #create.errors < 20 then
        create.errors[#create.errors + 1] = msg
    end
end

-- numbers as the save writes them (raw CFixedPoint <-> text), engine.fleets.path's
local function path()
    return require("engine.fleets.path")
end

-- ---------------------------------------------------------------------------------------------
-- the save's form

local function tok(v, quoted)
    return { text = tostring(v), quoted = quoted or nil }
end

local function copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = type(x) == "table" and copy(x) or x
    end
    return out
end
create.copy = copy

local function unq(v)
    if type(v) == "string" then
        return (v:gsub('^"(.*)"$', "%1"))
    end
    return v
end

local function coord_block(c)
    local P = path()
    local b = {}
    world.append(b, "x", P.text(c and c.x or 0))
    world.append(b, "y", P.text(c and c.y or 0))
    world.append(b, "origin", tostring(c and c.origin or NO_ID))
    return b
end

local function read_coord(b)
    if type(b) ~= "table" then
        return nil
    end
    local P = path()
    return { x = P.raw(world.field(b, "x")) or 0, y = P.raw(world.field(b, "y")) or 0,
             origin = tonumber(world.field(b, "origin")) or NO_ID }
end
create.read_coord = read_coord

local function today()
    local e = package.loaded["engine"]
    if e and e.date_text then
        return e.date_text()
    end
    return tostring(world.meta.date or "2200.01.01")
end

-- the blocks of a list block (`variables = { { ... } { ... } }`)
local function blocks(b)
    return world.blocks(b)
end

-- ---------------------------------------------------------------------------------------------
-- ids

local alloc = {}
local function allocator(store)
    local a = alloc[store]
    if a then
        return a
    end
    a = { free = {}, gen = {}, live = {}, max = -1 }
    for _, e in ipairs(world.store_blocks[store] or {}) do
        if e.op and e.key then
            local id = tonumber(e.key.text)
            if id then
                local index = id % GEN
                a.gen[index] = math.floor(id / GEN)
                if index > a.max then a.max = index end
                if e.value.text == "none" then
                    a.free[#a.free + 1] = index
                else
                    a.live[id] = true
                end
            end
        end
    end
    table.sort(a.free)
    alloc[store] = a
    return a
end

-- the slots freed since the last look pushed in front; ids made elsewhere taken as live
local function collect(a, store)
    local st = world.stores[store] or {}
    local gone = {}
    for id in pairs(a.live) do
        if st[id] == nil then gone[#gone + 1] = id end
    end
    table.sort(gone)
    for _, id in ipairs(gone) do
        a.live[id] = nil
        local index = id % GEN
        a.gen[index] = math.floor(id / GEN)
        table.insert(a.free, 1, index)
    end
    for _, id in ipairs(world.all(store)) do
        if not a.live[id] then
            a.live[id] = true
            local index, g = id % GEN, math.floor(id / GEN)
            if a.gen[index] == nil or a.gen[index] < g then a.gen[index] = g end
            if index > a.max then a.max = index end
            for i = #a.free, 1, -1 do
                if a.free[i] == index then table.remove(a.free, i) end
            end
        end
    end
end

function create.allocate(store)
    local a = allocator(store)
    collect(a, store)
    local index = table.remove(a.free, 1)
    local old
    if index == nil then
        a.max = a.max + 1
        index, old = a.max, -1
    else
        old = a.gen[index] or 0
    end
    local g = old < 0 and 0 or old + 1
    a.gen[index] = g
    local id = index + g * GEN
    -- a freed slot (`<old id> = none`) the object takes
    local e = old >= 0 and world.none_slot(store, index, GEN) or nil
    a.live[id] = true
    return id, e
end

-- create.place(store, id, old, block) -> the object's block in the world: the freed slot `old =
-- none` (create.allocate's) becomes the object, else it goes at the end
function create.place(store, id, old, block)
    return world.place(store, id, old, block, GEN)
end

-- ---------------------------------------------------------------------------------------------
-- the game's data: component and section templates by key (repeated `*_template = { key = }`)

local keyed_cache = {}
local function keyed(folder)
    local idx = keyed_cache[folder]
    if idx then
        return idx
    end
    idx = {}
    local ok, db = pcall(require, "simscript.db")
    local source = require("stellar.script.source")
    if ok and db and db.fs then
        for _, file in ipairs(source.files(db.fs, folder, "txt")) do
            local tree = source.parse(db.fs, file)
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.value.text == nil then
                    local key = unq(defs.field(e.value, "key"))
                    if key then
                        idx[key] = { block = e.value, kind = e.key.text, file = file }
                    end
                end
            end
        end
    end
    keyed_cache[folder] = idx
    return idx
end
create.components = function() return keyed("common/component_templates") end
create.sections = function() return keyed("common/section_templates") end

-- a definition's `@variable`: its file's own, else the global scripted variables
-- (common/scripted_variables)
local file_vars, global_vars = {}, nil
local function vars_of(file, into)
    into = into or {}
    pcall(function()
        local db = require("simscript.db")
        local source = require("stellar.script.source")
        for _, e in ipairs(source.parse(db.fs, file) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                into[e.key.text] = e.value.text
            end
        end
    end)
    return into
end
local function number(v, file, depth)
    if type(v) == "number" then
        return v
    end
    if type(v) ~= "string" then
        return nil
    end
    local n = tonumber(v)
    if n then
        return n
    end
    if v:sub(1, 1) == "@" and (depth or 0) < 8 then
        if file and file_vars[file] == nil then
            file_vars[file] = vars_of(file)
        end
        local r = file and file_vars[file][v]
        if r == nil then
            if not global_vars then
                global_vars = {}
                pcall(function()
                    local db = require("simscript.db")
                    local source = require("stellar.script.source")
                    for _, f in ipairs(source.files(db.fs, "common/scripted_variables", "txt") or {}) do
                        vars_of(f, global_vars)
                    end
                end)
            end
            r = global_vars[v]
        end
        return r and number(r, file, (depth or 0) + 1) or nil
    end
    return nil
end
create.number = number

local function size_def(size)
    local d = size and defs.get("common/ship_sizes", size)
    return d and d.block, d and d.file
end

-- the modifier adds of a block (`modifier = { ship_armor_add = 100 }`) into t
local function add_mods(t, block, file)
    if type(block) ~= "table" then
        return
    end
    for _, e in ipairs(block) do
        if e.op and e.key and e.value.text then
            local v = number(e.value.text, file)
            if v then t[e.key.text] = (t[e.key.text] or 0) + v end
        end
    end
end

-- create.design_info(did[, stage]) -> the design's growth stage, size, sections and components
function create.design_info(did, stage)
    local d = world.object("ship_design", did)
    if not d then
        return nil
    end
    local gs = blocks(world.field(d, "growth_stages"))[(stage or 0) + 1]
    if not gs then
        return nil
    end
    local size = unq(world.field(gs, "ship_size"))
    local sb, sfile = size_def(size)
    local info = { id = did, block = d, stage = gs, size = size, size_block = sb, size_file = sfile, sections = {}, required = {},
                   class = sb and unq(defs.field(sb, "class")) or "shipclass_military",
                   civilian = sb and defs.field(sb, "is_civilian") == "yes" or false,
                   size_multiplier = sb and number(defs.field(sb, "size_multiplier"), sfile) or 1,
                   formation_priority = sb and number(defs.field(sb, "formation_priority"), sfile) or 0,
                   culture = unq(world.field(d, "graphical_culture")) }
    for key, v in world.statements(gs) do
        if key == "section" and type(v) == "table" then
            local sec = { template = unq(world.field(v, "template")), slot = unq(world.field(v, "slot")), components = {} }
            for ckey, c in world.statements(v) do
                if ckey == "component" and type(c) == "table" then
                    sec.components[#sec.components + 1] = { slot = unq(world.field(c, "slot")), template = unq(world.field(c, "template")) }
                end
            end
            info.sections[#info.sections + 1] = sec
        elseif key == "required_component" and type(v) ~= "table" then
            info.required[#info.required + 1] = unq(v)
        end
    end
    return info
end

-- the ship's hit points: the size's max_hitpoints and the adds of the size's, the sections' and
-- the components' modifier blocks, times 1 + the country's (and the size's) mults [I], checked on
-- the save's ships (docs/shipbuilding.md)
local function country_mods(country)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers("country", country) or {}
end

function create.hit_points(country, did, stage)
    local info = type(did) == "table" and did or create.design_info(did, stage)
    if not info then
        return nil
    end
    local adds = {}
    local sb = info.size_block
    add_mods(adds, sb and defs.field(sb, "modifier"), info.size_file)
    local C, T = create.components(), create.sections()
    for _, sec in ipairs(info.sections) do
        local st = T[sec.template]
        add_mods(adds, st and defs.field(st.block, "modifier"), st and st.file)
        for _, c in ipairs(sec.components) do
            local ct = C[c.template]
            add_mods(adds, ct and defs.field(ct.block, "modifier"), ct and ct.file)
        end
    end
    for _, r in ipairs(info.required) do
        local ct = C[r]
        add_mods(adds, ct and defs.field(ct.block, "modifier"), ct and ct.file)
    end
    local M = country_mods(country)
    local size = info.size or ""
    local function mult(kind)
        return 1 + (M["ship_" .. kind .. "_mult"] or 0) + (M["shipsize_" .. size .. "_" .. kind .. "_mult"] or 0)
            + (adds["ship_" .. kind .. "_mult"] or 0)
    end
    local hull = ((sb and number(defs.field(sb, "max_hitpoints"), info.size_file) or 0) + (adds.ship_hull_add or 0)
        + (M.ship_hull_add or 0)) * mult("hull")
    local armor = ((adds.ship_armor_add or 0) + (M.ship_armor_add or 0)) * mult("armor")
    local shield = ((adds.ship_shield_add or 0) + (M.ship_shield_add or 0)) * mult("shield")
    return hull, armor, shield
end

-- ---------------------------------------------------------------------------------------------
-- names

local function name_key(n)
    return type(n) == "table" and unq(world.field(n, "key")) or nil
end

local function key_block(key)
    local b = {}
    world.append(b, "key", key, true)
    return b
end

-- a variable of a name: { key = "NAME" value = <name> }
local function var(key, value)
    local v = {}
    world.append(v, "key", key, true)
    world.append(v, "value", value)
    return v
end

local function format_block(key, vars)
    local b = {}
    world.append(b, "key", key, true)
    local vb = {}
    for _, v in ipairs(vars) do
        vb[#vb + 1] = v
    end
    world.append(b, "variables", vb)
    return b
end

-- the country's ship_names = { "key" = count }
local function ship_names(country)
    local c = world.object("country", country)
    if not c then
        return nil
    end
    local sn = world.field(c, "ship_names")
    if type(sn) ~= "table" then
        sn = world.child(c, "ship_names")
    end
    return sn
end

-- CCountry::GetNumShipNameKey
local function num_ship_name(country, key)
    local sn = ship_names(country)
    for _, e in ipairs(sn or {}) do
        if e.op and e.key and unq(e.key.text) == key then
            return tonumber(e.value.text) or 0
        end
    end
    return 0
end

-- CCountry::AddShipNameKey (0x237f420): the key's count + 1, or a new entry
local function add_ship_name(country, key)
    local sn = ship_names(country)
    if not sn or not key or key == "" then
        return
    end
    for _, e in ipairs(sn) do
        if e.op and e.key and unq(e.key.text) == key then
            world.set_entry(sn, e, (tonumber(e.value.text) or 0) + 1)
            return
        end
    end
    world.append_entry(sn, { key = { text = key, quoted = true }, op = "=", value = { text = "1" } })
end

-- the country's name list's ship names for a size: its own list and the generic one
local function name_lists(country, size)
    local c = world.object("country", country)
    local nl = c and unq(world.field(c, "name_list"))
    local d = nl and defs.get("common/name_lists", nl)
    local list = d and defs.field(d.block, nl) or (d and d.block)
    local sn = type(list) == "table" and defs.field(list, "ship_names")
    if type(sn) ~= "table" then
        sn = d and defs.field(d.block, "ship_names")
    end
    local function names(key)
        local out = {}
        local b = type(sn) == "table" and defs.field(sn, key)
        for _, e in ipairs(type(b) == "table" and b or {}) do
            if e.text then out[#out + 1] = unq(e.text) end
        end
        return out
    end
    return names(size or ""), names("generic"), list
end
create.name_lists = name_lists

-- CNameListShip::GetRandomNameKey(size, true, 0) (0x1dbc650): one draw for the list (odd: the
-- generic one, when it has names; the size's when it has names), one for the name in it
local function random_name_key(own, generic)
    local r1 = draw()
    local list = own
    if (r1 % 2 == 1 and #generic > 0) or #own == 0 then
        list = generic
    end
    if #list == 0 then
        return ""
    end
    return list[draw() % #list + 1]
end

-- CNameListManager::TakeRandomShipName (0x1dc1910): up to 100 tries for a name the country has
-- not used (GetNumShipNameKey 0); then GetShipNameWithRomanNumerals (0x1b45810): a used name gets
-- the numeral of its count + 1 (SUFFIX_NAME_FORMAT); then the prefix (PREFIX_NAME_FORMAT, the
-- country's ship_prefix, for a size that takes one) and AddShipNameKey
function create.ship_name(country, info)
    local own, generic = name_lists(country, info.size)
    local key = ""
    for _ = 1, 100 do
        S.name_tries = S.name_tries + 1
        key = random_name_key(own, generic)
        if key ~= "" and num_ship_name(country, key) <= 0 then
            break
        end
    end
    if key == "" then
        key = random_name_key(own, generic)
    end
    local name = key_block(key ~= "" and key or tostring(name_key(world.field(info.block, "name")) or ""))
    local used = num_ship_name(country, key)
    if used > 0 then
        local numeral = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII",
                          "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX" }
        local lit = {}
        world.append(lit, "key", numeral[used + 1] or tostring(used + 1), true)
        world.append(lit, "literal", "yes")
        name = format_block("SUFFIX_NAME_FORMAT", { var("NAME", name), var("SUFFIX", lit) })
    end
    return name, key
end

-- the prefix of CGameState::CreateNewShip (a size without uses_name_prefix = no):
-- PREFIX_NAME_FORMAT { NAME PREFIX = the country's ship_prefix }, then CCountry::AddShipNameKey
-- with the name's key (a given name's too: an army's transport adds "%SEQ%")
local function finish_name(country, info, name, key)
    local sb = info.size_block
    if not (sb and defs.field(sb, "uses_name_prefix") == "no") then
        local c = world.object("country", country)
        local prefix = c and world.field(c, "ship_prefix")
        if type(prefix) == "table" and world.field(prefix, "key") then
            name = format_block("PREFIX_NAME_FORMAT", { var("NAME", name), var("PREFIX", copy(prefix)) })
        end
    end
    add_ship_name(country, key or name_key(name))
    return name
end

-- ---------------------------------------------------------------------------------------------
-- the ship

local function facing(angle)
    local m = require("engine.fleets.movement")
    local sn, cs = m.fsin(angle), m.fcos(angle)
    local l = math.sqrt(sn * sn + cs * cs)
    if l == 0 then
        return 0, 0
    end
    local P = path()
    return P.fdiv(-sn, math.floor(l + 0.5)), P.fdiv(cs, math.floor(l + 0.5))
end

local WEAPON_KINDS = { weapon_component_template = true, strike_craft_component_template = true }

local function hp_text(v)
    return world.number_text(math.floor(v * FP + 0.5) / FP)
end

function create.ship(o)
    local info = create.design_info(o.design, o.stage)
    if not info then
        err("ship: no design " .. tostring(o.design))
        return nil
    end
    local country = o.country
    local name, key = o.name, nil
    if not name then
        name, key = create.ship_name(country, info)
    end
    if not o.raw_name then
        name = finish_name(country, info, name, key)
    end
    local id, entry = create.allocate("ships")
    local b = {}
    world.append(b, "fleet", o.fleet or NO_ID)
    world.append(b, "name", name)
    world.append(b, "reserve", 0)
    local sdi = {}
    world.append(sdi, "design", o.design)
    world.append(sdi, "upgrade", NO_ID)
    world.append(sdi, "growth_stage", o.stage or 0)
    world.append(b, "ship_design_implementation", sdi)
    local c = world.object("country", country)
    local gc = info.culture or (c and unq(world.field(c, "graphical_culture")))
    if gc then
        world.append(b, "graphical_culture", gc, true)
    end
    -- CShip::Initialize: a section per design section, a weapon per weapon component (the index
    -- the ship's counter, next_weapon_index)
    local C = create.components()
    local nweapon = 0
    for _, sec in ipairs(info.sections) do
        local s = {}
        world.append(s, "design", sec.template, true)
        world.append(s, "slot", sec.slot, true)
        for _, comp in ipairs(sec.components) do
            local ct = C[comp.template]
            if ct and WEAPON_KINDS[ct.kind] then
                local w = {}
                world.append(w, "index", nweapon)
                world.append(w, "template", comp.template, true)
                world.append(w, "component_slot", comp.slot, true)
                world.append(w, "targeting_module", {})
                world.append(s, "weapon", w)
                nweapon = nweapon + 1
            end
        end
        world.append(b, "section", s)
    end
    local at = o.coordinate or { x = 0, y = 0, origin = NO_ID }
    world.append(b, "coordinate", coord_block(at))
    world.append(b, "target_coordinate", coord_block(at))
    local P = path()
    world.append(b, "post_move_angle", P.text(o.angle or PI))
    local hull, armor, shield = create.hit_points(country, info)
    hull, armor, shield = hull or 0, armor or 0, shield or 0
    world.append(b, "hitpoints", hp_text(hull))
    world.append(b, "shield_hitpoints", hp_text(shield))
    world.append(b, "armor_hitpoints", hp_text(armor))
    world.append(b, "max_hitpoints", hp_text(hull))
    world.append(b, "max_shield_hitpoints", hp_text(shield))
    world.append(b, "max_armor_hitpoints", hp_text(armor))
    -- CShip::ResetToRotation(VFixedPI): forward = (-sin, cos)
    local fx, fy = facing(PI)
    world.append(b, "rotation", P.text(PI))
    world.append(b, "forward_x", P.text(fx))
    world.append(b, "forward_y", P.text(fy))
    world.append(b, "upgrade_progress", 0)
    if nweapon > 0 then
        world.append(b, "next_weapon_index", nweapon)
    end
    if o.army then
        world.append(b, "army", o.army)
    end
    world.append(b, "created_this_update", "no")
    world.append(b, "targeting_module", {})
    world.append(b, "combat_action", 1)
    if info.class == "shipclass_starbase" then
        world.append(b, "disable_at_health", 0)
        world.append(b, "enable_at_health", 0.05)
    end
    world.append(b, "construction_date", o.date or today(), true)
    world.append(b, "maturation_date", "0.01.01", true)
    create.place("ships", id, entry, b)
    S.ships = S.ships + 1
    return id, info
end

-- ---------------------------------------------------------------------------------------------
-- the fleet

local function null_coord()
    return coord_block({ x = 0, y = 0, origin = NO_ID })
end

-- the country's owned fleets (fleets_manager.owned_fleets = { { fleet = id } ... }), in id order
local function add_owned_fleet(country, fid)
    local c = world.object("country", country)
    local fm = c and world.child(c, "fleets_manager")
    if not fm then
        return
    end
    local owned = world.field(fm, "owned_fleets")
    if type(owned) ~= "table" then
        owned = {}
        world.insert(fm, 1, "owned_fleets", owned)
    end
    local e = {}
    world.append(e, "fleet", fid)
    local pos = #owned + 1
    for i, x in ipairs(owned) do
        if not x.op and not x.text then
            local id = tonumber(world.field(x, "fleet"))
            if id and id > fid then
                pos = i
                break
            end
        end
    end
    live.touch("country", country)
    world.insert_value(owned, pos, e)
    world.fleet_owner[fid] = country
end
create.add_owned_fleet = add_owned_fleet

function create.fleet(o)
    local id, entry = create.allocate("fleet")
    local b = {}
    local at = o.coordinate or { x = 0, y = 0, origin = NO_ID }
    world.append(b, "ships", {})
    local combat = {}
    local cc = {}
    world.append(cc, "x", 0)
    world.append(cc, "y", 0)
    world.append(cc, "origin", at.origin or NO_ID)
    world.append(combat, "coordinate", cc)
    local fp = {}
    for _, k in ipairs({ "x", "y", "speed", "rotation", "forward_x", "forward_y" }) do
        world.append(fp, k, 0)
    end
    world.append(combat, "formation_pos", fp)
    local fm = {}
    world.append(fm, "root", -1)
    world.append(combat, "formation", fm)
    world.append(combat, "start_coordinate", null_coord())
    world.append(combat, "start_date", "0.01.01", true)
    world.append(b, "combat", combat)
    local stats = {}
    local cs = {}
    world.append(cs, "fleet", {})
    world.append(cs, "date", "0.01.01", true)
    world.append(stats, "combat_stats", cs)
    world.append(b, "fleet_stats", stats)
    world.append(b, "ground_support_stance", "selective", true)
    if o.civilian then
        world.append(b, "fleet_stance", "evasive")
    end
    world.append(b, "ship_class", o.ship_class or "shipclass_military")
    world.append(b, "space_fauna_growth_stance", "excessive")
    world.append(b, "mia_from", null_coord())
    local mm = {}
    local formation = {}
    world.append(formation, "scale", 1)
    world.append(formation, "angle", path().text(o.angle or 0))
    world.append(formation, "type", o.ship_class == "shipclass_starbase" and "circle" or "wedge")
    world.append(mm, "formation", formation)
    world.append(mm, "coordinate", coord_block(at))
    local target = {}
    world.append(target, "coordinate", null_coord())
    world.append(mm, "target", target)
    world.append(mm, "target_coordinate", null_coord())
    world.append(mm, "state", "move_idle")
    local p = {}
    world.append(p, "date", "0.01.01", true)
    world.append(mm, "path", p)
    world.append(mm, "orbit", {})
    local lj = {}
    world.append(lj, "from", null_coord())
    world.append(lj, "fleet", NO_ID)
    world.append(lj, "jump_method", "jump_count")
    world.append(lj, "bypass_from", NO_ID)
    world.append(lj, "bypass_to", NO_ID)
    world.append(mm, "last_ftl_jump", lj)
    world.append(b, "movement_manager", mm)
    local props = {}
    if o.civilian then
        world.append(props, "civilian", "yes")
    end
    if o.station then
        world.append(props, "station", "yes")
    else
        world.append(props, "mobile", "yes")
    end
    world.append(props, "valid_for_combat", "yes")
    if o.ship_class == "shipclass_constructor" then
        world.append(props, "can_construct_megastructures", "yes")
    end
    if o.civilian then
        world.append(props, "dirty_cloaking_strength", "yes")
    end
    world.append(b, "properties", props)
    world.append(b, "hit_points", "0.00000")
    world.append(b, "military_power", "0.00000")
    world.append(b, "diplomacy_weight", "0.00000")
    for _, k in ipairs({ "cached_killed_ships", "cached_disabled_ships", "cached_disengaged_ships", "cached_combined_removed_ships" }) do
        world.append(b, k, 0)
    end
    world.append(b, "commanding_armada", "none")
    create.place("fleet", id, entry, b)
    add_owned_fleet(o.country, id)
    S.fleets = S.fleets + 1
    return id
end

-- the fleet's name with its first ship (CFleet::CreateName 0x292b620): a military fleet a random
-- name of the country's list's fleet_names (one draw a try, a name another fleet of the country
-- has is drawn again), else the sequential one; a transport fleet TRANS_FLEET_NAME with the
-- country's adjective and a counter (not saved: 1 after a load); any other the ship's name
-- a transport fleet's name: TRANS_FLEET_NAME { COUNTRY = the country's name, NUMBER = the
-- country's next_transport_fleet_number (1 without it) }, the number + 1 written back (after
-- `variables`, the save's place) [I]
function create.transport_fleet_name(country)
    local c = world.object("country", country)
    local n = c and tonumber(world.field(c, "next_transport_fleet_number")) or 1
    if c then
        if world.field(c, "next_transport_fleet_number") ~= nil then
            world.set(c, "next_transport_fleet_number", n + 1)
        else
            local pos = #c + 1
            for i, e in ipairs(c) do
                if e.op and e.key and e.key.text == "variables" then pos = i + 1 end
            end
            world.insert(c, pos, "next_transport_fleet_number", n + 1)
        end
    end
    local cname = c and world.field(c, "name")
    local num = {}
    world.append(num, "key", tostring(n), true)
    world.append(num, "literal", "yes")
    return format_block("TRANS_FLEET_NAME", { var("COUNTRY", type(cname) == "table" and copy(cname) or key_block("")), var("NUMBER", num) })
end

local function fleet_name(fid, f, country, info, ship_name)
    if info.class == "shipclass_transport" then
        return create.transport_fleet_name(country)
    elseif info.class == "shipclass_military" then
        local _, _, list = name_lists(country, info.size)
        local fn = type(list) == "table" and defs.field(list, "fleet_names")
        local rn = type(fn) == "table" and defs.field(fn, "random_names")
        local names = {}
        for _, e in ipairs(type(rn) == "table" and rn or {}) do
            if e.text then names[#names + 1] = unq(e.text) end
        end
        if #names > 0 then
            local taken = {}
            for other, owner in pairs(world.fleet_owner) do
                if owner == country and other ~= fid then
                    local k = name_key(world.field(world.object("fleet", other), "name"))
                    if k then taken[k] = true end
                end
            end
            for _ = 1, #names + 1 do
                local k = names[draw() % #names + 1]
                if not taken[k] then
                    return key_block(k)
                end
            end
        end
        local seq = type(fn) == "table" and unq(defs.field(fn, "sequential_name"))
        if seq then
            local n = 1
            local used = {}
            for other, owner in pairs(world.fleet_owner) do
                if owner == country then
                    local nb = world.field(world.object("fleet", other), "name")
                    if type(nb) == "table" and name_key(nb) == "%SEQ%" then
                        for _, v in ipairs(blocks(world.field(nb, "variables"))) do
                            if name_key(v) == "num" then
                                used[tonumber(name_key(world.field(v, "value"))) or 0] = true
                            end
                        end
                    end
                end
            end
            while used[n] do n = n + 1 end
            local nb = {}
            world.append(nb, "key", "%SEQ%", true)
            local fmt = {}
            world.append(fmt, "key", seq, true)
            local nn = {}
            world.append(nn, "key", tostring(n), true)
            world.append(nb, "variables", { var("fmt", fmt), var("num", nn) })
            return nb
        end
        return key_block("MIL_FLEET_NAME")
    end
    return copy(ship_name)
end

-- the fleet template of a military fleet (CFleetTemplateManager::OnShipAdded 0x2a1b120 ->
-- CreateOrAddToTemplate): the fleet's own gets the design (count + 1, CFleetTemplate::AddDesign)
-- while its fleet_size stays within the command limit; a fleet without one gets a new template
-- (CGameState::CreateNewFleetTemplate) in the country's fleet_template_manager
local function command_limit(country)
    local M = country_mods(country)
    -- [I] NDefines COMMAND_LIMIT_BASE (50) with the country's command_limit_add and _mult
    return (50 + (M.command_limit_add or 0)) * (1 + (M.command_limit_mult or 0))
end

local function template_add(country, fid, f, info, did)
    local tid = tonumber(world.field(f, "fleet_template"))
    local t = tid and world.object("fleet_template", tid)
    if not t then
        local id, entry = create.allocate("fleet_template")
        t = {}
        world.append(t, "fleet", fid)
        local hb = {}
        local ob = {}
        local orb = world.path(f, "movement_manager", "orbit", "orbitable")
        if type(orb) == "table" then
            for _, e in ipairs(orb) do
                if e.op and e.key then world.append(ob, e.key.text, e.value.text) end
            end
        end
        world.append(hb, "orbitable", ob)
        world.append(t, "home_base", hb)
        world.append(t, "fleet_template_design", {})
        world.append(t, "all_queued", {})
        world.append(t, "fleet_size", 0)
        create.place("fleet_template", id, entry, t)
        -- the fleet's fleet_template, after its ships (the save's place)
        local pos = #f + 1
        for i, e in ipairs(f) do
            if e.op and e.key and e.key.text == "ships" then pos = i + 1 end
        end
        world.insert(f, pos, "fleet_template", id)
        local c = world.object("country", country)
        local mgr = c and world.child(c, "fleet_template_manager")
        if mgr then
            local list = world.field(mgr, "fleet_template")
            if type(list) ~= "table" then
                list = world.child(mgr, "fleet_template")
            end
            world.append_value(list, id)
        end
        S.templates = S.templates + 1
        tid = id
    end
    local size = tonumber(world.field(t, "fleet_size")) or 0
    if size + info.size_multiplier > command_limit(country) * 1 then
        return
    end
    local list = world.field(t, "fleet_template_design")
    if type(list) ~= "table" then
        list = world.child(t, "fleet_template_design")
    end
    for _, entry in ipairs(blocks(list)) do
        local sdi = world.field(entry, "ship_design_implementation")
        if type(sdi) == "table" and tonumber(world.field(sdi, "design")) == did and tonumber(world.field(sdi, "upgrade")) == NO_ID then
            local n = tonumber(world.field(entry, "count")) or 1
            world.set(entry, "count", n + 1)
            world.set(t, "fleet_size", size + info.size_multiplier)
            return
        end
    end
    local e = {}
    local sdi = {}
    world.append(sdi, "design", did)
    world.append(sdi, "upgrade", NO_ID)
    world.append(sdi, "growth_stage", 0)
    world.append(e, "ship_design_implementation", sdi)
    world.push(list, e)
    world.set(t, "fleet_size", size + info.size_multiplier)
end

-- on_actions through the script layer
local function on_action(name, this, from)
    S.on_actions = S.on_actions + 1
    local ok, e = pcall(function()
        local events = package.loaded["simscript.events"] or require("simscript.events")
        local eval = package.loaded["simscript.eval"] or require("simscript.eval")
        events.on_action(name, eval.S(this[1], this[2]), from and eval.new_ctx(eval.S(from[1], from[2])) or nil)
    end)
    if not ok then
        S.on_action_errors = S.on_action_errors + 1
        err(name .. ": " .. tostring(e))
    end
end
create.on_action = on_action

local function ship_ids(f)
    local out = {}
    for _, v in ipairs(world.list(world.field(f, "ships"))) do
        out[#out + 1] = tonumber(v)
    end
    return out
end

local function design_of_ship(sid)
    local s = world.object("ships", sid)
    local sdi = s and world.field(s, "ship_design_implementation")
    return type(sdi) == "table" and tonumber(world.field(sdi, "design")) or nil,
        type(sdi) == "table" and tonumber(world.field(sdi, "growth_stage")) or 0
end

function create.add_ship(fid, sid, opts)
    local f = world.object("fleet", fid)
    local s = world.object("ships", sid)
    if not f or not s then
        return false
    end
    local country = world.fleet_owner[fid]
    local did, stage = design_of_ship(sid)
    local info = create.design_info(did, stage) or { class = "shipclass_military", size_multiplier = 1, formation_priority = 0 }
    -- the ships by size: in front of the first ship of a lower formation priority (the fleet's
    -- ships kept largest first) [I]
    local list = world.field(f, "ships")
    if type(list) ~= "table" then
        list = world.child(f, "ships")
    end
    local pos = #list + 1
    for i, e in ipairs(list) do
        if e.text then
            local odid, ostage = design_of_ship(tonumber(e.text))
            local oi = odid and create.design_info(odid, ostage)
            if oi and (oi.formation_priority < info.formation_priority
                or (oi.formation_priority == info.formation_priority and oi.size_multiplier < info.size_multiplier)) then
                pos = i
                break
            end
        end
    end
    world.insert_value(list, pos, sid)
    local n = #ship_ids(f)
    live.touch("fleet", fid)
    world.set(s, "fleet", fid)
    world.set(s, "reserve", n - 1)
    -- the ship's post_move_angle: the fleet's formation angle [I] (the saves' new ships)
    local fa = world.path(f, "movement_manager", "formation", "angle")
    if fa ~= nil then
        world.set(s, "post_move_angle", fa)
    end
    -- the first ship: the fleet's ship class and its name
    if n == 1 then
        world.set(f, "ship_class", info.class)
        if world.field(f, "name") == nil then
            world.insert(f, 1, "name", fleet_name(fid, f, country, info, world.field(s, "name")))
        end
    end
    -- the fleet's hit points: + the ship's hull
    local hp = tonumber(world.field(s, "hitpoints")) or 0
    world.set(f, "hit_points", string.format("%.5f", (tonumber(world.field(f, "hit_points")) or 0) + hp))
    -- CFleetTemplateManager::OnShipAdded and the country's naval capacity used (a military ship)
    if country and not info.civilian and info.class == "shipclass_military" then
        template_add(country, fid, f, info, did)
        local c = world.object("country", country)
        if c then
            for _, k in ipairs({ "fleet_size", "used_naval_capacity" }) do
                local v = tonumber(world.field(c, k))
                if v then world.set(c, k, v + info.size_multiplier) end
            end
        end
    end
    -- NScriptUtil::OnShipEnterFleet (0x2957710): two draws, on_ship_enter_fleet
    if not (opts and opts.no_events) then
        draw()
        draw()
        on_action("on_ship_enter_fleet", { "fleet", fid }, { "ship", sid })
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- orbits

local function starbase_system(sbid)
    for _, sys in ipairs(world.all("galactic_object")) do
        for _, v in ipairs(world.list(world.field(world.object("galactic_object", sys), "starbases"))) do
            if tonumber(v) == sbid then return sys end
        end
    end
    return nil
end

local function station_coordinate(sbid)
    local sb = world.object("starbases", sbid)
    local st = sb and world.object("ships", tonumber(world.field(sb, "station")))
    local c = st and read_coord(world.field(st, "coordinate"))
    if c then
        return c
    end
    local sys = starbase_system(sbid)
    local g = sys and world.object("galactic_object", sys)
    local star = g and world.object("planet", tonumber(world.field(g, "planet")))
    local sc = star and read_coord(world.field(star, "coordinate"))
    if not sc then
        return nil
    end
    local d = math.floor((0.33 * (tonumber(world.field(star, "planet_size")) or 20) + 2.7 + 9) * FP + 0.5)
    return { x = sc.x + d, y = sc.y - d, origin = sc.origin }
end
create.station_coordinate = station_coordinate

-- an orbit slot's place [I], from the save's fleets in orbit: a starbase's slot k at the station's
-- place + (-1 + 2 floor(k / 4), -1 + 2 (k % 4)); a planet's slot 0 at + (0.33 size + 2.7) on both
-- axes, the others turned by 90 degrees (engine.fleets.orders' rule)
function create.orbit_coordinate(kind, id, slot)
    if kind == "starbase" then
        local c = station_coordinate(id)
        if not c then
            return nil
        end
        return { x = c.x + (-1 + 2 * math.floor(slot / 4)) * FP, y = c.y + (-1 + 2 * (slot % 4)) * FP, origin = c.origin }
    end
    local p = world.object("planet", id)
    local c = p and read_coord(world.field(p, "coordinate"))
    if not c then
        return nil
    end
    local d = math.floor((0.33 * (tonumber(world.field(p, "planet_size")) or 10) + 2.7) * FP + 0.5)
    local dirs = { { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }
    local dir = dirs[(slot or 0) % 4 + 1]
    return { x = c.x + dir[1] * d, y = c.y + dir[2] * d, origin = c.origin }
end

-- the orbit's own place for a new ship (CFleetOrbitalSlotHandle::GetOrbitalCoordinateInternal):
-- a starbase's station place, a planet's
function create.orbital_coordinate(kind, id)
    if kind == "starbase" then
        return station_coordinate(id)
    end
    local p = world.object("planet", id)
    return p and read_coord(world.field(p, "coordinate"))
end

local function slots_block(kind, id)
    local o = world.object(kind == "starbase" and "starbases" or "planet", id)
    if not o then
        return nil
    end
    local key = kind == "starbase" and "orbitals" or "planet_orbitals"
    local b = world.field(o, key)
    if type(b) ~= "table" then
        b = world.child(o, key)
    end
    return b
end

function create.enter_orbit(fid, kind, id, opts)
    local f = world.object("fleet", fid)
    local mm = f and world.field(f, "movement_manager")
    local slots = slots_block(kind, id)
    if type(mm) ~= "table" or not slots then
        return nil
    end
    live.touch("fleet", fid)
    world.wrote(slots)
    -- the first free slot: no entry, or one that holds no fleet (4294967295, a fleet gone)
    local used, entry_of = {}, {}
    for _, e in ipairs(slots) do
        local k = e.op and e.key and tonumber(e.key.text)
        if k then
            entry_of[k] = e
            local v = tonumber(e.value.text)
            if v and v ~= NO_ID and world.object("fleet", v) then used[k] = true end
        end
    end
    local slot = 0
    while used[slot] do slot = slot + 1 end
    if entry_of[slot] then
        world.set_entry(slots, entry_of[slot], fid)
    else
        -- in the slots' order
        local pos = #slots + 1
        for i, e in ipairs(slots) do
            if (tonumber(e.key and e.key.text) or 0) > slot then
                pos = i
                break
            end
        end
        world.insert(slots, pos, tostring(slot), fid)
    end
    -- CFleet::CalcCanRepairFromOrbit [I]: in orbit of a starbase above an outpost
    if kind == "starbase" then
        local sb = world.object("starbases", id)
        local level = sb and tostring(world.field(sb, "level") or ""):gsub('"', "")
        local props = world.field(f, "properties")
        if level and level ~= "starbase_level_outpost" and type(props) == "table" and world.field(props, "can_orbitable_repair_ships") == nil then
            world.append(props, "can_orbitable_repair_ships", "yes")
        end
    end
    local o = world.field(mm, "orbit")
    if type(o) ~= "table" then
        o = world.child(mm, "orbit")
    end
    world.replace(o, {})
    local ob = {}
    world.append(ob, kind, id)
    world.append(o, "orbitable", ob)
    world.append(o, "index", slot)
    local at = create.orbit_coordinate(kind, id, slot)
    if at then
        local c = world.field(mm, "coordinate")
        if type(c) == "table" then
            local P = path()
            world.set(c, "x", P.text(at.x))
            world.set(c, "y", P.text(at.y))
            world.set(c, "origin", at.origin)
        end
        local cc = world.path(f, "combat", "coordinate")
        if type(cc) == "table" then world.set(cc, "origin", at.origin) end
        -- facing the starbase's station [I] (a planet's orbit: 0, as the saves' new transports)
        local to = kind == "starbase" and create.orbital_coordinate(kind, id) or nil
        local formation = world.field(mm, "formation")
        if to and type(formation) == "table" then
            local a = math.atan2(-(to.x - at.x), to.y - at.y)
            world.set(formation, "angle", path().text(math.floor(a * FP + 0.5)))
        end
        -- the system's fleet_presence
        local g = world.object("galactic_object", at.origin)
        if g then
            local fpres = world.field(g, "fleet_presence")
            if type(fpres) ~= "table" then
                fpres = world.child(g, "fleet_presence")
            end
            world.append_value(fpres, fid)
        end
    end
    S.orbits = S.orbits + 1
    -- CFleet::OnEnteredOrbit: three draws
    if not (opts and opts.no_draws) then
        draw()
        draw()
        draw()
    end
    return slot, at
end

-- the ships of a fleet in orbit there, in the save's fleet order
local function fleets_in_orbit(kind, id)
    local out = {}
    local slots = slots_block(kind, id)
    for _, e in ipairs(slots or {}) do
        if e.op and e.key and e.value.text then
            out[#out + 1] = tonumber(e.value.text)
        end
    end
    return out
end

-- NFleet::CanMergeShipWithFleet (0x29176c0): the fleet has ships, is the country's (owner and
-- controller), not civilian, not a station, not a transport fleet; the ship a military one [I]
function create.find_merge_fleet(country, kind, id, info)
    if info.civilian or info.class ~= "shipclass_military" then
        return nil
    end
    for _, fid in ipairs(fleets_in_orbit(kind, id)) do
        local f = world.object("fleet", fid)
        if f and world.fleet_owner[fid] == country and #ship_ids(f) > 0
            and world.field(f, "ship_class") == "shipclass_military" then
            local props = world.field(f, "properties")
            if not (type(props) == "table" and (world.field(props, "civilian") == "yes" or world.field(props, "station") == "yes")) then
                return fid
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- the shipyard's ship

function create.around_orbital(o)
    local kind, id = o.orbitable.kind, o.orbitable.id
    local info = create.design_info(o.design)
    if not info then
        return nil, nil, "no design " .. tostring(o.design)
    end
    -- CreateShipAroundOrbital (0x219ad80): CreateNewShip, at the orbital's place, rotation pi
    local at = create.orbital_coordinate(kind, id)
    local sid = create.ship{ country = o.country, design = o.design, coordinate = at, date = o.date }
    if not sid then
        return nil
    end
    local fid = create.find_merge_fleet(o.country, kind, id, info)
    local merged = fid ~= nil
    if not fid then
        -- CreateFleetAroundOrbital (0x219aee0): CreateNewFleet, SetIsCivilian, EnterOrbitInternal
        fid = create.fleet{ country = o.country, ship_class = info.class, civilian = info.civilian, coordinate = at }
        local _, slot_at = create.enter_orbit(fid, kind, id)
        -- the ship goes to the fleet's place (CFleet::AddShip: its first ship)
        local s = world.object("ships", sid)
        if slot_at and s then
            local P = path()
            for _, k in ipairs({ "coordinate", "target_coordinate" }) do
                local c = world.field(s, k)
                if type(c) == "table" then
                    world.set(c, "x", P.text(slot_at.x))
                    world.set(c, "y", P.text(slot_at.y))
                end
            end
        end
    else
        S.merged = S.merged + 1
    end
    create.add_ship(fid, sid)
    return sid, fid, merged
end

function create.on_ship_built(sid, orbitable)
    draw()
    draw()
    on_action("on_ship_built", { "ship", sid }, orbitable and { orbitable.kind, orbitable.id } or nil)
end

-- a station's ship and its fleet (no merge, no on_ship_built): for engine.fleets.stations
function create.station(o)
    local info = create.design_info(o.design)
    if not info then
        return nil
    end
    local sid = create.ship{ country = o.country, design = o.design, coordinate = o.coordinate, date = o.date, name = o.name }
    local fid = create.fleet{ country = o.country, ship_class = o.ship_class or info.class, civilian = info.civilian,
                              station = true, coordinate = o.coordinate }
    if o.orbit then
        create.enter_orbit(fid, o.orbit.kind, o.orbit.id)
    end
    create.add_ship(fid, sid)
    return sid, fid
end

function create.report()
    return string.format("fleets.create: %d ships, %d fleets (%d ships merged into a fleet), %d templates, %d orbits entered; %d draws (%d name tries), %d on_actions (%d errors)%s",
        S.ships, S.fleets, S.merged, S.templates, S.orbits, S.draws, S.name_tries, S.on_actions, S.on_action_errors,
        #create.errors > 0 and ("; first error: " .. create.errors[1]) or "")
end

return create
