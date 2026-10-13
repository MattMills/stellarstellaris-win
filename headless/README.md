# headless: the real Stellaris 4.5.2 as a simulation oracle

The Linux 4.5.2 build runs on a Linux box under Xvfb (Mesa software GL), loads a save through its
own load path, runs an exact number of ticks through its own tick path with nothing rendered, writes
the gamestate with its own writer, and exits. Runs are deterministic, and a run reproduces the
game's own play session: from `autosave_2210.01.01` the 180-day and 360-day results equal the
game's `autosave_2210.07.01` and `autosave_2211.01.01` except for the one event the human player
answered.

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
| `setup.sh` | builds the runtime directory `/opt/stellaris-headless/game` |
| `dev/gsdiff.sh` | diff two gamestates with the one known noise line masked |
| `dev/callsites.py` | the call-site table for the random-draw profiler |
| `dev/bg.sh`, `dev/xwd2png.py` | development: a game in the background, screenshots, gdb |
| `results/profile_*.tsv` | random draws per call site (below) |

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
  apart. `-threads=1` fixes it; one such counter can still differ by a few (it changed nothing
  else in 360 days).

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

`HEADLESS_MODE=frame` posts one turn a frame and lets the main loop run instead; it works but is
unusable under llvmpipe (the in-game frame, ship graphics included, takes about a minute).

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
- Frame mode needs the in-game graphics update off too, if it is ever wanted.
