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

-- the world in the store (STELLAR_WORLD=store): nothing is published. An object is found in its
-- store's own block (`country = { <id> = { ... } }`) through that block's key index, and the ids
-- are that block's keys, in the save's order: the world's data, read in place by any state.
local S = require("engine.store.core")
local IN_STORE = os.getenv("STELLAR_WORLD") == "store"
local holders            -- store name -> its block id, found once per state from the world's root
local KIDS = {}          -- an id -> its key's string id (this state's cache of the interned key)
local function holder(name)
    if holders == nil then
        holders = {}
        require("engine.store.world").find_stores(S.H.roots[0], function(n, bid) holders[n] = bid end)
    end
    return holders[name]
end
local function store_get(name, id)
    local h = holder(name)
    if not h then return nil end
    local k = KIDS[id]
    if k == nil then
        k = S.kid(tostring(id)) or false
        KIDS[id] = k
    end
    if not k then return nil end
    local i = S.find(h, k)
    if not i then return nil end
    local e = S.E[i]
    if e.kind == S.BLOCK then return e.v.u.a end
    return nil
end
local IDS = {}           -- store name -> the ids, read from its block (per refresh)
local function store_ids(name)
    local l = IDS[name]
    if l then return l end
    l = {}
    local h = holder(name)
    if h then
        local b = S.B[h]
        for i = b.first, b.first + b.count - 1 do
            local e = S.E[i]
            if e.op ~= 0 and e.kind == S.BLOCK then l[#l + 1] = tonumber(S.str(e.key)) end
        end
    end
    IDS[name] = l
    return l
end
if IN_STORE then
    function O.get(name, id) return store_get(name, id) end
    function O.ids(name) return store_ids(name) end
    function O.refresh() IDS = {} end
    function O.publish() end
end

return O
