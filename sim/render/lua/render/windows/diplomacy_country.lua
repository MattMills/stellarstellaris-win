-- render/windows/diplomacy_country.lua : a country's diplomacy (interface/diplomacy_view.gui,
-- CDiplomacyView), the Diplomacy tab as Contacts' Diplomacy button opens it: docs/windows/
-- diplomacy.md section 3. The portraits (CPortraitObject), the actions' triggers and the greeting
-- phrases are not drawn yet.

local M = {}

local FILE = "interface/diplomacy_view.gui"
local V = "/diplomacy_view"
local T = V .. "/diplomacy_tab"
local S = T .. "/country_diplomacy_stats"

-- CCountry::GetOpinionLevel (OPINION_EXCELLENT 750, GOOD 300, POOR -300, TERRIBLE -750): 0
-- Terrible .. 4 Excellent
function M.opinion_level(v)
    if v > 750 then
        return 4
    elseif v > 300 then
        return 3
    elseif v < -750 then
        return 0
    elseif v < -300 then
        return 1
    end
    return 2
end

local function primitive(c)
    return c and (c.type == "primitive" or c.type == "pre_ftl")
end

function M.build(ctx, state)
    local data = ctx.data
    local id = state.id
    local c = data.countries[id]
    local rel = data.relations[id]
    -- Show(): only a country we can act with (not ourselves, with communications)
    if not c or id == data.player or not (rel and rel.communications) then
        return
    end
    -- a country type without relations (the marauders): the game shows its own diplomacy event
    -- instead ("Incoming Transmission", by the game's frame) [I: the route not read]
    local t = require("render.windows.diplomacy").country_types(ctx.game_dir)[c.type] or {}
    if not t.relations then
        return
    end
    local their = data.their[id] or {}
    local op = data.opinion[id] or {}
    local human = data.player_names[id] ~= nil
    local espionage = state.tab == "espionage"
    local picked = state.action
    local hide = {
        -- the tabs (ShowTab: diplomacy_tab or espionage_tab; UpdateTabVisibility: the active
        -- tab's _active button, the other's plain one)
        espionage_tab = not espionage or nil, diplomacy_tab = espionage or nil,
        diplomacy_tab_button = not espionage or nil, diplomacy_tab_button_active = espionage or nil,
        espionage_tab_button = espionage or nil, espionage_tab_button_active = not espionage or nil,
        -- the portraits (CPortraitObject) [not drawn here]
        portrait_room = true, portrait_character = true, founder_species = true,
        -- the action view and its confirmation (ShowDiplomaticActions: none picked; SelectAction
        -- -> ShowActionView: the list hidden, the action's view, Confirm and Cancel)
        action_diplomacy_view = not picked or nil, ACTION_DEFAULT_VIEW = not picked or nil,
        confirm_button = not picked or nil, cancel_button = not picked or nil,
        diplo_actions_window = picked or nil,
        favors_container = true, alien_message = true,
        -- the council and custodian frames (no galactic community)
        council_frame = true, emperor_council_frame = true, custodian_frame = true, emperor_frame = true,
        -- the subject's specialist icon (no overlord)
        specialist_subject_icon = true,
        -- awareness: primitives that are unaware only; pre-FTL tech: primitives only
        awareness_window = true, awareness = true,
        tts_button = true, diplomacy_target_selector = true,
    }
    if not c.federation then
        hide.federation_icon = true
    end
    if not primitive(c) then
        hide.preftl_tech_window = true
        hide.preftl_tech = true
    else
        hide.relative_power = true
        hide.fleet_power = true
        hide.tech_power = true
        hide.economic_power = true
    end
    -- loyalty: only between a subject and its overlord
    if not (c.overlord == data.player or data.countries[data.player] and data.countries[data.player].overlord == id) then
        hide.loyalty = true
    end
    local text, frames = {}, {}
    text[V .. "/heading"] = "DIPLOMACY"
    text[T .. "/empire_name"] = ctx.name(c.name)
    text[T .. "/empire_government_type"] = c.government
    text[T .. "/empire_personality_type"] = human and ("§M" .. ctx.fmt("PLAYED_BY", { PLAYER = data.player_names[id] }) .. "§!")
        or ("personality_" .. tostring(c.personality))
    if c.species then
        text[T .. "/species_name"] = ctx.name(c.species.name)
        -- the species class's name (its key) [I]
        text[T .. "/species_type"] = c.species.class or ""
    end
    -- the ruler: NAME_WITH_TITLE_FORMAT "$TITLE$ $NAME$" [I: the government's ruler title not read:
    -- the name alone]; the leader's species: the founder species' name [I]
    text[T .. "/empire_leader"] = c.ruler_name and ctx.name(c.ruler_name) or ""
    text[T .. "/empire_leader_species"] = c.species and ctx.name(c.species.name) or ""
    -- the opinion: theirs of us (CalcRelationValue); its level's bars, its trend against the
    -- relation's last month
    local value = op.of_us or their.opinion_current or 0
    local level = M.opinion_level(value)
    frames[T .. "/opinion_window/opinion_level_bars"] = level + 1
    local last = their.opinion_last_month
    if not last or last == value then
        hide["/diplomacy_view/diplomacy_tab/opinion_window/trend_up"] = true
        hide["/diplomacy_view/diplomacy_tab/opinion_window/trend_down"] = true
    elseif value > last then
        hide["/diplomacy_view/diplomacy_tab/opinion_window/trend_down"] = true
    else
        hide["/diplomacy_view/diplomacy_tab/opinion_window/trend_up"] = true
    end
    -- the stats (NCountryDiplomacyStatsView): the opinion's label is the AI's attitude to us
    text[S .. "/opinion/label"] = human and "PLAYER_EMPIRE_SP" or ("attitude_" .. tostring(data.attitude[id] or "null"))
    -- the intel each item needs (common/intel_categories' items, by name [I]); "?" without it
    local diplomacy = require("render.windows.diplomacy")
    local function known(item)
        return (data.intel[id] or 0) >= diplomacy.intel_need(ctx.game_dir, item)
    end
    if not known("authority") then
        text[T .. "/empire_government_type"] = ""
        text[T .. "/empire_personality_type"] = ""
    end
    text[S .. "/planets/label"] = known("intel_economy_colonies_low") and tostring(c.planets or 0) or "LABEL_QUESTION_MARK"
    text[S .. "/pops/label"] = known("intel_economy_colonies_low") and ctx.fmt("$VALUE|1*$", { VALUE = c.pops or 0 }) or "LABEL_QUESTION_MARK"
    text[S .. "/sprawl/label"] = known("intel_empire_sprawl") and tostring(math.floor(c.empire_size or 0)) or "LABEL_QUESTION_MARK"
    -- the diplomatic weight: not in the save [I]
    text[S .. "/diplo_weight/label"] = "LABEL_QUESTION_MARK"
    text[S .. "/trust/label"] = "§Y" .. tostring(math.floor(their.trust or 0)) .. "§!"
    text[S .. "/favors_to_us/label"] = tostring(math.floor(their.favors or 0))
    text[S .. "/favors_to_them/label"] = tostring(math.floor(rel.favors or 0))
    local intel = data.intel[id] or 0
    text[S .. "/intel/label"] = ctx.fmt("INTEL_CONTACTS", { VALUE = intel })
    -- the relation box: our flag and the pacts toward us
    ctx.flags[T .. "/relation_window/flag"] = data.player
    ctx.flags[T .. "/empire_flag"] = id

    -- the civics: known (intel 0x10) or the unknown civic's icon [I: the civics' item]
    local intel_ok = known
    if intel_ok("civics") then
        hide.unknown_civic_icon = true
    end
    -- the window's buttons: close (CloseClick), the capital (to_to_home_world, shown with a
    -- capital: HasInworldCapital), the tabs (OnTabButton: the inactive tab's button; espionage
    -- enabled by IsEspionageAvailableFor [I: a spy network on them])
    local actions = {
        [V] = "diplo:none", [V .. "/close"] = "diplo:close",
        [V .. "/diplomacy_tab_button"] = "diplo:tab:diplomacy",
    }
    local disabled = {}
    if c.capital_system then
        actions[V .. "/to_to_home_world"] = "diplo:zoom:" .. id
    else
        hide.to_to_home_world = true
    end
    if c.spy_network then
        actions[V .. "/espionage_tab_button"] = "diplo:tab:espionage"
    else
        disabled[V .. "/espionage_tab_button"] = true
    end
    text[V .. "/heading"] = espionage and "ESPIONAGE" or "DIPLOMACY"
    -- the action view (ShowActionView): compact width, the action's title, description and icon
    local A = require("render.windows.diplomacy_actions")
    local sizes, sprites, positions = {}, {}, {}
    local list = state.actions and diplomacy.load_chunk(state.actions) or {}
    local picked_entry
    for _, e in ipairs(list) do
        if e.key == picked then
            picked_entry = e
        end
    end
    if picked then
        -- SetWideMode: 990 wide, the window where it was (its left edge kept: centred at 1280)
        sizes[V] = { 990, 635 }
        positions[V] = { (990 - 1280) / 2, 0 }
        local tk = A.title_key(picked, ctx.loc)
        text[T .. "/ACTION_DEFAULT_VIEW/action_title"] = tk
        text[T .. "/ACTION_DEFAULT_VIEW/action_desc"] = tk:gsub("_TITLE$", "_DESC")
        text[T .. "/ACTION_DEFAULT_VIEW/effects_text"] = "EFFECTS"
        hide.action_extra_desc = true
        -- ShowActionView without an extra description: effects_text and action_desc at the
        -- positionTypes effects_text_position_default (178, 50) and action_desc_position_default
        -- (244, 50) [I: read as x, y]
        positions[T .. "/ACTION_DEFAULT_VIEW/effects_text"] = { 178, 50 }
        positions[T .. "/ACTION_DEFAULT_VIEW/action_desc"] = { 244, 50 }
        -- HideSubWindows -> HideGeneralEmpireInfo: the empire's info under the action's view
        for _, n in ipairs({ "diplomacy_status_window", "relation_window", "ethics_window", "civics_window",
            "government_authority", "federation_icon", "empire_flag", "empire_name", "empire_government_type",
            "empire_personality_type", "country_diplomacy_stats", "species_name", "species_type", "capital_icon",
            "opinion_window", "awareness_window", "preftl_tech_window", "main_diplomacy_view" }) do
            hide[n] = true
        end
        if picked_entry and picked_entry.icon then
            sprites[T .. "/ACTION_DEFAULT_VIEW/diplomacy_icon"] = picked_entry.icon
        end
        actions[T .. "/confirm_button"] = "diplo:action_confirm"
        actions[T .. "/cancel_button"] = "diplo:action_cancel"
        text[T .. "/confirm_button"] = "HOTJOIN_CONFIRM"
        text[T .. "/cancel_button"] = "CANCEL"
        -- the confirm button: enabled when the action can be proposed (IsProposable)
        if picked_entry and not picked_entry.possible then
            disabled[T .. "/confirm_button"] = true
            actions[T .. "/confirm_button"] = nil
        end
    end
    -- the last proposal's answer, in the alien's bubble (SetAlienMessage) [I: the game's own
    -- acceptance texts not generated here]; the greeting phrase (a weighted pick of
    -- common/diplo_phrases) is not drawn [not done here]
    if state.message then
        text[T .. "/main_diplomacy_view/alien_message_window/alien_message_main"] = state.message
    else
        hide.alien_message_window = true
    end
    local r = ctx.layout(FILE, "diplomacy_view", {
        hide = hide, text = text, frames = frames, actions = actions, disabled = disabled, sizes = sizes,
        sprites = sprites, positions = positions,
    })
    -- the actions (CDiploActionEntry, diplo_action_entry) down actions_list: the title, the
    -- background enabled when the action can be proposed; the AI's acceptance icon not shown (the
    -- engine does not compute the acceptance) [not done here]
    local L = r.rects[T .. "/diplo_actions_window/actions_list"]
    if L and not picked then
        local y = L.y
        for k, e in ipairs(list) do
            if y + 29 > L.y + L.h then
                break
            end
            local p = "/diplo_actions/" .. k
            local w = p .. "/diplo_action_entry"
            local er = ctx.layout(FILE, "diplo_action_entry", {
                prefix = p, parent = { x = L.x, y = y, w = 0, h = 0 },
                text = { [w .. "/action_title"] = A.title_key(e.key, ctx.loc) },
                hide = { ai_acceptance_icon = true },
                -- (its background is the window's: the click on the entry's path)
                actions = { [w] = e.possible and ("diplo:action:" .. e.key) or nil },
                disabled = (not e.possible) and { [w] = true } or nil,
            })
            local rect = er.rects[w]
            -- the list's spacing (-5)
            y = y + ((rect and rect.h > 0) and rect.h or 34) - 5
        end
    end
    -- the ethics' and civics' icons (ApplyEthicsToBox, FillOverlappingElementsBox), by name
    if intel_ok("ethics") then
        local sp = {}
        for _, e in ipairs(c.ethics or {}) do
            sp[#sp + 1] = ctx.texture("gfx/interface/icons/ethics/" .. e .. ".dds")
        end
        ctx.icons(T .. "/ethics_window/empire_ethics_icons", r.rects[T .. "/ethics_window/empire_ethics_icons"], sp, "left")
    end
    if intel_ok("civics") then
        local sp = {}
        for _, e in ipairs(c.civics or {}) do
            sp[#sp + 1] = ctx.texture("gfx/interface/icons/governments/civics/" .. e .. ".dds")
        end
        ctx.icons(T .. "/civics_window/civics_icons", r.rects[T .. "/civics_window/civics_icons"], sp, "left")
    end
end

return M
