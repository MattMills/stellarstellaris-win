-- init.lua : run by stellar-injected once it is loaded into the game.
--
-- `stellar` is the DLL (see src/dll/lua.cpp): log(...), suspend_threads(), resume_threads(),
-- read(address, size), patch(address, bytes), thread_id(), heartbeat (a function called every
-- second), and the fields module_base, module_path, process_id, dll_path, lua_dir, git_hash.
-- `fnmatch` finds code and decodes instructions; the LuaJIT FFI reads and writes memory.
--
-- game.lua hooks the turn tick: scripts get the game state every tick (10 per game day).

local stellar = require("stellar")
local fnmatch = require("fnmatch")
local util = require("stellar.util")
local game = require("stellar.game")
local hex = util.hex

stellar.log(string.format("%s with %s (stellar-fnmatch %s), stellar-injected %s", jit and jit.version or _VERSION,
    fnmatch._VERSION, fnmatch.fnmatch_version, stellar.git_hash))
stellar.log(string.format("game %s at %s, init thread %d", stellar.module_path, hex(stellar.module_base),
    stellar.thread_id()))

-- one analysis of the game for everything below (kept in cache/ by md5)
local t0 = util.now()
local image, message = fnmatch.module("stellaris.exe", { cache = util.dirname(stellar.dll_path) .. "\\cache" })
if image == nil then
    stellar.log("cannot analyse the game: " .. tostring(message))
    return
end
stellar.log(string.format("%s analysed in %.1fs, %d functions, md5 %s", image:path(), util.now() - t0, #image, image:md5()))

-- setting(file, default) -> the first word of that file next to the DLL (or default), and the
-- second word
local function setting(file, default)
    local f = io.open(util.dirname(stellar.dll_path) .. "\\" .. file, "r")
    if f == nil then
        return default
    end
    local word, second = (f:read("*l") or ""):match("^%s*(%w*)%s*(%w*)")
    f:close()
    return (word ~= "" and word) or default, second ~= "" and second or nil
end

-- first: the game's script lexer (stellar.script.loader), hooked before the game reads its script.
-- The mode is the first word of lexer.txt next to the DLL: "replace" (the default: the game reads
-- its script with the Lua lexer), "shadow" (the game's lexer reads, every token is compared with
-- the Lua lexer's) or "off"
local lexer_mode = setting("lexer.txt", "replace")
local loader = require("stellar.script.loader")
local lexer_where, lexer_message = loader.locate(image, stellar.read)
if lexer_mode == "off" then
    stellar.log("loader: the lexer hook is off (lexer.txt)")
elseif lexer_where then
    local hooked, hook_message = loader.hook(lexer_where, lexer_mode)
    stellar.log(string.format("loader: CTextLexer::GetTok %s, CMemoryFile vtable %s, token tree %s, CToken::SetCharInString %s: %s",
        hex(lexer_where.get_tok), hex(lexer_where.memory_file_vtable), hex(lexer_where.token_tree),
        lexer_where.set_char and hex(lexer_where.set_char) or "not found", hooked and ("hooked (" .. lexer_mode .. ")") or ("not hooked: " .. tostring(hook_message))))
else
    stellar.log("loader: " .. tostring(lexer_message))
end

-- the load screen's stages and progress, logged from the heartbeat (stellar.loading)
local loading = require("stellar.loading")
local loading_where, loading_message = loading.locate(image, stellar.read)
if loading_where then
    stellar.log(string.format("load: SPushLoadScreenState %s, ~SPushLoadScreenState %s, RenderLoadScreen %s, LoadingScreenCallback %s, progress context at %s",
        hex(loading_where.push), hex(loading_where.pop), hex(loading_where.render), hex(loading_where.step),
        hex(loading_where.context)))
    local hooked, hook_message = loading.hook(loading_where, stellar.read)
    if not hooked then
        stellar.log("load: not hooked: " .. tostring(hook_message))
    end
else
    stellar.log("load: " .. tostring(loading_message))
end

-- the game databases (stellar.databases): the table SetupDatabases initializes them from. Marks
-- on each one's CreateInstance and PostReadInitInstance and on the steps of InitGame around them,
-- so that the log has each database with its time and texts, and what the load does after 100%
local databases = require("stellar.databases")
local databases_where, databases_message = databases.locate(image, stellar.read)
local marks = {}
local databases_unknown = {}
if databases_where then
    -- their dependencies, from the code (before the marks hook it)
    databases_unknown = databases.dependencies(databases_where, stellar.read)
    -- CreateInstance and InitInstance: also how Lua runs the loop (their trampolines and skip flags)
    -- (a thunk that jumps to the function is followed: the function is marked)
    for _, e in ipairs(databases_where.entries) do
        e.create_mark = { address = databases.follow(stellar.read, e.create), kind = "create", name = e.name }
        marks[#marks + 1] = e.create_mark
    end
    for _, e in ipairs(databases_where.entries) do
        e.init_mark = { address = databases.follow(stellar.read, e.init), kind = "init", name = e.name }
        marks[#marks + 1] = e.init_mark
    end
    for _, e in ipairs(databases_where.entries) do
        marks[#marks + 1] = { address = e.post_read, kind = "post_read", name = e.name }
    end
    stellar.log(string.format("databases: SetupDatabases %s, %d databases", hex(databases_where.setup),
        #databases_where.entries))
else
    stellar.log("databases: " .. tostring(databases_message))
end
local found = require("stellar.resolve").functions(image)
for _, name in ipairs(loading.MILESTONES) do
    marks[#marks + 1] = { address = found[name], kind = "milestone", name = name }
end
local marks_hooked, marks_failed = loading.hook_marks(marks)
stellar.log(string.format("load: %d marks hooked%s", marks_hooked,
    #marks_failed > 0 and ("; not hooked: " .. table.concat(marks_failed, "; ")) or ""))
-- The databases' loop in Lua: databases.txt next to the DLL says who runs it, "lua" (the default:
-- stellar.databases.run, before the game's loop, which then skips what Lua did), "trace" (the
-- same, learning what each database reads of the others: cache/database_dependencies-<md5>.tsv),
-- "parallel N" (databases.run_parallel on N workers, default 4, with the dependencies learned: an
-- experiment, the game's databases share tables that are not all locked yet) or "game"
local database_mode, database_workers = setting("databases.txt", "lua")
local dependencies_path = util.dirname(stellar.dll_path) .. "\\cache\\database_dependencies-" .. image:md5() .. ".tsv"
if databases_where and database_mode == "parallel" then
    local learned = databases.load(databases_where, dependencies_path)
    stellar.log(learned and string.format("databases: %d dependencies learned in a trace added", learned)
        or "databases: no dependencies learned yet (run once with databases.txt \"trace\"): one at a time")
    if not learned then
        database_mode = "lua"
    end
end
if databases_where and database_mode == "parallel" then
    -- the token table, which the databases add to, is locked
    local add = found["CStaticLexer::AddDynamicToken"]
    local memory = require("stellar.script.memory")
    local function pointer(address)
        local bytes = address and address ~= 0 and stellar.read(address, 8)
        return bytes and memory.u64(bytes, 0) or nil
    end
    -- the tree's find: the third slot of its vtable
    local tree = lexer_where and lexer_where.token_tree and stellar.call(lexer_where.token_tree)
    local vtable = pointer(tree)
    local find = vtable and pointer(vtable + 16)
    local locked, lock_message = nil, "AddDynamicToken or the token tree not found"
    if add and find then
        locked, lock_message = stellar.db_lock_tokens(add, find)
    end
    stellar.log("databases: the token table " .. (locked and "is locked" or ("is not locked: " .. tostring(lock_message))))
    if not locked then
        database_mode = "lua"
    end
end
if databases_where and (database_mode == "lua" or database_mode == "parallel" or database_mode == "trace") then
    stellar.setup_databases = function(a, done, progress)
        loading.milestone("NNullObjAndDatabaseInitUtil::SetupDatabases")
        local t0 = util.now()
        local n, stopped, report
        if database_mode == "parallel" then
            local timeline
            n, stopped, report, timeline = databases.run_parallel(databases_where, progress, stellar.read,
                tonumber(database_workers) or 4)
            for _, t in ipairs(timeline or {}) do
                stellar.log(string.format("databases:   %s on thread %d: +%.3fs, %.3fs", t.name, t.thread, t.start - t0,
                    t.seconds))
            end
        else
            n, stopped = databases.run(databases_where, progress, stellar.read, database_mode == "trace")
            if database_mode == "trace" then
                local count, beyond = 0, 0
                for _, e in ipairs(databases_where.entries) do
                    for _, d in ipairs(e.learned or {}) do
                        count = count + 1
                        local declared = false
                        for _, x in ipairs(e.depends or {}) do
                            declared = declared or x == d
                        end
                        beyond = beyond + (declared and 0 or 1)
                    end
                end
                report = string.format("trace: %d reads of other databases (%d not declared by CanInitialize), %d traps; saved to %s",
                    count, beyond, databases_where.traps or 0, tostring(databases.save(databases_where, dependencies_path)))
            end
        end
        stellar.log(string.format("databases: Lua initialized %d of %d databases in %.1fs%s%s", n,
            #databases_where.entries, util.now() - t0, stopped and ("; the game does the rest from " .. stopped) or "",
            report and ("; " .. report) or ""))
    end
    local hooked, message = stellar.hook_setup_databases(databases_where.setup)
    stellar.log("databases: the loop runs in Lua" .. (hooked and "" or (": not hooked: " .. tostring(message))))
else
    stellar.log("databases: the loop is the game's (" .. database_mode .. ")")
end
-- the read: the files listed, read and parsed
local reads_hooked, reads_failed = loading.hook_reads(found)
stellar.log(string.format("load: read hooks: %d of 4%s", reads_hooked,
    #reads_failed > 0 and ("; not hooked: " .. table.concat(reads_failed, "; ")) or ""))

-- the turn tick reaches Lua: log the first ticks, then each new month, with how long the tick that
-- started it took (the tick that runs MonthlyUpdate) and the ticks of the month
local ticks, month_ticks, started = 0, 0, 0
game.before_tick(function(gamestate, db)
    started = util.now()
end)
game.after_tick(function(gamestate, db)
    ticks = ticks + 1
    month_ticks = month_ticks + 1
    if ticks <= 3 then
        stellar.log(string.format("tick %d (%s) in %.1f ms; CGameState %s (%s g_CurrentGameState), database %s, thread %d",
            ticks, game.date_string(gamestate), (util.now() - started) * 1000, hex(gamestate),
            game.current() == gamestate and "=" or "NOT", hex(db), stellar.thread_id()))
    end
end)
game.after_day(function(gamestate, db)
    local _, _, day = game.date(gamestate)
    if day == 1 then
        stellar.log(string.format("new month %s: its first tick took %.1f ms, %d ticks since the last one",
            game.date_string(gamestate), (util.now() - started) * 1000, month_ticks))
        month_ticks = 0
    end
end)

-- The script engine: its tokens, triggers and effects (stellar.script.catalog), compared with the
-- game's own documentation of them, and written to cache/script_catalog-<md5>.tsv. The game writes
-- its documentation and builds the lexer's id -> name lookup once it has loaded, so the catalog is
-- read from the heartbeat when both are there (or with what there is after two minutes).
local catalog, docs = require("stellar.script.catalog"), require("stellar.script.docs")
local script_where, script_message = catalog.locate(image, stellar.read)
if script_where == nil then
    stellar.log("script: cannot locate the script tables: " .. tostring(script_message))
end
local catalog_path = util.dirname(stellar.dll_path) .. "\\cache\\script_catalog-" .. image:md5() .. ".tsv"

-- how long (heartbeats, seconds) to wait for the game to load before reading what there is: the
-- game writes its script documentation once its databases are loaded, which takes minutes with
-- large mods
local WAIT_FOR_LOAD = 600

local function read_catalog(waited)
    local d = docs.read()
    local documented = d ~= nil and #d.triggers_order > 0 and #d.effects_order > 0
    local c, message = catalog.read(script_where, stellar.read)
    if c == nil then
        if waited < WAIT_FOR_LOAD then
            return false
        end
        stellar.log("script: cannot read the catalog: " .. tostring(message))
        return true
    end
    if (c.lexer.stale or not documented) and waited < WAIT_FOR_LOAD then
        return false
    end
    local vtables = 0
    for _ in pairs(c.by_vtable) do
        vtables = vtables + 1
    end
    stellar.log(string.format("script: %d tokens (lookup %d%s, %d dynamic from id %d), %d triggers, %d effects, %d distinct object vtables",
        c.token_count, c.lexer.lookup, c.lexer.stale and " (stale)" or "", c.lexer.dynamic, c.lexer.base + 1,
        #c.trigger_list, #c.effect_list, vtables))
    if documented then
        for _, kind in ipairs({ "triggers", "effects" }) do
            local undocumented, unregistered = {}, {}
            for name in pairs(c[kind]) do
                if not d[kind][name] then
                    undocumented[#undocumented + 1] = name
                end
            end
            for name in pairs(d[kind]) do
                if not c[kind][name] then
                    unregistered[#unregistered + 1] = name
                end
            end
            table.sort(undocumented)
            table.sort(unregistered)
            stellar.log(string.format("script: %s: %d registered, %d documented; %d not documented (%s), %d documented but not registered (%s)",
                kind, #c[kind:sub(1, -2) .. "_list"], #d[kind .. "_order"],
                #undocumented, table.concat(undocumented, " ", 1, math.min(#undocumented, 12)),
                #unregistered, table.concat(unregistered, " ", 1, math.min(#unregistered, 12))))
        end
        local links = 0
        for _, name in ipairs(d.scopes_order) do
            if c.token_ids[name] then
                links = links + 1
            end
        end
        stellar.log(string.format("script: %d scope links documented, %d of them are tokens", #d.scopes_order, links))
    else
        stellar.log("script: the game's documentation is not there")
    end
    local ok, message = catalog.write_tsv(c, catalog_path, documented and d or nil, stellar.module_base)
    stellar.log(ok and ("script: catalog written to " .. catalog_path) or ("script: cannot write the catalog: " .. tostring(message)))

    -- the script the game has compiled: every trigger and effect object, named by its vtable
    local t2 = util.now()
    local census, census_message = catalog.census(c, script_where, stellar.read,
        { ["(scripted trigger)"] = true, ["(scripted effect)"] = true })
    if census == nil then
        stellar.log("script: census failed: " .. tostring(census_message))
        return true
    end
    -- for dev\run.lua (stellar.dev)
    local state = require("stellar.dev").state
    state.catalog, state.census, state.docs = c, census, documented and d or nil
    for _, kind in ipairs({ "triggers", "effects" }) do
        local s = census[kind]
        local names, unknown = {}, {}
        for name, n in pairs(s.by_name) do
            names[#names + 1] = { name, n }
        end
        for vtable, n in pairs(s.unknown) do
            unknown[#unknown + 1] = { hex(vtable - stellar.module_base), n }
        end
        table.sort(names, function(a, b) return a[2] > b[2] end)
        table.sort(unknown, function(a, b) return a[2] > b[2] end)
        local top, other = {}, {}
        for i = 1, math.min(#names, 15) do
            top[i] = names[i][1] .. " " .. names[i][2]
        end
        for i = 1, math.min(#unknown, 8) do
            other[i] = unknown[i][1] .. " " .. unknown[i][2]
        end
        stellar.log(string.format("script: compiled %s: %d objects, %d named (%.1f%%), %d keywords used; most used: %s; unnamed vtables (rva count): %s",
            kind, s.total, s.identified, s.total > 0 and 100 * s.identified / s.total or 0, #names,
            table.concat(top, ", "), table.concat(other, ", ")))
    end
    stellar.log(string.format("script: census in %.2fs", util.now() - t2))

    -- shadow: the scripted triggers and effects read from the files in Lua, next to what the game
    -- compiled from them; the files are the game's with the mods the launcher enabled
    local shadow = require("stellar.script.shadow")
    local fs, mods, mods_message = require("stellar.script.source").game_filesystem(util.dirname(stellar.module_path))
    local names = {}
    for _, mod in ipairs(mods) do
        names[#names + 1] = mod.name or mod.descriptor
    end
    stellar.log(string.format("script: %d mods enabled%s%s", #mods, #names > 0 and ": " .. table.concat(names, ", ") or "",
        mods_message and (" (" .. mods_message .. ")") or ""))
    for _, s in ipairs({
        { what = "scripted triggers", run = shadow.scripted_triggers, calls = census.triggers.objects["(scripted trigger)"] },
        { what = "scripted effects", run = shadow.scripted_effects, calls = census.effects.objects["(scripted effect)"] },
    }) do
        local t3 = util.now()
        local done, result = pcall(s.run, { catalog = c, read = stellar.read, game_dir = fs, calls = s.calls or {} })
        if not done then
            stellar.log("script: shadow of " .. s.what .. " failed: " .. tostring(result))
        else
            stellar.log(string.format("script: shadow of %s: %d definitions (%d parse errors), %d compared, %d identical, %d without a call without arguments (%d calls with arguments); %d nodes match (%d with a ? on another link of the chain), %d mismatches; in %.2fs; native location format: %s",
                s.what, result.definitions, #result.parse_errors, result.compared, result.identical, result.not_instantiated,
                result.calls_with_args, result.matched, result.nullable_differences, result.mismatches, util.now() - t3,
                tostring(result.sample_location)))
            local skipped = {}
            for k, n in pairs(result.skipped) do
                skipped[#skipped + 1] = { k, n }
            end
            table.sort(skipped, function(a, b) return a[2] > b[2] end)
            for i = 1, math.min(#skipped, 25) do
                skipped[i] = skipped[i][1] .. " " .. skipped[i][2]
            end
            stellar.log("script: " .. s.what .. ", statements that made no node (members of their parent): "
                .. table.concat(skipped, ", ", 1, math.min(#skipped, 25)))
            for _, example in ipairs(result.examples) do
                stellar.log("script:   " .. example)
            end
        end
    end
    return true
end

-- last: from here on the game's main thread calls into Lua
local ok, err = pcall(game.start, image)
if not ok then
    stellar.log("game.start failed: " .. tostring(err))
end
image:close()

-- the heartbeat reaches Lua: log the first one; read the catalog when the game has loaded; run
-- dev\run.lua when there is one (stellar.dev, development only)
local dev = require("stellar.dev")
dev.state.where = script_where
local heartbeats, catalog_done, schedule_logged = 0, script_where == nil, false
stellar.heartbeat = function()
    heartbeats = heartbeats + 1
    if heartbeats == 1 then
        stellar.log("heartbeat from Lua" .. (dev.enabled and ", dev enabled" or ""))
    end
    loading.poll(stellar.read)
    -- the lexer hook's counts, every 10 seconds while they change
    if heartbeats % 10 == 0 then
        loader.report()
    end
    -- once loaded: the databases' dependencies (from the code) and what initializing them in
    -- parallel would take, from this load's times
    if databases_where and not schedule_logged and loading.loaded() then
        schedule_logged = true
        local unknown = databases_unknown
        local seconds, count, sum = loading.database_seconds(), 0, 0
        for _, e in ipairs(databases_where.entries) do
            count = count + #e.depends
            sum = sum + (seconds[e.name] or 0)
        end
        local schedules, critical = {}, 0
        for _, workers in ipairs({ 1, 2, 4, 8, 16 }) do
            local makespan
            makespan, critical = databases.schedule(databases_where, seconds, workers)
            schedules[#schedules + 1] = string.format("%d: %.1fs", workers, makespan)
        end
        stellar.log(string.format("databases: %d dependencies from CanInitialize (%d globals read that are no database: %s); %.1fs one after another, the longest chain %.1fs; with N workers %s",
            count, #unknown, table.concat(unknown, ", ", 1, math.min(#unknown, 8)), sum, critical, table.concat(schedules, ", ")))
    end
    -- the catalog once the load is done: reading it holds the Lua lock, which the lexer hook needs
    if not catalog_done and (loading.loaded() or heartbeats >= WAIT_FOR_LOAD) then
        local done, result = pcall(read_catalog, heartbeats)
        if not done then
            stellar.log("script catalog failed: " .. tostring(result))
        end
        catalog_done = not done or result
        if catalog_done then
            loader.report(true)
        end
    end
    if catalog_done then
        dev.poll()
    end
end
