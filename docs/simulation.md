# Simulating the game's progression (4.5.2)

What the game does to advance time, and what a simulation outside the game would have to do, given
that the PDXScript layer in Lua (parsing and evaluating triggers, effects and script values, see
[script_engine.md](script_engine.md)) is correct and complete. Everything else is engine work:
this document finds it, sizes it, and splits it by the project's rule:

- **script effects** change state the script layer owns (flags, variables, saved event targets,
  scripted lists, the event queue): Lua does them entirely, consistent at once;
- **engine effects** need the engine (ships move, pops grow, combat, the economy): they cross a
  queued Lua -> engine boundary drained at fixed points of the tick.

Reverse engineered statically from the GOG 4.5.2 build and its PDB (names, class layouts), its call
graph and its disassembly, on hippo (`/root/fnm_tmp`). Addresses are GOG RVAs. **[V]** marks what
was verified in the disassembly or the call graph (the address or the call is given), **[I]** what is
inferred from names, call lists or the script files. Nothing was measured at runtime.

Sizes are x86-64 instruction counts of the optimized build (the call graph's per-function count).
As a rough rule, one line of game C++ is 5 to 10 instructions here, after inlining **[I]**.

The Rust skeleton built on this is in [`sim/`](../sim) (section 6).

## In short

- **One tick**, `CGameState::HandleTurnTick` (`0x252830`), runs 10 times per game day. Every tick:
  `MicroUpdate` (movement, combat). On the 4th tick of a day: `ProcessAI` (once a day). On the 10th:
  the date advances 24 hours, then `DailyUpdate`, then `MonthlyUpdate` if the month changed, then
  `YearlyUpdate` if the year changed **[V]**. (This refines [main_loop.md](main_loop.md):
  `MicroUpdate` runs on every tick including the day tick, and the AI once a day, not on every
  other tick.)
- **The day is a fixed pipeline** of about 40 phases. Each object kind has the engine's own split:
  `...OnlyChangeSafePrivate` and `...SelfDontReadOthers` run in parallel and may only write the
  object itself, `...Serial` runs on the main thread and does everything that touches other
  objects (kills, events, transfers) **[V]** (names) / **[I]** (the contract). A serial simulation
  in the same order gives the same result.
- **One random number generator** for everything synchronized: `CRandom::_Random`, a counter-based
  noise function (Squirrel3 with a fourth round) over `{position, seed}` **[V]**, saved in the game,
  1,024 call sites. Parallel phases do not draw: the day draws a pool of 1,000 values first and
  hands it to the parallel per-object updates **[V]**. The save holds the generator's state
  (`random_seed`, `random_count`, the position); the simulation starts from it
  (`save::random_of`). A single-player load reseeds from the clock (`CFrontEndIdler::SetAsCurrentIdler`,
  unless `-loadrandomseed`) **[V]**: the game's 2210.07.01 save has another seed than 2210.01.01
  and a count of 4,755,436 since that load (`STELLAR_RANDOM=target` takes its seed from position 0).
  The draws of a day (headless/README.md, measured): about 25,200 are MicroUpdate's ship pool,
  one value per live ship every tick, which seeds only ships whose fleet is in combat (the
  simulation skips them, `RUST.skip`); then the daily pool of 1,000 (every value read:
  `pool[(id + K) % 1000]` seeds the scope of each object's daily scripts), about 170 more in the
  day, and each month a pool of 1,000 and about 350 more. The AI draws none of it (its own
  generators). Over 180 days the simulation draws 4,691,982 against the game's 4,755,436.
- **Out-of-sync checks** (`NOosChecksums::CalcChecksums`, 131 slots) hash the RNG seed and draw
  count, every object database's members, country stockpiles, pop groups, construction queues,
  fleet paths and orbit positions, ship health, flags **[V]** (globals and helpers referenced).
- **Engine size.** Game logic reachable by direct calls from `HandleTurnTick` is about 0.68 M
  instructions (9,134 functions, plus 0.61 M of shared containers, task scheduler and library
  code); the AI (0.19 M) and code behind virtual calls (fleet orders, each object's
  `CalculateModifier`, economic unit templates) come on top: **about 1.0 to 1.3 M instructions,
  100,000 to 200,000 lines of C++** for a full simulation **[I]**. The whole executable is 8.3 M.
- **Script <-> engine.** Of 1,080 effects, about 470 are script effects (flags, variables, event
  targets, control flow and list iterators, event scheduling) and about 610 engine effects; of 1,098
  triggers about 290 read script state or are logic, about 810 read engine state **[I]** (by name).
  The engine calls into script from about 290 places (on_actions, events, weights, triggered
  modifiers).
- **The script layer runs in the simulation** (section 7): PDXScript through embedded LuaJIT, with
  every vanilla event, on_action, scripted trigger, effect and value loaded from the install in
  place; 80.9% of vanilla trigger uses and 70.8% of effect uses are evaluated by the Lua layer, the
  rest is recorded by keyword, count and first location.
- **A minimal simulation** that makes progression meaningful: date and RNG, script state and events
  (Lua), modifiers (the Lua graph), the economy, pops and jobs, colonies with buildings and
  districts, construction, research, leaders and country upkeep. Fleets, combat, diplomacy, AI and
  the content systems (situations, archaeology, storms) are deferred (section 5).

## 1. The progression loop

### Where it runs

`CSession::ProcessSynchronousCommands` executes the frame's queued commands in order: player and AI
commands first, then a `CTurnTickCommand` whose `Execute` tail-jumps to `HandleTurnTick` (see
[main_loop.md](main_loop.md)). So a simulation's input is a stream of commands between ticks; AI
decisions are commands too (`CCountryAI::DailyUpdate` calls `CCountryAI::AddAICommandForPosting`
**[V]**; they are posted to the session and executed like a player's **[I]**).

### Per tick: `CGameState::HandleTurnTick` (`0x252830`, 670 instructions)

In order **[V]** (call sites in the function):

| # | when | what |
|---|---|---|
| 1 | every tick, multiplayer | `NOosChecksums::MakeSyncCheck` (`0x252892`) with the checksums the tick command carries: the check is of the state after the previous tick |
| 2 | every tick | `_nTickCount` (`+0x8`) += 1; the random log frame is set (`CRandomLog::SetFrame`) |
| 3 | `_nTickCount % 10 == 0` (the day tick) | `CConsoleCommandRunner::Update`; the autosave check (below); `_nTickCount = 0`; `_CurrentDate += 24` (hours) at `0x252b15`; every `N+1` days (`N` at `0x28888d4`) `HandleRandomLogTurnTick` |
| 4 | every tick | `UpdateDatabaseArrays` (`0x2558b0`, the object arrays used for iteration **[I]**) |
| 5 | every tick | `MicroUpdate` (`0x253cf0`), timed |
| 6 | `_nTickCount % 10 == 4` | `ProcessAI` (`0x264600`): `cmp r14d, 4` at `0x252c7c`. Once a day, six ticks before the next day |
| 7 | day tick | cache the date: year `+0x118`, day of month `+0x120`, month `+0x128`, julian day `+0x12c`, day of year `+0x124`, 30 days per month `+0x11c`; `UpdateDatabaseArrays`; `CTiming::PrepareDailyTick` |
| 8 | day tick | `DailyUpdate` (`0x25cde0`) |
| 9 | day tick, month changed | `MonthlyUpdate` (`0x261620`): month compared with the value cached before step 7 (`0x252e24`) |
| 10 | day tick, year changed | `YearlyUpdate` (`0x262ee0`) (`0x252ed7`) |
| 11 | day tick | `UpdateDatabaseArrays`; `CInGameIdler::OnDailyTick` (UI) |
| 12 | every tick | multiplayer ping command, `CGameStateTimer::Tick`, `CLogEmpireStats::Tick`, a yearly autosave on day 0 of a year at an interval, a check at year 2600 (`cmp eax, 2600`, `0x2531d4`, end-game **[I]**), game-over timers |

`RenderFrameIfNeeded` runs between the steps (the UI keeps drawing inside a long day).

The autosave check (step 3) computes a level for the new date: 2 when the month changes, 3 when the
month index is a multiple of 3, 4 for a multiple of 6, 5 for a new year, and posts a save command
when the setting (or 3 in ironman) is at most that level **[V]** (the arithmetic) / **[I]** (the
meaning of the levels).

The date is `int` hours (`_CurrentDate`, `+0xc0`); years have 12 months of 30 days
([main_loop.md](main_loop.md#dates)).

### `MicroUpdate` (every tick, 1,021 instructions)

First call sites in order **[V]**: `GenerateGalacticMap` (when needed), `CGalacticMapCache::Update`,
a parallel-for, `CFleetCombatManager::CheckForNewCombats`, `CTargeting::BuildPotentialTargetsData`,
`CFleet::MicroUpdateSerial`, `CFleetMovementManager::MicroUpdate` (`0xe25160`: parallel fleet
updates, `CFleetMoveUpdateFunc`, `UpdateFleetMovementSerial`, parallel `SShipMoveUpdateFunc` and
`SShipMoveFinalizeFunc`), `CShipAura::MicroUpdateAuras`, `UpdateShipParallel` (which draws random
numbers with `GetIntegersForMacro`), `CShip::MicroUpdateSections` (weapons), `CStrikeCraftManager::
MicroUpdate`, `CMissileManager::MicroUpdateSerial`, open events that should abort
(`CEvent::ShouldAbort`, `RemoveEventMessage`), `CCountryGuiCacheCollection::Collate`.

So movement and space combat advance per tick (10 steps a day); everything else per day or month.

### `DailyUpdate` (3,335 instructions)

The phases in order **[V]** (call sites; "par" = a parallel-for or task graph, "ser" = serial):

| # | phase |
|---|---|
| 1 | `UpdateAllTickPrecalcs`; open player events: default option on timeout (`SelectDefaultOptionForOpenPlayerEventAtIndex`), message expiry |
| 2 | `CCountryAI::UpdateAttitudesThreaded` |
| 3 | wars, ser: `CWar::DailyUpdateSerial`, `CWar::OnEnd`; `CWarOverviewList::DailyUpdate` (UI) |
| 4 | federations: par `CFederationProgression::UpdateTriggeredFederationModifiers`; ser `CFederation::DailyUpdateSerial`, `End` |
| 5 | `CInGameIdler::UpdatePlayerAlliance` |
| 6 | par, a task graph of 22 tasks (`lambda_2` to `lambda_23`): flag expiry (`CPdxIntegerFlags::UpdateFlags` in `lambda_3`; the others **[I]** the same for other holders); then `UpdateFlags` of archaeological sites, espionage operations, agreements |
| 7 | par `CJobType::CalcSystemModifiers` |
| 8 | `CAmbientObject::DailyUpdate`, `CConstructionManager::DailyUpdate` (queue items, queues, cached data), `CStarbaseManager::DailyUpdate` |
| 9 | **the random pool**: 1,000 draws of `CRandom::GetIntegerForMacro` into a stack array (`0x25e6a0`-`0x25e6be`) |
| 10 | par `CBypass::CalcConnections` |
| 11 | **`CModifierNodeManager::Update`** (`0x25e898`) |
| 12 | countries, par: `DailyUpdateOnlyChangeSafePrivate` (event chances: `CStandardEventCountryModule::DailyUpdateOnlyChangeSafePrivate` -> `CEvent::GetChance` **[V]** callers), intel and detection caches, terra incognita, fleets in sensor range, `CSpyNetwork::DailyUpdateThreaded`, status caches, bypass access, `DailyUpdateSelfDontReadOthers` (ethics drift, starbase capacity, cached empire data, relation cache, `CDelayedEventManager::DailyUpdateThreaded`, `CIntelManager::DailyUpdate`); `CCountry::CalcVictoryRankings` |
| 13 | countries, ser: `DailyPreupdateSerial`, dead countries killed, `DailyUpdateSerial` (866 instructions: notifications, relay and waystation networks, contacts, policies, surveyed deposits, leaders, **country events** via `CCountryEventManager::DailyUpdateSerial`, diplomacy `HandleIncomingDiplomacy` / `HandleProposedDiplomacy`, bypass locks, elections, **research** `CTechnologyStatus::DailyResearch` and `QueueResearch`, `CGovernment::DailyUpdateSerial`, espionage, leased fleets, envoys, crisis progression), `CCountryFocusManager::DailyUpdate` |
| 14 | `CContractManager::DailyUpdate`, missions killed, **`CModifierNodeManager::Update`** (`0x25eec3`), `CAgreementManager::DailyUpdate` |
| 15 | sectors: par, then `CSector::DailyUpdateSerial` |
| 16 | galactic objects: par (map shield, `CDelayedEventManager::DailyUpdateThreaded`, `UpdateTriggeredModifiers`), par cleanup of dead fleets/ships in lists, ser `CGalacticObject::DailyUpdateSerial` |
| 17 | planets and colonies: `CPlanetManager::DailyUpdate`, `NColonyUpdate::DailyParallelUpdate` (`CColony::DailyUpdateSelfDontReadOthers`: invalid pops, employable pops, buildings, species cache, triggered modifiers, pop triggered modifiers, unemployment, slavery, planet event chances), `NColonyUpdate::DailySerialUpdate` (`CColony::DailyUpdateSerial`: jobs `NPlanetJobs::UpdatePopJobs`, colony on_actions, **construction** `DailyUpdateSerialHandleConstruction`, events, branch offices, **ground combat** `DailyUpdateSerialHandleCombat`), `MonthlyOrDailyUpdatePopJobsInColony` |
| 18 | trade deals: `CTradeDeal::DailyUpdateSerial`, expiry |
| 19 | buildings, zones, districts, waystation networks: per-object daily lambdas |
| 20 | pop groups: par `DailyUpdateOnlyChangeSafePrivate`, `DailyUpdateSelfDoNotReadOthers` (enslavement); ser: `CPopGroup::AddSize` (pending size changes), empty groups killed, `CPopGroup::DailyUpdateSerial` (ethics divergence, factions membership); dead pop jobs killed |
| 21 | ships: par, then par `CShip::DailyUpdateSelfDontReadOthers` **with the random pool**, ser `CShip::DailyUpdateSerial`, starbases destroyed, ships killed |
| 22 | fleets: par `CFleet::DailyUpdateSelfDontReadOthers`, par `UpdateTriggeredModifiers` and `CalcCanRepairFromOrbit`, par `CFleet::DailyUpdateHandleOrderPathfinding` **with the pool**, ser `CFleet::DailyUpdateSerial`, fleets killed, fleet templates cleaned |
| 23 | armies: par `CArmy::DailyUpdateSelfDontReadOthers` with the pool, par triggered modifiers, ser `CArmy::DailyUpdateSerial`, kills; deposits killed |
| 24 | pop factions: par `DailyUpdateSelfDoNotReadOthers`, `DailyUpdateCachedValues`; ser `CPopFaction::DailyUpdateSerial`, kills |
| 25 | `CMegaStructure::DailyUpdateSerial`, `CAstralRiftManager::DailyUpdate` |
| 26 | leaders: par `DailyUpdateOnlyChangeSafePrivate` and `DailyUpdateSelfDontReadOthers`, both with the pool; ser `CLeader::DailyUpdateSerial`, deaths |
| 27 | kills: debris, galactic objects, ambient objects, megastructures, astral rifts |
| 28 | `CalcBorders` when flagged; achievements; claims view |
| 29 | `CheckForWinner`, `CMarket::DailyUpdate`, `CSlaveMarketManager::DailyUpdate`, `NSectorManager::Update`, archaeology, espionage operations, `CGalacticCommunity::DailyUpdate`, event history, cosmic storms, psionic auras, `CGuiCacheManager::DailyInvalidate` |

### `MonthlyUpdate` (1,321 instructions)

First call sites in order **[V]**: `CTradeDeal::MonthlyUpdateSerial`, imperial authority
(`CGalacticCommunity::CalcImperialAuthorityMonthlyChange`), market caches and fluctuations,
**`CModifierNodeManager::Update`** (`0x26195f`), **the budget**
`CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>` (income, upkeep, stockpile; see
[modifiers.md](modifiers.md#the-economy)), par `CCountry::MonthlyUpdateSelfDontReadOthers` (with
random values), par `MonthlyUpdateStrategy`, par `MonthlyCopyAttitudes`, par
`CShip::MonthlyUpdateSelfDontReadOthers`, ser `CCountry::MonthlyUpdateSerial` (843 instructions:
subject integration, relations, leader experience, AI personality, decadence, crisis status,
loyalty, `CCountryEventManager::MonthlyUpdateSerial`, an on_action, situations, planet automation,
council agenda), `CAgreementManager::MonthlyUpdate`, `CPlanetManager::ProcessUpdateData`,
**`NColonyUpdate::MonthlyUpdate`** (pop groups that can procreate; par
`NColonyUpdate::MonthlyParallelUpdate` (auto-migration `CColony::CalcAutoMigrationSafePrivate`);
ser `MonthlySerialUpdate` -> `CColony::MonthlyUpdateSerial`: invalid buildings and districts,
`ApplyAutoMigrationResults`, **`ApplyMonthlyAssembly`, `ApplyMonthlyDecline`** (pop growth),
occupation armies; `NPlanetJobs::UpdatePopJobs`), starbases (par, ser), federation progression (XP,
levels, laws), `CWar::UpdatePassiveWarExhaustion`, ships collecting from stockpiles, cosmic storms,
psionic auras, `CFleet::CheckShipsMonthlyDamage`, and the global pulse
`COnActionDatabase::PerformEvent` (`on_monthly_pulse` **[I]**).

### `YearlyUpdate` (574 instructions)

`COnActionDatabase::PerformEvent` (the yearly pulses **[I]**), `CShipDesignManager::
ClearUnusedShipDesigns`, `CFleetTemplateManager::ClearInvalidFleetDesigns`, telemetry, timing dumps
**[V]**. Vanilla's periodic on_actions (`common/on_actions`): `on_monthly_pulse(_country)`,
`on_yearly_pulse(_country)`, `on_bi_yearly_pulse(_country)`, `on_five_year_pulse(_country)`,
`on_decade_pulse(_country)`, `on_mid_game_pulse`, `on_late_game_pulse`, `on_colony_monthly_pulse`,
`on_colony_yearly_pulse`, random pulses; their names are strings in the executable **[V]**, which
caller fires which was not traced.

### `ProcessAI` (once a day, 249 instructions)

Creates a `CCountryAI` for countries without one, `RefreshModules`, then `UpdateAIParallel` ->
`ParallelFor<CUpdateAIFunctor>` **[V]**: per country `CCountryAI::Update` (`CAICore::Update`),
`DailyUpdate` (`CAICore::DailyUpdate`, commands collected with `AddAICommandForPosting`),
`MonthlyUpdate` (budgets) **[V]** (callees). The AI's ministers (`CAIInteriorMinister`,
`CAIMilitaryMinister`, `CAIEconomicStrategy`, ...) are reached through virtual calls.

### The parallel discipline

Every object kind follows the same pattern **[V]** (names): `DailyUpdateOnlyChangeSafePrivate`
(par, reads others, writes only private caches), `DailyUpdateSelfDontReadOthers` (par, writes
itself, reads nothing else), `DailyUpdateSerial` (ser, anything). `g_nThreadSafetyState` is set
around the parallel phases (128 around the ship phase, `0x25f5f2`) and random draws are forbidden in
them (`CRandom::_InForbiddenZone`, below). So the result does not depend on thread scheduling, and a
serial simulation that keeps the phase order (all objects' parallel part, then all objects' serial
part, in database order) reproduces it **[I]** (the contract is enforced by debug checks, not
proven).

## 2. Subsystem inventory

"Census" is the instruction count of the subsystem's own classes (every method, including reading
the database files and some UI-facing getters; by class name). "Closure" is the game-logic code
reachable by direct calls from the named roots (inclusive and overlapping: everything reaches
`CCountry`). Both are rough. Classification: **S** script layer (Lua), **E** engine, **M** mixed.

| subsystem | cadence | state read / written | script fired or evaluated | class | C++ to reimplement (key functions) | size | main data structures |
|---|---|---|---|---|---|---|---|
| date and tick | tick, day | `_CurrentDate`, `_nTickCount`, cached date fields | `is_date`, `years_passed` read it | E (trivial) | `HandleTurnTick`, `CStellarisDate::*` | 670 + small | `CDate` (int hours) |
| RNG | everywhere | `CRandom::_Random {position, seed}` | `random_list`, `random`, `random_*` iterators, weights draw from it | M: one stream shared by script and engine | `CRandom::GetIntegerForMacro` (`0x1a760a0`), `GetIntegersForMacro`, the daily pool | tiny | `CNoiseRandom` (8 bytes) |
| script state | event time; daily expiry | flags, variables, event targets, scripted lists, timed flags | all flag/variable effects and triggers | S; expiry E-side today (`CPdxIntegerFlags::UpdateFlags`, daily task graph) | expiry only | small | `CPdxIntegerFlags`, per-object flag maps |
| events, on_actions, MTTH | daily (delayed, MTTH), on engine call-ins, pulses | delayed event queues per scope object, open player events | event triggers, immediate, options, `mean_time_to_happen`, on_action lists | S with engine call-ins | `CDelayedEventManager::DailyUpdateThreaded`/`Serial`, `CStandardEventCountryModule`, `CEvent::GetChance` (2 callers), `CEventManager::TriggerEvent` (23 callers), `COnActionDatabase::PerformEvent` (263 call sites in engine code) | census 171 k (includes situations, special projects, anomalies, archaeology, rifts, storms); closure 76 k | `CDelayedEvent` lists per object, `CEventScope` |
| modifiers recompute | after every root effect, after commands, twice a day, monthly | each object's modifier node | static/triggered modifiers' triggers, `add_modifier` | M: sources from script; the recompute is E today, planned in Lua ([modifier_graph.md](modifier_graph.md)) | `CModifierNodeManager::Update` (`0x29e250`), every class's `CalculateModifier` (virtual), `AddModifierNode` | census 33 k + the `CalculateModifier`s | `CModifier` (parallel arrays), node registry |
| economy, resources, market | monthly budget; daily market | country stockpiles, budget pages, colony snapshots, market prices | resource table triggers, triggered category modifiers | E (formula known, [modifiers.md](modifiers.md#the-economy); unit by unit, [economy.md](economy.md)) | `CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>` (`0x16605d0`), `ApplyModifiersToTable<N>`, `CCountryBudget::EndMonthlyUpdate`, `CEconomyCountryModule::AddResources`, `CMarket::DailyUpdate`, trade deals | census 208 k; closure 74 k | economic units (22 kinds), categories, `CFixedPoint` tables |
| pops: growth, jobs, migration, happiness | jobs daily and monthly; growth, decline, migration monthly; ethics daily | pop groups (size per species, strata, ethics), jobs, colony employment | job weights, pop growth/assembly weights, `on_daily_pop_ethics_divergence`, pop triggered modifiers | E with script weights | `NPlanetJobs::UpdatePopJobs`, `CColony::ApplyMonthlyAssembly`/`ApplyMonthlyDecline`/`ApplyAutoMigrationResults`, `CalcAutoMigrationSafePrivate`, `CPopGroup::DailyUpdate*`, `CPopGroup::AddSize` | census 134 k; closure (colony updates) 281 k | `CPopGroup`, `CPopJob`, `CSpecies` |
| planets and colonies | daily | planets, colonies, buildings, districts, zones, deposits, habitability | building/district `potential`/`allow`, triggered modifiers, colony on_actions | E | `NColonyUpdate::*`, `CColony::DailyUpdateSerial` (469), `MonthlyUpdateSerial`, `DailyUpdateSelfDontReadOthers`, `UpdateBuildings` | census 212 k | `CPlanet`, `CColony`, `CBuilding`, `CDistrict`, `CZone`, `CDeposit` |
| construction and queues | daily | construction queues and items, colony build slots, starbase and megastructure stages | `potential`/`allow`, costs (economy), `on_built` on_actions | E | `CConstructionManager::DailyUpdate` (`0x8fc700`), `CConstructionQueueManager::DailyUpdate`, `CConstructionQueueItemManager::DailyUpdate`, `CColony::DailyUpdateSerialHandleConstruction`, `CStarbaseManager::DailyUpdate`, `CMegaStructure::DailyUpdateSerial` | census 181 k (starbases, megastructures, designs); closure 63 k | `CConstructionQueue`, items |
| research | daily | tech status, progress, options, queue | tech `weight`, `potential`, `on_tech_increased` | E with script weights | `CTechnologyStatus::DailyResearch` (`0x818de0`), `QueueResearch`, `DoResearchTechnologyCompleted` | census 54 k (techs, traditions, perks) | `CTechnologyStatus` |
| country, leaders, government, sectors | daily, monthly | edicts, policies, elections, leaders (age, XP, death), council, sectors, contacts | many on_actions (`on_leader_death`, elections), edict/policy triggers | E | `CCountry::DailyUpdateSerial` (866), `MonthlyUpdateSerial` (843), `CLeader::Daily*`, `CGovernment::DailyUpdateSerial`, `CSector::DailyUpdateSerial` | census 275 k; closure 326 k (daily serial) | `CCountry` (and its modules), `CLeader` |
| fleets, movement, pathfinding | tick (movement), daily (orders, pathfinding) | fleet positions, orders, paths, orbits, bypasses, sensor and intel | `on_entering_system`, move orders from effects | E | `CFleetMovementManager::MicroUpdate` (`0xe25160`), `CFleet::MicroUpdateSerial`, `DailyUpdateHandleOrderPathfinding`, `CAStarAlgorithm<...>` (hyperlane policies), `CBypass::CalcConnections`, fleet order classes (virtual) | census 268 k; closure 147 k | `CFleet`, `CFleetPath`, `CGalacticObject` graph, A* |
| combat (space and ground) | tick (space), daily (ground) | ship health, targets, weapons, auras, strike craft, missiles; armies | `on_combat_end`, ship and fleet destroyed on_actions | E | `CFleetCombatManager::CheckForNewCombats` (`0xd740e0`), `MicroUpdateSerial`, `CTargeting::BuildPotentialTargetsData`, `CShip::MicroUpdateSections`, `CMissileManager`, `CStrikeCraftManager`, `CColony::DailyUpdateSerialHandleCombat`, `CGroundCombat` | census 139 k; closure 118 k | `CShip` sections, weapons, combat participants |
| diplomacy, wars, federations, GC, espionage | daily, monthly | relations, opinions, wars (exhaustion, war goals), truces, federations, agreements, resolutions, operations, first contact | acceptance (AI), `on_war_beginning`..., resolution triggers/effects | E | `CWar::DailyUpdateSerial`, `UpdatePassiveWarExhaustion`, `CFederation::DailyUpdateSerial`, `CFederationProgression::*`, `CAgreementManager`, `CCountry::HandleIncomingDiplomacy`, `CGalacticCommunity::DailyUpdate`, `CEspionageOperationManager::DailyUpdate` | census 202 k | `CWar`, `CFederation`, `CAgreement`, diplomacy modules |
| factions | daily | faction support, approval, membership | demands (triggers), attraction | E with script | `CPopFaction::Daily*`, `CPopGroup::ValidateFactions`, `PopulateWithTargetedFactions` | census 16 k | `CPopFaction` |
| AI | daily (tick 4), monthly | reads everything, writes commands and its caches | `ai_weight`s, AI budget categories | E | `ProcessAI`, `UpdateAIParallel`, `CCountryAI::*`, ministers | census 187 k (virtual: not in the closure) | `CCountryAI`, `CAICore`, ministers |
| out-of-sync checks | every tick (multiplayer) | reads everything | none | E | `NOosChecksums::CalcChecksums` (1,964), `MakeSyncCheck` (669) | 3 k | 131 x uint64 |
| save and load | on demand | everything | none | E | `CGameState::WriteMembers` / `ReadMember`, every class's | (large) | |

Totals: the census of all game-logic classes is about 2.3 M instructions, of which some is loading
and UI support; the code actually reachable from the tick is about 0.68 M (direct calls only), with
the AI and virtual-dispatch code adding perhaps 0.3 to 0.6 M **[I]**. The script layer's own
classes (triggers, effects, scripted lists, event targets) are about 0.74 M instructions: what the
Lua layer already replaces.

## 3. Determinism

### The random number generator **[V]**

`CRandom::_Random` (`0x310cb68`) is a `CNoiseRandom`: `uint32 position` (`+0`), `uint32 seed`
(`+4`). `CRandom::GetIntegerForMacro(file, line)` (`0x1a760a0`, `0x1a76109`-`0x1a7615e`):

```
n = position; position = n + 1; CSystem::_nRandomCount = n + 1
x = seed + n * 0xB5297A4D          (written as seed - n * 0x4AD685B3)
x ^= x >> 8;  x += 0x68E31DA4
x ^= x << 8;  x *= 0x1B56C4E9
x ^= x >> 8;  x *= 0x92D68CA2
x ^= x >> 8
return x & 0x7FFFFFFF               (31 bits, never negative)
```

These are the constants of Squirrel Eiserloh's "Squirrel3" noise function, with a fourth round
(`* 0x92D68CA2`, `^= >> 8`). It is stateless apart from the position: the n-th draw of a game is a
pure function of (seed, n). The Rust crate implements it (`sim/src/rng.rs`).

- **Draws**: 1,024 call sites in about 570 functions call `GetIntegerForMacro` (the file and line
  are for the random log); `GetIntegersForMacro` (`0x1a762d0`, several values at once) has 5 callers
  (`CArchaeologicalSiteManager::DailyUpdate`, `CEspionageOperationManager::DailyUpdate`,
  `CFirstContact::DailyUpdateSerial`, `CGameState::MonthlyUpdate`, `UpdateShipParallel`),
  `GetFixedPointForMacro` one. Script `random_list`, `random`, `random_*` iterators and weighted
  picks draw from the same stream **[I]** (the effect classes call the same functions).
- **Guards**: before drawing, if `CRandom::_InForbiddenZone` (`0x27ffcb0`) is set, or the thread is
  not the main thread and `CRandom::_MultithreadAllowed` is not set, a lambda reports it (`0x1a760de`,
  `0x1a760f8`). `CModifierNodeManager::Update` and the parallel phases set the forbidden zone.
- **The daily pool**: `DailyUpdate` draws 1,000 values serially (`0x25e6a0`) before its parallel
  phases and passes a pointer to them to the per-object updates through `TFunctorWithRandomValues`
  (`CShip::DailyUpdateSelfDontReadOthers(ship, pool)`: the functor passes its `+8` as the second
  argument, `0x2c9613`). Ships, fleets (pathfinding), armies, leaders (both parallel phases) get it;
  countries get a pool in `MonthlyUpdate`. How an object indexes the pool was not traced (open).
- **Seeding and saving**: the position and seed are written by `CGameState::InitPostRead` (new game),
  `CGameState::ReadMember` (load; `random_seed`/`random_count` are strings in the executable **[I]**
  that they are the keys), `CInGameIdler::LoadSave`, `CFrontEndIdler::LaunchSave`,
  `CSetRandomSeed::Execute` (a command: multiplayer), `CPostHotJoinCommand::Execute`, and saved by
  `CGameState::WriteMembers`. `CreateNewCountryGetPortrait` saves and restores them around portrait
  generation, so UI randomness does not move the stream. `CCountry::CreateShipDesign` reads the seed.
- **Hashes**: `PMurHash32` is used in the daily fleet phase, `MonthlyUpdate` and the checksums: a
  deterministic per-object value, not a draw **[I]** (its use).
- **Numbers**: the economy and modifiers are fixed point (`CFixedPoint`, int64, 1.0 = 100000).
  Movement and positions are floats (orbit coordinates are hashed by the checksums): the same
  binary gives the same results, a reimplementation must match the operation order to match bits
  **[I]**.

### What the checksums cover: `NOosChecksums::CalcChecksums` (`0x912370`)

131 `uint64` slots (`CPdxHybridArray<unsigned __int64, 131>`), labelled by `g_CheckSumLabels`
(`0x23950d0`; the label strings are in `.rdata`, not in the disassembly, not read yet). The globals
and helpers it references, in order **[V]**: `CSystem::_nSeed` and `CSystem::_nRandomCount` (the
RNG), a `CChecksumFile` and a `CWriter` (a serialization written into a hash **[I]**), planets,
countries, colonies (carriers, `CalcNumDistricts`), construction queues, districts, zones, pop
groups (`CalcPopGroupSpeciesChecksum`), agreements, situations, ships and fleets
(`CalcShipChecksum`, `CalcShipHealthChecksum`, `CalcFleetActionsChecksum`), conversion processes,
starbases, pop factions, galactic objects and their flags, country stockpiles
(`CEconomyCountryModule::GetResource` per strategic resource), the diplomacy module, sectors, fleet
paths (`CFleetPath::CalcCheckSum`, `CalcFleetPathChecksum`), orbit positions
(`CalcOrbitCoordinate`), auto-move, species.

`MakeSyncCheck` (`0x914540`) runs at the start of each tick on the checksums the tick command
carries; on a mismatch it generates the OOS data, pauses and posts `CClientOOSDetected` **[V]**.

So a simulation that must stay in step with real clients reproduces bit for bit: the RNG seed and
the number of draws (every draw, in order: one extra or missing `random_list` desyncs), object
identities per database, stockpiles, pop groups, construction queues, fleet paths and positions,
ship health and flags. A standalone simulation only needs to be deterministic with itself.

## 4. The Lua <-> engine interface

### Effects (1,080) and triggers (1,098)

Classified by name from the game's own `effects.log` and `triggers.log` **[I]**:

| effects | count | examples |
|---|---|---|
| script: control flow, tooltips, list iterators | 324 | `if`, `hidden_effect`, `random_list`, `every_owned_planet`, `random_country`, `ordered_*` (iterators read engine lists) |
| script: flags | 93 | `set_country_flag`, `set_timed_planet_flag`, `remove_*_flag` |
| script: event firing and scheduling | 24 | `country_event`, `planet_event`, `fire_on_action` |
| script: variables | 20 | `set_variable`, `change_variable`, `export_modifier_to_variable` (reads the engine) |
| script: event targets and lists | 9 | `save_event_target_as`, `save_global_event_target_as` |
| engine: create, destroy, remove | 140 | `create_species`, `create_country`, `remove_deposit` |
| engine: other | 166 | `set_owner`, `win`, `add_blocker`, `establish_branch_office` |
| engine: diplomacy and war | 76 | `declare_war`, `set_subject_of`, `establish_contact` |
| engine: fleets, ships, armies | 45 | `damage_ship`, `repair_ship`, `add_ship_design` |
| engine: pops and species | 40 | `add_trait`, `modify_species`, `change_background_job` |
| engine: planets, buildings, districts | 39 | `add_building`, `downgrade_buildings_of_type` |
| engine: leaders, government, country | 37 | `set_capital`, `set_name`, `set_policy_cooldown` |
| engine: situations, projects, anomalies | 34 | `add_anomaly`, `add_relic`, `finish_site` |
| engine: economy | 14 | `add_resource_to_local_stockpile`, `transfer_resource_stockpile` |
| engine: research | 12 | `give_technology`, `add_research_option` |
| engine: modifiers | 7 | `add_modifier`, `add_opinion_modifier` (Lua-owned once the modifier graph is the source) |

Triggers: about 810 read engine state (`num_ships`, `has_fleet_order`, `has_technology`, ...), 247 are
logic, list and event target triggers, 37 flags, 3 variables, 5 date and game setup.

The engine calls into script **[V]** (callers): `COnActionDatabase::PerformEvent` from 263 call
sites in engine code (on_actions: colonization, ownership changes, combat, deaths, policies, ...),
`CEventManager::TriggerEvent` from 23 (delayed events, country event modules, colonies,
archaeology, espionage, first contact, research completion, anomalies), and evaluation of script
for engine systems: weights (jobs, pop growth, techs, AI), `potential`/`allow`, triggered modifiers
(daily, per fleet, army, galactic object, colony, federation), resource table triggers, MTTH chances
(`CEvent::GetChance`, in the parallel country and colony phases) and delayed event pre-evaluation
(`CDelayedEventManager::DailyUpdateThreaded` -> `CPreTriggers::PreCalcScopeValues`, `CEvent::IsValid`,
in parallel). In a simulation each of these is a call from an engine subsystem into the
`ScriptHost`.

### Flush barriers

Engine effects are queued; a read of engine state that a pending effect changes needs the queue
drained first. Where the game's script does that:

- **The end of a root effect.** `CRootEffect::Execute` already runs `CModifierNodeManager::Update`
  after every root effect block ([modifiers.md](modifiers.md#recomputation-cmodifiernodemanagerupdate)):
  the game itself treats "an event's effects are done" as the point where derived state is
  refreshed. Drain the queue there.
- **Before iterating an engine list.** `every_*`, `random_*`, `ordered_*` effects also update
  modifiers before iterating: a barrier before a list read.
- **Created objects used at once.** `create_ship` (1,630 uses in vanilla `events/` and `common/`),
  `create_fleet` (873), `create_ambient_object` (789), `create_pop_group` (450), `create_leader`
  (385), `create_country` (332), `create_species` (236); then `last_created_ambient_object` (532
  reads), `last_created_leader` (321), `last_created_species` (264), `last_created_country` (252),
  `last_created_design` (246), `last_created_fleet` (52) in 166 files, and the nested
  `effect = { }` blocks of `create_fleet` / `create_country` that act on the new object. The queue
  returns a provisional handle at once (Lua allocates the id); effects on it queue against the
  handle; a trigger reading its engine state forces a flush.
- **Read after write in one event.** `add_resource` then a resource comparison, `set_owner` then an
  `owner` scope, `add_modifier` then a modifier-dependent trigger: dependency-tracked flushes (a
  pending effect marks what it writes; a trigger that reads it flushes).
- **Events fired immediately.** An event fired without delay from an effect runs inside the effect
  (`CEventManager::TriggerEvent` is called from effect code): its trigger reads engine state: flush
  before firing.
- **Random draws.** Script and engine draw from one stream: Lua draws must happen in the same order
  relative to engine draws as in the game, so either the queue is drained before every script draw
  that follows an engine draw, or the stream is owned by one side and the other asks it.

## 5. A minimal simulation

The smallest set that makes progression meaningful (an economy that grows, events that fire,
technologies that complete), in the game's order:

| keep | why | how |
|---|---|---|
| date, tick, phases | the schedule everything hangs on | `HandleTurnTick` order: micro every tick, AI on tick 4, day on tick 10, month, year |
| RNG | determinism | the noise RNG above, one stream, plus the daily pool |
| script state, events, on_actions, MTTH | the content | the Lua layer (`ScriptHost`): pulses, delayed events, MTTH chances |
| modifiers | every number depends on them | the Lua dependency graph ([modifier_graph.md](modifier_graph.md)), recomputed at the game's points |
| economy | resources drive everything | monthly budget: `out = s * (base + A) * (1 + max(-0.9, G + P))` per unit, stockpiles |
| pops and jobs | the producers | pop groups per species and stratum, job assignment, monthly growth and decline |
| colonies | where pops live | buildings and districts as counts with costs, upkeep and jobs |
| construction | how colonies grow | queues with build time and cost |
| research | progression | daily progress from monthly output, options from weights, completion events |
| country upkeep | edicts, policies, leaders | expiry, leader aging and death |

Deferred: fleets and movement (fleets as stacks with a location; travel time from hyperlane
distance), combat (a strength comparison), diplomacy beyond war state as data, AI (scripted
policies or recorded commands), espionage, the galactic community, the market, situations, special
projects, archaeology, storms (mostly event-driven, Lua can carry them), UI. Out-of-sync parity with
the real game is a later goal: it requires every engine draw in the right order.

Size of the minimal engine **[I]**: the formulas of the economy, pops, jobs, colonies, construction
and research are a small part of their classes' census (about 0.8 M instructions together, most of
it reading, validation and UI support): perhaps 20,000 to 40,000 lines of C++ to reproduce, against
100,000 to 200,000 for everything.

## 6. The engine (`sim/`): Rust the platform, the game in Lua from its own files

The first skeleton modelled the game by hand (a 10-resource enum, job, building and technology
structs, a sample world). That is gone. Nothing of the game is written in the engine; everything
comes from the game's files and a save:

| part | where | what |
|---|---|---|
| platform | `src/runtime.rs` | the LuaJIT state (require paths, `RUST.list_files`, `clock`, `date`, `rand`), `Runtime::load` / `load_world` / `phase` / `save_text` / `eval` |
| | `src/save.rs` | reading a save (`gamestate`, `meta`) and writing one (a zip of both, deflated as the game does) |
| | `src/scheduler.rs` | `HandleTurnTick`: commands, the tick count, the date, `MicroUpdate` every tick, `ProcessAI` on tick 4, and the daily, monthly and yearly phases in the game's order (section 1); parallel phases with random draws forbidden, the daily pool of 1,000 draws |
| | `src/rng.rs`, `date.rs`, `fixed.rs` | the game's RNG, `CDate`, `CFixedPoint` |
| definitions | `lua/engine/defs.lua` | every folder of `common/` of the vanilla file set, read in place the game's way (`stellar.script.source.definitions`): 247 folders, 21,128 definitions |
| script | `lua/simscript/*` | events, on_actions, scripted triggers, effects and values (section 7) |
| world | `lua/engine/world.lua` | the game state from a save's gamestate, kept in the save's own form: every store of id-keyed objects (`country`, `planet`, `pop_groups`, `fleet`, `ships`, `galactic_object`, `construction.item_mgr.items`, ...), fields read with `world.field` / `fields` / `list` / `blocks` / `path`, changes made as edits of the save's tree (`set`, `append`, `create`, `remove`), owners the save keeps only indirectly indexed (`system_owner`, `fleet_owner`) |
| engine interface | `lua/engine/interface.lua` | `E`, what the script layer reads of the engine (answered from the save's own fields; reads nothing answers yet are counted) and the engine effects it queues |
| systems | `lua/engine/systems.lua` | the engine effects applied to the world; per phase, what the engine does: the pulses and daily events through the script layer, the countdowns of flags and timed modifiers; the rest is added phase by phase |
| research | `lua/engine/research.lua` (docs/research.md) | `CTechnologyStatus::DailyResearch` in the countries' serial phase: on the month's second day each area's research (the budget's balance, times 1 + the research speed of the first queued technology) goes to the queue, with the stored points drawn up to the month's research; a technology is done at its cost (`CTechnology::GetCost`: the tier's difficulty scaling, the empire size penalty above the admin cap, the cost modifiers, the galaxy's tech cost); done: the technology added, `on_tech_increased`, the item out of the queue; a special project with a research cost takes the month's research and holds back what is behind it |
| leaders | `lua/engine/leaders.lua` (docs/leaders.md) | the month's experience (`CCountry::MonthlyUpdateSerial`, `CStandardLeaderCountryModule::MonthlyUpdateSerial`): the ruler, the heir, the government's councilors, and every leader not idle (`CLeader::IsIdle`) whose class can have traits; `CLeader::AddExperience`: the experience modifiers (species, class, the council seat), the leader cap penalty, level-ups at `sum(100 + 300 k)` with the experience carried over |
| construction | `lua/engine/construction.lua` (docs/construction.md) | `CConstructionQueue::DailyUpdate`: each queue's first `simultaneous` items advance by their buildable's speed (districts, zones, buildings and upgrades: 1 + `planet_building_build_speed_mult` + `planet_<key>_build_speed_mult` of the colony; armies: 1 + `planet_army_build_speed_mult`); done: a district's level + 1, a zone in its district's slot, a building in its zone, an upgrade's new type (new ids: the next index of the store); ships, starbase items and the armies' creation not modelled yet |
| fleet orders | `lua/engine/fleets/orders.lua`, `fleets/survey.lua` (docs/fleet_orders.md) | `CFleet::HandleOrders` in the daily ships/fleets/armies phase: each fleet's current order and queue in the save's form (`current_order`, `order`, `order_id`), started (`on_ship_order` and its two draws), ticked, finished, the next started the same day; `orders.issue` for the AI (`CFleet::AddOrder`). Surveys: `SCIENCE_SHIP_SURVEY_SPEED_MULT * (1 + science_ship_survey_speed [+ _uninhabitable])` a day in orbit, done at `BASE_SURVEY_TIME * survey_time_factor`; finished: `on_survey_planet`, `surveyed_deposit_holders` (`on_planet_surveyed`), the scientist's experience, `CPlanet::OnSurvey` (`surveyed_by`, `binary_flags`, the anomaly roll: chance, categories by spawn chance, null spawn, `on_spawn`), `on_system_survey(_ship)`, out of orbit; anomaly research (the days by level, the outcome event); orbit and move sub-orders (movement: engine.fleets.movement); station building's progress. Not modelled yet: the stations built, colonization, archaeology, the military orders |
| pops | `lua/engine/pops.lua` (docs/pops.md) | `NColonyUpdate::MonthlyUpdate`: logistic growth per species (`0.0025 (n - n²/K - 1)`, K from housing, free districts and carry capacity, rescaled to the galaxy's ceiling, scaled down with the country's size), colonization, assembly and decline, rounded at random from the month's pool of 1,000 draws (`RUST.monthly_pool`, drawn at the start of `MonthlyUpdate`); the growth bookkeeping in the save's form; the colonies' tables; the day's housing (`pops.daily` in the parallel `pop_groups` phase). Not modelled yet: the jobs update, migration, modding, purges, happiness/power/crime/stability |
| colonies | `lua/engine/colonies.lua` (docs/colonies.md) | the colonies' day (`CColony::DailyUpdateSelfDontReadOthers`, `MicroUpdateCachedValues`: employable and sapient pops, housing, amenities and their usage, stability with the power-weighted average happiness, crime, the civilian and unemployed counts) and the pop groups' (happiness, power, crime from the day before's happiness, amenities usage) in the pop group phase; recomputed after the month's size changes. Not modelled yet: habitability, the jobs update (ethics: below) |
| ethics | `lua/engine/ethics.lua` (docs/ethics.md) | the pop groups' ethics drift (`CPopGroup::EthicChangeSafePrivate`: every 18 days per group a 5% roll from the day's pool, `RUST.daily_pool`; the attraction `pop_attraction * (1 + pop_<ethic>_attraction_mult) * the country's cached attraction`, the values under 1.1 dropped; the target `round(size * a / total)`, 5 to 10% of the group moved toward it with the game's `Resize`; the attraction written only on a roll) and the faction-change remnant `fractions` (`CalculateFactionChange` every 30 days per colony or the day after an ethic change; the subset without factions: -0.004 * size per update), in the pop group phase; the countries' `ethics_attraction` every 30 days in the countries' parallel phase. Not modelled yet: factions themselves (wanted, potential, joining, `CPopFaction`), the country's pops-ethics caches, `OnEthicsDivergence`'s two draws (the pop group phase is parallel) |
| AI | `lua/engine/ai/` | `CGameState::ProcessAI` in Lua (docs/ai.md): the AI's own random number generators (`ai/rng.lua`, the unsynced one restarted at the country's id on load) and, so far, the interior minister's research choice (`ai/research.lua`: `GetTechToResearch`, `GetAIWeight`), its commands executed after every AI decided; the alternatives it picks from are drawn again on a completion (`research.update_alternatives`); the tradition and ascension perk choice on the AI's month (`ai/traditions.lua`, docs/traditions.md: `HandleTraditions`, `HandleAscensionPerks`, the traditions budget); the opinion of other countries (`ai/opinion.lua`: `CalcOurOpinionOfOtherNoScopeCopy`) and the attitudes, each AI every 10 days in the first daily phase (`ai/attitudes.lua`: `UpdateAttitudesThreaded`, `CAIAttitude::CalcAIWeight`); the AI's budget on its month (`ai/budget.lua`: the upkeep and expenditure splits, `CanAffordExpenditure`), the economic plan and the build plan, and the weekly district, building and zone orders paid from the stockpile (`ai/economy.lua`, docs/ai_economy.md: `CalcBestEconomicPlan`, `CreateBuildPlan`, `BuildAndUpgradeDistrictsAndBuildings`) |
| traditions | `lua/engine/traditions.lua` (docs/traditions.md) | the tradition cost (`CTraditionType::CalcCost`: `(300 + (8 n)^1.8)` times the empire size penalty, the cost modifiers and the galaxy's setting), the checks (`IsPossible`, `CanActivate`, completed categories, perk points), adoption (`CCountry::ActivateTradition`: paid, added with its category, `OnEnabled`: one draw, the `on_enabled` effect, `on_tradition_picked`, the finisher) |
| situations | `lua/engine/situations.lua` (docs/situations.md) | the month's progress of every situation (`CSituation::GetMonthlyProgress`: the type's `monthly_progress` MTTH in CFixedPoint, the game's parallel pass after the budget), then per country before its monthly pulse `CSituation::HandleMonthlyTickSerial`: `last_month_progress`, `progress +=`, the stages (`on_enter`, `on_first_enter`), `on_fail` / `on_progress_complete`, the type's `on_monthly` as an on_action, `destroy_situation`. Not modelled yet: creating situations (deficits, `start_situation`), approaches, section weights, the situations' modifiers |
| first contact | `lua/engine/first_contact.lua` (docs/situations.md) | each country's first contacts every day before its events (`CFirstContactsData::DailyUpdate`, `CFirstContact::DailyUpdateSerial`): `days_left -= 1 + first_contact_speed_mult`, the roll (`last_roll` from the CRandom noise of one draw, 80 or 110 days again), the score against 10: the stage event (weighted pick, fired) or `on_roll_failed`; the intel target; the script's `set_first_contact_stage`, `add_stage_clues`, `set_site_progress_locked`, `finish_first_contact` (the envoy released). Not modelled yet: creating first contacts, intel growth, the AI's envoys, most of `EstablishCommunications` |
| exploration | `lua/engine/exploration.lua` (docs/exploration.md) | each country's knowledge of the galaxy in the countries' parallel phase (`DailyUpdateOnlyChangeSafePrivate`, then the shared-intel and terra incognita passes), and once as the load does it: the visited systems; the sensor coverage (colonies, fleets' best ship range, armies, megastructures, enclaves, intel on capitals, surveys; spread over hyperlanes and sensor-extending bypasses, nebulae blocking) into each system's intel level; the known hyperlanes in the game's queue order; the shared intel (federation, subjects; the intel on other countries' territory; complete-sensor countries' alternating cache); terra incognita from the game's pixel table; the fleets in sensor range; the surveys the intel gives, in the serial phase before the country's events. The 2210.01.01 load and its first day equal the headless game in every field of all 55 countries. Not modelled yet: the intel values' daily change, detection and cloaking |
| economy | `lua/engine/economy.lua`, `economy/units.lua` (docs/economy.md, docs/modifiers.md) | `CEconomicUnitManager::CalculateTablesOrUpdateBudget` in the monthly budget phase: every economic unit of every country (jobs, buildings, districts and zones, pop groups, the country, leaders, deposits, starbases, ships, armies, diplomacy) through `ApplyModifiersToTable` with its object's modifier node, into each country's budget by category and resource, then the month's balance to its stockpile within the storage caps; 95.1% of the 2210.01.01 save's budget entries |
| modifiers | `lua/engine/economy/world_source.lua` | by default, every system's modifiers from the rewrite's own graph built from the world (`engine.modifiers.world`), rebuilt in the monthly modifier phase; the modifier types built from the game's files (`stellar.graph.modifiers` `game_definitions`), or read from its `script_documentation/modifiers.log` given in `STELLAR_MODIFIER_TYPES`; with `STELLAR_MODIFIERS=capture` (or no types log), the game's capture (`STELLAR_CAPTURE`) |
| saves | `engine.save()` | the world written back as a gamestate (pdxscript.write over the save's tree), dated today |
| check | `lua/engine/diff.lua`, `examples/diff.rs` | the simulation from one save to the date of a later save the game wrote, compared store by store and field by field |
| renderer | `render/` (`stellar-render`, [docs/render.md](render.md)) | the galaxy map of a save (systems, hyperlanes, owners' colours) with wgpu on Vulkan, headless to a PNG or in a window |

Tests (`tests/world.rs`; skipped without the game's files and the 2210.01.01 save): the vanilla
files and the save load (247 folders, 21,128 definitions, 10,105 events; 55 countries, 6,080
planets, 171 pop groups, 123 systems and 804 fleets with an owner); a month from the save twice is
the same; a save written after a month reads back the same.

Where to run: a Linux machine with the game's data installed (`/opt/stellaris`, `STELLARIS_DIR`) and
the saves (`/opt/stellaris-saves`), `cargo test --release` with a local `CARGO_TARGET_DIR`; on
Windows, `sim\cargo_msvc.cmd`.

Against the game: 2210.01.01 + 180 days against the game's own 2210.07.01 save (`examples/diff`):
95.0% of 734k fields equal. What differs is what the engine does not do yet: ship movement and fleet
orders (the AI), pop growth, leader experience, construction progress (it needs the modifiers), and
the AI's own state; the player's and the AI's commands between the saves are not in them, so part of
the difference is theirs.

Research over the same 180 days: on the 29 areas researching the same technology at both ends,
95.0% of the game's progress is made (society areas within a point); the game completed 2
technologies and so does the simulation, the same two. Not modelled yet: the AI's next pick when a
queue empties, the alternatives drawn again, special projects researched by days and their
completion, tech sharing; some physics and engineering areas gain ~30-70 points more in the game
than the month's research gives, from outside `DailyResearch` (events, anomalies: not found yet).

Leader experience over the same days: 363 of the 401 leaders end with the game's experience and
level (117 differed before). Of the 38 left, 28 are scientists on ships (the experience of surveys
and anomalies, fleet orders not modelled yet) and 6 officials governing planets (about 2 a month
short: not found yet). Level-ups do not offer traits yet.

## 7. The script layer in the simulation: PDXScript through LuaJIT

`LuaScriptHost` (`sim/src/lua_host.rs`) implements `ScriptHost` with LuaJIT 2.1 embedded through
`mlua` (`luajit` and `vendored` features: built from source with MSVC; the full library, `ffi`
included, as in the game). Its Lua side is `sim/lua/simscript/`, on top of the repo's read-only
modules through `require`: `pdxscript` (lib/stellar-lua-pdxscript) and `stellar.script.source`
(lua/stellar/script: the game's file lookup, inline script expansion and the game's text-based
instantiation of scripted triggers, effects and values with arguments).

| module | |
|---|---|
| `db.lua` | loads from the install, in place: every event of `events/` (10,105), every on_action (489, merged over files), scripted triggers (1,684), scripted effects (1,687), script values (682), static modifiers (3,080), scripted variables (2,908, plus each file's own); the game's trigger and effect names from `logs/script_documentation` when present. About 2 s |
| `eval.lua` | triggers, effects, values, weights; script state (flags, timed flags, variables, global flags, event targets, temp lists) in Lua; scope links; iterators; engine reads and engine effects through `E`; the record of what is not implemented |
| `events.lua` | firing (`pre_triggers`, `trigger`, `fire_only_once`, `immediate`, the option, `after`), delayed events (`days`, `random`), MTTH (`mean_time_to_happen` with its `modifier`s), on_actions (`events`, weighted `random_events`, `trigger`, `effect`), the AI stand-in's option choice (`ai_chance` weights, drawn with the game's RNG) |
| `host.lua` | the entry points `lua_host.rs` calls; one event's Lua error is caught and counted, not fatal; the run report |
| `coverage.lua` | parses every script file and counts keyword uses in context (below) |

**The boundary.** For each call `lua_host.rs` fills the global table `E` with functions bound to
that call's `ScriptCtx` (`mlua` scoped functions over the `World`, the RNG and the queue):

| `E.` | |
|---|---|
| `date`, `rand` | the game date; a draw from the game's RNG (an error in a forbidden zone) |
| `countries`, `colonies(owner)`, `pop_groups(colony)`, `leaders(country)` | id lists, in id order |
| `get(kind, id, field)`, `has(kind, id, set, member)` | engine reads: fields (`owner`, `capital`, `pops`, ...) and the World's property bags (attributes and sets keyed by the trigger that reads them: `is_country_type`, `has_ethic`, `has_civic`, `is_planet_class`, ...) |
| `resource`, `income`, `modifier`, `has_modifier` | stockpiles, last month's income, modifier values and sources |
| `push(effect)`, `new_handle`, `resolve(handle)`, `pending`, `flush` | the engine-effect queue: `add_resource`, `add_modifier` (a static modifier's entries), `create_pop_group` / `create_leader` (with a provisional handle for `last_created_*`), `give_technology`, `kill_leader`, and `unmodelled` for documented engine effects without a model (counted by keyword) |

Script effects (flags, variables, event targets, lists, event scheduling) are applied in Lua and
never cross. Engine effects are queued. **Barriers:** every engine read in Lua first flushes the
queue if anything is pending (a read after a write sees it, as in the game, where an effect applies
at once); `last_created_*` flushes and resolves its handle; an event fired without delay flushes
before its trigger runs; the scheduler flushes after every root effect (`CRootEffect::Execute`)
and at the end of each tick. In the 5-year vanilla run below, 495 flushes happened inside effects.
**Randomness:** every draw (`random_list`, `random`, `random_*` iterators, MTTH rolls,
`random_events`, option choice, delayed `random` days) is `E.rand`, the game's one stream, so a run
is a pure function of the seed (`the_slice_is_deterministic`).

**The vertical slice** (`tests/lua_slice.rs`, no game files): a small tree written to a temp dir
exercises `AND`/`OR`/`NOT`/`NOR`, `if`/`else`, `limit`, comparisons, `check_variable`,
`set_variable`/`change_variable`, `has_*_flag`/`set_*_flag`, `owner`, `capital_scope`,
`every_`/`random_`/`any_`/`count_owned_planet`, `every_country`, a scripted trigger with a
parameter and a default (`$AMOUNT|50$`), a scripted effect with a parameter, a script value with a
`modifier` and a scripted variable (`value:bonus_value`), `random_list`, `add_resource` read back
through `has_resource` in the same block (the barrier), `add_modifier` read back with
`has_modifier`, an on_action from the monthly pulse, a triggered event with two options chosen by
`ai_chance`, a delayed event (`days = 5`), an MTTH event with a `modifier`, a yearly-pulse `event`
iterating countries. All pass, with no Lua errors, and two runs with the same seed give the same
checksum.

**Coverage**, vanilla 4.5.2 (Steam), read in place (`tests/vanilla.rs`):

- **Parsing**: 2,276 `.txt` files under `common/`, `events/`, `map/`, `prescripted_countries/`,
  `flags/`; 1 fails, `common/HOW_TO_MAKE_NEW_SHIPS.txt`, which is prose the game does not load
  (pdxscript's own `parse_all` skips it); 1 warning (`common/named_colors`, a missing `=` the game
  tolerates). 3.8 s.
- **Keywords**, counted in context (trigger blocks, effect blocks, weight blocks; logic, `if`,
  scope changes and iterators followed; option parameters excluded; inline script files are not
  walked):

| | distinct | uses | evaluated by the Lua layer |
|---|---|---|---|
| triggers | 2,502 | 196,461 | 1,722 keywords, 158,944 uses (80.9%) |
| effects | 3,240 | 109,746 | 2,509 keywords, 77,753 uses (70.8%) |

  Triggers by status: implemented in Lua 33 keywords (26.4% of uses: logic, `if`, comparisons,
  variables, resources, ...), property-bag reads 47 (21.1%), scripted triggers 1,206 (13.2%), scope
  links and event targets 397 (11.1%), flags 27 (8.2%), iterators 12 (1.0%); missing: 635 documented
  triggers (15.8%: `is_at_war_with` 1,436, `is_ship_size` 1,223, `is_active_resolution` 891,
  `is_same_species` 714, `has_communications` 696, `is_megastructure_type` 578, the opinion family
  `is_hostile_to` / `is_friendly_to` / ..., `any_system_planet` 342) and 145 undocumented keys
  (3.3%, mostly scope links the sample has no objects for: `solar_system`, `leader`, `federation`,
  `overlord`). Effects: Lua 35 keywords (32.0%), scope changes 1,090 (13.3%), flags 60 (10.4%),
  event firing 15 (7.0%), scripted effects 1,291 (5.8%), iterators 18 (2.4%); engine effects
  pushed to the queue without an engine model 494 keywords (22.4%); missing 129 documented
  (2.7%: iterators over systems, fleets, ships, situations) and 108 undocumented (4.1%).
  "Evaluated" means the Lua layer runs it; property-bag reads are evaluated against what the
  sample world sets (an absent property reads as `no` or an empty set), so they are only as true as
  that world.

**A vanilla run** (`tests/vanilla.rs`, 3 empires, 5 years, seed 2200, a debug build): load 2.0 s,
run 9.3 s for 18,000 ticks; 1.41 million trigger evaluations; 553 events fired (16 distinct:
`focus.95` 180, `paragon.605` 120, `assimilation.150`, `pirate.4`, `pirate.48` 60 each,
`paragon_2.1020`, `timeline.2` 15, `nomads.3000`/`3005`, `crime.50`, `leviathans.10`, `action.220`,
`action.2213`, `action.250`, `focus.90`, `cybernetics.5053`), 16,324 stopped by their trigger,
3,600 MTTH checks, 26 delayed events; on_actions fired from the tick: `on_monthly_pulse(_country)`,
`on_yearly_pulse(_country)`, `on_bi_yearly_pulse(_country)`, `on_five_year_pulse(_country)` (with
its random lists), and the engine's `on_tech_increased`, `on_building_complete`, `on_pop_assembled`;
690 engine effects applied, 0 dropped, 3 kinds unmodelled (`merge_species`, `add_timeline_event`,
`export_trigger_value_to_variable`); 0 Lua errors. The events that fired have no options (pulse
events are hidden); option choice is exercised by the slice. Not implemented and hit while
running: 41 keywords, 45,510 hits, led by `owner_species` (12,600: species scopes),
`count_owned_pop_amount`, `any_neighbor_country`, `any_owned_megastructure` (5,400 each),
`last_increased_tech`, `is_under_colonization`, `founder_species`.

Ten years with the release build (`examples/vanilla.rs`, seed 2200): load 1.9 s, run 11.8 s for
36,000 ticks, 2.85 million trigger evaluations, 1,121 events fired (24 distinct, adding
`galcom.14`, `galactic_features.362`, `paragon.998`, ...), 1,380 engine effects, 990 flushes, 0 Lua
errors. Two runs end with the same checksum (`9b5794ee40779b50`) and RNG position (3,607,665): the
whole vanilla run is deterministic.

**Build and run** (Windows; the game's files are read in place, never copied):

```
set STELLARIS_DIR=C:\Program Files (x86)\Steam\steamapps\common\Stellaris
sim\cargo_msvc.cmd test -j 1 -- --nocapture --test-threads 1      (SIM_YEARS=5)
sim\cargo_msvc.cmd run --release --example vanilla -- "%STELLARIS_DIR%" 5 2200 --coverage
```

`sim/cargo_msvc.cmd` finds Visual Studio with `vswhere` and calls `vcvars64.bat` like
`C:\lfm\build_ss.cmd`, and sets `CARGO_TARGET_DIR` to a local directory
(`%LOCALAPPDATA%\stellarstellaris\simtarget`, not the share). Two traps of the vendored LuaJIT
build on this machine:
the shell environment sets `NoDefaultCurrentDirectoryInExePath=1`, so LuaJIT's `msvcbuild.bat`
cannot run the `minilua.exe` it just built ("'minilua' is not recognized"): the wrapper clears it;
and two concurrent builds of `mlua-sys` (a `[profile.test]` override builds it twice) failed copying
headers: one profile and `-j 1` build it once.

**Gaps to full PDXScript evaluation**, by weight:

1. **Engine objects the World does not have**: systems, fleets, ships, starbases, megastructures,
   species, situations, federations, wars, relations. Their scope links (`solar_system`,
   `owner_species`, `fleet`), iterators (`any_system_planet`, `every_owned_fleet`, ...) and reads
   (`is_at_war_with`, `is_ship_size`, the opinion triggers) are most of the missing 15.8% of
   trigger uses; their effects are most of the 22.4% of effect uses queued without a model.
2. **The property bag is a stand-in**: 47 trigger keywords read attributes a world sets by hand;
   a real engine (or the game's state through the FFI) has to answer them.
3. **Semantics to check against the game**: `=` on numbers as equality, the MTTH chance per day,
   the pulse years (bi-yearly, five-year, decade by year number), event `scopes`, `from` chains,
   `fire_only_once` across saves, numbers as doubles (the game uses `CFixedPoint`), the order of
   options and `random_events` draws relative to the game's own draws (needed for multiplayer
   parity, not for a deterministic simulation).
4. **Not done in Lua yet**: `complex_trigger_modifier`, `trigger:` values, `export_*_to_variable`,
   `check_variable_arithmetic`, scripted lists beyond temp lists, localisation (`custom_tooltip`
   text), and the game's validation errors.

## 8. Checking against the game's modifier nodes

A capture of a live 4.5.2 game gives the ground truth for the modifier model:
`C:\lfm\captures\modifier-nodes-2210.tsv`, every registered modifier node (15,678) right after
loading the 2210.01.01 autosave, with each node's final values and its **parts** (each addition into
the node: `multiplier|category_filter|values`, fixed point, 1.0 = 100000), and the session's
`modifiers-2210.log` (45,583 types and their categories). Parts carry no names (12,765 of 13,080
use `CPdxModifierNameEmptyImpl`), so they are identified by content. The save is
`sacreduthabulanorder_-730439522\autosave_2210.01.01.sav`: its 55 country ids are the 55 Country
nodes' owners, in the same order, and its 6,080 planets are the 6,080 Planet nodes.

The check is `sim/lua/simscript/modcheck.lua`, run from Rust (`sim/src/modcheck.rs`: the save is
read in memory with the `zip` crate, never copied; the vanilla script in place):

```
sim\cargo_msvc.cmd run --release -j 1 --example modcheck     (about 8 s)
sim\cargo_msvc.cmd test --release -j 1 --test modcheck -- --nocapture
  paths: MODCHECK_NODES, MODCHECK_TYPES, MODCHECK_SAVE, STELLARIS_DIR (defaults: the files above)
```

**1. The parts explain the nodes exactly.** For all 5,753 nodes that have parts, the node's values
equal the sum over its parts of `value * multiplier / 100000` (truncated), a value counted only
when its type's category mask meets the part's filter (`mask & filter != 0`; a filter of 0 or -1
passes everything): 5,753 of 5,753, every type exact, no value without a part and no part value
missing from its node. The other nodes: 9,924 are empty, and one has values and no parts (the
Federation node: `federation_fleet_cap_add`, `federation_experience_add`,
`federation_fleet_contribution_factor`, set outside `AddModifier`). The two labels docs/modifiers.md
lists as combinations matter: `Ships` (16508) and `All` (every bit); without them 2,985 nodes
fail (mostly ships, fleets and starbases, and 22 countries, whose ship types are in `Ships`). The SpyNetwork nodes are the clearest case of a filter: their one
part is the whole country node with filter `0x880000` (Espionage | Economic Units), and only three
of the country's types arrive.

**2. Save sources.** Per country: technologies with their level, traditions, ascension perks,
government type, authority, civics, origin, ethics, active policies (the selected option), edicts,
timed modifiers (`timed_modifier.items`, static modifier names), country type, the council
positions (top-level `council_positions`, with the leader's skill: `level + bonus_skill_level`) and
the councilors' and ruler's traits, and the static modifiers the engine adds by name: `empire_base`
(every country), `playable_ai_empire` (AI empires), `fallen_empire_base`.

**3. The script index**: every block of `common/**` (inline scripts expanded with
`stellar.script.source`) whose entries are modifier types: 17,963 blocks in 1,295 files, 7,426
distinct contents. Type names are case-insensitive (`empire_base` writes
`COUNTRY_NAVAL_COVERAGE_MULT = 1`) and some are upper case in the game's list
(`ROBOT_species_trait_points_add`).

**4. Country parts by source** (1,575 parts in 55 nodes; a part is attributed when its values,
raw or times its multiplier, are exactly a block's, and the block's object is among the country's
save sources):

| source | parts | share |
|---|---|---|
| technologies (48 of them scaled by the repeatable's level) | 717 | 45.5% |
| policies (the selected option) | 197 | 12.5% |
| traits of the ruler and councilors | 180 | 11.4% |
| ethics (`country_modifier`) | 89 | 5.7% |
| engine static modifiers (`empire_base`, `playable_ai_empire`, `fallen_empire_base`) | 88 | 5.6% |
| council positions (`modifier` x the councilor's skill) | 76 | 4.8% |
| traditions | 41 | 2.6% |
| authorities (`country_modifier`) | 34 | 2.2% |
| civics, origin | 29 | 1.8% |
| edicts | 18 | 1.1% |
| **from the save's sources** | **1,469** | **93.3%** |
| a script block, but not a source read from the save: `navy_coverage_shortage` (34), `difficulty_ensign_npc` (6), `federation_tax` (3), the shroud seal's `triggered_country_modifier` (11), council agendas in progress (10), others (11) | 75 | 4.8% |
| unexplained | 31 | 2.0% |

The unexplained parts look like sums of the colonies' contributions (`planet_physicists_trade_upkeep_add`
with `pop_physicist_bonus_workforce_mult`, `country_naval_cap_add = 8.8`, `country_edict_fund_add =
1.224`) **[I]**.

Other node categories, matched by content to any script block (or to another node's values, a
parent passed down): Colony 77% script and 23% parent; Fleet 25% script, 74% parent; Ship 36% script
(component templates, traits, static modifiers, ship sizes), 45% parent, 18.5% unexplained; Planet
41% script, 41% parent, 18% unexplained; PopGroup 76% script (pop categories, living standards),
12% unexplained; Leader 15% script, 51% parent, 35% unexplained; Army 24% script, 60% parent, 17%
unexplained; Starbase, Orbital, StarbaseCountry, Sector, GalacticObjectTimed fully matched.

**5. The countries.** Summing each country's save sources' blocks (technologies x level,
councilor positions x skill) gives 1,638 of 2,010 (country, type) values exactly (81.5%); 8 of 55
countries match on every type. What is still missing, by the types that differ:

- **state-dependent engine statics**: `navy_coverage_shortage` (34 countries: the whole
  `country_power_projection_influence_produces_mult` gap), `unity_deficit`, the difficulty modifiers;
- **conditional blocks**: `triggered_councilor_modifier` of traits, `triggered_country_modifier` of
  megastructures and buildings, council agendas while in progress: they need the trigger
  evaluated (the Lua layer can);
- **contributions from other objects**: colonies' jobs, buildings and designations, starbases
  (naval capacity), the federation (`federation_tax`): the country node sums them, scaled by their
  amount (docs/modifiers.md, "Computing a node");
- residual differences in `country_edict_fund_add` (17 countries) and `councilor_exp_gain` (12), where
  a source is counted that the game does not count or the other way round.

**Rules the simulation must model**, confirmed by the capture: one part per source, its values
times the part's multiplier over 100000, truncated; the per-type category filter of each part (for
parent nodes too); repeatable technologies scaled by level; council positions scaled by skill;
engine statics added by name; modifier keys matched without case; inline scripts expanded in
modifier blocks.

## Open questions

- The checksum labels (`g_CheckSumLabels`, `.rdata`): read them from the executable to name the 131
  slots.
- How each object indexes the daily random pool, and the monthly pool's size.
- Which caller fires which periodic on_action (`on_monthly_pulse_country` from
  `CCountry::MonthlyUpdateSerial` **[I]**, the five-year and decade pulses).
- The 22 tasks of the daily task graph beyond `CPdxIntegerFlags::UpdateFlags`.
- Whether every `...SelfDontReadOthers` really reads nothing else (a serial simulation depends on
  it): a runtime check with the game's own thread-safety asserts would tell.
- Effect classification is by name: check each "engine: other" effect's class (`ExecuteActual`
  callees) to confirm it touches engine state.
- The 31 country parts the modifier check cannot attribute (section 8): colony, starbase and
  federation contributions summed into one part each, to be confirmed by computing them.
