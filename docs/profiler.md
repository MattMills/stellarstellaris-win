# The profiler's hook mode

Where the game's time goes, function by function, in the running game: the functions whose names
match fnmatch globs are hooked on entry and exit, and a web page on the same machine shows their
calls and times while the game runs. Names come from the game's symbols, found in the running build
with lua_fnmatch, so the same globs work on GOG and Steam builds of any version that stellar-fnmatch
has a reference for.

## Turning it on

Next to `stellar-injected.dll` (the game's `stellarstellaris\` folder):

| file | |
|---|---|
| `profiler.txt` | `hook` turns the mode on, an optional second word is the port (default 8710): `hook 8710`. `off` or no file: off |
| `profiler_symbols.txt` | the globs, one a line; `!glob` excludes; `#` comments. Without it, the defaults below |
| `sigs\*.sig` | optional: stellar-fnmatch `.sig` files of builds with a PDB (GOG), to name functions of builds without one |
| `labels\*.csv` | optional: `stellar-fnmatch match`'s `export.csv` (or the rows of one build): its names for Steam builds |

Then start the game and open **http://127.0.0.1:8710/**. The log (`stellarstellaris-debug.log`)
and the page's log say how many functions each glob found, from which source, and how many were
hooked.

```
# profiler_symbols.txt
*::DailyUpdate
*::MonthlyUpdate
CShip::*
CFleet::*Update*
!*::~*          # no destructors
!*::Get*        # nor getters: called millions of times, little each
```

Globs (`profiler.glob`): `*` any text, `?` one character, `[abc]`, `[a-z]` and `[!abc]` one of a
set, `\*` a literal `*`. The whole name must match: `CShip::*` is every method of CShip, not of
CShipDesign. Names are the PDB's (MSVC's undecorated names: `CPdxArray<CShip *,int>::Add`,
`` `dynamic initializer for 'x'' ``).

The defaults (`profiler.DEFAULT`): `*::DailyUpdate`, `*::MonthlyUpdate`, `*::YearlyUpdate`,
`*::MicroUpdate`, `CGameState::*Update*`: 77 functions in 4.5.2, the game's daily, monthly and yearly
updates and the parts of a tick.

## The page

- **Functions**: one row per hooked function called since the reset: calls, calls per second
  (since the last refresh), self time (without the hooked functions it called; the bar), self time
  as a share of wall time (100% is one core busy in that function), total time (inclusive: the
  outermost call of a recursion only), average and longest call. Click a heading to sort; the filter
  takes text or a glob. *Last interval only* shows the times of the last refresh instead of the
  totals.
- **Pause recording** stops counting (the hooks stay: a call still costs the thunk); **Reset**
  zeroes every count.
- **Hook more**: globs sent to the game, searched and hooked at its next heartbeat (a few seconds:
  the game is analysed again from fnmatch's cache, and the PDB or `.sig` files read again).
- **Log**: what the searches found and hooked.

`GET /stats` is the same data in JSON: `{"enabled", "seconds" since the reset, "hooks", "pending",
"notes", "functions": [[index, name, rva, calls, inclusive us, self us, longest us], ...]}`, the
functions called since the reset (`/stats?all=1`: every hooked function). `POST /reset`,
`POST /enable?on=0|1` and `POST /hook?pattern=<globs>` need the header `X-Stellar: 1`.

The server listens on 127.0.0.1 only, and answers only requests whose `Host` is 127.0.0.1,
localhost or [::1]: a web page of another site cannot read it (no CORS headers, and DNS rebinding
gets a 403), nor change it (the header needs a CORS preflight the server never grants).

## Where the names come from

`stellar.profiler.find(image, options)`, in this order; the first source to name an address (or a
name) wins:

1. **functions.lua**: the functions the other modules use, found already (`stellar.resolve`).
2. **The PDB**: `stellaris.pdb` next to `stellaris.exe` (GOG ships it). The running build's own
   names, every function. It costs a second analysis of the game with the PDB (about 3 s, 700 MB at
   its peak, freed after).
3. **labels\*.csv**: `stellar-fnmatch match`'s export.csv, the rows whose `exe_md5` is the running
   build's. On Steam 4.5.2, 99,353 named functions; `CGameState::*Update` and `CShip::*` without
   destructors: 238.
4. **sigs\*.sig**: the `.sig` of the running build itself (same md5) gives addresses directly. The
   others (newest version first) give, for each name that matches, the signatures unique to it in
   that build, without the kinds unreliable across versions (`imm`, `a_vtslot`, `a_table_*`, as
   lua_fnmatch's README measured); one fnmatch bundle finds them all in the running build, the
   names it finds anchoring the symbol relations of the others.

Measured against the PDB of GOG 4.5.2, with only `gog-4.5.1.sig` (`*::DailyUpdate`,
`*::MonthlyUpdate`, `*::YearlyUpdate`, `CShip::*`, `CFleet::*`, `CPlanet::*`): 760 of the PDB's 761
functions found, all 760 at the right address, in 3.4 s.

An address must be the start of a function of the running build and not an EH funclet. Identical
functions the linker folded into one (`/OPT:ICF`) have several names and one address: the first
name that matches is shown, and its counts are those of all of them.

`tools/profiler_dry_run.lua` runs the search on an executable file, outside the game:

```
luajit tools/profiler_dry_run.lua stellaris.exe --pdb stellaris.pdb 'CShip::*' '!*::~*'
luajit tools/profiler_dry_run.lua stellaris.exe --dir <folder with sigs/ and labels/> --patterns profiler_symbols.txt
```

## How a call is timed (src/dll/profiler.cpp)

A hooked function's first instructions become a jmp (`install_code_hook`) to a stub of its own,
`mov r11, <its counters>; jmp <thunk>`. The thunk, one for every function:

1. pushes rbx and makes a frame of 0x100 bytes, keeps rcx, rdx, r8, r9 and xmm0-3, and calls
   `enter(counters, rsp)`;
2. copies the caller's 12 stack arguments (the 5th to the 16th) under its frame, restores the
   argument registers, and calls the original function (its trampoline);
3. keeps rax and xmm0, calls `leave(counters, rsp)`, restores them and returns.

`enter` and `leave` keep a stack of the calls in progress on each thread (thread-local, 256 deep)
with their start (QueryPerformanceCounter) and the time of the hooked functions they called, which
gives self time. The counters are atomic; several threads run the same function at once.

- **C++ exceptions** pass through the thunk: its unwind data is registered (RtlAddFunctionTable:
  `UWOP_PUSH_NONVOL rbx`, `UWOP_ALLOC_LARGE 0x100`). The calls an exception skipped never reach
  `leave`; the next `enter` or `leave` on that thread drops them (their rsp is lower than its own),
  and their time is counted in their caller's self time.
- **What can be hooked**: functions of the x64 calling convention with at most 16 arguments that
  return in rax or xmm0 (not a `__vectorcall` aggregate), whose first instructions (5 bytes or
  more) do not transfer control, and that nothing hooked before (`the target starts with a jmp`):
  the profiler hooks last, after the other modules' hooks. A function the profiler hooked cannot be
  hooked later by another module.
- **Installing**: every other thread is suspended; a thread found in the first 16 bytes of a target
  leaves that one unhooked (`a thread was in its first instructions`). Between the suspend and the
  resume nothing allocates from the heap (a suspended thread may hold its lock): the counters, stubs
  and thread handles are made before, and `install_code_hook` takes its relay and trampoline from
  slots of 128 bytes in 64 KB blocks near the targets (src/dll/code_hook.cpp; before, each hook took
  a 64 KB allocation of its own).
- **Cost**: a call through the thunk costs two QueryPerformanceCounter calls and a few atomic adds:
  88 ns more a call in `tests/profiler_test.cpp` (a 1.4 ns function took 89 ns hooked; Windows 11,
  one thread). That is nothing for an update that runs for milliseconds, and a lot
  for a getter called millions of times a day: exclude those (`!*::Get*`), or watch the calls per
  second. The time of the thunk itself is in the caller's self time. Pausing keeps the cost (the
  hooks stay until the game ends).

`tests/profiler_test.cpp` (`cmake --build build --target stellar-profiler-test`, run on Windows)
hooks functions of its own process and checks 16 arguments, floating point, a struct returned
through a hidden pointer, recursion (fib(15): 1973 calls), exceptions thrown through the hook, exact
counts on four threads, hooking a function while another thread calls it, and the server's routes
and guards.
