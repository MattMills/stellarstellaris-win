-- graph/buffer.lua : growable typed arrays outside the Lua heap, for stellar.graph.
--
-- The graph keeps its nodes and edges in flat arrays (structure of arrays). They are allocated
-- with malloc, not ffi.new, so that a large graph (millions of nodes) does not count against the
-- garbage-collected heap. They grow by a new allocation, the old elements copied and the new ones
-- zeroed a quarter of a megabyte at a time, with the simulation's engine.slice tick between (a
-- phase run in pieces may stop in a large array's growth, which one realloc and fill could not;
-- sim docs/frame_timing.md). New elements are zero.
--
--   local buffer = require("stellar.graph.buffer")
--   local a = buffer.new("double", 1024)        -- double[1024], zeroed
--   a = buffer.grow(a, "double", 1024, 4096)    -- the old pointer is invalid afterwards
--   buffer.free(a)

local ffi = require("ffi")

local M = {}

pcall(ffi.cdef, [[
    void *malloc(size_t size);
    void *realloc(void *p, size_t size);
    void free(void *p);
]])
local C = ffi.C

local tick = (function()
    local ok, slice = pcall(require, "engine.slice")
    return ok and slice.tick or function() end
end)()
local CHUNK = 262144

local pointer_types, sizes = {}, {}

local function info(ctype)
    local pt = pointer_types[ctype]
    if pt == nil then
        pt = ffi.typeof(ctype .. " *")
        pointer_types[ctype] = pt
        sizes[ctype] = ffi.sizeof(ctype)
    end
    return pt, sizes[ctype]
end

-- buffer.new(ctype, n) -> pointer to n zeroed elements (n >= 1)
function M.new(ctype, n)
    local pt, size = info(ctype)
    n = math.max(n, 1)
    local p = C.malloc(size * n)
    if p == nil then
        error(string.format("buffer.new: out of memory (%d x %s)", n, ctype), 2)
    end
    ffi.fill(p, size * n)
    return ffi.cast(pt, p)
end

-- buffer.grow(p, ctype, old_n, new_n) -> pointer to new_n elements, the first old_n kept, the
-- rest zeroed
function M.grow(p, ctype, old_n, new_n)
    local pt, size = info(ctype)
    local q = C.malloc(size * new_n)
    if q == nil then
        error(string.format("buffer.grow: out of memory (%d x %s)", new_n, ctype), 2)
    end
    local src, dst = ffi.cast("uint8_t *", p), ffi.cast("uint8_t *", q)
    local keep, total = size * math.min(old_n, new_n), size * new_n
    local at = 0
    while at < keep do
        local n = math.min(CHUNK, keep - at)
        ffi.copy(dst + at, src + at, n)
        at = at + n
        tick("graph grow")
    end
    while at < total do
        local n = math.min(CHUNK, total - at)
        ffi.fill(dst + at, n)
        at = at + n
        tick("graph grow")
    end
    C.free(p)
    return ffi.cast(pt, q)
end

function M.free(p)
    if p ~= nil then
        C.free(p)
    end
end

return M
