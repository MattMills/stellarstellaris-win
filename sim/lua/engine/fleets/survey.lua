-- engine/fleets/survey.lua : surveys and anomalies, the way the game's fleet orders do them (GOG
-- 4.5.2; docs/fleet_orders.md has the addresses and what is verified):
--
--   survey_planet_order    CSurveyDepositHolderFleetOrder: progress per day in orbit, done at
--                          BASE_SURVEY_TIME * the planet class's survey_time_factor; finished: the
--                          on_actions, the country's surveyed_deposit_holders, the scientist's
--                          experience, the planet's survey and its anomaly roll, the system fully
--                          surveyed, the fleet out of orbit
--   research_anomaly_order CResearchAnomalyFleetOrder: progress per day in orbit, done at the days
--                          of SCIENCE_SHIP_ANOMALY_RESEARCH_DAYS for the level difference; finished:
--                          the experience, the category's outcome event, the anomaly gone
--
-- Both register in engine.fleets.orders (orders.TYPES); the other half of each (the queue, the
-- orbit sub-order) is there. Random draws are the synchronized generator's (RUST.rand: the fleets'
-- serial phase), in the game's order; the anomaly roll's own stream is a CNoiseRandom seeded from
-- one draw (engine.newgame.rng.stream).
--
--   local survey = require("engine.fleets.survey")
--   survey.has_surveyed(country, 0, planet)   -- CCountry::HasSurveyedDepositHolder
--   survey.add_surveyed(country, 0, planet, fleet, host)  -- CCountry::AddSurveyedDepositHolder
--   survey.on_survey(planet, ship, host)      -- CPlanet::OnSurvey (the anomaly roll)

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")
local live = require("engine.store.live")   -- the store's copy of the country (docs/data_layer.md)

local survey = {
    stats = {
        progress_days = 0, finished = 0, auto_surveyed = 0, holders_added = 0, anomaly_rolls = 0,
        anomaly_chance_failed = 0, no_category = 0, null_spawn = 0, anomalies_spawned = 0,
        fully_surveyed = 0, research_days = 0, researched = 0, outcome_events = 0,
    },
    spawned = {},   -- { planet, category, country, date }
    finished = {},  -- { fleet, planet, country, date }
}
local S = survey.stats

local NO_ID = 4294967295
local ONE = 100000

-- ---------------------------------------------------------------------------------------------
-- helpers

local function fixed(v)
    return math.floor((tonumber(v) or 0) * ONE + 0.5)
end
-- CFixedPoint a * b (truncated toward zero)
local function fmul(a, b)
    local p = a * b / ONE
    return p >= 0 and math.floor(p) or -math.floor(-p)
end

local D
local function define(group, key, default)
    local g = defs.get("common/defines", group)
    local v = g and defs.field(g.block, key)
    return v ~= nil and v or default
end
local function defines()
    if D == nil then
        local days = {}
        local list = define("NGameplay", "SCIENCE_SHIP_ANOMALY_RESEARCH_DAYS", nil)
        for _, e in ipairs(type(list) == "table" and list or {}) do
            if e.text and tonumber(e.text) then days[#days + 1] = fixed(e.text) end
        end
        if #days == 0 then
            days = { 20, 24, 30, 35, 45, 55, 65, 80, 100, 120, 180, 300, 540, 720, 1080, 1440, 2160, 2880, 5760 }
            for i, v in ipairs(days) do days[i] = v * ONE end
        end
        D = {
            SURVEY_SPEED_MULT = fixed(define("NGameplay", "SCIENCE_SHIP_SURVEY_SPEED_MULT", 0.5)),
            BASE_SURVEY_TIME = fixed(define("NGameplay", "BASE_SURVEY_TIME", 30)),
            SURVEY_XP = tonumber(define("NGameplay", "LEADER_SCIENTIST_SURVEY_EXPERIENCE", 10)),
            ANOMALY_XP = tonumber(define("NGameplay", "LEADER_SCIENTIST_SUCCESSFUL_ANOMALY_RESEARCH_EXPERIENCE", 50)),
            SPAWN_CHANCE = fixed(define("NGameplay", "ANOMALY_SPAWN_CHANCE", 0.05)),
            SPAWN_INCREMENT = fixed(define("NGameplay", "ANOMALY_SPAWN_CHANCE_INCREMENT", 0.0025)),
            RESEARCH_DAYS = days,
        }
    end
    return D
end
survey.defines = defines

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers and economy.modifiers(kind, id) or {}
end

local function planet(id)
    return id and world.object("planet", id)
end

local function system_of_planet(p)
    return p and tonumber(world.field(world.field(p, "coordinate"), "origin"))
end

local function today()
    local d = RUST.date and RUST.date()
    return d
end

-- the fleet's ships, in order
local function ships_of(f)
    local out = {}
    for _, t in ipairs(world.list(world.field(f, "ships"))) do
        out[#out + 1] = tonumber(t)
    end
    return out
end
survey.ships_of = ships_of

-- CFleet::GetLeader: the first of the fleet's ships with a leader
local function leader_of(f)
    for _, sid in ipairs(ships_of(f)) do
        local l = tonumber(world.field(world.object("ships", sid), "leader"))
        if l and l ~= NO_ID and world.object("leaders", l) then
            return l
        end
    end
    return nil
end
survey.leader_of = leader_of

-- a ship's ship size (its design's first growth stage's ship_size)
local function ship_size(sid)
    local s = world.object("ships", sid)
    local impl = s and world.field(s, "ship_design_implementation")
    local did = type(impl) == "table" and tonumber(world.field(impl, "design"))
    local d = did and world.object("ship_design", did)
    local stages = d and world.field(d, "growth_stages")
    local first = world.blocks(stages)[1]
    return first and world.field(first, "ship_size") or nil
end

-- CShipSize::GetModifierValue(index): the modifier and the ship size's own variant of it
-- (`shipsize_<size>_<suffix>`, CShipSize::GetModifierType), from the ship's modifier node
local function size_mod(M, size, name, suffix)
    local v = M[name] or 0
    if size then
        v = v + (M["shipsize_" .. size .. "_" .. suffix] or 0)
    end
    return fixed(v)
end

-- CDepositHolder::IsColonizable: no owner, and the planet class colonizable
local function is_colonizable(p)
    local owner = tonumber(world.field(p, "owner"))
    if owner and owner ~= NO_ID then
        return false
    end
    local cl = world.field(p, "planet_class")
    local d = cl and defs.get("common/planet_classes", cl)
    return d ~= nil and defs.field(d.block, "colonizable") == "yes"
end

local humans
local function is_human(country)
    if humans == nil then
        humans = {}
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "player" and e.value.text == nil then
                for _, p in ipairs(world.blocks(e.value)) do
                    local c = tonumber(world.field(p, "country"))
                    if c then humans[c] = true end
                end
            end
        end
    end
    return humans[country] == true
end

-- an on_action with this, from and fromfrom (the script layer)
local function on_action(name, this, from, fromfrom)
    local events = package.loaded["simscript.events"] or require("simscript.events")
    local ctx = eval.new_ctx(from or eval.NONE, fromfrom or eval.NONE)
    local ok, err = pcall(events.on_action, name, this, ctx)
    if not ok then
        S.on_action_errors = (S.on_action_errors or 0) + 1
        survey.last_error = tostring(err)
    end
end
survey.on_action = on_action

local function add_experience(leader, amount)
    if leader then
        require("engine.leaders").add_experience(leader, amount)
    end
end

-- ---------------------------------------------------------------------------------------------
-- the country's surveys

-- CCountry::HasAutoSurveyedSystem (0x717370): a country whose type does not need surveys
-- (country_types needs_survey = no) has every system surveyed; one that does has its own systems
local function needs_survey(country)
    local c = world.object("country", country)
    if not c then
        return false
    end
    local ty = world.field(c, "type")
    local d = ty and defs.get("common/country_types", ty)
    return d ~= nil and defs.field(d.block, "needs_survey") == "yes"
end
function survey.has_auto_surveyed_system(country, system)
    if not world.object("country", country) then
        return true
    end
    if not needs_survey(country) then
        return true
    end
    return system ~= nil and world.system_owner[system] == country
end

local function holders(country, create)
    local c = world.object("country", country)
    if not c then
        return nil
    end
    local b = world.field(c, "surveyed_deposit_holders")
    if type(b) ~= "table" and create then
        b = world.child(c, "surveyed_deposit_holders")
    end
    return type(b) == "table" and b or nil
end

-- CCountry::_HasSurveyedDepositHolder: the holder in the country's sorted list
local function in_list(country, ty, id)
    local b = holders(country, false)
    for _, h in ipairs(world.blocks(b)) do
        if tonumber(world.field(h, "type")) == ty and tonumber(world.field(h, "id")) == id then
            return true
        end
    end
    return false
end

-- CCountry::HasSurveyedDepositHolder (0x71aec0): auto-surveyed, or in the list
function survey.has_surveyed(country, ty, id)
    local system
    if ty == 0 then
        system = system_of_planet(planet(id))
    end
    if survey.has_auto_surveyed_system(country, system) then
        return true
    end
    return in_list(country, ty, id)
end

-- the scope of a deposit holder (type 0 a planet, 1 an astral rift, 2 a ship)
local function holder_scope(ty, id)
    if ty == 0 then return eval.S("planet", id) end
    if ty == 1 then return eval.S("astral_rift", id) end
    if ty == 2 then return eval.S("ship", id) end
    return eval.NONE
end

-- CCountry::AddSurveyedDepositHolder (0x71b0d0): inserted in the sorted list (type, then id), three
-- draws for the scopes, then on_planet_surveyed / on_astral_rift_surveyed / on_ship_surveyed
-- (this = the holder, from = the country, fromfrom = the fleet). Nothing when it is there already.
function survey.add_surveyed(country, ty, id, fleet, host)
    if not world.object("country", country) or in_list(country, ty, id) then
        return false
    end
    local b = holders(country, true)
    local pos = #b + 1
    for i, e in ipairs(b) do
        if not e.text and not e.op then
            local t2, i2 = tonumber(world.field(e, "type")) or 0, tonumber(world.field(e, "id")) or 0
            if t2 > ty or (t2 == ty and i2 > id) then
                pos = i
                break
            end
        end
    end
    local h = {}
    world.append(h, "type", ty)
    world.append(h, "id", id)
    table.insert(b, pos, h)
    live.touch("country", country)
    S.holders_added = S.holders_added + 1
    RUST.rand()
    RUST.rand()
    RUST.rand()
    local names = { [0] = "on_planet_surveyed", [1] = "on_astral_rift_surveyed", [2] = "on_ship_surveyed" }
    if names[ty] then
        on_action(names[ty], holder_scope(ty, id), eval.S("country", country), fleet and eval.S("fleet", fleet) or nil)
    end
    return true
end

-- every deposit holder of a system: its planets (galactic_object.planet) and astral rifts
local function system_holders(system)
    local out = {}
    local g = world.object("galactic_object", system)
    for _, v in ipairs(world.fields(g, "planet")) do
        if type(v) == "string" and tonumber(v) then out[#out + 1] = { 0, tonumber(v) } end
    end
    for _, v in ipairs(world.list(g and world.field(g, "astral_rifts"))) do
        out[#out + 1] = { 1, tonumber(v) }
    end
    return out
end

local function fully_surveyed(country, system)
    for _, h in ipairs(system_holders(system)) do
        if not survey.has_surveyed(country, h[1], h[2]) then
            return false
        end
    end
    return true
end

-- CGalacticObject::OnFullySurveyed (0x86e790): with a fleet, two draws and on_system_survey_ship
-- (this = the ship, from = the system); then three draws and on_system_survey (this = the country,
-- from = the system, fromfrom = the fleet)
local function on_fully_surveyed(system, country, fid, ship)
    S.fully_surveyed = S.fully_surveyed + 1
    if fid and world.object("fleet", fid) then
        RUST.rand()
        RUST.rand()
        on_action("on_system_survey_ship", ship and eval.S("ship", ship) or eval.NONE, eval.S("system", system))
    end
    RUST.rand()
    RUST.rand()
    RUST.rand()
    on_action("on_system_survey", eval.S("country", country), eval.S("system", system), fid and eval.S("fleet", fid) or nil)
end

-- ---------------------------------------------------------------------------------------------
-- anomalies

-- the country's accumulated anomaly chance (modules.standard_event_module
-- .accumulated_anomaly_spawn_chance; CEventCountryModule, 0 when not written)
local function event_module(country, create)
    local c = world.object("country", country)
    local m = c and world.field(c, "modules")
    if type(m) ~= "table" then
        return nil
    end
    local em = world.field(m, "standard_event_module")
    if type(em) ~= "table" then
        if not create then
            return nil
        end
        em = world.child(m, "standard_event_module")
    end
    return em
end
local function accumulated(country)
    return fixed(world.field(event_module(country, false), "accumulated_anomaly_spawn_chance") or 0)
end
local function set_accumulated(country, v)
    local em = event_module(country, true)
    if not em then
        return
    end
    if v == 0 then
        for _, e in ipairs(em) do
            if e.op and e.key and e.key.text == "accumulated_anomaly_spawn_chance" then
                world.remove_entry(em, e)
                break
            end
        end
    else
        world.set(em, "accumulated_anomaly_spawn_chance", v / ONE)
    end
end

-- the country's planets with an anomaly (`events = { anomalies = { ids } }`)
local function anomaly_list(country, create)
    local c = world.object("country", country)
    if not c then
        return nil
    end
    local ev = world.field(c, "events")
    if type(ev) ~= "table" then
        if not create then return nil end
        ev = world.child(c, "events")
    end
    local l = world.field(ev, "anomalies")
    if type(l) ~= "table" then
        if not create then return nil end
        l = world.child(ev, "anomalies")
    end
    return l
end
local function list_has(l, id)
    for _, v in ipairs(world.list(l)) do
        if tonumber(v) == id then return true end
    end
    return false
end

local function surveyed_by(p)
    local v = tonumber(world.field(p, "surveyed_by"))
    return (v and v ~= NO_ID) and v or nil
end

-- CCountryEventManager::UpdateAnomalyPresenceOnPlanet, from CPlanet::SetAnomaly (0xe0b450): the
-- country that surveyed the planet lists it while it has an anomaly
local function set_anomaly(pid, category)
    local p = planet(pid)
    local had = world.field(p, "anomaly") ~= nil
    if category then
        world.set(p, "anomaly", category)
        for _, e in ipairs(p) do
            if e.op and e.key and e.key.text == "anomaly" then e.value.quoted = true end
        end
    else
        for _, e in ipairs(p) do
            if e.op and e.key and e.key.text == "anomaly" then
                world.remove_entry(p, e)
                break
            end
        end
    end
    local has = category ~= nil
    local owner = surveyed_by(p)
    if has ~= had and owner then
        local l = anomaly_list(owner, has)
        if l then
            if has then
                if not list_has(l, pid) then world.append_value(l, pid) end
            else
                world.remove_value(l, pid)
            end
        end
    end
end
survey.set_anomaly = set_anomaly

-- the anomaly categories in the database's order (the load order of common/anomalies)
local CATS
local function categories()
    if CATS == nil then
        CATS = {}
        for name, d in pairs(defs.folder("common/anomalies")) do
            CATS[#CATS + 1] = { name = name, def = d }
        end
        table.sort(CATS, function(a, b)
            if a.def.file ~= b.def.file then return tostring(a.def.file) < tostring(b.def.file) end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
    end
    return CATS
end

local function yes(block, key)
    return defs.field(block, key) == "yes"
end

-- a weight block (`spawn_chance = { base modifier = { add factor ... } }`, an outcome's) through the
-- script layer, as a CFixedPoint
local function weight(block, ctx)
    if type(block) ~= "table" then
        return fixed(tonumber(block) or 0)
    end
    local ok, w = pcall(eval.weight, block, ctx, 0)
    if not ok then
        S.weight_errors = (S.weight_errors or 0) + 1
        return 0
    end
    return fixed(w or 0)
end

-- the outcomes of a category's on_success: { weight block, event id, max_once, max_once_global }
local function outcomes(block)
    local os = defs.field(block, "on_success")
    local out = {}
    if os == nil then
        return out
    end
    if type(os) ~= "table" then
        out[1] = { base = ONE, event = os, max_once = true, max_once_global = false, simple = true }
        return out
    end
    for _, e in ipairs(os) do
        if e.op and e.key and tonumber(e.key.text) then
            local o = { base = fixed(e.key.text), max_once = true, max_once_global = false }
            if e.value.text then
                o.event = e.value.text
            else
                o.block = e.value
                o.event = defs.field(e.value, "anomaly_event") or defs.field(e.value, "ship_event")
                o.ship_event = defs.field(e.value, "ship_event") ~= nil
                local mo, mg = defs.field(e.value, "max_once"), defs.field(e.value, "max_once_global")
                if mo == "no" then o.max_once = false end
                if mg == "yes" then o.max_once_global = true end
            end
            out[#out + 1] = o
        end
    end
    return out
end

local function outcome_flag(o)
    return "anomaly_outcome_happened_" .. tostring(o.event)
end

-- CAnomalyType::COutcomeOption::CalcMTTHRawFactor (0x8411a0): 0 once its max-once flag is set
-- (globally, or on the country), else its weight (the base times its modifiers; scope: the ship,
-- from the planet)
local function outcome_weight(o, country, ctx)
    local flag = outcome_flag(o)
    if o.max_once_global and eval.store.has_flag(nil, flag) then
        return 0
    end
    if o.max_once and eval.store.has_flag(eval.S("country", country), flag) then
        return 0
    end
    if not o.block then
        return o.base
    end
    local mods = {}
    for _, e in ipairs(o.block) do
        if e.op and e.key and e.key.text == "modifier" then mods[#mods + 1] = e end
    end
    if #mods == 0 then
        return o.base
    end
    local blk = { { key = { text = "base" }, op = "=", value = { text = tostring(o.base / ONE) } } }
    for _, m in ipairs(mods) do blk[#blk + 1] = m end
    return weight(blk, ctx)
end

-- CAnomalyType::CanSucceed (0x83ff50): some outcome weighs at least 1
local function can_succeed(cat, country, ctx)
    for _, o in ipairs(outcomes(cat.def.block)) do
        if outcome_weight(o, country, ctx) >= ONE then
            return true
        end
    end
    return false
end

local function cat_flag(cat)
    return "anomaly_" .. cat.name
end

-- CAnomalyType::CalcSpawnChance (0x840140): 0 once spawned (max_once_global: the global flag
-- anomaly_<key>; max_once: the country's), else spawn_chance (scope: the planet, from the ship)
local function spawn_chance(cat, country, ctx)
    local b = cat.def.block
    if yes(b, "max_once_global") and eval.store.has_flag(nil, cat_flag(cat)) then
        return 0
    end
    if yes(b, "max_once") and eval.store.has_flag(eval.S("country", country), cat_flag(cat)) then
        return 0
    end
    return weight(defs.field(b, "spawn_chance"), ctx)
end

-- CAnomalyTypeDatabase::CollectEligibleAnomalies (0x842310): the categories for this country
-- (should_ai_and_humans_use, else should_ai_use for an AI, else a human's), not active on one of its
-- planets already, that can succeed, with a spawn chance above 0
local function eligible(pid, ship, country)
    local active = {}
    for _, v in ipairs(world.list(anomaly_list(country, false))) do
        local p = planet(tonumber(v))
        local a = p and world.field(p, "anomaly")
        if a then active[a] = true end
    end
    local ai = not is_human(country)
    local ship_ctx = eval.new_ctx(eval.S("ship", ship), eval.S("planet", pid))
    local planet_ctx = eval.new_ctx(eval.S("planet", pid), eval.S("ship", ship))
    local cats, weights = {}, {}
    for _, cat in ipairs(categories()) do
        local b = cat.def.block
        local ok
        if yes(b, "should_ai_and_humans_use") then
            ok = true
        elseif yes(b, "should_ai_use") then
            ok = ai
        else
            ok = not ai
        end
        if ok and not active[cat.name] and can_succeed(cat, country, ship_ctx) then
            local w = spawn_chance(cat, country, planet_ctx)
            if w > 0 then
                cats[#cats + 1] = cat
                weights[#weights + 1] = w
            end
        end
    end
    return cats, weights
end

-- GetWeightedRandomInternal<CFixedPoint> (0x1b4ad80): r below the positive weights' total, the
-- first whose running sum passes it
local function weighted(weights, r, fallback)
    local total = 0
    for _, w in ipairs(weights) do
        if w > 0 then total = total + w end
    end
    if total == 0 then
        return fallback
    end
    local x
    if total <= 2147483647 then
        x = r % total
    else
        x = math.floor(math.floor(total * 1000 / 2147483647) * r / 1000)
    end
    local acc = 0
    for i, w in ipairs(weights) do
        if w > 0 then
            acc = acc + w
            if acc > x then
                return i
            end
        end
    end
    return fallback
end

-- CAnomalyTypeDatabase::GetRandomAnomalyFor (0x841f50), with one draw of the global generator as
-- the seed of its own stream: the chance (ANOMALY_SPAWN_CHANCE + the country's accumulated chance)
-- times 1 + ship_anomaly_generation_chance_mult (+ _uninhabitable on an uncolonizable planet);
-- (first value % 100000) * 100 against chance * 100; then a category by spawn chance (the second
-- value)
local function random_anomaly(pid, ship, country, seed)
    local d = defines()
    local p = planet(pid)
    local M = modifiers("ship", ship)
    local size = ship_size(ship)
    local mult = size_mod(M, size, "ship_anomaly_generation_chance_mult", "anomaly_generation_chance")
    if not is_colonizable(p) then
        mult = mult + size_mod(M, size, "ship_anomaly_generation_chance_mult_uninhabitable", "anomaly_generation_chance_uninhabitable")
    end
    local chance = fmul(d.SPAWN_CHANCE + accumulated(country), ONE + mult)
    local stream = require("engine.newgame.rng").stream(seed)
    local v1, v2 = stream:int(), stream:int()
    if (v1 % 100000) * 100 >= chance * 100 then
        S.anomaly_chance_failed = S.anomaly_chance_failed + 1
        return nil
    end
    local cats, weights = eligible(pid, ship, country)
    if #cats == 0 then
        S.no_category = S.no_category + 1
        return nil
    end
    local i = weighted(weights, v2, v2 % #cats + 1)
    return cats[i]
end

-- CPlanet::OnSurvey(ship) (0xe0b040): the planet surveyed (binary_flags bit 2) once; in a system
-- someone else owns nothing more; the country that surveyed it first (surveyed_by, with its
-- anomaly listed); then, unless bit 3 or an anomaly already, the anomaly roll: one draw for the
-- category's stream; none picked: the accumulated chance + ANOMALY_SPAWN_CHANCE_INCREMENT; one
-- picked: a draw below null_spawn_chance spawns nothing (the max-once flags set), else the
-- accumulated chance back to 0, the anomaly set, two draws for the scopes, CAnomalyType::OnSpawn
-- (the max-once flags, on_spawn: this = the planet, from = the ship)
function survey.on_survey(pid, ship, host)
    local p = planet(pid)
    if not p then
        return
    end
    local flags = tonumber(world.field(p, "binary_flags")) or 64
    if math.floor(flags / 4) % 2 == 1 then
        return
    end
    flags = flags + 4
    world.set(p, "binary_flags", flags)
    local s = world.object("ships", ship)
    local fleet = s and tonumber(world.field(s, "fleet"))
    local country = fleet and world.fleet_owner[fleet]
    local system = system_of_planet(p)
    local sys_owner = system and world.system_owner[system]
    if sys_owner and sys_owner ~= country then
        return
    end
    -- CPlanet::OnSurvey(country) (0xe0af90)
    if surveyed_by(p) == nil and country then
        world.set(p, "surveyed_by", country)
        if world.field(p, "anomaly") then
            local l = anomaly_list(country, true)
            if l and not list_has(l, pid) then world.append_value(l, pid) end
        end
    end
    if math.floor(flags / 8) % 2 == 1 or world.field(p, "anomaly") then
        return
    end
    if not country then
        return
    end
    S.anomaly_rolls = S.anomaly_rolls + 1
    local seed = RUST.rand()
    local cat = random_anomaly(pid, ship, country, seed)
    if not cat then
        set_accumulated(country, accumulated(country) + defines().SPAWN_INCREMENT)
        return
    end
    local roll = RUST.rand() % 100000
    local b = cat.def.block
    local null = fixed(defs.field(b, "null_spawn_chance") or 0)
    local function max_once_flags()
        if yes(b, "max_once_global") then eval.store.set_flag(nil, cat_flag(cat)) end
        if yes(b, "max_once") then eval.store.set_flag(eval.S("country", country), cat_flag(cat)) end
    end
    if roll < null then
        S.null_spawn = S.null_spawn + 1
        max_once_flags()
        return
    end
    set_accumulated(country, 0)
    set_anomaly(pid, cat.name)
    RUST.rand()
    RUST.rand()
    S.anomalies_spawned = S.anomalies_spawned + 1
    survey.spawned[#survey.spawned + 1] = { planet = pid, category = cat.name, country = country, date = today() }
    -- CAnomalyType::OnSpawn (0x840910)
    max_once_flags()
    local on_spawn = defs.field(b, "on_spawn")
    if type(on_spawn) == "table" then
        local ok = pcall(eval.effect, on_spawn, eval.new_ctx(eval.S("planet", pid), eval.S("ship", ship), nil, cat.def.file))
        if not ok then S.on_spawn_errors = (S.on_spawn_errors or 0) + 1 end
    end
end

-- CPlanet::HasAnomaly(country) (0xdfb5d0): an anomaly, on a planet the country surveyed first
local function has_anomaly_for(p, country)
    return world.field(p, "anomaly") ~= nil and surveyed_by(p) == country
end
survey.has_anomaly = function(pid) local p = planet(pid); return p ~= nil and world.field(p, "anomaly") ~= nil end

-- ---------------------------------------------------------------------------------------------
-- the orders (engine.fleets.orders calls them with o = { type, block }, the fleet's id and block)

local function holder_of(o)
    local h = world.field(o.block, "deposit_holder")
    return tonumber(world.field(h, "type")) or 0, tonumber(world.field(h, "id"))
end

local function progress(o)
    return fixed(world.field(o.block, "progress") or 0)
end
-- the progress as the save writes it: after the order's target; a research_anomaly_order leaves it
-- out at 0 (a survey writes `progress = 0`)
local function set_progress(o, v)
    local after = o.type == "research_anomaly_order" and "planet" or "deposit_holder"
    local pos
    for i, e in ipairs(o.block) do
        if e.op and e.key and e.key.text == "progress" then
            if v == 0 and o.type == "research_anomaly_order" then
                world.remove_entry(o.block, e)
            else
                world.set(o.block, "progress", v / ONE)
            end
            return
        end
        if e.op and e.key and e.key.text == after then pos = i end
    end
    if v == 0 and o.type == "research_anomaly_order" then
        return
    end
    world.insert(o.block, (pos or #o.block) + 1, "progress", v / ONE)
end

local function head_ship(f)
    return ships_of(f)[1]
end

-- the fleet can do science: civilian, one ship, a science ship (CShip +0x8c0 == 3)
local function science_fleet(f)
    local props = world.field(f, "properties")
    if type(props) ~= "table" or world.field(props, "civilian") ~= "yes" then
        return false
    end
    local ships = ships_of(f)
    return #ships == 1 and world.field(f, "ship_class") == "shipclass_science_ship"
end

local survey_order = {}

-- CSurveyDepositHolderFleetOrder::GetNeededProgress (0xce4ad0): BASE_SURVEY_TIME * the planet
-- class's survey_time_factor (1 when not given)
function survey_order.needed(o)
    local ty, id = holder_of(o)
    local factor = ONE
    if ty == 0 then
        local p = planet(id)
        local cl = p and world.field(p, "planet_class")
        local d = cl and defs.get("common/planet_classes", cl)
        local v = d and defs.field(d.block, "survey_time_factor")
        if v then factor = fixed(v) end
    end
    return fmul(defines().BASE_SURVEY_TIME, factor)
end

-- the daily progress (TickOrder 0xce3a00): SCIENCE_SHIP_SURVEY_SPEED_MULT * (1 +
-- science_ship_survey_speed + science_ship_survey_speed_uninhabitable on an uncolonizable planet,
-- each with its ship size's variant), from the head ship's modifiers
function survey_order.speed(o, f)
    local ty, id = holder_of(o)
    local ship = head_ship(f)
    local M = modifiers("ship", ship)
    local size = ship_size(ship)
    local sum = size_mod(M, size, "science_ship_survey_speed", "science_survey_speed")
    local p = ty == 0 and planet(id)
    if p and not is_colonizable(p) then
        sum = sum + size_mod(M, size, "science_ship_survey_speed_uninhabitable", "science_survey_speed_uninhabitable")
    end
    return fmul(defines().SURVEY_SPEED_MULT, ONE + sum)
end

-- IsDone (0xce4be0): auto-surveyed or surveyed already by the fleet's country, or the progress
-- reached (the system's CanSurvey not modelled: true)
function survey_order.is_done(o, fid, f, orders)
    local ty, id = holder_of(o)
    local country = world.fleet_owner[fid]
    if country and survey.has_surveyed(country, ty, id) then
        return true
    end
    return progress(o) >= survey_order.needed(o)
end

-- IsPossible (approximated): the holder exists, the fleet has a ship
function survey_order.is_possible(o, fid, f)
    local ty, id = holder_of(o)
    if ty ~= 0 or not planet(id) then
        return ty == 1 and world.object("astral_rifts", id) ~= nil
    end
    return #ships_of(f) > 0
end

-- TickOrder (0xce3a00): a science fleet (or a scripted override, not modelled) in orbit of the
-- planet and idle advances; else the orbit sub-order (made if there is none) goes on
function survey_order.tick(o, fid, f, orders)
    local ty, id = holder_of(o)
    if not science_fleet(f) then
        return
    end
    if ty == 0 and orders.in_orbit_of(fid, f, id) then
        orders.clear_sub_order(o)
        set_progress(o, progress(o) + survey_order.speed(o, f))
        S.progress_days = S.progress_days + 1
        return
    end
    if ty == 0 then
        orders.tick_orbit_sub_order(o, fid, f, id)
    end
end

-- StartOrder (0xce39a0): possible: ticked once, then the progress set to 0; else the fleet's
-- current order cancelled
function survey_order.start(o, fid, f, orders)
    if survey_order.is_possible(o, fid, f) then
        survey_order.tick(o, fid, f, orders)
        set_progress(o, 0)
    else
        orders.cancel_current(fid, f)
    end
end

-- Finish (0xce3d30)
function survey_order.finish(o, fid, f, orders, host)
    local ships = ships_of(f)
    if #ships == 0 then
        return
    end
    local ty, id = holder_of(o)
    local country = world.fleet_owner[fid]
    local p = ty == 0 and planet(id) or nil
    if ty == 0 and not p then
        return
    end
    if not country then
        return
    end
    local system = p and system_of_planet(p)
    local ship = ships[1]
    local auto = survey.has_auto_surveyed_system(country, system)
    if not auto then
        -- two draws for the scopes; on_survey_planet (this = the ship, from = the planet)
        RUST.rand()
        RUST.rand()
        if ty == 0 then
            on_action("on_survey_planet", eval.S("ship", ship), eval.S("planet", id))
        elseif ty == 1 then
            on_action("on_survey_astral_rift", eval.S("ship", ship), eval.S("astral_rift", id))
        end
    end
    survey.add_surveyed(country, ty, id, fid, host)
    S.finished = S.finished + 1
    survey.finished[#survey.finished + 1] = { fleet = fid, planet = id, country = country, date = today() }
    if auto then
        S.auto_surveyed = S.auto_surveyed + 1
        return
    end
    local leader = leader_of(f)
    add_experience(leader, defines().SURVEY_XP)
    if ty == 0 then
        survey.on_survey(id, ship, host)
        if has_anomaly_for(p, country) then
            add_experience(leader, defines().SURVEY_XP)
        end
        if system and fully_surveyed(country, system) then
            on_fully_surveyed(system, country, fid, ship)
        end
    end
    -- the holder's LeaveOrbit, unless the fleet is MIA (fleet property bit 5)
    orders.leave_orbit(fid, f)
end

-- ---------------------------------------------------------------------------------------------
-- research_anomaly_order (CResearchAnomalyFleetOrder)

local research_order = {}

-- CShip::IsIdle (0xca4590): at its target coordinate, turned to within 0.1 of its post_move_angle
local function ship_idle(sid)
    local s = world.object("ships", sid)
    if not s then
        return false
    end
    local c, t = world.field(s, "coordinate"), world.field(s, "target_coordinate")
    if type(c) == "table" and type(t) == "table" then
        for _, k in ipairs({ "origin", "x", "y" }) do
            if fixed(world.field(c, k)) ~= fixed(world.field(t, k)) then
                return false
            end
        end
    end
    local r, a = fixed(world.field(s, "rotation") or 0), fixed(world.field(s, "post_move_angle") or 0)
    return math.abs(r - a) <= 10000
end

local function anomaly_planet(o)
    return tonumber(world.field(o.block, "planet"))
end

local function category_of(pid)
    local p = planet(pid)
    local a = p and world.field(p, "anomaly")
    for _, cat in ipairs(categories()) do
        if cat.name == a then return cat end
    end
    return nil
end

-- GetNeededProgress (0xce6b60): SCIENCE_SHIP_ANOMALY_RESEARCH_DAYS at the middle (the count / 2)
-- plus the category's level minus the leader's level and bonus_skill_level, within the list
function research_order.needed(o, fid, f)
    local days = defines().RESEARCH_DAYS
    local n = #days
    local idx = math.floor(n / 2)
    local cat = category_of(anomaly_planet(o))
    local leader = leader_of(f)
    local l = leader and world.object("leaders", leader)
    if cat and l then
        local level = tonumber(defs.field(cat.def.block, "level")) or 1
        idx = idx + level - (tonumber(world.field(l, "level")) or 1) - (tonumber(world.field(l, "bonus_skill_level")) or 0)
        if idx < 0 then idx = 0 end
        if idx > n - 1 then idx = n - 1 end
    end
    return days[idx + 1]
end

-- CAnomalyType::GetResearchAnomalySpeed (0x83fa70): 1 + ship_anomaly_research_speed_mult (+
-- _uninhabitable on an uncolonizable planet), with the ship size's variants, from the ship's
-- modifiers (the category's own research speed modifier not modelled yet)
function research_order.speed(o, f)
    local ship = head_ship(f)
    local M = modifiers("ship", ship)
    local size = ship_size(ship)
    local v = ONE + size_mod(M, size, "ship_anomaly_research_speed_mult", "anomaly_research_speed")
    local p = planet(anomaly_planet(o))
    if p and not is_colonizable(p) then
        v = v + size_mod(M, size, "ship_anomaly_research_speed_mult_uninhabitable", "anomaly_research_speed_uninhabitable")
    end
    return v
end

function research_order.is_possible(o, fid, f)
    local p = planet(anomaly_planet(o))
    return p ~= nil and world.field(p, "anomaly") ~= nil and #ships_of(f) > 0
end

-- IsDone (0xce64d0): the progress reached the days needed (with a leader)
function research_order.is_done(o, fid, f)
    if not leader_of(f) then
        return false
    end
    local p = planet(anomaly_planet(o))
    if not p or world.field(p, "anomaly") == nil then
        return true
    end
    return progress(o) >= research_order.needed(o, fid, f)
end

-- TickOrder (0xce5d90): a science fleet in orbit of the planet, its ship idle, with a leader on the
-- ship advances; else the orbit sub-order
function research_order.tick(o, fid, f, orders)
    if not science_fleet(f) then
        return
    end
    local pid = anomaly_planet(o)
    local ship = head_ship(f)
    if orders.in_orbit_of(fid, f, pid) and ship_idle(ship) then
        orders.clear_sub_order(o)
        -- the leader on this fleet's ship (its location)
        local leader = leader_of(f)
        local loc = leader and world.field(world.object("leaders", leader), "location")
        local on_ship = type(loc) == "table" and world.field(loc, "type") == "ship"
            and world.object("ships", tonumber(world.field(loc, "id")) or -1) ~= nil
            and tonumber(world.field(world.object("ships", tonumber(world.field(loc, "id"))), "fleet")) == fid
        if on_ship then
            set_progress(o, progress(o) + research_order.speed(o, f))
            S.research_days = S.research_days + 1
        end
        return
    end
    orders.tick_orbit_sub_order(o, fid, f, pid)
end

-- StartOrder (0xce5d70): ticked once, the progress set to 0
function research_order.start(o, fid, f, orders)
    research_order.tick(o, fid, f, orders)
    set_progress(o, 0)
end

-- CAnomalyType::OnResearchComplete (0x840350): two draws for the scopes, then OnSuccess: an
-- outcome drawn by weight (NRandomListImpl::ExecuteRandomList: one draw [I]), its max-once flag
-- set, its event fired (anomaly_event: this = the ship, from = the planet; ship_event: from = the
-- ship, fromfrom = the planet)
local function on_research_complete(cat, pid, ship, country)
    RUST.rand()
    RUST.rand()
    local ctx = eval.new_ctx(eval.S("ship", ship), eval.S("planet", pid))
    local list, weights = {}, {}
    for _, o in ipairs(outcomes(cat.def.block)) do
        local w = outcome_weight(o, country, ctx)
        if w > 0 then
            list[#list + 1] = o
            weights[#weights + 1] = math.floor(w / ONE)
        end
    end
    if #list == 0 then
        return
    end
    local r = RUST.rand()
    local i = weighted(weights, r, 1) or 1
    local o = list[i]
    if o.max_once_global then eval.store.set_flag(nil, outcome_flag(o)) end
    if o.max_once then eval.store.set_flag(eval.S("country", country), outcome_flag(o)) end
    if o.event then
        S.outcome_events = S.outcome_events + 1
        local events = package.loaded["simscript.events"] or require("simscript.events")
        local from_ctx = eval.new_ctx(eval.S("planet", pid))
        local ok = pcall(events.fire, o.event, eval.S("ship", ship), from_ctx, o.ship_event and eval.S("ship", ship) or eval.S("planet", pid))
        if not ok then S.outcome_errors = (S.outcome_errors or 0) + 1 end
    end
end

-- Finish (0xce6550): LEADER_SCIENTIST_SUCCESSFUL_ANOMALY_RESEARCH_EXPERIENCE, the outcome, the
-- planet's anomaly gone (and out of its country's list)
function research_order.finish(o, fid, f, orders, host)
    local ships = ships_of(f)
    if #ships == 0 then
        return
    end
    add_experience(leader_of(f), defines().ANOMALY_XP)
    local pid = anomaly_planet(o)
    local cat = category_of(pid)
    local country = world.fleet_owner[fid]
    if cat and country then
        on_research_complete(cat, pid, ships[1], country)
    end
    if planet(pid) then
        set_anomaly(pid, nil)
    end
    S.researched = S.researched + 1
end

survey.TYPES = {
    survey_planet_order = survey_order,
    research_anomaly_order = research_order,
}

function survey.report()
    local parts = {}
    for _, k in ipairs({ "progress_days", "finished", "auto_surveyed", "holders_added", "anomaly_rolls",
        "anomaly_chance_failed", "no_category", "null_spawn", "anomalies_spawned", "fully_surveyed",
        "research_days", "researched", "outcome_events", "on_action_errors", "weight_errors" }) do
        if S[k] and S[k] ~= 0 then parts[#parts + 1] = k .. " " .. S[k] end
    end
    return "surveys: " .. table.concat(parts, ", ")
end

return survey
