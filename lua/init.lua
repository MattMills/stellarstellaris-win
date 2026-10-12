-- init.lua : run by stellar-injected once it is loaded into the game, after the C++ hooks.
--
-- `stellar` is the DLL (see src/dll/lua.cpp): log(...), suspend_threads(), resume_threads(),
-- read(address, size), patch(address, bytes), thread_id(), heartbeat (a function called every
-- second), and the fields module_base, module_path, application, application_base, process_id,
-- dll_path, lua_dir, git_hash. `sigmatch` and `fnmatch` find code; the LuaJIT FFI reads and writes
-- memory.
--
-- report.lua says where the functions the C++ patches target are in this build; no patch is
-- installed from Lua yet. game.lua hooks the turn tick: scripts get the game state every tick (10
-- per game day).

local stellar = require("stellar")
local sigmatch = require("sigmatch")
local fnmatch = require("fnmatch")
local util = require("stellar.util")
local game = require("stellar.game")
local hex = util.hex

stellar.log(string.format("%s with %s and %s (stellar-fnmatch %s), stellar-injected %s", jit and jit.version or _VERSION,
    sigmatch._VERSION, fnmatch._VERSION, fnmatch.fnmatch_version, stellar.git_hash))
stellar.log(string.format("game %s at %s, CApplication at %s, init thread %d", stellar.module_path, hex(stellar.module_base),
    hex(stellar.application), stellar.thread_id()))

-- one analysis of the game for everything below (kept in cache/ by md5)
local t0 = util.now()
local image, message = fnmatch.module("stellaris.exe", { cache = util.dirname(stellar.dll_path) .. "\\cache" })
if image == nil then
    stellar.log("cannot analyse the game: " .. tostring(message))
    return
end
stellar.log(string.format("%s analysed in %.1fs, %d functions, md5 %s", image:path(), util.now() - t0, #image, image:md5()))

local ok, err = pcall(function()
    require("stellar.report").run({ image = image, memory = true, log = stellar.log })
end)
if not ok then
    stellar.log("report failed: " .. tostring(err))
end

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

-- last: from here on the game's main thread calls into Lua
ok, err = pcall(game.start, image)
if not ok then
    stellar.log("game.start failed: " .. tostring(err))
end
image:close()

-- the heartbeat reaches Lua: log the first one
stellar.heartbeat = function(frame)
    stellar.log("heartbeat from Lua, frame " .. tostring(frame))
    stellar.heartbeat = nil
end
