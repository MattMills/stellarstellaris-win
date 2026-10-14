-- engine/store/full.lua : the whole table world copied into the shared store, for engine code
-- running in the worker states (docs/data_layer.md, "The engine on the workers").
--
-- The table world stays the source of truth. The copy is built once (S.build of engine.world's
-- tree, every table block mapped to its store block) and brought up to date at each sync from the
-- marks the writers leave (engine.world's on_write, engine.store.live):
--
-- - a block whose own entries a world writer changed ("own"): its entries written again from the
--   table's, its child blocks pointed at (they have their own marks);
-- - a block a module changed itself, in it or below ("deep", world.wrote): the same for the block
--   and everything below it;
-- - an object (live.touch, created, its slot reused, removed): the whole object written again,
--   appended to its store block, or its slot written `none`.
--
-- A block is written again in place: the block keeps its id, and so does every block it held whose
-- table is still there (only a table new to the copy is built). Handles and caches keyed by block
-- id in the workers stay good across syncs. The copy's root is the store's root 4; root 5 counts the
-- syncs that added or removed an object, and a worker attaches its engine.store.world again when it
-- changed.
--
--   local full = require("engine.store.full")
--   full.build()      -- once, after the world is loaded
--   full.sync()       -- before a phase on the workers
--   full.check()      -- every object compared with the table world (STELLAR_STORE_CHECK=1): the
--                     -- stale ones counted by store and key, then brought in

local S = require("engine.store.core")
local live = require("engine.store.live")
local world = require("engine.world")

local ROOT, GEN = 4, 5

local F = {
    root = nil, generation = 0, detail = false,
    stats = { syncs = 0, objects = 0, deep = 0, own = 0, written = 0, built = 0, added = 0, removed = 0,
        lost = 0, seconds = 0, build_seconds = 0, checked = 0, stale = {}, stale_ids = {} },
}

local W   -- engine.store.world over the copy (its index)
local bid_of = setmetatable({}, { __mode = "k" })   -- table block -> its store block
local table_of = setmetatable({}, { __mode = "v" }) -- store block -> its table block
local own_marks, deep_marks = {}, {}                -- blocks marked since the last sync
local key_marks = {}                                 -- block -> { [key] = true }: world.set's tokens
local object_marks = {}                              -- store name -> { [id] = true }
local BLOCK, TEXT, OPS
local index_changed = false                          -- an object added or removed (workers re-attach)

-- t (a table block) and every block in it mapped to the store block bid and its blocks
local function map(t, bid)
    bid_of[t] = bid
    table_of[bid] = t
    local b = S.B[bid]
    local first = b.first
    for j = 1, math.min(#t, b.count) do
        local x = t[j]
        local v = x.op and x.value or x
        if type(v) == "table" and v.text == nil then
            local e = S.E[first + j - 1]
            if e.kind == BLOCK then map(v, e.v.u.a) end
        end
    end
end

-- a block built into the store for the first time (t new to the copy)
local function build(t)
    local bid = S.build(t)
    map(t, bid)
    F.stats.built = F.stats.built + 1
    return bid
end

-- the store block bid written again from t, in place: tokens set, a child block t already maps
-- keeps its store block (written again too when deep), a new one is built
local function fill(bid, t, deep)
    local ix = S.B[bid].index
    S.clear(bid)
    F.stats.written = F.stats.written + 1
    for _, x in ipairs(t) do
        local v = x.op and x.value or x
        local i
        if v.text then
            if x.op then
                i = S.append(bid, x.key.text, v.text)
            else
                i = S.append_value(bid, v.text)
            end
            local e = S.E[i]
            e.kind = TEXT
            e.v.u.a = S.id(v.text)
            e.v.u.b = 0
            e.flags = (x.op and x.key.quoted and 1 or 0) + (v.quoted and 2 or 0)
        else
            local cb = bid_of[v]
            if cb == nil then
                cb = build(v)
            elseif deep then
                fill(cb, v, true)
            end
            local _, j = S.append_block(bid, x.op and x.key.text or nil, cb)
            i = j
            local e = S.E[i]
            e.v.u.b = v.type and S.id(v.type) or 0
            e.flags = x.op and x.key.quoted and 1 or 0
        end
        if x.op and x.op ~= "=" then S.E[i].op = OPS[x.op] or 1 end
    end
    if ix ~= 0 then S.rebuild_index(bid, ix) end
end

-- whether t or a block it is in is in set
local function covered(t, set)
    local p = world.parent(t)
    while p do
        if set[p] then return true end
        p = world.parent(p)
    end
    return false
end

-- the nearest block at or above t that the copy has (t new: the block it was added to)
local function mapped(t)
    while t and not bid_of[t] do t = world.parent(t) end
    return t
end

-- F.build(): the copy made from the table world, marks taken from now on
function F.build()
    if F.root then return F.root end
    local t0 = RUST.clock()
    require("engine.store.bridge").start()
    BLOCK, TEXT, OPS = S.BLOCK, S.TEXT, S.OPS
    -- the object marks of engine.store.live too: the writers that change an object's blocks in
    -- place and say so with live.touch (rather than through a world writer)
    live.consumer("full")
    world.track_owners()
    world.on_write = function(name, id, block, how, key)
        if block == nil then
            local m = object_marks[name]
            if not m then
                m = {}
                object_marks[name] = m
            end
            m[id] = true
        elseif how == "deep" then
            deep_marks[block] = true
        elseif key ~= nil and own_marks[block] == nil then
            local k = key_marks[block]
            if not k then
                k = {}
                key_marks[block] = k
            end
            k[key] = true
        else
            own_marks[block] = true
        end
    end
    W = require("engine.store.world")
    F.root = S.build(world.tree)
    S.H.roots[ROOT] = F.root
    map(world.tree, F.root)
    W.attach_root(F.root)
    F.generation = 1
    S.H.roots[GEN] = F.generation
    F.stats.build_seconds = RUST.clock() - t0
    return F.root
end

-- the ids of a store, in the table world and in the copy (for a store marked whole)
local function every_id(name)
    local ids = {}
    for id in pairs(world.stores[name] or {}) do ids[id] = true end
    for id in pairs(W.bids[name] or {}) do ids[id] = true end
    return ids
end

-- one object brought in
local function bring(name, id)
    local tstore = world.stores[name]
    local bids = W.bids[name]
    if not (tstore and bids) then return end
    local t = tstore[id]
    local bid = bids[id]
    local holder = W.store_blocks[name]
    F.stats.objects = F.stats.objects + 1
    if type(t) == "table" and bid then
        if bid_of[t] == bid then
            fill(bid, t, true)
        else
            -- another table for the object (its slot reused): built, the store's entry pointed at it
            local nb = build(t)
            local i = S.find(holder, S.id(tostring(id)))
            if i then S.E[i].v.u.a = nb end
            bids[id] = nb
            W.stores[name][id] = W.handle(nb)
            index_changed = true
        end
    elseif type(t) == "table" then
        local nb = build(t)
        S.append_block(holder, tostring(id), nb)
        bids[id] = nb
        W.stores[name][id] = W.handle(nb)
        local ids = W.ids[name]
        ids[#ids + 1] = id
        F.stats.added = F.stats.added + 1
        index_changed = true
    elseif bid then
        -- the save keeps the slot, 'id = none', as engine.world.remove does
        local i = S.find(holder, S.id(tostring(id)))
        if i then
            local e = S.E[i]
            e.kind = TEXT
            e.v.u.a = S.id("none")
            e.v.u.b = 0
        end
        bids[id] = nil
        W.stores[name][id] = nil
        local ids = W.ids[name]
        for k = #ids, 1, -1 do
            if ids[k] == id then table.remove(ids, k) end
        end
        F.stats.removed = F.stats.removed + 1
        index_changed = true
    end
end

-- the main state's derived indexes (engine.world: kept by the writers, not computed again), copied
-- into the store at each sync for the workers: root 8 a block of `<name> = { ... }`, a map as its
-- keys and values in turn (`{ k v k v ... }`), a map of lists as each key, its count and its items;
-- root 9 counts the copies
F.INDEXES = { colony_planet = "map", planet_colony = "map", fleet_owner = "map", system_owner = "map",
    planets_of = "lists", pop_groups_of = "lists", leaders_of = "lists" }
local index_root, index_blocks = nil, {}
local function export_indexes()
    if index_root == nil then
        index_root = S.new_block(0)
        S.H.roots[8] = index_root
        for name in pairs(F.INDEXES) do
            index_blocks[name] = S.append_block(index_root, name)
        end
    end
    for name, how in pairs(F.INDEXES) do
        local bid = index_blocks[name]
        S.clear(bid)
        for k, v in pairs(world[name] or {}) do
            if type(k) == "number" then
                S.append_value(bid, k)
                if how == "map" then
                    S.append_value(bid, v)
                else
                    S.append_value(bid, #v)
                    for j = 1, #v do S.append_value(bid, v[j]) end
                end
            else
                F.stats.index_skipped = (F.stats.index_skipped or 0) + 1
            end
        end
    end
    S.H.roots[9] = S.H.roots[9] + 1
end
F.export_indexes = export_indexes

-- F.sync(): the marked objects and blocks brought into the copy
function F.sync()
    if not F.root then return end
    local t0 = RUST.clock()
    F.stats.syncs = F.stats.syncs + 1
    if live.check then F.check() end
    local done = {}
    local objects = object_marks
    object_marks = {}
    for name, ids in pairs(live.take("full")) do
        if ids == true then ids = every_id(name) end
        local m = objects[name]
        if not m then
            m = {}
            objects[name] = m
        end
        for id in pairs(ids) do m[id] = true end
    end
    for name, ids in pairs(objects) do
        local tstore = world.stores[name]
        for id in pairs(ids) do
            bring(name, id)
            local t = tstore and tstore[id]
            if type(t) == "table" then done[t] = true end
        end
    end
    local t1 = RUST.clock()
    F.stats.t_objects = (F.stats.t_objects or 0) + (t1 - t0)
    local deep, own, keys = deep_marks, own_marks, key_marks
    deep_marks, own_marks, key_marks = {}, {}, {}
    -- a mark on a block the copy does not have yet is a mark on the block it was added to
    local d, o = {}, {}
    for t in pairs(deep) do
        local m = mapped(t)
        if m ~= nil then d[m] = true else F.stats.lost = F.stats.lost + 1 end
    end
    for t in pairs(own) do
        local m = mapped(t)
        if m == nil then
            F.stats.lost = F.stats.lost + 1
        elseif m ~= t then
            d[m] = d[m] or nil
            o[m] = true
        else
            o[m] = true
        end
    end
    for t in pairs(d) do
        if not (done[t] or covered(t, d) or covered(t, done)) then
            F.stats.deep = F.stats.deep + 1
            fill(bid_of[t], t, true)
        end
    end
    for t in pairs(o) do
        if not (d[t] or done[t] or covered(t, d) or covered(t, done)) then
            F.stats.own = F.stats.own + 1
            fill(bid_of[t], t, false)
        end
    end
    -- world.set's tokens: the one entry set, where the copy has the block and the key's first entry
    -- is a token there too (else the block's entries written again)
    for t, ks in pairs(keys) do
        local bid = bid_of[t]
        if bid and not (o[t] or d[t] or done[t] or covered(t, d) or covered(t, done)) then
            for key in pairs(ks) do
                local te = world.token_entry(t, key)
                local i = te and S.find(bid, S.id(key))
                local e = i and S.E[i]
                if e and e.kind ~= BLOCK and e.op ~= 0 then
                    local v = te.value
                    e.kind = TEXT
                    e.v.u.a = S.id(v.text)
                    e.v.u.b = 0
                    e.flags = (te.key.quoted and 1 or 0) + (v.quoted and 2 or 0)
                    F.stats.keys = (F.stats.keys or 0) + 1
                else
                    F.stats.own = F.stats.own + 1
                    fill(bid, t, false)
                    break
                end
            end
        elseif not bid then
            F.stats.lost = F.stats.lost + 1
        end
    end
    export_indexes()
    F.stats.t_blocks = (F.stats.t_blocks or 0) + (RUST.clock() - t1)
    if index_changed then
        index_changed = false
        F.generation = F.generation + 1
        S.H.roots[GEN] = F.generation
    end
    F.stats.seconds = F.stats.seconds + (RUST.clock() - t0)
end

-- the store block bid equal to the Lua block t (pdxscript form): the same entries, keys, kinds and
-- values (a number compared as a number)
local function same(bid, t)
    local b = S.B[bid]
    local n = #t
    if b.count ~= n then return false end
    local first = b.first
    for j = 1, n do
        local x = t[j]
        local i = first + j - 1
        local e = S.E[i]
        local v = x.op and x.value or x
        if x.op then
            if e.op == 0 or e.key ~= S.id(x.key.text) then return false end
        elseif x.param or e.op ~= 0 then
            return false
        end
        if v.text then
            if e.kind == BLOCK then return false end
            local tok = S.token(i)
            if type(tok) == "number" then
                if tonumber(v.text) ~= tok then return false end
            elseif tok ~= v.text then
                return false
            end
        else
            if e.kind ~= BLOCK or not same(e.v.u.a, v) then return false end
        end
    end
    return true
end

-- the path of keys to the first place where a block and its copy differ
local function stale_key(bid, t, depth)
    depth = depth or 1
    local b = S.B[bid]
    for j = 1, math.min(b.count, #t) do
        local x = t[j]
        local e = S.E[b.first + j - 1]
        local v = x.op and x.value or x
        local key = x.op and x.key.text or "[]"
        if x.op and (e.op == 0 or e.key ~= S.id(x.key.text)) then return key end
        if v.text then
            local tok = S.token(b.first + j - 1)
            if e.kind == BLOCK or (type(tok) == "number" and tonumber(v.text) ~= tok)
                or (type(tok) ~= "number" and tok ~= v.text) then
                if F.detail then
                    return string.format("%s (copy %s, table %s)", key, e.kind == BLOCK and "{}" or tostring(tok), v.text)
                end
                return key
            end
        elseif e.kind ~= BLOCK then
            return key
        elseif not same(e.v.u.a, v) then
            if depth >= (F.detail and 6 or 3) then return key end
            return key .. "." .. stale_key(e.v.u.a, v, depth + 1)
        end
    end
    return string.format("(count %d -> %d)", b.count, #t)
end

-- F.check(): the marks applied first, then every object compared with the table world; the stale
-- ones counted (store.key) and brought in
function F.check()
    local saved = live.check
    live.check = false
    F.sync()
    live.check = saved
    for name, tstore in pairs(world.stores) do
        local bids = W.bids[name]
        if bids then
            for id, t in pairs(tstore) do
                if type(t) == "table" then
                    F.stats.checked = F.stats.checked + 1
                    local bid = bids[id]
                    if not bid or not same(bid, t) then
                        local k = name .. "." .. (bid and stale_key(bid, t) or "(new object)")
                        F.stats.stale[k] = (F.stats.stale[k] or 0) + 1
                        local l = F.stats.stale_ids[k] or {}
                        if #l < 3 then l[#l + 1] = id end
                        F.stats.stale_ids[k] = l
                        local m = object_marks[name] or {}
                        object_marks[name] = m
                        m[id] = true
                    end
                end
            end
        end
    end
end

-- F.table_of(bid) -> the table world's block that the store block bid copies (a block id from a worker)
function F.table_of(bid)
    return table_of[bid]
end

function F.report()
    local s = F.stats
    local lines = { string.format(
        "full copy: built in %.2f s; %d syncs: %d objects (%d added, %d removed), %d deep blocks, %d own blocks, %d single keys; %d blocks written, %d built, %d marks lost; %.2f s (objects %.2f, blocks %.2f)",
        s.build_seconds, s.syncs, s.objects, s.added, s.removed, s.deep, s.own, s.keys or 0, s.written, s.built, s.lost,
        s.seconds, s.t_objects or 0, s.t_blocks or 0) }
    if s.checked > 0 then
        local l = {}
        for k, n in pairs(s.stale) do l[#l + 1] = { k, n } end
        table.sort(l, function(a, b) return a[2] > b[2] end)
        lines[#lines + 1] = string.format("full copy check: %d objects compared, %d stale keys", s.checked, #l)
        for i = 1, math.min(#l, 40) do
            lines[#lines + 1] = string.format("  %-50s %7d  e.g. %s", l[i][1], l[i][2],
                table.concat(s.stale_ids[l[i][1]], " "))
        end
    end
    return table.concat(lines, "\n")
end

return F
