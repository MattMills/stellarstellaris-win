-- dev.lua : running Lua in the game without restarting it, for development.
--
-- Only when dev\enabled exists next to stellar-injected.dll: every heartbeat, if dev\run.lua is
-- there, it is run (on the init thread, protected) and renamed to run.lua.done.
-- What it prints goes to the log (print is stellar.log). It gets `state`, the table where
-- init.lua keeps what it found (the catalog, the census, the script addresses), as its first
-- argument (`local state = ...`).
--
--   local dev = require("stellar.dev")
--   dev.state.catalog = c
--   dev.poll()   -- from the heartbeat

local stellar = require("stellar")
local util = require("stellar.util")

local dev = { state = {} }

local directory = util.dirname(stellar.dll_path) .. "\\dev"
local script = directory .. "\\run.lua"

local function exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- dev.enabled: whether the dev directory exists (checked once, at load)
dev.enabled = exists(directory .. "\\enabled")

function dev.poll()
    if not dev.enabled or not exists(script) then
        return
    end
    local chunk, message = loadfile(script)
    os.remove(script .. ".done")
    os.rename(script, script .. ".done")
    if chunk == nil then
        stellar.log("dev: " .. tostring(message))
        return
    end
    local t0 = util.now()
    local ok, err = xpcall(function() return chunk(dev.state) end, debug.traceback)
    stellar.log(string.format("dev: run.lua %s in %.2fs%s", ok and "done" or "failed", util.now() - t0,
        ok and "" or (": " .. tostring(err))))
end

return dev
