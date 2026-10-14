-- engine/store/world.lua : engine.world's API over the shared store (docs/data_layer.md,
-- "The world API over the store"): the same functions and signatures, the save's tree held in the
-- store instead of Lua tables.
--
-- A block is a handle: a `pdx_block *` cdata pointing at the block's record (world.field returns
-- one for a block value; type(v) == "cdata", see W.is_block). Handles compare with ==; as table
-- keys use W.bid(h) (two handles of one block are two cdata objects). Tokens are returned as
-- engine.world returns them: world.field a number when the text reads as one, else the text;
-- world.fields / world.list the texts.
--
-- Values given to the writers are numbers, texts or handles. A Lua table given as a block
-- (world.append(obj, key, {}) as engine.world takes it) is copied into the store; the copy's
-- handle is returned, and the table itself is not the world's (code that fills a block after
-- appending it must use the handle).
--
--   local W = require("engine.store.world")
--   W.load(gamestate_text)             -- or W.attach_root(bid) over a store already built
--   W.field(W.object("country", 0), "capital")

local ffi = require("ffi")
local S = require("engine.store.core")
local pdxscript = require("pdxscript")

local W = {
    stores = {}, ids = {}, entries = {}, store_blocks = {}, meta = {}, bids = {}, seconds = 0,
}

W.KINDS = {
    country = "country", planet = "planet", pop_group = "pop_groups", leader = "leaders",
    fleet = "fleet", ship = "ships", system = "galactic_object", species = "species_db",
    army = "army", starbase = "starbases", federation = "federation", war = "war",
    deposit = "deposit", pop_job = "pop_jobs", megastructure = "megastructures", sector = "sectors",
    situation = "situations", first_contact = "contacts",
}

local E, B
local block_ptr = ffi.typeof("pdx_block *")
local function attach()
    S.attach()
    E, B = S.E, S.B
end

local function handle(bid)
    return B + bid
end
local function bid_of(h)
    return tonumber(h - B)
end
W.handle, W.bid = handle, bid_of
function W.is_block(v)
    return type(v) == "cdata" and ffi.istype(block_ptr, v)
end

local TEXT, NUMBER, BLOCK = S.TEXT, S.NUMBER, S.BLOCK
local token, text, find, find_next, kid, sid = S.token, S.text, S.find, S.find_next, S.kid, S.id

-- the value of entry i: a token's (number or text), or a block's handle
local function value(i)
    local e = E[i]
    if e.kind == BLOCK then return B + e.v.u.a end
    return token(i)
end

local function is_id(t)
    return t and t:match("^%d+$") ~= nil
end

-- a store block whose entries are all `<id> = { ... }` or `<id> = none`
local function is_store(bid)
    local b = B[bid]
    if b.count == 0 then return false end
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        if e.op == 0 or not is_id(S.str(e.key)) then return false end
    end
    return true
end

local function add_store(name, bid)
    local store, ids, entries = W.stores[name] or {}, W.ids[name] or {}, W.entries[name] or {}
    local bids = W.bids[name] or {}
    local b = B[bid]
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        if e.kind == BLOCK then
            local id = tonumber(S.str(e.key))
            store[id] = B + e.v.u.a
            bids[id] = e.v.u.a
            entries[id] = i
            ids[#ids + 1] = id
        end
    end
    W.stores[name], W.ids[name], W.entries[name], W.bids[name] = store, ids, entries, bids
    W.store_blocks[name] = bid
end

-- W.find_stores(root, visit) over a store tree, as engine.world.find_stores over a Lua tree;
-- returns the top-level entries (their indexes) that held no store
function W.find_stores(root, visit)
    local plain = {}
    local function walk(bid, path, key, depth)
        if is_store(bid) then
            visit(depth <= 2 and key or path, bid)
            return true
        end
        if depth >= 3 then return false end
        local any = false
        local b = B[bid]
        for i = b.first, b.first + b.count - 1 do
            local e = E[i]
            if e.op ~= 0 and e.kind == BLOCK then
                local k = S.str(e.key)
                any = walk(e.v.u.a, path .. "." .. k, k, depth + 1) or any
            end
        end
        return any
    end
    local b = B[root]
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        if e.op ~= 0 then
            local key = S.str(e.key)
            if e.kind ~= BLOCK or not walk(e.v.u.a, key, key, 1) then
                plain[#plain + 1] = i
            end
        end
    end
    return plain
end

-- W.attach_root(bid): the world over a store tree already built (a worker's, or after W.build)
function W.attach_root(root)
    attach()
    W.root = root
    W.stores, W.ids, W.entries, W.store_blocks, W.meta, W.bids = {}, {}, {}, {}, {}, {}
    for _, i in ipairs(W.find_stores(root, add_store)) do
        W.meta[S.str(E[i].key)] = value(i)
    end
    return W
end

-- W.build(tree) -> root: a pdxscript tree (engine.world.tree) into the store, as the world
function W.build(tree)
    attach()
    local t0 = RUST.clock()
    local root = S.build(tree)
    S.H.roots[0] = root
    W.attach_root(root)
    W.seconds = RUST.clock() - t0
    return root
end

-- W.load(text) -> true | nil, message: a gamestate parsed into the store (the Lua tree dropped)
function W.load(text_)
    local tree, message = pdxscript.parse(text_, "gamestate")
    if not tree then return nil, message end
    W.build(tree)
    W.index()
    return true
end

-- ---------------------------------------------------------------------------------------------
-- reads

function W.field(obj, key)
    if obj == nil then return nil end
    local k = kid(key)
    if not k then return nil end
    local i = find(bid_of(obj), k)
    if not i then return nil end
    return value(i)
end

function W.fields(obj, key)
    local out = {}
    if obj == nil then return out end
    local k = kid(key)
    if not k then return out end
    local bid = bid_of(obj)
    local i = find(bid, k)
    local n = 0
    while i do
        n = n + 1
        local e = E[i]
        out[n] = e.kind == BLOCK and (B + e.v.u.a) or text(i)
        i = find_next(bid, k, i)
    end
    return out
end

-- the bare values of a list block, as text
function W.list(block)
    local out, n = {}, 0
    if W.is_block(block) then
        local b = block
        for i = b.first, b.first + b.count - 1 do
            local e = E[i]
            if e.op == 0 and (e.kind == TEXT or e.kind == NUMBER) then
                n = n + 1
                out[n] = text(i)
            end
        end
    end
    return out
end

-- the blocks of a list block
function W.blocks(block)
    local out, n = {}, 0
    if W.is_block(block) then
        local b = block
        for i = b.first, b.first + b.count - 1 do
            local e = E[i]
            if e.op == 0 and e.kind == BLOCK then
                n = n + 1
                out[n] = B + e.v.u.a
            end
        end
    end
    return out
end

function W.path(obj, ...)
    local v = obj
    for _, k in ipairs({ ... }) do
        if not W.is_block(v) then return nil end
        v = W.field(v, k)
    end
    return v
end

function W.object(kind, id)
    local store = W.stores[W.KINDS[kind] or kind]
    return store and store[id]
end

function W.all(kind)
    return W.ids[W.KINDS[kind] or kind] or {}
end

-- ---------------------------------------------------------------------------------------------
-- writes, in the save's own form

W.number_text = S.number_text

-- a Lua block (pdxscript form) or a handle -> a block id in the store
local function as_bid(v)
    if type(v) == "table" then return S.build(v) end
    return bid_of(v)
end

function W.set(obj, key, value_)
    S.set(bid_of(obj), key, value_)
end

function W.child(obj, key)
    local v = W.field(obj, key)
    if W.is_block(v) then return v end
    local child = S.append_block(bid_of(obj), key)
    return B + child
end

function W.append(obj, key, value_, quoted)
    local bid = bid_of(obj)
    if type(value_) == "table" or W.is_block(value_) then
        local child = S.append_block(bid, key, as_bid(value_))
        return B + child
    end
    S.append(bid, key, value_, quoted)
end

function W.insert(obj, pos, key, value_, quoted)
    local bid = bid_of(obj)
    if type(value_) == "table" or W.is_block(value_) then
        local child = as_bid(value_)
        S.insert_at(bid, pos, key, { block = child })
        return B + child
    end
    S.insert_at(bid, pos, key, value_, quoted)
end

function W.append_value(block, v)
    S.append_value(bid_of(block), tostring(v))
end

function W.remove_value(block, v)
    v = tostring(v)
    local bid = bid_of(block)
    local b = B[bid]
    for i = b.first + b.count - 1, b.first, -1 do
        local e = E[i]
        if e.op == 0 and (e.kind == TEXT or e.kind == NUMBER) and text(i) == v then
            S.remove_at(bid, i)
        end
    end
end

-- W.remove_entry(block, i): entry i (an index, as W.find_entry gives) taken out
function W.remove_entry(block, i)
    return S.remove_at(bid_of(block), i)
end

-- the entry index of the first `key` in obj, or nil
function W.find_entry(obj, key)
    local k = kid(key)
    return k and find(bid_of(obj), k)
end

function W.remove(kind, id)
    local name = W.KINDS[kind] or kind
    local store, ids = W.stores[name], W.ids[name]
    if store and store[id] then
        store[id] = nil
        if W.bids[name] then W.bids[name][id] = nil end
        local i = W.entries[name] and W.entries[name][id]
        if i then
            -- the save keeps the slot: 'id = none'
            local e = E[i]
            e.kind = TEXT
            e.v.u.a = sid("none")
            e.v.u.b = 0
        end
        for j = #ids, 1, -1 do
            if ids[j] == id then table.remove(ids, j) end
        end
    end
end

function W.create(kind, id, block)
    local name = W.KINDS[kind] or kind
    local holder = W.store_blocks[name]
    if not holder then return nil end
    local child, i = S.append_block(holder, tostring(id), as_bid(block))
    local h = B + child
    W.stores[name][id] = h
    W.bids[name][id] = child
    W.entries[name][id] = i
    W.ids[name][#W.ids[name] + 1] = id
    return h
end

function W.reindex() end

function W.write()
    return S.write(W.root)
end

-- the relations the script layer walks (engine.world.index over the store)
function W.index()
    W.planets_of, W.pop_groups_of, W.leaders_of = {}, {}, {}
    W.colony_planet, W.planet_colony = {}, {}
    for _, pid in ipairs(W.all("planet")) do
        local c = tonumber(W.field(W.object("planet", pid), "colony"))
        if c then W.colony_planet[c], W.planet_colony[pid] = pid, c end
    end
    local function push(t, k, v)
        if k then
            local l = t[k]
            if not l then l = {} t[k] = l end
            l[#l + 1] = v
        end
    end
    for _, id in ipairs(W.all("planet")) do
        push(W.planets_of, tonumber(W.field(W.object("planet", id), "owner")), id)
    end
    for _, id in ipairs(W.all("pop_group")) do
        local colony = tonumber(W.field(W.object("pop_group", id), "planet"))
        push(W.pop_groups_of, colony and W.colony_planet[colony], id)
    end
    for _, id in ipairs(W.all("leader")) do
        push(W.leaders_of, tonumber(W.field(W.object("leader", id), "country")), id)
    end
    W.fleet_owner, W.system_owner = {}, {}
    for _, cid in ipairs(W.all("country")) do
        local owned = W.path(W.object("country", cid), "fleets_manager", "owned_fleets")
        for _, entry in ipairs(W.blocks(owned)) do
            local fleet = tonumber(W.field(entry, "fleet"))
            if fleet then W.fleet_owner[fleet] = cid end
        end
    end
    for _, sid_ in ipairs(W.all("system")) do
        for _, sb in ipairs(W.list(W.field(W.object("system", sid_), "starbases"))) do
            local station = tonumber(W.field(W.object("starbase", tonumber(sb)), "station"))
            local fleet = station and tonumber(W.field(W.object("ship", station), "fleet"))
            local owner = fleet and W.fleet_owner[fleet]
            if owner and W.system_owner[sid_] == nil then W.system_owner[sid_] = owner end
        end
    end
end

return W
