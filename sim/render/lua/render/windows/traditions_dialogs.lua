-- render/windows/traditions_dialogs.lua : the traditions view's dialogs (4.5.2 Linux;
-- docs/windows/research.md): the tradition category selection (CTraditionCategorySelectionView,
-- topbar_traditions_view.gui `tradition_category_selection_dialog`), the yes/no popup of an
-- adoption (CPopupMessageYesNo, popup.gui `yes_no_popup_window`), the ascension perks' list
-- (CAscensionPerksView, ascension_perks_view.gui) and its confirmation (CConfirmAscensionPerkDialog,
-- standard_dialog.gui `standard_dialog`). Laid out by traditions.build over the view; their
-- state is the view's: dialog=categories, confirm=TRADITION, perks=1, perk_confirm=PERK,
-- unavailable=1, cat_scroll=ROWS, perk_scroll=PIXELS. (No `extract`: not a view.)

local gui = require("render.gui")
local source = require("stellar.script.source")
local get = require("render.gfx").get

local dialogs = {}

local FILE = "interface/topbar_traditions_view.gui"
local PERKS_FILE = "interface/ascension_perks_view.gui"

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

-- a localised text with its $VAR$ (and $VAR|C$, in colour C) replaced (a value that is a key: its
-- text)
local function format(loc, key, vars)
    local t = loc and loc.has(key) and loc.raw(key) or key
    return (t:gsub("%$([%w_]+)|?(%w*)%$", function(k, colour)
        local v = vars[k]
        if v == nil then
            return nil
        end
        v = tostring(v)
        if loc and loc.has(v) then
            v = (loc.get(v))
        end
        return colour ~= "" and ("\194\167" .. colour .. v .. "\194\167!") or v
    end))
end

local function name_of(loc, key)
    return loc and loc.has(key) and (loc.get(key)) or key
end

-- the ascension perk categories (common/ascension_perk_categories: `ascension_perks = { ... }`),
-- in the database's order
local categories
local function perk_categories(game_dir)
    if categories then
        return categories
    end
    categories = {}
    local list = {}
    for key, def in pairs(source.definitions(game_dir, "common/ascension_perk_categories")) do
        local members = {}
        for _, e in ipairs(type(get(def.block, "ascension_perks")) == "table" and get(def.block, "ascension_perks") or {}) do
            if e.text then
                members[unquote(e.text)] = true
            end
        end
        list[#list + 1] = { key = key, members = members, order = { def.file or "", def.line or 0 } }
    end
    table.sort(list, function(a, b)
        if a.order[1] ~= b.order[1] then return a.order[1] < b.order[1] end
        return a.order[2] < b.order[2]
    end)
    categories = list
    return categories
end

-- ---------------------------------------------------------------------------------------------
-- the category selection

local SLOT_W, SLOT_H = 314, 266

-- dialogs.categories(ctx, data, state, layout, defs, native) : the dialog over the view
function dialogs.categories(ctx, data, state, layout, defs, native)
    local D = "/tradition_category_selection_dialog"
    local r = layout(FILE, "tradition_category_selection_dialog", {
        actions = { [D .. "/close"] = "view_set:dialog=;cat_scroll=" },
    })
    local box = r.rects[D .. "/tradition_category_gridbox_container"]
    if not box then
        return
    end
    -- UpdateList: the potential categories not adopted, in the database's order (extract)
    local list = data.available or {}
    local rows = math.max(1, math.floor(box.h / SLOT_H))
    local first = math.max(0, math.min(tonumber(state.cat_scroll) or 0, math.ceil(#list / 4) - rows))
    for i, cat in ipairs(list) do
        local slot = i - 1 - first * 4
        local row = math.floor(slot / 4)
        if slot >= 0 and row < rows then
            local def = defs.categories[cat.key] or {}
            local prefix = "/selection/" .. i
            local E = prefix .. "/tradition_category_grid_entry"
            local opts = {
                prefix = prefix, parent = { x = box.x + SLOT_W * (slot % 4), y = box.y + SLOT_H * row, w = 0, h = 0 },
                hide = { adopted_count_container = true, blocker_container = true, tree = true },
                text = {
                    [E .. "/category_name_container/category_label"] = cat.key,
                    [E .. "/category_desc"] = cat.desc or (cat.key .. "_desc"),
                },
                sprites = {
                    [E .. "/tradition_grid_entry_bg_container/tradition_grid_entry_bg"] = "GFX_tradition_category_bg_" .. cat.key,
                    [E .. "/category_name_container/hex_bg"] = "GFX_tradition_hex_bg_" .. cat.key,
                    [E .. "/category_name_container/category_icon"] = "GFX_tradition_category_icon_" .. cat.key,
                },
                sizes = {
                    [E .. "/category_adopt_button"] = { native(ctx, "GFX_adopt_tradition_category_button") },
                    [E .. "/category_desc"] = { 280, 200 },
                },
                actions = {}, disabled = {},
            }
            -- Adopt (UpdateAdoptCategoryButton): enabled when the adoption tradition is possible and
            -- affordable; a click asks for confirmation (OnClickAdopt 0x3377ca0)
            if cat.can and def.adoption then
                opts.actions[E .. "/category_adopt_button"] = "view_set:confirm=" .. def.adoption
            else
                opts.disabled[E .. "/category_adopt_button"] = true
            end
            layout(FILE, "tradition_category_grid_entry", opts)
        end
    end
end

-- the rows of the category selection the wheel scrolls (state cat_scroll), or nil: not over it
function dialogs.categories_wheel(ctx, data, state, notches, x, y)
    local ok, _, r = pcall(gui.layout, ctx.game_dir, ctx.db, FILE, "tradition_category_selection_dialog", ctx.screen,
        { texture_size = ctx.texture_size, loc = ctx.loc })
    local box = ok and r.rects["/tradition_category_selection_dialog/tradition_category_gridbox_container"]
    if not box or x < box.x or y < box.y or x > box.x + box.w or y > box.y + box.h then
        return nil
    end
    local rows = math.max(1, math.floor(box.h / SLOT_H))
    local max = math.max(0, math.ceil(#(data and data.available or {}) / 4) - rows)
    local v = math.max(0, math.min(max, (tonumber(state.cat_scroll) or 0) - (notches > 0 and 1 or -1)))
    return { cat_scroll = tostring(v) }
end

-- ---------------------------------------------------------------------------------------------
-- the yes/no popup (CPopupMessageYesNo: TRADITION_ADOPT_CONFIRM, its description with the
-- tradition's name and the cost)

function dialogs.confirm(ctx, data, state, layout)
    local P = "/yes_no_popup_window"
    local t = state.confirm
    local cost = math.ceil((data.cost or 0) - 1e-9)
    local desc = format(ctx.loc, "TRADITION_ADOPT_CONFIRM_DESC", {
        TRADITION = t, COST = format(ctx.loc, "COST_VALUE", { VALUE = "\194\163unity\194\163 " .. cost }),
    })
    layout("interface/popup.gui", "yes_no_popup_window", {
        text = { [P .. "/title"] = "TRADITION_ADOPT_CONFIRM", [P .. "/description"] = desc },
        -- Yes: CCountryActivateTraditionCommand (OnConfirmAdopt), the category selection closed;
        -- No: the popup closed (the dialog stays)
        actions = {
            [P .. "/AgreeButton"] = "cmd:traditions:adopt:" .. t .. "#confirm=;dialog=;cat_scroll=",
            [P .. "/DeclineButton"] = "view_set:confirm=",
        },
    })
end

-- ---------------------------------------------------------------------------------------------
-- the ascension perks' list

local GROUP_HEADER, PERK_H, SPACING = 40, 86, 10

-- the perks listed (UpdateList 0x2b71680): the possible ones, or with Show Unavailable the
-- potential ones, sorted by name (and the available first), grouped by the perk categories in
-- their order and then the others ("General": ap_category_default); each group's height
local function groups(ctx, data, state)
    local show_all = state.unavailable == "1"
    local list = {}
    for _, p in ipairs(data.perk_list or {}) do
        if (show_all and p.potential) or (not show_all and p.possible) then
            list[#list + 1] = { key = p.key, possible = p.possible, valid = p.valid, icon = p.icon, name = name_of(ctx.loc, p.key) }
        end
    end
    table.sort(list, function(a, b)
        if show_all and a.possible ~= b.possible then
            return a.possible
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    local out = {}
    local placed = {}
    for _, c in ipairs(perk_categories(ctx.game_dir)) do
        local g = { key = c.key, perks = {} }
        for _, p in ipairs(list) do
            if not placed[p.key] and c.members[p.key] then
                g.perks[#g.perks + 1] = p
                placed[p.key] = true
            end
        end
        out[#out + 1] = g
    end
    local rest = { key = "ap_category_default", perks = {} }
    for _, p in ipairs(list) do
        if not placed[p.key] then
            rest.perks[#rest.perks + 1] = p
        end
    end
    out[#out + 1] = rest
    local shown = {}
    for _, g in ipairs(out) do
        if #g.perks > 0 then
            g.h = GROUP_HEADER + PERK_H * #g.perks
            shown[#shown + 1] = g
        end
    end
    return shown
end

function dialogs.perks(ctx, data, state, layout)
    local A = "/ascension_perks_view"
    local free = math.max(0, (data.perk_points or 0) - #(data.perks or {}))
    local r = layout(PERKS_FILE, "ascension_perks_view", {
        -- (`desc`: SELECT_AN_ASCENSION_PERK while a slot is free, else nothing)
        text = { [A .. "/desc"] = free > 0 and "SELECT_AN_ASCENSION_PERK" or "" },
        frames = { [A .. "/filter_show_unavailable/checked"] = state.unavailable == "1" and 2 or 1 },
        actions = {
            [A .. "/close"] = "view_set:perks=;perk_confirm=;perk_scroll=",
            [A .. "/filter_show_unavailable/checked"] = "view_set:perk_scroll=;unavailable=" .. (state.unavailable == "1" and "" or "1"),
        },
    })
    local list = r.rects[A .. "/ascension_perks_list"]
    if not list then
        return
    end
    -- the groups stacked 10 apart, scrolled by perk_scroll pixels; drawn while they fit
    local y = list.y - (tonumber(state.perk_scroll) or 0)
    for gi, g in ipairs(groups(ctx, data, state)) do
        local prefix = "/perk_groups/" .. gi
        local G = prefix .. "/ascension_perk_category_entry"
        if y >= list.y - 1 and y + GROUP_HEADER <= list.y + list.h then
            layout(PERKS_FILE, "ascension_perk_category_entry", {
                prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
                sizes = { [G] = { 475, g.h } },
                text = { [G .. "/perk_category_header/perk_category_name"] = g.key },
            })
        end
        for k, p in ipairs(g.perks) do
            local py = y + GROUP_HEADER + PERK_H * (k - 1)
            if py >= list.y - 1 and py + PERK_H <= list.y + list.h + 1 then
                local q = prefix .. "/" .. k
                local E = q .. "/ascension_perk_entry_1"
                local name, desc = name_of(ctx.loc, p.key), name_of(ctx.loc, p.key .. "_desc")
                -- Update 0x2b6f910: disabled (and its texts grey) when the command is not valid
                if not p.valid then
                    name = "\194\167g" .. name .. "\194\167!"
                    desc = "\194\167g" .. desc .. "\194\167!"
                end
                layout(PERKS_FILE, "ascension_perk_entry_1", {
                    prefix = q, parent = { x = list.x, y = py, w = 0, h = 0 },
                    sprites = { [E .. "/icon"] = "GFX_" .. (p.icon or p.key) },
                    text = { [E .. "/key"] = name, [E .. "/desc"] = desc },
                    disabled = not p.valid and { [E] = true } or nil,
                    -- a click asks for confirmation (OnClick 0x2b6f690)
                    actions = { [E .. "/bg"] = p.valid and ("view_set:perk_confirm=" .. p.key) or nil },
                })
            end
        end
        y = y + g.h + SPACING
    end
end

-- the pixels the wheel scrolls the perk list by (a perk's height a notch [I]), or nil
function dialogs.perks_wheel(ctx, data, state, notches, x, y)
    local ok, _, r = pcall(gui.layout, ctx.game_dir, ctx.db, PERKS_FILE, "ascension_perks_view", ctx.screen,
        { texture_size = ctx.texture_size, loc = ctx.loc })
    local list = ok and r.rects["/ascension_perks_view/ascension_perks_list"]
    if not list or x < list.x or y < list.y or x > list.x + list.w or y > list.y + list.h then
        return nil
    end
    local total = 0
    for _, g in ipairs(groups(ctx, data or {}, state)) do
        total = total + g.h + SPACING
    end
    local max = math.max(0, total - list.h)
    local v = math.max(0, math.min(max, (tonumber(state.perk_scroll) or 0) - (notches > 0 and PERK_H or -PERK_H)))
    return { perk_scroll = tostring(math.floor(v)) }
end

-- the perk's confirmation (CConfirmAscensionPerkDialog on standard_dialog: Yes posts
-- CCountryActivateAscensionPerkCommand and closes the list; No closes the dialog)
function dialogs.perk_confirm(ctx, data, state, layout)
    local S = "/standard_dialog"
    layout("interface/standard_dialog.gui", "standard_dialog", {
        text = {
            [S .. "/title"] = "ASCENSION_PERK_CONFIRM_TITLE",
            [S .. "/description"] = format(ctx.loc, "ASCENSION_PERK_CONFIRM_DESC", { KEY = state.perk_confirm }),
            [S .. "/AgreeButton"] = "YES", [S .. "/DeclineButton"] = "NO",
        },
        actions = {
            [S .. "/AgreeButton"] = "cmd:traditions:perk:" .. state.perk_confirm .. "#perk_confirm=;perks=;perk_scroll=",
            [S .. "/DeclineButton"] = "view_set:perk_confirm=",
        },
    })
end

return dialogs
