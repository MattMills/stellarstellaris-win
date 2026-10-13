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
| unsynced | `CAICore::_Random` | `random_seed` / `random_count` (in the country's AI block) | restarted at position = seed = the country id, unless `-loadrandomseed` |
| synced | `CCountryAI::_SyncedRandom` | `synced_random_seed` / `synced_random_count` | always restored |

The AI draws nothing from the synchronized generator **[V]**.

## Command-line options

| option | effect |
|---|---|
| `-loadrandomseed` | keep the save's `random_seed` / `random_count` (read in `CGameState::ReadMember`) instead of reseeding at load; it sets `g_bUseSavedRandom` (read at `0x15092e`), which also restores each AI's unsynced generator **[V]** |
| `-rng_seed=N -rng_pos=N` | force the synchronized generator's seed and position (`CGameState::InitPostRead`) **[V]**. `-rng_seed=64429129 -rng_pos=0` reproduces a real play session from its starting save (below) |
| `-random=N` | the seed `CFrontEndIdler::SetAsCurrentIdler` uses instead of the clock **[V]** |
| `-threads=N` | not an RNG option, but it matters for reproducibility. `InitTaskSystem(int)` (GOG `0x1b39aa0`, Linux `0x4294ea0`) clamps N to [4, the usable threads]; the default (-1) is the usable threads − 1. So `-threads=1` means 4 threads, not 1 **[V]**. With many threads the AIs' unsynced generators are drawn in a varying order and runs drift apart: 4 to 1,568 lines in 180 days with the default, 23 threads on the 24-thread test box **[V]** |

With `-loadrandomseed -threads=1` (4 threads), runs from a save were byte-identical over 180 days.
A 360-day pair differed in one AI's unsynced `random_count`, by 4: thread ordering left over **[V]**.
Whether `-Threading.EnableTaskThreads=false` (`NPdxThreadUtilDetail::g_bEnableTaskThreads`, read by
the task scheduler's parallel-fors) runs that work on the main thread, and so removes the rest, is
untested.

## What a normal load does **[V]**

1. A single-player load reseeds from the clock: `CFrontEndIdler::SetAsCurrentIdler` sets `CSystem::_nSeed = CProfile::GetCPUTime()` (unless `-random=N`) and `_nRandomCount = 0`.
2. After the load, `CGameSetup::StartSyncPlayers` posts `CSetRandomSeed(_nSeed, _nRandomCount)`.
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
