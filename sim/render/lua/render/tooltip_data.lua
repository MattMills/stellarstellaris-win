-- render/tooltip_data.lua : what the tooltips need of the world (docs/tooltips.md), read on the
-- simulation's thread with the outliner's view (render.windows.outliner extract: view.tips) and
-- formatted on the render thread by render.tooltip.
--
--   tips = require("render.tooltip_data").extract(game_dir, { player = id, country = obj })
--   tips.economy[res] = { stock, max, balance, trade, income = { { cat, value } }, expenses = ... }
--   tips.research[area] = monthly balance
--   tips.fleets[id] = { name, owner, civilian, power, hp, max_hp, lead = SHIP, sizes = { { size, n } } }
--   tips.ships[id] = { name, size, class, design, owner, hp, max_hp, armor, max_armor, shields,
--                      max_shields }
--   tips.colonies[planet] = { pops, species }
--   tips.counters = { empire_size, starbases, starbase_cap, navy, navy_cap }

local M = {}

local NONE = 4294967295

local function field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function unquote(v)
    return v ~= nil and (tostring(v):gsub('"', "")) or nil
end

-- the game's files: the economic categories (CEconomicCategoryDatabase: files in name order, the
-- categories in file order; each category's row is its level-0 ancestor: the visible one with
-- no visible ancestor, CEconomicCategory::UpdateLevel), the resources' max, the ship sizes'
-- classes
local game_cache = {}
local function game_data(game_dir)
    local d = game_cache[game_dir]
    if d then
        return d
    end
    local source = require("stellar.script.source")
    d = { categories = {}, order = {}, max = {}, class = {} }
    for _, rel in ipairs(source.files(game_dir, "common/economic_categories", "txt")) do
        for _, e in ipairs(source.parse(game_dir, rel) or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                local name = e.key.text
                if not d.categories[name] then
                    d.order[#d.order + 1] = name
                end
                d.categories[name] = { parent = unquote(field(e.value, "parent")), hidden = field(e.value, "hidden") == "yes" }
            end
        end
    end
    local cats = d.categories
    local function level(c)
        local cat = cats[c]
        if not cat then
            return 255
        end
        if cat.hidden then
            return 255
        end
        local l, p = 0, cat.parent
        local guard = 0
        while p and cats[p] and guard < 64 do
            if not cats[p].hidden then
                l = l + 1
            end
            p = cats[p].parent
            guard = guard + 1
        end
        return l
    end
    d.row = {}
    for _, c in ipairs(d.order) do
        local x, guard = c, 0
        while x and level(x) ~= 0 and guard < 64 do
            x = cats[x] and cats[x].parent
            guard = guard + 1
        end
        d.row[c] = x
    end
    d.rows = {}
    for _, c in ipairs(d.order) do
        if level(c) == 0 then
            d.rows[#d.rows + 1] = c
        end
    end
    for name, def in pairs(source.definitions(game_dir, "common/strategic_resources") or {}) do
        d.max[name] = tonumber(field(def.block, "max"))
    end
    for name, def in pairs(source.definitions(game_dir, "common/ship_sizes") or {}) do
        d.class[name] = unquote(field(def.block, "class"))
    end
    game_cache[game_dir] = d
    return d
end

-- a budget block (`{ category = { resource = value } }`) by resource, its leaf categories summed
-- into their rows (level-0 ancestors), in the categories' order
local function by_rows(world, d, block)
    local sums = {}
    for cat, v in world.statements(block or {}) do
        local row = d.row[cat] or "ECONOMICS_CATEGORY_NONE"
        if type(v) == "table" then
            for res, amount in world.statements(v) do
                local n = tonumber(amount)
                if n then
                    sums[res] = sums[res] or {}
                    sums[res][row] = (sums[res][row] or 0) + n
                end
            end
        end
    end
    local out = {}
    for res, rows in pairs(sums) do
        local list = {}
        if rows.ECONOMICS_CATEGORY_NONE then
            list[#list + 1] = { cat = "ECONOMICS_CATEGORY_NONE", value = rows.ECONOMICS_CATEGORY_NONE }
        end
        for _, c in ipairs(d.rows) do
            if rows[c] and rows[c] ~= 0 then
                list[#list + 1] = { cat = c, value = rows[c] }
            end
        end
        out[res] = list
    end
    return out
end

local function total(list)
    local t = 0
    for _, r in ipairs(list or {}) do
        t = t + r.value
    end
    return t
end

function M.extract(game_dir, ctx)
    local world = require("engine.world")
    local galaxy = require("render.galaxy")
    local d = game_data(game_dir)
    local pc = ctx.country
    local tips = { economy = {}, research = {}, fleets = {}, ships = {}, colonies = {}, counters = {} }
    local country_names = {}
    local function country_name(cid)
        if cid == nil then
            return nil
        end
        if country_names[cid] == nil then
            local c = world.object("country", cid)
            country_names[cid] = c and galaxy.name_block(world.field(c, "name")) or false
        end
        return country_names[cid] or nil
    end

    if pc then
        -- the economy: the stockpile, the month's balance, income and expenses by row, trade
        local month = world.path(pc, "budget", "current_month")
        local income = by_rows(world, d, month and world.field(month, "income"))
        local expenses = by_rows(world, d, month and world.field(month, "expenses"))
        local balance = {}
        for _, v in world.statements(month and world.field(month, "balance") or {}) do
            if type(v) == "table" then
                for res, amount in world.statements(v) do
                    balance[res] = (balance[res] or 0) + (tonumber(amount) or 0)
                end
            end
        end
        local trade = {}
        for _, v in world.statements(month and world.field(month, "trade_balance") or {}) do
            if type(v) == "table" then
                for res, amount in world.statements(v) do
                    trade[res] = (trade[res] or 0) + (tonumber(amount) or 0)
                end
            elseif tonumber(v) then
                trade[_] = (trade[_] or 0) + tonumber(v)
            end
        end
        local stock = world.path(pc, "modules", "standard_economy_module", "resources")
        for _, res in ipairs({ "energy", "minerals", "food", "consumer_goods", "alloys", "trade", "influence", "unity" }) do
            tips.economy[res] = {
                stock = tonumber(stock and world.field(stock, res)) or 0, max = d.max[res],
                balance = balance[res] or 0, trade = trade[res] or 0,
                income = income[res] or {}, expenses = expenses[res] or {},
                produced = total(income[res]), consumed = total(expenses[res]),
            }
        end
        for _, area in ipairs({ "physics_research", "society_research", "engineering_research" }) do
            tips.research[area] = balance[area] or 0
        end
        tips.counters = {
            empire_size = tonumber(world.field(pc, "empire_size")) or 0,
            starbases = tonumber(world.field(pc, "starbase_capacity_used")) or 0,
            starbase_cap = tonumber(world.field(pc, "starbase_capacity")) or 0,
            navy = tonumber(world.field(pc, "used_naval_capacity")) or 0,
            navy_cap = tonumber(world.field(pc, "fleet_size")) or 0,
        }
        -- the player's colonies: pops and the dominant species (CColony::GetToolTip)
        if not world.colony_planet and world.index then
            world.index()
        end
        for _, c in ipairs(world.list(world.field(pc, "owned_planets"))) do
            local col = world.object("colony", tonumber(c))
            local pid = world.colony_planet and world.colony_planet[tonumber(c)]
            if col and pid then
                local best, best_n = nil, -1
                for sid, info in world.statements(world.field(col, "species_information") or {}) do
                    local n = type(info) == "table" and tonumber(world.field(info, "num_pops")) or 0
                    if n > best_n then
                        best, best_n = tonumber(sid), n
                    end
                end
                local sp = best and world.object("species", best)
                tips.colonies[pid] = {
                    pops = tonumber(world.field(col, "num_sapient_pops")) or 0,
                    species = sp and galaxy.name_block(world.field(sp, "name")) or nil,
                }
            end
        end
    end

    -- the player's name (a colony's owner line)
    tips.player_name = country_name(ctx.player)

    -- the systems (CGalacticObject::GetToolTip): name, the owner, the star class
    tips.systems = {}
    for _, sid in ipairs(world.all("system")) do
        local s = world.object("system", sid)
        if s then
            local owner = world.system_owner and world.system_owner[sid]
            tips.systems[sid] = {
                name = galaxy.name_block(world.field(s, "name")), owner = country_name(owner),
                star = unquote(world.field(s, "star_class")),
                type = owner == nil and "sys_unclaimed" or nil,
            }
        end
    end

    -- the ships and fleets (CShip::GetToolTip, CFleet::GetToolTip)
    local fleet_owner = world.fleet_owner or {}
    local function ship_info(sid, owner)
        local s = world.object("ship", sid)
        if not s then
            return nil
        end
        local impl = world.field(s, "ship_design_implementation")
        local did = impl and tonumber(world.field(impl, "design"))
        local design = did and world.object("ship_design", did)
        local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
        local size = stage and unquote(world.field(stage, "ship_size")) or ""
        return {
            name = galaxy.name_block(world.field(s, "name")), size = size, class = d.class[size] or "",
            design = design and galaxy.name_block(world.field(design, "name")) or nil, owner = country_name(owner),
            hp = tonumber(world.field(s, "hitpoints")) or 0, max_hp = tonumber(world.field(s, "max_hitpoints")) or 0,
            armor = tonumber(world.field(s, "armor_hitpoints")) or 0, max_armor = tonumber(world.field(s, "max_armor_hitpoints")) or 0,
            shields = tonumber(world.field(s, "shield_hitpoints")) or 0, max_shields = tonumber(world.field(s, "max_shield_hitpoints")) or 0,
        }
    end
    for _, fid in ipairs(world.all("fleet")) do
        local f = world.object("fleet", fid)
        local owner = fleet_owner[fid]
        local ships = f and world.list(world.field(f, "ships")) or {}
        if f and #ships > 0 then
            local sizes, order = {}, {}
            local lead, lead_rank
            local hp, max_hp = 0, 0
            for _, sid in ipairs(ships) do
                local info = ship_info(tonumber(sid), owner)
                if info then
                    tips.ships[tonumber(sid)] = info
                    hp, max_hp = hp + info.hp, max_hp + info.max_hp
                    if not sizes[info.size] then
                        sizes[info.size] = 0
                        order[#order + 1] = info.size
                    end
                    sizes[info.size] = sizes[info.size] + 1
                    -- the lead ship: the largest size's first (its maximum hull points stand for the
                    -- size's rank [I])
                    if not lead or info.max_hp > lead_rank then
                        lead, lead_rank = info, info.max_hp
                    end
                end
            end
            local comp = {}
            for _, s in ipairs(order) do
                comp[#comp + 1] = { size = s, n = sizes[s] }
            end
            local power = tonumber(world.field(f, "military_power")) or 0
            tips.fleets[fid] = {
                name = galaxy.name_block(world.field(f, "name")), owner = country_name(owner),
                civilian = world.field(f, "ship_class") ~= "shipclass_military" and power <= 0,
                station = world.path(f, "properties", "station") == "yes",
                power = power, hp = hp, max_hp = max_hp, lead = lead, sizes = comp,
            }
        end
    end
    return tips
end

return M
