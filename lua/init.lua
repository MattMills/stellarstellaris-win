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

local function read_catalog(waited)
    local d = docs.read()
    local documented = d ~= nil and #d.triggers_order > 0 and #d.effects_order > 0
    local c, message = catalog.read(script_where, stellar.read)
    if c == nil then
        if waited < 120 then
            return false
        end
        stellar.log("script: cannot read the catalog: " .. tostring(message))
        return true
    end
    if (c.lexer.stale or not documented) and waited < 120 then
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
    local census, census_message = catalog.census(c, script_where, stellar.read)
    if census == nil then
        stellar.log("script: census failed: " .. tostring(census_message))
        return true
    end
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
    return true
end

-- last: from here on the game's main thread calls into Lua
ok, err = pcall(game.start, image)
if not ok then
    stellar.log("game.start failed: " .. tostring(err))
end
image:close()

-- the heartbeat reaches Lua: log the first one; read the catalog when the game has loaded
local heartbeats, catalog_done = 0, script_where == nil
stellar.heartbeat = function(frame)
    heartbeats = heartbeats + 1
    if heartbeats == 1 then
        stellar.log("heartbeat from Lua, frame " .. tostring(frame))
    end
    if not catalog_done then
        local done, result = pcall(read_catalog, heartbeats)
        if not done then
            stellar.log("script catalog failed: " .. tostring(result))
        end
        catalog_done = not done or result
    end
    if catalog_done then
        stellar.heartbeat = nil
    end
end
