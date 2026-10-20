# Profiling the renderer (sim/render)

Where a frame's time goes, measured the same way each time, before anything is optimised. The
setup is four tools, each switched on by an environment variable and costing nothing when off:
the frame profiler's spans (Rust), the GUI Lua's sampling profiler, perf, and the command
protocol's `bench` with input made each frame. Section 4 is the baseline on 10.5.0.24, section 5
the costs it found, section 6 what was fixed with the numbers before and after, section 7 what is
left.

## In short

- **The UI thread is what to measure.** The window's render thread only draws (docs/render.md
  section 12); the app, its Lua and the scene are built on the UI thread, at most 120 times a
  second. A UI frame that takes 100 ms is a window that answers the mouse 10 times a second,
  whatever the GPU does. Offscreen, `bench` runs the same work on one thread and splits each
  frame into input, update, scene and upload (the CPU's part: the UI thread's work) and the GPU's
  frame.
- **The worst cost was waiting, not working.** With the clock running, every window that reads
  the simulation (the planet view, the fleet windows, the starbase window, the combat check of a
  selected fleet) asked the simulation's thread for its data with a blocking query at every new
  snapshot. The simulation answers between days only, and when it is behind it starts the next
  day at once, so each query waited for a whole day: 0.75 to 2.8 s of every UI frame
  (`running_fleet`: 2,234 ms a frame on average). perf cannot see this (the thread sleeps); the
  spans did.
- **Then relayouts.** Any change of the windows' key laid every window out again, and each
  relayout rebuilt the outliner's view in Lua: 352,341 values, 350,591 of them the tooltips' data
  (`tips`), 40 to 140 ms each. Hovering a star changed the key too.
- **Fixed** (section 6): the windows' queries no longer wait while the clock runs; `tips` is made
  in Lua as it is read; a hovered star relays out its label, not the windows; the old snapshot is
  freed on a thread of its own. Hovering, scrolling and dragging over any window went from 1.4 to 13
  ms a frame on average (p99 up to 174 ms) to 0.25 to 1.5 ms (p99 1.3 to 11 ms); with the clock
  running, from 0.75 to 2.8 s a frame with the planet, fleet or starbase window to 0.3 to 3.5 ms.
  The frames are unchanged: the galaxy, a selected fleet, the planet view and four tooltips are
  byte for byte the same PNGs as before.
- **First openings** (section 8): the first window with a portrait or a ship's view (the council,
  technology, leaders, the empire, the designer) took 0.7 to 1 s, 550 to 610 ms of it the models'
  index (531 files of gfx/models parsed in the map's runtime). It is made with the load now (Fix 5):
  those first openings take 156 to 178 ms (the designer 355 ms and its 200 ms upload), the load
  0.5 to 0.6 s longer, behind the load screen.
- **The GPU of 10.5.0.24.** The baselines and fixes of sections 4 to 6 were measured on lavapipe
  (Vulkan on the CPU, forced in /etc/environment from 2026-10-16 to 2026-10-20): its frames are 35
  to 65 ms at 1280x720 whatever the CPU's part is, and its 24 `llvmpipe` threads hold about 99% of
  the process's CPU samples. The renderers there use the GTX 1080 Ti through NVK again since
  2026-10-20 (section 9): 13 to 18 ms a frame, the CPU's part the same.

## 1. How to profile

Everything runs on 10.5.0.24 (the save in /opt/stellaris-saves, the game's files in /opt/stellaris),
with the worktree's renderer built in release (`debug = 1`: perf has the symbols):

```
cd sim/render && CARGO_TARGET_DIR=/root/target-X cargo build --release
B=/root/target-X/release/stellar-render
P=sim/render/tools/profile
bash $P/scenarios.sh /root/prof/scen                         # menu.txt, map.txt, running.txt
bash $P/run.sh $B /root/prof/runs/map /root/prof/scen/map.txt  # 8 min; the table at the end
python3 $P/summary.py /root/prof/runs/before /root/prof/runs/after   # two runs side by side
```

**The scenarios** (`tools/profile/scenarios.sh`): the 2210.01.01 autosave at 1280x720, loaded as a
running simulation, the galaxy in 3D. `menu.txt`: the main menu, still and hovered. `map.txt`, paused:
the map without a window, then each heavy window (the planet view of the capital, a fleet, the
outliner with a fleet selected, the ship designer, technology, the market, diplomacy's contacts,
the empire view, the fleet manager, a starbase), each 5 s still, hovered, wheeled and dragged.
`running.txt`: the same windows with the clock at Normal, still and hovered. A window's opening
frame is a `bench 1` of its own, apart from the measurements.

**`bench SECONDS [FPS] [INPUT]`** (engine.rs; docs/render.md section 9) draws frames at 120 FPS as
the window does and replies with the frames' times: the CPU's part (input, update, scene, upload)
mean, p50, p99 and max, the GPU's frame, the scenes built, the frames that took a new snapshot.
INPUT is made each frame: `hover X0 Y0 X1 Y1` (the pointer along the line and back in 2 s),
`wheel X Y` (a notch every 4 frames, 8 one way then 8 back), `drag X0 Y0 X1 Y1` (a left drag of
58 frames, again and again).

**The frame profiler** (`src/prof.rs`, `STELLAR_PROF=1`; `prof on|off` in the protocol). A span is
a guard: `let _s = prof::span("scene: galaxy frame");` times its scope, its own time apart from
the spans opened inside it. A frame's end (`prof::frame_end`: each `bench` frame, each period of
the window's UI thread, each frame of its render thread) makes each span's sum a sample of its
cost a frame. `prof report [PATH]` writes every thread's table (calls, calls a frame, total and
self ms, ms a frame, the most in a frame, the longest call) and the Lua samples, then forgets
them; `bench` starts from zero and names the costliest spans in its reply. Off, a span is one
relaxed atomic load. The spans now: `input`, `update` and `update: snapshot sync`; `scene` and
its parts (`scene: selection windows (relayout)`, `scene: system labels`, `scene: overlay items,
tooltip`, `scene: galaxy frame` / `scene: system build`, `scene: insets, trackers`); a relayout's
parts (`windows: names`, `windows: outliner data (to lua)`, `windows: planet, starbase data`,
`windows: outliner + selection (lua)`, `windows: main screen (topbar, bars)`, `windows: fleet
windows`, `windows: events`, `windows: view NAME`, `windows: designer`, `windows: diplomacy, menu,
flags`, `windows: derived textures, fonts`); `upload` and `gpu frame (draw, wait)` in `bench`;
`ui: jobs (input, commands)` and `ui: mip chains` on the window's UI thread; `render: ...` on its
render thread; and every `crate::prof(label, t0)` of before (RENDER_PROFILE=1's lines: the galaxy
frame's parts, each texture's upload).

**The GUI Lua's sampler** (`lua/render/prof.lua`, `STELLAR_LUA_PROF=1`: a sample every
millisecond, `STELLAR_LUA_PROF_DEPTH` the stacks' depth, 8). LuaJIT's `jit.profile` in the UI
thread's runtime (render.windows, render.gui, the names, the tooltips), the samples by function,
by line, by stack and by the VM's state (N compiled, I interpreted, C in C, G the collector, J the
compiler), in `prof report`. `STELLAR_LUA_PROF_RUNTIME=map` samples the map's runtime instead
(portraits, the models' index, the designer's insets). Its limits: one Lua state per process (the
profiler is the process's timer), so the other runtime and the simulation's are not in it; the
timer counts the whole process's CPU, so a tick that came while the state ran no Lua lands on its
next instruction: each callback counts once, not its ticks; and once in about 40 runs the process
spun in the profiler itself (gdb: `lj_dispatch_profile` on the callback's thread, under the
patched LuaJIT's hooks): kill it and run again, and keep it off for long runs. The simulation has
its own (`STELLAR_SLICE_PROFILE`, docs/frame_timing.md).

**perf** (`tools/profile/perf.sh BINARY RUN_DIR SETUP.txt "bench ..." [SECONDS]`): the renderer
serves the protocol, SETUP's commands load and open a window, and perf attaches for SECONDS of the
measurement only (not the load, not the exit, whose freeing of the Lua states looks like a hot
collector). It reports the CPU by thread and the commands' thread's functions. On lavapipe the
threads split the CPU's part from the rasterising: `llvmpipe-N` are the GPU. perf sees CPU time
only: a thread that waits is not in it.

**The window** (`tools/profile/window.sh BINARY RUN_DIR`): the real window under Xvfb (its own
display, :83), `--map --sim`, driven by xdotool (the map hovered paused, then running, then the
technology view), the frame profiler's tables every 5 s (`STELLAR_PROF_EVERY`) on stderr, each
headed by its Unix time, with the steps' times in `marks.txt` (a window closed by hand prints
the tables once more at its end). xdotool's keys need `windowfocus` then a plain `key`.

**GPU timing.** Not wired: on lavapipe the GPU's frame is the CPU's rasterising, measured as the
`gpu frame (draw, wait)` span and in perf as the `llvmpipe` threads. On a real GPU, wgpu's
timestamp queries (TIMESTAMP_QUERY) would split the passes; not done.

## 2. What a frame is made of

The window (docs/render.md section 12): the **UI thread** takes the input as jobs, then once a
period (8.3 ms) while something moves updates the app (the camera, the clock's commands, the newest
snapshot) and builds the scene when something changed (`App::scene`), then makes the mip chains of
the scene's new textures and publishes it. The **render thread** draws the newest scene and
uploads a new one's resources within 4 MB a frame. The **simulation's thread** runs days in 1 ms
slices and publishes a snapshot after each day.

`App::scene` rebuilds the windows only when `overlay_key` changes (the size, the view, the
selection, the snapshot's generation, the GUI shown, paused, the zoom past 400, observing, the
fleet windows' state and, before the fixes, the hovered star) or when it is set to None (a window
opened, closed or its state changed: `relayout`). A hover that changes a button's frame rebuilds
the scene (`self.scene = None`) but reuses the windows' items. A relayout runs, in order: the names
localised, the outliner's data set in Lua (`outliner::install`), the planet view's and starbase's
data, `render.windows.build` (the outliner and the selection's window), the top bar and bars,
the fleet windows, the events, the open view, the designer, diplomacy and the menus, then the
fonts.

## 3. Reading the numbers

- **The CPU's part** is the UI thread's work. Its mean is what a window costs; its p99 and max are
  the hitches. The window draws at 120 FPS while the CPU's part stays under 8.3 ms.
- **The GPU's p50** on 10.5.0.24 is llvmpipe at 1280x720: 35 to 65 ms whatever happens on the CPU
  (2.6 ms for the menu). A real GPU draws these frames in a few ms (docs/render.md section 10).
- **Paused and still**, a frame builds nothing (`scenes built 1`: the first); the CPU's part is
  0.01 ms. Every cost shows when something changes: input, a snapshot, a window's data.
- The runs are repeatable to about ±20% on the means (the hover's path crosses the same stars,
  the clock's days fall at different frames); a fix is counted when it is many times that.

## 4. The baseline (before the fixes)

10.5.0.24 (Ryzen 9 5900X, 24 threads; lavapipe), master at b594752 with the frame profiler, the
2210.01.01 autosave at 1280x720, `run.sh` with the scenarios of section 1. ms a frame, the CPU's
part (the UI thread): mean / p99.

| | still | hover | wheel | drag | GPU p50 |
|---|---:|---:|---:|---:|---:|
| main menu | 0.00 / 0.01 | 0.01 / 0.28 | | | 2.6 |
| map, no window | 0.01 / 0.01 | 0.13 / 1.2 | 2.0 / 59 | 11.5 / 101 | 58 |
| planet view | 0.01 / 0.02 | 9.6 / 122 | 2.0 / 38 | 9.1 / 132 | 37 |
| fleet view | 0.01 / 0.02 | 8.2 / 143 | 1.8 / 41 | 8.8 / 84 | 48 |
| outliner, a fleet selected | 0.01 / 0.01 | 3.9 / 43 | 1.7 / 39 | 9.6 / 124 | 49 |
| ship designer | 0.01 / 0.01 | 2.9 / 39 | 2.2 / 78 | 1.4 / 2.1 | 51 |
| technology | 0.01 / 0.01 | 10.5 / 109 | 2.4 / 61 | 10.1 / 171 | 35 |
| market | 0.01 / 0.01 | 3.6 / 39 | 1.8 / 38 | 12.5 / 174 | 49 |
| diplomacy (contacts) | 0.01 / 0.02 | 10.5 / 102 | 2.7 / 4.5 | 7.8 / 54 | 36 |
| empire | 0.01 / 0.01 | 12.9 / 134 | 1.8 / 39 | 12.0 / 142 | 36 |
| fleet manager | 0.01 / 0.01 | 0.45 / 1.5 | 2.8 / 59 | 6.4 / 62 | 60 |
| starbase | 0.01 / 0.01 | 10.9 / 113 | 5.1 / 152 | 5.9 / 54 | 37 |

The clock running at Normal (8 s still, 5 s hovered):

| window | still: mean / p99 | hover: mean / p99 |
|---|---:|---:|
| map, no window | 3.5 / 70 | 4.3 / 64 |
| planet view | **1,247 / 1,930** | **882 / 1,345** |
| fleet view | **2,234 / 3,862** | **2,848 / 3,526** |
| starbase | **747 / 960** | **833 / 923** |
| ship designer | 4.5 / 115 | 13.7 / 135 |
| technology | 2.9 / 58 | 3.8 / 69 |
| market | 1.8 / 68 | 3.2 / 78 |
| diplomacy | 2.6 / 77 | 2.8 / 58 |
| empire | 2.8 / 53 | 5.6 / 94 |
| fleet manager | 6.1 / 184 | 1.0 / 4.0 |

A window's first opening (its `bench 1`: the layout, the textures decoded, the upload): the designer
902 ms (and 182 ms of upload), technology 294 ms (735 ms when it is the first window with
portraits: section 5), the fleet view 168 ms, a fleet selected 194 ms, empire 69 ms, diplomacy 47
ms, the market 42 ms; closing any of them 36 to 70 ms (a relayout).

## 5. Where the time went

**1. Blocking queries to the simulation while it runs: 0.75 to 2.8 s a frame.** `running_planet`'s
spans: `windows: planet, starbase data` 1,031 ms a frame, all of it `planet::data`'s
`Clock::query`. The fleet view: `windows: fleet windows` (fleetwin.rs `fleet_items`, the fleet's
data) and the relayout's own time (`designer::in_combat`, asked of every selected fleet,
stations included: the starbase window's 680 ms). `Clock::query` sends Lua to the simulation's
thread and waits; the thread reads its commands between days only (clock.rs `Worker::run`), and
with the simulation behind its speed (in slices it runs about 2 days a second where Normal asks
2.67) the next day starts at once. So the snapshot comes, the windows are laid out for it, the
query goes out and waits for the whole next day; by the answer another snapshot is there. The
UI thread spent nearly all its time waiting. perf shows nothing of it (the thread sleeps in
`recv_timeout`).

**2. The outliner's view rebuilt in Lua at each relayout: 40 to 140 ms.** `windows: outliner data
(to lua)` (before the split, `windows: names, outliner data`): 46 ms a relayout on average in
`planet_hover`, at most 137. `outliner::install` turned the snapshot's `outliner_view` (a
`LuaData` tree) into Lua tables value by value through mlua. Its size in the 2210 save:

| `outliner_view` field | values |
|---|---:|
| `tips` (render.tooltip_data: every ship's and fleet's tooltip data, the economy's breakdowns) | 350,591 |
| `countries` | 869 |
| `groups` | 441 |
| `members` | 343 |
| `alerts`, `sectors`, `badges`, `tab_items`, `player` | 87 |

The layout reads a few dozen of `tips` (each visible row's tooltip, `outliner.lua` `row_tip`), the
tooltips a few more, always by key.

**3. Relayouts that did not need to happen.** The windows' key had the hovered star in it
(mapicons.rs: the label's hover marker), so moving the pointer over the galaxy laid every window out
again at each star: 19 relayouts in 5 s of `planet_hover`, 18 in 5 s of `market_drag`. The labels
are made apart and are cheap (`scene: system labels` 0.1 to 3 ms).

**4. The old snapshot freed on the UI thread: about 10 ms a day.** After fix 2 the outliner's
install still took 10 to 12 ms at each new snapshot, against 0.3 ms paused: replacing the view it
keeps freed the previous day's 352,000-value tree there (and `Map::sync` the previous galaxy). The
window's run showed the same: `update: snapshot sync` up to 47 ms.

**5. First openings.** The designer's first open, about 1.07 s of scene (its models and insets)
and 182 ms of upload; the technology view's, 652 ms in `scene: insets, trackers`, the
scientists' portraits (portraits.rs: the portrait files parsed in the map's runtime) when no window
with portraits was open before; the fleet view's, 160 ms. Once a session each.

**6. lavapipe.** perf of 8 s of `planet_hover` (`perf.sh`): the 24 `llvmpipe` threads about 99% of
the process's samples, the simulation's thread none (paused), the commands' thread under 1%;
of that thread's own samples, 37% are lavapipe's command recording (`libvulkan_lvp.so`), 28 to 33%
the kernel (futexes, munmap of lavapipe's buffers), 19 to 25% libc (memmove: lavapipe's copies),
3% the renderer's code, 5 to 8% JIT code (LuaJIT's traces and llvmpipe's shaders alike). Its GPU
frames are 35 to 65 ms; nothing in the renderer changes that.

What was not a cost: the galaxy scene's build (`frame: scene build` 0.5 to 1 ms), the top bar
(`frame: topbar` 0.05 ms, cached), `worldgfx::read` (0.05 ms), the overlay items' clone and the
tooltips (`scene: overlay items, tooltip` under 1 ms), input (0.1 ms), the windows' own Lua
(`windows: outliner + selection (lua)` 2 to 8 ms a relayout, the open view 1 to 13 ms).

## 6. The fixes, one at a time

Each measured with the scenarios of section 1, the build before against the build with it.

**Fix 1: the windows' queries do not wait while the clock runs** (`Clock::query_view`, clock.rs).
The read-only queries a layout makes (planet.rs `data`, fleetwin.rs `fleet_view_query`,
designer.rs `world_view`: `in_combat`, the combat view's data, the designer's stage model) go
through it with the snapshot's generation. Paused, it waits as `query` did, and keeps the answer
for the generation (planet.rs's own cache of one answer is gone). Running, it serves the code's last
answer and asks for a new one; `Clock::answers_arrived`, polled in `App::advance`, lays the windows
out again when it comes. A window is then at most about a day behind, as the game's windows update
on their own cadence. Commands go through `query` as before, which marks every kept answer as old
(`forget_views`): paused, the next layout waits for fresh data; running, it shows the last until
the new one comes. A code's first answer is still waited for.

| clock running (CPU ms a frame, mean / p99) | before | after |
|---|---:|---:|
| planet view | 1,247 / 1,930 | 3.3 / 80 |
| planet view, hovered | 882 / 1,345 | 5.0 / 98 |
| fleet view | 2,234 / 3,862 | 3.2 / 81 |
| fleet view, hovered | 2,848 / 3,526 | 5.3 / 141 |
| starbase | 747 / 960 | 3.1 / 76 |
| starbase, hovered | 833 / 923 | 4.8 / 98 |

**Fix 2: the outliner's `tips` made in Lua as they are read** (outliner.rs `install`, `LAZY_TIPS`).
The view's other fields (2,000 values) are made as before; `tips` is a table whose fields are
fetched from the Rust copy on first read, two levels deep (`tips.fleets[3]` makes that fleet's
table alone: `RENDER_TIPS_GET`). The snapshot's `outliner_view` is an `Arc` now, kept for the
tooltips without a copy. Paused, ms a frame, mean / p99:

| | before | after |
|---|---:|---:|
| planet view, hovered | 10.1 / 108 | 0.69 / 6.6 |
| fleet view, dragged | 11.5 / 110 | 0.59 / 6.9 |
| technology, hovered | 10.1 / 82 | 0.92 / 8.8 |
| market, hovered | 11.7 / 179 | 0.57 / 8.5 |
| diplomacy, hovered | 12.4 / 210 | 0.70 / 7.8 |
| empire, dragged | 12.7 / 218 | 2.1 / 21 |

(A relayout's `windows: outliner data (to lua)`: 46 ms on average, 137 at most, to 0.3 to 0.4 ms.)

**Fix 3: a hovered star relays out the labels, not the windows** (app.rs `scene`): when the
windows' key differs from the last only in the hovered star, the windows' items are kept and the
labels made again.

| paused, ms a frame, mean / p99 | before | after |
|---|---:|---:|
| planet view, hovered | 0.69 / 6.6 | 0.36 / 1.75 |
| fleet view, hovered | 1.95 / 20.2 | 0.25 / 1.35 |
| technology, hovered | 0.92 / 8.8 | 0.58 / 1.37 |
| empire, dragged | 2.06 / 20.7 | 0.36 / 2.54 |
| map, dragged | 0.64 / 5.7 | 0.29 / 1.83 |

**Fix 4: the old snapshot freed on a thread of its own** (main.rs `drop_later`, a `drop` thread):
`Map::sync`'s previous galaxy and snapshot, and the outliner's previous view. The clock running, a
snapshot's relayout: `windows: outliner data (to lua)` 10 to 13 ms to 0.3 to 0.7 ms,
`update: snapshot sync` at most 1.7 to 0.25 ms; the frames that take a snapshot:

| clock running, ms a frame, mean / p99 | before | after |
|---|---:|---:|
| map, no window | 0.80 / 18.3 | 0.38 / 9.3 |
| planet view | 0.77 / 18.1 | 0.56 / 11.3 |
| technology | 0.69 / 21.3 | 0.48 / 12.4 |

**All four, against the baseline** (paused: `map.txt`; the clock running: `running.txt`), ms a
frame, mean / p99:

| | before | after |
|---|---:|---:|
| map, dragged | 11.5 / 101 | 0.29 / 1.8 |
| planet view, hovered | 9.6 / 122 | 0.36 / 1.75 |
| fleet view, hovered | 8.2 / 143 | 0.25 / 1.35 |
| designer, wheeled | 2.2 / 78 | 0.49 / 6.6 |
| technology, dragged | 10.1 / 171 | 0.32 / 1.9 |
| market, dragged | 12.5 / 174 | 0.32 / 2.1 |
| diplomacy, hovered | 10.5 / 102 | 0.25 / 2.5 |
| empire, hovered | 12.9 / 134 | 0.70 / 2.0 |
| fleet manager, dragged | 6.4 / 62 | 0.61 / 1.6 |
| starbase, hovered | 10.9 / 113 | 0.49 / 1.8 |
| starbase, wheeled | 5.1 / 152 | 0.76 / 10.9 |
| running: map | 3.5 / 70 | 0.32 / 10.1 |
| running: planet view | 1,247 / 1,930 | 0.34 / 9.6 |
| running: fleet view | 2,234 / 3,862 | 0.47 / 13.9 |
| running: starbase | 747 / 960 | 1.6 / 30 |
| running: designer, hovered | 13.7 / 135 | 1.8 / 9.7 |
| running: empire, hovered | 5.6 / 94 | 1.3 / 3.0 |

Closing a window (a relayout) went from 36 to 70 ms to about 5 ms. The window's run under Xvfb
(`window.sh`: the home system, then the clock running, then the technology view hovered) agrees: a
relayout's `windows: outliner data (to lua)` took up to 150 ms before and 0.55 ms after, and
`update: snapshot sync` up to 47 ms before and 0.01 ms after.

**The pictures are the same.** The galaxy, a selected fleet, the planet view and four tooltips (a
fleet's and a ship's from the outliner, the energy's and the navy's from the top bar: `tips`) taken
by master and by the fixed build are the same PNGs, byte for byte. `cargo test` passes in sim and
in sim/render (with a test of the lazy `tips` and one of the spans).

## 7. What is left

- **A first answer is waited for.** Opening the planet, fleet or starbase window while the clock
  runs still waits for the simulation's day once (1.7 s in `running_fleet`'s opening frame). A
  window could open with its frame and fill in when the answer comes, as it does while the
  simulation loads.
- **First openings** after Fix 5 (section 8): each window's own definitions, parsed once in its
  module's cache on first use: the fleet windows' leader traits 140 ms, species 123 ms, the council,
  technology and leaders views 50 to 90 ms, the portraits 100 ms, the designer's ships 255 ms and
  their 2048x2048 textures' upload 200 ms.
- **A relayout is still 5 to 10 ms** of windows' Lua (the planet view about 5 ms, the labels 3, the
  top bar 2.7) at every snapshot and window change, and the technology view's own layout 16 ms on
  average and up to 56 (the window's run): within a frame or two, not within 8.3 ms with the
  frame's other work at the fastest speeds.
- **The wheel over the map** crosses the zoom's 400 (the key's `distance <= 400`) and relays out
  the windows (p99 8 ms): whether the windows depend on it was not checked.
- **`Map::sync`'s textures**: a day that changes owners re-adds the map's four textures
  (`textures.add`) on the UI thread.
- **The designer hovered** rebuilds the scene at each hover (82 scenes in 5 s, 1.5 ms a frame):
  cheap, but the only window that does.
- **GPU timestamps** on a real GPU (section 1), and these runs on the Windows laptop (its CPU has a
  third of these cores; the slices and the UI thread compete there).

## 8. First openings

Measured each in a process of its own (`tools/profile/first_open.sh`: the save loaded, the galaxy shown, paused, then the window
opened once: `prof reset`, the command, `prof report`, `bench 2`, `prof report`), so that no window
opened before has made what it needs. The first frame's scene and upload, ms, before Fix 5:

| window | first frame | of which |
|---|---:|---|
| designer | 1,096 | the models' index 610, the designer's ships 255, its layout 97, upload 197 |
| council | 794 | the models' index (in `scene: insets, trackers` 679), the view 87 |
| technology | 794 | the models' index 575, the portraits 101, the view 65 |
| leaders | 751 | the models' index (in 656), the view 66 |
| empire | 720 | the models' index (in 651), the view 48 |
| fleet manager | 164 | the view 141 (leader traits parsed: `source.lua:expand`) |
| a fleet selected, the fleet view | 156, 157 | `windows: fleet windows` 141 (`fleet.lua:traits`) |
| species | 143 | the view 123 (`empire_common.defs`: the species' and governments' files parsed) |
| traditions, planet, situation, discoveries, diplomacy, market, expansion planner, starbase, claims | 12 to 43 | |

**The models' index.** render.models.load parses gfx/models (531 files, 7,953 entities, 2,821
pdxmeshes) with the Lua pdxscript lexer: 0.3 to 0.6 s, about half the samples the lexer
(`pdxscript.lua:lex`) and 39% the collector (`STELLAR_LUA_PROF_RUNTIME=map`). The simulation's
thread makes its own for the systems' ships; the map's runtime (galaxy::files_runtime, made anew
with the map) made its own when a scene first needed a model: the first window with a portrait or
a ship's view, or the first system view.

**Fix 5: the models' index made with the load** (`Map::warm`, main.rs): behind the load screen
(App::loading_step, before DestroyLoadScreen: the window's Load, Continue and new games), in
`App::load_as` (the protocol's `load` and `load-sim`, `--map`), and where `Map::sync` makes the
map's runtime anew. The first frame, ms (scene, then upload):

| window | load-sim: before | after | the load screen's flow: before | after |
|---|---:|---:|---:|---:|
| technology | 726 + 4 | 169 + 4 | 767 + 4 | 202 + 4 |
| council | 742 + 13 | 175 + 13 | 784 + 13 | 174 + 13 |
| leaders | 717 + 15 | 178 + 15 | 769 + 15 | 160 + 15 |
| empire | 720 + 9 | 156 + 9 | 763 + 9 | 161 + 9 |
| designer | 921 + 196 | 355 + 199 | 946 + 197 | 361 + 204 |

The load takes 0.5 to 0.6 s more (`load-sim` 6.1 s to 6.7 s, `loaded` 6.1 s to 6.6 s). What is
left of the first openings is in section 7.

## 9. On the GTX 1080 Ti (NVK)

From 2026-10-16 to 2026-10-20 /etc/environment on 10.5.0.24 forced lavapipe
(`VK_DRIVER_FILES=.../lvp_icd.json`, after memory corruption seen under nouveau and NVK); it is
removed (the file before is /etc/environment.lavapipe-2026-10-16), and the renderer picks the GTX
1080 Ti through NVK (Mesa 26.0.8, nouveau without reclocking on Pascal: its boot clocks). The
fixed build's scenarios there (no kernel messages from nouveau through them), ms a frame, the CPU's
part mean / p99 and the GPU's p50:

| | CPU | GPU (lavapipe before) |
|---|---:|---:|
| main menu | 0.00 / 0.01 | 1.3 (2.6) |
| map, hovered | 0.14 / 1.4 | 18.7 (58) |
| planet view, hovered | 0.28 / 1.9 | 14.2 (36) |
| technology, hovered | 0.44 / 2.1 | 17.1 (35) |
| empire, hovered | 0.38 / 1.9 | 14.2 (50) |
| running: map | 0.16 / 7.7 | 18.0 (62) |
| running: planet view | 0.18 / 8.0 | 18.9 (65) |

The GPU's frames at the card's boot clocks are over 8.33 ms at 1280x720; the CPU's part fits.
