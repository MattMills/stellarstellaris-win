-- loading.lua : the load screen's stages and progress, in the log: what "loaded" means for the
-- game.
--
-- The startup load has phases, each a part of the progress bar (4.5.2: interface 5-30%, graphics
-- 30-80%, game databases 80-100%): CGameApplication::LoadingScreenCallback(current, total, start,
-- span) is a step of one. Loading a save or a new game pushes stages instead:
-- SPushLoadScreenState(start, end, file, line) begins one, the part [start, end] (0 to 100) of the
-- stage around it, named by the C++ file and line that pushed it; its destructor ends it.
-- RenderLoadScreen draws the load screen at a progress (0 to 100). The load is done when the load
-- screen is gone. The hooks
-- (src/dll/loading_hook.cpp) record these events; loading.poll() logs them from the heartbeat, with
-- the time each happened. The stages are a stack in the load screen's progress context (a global the
-- stage constructor reads); the load screen is gone when that global is null again.
--
--   local loading = require("stellar.loading")
--   local where = assert(loading.locate(image, stellar.read))
--   assert(loading.hook(where, stellar.read))
--   loading.poll(stellar.read)       -- every heartbeat

local ffi = require("ffi")
local stellar = require("stellar")
local resolve = require("stellar.resolve")
local code = require("stellar.code")
local util = require("stellar.util")

local loading = {}

-- loading.locate(image, read) -> where | nil, message: push, pop (SPushLoadScreenState's
-- constructor and destructor), render (RenderLoadScreen) and context (the global that holds the
-- progress context: the first `mov r64, [rip+x]` of the constructor)
function loading.locate(image, read)
    local found = resolve.functions(image)
    local push = found["SPushLoadScreenState::SPushLoadScreenState"]
    local pop = found["SPushLoadScreenState::~SPushLoadScreenState"]
    local render = found["RenderLoadScreen"]
    local step = found["CGameApplication::LoadingScreenCallback"]
    if not (push and pop and render and step) then
        return nil, string.format("not found:%s%s%s%s", push and "" or " SPushLoadScreenState",
            pop and "" or " ~SPushLoadScreenState", render and "" or " RenderLoadScreen",
            step and "" or " CGameApplication::LoadingScreenCallback")
    end
    local patterns = code.bundle(read, image)
    local load = patterns:register({ name = "the progress context in SPushLoadScreenState", in_function = push,
        signature = "[01001.00] 8b [00...101] ?? ?? ?? ??", count = false })
    local report = patterns:run()
    if not report.ok then
        return nil, "sigmatch: " .. tostring(report.error)
    end
    local first
    for _, at in ipairs(load.matches or {}) do
        if first == nil or at < first then
            first = at
        end
    end
    if first == nil then
        return nil, "no global read in SPushLoadScreenState"
    end
    return { push = push, pop = pop, render = render, step = step, context = code.relative(read, first + 3, first + 7) }
end

-- CLoadScreenProgressContext (4.5.2 PDB): _Stack, a CPdxArray of SState (24 bytes:
-- _nTransformedStart, _nTransformedSpan, _pCallFile, _nCallLineNumber)
local STACK_DATA, STACK_COUNT, STATE_SIZE = 24, 36, 24

local function pointer(read, address)
    local bytes = read(address, 8)
    return bytes and tonumber(ffi.cast("const uint64_t *", bytes)[0]) or nil
end

local function int32(read, address)
    local bytes = read(address, 4)
    return bytes and ffi.cast("const int32_t *", bytes)[0] or nil
end

local function c_string(read, address)
    local bytes = address and address ~= 0 and read(address, 260)
    return bytes and bytes:match("^[^%z]*") or "?"
end

-- the C++ file of a stage: its last two path components
local function short(file)
    return (file:gsub("\\", "/"):match("([^/]+/[^/]+)$")) or file
end

local function clock(t)
    return os.date("%H:%M:%S", math.floor(t)) .. string.format(".%03d", math.floor((t % 1) * 1000))
end

-- The phases of the startup load: CGameApplication::LoadingScreenCallback(current, total, start,
-- span) is called by a function per phase with its part of the bar (4.5.2: locGuiLoadingScreenCallback,
-- locGfxLoadingScreenCallback and a lambda of CGameApplication::InitGame)
local PHASE_NAMES = {
    ["5+25"] = "interface (GUI)",
    ["30+50"] = "graphics (GFX)",
    ["80+20"] = "game databases (CGameApplication::InitGame)",
}

local where_hooked
local phases, phase_order = {}, {}
-- Marks: functions whose entry is an event (src/dll/loading_hook.cpp, stellar.hook_entries), by id
--   create     a database's CreateInstance: it is initialized until the next progress step
--   post_read  a database's PostReadInitInstance (after 100%): until the next mark
--   milestone  a step of CGameApplication::InitGame
local marks = {}
local database, databases_done = nil, {}       -- the database being initialized, those done
local post_read, post_reads = nil, {}          -- the PostReadInitInstance running, those done
local milestone                                -- the last milestone

-- The steps of CGameApplication::InitGame that are milestones (stellar.functions), in its order
-- (NNullObjAndDatabaseInitUtil::SetupDatabases and CModifier::InitDefinitionIcons have hooks of
-- their own, stellar.hook_setup_databases and stellar.hook_before; loading.milestone records them)
loading.MILESTONES = {
    "CGlobalScriptedVariablesDatabase::InitializeWithDirectory", "CModifier::InitDefinitions",
    "CGameRules::InitInstance",
    "CAchievementsManager::InitFromFile", "CApplication::CalculateGameFilesChecksum", "CStaticModifierDatabase::Init",
    "CTriggerDatabase::PostInit", "CTriggerDatabase::PostValidate", "CEffectDatabase::PostInit",
    "CEffectDatabase::PostValidate", "CEventManager::InitEventConnectivityMaps", "CModifier::LogDefinitions",
    "CGameApplication::PrintScriptingDocumentation", "CPortraitSpriteType::InitializeScriptedLogic",
    "CFrontEndIdler::CFrontEndIdler", "DestroyLoadScreen",
}

-- loading.hook_marks(list) -> hooked, failures: hooks each { address, kind, name } of list (an
-- address hooked once: the first mark for it). A mark hooked gets its id and trampoline (which
-- runs the function past the hook); a mark for an address already marked gets shared = true.
function loading.hook_marks(list)
    local addresses, kept, failures, seen = {}, {}, {}, {}
    for _, m in ipairs(list) do
        if m.address and not seen[m.address] then
            seen[m.address] = true
            kept[#kept + 1] = m
            addresses[#addresses + 1] = m.address
        elseif m.address then
            m.shared = true
        end
    end
    local results, base = stellar.hook_entries(addresses)
    local hooked = 0
    for i, r in ipairs(results) do
        local m = kept[i]
        marks[base + i] = m
        if type(r) == "number" then
            m.id, m.trampoline = base + i, r
            hooked = hooked + 1
        else
            m.error = tostring(r)
            failures[#failures + 1] = m.name .. " (" .. m.kind .. "): " .. m.error
        end
    end
    return hooked, failures
end

-- The read (stellar.hook_reads): every file in the order it was read, and the folder lists
local files, lists, prelists = {}, {}, 0
local opened, opened_order = {}, {}     -- files whose lexer was made (path -> count), in order

-- loading.hook_reads(found) -> hooked, failures: the read hooks, from the functions found
function loading.hook_reads(found)
    local names = { "CLexer::CLexer", "CMemoryFile::~CMemoryFile", "VFSGetEnumeratedFiles", "VFSPreEnumerateFiles" }
    local results = stellar.hook_reads(found[names[1]] or 0, found[names[2]] or 0, found[names[3]] or 0,
        found[names[4]] or 0)
    local hooked, failures = 0, {}
    for i, name in ipairs(names) do
        if results[i] == true then
            hooked = hooked + 1
        else
            failures[#failures + 1] = name .. ": " .. tostring(results[i])
        end
    end
    return hooked, failures
end

-- the path of the TSV of the files read (next to the log)
local function files_path()
    return (os.getenv("USERPROFILE") or ".") .. "\\Documents\\Paradox Interactive\\Stellaris\\logs\\stellarstellaris-files.tsv"
end

-- writes every file read: the order, when, the thread, the database, the path, its bytes and
-- tokens, the milliseconds to read and to parse it
local function write_files()
    local f = io.open(files_path(), "w")
    if f == nil then
        return nil
    end
    f:write("order\ttime\tthread\tdatabase\tpath\tbytes\ttokens\tread_ms\tparse_ms\n")
    for i, r in ipairs(files) do
        f:write(string.format("%d\t%s\t%d\t%s\t%s\t%d\t%d\t%.3f\t%.3f\n", i, clock(r.time), r.thread, r.database,
            r.path, r.bytes, r.tokens, r.read * 1000, r.parse * 1000))
    end
    f:close()
    -- and the folder lists: when, the thread, the database, the folder (|filter|filter), the files
    -- in it, the milliseconds it took
    local lists_path = files_path():gsub("files%.tsv$", "folders.tsv")
    f = io.open(lists_path, "w")
    if f then
        f:write("order\ttime\tthread\tdatabase\tfolder\tfiles\tms\n")
        for i, l in ipairs(lists) do
            f:write(string.format("%d\t%s\t%d\t%s\t%s\t%d\t%.3f\n", i, clock(l.time), l.thread, l.database, l.folder,
                l.count, l.seconds * 1000))
        end
        f:close()
    end
    return files_path()
end

-- loading.milestone(name): records entering a milestone that has no mark (a function with a hook
-- of its own), from the thread that calls it
local virtual_marks = {}
function loading.milestone(name)
    local id = virtual_marks[name]
    if id == nil then
        id = 1000000 + #marks + 1
        for _ in pairs(virtual_marks) do
            id = id + 1
        end
        virtual_marks[name] = id
        marks[id] = { kind = "milestone", name = name }
    end
    stellar.mark(id)
end

-- the post read running on the thread of e ends at e
local function end_post_read(e)
    if post_read and post_read.thread == e.thread then
        post_read.seconds = e.time - post_read.time
        post_reads[#post_reads + 1] = post_read
        post_read = nil
    end
end
local stack = {}            -- the stages, as the events tell them
local deep = {}             -- stages below MAX_DEPTH: count by file:line
local MAX_DEPTH = 3         -- stages deeper than this are counted, not logged
local context_seen, closed, last_progress, started = false, false, nil, nil

local function log(e, text)
    stellar.log(string.format("load: [%s] %s", clock(e.time), text))
end

-- loading.hook(where, read) -> true | nil, message: hooks the load screen and logs the stages open
-- at that moment (the game's own stack)
function loading.hook(where, read)
    local ok, message = stellar.hook_loading(where.push, where.pop, where.render, where.step)
    if not ok then
        return nil, message
    end
    where_hooked = where
    started = util.now()
    local context = pointer(read, where.context)
    if context and context ~= 0 then
        context_seen = true
        local data, count = pointer(read, context + STACK_DATA), int32(read, context + STACK_COUNT) or 0
        stellar.log(string.format("load: hooked with the load screen up, %d stages open:", count))
        for i = 0, math.min(count, 32) - 1 do
            local s = data + i * STATE_SIZE
            local at, span = int32(read, s), int32(read, s + 4)
            local file, line = c_string(read, pointer(read, s + 8)), int32(read, s + 16)
            stack[#stack + 1] = { at = at, span = span, file = short(file), line = line, time = started, before = true }
            stellar.log(string.format("load:   %s%3d%% +%d%% %s:%d", string.rep("  ", i), at, span, short(file), line))
        end
    else
        stellar.log("load: hooked before the load screen is up")
    end
    return true
end

-- loading.database_seconds() -> { [database name] = seconds to create and initialize it }, from
-- this load
function loading.database_seconds()
    local seconds = {}
    for _, d in ipairs(databases_done) do
        seconds[d.name] = d.seconds
    end
    return seconds
end

-- loading.loaded() -> whether the load is done: the load screen was up and is gone (always true
-- when the load screen is not hooked)
function loading.loaded()
    return where_hooked == nil or closed
end

-- loading.poll(read): logs the events since the last poll, and the load screen going away
function loading.poll(read)
    if where_hooked == nil then
        return
    end
    for _, e in ipairs(stellar.loading_events()) do
        if e.kind == "push" then
            local parent = stack[#stack]
            local base, span = parent and parent.at or 0, parent and parent.span or 100
            local s = { at = base + e.a * span / 100, span = (e.b - e.a) * span / 100, file = short(e.text),
                line = e.line, time = e.time }
            if e.flag then
                stack[#stack + 1] = s
            end
            if #stack <= MAX_DEPTH then
                log(e, string.format("%s%5.1f%% +%.1f%% begins %s:%d (%d..%d of its parent; thread %d)%s",
                    string.rep("  ", #stack - 1), s.at, s.span, s.file, s.line, e.a, e.b, e.thread,
                    e.flag and "" or ", not pushed"))
            else
                local key = s.file .. ":" .. s.line
                deep[key] = (deep[key] or 0) + 1
            end
        elseif e.kind == "pop" and e.flag then
            local s = table.remove(stack)
            if s == nil then
                log(e, "a stage that began before the hook ends")
            elseif #stack < MAX_DEPTH then
                log(e, string.format("%s%5.1f%% +%.1f%% ends %s:%d after %.2fs", string.rep("  ", #stack), s.at, s.span,
                    s.file, s.line, e.time - s.time))
            end
        elseif e.kind == "render" then
            if e.a ~= last_progress then
                log(e, string.format("progress %d%%%s", e.a, e.text ~= "" and (" '" .. e.text .. "'") or ""))
                last_progress = e.a
            end
        elseif e.kind == "step" then
            local key = e.line .. "+" .. e.c
            local p = phases[key]
            if p == nil then
                p = { name = PHASE_NAMES[key] or ("phase " .. key), start = e.line, span = e.c, first = e.time,
                    steps = 0, threads = {} }
                phases[key] = p
                phase_order[#phase_order + 1] = p
                log(e, string.format("phase %s begins: %d%% to %d%% of the bar, step %d of %d (thread %d)", p.name,
                    p.start, p.start + p.span, e.a, e.b, e.thread))
            end
            p.steps, p.current, p.total, p.last = p.steps + 1, e.a, e.b, e.time
            p.threads[e.thread] = true
            -- a database's InitInstance is done: the step after its CreateInstance
            if database and database.thread == e.thread then
                local d = database
                d.seconds, d.texts, d.tokens, d.bytes = e.time - d.time, e.texts - d.texts, e.tokens - d.tokens,
                    e.bytes - d.bytes
                databases_done[#databases_done + 1] = d
                log(e, string.format("database %d/%d %s: %.3fs, %d texts (%.2f MB), %d tokens; %d files read in %.3fs, parsed in %.3fs; %d folder lists in %.3fs",
                    e.a, e.b, d.name, d.seconds, d.texts, d.bytes / 1e6, d.tokens, d.files, d.read, d.parse, d.lists,
                    d.list_seconds))
                database = nil
            end
        elseif e.kind == "file" then
            local d = database and database.thread == e.thread and database or nil
            files[#files + 1] = { time = e.time, thread = e.thread, database = d and d.name or "(outside the databases)",
                path = e.text, bytes = e.a, tokens = e.b, read = e.d1, parse = e.d2 }
            if d then
                d.files, d.read, d.parse = d.files + 1, d.read + e.d1, d.parse + e.d2
            end
        elseif e.kind == "list" then
            local d = database and database.thread == e.thread and database or nil
            lists[#lists + 1] = { time = e.time, thread = e.thread, folder = e.text, count = e.a, seconds = e.d1,
                database = d and d.name or "(outside the databases)" }
            if d then
                d.lists, d.list_seconds = d.lists + 1, d.list_seconds + e.d1
            end
        elseif e.kind == "prelist" then
            prelists = prelists + 1
        elseif e.kind == "open" then
            -- a file's lexer made: until its "file" (when it goes), it is open
            local path = e.text:match("^(.*)|") or e.text
            opened[path] = (opened[path] or 0) + 1
            opened_order[#opened_order + 1] = { path = path, lexer = e.text:match("|(.*)$"), thread = e.thread,
                database = database and database.thread == e.thread and database.name or "(outside the databases)" }
        elseif e.kind == "enter" then
            local m = marks[e.a] or { kind = "?", name = "#" .. e.a }
            end_post_read(e)
            if m.kind == "create" then
                database = { name = m.name, time = e.time, thread = e.thread, texts = e.texts, tokens = e.tokens,
                    bytes = e.bytes, files = 0, read = 0, parse = 0, lists = 0, list_seconds = 0 }
            elseif m.kind == "post_read" then
                post_read = { name = m.name, time = e.time, thread = e.thread }
            elseif m.kind == "milestone" then
                if milestone and milestone.name == m.name then
                    -- called again right away (one call per object): counted
                    milestone.calls = milestone.calls + 1
                else
                    if milestone and milestone.calls > 1 then
                        log(e, string.format("  (%s: %d calls)", milestone.name, milestone.calls))
                    end
                    local since = milestone and string.format(", %.3fs after %s", e.time - milestone.time, milestone.name) or ""
                    log(e, string.format("%s begins (thread %d%s; %d texts, %d tokens so far)", m.name, e.thread, since,
                        e.texts, e.tokens))
                    milestone = { name = m.name, time = e.time, calls = 1 }
                end
            end
        end
    end
    -- the progress context exists while the load screen is up
    local context = pointer(read, where_hooked.context)
    if context and context ~= 0 then
        context_seen, closed = true, false
    elseif context_seen and not closed then
        closed = true
        stellar.log(string.format("load: the load screen is gone (its progress context is null): loaded, %.1fs after the hook; last progress %s%%, %d stages open",
            util.now() - started, tostring(last_progress), #stack))
        for _, p in ipairs(phase_order) do
            local threads = 0
            for _ in pairs(p.threads) do
                threads = threads + 1
            end
            stellar.log(string.format("load:   phase %s (%d%% to %d%%): %d steps, the last %d of %d, from %s to %s (%.1fs), %d thread(s)",
                p.name, p.start, p.start + p.span, p.steps, p.current, p.total, clock(p.first), clock(p.last),
                p.last - p.first, threads))
        end
        if #databases_done > 0 then
            local by_time, seconds, texts, tokens, bytes = {}, 0, 0, 0, 0
            for i, d in ipairs(databases_done) do
                by_time[i] = d
                seconds, texts, tokens, bytes = seconds + d.seconds, texts + d.texts, tokens + d.tokens, bytes + d.bytes
            end
            table.sort(by_time, function(a, b) return a.seconds > b.seconds end)
            local top = {}
            for i = 1, math.min(#by_time, 15) do
                top[i] = string.format("%s %.2fs", by_time[i].name, by_time[i].seconds)
            end
            stellar.log(string.format("load:   %d databases initialized in %.1fs: %d texts (%.1f MB), %d tokens; the longest: %s",
                #databases_done, seconds, texts, bytes / 1e6, tokens, table.concat(top, ", ")))
        end
        if #files > 0 then
            -- the read: in the databases and outside them
            local sums = {}
            for _, r in ipairs(files) do
                local key = r.database == "(outside the databases)" and r.database or "(in the databases)"
                local s = sums[key] or { files = 0, bytes = 0, read = 0, parse = 0, threads = {} }
                sums[key] = s
                s.files, s.bytes, s.read, s.parse = s.files + 1, s.bytes + math.max(r.bytes, 0), s.read + r.read,
                    s.parse + r.parse
                s.threads[r.thread] = true
            end
            for key, s in pairs(sums) do
                local threads = 0
                for _ in pairs(s.threads) do
                    threads = threads + 1
                end
                stellar.log(string.format("load:   files %s: %d (%.1f MB) on %d thread(s), read in %.2fs, parsed in %.2fs",
                    key, s.files, s.bytes / 1e6, threads, s.read, s.parse))
            end
            local list_seconds = 0
            for _, l in ipairs(lists) do
                list_seconds = list_seconds + l.seconds
            end
            stellar.log(string.format("load:   %d folder lists (%d started ahead), %.2fs waiting for them; every file: %s",
                #lists, prelists, list_seconds, tostring(write_files())))
            local ctor, dtor, matched = stellar.read_counts()
            stellar.log(string.format("load:   CLexer from a path: %d made; CMemoryFile: %d destroyed, %d of them files of those lexers",
                ctor, dtor, matched))
            -- the files opened that never closed, by database, with examples
            local closed_count = {}
            for _, r in ipairs(files) do
                closed_count[r.path] = (closed_count[r.path] or 0) + 1
            end
            local by_database, examples = {}, {}
            for _, o in ipairs(opened_order) do
                if (closed_count[o.path] or 0) > 0 then
                    closed_count[o.path] = closed_count[o.path] - 1
                else
                    by_database[o.database] = (by_database[o.database] or 0) + 1
                    if #examples < 12 then
                        examples[#examples + 1] = string.format("%s (lexer %s, thread %d)", o.path, tostring(o.lexer), o.thread)
                    end
                end
            end
            local list = {}
            for name, n in pairs(by_database) do
                list[#list + 1] = name .. " " .. n
            end
            table.sort(list)
            stellar.log("load:   opened, never closed: " .. table.concat(list, ", "))
            stellar.log("load:   for example: " .. table.concat(examples, "; "))
        end
        if #post_reads > 0 then
            local by_time, seconds = {}, 0
            for i, p in ipairs(post_reads) do
                by_time[i] = p
                seconds = seconds + p.seconds
            end
            table.sort(by_time, function(a, b) return a.seconds > b.seconds end)
            local top = {}
            for i = 1, math.min(#by_time, 15) do
                top[i] = string.format("%s %.3fs", by_time[i].name, by_time[i].seconds)
            end
            stellar.log(string.format("load:   %d PostReadInitInstance in %.1fs; the longest: %s", #post_reads, seconds,
                table.concat(top, ", ")))
        end
        local keys = {}
        for key, n in pairs(deep) do
            keys[#keys + 1] = { key, n }
        end
        table.sort(keys, function(a, b) return a[2] > b[2] end)
        for i = 1, math.min(#keys, 20) do
            keys[i] = keys[i][1] .. " " .. keys[i][2]
        end
        if #keys > 0 then
            stellar.log("load: stages deeper than " .. MAX_DEPTH .. " (file:line count): " .. table.concat(keys, ", ", 1, math.min(#keys, 20)))
        end
    end
end

return loading
