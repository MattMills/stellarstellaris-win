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

## 5. Not done

- The game's own frames of its load screen (the headless path writes gamestates, not frames): the
  load screen's picture scaling and the status window's place are unverified against a game
  frame.
- RestoreDeviceObjects' steps (models, map textures) are two frames here, not ~25.
- The fallen empires' 20..70 progress (the generator makes none yet).
- Generated fleets: `fleets 0` in the galaxy read after the start (the start script's
  `create_fleet` and the ship designs are the effects session's).
