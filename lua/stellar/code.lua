-- code.lua : byte patterns in the code of the game's functions (lua_sigmatch). The functions are
-- found with fnmatch (stellar.resolve); the patterns are searched inside them, all of a bundle in
-- one run, read with `read` (stellar.read in the game: checked reads).
--
--   local code = require("stellar.code")
--   local patterns = code.bundle(read, image)
--   local gate = patterns:register({ name = "the gate", in_function = update,
--       signature = "c6 05 ?? ?? ?? ?? 00 c6 05 ?? ?? ?? ?? 01" })
--   local report = patterns:run()        -- gate.matches: addresses
--   code.relative(read, gate.address + 2, gate.address + 7) -- the address [rip+x] refers to
--
-- Patterns are sigmatch's: `??` a byte, `?` a nibble, `[0100.100]` bits (`.` any).

local sigmatch = require("sigmatch")

local code = {}

local Bundle = {}
Bundle.__index = Bundle

-- code.bundle(read, image) -> a bundle; register() takes sigmatch's entry spec, with in_function
-- (an address in a function of image) for the region: that function's code
function code.bundle(read, image)
    local target = sigmatch.access_memory_target(sigmatch.reader(function(address, size)
        return read(address, size)
    end))
    return setmetatable({ target = target, image = image, bundle = nil, entries = {} }, Bundle)
end

function Bundle:register(spec)
    if spec.in_function then
        local f = self.image:function_at(spec.in_function)
        if f == nil then
            error(string.format("no function at 0x%x", spec.in_function), 2)
        end
        spec.context = self.target:in_range(f.address, f.end_address - f.address)
        spec.in_function = nil
    end
    if self.bundle == nil then
        -- the default region of entries without one: the first entry's
        self.bundle = sigmatch.bundle(spec.context)
    end
    return self.bundle:register(spec)
end

function Bundle:run()
    return self.bundle:run()
end

-- code.relative(read, at, next) -> the address a 32-bit displacement at `at` refers to, relative to
-- `next` (the end of its instruction), or nil
function code.relative(read, at, next)
    local b = read(at, 4)
    if b == nil or #b < 4 then
        return nil
    end
    local b1, b2, b3, b4 = b:byte(1, 4)
    local v = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
    return next + (v >= 0x80000000 and v - 0x100000000 or v)
end

-- code.byte(read, address) -> the byte at address, or nil
function code.byte(read, address)
    local b = read(address, 1)
    return b and b:byte(1)
end

return code
