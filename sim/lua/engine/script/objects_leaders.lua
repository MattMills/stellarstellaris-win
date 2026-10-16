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

return leaders
