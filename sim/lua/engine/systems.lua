-- engine/systems.lua : the engine's work, in Lua over the save's world and the vanilla
-- definitions. Two parts:
--
-- - effects: the engine effects the script layer queues (E.push), applied at the barrier
--   (E.flush) to the world in the save's own form;
-- - phases: what each phase of the game's tick does (sim/src/scheduler.rs runs them in the
--   game's order: CGameState::HandleTurnTick, DailyUpdate, MonthlyUpdate, YearlyUpdate). The
--   script's part of a phase (pulses, daily events) runs through the script layer (simscript);
--   the engine's own work (economy, pops, construction, ...) is added here phase by phase, each
--   checked against the game's next save. A phase nothing models yet is counted.

local world = require("engine.world")
local slice = require("engine.slice")

local systems ={ effects = {}, phases = {}, ran = {}, not_modelled = {} }

-- ---------------------------------------------------------------------------------------------
-- effects

function systems.effects.add_resource(t)
    if t.kind ~= "country" then
        return nil
    end
    local c = world.object("country", t.id)
    if not c then
        return nil
    end
    local res = world.child(world.child(world.child(c, "modules"), "standard_economy_module"), "resources")
    world.set(res, t.resource, (tonumber(world.field(res, t.resource)) or 0) + (t.amount or 0))
    return true
end

function systems.effects.add_modifier(t)
    local o = world.object(t.kind, t.id)
    if not o then
        return nil
    end
    local items = world.child(world.child(o, "timed_modifier"), "items")
    local item = {}
    world.append(item, "modifier", tostring(t.source), true)
    world.append(item, "days", t.days or -1)
    items[#items + 1] = item
    return true
end

function systems.effects.give_technology(t)
    if t.kind ~= "country" or not world.object("country", t.id) then
        return nil
    end
    return require("engine.research").add_technology(t.id, tostring(t.tech))
end

function systems.effects.kill_leader(t)
    local l = world.object("leader", t.id)
    if not l then
        return nil
    end
    local owner = world.object("country", tonumber(world.field(l, "country")))
    local owned = owner and world.field(owner, "owned_leaders")
    if type(owned) == "table" then
        world.remove_value(owned, t.id)
    end
    world.remove("leader", t.id)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- phases: (kind, name) -> function(host); host is the script layer (simscript.host)

local function each_country(f)
    for _, id in ipairs(world.all("country")) do
        slice.check("country")
        f(id)
    end
end

-- ---------------------------------------------------------------------------------------------
-- countdowns: what counts its days on the objects themselves

-- flags with a duration (`flags = { name = { flag_date = <hour set> flag_days = <days left> } }`):
-- a day less each day, gone at 0 (CPdxIntegerFlags::UpdateFlags in the daily task graph)
local function count_down_flags(obj)
    local flags = world.field(obj, "flags")
    if type(flags) ~= "table" then
        return
    end
    for i = #flags, 1, -1 do
        local e = flags[i]
        if e.op and e.value.text == nil then
            local days_e
            for _, f in ipairs(e.value) do
                if f.op and f.key.text == "flag_days" then
                    days_e = f
                end
            end
            local days = days_e and tonumber(days_e.value.text)
            if days and days > 0 then
                if days <= 1 then
                    world.remove_entry(flags, e)
                else
                    world.set_entry(e.value, days_e, days - 1)
                end
            end
        end
    end
end

-- timed modifiers (`timed_modifier = { items = { { modifier = x days = n } } }`, -1 for ever): a
-- day less each day, gone at 0
local function count_down_modifiers(obj)
    local items = world.field(world.field(obj, "timed_modifier"), "items")
    if type(items) ~= "table" then
        return
    end
    for i = #items, 1, -1 do
        local item = items[i]
        if type(item) == "table" and not item.text and not item.op then
            for _, f in ipairs(item) do
                if f.op and f.key.text == "days" then
                    local days = tonumber(f.value.text)
                    if days and days > 0 then
                        if days <= 1 then
                            world.remove_entry(items, item)
                        else
                            world.set_entry(item, f, days - 1)
                        end
                    end
                end
            end
        end
    end
end

local function each_object(stores, f)
    for _, name in ipairs(stores) do
        local store = world.stores[name]
        for _, id in ipairs(world.ids[name] or {}) do
            local obj = store[id]
            if obj then
                slice.tick(name)
                f(obj)
            end
        end
    end
end

-- every store but the ones the countries and colonies phases count down
local OTHER_STORES
local function other_stores()
    if not OTHER_STORES then
        OTHER_STORES = {}
        for name in pairs(world.stores) do
            if name ~= "country" and name ~= "planet" then
                OTHER_STORES[#OTHER_STORES + 1] = name
            end
        end
        table.sort(OTHER_STORES)
    end
    return OTHER_STORES
end

local P = systems.phases

-- a module of the engine that may not be written yet: the module, or nil when there is no such file
-- (an error inside one that is there is raised as usual)
local present = {}
local function optional(name)
    if present[name] == nil then
        present[name] = package.searchpath(name, package.path) ~= nil
    end
    return present[name] and require(name) or nil
end
-- a function of an optional module, called when it is there (after a check named by both: what
-- the call takes before its own first check is learned there, docs/frame_timing.md)
local sites = {}
local function call_optional(name, fn, ...)
    local m = optional(name)
    if m and m[fn] then
        local by = sites[name]
        if not by then
            by = {}
            sites[name] = by
        end
        local site = by[fn]
        if not site then
            site = name .. "." .. fn
            by[fn] = site
        end
        slice.check(site)
        return true, m[fn](...)
    end
    return false
end

-- CCountryAI::UpdateAttitudesThreaded, first in the day: the AIs' attitudes (engine.ai.attitudes,
-- docs/ai.md section 3)
P["daily.ai_attitudes"] = function(host, date)
    call_optional("engine.ai.attitudes", "daily", host, date)
end
P["daily.script_state_expiry"] = function(host)
    each_object({ "country", "planet" }, count_down_flags)
    each_object(other_stores(), count_down_flags)
    host.daily_script_state()
end
-- CCountry::DailyUpdateSelfDontReadOthers: the timed modifiers; CCountry::DailyUpdateOnlyChangeSafePrivate:
-- every 30 days a country's ethics attraction (engine.ethics: UpdateCountryEthicsSafePrivate, no draws)
P["daily.countries_parallel"] = function(host, date)
    each_object({ "country" }, count_down_modifiers)
    call_optional("engine.ethics", "countries_daily", host, date)
    -- lambda_26 to lambda_28 of the day (visited systems, sensor coverage and intel levels, known
    -- hyperlanes, the shared intel, terra incognita, the fleets in sensor range: engine.exploration;
    -- its first call also runs the load's own pass, CGameState::RecalculateCachedData)
    call_optional("engine.exploration", "countries_daily", host, date)
end
-- NColonyUpdate::DailyParallelUpdate: the timed modifiers; the colonies' own day (engine.colonies,
-- once it is there: stability, amenities, happiness, crime, ...)
P["daily.colonies_parallel"] = function(host, date)
    each_object({ "planet" }, count_down_modifiers)
    call_optional("engine.colonies", "daily_parallel", host, date)
end
P["daily.galaxy"] = function()
    each_object(other_stores(), count_down_modifiers)
end
-- CConstructionManager::DailyUpdate: the construction queues (engine.construction)
P["daily.construction_manager"] = function(host, date)
    require("engine.construction").daily(date)
end
-- CCountry::DailyUpdateSerial: the country's events, then (after diplomacy and elections) its
-- research (engine.research)
P["daily.countries_serial"] = function(host, date)
    each_country(function(id)
        -- CCountry::UpdateContacts -> CFirstContactsData::DailyUpdate: the country's first
        -- contacts (engine.first_contact), before its events
        call_optional("engine.first_contact", "country_daily", host, date, id)
        -- then the deposit holders the day's shared intel surveyed or unsurveyed (_NewSurveyed,
        -- _NewUnsurveyed: AddSurveyedDepositHolder, RemoveSurveyedDepositHolder; engine.exploration)
        call_optional("engine.exploration", "country_serial", host, date, id)
        host.scope_daily_events("country", id)
    end)
    require("engine.research").daily(host, date)
end
-- NColonyUpdate::DailySerialUpdate: the planets' daily events; the colonies' serial day
-- (engine.colonies, once it is there)
P["daily.colonies_serial"] = function(host, date)
    for _, id in ipairs(world.all("planet")) do
        slice.tick("systems.lua:232")
        if world.pop_groups_of[id] then
            slice.check("planet events")
            host.scope_daily_events("planet", id)
        end
    end
    call_optional("engine.colonies", "daily_serial", host, date)
    -- NColonyUpdate::MonthlyOrDailyUpdatePopJobsInColony (0x28ecf80) from CGameState::DailyUpdate:
    -- the jobs update twice over the colonies (engine.jobs; its place in the day [I])
    call_optional("engine.jobs", "daily", host, date)
end
-- CModifierNodeManager::Update in the monthly update: the world's modifier graph brought up to date
-- (when the modifiers come from the world: engine.economy.world_source; only what changed,
-- engine.modifiers.incremental, docs/modifier_incremental.md)
P["monthly.modifiers"] = function()
    local engine = package.loaded["engine"]
    local source = engine and engine.modifier_source
    if source and source.rebuild then
        source.rebuild()
    end
end
-- CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>: every country's budget from its economic
-- units through the modifiers, and the month's balance to its stockpile (engine.economy), once the
-- economy has a modifier source (engine.load: the graph built from the world, or the capture)
P["monthly.budget"] = function()
    local economy = package.loaded["engine.economy"]
    if economy and economy.has_modifier_source and economy.has_modifier_source() then
        economy.monthly()
        systems.ran["monthly.budget (economy)"] = (systems.ran["monthly.budget (economy)"] or 0) + 1
    end
end
-- CCountry::MonthlyUpdateStrategy (before it, in the game a parallel pass after the budget): the
-- AIs' strategic data (engine.ai.strategy); then CCountry::MonthlyUpdateSerial: the leaders'
-- experience (engine.leaders), the monthly pulse
P["monthly.countries_serial"] = function(host, date)
    -- the situations' monthly progress (engine.situations: the game's parallel lambda right after
    -- the budget, before the strategy pass; no draws)
    call_optional("engine.situations", "monthly_progress", host, date)
    call_optional("engine.ai.strategy", "monthly", host, date)
    require("engine.leaders").monthly()
    each_country(function(id)
        -- CCountry::MonthlyUpdateSerial (0x6f4b10): one draw, the pulse's scope made from it
        -- (CEventScope position H(draw)); the pulse only for a country type with has_pulse_events
        local seed = RUST.rand()
        -- CCountryEventManager::MonthlyUpdateSerial: the country's situations, before its pulse
        call_optional("engine.situations", "country_monthly", host, date, id)
        if systems.has_pulse_events(id) then
            host.on_action("on_monthly_pulse_country", "country", id, seed)
        end
    end)
end
-- NColonyUpdate::MonthlyUpdate: growth and decline of the colonies' pops (engine.pops, once it is
-- there)
P["monthly.colonies"] = function(host, date)
    local pops = optional("engine.pops")
    if pops then
        pops.monthly(host, date)
    else
        systems.not_modelled["monthly.colonies"] = (systems.not_modelled["monthly.colonies"] or 0) + 1
    end
end
-- CPopGroup::DailyUpdate*: the day's housing of the pop groups and colonies (engine.pops; no random
-- draws, so it keeps to the game's parallel phase)
P["daily.pop_groups"] = function(host, date)
    local pops = optional("engine.pops")
    local ran = false
    if pops and pops.daily then
        pops.daily(host, date)
        ran = true
    end
    -- the pop groups' happiness, power, crime, amenities usage (engine.colonies; no random draws)
    if call_optional("engine.colonies", "pop_groups_daily", host, date) then
        ran = true
    end
    -- the pop groups' ethics drift and faction-change remnant (engine.ethics: EthicChangeSafePrivate,
    -- CheckPopFactionChange, then CPopGroup::DailyUpdateSerial's ethics part; the day's pool, no
    -- global draws: OnEthicsDivergence's two are counted, not made, until a serial pop group phase)
    if call_optional("engine.ethics", "pop_groups_daily", host, date) then
        ran = true
    end
    if not ran then
        systems.not_modelled["daily.pop_groups"] = (systems.not_modelled["daily.pop_groups"] or 0) + 1
    end
end
-- the fleets' part of the ships, fleets and armies phase: CFleet::DailyUpdateSerial ->
-- CFleet::HandleOrders, fleet by fleet (engine.fleets.orders: the current orders ticked and
-- finished, the next ones started; docs/fleet_orders.md)
P["daily.ships_fleets_armies"] = function(host, date)
    call_optional("engine.fleets.orders", "daily", host, date)
end
-- CGameState::MicroUpdate, every tick: first the fleet phase's movement (engine.fleets.movement:
-- CFleetMovementManager::MicroUpdate, its draws for the systems left and entered; combat is not
-- modelled), then the ship pool drawn as the game draws it (UpdateShipParallel:
-- CRandom::GetIntegersForMacro of one value per live ship, every entry of the ships store, after
-- the fleet phase), so the stream's position stays the game's. Its values seed only the ships
-- whose fleet is in combat (headless/README.md, "The random pools, traced"): with no combat
-- modelled, the draws are skipped, not made.
P["micro.update"] = function(host, date)
    call_optional("engine.fleets.movement", "tick", host, date)
    RUST.skip(#world.all("ship"))
end
-- CGameState::ProcessAI: the AI's decisions (engine.ai, once it is there; docs/ai.md)
P["ai.process"] = function(host, date)
    local ai = optional("engine.ai")
    if ai then
        ai.process(host, date)
    else
        systems.not_modelled["ai.process"] = (systems.not_modelled["ai.process"] or 0) + 1
    end
end
-- the end of CGameState::MonthlyUpdate (0x261620): one draw, the pulse's scope made from it
P["monthly.on_monthly_pulse"] = function(host)
    host.on_action("on_monthly_pulse", "none", 0, RUST.rand())
end
-- CGameState::YearlyUpdate (0x262ee0): one draw for the global pulses' scope (the yearly one, then
-- the longer ones of the year); then each country whose type has_pulse_events: one draw, its
-- pulses in that scope (CCountryType flags bit 2)
P["yearly.on_yearly_pulse"] = function(host, date)
    local year = date and date.year or 0
    local longer = {}
    for _, p in ipairs({ { 2, "on_bi_yearly_pulse" }, { 5, "on_five_year_pulse" }, { 10, "on_decade_pulse" } }) do
        -- the longer pulses, by the year (2200 is the start)
        if (year - 2200) % p[1] == 0 then longer[#longer + 1] = p[2] end
    end
    local seed = RUST.rand()
    host.on_action("on_yearly_pulse", "none", 0, seed)
    for _, name in ipairs(longer) do host.on_action(name, "none", 0, seed) end
    each_country(function(id)
        if systems.has_pulse_events(id) then
            local cseed = RUST.rand()
            host.on_action("on_yearly_pulse_country", "country", id, cseed)
            for _, name in ipairs(longer) do host.on_action(name .. "_country", "country", id, cseed) end
        end
    end)
end

-- a country whose type gets the country pulses (common/country_types: has_pulse_events, no by default)
local pulse_types = {}
function systems.has_pulse_events(id)
    local t = world.field(world.object("country", id), "type")
    t = type(t) == "string" and t:gsub('^"(.*)"$', "%1") or nil
    if not t then return false end
    local v = pulse_types[t]
    if v == nil then
        local d = require("engine.defs").get("common/country_types", t)
        v = d ~= nil and require("engine.defs").field(d.block, "has_pulse_events") == "yes"
        pulse_types[t] = v
    end
    return v
end

-- systems.phase(kind, name, host, date) -> whether something models it
function systems.phase(kind, name, host, date)
    local key = kind .. "." .. name
    local f = P[key]
    if not f then
        systems.not_modelled[key] = (systems.not_modelled[key] or 0) + 1
        return false
    end
    systems.ran[key] = (systems.ran[key] or 0) + 1
    f(host, date)
    return true
end

return systems
