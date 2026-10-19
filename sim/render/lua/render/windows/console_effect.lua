-- render/windows/console_effect.lua : the game console's `effect` (OnExecute_Effect 0x2c30180: its
-- words joined with spaces, run as a script effect in the player's country's scope [I: the scope;
-- `root` is the country in the game's runs]) in the simulation's runtime, as the headless game's
-- `effect` command runs it in the game: a test's setup made the same way on both sides (a colony
-- ship, a transport, a hostile fleet). The renderer's script command `effect WORDS...`.
--
--   require("render.windows.console_effect").run(text) -> "ok effect: ..." | "error effect: ..."

local M = {}

function M.run(text)
    local ok, r = pcall(function()
        local pdxscript = require("pdxscript")
        local eval = require("simscript.eval")
        local body, msg = pdxscript.parse(text, "console effect")
        if not body then return "error effect: " .. tostring(msg) end
        local player = require("render.windows.fleet_data").player()
        eval.effect(body, eval.new_ctx(eval.S("country", player), nil, nil, "console"))
        return "ok effect: Executing effect script."
    end)
    return ok and r or ("error effect: " .. tostring(r))
end

return M
