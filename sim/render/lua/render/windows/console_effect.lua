-- render/windows/console_effect.lua : the game console's `effect` (OnExecute_Effect 0x2c30180: its
-- words joined with spaces, run as a script effect in the player's country's scope [I: the scope;
-- `root` is the country in the game's runs]) in the simulation's runtime, as the headless game's
-- `effect` command runs it in the game: a test's setup made the same way on both sides (a colony
-- ship, a transport, a hostile fleet). The renderer's script command `effect WORDS...`; and the
-- console's `test_trigger` (OnExecute_TestTrigger 0x2c30b90) the same way, `trigger WORDS...`
-- (stellar-headless tools/qa.py: one script on both sides, the results and times compared).
--
--   require("render.windows.console_effect").run(text) -> "ok effect: ..." | "error effect: ..."
--   require("render.windows.console_effect").trigger(text) -> "ok trigger: yes|no ..." | "error trigger: ..."

local M = {}

-- the evaluator's own time in ms (the round trip has the protocol's in it)
local clock = os.clock
do
    local ok, ffi = pcall(require, "ffi")
    if ok and RUST and RUST.now_fn then
        local now = ffi.cast("double (*)(void)", RUST.now_fn)
        clock = function() return now() end
    end
end

local function in_player_scope(kind, text, run)
    local ok, r = pcall(function()
        local pdxscript = require("pdxscript")
        local eval = require("simscript.eval")
        local body, msg = pdxscript.parse(text, "console " .. kind)
        if not body then return "error " .. kind .. ": " .. tostring(msg) end
        local player = require("render.windows.fleet_data").player()
        local t0 = clock()
        local result = run(eval, body, eval.new_ctx(eval.S("country", player), nil, nil, "console"))
        return string.format("ok %s %.3f ms: %s", kind, (clock() - t0) * 1000, result)
    end)
    return ok and r or ("error " .. kind .. ": " .. tostring(r))
end

function M.run(text)
    return in_player_scope("effect", text, function(eval, body, ctx)
        eval.effect(body, ctx)
        return "Executing effect script."
    end)
end

function M.trigger(text)
    return in_player_scope("trigger", text, function(eval, body, ctx)
        return eval.trigger(body, ctx) and "yes" or "no"
    end)
end

return M
