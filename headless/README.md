# headless: the real Stellaris 4.5.2 as a simulation oracle

The Linux 4.5.2 build runs on a Linux box under Xvfb (Mesa software GL), loads a save through its
own load path, runs an exact number of ticks through its own tick path with nothing rendered, writes
the gamestate with its own writer, and exits. Runs are deterministic: byte-identical for a year
with `run.sh`'s defaults, and for 5 to 6 years with the settings of the correctness standard
(below). A run reproduces the game's own play session: from `autosave_2210.01.01` the 180-day and
360-day results equal the game's `autosave_2210.07.01` and `autosave_2211.01.01`, except for the
one event the human player answered.

```
headless/run.sh <save.sav> <ticks> <out.gamestate>
# e.g. on 10.5.0.24:
bash /zpool0/share/code_working/stellarstellaris-sim/headless/run.sh \
    /opt/stellaris-saves/autosave_2210.01.01.sav 1798 /tmp/2210.07.01.gamestate
```

About 29 s end to end for 180 days: ~22-24 s to boot and load, ~4 s for the 1,798 ticks, 0.3 s to
write the 20 MB gamestate. Each run has its own HOME, so several can run at once (four in parallel
on the 24-core box were fine).

| file | |
|---|---|
| `headless.c` | the `LD_PRELOAD` driver (C, no dependencies) |
| `run.sh` | one run: save, ticks, output |
| `make_standard.sh` | a correctness standard: a long run with the game's own monthly autosaves |
| `standard.sh` | our simulation against a standard at chosen horizons, or two standards compared |
| `dev/standard_events.py` | what happens in a standard: counts per save, countries and wars appearing |
| `setup.sh` | builds the runtime directory `/opt/stellaris-headless/game` |
| `view.sh` | the game's own frames, driven by commands over TCP or from a script: reference shots for `sim/render` (view mode, below) |
| `dev/gsdiff.sh` | diff two gamestates with the one known noise line masked |
| `dev/callsites.py` | the call-site table for the profiler (by caller, or by callee over a full disassembly) |
| `dev/pcfuncs.py` | a pool-read table's instructions, by function |
| `dev/bg.sh`, `dev/xwd2png.py` | development: a game in the background, screenshots, gdb |
| `results/profile_*.tsv` | random draws per call site (below) |
| `results/ship_pool_*`, `pool_*`, `draw_order_*`, `synced_generator_callers.tsv` | the pools traced (below) |
| `results/standard/` | the standards' manifests, timelines, events, determinism and divergence tables, runner summaries |

## Results

### Times (10.5.0.24, Ryzen 9 5900X, llvmpipe)

| step | time |
|---|---|
| start to main menu (InitGame and the databases: the game's `time.log` says ~20 s) | 18-22 s |
| `LaunchSave` to in game | 3-5 s |
| 1,798 ticks (2210.01.01 to 2210.07.01, ~2,500 ships) | 3.6-4.7 s: 20-26 ms a day |
| 3,598 ticks (to 2211.01.01) | 7.4-7.8 s |
| gamestate written (20.6 MB) | 0.23-0.39 s |

`-threads=1` (needed for determinism, below) costs little: ~22-26 ms a day against ~20.

### Determinism

| runs | differ by |
|---|---|
| two runs of `run.sh` defaults (`-loadrandomseed -threads=1`), 180 days | nothing (byte-identical) |
| three runs `-threads=1`, seed fixed, 180 days | nothing |
| a pair, 360 days, `-threads=1` | one line: one country AI's own `random_count` (masked by `gsdiff.sh`) |
| pairs with the default task threads, seed fixed, 180 days | 4 lines in one pair, 1,568 in another |
| no seed option (the load reseeds from the clock) | 92 lines after 1 day, 11,978 after 180 |

Two things make a run vary, and `run.sh` turns both off:

- A single-player load **reseeds the synchronized generator from the clock**:
  `CFrontEndIdler::SetAsCurrentIdler` sets `CSystem::_nSeed = CProfile::GetCPUTime()` (unless
  `-random=N`) and `_nRandomCount = 0`; after the load `CGameSetup::StartSyncPlayers` posts
  `CSetRandomSeed(_nSeed, _nRandomCount)`, whose `Execute` calls `CRandom::SynchronisedSeed`. The
  save's `random_seed` / `random_count` are only used with `-loadrandomseed` (read in
  `CGameState::ReadMember`); `-rng_seed=N -rng_pos=N` force both in `CGameState::InitPostRead`.
  The user's saves show it: four seeds, one per session (6366252 at 2200.01.11; -386941723 at
  2210.01.01; 64429129 at 2210.07.01, 2211.01.01, 2211.07.01; -324498909 at 2212.01.01 and .07.01).
- With several task threads, the AIs' own generators (`random_seed` / `random_count` inside each
  country's AI block, separate from `synced_random_*`) are drawn in a varying order, and runs drift
  apart. `-threads=1` fixes it in practice. `InitTaskSystem(int)` (`0x4294ea0`) clamps the count to
  [4, the usable threads], so that is 4 threads, against 23 by default on the 24-thread box; one
  AI counter can still differ by a few (it changed nothing else in 360 days), the ordering left
  over.

The generator is `CRandom::_Random`, a `CNoiseRandom { uint32 position; uint32 seed }`: a value is
a hash of (seed, position), so the state is exactly the save's `random_seed` and `random_count`.
The load itself draws 112 values (position = saved + 112 when the game is in hand).

### Against the game's own saves

The 2210.07.01 save comes from a session (seed 64429129) that loaded 2210.01.01 at position 0:
4,755,436 = 112 load draws + 4,755,324 drawn by 1,798 ticks. So the oracle runs it with that seed:

```
HEADLESS_ARGS="-rng_seed=64429129 -rng_pos=0 -threads=1" run.sh autosave_2210.01.01.sav 1798 out
```

| oracle run | compared with | `random_count` | lines that differ (of 1.17 M) |
|---|---|---|---|
| 2210.01.01 + 1,798 ticks | the game's `autosave_2210.07.01` | 4,755,436, equal | 79: the human player's answer (option 0) to event `marauder.3`, still open in our run, and the event ids after it |
| 2210.01.01 + 3,598 ticks | the game's `autosave_2211.01.01` | 9,577,467, equal | 139: player events and their answers only |
| the game's `autosave_2210.07.01` + 1,800 ticks (position put back to the save's) | the game's `autosave_2211.01.01` | 9,576,238 against 9,577,467 | 143,841 |
| our 2210.07.01 output, zipped as a save, + 1,800 | our continuous 3,598-tick run | 9,576,238 against 9,577,467 | 143,818 |
| the game's `autosave_2212.01.01` + 1,800 | the game's `autosave_2212.07.01` | 9,825,577 against 9,825,741 | 41,386 |

So the game is deterministic from a load, and the oracle reproduces the game's own play from a
load (the human's clicks aside). **A reload is not transparent**: loading a mid-session save and
going on is not what the session did. The two 2210.07.01 starts (the game's autosave, our output)
end the same way, so the save is complete enough; the load itself changes the trajectory: on the
first day it draws 6 more values than the continuous run. Writing and reading back changes 21,253
lines with no tick in between, and a 0-tick run of `autosave_2210.01.01` differs from the file by
18,865 lines (ship designs' components written out, `dirty_cloaking_strength=yes`, empty
`factions` blocks...). Compare the Lua simulation with
`run.sh <save> N` from the same save, and use `run.sh <save> 0` as the "just loaded" baseline.

The player's country (0) has a human player: its events wait for an answer that never comes (the
game's own session answered `marauder.3`). That is the one systematic difference above.

### Where the random draws go (per phase)

`HEADLESS_PROFILE=1 run.sh ...` counts the synchronized generator's draws per call site
(`results/profile_*.tsv`, inclusive of everything below the call). 2210.01.01 + 1,798 ticks (179.8
days), seed 64429129: 4,755,324 draws, 26,448 a day.

| phase (call in `HandleTurnTick` / below) | draws | a day | |
|---|---:|---:|---|
| **MicroUpdate** (every tick) | 4,535,761 | 25,227 | 95.4 % |
| - `UpdateShipParallel` -> `CRandom::GetIntegersForMacro(..., count)`: a pool of one value per ship, every tick, before the parallel ship update (~2,522 ships) | 4,534,756 | 25,221 | |
| - `CFleetMovementManager::MicroUpdate` | 482 | 2.7 | |
| - `CFleet::MicroUpdateSerial` | 471 | 2.6 | |
| - `CFleet::PostShipMicroUpdate` | 36 | 0.2 | |
| - `CShip::MicroUpdateSerial` | 16 | 0.1 | |
| **ProcessAI** (tick % 10 == 4) | 0 | 0 | the AI uses its own generators |
| **DailyUpdate** | 210,607 | 1,171 | 4.4 % |
| - the day's pool: 1,000 x `CRandom::GetIntegerForMacro` (site 0x1b1c948) | 180,000 | 1,000 | |
| - `CCountry::DailyUpdateSerial` (countries_serial) | 14,412 | 80 | |
| - `CPlanetManager::DailyUpdate` | 8,134 | 45 | |
| - `CFleet::DailyUpdateSerial` (ships_fleets_armies) | 5,753 | 32 | |
| - `CArchaeologicalSiteManager::DailyUpdate` | 1,800 | 10 | one a site a day |
| - `NColonyUpdate::DailySerialUpdate` (colonies_serial) | 316 | 1.8 | |
| - `CConstructionManager::DailyUpdate` | 75 | 0.4 | |
| - `CPopGroup::DailyUpdateSerial` (pop_groups) | 70 | 0.4 | |
| - `TPdxRef<CCountry>::Kill` 24, `CCountryFocusManager::DailyUpdate` 13, `TPdxRef<CFleet>::Kill` 10 | 47 | 0.3 | |
| - everything else, the parallel phases and `CCountryAI::UpdateAttitudesThreaded` included | 0 | | |
| **MonthlyUpdate** (6 calls) | 8,119 | 1,353 a month | |
| - the month's pool: `CRandom::GetIntegersForMacro` x 1,000 | 6,000 | 1,000 a month | |
| - `CCountry::MonthlyUpdateSerial` | 1,207 | 201 a month | |
| - `NColonyUpdate::MonthlyUpdate` | 906 | 151 a month | |
| - `CRandom::GetIntegerForMacro` (site 0x1b2fc06) | 6 | 1 a month | |
| **YearlyUpdate** (360-day run, 1 call) | 13 | | 1 + 12 `GetIntegerForMacro` |
| commands the session executes between ticks (outside `HandleTurnTick`) | 837 | 4.7 | |
| the load (before the first tick) | 112 | | |

The 360-day run (`profile_2210.01.01_3598.tsv`) has the same shape: 25,410 a day in MicroUpdate,
1,159 in DailyUpdate, 1,346 a month in MonthlyUpdate, 13 in YearlyUpdate, 4.4 a day in commands.
The ~25,200 values a day the Lua simulation does not draw are the per-tick ship pool in
`MicroUpdate`; the rest (~1,220 a day) is the daily pool, the serial country / planet / fleet
updates and the monthly pool.

## Correctness standard

Two 10-year runs of the real game from `autosave_2210.01.01` (2210.01.01 tick 4 to 2220.01.01
tick 4: 36,000 ticks), with every save the game wrote on the way. They live on 10.5.0.24:

| standard | game command line | generator at the first tick | final `random_count` |
|---|---|---|---|
| `/opt/stellaris-headless/standard/2210.01.01/` | `-loadrandomseed -threads=1` | the save's seed -386941723, position 14,059,660 (the save's 14,059,548 + 112 the load draws) | 119,315,458 |
| `/opt/stellaris-headless/standard/2210.01.01-seed20261013/` | `-rng_seed=20261013 -rng_pos=0 -threads=1` | seed 20261013, position **112** (the load draws 112 after `-rng_pos` set 0) | 104,539,977 |

Each directory holds 189 MB:

| file | |
|---|---|
| `autosave_<date>.sav` | the game's own monthly autosaves, exactly as it wrote them: 120 of them, from 2210.02.01 to 2220.01.01, each at tick 2 (like the user's own autosaves); zips with fixed dates, ~1.4 MB each |
| `final_2220.01.01.sav` | the state after the last tick (tick 4): the game's gamestate writer, with the meta of that day's autosave |
| `loaded_2210.01.01.sav` | the input as the game holds it right after the load, 0 ticks |
| `start.gamestate` | the input with `random_seed` / `random_count` set to the generator at the first tick: the `from` file for our simulation |
| `manifest.tsv` | for each file: date, tick, `random_seed`, `random_count`, size, sha256; the first line gives the generator at the first tick |
| `run.log`, `run_loaded.log` | the driver's logs (every autosave, times) |
| `timeline.tsv`, `events.txt` | from `dev/standard_events.py` (below) |

`results/standard/` has copies of the manifests, timelines and events, and every table below.

### How they are made

```
bash headless/make_standard.sh /opt/stellaris-saves/autosave_2210.01.01.sav 36000 <dir>
HEADLESS_ARGS="-rng_seed=N -rng_pos=0 -threads=1" bash headless/make_standard.sh ... <dir>
```

**Autosaves.** `run.sh` writes `autosave=2` (monthly) into the run's `settings.txt`.
`HandleTurnTick` posts a `CAutosave` command when the date passes a month, and its `Execute` only
raises the in-game idler's request flag. The main loop serves that flag after each frame:

1. `CInGameIdler::PostRenderUpdate` calls `AutoSave()`, which names the file
   `autosave_<date>` and starts the save task;
2. `CSaveGameTaskManager::Update(true)` runs at the next frame and writes the save.

The driver makes the same two calls after each session update. Task threads are off for the call,
so the save is written on this thread and is complete when the call returns. It then moves the
file to the standard's directory, because the save task stops writing once a folder holds 100
saves (`CountSaveGames`). `DeleteSaveGameFile` is a no-op, so the autosave rotation deletes
nothing.

Saving changes nothing in the run: 900 ticks with and without autosaves end byte-identical. One
autosave takes 0.35 s.

**Time.** About 6 minutes per standard, and both were built at once:

| step | time |
|---|---:|
| boot and load | 28 s |
| 36,000 ticks | 270 s (75 ms a day, task threads off) |
| 120 autosaves | 42 s |
| the 0-tick run and packaging | about 30 s |

Peak memory is 5.45 GB per game.

**The idle human.** The player's country (0) has a human player and no one at the controls, as in
our simulation. The game answers that player's events itself with their default option: in
`open_player_event_selection_history` they are marked `human=-1`, while clicked answers are
`human=1`.

- In standard A, 117 events were resolved this way in 10 years (selections went from 74 to 191).
- At most 3 events were open at any month.
- Nothing piles up, and the game never stops or pauses.

There were no crashes in any of the runs.

### Determinism

Run-to-run determinism decides how far a standard can be trusted. I built each standard twice in
full (`standard_checks/repeat_a`, `repeat_b`) and compared the files month by month. The first two
rows of the table were earlier builds with fewer settings off.

| settings | the two runs |
|---|---|
| `-threads=1` (as `run.sh`) | byte-identical to 2210.11. Then only the AIs' unsynchronized `random_count` lines differ (masked by `gsdiff.sh`). In 2211.08 one AI picks a different research option, and from 2212.02 the state parts (931 lines, then 131,637 at 2220) |
| + task threads off (`HEADLESS_NO_TASK_THREADS=1`) | byte-identical for 3 years. Part at 2214.07 in one pair (pop groups' ethics attraction first) and at 2216.08 in the other (focus cards and an AI trade-deal offer) |
| + address-space randomization off (`HEADLESS_NO_ASLR=1`): **the standards** | byte-identical for **72 months (A, to 2216.01)** and **64 months (B, to 2215.05)**, the AIs' own counters included. Then they part: an AI's unsynchronized `random_count` and an extra AI trade-deal offer in A; a pop group's growth in B |

So both standards are exact for their first 5 years. After that the game itself varies from run to
run, and the repeats measure by how much (the "run-to-run" columns below).

The remaining cause after year 5 is not found. Task threads and address randomization are both
off, so it comes from the AI's own generator, which something time- or memory-dependent still
moves. `make_standard.sh` turns task threads and address randomization off by default.

### The runner: `standard.sh`

```
bash headless/standard.sh <standard dir> [1m 6m 1y 2y 5y 10y]
bash headless/standard.sh <standard dir> --against <other standard dir> [horizons]
```

For each horizon it runs the sim's `examples/diff` from `start.gamestate` to the game's autosave
at that date, with all horizons in parallel. It writes `summary.tsv` and the full reports to
`/opt/stellaris-headless/standard_results/<name>-<time>/` (or `STANDARD_OUT`). Each row gives:

- fields equal and differing, and % equal;
- the five stores with the most differing fields;
- the sim's random draws against the game's (`random_count` at the horizon minus the first tick's
  position);
- the sim's run time.

`--against` loads one standard's autosave into the sim and compares it with the other standard's
autosave of the same date, with 0 ticks. It uses the same loader and diff, so the numbers are in the
same fields as the sim's.

**The generator start.** `examples/diff` takes the `from` file's `random_seed` and
`random_count`. `start.gamestate` carries the game's real start: the save's seed at the save's
position + 112, or the given seed at 112. `STELLAR_RANDOM=target` (the second file's seed from
position 0) would start 112 draws behind the game, so the runner does not use it. The platform
needs no change. The 112 draws belong to this save's load; each standard's manifest records the
position for its own save.

Sim cost: about 2.4 GB per process. With the 12 horizons of both standards running at once on the
24-core box, the times were:

| horizon | sim time |
|---|---:|
| 1m | 22 s |
| 6m | 150 s |
| 1y | 310 s |
| 2y | 610 s |
| 5y | 1,400 s |
| 10y | 2,400 to 2,600 s |

### Results (2026-10-14, sim at `2948960`)

Our simulation against standard A (`-loadrandomseed`):

| horizon | fields equal | differ | % equal | five worst stores (differ / fields) | draws: sim / game |
|---|---:|---:|---:|---|---:|
| 1m | 733,833 | 5,321 | 99.3 | ships 2,315/110,974, country 1,182/232,859, fleet 1,003/59,431, colony 271/6,487, pop_groups 228/5,498 | 778,614 / 782,863 |
| 6m | 723,316 | 13,320 | 98.2 | country 4,436, fleet 3,361, ships 3,257, colony 581, pop_groups 559 | 4,725,081 / 4,755,744 |
| 1y | 708,693 | 22,132 | 97.0 | country 9,925, ships 4,581, fleet 4,425, pop_groups 762, colony 735 | 9,509,367 / 9,577,199 |
| 2y | 706,086 | 30,520 | 95.9 | country 11,961, ships 6,327, fleet 5,830, pop_groups 1,644, colony 1,264 | 19,217,609 / 19,312,536 |
| 5y | 700,526 | 52,567 | 93.0 | country 23,089, ships 11,104, fleet 7,890, ship_design 1,776, planet 1,751 | 49,323,697 / 49,774,577 |
| 10y | 692,970 | 76,177 | 90.1 | country 39,206, ships 14,064, fleet 9,171, planet 3,278, ship_design 1,940 | 101,355,257 / 105,249,600 |

Against standard B (seed 20261013) the numbers are nearly the same: 99.3, 98.2, 97.0, 95.9, 92.8
and 90.0 % equal.

**In context**, as fields that differ at each horizon (`summary_*.tsv`, `divergence_lines.tsv`):

| horizon | sim vs A | game A vs game B (another seed) | game A vs its repeat | game B vs its repeat |
|---|---:|---:|---:|---:|
| 1m | 5,321 | 418 | 0 | 0 |
| 6m | 13,320 | 4,012 | 0 | 0 |
| 1y | 22,132 | 5,668 | 0 | 0 |
| 2y | 30,520 | 14,630 | 0 | 0 |
| 5y | 52,567 | 37,168 | 0 | 0 |
| 10y | 76,177 | 73,040 | 41,419 | 47,478 |

The sim loads a standard's save and compares it with the same save at 100 %, a check of the loader.
In gamestate lines (`gsdiff.sh`), A and B differ by:

| horizon | lines (of 1.46 M to 1.63 M) |
|---|---:|
| 1m | 996 |
| 6m | 10,458 |
| 1y | 14,088 |
| 2y | 27,555 |
| 5y | 78,457 |
| 10y | 246,061 |

So in the first years our simulation is far outside the spread another seed causes: 5,321 fields
against 418 at a month. At 10 years it reaches the spread of the game with another seed (73,040)
and is within twice the game's own run-to-run variation (41,000 to 47,000).

### What happens in the standards (`dev/standard_events.py`)

A quiet decade for both seeds. Over 10 years:

- the 12 empires, 2 fallen empires and 10 primitives stay; no wars, no ground combat, no crisis
  (2210 to 2220 is still early); the one federation stays;
- colonies grow from 49 to 54 (2215) and 59 (2220, standard A);
- ships go from 2,508 to 3,099 (A) or 3,062 (B), and fleets from 808 to 1,304 or 1,263;
- the monster factions `drone_faction` and `crystal_faction` disappear in 2210.07 and 2210.08 and
  come back with new ids at 2220.01;
- one short combat with 6 ships in the first 16 days (the profiled 180-day run, same start as
  standard A).

What the standards cover is the peaceful economy: production, pops, construction, ship building,
fleet movement and AI economics. They do not cover wars, crises or empire births and deaths.

## The random pools, traced: most of the 26,000 draws a day are never used

Run from `autosave_2210.01.01`, `run.sh` defaults, 1,798 ticks (180 days), unless noted. Files are
in `results/`.

### The ship pool (MicroUpdate, 95 % of the draws)

**What is drawn.** `CGameState::MicroUpdate` fills its static `ShipPtrArraySafe` from the game
state's ship list (`CGameState+0x530`, count +0x53c). It keeps every id that still resolves through
`TPdxRef<CShip>` (`CShip::IsValid()` is always true; a dead id resolves to the null object). That is
every ship in the save's `ships=` section. At 2210.01.01 there are 2,504 entries, and the first
tick's pool is 2,504 values; at the end the output has 2,546 entries and the last pool is 2,546.
The 2,546 include:

- mining stations (335), research stations (72) and starbases (outposts 95, starports 15,
  citadels 10);
- civilian ships: transports 136, science 44, constructors 33, a colonizer;
- warships (corvettes 102, ...);
- monsters (space whales, amoebas, crystals), marauders, caravaneers and fallen-empire ships and
  stations.

`(anonymous namespace)::UpdateShipParallel` then draws exactly that many values in one call,
`CRandom::GetIntegersForMacro(..., buf, count)`:

- once per tick (1,798 calls in 1,798 ticks);
- into a zeroed stack array, with draws allowed and the random log off.

The count is fixed when the array is built, before the draw, so it cannot change during the tick's
draw. It comes after the tick's fleet phase (`CFleet::MicroCombatSerial`,
`CFleet::MicroUpdateSerial`, `CFleetMovementManager::MicroUpdate`). Between ticks it changes as
ships are built and destroyed: 36 different counts in 180 days, from 2,504 to 2,548
(`ship_pool_per_tick_*.tsv`).

**Where the values go.** `CShipUpdateParallelFunc::operator()` hands value i to ship i:
`CShip::MicroUpdateParallel(unsigned seed, SCombatParticipants const&)`.

- It seeds a local `CCrudeRandom(seed)`: a `CNoiseRandom` hashed from the seed and the constant
  0x5ea6ba9f, nothing shared.
- It returns at once unless the ship's fleet `CFleetCombatManager::HasCombat()`.
- In combat it derives one seed per section, for `CSection::MicroUpdateCombatComponentsParallel`,
  and from that one per weapon, for `CWeaponComponent::MicroUpdateTargetingParallel`. That function
  does the targeting, and when a weapon fires it draws two values for
  `CStatInterval<CFixedPoint>::GetRandom`: the weapon's cooldown or stat roll.

All of this is game state (combat). No rendering, entity, particle, sound or GUI code reads the
values. No rendering or visibility check stands in front of them: the only gate is `HasCombat`.

| 180 days | values |
|---|---:|
| drawn | 4,535,156 |
| handed to a ship | 4,535,156 (every one) |
| to a ship whose fleet is in combat: the only ones that are used | **960** (0.021 %): 6 ships, in 160 ticks, the first 16 days |
| derived section seeds / weapon updates | 960 / 2,400 |
| weapon rolls (`CStatInterval::GetRandom`) | 18 |
| ticks with no ship in combat | 1,638 of 1,798 |

**Proof by experiment** (`HEADLESS_OVERRIDE`). The values handed to ships are replaced after the
draw, and the generator advances as usual (`pool_override_experiments.tsv`):

| ship pool values replaced | lines that differ from the normal run |
|---|---:|
| `^ 0x5bd1e995` from total tick 7956170 on (the last combat tick is 7956164): about 4.1 M values | **0**, and the same final `random_count` |
| `^ 0x5bd1e995`, every tick | 7,131 after 180 days |
| zero, every tick | 7,796 after 180 days |
| `^ 0x5bd1e995` over the 170 ticks of the combat | 373 |

In the last row, the fields that change are combat state: ship `x`, `y`, `rotation`, `forward_*`,
`speed`, `action` and `post_move_angle`; weapon `cooldown` and `shots_fired`; `hitpoints` and
`armor_hitpoints`; `last_damage`, `last_roll`, `last_combat_activity` and
`disengagement_opportunities_used`. After those come knock-on changes (a country focus, a
first-contact `clues` count) and a `random_count` 11 higher.

So outside combat the ship pool's values are drawn and never used. A simulation stays on the
game's stream by advancing the generator by the ship count (every entry of `ships=`, starbases and
stations included) at that point of each tick. It has to produce the actual values only for ships
whose fleet is in combat. The draw keeps the stream's position independent of which ships fight,
and lets the ships update in parallel.

**The order of the draws in a tick** (`HEADLESS_TRACE`, `draw_order_*.tsv`):

1. Commands the session executes before the tick: 837 draws in 180 days, none in the traced turns.
2. `HandleTurnTick`. On a day tick the date advances first; that draws nothing.
3. `MicroUpdate`:
   - first the fleet phase: `CFleet::MicroCombatSerial`, `CFleet::MicroUpdateSerial`,
     `CFleetMovementManager::MicroUpdate` (5 to 10 draws a day in all, on a few ticks; e.g. 5 in
     `CFleetMovementManager::MicroUpdate` right before tick 7956298's pool);
   - then **the ship pool, N values**;
   - then `CShip::MicroUpdateSerial` and `CFleet::PostShipMicroUpdate` (rare).
4. `ProcessAI` (tick % 10 == 4): no draws.
5. On a day tick, `DailyUpdate`: **the daily pool, 1,000 values, first** (nothing before it in
   `DailyUpdate` draws), then `CCountry::DailyUpdateSerial` country by country,
   `CPlanetManager::DailyUpdate`, `NColonyUpdate::DailySerialUpdate`,
   `CArchaeologicalSiteManager::DailyUpdate` (its own 10-value pool)...
6. On a month's first day, `MonthlyUpdate`: **the monthly pool, 1,000 values, first**, then
   `CCountry::MonthlyUpdateSerial`, `NColonyUpdate::MonthlyUpdate`, then one `GetIntegerForMacro`.
7. On a year's first day, `YearlyUpdate`.

For example, the 2210.02.01 tick moves the generator from 14,832,476 to 14,837,507:

| step | draws |
|---|---:|
| ship pool | 2,508 |
| daily pool | 1,000 |
| countries (daily) | 81 |
| planets | 45 |
| colonies (daily) | 36 |
| archaeology | 10 |
| monthly pool | 1,000 |
| countries (monthly) | 201 |
| colonies (monthly) | 149 |
| last `GetIntegerForMacro` | 1 |

### The daily and monthly pools

Both pools are handed to the per-object updates as `int const*` (`CPlanet::...(CGameDate, int*)`,
`CCountry::DailyUpdate...(int const*)`, ...). An object reads `pool[(id + K) % 1000]`, with a
constant K per kind (2659 for an unhabitable planet). It passes the value to `CEventScope(int)`, the
random seed of the scope its daily scripts run in (the `random={ 0 seed }` of saved scopes).

`HEADLESS_POOLTRACK` counts the reads. The pool is mirrored on a page of our own, the
`int const*` arguments are switched to it, and every read faults and is counted:

| per fill | daily | monthly |
|---|---:|---:|
| reads | 13,605 | 1,195 |
| distinct values read | **1,000 of 1,000**, every day | 217 of 1,000 (219 at most) |
| writes | 0 | 0 |

Who reads (`pool_reads_by_function_*.tsv`):

- **Daily:**
  - `CPlanet::DailyUpdateUnhabitable{OnlyChangeSafePrivate,SelfDontReadOthers}`: 5,955 planets,
    one read each in both functions (11,911 a day);
  - `CCountry::DailyUpdate{OnlyChangeSafePrivate,SelfDontReadOthers}`: about 10 reads each per
    country (1,098 a day);
  - the habitable planets: 249 a day;
  - the colonies and their event lambda: 197 a day;
  - `CPopGroup::DailyUpdateOnlyChangeSafePrivate`: one per pop group (145 a day), plus
    `EthicChangeSafePrivate`.
  - Ships, fleets, armies, leaders and bypasses get the pointer but read nothing in these 180 days.
- **Monthly:** `CCountry::Monthly{OnlyChangeSafePrivate,SelfDontReadOthers}` (10 reads each per
  country) and the colonies' monthly updates.

All of these are game-state classes. Changing the values changes the game:

- `^ 0x5bd1e995` on the daily pool: 6,713 lines differ after 180 days;
- the same on the monthly pool: 8,129 lines.

So, unlike the ship pool, these values are read every day and do matter. They seed scopes, so
whether a given read changes anything depends on whether the scripts run in that scope use
randomness.

### Graphics and the synchronized generator

The static search (`synced_generator_callers.tsv`) found 1,056 call sites in 599 functions:

- `CRandom::GetIntegerForMacro`: 1,019;
- `GetFixedPointForMacro`: 32;
- `GetIntegersForMacro`: 5 (`UpdateShipParallel`, `MonthlyUpdate`,
  `CArchaeologicalSiteManager::DailyUpdate`, `CEspionageOperationManager::DailyUpdate`,
  `CFirstContact::DailyUpdateSerial`);
- plus 15 direct uses of `CRandom::_Random`: the generator's own functions,
  `CGameState::WriteMembers`, `CStartGameFromInGameLobby::Execute` and
  `CCountry::CreateShipDesign`.

None is in a rendering, entity, particle, sound, animation or GUI class. Three only sound like
graphics:

- `RandomizeShipGfxCulture(CEmpireDesign const&)` picks a generated empire's ship graphical
  culture, a saved country field;
- `CParagonsImGui::Update` and `CCosmicStormsImGui::...` are developer debug panels.

So the synchronized draws are not there to keep visual effects in sync. The ship pool is combat
state, and outside combat it is drawn only to keep the stream's position fixed.

## How it works

`run.sh` makes a fresh HOME with `.local/share/Paradox Interactive/Stellaris/save games/headless/in.sav`,
reads the save's `required_dlcs` from its `meta`, and starts the game under `xvfb-run` with
`LD_PRELOAD=headless.so`, `LIBGL_ALWAYS_SOFTWARE=1` and `-loadrandomseed -threads=1`. The driver
finds every address in the executable's `.symtab` (`/proc/self/exe`) plus the load base
(`dl_iterate_phdr`), and replaces three functions (12-byte `movabs rax; jmp rax` at their entry):

| replaced | by | why |
|---|---|---|
| `CDLCManager::VerifyAllDLCOwnership(bool)` | marks each DLC descriptor owned (the node's byte +0x40c, as `AcceptAllDLC` does) when its name is in the save's `required_dlcs` | without Steam the store has no items and nothing is owned; here 14 of the 17 installed DLCs, as in the user's game (not Utopia, Synthetic Dawn, Humanoids) |
| `CFrontendDlcView::Update()` | on the third main-menu frame: `CFrontEndIdler::LaunchSave(CString("save games/headless/in.sav"), false, frontEnd + 0x250)` on `g_CurrentFrontEndIdler` | the main menu's load path (what `CLoadGameView::LoadSave` and the `-continuelastsave` path call) |
| `CInGameIdler::CheckTick(float)` | the driver: the game's own clock-driven ticks never start | runs on the main thread, once a frame, in game |

Five frames after the game is in (`g_CurrentGameState` set and started, `+0xa0`), the driver
turns off `g_bFrameSmoothing` (no frame rendered from inside a tick) and, until
`CGameState::GetTotalTicks()` has advanced by N, repeats what `CheckTick` and the main loop do:

1. `NUM_COMMANDS_PER_TURN` (2) times: a `CTurnTickCommand` built as `CheckTick` builds it
   (`operator new(0x50)`, its vtable and empty arrays), posted with `PostCommandToSession(cmd, false)`;
2. `CGameApplication::Update()` on `CApplication::AccessInstance()`: the frame's session update
   (`CSession::Update` -> `ProcessSynchronousCommands`, with the game state's
   `RenderFrameBetweenCommands` / `AfterCommandExecutedUpdate` callbacks), which executes the
   queued commands (AI and others) and then the ticks: `CTurnTickCommand::Execute` ->
   `CGameState::HandleTurnTick` (MicroUpdate, ProcessAI, DailyUpdate, MonthlyUpdate, YearlyUpdate).

Then `SaveGameCheckMakeSave(CString)` (the save-stability check's writer:
`CWriter::WriteTopLevelList(*g_CurrentGameState)` into a `CArchiveFile`, on the main thread) writes
the gamestate, in the same format as a save's `gamestate` (CRLF, which `run.sh` turns into LF), and
the process `_exit`s. The save's `tick` (`CGameState+8`, the `_nTickCount`) is restored by the load
itself (4 for `autosave_2210.01.01`).

`HEADLESS_MODE=frame` posts one turn a frame and lets the main loop run instead. With
`HEADLESS_RENDER=1` (frames drawn) it hangs after a few turns: the main thread spins in
`CShipGraphics::RenderShip`'s angle wrap (an `addss` loop at +0x140 that adds a step until the angle
reaches a bound, `ucomiss; jb` back:
the main thread was at that loop in three gdb samples 5 s apart on 2026-10-14;
a NaN keeps it there (the ship's rotation at CShipGraphics +0x110 comes from `asinf` of +0xb4, NaN
out of [-1, 1]: the cause is read from the code, not caught). That hang, not
llvmpipe, was the "minute a frame": drawn while paused (view mode, below), a frame takes 10 to
20 ms at 1600x900.

### View mode: the game's frames, driven by commands (`view.sh`)

```
headless/view.sh [--size WxH] [--listen [ADDR:]PORT] [--script FILE] [--replies FILE] [--menu] <save.sav>
# e.g. reference shots for sim/render, from a command file:
bash headless/view.sh --script shots.txt --replies shots.replies /opt/stellaris-saves/autosave_2210.01.01.sav
```

`HEADLESS_MODE=view`: the game boots, loads the save (or, with `--menu`, waits at the main menu
for a `load`), never ticks on its own, and draws its frames on an Xvfb screen of the window's
size (default 1600x900, windowed, vsync off; Mesa llvmpipe). It runs commands from the script,
then from TCP (one client at a time, localhost unless an address is given) until `quit`; one reply
per command, when it is complete. The protocol is `sim/render`'s (`docs/render.md` section 9), so
`sim/render/tools/ctl.py` drives both and one command file takes the same shots of the game and of
the renderer:

| command | in the game |
|---|---|
| `load PATH` | at the main menu: the file copied into the user dir, `CFrontEndIdler::LaunchSave`; the reply once the game is in (one save per run) |
| `pause` | ok: the game only ticks on `step` |
| `step DAYS` | the loop mode's turns until the date moved DAYS days, frame smoothing off (nothing drawn; ~30 ms a day) |
| `view galaxy`, `view system ID` | `CGameCamera::LeaveSystem`, `CGameCamera::EnterSystem` (the object from `TPdxRef<CGalacticObject>::_pDatabase`) |
| `focus system ID` | the galaxy camera's target on the system (`CGalacticObject::GetCoordinate` +0x408, x 2) |
| `camera X Y Z YAW PITCH DISTANCE` | the camera's orientation, in map units and degrees, put back every frame after the game's camera update; `camera off` releases it |
| `resize W H` | ok if the window is W x H (it is set at start: `--size`) |
| `gui off\|on` | `g_bNoGUI`, the hide-GUI key's flag (the GUI and the system's orbit lines) |
| `frame PATH.png`, `frame -` | the window captured from the X server once the picture settles: from 2 s and 10 frames on, two captures in a row nearly equal (at most 30 s; `HEADLESS_FRAME_WAIT`, `_MIN`, `_TIMEOUT`); a PNG (zlib) |
| `state [planet ID]` | JSON: date, view, window, the camera (orientation and its smoothing target, eye, look-at, up, FOV, aspect, near, far, the view and projection matrices), the system's zoom steps; with a planet its `CPlanet::CalcCurrentEntityScale`, `GetDisplaySize` and entity world transform |
| `quit` | `_exit(0)` (no gamestate written) |

How (all in `headless.c`, the layouts read from the Linux build's code):

- the camera is `CInGameIdler` +0x218, a `CGameCamera` beginning with its `CCamera` (view matrix
  +0x00, projection +0x40, eye +0x180, look-at +0x18c, up +0x198, FOV +0x1a4, aspect +0x1a8, near
  +0x1ac, far +0x1b0); its orientation {x, y, z, distance, pitch, yaw} at +0x218, its target
  orientation at +0x230, the system it is in at +0x274 (-1 the galaxy);
- `CInGameIdler::UpdateInternal` calls `CGameCamera::Update` after `CheckTick`: that `call rel32`
  is pointed at a thunk near the executable that calls the original and then writes the set
  orientation into both orientations and calls `CGameCamera::UpdateInternalCamera` (eye and
  matrices), so the frame is drawn from it;
- planets: `CGameState` +0x918 the planet manager (entries of 16 bytes at +0xdc0, the `CPlanet` at
  +8, the count at +0xdc8; the planet's id at +0x18, its size at +0x150, its entity at +0xc20);
  `EntityInstanceGetWorldTransform` gives the entity's world matrix;
- libX11 (`XGetImage` on the largest mapped top-level window) and zlib (`compress2`, `crc32`) are
  loaded with `dlopen`, so the build line is unchanged.

Seen in the game (2210.01.01, system 401): its bodies sit at y = -150 of the system's world (the
save's coordinates x 10), the ships at y = 0; a body's entity scale is `planet_size` x 0.1 x its
class's `entity_scale` x 0.35 (`g_bDisableScaling` set: PLANET_SCALE_SYSTEM is not used) x 0.7 for
a moon. The comparisons with `sim/render` are in `docs/render.md` section 10.

The site table for the pool traces was made with
`dev/callsites.py game/stellaris sites_pools.tsv -f <the tick's phases> -f <the ship chain: CShipUpdateParallelFunc, CShip::MicroUpdateParallel, CSection::MicroUpdateCombatComponentsParallel, CWeaponComponent::MicroUpdateTargetingParallel> --callee "(Daily|Monthly)[A-Za-z]*\(.*int( const)?\*" --asm re/full.asm`,
less the task-scheduler templates (`CreateTasks`, `AddTasks`, `std::__...`), which the callee
pattern also matches.

The profiler (`HEADLESS_PROFILE`) redirects each listed `call` / tail `jmp` (rel32) to a stub near
the executable (`mov r11d, site; jmp hk_entry`). `hk_entry` saves the argument registers, records
`CRandom::_Random`'s position, swaps the return address for `hk_post` and jumps to the original
target with the stack untouched; `hk_post` adds the draws to the site. Profiling changes nothing:
the profiled runs are byte-identical to unprofiled ones.

### What blocked, and the way around

| blocker | fix |
|---|---|
| `File 'gfx/...' does not exist : symlinks are forbidden`, then a crash | PhysFS refuses symbolic links: the data is copied (28 GB), not linked |
| SIGSEGV in `CPdxCrashReporter::CPdxCrashReporter` (strlen of `VFSGetWriteDir()` = NULL) | the user dir `~/.local/share/Paradox Interactive/Stellaris` must exist; `run.sh` creates it |
| no Steam client | nothing needed: `SteamAPI_Init` fails and the game goes on (no stub `libsteam_api.so`); PDX SDK and nakama do not block either |
| no DLC owned without Steam | `VerifyAllDLCOwnership` replaced (above) |
| `-continuelastsave` with a `continue_game.json` did not load (`g_bQuickStart` stayed 0; not pursued) | `LaunchSave` called directly |
| SIGSEGV in `CPlanetView::Reload` after the load ("Tried to get gui_type [] which does not exist") | `/opt/stellaris` lacks `unchecked_defines/` (`PORTRAIT_GUI_NAME_PLANET_SECTOR_GOVERNOR` ...) and five other folders; copied from the Windows Steam install of the same version into the runtime dir |
| runs differ | `-loadrandomseed`, `-threads=1` (above) |
| `timeout` on `xvfb-run` left the game running | the kill timeout is on the game itself, plus a watchdog thread in the driver (`HEADLESS_TIMEOUT`) |

Harmless: three empty DLC zips (dlc004, dlc013, dlc015) fail to mount ("unsupported"), no ALSA
device, ~2 MB of error.log about sounds (no audio device).

## Setup (done on 10.5.0.24)

```
bash headless/setup.sh [build dir] [data dir] [extra data dir]
```

Defaults: the 4.5.2 Linux build from hippo's `by_manifest/281994/1994331557761953329`, the data from
`/opt/stellaris`. The extra folders (`unchecked_defines dlc_metadata curated_save_games
pdx_online_assets tweakergui_assets locales`) came from the Windows install
(`C:\Program Files (x86)\Steam\steamapps\common\Stellaris`, same `checksum_manifest.txt`) by
`tar | ssh`. Nothing under `/opt/stellaris`, `/opt/stellaris-saves` or the backups is modified.
`/opt/stellaris-headless`: `game/` (the install), `headless.so`, `work/` (per-run dirs, removed
after a successful run), `cache/` (Mesa shaders, the profiler's site table).

## Options (`run.sh` environment)

| variable | |
|---|---|
| `HEADLESS_ARGS` | the game's command line, default `-loadrandomseed -threads=1`; e.g. `-rng_seed=64429129 -rng_pos=0 -threads=1` to replay a session that started from a load |
| `HEADLESS_RNG_POS` | after the load, set the generator's position (a number, or `save` for the save's `random_count`, undoing the load's draws) |
| `HEADLESS_PROFILE` | `1` for the default site table (made once by `dev/callsites.py`), or a table; the result goes to `<out>.profile.tsv` (or `HEADLESS_PROFILE_OUT`) |
| `HEADLESS_OVERRIDE` | `<site>=<mode>[,...]` (hex offsets of instrumented calls): after the call returns, replace what it drew (the `count` ints of a `GetIntegersForMacro`, or the int returned): `zero`, `xor` (^ 0x5bd1e995), `const:N`; with `HEADLESS_OVERRIDE_FROM=<total ticks>` only from then on. Needs `HEADLESS_PROFILE` |
| `HEADLESS_TICKLOG`, `HEADLESS_WATCH` | a line per tick: the draws in it and how many times each watched site (`hex,...`) was called |
| `HEADLESS_TRACE`, `HEADLESS_TRACE_OUT` | `<from>-<to>` total ticks: every instrumented call that draws, in order, with the generator's position |
| `HEADLESS_POOLTRACK` | a file: reads of the daily and monthly pools, by consumer, instruction and index (`HEADLESS_POOL_DAILY` / `_MONTHLY` give the pool sites, default `1b1c948` / `1b2d746`); turns task threads off and takes ~150 ms a day; the outputs are unchanged |
| `HEADLESS_AUTOSAVE`, `HEADLESS_SAVES_OUT` | the game's own autosaves at that level (2 monthly, 3 quarterly, 4 half-yearly, 5 yearly), all kept, moved to that directory as they are written |
| `HEADLESS_NO_TASK_THREADS=1` | the game's parallel-fors run inline (deterministic AI; ~75 ms a day instead of ~40) |
| `HEADLESS_NO_ASLR=1` | the game runs with address-space randomization off (`setarch -R`) |
| `HEADLESS_DLCS` | owned DLCs, `;`-separated names; default the save's `required_dlcs` |
| `HEADLESS_KEEP=1` | keep the work dir (the game's logs) |
| `HEADLESS_TIMEOUT` | seconds (default 1800) |
| `HEADLESS_ROOT` | default `/opt/stellaris-headless` |

## What is left

- The player country's events stay open. To match a session where someone clicked, answer them
  (e.g. `CGameState::SelectDefaultOptionForOpenPlayerEventAtIndex`, which `DailyUpdate` already
  calls for auto-selectable events), or give the country to the AI (`-humanai`).
- One boot per run (~23 s of the ~29). Several outputs from one run (gamestates at 10, 100, 1,798
  ticks) would be a small addition; many saves per boot would need a return to the main menu.
- Only the gamestate is written, not a `.sav` (`meta` + zip). `zip` it with the input's `meta` to
  load it again (done above), or call the save task (`CSaveGameTaskManager`).
- Offsets that are not symbols are 4.5.2's: the `CString` layout, `CGameState` +0x8/+0xa0/+0xc4,
  the front end's +0x250, the DLC map (+0xd8, node +0x50/+0x40c), the tick command's fields.
- Frame mode (ticks with frames drawn) hangs in `CShipGraphics::RenderShip` on a NaN rotation
  (above); view mode draws frames only while paused. A `state ship ID` (the ship's entity, through
  `CShipGraphics`) is not done.
