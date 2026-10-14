# Fleet movement (4.5.2)

How the game moves fleets each tick: the pathfinder, sublight movement in a system, hyperlane FTL
(windup, flight, arrival), the systems' fleet presence and the random draws of the fleet phase.
Ported in `sim/lua/engine/fleets/movement.lua` and `sim/lua/engine/fleets/path.lua` (the
pathfinder and the fixed-point geometry). The part of [fleets.md](fleets.md) that orders, the AI
and exploration call.

Read from the GOG 4.5.2 build (PDB names and layouts) and, where the GOG build inlines a function,
from the Linux 4.5.2 build, which has full symbols: r2ghidra decompiles of the Linux executable,
the call targets named from its symbol table. GOG addresses are given first, Linux ones as `L:`.
**[V]** = read in the code, **[I]** = inferred from the headless game's runs (`headless/run.sh`).

## The save's form

```
fleet = { <id> = { ...
    movement_manager = {
        formation = { scale angle type }                      CFleetFormation (+0x118)
        coordinate = { x y origin [visual_height] }           _Coordinate (+0x78)
        target = { coordinate = { ... } [anchor] }            _Target (+0x10)
        target_coordinate = { x y origin }                    _TargetCoordinate (+0x50)
        time_since_last_path_update = n                       (+0xe8, left out when 0)
        state = move_wind_up | move_wind_down | move_idle | move_system | move_galaxy | move_jump_anim
        ftl_windup = n  ftl_winddown = n                      (+0x150, +0x158, left out when 0)
        path = { node = { coordinate = { ... } ftl = jump_hyperlane [bypass = id] } ...
                 date = "<ETA>" }                             CFleetPath (+0xf0)
        orbit = { orbitable = { planet } index }              CFleetOrbitalSlotHandle (+0x160)
        last_ftl_jump = { from = { ... } to fleet jump_method bypass_from bypass_to }   CFTLJump (+0xa0)
        ftl_anim_counter = n  ftl_total_windup = n            (+0x15c, +0x154)
        custom_formation = { ... } } } }
galactic_object = { <id> = { ... fleet_presence = { <fleet ids> } ... } }   _PrecalcFleetPresence
ships = { <id> = { ... speed coordinate target_coordinate post_move_angle ... rotation forward_x forward_y } }
```

The order is `CFleetMovementManager::WriteMembers` (L:0x298bd10) **[V]**. The states are
`NMovement::EState`: 0 FTL_WIND_UP, 1 FTL_WIND_DOWN, 2 IDLE, 3 MOVING_IN_SYSTEM, 4
MOVING_IN_GALAXY, 5 FTL_JUMP_ANIM; the jump methods `EPathJumpMethod`: 0 hyperlane, 1 bypass, 2
jump_count (none yet) **[V]** (PDB enums). Coordinates are CFixedPoint (int64, 1.0 = 100000): in a
system relative to its star, in the galaxy (`origin=4294967295`) the galactic position. A
hyperlane's `length` is read as a CFixedPoint (`CHyperlane::ReadMember` 0x883e80): the saved
integer is the length the pathfinder uses **[V]**.

## The tick **[V]**

`CGameState::MicroUpdate` runs the fleet phase every tick, before the ship pool:
`CFleetMovementManager::MicroUpdate` (0xe25160, L:0x298c000):

1. parallel, every fleet: `UpdateFleetMovementOnlyChangeSelfPrivate` (0xe27ac0): the executing
   order's target (`GetFleetTargetCoordinate`) and whether it needs a move;
2. parallel, every fleet: `UpdateFleetMovementDontReadOthers` (0xe289b0): the sublight part;
3. serial, every fleet in order: `UpdateFleetMovementSerial` (0xe27730): `UpdateFTLJump`
   (0xe25ed0) for the states 0, 1, 4 and 5, then the orbit entered or left;
4. parallel: the ships (`SShipMoveUpdateFunc`, `SShipMoveFinalizeFunc`).

Skipped: fleets to be killed, immobile (`properties.mobile`), disabled, MIA; a fleet in combat
moves toward its combat coordinate instead.

**DontReadOthers**, by state:

- WIND_DOWN, MOVING_IN_GALAXY, FTL_JUMP_ANIM: nothing.
- IDLE, MOVING_IN_SYSTEM: `UpdateTargetCoordinate` (0xe25ab0): no target (the order needs no
  move) clears the target and the path (IDLE); a path that is gone or crosses a system the fleet
  may not enter (`CFleet::HasAccess`) is planned again (`UpdatePath`, forced); a changed target is
  planned again, at once when it is in another system, else after 50 ticks of
  `time_since_last_path_update`; at the target: cleared, IDLE.
- FTL_WIND_UP: `_CheckCancelFTLWindup` (0xe28d90): a new path from the order's target that starts
  with another jump cancels the windup.

Then, with a target: `time_since_last_path_update` + 1; the first node in another system starts
the jump (`BeginFTLJump`), else the state is MOVING_IN_SYSTEM and the fleet moves
(`MoveTowards`); within 1.0 of the node (`CCelestialCoordinate::IsNear` 0x349f00) the node is
done, and the last one ends the movement (`CancelMovement` 0xe2bbd0: target and path cleared,
IDLE).

**MoveTowards** (0xe294e0): `CalcTowards(coordinate, node, CFleet::CalcMaxSpeed / 10)`, then
`UpdateFormation` (0xe275b0). `CCelestialCoordinate::CalcTowards` (0x34a5d0): `dist = isqrt(dx² +
dy²)` on the raw integers (Newton from n/2); past the target it gives the target; else `from +
(dx * step / 100000) * 100000 / dist` per axis, truncated toward zero. All 39 fleets moving in a
system on the first tick of the 2210.01.01 save are reproduced to the last digit by it **[I]**.

**BeginFTLJump** (0xe27390): `CFleetPath::Create` from the fleet to the next node (the node in
the next system): the path becomes [leave point, enter point, enter point]; at its leave point
(closer than 1.0) the windup starts: `ftl_total_windup = CFTLJump::CalcFTLWindUp`, state
FTL_WIND_UP.

**UpdateFTLJump** (0xe25ed0), by state:

- FTL_WIND_UP: every system of the path must still be open (else `OnMoveOrderChanged`, 0xe2bcd0);
  `ftl_windup` + 1; at `ftl_total_windup`: a jump `CFTLJump(coordinate, node 1's system, fleet,
  node 1's method, node 0's bypass, node 1's bypass)`; a bypass jump goes to FTL_JUMP_ANIM, a
  hyperlane one to `EnterFTL`.
- MOVING_IN_GALAXY: `CalcTowards(coordinate, the galactic coordinate of node 0's system,
  CalcFTLSpeed)`; there: `LeaveFTL`. (An empty path sends the fleet MIA.)
- FTL_WIND_DOWN: `ftl_winddown` + 1 up to `CalcFTLWindDown`, then IDLE.
- FTL_JUMP_ANIM: the bypass type's animation ticks, then `EnterFTL`.

**EnterFTL** (0xe26460): `last_ftl_jump` = the jump; out of the system's presence
(`RemovePrecalcFleetPresence` 0x86c190), `CGalacticObject::OnFleetLeft` (0x867740); state
MOVING_IN_GALAXY; node 0 dropped; the counters zeroed; teleported (`TeleportFleetToCoordinate`
0xe2a810) to the left system's galactic coordinate, facing 0. A bypass jump also fires the
bypass type's on_action (three scopes, three draws).

**LeaveFTL** (0xe27150): state FTL_WIND_DOWN, or IDLE when the winddown is 0 (hyperlanes:
`HYPERLANE_WINDDOWN = 0`); teleported to `CalcFTLEnterSystemPoint`, facing `Atan2(y, x) - (pi/2 +
pi)`; `CGalacticObject::OnFleetEntered` (0x866e70) with the system it came from. (Entering a system
the fleet has no access to sends it MIA, with a border violation.)

**TeleportFleetToCoordinate** (0xe2a810): out of the old system's presence, the coordinate and the
formation's angle set, the formation placed and the ships snapped to it
(`CShip::SnapToFormation`), into the new system's presence (`AddPrecalcFleetPresence` 0x86c0a0:
appended when absent), then `UpdateTargetCoordinate` forced: the path is planned again from where
the fleet is. In FTL (`UpdatePath` in MOVING_IN_GALAXY) it is planned from the enter point the
jump will come out at; when no path, that point alone.

**UpdatePath** (0xe25470): `time_since_last_path_update = 0`; in a system: kept when its last
node is the target, or moved to the target when it is in the same system and the path is open;
else `CFleetPath::Create`. The ETA (`path.date`) is today + `CFleetPath::CalcEstimatedDays`
(0xe20b40) rounded, except in FTL.

**RepairData** (L:0x29924a0), at the load: a `last_ftl_jump` whose fleet is not a fleet becomes
this fleet's, to the system it is in, no bypasses (69 fleets of the 2210.01.01 save).

## Pathfinding **[V]**

`CFleetPath::Create(from, to, null, fleet, settings)` (0xe21390, L:0x29880d0): in another system,
`FindPath` (0xaff330); for each system of the route the jump's leave point (when in a system) and
enter point, then the target itself (jump_hyperlane). The movement's settings
(`CFleet::CalcMovementPathFindSettings`) always include CheckAccess, evasive for some fleets.

`FindPath` -> `FindPathHyperlane` -> `FindPathInternal` (0xaff020) -> the access variant of
`CAStarAlgorithm<CAStarHyperlaneWithBypassConfigPolicy<SFindFleetPathValidatorFuncBase<..>,
SFindFleetPathCostFunc, SNoHeuristics, CAStarHyperlaneWithMethodNode>,
CFindFleetPathResultPolicy>::Find` (inlined, L:0x29ef690): Dijkstra over the systems, indexed by
the system's id:

- a binary min-heap of (cost, system): the root swapped with the last, sifted down over the first
  n - 1 (the right child first, `<=` keeps the parent), new and improved nodes sifted up (`<=`
  stops);
- a popped system is closed; at the target the route is its parents' chain, the start left out;
- the adjacencies: the system's hyperlanes in the save's order, then its bypasses' connections;
- a node reached again: a lower cost replaces the parent, an equal cost replaces it when the new
  parent's chain is shorter.

The cost of a hyperlane (`SAStarHyperlaneWithBypassCostFuncBase::Eval`, L:0x2622660):
`HYPERLANE_WINDUP + 1 + length / HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED` = 151 + the saved integer
length; doubled into a system where the country knows hostiles when it is not at war
(`HasSystemHostilesCached`), plus `FLEET_PATHFINDING_COSMIC_STORM_WEIGHT` (10) into an active
storm. A bypass costs its type's windup and winddown ticks + 1.

The validator (L:0x29fbfe0): a hyperlane is skipped without an FTL drive or when
`CanUseHyperlanesFromSystem` (L:0x29f2010) says no: the lane back to the system of the last jump
is always open; else the from system must be in the country's hyperlane range (`hyperlane_systems`)
and, for a fleet that cannot explore, the to system too; between two unexplored systems only an
exploring fleet (`CAN_TRAVEL_BETWEEN_UNEXPLORED_SYSTEMS = no`). A system is closed for the search
when its owner is not friendly and the country has no access (closed borders), for an evasive
fleet when it knows hostiles there, for a fleet that cannot explore when it is unexplored
(`DoesSystemRequireExplorationCached` 0x74e290: `LIMITED_EXPLORATION = 1` and intel level 0), and
when restricted. `CFleet::CanExplore` (0xc85020): a military or science fleet with a commander or
scientist (the leader is the save's `ship.leader`).

The points (`CGalacticObject::CalcFTLPointWith`, 0x86d090 / 0x86d0d0): `CalcTowards(the system's
galactic coordinate, the other system's, 1.05 * inner_radius, no clamp, relative)`, in the system:
the leave point toward the next system (`CFTLJump::CalcFTLLeaveSystemPoint` 0xe1fcc0), the enter
point toward the system the jump comes from (`CalcFTLEnterSystemPoint` 0xe20160). A hostile FTL
magnet in the destination (`_PrecalcFTLMagnetPresence`) pulls the enter point to
`FTL_MAGNET_DISTANCE` from it toward the star. A point inside the gravity well with no other
system (`CalcClosestPointOutsideOfGravityWell` 0xe1e660) is pushed to 1.05 * the inner radius.

## Speeds and times

- **Sublight** (`CFleet::CalcMaxSpeed` 0xc7e0c0): the slowest ship's cached speed, at least 0.1;
  a tick moves a tenth of it. The ship's (`NShipUtil::CalcMaxSpeed` 0xa11d20) **[V]**: the
  design's base speed (its ship size's `max_speed` * `SHIP_SPEED_SCALE` 0.045 **[I]**) * (1 +
  `ship_base_speed_mult`) * max(min, 1 + `ship_speed_mult` + `owned_ship_speed_mult` +
  `space_fauna_ship_speed_mult`), `ship_speed_reduction` applied, then * (1 +
  `ship_federation_territory_speed_mult` in owned or federation space + `..community..` + the
  military / science class terms + psionic aura + the damage penalty). `CShipSize::GetModifierValue`
  adds the size's own modifier (`shipsize_<size>_speed_mult`).
- **FTL** (`CalcFTLSpeed` 0xe1e340): `HYPERDRIVE_INTERSTELLAR_TRAVEL_SPEED` (1.0 a tick) * (1 +
  `ship_interstellar_speed_mult`), the ships' average.
- **Windup** (`CFTLJump::CalcFTLWindUp` 0xe1f6a0): hyperlane `HYPERLANE_WINDUP` (150 ticks) * (1 +
  the fleet's lowest `ship_windup_mult`); winddown likewise (`HYPERLANE_WINDDOWN` 0).
- **ETA** (`CalcEstimatedDays`): per leg, a jump's windup + winddown + FTL travel ticks, a
  system's distance at the sublight speed, in days.

## The angles

`CCelestialCoordinate::AngleTo` = `CFixedPoint::Atan2(dy, dx) - VFixedPIHalf` (1.571); `Atan2`
(0x1b46a20) is the octant approximation: `r = (x - |y|) / (x + |y|)`, `pi/4 - pi/4 r` (`x < 0`: `r
= (x + |y|) / (|y| - x)`, `3pi/4 - pi/4 r`), negated for `y < 0`. `fixed_int64::sin` (0x1b43e30):
reduced to [0, pi/2], `x - x³/6 + x⁵/120` truncated (`_sinx` 0x1b43c60); cos(a) = sin(a + 1.5708).
`VFixedPI` is 3.142 and `VFixedPITwo` 6.284. The formation faces the next node in the system
(`UpdateFormation`); every ship gets its place and angle (`UpdatePositionInFleetFormation`: the
save's `target_coordinate` and `post_move_angle`); a snap sets the ship there with `rotation` =
the angle and `forward = (-sin, cos)` normalized.

## Systems entered and left: the draws **[V]**

`CGalacticObject::OnFleetLeft` (0x867740): two event scopes (two `CRandom::GetIntegerForMacro`),
`on_leaving_system_fleet` (this = the fleet, from = the system). `OnFleetEntered` (0x866e70):
the controller's terra incognita cleared, the ships entered, contact made, two scopes and
`on_entering_system_fleet`; into another owner's system a `CCrudeRandom` seeded by one draw gives
three scopes, `on_crossing_border` (from = the system left). These are the fleet phase's own draws
(482 in `CFleetMovementManager::MicroUpdate` over 180 days in the headless profile); the rest of
the phase's (`CFleet::MicroUpdateSerial`, 471) is the orders'.

## The port

`movement.lua` keeps each fleet's movement manager parsed (raw integers), runs the tick as above
(DontReadOthers for every fleet, then the serial part, in the save's fleet order), and writes the
block back in the game's order; `fleet_presence` lists are edited in place (an empty one is left
out, a new one is written after `initializer`). Only fleets with something to do are visited.
The draws are made with `RUST.rand()` where the game makes them, before the ship pool
(`P["micro.update"]` in systems.lua calls `movement.tick` before `RUST.skip`). The on_actions go
through the script layer (`simscript.events.on_action`, from = the system).

The movement's target stands for the executing order's. `movement.move_to(fleet, target)` sets it
and plans the path at once (as an order's start does through `OnMoveOrderChanged`); the API is at
the top of movement.lua.

Dev switches: `STELLAR_MOVEMENT=off` (the movement does nothing: a check's baseline);
`STELLAR_FLEET_SPEEDS=<file>` (`<fleet> <raw speed>` lines: speeds measured in the game in place of
the computed ones, to tell the logic from the speeds).

## Checks

From `autosave_2210.01.01` (tick 4) against `headless/run.sh` of the same save after 1, 10, 50,
100, 300 and 1,798 ticks (outputs in `/opt/stellaris-headless/out/fleetmove/`), compared with
`fm.py` / `cmp2.py` (in `/root/fleetmove` on 10.5.0.24: every moving fleet's state, path, windup,
ETA, position, and the systems' presence) and `examples/diff`.

**Which fleets.** 46 fleets move at load (a path or a state other than idle). One (261, space
amoebae) is in combat and excluded. The others are compared as long as the game's run shows them
on the target they had at load; a fleet the game gives another target (its order or the AI: the
space fauna and the fallen empire's fleets, 11 by tick 300), or that its order moves again after
it arrived (survey orbits), is left out from then on.

| ticks | fleets compared | state | path (systems) | path (every node exact) | windup | position exact | presence |
|---|---|---|---|---|---|---|---|
| 10 | 45 | 45 | 45 | 45 | 45 | 23 | 45 of 45 |
| 50 | 43 | 43 | 43 | 43 | 41 | 22 | 42 of 42 |
| 100 | 40 | 40 | 40 | 40 | 38 | 16 | 38 of 38 |
| 300 | 34 | 31 | 33 | 32 | 29 | 8 | 34 of 34 |

With the game's speeds (`STELLAR_FLEET_SPEEDS`, fitted from the first tick: every one of the 39
moving fleets' first steps is reproduced exactly by CalcTowards) the positions are exact for 45
of 45 at tick 10, 41 of 43 at 50 (2 within 0.0003), 34 of 40 at 100 and 22 of 34 at 300: what is
left is legs after a jump, where the computed speed is used again.

**Jumps and arrivals.** The ticks of the jumps and arrivals that follow from the paths at load
are the game's to the tick, each checked against the run at that tick and the one before:

| fleet | event | tick |
|---|---|---|
| 173 | arrived (in its system) | 26 |
| 499 | enters FTL / comes out | 35 / 66 |
| 607 | enters FTL / comes out | 61 / 89 |
| 498 | enters FTL / comes out | 63 / 102 |
| 597 | enters FTL / comes out | 69 / 86 |
| 38 | enters FTL / comes out | 83 / 104 |
| 686 | enters FTL / comes out | 116 / 156 |

Their paths planned again at the jump (up to 6 jumps) are the game's node for node, and the
systems' `fleet_presence` changes with them (the fleet out of the system it leaves when it enters
FTL, appended to the one it arrives in).

**Store by store** (`examples/diff`, the movement off / on, the diff's own tolerance of 1e-3
relative):

| ticks | store | fields equal, off | on | differ, off | on |
|---|---|---:|---:|---:|---:|
| 1 | fleet (804) | 58,569 | 58,815 | 983 | 737 |
| 1 | ships (2,504) | 109,388 | 109,432 | 1,352 | 1,308 |
| 1 | galactic_object (596) | 21,967 | 21,967 | 0 | 0 |
| 300 | fleet | 57,619 | 58,063 | 1,675 | 1,153 |
| 300 | ships | 108,481 | 108,531 | 2,363 | 2,313 |
| 300 | galactic_object | 21,947 | 21,964 | 34 | 7 |
| 1,798 | fleet (800 in both) | 55,833 | 56,175 | 3,592 | 2,975 |
| 1,798 | ships (2,492 in both) | 107,707 | 107,758 | 2,729 | 2,673 |
| 1,798 | galactic_object | 21,895 | 21,926 | 142 | 95 |

After one tick what is left in the fleets is the load's (721 `properties.dirty_cloaking_strength`
the game adds) and 5 positions. No phase errors. The movement draws 146 values over the 1,798
ticks (the systems left and entered and the events they fire); the game's fleet phase about
1,000, most of them from jumps of new orders.

**What differs, and why.**

- **Speed.** The AI empires' civilian ships move 0.67%, 2.67% or 4.67% faster in the game than the
  formula gives (a factor `1 + 1/150 + 0.02 k` on top of everything else, per country and ship
  class, the same in every system): no modifier in the game's own capture of the ship and fleet
  nodes holds it; not found. Space monsters' speeds come from the rewrite's modifier graph, which
  differs from the game's for some (fleets 159, 189, 347). Everything after the first leg
  inherits it: positions, the tick a fleet reaches its leave point (windups 1-11 ticks late by
  tick 300), the ETAs written when a path is planned again.
- **Ships.** The ships' own movement toward their places (`CShip::InternalUpdateMovement`:
  acceleration, turning, their `speed`) is not ported: a ship follows its place at its fleet's
  speed **[I]**. Places are ported for single-ship fleets: their `target_coordinate` and
  `post_move_angle` are the game's to the digit (the Atan2 approximation), and the snaps of a
  jump give the game's coordinate, rotation and forward vector (exact for the fleets in FTL at
  ticks 100 and 101); the wedge and circle offsets of larger fleets are not.
- **New orders** (the AI's, the orders' re-targeting): the other parts' (orders, AI).

## Not ported

- Bypasses (gateways, wormholes, L-gates, the jump animation, their on_action), jump drives,
  emergency FTL, MIA, FTL inhibitors and magnets.
- Closed borders and access (`CFleet::HasAccess`, `HasAccessLevelCached`, restricted systems:
  every system open), known hostiles and cosmic storms in the costs, the overlord and
  FTL-inhibitor rules of `CanUseHyperlanesFromSystem`. Hooks for the parts that will know them:
  `path.hooks.has_access(data, system)`, `.restricted`, `.hostiles`, `.storm(storm_id)` for the
  pathfinder, `movement.hooks.has_access(fleet, system)` for the movement's own checks.
- Combat movement (a fleet in combat is left where it is); orbits (the orders keep `orbit`).
- The ETA's speed factors (`CalcEstimatedDays`' ship and star speed reduction terms).
- `OnFleetEntered`'s terra incognita, contact and ship entry (`movement.hooks.on_entered` for the
  exploration part), `on_crossing_border`'s fromfrom scope.
