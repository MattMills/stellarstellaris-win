-- render/windows/starbase_data.lua : what the starbase window shows (interface/starbase_view.gui;
-- docs/windows/starbase.md), read from the world (engine.world, a save's gamestate) and the game's
-- files where galaxy.lua runs (the save's runtime, or the simulation's thread), and carried to the
-- front end's runtime as a Lua chunk (Galaxy::starbases) that render.windows.starbase lays out.
--
--   local data = require("render.windows.starbase_data")
--   local chunk = data.extract(game_dir)   -- "return { [fleet id] = { ... }, ... }"
--
-- One entry a starbase, keyed by its station's fleet (what the map and the outliner select):
--   id, fleet, owner, system, level, size (the level's ship size), next_size, name (a name block),
--   picture, modules / buildings ({ { slot, key, icon, frame } }, slot from 1), module_slots /
--   building_slots (the level's slots: CStarbase::GetMaxModuleCapacity), module_capacity /
--   building_capacity (the starbase_*_capacity_add of its station modifiers: CStarbase +0x14e0),
--   hyperlane, sensor, detection, queue ({ { kind, key, progress, needed, days } }), shipyard,
--   hatchery, beastport, has_sector, orbitals, platforms, platform_capacity, design, uses_design,
--   occupied, mobile, waystation, planet (its system has a colony of its owner)

local world = require("engine.world")
local source = require("stellar.script.source")

local M = {}

local function unq(v)
    if v == nil then
        return nil
    end
    return (tostring(v):gsub('"', ""))
end

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a field that is one token or a block of them (construction_type = x / { x y })
local function defs_list(v)
    if type(v) == "string" then
        return { unq(v) }
    end
    local out = {}
    for _, e in ipairs(type(v) == "table" and v or {}) do
        if e.text then
            out[#out + 1] = unq(e.text)
        end
    end
    return out
end

local function galaxy_name(block)
    return block and require("render.galaxy").name_block(block) or nil
end

local function list_of(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = unq(e.text)
        end
    end
    return out
end

-- the game's definitions of a folder, with each file's scripted variables (`@name = value`)
local defs_cache = {}
local function defs(game_dir, folder)
    local d = defs_cache[folder]
    if d == nil then
        d = { by = source.definitions(game_dir, folder) or {}, vars = {} }
        defs_cache[folder] = d
    end
    return d
end

local file_vars = {}
local function vars_of(game_dir, file)
    local v = file_vars[file]
    if v == nil then
        v = {}
        local tree = file and source.parse(game_dir, file)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                v[e.key.text] = tonumber(e.value.text)
            end
        end
        file_vars[file] = v
    end
    return v
end

local global_vars
local function number(game_dir, def, v)
    if type(v) ~= "string" and type(v) ~= "number" then
        return nil
    end
    local n = tonumber(v)
    if n then
        return n
    end
    v = tostring(v)
    if v:sub(1, 1) == "@" then
        local fv = def and vars_of(game_dir, def.file) or {}
        if fv[v] then
            return fv[v]
        end
        if global_vars == nil then
            global_vars = {}
            for _, f in ipairs(source.files(game_dir, "common/scripted_variables", "txt") or {}) do
                for k, x in pairs(vars_of(game_dir, f)) do
                    global_vars[k] = x
                end
            end
        end
        return global_vars[v]
    end
    return nil
end

-- the sum of a modifier type over the blocks `key` of a definition (`station_modifier = { ... }`)
local function modifier(game_dir, def, key, mtype)
    local total = 0
    if def == nil then
        return 0
    end
    for _, e in ipairs(def.block) do
        if e.op and e.key and e.key.text == key and type(e.value) == "table" and e.value.text == nil then
            total = total + (number(game_dir, def, field(e.value, mtype)) or 0)
        end
    end
    return total
end

local function count(block)
    local n = 0
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            n = n + 1
        end
    end
    return n
end

-- a level's picture (CStarbaseLevelType::GetPicture: its `picture`, the first whose trigger holds;
-- GFX_starbase_background without one). The triggers are not evaluated: a plain picture is used,
-- a conditional one (bio ships) is not [I].
local function picture(level)
    for _, e in ipairs(level and level.block or {}) do
        if e.op and e.key and e.key.text == "picture" then
            if e.value.text then
                return unq(e.value.text)
            end
        end
    end
    return "GFX_starbase_background"
end

-- the components of a design's growth stage (required_component and the sections' components)
local function design_components(stage)
    local out = {}
    for _, e in ipairs(type(stage) == "table" and stage or {}) do
        if e.op and e.key then
            if e.key.text == "required_component" and e.value.text then
                out[#out + 1] = unq(e.value.text)
            elseif e.key.text == "section" and type(e.value) == "table" then
                for _, c in ipairs(e.value) do
                    if c.op and c.key and c.key.text == "component" and type(c.value) == "table" then
                        out[#out + 1] = unq(field(c.value, "template"))
                    end
                end
            end
        end
    end
    return out
end

-- the component templates by key (common/component_templates: `key = "SENSOR_1"` in blocks with no
-- name of their own)
local templates
local function component(game_dir, key)
    if templates == nil then
        templates = {}
        for _, f in ipairs(source.files(game_dir, "common/component_templates", "txt") or {}) do
            for _, e in ipairs(source.parse(game_dir, f) or {}) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    local k = unq(field(e.value, "key"))
                    if k then
                        templates[k] = { block = e.value, file = f }
                    end
                end
            end
        end
    end
    return templates[key]
end

-- the construction queue items by queue id (the store construction.item_mgr.items), in id order
local item_id = setmetatable({}, { __mode = "k" })   -- an item's block -> its id
local function queue_items()
    local by = {}
    local store = world.stores["construction.item_mgr.items"] or {}
    for _, id in ipairs(world.ids["construction.item_mgr.items"] or {}) do
        local item = store[id]
        local q = item and tonumber(field(item, "queue"))
        if q then
            local l = by[q] or {}
            by[q] = l
            l[#l + 1] = item
            item_id[item] = id
        end
    end
    return by
end

local function queue_entry(item)
    local out = {
        id = item_id[item],
        progress = tonumber(field(item, "progress")) or 0,
        needed = tonumber(field(item, "progress_needed")) or 0,
    }
    for _, e in ipairs(item) do
        local k = e.op and e.key and e.key.text
        if k and k:match("^buildable_") and type(e.value) == "table" then
            out.kind = k:sub(11)
            local b = e.value
            if out.kind == "ship" then
                local did = tonumber(world.path(b, "ship_design_implementation", "design"))
                local d = did and world.object("ship_design", did)
                local stage = d and world.blocks(world.field(d, "growth_stages"))[1]
                out.key = stage and unq(world.field(stage, "ship_size")) or ""
                out.design = d and require("render.galaxy").name_block(world.field(d, "name")) or nil
            elseif out.kind == "starbase_upgrade" then
                out.key = unq(field(b, "starbase_upgrade"))
            elseif out.kind == "starbase_module" then
                out.key = unq(field(b, "starbase_module") or field(b, "module"))
                out.slot = tonumber(field(b, "slot"))
            elseif out.kind == "starbase_building" then
                out.key = unq(field(b, "starbase_building") or field(b, "building"))
                out.slot = tonumber(field(b, "slot"))
            else
                out.key = unq(field(b, out.kind) or "")
            end
        end
    end
    return out
end

-- M.starbases(game_dir) -> { [fleet id] = entry }
function M.starbases(game_dir)
    local levels = defs(game_dir, "common/starbase_levels").by
    local sizes = defs(game_dir, "common/ship_sizes").by
    local mods = defs(game_dir, "common/starbase_modules").by
    local blds = defs(game_dir, "common/starbase_buildings").by
    local types = defs(game_dir, "common/starbase_types").by
    local galaxy = require("render.galaxy")
    local queues = queue_items()

    -- the DLCs the save was made with (required_dlcs): the cloaking row needs First Contact
    -- (CStarbaseStarbaseTabController::Setup: NGameDLC::IsEnabled(0x400000), DLC_FIRST_CONTACT)
    local first_contact = false
    for _, d in ipairs(list_of(world.meta.required_dlcs)) do
        if d:find("First Contact", 1, true) then
            first_contact = true
        end
    end
    -- the countries' technologies (country.tech_status.technology), for the upgrade button
    local techs = {}
    local function has_tech(country, tech)
        local t = techs[country]
        if t == nil then
            t = {}
            local c = world.object("country", country)
            local ts = c and world.field(c, "tech_status")
            for _, k in ipairs(type(ts) == "table" and world.fields(ts, "technology") or {}) do
                t[unq(k)] = true
            end
            techs[country] = t
        end
        return t[tech] == true
    end
    -- the fleets by system (the shipyard tab's fleets in orbit [I]: the owner's fleets in the
    -- starbase's system, the stations left out)
    local fleets_at = {}
    for _, fid in ipairs(world.all("fleet")) do
        local f = world.object("fleet", fid)
        local sys = f and tonumber(world.path(f, "movement_manager", "coordinate", "origin"))
        if sys and world.path(f, "properties", "station") ~= "yes" and #world.list(world.field(f, "ships")) > 0 then
            local l = fleets_at[sys] or {}
            fleets_at[sys] = l
            local first = world.object("ship", tonumber(world.list(world.field(f, "ships"))[1]))
            local fd = first and tonumber(world.path(first, "ship_design_implementation", "design"))
            local d = fd and world.object("ship_design", fd)
            local st = d and world.blocks(world.field(d, "growth_stages"))[1]
            l[#l + 1] = { id = fid, owner = (world.fleet_owner or {})[fid] or -1, name = galaxy.name_block(world.field(f, "name")),
                ships = #world.list(world.field(f, "ships")), military = (tonumber(world.field(f, "military_power")) or 0) > 0,
                size = st and unq(world.field(st, "ship_size")) or nil }
        end
    end
    -- the starbases' systems (galactic_object.starbases)
    local system_of = {}
    for _, gid in ipairs(world.all("system")) do
        local g = world.object("system", gid)
        for _, sb in ipairs(world.list(g and world.field(g, "starbases"))) do
            system_of[tonumber(sb)] = gid
        end
    end
    -- the sectors' systems (the army hub tab: STARBASE_NO_SECTOR), and each sector's colonies
    local in_sector, sector_of = {}, {}
    for _, sid in ipairs(world.all("sector")) do
        local s = world.object("sector", sid)
        for _, v in ipairs(world.list(s and world.field(s, "systems"))) do
            in_sector[tonumber(v)] = true
            sector_of[tonumber(v)] = sid
        end
    end
    local sector_colonies, system_colonies = {}, {}
    for pid in pairs(world.planet_colony or {}) do
        local p = world.object("planet", pid)
        local sys = p and tonumber(world.path(p, "coordinate", "origin"))
        local sid = sys and sector_of[sys]
        if sid then
            sector_colonies[sid] = (sector_colonies[sid] or 0) + 1
        end
        if sys then
            system_colonies[sys] = (system_colonies[sys] or 0) + 1
        end
    end

    local out = {}
    for _, id in ipairs(world.all("starbase")) do
        local sb = world.object("starbase", id)
        local station = sb and tonumber(world.field(sb, "station"))
        local ship = station and world.object("ship", station)
        local fid = ship and tonumber(world.field(ship, "fleet"))
        local fleet = fid and world.object("fleet", fid)
        if fleet then
            local level_key = unq(world.field(sb, "level")) or ""
            local level = levels[level_key]
            local size_key = level and unq(field(level.block, "ship_size")) or ""
            local size = sizes[size_key]
            local next_key = level and unq(field(level.block, "next_level"))
            local next_level = next_key and levels[next_key]
            local e = {
                id = id, fleet = fid, level = level_key, size = size_key,
                next_level = next_key, next_size = next_level and unq(field(next_level.block, "ship_size")) or nil,
                owner = (world.fleet_owner or {})[fid] or tonumber(world.field(fleet, "owner")) or -1,
                system = system_of[id] or tonumber(world.path(fleet, "movement_manager", "coordinate", "origin")) or -1,
                name = galaxy.name_block(world.field(ship, "name")),
                picture = picture(level),
                type = unq(world.field(sb, "type")) or "",
                modules = {}, buildings = {}, queue = {},
                mobile = world.path(fleet, "properties", "mobile") == "yes",
                occupied = world.field(sb, "occupier") ~= nil,
            }
            -- the grids' slots: CStarbase::GetMaxModuleCapacity / GetMaxBuildingCapacity (CStarbase
            -- +0x890's +0x118, +0x11c), as many as the highest level of its line has (the game's
            -- frame: a starport shows 6 module and 4 building slots, a citadel's) [I]
            e.module_slots, e.building_slots = 0, 0
            local l, seen = level, {}
            while l and not seen[l] do
                seen[l] = true
                e.module_slots = math.max(e.module_slots, count(field(l.block, "module_slots")))
                e.building_slots = math.max(e.building_slots, count(field(l.block, "building_slots")))
                local nk = unq(field(l.block, "next_level"))
                l = nk and levels[nk]
            end
            local td = e.type ~= "" and types[e.type]
            e.waystation = td and field(td.block, "is_waystation") == "yes" or false
            -- the station modifiers: the level's ship size's `modifier`, the modules' and buildings'
            -- station_modifier (CStarbase::RecalcStationModifier; the triggered ones and the
            -- country's are not added) [I]
            -- with the simulation running, its modifier node (engine.economy's source: the node's own
            -- values and its parents', the country's civics and edicts among them) [V for what the
            -- node holds]; a save read alone has no node: the parts are summed
            local econ = package.loaded["engine.economy"]
            local node = econ and econ.has_modifier_source() and econ.modifiers("starbase", id) or nil
            local function station_mod(mtype)
                if node then
                    return node[mtype] or 0
                end
                local v = modifier(game_dir, size, "modifier", mtype)
                for _, m in ipairs(e.modules) do
                    v = v + modifier(game_dir, mods[m.key], "station_modifier", mtype)
                end
                for _, b in ipairs(e.buildings) do
                    v = v + modifier(game_dir, blds[b.key], "station_modifier", mtype)
                end
                return v
            end
            for _, part in ipairs({ { "modules", mods, e.modules }, { "buildings", blds, e.buildings } }) do
                for _, x in ipairs(world.field(sb, part[1]) or {}) do
                    if x.op and x.key and x.value.text then
                        local key = unq(x.value.text)
                        local d = part[2][key]
                        part[3][#part[3] + 1] = {
                            slot = (tonumber(x.key.text) or #part[3]) + 1, key = key,
                            icon = d and unq(field(d.block, "icon")) or ("GFX_" .. key),
                            frame = d and tonumber(field(d.block, "icon_frame")) or 1,
                        }
                    end
                end
            end
            -- CStarbase::IsShipyard: CanBuildShips (a shipyard queue [I]) and its construction type
            -- (+0x888, the save's construction_type) the shipyard's; IsHatchery the hatchery's or the
            -- beastport's (0x4 | 0x8: the shipyard tab's text, STARBASE_HATCHERY_TAB, _BEASTPORT_TAB)
            local ctype = unq(world.field(sb, "construction_type")) or ""
            local can_build = (tonumber(world.field(sb, "shipyard_build_queue")) or 4294967295) ~= 4294967295
            e.shipyard = can_build and ctype == "starbase_shipyard"
            e.hatchery = can_build and ctype:find("hatchery", 1, true) ~= nil
            e.beastport = can_build and ctype:find("beastport", 1, true) ~= nil
            e.module_capacity = math.floor(station_mod("starbase_module_capacity_add") + 0.5)
            e.building_capacity = math.floor(station_mod("starbase_building_capacity_add") + 0.5)
            e.platform_capacity = math.floor(station_mod("starbase_defense_platform_capacity_add") + 0.5)
            e.shipyard_capacity = math.floor(station_mod("starbase_shipyard_capacity_add") + 0.5)
            -- the station's design: its sensor component's ranges (CStarbase::GetHyperlaneRange: the
            -- starbase's sensor value + the ship size's hyperlane modifier; GetSensorRange: the
            -- sensor range + ship_sensor_range_add) [I]: the component of the design, not its
            -- upgrades
            local impl = world.field(ship, "ship_design_implementation")
            local did = type(impl) == "table" and tonumber(world.field(impl, "design"))
            local design = did and world.object("ship_design", did)
            local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
            local sensor, hyper = 0, 0
            for _, c in ipairs(design_components(stage)) do
                local t = component(game_dir, c)
                if t then
                    sensor = math.max(sensor, number(game_dir, t, field(t.block, "sensor_range")) or 0)
                    hyper = math.max(hyper, number(game_dir, t, field(t.block, "hyperlane_range")) or 0)
                end
            end
            e.sensor = math.floor(sensor + station_mod("ship_sensor_range_add") + 0.5)
            e.hyperlane = math.floor(hyper + station_mod("ship_hyperlane_range_add") + 0.5)
            e.detection = math.floor(station_mod("ship_cloaking_detection_add") + 0.5)
            e.design = design and galaxy.name_block(world.field(design, "name")) or nil
            -- a designed starbase (the growth stage's flag 0x2: CStarbaseAbstractStarbaseTabController::
            -- Update shows design_info instead of modules_info) [I]: its size is_designable (the
            -- game's frame: a deep space citadel shows its design, an enclave its empty modules)
            e.uses_design = size ~= nil and field(size.block, "is_designable") == "yes"
            e.first_contact = first_contact
            -- the upgrade's command valid (CAddBuildableToQueueCommand::IsValid) [I]: the next
            -- size's prerequisites researched, no upgrade queued
            local ns = e.next_size and sizes[e.next_size]
            local ok = ns ~= nil
            for _, t in ipairs(ns and list_of(field(ns.block, "prerequisites")) or {}) do
                ok = ok and has_tech(e.owner, t)
            end
            e.upgrade_ok = ok
            -- the build queue (CStarbase::GetMainBuildQueueRef: `build_queue`), the shipyard's
            for _, q in ipairs({ { "queue", "build_queue" }, { "ship_queue", "shipyard_build_queue" } }) do
                local list = {}
                for _, item in ipairs(queues[tonumber(world.field(sb, q[2])) or -1] or {}) do
                    local qe = queue_entry(item)
                    -- an upgrade's level: its ship size (the entry's "Upgrade to <size>")
                    local ql = qe.kind == "starbase_upgrade" and qe.key and levels[qe.key]
                    qe.next_size = ql and unq(field(ql.block, "ship_size")) or nil
                    -- a ship's size civilian (its entry's second line: the size's name, else the
                    -- design's "<name>-class")
                    local qs = qe.kind == "ship" and sizes[qe.key or ""]
                    qe.civilian = qs and field(qs.block, "is_civilian") == "yes" or false
                    -- the item's speed (engine.construction.speed: the starbase's mults) for the
                    -- days left
                    local M = node or {}
                    if qe.kind == "ship" then
                        qe.speed = 1 + (M.starbase_shipyard_artificial_build_speed_mult or 0) + (M.starbase_shipyard_build_speed_mult or 0)
                            + (M["shipsize_" .. tostring(qe.key) .. "_build_speed_mult"] or 0)
                    elseif qe.kind == "starbase_upgrade" then
                        qe.speed = 1 + (M.starbase_upgrade_speed_mult or 0)
                    elseif qe.kind == "starbase_module" then
                        qe.speed = 1 + (M.starbase_module_build_speed_mult or 0)
                    elseif qe.kind == "starbase_building" then
                        qe.speed = 1 + (M.starbase_building_build_speed_mult or 0)
                    end
                    list[#list + 1] = qe
                end
                e[q[1]] = list
            end
            -- the orbitals (defense platforms and the like: `orbitals`, 4294967295 an empty slot)
            local orbitals = {}
            for _, x in ipairs(world.field(sb, "orbitals") or {}) do
                local v = x.op and tonumber(x.value.text)
                if v and v ~= 4294967295 then
                    orbitals[#orbitals + 1] = v
                end
            end
            -- the defense platforms: the station fleet's other ships [I]
            e.platforms = math.max(0, #world.list(world.field(fleet, "ships")) - 1)
            e.station_ship = station
            -- the defense platforms' list (the station fleet's other ships: their names)
            e.platform_list = {}
            for _, v in ipairs(world.list(world.field(fleet, "ships"))) do
                local sid = tonumber(v)
                local ps = sid and sid ~= station and world.object("ship", sid)
                if ps then
                    e.platform_list[#e.platform_list + 1] = { id = sid, name = galaxy.name_block(world.field(ps, "name")) }
                end
            end
            e.orbitals = orbitals
            e.has_sector = in_sector[e.system] or false
            e.sector_planets = sector_of[e.system] and sector_colonies[sector_of[e.system]] or 0
            -- the waystation window's colonies of the system and owner's name
            e.colonies = system_colonies[e.system] or 0
            local oc = world.object("country", e.owner)
            e.owner_name = oc and galaxy.name_block(world.field(oc, "name")) or nil
            -- the shipyard's modifiers (CShipyardModifierGridController) from the station's own
            -- parts [I]: the country's and the system's shares are not added
            e.shipyard_mods = {
                { type = "starbase_shipyard_build_cost_mult", value = station_mod("starbase_shipyard_build_cost_mult"), good_negative = true },
                { type = "starbase_shipyard_build_speed_mult", value = station_mod("starbase_shipyard_build_speed_mult") },
                { type = "starbase_shipyard_build_time_mult", value = station_mod("starbase_shipyard_build_time_mult"), good_negative = true },
            }
            -- the planet button: CStarbase::GetPlanet, a starbase tied to a planet (an orbital ring);
            -- the save's `planet` [I]
            e.planet = tonumber(world.field(sb, "planet"))
            e.fleets = {}
            for _, f in ipairs(fleets_at[e.system] or {}) do
                if f.owner == e.owner then
                    e.fleets[#e.fleets + 1] = f
                end
            end
            out[fid] = e
        end
    end
    return out
end

-- the side view's catalogs (CStarbaseSideView) of a starbase, where the simulation's engine is (its
-- definitions, economy, script layer; nil without it):
--   ships, defenses: the owner's designs a shipyard / the build queue can build
--     (CBuildableShipListController::Update: each design of the country's collection whose
--     CShipDesign::CanBuildAtPotential holds: the size's construction types hold the queue's
--     (starbase_shipyard, the beastport's; starbase_defenses), its prerequisites researched, its
--     potential_construction trigger (CShipSize::IsPotentialForConstruction) [I: the culture's
--     sizes and the design's allow_buildable_trigger not checked]), sorted as SShipyardEntrySorter:
--     civilian first, then the size's size_multiplier (SSortShipSizeBySizeMultiplier), then the
--     size's place in the files [I], then the collection's order; each with its cost and build
--     time at this starbase (engine.ai.shipbuilding: CalcCost, CalcBuildTime)
--   modules, buildings: the definitions whose potential holds for the starbase (the side view's
--     CStarbaseBuildableComponentEntry list), in the files' order [I]; `possible` false: greyed
-- the special buildable designs (is_special_buildable: the global designs the save carries), found
-- once per world
local specials, specials_of
local function special_designs()
    local ids = world.ids and world.ids[world.KINDS and world.KINDS.ship_design or "ship_design"] or world.all("ship_design")
    if specials_of ~= ids or specials == nil then
        specials, specials_of = {}, ids
        for _, did in ipairs(world.all("ship_design")) do
            local d = world.object("ship_design", did)
            if d and world.field(d, "is_special_buildable") == "yes" then
                specials[#specials + 1] = did
            end
        end
    end
    return specials
end

local function catalog(e)
    local edefs = package.loaded["engine.defs"]
    local econ = package.loaded["engine.economy"]
    if not (edefs and econ and edefs.folders and next(edefs.folders)) then
        return nil
    end
    local C = require("engine.fleets.create")
    local sbm = require("engine.ai.shipbuilding")
    local cmds = require("render.windows.starbase_commands")
    local eval = require("simscript.eval")
    local owner = e.owner
    local ctx = eval.new_ctx(eval.S("starbase", e.id), eval.S("country", owner), nil, "starbase side view")
    -- a trigger: true, false, or (an error, a keyword the script layer does not implement yet:
    -- simscript.eval's stats.missing grew) unknown, taken as holding [I]
    local function misses()
        local n = 0
        for _, m in pairs(eval.stats and eval.stats.missing or {}) do
            n = n + (m.count or 0)
        end
        return n
    end
    local function holds(block)
        if type(block) ~= "table" then
            return true
        end
        local before = misses()
        local ok, r = pcall(eval.trigger, block, ctx)
        return not ok or misses() > before or r == true
    end
    local Mods = econ.modifiers("starbase", e.id) or {}
    local order = econ.resources or {}
    local function cost_list(t)
        local out = {}
        for _, r in ipairs(order) do
            local v = t and t[r]
            if v and v ~= 0 then
                out[#out + 1] = { res = r, value = v }
            end
        end
        return out
    end
    local c = world.object("country", owner)
    local techs = {}
    local ts = c and world.field(c, "tech_status")
    for _, k in ipairs(type(ts) == "table" and world.fields(ts, "technology") or {}) do
        techs[unq(k)] = true
    end
    -- the queue types: the shipyard's (its construction type: shipyard, beastport) and the defenses'
    local yard = { starbase_shipyard = e.shipyard, starbase_beastport = e.beastport }
    local out = { ships = {}, defenses = {}, modules = {}, buildings = {}, stock = {} }
    -- the owner's stockpile (an entry it cannot pay for is greyed)
    local module = c and world.path(c, "modules", "standard_economy_module")
    local res = type(module) == "table" and world.child(module, "resources") or nil
    for _, r in ipairs(order) do
        out.stock[r] = res and tonumber(world.field(res, r)) or 0
    end
    -- the designs: the country's collection, then the special buildable ones (global designs:
    -- `is_special_buildable`) whose allow_buildable_trigger, a scripted trigger, holds for the
    -- country (CShipDesign::CanCountryBuildPotential: "ship_design.<name>.allow_buildable_trigger")
    local coll = c and world.path(c, "ship_design_collection", "ship_design")
    local candidates = {}
    for _, v in ipairs(world.list(coll)) do
        candidates[#candidates + 1] = tonumber(v)
    end
    local cctx = eval.new_ctx(eval.S("country", owner), eval.S("country", owner), nil, "ship design")
    for _, did in ipairs(special_designs()) do
        local d = world.object("ship_design", did)
        local trig = d and unq(world.field(d, "allow_buildable_trigger"))
        local ok = trig == nil
        if trig then
            local okk, r = pcall(eval.trigger, { { op = "=", key = { text = trig }, value = { text = "yes" } } }, cctx)
            ok = okk and r == true
        end
        if ok then
            candidates[#candidates + 1] = did
        end
    end
    for n, did in ipairs(candidates) do
        local info = did and C.design_info(did)
        local sd = info and info.size_block
        if sd then
            local cts = defs_list(edefs.field(sd, "construction_type"))
            local kind
            for _, ct in ipairs(cts) do
                if yard[ct] then kind = "ships" end
                if ct == "starbase_defenses" then kind = "defenses" end
            end
            local ok = kind ~= nil
            for _, t in ipairs(ok and list_of(edefs.field(sd, "prerequisites")) or {}) do
                ok = ok and techs[t] == true
            end
            ok = ok and holds(edefs.field(sd, "potential_construction"))
            if ok then
                local d = edefs.get("common/ship_sizes", info.size)
                local okc, cost = pcall(sbm.ship_table, owner, did, "cost", Mods)
                local okt, time = pcall(sbm.build_time, did, Mods)
                -- the days shown: the build time over the item's speed (construction.speed: 1 +
                -- the shipyard's, the artificial ships' and the size's build speed mults), whole
                -- days down (the game's frame: 54 for 60 at +10%)
                local speed = 1 + (Mods.starbase_shipyard_artificial_build_speed_mult or 0) + (Mods.starbase_shipyard_build_speed_mult or 0)
                    + (Mods["shipsize_" .. tostring(info.size) .. "_build_speed_mult"] or 0)
                local list = out[kind]
                list[#list + 1] = {
                    design = did, size = info.size, civilian = info.civilian, class = info.class,
                    name = galaxy_name(world.field(info.block, "name")),
                    auto = world.field(info.block, "auto_gen_design") == "yes",
                    cost = okc and cost_list(cost) or {}, time = okt and time or nil,
                    days = okt and time and math.floor(time / math.max(speed, 0.01) + 1e-6) or nil,
                    mult = info.size_multiplier or 1, file = d and d.file or "", line = d and d.line or 0, n = n,
                }
            end
        end
    end
    for _, k in ipairs({ "ships", "defenses" }) do
        table.sort(out[k], function(a, b)
            if a.civilian ~= b.civilian then return a.civilian end
            if a.mult ~= b.mult then return a.mult < b.mult end
            if a.file ~= b.file then return a.file < b.file end
            if a.line ~= b.line then return a.line < b.line end
            return a.n < b.n
        end)
    end
    for _, part in ipairs({ { "modules", "common/starbase_modules" }, { "buildings", "common/starbase_buildings" } }) do
        local list = {}
        for key, d in pairs(edefs.folder(part[2])) do
            -- (an inline script's own key is not a component)
            if key ~= "inline_script" and edefs.field(d.block, "construction_days") and holds(edefs.field(d.block, "potential")) then
                local okc, cost = pcall(cmds.def_table, owner, d, "cost", Mods)
                local total = 0
                for _, v in pairs(okc and cost or {}) do
                    total = total + v
                end
                list[#list + 1] = {
                    key = key, icon = unq(edefs.field(d.block, "icon")) or ("GFX_" .. key),
                    category = unq(edefs.field(d.block, "category")) or "", total = total,
                    frame = tonumber(edefs.field(d.block, "icon_frame")) or 1,
                    cost = okc and cost_list(cost) or {},
                    time = tonumber(edefs.field(d.block, "construction_days")) or 180,
                    days = math.floor((tonumber(edefs.field(d.block, "construction_days")) or 180)
                        / math.max(1 + (Mods[part[1] == "modules" and "starbase_module_build_speed_mult" or "starbase_building_build_speed_mult"] or 0), 0.01) + 1e-6),
                    possible = holds(edefs.field(d.block, "possible")),
                    file = d.file or "", line = d.line or 0,
                }
            end
        end
        table.sort(list, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.line < b.line
        end)
        out[part[1]] = list
    end
    return out
end

-- a table of strings, numbers, booleans (nested) as `return { ... }`
local function dump(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do
            dump(v[i], out)
            out[#out + 1] = ","
        end
        for k, x in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                out[#out + 1] = "["
                dump(k, out)
                out[#out + 1] = "]="
                dump(x, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" then
        out[#out + 1] = (v == math.floor(v) and math.abs(v) < 2 ^ 53) and string.format("%d", v) or string.format("%.17g", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = "nil"
    end
end

M.dump = function(v)
    local out = { "return " }
    dump(v, out)
    return table.concat(out)
end

-- M.megastructures(game_dir) -> { [id] = entry }: what the megastructure window shows
-- (interface/megastructure_view.gui, CMegaStructureView): its type, name (its own, else the type's:
-- CMegaStructure::GetLocalizedName), owner, the type's portrait (`portrait`, the default the .gui's
-- GFX_megastructure_construction_background), description key (CMegaStructureType::GetDescription:
-- "%s_DESC"), system, the upgrade that can follow it (a type whose upgrade_from lists it [I]),
-- dismantling
function M.megastructures(game_dir)
    local types = defs(game_dir, "common/megastructures").by
    -- the upgrades: a type's `upgrade_from = { a b }` [I]
    local upgrades = {}
    for name, d in pairs(types) do
        for _, from in ipairs(list_of(field(d.block, "upgrade_from"))) do
            upgrades[from] = upgrades[from] or name
        end
    end
    local galaxy = require("render.galaxy")
    local out = {}
    for _, id in ipairs(world.all("megastructure")) do
        local m = world.object("megastructure", id)
        local ty = m and unq(world.field(m, "type")) or ""
        local d = types[ty]
        local owner = tonumber(world.field(m, "owner"))
        out[id] = {
            id = id, type = ty,
            name = world.field(m, "name") and galaxy.name_block(world.field(m, "name")) or nil,
            owner = owner and owner ~= 4294967295 and owner or -1,
            portrait = d and unq(field(d.block, "portrait")) or "GFX_megastructure_construction_background",
            system = tonumber(world.path(m, "coordinate", "origin")) or -1,
            planet = tonumber(world.field(m, "planet")),
            upgrade = upgrades[ty],
            dismantling = (tonumber(world.field(m, "dismantle_progress")) or 0) > 0,
        }
    end
    return out
end

-- the waystation networks by id (the save's `waystation_networks`; CWaystationNetwork::WriteMembers
-- writes `name`, `waystations` = { starbase ids } and `networks` = { connected network ids }): their
-- stations by station fleet, the owner theirs [I]; each station's entry gets its network (no save
-- at hand has one)
function M.networks(starbases)
    local galaxy = require("render.galaxy")
    local fleet_of = {}
    for fleet, e in pairs(starbases) do
        fleet_of[e.id] = fleet
    end
    local out = {}
    local ok, ids = pcall(world.all, "waystation_networks")
    for _, id in ipairs(ok and ids or {}) do
        local n = world.object("waystation_networks", id)
        if n then
            local e = { id = id, stations = {}, networks = {}, owner = -1 }
            e.name = world.field(n, "name") and galaxy.name_block(world.field(n, "name")) or nil
            for _, sb in ipairs(world.list(world.field(n, "waystations"))) do
                local fleet = fleet_of[tonumber(sb)]
                if fleet then
                    e.stations[#e.stations + 1] = fleet
                    e.owner = e.owner == -1 and starbases[fleet].owner or e.owner
                    starbases[fleet].network, starbases[fleet].network_id = e.name or {}, id
                end
            end
            for _, v in ipairs(world.list(world.field(n, "networks"))) do
                e.networks[#e.networks + 1] = tonumber(v)
            end
            out[id] = e
        end
    end
    return out
end

-- data.extract(game_dir) -> the chunk (Galaxy::starbases): the starbases by station fleet, the
-- megastructures and waystation networks by id
function M.extract(game_dir)
    local starbases = M.starbases(game_dir)
    -- the side views' catalogs of the player's starbases (where the engine is)
    local player = 0
    local pl = world.meta and world.meta.player
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            player = tonumber(world.field(b, "country")) or player
        end
    end
    for _, e in pairs(starbases) do
        if e.owner == player then
            local ok, cat = pcall(catalog, e)
            if ok then
                e.catalog = cat
            else
                io.stderr:write("starbase catalog: " .. tostring(cat) .. "\n")
            end
        end
    end
    local networks = M.networks(starbases)
    return M.dump({ starbases = starbases, megastructures = M.megastructures(game_dir), networks = networks })
end

return M
