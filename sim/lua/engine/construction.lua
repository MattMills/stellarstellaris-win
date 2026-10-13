-- engine/construction.lua : construction queues, the way the game advances them each day (GOG
-- 4.5.2, CConstructionManager::DailyUpdate -> CConstructionQueueManager::DailyUpdate, per queue
-- CConstructionQueue::DailyUpdate, then CConstructionQueueItemManager::DailyUpdate finishing what is
-- done), on the save's stores:
--
--   construction.queue_mgr.queues: { items = { ids } owner location = { type id } simultaneous type
--                                    disabled }
--   construction.item_mgr.items:   { queue paying_country progress progress_needed resources
--                                    buildable_<kind> = { ... } }
--
-- Each day, a queue that is not disabled advances its first `simultaneous` items, from the last of
-- them to the first: progress += the buildable's speed (CBuildable*::CalcProgressionSpeed); an item
-- that reaches progress_needed is done: taken out of its queue and finished (OnFinished).
--
-- Speeds (the colony's modifier node of the planet the item is on):
--   district  1 + planet_building_build_speed_mult + planet_<district>_build_speed_mult
--             (CDistrictType::CalcBuildSpeed)
--   zone      1 + planet_building_build_speed_mult + planet_<zone>_build_speed_mult (CZoneType)
--   building  1 + planet_building_build_speed_mult + planet_<building>_build_speed_mult (CBuildingType)
--   army      1 + planet_army_build_speed_mult (CBuildableArmy)
-- Ships, starbase upgrades, modules and buildings, defense platforms, decisions, deposit blockers:
-- not modelled yet (their items stay as they are, counted).
--
-- Finished: a district's level + 1; a zone created in its district's slot; a building created and
-- added to its zone (new ids: the next index of the store, as the game's databases give them).
-- Not modelled yet: armies created, the on_actions of completion, the refunds of aborted items.

local world = require("engine.world")

local construction = {
    stats = { advanced = 0, finished = 0, not_modelled = {}, finish_not_modelled = {} },
    finished = {}, -- { kind, planet, date }
    failures = {}, -- what could not be finished, and why
}

local QUEUES, ITEMS = "construction.queue_mgr.queues", "construction.item_mgr.items"

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers(kind, id) or {}
end

-- the colony modifier node of an item (a buildable's `planet` is a colony id in 4.5, like a pop
-- group's and a capital)
local function colony_mods(colony)
    return modifiers("colony", colony or -1)
end

local function buildable(item)
    for _, e in ipairs(item) do
        if e.op and e.key and e.value.text == nil and e.key.text:sub(1, 10) == "buildable_" then
            return e.key.text:sub(11), e.value
        end
    end
end

-- construction.speed(item) -> the daily progress, or nil (a kind not modelled)
function construction.speed(item)
    local kind, b = buildable(item)
    if not kind then
        return nil
    end
    local planet = tonumber(world.field(b, "planet"))
    if kind == "district" or kind == "zone" or kind == "planet_building" or kind == "planet_upgrade_building" then
        local key = world.field(b, (kind == "planet_building" or kind == "planet_upgrade_building") and "building" or kind)
        local M = colony_mods(planet)
        return 1 + (M.planet_building_build_speed_mult or 0) + (M["planet_" .. tostring(key) .. "_build_speed_mult"] or 0), kind
    elseif kind == "army" then
        local M = colony_mods(planet)
        return 1 + (M.planet_army_build_speed_mult or 0), kind
    end
    return nil, kind
end

-- the next id of a store: one index past the highest in use (generation 0)
local function next_id(store)
    local max = -1
    for _, id in ipairs(world.all(store)) do
        local index = id % 16777216
        if index > max then
            max = index
        end
    end
    return max + 1
end

local function finish(item, kind, b, date)
    local planet = tonumber(world.field(b, "planet"))
    if kind == "district" then
        -- the colony's district of that type
        local want = world.field(b, "district")
        local colony = planet
        local c = colony and world.object("colony", colony)
        if not c then
            return false, "district: no colony " .. tostring(colony)
        end
        for _, did in ipairs(world.list(world.field(c, "districts"))) do
            local d = world.object("districts", tonumber(did))
            if d and world.field(d, "type") == want then
                world.set(d, "level", (tonumber(world.field(d, "level")) or 0) + 1)
                return true
            end
        end
        return false, "district: colony " .. tostring(colony) .. " has no " .. tostring(want)
    elseif kind == "planet_upgrade_building" then
        -- the building becomes the upgrade (upgrade_building: the building's id)
        local bl = world.object("buildings", tonumber(world.field(b, "upgrade_building")))
        if not bl then
            return false, "upgrade: no building " .. tostring(world.field(b, "upgrade_building"))
        end
        world.set(bl, "type", world.field(b, "building"))
        return true
    elseif kind == "zone" then
        local d = world.object("districts", tonumber(world.field(b, "district")))
        local slot = tonumber(world.field(b, "zone_slot"))
        local zones = d and world.field(d, "zones")
        local values = {}
        for _, e in ipairs(type(zones) == "table" and zones or {}) do
            if e.text then values[#values + 1] = e end
        end
        if not (slot and values[slot + 1]) then
            return false
        end
        local id = next_id("zones")
        local z = {}
        world.append(z, "type", world.field(b, "zone"), true)
        world.append(z, "buildings", {})
        world.create("zones", id, z)
        values[slot + 1].text = tostring(id)
        return true
    elseif kind == "planet_building" then
        local z = world.object("zones", tonumber(world.field(b, "zone")))
        if not z then
            return false
        end
        local id = next_id("buildings")
        local bl = {}
        world.append(bl, "type", world.field(b, "building"), true)
        world.append(bl, "position", #world.list(world.field(z, "buildings")))
        world.create("buildings", id, bl)
        world.append_value(world.child(z, "buildings"), id)
        return true
    end
    return nil
end

-- construction.daily(date): every queue's day
function construction.daily(date)
    local items = world.stores[ITEMS]
    local queues = world.stores[QUEUES]
    if not items or not queues then
        return
    end
    local today = date and date.year and string.format("%d.%02d.%02d", date.year, date.month, date.day) or nil
    local done = {}
    for _, qid in ipairs(world.all(QUEUES)) do
        local q = queues[qid]
        if q and world.field(q, "disabled") ~= "yes" then
            local list = world.field(q, "items")
            local ids = world.list(list)
            local n = math.min(#ids, tonumber(world.field(q, "simultaneous")) or 1)
            for i = n, 1, -1 do
                local iid = tonumber(ids[i])
                local item = iid and items[iid]
                if item then
                    local speed, kind = construction.speed(item)
                    if speed then
                        local progress = (tonumber(world.field(item, "progress")) or 0) + speed
                        world.set(item, "progress", math.floor(progress * 100000 + 0.5) / 100000)
                        construction.stats.advanced = construction.stats.advanced + 1
                        if progress >= (tonumber(world.field(item, "progress_needed")) or math.huge) then
                            world.remove_value(list, iid)
                            done[#done + 1] = iid
                        end
                    else
                        kind = kind or "?"
                        construction.stats.not_modelled[kind] = (construction.stats.not_modelled[kind] or 0) + 1
                    end
                end
            end
        end
    end
    -- CConstructionQueueItemManager::DailyUpdate: the finished items
    for _, iid in ipairs(done) do
        local item = items[iid]
        local kind, b = buildable(item)
        local ok, why = finish(item, kind, b, today)
        if ok then
            construction.stats.finished = construction.stats.finished + 1
            construction.finished[#construction.finished + 1] = { kind = kind, planet = world.field(b, "planet"), date = today }
        else
            construction.stats.finish_not_modelled[kind] = (construction.stats.finish_not_modelled[kind] or 0) + 1
            construction.failures[#construction.failures + 1] = string.format("%s %s: %s", tostring(today), kind, why or "not modelled")
        end
        world.remove(ITEMS, iid)
    end
end

local function list(t)
    local out = {}
    for k, v in pairs(t) do
        out[#out + 1] = k .. " " .. v
    end
    table.sort(out)
    return table.concat(out, ", ")
end

function construction.report()
    local s = construction.stats
    return string.format("construction: %d item-days advanced, %d finished; not modelled: item-days of %s; finishing of %s",
        s.advanced, s.finished, list(s.not_modelled), list(s.finish_not_modelled))
end

return construction
