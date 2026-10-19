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

    -- the values of the budget and stockpile triggers eval.lua implements (complex_trigger_modifier's
    -- `trigger:` values): the number each trigger compares, from the same readers (E.budget_sum,
    -- E.resource), the parameters block as e.value
    local function Eng() return eval._internal.E or {} end
    local function owner_country(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "country" then return sc.id end
        local o = world.object(sc.kind, sc.id)
        return o and ref(world.field(o, "owner"))
    end
    local function budget_value(month, side, with_category)
        return function(ctx, e)
            local id = this_country(ctx)
            if not id or not e or e.value.text or not Eng().budget_sum then return nil end
            local key = param_text(e.value, "resource")
            if not key then return nil end
            sync()
            return Eng().budget_sum(id, month, side, key, with_category and param_text(e.value, "category") or nil)
        end
    end
    if eval.TVAL then
        -- has_monthly_income = { resource value }: last month's balance
        eval.TVAL["has_monthly_income"] = budget_value("last_month", "balance", false)
        -- resource_income_compare: this month's balance; resource_expenses_compare: its expenses
        eval.TVAL["resource_income_compare"] = budget_value("current_month", "balance", true)
        eval.TVAL["resource_expenses_compare"] = budget_value("current_month", "expenses", true)
        -- has_resource = { type amount } / resource_stockpile_compare = { resource value }: the
        -- stockpile of the scope's country (a planet's, a ship's owner)
        local function stock_value(key_param)
            return function(ctx, e)
                local id = owner_country(ctx.this)
                if not id or not e or e.value.text or not Eng().resource then return nil end
                local key = param_text(e.value, key_param)
                    or (key_param == "type" and param_text(e.value, "resource")) or nil
                if not key then return nil end
                sync()
                return Eng().resource(id, key)
            end
        end
        -- has_resource takes its resource as `type` or `resource` (CHasResourceTrigger::ReadMember
        -- 0x3b86310 reads both) [V]
        eval.TVAL["has_resource"] = stock_value("type")
        eval.TVAL["resource_stockpile_compare"] = stock_value("resource")
    end

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

    -- the trade deals of a country: its `trade_deals = { { trade_deal = <id> } ... }` in order
    -- (CCountry +0x2708), each the top-level trade_deal = { <id> = { first = { country actions
    -- action_value } second = { ... } } }; without that list, the deals it is a side of by id [I]
    local function deal_block(id)
        local ok, d = pcall(world.object, "trade_deal", id)
        if ok and type(d) == "table" then return d end
        local store = world.meta.trade_deal
        local v = type(store) == "table" and world.field(store, tostring(id))
        return type(v) == "table" and v or nil
    end
    local function deals_of(country)
        local out = {}
        local c = world.object("country", country)
        local list = c and world.field(c, "trade_deals")
        if type(list) == "table" then
            for _, b in ipairs(world.blocks(list)) do
                local id = ref(world.field(b, "trade_deal"))
                local d = id and deal_block(id)
                if d then out[#out + 1] = { id = id, block = d } end
            end
        else
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
        end
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

    -- get_trade_data / make_special_trade = { target } (CGetTradeDataEffect 0x37e9630,
    -- CMakeSpecialTrade 0x37ea210) [V]: only while the AI weighs an `ai_trade_facility` option (the
    -- buyer's offer receiver and the enclave's offer seller set); anywhere else the game logs
    -- "wrong scoped or target country" and does nothing. That AI evaluation is not modelled, so the
    -- effects do what the game does outside it: nothing (no world change). Inside it, get_trade_data
    -- only fills the AI's offer list (no save change) and make_special_trade hires the enclave's
    -- service and moves its cost from the buyer to the enclave
    local function trade_facility(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        -- (the target's check passes or not: outside the AI's evaluation the effect stops at the
        -- offer receiver's, which no country has here)
        local _ = scope_country(param_scope(e.value, "target", ctx, e))
    end
    EFF["get_trade_data"] = trade_facility
    EFF["make_special_trade"] = trade_facility

    -- ------------------------------------------------------------------------------------------
    -- converters and trade conversions

    -- set_resource_converter = <key> / none (CSetResourceConverter 0x37ee0b0) [V]: the economy
    -- module's resource_conversions = "<key>" (none: taken out); the country's monthly trades the
    -- new converter cannot make removed
    EFF["set_resource_converter"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not e.value.text then return end
        sync()
        local key = unq(e.value.text)
        if key == "none" then key = nil
        elseif not require("engine.defs").get("common/resource_converters", key) then return end
        if market().set_converter(id, key) then written() end
    end

    -- set_trade_conversions = { <resource> = <fraction> ... } (CSetTradeConversions 0x37ed7a0) [V]:
    -- the country's trade_conversions replaced by the table (its non-zero entries); an empty table
    -- changes nothing [V: the game's save after `set_trade_conversions = { }`]. The budget books the
    -- net trade income out and each listed resource in at trade x its fraction (a `trade` entry
    -- keeps that share as trade)
    EFF["set_trade_conversions"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local m = market()
        local entries, listed = {}, false
        for _, x in ipairs(e.value) do
            if x.op and x.key and m.resource(x.key.text) then
                listed = true
                local v = fixed(eval.value(x.value, ctx, x))
                if v ~= 0 then
                    entries[#entries + 1] = { key = { text = x.key.text }, op = "=", value = { text = world.number_text(v) } }
                end
            end
        end
        if not listed then return end
        sync()
        world.replace(world.child(c, "trade_conversions"), entries)
        written()
    end

    -- ------------------------------------------------------------------------------------------
    -- stockpiles: the country's

    -- a `<resource> = <value> ... mult = x` table (CFixedResourceTable, `mult` / `multiplier`)
    local function resource_table(block, ctx, skip)
        local m = market()
        local t, mult = {}, nil
        for _, x in ipairs(type(block) == "table" and block or {}) do
            if x.op and x.key then
                local k = x.key.text:lower()
                if k == "mult" or k == "multiplier" then
                    mult = eval.value(x.value, ctx, x)
                elseif not (skip and skip[k]) and m.resource(x.key.text) then
                    t[x.key.text] = (t[x.key.text] or 0) + fixed(eval.value(x.value, ctx, x))
                end
            end
        end
        if mult then
            for k, v in pairs(t) do t[k] = fixed(v * mult) end
        end
        return t
    end

    -- add_resource_from_debris = { <resource> = x ... system mult } (CAddResourceFromDebrisEffect
    -- 0x37a4200) [V]: the resources (x mult) added to the country's stockpile as add_resource
    -- (within its max); the notification DEBRIS_SCAVENGED_FINISH (the unmultiplied amounts, the
    -- system's name; human countries only) is the interface's, no save change
    EFF["add_resource_from_debris"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        local t = resource_table(e.value, ctx, { system = true })
        sync()
        if market().add_stockpile(id, t) then written() end
    end

    -- transfer_resources_to_empire = { target resources = { ... } percentage }
    -- (CTransferResourcesToEmpireEffect 0x379a1b0) [V]: the percentage clamped to [0, 1] (1 when not
    -- given); each listed resource's stockpile x it (truncated) above 0 into a table; the target
    -- gets the table (CCountry::AddResources: within its max, the rest lost), the scope loses it all
    EFF["transfer_resources_to_empire"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        local target = scope_country(param_scope(e.value, "target", ctx, e))
        if not target then return end
        local p = param_num(e.value, "percentage", ctx) or 1
        p = math.max(0, math.min(1, fixed(p)))
        sync()
        local m = market()
        local t, lose, any = {}, {}, false
        for _, key in ipairs(param_list(e.value, "resources")) do
            if m.resource(key) then
                local v = m.mul(m.fx(rt().stockpile(id, key)), m.fx(p)) / m.ONE
                if v > 0 then
                    t[key] = (t[key] or 0) + v
                    lose[key] = -t[key]
                    any = true
                end
            end
        end
        if not any then return end
        m.add_stockpile(target, t)
        m.add_stockpile(id, lose)
        written()
    end

    -- ------------------------------------------------------------------------------------------
    -- stockpiles: ships and waystations (`ships.<id>.resources = { ... }`, a waystation's on its
    -- station ship)

    local function defs() return require("engine.defs") end
    -- a ship's size (its design's current growth stage's ship_size) and its definition
    local function ship_size_key(sid)
        local s = world.object("ship", sid)
        local impl = s and world.field(s, "ship_design_implementation")
        local design = type(impl) == "table" and world.object("ship_design", tonumber(world.field(impl, "design")))
        if not design then return nil end
        local stage = tonumber(world.field(impl, "growth_stage")) or 0
        local g = world.blocks(world.field(design, "growth_stages"))[stage + 1]
        return g and unq(world.field(g, "ship_size")) or nil
    end
    local function ship_size_def(sid)
        local k = ship_size_key(sid)
        return k and defs().get("common/ship_sizes", k) or nil
    end
    local function ship_starbase(sid)
        local s = world.object("ship", sid)
        local sb = s and ref(world.field(s, "starbase"))
        if sb and world.object("starbase", sb) then return sb end
        for _, b in ipairs(world.all("starbase")) do
            local o = world.object("starbase", b)
            if o and ref(world.field(o, "station")) == sid then return b end
        end
        return nil
    end
    -- CStarbase::IsWaystation [I: the station's ship size is one of 00_waystations.txt's,
    -- starbase_waystation_*]
    local function is_waystation(sb)
        local o = sb and world.object("starbase", sb)
        local st = o and ref(world.field(o, "station"))
        local k = st and ship_size_key(st)
        return (k ~= nil and k:find("waystation", 1, true) ~= nil)
            or (o ~= nil and tostring(unq(world.field(o, "level")) or ""):find("waystation", 1, true) ~= nil)
    end
    local function mods(kind, id)
        local economy = package.loaded["engine.economy"] or require("engine.economy")
        local ok, m = pcall(economy.modifiers, kind, id)
        return ok and m or {}
    end
    -- the ship size's own `modifier` value of a key (the station's modifier node when the engine
    -- has no modifier source)
    local function size_modifier(d, key)
        local m = d and defs().field(d.block, "modifier")
        return type(m) == "table" and tonumber(defs().field(m, key)) or 0
    end
    -- CShip::CanStoreResources (0x2aa4d20) [V]: its size collects_stockpile_from someone and not to
    -- the country, or its starbase is a waystation
    local function can_store(sid)
        local d = ship_size_def(sid)
        if d then
            local from = defs().field(d.block, "collects_stockpile_from")
            local n = 0
            for _, v in ipairs(type(from) == "table" and from or {}) do if v.text then n = n + 1 end end
            if n > 0 and defs().field(d.block, "collects_stockpile_to_country") ~= "yes" then return true end
        end
        return is_waystation(ship_starbase(sid))
    end
    -- CShip::CalcStockpileCapacity (0x2aa4a50) [V]: (size ship_stockpile_capacity +
    -- ship_stockpile_capacity_add) x (1 + ship_stockpile_capacity_mult), at least 0 [I: the size's
    -- own modifier type's adds not read]
    local function ship_capacity(sid)
        local d = ship_size_def(sid)
        local base = d and tonumber(defs().field(d.block, "ship_stockpile_capacity")) or 0
        local m = mods("ship", sid)
        return math.max(0, (base + (m.ship_stockpile_capacity_add or 0)) * (1 + (m.ship_stockpile_capacity_mult or 0)))
    end
    -- CStarbase::CalcResourceCollectorMaxValues (0x202eb70) [V]: per resource,
    -- starbase_stockpile_capacity_add + starbase_stockpile_<r>_capacity_add, above 0 times
    -- (1 + starbase_stockpile_capacity_mult + starbase_stockpile_<r>_capacity_mult)
    local function waystation_max(sb)
        local o = world.object("starbase", sb)
        local d = o and ship_size_def(ref(world.field(o, "station")))
        local m = mods("starbase", sb)
        local function get(k) return m[k] or (next(m) == nil and size_modifier(d, k)) or 0 end
        local out = {}
        for _, r in ipairs((market().resources())) do
            local v = get("starbase_stockpile_capacity_add") + get("starbase_stockpile_" .. r.key .. "_capacity_add")
            if v > 0 then
                v = v * (1 + get("starbase_stockpile_capacity_mult") + get("starbase_stockpile_" .. r.key .. "_capacity_mult"))
            end
            out[r.key] = v
        end
        return out
    end
    local function stock_of(sid)
        local s = world.object("ship", sid)
        local t = {}
        local res = s and world.field(s, "resources")
        for k, v in world.statements(type(res) == "table" and res or {}) do
            local n = tonumber(v)
            if n then t[k] = n end
        end
        return t
    end
    local function write_stock(sid, t)
        local s = world.object("ship", sid)
        if not s then return end
        local entries = {}
        for _, r in ipairs((market().resources())) do
            local v = t[r.key]
            if v and v ~= 0 then
                entries[#entries + 1] = { key = { text = r.key }, op = "=", value = { text = world.number_text(fixed(v)) } }
            end
        end
        local e = world.entry(s, "resources")
        if #entries == 0 then
            if e and type(e.value) == "table" and e.value.text == nil then world.remove_entry(s, e) end
            return
        end
        world.replace(world.child(s, "resources"), entries)
    end
    -- the used share of a ship's stockpile (CShip::UpdateShipStockpileUsed 0x2aa5830, a waystation's
    -- UpdateWaystationStockpileUsed 0x2aa5ac0) [V]: a ship's total over its capacity in [0, 1] (no
    -- capacity: 1); a waystation's largest share of a resource's max (a resource with no max, or
    -- over it: 1)
    local function used_share(sid)
        local t = stock_of(sid)
        local sb = ship_starbase(sid)
        if sb and is_waystation(sb) then
            local max = waystation_max(sb)
            local best = 0
            for _, r in ipairs((market().resources())) do
                local s, mx = t[r.key] or 0, max[r.key] or 0
                if mx <= 0 or s > mx then return 1 end
                if s > 0 then best = math.max(best, s / mx) end
            end
            return best
        end
        local cap = ship_capacity(sid)
        if cap <= 0 then return 1 end
        local total = 0
        for _, v in pairs(t) do total = total + v end
        return math.max(0, math.min(1, total / cap))
    end
    -- CShip::AddStoredResources (0x2ab52d0) [V]: a waystation: each resource added and kept within
    -- its max; another ship: CResourceTable::AddTableWithTotalLimit (in resource order, up to the
    -- capacity's total, the walk stopped at the first that does not fit whole)
    local function add_stored(sid, add)
        local t = stock_of(sid)
        local sb = ship_starbase(sid)
        if sb and is_waystation(sb) then
            local max = waystation_max(sb)
            for _, r in ipairs((market().resources())) do
                if add[r.key] then
                    t[r.key] = math.min((t[r.key] or 0) + add[r.key], max[r.key] or 0)
                end
            end
        else
            local cap = ship_capacity(sid)
            local total = 0
            for _, v in pairs(t) do total = total + v end
            if total < cap then
                for _, r in ipairs((market().resources())) do
                    local a = add[r.key]
                    if a then
                        if total + a < cap then
                            t[r.key] = (t[r.key] or 0) + a
                            total = total + a
                        else
                            t[r.key] = (t[r.key] or 0) + (cap - total)
                            break
                        end
                    end
                end
            end
        end
        write_stock(sid, t)
    end

    -- add_resource_to_local_stockpile = { <resource> = x ... mult } (CAddResourceToLocalStockpileEffect
    -- 0x36cebd0) [V]: a ship that can store resources (a fleet scope: the game logs an error and does
    -- nothing, though the docs list it) gets the table (x mult) within its capacity
    EFF["add_resource_to_local_stockpile"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "ship" or e.value.text then return end
        sync()
        if not world.object("ship", sc.id) or not can_store(sc.id) then return end
        add_stored(sc.id, resource_table(e.value, ctx))
        written()
    end

    -- transfer_resource_stockpile = { target mult } (CTransferResourceStockpileEffect 0x3799010) [V]:
    -- the scope ship's stockpile (x mult, 1 when not given) to a country (add_resource, within its
    -- max) or to a ship that can store (AddStoredResources, the excess lost); then the ship's
    -- stockpile cleared. A target that is neither: nothing [I: the error path before the clear]
    EFF["transfer_resource_stockpile"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "ship" or e.value.text then return end
        sync()
        if not world.object("ship", sc.id) or not can_store(sc.id) then return end
        local mult = param_num(e.value, "mult", ctx) or param_num(e.value, "multiplier", ctx) or 1
        local t = {}
        for k, v in pairs(stock_of(sc.id)) do t[k] = fixed(v * mult) end
        local target = param_scope(e.value, "target", ctx, e)
        local country = scope_country(target)
        if country then
            market().add_stockpile(country, t)
        elseif target and target.kind == "ship" and world.object("ship", target.id) and can_store(target.id) then
            add_stored(target.id, t)
        else
            return
        end
        write_stock(sc.id, {})
        written()
    end

    -- used_stockpile_capacity_percentage <op> x (ship, starbase; CUsedStockpileCapacityPercentageTrigger
    -- 0x3bd9840) [V]: the ship's (a starbase's station ship's) used share
    value_trigger("used_stockpile_capacity_percentage", function(ctx)
        local sc = ctx.this
        if not sc or sc == NONE then return nil end
        local sid
        if sc.kind == "ship" then sid = sc.id
        elseif sc.kind == "starbase" then
            local o = world.object("starbase", sc.id)
            sid = o and ref(world.field(o, "station"))
        end
        if not sid or not world.object("ship", sid) then return nil end
        return used_share(sid)
    end)

    -- waystation_network_stockpile_used <op> x (a starbase; CWaystationNetworkStockpileUsedTrigger
    -- 0x3c4f340) [V]: the largest used share of its network's waystations' station ships
    -- (NWaystationUtil::GetWaylineStockpileUsed); not in a network: 0
    value_trigger("waystation_network_stockpile_used", function(ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "starbase" or not world.object("starbase", sc.id) then return nil end
        local net
        for _, nid in ipairs(world.all("waystation_networks") or {}) do
            local n = world.object("waystation_networks", nid)
            for _, v in ipairs(world.list(n and world.field(n, "waystations"))) do
                if ref(v) == sc.id then net = n end
            end
            if net then break end
        end
        if not net then return 0 end
        local best = 0
        for _, v in ipairs(world.list(world.field(net, "waystations"))) do
            local o = world.object("starbase", ref(v))
            local sid = o and ref(world.field(o, "station"))
            if sid and world.object("ship", sid) then best = math.max(best, used_share(sid)) end
        end
        return best
    end)

    -- ------------------------------------------------------------------------------------------
    -- deposits and the colony's economy

    -- the scope's colony carrier (NScriptUtil::GetCarrierFromScope: a planet, a ship, a colony's)
    local function carrier(sc)
        if not sc or sc == NONE then return nil end
        return rt().carrier_of(sc.kind, sc.id)
    end
    -- a deposit type's `resources = { produces = { <res> = x } }` (CDeposit::GetNumResources: the
    -- produce blocks whose `trigger` holds in the planet's scope, the owner as from) [I: a produce
    -- block's value a number]
    local function deposit_amounts(dtype, kind, id)
        local out = {}
        local t = rt().deposit_type_field(dtype, "resources")
        for _, b in ipairs(type(t) == "table" and t or {}) do
            if b.op and b.key and b.key.text == "produces" and b.value.text == nil then
                local tr = defs().field(b.value, "trigger")
                local holds = true
                if type(tr) == "table" then
                    local ok, h = pcall(eval.trigger, tr, eval.new_ctx(S(kind, id), nil, nil, "deposit"))
                    holds = ok and h
                end
                if holds then
                    for _, x in ipairs(b.value) do
                        if x.op and x.key and x.value.text and x.key.text ~= "trigger" then
                            local v = tonumber(x.value.text)
                            if v then out[x.key.text] = (out[x.key.text] or 0) + v end
                        end
                    end
                end
            end
        end
        return out
    end
    local function carrier_amounts(sc)
        local kind, id = carrier(sc)
        if not kind then return nil end
        local out = {}
        for _, did in ipairs(rt().carrier_deposits(kind, id)) do
            local dt = rt().deposit_type(did)
            for k, v in pairs(dt and deposit_amounts(unq(dt), kind, id) or {}) do out[k] = (out[k] or 0) + v end
        end
        return out
    end

    -- num_energy / num_minerals <op> n (CNumEnergyTrigger 0x3b52200 / CNumMineralsTrigger 0x3b51fe0)
    -- [V]: the carrier's deposits' produced energy / minerals (not the colony's economy); no carrier:
    -- false
    for k, res in pairs({ num_energy = "energy", num_minerals = "minerals" }) do
        value_trigger(k, function(ctx)
            local t = carrier_amounts(ctx.this)
            return t and (t[res] or 0) or nil
        end)
    end

    -- has_any_strategic_resource = yes/no (CHasAnyStrategicResourceTrigger 0x3b61e10) [V]: a deposit of
    -- the carrier produces something (any resource, not only strategic ones); no carrier: `no` true
    TRIG["has_any_strategic_resource"] = function(e, ctx)
        sync()
        local t = carrier_amounts(ctx.this)
        local any = false
        for _, v in pairs(t or {}) do if v ~= 0 then any = true break end end
        return any == yes_no(e)
    end

    -- planet_resource_compare = { resource value type } (CPlanetResourceCompareTrigger 0x3bdc6b0)
    -- [V]: the colony's economy (CColony::CalcSingleResourceIncludePops: its units and its pops' jobs):
    -- produces, upkeep, or balance (produces - upkeep, the default); engine.economy's colony tables
    -- (computed with the owner's budget)
    value_trigger("planet_resource_compare", function(ctx, e)
        local sc = ctx.this
        if not e or e.value.text or not sc or sc == NONE then return nil end
        local key = param_text(e.value, "resource")
        if not key or not market().resource(key) then return nil end
        local col = rt().colony_of(sc.kind, sc.id)
        if not col then return nil end
        local kind, pid = rt().carrier_of("colony", col)
        local p = kind and world.object(kind, pid)
        local owner = p and ref(world.field(p, "owner"))
        local economy = package.loaded["engine.economy"] or require("engine.economy")
        if owner and economy.budget then pcall(economy.budget, owner) end
        local ct = economy.colony_tables and economy.colony_tables[col] or { income = {}, expenses = {} }
        local prod, up = fixed(ct.income[key] or 0), fixed(ct.expenses[key] or 0)
        local t = param_text(e.value, "type") or "balance"
        if t == "produces" then return prod end
        if t == "upkeep" then return up end
        return fixed(prod - up)
    end)

    -- ship_size_cost_resource_percent = <resource> (a ship, a growth stage; CShipSizeCostResourcePercent
    -- 0x3c37fd0) [V]: the resource's share of the ship size's cost table (evaluated in the scope), 0
    -- when the table is empty
    local function size_cost(sid, d)
        local economy = require("engine.economy")
        local units = require("engine.economy.units")
        local cost, total = {}, 0
        for _, b in ipairs(units.blocks_of(d, "resources")) do
            local t = economy.template(b, d.file)
            local c = eval.new_ctx(S("ship", sid), nil, nil, d.file)
            for _, blk in ipairs(t.cost or {}) do
                if blk.trigger == nil or eval.trigger(blk.trigger, c) then
                    local m = blk.mult and economy.value_of(blk.mult, c) or 1
                    for _, rv in ipairs(blk.values) do
                        local v = economy.value_of(rv[2], c) * m
                        cost[rv[1]] = (cost[rv[1]] or 0) + v
                        total = total + v
                    end
                end
            end
        end
        return cost, total
    end
    -- (the game reads `resource` (token 0x3fe9) from a block: `= { resource = <key> value <op> x }`,
    -- as vanilla's complex_trigger_modifier parameters give it; the docs' `= <key>` also taken)
    value_trigger("ship_size_cost_resource_percent", function(ctx, e)
        local sc = ctx.this
        if not e or not sc or sc == NONE or sc.kind ~= "ship" then return nil end
        local key = e.value.text and unq(e.value.text) or param_text(e.value, "resource")
        if not key then return nil end
        local d = ship_size_def(sc.id)
        if not d then return nil end
        local ok, cost, total = pcall(size_cost, sc.id, d)
        if not ok or total == 0 then return 0 end
        local m = market()
        return m.div(m.fx(cost[key] or 0), m.fx(total)) / m.ONE
    end)

    -- ------------------------------------------------------------------------------------------
    -- slavery (a country's `modules.standard_species_rights_module.species_rights = { { species_index
    -- slavery former_slavery last_changed_slavery_type last_changed_value ... } }`)

    local function rights_module(country)
        local c = world.object("country", country)
        local m = c and world.path(c, "modules", "standard_species_rights_module")
        if type(m) ~= "table" or world.field(m, "enabled") == "no" then return nil end
        return m
    end
    -- (the founder species' rights are `primary`, the built species' `built_species` [V: the
    -- game's save after set_slavery_type on the founder species], the others in species_rights)
    local function rights_of(m, species)
        for _, k in ipairs({ "primary", "built_species" }) do
            local b = world.field(m, k)
            if type(b) == "table" and ref(world.field(b, "species_index")) == species then return b end
        end
        for _, b in ipairs(world.blocks(world.field(m, "species_rights"))) do
            if ref(world.field(b, "species_index")) == species then return b end
        end
        return nil
    end
    -- the species of a pop, pop group, leader or species scope (CEventScope::GetTargetSpecies)
    local function scope_species(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "species" then return sc.id end
        if sc.kind == "pop_group" or sc.kind == "pop" or sc.kind == "leader" then
            local o = world.object(sc.kind == "pop" and "pop_group" or sc.kind, sc.id)
            return o and ref(world.field(o, "species"))
        end
        return nil
    end
    -- the owner of a pop group's colony carrier
    local function pop_owner(gid)
        local g = world.object("pop_group", gid)
        local col = g and ref(world.field(g, "planet"))
        local kind, id = col and rt().carrier_of("colony", col)
        local o = kind and world.object(kind, id)
        return o and ref(world.field(o, "owner"))
    end
    -- the date `years` from today ("y.m.d")
    local function years_on(years)
        local y, m, d = tostring(unq(world.meta.date) or "2200.01.01"):match("(%d+)%.(%d+)%.(%d+)")
        return string.format("%d.%02d.%02d", (tonumber(y) or 2200) + years, tonumber(m) or 1, tonumber(d) or 1)
    end

    -- set_slavery_type = { country type cooldown } (CSetSpeciesRightsEffect<SSetSlaveryType> 0x382c780)
    -- [V]: the species' rights in the country's species_rights (the `country` given, else the
    -- scope's: a pop's owner, a leader's country), made from `default` when it has none [I]:
    -- last_changed_value = slavery even without a change; a change: former_slavery = the old type,
    -- slavery = the new; cooldown = yes: last_changed_slavery_type = today + SPECIES_POLICY_YEARS
    EFF["set_slavery_type"] = function(e, ctx)
        if e.value.text then return end
        local sc = ctx.this
        local species = scope_species(sc)
        local stype = param_text(e.value, "type")
        if not species or not stype then return end
        -- (an unknown type: the game's reader rejects it; the folder checked when engine.defs has it)
        local folder = defs().folders and defs().folders["common/species_rights/slavery_types"]
        if folder and not defs().get("common/species_rights/slavery_types", stype) then return end
        local country = scope_country(param_scope(e.value, "country", ctx, e))
        if not country and sc and sc ~= NONE then
            if sc.kind == "pop_group" or sc.kind == "pop" then country = pop_owner(sc.id)
            elseif sc.kind == "leader" then
                local l = world.object("leader", sc.id)
                country = l and ref(world.field(l, "country"))
            end
        end
        sync()
        local m = country and rights_module(country)
        if not m then return end
        local cfg = rights_of(m, species)
        if not cfg then
            cfg = {}
            local def = world.field(m, "default")
            for _, x in ipairs(type(def) == "table" and def or {}) do
                if x.op and x.key and x.value.text then
                    world.append(cfg, x.key.text, x.value.text, x.value.quoted)
                end
            end
            if world.field(cfg, "species_index") then world.set(cfg, "species_index", species)
            else world.append(cfg, "species_index", species) end
            world.push(world.child(m, "species_rights"), cfg)
        end
        -- (written before the last_changed_* dates, as the game's WriteMembers orders them)
        local function put(key, text, quoted)
            if world.token_entry(cfg, key) then
                world.set(cfg, key, text)
            else
                local pos = #cfg + 1
                for i, x in ipairs(cfg) do
                    if x.op and x.key and x.key.text:find("^last_changed_") and x.key.text ~= "last_changed_value" then pos = i break end
                end
                world.insert(cfg, pos, key, text, quoted)
            end
            if quoted then world.token_entry(cfg, key).value.quoted = true end
        end
        put("last_changed_value", "slavery")
        written()
        local old = unq(world.field(cfg, "slavery"))
        if old == stype then return end
        put("former_slavery", old or "", true)
        market().set_quoted(cfg, "slavery", stype)
        if param_text(e.value, "cooldown") == "yes" then
            local years = tonumber(rt().define("NGameplay", "SPECIES_POLICY_YEARS", 10)) or 10
            market().set_quoted(cfg, "last_changed_slavery_type", years_on(years))
        end
    end

    -- former_slavery_type = <type> (pop, pop group; CFormerSpeciesRightTrigger<SHasSlaveryType>
    -- 0x3c489f0) [V]: the former slavery type in the pop owner's species rights for its species
    -- (`default` when it has none [I])
    TRIG["former_slavery_type"] = function(e, ctx)
        local sc = ctx.this
        if not e.value.text or not sc or sc == NONE or (sc.kind ~= "pop_group" and sc.kind ~= "pop") then return false end
        sync()
        local owner = pop_owner(sc.id)
        local m = owner and rights_module(owner)
        if not m then return false end
        local cfg = rights_of(m, scope_species(sc)) or world.field(m, "default")
        return type(cfg) == "table" and unq(world.field(cfg, "former_slavery")) == unq(e.value.text)
    end

    -- the enslaved species (CEnslavedSpecies::BuildIDArray 0x3ab6400) [V]: the saved
    -- enslaved_species_refs of a country, or of the colony of a planet, a colony or a ship, in order
    LISTS["enslaved_species"] = function(sc)
        if not sc or sc == NONE then return {} end
        sync()
        local o
        if sc.kind == "country" then
            o = world.object("country", sc.id)
        else
            local col = rt().colony_of(sc.kind, sc.id)
            o = col and world.object("colony", col)
        end
        local out = {}
        for _, v in ipairs(world.list(o and world.field(o, "enslaved_species_refs"))) do
            local id = ref(v)
            if id and world.object("species", id) then out[#out + 1] = S("species", id) end
        end
        return out
    end

    -- ------------------------------------------------------------------------------------------
    -- cosmic storms' influence fields (top-level storm_influence_fields = { storm_influence_fields =
    -- { <id> = { center radius influence is_timed_influence_field storm_influence_groups } } };
    -- a system's storm_influence_fields = { <ids> })

    local function fields_store()
        local ok, ids = pcall(world.all, "storm_influence_fields")
        if ok and type(ids) == "table" and #ids > 0 then
            local out = {}
            for _, id in ipairs(ids) do out[#out + 1] = { id = id, block = world.object("storm_influence_fields", id) } end
            return out
        end
        local top = world.meta.storm_influence_fields
        local inner = type(top) == "table" and world.field(top, "storm_influence_fields")
        local out = {}
        for k, v in world.statements(type(inner) == "table" and inner or {}) do
            if type(v) == "table" and tonumber(k) then out[#out + 1] = { id = tonumber(k), block = v } end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    local function field_block(id)
        for _, f in ipairs(fields_store()) do
            if f.id == id then return f.block end
        end
        return nil
    end

    -- any/every/random/ordered/count_owned_storm_influence_field (a country;
    -- COwnedInfluenceFieldListBuilder 0x38eaad0) [V]: the fields (by id) whose center system's owner
    -- is the country (a field has no owner of its own)
    LISTS["owned_storm_influence_field"] = function(sc)
        if not sc or sc == NONE or sc.kind ~= "country" then return {} end
        sync()
        local out = {}
        for _, f in ipairs(fields_store()) do
            local c = ref(world.field(f.block, "center"))
            if c and rt().system_owner(c) == sc.id then out[#out + 1] = S("cosmic_storm_influence_field", f.id) end
        end
        return out
    end

    -- the fields of a system's list centred on it
    local function centred(sid)
        local s = world.object("system", sid)
        local out = {}
        for _, v in ipairs(world.list(s and world.field(s, "storm_influence_fields"))) do
            local id = ref(v)
            local b = id and field_block(id)
            if b and ref(world.field(b, "center")) == sid then out[#out + 1] = { id = id, block = b } end
        end
        return out
    end

    -- storm_influence_field (a system -> its field; CEventTarget::GetScope 0x257f4b2) [V]: the last
    -- field of the system's list centred on it (timed or not); none: no scope
    LINKS["storm_influence_field"] = function(cur)
        if not cur or cur == NONE or cur.kind ~= "system" then return nil end
        sync()
        local list = centred(cur.id)
        local f = list[#list]
        return f and S("cosmic_storm_influence_field", f.id) or nil
    end

    -- is_influence_center = yes/no (a system; CIsInfluenceCenterTrigger 0x3bf0260) [V]: a field of
    -- the system's list that is not timed is centred on it (the docs' text is another trigger's)
    TRIG["is_influence_center"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "system" then return false end
        sync()
        local found = false
        for _, f in ipairs(centred(sc.id)) do
            if world.field(f.block, "is_timed_influence_field") ~= "yes" then found = true break end
        end
        return found == yes_no(e)
    end

    -- recalculate_storm_influence_field = yes (an influence field; CRecalculateStormInfluenceFieldsEffect
    -- 0x37e5110) [V]: CCosmicStormInfluenceField::RecalculateAllSystems: each grouped system's
    -- influence totals made again. Those totals are not saved and the groups and `influence` are not
    -- rebuilt, so the world does not change
    EFF["recalculate_storm_influence_field"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "cosmic_storm_influence_field" then return end
        -- (the field's groups read as the game walks them; nothing saved changes)
        local b = field_block(sc.id)
        local _ = b and world.blocks(world.field(b, "storm_influence_groups"))
    end
end
