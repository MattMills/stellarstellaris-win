-- engine/ai/economy/orders.lua : a construction order in the save's form, what the game does when
-- the AI's CAddBuildableToQueueCommand executes (docs/ai_economy.md section 5):
--
--   CAddBuildableToQueueCommand::ExecuteLocal (0xaca340) -> CConstructionQueue::AddItemInternal
--   (0x7b7c30): CConstructionQueueItemManager::CreateItem (0x8fc1a0) takes the item database's
--   first free slot (generation + 1); the item is appended to the queue's items;
--   CConstructionQueueItem::TakeResources (0x7b8760) takes the cost from the paying country's
--   stockpile (CEconomyCountryModule::RemoveResources) and keeps it as the item's `resources`;
--   progress_needed = the buildable's build time (vfunc +88).
--
-- Item ids: index | generation << 24. The free slots are the save's `id = none` entries; the game's
-- 2210.01.01 -> 2210.07.01 saves fit a free list built in ascending index order at load, with a
-- freed slot pushed in front (a slot is taken again with its generation + 1).
--
--   local orders = require("engine.ai.economy.orders")
--   orders.add{ country, colony, queue, kind = "district"|"planet_building"|"zone"|"planet_upgrade_building",
--               fields = { {key, value, quoted} ... }, cost = { res = v }, build_time = n } -> item id

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local fp = require("engine.ai.economy.fixed")

local orders = { stats = { added = 0, paid = {} } }

local ITEMS, QUEUES = "construction.item_mgr.items", "construction.queue_mgr.queues"
local GEN = 16777216

-- the free list: slot indices, the next one first
local free, gen_of, live
local function init_free()
    if free then
        return
    end
    free, gen_of, live = {}, {}, {}
    local holder = world.store_blocks[ITEMS]
    for _, e in ipairs(holder or {}) do
        slice.tick("ai/economy/orders.lua:35")
        if e.op and e.key then
            local id = tonumber(e.key.text)
            if id then
                local index = id % GEN
                gen_of[index] = math.floor(id / GEN)
                if e.value.text == "none" then
                    free[#free + 1] = index
                else
                    live[id] = true
                end
            end
        end
    end
    table.sort(free)
end

-- slots freed since the last look (engine.construction removes finished items): pushed in front
local function collect_freed()
    local store = world.stores[ITEMS] or {}
    local gone = {}
    for id in pairs(live) do
        slice.tick("ai/economy/orders.lua:56")
        if store[id] == nil then
            gone[#gone + 1] = id
        end
    end
    table.sort(gone)
    for _, id in ipairs(gone) do
        slice.tick("ai/economy/orders.lua:62")
        live[id] = nil
        local index = id % GEN
        gen_of[index] = math.floor(id / GEN)
        table.insert(free, 1, index)
    end
    -- items others created (not through here) are live too
    for id in pairs(store) do
        slice.tick("ai/economy/orders.lua:69")
        if not live[id] then
            live[id] = true
        end
    end
end

-- the next item id, and the tree entry of its slot when the slot is reused (an `id = none` entry)
local function allocate()
    init_free()
    collect_freed()
    local index = table.remove(free, 1)
    if index == nil then
        -- no free slot: past the highest index (TPdxRefDatabase::ReserveLookup)
        local max = -1
        for i in pairs(gen_of) do
            slice.tick("ai/economy/orders.lua:84")
            if i > max then max = i end
        end
        index = max + 1
        gen_of[index] = -1
    end
    local old = (gen_of[index] or -1)
    local g = old + 1
    gen_of[index] = g
    local id = index + g * GEN
    local entry
    if old >= 0 then
        entry = index + old * GEN   -- the freed slot's id (`<id> = none`)
    end
    return id, entry
end

-- an item block in the store: a reused slot keeps its place in the save (`old = none` becomes the
-- new id), a new slot goes at the end
local function store_item(id, entry, block)
    local b = world.place(ITEMS, id, entry, block, GEN)
    live[id] = true
    return b
end

-- the stockpile of a country (nil for one without the economy module)
local function stock_block(country)
    local c = world.object("country", country)
    local module = world.path(c, "modules", "standard_economy_module")
    return type(module) == "table" and world.child(module, "resources") or nil
end

-- orders.can_pay(country, cost) -> whether the stockpile holds the cost
function orders.can_pay(country, cost)
    local stock = stock_block(country)
    if not stock then
        return false
    end
    for r, v in pairs(cost or {}) do
        slice.tick("ai/economy/orders.lua:122")
        if v > 0 and (tonumber(world.field(stock, r)) or 0) < v then
            return false
        end
    end
    return true
end

-- orders.add(o) -> item id | nil, why
function orders.add(o)
    local q = world.object(QUEUES, o.queue)
    if not q then
        return nil, "no queue " .. tostring(o.queue)
    end
    local stock = stock_block(o.country)
    local id, entry = allocate()
    local item = {}
    world.append(item, "queue", o.queue)
    world.append(item, "paying_country", o.country)
    world.append(item, "progress", 0)
    world.append(item, "progress_needed", o.build_time or 0)
    local res = {}
    for _, r in ipairs(o.cost_order or {}) do
        slice.tick("ai/economy/orders.lua:144")
        if o.cost[r] and o.cost[r] ~= 0 then
            world.append(res, r, fp.to(fp.from(o.cost[r])))
        end
    end
    world.append(item, "resources", res)
    local b = {}
    for _, f in ipairs(o.fields) do
        slice.tick("ai/economy/orders.lua:151")
        world.append(b, f[1], f[2], f[3])
    end
    world.append(item, "buildable_" .. o.kind, b)
    store_item(id, entry, item)
    -- the queue's items (written first in the queue's block, as the game does)
    local items = world.field(q, "items")
    if type(items) ~= "table" then
        items = {}
        world.insert(q, 1, "items", items)
    end
    world.append_value(items, id)
    -- TakeResources: the cost from the paying country's stockpile
    if stock then
        for r, v in pairs(o.cost or {}) do
            slice.tick("ai/economy/orders.lua:165")
            if v ~= 0 then
                local now = fp.from(tonumber(world.field(stock, r)) or 0)
                world.set(stock, r, fp.to(now - fp.from(v)))
                orders.stats.paid[r] = (orders.stats.paid[r] or 0) + v
            end
        end
    end
    orders.stats.added = orders.stats.added + 1
    return id
end

function orders.report()
    local parts = {}
    for r, v in pairs(orders.stats.paid) do
        slice.tick("ai/economy/orders.lua:179")
        parts[#parts + 1] = string.format("%s %.0f", r, v)
    end
    table.sort(parts)
    return string.format("ai orders: %d items queued, paid %s", orders.stats.added, table.concat(parts, ", "))
end

return orders
