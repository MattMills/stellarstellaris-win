-- memory.lua : reading the game's data structures from Lua with checked reads.
--
-- `read` is a function(address, size) -> string | nil, message (stellar.read in the game, or a
-- reader of an executable file outside it). Values are decoded from the strings it returns, so a
-- wrong pointer gives an error or a wrong value, never a crash.

local memory = {}

function memory.u8(s, o)
    return s:byte(o + 1)
end

function memory.i32(s, o)
    local b1, b2, b3, b4 = s:byte(o + 1, o + 4)
    local v = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
    return v >= 0x80000000 and v - 0x100000000 or v
end

function memory.u32(s, o)
    local v = memory.i32(s, o)
    return v < 0 and v + 0x100000000 or v
end

-- addresses are below 2^53, exact as Lua numbers
function memory.u64(s, o)
    return memory.u32(s, o) + memory.u32(s, o + 4) * 0x100000000
end

-- A reader that raises errors, from one that returns nil, message.
function memory.strict(read)
    return function(address, size)
        local bytes, message = read(address, size)
        if bytes == nil then
            error(message or string.format("cannot read %d bytes at 0x%x", size, address), 0)
        end
        return bytes
    end
end

-- A NUL-terminated string, read up to page boundaries (the page after it may not be mapped).
function memory.cstring(read, address, max)
    max = max or 256
    local parts, length = {}, 0
    while length < max do
        local n = math.min(max - length, 4096 - (address + length) % 4096)
        local s = read(address + length, n)
        if s == nil then
            break
        end
        local nul = s:find("\0", 1, true)
        if nul then
            parts[#parts + 1] = s:sub(1, nul - 1)
            break
        end
        parts[#parts + 1] = s
        length = length + n
    end
    return table.concat(parts)
end

-- A CString (std::basic_string with a 16-byte allocator, 48 bytes): the text at +16, inline when
-- the capacity (+40) is below 16, else behind a pointer; the size at +32.
function memory.cstring_object(read, address)
    local b = read(address, 48)
    if b == nil then
        return nil
    end
    local size, capacity = memory.u64(b, 32), memory.u64(b, 40)
    if size == 0 then
        return ""
    elseif size > 1000000 or capacity < size then
        return nil
    elseif capacity < 16 then
        return b:sub(17, 16 + size)
    end
    return read(memory.u64(b, 16), size)
end

-- A CPdxArray<T *, int> (vtable, T **_pData at +8, int _nCapacity at +16, int _nSize at +20): its
-- pointers, or nil.
function memory.pointer_array(read, address, max)
    local b = read(address, 24)
    if b == nil then
        return nil
    end
    local data, size = memory.u64(b, 8), memory.i32(b, 20)
    if size < 0 or size > (max or 1000000) then
        return nil
    end
    local list = {}
    if size > 0 then
        local pointers = read(data, size * 8)
        if pointers == nil then
            return nil
        end
        for i = 0, size - 1 do
            list[i + 1] = memory.u64(pointers, i * 8)
        end
    end
    return list
end

-- A CPdxArray<std::pair<CString, CString>, int> (vtable, _pData at +8, _nSize at +20; pairs of two
-- 48-byte strings): its pairs as { first, second }, or nil.
function memory.string_pairs(read, address, max)
    local b = read(address, 24)
    if b == nil then
        return nil
    end
    local data, size = memory.u64(b, 8), memory.i32(b, 20)
    if size < 0 or size > (max or 10000) then
        return nil
    end
    local list = {}
    for i = 0, size - 1 do
        local first = memory.cstring_object(read, data + i * 96)
        local second = memory.cstring_object(read, data + i * 96 + 48)
        if first == nil or second == nil then
            return nil
        end
        list[#list + 1] = { first, second }
    end
    return list
end

return memory
