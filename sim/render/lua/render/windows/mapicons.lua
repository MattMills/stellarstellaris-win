-- render/windows/mapicons.lua : what the map labels (interface/mapicons.gui) show, from the world
-- (a save's gamestate): per system its owner and capitals, its starbase, its fleets, its planets'
-- deposits and whether a station collects them, the player's surveys and first contacts. The
-- rules that turn these into a label for an observer (who sees what, which icon, which frame)
-- are the renderer's (sim/render/src/mapicons.rs; docs/windows/mapicons.md).
--
--   local mapicons = require("render.windows.mapicons")
--   local data = mapicons.extract(game_dir, player)   -- player: the player's country id
--
-- data = {
--   resources = { name ... },                 -- common/strategic_resources in the game's order
--   classes = { [country id] = { hostile = bool } },
--   player_surveyed = { [planet id] = true },  -- country.surveyed_deposit_holders (type 0)
--   player_communications = { country id ... },
--   systems = { {
--     id, owner (country id or -1), capital = 0 | 1 (an empire's capital) | 2 (a sector's),
--     shield = bool,                         -- CGalacticObject::CalcShouldDisplayShieldOnMap
--     starbase = { level, size, owner, map_icon, frame } | nil,
--     null_starbase = bool,                  -- its starbases list names none that exists
--     fleets = { { id, owner, class (EShipClass), power, ftl, station, icon_frame } },
--     planets = { { id, owner, colony, deposits = { { resource, amount, collector } } } },
--     contact = bool,                        -- a first contact of the player's in progress here
--   } ... },
-- }

local world = require("engine.world")
local source = require("stellar.script.source")

local mapicons = {}

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value and (e.value.text or e.value)
        end
    end
    return nil
end

local function unquote(v)
    return v and (tostring(v):gsub('"', "")) or nil
end

-- EShipClass (4.5.2 Linux: GetShipClassTokenFromEnum's token table, GetTokenArray's names) [V]
local CLASS = {
    shipclass_military = 0, shipclass_constructor = 1, shipclass_colonizer = 2,
    shipclass_science_ship = 3, shipclass_transport = 4, shipclass_mining_station = 5,
    shipclass_research_station = 6, shipclass_military_station = 7, shipclass_habitat_station = 8,
    shipclass_observation_station = 9, shipclass_starbase = 10, shipclass_military_special = 11,
    shipclass_gravity_snare = 12, shipclass_entropy_conduit = 13,
}
mapicons.CLASS = CLASS

-- the game files read once: the resources' order, the deposits (what each produces, the
-- station class that collects it), the country types' factions (hostile)
local cache
local function files(game_dir)
    if cache then
        return cache
    end
    cache = { resources = {}, deposits = {}, country_types = {}, levels = {}, sizes = {} }
    -- the starbase levels' display_map_icon (default yes) and display_empire_shield (default
    -- no); the starbase sizes' icon_frame (their icon on GFX_starbase_ship_size_small)
    for name, d in pairs(source.definitions(game_dir, "common/starbase_levels")) do
        cache.levels[name] = { map_icon = get(d.block, "display_map_icon") ~= "no", shield = get(d.block, "display_empire_shield") == "yes" }
    end
    cache.class_frames = {}
    for name, d in pairs(source.definitions(game_dir, "common/ship_sizes")) do
        cache.sizes[name] = tonumber(get(d.block, "icon_frame"))
        cache.class_frames[name] = tonumber(get(d.block, "ship_class_icon_frame"))
    end
    local list = source.files(game_dir, "common/strategic_resources", "txt")
    table.sort(list)
    for _, f in ipairs(list) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.key.text:sub(1, 1) ~= "@" then
                cache.resources[#cache.resources + 1] = e.key.text
            end
        end
    end
    for name, d in pairs(source.definitions(game_dir, "common/deposits")) do
        local produces = get(get(d.block, "resources"), "produces")
        local out = {}
        for _, e in ipairs(type(produces) == "table" and produces or {}) do
            if e.op and e.key and e.value and tonumber(e.value.text) then
                out[#out + 1] = { resource = e.key.text, amount = tonumber(e.value.text) }
            end
        end
        cache.deposits[name] = { produces = out, station = unquote(get(d.block, "station")) }
    end
    for name, d in pairs(source.definitions(game_dir, "common/country_types")) do
        cache.country_types[name] = { hostile = get(get(d.block, "faction"), "hostile") == "yes" }
    end
    return cache
end

-- the system a planet (colony id or planet id) is in
local function planet_system(pid)
    local p = pid and world.object("planet", pid)
    return p and tonumber(world.path(p, "coordinate", "origin"))
end

function mapicons.extract(game_dir, player)
    local f = files(game_dir)
    if not world.colony_planet and world.index then
        world.index()
    end
    local fleet_owner = world.fleet_owner or {}
    local out = { resources = f.resources, classes = {}, player_surveyed = {}, player_communications = {}, systems = {} }

    -- capitals: each country's (`capital`, a colony id) and each sector's (`local_capital`)
    local capital_kind = {}
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        local t = c and unquote(world.field(c, "type")) or ""
        local ct = f.country_types[t]
        out.classes[cid] = { hostile = ct and ct.hostile or false, kind = t }
        local cap = c and tonumber(world.field(c, "capital"))
        local sid = cap and planet_system(world.colony_planet and world.colony_planet[cap] or cap)
        if sid then
            capital_kind[sid] = 1
        end
    end
    for _, sid in ipairs(world.all("sector")) do
        local s = world.object("sector", sid)
        local lc = s and tonumber(world.field(s, "local_capital"))
        local sys = lc and planet_system(world.colony_planet and world.colony_planet[lc] or lc)
        if sys and not capital_kind[sys] then
            capital_kind[sys] = 2
        end
    end

    -- the player's surveys (surveyed_deposit_holders = { { type = 0 id = planet } }) and first
    -- contacts in progress (their location)
    local pc = player and world.object("country", player)
    for _, b in ipairs(pc and world.blocks(world.field(pc, "surveyed_deposit_holders")) or {}) do
        if tonumber(world.field(b, "type")) == 0 then
            out.player_surveyed[tonumber(world.field(b, "id")) or -1] = true
        end
    end
    local rm = pc and world.field(pc, "relations_manager")
    for _, r in ipairs(rm and world.fields(rm, "relation") or {}) do
        local other = type(r) == "table" and tonumber(world.field(r, "country"))
        if other and world.field(r, "communications") == "yes" then
            out.player_communications[#out.player_communications + 1] = other
        end
    end
    local contact_at = {}
    for _, cid in ipairs(pc and world.list(world.path(pc, "first_contact", "contacts")) or {}) do
        local c = world.object("first_contact", tonumber(cid))
        if c and world.field(c, "status") == "in_progress" then
            local loc = tonumber(world.field(c, "location"))
            if loc then
                contact_at[loc] = true
            end
        end
    end

    local fleet_info = {}
    for _, fid in ipairs(world.all("fleet")) do
        local fl = world.object("fleet", fid)
        local mm = fl and world.field(fl, "movement_manager")
        if type(mm) == "table" then
            local class = CLASS[unquote(world.field(fl, "ship_class")) or ""]
            local state = tostring(world.field(mm, "state") or "")
            local info = {
                id = fid, owner = fleet_owner[fid] or -1, class = class or 0,
                power = tonumber(world.field(fl, "military_power")) or 0,
                ftl = state == "move_jump_anim" or state == "move_wind_up" or state == "move_wind_down",
                station = world.path(fl, "properties", "station") == "yes",
                ships = #world.list(world.field(fl, "ships")),
            }
            -- a station's size's ship_class_icon_frame (GetShipClassIconFrameFromSize)
            if info.station then
                local ship = world.object("ship", tonumber(world.list(world.field(fl, "ships"))[1]))
                local did = ship and tonumber(world.path(ship, "ship_design_implementation", "design"))
                local design = did and world.object("ship_design", did)
                local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
                local size = stage and unquote(world.field(stage, "ship_size"))
                info.icon_frame = size and f.class_frames[size] or nil
            end
            fleet_info[fid] = info
        end
    end

    for _, sid in ipairs(world.all("system")) do
        local obj = world.object("system", sid)
        local sys = {
            id = sid, owner = world.system_owner and world.system_owner[sid] or -1,
            capital = capital_kind[sid] or 0, fleets = {}, planets = {}, contact = contact_at[sid] or false,
        }
        for _, fid in ipairs(world.list(world.field(obj, "fleet_presence"))) do
            local info = fleet_info[tonumber(fid)]
            if info and info.ships > 0 then
                sys.fleets[#sys.fleets + 1] = info
            end
        end
        local starbases = world.list(world.field(obj, "starbases"))
        sys.null_starbase = #starbases > 0
        for _, sb in ipairs(starbases) do
            local s = world.object("starbase", tonumber(sb))
            if s then
                sys.null_starbase = false
            end
            local station = s and tonumber(world.field(s, "station"))
            local ship = station and world.object("ship", station)
            local level = s and f.levels[unquote(world.field(s, "level")) or ""]
            if level and level.shield then
                sys.shield = true
            end
            if s and not sys.starbase then
                local did = ship and tonumber(world.path(ship, "ship_design_implementation", "design"))
                local design = did and world.object("ship_design", did)
                local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
                local fleet = ship and tonumber(world.field(ship, "fleet"))
                local size = stage and unquote(world.field(stage, "ship_size")) or ""
                sys.starbase = {
                    level = unquote(world.field(s, "level")) or "", size = size,
                    owner = fleet and fleet_owner[fleet] or -1,
                    map_icon = not level or level.map_icon, frame = f.sizes[size] or 0,
                }
            end
        end
        for _, pid in ipairs(world.fields(obj, "planet")) do
            pid = tonumber(pid)
            local p = pid and world.object("planet", pid)
            if p then
                local planet = {
                    id = pid, owner = tonumber(world.field(p, "owner")) or -1,
                    colony = world.field(p, "colony") ~= nil, deposits = {},
                }
                -- a colony in the system shows its owner's shield
                if planet.colony then
                    sys.shield = true
                end
                -- the planet's station (shipclass_orbital_station: the deposit holder's station
                -- fleet, CDepositHolder +0xe0)
                local st = fleet_info[tonumber(world.field(p, "shipclass_orbital_station")) or -1]
                for _, did in ipairs(world.list(world.field(p, "deposits"))) do
                    local d = world.object("deposit", tonumber(did))
                    local def = d and f.deposits[unquote(world.field(d, "type")) or ""]
                    if def and #def.produces > 0 then
                        -- the planet's station collects it when of the deposit's station class or a
                        -- starbase (CDeposit::ListResourcesForMapmode)
                        local collector = -1
                        local want = CLASS[def.station or ""]
                        if not want then
                            want = (def.produces[1].resource:find("_research", 1, true)) and 6 or 5
                        end
                        if st and (st.class == want or st.class == 10) then
                            collector = st.owner
                        end
                        for _, r in ipairs(def.produces) do
                            planet.deposits[#planet.deposits + 1] = { resource = r.resource, amount = r.amount, collector = collector }
                        end
                    end
                end
                sys.planets[#sys.planets + 1] = planet
            end
        end
        out.systems[#out.systems + 1] = sys
    end
    return out
end

return mapicons
