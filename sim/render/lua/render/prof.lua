-- render/prof.lua : the GUI Lua's sampling profiler (docs/profiling.md), LuaJIT's jit.profile
-- in the UI thread's runtime (the windows' layouts, the localisation, the tooltips).
--
--   STELLAR_LUA_PROF=1          on, a sample every millisecond (N: every N ms)
--   STELLAR_LUA_PROF_DEPTH=12   the stacks' depth (8)
--
-- The samples are counted by function, by line, by stack and by the VM's state (N compiled,
-- I interpreted, C in a C function, G the collector, J the JIT compiler). One state per process
-- can be profiled (LuaJIT's profiler is the process's timer): the first runtime to start it.
-- The timer counts the process's CPU time, every thread's: a tick while this state runs no Lua
-- reaches it at its next instruction, so each callback counts once, not its ticks.

local M = {}

local ok, profile = pcall(require, "jit.profile")
local running = false
local by_fn, by_line, by_stack, by_state = {}, {}, {}, {}
local total = 0
local depth = 8

local function bump(t, k)
    t[k] = (t[k] or 0) + 1
end

function M.start(interval_ms, stack_depth)
    if not ok or running then
        return false
    end
    depth = stack_depth or depth
    -- jit.profile's interval is whole milliseconds (its default 10)
    local ms = math.max(1, math.floor((interval_ms or 1) + 0.5))
    profile.start("li" .. ms, function(th, _, vmstate)
        total = total + 1
        bump(by_state, vmstate)
        bump(by_fn, profile.dumpstack(th, "F", 1))
        bump(by_line, profile.dumpstack(th, "l", 1))
        bump(by_stack, profile.dumpstack(th, "F < ", depth))
    end)
    running = true
    return true
end

function M.stop()
    if running then
        profile.stop()
        running = false
    end
end

function M.reset()
    by_fn, by_line, by_stack, by_state = {}, {}, {}, {}
    total = 0
end

local function top(t, n)
    local rows = {}
    for k, v in pairs(t) do
        rows[#rows + 1] = { k, v }
    end
    table.sort(rows, function(a, b)
        if a[2] ~= b[2] then
            return a[2] > b[2]
        end
        return a[1] < b[1]
    end)
    local out = {}
    for i = 1, math.min(n, #rows) do
        out[i] = rows[i]
    end
    return out
end

-- The report: the samples' share by function, by line and by stack, n rows each.
function M.report(n)
    n = n or 25
    if total == 0 then
        return running and "lua: no samples\n" or ""
    end
    local out = { ("lua samples: %d (the VM: "):format(total) }
    local states = {}
    for _, r in ipairs(top(by_state, 8)) do
        states[#states + 1] = ("%s %.1f%%"):format(r[1], 100 * r[2] / total)
    end
    out[#out + 1] = table.concat(states, ", ") .. ")\n"
    local function section(title, t, rows)
        out[#out + 1] = ("  %s\n"):format(title)
        for _, r in ipairs(top(t, rows)) do
            out[#out + 1] = ("  %6.2f%% %6d  %s\n"):format(100 * r[2] / total, r[2], r[1])
        end
    end
    section("by function", by_fn, n)
    section("by line", by_line, n)
    section("by stack (innermost first)", by_stack, math.floor(n / 2) + 1)
    return table.concat(out)
end

return M
