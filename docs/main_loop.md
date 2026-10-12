# The main loop and access to the game state (4.5.2)

Reverse engineered from the GOG 4.5.2 build and its PDB (names, class layouts), the stellar-fnmatch
extract of that build (call graph, referenced globals) and its disassembly. Steam 4.5.2 addresses
come from lua_fnmatch: the functions below have the same first bytes in both builds.

Addresses are RVAs (add the module base).

## The loop

```
CApplication::Run                                     loop until quit ([this+0xCB])
  CApplication::UpdateOneFrame                        frame counter: [this+0x420], idler: [this+0x08]
    idler->vfunc[11]  = CGameIdler::Idle
      CGameApplication::Update                        opens the game state for the frame (below)
        CSession::Update
          CSession::ProcessSynchronousCommands        every queued command, one at a time
            command->Execute()                        e.g. player actions, and:
            CTurnTickCommand::Execute                 one per game day, tail-jumps to
              CGameState::HandleTurnTick              MicroUpdate, ProcessAI, DailyUpdate,
                                                      MonthlyUpdate, YearlyUpdate, autosave, ...
      CInGameIdler::UpdateInternal
        CInGameIdler::CheckTick                       decides a day is due: posts a CTurnTickCommand
                                                      and runs CSession::Update itself (same gate)
        ... UI update and rendering
```

During long days `HandleTurnTick` renders frames itself (`CGameState::RenderFrame` ->
`CApplication::UpdateOneFrame`), so the UI keeps running inside the tick. Those nested frames cannot
execute commands: `CSession::Update` refuses while `CSession::_IsInExecution` is set.

## How the game guards the game state

There is no lock around the game state. One thread (the main thread) owns it, and globals say what
the code running on it may do:

| global | GOG 4.5.2 | meaning |
|---|---|---|
| `CGameState *g_CurrentGameState` | `0x31003e0` | the game state |
| `bool g_AllowGlobalGameStateAccess` | `0x3100ac8` | the gate: `AccessCurrentGameState()` (inlined everywhere) logs "Illegal call to AccessCurrentGameState" in random-log builds when it is false |
| `bool g_AllowPostCommandToSession` | `0x27f3980` | false while commands execute: nothing may post a new command |
| `bool g_AllowGetPlayer` | `0x27f37a9` | false while commands execute |
| `int g_nThreadSafetyState` | `0x27ffcb4` | what kind of code may run: 1 (its initial value) for serial main-thread code; DailyUpdate / MonthlyUpdate set other values around their parallel phases (0x2, 0x4, 0x100000, ...), 0x40000 for modifier and effect evaluation; always saved and restored |
| `CGameIdler *g_CurrentIdler`, `CInGameIdler *g_CurrentInGameIdler` | `0x3100b58`, `0x3100b50` | |

`CGameApplication::Update` (the frame) and `CInGameIdler::CheckTick` (the tick) open the game state
the same way: `g_AllowGlobalGameStateAccess = 1`, `g_AllowGetPlayer = 0`,
`g_AllowPostCommandToSession = 0`, then `CSession::Update`, then the old values back. Code that needs
the game state outside that window (console commands, some UI actions, the render-in-tick helpers)
saves, sets and restores the gate itself.

`CGameApplication::Update` also installs two `CSession` callbacks for its own command processing:
`_pAfterExecuteCommandsFunc` = `CGameState::AfterCommandExecutedUpdate` (after each command: updates
the modifier tree under `g_nThreadSafetyState = 0x40000`) and `_pBetweenCommandsFunc` =
`CGameState::RenderFrameBetweenCommands`. They are cleared afterwards, so they do not run for
commands executed by `CheckTick`, which is where the day usually runs.

## The game database

`CGameState` (3008 bytes) points to it: `_pDB` at `+0x930` is a `CGameStateDatabase` (7488 bytes)
holding every object database:

| offset | member |
|---|---|
| `+0x0` | `_ModifierNodeManager` |
| `+0xe00` | `CPlanetManager _Planets` |
| `+0xed8` | `CStarbaseManager _Starbases` |
| `+0xf60` | `TPdxRefDatabase<CColony> _Colonies` |
| `+0xf98` | `TPdxRefDatabase<CCountry> _Countries` |
| `+0x1008` | `TPdxRefDatabase<CFleet> _Fleets` |
| `+0x1040` | `TPdxRefDatabase<CLeader> _Leaders` |
| `+0x1078` | `TPdxRefDatabase<CGalacticObject> _GalacticObjects` |
| `+0x11c8` | `TPdxRefDatabase<CWar> _Wars` |
| `+0x1628` | `TPdxRefDatabase<CShip> _Ships` |
| `+0x1660` | `TPdxRefDatabase<CSpecies> _Species` |

(and about 60 more: armies, pops, deposits, federations, megastructures, sectors, ...). `CGameState`
also keeps arrays of references for iteration (`_FleetArray +0x4f8`, `_ShipArray +0x540`,
`_CountryArray +0x558`, `_PlanetArray +0x5c0`, ...), the date (`_CurrentDate +0xc0`) and
`_bHasGameStarted` (`+0xa0`).

## Where to hook: `CGameState::HandleTurnTick`

`void CGameState::HandleTurnTick(CGameState *this, CTurnTickCommand *command)`:
GOG 4.5.2 `0x252830`, Steam 4.5.2 `0x251800`.

- It runs exactly where the game itself changes the database: inside
  `CSession::ProcessSynchronousCommands` (from `CheckTick` or `CGameApplication::Update`), on the
  main thread, with the gate open, posting disabled, `CSession::_IsInExecution` set and no parallel
  phase active (`g_nThreadSafetyState` is 1, the serial main-thread value).
- It is the body of a synchronized command, so every multiplayer client runs it at the same point:
  changes made from it stay in sync if they are deterministic.
- `this` is the game state (`this->_pDB` is the database). Before the original runs, the new day has
  not started; after it returns, the day, month and year updates are done.
- It is never re-entered: nested frames inside the tick cannot execute commands.
- Its first instruction (`mov [rsp+0x10], rbx`, 5 bytes) moves to a trampoline as is, and it is
  identical in the GOG and Steam builds.

A wrapper should do what the game's own helpers do around code that touches the game state: save
`g_AllowGlobalGameStateAccess`, set it to 1, call Lua, restore it. A frame rendered during the day
can leave it at 0 when `HandleTurnTick` returns.

Other places, and why not:

| | |
|---|---|
| `CTurnTickCommand::Execute` (GOG `0x95eee0`, Steam `0x9603e0`) | same point, but it also loops over the humans first; `HandleTurnTick` is the core |
| `CGameState::AfterCommandExecutedUpdate` (GOG `0x24cfb0`) | after each command, but only for commands `CGameApplication::Update` executes, not the ticks `CheckTick` executes, and not for AI-posted commands |
| `CSession::ProcessSynchronousCommands` (GOG `0x1a54cb0`, Steam `0x1a5a6e0`) | every frame, also while paused: good for reading the state every frame (check `g_AllowGlobalGameStateAccess` and `g_CurrentGameState`, it is also called from the lobby and hot join), but changes made there are not synchronized in multiplayer |
| `CGameApplication::Update` entry | the gate is still closed there |
| `CGameState::RenderFrameBetweenCommands`, `RenderFrame` | rendering, possibly nested inside a tick |

## Finding the globals in other builds

The globals have no signatures of their own. Find a function that uses them with lua_fnmatch (for
example `CGameApplication::Update` or `CTurnTickCommand::Execute`), then decode the RIP-relative
operand of the instruction that uses the global inside it (sigmatch over the function's range):

| global | instruction in `CGameApplication::Update` |
|---|---|
| `g_AllowGlobalGameStateAccess` | `c6 05 ?? ?? ?? ?? 01` (first `mov byte ptr [rip+x], 1`) |
| `g_AllowGetPlayer` | `c6 05 ?? ?? ?? ?? 00` (the instruction before it) |
| `g_CurrentGameState` | `48 39 3d ?? ?? ?? ??` / `4c 39 3d ?? ?? ?? ??` (`cmp [rip+x], r15`) |

## Also in this pass

The `CApplication` layout in `include/stellaris/CApplication.h` is from 3.7.4. In 4.5.2 the idler
is at `+0x8` and the frame counter at `+0x420`, which is why the heartbeat in dllmain.cpp reads them
with checked reads.
