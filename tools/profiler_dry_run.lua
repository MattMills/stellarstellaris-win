-- profiler_dry_run.lua : the profiler's search (stellar.profiler.find) against an executable file,
-- outside the game: which functions its patterns would hook, and where each name came from.
--
-- Usage: luajit tools/profiler_dry_run.lua <stellaris.exe> [options] [glob ...] [!glob ...]
--   --patterns <file>   globs from a file like profiler_symbols.txt (default: the globs given, or
--                       stellar.profiler's defaults)
--   --pdb <file>        the PDB of the executable (as stellaris.pdb next to the game)
--   --dir <dir>         a folder with sigs/*.sig and labels/*.csv (as next to the DLL)
--   --cache <dir>       fnmatch's analysis cache
--   --list <n>          print the first n functions found (default 20)
-- The fnmatch module (lua_fnmatch) must be on package.cpath (LUA_CPATH).

local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../lua/?.lua;" .. package.path

local exe = arg[1]
if exe == nil then
    io.stderr:write("usage: luajit profiler_dry_run.lua <stellaris.exe> [--patterns f] [--pdb f] [--dir d] [--cache d] [--list n] [glob ...]\n")
    os.exit(2)
end
local options, globs = { list = 20 }, {}
local i = 2
while i <= #arg do
    local a = arg[i]
    if a:sub(1, 2) == "--" then
        options[a:sub(3)] = arg[i + 1]
        i = i + 2
    else
        globs[#globs + 1] = a
        i = i + 1
    end
end

local fnmatch = require("fnmatch")
local util = require("stellar.util")
local profiler = require("stellar.profiler")
local hex = util.hex

local include, exclude = profiler.parse(table.concat(globs, "\n"))
if options.patterns then
    include, exclude = profiler.read_patterns(options.patterns)
    assert(include, "cannot read " .. options.patterns)
elseif #include == 0 then
    include = profiler.DEFAULT
end

local t0 = util.now()
local image = assert(fnmatch.file(exe, { cache = options.cache }))
print(string.format("%s: %d functions, md5 %s, analysed in %.1fs", exe, #image, image:md5(), util.now() - t0))
local found = require("stellar.resolve").functions(image)

local list, report = profiler.find(image, {
    include = include, exclude = exclude, found = found, dir = options.dir, sep = "/",
    pdb = options.pdb, open_pdb = function(path) return fnmatch.file(exe, { pdb = path, cache = nil }) end,
})
print(string.format("globs: %s%s", table.concat(include, "  "), #exclude > 0 and ("  excluding " .. table.concat(exclude, "  ")) or ""))
print(string.format("%d functions in %.1fs: %s", #list, report.seconds, profiler.describe(report)))
local base = image:base()
for k = 1, math.min(#list, tonumber(options.list)) do
    local e = list[k]
    print(string.format("  rva %-10s %-34s %s", hex(e.address - base), e.source, e.name))
end
image:close()
