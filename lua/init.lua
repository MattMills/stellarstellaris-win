-- init.lua : run by stellar-injected once it is loaded into the game, after the C++ hooks.
--
-- `stellar` is the DLL (see src/dll/lua.cpp): log(...), suspend_threads(), resume_threads(),
-- read(address, size), patch(address, bytes), heartbeat (a function called every second), and the
-- fields module_base, module_path, application, application_base, process_id, dll_path, lua_dir,
-- git_hash. `sigmatch` and `fnmatch` find code; the LuaJIT FFI reads and writes memory.
--
-- For now the scripts only look: report.lua says where the functions the C++ patches target are
-- in this build. No patch is installed from Lua yet.

local stellar = require("stellar")
local sigmatch = require("sigmatch")
local fnmatch = require("fnmatch")
local util = require("stellar.util")
local hex = util.hex

stellar.log(string.format("%s with %s and %s (stellar-fnmatch %s), stellar-injected %s", jit and jit.version or _VERSION,
    sigmatch._VERSION, fnmatch._VERSION, fnmatch.fnmatch_version, stellar.git_hash))
stellar.log(string.format("game %s at %s, CApplication at %s", stellar.module_path, hex(stellar.module_base), hex(stellar.application)))

local cache = util.dirname(stellar.dll_path) .. "\\cache"
local ok, err = pcall(function()
    require("stellar.report").run({ cache = cache, memory = true, log = stellar.log })
end)
if not ok then
    stellar.log("report failed: " .. tostring(err))
end

-- the heartbeat reaches Lua: log the first one
stellar.heartbeat = function(frame)
    stellar.log("heartbeat from Lua, frame " .. tostring(frame))
    stellar.heartbeat = nil
end
