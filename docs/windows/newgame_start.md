# Starting a new game (the renderer)

From the setup's Start to a running game: the galaxy generated in Lua (docs/newgame.md), the
game's load screen while it runs, then the map of the new game, paused at 2200.01.01 on the
player's capital, its simulation on the clock's thread as a loaded save's. **[V]** marks what was
read in the 4.5.2 Linux build (`/root/re452` on hippo; addresses are that binary's), **[I]** what is
inferred or chosen here.

## 1. The game's path

`CFrontEndIdler::LaunchNewGame` (`0x25c57b0`) **[V]**:

1. `CreateLoadScreen(gfx, gui, true)`, `ShowLoadscreenWindow`, `RenderLoadScreen` at 0 with
   `START_NEW_GAME` ("Starting New Game"); `s_nWorldGenProgress = 0`.
2. The generation runs as a task (`LaunchNewGame::$_2` -> `CGameState::GenerateNewGalaxy`). The
   main thread pushes the progress state (0, 50) and loops until the task is done: the session's
   net update; when the bar shown (a float from 0) is not the progress, `shown = 0.9 shown + 0.1
   T(progress)` and `RenderLoadScreen(START_NEW_GAME, trunc(shown))`; then a 16 ms nanosleep
   (`{0, 16000000}` at `0x45febd0`). The comparison is with the raw progress, not its transform.
3. The state popped, `RenderLoadScreen` at 50, the `CInGameIdler` made and set.
4. `CInGameIdler::RestoreDeviceObjects` (`0x1c97c30`) pushes (50, 75) and draws `LOAD_MAP_GFX`
   ("Loading Map Graphics") at about 25 steps `100 k / n` (`RenderRestoreDeviceObjectsLoadScreen`
   `0x1c97a90`: at most once each 1/60 s), the last at 100 (75% of the bar), then
   `DestroyLoadScreen`.

The progress context (`CLoadScreenProgressContext`) **[V]**: a stack of `{start, span}`;
`PushState(a, b)` on the top `{s, k}` pushes `{s + k a / 100, k (b - a) / 100}` (integers);
`GetTransformed(p) = start + span p / 100` of the top state. `GenerateNewGalaxy` pushes (0, 75)
around `CGalaxyGenerator::Generate` and (75, 100) around `InitPostGalaxyCreation`, so the bar
moves toward `37 p / 100` while the galaxy is made and toward `37 + 12 p / 100` after.

`SetWorldGenerationProgress` (`0x25c95d0`, an `xchg` on `s_nWorldGenProgress`) **[V]**, its callers:

| where | value |
|---|---|
| `CGalaxyGenerator::Generate`, after `CRandomNameDatabase::FillDatabase` | 5 |
| `GenerateFromRandomScenario`, after `CreateResouceClusters` | 10 |
| the same, after `InitEmpireSystems` | 17 |
| `GenerateFallenEmpires`, after each tree | `20 + 50 i / n` |
| `InitializeUninitializedSystems(.., 70, ..)`, each system (initialized or not) | `70 + 30 i / n` (i from 0; the end is 100 in the code, not the argument) |
| `GenerateFromStaticScenario`, at the end | 100 |

The picture: `CGameGraphics::LoadLoadingScreens(true)` (`0x2e6faa0`) lists `gfx/loadingscreens`
`*.dds` and takes `CCrudeRandom(1).Seed()` (the clock) `% count` **[V]**; the window is
`interface/load_screen.gui` `load_screen` (fullScreen, its `status` window `CENTER_DOWN` at y -180:
the `GFX_progressbar_933` bar and an instantTextBox in the `load_screen` bitmap font; the `tip`
window is at y -99999, off the screen).

## 2. Here

| part | where | status |
|---|---|---|
| settings | `newgame.rs` `NewGameSettings { values, empire }`: newgame.generate's keys as text; `empire` a prescripted design's key or a whole design `key = { ... }` (settings `player_design` / `player_design_text`, engine/newgame/empires.lua); `from_lua` takes the setup screens' table (render.newgame_setup, session ng-flow) | **[V]** run |
| Start | `App::start_new_game(settings)`; the action `start_new_game` starts one from `App::newgame_setup` (the setup screens set it) | the call **[V]**; the Play button is ng-flow's |
| command | `newgame [async] KEY=VALUE ... [empire=DESIGN] [designs=FILE] [global_at=STEP=N,...]` (`_` for a space in a step's name); `loaded` waits for an `async` one; `state` has `load_screen: {text, percent, world_gen, stage}` | **[V]** |
| generation | on the simulation's thread (`clock::Source::NewGame`): a runtime at 2200.01.01 seeded with `global_seed` (the global stream the generator draws from), `newgame.generate(dir, settings)` with `tree_only` and a `progress` callback | **[V]** |
| progress | engine/newgame/init.lua calls `settings.progress` with the game's values: 5, 10, 17, `70 + 30 i / n` (systems.initialize_rest); no fallen empires yet, so no 20..70 | **[V]** the values; the moments are the Lua's steps |
| hand-off | the generated tree handed to `engine.load` as is (`world.load_tree`: the builder's metatables cleared), no text written or parsed. `STELLAR_NEWGAME_TEXT=1` loads its text instead; `STELLAR_NEWGAME_CHECK=1` compares the tree with its text parsed again (tiny, seed 1234: 0 differences besides the parser's line numbers) | **[V]** |
| start | `newgame.start_script` in the same state (the init_effects, the empire on_actions, on_game_start), then the clock's first snapshot | **[V]** |
| terra incognita | engine/newgame/post.lua after the start script (InitPostGalaxyCreation's): every country without one gets an all-unknown `terra_incognita = { size = 256 data = { 65536 } systems = { } }` (the game's day 0 has one per country), the world indexed again, then engine.exploration's load pass clears it in sensor range | the maps **[V]** (day0.gamestate); the clearing is the engine's |
| load screen | `Screen::Loading`: frontend.load_screen (the picture covering the screen [I], the status window), the bar stepped as LaunchNewGame does (`newgame::Bar`, 16 ms steps of the frame's time), stage GENERATING then POST; when the game is ready the map is made (LOAD_MAP_GFX at 50) and shown after one more frame (75) | the formula **[V]**; RestoreDeviceObjects' ~25 steps are two here **[I]** |
| landing | as after a load (`App::show_map`): the galaxy camera reset, the capital's system entered, paused, speed 3 | **[V]** |
| picture | `newgame::background`: the folder's `.dds` sorted by name, `% count` of a clock seed (`STELLAR_LOADSCREEN=N` fixes it) | the folder's order **[I]** |
| fullScreen | gui.lua: a `fullScreen = yes` window is the screen's size (centres the status bar; only interface.gui and load_screen.gui have it) | **[I]**, not compared with a game frame |

Checked on 10.5.0.24 (lavapipe, 1600x900):

- `newgame scenario=tiny empires=3 seed=1234`: 196 systems, 4 countries, player 0 on its capital's
  system (Slephus Prime), 2200.01.01 paused; generated 0.5 s, loaded 4.2 s, start script 0.2 s
  (304 init_effects, 17 on_actions, 0 errors); `step 10`: 0 errors.
- `newgame scenario=medium seed=7`: 590 systems, 834 hyperlanes, 10 countries (the player the
  prescripted XT-489 Eliminator), shown in 6.8 s; 100 days by `step`, then 45 at speed 5 on the
  clock: 0 errors.
- lockstep frames of the load screen: START_NEW_GAME, the bar at 0 then 46-47% in the POST stage.

## 3. Found on the way

- `modifiers.lua` (ship parts): a ship whose design is not in `ship_design` gave `design = false`
  and the check `gs == nil` let it through (`world.field(false)`): `if not gs`. The generated
  ships reference designs the generator does not write; a loaded world with such a ship failed in
  `engine.load`'s modifier rebuild.
- `settings.player_design` was never read (scenario.lua's config had no `player_design`): now it
  is, and `player_design_text` beside it.

## 4. Against the game's new game

Session ng-headless's reference (headless/newgame.sh on branch ng-headless;
code_working/tmp_newgame/ref/tiny3_g0: tiny, elliptical, 3 AI, the player humans1_1, the global
generator at 0:0) loaded in the renderer (`load-sim .../ticks10.gamestate`) beside `newgame
scenario=tiny shape=elliptical empires=3 fallen_empires=0 global_seed=0 empire=humans1_1`
(/root/ngs/t5.txt, t6.txt on .24; side by side /root/ngs/cmp_g.jpg):

| | the game | here |
|---|---|---|
| galaxy seed (value 1874735034) | 1064022505 | 1064022505 |
| systems | 200 (196 of the generation, 4 made by the start) | 196 |
| the player | United Nations of Earth, Sol, Earth the capital | the same |
| landing | paused, the capital's system (Sol, id 23) | paused, the capital's system (Sol, id 1) |
| fleets | 113 (science, construction, 1st Fleet, ...) | 0 |
| Sol's neighbourhood, lanes, the starting income | | differ |

The path (settings, seed, generation, start, landing) agrees; what differs is the generator's and
the start script's content (sessions ng-headless and ng-effects).

With ng-headless (cfa2302) and ng-effects (49b4b60) merged in a test worktree and the reference's
parity setup (`newgame ... designs=.../tmp_newgame/ref/designs3.txt
global_at=hyperlanes=5382,empire_systems=5384`, /root/ngs/t9.txt; side by side
/root/ngs/cmp_p.jpg): the UNE at system 23 as in the game, the same Sol border and neighbours
(Alpha Centauri, Procyon, Barnard's Star), 1st Fleet 15/50, 273 hyperlanes, 96 fleets (the game
113), 196 systems (200), a day run with 0 errors. Still different: the top bar's incomes; the
ships' names (UNS); Sol Station / Sol Starbase.

Terra incognita (post.lua): the game's UNE knows Sol and its hyperlane neighbours at day 0: `{ 11 23
112 145 }` in tiny3_g0 (Sol's lanes 112 11 145) and `{ 11 23 112 147 }` in tiny3f_g0, the reference
with the forced designs (Sol's lanes 147 112 11; the Lua's day-0 lanes equal the game's there);
here `{ 23 }` with ng-effects 49b4b60. (tiny3_g0 was made with the default, randomized designs:
compare a forced-design run with tiny3f_g0.) With ng-effects 57f28c3 (the station fleet placed, the
game's start designs: the starport's size modifier gives its sensor range 2) and ng-headless
56eb082 merged: the UNE knows `{ 11 23 112 147 }` and its map's runs are the game's exactly
(`33885 3 252 9 246 17 ... 29083`); the galaxy view shows the known space only, as the game's. The exploration pass sees the capital (sensor range 1: its own system
only) and the fleets at Sol, but every generated ship's design gives sensor range 1 and the
starbase's station fleet (fleet 0) has no `movement_manager.coordinate.origin`, so nothing reaches
past Sol: the start objects' data (session ng-effects), not the pass.

## 5. A creator-made empire (render-newgame-1)

Through the empire creator (Done, Yes, Play), three faults, fixed on branch ng-start-fix:

- **Names "nil"**: a user design's names are name blocks (`name = { key = "United Nations" literal
  = yes }`, `system_name`, `planet_name`, the species' `species_name` / `species_plural` /
  `species_adjective`); empires.lua passed the parsed block to save.lua's `B:name`, which wants
  `{ key, literal, variables }`, so every key was written `"nil"`. `empires.name_of` converts them
  (a prescripted design's texts pass as they are). The renamed home system's planets and moons
  follow its name ("Sol IIa", not the generated name's) [I].
- **An empty home system**: the world was right (system 9 with its 20 planets), but the first frame
  showed 0 bodies: the map asks the simulation's thread for the system and waits a second, and
  that thread reads the models' index first (1.5 s on a medium galaxy). The load screen now stays
  at LOAD_MAP_GFX until the capital's system has come (at most 60 s): the first frame has its
  bodies and ships.
- **No flag in Game Details** for a custom design: the setup view's `empire_flag` now gets the
  design's `empire_flag` composed on GFX_empire_flag_128 (render.empire_preview.flag_texture).
  (`render.newgame_design`, which frontend_newgame.lua requires for the preview's texts, does not
  exist: the empire's name and species texts there stay empty.)

Tools: `newgame ... empire_file=FILE` (a whole design from a file), `STELLAR_NEWGAME_DUMP=FILE`
(the settings a start was given, and FILE.empire its design), `STELLAR_NEWGAME_EVAL=FILE` (a Lua
chunk run on the started world, its result logged). Checked on .24 (/root/ngf): the creator flow,
its design replayed by command, the tiny parity run (the game's known systems, 10 days) and medium
seed 7 (30 days), 0 errors; cargo test 24 passed.

## 6. The bar's look (progress_startend.shader)

GFX_progressbar_933 is drawn with `gfx/FX/progress_startend.shader` **[V]** (the file): its
textureFile1 (609 x 102) is three rows of 34, a start cap, the framed middle and an end cap. Up to
the state each pixel is the middle row with the start cap laid over it by its alpha and the end
cap, shifted by `1 - state` in u (its right end at the state), laid over by its alpha; after the
state, textureFile2. The renderer drew textureFile1 whole, its three rows squeezed into the 34
pixel bar: a thin fill with a faded left end and no frame, which looked shifted left of the empty
part. Now gui.lua draws the three rows as the shader composes them (an item's `clip` carries the
texture's v range and a u shift: `{ u0, u1, v0, v1, shift }`, scene.rs; a row is sampled half a
texel in), for every progressbarType whose effectFile is progress_startend (the planet view's,
the fleets' health and the queues' bars too).

Checked against the real game's load screens (loading a save in view mode, its Xvfb display
captured every 0.2 s: /root/nlb/gcap.sh on .24) at 1600x900 and 1920x1080: the bar's frame at the
same place (x 485..1094, top 785 at 1600x900; x 655..1264, top 965 at 1920x1080), the fill inside
it from its left edge, the middle's frame and the end cap's light at the state.

The other bars the renderer draws do not take this path: the technology and traditions views'
GFX_tech_research_progressbar has progress.shader; the fleet window's health, armour, shield and
command limit bars are composed as `@bar:` textures (fleetwin.rs); the starbase build queue's bar
has its own items (starbase.lua); the planet view's and the situations' bars are hidden. The
planet (15), fleet (3), starbase (0), technology and traditions views of autosave_2210.01.01 are
pixel for pixel the same with and without this change (master 0b73793 against it, .24
/root/nlb/pb). (The starbase queue's GFX_queue_progressbar is a progress_startend sprite drawn
whole by starbase.lua: when a save with a queued item is compared, it may want the same
composition.)

## 7. The load screens' console (the renderer's, not the game's)

Over every load screen the renderer shows (a new game's START_NEW_GAME and LOAD_MAP_GFX, a save's
LOAD_SAVE_GAME), a dark panel at the top left (GFX_tiles_dark_area_cut_8 at 85%, the cg_16b font)
shows the last lines of the renderer's log, newest at the bottom, each cut to the panel's width, a
line with errors in red ("0 errors" is not one). The game has no such panel; it is drawn after the
load screen's window and apart from it.

- What it shows (src/console.rs): every line the crate writes with `eprintln!` (main.rs shadows the
  macro for the whole crate, from every thread), and so the app's log where it is written out (the
  window's eprintln! of it); driven by commands, the app's log goes into the replies and
  `flush_log` adds it. Each line comes once (the load screen took the app's log as well, until a
  fix: every app log line was shown twice in the window).
  The simulation's thread writes the new game's stages as each ends (the generator's summary and
  steps, the engine's load with its `jobs:` line, the start script, the terra incognita, the
  timings), so they come while the screen is up; then `simulation: loaded in`, the models' index.
- Loading a save: the window's Load and Continue now load behind the load screen
  (`App::start_load_save`: the simulation's thread loads the save, the map is shown as after a
  new game). Commands keep `load` / `load-sim` at once; `load-sim async PATH` loads behind the
  load screen and `loaded` waits for it.
- Switches: on in the window, off when the renderer is driven by commands (`--script`,
  `--listen`: the frames compare with the game's); STELLAR_LOAD_CONSOLE=1 / =0 forces it; the key
  ` (`toggle_console`, any screen); the command `console on|off`.

Checked on .24: a medium new game and a save loaded behind the load screen with `console on`
(the stages coming in as they end), the default off when scripted, the tint.

## 8. Not done

- The game's own frames of its load screen (the headless path writes gamestates, not frames): the
  load screen's picture scaling and the status window's place are unverified against a game
  frame.
- RestoreDeviceObjects' steps (models, map textures) are two frames here, not ~25.
- The fallen empires' 20..70 progress (the generator makes none yet).
- Generated fleets: `fleets 0` in the galaxy read after the start (the start script's
  `create_fleet` and the ship designs are the effects session's).
