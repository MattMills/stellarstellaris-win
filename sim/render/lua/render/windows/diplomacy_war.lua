-- render/windows/diplomacy_war.lua : a war's overview (interface/waroverview.gui, CWarOverview),
-- the player's side on the left: docs/windows/diplomacy.md section 5. No save read so far has a
-- war, so this follows the game's code (CWarOverview::Update and its side controllers) without a
-- frame of the game to compare; the battle log and the peace options' AI acceptance are not
-- filled.

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

function M.build(ctx, state)
    local data = ctx.data
    local w = data.wars[state.id]
    local player = data.player
    if not w then
        return
    end
    local attacker = contains(w.attackers, player)
    if not attacker and not contains(w.defenders, player) then
        -- ShowForWarIfPlayerInvolved: the player's wars only [I: ShowForWar itself does not check]
        attacker = true
    end
    local ours = attacker and w.attacker_war_exhaustion or w.defender_war_exhaustion
    local theirs = attacker and w.defender_war_exhaustion or w.attacker_war_exhaustion
    local text, hide, frames = {}, {}, {}
    text[V .. "/war_name"] = ctx.name(w.name)
    text[V .. "/war_start_date"] = ctx.fmt("WAR_STARTED", { DATE = w.start_date or "" })
    -- the sides: left ours (ATTACKERS or DEFENDERS), right theirs
    for _, s in ipairs({ { "left_side", attacker, true, ours }, { "right_side", not attacker, false, theirs } }) do
        local name, is_att, is_ours, we = s[1], s[2], s[3], s[4]
        local P = V .. "/" .. name
        text[P .. "/header"] = is_att and "ATTACKERS" or "DEFENDERS"
        local W = P .. "/war_exhaustion_stats"
        text[W .. "/sum_value"] = M.exhaustion(we, is_ours)
        frames[W .. "/progressbar"] = math.max(1, math.floor(math.min(we, 1) * 100))
        -- the parts of the exhaustion (CWar::CalcWarExhaustionStats) are not in the save [I]
        for _, n in ipairs({ "passive_value", "ships_value", "armies_value", "static_value" }) do
            text[W .. "/" .. n] = ""
        end
        text[P .. "/occupation_stats/occupation_value"] = ""
    end
    -- set_war_goal: ours, defending, with no defender war goal (SetWarGoalIsPotential) [I: the
    -- defender's war goal not read]
    if attacker then
        hide[V .. "/left_side/participants/set_war_goal"] = true
    end
    -- the top bar: d = theirs - ours; left filled to 1 + d, right to d
    local d = theirs - ours
    frames[V .. "/war_exhaustion/progressbar_left"] = math.max(1, math.floor(math.max(0, math.min(1, 1 + d)) * 100))
    frames[V .. "/war_exhaustion/progressbar_right"] = math.max(1, math.floor(math.max(0, math.min(1, d)) * 100))
    if d == 0 then
        hide[V .. "/war_exhaustion/progressbar_marker"] = true
    end
    text[V .. "/war_exhaustion/war_icon/our_war_exhaustion"] = M.exhaustion(ours, true)
    text[V .. "/war_exhaustion/war_icon/their_war_exhaustion"] = M.exhaustion(theirs, false)
    local opponent = attacker and w.defenders[1] or w.attackers[1]
    if opponent then
        ctx.flags[V .. "/war_exhaustion/war_icon/enemy_flag"] = opponent
    end
    -- offer peace: no option selected
    text[V .. "/offer_peace/description"] = "WAROVERVIEW_OFFER_PEACE_SELECT_OPTION"
    for _, o in ipairs({ "force_demands", "status_quo", "surrender" }) do
        hide[V .. "/offer_peace/" .. o .. "/selected"] = true
        text[V .. "/offer_peace/" .. o .. "/ai_acceptance_value"] = ""
    end
    hide.temp_wargoal_ours = true
    hide.temp_wargoal_theirs = true

    local r = ctx.layout(FILE, "waroverview", {
        hide = hide, text = text, frames = frames,
        actions = { [V] = "diplo:none", [V .. "/close"] = "diplo:close" },
    })
    -- the participants (NWarParticipantsList): a waroverview_participant_entry_<side> each
    for _, s in ipairs({ { "left_side", attacker and w.attackers or w.defenders, "left" },
        { "right_side", attacker and w.defenders or w.attackers, "right" } }) do
        local list = r.rects[V .. "/" .. s[1] .. "/participants/list"]
        if list then
            local y = list.y
            for k, cid in ipairs(s[2]) do
                local c = data.countries[cid]
                local entry = "waroverview_participant_entry_" .. s[3]
                local p = "/war/" .. s[3] .. "/" .. k
                if c and y + 40 <= list.y + list.h then
                    local er = ctx.layout(FILE, entry, {
                        prefix = p, parent = { x = list.x, y = y, w = 0, h = 0 },
                        text = { [p .. "/" .. entry .. "/name"] = ctx.name(c.name), [p .. "/" .. entry .. "/type"] = c.government },
                    })
                    ctx.flags[p .. "/" .. entry .. "/flag"] = cid
                    local rect = er.rects[p .. "/" .. entry]
                    y = y + (rect and rect.h > 0 and rect.h or 40)
                end
            end
        end
    end
end

return M
