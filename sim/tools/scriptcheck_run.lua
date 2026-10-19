-- tools/scriptcheck_run.lua : the script coverage check, run by examples/run.rs after a save's
-- load (STELLAR_LUA=sim/tools/scriptcheck_run.lua, 0 days):
--
--   SCRIPTCHECK_DOCS=<logs/script_documentation dir> SCRIPTCHECK_MOD=<docs mod dir> \
--   SCRIPTCHECK_OUT=<report.tsv> STELLAR_LUA=sim/tools/scriptcheck_run.lua \
--   cargo run --release --example run -- 0 <save.sav>
--
-- SCRIPTCHECK_COVERAGE=1 also runs simscript.coverage first, for the TSV.s vanilla_uses column (informational:
-- more). Without SCRIPTCHECK_MOD only the static part runs. See simscript/scriptcheck.lua.

local docs = assert(os.getenv("SCRIPTCHECK_DOCS"), "set SCRIPTCHECK_DOCS")
local mod = os.getenv("SCRIPTCHECK_MOD")
if os.getenv("SCRIPTCHECK_COVERAGE") == "1" then
    require("simscript.coverage").run()
end
local r = require("simscript.scriptcheck").run({
    docs = docs, mod = mod, dynamic = mod ~= nil, out = os.getenv("SCRIPTCHECK_OUT"),
})
return r.text
