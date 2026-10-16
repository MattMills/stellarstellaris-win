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
-- items after a clip item are cut to its rectangle (render.newgame_widgets' clip items)
local function clip(b, r)
    b.items[#b.items + 1] = { kind = "sprite", path = "/clip", sprite = "", texture = "", sprite_kind = "clip",
        frame = 1, frames = 1, x = r and r.x or 0, y = r and r.y or 0, w = r and r.w or 0, h = r and r.h or 0 }
end

local function list_entries(b, file, window, rect, n, h, spacing, prefix, opts_of)
    if not rect then
        return
    end
    clip(b, rect)
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
    clip(b, nil)
end

-- entries in a grid box's slots (gui.grid_slot); a grid inside a window of the editor is cut to
-- that window (the portraits' container, the origins' window: the game's frames show the last row
-- cut there), one placed in the editor itself is not (the authorities' grid, 50 high, shows two rows)
local function grid_entries(b, file, window, r, path, n, prefix, opts_of, pre)
    local grid = r.grids and r.grids[path]
    if not grid then
        return
    end
    local parent = path:match("^(/[^/]+/.+)/[^/]+$")
    local box = parent and r.rects[parent]
    if box then
        clip(b, box)
    end
    for i = 1, n do
        local x, y = gui.grid_slot(grid, i - 1, n)
        if not x or (box and y >= box.y + box.h) then
            break
        end
        local p = prefix .. "/" .. i
        local o = opts_of(i, p .. "/" .. window) or {}
        o.prefix = p
        o.parent = { x = x, y = y, w = grid.sx, h = grid.sy }
        -- (what the entry draws under its window: pre(i, x, y))
        if pre then
            pre(i, x, y)
        end
        b:add(file, window, o)
    end
    if box then
        clip(b, nil)
    end
end

-- an element's block in a window of a .gui file by its path under the window ("a/b"), and the
-- rectangle the layout gave its parent
local function block_at(ctx, file, window, rel)
    local blk, scope = gui.find(ctx.game_dir, file, window)
    -- the scripted variables in scope (the file's, then each block's own on the way down)
    local vars = setmetatable({}, { __index = scope })
    local function take(b_)
        for _, e in ipairs(b_ or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                vars[e.key.text] = e.value.text
            end
        end
    end
    take(blk)
    for name in rel:gmatch("[^/]+") do
        local found
        for _, e in ipairs(blk or {}) do
            if not found and e.op and e.key and type(e.value) == "table" and e.value.text == nil and C.field(e.value, "name") == name then
                found = e.value
            end
        end
        blk = found
        take(blk)
    end
    return blk, vars
end

-- a spinnerType (not laid out by render.gui): its arrows (render.newgame_widgets.spinner) at its
-- position and size in its parent [I: a spinner of height 0 takes the arrows' height]
local function spinner(ctx, b, r, window, rel, actions, file)
    local def, vars = block_at(ctx, file or FILE, window, rel)
    local parent = r.rects["/" .. window .. "/" .. (rel:match("^(.*)/[^/]+$") or "")] or r.rects["/" .. window]
    if not def or not parent then
        return
    end
    local function num(v)
        if type(v) == "string" and v:sub(1, 1) == "@" then
            v = vars[v]
        end
        return tonumber(v)
    end
    local pos, size = C.raw_field(def, "position"), C.raw_field(def, "size")
    local x = parent.x + (num(C.field(pos, "x")) or 0)
    local y = parent.y + (num(C.field(pos, "y")) or 0)
    local w_ = num(C.field(size, "x") or C.field(size, "width")) or 100
    local h_ = num(C.field(size, "y") or C.field(size, "height")) or 0
    local widgets = require("render.newgame_widgets")
    local wctx = { db = ctx.db, texture_size = ctx.texture_size, items = b.items, report = b.report }
    if h_ <= 0 then
        h_ = 24
    end
    widgets.spinner(wctx, def, { x = x, y = y, w = w_, h = h_ }, "/spinners/" .. rel, actions)
end

-- a leader trait's icon sprite (its inline_script's ICON: GFX_leader_trait_<name>)
local function leader_trait_icon(R, key)
    local t = R.trait[key]
    local is = t and C.raw_field(t.block, "inline_script")
    local icon = type(is) == "table" and C.field(is, "ICON")
    return icon or C.field(t and t.block or {}, "icon")
end

-- a text's concept links ([concept_x] and ['concept_x', TEXT]) as the game shows them: the
-- concept's name (its localisation) or the link's own text, in the link colour [I: §E]
function editors.concepts(ctx, text)
    text = text:gsub("%[%s*'(concept_[%w_]+)'%s*,%s*([^%]]-)%s*%]", function(_, shown_text)
        return "§E" .. shown_text .. "§!"
    end)
    text = text:gsub("%[(concept_[%w_]+)%]", function(c)
        return "§E" .. C.loc(ctx, c) .. "§!"
    end)
    return text
end

-- a label's text without its $VALUE$ (the value is its own text box): "Trait Points Left:"
function editors.label(ctx, key)
    local t = C.raw(ctx, key):gsub("%s*%$[^$]*%$", "")
    return t
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
    local ps = {}
    for _, p in ipairs(rules.category_portraits(R, st.view.category or "")) do
        if not (p.locked and st.hide_locked) then
            ps[#ps + 1] = p
        end
    end
    st.view.portraits = ps
    grid_entries(b, PICKER, "species_portrait_picker_entry", r, W .. "/portraits_container/portraits", #ps,
        "/portraits", function(i, E_)
            return {
                hide = { [E_ .. "/selected"] = ps[i].portrait ~= d.species.portrait, portrait = true,
                    not_eligible = true, portrait_overlay = true, portrait_substitution_indicator = true },
                actions = { [E_] = not ps[i].locked and ("creator:portrait:" .. i) or nil },
                disabled = { [E_] = ps[i].locked },
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
    -- an ethic that cannot be added greyed (CEmpireEthicsGovEditor::RefreshEthics [I])
    local chosen = {}
    for _, k in ipairs(d.ethics) do
        chosen[k] = true
    end
    for _, e in ipairs(R.ethics) do
        if not chosen[e.key] and not rules.can_add_ethic(R, d, e.key) then
            o.disabled[G .. "/" .. e.key] = true
        end
    end
    -- the authority's name and description; the government type
    local a = d.authority and R.authority[d.authority]
    o.text[W .. "/authority_description/desc"] = a and (loc(ctx, a.key) .. "\n" .. loc(ctx, a.key .. "_desc"))
        or (loc(ctx, "NO_GOVERNMENT_SELECTED") .. "\n" .. loc(ctx, "NO_GOVERNMENT_SELECTED_DESC"))
    o.text[W .. "/government_type"] = d.government and loc(ctx, d.government) or ""
    o.hide[W .. "/nomad_toggle_container"] = true
    local r = b:add(FILE, "empire_ethics_and_government_editor", o)
    -- the chosen ethics: their category's ring (GFX_ethic_selected) centred on the ethic's button
    local ring = ctx.db.sprites.GFX_ethic_selected
    for _, k in ipairs(d.ethics) do
        local er = r.rects[G .. "/" .. k]
        if er and ring then
            local s = ring
            local w_, h_ = s.size and s.size[1], s.size and s.size[2]
            if not w_ then
                w_, h_ = ctx.texture_size(s.texture)
                w_ = w_ and w_ / math.max(1, s.frames or 1)
            end
            if w_ then
                b:sprite("/ethic_selected/" .. k, "GFX_ethic_selected", er.x + er.w / 2 - w_ / 2, er.y + er.h / 2 - h_ / 2, w_, h_)
            end
        end
    end
    -- the authorities (government_entry in authority_grid)
    local auths = rules.authorities(R, d)
    grid_entries(b, FILE, "government_entry", r, W .. "/authority_grid", #auths, "/authorities",
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
    -- its description and effects (`description`: the game's frame shows "Effects:" under it)
    local desc = og and loc(ctx, og.key .. "_desc") or ""
    local fx = og and C.field(og.block, "description")
    if fx and ctx.loc and ctx.loc.has(fx) then
        desc = desc .. "\n\n" .. editors.concepts(ctx, loc(ctx, fx))
    end
    o.text[W .. "/desc_window/selected_origin_desc"] = desc
    local r = b:add(FILE, "empire_origin_editor", o)
    grid_entries(b, FILE, "empire_origin_entry", r, W .. "/origins_window/origins", #list, "/origins",
        function(i, E_)
            local g = list[i]
            local ok = rules.origin_ok(R, d, g.key)
            return {
                text = { [E_ .. "/name"] = ok and loc(ctx, g.key) or ("§g" .. loc(ctx, g.key) .. "§!") },
                sprites = { [E_ .. "/picture_frame/picture"] = g.picture },
                hide = { [E_ .. "/selected"] = g.key ~= d.origin, [E_ .. "/missing_dlc_overlay"] = true },
                actions = { [E_] = "creator:origin:" .. g.key },
                disabled = { [E_ .. "/picture_frame"] = not ok or nil },
            }
        end)
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
    -- the labels without their value (drawn beside them)
    o.text[W .. "/trait_points_lables"] = editors.label(ctx, "POINTS_LEFT")
    o.text[W .. "/trait_picks_lables"] = editors.label(ctx, "PICKS_LEFT")
    o.text[W .. "/headline_label"] = loc(ctx, "TRAITS")
    o.hide[W .. "/details"] = true
    local r = b:add(FILE, "species_traits_editor", o)
    -- the available traits: positive ones by cost, then by name, then the negative ones [I: the
    -- game's frame lists Communal, Conservationist, Enduring, Migratory, Natural Engineers ... (1)]
    local avail = rules.trait_list(R, d)
    table.sort(avail, function(x, y)
        if (x.cost > 0) ~= (y.cost > 0) then
            return x.cost > 0
        end
        if x.cost ~= y.cost then
            if x.cost > 0 then
                return x.cost < y.cost
            end
            return x.cost > y.cost
        end
        return loc(ctx, x.key) < loc(ctx, y.key)
    end)
    grid_entries(b, FILE, "customization_selected_trait_entry", r, W .. "/available/entries", #avail, "/traits_available",
        function(i, E_)
            local t = avail[i]
            local can = rules.can_add_trait(R, d, t.key)
            local cost = t.cost
            return {
                text = { [E_ .. "/name"] = can and loc(ctx, t.key) or ("§g" .. loc(ctx, t.key) .. "§!"),
                    [E_ .. "/cost"] = (cost > 0 and "§R" or "§G") .. tostring(cost) .. "§!" },
                textures = { [E_ .. "/icon"] = trait_icon(ctx, t.key) },
                actions = { [E_] = "creator:trait:" .. t.key },
            }
        end)
    local cur = d.species.traits
    grid_entries(b, FILE, "customization_selected_trait_entry", r, W .. "/current/entries", #cur, "/traits_current",
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
        -- (`selectable = { always = no }`: GDF, AI, the special lists)
        if rules.trigger(R, n.playable) ~= false and rules.trigger(R, n.selectable) ~= false then
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
        local per = math.ceil(rect.h / 29)
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
    -- (the list's spacing -3: 29 apart; its borderSize x -5)
    if rect then
        rect = { x = rect.x - 5, y = rect.y, w = rect.w + 5, h = rect.h }
    end
    list_entries(b, FILE, "namelist_group_entry", rect, #shown_, 32, -3, "/name_lists", function(i, E_)
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
    -- the classes' buttons at their places (@planet_colN / @planet_rowN); the planets are 3D in
    -- the game (not drawn: GFX_dummy_3d_home_world_new at the button's 100 x 100)
    local PLACES = {
        pc_desert = { 286, 46 }, pc_ocean = { 411, 46 }, pc_arctic = { 537, 46 },
        pc_arid = { 286, 140 }, pc_continental = { 411, 140 }, pc_alpine = { 537, 140 },
        pc_savannah = { 286, 236 }, pc_tropical = { 411, 236 }, pc_tundra = { 537, 236 },
    }
    for p in pairs(PLACES) do
        o.actions[D .. "/" .. p] = "creator:planet:" .. p
        o.sizes[D .. "/" .. p] = { 100, 100 }
    end
    -- the selection ring's window moved to the chosen class's button (the file's comment) [V]
    local at = PLACES[d.planet_class or ""]
    if at then
        o.positions[D .. "/selected"] = { at[1] - 5, at[2] - 5 }
    else
        o.hide[D .. "/selected"] = true
    end
    -- the details: the class, its climate and description, its preference trait
    local pc = d.planet_class or ""
    local def = R.planet_class[pc]
    o.text[W .. "/details/name"] = loc(ctx, pc)
    o.text[W .. "/details/desc"] = (def and def.climate and (loc(ctx, def.climate) .. "\n") or "")
        .. loc(ctx, pc .. "_desc")
    local pref = "trait_" .. pc .. "_preference"
    o.text[W .. "/details/preference_trait/name"] = loc(ctx, pref)
    o.textures[W .. "/details/preference_trait/icon"] = trait_icon(ctx, pref)
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
        -- the categories with a name (FLAG_CATEGORY_<folder>) [I: the game's list has no
        -- Enclaves, which has none]
        local name = dir:match("^flags/([^/]+)$")
        if name and name ~= "backgrounds" and ctx.loc and ctx.loc.has("FLAG_CATEGORY_" .. name) then
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
    -- the buttons and the colours they set: the flag's first two, the map's border and fill (the
    -- design's colours 1, 2, 5, 6 as the game's Save writes them) [V]
    local slots = { "primary_color", "secondary_color", "border_color", "fill_color" }
    local SLOT = { 1, 2, 5, 6 }
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
        local c = cols[(f.colors or {})[SLOT[i]] or ""]
        if c then
            o.tints[W .. "/" .. s .. "_preview/swatch"] = { c[1], c[2], c[3], 1 }
        end
    end
    local r = b:add(FILE, "empire_flag_editor", o)
    list_entries(b, FILE, "flag_symbol_category_entry", r.rects[W .. "/categories"], #fp.cats, 30, 0, "/flag_categories",
        function(i, E_)
            local c = fp.cats[i]
            return {
                text = { [E_ .. "/name"] = loc(ctx, "FLAG_CATEGORY_" .. c) },
                hide = { [E_ .. "/selected"] = c ~= st.view.flag_category },
                actions = { [E_] = "creator:flag_category:" .. c },
            }
        end)
    local emblems = fp.files[st.view.flag_category] or {}
    grid_entries(b, FILE, "flag_texture_entry", r, W .. "/symbols_window/symbols", #emblems, "/flag_symbols",
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
        end)
    -- the colours (color_entry: a swatch each, flags/colors.txt's order)
    local names = preview.colour_names(ctx.game_dir)
    grid_entries(b, FILE, "color_entry", r, W .. "/colors", #names, "/flag_colors", function(i, E_)
        local c = cols[names[i]]
        return {
            sizes = { [E_ .. "/select_color"] = { 20, 20 } },
            tints = c and { [E_ .. "/select_color"] = { c[1], c[2], c[3], 1 } } or nil,
            hide = { [E_ .. "/highlight"] = (f.colors or {})[SLOT[st.view.color_slot]] ~= names[i] },
            actions = { [E_ .. "/select_color"] = "creator:flag_color:" .. names[i] },
        }
    end)
    -- the backgrounds (flag_texture_entry each: GFX_flag_no_mask with that background, in greys
    -- [I: the game's frame shows them grey and white whatever the colours])
    grid_entries(b, FILE, "flag_texture_entry", r, W .. "/patterns_window/patterns", #fp.backgrounds, "/flag_patterns",
        function(i, E_)
            local fl = { icon = { category = "", file = "" }, background = { category = "backgrounds", file = fp.backgrounds[i] },
                colors = { "@grey", "@white", "@grey", "@grey" } }
            local tex = preview.flag_texture(ctx, "GFX_flag_no_mask", fl)
            return {
                textures = tex and { [E_ .. "/flag"] = tex } or nil,
                sizes = { [E_ .. "/flag"] = { 60, 60 } },
                hide = { [E_ .. "/highlight"] = not (f.background and f.background.file == fp.backgrounds[i]) },
                actions = { [E_ .. "/flag"] = "creator:flag_background:" .. fp.backgrounds[i] },
            }
        end)
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
        -- each city over the home world's landscape (species_preview_backgrounds/
        -- species_preview_bg_<class>.dds) [I: the game's frame shows the same landscape behind each]
        local sky = "gfx/portraits/species_preview_backgrounds/species_preview_bg_" .. (d.planet_class or "pc_continental"):gsub("^pc_", "") .. ".dds"
        if not ctx.texture_size(sky) then
            sky = "gfx/portraits/species_preview_backgrounds/species_preview_bg_continental.dds"
        end
        grid_entries(b, FILE, "city_portrait_entry", r, W .. "/cities_window/cities_grid", #list, "/cities",
            function(i, E_)
                local g = list[i]
                local cls = rules.culture_class(R, g.key)
                local name = (C.raw(ctx, "CITY_GRAPHICS_NAME"):gsub("%$CULTURE%$", cls and loc(ctx, cls) or g.key))
                return {
                    textures = { [E_ .. "/button"] = "gfx/portraits/city_sets/" .. g.key .. "_city_l03.dds" },
                    sizes = { [E_ .. "/button"] = { 330, 160 } },
                    text = { [E_ .. "/culture"] = name },
                    hide = { [E_ .. "/selected"] = g.key ~= d.city_graphical_culture, [E_ .. "/missing_dlc_overlay"] = true },
                    actions = { [E_ .. "/button"] = "creator:city:" .. g.key },
                }
            end, function(i, x, y)
                if ctx.texture_size(sky) then
                    b:texture("/cities/" .. i .. "/sky", sky, x + 1, y + 5, 328, 128)
                end
            end)
    else
        -- the rooms the room selector offers in the game setup (gfx/portraits/asset_selectors/
        -- room_textures.txt `room_selector = { game_setup = { "room" = { trigger } } }`)
        local rooms = {}
        local source = require("stellar.script.source")
        local sel = C.raw_field(source.parse(ctx.game_dir, "gfx/portraits/asset_selectors/room_textures.txt") or {}, "room_selector")
        for _, e in ipairs(type(C.raw_field(sel, "game_setup")) == "table" and C.raw_field(sel, "game_setup") or {}) do
            if e.op and e.key and rules.trigger(R, type(e.value) == "table" and not e.value.text and e.value or nil, rules.config(R, d)) then
                rooms[#rooms + 1] = (e.key.text:gsub('"', ""))
            end
        end
        if #rooms == 0 then
            rooms = { "default_room" }
        end
        grid_entries(b, FILE, "diplomacy_room_entry", r, W .. "/rooms_window/rooms_grid", #rooms, "/rooms",
            function(i, E_)
                return {
                    textures = { [E_ .. "/button"] = "gfx/portraits/city_sets/" .. rooms[i] .. ".dds" },
                    sizes = { [E_ .. "/button"] = { 326, 116 } },
                    hide = { [E_ .. "/selected"] = (d.room ~= "" and d.room or "default_room") ~= rooms[i] },
                    actions = { [E_ .. "/button"] = "creator:room:" .. rooms[i] },
                }
            end)
    end
end

-- a ship set's name: its key upper case localised (BIOGENESIS_02 "Shellcraft"), else its species
-- class's ("Mammalian") [I]
local function culture_name(ctx, R, key)
    if ctx.loc and ctx.loc.has(key:upper()) then
        return loc(ctx, key:upper())
    end
    local cls = rules.culture_class(R, key)
    return cls and loc(ctx, cls) or key
end

-- Shipsets (ship_gfx_culture_browser_editor): the ship sets in their groups (Biological: those
-- with bio_ship among their ship_kinds; Mechanical: the others) [I: the game's frame], the chosen
-- one's description, the ship classes' spinner, the ship colours. The 3D ship is not drawn.
E.shipset = function(ctx, b, st, R, d, W, o)
    local groups = { { key = "BIOLOGICAL", list = {} }, { key = "ROBOT", list = {} } }
    local cfg = rules.config(R, d)
    for _, g in ipairs(R.cultures) do
        local sel = g.selectable
        local never = type(sel) == "table" and C.field(sel, "always") == "no"
        if sel ~= nil and not never then
            local kinds = C.strings(C.raw_field(C.defs(ctx, "common/graphical_culture")[g.key] or {}, "ship_kinds"))
            local bio = false
            for _, k in ipairs(kinds) do
                bio = bio or k == "bio_ship"
            end
            local entry = { key = g.key, locked = not rules.trigger(R, sel, cfg) }
            table.insert(groups[bio and 1 or 2].list, entry)
        elseif sel == nil and g.ship_color then
            table.insert(groups[2].list, { key = g.key })
        end
    end
    local sizes = { "corvette", "destroyer", "cruiser", "battleship", "titan", "colossus", "juggernaut", "science", "constructor",
        "colonizer", "transport", "military_station_small", "outpost" }
    st.view.ship_size = st.view.ship_size or 1
    local size = sizes[st.view.ship_size]
    local T = W .. "/ship_type_browser_container"
    o.text[T .. "/shipset_name"] = culture_name(ctx, R, d.graphical_culture or "")
    o.text[T .. "/ship_index_text"] = st.view.ship_size .. "/" .. #sizes
    o.text[T .. "/spinner_container/ship_preview_label_text"] = loc(ctx, size)
    o.text[T .. "/shipset_description_text"] = loc(ctx, (d.graphical_culture or "") .. "_shipset_desc")
    o.text[T .. "/ship_type_label_text"] = loc(ctx, size)
    o.text[T .. "/ship_type_description_text"] = loc(ctx, size .. "_desc")
    o.hide[W .. "/dlc_overlay"] = true
    o.hide[W .. "/3d_view_window"] = true
    o.hide[W .. "/ship_color_container/ship_colors_disabled_overlay"] = d.ship_color ~= nil
    o.actions[W .. "/ship_color_container/use_ship_color"] = "creator:toggle_ship_color"
    o.frames[W .. "/ship_color_container/use_ship_color"] = d.ship_color and 2 or 1
    local r = b:add(SHIPS, "ship_gfx_culture_browser_editor", o)
    spinner(ctx, b, r, "ship_gfx_culture_browser_editor", "ship_type_browser_container/spinner_container/ship_type_spinner",
        { left = "creator:ship_size:-1", right = "creator:ship_size:1" }, SHIPS)
    -- the list: a group's header (ship_browser_shipset_entry), its sets (ship_browser_culture_entry)
    local lr = r.rects[W .. "/shipset_browser_container/shipset_listbox"]
    if lr then
        clip(b, lr)
        local y = lr.y
        for gi, g in ipairs(groups) do
            if #g.list > 0 and y < lr.y + lr.h then
                local p = "/shipsets/" .. gi
                b:add(SHIPS, "ship_browser_shipset_entry", { prefix = p, parent = { x = lr.x, y = y, w = lr.w, h = 32 },
                    text = { [p .. "/ship_browser_shipset_entry/shipset_label"] = loc(ctx, g.key) } })
                y = y + 32
                for ci, c in ipairs(g.list) do
                    if y >= lr.y + lr.h then
                        break
                    end
                    local q = p .. "/" .. ci
                    local E_ = q .. "/ship_browser_culture_entry"
                    b:add(SHIPS, "ship_browser_culture_entry", { prefix = q, parent = { x = lr.x, y = y, w = lr.w, h = 100 },
                        text = { [E_ .. "/ship_category_entry_name"] = culture_name(ctx, R, c.key) },
                        hide = { [E_ .. "/selected"] = c.key ~= d.graphical_culture, [E_ .. "/missing_dlc_overlay"] = not c.locked },
                        actions = { [E_ .. "/choose_ship_culture_button"] = not c.locked and ("creator:shipset:" .. c.key) or nil },
                    })
                    y = y + 100
                end
            end
        end
        clip(b, nil)
    end
    -- the ship colours (flags/colors.txt's names, ship_color_entry each)
    local names = preview.colour_names(ctx.game_dir)
    local cols = preview.flag_colours(ctx.game_dir)
    grid_entries(b, SHIPS, "ship_color_entry", r, W .. "/ship_color_container/ship_colors", #names, "/ship_colors", function(i, E_)
        local c = cols[names[i]]
        return {
            tints = c and { [E_ .. "/select_color"] = { c[1], c[2], c[3], 1 } } or nil,
            hide = { [E_ .. "/highlight"] = d.ship_color ~= names[i] },
            actions = { [E_ .. "/select_color"] = "creator:ship_color:" .. names[i] },
        }
    end)
end

-- Ruler Appearance (species_ruler_editor)
E.ruler = function(ctx, b, st, R, d, W, o)
    local G = W .. "/gender"
    o.actions[G .. "/male"] = "creator:ruler_gender:male"
    o.actions[G .. "/female"] = "creator:ruler_gender:female"
    o.actions[G .. "/indeterminable"] = "creator:ruler_gender:indeterminable"
    o.frames[G .. "/" .. (d.ruler.gender or "female")] = 2
    -- a species with genders: male and female (the game's frame shows no third button)
    local cls = R.class[d.species.class or ""]
    if not cls or cls.gender then
        o.hide[G .. "/indeterminable"] = true
    end
    o.actions[W .. "/name_box/randomize_name"] = "creator:randomize:ruler_name"
    -- the titles: the government type's, N/A without an heir (the edit boxes' texts)
    local t = rules.ruler_titles(R, d)
    local N = W .. "/name_box"
    o.hide[N .. "/ruler_title_na"] = t.ruler ~= nil
    o.hide[N .. "/heir_title_na"] = t.heir ~= nil
    o.hide[N .. "/female_container/female_ruler_title_container/ruler_title_female_na"] = t.ruler ~= nil
    o.hide[N .. "/female_container/female_heir_title_container/heir_title_female_na"] = t.heir ~= nil
    -- the portrait's spinners: phenotype, attachments (its custom label: Hairstyle), colour
    -- variant, clothes, evolution stage; no evolution variant [I: the game's frame]
    local po = rules.portrait_options(R, d)
    local spins = {
        { "sub_portrait", po.phenotype, #po.phenotypes, "LEADER_SUB_PORTRAIT" },
        { "attachments", (d.ruler.attachment or 0) + 1, po.attachments, po.attachment_label },
        { "variation", (d.ruler.texture or 0) + 1, po.textures },
        { "clothes", (d.ruler.clothes or 0) + 1, po.clothes },
        { "evolution_stage", 1, 1 },
    }
    o.hide[W .. "/evolution_variant"] = true
    for _, s in ipairs(spins) do
        o.text[W .. "/" .. s[1] .. "/selected"] = s[2] .. " / " .. s[3]
        if s[4] then
            o.text[W .. "/" .. s[1] .. "/portrait_label"] = loc(ctx, s[4])
        end
    end
    local r = b:add(FILE, "species_ruler_editor", o)
    for _, s in ipairs(spins) do
        spinner(ctx, b, r, "species_ruler_editor", s[1] .. "/spinner",
            { left = "creator:ruler_spin:" .. s[1] .. ":-1", right = "creator:ruler_spin:" .. s[1] .. ":1" })
    end
    edit_box(ctx, b, st, r.rects[N .. "/name"], "ruler_name", d.ruler.name)
    edit_box(ctx, b, st, r.rects[N .. "/ruler_title"], "ruler_title", d.ruler.ruler_title ~= "" and d.ruler.ruler_title or t.ruler)
    edit_box(ctx, b, st, r.rects[N .. "/heir_title"], "heir_title", t.heir and (d.ruler.heir_title ~= "" and d.ruler.heir_title or t.heir) or "")
    local F = N .. "/female_container"
    if t.ruler then
        edit_box(ctx, b, st, r.rects[F .. "/female_ruler_title_container/ruler_title_female_editbox"], "ruler_title_female",
            d.ruler.ruler_title_female ~= "" and d.ruler.ruler_title_female or t.ruler_female)
    end
    if t.heir then
        edit_box(ctx, b, st, r.rects[F .. "/female_heir_title_container/heir_title_female_editbox"], "heir_title_female",
            d.ruler.heir_title_female ~= "" and d.ruler.heir_title_female or t.heir_female)
    end
    edit_box(ctx, b, st, r.rects[W .. "/leader_bio_container/leader_bio_edit_box"], "ruler_biography", d.ruler.biography)
end

-- Ruler Traits (ruler_traits_editor): the class, the starting traits, the chosen ones
E.ruler_traits = function(ctx, b, st, R, d, W, o)
    local pts = rules.ruler_points_left(R, d)
    o.text[W .. "/trait_points"] = (pts < 0 and "§R" or "§G") .. pts .. "§!"
    o.text[W .. "/ruler_class_spinner_container/spinner_value"] = loc(ctx, d.ruler.leader_class or "")
    o.text[W .. "/trait_points_lables"] = editors.label(ctx, "POINTS_LEFT")
    o.hide[W .. "/details"] = true
    local r = b:add(FILE, "ruler_traits_editor", o)
    spinner(ctx, b, r, "ruler_traits_editor", "ruler_class_spinner_container/ruler_class_spinner",
        { left = "creator:ruler_class_prev", right = "creator:ruler_class_next" })
    local avail = rules.ruler_trait_list(R, d)
    grid_entries(b, FILE, "customization_ruler_trait_entry", r, W .. "/available/entries", #avail, "/ruler_traits",
        function(i, E_)
            local t = avail[i]
            return {
                text = { [E_ .. "/name"] = loc(ctx, t.key), [E_ .. "/description"] = loc(ctx, t.key .. "_desc"),
                    [E_ .. "/cost"] = "§R" .. tostring(t.cost) .. "§!" },
                sprites = { [E_ .. "/icon"] = leader_trait_icon(R, t.key) },
                hide = { [E_ .. "/selected_icon"] = true },
                actions = { [E_] = "creator:ruler_trait:" .. t.key },
            }
        end)
    local cur = d.ruler.traits
    grid_entries(b, FILE, "customization_selected_ruler_trait_entry", r, W .. "/current/entries", #cur, "/ruler_traits_current",
        function(i, E_)
            local t = R.trait[cur[i]] or { key = cur[i], cost = 0 }
            return {
                text = { [E_ .. "/name"] = loc(ctx, t.key), [E_ .. "/cost"] = "§R" .. tostring(t.cost) .. "§!" },
                sprites = { [E_ .. "/icon"] = leader_trait_icon(R, t.key) },
                actions = { [E_] = "creator:ruler_trait:" .. t.key },
            }
        end)
end

function editors.build(ctx, b, st, R, d)
    local e = rules.BY_KEY[st.editor] or rules.BY_KEY.portrait
    local W = "/" .. e.window
    local o = {
        text = {}, hide = {}, frames = {}, sprites = {}, textures = {}, tints = {}, disabled = {}, sizes = {}, positions = {},
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
    ruler_title = function(d) return d.ruler, "ruler_title" end,
    ruler_title_female = function(d) return d.ruler, "ruler_title_female" end,
    heir_title = function(d) return d.ruler, "heir_title" end,
    heir_title_female = function(d) return d.ruler, "heir_title_female" end,
    ruler_biography = function(d) return d.ruler, "biography" end,
}
-- a field's name in the design's literal flags (rules.to_text)
local LITERAL = { empire_name = "name", empire_adjective = "adjective" }

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
            -- a name the player types is their own text (literal = yes in the design); a key's
            -- text becomes the starting point [I]
            d.literal = d.literal or {}
            if not d.literal[LITERAL[st.focus] or st.focus] and RENDER_LOC and RENDER_LOC.has(cur) then
                cur = (RENDER_LOC.get(cur))
            end
            d.literal[LITERAL[st.focus] or st.focus] = true
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
        d.empire_flag.colors[({ 1, 2, 5, 6 })[st.view.color_slot or 1]] = arg
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
    elseif verb == "ship_size" then
        st.view.ship_size = ((st.view.ship_size or 1) - 1 + (tonumber(arg) or 0)) % 13 + 1
    elseif verb == "toggle_ship_color" then
        d.ship_color = (not d.ship_color) and (d.empire_flag.colors or {})[1] or nil
    elseif verb == "ship_color" then
        if d.ship_color then
            d.ship_color = arg
        end
    elseif verb == "ruler_gender" then
        d.ruler.gender = arg
    elseif verb == "ruler_spin" then
        -- a portrait spinner's arrow: the option before or after, round [I]
        local what, dir = arg:match("^([%w_]+):(-?%d+)$")
        local po = rules.portrait_options(R, d)
        local m = ({
            sub_portrait = { "phenotype", #po.phenotypes }, attachments = { "attachment", po.attachments },
            variation = { "texture", po.textures }, clothes = { "clothes", po.clothes },
        })[what or ""]
        local fieldname, count = m and m[1], m and m[2]
        if fieldname and count > 0 then
            d.ruler[fieldname] = ((d.ruler[fieldname] or 0) + tonumber(dir)) % count
            if fieldname == "phenotype" then
                d.ruler.portrait = po.phenotypes[d.ruler.phenotype + 1]
            end
        end
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
