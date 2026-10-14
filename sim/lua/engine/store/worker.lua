-- engine/store/worker.lua : what a worker's Lua state loads (sim/src/workers.rs): the store mapped,
-- the engine's store modules, and the jobs the main thread runs on every worker at once
-- (RUST.pool_run(name, arg) -> each worker's W[name](arg), a text).
--
-- A worker has no table world and no definitions of its own: it reads the store (the world's
-- blocks, the definitions, the typed arrays). It builds no key index (S.serial = false): a block
-- without one is scanned.

local S = require("engine.store.core")
S.attach()
S.serial = false

local W = {}

-- part "a" / "b" / "c" of exploration's pass; arg = part .. with_visited (0/1) .. write (0/1)
function W.part(arg)
    local X = require("engine.store.exploration")
    return X.run_part(arg:sub(1, 1), arg:sub(2, 2) == "1", arg:sub(3, 3) == "1")
end

function W.ping()
    return string.format("worker %d of %d", RUST.worker_index, RUST.worker_count)
end

-- a read benchmark over the world in the store: every fleet's movement_manager.coordinate.origin,
-- `reps` times (arg); for scaling of plain reads
function W.read_bench(arg)
    local O = require("engine.store.objects")
    O.refresh()
    local reps = tonumber(arg) or 100
    local find, token = S.find, S.token
    local km, kc, ko = S.id("movement_manager"), S.id("coordinate"), S.id("origin")
    local ids = O.ids("fleet")
    local fb = {}
    for i, id in ipairs(ids) do fb[i] = O.get("fleet", id) end
    local E = S.E
    local t0 = RUST.clock()
    local s = 0
    for _ = 1, reps do
        for i = 1, #fb do
            local x = find(fb[i], km)
            x = x and find(E[x].v.u.a, kc)
            x = x and find(E[x].v.u.a, ko)
            s = s + (x and token(x) or 0)
        end
    end
    return string.format("%.6f %d", RUST.clock() - t0, s)
end

-- an allocation benchmark: Lua tables made and dropped (the garbage collector of this state, the
-- allocator under it), `reps` thousand times 100 small tables
function W.alloc_bench(arg)
    local reps = (tonumber(arg) or 100) * 10
    local t0 = RUST.clock()
    local keep
    for _ = 1, reps do
        local t = {}
        for i = 1, 100 do t[i] = { i, i + 1 } end
        keep = t
    end
    return string.format("%.6f %d", RUST.clock() - t0, #keep)
end

-- part a of exploration on every country, in this state alone (no counter): each worker does
-- the whole part, to time the same work on N threads at once
function W.part_a_all(arg)
    local X = require("engine.store.exploration")
    local O = require("engine.store.objects")
    local reps = tonumber(arg) or 1
    local t0 = RUST.clock()
    for _ = 1, reps do
        X.begin()
        for _, cid in ipairs(O.ids("country")) do X.part_a(cid, true) end
    end
    return string.format("%.6f %d", RUST.clock() - t0, reps)
end

return W
