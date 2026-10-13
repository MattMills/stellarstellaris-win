-- flags.lua : the script flags' ids, made in the game's order before the databases run in parallel.
--
-- A script flag (set_country_flag = x, has_country_flag = x, ...) has an id, its index in
-- CPdxIntegerFlags::_AllFlagsReverse (a CPdxArray<CString>), given by CPdxIntegerFlags::
-- CreateFlagIndex the first time its name is seen. Databases that run in parallel would see the
-- names in another order and give other ids. A load that runs them one at a time keeps the names
-- in id order (flags.save); a parallel load gives them their ids before its databases start
-- (flags.register), so every id is the game's and no database has to wait for another for them.
--
--   local where = assert(flags.locate(found, read))
--   flags.save(where, path)                      -- after a load in the game's order
--   flags.register(where, assign, flags.load(path))  -- before the databases, in parallel

local ffi = require("ffi")
local fnmatch = require("fnmatch")

local flags = {}

-- the instructions at the start of a function: { address, length, text, flow, target, rip }
local function instructions(read, address, count)
    local out, bytes, pos = {}, read(address, 1024), 1
    while bytes and pos <= #bytes - 15 and #out < count do
        local i = fnmatch.decode(bytes, address, pos)
        if i == nil then
            break
        end
        out[#out + 1] = { address = address + pos - 1, length = i.length, text = i.text, flow = i.flow,
            target = i.target, rip = i.rip_relative }
        pos = pos + i.length
    end
    return out
end

-- flags.locate(found, read) -> where | nil, message: CreateFlagIndex, and _AllFlagsReverse from
-- its code (mov edx, [array + 0x14] (its size); lea rcx, [array])
function flags.locate(found, read)
    local create = found["CPdxIntegerFlags::CreateFlagIndex"]
    if create == nil then
        return nil, "CPdxIntegerFlags::CreateFlagIndex not found"
    end
    local code = instructions(read, create, 200)
    for k = 1, #code - 1 do
        local a, b = code[k], code[k + 1]
        if a.rip and b.rip and a.text:match("^mov edx,") and b.text:match("^lea rcx,") and a.target == b.target + 0x14 then
            return { create = create, names = b.target }
        end
    end
    return nil, "CreateFlagIndex does not name _AllFlagsReverse as in 4.5.2"
end

-- a CString (48 bytes): its text at +16 (inline below 16 bytes, else a pointer), size +32,
-- capacity +40
local function cstring_text(p)
    local size = tonumber(ffi.cast("uint64_t *", p + 32)[0])
    local capacity = tonumber(ffi.cast("uint64_t *", p + 40)[0])
    local text = capacity >= 16 and ffi.cast("const char **", p + 16)[0] or ffi.cast("const char *", p + 16)
    return ffi.string(text, size)
end

-- flags.names(where) -> the flags' names in id order
function flags.names(where)
    local array = ffi.cast("uint8_t *", where.names)
    local data = ffi.cast("uint8_t **", array + 8)[0]
    local size = ffi.cast("int32_t *", array + 0x14)[0]
    local out = {}
    for i = 0, size - 1 do
        out[i + 1] = cstring_text(data + i * 48)
    end
    return out
end

-- flags.save(where, path) -> count | nil: the names in id order, one a line
function flags.save(where, path)
    local f = io.open(path, "wb")
    if f == nil then
        return nil
    end
    local names = flags.names(where)
    for _, name in ipairs(names) do
        f:write(name, "\n")
    end
    f:close()
    return #names
end

-- flags.load(path) -> names | nil (an empty name is a line too: the ids are the line numbers)
function flags.load(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local names = {}
    for line in f:lines() do
        names[#names + 1] = line
    end
    f:close()
    return names
end

-- flags.register(where, assign, names) -> registered, mismatch: each name given its id in order
-- (CreateFlagIndex: the existing ones are found, the others made); mismatch is the first id whose
-- name is not the one expected (nil: every id is the game's). assign is the CString's assign
-- (loader.token_table): one CString holds each name in turn.
function flags.register(where, assign, names)
    local stellar = require("stellar")
    local name = ffi.new("uint8_t[48]")
    ffi.cast("uint64_t *", name + 40)[0] = 15
    local out = ffi.new("uint8_t[16]")
    local done = 0
    local name_address, out_address = tonumber(ffi.cast("uintptr_t", name)), tonumber(ffi.cast("uintptr_t", out))
    for _, text in ipairs(names) do
        if text ~= "" then
            local buffer = ffi.new("char[?]", #text + 1, text)
            stellar.call(assign, name_address, tonumber(ffi.cast("uintptr_t", buffer)), #text)
            stellar.call(where.create, out_address, name_address)
            done = done + 1
        end
    end
    local now = flags.names(where)
    for i, text in ipairs(names) do
        if now[i] ~= text then
            return done, i - 1
        end
    end
    return done, nil
end

return flags
