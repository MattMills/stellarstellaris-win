# Stellaris command line options (4.5.2)
## Unofficial documentation

Reverse engineered from the GOG 4.5.2 build of `stellaris.exe` and its PDB (names, class layouts).
Addresses are GOG RVAs. Everything below is what the code does; several options are developer tools
that Paradox does not support, and a few are parsed but do nothing in 4.5.2.

## How the game reads its command line

`SDL_main` (`0x14ccc0`) gives `argc`/`argv` to three readers, in this order.

1. `CPdxCommandLine::Init` (`0x1b25650`) builds the engine's option table. Code asks it later with
   `CPdxCommandLine::HasOption` (`0x1b25c30`), `GetOptionArgument` (`0x1b25cb0`) or the same lookup
   inlined.
   - Every argument must start with `-`. Others are skipped and logged:
     `Skipped command line option due to missing '-' (use '-%s' instead)`.
   - One `-` is removed: `-logall` is the key `logall`, `--continuelastsave` the key
     `-continuelastsave`.
   - `-key=value` splits at the first `=`. `-key value` works too: the next argument is the value
     when it does not start with `-`.
2. `ApplicationUtilsCommandLineArgs` (`0x1b0a0a0`) sets console variables
   ([below](#console-variables)).
3. `RunGame` (`0x14fa40`). An argument that is exactly `-editor` or `--editor` runs the editor
   (`editor_main`) instead of the game. Otherwise `RunGame` joins `argv[1..]` with spaces, cuts the
   text at every `-`, trims each piece and offers it to `ParseClausewitzCommandLineOption`
   (`0x1a3a2d0`, the engine's options), then to its own list.
   - `-x` and `--x` are the same option. `xxx=` options match by prefix, the others exactly.
   - A value cannot contain `-`: it ends the piece. `-userdir=D:\my-games` gives `D:\my`. Spaces are
     kept when the argument is quoted.
   - Unknown pieces are ignored silently. Order does not matter; a repeated option overwrites (single
     values) or appends (lists).

A few functions also search the joined text itself (`+connect`, `-mod `, the auto client).

Names are case-sensitive everywhere except for console variables. The column after each option says
who reads it: **C** `ParseClausewitzCommandLineOption`, **G** `RunGame`, **P** `CPdxCommandLine`,
**T** a search of the joined text.

## Directories, settings, language, DLC and mods

| Option | | Effect |
|---|---|---|
| `-userdir=<path>` | G | The user directory (saves, settings, logs, mods), mounted first and used as the write directory by `StartVFS`. Default: the custom user dir (`VFSGetCustomUserDir`), else `Documents/Paradox Interactive/Stellaris`. Its path cannot contain `-` (see above). |
| `-settings=<file>` | G | `LoadSettings` reads this file instead of `settings.txt` (a path in the user directory). When it does not exist the game treats the start as a first start (`g_bFirstTimeStartup`). |
| `-message_settings=<file>` | G | Instead of `message_settings.txt` (`LoadMessageSettings`). |
| `-alert_settings=<file>` | G | Instead of `alert_settings.txt` (`LoadAlertSettings`). |
| `-language=<key>` | G | The language for this run instead of the one in the settings, e.g. `-language=l_german`. A key not in `localisation/languages.yml` falls back to the first language. |
| `-exclude_dlc=<entry>` | G | Repeatable. Added to the disabled DLC list (`CDLCManager::_DisabledDLC`), which `disabled_dlcs` in `dlc_load.json` fills. `CDLCManager::IsEnabled` looks a DLC up there by its descriptor's `_FileName`, so the value has the form of a `disabled_dlcs` entry. |
| `-dlcmod` | G | Writes `CDLCManager::CreateDLCModInfoString` (the enabled DLC and mods) to the console the game was started from (`AttachConsole`, `GetStdHandle`) and quits. |
| `-mod=<path>` | G | Repeatable; collected, then replaced by the enabled mods of `dlc_load.json` before the second `StartVFS`. No effect in 4.5.2. `GetModFromCommandLine` also searches for `-mod ` and the result is dropped. |
| `-threads=<n>` | G | Worker threads for the task system (`InitTaskSystem`), clamped to 4 .. max(4, logical processors). Default (-1): max(4, logical processors) - 1. Logged as "Spawning %d worker threads". |
| `-gamepad` | G | Leaves game controllers on. Without it `RunGame` calls `CApplication::SetGameControllersEnabled(false)`. |

## Starting and loading games

| Option | | Effect |
|---|---|---|
| `-quick` | G | Starts a new game at once from the main menu (`CFrontEndIdler::UpdateInternal`): one human player with the last used name and a random empire, the galaxy settings the front end holds. The start screen is skipped, and messages are not held back for it. |
| `-quick=<save>` | G | Loads a save instead. `"` are removed. The saves under `save games` (newest first, cloud saves included) are searched for the first whose `save games/<folder>/<name>.sav` contains the value; `latest`, or no match, takes the newest. No saves: nothing happens. A save from an older major version shows the resume warning and stops; other DLC or a bad version stop silently. A value that is the exact path of an existing file skips the search, and the load then fails (from the code, not tested). |
| `-quickrestart=<n>` | G | Quick start, then about 5 seconds into the game the player resigns and the game starts again: n restarts, n+1 games, the last one keeps running (`CInGameIdler::UpdateInternal`, `DoResign`). |
| `--continuelastsave` | P | Two dashes. Once per run, reads `continue_game.json` (the last save, rewritten with every save) and loads it like `-quick=<that save>`. |
| `-empire=<key>`, `-empire <key>` | P | Starts a new game with the empire design whose key is `<key>` (prescripted designs first, then the user's), if it is playable. Checked at the main menu before the quick start. |
| `-igc=<command>` | G | Repeatable. A console command, run each time a game starts or is loaded (`CInGameIdler::RestoreDeviceObjects`: `IGC Command: <command>` in the console, `CConsole::RunCommandNow`). The list is never cleared. The command cannot contain `-`, so no negative numbers. |
| `-one_year` | G | Queues the `one_year` console command: the game runs one year at speed 4, logs `Performance run took <x>s` to game.log, pauses and shows "Run Finished". |
| `-overnight` | G | Quick start, and the console commands `overnight` and `game_paused false`: observer mode, `ticks_per_turn 300`, frame smoothing off, the camera follows combat, incremental saves on (ironman too), and the game quits in 2600 (`g_bOvernight`). Refused in multiplayer. |
| `-incrementalsaves`, `-incrementalsaves=<n>` | G | Saves non-ironman games on 1 January every n years (without n: the define `NGameplay.INCREMENTAL_SAVE_FREQUENCY`), as `<game name>_<yyyy.mm.dd>` in the game's save folder (`CGameState::HandleTurnTick`). |
| `-random=<n>` | G | n ≥ 0: the seed of the random generator when the main menu opens (`CFrontEndIdler::SetAsCurrentIdler`), instead of the clock, and the seed the game setup sends (`CGameSetup::StartSyncPlayers`). It fixes the seed, not the position, so it gives the same galaxy only when everything else is the same too: see [Random numbers](#random-numbers). Default -1. |
| `-rng_seed=<n>`, `-rng_pos=<n>` | G | Only when a game state is loaded (`CGameState::InitPostRead`): the random generator's seed and position (its place in the sequence of numbers, not a place on the map). Either option sets both; the one not given is 0. No effect on a new game. See [Random numbers](#random-numbers). |
| `-loadrandomseed` | G | `g_bUseSavedRandom` (also the console variable `UseSavedRandom`): loading a save restores the random generator from the save's `random_seed` and `random_count`. Otherwise a load keeps the current generator (the main menu's, or the running game's). `CCountryAI::ReadMember` also reads each AI's own generator from the save with this option, but in a headless run the AI behaved as if its generator restarted at the country id anyway, as on a normal load (see [random.md](random.md); not confirmed). |
| `-combat_debug` | G | Combat test mode (`g_bCombatOnlyMode`): `CGameApplication::InitGame` loads `combat_test_scenarios.txt` and starts a `CCombatDebugIdler` instead of the main menu. Monthly updates, most of the daily update and the AI interior minister are off, and `CFleet::CanAddShip` skips its checks. |

## Joining a multiplayer game

`GetMatchmakingFromCommandLine` (`0x14d190`) cuts the joined command line at spaces. Each keyword
must be a whole argument, and its value is the next argument (no `-`, so `CPdxCommandLine` logs
them as skipped, which does no harm). A valid target ends up in
`CGameApplication::_MatchmakingConnectNetAddress` (+0x478) and the password in
`_MatchmakingConnectPassword` (+0x4d0). `CFrontEndGui::Update` then opens the multiplayer menu,
and `CMultiplayerMenuView::Show` joins the game once (`DoJoinDirect`, the password is MD5 hashed).

| Option | | Effect |
|---|---|---|
| `+connect_lobby <id>` | T | Joins the lobby with that 64-bit id (`SNetAddress::_nID`). |
| `+connect_pdxmp <id>` | T | Paradox multiplayer, parsed by `NetAddressFromString`: `<uuid>.nakama` (or `...nakama-<digit>`) is a Nakama match id; `R:<n>` a Rail id; any other text a 64-bit id. Text with a `.` is taken as a host without a port, which is not valid, so nothing happens. |
| `+password <password>` | T | Password for the game joined above (no spaces). |
| `+connect <host>:<port>` | T | Fills the address's IP and port, but `SNetAddress::IsValid` accepts only Nakama match ids and 64-bit ids, so this joins nothing in 4.5.2. |

The `matchmaking_connect` console command (`OnExecute_MatchmakingConnect`, via
`NetAddressFromCommandLine`) reads `+connect`, `+connect_lobby` and `+password` the same way, but not
`+connect_pdxmp`, although its usage text shows it.

| Option | | Effect |
|---|---|---|
| `-name=<name>` | G | `g_PlayerName`: the player name in the multiplayer menu (ahead of the last name used, then the platform user name). |
| `-wait_for_clients=<n>` | G | On the host, the game does not advance until it has at least n human players (`CInGameIdler::CheckTick`). Default 0. |
| `-nopdxmp` | P | The multiplayer menu no longer requires the Paradox account login (see [below](#crash-reporter-launcher-and-online-services)). |
| `-connect=<host>` | C | Stored in `g_ClausewitzOptions._ConnectToHost`, which nothing reads. No effect. |

### The auto client (no effect)

`GetAutoClientDataFromCommandLine` (`0x14d5f0`) cuts the joined text at `-` like `RunGame` and reads
`-client` and `-ip=`, `-server=`, `-password=`, `-country=`, `-name=` (an empty value is ignored).
`CApplication::SetAutoClientData` stores them (`_bIsAutoClient` +0xd8, `_AutoClientIPAdress`,
`_AutoClientServerName`, `_AutoClientPassword`, `_AutoClientCountryTag`, `_AutoClientNick`), and
nothing in 4.5.2 reads them back. `-name=` is the same piece `RunGame` reads, so it still sets the
multiplayer name above.

## The editor

`-editor` or `--editor` (exact argument) sets `g_bIsEditorMode` and runs `editor_main`
(`0x1bbe8f0`) instead of the game: the Clausewitz asset and map previewer (`pdx_editor`, "PdxEditor",
SDK name "pdx_previewer"). It opens a `CMapApplication` with a local "Editor" session, loads files
dropped on the window, uses `l_english`, and mounts `previewer_assets` / `previewer_assets.zip` from
the game directory if present. Its own options (the joined text cut at `-`, like `RunGame`):

| Option | Effect |
|---|---|
| `-settings=<file>` | `CEditorSettings` loads, then saves, this file (default `settings.txt`). |
| `-userdir=<path>` | The user directory (default: the custom user dir, else the default one for "PdxEditor"). |
| `-mount=<path>` | Mounted as an extra root (quotes removed) and used as the write directory. |
| `-mesh <path>`, `-anim <path>`, `-particle <path>`, `-pdxmesh <path>`, `-entity <path>` | Loaded at startup (`LoadMeshesAndAnimations`, `LoadParticles`, `LoadPdxMeshes`, `LoadEntities`). Prefix match without `=`; repeatable. |
| `-filterfile=<file>` | Lines of the file go to `CApplication::_Filter`; no reader found. |
| `-ip=<addr>`, `-user=<name>`, `-host` | Read, no effect (`ChatIP`, `ChatUser` are never used). |
| `-logprefix`, `-logpostfix` | As in the game: `logs/<prefix>error<postfix>.log`, `system`, `random`. |

The engine options (**C**) are parsed too; those that set globals (renderer, OOS flags,
`-debug_mode`, ...) apply, those stored in the options struct (`-connect=`, the localisation tools)
are discarded.

## Logs and profiling

| Option | | Effect |
|---|---|---|
| `-logprefix=<text>` | P | Put before the name of every log file: `logs/<prefix><name><postfix>.log` in the user directory (`InitializeLogging`), for game, ai, setup, error, system, memory, time, profiler, info, event_data, debug, script_profiling, script_profiling_summary, and `logs/script_documentation/<prefix>triggers<postfix>.log` and the other script documentation files. Also used by the timer dump, the OOS dump and the editor. The crash reporter still attaches `logs/error.log` and `logs/system.log`. |
| `-logpostfix=<text>` | P | Put after the name, before `.log`. |
| `-logall` | P | Writes repeated messages. A file logger normally writes each message (source file, line, text) once per file; with `-logall` the duplicate filter is off (`CFileLogger` flags 15 → 7) for game, ai, setup, error, system, memory, debug and the script documentation, and profiler (9 → 1). It does not enable other loggers or levels. |
| `-suppresserrorlog` | G | Skips the error count check after a game starts or loads (`OpenErrorLogIfNewErrors`), which in 4.5.2 only formats a message that is never shown. No effect. |
| `-console` | G | Writes every console command with its help text to `logs/info.log` once at startup (`CConsoleCmdManager::DumpConsoleCommands`). |
| `-timer` | G | `CTiming::EnableTiming`: every game year and on quit, `logs/<prefix>timer_dump_<galaxy name><postfix>.txt`, a version and system header and one row per tick with the date and the time of about 43 scopes. |
| `-loadtimes` | G | Logs `Loading time: %f` (from startup to the first game) once. Its log category (0x2000) has no file, so the line probably goes nowhere. |
| `-gamestatetimer` | G | `logs/gametimer_<YYYYMMDD_HHMMSS>.tsv` (`CGameStateTimer`): the wall time of every tick, day, week, month and year. Also sets `-suppresserrorlog`. |
| `-logempirestats` | G | `logs/empire_stats_<YYYYMMDD_HHMMSS>_<galaxy template>_<difficulty>.tsv` (`CLogEmpireStats`): for each tracked empire, its AI plan and economy, military and tech, probably monthly. |
| `-elasticsearch=<url>`, `-elasticsearch-auth=<key>` | P | Both needed. `NElasticLogging::TryCreateLogger` (from `CGameApplication::InitGame`) then sends the yearly tick performance stats (`CGameState::FlushPerformanceStats`: daily, monthly and micro update times, with version, checksums and game date) as NDJSON to `<url>/_bulk` with `Authorization: ApiKey <key>`, index `<app name>-<type>-<YYYY-MM>`. |
| `-elasticsearch-api=<7\|8>` | P | Bulk format: `7` adds `_type`; empty or `8` is the ES8 format; other values log "Not supported elastic search version" and use 8. |

## Crash reporter, launcher and online services

| Option | | Effect |
|---|---|---|
| `-nopopup` | P | `SPdxCrashReportSettings::_bLaunchCrashReporter` off: after a crash the game still writes the minidump and crash files, but does not start CrashReporter.exe (the dialog and upload). |
| `-crash_reporter_dir=<dir>` | P | Where `CrashReporter.exe` is looked for: `<dir>/binaries/CrashReporter.exe` instead of `<game dir>/crash_reporter/binaries/`. |
| `--pdx-launcher-session-token=<token>` | P | Given by the Paradox launcher; passed to the PDX SDK (`Config::SetSessionToken`). |
| `-gdpr-compliant` | P | The PDX SDK skips the legal documents flow (`SetSkipLegalDocumentsFlow(true)`), and the game marks every unviewed legal document as viewed, so no prompt. |
| `-automated_test` | P | Skips the third-party account linking prompt ("Automated test, skipping third party account linking prompt"); the answer is set to 2, not the accepted value 1. |
| `-nopdxmp` | P | `IsMultiplayerEnabled` returns true without checking the Paradox account, so the multiplayer menu no longer requires the Paradox login dialog. |
| `-nakama_key=<k> -nakama_host=<h> -nakama_port=<n> -nakama_ssl=<0\|1>` | P | The Nakama (Paradox online) server. All four or nothing: if any is missing, the built-in key, `stellaris.online.paradox-interactive.com`, port 443 and SSL are used. A bare `-nakama_ssl` means SSL off. Logged as `[PDX NAKAMA] Using host from command line`. |
| `-additional_content_url=<url>` | P | Where the in-game store's metadata JSON is fetched (default: a Paradox S3 feed). |
| `-additional_content_fake_data_files` | P | The store reads `additional_content/metadata.json` and `additional_content/assets/<file>` from the game files instead of downloading. |
| `-additional_content_read_test_values` | P | The store uses the `test_base_price`, `test_price`, `test_is_on_sale` values of the product JSON (shown as `<value> WWW`) instead of asking the platform store. |
| `-hud_tutorial_sanity_check` | P | `CGuiHighlighter` checks, once, that every tutorial highlight (`EGuiHighlight`) has a GUI element, and logs `Highlighter is missing a Highlight, EGuiHighlight N` to error.log for those that do not. |

`CPdxCrashReporter::WriteCrashMetaData` writes the whole command line into the crash metadata
(`LaunchArguments:`).

## Debugging and cheats

| Option | | Effect |
|---|---|---|
| `-debug_mode` | C | Sets `g_DebugMode`, which `CApplication::CApplication` copies to `CApplication::_bIsInDebugMode`: the game starts in debug mode, the flag the console's `ToggleDebugMode` switches ("Turning debug ON/OFF"). |
| `-debugtooltip` | G | `g_bDebugToolTip`: the debug information in tooltips (read by about a hundred `GetToolTip` functions; `OnExecute_DebugTooltip` toggles it in the console). |
| `-humanai`, `-human_ai` | G | `CCheatManager::g_ForceHumanAI`. `CCheatManager::ResetAllCheats`, which runs for every new game state, copies it to `g_HumanAI`: the AI plays the human players' empires. |
| `-berserkai`, `-berserk_ai` | G | `g_ForceBerserkAI`, copied to `g_BerserkAI` the same way (read by `CAIForeignMinister::PrepareWar`). |
| `-fullgalaxyspawn` | G | `g_ForceFullGalaxySpawn`, copied to `g_FullGalaxySpawn`, which `InitializeUninitializedSystems` reads. |
| `-daily_jobs_update` | G | `CCheatManager::g_EnableDailyUpdatePopJobs`: `NColonyUpdate` updates pop jobs every day instead of monthly. A console command toggles it too (`OnExecute_ToggleDailyPopJobsUpdates`). |
| `-audiodebug` | C | `g_bRenderSoundDebug` (the `Audio.Debug` console variable): draws the sound debug overlay (`PdxDebugUtil::RenderSoundDebug`). |
| `-bajen` | G | The advisor voice is always the audio group `l_bajen` (`NAdvisorVoice::SetForCountry`). |

## Graphics

| Option | | Effect |
|---|---|---|
| `-dx11` | C | Forces the Direct3D 11 renderer. `GfxSetRenderType(1)` and `g_RenderTypeIsForced`. |
| `-dx9` | C | Forces the Direct3D 9 renderer (`GfxSetRenderType(0)`). |
| `-opengl` | C | Forces the OpenGL renderer (`GfxSetRenderType(2)`). |
| `-opengl4` | C | Forces the OpenGL 4 renderer (`GfxSetRenderType(3)`). |
| `-dx9legacy` | C | `g_bLegacyDevice`: read only by `GfxInitInternalDX9`, so it matters only with the DX9 renderer. |
| `-noamdworkaround` | C | Clears `g_bAMDWorkaround` (on by default). Read only by `GfxInitInternalDX9`. |
| `-nohdr` | G | Clears `g_bHDREnabled` (read by the post effects and the 3D render targets; a console command, `OnExecute_HDR`, toggles it) and the sRGB flag below. |
| `-nosRGB` | G | Clears the flag (GOG `0x27fff79`, on by default) that the colour code reads to work in linear space and load textures as sRGB (`GfxToLinear`, `CTextureHandler::AddTexture_sRGB`, ...). |
| `-debug_shaders`, `-shader_debug` | G | Adds `D3DCOMPILE_DEBUG` (1) to the shader compile flags (GOG `0x321a900`), which `GfxAddVertexShaderDX9/DX11` and `GfxAddPixelShaderDX9/DX11` pass to the compiler. |
| `-shader_skip_optimization` | G | Adds `D3DCOMPILE_SKIP_OPTIMIZATION` (4). |
| `-shader_prefer_flow_control` | G | Adds `D3DCOMPILE_PREFER_FLOW_CONTROL` (0x400). |
| `-shader_warnings_are_errors` | G | Adds `D3DCOMPILE_WARNINGS_ARE_ERRORS` (0x40000). |

Without a forced renderer, `CGraphics::InitGfx` sets DX11 and, when the DX11 device cannot be created,
logs `Failed creating d3d11 device! trying with d3d9.` and tries DX9. A forced renderer gets no
fallback, and `CGraphicsSettings::Init` does not replace it with the one from the settings. All four
backends are in the Windows executable (`GfxInitInternalDX9`, `...DX11`, `...OpenGL`, `...OpenGL4`).

## Out of sync (OOS) debugging

These fill `COosChecks::_Initial`, a `COOSCheckSettings` (GOG `0x28888e0`: `_nRandomLogStackDepth` at
+0x8, `_nRandomLogExtraFrames` at +0xc, the `EOosFlags` mask at +0x10). `COosChecks::SetCurrent`
copies it to `COosChecks::_Current` when a game starts (`CStartGame::Execute`,
`CStartGameFromInGameLobby::Execute`) and when a game state is destroyed. The host sends its settings
to the session (`CGameSetup::Update`, `CIngameLobby::Start`), so in multiplayer the host's options
apply.

| Option | | Effect |
|---|---|---|
| `-hardoos` | C | `EOosFlags::HardCheck` (1): `NOosChecksums::CalcChecksums` checks more. |
| `-clientsaves` | C | `ClientSaves` (2): clients also write the autosaves (`CAutosave::Execute`, `CInGameIdler::AutoSave`). |
| `-localoos` | C | `LocalCheck` (4). No reader of this bit found in 4.5.2. |
| `-randomlog` | C | `RandomLog` (8): turns on the random log (`CRandom::_RandomLogEnabled`): the game's random draws (`CRandom::GetIntegerForMacro`, ...) are recorded with `CRandomLog::Log`, for comparing clients after an OOS. |
| `-hotjoinlog` | C | `HotjoinLog` (16): also turns on the random log. |
| `-randomcache` | C | `RandomCache` (32): `CRandom::_RandomCacheEnabled`: random draws also go to an in-memory cache (`CRandomLogCache`), advanced with the game date and written into the OOS dump (`CRandom::DumpCachedRandomLogs`, `_BuildOOSDump`). |
| `-deepsyncscan` | C | `DeepSyncScan` (64): `CalcChecksums` / `MakeSyncCheck` compute the detailed checksums. |
| `-randomlog_stack=<n>` | C | `_nRandomLogStackDepth` (by its name, the call stack depth kept with each entry). In 4.5.2 the value is only copied and sent with the game settings; no other reader found. |
| `-randomlog_frames=<n>` | C | `_nRandomLogExtraFrames`: how much random log history is kept. `CGameState::HandleRandomLogTurnTick` drops entries older than (n+1)×10 ticks ((n+1) days) behind the current tick, or behind the oldest tick another player has reached. Default 0. |

## Random numbers

Every synchronized random outcome comes from one generator: galaxy generation, events, combat,
the `random` blocks of scripts. That generator is `CRandom::_Random` (GOG `0x310cb68`), a
`CNoiseRandom` of two numbers, a seed and a position. A draw hashes (position, seed) and adds one to
the position, so the n-th number after a given seed is always the same. The AI has generators of its
own and draws nothing from this one. [random.md](random.md) has the algorithm, the AI's generators,
and where the draws go (measured in the headless game). [newgame.md](newgame.md) section 2 has the
galaxy's seeding.

| When | Seed | Position |
|---|---|---|
| The main menu opens (`CFrontEndIdler::SetAsCurrentIdler`; also after leaving a game) | `-random=<n>` if n ≥ 0, else the clock (`QueryPerformanceCounter`) | 0 |
| Every draw (menus, generation, the game) | | +1 |
| The game setup moves on (`CGameSetup::StartSyncPlayers`, single player and multiplayer) | `CSetRandomSeed` sends the same seed (`-random=<n>` if set) to every player | the current one |
| A player joins a running game (`CPostHotJoinCommand`) | the host's | the host's |
| A save is loaded (`CFrontEndIdler::LaunchSave`, `CInGameIdler::LoadSave`) | unchanged (the main menu's, or the running game's for a load from inside a game); with `-loadrandomseed` the save's `random_seed` | unchanged; with `-loadrandomseed` the save's `random_count` |
| Right after a game state is read (`CGameState::InitPostRead`), with `-rng_seed` or `-rng_pos` | `-rng_seed=<n>`, else 0 | `-rng_pos=<n>`, else 0 |

A new game (`CGameState::GenerateNewGalaxy`) draws one number and turns it into the galaxy seed.
From that seed and the settings, `CGalaxyGenerator` makes the star map (star positions, nebulas,
partitions, the empires' home systems) with a stream of its own. The hyperlanes, the systems'
contents, the species and empires, the names and every script effect draw from the global
generator, so they also depend on the draws that follow.

Numbers on the command line: values are read with `atoi` and cannot contain `-`. A seed that a save
shows as negative (`random_seed=-386941723`) cannot be given: `-rng_seed=-386941723` reads as an
empty value, which is 0, and the unsigned form 3908025573 overflows `atoi` to 2147483647. Use
`-loadrandomseed` to keep a save's own seed.

Checking that the options reach the game: on Steam the game starts through the Paradox launcher,
and whether it passes Steam's launch options on is not visible in `stellaris.exe`. Add
`-logprefix=test_` next to the other options. If the logs come out as `logs/test_game.log`,
`logs/test_error.log` and so on, the command line arrived.

### The same galaxy twice: `-random=<n>`

`-random=<n>` fixes the seed, not the position. The galaxy is the same only when everything that
feeds the generation is the same:

- **The position when the galaxy is generated**: the same draws in the menus since the main menu
  opened. The menus draw when an empire design is edited in the game setup
  (`CGameSetupView::EditEmpireDesign` draws once and re-rolls the flag), with the empire designer's
  randomize functions (name, flag, portrait, traits, ethics, ...), and when a store product with a
  ship preview is shown. Leaving a game back to the main menu starts again at position 0.
- **The setup**: the galaxy settings and game rules, the player's empire, and the empire designs
  the AI can pick.
- **The game files**: the version, the DLC, the mods.
- **The order of the draws**: generation allows draws from worker threads
  (`CRandom::_MultithreadAllowed`), whose order may vary from run to run (inferred, not measured).
  `-threads` cannot go below 4.

From the code (not tested): `-random=<n> -quick` twice, with the same settings, starts a new game
from the main menu with no menu input, which keeps the position the same.

### `-rng_seed=<n>` and `-rng_pos=<n>`

These are not only for events. They set the seed and position of the generator above, so every
random outcome after that point follows from them: events, combat, script randomness (not the AI,
which has its own generators). They apply only when a game state is read: a loaded save, or the game
state a multiplayer client receives. They do nothing to a new game.

Use them to replay from a save. Load the same save with the same `-rng_seed=<s> -rng_pos=<p>`, make
the same choices, and the random outcomes repeat. The headless game did this from an autosave with
`-rng_seed=64429129 -rng_pos=0` and reproduced the player's next autosave, except for his event
choices ([random.md](random.md)). `-loadrandomseed` does the same from the numbers stored in the
save, so you do not need to know them.

`-rng_pos=<n>` is a position in the sequence of random numbers (how many have been drawn since the
seed was set), not a place in the galaxy. No option puts an empire at a chosen spot (say, "2
o'clock"). The home systems are part of the star map that the galaxy seed makes. Only a static galaxy
scenario (`map/setup_scenarios`, used by mods) fixes where things are.

## Localisation tools

`ExecuteLocalizationOptions`, called from `InitLocalisation` when the game loads its localisation.
Any of these makes `PdxLocalizeSetup` read the localisation of every language. Except for
`-printall_loc` and `-tag_loc`, the game runs the tool and exits.

| Option | | Effect |
|---|---|---|
| `-update_loc=<file>` | C | `UpdateTagFile(<file>)` (`localization_tag_file`), then exits. |
| `-export_loc` | C | `ExportUnlocalizedStrings` for l_french, l_german, l_spanish, l_russian, l_polish, then exits. |
| `-import_loc`, `-import_loc=<file>` | C | `ImportNewCSVLocalization` (`localisation_translated` `.csv` files) for l_english, l_french, l_german, l_spanish, then exits. The `=` form also stores the file name (`_LocalizationImportLocalized`). |
| `-purge_loc` | C | `PurgeLocalization` for l_french, l_german, l_spanish, then exits. |
| `-printall_loc` | C | `PdxLocalizePrintAllUsedCharacters` writes `usedcharacters.txt`; the game continues. |
| `-tag_loc` | C | Sets `_bLocalizationTagLocalized`; nothing else reads it, so the only effect is loading every language. |

## Read but without effect in 4.5.2

| Option | | |
|---|---|---|
| `-antiloop` | C | Taken, nothing done. |
| `-readlimit=<x>`, `-writelimit=<x>` | C | `atof` of the value, the result discarded. |
| `-script_debug`, `-profile_start` | G | Taken, nothing done. |
| `-localoos` | C | Sets `EOosFlags::LocalCheck`; no reader. |
| `-connect=<host>` | C | Stored, never read. |
| `-mod=<path>` | G | Replaced by the mods of `dlc_load.json`. |
| `-client`, `-ip=`, `-server=`, `-password=`, `-country=` | T | The auto client, never read back. |
| `+connect <host>:<port>` | T | Not a valid join target. |
| `-suppresserrorlog` | G | Skips a check whose result is not shown. |

## Console variables

`ApplicationUtilsCommandLineArgs` sets console variables (the tweakables of the console and the
debug GUI): `-<name>=<value>`, or `-<name>` alone for `true`. Names are not case-sensitive. The text
is cut at `-` like `RunGame`'s, so a value cannot be negative. Booleans are false for `0`, `false`,
`no` (any case) and true otherwise; integers use `atoi`, floats `atof`; the range is not checked.

The 144 variables registered at startup (`dynamic initializer for 'CONSOLEVAR_n'`) follow. Others
are registered later (the particle editor's GUI) and get their command line value then
(`AddTweakable`). The cheats in `CCheatManager` are reset when a game starts or loads
(`CCheatManager::ResetAllCheats`, from the `CGameState` constructor), so set from the command line
they only last until then; the force flags of `-humanai`, `-berserkai`, `-fullgalaxyspawn` are made
for that. The default is the value at startup; the range is what the console variable declares.

| Name | Type | Default | Range | Variable |
|---|---|---|---|---|
| `UseSavedRandom` | bool | false |  | `g_bUseSavedRandom` |
| `Enable.FrameSmoothing` | bool | true |  | `g_bFrameSmoothing` |
| `SimulatedLag.Enable` | bool | false |  |  |
| `SimulatedLag.Min` | float | 0 | 0 .. 10 |  |
| `SimulatedLag.Max` | float | 1 | 0 .. 10 |  |
| `Enable.AI` | bool | true |  |  |
| `ai_get_messages` | bool | false |  | `CCheatManager::g_AiGetsMesssages`, reset when a game starts or loads |
| `MaxFPS` | float | 0 | -1000000 .. 1000000 |  |
| `distort_date` | bool | false |  | `CGameDate::DistortDate` |
| `Date.Distoration_Skip` | int | 25 | -1000000 .. 1000000 | `SkipChance` |
| `Date.Distoration_?` | int | 5 | -1000000 .. 1000000 | `QuestionMarkChance` |
| `ignore_truce` | bool | false |  | `CCheatManager::g_IgnoreTruce`, reset when a game starts or loads |
| `open_diplo` | bool | false |  | `CCheatManager::g_OpenDiploActions`, reset when a game starts or loads |
| `pop_happiness` | int | -1 | -1 .. 100 | `CCheatManager::g_ForcedPopHappiness`, reset when a game starts or loads |
| `PopFactionLogs` | bool | false |  |  |
| `no_resources` | bool | false |  | `CCheatManager::g_NoResources`, reset when a game starts or loads |
| `instant_research` | bool | false |  | `CCheatManager::g_InstantResearch`, reset when a game starts or loads |
| `Draw.CombatDebugLines` | bool | false |  | `g_bDrawCombatDebugLines` |
| `Draw.Objects` | bool | true |  | `g_bDrawObjects` |
| `Draw.PathToSystem` | int | -1 | -1000000 .. 1000000 | `g_bDrawMovementDebugSystem` |
| `endscreen` | bool | false |  | `bOpenEndScreen` |
| `Draw.GreenScreen` | bool | false |  | `bDrawGreenScreen` |
| `Entity.Names` | bool | false |  | `g_bRenderEntityNames` |
| `Draw.Neighbors` | bool | false |  | `g_bGalacticObjectNeighbors` |
| `Entity.RecursiveBoundingVolumes` | bool | false |  | `g_bEntityBoundingVolumes` |
| `Draw.Regions` | bool | false |  |  |
| `Draw.Precursors` | bool | false |  |  |
| `Draw.StartClusters` | bool | false |  |  |
| `Draw.AllClusters` | bool | false |  |  |
| `Draw.SystemInit` | bool | false |  |  |
| `Draw.TIGrid` | bool | false |  |  |
| `Draw.CosmicStormGrid` | bool | false |  |  |
| `Draw.DeflectionVector` | bool | false |  |  |
| `Entity.Tooltip` | bool | false |  |  |
| `Alerts.ShowAll` | bool | false |  |  |
| `PathFindCache` | bool | true |  | `g_bUsePathFindCache` |
| `ai_test` | bool | false |  | `CCheatManager::g_AITest`, reset when a game starts or loads |
| `ai_caches` | bool | false |  | `CCheatManager::g_AICheckCaches`, reset when a game starts or loads |
| `instant_reinforce` | bool | false |  | `CCheatManager::g_InstantReinforcement`, reset when a game starts or loads |
| `Combat.Collision` | bool | true |  |  |
| `Combat.AllowCollisionStrafe` | bool | true |  |  |
| `instant_survey` | bool | false |  | `CCheatManager::g_InstantSurvey`, reset when a game starts or loads |
| `instant_anomaly_research` | bool | false |  | `CCheatManager::g_InstantAnomalyResearch`, reset when a game starts or loads |
| `PlanetDestruction.SkipWindupPhase` | bool | false |  | `CCheatManager::g_SkipPlanetDestructionWindupPhase`, reset when a game starts or loads |
| `PlanetDestruction.SkipFirePhase` | bool | false |  | `CCheatManager::g_SkipPlanetDestructionFirePhase`, reset when a game starts or loads |
| `PlanetDestruction.SkipRules` | bool | false |  | `CCheatManager::g_SkipPlanetDestructionRules`, reset when a game starts or loads |
| `instant_colony` | bool | false |  | `CCheatManager::g_InstantColony`, reset when a game starts or loads |
| `instant_move` | bool | false |  | `CCheatManager::g_InstantMovement`, reset when a game starts or loads |
| `FleetPathFindCache` | bool | true |  | `g_bUseFleetPathFindCache` |
| `Draw.LightDebug` | bool | false |  | `g_bDrawLightDebug` |
| `Enable.Asserts` | bool | true |  | `g_bAssertsEnabled` |
| `Music.Next` | bool | false |  | `g_bNextMusic` |
| `Music.Fade` | float | 3 | -1000000 .. 1000000 | `g_vMusicFadeTime` |
| `Gfx.ConstructionLoop` | float | 0 | -1000000 .. 1000000 |  |
| `Portraits` | bool | false |  |  |
| `Portraits.PopLevel` | int | 99 | -1000000 .. 1000000 |  |
| `Camera.SearchForCombat` | bool | false |  | `g_bCameraSearchForCombat` |
| `Hyperlanes.ColorPartitions` | bool | false |  |  |
| `Draw.Hyperlanes` | bool | true |  | `g_bGfxDrawHyperlane` |
| `Draw.Trails` | bool | true |  | `g_bDrawTrails` |
| `Ships.NLIPS` | bool | true |  | `g_bShipsNLIPS` |
| `Ships.Merge` | bool | true |  | `g_bShipsMerge` |
| `Draw.ShipIntersection` | bool | false |  | `bDrawShipIntersection` |
| `Gfx.DissolveOverride` | bool | false |  | `bDissolveOverride` |
| `Gfx.DissolveOverrideValue` | float | 0 | 0 .. 1 | `vDissolveOverrideValue` |
| `Shield.Spam` | bool | false |  |  |
| `Shield.Entity` | int | 0 | 0 .. 3 |  |
| `Draw.CatapultRange` | bool | true |  | `g_DrawCatapultRange` |
| `Draw.CatapultDestinations` | bool | true |  | `g_DrawCatapultDestinations` |
| `BombardEffectTest` | int | 0 | 0 .. 3 |  |
| `Draw.Background` | bool | true |  | `g_bGfxDrawGalaxyBg` |
| `Draw.Names` | bool | true |  | `bDrawNames` |
| `Draw.SystemLines` | bool | true |  | `bDrawSystemLines` |
| `Portrait.OverrideZoom` | bool | false |  |  |
| `Portrait.Zoom` | float | 1 | 1 .. 3 |  |
| `Portrait.XPos` | float | 0 | -1000000 .. 1000000 |  |
| `Portrait.YPos` | float | 0 | -1000000 .. 1000000 |  |
| `Draw.StrikeCraftTrails` | bool | true |  |  |
| `Draw.Borders` | bool | true |  | `g_bGfxDrawBorders` |
| `Borders.UpdateWheneverPossible` | bool | false |  | `g_bBorderAlwaysUpdate` |
| `Borders.SaveDebugImages` | bool | false |  |  |
| `Borders.BlurDistanceFields` | bool | true |  |  |
| `Borders.BlurIterations` | int | 1 | 1 .. 10 |  |
| `Borders.SdfMaxDistance` | float | 15 | -1000000 .. 1000000 |  |
| `Borders.DownSample` | int | 4 | 1 .. 16 |  |
| `Draw.CosmicStorms` | bool | true |  | `g_bGfxDrawGalaxyCosmicStorm` |
| `Draw.PsionicAuras` | bool | true |  | `g_bGfxDrawGalaxyPsionicAura` |
| `Borders.TextureCalcDebugLines` | bool | false |  |  |
| `Borders.SourceGridDebugLines` | bool | false |  |  |
| `Shield.ConstantSize` | bool | true |  |  |
| `Draw.PsionicAuraHyperlanes` | bool | true |  | `g_bGfxDrawPsionicAuraHyperlane` |
| `Draw.WaystationNetworkHyperlanes` | bool | true |  | `g_bGfxDrawWaystationNetworkHyperlane` |
| `Draw.WeaponLocators` | bool | false |  | `bDrawWeaponLocators` |
| `Draw.Projectiles` | bool | true |  |  |
| `GalaxyDownsample` | int | 0 | -1000000 .. 1000000 | `g_nGfxGalaxyDownsample` |
| `Draw.Stars` | bool | true |  | `g_bGfxDrawStars` |
| `Draw.Dust` | bool | true |  | `g_bGfxDrawGalaxyDust` |
| `Draw.Nebula` | bool | true |  | `g_bGfxDrawGalaxyNebula` |
| `Draw.Center` | bool | true |  | `g_bGfxDrawGalaxyCenter` |
| `Draw.Asteroids` | bool | true |  | `g_bGfxDrawAsteroids` |
| `Draw.NavigationArrows` | bool | true |  | `bDrawNavigationArrows` |
| `MissileGfx.SlowDownRadius` | float | 10 | -1000000 .. 1000000 |  |
| `Draw.WPOWFX` | bool | true |  | `g_GfxDrawWpoVfx` |
| `Draw.Sensor` | bool | true |  | `bDrawSensorRange` |
| `TerraIncognita` | bool | true |  | `CCheatManager::g_EnableTerraIncognita`, reset when a game starts or loads |
| `IconCullGrid.Divisions` | int | 40 | -1000000 .. 1000000 | `g_nIconCullGridDivisions` |
| `Economics.Threaded` | bool | true |  |  |
| `debug_break` | bool | false |  | `CCheatManager::g_TriggerEffectDebugBreakEnabled`, reset when a game starts or loads |
| `Update.Particles` | bool | true |  | `g_bUpdateParticles` |
| `Update.Animations` | bool | true |  | `g_bUpdateAnimations` |
| `Mesh.Normals` | bool | false |  | `g_bShowNormals` |
| `Mesh.BoundingVolumes` | bool | false |  | `g_bShowBoundingVolumes` |
| `Mesh.Skeleton` | bool | false |  | `g_bShowSkeleton` |
| `Mesh.CollisionMeshes` | bool | false |  | `g_bShowCollisions` |
| `Mesh.Names` | bool | false |  | `g_bShowMeshNames` |
| `Mesh.TextureNames` | bool | false |  | `g_bShowMeshTextureNames` |
| `Mesh.JointNames` | bool | false |  | `g_bShowJointNames` |
| `Mesh.AnimationNames` | bool | false |  | `g_ShowAnimationNames` |
| `Particle.BoundingVolumes` | bool | false |  | `g_bShowParticleBoundingVolumes` |
| `Particle.Names` | bool | false |  | `g_bShowParticleNames` |
| `Draw.OpaqueObjects` | bool | true |  |  |
| `Draw.Arrows` | bool | true |  |  |
| `Draw.TransparentObjects` | bool | true |  |  |
| `Draw.Particles` | bool | true |  |  |
| `Mesh.Wireframe` | bool | false |  |  |
| `Mesh.MipLevels` | bool | false |  | `g_bMeshMipLevels` |
| `Particle.Wireframe` | bool | false |  |  |
| `Particle.UseRingbuffer` | bool | true |  |  |
| `Particle.Instancing` | bool | true |  |  |
| `Particle.MipLevels` | bool | false |  | `g_bParticleMipLevels` |
| `Audio.Debug` | bool | false |  | `g_bRenderSoundDebug` |
| `Audio.Debug.ExtendedRange` | bool | false |  | `g_bRenderSoundDebugExtendedRange` |
| `Audio.Compressor` | bool | true |  |  |
| `ApplicationUtils.Update` | bool | true |  |  |
| `console_history` | bool | true |  | `g_bAddToHistory` |
| `Threading.EnableTaskThreads` | bool | true |  | `NPdxThreadUtilDetail::g_bEnableTaskThreads` |
| `guibounds` | bool | false |  |  |
| `GUI.Wireframe` | bool | false |  | `g_bGUIWireframe` |
| `concepts.collisiondebug` | bool | false |  | `g_ConceptsCollisionDebug` |
| `Net.PrintStats` | bool | false |  | `l_EnableMessageLogging` |
| `Audio.DebugMin` | bool | true |  | `g_bRenderSoundDebugMinRadius` |
| `Audio.DebugMax` | bool | true |  | `g_bRenderSoundDebugMaxRadius` |
| `Audio.Debug.LevelsSampleRate` | int | 20 | -1000000 .. 1000000 | `g_bRenderSoundDebugLevelsSampleRate` |
| `Audio.Debug.Levels` | bool | true |  | `g_bRenderSoundDebugLevels` |
