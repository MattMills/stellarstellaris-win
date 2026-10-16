-- render/windows/diplomacy_community.lua : the galactic community (interface/
-- galactic_community_view.gui, CGalacticCommunityView), as the game shows it to the player:
-- docs/windows/diplomacy.md. What it draws of a formed community (members, council, resolutions
-- on the floor) is laid out from the save's community; the saves read so far have none, and the
-- view then shows the player's own greeting, the empty queue and Join.

local M = {}

local FILE = "interface/galactic_community_view.gui"
local V = "/galactic_community_view"
local CW = V .. "/community_window"

local function contains(list, x)
    for _, v in ipairs(list or {}) do
        if v == x then
            return true
        end
    end
    return false
end

function M.build(ctx, state)
    local data = ctx.data
    local gc = data.community or { members = {}, council = {} }
    local player = data.player
    local member = contains(gc.members, player)
    -- the tab (Update: this+0x1688): Senate Floor needs membership (the button disabled)
    local tab = state.tab or "community"
    if tab == "senate" and not member then
        tab = "community"
    end

    local hide = {
        -- Show(): the tabs' windows, the focus view; UpdateFocus: no focus, no top-level focus
        senate_window = tab ~= "senate" or nil, resolutions_window = tab ~= "resolutions" or nil,
        community_window = tab ~= "community" or nil,
        change_galactic_focus_view = true, focus_container = true,
        -- UpdateCommunity: no custodian, no Galactic Imperium
        galactic_custodian_container = true, galactic_empire_container = true, navy_group = true,
        defense_force_group = true,
        -- UpdateMembers: the council's containers (no council positions, no custodian)
        council_container = true, council_with_leader_container = true,
        -- UpdateGreetingCountryButton: the frames of the council, the custodian, the emperor
        council_frame = true, emperor_council_frame = true, custodian_frame = true, emperor_frame = true,
        -- the ruler's portrait (CPortraitObject: not drawn here)
        portrait = true,
        -- the greeting country's stats: not shown for the player [I: by the game's frame]
        flag_stats_window = true,
        -- Show(): supported_by_container hidden
        supported_by_container = true,
        -- the tab buttons: the active one's _active twin (UpdateTabVisibility)
        tab_community = tab == "community" or nil, tab_community_active = tab ~= "community" or nil,
        tab_senate = tab == "senate" or nil, tab_senate_active = tab ~= "senate" or nil,
        tab_resolutions = tab == "resolutions" or nil, tab_resolutions_active = tab ~= "resolutions" or nil,
    }
    local text, frames, sizes, positions = {}, {}, {}, {}
    local proposed = gc.proposed or {}

    -- UpdateProposed: the queue's text when it is empty
    if #proposed > 0 then
        hide.resolution_queue_desc = true
    end
    -- the player's diplomatic weight (country +0x2f40: a modifier total, not in the save) [I: not
    -- computed here]
    hide.diplomatic_weight_number = true

    -- UpdateCommunity, propose mode (an empty queue)
    local HR = CW .. "/highlighted_resolution_container"
    if #proposed == 0 then
        for _, n in ipairs({ "button_details", "button_supports", "highlighted_name", "highlighted_icon", "details_text",
            "insession_summary_container" }) do
            hide[n] = true
        end
        text[HR .. "/propose_resolution_name"] = member and "PROPOSE_RESOLUTION_NAME" or "ancrel.2019.c"
        text[HR .. "/details_container/propose_resolution_details_text"] = member and "PROPOSE_RESOLUTION_DETAILS" or "MUST_BE_MEMBER"
        frames[HR .. "/highlighted_type_background"] = member and 5 or 4
    end
    -- the decisions: a member's list, else the text that says membership is needed (not with an
    -- empty queue: the game's frame shows only the support options' text there) [I]
    if member or #proposed == 0 then
        hide.not_in_community_text = true
    end
    if not member then
        hide.decisions_list = true
    end
    -- the delegate (CAssignOfficialWindow): none assigned, its Select a Leader button only [I: by
    -- the game's frame; the window's code not read]
    hide.assigned_delegate = true
    hide.leader_function = true
    hide.leader_name = true

    -- UpdateMembers: no council positions and no custodian, the large layout
    local large = true
    positions[CW .. "/members_container"] = large and { 940, 340 } or { 940, 400 }
    sizes[CW .. "/members_container"] = large and { 314, 192 } or { 314, 132 }
    sizes[CW .. "/members_container/members_box_container"] = large and { 300, 160 } or { 300, 90 }
    text[CW .. "/members_container/community_text"] = "GALACTIC_COMMUNITY"

    -- the greeting country (UpdateCommunity @2e1c004): the first member with communications, the
    -- first member, else the player
    local greet = player
    if not (#proposed == 0 and member) and #gc.members > 0 then
        greet = gc.members[1]
        for _, m in ipairs(gc.members) do
            local r = data.relations[m]
            if r and r.communications then
                greet = m
                break
            end
        end
    end
    local gcn = data.countries[greet]
    local PG = CW .. "/portrait_greeting_window"
    if gcn then
        text[PG .. "/flag_name"] = ctx.name(gcn.name)
        text[PG .. "/flag_government"] = gcn.government
        if data.player_names[greet] then
            text[PG .. "/flag_personality"] = "§M" .. ctx.fmt("PLAYED_BY", { PLAYER = data.player_names[greet] }) .. "§!"
        else
            text[PG .. "/flag_personality"] = gcn.personality or ""
        end
        ctx.flags[PG .. "/portrait_flag"] = greet
        if not gcn.federation then
            hide.federation_type = true
        end
    end
    text[PG .. "/flag_chat_window/chat_text"] = greet == player and "PROPOSE_RESOLUTION_GREETINGS" or ""

    -- Update: Join or Leave on the Community tab
    text[V .. "/join_leave_button"] = member and "LEAVE" or "JOIN"
    if tab ~= "community" then
        hide.join_leave_button = true
    end

    ctx.layout(FILE, "galactic_community_view", {
        hide = hide, text = text, frames = frames, sizes = sizes, positions = positions,
        actions = {
            [V] = "diplo:none", [V .. "/close"] = "diplo:close",
            [V .. "/tab_community"] = "diplo:tab:community", [V .. "/tab_resolutions"] = "diplo:tab:resolutions",
            [V .. "/tab_senate"] = member and "diplo:tab:senate" or nil,
        },
    })
end

return M
