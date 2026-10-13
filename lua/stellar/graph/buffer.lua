-- graph/buffer.lua : growable typed arrays outside the Lua heap, for stellar.graph.
--
-- The graph keeps its nodes and edges in flat arrays (structure of arrays). They are allocated
-- with malloc, not ffi.new, so that a large graph (millions of nodes) does not count against the
-- garbage-collected heap, and they grow with realloc. New elements are zero.
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
    local q = C.realloc(p, size * new_n)
    if q == nil then
        error(string.format("buffer.grow: out of memory (%d x %s)", new_n, ctype), 2)
    end
    q = ffi.cast(pt, q)
    if new_n > old_n then
        ffi.fill(q + old_n, size * (new_n - old_n))
    end
    return q
end

function M.free(p)
    if p ~= nil then
        C.free(p)
    end
end

return M
