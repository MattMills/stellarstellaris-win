# The AI (4.5.2): how it decides, and how to move it to Lua

What the game's AI does, read off the GOG 4.5.2 build and its PDB on hippo (`/root/fnm_tmp`:
`annotate.py`, `pdbtype.py`, the type dump `types452.txt` for enum values), and what a Lua AI in the
simulation would have to reproduce. Addresses are GOG RVAs. **[V]** marks what was read in the
disassembly (the address is given), **[I]** what is inferred from names, call lists or the script
files. Nothing was measured at runtime. Fixed point: `CFixedPoint` is int64 with 1.0 = 100000;
`fpml::fixed_point<int64,48,15>` (fleet power, the AI's weights) has 1.0 = 32768 ("fp15" below).

Context: the tick order is in [simulation.md](simulation.md) section 1 (`ProcessAI` on tick 4 of the
day, `sim/src/scheduler.rs` phase `ai.process`); the engine in section 6.

## In short

- **The AI never touches the game state directly.** `CGameState::ProcessAI` (`0x264600`) runs every
  AI country's update in parallel with `g_AllowGlobalGameStateAccess = 0`, `g_AllowGetPlayer = 0`
  and `CRandom::_InForbiddenZone = 1` **[V]**. Every decision becomes a command (`CCommand`)
  collected per country (`CCountryAI::AddAICommandForPosting`, under a mutex), and after the
  parallel phase the commands are posted to the session in country order **[V]**. They execute in
  the next tick's `CSession::ProcessSynchronousCommands`, like a player's. So the AI is a pure
  function of (game state, AI state) -> command list, and the state it reads is the state at tick
  4 of the day.
- **Its own random numbers.** The AI may not draw from the synchronized `CRandom`. Each AI has two
  Squirrel3 noise generators of the same kind as `CRandom` (simulation.md section 3): the
  *unsynced* one `CAICore::_Random` (`+0x32c` position, `+0x330` seed; save keys `random_seed`,
  `random_count`), drawn by `CAICore::GetRandomInt` (`0xb871d0`) and `CAIModule::GetRandomInt`
  (`0x1afa960`), and the *synced* one `CCountryAI::_SyncedRandom` (`+0x47c`, `+0x480`; save keys
  `synced_random_seed`, `synced_random_count`), drawn by `CCountryAI::GetRandomIntSynced`
  (`0xb7d240`) **[V]**. The unsynced one starts at position = seed = the country id
  (`CAICore::CAICore`, `0x1af82a0`) and, unless the game runs with `-loadrandomseed`, **is not
  restored from a save**: a loaded game starts it again at the id **[V]**. The synced one is
  restored. Some commands draw from the global `CRandom` when they execute (below).
- **Daily, weekly, monthly, yearly are per-country day counters**, not the calendar:
  `CAICore::Update` (`0x1af84e0`) calls `DailyUpdate` every day and the weekly, monthly and yearly
  updates when counters of 7, 30 and 360 days run out; the counters start at `id % 7`, `id % 30`,
  `id % 360` and are not saved, so they restart from the id when a save is loaded **[V]** (the
  constructor, called by `CCountry::ReadMember`). The AI's weeks and months are spread over the
  days by country id; its diplomacy pass is on a calendar day, `(id + day) % 30 == 0`.
- **The structure is ministers.** `CCountryAI` (1,496 bytes) is a `CAICore` with modules: the
  military minister (fleets), the foreign minister (war preparation, diplomacy, envoys,
  espionage), the interior minister (economy, building, research, colonization, policies,
  traditions...), plus enclave/mercenary modules, in the order of the country type's
  `ai = { modules = { ... } }` (with personality `ai_module_overrides`) **[V]**.
- **Attitudes** (hostile, friendly, rival...) are recomputed daily, outside the AI phase, by code
  per attitude type from opinion, borders, personality behaviours and pacts; they gate war and
  pacts **[V]**.
- **War** is a two-step decision **[V]**: weekly, the foreign minister picks the best target
  (opinion, colonies, a random 0..199, distance, casus belli, an attitude that attacks, fleet power
  against the enemy's whole side), rolls `x / 5000` with `x = AI_AGGRESSIVENESS_BASE (25) *
  personality aggressiveness * modifiers * power ratio`, and starts *war preparation*
  (`CAIPrepareWarCommand`, 12 to 29 months drawn from the global `CRandom`); once a month, the
  diplomacy pass proposes `action_declare_war` against that target when the preparation time has
  run out (`CDeclareWarAction::ShouldAIPropose`).
- **Research**: daily, for each area with nothing queued, a weighted random pick among
  `tech_status.alternatives` with weight `ai_weight * (max cost / cost)^2` (and two defines),
  drawn with the unsynced AI random; it is posted as `CResearchTechnologyCommand` **[V]**.
- **Diplomacy**: once a month each AI proposes at most one action (the best of `rand % 100 +
  acceptance` over every action and country it can propose to); it answers proposals after a
  7-day cooldown with a daily roll; acceptance is C++ per action type (`Get*Acceptance`, the
  tooltip terms and `NAI` defines) plus the script's `ai_acceptance` **[V]**.
- **Porting order** (section 7): the AI state and its RNGs first, then research (simple, daily,
  checkable on every save), then opinion and attitudes (deterministic, saved), then the war
  preparation decision, then diplomacy and acceptance, then the budget and the economy; fleets
  last.

## 1. Architecture and entry points

### `CGameState::ProcessAI` (`0x264600`, once a day, tick 4) **[V]**

1. For each country in the game state's country list (`+0x560`, count `+0x56c`): if it is valid
   and has no started AI (`CCountry +0x1b28` is the `CCountryAI*`), create one (`operator new(1496)`,
   `CCountryAI::CCountryAI(id)`, `CCountry::SetAI`, vfunc `SetOwner`; if the game is running, vfunc
   `Start` with random draws forbidden). If the AI has the flag `ModuleCompositionHasChanged`
   (`_Flags` bit 13) call `CCountryAI::RefreshModules`. If the AI is started (`IsStarted`), add
   it to the update list (`CGameState +0x88`).
2. `UpdateAIParallel(list, n)` (`0xb851e0`): with `_InForbiddenZone = 1` and
   `g_AllowPostCommandToSession = 1`, `NThreadUtil::ParallelFor<CUpdateAIFunctor>` over the list;
   each item calls the AI's vfunc `+0x38` = `CCountryAI::Update`. (With task threads disabled it is
   a plain loop.)
3. Serially, for each AI in list order, each command of `_AICommands` (`+0x528`, count `+0x53c`)
   is stamped with the current frame and posted to the session (`session->vfunc +0x28`), or
   deleted when there is no session/host; the array is cleared.

### `CCountryAI::Update` (`0xb6d800`) and `CAICore::Update` (`0x1af84e0`) **[V]**

`CCountryAI::Update` clears the AI's path cache, then runs `CAICore::Update` only if the AI is
active (`_bActive`, `+0x378`), the country type has `ai = { enabled = yes }` (bit 0 of the AI
settings flags, `CCountryType +0x8c`), the strategy is initialized (`+0x379`), the country is alive,
and the country is not human (`CCountry +0x314c`, unless the `ai` console cheat is on).

`CAICore::Update`: removes modules whose `Update` (module vfunc `+0x28`) reports them finished,
then `DailyUpdate` (vfunc `+0x40`); `--_WeekDaysCounter` (`+0x334`) and at <= 0 `WeeklyUpdate`
(`+0x48`), reset to 7; `--_MonthDaysCounter` (`+0x338`) -> `MonthlyUpdate` (`+0x50`), reset 30;
`--_YearDaysCounter` (`+0x33c`) -> `YearlyUpdate` (`+0x58`), reset 360. `CAICore::Daily/Weekly/
MonthlyUpdate` call the same method on each module (`_Modules`, `+0x340`); each minister calls
`CAIModule::*Update` on its sub-modules at its end.

### What runs when (per AI country) **[V]** (callees)

| when | where | what |
|---|---|---|
| daily | `CCountryAI::DailyUpdate` (`0xb6d910`) | when the country's at-war state differs from the AI flag `InWar`, post `CAIUpdateStrategicData`; when `NeedStrategicWarData` is set or the war state changed, post `CAIUpdateStrategicWarData` (the strategy data is rebuilt when the command executes); expire `last_diplo_actions` older than `DIPLO_ACTION_REPEAT_DELAY` days (post `CAIRemoveDiploAction`) |
| daily | `CAIForeignMinister::DailyUpdate` (`0xc39640`) | if the type has `ai.diplomacy`: once a month, on the day where `(id + day index) % 30 == 0`, `MakeAIDiplomaticAction` (propose one diplomatic action, section 3); `HandleRelations`; answer incoming proposals (`ShouldAIAccept` -> `CDiploActionRespondCommand`) when `IsTimeToRespond` or `INSTANT_AI_DIPLOMACY`; espionage networks (`ai.espionage`) |
| daily | `CAIInteriorMinister::DailyUpdate` (`0xbb39a0`) | research choice for the 3 areas (`ai.tech`, section 4); special projects; armies (`BuildArmies`); colonization (`CalcShouldAttemptColonization`, `BuildColonizer`); civilian ships (`BuildShipOfOwnerType` x3), `DisbandShips`; contracts |
| weekly | `CAIForeignMinister::WeeklyUpdate` (`0xc39eb0`) | war preparation (`PrepareWar` / `CheckShouldContinuePreparingWar`, section 2); `AssignEnvoys`; espionage operations; `HandleEmpireSupport` |
| weekly | `CAIMilitaryMinister::WeeklyUpdate` (`0xbfbe50`) | fleet groups: create from stratagems, objectives, opportunities, emergency FTL, transports, idle fleets, bombing stance, megastructure actions (section 6) |
| weekly | `CAIInteriorMinister::WeeklyUpdate` (`0xbb3d10`) | demolish/build/upgrade districts and buildings, starbases and defenses, sectors, leaders, civilian fleets, market trade, council agenda, branch offices, holdings, megastructure dismantling, events (`HandleOneEvent`), situations, decisions, policies, relics, minor artifacts, astral actions, accords, government, claims (`RemoveClaims`, `MakeClaims`) |
| monthly | `CCountryAI::MonthlyUpdate` (`0xb6ddc0`) | the budget: `SetBudgetArraySize`, `UpdateUpkeepBudget`, `UpdateExpenditureBudget` (section 5); agreement renegotiation (`CNegotiateExistingAgreementAction`) |
| monthly | `CAIInteriorMinister::MonthlyUpdate` (`0xbb40f0`) | `CAIEconomicStrategy::CalcBestEconomicPlan` and `CreateBuildPlan` (section 5); threatened systems; slaves; species rights; factions; amenity and scripted jobs (parallel over colonies); edicts; species modding and uplift; resettlement; deposit blockers; terraforming; observation stations; megastructures; traditions; ascension perks; planetary ascension; galactic community; councilors |
| monthly | `CAIMilitaryMinister::MonthlyUpdate` (`0xbfc570`) | `UpdateFleetCompositions`, `TrimFleetGroups`, `ReinforceFleetGroups` |
| yearly | `CAIInteriorMinister::YearlyUpdate` (`0xbb4c30`) | galactic community (join, breach `AI_IN_BREACH_THRESHOLD`, council powers, freeze, end session), re-enable disabled buildings |

`CAIMilitaryMinister::DailyUpdate` and `CAIForeignMinister::MonthlyUpdate` are empty **[V]** (folded
with other empty functions). Most minister updates return early when the country `WasHumanRecently`.

Other parts of the AI run outside `ProcessAI`, in the game's own phases:

- `CCountryAI::UpdateAttitudesThreaded` (`0xb7ab60`) is phase 2 of `DailyUpdate`, and
  `MonthlyUpdateStrategy` / `MonthlyCopyAttitudes` run in parallel in `MonthlyUpdate` (simulation.md
  section 1) **[V]** (call sites); the attitudes are section 3.
- `ShouldAIAccept`, `GetAIAcceptance` also run when a proposal to an AI is processed.
- The commands execute in `ProcessSynchronousCommands` of the next tick, serially, and may draw
  the global `CRandom` there (e.g. `CAIPrepareWarCommand::Execute`).

### The AI state (save `country.ai = { ... }`) **[V]** (`CCountryAI` layout, the 2210.01.01 save)

| key | field | |
|---|---|---|
| `initialized`, `recalculate` | `_bInitializedStrategy`, `_bRecalculateStrategy` | |
| `building`, `station`, `prepare_war`, `war`, `deficit_spending`, `colonize`, `navy_depleted`, `can_build_robots`, `need_strategic_war_data`, `is_in_stale_war`, `dirty_expand_strategy`, `ai_death_spiral`, `ai_module_composition_changed` | `_Flags` (`EAICountryFlags` bits 0-8, 10-13) | written only when set (`colonize=yes` is `HasCreatedColonizeData`) |
| `budget` | `_Budget` | 4 numbers |
| `extra_attacker` | `_ExtraAttackers` `+0x3d0` | allies picked for the prepared war |
| `strategy = { id target value type }` | `CAIStrategicBase` strategies | 14 of 55 AI countries have them |
| `prepare_war_date_start`, `prepare_war_date` | `_PrepareWarDateStart` `+0x3f8`, `_PrepareWarDateEnd` `+0x3fc` | |
| `target` | `_Target` `+0x400` | war preparation target, 4294967295 = none |
| `nemesis` | `_Nemesis` `+0x478` | |
| `robot_colonies`, `robot_colonies_with_free_buildings` | `+0x3e8`, `+0x3f0` | |
| `attitude = { { country attitude weight priority date } }` | `_Attitudes` `+0x488` (`SAttitudeData`: country, `CAIAttitude*`, weight fixed, `EAIPriority`, last priority change date, forced) | 15 of 55 |
| `random_seed`, `random_count` | `CAICore::_Random` | unsynced RNG |
| `synced_random_seed`, `synced_random_count` | `_SyncedRandom` | |
| `ai_resource_target_records`, `last_valid_resource_targets`, `last_valid_resource_floors` | `_ResourceTargetRecords` etc. | income targets (budget) |
| `last_diplo_actions = { { country action creation_date } }` | `_LastDiploActions` `+0x540` | repeat delay of proposals |

`CCountryAI::ReadMember` (`0xb759a0`) keys **[V]** (the token switch). `EAICountryFlags`: 1
`NeedsBuildings`, 2 `NeedsStations`, 4 `PrepareWar`, 8 `InWar`, 16 `IsDeficitSpending`, 32
`HasCreatedColonizeData`, 64 `NavyDepleted`, 128 `CanBuildRobots`, 256 `NeedStrategicWarData`, 512
`WantsToNegotiateAgreement` (not read), 1024 `IsInStaleWar`, 2048 `DirtyExpandStrategy`, 4096
`HasEnteredDeathSpiral`, 8192 `ModuleCompositionHasChanged`. Not saved: the day counters, the
fleet power cache, the expenditure and upkeep budgets (recomputed on the AI's month).

**The unsynced RNG is not restored on load** **[V]**: `random_seed` / `random_count` are applied
only when `g_bUseSavedRandom` is set, which is the command-line option `-loadrandomseed`
(`0x15092e`). By default a loaded AI starts again at position = seed = country id, like a new one,
and its day counters at `id % 7`, `id % 30`, `id % 360`. The synced RNG (`synced_random_*`) is
always restored. Consistent with the saves: `random_count` of country 16777217 is 16,790,500 in
2210.01.01 and 16,781,668 (= id + 4,451, about 25 draws a day) in 2210.07.01, a game loaded in
between; `synced_random_count` grew by 13 in 180 days. So a simulation started from a save
reproduces a game *loaded* from that save when it resets the unsynced RNG to the id (or both use
`-loadrandomseed` and the saved position).

### Country type AI settings (`SCountryAISettings`, `CCountryType +0x68`) **[V]**

`ai = { ... }` of `common/country_types`, flags at `+0x8c` (`ECountryAISettingsFlags`, from
`SCountryAISettings::ReadMember`, `0x43bb40`): 0 `enabled`, 1 `declare_war`, 2 `colonizer`,
3 `internal_policies`, 4 `modification`, 5 `government`, 6 `traditions`, 7 `construction`,
8 `limited_construction`, 9 `starbase_upgrade`, 10 `diplomacy`, 11 `tech`, 12 `follow`,
13 `avoid_enemies`, 14 `can_use_market`, 15 `espionage`, 16 `ascension_perks`,
17 `limited_military_construction`, 18 `limited_leaders`; `min_assault_armies_for_wars` (`+0x88`),
`modules` (`+0x70`).

### Personalities (`CAIPersonality`, `common/personalities`) **[V]** (layout)

`aggressiveness` `+0x208`, `bravery` `+0x210`, `combat_bravery` `+0x218`, `trade_willingness`
`+0x220`, `military_spending` `+0x228`, `colony_spending` `+0x230`, `threat_modifier` `+0x1e0`,
`threat_others_modifier` `+0x1e8`, `friction_modifier` `+0x1f0`, `claims_modifier` `+0x1f8`,
`loyalty_acceptance` `+0x200`, the agreement acceptances (ints) `federation_acceptance` `+0x1c0`,
`migration_pact_acceptance` `+0x1c4`, `nap_acceptance` `+0x1c8`, `commercial_pact_acceptance`
`+0x1cc`, `research_agreement_acceptance` `+0x1d0`, `defensive_pact_acceptance` `+0x1d4`,
`advanced_start_chance`, ship part ratios, `weapon_preferences`, `behaviour` (`+0x48`, flags such
as conqueror, propagator...), `weight` (a scriptable value), `allow`, `ai_module_overrides`. The
country holds its personality at `CCountry +0x33f8` (save key `personality`).

## 2. War

### The decision path **[V]**

```
weekly   CAIForeignMinister::WeeklyUpdate
           AI not preparing war  -> gates -> PrepareWar
               best target = argmax CalcGoingToWarScoreAgainst over the country's relations
               power check (recruit allies if needed)
               roll: AI random % 5000 < x  -> post CAIPrepareWarCommand(start, target, allies)
           AI preparing war      -> CheckShouldContinuePreparingWar
               conditions fail -> post CAIPrepareWarCommand(stop)
next tick  CAIPrepareWarCommand::Execute: PrepareWar flag, start date = today,
           end date = today + AI_WAR_PREPARATION_MIN_MONTHS + CRandom % (MAX - MIN) months, target
monthly  CAIForeignMinister::DailyUpdate -> MakeAIDiplomaticAction (on the country's diplomacy day)
           BuildProposalList(action_declare_war, target):
               war goal NAIUtil::SelectWarGoalType, allies from the extra attackers,
               CDeclareWarAction::ShouldAIPropose: prepare flag, target, today > end date
           best proposal (declare war scores +10000) -> post CDiploActionProposeCommand
```

### Gates of `CAIForeignMinister::WeeklyUpdate` (`0xc39eb0`)

Nothing if the country `WasHumanRecently`. War preparation is considered when the country type has
`ai.declare_war`, and then:

- the AI is already preparing (`_Flags & PrepareWar`) -> `CheckShouldContinuePreparingWar` instead;
- the country is under crisis attack (`_Settings` bit 8, `IsUnderCrisisAttackCached`) -> the same;
  fighting a crisis (bit 7) and not the crisis leader -> the same;
- the country type has the `Relations` flag (`ECountryTypeFlags` 128);
- not at war (`CCountryRelationsManager` war count, `CCountry +0x2bb4`), unless the type is an
  awakened fallen empire (flag 1024);
- `CCountryAI::IsReadyForWarCheckMilitary(false)` (`0xb78d70`): owned assault armies
  (`CCountry::CalcNumOwnedAssaultArmies`) >= max(1, `min_assault_armies_for_wars`), and
  `_vCachedMilitaryFleetPower` (`CCountry +0x2f30`, fp15) >= `MIN_FLEET_FOR_OPERATIONS` (500);
- the country flag `NO_WARS_FLAG` (`ai_no_wars`) is not set.

### Target score: `CAIForeignMinister::CalcGoingToWarScoreAgainst` (`0xc3b500`)

For each relation `R` of the country (`CCountry +0x2b90`, the relations manager's array), with `T`
the other country. Score 0 (not a candidate) unless all of:

1. `R` has `HasContact` (`ERelationFlags` 65536) and `T`'s country type has `Relations`;
2. no truce: if `CRelation::GetTruce(R)` is valid, the score is 0 and the out flag `truce` is set
   (used by the aggressiveness, below);
3. the country has a casus belli against `T` (any entry of `CDiplomacyCountryModule::_CasusBelli`,
   `+0x50`, whose target is `T`);
4. the AI's attitude towards `T` (`CCountryAI::GetAttitude`) has `behaviour = { attack = yes }`
   (`SBehaviour::_bAttack`, attitude `+0x50`): in vanilla `hostile`, `domineering`, `disloyal`,
   `threatened`, `angry`, ... (`common/attitudes`);
5. `CCountryAI::IsReadyForWarWith(T, &war)` (below);
6. distance: if `T`'s relation to us is `IsBordering`, fine; else unless `T` is nomadic
   (`_Settings` bit 11) the relation's `_BorderDistance` (`+0x100`, save `border_range`, jumps)
   must be <= `WAR_DECLARATION_MAX_DISTANCE` (300) and a path must exist from our capital to
   theirs (`CPathCache::FindPath` with the country's first fleet's movement data).

Then (all fixed point):

```
score = (100 - opinion) + (AI random % 200) + min(5 * colonies(T), 200)
if war.NeedsExtraAttackers: score = score / 2
if bordering:              score = score * 1.5
else:                      d = nomadic(T) ? 0 : border distance
                           if d > WAR_DECLARATION_MALUS_DISTANCE (200):
                               score = score * max(WAR_DECLARATION_MINIMUM_SCORE (0.5),
                                                   1 - d * WAR_DECLARATION_MALUS (0.05))
```

`opinion` is `COpinionCalculator::GetSecondsOpinionOfFirst(T, us)` (the AI's opinion of `T` **[I]**
from the argument order), `colonies(T)` the size of `T`'s `_OwnedColonies` (`+0x26b8`). The random
is one draw of the unsynced AI random per candidate that passes the gates, in relation order. Note
`1 - d * 0.05` with `d > 200` is always below 0.5, so beyond 200 jumps the factor is simply 0.5
(the define comments suggest the malus was meant per jump above the malus distance).

### Power check: `CCountryAI::IsReadyForWarWith` (`0xb78470`)

1. `IsReadyForWarCheckMilitary(false)`.
2. War goal for the estimate: the first war goal type (`CWarGoalTypeDatabase`) with the byte
   `+0x564` set; if `T` is our overlord (`CCountry +0x2630`), `wg_independence`.
3. `CalcStartWarData(us, T, allies = {}, wargoal)` (`0xb78160`): `CWarParticipants::NewWar` builds
   both sides as a declaration would (allies, subjects, defensive pacts, federation...);
   `Us.FleetPower` = sum of the attackers' `_vCachedMilitaryFleetPower`, `Us.FleetCapacity` = sum
   of `CCountry::CalcNavalCapacity`; `Them` the same over the defenders (`SStartWarData`, fp15).
4. Wars already running: for each of our wars, one side of that war (the attackers if `T` is an
   attacker in it, else the defenders) adds half of each member's fleet power to `them`. If `T` is
   at war and our personality is an `opportunist` (`SPersonalityBehaviour` `+0xc`), a second pass
   adds the same kind of sums to `us`; as read, that pass also iterates over *our* wars
   (`CCountry +0x2ba8` of the AI's own country), not `T`'s **[V]** (registers); possibly a game
   bug, reproduce it as is.
5. Not playable country types (`ECountryTypeFlags` `Playable`) are ready here. Otherwise ready
   when `us > 0` and `us >= them * ENEMY_FLEET_POWER_MULT (1.2)`.
6. Else allies: for each relation `C` with `CanBeInvitedToWarBy(us, T)` and `CanJoinWarAgainst`,
   add `C` and recompute step 3; ready as soon as the condition of step 5 holds, with
   `NeedsExtraAttackers = 1` (a country with an overlord keeps adding every eligible ally).

### `CAIForeignMinister::PrepareWar` (`0xc3a760`)

1. Best target: the candidate with the highest score `> 0` (strictly greater wins, so the first in
   relation order on ties). Keep its `SStartWarData`, and
   ```
   ratio = (Us.FleetPower / max(Them.FleetPower, 1) + Us.FleetCapacity / max(Them.FleetCapacity, 1)) / 2
   ```
   No candidate -> nothing.
2. If the target needs extra attackers: repeatedly pick, among our relations `C` that
   `CanBeInvitedToWarBy` us against the target, `WillJoinWarAgainst(C, us, T)` (for a human `C`,
   also: we do not hold the opinion modifier `COpinionModifierDatabase +0x58` towards `C`,
   presumably the declined-invitation one [I]) and are not yet picked, the one with the highest
   `power(C) + AI random % int(power(C))` (one draw per eligible `C` with power >= 1); add it to the
   extra attackers and its power to ours; stop when `ours >= theirs * ENEMY_FLEET_POWER_MULT` or
   nobody is left. Still short -> nothing.
3. Aggressiveness (integer arithmetic after the first product):
   ```
   m = 1, or AI_AGGRESSIVENESS_HIGH_MULT (2.0) / LOW_MULT (0.5) by the game setting (CGameState +0x9b0 -> +0xa4 == 1 / 2)
   x = round(AI_AGGRESSIVENESS_BASE (25) * m * personality.aggressiveness)
   truce = some relation passed the contact gate but has a valid truce (step 2 of the score)
   if CCountryAI::HasPotentialBorderExpansion (0xb70890):
       if colonies < MAX_PLANETS_FOR_BUDGET_FACTOR (3): x = x / (3 - colonies)   (integer division)
           then if truce: x = x / AI_AGGRESSIVENESS_BOXED_IN_MULT
       elif the AI's strategy list 1 (CAIStrategicBase::GetStrategy(1), colony targets [I]) is not empty:
           if truce: x = x / AI_AGGRESSIVENESS_BOXED_IN_MULT
       elif truce: x = x / AI_AGGRESSIVENESS_BOXED_IN_MULT
       else:       x = x * AI_AGGRESSIVENESS_NO_COLONY_TARGET_MULT (2)
   else (boxed in):
       truce -> x = x / AI_AGGRESSIVENESS_BOXED_IN_MULT (4)
       propagator personality (SPersonalityBehaviour +0x15) -> x = x * AI_AGGRESSIVENESS_PROPAGATOR_BOXED_IN_MULT (10)
       else -> x = x * AI_AGGRESSIVENESS_BOXED_IN_MULT (4)
   if the target is not at war: x = round(x * min(0.5 + ratio / 2, 5))
   x = max(x, 1)
   prepare war if AI random % 5000 < x            (always with the console cheat at g_CheatManager +0x74)
   ```
   So a balanced (ratio 1) "aggressiveness 1.75" AI with room to expand and 3+ colonies and colony
   targets has about 44 / 5000 per week, under 1% a week; boxed in, four times that.
4. Post `CAIPrepareWarCommand` (72 bytes: country, target, extra attackers, `start = 1`).

### `CAIPrepareWarCommand::Execute` (`0x6c2a20`), in the synchronous command phase

`_Flags.PrepareWar = start`; `_PrepareWarDateStart = today`; one draw of the **global**
`CRandom::GetIntegerForMacro`; `_PrepareWarDateEnd = AddMonths(today, MIN + r % (MAX - MIN))`
with `AI_WAR_PREPARATION_MIN_MONTHS` 12 and `MAX` 30; `_Target = target` (or none); the extra
attackers copied. The draw and the dates happen for a stop command too.

### `CAIForeignMinister::CheckShouldContinuePreparingWar` (`0xc3a490`)

Weekly while preparing: recompute `CalcGoingToWarScoreAgainst` for `_Target`; keep preparing when
(not at war or awakened fallen empire) and `IsReadyForWarCheckMilitary(false)` and the attitude
towards the target still attacks and the target is alive and the score is `> 0`; otherwise post
`CAIPrepareWarCommand(stop)`. With an attacking attitude the opinion is low (hostile needs
opinion <= -100), so the score is positive whenever the gates pass: what ends a preparation is a
gate (casus belli lost, attitude changed, truce, power check, distance, army or fleet minimum).
The recomputation draws the unsynced random as in `PrepareWar`.

### The declaration: `BuildProposalList` (`0xb89370`) for `action_declare_war`

In the monthly diplomacy pass (section 3), for the token `action_declare_war`:

1. `CDeclareWarAction` us -> `T`, `IsProposable(ai)`;
2. the war goal `NAIUtil::SelectWarGoalType(us, T)` (`0xba2e10`) must be valid: among
   `NWarGoal::ListPotentialWarGoals(us, T)` the possible ones (`CWarGoalType::IsPossible`), the
   one with the highest `CWarGoalType::CalcAIWeight` (the war goal's `ai_weight` in
   `common/war_goals`); no random;
3. the AI's extra attackers that `CanJoinWarAgainst` join the attackers;
4. no federation cooldown (`ActionHasFederationCooldown`); unless auto-accepted, `T` has not
   rejected the same action before (`CCountry::_RejectedActions`, `+0x1960`);
5. `IsProposable` again, and `CDeclareWarAction::ShouldAIPropose` (`0x9ac610`):
   `ScriptedShouldAIPropose` (the action's `should_ai_propose` trigger if any) and the AI has
   `PrepareWar` and `_Target == T` and `today > _PrepareWarDateEnd` (as `year*360 + day of
   year`).

`action_declare_war` is `auto_accepted = yes` in `common/diplomatic_actions`, so no acceptance is
asked. In `MakeAIDiplomaticAction` its score gets `+10000`, so it wins over any other proposal of
the month.

### Defines (`common/defines`, `NAI`) used here

`MIN_FLEET_FOR_OPERATIONS` 500, `ENEMY_FLEET_POWER_MULT` 1.2, `AI_AGGRESSIVENESS_BASE` 25,
`AI_AGGRESSIVENESS_LOW_MULT` 0.5, `AI_AGGRESSIVENESS_HIGH_MULT` 2.0,
`AI_AGGRESSIVENESS_BOXED_IN_MULT` 4, `AI_AGGRESSIVENESS_PROPAGATOR_BOXED_IN_MULT` 10,
`AI_AGGRESSIVENESS_NO_COLONY_TARGET_MULT` 2, `MAX_PLANETS_FOR_BUDGET_FACTOR` 3,
`WAR_DECLARATION_MAX_DISTANCE` 300, `WAR_DECLARATION_MALUS_DISTANCE` 200,
`WAR_DECLARATION_MALUS` 0.05, `WAR_DECLARATION_MINIMUM_SCORE` 0.5,
`AI_WAR_PREPARATION_MIN_MONTHS` 12, `AI_WAR_PREPARATION_MAX_MONTHS` 30,
`DIPLO_ACTION_REPEAT_DELAY` 360, `NO_WARS_FLAG` "ai_no_wars".

## 3. Diplomacy

### Attitudes: `CCountryAI::UpdateAttitudesThreaded` (`0xb7ab60`) **[V]**

Daily, phase 2 of `CGameState::DailyUpdate` (not in `ProcessAI`), in parallel over every AI's
relations (`CPerCountryRelationAttitudesFunctor`, `0xb7a2f0`); new entries are appended serially
after the parallel part. For each relation `R` to a country `T` with `HasContact`:

- the AI's current entry for `T` (`_Attitudes`, `SAttitudeData`): if it is `forced`
  (`ForceAttitude`, an effect), keep it; else the current attitude's weight
  `CAIAttitude::CalcAIWeight` + `ATTITUDE_CHANGE_BUFFER` (0) is the bar; with no entry the bar is
  -1.0;
- `opinion = GetSecondsOpinionOfFirst(T, us)`, `HasDiplomaticInterest(us, T)`;
- every attitude of `common/attitudes` (database order) other than the current one:
  `friendly`, `protective`, `wary` and `receptive` weigh 0 without diplomatic interest (the token
  switch at `0xb7a52c`); the others, and those with interest, `CAIAttitude::CalcAIWeight`
  (`0xb3a060`, a switch on the attitude's type); the highest weight wins if it is strictly above
  the bar (ties keep the earlier one, so the current attitude wins ties);
- the entry is updated (attitude, weight) or appended.

The list of AIs is every AI whose country type has `Relations`, daily, in the game's country order
(`CGameState::DailyUpdate` `0x25d280`-`0x25d363`).

`CAIAttitude::CalcAIWeight` is code per attitude type (not script): it reads the current attitude,
`IsAtWarWith`, `IsAllied`, migration pacts, associate status, borders (`IsBorderingCountry`,
`CGameRules::HasBorders`), `CalcRelativePower`, opinion modifiers, `HIGH_THREAT_THRESHOLD` (50),
crisis fighting (`NAttitude::ShouldFightCrisis`), and two helpers. The war-relevant one,
`NAttitude::CalcHostileAIWeight` (`0xb39b50`):

```
0 if we are a fallen empire; 0 if allied with T and we have no casus belli of the type
  NGameplay DECLINED_TO_LEAVE_FEDERATION_CASUS_BELLI_TYPE against T; 0 if not bordering T
0 unless personality conqueror, or liberator, or (subjugator and T's type is a fallen empire)
0 if propagator and HasPotentialBorderExpansion
threshold = -100 (-80 if hostile is already the current attitude); with a rivalry -50 (-40)
weight = opinion <= threshold ? 3000 : 0
```

(The 2210.01.01 save has `attitude="hostile" weight=3000`.) The other types are to be read the
same way when porting (`CAIAttitude::CalcAIWeight` 745 instructions, `CalcProtectiveAIWeight`).
`CCountryAI::GetAttitude(id)` returns the entry's attitude or a null attitude.

### Proposing: `MakeAIDiplomaticAction` (`0xb8ae20`) **[V]**

Once a month per AI, on the day where `(country id + days since 0.01.01) % 30 == 0`, if the AI is
not human-recent and (at war, or it has no outgoing proposal pending:
`CCountry::_ProposedActions`, `+0x1978`, empty):

1. Draw one unsynced AI random per country of the game (in country order) into an array.
2. In parallel over all countries `T` (lambda `0xb8b2f0`): skip unless the relation has
   `HasCommunications` (8), both sides can act (`CDiplomacyCountryModule` vfunc `+0xb0` both ways)
   and `HasContact`. For each diplomatic action type (`common/diplomatic_actions`, database order):
   skip if `last_diplo_actions` has (T, action) with `date + DIPLO_ACTION_REPEAT_DELAY days > today`;
   else `BuildProposalList(us, T, action, ..., random[T])` (`0xb89370`), which has specialized
   branches for `action_declare_war` (section 2), `action_offer_peace` (below),
   `action_form_research_agreement`, `action_break_research_agreement`,
   `action_ask_to_join_federation`, `action_recall_embassy`, `action_pledge_secret_fealty`, ... and
   a generic one; a candidate needs `IsProposable`, the action's `ShouldAIPropose` (C++ per class,
   plus the script's `should_ai_propose` through `CDiplomaticAction::ScriptedShouldAIPropose`) and,
   unless auto-accepted, `GetAIAcceptance(T) >= 1`.
3. Serially over the candidates: `score = AI random % 100 + (auto-accepted ? 0 :
   GetAIAcceptance(action, recipient))`; `action_declare_war` and `action_offer_peace` get
   `+10000`; `action_close_borders` is set to 1. The highest score (strictly greater, first wins)
   is posted as `CDiploActionProposeCommand`; the date goes into `last_diplo_actions`
   (`CCountryAI::SetActionProposed` [I]).

### Accepting: `ShouldAIAccept` (`0xb8b580`), `GetAIAcceptance` (`0xb8b790`) **[V]**

Daily in `CAIForeignMinister::DailyUpdate`, for each incoming proposal (`CCountry +0x1950`): when
`IsTimeToRespond` (`0xc39a30`) or `INSTANT_AI_DIPLOMACY`, `ShouldAIAccept`: accept iff the recipient
has not rejected it before (`HasRejectedAction`) and `GetAIAcceptance >= 1`; the answer is posted
as `CDiploActionRespondCommand` (a refusal only if `CanDecline`). `IsTimeToRespond` **[V]**: the
proposal expires `AUTO_DECLINE_DIPLOMACY_DAYS` (180) after it was made (action `+0x38`); at or
after the expiry, respond; before `DIPLOMACY_RESPONSE_COOLDOWN_DAYS` (7) have passed, never; in
between, each day draw an unsynced random and respond if `days left < r % 180`. The same check
gates federation votes in `HandleRelations` (`0xc39b00`, `GetAIAcceptanceForFederationMembers`).

`GetAIAcceptance(action, evaluator)` = `ACCEPTANCE_DEAL_ALWAYS` (1000) when the evaluator is the
actor or the action is auto-accepted; otherwise a C++ function per action type plus
`GetFavorAcceptanceBonus` (favors x `DIPLO_ACTION_FAVOR_AI_ACCEPTANCE_VALUE` 5) plus
`GetScriptedAcceptance` (the action's `ai_acceptance` script modifiers) (+ federation handling for
trade deals and federation votes). The per-type functions are sums of integer terms, each
`int(input * define)` with the game's fixed-point truncation:

| action | function | terms (defines `NAI`) |
|---|---|---|
| `action_form_defensive_pact` | `GetDefensivePactAcceptance` (`0xb91bf0`) | base (`AI_acceptance_base_value`, `GetBaseValue` `0xb8fec0`), deal breakers (`ACCEPTANCE_DEAL_BREAKER` -1000), attitude: alliance behaviour +50 / coexist +20 / other -50, existing pacts x -50, opinion x 0.2, shared defensive pacts x 30, shared threat x 0.25, shared rivals x 30, relative power x 5 capped 20, personality `defensive_pact_acceptance`, border distance x -0.1 (`GetDistanceScore`) |
| `action_form_non_aggression_pact`, association status | `GetNonAggressionAcceptance`, `GetNonAggressionAndAssociateShared` (`0xb928a0`) | the same shape with `NON_AGGRESSION_PACT_ACCEPTANCE_*` |
| commercial pact, research agreement, migration pact, guarantee, embassy, trade deal, secret fealty, federation invite/join/associate, subjugation demand/ask, pre-FTL, renegotiation | `GetCommercialPactAcceptance`, `GetResearchAgreementAcceptance`, `GetMigrationPactAcceptance`, `GetGuaranteeIndependenceAcceptance`, `GetEmbassyAcceptance`, `GetOfferTradeDealAcceptance`, `GetProposeSecretFealtyAcceptance`, `GetInviteFederationAcceptance`, `GetAskJoinFederationAcceptance`, `GetInviteFederationAssociateAcceptance`, `GetDemandSubjugationAcceptance`, `GetAskToBecomeSubjugatedAcceptance`, `GetPreFtlAcceptance`, `GetNegotiateAgreementAcceptance` | each its define group and personality `*_acceptance` |
| other actions | `GetBaseValue` | `AI_acceptance_base_value` |
| `action_offer_peace` | `GetOfferPeaceAcceptance` (`0xb8e820`) | below |

`NAIUtil::WillAIAccept` (`0xba0890`, 1,431 instructions) and `NWarAI` (`CalcWarWillingness`,
`CalcLeaveWarWillingness`, `IsWarAcceptable`, `CheckWillOfferToJoin`, `CheckWillTryToLeave`) are the
acceptance of trade-deal terms that join or leave wars (`ProposeJoinOrLeaveWar`), not of the
declaration itself **[V]** (callers).

### Peace

`BuildProposalList` for `action_offer_peace`: for a war where both are war leaders,
`CalcBestPeaceOffer` (`0xb8e620`) tries the offers `DemandSurrender` (2), `Surrender` (1) and
`StatusQuo` (0) (`EPeaceOfferStatus`), each kept if `IsPossible`, the script's
`should_ai_propose`, and `GetOfferPeaceAcceptance(recipient) > 0`; the order of the tests suggests
the preference demand > surrender > status quo **[I]**. `GetOfferPeaceAcceptance` terms **[V]**
(defines read, arithmetic not traced): occupation (`CWar::CalcOccupationPercent`) x
`PEACE_OCCUPATION_FACTOR` (100); war exhaustion x `PEACE_WAR_EXHAUSTION_FACTOR` (100); demand
surrender `PEACE_DEMAND_SURRENDER_FACTOR` (-100); status quo `PEACE_STATUS_QUO_FACTOR` (-75),
`PEACE_HIGH_WE_STATUS_QUO_FACTOR` (+100) at high war exhaustion, `PEACE_STALE_WAR_STATUS_QUO_FACTOR`
(+75) in a stale war (AI flag `IsInStaleWar`, set by the military minister after `STALE_WAR_TIMER`
failed searches for objectives [I]); claimed systems the evaluator still holds: per system
`PEACE_DEFENDING_CLAIM_SYSTEM_FACTOR` (-10), with an upgraded starbase `..._STARBASE_FACTOR` (-40),
with a colony `..._PLANET_FACTOR` (-100); relative navy x `PEACE_RELATIVE_NAVY_STRENGTH_FACTOR`
(50); a war goal term; `ACCEPTANCE_DEAL_ALWAYS` in some cases (being offered the other side's
surrender [I]). The forced peace at full war exhaustion is the war's own logic
(`CWar::DailyUpdateSerial`), not the AI.

### Federations, rivalries, envoys

- Rivalries, federations and pacts are diplomatic actions like the others: proposed by the
  monthly pass and accepted by `GetAIAcceptance` **[V]** (the dispatch).
- Envoys: `CAIForeignMinister::AssignEnvoys` (`0xc3bc20`, weekly, 1,517 instructions) assigns
  envoys to improve or harm relations and to federations, drawing `CAICore::GetRandomInt(min, max)`
  (`0xbb2d70`, `min + r % (max - min + 1)`) and posting `CAssignLeaderCommand` and pact actions
  **[V]** (calls).
- Federation laws and votes go through `WillFederationAccept` (`0xb88d20`).

## 4. Research **[V]**

`CAIInteriorMinister::DailyUpdate` (`0xbb39a0`), if the country type has `ai.tech`: for the areas
0, 1, 2 (physics, society, engineering) in order:

```
r = unsynced AI random                           (drawn every day for each area, used or not)
tech = CTechnologyStatus::GetTechToResearch(tech_status, area, r)
if tech is valid: post CResearchTechnologyCommand(country, tech)
```

`GetTechToResearch` (`0x81e090`):

1. If the area's queue (`_TechQueues`, `tech_status +0x48 + 24*area`, save `physics_queue`...)
   holds an item with a valid technology (or an active special project), return none.
2. `alternatives` = `_TechAlternatives`, `tech_status +0x108 + 24*area` (save
   `alternatives = { physics = {...} }`); none -> none.
3. `maxCost = GetMaxCost(alternatives)` (`0x81e510`): the largest `CTechnology::GetCost` among
   the alternatives, each at its next level (current level + 1, for repeatables).
4. For each alternative `t` (when fewer than 200): `w(t) = CanQueueResearch(t) ? max(GetAIWeight(t,
   maxCost), 1.0) : 0` (fp15). `CanQueueResearch` (`0x81a440`): a valid technology, not maxed,
   `CTechnology::CanResearch`, and not already queued in its area (`GetAreaFor`). With 200
   alternatives or more a weighted heap (`NPrivateHelper::WeightedRandomHeap`) is used instead.
5. `index = GetWeightedRandomInternal(n, w, r, r % n)` (`0x1b4ad80`): `total = sum max(w, 0)` (raw
   fp15 integers); if `total == 0` the fallback `r % n`; `target = r % total` (or a scaled form when
   `total > 2^31 - 1`); the first index whose running sum exceeds `target`.

`GetAIWeight` (`0x81e5d0`):

```
w = ai_weight of the technology (common/technology; CTechnology::_AIWeight +0x508 is a
    CMeanTimeToHappen: the factor +0x518, then each modifier of +0x528 applied in order with the
    country as scope; CFixedPoint) -> fp15
if infinitely repeatable (_Levels +0x588 = -1): w *= AI_TECHNOLOGY_INFINITELY_REPEATABLE_WEIGHT_MULT (0.01)
if rare (_Properties +0x9f8 & Rare (8)):       w *= AI_TECHNOLOGY_RARE_WEIGHT_MULT (1.5)
cost  = max(CTechnology::GetCost(country), 1.0)
ratio = max(maxCost / cost, 1.0)
w *= ratio * ratio
```

`CResearchTechnologyCommand::Execute` (`0x6ba9d0`) -> `CTechnologyStatus::QueueResearch`
(`0x81a560`), valid if `CanQueueResearch`. It executes in the next tick's command phase, so a tech
chosen on tick 4 is queued the same day; research progress is the daily phase
(`engine/research.lua`). Human auto-research is the same function with a **global** `CRandom`
draw, in `CCountry::DailyUpdateSerial` (`0x6f18da`), behind a technology feature flag.

The alternatives themselves are drawn by `CTechnologyStatus::UpdateTechAlternatives` (`0x81d960`,
the tech `weight`, `GetTechWeight` `0x81bd40`) when a technology completes: game logic, not AI.

## 5. Economy and building

### The budget: `CCountryAI::MonthlyUpdate` (`0xb6ddc0`) **[V]** (calls) / **[I]** (formula)

On the AI's month: `SetBudgetArraySize`, `UpdateUpkeepBudget` (`0xb70af0`) and
`UpdateExpenditureBudget` (`0xb716b0`). `common/ai_budget` entries (`CAIBudgetEntry`: `resource`
(`+0x1d0`), `type` upkeep or expenditure (`EAIBudgetEntryType`, `+0x48`), `category` (an economic category with
`use_for_ai_budget`, `+0x208`), `potential`, `weight`, `desired_min`, `desired_max`; the last three
are scriptable values: `GetBudgetWeight`, `GetBudgetDesiredMin`, `GetBudgetDesiredMax`).

`UpdateExpenditureBudget`, per resource **[V]** (first pass) / **[open]** (the rest):

```
for each expenditure entry of this resource that is potential:
    W[category] += weight; total += weight; MAX[category] += desired_max; MIN[category] += desired_min
S = CEconomyCountryModule::GetResource(resource)          (the stockpile [I])
for each category with W > 0 or MIN > 0, if S > 0:
    a = S * W / total
    strategic resources: a = min(a, GetMaximumForCountry * W / total)
    a = clamp(a, MIN, MAX if MAX > 0 else a); a = min(a, S)
then a second pass hands out what the clamps left (0xb71f7a-0xb72100), not read in detail
```

`UpdateUpkeepBudget` has the same shape for upkeep entries (and `UpdateInternalUpkeepCache`); what
it splits (the income [I]) was not read. The results are a `CFixedResourceTable` per category
(`_ExpenditureBudget`, `_UpkeepBudget`), not saved. Spending checks them:
`CCountryAI::CanAffordExpenditure` (`0xb78f00`), `CanAffordUpkeep`, `WithdrawCost`, and the
commands posted with `AddAICommandWithCostForPosting<...>` (the cost withdrawn from the
category).

### Economic plan and build plan (`common/economic_plans`) **[V]** (calls)

`CAIInteriorMinister::MonthlyUpdate` -> `CAIEconomicStrategy::CalcBestEconomicPlan` (`0xb4c190`,
checks `IsPotential` and `IsFulfilled` of the plans [I] the first unfulfilled one) and
`CreateBuildPlan` (`0xb423e0`): `CalculateIncomeTargetBasedOnForecast`,
`UpdateIncomeTargetRecords` (save `ai_resource_target_records`), then `FillBuildPlan` (`0xb45610`:
eight parallel estimation tasks (districts, buildings, zones, orbitals, upgrades and repairs,
designations), then `ApplyOpportunityCostsToBuildPlan`, `SpecializeAllBuildables`), stable-sorted
by weight; `DestroySuperfluousDistrictsAndBuildings`. Weekly, `BuildAndUpgradeDistrictsAndBuildings`
takes the plan's items in order and posts `CAddBuildableToQueueCommand` while the budget affords
them. `UpdatePlanetDesignations` posts `CSetColonyTypeCommand`. `SpecializeAllBuildables`, starbase
buildings, edicts and deposit blockers draw the unsynced random (`CAICore::GetRandomInt` callers).

### Ships, armies, colonization

`CCountryAI::CreateNavyBuildData`, `CreateArmyBuildData` (strategic data) and the interior
minister's `BuildShipOfOwnerType` (civilian), `BuildArmies`, `BuildColonizer`; military ships are
built to fill fleet templates (`CAIMilitaryMinister::ReinforceFleetGroups`,
`UpdateFleetCompositions`, monthly) with designs from `RequestNewShipDesign` /
`CCreateOrUpdateShipDesignCommand` **[V]** (calls) / **[I]** (the roles). Colonization targets come
from `CCountryAI::CreateColonizeData` (`0xb6f280`), which draws the **synced** AI random
(`AddColonyData` -> `GetRandomIntSynced`). `HasPotentialBorderExpansion` (`0xb70890`, used by the
war aggressiveness) = `ai.colonizer` and (strategy list 19 not empty or fewer than
`AI_BUDGETING_START_YEARS` (15) years since `START_YEAR`) **[V]**.

## 6. Fleets (decision structure) **[V]** (names, calls)

`CAIMilitaryMinister::WeeklyUpdate` (`0xbfbe50`) manages fleet groups (`CAIFleetGroup`, 128 bytes:
target `SAITarget` (score, enemy power, fleet/planet/system, weight coefficient, type), type
`EAIFleetGroupType` (invade, raid, attack, defense, follow, destroy, war preparation, scripted
action), fleets, home base, status `EAIFleetUpdateStatus` (idle, peacetime, opportunist,
retreating, regrouping, merging, waiting, building, on mission)). Order: clear idle defensive and
scripted groups; `CalcDistanceToObjectives`; `CreateFleetGroupsFromStratagems` (the policy's
offensive and defensive stratagems: `CAIMilitaryMinisterDefaultPolicy::FillOffensiveStrategy`, ...,
which call `CCountryAI::RandomizePriority`, the synced random); prepare each group's data; validate
bases; `HandleEmergencyFTL`; `HandleFleetGroupOpportunities`; `HandleNonAssignedMilitaryFleets`;
`HandleTransportFleets`; sort the groups by target score; assign fleets
(`AssignFleetsToObjectives`, `CalcBestFleetAssignment`, `SelectBestFleetsFor`); bombing stance;
megastructure actions; `HandleFleetGroups` (move, gather, regroup, merge, attack). Targets are
scored by `SAITarget::CalcTargetScore` (`TARGET_BASE_SCORE` 100 and the `WAR_*_PRIO` defines);
groups are committed when their power reaches `CalcWantedFleetPower` (`ENEMY_FLEET_POWER_MULT`,
`MIN_FLEET_FOR_OPERATIONS`). Orders go out as fleet commands (`CQueueFleetOrderCommand`,
`CQueueFleetsOrderCommand`, `CFleetCancelOrdersCommand`, `CFollowFleetCommand`,
`CFleetLandArmiesCommand`, `CMoveArmyToOrbitCommand`, `CFleetCombatEmergencyFTLCommand`,
`CSwitchFleetStanceCommand`, `CGoMIACommand`, `CFleetUpgradeDesignCommand`, ...).

`CMission` / `CMissionType` (`common/missions`, `CalcAIWeight`) are leader missions, not fleets.

## 7. Moving the AI to Lua

### What the Lua AI needs

- **Its state**: the save's `ai = { ... }` block per country (section 1), plus what is rebuilt:
  day counters (`id % 7`, `id % 30`, `id % 360` at load), the two RNGs, the budgets, the fleet
  groups, and the strategic data (rebuilt by `CAIUpdateStrategicData` when the war state changes;
  the strategy lists themselves are saved).
- **The RNGs** (`ai/rng.lua`, or the Rust `rng.rs` exported): the Squirrel3 variant of
  simulation.md section 3, one generator per AI country:
  - unsynced `CAICore::_Random`: at load `seed = position = country id` (unless the game ran with
    `-loadrandomseed`); `r = noise(seed, position++) & 0x7fffffff`;
  - synced `_SyncedRandom`: from the save (`synced_random_seed`, `synced_random_count`); a new AI
    starts at `seed = id`, `position = h(id)` with `x = id * 542824007; x ^= x >> 8;
    x -= 1259093227; x ^= x << 8; x *= 947560250; x ^= x >> 8` (`0xb6d0fc`) **[V]**;
  - every draw site must be reproduced in the game's order, or the stream drifts: the unsynced
    stream is used by research (3 a day), the diplomacy pass (one per country of the galaxy, plus
    one per candidate), the war score (one per gated candidate, weekly), ally recruiting, the war
    roll, envoys, armies, decisions, astral actions, minor artifacts, edicts, starbase buildings,
    deposit blockers, buildable specialization (`CAICore::GetRandomInt` / `CAIModule::GetRandomInt`
    callers). About 25 draws a day per country in the 2210 saves.
- **The schedule** (in `scheduler.rs` phase `ai.process`): countries in the game state's country
  order; per country `DailyUpdate` (the `CCountryAI` part, then the modules in the order of the
  country type's `ai.modules`, section 8), then the weekly / monthly / yearly counters; then the
  commands, in country order, executed at the start of the next tick. Attitudes are a separate
  daily phase (2 of `DailyUpdate`). The AI reads the state as of tick 4: it must not see its own
  commands' effects until they execute.
- **The commands** it posts (about 150 posting sites, `CCountryAI::AddAICommandForPosting` callers):
  the Lua AI returns a list of command records; the engine side executes them in the command
  phase. The first ones needed: `CResearchTechnologyCommand` (queue research),
  `CAIPrepareWarCommand` (AI state; one global `CRandom` draw), `CDiploActionProposeCommand` /
  `CDiploActionRespondCommand` (diplomacy; declaring war creates the war), `CAIRemoveDiploAction`,
  `CAIUpdateStrategicData`, `CAddBuildableToQueueCommand` (construction), `CAddEdictCommand`, fleet
  orders.
- **Engine reads** (beyond the save's own fields): opinion
  (`CCountry::CalcOurOpinionOfOtherNoScopeCopy`, 2,142 instructions: the saved timed opinion
  modifiers of the relation, the triggered ones of `common/opinion_modifiers`, envoys, imperial
  authority, clamped to `OPINION_MIN/MAX`), casus belli (`CDiplomacyCountryModule::_CasusBelli`,
  `UpdateCasusBelli` with `common/casus_belli`), fleet power (`military_power` is in the save; the
  cache `_vCachedMilitaryFleetPower` is fp15 there), naval capacity, assault armies, border
  distance and bordering (relation `border_range`, `borders`), truces, war participants
  (`CWarParticipants::NewWar`: allies, subjects, pacts, federation), path existence between
  capitals, technology costs, and the script layer for `ai_weight`, `ai_will_do`,
  `should_ai_propose`, `ai_acceptance`, the budget values, war goal `ai_weight`.

### Proposed modules: `sim/lua/engine/ai/`

| module | contents | game functions |
|---|---|---|
| `init.lua` | `ProcessAI`: the per-country loop, counters, module order, command list; the attitude phase hook | `CGameState::ProcessAI`, `CAICore::Update`, `CCountryAI::Update/DailyUpdate` |
| `state.lua` | read and write the save's `ai` block; flags; strategy lists; `last_diplo_actions` expiry | `CCountryAI::ReadMember/WriteMembers` |
| `rng.lua` | the two AI generators, weighted pick (`GetWeightedRandomInternal`) | `CAICore::GetRandomInt`, `GetRandomIntSynced` |
| `research.lua` | tech choice | `GetTechToResearch`, `GetAIWeight` |
| `opinion.lua` | opinion of one country for another (shared with the script layer's `opinion` trigger) | `CalcOurOpinionOfOther` |
| `attitudes.lua` | the daily attitude update, one function per attitude type | `UpdateAttitudesThreaded`, `CAIAttitude::CalcAIWeight`, `NAttitude::*` |
| `war.lua` | war preparation and its command, readiness, target score, aggressiveness, war goal choice | `CAIForeignMinister::PrepareWar`, `CalcGoingToWarScoreAgainst`, `CheckShouldContinuePreparingWar`, `CCountryAI::IsReadyForWarWith`, `CalcStartWarData`, `CAIPrepareWarCommand`, `NAIUtil::SelectWarGoalType` |
| `diplomacy.lua` | the monthly proposal pass and responses | `MakeAIDiplomaticAction`, `BuildProposalList`, `ShouldAIAccept`, `CDeclareWarAction::ShouldAIPropose` |
| `acceptance.lua` | `GetAIAcceptance` and the per-action terms, peace acceptance | `Get*Acceptance`, `GetOfferPeaceAcceptance`, `CalcBestPeaceOffer` |
| `budget.lua` | `ai_budget` split, affordability | `UpdateExpenditureBudget`, `UpdateUpkeepBudget`, `CanAfford*` |
| `economy.lua` | economic plan, build plan, buildings and districts | `CAIEconomicStrategy::*`, `BuildAndUpgradeDistrictsAndBuildings` |
| `interior.lua` | the rest of the interior minister (edicts, policies, traditions, leaders, colonization, starbases...) | `CAIInteriorMinister::*` |
| `fleets.lua` | the military minister | `CAIMilitaryMinister::*`, `CAIFleetGroup`, `SAITarget` |

### Order of work and how to check each piece against the game's saves

The check is a run from one autosave to the date of the next one, compared field by field
(`lua/engine/diff.lua`). Two facts shape it: (1) the game's next autosave must come from a game
*loaded* from the first save (the unsynced AI RNG and the day counters restart at load), or both
sides use `-loadrandomseed`; (2) until every draw of the unsynced stream is ported, the stream
drifts after the first unported draw, so random choices can be compared exactly only until then.

1. **State and RNGs** (`state.lua`, `rng.lua`, `init.lua` with no modules): the `ai` blocks
   round-trip unchanged through a run; `last_diplo_actions` expiry; the counters. Check: the AI
   fields of the diff are equal where the game changed nothing.
2. **Research** (`research.lua`): daily, small, every AI country; it needs the technology costs
   (`engine/research.lua` has `CTechnology::GetCost`) and the `ai_weight` weights (the script
   layer's weight evaluation: factor and `modifier = { factor ... trigger }` blocks). Exact
   checks: the weights (compare with the game's debug tooltip of the technology view, which calls
   `GetAIWeight`, or with a probe in the running game); the first choice of each area after a
   load (on day 1 of a loaded game the research draws are at positions id, id + 1, id + 2 for an
   AI that has neither its diplomacy day nor an incoming proposal past its cooldown, since only
   the foreign minister's daily update runs before the interior minister's); after that, the
   queued technologies (`*_queue`) and the `technology` list of the next save, exact while no
   other draw intervenes, statistically afterwards. This also closes the gap noted in
   `research.lua` ("the next technology the AI queues").
3. **Opinion and attitudes** (`opinion.lua`, `attitudes.lua`): deterministic (no RNG); the save
   holds the result (`attitude = { country attitude weight priority date }`) and the opinion
   inputs (`modifier = {...}` of each relation). Check every attitude entry of the next save.
   Opinion is also needed by the script layer (the `opinion` trigger).
4. **War preparation** (`war.lua`): weekly; the save holds its result (`prepare_war`,
   `prepare_war_date_start`, `prepare_war_date`, `target`, `extra_attacker`). Deterministic parts
   checkable on their own: the gates, the candidate set and the score without its random term,
   the power check. The roll needs the stream position (after step 2 and the other draws of the
   week); the preparation end date needs the global `CRandom` (already in the engine).
5. **Diplomacy** (`diplomacy.lua`, `acceptance.lua`): the monthly pass and the responses; checks
   on the next save: new wars (declarations once a preparation is due), pacts, rivalries,
   `last_diplo_actions`.
6. **Budget and economy** (`budget.lua`, `economy.lua`): needs the engine's economy (the budget
   balance) and construction; checks: construction queues, districts and buildings.
7. **Interior rest, fleets**: last; fleets need movement and combat in the engine.

A runtime probe would make every step exact: the project's injected Lua in the running game
(the dev channel) can read `CAICore +0x32c` (the unsynced position) and the AI flags per country
each day, giving the number of draws per day and phase to compare with the Lua AI's.

## 8. Open questions

- The order of the modules: `CCountryAI::RefreshModules` (`0xb6d3e0`) builds the wanted list
  (country type `ai.modules`, then `CAIPersonality::OverrideAIModules`), deletes the modules no
  longer wanted and calls `AddModule` (`0xb6d140`, created through `CStellarisModuleRegister`,
  appended to `_Modules`) for the new ones in list order **[V]**; so a fresh AI updates its
  modules in the order of the list, but how `OverrideAIModules` reorders (replace in place or
  append) was not read.
- Which other daily handlers draw from the unsynced stream (the interior minister's daily
  `BuildArmies`, `HandleSpecialProjects`, colonization; `HandleRelations` does not draw itself, but
  calls `IsTimeToRespond`).
- The strategy list kinds (`CAIStrategicBase`, 33 lists; 1 is read as colony targets and 19 as
  border expansion targets in the war code) and how the save's `strategy = { id target value type }`
  maps to them.
- The budget's second pass (what the clamps leave), what `UpdateUpkeepBudget` splits, and the
  economic plan choice (`CalcBestEconomicPlan`).
- The war goal used by `IsReadyForWarWith` for the estimate: the first `CWarGoalType` with the
  byte `+0x564` set (which key sets it).
- `IsReadyForWarWith` step 4: the opportunist pass iterates the AI's own wars (as read); confirm
  with a runtime probe before copying it.
- `CalcBestPeaceOffer`: the preference between the offers and what the duplicated probes are.
- Whether `CCountryAI::Start` or the first `CAIUpdateStrategicData` after a load draw from either
  stream.
