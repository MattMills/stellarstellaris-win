-- render/windows/diplomacy_actions.lua : the diplomatic actions of a country's diplomacy window
-- (CDiplomacyView::ShowDiplomaticActions, docs/windows/diplomacy.md section 3), run where the world
-- is (the simulation's thread, or the save's runtime): which actions are listed, which are
-- possible, and what proposing one does.
--
--   local A = require("render.windows.diplomacy_actions")
--   A.list(game_dir, actor, recipient) -> a Lua chunk: { { key, title, possible, auto } ... }
--   A.apply(game_dir, key, actor, recipient) -> a Lua chunk: { ok, done, note }
--
-- The list (ShowDiplomaticActions @2cc2560 [V]): common/diplomatic_actions in file order, each
-- action's `is_listed = no` dropped and its `potential` trigger (this = the actor, from = the
-- recipient) holding; the possible ones (`possible`) first, then the others, each group in file
-- order. The game's frame of autosave_2212.07.01 with communications added to the empire 16777223
-- shows this order. Triggers need the script layer (the simulation's runtime): without it every
-- trigger counts as holding [I]. The engine's own checks besides the triggers
-- (CDiplomaticAction::IsPotential / IsPossible) are approximated by the relation's state below
-- [I].

local world = require("engine.world")
local source = require("stellar.script.source")

local A = {}

local FILE = "common/diplomatic_actions/00_actions.txt"

-- the actions, in file order: { key, block }
local actions_cache
local function actions(game_dir)
    if not actions_cache then
        actions_cache = {}
        local tree = source.parse(game_dir, FILE)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                actions_cache[#actions_cache + 1] = { key = e.key.text, block = e.value }
            end
        end
    end
    return actions_cache
end

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a trigger of the action's (this = actor, from = recipient): true, false, or nil without the
-- script layer
local function holds(block, actor, recipient)
    if type(block) ~= "table" then
        return true
    end
    local ok, eval = pcall(require, "simscript.eval")
    if not ok or not eval.trigger or not eval.new_ctx then
        return nil
    end
    local ok2, ctx = pcall(eval.new_ctx, eval.S and eval.S("country", actor) or { kind = "country", id = actor },
        eval.S and eval.S("country", recipient) or { kind = "country", id = recipient })
    if not ok2 then
        return nil
    end
    local ok3, r = pcall(eval.trigger, block, ctx)
    if not ok3 then
        return nil
    end
    return r and true or false
end

local function relation(a, b)
    local c = world.object("country", a)
    local rm = c and world.field(c, "relations_manager")
    for _, r in ipairs(type(rm) == "table" and world.fields(rm, "relation") or {}) do
        if type(r) == "table" and tonumber(world.field(r, "country")) == b then
            return r
        end
    end
    return nil
end

A.relation = relation

local function flag(r, name)
    return r ~= nil and world.field(r, name) == "yes"
end

-- the relation's state an action needs besides its triggers: a pact formed or not, a rivalry, an
-- embassy, closed borders [I: CDiplomaticAction subclasses' IsPotential not read]
local PACTS = {
    defensive_pact = "defensive_pact", non_aggression_pact = "non_aggression_pledge",
    commercial_pact = "commercial_pact", waystation_pact = "waystation_pact",
    research_agreement = "research_agreement", migration_pact = "migration_access",
}
local NONE = 4294967295
local function cref(c, key)
    local v = c and tonumber(world.field(c, key))
    if v == nil or v == NONE then return nil end
    return v
end

-- the countries' standing the engine's checks read: federations, subjects, spy networks,
-- the Galactic Imperium, a primitive recipient
local function standing(actor, recipient)
    local a, r = world.object("country", actor), world.object("country", recipient)
    local s = {
        fed_a = cref(a, "federation"), fed_r = cref(r, "federation"),
        overlord_a = cref(a, "overlord"), overlord_r = cref(r, "overlord"),
        primitive = r ~= nil and tostring(world.field(r, "type") or ""):find("primitive") ~= nil,
    }
    s.same_fed = s.fed_a ~= nil and s.fed_a == s.fed_r
    -- the recipient an AI (an `ai` block, not a human player's country) [I]; the favors the
    -- actor holds on it (the relation's num_favors)
    s.recipient_ai = r ~= nil and type(world.field(r, "ai")) == "table"
    local rel_ar = relation(actor, recipient)
    s.favors = tonumber(rel_ar and world.field(rel_ar, "num_favors")) or 0
    s.actor, s.recipient = actor, recipient
    -- the actor's spy networks (espionage_manager = { spy_networks = { ids } }): one on the
    -- recipient (spy_networks store: target) [I: the store's name]
    s.spy = false
    local em = a and world.field(a, "espionage_manager")
    for _, v in ipairs(world.list(type(em) == "table" and world.field(em, "spy_networks") or nil)) do
        local ok, n = pcall(world.object, "spy_networks", tonumber(v))
        if ok and n and tonumber(world.field(n, "target")) == recipient then
            s.spy = true
        end
    end
    -- the Galactic Imperium (galactic_community `empire`) [I: none in the saves]
    s.empire = false
    return s
end

local function engine_potential(key, ours, s)
    local k = key:gsub("^action_", "")
    -- federations: within the same one (kick, leave, the votes), joining theirs, inviting to ours,
    -- associations with a federation
    if k == "kick_from_federation" or k == "leave_federation" or k == "ask_to_leave_federation" then
        return s.same_fed
    end
    if k == "invite_to_federation" then return s.fed_a ~= nil and not s.same_fed end
    if k == "ask_to_join_federation" then return s.fed_r ~= nil and s.fed_a == nil end
    if k == "offer_federation_association_status" then return s.fed_a ~= nil and not s.same_fed end
    if k == "ask_for_federation_association_status" then return s.fed_r ~= nil and not s.same_fed end
    if k == "revoke_federation_association_status" or k == "end_federation_association_status" then
        return flag(ours, "associate") or false
    end
    -- subjects: of ours (release, integrate, negotiate), we theirs (ask to be released)
    if k == "release_subject" or k == "integrate_subject" or k == "cancel_subject_integration" then
        return s.overlord_r ~= nil and s.overlord_r == s.actor
    end
    if k == "ask_to_be_released_subject" then return s.overlord_a ~= nil and s.overlord_a == s.recipient end
    if k == "negotiate_existing_agreement" then
        return (s.overlord_r == s.actor) or (s.overlord_a == s.recipient)
    end
    if k == "demand_subjugation" or k == "ask_to_become_subjugated" then
        return s.overlord_r ~= s.actor and s.overlord_a ~= s.recipient
    end
    -- the Galactic Imperium's
    if k == "ask_to_join_galactic_empire" or k == "add_imperial_council_member" or k == "remove_imperial_council_member" then
        return s.empire
    end
    -- pacts a federation stands for: not with or as a federation member (the game lists no
    -- defensive pact, non-aggression pact or guarantee for a member of one; the guarantee's own
    -- `exists = alliance` is not read by the engine's script layer yet) [I]
    if k == "form_defensive_pact" or k == "form_non_aggression_pact" or k == "guarantee_independence" then
        if s.fed_a or s.fed_r then return false end
    end
    -- supporting independence: of a subject (of another) [I]
    if k == "support_independence" then return s.overlord_r ~= nil and s.overlord_r ~= s.actor end
    -- spy networks
    if k == "build_spy_network" then return not s.spy end
    if k == "manage_spy_network" then return s.spy end
    -- secret fealty: broken only when pledged
    if k == "break_secret_fealty" or k == "propose_to_break_secret_fealty" then return flag(ours, "secret_fealty") end
    -- a primitive recipient's actions
    if k == "reveal_presence" or k:find("enlightenment") or k:find("pre_ftl") then
        return s.primitive
    end
    local formed = k:match("^form_(.+)$")
    if formed and PACTS[formed] then
        return not flag(ours, PACTS[formed])
    end
    local broken = k:match("^break_(.+)$")
    if broken and PACTS[broken] then
        return flag(ours, PACTS[broken])
    end
    if k == "make_rival" then return not flag(ours, "is_rival") end
    if k == "end_rivalry" then return flag(ours, "is_rival") end
    if k == "embassy" then return not flag(ours, "embassy") end
    if k == "recall_embassy" then return flag(ours, "embassy") end
    if k == "close_borders" then return not flag(ours, "closed_borders") end
    if k == "open_borders" then return flag(ours, "closed_borders") end
    if k == "guarantee_independence" then return not flag(ours, "guarantee") end
    if k == "break_guarantee" then return flag(ours, "guarantee") end
    if k == "support_independence" then return not flag(ours, "support_independence") end
    if k == "break_support" then return flag(ours, "support_independence") end
    local at_war = ours and type(world.field(ours, "wars")) == "table" and #world.list(world.field(ours, "wars")) > 0
    if k == "declare_war" then return not at_war end
    if k == "offer_peace_diplomacy_view" then return at_war end
    return true
end

-- the title's localisation key (CDiplomaticAction::GetTitleTag: the action class's name +
-- "_TITLE"): ACTION_<KEY>_TITLE, the envoys' improve_relations_TITLE and harm_relations_TITLE
function A.title_key(key, loc)
    local k = key:gsub("^action_", "")
    for _, t in ipairs({ ("ACTION_" .. k):upper() .. "_TITLE", k .. "s_TITLE", k .. "_TITLE", ("ACTION_" .. k):upper() }) do
        if not loc or loc.has(t) then
            return t
        end
    end
    -- the class's name is shorter than the key (action_ask_for_federation_association_status:
    -- ACTION_ASK_FOR_FEDERATION_ASSOCIATION_TITLE): its last words dropped in turn
    local words = k
    while words:find("_") do
        words = words:gsub("_[^_]*$", "")
        local t = ("ACTION_" .. words):upper() .. "_TITLE"
        if loc and loc.has(t) then
            return t
        end
    end
    return key
end

-- ---------------------------------------------------------------------------------------------
-- the AI's acceptance (GetAIAcceptance @27f7230, docs/windows/diplomacy.md section 9): the action
-- type's own terms, favors x DIPLO_ACTION_FAVOR_AI_ACCEPTANCE_VALUE, the scripted `ai_acceptance`
-- block (root = recipient, from = actor); accepted above 0 (HasEnoughAIAcceptance)

local DEAL_BREAKER, DEAL_ALWAYS = -1000, 1000

-- the NAI defines (common/defines: the last file's value of a key wins)
local nai_cache
local function nai(game_dir)
    if not nai_cache then
        nai_cache = {}
        for _, f in ipairs(source.files(game_dir, "common/defines", "txt")) do
            for _, top in ipairs(source.parse(game_dir, f) or {}) do
                if top.op and top.key and top.key.text == "NAI" and type(top.value) == "table" then
                    for _, e in ipairs(top.value) do
                        if e.op and e.key and e.value.text then
                            nai_cache[e.key.text] = tonumber(e.value.text)
                        end
                    end
                end
            end
        end
    end
    return nai_cache
end

A.nai = nai

-- definitions of a common/ folder, by name (once)
local def_cache = {}
local function defs_of(game_dir, dir)
    if not def_cache[dir] then
        def_cache[dir] = source.definitions(game_dir, dir) or {}
    end
    return def_cache[dir]
end

local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return -math.floor(-x)
end

local function rounded(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

local function relations_list(id)
    local c = world.object("country", id)
    local rm = c and world.field(c, "relations_manager")
    local out = {}
    for _, r in ipairs(type(rm) == "table" and world.fields(rm, "relation") or {}) do
        if type(r) == "table" then
            local other = tonumber(world.field(r, "country"))
            if other then
                out[other] = r
            end
        end
    end
    return out
end

-- the recipient's AI attitude towards the actor and its behaviour (common/attitudes)
local function behaviour(game_dir, recipient, actor)
    local ok, D = pcall(require, "engine.diplomacy")
    local name = ok and D.attitude(recipient, actor) or "null"
    local d = defs_of(game_dir, "common/attitudes")[tostring(name):gsub('"', "")]
    local b = d and field(d.block, "behaviour")
    local function yes(k)
        return type(b) == "table" and field(b, k) == "yes"
    end
    return { alliance = yes("alliance"), coexist = yes("coexist"), attack = yes("attack"), weaken = yes("weaken") }
end

-- the recipient's opinion of the actor (CalcOurOpinionOfOther: engine.ai.opinion; else the
-- relation's monthly snapshot)
local function opinion_of(recipient, actor)
    local ok, op = pcall(require, "engine.ai.opinion")
    if ok then
        local ok2, v = pcall(op.of, recipient, actor)
        if ok2 and v then
            return v
        end
    end
    local r = relation(recipient, actor)
    return tonumber(r and world.field(r, "relation_current")) or 0
end

-- the recipient's personality's field (common/personalities)
local function personality(game_dir, recipient, key)
    local c = world.object("country", recipient)
    local p = c and tostring(world.field(c, "personality") or ""):gsub('"', "")
    local d = p and defs_of(game_dir, "common/personalities")[p]
    return d and tonumber(field(d.block, key)) or 0
end

-- CCountry::CalcRelativePower(actor, recipient): the powers weighted by RELATIVE_POWER_*_MULT
-- [I: the intel's effect not applied]
local function relative_power(game_dir, a, b)
    local N = nai(game_dir)
    local function power(id)
        local c = world.object("country", id)
        local function f(k) return tonumber(c and world.field(c, k)) or 0 end
        return f("military_power") * (N.RELATIVE_POWER_FLEET_MULT or 2) + f("economy_power") * (N.RELATIVE_POWER_ECONOMY_MULT or 3)
            + f("tech_power") * (N.RELATIVE_POWER_TECH_MULT or 1)
    end
    local pb = power(b)
    if pb <= 0 then
        return 0
    end
    return power(a) / pb
end

-- the countries with a pact (a relation flag) with both a and b; rivals in common [I: rivals
-- of both, either way]
local function shared(a, b, flagname)
    local ra, rb = relations_list(a), relations_list(b)
    local n = 0
    for c, r in pairs(ra) do
        if c ~= b and rb[c] and flag(r, flagname) and flag(rb[c], flagname) then
            n = n + 1
        end
    end
    return n
end
local function shared_rivals(a, b)
    local ra, rb = relations_list(a), relations_list(b)
    local n = 0
    for c, r in pairs(ra) do
        if c ~= b and rb[c] then
            local ta, tb = relations_list(c), nil
            local rival_a = flag(r, "is_rival") or (ta[a] and flag(ta[a], "is_rival"))
            local rival_b = flag(rb[c], "is_rival") or (ta[b] and flag(ta[b], "is_rival"))
            if rival_a and rival_b then
                n = n + 1
            end
        end
    end
    return n
end

-- the pacts the recipient has of a kind (its diplomacy module's counts)
local function count_pacts(id, flagname)
    local n = 0
    for _, r in pairs(relations_list(id)) do
        if flag(r, flagname) then
            n = n + 1
        end
    end
    return n
end

-- GetDistanceScore: 0 when bordering (the relation's `borders`) [I], else the border distance
-- (the relation's border_range [I]) up to 1000, x mult, rounded
local function distance(ours, mult)
    if not ours or flag(ours, "borders") then
        return 0
    end
    local d = tonumber(world.field(ours, "border_range")) or 0
    return rounded(math.min(d, 1000) * mult)
end

-- the largest threat in a country's relations (GetLargestThreat)
local function largest_threat(id)
    local m = 0
    for _, r in pairs(relations_list(id)) do
        m = math.max(m, tonumber(world.field(r, "threat")) or 0)
    end
    return m
end

-- the techs a country has researched (tech_status = { technology = "tech_x" level = 1 ... }) [I:
-- CalcNumTechsNotResearchedBy's second argument not read: every tech counts]
local function techs(id)
    local c = world.object("country", id)
    local out = {}
    local ts = c and world.field(c, "tech_status")
    for _, t in ipairs(type(ts) == "table" and world.fields(ts, "technology") or {}) do
        out[tostring(t):gsub('"', "")] = true
    end
    return out
end

-- the terms one per-type function adds (reasons: { key, value })
local function terms(game_dir, key, def, actor, recipient)
    local N = nai(game_dir)
    local ours = relation(actor, recipient)
    local out = {}
    local function add(reason, v)
        v = trunc(v)
        if v ~= 0 then
            out[#out + 1] = { reason, v }
        end
    end
    local function base()
        add("BASE", tonumber(def and field(def.block, "AI_acceptance_base_value")) or 0)
    end
    local function attitude(prefix)
        local b = behaviour(game_dir, recipient, actor)
        local v
        if b.alliance then
            v = N[prefix .. "_ATTITUDE_ALLIANCE"]
        elseif b.coexist then
            v = N[prefix .. "_ATTITUDE_COEXIST"]
        elseif b.attack or b.weaken then
            v = DEAL_BREAKER
        else
            v = N[prefix .. "_OTHER_ATTITUDE"]
        end
        add("ATTITUDE", v or 0)
    end
    local function opinion(prefix)
        add("OPINION", opinion_of(recipient, actor) * (N[prefix .. "_OPINION_FACTOR"] or 0))
    end
    local function power(prefix)
        local rp = math.max(relative_power(game_dir, actor, recipient), 0)
        add("RELATIVE_POWER_ACCEPTANCE_FACTOR", math.min((rp - 1) * (N[prefix .. "_RELATIVE_STRENGTH_FACTOR"] or 0),
            N[prefix .. "_RELATIVE_STRENGTH_MAX"] or 0))
    end
    local function num_pacts(prefix, flagname, reason)
        if not flag(ours, flagname) then
            add(reason, count_pacts(recipient, flagname) * (N[prefix .. "_NUM_PACTS"] or 0))
        end
    end
    -- (the shared threat: GetSharedThreatFactor not read, 0 here [I])
    local k = key:gsub("^action_", "")
    if k == "embassy" then
        local P = "EMBASSY_ACCEPTANCE"
        base(); attitude(P)
        num_pacts(P, "defensive_pact", "NUM_DEFENSIVE_PACTS")
        opinion(P)
        add("opinion_ally_of_ally", shared(actor, recipient, "defensive_pact") * (N[P .. "_SHARED_ALLY"] or 0))
        add("opinion_mutual_rival", shared_rivals(actor, recipient) * (N[P .. "_SHARED_RIVAL"] or 0))
        power(P)
        add("PERSONALITY", personality(game_dir, recipient, "defensive_pact_acceptance"))
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    elseif k == "form_defensive_pact" then
        local P = "DEFENSIVE_PACT_ACCEPTANCE"
        base(); attitude(P)
        num_pacts(P, "defensive_pact", "NUM_DEFENSIVE_PACTS")
        opinion(P)
        add("opinion_ally_of_ally", shared(actor, recipient, "defensive_pact") * (N[P .. "_SHARED_ALLY"] or 0))
        add("opinion_mutual_rival", shared_rivals(actor, recipient) * (N[P .. "_SHARED_RIVAL"] or 0))
        power(P)
        add("PERSONALITY", personality(game_dir, recipient, "defensive_pact_acceptance"))
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    elseif k == "form_non_aggression_pact" or k == "guarantee_independence" then
        local P = "NON_AGGRESSION_PACT_ACCEPTANCE"
        if k == "guarantee_independence" then
            -- the guarantee's own base, then the whole non-aggression formula with the NAP type's
            -- base [V]
            base()
            for _, a in ipairs(actions(game_dir)) do
                if a.key == "action_form_non_aggression_pact" then
                    add("BASE", tonumber(field(a.block, "AI_acceptance_base_value")) or 0)
                end
            end
        else
            base()
        end
        attitude(P); opinion(P)
        add("opinion_mutual_rival", shared_rivals(actor, recipient) * (N[P .. "_SHARED_RIVAL"] or 0))
        power(P)
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
        add("opinion_ally_of_ally", shared(actor, recipient, "defensive_pact") * (N.DEFENSIVE_PACT_ACCEPTANCE_SHARED_ALLY or 0))
        num_pacts(P, "non_aggression_pledge", "NUM_NON_AGGRESSION_PACTS")
        add("PERSONALITY", personality(game_dir, recipient, "nap_acceptance"))
        if k == "guarantee_independence" then
            local t = largest_threat(recipient)
            if t > 0 then
                add("THREATENED", math.min(rounded(t * (N.VASSALIZATION_ACCEPTANCE_OTHER_THREAT_MULT or 0.2)),
                    N.VASSALIZATION_ACCEPTANCE_OTHER_THREAT_MAX or 20))
            end
        end
    elseif k == "ask_for_federation_association_status" then
        -- GetFederationAssociateAcceptance: BASE and the non-aggression pact's shared block (NAP
        -- defines); then the federation's vote (below)
        local P = "NON_AGGRESSION_PACT_ACCEPTANCE"
        base(); attitude(P); opinion(P)
        add("opinion_mutual_rival", shared_rivals(actor, recipient) * (N[P .. "_SHARED_RIVAL"] or 0))
        power(P)
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    elseif k == "ask_to_join_federation" then
        -- GetAskJoinFederationAcceptance: BASE and GetInviteFederationShared (the recipient judging
        -- the actor) [I: the voted-down modifier, the war philosophy's difference and the crisis
        -- term not read here]; then the federation's vote
        local P = "FEDERATION_ACCEPTANCE"
        base(); attitude(P)
        add("PERSONALITY", personality(game_dir, recipient, "federation_acceptance"))
        opinion(P)
        add("opinion_mutual_rival", shared_rivals(actor, recipient) * (N[P .. "_SHARED_RIVAL"] or 0))
        power(P)
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    elseif k == "form_commercial_pact" then
        local P = "COMMERCIAL_PACT_ACCEPTANCE"
        base(); attitude(P); opinion(P)
        num_pacts(P, "commercial_pact", "NUM_COMMERCIAL_PACTS")
        add("PERSONALITY", personality(game_dir, recipient, "commercial_pact_acceptance"))
        -- the trade given and received (CalcGivenValueForCommercialPacts) [not done here: 0]
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    elseif k == "form_research_agreement" then
        local P = "RESEARCH_AGREEMENT_ACCEPTANCE"
        base(); attitude(P); opinion(P)
        num_pacts(P, "research_agreement", "NUM_RESEARCH_AGREEMENTS")
        local ta, tr = techs(actor), techs(recipient)
        local given, taken = 0, 0
        for t in pairs(tr) do if not ta[t] then given = given + 1 end end
        for t in pairs(ta) do if not tr[t] then taken = taken + 1 end end
        local v = trunc(given * (N[P .. "_GIVEN_TECHS"] or -0.5)) + trunc(taken * (N[P .. "_TAKEN_TECHS"] or -0.5))
        add("RESEARCH_AGREEMENT_TECHS", math.max(N[P .. "_TECHS_MIN"] or -100, math.min(v, N[P .. "_TECHS_MAX"] or 100)))
        add("PERSONALITY", personality(game_dir, recipient, "research_agreement_acceptance"))
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    elseif k == "form_migration_pact" then
        local P = "MIGRATION_PACT_ACCEPTANCE"
        base(); attitude(P)
        if not flag(ours, "migration_access") then
            -- the actor's largest threat (sic) [V]
            add("THREAT_ACCEPTANCE_FACTOR", largest_threat(actor) * (N[P .. "_THREAT_MULT"] or -0.5))
        end
        opinion(P)
        add("PERSONALITY", personality(game_dir, recipient, "migration_pact_acceptance"))
        add("DISTANCE", distance(ours, N[P .. "_DISTANCE_MULT"] or 0))
    else
        return nil
    end
    return out
end

-- the scripted part (GetScriptedAcceptance): the type's ai_acceptance weight (root = recipient,
-- from = actor) [the actor's diplo_action_acceptance_add modifier not read here]
local function scripted(def, actor, recipient)
    local b = def and field(def.block, "ai_acceptance")
    if type(b) ~= "table" then
        return 0
    end
    local ok, eval = pcall(require, "simscript.eval")
    if not ok or not eval.weight then
        return 0
    end
    local ctx = eval.new_ctx(eval.S("country", recipient), eval.S("country", actor))
    local ok2, v = pcall(eval.weight, b, ctx, 0)
    return ok2 and trunc(tonumber(v) or 0) or 0
end

-- A.acceptance(game_dir, key, actor, recipient, favors) -> total (nil: not computed here),
-- reasons
function A.acceptance(game_dir, key, actor, recipient, favors)
    local def
    for _, a in ipairs(actions(game_dir)) do
        if a.key == key then def = a end
    end
    if actor == recipient then
        return DEAL_ALWAYS, {}
    end
    local reasons
    local auto = def and field(def.block, "auto_accepted") == "yes"
    local icon = def and field(def.block, "diplo_view_acceptance_icon") == "yes"
    local total = 0
    if auto and not icon then
        total = DEAL_ALWAYS
        reasons = {}
    else
        reasons = terms(game_dir, key, def, actor, recipient)
        if not reasons then
            return nil, {}
        end
        for _, r in ipairs(reasons) do
            total = total + r[2]
        end
    end
    if (favors or 0) > 0 then
        local f = favors * (nai(game_dir).DIPLO_ACTION_FAVOR_AI_ACCEPTANCE_VALUE or 5)
        reasons[#reasons + 1] = { "FAVORS", f }
        total = total + f
    end
    local s = scripted(def, actor, recipient)
    if s ~= 0 then
        reasons[#reasons + 1] = { "ai_acceptance", s }
        total = total + s
    end
    -- the federation's vote (requires_alliance_vote or requires_recipient_alliance_vote): 1 or 0;
    -- with the recipient its federation's leader no other member votes [V], so the recipient's
    -- own acceptance decides [I: other members' votes not computed]
    if def and (field(def.block, "requires_recipient_alliance_vote") == "yes" or field(def.block, "requires_alliance_vote") == "yes") then
        return (total > 0 or auto) and 1 or 0, reasons
    end
    if auto then
        return DEAL_ALWAYS, reasons
    end
    return total, reasons
end

-- the recipient's reply (GenerateActionText: common/diplo_phrases' `<action> = { accept|refuse
-- = { KEY = { trigger } } }`, root = recipient, from = actor): the first phrase whose trigger
-- holds [I: the game picks a weighted random one with the action's seed]
local phrases_cache
function A.phrase(game_dir, key, kind, actor, recipient)
    if not phrases_cache then
        phrases_cache = {}
        for _, f in ipairs(source.files(game_dir, "common/diplo_phrases", "txt")) do
            for _, top in ipairs(source.parse(game_dir, f) or {}) do
                if top.op and top.key and type(top.value) == "table" and not phrases_cache[top.key.text] then
                    phrases_cache[top.key.text] = top.value
                end
            end
        end
    end
    local cat = phrases_cache[key] and field(phrases_cache[key], kind)
    if type(cat) ~= "table" then
        return nil
    end
    for _, e in ipairs(cat) do
        if e.op and e.key and type(e.value) == "table" then
            if holds(field(e.value, "trigger"), recipient, actor) ~= false then
                return e.key.text
            end
        end
    end
    return nil
end

function A.list(game_dir, actor, recipient)
    local ours = relation(actor, recipient)
    local s = standing(actor, recipient)
    local possible, impossible = {}, {}
    local scripted = true
    for _, a in ipairs(actions(game_dir)) do
        if field(a.block, "is_listed") ~= "no" then
            local pot = holds(field(a.block, "potential"), actor, recipient)
            if pot == nil then
                scripted = false
            end
            if pot ~= false and engine_potential(a.key, ours, s) then
                -- possible: its `possible` and `proposable` triggers [I: the game's group of the
                -- possible ones matches both in its frame]
                local pos = holds(field(a.block, "possible"), actor, recipient)
                if pos ~= false then
                    pos = holds(field(a.block, "proposable"), actor, recipient)
                end
                local e = { key = a.key, auto = field(a.block, "auto_accepted") == "yes", possible = pos ~= false,
                    icon = type(field(a.block, "icon")) == "string" and (field(a.block, "icon"):gsub('"', "")) or nil }
                -- the AI's acceptance icon (CDiploActionEntry: PreviewAcceptanceIcon, an AI
                -- recipient): frame 2 accepts, 3 accepts with the favors we hold, 1 refuses
                if field(a.block, "diplo_view_acceptance_icon") == "yes" and s.recipient_ai then
                    local total = A.acceptance(game_dir, a.key, actor, recipient, 0)
                    if total then
                        local with = A.acceptance(game_dir, a.key, actor, recipient, s.favors)
                        e.acceptance = total
                        e.icon_frame = total > 0 and 2 or ((with or 0) > 0 and 3 or 1)
                    end
                end
                if e.possible then
                    possible[#possible + 1] = e
                else
                    impossible[#impossible + 1] = e
                end
            end
        end
    end
    for _, e in ipairs(impossible) do
        possible[#possible + 1] = e
    end
    possible.scripted = scripted
    return require("render.windows.diplomacy_data").serialize(possible)
end

-- the relation's flag set or removed (`name = yes`), on one side
local function set_flag(r, name, on)
    if not r then
        return false
    end
    if on then
        world.set(r, name, "yes")
    else
        local e = world.entry(r, name)
        if e then
            world.remove_entry(r, e)
        end
    end
    return true
end

-- what an action does once accepted (the CDiplomaticAction subclasses' ExecuteAccept,
-- docs/windows/diplomacy.md section 9): an AI recipient decides by its acceptance (> 0); the
-- accepted pacts set on both sides (a defensive pact clears a non-aggression pact and a
-- guarantee both ways), a guarantee, borders and rivalries on the actor's side; the on_accept
-- effects and on_sign_* on_actions are not run here
function A.apply(game_dir, key, actor, recipient)
    local ours, theirs = relation(actor, recipient), relation(recipient, actor)
    local def
    for _, a in ipairs(actions(game_dir)) do
        if a.key == key then
            def = a
        end
    end
    local out = { ok = false }
    local k = key:gsub("^action_", "")
    local auto = def and field(def.block, "auto_accepted") == "yes"
    local broken = k:match("^break_(.+)$")
    local formed = k:match("^form_(.+)$")
    -- the recipient's answer (ShouldAIAccept: GetAIAcceptance > 0) for what is not auto-accepted
    local accepted = auto
    if not auto then
        local total, reasons = A.acceptance(game_dir, key, actor, recipient, 0)
        out.total = total
        if total == nil then
            out.note = "the AI's acceptance of " .. key .. " is not computed here"
            out.done = false
            return require("render.windows.diplomacy_data").serialize(out)
        end
        accepted = total > 0
        local parts = {}
        for _, r in ipairs(reasons) do
            parts[#parts + 1] = r[1] .. " " .. r[2]
        end
        out.reasons = table.concat(parts, ", ")
    end
    out.accepted = accepted
    out.phrase = A.phrase(game_dir, key, accepted and "accept" or "refuse", actor, recipient)
    if not accepted then
        out.ok, out.done = true, false
        return require("render.windows.diplomacy_data").serialize(out)
    end
    if formed and PACTS[formed] then
        out.ok = set_flag(ours, PACTS[formed], true) and set_flag(theirs, PACTS[formed], true)
        if formed == "defensive_pact" then
            set_flag(ours, "non_aggression_pledge", false); set_flag(theirs, "non_aggression_pledge", false)
            set_flag(ours, "guarantee", false); set_flag(theirs, "guarantee", false)
        end
    elseif k == "embassy" then
        out.ok = set_flag(ours, "embassy", true) and set_flag(theirs, "embassy", true)
    elseif k == "guarantee_independence" then
        out.ok = set_flag(ours, "guarantee", true)
    elseif k == "close_borders" then
        out.ok = set_flag(ours, "closed_borders", true)
    elseif k == "open_borders" then
        out.ok = set_flag(ours, "closed_borders", false)
    elseif k == "make_rival" then
        out.ok = set_flag(ours, "is_rival", true)
        if ours then
            local today = world.meta and world.meta.date
            if today then world.set(ours, "rival_date", today) end
        end
    elseif k == "end_rivalry" then
        out.ok = set_flag(ours, "is_rival", false)
    elseif k == "recall_embassy" then
        out.ok = set_flag(ours, "embassy", false)
    elseif broken and PACTS[broken] then
        -- a pact ends on both sides
        out.ok = set_flag(ours, PACTS[broken], false) and set_flag(theirs, PACTS[broken], false)
    elseif k == "insult" then
        -- CInsultAction: the recipient's opinion of the actor gets opinion_insult (the engine's
        -- add_opinion_modifier; the actor's insult efficiency multiplier not applied [I])
        local okc = pcall(require, "engine.script.creation")
        local oks, systems = pcall(require, "engine.systems")
        if okc and oks and systems.effects and systems.effects.add_opinion_modifier then
            out.ok = pcall(systems.effects.add_opinion_modifier, { kind = "country", id = recipient, who = actor, modifier = "opinion_insult" })
        else
            out.note = "the engine's add_opinion_modifier is not loaded"
        end
    else
        out.note = "accepted; its effect (" .. key .. ") is not done here"
    end
    -- the pacts' on_actions (ROOT = recipient, FROM = actor), then CDiplomaticAction::ExecuteAccept:
    -- the type's on_accept effect (ROOT = actor, FROM = recipient), through the script layer
    local SIGN = { commercial_pact = "on_sign_commercial_pact", defensive_pact = "on_sign_defensive_pact",
        non_aggression_pact = "on_sign_non_aggression_pact", research_agreement = "on_sign_research_pact",
        migration_pact = "on_sign_migration_pact" }
    local ok, eval = pcall(require, "simscript.eval")
    if ok and eval.effect then
        local run = {}
        if formed and SIGN[formed] then
            local okev, events = pcall(require, "simscript.events")
            if okev then
                local okr, err = pcall(events.on_action, SIGN[formed], eval.S("country", recipient),
                    eval.new_ctx(eval.S("country", actor), eval.S("country", recipient)))
                if eval.sync then pcall(eval.sync) end
                run[#run + 1] = SIGN[formed] .. (okr and "" or (" failed: " .. tostring(err)))
            end
        end
        local oa = def and field(def.block, "on_accept")
        if type(oa) == "table" then
            local okr, err = pcall(eval.effect, oa, eval.new_ctx(eval.S("country", actor), eval.S("country", recipient)))
            -- its queued engine effects applied now (simscript.eval.sync), as the game applies them at once
            if eval.sync then pcall(eval.sync) end
            run[#run + 1] = "on_accept" .. (okr and "" or (" failed: " .. tostring(err)))
        end
        if #run > 0 then
            out.reasons = ((out.reasons and out.reasons ~= "") and (out.reasons .. "; ") or "") .. "ran " .. table.concat(run, ", ")
        end
    end
    out.done = out.ok
    return require("render.windows.diplomacy_data").serialize(out)
end

return A
