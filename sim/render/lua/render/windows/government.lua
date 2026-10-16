-- render/windows/government.lua : the government view (interface/government_view.gui,
-- CGovernmentView; docs/windows/empire.md section 2), opened by the top bar's flag. Its Empire tab
-- (CGovernmentViewGovernmentTab::Update): the empire's name, the ruler's card, the government's
-- type and authority, ethics, civics, origin, elections, diplomatic weight, the temporary
-- modifiers or the relations; its Demographics tab (CGovernmentViewDemographicsTab): the
-- founder species, the pops.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")
local reform = require("render.windows.reform")
local rename = require("render.windows.rename")

local M = {}

local FILE = "interface/government_view.gui"
local V = "/government_view"
local G = V .. "/government_window/info_window/"

function M.data(cid, state)
    local galaxy = require("render.galaxy")
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local gov = world.field(c, "government")
    local d = {
        country = cid,
        name = galaxy.name_block(world.field(c, "name")),
        government = C.strip(world.field(gov, "type")),
        authority = C.strip(world.field(gov, "authority")),
        origin = C.strip(world.field(gov, "origin")),
        civics = C.strings(world.field(gov, "civics")),
        ethics = C.strings(world.path(c, "ethos", "ethics")),
        next_election = C.strip(world.field(c, "next_election")),
        timed_modifiers = #world.list(world.field(c, "timed_modifier") or {}),
        -- what the diplomatic weight is made of (CCountry::CalcCachedEmpireData; docs)
        economy_power = tonumber(world.field(c, "economy_power")) or 0,
        tech_power = tonumber(world.field(c, "tech_power")) or 0,
        military_power = tonumber(world.field(c, "military_power")) or 0,
        pops = tonumber(world.field(c, "num_sapient_pops")) or 0,
        city = C.strip(world.field(c, "city_graphical_culture")),
        planets = #world.list(world.field(c, "owned_planets")),
        -- what the Reform Government window reads (CCountry::CanChangeGovernment,
        -- CalcGovernmentReformCost, CalcTotalCivicPoints)
        empire_size = tonumber(world.field(c, "empire_size")) or 0,
        unity = tonumber(world.path(c, "modules", "standard_economy_module", "resources", "unity")) or 0,
        government_date = C.strip(world.field(c, "government_date")),
        free_reform = false,
        civic_points_add = 0,
    }
    local flags = world.field(c, "flags")
    d.free_reform = type(flags) == "table" and world.field(flags, "free_government_reform") ~= nil
    -- (the cooldown: government_date after today; GOVERNMENT_CHANGE_YEARS counts the years'
    -- numbers apart)
    local today = (tostring(world.meta.date or ""):gsub('"', ""))
    local cmd = require("render.windows.empire_commands")
    if d.government_date and cmd.days(d.government_date) > cmd.days(today) then
        d.cooldown_years = math.max(1, (tonumber(d.government_date:match("^(%d+)")) or 0) - (tonumber(today:match("^(%d+)")) or 0))
    end
    local economy = package.loaded["engine.economy"]
    local mods = economy and economy.has_modifier_source and economy.has_modifier_source() and economy.modifiers("country", cid)
    d.civic_points_add = mods and math.floor(tonumber(mods.country_government_civic_points_add) or 0) or 0
    local ruler = tonumber(world.field(c, "ruler"))
    d.ruler = ruler and leaders.leader_data(ruler, c) or nil
    d.founder = leaders.species_data(tonumber(world.field(c, "founder_species_ref")))
    -- the founder species' pops (POPS_IN_WORLD's NO: the game's frame, 2.6K of 5.3K)
    local count, order = leaders.country_species(c)
    d.founder_pops = d.founder and count[d.founder.id] or d.pops
    -- the country's species (the pie chart's list), their names and pops
    d.species = {}
    for _, sp in ipairs(order) do
        local s = leaders.species_data(sp)
        if s then
            d.species[#d.species + 1] = { id = sp, name = s.name, pops = count[sp] }
        end
    end
    return d
end

-- the tabs (CGovernmentView::UpdateTabs): the tab shown has its `_active` button, the others
-- their own; Budget is never available (CGovernmentViewBudgetTab::ShouldBeAvailable returns 0),
-- the advisor's only with more than one playable voice type (not drawn)
local TABS = {
    { name = "government", window = "info_window" },
    { name = "demographics", window = "demographics_window" },
}

-- an authority's election rules (common/governments/authorities)
local function authority(ctx, key)
    local b = C.defs(ctx, "common/governments/authorities")[key or ""]
    return {
        election_type = b and C.field(b, "election_type") or "none",
        term = tonumber(b and C.field(b, "election_term_years")) or 0,
        variance = tonumber(b and C.field(b, "election_term_variance")) or 0,
        heir = b and C.field(b, "has_heir") == "yes",
        icon = C.icon_file(ctx, "common/governments/authorities", key,
            "gfx/interface/icons/governments/authorities/" .. tostring(key) .. ".dds"),
    }
end

-- the diplomatic weight: NDiplomacy's factors of the country's powers and pops (common/defines)
-- [I: the pops' happiness and the weight's modifiers are left out]
local function diplomatic_weight(ctx, d)
    local def = function(k, v)
        return tonumber(C.define(ctx, "NDiplomacy", k)) or v
    end
    local w = def("DIPLOMACY_WEIGHT_BASE", 0)
        + d.economy_power * def("DIPLOMACY_WEIGHT_ECONOMY_FACTOR", 0.15)
        + d.tech_power * def("DIPLOMACY_WEIGHT_TECHNOLOGY_FACTOR", 0.1)
        + d.military_power * def("DIPLOMACY_WEIGHT_NAVAL_FACTOR", 0.025)
        + d.pops * def("DIPLOMACY_WEIGHT_POP_BASE", 0.01)
    return math.floor(w + 0.5)
end

local function empire_tab(ctx, b, d, state, opts)
    local text, textures, hide, frames = opts.text, opts.textures, opts.hide, opts.frames
    local auth = authority(ctx, d.authority)
    textures[G .. "government_authority"] = auth.icon
    text[G .. "government_title"] = d.government or ""
    -- the right panel: the temporary modifiers, or the relations (relations_button)
    if state.panel == "relations" then
        hide.modifiers_window = true
    else
        hide.diplomacy_status_window = true
        if d.timed_modifiers > 0 then
            hide.empty_mods = true
        end
    end
    opts.actions[G .. "modifiers_button"] = "view_set:panel="
    opts.actions[G .. "relations_button"] = "view_set:panel=relations"
    -- elections (UpdateElections): on the ruler's death when the term is 0; the button disabled
    -- without an emergency or democratic election
    if auth.election_type == "none" then
        hide.election_window = true
    elseif auth.term == 0 then
        text[G .. "government_spec_window/election_window/next_election"] = "ELECTIONS_ON_RULER_DEATH"
    else
        text[G .. "government_spec_window/election_window/next_election"] = d.next_election or ""
    end
    opts.disabled[G .. "government_spec_window/election_window/emergency_election_button"] = auth.election_type ~= "democratic"
    if not auth.heir then
        hide.heir_window = true
    end
    if d.origin then
        textures[G .. "origin_window/origin_icon"] = C.icon_file(ctx, "common/governments/civics", d.origin,
            "gfx/interface/icons/governments/civics/" .. d.origin .. ".dds")
        text[G .. "origin_window/origin_name"] = d.origin
    end
    text[G .. "diplo_weight_window/diplomacy_weight"] = "§Y" .. diplomatic_weight(ctx, d) .. "§!"
    -- Reform Government (ShowGovernmentModWindow: render.windows.reform)
    opts.actions[G .. "government_reform"] = reform.open_action(d)
end

function M.build(ctx, d, state)
    d = d or {}
    -- (before the view's data has come, its frame alone: the data is nil until the snapshot
    -- carries it)
    if d.government == nil then
        local b0 = C.builder(ctx)
        b0:add(FILE, "government_view", { only = { background = true, close = true, close_button = true, heading = true }, actions = { [V .. "/close"] = "view_close" } })
        return b0.items, b0.report
    end
    local b = C.builder(ctx)
    local tab = state.tab or "government"
    local opts = {
        hide = { tab_budget = true, tab_budget_active = true, tab_advisor = true, tab_advisor_active = true,
            budget = true, advisor_window = true },
        text = { [V .. "/heading"] = C.name(ctx, d.name) },
        actions = {
            [V .. "/close"] = "view_close",
            -- the empire's name (OnRenameEmpire: CEmpireRenameDialog, render.windows.rename)
            [V .. "/empire_rename_button"] = rename.open("country", d.country, C.name(ctx, d.name)),
        },
        textures = {}, frames = {}, disabled = {},
    }
    for _, t in ipairs(TABS) do
        if t.name == tab then
            opts.hide["tab_" .. t.name] = true
        else
            opts.hide["tab_" .. t.name .. "_active"] = true
            opts.hide[t.window] = true
            opts.actions[V .. "/tab_" .. t.name] = "view_set:tab=" .. t.name
        end
    end
    if tab == "government" then
        empire_tab(ctx, b, d, state, opts)
    elseif tab == "demographics" and d.founder then
        -- the founder species (CGovernmentViewDemographicsTab::UpdatePops): its name, class, ideal
        -- planet (its planet preference trait's class), the pops (its portrait is 3D: not drawn)
        local D = V .. "/government_window/demographics_window/population_window/"
        opts.text[D .. "species_name"] = C.name(ctx, d.founder.name)
        opts.text[D .. "founder_species_class"] = d.founder.class or ""
        local ideal
        for _, t in ipairs(d.founder.traits or {}) do
            ideal = ideal or t:match("^trait_(pc_.*)_preference$")
        end
        opts.text[D .. "ideal_planet_class"] = ideal
            and C.raw(ctx, "IDEAL_PLANET_CLASS"):gsub("%$CLASS%$", C.loc(ctx, ideal)) or "NO_IDEAL_PLANET_CLASS"
        opts.text[D .. "pops"] = C.raw(ctx, "POPS_IN_WORLD"):gsub("%$NO|1%*H%$", "§H" .. C.short(d.founder_pops or d.pops) .. "§!")
            :gsub("%$PLANETS|H%$", "§H" .. tostring(d.planets or 1) .. "§!")
        opts.hide.species_leader_image = true
    end
    local r = b:add(FILE, "government_view", opts)
    if tab == "government" then
        -- the ethics and civics (object_icon entries in their overlapping boxes): their icons'
        -- files on GFX_ethic and GFX_government_civic
        local function icons(box, list, sprite, file_of)
            local rect = r.rects[G .. box]
            if not rect then
                return
            end
            C.overlap(b, rect, #list, 32, 2, function(i, x, y, prefix)
                b:add("interface/game_setup/species.gui", "object_icon", {
                    prefix = prefix, parent = { x = x, y = y, w = 0, h = 0 },
                    only = { icon = true },
                    sprites = { [prefix .. "/object_icon/icon"] = sprite },
                    textures = { [prefix .. "/object_icon/icon"] = file_of(list[i]) },
                })
            end)
        end
        icons("imperium_window/ethics", d.ethics or {}, "GFX_ethic", function(k)
            return "gfx/interface/icons/ethics/" .. k .. ".dds"
        end)
        icons("civics_window/civics", d.civics or {}, "GFX_government_civic", function(k)
            return C.icon_file(ctx, "common/governments/civics", k, "gfx/interface/icons/governments/civics/" .. k .. ".dds")
        end)
        -- the ruler's card in ruler_container (NInterface PORTRAIT_GUI_NAME_GOVERNMENT_VIEW_RULER)
        local rc = r.rects[G .. "portrait_window/ruler_container"]
        if rc and d.ruler then
            leaders.card(ctx, b, "paragon_portrait_container_ruler_government", rc, d.ruler, { prefix = "/government_ruler", ruler = true,
                named_actions = leaders.rename_actions(ctx, d.ruler) })
        end
    elseif tab == "demographics" then
        local P = V .. "/government_window/demographics_window/"
        -- the founder species' traits (CSpeciesTraitListboxEntry each; CTraitDatabase::SortTraits:
        -- positive first [I]) in population_window/traits
        local tr = r.rects[P .. "population_window/traits"]
        if tr and d.founder then
            -- (the planet preference first, as the game's frame shows it)
            local pos, neg = {}, {}
            for _, t in ipairs(d.founder.traits or {}) do
                if t:match("^trait_pc_.*_preference$") then
                    table.insert(pos, 1, t)
                else
                    local def = C.defs(ctx, "common/traits")[t]
                    local cost = tonumber(def and C.field(def, "cost")) or 0
                    table.insert(cost < 0 and neg or pos, t)
                end
            end
            for _, t in ipairs(neg) do
                pos[#pos + 1] = t
            end
            C.overlap(b, tr, #pos, 29, 4, function(i, x, y)
                leaders.trait_icon(ctx, b, pos[i], x, y + 2, 29, "/government_traits/" .. i)
            end)
        end
        -- the pie chart's list: one species_piechart_entry per species, 30 apart, in the
        -- species' database order (their ids) [I: the game's frame lists Qvagh, then Uthabulan];
        -- the slices' colours (CColorsDatabase::GetSpeciesColor) are not drawn
        local sl = r.rects[P .. "species_piechart/species_list"]
        if sl then
            local list = {}
            for _, s in ipairs(d.species or {}) do
                list[#list + 1] = s
            end
            table.sort(list, function(a, b2)
                return a.id < b2.id
            end)
            for i, s in ipairs(list) do
                local prefix = "/government_species/" .. i
                b:add(FILE, "species_piechart_entry", {
                    prefix = prefix, parent = { x = sl.x, y = sl.y + (i - 1) * 30, w = 0, h = 0 },
                    text = { [prefix .. "/species_piechart_entry/name"] = C.name(ctx, s.name) },
                })
            end
        end
    end
    -- the Reform Government window and the rename dialog over the view
    reform.build(ctx, b, d, state)
    rename.build(b, ctx, "government", state, nil)
    return b.items, b.report
end

-- the wheel over the Reform Government window's civics
function M.wheel(ctx, d, state, notches, x, y)
    return reform.wheel(ctx, d or {}, state, notches, x, y)
end

-- its commands in the simulation (views.rs: `cmd:government:VERB:ARG...`): reform, rename
function M.command(...)
    return require("render.windows.empire_commands").run(...)
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end


-- Escape (views.rs): the side windows in these state keys close first, else the view closes
M.escape_keys = { "reform", "rf_auth", "rf_civics", "rf_scroll" }
-- (the rename dialog first, then the Reform window: their Cancel buttons' ESCAPE)
function M.escape(state)
    if state.reform == "1" then
        return reform.close_action()
    end
    return nil
end
rename.install(M, "government")

return M
