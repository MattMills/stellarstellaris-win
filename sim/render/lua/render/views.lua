-- render/views.lua : the left bar's views (the game's top bar views, ETopBarView; the renderer's
-- sim/render/src/views.rs), one module each in render/windows/:
--
--   M.data(country_id, state) -> a table of plain values: what the view shows of the save, read
--       in the runtime that has the world (engine.world); copied to the front end's runtime
--   M.build(ctx, data, state) -> items, report: the view laid out (render.gui), in the front
--       end's runtime: ctx = { game_dir, db, screen, texture_size, loc }
--
-- state is what the view remembers between frames (its tab, the leader selected ...), strings
-- set by its buttons' actions `view_set:KEY=VALUE`; `view_close` closes the view, `view:NAME`
-- opens another. A view without a module draws nothing.

local views = {}

views.MODULES = {
    empire = "render.windows.empire",
    government = "render.windows.government",
    leaders = "render.windows.leaders",
    council = "render.windows.council",
    edicts = "render.windows.edicts",
    factions = "render.windows.factions",
    species = "render.windows.species",
}

local function module(name)
    local m = views.MODULES[name]
    if not m then
        return nil
    end
    local ok, mod = pcall(require, m)
    if not ok then
        error(mod)
    end
    return mod
end

-- the player's country id (meta.player), 0 if none
function views.player()
    return require("render.topbar").player()
end

function views.data(name, state)
    local m = module(name)
    if not (m and m.data) then
        return {}
    end
    return m.data(views.player(), state or {})
end

function views.build(name, game_dir, db, screen, texture_size, loc, data, state)
    local m = module(name)
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    if not (m and m.build) then
        return items, report
    end
    local ctx = { game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc }
    return m.build(ctx, data or {}, state or {})
end

return views
