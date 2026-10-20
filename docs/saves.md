# Saves (4.5.2): reading, writing, and the real game on both sides

How the simulation and the renderer save a running game so that the real Stellaris 4.5.2 loads and
continues it, and how they load what the game writes. The code: `sim/lua/engine/savegame.lua` (the
gamestate's layout, the head, the meta, the load report), `sim/src/save.rs` (the zip, the folder and
file names), `Simulation::write_save` (`sim/src/scheduler.rs`), the simulation thread's `Save`
command (`sim/render/src/clock.rs`), the save window (`sim/render/src/mainbars.rs`), the command
`save [PATH]` (`sim/render/src/engine.rs`), `sim/examples/resave.rs`, `sim/tools/save_roundtrip.sh`,
`sim/tests/savefmt.rs`.

**Marks.** **[V]** was read in the game's own saves (the user's `sacreduthabulanorder_-730439522`
folder, `/opt/stellaris-saves`, `/root/scov/saves/rich_2212.sav`), in the Linux 4.5.2 binary (its
symbols; the address is given), or measured with the headless game (`headless/`). **[I]** is
inferred.

## In short

- A `.sav` is a zip of `gamestate` then `meta`, deflated, DOS time 0, plain text, no checksum
  [V]. We write it that way.
- The gamestate is written from the world in the game's own layout; read back it is the same tree,
  and 99.94% of its lines are the game's byte for byte (the rest: member writers' layouts, below).
- The meta is made from the world as `CGameState::WriteMembers` makes it [V 0x1b08003]: on the
  game's autosave it is the game's meta byte for byte.
- The head carries the simulation's state: the date, the tick within the day, the synchronized
  generator (`random_seed` written as the game's signed int, `random_count`).
- The folder and default name are the game's: `save games/<CGameState::GetSaveFolderName>/<date>.sav`.
- Proved with the headless game (`sim/tools/save_roundtrip.sh`): the game loads our saves,
  continues them, and saves them again with its own save path; we load what it writes.
  From `autosave_2210.01.01`, the game's 30 days from our rewrite of its save are identical to its
  30 days from the save itself.

## 1. The file [V]

| | the game (4.5.2's saves) | ours |
|---|---|---|
| container | zip: `gamestate`, then `meta` | the same (`save::write_save`) |
| compression | deflate, flags 0 | deflate |
| entry time | DOS date and time 0 (1980-00-00) | the same |
| checksum | none: not in the meta, not in the gamestate head | none |
| text | LF, no BOM | the same |
| binary saves | no: `CSaveGameTaskManager::CreateMemoryFiles` (0x1f24330) writes both entries with `CWriter(file, false)` and `WriteTopLevelList` | read: text and zipped text; a plain gamestate (`headless/run.sh`'s) too |

The file is written to `<path>.tmp` and renamed over the target, so a failed save leaves the old
one.

### Folder and name

- **Folder** (`CGameState::GetSaveFolderName` @0x1b40f20 [V]): the game's name (the gamestate's
  `name`) with everything but ASCII letters and digits removed; when something was removed, `_`
  and `PMurHash32(seed 0, name)` as a signed int are appended; then lowercased. "Sacred Uthabulan
  Order" gives `sacreduthabulanorder_-730439522`, the user's own folder. `save::save_folder_name`.
- **Root**: `Documents/Paradox Interactive/Stellaris/save games` on Windows,
  `~/.local/share/Paradox Interactive/Stellaris/save games` on Linux; `STELLAR_SAVE_GAMES` overrides
  (`save::save_games_dir`).
- **Default name**: the date (`CInGameIdler::ShowSaveGameScreen` @0x1c8bba0 passes
  `CGameDate::GetGameString()` to `CSaveGameView::Show` [V]; the user's manual save is
  `2200.01.11.sav`). Characters a file name cannot hold are dropped (`save::save_file_name`) [I].

## 2. The meta [V]

`CGameState::WriteMembers` writes the meta's part (0x1b08003): `version`,
`version_control_revision`, `name`, `date`, `required_dlcs` (the gamestate's head), then for the
player's country (`CHuman::GetSelectedCountry`):

| key | source | in the world |
|---|---|---|
| `player_portrait` | the country's species (+0x153c), its portrait (+0x180) | `founder_species_ref` -> species `portrait` |
| `flag` | the country's flag (+0x27e0) | the country's `flag` block |
| `meta_fleets` | `CCountry::GetFleetSize(true)`, a fixed point | `used_naval_capacity` (15 in the user's saves, while the country owns 9 fleets) |
| `meta_planets` | an int (+0x269c) | the `owned_planets` list's length [I: equal in all the user's saves] |

`savegame.meta` writes these in that order from the world, keeping any other key of the loaded
save's meta (`ironman`). Test: the meta made from the world on `autosave_2210.01.01` equals the
game's byte for byte. The game's own save of a game we wrote (round trip, step 2) has the same meta
as ours but for the date.

**What the game checks on load:** `SSaveGameMetaData::CheckIsBadVersion` (0x1f1b8f0) marks a save
under 4.5 or over the game's version incompatible; `CheckHasOtherDLCs` (0x1f1bc80) compares
`required_dlcs` with the DLCs owned. We write the loaded save's version and DLC list; a new game's
are the generator's (`engine/newgame/save.lua`).

## 3. The gamestate

### Layout [V the saves]

The game's reader does not care about whitespace (with one exception, below), but written in the
game's layout a save diffs line for line with the game's. `savegame.write`:

- `key=value`; a block opens on the next line at its key's indent (`key=\n\t{`), its entries one tab
  in, and closes at the key's indent; an empty block `key=\n\t{\n\t}`;
- a block's unquoted values on one line, each followed by a space (`\t\t4 5 6 7 \n`); quoted values
  one per line (`required_dlcs`, flag colours);
- a run of blocks without keys: a line of the indent alone before the first, a line holding one
  space after each; in `growth_stages`, `pop_groups`, the research queues and a few more, an empty
  line between them and none after the last;
- `random={ 0 633261057 }` inline (the AI's generator state);
- a date value gets its indent twice (`\t\tformed=\t\t"2209.04.19"`; in a list the first date);
  `dismantle_finish_date` is a plain string;
- **`intel` and `federation_intel` are maps written as pairs, `{ 6 { intel=0 ... } }`**: the key at
  the start of its line, a space, the block without `=`. pdxscript reads `6 {` as `6={`, and the game
  does **not** read `6={` back there: written with `=`, every intel entry was lost (30 days later
  the game had `intel=0.9999` where its own save gave 10 to 29.8; 564 lines). This is the one layout
  the game's reader depends on that we found.

What is left (848 of 1,451,433 lines of `autosave_2210.01.01`, 0.058%; 651 of `rich_2212`) is member
writers' own layouts that the parsed tree does not keep: starbase modules on one line
(`0=shipyard\t\t\t\t1=solar_panel_network\t\t\t}`), some map keys at the start of the line (`16=`),
`key=0\t\t\t\tvalue=6313\t\t\t}` on one line, technology keys with the indent twice. pdxscript would
have to record `key {` against `key={` (it folds them, `lib/stellar-lua-pdxscript/pdxscript.lua`
line 346) for the pair rule to be general rather than per key.

### Numbers, quoting

Values are kept as the save's text: a value the simulation never wrote is written back exactly as
read. Values the simulation writes use `world.number_text` (integers as integers, else 5 decimals
with trailing zeros dropped), which is the game's form (`3.65056`, `293.0167`, `-131.97`).
Quoting is kept per token as read.

### The head

`savegame.prepare` sets, from the simulation: `date`, `tick` (`CGameState::_nTickCount`, 0..9: our
saves are written between days, so it is the tick the save was loaded at), `random_seed` (a u32
written as the game's signed int) and `random_count`. The rest of the head (`version`,
`required_dlcs`, `player`, `cheated_on_save`...) is the loaded save's.

The game only uses the saved generator with `-loadrandomseed`; a normal single-player load reseeds
from the clock (headless/README.md, Determinism). The renderer's simulation now starts from the
save's `random_seed` / `random_count` and tick, as `examples/run` and the headless oracle do (it
started at seed 0, tick 0: its saves could not continue the save's stream).

## 4. Saving from the renderer

- The simulation runs on its own thread (clock.rs). `Clock::save(path)` sends `Cmd::Save`; the
  thread handles it between days (a day is never left half run: `run_sliced` ends on a tick's end,
  and `Simulation::write_save` refuses mid-tick). A save of the 2210 galaxy takes 0.3 s.
- The in-game menu's **Save Game** hides the menu and opens the save window (CMainMenuView::Save
  @0x2f54580 [V]): `savegame_view.gui` `SaveGameScreen`, the game's name, the file name box (the date,
  typed into; Backspace, Return), **Save**, and the folder's saves (`SaveSaveGameEntry`: name, date,
  fleets, planets from each meta; a click takes its name). Escape closes it.
- The window's size (CSaveGameView::Update @0x3141c67 [V]): the .gui's height (6) plus the list's
  top (150) and its entries (58 high, spacing -4), at most `SaveGameScreenMaxSize` (550); centred
  [I].
- [I] Not done: the overwrite dialog (`ClosedOverwriteDialog`: an existing file is overwritten),
  the entries' delete buttons (hidden), cloud saves (hidden), ironman saves.
- The command protocol: `save PATH`, or `save` alone to the game's folder and default name.

## 5. Loading

- The main menu's Load Game lists the saves of the game's folder (now also the Linux one) and loads
  them behind the load screen into the simulation, as before; our saves show there with their
  meta's flag, fleets and planets.
- What of a save this build does not read is said, not failed on (`savegame.report`, printed by the
  simulation thread and put in the log and the load console): another version than 4.5.2 (the world
  is read as it is, nothing is converted), `ironman=yes` (loaded as a normal game; saves written from
  it are not ironman saves).
- Everything the simulation does not model stays in the world as read and is written back as it was:
  a save the game wrote loses nothing by passing through us (step 1 below).

## 6. Both directions with the headless game

`sim/tools/save_roundtrip.sh [save] [N] [M]` on 10.5.0.24 (one headless game at a time; output in
`/root/saves/rt*`). Results, 30 + 30 days:

| step | autosave_2210.01.01 | rich_2212 |
|---|---|---|
| 1. the game's N days from its save, and from our rewrite of it (read, written, 0 days) | **identical** (0 lines; 564 before the intel fix) | 1,250 lines differ: the game's own run-to-run noise there (below); 4 of 5 runs from our rewrite equal a run from the original |
| 2. the game loads our N-day save | yes; 0 ticks writes back 16,467 changed lines (its own save: 15,519) | yes |
| 2. the game runs M days from it and saves with its own save path (view.sh `save`) | yes, `autosave_2210.03.01.sav` | yes, `autosave_2212.09.03.sav` |
| 2. we load the game's save of our game | yes (and the renderer: run, saved again) | yes |
| 3. our M days from our save against the game's M days from it (examples/diff) | 99.2% of 738,077 fields equal | 98.8% of 763,018 |
| 4. our N days from the game's save against the game's (the same measure from the game's own save) | 99.3% | 98.9% |

Steps 3 and 4 measure the simulation, not the save: from our save the game and we agree as well as
from the game's own save (the step 3 runs are a month later, after our first month). The differing
fields are the simulation's (ship positions and headings, pop growth, AI choices): the coverage
sessions' work, not this one's.

### rich_2212: the game is not repeatable there, the save's bytes play no part [V]

On `rich_2212` the game's 30 days from our rewrite differed from its 30 days from its own save
(1,250 lines). That first looked like a dependence on the save's exact bytes: three runs of the
original agreed, while a trailing newline or one tab made a space changed the result. It is not:
**the original itself is not repeatable** (`-loadrandomseed -threads=1`), and three agreeing runs
were luck. Runs of 40 ticks (4 days) on `/root/saves/bis` (10.5.0.24):

| file | runs | AI country 16777225 proposes an embassy to |
|---|---|---|
| the game's own gamestate, re-zipped | 7 | 16777217 in 5, 16777219 in 2 |
| the same, one tab made a space | 8 | 16777217 in 6, 16777219 in 2 |
| the same, one newline added | 2 | 16777219, 49 |
| the same, `HEADLESS_NO_TASK_THREADS=1` (parallel-fors inline) | 6 | 49 in 5, 16777218 in 1 |
| **our rewrite** (`ours_0.sav`: read, written back) | 5 (a 6th aborted at start-up) | 16777217 in 3, 16777219, 16777218; **4 of the 5 identical to a run of the original** (0 lines) |

The runs are identical up to day 3; the 36 lines on day 4 are this one proposal (and what follows from
it), and they grow to ~1,000 lines in 30 days. What the game does there [V]:

- `CAIForeignMinister::DailyUpdate` (0x2819620), in the AI's per-country pass `UpdateAIParallel`
  (0x28086c0), calls `MakeAIDiplomaticAction` (0x27f6670);
- that runs a parallel-for over the other countries whose body calls `BuildProposalList` (0x27f2b60),
  which appends each candidate to one shared array under a `CPdxMutex` (`InsertAtEmplace`): the
  array's order is the tasks' completion order, and nothing sorts it;
- the country AI's own generator (`CNoiseRandom::GetInteger`, the country's `random_seed` /
  `random_count`) then draws the index of the proposal to make.

With the default task threads (`-threads=1` still leaves 4) the order changes from run to run. With the
task threads off one run in six still differed: there country 16777225's own generator had drawn
once more (`random_count` 16,790,944 against 16,790,943, a line `gsdiff.sh` masks) before the pick.
Where that extra draw comes from is not found [open]. `UpdateAIParallel`'s clock reads
(`CProfile::GetCPUTime`) only pace frames (`RenderFrameInParallelFor`), not state.

So the writer is not at fault on `rich_2212`: a game run from our rewrite is indistinguishable from
one from the game's file. `save_roundtrip.sh` now runs the game twice from the original and prints that
noise next to the writer's difference. On `autosave_2210.01.01` the noise was 0 in every run so far.

## 7. Tests

- `sim/tests/savefmt.rs` (no game needed for the first four): a sample in the game's layout read and
  written back byte for byte (every rule above, the intel pair included); the head; the folder name
  (the user's); the zip's layout; and with a save present, the game's `autosave_2210.01.01` written
  back as the same tree with fewer than 0.1% of lines in another layout and the meta byte for byte.
- `sim/tests/world.rs` `a_save_written_after_a_month_loads_back`: 31 days, `write_save`, read back:
  the date, the tick, the generator, the meta, the world's state.
- `sim/tools/save_roundtrip.sh`: the headless round trip above, rerunnable.
