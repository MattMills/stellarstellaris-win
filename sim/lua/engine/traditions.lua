-- engine/traditions.lua : traditions and ascension perks, the game's way (GOG 4.5.2; docs/traditions.md),
-- on the save's own fields of a country:
--
--   tradition_categories = { "tradition_discovery" }
--   traditions = { "tr_discovery_adopt" "tr_discovery_science_division" }
--   ascension_perks = { "ap_x" }                       (written when there are any)
--   last_picked_tradition = "tr_discovery_science_division"
--
-- The cost (CTraditionType::CalcCost, 0x4c0f00; static over the country, the tradition does not
-- enter it), with n the number of the country's traditions (adoption and finisher included):
--
--   cost[r] = TRADITION_COST_AMOUNTS[r]                     (NEconomy: { unity = 300 })
--             + (n * TRADITION_COST_TRADITION) ^ TRADITION_COST_TRADITION_EXP      (8, 1.8)
--   * (1 + groups * TRADITION_COST_MULT_TRADITION_GROUP)    (groups: the adoption traditions; 0.0)
--   * (1 + p)                                               (the empire size)
--   * max(1 + tradition_cost_mult, 0)
--   * galaxy.traditions                                     (the galaxy setting, when > 0)
--   p = EMPIRE_SIZE_TRADITION_COST_PENALTY * max(0, empire_size - cap) * max(1 + empire_size_penalty_mult, 0)
--       * max(1 + tradition_cost_empire_size_mult, 0)
--   cap = (EMPIRE_SIZE_BASE + country_admin_cap_add) * max(1 + country_admin_cap_mult, 0)
--
-- Adoption (CCountryActivateTraditionCommand::Execute, 0x6c6ae0): the cost removed from the
-- stockpile, then CCountry::ActivateTradition (0x74cdf0): the category added when it is new, the
-- tradition (or perk) appended, last_picked_tradition (not for perks), the modifiers invalidated,
-- then OnEnabled (0x4c2870): one draw of the game's generator (the effect scope's seed), the
-- on_enabled effect (the tradition swap's own when one applies and does not inherit effects), the
-- on_action on_tradition_picked (on_ascension_perk_picked for a perk), and the category's finisher
-- activated (without cost) once it is possible, i.e. when every other tradition of the category
-- is there.
--
--   local traditions = require("engine.traditions")
--   traditions.cost(country, tradition)        -- { unity = 818.2 }, 818.2
--   traditions.can_activate(country, name, true)
--   traditions.activate(country, name, host)   -- the command: checked, paid, activated

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local traditions = {
    TRADITION = 1, PERK = 2,
    stats = { adopted = 0, perks = 0, finishers = 0, activated = 0, refused = 0, effects = 0, effect_errors = 0,
        trigger_errors = 0, draws = 0 },
    log = {},   -- { country, tradition, kind, date, cost, unity_before } in the order they happened
}

-- ---------------------------------------------------------------------------------------------
-- the defines

local D
local function define(group, key)
    local g = defs.get("common/defines", group)
    local v = g and defs.field(g.block, key)
    if v ~= nil then
        return v
    end
    for _, d in pairs(defs.folder("common/defines")) do
        v = defs.field(d.block, key)
        if v ~= nil then return v end
    end
    return nil
end
local function list_values(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = e.text
        end
    end
    return out
end
local function defines()
    if D then
        return D
    end
    local function num(group, key, default)
        return tonumber(define(group, key)) or default
    end
    D = {
        TRADITION_COST_TRADITION = num("NGameplay", "TRADITION_COST_TRADITION", 8),
        TRADITION_COST_TRADITION_EXP = num("NGameplay", "TRADITION_COST_TRADITION_EXP", 1.8),
        TRADITION_COST_MULT_TRADITION_GROUP = num("NGameplay", "TRADITION_COST_MULT_TRADITION_GROUP", 0),
        EMPIRE_SIZE_TRADITION_COST_PENALTY = num("NGameplay", "EMPIRE_SIZE_TRADITION_COST_PENALTY", 0.002),
        EMPIRE_SIZE_BASE = num("NGameplay", "EMPIRE_SIZE_BASE", 100),
        TRADITION_CATEGORIES_MAX = num("NGameplay", "TRADITION_CATEGORIES_MAX", 7),
        ASCENSION_PERKS_SLOTS = num("NGameplay", "ASCENSION_PERKS_SLOTS", 8),
        COST = {},  -- { { resource, amount } } (NResourceUtil::ConstructBaseCostFromDefines)
    }
    local res = list_values(define("NEconomy", "TRADITION_COST_RESOURCES"))
    local amounts = list_values(define("NEconomy", "TRADITION_COST_AMOUNTS"))
    for i, r in ipairs(res) do
        D.COST[#D.COST + 1] = { resource = r, amount = tonumber(amounts[i]) or 0 }
    end
    if #D.COST == 0 then
        D.COST[1] = { resource = "unity", amount = 300 }
    end
    return D
end
traditions.defines = defines

-- ---------------------------------------------------------------------------------------------
-- the definitions: the databases in the game's order (the files by name, the definitions in file
-- order: the index of CTraditionType +8, which the AI's weighted pick runs over)

local DB
local function sorted(folder)
    local list = {}
    for name, d in pairs(defs.folder(folder)) do
        list[#list + 1] = { name = name, def = d }
    end
    table.sort(list, function(a, b)
        if a.def.file ~= b.def.file then
            return tostring(a.def.file) < tostring(b.def.file)
        end
        return (a.def.line or 0) < (b.def.line or 0)
    end)
    return list
end
local function load()
    if DB then
        return DB
    end
    DB = { types = {}, type_by = {}, perks = {}, perk_by = {}, categories = {}, category_by = {} }
    for i, e in ipairs(sorted("common/traditions")) do
        local t = { name = e.name, block = e.def.block, file = e.def.file, kind = traditions.TRADITION, index = i }
        DB.types[i], DB.type_by[e.name] = t, t
    end
    for i, e in ipairs(sorted("common/ascension_perks")) do
        local t = { name = e.name, block = e.def.block, file = e.def.file, kind = traditions.PERK, index = i }
        DB.perks[i], DB.perk_by[e.name] = t, t
    end
    -- CTraditionCategory (+344 the adoption, +352 the finisher, +368 the traditions: the listed ones,
    -- the adoption and the finisher added); each tradition's category (+80) set by the category
    for i, e in ipairs(sorted("common/tradition_categories")) do
        local b = e.def.block
        local c = { name = e.name, block = b, file = e.def.file, index = i,
            adoption = defs.field(b, "adoption_bonus"), finisher = defs.field(b, "finish_bonus"), traditions = {} }
        if type(c.adoption) ~= "string" then c.adoption = nil end
        if type(c.finisher) ~= "string" then c.finisher = nil end
        local members = {}
        if c.adoption then members[#members + 1] = c.adoption end
        for _, name in ipairs(list_values(defs.field(b, "traditions"))) do
            members[#members + 1] = name
        end
        if c.finisher then members[#members + 1] = c.finisher end
        for _, name in ipairs(members) do
            local t = DB.type_by[name]
            if t then
                c.traditions[#c.traditions + 1] = name
                if t.category == nil then
                    t.category = c.name
                end
            end
        end
        DB.categories[i], DB.category_by[e.name] = c, c
    end
    return DB
end

-- traditions.type(name) -> the tradition or perk ({ name, block, file, kind, index, category })
function traditions.type(name)
    local db = load()
    return db.type_by[name] or db.perk_by[name]
end
-- the traditions in the database's order; the perks; the categories
function traditions.types() return load().types end
function traditions.perk_types() return load().perks end
function traditions.category(name) return load().category_by[name] end
function traditions.categories() return load().categories end

-- ---------------------------------------------------------------------------------------------
-- a country's traditions (the save's lists)

local function country_of(id)
    return world.object("country", id)
end

local function names(id, key)
    return world.list(world.field(country_of(id), key))
end
-- traditions.of(country) -> the tradition names in order; categories_of; perks_of
function traditions.of(id) return names(id, "traditions") end
function traditions.categories_of(id) return names(id, "tradition_categories") end
function traditions.perks_of(id) return names(id, "ascension_perks") end

local function contains(list, name)
    for i, v in ipairs(list) do
        if v == name then return i end
    end
    return nil
end
-- CCountry::HasTradition / HasAscensionPerk / HasTraditionCategory
function traditions.has(id, name) return contains(traditions.of(id), name) ~= nil end
function traditions.has_perk(id, name) return contains(traditions.perks_of(id), name) ~= nil end
function traditions.has_category(id, cat) return contains(traditions.categories_of(id), cat) ~= nil end

-- CCountry::HasCompletedTraditionCategory (0x74cd70): the category adopted and its finisher there
function traditions.completed_category(id, cat)
    local c = traditions.category(cat)
    return c ~= nil and c.finisher ~= nil and traditions.has_category(id, cat) and traditions.has(id, c.finisher)
end

-- has_unlocked_all_traditions (CHasUnlockedAllTraditionsTrigger::ActualEvaluate, 0x197e8f0):
-- TRADITION_CATEGORIES_MAX categories adopted, all completed
function traditions.unlocked_all(id)
    local cats = traditions.categories_of(id)
    if #cats < defines().TRADITION_CATEGORIES_MAX then
        return false
    end
    for _, cat in ipairs(cats) do
        if not traditions.completed_category(id, cat) then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the cost

local function modifiers_of(id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers("country", id) or {}
end

-- the galaxy setting `traditions` (CGalaxyConfiguration +216: the tradition cost slider)
local galaxy_mult
local function galaxy_traditions()
    if galaxy_mult == nil then
        galaxy_mult = 1
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "galaxy" and e.value.text == nil then
                galaxy_mult = tonumber(world.field(e.value, "traditions")) or 1
            end
        end
    end
    return galaxy_mult
end

-- CModifier::ApplyModifierMult: x * max(1 + modifier, 0) (the modifier definitions' minimum is 0)
local function mult(M, name)
    return math.max(1 + (M[name] or 0), 0)
end

-- traditions.cost(country[, tradition]) -> { resource = amount }, the unity amount; a perk costs
-- nothing (CTraditionType::CanActivate skips the cost for kind 2)
function traditions.cost(id, name)
    local t = name and traditions.type(name)
    if t and t.kind == traditions.PERK then
        return {}, 0
    end
    local d = defines()
    local list = traditions.of(id)
    local cost = {}
    for _, e in ipairs(d.COST) do
        cost[e.resource] = (cost[e.resource] or 0) + e.amount
    end
    -- (n * TRADITION_COST_TRADITION) ^ TRADITION_COST_TRADITION_EXP (NFixedInt64Internal::ipow,
    -- exp2(e * log2 x) in fixed point; 0 stays 0), added to each resource of the base cost
    local x = #list * d.TRADITION_COST_TRADITION
    if x ~= 0 then
        x = x ^ d.TRADITION_COST_TRADITION_EXP
    end
    for r, v in pairs(cost) do
        if v ~= 0 then
            cost[r] = v + x
        end
    end
    local factor = 1
    -- the adopted groups (the traditions that are their category's adoption)
    local groups = 0
    for _, n in ipairs(list) do
        local tt = traditions.type(n)
        local c = tt and tt.category and traditions.category(tt.category)
        if c and c.adoption == n then
            groups = groups + 1
        end
    end
    local g = groups * d.TRADITION_COST_MULT_TRADITION_GROUP
    if g ~= 0 then
        factor = factor * (1 + g)
    end
    -- the empire size above the administrative capacity
    local M = modifiers_of(id)
    local size = tonumber(world.field(country_of(id), "empire_size")) or 0
    local cap = (d.EMPIRE_SIZE_BASE + (M.country_admin_cap_add or 0)) * mult(M, "country_admin_cap_mult")
    local excess = math.max(size - cap, 0) * mult(M, "empire_size_penalty_mult")
    local p = excess * d.EMPIRE_SIZE_TRADITION_COST_PENALTY * mult(M, "tradition_cost_empire_size_mult")
    factor = factor * (1 + p)
    if (M.tradition_cost_mult or 0) ~= 0 then
        factor = factor * mult(M, "tradition_cost_mult")
    end
    local gal = galaxy_traditions()
    if gal > 0 then
        factor = factor * gal
    end
    for r, v in pairs(cost) do
        -- the game's fixed point (5 decimals)
        cost[r] = math.floor(v * factor * 100000) / 100000
    end
    return cost, cost.unity or 0
end

-- the parts of the cost, for a check: n, the base, the size penalty p, the modifiers
function traditions.cost_parts(id)
    local d = defines()
    local M = modifiers_of(id)
    local size = tonumber(world.field(country_of(id), "empire_size")) or 0
    local cap = (d.EMPIRE_SIZE_BASE + (M.country_admin_cap_add or 0)) * mult(M, "country_admin_cap_mult")
    return {
        n = #traditions.of(id), size = size, cap = cap,
        tradition_cost_mult = M.tradition_cost_mult or 0,
        tradition_cost_empire_size_mult = M.tradition_cost_empire_size_mult or 0,
        empire_size_penalty_mult = M.empire_size_penalty_mult or 0,
        galaxy = galaxy_traditions(),
    }
end

-- ---------------------------------------------------------------------------------------------
-- the conditions

local function trigger(block, id, file)
    if type(block) ~= "table" then
        return true
    end
    local ok, r = pcall(eval.trigger, block, eval.new_ctx(eval.S("country", id), nil, nil, file))
    if not ok then
        traditions.stats.trigger_errors = traditions.stats.trigger_errors + 1
        return false
    end
    return r and true or false
end

-- CTraditionType::IsPotential (0x4c1da0): `potential`; FulfillsPossibleTrigger (0x4c35c0): `possible`
function traditions.is_potential(id, name)
    local t = traditions.type(name)
    return t ~= nil and trigger(defs.field(t.block, "potential"), id, t.file)
end
function traditions.fulfills_possible(id, name)
    local t = traditions.type(name)
    return t ~= nil and trigger(defs.field(t.block, "possible"), id, t.file)
end
-- CTraditionCategory::IsPotential (0x4bb250): `potential` (true without one)
function traditions.category_potential(id, cat)
    local c = traditions.category(cat)
    return c ~= nil and trigger(defs.field(c.block, "potential"), id, c.file)
end

-- CTraditionType::IsPossible (0x4c2140): potential; not had (as a tradition or a perk); a
-- category's tradition needs the category's adoption, a finisher every other tradition of its
-- category; possible
function traditions.is_possible(id, name)
    local t = traditions.type(name)
    if not t or not country_of(id) then
        return false
    end
    if not traditions.is_potential(id, name) then
        return false
    end
    if traditions.has(id, name) or traditions.has_perk(id, name) then
        return false
    end
    local c = t.category and traditions.category(t.category)
    if c then
        if c.adoption and c.adoption ~= name and not traditions.has(id, c.adoption) then
            return false
        end
        if c.finisher == name then
            local have = traditions.of(id)
            for _, other in ipairs(c.traditions) do
                if other ~= name and not contains(have, other) then
                    return false
                end
            end
        end
    end
    return traditions.fulfills_possible(id, name)
end

-- CCountry::CalcTotalAscensionPerkPoints (0x74d1e0): ascension_perks_add, at most ASCENSION_PERKS_SLOTS
function traditions.perk_points(id)
    local v = modifiers_of(id).ascension_perks_add or 0
    v = v >= 0 and math.floor(v) or -math.floor(-v)
    return math.min(v, defines().ASCENSION_PERKS_SLOTS)
end

-- the country's stockpile block (made when create, for a payment; a read takes a missing one as empty)
local function stockpile(id, create)
    local c = country_of(id)
    local module = world.path(c, "modules", "standard_economy_module")
    if type(module) ~= "table" then return nil end
    return create and world.child(module, "resources") or world.field(module, "resources")
end
function traditions.stockpile(id, resource)
    return tonumber(world.field(stockpile(id), resource)) or 0
end

-- CEconomyCountryModule's affordability (vfunc +176): every resource of the cost in the stockpile
local function can_afford(id, cost)
    for r, v in pairs(cost) do
        if v > 0 and traditions.stockpile(id, r) < v then
            return false
        end
    end
    return true
end

-- CTraditionType::CanActivate (0x4c2610): possible; a tradition's cost affordable; a perk (with
-- slots checked) a free slot: CalcTotalAscensionPerkPoints - the perks > 0
function traditions.can_activate(id, name, check_slots)
    local t = traditions.type(name)
    if not t or not traditions.is_possible(id, name) then
        return false
    end
    if t.kind ~= traditions.PERK then
        if not can_afford(id, (traditions.cost(id, name))) then
            return false
        end
    elseif check_slots and traditions.perk_points(id) - #traditions.perks_of(id) <= 0 then
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- activation

local function quoted_list(c, key)
    return world.child(c, key)
end
local function append_name(block, name)
    block[#block + 1] = { text = name, quoted = true }
    world.wrote(block)
end

-- CTraditionType::GetTraditionSwap: of the `tradition_swap`s whose trigger holds, the one with
-- the highest weight (the first of equal ones), or none
function traditions.swap(id, name)
    local t = traditions.type(name)
    local best, best_w
    for _, e in ipairs(t and t.block or {}) do
        if e.op and e.key and e.key.text == "tradition_swap" and e.value.text == nil then
            if trigger(defs.field(e.value, "trigger"), id, t.file) then
                local wb = defs.field(e.value, "weight")
                local w = 1
                if type(wb) == "table" then
                    local ok, v = pcall(eval.weight, wb, eval.new_ctx(eval.S("country", id), nil, nil, t.file), 1)
                    w = ok and v or 1
                end
                if best_w == nil or w > best_w then
                    best, best_w = e.value, w
                end
            end
        end
    end
    return best
end

-- one draw of the game's generator (CRandom::GetIntegerForMacro): the seed of the effect's scope
local function scope_draw()
    local ok = pcall(eval.rand)
    if ok then
        traditions.stats.draws = traditions.stats.draws + 1
    end
end

-- CTraditionType::OnEnabled (0x4c2870)
local function on_enabled(id, t, host)
    scope_draw()
    local block = defs.field(t.block, "on_enabled")
    local swap = t.kind == traditions.TRADITION and traditions.swap(id, t.name)
    if swap and defs.field(swap, "inherit_effects") ~= "yes" then
        block = defs.field(swap, "on_enabled")
    end
    if type(block) == "table" and #block > 0 then
        local ok = pcall(eval.effect, block, eval.new_ctx(eval.S("country", id), nil, nil, t.file))
        traditions.stats.effects = traditions.stats.effects + 1
        if not ok then
            traditions.stats.effect_errors = traditions.stats.effect_errors + 1
        end
        pcall(eval.sync)
    end
    local c = t.category and traditions.category(t.category)
    if c then
        if host and host.on_action then
            host.on_action("on_tradition_picked", "country", id)
        end
        -- the finisher, once every other tradition of the category is there
        if c.finisher and c.finisher ~= t.name and traditions.is_possible(id, c.finisher) then
            traditions.stats.finishers = traditions.stats.finishers + 1
            traditions.add(id, c.finisher, host)
        end
    elseif host and host.on_action then
        host.on_action("on_ascension_perk_picked", "country", id)
    end
end

-- traditions.add(country, name, host): CCountry::ActivateTradition (0x74cdf0) and ExecuteTradition
-- (0x70c950), without cost: the category added when new, the tradition appended (a perk to
-- ascension_perks), last_picked_tradition, the modifiers invalidated, OnEnabled
function traditions.add(id, name, host)
    local c = country_of(id)
    local t = traditions.type(name)
    if not c or not t then
        return false
    end
    if t.category and not traditions.has_category(id, t.category) then
        append_name(quoted_list(c, "tradition_categories"), t.category)
    end
    if t.kind == traditions.PERK then
        append_name(quoted_list(c, "ascension_perks"), name)
        traditions.stats.perks = traditions.stats.perks + 1
    else
        append_name(quoted_list(c, "traditions"), name)
        local last = world.field(c, "last_picked_tradition")
        if last ~= nil and type(last) ~= "table" then
            world.set(c, "last_picked_tradition", name)
        else
            world.append(c, "last_picked_tradition", name, true)
        end
    end
    traditions.stats.activated = traditions.stats.activated + 1
    -- UpdateTriggeredAndNonTriggeredTraditionAndAPModifiers + InvalidateModifier: the country's
    -- modifiers change (the modifier source picks them up when it is built from the world)
    local economy = package.loaded["engine.economy"]
    if economy and economy.invalidate then
        economy.invalidate()
    end
    on_enabled(id, t, host)
    return true
end

-- traditions.pay(country, cost): CEconomyCountryModule::RemoveResources
function traditions.pay(id, cost)
    local stock = stockpile(id, true)
    if not stock then
        return false
    end
    for r, v in pairs(cost) do
        if v ~= 0 then
            local now = tonumber(world.field(stock, r)) or 0
            world.set(stock, r, math.floor((now - v) * 100000 + 0.5) / 100000)
        end
    end
    return true
end

-- traditions.activate(country, name, host[, date]) -> whether it was activated: the command
-- (CCountryActivateTraditionCommand / CCountryActivateAscensionPerkCommand): IsValid
-- (CanActivate with the perk slots checked), then Execute: a tradition's cost paid
-- (CTraditionType::CalcCost, RemoveResources), then CCountry::ActivateTradition
function traditions.activate(id, name, host, date)
    local t = traditions.type(name)
    if not t or not traditions.can_activate(id, name, true) then
        traditions.stats.refused = traditions.stats.refused + 1
        return false
    end
    local entry = { country = id, tradition = name, kind = t.kind == traditions.PERK and "perk" or "tradition",
        date = date, unity_before = traditions.stockpile(id, "unity") }
    if t.kind ~= traditions.PERK then
        local cost, unity = traditions.cost(id, name)
        traditions.pay(id, cost)
        entry.cost = unity
        traditions.stats.adopted = traditions.stats.adopted + 1
    end
    traditions.log[#traditions.log + 1] = entry
    return traditions.add(id, name, host)
end

function traditions.report()
    local s = traditions.stats
    return string.format("traditions: %d adopted, %d perks, %d finishers, %d activated, %d refused; %d on_enabled effects (%d errors), %d scope draws",
        s.adopted, s.perks, s.finishers, s.activated, s.refused, s.effects, s.effect_errors, s.draws)
end

return traditions
