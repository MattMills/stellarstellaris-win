-- deep.lua : compare two C++ object graphs of the running game (Linux 4.5.2, glibc) without a
-- description of their classes. What the shadow uses for the script parts of an object (trigger
-- trees, script values), whose many classes the prototype does not describe.
--
-- Two heap blocks are compared qword by qword:
--   - equal values are equal (a vtable, a global, a shared object);
--   - a CPdxArray (recognized by its vtable's RTTI name, 9CPdxArray...: vptr, data, capacity,
--     size) is compared by its size and its used elements only (pointer elements followed);
--   - a CString (48 bytes: allocator strategy and frame allocator, then std::string: data pointer,
--     size, local buffer) is compared by its text only;
--   - two different values that both point to heap blocks (the chunk header gives their size) are
--     followed in parallel; a pointer to the same place of two blocks compared together (an
--     object's parent) is the same pointer;
--   - anything else that differs is a mismatch.
-- What still differs is either real or memory the game never wrote (padding, the unused part of a
-- block); shadow runs fill new memory with one pattern (dbbuild: mallopt M_PERTURB, and
-- GLIBC_TUNABLES=glibc.malloc.tcache_count=0 so that every allocation gets it).
--
--   local deep = require("deep")
--   local d = deep.new()                              -- reads /proc/self/maps once
--   local mismatches = d:compare(a, b, size, depth, masks)   -- { "path: a vs b", ... }

local ffi = require("ffi")
local bit = require("bit")

local deep = {}
deep.__index = deep

local function maps()
    local heap, exe = {}, {}
    for line in io.lines("/proc/self/maps") do
        local a, b, perms, rest = line:match("^(%x+)-(%x+) (%S+) %S+ %S+ %S+%s*(.*)$")
        if a then
            if perms:sub(1, 2) == "rw" and (rest == "" or rest == "[heap]") then
                heap[#heap + 1] = { tonumber(a, 16), tonumber(b, 16) }
            elseif rest:match("/stellaris$") then
                exe[#exe + 1] = { tonumber(a, 16), tonumber(b, 16) }
            end
        end
    end
    return heap, exe
end

function deep.new()
    local heap, exe = maps()
    return setmetatable({ ranges = heap, exe = exe, names = {} }, deep)
end

local function in_ranges(ranges, p, n)
    for _, r in ipairs(ranges) do
        if p >= r[1] and p + (n or 1) <= r[2] then
            return r
        end
    end
end

function deep:range(p, n)
    return in_ranges(self.ranges, p, n)
end

-- a heap block at p: its usable size, or nil. From the chunk's header (glibc: the qword before the
-- block, flags in its low 3 bits; usable = chunk size - 8, or - 16 when mmapped), every read checked
-- to stay in a mapping (malloc_usable_size on something that is not a block can fault).
function deep:block(p)
    if p % 16 ~= 0 then
        return nil
    end
    local r = self:range(p - 16, 16)
    if not r then
        return nil
    end
    local hdr = tonumber(ffi.cast("uint64_t *", p - 8)[0])
    local flags = hdr % 8
    local chunk = hdr - flags
    if chunk < 32 or chunk > 1048576 or chunk % 16 ~= 0 then
        return nil
    end
    local n = chunk - (bit.band(flags, 2) ~= 0 and 16 or 8)
    if p + n > r[2] then
        return nil
    end
    return n
end

-- the RTTI name of the class whose vtable v points into (vtable[-1] is the type_info, its name at +8)
function deep:rtti(v)
    local cached = self.names[v]
    if cached ~= nil then
        return cached or nil
    end
    local name = false
    if v % 8 == 0 and in_ranges(self.exe, v - 8, 8) then
        local ti = tonumber(ffi.cast("uint64_t *", v - 8)[0])
        if ti % 8 == 0 and in_ranges(self.exe, ti, 16) then
            local s = tonumber(ffi.cast("uint64_t *", ti + 8)[0])
            if in_ranges(self.exe, s, 1) then
                name = ffi.string(ffi.cast("const char *", s)):sub(1, 200)
            end
        end
    end
    self.names[v] = name
    return name or nil
end

local function q(p, i)
    return ffi.cast("uint64_t *", p)[i]
end
local function i32(p, off)
    return ffi.cast("int32_t *", p + off)[0]
end

-- a CString at p + k? (Linux: +0x10 data, +0x18 size, +0x20 the local buffer when size < 16)
function deep:cstring(p, k, n)
    if k + 48 > n then
        return nil
    end
    local data, size = tonumber(q(p + k, 2)), tonumber(q(p + k, 3))
    if size > 1048576 then
        return nil
    end
    if data == p + k + 0x20 then
        if size >= 16 then
            return nil
        end
    else
        local b = self:block(data)
        if not b or b < size + 1 or size < 16 then
            return nil
        end
    end
    if ffi.cast("uint8_t *", data)[size] ~= 0 then
        return nil
    end
    return ffi.string(ffi.cast("const char *", data), size), tonumber(bit.band(q(p + k, 0), 0xffffffff))
end

function deep:compare(a, b, size, max_depth, masks)
    local out, seen, pairs_seen = {}, {}, {}
    masks = masks or {}
    max_depth = max_depth or 16
    local function same_place(na, nb)
        for _, p in ipairs(pairs_seen) do
            if na >= p[1] and na < p[1] + p[3] and na - p[1] == nb - p[2] then
                return true
            end
        end
        return false
    end
    local walk
    -- every byte that differs is a fill pattern (0xa5 freed, 0x5a new) on one side and zero on the
    -- other: padding next to a smaller member, written by neither constructor
    local function padding(va, vb)
        local seen_diff = false
        for byte = 0, 7 do
            local x = tonumber(bit.band(bit.rshift(va, byte * 8), 0xff))
            local y = tonumber(bit.band(bit.rshift(vb, byte * 8), 0xff))
            if x ~= y then
                seen_diff = true
                local fx, fy = x == 0xa5 or x == 0x5a, y == 0xa5 or y == 0x5a
                -- a bitfield in the low bits of a filled byte: only its bits count (0xa0 vs 0)
                local hx, hy = bit.rshift(x, 4), bit.rshift(y, 4)
                local bx = (hx == 0xa or hx == 0x5) and y == 0 and bit.band(x, 0xf) == 0
                local by = (hy == 0xa or hy == 0x5) and x == 0 and bit.band(y, 0xf) == 0
                if not ((fx and y == 0) or (fy and x == 0) or bx or by) then
                    return false
                end
            end
        end
        return seen_diff
    end
    self.padding = 0
    -- two values at the same place of two graphs
    local function value(va, vb, where, depth)
        if va == vb then
            return
        end
        local na, nb = tonumber(va), tonumber(vb)
        if same_place(na, nb) then
            return
        end
        if padding(va, vb) then
            self.padding = self.padding + 1
            return
        end
        local sa, sb = self:block(na), self:block(nb)
        if sa and sb and depth < max_depth then
            walk(na, nb, math.min(sa, sb), where .. "->", depth + 1)
        else
            out[#out + 1] = string.format("%s: %x vs %x", where, na, nb)
        end
    end
    walk = function(pa, pb, n, path, depth)
        local key = pa .. ":" .. pb
        if seen[key] or #out > 50 then
            return
        end
        seen[key] = true
        pairs_seen[#pairs_seen + 1] = { pa, pb, n }
        -- a polymorphic object: its class (RTTI) in the path
        local cls = n >= 8 and self:rtti(tonumber(q(pa, 0)))
        if cls then
            path = path .. "(" .. cls:gsub("^%d+", "") .. ")"
        end
        local i, count = 0, math.floor(n / 8)
        while i < count do
            local k = i * 8
            local where = string.format("%s+0x%x", path, k)
            local va, vb = q(pa, i), q(pb, i)
            local mask = depth == 0 and masks[k]
            if mask then
                va, vb = bit.band(va, mask), bit.band(vb, mask)
            end
            local name = va == vb and self:rtti(tonumber(va))
            local sa_text, sa_strategy = self:cstring(pa, k, n)
            if name and name:match("^%d+CPdx%a*ArrayI") and k + 24 <= n then
                -- a CPdxArray: data +8, capacity +0x10, size +0x14
                local na_, nb_ = i32(pa, k + 0x14), i32(pb, k + 0x14)
                local inline = tonumber(name:match("^%d+CPdxHybridArrayIcL[ij](%d+)E"))
                if na_ ~= nb_ then
                    out[#out + 1] = string.format("%s: array of %d and %d", where, na_, nb_)
                elseif inline then
                    -- characters (a token's text): the used ones; the inline buffer after the
                    -- header is skipped (what is after the text there is what was read before)
                    local da, db = tonumber(q(pa + k, 1)), tonumber(q(pb + k, 1))
                    local ta = ffi.string(ffi.cast("const char *", da), math.max(na_, 0))
                    local tb = ffi.string(ffi.cast("const char *", db), math.max(nb_, 0))
                    if ta ~= tb then
                        out[#out + 1] = string.format("%s: text %q vs %q", where, ta, tb)
                    end
                    if da == pa + k + 24 then
                        i = i + math.ceil(inline / 8)
                    end
                elseif na_ > 0 then
                    local da, db = tonumber(q(pa + k, 1)), tonumber(q(pb + k, 1))
                    local pointers = name:match("^%d+CPdx%a*ArrayIP") ~= nil
                    if pointers then
                        for e = 0, na_ - 1 do
                            value(q(da, e), q(db, e), string.format("%s[%d]", where, e), depth + 1)
                        end
                    else
                        -- elements of another kind: the used part of their block, as raw qwords
                        -- (the element size taken as the block's size over the capacity)
                        local ba, bb = self:block(da), self:block(db)
                        local cap = i32(pa, k + 0x10)
                        if ba and bb and cap > 0 then
                            local elem = math.floor(math.min(ba, bb) / cap / 8) * 8
                            walk(da, db, math.min(ba, bb, elem * na_), where .. "[]", depth + 1)
                        end
                    end
                end
                i = i + 3
            elseif sa_text then
                local sb_text, sb_strategy = self:cstring(pb, k, n)
                if sb_text == nil then
                    out[#out + 1] = string.format("%s: string %q vs not a string", where, sa_text)
                elseif sa_text ~= sb_text or sa_strategy ~= sb_strategy then
                    out[#out + 1] = string.format("%s: string %q vs %q", where, sa_text, sb_text)
                end
                i = i + 6
            else
                value(va, vb, where, depth)
                i = i + 1
            end
        end
    end
    local na, nb = tonumber(ffi.cast("uintptr_t", a)), tonumber(ffi.cast("uintptr_t", b))
    walk(na, nb, size or self:block(na) or 8, "", 0)
    return out
end

return deep
