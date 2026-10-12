-- databases.lua : the game's databases (common/..., the 80-100% phase of the startup load).
--
-- NNullObjAndDatabaseInitUtil::SetupDatabases (called by CGameApplication::InitGame) fills a table
-- on its stack, one SDatabaseObjectFunctions per database (48 bytes): its name and the functions
-- CreateInstance, DestroyInstance, CanInitialize (or null), InitInstance and PostReadInitInstance.
-- It then initializes them, one at a time on the thread that runs it: it picks the first database
-- left whose CanInitialize (its dependencies) is true, or that has none, logs "Initializing
-- Database: <name>" (to a null logger in release builds), calls CreateInstance and InitInstance
-- (which reads the database's files), and reports progress (current of total). Then it resolves
-- the deferred key references and calls every PostReadInitInstance.
--
-- databases.locate reads that table from the code of SetupDatabases: the name and functions are
-- stored with `lea reg, [rip+x]` / `mov [rbp+d], reg` (and a register that holds zero for a null).
--
--   local databases = require("stellar.databases")
--   local where = assert(databases.locate(image, stellar.read))
--   where.entries[i] = { name, create, destroy, can_initialize, init, post_read }

local fnmatch = require("fnmatch")
local resolve = require("stellar.resolve")

local databases = {}

local ENTRY_SIZE = 48

-- the number in an operand: 50h, 0x50 or 80
local function number(text)
    local hex = text:match("^(%x+)h$") or text:match("^0x(%x+)$")
    if hex then
        return tonumber(hex, 16)
    end
    return tonumber(text)
end

-- databases.locate(image, read) -> where | nil, message: setup (SetupDatabases) and entries, in the
-- order of the table
function databases.locate(image, read)
    local setup = resolve.functions(image)["NNullObjAndDatabaseInitUtil::SetupDatabases"]
    if not setup then
        return nil, "NNullObjAndDatabaseInitUtil::SetupDatabases not found"
    end
    local f = image:function_at(setup)
    if f == nil then
        return nil, "no function at SetupDatabases"
    end
    local code = read(f.address, f.end_address - f.address)
    if code == nil then
        return nil, "cannot read SetupDatabases"
    end
    -- what the registers hold (an address or 0), and the qwords stored in the frame
    local regs, stores = {}, {}
    local pos = 1
    while pos <= #code do
        local i = fnmatch.decode(code, f.address, pos)
        if i == nil then
            pos = pos + 1
        else
            local text = i.text
            local dest, src = text:match("^mov %[rbp%+(%w+)%],(%w+)$")
            if dest then
                -- the first store to a slot: the table is built first, the frame is reused after
                local offset = number(dest)
                if regs[src] ~= nil and offset and stores[offset] == nil then
                    stores[offset] = regs[src]
                end
            else
                local reg = text:match("^lea (%w+),%[") or text:match("^mov (%w+),")
                local a, b = text:match("^xor (%w+),(%w+)$")
                if a and a == b then
                    -- a zeroed register, and the 64-bit one it is part of
                    regs[a], regs[(a:gsub("d$", ""))] = 0, 0
                elseif reg and i.rip_relative and text:match("^lea ") then
                    regs[reg] = i.target
                elseif reg then
                    regs[reg] = nil
                end
                if i.flow == "call" or i.flow == "indirect_call" then
                    -- a call clobbers the volatile registers
                    for _, r in ipairs({ "rax", "rcx", "rdx", "r8", "r9", "r10", "r11" }) do
                        regs[r] = nil
                    end
                end
            end
            pos = pos + i.length
        end
    end
    -- entries: a name (a C string) followed by the functions
    local entries, seen = {}, {}
    local offsets = {}
    for d in pairs(stores) do
        offsets[#offsets + 1] = d
    end
    table.sort(offsets)
    for _, d in ipairs(offsets) do
        local name_at, create = stores[d], stores[d + 8]
        if name_at and name_at ~= 0 and create and create ~= 0 and stores[d + 32] and not seen[d] then
            local bytes = read(name_at, 64)
            local name = bytes and bytes:match("^([%w_:]+)%z")
            if name then
                entries[#entries + 1] = { name = name, create = create, destroy = stores[d + 16],
                    can_initialize = stores[d + 24] ~= 0 and stores[d + 24] or nil,
                    init = stores[d + 32], post_read = stores[d + 40] ~= 0 and stores[d + 40] or nil }
                for k = 0, ENTRY_SIZE - 8, 8 do
                    seen[d + k] = true
                end
            end
        end
    end
    if #entries == 0 then
        return nil, "no database table in SetupDatabases"
    end
    return { setup = setup, entries = entries }
end

-- The globals a function reads or writes relative to RIP (its first `count` instructions, calls
-- not followed): { [address] = "read" | "write" }
local function globals(read, address, count)
    local out = {}
    local bytes = address and read(address, 256)
    if bytes == nil then
        return out
    end
    local pos = 1
    for _ = 1, count do
        local i = fnmatch.decode(bytes, address, pos)
        if i == nil or i.flow == "return" then
            break
        end
        if i.rip_relative and i.target then
            local text = i.text
            if text:match("^mov %[") then
                out[i.target] = "write"
            elseif not out[i.target] then
                out[i.target] = "read"
            end
        end
        pos = pos + i.length
        if pos > #bytes - 15 then
            break
        end
    end
    return out
end

-- databases.dependencies(where, read) -> unknown: each entry gets instance (the global its
-- CreateInstance stores the new database in: the first global it writes) and depends (the entries
-- whose instance its CanInitialize reads: the databases that must exist first). unknown lists the
-- globals a CanInitialize reads that are no database's instance.
function databases.dependencies(where, read)
    local by_instance = {}
    for _, e in ipairs(where.entries) do
        local create = databases.follow(read, e.create)
        local bytes = read(create, 256)
        local pos = 1
        while bytes and pos <= #bytes - 15 do
            local i = fnmatch.decode(bytes, create, pos)
            if i == nil or i.flow == "return" then
                break
            end
            if i.rip_relative and i.target and i.text:match("^mov %[") then
                e.instance = i.target
                by_instance[i.target] = e
                break
            end
            pos = pos + i.length
        end
    end
    local unknown = {}
    for _, e in ipairs(where.entries) do
        e.depends = {}
        if e.can_initialize then
            for address, how in pairs(globals(read, databases.follow(read, e.can_initialize), 64)) do
                local d = how == "read" and by_instance[address]
                if d and d ~= e then
                    e.depends[#e.depends + 1] = d
                elseif how == "read" and not d then
                    -- something that is not a database: it waits for every database before it
                    e.barrier = true
                    unknown[#unknown + 1] = string.format("%s reads 0x%x", e.name, address)
                end
            end
        end
    end
    return unknown
end

-- databases.schedule(where, seconds, workers) -> makespan, critical: the time to initialize every
-- database with `workers` threads, each database starting when the databases it depends on are
-- done (list scheduling, the longest first among the ready), from the times of one run
-- (seconds[name]); critical is the longest chain of dependencies
function databases.schedule(where, seconds, workers)
    local finish, critical = {}, 0
    local function chain(e)
        if finish[e] == nil then
            local start = 0
            for _, d in ipairs(e.depends or {}) do
                start = math.max(start, chain(d))
            end
            finish[e] = start + (seconds[e.name] or 0)
        end
        return finish[e]
    end
    for _, e in ipairs(where.entries) do
        critical = math.max(critical, chain(e))
    end
    -- simulate workers
    local done, start_of, free = {}, {}, {}
    for w = 1, workers do
        free[w] = 0
    end
    local left = {}
    for _, e in ipairs(where.entries) do
        left[#left + 1] = e
    end
    local makespan = 0
    while #left > 0 do
        -- the earliest free worker; the ready database with the longest time
        table.sort(free)
        local now = free[1]
        local best, best_k
        for k, e in ipairs(left) do
            local ready = 0
            for _, d in ipairs(e.depends or {}) do
                ready = done[d] and math.max(ready, done[d]) or math.huge
            end
            if ready <= now and (best == nil or (seconds[e.name] or 0) > (seconds[best.name] or 0)) then
                best, best_k = e, k
            end
        end
        if best == nil then
            -- nothing ready at that time: the worker waits for the next database to finish
            local next_done = math.huge
            for _, t in pairs(done) do
                if t > now and t < next_done then
                    next_done = t
                end
            end
            if next_done == math.huge then
                break
            end
            free[1] = next_done
        else
            table.remove(left, best_k)
            done[best] = now + (seconds[best.name] or 0)
            free[1] = done[best]
            makespan = math.max(makespan, done[best])
        end
    end
    return makespan, critical
end

-- databases.follow(read, address) -> the function a thunk jumps to (`jmp x` as its first
-- instruction, followed up to 4 times), or address itself
function databases.follow(read, address)
    for _ = 1, 4 do
        local bytes = address and read(address, 16)
        local i = bytes and fnmatch.decode(bytes, address)
        if i == nil or i.flow ~= "branch" or not i.target then
            break
        end
        address = i.target
    end
    return address
end

-- Whether the function at address does nothing (its first instruction returns): calling it again
-- is harmless, so it needs no hook to be skipped
local function returns_at_once(read, address)
    local bytes = address and read(address, 16)
    local i = bytes and fnmatch.decode(bytes, address)
    return i ~= nil and i.flow == "return"
end

-- How Lua calls a function of an entry so that the game's loop will not run it again: through the
-- trampoline of its mark (the mark's skip flag is set after), or directly if it does nothing.
-- Returns the address to call and the mark, or nil and why not.
local function callable(read, address, mark)
    if mark and mark.trampoline then
        return mark.trampoline, mark
    end
    if returns_at_once(read, address) then
        return address, nil
    end
    return nil, mark and (mark.error or (mark.shared and "shared with another database")) or "not marked"
end

-- Databases that run on the game's thread in parallel mode (they may touch graphics, sounds or
-- the interface, which the game makes on its main thread): by name
databases.MAIN_THREAD = { "Gfx", "Graphic", "Portrait", "Color", "Flag", "Ambient", "Projectile", "Frontend",
    "Advisor", "MapMode", "Sound", "Music", "Font", "Model", "Particle", "Background", "Destruction",
    "Overlay", "Icon", "Shipview", "Message", "Alert", "Greeting" }

local function on_main_thread(name)
    for _, p in ipairs(databases.MAIN_THREAD) do
        if name:find(p, 1, true) then
            return true
        end
    end
    return false
end

-- databases.run_parallel(where, progress, read, workers) -> initialized, stopped, report: the
-- loop of SetupDatabases in parallel. A database starts when the databases it depends on are done
-- (their InitInstance too, not only their CreateInstance as CanInitialize checks), from
-- databases.dependencies; one whose CanInitialize reads a global that is no database's waits for
-- every database before it in the table. It runs on a worker (stellar.db_start), or on this thread
-- (the game's) if it may need it (databases.MAIN_THREAD), meanwhile the workers go on. This
-- thread reports the progress as databases are done. If a database cannot be given back to the
-- game's loop (see databases.run), nothing runs in parallel: databases.run does the loop.
function databases.run_parallel(where, progress, read, workers)
    local stellar = require("stellar")
    local entries, plan = where.entries, {}
    for i, e in ipairs(entries) do
        local create, create_mark = callable(read, e.create, e.create_mark)
        local init, init_mark = callable(read, e.init, e.init_mark)
        if create == nil or init == nil then
            local n, stopped = databases.run(where, progress, read)
            return n, stopped, "sequential: " .. e.name .. " cannot be given back to the game's loop"
        end
        plan[i] = { create = create, init = init, create_mark = create_mark, init_mark = init_mark,
            main = on_main_thread(e.name), index = i }
        e.index = i
    end
    local count = stellar.db_workers(workers)
    local state, done, total, running = {}, 0, #entries, 0
    local t0 = (require("stellar.util")).now()
    local timeline = {}
    local function ready(e)
        for _, d in ipairs(e.depends or {}) do
            if state[d] ~= "done" then
                return false
            end
        end
        if e.barrier then
            for k = 1, e.index - 1 do
                if state[entries[k]] ~= "done" then
                    return false
                end
            end
        end
        return true
    end
    local function finish(i, thread, start, finish_time)
        local e, p = entries[i], plan[i]
        state[e] = "done"
        if p.create_mark then
            stellar.set_entry_skip(p.create_mark.id, true)
        end
        if p.init_mark then
            stellar.set_entry_skip(p.init_mark.id, true)
        end
        done = done + 1
        timeline[#timeline + 1] = { name = e.name, thread = thread, start = start, seconds = finish_time - start }
        stellar.call_progress(progress, done, total)
    end
    local util = require("stellar.util")
    while done < total do
        local progressed = false
        for i, e in ipairs(entries) do
            if state[e] == nil and ready(e) then
                local p = plan[i]
                if p.main then
                    state[e] = "running"
                    local start = util.now()
                    stellar.call(p.create)
                    stellar.call(p.init)
                    finish(i, stellar.thread_id(), start, util.now())
                    progressed = true
                elseif running < count then
                    state[e] = "running"
                    running = running + 1
                    stellar.db_start(i, p.create, p.init)
                    progressed = true
                end
            end
        end
        if running > 0 then
            for _, r in ipairs(stellar.db_wait()) do
                running = running - 1
                finish(r.id, r.thread, r.start, r.finish)
            end
        elseif not progressed then
            return done, "no database left can start", timeline
        end
    end
    -- the report: the time on the clock against the sum of the databases' times
    local sum, threads = 0, {}
    for _, t in ipairs(timeline) do
        sum = sum + t.seconds
        threads[t.thread] = (threads[t.thread] or 0) + 1
    end
    local n_threads = 0
    for _ in pairs(threads) do
        n_threads = n_threads + 1
    end
    return done, nil, string.format("parallel on %d workers and this thread (%d threads used): %.1fs on the clock for %.1fs of databases",
        count, n_threads, util.now() - t0, sum), timeline
end

-- databases.run(where, progress, read) -> initialized, stopped: the loop of SetupDatabases, in
-- Lua, before the game's: the first database left (in the table's order) whose CanInitialize is
-- true, or that has none, then its CreateInstance and InitInstance, then progress (the game's
-- std::function at `progress`). Each entry has its marks (create_mark, init_mark: their
-- trampolines and skip flags, stellar.loading). The game's loop then skips what Lua did. Lua does
-- only what it can give back: at a database whose CreateInstance or InitInstance it cannot call
-- that way, the loop stops (stopped says why), and the game's loop does the rest in its order.
function databases.run(where, progress, read, trace)
    local stellar = require("stellar")
    local left = {}
    for i = 1, #where.entries do
        left[i] = i
    end
    if trace then
        -- what each database's CreateInstance and InitInstance read of the databases' instances
        local instances = {}
        for _, e in ipairs(where.entries) do
            instances[#instances + 1] = e.instance
        end
        stellar.trace_begin(instances)
    end
    local total, initialized, stopped = #where.entries, 0, nil
    while #left > 0 do
        local pick
        for k, i in ipairs(left) do
            local e = where.entries[i]
            if e.can_initialize == nil or stellar.call(e.can_initialize) % 256 ~= 0 then
                pick = k
                break
            end
        end
        if pick == nil then
            stopped = "no database left can initialize"
            break
        end
        local index = left[pick]
        local e = where.entries[index]
        local create, create_mark = callable(read, e.create, e.create_mark)
        local init, init_mark = callable(read, e.init, e.init_mark)
        if create == nil or init == nil then
            stopped = string.format("%s: %s", e.name, tostring(create == nil and create_mark or init_mark))
            break
        end
        if create_mark then
            stellar.mark(create_mark.id)
        end
        if trace then
            stellar.trace_set(index)
        end
        stellar.call(create)
        stellar.call(init)
        if trace then
            stellar.trace_set(0)
        end
        if create_mark then
            stellar.set_entry_skip(create_mark.id, true)
        end
        if init_mark then
            stellar.set_entry_skip(init_mark.id, true)
        end
        table.remove(left, pick)
        initialized = initialized + 1
        stellar.call_progress(progress, initialized, total)
    end
    if trace then
        local records, traps = stellar.trace_end()
        databases.learn(where, records)
        where.traps = traps
    end
    return initialized, stopped
end

-- databases.learn(where, records) -> count: each entry gets learned, the databases whose instance
-- its CreateInstance or InitInstance read (records from stellar.trace_end: { [index] = addresses })
function databases.learn(where, records)
    local by_instance, count = {}, 0
    for _, e in ipairs(where.entries) do
        if e.instance then
            by_instance[e.instance] = e
        end
    end
    for index, addresses in pairs(records) do
        local e = where.entries[index]
        e.learned = {}
        for _, address in ipairs(addresses) do
            local d = by_instance[address]
            if d and d ~= e then
                e.learned[#e.learned + 1] = d
                count = count + 1
            end
        end
    end
    return count
end

-- databases.save(where, path): the dependencies learned, as "database<TAB>depends on" lines
function databases.save(where, path)
    local f = io.open(path, "w")
    if f == nil then
        return nil
    end
    for _, e in ipairs(where.entries) do
        for _, d in ipairs(e.learned or {}) do
            f:write(e.name, "\t", d.name, "\n")
        end
    end
    f:close()
    return path
end

-- databases.load(where, path) -> count | nil: the dependencies learned in an earlier load, added
-- to each entry's depends
function databases.load(where, path)
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local by_name, count = {}, 0
    for _, e in ipairs(where.entries) do
        by_name[e.name] = e
    end
    for line in f:lines() do
        local name, depends = line:match("^([^\t]+)\t([^\t]+)$")
        local e, d = by_name[name or ""], by_name[depends or ""]
        if e and d then
            local known = false
            for _, x in ipairs(e.depends) do
                known = known or x == d
            end
            if not known then
                e.depends[#e.depends + 1] = d
                count = count + 1
            end
        end
    end
    f:close()
    return count
end

return databases
