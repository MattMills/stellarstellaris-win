# Frame timing: the simulation inside a rendered game (sim/)

The simulation has to run inside a game that renders. At 120 frames a second a frame is 8.33 ms,
and the simulation's work must fit around the frames in one of two ways:

- **inline**: on the render thread, in what each frame leaves after its render work;
- **on a thread of its own**: the render thread only reads what the simulation publishes, and its
  frames must not be slowed by it.

`sim/src/frametime.rs` runs the simulation from a save in a 120 FPS frame loop in each of the two
ways and measures the frames, the game's pace and the phases; `examples/frametime.rs` prints the
whole report, `tests/frame_timing.rs` is the pass or fail check. `lua/engine/slice.lua` is what
lets a phase run inline: it cuts the phase into pieces a frame can hold.

## The target now: 1 ms slices on the simulation's threads (the prototype)

The render thread does nothing but render. The simulation runs on its own threads (its thread
and the worker pool's), each in slices of 1 ms, with every other millisecond unused: time is cut
into milliseconds on one clock for all of them, the odd ones for work and the even ones left idle
(the threads asleep, not spinning). `frametime::run_sliced`, `STELLAR_FRAME_MODE=sliced`, the test
case `in_slices_on_its_threads`.

**The VM stops the code, not the scripts.** A slice is a coroutine resumed with a deadline
(`sim/src/preempt.rs`). While it runs no hook is set, and the interpreter and the compiled code run
at full speed. A preempter thread sleeps until the earliest deadline of the VMs running a slice,
spins its last 0.25 ms, and at a VM's deadline sets a count hook of 1 on it. The interpreter runs the
hook at its next instruction. Compiled code reaches it too: the vendored LuaJIT is built with
`LUAJIT_ENABLE_CHECKHOOK`, so every trace checks the hooks at its start and at every loop iteration
and exits to the interpreter when one is set (`sim/vendor/README.md`). The hook yields the coroutine
wherever it is (`lua_yield` from a hook: LuaJIT adds a continuation frame, and the code goes on at
the same instruction in the next slice). The engine's scripts take no part (`engine.slice`'s checks
are passive in this mode, but for its waits on the worker pool, which yield). The worker pool's jobs
run the same way, each a coroutine on its worker's VM (`workers.rs`). `sim/src/cadence.rs` is the
clock: a slice may start in a work millisecond, no earlier than a millisecond after the thread's last
slice ended, and its deadline is the millisecond's end less 0.1 ms; then the thread sleeps. The JIT
is on.

**What no hook stops, and how each is kept clear of a deadline.** A slice runs late only by a step
that runs no Lua instruction. The report records every one (below), and each kind found has been
dealt with:

| what | found as | what was done |
|---|---|---|
| a Lua function called from C cannot yield | `table.sort`'s comparators (95,000 looks in 35 days), a module's first `require` | `table.sort` and `require` in Lua (`sim/src/table_sort.lua`: LuaJIT's own sort, the same order of the elements, a parity test; `sim/src/require.lua`: Lua 5.1's), the engine's files compiled with the VM (a module's compile is C) |
| the JIT's compiler | 1,444 compile steps over 0.1 ms on the simulation's thread | no trace starts in the last 0.4 ms before a deadline; a recording the preempter's hook aborts is not penalized (LuaJIT blacklisted such loops); the machine code is not write-protected while it runs (`LUAJIT_SECURITY_MCODE=0`: two `mprotect` calls a trace, 0.05 ms a trace, up to 0.4); a new machine code area faulted in at once |
| the collector | the atomic phase, a large table marked | no step in the last 0.25 ms before a deadline (the debt is paid in the next slice) |
| page faults | a burst of 100 and more made a piece up to 1 ms late; 278,000 `mprotect` calls in 16 s on the simulation's thread, which the other threads' page faults waited for | glibc's allocator set for the heaps (memory kept, grown 64 MB at a time, no fastbins: `runtime::tune_malloc`); each thread's heap growth faulted in before its slices (2 GB on the simulation's thread, 384 MB on each worker: `runtime::prefault_heap`), and the store's (`Store::prefault`) |
| the system's scheduler | the preempter set a hook up to 2.9 ms late; a thread preempted 2.6 ms; a thread pinned to one CPU woken 3.5 ms late | the preempter spins its last 0.25 ms, asks for a real-time priority (`SCHED_FIFO` where allowed, a time-critical thread on Windows) and never waits on a VM's lock; the simulation's threads, the preempter and the render thread each on a physical core of its own (both of its logical CPUs: `cadence::pin`) |

**Results** (10.5.0.24, 35 days from 2210.01.01 at Normal, 4 worker threads, the JIT on; the test case
`in_slices_on_its_threads`):

| | before the patched LuaJIT | now |
|---|---|---|
| the simulation's thread: slices, p50, p99, p99.9, longest | 8,638: 0.934, 2.10, 3.44, 14.0 ms | 6,900: 0.899, 0.906, 0.953, 1.69 ms |
| its slices over 1 ms | 24% | 0.072% |
| each worker's slices over 1 ms (longest) | (not run) | none (0.90 to 0.99 ms) |
| the shortest gap between two slices of a thread | 1.006 ms | 1.033 ms |
| the preempter's hooks set within 10 µs of the deadline | | all |
| the render thread's frames | none over 8.33 ms, 4.0 ms | none over, 4.0 ms |
| game days a second (Normal asks 2.67) | 1.59 (60%, workers not sliced) | 2.41 (90%) |

Over runs of the same build the simulation's thread has 0.01 to 0.10% of its slices over 1 ms and its
longest 1.2 to 1.8 ms (one in a dozen runs had one slice of 2.2 ms), and a worker 0 to 2 slices over
1 ms in about 470. The run in slices ends with the same save as a whole run, but for the one value
that differs between any two runs (section 5: an alloys amount's last digit), and the 180-day check
gives the same counts (723,928 / 12,466, 4,723,614 draws). The changes for the slices made the
simulation faster in every mode: the thread mode keeps Normal's pace (2.66 game days a second),
inline went from 82% to 86 to 90%, the serial 180 days from 28.2 s to 27.6 s.

**The record** (the sliced report): each thread's steps no hook stops, by kind, from the vendored
LuaJIT (the collector's phases and the atomic phase's parts, the compiler, each trace's compile by its
size, the traces and collector steps put off); each piece that ended more than 0.1 ms past its
deadline, how it ended (the hook late, or the piece by itself), the longest step no hook stops in it,
its page faults and whether the thread was off the CPU (preempted or blocked), and with
`STELLAR_PREEMPT_TRACE=1` the Lua stack where the hook yielded late or could not yield; how late the
preempter set its hooks; and how late the worker pool's waits came back.

**In the renderer** (docs/render.md section 12, "The render thread renders only"): the render
thread draws only, the app and its Lua on a UI thread, the simulation's days in these slices on
Linux (whole on Windows, where a sleeping thread wakes half a millisecond late). Judged by the 120
FPS standard: with the clock running no frame's CPU part reaches the frame's time (at most 1.8 ms
on 10.5.0.24, 2 ms on the Windows laptop, where 13 to 44 ms before). The renderer neither faults
the heap in ahead nor keeps a collector pause of 400 (memory: 4 to 5.5 GB, from 8).

**What is open**:

- the pace: 90% of Normal. Every other millisecond idle and a margin of 0.1 ms leave the
  simulation's own thread 0.9 ms of every 2; its work is about 180 ms a simulated day and must come
  to about 168. More of it on the workers (the AI, the colonies and pops, the monthly budget:
  docs/data_layer.md section 12; `STELLAR_PARALLEL` now waits for the workers by yielding, and starts
  them with the load), and the engine's own speed;
- what remains past a deadline is the system: a page fault that waits for the memory map's lock,
  a compile step that faults; about a dozen pieces in 35 days on all five threads;
- Windows, the game's platform: the allocator's settings, the faulting in and the pinning are written
  for Linux and glibc (the preempter's priority has a Windows path); Windows needs its own;
- the cost of the settings: the machine code writable while it runs (the hardening W^X gives against
  a memory-corruption bug), and 3.5 GB of the heaps' growth taken at the load.

## In short (the earlier targets)

- **The frame loop**: the render thread draws 120 frames a second (4 ms of render work by default, a
  busy wait) and is the game's clock: two ticks every `gGameSpeedTurnTimes[speed]`, as
  `CInGameIdler::CheckTick` posts them. The simulation runs the ticks posted.
- **Inline fits.** Each phase runs as a Lua coroutine; the engine's loops, the script evaluator and
  the modifier graph check the platform's clock between their objects (`engine.slice`), and past
  the frame's deadline the phase yields and goes on in the next frame. Over 35 days from 2210.01.01
  on 10.5.0.24, at every speed, 0 to 2 frames in a few thousand are over 8.33 ms (0.11% at most),
  the 99th percentile is 7.5 ms and the worst frame 8 to 10 ms (section 4). Over 180 days at Normal
  17 of 8,303 frames are over (0.20%), the worst 17.3 ms. The game's pace inline is what the
  frames leave, 3.33 ms of each: Slowest and Slow keep theirs; Normal runs at 82% over the first
  35 days and 97% over 180.
- **On its own thread it fits too**: no frame is slowed (4.0 ms, the render work, in every run),
  and the game keeps its pace up to Fast over 180 days (99% at Normal, 98% at Fast); Fastest asks
  for 24 game days a second and the simulation runs about 5.
- **The results are the same.** The 180-day check against the headless game's save gives the same
  counts as before (723,928 fields equal, 12,466 differ, 4,723,614 draws), and a 35-day run cut into
  pieces ends with the same save as one run whole, but for the one value that differs between any
  two runs (section 5).
- **The check**: `cargo test --release --test frame_timing -- --ignored` passes both cases at
  Normal: inline none of 2,192 frames over 8.33 ms (the worst 8.1 ms), on the thread none.

## 1. The model

**The game's clock is the render thread's**, as in the game, where `CInGameIdler::CheckTick`
posts two tick commands every `gGameSpeedTurnTimes[speed]` seconds: 0.3, 0.15, 0.075, 0.04 s for
speeds 1 to 4 (a day of ten ticks lasts 1.5, 0.75, 0.375, 0.2 s), and two every frame at the
fastest (at 120 FPS a day every five frames, 24 game days a second) (docs/render.md section 12).
Every frame posts the ticks its time is worth; the simulation runs the ticks posted. A simulation
that falls behind leaves ticks posted and not run (the backlog); the game's pace is the game days
run a second against what the speed asks for, and a run *keeps pace* at 95% or more.

**A frame** is the render work, a busy wait of `render_ms` (4 ms by default: the renderer's own
cost is measured on its own, docs/render.md), then what else the render thread does, then the wait
for the frame's deadline, as vsync does. A frame whose work ends after its deadline misses it, and
every deadline it passes; the next frame starts at the first deadline after it. A frame's time is
from its start to the end of its work.

**Units and pieces.** A tick is a list of units, its phases in the game's order (`MicroUpdate`,
`ProcessAI`, each phase of `DailyUpdate`, `MonthlyUpdate` and `YearlyUpdate`:
`sim/src/scheduler.rs`). A unit runs as a coroutine of `engine.phase` (`Runtime::phase_thread`);
`Simulation::step_until(deadline)` resumes the current one with a deadline on the platform's clock
(`runtime::clock`, read in Lua through the FFI) and returns when it finishes or yields, and the next
call goes on where it stopped. Nothing else runs in the Lua state between two pieces, so a phase
sees the world as if it had run whole. `Simulation::step` is `step_until` without a deadline, and
`tick` runs the steps of a tick.

**Inline** (`frametime::run_inline`): after the render work, units run in pieces up to the frame's
deadline less a margin (1 ms: 8.33 - 4 - 1 = 3.33 ms of room a frame by default). A piece past the
deadline yields at the engine's next check; the margin is the slack for the stretch between two
checks that runs past it. The run fits when the 99th percentile of its frames is within 8.33 ms, at
most one frame in two hundred is over, and none is over two frames' time (16.7 ms).

**On a thread** (`frametime::run_threaded`): the simulation is made on its own thread (a Lua state
stays on the thread that made it) and runs the ticks the render thread's clock posts, a unit at a
time, sleeping when none is posted; after each day it publishes the date under a mutex, which the
render thread reads every frame. The render thread first draws 3 s of frames with no simulation
(the baseline), then frames while the thread loads the save (the game paused), then frames while it
runs. The run fits when the 99th percentile of its frames is within 8.33 ms and at most one frame in
a thousand is over (the OS's own hiccups: the baseline shows whether there are any). It keeps pace
or it fails.

This is the renderer's simulation thread (`sim/render/src/clock.rs`, docs/render.md section 12)
reduced to what concerns the frames: that thread runs whole days and publishes a snapshot of the
galaxy after each (25 to 70 ms on 10.5.0.24, its own cost on the simulation's thread), which this
one does not.

## 2. Running it

```
cd sim
cargo run --release --example frametime -- [days] [save.sav]
cargo test --release --test frame_timing -- --ignored --nocapture --test-threads 1
```

(on Windows `sim\cargo_msvc.cmd` in place of `cargo`). The defaults are 35 days from the 2210.01.01
autosave (`save::default_save`: one month's end, 2210.02.01), Normal speed, 120 FPS, 4 ms of render
work. The settings:

| variable | default | |
|---|---|---|
| `STELLAR_FRAME_SPEED` | 3 | 1 (Slowest) to 5 (Fastest); for the example also a list (`3,5`) or `all` |
| `STELLAR_FRAME_DAYS` | 35 | game days to run (the example's first argument too) |
| `STELLAR_FRAME_FPS` | 120 | |
| `STELLAR_FRAME_RENDER_MS` | 4 | the render thread's own work a frame |
| `STELLAR_FRAME_MARGIN_MS` | 1 | inline: left free at the end of a frame |
| `STELLAR_FRAME_BASELINE_S` | 3 | thread: seconds of frames with no simulation first |
| `STELLAR_FRAME_MODE` | both | the example: `inline`, `thread` or `both` |
| `STELLAR_FRAME_SAVE_DIR` | | writes each run's end as `<mode>-speed<N>.gamestate` there |

And `engine.slice`'s record, in the report's `slice:` lines:

| variable | |
|---|---|
| `STELLAR_SLICE_GAP_MS` | the stretches between two checks recorded, from this long (0.5) |
| `STELLAR_SLICE_TRACE=1` | where the longest stretch of each pair of sites that crossed a frame's end ended (a traceback) |
| `STELLAR_SLICE_PROFILE=1` | LuaJIT's sampling profiler (`jit.profile`) in the long stretches, by line and by stack (a number: the stack's depth) |
| `STELLAR_SLICE_PROFILE_MS` | the stretches sampled, from this long (2) |
| `STELLAR_SLICE_GC=1` | the heap, the largest tables, the weak tables by where they were made, the collector's longest steps through a cycle, a full collection's time |

The test's two cases, `inline_in_what_each_frame_leaves` and `on_a_thread_of_its_own`, fail with
what did not fit: the frames over 8.33 ms and the worst, the units with a piece longer than a
frame's room (inline), and the game days a second against the speed's (on the thread). They are
ignored by default: they take a load and the days in real time, and they measure the machine as
much as the simulation.

## 3. A phase in pieces: `engine.slice`

**Checks and ticks.** `slice.check(site)` reads the clock (an FFI call, `RUST.now_fn`); past the
deadline it yields. `slice.tick(site)` is for the loops over many small objects and the script
evaluator's own calls: it reads the clock every few calls of its site, as many as take about 50 us
at the pace of its last ones (at most 4), and near the deadline no more than half of what is left
holds. Neither yields where the coroutine cannot (in a sort's comparator, a gsub callback, a call
from Rust): `coroutine.isyieldable()` says so, and there the check only keeps its record. Without
a deadline (a whole tick, a worker, a tool) nothing yields.

**Predicted stretches.** Each site keeps the longest stretch after it (a check) or call of it (a
tick), fading by 3% at each shorter one. A check yields early before a stretch that will not fit in
what the frame has left but fits in a frame of its own; so does a phase's start (`slice.begin`, a
phase's usual first stretch), and every call into an engine module from `systems.lua`
(`call_optional`, a check named by the module and function) learns that module's own start.

**Where the checks are.**

- The systems' loops: a check per country, per colony, per fleet with orders, per AI country and AI
  module, per research area; a tick per object in the stores' countdowns.
- A tick at the top of every loop over a world store in the engine (`for ... in
  ipairs(world.all(...))`: 94 of them, named by file and line), and of every loop of the AI's
  economy planner, budget, construction ships, starbases, research, exploration and traditions, and
  of fleet creation (258).
- The script layer: a tick at every trigger block and effect block the walker evaluates, every
  compiled trigger (`trigger_c`), compiled block of four statements or more, compiled scripted
  trigger and item of a compiled `any_` iterator, and every statement the compiler compiles.
- The modifier graph's monthly update (`engine.modifiers.incremental`): a tick per holder in each of
  its passes; the graph's changes propagated and its nodes computed in pieces of 2,048 units of work
  (`g:mark(budget)`, `g:run(class, budget)`: the same nodes in the same order as `g:flush()`); in
  `stellar.graph.core` a tick in the walks of `raise`, `pull` and `lower_need`; in
  `stellar.graph.modifiers` a tick at each node made on demand and each type of a holder's values.
- Exploration's pass over the shared store: its inputs and its sync with the table world (a tick per
  object, block and entry), its merge, and the worker pool's results; the pass itself runs on the
  workers, and the main thread waits for it a frame at a time (`RUST.pool_post`, `RUST.pool_poll`:
  the frame's time left, then `slice.wait` yields).

**Made so that it can be cut.**

- `table.sort` cannot yield in its comparator: the AI strategy's lists (thousands of entries a
  country, a total order) are sorted by a merge sort with a tick between its merges, and the graph's
  `pull` puts a list of more than 64 nodes in order by a bucket sort by level (the nodes of one level
  do not read each other: their order among themselves changes no value).
- `stellar.graph.buffer` grows its arrays by a new allocation, copied and zeroed a quarter of a
  megabyte at a time with a tick between, where one `realloc` and fill of tens of megabytes could
  not be cut.
- The shared store's string interner (a Rust `HashMap`) is made at its capacity (the store's string
  cap): it never moves every string into a larger table in the middle of an intern.

**Moved to the load.** What the first day or month would do once, the load does (`engine.load`,
nothing of the world read or changed, no draws): exploration's store statics and the worker pool
(`engine.store.bridge.prepare`); the engine's modules the phases load on first use; the files read
on first use (component and section templates, special projects, ship sizes and armies, the
scripted variables movement and fleet creation read, the pathfinder's defines); each definition
file's `@variables`, read in the load's own parse of the file (`stellar.script.source.definitions`
returns them, `simscript.db.set_filevars` keeps them) where `db.filevars` parsed the file again on
first use. Then a full collection: the load's garbage is collected with it (about a second), and the
collector's next cycle comes when the heap has doubled again, not straight away.

**The collector.** LuaJIT's collector is incremental, but its atomic step, a weak table's clearing
and a large table's traversal are each one step that nothing cuts. On the 1.4 GB heap of this game
the longest step was 6.6 ms, most of it the world's field index (`engine.world`), a weak table of
every block read (84,000 at day 10, 103,000 at day 35), traversed again and cleared in the atomic
step. A block of 8 entries or fewer (most of them: coordinates, short lists) is now scanned instead
of indexed, which costs no more than the index (35 days: the same total time) and leaves 13,000
entries; the longest step is 2.1 to 2.6 ms. `STELLAR_WORLD_CHECK=1` counts the reads of an index made
stale by a direct edit: none in 35 days, so a scan and the index give the same entries. Without the
collector a 35-day run is about a fifth faster (it marks the whole heap a step at a time in a cycle),
and grows by about 1.1 GB.

**The record.** `slice.report` lists the longest stretches between two checks by the pair of sites,
and the stretches that crossed a frame's end (the platform gives it: `Runtime::set_frame_end`), with
a traceback of where the longest of each ended. Every frame over 8.33 ms inline has one.

## 4. Results on 10.5.0.24

Ryzen 9 5900X (12 cores, 24 threads), Linux, quiet, 2026-10-14. 35 days from the 2210.01.01
autosave (the month's end on 2210.02.01), 120 FPS, 4 ms of render work, a 1 ms margin inline; every
run from its own load of the save (5.5 s with what moved to it); `examples/frametime` with
`STELLAR_FRAME_SPEED=all`.

| speed | days a second asked | inline: days a second | inline: frames over 8.33 ms | inline: p99, worst | thread: days a second | thread: frames over 8.33 ms | thread: worst |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 Slowest | 0.67 | 0.67 | 0 of 6,304 | 7.4, 8.2 ms | 0.67 | 0 of 6,304 | 4.0 ms |
| 2 Slow | 1.33 | 1.33 | 2 of 3,156 (0.06%) | 7.5, 9.9 ms | 1.33 | 0 of 3,154 | 4.0 ms |
| 3 Normal | 2.67 | 2.19 (82%) | 1 of 1,918 (0.05%) | 7.5, 8.8 ms | 2.66 (100%) | 0 of 1,579 | 4.0 ms |
| 4 Fast | 5.00 | 2.43 (49%) | 1 of 1,726 (0.06%) | 7.5, 10.1 ms | 4.71 (94%) | 0 of 892 | 4.0 ms |
| 5 Fastest | 24.00 | 2.22 (9%) | 2 of 1,888 (0.11%) | 7.5, 9.2 ms | 5.02 (21%) | 0 of 837 | 4.0 ms |

Inline, half the frames run the simulation for its whole room (the median frame is 7.33 ms), and a
game day is about 50 pieces (about 1,800 yields in the 35 days at Normal), a month's end's units
several hundred. In the thread runs the frames with no simulation, while it loaded and while it ran
were 4.0 ms, and the render thread's longest wait for the published state was 0.001 ms.

**180 days** (six months' ends), at Normal:

| mode | days a second (asked) | frames over 8.33 ms | p99, worst | ticks behind: p99, most |
|---|---:|---:|---:|---:|
| inline | 2.60 (2.67, 97%) | 17 of 8,303 (0.20%) | 7.6, 17.3 ms | 161, 167 |
| thread | 2.64 (2.67, 99%) | 0 of 8,179 | 4.0, 4.0 ms | 31, 39 |
| thread, Fast | 4.91 (5.00, 98%) | 0 of 4,404 | 4.0, 4.0 ms | 95, 101 |

The first 35 days cost more a day than the months after them (the load's first exploration pass, the
first month's end, the first compilation of every script block), so the pace over 180 days is the
better measure: inline keeps Normal's over 180 days, but not over the first 35.

**The test** at its defaults (Normal, 35 days): both cases pass; inline none of 2,192 frames over
8.33 ms (the worst 8.1 ms, the 99th percentile 7.47 ms, 1.92 game days a second), on the thread none
(2.66 game days a second); 52 s for both. An earlier run of it had 1 frame of 2,069 over (9.3 ms):
the pace inline varies from 1.9 to 2.2 days a second from run to run, as the collector's work does.

**The margin.** At 0.5 ms (3.83 ms of room) the same 35 days have 9 to 17 frames over 8.33 ms (0.5
to 0.8%), most of them by under half a millisecond: a stretch between two checks a little longer
than the margin, begun just before the deadline. At 1 ms they are 1 to 5 (0.05 to 0.25% over
several runs), and the game runs about 10% slower inline.

## 5. What it shows

**Inline works when the phases can be cut, and they can.** Before them, the units ran whole: a game
day was about 15 units of 2 to 35 ms on average and a month's end three more of a third of a second
to a second, against 3.83 ms of room, and 4 to 36% of the frames were over 8.33 ms at every speed,
the worst by most of a second (the previous version of this page). Cut at several hundred places in
the engine and the script layer, and with the load doing what the first day did once, a frame's
piece ends within its room nearly always. What is left over the time are single stretches between two
checks that run past the frame's end: 1 to 5 in 35 days, 17 in 180, each a different place
(section 6).

**Inline, the frames set the pace.** 120 frames of 3.33 ms are 0.4 s of simulation a second. The
first 35 days ask about 0.21 s a game day (with the load's first pass and the month's end), so
Normal (2.67 days a second, 0.56 s) runs at 82%; over 180 days a day costs less and Normal keeps its
pace. Fast and Fastest run as fast as the room lets them, 2.2 to 2.4 days a second. A game whose
simulation needs more than the frames leave slows down, as the game itself does late in a game.

**On its own thread the simulation keeps the frames and, up to Fast, the pace.** The frames are
untouched (4.0 ms, the render work), and the game runs at the speed asked up to Fast over 180 days.
What limits it is the simulation's own speed, about 5 game days a second on this machine: Fastest
asks for 24 at 120 FPS.

**The pieces change nothing.** The 180-day check against the headless game's save gives the same
counts after every change here (723,928 fields equal, 12,466 differ, 4,723,614 draws). A 35-day run
cut into pieces (about 1,800 yields) ends with the same save as one run whole, byte for byte, or
with one value different, a country's alloys stockpile, `148.21831` in one and `148.21832` in the
other: two whole runs of the same build differ in that value as well. The engine adds some doubles
in an order that changes from run to run (where is not found yet: a `pairs` over a table whose
order follows addresses, or LuaJIT's string hash seed, would do it); it is the engine's own
difference, not the pieces'.

## 6. What is left over the time

The stretches that crossed a frame's end in the 180-day run (`STELLAR_SLICE_TRACE=1`), and in the
35-day runs before the last changes: each a single stretch between two checks, most of them once.

- A compiled trigger or scripted trigger whose body is long and has no iterator (the AI's budget
  `potential`s, a research option's `potential`, an event's mean time to happen): 2 to 10 ms, a few
  times in 180 days. The compiled blocks of three statements or fewer have no tick of their own.
- A stretch that allocates much, where the collector's steps fall due (the AI strategy's entries
  written, 7 ms twice), and the collector's atomic step, 2.1 to 2.6 ms, once a cycle (about once in
  35 days of this game).
- One object's work between two of its loop's checks: a ship component's economic unit in a month's
  budget (9 ms twice), a colony's daily values (12 ms once), a block's first compilation.

Cutting them is the same work again at each place. What it does not reach is a single call that
cannot yield: a `table.sort` with a Lua comparator, a C function, the collector's step.

## 7. Not done

- **The renderer's thread.** `sim/render/src/clock.rs` runs whole days and publishes a snapshot of
  the galaxy after each, on the simulation's thread (25 to 70 ms on 10.5.0.24): its cost comes off
  the pace above, and the renderer sees the world move once a game day. The harness does not run
  the renderer's `Clock`; a test of it would sit in the render crate, with its snapshot.
- **A real render load.** The render work is a busy wait on one core. A real frame also uses the
  GPU driver's threads and memory bandwidth, which the simulation competes with; on a machine with
  fewer cores than this one (the 4-core laptop) both modes have to be measured there.
- **Reads between pieces.** Inline, a phase may stop in the middle: the world is then half way
  through it. Nothing reads it between two pieces here; a renderer that does must read what the
  simulation published at the end of the last day, as the thread's render loop does.
- **One save.** The 2210.01.01 game (55 countries) early in its life; a late game has many times
  the objects, every unit grows with them, and so do the stretches between checks.
