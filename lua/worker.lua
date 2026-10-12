-- worker.lua : run by each worker state (src/dll/lua.cpp, stellar_worker_state): the Lua state of
-- one thread that needs Lua for itself, such as each thread that reads script (the lexer hook). A
-- worker shares nothing with the main state (lua/init.lua) or the other workers: it has the
-- `stellar` module of the DLL and what this script loads, and it runs on its thread only.

local stellar = require("stellar")

-- the lexer hook (src/dll/lexer_hook.cpp) asks for the GetTok calls of a text here
stellar.lexer_tokens = require("stellar.script.lexer").records
