-- engine/store/parallel.lua : the engine's phases on the worker states (docs/data_layer.md, "The
-- engine on the workers"). The whole world's copy (engine.store.full) and an engine in each worker
-- (engine.store.worker's `engine` job: engine.world over the copy, the definitions and the script
-- layer of its own) are made once; before a phase runs on the workers the copy is synced and the
-- date given. A phase on the workers only reads: what it decides comes back as text, and this state
-- applies it in the game's order.
--
-- STELLAR_PARALLEL names the phases that run on the workers ("attitudes", ..., or "all"); none by
-- default while each is checked against its serial form.
--
--   local parallel = require("engine.store.parallel")
--   if parallel.enabled("attitudes") then
--       local texts = parallel.run("attitudes", arg)   -- each worker's answer, in worker order
--   end

local P = { on = {}, started = false, failed = nil, stats = { runs = 0, seconds = 0, start_seconds = 0 } }

for name in (os.getenv("STELLAR_PARALLEL") or ""):gmatch("[^,%s]+") do P.on[name] = true end

-- whether a phase runs on the workers (and they can be started: a pool, a world)
function P.enabled(name)
    if not (P.on[name] or P.on.all) or P.failed then return false end
    if not P.started then P.start() end
    return P.started
end

-- the copy built and the workers' engines loaded (once)
function P.start()
    if P.started or P.failed then return end
    local t0 = RUST.clock()
    local ok, err = pcall(function()
        local full = require("engine.store.full")
        full.build()
        if not (RUST.pool_run and require("engine.store.bridge").start) then error("no worker pool") end
        local game_dir = require("simscript.db").game_dir or os.getenv("STELLARIS_DIR") or ""
        for i, r in ipairs(RUST.pool_run("engine", game_dir .. "\t")) do
            if not tostring(r):match("^%d") then error("worker " .. i .. ": " .. tostring(r)) end
        end
    end)
    P.stats.start_seconds = RUST.clock() - t0
    if ok then
        P.started = true
    else
        P.failed = tostring(err)
    end
end

-- P.run(job, arg) -> each worker's answer to engine.store.worker[job](arg), after the copy's sync
function P.run(job, arg)
    local t0 = RUST.clock()
    require("engine.store.full").sync()
    require("engine.store.modifiers").sync()
    local world = require("engine.world")
    RUST.pool_run("date", tostring(world.meta.date))
    local res = RUST.pool_run(job, arg)
    P.stats.runs = P.stats.runs + 1
    P.stats.seconds = P.stats.seconds + (RUST.clock() - t0)
    return res
end

function P.report()
    local names = {}
    for k in pairs(P.on) do names[#names + 1] = k end
    table.sort(names)
    return string.format("parallel: %s; started %s in %.2f s; %d runs, %.2f s%s", #names > 0 and table.concat(names, ",") or "none",
        tostring(P.started), P.stats.start_seconds, P.stats.runs, P.stats.seconds,
        P.failed and (" (failed: " .. P.failed .. ")") or "")
end

return P
