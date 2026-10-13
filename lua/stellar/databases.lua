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

local ffi = require("ffi")
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
        -- CEventManager::CreateInstance stores its instance 262 bytes in
        local bytes = read(create, 1024)
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
                    -- (unless it is there already when the databases start: run_parallel)
                    e.barrier = true
                    e.unknown_globals = e.unknown_globals or {}
                    e.unknown_globals[#e.unknown_globals + 1] = address
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

-- What the databases share and write while they initialize, found by the exception handler
-- (run_parallel: where the failures were, named with the reference builds): run under one lock
-- when they run in parallel (stellar.serialize, src/dll/database_workers.cpp).
databases.SHARED = {
    -- the global list of references to other databases' objects, resolved after the load
    -- (CPdxArray<SDatabaseObjectReference> grown under a reader)
    "CGlobalDeferredDatabaseObjectResolver::Register_Internal",
    -- the trigger database's set of every trigger (a CPdxRobinHoodTable<CTrigger*> rehashed):
    -- added to by AddTrigger, taken from by ~CTrigger (triggers made and dropped while reading)
    "CTriggerDatabase::AddTrigger",
    "CTrigger::~CTrigger",
    -- a switch's condition is read with adding triggers turned off (a flag of the trigger
    -- database): the triggers other threads made meanwhile were not added (243 of them)
    "CTriggerSwitchBase<CSwitchEffectBase<0>,CPdxScopedPtrImpl<CEffect,0> >::ReadCondition",
    "CTriggerSwitchBase<CSwitchTriggerBase<0>,CAndTrigger>::ReadCondition",
    -- the effect database's set of every effect (the same; broken, it was found only by
    -- CEffectDatabase::PostInit after the databases)
    "CEffect::CEffect",
    "CEffect::~CEffect",
    -- the lookup values' set (a table of the same kind)
    "CScriptableLookupValue::CScriptableLookupValue (the one that adds)",
    "CScriptableLookupValue::~CScriptableLookupValue",
    -- the script flags' names (CPdxIntegerFlags::_AllFlags, name -> id, and _AllFlagsReverse):
    -- names lost to a race came out as "Invalid script flag" in the effects' PostValidate
    "CPdxIntegerFlags::CreateFlagIndex",
    "CPdxIntegerFlags::GetFlagIndex",
    "CPdxIntegerFlags::GetFlagString",
    -- the post-init modifiers (modifiers read from script, finished after the databases): added
    -- to by CreatePostInitModifier, searched and taken from by ~CModifier
    "CPostInitModifierDatabase::CreatePostInitModifier",
    "CModifier::~CModifier",
    -- the event namespaces (a CHashTable<CString, CNameSpace>): made by GetNameSpace, found by
    -- IsValidIDTag and COnActionList::ReadList
    "CEventManager::GetNameSpace",
    "CHashTable<CString,CNameSpace,ClassicHashKeyTraits<CString,CNameSpace> >::Find",
    -- the modifier definitions (CPdxArray<CPdxModifierDefinition> grown under a reader: also
    -- reserved, databases.MODIFIER_ROOM): the types are numbered as they are made, so the
    -- databases that make them keep the game's order (databases.chain)
    "CModifier::TryAddDynamicModifier",
}
databases.MODIFIER_WRITER = "CModifier::TryAddDynamicModifier"
-- what numbers things as they are made: the databases that call it (recorded by the lock, in
-- cache/database_<file>-<md5>.tsv) run one after another in the game's order (databases.chain)
databases.ORDERED = {
    { name = "CModifier::TryAddDynamicModifier", file = "modifier_writers", what = "modifier types" },
    { name = "CPdxIntegerFlags::CreateFlagIndex", file = "flag_writers", what = "script flag ids" },
}
databases.MODIFIER_RESERVE = "CPdxArray<CPdxModifierDefinition<enum ModifierType,enum ModifierCategory>,int>::Reserve"
-- room for this many modifier definitions before the databases (vanilla 4.5.2 makes 45,583)
databases.MODIFIER_ROOM = 131072

-- functions of databases.SHARED the signatures may miss (none in the Steam 4.5.2 build), found as
-- the first call of a function they find
databases.SHARED_FIRST_CALL = {
    ["CHashTable<CString,CNameSpace,ClassicHashKeyTraits<CString,CNameSpace> >::Find"] = "CEventManager::GetNameSpace",
    ["CScriptableLookupValue::CScriptableLookupValue (the one that adds)"] = "CScriptableLookupValue::CScriptableLookupValue",
}

local function first_call(read, address)
    local bytes, pos = read(address, 96), 1
    for _ = 1, 16 do
        local i = bytes and pos <= #bytes - 15 and fnmatch.decode(bytes, address, pos)
        if not i then
            return nil
        end
        if i.flow == "call" then
            return i.target
        end
        pos = pos + i.length
    end
end

-- databases.serialize(found, read) -> slots, failed: each function of databases.SHARED runs under
-- the lock (slots[name] = its slot for stellar.serialized), failed lists what could not be
function databases.serialize(found, read)
    local stellar = require("stellar")
    local slots, failed = {}, {}
    -- every address first: a hook rewrites the start of the function a first call is read from
    local addresses = {}
    for _, name in ipairs(databases.SHARED) do
        addresses[name] = found[name]
        local from = databases.SHARED_FIRST_CALL[name]
        if addresses[name] == nil and from and found[from] then
            addresses[name] = first_call(read, found[from])
        end
    end
    for _, name in ipairs(databases.SHARED) do
        local slot, why
        local address = addresses[name]
        if address then
            -- the modifier types' writer also holds the index's lock: no lookup indexes a definition
            -- it added before it filled it
            slot, why = stellar.serialize(address, name == databases.MODIFIER_WRITER)
        else
            why = "not found"
        end
        if slot then
            slots[name] = slot
        else
            failed[#failed + 1] = name .. ": " .. tostring(why)
        end
    end
    return slots, failed
end

-- databases.load_names(path) -> names | nil, and databases.save_names(path, names): a file of
-- database names, one a line
function databases.load_names(path)
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local names = {}
    for line in f:lines() do
        if line ~= "" then
            names[#names + 1] = line
        end
    end
    f:close()
    return names
end

function databases.save_names(path, names)
    local f = io.open(path, "w")
    if f == nil then
        return nil
    end
    for _, name in ipairs(names) do
        f:write(name, "\n")
    end
    f:close()
    return path
end

-- databases.chain(where, names, order) -> count: the databases named run one after another in the
-- game's order (order: names, databases.load_order): each depends on the one before it. For what
-- numbers things as they are made (the modifier types): parallel, they would be numbered otherwise
function databases.chain(where, names, order)
    local by_name, rank = {}, {}
    for _, e in ipairs(where.entries) do
        by_name[e.name] = e
    end
    for i, name in ipairs(order) do
        rank[name] = i
    end
    local list = {}
    for _, name in ipairs(names) do
        if by_name[name] and rank[name] then
            list[#list + 1] = by_name[name]
        end
    end
    table.sort(list, function(a, b) return rank[a.name] < rank[b.name] end)
    local count = 0
    for i = 2, #list do
        local e, before = list[i], list[i - 1]
        e.depends = e.depends or {}
        local has = false
        for _, d in ipairs(e.depends) do
            has = has or d == before
        end
        if not has then
            e.depends[#e.depends + 1] = before
            count = count + 1
        end
    end
    return count
end

-- databases.load_conflicts(where, path) -> count | nil: the conflicts learned in earlier loads (a
-- database that failed while others ran: "database<TAB>database" lines), symmetric, in each
-- entry's conflicts: two databases in conflict never run at the same time
function databases.load_conflicts(where, path)
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local by_name, count = {}, 0
    for _, e in ipairs(where.entries) do
        by_name[e.name] = e
        e.conflicts = e.conflicts or {}
    end
    for line in f:lines() do
        local a, b = line:match("^([^\t]+)\t([^\t]+)$")
        local ea, eb = by_name[a or ""], by_name[b or ""]
        if ea and eb and ea ~= eb and not ea.conflicts[eb] then
            ea.conflicts[eb], eb.conflicts[ea] = true, true
            count = count + 1
        end
    end
    f:close()
    return count
end

-- databases.load_after(where, path) -> count | nil: what failed loads learned a database waits for
-- ("database<TAB>what it waits for" lines, run_parallel), added to the entries' depends
function databases.load_after(where, path)
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local by_name, count = {}, 0
    for _, e in ipairs(where.entries) do
        by_name[e.name] = e
    end
    for line in f:lines() do
        local a, b = line:match("^([^\t]+)\t([^\t]+)$")
        local ea, eb = by_name[a or ""], by_name[b or ""]
        if ea and eb and ea ~= eb then
            ea.depends = ea.depends or {}
            local has = false
            for _, d in ipairs(ea.depends) do
                has = has or d == eb
            end
            if not has then
                ea.depends[#ea.depends + 1] = eb
                count = count + 1
            end
        end
    end
    f:close()
    return count
end

-- databases.run_parallel(where, progress, read, workers, conflicts_path, inflight_path, after_path, order,
-- errors_log, durations) -> initialized, stopped,
-- report, timeline, failure: the loop of SetupDatabases in parallel. A database starts when the
-- databases it depends on are done (their InitInstance too, not only their CreateInstance as
-- CanInitialize checks), from databases.dependencies; one whose CanInitialize reads a global that
-- is no database's waits for every database before it in the table; none starts while a database
-- it conflicts with runs (databases.load_conflicts). It runs on a worker (stellar.db_start), or on
-- this thread (the game's) if it may need it (databases.MAIN_THREAD), meanwhile the workers go on.
-- This thread reports the progress as databases are done.
--
-- Each database runs under an exception handler (src/dll/database_workers.cpp). When one fails,
-- it conflicts with every database that ran while it did: those pairs are added to conflicts_path,
-- nothing more starts, the running ones are waited for (10s at most), and failure says what
-- happened (the load cannot go on: the database is half made; the next load knows the conflict).
-- With the game's order (order, names: databases.load_order), the failed database also waits, in
-- the next loads, for the databases before it in that order that were not done when it started
-- (after_path, databases.load_after): what it used may not have been made yet, which no exclusion
-- fixes. The game's error log (errors_log) is a failure too: the game logs no error while its
-- databases initialize, so the databases that ran while it grew learn the same waits. A failure
-- no handler sees (a broken heap ends the game at once) is learned by the next
-- load from inflight_path (databases.recover_inflight). If a database cannot be given back to the
-- game's loop (see databases.run), nothing runs in parallel: databases.run does the loop.
--
-- options.early: the databases start before SetupDatabases, from a thread of Lua's while the game's
-- thread loads the interface and the graphics (stellar.early): only on the workers, without
-- progress, and not those that need the game's thread (databases.MAIN_THREAD), a global not set
-- yet, or the game's phases (e.late: databases.load_late); it returns once nothing more can start
-- (resume, the sixth result, carries on). options.resume: carries on from that run, at
-- SetupDatabases. The sixth result also says which databases failed or ran while the error log grew
-- (failed: names).
function databases.run_parallel(where, progress, read, workers, conflicts_path, inflight_path, after_path, order, errors_log,
    durations, options)
    local stellar = require("stellar")
    local util = require("stellar.util")
    options = options or {}
    local early, resume = options.early, options.resume
    local entries, plan = where.entries, {}
    local state, timeline = resume and resume.state or {}, resume and resume.timeline or {}
    local failed_names = {}
    -- what runs now and what ended in the last quarter second, kept in inflight_path: if the game
    -- dies of something no handler sees (the heap found broken: a fail-fast), the next load learns
    -- from it (databases.recover_inflight). A broken heap is found after the write that broke it,
    -- by whoever uses that block next: the quarter second is a guess at how long that takes (a
    -- whole second named 35 databases once, most of them short and innocent)
    local function write_inflight()
        local f = inflight_path and io.open(inflight_path, "w")
        if f == nil then
            return
        end
        -- (beside the game's phases: what ran then waits for them, databases.recover_inflight)
        if early then
            f:write("#early\n")
        end
        for e, s in pairs(state) do
            if s == "running" then
                f:write(e.name, "\n")
            end
        end
        local now = util.system_time()
        for k = #timeline, 1, -1 do
            local t = timeline[k]
            if t.start + t.seconds < now - 0.25 then
                break
            end
            f:write(t.name, "\n")
        end
        f:close()
    end
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
        e.conflicts = e.conflicts or {}
    end
    -- with the game's order: every database it made before another can be waited for by it, none
    -- after (in the game, the later one was not made yet: a read of it found nothing, or only
    -- checked it was there), so what waits for a later one is dropped (it would make a cycle
    -- with the waits learned), and a barrier waits for what the game made before it
    local rank = {}
    for k, name in ipairs(order or {}) do
        rank[name] = k
    end
    local depends, before, dropped = {}, {}, 0
    for _, e in ipairs(entries) do
        depends[e] = {}
        for _, d in ipairs(e.depends or {}) do
            if rank[e.name] and rank[d.name] and rank[d.name] > rank[e.name] then
                dropped = dropped + 1
            else
                depends[e][#depends[e] + 1] = d
            end
        end
        before[e] = {}
        -- a global that is not a database's but is set already (CGui::_pGui: the GUI is loaded
        -- before the databases) waits for nothing; early, one not set yet waits for SetupDatabases
        local barrier = false
        for _, g in ipairs(e.unknown_globals or {}) do
            barrier = barrier or ffi.cast("void **", g)[0] == nil
        end
        e.unset_global = barrier
        if e.barrier and barrier and not early then
            for k, other in ipairs(entries) do
                if other ~= e and ((rank[e.name] and rank[other.name] and rank[other.name] < rank[e.name])
                    or (not (rank[e.name] and rank[other.name]) and k < e.index)) then
                    before[e][#before[e] + 1] = other
                end
            end
        end
    end
    where.dropped_depends = dropped
    -- which first, of those ready: the one with the longest chain still to come after it (its
    -- time and the longest of what waits for it, with each database's time from the last boot,
    -- durations), not the table's order (a short database late in the table that a long one
    -- waits for started seconds late)
    local waiting_for = {}
    for _, e in ipairs(entries) do
        for _, d in ipairs(depends[e]) do
            waiting_for[d] = waiting_for[d] or {}
            table.insert(waiting_for[d], e)
        end
        for _, d in ipairs(before[e]) do
            waiting_for[d] = waiting_for[d] or {}
            table.insert(waiting_for[d], e)
        end
    end
    local chain = {}
    local function chain_of(e)
        if chain[e] == nil then
            chain[e] = 0  -- (no cycle: what waits comes later in the game's order)
            local longest = 0
            for _, w in ipairs(waiting_for[e] or {}) do
                longest = math.max(longest, chain_of(w))
            end
            chain[e] = ((durations or {})[e.name] or 0.01) + longest
        end
        return chain[e]
    end
    local by_priority = {}
    for i, e in ipairs(entries) do
        chain_of(e)
        by_priority[i] = e
    end
    table.sort(by_priority, function(a, b)
        if chain[a] ~= chain[b] then
            return chain[a] > chain[b]
        end
        return a.index < b.index
    end)
    local count = stellar.db_workers(workers)
    local done, total, running = 0, #entries, 0
    for _, s in pairs(state) do
        done = done + (s == "done" and 1 or 0)
    end
    local t0 = resume and resume.t0 or util.system_time()
    local started = resume and resume.started or {}
    -- early: what waits for SetupDatabases
    local function held(e, p)
        return early and (p.main or e.late or (e.barrier and e.unset_global))
    end
    local function ready(e)
        for _, d in ipairs(depends[e]) do
            if state[d] ~= "done" then
                return false
            end
        end
        for _, d in ipairs(before[e]) do
            if state[d] ~= "done" then
                return false
            end
        end
        for other in pairs(e.conflicts) do
            if state[other] == "running" then
                return false
            end
        end
        return true
    end
    if not resume then
        where.done_order = {}
    end
    local failure
    -- a database that failed may have used what a database before it in the game's order makes,
    -- not made yet (no lock helps that): it waits for every one of those that was not done when
    -- it started (after_path) -> how many. Beside the game's phases (early), what it missed is taken
    -- to be the phases' (the caller makes it wait for them): no waits
    local function learn_waits(e, start)
        local waits = 0
        if after_path and rank[e.name] and not early then
            local done_before = {}
            for _, t in ipairs(timeline) do
                if t.start + t.seconds <= start then
                    done_before[t.entry] = true
                end
            end
            local out = io.open(after_path, "a")
            if out then
                for _, other in ipairs(entries) do
                    if other ~= e and rank[other.name] and rank[other.name] < rank[e.name] and not done_before[other] then
                        out:write(e.name, "\t", other.name, "\n")
                        waits = waits + 1
                    end
                end
                out:close()
            end
        end
        return waits
    end
    -- the game's error log: the game logs no error while its databases initialize (vanilla
    -- 4.5.2), so one that grows while a database runs says that it ran before what it needed (an
    -- event it names, a modifier's category, ...): a failure without an exception
    local errors_path = errors_log
    local function errors_size()
        local f = errors_path and io.open(errors_path, "rb")
        if f == nil then
            return 0
        end
        local size = f:seek("end")
        f:close()
        return size or 0
    end
    local errors_at_start, erred = resume and resume.errors_at_start or {}, {}
    -- an address in the game as +rva (to name with the reference builds), else as is
    local function game_address(a)
        local base = stellar.module_base
        if base and a >= base and a < base + 0x10000000 then
            return "+" .. util.hex(a - base):sub(3)
        end
        return util.hex(a)
    end
    -- a database stopped by an exception (what: { address, stack, type }): it conflicts with every
    -- database that ran while it did
    local function failed(i, thread, start, finish_time, code, what)
        what = what or {}
        local address = what.address or 0
        local e = entries[i]
        state[e] = "failed"
        failed_names[#failed_names + 1] = e.name
        local with = {}
        for _, t in ipairs(timeline) do
            if t.entry ~= e and t.start < finish_time and t.start + t.seconds > start then
                with[#with + 1] = t.entry
            end
        end
        for other, s in pairs(started) do
            if other ~= e and state[other] == "running" and s < finish_time then
                with[#with + 1] = other
            end
        end
        local names = {}
        local f = conflicts_path and io.open(conflicts_path, "a")
        for _, other in ipairs(with) do
            names[#names + 1] = other.name
            if f then
                f:write(e.name, "\t", other.name, "\n")
            end
        end
        if f then
            f:close()
        end
        local waits = learn_waits(e, start)
        local stack = {}
        for k, a in ipairs(what.stack or {}) do
            stack[k] = game_address(a)
        end
        local text = string.format("%s failed on thread %d (exception 0x%08x%s at %s, +%.3fs) while %d others ran: %s; it waits for %d before it in the game's order; stack %s",
            e.name, thread, code, (what.type or "") ~= "" and (" " .. what.type) or "", game_address(address),
            start - t0, #names, table.concat(names, ", "), waits, table.concat(stack, " "))
        -- said now: what the failure broke may end the game before the caller can say it
        stellar.log("databases: " .. text)
        failure = failure or text
        -- learned: the in-flight file goes (the pairs above say more)
        if inflight_path then
            os.remove(inflight_path)
        end
    end
    -- what held a database back when it started: the constraint that ended last before it (a
    -- dependency, or "before" for a barrier), or, when that ended well before, the loop (no
    -- worker was free, or this thread ran a database of its own)
    local ended, gates = resume and resume.ended or {}, resume and resume.gates or {}
    local function gate_of(e, at)
        local name, why, last = nil, nil, -1
        for _, d in ipairs(depends[e]) do
            if (ended[d] or -1) > last then name, why, last = d.name, "dependency", ended[d] end
        end
        for _, d in ipairs(before[e]) do
            if (ended[d] or -1) > last then name, why, last = d.name, "before (barrier)", ended[d] end
        end
        if name == nil or last < at - 0.02 then
            return "the loop", last
        end
        return name .. " (" .. why .. ")", last
    end
    local function finish(i, thread, start, finish_time)
        local e, p = entries[i], plan[i]
        state[e] = "done"
        ended[e] = finish_time
        where.done_order[#where.done_order + 1] = e
        if p.create_mark then
            stellar.set_entry_skip(p.create_mark.id, true)
        end
        if p.init_mark then
            stellar.set_entry_skip(p.init_mark.id, true)
        end
        done = done + 1
        timeline[#timeline + 1] = { entry = e, name = e.name, thread = thread, start = start, seconds = finish_time - start,
            gate = gates[e] }
        if errors_size() > (errors_at_start[e] or math.huge) then
            erred[#erred + 1] = e
        end
        write_inflight()
        if progress then
            stellar.call_progress(progress, done, total)
        end
    end
    while done < total and failure == nil do
        local progressed, ran_here = false, false
        -- the free workers first, the longest chains first
        for _, e in ipairs(by_priority) do
            local i = e.index
            local p = plan[i]
            if failure == nil and running < count and not p.main and not held(e, p) and state[e] == nil and ready(e) then
                state[e] = "running"
                write_inflight()
                errors_at_start[e] = errors_size()
                started[e] = util.system_time()
                gates[e] = gate_of(e, started[e])
                running = running + 1
                stellar.db_start(i, p.create, p.init)
                progressed = true
            end
        end
        -- then one of this thread's (meanwhile the loop starts nothing)
        for _, e in ipairs(by_priority) do
            local i = e.index
            local p = plan[i]
            if failure == nil and not early and p.main and state[e] == nil and ready(e) then
                state[e] = "running"
                write_inflight()
                errors_at_start[e] = errors_size()
                local start = util.system_time()
                started[e] = start
                gates[e] = gate_of(e, start)
                local code, what = stellar.db_call(p.create, p.init, i)
                if code ~= 0 then
                    failed(i, stellar.thread_id(), start, util.system_time(), code, what)
                else
                    finish(i, stellar.thread_id(), start, util.system_time())
                end
                progressed, ran_here = true, true
                break
            end
        end
        if running > 0 then
            -- after one of this thread's, only what is done already: the workers may be free
            for _, r in ipairs(stellar.db_wait(ran_here and 0 or nil)) do
                running = running - 1
                if r.exception ~= 0 then
                    failed(r.id, r.thread, r.start, r.finish, r.exception, r)
                else
                    finish(r.id, r.thread, r.start, r.finish)
                end
            end
        elseif not progressed then
            if inflight_path then
                os.remove(inflight_path)
            end
            if early then
                -- the rest waits for SetupDatabases
                break
            end
            -- what the first ones left wait for (a cycle is a bug: say where it is)
            local blocked = {}
            for _, e in ipairs(entries) do
                if state[e] == nil and #blocked < 5 then
                    local missing = {}
                    for _, d in ipairs(depends[e]) do
                        if state[d] ~= "done" then
                            missing[#missing + 1] = d.name
                        end
                    end
                    for _, d in ipairs(before[e]) do
                        if state[d] ~= "done" and #missing < 8 then
                            missing[#missing + 1] = d.name .. " (before it)"
                        end
                    end
                    blocked[#blocked + 1] = e.name .. " waits for " .. table.concat(missing, ", ")
                end
            end
            return done, "no database left can start: " .. table.concat(blocked, "; "), nil, timeline
        end
    end
    -- what a resumed run carries on from, and what failed
    local function carry()
        return { state = state, timeline = timeline, started = started, ended = ended, gates = gates,
            errors_at_start = errors_at_start, t0 = t0, failed = failed_names }
    end
    if failure then
        -- what still runs is waited for (it may never end: the failure may have broken what it uses)
        local deadline = util.system_time() + 10
        while running > 0 and util.system_time() < deadline do
            for _, r in ipairs(stellar.db_wait(1)) do
                running = running - 1
                if r.exception ~= 0 then
                    failed(r.id, r.thread, r.start, r.finish, r.exception, r)
                end
            end
        end
        return done, nil, nil, timeline, failure, carry()
    end
    if inflight_path then
        os.remove(inflight_path)
    end
    -- errors logged while databases ran: each of them waits for what it ran before (the load goes
    -- on in a state the game's order would not make: a failure)
    if #erred > 0 then
        local names, waits = {}, 0
        for _, e in ipairs(erred) do
            names[#names + 1] = e.name
            failed_names[#failed_names + 1] = e.name
            waits = waits + learn_waits(e, started[e] or t0)
        end
        failure = string.format("the error log grew while %d databases ran (%s): they wait for %d before them in the game's order",
            #erred, table.concat(names, ", "), waits)
        stellar.log("databases: " .. failure)
        return done, nil, nil, timeline, failure, carry()
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
    return done, nil, string.format("parallel on %d workers%s (%d threads used): %.1fs on the clock for %.1fs of databases",
        count, early and ", beside the game's phases" or " and this thread", n_threads, util.system_time() - t0, sum),
        timeline, nil, carry()
end

-- databases.recover_inflight(inflight_path, conflicts_path, late_path) -> count, names, late | nil:
-- if the last load died while databases ran in parallel (its in-flight file is still there, see
-- run_parallel), those databases conflict with each other: every pair goes to conflicts_path, the
-- file goes. If they ran beside the game's phases (early), they wait for the phases instead
-- (late_path, databases.save_late; late is true).
function databases.recover_inflight(inflight_path, conflicts_path, late_path)
    local f = io.open(inflight_path, "r")
    if f == nil then
        return nil
    end
    local names, seen, early = {}, {}, false
    for line in f:lines() do
        if line == "#early" then
            early = true
        elseif line ~= "" and not seen[line] then
            seen[line] = true
            names[#names + 1] = line
        end
    end
    f:close()
    os.remove(inflight_path)
    if early and late_path then
        return databases.save_late(late_path, names), names, true
    end
    local out, count = io.open(conflicts_path, "a"), 0
    if out then
        for i = 1, #names do
            for j = i + 1, #names do
                out:write(names[i], "\t", names[j], "\n")
                count = count + 1
            end
        end
        out:close()
    end
    return count, names
end

-- The databases that wait for the game's phases (the interface and the graphics) when the
-- databases start beside them (run_parallel, options.early): one name a line, learned from
-- failures there (a database that failed, or ran while the error log grew or the game died)
-- databases.save_late(path, names) -> how many were new
function databases.save_late(path, names)
    local known = {}
    for _, name in ipairs(databases.load_names(path) or {}) do
        known[name] = true
    end
    local out, added = io.open(path, "a"), 0
    for _, name in ipairs(names) do
        if not known[name] then
            known[name] = true
            added = added + 1
            if out then
                out:write(name, "\n")
            end
        end
    end
    if out then
        out:close()
    end
    return added
end

-- databases.load_late(where, path) -> count: e.late for each of them
function databases.load_late(where, path)
    local late, count = {}, 0
    for _, name in ipairs(databases.load_names(path) or {}) do
        late[name] = true
    end
    for _, e in ipairs(where.entries) do
        e.late = late[e.name] or nil
        count = count + (e.late and 1 or 0)
    end
    return count
end

-- databases.load_durations(path) -> { name -> seconds } | nil: each database's time in the boot
-- order kept last (databases.save_boot_order), for run_parallel's priorities
function databases.load_durations(path)
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local out = {}
    for line in f:lines() do
        local name, seconds = line:match("^([^\t]+)\t[^\t]+\t([^\t]+)\t")
        if name and tonumber(seconds) then
            out[name] = tonumber(seconds)
        end
    end
    f:close()
    return out
end

-- databases.save_boot_order(timeline, t0, path): the order a load initialized the databases in,
-- when each started and how long it took, on which thread, and what it waited for last (the boot
-- order that worked)
function databases.save_boot_order(timeline, t0, path)
    local f = io.open(path, "w")
    if f == nil then
        return nil
    end
    f:write("database\tstart\tseconds\tthread\tafter\n")
    for _, t in ipairs(timeline) do
        f:write(string.format("%s\t%.3f\t%.3f\t%d\t%s\n", t.name, t.start - t0, t.seconds, t.thread, t.gate or "-"))
    end
    f:close()
    return path
end

-- databases.skip_post_reads(where, order) -> list: after Lua's loop, the PostReadInitInstance of
-- every database Lua initialized, in that order, that the game's loop will skip (the skip flags of
-- their marks set): databases.run_post_reads calls them in that order, as the game would have.
-- order (names, databases.load_order) is the game's order where the loop's is not (in parallel):
-- the modifier types the PostReads make are numbered as they are made
function databases.skip_post_reads(where, order)
    local stellar = require("stellar")
    local list, rank = {}, {}
    for i, name in ipairs(order or {}) do
        rank[name] = i
    end
    for k, e in ipairs(where.done_order or {}) do
        local m = e.post_mark
        if m and m.trampoline then
            stellar.set_entry_skip(m.id, true)
            list[#list + 1] = e
            e.done_rank = k
        end
    end
    if order then
        table.sort(list, function(a, b)
            local ra, rb = rank[a.name] or (#order + a.done_rank), rank[b.name] or (#order + b.done_rank)
            return ra < rb
        end)
    end
    return list
end

-- databases.save_order(where, path): the order the game's loop (or Lua's, the same) initialized
-- the databases in, one name a line (databases.load_order)
function databases.save_order(where, path)
    local names = {}
    for _, e in ipairs(where.done_order or {}) do
        names[#names + 1] = e.name
    end
    return databases.save_names(path, names)
end

-- databases.load_order(path) -> names | nil
databases.load_order = databases.load_names

-- databases.run_post_reads(list): their PostReadInitInstance, in order (through the trampolines,
-- with the event of their mark for the logs), then their skip flags cleared
function databases.run_post_reads(list)
    local stellar = require("stellar")
    for _, e in ipairs(list) do
        stellar.mark(e.post_mark.id)
        stellar.call(e.post_mark.trampoline)
        stellar.set_entry_skip(e.post_mark.id, false)
    end
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
    -- the databases in the order they are initialized (the game's PostReadInitInstance order)
    where.done_order = {}
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
        where.done_order[#where.done_order + 1] = e
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
