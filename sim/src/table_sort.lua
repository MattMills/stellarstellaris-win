-- table.sort in Lua (sim/src/runtime.rs installs it in every VM of the simulation): LuaJIT's own
-- algorithm (lib_table.c: auxsort, Lua 5.1's quicksort with the median of three), the same
-- comparisons in the same order, so the same order of the elements as the C function gives, ties
-- and comparators that are not a strict order included. In C a comparator's call cannot yield, and
-- the VM could not stop a long sort at a slice's deadline (sim/src/preempt.rs); in Lua it can, and
-- the JIT compiles the comparator's calls.

local rawget, rawset, type, error = rawget, rawset, type, error
local floor = math.floor

local function less(comp, a, b)
    if comp then
        return comp(a, b)
    end
    return a < b
end

local function auxsort(t, l, u, comp)
    while l < u do
        -- sort a[l], a[(l+u)/2] and a[u]
        local x, y = rawget(t, l), rawget(t, u)
        if less(comp, y, x) then
            rawset(t, l, y)
            rawset(t, u, x)
        end
        if u - l == 1 then
            break
        end
        local i = floor((l + u) / 2)
        local a, b = rawget(t, i), rawget(t, l)
        if less(comp, a, b) then
            rawset(t, i, b)
            rawset(t, l, a)
        else
            local c = rawget(t, u)
            if less(comp, c, a) then
                rawset(t, i, c)
                rawset(t, u, a)
            end
        end
        if u - l == 2 then
            break
        end
        -- the pivot to a[u-1]: a[l] <= P == a[u-1] <= a[u], sort from l+1 to u-2
        local p = rawget(t, i)
        rawset(t, i, rawget(t, u - 1))
        rawset(t, u - 1, p)
        local j
        i, j = l, u - 1
        while true do
            i = i + 1
            local ai = rawget(t, i)
            while less(comp, ai, p) do
                if i >= u then
                    error("invalid order function for sorting", 3)
                end
                i = i + 1
                ai = rawget(t, i)
            end
            j = j - 1
            local aj = rawget(t, j)
            while less(comp, p, aj) do
                if j <= l then
                    error("invalid order function for sorting", 3)
                end
                j = j - 1
                aj = rawget(t, j)
            end
            if j < i then
                break
            end
            rawset(t, i, aj)
            rawset(t, j, ai)
        end
        local pv, ii = rawget(t, u - 1), rawget(t, i)
        rawset(t, u - 1, ii)
        rawset(t, i, pv)
        -- the smaller half by recursion, the larger one by the loop
        if i - l < u - i then
            j = l
            i = i - 1
            l = i + 2
        else
            j = i + 1
            i = u
            u = j - 2
        end
        auxsort(t, j, i, comp)
    end
end

return function(t, comp)
    if type(t) ~= "table" then
        error("bad argument #1 to 'sort' (table expected, got " .. type(t) .. ")", 2)
    end
    if comp ~= nil and type(comp) ~= "function" then
        error("bad argument #2 to 'sort' (function expected, got " .. type(comp) .. ")", 2)
    end
    auxsort(t, 1, #t, comp)
end
