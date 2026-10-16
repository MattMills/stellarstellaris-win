-- render/windows/outliner.lua : the outliner (interface/outliner.gui; COutlinerControllerView,
-- CCountryTabbedOutliner, COutlinerGroup*, CObserverOutliner: docs/windows/outliner.md).
--
-- Two halves, on two threads:
--   extract(game_dir, { player, country, planets }) -> view   (the simulation's thread, in the
--       world's runtime, from render.galaxy: plain data, copied to the render thread)
--   layout(ctx, data, items, report)   (the render thread, from render.windows: data is
--       RENDER_OUTLINER = { view, state = { tab, collapsed, observer_list }, selected, observe })
--
-- The view's `members` and `sectors` are the lists render.galaxy returned before (galaxy.rs reads
-- them); the rest is this module's own.

local M = {}

local OUTLINER = "interface/outliner.gui"

-- ---------------------------------------------------------------------------------------------
-- extract: the world's side
-- ---------------------------------------------------------------------------------------------

function M.extract(game_dir, ctx)
    local world = require("engine.world")
    local galaxy = require("render.galaxy")
    local pc, player, planets = ctx.country, ctx.player, ctx.planets or {}
    local view = { player = player, members = {}, sectors = {} }
    if not pc then
        return view
    end
    local outliner, sectors = view.members, view.sectors
    local function system_name(sid)
        local s = sid and sid >= 0 and world.object("system", sid)
        return s and galaxy.name_block(world.field(s, "name")) or nil
    end
    -- the outliner's members (COutlinerGroup*): the player's fleets by kind (utility: by ship
    -- class, then the owned-fleet order; military; the starbases: with a shipyard module for
    -- Shipyards, other upgraded ones for Starbases), its sectors and their colonies (a sector's
    -- systems; the colony's final_designation)
    local function ship_size(sid)
        local ship = world.object("ship", tonumber(sid))
        local did = ship and tonumber(world.path(ship, "ship_design_implementation", "design"))
        local design = did and world.object("ship_design", did)
        local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
        return stage and tostring(world.field(stage, "ship_size") or ""):gsub('"', "") or ""
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
                location = system_name(origin),
                power = tonumber(world.field(f, "military_power")) or 0, order = k,
            }
            if world.path(f, "properties", "station") == "yes" then
                local sb = starbase_of[tonumber(ships[1])]
                if sb then
                    local level = tostring(world.field(sb, "level") or ""):gsub('"', "")
                    local has_yard = false
                    local mods = world.field(sb, "modules")
                    if type(mods) == "table" then
                        for _, m in ipairs(mods) do
                            if m.value and m.value.text == "shipyard" then
                                has_yard = true
                            end
                        end
                    end
                    e.sub = tostring(world.field(sb, "type") or ""):gsub('"', "")
                    e.level = level
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
                military[#military + 1] = e
            else
                e.kind = "civilian"
                e.sub = ship_size(ships[1])
                e.class = CLASS[e.sub] or 9
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
            for _, p in ipairs(planets) do
                if systems[p.system] then
                    local col = world.planet_colony and world.planet_colony[p.id]
                    local c = col and world.object("colony", col)
                    outliner[#outliner + 1] = {
                        kind = "planet", id = p.id, name = p.name, system = p.system, sector = sid, power = 0,
                        location = system_name(p.system),
                        sub = c and tostring(world.field(c, "final_designation") or ""):gsub('"', "") or "",
                    }
                end
            end
        end
    end
    return view
end

-- ---------------------------------------------------------------------------------------------
-- layout: the render thread's side
-- ---------------------------------------------------------------------------------------------

local ROW = {
    planet = { window = "outliner_member_planet_entry_window", only = { background = true, name = true, star = true, colony_type = true } },
    fleet = { window = "outliner_member_fleet_entry_window", only = { background = true, name = true, location = true, offensive_power = true } },
    civilian = { window = "outliner_member_fleet_civilian_entry_window", only = { background = true, name = true, type = true, location = true } },
    starbase = { window = "outliner_member_starbase_entry_window", only = { background = true, name = true, starbase_type = true, system = true, military_power = true } },
}

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

-- the groups of the Overview tab, from the view: { title, kind, rows, header, amount }
local function overview_groups(view, selected, fmt)
    local members = view.members or {}
    local function row_of(e)
        local sel = selected and ((selected.kind == "planet") == (e.kind == "planet")) and selected.id == e.id
        return {
            id = e.id, name = fmt(e.name), sub = e.sub or "", location = fmt(e.location),
            power = (e.power or 0) > 0 and si(math.floor(e.power + 0.5)) or "", selected = sel or nil,
        }
    end
    local groups = {}
    for _, g in ipairs({
        { "OUTLINER_CIVILIAN_FLEETS", "civilian", "civilian" },
        { "OUTLINER_FLEETS", "fleet", "military" },
        { "OUTLINER_STARBASES", "starbase", "starbase" },
        { "OUTLINER_SHIPYARDS", "starbase", "shipyard" },
    }) do
        local rows = {}
        for _, e in ipairs(members) do
            if e.kind == g[3] then
                rows[#rows + 1] = row_of(e)
            end
        end
        if #rows > 0 then
            groups[#groups + 1] = { title = g[1], kind = g[2], rows = rows }
        end
    end
    local sectors = view.sectors or {}
    if #sectors > 0 then
        groups[#groups + 1] = { title = "OUTLINER_SECTORS", kind = "sectors", rows = {}, amount = tostring(#sectors) }
        for _, s in ipairs(sectors) do
            local rows = {}
            for _, e in ipairs(members) do
                if e.kind == "planet" and e.sector == s.id then
                    rows[#rows + 1] = row_of(e)
                end
            end
            groups[#groups + 1] = { title = fmt(s.name), kind = "planet", rows = rows, header = "outliner_sector_title_entry_window" }
        end
    end
    return groups
end

function M.layout(ctx, data, items, report)
    local gui = require("render.gui")
    data = data or {}
    local view = data.view or {}
    local names = require("render.names")
    local function fmt(n)
        if type(n) ~= "table" then
            return ""
        end
        return names.format(ctx.loc, n)
    end
    local groups = overview_groups(view, data.selected, fmt)
    -- (the observer's toggle shows in observer mode only)
    local base = { texture_size = ctx.texture_size, loc = ctx.loc, hide = { observer_outliner_toggle = true } }
    -- the toggle and the tabs over the list
    for _, w in ipairs({ "outliner_controller_window", "tabs_outliner_window" }) do
        local i, r = gui.layout(ctx.game_dir, ctx.db, OUTLINER, w, ctx.screen, base)
        gui.merge(items, report, i, r)
    end
    -- the tab: as high as its rows, down to the screen's bottom margin (outliner_window_margin)
    local rows_h = 0
    for _, g in ipairs(groups) do
        rows_h = rows_h + 36 + 41 * #g.rows
    end
    local top = 186
    local h = math.min(40 + rows_h + 8, ctx.screen.height - top - 60)
    local tab_items, tab_report = gui.layout(ctx.game_dir, ctx.db, OUTLINER, "outliner_tab_window", ctx.screen, {
        texture_size = ctx.texture_size, loc = ctx.loc,
        sizes = { ["/outliner_tab_window"] = { 260, h } },
        text = { ["/outliner_tab_window/tab_name"] = "outliner_government" },
    })
    gui.merge(items, report, tab_items, tab_report)
    local list = tab_report.rects["/outliner_tab_window/list"] or { x = ctx.screen.width - 258, y = top + 40, w = 240, h = 0 }
    local y, bottom = list.y, top + h - 8
    for gi, g in ipairs(groups) do
        if y + 36 > bottom then
            break
        end
        local prefix = "/outliner/" .. gi
        local header = g.header or "outliner_title_entry_window"
        local hi, hr = gui.layout(ctx.game_dir, ctx.db, OUTLINER, header, ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = prefix,
            -- a list places its entries at its own coordinates (their orientation in a slot of
            -- their size)
            parent = { x = list.x, y = y, w = 0, h = 36 },
            hide = { selected_overlay = true },
            text = {
                [prefix .. "/" .. header .. "/title"] = g.title,
                [prefix .. "/" .. header .. "/amount"] = g.amount or tostring(#g.rows),
            },
        })
        gui.merge(items, report, hi, hr)
        y = y + 36
        local spec = ROW[g.kind]
        for k, row in ipairs(g.rows) do
            if y + 41 > bottom then
                break
            end
            local rp = prefix .. "/" .. k
            local path = rp .. "/" .. spec.window
            local text = {
                [path .. "/name"] = row.name or "",
                [path .. "/star"] = row.location or "",
                [path .. "/location"] = row.location or "",
                [path .. "/system"] = row.location or "",
                [path .. "/type"] = row.sub or "",
                [path .. "/starbase_type"] = row.sub or "",
                [path .. "/colony_type"] = row.sub or "",
                [path .. "/offensive_power"] = row.power or "",
                [path .. "/military_power"] = row.power or "",
            }
            local only = {}
            for n in pairs(spec.only) do
                only[n] = true
            end
            only.selected_overlay = row.selected or nil
            local ri, rr = gui.layout(ctx.game_dir, ctx.db, OUTLINER, spec.window, ctx.screen, {
                texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp, only = only, text = text,
                parent = { x = list.x, y = y, w = 0, h = 41 },
                actions = { [path .. "/background"] = "select:" .. (g.kind == "planet" and "planet" or "fleet") .. ":" .. tostring(row.id) },
            })
            gui.merge(items, report, ri, rr)
            y = y + 41
        end
    end
end

return M
