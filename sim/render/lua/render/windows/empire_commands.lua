-- render/windows/empire_commands.lua : the empire and government views' commands, run in the
-- simulation's runtime (render-buttons-1's views.rs: a button's `cmd:VIEW:VERB:ARG...` runs the view
-- module's command(VERB, ARG, ...), which is M.run here), where they change the world as the game's commands
-- change the game state (docs/windows/empire.md section 10): the player's country only. Each change
-- goes through engine.world's writers, so the simulation's store and modifiers see it.
--
--   edict add|remove KEY            CAddEdictCommand / CRemoveEdictCommand
--   policy GROUP OPTION             the policy's option (CPoliciesView: the policy command)
--   hire LEADER, dismiss LEADER     CRecruitLeaderCommand, CFireLeaderCommand
--   agenda KEY                      the council's agenda chosen
--   rights SPECIES|default FIELD OPTION, default_species SPECIES
--                                   CSetSpeciesRightsCommand, CSetDefaultSpeciesCommand
--
-- A command that is not valid (the game's IsValid) changes nothing; what it did or why not is
-- returned (and written to stderr).

local world = require("engine.world")

local M = {}

-- the perpetual edicts' end date, as the save writes it
local PERPETUAL = "-5070.07.21"

local function strip(v)
    return type(v) == "string" and (v:gsub('"', "")) or v
end

local function country()
    local cid = require("render.topbar").player()
    return world.object("country", cid), cid
end

local function today()
    return (tostring(world.meta.date or ""):gsub('"', ""))
end

local function stockpile(c)
    return world.path(c, "modules", "standard_economy_module", "resources")
end

-- pays `amount` of `res` from the country's stockpile; false when it has less
local function pay(c, res, amount)
    local r = stockpile(c)
    local have = tonumber(world.field(r, res)) or 0
    if amount > 0 and have < amount then
        return false
    end
    world.set(r, res, have - amount)
    return true
end

-- the game's definitions (engine.defs, loaded with the simulation), by directory
local function def(dir, key)
    local defs = require("engine.defs")
    local d = defs.get(dir, key)
    return d and (d.block or d)
end

-- the entries `{ ... }` of a block whose `key` field is `value`
local function find_entry(block, key, value)
    for _, e in ipairs(world.blocks(block)) do
        if strip(world.field(e, key)) == value then
            return e
        end
    end
    return nil
end

-- days since 1.1.1 of "y.m.d" (360-day years), and a date that many days on
local function days(date)
    local y, m, d = tostring(date or ""):match("^(-?%d+)%.(%d+)%.(%d+)")
    if not y then
        return 0
    end
    return (tonumber(y) * 12 + tonumber(m) - 1) * 30 + tonumber(d) - 1
end

local function add_days(date, n)
    local t = days(date) + n
    local y = math.floor(t / 360)
    local r = t % 360
    return string.format("%d.%02d.%02d", y, math.floor(r / 30) + 1, r % 30 + 1)
end

local C = {}

-- a species' rights reset to the default's (the species' entry removed: the default applies)
function C.rights_reset(args)
    local c = country()
    local mod = world.path(c, "modules", "standard_species_rights_module")
    local list = mod and world.field(mod, "species_rights")
    if args[1] == "default" or not list then
        return "nothing to reset"
    end
    for i, e in ipairs(list) do
        if type(e) == "table" and not e.op and strip(world.field(e, "species_index")) == args[1] then
            world.remove_at(list, i)
            return "reset"
        end
    end
    return "already the default"
end

-- an edict taken: perpetual ones with the sentinel end date and today's start, the cost paid in
-- unity [I: the cost's multipliers (edict_size_effect, edicts_cost_mult) not applied]
function C.edict(args)
    local c = country()
    local how, key = args[1], args[2]
    local edicts = world.child(c, "edicts")
    local have = find_entry(edicts, "edict", key)
    if how == "remove" then
        if not have then
            return "not active"
        end
        -- (CRemoveEdictCommand: no refund; the game swaps the last edict into its place)
        for i, e in ipairs(edicts) do
            if e == have then
                world.remove_at(edicts, i)
                break
            end
        end
        return "removed"
    end
    if have then
        return "already active"
    end
    local d = def("common/edicts", key)
    if not d then
        return "no such edict"
    end
    local res = world.field(d, "resources")
    local cost = res and world.field(res, "cost")
    local amount = tonumber(cost and world.field(cost, "unity")) or 0
    if not pay(c, "unity", amount) then
        return "not enough unity"
    end
    -- (`length`: days; @EdictPerpetual = -1 through the file's variable)
    local length = tonumber(world.field(d, "length"))
    local block = {}
    world.append(block, "edict", key, true)
    if length == nil or length < 0 then
        world.append(block, "date", PERPETUAL, true)
        world.append(block, "perpetual", "yes")
    else
        world.append(block, "date", add_days(today(), length), true)
    end
    world.append(block, "start_date", today(), true)
    world.push(edicts, block)
    return "added"
end

-- a policy's option chosen: active_policies' entry for the group (made if missing), the
-- old option's flag replaced by the new one in policy_flags
function C.policy(args)
    local c = country()
    local group, option = args[1], args[2]
    local policies = world.child(c, "active_policies")
    local e = find_entry(policies, "policy", group)
    if not e then
        return "the country has no such policy"
    end
    local old = strip(world.field(e, "selected"))
    if old == option then
        return "already selected"
    end
    -- (CCountry::CanChangePolicy: never changed, or 10 years since)
    local last = strip(world.field(e, "date"))
    if last and last ~= "" and days(today()) - days(last) < 3600 then
        return "changed less than 10 years ago"
    end
    world.set(e, "selected", '"' .. option .. '"')
    world.set(e, "date", '"' .. today() .. '"')
    local flags = world.child(c, "policy_flags")
    if old then
        world.remove_value(flags, '"' .. old .. '"')
        world.remove_value(flags, old)
    end
    world.append_value(flags, option, true)
    return "selected"
end

-- a leader recruited from the pool: out of the pool, among the owned leaders, the cost paid
-- (the class's cost: unity 100 [I])
function C.hire(args)
    local c, cid = country()
    local id = tonumber(args[1])
    local pool = world.path(c, "modules", "standard_leader_module", "leaders")
    local found = false
    for _, t in ipairs(world.list(pool)) do
        if tonumber(t) == id then
            found = true
        end
    end
    if not found then
        return "not in the pool"
    end
    if not pay(c, "unity", 100) then
        return "not enough unity"
    end
    world.remove_value(pool, tostring(id))
    world.append_value(world.child(c, "owned_leaders"), tostring(id))
    local l = world.object("leader", id)
    if l then
        world.set(l, "country", cid)
        world.set(l, "recruitment_date", '"' .. today() .. '"')
    end
    return "hired"
end

-- a leader dismissed: not the ruler (CFireLeaderCommand::IsValid); out of the owned leaders,
-- off its council position, removed
function C.dismiss(args)
    local c = country()
    local id = tonumber(args[1])
    if tonumber(world.field(c, "ruler")) == id then
        return "the ruler cannot be dismissed"
    end
    world.remove_value(world.child(c, "owned_leaders"), tostring(id))
    for _, pid in ipairs(world.all("council_positions")) do
        local p = world.object("council_positions", pid)
        if p and tonumber(world.field(p, "leader")) == id then
            world.set(p, "leader", 4294967295)
        end
    end
    world.remove("leader", id)
    return "dismissed"
end

-- the council's agenda chosen (its progress kept [I])
function C.agenda(args)
    local c = country()
    local gov = world.field(c, "government")
    if strip(world.field(gov, "council_agenda")) == args[1] then
        return "already the agenda"
    end
    world.set(gov, "council_agenda", '"' .. args[1] .. '"')
    world.set(gov, "council_agenda_progress", 0)
    return "chosen"
end

-- a species' right set (standard_species_rights_module: the species' entry, made from the
-- default's when it has none; `default` the default rights)
function C.rights(args)
    local c = country()
    local who, field, option = args[1], args[2], args[3]
    local mod = world.path(c, "modules", "standard_species_rights_module")
    if not mod then
        return "no species rights"
    end
    local entry
    if who == "default" then
        entry = world.field(mod, "default")
    elseif tonumber(world.field(world.field(mod, "primary"), "species_index")) == tonumber(who) then
        entry = world.field(mod, "primary")
    else
        local list = world.child(mod, "species_rights")
        entry = find_entry(list, "species_index", who)
        if not entry then
            entry = {}
            world.append(entry, "species_index", who)
            for _, e in ipairs(world.field(mod, "default") or {}) do
                if e.op and e.key and e.key.text ~= "species_index" and e.value.text then
                    world.append(entry, e.key.text, e.value.text)
                end
            end
            list[#list + 1] = { value = entry }
            world.wrote(list)
        end
    end
    world.set(entry, field, '"' .. option .. '"')
    return "set"
end

-- the default species (CSetDefaultSpeciesCommand: the module's primary species) [I]
function C.default_species(args)
    local c = country()
    local mod = world.path(c, "modules", "standard_species_rights_module")
    local primary = mod and world.field(mod, "primary")
    if not primary then
        return "no species rights"
    end
    -- (the game keeps a default species per base species in a map the 2210 save leaves empty:
    -- its save key is not known [not done here])
    return "not done: the default species' save field is not known"
end

-- M.run(VERB, ARG, ...): the command, its result (or why it did nothing) for the log
function M.run(verb, ...)
    local list = { ... }
    local f = C[verb]
    local ok, r = pcall(function()
        if not f then
            return "no such command"
        end
        return f(list)
    end)
    local line = string.format("%s %s: %s", verb, table.concat(list, " "), ok and tostring(r) or ("error: " .. tostring(r)))
    io.stderr:write("empire command " .. line .. "\n")
    return line
end

return M
