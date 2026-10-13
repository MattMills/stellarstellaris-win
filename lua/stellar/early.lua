-- early.lua : the game's databases begin during the interface and graphics phases of the startup
-- load, driven by Lua, instead of after them.
--
-- CGameApplication::InitGame begins with what the databases need:
--   CGlobalScriptedVariablesDatabase::InitializeWithDirectory("common/scripted_variables") (into
--     CReader::s_GlobalVariables, which every reader looks in)
--   CInlineScriptDatabase::CreateInstance (reads common/inline_scripts)
--   CModifier::InitDefinitions (the modifier definitions)
--   CGfxUtil (graphics: left to the game)
--   the null objects: a table of { TPdxNullObject<T>::Allocate, Initialize } (323 in 4.5.2), every
--     Allocate, then every Initialize (two loops)
--   NNullObjAndDatabaseInitUtil::SetupDatabases
-- early.locate finds these in InitGame. early.prepare gives them to the game's thread for its next
-- step of the load (stellar.loading_step_work: between two files of the interface or graphics
-- phase, where no reader is in the middle of a statement), which then turns the game's own off: the
-- skip flags of the three functions' marks, and a jump over the two loops. The databases then start
-- on the workers (databases.run_parallel, early) while the game's thread goes on with the graphics;
-- SetupDatabases carries on with the rest.
--
--   local early = require("stellar.early")
--   local where = early.locate(found, image, read)       -- at startup (the image open)
--   local status, info = early.prepare(where, marks)      -- from Lua's thread: waits for the step

local ffi = require("ffi")
local fnmatch = require("fnmatch")
local stellar = require("stellar")
local util = require("stellar.util")

local early = {}

early.FUNCTIONS = {
    variables = "CGlobalScriptedVariablesDatabase::InitializeWithDirectory",
    inline = "CInlineScriptDatabase::CreateInstance",
    definitions = "CModifier::InitDefinitions",
    setup = "NNullObjAndDatabaseInitUtil::SetupDatabases",
}

-- the scripted variables' folder, as InitGame gives it: { int32 0, the allocator (8 bytes), a
-- std::string: its data (a pointer from 16 bytes on), size, capacity }; kept alive here
local VARIABLES = "common/scripted_variables"
local keep = {}

local function variables_argument()
    if keep.argument == nil then
        local text = ffi.new("char[32]", VARIABLES)
        local argument = ffi.new("uint8_t[48]")
        ffi.cast("uint64_t *", argument + 16)[0] = ffi.cast("uint64_t", ffi.cast("char *", text))
        ffi.cast("uint64_t *", argument + 32)[0] = #VARIABLES
        ffi.cast("uint64_t *", argument + 40)[0] = 31
        keep.text, keep.argument = text, argument
    end
    return tonumber(ffi.cast("uintptr_t", keep.argument))
end

-- early.locate(found, image, read) -> where | nil, why: InitGame's calls before SetupDatabases
-- (where.variables, inline, definitions: the functions), the null objects' table (where.nulls:
-- { allocate, initialize } pairs) and its loops (where.loops: the first instruction, where.after:
-- the one after them)
function early.locate(found, image, read)
    local init_game = found["CGameApplication::InitGame"]
    if not init_game then
        return nil, "CGameApplication::InitGame not found"
    end
    local where = { init_game = init_game }
    for k, name in pairs(early.FUNCTIONS) do
        where[k] = found[name]
        if not where[k] then
            return nil, name .. " not found"
        end
    end
    local f = image:function_at(init_game)
    local code = f and read(f.address, f.end_address - f.address)
    if code == nil then
        return nil, "cannot read InitGame"
    end
    -- the calls in order, until SetupDatabases; the loops: lea rbx, [table]; mov rdi, rbx; lea rsi,
    -- [end]; call [rdi] ...; call [rbx+8] ...; jne back
    local order, n = {}, 0
    local table_start, table_end, loops, second, after
    local pos = 1
    while pos <= #code do
        local i = fnmatch.decode(code, f.address, pos)
        if i == nil then
            break
        end
        local at = f.address + pos - 1
        if i.flow == "call" and i.target then
            n = n + 1
            order[i.target] = order[i.target] or n
            if i.target == where.setup then
                break
            end
        elseif i.text:match("^lea rbx,%[") and i.rip_relative and not loops then
            table_start, loops = i.target, at
        elseif loops and not table_end and i.text:match("^lea rsi,%[") and i.rip_relative then
            table_end = i.target
        elseif loops and i.flow == "indirect_call" and i.text:match("%[rbx%+8%]") then
            second = at
        elseif second and not after and i.flow == "conditional_branch" and i.target == second then
            after = at + i.length
        end
        pos = pos + i.length
    end
    if not (order[where.variables] and order[where.inline] and order[where.definitions] and order[where.setup]) then
        return nil, "InitGame does not call the scripted variables, inline scripts, definitions and SetupDatabases"
    end
    if not (order[where.variables] < order[where.inline] and order[where.inline] < order[where.definitions]
        and order[where.definitions] < order[where.setup]) then
        return nil, "InitGame calls them in another order"
    end
    if not (table_start and table_end and after and after - loops < 64) then
        return nil, "the null objects' loops not found"
    end
    local count = (table_end - table_start) / 16
    if count < 1 or count > 4096 or count ~= math.floor(count) then
        return nil, "the null objects' table is not a table of pairs"
    end
    local bytes = read(table_start, table_end - table_start)
    if bytes == nil then
        return nil, "cannot read the null objects' table"
    end
    local p = ffi.cast("const uint64_t *", bytes)
    where.nulls = {}
    for k = 0, count - 1 do
        local allocate, initialize = tonumber(p[2 * k]), tonumber(p[2 * k + 1])
        if not (image:function_at(allocate) and image:function_at(initialize)) then
            return nil, string.format("null object %d is not a pair of functions", k + 1)
        end
        where.nulls[#where.nulls + 1] = { allocate, initialize }
    end
    where.loops, where.after = loops, after
    return where
end

-- early.prepare(where, marks, timeout) -> "done", { start, finish } | "failed", { ..., code, index,
-- address } | "cancelled" | nil, why: the start of InitGame run at the game's next step of the load,
-- the game's own turned off (marks: by name, the marks of the three functions, with their ids and
-- trampolines: they are called past their hooks, and their skip flags set). Waits for it (from
-- Lua's thread: the game's thread does not need Lua for its steps); cancelled if the game gets to
-- InitGame first, or after timeout seconds (600)
function early.prepare(where, marks, timeout)
    local m = {}
    for k in pairs({ variables = true, inline = true, definitions = true }) do
        m[k] = marks[early.FUNCTIONS[k]]
        if not (m[k] and m[k].id and m[k].trampoline) then
            return nil, early.FUNCTIONS[k] .. " is not marked"
        end
    end
    local calls = {
        { m.variables.trampoline, 0, variables_argument() },
        { m.inline.trampoline },
        { m.definitions.trampoline },
    }
    for _, pair in ipairs(where.nulls) do
        calls[#calls + 1] = { pair[1] }
    end
    for _, pair in ipairs(where.nulls) do
        calls[#calls + 1] = { pair[2] }
    end
    -- jmp rel32 from the first instruction of the loops to the one after them
    local rel = where.after - (where.loops + 5)
    local jump = string.char(0xE9, bit.band(rel, 0xff), bit.band(bit.rshift(rel, 8), 0xff),
        bit.band(bit.rshift(rel, 16), 0xff), bit.band(bit.rshift(rel, 24), 0xff))
    local ok, why = stellar.loading_step_work(calls, { m.variables.id, m.inline.id, m.definitions.id },
        { { where.loops, jump } }, m.variables.id)
    if not ok then
        return nil, why
    end
    local deadline = util.now() + (timeout or 600)
    while true do
        local status, info = stellar.loading_step_work_wait(0.5, util.now() > deadline)
        if status then
            return status, info
        end
    end
end

return early
