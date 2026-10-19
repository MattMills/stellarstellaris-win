-- engine/draws.lua : draws of the game's synchronized generator (CRandom, RUST.rand) made by engine
-- updates whose own work the simulation does not model, made where the game makes them so that the
-- stream's position stays the game's (docs/random.md, "In the simulation"). Each value seeds an
-- event scope or a roll whose outcome is not modelled here: the draws are skipped (RUST.skip), the
-- position advanced. Addresses are the Linux 4.5.2 build's; the counts and their order were checked
-- against the headless game's trace of every draw (headless/README.md, HEADLESS_TRACE) [V].
--
--   draws.factions(country)                 CPopFactionsCountryModule::DailyUpdateSerial
--   draws.special_projects(country, date)   CCountryEventManager::DailyUpdateSerial's projects
--   draws.envoys(country)                   CCountry::UpdateEnvoys
--   draws.planets()                         CPlanetManager::DailyUpdate
--   draws.archaeology()                     CArchaeologicalSiteManager::DailyUpdate
--   draws.divergence(n) / draws.flush()     CPopGroup::OnEthicsDivergence, made after the parallel phase
--   draws.monthly_modules(country)          CCountry::MonthlyUpdateSerial: the modules' (vivarium)
--   draws.monthly_after_pulse_draw(country) CCountry::MonthlyUpdateSerial: personality, integration
--   draws.sensor_snapshot()                 the fleets each country saw, before the day's sensor pass
--   draws.fleets_detected(country)          CCountry::DailyUpdateNewFleetsDetectedSerial

local world = require("engine.world")

local draws = {
    stats = { factions = 0, abort = 0, fail = 0, envoys = 0, planets = 0, sites = 0, divergence = 0,
        vivarium = 0, personality = 0, integration = 0, detected = 0 },
    pending = 0,
}

local function skip(n, what)
    if n > 0 then
        RUST.skip(n)
        draws.stats[what] = draws.stats[what] + n
    end
end

-- the days of a date ("2210.01.23" or { year, month, day }), 30-day months
local function days(d)
    if type(d) == "table" then
        return d.year * 360 + (d.month - 1) * 30 + (d.day - 1)
    end
    local y, m, dd = tostring(d or ""):match("(%d+)%.(%d+)%.(%d+)")
    return y and tonumber(y) * 360 + (tonumber(m) - 1) * 30 + (tonumber(dd) - 1) or nil
end

-- CPopFactionsCountryModule::DailyUpdateSerial (0x1ea0b50) -> DestroyFactions (0x1e9d230): one draw at
-- its start (CRandom::GetIntegerForMacro, the event scope of the factions it destroys), for a country
-- with standard_pop_factions_module (the 12 regular empires of 2210: 12 draws a day). The modules'
-- daily updates come first in CCountry::DailyUpdateSerial (0x235486d), before the first contacts.
local function has_module(country, name)
    local c = world.object("country", country)
    local modules = c and world.field(c, "modules")
    return type(modules) == "table" and type(world.field(modules, name)) == "table"
end
function draws.factions(country)
    if has_module(country, "standard_pop_factions_module") then
        skip(1, "factions")
    end
end

-- CCountryEventManager::DailyUpdateSerial (0x2418e00), its first loop: the country's special projects
-- (`events = { special_project = { id special_project status ai_research_date ... } }`), in order:
-- - every project not aborted: CSpecialProjectInstance::ShouldAbort (0x1f9de20), two draws (the
--   project's scope and the country's), then the type's abort trigger (not evaluated here);
-- - a pending project (no status: the AI has not started it; status 0): its day counter (+0x1c)
--   counted down, then ShouldFail (0x1f9daf0), two draws while the counter runs. The game drew them
--   on 2210.01.02 to 01.24 for ai_research_date 2210.01.23 [V]: up to the day after that date (the
--   counter's start from the date is inferred from that one project [I]).
-- An in-progress project that can progress draws nothing more.
function draws.special_projects(country, date)
    local c = world.object("country", country)
    local events = c and world.field(c, "events")
    if type(events) ~= "table" then
        return
    end
    local today = days(date)
    for _, p in ipairs(world.fields(events, "special_project")) do
        if type(p) == "table" then
            local status = world.field(p, "status")
            if not (type(status) == "string" and status:find("abort")) then
                skip(2, "abort")
                if status == nil then
                    local due = days(world.field(p, "ai_research_date"))
                    if due and today and today <= due + 1 then
                        skip(2, "fail")
                    end
                end
            end
        end
    end
end

-- CCountry::UpdateEnvoys (0x2357190), after the country's research (CCountry::DailyUpdateSerial
-- 0x2354c57): one draw (CLeaderClassDatabase::Randomize, the class of a new envoy) for every
-- country, every day. The envoys it then makes up to the allowance (CGameState::CreateNewLeader,
-- about 11 draws each) are not modelled.
function draws.envoys(country)
    skip(1, "envoys")
end

-- CPlanetManager::DailyUpdate (0x2a86e20) -> CPlanet::DailyUpdateUnhabitableSerial (0x2a6c410) ->
-- DailyUpdateSerialHandleOrbitalBombardment (0x2a6cad0): one draw at its start (the bombardment's
-- scope) for each planet with an owner (45 a day in 2210, the owned planets) [V]; an unowned planet
-- with the CAN_HAVE_SCRIPTED_BOMBARDMENT_FLAG flag draws too (not counted here). After the
-- countries' serial update, before the colonies' (CGameState::DailyUpdate 0x1b21901).
local owned_cache = { day = nil, n = 0 }
function draws.planets(date)
    local today = days(date)
    if owned_cache.day ~= today then
        local n = 0
        for _, id in ipairs(world.all("planet")) do
            local p = world.object("planet", id)
            if p and world.field(p, "owner") ~= nil then
                n = n + 1
            end
        end
        owned_cache.day, owned_cache.n = today, n
    end
    skip(owned_cache.n, "planets")
end

-- CArchaeologicalSiteManager::DailyUpdate (0x2226ea0), in the day's last updates (after the market):
-- a pool of one value per site (CRandom::GetIntegersForMacro, the sites' excavation rolls through a
-- CCrudeRandom each: not modelled), then each site's DailyUpdateSerial (0x2218570), one draw at its
-- start (the site's scope): two per site a day [V].
function draws.archaeology()
    local n = #world.all("sites")
    skip(2 * n, "sites")
end

-- CCountry::MonthlyUpdateSerial (0x235b930), around the pulse's own draw (systems.lua):
-- - before it, the modules' monthly updates: CGrandArchiveCountryModule::BreedVivariumCritters
--   (0x1c61f60), one draw at its start, for a country with standard_grand_archive_module (12 a
--   month in 2210) [V];
-- - after it, a country without an AI personality has one drawn (0x235c301, then
--   CCountry::CalculatePersonality: 31 a month in 2210, the countries with no `personality`) [V];
--   one whose personality no longer applies (CAIPersonality::CalcWeight 0) too (not checked here);
-- - then CCountry::HandleForcedSpeciesIntegration (0x235c8b0): one draw at its start, every
--   country [V].
function draws.monthly_modules(country)
    if has_module(country, "standard_grand_archive_module") then
        skip(1, "vivarium")
    end
end
function draws.monthly_after_pulse_draw(country)
    local c = world.object("country", country)
    if c and world.field(c, "personality") == nil then
        skip(1, "personality")
    end
    skip(1, "integration")
end

-- CCountry::DailyUpdateNewFleetsDetectedSerial (0x2356990), in the country's serial day after its
-- events and diplomacy, before its research: for each fleet CCountry::UpdateFleetsInSensorRange
-- found in sensor range today and not yesterday (sorted by id), that is alive, not the country's
-- own and, in FTL, jumping to or from the country's space: contact made if new (not modelled),
-- then two draws for the scopes and on_fleet_detected (this = the country, from = the fleet)
-- [V]. A fleet flag (CFleet +0x1260 bit 2) skips the event: not modelled [I].
local seen_before = {}
function draws.sensor_snapshot()
    seen_before = {}
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        local set = {}
        for _, fid in ipairs(world.list(c and world.field(c, "sensor_range_fleets") or nil)) do
            set[tonumber(fid)] = true
        end
        seen_before[cid] = set
    end
end
local function system_owner(sid)
    return sid and world.system_owner and world.system_owner[sid]
end
function draws.fleets_detected(country, host)
    local before = seen_before[country]
    local c = world.object("country", country)
    if not before or not c then
        return
    end
    local new = {}
    for _, fid in ipairs(world.list(world.field(c, "sensor_range_fleets") or nil)) do
        fid = tonumber(fid)
        if fid and not before[fid] then
            new[#new + 1] = fid
        end
    end
    table.sort(new)
    for _, fid in ipairs(new) do
        local f = world.object("fleet", fid)
        local owner = world.fleet_owner and world.fleet_owner[fid]
        local ok = f ~= nil and owner ~= country
        local mm = f and world.field(f, "movement_manager")
        if ok and mm and world.field(mm, "state") == "move_galaxy" then
            local jump = world.field(mm, "last_ftl_jump")
            local from = jump and tonumber(world.field(jump, "from"))
            local to = jump and tonumber(world.field(jump, "to"))
            ok = system_owner(to) == country or system_owner(from) == country
        end
        if ok then
            RUST.rand()
            RUST.rand()
            draws.stats.detected = draws.stats.detected + 2
            if host and host.on_action_scopes then
                host.on_action_scopes("on_fleet_detected", "country", country, "fleet", fid)
            else
                local events = package.loaded["simscript.events"] or require("simscript.events")
                local eval = package.loaded["simscript.eval"] or require("simscript.eval")
                pcall(events.on_action, "on_fleet_detected", eval.S("country", country), eval.new_ctx(eval.S("fleet", fid)))
            end
        end
    end
end

-- CPopGroup::OnEthicsDivergence (0x684640): two draws (the event scope of
-- on_daily_pop_ethics_divergence) for a pop group whose ethics changed. The game makes them in
-- CPopGroup::DailyUpdateSerial, right after the pop groups' parallel update; the simulation's pop
-- group phase is a parallel one (engine.ethics counts them there), so they are made at the start of
-- the next serial phase (ships, fleets and armies), where nothing draws before them.
function draws.divergence(n)
    draws.pending = draws.pending + n
end
function draws.flush()
    local n = draws.pending
    draws.pending = 0
    skip(n, "divergence")
end

function draws.report()
    local s = draws.stats
    return string.format("engine draws (not modelled otherwise): %d factions, %d special project aborts, %d fails, "
        .. "%d envoys, %d planets, %d archaeological sites, %d ethics divergences; monthly %d vivarium, "
        .. "%d personalities, %d species integrations; %d fleet detection draws",
        s.factions, s.abort, s.fail, s.envoys, s.planets, s.sites, s.divergence, s.vivarium, s.personality,
        s.integration, s.detected)
end

return draws
