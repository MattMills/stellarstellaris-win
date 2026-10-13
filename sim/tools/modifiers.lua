-- sim/tools/modifiers.lua : the modifier sources of engine.modifiers checked against a capture of
-- the game's modifier nodes, with a plain LuaJIT (no Rust runtime): the vanilla files, the save and
-- the capture of the same moment.
--
--   luajit sim/tools/modifiers.lua [categories]
--     STELLARIS_DIR   the game (default /opt/stellaris)
--     STELLAR_SAVE    the save (.sav, read with `unzip -p`, or a gamestate file;
--                     default /opt/stellaris-saves/autosave_2210.01.01.sav)
--     MODCHECK_NODES  the capture (default /opt/stellaris-captures/modifier-nodes-2210.tsv)
--     MODCHECK_TYPES  a modifiers.log to read the types from (default: made from the game's files)
--   categories: a comma-separated list (Country,Planet,Colony,PopGroup: the default)
--
-- The same check runs from Rust: `cargo test --release --test modifiers -- --nocapture`.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]sim[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/sim/lua/?.lua;" .. dir .. "/sim/lua/?/init.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;"
    .. dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path

-- the platform's helpers (sim/src/runtime.rs), when not run from it
RUST = RUST or {}
RUST.clock = RUST.clock or os.clock
RUST.list_files = RUST.list_files or function(root, sub)
    local out = {}
    local p = io.popen("cd '" .. root .. "' && find '" .. sub .. "' -type f -iname '*.txt' | LC_ALL=C sort")
    for line in p:lines() do
        out[#out + 1] = line
    end
    p:close()
    return out
end
E = E or {}

local function env(k, d)
    local v = os.getenv(k)
    return (v and v ~= "") and v or d
end
local game_dir = env("STELLARIS_DIR", "/opt/stellaris")
local save = env("STELLAR_SAVE", "/opt/stellaris-saves/autosave_2210.01.01.sav")
local nodes_tsv = env("MODCHECK_NODES", "/opt/stellaris-captures/modifier-nodes-2210.tsv")
local types_log = env("MODCHECK_TYPES", nil)

local function gamestate(path)
    local f = io.open(path, "rb")
    if f == nil then
        error("cannot read " .. path)
    end
    local head = f:read(2)
    f:close()
    local p
    if head == "PK" then
        p = io.popen("unzip -p '" .. path .. "' gamestate")
    else
        p = io.open(path, "rb")
    end
    local text = p:read("*a")
    p:close()
    return text
end

local t0 = os.clock()
local text = gamestate(save)
-- the date and the random generator the platform gives (here: the save's date, a counter)
local y, m, d = text:match('\ndate%s*=%s*"(%d+)%.(%d+)%.(%d+)"')
local hours = 43800000 + ((tonumber(y) or 2200) * 360 + ((tonumber(m) or 1) - 1) * 30 + (tonumber(d) or 1) - 1) * 24
RUST.date = RUST.date or function() return hours end
local draws = 0
RUST.rand = RUST.rand or function()
    draws = draws + 1
    return draws
end
-- the engine as sim/src/runtime.rs loads it: the script layer, the definitions, the world
local engine = require("engine")
io.write(engine.load(game_dir, text), "\n")
text = nil
local fs = require("simscript.db").fs

local cats
if arg and arg[1] then
    cats = {}
    for c in arg[1]:gmatch("[^,]+") do
        cats[#cats + 1] = c
    end
end
-- MODCHECK_SHOW=PopGroup:25,Country:0 prints those nodes' own parts, the game's and the computed
local show
for k in env("MODCHECK_SHOW", ""):gmatch("[^,]+") do
    show = show or {}
    show[k] = true
end
local check = require("engine.modifiers.check")
local report = check.run({ nodes_tsv = nodes_tsv, types_log = types_log, categories = cats, game_dir = game_dir,
    fs = fs, show = show, samples = tonumber(env("MODCHECK_SAMPLES", "12")) })
io.write(report, "\n")
io.write(string.format("total %.1f s\n", os.clock() - t0))
