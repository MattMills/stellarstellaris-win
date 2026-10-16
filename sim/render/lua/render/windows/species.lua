-- render/windows/species.lua : the species view (interface/topbar_species_view.gui,
-- CTopBarSpeciesViewImp; docs/windows/empire.md section 8): the empire's species (those with
-- pops on its colonies) grouped by base species, sorted by population (most first), one
-- species_entry each (name and template type, total pops, variants, traits, planet preference,
-- population, trait points and picks, rights); the first selected, its panel on the right
-- (selected_species: name, class, home planet, traits, pops, preference, rights, template).
-- The portraits are 3D: not drawn.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")

local M = {}

local FILE = "interface/topbar_species_view.gui"
local V = "/topbar_species_view"

function M.data(cid, state)
    local galaxy = require("render.galaxy")
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local d = { species = {}, founder = tonumber(world.field(c, "founder_species_ref")) }
    -- pops by species over the country's colonies
    local count, order = {}, {}
    for _, k in ipairs(world.list(world.field(c, "controlled_colonies"))) do
        local col = world.object("colony", tonumber(k))
        for _, g in ipairs(world.list(col and world.field(col, "pop_groups"))) do
            local pg = world.object("pop_group", tonumber(g))
            local sp = pg and tonumber(world.path(pg, "key", "species"))
            if sp then
                if not count[sp] then
                    order[#order + 1] = sp
                    count[sp] = 0
                end
                count[sp] = count[sp] + (tonumber(world.field(pg, "size")) or 0)
            end
        end
    end
    -- the species' rights (standard_species_rights_module: primary, default, species_rights)
    local mod = world.path(c, "modules", "standard_species_rights_module")
    local rights = {}
    local function rights_of(b)
        return { citizenship = C.strip(world.field(b, "citizenship")), slavery = C.strip(world.field(b, "slavery")) }
    end
    local primary = world.field(mod, "primary")
    if primary then
        rights[tonumber(world.field(primary, "species_index")) or -1] = rights_of(primary)
    end
    for _, e in ipairs(mod or {}) do
        if e.op and e.key and e.key.text == "species_rights" and type(e.value) == "table" then
            -- (a list of blocks, one per species, or one block)
            local inner = world.blocks(e.value)
            if #inner == 0 then
                inner = { e.value }
            end
            for _, sr in ipairs(inner) do
                rights[tonumber(world.field(sr, "species_index")) or -1] = rights_of(sr)
            end
        end
    end
    local default = world.field(mod, "default")
    for _, sp in ipairs(order) do
        local s = leaders.species_data(sp)
        if s then
            s.pops = count[sp]
            s.rights = rights[sp] or (default and rights_of(default)) or {}
            local so = world.object("species", sp)
            local hb = so and world.field(so, "home_planet")
            local hp = type(hb) == "table" and tonumber(world.field(hb, "reference")) or tonumber(hb)
            local p = hp and world.object("planet", hp)
            s.home_planet = p and galaxy.name_block(world.field(p, "name"))
            d.species[#d.species + 1] = s
        end
    end
    return d
end

-- a trait's icon file (common/traits `icon`)
local function trait_icon(ctx, t)
    local def = C.defs(ctx, "common/traits")[t]
    local icon = def and C.field(def, "icon")
    return type(icon) == "string" and icon or nil
end

-- the planet class preference trait (trait_pc_*_preference) and the others
local split_ctx   -- the build's ctx (the traits' costs)
local function split_traits(traits)
    local pref, rest = nil, {}
    for _, t in ipairs(traits or {}) do
        if t:match("^trait_pc_.*_preference$") then
            pref = t
        else
            rest[#rest + 1] = t
        end
    end
    -- CTraitDatabase::SortTraits: the positive ones first, then the negative (by their cost's
    -- sign), each in the species' order [I: the frame's order]
    local ctx = split_ctx
    if ctx then
        local function cost(t)
            local d = C.defs(ctx, "common/traits")[t]
            return tonumber(d and C.field(d, "cost")) or 0
        end
        local pos, neg = {}, {}
        for _, t in ipairs(rest) do
            if cost(t) < 0 then
                neg[#neg + 1] = t
            else
                pos[#pos + 1] = t
            end
        end
        for _, t in ipairs(neg) do
            pos[#pos + 1] = t
        end
        rest = pos
    end
    return pref, rest
end

-- the rights' name (NSpeciesViewHelper::GetSpeciesRightsName): a slave's slavery type, else its
-- citizenship
local function rights_name(r)
    if r.citizenship == "citizenship_slavery" and r.slavery then
        return r.slavery
    end
    return r.citizenship or ""
end

local function template_type(d, s)
    if s.id == d.founder then
        return "TEMPLATE_TYPE_FOUNDER"
    end
    return "TEMPLATE_TYPE_DEFAULT"
end

local function icons(ctx, b, rect, list, size, spacing, path)
    if not rect then
        return
    end
    -- (centred in the box when they fit)
    local n = #list
    local w = n * size + (n - 1) * spacing
    local r = { x = rect.x + math.max(0, (rect.w - w) / 2), y = rect.y + (rect.h - size) / 2, w = math.min(rect.w, w), h = size }
    C.overlap(b, r, n, size, spacing, function(i, x, y)
        -- (the trait's icon, its inline scripts expanded: render.windows.leaders_common)
        leaders.trait_icon(ctx, b, list[i], x, y, size, path .. "/" .. i)
    end)
end

function M.build(ctx, d, state)
    split_ctx = ctx
    local b = C.builder(ctx)
    local list = {}
    for _, s in ipairs(d.species or {}) do
        list[#list + 1] = s
    end
    -- SortSpeciesGroups: population, most first (stable)
    for i, s in ipairs(list) do
        s.order = i
    end
    table.sort(list, function(a, b2)
        if a.pops ~= b2.pops then
            return a.pops > b2.pops
        end
        return a.order < b2.order
    end)
    local selected
    for _, s in ipairs(list) do
        if tostring(s.id) == state.species then
            selected = s
        end
    end
    selected = selected or list[1]
    local T = V .. "/topbar_species_tab/"
    local S = T .. "selected_species/"
    local text, textures, sprites, hide = {}, {}, {}, {
        show_galaxy_species_tab_button_selected = true, tab_species = true, species_rights_settings_item = true,
        selected_species_icon = true,
    }
    if selected then
        local pref = split_traits(selected.traits)
        text[S .. "selected_species_name"] = C.name(ctx, selected.name)
        text[S .. "selected_species_type"] = selected.class or ""
        text[S .. "selected_species_home_planet_name"] = C.name(ctx, selected.home_planet)
        text[S .. "selected_species_amount"] = C.short(selected.pops)
        text[S .. "selected_species_trait_points"] = "0"
        text[S .. "selected_species_trait_picks"] = "0"
        text[S .. "selected_species_rights_value"] = rights_name(selected.rights)
        text[S .. "selected_species_template_value"] = template_type(d, selected)
        -- the actions' texts (UpdateSelectedSpecies: a species' own, not a pre-sapient's)
        text[S .. "set_rights_or_policy_button"] = "SET_SPECIES_RIGHTS"
        text[S .. "modify_button"] = "SPECIES_VIEW_TRAITS_CREATE_TEMPLATE"
        text[S .. "apply_template_or_uplift_button"] = "SPECIES_VIEW_TRAITS_APPLY_TEMPLATE"
        if pref then
            local pdef = C.defs(ctx, "common/traits")[pref]
            text[S .. "selected_species_planet_preference_textbox"] = pref .. "_short"
            local pi = trait_icon(ctx, pref)
            if pi and ctx.db.sprites[pi] then
                sprites[S .. "selected_species_planet_preference_icon"] = pi
            else
                textures[S .. "selected_species_planet_preference_icon"] = pi
            end
            local bg = "GFX_species_selected_background_" .. pref
            sprites[S .. "portrait_background/portrait_background_icon"] = ctx.db.sprites[bg] and bg or "GFX_species_selected_background_fallback"
        end
    else
        hide.selected_species = true
    end
    local r = b:add_named(FILE, "topbar_species_view", {
        hide = hide, text = text, textures = textures, sprites = sprites,
        actions = { [V .. "/close"] = "view_close" },
    })
    if selected then
        local _, rest = split_traits(selected.traits)
        icons(ctx, b, r.rects[S .. "selected_species_traits_icons"], rest, 29, 5, "/species_selected_traits")
    end

    -- the list: a species_entry per group (each species its own base here [I])
    local lr = r.rects[T .. "species_window/species"]
    if lr then
        local y = lr.y
        for i, s in ipairs(list) do
            if y + 91 > lr.y + lr.h then
                break
            end
            local prefix = "/species_list/" .. i
            local p = prefix .. "/species_entry/"
            local pref, rest = split_traits(s.traits)
            local et = {
                [p .. "name"] = "§E" .. C.name(ctx, s.name) .. "§!\n" .. C.loc(ctx, template_type(d, s)),
                [p .. "species_list_total_pop"] = C.raw(ctx, "SPECIES_VIEW_TOTAL_POP"):gsub("%$VAL|?1?%*?%$", C.short(s.pops)),
                [p .. "species_list_variants"] = C.raw(ctx, "SPECIES_VIEW_VARIANTS"):gsub("%$VAL%$", "1"),
                [p .. "population"] = C.short(s.pops),
                [p .. "species_list_trait_points"] = "0",
                [p .. "species_list_trait_picks"] = "0",
                [p .. "rights"] = rights_name(s.rights),
            }
            local er = b:add(FILE, "species_entry", {
                prefix = prefix, parent = { x = lr.x, y = y, w = 0, h = 0 },
                text = et,
                hide = { selected_entry = s ~= selected or nil, integrating = true, species = true },
                textures = pref and { [p .. "planet_preference_container/planet_preference_icon"] = trait_icon(ctx, pref) } or nil,
                actions = { [p .. "species_selection"] = "view_set:species=" .. s.id },
            })
            icons(ctx, b, er.rects[p .. "traits_icons"], rest, 29, 4, prefix .. "/traits")
            y = y + 91 + 1
        end
    end
    return b.items, b.report
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end

return M
