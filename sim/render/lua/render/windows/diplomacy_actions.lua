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

-- what an action does once accepted (the engine's CDiplomaticAction subclasses' effects [I: their
-- code not read]): the relation flags of the auto-accepted actions; the others need the AI's
-- acceptance, which the engine does not compute yet
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
    if k == "close_borders" then
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
    elseif auto then
        out.note = "auto-accepted; its effect is not done here"
    else
        out.note = "needs the recipient's acceptance (the AI's acceptance is not computed here)"
    end
    out.done = out.ok
    return require("render.windows.diplomacy_data").serialize(out)
end

return A
