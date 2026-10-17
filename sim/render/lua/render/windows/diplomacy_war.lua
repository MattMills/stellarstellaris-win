-- render/windows/diplomacy_war.lua : a war's overview (interface/waroverview.gui, CWarOverview),
-- the player's side on the left: docs/windows/diplomacy.md section 5. Laid out as CWarOverview::Update
-- and its side controllers do; the exhaustion and the peace offers' acceptance are
-- render.windows.diplomacy_peace's. The battle log is not filled.

local M = {}

local FILE = "interface/waroverview.gui"
local V = "/waroverview"

-- NWar::GetFormattedWarExhaustion: the whole percent, green or red by side under 30 %, yellow to
-- 70 %, red or green above
function M.exhaustion(v, ours)
    local c
    if v < 0.30 then
        c = ours and "G" or "R"
    elseif v < 0.70 then
        c = "Y"
    else
        c = ours and "R" or "G"
    end
    return "§" .. c .. string.format("%d%%", math.floor(v * 100 + 0.5)) .. "§!"
end

local function contains(list, x)
    for _, v in ipairs(list or {}) do
        if v == x then
            return true
        end
    end
    return false
end

-- NWar::ApplyCallerTypeToButton @2153d60: a participant's icon by how it was called in (the main
-- participant none; an overlord's the subject preset's [I: not read; the vassal icon])
local CALL_ICON = {
    alliance = "GFX_diplomacy_status_federation", subject = "GFX_diplomacy_status_has_vassal",
    overlord = "GFX_diplomacy_status_has_vassal", guarantee = "GFX_diplomacy_status_guarantee",
    free = "GFX_diplomacy_status_support_independence", defensive = "GFX_diplomacy_status_defensive_pact",
    offensive = "GFX_diplomacy_status_trade", galactic_empire = "GFX_diplomacy_status_galactic_empire",
    secret_fealty = "GFX_diplomacy_status_secret_fealty", trade_deal = "GFX_diplomacy_status_trade_war_ally",
}

local LABEL = { force_demands = "WAROVERVIEW_FORCE_DEMANDS", status_quo = "WAROVERVIEW_STATUS_QUO",
    surrender = "WAROVERVIEW_SURRENDER" }

-- GreyOutTextIfDisabled: the text's colours taken out and the whole greyed
local function grey(ctx, s)
    s = ctx.loc and ctx.loc.has(s) and ctx.loc.get(s) or s
    return "§g" .. s:gsub("§.", "") .. "§!"
end

function M.build(ctx, state)
    local data = ctx.data
    local w = data.wars[state.id]
    local player = data.player
    if not w then
        return
    end
    local P = require("render.windows.diplomacy_peace")
    local attacker = contains(w.attackers, player)
    if not attacker and not contains(w.defenders, player) then
        -- ShowForWarIfPlayerInvolved: the player's wars only [I: ShowForWar itself does not check]
        attacker = true
    end
    local our_stats, their_stats = P.stats(w, attacker), P.stats(w, not attacker)
    local ours, theirs = our_stats.sum, their_stats.sum
    local text, hide, frames, sizes, progress, sprites, disabled = {}, {}, {}, {}, {}, {}, {}
    text[V .. "/war_name"] = ctx.name(w.name)
    text[V .. "/war_start_date"] = ctx.fmt("WAR_STARTED", { DATE = w.start_date or "" })
    -- set_war_goal: the defenders' button while they have no war goal (SetWarGoalIsPotential) [I]
    local set_goal = not attacker and not w.have_defender_war_goal
    if not set_goal then
        hide[V .. "/left_side/participants/set_war_goal"] = true
    end
    -- the sides: left ours (ATTACKERS or DEFENDERS), right theirs; the exhaustion's parts
    -- (CalcWarExhaustionStats) and the occupation [I: not computed: 0]
    for _, s in ipairs({ { "left_side", attacker, true, our_stats }, { "right_side", not attacker, false, their_stats } }) do
        local name, is_att, is_ours, st = s[1], s[2], s[3], s[4]
        local S = V .. "/" .. name
        text[S .. "/header"] = is_att and "ATTACKERS" or "DEFENDERS"
        local W = S .. "/war_exhaustion_stats"
        text[W .. "/sum_value"] = M.exhaustion(st.sum, is_ours)
        progress[W .. "/progressbar"] = math.min(1, st.sum)
        text[W .. "/passive_value"] = M.exhaustion(st.attrition, is_ours)
        text[W .. "/ships_value"] = M.exhaustion(st.ships, is_ours)
        text[W .. "/armies_value"] = M.exhaustion(st.armies, is_ours)
        text[W .. "/static_value"] = M.exhaustion(st.static, is_ours)
        text[S .. "/occupation_stats/occupation_value"] = M.exhaustion(0, is_ours)
        progress[S .. "/occupation_stats/progressbar"] = 0
        -- the participants' list (NWarParticipantsList::UpdateList): its size from the
        -- positionType with or without the Set War Goal button
        sizes[S .. "/participants/list"] = (is_ours and set_goal) and { 305, 155 } or { 305, 194 }
    end
    -- the top bar: d = theirs - ours; left filled to 1 + d, right to d (green up to the state on
    -- the left, red on the right)
    local d = theirs - ours
    progress[V .. "/war_exhaustion/progressbar_left"] = math.max(0, math.min(1, 1 + d))
    progress[V .. "/war_exhaustion/progressbar_right"] = math.max(0, math.min(1, d))
    text[V .. "/war_exhaustion/war_icon/our_war_exhaustion"] = M.exhaustion(ours, true)
    text[V .. "/war_exhaustion/war_icon/their_war_exhaustion"] = M.exhaustion(theirs, false)
    local opponent = attacker and w.defenders[1] or w.attackers[1]
    if opponent then
        ctx.flags[V .. "/war_exhaustion/war_icon/enemy_flag"] = opponent
    end

    -- offer peace (CWarOverviewOfferPeaceOptionController::Update): each option valid or greyed,
    -- its acceptance, the war goal's icon (ours to achieve, theirs to surrender to; none keeps the
    -- gui's), the one selected
    local O = V .. "/offer_peace"
    local our_goal, their_goal = w.defender_war_goal, w.attacker_war_goal
    if attacker then
        our_goal, their_goal = w.attacker_war_goal, w.defender_war_goal
    end
    local selected = state.action
    local send_valid = false
    for _, opt in ipairs(P.OPTIONS) do
        local o = P.offer(ctx.game_dir, data, w, player, opt)
        local B = O .. "/" .. opt
        if not (o.valid and selected == opt) then
            hide[B .. "/selected"] = true
        end
        local value = P.format(o.acceptance)
        if o.valid then
            text[B .. "/ai_acceptance_value"] = value
        else
            text[B .. "/label"] = grey(ctx, LABEL[opt])
            text[B .. "/ai_acceptance_value"] = grey(ctx, value)
            disabled[B .. "/background"] = true
            disabled[B .. "/ai_acceptance_icon"] = true
            disabled[B .. "/war_goal_icon"] = true
        end
        frames[B .. "/ai_acceptance_icon"] = o.acceptance > 0 and 2 or 1
        -- CWarGoalType::GetIcon: "GFX_" and the type's icon key [I: the type's own key when it has
        -- none, as GFX_wg_subjugation]
        local g = opt == "force_demands" and our_goal or (opt == "surrender" and their_goal or nil)
        if g then
            sprites[B .. "/war_goal_icon"] = "GFX_" .. (P.goal_field(ctx.game_dir, g, "icon") or g)
        end
        if opt == selected and o.valid then
            send_valid = true
        end
    end
    text[O .. "/description"] = (selected and send_valid) and (LABEL[selected] .. "_DESC")
        or "WAROVERVIEW_OFFER_PEACE_SELECT_OPTION"
    if not send_valid then
        disabled[O .. "/send"] = true
    end
    -- the war goals' names (CWarGoalType::GetName: war_goal_<type>)
    text[O .. "/temp_wargoal_ours"] = our_goal and ("war_goal_" .. our_goal) or ""
    text[O .. "/temp_wargoal_theirs"] = their_goal and ("war_goal_" .. their_goal) or ""

    local actions = { [V] = "diplo:none", [V .. "/close"] = "diplo:close" }
    for _, opt in ipairs(P.OPTIONS) do
        actions[O .. "/" .. opt .. "/background"] = "diplo:peace:" .. opt
    end
    if send_valid then
        actions[O .. "/send"] = "diplo:peace_send"
    end
    local r = ctx.layout(FILE, "waroverview", {
        hide = hide, text = text, frames = frames, sizes = sizes, progress = progress, sprites = sprites,
        disabled = disabled, actions = actions,
    })
    -- the participants (NWarParticipantsList::CEntry): a waroverview_participant_entry_<side> each,
    -- 38 high, in the save's order; the frame never shown, the flag and name the country's, the
    -- type icon by its call type
    for _, s in ipairs({ { "left_side", attacker and w.attackers or w.defenders, "left" },
        { "right_side", attacker and w.defenders or w.attackers, "right" } }) do
        local list = r.rects[V .. "/" .. s[1] .. "/participants/list"]
        if list then
            local y = list.y
            for k, cid in ipairs(s[2]) do
                local c = data.countries[cid]
                local entry = "waroverview_participant_entry_" .. s[3]
                local p = "/war/" .. s[3] .. "/" .. k
                local E = p .. "/" .. entry
                if c and y + 38 <= list.y + list.h then
                    local call = w.calls and w.calls[cid] or {}
                    local icon = CALL_ICON[call.type or ""]
                    ctx.layout(FILE, entry, {
                        prefix = p, parent = { x = list.x, y = y, w = 0, h = 0 },
                        text = { [E .. "/name"] = ctx.name(c.name) },
                        hide = { [E .. "/frame"] = true, [E .. "/type"] = not icon or nil },
                        sprites = icon and { [E .. "/type"] = icon } or nil,
                        actions = { [E .. "/flag"] = "diplo:country:" .. cid, [E .. "/background"] = "diplo:none" },
                    })
                    ctx.flags[E .. "/flag"] = cid
                    y = y + 38
                end
            end
        end
    end
end

return M
