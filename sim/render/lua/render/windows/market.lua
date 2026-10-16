-- render/windows/market.lua : the galactic market (interface/market_view.gui, CMarketView;
-- docs/windows/economy.md), bound to the save's world.
--
--   local market = require("render.windows.market")
--   local d = market.data(country_id, state, game_dir)  -- in the world's runtime: plain values
--   local items, report = market.build(game_dir, db, screen, texture_size, loc, d, state)
--
-- state (the view's own, App::view_state): tab ("market" | "slave_market"), resource (the one
-- selected; else the first the country can trade, as CMarketView::UpdateMarketTab picks it).
--
-- The prices are CMarket's (CalcResourcePriceForAmount, NMarketUtil::CalcFluctuation and
-- CalcPriceWithSimulatedFluctuation, AddTradeFeeToPrice), computed in the game's fixed point
-- (1.0 = 100000, products and quotients truncated).

local gui = require("render.gui")
local text = require("render.windows.text")

local market = {}

local FILE = "interface/market_view.gui"
local V = "/market_view"
local M = V .. "/market"

-- ---------------------------------------------------------------------------------------------
-- the game's fixed point

local ONE = 100000

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
    return trunc(a * ONE / b)
end
market.fx, market.mul, market.div = fx, mul, div

-- ---------------------------------------------------------------------------------------------
-- the definitions: NDefines::NEconomy (common/defines), the resources in their file's order

local DEF = {
    TRADE_AMOUNT_MULTIPLIER = { 1, 5, 10, 50, 100 },
    MARKET_TRADE_FEE_BASE = 0.3, MARKET_TRADE_FEE_MIN = 0.05,
    MARKET_FLUCTUATION_ABOVE_BASE_PRICE = 1, MARKET_FLUCTUATION_BELOW_BASE_PRICE = 0.3,
    MARKET_MIN_FLUCTUATION_FROM_BASE_PRICE = -80, MARKET_MAX_FLUCTUATION_FROM_BASE_PRICE = 400,
    MARKET_MAX_BASE_AMOUNTS = 200, INTERNAL_MARKET_FLUCTUATION_MULT = 2, MARKET_RESOURCE = "trade",
}

local defs_cache = {}

local function definitions(game_dir)
    if defs_cache[game_dir] then
        return defs_cache[game_dir]
    end
    local source = require("stellar.script.source")
    local get = require("render.gfx").get
    local d = { defines = {}, resources = {} }
    for k, v in pairs(DEF) do
        d.defines[k] = v
    end
    -- NDefines::NEconomy from the defines file (the values above when it cannot be read)
    local ok, tree = pcall(source.parse, game_dir, "common/defines/00_defines.txt")
    local ne = ok and tree and get(get(tree, "NDefines"), "NEconomy")
    if type(ne) == "table" then
        for k in pairs(DEF) do
            local v = get(ne, k)
            if type(v) == "table" then
                local list = {}
                for _, e in ipairs(v) do
                    if e.text then
                        list[#list + 1] = tonumber(e.text)
                    end
                end
                d.defines[k] = list
            elseif v ~= nil then
                d.defines[k] = tonumber(v) or (tostring(v):gsub('"', ""))
            end
        end
    end
    -- the resources (CStrategicResourceDatabase, the definition order; the game's one file):
    -- tradable, market_amount, market_price
    for _, f in ipairs({ "common/strategic_resources/00_strategic_resources.txt" }) do
        local okf, t = pcall(source.parse, game_dir, f)
        if okf and t then
            for _, e in ipairs(t) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                    local b = e.value
                    d.resources[#d.resources + 1] = {
                        key = e.key.text,
                        tradable = get(b, "tradable") == "yes",
                        market_amount = tonumber(get(b, "market_amount")) or 0,
                        market_price = tonumber(get(b, "market_price")) or 0,
                    }
                end
            end
        end
    end
    defs_cache[game_dir] = d
    return d
end
market.definitions = definitions

-- ---------------------------------------------------------------------------------------------
-- CMarket's prices

-- NMarketUtil::CalcFluctuation: the fluctuation after `n` base amounts traded (n fixed point)
local function next_fluctuation(D, buy, f, n, internal)
    local m = internal and fx(D.INTERNAL_MARKET_FLUCTUATION_MULT) or ONE
    local A = mul(fx(D.MARKET_FLUCTUATION_ABOVE_BASE_PRICE), m)
    local B = mul(fx(D.MARKET_FLUCTUATION_BELOW_BASE_PRICE), m)
    if A == 0 or B == 0 then
        return f
    end
    if buy then
        if f >= 0 then
            f = f + mul(n, A)
        else
            local g = f + mul(n, B)
            -- [I: the split where the price crosses its base]
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

-- CMarket::CalcResourcePriceForAmount(amount, trade, with fee): fixed point in and out
local function price_for(D, r, amount, buy, f0, internal, fee)
    local ma, mp = fx(r.market_amount), fx(r.market_price)
    local k = div(amount, ma)
    local cur = mp + f0
    local price
    if k < ONE then
        price = mul(k, cur)
    elseif k == ONE then
        price = cur
    else
        -- CalcPriceWithSimulatedFluctuation over the base amounts after the first
        local f = next_fluctuation(D, buy, f0, ONE, internal)
        local n = math.min(k - ONE, fx(D.MARKET_MAX_BASE_AMOUNTS))
        local sum = 0
        while n >= ONE do
            sum = sum + mp + f
            f = next_fluctuation(D, buy, f, ONE, internal)
            n = n - ONE
        end
        if n > 0 then
            sum = sum + mul(mp + f, n)
        end
        price = cur + sum
    end
    if fee then
        price = mul(price, buy and (ONE + fee) or (ONE - fee))
    end
    return price
end
market.price_for = price_for

-- ---------------------------------------------------------------------------------------------
-- the data, read in the world's runtime

local function numbers(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = tonumber(e.text) or 0
        end
    end
    return out
end

-- a `country=N amount={...}` list (resources_bought, resources_sold): country index -> amounts
local function per_country(world, block)
    local out, current = {}, nil
    for k, v in world.statements(type(block) == "table" and block or {}) do
        if k == "country" then
            current = tonumber(v)
        elseif k == "amount" and current then
            out[current] = numbers(v)
        end
    end
    return out
end

-- a `{ category = { resource = value } }` table summed by resource
local function by_resource(world, block)
    local out = {}
    for _, v in world.statements(type(block) == "table" and block or {}) do
        if type(v) == "table" then
            for r, x in world.statements(v) do
                out[r] = (out[r] or 0) + (tonumber(x) or 0)
            end
        end
    end
    return out
end

-- market.data(country_id, state, game_dir) -> the window's values (plain: they cross runtimes)
function market.data(cid, state, game_dir)
    local world = require("engine.world")
    state = state or {}
    local d = definitions(game_dir)
    local D = d.defines
    local c = world.object("country", cid)
    local out = { country = cid, resources = {}, trades = {} }
    if not c then
        return out
    end
    -- the stockpile and the month's income and expenses (the budget's current_month)
    local stock = {}
    for k, v in world.statements(world.path(c, "modules", "standard_economy_module", "resources") or {}) do
        stock[k] = tonumber(v) or 0
    end
    local income = by_resource(world, world.path(c, "budget", "current_month", "income"))
    local expenses = by_resource(world, world.path(c, "budget", "current_month", "expenses"))
    -- the market (the top level `market = { ... }`, CMarket::WriteMembers)
    local m = world.meta.market
    m = type(m) == "table" and m or {}
    local ids = numbers(world.field(m, "id"))
    local index = cid % 16777216   -- a country's index: its id's low 24 bits
    local mine = ids[index + 1] == cid
    -- the galactic market: founded (its flag), this country's access (per country index)
    -- [I: the save's key names of the founded flag, the access and fluctuation arrays]
    local galactic = world.field(m, "galactic_market") == "yes" or world.field(m, "enabled") == "yes"
    local access = false
    if galactic then
        access = numbers(world.field(m, "galactic_market_access"))[index + 1] == 1
    end
    local internal = not access
    -- the fluctuations: the galactic market's per resource, else the country's internal ones
    local fluct = {}
    if access then
        local list = numbers(world.field(m, "fluctuations"))
        for i, r in ipairs(d.resources) do
            fluct[r.key] = list[i] or 0
        end
    else
        local current
        for k, v in world.statements(world.field(m, "internal_market_fluctuations") or {}) do
            if k == "country" then
                current = tonumber(v)
            elseif k == "resources" and current == cid then
                for r, x in world.statements(v) do
                    fluct[r] = tonumber(x) or 0
                end
            end
        end
    end
    local bought = mine and per_country(world, world.field(m, "resources_bought"))[index] or {}
    local sold = mine and per_country(world, world.field(m, "resources_sold"))[index] or {}
    -- the fee: MARKET_TRADE_FEE_BASE + country_trade_fee, at least MARKET_TRADE_FEE_MIN [I: the
    -- country's modifier is not evaluated here: the base]
    local fee = fx(math.max(D.MARKET_TRADE_FEE_MIN, D.MARKET_TRADE_FEE_BASE))
    local currency = D.MARKET_RESOURCE
    out.fee = fee
    out.currency = currency
    out.currency_stock = stock[currency] or 0
    out.access = access
    out.galactic = galactic
    local leader = tonumber(world.field(m, "country"))
    out.leader = (leader and leader ~= 4294967295) and leader or nil
    -- the DLC of the slave market (Megacorp) among the save's
    out.megacorp = false
    for _, dlc in ipairs(world.list(world.meta.required_dlcs)) do
        if dlc:gsub('"', "") == "Megacorp" then
            out.megacorp = true
        end
    end
    -- the resources the grid lists (CMarket::GetValidAndVisibleResources): tradable with a
    -- market amount and price; on the internal market only those with an income [I: which
    -- resources count their expenses instead: not read]
    local valid = {}
    for i, r in ipairs(d.resources) do
        local tradable = r.tradable and r.market_amount > 0 and r.market_price > 0
        if tradable and r.key ~= currency and (access or (income[r.key] or 0) > 0) then
            valid[#valid + 1] = r
            out.resources[#out.resources + 1] = { key = r.key, stock = stock[r.key] or 0, index = i }
        end
    end
    -- the selected resource: the state's, if valid, else the first valid one
    local sel
    for _, r in ipairs(valid) do
        if r.key == state.resource then
            sel = r
        end
    end
    sel = sel or valid[1]
    if sel then
        out.selected = sel.key
        local f0 = fx(fluct[sel.key] or 0)
        out.unit_buy = price_for(D, sel, ONE, true, f0, internal, fee)
        out.unit_sell = price_for(D, sel, ONE, false, f0, internal, fee)
        for _, ri in ipairs(out.resources) do
            if ri.key == sel.key then
                out.bought = bought[ri.index] or 0
                out.sold = sold[ri.index] or 0
            end
        end
        out.buy, out.sell = {}, {}
        for _, mult in ipairs(D.TRADE_AMOUNT_MULTIPLIER) do
            local amount = mult * sel.market_amount
            local bp = price_for(D, sel, fx(amount), true, f0, internal, fee)
            local sp = price_for(D, sel, fx(amount), false, f0, internal, fee)
            -- buy: the price rounded up, too dear beyond the currency's stockpile; sell: rounded
            -- down, not possible beyond the resource's stockpile (CanBuyResource, CanSellResource)
            out.buy[#out.buy + 1] = { amount = amount, price = math.ceil(bp / ONE), ok = fx(out.currency_stock) - bp >= 0 }
            out.sell[#out.sell + 1] = { amount = amount, price = math.floor(sp / ONE), ok = (stock[sel.key] or 0) >= amount }
        end
    end
    -- the monthly trades: this country's [I: their save fields, none in the saves read]
    for k, v in world.statements(m) do
        if k == "monthly_trades" and type(v) == "table" then
            for _, t in ipairs(world.blocks(v)) do
                if tonumber(world.field(t, "country")) == cid then
                    out.trades[#out.trades + 1] = {
                        resource = tostring(world.field(t, "resource") or ""),
                        buy = tostring(world.field(t, "type") or "buy") ~= "sell",
                        amount = tonumber(world.field(t, "amount")) or 0,
                        limit = tonumber(world.field(t, "price_limit")) or 0,
                    }
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the layout

-- a stockpile as the resources grid shows it (CreateSIValueNoColor: one decimal, cut; under
-- 1000 the whole units)
function market.stockpile(v)
    local a = math.abs(v)
    local s = v < 0 and "-" or ""
    if a >= 1e9 then
        return string.format("%s%.1fG", s, math.floor(a / 1e8) / 10)
    elseif a >= 1e6 then
        return string.format("%s%.1fM", s, math.floor(a / 1e5) / 10)
    elseif a >= 1e3 then
        return string.format("%s%.1fK", s, math.floor(a / 1e2) / 10)
    end
    return s .. tostring(math.floor(a))
end

-- a fixed point value with 2 decimals, cut (the localisation's default)
function market.two(v)
    local cents = trunc(v / 1000)
    local s = cents < 0 and "-" or ""
    cents = math.abs(cents)
    return string.format("%s%d.%02d", s, math.floor(cents / 100), cents % 100)
end

-- the fee as a percentage (CString of a fixed point: up to 5 decimals, the zeros cut)
local function percent(fee)
    local v = fee * 100
    local whole = trunc(v / ONE)
    local frac = math.abs(v - whole * ONE)
    if frac == 0 then
        return tostring(whole)
    end
    return (string.format("%d.%05d", whole, frac):gsub("0+$", ""))
end

-- the entries of a grid box (`path`, laid out: report.grids), each at its slot (gui.grid_slot);
-- each(entry, element path, i) -> the entry's layout options
local function grid_entries(ctx, items, report, file, window, path, list, each)
    local g = report.grids and report.grids[path]
    if not g then
        return
    end
    for i, e in ipairs(list) do
        local x, y = gui.grid_slot(g, i - 1, #list)
        if not x then
            break
        end
        local prefix = path .. "/" .. i
        local spec = each(e, prefix .. "/" .. window, i)
        spec.texture_size, spec.loc, spec.prefix = ctx.texture_size, ctx.loc, prefix
        spec.parent = { x = x, y = y, w = 0, h = 0 }
        local ok, it, rp = pcall(gui.layout, ctx.game_dir, ctx.db, file, window, ctx.screen, spec)
        if ok then
            gui.merge(items, report, it, rp)
        else
            report.missing_sprites[#report.missing_sprites + 1] = window .. ": " .. tostring(it)
        end
    end
end
market.grid_entries = grid_entries

function market.build(game_dir, db, screen, texture_size, loc, data, state)
    data = data or {}
    state = state or {}
    local ctx = { game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc }
    local slave = state.tab == "slave_market"
    local hide, texts, actions, sizes, disabled = {}, {}, {}, {}, {}
    actions[V .. "/close"] = "close_view"
    -- the tabs (CGameGraphics::UpdateTabVisibility: the active tab's _active button, the other's
    -- plain one; the slave market's only with Megacorp)
    hide[V .. (slave and "/tab_slave_market" or "/tab_market")] = true
    hide[V .. (slave and "/tab_market_active" or "/tab_slave_market_active")] = true
    if data.megacorp == false then
        hide[V .. "/tab_slave_market"] = true
        hide[V .. "/tab_slave_market_active"] = true
    end
    actions[V .. "/tab_market"] = "state:tab=market"
    -- (the slave market's tab takes clicks only with the galactic market's access:
    -- CMarketView::Update)
    if data.access then
        actions[V .. "/tab_slave_market"] = "state:tab=slave_market"
    else
        disabled[V .. "/tab_slave_market"] = true
    end
    hide[V .. (slave and "/market" or "/slave_market")] = true
    texts[V .. "/windows_title"] = slave and "SLAVE_MARKET" or "MARKET_VIEW"
    -- the buy and sell boxes clip their lists (clipping = yes) at their 240 [I: drawn at the box's
    -- width here: the renderer does not clip]
    sizes[M .. "/buy_box/empire_list"] = { 240, 225 }
    sizes[M .. "/sell_box/empire_list"] = { 240, 225 }

    local cur = data.currency or "trade"
    local sel = data.selected
    if sel then
        texts[M .. "/buy_box/unit_price_buy"] = text.format(loc, "RESOURCE_UNIT_PRICE", { KEY = sel, CURRENCY_KEY = cur, PRICE = "§Y" .. market.two(data.unit_buy) .. "§!" })
        texts[M .. "/sell_box/unit_price_sell"] = text.format(loc, "RESOURCE_UNIT_PRICE", { KEY = sel, CURRENCY_KEY = cur, PRICE = "§Y" .. market.two(data.unit_sell) .. "§!" })
        local name = text.format(loc, sel, {})
        texts[M .. "/total_bought_text"] = text.format(loc, "MARKET_TOTAL_BOUGHT", { RESOURCE = name, KEY = sel, VALUE = "§Y" .. math.floor(data.bought or 0) .. "§!" })
        texts[M .. "/total_sold_text"] = text.format(loc, "MARKET_TOTAL_SOLD", { RESOURCE = name, KEY = sel, VALUE = "§Y" .. math.floor(data.sold or 0) .. "§!" })
    else
        hide[M .. "/buy_box/unit_price_buy"] = true
        hide[M .. "/sell_box/unit_price_sell"] = true
    end
    -- the fee (built in code: §Y<fee x 100>%§!), the currency's stockpile
    texts[M .. "/trade_fee_box/trade_fee_value"] = "§Y" .. percent(data.fee or 30000) .. "%§!"
    texts[M .. "/trade_stockpile_box/trade_stockpile_header"] = text.format(loc, "MARKET_TRADE_STOCKPILE_HEADER", { CURRENCY = text.format(loc, cur, {}) })
    texts[M .. "/trade_stockpile_box/trade_stockpile_value"] = text.format(loc, "MARKET_TRADE_STOCKPILE_VALUE", { CURRENCY_KEY = cur, VALUE = "§Y" .. math.floor(data.currency_stock or 0) .. "§!" })
    -- the market's state: the galactic market (its leader) or the internal one (and why)
    if data.access then
        texts[M .. "/market_state"] = "GALACTIC_MARKET"
        hide[M .. "/market_info_window/market_info"] = true
        if not data.leader then
            hide[M .. "/market_info_window/market_leader"] = true
        end
    else
        texts[M .. "/market_state"] = "INTERNAL_MARKET"
        hide[M .. "/market_info_window/market_leader"] = true
        texts[M .. "/market_info_window/market_info"] = data.galactic and "GALACTIC_MARKET_FOUNDED_NO_ACCESS_DESC" or "GALACTIC_MARKET_NOT_FOUNDED_DESC"
    end

    local items, report = gui.layout(game_dir, db, FILE, "market_view", screen, {
        texture_size = texture_size, loc = loc, hide = hide, text = texts, actions = actions, sizes = sizes, disabled = disabled,
    })
    if slave then
        return items, report
    end
    local function rect_of(path)
        local r = report.rects[path]
        return r and { x = r.x, y = r.y, path = path } or nil
    end
    -- the resources grid: a market_resource_grid_entry per resource, 81 x 35 apart, 3 a row:
    -- its stockpile after the resource's text icon (£key|1), the selected one's glow
    local rg = rect_of(M .. "/resources_box/resources_grid")
    if rg then
        grid_entries(ctx, items, report, FILE, "market_resource_grid_entry", M .. "/resources_box/resources_grid", data.resources or {}, function(r, p)
            return {
                text = { [p .. "/resource_amount"] = "£" .. r.key .. "£" .. market.stockpile(r.stock) },
                hide = { [p .. "/selected_overlay"] = (r.key ~= sel) or nil, [p .. "/disabled_bg"] = true },
                actions = { [p] = "state:resource=" .. r.key },
            }
        end)
    end
    -- the buy and sell grids: a market_trade_resource_grid_entry per TRADE_AMOUNT_MULTIPLIER,
    -- 75 x 88 apart, 3 a row: the resource's large icon, the amount, the price in the currency
    if sel then
        for _, side in ipairs({ { "buy_box/buy_resources_grid", data.buy or {}, true }, { "sell_box/sell_resources_grid", data.sell or {}, false } }) do
            local gr = rect_of(M .. "/" .. side[1])
            if gr then
                grid_entries(ctx, items, report, FILE, "market_trade_resource_grid_entry", M .. "/" .. side[1], side[2], function(e, p)
                    local amount, price
                    if side[3] then
                        amount = "+" .. e.amount
                        price = e.ok and ("-" .. e.price) or ("§R-" .. e.price .. "§!")
                    else
                        amount = e.ok and ("-" .. e.amount) or ("§R-" .. e.amount .. "§!")
                        price = "+" .. e.price
                    end
                    return {
                        sprites = { [p .. "/large_resource_icon"] = "GFX_resource_" .. sel .. "_large" },
                        disabled = { [p] = not e.ok or nil },
                        text = { [p .. "/resource_amount"] = amount, [p .. "/price"] = "£" .. cur .. "£" .. price },
                    }
                end)
            end
        end
    end
    -- the monthly trades: a market_monthly_trade_grid_entry each, 30 apart
    local tg = rect_of(M .. "/automatic_trades_box/trades/trade_grid_box/monthly_trades_grid")
    if tg then
        grid_entries(ctx, items, report, FILE, "market_monthly_trade_grid_entry", M .. "/automatic_trades_box/trades/trade_grid_box/monthly_trades_grid", data.trades or {}, function(t, p)
            return {
                sprites = { [p .. "/resource_icon"] = "GFX_resource_" .. t.resource },
                text = {
                    [p .. "/trade_type"] = t.buy and "MARKET_BUY" or "MARKET_SELL",
                    [p .. "/amount"] = tostring(math.floor(t.amount)),
                    [p .. "/price_text"] = t.buy and "MAX_PRICE" or "MIN_PRICE",
                    [p .. "/price_value"] = "£" .. cur .. "£ " .. (t.limit > 0 and tostring(math.floor(t.limit)) or " -"),
                },
            }
        end)
    end
    return items, report
end

return market
