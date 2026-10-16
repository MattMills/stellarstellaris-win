-- render/windows/empire_commands.lua : the empire and government views' commands, run in the
-- simulation's runtime (render-buttons-1's views.rs: a button's `cmd:VIEW:VERB:ARG...` runs the view
-- module's command(VERB, ARG, ...), which is M.run here), where they change the world as the game's commands
-- change the game state (docs/windows/empire.md section 10): the player's country only. Each change
-- goes through engine.world's writers, so the simulation's store and modifiers see it.
--
--   edict add|remove KEY            CAddEdictCommand / CRemoveEdictCommand
--   policy GROUP OPTION             the policy's option (CPoliciesView: the policy command)
--   hire LEADER, dismiss LEADER     CRecruitLeaderCommand, CFireLeaderCommand
--   assign LEADER KIND ID           the leader's job (CAssignLeaderCommand and its kin)
--   agenda KEY, launch              the council's agenda chosen, CFinishAgendaCommand
--   rights SPECIES|default FIELD OPTION, rights_reset SPECIES, default_species SPECIES
--                                   CSetSpeciesRightsCommand, CSetDefaultSpeciesCommand
--   reform AUTHORITY CIVIC...       CChangeGovernmentCommand
--   rename KIND ID TEXT             the rename dialogs' commands
--
-- A command that is not valid (the game's IsValid) changes nothing; what it did or why not is
-- returned (and written to stderr).

local world = require("engine.world")

local M = {}

-- the perpetual edicts' end date, as the save writes it
local PERPETUAL = "-5070.07.21"
-- an id that names nothing (a council position's empty `leader`)
local NONE = 4294967295

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

-- the game's definitions (engine.defs, loaded with the simulation), by directory: the block and
-- its file
local function def(dir, key)
    local defs = require("engine.defs")
    local d = defs.get(dir, key)
    if not d then
        return nil
    end
    return d.block or d, d.file
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
M.days, M.add_days = days, add_days

-- the country's modifiers (the simulation's economy: engine.economy's modifier source), and
-- 1 + one of them
local function modifiers(cid)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers("country", cid) or {}
end

local function mult(Mod, name)
    return 1 + (tonumber(Mod[name]) or 0)
end

-- the simulation's script layer (simscript.eval); nil when the runtime has none
local function script()
    local ok, eval = pcall(function()
        return package.loaded["simscript.eval"] or require("simscript.eval")
    end)
    return ok and eval or nil
end

-- an effect block of a definition run in a scope (eval.effect: the script layer queues the engine's
-- effects and applies its own); what happened, for the log
local function run_effect(block, kind, id, file)
    if type(block) ~= "table" then
        return nil
    end
    local eval = script()
    if not eval then
        return "no script layer: effect not run"
    end
    local ok, err = pcall(function()
        eval.effect(block, eval.new_ctx(eval.S(kind, id), nil, nil, file))
    end)
    if not ok then
        io.stderr:write("empire command: effect: " .. tostring(err) .. "\n")
        return "effect failed"
    end
    return "effect run"
end

-- a definition's number field, its file's scripted variables (`@x`) through the script layer
local function number(block, key, file)
    local e = world.entry(block or {}, key)
    if not e or not e.value or not e.value.text then
        return nil
    end
    local n = tonumber(e.value.text)
    if n then
        return n
    end
    local eval = script()
    local ok, v = pcall(function()
        return eval.value(e.value, eval.new_ctx(nil, nil, nil, file), e)
    end)
    return ok and tonumber(v) or nil
end

-- an on_action fired in a scope (simscript.events)
local function on_action(name, kind, id)
    local eval = script()
    if eval then
        pcall(function()
            require("simscript.events").on_action(name, eval.S(kind, id))
        end)
    end
end

-- an economic unit's cost table (`resources = { category = C cost = { R = v multiplier = ... } }`)
-- in a scope, with the category's cost modifiers (CEconomicUnitBase::ApplyModifiersToTable:
-- engine.economy.apply, `<category>_cost_mult` and the parents' chain)
local function cost_table(block, file, kind, id, cid)
    if type(block) ~= "table" then
        return {}
    end
    local economy = require("engine.economy")
    local eval = script()
    local t = economy.template(block, file)
    if not t or not eval then
        return {}
    end
    local ctx = economy.ctx(kind, id, file)
    local base = {}
    for _, b in ipairs(t.cost) do
        if b.trigger == nil or eval.trigger(b.trigger, ctx) then
            local m = b.mult and economy.value_of(b.mult, ctx) or 1
            for _, rv in ipairs(b.values) do
                base[rv[1]] = (base[rv[1]] or 0) + economy.value_of(rv[2], ctx) * m
            end
        end
    end
    return economy.apply(t.category, "cost", base, 1, modifiers(cid), ctx)
end
M.cost_table = cost_table

-- whether the stockpile holds a cost table, and the table paid (CCountry::RemoveResources)
local function can_pay(c, cost)
    local r = stockpile(c)
    for res, v in pairs(cost) do
        if v > 0 and (tonumber(world.field(r, res)) or 0) < v then
            return false, res
        end
    end
    return true
end

local function pay_table(c, cost)
    local r = stockpile(c)
    for res, v in pairs(cost) do
        if v ~= 0 then
            local have = tonumber(world.field(r, res)) or 0
            world.set(r, res, math.floor((have - v) * 1000 + 0.5) / 1000)
        end
    end
end

local function cost_text(cost)
    local l = {}
    for res, v in pairs(cost) do
        l[#l + 1] = string.format("%s %.2f", res, v)
    end
    table.sort(l)
    return table.concat(l, ", ")
end

local C = {}

-- a species' rights reset to the default's (the species' entry removed: the default applies);
-- not while a right is locked (CCountryResetSpeciesRightsCommand::IsValid:
-- CalcNextAllowedRightsChangeDate)
function C.rights_reset(args)
    local c = country()
    local mod = world.path(c, "modules", "standard_species_rights_module")
    local list = mod and world.field(mod, "species_rights")
    if args[1] == "default" or not list then
        return "nothing to reset"
    end
    for i, e in ipairs(list) do
        if type(e) == "table" and not e.op and strip(world.field(e, "species_index")) == args[1] then
            local until_ = M.locked_until(e)
            if until_ then
                return "locked until " .. until_
            end
            world.remove_at(list, i)
            return "reset"
        end
    end
    return "already the default"
end

-- an edict's cost (CCountry::CalcEdictCost: the economic unit's cost table, its multiplier
-- `value:edict_size_effect` in the country's scope, the `edicts` category's cost modifiers; each
-- resource capped at EDICT_MAX_RESOURCE_COST) [I: the unity ambitions' tradition-priced cost
-- not taken]
function M.edict_cost(cid, key)
    local d, file = def("common/edicts", key)
    local cost = cost_table(d and world.field(d, "resources"), file, "country", cid, cid)
    for res, v in pairs(cost) do
        cost[res] = math.min(v, 1000000)
    end
    return cost
end

-- an edict taken (CCountry::AddEdict): the cost paid, its `effect` run, on_edict_activated;
-- perpetual ones with the sentinel end date, others `length` × (1 + edict_length_mult) days.
-- Removed (CCountry::RemoveEdict): the last edict swapped into its place, no refund, its
-- `on_disabled` run
function C.edict(args)
    local c, cid = country()
    local how, key = args[1], args[2]
    local edicts = world.child(c, "edicts")
    local have = find_entry(edicts, "edict", key)
    local d, file = def("common/edicts", key)
    if how == "remove" then
        if not have then
            return "not active"
        end
        local list = {}
        for i, e in ipairs(edicts) do
            if not e.op and not e.text then
                list[#list + 1] = i
            end
        end
        for n, i in ipairs(list) do
            if edicts[i] == have then
                local last = list[#list]
                if last ~= i then
                    edicts[i] = edicts[last]
                end
                world.remove_at(edicts, last)
                break
            end
        end
        local r = run_effect(d and world.field(d, "on_disabled"), "country", cid, file)
        return "removed" .. (r and ("; on_disabled " .. r) or "")
    end
    if have then
        return "already active"
    end
    if not d then
        return "no such edict"
    end
    local cost = M.edict_cost(cid, key)
    local ok, short = can_pay(c, cost)
    if not ok then
        return "not enough " .. short
    end
    pay_table(c, cost)
    local r = run_effect(world.field(d, "effect"), "country", cid, file)
    on_action("on_edict_activated", "country", cid)
    -- (CEdict::GetLengthInDays: `length` ≤ 0, @EdictPerpetual = -1 through the file's variable,
    -- is perpetual)
    local length = number(d, "length", file)
    local block = {}
    world.append(block, "edict", key, true)
    if length == nil or length <= 0 then
        world.append(block, "date", PERPETUAL, true)
        world.append(block, "perpetual", "yes")
    else
        length = math.floor(length * mult(modifiers(cid), "edict_length_mult") + 0.5)
        world.append(block, "date", add_days(today(), length), true)
    end
    world.append(block, "start_date", today(), true)
    world.push(edicts, block)
    return "added, paid " .. cost_text(cost) .. (r and ("; " .. r) or "")
end

-- a policy group's option block (common/policies GROUP's `option = { name = X }`)
local function policy_option(group, option)
    local d, file = def("common/policies", group)
    for _, e in ipairs(type(d) == "table" and d or {}) do
        if e.op and e.key and e.key.text == "option" and type(e.value) == "table"
            and strip(world.field(e.value, "name")) == option then
            return e.value, file
        end
    end
    return nil, file
end

-- a policy's option chosen (CCountry::ChangePolicy): active_policies' entry, its date, the old
-- option's flags replaced by the new one's in policy_flags, the old option's on_disabled and the
-- new one's on_enabled run, on_policy_changed
function C.policy(args)
    local c, cid = country()
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
    -- (UpdatePolicyFlags: each selected option's `policy_flags`, else its name [I])
    local flags = world.child(c, "policy_flags")
    local ob, obf = policy_option(group, old or "")
    local nb, nbf = policy_option(group, option)
    local function flags_of(b, name)
        local l = world.list(b and world.field(b, "policy_flags"))
        if #l == 0 and name then
            l = { name }
        end
        return l
    end
    for _, f in ipairs(old and flags_of(ob, old) or {}) do
        world.remove_value(flags, '"' .. strip(f) .. '"')
        world.remove_value(flags, strip(f))
    end
    for _, f in ipairs(flags_of(nb, option)) do
        world.append_value(flags, strip(f), true)
    end
    local r1 = run_effect(ob and world.field(ob, "on_disabled"), "country", cid, obf)
    local r2 = run_effect(nb and world.field(nb, "on_enabled"), "country", cid, nbf)
    on_action("on_policy_changed", "country", cid)
    return "selected" .. (r1 and ("; on_disabled " .. r1) or "") .. (r2 and ("; on_enabled " .. r2) or "")
end

-- a leader's hiring cost (CLeader::CalcTable: its class's economic unit, `mult = value:leader_cost`
-- with the leader's level, in the leader's scope; the class's category modifiers)
function M.leader_cost(cid, id)
    local l = world.object("leader", id)
    local class = l and strip(world.field(l, "class"))
    local d, file = def("common/leader_classes", class or "")
    return cost_table(d and world.field(d, "resources"), file, "leader", id, cid)
end

-- a leader recruited from the pool (HireNewLeader): the cost paid, out of the pool, among the
-- owned leaders, its recruitment date, on_leader_hired
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
    local cost = M.leader_cost(cid, id)
    local ok, short = can_pay(c, cost)
    if not ok then
        return "not enough " .. short
    end
    pay_table(c, cost)
    world.remove_value(pool, tostring(id))
    world.append_value(world.child(c, "owned_leaders"), tostring(id))
    local l = world.object("leader", id)
    if l then
        world.set(l, "country", cid)
        world.set(l, "recruitment_date", '"' .. today() .. '"')
    end
    on_action("on_leader_hired", "leader", id)
    return "hired, paid " .. cost_text(cost)
end

-- a leader dismissed: not the ruler (CFireLeaderCommand::IsValid); out of the owned leaders,
-- off its council position and its job, removed
function C.dismiss(args)
    local c = country()
    local id = tonumber(args[1])
    if tonumber(world.field(c, "ruler")) == id then
        return "the ruler cannot be dismissed"
    end
    M.unassign(id)
    world.remove_value(world.child(c, "owned_leaders"), tostring(id))
    for _, pid in ipairs(world.all("council_positions")) do
        local p = world.object("council_positions", pid)
        if p and tonumber(world.field(p, "leader")) == id then
            world.set(p, "leader", NONE)
        end
    end
    world.remove("leader", id)
    return "dismissed"
end

-- the council's agenda chosen (CGovernment::SetCouncilAgenda): its progress back to 0, its
-- `init_effect` run
function C.agenda(args)
    local c, cid = country()
    local gov = world.field(c, "government")
    if strip(world.field(gov, "council_agenda")) == args[1] then
        return "already the agenda"
    end
    world.set(gov, "council_agenda", '"' .. args[1] .. '"')
    world.set(gov, "council_agenda_progress", 0)
    local d, file = def("common/council_agendas", args[1])
    local r = run_effect(d and world.field(d, "init_effect"), "country", cid, file)
    return "chosen" .. (r and ("; init_effect " .. r) or "")
end

-- an agenda's cost (CCouncilAgenda::GetCost 2323c30: `agenda_cost` x (1 +
-- EMPIRE_SIZE_COUNCIL_AGENDA_COST_PENALTY x GetEmpireSizeEffectScale(size, cap)), cap =
-- EMPIRE_SIZE_BASE + country_admin_cap_add, x (1 + country_admin_cap_mult) [V]; the scale taken as
-- the size over the cap x (1 + empire_size_penalty_mult) [I])
function M.agenda_cost(key)
    local d, file = def("common/council_agendas", key or "")
    local base = number(d, "agenda_cost", file) or 0
    local c, cid = country()
    local Mod = modifiers(cid)
    local cap = (100 + (tonumber(Mod.country_admin_cap_add) or 0)) * mult(Mod, "country_admin_cap_mult")
    local over = math.max(0, (tonumber(world.field(c, "empire_size")) or 0) - cap) * math.max(0, mult(Mod, "empire_size_penalty_mult"))
    return base * (1 + 0.001 * over)
end

-- the agenda launched (CFinishAgendaCommand → CGovernment::FinishAgenda): its finish_modifier as a
-- timed modifier for COUNCIL_AGENDA_FINISH_MODIFIER_DURATION × (1 +
-- council_agenda_finishing_effect_duration_mult) days, its `effect` run, a cooldown entry
-- (council_agenda_cooldowns: the end date in start_date, COUNCIL_AGENDA_COOLDOWN or the agenda's
-- agenda_cooldown days), no agenda and progress 0; on_agenda_finished. The view offers it only when
-- the progress has reached the cost (CGovernment::IsAgendaFinished)
function C.launch()
    local c, cid = country()
    local gov = world.field(c, "government")
    local key = strip(world.field(gov, "council_agenda"))
    if not key or key == "" or key == "none" then
        return "no agenda"
    end
    local progress = tonumber(world.field(gov, "council_agenda_progress")) or 0
    if progress < M.agenda_cost(key) then
        return "not finished"
    end
    local d, file = def("common/council_agendas", key)
    local Mod = modifiers(cid)
    local out = {}
    local fm = d and strip(world.field(d, "finish_modifier"))
    if fm then
        local n = math.max(1, math.floor(3600 * mult(Mod, "council_agenda_finishing_effect_duration_mult") + 0.5))
        local ok = pcall(function()
            require("engine.script.creation")
            require("engine.systems").effects.add_timed_modifier({ kind = "country", id = cid, modifier = fm, days = n })
        end)
        if not ok then
            local items = world.child(world.child(c, "timed_modifier"), "items")
            local item = {}
            world.append(item, "modifier", fm, true)
            world.append(item, "days", n)
            world.push(items, item)
        end
        out[#out + 1] = fm .. " for " .. n .. " days"
    end
    local r = run_effect(d and world.field(d, "effect"), "country", cid, file)
    if r then
        out[#out + 1] = r
    end
    local cd = tonumber(d and world.field(d, "agenda_cooldown")) or 10800
    local entry = {}
    world.append(entry, "council_agenda", key, true)
    world.append(entry, "start_date", add_days(today(), cd), true)
    world.push(world.child(gov, "council_agenda_cooldowns"), entry)
    local e = world.entry(gov, "council_agenda")
    if e then
        world.remove_entry(gov, e)
    end
    world.set(gov, "council_agenda_progress", 0)
    on_action("on_agenda_finished", "country", cid)
    return "launched " .. key .. ": " .. table.concat(out, "; ")
end

-- the rights' lock dates (CSpeciesRightsCountryConfiguration's last_changed_*: the date a right may
-- change again, now + SPECIES_POLICY_YEARS when it changed); subspecies integration has none
M.LOCK = {
    citizenship = "last_changed_citizenship_type", military_service = "last_changed_military_service_type",
    slavery = "last_changed_slavery_type", purge = "last_changed_purge_type",
    living_standard = "last_changed_living_standard", colonization_control = "last_changed_colonization_control",
    population_control = "last_changed_population_control", migration_control = "last_changed_migration_control",
}

-- the date a right (or, without a field, any right) of a rights entry unlocks, when after today
function M.locked_until(entry, field)
    local now = days(today())
    for f, k in pairs(M.LOCK) do
        if field == nil or field == f then
            local d = strip(world.field(entry, k))
            if d and days(d) > now then
                return d
            end
        end
    end
    return nil
end

-- a species' right set (CCountrySetSpeciesRightsCommand: the species' entry, made from the
-- default's when it has none; `default` the default rights, where the old option is kept as
-- former_*): not while the right is locked (CanChangeSpeciesRight); the right's lock date set
-- SPECIES_POLICY_YEARS on
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
            world.push(list, entry)
        end
    end
    local old = strip(world.field(entry, field))
    if old == option then
        return "already set"
    end
    local until_ = M.locked_until(entry, field)
    if until_ then
        return "locked until " .. until_
    end
    if who == "default" and old then
        world.set(entry, "former_" .. field, '"' .. old .. '"')
    end
    world.set(entry, field, '"' .. option .. '"')
    if M.LOCK[field] then
        world.set(entry, M.LOCK[field], '"' .. add_days(today(), 3600) .. '"')
    end
    return "set"
end

-- the government reformed (CChangeGovernmentCommand; the window checked the authority and the
-- civics, render.windows.reform): args AUTHORITY TYPE CIVIC,CIVIC (TYPE the government type the
-- window worked out: GenerateType [I: the weights not read]). IsValid's unity and cooldown checked
-- again; nothing when the authority and the civics are the same. Execute: unity - empire size x
-- GOVERNMENT_CHANGE_EMPIRE_SIZE_MULT (0 with the free_government_reform flag), the authority, the
-- civics (the origin kept), the type, government_date = now + GOVERNMENT_COOLDOWN_YEARS, the
-- ruler's own titles cleared (ClearCustomRulerTitles), on_pre/on_post_government_changed
function C.reform(args)
    local c, cid = country()
    local auth, gtype = args[1], args[2]
    local civics = {}
    for k in tostring(args[3] or ""):gmatch("[^,]+") do
        if k ~= "-" then
            civics[#civics + 1] = k
        end
    end
    local gov = world.child(c, "government")
    local old = {}
    for _, k in ipairs(world.list(world.field(gov, "civics"))) do
        old[#old + 1] = strip(k)
    end
    if strip(world.field(gov, "authority")) == auth and table.concat(old, ",") == table.concat(civics, ",") then
        return "unchanged"
    end
    local flags = world.field(c, "flags")
    local free = type(flags) == "table" and world.field(flags, "free_government_reform") ~= nil
    local last = strip(world.field(c, "government_date"))
    if not free and last and days(last) > days(today()) then
        return "reformed too recently (until " .. last .. ")"
    end
    local cost = free and 0 or math.floor((tonumber(world.field(c, "empire_size")) or 0) * 10 + 0.5)
    local ok = can_pay(c, { unity = cost })
    if not ok then
        return "not enough unity"
    end
    on_action("on_pre_government_changed", "country", cid)
    pay_table(c, { unity = cost })
    world.set(gov, "authority", '"' .. auth .. '"')
    local list = world.child(gov, "civics")
    for i = #list, 1, -1 do
        world.remove_at(list, i)
    end
    for _, k in ipairs(civics) do
        world.append_value(list, k, true)
    end
    if gtype and gtype ~= "" then
        world.set(gov, "type", '"' .. gtype .. '"')
    end
    world.set(c, "government_date", '"' .. add_days(today(), 20 * 360) .. '"')
    for _, k in ipairs({ "ruler_title", "ruler_title_female", "heir_title", "heir_title_female" }) do
        local e = world.entry(gov, k)
        if e then
            world.remove_entry(gov, e)
        end
    end
    on_action("on_post_government_changed", "country", cid)
    return "reformed: " .. auth .. " " .. table.concat(civics, ",") .. ", paid unity " .. cost
end

-- a block statement `key = { ... }` set (replaced or added)
local function set_block(obj, key, block)
    local e = world.entry(obj, key)
    if e then
        world.set_entry(obj, e, block)
    else
        world.append_entry(obj, { key = { text = key }, op = "=", value = block })
    end
end

-- a typed name as the save keeps it (CPersistentName(text, literal): `{ key="X" literal=yes }`)
local function literal(text)
    local b = {}
    world.append(b, "key", text, true)
    world.append(b, "literal", "yes")
    return b
end
M.literal = literal

-- the rename dialogs' commands (docs/windows/empire.md section 12). The texts come encoded
-- (render.windows.rename: `-` an unchanged box, the original name kept; `~` an empty one):
--   country ID NAME              CRenameCountryCommand: not a name another country has (as typed:
--                                the literal names compared [I]); `name` and `adjective`
--                                (%ADJECTIVE% with the name as its `adjective`) rewritten
--   sector ID NAME               CSetSectorNameCommand: the sector's `name`
--   leader ID NAME               CChangeLeaderNameCommand: `name.full_names`
--   ruler|heir ID NAME MALE FEMALE  and the ruler's or heir's titles (CChangeRulerTitlesCommand:
--                                the government's ruler_title(_female) / heir_title(_female) [I keys])
--   position ID NAME MALE FEMALE CChangeLeaderNameCommand for its councillor and
--                                CChangeCouncilPositionTitlesCommand (the country's
--                                custom_council_titles: { type male female } [I keys])
function C.rename(args)
    local R = require("render.windows.rename")
    local c = country()
    local kind, id = args[1], tonumber(args[2])
    local function text(i)
        local v = args[i]
        if v == nil or v == "-" then
            return nil
        end
        return v == "~" and "" or R.dec(v)
    end
    local name, male, female = text(3), text(4), text(5)
    if name == "" or male == "" or female == "" then
        return "a name is empty"
    end
    local done = {}
    local function rename_leader(lid)
        local l = world.object("leader", lid)
        if l and name then
            set_block(world.child(l, "name"), "full_names", literal(name))
            done[#done + 1] = "leader " .. lid
        end
    end
    if kind == "country" then
        if not name then
            return "unchanged"
        end
        for _, cid in ipairs(world.all("country")) do
            local o = world.object("country", cid)
            local n = o and world.field(o, "name")
            if type(n) == "table" and strip(world.field(n, "key")) == name and world.field(n, "literal") == "yes" then
                return "a country has that name"
            end
        end
        local o = world.object("country", id)
        set_block(o, "name", literal(name))
        local adj = {}
        world.append(adj, "key", "%ADJECTIVE%", true)
        local vars = {}
        local v = {}
        world.append(v, "key", "adjective", true)
        world.append_entry(v, { key = { text = "value" }, op = "=", value = literal(name) })
        world.push(vars, v)
        world.append_entry(adj, { key = { text = "variables" }, op = "=", value = vars })
        set_block(o, "adjective", adj)
        return "renamed the country"
    elseif kind == "sector" then
        local s = world.object("sector", id)
        if not s or tonumber(world.field(s, "owner")) ~= tonumber(require("render.topbar").player()) then
            return "not the player's sector"
        end
        if not name then
            return "unchanged"
        end
        set_block(s, "name", literal(name))
        return "renamed the sector"
    elseif kind == "leader" then
        if not name then
            return "unchanged"
        end
        rename_leader(id)
        return "renamed the leader"
    elseif kind == "ruler" or kind == "heir" then
        rename_leader(id)
        local gov = world.child(c, "government")
        if male then
            set_block(gov, kind .. "_title", literal(male))
            done[#done + 1] = kind .. " title"
        end
        if female then
            set_block(gov, kind .. "_title_female", literal(female))
            done[#done + 1] = kind .. " female title"
        end
        return #done > 0 and ("renamed " .. table.concat(done, ", ")) or "unchanged"
    elseif kind == "position" then
        local p = world.object("council_positions", id)
        if not p then
            return "no such position"
        end
        local lid = tonumber(world.field(p, "leader"))
        if lid and lid ~= NONE then
            rename_leader(lid)
        end
        if male or female then
            local ptype = strip(world.field(p, "type"))
            local titles = world.child(c, "custom_council_titles")
            local e = find_entry(titles, "type", ptype)
            if not e then
                e = {}
                world.append(e, "type", ptype, true)
                world.push(titles, e)
            end
            if male then
                set_block(e, "male", literal(male))
            end
            set_block(e, "female", literal(female or male))
            done[#done + 1] = "titles"
        end
        return #done > 0 and ("renamed " .. table.concat(done, ", ")) or "unchanged"
    end
    return "nothing to rename"
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

M.C = C
M.def, M.strip, M.country, M.today, M.find_entry = def, strip, country, today, find_entry
M.can_pay, M.pay_table, M.run_effect, M.on_action, M.modifiers = can_pay, pay_table, run_effect, on_action, modifiers
M.NONE = NONE

-- the leader taken off its job (CLeaderLocation::UnsetLeader): its colony's `governor` or its
-- ship's `leader` emptied, its `location` removed; the council seat kept
function M.unassign(id)
    local l = world.object("leader", id)
    local loc = l and world.field(l, "location")
    if type(loc) ~= "table" then
        return
    end
    local t, lid = strip(world.field(loc, "type")), tonumber(world.field(loc, "id"))
    if t == "planet" then
        local col = world.object("colony", lid)
        local e = col and world.entry(col, "governor")
        if e and tonumber(e.value.text) == id then
            world.remove_entry(col, e)
        end
    elseif t == "ship" then
        local s = world.object("ship", lid)
        local e = s and world.entry(s, "leader")
        if e and tonumber(e.value.text) == id then
            world.remove_entry(s, e)
        end
    end
    local e = world.entry(l, "location")
    if e then
        world.remove_entry(l, e)
    end
end

-- a leader given a job from the job list (CAssignLeaderCommand(leader, location, resetCooldown):
-- CLeaderLocation::SetLeader): args LEADER planet|ship ID (a colony's id, a fleet's first ship).
-- Not while its cooldown runs, not the place it has, not one with a leader; its old job left
-- (UnsetLeader), `location = { type assignment id position }`, the colony's `governor` or the
-- ship's `leader`, the class's assignment_cooldown, on_leader_assigned. No cost
function C.assign(args)
    local c = country()
    local id, kind, where = tonumber(args[1]), args[2], tonumber(args[3])
    local l = world.object("leader", id)
    if not l or tonumber(world.field(l, "country")) ~= tonumber(require("render.topbar").player()) then
        return "not the player's leader"
    end
    if (tonumber(world.field(l, "cooldown")) or 0) > 0 then
        return "the leader's cooldown runs"
    end
    if tonumber(world.field(c, "ruler")) == id then
        return "the ruler takes no job"
    end
    local loc = world.field(l, "location")
    if type(loc) == "table" and strip(world.field(loc, "type")) == kind and tonumber(world.field(loc, "id")) == where then
        return "already there"
    end
    local target
    if kind == "planet" then
        target = world.object("colony", where)
        if not target or world.field(target, "governor") ~= nil then
            return "no ungoverned colony"
        end
    elseif kind == "ship" then
        target = world.object("ship", where)
        if not target or world.field(target, "leader") ~= nil then
            return "no leaderless ship"
        end
    else
        return "not a job here"
    end
    M.unassign(id)
    local b = {}
    world.append(b, "type", kind)
    world.append(b, "assignment", "none")
    world.append(b, "id", where)
    world.append(b, "position", 0)
    set_block(l, "location", b)
    world.set(target, kind == "planet" and "governor" or "leader", id)
    local class = strip(world.field(l, "class"))
    local d = def("common/leader_classes", class or "")
    local cd = tonumber(d and world.field(d, "assignment_cooldown")) or 0
    if cd > 0 then
        world.set(l, "cooldown", cd)
    end
    on_action("on_leader_assigned", "leader", id)
    return "assigned to " .. kind .. " " .. where
end

-- the base species of a species (`base_ref`; none: itself)
local function base_of(sp)
    local s = world.object("species", sp)
    return s and (tonumber(world.field(s, "base_ref")) or sp) or nil
end

-- CCountry::GetDefaultSpecies(species, 1): the country's `default_species` entry for the species'
-- base; else the built species (built_species_ref) when it is that one or of that base; else the base
function M.default_of(c, sp)
    local b = base_of(sp)
    local map = world.field(c, "default_species")
    local e = type(map) == "table" and world.entry(map, tostring(b))
    if e then
        return tonumber(e.value.text)
    end
    local built = tonumber(world.field(c, "built_species_ref"))
    if built and (built == sp or base_of(built) == b) then
        return built
    end
    return b
end

-- the default species (CSetDefaultSpeciesCommand: valid when the species is not its group's default
-- already → CCountry::SetDefaultSpecies): the country's `default_species = { BASE = SPECIES }`
-- entry; the built species too when the species is it or of its base (SetBuiltSpecies)
function C.default_species(args)
    local c = country()
    local sp = tonumber(args[1])
    if not world.object("species", sp) then
        return "no such species"
    end
    if M.default_of(c, sp) == sp then
        return "already the default"
    end
    local b = base_of(sp)
    world.set(world.child(c, "default_species"), tostring(b), sp)
    local built = tonumber(world.field(c, "built_species_ref"))
    if built and (built == sp or base_of(built) == b) then
        world.set(c, "built_species_ref", sp)
    end
    return "the default of " .. b .. " set"
end

-- a block copied (its statements and values, not shared)
local function copy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = copy(v)
    end
    return out
end

-- a species template made (CCountryCreateSpeciesModTemplate → CGameState::CreateNewSpecies,
-- CCountry::AddSpeciesTemplate): a new species_db entry, the source's with the edited traits and
-- `base_ref` its base; its id in the country's species_templates_ref; its rights a copy of the
-- source's (a species_rights entry). Returns its id
local function new_template(c, src, traits)
    local so = world.object("species", src)
    if not so then
        return nil, "no such species"
    end
    local block = copy(so)
    local tb = {}
    for _, t in ipairs(traits) do
        world.append(tb, "trait", t, true)
    end
    set_block(block, "traits", tb)
    world.set(block, "base_ref", tonumber(world.field(so, "base_ref")) or src)
    -- (the new species' id: the store's next index [I: the game's id generation])
    local id = world.next_index("species")
    world.create("species", id, block)
    world.append_value(world.child(c, "species_templates_ref"), tostring(id))
    local mod = world.path(c, "modules", "standard_species_rights_module")
    if mod then
        local list = world.child(mod, "species_rights")
        local from = find_entry(list, "species_index", tostring(src))
        local primary = world.field(mod, "primary")
        if not from and primary and tonumber(world.field(primary, "species_index")) == src then
            from = primary
        end
        from = from or world.field(mod, "default")
        if from then
            local e = copy(from)
            world.set(e, "species_index", id)
            world.push(list, e)
        end
    end
    return id
end

local function trait_list(s)
    local out = {}
    for k in tostring(s or ""):gmatch("[^,]+") do
        if k ~= "-" then
            out[#out + 1] = k
        end
    end
    return out
end

-- Save / Apply in the template editor: args SOURCE TRAITS APPLY
function C.create_template(args)
    local c = country()
    local id, why = new_template(c, tonumber(args[1]), trait_list(args[2]))
    if not id then
        return why
    end
    return "template " .. id .. " made" .. (args[3] == "1" and " (apply: the apply window opens from the view)" or "")
end

-- Update: a new template, the old one out of species_templates_ref (CCountryUpdateSpeciesModTemplate)
function C.update_template(args)
    local c = country()
    local old = tonumber(args[1])
    local id, why = new_template(c, old, trait_list(args[2]))
    if not id then
        return why
    end
    world.remove_value(world.child(c, "species_templates_ref"), tostring(old))
    return "template " .. old .. " replaced by " .. id
end

-- Delete: out of species_templates_ref (CCountryDeleteSpeciesModTemplate; the species_db entry stays)
function C.delete_template(args)
    local c = country()
    world.remove_value(world.child(c, "species_templates_ref"), tostring(args[1]))
    return "template " .. args[1] .. " deleted"
end

-- Research Project in the apply window (CCreateSpeciesModSpecialProjectCommand): the game starts a
-- species modification special project whose pops change when it completes; that project is not
-- modelled here [not done: its save shape is not known]
function C.apply_template(args)
    return "not done: the species modification project for template " .. tostring(args[1]) .. " (species " .. tostring(args[2]) .. ") is not modelled"
end

return M
