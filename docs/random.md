# Random numbers (4.5.2)

The game's random number generators: what they are, how they're seeded and saved, the
command-line options that control them, and where the draws go. From the GOG 4.5.2 build, and from
the real Linux 4.5.2 game run headless (`headless/`). **[V]** = read in the disassembly or measured
in the headless game; **[I]** = inferred. More detail:
- `headless/README.md`: the sections "Determinism", "Against the game's own saves" and "The random pools, traced";
- `docs/ai.md` section 1: the AI's own generators;
- `sim/src/rng.rs`: the algorithm, with test vectors.

## The generators

**The synchronized generator** `CRandom::_Random` (`0x310cb68`) is a `CNoiseRandom { uint32
position; uint32 seed }` **[V]**:
- **Algorithm:** a draw hashes (position, seed) with Squirrel3 plus a fourth round (constants `0xB5297A4D`, `0x68E31DA4`, `0x1B56C4E9`, `0x92D68CA2`), advances the position, copies it to `CSystem::_nRandomCount`, and returns the low 31 bits.
- **State:** the whole state is the save's top-level `random_seed` and `random_count`.
- **Draw functions:** `CRandom::GetIntegerForMacro` (`0x1a760a0`, 1,024 call sites) and `GetIntegersForMacro` (`0x1a762d0`, several values at once).
- **Forbidden zones:** draws are forbidden inside `CModifierNodeManager::Update` and the parallel phases (`_InForbiddenZone`).

**Each AI country also has two generators of the same kind** **[V]**:

| generator | field | save keys | on load |
|---|---|---|---|
| unsynced | `CAICore::_Random` | `random_seed` / `random_count` (in the country's AI block) | restarted at position = seed = the country id; `-loadrandomseed` is read as restoring it, but see below |
| synced | `CCountryAI::_SyncedRandom` | `synced_random_seed` / `synced_random_count` | always restored |

The AI draws nothing from the synchronized generator **[V]**.

The headless game runs with `-loadrandomseed`. Yet its AI tradition picks over 180 days from
2210.01.01 are those of an unsynced generator restarted at the country id: 2 of 2 (country 49:
commercial enterprise, 16777219: war games). The save's position gives 1 of 2. So the unsynced
generator is not restored by `-loadrandomseed` after all, or is restarted after the load **[I]**.
The simulation restarts it at the id.

The read does restore it. `CCountryAI::ReadMember` writes the two saved values under
`g_bUseSavedRandom` (`0xb763dc`, `0xb7641b`) onto `CAICore::_Random`'s position and seed (`+0x32c`,
`+0x330`) **[V]**. So something resets it to the country id after the read: an `InitPostRead`, an
AI re-initialization after the load, or the load path itself. That is not traced yet.

## Command-line options

| option | effect |
|---|---|
| `-loadrandomseed` | keep the save's `random_seed` / `random_count` (read in `CGameState::ReadMember`) instead of reseeding at load; it sets `g_bUseSavedRandom` (read at `0x15092e`), read as also restoring each AI's unsynced generator, which the headless runs contradict (above) **[V]** |
| `-rng_seed=N -rng_pos=N` | force the synchronized generator's seed and position (`CGameState::InitPostRead`; either one sets `g_bUseForcedSeed`, and the other then defaults to 0) **[V]**. `-rng_seed=64429129 -rng_pos=0` reproduces a real play session from its starting save (below). The value is read with `CString::GetInt` (`atoi`, which clamps on overflow), and the command line is split at every `-`. So a seed the save shows as negative can't be passed: its unsigned form becomes 2147483647. Only `-loadrandomseed` reuses such a seed **[V]** |
| `-random=N` | the seed `CFrontEndIdler::SetAsCurrentIdler` uses instead of the clock **[V]** |
| `-threads=N` | not an RNG option, but it matters for reproducibility. `InitTaskSystem(int)` (GOG `0x1b39aa0`, Linux `0x4294ea0`) clamps N to [4, the usable threads]; the default (-1) is the usable threads − 1. So `-threads=1` means 4 threads, not 1 **[V]**. With many threads the AIs' unsynced generators are drawn in a varying order and runs drift apart: 4 to 1,568 lines in 180 days with the default, 23 threads on the 24-thread test box **[V]** |

With `-loadrandomseed -threads=1` (4 threads), runs from a save were byte-identical over 180 days.
A 360-day pair differed in one AI's unsynced `random_count`, by 4: thread ordering left over **[V]**.
Whether `-Threading.EnableTaskThreads=false` (`NPdxThreadUtilDetail::g_bEnableTaskThreads`, read by
the task scheduler's parallel-fors) runs that work on the main thread, and so removes the rest, is
untested.

## What a normal load does **[V]**

1. A single-player load reseeds from the clock: `CFrontEndIdler::SetAsCurrentIdler` sets `CSystem::_nSeed = CProfile::GetCPUTime()` (unless `-random=N`) and `_nRandomCount = 0`.
2. After the load, `CGameSetup::StartSyncPlayers` (from `CGameSetup::Start`, in single player too) posts `CSetRandomSeed` with `g_nGameDebugRandom` when it is ≥ 0, else `_nSeed`, and the current `_nRandomCount`.
3. Its `Execute` calls `CRandom::SynchronisedSeed`.
4. The load itself draws 112 values.

So every session has its own seed. The 2210 saves show four:

| seed | in the saves |
|---|---|
| 6366252 | 2200.01.11 |
| -386941723 | 2210.01.01 |
| 64429129 | 2210.07.01 to 2211.07.01 |
| -324498909 | 2212.01.01 and 2212.07.01 |

The game is deterministic from a load. Seeded as the real session was, the headless game turns
2210.01.01 into the game's 2210.07.01 save except the human player's event answers (79 of 1.17 M
lines), with `random_count` exactly 4,755,436.

A reload is not transparent. A mid-session save plus N ticks is not what the session did: the
load draws 6 more values on the first day, and 143,841 lines differ after 180 days.

## A new game

Galaxy generation (docs/newgame.md section 2) takes its galaxy seed from one draw of the global
stream, and the systems' contents from the global stream as it goes. So `-random=N` makes the same
galaxy only if the main menu draws the same values before generation starts. The menu draws from
the global stream in these places **[V]**:
- `CGameSetupView::EditEmpireDesign`: one draw, then `CEmpireFlag::Randomize`. The `CCoopSPSetupView` and `CMPGameSetupView` versions draw too.
- The empire designer's randomizers: `CNameListEditor::*`, `CTraitSet::Randomize`, `CCountryEthos::Randomize`, `CSpecies::Randomize*`.
- The store's ship previewer: `CAdditionalContentShipPreviewer::SetShip`.

Generation itself allows draws off the main thread (`CRandom::_MultithreadAllowed`, set by
`CGameState::GenerateNewGalaxy`) **[V]**. Whether that reorders them is untested.

The command-line side of this (`-random`, `-rng_seed`, `-rng_pos`) is in
docs/stellaris-command-line-args.md, "Random numbers".

## Where the draws go **[V]**

2210.01.01 + 1,798 ticks, `HEADLESS_PROFILE=1`: 4,755,324 draws, about 26,400 a day.

| | draws | what reads them |
|---|---|---|
| MicroUpdate's ship pool | about 25,200 a day: one value per live ship (every entry of `ships=`) per tick | each value seeds that ship's `CCrudeRandom` in `CShip::MicroUpdateParallel`, used only when its fleet is in combat: 960 of 4.5 M mattered |
| the daily pool (`DailyUpdate`, `0x25e6a0`) | 1,000 a day | each object reads `pool[(id + K) % 1000]` (K fixed per kind) as the seed of the scope its daily scripts run in: 13,605 reads a day |
| the monthly pool | 1,000 a month | the same for countries and colonies: about 1,200 reads a month |
| everything else | about 170 a day and 350 a month | countries, planets, colonies, archaeology, commands |
| ProcessAI | 0 | the AI uses its own generators |

No rendering, entity, particle, sound or GUI code draws from the synchronized generator: 1,056 call
sites in 599 functions were checked.

## In the simulation

- `save::random_of` starts the synchronized generator from the save's state. The diff can take the second save's seed from position 0 instead (`STELLAR_RANDOM=target`).
- The micro phase advances the position by the ship count each tick (`RUST.skip`), since the ship pool's values matter only in combat.
- The daily and monthly pools are drawn where the game draws them (`RUST.daily_pool`, `RUST.monthly_pool`).
- The AI's unsynced generator restarts at the country id, as a loaded game does without `-loadrandomseed` (`sim/lua/engine/ai/rng.lua`).
- The draws of engine updates whose own work is not modelled are made where the game makes them, and their values dropped (`sim/lua/engine/draws.lua`), each checked against the headless trace of every draw **[V]**:
  - per country, in `CCountry::DailyUpdateSerial`: the pop factions module (1), the special projects (2 per project, 2 more while a pending one waits for its `ai_research_date`), `UpdateEnvoys` (1, after the research);
  - one per owned planet in `CPlanetManager::DailyUpdate` (the bombardment's scope);
  - `OnEthicsDivergence` (2 per pop group whose ethics changed), made at the start of the next serial phase;
  - archaeology: one value per site (its excavation pool), then one per site;
  - monthly, per country: the grand archive module (1), a personality for a country without one (1), `HandleForcedSpeciesIntegration` (1).
- MTTH events draw nothing from the global stream: a country rolls from `CCrudeRandom(pool[(id + 4696) % 1000])`, `GetInt64 % 1,000,000` per event whose trigger is met (`simscript/events.lua`).
- Fleets and colonies **[V]**:
  - a fleet entering or leaving a planet's or starbase's orbit: 2 draws and `on_fleet_enter_orbit` / `on_fleet_leave_orbit` (`engine/fleets/orders.lua`); a move to a point is done within 1.0 of it, as `CMoveToSystemPointFleetOrder::IsDone` has it, so the orbit sub-orders finish;
  - each ship of a fleet entering a system: 3 draws and `on_entering_system_first_time` (the country then added to the system's `discovery`) or `on_entering_system` (`CGalacticObject::DoShipEnter`, `engine/fleets/movement.lua`);
  - the fleets newly in a country's sensor range (sorted, not its own; in FTL only to or from its space): 2 draws and `on_fleet_detected`, after its events (`engine/draws.lua`);
  - a colony's pulses: one draw each for `on_colony_monthly_pulse` (every 30 days since its planet's `colonize_date`), yearly, 5-year and 10-year. Three young colonies and four unowned ones did not match the game's in 60 days (which species or date it reads is not traced) **[I]**.
- The fleets' scripted actions and auto-movement, run as the game runs them (`engine/fleets/actions.lua`, `engine/fleets/automove.lua`; the notes from the disassembly in `docs/re/`) **[V]**:
  - the head of each fleet's action queue on every tick, before the movement (Init once, then Update; the next action on the next tick): `repeat`, `find_planet` (closest / random, its trigger looked up by id), `move_to`, `orbit_planet`, `wait`, `effect`; their draws: one when `find_planet` makes a `found_planet` child (the child's scope), one in `random` mode at its Init, one per `wait` made (`GetFixedPointForMacro`, made even with no random part), one for `orbit_planet = random`;
  - auto-movement: an idle fleet in orbit keeps its planet as target (`SaveOrbitTarget`); on its daily update after its orders, a fleet in orbit of its target arrives once: 3 draws and `on_fleet_auto_move_arrival`, the arrival effect, the kill; elsewhere it is sent back with an orbit order; a new order clears a target set with `clear_on_new_orders`;
  - a fleet in orbit given a move elsewhere leaves the orbit at once (`CFleetMovementManager::OnMoveOrderChanged`: 2 draws, `on_fleet_leave_orbit`);
  - the effects `queue_actions`, `clear_fleet_actions`, `auto_move_to_planet`, `remove_auto_move_target`.
  find_system, find_fleet, attack, merge, destroy_planet and terraform actions are not modelled (a repeat holding one ends), nor the fleet targets of auto-movement (armadas).
- Not made yet: `CCountry::CreateAndAddDefaultShipDesign`, `UpdateVisited`'s events, contacts, ships merging into fleets, combat; some fleets arrive a tick or a day apart from the game's. Over 60 combat-free days from 2210.02.01 the simulation ends 194 draws short of the game (394 before the fleet actions and auto-movement, 903 before the fleet and colony draws, about 8,000 before any of these).
