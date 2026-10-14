-- engine/store/core.lua : the shared store's records through the FFI (docs/data_layer.md).
--
-- The store is plain memory that the Rust side allocates once (sim/src/store.rs) and every Lua
-- state of the process maps: the main state and the workers (sim/src/workers.rs). A save's tree
-- (and the definitions) are held there as entries and blocks:
--
--   entry  16 bytes: key (string id; 0 for a list's bare value), kind (TEXT, NUMBER, BLOCK, COND),
--          op (1 '=' 2 '==' 3 '!=' 4 '<' 5 '>' 6 '<=' 7 '>=' 8 '?='; 0 a bare value), flags (1 the
--          key quoted, 2 the value quoted, 4 a negated condition), and the value: a string id
--          (v.u.a), a number (v.num, written by the engine), or a block id (v.u.a, with the typed
--          block's tag in v.u.b)
--   block  16 bytes: first (its first entry), count, cap (entries reserved from first), index
--          (its key index in the index region, 0 when it has none)
--
-- A block's entries are contiguous: reading an object is a walk over consecutive 16-byte records.
-- Every block with statements carries a key index (two-choice hashing, key id -> the position of
-- the key's first entry: two probes, no loop, so callers' loops stay compiled); lists share an
-- empty one. Strings are interned once for the process (store.rs, under a lock); each Lua state
-- caches id <-> string in its own tables.
--
-- Allocation is a bump in chunks reserved atomically from the store, so each state (each worker
-- in a parallel phase) allocates in its own chunk: a block that grows past its capacity moves to
-- new entries of the state that grew it (the old ones are left; the store is never compacted while
-- it runs).
--
--   local S = require("engine.store.core")
--   S.attach()                         -- RUST.store()
--   local root = S.build(tree)         -- a pdxscript tree into the store
--   S.write(root) == pdxscript.write(tree)

local ffi = require("ffi")
local bit = require("bit")
local band, bor = bit.band, bit.bor

ffi.cdef [[
typedef struct pdx_entry {
    uint32_t key;
    uint8_t kind, op, flags, pad;
    union { struct { uint32_t a, b; } u; double num; } v;
} pdx_entry;
typedef struct pdx_block { uint32_t first, count, cap, index; } pdx_block;
typedef struct pdx_store {
    pdx_entry *entries; uint32_t n_entries, cap_entries;
    pdx_block *blocks; uint32_t n_blocks, cap_blocks;
    uint32_t *index; uint32_t n_index, cap_index;
    uint8_t *str_bytes; uint32_t *str_off; uint32_t *str_len;
    uint32_t n_str, cap_str, n_str_bytes, cap_str_bytes;
    uint8_t *bytes; uint64_t n_bytes, cap_bytes;
    uint32_t (*reserve)(struct pdx_store *, uint32_t, uint32_t);
    uint64_t (*reserve_bytes)(struct pdx_store *, uint64_t);
    uint32_t (*intern)(struct pdx_store *, const char *, size_t);
    uint32_t (*lookup)(struct pdx_store *, const char *, size_t);
    void *interner;
    uint64_t (*fetch_add)(struct pdx_store *, uint32_t, uint64_t);
    uint32_t roots[64];
    uint64_t counters[64];
} pdx_store;
]]

local S = {}

local TEXT, NUMBER, BLOCK, COND = 1, 2, 3, 4
S.TEXT, S.NUMBER, S.BLOCK, S.COND = TEXT, NUMBER, BLOCK, COND
local OPS = { ["="] = 1, ["=="] = 2, ["!="] = 3, ["<"] = 4, [">"] = 5, ["<="] = 6, [">="] = 7, ["?="] = 8 }
local OP_TEXT = { "=", "==", "!=", "<", ">", "<=", ">=", "?=" }
S.OPS, S.OP_TEXT = OPS, OP_TEXT
local FULL = 4294967295
local CHUNK_E, CHUNK_B, CHUNK_I = 65536, 16384, 16384

local H, E, B, IX           -- the header and the regions (they never move)
local STR, SID, NUM, NEG = {}, {}, {}, {}
S.STR = STR

-- S.attach([ptr]) -> S: the store (RUST.store() by default)
function S.attach(ptr)
    if H then return S end
    ptr = ptr or RUST.store()
    H = ffi.cast("pdx_store *", ptr)
    E, B, IX = H.entries, H.blocks, H.index
    S.H, S.E, S.B, S.IX = H, E, B, IX
    return S
end

-- S.serial: whether this state may build key indexes lazily (the main thread in a serial phase;
-- workers read blocks without one by a scan)
S.serial = true

-- ---------------------------------------------------------------------------------------------
-- strings

local function str(id)
    local s = STR[id]
    if s == nil then
        s = ffi.string(H.str_bytes + H.str_off[id], H.str_len[id])
        STR[id] = s
        SID[s] = id
    end
    return s
end
S.str = str

-- the id of a string, interned if new
local function sid(s)
    local id = SID[s]
    if id == nil then
        id = H.intern(H, s, #s)
        if id == FULL then error("the store's strings are full") end
        SID[s] = id
        STR[id] = s
    end
    return id
end
S.id = sid

-- the id of a key, or nil when no such string was ever interned (nothing has that key)
local function kid(s)
    local id = SID[s]
    if id ~= nil then return id end
    local n = H.n_str
    if NEG[s] == n then return nil end
    id = H.lookup(H, s, #s)
    if id == 0 and s ~= "" then
        NEG[s] = n
        return nil
    end
    SID[s] = id
    STR[id] = s
    return id
end
S.kid = kid

-- the number a text reads as (tonumber), or false
local function num_of(id)
    local n = NUM[id]
    if n == nil then
        n = tonumber(str(id)) or false
        NUM[id] = n
    end
    return n
end
S.num_of = num_of

-- a number as the save writes it (world.number_text: 5 decimals, the zeros dropped)
local function number_text(v)
    if v == math.floor(v) then
        return string.format("%d", v)
    end
    return (string.format("%.5f", v):gsub("0+$", ""))
end
S.number_text = number_text

-- ---------------------------------------------------------------------------------------------
-- allocation (per state, in chunks)

local e_lo, e_hi, b_lo, b_hi, i_lo, i_hi = 0, 0, 0, 0, 0, 0
local function reserve(region, n)
    local f = H.reserve(H, region, n)
    if f == FULL then error("the store is full (region " .. region .. ")") end
    return f
end
local function alloc_entries(n)
    if n == 0 then return 0 end
    if n > 4096 then return reserve(0, n) end
    if e_lo + n > e_hi then
        e_lo = reserve(0, CHUNK_E)
        e_hi = e_lo + CHUNK_E
    end
    local f = e_lo
    e_lo = e_lo + n
    return f
end
local function alloc_block()
    if b_lo >= b_hi then
        b_lo = reserve(1, CHUNK_B)
        b_hi = b_lo + CHUNK_B
    end
    local f = b_lo
    b_lo = b_lo + 1
    return f
end
local function alloc_index(n)
    if n > 4096 then return reserve(2, n) end
    if i_lo + n > i_hi then
        i_lo = reserve(2, CHUNK_I)
        i_hi = i_lo + CHUNK_I
    end
    local f = i_lo
    i_lo = i_lo + n
    return f
end
-- n bytes of the raw region (8-aligned): the offset
function S.alloc_bytes(n)
    local off = H.reserve_bytes(H, n)
    if off == ffi.cast("uint64_t", -1) then error("the store's bytes are full") end
    return tonumber(off)
end
function S.bytes_ptr(off, ctype)
    return ffi.cast(ctype or "uint8_t *", H.bytes + off)
end

-- S.new_block([cap]) -> a new empty block's id
local function new_block(cap)
    local bid = alloc_block()
    local b = B[bid]
    cap = cap or 0
    b.first = alloc_entries(cap)
    b.count = 0
    b.cap = cap
    b.index = 0
    return bid
end
S.new_block = new_block

-- ---------------------------------------------------------------------------------------------
-- key indexes: IX[ix] = mask; slots IX[ix + 1 + 2 h] = key id (0 empty), IX[ix + 2 + 2 h] = the
-- position of the key's first entry in the block. Two-choice (cuckoo) hashing: a key is in its
-- first slot (key & mask) or its second, so a lookup is two probes and no loop (a loop in it would
-- stop LuaJIT from compiling the caller's loop through it: "inner loop in root trace"). A block
-- whose entries are all bare values shares EMPTY_IX (every lookup misses at once).

local tobit, rshift = bit.tobit, bit.rshift
local function slot1(k, mask) return band(k, mask) end
local function slot2(k, mask) return band(rshift(tobit(k * 40503), 5), mask) end

local EMPTY_IX
local function empty_ix()
    if not EMPTY_IX then
        EMPTY_IX = alloc_index(3)
        IX[EMPTY_IX], IX[EMPTY_IX + 1], IX[EMPTY_IX + 2] = 0, 0, 0
    end
    return EMPTY_IX
end

-- key at pos into index ix (unless the key is there: the first entry stays); false when it does
-- not fit (the index is to be built bigger)
local function index_add(ix, key, pos)
    local mask = IX[ix]
    if IX[ix + 1 + 2 * slot1(key, mask)] == key or IX[ix + 1 + 2 * slot2(key, mask)] == key then
        return true
    end
    local h = slot1(key, mask)
    for _ = 1, 64 do
        local s = ix + 1 + 2 * h
        local ok, op = IX[s], IX[s + 1]
        IX[s], IX[s + 1] = key, pos
        if ok == 0 then return true end
        key, pos = ok, op
        local a = slot1(key, mask)
        if h == a then h = slot2(key, mask) else h = a end
    end
    return false
end

-- the index a block had when a write dropped it (its entries moved: insert, remove, clear): built
-- again in the same slots when its keys still fit, so that a block written over and over does not
-- take new index slots each time
local stale_ix = {}
local function drop_index(bid)
    local b = B[bid]
    local ix = b.index
    if ix ~= 0 and ix ~= EMPTY_IX then stale_ix[bid] = ix end
    b.index = 0
end
S.drop_index = drop_index

local function build_index(bid)
    local b = B[bid]
    local old = stale_ix[bid]
    if old then
        stale_ix[bid] = nil
        return S.rebuild_index(bid, old)
    end
    local n, first = b.count, b.first
    local keys = 0
    for p = 0, n - 1 do
        if E[first + p].op ~= 0 then keys = keys + 1 end
    end
    if keys == 0 then
        b.index = empty_ix()
        return b.index
    end
    local size = 4
    while size < 4 * keys do size = size * 2 end
    while true do
        local ix = alloc_index(1 + 2 * size)
        IX[ix] = size - 1
        for s = ix + 1, ix + 2 * size do IX[s] = 0 end
        local ok = true
        for p = 0, n - 1 do
            local e = E[first + p]
            if e.op ~= 0 and e.key ~= 0 and not index_add(ix, e.key, p) then
                ok = false
                break
            end
        end
        if ok then
            b.index = ix
            return ix
        end
        size = size * 2
    end
end
S.build_index = build_index

-- S.rebuild_index(bid, ix): block bid's key index built again in ix, an index it had (cleared and
-- refilled when its keys still fit at build_index's load), else a new one (engine.store.full, after
-- a block's entries were written again)
function S.rebuild_index(bid, ix)
    if ix and ix ~= 0 and ix ~= EMPTY_IX then
        local b = B[bid]
        local size = IX[ix] + 1
        local keys = 0
        for p = 0, b.count - 1 do
            if E[b.first + p].op ~= 0 then keys = keys + 1 end
        end
        if keys > 0 and 4 * keys <= size then
            for s = ix + 1, ix + 2 * size do IX[s] = 0 end
            local ok = true
            for p = 0, b.count - 1 do
                local e = E[b.first + p]
                if e.op ~= 0 and e.key ~= 0 and not index_add(ix, e.key, p) then
                    ok = false
                    break
                end
            end
            if ok then
                b.index = ix
                return ix
            end
        end
    end
    return build_index(bid)
end

local scan
-- the first entry of key k (an id) in block bid, or nil
local function find(bid, k)
    local b = B[bid]
    local ix = b.index
    if ix ~= 0 then
        local mask = IX[ix]
        local s = ix + 1 + 2 * band(k, mask)
        if IX[s] == k then return b.first + IX[s + 1] end
        s = ix + 1 + 2 * band(rshift(tobit(k * 40503), 5), mask)
        if IX[s] == k then return b.first + IX[s + 1] end
        return nil
    end
    return scan(bid, k)
end
S.find = find

-- a block without an index: built (in a serial phase), or scanned (a worker: blocks are read by
-- others while their owner may change them, so only the owner builds what it changed)
function scan(bid, k)
    if S.serial then
        build_index(bid)
        return find(bid, k)
    end
    local b = B[bid]
    for i = b.first, b.first + b.count - 1 do
        if E[i].key == k and E[i].op ~= 0 then return i end
    end
    return nil
end

-- the next entry of key k after entry i in block bid, or nil
local function find_next(bid, k, i)
    local b = B[bid]
    local last = b.first + b.count - 1
    for j = i + 1, last do
        if E[j].key == k then return j end
    end
    return nil
end
S.find_next = find_next

-- ---------------------------------------------------------------------------------------------
-- values

-- the value of entry i as world.field gives it: a number when it reads as one, else the text; for
-- a block its id (as a number: callers that need to tell a block from a number use S.kind)
local function token(i)
    local e = E[i]
    local k = e.kind
    if k == NUMBER then return e.v.num end
    if k == TEXT then
        local id = e.v.u.a
        local n = NUM[id]
        if n == nil then n = num_of(id) end
        if n then return n end
        return STR[id] or str(id)
    end
    return nil
end
S.token = token

-- the text of a token entry (as written in the save)
local function text(i)
    local e = E[i]
    if e.kind == NUMBER then return number_text(e.v.num) end
    if e.kind == TEXT then return STR[e.v.u.a] or str(e.v.u.a) end
    return nil
end
S.text = text

function S.kind(i) return E[i].kind end
function S.block_of(i)
    local e = E[i]
    if e.kind == BLOCK then return e.v.u.a end
    return nil
end

-- typed reads of block bid's first `key`: a token's value (number or text), a block's id, a
-- number, a text
function S.val(bid, key)
    local k = kid(key)
    local i = k and find(bid, k)
    return i and token(i)
end
function S.blk(bid, key)
    local k = kid(key)
    local i = k and find(bid, k)
    if not i then return nil end
    local e = E[i]
    if e.kind == BLOCK then return e.v.u.a end
    return nil
end
function S.num(bid, key)
    local k = kid(key)
    local i = k and find(bid, k)
    if not i then return nil end
    local e = E[i]
    if e.kind == NUMBER then return e.v.num end
    if e.kind == TEXT then return num_of(e.v.u.a) or nil end
    return nil
end
function S.txt(bid, key)
    local k = kid(key)
    local i = k and find(bid, k)
    return i and text(i)
end

-- the bare numbers of a list block (`{ 1 2 3 }`), as a Lua array
function S.numbers(bid)
    local out, n = {}, 0
    if not bid then return out end
    local b = B[bid]
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        if e.op == 0 then
            local k = e.kind
            if k == TEXT then
                local v = num_of(e.v.u.a)
                if v then n = n + 1; out[n] = v end
            elseif k == NUMBER then
                n = n + 1; out[n] = e.v.num
            end
        end
    end
    return out
end

function S.count(bid) return B[bid].count end
function S.first(bid) return B[bid].first end

-- ---------------------------------------------------------------------------------------------
-- writes

-- room for one more entry at the end of block bid: the block moves to new entries when it is full
local function grow(bid, need)
    local b = B[bid]
    local n = b.count
    if n + need <= b.cap then return end
    local cap = b.cap * 2
    if cap < 4 then cap = 4 end
    while cap < n + need do cap = cap * 2 end
    local first = alloc_entries(cap)
    ffi.copy(E + first, E + b.first, n * 16)
    b.first = first
    b.cap = cap
end

-- a new entry at the end of block bid: its index
local function push(bid, key, op)
    grow(bid, 1)
    local b = B[bid]
    local i = b.first + b.count
    local e = E[i]
    e.key = key
    e.op = op
    e.flags = 0
    e.pad = 0
    b.count = b.count + 1
    local ix = b.index
    if ix ~= 0 and op ~= 0 then
        if ix == EMPTY_IX or 2 * b.count > IX[ix] + 1 or not index_add(ix, key, b.count - 1) then
            b.index = 0   -- too full, or a list's shared empty index: built again when next needed
        end
    end
    return i
end

-- entry i set to the token `value` (a number as the engine writes it, or a text)
local function set_value(i, value, quoted)
    local e = E[i]
    if type(value) == "number" then
        if value == math.floor(value) and value > -9007199254740992 and value < 9007199254740992 then
            e.kind = NUMBER
            e.v.num = value
        else
            local t = number_text(value)
            if t:sub(-1) == "." then
                e.kind = TEXT
                e.v.u.a = sid(t)
                e.v.u.b = 0
            else
                e.kind = NUMBER
                e.v.num = tonumber(t)
            end
        end
    else
        e.kind = TEXT
        e.v.u.a = sid(tostring(value))
        e.v.u.b = 0
    end
    if quoted ~= nil then
        e.flags = quoted and bor(band(e.flags, 1), 2) or band(e.flags, 1)
    end
end
S.set_value = set_value

-- S.set(bid, key, value): the first `key = <token>` changed, or appended (world.set)
function S.set(bid, key, value)
    local k = sid(key)
    local i = find(bid, k)
    while i do
        local kind = E[i].kind
        if kind == TEXT or kind == NUMBER then
            set_value(i, value)
            return i
        end
        i = find_next(bid, k, i)
    end
    i = push(bid, k, 1)
    set_value(i, value, false)
    return i
end

-- S.append(bid, key, value[, quoted]): another `key = value` (a number or a text) at the end
function S.append(bid, key, value, quoted)
    local i = push(bid, sid(key), 1)
    set_value(i, value, quoted or false)
    return i
end

-- S.append_block(bid, key[, child]) -> the child block's id: `key = { }` at the end
function S.append_block(bid, key, child)
    child = child or new_block(0)
    local i = push(bid, key and sid(key) or 0, key and 1 or 0)
    local e = E[i]
    e.kind = BLOCK
    e.v.u.a = child
    e.v.u.b = 0
    return child, i
end

-- S.append_entry(bid, i): a copy of entry i's record at the end of block bid (the same key and
-- value: a block value is shared, not copied)
function S.append_entry(bid, i)
    grow(bid, 1)
    local b = B[bid]
    ffi.copy(E + b.first + b.count, E + i, 16)
    b.count = b.count + 1
    drop_index(bid)
    return b.first + b.count - 1
end

-- S.append_value(bid, value[, quoted]): a bare value at the end of a list block
function S.append_value(bid, value, quoted)
    local i = push(bid, 0, 0)
    set_value(i, value, quoted or false)
    return i
end

-- S.insert_at(bid, pos, key, value[, quoted]) -> the entry: `key = value` at position pos (1 is
-- the first); value a number, a text, or { block = id }
function S.insert_at(bid, pos, key, value, quoted)
    grow(bid, 1)
    local b = B[bid]
    local n = b.count
    if pos > n + 1 then pos = n + 1 end
    local at = b.first + pos - 1
    if pos <= n then
        ffi.copy(E + at + 1, E + at, (n - pos + 1) * 16)
    end
    b.count = n + 1
    drop_index(bid)
    local e = E[at]
    e.key = key ~= nil and sid(key) or 0   -- (nil: a bare value)
    e.op = key ~= nil and 1 or 0
    e.flags = 0
    e.pad = 0
    if type(value) == "table" then
        e.kind = BLOCK
        e.v.u.a = value.block
        e.v.u.b = 0
    else
        set_value(at, value, quoted or false)
    end
    return at
end

-- S.remove_at(bid, i): entry i taken out of block bid (the others keep their order)
function S.remove_at(bid, i)
    local b = B[bid]
    local last = b.first + b.count - 1
    if i < b.first or i > last then return false end
    if i < last then
        ffi.copy(E + i, E + i + 1, (last - i) * 16)
    end
    b.count = b.count - 1
    drop_index(bid)
    return true
end

-- S.clear(bid): no entries (the capacity kept)
function S.clear(bid)
    local b = B[bid]
    b.count = 0
    drop_index(bid)
end

-- S.set_numbers(bid, values): the block's entries are the bare values `values` (numbers)
function S.set_numbers(bid, values)
    local b = B[bid]
    local n = #values
    b.count = 0
    drop_index(bid)
    grow(bid, n)
    local first = b.first
    for j = 1, n do
        local e = E[first + j - 1]
        e.key = 0
        e.op = 0
        e.flags = 0
        e.pad = 0
        e.kind = NUMBER
        e.v.num = values[j]
    end
    b.count = n
end

-- ---------------------------------------------------------------------------------------------
-- a pdxscript tree into the store, and back to text

-- S.build(tree) -> the block id of a pdxscript block (a tree, or any block in it)
local function build(t)
    local n = #t
    local bid = new_block(n)
    local first = B[bid].first
    for j = 1, n do
        local x = t[j]
        local e = E[first + j - 1]
        e.pad = 0
        if x.op then
            e.key = sid(x.key.text)
            e.op = OPS[x.op]
            local flags = x.key.quoted and 1 or 0
            local v = x.value
            if v.text then
                e.kind = TEXT
                e.v.u.a = sid(v.text)
                e.v.u.b = 0
                if v.quoted then flags = flags + 2 end
            else
                e.kind = BLOCK
                e.v.u.a = build(v)
                e.v.u.b = v.type and sid(v.type) or 0
            end
            e.flags = flags
        elseif x.text then
            e.key = 0
            e.op = 0
            e.kind = TEXT
            e.v.u.a = sid(x.text)
            e.v.u.b = 0
            e.flags = x.quoted and 2 or 0
        elseif x.param then
            e.key = sid(x.param)
            e.op = 0
            e.kind = COND
            e.v.u.a = build(x)
            e.v.u.b = 0
            e.flags = x.negated and 4 or 0
        else
            e.key = 0
            e.op = 0
            e.kind = BLOCK
            e.v.u.a = build(x)
            e.v.u.b = x.type and sid(x.type) or 0
            e.flags = 0
        end
    end
    B[bid].count = n
    build_index(bid)
    return bid
end
S.build = build

-- S.write(bid) -> text: the block as pdxscript.write writes the same tree (byte for byte)
function S.write(root)
    local out, n, chunks = {}, 0, {}
    local entries
    local function token_text(i)
        local e = E[i]
        local s = text(i)
        if band(e.flags, 2) ~= 0 then return '"' .. s .. '"' end
        return s
    end
    local function value(i, indent)
        local e = E[i]
        if e.kind ~= BLOCK then
            n = n + 1
            out[n] = token_text(i)
            return
        end
        local bid = e.v.u.a
        if e.v.u.b ~= 0 then
            n = n + 1
            out[n] = str(e.v.u.b) .. " "
        end
        local b = B[bid]
        local first, count = b.first, b.count
        local flat = true
        for j = first, first + count - 1 do
            local c = E[j]
            if c.op ~= 0 or (c.kind ~= TEXT and c.kind ~= NUMBER) then
                flat = false
                break
            end
        end
        if flat then
            n = n + 1
            out[n] = "{"
            for j = first, first + count - 1 do
                n = n + 1
                out[n] = " " .. token_text(j)
            end
            n = n + 1
            out[n] = " }"
        else
            n = n + 1
            out[n] = "{\n"
            entries(bid, indent .. "\t")
            n = n + 1
            out[n] = indent .. "}"
        end
    end
    function entries(bid, indent)
        local b = B[bid]
        for j = b.first, b.first + b.count - 1 do
            local e = E[j]
            n = n + 1
            out[n] = indent
            if e.op ~= 0 then
                n = n + 1
                local k = str(e.key)
                if band(e.flags, 1) ~= 0 then k = '"' .. k .. '"' end
                out[n] = k .. " " .. OP_TEXT[e.op] .. " "
                value(j, indent)
            elseif e.kind == COND then
                n = n + 1
                out[n] = "[[" .. (band(e.flags, 4) ~= 0 and "!" or "") .. str(e.key) .. "]\n"
                entries(e.v.u.a, indent .. "\t")
                n = n + 1
                out[n] = indent .. "]"
            else
                value(j, indent)
            end
            n = n + 1
            out[n] = "\n"
            if n > 100000 then
                chunks[#chunks + 1] = table.concat(out, "", 1, n)
                n = 0
            end
        end
    end
    entries(root, "")
    chunks[#chunks + 1] = table.concat(out, "", 1, n)
    return table.concat(chunks)
end

-- S.usage() -> text: what the store holds
function S.usage()
    return string.format("%d entries (%.0f MB), %d blocks, %d index slots, %d strings (%.1f MB), %.1f MB of bytes",
        H.n_entries, H.n_entries * 16 / 1048576, H.n_blocks, H.n_index, H.n_str, H.n_str_bytes / 1048576,
        tonumber(H.n_bytes) / 1048576)
end

-- ---------------------------------------------------------------------------------------------
-- a block handle walked the way engine.world's tables are (the engine's code on a worker:
-- engine.store.worker, docs/data_layer.md section 12): ipairs(h) gives each entry as a table of
-- pdxscript's form, made for the walk (changing it changes nothing in the store), #h is the number of
-- entries, and a field a block record does not have (.text, .op, .key, .value) reads nil. A block in
-- an entry is a handle again, or the Lua table a worker holds for it (S.block_value, set by
-- engine.store.world).
-- entry i (of block bid, its j-th) as the pdxscript form; _b and _p (the block, the position) let
-- the world's writers find it again (engine.store.world: set_entry, remove_entry)
local function entry_table(i, bid, j)
    local e = E[i]
    local v
    if e.kind == BLOCK then
        v = S.block_value(e.v.u.a)
    else
        v = { text = text(i), quoted = band(e.flags, 2) ~= 0 or nil, _b = bid, _p = j }
    end
    if e.op ~= 0 then
        return { key = { text = str(e.key), quoted = band(e.flags, 1) ~= 0 or nil }, op = OP_TEXT[e.op], value = v, _b = bid, _p = j }
    end
    return v
end
S.entry_table = entry_table
-- a block handle (engine.store.world): a struct holding the block's pointer, so that h[i], #h,
-- ipairs(h) and == go through these metamethods (a number index on a pointer would be pointer
-- arithmetic: the record of another block)
ffi.cdef("typedef struct { pdx_block *p; } pdx_handle;")
S.handle_t = ffi.typeof("pdx_handle")
local function next_entry(h, j)
    j = j + 1
    local b = h.p
    if j > b.count then return nil end
    return j, entry_table(b.first + j - 1, tonumber(b - B), j)
end
ffi.metatype("pdx_handle", {
    -- h[k]: entry k as a read-only view (a table of the pdxscript form: changing it changes nothing;
    -- the world's writers change the store), nil for anything else
    __index = function(h, k)
        if type(k) == "number" then
            local b = h.p
            if k >= 1 and k <= b.count then return entry_table(b.first + k - 1, tonumber(b - B), k) end
        end
        return nil
    end,
    __len = function(h) return h.p.count end,
    __ipairs = function(h) return next_entry, h, 0 end,
    __pairs = function(h) return next_entry, h, 0 end,
    __eq = function(a, b) return ffi.istype(S.handle_t, a) and ffi.istype(S.handle_t, b) and a.p == b.p end,
    __tostring = function(h) return "block " .. tonumber(h.p - B) end,
})
S.block_value = function(a) return S.handle_t(B + a) end

return S
