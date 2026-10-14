-- engine/store/objects.lua : the object tables (docs/data_layer.md, "Typed arrays and object
-- tables"): for each store of the world (country, fleet, ships, ...), the block of every object by
-- id and the ids in the save's order, as typed arrays of the store. They are what the game's
-- object databases are (an array by id): any Lua state finds an object without a Lua table of
-- handles. The main thread publishes them (O.publish); readers look the arrays up once per phase
-- (O.refresh).
--
-- `obj:<name>` is an id map (engine.store.arrays: a dense array by id, or the ids sorted when they
-- are sparse, as some databases number from high bits), the block ids its values (0 none);
-- `ids:<name>` is the ids in the save's order.
--
--   local O = require("engine.store.objects")
--   O.refresh()
--   local bid = O.get("fleet", 12)          -- the fleet's block, or nil
--   for _, id in ipairs(O.ids("country")) do ... end

local A = require("engine.store.arrays")

local O = {}

local P = {}     -- name -> { get = id -> block id, ids = Lua array }

local function load(name)
    local ip, m = A.ptr("ids:" .. name, "double")
    local ids = {}
    for i = 0, (m or 0) - 1 do ids[i + 1] = ip[i] end
    local t = { get = A.map("obj:" .. name), ids = ids }
    P[name] = t
    return t
end

-- O.refresh(): the tables looked up again (a reader, at the start of each phase)
function O.refresh()
    P = {}
end

-- O.get(name, id) -> the object's block id, or nil
function O.get(name, id)
    local t = P[name] or load(name)
    return t.get(id)
end

-- O.ids(name) -> the ids, in the save's order (a Lua array; do not change it)
function O.ids(name)
    local t = P[name] or load(name)
    return t.ids
end

-- O.publish(name, ids, bids): the table of one store (main thread): ids in order, bids[id]
function O.publish(name, ids, bids)
    local map = {}
    for _, id in ipairs(ids) do map[id] = bids[id] end
    A.publish_map("obj:" .. name, map, "double", 0)
    local ip = A.make("ids:" .. name, "double", #ids)
    for i, id in ipairs(ids) do ip[i - 1] = id end
    P[name] = nil
end

-- O.publish_world(W): every store of a store world (engine.store.world)
function O.publish_world(W)
    for name, ids in pairs(W.ids) do
        O.publish(name, ids, W.bids[name])
    end
end

return O
