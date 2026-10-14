-- render/windows.lua : the main screen's windows for the selection, from the game's GUI files
-- (4.5.2; what opens and where: docs/render.md section 12), laid out by render.gui with the
-- texts the caller gives (names localised by render.names).
--
--   local windows = require("render.windows")
--   local items, report = windows.build(game_dir, db, screen, texture_size, loc, data)
--
-- data = {
--   outliner = { { title = "OUTLINER_PLANETS", kind = "planet"|"fleet"|"civilian"|"starbase",
--                  rows = { { id, name, sub, location, selected } } } ... },
--   selected = { kind = "fleet"|"starbase"|"planet", id, name, sub } | nil,
-- }
--
-- The outliner (interface/outliner.gui): outliner_controller_window, tabs_outliner_window and
-- outliner_tab_window (the Overview tab), its list filled with a group header
-- (outliner_title_entry_window) and the group's rows (outliner_member_*_entry_window) as far as
-- the window reaches down the screen. A planet opens planet_view (planet_view.gui), a fleet
-- fleet_view (fleet_view.gui, one fleet_view_entry), a starbase starbase_view
-- (starbase_view.gui): each with its name and close button; their other parts (lists, tabs,
-- the bars the game fills) are not drawn. A row's background and a window's close button carry
-- the actions `select:KIND:ID` and `close`.

local gui = require("render.gui")

local windows = {}

local OUTLINER = "interface/outliner.gui"

local ROW = {
    -- (the rows' icons, fleet sizes, status lists are not drawn yet)
    planet = { window = "outliner_member_planet_entry_window", only = { background = true, name = true, star = true, colony_type = true } },
    fleet = { window = "outliner_member_fleet_entry_window", only = { background = true, name = true, location = true, offensive_power = true } },
    civilian = { window = "outliner_member_fleet_civilian_entry_window", only = { background = true, name = true, type = true, location = true } },
    starbase = { window = "outliner_member_starbase_entry_window", only = { background = true, name = true, starbase_type = true, system = true, military_power = true } },
}

local function merge(items, report, more, more_report)
    gui.merge(items, report, more, more_report)
end

local function outliner(ctx, data, items, report)
    -- (the observer's toggle shows in observer mode only)
    local base = { texture_size = ctx.texture_size, loc = ctx.loc, hide = { observer_outliner_toggle = true } }
    -- the toggle and the tabs over the list
    for _, w in ipairs({ "outliner_controller_window", "tabs_outliner_window" }) do
        local i, r = gui.layout(ctx.game_dir, ctx.db, OUTLINER, w, ctx.screen, base)
        merge(items, report, i, r)
    end
    -- the tab: as high as its rows, down to the screen's bottom margin (outliner_window_margin)
    local rows_h = 0
    for _, g in ipairs(data.outliner or {}) do
        rows_h = rows_h + 36 + 41 * #g.rows
    end
    local top = 186
    local h = math.min(40 + rows_h + 8, ctx.screen.height - top - 60)
    local tab_items, tab_report = gui.layout(ctx.game_dir, ctx.db, OUTLINER, "outliner_tab_window", ctx.screen, {
        texture_size = ctx.texture_size, loc = ctx.loc,
        sizes = { ["/outliner_tab_window"] = { 260, h } },
        text = { ["/outliner_tab_window/tab_name"] = "outliner_government" },
    })
    merge(items, report, tab_items, tab_report)
    local list = tab_report.rects["/outliner_tab_window/list"] or { x = ctx.screen.width - 258, y = top + 40, w = 240, h = 0 }
    local y, bottom = list.y, top + h - 8
    for gi, g in ipairs(data.outliner or {}) do
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
        merge(items, report, hi, hr)
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
            merge(items, report, ri, rr)
            y = y + 41
        end
    end
end

local function selected_window(ctx, sel, items, report)
    if sel.kind == "fleet" then
        -- one fleet: the window grows up from its place by the row (fleet_view_entry, 259)
        local row_h = 259
        local wi, wr = gui.layout(ctx.game_dir, ctx.db, "interface/fleet_view.gui", "fleet_view", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc,
            sizes = { ["/fleet_view"] = { 510, 23 + row_h } },
            actions = { ["/fleet_view/header/close"] = "close" },
        })
        merge(items, report, wi, wr)
        local list = wr.rects["/fleet_view/fleets"]
        if list then
            local p = "/fleet_view/fleets/fleet_view_entry"
            local ri, rr = gui.layout(ctx.game_dir, ctx.db, "interface/fleet_view.gui", "fleet_view_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = ctx.loc, prefix = "/fleet_view/fleets",
                parent = { x = list.x, y = list.y, w = 510, h = row_h },
                only = { top = true },
                hide = {
                    flag = true, rename_button = true, unknown_faction_name = true,
                    toggle_armada_commanding_mode = true, open_fleet_manager = true, go_to_planet_view = true,
                },
                text = { [p .. "/top/fleet_name"] = sel.name or "", [p .. "/top/fleet_type"] = sel.sub or "" },
                actions = { [p .. "/top/deselect"] = "close" },
            })
            merge(items, report, ri, rr)
        end
    elseif sel.kind == "starbase" then
        local h = ctx.screen.height >= 801 and 765 or 611
        local wi, wr = gui.layout(ctx.game_dir, ctx.db, "interface/starbase_view.gui", "starbase_view", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc,
            sizes = { ["/starbase_view"] = { 562, h } },
            only = { planet_bg_top = true, starbase_bg_bottom = true, empire_header_line = true, hex_bg = true, name = true, header_actions = true },
            text = { ["/starbase_view/name"] = sel.name or "" },
            actions = { ["/starbase_view/header_actions/close"] = "close" },
        })
        merge(items, report, wi, wr)
    elseif sel.kind == "planet" then
        local wi, wr = gui.layout(ctx.game_dir, ctx.db, "interface/planet_view.gui", "planet_view", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc,
            sizes = { ["/planet_view"] = { 1162, 680 } },
            only = { planet_view_bg = true, planet_name = true, header_actions = true },
            text = { ["/planet_view/planet_name"] = sel.name or "" },
            actions = { ["/planet_view/header_actions/close"] = "close" },
        })
        merge(items, report, wi, wr)
    end
end

-- windows.specs(game_dir, db, screen, texture_size, loc, specs) -> items, report: windows laid
-- out one after the other, each spec { file, window, only, hide, text, frames, actions, sizes,
-- prefix, parent = { x, y, w, h } } as render.gui's options (lists of names become sets)
function windows.specs(game_dir, db, screen, texture_size, loc, specs)
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local function set(list)
        if not list then
            return nil
        end
        local s = {}
        for _, n in ipairs(list) do
            s[n] = true
        end
        return s
    end
    for _, s in ipairs(specs) do
        local ok, i, r = pcall(gui.layout, game_dir, db, s.file, s.window, screen, {
            texture_size = texture_size, loc = loc, only = set(s.only), hide = set(s.hide), text = s.text,
            frames = s.frames, actions = s.actions, sizes = s.sizes, prefix = s.prefix, parent = s.parent,
            positions = s.positions, sprites = s.sprites, tints = s.tints,
        })
        if ok then
            merge(items, report, i, r)
        else
            report.missing_sprites[#report.missing_sprites + 1] = tostring(s.window) .. ": " .. tostring(i)
        end
    end
    return items, report
end

function windows.build(game_dir, db, screen, texture_size, loc, data)
    local ctx = { game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc }
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    outliner(ctx, data, items, report)
    if data.selected then
        selected_window(ctx, data.selected, items, report)
    end
    return items, report
end

return windows
