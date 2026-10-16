-- render/newgame_creator.lua : the empire creator (interface/customize_species.gui,
-- customize_species_editors.gui; the game's CCustomizeSpeciesView and its editors;
-- docs/windows/newgame_creator.md), opened from the empire selection (Create New, Edit) of
-- render.frontend_newgame. The rules (lists, points, picks, errors) are render.creator_rules';
-- the editors' screens render.creator_editors'.
--
--   creator.build(game_dir, db, screen, texture_size, loc, state, base) -> { items, report }
--   creator.act(state, action) -> nil (stay), "done" (the design handed to
--       render.newgame_setup.set_design) or "cancel"
--
-- state is the new game's setup (RENDER_NEWGAME); the creator keeps its own in state.creator:
-- { design, base, editor, focus, scroll, view } . base is what the selection had (state.empire:
-- { kind, key, design }): a custom design is edited, a prescripted block converted, none gives
-- the game's new design.
--
-- The screen: the menu on the left (customize_species_view: its sections and buttons, an editor
-- with errors in red), the design's preview (render.empire_preview) and the editor open over its
-- lower part.

local C = require("render.windows.empire_common")
local rules = require("render.creator_rules")
local preview = require("render.empire_preview")
local editors = require("render.creator_editors")

local creator = {}

local MAIN = "interface/customize_species.gui"
local V = "/customize_species_view"

-- the positionTypes of customize_species.gui (the menu's section sizes and button places)
local positions_cache
local function positions(game_dir)
    if positions_cache then
        return positions_cache
    end
    local source = require("stellar.script.source")
    local tree = source.parse(game_dir, MAIN) or {}
    local out, vars = {}, {}
    local function scan(block)
        for _, e in ipairs(block) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                vars[e.key.text] = e.value.text
            elseif e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                if e.key.text == "guiTypes" then
                    scan(e.value)
                elseif e.key.text == "positionType" then
                    local pos = C.raw_field(e.value, "position")
                    local function n(v)
                        v = v and (vars[v] or v)
                        return tonumber(v)
                    end
                    out[C.field(e.value, "name")] = { n(C.field(pos, "x")) or 0, n(C.field(pos, "y")) or 0 }
                end
            end
        end
    end
    scan(tree)
    positions_cache = out
    return out
end

-- the creator's state for the setup's empire
function creator.open(state, base)
    local R = rules.load(state.game_dir)
    if state.dlcs then
        local names = {}
        for k, v in pairs(state.dlcs) do
            if v then
                names[#names + 1] = k
            end
        end
        rules.set_owned(R, names)
    end
    local d
    if base and type(base.design) == "table" then
        if base.design.species and base.design.species.class then
            d = rules.copy(base.design)
        else
            d = rules.from_block(base.design, base.key)
            -- an edited prescripted design becomes the player's (CEmpireDesign copy) [I]
            d.key = ""
        end
    else
        d = rules.default_design(R)
    end
    local st = { design = d, base = base, editor = "portrait", scroll = {}, view = {}, focus = nil }
    state.creator = st
    return st
end

-- the editors the menu shows (EmpireAdvisorEditorIsVisible: the advisor only with a choice of
-- voices [I: hidden in the game's frame]; the secondary species only with an origin that has one)
function creator.menu_editors(R, d)
    local out = {}
    for _, s in ipairs(rules.SECTIONS) do
        local list = {}
        for _, k in ipairs(s.editors) do
            if k ~= "advisor" then
                list[#list + 1] = k
            end
        end
        out[#out + 1] = { window = s.window, editors = list }
    end
    return out
end

-- the editors in the menu's order (Back / Next of an editor step through them)
local function order(R, d)
    local out = {}
    for _, s in ipairs(creator.menu_editors(R, d)) do
        for _, k in ipairs(s.editors) do
            out[#out + 1] = k
        end
    end
    return out
end

local function err_text(ctx, e)
    local t = C.raw(ctx, e.key)
    for k, v in pairs(e.args or {}) do
        t = t:gsub("%$" .. k .. "%$", C.loc(ctx, v))
    end
    return t
end
creator.err_text = err_text

-- the menu (customize_species_view's `menu`, its list of sections)
local function build_menu(ctx, b, st, R, d, errors)
    local pos = positions(ctx.game_dir)
    local r = b:add(MAIN, "customize_species_view", {
        hide = { species_preview_done_button = true, locked_content_checkbox = true },
        actions = {
            [V .. "/menu/save"] = "creator:save",
            [V .. "/menu/next"] = "creator:done",
            [V .. "/menu/back"] = "creator:cancel",
        },
    })
    -- the checkbox at its positionType (the gui file puts it off screen; CCustomizeSpeciesView
    -- moves it to locked_content_checkbox_position) [V: the file's comment, the game's frame]
    local menu = r.rects[V .. "/menu"]
    local cb = pos.locked_content_checkbox_position
    if menu and cb then
        b:add(MAIN, "customize_species_view", {
            only = { menu = true },
            hide = { background = true, editors_list = true, locked_content_label = true, save = true, next = true, back = true },
            positions = { [V .. "/menu/locked_content_checkbox"] = { cb[1], cb[2] } },
            actions = { [V .. "/menu/locked_content_checkbox"] = "creator:toggle_locked" },
            frames = { [V .. "/menu/locked_content_checkbox"] = st.hide_locked and 2 or 1 },
            prefix = "/locked",
        })
    end
    local list = r.rects[V .. "/menu/editors_list"]
    if not list then
        return
    end
    local y = list.y
    for _, sec in ipairs(creator.menu_editors(R, d)) do
        local n = #sec.editors
        local size = pos["customize_species_view_menu_section_size_" .. n .. "_buttons"] or { 220, 80 }
        local hide, text, actions, positions_, frames = {}, {}, {}, {}, {}
        local S = "/menu_sections/" .. sec.window .. "/" .. sec.window
        local shown = {}
        for i, k in ipairs(sec.editors) do
            shown[rules.BY_KEY[k].button] = i
        end
        for _, e in ipairs(rules.EDITORS) do
            local path = S .. "/" .. e.button
            local i = shown[e.button]
            if not i then
                hide[path] = true
            else
                local p = pos["customize_species_view_menu_button_pos_" .. i] or { -2, 33 + 27 * (i - 1) }
                positions_[path] = { p[1], p[2] }
                actions[path] = "creator:menu:" .. e.key
                -- an editor with errors: its label red (CCustomizeSpeciesViewEditorMenuSectionItem::
                -- UpdateEntry; the game's frame) [I: the colour code]
                if #(errors[e.key] or {}) > 0 then
                    text[path] = "§R" .. C.loc(ctx, editors.button_text(ctx, e)) .. "§!"
                end
                -- the open editor's button: its selected frame [I: the game's frame shows it lit]
                if st.editor == e.key then
                    frames[path] = 3
                end
            end
        end
        b:add(MAIN, sec.window, {
            prefix = "/menu_sections/" .. sec.window,
            parent = { x = list.x, y = y, w = size[1], h = size[2] },
            hide = hide, text = text, actions = actions, positions = positions_, frames = frames,
        })
        y = y + size[2]
    end
end

function creator.build(game_dir, db, screen, texture_size, loc, state, base)
    state.game_dir = state.game_dir or game_dir
    local st = state.creator
    if not st or st.base ~= base then
        st = creator.open(state, base)
    end
    local ctx = { game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc }
    local R = rules.load(game_dir)
    local d = st.design
    local b = C.builder(ctx)
    local _, errors = rules.validate(R, d)
    st.errors = errors
    -- the preview (its lower part under the editor), the editor over it, the menu
    preview.build(ctx, b, d, { hide_lower = true, actions = {} })
    editors.build(ctx, b, st, R, d)
    build_menu(ctx, b, st, R, d, errors)
    b.report.note = "empire creator: " .. st.editor
    return { items = b.items, report = b.report }
end

-- the design valid: handed to the setup (render.newgame_setup.set_design)
local function finish(state, st)
    local ok, setup = pcall(require, "render.newgame_setup")
    if ok and setup.set_design then
        setup.set_design(state, st.design)
    else
        state.empire = { kind = "custom", design = st.design }
    end
    state.creator = nil
end

function creator.act(state, action)
    local st = state.creator
    if not st then
        return "cancel"
    end
    local R = rules.load(state.game_dir)
    local d = st.design
    local verb, rest = action:match("^creator:([%w_]+):?(.*)$")
    if verb == "cancel" then
        -- CCustomizeSpeciesView::OnBack -> ConfirmedBack (the confirmation not drawn) [I]
        state.creator = nil
        return "cancel"
    elseif verb == "done" or verb == "save" then
        -- OnDone / OnSave: with errors, ShowFirstEditorWithError; else the design is kept
        local ok, all = rules.validate(R, d)
        if not ok then
            for _, k in ipairs(order(R, d)) do
                if #(all[k] or {}) > 0 then
                    st.editor = k
                    break
                end
            end
            return nil
        end
        if verb == "save" then
            -- CEmpireDesignDatabase::SaveDesign: the user's designs [I: kept in the setup's list]
            st.saved = true
            return nil
        end
        finish(state, st)
        return "done"
    elseif verb == "menu" then
        if rules.BY_KEY[rest] then
            st.editor = rest
            st.focus = nil
        end
        return nil
    elseif verb == "prev" or verb == "next" then
        local list = order(R, d)
        for i, k in ipairs(list) do
            if k == st.editor then
                local j = verb == "prev" and i - 1 or i + 1
                if list[j] then
                    st.editor = list[j]
                    st.focus = nil
                end
                break
            end
        end
        return nil
    elseif verb == "toggle_locked" then
        st.hide_locked = not st.hide_locked
        return nil
    end
    editors.act(st, R, d, verb, rest)
    return nil
end

return creator
