-- render/windows/government.lua : the government view (interface/government_view.gui,
-- CGovernmentView; docs/windows/empire.md section 2), opened by the top bar's flag. Its Empire tab
-- (CGovernmentViewGovernmentTab::Update): the empire's name, the ruler's card, the government's
-- type and authority, ethics, civics, origin, elections, diplomatic weight, the temporary
-- modifiers or the relations; its Demographics tab (CGovernmentViewDemographicsTab): the
-- founder species, the pops.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")

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
    }
    local ruler = tonumber(world.field(c, "ruler"))
    d.ruler = ruler and leaders.leader_data(ruler, c) or nil
    d.founder = leaders.species_data(tonumber(world.field(c, "founder_species_ref")))
    return d
end

-- the tabs (CGovernmentView::UpdateTabs): the tab shown has its `_active` button, the others
-- their own; Budget is never available (CGovernmentViewBudgetTab::ShouldBeAvailable returns 0),
-- the advisor's only with more than one playable voice type (not drawn)
local TABS = {
    { name = "government", window = "government_window" },
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
    opts.actions[G .. "government_reform"] = nil
end

function M.build(ctx, d, state)
    local b = C.builder(ctx)
    local tab = state.tab or "government"
    local opts = {
        hide = { tab_budget = true, tab_budget_active = true, tab_advisor = true, tab_advisor_active = true,
            budget = true, advisor_window = true },
        text = { [V .. "/heading"] = C.name(ctx, d.name) },
        actions = { [V .. "/close"] = "view_close" },
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
            leaders.card(ctx, b, "paragon_portrait_container_ruler_government", rc, d.ruler, { prefix = "/government_ruler", ruler = true })
        end
    end
    return b.items, b.report
end

return M
