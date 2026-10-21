-- profiler.lua : the profiler's hook mode (profiler.txt "hook [port]" next to the DLL;
-- docs/profiler.md). The game functions whose names match fnmatch globs (profiler_symbols.txt next
-- to the DLL, or the page) are found in the running build with lua_fnmatch and timed on entry and
-- exit by src/dll/profiler.cpp; a web page on http://127.0.0.1:<port>/ shows them.
--
-- The names come from, in this order (the first to name an address or a name wins):
--   - the functions of functions.lua, found already (stellar.resolve);
--   - the game's PDB, stellaris.pdb next to stellaris.exe (GOG builds ship it);
--   - labels/*.csv next to the DLL: `stellar-fnmatch match`'s export.csv, its rows for this build
--     (by md5): the names stellar-fnmatch gave the functions of a Steam build;
--   - sigs/*.sig next to the DLL: stellar-fnmatch .sig files of builds with a PDB. The .sig of this
--     very build gives addresses; the others give the signatures of each name that matches, found
--     in this build by one fnmatch bundle (the newest build first, without the kinds that are
--     unreliable across versions).
--
--   local profiler = require("stellar.profiler")
--   profiler.glob("CShip::*")                      --> "^CShip::.*$" (a Lua pattern)
--   local list, report = profiler.find(image, { include = { "CShip::*" }, found = found, dir = dir })
--   profiler.start(image, found, port)             -- in the game: serves the page, hooks
--   profiler.poll()                                -- from the heartbeat: patterns asked for on the page
--
-- profiler.find runs outside the game too (tools/profiler_dry_run.lua).

local fnmatch = require("fnmatch")
local util = require("stellar.util")

local profiler = {}

profiler.PORT = 8710
-- at most this many hooks from one search: a hook costs about 90 ns a call
profiler.MAX_HOOKS = 20000
-- without profiler_symbols.txt: the game's updates, daily, monthly and yearly, and the tick's
-- (77 functions in 4.5.2). CGameState::HandleTurnTick itself is stellar.game's hook.
profiler.DEFAULT = {
    "*::DailyUpdate", "*::MonthlyUpdate", "*::YearlyUpdate", "*::MicroUpdate", "CGameState::*Update*",
}
-- signature kinds that can name another function in another version (lua_fnmatch's README)
local UNRELIABLE = { imm = true, a_vtslot = true, a_table_prev = true, a_table_next = true }

-- the Lua pattern of an fnmatch glob: `*` any text, `?` one character, `[abc]`, `[a-z]` and
-- `[!abc]` (or `[^abc]`) one of a set, `\x` the character x; the whole name must match
function profiler.glob(glob)
    local out, i, n = { "^" }, 1, #glob
    local function literal(c)
        return c:match("%w") and c or "%" .. c
    end
    while i <= n do
        local c = glob:sub(i, i)
        if c == "*" then
            out[#out + 1] = ".*"
        elseif c == "?" then
            out[#out + 1] = "."
        elseif c == "\\" and i < n then
            i = i + 1
            out[#out + 1] = literal(glob:sub(i, i))
        elseif c == "[" then
            local j = i + 1
            local negate = glob:sub(j, j) == "!" or glob:sub(j, j) == "^"
            if negate then
                j = j + 1
            end
            -- a `]` first in the set is one of its characters
            local close = glob:find("]", glob:sub(j, j) == "]" and j + 1 or j, true)
            if close then
                local set = glob:sub(j, close - 1):gsub("%%", "%%%%")
                out[#out + 1] = "[" .. (negate and "^" or "") .. set .. "]"
                i = close
            else
                out[#out + 1] = "%["
            end
        else
            out[#out + 1] = literal(c)
        end
        i = i + 1
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

-- profiler.parse(text) -> include, exclude: one glob a line; `!glob` excludes; `#` comments
function profiler.parse(text)
    local include, exclude = {}, {}
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            if line:sub(1, 1) == "!" then
                exclude[#exclude + 1] = line:sub(2):match("^%s*(.-)$")
            else
                include[#include + 1] = line
            end
        end
    end
    return include, exclude
end

-- the globs of a file (nil if there is none)
function profiler.read_patterns(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return profiler.parse(text)
end

-- a function(name) -> true when a name matches an include glob and no exclude glob
function profiler.matcher(include, exclude)
    local inc, exc = {}, {}
    for _, g in ipairs(include) do
        inc[#inc + 1] = profiler.glob(g)
    end
    for _, g in ipairs(exclude or {}) do
        exc[#exc + 1] = profiler.glob(g)
    end
    return function(name)
        local ok = false
        for _, p in ipairs(inc) do
            if name:find(p) then
                ok = true
                break
            end
        end
        if not ok then
            return false
        end
        for _, p in ipairs(exc) do
            if name:find(p) then
                return false
            end
        end
        return true
    end
end

-- the files of a directory with an extension, sorted
local function list_files(dir, extension, sep)
    local files = {}
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi.os == "Windows" then
        pcall(ffi.cdef, [[
            typedef struct { uint32_t attributes; uint32_t times[6]; uint32_t size_high, size_low, reserved0, reserved1;
                char name[260]; char alternate[14]; } stellar_find_data;
            void *FindFirstFileA(const char *pattern, stellar_find_data *data);
            int FindNextFileA(void *handle, stellar_find_data *data);
            int FindClose(void *handle);
        ]])
        local data = ffi.new("stellar_find_data")
        local handle = ffi.C.FindFirstFileA(dir .. sep .. "*" .. extension, data)
        if tonumber(ffi.cast("intptr_t", handle)) ~= -1 then
            repeat
                if bit.band(data.attributes, 0x10) == 0 then
                    files[#files + 1] = dir .. sep .. ffi.string(data.name)
                end
            until ffi.C.FindNextFileA(handle, data) == 0
            ffi.C.FindClose(handle)
        end
    else
        local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
        for name in p:lines() do
            if name:sub(-#extension) == extension then
                files[#files + 1] = dir .. sep .. name
            end
        end
        p:close()
    end
    table.sort(files)
    return files
end

-- "4.5.2" before "4.5.10" before "4.10.0", newest first
local function newer(a, b)
    local x, y = {}, {}
    for n in tostring(a):gmatch("%d+") do
        x[#x + 1] = tonumber(n)
    end
    for n in tostring(b):gmatch("%d+") do
        y[#y + 1] = tonumber(n)
    end
    for i = 1, math.max(#x, #y) do
        if (x[i] or -1) ~= (y[i] or -1) then
            return (x[i] or -1) > (y[i] or -1)
        end
    end
    return false
end

-- the symbol of a line of export.csv (the last column, maybe quoted, may hold commas)
local function csv_fields(line)
    local fields, rest = {}, line
    for _ = 1, 8 do
        local field, after = rest:match("^([^,]*),(.*)$")
        if field == nil then
            return nil
        end
        fields[#fields + 1] = field
        rest = after
    end
    if rest:sub(1, 1) == '"' and rest:sub(-1) == '"' then
        rest = rest:sub(2, -2):gsub('""', '"')
    end
    fields[9] = rest
    return fields
end

-- profiler.find(image, options) -> list, report: the functions of `image` whose names match, as
-- { address, name, source }, and what each source gave. Options:
--   include, exclude   globs
--   found              name -> address (stellar.resolve.functions)
--   dir                where labels/ and sigs/ are (nil: none); sep, the path separator ("\\")
--   pdb, open_pdb      the PDB's path and function(path) -> an image of this build with its names
--   max                at most this many (profiler.MAX_HOOKS)
function profiler.find(image, options)
    local t0 = util.now()
    local matches = profiler.matcher(options.include or {}, options.exclude)
    local sep = options.sep or "\\"
    local max = options.max or profiler.MAX_HOOKS
    local base, md5 = image:base(), image:md5()
    local list, by_address, by_name = {}, {}, {}
    local report = { sources = {}, order = {}, not_found = 0, truncated = false }

    local function count(source)
        if report.sources[source] == nil then
            report.sources[source] = 0
            report.order[#report.order + 1] = source
        end
    end
    -- a function start of this build, not an EH funclet
    local function entry(address)
        local f = image:function_at(address)
        return f ~= nil and f.address == address and f.funclet_of == nil
    end
    local function add(address, name, source)
        count(source)
        if by_address[address] or by_name[name] then
            return
        end
        if #list >= max then
            report.truncated = true
            return
        end
        if not entry(address) then
            return
        end
        by_address[address], by_name[name] = true, true
        list[#list + 1] = { address = address, name = name, source = source }
        report.sources[source] = report.sources[source] + 1
    end
    -- the first matching name of a description's names
    local function matching(names)
        for _, name in ipairs(names or {}) do
            if matches(name) then
                return name
            end
        end
    end

    -- functions.lua
    local names = {}
    for name in pairs(options.found or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if matches(name) then
            add(options.found[name], name, "functions.lua")
        end
    end

    -- the PDB
    if options.pdb and options.open_pdb then
        local f = io.open(options.pdb, "rb")
        if f then
            f:close()
            local pdb, message = options.open_pdb(options.pdb)
            if pdb and pdb:has_pdb() then
                for i = 1, #pdb do
                    local fn = pdb[i]
                    local name = fn.funclet_of == nil and matching(fn.names)
                    if name then
                        add(fn.address, name, "pdb")
                    end
                end
                pdb:close()
            else
                report.pdb_error = tostring(message or "no names in it")
                if pdb then
                    pdb:close()
                end
            end
        end
    end

    if options.dir then
        -- labels/*.csv: stellar-fnmatch match's export.csv
        for _, path in ipairs(list_files(options.dir .. sep .. "labels", ".csv", sep)) do
            local f = io.open(path, "rb")
            for line in f:lines() do
                local x = csv_fields((line:gsub("\r$", "")))
                -- build_id,version,platform,exe_md5,start_va,end_va,score,evidence,symbol
                if x and x[4]:lower() == md5 and matches(x[9]) then
                    local va = tonumber(x[5])
                    if va then
                        add(base + va - 0x140000000, x[9], "labels")
                    end
                end
            end
            f:close()
        end

        -- sigs/*.sig: this build's first, then the newest
        local sigs = {}
        for _, path in ipairs(list_files(options.dir .. sep .. "sigs", ".sig", sep)) do
            local sf, message = fnmatch.sig_file(path)
            if sf then
                sigs[#sigs + 1] = { file = sf, path = path, same = sf:md5() == md5, version = sf:version() }
            else
                report.sig_errors = (report.sig_errors or 0) + 1
                report.sig_error = message
            end
        end
        table.sort(sigs, function(a, b)
            if a.same ~= b.same then
                return a.same
            end
            return newer(a.version, b.version)
        end)
        local wanted, wanted_names = {}, {}
        for _, s in ipairs(sigs) do
            local source = "sig " .. s.file:id()
            for i = 1, #s.file do
                local fn = s.file[i]
                local name = fn.funclet_of == nil and matching(fn.names)
                if name and not by_name[name] then
                    if s.same then
                        add(base + fn.rva, name, source)
                    elseif not wanted_names[name] then
                        local alternatives = {}
                        for _, sig in ipairs(s.file:signatures(fn.rva) or {}) do
                            if not UNRELIABLE[sig:match("^([%w_]+):")] then
                                alternatives[#alternatives + 1] = sig
                            end
                        end
                        if #alternatives > 0 then
                            wanted_names[name] = true
                            wanted[#wanted + 1] = { name = name, signatures = alternatives, source = source }
                        end
                    end
                end
            end
            s.file:close()
        end
        -- the names of other builds, found in this one together
        if #wanted > 0 then
            local bundle = fnmatch.bundle(image)
            local entries = {}
            for i, w in ipairs(wanted) do
                if not by_name[w.name] then
                    entries[i] = bundle:register({ name = w.name, signatures = w.signatures, required = false })
                end
            end
            bundle:run()
            for i, w in ipairs(wanted) do
                local e = entries[i]
                if e and e.found then
                    add(e.address, w.name, w.source .. " (matched)")
                elseif e then
                    report.not_found = report.not_found + 1
                end
            end
        end
    end
    report.seconds = util.now() - t0
    return list, report
end

-- "functions.lua 3, pdb 120, ...": what each source gave
function profiler.describe(report)
    local parts = {}
    for _, source in ipairs(report.order) do
        parts[#parts + 1] = source .. " " .. report.sources[source]
    end
    if report.not_found > 0 then
        parts[#parts + 1] = report.not_found .. " names of other builds not found in this one"
    end
    if report.truncated then
        parts[#parts + 1] = "more than " .. profiler.MAX_HOOKS .. ": the rest left out"
    end
    if report.pdb_error then
        parts[#parts + 1] = "the PDB: " .. report.pdb_error
    end
    if report.sig_error then
        parts[#parts + 1] = report.sig_errors .. " .sig files unreadable: " .. tostring(report.sig_error)
    end
    return #parts > 0 and table.concat(parts, ", ") or "no source named any"
end

--
-- In the game
--

local state  -- set by profiler.start

local function note(text)
    local stellar = require("stellar")
    stellar.log("profiler: " .. text)
    stellar.profile_note(os.date("%H:%M:%S ") .. text)
end

-- finds the functions of `include` and `exclude` in `image` and hooks those not hooked yet
function profiler.hook(image, include, exclude, what)
    local stellar = require("stellar")
    local t0 = util.now()
    local list, report = profiler.find(image, {
        include = include, exclude = exclude, found = state.found, dir = state.dir, sep = "\\",
        pdb = util.dirname(stellar.module_path) .. "\\stellaris.pdb",
        open_pdb = function(path) return fnmatch.module("stellaris.exe", { pdb = path }) end,
    })
    local todo = {}
    for _, e in ipairs(list) do
        if not state.hooked[e.address] then
            todo[#todo + 1] = e
        end
    end
    local results, hooked = stellar.profile_hook(todo)
    local reasons, why = {}, {}
    for i, r in ipairs(results) do
        if r == true then
            state.hooked[todo[i].address] = todo[i].name
        else
            if reasons[r] == nil then
                why[#why + 1] = r
            end
            reasons[r] = (reasons[r] or 0) + 1
        end
    end
    for i, r in ipairs(why) do
        why[i] = reasons[r] .. " " .. r
    end
    note(string.format("%s: %d functions (%s), %d of %d new ones hooked in %.1fs%s", what, #list,
        profiler.describe(report), hooked, #todo, util.now() - t0,
        #why > 0 and ("; not hooked: " .. table.concat(why, "; ")) or ""))
    return hooked
end

-- profiler.start(image, found, port): the page on 127.0.0.1:port, then the functions of
-- profiler_symbols.txt (or profiler.DEFAULT) hooked
function profiler.start(image, found, port)
    local stellar = require("stellar")
    local dir = util.dirname(stellar.dll_path)
    state = { found = found or {}, dir = dir, hooked = {} }
    port = port or profiler.PORT
    local ok, message = stellar.profile_serve(port, stellar.lua_dir .. "\\stellar\\profiler.html")
    note(ok and string.format("the page is http://127.0.0.1:%d/", port) or ("no page: " .. tostring(message)))
    local include, exclude = profiler.read_patterns(dir .. "\\profiler_symbols.txt")
    local what = "profiler_symbols.txt"
    if include == nil then
        include, exclude, what = profiler.DEFAULT, {}, "the default patterns (no profiler_symbols.txt)"
    end
    if #include == 0 then
        note(what .. ": no pattern")
        return 0
    end
    return profiler.hook(image, include, exclude, what)
end

-- from the heartbeat: the patterns asked for on the page, hooked (the game analysed again, from
-- the cache)
function profiler.poll()
    if state == nil then
        return
    end
    local stellar = require("stellar")
    local requests = stellar.profile_requests()
    if #requests == 0 then
        return
    end
    local image, message = fnmatch.module("stellaris.exe", { cache = state.dir .. "\\cache" })
    if image == nil then
        note("cannot analyse the game: " .. tostring(message))
        return
    end
    for _, text in ipairs(requests) do
        local include, exclude = profiler.parse(text)
        local ok, err = pcall(profiler.hook, image, include, exclude, "the page's " .. table.concat(include, " "))
        if not ok then
            note("failed: " .. tostring(err))
        end
    end
    image:close()
end

return profiler
