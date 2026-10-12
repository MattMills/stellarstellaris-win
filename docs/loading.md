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
