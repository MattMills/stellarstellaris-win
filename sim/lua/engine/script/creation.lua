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
        world.set_text(block, area, world.number_text(now / FP))
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
-- timed modifiers (CTimedModifierCollection: { modifier, days, multiplier, clear_on_owner_change },
-- the save's `timed_modifier = { items = { { modifier days [multiplier] } } }`)

local function items_of(obj, create)
    local tm = world.field(obj, "timed_modifier")
    if type(tm) ~= "table" then
        if not create then return nil end
        tm = world.child(obj, "timed_modifier")
    end
    local items = world.field(tm, "items")
    if type(items) ~= "table" then
        if not create then return nil end
        items = world.child(tm, "items")
    end
    return items
end

local function item_modifier(item)
    return type(item) == "table" and not item.text and not item.op and unq(world.field(item, "modifier")) or nil
end

-- CCountry::AddTimedModifier (0x707d10), CColonyCarrier::AddTimedModifier (0xcce430): an item of the
-- same modifier keeps the longer days (the new ones when its own are lower: a permanent -1 becomes
-- the new duration) and takes the new multiplier and flag; else a new item at the end [V]
local function add_timed(obj, name, days, mult, clear)
    local items = items_of(obj, true)
    for _, item in ipairs(items) do
        if item_modifier(item) == name then
            local old = tonumber(world.field(item, "days")) or -1
            if old < days then world.set(item, "days", days) end
            local om = world.field(item, "multiplier")
            om = om and fp(om) or FP
            if om ~= mult then
                if mult == FP then
                    for _, e in ipairs(item) do
                        if e.op and e.key and e.key.text == "multiplier" then world.remove_entry(item, e); break end
                    end
                else
                    world.set(item, "multiplier", mult / FP)
                end
            end
            return "refreshed"
        end
    end
    local item = {}
    world.append(item, "modifier", name, true)
    world.append(item, "days", days)
    if mult ~= FP then world.append(item, "multiplier", mult / FP) end
    if clear then world.append(item, "clear_on_owner_change", "yes") end
    world.push(items, item)
    return "added"
end

-- the objects an add_modifier in a scope goes to (CAddModifierEffect::ExecuteActual 0x17ccb40): the
-- object itself; a colony's planet; a fleet's ships unless it is a starbase's fleet (ship class 10)
-- or a station fleet, which keep it themselves [V] (the station test is the fleet's flag bit 2 [I])
local function modifier_holders(kind, id)
    if kind == "colony" then
        local pid = world.colony_planet and world.colony_planet[id]
        return { pid and world.object("planet", pid) }
    elseif kind == "fleet" then
        local f = world.object("fleet", id)
        if not f then return {} end
        local class = unq(world.field(f, "ship_class"))
        local props = world.field(f, "properties")
        local station = type(props) == "table" and world.field(props, "station") == "yes"
        if class == "shipclass_starbase" or station then
            return { f }
        end
        local out = {}
        for _, v in ipairs(world.list(world.field(f, "ships"))) do
            local s = world.object("ship", tonumber(v))
            if s then out[#out + 1] = s end
        end
        return out
    end
    return { world.object(kind, id) }
end

-- add_modifier: t = { kind, id, modifier, days, mult (raw), clear }
function systems.effects.add_timed_modifier(t)
    local holders = modifier_holders(t.kind, t.id)
    if #holders == 0 then
        return skipped("add_modifier", "no object")
    end
    for _, obj in ipairs(holders) do
        add_timed(obj, t.modifier, t.days, t.mult or FP, t.clear)
    end
    creation.modifiers_changed = true
    return applied("add_modifier")
end

-- remove_modifier: t = { kind, id, modifier } (CColonyCarrier::RemoveTimedModifier 0xcce4f0,
-- CCountry::RemoveTimedModifier: the first item of the modifier taken out) [V]
function systems.effects.remove_timed_modifier(t)
    local holders = modifier_holders(t.kind, t.id)
    local removed = false
    for _, obj in ipairs(holders) do
        local items = items_of(obj, false)
        for i, item in ipairs(items or {}) do
            if item_modifier(item) == t.modifier then
                world.remove_at(items, i)
                removed = true
                break
            end
        end
    end
    if not removed then
        return skipped("remove_modifier", "not there")
    end
    creation.modifiers_changed = true
    return applied("remove_modifier")
end

-- after a root effect (an event's immediate, option or after): the game updates its modifier nodes
-- (CRootEffect::Execute -> CModifierNodeManager::Update) [V]; when a timed modifier changed, the
-- world's graph is brought up to date then (engine.modifier_source.rebuild), not at the month's
-- update only. creation.defer (set by newgame.start_script) takes the update instead: the graph
-- is brought up to date when something next reads it, which gives the same values (nothing reads
-- the graph in between) without a rebuild after every event of the start
function creation.after_root_effect()
    if not creation.modifiers_changed then
        return
    end
    creation.modifiers_changed = false
    if creation.defer then
        creation.defer()
        return
    end
    local engine = package.loaded["engine"]
    local source = engine and engine.modifier_source
    if source and source.rebuild then
        source.rebuild()
        creation.modifier_updates = (creation.modifier_updates or 0) + 1
    end
end

-- ---------------------------------------------------------------------------------------------
-- opinion modifiers (CRelation's CTimedOpinionModifier list: the relation's `modifier = { modifier
-- date start_date value decay }` entries in the owner's relations_manager)

local function relation_of(us, them, create)
    local c = world.object("country", us)
    local rm = c and world.field(c, "relations_manager")
    if type(rm) ~= "table" then
        if not create or not c then return nil end
        rm = world.child(c, "relations_manager")
    end
    for _, e in ipairs(rm) do
        if e.op and e.key and e.key.text == "relation" and type(e.value) == "table" and not e.value.text then
            if tonumber(world.field(e.value, "country")) == them then
                return e.value
            end
        end
    end
    if not create then return nil end
    -- CDiplomacyCountryModule::AccessOrCreateRelation: a relation made (the save's defaults [I])
    local rel = {}
    world.append(rel, "owner", us)
    world.append(rel, "country", them)
    world.append(rel, "shared_rivals", 0)
    world.append(rel, "border_range", 0)
    world.append(rel, "threat", 0)
    world.append(rel, "trust", 0)
    world.append(rel, "relation_current", 0)
    world.append(rel, "relation_last_month", 0)
    world.append(rm, "relation", rel)
    return rel
end
creation.relation_of = relation_of

local function date_text(day)
    local y = floor(day / 360)
    local r = day - y * 360
    return string.format("%d.%02d.%02d", y, floor(r / 30) + 1, r % 30 + 1)
end

-- COpinionModifier::GetValue: the `opinion` value (base, then the modifiers whose triggers hold) in
-- this = us, from = them
local function opinion_value(def, us, them)
    local o = defs.field(def.block, "opinion")
    if o == nil then return 0 end
    if type(o) ~= "table" then return fp(o) end
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S("country", us), eval.S("country", them), nil, def.file)
    local ok, v = pcall(eval.weight, o, ctx, 0)
    return ok and fp(v) or 0
end

local function modifier_entries(rel, key)
    local out = {}
    for i, e in ipairs(rel) do
        if e.op and e.key and e.key.text == "modifier" and type(e.value) == "table" and not e.value.text then
            if not key or unq(world.field(e.value, "modifier")) == key then
                out[#out + 1] = { index = i, entry = e }
            end
        end
    end
    return out
end

-- CRelation::RemoveOpinion (0x66aeb0): every entry of the modifier taken out, each replaced by the
-- list's last [V]
local function remove_opinion(rel, key)
    local n = 0
    while true do
        local all = modifier_entries(rel, nil)
        local hit
        for k, m in ipairs(all) do
            if unq(world.field(m.entry.value, "modifier")) == key then hit = k; break end
        end
        if not hit then break end
        local last = all[#all]
        if last.index ~= all[hit].index then
            world.set_entry(rel, all[hit].entry, last.entry.value)
        end
        world.remove_entry(rel, last.entry)
        n = n + 1
    end
    return n
end

-- add_opinion_modifier: t = { kind = "country", id (us), who (them), modifier }
-- (CAddOpinionModifierEffect 0x171ee70 -> CRelation::AddOpinion 0x66ab10): both countries alive and
-- not the same; the value GetValue * 1, clamped to [min, max]; an accumulative modifier adds to its
-- entry; a unique one replaces its entries; a new entry ends (`date`) after `months` when set,
-- decays (`decay`, `start_date` today) when it has a decay or growth rate [V]
function systems.effects.add_opinion_modifier(t)
    if t.kind ~= "country" or t.id == t.who then
        return skipped("add_opinion_modifier", "not a country / itself")
    end
    if not world.object("country", t.id) or not world.object("country", t.who) then
        return skipped("add_opinion_modifier", "no country")
    end
    local def = defs.get("common/opinion_modifiers", t.modifier)
    if not def then
        return skipped("add_opinion_modifier", "unknown modifier")
    end
    local b = def.block
    local maxv, minv = defs.field(b, "max"), defs.field(b, "min")
    maxv = maxv and fp(maxv) or math.huge
    minv = minv and fp(minv) or -math.huge
    local value = opinion_value(def, t.id, t.who)
    local rel = relation_of(t.id, t.who, true)
    if defs.field(b, "accumulative") == "yes" then
        local m = modifier_entries(rel, t.modifier)[1]
        if m then
            local v = fp(world.field(m.entry.value, "value"))
            v = v + value
            if v > maxv then v = maxv end
            if v < minv then v = minv end
            world.set(m.entry.value, "value", v / FP)
            return applied("add_opinion_modifier")
        end
    end
    if defs.field(b, "unique") == "yes" then
        remove_opinion(rel, t.modifier)
    end
    if value > maxv then value = maxv end
    if value < minv then value = minv end
    local e = {}
    world.append(e, "modifier", t.modifier, true)
    local months = tonumber(defs.field(b, "months"))
    local today = require("simscript.eval").today()
    if months and months > 0 then
        world.append(e, "date", date_text(today + months * 30), true)
    end
    local decays = defs.field(b, "decay") ~= nil or defs.field(b, "growth") ~= nil
    if decays then
        world.append(e, "start_date", date_text(today), true)
    end
    world.append(e, "value", value / FP)
    if decays then
        -- the growth direction -1 (decay) [I: the definition has decay, not growth]
        world.append(e, "decay", defs.field(b, "growth") == nil and "yes" or "no")
    end
    -- after the last modifier entry (the list's end), else after trust
    local pos
    for i, x in ipairs(rel) do
        if x.op and x.key and (x.key.text == "modifier" or (not pos and x.key.text == "trust")) then pos = i end
    end
    world.insert(rel, (pos or #rel) + 1, "modifier", e)
    return applied("add_opinion_modifier")
end

-- remove_opinion_modifier: t = { kind = "country", id, who (a country id or "all"), modifier }
function systems.effects.remove_opinion_modifier(t)
    if t.kind ~= "country" then
        return skipped("remove_opinion_modifier", "not a country")
    end
    local n = 0
    if t.who == "all" then
        local c = world.object("country", t.id)
        local rm = c and world.field(c, "relations_manager")
        for _, e in ipairs(type(rm) == "table" and rm or {}) do
            if e.op and e.key and e.key.text == "relation" and type(e.value) == "table" and not e.value.text then
                n = n + remove_opinion(e.value, t.modifier)
            end
        end
    else
        local rel = relation_of(t.id, t.who, false)
        if rel then n = remove_opinion(rel, t.modifier) end
    end
    if n == 0 then
        return skipped("remove_opinion_modifier", "not there")
    end
    return applied("remove_opinion_modifier")
end

-- ---------------------------------------------------------------------------------------------
-- planets

-- change_pc: t = { kind = "planet", id, class } (CChangePlanetClassEffect 0x1704980 ->
-- CPlanet::SetPlanetClass 0xdf9f60): nothing when the class is the planet's already; the class set;
-- one draw of the game's generator, a scope made from it (this = the planet) for
-- on_planet_class_changed [V]. A colony's consequences (ClearAndReplaceInvalidBuildingsAndDistricts,
-- the pops' habitability, the terraforming cancelled) are not modelled: counted
function systems.effects.change_pc(t)
    local pid = t.kind == "planet" and t.id or (t.kind == "colony" and world.colony_planet and world.colony_planet[t.id])
    local p = pid and world.object("planet", pid)
    if not p then
        return skipped("change_pc", "not a planet")
    end
    if not defs.get("common/planet_classes", t.class) then
        return skipped("change_pc", "unknown class")
    end
    if unq(world.field(p, "planet_class")) == t.class then
        return skipped("change_pc", "the same class")
    end
    world.set(p, "planet_class", t.class)
    for _, e in ipairs(p) do
        if e.op and e.key and e.key.text == "planet_class" then e.value.quoted = true end
    end
    if world.planet_colony and world.planet_colony[pid] then
        stat("change_pc").colonies = (stat("change_pc").colonies or 0) + 1
    end
    creation.modifiers_changed = true
    local seed = draw()
    local host = package.loaded["simscript.host"]
    if host then
        host.on_action("on_planet_class_changed", "planet", pid, seed)
    end
    return applied("change_pc")
end

-- ---------------------------------------------------------------------------------------------
-- surveys

-- set_surveyed: t = { kind, id, surveyor (country), surveyed (bool) } (CSetSurveyedEffect
-- 0x170dbb0): a deposit holder (planet, ship, astral rift): yes -> CCountry::AddSurveyedDepositHolder
-- (engine.fleets.survey.add_surveyed: the sorted list, three draws, on_*_surveyed), no ->
-- RemoveSurveyedDepositHolder; a system: yes -> AddSurveyedSystem (its holders), no -> every holder
-- of it removed [V]. The country's list of newly surveyed systems is not kept [I]
local function remove_surveyed(country, ty, id)
    local c = world.object("country", country)
    local b = c and world.field(c, "surveyed_deposit_holders")
    if type(b) ~= "table" then return false end
    for i, e in ipairs(b) do
        if not e.text and not e.op and tonumber(world.field(e, "type")) == ty and tonumber(world.field(e, "id")) == id then
            world.remove_at(b, i)
            return true
        end
    end
    return false
end
function systems.effects.set_surveyed(t)
    local survey = require("engine.fleets.survey")
    local host = package.loaded["simscript.host"]
    if not world.object("country", t.surveyor) then
        return skipped("set_surveyed", "no surveyor")
    end
    if t.kind == "system" then
        local g = world.object("galactic_object", t.id)
        if not g then return skipped("set_surveyed", "no system") end
        local holders = {}
        for _, v in ipairs(world.fields(g, "planet")) do
            if type(v) == "string" and tonumber(v) then holders[#holders + 1] = { 0, tonumber(v) } end
        end
        for _, h in ipairs(holders) do
            if t.surveyed then survey.add_surveyed(t.surveyor, h[1], h[2], nil, host)
            else remove_surveyed(t.surveyor, h[1], h[2]) end
        end
        return applied("set_surveyed")
    end
    local htype, hid = holder_of(t.kind, t.id)
    if not htype then
        return skipped("set_surveyed", "not a deposit holder")
    end
    if t.surveyed then
        survey.add_surveyed(t.surveyor, htype, hid, nil, host)
    else
        remove_surveyed(t.surveyor, htype, hid)
    end
    return applied("set_surveyed")
end

-- ---------------------------------------------------------------------------------------------
-- countries

-- add_timeline_event: t = { kind = "country", id, definition, date (day index), targets =
-- { { kind, id } } } (CAddTimelineEventEffect 0x17c3e00): the country's `timeline_events` gets
-- { date data types definition } at the end [V]; a definition's uniqueness is not checked [I]
local TYPE_NAME = { system = "galactic_object" }
function systems.effects.add_timeline_event(t)
    local c = t.kind == "country" and world.object("country", t.id)
    if not c then
        return skipped("add_timeline_event", "not a country")
    end
    local list = world.child(c, "timeline_events")
    local item = {}
    world.append(item, "date", date_text(t.date), true)
    if t.targets and #t.targets > 0 then
        local data, types = {}, {}
        for _, x in ipairs(t.targets) do
            data[#data + 1] = { text = tostring(x.id) }
            types[#types + 1] = { text = TYPE_NAME[x.kind] or x.kind }
        end
        world.append(item, "data", data)
        world.append(item, "types", types)
    end
    world.append(item, "definition", t.definition, true)
    list[#list + 1] = item
    return applied("add_timeline_event")
end

-- ---------------------------------------------------------------------------------------------
-- event chains and special projects (CCountryEventManager: the country's `events = { event_chain
-- special_project next_special_project_id }`)

local function events_block(country, create)
    local c = world.object("country", country)
    if not c then return nil end
    local b = world.field(c, "events")
    if type(b) ~= "table" then
        if not create then return nil end
        b = world.child(c, "events")
    end
    return b
end

local function chain_entry(evb, key)
    for _, e in ipairs(evb or {}) do
        if e.op and e.key and e.key.text == "event_chain" and type(e.value) == "table" and not e.value.text
            and unq(world.field(e.value, "event_chain")) == key then
            return e
        end
    end
    return nil
end

-- begin_event_chain: t = { country, chain, scope (a scope block) } (CBeginEventChainEffect 0x17bb5c0
-- -> CCountryEventManager::BeginEventChain 0x801f00): when the chain is not active, a
-- CActiveEventChain with a copy of the effect's scope at the end of the list [V]
function systems.effects.begin_event_chain(t)
    if not defs.get("common/event_chains", t.chain) then
        return skipped("begin_event_chain", "unknown chain")
    end
    local evb = events_block(t.country, true)
    if not evb then
        return skipped("begin_event_chain", "no country")
    end
    if chain_entry(evb, t.chain) then
        return skipped("begin_event_chain", "active already")
    end
    local b = {}
    world.append(b, "event_chain", t.chain, true)
    world.append(b, "scope", t.scope)
    -- after the last event_chain entry (the list), else at the start
    local pos = 0
    for i, e in ipairs(evb) do
        if e.op and e.key and e.key.text == "event_chain" then pos = i end
    end
    world.insert(evb, pos + 1, "event_chain", b)
    return applied("begin_event_chain")
end

-- end_event_chain: t = { country, chain } (CCountryEventManager::EndEventChain 0x8020d0): the chain
-- taken out (the others keep their order); its special projects in progress removed
-- (CTechnologyStatus::RemoveInprogressSpecialProject) [V]; the list of completed chains is not
-- written in the saves seen [I]
function systems.effects.end_event_chain(t)
    local evb = events_block(t.country, false)
    local e = evb and chain_entry(evb, t.chain)
    if not e then
        return skipped("end_event_chain", "not active")
    end
    world.remove_entry(evb, e)
    -- the special projects of the chain
    local removed = {}
    for i = #evb, 1, -1 do
        local x = evb[i]
        if x.op and x.key and x.key.text == "special_project" and type(x.value) == "table" and not x.value.text then
            local key = unq(world.field(x.value, "special_project"))
            local d = key and creation.special_project_def(key)
            if d and unq(defs.field(d.block, "event_chain")) == t.chain then
                removed[#removed + 1] = tonumber(world.field(x.value, "id"))
                world.remove_entry(evb, x)
            end
        end
    end
    if #removed > 0 then
        creation.remove_project_research(t.country, removed)
    end
    return applied("end_event_chain")
end

-- add_event_chain_counter: t = { country, chain, counter, amount }: the chain's counter, kept in
-- the chain's entry as `counter = { <key> = <value> }`, clamped to [0, max] [I]
function systems.effects.add_event_chain_counter(t)
    local evb = events_block(t.country, false)
    local e = evb and chain_entry(evb, t.chain)
    if not e then
        return skipped("add_event_chain_counter", "not active")
    end
    local d = defs.get("common/event_chains", t.chain)
    local cdef = d and defs.field(d.block, "counter")
    local max = cdef and type(cdef) == "table" and defs.field(cdef, t.counter)
    max = type(max) == "table" and tonumber(defs.field(max, "max")) or nil
    local cb = world.child(e.value, "counter")
    local v = (tonumber(world.field(cb, t.counter)) or 0) + t.amount
    if v < 0 then v = 0 end
    if max and v > max then v = max end
    world.set(cb, t.counter, v)
    return applied("add_event_chain_counter")
end

-- the special project types (common/special_projects: `special_project = { key = "X" ... }`)
local projects
function creation.special_project_def(key)
    if projects == nil then
        projects = {}
        local db = require("simscript.db")
        for _, file in ipairs(source.files(db.fs, "common/special_projects", "txt")) do
            for _, e in ipairs(source.parse(db.fs, file) or {}) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    local k = unq(defs.field(e.value, "key"))
                    if k then projects[k] = { block = e.value, file = file } end
                end
            end
        end
    end
    return projects[key]
end

-- research queue items of special projects taken out (the tech_status queues' `special_project = id`)
function creation.remove_project_research(country, ids)
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    local status = world.field(world.object("country", country), "tech_status")
    if type(status) ~= "table" then return end
    local function scrub(b, depth)
        if depth > 4 or type(b) ~= "table" then return end
        for i = #b, 1, -1 do
            local x = b[i]
            if type(x) == "table" and not x.text then
                local v = x.op and x.value or x
                if type(v) == "table" and not v.text and set[tonumber(world.field(v, "special_project"))] then
                    world.remove_at(b, i)
                else
                    scrub(v, depth + 1)
                end
            end
        end
    end
    scrub(status, 0)
end

-- enable_special_project: t = { country, project, scope (a scope block), location = { kind, id },
-- wait (the AI's wait days) } (CEnableSpecialProjectEffect::EnableSpecialProject 0x16e37e0 ->
-- CSpecialProjectInstance): id = the country's next_special_project_id (advanced); the scope
-- copied; the location's coordinate (spatial object) and colony carrier; ai_research_date = today +
-- 24 h x (AI_wait_days' weight + one draw % NAI AI_COMMUNICATIONS_RANDOM_VALUE) (GetAIWaitDays
-- 0x4dcaf0) [V]
function systems.effects.enable_special_project(t)
    local d = creation.special_project_def(t.project)
    if not d then
        return skipped("enable_special_project", "unknown project")
    end
    local evb = events_block(t.country, true)
    if not evb then
        return skipped("enable_special_project", "no country")
    end
    local id = tonumber(world.field(evb, "next_special_project_id")) or 1
    world.set(evb, "next_special_project_id", id + 1)
    local b = {}
    world.append(b, "id", id)
    world.append(b, "special_project", t.project, true)
    world.append(b, "scope", t.scope)
    local loc = t.location
    if loc then
        local htype = loc.kind == "planet" and 2 or loc.kind == "ship" and 1 or loc.kind == "system" and 0 or nil
        if htype then
            local c = {}
            world.append(c, "type", htype)
            world.append(c, "id", loc.id)
            world.append(b, "coordinate", c)
        end
        if loc.kind == "planet" or loc.kind == "ship" then
            local carrier = {}
            world.append(carrier, "type", loc.kind)
            world.append(carrier, "reference", loc.id)
            world.append(b, "carrier", carrier)
        end
    end
    local r = draw()
    local define = require("engine.defs").get("common/defines", "NAI")
    local rv = define and tonumber(defs.field(define.block, "AI_COMMUNICATIONS_RANDOM_VALUE")) or 1
    local days = trunc(t.wait or 0) + (rv > 0 and r % rv or 0)
    world.append(b, "ai_research_date", date_text(require("simscript.eval").today() + days), true)
    -- after the other special projects
    local pos
    for i, e in ipairs(evb) do
        if e.op and e.key and (e.key.text == "special_project" or e.key.text == "event_chain") then pos = i end
    end
    world.insert(evb, (pos or 0) + 1, "special_project", b)
    applied("enable_special_project")
    return id
end

-- abort_special_project: t = { country, project }: the country's projects of that type taken out
-- with their research (CAbortSpecialProjectEffect) [I]
function systems.effects.abort_special_project(t)
    local evb = events_block(t.country, false)
    if not evb then return skipped("abort_special_project", "no country") end
    local removed = {}
    for i = #evb, 1, -1 do
        local x = evb[i]
        if x.op and x.key and x.key.text == "special_project" and type(x.value) == "table" and not x.value.text
            and unq(world.field(x.value, "special_project")) == t.project then
            removed[#removed + 1] = tonumber(world.field(x.value, "id"))
            world.remove_entry(evb, x)
        end
    end
    if #removed == 0 then return skipped("abort_special_project", "none") end
    creation.remove_project_research(t.country, removed)
    return applied("abort_special_project")
end

-- set_site_progress_locked: t = { kind, id, locked } (CSetSiteProgressLockedEffect 0x17b6370): an
-- archaeological site's lock (+0x178; the save's `locked = yes` [I]); a first contact's status
-- locked / in_progress unless it is finished or aborted (status 2 and 3) [V]
function systems.effects.set_site_progress_locked(t)
    if t.kind == "archaeological_site" then
        local s = world.object("sites", t.id)
        if not s then return skipped("set_site_progress_locked", "no site") end
        if t.locked then
            world.set(s, "locked", "yes")
        else
            for _, e in ipairs(s) do
                if e.op and e.key and e.key.text == "locked" then world.remove_entry(s, e); break end
            end
        end
        return applied("set_site_progress_locked")
    elseif t.kind == "first_contact" then
        local fc = world.object("first_contact", t.id)
        if not fc then return skipped("set_site_progress_locked", "no first contact") end
        local st = unq(world.field(fc, "status"))
        if st ~= "finished" and st ~= "aborted" then
            world.set(fc, "status", t.locked and "locked" or "in_progress")
        end
        return applied("set_site_progress_locked")
    end
    return skipped("set_site_progress_locked", "not a site")
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
