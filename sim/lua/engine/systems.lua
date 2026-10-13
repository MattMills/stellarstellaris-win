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

local systems = { effects = {}, phases = {}, ran = {}, not_modelled = {} }

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
    world.append(item, "modifier", '"' .. tostring(t.source) .. '"')
    world.append(item, "days", t.days or -1)
    items[#items + 1] = item
    return true
end

function systems.effects.give_technology(t)
    local c = t.kind == "country" and world.object("country", t.id)
    if not c then
        return nil
    end
    local status = world.child(c, "tech_status")
    world.append(status, "technology", '"' .. tostring(t.tech) .. '"')
    world.append(status, "level", 1)
    return true
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
        f(id)
    end
end

local P = systems.phases
P["daily.script_state_expiry"] = function(host)
    host.daily_script_state()
end
P["daily.countries_serial"] = function(host)
    each_country(function(id) host.scope_daily_events("country", id) end)
end
P["daily.colonies_serial"] = function(host)
    for _, id in ipairs(world.all("planet")) do
        if world.pop_groups_of[id] then
            host.scope_daily_events("planet", id)
        end
    end
end
P["monthly.countries_serial"] = function(host)
    each_country(function(id) host.on_action("on_monthly_pulse_country", "country", id) end)
end
P["monthly.on_monthly_pulse"] = function(host)
    host.on_action("on_monthly_pulse", "none", 0)
end
P["yearly.on_yearly_pulse"] = function(host, date)
    host.on_action("on_yearly_pulse", "none", 0)
    each_country(function(id) host.on_action("on_yearly_pulse_country", "country", id) end)
    -- the longer pulses, by the year (2200 is the start)
    local year = date and date.year or 0
    for _, p in ipairs({ { 2, "on_bi_yearly_pulse" }, { 5, "on_five_year_pulse" }, { 10, "on_decade_pulse" } }) do
        if (year - 2200) % p[1] == 0 then
            host.on_action(p[2], "none", 0)
            each_country(function(id) host.on_action(p[2] .. "_country", "country", id) end)
        end
    end
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
