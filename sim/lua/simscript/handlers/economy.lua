-- simscript/handlers/economy.lua : the economy package of the script coverage
-- (docs/script_economy.md): the stockpiles and budgets, the galactic and internal markets, the
-- slave market and slavery, trade deals and the enclaves' special trades, resource converters
-- and trade conversions, the cosmic storms' influence fields.
--
-- Each keyword names its class in the Linux 4.5.2 build with [V] (read in the binary:
-- /opt/stellaris-headless/re on 10.5.0.24) or [I] (inferred from the game's script documentation and
-- the save's fields). The world is the save (engine.world): a handler writes the fields the game
-- writes (the classes' WriteMembers names), so a save written after it has the change. The market
-- and the budgets are engine.market's.

return function(eval)
    local I = eval._internal
    local S, NONE, compare, sync = I.S, I.NONE, I.compare, I.sync
    local stats = I.stats
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local world = require("engine.world")
    local floor = math.floor
    local NO_ID = 4294967295

    -- ------------------------------------------------------------------------------------------
    -- helpers

    local function written() stats.script = stats.script + 1 end
    local function market() return require("engine.market") end
    local function rt() return require("engine.script.runtime") end
    local function unq(v)
        if type(v) ~= "string" then return v end
        return (v:gsub('^"(.*)"$', "%1"))
    end
    local function ref(v)
        local n = tonumber(unq(v))
        if not n or n == NO_ID then return nil end
        return n
    end
    local function this_country(ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "country" then return nil end
        local c = world.object("country", sc.id)
        if not c then return nil end
        return sc.id, c
    end
    local function param(block, key)
        if type(block) ~= "table" or block.text then return nil end
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key then return x end
        end
        return nil
    end
    local function param_text(block, key)
        local x = param(block, key)
        return x and x.value.text and unq(x.value.text) or nil
    end
    local function param_num(block, key, ctx)
        local x = param(block, key)
        if not x then return nil end
        return eval.value(x.value, ctx, x)
    end
    local function param_list(block, key)
        local x = param(block, key)
        local out = {}
        if x and type(x.value) == "table" and x.value.text == nil then
            for _, v in ipairs(x.value) do
                if v.text then out[#out + 1] = unq(v.text) end
            end
        elseif x and x.value.text then
            out[1] = unq(x.value.text)
        end
        return out
    end
    local function yes_no(e) return e.value.text ~= "no" end
    -- the scope a parameter names (`target = from`)
    local function param_scope(block, key, ctx, e)
        local t = param_text(block, key)
        if not t then return nil end
        local found, sc = eval.resolve(t, ctx, e)
        if not found or not sc or sc == NONE then return nil end
        return sc
    end
    local function scope_country(sc)
        if sc and sc.kind == "country" and world.object("country", sc.id) then return sc.id end
        return nil
    end
    -- `<trigger> <op> <value>`, or `<trigger> = { value <op> n }`
    local function compare_value(v, e, ctx)
        if v == nil then return false end
        if e.value.text then return compare(v, e.op, eval.value(e.value, ctx, e)) end
        local x = param(e.value, "value")
        if not x then return false end
        return compare(v, x.op, eval.value(x.value, ctx, x))
    end
    -- the game's fixed point (CFixedPoint: 1/100000, truncated toward zero)
    local function fixed(v)
        local n = tonumber(v) or 0
        if n >= 0 then return floor(n * 100000 + 1e-6) / 100000 end
        return -floor(-n * 100000 + 1e-6) / 100000
    end
    -- a value trigger: also a trigger value (`value = trigger:<k>`); value(ctx, e) nil = no value
    local function value_trigger(k, value)
        TRIG[k] = function(e, ctx)
            sync()
            return compare_value(value(ctx, e), e, ctx)
        end
        if eval.TVAL then
            eval.TVAL[k] = function(ctx, e)
                sync()
                return value(ctx, e) or 0
            end
        end
    end
    -- export_*_to_variable's variable (ReadTokenAsVariable; AccessVariablePointer, SetVariable)
    local function export(ctx, var, v)
        if not var or v == nil then return end
        written()
        eval.store.setvar(ctx.this, var, fixed(v))
    end

    -- ------------------------------------------------------------------------------------------
    -- the galactic market

    -- is_on_market = <resource> (CIsOnMarketTrigger 0x3bfd530) [V]: any scope; the resource enabled
    -- on the galactic market (galactic_market_resources[index] == 1), the market's `enabled` and the
    -- scope's access not read
    TRIG["is_on_market"] = function(e, ctx)
        if not e.value.text then return false end
        sync()
        return market().resource_enabled(unq(e.value.text))
    end

    -- can_buy_on_market = <resource> (CCanBuyOnMarketTrigger 0x3bfd6e0) [V]: CMarket::IsValidResource
    -- for buying (engine.market.valid_resource: tradable and its tradable_in_market trigger; on the
    -- galactic market with access, else its current-month income or expenses); no price check
    TRIG["can_buy_on_market"] = function(e, ctx)
        if not e.value.text then return false end
        sync()
        local key = unq(e.value.text)
        local sc = ctx.this
        local country = sc and sc ~= NONE and sc.kind == "country" and sc.id or nil
        return market().valid_resource(country, key, function(r)
            local t = require("engine.defs").field(r.block, "tradable_in_market")
            if type(t) ~= "table" or not country then return true end
            local ok, holds = pcall(eval.trigger, t, eval.new_ctx(S("country", country), nil, nil, ctx.file))
            return not ok or holds
        end)
    end

    -- is_market_leader = yes/no (CIsMarketLeader 0x3bfef00) [V]: market.country is the scope; a scope
    -- that is not a country: false for yes and no
    TRIG["is_market_leader"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return false end
        sync()
        return (market().leader() == id) == yes_no(e)
    end

    -- market_resource_price = { resource amount trade_type value } (CMarketResourcePriceTrigger
    -- 0x3bfe150) [V]: CMarket::CalcResourcePriceForAmount with the fee; amount 1 and trade_type
    -- not_set (no fee) by default; neither the resource nor the access checked
    value_trigger("market_resource_price", function(ctx, e)
        if not e or e.value.text then return nil end
        local key = param_text(e.value, "resource")
        if not key then return nil end
        local amount = param_num(e.value, "amount", ctx) or 1
        local ttype = param_text(e.value, "trade_type") or "not_set"
        local sc = ctx.this
        local country = sc and sc ~= NONE and sc.kind == "country" and sc.id or nil
        return market().price(country, key, amount, ttype)
    end)

    -- enable_on_market = <resource> (CEnableOnMarketEffect 0x37b6210) [V]: any scope; the galactic
    -- market not founded (no `enabled`): nothing (the game logs it); else the resource enabled there
    EFF["enable_on_market"] = function(e, ctx)
        if not e.value.text then return end
        sync()
        local m = market()
        if not m.enabled() then return end
        if m.enable_resource(unq(e.value.text)) then written() end
    end

    -- set_market_leader = yes/no (CSetMarketLeaderEffect 0x37b6690) [V]: yes: market.country = the
    -- scope; no: no leader (4294967295), whoever led; nothing else (no flag, no access)
    EFF["set_market_leader"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return end
        sync()
        market().set_leader(yes_no(e) and id or nil)
        written()
    end

    -- enable_galactic_market = yes/no (CEnableGalacticMarketEffect 0x379dac0) [V]: the scope's access
    -- (CMarket::SetGalacticMarketAccess: galactic_market_access and id grown to its index, id[ci] =
    -- the country, access[ci] = 1 or 0); the market's own `enabled` is not touched (set by the
    -- daily update once the global flag galactic_market_founded exists)
    EFF["enable_galactic_market"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return end
        sync()
        market().set_access(id, yes_no(e))
        written()
    end

    -- ------------------------------------------------------------------------------------------
    -- the slave market

    -- is_on_slave_market = yes/no (CIsOnSlaveMarket 0x3bfebe0) [V]: the pop group's id among
    -- slave_market_manager.slaves_on_market (the amount not read); another scope: id 4294967295
    TRIG["is_on_slave_market"] = function(e, ctx)
        local sc = ctx.this
        local id = sc and sc ~= NONE and sc.kind == "pop_group" and sc.id or NO_ID
        sync()
        local found = false
        for _, s in ipairs(market().slaves_on_market()) do
            if s.pop_group == id then found = true break end
        end
        return found == yes_no(e)
    end

    -- ------------------------------------------------------------------------------------------
    -- the budgets

    -- income <op> x (CIncomeTrigger 0x3b7d310) [V]: last month's gross income of energy
    -- (CCountryBudget::CalcLastMonthsIncome: last_month.income and trade_income summed)
    value_trigger("income", function(ctx)
        local id = this_country(ctx)
        if not id then return 0 end
        return market().budget(id, "last_month", "income", nil, "energy")
    end)

    -- the budget's current month of a resource (one economic category, or all), for the
    -- CResourceCompareTrigger family; no value without a resource or a country
    local function month_sum(ctx, e, side)
        local id = this_country(ctx)
        if not id or not e or e.value.text then return nil end
        local key = param_text(e.value, "resource")
        local m = market()
        if not key or not m.resource(key) then return nil end
        local cat = param_text(e.value, "category")
        if cat and not m.category(cat) then cat = nil end
        return m.budget(id, "current_month", side, cat, key)
    end

    -- resource_revenue_compare = { resource category value } (CResourceCompareTrigger
    -- <SResourceRevenueCompare> 0x3bdb1c0) [V]: the current month's gross income
    value_trigger("resource_revenue_compare", function(ctx, e) return month_sum(ctx, e, "income") end)

    -- resource_income_to_expenditure_balance_ratio = { resource category value }
    -- (SResourceIncomeToExpenditureRatio 0x3bdbac0) [V]: the current month's balance (net, not the
    -- gross income the docs say) over its expenses, truncated; no expenses: 2814749767.10655
    value_trigger("resource_income_to_expenditure_balance_ratio", function(ctx, e)
        local n = month_sum(ctx, e, "balance")
        if n == nil then return nil end
        local d = month_sum(ctx, e, "expenses")
        local m = market()
        if m.fx(d) == 0 then return 2814749767.10655 end
        return m.div(m.fx(n), m.fx(d)) / m.ONE
    end)

    -- export_resource_income_to_variable = { resource variable } (0x37ce700) [V]: the current
    -- month's balance (net) of the resource
    EFF["export_resource_income_to_variable"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local sc = ctx.this
        local id = sc and sc ~= NONE and sc.kind == "country" and sc.id or nil
        local key = param_text(e.value, "resource")
        local v = (id and key) and market().budget(id, "current_month", "balance", nil, key) or 0
        export(ctx, param_text(e.value, "variable"), v)
    end

    -- export_resource_maximum_to_variable = { resource variable } (0x37cf2c0) [V]:
    -- CStrategicResource::GetMaximumForCountry (no country: 0; a resource without a max: its max)
    EFF["export_resource_maximum_to_variable"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local key = param_text(e.value, "resource")
        local id = this_country(ctx)
        local v = 0
        if id and key then
            local m = market()
            v = m.capacity(id, key)
            if v == nil then
                local r = m.resource(key)
                v = r and tonumber(require("engine.defs").field(r.block, "max")) or 0
            end
        end
        export(ctx, param_text(e.value, "variable"), v)
    end

    -- export_resource_stockpile_to_variable = { resource variable } (0x37cecf0) [V]: the stockpile
    EFF["export_resource_stockpile_to_variable"] = function(e, ctx)
        if e.value.text then return end
        sync()
        local key = param_text(e.value, "resource")
        local id = this_country(ctx)
        export(ctx, param_text(e.value, "variable"), (id and key) and rt().stockpile(id, key) or 0)
    end

    -- ------------------------------------------------------------------------------------------
    -- the stockpile

    -- set_resource = { resource value } (CSetResourceEffect 0x3792070 ->
    -- CEconomyCountryModule::SetResource 0x24ef350) [V]: the value exactly, then every resource
    -- within [0, its max]
    EFF["set_resource"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        local key = param_text(e.value, "resource")
        local v = param_num(e.value, "value", ctx)
        local m = market()
        if not key or not v or not m.resource(key) then return end
        sync()
        if m.set_stockpile(id, key, fixed(v)) then written() end
    end

    -- clear_resources = yes (CClearResourceEffect 0x3771030 -> CCountry::ClearAccumulatedResources
    -- 0x23a8030) [V]: every resource's stockpile 0, also with `= no`
    EFF["clear_resources"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return end
        sync()
        local m = market()
        for _, r in ipairs((m.resources())) do
            if rt().stockpile(id, r.key) ~= 0 then m.set_stockpile(id, r.key, 0) end
        end
        written()
    end

    -- ------------------------------------------------------------------------------------------
    -- trade deals

    -- the trade deals (top-level trade_deal = { <id> = { first = { country actions action_value }
    -- second = { ... } } }) of a country, by id [I: the country's own list is the deals it is a
    -- side of]
    local function deals_of(country)
        local out = {}
        local store = world.meta.trade_deal
        local ok, ids = pcall(world.all, "trade_deal")
        if ok and type(ids) == "table" and #ids > 0 then
            for _, d in ipairs(ids) do out[#out + 1] = { id = d, block = world.object("trade_deal", d) } end
        elseif type(store) == "table" then
            for k, v in world.statements(store) do
                if type(v) == "table" and tonumber(k) then out[#out + 1] = { id = tonumber(k), block = v } end
            end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        local mine = {}
        for _, d in ipairs(out) do
            local f, s = world.field(d.block, "first"), world.field(d.block, "second")
            local fc = type(f) == "table" and ref(world.field(f, "country"))
            local scn = type(s) == "table" and ref(world.field(s, "country"))
            if fc == country or scn == country then mine[#mine + 1] = { first = f, second = s, fc = fc, sc = scn } end
        end
        return mine
    end
    local function side_has(side, action)
        if type(side) ~= "table" then return false end
        for _, v in ipairs(world.list(world.field(side, "actions"))) do
            if unq(v) == action then return true end
        end
        return false
    end

    -- trade_action_value = { action with_country value } (CTradeActionValueTrigger 0x3c0f810) [V]:
    -- the scope's first deal with with_country on either side whose side has the action: that
    -- side's action_value (0 when not written); none: no value
    value_trigger("trade_action_value", function(ctx, e)
        local id = this_country(ctx)
        if not id or not e or e.value.text then return nil end
        local action = param_text(e.value, "action")
        local other = scope_country(param_scope(e.value, "with_country", ctx, e))
        if not action or not other then return nil end
        for _, d in ipairs(deals_of(id)) do
            if d.fc == other or d.sc == other then
                if side_has(d.first, action) then return tonumber(world.field(d.first, "action_value")) or 0 end
                if side_has(d.second, action) then return tonumber(world.field(d.second, "action_value")) or 0 end
            end
        end
        return nil
    end)
end
