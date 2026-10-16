-- render/windows.lua : the main screen's windows for the selection, from the game's GUI files
-- (4.5.2; what opens and where: docs/render.md section 12), laid out by render.gui with the
-- texts the caller gives (names localised by render.names).
--
--   local windows = require("render.windows")
--   local items, report = windows.build(game_dir, db, screen, texture_size, loc, data)
--
-- data = {
--   selected = { kind = "fleet"|"starbase"|"planet", id, name, sub } | nil,
-- }
--
-- The outliner: render.windows.outliner (its own module; RENDER_OUTLINER, outliner.rs). A
-- planet opens planet_view (planet_view.gui), a fleet fleet_view (fleet_view.gui, one
-- fleet_view_entry), a starbase starbase_view (starbase_view.gui): each with its name and close
-- button; their other parts (lists, tabs, the bars the game fills) are not drawn. A row's
-- background and a window's close button carry the actions `select:KIND:ID` and `close`.

local gui = require("render.gui")

local windows = {}

local function merge(items, report, more, more_report)
    gui.merge(items, report, more, more_report)
end

-- the outliner (render.windows.outliner: its own module), from RENDER_OUTLINER (outliner.rs)
local function outliner(ctx, items, report)
    require("render.windows.outliner").layout(ctx, RENDER_OUTLINER, items, report)
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
        -- the planet view: render.windows.planet (its data from RENDER_PLANET)
        require("render.windows.planet").build(ctx, sel, items, report)
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
    outliner(ctx, items, report)
    if data.selected then
        selected_window(ctx, data.selected, items, report)
    end
    return items, report
end

return windows
