-- engine/store/arrays.lua : named typed arrays in the store's raw bytes (docs/data_layer.md, "Typed
-- arrays"): the engine's own state that is not the save's tree (per-object values computed by one
-- phase for another, rule and modifier values, the object tables), shared by every Lua state.
--
-- The registry is a block of the store (root 2): `name = { off = <byte offset> n = <elements> }`.
-- The main thread (in a serial phase) makes and grows arrays; any state reads them. An array that
-- grows moves (its old bytes are left), so readers look it up again each phase (A.ptr).
--
--   local A = require("engine.store.arrays")
--   local p = A.make("sys_flags", "uint8_t", 600)   -- zeroed, at least 600 elements
--   local p, n = A.ptr("sys_flags", "uint8_t")

local ffi = require("ffi")
local S = require("engine.store.core")

local A = {}

local SIZE = {}
local function size_of(ctype)
    local s = SIZE[ctype]
    if not s then
        s = ffi.sizeof(ctype)
        SIZE[ctype] = s
    end
    return s
end

local function registry()
    S.attach()
    local r = S.H.roots[2]
    if r == 0 then
        r = S.new_block(0)
        S.H.roots[2] = r
    end
    return r
end

-- A.make(name, ctype, n[, keep]) -> pointer: a zeroed array of at least n elements (the old one when it is
-- big enough: zeroed again unless keep)
function A.make(name, ctype, n, keep)
    local reg = registry()
    local b = S.blk(reg, name)
    local esz = size_of(ctype)
    if b then
        local off, cap = S.num(b, "off"), S.num(b, "cap")
        if cap >= n then
            local p = ffi.cast(ctype .. " *", S.H.bytes + off)
            if not keep then ffi.fill(p, cap * esz) end
            S.set(b, "n", n)
            return p
        end
        local cap2 = math.max(n, cap * 2)
        local off2 = S.alloc_bytes(cap2 * esz)
        local p = ffi.cast(ctype .. " *", S.H.bytes + off2)
        ffi.fill(p, cap2 * esz)
        if keep then ffi.copy(p, S.H.bytes + off, cap * esz) end
        S.set(b, "off", off2)
        S.set(b, "cap", cap2)
        S.set(b, "n", n)
        return p
    end
    local cap = math.max(n, 16)
    local off = S.alloc_bytes(cap * esz)
    local p = ffi.cast(ctype .. " *", S.H.bytes + off)
    ffi.fill(p, cap * esz)
    b = S.append_block(reg, name)
    S.set(b, "off", off)
    S.set(b, "cap", cap)
    S.set(b, "n", n)
    return p
end

-- A.ptr(name, ctype) -> pointer, n | nil: an array made by A.make
function A.ptr(name, ctype)
    local reg = registry()
    local b = S.blk(reg, name)
    if not b then return nil, 0 end
    return ffi.cast(ctype .. " *", S.H.bytes + S.num(b, "off")), S.num(b, "n")
end

-- ---------------------------------------------------------------------------------------------
-- maps from object ids (the game's ids are dense in some databases, sparse in others: ships and
-- fleets number from high bits): a dense array by id (`<name>`, `missing` where there is no
-- value), or the ids sorted (`<name>#k`) with their values (`<name>#v`), found by halving

-- A.publish_map(name, map[, ctype[, missing]]): an id -> number map (main thread)
function A.publish_map(name, map, ctype, missing)
    ctype = ctype or "double"
    missing = missing or -1
    local keys, max = {}, -1
    for k in pairs(map) do
        if type(k) == "number" and k >= 0 then
            keys[#keys + 1] = k
            if k > max then max = k end
        end
    end
    local reg = registry()
    if max + 1 <= 8 * #keys + 65536 then
        local p = A.make(name, ctype, max + 1)
        for i = 0, max do p[i] = missing end
        for _, k in ipairs(keys) do p[k] = map[k] end
        local b = S.blk(reg, name)
        S.set(b, "sparse", 0)
        S.set(b, "missing", missing)
    else
        table.sort(keys)
        local pk = A.make(name .. "#k", "double", #keys)
        local pv = A.make(name, ctype, #keys)
        for i, k in ipairs(keys) do
            pk[i - 1] = k
            pv[i - 1] = map[k]
        end
        local b = S.blk(reg, name)
        S.set(b, "sparse", 1)
        S.set(b, "missing", missing)
    end
end

-- A.map(name[, ctype]) -> get, p, slot: get(id) the value or nil; p the values; slot(id) the
-- index of id's value in p, or nil (a reader; look it up again each phase)
function A.map(name, ctype)
    ctype = ctype or "double"
    local reg = registry()
    local b = S.blk(reg, name)
    if not b then
        local none = function() return nil end
        return none, nil, none
    end
    local p, n = A.ptr(name, ctype)
    local missing = S.num(b, "missing") or -1
    local slot
    if S.num(b, "sparse") == 1 then
        local pk = A.ptr(name .. "#k", "double")
        slot = function(id)
            if id == nil then return nil end
            local lo, hi = 0, n - 1
            while lo <= hi do
                local mid = math.floor((lo + hi) / 2)
                local k = pk[mid]
                if k == id then return mid end
                if k < id then lo = mid + 1 else hi = mid - 1 end
            end
            return nil
        end
    else
        slot = function(id)
            if id == nil or id < 0 or id >= n then return nil end
            return id
        end
    end
    local function get(id)
        local i = slot(id)
        if i == nil then return nil end
        local v = p[i]
        if v == missing then return nil end
        return v
    end
    return get, p, slot
end

return A
