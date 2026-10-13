# Startup (4.5.2)

From the process entry to `CApplication::Run`: what runs, in which order, and where the command line
options ([stellaris-command-line-args.md](stellaris-command-line-args.md)) take effect. Reverse
engineered from the GOG 4.5.2 build and its PDB; addresses are GOG RVAs. The tools are in
`tools/re/cmdline`.

## Entry

```
sub_2054bf0  (SDL's WinMain)    GetCommandLineW, CommandLineToArgvW, to UTF-8, SDL_main(argc, argv)
SDL_main                         0x14ccc0
  SDL hint SDL_IME_SHOW_UI = 1, NThreads::_bIsMainThreadSet, SetThreadPriority(current thread, 1)
  CPdxCommandLine::_pInstance = new CPdxCommandLine            0x3145048
  CPdxCommandLine::Init(argc, argv)                             0x1b25650  ("Failed creating commandline")
  CClausewitzInit::_pInstance = [CFreeImageStartup]             0x3144b80, each ->vfunc[1]() now,
                                                                ->vfunc[2]() after RunGame returns
  CReloadManager::_Instance = new CClausewitzReloadManager
  ApplicationUtilsCommandLineArgs(argc, argv)                   0x1b0a0a0  console variables
  RunGame(argc, argv)                                           0x14fa40   returns the exit code
```

The C runtime's `__argc`, `__argv` and `_acmdln` are never read by game code: the command line
reaches the game only through `SDL_main`. `CPdxCrashReporter::WriteCrashMetaData` writes `argv[1..]`
into crash reports (`LaunchArguments:`).

### CPdxCommandLine

`Init` copies `argv` (`[this+0x20]`, count `[this+0x18]`), then builds a `CPdxArray<SSplit>` at
`[this+0x8]` (count `[this+0x14]`): one entry of 96 bytes per option, two `CString`s, key at +0 and
value at +0x30. It is sorted (`std::_Stable_sort_unchecked`, by `memcmp` / `operator<=>`, so
case-sensitive), and `FindIndexSorted<CString, SSplitComparer>` (`0x1b25d90`) binary-searches it.
`HasOption` (`0x1b25c30`) and `GetOptionArgument` (`0x1b25cb0`) wrap that search; many callers
inline it, building the key in a local `CString` just before the call.

### ApplicationUtilsCommandLineArgs

Joins `argv[1..]` (each followed by a space), splits at `-`, then each piece at `=`. A piece without
`=` gets the value `true`. With exactly two parts, both trimmed, the name lowercased:
`map[name] = value` in a global `std::unordered_map<CString, CString>` (GOG `0x3134cd0`), and
`GetTweakable(name)->SetFromText(value)` when a console variable has that name. `AddTweakable`
(`0x1b44940`), which registers console variables, looks the same map up, so a variable registered
later (for example by a GUI) still gets its value. `SetFromText`: `CTweakableBool` takes `0`,
`false`, `no` (any case) as false and everything else as true; `CTweakableInt` `atoi`;
`CTweakableFloat` `atof`. No range check.

## RunGame

`RunGame` keeps a list of named time stamps (`start`, `create application`, `await verification`,
...) and logs them at the end as `[Thread n] Startup real time: x ms` and `- <name>: x ms`.

1. `InitializeFrameStringAllocator`, the `start` stamp.
2. `argv` scan: an argument equal to `-editor` or `--editor` sets `g_bIsEditorMode` and returns
   `editor_main(argc, argv, IFEditorInterface)` (`0x1bbe8f0`, the asset and map previewer).
3. `gsAppicationName = "Stellaris"`; SDL video init (returns 0 if it fails).
   `CGuiType::_pReadGameSpecificFunc = CGameGraphics::ReadGameSpecificGuiTypeMember`.
4. `CSystem::CreateInstance`, `CTiming::CreateInstance` and `StartupBegin`,
   `CSettings::CreateInstance`, `CPdxProgram::CreateInstance` and `Initialize`.
5. The option loop: the joined command line cut at `-`, each piece trimmed, from the second piece
   on: `ParseClausewitzCommandLineOption(piece, &g_ClausewitzOptions)` (`0x1a3a2d0`), and when it
   does not take the piece, `RunGame`'s own comparisons. Results go to globals or to locals that
   step 12 captures. `g_vGlobalCullDistance` is set here too.
6. `GetMatchmakingFromCommandLine` (`0x14d190`): `+connect...` into a local `SNetAddress` and
   password.
7. `PdxGOGInit`, `PdxGOGSignIn` when it succeeded.
8. `StartVFS(userdir, "Stellaris", false, mods)` (`0x14d990`), see [below](#startvfs).
9. `CPdxEvents::CreateInstance`, `CApplication::ShowLoadWindow` (the SDL load window).
10. `CreateCrashReporter`. `pGlobalFilterLogger = new CFilterLogger`; `logprefix`, `logpostfix`
    and `logall` from `CPdxCommandLine`; `InitializeLogging` ([below](#logging)).
11. `InitTaskSystem(gnCmdLineThreads)` (`0x1b39aa0`): `-1` (the default) gives max(4, logical
    processors) - 1 workers, other values are clamped to 4 .. max(4, logical processors);
    "Spawning %d worker threads".
12. `CContextOwner`, then the [startup task](#the-startup-task) (`RunGame::<lambda_1>`, `0x151560`)
    runs as the primary task (`CreatePrimaryTask`). The main thread waits with
    `CPdxEvents::_pInstance->vfunc[2]()` until `CTask::IsDone`. Stamp `create application`.
13. If the task asked to quit (`-dlcmod`), `RunGame` returns its exit code.
14. `new CGameApplication(contexts)` (1408 bytes), `SetProductName("augustus")`,
    `SetMatchmakingConnect(address, password)`, `GetAutoClientDataFromCommandLine` and
    `CApplication::SetAutoClientData`, `SetLoadAssetsAtInit`, `vfunc[7]`,
    `SetGameControllersEnabled(false)` unless `-gamepad`, the game controller group.
15. Stamp `await verification`, the startup times, `VFSGetAllowFileAccessOnMain() = 0`,
    `CGameApplication::SendInitialTelemetry`, `CApplication::Run` (does not return here).

`CApplication::CApplication` copies `g_DebugMode` (`-debug_mode`) to `_bIsInDebugMode` (+0xcc).

## The startup task

`RunGame::<lambda_1>::operator()` (`0x151560`). Its captures, by `[this+n]`: 0 the
`CContextOwner`, 8 `settings=`, 0x10 `message_settings=`, 0x18 `alert_settings=`, 0x20 the
`dlcmod` flag, 0x28 the quit flag, 0x30 the exit code, 0x38 `exclude_dlc=` list, 0x40 `mod=` list,
0x48 `userdir=`, 0x50 the application name, 0x58 `logprefix`, 0x60 `logpostfix`, 0x68 `logall`,
0x70 `language=`, 0x78 the joined command line.

1. `PdxSocialPermissions` (if not created yet).
2. A `CChecksum` of `Cygnus v4.5.2`; `CContextOwner::InitPdxSdk` with the game name "stellaris"
   ([below](#pdx-sdk)); the UGC context ("No UGC backend available for current platform."
   on GOG), `InitStoreSystem`.
3. `CDLCManager::_pInstance = new CDLCManager`, `CDLCManager::Initialize` (`0x1a3d780`): `_DLCFolder =
   "dlc"`, `_ModFolder = "mod"`, `ReloadMetaData`, `ReloadDLC`, `ReloadMods`, then `dlc_load.json`
   (`SDlcLoadFile`): `enabled_mods` into `_EnabledMods` (+0x88) and `disabled_dlcs` into
   `_DisabledDLC` (+0x70).
4. `LoadSettings`, `LoadMessageSettings`, `LoadAlertSettings` with the `settings=` ... file names
   (defaults `settings.txt`, `message_settings.txt`, `alert_settings.txt`; a missing settings file
   sets `g_bFirstTimeStartup`).
5. With `-dlcmod`: `CDLCManager::CreateDLCModInfoString`, `AttachConsole(ATTACH_PARENT_PROCESS)`,
   written to `STD_OUTPUT_HANDLE`; quit flag, exit code 0; the task ends.
6. Every DLC in `_DLCs` gets `_bVerified = 1`; each `exclude_dlc=` value not yet in `_DisabledDLC`
   is added.
7. `CContextOwner::InitCloudStorageSystem`. The `mod=` list is replaced by `_EnabledMods`.
8. `NHostLanguage::Setup`, `NGameDLC::Setup`.
9. The loggers are dropped, `VFSShutdown`, `StartVFS(userdir, name, true, mods)`; PhysFS state flag
   set; a new `CFilterLogger` and `InitializeLogging` again, appending to the logs.
10. `StartPreEnumeration` and 239 `VFSPreEnumerateFiles(folder, extension)` calls: `music`,
    `map/galaxy`, nearly every `common/...` folder, `events`, `localisation`, `flags`, the `gfx` and
    `interface` files, `dlc_metadata/dlc_recommendations`, ...
11. `InitLocalisation(&firstStart, language)` (`0x14f020`): the language is `language=` or the one
    in the settings (empty: first start). `ExecuteLocalizationOptions` (the localisation tools,
    which may exit) and `PdxLocalizeSetup(language, "localisation", "localisation/languages.yml")`;
    the `toggle_string_id` and `toggle_string_id_and_loc` console commands; the
    `pdx_online_assets/localisation` folder.
12. `CReferenceObject::TotalInit`, `GetModFromCommandLine` (searches `-mod `; the result is
    dropped).

## StartVFS

`StartVFS(userdir, appName, withMods, mods)` (`0x14d990`):

- `VFSInit`. User directory: `userdir=` if given, else `VFSGetCustomUserDir`, else
  `VFSGetDefaultUserDir(appName)` (Documents/Paradox Interactive/Stellaris). `MountDirAsHighestPrio`
  and `PHYSFS_setWriteDir` on it.
- With mods (the second call): `_EnabledMods` becomes the sorted, unique `mods` list,
  `CDLCManager::AppendVerifiedToPath` mounts the enabled DLC and mods, and when
  `CDLCManager::_UserDirAppend` is set, `<userdir>/<_UserDirAppend>` is created
  (`CreateDirectoryW`); if that fails with `ERROR_PATH_NOT_FOUND`, `MessageBox` "Could not create or
  read directory" and `exit(0)`.
- `ApplicationUtilsLoadAssets`.

## Logging

`InitializeLogging(filterLogger, prefix, postfix, append, logall)` (`0x14de90`) opens one
`CFileLogger` per file, `logs/<prefix><name><postfix>.log` in the write directory (`VFSCreatePath`
first): game, ai, setup, error, system, memory, time, profiler, info, event_data, debug,
script_profiling, script_profiling_summary, and
`logs/script_documentation/<prefix>{triggers,effects,scopes,modifiers,localizations}<postfix>.log`.
The first call truncates (`EFileMode` 1), the call from the startup task appends (2).

`CFileLogger` flags (+0xc8), from `CFileLogger::Log` (`0x1b3a410`): 1 flush after each write,
2 `[hh:mm:ss]`, 4 `[file:line]`, 8 drop a message whose (source file, line, text) hash was already
written. The flags are `8 * !logall + 7` for game, ai, setup, error, system, memory, debug and the
script documentation (15, or 7 with `-logall`), profiler 9 or 1, time 7, info and event_data 1,
script_profiling and script_profiling_summary 15.

Other users of the prefix and postfix: `CTiming::DumpDataToFile` (on quit and yearly,
`logs/<prefix>timer_dump_<galaxy name><postfix>.txt`), `_BuildOOSDump` (copies the logs into the OOS
dump), `editor_main`. `GetCrashReporterSettings` attaches the fixed `logs/error.log`,
`logs/system.log` and `settings.txt`.

## Crash reporter

`GetCrashReporterSettings` fills `SPdxCrashReportSettings` (product "stellaris", the backtrace
submit URL, the attached files); `-nopopup` clears `_bLaunchCrashReporter` (+0x245).
`CPdxCrashReporter::CPdxCrashReporter` sets `_CrashReporterAppDir` to
`PHYSFS_getBaseDir() + "/crash_reporter/"` or `crash_reporter_dir`. On a crash
`GenerateCrashReportThreaded` (`0x1ca1750`) writes the minidump, exception and stack files and the
copies, then (if `_bLaunchCrashReporter`) `LaunchCrashReporterApp` runs
`<dir>/binaries/CrashReporter.exe --crashdir=... --uploadurl=...` ("CrashReporter could not find
CrashReporterApp" when it is missing).

## PDX SDK

`CContextOwner::InitPdxSdk` (`0x1a44a50`) sets the SDK config: game name and version, language,
number of clients, `SetSessionToken(--pdx-launcher-session-token)` when given, the log folder
(`%s/logs` in the write directory), the gaming network name, and
`SetSkipLegalDocumentsFlow(true)` with `-gdpr-compliant`. In the account flow,
`CPdxAccount::InitLegalDocsPromptState` marks every unviewed legal document as viewed with
`-gdpr-compliant`, and `InitGetLinkAnswerState` sets `_UserLinkAnswer` (+0x22c) to 2 with
`-automated_test` ("Automated test, skipping third party account linking prompt"; 1 is
accepted, 0 asks).

`CPdxNakamaClientSettingsBuilder::Build` (`0x1ca79f0`, from the `CPdxNakamaWrapper` constructor):
`nakama_key`, `nakama_host`, `nakama_port` and `nakama_ssl` replace the built-in server (host
`stellaris.online.paradox-interactive.com`, port 443, SSL) only when all four are present
(`[PDX NAKAMA] Using host from command line [%s:%i] SSL=%s`).

`anonymous namespace::IsMultiplayerEnabled` (`0x100efbc`, used by `CPopsLoginGui::TryLogin` and
`CPdxOnlineLoginDialog::OnDecline`) is true when the account object's flag (bit 0 of +4792) is set,
or always with `-nopdxmp`.

## Joining a multiplayer game from the command line

```
RunGame
  GetMatchmakingFromCommandLine(joined, &address, &password)   0x14d190
    CString::SplitLong(' '); keyword tokens compared with strcmp, the value is the next token
    +connect <host>:<port>   NetGetAddressFromHost -> _IP (+0x20), atoi -> _Port (+0x24)
    +connect_lobby <n>       CString::GetUInt64 -> _nID (+0x18)
    +connect_pdxmp <s>       NetAddressFromString (0x1c8db10):
                               "<uuid>.nakama" or "...nakama-<digit>"  type 5 NAKAMA_MATCH_ID
                               "R:<n>"                                  type 4 RAIL_ID
                               contains '.'                             type 1 IP_PORT, no port
                               else                                     type 2 UINT64, _nID
    +password <pw>
  CGameApplication::SetMatchmakingConnect                      0x1bb250
    _MatchmakingConnectNetAddress (+0x478), _MatchmakingConnectPassword (+0x4d0)
CFrontEndGui::Update                                           0xf14fc0
  SNetAddress::IsValid (0x1c8d090): type 5, or _nID > 0, or _nPdxID != 0
  -> CFrontEndGui::ShowMultiPlayer (unless the PDX login GUI is up)
CMultiplayerMenuView::Show
  DoJoinDirect(address, md5(password)) (0x10da570) -> ConnectToGame; the stored target is cleared
```

`+connect <host>:<port>` leaves the type at NULL with `_nID` 0, so `IsValid` fails and nothing
happens. The console command `matchmaking_connect` (`OnExecute_MatchmakingConnect`, `0xed4c00`,
`NetAddressFromCommandLine` `0x1c8ddd0`) parses `+connect`, `+connect_lobby` and `+password`
(password up to 127 characters), not `+connect_pdxmp`.

`CMultiplayerMenuView::Show` takes the player name from `g_PlayerName` (`-name=`), then
`CSettings::GetLastName`, then the platform user name, then "Unknown".

The auto client: `GetAutoClientDataFromCommandLine` (`0x14d5f0`, `ExtractArgument` `0x14d500`) and
`CApplication::SetAutoClientData` (`0x1a47ab0`) fill `CApplication::_bIsAutoClient` (+0xd8),
`_AutoClientIPAdress` (+0xe0), `_AutoClientServerName` (+0x110), `_AutoClientPassword` (+0x140),
`_AutoClientCountryTag` (+0x170), `_AutoClientNick` (+0x1a0) and `_nNumClients` (+0x1d0) = 0. No
code reads them back in 4.5.2.

## After CApplication::Run: options the idlers read

`CGameApplication::InitGame` (`0x1ba200`):
- `g_bDumpConsoleCommands` (`-console`): after every console command is registered,
  `CConsoleCmdManager::DumpConsoleCommands` (`0x1b3f1f0`) logs `<syntax>\n - <help>` for each
  (category 0x10008, `logs/info.log`).
- `g_bCombatOnlyMode` (`-combat_debug`): `CCombatTestScenarioDatabase` (`combat_test_scenarios.txt`)
  and a `CCombatDebugIdler` (`0x8b4050`) as the first idler instead of `CFrontEndIdler`. With it
  `CGameState::MonthlyUpdate` returns at once, much of `DailyUpdate` is skipped, the
  `CAIInteriorMinister` updates return, and `CFleet::CanAddShip` skips its FTL, compatibility and
  limit checks.
- `TryMakeElasticLogger` (`-elasticsearch...`).

`CFrontEndIdler::SetAsCurrentIdler` (`0x8ba820`): with `g_nGameDebugRandom >= 0` (`-random=`),
`CSystem::_nSeed` and `CRandom::_Random` get that value instead of `QueryPerformanceCounter`.
`CGameSetup::StartSyncPlayers` (`0xb280e0`) posts `CSetRandomSeed(n)`.

`CFrontEndIdler::UpdateInternal` (`0x8b9440`), every main menu frame:

1. `--continuelastsave`, once per process (static guard `0x3143295`):
   `SMostRecentSaveInfo::ReadFromDisk` (`0x972370`) reads `continue_game.json` (`title`, `desc`,
   `date`; written by `SMostRecentSaveInfo::WriteToDisk` `0x971d00` from
   `CSaveGameTaskManager::CreateMemoryFiles` with every save; `title` is the save's `_FileName`). On
   success `g_QuickStartSave = title`, `g_bQuickStart = 1`.
2. `GetOptionArgument("empire")`: `CEmpireDesignDatabase::GetDesignByKey` (`0x521650`, prescripted
   designs, then the user's), if valid and playable a human player (`CSettings::GetLastName`) with
   that design, `[this+536]`, `[this+537]`, and `LaunchNewGame` the next frame. No once-only guard.
3. The quick start block (`0x8b9fe8`..`0x8ba436`), while `g_bQuickStart` and nothing is launching:
   - No save name: a human player (last name, ready, primary local) with a default `CEmpireDesign`
     whose `_bRandomized` (+0x38) is 1; `CFrontEndIdler::LaunchGame` (`0x8bb420`), then
     `LaunchNewGame` (`0x8bb450`).
   - A save name (`"` removed by `RunGame`): if `VFSExists(name)`, the list is skipped (and the
     metadata read of an empty `SSaveGameFile` fails). Otherwise `RetrieveSaveGames("save games")`
     (`0x9705b0`: `*.sav` recursively and the cloud saves, newest first); unless the name is
     `latest`, the first save whose `<_Path>/<_File>` contains it; else the newest; none: quick
     start off. A major version jump: `RESUME_MAJOR_VERSION_WARNING_TITLE` / `_DESC` with
     `GAME_VERSION`, quick start off. `HasOtherDLCs` or `IsBadVersion`: off. Then
     `CFrontEndIdler::LaunchSave` (`0x8bc1d0`).

`CInGameIdler::RestoreDeviceObjects` (`0x930330`), on every game start and load:
- With quick start a new game skips `CStartScreenWindow::Show`; `CMessageSystem::Update`
  (`0x324bac`) does not hold messages back for the start screen.
- `g_IngameConsoleCommands` (`-igc=`, `-one_year`, `-overnight`): for each,
  `CConsole::AddLine("IGC Command: " + cmd)` and `CConsole::RunCommandNow(cmd)`. Never cleared.
- `g_bEnableGameStateTimer` (`-gamestatetimer`): `CGameStateTimer::SetEnabled` (`0x90dc70`) on
  `g_CurrentGameState + 0xa58` opens `logs/gametimer_YYYYMMDD_HHMMSS.tsv` (`Game Date`,
  `Time Unit`, `Seconds`); `CGameStateTimer::Tick` (`0x90df60`, from `HandleTurnTick`) writes the
  wall time of each Micro (tick), Day, Week, Month and Year, and flushes weekly.
- `g_bEnableLogEmpireStats` (`-logempirestats`): `CLogEmpireStats::_bEnabled` (+0xa98);
  `CLogEmpireStats::Tick` (`0x90e8f0`) writes
  `logs/empire_stats_YYYYMMDD_HHMMSS_<galaxy template>_<difficulty>.tsv` (`Game Date`, `Empire`,
  `IsNomad`, `Plan`, `Economy`, `Military`, `Tech`).

`CInGameIdler::UpdateInternal` (`0x927ee0`): while `g_nQuickRestartNum > 0`, after about 5 s of
frame time (`vQuickRestartDelay`), `_bDoResign`. `CInGameIdler::DoResign` (`0x9333f0`) decrements
it, or clears `g_bQuickStart` at 0. `CGameIdler::Idle` re-arms the quick start for the reload world
path (`gReloadWorldStage`), not for the command line.

`CInGameIdler::CheckTick` (`0x933940`): on the server, no tick while the game state has fewer than
`g_WaitForClients` humans.

`CGameState::HandleTurnTick` (`0x252830`):
- `g_bIncrementalSaves` / `g_nIncrementalSaveFrequency` (`-incrementalsaves`): not in ironman
  (`_pGalaxyConfiguration->_bIronman`) unless `g_bOvernight`. On 1 January when year % frequency
  is 0 (frequency n, or `NGameplay.INCREMENTAL_SAVE_FREQUENCY` when n <= 0), once per date:
  `CInGameIdler::SaveGame` of `<_GameName>_<yyyy.mm.dd>`.
- `g_bOvernight`: forces those saves, and `CInGameIdler::DoQuit` in 2600.
- `one_year`: `OnExecute_OneYear` (`0xed3100`) unpauses, sets speed 4 and `CGameState::SetOneYear`
  (`0x25ccb0`, end = now + 8640 hours); at the end `Performance run took <x>s` in game.log
  (category 0x10002), pause, "Run Finished".
- `overnight`: `OnExecute_Overnight` (`0xec7eb0`, not in multiplayer) pauses, sets
  `NCustomAssert::SessionFolder = overnight/<save folder>`, runs `observe` and
  `ticks_per_turn <arg or 300>`, `g_bFrameSmoothing = 0`, `g_bCameraSearchForCombat = 1`,
  `g_bOvernight = 1`; `-overnight` then queues `game_paused false`.
- `CTiming::DumpDataToFile` (`0x1abcc0`) from `CGameState::YearlyUpdate` and
  `CGameApplication::OnQuit` when `-timer` enabled it.

Loading a save: `CGameState::ReadMember` restores `random_seed` / `random_count` and
`CCountryAI::ReadMember` the AI's random fields only with `g_bUseSavedRandom` (`-loadrandomseed`);
`CGameState::InitPostRead` (`0x24be80`) then applies `-rng_seed=` / `-rng_pos=` (`CSystem::_nSeed`,
`CRandom::_Random`, `CSystem::_nRandomCount`).

`NAdvisorVoice::SetForCountry` (`0x7c5da0`): with `g_bEnableBajenAudioGroup` (`-bajen`) the advisor
voice group is `l_bajen`.

`anonymous namespace::LogLoadTimes` (`0x271f70`, from `OnNewGameStarted` / `OnSavedGameStarted`):
`Loading time: %f` from `g_pLoadTimer` (`-loadtimes`), category 0x2000, which no file logger takes.

## Graphics device

`CGraphics::InitGfx` (`0x1a6f600`): unless `g_RenderTypeIsForced`, `GfxSetRenderType(1)` (DX11).
`GfxSetRenderType` (`0x1cc7070`) points the `Gfx*_Callback` function pointers at one backend
(`EGfxRenderType`: 0 DX9, 1 DX11, 2 OpenGL, 3 OpenGL4; `GfxInitInternalDX9`, `...DX11`,
`...OpenGL`, `...OpenGL4`). `GfxInit` fails: if not forced, "Failed creating d3d11 device! trying
with d3d9." and DX9; then "Failed! Trying desktop resolution" with the desktop size.
`CGraphicsSettings::Init` takes the render type from the graphics settings unless forced.

## Globals

| global | GOG 4.5.2 | set by |
|---|---|---|
| `CPdxCommandLine::_pInstance` | `0x3145048` | `SDL_main` |
| `g_ClausewitzOptions` (`SClausewitzCommandLineOptions`, 152 bytes) | `0x28001b0` | `ParseClausewitzCommandLineOption`: `_UpdateLoc` +0, `_LocalizationImportLocalized` +0x30, `_ConnectToHost` +0x60, `_bLocalizationExportUnlocalized` +0x90, `_bLocalizationImportLocalized` +0x91, `_bLocalizationTagLocalized` +0x92, `_bLocalizationPurgeLocalized` +0x93, `_bLocalizationPrintAll` +0x94 |
| `COosChecks::_Initial`, `_Current` (`COOSCheckSettings`) | `0x28888e0`, `0x28888c8` | the OOS options; `_nRandomLogStackDepth` +0x8, `_nRandomLogExtraFrames` +0xc, `EOosFlags` +0x10 (HardCheck 1, ClientSaves 2, LocalCheck 4, RandomLog 8, HotjoinLog 16, RandomCache 32, DeepSyncScan 64) |
| `g_DebugMode` | `0x3144b89` | `-debug_mode` |
| `g_RenderTypeIsForced`, `g_bLegacyDevice`, `g_bAMDWorkaround` | `0x3144c4c`, `0x321a93c`, `0x2800104` | renderer options |
| shader compile flags | `0x321a900` | `-debug_shaders` ... (D3DCOMPILE flags) |
| sRGB flag, `g_bHDREnabled` | `0x27fff79`, `0x27f4e78` | `-nosRGB`, `-nohdr` |
| `gnCmdLineThreads` | `0x27f3760` | `-threads=` (default -1) |
| `g_nGameDebugRandom` | `0x27f3764` | `-random=` (default -1) |
| `g_WaitForClients` | `0x30fcef0` | `-wait_for_clients=` |
| `g_IngameConsoleCommands` (`CPdxArray<CString>`) | `0x2800148` | `-igc=`, `-one_year`, `-overnight` |
| `g_QuickStartSave`, `g_bQuickStart`, `g_nQuickRestartNum` | `0x2800118`, `0x30fcf02`, `0x30fcef4` | `-quick`, `-quick=`, `-quickrestart=`, `-overnight` |
| `g_PlayerName` | `0x2800178` | `-name=` |
| `g_bDumpConsoleCommands` | `0x30fcefe` | `-console` |
| `g_bSupressErrorLog` | `0x31003d8` | `-suppresserrorlog`, `-gamestatetimer` |
| `g_bEnableBajenAudioGroup` | `0x30fceff` | `-bajen` |
| `g_bIncrementalSaves`, `g_nIncrementalSaveFrequency` | `0x30fcefc`, `0x30fcef8` | `-incrementalsaves[=]` |
| `g_bUseSavedRandom` | `0x3100b20` | `-loadrandomseed`, console variable `UseSavedRandom` |
| `g_bUseForcedSeed`, `g_nForcedSeed`, `g_nForcedPosition` | `0x3100b21`, `0x3100b24`, `0x3100b28` | `-rng_seed=`, `-rng_pos=` |
| `g_bCombatOnlyMode` | `0x30fced8` | `-combat_debug` |
| `g_bDebugToolTip` | `0x31003d9` | `-debugtooltip` |
| `g_bOvernight` | `0x30fcefd` | `-overnight` |
| `g_bEnableGameStateTimer`, `g_bEnableLogEmpireStats` | `0x30fcf04`, `0x30fcf03` | `-gamestatetimer`, `-logempirestats` |
| `g_pLoadTimer` | `0x30fcee8` | `-loadtimes` |
| `g_bIsEditorMode` | `0x30fcf01` | `-editor` |
| `g_CheatManager` (`CCheatManager`, 160 bytes) | `0x2800680` | `g_ForceHumanAI` +0x79, `g_ForceBerserkAI` +0x7a, `g_ForceFullGalaxySpawn` +0x7b, `g_EnableDailyUpdatePopJobs` +0x9e |
| console variable values from the command line | `0x3134cd0` | `ApplicationUtilsCommandLineArgs` |

`CCheatManager::ResetAllCheats` (`0x1ad7b0`) runs from the `g_CheatManager` initializer and from
every `CGameState` constructor and destructor. It clears the cheats (0x20-0x30, 0x50, 0x51,
0x70-0x77, 0x7c-0x91, 0x98-0x9c), sets `g_AI` (+0x72) and `g_EnableTerraIncognita` (+0x8a),
`g_ForcedPopHappiness` (+0x94) to -1, and copies `g_ForceHumanAI`, `g_ForceBerserkAI`,
`g_ForceFullGalaxySpawn` to `g_HumanAI` (+0x73), `g_BerserkAI` (+0x74), `g_FullGalaxySpawn`
(+0x78). It leaves the force flags, +0x9d and `g_EnableDailyUpdatePopJobs` alone.
