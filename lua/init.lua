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

-- the static lexer's token table, taken over (src/dll/database_workers.cpp): its id -> name lookup
-- is kept up to date in place as tokens are added, and CStaticLexer::RebuildLookup (which emptied
-- and refilled it under every reader) never runs again
local cstring_assign  -- the CString's assign (loader.token_table), for stellar.flags
do
    local t, message = loader.token_table(require("stellar.resolve").functions(image), lexer_where, stellar.read)
    cstring_assign = t and t.assign
    local ok
    if t then
        ok, message = stellar.token_table(t.add, t.find, t.rebuild, t.access, t.reserve, t.assign)
    end
    local s = ok and stellar.token_table_stats() or {}
    stellar.log(ok and string.format("tokens: the token table is taken over: %d names of %d, room for %d; RebuildLookup is replaced",
        s.size or 0, s.desired or 0, s.capacity or 0) or ("tokens: the token table is not taken over: " .. tostring(message)))
end

-- the modifier definitions found by token through an index (stellar.modifier_index): the game's
-- linear scans of them (about 10^9 compares at load) replaced
-- (modifiers.txt next to the DLL: "off" to leave the game's scans)
local modifier_where  -- where the definitions are (modifier_index.locate)
if setting("modifiers.txt", "index") == "off" then
    stellar.log("modifiers: no index (modifiers.txt)")
else
    local modifier_index = require("stellar.modifier_index")
    local where, message = modifier_index.locate(require("stellar.resolve").functions(image), stellar.read)
    modifier_where = where
    local results = where and modifier_index.install(where)
    stellar.log(results and string.format("modifiers: the definitions' index: GetTypeFromToken %s, TryAddDynamicModifier %s, TryReadMember %s",
        tostring(results.get_type), tostring(results.add), tostring(results.read))
        or ("modifiers: no index: " .. tostring(message)))
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
    elseif setting("loading_bar.txt", "lua") == "game" then
        stellar.log("load: the bar is the game's (loading_bar.txt)")
    else
        -- the bar: Lua's, from the last load's timeline, at once (the interface phase may begin
        -- while Lua is still starting); the milestones after the databases are scheduled below,
        -- once they are hooked (loading.bar_schedule)
        local report, why = loading.bar(util.dirname(stellar.dll_path) .. "\\cache\\load_timeline-" .. image:md5() .. ".tsv")
        stellar.log("load: the bar " .. (report and ("is Lua's: " .. report) or ("is the game's: " .. tostring(why))))
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
        if e.post_read then
            e.post_mark = { address = databases.follow(stellar.read, e.post_read), kind = "post_read", name = e.name }
            marks[#marks + 1] = e.post_mark
        end
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
local post_reads  -- the PostReadInitInstance Lua runs (databases.skip_post_reads)
local dependencies_path = util.dirname(stellar.dll_path) .. "\\cache\\database_dependencies-" .. image:md5() .. ".tsv"
local conflicts_path = util.dirname(stellar.dll_path) .. "\\cache\\database_conflicts-" .. image:md5() .. ".tsv"
local boot_order_path = util.dirname(stellar.dll_path) .. "\\cache\\database_boot_order-" .. image:md5() .. ".tsv"
local inflight_path = util.dirname(stellar.dll_path) .. "\\cache\\database_inflight-" .. image:md5() .. ".tsv"
local order_path = util.dirname(stellar.dll_path) .. "\\cache\\database_order-" .. image:md5() .. ".tsv"
-- the databases that call what numbers things as it makes them (databases.ORDERED); the md5 now,
-- the image is closed by the time the databases run
local image_md5 = image:md5()
local function writers_path(o)
    return util.dirname(stellar.dll_path) .. "\\cache\\database_" .. o.file .. "-" .. image_md5 .. ".tsv"
end
local after_path = util.dirname(stellar.dll_path) .. "\\cache\\database_after-" .. image:md5() .. ".tsv"
local game_order  -- the game's order of the databases (databases.load_order), for run_parallel
local serialized = {}  -- name -> slot (databases.serialize)
-- the script flags' names in id order (stellar.flags): kept by a load in the game's order, given
-- their ids before the databases run in parallel (then no database waits for another for them).
-- Located before the lock's hook rewrites the start of CreateFlagIndex.
local flags = require("stellar.flags")
local flags_where, flags_message = flags.locate(found, stellar.read)
local flags_path = util.dirname(stellar.dll_path) .. "\\cache\\flag_names-" .. image_md5 .. ".tsv"
local flag_names  -- the names to register (flags.load), in parallel
if not flags_where then
    stellar.log("flags: " .. tostring(flags_message))
end
if databases_where and database_mode == "parallel" then
    -- a load that died in the databases without a handler seeing it: what ran then conflicts
    local recovered, names = databases.recover_inflight(inflight_path, conflicts_path)
    if recovered then
        stellar.log(string.format("databases: the last load died while %d databases ran (%s): %d conflicts added",
            #names, table.concat(names, ", "), recovered))
    end
    local learned = databases.load(databases_where, dependencies_path)
    local conflicts = databases.load_conflicts(databases_where, conflicts_path)
    stellar.log(learned and string.format("databases: %d dependencies learned in a trace added; %d conflicts learned in failed loads",
        learned, conflicts or 0)
        or "databases: no dependencies learned yet (run once with databases.txt \"trace\"): one at a time")
    if not learned then
        database_mode = "lua"
    else
        -- what they share, under one lock
        local failed
        serialized, failed = databases.serialize(found, stellar.read)
        local count = 0
        for _ in pairs(serialized) do
            count = count + 1
        end
        stellar.log(string.format("databases: %d of %d shared writers serialized%s", count, #databases.SHARED,
            #failed > 0 and ("; not: " .. table.concat(failed, "; ")) or ""))
        local order = databases.load_order(order_path)
        game_order = order
        -- what failed loads learned the databases wait for
        local waits = databases.load_after(databases_where, after_path)
        stellar.log(string.format("databases: %d waits learned in failed loads", waits or 0))
        -- the flags' ids given before the databases run: their makers need no order
        flag_names = flags_where and cstring_assign and flags.load(flags_path)
        if flag_names then
            stellar.log(string.format("flags: %d names to give their ids before the databases (%s)", #flag_names, flags_path))
        end
        -- the databases that make what is numbered as it is made, in the game's order
        for _, o in ipairs(databases.ORDERED) do
            local writers = databases.load_names(writers_path(o))
            if flag_names and o.file == "flag_writers" then
                stellar.log("databases: the databases that make script flag ids need no order: the ids are given before")
            elseif writers and order then
                stellar.log(string.format("databases: %d databases make %s: %d links keep them in the game's order",
                    #writers, o.what, databases.chain(databases_where, writers, order)))
            else
                stellar.log("databases: the databases that make " .. o.what .. " are not known yet (" .. writers_path(o)
                    .. ") or the game's order (" .. order_path .. "): they may be numbered otherwise this load")
            end
        end
    end
end
if databases_where and (database_mode == "lua" or database_mode == "parallel" or database_mode == "trace") then
    stellar.setup_databases = function(a, done, progress)
        loading.milestone("NNullObjAndDatabaseInitUtil::SetupDatabases")
        local t0 = util.now()
        local n, stopped, report
        if database_mode == "parallel" then
            -- the workers' times are the system clock's
            -- room in the modifier definitions: added to while other databases read them, they
            -- never move
            if found[databases.MODIFIER_RESERVE] and modifier_where then
                stellar.call(found[databases.MODIFIER_RESERVE], modifier_where.data - 8, databases.MODIFIER_ROOM)
            end
            -- the flags' ids, in the game's order, before any database makes one
            if flag_names then
                local registered, mismatch = flags.register(flags_where, cstring_assign, flag_names)
                stellar.log(mismatch and string.format("flags: %d names registered, but id %d is not the one kept: the ids are not the game's",
                    registered, mismatch) or string.format("flags: %d names given their ids, as the game gives them", registered))
            end
            local t0 = util.system_time()
            local timeline, failure
            stellar.serialize_active(true)
            n, stopped, report, timeline, failure = databases.run_parallel(databases_where, progress, stellar.read,
                tonumber(database_workers) or 4, conflicts_path, inflight_path, after_path, game_order,
                (os.getenv("USERPROFILE") or ".") .. "\\Documents\\Paradox Interactive\\Stellaris\\logs\\error.log",
                databases.load_durations(boot_order_path))
            stellar.serialize_active(false)
            -- flags the kept names do not have were numbered in this load's order
            if flag_names then
                local now = #flags.names(flags_where)
                if now > #flag_names then
                    stellar.log(string.format("flags: %d made while the databases ran that the kept names do not have: their ids may not be the game's (a \"lua\" load keeps the names again)",
                        now - #flag_names))
                end
            end
            -- what the lock cost: per function, the calls under it and how long they waited for it
            local costs = {}
            for _, name in ipairs(databases.SHARED) do
                if serialized[name] then
                    local calls, _, contended, waited = stellar.serialized(serialized[name])
                    if calls > 0 then
                        costs[#costs + 1] = string.format("%s %d calls, %d waited %.2fs", name:match("[^:]*::[^:]*$") or name,
                            calls, contended or 0, waited or 0)
                    end
                end
            end
            stellar.log("databases: the shared lock: " .. table.concat(costs, "; "))
            -- the databases that made what is numbered (in Create or Init), with those known before
            for _, o in ipairs(databases.ORDERED) do
                local slot = serialized[o.name]
                if slot then
                    local _, ids = stellar.serialized(slot)
                    local names, seen = databases.load_names(writers_path(o)) or {}, {}
                    for _, name in ipairs(names) do
                        seen[name] = true
                    end
                    local added = 0
                    for _, id in ipairs(ids) do
                        local e = databases_where.entries[id]
                        if e and not seen[e.name] then
                            seen[e.name] = true
                            names[#names + 1] = e.name
                            added = added + 1
                        end
                    end
                    databases.save_names(writers_path(o), names)
                    stellar.log(string.format("databases: %d databases made %s (%d new)", #ids, o.what, added))
                end
            end
            if failure then
                -- the conflict is learned (and said, by run_parallel); this load cannot go on (a
                -- database is half made)
                stellar.log("databases: conflict learned (" .. conflicts_path .. "): the game ends, the next load keeps those apart")
                stellar.exit_process(3)
            end
            for _, t in ipairs(timeline or {}) do
                stellar.log(string.format("databases:   %s on thread %d: +%.3fs, %.3fs", t.name, t.thread, t.start - t0,
                    t.seconds))
            end
            stellar.log("databases: the boot order that worked: " .. tostring(databases.save_boot_order(timeline or {}, t0,
                boot_order_path)))
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
        -- their PostReadInitInstance in the order they were initialized, as in the game's loop: the
        -- game's own pass would call them in the table's order (every database is ready by then).
        -- In parallel, the order of the game's loop, kept by a load that ran it in Lua
        local order
        if database_mode == "parallel" then
            order = databases.load_order(order_path)
            if order == nil then
                stellar.log("databases: no game order kept yet (" .. order_path .. ", run once with databases.txt \"lua\"): "
                    .. "the PostReads run in the order the databases were done, the modifier types may be numbered otherwise")
            end
        elseif n == #databases_where.entries then
            databases.save_order(databases_where, order_path)
        end
        post_reads = databases.skip_post_reads(databases_where, order)
    end
    -- InitDefinitionIcons comes right after the game's PostReadInitInstance loop (which skips
    -- those): they run here, in their order
    -- CModifier::LogDefinitions (writes modifiers.log: 4.3s on the game's thread, nothing waits for
    -- it) runs on a thread of its own once the definitions are final (after the PostReads), while
    -- the game goes on; InitGame's own call returns at once, and the first call after it waits for
    -- it (background.txt "off": in its place)
    local log_definitions, log_definitions_call
    for _, m in ipairs(marks) do
        if m.kind == "milestone" and m.name == "CModifier::LogDefinitions" and m.trampoline then
            log_definitions = m
        end
    end
    local background = setting("background.txt", "on") ~= "off"
    stellar.before_definition_icons = function()
        loading.milestone("CModifier::InitDefinitionIcons")
        if post_reads then
            databases.run_post_reads(post_reads)
            post_reads = nil
        end
        if background and log_definitions and found["CEconomicCategory::LogUnusedGeneratedAddModifiers"] then
            stellar.set_entry_skip(log_definitions.id, true)
            log_definitions_call = stellar.run_async(log_definitions.trampoline)
        end
    end
    stellar.before_log_unused = function()
        if log_definitions_call then
            local waited = util.system_time()
            local code, what = stellar.join_async(log_definitions_call)
            log_definitions_call = nil
            stellar.set_entry_skip(log_definitions.id, false)
            stellar.log(string.format("load: CModifier::LogDefinitions ran beside the load: %.2fs, waited for %.2fs%s",
                (what.finish or 0) - (what.start or 0), util.system_time() - waited,
                code ~= 0 and string.format(" (failed: exception 0x%08x)", code) or ""))
        end
    end
    if background and log_definitions and found["CEconomicCategory::LogUnusedGeneratedAddModifiers"] then
        local ok, why = stellar.hook_before(found["CEconomicCategory::LogUnusedGeneratedAddModifiers"], "before_log_unused")
        if not ok then
            background = false
            stellar.log("load: LogDefinitions stays in its place: " .. tostring(why))
        end
    end
    local icons_hooked, icons_message = nil, "CModifier::InitDefinitionIcons not found"
    if found["CModifier::InitDefinitionIcons"] then
        icons_hooked, icons_message = stellar.hook_before(found["CModifier::InitDefinitionIcons"], "before_definition_icons")
    end
    local hooked, message = stellar.hook_setup_databases(databases_where.setup)
    stellar.log("databases: the loop runs in Lua" .. (hooked and "" or (": not hooked: " .. tostring(message)))
        .. (icons_hooked and "" or ("; the PostReadInitInstance order is the game's pass: " .. tostring(icons_message))))
else
    stellar.log("databases: the loop is the game's (" .. database_mode .. ")")
end
-- the bar's milestones after the databases, each crossed in the time it took last load
local scheduled = loading.bar_schedule()
if scheduled > 0 then
    stellar.log(string.format("load: the bar: %d milestones scheduled", scheduled))
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
-- what the modifier nodes cost, month by month (modifier_stats.txt "on": stellar.modifier_capture)
local modifier_stats = false
if setting("modifier_stats.txt", "off") == "on" then
    local capture = require("stellar.modifier_capture")
    local capture_where, why = capture.locate(found, stellar.read)
    local ok
    if capture_where then
        ok, why = capture.stats_hook(capture_where)
    end
    modifier_stats = ok and capture or false
    stellar.log("modifiers: the nodes' costs " .. (ok and "are counted, logged each month" or ("are not counted: " .. tostring(why))))
end
game.after_day(function(gamestate, db)
    local _, _, day = game.date(gamestate)
    if day == 1 then
        stellar.log(string.format("new month %s: its first tick took %.1f ms, %d ticks since the last one",
            game.date_string(gamestate), (util.now() - started) * 1000, month_ticks))
        month_ticks = 0
        if modifier_stats then
            stellar.log("modifiers: the last month: " .. modifier_stats.stats_report(stellar.modifier_stats(true),
                stellar.module_base))
        end
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
dev.state.found = found
-- the modifier nodes, captured on demand (stellar.modifier_capture; a game loaded)
do
    local capture_where, why = require("stellar.modifier_capture").locate(found, stellar.read)
    dev.state.modifier_where = capture_where
    stellar.log("modifiers: the node manager " .. (capture_where and string.format("at %s", hex(capture_where.instance))
        or ("not found: " .. tostring(why))))
end
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
        -- a load in the game's order keeps the flags' names in id order (for parallel loads)
        if flags_where and database_mode ~= "parallel" then
            local count = flags.save(flags_where, flags_path)
            stellar.log(string.format("flags: %s names kept in id order (%s)", tostring(count), flags_path))
        end
        local lookups, hits, indexed = stellar.modifier_index_stats()
        lookups, hits, indexed = lookups or 0, hits or 0, indexed or 0
        stellar.log(string.format("modifiers: %d lookups through the index (%d found), %d definitions indexed",
            lookups, hits, indexed))
        local t = stellar.token_table_stats()
        stellar.log(string.format("tokens: %d names added in place in %d updates, the lookup moved %d times; RebuildLookup called %d times (replaced); %d of %d names, room for %d",
            t.names or 0, t.updates or 0, t.moves or 0, t.rebuild_calls or 0, t.size or 0, t.desired or 0, t.capacity or 0))
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
