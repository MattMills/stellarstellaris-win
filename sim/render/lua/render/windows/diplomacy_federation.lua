-- render/windows/diplomacy_federation.lua : the player's federation (interface/
-- federation_view.gui, CFederationView): docs/windows/diplomacy.md section 4. The game shows it
-- only for the observed country's federation (CFederationView::Update hides the window without
-- one), on the Levels tab first. The tabs' lists (levels, members, fleets, laws) are not filled.

local M = {}

local FILE = "interface/federation_view.gui"
local V = "/federation_view"

local TABS = { "levels", "members", "fleets", "laws" }

function M.build(ctx, state)
    local data = ctx.data
    local pc = data.countries[data.player]
    -- the player's federation (the window's argument is the game's only: the observed country's)
    local fid = pc and pc.federation
    local f = fid and data.federations[fid]
    if not f then
        return
    end
    local tab = state.tab or "levels"
    local hide, text = {}, {}
    for _, t in ipairs(TABS) do
        -- UpdateTabVisibility; SwitchToTab: Levels shows levels_window, the others the cohesion
        -- header and their own window
        hide["tab_" .. t] = t == tab or nil
        hide["tab_" .. t .. "_active"] = t ~= tab or nil
        hide[t .. "_window"] = t ~= tab or nil
    end
    hide.level_cohesion_window = tab == "levels" or nil
    -- UpdateGeneralInfo
    text[V .. "/federation_name"] = ctx.name(f.name)
    text[V .. "/federation_type"] = ctx.fmt("FEDERATION_VIEW_TYPE", { TYPE = ctx.loc and ctx.loc.get(f.type or "") or f.type })
    text[V .. "/federation_type_desc"] = (f.type or "") .. "_desc"
    text[V .. "/federation_formed"] = ctx.fmt("FEDERATION_VIEW_DATE", { DATE = f.start_date or "" })
    -- the leave button: Ask to Leave when not its leader and the leader decides [I: the action's
    -- acceptance type not read], else Leave Federation
    text[V .. "/leave_federation_button"] = f.leader ~= data.player and "ASK_TO_LEAVE_FEDERATION" or "FEDERATION_VIEW_LEAVE_FEDERATION"
    ctx.flags[V .. "/levels_window/leader"] = f.leader
    hide.portrait_window = true
    local actions = { [V] = "diplo:none", [V .. "/close"] = "diplo:close" }
    for _, t in ipairs(TABS) do
        actions[V .. "/tab_" .. t] = "diplo:tab:" .. t
    end
    ctx.layout(FILE, "federation_view", { hide = hide, text = text, actions = actions })
end

return M
