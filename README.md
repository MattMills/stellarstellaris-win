[![Build](https://github.com/MattMills/stellarstellaris-win/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/MattMills/stellarstellaris-win/actions/workflows/build.yml)


# StellarStellars - Windows (+Linux?) edition

The goal of this project is to start building an enhanced version of StellarStellaris that can hook into Stellaris on multiple platforms, with the initial focus being Steam Windows, since that is the most heavily used version.

This is in a very early alpha stage, it currently doesn't do much of anything.

Currently supported in version v0.1.1-alpha:
 * Windows Steam (should support any current version)
 * Windows GOG (should support any current version)

# NEED BETA TESTERS, JOIN DISCORD!

## Current State

Currently works on WINDOWS, Steam or GOG. I will eventually add Linux support, I don't have any macs.

Everything is being rebuilt in Lua. The C++ patches of the 3.x versions (the hull/shield/armor
regen overflow, the disappearing army outliner group, the species-is-modifiable alert lag, and the
debug logging of events and effects) are gone from this branch; `docs/bug_notes` and
`docs/performance_notes` keep what was learned about those problems.

## Lua scripting (in progress)

stellar-injected.dll embeds LuaJIT with [lua_fnmatch](https://github.com/MattMills/lua_fnmatch)
(stellar-fnmatch function signatures, instruction decoding) and runs `lua/init.lua` from the
directory of the DLL. The C++ side only loads the DLL, starts Lua, hooks the turn tick and gives Lua
memory access; finding code, reading the game and its script engine are done in Lua.

Scripts get the game state every tick (10 per game day): `lua/stellar/game.lua` hooks
`CGameState::HandleTurnTick` and calls back before and after each tick, and after each new day, on
the main thread, with the game state open the way the game opens it ([docs/main_loop.md](docs/main_loop.md)):

```lua
local game = require("stellar.game")
game.after_day(function(gamestate, db)    -- CGameState, CGameStateDatabase (addresses)
    print(game.date_string(gamestate))    -- "2200.01.02": daily, monthly, yearly updates done
end)
```

The game reads its script through the Lua lexer. `lua/stellar/script/lexer.lua` is the game's
tokenizer (`CTextLexer::GetTok`) in Lua. The hook gives the game Lua's tokens for every script text
it reads, from the first file on: the proxy `version.dll` loads StellarStellaris before the game
reads any. On vanilla 4.5.2 the game loads the same script from them: the same `error.log`, and
every compiled trigger and effect matches the files. The load takes about 1.5s more
([docs/text_lexer.md](docs/text_lexer.md)). `lexer.txt` next to the DLL can set `shadow` (the game
reads, and every token is compared with Lua's) or `off`. The log also shows the phases and
progress of the load screen.

| File | |
|---|---|
| `src/dll/lua.cpp` | the Lua state and the `stellar` module |
| `src/dll/code_hook.cpp` | function hooks installed while the game runs (the turn tick) |
| `src/dll/lexer_hook.cpp` | the hook on the game's lexer: Lua's tokens (replace) or a comparison with them (shadow) |
| `src/dll/loading_hook.cpp` | the load screen's events (phases, stages, progress) |
| `src/proxy` | `version.dll` for the game's folder: loads StellarStellaris with the game |
| `install/` | `install.ps1` and the `.bat` files that run it: install into the Stellaris folder, uninstall |
| `lua/init.lua` | the first script |
| `lua/stellar/script/lexer.lua` | the game's tokenizer in Lua ([docs/text_lexer.md](docs/text_lexer.md)) |
| `lua/stellar/script/loader.lua` | locates the lexer and hooks it |
| `lua/stellar/loading.lua` | the load screen in the log: what "loaded" means |
| `lua/stellar/game.lua` | the turn tick hook, the game state and the date |
| `lua/stellar/script/catalog.lua` | the script engine read from the game: every token, trigger and effect (with the vtable of its objects), and a census of the compiled script ([docs/script_engine.md](docs/script_engine.md)); written to `cache/script_catalog-<md5>.tsv` |
| `lua/stellar/script/docs.lua` | the game's own documentation of triggers, effects, scope links and modifiers |
| `lua/stellar/script/source.lua` | the game's script files read in Lua as the game reads them: the enabled mods over the game directory, load order, `inline_script` expanded, scripted triggers, effects and values instantiated |
| `lua/stellar/script/native.lua` | the game's compiled triggers and effects read back as Lua trees |
| `lua/stellar/script/shadow.lua` | the two compared node by node ([docs/script_engine.md](docs/script_engine.md)) |
| `lua/stellar/script/memory.lua` | checked reads of the game's structures (strings, arrays) |
| `lua/stellar/dev.lua` | runs `dev\run.lua` in the running game when `dev\enabled` exists next to the DLL (development) |
| `lib/stellar-lua-pdxscript` | [stellar-lua-pdxscript](https://github.com/MattMills/stellar-lua-pdxscript): `require("pdxscript")`, Paradox script text -> a tree (every vanilla 4.5.2 script file, 0 errors); the build copies `pdxscript.lua` into `lua/` |
| `lua/stellar/functions.lua` | the functions the Lua side uses (the hook point, the functions that name the globals, the script engine's class methods) |
| `lua/stellar/signatures.lua` | their stellar-fnmatch signatures, generated by `tools/make_signatures.lua` |
| `tools/make_signatures.lua` | `luajit tools/make_signatures.lua lua/stellar/signatures.lua gog-4.5.2.sig gog-4.5.1.sig ...` (newest first, `.sig` files from stellar-fnmatch) |
| `tools/dry_run.lua` | `luajit tools/dry_run.lua stellaris.exe`: the lookups of game.lua and of the script catalog, on a file, outside the game |
| `docs/main_loop.md` | the main loop, how the game guards its state, and where to hook to use it |
| `lua/stellar/profiler.lua`, `src/dll/profiler.cpp`, `lua/stellar/profiler.html` | the profiler's hook mode: the functions whose names match fnmatch globs, timed on entry and exit, on a web page on 127.0.0.1 ([docs/profiler.md](docs/profiler.md)) |
| `tools/profiler_dry_run.lua` | `luajit tools/profiler_dry_run.lua stellaris.exe --pdb stellaris.pdb 'CShip::*'`: what the profiler's globs would hook, on a file, outside the game |
| `tests/profiler_test.cpp` | the profiler's hooks and server in a program of their own (`stellar-profiler-test`, run on Windows) |

### The profiler's hook mode

`profiler.txt` next to the DLL with `hook` (and optionally a port: `hook 8710`) hooks the game
functions whose names match the fnmatch globs of `profiler_symbols.txt` (`CShip::*`, `!*::~*`, one a
line), and serves **http://127.0.0.1:8710/**: calls, self and total time and the longest call of
each function, live, with more globs hooked from the page. The names come from the game's PDB
(GOG), stellar-fnmatch's labels of Steam builds (`labels\*.csv`) or its `.sig` files of other
builds (`sigs\*.sig`), found in the running build with lua_fnmatch. A hooked call costs about 90 ns.
See [docs/profiler.md](docs/profiler.md).

The tools need the `fnmatch` module (`fnmatch.dll` / `fnmatch.so` from lua_fnmatch) on `LUA_CPATH`.

`require("stellar")` in the game:

| | |
|---|---|
| `log(...)` | like `print` (which also goes to the log): writes to stellarstellaris-debug.log |
| `suspend_threads()`, `resume_threads()` | every other thread of the game |
| `read(address, size)` | a string, or nil and a message for unmapped memory |
| `patch(address, bytes)` | writes code or read-only data, returns the bytes it replaced |
| `thread_id()` | the id of the calling thread |
| `heartbeat` | set it to a function: called every second (with 1, 2, ...) |
| `hook_turn_tick(handle_turn_tick, gate)`, `turn_tick`, `skipped_ticks()` | used by `stellar.game` |
| `hook_lexer(get_tok, layout, mode)`, `lexer_tokens`, `lexer_stats()`, `lexer_mismatches()` | used by `stellar.script.loader` |
| `hook_loading(push, pop, render, step)`, `loading_events()` | used by `stellar.loading` |
| `profile_hook(list)`, `profile_serve(port, page)`, `profile_requests()`, `profile_note(text)` | used by `stellar.profiler` |
| `module_base`, `module_path` | stellaris.exe |
| `dll_path`, `lua_dir`, `git_hash`, `process_id` | |

The LuaJIT FFI reads and writes memory directly. One Lua state serves the init thread (the
heartbeat) and the game's main thread (the turn tick); C++ code that calls into Lua holds
`stellar_lua_lock()`.

Analysing stellaris.exe for fnmatch takes a few seconds; the analysis is kept in `cache/` next to the
DLL, by md5, so it is done once per game version.

Building needs the submodules (`git submodule update --init --recursive`), a Rust toolchain
(https://rustup.rs, for lua_fnmatch) and a Visual Studio 2022 developer prompt (LuaJIT is built with
its `msvcbuild.bat`).

## Install/Using:

Compiled Windows builds are available as build artifacts of the GitHub workflow. Download the zip
file, extract it, close Stellaris and run `install.bat`. Then start Stellaris as usual.

`install.bat` (`install.ps1`) finds Stellaris (Steam, every library, or GOG); pass
`-GameDir <the folder of stellaris.exe>` when it is somewhere else. It copies:

| from the archive | to the Stellaris folder |
|---|---|
| `proxy\version.dll` | `version.dll` |
| `stellar-injected.dll`, `stellar-injected.pdb`, `lua\` | `stellarstellaris\` |

Windows loads a `version.dll` in the game's folder before the one in System32. This one forwards
the real one's functions and starts `stellarstellaris\stellar-injected.dll` with the game, before
the game reads its script. The installer does not replace a `version.dll` of anything else.

`uninstall.bat` (`install.ps1 -Uninstall`) removes the three: `version.dll` (only
StellarStellaris's), the `stellarstellaris` folder (with its `cache` and settings such as
`lexer.txt`), and a `stellarstellaris.txt` if there is one.

For development, a `stellarstellaris.txt` next to `version.dll` names another stellar-injected.dll
(its first line: a full path, or one relative to the game's folder).

`stellar-loader.exe` is still in the archive: started while the game runs, it loads the DLL into
the running game, once per game. Then the game has already read its script with its own lexer.

## Compatibility:

Currently, there are no compatibility issues, the loader can be run at any time during a game, and can be removed by restarting the game without any issue.

## Support discord:

https://discord.gg/Mtm5nURDSC

[![Join Support discord link](https://discordapp.com/api/guilds/960348408990793838/widget.png?style=banner3)](https://discord.gg/Mtm5nURDSC)

## How to sponsor / support:
https://github.com/sponsors/MattMills

https://www.patreon.com/RadioCapture


### References / Thanks / Borrowed code:
https://github.com/khalladay/hooking-by-example (the process and module helpers of `src/hooking/windows.cpp`)
