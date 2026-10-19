-- engine/market.lua : the galactic and internal markets and the country budgets as the script reads
-- and changes them (docs/script_economy.md). The market is the save's top-level `market = { ... }`
-- (CMarket), the budgets each country's `budget = { current_month last_month }` (CCountryBudget).
-- Read in the 4.5.2 Linux build (CMarket, NMarketUtil, CCountryBudget;
-- code_working/tmp_sim/economy_market_re.md, wire_market_re.md, cov_market_re.md).
--
--   local market = require("engine.market")
--   market.enabled()                         -- the galactic market founded (`enabled = yes`)
--   market.has_access(country)               -- CMarket::HasGalacticMarketAccess
--   market.resource_enabled(key)             -- the resource on the galactic market
--   market.valid_resource(country, key, t)   -- CMarket::IsValidResource (t 0 buy, 1 sell, 2 any)
--   market.price(country, key, amount, t)    -- CalcResourcePriceForAmount ("market_buy",
--                                            -- "market_sell", "not_set")
--   market.leader() / market.set_leader(id)  -- the market leader's country id
--   market.set_access(country, yes)          -- CMarket::SetGalacticMarketAccess
--   market.enable_resource(key)              -- EnableResourceOnGalacticMarket
--   market.budget(country, month, side, cat, key)  -- a budget sum (CCountryBudget's cached sums)
--   market.capacity(country, key)            -- CStrategicResource::GetMaximumForCountry
--   market.set_stockpile(country, key, v)    -- CEconomyCountryModule::SetResource

local world = require("engine.world")

local market = {}

local ONE = 100000
local NO_ID = 4294967295

local function trunc(v)
    return v >= 0 and math.floor(v) or -math.floor(-v)
end
local function fx(v)
    v = tonumber(v) or 0
    return v >= 0 and math.floor(v * ONE + 0.5) or -math.floor(-v * ONE + 0.5)
end
local function mul(a, b)
    return trunc(a * b / ONE)
end
local function div(a, b)
    if b == 0 then
        return 0
    end
    return trunc(a * ONE / b)
end
market.fx, market.mul, market.div, market.ONE, market.NO_ID = fx, mul, div, ONE, NO_ID

local function defs()
    return require("engine.defs")
end
local function unq(v)
    if type(v) ~= "string" then
        return v
    end
    return (v:gsub('^"(.*)"$', "%1"))
end

-- NDefines::NEconomy (the defaults the game's defines file has)
local DEF = {
    MARKET_TRADE_FEE_BASE = 0.3, MARKET_TRADE_FEE_MIN = 0.05,
    MARKET_FLUCTUATION_ABOVE_BASE_PRICE = 1, MARKET_FLUCTUATION_BELOW_BASE_PRICE = 0.3,
    MARKET_MIN_FLUCTUATION_FROM_BASE_PRICE = -80, MARKET_MAX_FLUCTUATION_FROM_BASE_PRICE = 400,
    MARKET_MAX_BASE_AMOUNTS = 200, INTERNAL_MARKET_FLUCTUATION_MULT = 2,
}
local defines
function market.defines()
    if defines then
        return defines
    end
    defines = {}
    for k, v in pairs(DEF) do
        defines[k] = v
    end
    local ok, d = pcall(defs)
    local g = ok and d.get and d.get("common/defines", "NEconomy")
    if g then
        for k in pairs(DEF) do
            local v = tonumber(d.field(g.block, k))
            if v then
                defines[k] = v
            end
        end
    end
    return defines
end

-- the resources in their definition order (CStrategicResourceDatabase; index 0-based as the
-- market's per-resource lists): key, index, def block, tradable, market_amount, market_price
-- (a resource without them: -1, the game's defaults)
local resources, by_key
function market.resources()
    if resources then
        return resources, by_key
    end
    resources, by_key = {}, {}
    local d = defs()
    local list = {}
    for name, def in pairs(d.folder("common/strategic_resources")) do
        list[#list + 1] = { name = name, def = def }
    end
    table.sort(list, function(a, b)
        if (a.def.file or "") ~= (b.def.file or "") then
            return (a.def.file or "") < (b.def.file or "")
        end
        return (a.def.line or 0) < (b.def.line or 0)
    end)
    for i, x in ipairs(list) do
        local b = x.def.block
        local r = {
            key = x.name, index = i - 1, block = b,
            tradable = d.field(b, "tradable") == "yes",
            market_amount = tonumber(d.field(b, "market_amount")) or -1,
            market_price = tonumber(d.field(b, "market_price")) or -1,
        }
        resources[i] = r
        by_key[r.key] = r
    end
    return resources, by_key
end
function market.resource(key)
    local _, by = market.resources()
    return by[unq(key)]
end

-- the market's block (made when the save has none)
function market.block()
    local m = world.meta.market
    if type(m) ~= "table" then
        m = {}
        world.meta.market = m
    end
    return m
end

local function numbers(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = tonumber(e.text) or 0
        end
    end
    return out
end
market.numbers = numbers

-- a number list's value i (1-based) set, the list grown with `fill`
local function set_list(block, i, value, fill)
    local vals = {}
    for _, e in ipairs(block) do
        if e.text then
            vals[#vals + 1] = e
        end
    end
    while #vals < i do
        local e = { text = tostring(fill) }
        world.append_entry(block, e)
        vals[#vals + 1] = e
    end
    world.set_entry(block, vals[i], world.number_text(value))
end
market.set_list = set_list

-- `key = "text"` set (the first token entry), or added
function market.set_quoted(obj, key, text)
    world.set(obj, key, text)
    local e = world.token_entry(obj, key)
    if e then
        e.value.quoted = true
    end
end

-- the galactic market founded (CMarket +0x128, saved `enabled = yes`)
function market.enabled()
    return world.field(market.block(), "enabled") == "yes"
end

-- a country's index (an id's low 24 bits)
function market.index(country)
    return country % 16777216
end

-- CMarket::HasGalacticMarketAccess (0x1d49910) [V]: the market enabled, id[ci] the country and
-- access[ci] 1 (ci = the country's index) [I: the game rule can_use_galactic_market always on]
function market.has_access(country)
    if not country or not world.object("country", country) or not market.enabled() then
        return false
    end
    local m = market.block()
    local i = market.index(country) + 1
    return numbers(world.field(m, "id"))[i] == country and numbers(world.field(m, "galactic_market_access"))[i] == 1
end

-- CMarket::IsResourceEnabledOnGalacticMarket (0x1d4b1a0) [V]: galactic_market_resources[index] == 1
function market.resource_enabled(key)
    local r = market.resource(key)
    if not r then
        return false
    end
    return numbers(world.field(market.block(), "galactic_market_resources"))[r.index + 1] == 1
end

-- EnableResourceOnGalacticMarket (0x1d4b180) [V]: galactic_market_resources[index] = 1 when the list
-- reaches it (SetGalacticMarketEnabled sized it to the resources)
function market.enable_resource(key)
    local r = market.resource(key)
    local list = r and world.field(market.block(), "galactic_market_resources")
    if type(list) ~= "table" or #numbers(list) <= r.index then
        return false
    end
    set_list(list, r.index + 1, 1, 0)
    return true
end

-- the market leader (`country`, NO_ID none)
function market.leader()
    local v = tonumber(world.field(market.block(), "country"))
    if not v or v == NO_ID then
        return nil
    end
    return v
end
-- CMarket::SetGalacticMarketLeader (0x1d49df0): `country` = the id (nil: none)
function market.set_leader(country)
    world.set(market.block(), "country", country or NO_ID)
end

-- CMarket::SetGalacticMarketAccess (0x1d49cd0) [V]: AddCountryForAccess grows galactic_market_access
-- (0) and id (-1) to the country's index and sets id[ci]; then access[ci] = yes and 1 or 0
function market.set_access(country, yes)
    local m = market.block()
    local i = market.index(country) + 1
    local access = world.child(m, "galactic_market_access")
    local ids = world.child(m, "id")
    if #numbers(access) < i then
        set_list(access, i, 0, 0)
    end
    set_list(ids, i, country, -1)
    set_list(access, i, yes and 1 or 0, 0)
end

-- ---------------------------------------------------------------------------------------------
-- the budgets

-- CCountryBudget's cached sums (UpdateCachedValues 0x240a000) [V]: a page's (current_month,
-- last_month) block0 (income, expenses, balance) plus its block1 (trade_income, trade_expenses,
-- trade_balance), for one economic category or all of them; a missing resource is 0
function market.budget(country, month, side, category, key)
    local c = world.object("country", country)
    local page = c and world.path(c, "budget", month)
    if type(page) ~= "table" then
        return 0
    end
    local sum = 0
    for _, name in ipairs({ side, "trade_" .. side }) do
        local block = world.field(page, name)
        for k, v in world.statements(type(block) == "table" and block or {}) do
            if type(v) == "table" then
                if not category or k == category then
                    sum = sum + (tonumber(world.field(v, key)) or 0)
                end
            elseif k == key and not category then
                -- (a flat trade block: the resource itself)
                sum = sum + (tonumber(v) or 0)
            end
        end
    end
    return sum
end

-- an economic category (common/economic_categories)
function market.category(name)
    return name and defs().get("common/economic_categories", unq(name)) ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- the stockpile

-- CStrategicResource::GetMaximumForCountry (0x2072e80) [V]: the resource's max (negative: none, nil
-- here), fixed_max_amount as written; else the max with dynamic_capacity and the country's max
-- modifiers (engine.economy.capacity; special_max_amount leaves out country_resource_max_add)
function market.capacity(country, key)
    local r = market.resource(key)
    if not r or not world.object("country", country) then
        return nil
    end
    local max = tonumber(defs().field(r.block, "max"))
    if not max or max < 0 then
        return nil
    end
    local economy = package.loaded["engine.economy"] or require("engine.economy")
    local cap = economy.capacity and economy.capacity(country, r.key) or max
    if defs().field(r.block, "special_max_amount") == "yes" and defs().field(r.block, "fixed_max_amount") ~= "yes" then
        local m = economy.modifiers and economy.modifiers("country", country) or {}
        cap = cap - (m.country_resource_max_add or 0)
    end
    return cap
end

-- ---------------------------------------------------------------------------------------------
-- resource converters (common/resource_converters; a country's
-- `modules.standard_economy_module.resource_conversions = "<key>"`, CEconomyCountryModule +0x20)

local function economy_module(country, create)
    local c = world.object("country", country)
    if not c then
        return nil
    end
    if create then
        return world.child(world.child(c, "modules"), "standard_economy_module")
    end
    local m = world.path(c, "modules", "standard_economy_module")
    return type(m) == "table" and m or nil
end
market.economy_module = economy_module

-- the country's converter: its key and its definition's block
function market.converter(country)
    local m = country and economy_module(country, false)
    local key = m and unq(world.field(m, "resource_conversions"))
    local d = key and defs().get("common/resource_converters", key)
    if not d then
        return nil
    end
    return key, d.block
end
-- the converter's entry of a resource (resource_conversions = { <resource> = { ... } })
local function conversion(country, key)
    local _, block = market.converter(country)
    local rc = block and defs().field(block, "resource_conversions")
    local e = type(rc) == "table" and defs().field(rc, key)
    return type(e) == "table" and e or nil
end
local function conv_flag(country, key, flag, default)
    local e = conversion(country, key)
    local v = e and defs().field(e, flag)
    if v == nil then
        return default
    end
    return v == "yes"
end
-- CEconomyCountryModule::CanBuyResource / CanSellResource [I: a resource the converter does not
-- list, or a flag not written: yes]; OverridesTradeRestriction; IsResourceCapped's should_cap
function market.can_buy(country, key) return conv_flag(country, key, "can_buy", true) end
function market.can_sell(country, key) return conv_flag(country, key, "can_sell", true) end
function market.overrides_restriction(country, key) return conv_flag(country, key, "override_trade_restriction", false) end
function market.should_cap(country, key) return conv_flag(country, key, "should_cap", true) end

-- CEconomyCountryModule::SetResourceConverter (0x24ed9a0) [V]: the key written (nil: the entry
-- taken out); then the country's monthly trades the converter cannot make (a buy it cannot buy, a
-- sell it cannot sell) removed (CMarket::RemoveMonthlyTrade)
function market.set_converter(country, key)
    local m = economy_module(country, true)
    if not m then
        return false
    end
    if key then
        market.set_quoted(m, "resource_conversions", key)
    else
        local e = world.entry(m, "resource_conversions")
        if e then
            world.remove_entry(m, e)
        end
    end
    if not key then
        return true
    end
    local list = world.field(market.block(), "monthly_trades")
    if type(list) ~= "table" then
        return true
    end
    local keep, removed = {}, false
    for _, e in ipairs(list) do
        local td = type(e) == "table" and e.text == nil and not e.op and world.field(e, "trade_data")
        local drop = false
        if td and tonumber(world.field(td, "country")) == country then
            local r = unq(world.field(td, "resource"))
            local buy = unq(world.field(td, "trade_type")) == "market_buy"
            drop = buy and not market.can_buy(country, r) or (not buy and not market.can_sell(country, r))
        end
        if drop then
            removed = true
        else
            keep[#keep + 1] = e
        end
    end
    if removed then
        world.replace(list, keep)
    end
    return true
end

-- the stockpile of a resource (R.stockpile: research from tech_status.stored_techpoints)
function market.stockpile(country, key)
    return require("engine.script.runtime").stockpile(country, key)
end

local RESEARCH = { physics_research = 1, society_research = 2, engineering_research = 3 }

-- CEconomyCountryModule::SetResource (0x24ef350) [V]: the value set exactly, then every resource
-- clamped to [0, max] (IsResourceCapped); research to tech_status.stored_techpoints
function market.set_stockpile(country, key, value)
    local c = world.object("country", country)
    if not c then
        return false
    end
    local function clamp(k, v)
        v = math.max(v, 0)
        local cap = market.should_cap(country, k) and market.capacity(country, k)
        if cap and v >= cap then
            v = cap
        end
        return math.floor(v * ONE + 0.5) / ONE
    end
    -- (research is also tech_status.stored_techpoints, which the game keeps equal [V: both 0 after
    -- clear_resources])
    local ri = RESEARCH[key]
    if ri then
        local tp = world.child(world.child(c, "tech_status"), "stored_techpoints")
        set_list(tp, ri, clamp(key, value), 0)
    end
    do
        local module = world.child(world.child(c, "modules"), "standard_economy_module")
        local res = world.child(module, "resources")
        world.set(res, key, clamp(key, value))
        -- (the clamp pass over the others: a resource over its max comes down to it)
        for k, v in world.statements(res) do
            local n = tonumber(v)
            if n and k ~= key then
                local cv = clamp(k, n)
                if cv ~= n then
                    world.set(res, k, cv)
                end
            end
        end
        -- (the table is saved without its zeros, and not at all when empty [V: the game's save after
        -- clear_resources: `standard_economy_module = { }`])
        for i = #res, 1, -1 do
            local x = res[i]
            if x.op and x.value and x.value.text and tonumber(x.value.text) == 0 then
                world.remove_entry(res, x)
            end
        end
        if #res == 0 then
            local e = world.entry(module, "resources")
            if e then
                world.remove_entry(module, e)
            end
        end
    end
    return true
end

-- CCountry::AddResources (option 0): each resource of the table added to the stockpile, kept
-- within [0, its max] [I: the converter's payment path (bottomless resources paid with another)
-- not modelled; the clamp as SetResource's]
function market.add_stockpile(country, tbl)
    if not world.object("country", country) then
        return false
    end
    local _, by = market.resources()
    local changed = false
    for _, r in ipairs((market.resources())) do
        local v = tbl[r.key]
        if v and v ~= 0 then
            market.set_stockpile(country, r.key, market.stockpile(country, r.key) + v)
            changed = true
        end
    end
    for k, v in pairs(tbl) do
        if not by[k] and v ~= 0 then
            changed = true
        end
    end
    return changed
end

-- ---------------------------------------------------------------------------------------------
-- prices

-- the fluctuation of a resource for a country (CMarket::GetFluctuation): the galactic market's
-- with access, else the country's internal_market_fluctuations (missing: 0)
function market.fluctuation(country, key)
    local r = market.resource(key)
    if not r then
        return 0
    end
    local m = market.block()
    if country and market.has_access(country) then
        return numbers(world.field(m, "fluctuations"))[r.index + 1] or 0
    end
    local current
    for k, v in world.statements(world.field(m, "internal_market_fluctuations") or {}) do
        if k == "country" then
            current = tonumber(v)
        elseif k == "resources" and current == country then
            return tonumber(world.field(v, r.key)) or 0
        end
    end
    return 0
end

-- NMarketUtil::CalcFluctuation (0x1d52b30): after n base amounts (fixed point); a trade type other
-- than buy or sell: 0 [V]
local function next_fluctuation(ttype, f, n, internal)
    if ttype ~= "market_buy" and ttype ~= "market_sell" then
        return 0
    end
    local D = market.defines()
    local m = internal and fx(D.INTERNAL_MARKET_FLUCTUATION_MULT) or ONE
    local A = mul(fx(D.MARKET_FLUCTUATION_ABOVE_BASE_PRICE), m)
    local B = mul(fx(D.MARKET_FLUCTUATION_BELOW_BASE_PRICE), m)
    if A == 0 or B == 0 then
        return 0
    end
    if ttype == "market_buy" then
        if f >= 0 then
            f = f + mul(n, A)
        else
            local g = f + mul(n, B)
            f = g <= 0 and g or mul(n - div(-f, B), A)
        end
        return math.min(f, fx(D.MARKET_MAX_FLUCTUATION_FROM_BASE_PRICE))
    end
    if f <= 0 then
        f = f - mul(n, B)
    else
        local g = f - mul(n, A)
        f = g >= 0 and g or -mul(n - div(f, A), B)
    end
    return math.max(f, fx(D.MARKET_MIN_FLUCTUATION_FROM_BASE_PRICE))
end
market.next_fluctuation = next_fluctuation

-- the trade fee: MARKET_TRADE_FEE_BASE + country_trade_fee, at least MARKET_TRADE_FEE_MIN
function market.fee(country)
    local D = market.defines()
    local m = 0
    local economy = package.loaded["engine.economy"] or require("engine.economy")
    if country and economy.modifiers then
        local mods = economy.modifiers("country", country) or {}
        m = mods.country_trade_fee or 0
    end
    return math.max(D.MARKET_TRADE_FEE_MIN, D.MARKET_TRADE_FEE_BASE + m)
end

-- CMarket::CalcResourcePriceForAmount (amount in resource units, the value in the market's
-- currency): k = amount / market_amount base amounts; the first at market_price + the current
-- fluctuation, the next ones each a step further (at most MARKET_MAX_BASE_AMOUNTS); "market_buy"
-- adds the fee, "market_sell" takes it off, "not_set" neither and its steps at the plain price [V]
function market.price(country, key, amount, ttype)
    local r = market.resource(key)
    if not r then
        return 0
    end
    local D = market.defines()
    local internal = not (country and market.has_access(country))
    local ma, mp = fx(r.market_amount), fx(r.market_price)
    local k = div(fx(amount), ma)
    local f0 = fx(market.fluctuation(country, key))
    local cur = mp + f0
    local price
    if k < ONE then
        price = mul(k, cur)
    elseif k == ONE then
        price = cur
    else
        local f = next_fluctuation(ttype, f0, ONE, internal)
        local n = math.min(k - ONE, fx(D.MARKET_MAX_BASE_AMOUNTS))
        local sum = 0
        while n >= ONE do
            sum = sum + mp + f
            f = next_fluctuation(ttype, f, ONE, internal)
            n = n - ONE
        end
        if n > 0 then
            sum = sum + mul(mp + f, n)
        end
        price = cur + sum
    end
    if ttype == "market_buy" or ttype == "market_sell" then
        local fee = fx(market.fee(country))
        price = mul(price, ttype == "market_buy" and (ONE + fee) or (ONE - fee))
    end
    return price / ONE
end

-- ---------------------------------------------------------------------------------------------
-- CMarket::IsValidResource (0x1d4b880) [V]: tradable (tradable, a market amount and price, its
-- tradable_in_market trigger); no country: on the galactic market; the converter (ttype 0 buy:
-- it can buy, 1 sell: it can sell, 2: either; its override_trade_restriction: valid); with access:
-- on the galactic market; else (the internal market) the country's current-month income of it
-- above 0, or for a resource of the two flagged kinds its expenses [I: the flag not read: expenses
-- checked for all]
function market.valid_resource(country, key, trigger_ok, ttype)
    local r = market.resource(key)
    if not r or not (r.tradable and r.market_amount > 0 and r.market_price > 0) then
        return false
    end
    if trigger_ok and not trigger_ok(r) then
        return false
    end
    if not country or not world.object("country", country) then
        return market.resource_enabled(key)
    end
    ttype = ttype or 0
    local b, s = market.can_buy(country, r.key), market.can_sell(country, r.key)
    if (ttype == 0 and not b) or (ttype == 1 and not s) or (ttype == 2 and not (b or s)) then
        return false
    end
    if market.overrides_restriction(country, r.key) then
        return true
    end
    if market.has_access(country) then
        return market.resource_enabled(key)
    end
    if market.budget(country, "current_month", "income", nil, r.key) > 0 then
        return true
    end
    return market.budget(country, "current_month", "expenses", nil, r.key) > 0
end

-- slave_market_manager.slaves_on_market: { key = pop group value = amount }
function market.slaves_on_market()
    local out = {}
    local smm = world.meta.slave_market_manager
    for _, e in ipairs(type(smm) == "table" and world.blocks(world.field(smm, "slaves_on_market")) or {}) do
        local g = tonumber(world.field(e, "key"))
        if g then
            out[#out + 1] = { pop_group = g, amount = tonumber(world.field(e, "value")) or 0 }
        end
    end
    return out
end

return market
