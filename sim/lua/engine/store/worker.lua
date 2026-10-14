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

local SW, TW, generation_seen
local rawtype = type
local job = { date = nil, daily_pool = nil, monthly_pool = nil }

local function forbidden(name)
    return function() error(name .. " in a worker (a parallel phase may not)", 2) end
end

-- the copy attached again when the main state's sync moved, added or removed an object
local indexes_seen, values_seen
local function current()
    local g = S.H.roots[5]
    if g ~= generation_seen then
        SW.attach_root(S.H.roots[4])
        SW.index()
        generation_seen = g
        indexes_seen = nil
    end
    -- the main state's derived indexes as its writers keep them (engine.store.full's root 8), in
    -- place of those SW.index computes
    local n = S.H.roots[9]
    if n ~= indexes_seen and S.H.roots[8] ~= 0 then
        indexes_seen = n
        local root = S.H.roots[8]
        local how_of = require("engine.store.full").INDEXES
        local b = S.B[root]
        for i = b.first, b.first + b.count - 1 do
            local e = S.E[i]
            local name, how = S.str(e.key), how_of[S.str(e.key)]
            local list = S.numbers(e.v.u.a)
            local t, j = {}, 1
            if how == "map" then
                while j < #list do
                    t[list[j]] = list[j + 1]
                    j = j + 2
                end
            else
                while j <= #list do
                    local k, c = list[j], list[j + 1]
                    t[k] = { unpack(list, j + 2, j + 1 + c) }
                    j = j + 2 + c
                end
            end
            SW[name] = t
        end
    end
    -- the main state's module values (engine.store.full's root 10): each set on the module here
    local nv = S.H.roots[11]
    if nv ~= values_seen and S.H.roots[10] ~= 0 then
        values_seen = nv
        local function get(bid)
            local out = {}
            local b = S.B[bid]
            for i = b.first, b.first + b.count - 1 do
                local e = S.E[i]
                local key = S.str(e.key)
                local k = key:sub(1, 1) == "#" and tonumber(key:sub(2)) or key
                if e.kind == S.BLOCK then
                    out[k] = get(e.v.u.a)
                elseif e.kind == S.NUMBER then
                    out[k] = e.v.num
                else
                    out[k] = S.str(e.v.u.a)
                end
            end
            return out
        end
        local b = S.B[S.H.roots[10]]
        for i = b.first, b.first + b.count - 1 do
            local e = S.E[i]
            local module, field = S.str(e.key):match("^(.*)%.([^.]+)$")
            require(module)[field] = get(e.v.u.a)
        end
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
        "remove", "create", "push", "set_text", "set_key", "insert_value", "remove_at", "replace", "set_entry",
        "append_entry", "place" }) do
        SW[name] = forbidden("engine.world." .. name)
    end
    -- the blocks a worker holds as Lua tables (SW.overlay: an AI country's own state while it
    -- decides) are read and written by a table world of the worker's own (a second instance of
    -- engine.world's module): each block function goes to it for a table, to the store's for a handle
    TW = dofile(package.searchpath("engine.world", package.path))
    for _, name in ipairs({ "field", "fields", "list", "blocks", "statements", "count", "key", "token_entry",
        "set", "child", "append", "insert", "append_value", "remove_value", "remove_entry", "push", "reindex",
        "set_text", "set_key", "insert_value", "remove_at", "replace", "set_entry", "append_entry" }) do
        local s, t = SW[name], TW[name]
        if t then
            SW[name] = function(obj, ...)
                if rawtype(obj) == "table" then return t(obj, ...) end
                if s then return s(obj, ...) end
                return nil
            end
        end
    end
    package.loaded["engine.world"] = SW
    -- an AI command made here is a recipe the main state turns into the command (engine.ai.commands)
    _G.STELLAR_WORKER = true
    -- the engine's modules test a world value with type(v) == "table" (a block, not a token): a
    -- store block is a cdata handle here, so type says "table" for it. Code that then walks it as a
    -- Lua table (ipairs, #, .text) fails loudly, and is moved to engine.world's API.
    local ffi = require("ffi")
    local rawtype, istype, block_ptr = type, ffi.istype, S.handle_t
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
    -- the modifier values: the main state's graph's, from the store (engine.store.modifiers)
    require("engine.economy").set_modifier_source(require("engine.store.modifiers").reader())
    collectgarbage()
    return string.format("%.3f %d", RUST.clock() - t0, math.floor(collectgarbage("count")))
end

-- W.profile("<job> <reps>\n<arg>"): another job run reps times under LuaJIT's sampling profiler ->
-- the seconds, then the top functions by samples and the VM states
function W.profile(arg)
    local head, rest = arg:match("^([^\n]*)\n?(.*)$")
    local name, reps = head:match("^(%S+)%s*(%d*)$")
    reps = tonumber(reps) or 1
    local profile = require("jit.profile")
    local fn, vm, n = {}, {}, 0
    profile.start("fi1", function(thread, samples, vmstate)
        n = n + samples
        vm[vmstate] = (vm[vmstate] or 0) + samples
        local top = profile.dumpstack(thread, "pl", 1)
        fn[top] = (fn[top] or 0) + samples
    end)
    local t0 = RUST.clock()
    for _ = 1, reps do W[name](rest) end
    local secs = RUST.clock() - t0
    profile.stop()
    local list = {}
    for k, v in pairs(fn) do list[#list + 1] = { k, v } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local out = { string.format("%.3f s, %d samples", secs, n) }
    local states = {}
    for k, v in pairs(vm) do states[#states + 1] = k .. " " .. string.format("%.0f%%", 100 * v / n) end
    out[#out + 1] = "vm: " .. table.concat(states, ", ")
    for i = 1, math.min(25, #list) do out[#out + 1] = string.format("%6d %s", list[i][2], list[i][1]) end
    return table.concat(out, "\n")
end

-- the main state's date for the next jobs ("YYYY.MM.DD <RUST.date()>": the save's text, and the
-- game's date as RUST.date gives it in the main state)
function W.date(arg)
    local text, ticks = arg:match("^(%S+)%s*(%S*)$")
    job.date = tonumber(ticks)
    SW.meta.date = text
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

-- a country's `ai` block held as a Lua table in this worker while it decides (SW.overlay): the
-- block's id, the table, and its text as it was
local pdxscript_ = nil
local function hold_ai(country)
    local ch = SW.object("country", country)
    local i = ch and S.find(SW.bid(ch), S.id("ai"))
    local e = i and S.E[i]
    if not (e and e.kind == S.BLOCK) then return nil end
    local bid = e.v.u.a
    local t = SW.to_table(SW.handle(bid))
    SW.overlay[bid] = t
    pdxscript_ = pdxscript_ or require("pdxscript")
    return bid, t, pdxscript_.write(t)
end
-- the held block let go: its text when it changed, else nil
local function release_ai(bid, t, before)
    SW.overlay[bid] = nil
    local after = pdxscript_.write(t)
    if after ~= before then return after end
    return nil
end
W.hold_ai, W.release_ai = hold_ai, release_ai

-- a dry run of the AI's decisions ("<today>\n<country> <week> <month> <year>\n..."): each country's
-- engine.ai.decide with a command list thrown away, the errors reported (a write the worker may not
-- make, code that walks a block handle as a table, ...): "<country> ok <n commands>" or the error
function W.ai_dry(arg)
    current()
    local ai = require("engine.ai")
    local host = require("simscript.host")
    local today, rest = arg:match("^([^\n]*)\n(.*)$")
    local out = {}
    for c, w, m, y in rest:gmatch("(%d+) (%d) (%d) (%d)") do
        local commands = {}
        local bid, t, before = hold_ai(tonumber(c))
        local ok, err = pcall(ai.decide, tonumber(c), today, { week = w == "1", month = m == "1", year = y == "1" },
            commands, host)
        local changed = bid and release_ai(bid, t, before)
        out[#out + 1] = c .. (ok and string.format(" ok %d commands, ai block %s", #commands,
            changed and ("changed (" .. #changed .. " bytes)") or "unchanged") or (" error " .. tostring(err):gsub("\n", " ")))
    end
    return table.concat(out, "\n")
end

-- one record of an answer: a tag, the payload's length, a newline, the payload
local function record(out, tag, payload)
    out[#out + 1] = tag .. #payload .. "\n" .. payload
end

-- the AI's day for this worker's countries (engine.ai.process with STELLAR_PARALLEL=ai): arg is
-- "<today>\n" and a line "<country> <week> <month> <year> <seed> <position>" per AI country; this
-- worker takes the countries c with c % worker_count == its index (always the same ones: the AI
-- modules' own state of a country lives in one worker). Each decides with its unsynced generator
-- set from the line and its `ai` block held as a Lua table; a command the AI keeps for itself
-- (internal) is executed here. Per country the records "C" ("<country> <seed> <position>"), "O"
-- (the ai block's text, when it changed), "E" (an error), then "K" for each command
-- (engine.ai.commands' line), in order.
local ai_prof, ai_times
local function prof_start()
    if ai_prof or not os.getenv("STELLAR_WORKER_PROF") then return end
    local profile = require("jit.profile")
    ai_prof, ai_times = { fn = {}, n = 0 }, { hold = 0, decide = 0, serialize = 0, release = 0, jobs = 0 }
    profile.start("fi1", function(thread, samples)
        ai_prof.n = ai_prof.n + samples
        local top = profile.dumpstack(thread, "pl", 1)
        ai_prof.fn[top] = (ai_prof.fn[top] or 0) + samples
    end)
end
local function prof_write()
    if not ai_prof then return end
    local list = {}
    for k, v in pairs(ai_prof.fn) do list[#list + 1] = { k, v } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local f = io.open(os.getenv("STELLAR_WORKER_PROF") .. "." .. RUST.worker_index, "w")
    f:write(string.format("%d samples; %d jobs: hold %.2f s, decide %.2f s, serialize %.2f s, release %.2f s\n", ai_prof.n,
        ai_times.jobs, ai_times.hold, ai_times.decide, ai_times.serialize, ai_times.release))
    for i = 1, math.min(40, #list) do f:write(string.format("%6d %s\n", list[i][2], list[i][1])) end
    f:close()
end

function W.ai(arg)
    current()
    prof_start()
    local clock = RUST.clock
    local ai = require("engine.ai")
    local rng = require("engine.ai.rng")
    local cmds = require("engine.ai.commands")
    local host = require("simscript.host")
    local today, rest = arg:match("^([^\n]*)\n(.*)$")
    local out = {}
    local n, mod = RUST.worker_count, RUST.worker_index
    for c, w, m, y, seed, pos in rest:gmatch("(%d+) (%d) (%d) (%d) (%d+) (%d+)") do
        c = tonumber(c)
        if c % n == mod then
            rng.set_state(c, tonumber(seed), tonumber(pos))
            local commands = {}
            local t0 = clock()
            local bid, t, before = hold_ai(c)
            local t1 = clock()
            local ok, err = pcall(ai.decide, c, today, { week = w == "1" or nil, month = m == "1" or nil,
                year = y == "1" or nil }, commands, host)
            local t2 = clock()
            local lines = {}
            if ok then
                local paths = t and cmds.paths(t)
                for _, cmd in ipairs(commands) do
                    if cmd.internal then
                        cmd.execute(cmd, today)
                    else
                        local okc, line = pcall(cmds.serialize, cmd, paths)
                        if not okc then
                            ok, err = false, line
                            break
                        end
                        lines[#lines + 1] = line
                    end
                end
            end
            local t3 = clock()
            local changed = bid and release_ai(bid, t, before)
            if ai_times then
                ai_times.hold = ai_times.hold + (t1 - t0)
                ai_times.decide = ai_times.decide + (t2 - t1)
                ai_times.serialize = ai_times.serialize + (t3 - t2)
                ai_times.release = ai_times.release + (clock() - t3)
            end
            local s, p = rng.state(c)
            record(out, "C", string.format("%d %d %d", c, s, p))
            if changed then record(out, "O", changed) end
            if not ok then record(out, "E", tostring(err)) end
            for _, line in ipairs(lines) do record(out, "K", line) end
        end
    end
    if ai_times then
        ai_times.jobs = ai_times.jobs + 1
        if ai_times.jobs % 30 == 0 then prof_write() end
    end
    return table.concat(out)
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
