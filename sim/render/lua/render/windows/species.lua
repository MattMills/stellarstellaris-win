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
local SM = require("render.windows.species_mod")

local M = {}

local FILE = "interface/topbar_species_view.gui"
local V = "/topbar_species_view"

function M.data(cid, state)
    local galaxy = require("render.galaxy")
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local gov = world.field(c, "government")
    local d = {
        species = {}, founder = tonumber(world.field(c, "founder_species_ref")),
        built = tonumber(world.field(c, "built_species_ref")),
        -- (the government the template editor's trait rules read)
        ethics = C.strings(world.path(c, "ethos", "ethics")), authority = C.strip(world.field(gov, "authority")),
        civics = C.strings(world.field(gov, "civics")), origin = C.strip(world.field(gov, "origin")),
    }
    -- pops by species over a country's colonies (CCountry::_ListSpecies: a species met again adds
    -- its pops), each species' colonies on the player's
    local count, order, colonies = {}, {}, {}
    local function list_species(country, own)
        for _, k in ipairs(world.list(world.field(country, "controlled_colonies"))) do
            local col = world.object("colony", tonumber(k))
            local seen = {}
            for _, g in ipairs(world.list(col and world.field(col, "pop_groups"))) do
                local pg = world.object("pop_group", tonumber(g))
                local sp = pg and tonumber(world.path(pg, "key", "species"))
                if sp then
                    if not count[sp] then
                        order[#order + 1] = sp
                        count[sp] = 0
                    end
                    local n = tonumber(world.field(pg, "size")) or 0
                    count[sp] = count[sp] + n
                    if own then
                        colonies[sp] = colonies[sp] or {}
                        if not seen[sp] then
                            local p = leaders.colony_planet(tonumber(k))
                            seen[sp] = { id = tonumber(k), name = p and galaxy.name_block(world.field(p, "name")), class = p and C.strip(world.field(p, "planet_class")), pops = 0 }
                            colonies[sp][#colonies[sp] + 1] = seen[sp]
                        end
                        seen[sp].pops = seen[sp].pops + n
                    end
                end
            end
        end
    end
    list_species(c, true)
    -- the templates the country made (species_templates_ref) [I: listed with no pops]
    for _, t in ipairs(world.list(world.field(c, "species_templates_ref"))) do
        local sp = tonumber(t)
        if sp and not count[sp] then
            order[#order + 1] = sp
            count[sp] = 0
        end
    end
    -- All Species (_ListGalaxySpecies): the species of the countries with communications with the
    -- player too (their relation toward it: communications = yes)
    local own_count = {}
    for k, v in pairs(count) do
        own_count[k] = v
    end
    local galaxy_first = #order + 1
    local rel = world.path(c, "relations_manager")
    for _, e in ipairs(type(rel) == "table" and rel or {}) do
        if e.op and e.key and e.key.text == "relation" and type(e.value) == "table" then
            local other = world.object("country", tonumber(world.field(e.value, "country")))
            local back = other and world.path(other, "relations_manager")
            for _, f in ipairs(type(back) == "table" and back or {}) do
                if f.op and f.key and f.key.text == "relation" and type(f.value) == "table"
                    and tonumber(world.field(f.value, "country")) == cid and world.field(f.value, "communications") == "yes" then
                    list_species(other, false)
                end
            end
        end
    end
    -- the species' rights (standard_species_rights_module: primary, default, species_rights)
    local mod = world.path(c, "modules", "standard_species_rights_module")
    local rights = {}
    local function rights_of(b)
        local r = {}
        for _, g in ipairs(M.RIGHTS) do
            r[g.field] = C.strip(world.field(b, g.field))
        end
        return r
    end
    local primary = world.field(mod, "primary")
    if primary then
        d.primary = tonumber(world.field(primary, "species_index"))
        rights[d.primary or -1] = rights_of(primary)
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
    d.default_rights = default and rights_of(default) or {}
    d.facts = C.facts(world, c)
    local cmd = require("render.windows.empire_commands")
    local templates = {}
    for _, t in ipairs(world.list(world.field(c, "species_templates_ref"))) do
        templates[tonumber(t) or -1] = true
    end
    for i, sp in ipairs(order) do
        local s = leaders.species_data(sp)
        if s then
            -- (Empire Species: the player's pops; All Species: everyone's listed)
            s.pops = own_count[sp] or 0
            s.galaxy_pops = count[sp]
            s.galaxy_only = i >= galaxy_first or nil
            s.colonies = colonies[sp] or {}
            local so0 = world.object("species", sp)
            s.base = tonumber(so0 and world.field(so0, "base_ref")) or sp
            s.is_base = s.base == sp
            s.template = templates[sp] or nil
            s.is_default = cmd.default_of(c, sp) == sp
            s.rights = rights[sp] or (default and rights_of(default)) or {}
            local so = world.object("species", sp)
            local hb = so and world.field(so, "home_planet")
            local hp = type(hb) == "table" and tonumber(world.field(hb, "reference")) or tonumber(hb)
            local p = hp and world.object("planet", hp)
            s.home_planet = p and galaxy.name_block(world.field(p, "name"))
            s.home_planet_id = p and hp or nil
            d.species[#d.species + 1] = s
        end
    end
    return d
end

-- the species rights popup's groups (species_rights_settings_item, the game's frame's order):
-- the module's field, the definitions' directory, the group's name and icon
M.RIGHTS = {
    { field = "citizenship", dir = "citizenship_types", name = "SPECIES_RIGHT_CITIZENSHIP", icon = "GFX_species_right_citizenship" },
    { field = "subspecies_integration", dir = "subspecies_integration_types", name = "SPECIES_RIGHT_SUBSPECIES_INTEGRATION_TYPE", icon = "GFX_species_right_subspecies_integration_type" },
    { field = "living_standard", dir = "living_standards", name = "SPECIES_RIGHT_LIVING_STANDARDS", icon = "GFX_species_right_living_standards" },
    { field = "military_service", dir = "military_service_types", name = "SPECIES_RIGHT_MILITARY_SERVICE", icon = "GFX_species_right_military_service" },
    { field = "colonization_control", dir = "colonization_controls", name = "SPECIES_RIGHT_COLONIZATION_CONTROLS", icon = "GFX_species_right_colonization_controls" },
    { field = "population_control", dir = "population_controls", name = "SPECIES_RIGHT_POPULATION_CONTROLS", icon = "GFX_species_right_population_controls" },
    { field = "migration_control", dir = "migration_controls", name = "SPECIES_RIGHT_MIGRATION_CONTROLS", icon = "GFX_species_right_migration_controls" },
    { field = "slavery", dir = "slavery_types", name = "SPECIES_RIGHT_SLAVERY_TYPE", icon = "GFX_species_right_slavery_type", needs = "citizenship_slavery" },
    { field = "purge", dir = "purge_types", name = "SPECIES_RIGHT_PURGE_TYPE", icon = "GFX_species_right_purge_type", needs = "citizenship_purge" },
}

-- a right's options: its directory's definitions whose potential holds (an unknown trigger
-- counted as holding [I]: the species' scope is not evaluated here)
function M.options(ctx, d, dir)
    local out = {}
    for _, k in ipairs(C.def_order(ctx, "common/species_rights/" .. dir)) do
        local o = C.defs(ctx, "common/species_rights/" .. dir)[k]
        if C.trigger(C.raw_field(o, "potential") or {}, d.facts or {}, true) then
            out[#out + 1] = k
        end
    end
    return out
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

-- NSpeciesViewHelper::CalculateTemplateType: founder, robot default (the built species), default
-- (CCountry::GetDefaultSpecies), original (a base species), modified [I: pre-sapient and
-- integrating not told apart]
local function template_type(d, s)
    if s.id == d.founder then
        return "TEMPLATE_TYPE_FOUNDER"
    elseif s.id == d.built then
        return "TEMPLATE_TYPE_BUILT_DEFAULT"
    elseif s.is_default then
        return "TEMPLATE_TYPE_DEFAULT"
    elseif s.is_base then
        return "TEMPLATE_TYPE_ORIGINAL"
    end
    return "TEMPLATE_TYPE_MODIFIED"
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
    d = d or {}
    -- (before the view's data has come, its frame alone: the data is nil until the snapshot
    -- carries it)
    if d.species == nil then
        local b0 = C.builder(ctx)
        b0:add(FILE, "topbar_species_view", { only = { background = true, close = true, close_button = true, heading = true }, actions = { [V .. "/close"] = "view_close" } })
        return b0.items, b0.report
    end
    split_ctx = ctx
    local b = C.builder(ctx)
    -- Empire Species (mode 0): the player's own (its colonies' species and its templates); All
    -- Species (mode 1): those of the countries it has communications with too, their pops summed
    local all = (state.mode or "") == "all"
    local list = {}
    for _, s in ipairs(d.species or {}) do
        if all or not s.galaxy_only then
            s.shown_pops = all and s.galaxy_pops or s.pops
            list[#list + 1] = s
        end
    end
    -- SortSpeciesGroups: population, most first (stable)
    for i, s in ipairs(list) do
        s.order = i
    end
    table.sort(list, function(a, b2)
        if a.shown_pops ~= b2.shown_pops then
            return a.shown_pops > b2.shown_pops
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
        text[S .. "selected_species_amount"] = C.short(selected.shown_pops or selected.pops)
        text[S .. "selected_species_trait_points"] = "0"
        text[S .. "selected_species_trait_picks"] = "0"
        text[S .. "selected_species_rights_value"] = rights_name(selected.rights)
        text[S .. "selected_species_template_value"] = template_type(d, selected)
        -- the actions' texts (UpdateSelectedSpecies: a species' own, not a pre-sapient's)
        text[S .. "set_rights_or_policy_button"] = "SET_SPECIES_RIGHTS"
        text[S .. "modify_button"] = (selected.pops or 0) > 0 and "SPECIES_VIEW_TRAITS_CREATE_TEMPLATE" or "SPECIES_VIEW_TRAITS_MODIFY"
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
    -- the tabs (ChangeViewMode: Empire Species 0, All Species 1 [the galaxy's species not listed
    -- here: not done]), the sort buttons (OnSetSortTypeSpecies: the same again reverses), the
    -- selected species' buttons: Set Species Rights and Default Rights open the rights popup, Set as
    -- Default (CSetDefaultSpeciesCommand: not the default already), the home planet's button
    -- (OnHomePlanet: the planet selected); Create Template and Apply This Template open the
    -- species' editor [not done here]
    local mode = state.mode or ""
    hide.show_empire_species_tab_button_selected = mode ~= "" or nil
    hide.show_galaxy_species_tab_button_selected = mode == "" or nil
    local named = {
        close = "view_close",
        show_empire_species_tab_button = "view_set:mode=",
        show_galaxy_species_tab_button = "view_set:mode=all",
        set_default_rights_button = "view_set:rights=default",
        expand_all_button = "view_set:expand_all=" .. (state.expand_all == "1" and "" or "1"),
    }
    local SORTS = { "species_name_button", "traits_button", "planet_button", "population_button", "trait_points_button", "trait_picks_button", "rights_button" }
    for n, name in ipairs(SORTS) do
        local again = tonumber(state.sort) == n - 1
        named[name] = "view_set:sort=" .. (n - 1) .. ";rev=" .. ((again and state.rev ~= "1") and "1" or "")
    end
    local disabled = {}
    if all then
        -- (ChangeViewMode 1: the trait columns' sorts and the action buttons disabled, the trait
        -- points and picks hidden)
        for _, n in ipairs({ "trait_points_button", "trait_picks_button" }) do
            named[n] = nil
        end
        for _, n in ipairs({ "set_rights_or_policy_button", "set_default", "modify_button", "apply_template_or_uplift_button" }) do
            disabled[S .. n] = true
        end
        for _, n in ipairs({ "selected_species_trait_points", "selected_species_trait_picks", "selected_species_template_value" }) do
            hide[n] = true
        end
    elseif selected then
        named.set_rights_or_policy_button = "view_set:rights=" .. selected.id
        -- Set as Default (CSetDefaultSpeciesCommand::IsValid: not its group's default already)
        if selected.is_default then
            disabled[S .. "set_default"] = true
        else
            named.set_default = "cmd:species:default_species:" .. selected.id
        end
        -- Create / Modify Template and Apply This Template (CanCreateTemplateFrom,
        -- CanApplyTemplate: render.windows.species_mod)
        if SM.can_create(ctx, d, selected) then
            named.modify_button = SM.open_editor(selected)
        else
            disabled[S .. "modify_button"] = true
        end
        if SM.can_apply(ctx, d, selected) then
            named.apply_template_or_uplift_button = SM.open_apply(selected)
        else
            disabled[S .. "apply_template_or_uplift_button"] = true
        end
        if selected.home_planet_id then
            named.selected_species_home_planet_type_button = "select:planet:" .. selected.home_planet_id
        end
    end
    local r = b:add_named(FILE, "topbar_species_view", {
        hide = hide, text = text, textures = textures, sprites = sprites, disabled = disabled,
        named = { actions = named },
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
                [p .. "species_list_total_pop"] = C.raw(ctx, "SPECIES_VIEW_TOTAL_POP"):gsub("%$VAL|?1?%*?%$", C.short(s.shown_pops)),
                [p .. "species_list_variants"] = C.raw(ctx, "SPECIES_VIEW_VARIANTS"):gsub("%$VAL%$", "1"),
                [p .. "population"] = C.short(s.shown_pops),
                [p .. "species_list_trait_points"] = "0",
                [p .. "species_list_trait_picks"] = "0",
                [p .. "rights"] = rights_name(s.rights),
            }
            local er = b:add(FILE, "species_entry", {
                prefix = prefix, parent = { x = lr.x, y = y, w = 0, h = 0 },
                text = et,
                hide = { selected_entry = s ~= selected or nil, integrating = true, species = true,
                    species_list_trait_points = all or nil, species_list_trait_picks = all or nil },
                textures = pref and { [p .. "planet_preference_container/planet_preference_icon"] = trait_icon(ctx, pref) } or nil,
                actions = { [p .. "species_selection"] = "view_set:species=" .. s.id },
            })
            icons(ctx, b, er.rects[p .. "traits_icons"], rest, 29, 4, prefix .. "/traits")
            y = y + 91 + 1
        end
    end

    -- the rights popup (species_rights_settings_item, centred: (510, 110) at 1600 x 900 as in the
    -- game's frame): the species' name or "Default Rights" as its title, a
    -- species_right_group_entry per right (its
    -- option selected; Slavery and Purge only for a slave or a purged species: disabled), a
    -- group's click shows its options (species_right_entry), an option's click sets it (the
    -- simulation's command: cmd:species:rights); Reset sets the default's rights again
    if state.rights then
        local who = state.rights
        local rights, title = d.default_rights or {}, C.loc(ctx, "SET_DEFAULT_RIGHTS")
        for _, s in ipairs(d.species or {}) do
            if tostring(s.id) == who then
                rights, title = s.rights or {}, C.name(ctx, s.name)
            end
        end
        local P = "/species_rights_settings_item/"
        local pr = b:add(FILE, "species_rights_settings_item", {
            text = {
                [P .. "species_rights_header"] = title,
                [P .. "reset_rights_button"] = who == "default" and "RESET_RIGHTS_ALL" or "RESET_RIGHTS",
            },
            actions = {
                [P .. "close"] = "view_set:rights=",
                [P .. "reset_rights_button"] = "cmd:species:rights_reset:" .. who,
            },
        })
        local rl = pr.rects[P .. "species_right_list_window/species_right_list"]
        if rl then
            local y = rl.y
            for i, g in ipairs(M.RIGHTS) do
                if y + 30 > rl.y + rl.h then
                    break
                end
                local gp = "/species_rights/" .. i
                local q = gp .. "/species_right_group_entry/"
                local off = g.needs and rights.citizenship ~= g.needs
                local open = state["rg_" .. g.field] == "1" and not off
                b:add(FILE, "species_right_group_entry", {
                    prefix = gp, parent = { x = rl.x, y = y, w = 0, h = 0 },
                    sprites = ctx.db.sprites[g.icon] and { [q .. "group_icon"] = g.icon } or nil,
                    text = { [q .. "species_right_name"] = g.name, [q .. "selected_option_name"] = rights[g.field] or "" },
                    frames = { [q .. "expand_icon"] = open and 2 or 1 },
                    actions = not off and { [q .. "background"] = "view_set:rg_" .. g.field .. "=" .. (open and "" or "1") } or nil,
                    disabled = off and { [q .. "background"] = true } or nil,
                })
                y = y + 30
                for k, opt in ipairs(open and M.options(ctx, d, g.dir) or {}) do
                    if y + 30 > rl.y + rl.h then
                        break
                    end
                    local op = gp .. "/options/" .. k
                    local o = op .. "/species_right_entry/"
                    local chosen = opt == rights[g.field]
                    b:add(FILE, "species_right_entry", {
                        prefix = op, parent = { x = rl.x + 15, y = y, w = 0, h = 0 },
                        text = { [o .. "name"] = opt },
                        frames = { [o .. "is_selected"] = chosen and 2 or 1 },
                        actions = not chosen and { [o .. "option_button"] = "cmd:species:rights:" .. who .. ":" .. g.field .. ":" .. opt } or nil,
                    })
                    y = y + 30
                end
            end
        end
    end
    -- the template editor and the apply window over the view
    SM.build(ctx, b, d, state)
    return b.items, b.report
end

-- the wheel over the template editor's trait lists
function M.wheel(ctx, d, state, notches, x, y)
    return SM.wheel(state, notches, x, y)
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end


-- its buttons' commands in the simulation (views.rs: `cmd:species:VERB:ARG...`, between days)
function M.command(...)
    return require("render.windows.empire_commands").run(...)
end

-- Escape (views.rs): the side windows in these state keys close first, else the view closes
M.escape_keys = { "rights", "sm", "sm_traits", "sm_pos", "sm_neg", "sm_apply", "sm_off" }
-- (the template windows first, then the rights popup: their close buttons' ESCAPE)
function M.escape(state)
    if state.sm or state.sm_apply then
        return SM.CLOSE
    elseif state.rights then
        return "view_set:rights="
    end
    return nil
end

return M
