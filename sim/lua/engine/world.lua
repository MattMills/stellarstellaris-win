-- engine/world.lua : the game state, from a save. A save's `gamestate` is the game's object
-- databases written member by member (CPersistent::WriteMembers): `country = { 0 = { ... } ... }`,
-- `pop_groups`, `leaders`, `fleet`, `ships`, `galactic_object`, `planets = { planet = { ... } }`,
-- ... Every section of id-keyed blocks becomes a store of objects (their blocks as parsed, read
-- through world.field); every other top-level value is kept in world.meta.
--
--   local world = require("engine.world")
--   world.load(gamestate_text)
--   world.object("country", 0), world.field(obj, "capital"), world.list(obj, "civics")

local pdxscript = require("pdxscript")

local world = {
    stores = {},   -- store name -> { [id] = block }
    ids = {},      -- store name -> ids in order
    meta = {},     -- top-level values that are not stores (date, tick, player, ...)
    seconds = 0,
}

-- the store a scope kind of the script layer lives in
world.KINDS = {
    country = "country", planet = "planet", pop_group = "pop_groups", leader = "leaders",
    fleet = "fleet", ship = "ships", system = "galactic_object", species = "species_db",
    army = "army", starbase = "starbases", federation = "federation", war = "war",
    deposit = "deposit", pop_job = "pop_jobs", megastructure = "megastructures", sector = "sectors",
    situation = "situations", first_contact = "contacts",
}

local function is_id(text)
    return text and text:match("^%d+$") ~= nil
end

-- a block whose statements are all `<id> = { ... }` or `<id> = none`
local function is_store(block)
    local n = 0
    for _, e in ipairs(block) do
        if not (e.op and e.key and is_id(e.key.text)) then
            return false
        end
        n = n + 1
    end
    return n > 0
end

world.entries = {}   -- store name -> { [id] = its entry in the tree (removal writes 'id = none') }
world.store_blocks = {}  -- store name -> the tree's block that holds it (new objects are added there)

-- The blocks the writers below change, for the store's copy of the world (engine.store.full):
-- after world.track_owners(), every block knows its object (store and id) and the block it is in,
-- and each writer calls world.on_write(store, id, block, how):
--   how "own"  the writer changed block's own entries (a token set, an entry added or taken out);
--   how "deep" world.wrote(block): a module changed something in block or below it itself (an
--              entry's text set directly, table.insert into a block);
--   no block   the object itself (created, its slot reused, removed).
-- A block a writer adds belongs to the object of the block it is added to.
local owner = setmetatable({}, { __mode = "k" })      -- block -> the object's block
local parent_of = setmetatable({}, { __mode = "k" })  -- block -> the block it is in
local object_of = setmetatable({}, { __mode = "k" })  -- an object's block -> { store, id }
local tracking = false
world.on_write = nil

-- block (in parent) and every block in it belong to obj
local function own(block, obj, parent)
    owner[block] = obj
    parent_of[block] = parent
    for _, e in ipairs(block) do
        local v = e.op and e.value or e
        if type(v) == "table" and v.text == nil then own(v, obj, block) end
    end
end

local function wrote(block, how, key)
    local f = world.on_write
    if f then
        local o = object_of[owner[block]]
        if o then f(o[1], o[2], block, how, key) end
    end
end

-- world.parent(block) -> the block it is in (after world.track_owners)
function world.parent(block)
    return parent_of[block]
end

-- world.wrote(block): a module that changed block (or anything in it) without this API's writers
-- says so (an entry's text set directly, entries inserted or removed with table.*)
function world.wrote(block)
    if tracking then wrote(block, "deep") end
end

-- world.adopt(name, id, block): an object a module put into its store itself (a freed slot reused:
-- engine.fleets.create.place) given its blocks' owner, and marked
function world.adopt(name, id, block)
    if not tracking then return end
    object_of[block] = { name, id }
    own(block, block, world.store_blocks[name])
    if world.on_write then world.on_write(name, id) end
end

-- world.retrack(block): the blocks now in block (its entries replaced) given its object and itself as parent
function world.retrack(block)
    if tracking then own(block, owner[block], parent_of[block]) end
end

-- world.track_owners(): every object's blocks given their object, from now on kept by the writers
function world.track_owners()
    if tracking then return end
    tracking = true
    for name, store in pairs(world.stores) do
        local holder = world.store_blocks[name]
        for id, block in pairs(store) do
            object_of[block] = { name, id }
            own(block, block, holder)
        end
    end
end

local function add_store(name, block)
    local store, ids, entries = world.stores[name] or {}, world.ids[name] or {}, world.entries[name] or {}
    for _, e in ipairs(block) do
        if e.value.text == nil then
            local id = tonumber(e.key.text)
            store[id] = e.value
            entries[id] = e
            ids[#ids + 1] = id
        end
    end
    world.stores[name], world.ids[name], world.entries[name] = store, ids, entries
    world.store_blocks[name] = block
end

-- world.find_stores(tree, visit): every store of a gamestate tree, visit(name, block). A top-level
-- store is named by its key (`country`); one inside a wrapper by the inner key (`planets = {
-- planet = { } }` -> `planet`, `starbase_mgr = { starbases = { } }` -> `starbases`); one deeper by
-- its path (`construction = { item_mgr = { items = { } } }` -> `construction.item_mgr.items`).
-- Returns the top-level keys that held no store (plain values or blocks).
function world.find_stores(tree, visit)
    local plain = {}
    local function walk(v, path, key, depth)
        if is_store(v) then
            visit(depth <= 2 and key or path, v)
            return true
        end
        if depth >= 3 then
            return false
        end
        local any = false
        for _, inner in ipairs(v) do
            if inner.op and inner.key and inner.value.text == nil then
                any = walk(inner.value, path .. "." .. inner.key.text, inner.key.text, depth + 1) or any
            end
        end
        return any
    end
    for _, e in ipairs(tree) do
        if e.op and e.key then
            local key, v = e.key.text, e.value
            if v.text ~= nil or not walk(v, key, key, 1) then
                plain[#plain + 1] = e
            end
        end
    end
    return plain
end

-- world.load(text) -> true | nil, message
function world.load(text)
    local t0 = RUST.clock()
    local tree, message = pdxscript.parse(text, "gamestate")
    if not tree then
        return nil, message
    end
    world.tree = tree
    for _, e in ipairs(world.find_stores(tree, add_store)) do
        world.meta[e.key.text] = e.value.text or e.value
    end
    world.seconds = RUST.clock() - t0
    world.index()
    return true
end

-- world.parse_stores(text) -> { name -> { [id] = block } } | nil, message: the stores of another
-- gamestate, apart from this world (to compare with it: engine.diff)
function world.parse_stores(text)
    local tree, message = pdxscript.parse(text, "gamestate")
    if not tree then
        return nil, message
    end
    local stores = {}
    world.find_stores(tree, function(name, block)
        local store = stores[name] or {}
        for _, e in ipairs(block) do
            if e.value.text == nil then
                store[tonumber(e.key.text)] = e.value
            end
        end
        stores[name] = store
    end)
    for _, e in ipairs(tree) do
        if e.op and e.key and e.value.text then
            stores["@" .. e.key.text] = e.value.text
        end
    end
    return stores
end

-- the fields of an object, indexed once: key -> { entries }. The entries themselves are kept (a
-- value read through them is the value now, whether a token changed in place or an entry given a
-- new value), and the object's length when indexed: an object grown or shrunk by code that edits
-- its entries directly is indexed again on its next read. (world.set / child / append keep the
-- index and the length current themselves; world.reindex for a same-length rewrite.)
--
-- The length check costs about 15% of the run, so it is on only with STELLAR_WORLD_CHECK=1: then
-- every read of an index made stale by a direct edit is counted with its traceback
-- (world.stale_report()), to find the code that must call world.reindex; without it, an index is
-- trusted until world.reindex / insert / remove_entry drops it.
local fields_of = setmetatable({}, { __mode = "k" })
local length_of = setmetatable({}, { __mode = "k" })
local check = os.getenv("STELLAR_WORLD_CHECK") == "1"
local stale = {}
function world.stale_report()
    local list = {}
    for where, n in pairs(stale) do list[#list + 1] = { where, n } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local out = { string.format("world: %d places read a stale field index", #list) }
    for i = 1, math.min(#list, 30) do
        out[#out + 1] = string.format("%8d  %s", list[i][2], list[i][1])
    end
    return table.concat(out, "\n")
end
local function fields(obj)
    local f = fields_of[obj]
    local n = check and #obj or 0
    if f ~= nil and check and length_of[obj] ~= n then
        local where = debug.traceback("", 3):gsub("\n%s*", " | "):sub(1, 400)
        stale[where] = (stale[where] or 0) + 1
        f = nil
    end
    if f == nil then
        f = {}
        for _, e in ipairs(obj) do
            if e.op and e.key then
                local list = f[e.key.text]
                if not list then
                    list = {}
                    f[e.key.text] = list
                end
                list[#list + 1] = e
            end
        end
        fields_of[obj] = f
        length_of[obj] = n
    end
    return f
end

-- world.reindex(obj): the index of obj dropped, for code that rewrote obj's entries directly
-- without changing its length
function world.reindex(obj)
    if tracking then wrote(obj, "deep") end
    fields_of[obj] = nil
end

-- world.field(obj, key) -> the first value of key: a number when it is one, else the text or the
-- block; world.fields(obj, key) -> all of them (texts or blocks)
function world.field(obj, key)
    if obj == nil then
        return nil
    end
    local l = fields(obj)[key]
    local v = l and l[1] and l[1].value
    if v and v.text then
        return tonumber(v.text) or v.text
    end
    return v
end
function world.fields(obj, key)
    local out = {}
    for i, e in ipairs(obj and fields(obj)[key] or {}) do
        local v = e.value
        out[i] = v.text or v
    end
    return out
end

-- the bare values of a list block (`civics = { "a" "b" }`), as text
function world.list(block)
    local out = {}
    if type(block) == "table" then
        for _, e in ipairs(block) do
            if e.text then
                out[#out + 1] = e.text
            end
        end
    end
    return out
end

-- a path of fields: world.path(obj, "modules", "standard_economy_module", "resources", "energy")
function world.path(obj, ...)
    local v = obj
    for _, k in ipairs({ ... }) do
        if type(v) ~= "table" then
            return nil
        end
        v = world.field(v, k)
    end
    return v
end

-- ---------------------------------------------------------------------------------------------
-- changes, in the save's own form (the world stays a save: it is written back as it is read)

-- a number as the save writes it (5 decimals, 1.0 = 100000 in the game's fixed point)
local function number_text(v)
    if v == math.floor(v) then
        return string.format("%d", v)
    end
    return (string.format("%.5f", v):gsub("0+$", ""))
end
world.number_text = number_text

-- an entry just appended at the end of obj: an index that was current before it gets the entry at
-- the end of the key's list, as a rebuild would put it; one that was not is dropped
local function appended(obj, key, entry)
    local f = fields_of[obj]
    if f == nil then
        return
    end
    local n = check and #obj or 0
    if check and length_of[obj] ~= n - 1 then
        fields_of[obj] = nil
        return
    end
    local list = f[key]
    if not list then
        list = {}
        f[key] = list
    end
    list[#list + 1] = entry
    length_of[obj] = n
end

-- world.set(obj, key, value): the first `key = <token>` of obj changed, or added
-- world.token_entry(obj, key) -> the first `key = <token>` entry of obj (the one world.set sets), or nil
function world.token_entry(obj, key)
    for _, e in ipairs(fields(obj)[key] or {}) do
        if e.value.text ~= nil then return e end
    end
    return nil
end

function world.set(obj, key, value)
    local text = type(value) == "number" and number_text(value) or tostring(value)
    if tracking then wrote(obj, "own", key) end
    for _, e in ipairs(fields(obj)[key] or {}) do
        if e.value.text ~= nil then
            e.value.text = text
            return
        end
    end
    local e = { key = { text = key }, op = "=", value = { text = text } }
    obj[#obj + 1] = e
    appended(obj, key, e)
end

-- world.child(obj, key) -> the block of `key = { }` in obj, made if it is not there
function world.child(obj, key)
    local v = world.field(obj, key)
    if type(v) == "table" then
        return v
    end
    local block = {}
    local e = { key = { text = key }, op = "=", value = block }
    obj[#obj + 1] = e
    appended(obj, key, e)
    if tracking then
        owner[block], parent_of[block] = owner[obj], obj
        wrote(obj, "own")
    end
    return block
end

-- world.append(obj, key, value): another `key = value` (a token's text, or a block)
function world.append(obj, key, value, quoted)
    local v = type(value) == "table" and value
        or { text = type(value) == "number" and number_text(value) or tostring(value), quoted = quoted or nil }
    local e = { key = { text = key }, op = "=", value = v }
    obj[#obj + 1] = e
    appended(obj, key, e)
    if tracking then
        if v.text == nil then own(v, owner[obj], obj) end
        wrote(obj, "own")
    end
end

-- world.insert(obj, pos, key, value[, quoted]): `key = value` at position pos of obj (the save's
-- order kept: e.g. a technology after the others)
function world.insert(obj, pos, key, value, quoted)
    local v = type(value) == "table" and value
        or { text = type(value) == "number" and number_text(value) or tostring(value), quoted = quoted or nil }
    table.insert(obj, pos, { key = { text = key }, op = "=", value = v })
    fields_of[obj] = nil
    if tracking then
        if v.text == nil then own(v, owner[obj], obj) end
        wrote(obj, "own")
    end
end

-- world.push(block, value): a bare value at the end of a list block, a token's text or a block (a
-- block given here belongs to block's object from now on)
function world.push(block, value)
    local v = type(value) == "table" and value or { text = tostring(value) }
    block[#block + 1] = v
    if tracking then
        if v.text == nil then own(v, owner[block], block) end
        wrote(block, "own")
    end
end

-- world.append_value(block, text): a bare value at the end of a list block
function world.append_value(block, text, quoted)
    block[#block + 1] = { text = tostring(text), quoted = quoted or nil }
    if tracking then wrote(block, "own") end
end

-- world.remove_value(block, text): a bare value taken out of a list block
function world.remove_value(block, text)
    if tracking then wrote(block, "own") end
    text = tostring(text)
    for i = #block, 1, -1 do
        if block[i].text == text then
            table.remove(block, i)
        end
    end
end

-- world.remove_entry(block, entry): one entry taken out of a block (a statement or a list element)
function world.remove_entry(block, entry)
    if tracking then wrote(block, "own") end
    for i = #block, 1, -1 do
        if block[i] == entry then
            table.remove(block, i)
            fields_of[block] = nil
            return true
        end
    end
    return false
end

-- world.remove(kind, id): the object taken out of its store
function world.remove(kind, id)
    local name = world.KINDS[kind] or kind
    local store, ids = world.stores[name], world.ids[name]
    if store and store[id] then
        if tracking and world.on_write then world.on_write(name, id) end
        store[id] = nil
        -- the save keeps the slot: 'id = none'
        local e = world.entries[name] and world.entries[name][id]
        if e then
            e.value = { text = 'none' }
        end
        for i = #ids, 1, -1 do
            if ids[i] == id then
                table.remove(ids, i)
            end
        end
    end
end

-- world.create(kind, id, block): a new object in its store (and in the save, at the store's end)
-- the writers both worlds have for what modules did to blocks directly (engine.store.world has the
-- same: the main state runs on either)

-- world.replace(block, entries): the block's entries replaced by entries (the pdxscript form)
function world.replace(block, entries)
    local list = {}
    for i, x in ipairs(entries) do list[i] = x end
    for i = #block, 1, -1 do block[i] = nil end
    for i, x in ipairs(list) do block[i] = x end
    fields_of[block] = nil
    if tracking then
        own(block, owner[block], parent_of[block])
        wrote(block, "deep")
    end
end

-- world.append_entry(block, e): an entry of the pdxscript form (a keyed entry, a bare token or block)
-- at the end of the block
function world.append_entry(block, e)
    block[#block + 1] = e
    fields_of[block] = nil
    if tracking then
        local v = e.op and e.value or e
        if type(v) == "table" and v.text == nil then own(v, owner[block], block) end
        wrote(block, "own")
    end
end

-- world.same(a, b): whether a and b are the same block (engine.store.world compares a handle with a
-- table it was made from)
function world.same(a, b)
    return a == b
end

-- world.set_entry(block, e, text): the token of entry e of block (an entry `key = token`, or a bare
-- token, as ipairs gives it) set
function world.set_entry(block, e, value)
    if type(value) == "table" and value.text == nil then
        -- a block: the entry's value
        e.value = value
        if tracking then
            own(value, owner[block], block)
            wrote(block, "own")
        end
        return
    end
    local text = tostring(type(value) == "table" and value.text or value)
    local v = e.op and e.value or e
    if e.op and v.text == nil then e.value = { text = text } else v.text = text end
    if tracking then wrote(block, "own") end
end

-- world.set_text(block, i, text): the token of the block's entry i (1-based) set
function world.set_text(block, i, text)
    local x = block[i]
    local v = x.op and x.value or x
    v.text = tostring(text)
    if x.op then fields_of[block] = nil end
    if tracking then wrote(block, "own") end
end

-- world.set_key(block, i, key): the key of the block's entry i
function world.set_key(block, i, key)
    block[i].key.text = tostring(key)
    fields_of[block] = nil
    if tracking then wrote(block, "own") end
end

-- world.insert_value(block, pos, value): a bare value (a token's text or a block) at position pos
function world.insert_value(block, pos, value)
    local v = type(value) == "table" and value or { text = tostring(value) }
    table.insert(block, pos, v)
    if tracking then
        if v.text == nil then own(v, owner[block], block) end
        wrote(block, "own")
    end
    return v
end

-- world.remove_at(block, i): the block's entry i taken out
function world.remove_at(block, i)
    if tracking then wrote(block, "own") end
    table.remove(block, i)
    fields_of[block] = nil
end

-- world.none_slot(store, index, gen) -> the id of the first `<id> = none` slot of the store whose
-- id is index modulo gen (a freed slot a new object may take), or nil
function world.none_slot(name, index, gen)
    name = world.KINDS[name] or name
    for _, x in ipairs(world.store_blocks[name] or {}) do
        local id = x.op and x.key and tonumber(x.key.text)
        if id and id % gen == index and x.value.text == "none" then return id end
    end
    return nil
end

-- world.place(store, id, old, block, gen) -> the object's block: a freed slot `old = none` becomes
-- the object (the save keeps its place), else the object goes at the end (world.create)
function world.place(name, id, old, block, gen)
    name = world.KINDS[name] or name
    local e
    if old then
        for _, x in ipairs(world.store_blocks[name] or {}) do
            if x.op and x.key and tonumber(x.key.text) == old and x.value.text == "none" then
                e = x
                break
            end
        end
    end
    if not e then return world.create(name, id, block) end
    e.key.text = tostring(id)
    e.value = block
    world.stores[name][id] = block
    world.entries[name][id] = e
    if old ~= id then world.entries[name][old] = nil end
    local ids = world.ids[name]
    ids[#ids + 1] = id
    table.sort(ids, function(x, y) return x % gen < y % gen end)
    fields_of[world.store_blocks[name]] = nil
    world.adopt(name, id, block)
    return block
end

function world.create(kind, id, block)
    local name = world.KINDS[kind] or kind
    local holder = world.store_blocks[name]
    if not holder then
        return nil
    end
    local e = { key = { text = tostring(id) }, op = '=', value = block }
    holder[#holder + 1] = e
    world.stores[name][id] = block
    world.entries[name][id] = e
    world.ids[name][#world.ids[name] + 1] = id
    if tracking then
        object_of[block] = { name, id }
        own(block, block, holder)
        if world.on_write then world.on_write(name, id) end
    end
    return block
end

-- world.write() -> the gamestate's text: the world in the save's form (pdxscript.write)
function world.write()
    return pdxscript.write(world.tree)
end

function world.object(kind, id)
    local store = world.stores[world.KINDS[kind] or kind]
    return store and store[id]
end

function world.all(kind)
    return world.ids[world.KINDS[kind] or kind] or {}
end

-- the relations the script layer walks, from the objects' own fields
function world.index()
    world.planets_of, world.pop_groups_of, world.leaders_of = {}, {}, {}
    -- a colony (the `colony` store) is the colony of the planet whose `colony` field names it; in
    -- 4.5 a pop group's `planet`, a pop job's `planet` and a country's `capital` and
    -- `owned_planets` are colony ids
    world.colony_planet, world.planet_colony = {}, {}
    for _, pid in ipairs(world.all("planet")) do
        local c = tonumber(world.field(world.object("planet", pid), "colony"))
        if c then
            world.colony_planet[c], world.planet_colony[pid] = pid, c
        end
    end
    local function push(t, k, v)
        if k then
            local l = t[k]
            if not l then
                l = {}
                t[k] = l
            end
            l[#l + 1] = v
        end
    end
    for _, id in ipairs(world.all("planet")) do
        push(world.planets_of, tonumber(world.field(world.object("planet", id), "owner")), id)
    end
    for _, id in ipairs(world.all("pop_group")) do
        local colony = tonumber(world.field(world.object("pop_group", id), "planet"))
        push(world.pop_groups_of, colony and world.colony_planet[colony], id)
    end
    for _, id in ipairs(world.all("leader")) do
        push(world.leaders_of, tonumber(world.field(world.object("leader", id), "country")), id)
    end
    -- owners the save does not write on the object: a fleet's is the country whose
    -- fleets_manager.owned_fleets lists it; a system's is its starbase's (starbase -> its station
    -- ship -> that ship's fleet -> the fleet's owner)
    world.fleet_owner, world.system_owner = {}, {}
    for _, cid in ipairs(world.all("country")) do
        local owned = world.path(world.object("country", cid), "fleets_manager", "owned_fleets")
        for _, entry in ipairs(world.blocks(owned)) do
            local fleet = tonumber(world.field(entry, "fleet"))
            if fleet then
                world.fleet_owner[fleet] = cid
            end
        end
    end
    for _, sid in ipairs(world.all("system")) do
        for _, sb in ipairs(world.list(world.field(world.object("system", sid), "starbases"))) do
            local station = tonumber(world.field(world.object("starbase", tonumber(sb)), "station"))
            local fleet = station and tonumber(world.field(world.object("ship", station), "fleet"))
            local owner = fleet and world.fleet_owner[fleet]
            if owner and world.system_owner[sid] == nil then
                world.system_owner[sid] = owner
            end
        end
    end
end

-- the blocks of a list block (`hyperlane = { { to = 1 } { to = 2 } }`)
-- world.statements(block) -> an iterator over block's `key = value` statements: the key's text and
-- the value (a token's text, or a block), in order
function world.statements(block)
    local i = 0
    return function()
        while block do
            i = i + 1
            local e = block[i]
            if e == nil then return nil end
            if e.op and e.key then
                local v = e.value
                return e.key.text, (v.text or v)
            end
        end
        return nil
    end
end

-- world.count(block) -> the number of its entries; world.key(block) -> a key for a cache of
-- something about the block (the block itself here; engine.store.world gives the block's id, as two
-- handles of one block are two values)
function world.count(block)
    return #block
end
function world.key(block)
    return block
end

function world.blocks(block)
    local out = {}
    if type(block) == "table" then
        for _, e in ipairs(block) do
            if not e.text and not e.op then
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- world.summary() -> text
function world.summary()
    local names = {}
    for name in pairs(world.stores) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b) return #world.ids[a] > #world.ids[b] end)
    local parts = {}
    for i = 1, math.min(14, #names) do
        parts[#parts + 1] = names[i] .. " " .. #world.ids[names[i]]
    end
    return string.format("%s, %d stores (%s), parsed in %.1f s", tostring(world.meta.date), #names,
        table.concat(parts, ", "), world.seconds)
end

return world
