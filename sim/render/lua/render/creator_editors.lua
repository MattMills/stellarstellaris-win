-- render/creator_editors.lua : the empire creator's editors (interface/customize_species_editors.gui,
-- customize_species_shipsets.gui, species_portrait_picker_view.gui; the game's
-- CSpeciesPortraitEditor, CEmpireEthicsGovEditor, CEmpireOriginEditor, CSpeciesTraitsEditor,
-- CNameListEditor, CSpeciesNameEditor, CHomeWorldEditor, CEmpireFlagEditor, the city and room
-- editor, CShipGfxCultureEditor, CEmpireRulerEditor, CRulerTraitEditor). render.newgame_creator
-- shows the open one; their clicks come back as creator:VERB:ARG (editors.act).
--
--   editors.build(ctx, b, st, R, d)        -- the open editor (st.editor) laid out into b
--   editors.act(st, R, d, verb, arg)       -- a click or a key on it
--
-- What the game draws in 3D is left out and noted: portraits (the grid's frames are drawn, not the
-- characters), the home world's planets (their buttons, without the planets), the ship set's ship.

local C = require("render.windows.empire_common")
local gui = require("render.gui")
local rules = require("render.creator_rules")
local preview = require("render.empire_preview")

local editors = {}

local FILE = "interface/customize_species_editors.gui"
local SHIPS = "interface/customize_species_shipsets.gui"
local PICKER = "interface/species_portrait_picker_view.gui"

local function loc(ctx, k)
    return C.loc(ctx, k)
end

-- a menu button's label key (customize_species.gui's buttonText)
function editors.button_text(ctx, e)
    local w = gui.find(ctx.game_dir, "interface/customize_species.gui", "customize_species_view_menu_entry_background")
    local found
    for _, sec in ipairs({ "customize_species_view_menu_entry_background", "customize_species_view_menu_entry_empire",
        "customize_species_view_menu_entry_ruler" }) do
        local win = gui.find(ctx.game_dir, "interface/customize_species.gui", sec)
        for _, x in ipairs(win or {}) do
            if x.op and x.key and type(x.value) == "table" and C.field(x.value, "name") == e.button then
                found = C.field(x.value, "buttonText")
            end
        end
    end
    return found or e.label
end

-- entries laid out down a list's rectangle (a smoothListbox: one under the other, `spacing`
-- apart), those that start inside it drawn [I: the scroll position at the top]
local function list_entries(b, file, window, rect, n, h, spacing, prefix, opts_of)
    if not rect then
        return
    end
    local y = rect.y
    for i = 1, n do
        if y >= rect.y + rect.h then
            break
        end
        local p = prefix .. "/" .. i
        local o = opts_of(i, p .. "/" .. window) or {}
        o.prefix = p
        o.parent = { x = rect.x, y = y, w = rect.w, h = h }
        b:add(file, window, o)
        y = y + h + (spacing or 0)
    end
end

-- entries in a grid box's slots (gui.grid_slot), those inside its rectangle
local function grid_entries(b, file, window, grid, n, prefix, opts_of, row_limit)
    if not grid then
        return
    end
    for i = 1, n do
        local x, y = gui.grid_slot(grid, i - 1, n)
        if not x or y >= grid.y + grid.h or (row_limit and y + grid.sy > grid.y + grid.h + grid.sy * 0.5) then
            break
        end
        local p = prefix .. "/" .. i
        local o = opts_of(i, p .. "/" .. window) or {}
        o.prefix = p
        o.parent = { x = x, y = y, w = grid.sx, h = grid.sy }
        b:add(file, window, o)
    end
end

-- the text a field shows: the player's text, or a key's localisation
local function shown(ctx, s)
    return preview.text_of(ctx, s)
end

-- an edit box's action (focus) over its rectangle, with the field's text
local function edit_box(ctx, b, st, rect, field_key, value)
    if not rect then
        return
    end
    local text = shown(ctx, value)
    if st.focus == field_key then
        text = text .. "|"
    end
    b.items[#b.items + 1] = {
        kind = "text", path = "/edit/" .. field_key, font = "malgun_goth_24", text = text,
        spans = { { text = text, colour = { 1, 1, 1 } } }, x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        format = "left", valign = "center", fixed = true,
    }
    local s = ctx.db.sprites.GFX_invisible
    if s and s.texture then
        b.items[#b.items + 1] = {
            kind = "sprite", path = "/edit/" .. field_key .. "/hit", sprite = "GFX_invisible", texture = s.texture,
            sprite_kind = "spriteType", frame = 1, frames = s.frames or 1, x = rect.x, y = rect.y, w = rect.w, h = rect.h,
            button = { name = field_key, action = "creator:focus:" .. field_key },
        }
    end
end

-- ---------------------------------------------------------------------------------------------
-- the editors

local E = {}

-- Species & Portrait (species_portrait_editor): the categories, the category's portraits
E.portrait = function(ctx, b, st, R, d, W, o)
    local cats = rules.portrait_categories(R)
    st.view.category = st.view.category or (function()
        for _, c in ipairs(cats) do
            for _, p in ipairs(rules.category_portraits(R, c.key)) do
                if p.portrait == d.species.portrait then
                    return c.key
                end
            end
        end
        return cats[1] and cats[1].key
    end)()
    local r = b:add(FILE, "species_portrait_editor", o)
    list_entries(b, FILE, "species_portrait_category_entry", r.rects[W .. "/categories"], #cats, 28, 1, "/portrait_categories",
        function(i, E_)
            local c = cats[i]
            return {
                text = { [E_ .. "/label"] = loc(ctx, c.name) },
                hide = { [E_ .. "/selected"] = c.key ~= st.view.category },
                actions = { [E_] = "creator:pcat:" .. c.key },
            }
        end)
    local ps = rules.category_portraits(R, st.view.category or "")
    st.view.portraits = ps
    local grid = r.report_grids and nil
    grid_entries(b, PICKER, "species_portrait_picker_entry", r.grids and r.grids[W .. "/portraits_container/portraits"], #ps,
        "/portraits", function(i, E_)
            return {
                hide = { [E_ .. "/selected"] = ps[i].portrait ~= d.species.portrait, portrait = true,
                    not_eligible = true, portrait_overlay = true, portrait_substitution_indicator = true },
                actions = { [E_] = "creator:portrait:" .. i },
            }
        end)
end

-- Government & Ethics (empire_ethics_and_government_editor)
E.ethics = function(ctx, b, st, R, d, W, o)
    local G = W .. "/ethics"
    o.text[G .. "/ethic_points_left"] = (C.raw(ctx, "POINTS_LEFT_ETHICS"):gsub("%$[%w_|]+%$", "§Y" .. rules.ethic_points_left(R, d) .. "§!"))
    o.text[W .. "/civic_points_left"] = (C.raw(ctx, "POINTS_LEFT_CIVICS"):gsub("%$[%w_|]+%$", "§Y" .. rules.civic_points_left(R, d) .. "§!"))
    -- the ethics' buttons: frame 1 normal, 2 chosen [I: the sprite's frames], greyed when they
    -- cannot be added; the category's `selected` ring hidden (the game's frame shows none)
    for _, e in ipairs(R.ethics) do
        local path = G .. "/" .. e.key
        o.actions[path] = "creator:ethic:" .. e.key
        if rules.ethic_playable(R, d, e.key) == false then
            o.disabled[path] = true
        end
    end
    for _, n in ipairs({ "col", "xen", "mil", "spi", "hive" }) do
        o.hide[G .. "/ethic_" .. n .. "_selected"] = true
    end
    local chosen = {}
    for _, k in ipairs(d.ethics) do
        chosen[k] = true
    end
    for _, e in ipairs(R.ethics) do
        local path = G .. "/" .. e.key
        if chosen[e.key] then
            o.frames[path] = 2
        elseif not rules.can_add_ethic(R, d, e.key) then
            o.frames[path] = 3
        end
    end
    -- the authority's name and description; the government type
    local a = d.authority and R.authority[d.authority]
    o.text[W .. "/authority_description/desc"] = a and (loc(ctx, a.key) .. "\n" .. loc(ctx, a.key .. "_desc"))
        or ("§Y" .. loc(ctx, "NO_AUTHORITY_SELECTED") .. "§!\n" .. loc(ctx, "NO_AUTHORITY_SELECTED_DESC"))
    o.text[W .. "/government_type"] = d.government and loc(ctx, d.government) or ""
    o.hide[W .. "/nomad_toggle_container"] = true
    local r = b:add(FILE, "empire_ethics_and_government_editor", o)
    -- the authorities (government_entry in authority_grid)
    local auths = rules.authorities(R, d)
    grid_entries(b, FILE, "government_entry", r.grids and r.grids[W .. "/authority_grid"], #auths, "/authorities",
        function(i, E_)
            local a_ = auths[i]
            local ok = rules.authority_ok(R, d, a_.key)
            return {
                hide = { [E_ .. "/selected"] = d.authority ~= a_.key, [E_ .. "/missing_dlc_overlay"] = true },
                textures = { [E_ .. "/icon"] = C.icon_file(ctx, "common/governments/authorities", a_.key,
                    "gfx/interface/icons/governments/authorities/" .. a_.key .. ".dds") },
                actions = { [E_ .. "/icon"] = "creator:authority:" .. a_.key },
                disabled = { [E_ .. "/icon"] = not ok or nil },
            }
        end)
    -- the civics: the available list, the chosen ones lit (customization_selected_civic_entry)
    local civics = rules.civic_list(R, d)
    table.sort(civics, function(x, y)
        return loc(ctx, x.key) < loc(ctx, y.key)
    end)
    local chosen_c = {}
    for _, c in ipairs(d.civics) do
        chosen_c[c] = true
    end
    list_entries(b, FILE, "customization_selected_civic_entry", r.rects[W .. "/civics/available_entries"], #civics, 32, 3,
        "/civics", function(i, E_)
            local g = civics[i]
            local ok = rules.civic_ok(R, d, g.key)
            return {
                text = { [E_ .. "/name"] = ok and loc(ctx, g.key) or ("§R" .. loc(ctx, g.key) .. "§!"), [E_ .. "/cost"] = tostring(g.cost) },
                textures = { [E_ .. "/icon"] = C.icon_file(ctx, "common/governments/civics", g.key,
                    "gfx/interface/icons/governments/civics/" .. g.key .. ".dds") },
                hide = { [E_ .. "/selected"] = not chosen_c[g.key] },
                actions = { [E_] = "creator:civic:" .. g.key },
            }
        end)
end

-- Origin (empire_origin_editor): the origins' cards, the chosen one's description
E.origin = function(ctx, b, st, R, d, W, o)
    local list = rules.origin_list(R, d)
    local og = R.civic[d.origin or ""]
    o.textures[W .. "/desc_window/selected_origin_icon"] = og and C.icon_file(ctx, "common/governments/civics", og.key,
        "gfx/interface/icons/governments/civics/" .. og.key .. ".dds")
    o.text[W .. "/desc_window/selected_origin_name"] = og and loc(ctx, og.key) or ""
    o.text[W .. "/desc_window/selected_origin_desc"] = og and loc(ctx, og.key .. "_desc") or ""
    local r = b:add(FILE, "empire_origin_editor", o)
    grid_entries(b, FILE, "empire_origin_entry", r.grids and r.grids[W .. "/origins_window/origins"], #list, "/origins",
        function(i, E_)
            local g = list[i]
            local ok = rules.origin_ok(R, d, g.key)
            return {
                text = { [E_ .. "/name"] = ok and loc(ctx, g.key) or ("§G" .. loc(ctx, g.key) .. "§!") },
                sprites = { [E_ .. "/picture_frame/picture"] = g.picture },
                hide = { [E_ .. "/selected"] = g.key ~= d.origin, [E_ .. "/missing_dlc_overlay"] = true },
                actions = { [E_] = "creator:origin:" .. g.key },
                disabled = { [E_ .. "/picture_frame"] = not ok or nil },
            }
        end, true)
end

-- a species trait's icon (common/traits `icon`, else gfx/interface/icons/traits/<key>.dds)
local function trait_icon(ctx, key)
    return C.icon_file(ctx, "common/traits", key, "gfx/interface/icons/traits/" .. key .. ".dds")
end

-- Traits (species_traits_editor): points and picks left, the available traits, the chosen ones
E.traits = function(ctx, b, st, R, d, W, o)
    local pts, picks = rules.trait_points_left(R, d), rules.trait_picks_left(R, d)
    o.text[W .. "/trait_points"] = (pts < 0 and "§R" or "§G") .. pts .. "§!"
    o.text[W .. "/trait_picks"] = (picks < 0 and "§R" or "§G") .. picks .. "§!"
    o.hide[W .. "/details"] = true
    local r = b:add(FILE, "species_traits_editor", o)
    local avail = rules.trait_list(R, d)
    grid_entries(b, FILE, "customization_selected_trait_entry", r.grids and r.grids[W .. "/available/entries"], #avail, "/traits_available",
        function(i, E_)
            local t = avail[i]
            local can = rules.can_add_trait(R, d, t.key)
            local cost = t.cost
            return {
                text = { [E_ .. "/name"] = can and loc(ctx, t.key) or ("§G" .. loc(ctx, t.key) .. "§!"),
                    [E_ .. "/cost"] = (cost > 0 and "§R" or "§G") .. tostring(cost) .. "§!" },
                textures = { [E_ .. "/icon"] = trait_icon(ctx, t.key) },
                actions = { [E_] = "creator:trait:" .. t.key },
            }
        end)
    local cur = d.species.traits
    grid_entries(b, FILE, "customization_selected_trait_entry", r.grids and r.grids[W .. "/current/entries"], #cur, "/traits_current",
        function(i, E_)
            local t = R.trait[cur[i]] or { key = cur[i], cost = 0 }
            return {
                text = { [E_ .. "/name"] = loc(ctx, t.key), [E_ .. "/cost"] = (t.cost > 0 and "§R" or "§G") .. tostring(t.cost) .. "§!" },
                textures = { [E_ .. "/icon"] = trait_icon(ctx, t.key) },
                actions = { [E_] = "creator:trait:" .. t.key },
            }
        end)
end

-- a name list's name in the editor ("Humanoid 1": the list's key localised, name_list_<KEY>)
local function name_list_name(ctx, k)
    for _, key in ipairs({ "name_list_" .. k, k }) do
        if ctx.loc and ctx.loc.has(key) then
            return loc(ctx, key)
        end
    end
    return k
end

-- names from a name list's block: `path` keys in order, the first n tokens found
local function names_from(R, ctx, list, path, n)
    local nl = R.name_list[list or ""]
    if not nl then
        return ""
    end
    local out = {}
    local function walk(blk, depth)
        for _, e in ipairs(type(blk) == "table" and blk or {}) do
            if #out >= n then
                return
            end
            if e.text then
                out[#out + 1] = loc(ctx, e.text:gsub('"', ""))
            elseif e.op and e.key and type(e.value) == "table" and depth < 4 then
                walk(e.value, depth + 1)
            end
        end
    end
    local blk = C.raw_field(nl.block, path)
    walk(blk, 0)
    return table.concat(out, ", ")
end

-- Name Lists (empire_name_list_editor): the ship prefix, the lists, examples
E.name_list = function(ctx, b, st, R, d, W, o)
    local lists = {}
    for _, n in ipairs(R.name_lists) do
        if rules.trigger(R, n.playable) ~= false and n.key ~= "AI" then
            lists[#lists + 1] = n
        end
    end
    table.sort(lists, function(x, y)
        return name_list_name(ctx, x.key) < name_list_name(ctx, y.key)
    end)
    -- examples [I: the game draws random names (CNameListEditor::UpdateExamples); the first ones here]
    o.text[W .. "/leaders/names"] = names_from(R, ctx, d.species.name_list, "character_names", 12)
    o.text[W .. "/planets/names"] = names_from(R, ctx, d.species.name_list, "planet_names", 8)
    o.text[W .. "/ships/names"] = names_from(R, ctx, d.species.name_list, "ship_names", 8)
    o.text[W .. "/fleets/names"] = names_from(R, ctx, d.species.name_list, "fleet_names", 4)
    local r = b:add(FILE, "empire_name_list_editor", o)
    edit_box(ctx, b, st, r.rects[W .. "/prefix"], "ship_prefix", d.ship_prefix)
    -- the list scrolled so the chosen one shows [I: the game's frame shows Humanoid 1 at the bottom]
    local first = 1
    local rect = r.rects[W .. "/available/entries"]
    if rect then
        local per = math.floor(rect.h / 32)
        for i, n in ipairs(lists) do
            if n.key == d.species.name_list and i > per then
                first = i - per + 1
            end
        end
    end
    local shown_ = {}
    for i = first, #lists do
        shown_[#shown_ + 1] = lists[i]
    end
    list_entries(b, FILE, "namelist_group_entry", rect, #shown_, 32, 0, "/name_lists", function(i, E_)
        local n = shown_[i]
        return {
            text = { [E_ .. "/label"] = name_list_name(ctx, n.key) },
            hide = { [E_ .. "/selected"] = n.key ~= d.species.name_list },
            actions = { [E_] = "creator:namelist:" .. n.key },
        }
    end)
end

-- Empire & Species Names (species_name_editor)
E.names = function(ctx, b, st, R, d, W, o)
    o.text[W .. "/headline_label"] = loc(ctx, "SPECIES_EMPIRE_NAME")
    local S = W .. "/species_name_editor_new/gender"
    for _, g in ipairs({ "DEFAULT_GENDER", "male", "female", "indeterminable" }) do
        o.actions[S .. "/" .. g] = "creator:gender:" .. g
    end
    local gsel = { not_set = "DEFAULT_GENDER", male = "male", female = "female", indeterminable = "indeterminable" }
    o.frames[S .. "/" .. (gsel[d.species.gender or "not_set"] or "DEFAULT_GENDER")] = 2
    o.actions[W .. "/species_name_editor_new/randomize_species_name"] = "creator:randomize:species_name"
    o.actions[W .. "/species_name_editor_new/generate_adjective"] = "creator:randomize:species_adjective"
    o.actions[W .. "/empire_name_editor_new/randomize_empire_name"] = "creator:randomize:empire_name"
    local r = b:add(FILE, "species_name_editor", o)
    local N = W .. "/species_name_editor_new"
    edit_box(ctx, b, st, r.rects[N .. "/species_name_container/species_name"], "species_name", d.species.name)
    edit_box(ctx, b, st, r.rects[N .. "/species_name_plural_container/species_plural"], "species_plural", d.species.plural)
    edit_box(ctx, b, st, r.rects[N .. "/species_name_adjective_container/species_adjective"], "species_adjective", d.species.adjective)
    edit_box(ctx, b, st, r.rects[N .. "/species_biography_container/bio"], "biography", d.biography)
    local M = W .. "/empire_name_editor_new"
    edit_box(ctx, b, st, r.rects[M .. "/empire_name_container/empire_name"], "empire_name", d.name)
    edit_box(ctx, b, st, r.rects[M .. "/empire_name_adjective_container/empire_adjective"], "empire_adjective", d.adjective)
end

-- Homeworld (planet_class_editor): the names, the starting system, the planet classes
E.homeworld = function(ctx, b, st, R, d, W, o)
    local D = W .. "/3d_icons"
    for _, p in ipairs({ "pc_desert", "pc_arid", "pc_savannah", "pc_ocean", "pc_continental", "pc_tropical", "pc_arctic",
        "pc_alpine", "pc_tundra" }) do
        o.actions[D .. "/" .. p] = "creator:planet:" .. p
    end
    o.hide[D .. "/pc_volcanic"] = true
    o.hide[D .. "/TYPE_HEADER_04"] = true
    o.hide[W .. "/3d_icons_arkships"] = true
    o.actions[W .. "/randomize_name"] = "creator:randomize:homeworld"
    o.actions[W .. "/initializer_box/initializer_dropdown"] = "creator:initializer_menu"
    local init = d.initializer ~= "" and R.initializer[d.initializer]
    o.text[W .. "/initializer_box/initializer_dropdown/selected_initializer_name"] = init and loc(ctx, init.name or init.key)
        or loc(ctx, "RANDOM")
    if st.view.initializer_open then
        o.open = { [W .. "/initializer_box/initializer_dropdown"] = true }
    end
    -- the planet class's description in the details on the right [I: drawn as text]
    local r = b:add(FILE, "planet_class_editor", o)
    edit_box(ctx, b, st, r.rects[W .. "/homeworld_box/name"], "planet_name", d.planet_name)
    edit_box(ctx, b, st, r.rects[W .. "/system_box/name"], "system_name", d.system_name)
    -- the chosen class: its selection ring over its button
    local pr = r.rects[D .. "/" .. (d.planet_class or "")]
    local sel = ctx.db.sprites.GFX_planet_selection_ring or ctx.db.sprites.GFX_glow_tile_orange
    if pr and sel then
        b:sprite("/homeworld/selected", ctx.db.sprites.GFX_planet_selection_ring and "GFX_planet_selection_ring" or "GFX_glow_tile_orange",
            pr.x - 2, pr.y - 2, pr.w + 4, pr.h + 4)
    end
    if st.view.initializer_open then
        local lr = r.rects[W .. "/initializer_box/initializer_dropdown/initializer_dropdown_content/initializer_dropdown_list"]
        local items = { { key = "", name = "RANDOM" } }
        for _, i in ipairs(R.initializers) do
            items[#items + 1] = { key = i.key, name = i.name or i.key }
        end
        list_entries(b, FILE, "system_initializer_dropdown_entry", lr, #items, 25, 0, "/initializers", function(i, E_)
            return { text = { [E_ .. "/name"] = loc(ctx, items[i].name) }, actions = { [E_] = "creator:initializer:" .. items[i].key } }
        end)
    end
end

-- Flag (empire_flag_editor): the emblem's categories and emblems, the colours, the backgrounds
local flag_cache = {}
local function flag_parts(ctx)
    if flag_cache[ctx.game_dir] then
        return flag_cache[ctx.game_dir]
    end
    local source = require("stellar.script.source")
    local dirs = RENDER_SUBDIRS and RENDER_SUBDIRS("flags") or {}
    local cats, files = {}, {}
    for _, dir in ipairs(dirs) do
        local name = dir:match("^flags/([^/]+)$")
        if name and name ~= "backgrounds" and name ~= "special" and name ~= "pirate" and name ~= "fallen_empires" then
            local list = source.files(ctx.game_dir, dir, "dds") or {}
            if #list > 0 then
                cats[#cats + 1] = name
                files[name] = {}
                for _, f in ipairs(list) do
                    files[name][#files[name] + 1] = f:match("([^/]+)$")
                end
            end
        end
    end
    local bgs = {}
    for _, f in ipairs(source.files(ctx.game_dir, "flags/backgrounds", "dds") or {}) do
        bgs[#bgs + 1] = f:match("([^/]+)$")
    end
    flag_cache[ctx.game_dir] = { cats = cats, files = files, backgrounds = bgs }
    return flag_cache[ctx.game_dir]
end

E.flag = function(ctx, b, st, R, d, W, o)
    local fp = flag_parts(ctx)
    local f = d.empire_flag
    st.view.flag_category = st.view.flag_category or (f.icon and f.icon.category) or fp.cats[1]
    st.view.color_slot = st.view.color_slot or 1
    local slots = { "primary_color", "secondary_color", "border_color", "fill_color" }
    for i, s in ipairs(slots) do
        o.actions[W .. "/" .. s] = "creator:color_slot:" .. i
        if st.view.color_slot == i then
            o.frames[W .. "/" .. s] = 3
        end
    end
    o.hide[W .. "/use_map_color"] = false
    o.actions[W .. "/use_map_color"] = "creator:toggle_map_color"
    local cols = preview.flag_colours(ctx.game_dir)
    for i, s in ipairs(slots) do
        local c = cols[(f.colors or {})[i] or ""]
        if c then
            o.tints[W .. "/" .. s .. "_preview/swatch"] = { c[1], c[2], c[3], 1 }
        end
    end
    local r = b:add(FILE, "empire_flag_editor", o)
    list_entries(b, FILE, "flag_symbol_category_entry", r.rects[W .. "/categories"], #fp.cats, 30, 0, "/flag_categories",
        function(i, E_)
            local c = fp.cats[i]
            return {
                text = { [E_ .. "/name"] = loc(ctx, "flag_category_" .. c) ~= "flag_category_" .. c and loc(ctx, "flag_category_" .. c)
                    or (c:sub(1, 1):upper() .. c:sub(2)) },
                hide = { [E_ .. "/selected"] = c ~= st.view.flag_category },
                actions = { [E_] = "creator:flag_category:" .. c },
            }
        end)
    local emblems = fp.files[st.view.flag_category] or {}
    grid_entries(b, FILE, "flag_texture_entry", r.grids and r.grids[W .. "/symbols_window/symbols"], #emblems, "/flag_symbols",
        function(i, E_)
            local file = "flags/" .. st.view.flag_category .. "/small/" .. emblems[i]
            if not ctx.texture_size(file) then
                file = "flags/" .. st.view.flag_category .. "/" .. emblems[i]
            end
            return {
                textures = { [E_ .. "/flag"] = file },
                sizes = { [E_ .. "/flag"] = { 60, 60 } },
                hide = { [E_ .. "/highlight"] = not (f.icon and f.icon.file == emblems[i] and f.icon.category == st.view.flag_category) },
                actions = { [E_ .. "/flag"] = "creator:flag_symbol:" .. emblems[i] },
            }
        end, true)
    -- the colours (color_entry: a swatch each, flags/colors.txt's order)
    local names = preview.colour_names(ctx.game_dir)
    grid_entries(b, FILE, "color_entry", r.grids and r.grids[W .. "/colors"], #names, "/flag_colors", function(i, E_)
        local c = cols[names[i]]
        return {

            sizes = { [E_ .. "/select_color"] = { 20, 20 } },
            tints = c and { [E_ .. "/select_color"] = { c[1], c[2], c[3], 1 } } or nil,
            hide = { [E_ .. "/highlight"] = (f.colors or {})[st.view.color_slot] ~= names[i] },
            actions = { [E_ .. "/select_color"] = "creator:flag_color:" .. names[i] },
        }
    end, true)
    -- the backgrounds (flag_texture_entry each: the flag with that background)
    grid_entries(b, FILE, "flag_texture_entry", r.grids and r.grids[W .. "/patterns_window/patterns"], #fp.backgrounds, "/flag_patterns",
        function(i, E_)
            local fl = { icon = { category = "", file = "" }, background = { category = "backgrounds", file = fp.backgrounds[i] }, colors = f.colors }
            local tex = preview.flag_texture(ctx, "GFX_empire_flag_64", fl) or preview.flag_texture(ctx, "GFX_empire_flag_200", fl)
            return {
                textures = tex and { [E_ .. "/flag"] = tex } or nil,
                sizes = { [E_ .. "/flag"] = { 60, 60 } },
                hide = { [E_ .. "/highlight"] = not (f.background and f.background.file == fp.backgrounds[i]) },
                actions = { [E_ .. "/flag"] = "creator:flag_background:" .. fp.backgrounds[i] },
            }
        end, true)
end

-- City & Room (planet_city_gfx_culture_editor): the city sets or the rooms
E.city = function(ctx, b, st, R, d, W, o)
    local tab = st.view.city_tab or "city"
    o.actions[W .. "/city_tab_button"] = "creator:city_tab:city"
    o.actions[W .. "/room_tab_button"] = "creator:city_tab:room"
    o.frames[W .. "/" .. tab .. "_tab_button"] = 3
    o.hide[W .. "/" .. (tab == "city" and "rooms_window" or "cities_window")] = true
    local r = b:add(FILE, "planet_city_gfx_culture_editor", o)
    if tab == "city" then
        local list = {}
        for _, g in ipairs(R.cultures) do
            if rules.trigger(R, g.selectable, rules.config(R, d)) ~= false and g.selectable ~= nil or (g.ship_color and g.selectable == nil) then
                if ctx.texture_size("gfx/portraits/city_sets/" .. g.key .. "_city_l03.dds") then
                    list[#list + 1] = g
                end
            end
        end
        grid_entries(b, FILE, "city_portrait_entry", r.grids and r.grids[W .. "/cities_window/cities_grid"], #list, "/cities",
            function(i, E_)
                local g = list[i]
                return {
                    textures = { [E_ .. "/button"] = "gfx/portraits/city_sets/" .. g.key .. "_city_l03.dds" },
                    sizes = { [E_ .. "/button"] = { 330, 160 } },
                    text = { [E_ .. "/culture"] = loc(ctx, g.key .. "_city") ~= g.key .. "_city" and loc(ctx, g.key .. "_city") or loc(ctx, g.key) },
                    hide = { [E_ .. "/selected"] = g.key ~= d.city_graphical_culture, [E_ .. "/missing_dlc_overlay"] = true },
                    actions = { [E_ .. "/button"] = "creator:city:" .. g.key },
                }
            end, true)
    else
        local rooms = { "default_room", "personality_hegemonic_imperialists_room", "personality_federation_builders_room",
            "personality_democratic_crusaders_room", "personality_evangelizing_zealots_room", "personality_migrating_flock_room" }
        grid_entries(b, FILE, "diplomacy_room_entry", r.grids and r.grids[W .. "/rooms_window/rooms_grid"], #rooms, "/rooms",
            function(i, E_)
                return {
                    textures = { [E_ .. "/button"] = "gfx/portraits/city_sets/" .. rooms[i] .. ".dds" },
                    sizes = { [E_ .. "/button"] = { 326, 116 } },
                    hide = { [E_ .. "/selected"] = (d.room ~= "" and d.room or "default_room") ~= rooms[i] },
                    actions = { [E_ .. "/button"] = "creator:room:" .. rooms[i] },
                }
            end, true)
    end
end

-- Shipsets (ship_gfx_culture_browser_editor): the ship sets in their groups; the ship not drawn
E.shipset = function(ctx, b, st, R, d, W, o)
    local r = b:add(SHIPS, "ship_gfx_culture_browser_editor", o)
end

-- Ruler Appearance (species_ruler_editor)
E.ruler = function(ctx, b, st, R, d, W, o)
    local G = W .. "/gender"
    o.actions[G .. "/male"] = "creator:ruler_gender:male"
    o.actions[G .. "/female"] = "creator:ruler_gender:female"
    o.actions[G .. "/indeterminable"] = "creator:ruler_gender:indeterminable"
    o.frames[G .. "/" .. (d.ruler.gender or "female")] = 2
    o.actions[W .. "/name_box/randomize_name"] = "creator:randomize:ruler_name"
    local r = b:add(FILE, "species_ruler_editor", o)
    edit_box(ctx, b, st, r.rects[W .. "/name_box/name"], "ruler_name", d.ruler.name)
end

-- Ruler Traits (ruler_traits_editor): the class, the starting traits, the chosen ones
E.ruler_traits = function(ctx, b, st, R, d, W, o)
    local pts = rules.ruler_points_left(R, d)
    o.text[W .. "/trait_points"] = (pts < 0 and "§R" or "§G") .. pts .. "§!"
    o.text[W .. "/ruler_class_spinner_container/spinner_value"] = loc(ctx, "leader_class_" .. (d.ruler.leader_class or ""))
        ~= "leader_class_" .. (d.ruler.leader_class or "") and loc(ctx, "leader_class_" .. d.ruler.leader_class) or loc(ctx, d.ruler.leader_class or "")
    o.hide[W .. "/details"] = true
    local r = b:add(FILE, "ruler_traits_editor", o)
    -- the class spinner's arrows: buttons at its ends [I: spinnerType is not laid out by render.gui]
    local sp = r.rects[W .. "/ruler_class_spinner_container/ruler_class_spinner"]
    if sp then
        local up, down = ctx.db.sprites.GFX_arrow_left and "GFX_arrow_left", ctx.db.sprites.GFX_arrow_right and "GFX_arrow_right"
        local function arrow(name, x, action)
            local s = name and ctx.db.sprites[name]
            if s and s.texture then
                b.items[#b.items + 1] = { kind = "sprite", path = "/ruler_class/" .. action, sprite = name, texture = s.texture,
                    sprite_kind = s.kind, frame = 1, frames = s.frames or 1, x = x, y = sp.y, w = 24, h = 24,
                    button = { name = action, action = "creator:" .. action } }
            end
        end
        arrow(up, sp.x - 4, "ruler_class_prev")
        arrow(down, sp.x + 130, "ruler_class_next")
    end
    local avail = rules.ruler_trait_list(R, d)
    grid_entries(b, FILE, "customization_ruler_trait_entry", r.grids and r.grids[W .. "/available/entries"], #avail, "/ruler_traits",
        function(i, E_)
            local t = avail[i]
            return {
                text = { [E_ .. "/name"] = loc(ctx, t.key), [E_ .. "/description"] = loc(ctx, t.key .. "_desc"),
                    [E_ .. "/cost"] = "§R" .. tostring(t.cost) .. "§!" },
                hide = { [E_ .. "/selected_icon"] = true },
                actions = { [E_] = "creator:ruler_trait:" .. t.key },
            }
        end)
    local cur = d.ruler.traits
    grid_entries(b, FILE, "customization_selected_ruler_trait_entry", r.grids and r.grids[W .. "/current/entries"], #cur, "/ruler_traits_current",
        function(i, E_)
            local t = R.trait[cur[i]] or { key = cur[i], cost = 0 }
            return {
                text = { [E_ .. "/name"] = loc(ctx, t.key), [E_ .. "/cost"] = "§R" .. tostring(t.cost) .. "§!" },
                actions = { [E_] = "creator:ruler_trait:" .. t.key },
            }
        end)
end

function editors.build(ctx, b, st, R, d)
    local e = rules.BY_KEY[st.editor] or rules.BY_KEY.portrait
    local W = "/" .. e.window
    local o = {
        text = {}, hide = {}, frames = {}, sprites = {}, textures = {}, tints = {}, disabled = {}, sizes = {},
        actions = { [W .. "/back"] = "creator:prev", [W .. "/apply_and_close"] = "creator:next" },
    }
    local f = E[e.key]
    if f then
        f(ctx, b, st, R, d, W, o)
    end
end

-- ---------------------------------------------------------------------------------------------
-- clicks and keys

local FIELDS = {
    species_name = function(d) return d.species, "name" end,
    species_plural = function(d) return d.species, "plural" end,
    species_adjective = function(d) return d.species, "adjective" end,
    empire_name = function(d) return d, "name" end,
    empire_adjective = function(d) return d, "adjective" end,
    biography = function(d) return d, "biography" end,
    planet_name = function(d) return d, "planet_name" end,
    system_name = function(d) return d, "system_name" end,
    ship_prefix = function(d) return d, "ship_prefix" end,
    ruler_name = function(d) return d.ruler, "name" end,
}

-- random names [I: the game draws them from the name list (CSpeciesNameEditor::RandomizeSpeciesName,
-- CHomeWorldEditor::RandomizeNames, CEmpireRulerEditor::RandomizeName) with its random stream;
-- these take the list's first entries]
local function first_name(R, d, path)
    local nl = R.name_list[d.species.name_list or ""]
    local blk = nl and C.raw_field(nl.block, path)
    local function walk(t, depth)
        for _, e in ipairs(type(t) == "table" and t or {}) do
            if e.text then
                return (e.text:gsub('"', ""))
            elseif e.op and type(e.value) == "table" and depth < 4 then
                local r = walk(e.value, depth + 1)
                if r then
                    return r
                end
            end
        end
    end
    return walk(blk, 0)
end

function editors.act(st, R, d, verb, arg)
    if verb == "focus" then
        st.focus = FIELDS[arg] and arg or nil
    elseif verb == "text" then
        local f = st.focus and FIELDS[st.focus]
        if f then
            local t, k = f(d)
            local cur = t[k] or ""
            -- a localisation key stays as the player's text once typed in [I]
            t[k] = (cur .. arg):sub(1, 100)
        end
    elseif verb == "key" then
        local f = st.focus and FIELDS[st.focus]
        if arg == "backspace" and f then
            local t, k = f(d)
            t[k] = (t[k] or ""):sub(1, -2)
        elseif arg == "return" or arg == "escape" or arg == "tab" then
            st.focus = nil
        end
    elseif verb == "pcat" then
        st.view.category = arg
    elseif verb == "portrait" then
        local p = st.view.portraits and st.view.portraits[tonumber(arg)]
        if p then
            rules.set_portrait(R, d, p.portrait, p.class)
        end
    elseif verb == "ethic" then
        rules.click_ethic(R, d, arg)
    elseif verb == "authority" then
        rules.click_authority(R, d, arg)
    elseif verb == "civic" then
        rules.click_civic(R, d, arg)
    elseif verb == "origin" then
        rules.select_origin(R, d, arg)
    elseif verb == "trait" then
        rules.click_trait(R, d, arg)
    elseif verb == "namelist" then
        if R.name_list[arg] then
            d.species.name_list = arg
        end
    elseif verb == "gender" then
        local g = { DEFAULT_GENDER = "not_set", male = "male", female = "female", indeterminable = "indeterminable" }
        d.species.gender = g[arg] or "not_set"
    elseif verb == "planet" then
        if R.planet_class[arg] then
            d.planet_class = arg
        end
    elseif verb == "initializer_menu" then
        st.view.initializer_open = not st.view.initializer_open
    elseif verb == "initializer" then
        d.initializer = arg
        st.view.initializer_open = false
    elseif verb == "flag_category" then
        st.view.flag_category = arg
    elseif verb == "flag_symbol" then
        d.empire_flag.icon = { category = st.view.flag_category, file = arg }
    elseif verb == "flag_background" then
        d.empire_flag.background = { category = "backgrounds", file = arg }
    elseif verb == "color_slot" then
        st.view.color_slot = tonumber(arg) or 1
    elseif verb == "flag_color" then
        d.empire_flag.colors = d.empire_flag.colors or {}
        d.empire_flag.colors[st.view.color_slot or 1] = arg
    elseif verb == "toggle_map_color" then
        st.view.map_color = not st.view.map_color
    elseif verb == "city_tab" then
        st.view.city_tab = arg
    elseif verb == "city" then
        d.city_graphical_culture = arg
    elseif verb == "room" then
        d.room = arg
    elseif verb == "shipset" then
        d.graphical_culture = arg
    elseif verb == "ruler_gender" then
        d.ruler.gender = arg
    elseif verb == "ruler_trait" then
        rules.click_ruler_trait(R, d, arg)
    elseif verb == "ruler_class_prev" or verb == "ruler_class_next" then
        local list = rules.ruler_classes(R, d)
        local i = 1
        for j, k in ipairs(list) do
            if k == d.ruler.leader_class then
                i = j
            end
        end
        i = verb == "ruler_class_next" and (i % #list) + 1 or ((i - 2) % #list) + 1
        rules.set_ruler_class(R, d, list[i])
    elseif verb == "randomize" then
        if arg == "species_name" then
            d.species.name = first_name(R, d, "species_name") or "SPEC_Human"
            d.species.plural = d.species.name .. "_pl"
            d.species.adjective = d.species.name
        elseif arg == "species_adjective" then
            d.species.adjective = d.species.name
        elseif arg == "empire_name" then
            d.name = first_name(R, d, "empire_name") or "EMPIRE_DESIGN_humans1"
            d.adjective = d.species.adjective ~= "" and d.species.adjective or d.name
        elseif arg == "homeworld" then
            d.planet_name = first_name(R, d, "planet_names") or "NAME_Earth"
            d.system_name = first_name(R, d, "planet_names") or "NAME_Sol"
        elseif arg == "ruler_name" then
            d.ruler.name = first_name(R, d, "character_names") or "Ruler"
        end
    end
end

return editors
