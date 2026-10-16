-- engine/script/objects_leaders.lua : leaders and policies made by script (create_leader,
-- set_leader / assign_leader, set_policy, add_council_agenda_progress) and a new country's
-- starting policies, from the 4.5.2 Linux build (docs/script_objects.md "Leaders", "Policies").
--
-- A leader in the save's form (the 2200.01.11 save's leaders):
--   { name = { full_names = { key = "%LEADER_2%" variables = { { key = "1" value = { key } } ... } }
--     use_full_regnal_name = yes } species portrait gender country creator class tier location date
--     recruitment_date age job ethic background_planet = { type = planet reference } traits level
--     bonus_skill_level }

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")
local objects = require("engine.script.objects")

local applied, skipped, unq, NO_ID = objects.applied, objects.skipped, objects.unq, objects.NO_ID
local draw = objects.draw

local leaders = {}
objects.leaders = leaders

local function today_text()
    local eval = package.loaded["simscript.eval"]
    local d = eval and eval.today and eval.today() or 0
    local y = math.floor(d / 360)
    local m = math.floor((d % 360) / 30) + 1
    local dd = d % 30 + 1
    return string.format("%d.%02d.%02d", y, m, dd)
end
leaders.today_text = today_text

local function list_names(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then out[#out + 1] = unq(e.text) end
    end
    return out
end

-- GetFixedPointForMacro: one draw, draw % 100000 (a CFixedPoint in [0, 1))
local function draw_fp()
    return draw() % 100000
end

-- GetWeightedRandom over integer weights (0x4274730): r = draw % total, the first weight whose
-- running sum is above r
local function weighted(weights)
    local total = 0
    for _, w in ipairs(weights) do if w > 0 then total = total + w end end
    if total <= 0 then return nil end
    local r = draw() % total
    local cum = 0
    for i, w in ipairs(weights) do
        if w > 0 then
            cum = cum + w
            if cum > r then return i end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- names (CNameListManager::TakeRandomCharacterName 0x1dc1140, CNameListCharacter::GetRandomName
-- 0x1dbba90, CNameListCulture::GetRandomName 0x1dbaae0) [V]

local GENDER_SUFFIX = { [0] = "_male", [1] = "_female" }

-- the three gender lists of a kind (`full_names`, `first_names`, `second_names`, `regnal_*`) of a
-- name set: { male, female, neutral }
local function gender_lists(set, kind)
    return {
        list_names(defs.field(set, kind .. "_male")),
        list_names(defs.field(set, kind .. "_female")),
        list_names(defs.field(set, kind)),
    }
end
local function has_names(l, g)
    if #l[3] > 0 then return true end
    if g == 0 then return #l[1] > 0 end
    if g == 1 then return #l[2] > 0 end
    return #l[1] > 0 or #l[2] > 0
end
-- one name of a kind's lists for a gender: indeterminable picks a list (a draw over the non-empty
-- ones, weight 100000 each); else the gender's, or the neutral one; then draw % count
local function pick(l, g)
    local idx
    if g == 2 then
        idx = weighted({ #l[1] > 0 and 100000 or 0, #l[2] > 0 and 100000 or 0, #l[3] > 0 and 100000 or 0 })
    else
        idx = (#l[g + 1] > 0) and (g + 1) or ((#l[3] > 0) and 3 or nil)
    end
    local list = idx and l[idx]
    if not list or #list == 0 then return nil end
    return list[draw() % #list + 1]
end

local function key_block(key)
    local b = {}
    world.append(b, "key", key, true)
    return b
end

-- a name: the set by weight (one fixed-point draw), full or first + second (a coin when all three
-- kinds exist), the names drawn -> the save's name block
function leaders.random_name(list_key, g)
    local nl = defs.get("common/name_lists", list_key or "")
    local cn = nl and defs.field(nl.block, "character_names")
    if type(cn) ~= "table" then return nil end
    local sets, total = {}, 0
    for _, e in ipairs(cn) do
        if e.op and e.key and e.value.text == nil then
            local w = tonumber(defs.field(e.value, "weight")) or 1
            sets[#sets + 1] = { e.value, w }
            total = total + w
        end
    end
    if #sets == 0 then return nil end
    local fp = draw_fp()
    local set = sets[#sets][1]
    local cum = 0
    for _, s in ipairs(sets) do
        cum = cum + s[2]
        if fp * total < cum * 100000 then set = s[1] break end
    end
    local full, first, second = gender_lists(set, "full_names"), gender_lists(set, "first_names"), gender_lists(set, "second_names")
    local hf, h1, h2 = has_names(full, g), has_names(first, g), has_names(second, g)
    local use_full
    if hf and h1 and h2 then
        use_full = draw() % 2 == 0
    else
        use_full = hf
    end
    local name = {}
    local fn
    if use_full then
        local k = pick(full, g)
        fn = key_block(k or "")
    else
        local a, b = pick(first, g), pick(second, g)
        fn = {}
        world.append(fn, "key", "%LEADER_2%", true)
        local v1, v2 = {}, {}
        world.append(v1, "key", "1", true)
        world.append(v1, "value", key_block(a or ""))
        world.append(v2, "key", "2", true)
        world.append(v2, "value", key_block(b or ""))
        world.append(fn, "variables", { v1, v2 })
    end
    world.append(name, "full_names", fn)
    world.append(name, "use_full_regnal_name", "yes")
    return name
end

-- ---------------------------------------------------------------------------------------------
-- leaders

local function species_field(sid, key)
    local s = sid and world.object("species_db", sid)
    return s and world.field(s, key)
end

local function country_ethics(country)
    local c = world.object("country", country)
    local out = {}
    for _, e in ipairs(world.list(c and world.path(c, "ethos", "ethics"))) do out[#out + 1] = unq(e) end
    return out
end

-- the leader classes in database order
local function classes()
    local out = {}
    for _, d in ipairs(objects.ordered("common/leader_classes")) do out[#out + 1] = d[1] end
    return out
end

local function append_owned(country, lid)
    local c = world.object("country", country)
    if not c then return end
    world.append_value(objects.list_of(c, "owned_leaders"), lid)
    local l = world.leaders_of[country]
    if not l then l = {}; world.leaders_of[country] = l end
    l[#l + 1] = lid
end

-- the leader's traits: `traits = { N = <trait> }` added when N <= its level (random_* adders are
-- not ported) [I]
local function add_traits(b, traits, level)
    for _, t in ipairs(traits or {}) do
        local n, key = t[1], t[2]
        if (n or 0) <= level and key and not key:match("^random") and defs.get("common/traits", key) then
            world.append(b, "traits", key, true)
        end
    end
end

-- leaders.create(t) -> leader id: anon::CreateLeader (0x36d32a0), its draws in the game's order:
-- the class (a draw when not given), the ethic (a draw over the country's ethics: RandomizeBackground
-- needs the jobs, not ported [I]), the gender (a draw when the species has both), the name (twice:
-- Initialize and SetupLeaderFromData), the first level-up (two draws, on_leader_level_up), the age
-- (two fixed-point draws, triangular between LEADER_AGE_MIN and MAX), the owned leader, then
-- OnSpawned (two draws, on_leader_spawned)
function leaders.create(t)
    local country = t.country
    local c = world.object("country", country)
    if not c then return nil end
    local class = t.class
    if not class or not defs.get("common/leader_classes", class) then
        local cl = classes()
        if #cl == 0 then return nil end
        class = cl[draw() % #cl + 1]
    end
    local sid = t.species or objects.ref(world.field(c, "founder_species_ref"))
    -- Initialize: the ethic (no background: the country's ethics, its regular variant)
    local ethic
    if not t.skip_background then
        local eth = country_ethics(country)
        if #eth > 0 then
            ethic = eth[draw() % #eth + 1]:gsub("^ethic_fanatic_", "ethic_")
        end
    end
    local gender = t.gender
    local sg = unq(species_field(sid, "gender"))
    local g
    if gender == "male" then g = 0 elseif gender == "female" then g = 1 elseif gender == "indeterminable" then g = 2 end
    local gdraw
    if sg == "indeterminable" then gdraw = 2 else gdraw = draw() % 2 end
    g = g or gdraw
    local list = unq(species_field(sid, "name_list")) or unq(world.field(c, "name_list"))
    local name = t.name
    if not name then
        leaders.random_name(list, g)
        name = leaders.random_name(list, g)
    end
    local b = {}
    world.append(b, "name", name or key_block(""))
    if sid then world.append(b, "species", sid) end
    local portrait = species_field(sid, "portrait")
    if portrait then world.append(b, "portrait", unq(portrait), true) end
    if g == 0 then world.append(b, "gender", "male") elseif g == 1 then world.append(b, "gender", "female") end
    world.append(b, "country", country)
    world.append(b, "creator", country)
    world.append(b, "class", class, true)
    world.append(b, "tier", "leader_tier_default", true)
    local date = today_text()
    world.append(b, "date", date, true)
    world.append(b, "recruitment_date", date, true)
    -- the age: (fp1 + fp2) / 2 of the range, truncated, over LEADER_AGE_MIN..MAX (25..45) [V]
    local lo, hi = 25, 45
    local r = (draw_fp() + draw_fp()) / 2
    local age = t.age or (math.floor((hi - lo) * r / 100000) + lo)
    world.append(b, "age", age)
    if ethic then world.append(b, "ethic", ethic, true) end
    local cap = objects.ref(world.field(c, "capital"))
    local bp = cap and world.colony_planet[cap]
    if bp and not t.skip_background then
        local bpb = {}
        world.append(bpb, "type", "planet")
        world.append(bpb, "reference", bp)
        world.append(b, "background_planet", bpb)
    end
    local level = t.skill and math.max(1, t.skill) or 1
    add_traits(b, t.traits, level)
    world.append(b, "level", level)
    world.append(b, "bonus_skill_level", 0)
    if t.hidden then world.append(b, "leader_flags", 512) end
    local lid = objects.create("leaders", b)
    append_owned(country, lid)
    -- the first level-up's two draws and on_leader_level_up (this = the leader, from = the country)
    local eval = package.loaded["simscript.eval"]
    draw()
    draw()
    if eval then objects.on_action("on_leader_level_up", eval.S("leader", lid), eval.S("country", country)) end
    -- OnSpawned: two draws, on_leader_spawned (this = the country, from = the leader)
    draw()
    draw()
    if eval then objects.on_action("on_leader_spawned", eval.S("country", country), eval.S("leader", lid)) end
    return lid
end

function systems.effects.create_leader(t)
    if t.kind ~= "country" then return skipped("create_leader", "not a country") end
    local lid = leaders.create({ country = t.id, class = t.class, species = t.species, name = t.name,
        gender = t.gender, skill = t.skill, age = t.age, traits = t.traits, hidden = t.hidden,
        skip_background = t.skip_background })
    if not lid then return skipped("create_leader", "not made") end
    return applied("create_leader", lid)
end

-- the leader's location (CLeader::SetLocation): `location = { type assignment id position }`
local function set_location(l, ltype, id)
    local e = world.entry(l, "location")
    local loc = {}
    world.append(loc, "type", ltype)
    world.append(loc, "assignment", "none")
    world.append(loc, "id", id)
    world.append(loc, "position", 0)
    if e then
        world.set_entry(l, e, loc)
    else
        local pos = #l + 1
        for i, x in ipairs(l) do
            if x.op and x.key and x.key.text == "tier" then pos = i + 1 end
        end
        world.insert(l, pos, "location", loc)
    end
end

-- set_leader = <leader> on a fleet (CFleet::SetLeader 0x29424d0): the leader at the fleet's flagship
-- (`location = { type = ship id = <first ship> }`), the fleet's `leader`; on_leader_assigned with
-- one draw (CLeaderLocation::SetLeader) [V]
function systems.effects.set_fleet_leader(t)
    local f = world.object("fleet", t.id)
    local l = world.object("leaders", t.leader)
    if not f or not l then return skipped("set_leader", "no fleet or leader") end
    local ship = tonumber(world.list(world.field(f, "ships"))[1])
    set_location(l, "ship", ship or NO_ID)
    world.set(f, "leader", t.leader)
    local eval = package.loaded["simscript.eval"]
    draw()
    if eval then objects.on_action("on_leader_assigned", eval.S("leader", t.leader), nil) end
    return applied("set_leader")
end

-- assign_leader on a planet or colony: the colony's governor (`governor`), the leader's location
-- `type = planet` with the colony's id (the save's form) [V for the draws: one for on_leader_assigned]
function systems.effects.assign_leader(t)
    local l = world.object("leaders", t.leader)
    if not l then return skipped("assign_leader", "no leader") end
    local eval = package.loaded["simscript.eval"]
    if t.kind == "planet" or t.kind == "colony" then
        local cid = t.kind == "colony" and t.id or world.planet_colony[t.id]
        local col = cid and world.object("colony", cid)
        if not col then return skipped("assign_leader", "no colony") end
        set_location(l, "planet", cid)
        world.set(col, "governor", t.leader)
    elseif t.kind == "fleet" then
        return systems.effects.set_fleet_leader({ id = t.id, leader = t.leader })
    else
        return skipped("assign_leader", "scope")
    end
    draw()
    if eval then objects.on_action("on_leader_assigned", eval.S("leader", t.leader), nil) end
    return applied("assign_leader")
end

-- ---------------------------------------------------------------------------------------------
-- policies

local function policies_block(c)
    return world.field(c, "active_policies")
end

local function policy_entry(c, group)
    local ap = policies_block(c)
    for _, e in ipairs(type(ap) == "table" and ap or {}) do
        if not e.op and not e.text and unq(world.field(e, "policy")) == group then return e end
    end
    return nil
end

local function run_option_effect(group, option, key, country)
    local pd = defs.get("common/policies", group)
    if not pd then return end
    local opt
    for _, e in ipairs(pd.block) do
        if e.op and e.key and e.key.text == "option" and e.value.text == nil and unq(defs.field(e.value, "name")) == option then
            opt = e.value
        end
    end
    local eff = opt and defs.field(opt, key)
    if type(eff) == "table" and #eff > 0 then
        local seed = draw()
        local eval = package.loaded["simscript.eval"]
        if eval then
            local ctx = eval.new_ctx(eval.S("country", country))
            eval.seed_scope(ctx, seed)
            pcall(eval.effect, eff, ctx)
        end
    end
end

-- set_policy = { policy option cooldown } (CSetPolicyEffect 0x375fbd0 -> CCountry::ChangePolicy
-- 0x2399b40): the entry's option (a new entry at the end), `date` with cooldown; a change runs the
-- old option's on_disabled and the new one's on_enabled (a draw each when non-empty) and fires
-- on_policy_changed (one draw) [V]
function systems.effects.set_policy(t)
    local c = world.object("country", t.id)
    if not c or not defs.get("common/policies", t.policy) then return skipped("set_policy", "no country or policy") end
    local e = policy_entry(c, t.policy)
    local old
    if e then
        old = unq(world.field(e, "selected"))
        world.set(e, "selected", t.option)
    else
        local ap = policies_block(c)
        if type(ap) ~= "table" then ap = world.child(c, "active_policies") end
        local b = {}
        world.append(b, "policy", t.policy, true)
        world.append(b, "selected", t.option, true)
        world.push(ap, b)
        e = b
    end
    if t.cooldown then
        if world.field(e, "date") ~= nil then world.set(e, "date", today_text()) else world.append(e, "date", today_text(), true) end
    end
    if old == t.option then return applied("set_policy") end
    if old then run_option_effect(t.policy, old, "on_disabled", t.id) end
    run_option_effect(t.policy, t.option, "on_enabled", t.id)
    local seed = draw()
    local eval = package.loaded["simscript.eval"]
    if eval then
        local ok = pcall(function()
            local events = require("simscript.events")
            events.on_action("on_policy_changed", eval.S("country", t.id), nil, require("engine.script.scope_random").new(seed))
        end)
        if not ok then objects.err("on_policy_changed") end
    end
    return applied("set_policy")
end

-- add_council_agenda_progress (0x376b3b0 -> CGovernment::AddCouncilAgendaProgress): the
-- government's council_agenda_progress plus the value, floored at 0 [V]
function systems.effects.add_council_agenda_progress(t)
    local c = world.object("country", t.id)
    local gov = c and world.field(c, "government")
    if type(gov) ~= "table" then return skipped("add_council_agenda_progress", "no government") end
    local v = (tonumber(world.field(gov, "council_agenda_progress")) or 0) + (t.amount or 0)
    world.set(gov, "council_agenda_progress", math.max(0, v))
    return applied("add_council_agenda_progress")
end

-- leaders.initialize_policies(country): CCountry::UpdatePolicies -> InitializePolicy (0x23999f0) for
-- each policy group the country has no entry of: the potential and valid option with the highest
-- ai_weight (the first of equals), no draw; its on_enabled (a draw when non-empty). The groups'
-- and options' potential / valid triggers and the weights' modifiers are evaluated in the country's
-- scope; a group whose potential fails is left out [V for the rule; group order: database order I]
function leaders.initialize_policies(country)
    local c = world.object("country", country)
    if not c then return 0 end
    local eval = package.loaded["simscript.eval"]
    local function holds(block, key)
        local tb = block and defs.field(block, key)
        if type(tb) ~= "table" or not eval then return true end
        local ok, r = pcall(eval.trigger, tb, eval.new_ctx(eval.S("country", country)))
        return ok and r and true or false
    end
    local n = 0
    for _, pg in ipairs(objects.ordered("common/policies")) do
        local group, gb = pg[1], pg[2].block
        if not policy_entry(c, group) and holds(gb, "potential") then
            local best, bw
            for _, e in ipairs(gb) do
                if e.op and e.key and e.key.text == "option" and e.value.text == nil then
                    local opt = e.value
                    if holds(opt, "potential") and holds(opt, "valid") then
                        local aw = defs.field(opt, "ai_weight")
                        local w = 1
                        if type(aw) == "table" and eval then
                            local ok, v = pcall(eval.weight, aw, eval.new_ctx(eval.S("country", country)), tonumber(defs.field(aw, "base") or defs.field(aw, "weight")) or 1)
                            if ok and v then w = v end
                        end
                        if w > -1 and (not best or w > bw) then best, bw = unq(defs.field(opt, "name")), w end
                    end
                end
            end
            if best then
                local ap = policies_block(c)
                if type(ap) ~= "table" then ap = world.child(c, "active_policies") end
                local b = {}
                world.append(b, "policy", group, true)
                world.append(b, "selected", best, true)
                world.push(ap, b)
                run_option_effect(group, best, "on_enabled", country)
                n = n + 1
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- the council (CGovernment's council positions; CCouncilPosition in the save's
-- `council_positions = { council_positions = { <id> = { country type leader } } }`, the
-- government's `council_positions = { <ids> }` and `picked_council_types = { <types> }`,
-- `unlocked_civic_council_slots` (+0x88, CGovernment::WriteMembers 0x1c10570) [V])

local council = {}
leaders.council = council

-- the positions' store, made as the save has it (inside its `council_positions` wrapper) when a
-- generated game has none yet
local function position_store()
    if world.store_blocks.council_positions then return true end
    local tree = world.tree
    if not tree then return false end
    local inner = {}
    tree[#tree + 1] = { key = { text = "council_positions" }, op = "=", value = {
        { key = { text = "council_positions" }, op = "=", value = inner } } }
    world.stores.council_positions, world.ids.council_positions, world.entries.council_positions = {}, {}, {}
    world.store_blocks.council_positions = inner
    return true
end

local function government(c)
    local g = world.field(c, "government")
    return type(g) == "table" and g or nil
end

local function list_block(g, key)
    local b = world.field(g, key)
    if type(b) ~= "table" then b = world.child(g, key) end
    return b
end

-- council.positions(country) -> the ids of the government's council positions, in order
function council.positions(country)
    local c = world.object("country", country)
    local g = c and government(c)
    local out = {}
    for _, v in ipairs(world.list(g and world.field(g, "council_positions"))) do
        local id = tonumber(v)
        if id then out[#out + 1] = id end
    end
    return out
end

-- CGameState::CreateCouncilPosition (0x1b489b0) and the government's two arrays (the position,
-- the picked type): CGovernment::DetermineCouncilorTypes and PickCouncilorType (0x1c13f70) do both
local function add_position(country, ctype)
    local c = world.object("country", country)
    local g = c and government(c)
    if not g or not position_store() then return nil end
    local b = {}
    world.append(b, "country", country)
    world.append(b, "type", ctype, true)
    local id = objects.create("council_positions", b)
    world.append_value(list_block(g, "council_positions"), id)
    world.append_value(list_block(g, "picked_council_types"), ctype, true)
    return id
end

local function holds(country, block, key, default)
    local tb = block and defs.field(block, key)
    if type(tb) ~= "table" then return default end
    local eval = package.loaded["simscript.eval"]
    if not eval then return default end
    local ok, r = pcall(eval.trigger, tb, eval.new_ctx(eval.S("country", country)))
    return ok and r and true or false
end

-- council.determine(country): CGovernment::DetermineCouncilorTypes (0x1c13780, from
-- CCountry::InitFromDesign and SetGovernmentAndCivics): the council cleared, then every councilor
-- type in the database's order whose `possible` holds and whose `optional` does not (an empty
-- trigger holds: a type without `optional` is optional) gets a position. With Galactic Paragons the
-- three regular positions are optional (`has_paragon_dlc`): game_start.72 picks them [V]
function council.determine(country)
    local c = world.object("country", country)
    local g = c and government(c)
    if not g then return 0 end
    for _, id in ipairs(council.positions(country)) do
        world.remove("council_positions", id)
    end
    world.replace(list_block(g, "council_positions"), {})
    world.replace(list_block(g, "picked_council_types"), {})
    local n = 0
    for _, d in ipairs(objects.ordered("common/governments/councilors")) do
        local b = d[2].block
        if holds(country, b, "possible", true) and not holds(country, b, "optional", true) then
            if add_position(country, d[1]) then n = n + 1 end
        end
    end
    return n
end

-- the unlocked slots (CGovernment +0x88, `unlocked_civic_council_slots`)
local function unlocked(g)
    return tonumber(world.field(g, "unlocked_civic_council_slots")) or 0
end

-- unlock_council_slots = N (CUnlockCouncilSlot::ExecuteActual 0x3715700): with the Galactic
-- Paragons DLC only, CGovernment::AddUnlockedCouncilSlots (+0x88 += N) [V]
function systems.effects.unlock_council_slots(t)
    local c = world.object("country", t.id)
    local g = c and government(c)
    if not g then return skipped("unlock_council_slots", "no government") end
    if not t.paragons then return applied("unlock_council_slots", "no Galactic Paragons") end
    world.set(g, "unlocked_civic_council_slots", unlocked(g) + (t.amount or 0))
    return applied("unlock_council_slots")
end

-- set_council_position_to_council = <type> (CSetCouncilPositionToCouncil 0x3715bf0): a
-- CUnlockCouncilPositionCommand run when valid (IsValid 0x22a7190: a slot to pick,
-- HasAvailableCouncilorSlotPick: picked types < unlocked slots; the type not picked yet), Execute:
-- PickCouncilorType [V; the civic's check not modelled]
function systems.effects.set_council_position_to_council(t)
    local c = world.object("country", t.id)
    local g = c and government(c)
    if not g or not defs.get("common/governments/councilors", t.ctype) then
        return skipped("set_council_position_to_council", "no government or type")
    end
    local picked = world.list(world.field(g, "picked_council_types"))
    for _, p in ipairs(picked) do
        if unq(p) == t.ctype then return applied("set_council_position_to_council", "picked") end
    end
    if #picked >= unlocked(g) then return applied("set_council_position_to_council", "no slot") end
    add_position(t.id, t.ctype)
    return applied("set_council_position_to_council")
end

-- council.seat(position, leader): CLeaderLocation::SetLeader (0x1d3c760) on a council position:
-- the position's `leader`, the leader's `council_location = { type = council_position
-- assignment = none id position = 0 }` (a previous holder's taken off), one draw and
-- on_leader_assigned (as the fleet's) [V for the form: the 2200.01.11 save]
function council.seat(pid, lid)
    local p = world.object("council_positions", pid)
    local l = world.object("leaders", lid)
    if not p or not l then return false end
    local old = tonumber(world.field(p, "leader"))
    if old and old ~= lid and old ~= NO_ID then
        local ol = world.object("leaders", old)
        local e = ol and world.entry(ol, "council_location")
        if e then world.remove_entry(ol, e) end
    end
    world.set(p, "leader", lid)
    local loc = {}
    world.append(loc, "type", "council_position")
    world.append(loc, "assignment", "none")
    world.append(loc, "id", pid)
    world.append(loc, "position", 0)
    local e = world.entry(l, "council_location")
    if e then
        world.set_entry(l, e, loc)
    else
        local pos = #l + 1
        for i, x in ipairs(l) do
            if x.op and x.key and (x.key.text == "location" or x.key.text == "tier") then pos = i + 1 end
        end
        world.insert(l, pos, "council_location", loc)
    end
    local eval = package.loaded["simscript.eval"]
    draw()
    if eval then objects.on_action("on_leader_assigned", eval.S("leader", lid), nil) end
    return true
end

-- set_council_position = <type> (CSetCouncilPosition 0x37b32f0, a leader): the leader seated in
-- its owner's position of that type
function systems.effects.set_council_position(t)
    local l = world.object("leaders", t.leader)
    local country = l and tonumber(world.field(l, "country"))
    if not country then return skipped("set_council_position", "no leader") end
    for _, pid in ipairs(council.positions(country)) do
        local p = world.object("council_positions", pid)
        if p and world.field(p, "type") == t.ctype then
            council.seat(pid, t.leader)
            return applied("set_council_position")
        end
    end
    return skipped("set_council_position", "no position " .. tostring(t.ctype))
end

-- council.fill(country): the end of InitEmpireShared (0x262a605): when the country can change its
-- councilors (CGameRules::CanCountryChangeCouncilors), each position in order takes the first of
-- the country's leaders (owned_leaders' order) not on the council for whom the type's
-- `is_leader_possible` holds (CCouncilPosition::IsLeaderPossible) [V; the rule's trigger: leaders.lua]
function council.fill(country)
    local c = world.object("country", country)
    if not c then return 0 end
    local okl, L = pcall(require, "engine.leaders")
    if okl and type(L) == "table" and L.can_change_councilors and not L.can_change_councilors(country) then
        return 0
    end
    local eval = package.loaded["simscript.eval"]
    local n = 0
    for _, pid in ipairs(council.positions(country)) do
        local p = world.object("council_positions", pid)
        local d = p and defs.get("common/governments/councilors", world.field(p, "type") or "")
        local held = p and tonumber(world.field(p, "leader"))
        if d and not (held and held ~= NO_ID) then
            for _, v in ipairs(world.list(world.field(c, "owned_leaders"))) do
                local lid = tonumber(v)
                local l = lid and world.object("leaders", lid)
                if l and world.field(l, "council_location") == nil and tonumber(world.field(c, "ruler")) ~= lid then
                    local ok = true
                    local ip = defs.field(d.block, "is_leader_possible")
                    if type(ip) == "table" and eval then
                        local good, r = pcall(eval.trigger, ip, eval.new_ctx(eval.S("leader", lid)))
                        ok = good and r and true or false
                    end
                    if ok then
                        council.seat(pid, lid)
                        n = n + 1
                        break
                    end
                end
            end
        end
    end
    return n
end

return leaders
