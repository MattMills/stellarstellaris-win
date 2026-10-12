-- dry_run.lua : runs lua/stellar/report.lua against an executable file, outside the game (the
-- fnmatch part only: there is no process memory to search with sigmatch).
--
-- Usage: luajit tools/dry_run.lua <stellaris.exe> [<cache dir>]
-- The fnmatch module (lua_fnmatch) must be on package.cpath (LUA_CPATH).

local exe, cache = arg[1], arg[2]
if exe == nil then
    io.stderr:write("usage: luajit dry_run.lua <stellaris.exe> [<cache dir>]\n")
    os.exit(2)
end
local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../lua/?.lua;" .. package.path

local fnmatch = require("fnmatch")
local image = assert(fnmatch.file(exe, { cache = cache }))
local results = assert(require("stellar.report").run({ image = image }))
local missing = 0
for _, r in ipairs(results) do
    if not r.address then
        missing = missing + 1
    end
end
os.exit(missing == 0 and 0 or 1)
