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
    local hide = {
        -- the espionage tab and its button's twin (ShowTab, UpdateTabVisibility)
        espionage_tab = true, diplomacy_tab_button = true, espionage_tab_button_active = true,
        -- the portraits (CPortraitObject) [not drawn here]
        portrait_room = true, portrait_character = true, founder_species = true,
        -- the action view and its confirmation (ShowDiplomaticActions: none selected)
        action_diplomacy_view = true, ACTION_DEFAULT_VIEW = true, favors_container = true,
        confirm_button = true, cancel_button = true, alien_message = true,
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
    local r = ctx.layout(FILE, "diplomacy_view", {
        hide = hide, text = text, frames = frames,
        actions = { [V] = "diplo:none", [V .. "/close"] = "diplo:close" },
    })
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
