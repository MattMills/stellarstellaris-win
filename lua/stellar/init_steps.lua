-- init_steps.lua : the steps of CGameApplication::InitGame that Lua runs itself, ahead of the game,
-- each on a thread of its own as soon as what it needs is made; the game's own call of the step
-- then waits for that run and returns its result (stellar.run_async, stellar.defer_mark).
--
-- A step is a function the load marks (stellar.loading MILESTONES), started at a point of the load
-- Lua sees ("databases": SetupDatabases begins; "post_reads": the PostReadInitInstance calls are
-- done), with its arguments ("application": the CGameApplication).
--
--   local init_steps = require("stellar.init_steps")
--   init_steps.bind(marks)          -- the marks hooked (with id and trampoline)
--   init_steps.start("databases")   -- from the game's thread, at that point
--   init_steps.report()             -- once the load is done

local stellar = require("stellar")

local init_steps = {}

init_steps.STEPS = {
    { name = "CApplication::CalculateGameFilesChecksum", at = "databases", args = { "application" },
        why = "hashes the game's files into the application (+800), 1.1s; nothing the load makes is read" },
    { name = "CModifier::LogDefinitions", at = "post_reads", args = {},
        why = "writes modifiers.log, 4.3s; the modifier definitions are final after the PostReads" },
}

local by_name, started = {}, {}

-- init_steps.bind(marks) -> bound, missing: each step's mark (by name, kind milestone)
function init_steps.bind(marks)
    local missing = {}
    for _, m in ipairs(marks) do
        if m.kind == "milestone" and m.id and m.trampoline then
            by_name[m.name] = m
        end
    end
    local bound = 0
    for _, step in ipairs(init_steps.STEPS) do
        if by_name[step.name] then
            bound = bound + 1
        else
            missing[#missing + 1] = step.name
        end
    end
    return bound, missing
end

local function argument(a)
    if a == "application" then
        return stellar.loading_application()
    end
    return a
end

-- init_steps.start(at) -> started: the steps of that point, each on a thread of its own; the
-- game's call of each waits for it
function init_steps.start(at)
    local n = 0
    for _, step in ipairs(init_steps.STEPS) do
        local m = by_name[step.name]
        if step.at == at and m and not started[step.name] then
            local args, ok = {}, true
            for i, a in ipairs(step.args) do
                args[i] = argument(a)
                ok = ok and args[i] ~= nil
            end
            if ok then
                local call = stellar.run_async(m.trampoline, args[1], args[2], args[3], args[4])
                if call then
                    stellar.defer_mark(m.id, call)
                    started[step.name] = call
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- init_steps.report() -> text: each step started, how long it ran, and the waits for them
function init_steps.report()
    local parts = {}
    for _, step in ipairs(init_steps.STEPS) do
        local call = started[step.name]
        if call then
            local code, what = stellar.join_async(call, 0)
            if code == nil then
                parts[#parts + 1] = step.name .. " still running"
            else
                parts[#parts + 1] = string.format("%s %.2fs%s", step.name, (what.finish or 0) - (what.start or 0),
                    code ~= 0 and string.format(" (failed: 0x%08x)", code) or "")
            end
        end
    end
    local joins, waited, pending = stellar.deferred_stats()
    return string.format("%s; the game waited %.2fs in %d calls (%d not called)", table.concat(parts, ", "), waited,
        joins, pending)
end

return init_steps
