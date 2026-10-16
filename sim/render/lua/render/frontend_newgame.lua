-- render/frontend_newgame.lua : the new game's screens after the main menu's New Game, from the
-- game's GUI files: the empire selection (interface/select_empire_design.gui with the preview of
-- interface/new_game_setup.gui), the empire creator (render.newgame_creator) and the galaxy
-- settings (interface/game_setup/setup.gui: gamesetup_setupview and its setting entries), over the
-- front end's still; their buttons' actions on the setup state (render.newgame_setup,
-- RENDER_NEWGAME).
--
--   local fe = require("render.frontend_newgame")
--   fe.build(game_dir, db, screen, texture_size, loc, name)  -> { items, report, note }
--       name: "select", "creator", "setup"
--   fe.act(game_dir, action, x, y) -> the screen to go to ("menu", "select", "creator", "setup",
--       "play") or nil: the actions are "ng:..." (and the creator's "creator:...")
--
-- The game's classes: CFrontEndIdler (StartNewGame, SetGuiView, GoBackFromGameSetup),
-- CSelectEmpireDesignView, CSpeciesPreviewWindow, CGameSetupView / CGameSetupGalaxyView and the
-- CGameSetup*Picker entries (docs/windows/newgame_flow.md).

local gui = require("render.gui")
local frontend = require("render.frontend")
local gfx = require("render.gfx")
local get = gfx.get
local setup = require("render.newgame_setup")
local widgets = require("render.newgame_widgets")

local fe = {}

local SETUP_GUI = "interface/game_setup/setup.gui"
local SELECT_GUI = "interface/select_empire_design.gui"
local PREVIEW_GUI = "interface/new_game_setup.gui"

local function new_report()
    return { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {}, grids = {} }
end

local function merge(items, report, it, r)
    gui.merge(items, report, it, r)
    for k, v in pairs(r.rects or {}) do
        report.rects[k] = v
    end
    for k, v in pairs(r.grids or {}) do
        report.grids[k] = v
    end
end

-- the front end's still under the screens (its 3D scene goes on behind them in the game)
local function still(game_dir, screen, texture_size, items, report)
    local bg = frontend.background(game_dir)
    if not bg then
        return
    end
    local tw, th = texture_size(bg.texture)
    if not tw then
        return
    end
    local s = math.max(screen.width / tw, screen.height / th)
    local w, h = tw * s, th * s
    items[#items + 1] = {
        kind = "sprite", path = "/frontend_background/animated_background", sprite = bg.mesh,
        texture = bg.texture, sprite_kind = "still", frame = 1, frames = 1,
        x = (screen.width - w) / 2, y = (screen.height - h) / 2, w = w, h = h,
    }
    report.sprites = report.sprites + 1
end

-- an element of a .gui window by path of names (its block)
local function find_block(game_dir, file, path)
    local block = gui.find(game_dir, file, path[1])
    for i = 2, #path do
        local found
        for _, e in ipairs(block or {}) do
            if not found and e.op and e.key and type(e.value) == "table" and get(e.value, "name") == path[i] then
                found = e.value
            end
        end
        block = found
    end
    return block
end

-- ---------------------------------------------------------------- the galaxy settings

-- an entry's window per setting kind (game_setup/setup.gui) and its height
local ENTRY = {
    spinner = "gamesetup_spinner_entry", slider = "gamesetup_scrollbar_entry",
    checkbox = "gamesetup_checkbox_entry", shapes = "gamesetup_icon_picker_entry",
    precursors = "gamesetup_precursor_entry",
}

-- the shapes the size offers, with their icons (GFX_galaxy_button_<shape>)
local function shapes_of(state)
    local out = {}
    local size
    for _, s in ipairs(state.sizes) do
        if s.name == state.galaxy.galaxy_size then
            size = s
        end
    end
    for _, e in ipairs(size and size.block or {}) do
        if e.op and e.key and e.key.text == "supports_shape" and e.value.text then
            out[#out + 1] = e.value.text
        end
    end
    return out
end

-- one setting entry at (x, y): its items; its height
local function setting_entry(ctx, state, token, x, y, width)
    local d = state.defs[token]
    local loc = ctx.loc
    local window = ENTRY[d.kind]
    local prefix = "/settings/" .. token
    local opts = {
        texture_size = ctx.texture_size, loc = loc, prefix = prefix,
        parent = { x = x, y = y, w = width, h = 40 },
        text = {}, hide = {}, sprites = {}, frames = {}, actions = {},
    }
    local base = prefix .. "/" .. window
    opts.text[base .. "/label"] = d.label
    if d.kind == "spinner" then
        opts.text[base .. "/spinner_container/pick_text"] = setup.text(state, token, loc)
        if d.bar then
            local i = 1
            for k, o in ipairs(d.options) do
                if o[1] == state.galaxy[token] then
                    i = k
                end
            end
            opts.sprites[base .. "/spinner_container/bar"] = "GFX_difficulty_bar_" .. i
        else
            opts.hide[base .. "/spinner_container/bar"] = true
        end
    elseif d.kind == "slider" then
        opts.text[base .. "/pick_text"] = setup.text(state, token, loc)
        if not d.randomize then
            opts.hide[base .. "/randomize_checkbox"] = true
        else
            opts.frames[base .. "/randomize_checkbox"] = state.random[token] and 2 or 1
            opts.actions[base .. "/randomize_checkbox"] = "ng:random:" .. token
        end
    elseif d.kind == "checkbox" then
        opts.text[base .. "/checkbox_container/pick_text"] = setup.text(state, token, loc)
        opts.frames[base .. "/checkbox_container/checkbox"] = state.galaxy[token] and 2 or 1
        opts.actions[base .. "/checkbox_container/checkbox"] = "ng:toggle:" .. token
    end
    local items, report = gui.layout(ctx.game_dir, ctx.db, SETUP_GUI, window, ctx.screen, opts)
    merge(ctx.items, ctx.report, items, report)
    local h = 40
    if d.kind == "spinner" then
        local r = report.rects[base .. "/spinner_container/spinner"]
        local def = find_block(ctx.game_dir, SETUP_GUI, { window, "spinner_container", "spinner" })
        if r and def then
            widgets.spinner(ctx, def, r, base .. "/spinner_container/spinner", { left = "ng:step:" .. token .. ":-1", right = "ng:step:" .. token .. ":1" })
        end
    elseif d.kind == "slider" then
        local r = report.rects[base .. "/scrollbar_container/scrollbar"]
        local def = find_block(ctx.game_dir, SETUP_GUI, { window, "scrollbar_container", "scrollbar" })
        if r and def then
            widgets.slider(ctx, def, r, base .. "/scrollbar_container/scrollbar", setup.fraction(state, token), {
                left = "ng:step:" .. token .. ":-1", right = "ng:step:" .. token .. ":1", track = "ng:track:" .. token,
            })
            ctx.tracks[token] = r
        end
    elseif d.kind == "shapes" then
        -- the shapes' icons in the options grid, the chosen one in its third frame [I]
        local g = report.grids[base .. "/options"]
        local list = shapes_of(state)
        if g then
            for i, shape in ipairs(list) do
                local sx, sy = gui.grid_slot(g, i - 1, #list)
                if sx then
                    local oprefix = base .. "/options/" .. i
                    local oopts = {
                        texture_size = ctx.texture_size, loc = loc, prefix = oprefix,
                        parent = { x = sx, y = sy, w = g.sx, h = g.sy },
                        sprites = { [oprefix .. "/gamesetup_icon_picker_option_entry/button_container/button"] = "GFX_galaxy_button_" .. shape },
                        frames = { [oprefix .. "/gamesetup_icon_picker_option_entry/button_container/button"] = shape == state.galaxy.galaxy_shape and 3 or nil },
                        text = { [oprefix .. "/gamesetup_icon_picker_option_entry/label"] = shape },
                        actions = { [oprefix .. "/gamesetup_icon_picker_option_entry/button_container/button"] = "ng:set:galaxy_shape:" .. shape },
                    }
                    local it, r = gui.layout(ctx.game_dir, ctx.db, SETUP_GUI, "gamesetup_icon_picker_option_entry", ctx.screen, oopts)
                    merge(ctx.items, ctx.report, it, r)
                end
            end
            local rows = math.ceil(#list / math.max(1, g.max_h > 0 and g.max_h or 5))
            h = 30 + rows * g.sy
        end
    end
    return h
end

-- the galaxy settings screen
local function build_setup(ctx, state)
    local loc = ctx.loc
    local s = setup.settings(state)
    local e = state.empire or {}
    local opts = {
        texture_size = ctx.texture_size, loc = loc,
        text = {}, hide = {}, sprites = {}, frames = {}, actions = {},
    }
    local V = "/gamesetup_setupview"
    opts.sprites[V .. "/galaxy_preview/galaxy_shape_image/galaxy_shape_preview"] = "GFX_galaxy_preview_" .. tostring(s.shape)
    opts.frames[V .. "/general_settings_tab"] = state.tab == 1 and 2 or 1
    opts.frames[V .. "/advanced_settings_tab"] = state.tab == 2 and 2 or 1
    opts.actions[V .. "/general_settings_tab"] = "ng:tab:1"
    opts.actions[V .. "/advanced_settings_tab"] = "ng:tab:2"
    opts.actions[V .. "/back_button"] = "ng:back"
    opts.actions[V .. "/next_button"] = "ng:play"
    opts.actions[V .. "/reset_button"] = "ng:reset"
    -- the player's empire and species (filled from the design: render.newgame_design)
    local P = V .. "/galaxy_preview/player_container"
    local SP = V .. "/galaxy_preview/species_container"
    local texts = ctx.design_texts or {}
    opts.text[P .. "/empire_name"] = texts.name or ""
    opts.text[P .. "/player_name"] = texts.player or ""
    opts.text[SP .. "/species_name"] = texts.species_name or ""
    opts.text[SP .. "/species_class"] = texts.species_class or ""
    opts.text[SP .. "/government_authority_name"] = texts.authority or ""
    opts.text[SP .. "/origin_name"] = texts.origin or ""
    opts.textures = {
        [SP .. "/government_authority_icon"] = texts.authority_icon,
        [SP .. "/origin_icon"] = texts.origin_icon,
    }
    if e.kind == "random" then
        opts.hide[P .. "/empire_flag"] = true
        opts.hide[SP .. "/portrait_window/portrait"] = true
    else
        opts.hide[P .. "/random_empire_flag"] = true
        opts.hide[SP .. "/portrait_window/random_portrait"] = true
    end
    -- (the portrait is 3D: not drawn)
    opts.hide[SP .. "/portrait_window/portrait"] = true
    local items, report = gui.layout(ctx.game_dir, ctx.db, SETUP_GUI, "gamesetup_setupview", ctx.screen, opts)
    -- the player's flag: a creator design's empire_flag composed on the element's sprite
    -- (GFX_empire_flag_128), as the creator's preview composes it (render.empire_preview)
    local flag = type(e.design) == "table" and e.design.empire_flag
    if type(flag) == "table" and e.kind ~= "random" then
        local tex = require("render.empire_preview").flag_texture(ctx, "GFX_empire_flag_128", flag)
        for _, it in ipairs(tex and items or {}) do
            if it.path == P .. "/empire_flag" and it.kind == "sprite" then
                it.texture = tex
                it.sprite_kind = "flagSpriteType"
                it.frames, it.frame = 1, 1
            end
        end
    end
    merge(ctx.items, ctx.report, items, report)

    -- the AI empires' previews: one per AI empire, advanced and fallen ones after [I]
    local grid = report.grids[V .. "/galaxy_preview/ai_empires_container/ai_empires"]
    if grid then
        local n = (s.empires or 0) + (s.fallen_empires or 0)
        local k = 0
        for i = 1, n do
            local sx, sy = gui.grid_slot(grid, k, n)
            if sx then
                local p = "/ai_empires/" .. i
                local frame = 1
                local sprite = "GFX_random_ai_preview"
                if i > (s.empires or 0) then
                    sprite = "GFX_random_ai_preview_fallen"
                elseif i > (s.empires or 0) - (s.advanced_empires or 0) then
                    sprite = "GFX_random_ai_preview_advanced"
                end
                local it, r = gui.layout(ctx.game_dir, ctx.db, SETUP_GUI, "ai_empire_preview_entry", ctx.screen, {
                    texture_size = ctx.texture_size, loc = loc, prefix = p,
                    parent = { x = sx, y = sy, w = grid.sx, h = grid.sy },
                    hide = { ai_empire_flag = true, ai_empire_minor_alert = true, ai_empire_major_alert = true },
                    sprites = { [p .. "/ai_empire_preview_entry/ai_random_empire_flag"] = sprite },
                    frames = { [p .. "/ai_empire_preview_entry/ai_random_empire_flag"] = frame },
                })
                merge(ctx.items, ctx.report, it, r)
                k = k + 1
            end
        end
    end

    -- the settings list: the tab's categories, one gamesetup_category_entry each
    local list = report.rects[V .. "/settings_container/gamesetup_settings_categories_list"]
    if not list then
        return
    end
    local def = find_block(ctx.game_dir, SETUP_GUI, { "gamesetup_setupview", "settings_container", "gamesetup_settings_categories_list" })
    local bs = def and get(def, "borderSize")
    local bx = tonumber(bs and get(bs, "x")) or 0
    local by = tonumber(bs and get(bs, "y")) or 0
    local spacing = tonumber(def and get(def, "spacing")) or 0
    local box = { x = list.x, y = list.y, w = list.w, h = list.h }
    widgets.clip(ctx.items, box)
    local y = list.y + by - state.scroll.setup
    local total = 0
    for ci, cat in ipairs(setup.categories(state, state.tab)) do
        local cprefix = "/categories/" .. ci
        local cbase = cprefix .. "/gamesetup_category_entry"
        -- the entries first (their heights make the category's)
        local sub = { items = {}, report = new_report() }
        local saved_items, saved_report = ctx.items, ctx.report
        ctx.items, ctx.report = sub.items, sub.report
        local ey = 0
        local entries = {}
        for _, token in ipairs(cat.tokens) do
            entries[#entries + 1] = { token = token, y = ey }
            ey = ey + 40
            if state.defs[token].kind == "shapes" then
                ey = ey + 180 + 2 -- replaced below by the real height
            end
        end
        ctx.items, ctx.report = saved_items, saved_report
        -- the category's frame: header 34 + the list at 38, as high as its entries
        local cy = y
        local heights = 0
        local probe = { items = {}, report = new_report() }
        ctx.items, ctx.report = probe.items, probe.report
        for _, en in ipairs(entries) do
            heights = heights + setting_entry(ctx, state, en.token, -10000, -10000, 590)
        end
        ctx.items, ctx.report = saved_items, saved_report
        local ch = 38 + heights
        local it, r = gui.layout(ctx.game_dir, ctx.db, SETUP_GUI, "gamesetup_category_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = loc, prefix = cprefix,
            parent = { x = list.x + bx, y = cy, w = 615, h = ch },
            sizes = { [cbase] = { 615, ch } },
            text = { [cbase .. "/header_container/header"] = cat.name },
            hide = {
                [cbase .. "/header_container/randomize_text"] = cat.name ~= "GALAXY_SETTINGS_CATEGORY_EMPIRES",
                [cbase .. "/header_container/additional_text"] = cat.name ~= "GALAXY_SETTINGS_CATEGORY_PRECURSORS",
            },
        })
        merge(ctx.items, ctx.report, it, r)
        local lr = r.rects[cbase .. "/settings_list"] or { x = list.x + bx + 10, y = cy + 38, w = 615 }
        local yy = lr.y
        for _, en in ipairs(entries) do
            yy = yy + setting_entry(ctx, state, en.token, lr.x, yy, 590)
        end
        y = cy + ch + spacing
        total = total + ch + spacing
    end
    widgets.unclip(ctx.items)
    state.scroll.setup_max = math.max(0, total - spacing + 2 * by - list.h)
end

-- ---------------------------------------------------------------- the empire selection

local function build_select(ctx, state)
    local loc = ctx.loc
    local opts = {
        texture_size = ctx.texture_size, loc = loc,
        text = {}, hide = {}, sprites = {}, frames = {}, actions = {},
    }
    local V = "/select_empire_design_view"
    opts.actions[V .. "/back"] = "ng:back"
    opts.actions[V .. "/next"] = "ng:next"
    opts.actions[V .. "/edit"] = "ng:edit"
    opts.hide[V .. "/edit_custom"] = true
    opts.hide[V .. "/quick_start"] = true
    opts.hide[V .. "/close"] = true
    local items, report = gui.layout(ctx.game_dir, ctx.db, SELECT_GUI, "select_empire_design_view", ctx.screen, opts)
    merge(ctx.items, ctx.report, items, report)
    local list = report.rects[V .. "/list"]
    if not list then
        return
    end
    widgets.clip(ctx.items, list)
    local y = list.y - state.scroll.select
    for i, d in ipairs(state.designs) do
        local window = d.kind == "random" and "random_empire_design_entry"
            or d.kind == "custom" and (d.user and "user_empire_design_entry" or "custom_empire_design_entry")
            or "prescripted_empire_design_entry"
        local p = "/designs/" .. i
        local base = p .. "/" .. window
        local t = ctx.design_texts_of and ctx.design_texts_of(d) or {}
        local eopts = {
            texture_size = ctx.texture_size, loc = loc, prefix = p,
            parent = { x = list.x, y = y, w = list.w, h = 65 },
            hide = { [base .. "/selected_overlay"] = i ~= state.selected, portrait = true, portrait_substitution_indicator = true, spawn_setting = true },
            text = { [base .. "/name"] = t.name, [base .. "/government"] = t.government, [base .. "/species_class"] = t.species_class },
            actions = { [base] = "ng:design:" .. i },
        }
        local it, r = gui.layout(ctx.game_dir, ctx.db, SELECT_GUI, window, ctx.screen, eopts)
        merge(ctx.items, ctx.report, it, r)
        local er = r.rects[base]
        y = y + (er and er.h or 65) + 5
    end
    widgets.unclip(ctx.items)
end

-- ---------------------------------------------------------------- the screens

local function state_of(game_dir)
    if not RENDER_NEWGAME then
        RENDER_NEWGAME = setup.new(game_dir)
    end
    return RENDER_NEWGAME
end

function fe.build(game_dir, db, screen, texture_size, loc, name)
    local state = state_of(game_dir)
    local ctx = {
        game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc,
        items = {}, report = new_report(), tracks = {},
    }
    local ok, design = pcall(require, "render.newgame_design")
    if ok then
        ctx.design_texts_of = function(d)
            return design.texts(game_dir, loc, d)
        end
        -- (the empire chosen: a prescripted design, or the creator's after Done)
        ctx.design_texts = design.texts(game_dir, loc, state.empire or state.designs[state.selected] or {})
    end
    still(game_dir, screen, texture_size, ctx.items, ctx.report)
    if name == "select" then
        build_select(ctx, state)
    elseif name == "setup" then
        build_setup(ctx, state)
    elseif name == "creator" then
        local creator = require("render.newgame_creator")
        local r = creator.build(game_dir, db, screen, texture_size, loc, state, state.empire)
        for _, it in ipairs(r.items or {}) do
            ctx.items[#ctx.items + 1] = it
        end
    end
    state.tracks = ctx.tracks
    return { items = ctx.items, report = ctx.report, note = "new game: " .. name .. ", " .. setup.summary(state) }
end

-- an action on the setup state; the screen to go to, or nil
function fe.act(game_dir, action, x, y)
    if action == "ng:open" then
        RENDER_NEWGAME = setup.new(game_dir)
        return "select"
    end
    local state = state_of(game_dir)
    local verb, rest = action:match("^ng:([%w_]+):?(.*)$")
    if action:sub(1, 8) == "creator:" then
        local r = require("render.newgame_creator").act(state, action)
        -- Done goes on to the galaxy settings with the new design (the game's frame: Game
        -- Details shows it); Back returns to the empire selection
        if r == "done" then
            state.screen = "setup"
            return "setup"
        elseif r == "cancel" then
            state.screen = "select"
            return "select"
        end
        return nil
    end
    if verb == "back" then
        -- the galaxy settings go back to the empire selection, that to the menu
        -- (CFrontEndIdler::GoBackFromGameSetup)
        if state.screen == "setup" then
            state.screen = "select"
            return "select"
        end
        state.screen = nil
        return "menu"
    elseif verb == "accept" then
        if state.screen == "setup" then
            return "play"
        end
        state.screen = "setup"
        return "setup"
    elseif verb == "next" then
        local d = state.designs[state.selected]
        if d and d.kind == "custom" and not d.design then
            state.screen = "creator"
            return "creator"
        end
        state.screen = "setup"
        return "setup"
    elseif verb == "edit" then
        state.screen = "creator"
        return "creator"
    elseif verb == "play" then
        return "play"
    elseif verb == "design" then
        setup.select(state, tonumber(rest))
    elseif verb == "tab" then
        state.tab = tonumber(rest) or 1
        state.scroll.setup = 0
    elseif verb == "reset" then
        setup.reset_galaxy(state)
    elseif verb == "step" then
        local token, dir = rest:match("^([%w_]+):(-?%d+)$")
        setup.step(state, token, tonumber(dir))
    elseif verb == "toggle" then
        setup.step(state, rest, 1)
    elseif verb == "random" then
        state.random[rest] = not state.random[rest]
    elseif verb == "set" then
        local token, value = rest:match("^([%w_]+):(.*)$")
        setup.set(state, token, tonumber(value) or value)
    elseif verb == "track" then
        local r = state.tracks and state.tracks[rest]
        if r and x then
            local range = setup.range(state, rest)
            local f = math.max(0, math.min(1, (x - r.x) / math.max(1, r.w)))
            setup.set(state, rest, range.min + f * (range.max - range.min))
        end
    elseif verb == "wheel" then
        local n = tonumber(rest) or 0
        local key = state.screen == "setup" and "setup" or "select"
        local max = state.scroll[key .. "_max"] or 0
        state.scroll[key] = math.max(0, math.min(max, state.scroll[key] - n * 40))
    end
    return nil
end

return fe
