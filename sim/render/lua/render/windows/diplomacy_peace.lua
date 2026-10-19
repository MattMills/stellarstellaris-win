-- render/windows/diplomacy_peace.lua : a war's exhaustion and its peace offers (the war overview's
-- Offer Peace, COfferPeaceAction), docs/windows/diplomacy.md section 5. Computed from the windows'
-- data (render.windows.diplomacy_data) so the window and the simulation agree:
--
--   local P = require("render.windows.diplomacy_peace")
--   P.stats(war, attacker_side) -> { sum, attrition, ships, armies, static }
--   P.offer(game_dir, data, war, player, option) -> { status, valid, reason, auto, acceptance, reasons }
--   P.format(acceptance) -> the acceptance's text (FormatAIAcceptance)
--   P.apply(game_dir, war_id, player, option) -> a Lua chunk: { ok, accepted, phrase, note, ... }
--     (in the simulation: the offer sent, the recipient's answer, an accepted peace done)

local P = {}

-- the options (CWarOverview's peace options) -> EPeaceOfferStatus: 0 status quo, 1 surrender (the
-- actor gives in), 2 demand (the actor enforces its war goal) [V table @469ccb4]
P.OPTIONS = { "force_demands", "status_quo", "surrender" }
P.STATUS = { force_demands = 2, status_quo = 0, surrender = 1 }

local DEAL_ALWAYS = 1000
-- NGameplay WAR_EXHAUSTION_FROM_UNITS_CUTOFF [V 00_defines.txt]
local CUTOFF = 1.0

local function contains(list, x)
    for _, v in ipairs(list or {}) do
        if v == x then
            return true
        end
    end
    return false
end

local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return -math.floor(-x)
end

local function rounded(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- CWar::CalcCachedWarExhaustion: a side's exhaustion. Attrition is the war's
-- attacker/defender_war_exhaustion; the battles add theirs by type in order until the running total
-- reaches the cutoff (CalcBattleWarExhaustion); occupations add nothing. Not saved: computed.
local PART = { ships = "ships", armies = "armies", static_war_exhaustion = "static" }
function P.stats(w, attacker)
    local attrition = (attacker and w.attacker_war_exhaustion or w.defender_war_exhaustion) or 0
    local s = { attrition = attrition, ships = 0, armies = 0, static = 0 }
    local running = attrition
    for _, b in ipairs(w.battles or {}) do
        if running >= CUTOFF then
            break
        end
        local v = attacker and b.attacker_war_exhaustion or b.defender_war_exhaustion
        local c = math.min(v or 0, math.max(0, CUTOFF - running))
        local f = PART[b.type or ""]
        if f then
            s[f] = s[f] + c
            running = running + c
        end
    end
    s.sum = math.max(0, attrition + s.ships + s.armies + s.static)
    return s
end

-- the war goals' definitions (common/war_goals)
local goals_cache
local function goals(game_dir)
    if not goals_cache then
        goals_cache = require("stellar.script.source").definitions(game_dir, "common/war_goals") or {}
    end
    return goals_cache
end

local function goal_field(game_dir, key, name)
    local d = key and goals(game_dir)[key]
    for _, e in ipairs(d and d.block or {}) do
        if e.op and e.key and e.key.text == name then
            return e.value.text or e.value
        end
    end
    return nil
end
P.goal_field = goal_field

-- a side's naval strength for the peace terms: 100 + the side's countries' fleet power
-- (country +0x2f00 [I: the save's military_power]), at least 1
local function navy(data, side)
    local n = 100
    for _, cid in ipairs(side) do
        local c = data.countries[cid]
        n = n + (c and c.military_power or 0)
    end
    return math.max(n, 1)
end

-- COfferPeaceAction for the option: the actor is the player, the recipient the other side's main
-- participant (CreateOfferPeaceAction @264bf50); its validity (IsProposable), whether it is
-- auto-accepted (IsAutoAccepted @264af50) and the recipient's acceptance (GetAIAcceptance:
-- GetOfferPeaceAcceptance @27f7710 + favors x 5)
function P.offer(game_dir, data, w, player, option)
    local status = P.STATUS[option]
    local attacker = contains(w.attackers, player)
    local recipient = attacker and w.defenders[1] or w.attackers[1]
    local out = { status = status, recipient = recipient, valid = true, reasons = {} }
    -- surrender by an attacker before the defenders set their war goal (SEND_OFFER_NO_DEFENDER_DEMANDS)
    if status == 1 and attacker and not w.have_defender_war_goal then
        out.valid, out.reason = false, "SEND_OFFER_NO_DEFENDER_DEMANDS"
    end
    -- demands need a war goal of ours (CPeaceOffer::IsPossible: the goal type's IsPeaceOfferAllowed)
    -- [I: a side without a goal]
    local ours_goal = w.defender_war_goal
    if attacker then
        ours_goal = w.attacker_war_goal
    end
    if status == 2 and not ours_goal then
        out.valid, out.reason = false, "SEND_OFFER_NO_WAR_GOAL"
    end
    -- the recipient's side: attackers if the recipient attacks
    local r_att = not attacker
    local occupation = 0 -- CalcOccupationPercent [I: not computed here; 0]
    local surrendered = w.defenders_surrendered
    if r_att then
        surrendered = w.attackers_surrendered
    end
    out.auto = status == 1 or surrendered or occupation >= 1
    if out.auto then
        out.acceptance = DEAL_ALWAYS
        return out
    end
    local N = require("render.windows.diplomacy_actions").nai(game_dir)
    local function add(key, v)
        if v ~= 0 then
            out.reasons[#out.reasons + 1] = { key, v }
        end
    end
    local we = P.stats(w, r_att).sum
    if status == 0 then
        add("OFFERING_STATUS_QUO", N.PEACE_STATUS_QUO_FACTOR or -75)
        if we >= 1 then
            add("high_war_exhaustion", N.PEACE_HIGH_WE_STATUS_QUO_FACTOR or 100)
        end
        -- the stalemate term (every participant's AI stale-war flag) [I: not computed]
    elseif status == 2 then
        add("DEMANDING_SURRENDER", N.PEACE_DEMAND_SURRENDER_FACTOR or -100)
        -- the systems demanded but not occupied (DEFENDING_CLAIMS, DEFENDING_PLANET_CLAIMS) [I: not
        -- computed: the goals' claims]
    end
    add("WAR_EXHAUSTION", trunc(we * (N.PEACE_WAR_EXHAUSTION_FACTOR or 100)))
    add("OCCUPATION", trunc(occupation * (N.PEACE_OCCUPATION_FACTOR or 100)))
    local a_side = attacker and w.attackers or w.defenders
    local r_side = attacker and w.defenders or w.attackers
    local ratio = math.max(0.1, math.min(10, navy(data, a_side) / navy(data, r_side)))
    local F = N.PEACE_RELATIVE_NAVY_STRENGTH_FACTOR or 50
    add("RELATIVE_NAVY_STRENGTH", rounded(math.min(F, (ratio - 1) * F)))
    if status == 2 then
        add("WARGOAL", tonumber(goal_field(game_dir, ours_goal, "surrender_acceptance")) or 0)
    end
    local total = 0
    for _, r in ipairs(out.reasons) do
        total = total + r[2]
    end
    -- favors the player holds on the recipient [I: not read here; 0]
    out.acceptance = total
    return out
end

-- FormatAIAcceptance @2800c00: Auto at 1000, else the number green above 0, red otherwise (no sign)
function P.format(acc)
    if acc == DEAL_ALWAYS then
        return "§GAuto§!"
    end
    return "§" .. (acc > 0 and "G" or "R") .. tostring(acc) .. "§!"
end

-- the world's side of a peace, in the simulation ------------------------------------------------

local function copy(block)
    if type(block) ~= "table" then
        return block
    end
    local out = {}
    for k, v in pairs(block) do
        out[k] = type(v) == "table" and copy(v) or v
    end
    return out
end

-- a war goal's effect block (on_accept / on_status_quo) run: ROOT = the goal's actor, FROM = its
-- target [I]
local function run_goal(game_dir, wobj, side_key, name, run)
    local world = require("engine.world")
    local g = world.field(wobj, side_key)
    local key = type(g) == "table" and world.field(g, "type")
    if not key then
        return
    end
    key = tostring(key):gsub('"', "")
    local block = goal_field(game_dir, key, name)
    if type(block) ~= "table" then
        return
    end
    local actor, target = tonumber(world.field(g, "actor")), tonumber(world.field(g, "target"))
    local ok, eval = pcall(require, "simscript.eval")
    if not ok or not eval.effect or not actor or not target then
        run[#run + 1] = key .. "." .. name .. " not run (no script layer)"
        return
    end
    local okr, err = pcall(eval.effect, block, eval.new_ctx(eval.S("country", actor), eval.S("country", target)))
    -- its queued engine effects applied now (simscript.eval.sync), as the game applies them at once
    if eval.sync then pcall(eval.sync) end
    run[#run + 1] = key .. "." .. name .. (okr and "" or (" failed: " .. tostring(err)))
end

local function on_action(name, scope, from, run)
    local ok, eval = pcall(require, "simscript.eval")
    local okev, events = pcall(require, "simscript.events")
    if ok and okev then
        local okr, err = pcall(events.on_action, name, eval.S("country", scope), eval.new_ctx(eval.S("country", from), eval.S("country", scope)))
        -- its queued engine effects applied now (simscript.eval.sync), as the game applies them at once
        if eval.sync then pcall(eval.sync) end
        run[#run + 1] = name .. (okr and "" or (" failed: " .. tostring(err)))
    end
end

-- CWar::OnEnd: a truce between every attacker and defender (CTruce: the war's name, today,
-- truce_type war; each relation's `truce`), the war taken out of the relations' `wars`, on_war_ended,
-- the war removed. The opinion modifier between the main participants [I: its name not read] and the
-- proxy-war and rebel clean-up are not done.
local function end_war(war_id, wobj, w, run)
    local world = require("engine.world")
    local A = require("render.windows.diplomacy_actions")
    local tid = world.next_index("truce")
    local t = {}
    world.create("truce", tid, t)
    local name = world.field(wobj, "name")
    if type(name) == "table" then
        world.append(t, "name", copy(name))
    end
    world.append(t, "start_date", tostring(world.meta and world.meta.date or ""):gsub('"', ""), true)
    world.set(t, "truce_type", "war")
    local everyone = {}
    for _, c in ipairs(w.attackers) do everyone[#everyone + 1] = c end
    for _, c in ipairs(w.defenders) do everyone[#everyone + 1] = c end
    for _, a in ipairs(everyone) do
        for _, b in ipairs(everyone) do
            local r = a ~= b and A.relation(a, b)
            if r then
                local wl = world.field(r, "wars")
                if type(wl) == "table" then
                    world.remove_value(wl, war_id)
                    if #wl == 0 then
                        world.remove_entry(r, world.entry(r, "wars"))
                    end
                end
                if contains(w.attackers, a) ~= contains(w.attackers, b) then
                    world.set(r, "truce", tid)
                end
            end
        end
    end
    on_action("on_war_ended", w.attackers[1], w.defenders[1], run)
    world.remove("war", war_id)
    return tid
end

-- the offer sent (CWarOverview::OnOfferPeaceSendOffer): the recipient (an AI) accepts at above 0
-- (ShouldAIAccept), auto-accepted offers at once. Accepted (CPeaceOffer::AcceptOffer): surrender or
-- demands -> the winner's war goal's on_accept, on_war_won / on_war_lost; status quo -> both goals'
-- on_status_quo and on_status_quo; then the war ends. A status quo refused gives the actor
-- opinion_status_quo_not_accepted towards the recipient [I: its direction].
function P.apply(game_dir, war_id, player, option)
    local world = require("engine.world")
    local D = require("render.windows.diplomacy_data")
    local data = D.load(D.extract(game_dir, player))
    local w = data and data.wars[war_id]
    local wobj = world.object("war", war_id)
    local out = { ok = false }
    if not w or not wobj then
        out.note = "no war " .. tostring(war_id)
        return D.serialize(out)
    end
    local o = P.offer(game_dir, data, w, player, option)
    out.acceptance, out.valid = o.acceptance, o.valid
    local parts = {}
    for _, r in ipairs(o.reasons) do
        parts[#parts + 1] = r[1] .. " " .. r[2]
    end
    out.reasons = table.concat(parts, ", ")
    if not o.valid then
        out.note = "not valid: " .. tostring(o.reason)
        return D.serialize(out)
    end
    local accepted = o.acceptance > 0
    out.accepted = accepted
    out.phrase = require("render.windows.diplomacy_actions").phrase(game_dir, "action_offer_peace",
        accepted and "accept" or "refuse", player, o.recipient)
    local run = {}
    if not accepted then
        if o.status == 0 then
            local oks, systems = pcall(require, "engine.systems")
            if oks and systems.effects and systems.effects.add_opinion_modifier then
                pcall(systems.effects.add_opinion_modifier, { kind = "country", id = player, who = o.recipient, modifier = "opinion_status_quo_not_accepted" })
            end
        end
        out.ok, out.done = true, false
        return D.serialize(out)
    end
    local attacker = contains(w.attackers, player)
    if o.status == 0 then
        run_goal(game_dir, wobj, "attacker_war_goal", "on_status_quo", run)
        run_goal(game_dir, wobj, "defender_war_goal", "on_status_quo", run)
        on_action("on_status_quo", w.attackers[1], w.defenders[1], run)
    else
        local attackers_win = (attacker and o.status == 2) or (not attacker and o.status == 1)
        world.set(wobj, attackers_win and "defenders_surrendered" or "attackers_surrendered", "yes")
        run_goal(game_dir, wobj, attackers_win and "attacker_war_goal" or "defender_war_goal", "on_accept", run)
        local winner = attackers_win and w.attackers[1] or w.defenders[1]
        local loser = attackers_win and w.defenders[1] or w.attackers[1]
        on_action("on_war_won", winner, loser, run)
        on_action("on_war_lost", loser, winner, run)
    end
    out.truce = end_war(war_id, wobj, w, run)
    out.ran = table.concat(run, ", ")
    out.ok, out.done = true, true
    return D.serialize(out)
end

return P
