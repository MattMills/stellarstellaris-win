-- render/frontend.lua : the game's front end from its GUI files: the main menu
-- (interface/frontend.gui) and the load game window (interface/loadgame_view.gui), laid out with
-- render.gui, texts localised with engine.localisation, buttons given actions.
--
--   local frontend = require("render.frontend")
--   frontend.menu(game_dir, db, screen, texture_size, loc, version)  -> { items, report, background }
--   frontend.load_window(game_dir, db, screen, texture_size, loc, saves) -> { items, report }
--
-- The menu is three windows of frontend.gui: frontend_background (its `animated_background` is a
-- render target the game draws its 3D scene into), frontend_background_view (the links at the
-- bottom) and frontendgui (the gradient, the logo, the buttons New Game / Load Game /
-- Multiplayer / Cooperative / Additional Content / Settings / Credits / Exit, the version).
--
-- The 3D scene is not drawn: in its place, a still. common/frontend_backgrounds names the scenes
-- (the one with `default = yes` is shown); its entity (gfx/models/ui/*.asset) attaches a
-- pdxmesh (gfx/models/ui/*.gfx) whose `background` mesh's texture_diffuse is the scene's
-- backdrop, drawn to cover the screen.

local source = require("stellar.script.source")
local gui = require("render.gui")
local get = require("render.gfx").get

local frontend = {}

-- the menu's buttons: their container -> action
frontend.ACTIONS = {
    start_game_container = "new_game",
    load_game_container = "open_load",
    multiplayer_container = "multiplayer",
    coop_container = "coop",
    additional_content_container = "additional_content",
    settings_container = "settings",
    credits_container = "credits",
    quit_container = "exit",
}

-- blocks of a list block, statements by key (any case)
local function each(block, key, f)
    key = key:lower()
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key and type(e.value) == "table" and e.value.text == nil then
            f(e.value)
        end
    end
end

-- the backdrop of the front end's default 3D scene: { tag, entity, mesh, texture } or nil, why
function frontend.background(game_dir)
    local defs = source.definitions(game_dir, "common/frontend_backgrounds")
    local tag, entity
    local names = {}
    for name in pairs(defs) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b)
        return (defs[a].line or 0) < (defs[b].line or 0)
    end)
    for _, name in ipairs(names) do
        local d = defs[name]
        if get(d.block, "default") == "yes" or not tag then
            tag, entity = name, get(d.block, "entity")
        end
    end
    if not entity then
        return nil, "no frontend background"
    end
    -- the entity's first attached entity's pdxmesh
    local assets = {}
    for _, f in ipairs(source.files(game_dir, "gfx/models/ui", "asset")) do
        local tree = source.parse(game_dir, f)
        each(tree, "entity", function(e)
            assets[get(e, "name") or ""] = e
        end)
    end
    local root = assets[entity]
    if not root then
        return nil, "no entity " .. entity
    end
    local mesh = get(root, "pdxmesh")
    if not mesh then
        each(root, "attach", function(a)
            if mesh then
                return
            end
            for _, s in ipairs(a) do
                if s.op and s.value.text and assets[s.value.text] then
                    mesh = mesh or get(assets[s.value.text], "pdxmesh")
                end
            end
        end)
    end
    if not mesh then
        return nil, "entity " .. entity .. " has no mesh"
    end
    -- the mesh's backdrop texture
    for _, f in ipairs(source.files(game_dir, "gfx/models/ui", "gfx")) do
        local tree = source.parse(game_dir, f)
        local found
        each(tree, "objectTypes", function(ot)
            each(ot, "pdxmesh", function(m)
                if get(m, "name") == mesh and not found then
                    local dir = (get(m, "file") or f):match("^(.*)/[^/]*$") or "gfx/models/ui"
                    local first
                    each(m, "meshsettings", function(s)
                        local tex = get(s, "texture_diffuse")
                        local n = (get(s, "name") or ""):lower()
                        first = first or tex
                        if tex and not found and (n:find("background", 1, true) or n:find("bg", 1, true)) then
                            found = dir .. "/" .. tex
                        end
                    end)
                    found = found or (first and dir .. "/" .. first)
                end
            end)
        end)
        if found then
            return { tag = tag, entity = entity, mesh = mesh, texture = found }
        end
    end
    return nil, "no pdxmesh " .. mesh
end

-- the menu at a screen's size; `modal`: a window is open over it (the menu's blocker shades it)
function frontend.menu(game_dir, db, screen, texture_size, loc, version, modal)
    local actions, hide = {}, {
        -- the 3D scene's render target (a still is drawn instead), the portrait room, the list of
        -- new content (filled at run time) and the invisible version button
        animated_background = true, portrait_room = true, additional_content_whats_new = true,
        version_button = true,
        -- the shade over the menu while a window is open
        blocker = not modal,
    }
    for container, action in pairs(frontend.ACTIONS) do
        actions["/frontendgui/menu/buttons/" .. container .. "/button"] = action
    end
    local opts = {
        hide = hide, actions = actions, texture_size = texture_size, loc = loc,
        text = { ["/frontendgui/menu/version"] = version or "" },
    }
    local items, report = {}, { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    -- the still under everything
    local bg, why = frontend.background(game_dir)
    if bg then
        local tw, th = texture_size(bg.texture)
        if tw then
            local s = math.max(screen.width / tw, screen.height / th)
            local w, h = tw * s, th * s
            items[1] = {
                kind = "sprite", path = "/frontend_background/animated_background", sprite = bg.mesh,
                texture = bg.texture, sprite_kind = "still", frame = 1, frames = 1,
                x = (screen.width - w) / 2, y = (screen.height - h) / 2, w = w, h = h,
            }
            report.sprites = 1
        else
            why = "no texture " .. bg.texture
        end
    end
    for _, window in ipairs({ "frontend_background", "frontend_background_view", "frontendgui" }) do
        local it, r = gui.layout(game_dir, db, "interface/frontend.gui", window, screen, opts)
        gui.merge(items, report, it, r)
    end
    return { items = items, report = report, background = bg, background_missing = why }
end

-- the load screen (interface/load_screen.gui, window load_screen; RenderLoadScreen): the
-- picture (gfx/loadingscreens, newgame.rs picks it) covering the screen, the status window's
-- progress bar (GFX_progressbar_933) at `percent` and its text (`key` localised: START_NEW_GAME,
-- LOAD_MAP_GFX, ...) in the load_screen font. The tip window is off the screen (y = -99999).
function frontend.load_screen(game_dir, db, screen, texture_size, loc, key, percent, picture)
    local items, report = {}, { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    if picture then
        local tw, th = texture_size(picture)
        if tw then
            local s = math.max(screen.width / tw, screen.height / th)
            local w, h = tw * s, th * s
            items[1] = {
                kind = "sprite", path = "/load_screen/picture", sprite = picture, texture = picture,
                sprite_kind = "still", frame = 1, frames = 1,
                x = (screen.width - w) / 2, y = (screen.height - h) / 2, w = w, h = h,
            }
            report.sprites = 1
        else
            report.missing_sprites[#report.missing_sprites + 1] = picture
        end
    end
    local text = loc and (loc.get(key)) or key
    local opts = {
        texture_size = texture_size, loc = loc,
        hide = { tip = true },
        text = { ["/load_screen/status/text"] = text },
        progress = { ["/load_screen/status/progress"] = math.max(0, math.min(100, percent)) / 100 },
    }
    local it, r = gui.layout(game_dir, db, "interface/load_screen.gui", "load_screen", screen, opts)
    gui.merge(items, report, it, r)
    return { items = items, report = report }
end

-- the load game window over the menu: one LoadGameSessionEntry per session (a save folder), the
-- selected session's details and saves (render.loadgame); saves = { { name, date, file, path,
-- dir, meta, modified } } newest first
function frontend.load_window(game_dir, db, screen, texture_size, loc, saves)
    return require("render.loadgame").build(game_dir, db, screen, texture_size, loc, saves)
end

-- an action of the load window ("loadwin:..."): the save to load, or nil
function frontend.load_act(action)
    return require("render.loadgame").act(action)
end

return frontend
