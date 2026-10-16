-- render/windows/traditions.lua : the traditions view (interface/topbar_traditions_view.gui,
-- `traditions_view`), as CTraditionsView fills it (4.5.2 Linux; docs/windows/research.md):
--
--   traditions.extract(game_dir) -> data    the player's categories, traditions, perks, unity
--   traditions.build(ctx, data, state)      the view laid out (render.gui)
--
-- The Traditions tab: the next tradition's cost, the unity's progress to it and the months left
-- (tradition_box), seven category slots (TRADITION_CATEGORIES_MAX) with the adopted categories
-- first in their order then empty ones (tradition_category_grid_entry: an adopted category's tree
-- from its tree_template with a tradition_entry in each of the template's containers, an empty one
-- "Empty" with its Select button), and the eight ascension perk slots (ap_0 .. ap_7). The crisis
-- (Ambition) tab is not drawn.

local gui = require("render.gui")
local source = require("stellar.script.source")
local get = require("render.gfx").get

local traditions = {}

local FILE = "interface/topbar_traditions_view.gui"
local CATEGORIES_MAX = 7   -- NDefines.NGameplay.TRADITION_CATEGORIES_MAX
local PERK_SLOTS = 8       -- NDefines.NGameplay.ASCENSION_PERKS_SLOTS

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

local function list_of(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = unquote(e.text)
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the world: what the view shows of the player's country

-- traditions.extract(game_dir) -> { categories, traditions, perks, unity, income, cost,
--   perk_points, can = { [tradition] = true } } (CTraditionType::CanActivate: possible and
--   affordable), or nil without a player country
function traditions.extract(game_dir)
    local world = require("engine.world")
    local topbar = require("render.topbar")
    local cid = topbar.player()
    local c = world.object("country", cid)
    if not c then
        return nil
    end
    local d = {
        categories = world.list(world.field(c, "tradition_categories")),
        traditions = world.list(world.field(c, "traditions")),
        perks = world.list(world.field(c, "ascension_perks")),
        empire_size = tonumber(world.field(c, "empire_size")) or 0,
    }
    for _, k in ipairs({ "categories", "traditions", "perks" }) do
        for i, v in ipairs(d[k]) do
            d[k][i] = unquote(v)
        end
    end
    local values, stock = topbar.values(cid)
    d.unity = stock.unity or 0
    d.income = values.tb_unity_group and values.tb_unity_group.income or 0
    -- the cost and what can be adopted: the simulation's engine.traditions (CTraditionType::
    -- CalcCost with the country's modifiers; without its definitions, the defines' formula alone)
    local ok, tr = pcall(require, "engine.traditions")
    if ok then
        local okc, _, unity = pcall(tr.cost, cid)
        d.cost = okc and unity or nil
        local okp, pts = pcall(tr.perk_points, cid)
        d.perk_points = okp and pts or nil
        -- (without the simulation's definitions, nothing is known of it: no overlay, no grey)
        local okd, any = pcall(tr.categories)
        d.can = okd and any and next(any) and {} or nil
        for _, cat in ipairs(d.can and d.categories or {}) do
            local def = tr.category(cat)
            for _, t in ipairs(def and def.traditions or {}) do
                local okt, can = pcall(tr.can_activate, cid, t, true)
                if okt and can then
                    d.can[t] = true
                end
            end
        end
        if d.can then
            local eval = require("simscript.eval")
            local function holds(block, file)
                if type(block) ~= "table" then
                    return true
                end
                local okt, r = pcall(eval.trigger, block, eval.new_ctx(eval.S("country", cid), nil, nil, file))
                return okt and r and true or false
            end
            local adopted = {}
            for _, cat in ipairs(d.categories) do
                adopted[cat] = true
            end
            -- the category selection (CTraditionCategorySelectionView::Update): the potential
            -- categories not adopted, in the database's order; Adopt enabled when the adoption
            -- tradition is possible and affordable; the description the first `desc` whose trigger
            -- holds (CTriggeredEventDescription), else KEY_desc
            d.available = {}
            local unity_cost = d.cost or 0
            for _, c in ipairs(tr.categories()) do
                local okp, potential = pcall(tr.category_potential, cid, c.name)
                if not adopted[c.name] and okp and potential then
                    local desc
                    for _, e in ipairs(c.block) do
                        if not desc and e.op and e.key and e.key.text == "desc" and type(e.value) == "table" and e.value.text == nil then
                            local trig, text
                            for _, x in ipairs(e.value) do
                                if x.op and x.key and x.key.text == "trigger" then trig = x.value end
                                if x.op and x.key and x.key.text == "text" then text = x.value.text end
                            end
                            if text and holds(trig, c.file) then
                                desc = unquote(text)
                            end
                        end
                    end
                    local okq, possible = pcall(tr.is_possible, cid, c.adoption or "")
                    d.available[#d.available + 1] = {
                        key = c.name, desc = desc,
                        can = c.adoption ~= nil and okq and possible and d.unity >= unity_cost or false,
                    }
                end
            end
            -- the ascension perks (CAscensionPerksView::UpdateList): potential, possible (without
            -- the slots), valid (CCountryActivateAscensionPerkCommand::IsValid: with them)
            d.perk_list = {}
            for _, p in ipairs(tr.perk_types()) do
                local okp, potential = pcall(tr.is_potential, cid, p.name)
                if okp and potential then
                    local okq, possible = pcall(tr.can_activate, cid, p.name, false)
                    local okv, valid = pcall(tr.can_activate, cid, p.name, true)
                    d.perk_list[#d.perk_list + 1] = {
                        key = p.name, potential = true, possible = okq and possible or false, valid = okv and valid or false,
                        icon = unquote(require("engine.defs").field(p.block, "icon")),
                    }
                end
            end
        end
    end
    if d.cost == nil then
        -- (TRADITION_COST_AMOUNTS + (n x TRADITION_COST_TRADITION) ^ EXP) x (1 + size penalty)
        -- [I: the modifiers not applied: the administrative capacity is EMPIRE_SIZE_BASE]
        local x = #d.traditions * 8
        d.cost = (300 + (x > 0 and x ^ 1.8 or 0)) * (1 + 0.002 * math.max(0, d.empire_size - 100))
    end
    return d
end

-- ---------------------------------------------------------------------------------------------
-- the game's files: the categories (common/tradition_categories), the traditions' and perks' icons

local files
local function definitions(game_dir)
    if files then
        return files
    end
    files = { categories = {}, icons = {} }
    local cats = source.definitions(game_dir, "common/tradition_categories")
    for key, def in pairs(cats) do
        files.categories[key] = {
            tree_template = unquote(get(def.block, "tree_template")),
            adoption = unquote(get(def.block, "adoption_bonus")),
            finisher = unquote(get(def.block, "finish_bonus")),
            traditions = list_of(get(def.block, "traditions")),
        }
    end
    -- CTraditionType::GetIconKey: its `icon`, else its key [I: a swap's icon not applied]
    for _, dir in ipairs({ "common/traditions", "common/ascension_perks" }) do
        for key, def in pairs(source.definitions(game_dir, dir)) do
            files.icons[key] = unquote(get(def.block, "icon")) or key
        end
    end
    -- the ascension perks' places (positionType ap_0 .. ap_7)
    files.perk_slots = {}
    local tree = source.parse(game_dir, FILE)
    local function scan(block)
        for _, e in ipairs(block or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                if e.key.text:lower() == "positiontype" then
                    local n = unquote(get(e.value, "name"))
                    local p = get(e.value, "position")
                    local i = n and tonumber(n:match("^ap_(%d+)$"))
                    if i and type(p) == "table" then
                        files.perk_slots[i] = { tonumber(get(p, "x")) or 0, tonumber(get(p, "y")) or 0 }
                    end
                elseif e.key.text:lower() == "guitypes" then
                    scan(e.value)
                end
            end
        end
    end
    scan(tree)
    return files
end

-- a localised text with its $VAR$ (and $VAR|C$, in colour C) replaced
local function format(loc, key, vars)
    local t = loc and loc.has(key) and loc.raw(key) or key
    return (t:gsub("%$([%w_]+)|?(%w*)%$", function(k, colour)
        local v = vars[k]
        if v == nil then
            return nil
        end
        return colour ~= "" and ("\194\167" .. colour .. tostring(v) .. "\194\167!") or tostring(v)
    end))
end

-- ---------------------------------------------------------------------------------------------
-- the layout

-- traditions.build(ctx, data, state) -> items, report
function traditions.build(ctx, data, state)
    local defs = definitions(ctx.game_dir)
    -- (the data comes a snapshot after the view opens: every field guarded)
    data = data or {}
    data.categories, data.traditions, data.perks = data.categories or {}, data.traditions or {}, data.perks or {}
    data.unity, data.income, data.cost = data.unity or 0, data.income or 0, data.cost or 300
    state = state or {}
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local base = { texture_size = ctx.texture_size, loc = ctx.loc }
    local function layout(window, opts)
        for k, v in pairs(base) do
            opts[k] = opts[k] or v
        end
        local i, r = gui.layout(ctx.game_dir, ctx.db, FILE, window, ctx.screen, opts)
        gui.merge(items, report, i, r)
        return r
    end
    local has = {}
    for _, t in ipairs(data.traditions) do
        has[t] = true
    end
    local adopted = {}
    for _, c in ipairs(data.categories) do
        adopted[c] = true
    end
    -- UpdateNextTradition: a next tradition while a slot is free or a category is not complete
    local has_next = #data.categories < CATEGORIES_MAX
    for _, c in ipairs(data.categories) do
        local def = defs.categories[c]
        if def and def.finisher and not has[def.finisher] then
            has_next = true
        end
    end
    local cost = math.ceil((data.cost or 0) - 1e-9)
    local affordable = data.unity >= (data.cost or 0)

    -- the window: the Traditions tab active (UpdateTabVisibility), the crisis window hidden
    local V = "/traditions_view"
    local hide = { tab_traditions = true, tab_crisis_active = true, crisis_window = true }
    local text, progress = {}, {}
    if has_next then
        -- UpdateProgress: the cost with the unity icon, rounded up; the stock's share of it; the
        -- months to it (MONTHS_VALUE: "? months" without income, "0 months" when affordable)
        text[V .. "/traditions_window/tradition_box/tradition_cost"] = "\194\163unity\194\163 " .. cost
        local p = cost == 0 and 100 or math.max(0, math.min(100, math.floor(data.unity / data.cost * 100 + 0.5)))
        progress[V .. "/traditions_window/tradition_box/progress"] = p / 100
        local months
        if (data.income or 0) == 0 then
            months = "?"
        elseif data.cost - data.unity <= 0 then
            months = 0
        else
            months = math.ceil((data.cost - data.unity) / data.income)
        end
        text[V .. "/traditions_window/tradition_box/time_to_next_tradition"] =
            format(ctx.loc, months == 1 and "MONTH_VALUE" or "MONTHS_VALUE", { VALUE = months })
    else
        hide.tradition_cost, hide.progress, hide.time_to_next_tradition = true, true, true
    end
    local r = layout("traditions_view", {
        hide = hide, text = text, progress = progress,
        -- (a text box without maxWidth is as wide as its text)
        sizes = { [V .. "/traditions_window/ascension_perks/ascension_perks_label"] = { 280, 25 } },
        actions = { [V .. "/close"] = "view_close" },
        -- the Ambition tab: disabled without the country's crisis data (Update 0x334c3e0) [I: the
        -- player has none here]
        disabled = { [V .. "/tab_crisis"] = true },
    })

    -- the categories (UpdateTraditionsGridbox): slot i at the gridbox's (314 x 266) cell
    local grid = r.rects[V .. "/traditions_window/tradition_category_gridbox"]
    for i = 0, CATEGORIES_MAX - 1 do
        local cat = data.categories[i + 1]
        local def = cat and defs.categories[cat]
        local prefix = "/traditions/" .. i
        local E = prefix .. "/tradition_category_grid_entry"
        local parent = { x = grid.x + 314 * (i % 4), y = grid.y + 266 * math.floor(i / 4), w = 0, h = 0 }
        local opts = { prefix = prefix, parent = parent, hide = {}, text = {}, sprites = {}, actions = {}, sizes = {
            -- the button at its sprite's size, not its `size` (298 x 35); the description centred
            -- in the 200 below its place (the game's frame) [I: measured]
            [E .. "/category_adopt_button"] = { require("render.windows.technology").native(ctx, "GFX_adopt_tradition_category_button") },
            [E .. "/category_desc"] = { 280, 200 },
        } }
        if def then
            -- an adopted category: its sprites by key, its name, the count of its traditions
            -- (UpdateAdoptCategoryButton, UpdateAdoptedCount, UpdateCategoryVisibility)
            opts.sprites[E .. "/tradition_grid_entry_bg_container/tradition_grid_entry_bg"] = "GFX_tradition_category_bg_" .. cat
            opts.sprites[E .. "/category_name_container/hex_bg"] = "GFX_tradition_hex_bg_" .. cat
            opts.sprites[E .. "/category_name_container/category_icon"] = "GFX_tradition_category_icon_" .. cat
            opts.text[E .. "/category_name_container/category_label"] = cat
            opts.hide.category_adopt_button = true
            opts.hide.category_desc = true
            opts.hide.blocker_container = true
            local max, count = 0, 0
            for _, t in ipairs(def.traditions) do
                if t ~= def.adoption and t ~= def.finisher then
                    max = max + 1
                    count = count + (has[t] and 1 or 0)
                end
            end
            opts.text[E .. "/adopted_count_container/adopted_count_value"] = format(ctx.loc, "TRADITION_ADOPTED_COUNT", { COUNT = count, MAX = max })
        else
            -- an empty slot: Select (TRADITION_SELECT_BUTTON); the "available" sprites and no
            -- blocker when the next tradition is affordable
            opts.hide.adopted_count_container = true
            opts.text[E .. "/category_adopt_button"] = "TRADITION_SELECT_BUTTON"
            -- Select: enabled when the next tradition is affordable; it opens the category
            -- selection (OnClickAdopt with no category: CTraditionCategorySelectionView)
            if affordable then
                opts.actions[E .. "/category_adopt_button"] = "view_set:confirm=;dialog=categories"
            else
                opts.disabled = { [E .. "/category_adopt_button"] = true }
            end
            if affordable then
                opts.sprites[E .. "/tradition_grid_entry_bg_container/tradition_grid_entry_bg"] = "GFX_tradition_category_bg_available"
                opts.sprites[E .. "/category_name_container/category_icon"] = "GFX_tradition_category_icon_available"
                opts.hide.blocker_container = true
            end
            opts.hide.tree = true
        end
        local er = layout("tradition_category_grid_entry", opts)
        -- the tree (SetupTraditions): the template inside `tree`, tradition i in its i-th container
        if def and def.tree_template then
            local tree = er.rects[E .. "/tree"] or parent
            local tp = prefix .. "/tree"
            local ok, tr = pcall(layout, def.tree_template, { prefix = tp, parent = { x = tree.x, y = tree.y, w = 0, h = 0 } })
            if ok then
                for k, t in ipairs(def.traditions) do
                    local slot = tr.rects[tp .. "/" .. def.tree_template .. "/" .. def.tree_template .. "_tradition_" .. k]
                    if slot then
                        local p = tp .. "/" .. k
                        local T = p .. "/tradition_entry"
                        -- UpdateTraditions: the overlay where CanActivate; owned ones take no clicks
                        layout("tradition_entry", {
                            prefix = p, parent = { x = slot.x, y = slot.y, w = 0, h = 0 },
                            sprites = { [T .. "/tradition_adopt_button"] = "GFX_" .. (defs.icons[t] or t) },
                            hide = { available_tradition = not (data.can and data.can[t]) or nil },
                            -- a tradition neither had nor adoptable is disabled: the game draws
                            -- it greyed [I: the disabled look as a grey tint]
                            tints = { [T .. "/tradition_adopt_button"] = (data.can and not has[t] and not data.can[t]) and { 0.35, 0.35, 0.35, 1 } or nil },
                            -- a click on one that can be adopted asks for confirmation
                            -- (OnClickTraditionAdopt: CPopupMessageYesNo)
                            actions = { [T .. "/tradition_adopt_button"] = (data.can and data.can[t]) and ("view_set:confirm=" .. t) or nil },
                        })
                    end
                end
            end
        end
    end

    -- the ascension perks (UpdateAscensionPerks): the taken ones, then the free slots
    -- (CalcFreeAscensionPerkPoints), then locked ones
    local box = r.rects[V .. "/traditions_window/ascension_perks"]
    local free = math.max(0, (data.perk_points or 0) - #data.perks)
    for i = 0, PERK_SLOTS - 1 do
        local at = defs.perk_slots[i] or { 0, 0 }
        local prefix = "/perks/" .. i
        local P = prefix .. "/traditions_ascension_perk_entry"
        local icon, frame = "GFX_ascension_perk_slot_locked", "GFX_flag_64_frame"
        if data.perks[i + 1] then
            icon = "GFX_" .. (defs.icons[data.perks[i + 1]] or data.perks[i + 1])
        elseif free > 0 then
            icon, frame = "GFX_ascension_perk_slot_available", "GFX_flag_64_frame_highlight"
            free = free - 1
        end
        layout("traditions_ascension_perk_entry", {
            prefix = prefix, parent = { x = box.x + at[1], y = box.y + at[2], w = 0, h = 0 },
            sprites = { [P .. "/icon"] = icon, [P .. "/ascension_perk_button"] = frame },
            -- an untaken slot (free or locked) opens the perk list (OnClickAscensionPerk)
            actions = { [P .. "/ascension_perk_button"] = not data.perks[i + 1] and "view_set:confirm=;perks=1" or nil },
        })
    end

    -- the dialogs over the view: the category selection, the perk list, their confirmations
    local dialogs = require("render.windows.traditions_dialogs")
    local function dlayout(file, window, opts)
        for k, v in pairs(base) do
            opts[k] = opts[k] or v
        end
        local i, rr = gui.layout(ctx.game_dir, ctx.db, file, window, ctx.screen, opts)
        gui.merge(items, report, i, rr)
        return rr
    end
    local native = require("render.windows.technology").native
    if state.dialog == "categories" then
        dialogs.categories(ctx, data, state, dlayout, defs, native)
    end
    if state.perks then
        dialogs.perks(ctx, data, state, dlayout)
    end
    -- (the popups' descriptions have "\n"s: a text item a line)
    local first = #items + 1
    if state.confirm then
        dialogs.confirm(ctx, data, state, dlayout)
    end
    if state.perk_confirm then
        dialogs.perk_confirm(ctx, data, state, dlayout)
    end
    require("render.windows.technology").split_lines(items, first, 17)
    return items, report
end

-- traditions.escape(state) -> the action Escape does: the innermost window closed (a popup, then
-- the dialog under it), or nil (the view closed)
function traditions.escape(state)
    if state.confirm then
        return "view_set:confirm="
    elseif state.perk_confirm then
        return "view_set:perk_confirm="
    elseif state.dialog then
        return "view_set:dialog=;cat_scroll="
    elseif state.perks then
        return "view_set:perks=;perk_scroll="
    end
    return nil
end

-- traditions.wheel(ctx, data, state, notches, x, y): the category selection's rows or the perk
-- list scrolled when the pointer is over them
function traditions.wheel(ctx, data, state, notches, x, y)
    local dialogs = require("render.windows.traditions_dialogs")
    if state.perks then
        return dialogs.perks_wheel(ctx, data, state, notches, x, y)
    elseif state.dialog == "categories" then
        return dialogs.categories_wheel(ctx, data, state, notches, x, y)
    end
    return nil
end

-- traditions.command(what, name) -> what it did (the action `cmd:traditions:WHAT:NAME`, views.rs:
-- in the simulation's runtime)
--   adopt NAME  CCountryActivateTraditionCommand (IsValid: CanActivate with the slots; Execute:
--               the cost paid, CCountry::ActivateTradition): engine.traditions.activate; a
--               category is adopted with its adoption tradition
--   perk NAME   CCountryActivateAscensionPerkCommand (IsValid: CanActivate with the slots;
--               Execute: CCountry::ActivateAscensionPerk, no cost): the same activate
function traditions.command(what, name)
    local world = require("engine.world")
    local tr = require("engine.traditions")
    local cid = require("render.topbar").player()
    if what ~= "adopt" and what ~= "perk" then
        return "refused: unknown command " .. tostring(what)
    end
    local t = tr.type(name or "")
    if not t or (what == "perk") ~= (t.kind == tr.PERK) then
        return "refused: no " .. (what == "perk" and "ascension perk " or "tradition ") .. tostring(name)
    end
    local date = (tostring(world.meta.date or ""):gsub('"', ""))
    local ok = tr.activate(cid, name, require("simscript.host"), date)
    return (ok and (what == "perk" and "perk " or "adopted ") or "refused: ") .. name
end

return traditions
