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
        end
    end
    return by
end

local function queue_entry(item)
    local out = {
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
            elseif out.kind == "starbase_building" then
                out.key = unq(field(b, "starbase_building") or field(b, "building"))
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
    local sector_colonies = {}
    for pid in pairs(world.planet_colony or {}) do
        local p = world.object("planet", pid)
        local sys = p and tonumber(world.path(p, "coordinate", "origin"))
        local sid = sys and sector_of[sys]
        if sid then
            sector_colonies[sid] = (sector_colonies[sid] or 0) + 1
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
            e.orbitals = orbitals
            e.has_sector = in_sector[e.system] or false
            e.sector_planets = sector_of[e.system] and sector_colonies[sector_of[e.system]] or 0
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

-- data.extract(game_dir) -> the chunk (Galaxy::starbases): the starbases by station fleet, the
-- megastructures by id
function M.extract(game_dir)
    return M.dump({ starbases = M.starbases(game_dir), megastructures = M.megastructures(game_dir) })
end

return M
