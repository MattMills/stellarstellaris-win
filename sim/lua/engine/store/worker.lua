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

-- ---------------------------------------------------------------------------------------------
-- the engine in a worker (docs/data_layer.md, "The engine on the workers"): engine.world is
-- engine.store.world over the whole world's copy (engine.store.full: root 4, its generation in root
-- 5), and the definitions and the script layer are loaded as engine.load loads them. What only the
-- main state may do raises an error here: a random draw, an engine effect, the date moved.

local SW, generation_seen
local job = { date = nil, daily_pool = nil, monthly_pool = nil }

local function forbidden(name)
    return function() error(name .. " in a worker (a parallel phase may not)", 2) end
end

-- the copy attached again when the main state's sync moved, added or removed an object
local function current()
    local g = S.H.roots[5]
    if g ~= generation_seen then
        SW.attach_root(S.H.roots[4])
        SW.index()
        generation_seen = g
    end
end
W.current = current

-- W.engine("<game_dir>\t<docs_dir>"): the engine loaded over the copy -> "<seconds> <KB of Lua heap>"
function W.engine(arg)
    local game_dir, docs_dir = arg:match("^([^\t]*)\t?(.*)$")
    local t0 = RUST.clock()
    RUST.rand = forbidden("RUST.rand")
    RUST.skip = forbidden("RUST.skip")
    RUST.effect = forbidden("RUST.effect")
    RUST.date = function() return job.date end
    RUST.daily_pool = function() return job.daily_pool end
    RUST.monthly_pool = function() return job.monthly_pool end
    SW = require("engine.store.world")
    SW.attach_root(S.H.roots[4])
    SW.index()
    generation_seen = S.H.roots[5]
    -- engine.world's writers' marks are the main state's business, and a worker never writes the
    -- copy (the other workers read it): a writer called here is an error
    SW.wrote = function() end
    SW.adopt = function() end
    SW.track_owners = function() end
    SW.parent = function() return nil end
    for _, name in ipairs({ "set", "child", "append", "insert", "append_value", "remove_value", "remove_entry",
        "remove", "create", "push" }) do
        SW[name] = forbidden("engine.world." .. name)
    end
    package.loaded["engine.world"] = SW
    -- the engine's modules test a world value with type(v) == "table" (a block, not a token): a
    -- store block is a cdata handle here, so type says "table" for it. Code that then walks it as a
    -- Lua table (ipairs, #, .text) fails loudly, and is moved to engine.world's API.
    local ffi = require("ffi")
    local rawtype, istype, block_ptr = type, ffi.istype, ffi.typeof("pdx_block *")
    _G.type = function(v)
        local t = rawtype(v)
        if t == "cdata" and istype(block_ptr, v) then return "table" end
        return t
    end
    local engine = require("engine")
    engine.host.init(game_dir, docs_dir ~= "" and docs_dir or nil)
    local db = require("simscript.db")
    engine.defs.load(db.fs, game_dir)
    require("engine.scriptstate").install()
    collectgarbage()
    return string.format("%.3f %d", RUST.clock() - t0, math.floor(collectgarbage("count")))
end

-- the main state's date for the next jobs ("YYYY.MM.DD")
function W.date(arg)
    local y, m, d = arg:match("^(%d+)%.(%d+)%.(%d+)$")
    job.date = { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
    SW.meta.date = arg
    return "ok"
end

-- the day's attitude update of this worker's share of the countries ("<today> <year> <id>,<id>...":
-- every worker_count-th from its index), as engine.ai.attitudes.part_text gives it
function W.attitudes(arg)
    current()
    local today, year, ids = arg:match("^(%S+) (%d+) (.*)$")
    local mine, i = {}, 0
    for id in ids:gmatch("%d+") do
        if i % RUST.worker_count == RUST.worker_index then mine[#mine + 1] = tonumber(id) end
        i = i + 1
    end
    return require("engine.ai.attitudes").part_text(mine, today, tonumber(year))
end

-- a parity probe: the opinion terms of the pairs "us:other,..." (engine.ai.opinion.terms)
function W.probe_opinion(arg)
    current()
    local op = require("engine.ai.opinion")
    local out = {}
    for us, other in arg:gmatch("(%d+):(%d+)") do
        local ok, total, terms = pcall(op.terms, tonumber(us), tonumber(other))
        if not ok then terms = total end
        local t = {}
        for _, x in ipairs(ok and terms or {}) do t[#t + 1] = tostring(x[1]) .. "=" .. tostring(x[2]) end
        out[#out + 1] = us .. ":" .. other .. " " .. (ok and table.concat(t, ",") or ("error " .. tostring(terms)))
    end
    return table.concat(out, "\n")
end

-- a parity probe: the attitude weights of the pairs "us:other,us:other,..." as the engine here
-- computes them (engine.ai.attitudes.evaluate), one line per pair
function W.probe_attitudes(arg)
    current()
    local attitudes = require("engine.ai.attitudes")
    local out = {}
    for us, other in arg:gmatch("(%d+):(%d+)") do
        local ok, opinion, interest, all = pcall(attitudes.evaluate, tonumber(us), tonumber(other))
        if not ok then
            out[#out + 1] = us .. ":" .. other .. " error " .. tostring(opinion)
        else
            local w = {}
            for _, x in ipairs(all or {}) do w[#w + 1] = x[1] .. "=" .. string.format("%.5f", x[2]) end
            out[#out + 1] = string.format("%s:%s %s %s %s", us, other, tostring(opinion), tostring(interest),
                table.concat(w, ","))
        end
    end
    return table.concat(out, "\n")
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
