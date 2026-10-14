# Frame timing: the simulation inside a rendered game (sim/)

The simulation has to run inside a game that renders. At 120 frames a second a frame is 8.33 ms,
and the simulation's work must fit around the frames in one of two ways:

- **inline**: on the render thread, in what each frame leaves after its render work;
- **on a thread of its own**: the render thread only reads what the simulation publishes, and its
  frames must not be slowed by it.

Either way the game's clock must keep its pace at the chosen speed. `sim/src/frametime.rs` runs the
simulation from a save in a 120 FPS frame loop in each of the two ways and measures the frames, the
pace and the phases; `examples/frametime.rs` prints the whole report, `tests/frame_timing.rs` is the
pass or fail check.

## In short

- **The frame loop**: the render thread draws 120 frames a second (4 ms of render work by default, a
  busy wait) and is the game's clock: two ticks every `gGameSpeedTurnTimes[speed]`, as
  `CInGameIdler::CheckTick` posts them. The simulation runs the ticks posted, a phase at a time
  (`Simulation::step`, new: `tick` runs the same phases in the same order, and the 180-day check
  is unchanged).
- **Inline does not fit, at any speed** (10.5.0.24, 35 days from 2210.01.01): 4 to 36% of the
  frames are over 8.33 ms, the worst by half a second to most of a second, and above Slow the
  game falls behind. 15 of the 21 phases that run are longer than the 3.83 ms a frame leaves;
  the monthly ones are 35 to 250 times longer. Inline needs every phase cut into resumable pieces
  of a few milliseconds.
- **On its own thread it fits**: no frame is slowed (4.0 ms, the render work, in every run) and the
  render thread waits about a microsecond for what it reads. The game keeps its pace at Slowest,
  Slow and Normal, and at Fast over 180 days (96%; 86% over the first 35); at Fastest it runs at
  21%: the simulation's own speed, about 4.8 game days a second here over 180 days, is the limit.
- **The check**: `cargo test --release --test frame_timing -- --ignored` fails the inline case
  and passes the thread case at Normal (section 2); `examples/frametime` prints the report at
  every speed.

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

**Units.** The simulation's work is cut where it can be cut: `Simulation::step` runs one unit of a
tick, a phase (`MicroUpdate`, `ProcessAI`, each phase of `DailyUpdate`, `MonthlyUpdate` and
`YearlyUpdate`: `sim/src/scheduler.rs`), and the next step goes on with the same tick. A phase is
one call into the Lua engine with its barrier, and cannot be cut shorter from outside it.
`Simulation::tick` runs the same units in the same order: the 180-day check from 2210.01.01
against the headless game's 2210.07.01 (`examples/diff`) gives the same counts with and without the
change (723,928 fields equal, 12,466 differ, 4,723,614 draws), and a 35-day run's save is byte for
byte the one master's build writes.

**Inline** (`frametime::run_inline`): after the render work, units run while the next one fits the
time left to the frame's deadline less a margin (0.5 ms), by a running estimate of its time (a
quarter of the newest call). A unit that does not fit waits for the next frame. A unit whose
estimate is longer than a whole frame's room (8.33 - 4 - 0.5 = 3.83 ms by default) would never fit:
it runs first in a frame, which it overruns. The run fits when no frame is over 8.33 ms.

**On a thread** (`frametime::run_threaded`): the simulation is made on its own thread (a Lua state
stays on the thread that made it) and runs the ticks the render thread's clock posts, a unit at a
time, sleeping when none is posted; after each day it publishes the date under a mutex, which the
render thread reads every frame. The render thread first draws 3 s of frames with no simulation
(the baseline), then frames while the thread loads the save (the game paused), then frames while it
runs. The run fits when the 99th percentile of its frames is within 8.33 ms and at most one frame in
a thousand is over (the OS's own hiccups: the baseline shows whether there are any).

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
| `STELLAR_FRAME_MARGIN_MS` | 0.5 | inline: left free at the end of a frame |
| `STELLAR_FRAME_BASELINE_S` | 3 | thread: seconds of frames with no simulation first |
| `STELLAR_FRAME_MODE` | both | the example: `inline`, `thread` or `both` |
| `STELLAR_FRAME_SAVE_DIR` | | writes each run's end as `<mode>-speed<N>.gamestate` there |

The test's two cases, `inline_in_what_each_frame_leaves` and `on_a_thread_of_its_own`, fail with
what did not fit: the frames over 8.33 ms and the worst, the units longer than a frame's room
(inline), and the game days a second against the speed's. They are ignored by default: they take a
load and the days in real time, and they measure the machine as much as the simulation.

## 3. Results on 10.5.0.24

Ryzen 9 5900X (12 cores, 24 threads), Linux, quiet (load under 1), 2026-10-14. 35 days from the
2210.01.01 autosave (the month's end on 2210.02.01), 120 FPS, 4 ms of render work; every run from its
own load of the save; `examples/frametime` with `STELLAR_FRAME_SPEED=all`.

| speed | days a second asked | inline: days a second | inline: frames over 8.33 ms | inline: worst frame | thread: days a second | thread: frames over 8.33 ms | thread: worst frame |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 Slowest | 0.67 | 0.67 | 250 of 5,610 (4.5%) | 495 ms | 0.67 | 0 of 6,303 | 4.9 ms |
| 2 Slow | 1.33 | 1.33 | 228 of 2,467 (9.2%) | 823 ms | 1.33 | 0 of 3,153 | 4.0 ms |
| 3 Normal | 2.67 | 2.52 (94%) | 266 of 994 (26.8%) | 717 ms | 2.61 (98%) | 0 of 1,610 | 4.0 ms |
| 4 Fast | 5.00 | 3.16 (63%) | 230 of 690 (33.3%) | 713 ms | 4.30 (86%) | 0 of 978 | 4.0 ms |
| 5 Fastest | 24.00 | 3.08 (13%) | 240 of 659 (36.4%) | 768 ms | 4.92 (21%) | 0 of 854 | 4.0 ms |

In the thread runs the frames with no simulation and the frames while it loaded were 4.0 ms at
most, as were nearly all the frames while it ran, and the render thread's longest wait for the
published state was 0.001 ms.

**The units** (a phase each), in those runs and a first run at Normal: the calls in 35 days, the
mean of a call and the longest call, as ranges over the runs. A frame's room for the simulation is
3.83 ms.

| unit | calls | mean ms | longest ms |
|---|---:|---:|---:|
| `monthly.budget` | 1 | | 380 to 983 |
| `monthly.modifiers` | 1 | | 334 to 811 |
| `monthly.countries_serial` | 1 | | 134 to 724 |
| `daily.countries_parallel` | 35 | 31 to 38 | 423 to 599 (the first: exploration's load pass, docs/data_layer.md) |
| `ai.process` | 35 | 29 to 36 | 79 to 123 |
| `daily.countries_serial` | 35 | 15 to 24 | 60 to 147 |
| `daily.pop_groups` | 35 | 8 to 9 | 65 to 68 |
| `daily.ships_fleets_armies` | 35 | 8 to 9 | 29 to 52 |
| `micro.update` | 350 | 2.2 to 4.1 | 35 to 57 |
| `daily.construction_manager` | 35 | 3.5 to 3.8 | 39 to 43 |
| `monthly.colonies` | 1 | | 24 to 35 |
| `daily.script_state_expiry` | 35 | 6 to 7 | 23 to 27 |
| `daily.ai_attitudes` | 35 | 6 to 7 | 24 |
| `daily.colonies_parallel` | 35 | 4 | 11 |
| `monthly.on_monthly_pulse` | 1 | | 7 to 14 |
| `daily.galaxy` | 35 | 2 | 3 to 4 |

15 of the 21 units that ran are longer than the room at least once; the others are `daily.galaxy`,
the day's random pool, and the phases nothing models yet (`daily.modifiers_1`, `modifiers_2`,
`leaders`). The monthly units are 35 to 250 times the room. The same phase varies by up to two to
three times from run to run (`monthly.budget` 380 against 983 ms): the Lua collector's steps are
paid by whatever allocates when a cycle comes.

**Longer, and the best case for inline.** On the thread over 180 days (six months' ends):

| speed | days a second (asked) | frames over 8.33 ms | worst frame | ticks behind: p99, most |
|---|---:|---:|---:|---:|
| 3 Normal | 2.64 (2.67, 99%) | 0 of 8,184 | 6.0 ms | 35, 49 |
| 4 Fast | 4.80 (5.00, 96%) | 0 of 4,501 | 4.1 ms | 81, 91 |

Fast keeps its pace over 180 days where the 35 days did not (86%): the 35 days carry the load's
first exploration pass and a month's end over fewer days. Inline with no render work at all
(`STELLAR_FRAME_RENDER_MS=0`: 7.83 ms of room a frame), at Normal, 35 days: the pace kept (2.59 days
a second, 97%), but 142 of 1,069 frames over 8.33 ms (13.3%), the worst 859 ms, and the same 15
units longer than the room.

**The test** at its defaults (Normal, 35 days): `inline_in_what_each_frame_leaves` fails (250 of
966 frames over 8.33 ms, the worst 1,194 ms, the 15 units listed, 2.42 game days a second of the
2.67 asked), `on_a_thread_of_its_own` passes; 46 s for both.

## 4. What it shows

**Inline does not work with the engine as it is, at any speed.** The scheduling is not the
problem: the units are. A game day is about 15 units of 2 to 35 ms on average (150 to 250 ms in all)
and a month's end three more of a third of a second to a second, while a frame leaves 3.83 ms.
Every day overruns about seven frames whatever the speed (228 to 266 frames over 8.33 ms in 35
days at each speed), the worst by most of a second. At Normal and above the room is also too small
in total: 120 frames of 3.83 ms are 0.46 s of simulation a second, and Normal asks for 2.67 days of
150 to 250 ms. Inline would need every phase cut into resumable pieces of a few milliseconds (each
system yielding inside its loops over countries, colonies, pop groups and fleets), and the monthly
phases into hundreds of pieces.

**On its own thread the simulation keeps the frames and, up to Fast, the pace.** The frames are
untouched (4.0 ms, the render work), the render thread waits about a microsecond for the published
state, and the game runs at the speed asked for at Slowest, Slow and Normal, and at Fast over 180
days (96%). A month's end leaves the thread three to nine game days behind (about 45 ticks at
Normal, 90 at Fast), which it makes up during the month. What limits it is the simulation's own
speed, about 4.8 game days a second over 180 days on this machine (about 210 ms a day with the
months' ends): Fast asks for 5, with little to spare, and Fastest for 24 at 120 FPS, five times
more: the parallel phases on the workers of docs/data_layer.md and the monthly phases' own costs
(docs/modifier_incremental.md).

**Stepping changes nothing.** The two modes run the same units in the same order; their ends are
the same save but for one value, a country's alloys stockpile, `148.21831` in one and `148.21832`
in the other (and alike at Slow and Fast). Two whole-tick runs of the same build differ in that
value as well, one of them byte for byte the run of master's build: the engine adds some doubles
in an order that changes from run to run (where is not found yet; a `pairs` over a table keyed by
objects, whose order follows their addresses, would do it). It is the engine's own difference, not
the frames'.

## 5. Not done

- **The renderer's thread.** `sim/render/src/clock.rs` runs whole days and publishes a snapshot of
  the galaxy after each, on the simulation's thread (25 to 70 ms on 10.5.0.24): its cost comes off
  the pace above, and the renderer sees the world move once a game day. The harness does not run
  the renderer's `Clock`; a test of it would sit in the render crate, with its snapshot.
- **A real render load.** The render work is a busy wait on one core. A real frame also uses the
  GPU driver's threads and memory bandwidth, which the simulation's thread competes with; on a
  machine with fewer cores than this one (the 4-core laptop) the thread's interference has to be
  measured there.
- **One save, 35 days.** The 2210.01.01 game (55 countries) early in its life; a late game has
  many times the objects, and every unit grows with them.
