-- render/windows/market.lua : the galactic market (interface/market_view.gui, CMarketView;
-- docs/windows/economy.md), bound to the save's world.
--
--   market.extract(game_dir) -> data    the player's market, read where the galaxy is (views.rs)
--   market.build(ctx, data, state) -> items, report
--
-- state (the view's own, App::view_state, `view_set:`): tab ("market" | "slave_market"),
-- resource (the one selected; else the first the country can trade, as
-- CMarketView::UpdateMarketTab picks it).
--
-- The prices are CMarket's (CalcResourcePriceForAmount, NMarketUtil::CalcFluctuation and
-- CalcPriceWithSimulatedFluctuation, AddTradeFeeToPrice), computed in the game's fixed point
-- (1.0 = 100000, products and quotients truncated).

local gui = require("render.gui")
local text = require("render.loctext")

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
    -- the traits' slave_cost (CTraitSet::CalcSlaveCost), the files in name order
    d.slave_cost = {}
    local p = io.popen("ls '" .. game_dir .. "/common/traits' 2>/dev/null")
    local files = {}
    if p then
        for line in p:lines() do
            if line:match("%.txt$") then
                files[#files + 1] = "common/traits/" .. line
            end
        end
        p:close()
    end
    table.sort(files)
    for _, f in ipairs(files) do
        local okf, t = pcall(source.parse, game_dir, f)
        for _, e in ipairs(okf and t or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local sc = get(e.value, "slave_cost")
                if type(sc) == "table" then
                    d.slave_cost[e.key.text] = tonumber(get(sc, "trade")) or 0
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

-- market.data(country_id, game_dir) -> the window's values (plain: they cross runtimes)
function market.data(cid, game_dir)
    local world = require("engine.world")
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
    -- each with its prices (the one selected is the view's state: build)
    for i, r in ipairs(d.resources) do
        local tradable = r.tradable and r.market_amount > 0 and r.market_price > 0
        if tradable and r.key ~= currency and (access or (income[r.key] or 0) > 0) then
            local f0 = fx(fluct[r.key] or 0)
            local e = {
                key = r.key, stock = stock[r.key] or 0,
                unit_buy = price_for(D, r, ONE, true, f0, internal, fee),
                unit_sell = price_for(D, r, ONE, false, f0, internal, fee),
                bought = bought[i] or 0, sold = sold[i] or 0,
                buy = {}, sell = {},
            }
            for _, mult in ipairs(D.TRADE_AMOUNT_MULTIPLIER) do
                local amount = mult * r.market_amount
                local bp = price_for(D, r, fx(amount), true, f0, internal, fee)
                local sp = price_for(D, r, fx(amount), false, f0, internal, fee)
                -- buy: the price rounded up, too dear beyond the currency's stockpile; sell:
                -- rounded down, not possible beyond the resource's stockpile (CanBuyResource,
                -- CanSellResource)
                e.buy[#e.buy + 1] = { amount = amount, price = math.ceil(bp / ONE), ok = fx(out.currency_stock) - bp >= 0 }
                e.sell[#e.sell + 1] = { amount = amount, price = math.floor(sp / ONE), ok = (stock[r.key] or 0) >= amount }
            end
            out.resources[#out.resources + 1] = e
        end
    end
    out.slaves = market.slave_data(world, d, c, cid)
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
-- the slave market (CSlaveMarketView) and the Sell Slaves window (CSlavePoolView)

local function unquote(v)
    return (tostring(v or ""):gsub('"', ""))
end

-- CSlaveMarketManager::CalcPricePerPop without a country's modifier: (the defines' base, 1000
-- trade, + the species' traits' slave_cost) / POP_BULK_UNIT_SIZE (100) [I: the country's slave
-- market cost modifier not evaluated]
local function slave_price_per_pop(world, d, species)
    local cost = 1000
    for _, tr in ipairs(world.fields(world.field(species, "traits") or {}, "trait")) do
        cost = cost + (d.slave_cost[unquote(tr)] or 0)
    end
    return cost / 100
end

-- a colony's planet
local function colony_planet(world, colony)
    local carrier = colony and world.field(colony, "carrier")
    return type(carrier) == "table" and world.object("planet", tonumber(world.field(carrier, "reference"))) or nil
end

function market.slave_data(world, d, c, cid)
    local galaxy = require("render.galaxy")
    local s = { on_market = {}, colonies = {}, species = {}, pool = {} }
    -- the enslaved species (the species rights: citizenship_slavery) [I: CanBeSoldOnSlaveMarket's
    -- other conditions, robots and the trade bans, not evaluated]
    local enslaved = {}
    local sr = world.path(c, "modules", "standard_species_rights_module")
    for _, b in ipairs(type(sr) == "table" and world.blocks(world.field(sr, "species_rights")) or {}) do
        if unquote(world.field(b, "citizenship")) == "citizenship_slavery" then
            enslaved[tonumber(world.field(b, "species_index"))] = true
        end
    end
    -- the market's slaves (slave_market_manager.slaves_on_market: { key = pop group value = amount })
    local on_market = {}
    local smm = world.meta.slave_market_manager
    for _, e in ipairs(type(smm) == "table" and world.blocks(world.field(smm, "slaves_on_market")) or {}) do
        local g, n = tonumber(world.field(e, "key")), tonumber(world.field(e, "value")) or 0
        local pg = g and world.object("pop_group", g)
        if pg then
            on_market[g] = n
            local sp = world.object("species", tonumber(world.path(pg, "key", "species")))
            local planet = colony_planet(world, world.object("colony", tonumber(world.field(pg, "planet"))))
            s.on_market[#s.on_market + 1] = {
                group = g, amount = n,
                species = sp and galaxy.name_block(world.field(sp, "name")),
                class = sp and unquote(world.field(sp, "class")),
                habitability = math.floor((tonumber(world.field(pg, "habitability")) or 0) * 100 + 1e-9),
                price = sp and math.ceil(slave_price_per_pop(world, d, sp) * n) or 0,
                seller = planet and tonumber(world.field(planet, "owner")) == cid or false,
            }
        end
    end
    -- the country's colonies in its order (owned_planets: colony ids [I]), not being colonised
    local capital = tonumber(world.field(c, "capital"))
    local colonies = {}
    for _, id in ipairs(world.list(world.field(c, "owned_planets"))) do
        id = tonumber(id)
        local colony = id and world.object("colony", id)
        local planet = colony_planet(world, colony)
        if planet and unquote(world.field(colony, "status")) ~= "in_progress" then
            colonies[#colonies + 1] = { id = id, colony = colony, planet = planet }
        end
    end
    for _, e in ipairs(colonies) do
        -- the jobs: the colony's workforce over its jobs' workforce limits (CalcWorkforceAmount)
        local a, b = 0, 0
        for _, j in ipairs(world.list(world.field(e.colony, "pop_jobs"))) do
            local job = world.object("pop_job", tonumber(j))
            if job then
                a = a + (tonumber(world.field(job, "workforce")) or 0)
                b = b + math.max(0, tonumber(world.field(job, "workforce_limit")) or 0)
            end
        end
        -- the habitability shown: the founder species' pop group's there [I: GetCachedHabitabilityUI]
        local hab = 1
        for _, g in ipairs(world.list(world.field(e.colony, "pop_groups"))) do
            local pg = world.object("pop_group", tonumber(g))
            if pg and tonumber(world.path(pg, "key", "species")) == tonumber(world.field(c, "founder_species_ref")) then
                hab = tonumber(world.field(pg, "habitability")) or hab
                break
            end
        end
        s.colonies[#s.colonies + 1] = {
            id = e.id, name = galaxy.name_block(world.field(e.planet, "name")), class = unquote(world.field(e.planet, "planet_class")),
            habitability = math.floor(hab * 100 + 1e-9),
            housing = tonumber(world.field(e.colony, "free_housing")) or 0,
            unemployed = tonumber(world.field(e.colony, "unemploy_pop")) or 0,
            jobs = { math.floor(a), math.floor(b) },
        }
    end
    -- the slaves the country could sell: its colonies' enslaved pop groups in order; the species
    -- in first-seen order (ListSpeciesWithSlavePops) with their pops and groups
    local seen = {}
    for _, e in ipairs(colonies) do
        local groups = {}
        for _, g in ipairs(world.list(world.field(e.colony, "pop_groups"))) do
            g = tonumber(g)
            local pg = g and world.object("pop_group", g)
            local sp_id = pg and tonumber(world.path(pg, "key", "species"))
            if sp_id and enslaved[sp_id] then
                local sp = world.object("species", sp_id)
                if not seen[sp_id] then
                    seen[sp_id] = { id = sp_id, name = sp and galaxy.name_block(world.field(sp, "name")), total = 0, groups = 0 }
                    s.species[#s.species + 1] = seen[sp_id]
                end
                local size = tonumber(world.field(pg, "size")) or 0
                seen[sp_id].total = seen[sp_id].total + size
                seen[sp_id].groups = seen[sp_id].groups + 1
                local amount = math.min(size - (on_market[g] or 0), 100)
                groups[#groups + 1] = {
                    group = g, species = sp_id, category = unquote(world.path(pg, "key", "category")), amount = amount,
                    price = sp and math.ceil(slave_price_per_pop(world, d, sp) * amount) or 0,
                }
            end
        end
        if #groups > 0 then
            -- the capital first, then the others in their order [I: the others by distance]
            local entry = { id = e.id, name = galaxy.name_block(world.field(e.planet, "name")), class = unquote(world.field(e.planet, "planet_class")), groups = groups }
            if e.id == capital then
                table.insert(s.pool, 1, entry)
            else
                s.pool[#s.pool + 1] = entry
            end
        end
    end
    -- CanSellSlaves: a colony with slaves and room on the market (SLAVE_MARKET_SIZE_CAP, 100)
    s.can_sell = #s.species > 0 and #s.on_market < 100
    return s
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

-- a planet class's icon (the class's `icon`: GFX_planet_type_<class without pc_> in the game's
-- files [I: read from the planet classes by the planner, assumed here])
local function class_icon(class)
    return "GFX_planet_type_" .. tostring(class or ""):gsub("^pc_", "")
end

-- a percentage coloured as the game's habitability (red under 40, yellow under 70, else green)
local function habitability_text(n)
    local c = n < 40 and "R" or n < 70 and "Y" or "G"
    return "§" .. c .. tostring(n) .. "%§!"
end

-- the Slave Market tab (CSlaveMarketView::Update): the slaves on the market sorted by species name
-- (stable), "No Slaves for sale..." without any, Sell Slaves enabled when the country has slaves
-- to sell and the market room; the destinations: the country's colonies, none selected until
-- one is clicked (a click selects it, again deselects)
function market.slave_tab(ctx, items, report, s, state, access)
    local names = require("render.names")
    local loc = ctx.loc
    local SM = V .. "/slave_market"
    local L = SM .. "/left_box"
    -- (laid out in the market window's report: its grids)
    local sel_colony = tonumber(state.colony)
    -- the market's slaves
    local list = {}
    for _, e in ipairs(s.on_market or {}) do
        local r = {}
        for k, v in pairs(e) do
            r[k] = v
        end
        r.name = e.species and names.format(loc, e.species) or ""
        list[#list + 1] = r
    end
    for i, r in ipairs(list) do
        r._i = i
    end
    table.sort(list, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a._i < b._i
    end)
    grid_entries(ctx, items, report, FILE, "slave_market_pop_entry", L .. "/slaves_for_sale/slave_list", list, function(r, p)
        local buy = r.seller and "CANCEL" or ("£trade£ " .. tostring(r.price))
        return {
            -- (the portrait not drawn: the species' portraits are not rendered here)
            hide = { [p .. "/portrait"] = true },
            text = {
                [p .. "/species"] = r.name, [p .. "/type"] = r.class or "",
                [p .. "/habitability"] = habitability_text(r.habitability or 0),
                [p .. "/buy_cancel"] = buy,
            },
            disabled = { [p .. "/buy_cancel"] = (not r.seller and (not sel_colony or not access)) or nil },
        }
    end)
    -- the destinations
    grid_entries(ctx, items, report, FILE, "slave_market_planet_entry", SM .. "/right_box/selectable_planets/planet_list", s.colonies or {}, function(cl, p)
        local a, b = cl.jobs[1], cl.jobs[2]
        local housing = math.floor(cl.housing + (cl.housing > 0 and 0.5 or -0.5))
        return {
            sprites = { [p .. "/planet_info/planet_class_icon"] = class_icon(cl.class) },
            text = {
                [p .. "/planet_info/name"] = cl.name and names.format(loc, cl.name) or "",
                [p .. "/planet_info/type"] = loc and loc.has(cl.class) and loc.get(cl.class) or cl.class,
                [p .. "/planet_info/habitability"] = habitability_text(cl.habitability or 0),
                [p .. "/planet_housing/planet_housing_amount"] = "§" .. (housing < 0 and "R" or housing == 0 and "Y" or "G") .. housing .. "§!",
                [p .. "/planet_unemployed/planet_unemployed_amount"] = "§" .. (cl.unemployed > 0 and "R" or "G") .. math.floor(cl.unemployed) .. "§!",
                [p .. "/planet_jobs/planet_jobs_amount"] = "§" .. (a >= b and "Y" or "W") .. a .. " / " .. b .. "§!",
            },
            hide = { [p .. "/selected_overlay"] = (cl.id ~= sel_colony) or nil },
            actions = { [p] = "view_set:colony=" .. (cl.id == sel_colony and "" or tostring(cl.id)) },
        }
    end)
end

-- the Sell Slaves window (CSlavePoolView), opened by Sell Slaves: the first species with slaves
-- (or the one chosen), its pops (SI_NUMBER, one decimal), its colonies' groups (the capital
-- first; collapsed until clicked) and their pops (at most 100 each, the price without the
-- country's modifier), disabled without the galactic market's access; the summary hidden and
-- Put on Market disabled while nothing is selected
function market.slave_pool(ctx, items, report, s, state, access)
    local names = require("render.names")
    local loc = ctx.loc
    local P = "/slave_pool_view"
    local species = (s.species or {})[1]
    for _, sp in ipairs(s.species or {}) do
        if tostring(sp.id) == state.pool_species then
            species = sp
        end
    end
    local texts, hide, actions, disabled = {}, {}, {}, {}
    actions[P .. "/close"] = "view_set:pool="
    if species then
        texts[P .. "/species_dropdown/selected_species"] = species.name and names.format(loc, species.name) or ""
        texts[P .. "/species_dropdown/slave_amount"] = market.stockpile(species.total)
    else
        hide[P .. "/species_dropdown/selected_species"] = true
        hide[P .. "/species_dropdown/slave_amount"] = true
        hide[P .. "/species_dropdown/slave_icon"] = true
    end
    hide[P .. "/summary_window/cost_summary"] = true
    disabled[P .. "/put_on_market"] = true
    local it, rp = gui.layout(ctx.game_dir, ctx.db, "interface/slave_pool_view.gui", "slave_pool_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, text = texts, hide = hide, actions = actions, disabled = disabled,
    })
    gui.merge(items, report, it, rp)
    local list = rp.rects[P .. "/slaves/planet_groups"]
    if not list or not species then
        return
    end
    -- the colony groups of the species, each 35 high, its pops under it when open (spacing 1,
    -- the inner list's 4 [V: the .gui's spacing])
    local y = list.y
    for gi, cg in ipairs(s.pool or {}) do
        local pops = {}
        for _, g in ipairs(cg.groups) do
            if g.species == species.id then
                pops[#pops + 1] = g
            end
        end
        if #pops > 0 then
            local open = state.pool_open == tostring(cg.id)
            local prefix = P .. "/slaves/planet_groups/" .. gi
            local p = prefix .. "/slave_pool_planet_group_entry"
            local ok, gi_items, grp = pcall(gui.layout, ctx.game_dir, ctx.db, "interface/slave_pool_view.gui", "slave_pool_planet_group_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
                sprites = { [p .. "/planet_class"] = class_icon(cg.class) },
                frames = { [p .. "/expand_icon"] = open and 2 or 1 },
                text = { [p .. "/planet_name"] = cg.name and names.format(loc, cg.name) or "" },
                actions = { [p .. "/background"] = "view_set:pool_open=" .. (open and "" or tostring(cg.id)) },
            })
            if ok then
                gui.merge(items, report, gi_items, grp)
            end
            y = y + 35 + 1
            if open then
                y = y + 4
                for k, g in ipairs(pops) do
                    local pp = prefix .. "/" .. k
                    local q = pp .. "/slave_pool_pop_entry"
                    local cat = "pop_cat_" .. g.category
                    local okp, pi, pr = pcall(gui.layout, ctx.game_dir, ctx.db, "interface/slave_pool_view.gui", "slave_pool_pop_entry", ctx.screen, {
                        texture_size = ctx.texture_size, loc = loc, prefix = pp, parent = { x = list.x, y = y, w = 0, h = 0 },
                        -- (the portrait, its planet background and building not drawn)
                        hide = {
                            [q .. "/selected_overlay"] = true, [q .. "/portrait/portrait"] = true,
                            [q .. "/portrait/pop_background"] = true, [q .. "/portrait/building_icon"] = true,
                            [q .. "/portrait/pop_mod"] = true, [q .. "/disabled_entry"] = access or nil,
                        },
                        frames = { [q .. "/portrait/pop_status"] = 2 },
                        text = {
                            [q .. "/portrait/amount"] = tostring(g.amount),
                            [q .. "/species"] = species.name and names.format(loc, species.name) or "",
                            [q .. "/category_name"] = loc and loc.has(cat) and loc.get(cat) or g.category,
                            [q .. "/estimated_price/price"] = "£trade£ " .. tostring(g.price),
                        },
                    })
                    if okp then
                        gui.merge(items, report, pi, pr)
                    end
                    y = y + 65 + 4
                end
            end
        end
    end
end


-- market.extract(game_dir): the player's market (views.rs: where the galaxy is read)
function market.extract(game_dir)
    return market.data(require("render.topbar").player(), game_dir)
end

-- market.build(ctx, data, state): the window (ctx: game_dir, db, screen, texture_size, loc)
function market.build(ctx, data, state)
    local game_dir, db, screen, texture_size, loc = ctx.game_dir, ctx.db, ctx.screen, ctx.texture_size, ctx.loc
    data = data or {}
    state = state or {}
    local slave = state.tab == "slave_market"
    local hide, texts, actions, sizes, disabled = {}, {}, {}, {}, {}
    actions[V .. "/close"] = "view_close"
    -- the tabs (CGameGraphics::UpdateTabVisibility: the active tab's _active button, the other's
    -- plain one; the slave market's only with Megacorp)
    hide[V .. (slave and "/tab_slave_market" or "/tab_market")] = true
    hide[V .. (slave and "/tab_market_active" or "/tab_slave_market_active")] = true
    if data.megacorp == false then
        hide[V .. "/tab_slave_market"] = true
        hide[V .. "/tab_slave_market_active"] = true
    end
    actions[V .. "/tab_market"] = "view_set:tab=market"
    -- (the slave market's tab takes clicks only with the galactic market's access:
    -- CMarketView::Update)
    if data.access then
        actions[V .. "/tab_slave_market"] = "view_set:tab=slave_market"
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
    -- the selected resource: the state's if the grid lists it, else the first (UpdateMarketTab)
    local selr
    for _, r in ipairs(data.resources or {}) do
        if r.key == state.resource then
            selr = r
        end
    end
    selr = selr or (data.resources or {})[1]
    local sel = selr and selr.key
    if sel then
        texts[M .. "/buy_box/unit_price_buy"] = text.format(loc, "RESOURCE_UNIT_PRICE", { KEY = sel, CURRENCY_KEY = cur, PRICE = "§Y" .. market.two(selr.unit_buy) .. "§!" })
        texts[M .. "/sell_box/unit_price_sell"] = text.format(loc, "RESOURCE_UNIT_PRICE", { KEY = sel, CURRENCY_KEY = cur, PRICE = "§Y" .. market.two(selr.unit_sell) .. "§!" })
        local name = text.format(loc, sel, {})
        texts[M .. "/total_bought_text"] = text.format(loc, "MARKET_TOTAL_BOUGHT", { RESOURCE = name, KEY = sel, VALUE = "§Y" .. math.floor(selr.bought or 0) .. "§!" })
        texts[M .. "/total_sold_text"] = text.format(loc, "MARKET_TOTAL_SOLD", { RESOURCE = name, KEY = sel, VALUE = "§Y" .. math.floor(selr.sold or 0) .. "§!" })
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

    -- the slave market tab's own (CSlaveMarketView::Update): "No Slaves for sale..." only without
    -- any, Sell Slaves enabled by CanSellSlaves (it opens the Sell Slaves window)
    local slaves = data.slaves or {}
    if #(slaves.on_market or {}) > 0 then
        hide[V .. "/slave_market/left_box/slaves_for_sale/no_slaves_for_sale"] = true
    end
    if slaves.can_sell then
        actions[V .. "/slave_market/left_box/sell_slaves"] = "view_set:pool=1"
    else
        disabled[V .. "/slave_market/left_box/sell_slaves"] = true
    end
    local items, report = gui.layout(game_dir, db, FILE, "market_view", screen, {
        texture_size = texture_size, loc = loc, hide = hide, text = texts, actions = actions, sizes = sizes, disabled = disabled,
    })
    if slave then
        market.slave_tab(ctx, items, report, data.slaves or {}, state, data.access)
        if state.pool == "1" then
            market.slave_pool(ctx, items, report, data.slaves or {}, state, data.access)
        end
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
                actions = { [p] = "view_set:resource=" .. r.key },
            }
        end)
    end
    -- the buy and sell grids: a market_trade_resource_grid_entry per TRADE_AMOUNT_MULTIPLIER,
    -- 75 x 88 apart, 3 a row: the resource's large icon, the amount, the price in the currency
    if sel then
        for _, side in ipairs({ { "buy_box/buy_resources_grid", selr.buy or {}, true }, { "sell_box/sell_resources_grid", selr.sell or {}, false } }) do
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
    if state.pool == "1" then
        market.slave_pool(ctx, items, report, data.slaves or {}, state, data.access)
    end
    return items, report
end

return market
