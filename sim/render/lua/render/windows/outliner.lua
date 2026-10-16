-- render/windows/outliner.lua : the outliner (interface/outliner.gui; COutlinerControllerView,
-- CCountryTabbedOutliner, COutlinerGroup*, CObserverOutliner: docs/windows/outliner.md).
--
-- Two halves, on two threads:
--   extract(game_dir, { player, country, planets }) -> view   (the simulation's thread, in the
--       world's runtime, from render.galaxy: plain data, copied to the render thread)
--   layout(ctx, data, items, report)   (the render thread, from render.windows: data is
--       RENDER_OUTLINER = { view, state = { tab, collapsed, shown }, selected, observe })
--
-- The view's `members` and `sectors` are the lists render.galaxy returned before (galaxy.rs reads
-- them); `groups` (by EOutLinerGroup), `tab_items`, `badges` and `countries` are this module's.

local M = {}

local OUTLINER = "interface/outliner.gui"
local NONE = 4294967295

-- ---------------------------------------------------------------------------------------------
-- extract: the world's side
-- ---------------------------------------------------------------------------------------------

-- a pdxscript tree's field (the game's files)
local function field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function unquote(v)
    return v ~= nil and (tostring(v):gsub('"', "")) or nil
end

-- what the rows need of the game's files, read once per game directory
local game_cache = {}
local function game_data(game_dir)
    local d = game_cache[game_dir]
    if d then
        return d
    end
    local source = require("stellar.script.source")
    d = {}
    -- the scripted variables (@corvette_size_multiplier = 5)
    local vars = {}
    for _, rel in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
        local tree = source.parse(game_dir, rel)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                vars[e.key.text] = tonumber(e.value.text)
            end
        end
    end
    local function num(v)
        if type(v) ~= "string" then
            return nil
        end
        if v:sub(1, 1) == "@" then
            return vars[v]
        end
        return tonumber(v)
    end
    -- ship sizes: command points (size_multiplier), the starbase icon's frame (icon_frame)
    d.sizes = {}
    for name, def in pairs(source.definitions(game_dir, "common/ship_sizes") or {}) do
        d.sizes[name] = {
            points = num(field(def.block, "size_multiplier")) or 1,
            icon_frame = num(field(def.block, "icon_frame")),
        }
    end
    -- planet classes' icons (the outliner's portrait: CPlanetClass::GetIcon)
    d.planet_icons = {}
    for name, def in pairs(source.definitions(game_dir, "common/planet_classes") or {}) do
        d.planet_icons[name] = unquote(field(def.block, "icon"))
    end
    -- country types the observer lists (`observable = yes`) and the fallen ones
    d.observable, d.fallen = {}, {}
    for name, def in pairs(source.definitions(game_dir, "common/country_types") or {}) do
        d.observable[name] = field(def.block, "observable") == "yes"
        d.fallen[name] = field(def.block, "fallen_empire") == "yes" or field(def.block, "awakened_fallen_empire") == "yes"
    end
    -- zones' building slots (max_buildings, else DEFAULT_MAX_PLANET_BUILDINGS_PER_ZONE)
    d.zone_slots = {}
    for name, def in pairs(source.definitions(game_dir, "common/zones") or {}) do
        d.zone_slots[name] = num(field(def.block, "max_buildings"))
    end
    -- deposits: the blockers and the technologies that clear them
    d.blockers = {}
    for name, def in pairs(source.definitions(game_dir, "common/deposits") or {}) do
        if unquote(field(def.block, "category")) == "deposit_cat_blockers" then
            local pre = {}
            local p = field(def.block, "prerequisites")
            for _, e in ipairs(type(p) == "table" and p or {}) do
                local t = e.value and e.value.text or (e.key and e.key.text)
                if t then
                    pre[#pre + 1] = unquote(t)
                end
            end
            d.blockers[name] = pre
        end
    end
    -- the defines read (any section)
    d.defines = {}
    for _, rel in ipairs(source.files(game_dir, "common/defines", "txt")) do
        for _, sec in ipairs(source.parse(game_dir, rel) or {}) do
            if sec.op and type(sec.value) == "table" and sec.value.text == nil then
                for _, e in ipairs(sec.value) do
                    if e.op and e.key and e.value and e.value.text then
                        d.defines[e.key.text] = tonumber(e.value.text) or d.defines[e.key.text]
                    end
                end
            end
        end
    end
    game_cache[game_dir] = d
    return d
end

function M.extract(game_dir, ctx)
    local world = require("engine.world")
    local galaxy = require("render.galaxy")
    local pc, player, planets = ctx.country, ctx.player, ctx.planets or {}
    local view = { player = player, members = {}, sectors = {}, groups = {}, tab_items = { [2] = 0, [3] = 0 }, badges = {} }
    if not world.colony_planet and world.index then
        world.index()
    end
    local gd = game_data(game_dir)
    view.countries = M.observer_countries(world, galaxy, gd, player)
    if not pc then
        return view
    end
    local outliner, sectors = view.members, view.sectors
    local function system_name(sid)
        local s = sid and sid >= 0 and world.object("system", sid)
        return s and galaxy.name_block(world.field(s, "name")) or nil
    end

    -- the player's leaders where they serve (leader location = { type id }): a fleet's commander,
    -- a colony's governor (the badge's frame is the level: GFX_outliner_leader_level)
    local fleet_leader, colony_leader = {}, {}
    for _, lid in ipairs(world.leaders_of and world.leaders_of[player] or {}) do
        local l = world.object("leader", lid)
        local loc = l and world.field(l, "location")
        local kind = loc and unquote(world.field(loc, "type"))
        local at = loc and tonumber(world.field(loc, "id"))
        local level = tonumber(world.field(l, "level")) or 0
        if kind == "ship" and at then
            fleet_leader[at] = level
        elseif kind == "planet" and at then
            colony_leader[at] = level
        end
    end

    local function ship_size_of(sid)
        local ship = world.object("ship", tonumber(sid))
        local did = ship and tonumber(world.path(ship, "ship_design_implementation", "design"))
        local design = did and world.object("ship_design", did)
        local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
        return stage and unquote(world.field(stage, "ship_size")) or "", ship
    end

    -- a fleet's status icon (CFleet::GetFleetStatusIconFrame) [V for the rule; I for the save's
    -- fields]: moving 2, docked at a starbase 3, in a planet's orbit 23, else idle 1
    local function status_frame(f)
        local mm = world.field(f, "movement_manager")
        local state = mm and unquote(world.field(mm, "state")) or "move_idle"
        if state ~= "move_idle" then
            return 2
        end
        local orb = mm and world.path(mm, "orbit", "orbitable")
        if type(orb) == "table" then
            if world.field(orb, "starbase") ~= nil then
                return 3
            end
            if world.field(orb, "planet") ~= nil then
                return 23
            end
        end
        return 1
    end

    -- the starbases by their station ship
    local starbase_of = {}
    for _, sb in ipairs(world.all("starbase")) do
        local s = world.object("starbase", sb)
        local st = s and tonumber(world.field(s, "station"))
        if st then
            starbase_of[st] = s
        end
    end
    -- EShipClass order of the utility ships (construction before science, the frame's) [I]
    local CLASS = { constructor = 1, science = 2, colonizer = 3 }
    local civilian, military, yards, bases = {}, {}, {}, {}
    local repairable, science_without_leader = 0, 0
    local owned = world.blocks(world.path(pc, "fleets_manager", "owned_fleets"))
    for k, o in ipairs(owned) do
        local fid = tonumber(world.field(o, "fleet"))
        local f = fid and world.object("fleet", fid)
        local ships = f and world.list(world.field(f, "ships")) or {}
        if f and #ships > 0 then
            local mm = world.field(f, "movement_manager")
            local origin = tonumber(world.path(mm, "coordinate", "origin")) or -1
            local e = {
                id = fid, name = galaxy.name_block(world.field(f, "name")), system = origin,
                location = system_name(origin), in_ftl = origin == NONE or nil,
                power = tonumber(world.field(f, "military_power")) or 0, order = k,
                leader_level = fleet_leader[fid], status = status_frame(f),
            }
            -- ships: damage (can repair), designs with an upgrade (can upgrade), command points
            local damaged, upgradable, points = false, false, 0
            local designs = {}
            for _, sid in ipairs(ships) do
                local size, ship = ship_size_of(sid)
                points = points + ((gd.sizes[size] or {}).points or 1)
                if ship then
                    if (tonumber(world.field(ship, "hitpoints")) or 0) < (tonumber(world.field(ship, "max_hitpoints")) or 0)
                        or (tonumber(world.field(ship, "armor_hitpoints")) or 0) < (tonumber(world.field(ship, "max_armor_hitpoints")) or 0) then
                        damaged = true
                    end
                    local impl = world.field(ship, "ship_design_implementation")
                    local up = impl and tonumber(world.field(impl, "upgrade"))
                    if up and up ~= NONE then
                        upgradable = true
                    end
                    local did = impl and tonumber(world.field(impl, "design"))
                    if did then
                        designs[did] = (designs[did] or 0) + 1
                    end
                end
            end
            if damaged then
                repairable = repairable + 1
            end
            if world.path(f, "properties", "station") == "yes" then
                local sb = starbase_of[tonumber(ships[1])]
                if sb then
                    local level = unquote(world.field(sb, "level")) or ""
                    local has_yard = false
                    local mods = world.field(sb, "modules")
                    if type(mods) == "table" then
                        for _, m in ipairs(mods) do
                            if m.value and m.value.text == "shipyard" then
                                has_yard = true
                            end
                        end
                    end
                    -- the station ship's name (CShip::GetNameWithType) and size's icon frame
                    local size, ship = ship_size_of(ships[1])
                    e.name = ship and galaxy.name_block(world.field(ship, "name")) or e.name
                    e.type_frame = (gd.sizes[size] or {}).icon_frame
                    e.sub = unquote(world.field(sb, "type")) or ""
                    e.level = level
                    e.status = nil
                    if has_yard then
                        e.kind = "shipyard"
                        yards[#yards + 1] = e
                    elseif level ~= "starbase_level_outpost" then
                        e.kind = "starbase"
                        bases[#bases + 1] = e
                    end
                end
            elseif world.field(f, "ship_class") == "shipclass_military" or e.power > 0 then
                e.kind = "military"
                -- the size line (BuildFleetTemplateCountString): command points used / the fleet
                -- command limit (COMMAND_LIMIT_BASE [I: its modifiers not summed]) (the
                -- template's size); the power red below the template's (its designs, all built)
                -- [I: the template's power is not computed: a ship short, damaged or of another
                -- design than the template's stands for it]
                e.points = points
                e.limit = gd.defines.COMMAND_LIMIT_BASE or 50
                local tid = tonumber(world.field(f, "fleet_template"))
                local t = tid and world.object("fleet_template", tid)
                if t then
                    e.template = tonumber(world.field(t, "fleet_size"))
                    local below = damaged
                    for _, entry in ipairs(world.blocks(world.field(t, "fleet_template_design"))) do
                        local did = tonumber(world.path(entry, "ship_design_implementation", "design"))
                        local count = tonumber(world.field(entry, "count")) or 0
                        if did and (designs[did] or 0) < count then
                            below = true
                        end
                    end
                    e.power_below = below or nil
                end
                e.can_upgrade = upgradable or nil
                e.can_repair = damaged or nil
                military[#military + 1] = e
            else
                e.kind = "civilian"
                e.sub = ship_size_of(ships[1])
                e.class = CLASS[e.sub] or 9
                if e.sub == "science" and not e.leader_level then
                    science_without_leader = science_without_leader + 1
                end
                civilian[#civilian + 1] = e
            end
        end
    end
    table.sort(civilian, function(a, b)
        if a.class ~= b.class then
            return a.class < b.class
        end
        return a.order < b.order
    end)
    for _, list in ipairs({ civilian, military, yards, bases }) do
        for _, e in ipairs(list) do
            outliner[#outliner + 1] = e
        end
    end

    -- the country's technologies (a blocker's clearing)
    local techs = {}
    for _, t in ipairs(world.fields(world.field(pc, "tech_status") or {}, "technology")) do
        techs[unquote(t)] = true
    end

    -- a colony's row: its name, the portrait, the designation, the governor's level, the status
    -- icons (COutlinerPlanetStatusController: frame = condition + 1) [V for the rules; I for the
    -- save's fields]
    local unemployed_colonies, low_stability = 0, 0
    local sector_capital = {}
    local function planet_row(p, sector)
        local col = world.planet_colony and world.planet_colony[p.id]
        local c = col and world.object("colony", col)
        local po = world.object("planet", p.id)
        local e = {
            kind = "planet", id = p.id, name = p.name, system = p.system, sector = sector, power = 0,
            location = system_name(p.system),
            sub = c and unquote(world.field(c, "final_designation")) or "",
            icon = gd.planet_icons[p.class], leader_level = col and colony_leader[col],
            sector_capital = col and sector_capital[col] or nil,
        }
        local status = {}
        if c then
            -- 0: a free building slot (a zone with fewer buildings than its slots)
            local free = false
            for _, did in ipairs(world.list(world.field(c, "districts"))) do
                local d = world.object("districts", tonumber(did))
                for _, zid in ipairs(d and world.list(world.field(d, "zones")) or {}) do
                    local z = world.object("zones", tonumber(zid))
                    if z then
                        local slots = gd.zone_slots[unquote(world.field(z, "type"))] or gd.defines.DEFAULT_MAX_PLANET_BUILDINGS_PER_ZONE or 3
                        if #world.list(world.field(z, "buildings")) < slots then
                            free = true
                        end
                    end
                end
            end
            if free then
                status[#status + 1] = 1
            end
            -- 1: a blocker the country can clear
            for _, dep in ipairs(po and world.list(world.field(po, "deposits")) or {}) do
                local dd = world.object("deposit", tonumber(dep))
                local pre = dd and gd.blockers[unquote(world.field(dd, "type"))]
                if pre and ctx.blockers_checked then
                    local ok = true
                    for _, t in ipairs(pre) do
                        ok = ok and techs[t] or false
                    end
                    if ok then
                        status[#status + 1] = 2
                        break
                    end
                end
            end
            local unemployed = tonumber(world.field(c, "unemploy_pop")) or 0
            local civilians = tonumber(world.field(c, "civilian")) or 0
            -- 5: unemployment of POP_BULK_UNIT_SIZE (100) or more; 6: with the civilians, 500
            if unemployed >= (gd.defines.POP_BULK_UNIT_SIZE or 100) then
                status[#status + 1] = 6
            end
            if unemployed + civilians >= (gd.defines.POP_OUTLINER_CIVILIAN_WARNING or 500) then
                status[#status + 1] = 7
            end
            -- 7: overcrowded
            if (tonumber(world.field(c, "free_housing")) or 0) < 0 then
                status[#status + 1] = 8
            end
            -- 10: low stability
            local stability = tonumber(world.field(c, "stability")) or 50
            if stability < (gd.defines.LOW_PLANET_STABILITY or 25) then
                status[#status + 1] = 11
                low_stability = low_stability + 1
            end
            if unemployed > 0 then
                unemployed_colonies = unemployed_colonies + 1
            end
        end
        e.status = status
        return e
    end

    -- the sectors (in the save's order) and their colonies; a colony in no sector's system is in
    -- the frontier sector (CCountry::GetFrontierColonies) [V]
    local in_sector = {}
    local sector_rows = {}
    for _, sid in ipairs(world.all("sector")) do
        local s = world.object("sector", sid)
        if s and tonumber(world.field(s, "owner")) == player then
            local lc = tonumber(world.field(s, "local_capital"))
            if lc then
                sector_capital[lc] = true
            end
        end
    end
    for _, sid in ipairs(world.all("sector")) do
        local s = world.object("sector", sid)
        if s and tonumber(world.field(s, "owner")) == player then
            local systems = {}
            for _, v in ipairs(world.list(world.field(s, "systems"))) do
                systems[tonumber(v)] = true
            end
            -- the capital's system (the map's sector name sits there: GenerateSectorNames):
            -- local_capital is a colony, on a planet
            local lc = tonumber(world.field(s, "local_capital"))
            local cp = lc and world.colony_planet and world.colony_planet[lc]
            local cpo = cp and world.object("planet", cp)
            local capital = cpo and tonumber(world.path(cpo, "coordinate", "origin"))
            sectors[#sectors + 1] = { id = sid, name = galaxy.name_block(world.field(s, "name")), capital = capital }
            local rows = {}
            for _, p in ipairs(planets) do
                if systems[p.system] then
                    in_sector[p.id] = true
                    local e = planet_row(p, sid)
                    outliner[#outliner + 1] = e
                    rows[#rows + 1] = e
                end
            end
            sector_rows[#sector_rows + 1] = { key = "sector:" .. sid, title = galaxy.name_block(world.field(s, "name")), rows = rows }
        end
    end
    local frontier = {}
    for _, p in ipairs(planets) do
        if not in_sector[p.id] then
            frontier[#frontier + 1] = planet_row(p, -1)
        end
    end

    -- the groups (EOutLinerGroup) the layout shows, by name
    local groups = view.groups
    for _, kind in ipairs({ "civilian", "military", "starbase", "shipyard" }) do
        local rows = {}
        for _, e in ipairs(outliner) do
            if e.kind == kind then
                rows[#rows + 1] = e
            end
        end
        groups[kind] = { rows = rows }
    end
    -- Sectors (COutlinerGroupSector::UpdateDerived): a group per sector, then the frontier's; the
    -- header counts them [V]
    local children = {}
    for _, s in ipairs(sector_rows) do
        children[#children + 1] = { key = s.key, title = s.title, header = "outliner_sector_title_entry_window", kind = "planet", rows = s.rows }
    end
    if #frontier > 0 then
        children[#children + 1] = { key = "sector:frontier", title = "FRONTIER_SECTOR", header = "outliner_sector_title_entry_window", kind = "planet", rows = frontier }
    end
    groups.sectors = { children = children }

    -- Politics: the country's factions (COutlinerGroupPopFactions::UpdateInternal), in the save's
    -- order [I]: name, type icon, approval (§G at POP_FACTION_APPROVAL_HIGH and over, §R under
    -- _LOW, else §Y: CPopFaction::GetApprovalColor) [V], members
    local factions = {}
    for _, fid in ipairs(world.all("pop_factions")) do
        local fa = world.object("pop_factions", fid)
        if fa and tonumber(world.field(fa, "country")) == player then
            factions[#factions + 1] = {
                kind = "faction", id = fid, name = galaxy.name_block(world.field(fa, "name")),
                type = unquote(world.field(fa, "type")),
                approval = tonumber(world.field(fa, "faction_approval")) or 0,
                support = tonumber(world.field(fa, "support_power")) or 0,
                pops = tonumber(world.field(fa, "last_month_pops")) or 0,
                high = gd.defines.POP_FACTION_APPROVAL_HIGH or 0.6, low = gd.defines.POP_FACTION_APPROVAL_LOW or 0.4,
            }
        end
    end
    groups.factions = { rows = factions }
    view.tab_items[2] = #factions

    -- the tabs' badges (UpdateTabNotificationCountForTab): Overview, colonies with unemployment
    -- (+ buildings that can be upgraded [I: not counted]), critical: low stability; Ships,
    -- fleets that can be repaired, critical: science ships without a leader [V for the rules]
    view.badges[0] = { regular = unemployed_colonies, critical = low_stability }
    view.badges[1] = { regular = repairable, critical = science_without_leader }
    return view
end

-- the observer's countries (CObserverOutlinerGroupEmpires::UpdateInternal): every observable
-- country (its type's `observable`), by group (players: none for an observer; fallen empires;
-- the rest AI), by economy power, the highest first [V for the rules; I for the save's fields]
function M.observer_countries(world, galaxy, gd, player)
    local out = { players = {}, ai = {}, fallen = {}, minors = {} }
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        local ty = c and unquote(world.field(c, "type"))
        if ty and gd.observable[ty] then
            local fed = tonumber(world.field(c, "federation"))
            local fo = fed and world.object("federation", fed)
            local e = {
                kind = "country", id = cid, flag_country = cid, name = galaxy.name_block(world.field(c, "name")),
                alliance = fo and galaxy.name_block(world.field(fo, "name")) or nil,
                economy = tonumber(world.field(c, "economy_power")) or 0,
                military = tonumber(world.field(c, "military_power")) or 0,
                pops = tonumber(world.field(c, "num_sapient_pops")) or 0,
            }
            local list = gd.fallen[ty] and out.fallen or out.ai
            list[#list + 1] = e
        end
    end
    for _, list in pairs(out) do
        table.sort(list, function(a, b)
            if math.floor(a.economy) ~= math.floor(b.economy) then
                return math.floor(a.economy) > math.floor(b.economy)
            end
            return a.id < b.id
        end)
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- layout: the render thread's side
-- ---------------------------------------------------------------------------------------------

-- the tabs (EOutlinerTabType; NOutlinerHelpers::GetOutlinerTabNameKey, SetTabButtonSprite) [V]
local TABS = {
    [0] = { key = "outliner_government", sprite = "GFX_outliner_government_tab_button" },
    [1] = { key = "outliner_ships", sprite = "GFX_outliner_ships_tab_button" },
    [2] = { key = "outliner_politics", sprite = "GFX_outliner_politics_tab_button" },
    [3] = { key = "outliner_structures", sprite = "GFX_outliner_structures_tab_button" },
}

-- each tab's groups as shown: created in EOutLinerGroup order, every tab but Politics sorts its
-- groups equal and the merge sort reverses them (COutlinerSettings::GetSort, SortedMerge) [V]; the
-- groups this renderer fills (the others are empty for the player here: situations, armies,
-- waystations, terraforming, special planets, overlord holdings, arkships)
local TAB_GROUPS = {
    [0] = { "civilian", "military", "starbase", "shipyard", "sectors" },
    [1] = { "civilian", "military" },
    [2] = { "observation_posts", "factions", "integration" },
    [3] = { "megastructures" },
}

-- the groups' titles (GetOutlinerGroupString) [V]
local GROUP_TITLE = {
    civilian = "OUTLINER_CIVILIAN_FLEETS", military = "OUTLINER_FLEETS", starbase = "OUTLINER_STARBASES",
    shipyard = "OUTLINER_SHIPYARDS", sectors = "OUTLINER_SECTORS", observation_posts = "OUTLINER_OBSERVATION_POSTS",
    factions = "OUTLINER_POP_FACTIONS", integration = "OUTLINER_INTEGRATION", megastructures = "OUTLINER_MEGASTRUCTURES",
    players = "OUTLINER_PLAYER_COUNTRIES", ai = "OUTLINER_AI_COUNTRIES", fallen = "OUTLINER_FALLEN_EMPIRES",
    minors = "OUTLINER_MINOR_COUNTRIES",
}

-- the observer's groups, reverse enum order (Minors 25, Fallen 24, AI 23, Players 22) [V]
local OBSERVER_GROUPS = { "minors", "fallen", "ai", "players" }

-- the list's metrics (CSmoothListbox::GetSize: items' heights summed, spacing -1 between) [V]
local HEADER_H = 38   -- outliner_title_entry_window
local INNER_Y = 36    -- its `list` (x 2)
local ROW_H = 41      -- outliner_member_*_entry_window
local COUNTRY_H = 56  -- observer_outliner_country_window

-- whole under 1000, then K (one decimal under 100K) and M with one decimal, cut not rounded
-- (CreateSIValueNoColor; app.rs si_number)
local function si(v)
    local s = v < 0 and "-" or ""
    local a = math.abs(v)
    if a < 1000 then
        return s .. tostring(math.floor(a))
    elseif a < 100000 then
        return s .. string.format("%.1fK", math.floor(a / 100) / 10)
    elseif a < 1000000 then
        return s .. tostring(math.floor(a / 1000)) .. "K"
    end
    return s .. string.format("%.1fM", math.floor(a / 100000) / 10)
end
M.si = si

-- a list's height: its items' summed, `spacing` between each two (the tab's list: -1; a group's
-- inner list gives none and its rows come 42 apart in the game's frame, 41 high: 1 [I, measured])
local TAB_SPACING, INNER_SPACING = -1, 1
local function list_height(heights, spacing)
    local h = 0
    for _, v in ipairs(heights) do
        h = h + v
    end
    return #heights > 0 and h + spacing * (#heights - 1) or 0
end

-- a group's height in its list (COutlinerGroup::UpdateEntry: the header, and its inner list when
-- expanded and not empty)
local function group_height(g, collapsed)
    if collapsed[g.key] then
        return HEADER_H
    end
    local hs = {}
    for _, c in ipairs(g.children or {}) do
        hs[#hs + 1] = group_height(c, collapsed)
    end
    for _ = 1, #(g.rows or {}) do
        hs[#hs + 1] = g.row_h or ROW_H
    end
    return HEADER_H + list_height(hs, INNER_SPACING)
end

-- the groups of a tab from the view (empty ones left out: COutlinerListViewBase::InternalUpdate)
local function tab_groups(view, tab)
    local out = {}
    for _, name in ipairs(TAB_GROUPS[tab] or {}) do
        local g = (view.groups or {})[name]
        if g and ((g.rows and #g.rows > 0) or (g.children and #g.children > 0)) then
            out[#out + 1] = {
                key = name .. "@" .. tab, title = g.title or GROUP_TITLE[name], kind = g.kind or name, rows = g.rows,
                children = g.children, amount = g.amount, header = g.header,
            }
        end
    end
    return out
end

-- the rows: what each kind of member's window shows (M.rows[kind](row, path, fmt) -> window,
-- opts), filled in below
M.rows = {}

function M.layout(ctx, data, items, report)
    local gui = require("render.gui")
    local names = require("render.names")
    data = data or {}
    local view = data.view or {}
    local state = data.state or {}
    local collapsed = state.collapsed or {}
    local shown = state.shown or 0          -- 0 the tabs, 1 the observer's list, 2 none
    local selected = data.selected
    local observe = data.observe
    local screen = ctx.screen
    local function fmt(n)
        if type(n) ~= "table" then
            return n and tostring(n) or ""
        end
        return names.format(ctx.loc, n)
    end
    local function lay(window, opts)
        -- a sprite the game sets (ChangeSprite) shows its own frame (a sprite sheet's default_frame)
        for path, name in pairs(opts.sprites or {}) do
            local s = ctx.db.sprites[name]
            if s and s.default_frame and not (opts.frames and opts.frames[path]) then
                opts.frames = opts.frames or {}
                opts.frames[path] = s.default_frame
            end
        end
        opts.texture_size = ctx.texture_size
        opts.loc = ctx.loc
        local i, r = gui.layout(ctx.game_dir, ctx.db, OUTLINER, window, screen, opts)
        gui.merge(items, report, i, r)
        return r
    end

    -- the toggles (COutlinerControllerView): the observer's shows only when the player has no
    -- country (observe) [V]
    lay("outliner_controller_window", {
        hide = { observer_outliner_toggle = not observe or nil },
        actions = {
            ["/outliner_controller_window/outliner_toggle_window/tabbed_outliner_toggle"] = "outliner:tabbed",
            ["/outliner_controller_window/outliner_toggle_window/observer_outliner_toggle"] = "outliner:observer",
        },
    })
    if shown == 2 then
        return
    end

    -- the window's height (COutlinerListViewBase::InternalUpdate): its list's content + 20 + the
    -- list's y, at least outliner_min_size (180), at most the screen less its y and
    -- outliner_window_margin (193) [V]
    local top = 186
    local max_h = screen.height - top - 193
    local function window_height(content, list_y)
        return math.max(180, math.min(20 + content + list_y, max_h))
    end

    -- the groups, each at (x, y): its header, then its rows or child groups in its inner list
    -- (at x + 2, y + 36), drawn as far as the list's bottom
    local list_bottom
    local function draw_group(g, prefix, x, y)
        if y + HEADER_H > list_bottom then
            return
        end
        local header = g.header or "outliner_title_entry_window"
        local hp = prefix .. "/" .. header
        local text = { [hp .. "/title"] = g.title_text or fmt(g.title) }
        local n = #(g.children or {}) > 0 and #g.children or #(g.rows or {})
        text[hp .. "/amount"] = g.amount or tostring(n)
        local hide = { selected_overlay = true }
        local sprites, frames = {}, {}
        if g.icon_frame then
            frames[hp .. "/sectors"] = g.icon_frame
        end
        lay(header, {
            prefix = prefix, parent = { x = x, y = y, w = 0, h = HEADER_H }, hide = hide, text = text,
            sprites = sprites, frames = frames,
            -- a click on the header collapses or expands the group (COutlinerGroup::OnToggle) [V]
            actions = { [hp .. "/background"] = "outliner:toggle:" .. g.key },
        })
        if collapsed[g.key] then
            return
        end
        local cy = y + INNER_Y
        for k, c in ipairs(g.children or {}) do
            draw_group(c, prefix .. "/" .. k, x + 2, cy)
            cy = cy + group_height(c, collapsed) + INNER_SPACING
        end
        local row_h = g.row_h or ROW_H
        for k, row in ipairs(g.rows or {}) do
            if cy + row_h > list_bottom then
                break
            end
            -- (a row with a flag carries its country in its path: `@ID`, outliner.rs flag_country)
            local rp = prefix .. "/" .. k .. (row.flag_country and ("@" .. row.flag_country) or "")
            local fill = M.rows[row.kind or g.kind]
            if fill then
                local window, opts = fill(row, rp, fmt, selected)
                local extra = opts.extra
                opts.extra = nil
                opts.prefix = rp
                opts.parent = { x = x + 2, y = cy, w = 0, h = row_h }
                lay(window, opts)
                -- the entries of its grid boxes (status icons), at their slots
                for i, sub in ipairs(extra or {}) do
                    sub.opts.prefix = rp .. "/" .. sub.name .. "/" .. i
                    -- (its frames given by the path under its prefix)
                    local fr = {}
                    for k, v in pairs(sub.opts.frames or {}) do
                        fr[sub.opts.prefix .. k] = v
                    end
                    sub.opts.frames = fr
                    sub.opts.parent = { x = x + 2 + sub.dx, y = cy + sub.dy, w = 0, h = 0 }
                    lay(sub.window, sub.opts)
                end
            end
            cy = cy + row_h + INNER_SPACING
        end
    end

    local function draw_list(groups, list, prefix)
        local y = list.y
        for gi, g in ipairs(groups) do
            draw_group(g, prefix .. "/" .. gi, list.x, y)
            y = y + group_height(g, collapsed) + TAB_SPACING
        end
    end

    if shown == 1 then
        -- the observer's list (CObserverOutliner: observer_window_outliner, its list at y 50)
        local groups = {}
        for _, name in ipairs(OBSERVER_GROUPS) do
            local rows = (view.countries or {})[name]
            if rows and #rows > 0 then
                groups[#groups + 1] = { key = "observer:" .. name, title = GROUP_TITLE[name], kind = "country", rows = rows, row_h = COUNTRY_H }
            end
        end
        local hs = {}
        for _, g in ipairs(groups) do
            hs[#hs + 1] = group_height(g, collapsed)
        end
        local h = window_height(list_height(hs, TAB_SPACING), 50)
        local r = lay("observer_window_outliner", {
            sizes = { ["/observer_window_outliner"] = { 260, h } },
            actions = { ["/observer_window_outliner/unobserve"] = "outliner:unobserve" },
        })
        local list = r.rects["/observer_window_outliner/list"] or { x = screen.width - 258, y = top + 50 }
        list_bottom = top + h - 20
        draw_list(groups, list, "/observer_outliner")
        return
    end

    -- the tab buttons (CCountryTabbedOutliner::UpdateTabButtons): Overview and Ships always,
    -- Politics and Structures once they have members, in enum order in tabs_gridbox (slots 46 x
    -- 27); the active one's sprite in frame 2, the others in frame 1 (SwitchTab) [V]
    local tab = state.tab or 0
    local enabled = {}
    for t = 0, 3 do
        if t <= 1 or (view.tab_items and (view.tab_items[t] or view.tab_items[tostring(t)] or 0) > 0) then
            enabled[#enabled + 1] = t
        end
    end
    local tr = lay("tabs_outliner_window", {})
    local grid = tr.rects["/tabs_outliner_window/tabs_gridbox"] or { x = screen.width - 260, y = 159 }
    local badges = view.badges or {}
    for i, t in ipairs(enabled) do
        local p = "/outliner_tabs/" .. t
        local ep = p .. "/tabs_gridbox_entry"
        local b = badges[t] or badges[tostring(t)] or {}
        -- the badge (UpdateNotification): the critical count on red, else the regular one; "9+"
        -- over nine [V]
        local crit, reg = b.critical or 0, b.regular or 0
        local n = crit > 0 and crit or reg
        local hide = {}
        if n == 0 then
            hide.notification_container = true
        elseif crit > 0 then
            hide.notification_background_regular = true
        else
            hide.notification_background_critical = true
        end
        lay("tabs_gridbox_entry", {
            prefix = p, parent = { x = grid.x + (i - 1) * 46, y = grid.y, w = 0, h = 0 }, hide = hide,
            sprites = { [ep .. "/tab_button_background_icon"] = TABS[t].sprite },
            frames = { [ep .. "/tab_button_background_icon"] = t == tab and 2 or 1 },
            text = { [ep .. "/notification_container/notification_text"] = n > 9 and "9+" or tostring(n) },
            actions = { [ep .. "/button_overlay"] = "outliner:tab:" .. t },
        })
    end

    -- the tab's window and its groups (an observer has no country: its tabs are empty)
    local groups = observe and {} or tab_groups(view, tab)
    local hs = {}
    for _, g in ipairs(groups) do
        hs[#hs + 1] = group_height(g, collapsed)
    end
    local h = window_height(list_height(hs, TAB_SPACING), 40)
    local r = lay("outliner_tab_window", {
        -- (the rearrange button is drawn at its sprite's 28 x 28, not the .gui's 20 x 20, in the
        -- game's frame [I])
        sizes = { ["/outliner_tab_window"] = { 260, h }, ["/outliner_tab_window/rearrange"] = { 28, 28 } },
        text = { ["/outliner_tab_window/tab_name"] = TABS[tab].key },
        -- the rearrange button only on a tab with colonies or sectors (Overview) [V]
        hide = { rearrange = tab ~= 0 or nil },
    })
    local list = r.rects["/outliner_tab_window/list"] or { x = screen.width - 258, y = top + 40 }
    list_bottom = top + h - 20
    draw_list(groups, list, "/outliner")
end


-- ---------------------------------------------------------------------------------------------
-- the rows (COutlinerMember*::UpdateEntry): the window, its children shown, texts, frames
-- ---------------------------------------------------------------------------------------------

local function set(list)
    local s = {}
    for _, n in ipairs(list) do
        s[n] = true
    end
    return s
end

-- the selection's glow on the row it selects
local function is_selected(selected, kind, id)
    return selected and selected.kind == kind and selected.id == id
end

-- a colour code around a text (§X ... §!)
local function colour(code, text)
    return "\194\167" .. code .. text .. "\194\167!"
end

-- the location (SYSTEM_TEXT "$SYSTEM|E$"; a fleet between systems IN_FTL) [V]
local function location(row, fmt, ftl)
    if row.in_ftl then
        return ftl and "IN_FTL" or ""
    end
    local s = fmt(row.location)
    return s ~= "" and colour("E", s) or ""
end

-- the status icons of a grid box: `count` entries of `window` (their icon's frames), from the
-- grid's slot at (x, y) leftwards, `step` apart (format UPPER_RIGHT)
local function status_entries(window, icon, frames, x, y, step, max)
    local out = {}
    for k, f in ipairs(frames) do
        if k > max then
            break
        end
        out[#out + 1] = {
            name = window, window = window, dx = x - step * k, dy = y,
            opts = { frames = { ["/" .. window .. "/" .. icon] = f } },
        }
    end
    return out
end

local function fleet_common(row, p, fmt, selected, children, window)
    local only = set(children)
    only.selected_overlay = is_selected(selected, "fleet", row.id) or nil
    local frames = { [p .. "/fleet_status"] = row.status or 1 }
    -- the leader's level, with a leader (GFX_outliner_leader_level: frame = level) [V]
    if row.leader_level and row.leader_level > 0 then
        only.leader_level = true
        frames[p .. "/leader_level"] = row.leader_level
    end
    return only, frames
end

M.rows.civilian = function(row, rp, fmt, selected)
    local window = "outliner_member_fleet_civilian_entry_window"
    local p = rp .. "/" .. window
    local only, frames = fleet_common(row, p, fmt, selected, { "background", "fleet_status", "name", "type", "location" })
    return window, {
        only = only, frames = frames,
        text = {
            -- the name plain; the type the first ship's size (OUTLINER_CIVILIAN_FLEET_TYPE) [V]
            [p .. "/name"] = fmt(row.name), [p .. "/location"] = location(row, fmt, false),
            [p .. "/type"] = row.sub or "",
        },
        actions = { [p .. "/background"] = "select:fleet:" .. tostring(row.id) },
    }
end

M.rows.military = function(row, rp, fmt, selected)
    local window = "outliner_member_fleet_entry_window"
    local p = rp .. "/" .. window
    local only, frames = fleet_common(row, p, fmt, selected, { "background", "fleet_status", "name", "location", "size_limit" })
    local text = {
        -- the name white (§T) [V]
        [p .. "/name"] = colour("T", fmt(row.name)), [p .. "/location"] = location(row, fmt, true),
    }
    -- "15/50 (15)": command points / the command limit, both §Y, then the template's size, §E
    -- when not reached (BuildFleetTemplateCountString, CreateIntValueOutOfMax) [V]
    if row.template then
        local t = tostring(row.template)
        text[p .. "/size_limit"] = colour("Y", tostring(row.points or 0)) .. "/" .. colour("Y", tostring(row.limit or 0)) .. " "
            .. (row.template > (row.points or 0) and "(" .. colour("E", t) .. ")" or "(" .. t .. ")")
    else
        text[p .. "/size_limit"] = "\194\163navy_size\194\163 " .. colour("Y", tostring(row.points or 0))
    end
    -- the power: £military_power£ and the number, red under the template's (§R) [V]
    local power = math.floor((row.power or 0) + 0.5)
    if power > 0 then
        only.offensive_power = true
        local v = si(power)
        text[p .. "/offensive_power"] = "\194\163military_power\194\163 " .. (row.power_below and colour("R", v) or v)
    end
    -- the status grid (fleet_status_grid: x -132 y -21 from the lower right, 15 apart): repair
    -- (frame 1), upgrade (frame 2) [V]
    local st = {}
    if row.can_repair then
        st[#st + 1] = 1
    end
    if row.can_upgrade then
        st[#st + 1] = 2
    end
    return window, {
        only = only, frames = frames, text = text,
        actions = { [p .. "/background"] = "select:fleet:" .. tostring(row.id) },
        extra = status_entries("fleet_status_entry", "status", st, 318 - 132, 41 - 21, 15, 3),
    }
end

M.rows.starbase = function(row, rp, fmt, selected)
    local window = "outliner_member_starbase_entry_window"
    local p = rp .. "/" .. window
    local only = set({ "background", "type", "name", "starbase_type", "system", "military_power" })
    only.selected_overlay = is_selected(selected, "fleet", row.id) or nil
    local power = math.floor((row.power or 0) + 0.5)
    return window, {
        only = only,
        -- the type icon: the station's ship size's icon_frame (outpost 1 .. citadel 5) [V]
        frames = { [p .. "/type"] = row.type_frame or 1 },
        text = {
            [p .. "/name"] = fmt(row.name), [p .. "/system"] = location(row, fmt, false),
            [p .. "/starbase_type"] = row.sub or "",
            -- always yellow (MILITARY_POWER_YELLOW) [V]
            [p .. "/military_power"] = power > 0 and ("\194\163military_power\194\163 " .. colour("Y", si(power))) or "",
        },
        actions = { [p .. "/background"] = "select:fleet:" .. tostring(row.id) },
    }
end
M.rows.shipyard = M.rows.starbase

M.rows.planet = function(row, rp, fmt, selected)
    local window = "outliner_member_planet_entry_window"
    local p = rp .. "/" .. window
    -- the default display mode (0): the planet's portrait and its designation [V]
    local only = set({ "background", "planet_type_icon", "name", "star", "colony_type" })
    only.selected_overlay = is_selected(selected, "planet", row.id) or nil
    local frames, sprites = {}, {}
    if row.icon then
        sprites[p .. "/planet_type_icon"] = row.icon
    end
    if row.leader_level and row.leader_level > 0 then
        only.leader_level = true
        frames[p .. "/leader_level"] = row.leader_level
    end
    -- the name §E, a sector capital's with the £sector_capital£ icon (SECTOR_CAPITAL_NAME_WITH_FLAG)
    local name = colour("E", fmt(row.name))
    if row.sector_capital then
        name = "\194\163sector_capital\194\163" .. name
    end
    -- the status icons (planet_status_container at 23, 20; planet_or_starbase_status_entry at x
    -- 215 in its slot; UPPER_RIGHT: leftwards from there) [I: the slot's place, by the frame]
    return window, {
        only = only, frames = frames, sprites = sprites,
        text = { [p .. "/name"] = name, [p .. "/star"] = location(row, fmt, false), [p .. "/colony_type"] = row.sub or "" },
        actions = { [p .. "/background"] = "select:planet:" .. tostring(row.id) },
        extra = status_entries("planet_or_starbase_status_entry", "status", row.status or {}, 23, 20, 15, 5),
    }
end

-- the factions (COutlinerMemberPopFaction::UpdateEntry) [V for the parts; I for the values]
M.rows.faction = function(row, rp, fmt)
    local window = "outliner_member_pop_faction_entry_window"
    local p = rp .. "/" .. window
    local a = row.approval or 0
    local code = a >= (row.high or 0.6) and "G" or (a < (row.low or 0.4) and "R" or "Y")
    return window, {
        -- (the influence it gives is not computed: its label is not drawn)
        hide = { selected_overlay = true, influence_label = true },
        sprites = { [p .. "/faction_icon"] = "GFX_faction_icon_" .. tostring(row.type) },
        text = {
            [p .. "/name"] = fmt(row.name),
            [p .. "/approval_label"] = "\194\163mod_faction_approval\194\163 " .. colour(code, tostring(math.floor(a * 100 + 0.5)) .. "%"),
            [p .. "/num_pops"] = si(row.pops or 0),
        },
    }
end

-- the observer's country rows (CObserveOutlineMemberCountry::UpdateEntry) [V]
M.rows.country = function(row, rp, fmt)
    local window = "observer_outliner_country_window"
    local p = rp .. "/" .. window
    return window, {
        hide = { war_status_icon = true, fighting = true, selected_overlay = true },
        text = {
            [p .. "/name"] = fmt(row.name), [p .. "/alliance"] = fmt(row.alliance),
            -- economy power (COUNTRY_ECON_POWER), the fleets' power, the pops [V]
            [p .. "/might"] = "\194\163economy\194\163: " .. colour("Y", tostring(math.floor(row.economy or 0))),
            [p .. "/fleet_power"] = "\194\163military_power\194\163 " .. colour("Y", si(math.floor((row.military or 0) + 0.5))),
            [p .. "/pops"] = "\194\163pops\194\163: " .. tostring(math.floor(row.pops or 0)),
        },
    }
end

return M
