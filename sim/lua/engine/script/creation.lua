-- engine/script/creation.lua : the engine side of the script effects that create or change things
-- (simscript/handlers/creation.lua queues them; docs/script_creation.md has each effect's semantics
-- from the GOG 4.5.2 build). Each applier is registered in engine.systems.effects under the queued
-- effect's type and applied at the barrier (E.flush) to the world in the save's own form.
--
--   local creation = require("engine.script.creation")
--   creation.stats, creation.report()
--
-- Appliers (t is the queued effect, t.kind/t.id its scope):
--   add_deposit                CAddDepositEffect::ExecuteActual -> CGameState::CreateNewDeposit
--   remove_deposit             CRemoveDepositEffect::ExecuteActual -> CDepositHolder::RemoveDeposit
--   add_monthly_resource_mult  CAddMonthlyResourceMultEffect::ExecuteActual (CalcGained)
--   add_experience             CAddExperience::ExecuteActual -> CLeader::AddExperience (engine.leaders)

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")

local creation = {
    stats = {},     -- effect type -> { applied =, skipped = { [why] = n } }
    errors = {},
}

local GEN = 16777216
local FP = 100000

local function stat(kind)
    local s = creation.stats[kind]
    if not s then
        s = { applied = 0, skipped = {} }
        creation.stats[kind] = s
    end
    return s
end
local function applied(kind)
    local s = stat(kind)
    s.applied = s.applied + 1
    return true
end
-- an effect that did nothing, and why (the game's own no-ops: an unknown type, a missing holder)
local function skipped(kind, why)
    local s = stat(kind)
    s.skipped[why] = (s.skipped[why] or 0) + 1
    return nil
end
creation.applied, creation.skipped = applied, skipped

local function err(msg)
    if #creation.errors < 20 then
        creation.errors[#creation.errors + 1] = msg
    end
end

local function draw()
    return RUST.rand()
end
creation.draw = draw

-- ---------------------------------------------------------------------------------------------
-- fixed point (CFixedPoint: int64, 1.0 = 100000), in doubles that hold exact integers

local floor = math.floor
local function trunc(x)
    return x < 0 and -floor(-x) or floor(x)
end
-- a value as the game reads or stores it: the nearest fixed-point step
local function fp(v)
    return floor((tonumber(v) or 0) * FP + 0.5)
end
-- CFixedPoint::operator*: the product of two raw values, truncated toward zero
local function fmul(a, b)
    return trunc(a * b / FP)
end
creation.fp, creation.fmul, creation.trunc = fp, fmul, trunc

-- ---------------------------------------------------------------------------------------------
-- definitions

local source = require("stellar.script.source")
local expanded = {}
-- a definition's block with its inline scripts expanded (deposit types take modifiers from them)
local function def_block(folder, name)
    local key = folder .. "|" .. name
    local b = expanded[key]
    if b == nil then
        b = false
        local d = defs.get(folder, name)
        if d then
            local db = require("simscript.db")
            local ok, x = pcall(source.expand, db.fs, d.block, nil, 0, "file: " .. tostring(d.file))
            b = { block = ok and x or d.block, file = d.file }
        end
        expanded[key] = b
    end
    return b or nil
end
creation.def_block = def_block

local function unq(v)
    if type(v) == "string" then
        return (v:gsub('^"(.*)"$', "%1"))
    end
    return v
end
creation.unq = unq

-- a static modifier block (CStaticModifier) is empty when it has no entries [I]
local function nonempty(block)
    if type(block) ~= "table" then
        return false
    end
    for _, e in ipairs(block) do
        if e.op and e.key then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- deposits

-- the deposit holder of a scope (CEventScope::GetDepositHolder; EDepositHolderType as the save
-- writes deposit_holder.type: 0 a planet, 1 an astral rift, 2 a ship)
local function holder_of(kind, id)
    if kind == "planet" then
        return 0, id, world.object("planet", id)
    elseif kind == "colony" then
        local pid = world.colony_planet and world.colony_planet[id]
        return pid and 0, pid, pid and world.object("planet", pid)
    elseif kind == "ship" then
        return 2, id, world.object("ship", id)
    elseif kind == "astral_rift" then
        return 1, id, world.object("astral_rifts", id)
    end
    return nil
end
creation.holder_of = holder_of

local function deposit_def(key)
    return key and def_block("common/deposits", key)
end

-- CDepositCategory::_bBlocker (`blocker = yes`)
local function is_blocker(d)
    local cat = unq(defs.field(d.block, "category"))
    local c = cat and defs.get("common/deposit_categories", cat)
    return c ~= nil and defs.field(c.block, "blocker") == "yes"
end

-- the holder's deposit list (CDepositHolder +0x40, the save's `deposits = { ids }`)
local function deposit_list(obj, create)
    local l = world.field(obj, "deposits")
    if type(l) ~= "table" and create then
        l = world.child(obj, "deposits")
    end
    return type(l) == "table" and l or nil
end

-- CColonyCarrier::AddDeposit / RemoveDeposit: carrier_binary_flags |= 2 when the deposit type has a
-- country or habitat modifier (CDepositType _CountryModifier +0x4a8, _HabitatModifier +0x678,
-- vtable+64 on each) [V]; the flag's meaning (the carrier's deposits to be re-read) [I]
local function flag_carrier(obj, d)
    if not (nonempty(defs.field(d.block, "country_modifier")) or nonempty(defs.field(d.block, "habitat_modifier"))) then
        return
    end
    local f = tonumber(world.field(obj, "carrier_binary_flags")) or 0
    if f % 4 < 2 then
        world.set(obj, "carrier_binary_flags", f + 2)
    end
end

-- CDeposit::SetType for a blocker (CDepositCategory blocker): the deposit it hides (swap_type).
-- blocker_swap_types without use_weights_for_blocker_swap_types: one draw, list[r % n] [V];
-- all_blocker_swap_types or the weighted form go through CDepositTypesDatabase::_Randomize (not
-- ported: returns nil, false)
local function blocker_swap(d)
    if defs.field(d.block, "all_blocker_swap_types") == "yes" then
        return nil, false
    end
    local list = defs.field(d.block, "blocker_swap_types")
    local names = {}
    for _, e in ipairs(type(list) == "table" and list or {}) do
        if e.text then names[#names + 1] = unq(e.text) end
    end
    if #names == 0 then
        return nil, true
    end
    if defs.field(d.block, "use_weights_for_blocker_swap_types") == "yes" then
        return nil, false
    end
    return names[draw() % #names + 1], true
end

-- add_deposit: t = { kind, id, deposit (a type key) }
function systems.effects.add_deposit(t)
    local htype, hid, obj = holder_of(t.kind, t.id)
    if not obj then
        return skipped("add_deposit", "no deposit holder")
    end
    local d = deposit_def(t.deposit)
    if not d then
        return skipped("add_deposit", "unknown type")       -- the null type: IsValid false, nothing made
    end
    local swap
    if is_blocker(d) then
        local ok
        swap, ok = blocker_swap(d)
        if not ok then
            return skipped("add_deposit", "blocker with a weighted swap type (_Randomize not ported)")
        end
    end
    local create = require("engine.fleets.create")
    local id, e = create.allocate("deposit")
    local block = {}
    world.append(block, "type", t.deposit, true)
    if swap then
        world.append(block, "swap_type", swap, true)
    end
    local h = {}
    world.append(h, "type", htype)
    world.append(h, "id", hid)
    world.append(block, "deposit_holder", h)
    create.place("deposit", id, e, block)
    -- CDepositHolder::AddDeposit: the id appended unless listed (it is new), then
    -- CPlanet::InvalidateModifier (the planet's modifiers: the next modifier update)
    world.append_value(deposit_list(obj, true), id)
    if htype == 0 then
        flag_carrier(obj, d)
    end
    applied("add_deposit")
    return id
end

-- the first deposit of the holder's list whose type is key (CDepositHolder::RemoveDeposit(type))
local function find_deposit(obj, key)
    for _, v in ipairs(world.list(deposit_list(obj, false))) do
        local did = tonumber(v)
        local dep = did and world.object("deposit", did)
        if dep and unq(world.field(dep, "type")) == key then
            return did
        end
    end
    return nil
end

-- the deposit taken off its holder and out of the store (the game marks it deleted, holder type 3,
-- and frees the slot at its cleanup; here at once [I])
local function delete_deposit(did, no_flag)
    local dep = world.object("deposit", did)
    if not dep then
        return false
    end
    local h = world.field(dep, "deposit_holder")
    local htype = h and tonumber(world.field(h, "type"))
    local hid = h and tonumber(world.field(h, "id"))
    local obj = htype == 0 and world.object("planet", hid) or htype == 2 and world.object("ship", hid)
        or htype == 1 and world.object("astral_rifts", hid) or nil
    local d = deposit_def(unq(world.field(dep, "type")))
    if obj then
        local l = deposit_list(obj, false)
        if l then world.remove_value(l, did) end
        if htype == 0 and d and not no_flag then
            flag_carrier(obj, d)
        end
    end
    world.remove("deposit", did)
    return true
end
creation.delete_deposit = delete_deposit

-- remove_deposit: t = { kind, id, deposit (a type key, or nil for `yes`) }
function systems.effects.remove_deposit(t)
    if t.kind == "deposit" then
        local dep = world.object("deposit", t.id)
        if not dep then
            return skipped("remove_deposit", "no deposit")
        end
        local key = t.deposit or unq(world.field(dep, "type"))
        local h = world.field(dep, "deposit_holder")
        local htype, hid = tonumber(world.field(h, "type")), tonumber(world.field(h, "id"))
        local kind = htype == 0 and "planet" or htype == 2 and "ship" or htype == 1 and "astral_rift" or nil
        if not kind then
            return skipped("remove_deposit", "no deposit holder")
        end
        t = { kind = kind, id = hid, deposit = key }
    end
    local _, _, obj = holder_of(t.kind, t.id)
    if not obj then
        return skipped("remove_deposit", "no deposit holder")
    end
    if not t.deposit then
        return skipped("remove_deposit", "no type (yes outside a deposit scope)")
    end
    local did = find_deposit(obj, t.deposit)
    if not did then
        return skipped("remove_deposit", "the holder has none of the type")
    end
    delete_deposit(did)
    return applied("remove_deposit")
end

-- clear_deposits = yes (CClearDepositsEffect -> CColonyCarrier::ClearDeposits): every deposit of
-- the carrier marked deleted and the list emptied; no carrier flag, no modifier invalidation [V]
function systems.effects.clear_deposits(t)
    local _, _, obj = holder_of(t.kind, t.id)
    if not obj then
        return skipped("clear_deposits", "no deposit holder")
    end
    local ids = {}
    for _, v in ipairs(world.list(deposit_list(obj, false))) do
        ids[#ids + 1] = tonumber(v)
    end
    for _, did in ipairs(ids) do
        delete_deposit(did, true)
    end
    return applied("clear_deposits")
end

-- ---------------------------------------------------------------------------------------------
-- resources

local RESEARCH = { physics_research = 1, society_research = 2, engineering_research = 3 }

-- the country's last month's summed income of a resource (CCountryBudget _LastMonth._Standard
-- ._SummedIncome, +0x20c0 of CCountry): the simulation's last month once it ran one, else the
-- save's budget.last_month.income (trade_income is the _Trade block, not summed here)
local function last_month_income(country, res)
    local economy = package.loaded["engine.economy"]
    local lm = economy and economy.last_month and economy.last_month[country]
    local sum = 0
    if lm then
        for _, t in pairs(lm.income or {}) do
            sum = sum + (t[res] or 0)
        end
        return sum
    end
    local inc = world.path(world.object("country", country), "budget", "last_month", "income")
    for _, e in ipairs(type(inc) == "table" and inc or {}) do
        if e.op and e.key and e.value.text == nil then
            for _, x in ipairs(e.value) do
                if x.op and x.key and x.key.text == res then
                    sum = sum + (tonumber(x.value.text) or 0)
                end
            end
        end
    end
    return sum
end
creation.last_month_income = last_month_income

local function stockpile(country)
    local c = world.object("country", country)
    local module = world.path(c, "modules", "standard_economy_module")
    return type(module) == "table" and world.child(module, "resources") or nil
end

-- the stored research points (tech_status.stored_techpoints = { physics society engineering })
local function stored_points(country)
    local status = world.field(world.object("country", country), "tech_status")
    if type(status) ~= "table" then
        return nil
    end
    local block = world.field(status, "stored_techpoints")
    if type(block) ~= "table" then
        block = world.child(status, "stored_techpoints")
    end
    while #block < 3 do
        block[#block + 1] = { text = "0" }
    end
    return block
end

-- add_monthly_resource_mult: t = { kind = "country", id, resource, value, min, max, mult } (raw
-- fixed point; min / max nil when not given)
--   CalcGained: gained = last month's income * value; then max(min), min(max); then, against the
--   stockpile s (research: the stored points), the amount is gained when gained + s > 0, else -s;
--   times mult; rounded to a whole unit (half away from zero) [V]
--   ExecuteActual: research -> CTechnologyStatus stored points (clamped at 0) [V]; else
--   CCountry::AddResource -> CEconomyCountryModule::AddResource (whole units, then CapTable) [V];
--   the resource converter path (countries with a CResourceConverter) is not modelled [I]
function systems.effects.add_monthly_resource_mult(t)
    if t.kind ~= "country" or not world.object("country", t.id) then
        return skipped("add_monthly_resource_mult", "not a country")
    end
    local res = t.resource
    local income = fp(last_month_income(t.id, res))
    local gained = fmul(income, t.value or 0)
    if t.min and gained < t.min then gained = t.min end
    if t.max and gained > t.max then gained = t.max end
    local area = RESEARCH[res]
    local stock, block
    if area then
        block = stored_points(t.id)
        if not block then
            return skipped("add_monthly_resource_mult", "no tech_status")
        end
        stock = fp(block[area].text)
    else
        block = stockpile(t.id)
        if not block then
            return skipped("add_monthly_resource_mult", "no stockpile")
        end
        stock = fp(world.field(block, res))
    end
    local x = (gained + stock > 0) and gained or -stock
    x = fmul(x, t.mult or FP)
    x = trunc((x + (x < 0 and -50000 or 50000)) / FP) * FP
    if area then
        local now = stock + x
        if now < 0 then now = 0 end
        block[area].text = world.number_text(now / FP)
    else
        local now = stock + x
        if now < 0 then now = 0 end
        local v = now / FP
        local economy = require("engine.economy")
        local cap = economy.capacity(t.id, res)
        if cap and v > cap then
            v = math.max(stock / FP, cap)
        end
        world.set(block, res, v)
    end
    creation.last_mult = { country = t.id, resource = res, amount = x / FP }
    return applied("add_monthly_resource_mult")
end

-- ---------------------------------------------------------------------------------------------
-- leaders

-- add_experience: t = { kind = "leader", id, amount } (CLeader::AddExperience through engine.leaders)
function systems.effects.add_experience(t)
    if t.kind ~= "leader" or not world.object("leaders", t.id) then
        return skipped("add_experience", "not a leader")
    end
    require("engine.leaders").add_experience(t.id, t.amount)
    return applied("add_experience")
end

-- ---------------------------------------------------------------------------------------------

function creation.report()
    local kinds = {}
    for k in pairs(creation.stats) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    local parts = {}
    for _, k in ipairs(kinds) do
        local s = creation.stats[k]
        local why = {}
        for w, n in pairs(s.skipped) do why[#why + 1] = string.format("%s %d", w, n) end
        table.sort(why)
        parts[#parts + 1] = string.format("%s %d%s", k, s.applied, #why > 0 and (" (not: " .. table.concat(why, ", ") .. ")") or "")
    end
    local out = "script creation: " .. (#parts > 0 and table.concat(parts, "; ") or "nothing applied")
    local es = package.loaded["engine.script.event_save"]
    if es then out = out .. "\n" .. es.report() end
    local st = require("simscript.eval").stats
    out = out .. string.format("\nevents: %d option draws (AI), %d human options, %d random_events draws, %d delayed loaded or queued, %d delayed fired",
        st.option_draws or 0, st.human_options or 0, st.random_event_draws or 0,
        (es and es.stats.delayed or 0) + (st.delayed_queued or 0), st.delayed_fired or 0)
    for _, e in ipairs(creation.errors) do
        out = out .. "\n  error: " .. e
    end
    return out
end

return creation
