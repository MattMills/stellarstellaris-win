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
-- the builtin: a worker makes the global type say "table" for a block handle, for the engine's
-- modules (engine.store.worker); here a handle must stay a cdata
local type = type
local band, bor = require("bit").band, require("bit").bor

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
local handle_t = S.handle_t
local function attach()
    S.attach()
    E, B = S.E, S.B
end

-- one handle per block (interned): caches keyed by a block find it again
local handles = {}
local function handle(bid)
    local h = handles[bid]
    if h == nil then
        h = handle_t(B + bid)
        handles[bid] = h
    end
    return h
end
local function bid_of(h)
    return tonumber(h.p - B)
end
W.handle, W.bid = handle, bid_of
function W.is_block(v)
    return type(v) == "cdata" and ffi.istype(handle_t, v)
end

-- W.count(h) -> the number of the block's entries; W.key(h) -> the block's id, a key for caches
-- (engine.world.count / key)
function W.count(h)
    return h.p.count
end
function W.key(h)
    return tonumber(h.p - B)
end

local TEXT, NUMBER, BLOCK = S.TEXT, S.NUMBER, S.BLOCK
local token, text, find, find_next, kid, sid = S.token, S.text, S.find, S.find_next, S.kid, S.id

-- W.overlay: block id -> a Lua table (pdxscript form) given instead of the block's handle. A worker
-- puts there the blocks it may write (an AI country's own state: engine.store.worker), materialized
-- from the copy; engine.world's functions on those tables are the table world's.
W.overlay = {}
local overlay = W.overlay

local function block_value(a)
    return overlay[a] or handle(a)
end
S.block_value = block_value

-- the value of entry i: a token's (number or text), or a block's handle
local function value(i)
    local e = E[i]
    if e.kind == BLOCK then return block_value(e.v.u.a) end
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
            store[id] = handle(e.v.u.a)
            bids[id] = e.v.u.a
            entries[id] = i
            ids[#ids + 1] = id
        end
    end
    W.stores[name], W.ids[name], W.entries[name], W.bids[name] = store, ids, entries, bids
    W.store_blocks[name] = handle(bid)
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
    W.tree = handle(root)
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
        out[n] = e.kind == BLOCK and block_value(e.v.u.a) or text(i)
        i = find_next(bid, k, i)
    end
    return out
end

-- the bare values of a list block, as text
function W.list(block)
    local out, n = {}, 0
    if W.is_block(block) then
        local b = block.p
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
        local b = block.p
        for i = b.first, b.first + b.count - 1 do
            local e = E[i]
            if e.op == 0 and e.kind == BLOCK then
                n = n + 1
                out[n] = block_value(e.v.u.a)
            end
        end
    end
    return out
end

-- W.statements(h) -> an iterator over the block's `key = value` statements: the key's text and the
-- value (a token's text, or a block) (engine.world.statements)
function W.statements(h)
    if not W.is_block(h) then return function() return nil end end
    local b = h.p
    local i, last = b.first - 1, b.first + b.count - 1
    return function()
        while i < last do
            i = i + 1
            local e = E[i]
            if e.op ~= 0 then
                return S.str(e.key), (e.kind == BLOCK and block_value(e.v.u.a) or text(i))
            end
        end
        return nil
    end
end

-- W.to_table(h) -> the block as a Lua table in pdxscript's form (a block's entries, with their keys,
-- operators, quoting and types), for a worker's overlay
local OP_TEXT = S.OP_TEXT
local function to_table(bid)
    local b = B[bid]
    local t = {}
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        local v
        if e.kind == BLOCK then
            v = to_table(e.v.u.a)
            if e.v.u.b ~= 0 then v.type = S.str(e.v.u.b) end
        else
            v = { text = text(i), quoted = band(e.flags, 2) ~= 0 or nil }
        end
        if e.op ~= 0 then
            t[#t + 1] = { key = { text = S.str(e.key), quoted = band(e.flags, 1) ~= 0 or nil }, op = OP_TEXT[e.op],
                value = v }
        else
            t[#t + 1] = v
        end
    end
    return t
end
function W.to_table(h)
    return to_table(bid_of(h))
end

function W.path(obj, ...)
    local v = obj
    for _, k in ipairs({ ... }) do
        -- a block handle, or an overlay's Lua table (W.field is the worker's dispatching one then)
        if type(v) ~= "table" and not W.is_block(v) then return nil end
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
-- the Lua tables copied into the store, and the store block each became (its nested tables too):
-- a module that builds a block, gives it to a writer and goes on writing it writes the store's
-- (engine.store.engine_world sends a function's Lua table here when it is one of these)
local attached = setmetatable({}, { __mode = "k" })
W.attached = attached
local function map_attached(t, bid)
    attached[t] = bid
    local b = B[bid]
    for j = 1, math.min(#t, b.count) do
        local x = t[j]
        local v = (type(x) == "table" and x.op) and x.value or x
        if type(v) == "table" and v.text == nil then
            local e = E[b.first + j - 1]
            if e.kind == BLOCK then map_attached(v, e.v.u.a) end
        end
    end
end
local function as_bid(v)
    if type(v) == "table" then
        local a = attached[v]
        if a then return a end
        a = S.build(v)
        map_attached(v, a)
        return a
    end
    return bid_of(v)
end

function W.set(obj, key, value_)
    S.set(bid_of(obj), key, value_)
end

function W.child(obj, key)
    local v = W.field(obj, key)
    if W.is_block(v) then return v end
    local child = S.append_block(bid_of(obj), key)
    return handle(child)
end

function W.append(obj, key, value_, quoted)
    if type(value_) == "table" and value_.text ~= nil then value_, quoted = value_.text, value_.quoted end
    local bid = bid_of(obj)
    if type(value_) == "table" or W.is_block(value_) then
        local child = S.append_block(bid, key, as_bid(value_))
        return handle(child)
    end
    S.append(bid, key, value_, quoted)
end

function W.insert(obj, pos, key, value_, quoted)
    if type(value_) == "table" and value_.text ~= nil then value_, quoted = value_.text, value_.quoted end
    local bid = bid_of(obj)
    if type(value_) == "table" or W.is_block(value_) then
        local child = as_bid(value_)
        S.insert_at(bid, pos, key, { block = child })
        return handle(child)
    end
    S.insert_at(bid, pos, key, value_, quoted)
end

function W.append_value(block, v, quoted)
    S.append_value(bid_of(block), tostring(v), quoted or false)
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


-- the entry index of the first `key` in obj, or nil
function W.find_entry(obj, key)
    local k = kid(key)
    return k and find(bid_of(obj), k)
end

-- W.entry(obj, key) -> the first `key = value` statement of obj as an entry view (what h[i] and
-- ipairs give) and its position, or nil (engine.world.entry): found by the key index, one view
-- built, instead of a walk that builds a view of every entry before it
function W.entry(obj, key)
    if obj == nil then return nil end
    local k = kid(key)
    if not k then return nil end
    local bid = bid_of(obj)
    local i = find(bid, k)
    if not i then return nil end
    local p = i - B[bid].first + 1
    return S.entry_table(i, bid, p), p
end

function W.remove(kind, id)
    W.version = (W.version or 0) + 1
    local name = W.KINDS[kind] or kind
    local store, ids = W.stores[name], W.ids[name]
    if store and store[id] then
        store[id] = nil
        if W.bids[name] then W.bids[name][id] = nil end
        -- (looked up: a remembered entry index moves when the holder block grows)
        local holder = W.store_blocks[name] and bid_of(W.store_blocks[name])
        local i = holder and find(holder, sid(tostring(id)))
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

-- W.ensure_store(kind) -> the store's block (engine.world.ensure_store): a store the save has no
-- objects in made as a top-level `name = { }`
function W.ensure_store(kind)
    local name = W.KINDS[kind] or kind
    if W.store_blocks[name] then return W.store_blocks[name] end
    if not W.root then return nil end
    local child = S.append_block(W.root, name)
    local h = handle(child)
    W.meta[name] = nil
    W.stores[name], W.ids[name], W.entries[name], W.bids[name] = {}, {}, {}, {}
    W.store_blocks[name] = h
    return h
end

function W.next_index(kind)
    local max = -1
    for _, id in ipairs(W.all(kind)) do
        local index = id % 16777216
        if index > max then max = index end
    end
    return max + 1
end

function W.create(kind, id, block)
    W.version = (W.version or 0) + 1
    local name = W.KINDS[kind] or kind
    if not W.store_blocks[name] then W.ensure_store(name) end
    local holder = W.store_blocks[name] and bid_of(W.store_blocks[name])
    if not holder then return nil end
    local child, i = S.append_block(holder, tostring(id), as_bid(block))
    local h = handle(child)
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

-- ---------------------------------------------------------------------------------------------
-- the rest of engine.world's writers, so the main state runs on the store (STELLAR_WORLD=store)

local GEN = 16777216

-- the entry index (into S.E) of e in block h: an index, an entry view (h[i], ipairs: its position
-- in the block), or a bare block's handle
local function entry_index(h, e)
    if type(e) == "number" then return e end
    if type(e) == "table" then
        local p = e._p or (e.value and e.value._p)
        if p then return B[bid_of(h)].first + p - 1 end
    end
    if W.is_block(e) then
        local b = B[bid_of(h)]
        local want = bid_of(e)
        for i = b.first, b.first + b.count - 1 do
            local x = E[i]
            if x.kind == BLOCK and x.v.u.a == want then return i end
        end
    end
    return nil
end

-- W.remove_entry(block, e): one entry taken out (an index, an entry view, or a bare block)
function W.remove_entry(block, e)
    local i = entry_index(block, e)
    return i ~= nil and S.remove_at(bid_of(block), i)
end

-- W.set_entry(block, e, text): the token of entry e (an entry or a bare token as h[i] and ipairs
-- give it) set; the view itself too, so the code holding it reads the new text
function W.set_entry(block, e, t)
    local i = entry_index(block, e)
    local x = E[i]
    if W.is_block(t) then
        -- the entry now holds that block
        x.kind = BLOCK
        x.v.u.a = bid_of(t)
        x.v.u.b = 0
        if e.op then e.value = t end
        return
    end
    if type(t) == "table" and t.text == nil then
        -- a block of the pdxscript form: written into the block the entry holds, in place, or built
        if x.kind == BLOCK then
            local child = x.v.u.a
            W.replace(handle(child), t)
            attached[t] = child
        else
            local child = as_bid(t)
            x = E[i]
            x.kind = BLOCK
            x.v.u.a = child
            x.v.u.b = 0
        end
        if e.op then e.value = handle(E[i].v.u.a) end
        return
    end
    if type(t) == "table" then t = t.text end
    t = tostring(t)
    S.set_value(i, t)
    local v = e.op and e.value or e
    if type(v) == "table" and v.text ~= nil then v.text = t elseif e.op then e.value = { text = t } end
end

-- W.push(block, value): a bare value at the end of a list block, a token or a block
function W.push(block, v)
    if type(v) == "table" and v.text ~= nil then
        S.append_value(bid_of(block), v.text, v.quoted or false)
        return
    end
    if type(v) == "table" or W.is_block(v) then
        return handle(S.append_block(bid_of(block), nil, as_bid(v)))
    end
    S.append_value(bid_of(block), tostring(v))
end

-- W.set_text(block, i, text): the token of the block's entry i (1-based) set
function W.set_text(block, i, t)
    local b = B[bid_of(block)]
    S.set_value(b.first + i - 1, tostring(t))
end

-- W.set_key(block, i, key): the key of the block's entry i
function W.set_key(block, i, key)
    local bid = bid_of(block)
    local b = B[bid]
    E[b.first + i - 1].key = sid(tostring(key))
    b.index = 0
end

-- W.insert_value(block, pos, value): a bare value (a token or a block) at position pos
function W.insert_value(block, pos, v)
    if type(v) == "table" and v.text ~= nil then
        S.insert_at(bid_of(block), pos, nil, v.text, v.quoted or false)
        return
    end
    local bid = bid_of(block)
    if type(v) == "table" or W.is_block(v) then
        local child = as_bid(v)
        S.insert_at(bid, pos, nil, { block = child })
        return handle(child)
    end
    S.insert_at(bid, pos, nil, tostring(v))
end

-- W.remove_at(block, i): the block's entry i taken out
function W.remove_at(block, i)
    local bid = bid_of(block)
    return S.remove_at(bid, B[bid].first + i - 1)
end

-- W.none_slot(store, index, gen) -> the id of the first `<id> = none` slot of the store whose id is
-- index modulo gen (a freed slot a new object may take), or nil
function W.none_slot(name, index, gen)
    name = W.KINDS[name] or name
    local holder = W.store_blocks[name] and bid_of(W.store_blocks[name])
    if not holder then return nil end
    local b, none = B[holder], sid("none")
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        if e.op ~= 0 and e.kind == TEXT and e.v.u.a == none then
            local id = tonumber(S.str(e.key))
            if id and id % (gen or GEN) == index then return id end
        end
    end
    return nil
end

-- W.place(store, id, old, block[, gen]) -> the object's block: a freed slot `old = none` becomes the
-- object (the save keeps its place), else the object goes at the end (W.create)
function W.place(name, id, old, block, gen)
    W.version = (W.version or 0) + 1
    name = W.KINDS[name] or name
    local holder = W.store_blocks[name] and bid_of(W.store_blocks[name])
    local i = old and holder and find(holder, sid(tostring(old)))
    if i and E[i].kind == TEXT and E[i].v.u.a == sid("none") then
        local child = as_bid(block)
        local e = E[i]
        e.key = sid(tostring(id))
        e.kind = BLOCK
        e.v.u.a = child
        e.v.u.b = 0
        B[holder].index = 0
        local h = handle(child)
        W.stores[name][id], W.bids[name][id], W.entries[name][id] = h, child, i
        if old ~= id then W.entries[name][old] = nil end
        local ids = W.ids[name]
        ids[#ids + 1] = id
        gen = gen or GEN
        table.sort(ids, function(x, y) return x % gen < y % gen end)
        return h
    end
    return W.create(name, id, block)
end

-- W.replace(block, entries): the block's entries replaced by entries (the pdxscript form: entries
-- `{ key, op, value }`, bare tokens `{ text }`, blocks; views of this or another store block keep
-- the store blocks they hold, a Lua table is built into the store)
-- (W.replace below) one entry of the pdxscript form appended to store block bid
local function append_one(bid, x)
    do
        local keyed = type(x) == "table" and x.op ~= nil
        local v = keyed and x.value or x
        local key = keyed and x.key.text or nil
        local i
        if W.is_block(v) then
            local _, j = S.append_block(bid, key, bid_of(v))
            i = j
        elseif v.text == nil then
            local _, j = S.append_block(bid, key, as_bid(v))
            i = j
            if v.type then E[i].v.u.b = sid(v.type) end
        else
            i = key and S.append(bid, key, v.text, v.quoted or false) or S.append_value(bid, v.text, v.quoted or false)
        end
        if keyed then
            if x.key.quoted then E[i].flags = bor(E[i].flags, 1) end
            if x.op ~= "=" then E[i].op = S.OPS[x.op] or 1 end
        end
    end
end

-- W.append_entry(block, e): an entry of the pdxscript form (a keyed entry, a bare token or block) at
-- the end of the block
function W.append_entry(block, e)
    append_one(bid_of(block), e)
end

-- W.replace(block, entries): the block's entries replaced by entries (the pdxscript form: entries
-- `{ key, op, value }`, bare tokens `{ text }`, blocks). A handle given (a view's value) keeps its
-- store block; a Lua table where the block had a block at the same place under the same key is
-- written into that block, in place (so a writer that rebuilds a block each tick takes no new store
-- blocks); another Lua table is built into the store.
local function replace(bid, list)
    local b = B[bid]
    local old = {}
    for j = 1, b.count do
        local e = E[b.first + j - 1]
        if e.kind == BLOCK then old[j] = e end
    end
    -- (the old entries' keys and child blocks, before the block is cleared)
    for j, e in pairs(old) do old[j] = { key = e.key, op = e.op, child = e.v.u.a } end
    S.clear(bid)
    for j, x in ipairs(list) do
        local keyed = type(x) == "table" and x.op ~= nil
        local v = keyed and x.value or x
        local o = old[j]
        if o and type(v) == "table" and v.text == nil and not attached[v]
            and (keyed and o.op ~= 0 and o.key == sid(x.key.text) or (not keyed and o.op == 0)) then
            local inner = {}
            for k, y in ipairs(v) do inner[k] = y end
            replace(o.child, inner)
            attached[v] = o.child
            local _, i = S.append_block(bid, keyed and x.key.text or nil, o.child)
            if v.type then E[i].v.u.b = sid(v.type) end
            if keyed then
                if x.key.quoted then E[i].flags = bor(E[i].flags, 1) end
                if x.op ~= "=" then E[i].op = S.OPS[x.op] or 1 end
            end
        else
            append_one(bid, x)
        end
    end
end
function W.replace(block, entries)
    local list = {}
    for i, x in ipairs(entries) do list[i] = x end
    replace(bid_of(block), list)
end

-- W.same(a, b): whether a and b are the same block of the world (a handle, or a Lua table a writer
-- put into the store: engine.store.engine_world)
function W.same(a, b)
    local function id(x)
        if type(x) == "table" then return attached[x] end
        if W.is_block(x) then return bid_of(x) end
        return nil
    end
    local ia, ib = id(a), id(b)
    if ia and ib then return ia == ib end
    return rawequal(a, b)
end

-- engine.world's write marks and owners are the table world's (its copy for the workers): none here
function W.wrote() end
function W.adopt() end
function W.retrack() end
function W.track_owners() end
function W.parent() return nil end

function W.summary()
    local names = {}
    for name in pairs(W.stores) do names[#names + 1] = name end
    table.sort(names, function(a, b) return #W.ids[a] > #W.ids[b] end)
    local parts = {}
    for i = 1, math.min(14, #names) do parts[#parts + 1] = names[i] .. " " .. #W.ids[names[i]] end
    return string.format("%s, %d stores (%s), in the store in %.1f s", tostring(W.meta.date), #names,
        table.concat(parts, ", "), W.seconds)
end

return W
