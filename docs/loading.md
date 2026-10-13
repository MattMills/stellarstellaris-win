# The startup load

What the game does from the first frame of the load screen to the main menu, in vanilla 4.5.2
(Steam). `lua/stellar/loading.lua` puts all of it in the log on every run, with
`lua/stellar/databases.lua` for the databases.

## When the load is done

The load is done when the load screen goes away (`DestroyLoadScreen`, which nulls the load
screen's progress context). That is about 17 seconds after the progress bar reaches 100%.

The bar has three phases, each a part of it. A function per phase calls
`CGameApplication::LoadingScreenCallback(current, total, start, span)`:

| phase | bar | caller |
|---|---|---|
| interface (GUI) | 5% to 30% | `locGuiLoadingScreenCallback` |
| graphics (GFX) | 30% to 80% | `locGfxLoadingScreenCallback` |
| game databases | 80% to 100% | a lambda of `CGameApplication::InitGame` |

`RenderLoadScreen` draws the bar only when the progress goes up. Loading a save or starting a new
game uses named stages instead (`SPushLoadScreenState(start, end, __FILE__, __LINE__)`).

## The bar, Lua's

`CGameApplication::Init` runs `InitBase` (the interface phase), `CGraphics::Init3DTypes` and
`CApplication::LoadAssetsAndEntities` (graphics), then `InitGame`. `LoadingScreenCallback(app,
current, total, start, span)` draws `start + current * span / total` when that is more than it drew
last (a global, its gate), and keeps the game's services alive while it does
(`galaxy::api::ProcessData`, `CPdxAccount::Update`, `CPdxNakamaWrapper::Update`); nothing calls it
after the databases, so the bar stood at 100% for 16 seconds.

Each load keeps its timeline (`cache/load_timeline-<md5>.tsv`: when each phase and each milestone
on the game's thread began, from the first frame). The next load (`loading.bar`,
`src/dll/loading_hook.cpp`):

- shows each phase on its part of one bar for the whole load: the step hook gives
  `LoadingScreenCallback` the phase's new start and span, so the game draws the number and its
  text itself;
- crosses the milestones after it: entering a milestone starts its segment of the bar, and the
  game's thread moves along it (at most ten times a second, at marks and at each file read) by
  calling the game's own `LoadingScreenCallback(p, 100, 0, 100)`; `DestroyLoadScreen` draws 100%
  and gives the bar back to the game (a save's load screen is the game's);
- draws nothing of the game's own numbers once the phases begin (`RenderLoadScreen` called
  outside a step: its 30% and 80%), nor, before them, above where the first phase begins; and
  keeps the gate at what is on the screen.

The phases are mapped at once (`InitBase` may begin while Lua is still starting); the milestones
are scheduled once they are hooked (`loading.bar_schedule`). `loading_bar.txt` "game" leaves the bar
to the game. `C:\lfm\validate_load.sh` measures it: the frames drawn, out of order or not, the
longest time without one, the biggest jump.

## Beside the load

`CModifier::LogDefinitions` writes `modifiers.log` (4.3s on the game's thread) and nothing reads it
during the load. It runs on a thread of its own (`stellar.run_async`, its trampoline) from the end
of the PostReads, when the definitions are final; `InitGame`'s own call returns at once (its skip
flag), and the first call after it (`CEconomicCategory::LogUnusedGeneratedAddModifiers`) waits for
it (`stellar.join_async`). `modifiers.log` stays identical to vanilla. `background.txt` "off" leaves
it in its place. (`CModifier::InitDefinitionIcons` is called from inside `SetupDatabases`: the
SetupDatabases hook clears only the skip flags Lua's loop set, not those set from hooks inside it.)

## CGameApplication::InitGame

All on one thread, in this order. Times are from a run with the Lua lexer, in seconds from 0% on
the bar (about 7.5 seconds after the game starts):

| at | step | time | texts read |
|---|---|---|---|
| 0 | interface and graphics phases | 8.9s | 3,900 |
| 8.9 | `CGlobalScriptedVariablesDatabase::InitializeWithDirectory`, `CModifier::InitDefinitions` | 0.1s | |
| 9.0 | `NNullObjAndDatabaseInitUtil::SetupDatabases`: the databases | 17.2s | 12,450 (39.5 MB) |
| 26.2 | the same: deferred key references, `PostReadInitInstance` of each database | 2.0s | |
| 28.2 | `CModifier::InitDefinitionIcons`, `CGameRules::InitInstance`, achievements | 0.4s | |
| 28.6 | `CApplication::CalculateGameFilesChecksum` | 1.2s | |
| 29.9 | `CStaticModifierDatabase::Init` | 2.3s | 7,000 |
| 32.2 | `CTriggerDatabase::PostInit`: scripted triggers called with arguments | 2.7s | 90,000 |
| 34.9 | `CTriggerDatabase::PostValidate` | 0.2s | |
| 35.1 | `CEffectDatabase::PostInit`: scripted effects called with arguments | 2.1s | 10,000 |
| 37.2 | `CEffectDatabase::PostValidate`, `CEventManager::InitEventConnectivityMaps` | 0.1s | |
| 37.3 | `CModifier::LogDefinitions` | 3.7s | |
| 41.0 | `CGameApplication::PrintScriptingDocumentation`, portraits (21 calls) | 0.3s | |
| 41.3 | `CFrontEndIdler::CFrontEndIdler`: the main menu | | |
| 41.4 | the main menu: `CTriggerDatabase::PostInit` and `PostValidate` again | 2.1s | 27,000 |
| 43.5 | `DestroyLoadScreen` | | |

## The databases

`SetupDatabases` fills a table on its stack, one `SDatabaseObjectFunctions` (48 bytes) per
database: its name, `CreateInstance`, `DestroyInstance`, `CanInitialize` (or null),
`InitInstance` and `PostReadInitInstance`. There are 198 databases in 4.5.2; 126 have a
`CanInitialize`, 178 a `PostReadInitInstance`. `databases.locate` reads the table from the code
(`lea reg, [rip+x]` / `mov [rbp+d], reg`; the first store to each slot, since the frame is reused
later).

The loop:
1. Pick the first database left whose `CanInitialize` (its dependencies) returns true, or that
   has none.
2. Log "Initializing Database: <name>". It goes to a null logger in release builds.
3. Call `CreateInstance`, which makes the database object with its folder (e.g.
   `common/named_colors`).
4. Call `InitInstance`, the object's virtual `Init`, which reads the folder's files.
5. Report progress.

Then it resolves the deferred key references and calls every `PostReadInitInstance`.

A mark on each database's `CreateInstance` (an entry hook, `stellar.hook_entries`) and the
progress step after its `InitInstance` give each database's time and the texts and tokens it
read. `CWeaponTagDatabase` and `CSpeciesNamesDatabase` start with a jump and are not marked. The
longest:

| database | time | texts | tokens |
|---|---|---|---|
| `CJobTypeDatabase` | 3.0s | 247 | 62,000 |
| `CShipSizeDatabase` | 2.7s | 193 | 60,000 |
| `CAnomalyTypeDatabase` | 1.7s | 18 | 19,000 |
| `CEventManager` | 1.5s | 713 | 1,526,000 |
| `CTraitDatabase` | 1.5s | 4,995 | 203,000 |
| `CShipDesignTemplatesDatabase` | 1.1s | 1,039 | 251,000 |

Most of the time is not reading: `CJobTypeDatabase`, `CShipSizeDatabase` and
`CAnomalyTypeDatabase` read few tokens and spend seconds after the read. `CEventManager` reads 12.75
MB in about 1.5 seconds.

### In parallel (`databases.txt`: `parallel N`)

`databases.run_parallel` starts a database when the databases it depends on are done (from
`CanInitialize` and the access trace, `databases.txt` `trace`), on N workers and the game's
thread. The databases were written to run one at a time, and the declared dependencies are not
all of them. Each database runs under an exception handler (`stellar.db_start` /
`stellar.db_call`, `src/dll/database_workers.cpp`), and a failure ends the load (the database is
half made) and teaches the next load:

- **conflicts** (`cache/database_conflicts-<md5>.tsv`): the failed database and each database
  that ran while it did never run at the same time again;
- **waits** (`cache/database_after-<md5>.tsv`): the failed database waits for every database
  before it in the game's order (`cache/database_order-<md5>.tsv`, kept by a `lua` load) that was
  not done when it started: it may have used something not made yet, which no exclusion fixes
  (`CSituationTypeDatabase` reads the event namespaces `CEventManager` makes; the trace does not
  see it, they are not the instance's);
- a failure no handler sees (a broken heap is a fail-fast: the process ends at once) leaves
  `cache/database_inflight-<md5>.tsv`, what ran then and in the quarter second before: the next
  load adds those as conflicts.

`C:\lfm\learn_boot.ps1` loads the game until a load gets through. The faults, named through the
GOG build (the same code at other addresses), were mostly not between two databases but in tables
every database writes. Those functions run under one recursive lock (`stellar.serialize`,
`databases.SHARED`), left by a `__finally` when a database fails:

| fault in | the table | serialized |
|---|---|---|
| `CPdxArray<SDatabaseObjectReference>::MoveInitDestroy` | the deferred database object references, resolved after the load | `CGlobalDeferredDatabaseObjectResolver::Register_Internal` |
| `CPdxRobinHoodTable<CTrigger*>::EmplaceWithHash`, `Rehash` | the trigger database's set of every trigger | `CTriggerDatabase::AddTrigger`, `CTrigger::~CTrigger` (and `CScriptableLookupValue`'s, a table of the same kind) |
| none: 243 triggers missing from the census | a switch's condition is read with adding triggers turned off (a flag of the trigger database): the triggers other threads made meanwhile were not added | `CTriggerSwitchBase<…>::ReadCondition` (the effect's and the trigger's) |
| none: "Invalid script flag" in the effects' `PostValidate` | the script flags' names (`CPdxIntegerFlags::_AllFlags`, `_AllFlagsReverse`) | `CPdxIntegerFlags::CreateFlagIndex`, `GetFlagIndex`, `GetFlagString` |
| `CEffectDatabase::PostInit` (after the databases) | the effect database's set of every effect, broken without a fault while the databases ran | `CEffect::CEffect`, `CEffect::~CEffect` |
| `CModifier::~CModifier` | the post-init modifiers (modifiers read from script, finished after the databases): a list every modifier searches when it goes | `CPostInitModifierDatabase::CreatePostInitModifier`, `CModifier::~CModifier` |
| `CHashTable<CString, CNameSpace>::Find` | the event namespaces | `CEventManager::GetNameSpace`, `Find` (found as `GetNameSpace`'s first call) |
| `CPdxArray<CPdxModifierDefinition>::SetNewDataAndCapacity` | the modifier definitions | `CModifier::TryAddDynamicModifier`; the array is reserved for 131,072 first so it never moves under a reader |

Modifier types are numbered as they are made, so the databases that make them in `InitInstance`
(recorded by the lock: `cache/database_modifier_writers-<md5>.tsv`, `databases.ORDERED`) are
chained in the game's order, and the `PostReadInitInstance` calls run in the game's order too.
Script flag ids are numbered the same way, but a flag is only a name: a load in the game's order
keeps the 10,088 names in id order (`cache/flag_names-<md5>.tsv`, `stellar.flags`), and a parallel
load gives them their ids before its databases start (`CreateFlagIndex` for each), so the 29
databases that make flags need no order between them.

The loop starts, of the databases ready, the one with the longest chain still to come after it
(with each database's time from the last boot), not the table's order: a short database late in
the table that a long one waits for started seconds late. Each line of
`cache/database_boot_order-<md5>.tsv` says what the database waited for last; `C:\lfm\crit.lua`
walks back from the last one. A `CanInitialize` that reads a global that is no database's makes
a barrier (waits for every database before it), unless the global is set when the databases
start (`CGui::_pGui`); `CEventManager`'s instance is stored 262 bytes into its `CreateInstance`,
past the 256 first read, and seven databases waited for everything.

What the handler learns is checked with `C:\lfm\stress_boot.ps1`: loads from the same start (the
learned waits set aside, those of `-Keep` kept), each validated. With only
`CSituationTypeDatabase`'s 7 waits (it reads the events `CEventManager` makes), 14 loads in a row
were identical to vanilla; the 72 other waits and 2 conflicts learned before were not needed and
were dropped (kept in `cache/learned-before-pruning`). A failure logs the stack (game addresses as
`+rva`, to name with `sym.py`) and, for a C++ exception, the type thrown.

On this machine (4 cores, 8 threads) the phase takes 7.6-8.8s against 10.7s one at a time. What
bounds it is a chain of real dependencies (`CShipSizeDatabase` -> `CPopCategoryDatabase` ->
`CJobTypeDatabase` -> `CEventManager` -> `COnActionDatabase` -> `CScriptedActionDatabase` ->
`CShipDesignTemplatesDatabase`), and each database takes about twice its time alone while the
others run (`CEventManager` 2.9s against 1.4s).

A load that gets through is checked against vanilla with `C:\lfm\validate_load.sh`: error.log
(558 bytes), `modifiers.log` (identical), the census (1,318,141 triggers, 424,716 effects).

The wrapper forwards integer arguments only (16: `TryAddDynamicModifier` takes 12; forwarding 8
lost its category, and every modifier type came out with none). The lock is taken on every thread
while the databases run (a database's `InitInstance` hands work to the game's task threads), and
on none after: after, the game calls some of these holding its own locks, and taking this one too
spun the load forever.
