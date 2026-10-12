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
loading.MILESTONES = {
    "CGlobalScriptedVariablesDatabase::InitializeWithDirectory", "CModifier::InitDefinitions",
    "NNullObjAndDatabaseInitUtil::SetupDatabases", "CModifier::InitDefinitionIcons", "CGameRules::InitInstance",
    "CAchievementsManager::InitFromFile", "CApplication::CalculateGameFilesChecksum", "CStaticModifierDatabase::Init",
    "CTriggerDatabase::PostInit", "CTriggerDatabase::PostValidate", "CEffectDatabase::PostInit",
    "CEffectDatabase::PostValidate", "CEventManager::InitEventConnectivityMaps", "CModifier::LogDefinitions",
    "CGameApplication::PrintScriptingDocumentation", "CPortraitSpriteType::InitializeScriptedLogic",
    "CFrontEndIdler::CFrontEndIdler", "DestroyLoadScreen",
}

-- loading.hook_marks(list) -> hooked, failures: hooks each { address, kind, name } of list (an
-- address hooked once: the first mark for it)
function loading.hook_marks(list)
    local addresses, kept, failures, seen = {}, {}, {}, {}
    for _, m in ipairs(list) do
        if m.address and not seen[m.address] then
            seen[m.address] = true
            kept[#kept + 1] = m
            addresses[#addresses + 1] = m.address
        end
    end
    local results = stellar.hook_entries(addresses)
    local hooked = 0
    for i, r in ipairs(results) do
        marks[i] = kept[i]
        if r == true then
            hooked = hooked + 1
        else
            failures[#failures + 1] = kept[i].name .. " (" .. kept[i].kind .. "): " .. tostring(r)
        end
    end
    return hooked, failures
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
                log(e, string.format("database %d/%d %s: %.3fs, %d texts (%.2f MB), %d tokens", e.a, e.b, d.name,
                    d.seconds, d.texts, d.bytes / 1e6, d.tokens))
                database = nil
            end
        elseif e.kind == "enter" then
            local m = marks[e.a] or { kind = "?", name = "#" .. e.a }
            end_post_read(e)
            if m.kind == "create" then
                database = { name = m.name, time = e.time, thread = e.thread, texts = e.texts, tokens = e.tokens,
                    bytes = e.bytes }
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
