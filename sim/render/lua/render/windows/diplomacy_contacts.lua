-- render/windows/diplomacy_contacts.lua : Contacts (interface/galaxy_view.gui, CGalaxyView), the
-- empires the player has communications with, the player's own row among them, and the selected
-- one's profile (CGalaxyViewEmpireProfile). docs/windows/diplomacy.md section 2.

local diplomacy = require("render.windows.diplomacy")

local M = {}

local FILE = "interface/galaxy_view.gui"
local V = "/galaxy_view"
local G = V .. "/galaxy"
local ROW_H = 47

-- the filters (CGalaxyView::Setup): a checkbox per country type the .gui has, all checked; the
-- type's label's text_color_code colours its rows' empire_type
local TYPE_FILTERS = { default = "W", fallen_empire = "H", primitive = "L" }

-- the sort header buttons and their ECountrySortingMethod (Setup: button +0x20)
local SORT_BUTTONS = {
    name = "name", empire_relations = "relation", power = "power", status = "diplomacy",
    alliance_federation = "alliance", planets = "planets", war_status = "war",
}

-- a country's name as the list sorts it (CCountryGuiCache::GetName)
local function sort_key(ctx, c)
    return ctx.name(c.name)
end

-- the pacts toward the player (CDiplomaticPactsTowardPlayerView::Update: EDiploStatusItemType 0..32
-- in order, its sprite) [V the order and sprites; I the conditions, from the relations' flags:
-- NDiplomacyUtil::HasDiplomacyItemTowardCountry not read]
function M.pacts(data, id)
    local ours, theirs = data.relations[id] or { flags = {} }, data.their[id] or { flags = {} }
    local c, pc = data.countries[id], data.countries[data.player] or {}
    local out = {}
    local function add(cond, sprite)
        if cond then
            out[#out + 1] = sprite
        end
    end
    local S = "GFX_diplomacy_status_"
    add(#(ours.wars or {}) > 0, S .. "war")
    -- a country type without relations has no pacts (the marauders' closed borders toward the
    -- player show no icon in the game's frame) [I]
    local t = diplomacy.country_types(game_dir_of_ctx)[c.type] or {}
    if not t.relations then
        return out
    end
    add(c.federation and c.federation == pc.federation, S .. "federation")
    add(c.overlord == data.player, S .. "has_vassal")
    add(pc.overlord == id, S .. "trade")
    add(ours.flags.is_rival, S .. "rivalry")
    add(theirs.flags.is_rival, S .. "rivaled")
    add(ours.flags.non_aggression_pledge, S .. "non_aggression_pact")
    add(ours.flags.commercial_pact, S .. "commercial_pact")
    add(ours.flags.research_agreement, S .. "research_agreement")
    add(ours.flags.defensive_pact, S .. "defensive_pact")
    add(ours.flags.guarantee, S .. "guarantee")
    add(theirs.flags.guarantee, S .. "guaranteed_by")
    add(ours.flags.support_independence, S .. "support_independence")
    add(ours.flags.migration_access, S .. "migration_pact")
    add(ours.flags.waystation_pact, S .. "waystation_pact")
    add(theirs.flags.closed_borders, S .. "closed_borders")
    add(ours.truce ~= nil, S .. "truce")
    return out
end

-- the countries Contacts lists, in its order (UpdateEmpires: SortCountries over the countries by
-- id, stable; ShouldShowEmpire), each with its empire_type colour code
function M.rows(ctx, state)
    local data = ctx.data
    local player = data.player
    local types = diplomacy.country_types(ctx.game_dir)
    local rows = {}
    for _, id in ipairs(data.order) do
        local c = data.countries[id]
        local show, colour = false, "M"
        if c and id == player then
            -- IsCountryVisibleTo(viewer, country, 1): the player's own row
            show = true
        elseif c then
            local t = types[c.type] or {}
            local rel = data.relations[id]
            show = t.show_in_contacts_list and rel and rel.communications or false
        end
        if show then
            local f = TYPE_FILTERS[c.type]
            if f then
                colour = f
            else
                -- "other": the player can act with it or has custom diplomacy with it [I: both
                -- taken as communications]
                colour = "M"
            end
            rows[#rows + 1] = { id = id, country = c, colour = colour, key = sort_key(ctx, c) }
        end
    end
    -- the sort: by name (method 0) A..Z by default; a header toggles its direction
    local method, descending = (state.sort or "name"):match("^(%a+)(:?d?e?s?c?)$")
    descending = descending == ":desc"
    local function value(r)
        if method == "relation" then
            if r.id == player then
                return 1500
            end
            local op = data.opinion[r.id]
            return op and op.of_us or (data.their[r.id] or {}).opinion_current or 0
        elseif method == "planets" then
            return r.country.planets or 0
        elseif method == "war" then
            return r.country.at_war and 0 or 1
        end
        return r.key
    end
    -- a stable sort (by the countries' order on ties)
    for i, r in ipairs(rows) do
        r.index = i
    end
    table.sort(rows, function(a, b)
        local va, vb = value(a), value(b)
        if va ~= vb then
            if descending then
                return va > vb
            end
            return va < vb
        end
        return a.index < b.index
    end)
    return rows
end

-- the intel the player has on a country (CIntelManager): an EIntelInfo is available from its
-- item's level in common/intel_categories on (diplomacy.intel_need); everything on the player's
-- own country. The EIntelInfo bits' items [I: by name]: government (0x2) authority, ethics
-- (0x20000), colonies (0x800) intel_economy_colonies_low, sprawl (0x2000) intel_empire_sprawl,
-- federation (0x80000) federation_name, power relative_power; pops (0x400) has no item of its own
-- [I: the colonies']
local ITEMS = {
    government = "authority", ethics = "ethics", colonies = "intel_economy_colonies_low",
    sprawl = "intel_empire_sprawl", federation = "federation_name", power = "relative_power",
    pops = "intel_economy_colonies_low",
}
local game_dir_of_ctx
local function knows(data, id, what)
    if id == data.player then
        return true
    end
    return (data.intel[id] or 0) >= diplomacy.intel_need(game_dir_of_ctx, ITEMS[what] or what)
end

local function profile(ctx, id, hide, text, frames, sprites)
    local data = ctx.data
    local c = data.countries[id]
    local types = diplomacy.country_types(ctx.game_dir)
    local t = types[c.type] or {}
    local P = G .. "/empire_profile"
    local S = P .. "/diplo_stats"
    local mine = id == data.player
    hide.empire_profile_minimalist = not t.minimalist or nil
    hide.empire_profile = t.minimalist or nil
    if t.minimalist then
        P = G .. "/empire_profile_minimalist"
    end
    ctx.flags[P .. "/selected_empire_flag"] = id
    text[P .. "/selected_empire_name"] = ctx.name(c.name)
    -- the government, its authority, the personality: with the government's intel
    if knows(data, id, "government") then
        text[P .. "/selected_empire_government_type"] = c.government
        -- CGovernmentAuthorityType::ApplyToButton: the authority's icon, found by its key
        sprites[P .. "/government_authority"] = ctx.texture("gfx/interface/icons/governments/authorities/" .. tostring(c.authority) .. ".dds")
        if data.player_names[id] then
            text[P .. "/selected_empire_personality_type"] = "§M" .. ctx.fmt("PLAYED_BY", { PLAYER = data.player_names[id] }) .. "§!"
        else
            text[P .. "/selected_empire_personality_type"] = "personality_" .. tostring(c.personality)
        end
    else
        text[P .. "/selected_empire_government_type"] = ""
        text[P .. "/selected_empire_personality_type"] = ""
    end
    -- the personality: for a country type with relations, not the player's own
    if mine or not t.relations then
        hide[P .. "/selected_empire_personality_type"] = true
    end
    -- the portrait (CPortraitObject: the ruler's species) [not drawn here]
    hide[P .. "/species_box"] = true
    -- the ethics icons (UpdateEthics: with no intel record or the ethics' intel), each ethic's
    -- gfx/interface/icons/ethics/<ethic>.dds (the fanatic ones have no GFX_ sprite) [I: by name]
    if knows(data, id, "ethics") and not t.minimalist then
        local sp = {}
        for _, e in ipairs(c.ethics or {}) do
            sp[#sp + 1] = ctx.texture("gfx/interface/icons/ethics/" .. e .. ".dds")
        end
        ctx.ethics = { path = P .. "/selected_empire_ethics_icons", sprites = sp }
    end
    -- diplo_stats (NCountryDiplomacyStatsView): the items a country without relations, or the
    -- player, does not have
    if mine or not t.relations then
        for _, n in ipairs({ "pops", "diplo_weight", "sprawl", "power", "diplo_stance" }) do
            hide[S .. "/" .. n] = true
        end
    end
    local primitive = c.type == "primitive"
    if not primitive then
        hide[S .. "/awareness"] = true
        hide[S .. "/preftl_tech"] = true
    else
        hide[S .. "/power"] = true
    end
    -- intel: not on the player's own country
    if mine then
        hide[S .. "/intel"] = true
        hide[S .. "/Intel_darkcut"] = true
    else
        local intel = data.intel[id] or 0
        text[S .. "/intel/label"] = ctx.fmt("INTEL_CONTACTS", { VALUE = intel })
        sprites[S .. "/intel/icon"] = "GFX_intel_level_" .. diplomacy.intel_frame(ctx.game_dir, intel)
        frames[S .. "/intel/intel_progressbar"] = math.floor(100 * intel / 100 + 0.5)
    end
    -- espionage: not available (no spy network) [I: IsEspionageAvailableFor not read]
    for _, n in ipairs({ "icon", "label", "spypower_trend_up", "spypower_trend_down", "spypower_trend_stagnant" }) do
        hide[S .. "/espionage/" .. n] = true
    end
    -- opinion (COpinionItem): theirs of us, the level's bar (GFX_diplomacy_opinion_<level>, its
    -- frame the fill within the level's interval), the label the AI's attitude to us
    if mine then
        hide[S .. "/opinion"] = true
    else
        local op = data.opinion[id]
        local v = op and op.of_us or (data.their[id] or {}).opinion_current or 0
        local level = require("render.windows.diplomacy_country").opinion_level(v)
        local bounds = { { -1500, -750 }, { -750, -300 }, { -300, 300 }, { 300, 750 }, { 750, 1500 } }
        local names = { "terrible", "poor", "neutral", "good", "excellent" }
        local lo, hi = bounds[level + 1][1], bounds[level + 1][2]
        sprites[S .. "/opinion/icon"] = "GFX_diplomacy_opinion_" .. names[level + 1]
        frames[S .. "/opinion/icon"] = math.max(1, math.floor(100 * (v - lo) / (hi - lo)))
        text[S .. "/opinion/label"] = data.player_names[id] and "PLAYER_EMPIRE_SP" or ("attitude_" .. tostring(data.attitude[id] or "null"))
    end
    if not knows(data, id, "pops") then
        text[S .. "/pops/label"] = "LABEL_QUESTION_MARK"
        text[S .. "/sprawl/label"] = "LABEL_QUESTION_MARK"
        text[S .. "/diplo_weight/label"] = "LABEL_QUESTION_MARK"
    else
        text[S .. "/pops/label"] = diplomacy.si(c.pops or 0)
        text[S .. "/sprawl/label"] = tostring(math.floor(c.empire_size or 0))
        text[S .. "/diplo_weight/label"] = "LABEL_QUESTION_MARK"
    end
    -- the Diplomacy and Espionage buttons: enabled by IsDiplomaticViewAvailableFor (communications)
    local rel = data.relations[id]
    ctx.actions[P .. "/diplomacy_button"] = (not mine and rel and rel.communications) and ("diplo:country:" .. id) or nil
    -- zoom to capital: a capital in the world
    if not c.capital then
        hide[P .. "/zoom_to_capital_button"] = true
    end
end

function M.build(ctx, state)
    local data = ctx.data
    game_dir_of_ctx = ctx.game_dir
    -- the tab: Agreements only while its button is enabled (an overlord or subjects), the Shroud
    -- not drawn (its DLC's rule not read): else Contacts, as Update switches back
    local pc0 = data.countries[data.player]
    local agreements_ok = pc0 and (pc0.overlord or #(pc0.subjects or {}) > 0)
    local tab = (state.tab == "agreements" and agreements_ok) and "agreements" or "contacts"
    ctx.actions = {
        [V] = "diplo:none", [V .. "/close"] = "diplo:close",
    }
    local hide = {
        -- the tabs (UpdateTabVisibility): the active one's _active twin; the shroud's needs its DLC
        tab_galaxy = tab == "contacts" or nil, tab_galaxy_active = tab ~= "contacts" or nil,
        tab_agreements = tab == "agreements" or nil, tab_agreements_active = tab ~= "agreements" or nil,
        tab_shroud = true, tab_shroud_active = true, shroud_window = true,
        galaxy = tab ~= "contacts" or nil, agreements = tab ~= "agreements" or nil,
        -- the filters' drop-down is not used (the checkboxes are)
        filters = true,
    }
    local text, frames, sprites = {}, {}, {}
    text[V .. "/header"] = tab == "contacts" and "topbar_button_contacts_name" or "xenos_ui_agreements"
    -- the checkboxes: all checked
    for _, n in ipairs({ "default", "fallen_empire", "primitive", "other", "non_player" }) do
        frames[G .. "/filter_checkbox_" .. n] = 2
    end
    -- the agreements tab: enabled with an overlord or subjects (Update)
    local pc = data.countries[data.player]
    if pc and (pc.overlord or #(pc.subjects or {}) > 0) then
        ctx.actions[V .. "/tab_agreements"] = "diplo:tab:agreements"
    end
    ctx.actions[V .. "/tab_galaxy"] = "diplo:tab:contacts"
    for b, m in pairs(SORT_BUTTONS) do
        local cur = state.sort or "name"
        ctx.actions[G .. "/" .. b] = "diplo:sort:" .. ((cur == m) and (m .. ":desc") or m)
    end

    local rows = tab == "contacts" and M.rows(ctx, state) or {}
    -- the selection: the clicked row, else the first (UpdateEmpires), else the player
    local selected = nil
    for _, r in ipairs(rows) do
        if r.id == state.selected then
            selected = r.id
        end
    end
    selected = selected or (rows[1] and rows[1].id) or data.player
    if tab == "contacts" and data.countries[selected] then
        profile(ctx, selected, hide, text, frames, sprites)
    end

    local r = ctx.layout(FILE, "galaxy_view", {
        hide = hide, text = text, frames = frames, sprites = sprites, actions = ctx.actions,
    })
    if ctx.ethics then
        -- the box's format = right
        ctx.icons(ctx.ethics.path, r.rects[ctx.ethics.path], ctx.ethics.sprites, "right")
    end
    local list = r.rects[G .. "/empires_window/galaxy_empires"]
    if not list then
        return
    end
    local y, bottom = list.y, list.y + list.h
    local types = diplomacy.country_types(ctx.game_dir)
    for _, row in ipairs(rows) do
        if y + ROW_H > bottom then
            break
        end
        local id, c = row.id, row.country
        local t = types[c.type] or {}
        local p = "/contacts/" .. id
        local w = p .. "/galaxy_view_empire_entry"
        local rtext, rhide = {}, {}
        rtext[w .. "/name"] = ctx.name(c.name)
        -- empire_type (GetCountryTypeString) in its filter's colour: a human's "Player Empire",
        -- else the government [I: the function not read]
        if data.player_names[id] then
            rtext[w .. "/empire_type"] = "PLAYER_EMPIRE_SP"
        else
            local g = ctx.loc and ctx.loc.has(c.government) and ctx.loc.get(c.government) or c.government
            rtext[w .. "/empire_type"] = "§" .. row.colour .. g .. "§!"
        end
        -- their opinion of the player: DASH on the player's own row
        if id == data.player then
            rtext[w .. "/empire_relations"] = "DASH"
        else
            local op = data.opinion[id]
            local v = op and op.of_us or (data.their[id] or {}).opinion_current or 0
            rtext[w .. "/empire_relations"] = ctx.fmt("GALAXY_VIEW_EMPIRE_ENTRY_THEIR_OPINION", { VAL = math.floor(v) })
        end
        -- power: other countries of a type with relations and no custom opinion
        if id == data.player or not t.relations or t.custom_opinion then
            rhide.power = true
        else
            rtext[w .. "/power"] = "RELATIVE_POWER_UNAVAILABLE_INTEL"
        end
        -- planets: with the colonies' intel
        rtext[w .. "/planets"] = knows(data, id, "colonies") and tostring(c.planets or 0) or ""
        -- the federation: its name with the federation's intel
        if c.federation and data.federations[c.federation] then
            rtext[w .. "/alliance_federation"] = knows(data, id, "federation") and ctx.name(data.federations[c.federation].name) or "UNKNOWN_FEDERATION"
        else
            rtext[w .. "/alliance_federation"] = ""
        end
        -- the war icon: any war, frame 1 offensive, 2 defensive
        local rframes = {}
        if not c.at_war then
            rhide.war_status_icon = true
        else
            rframes[w .. "/war_status_icon"] = c.offensive_war and 1 or 2
        end
        if id ~= selected then
            rhide.selected_overlay = true
        end
        local er = ctx.layout(FILE, "galaxy_view_empire_entry", {
            prefix = p, parent = { x = list.x, y = y, w = 0, h = 0 },
            text = rtext, hide = rhide, frames = rframes,
            actions = { [w .. "/background"] = "diplo:select:" .. id },
        })
        -- the pacts' icons in the box (format left)
        if id ~= data.player then
            ctx.icons(w .. "/diplomacy_icons", er.rects[w .. "/diplomacy_icons"], M.pacts(data, id), "left")
        end
        ctx.flags[w .. "/flag"] = id
        y = y + ROW_H
    end
end

return M
