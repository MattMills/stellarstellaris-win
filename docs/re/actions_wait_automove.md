# Stellaris 4.5.2 (Linux) -- fleet actions `wait` / `effect`, and auto-movement

Source: `/opt/stellaris-headless/re/full.asm` (objdump of the game binary). All addresses are
in that binary. Token ids were resolved from `GetTokenArray()` (0x19a5770: `CToken::CToken(id, str)`
calls); helper: `/root/drawprof/re/tok.sh <hexid>...`. `/root/drawprof/re/fnof.sh <addr>` names the
function containing an address.

Conventions:
- `CFixedPoint` is an int64 with scale 100000 (V10 @0x4866478 = 10000 = 0.10; VZERO = 0).
  Fixed multiply `fmul(a,b)` (inlined everywhere):
  ```
  if (a + 0xb504f333 < 0x16a09e667 && b + 0xb504f333 < 0x16a09e667)   // unsigned compares, i.e. |a|,|b| < ~3.04e9 raw
      r = trunc_toward_zero(a*b / 100000)
  else { hi = max(a,b); lo = min(a,b); q = trunc(hi/100000); rem = hi - q*100000;
         r = q*lo + trunc(rem*lo / 100000) }
  ```
- Game tick = one `CGameState::MicroUpdate`; 10 micro updates per day (DailyUpdate on the day tick).
- Draw = `CRandom::GetIntegerForMacro` (0x3ca1ca0) = `CNoiseRandom::GetInteger()` on `CRandom::_Random`.
  Its value is always in [0, 2^31) (`(a & 0x7ffffffe) ^ (a >> 8)` with logical shift).
  `CRandom::GetFixedPointForMacro` (0x3ca1f30) = ONE draw `v`, returns raw `v % 100000` (a fixed in [0,1)).

---------------------------------------------------------------------------------------------------

## 1. Fleet action queue (where wait/effect actions run)

CFleet fields:
| offset | meaning |
|---|---|
| +0x1208 | `CPdxArray<CFleetAction*>` action queue (data ptr +0x1210, size +0x121c) |
| +0x1220 | `CPdxArray<CFleetAction*>` "to be deleted" (data +0x1228, size +0x1234) |
| +0x1260 bit 0x40 | "front action has been Init()-ed" |
| +0x1260 bit 0x20 | fleet is MIA (skips MicroUpdateSerial entirely) |
| +0x1260 bit 0x200000 | (skips emergency-FTL + combat micro update, and DailyUpdateSerial) |

`CFleet::AddActionToQueue(a)` 0x2946ac0: append `a` to +0x1208; if size becomes 1, clear bit 0x40.
Called by `CQueueFleetActionsEffect::ExecuteActual` 0x372c950, which for each action data of the
`queue_actions` block (in script order) calls `data->CreateInstance(scope)` (vfunc +0x30) and appends.
So for a top-level `wait`, its draw happens at `queue_actions` effect time.

`CFleet::ClearFleetActions()` 0x2946bb0: moves all queued actions to the to-be-deleted list, size=0,
clear bit 0x40, and if auto-move type != 0 -> `SFleetAutoMoveSettings::Reset()` (see 2.1).

### CFleet::MicroUpdateSerial(SCombatParticipants const&) 0x291f460 (every tick, from CGameState::MicroUpdate @0x1b1637a)
```
if (flags1260 & 0x20) return;                       // MIA
if (!(flags1260 & 0x200000)) {
    if (ShouldForceEmergencyFTL()) movement(+0x508).DoEmergencyFTL();
    else combatMgr(+0x790).MicroUpdateSerial(participants);
}
for each a in toDelete: delete a (vfunc +8); toDelete.size = 0;
if (actions.size == 0) return;
a = actions[0];
if (!(flags1260 & 0x40)) { a->Init(fleet) /*vf+0x40*/; flags1260 |= 0x40; }
a->Update(fleet)                                    /*vf+0x48*/;
if (!a->done /*+0x8*/) return;
actions.Remove(a);
if (actions.Find(a) != -1) goto clr;                // a was queued twice: keep it alive
toDelete.Remove(a); delete a;
clr: flags1260 &= ~0x40;
```
=> exactly one front action is updated per tick; Init + first Update happen in the same tick;
after an action finishes, the next one starts on the NEXT tick.

CFleetAction base: vptr, +0x8 bool done, +0xc int token id of the action.
`CFleetAction::Init` 0x2973ba0 is a no-op (used by Wait and ExecuteEffect).
Base save: `CFleetAction::WriteMembers` writes `done=yes` only if done; ReadMember reads `done` (0x3103).

---------------------------------------------------------------------------------------------------

## 2. `wait` action

### Data: CWaitFleetActionData (script `wait = X` or `wait = { duration = X random = Y }`)
- `ReadInternal` 0x2969f10: if the value token is a block (reader+0x278 == 3) -> member parse
  (`ReadMember` 0x2969fd0: `duration` tok 0x6d -> +0x40, `random` tok 0x2c9b -> +0x48, both CFixedPoint);
  else `wait = X` -> +0x40 = X (`CToken::GetFloat`). Default +0x48 = 0.
- `Write` 0x296a010: if random == 0 -> writes the bare value (`wait=30`), else `{ duration=.. random=.. }`.

### CWaitFleetActionData::CreateInstance(CEventScope&) 0x2969e10
```
inst = new CWaitFleetAction (0x18 bytes); inst->done = false; inst->id = 0x30ff ("wait");
u    = GetFixedPointForMacro("fleet_actions.cpp", 0x2ba /*698*/)   // ONE draw, ALWAYS (even if random==0)
                                                                    // u = draw % 100000 (raw), i.e. [0,1)
inst->time (+0x10) = duration(+0x40) + fmul(u, random(+0x48))      // fast path: trunc(random_raw*u_raw/100000)
```
The scope argument is not used. No Init override.

### CWaitFleetAction::Update(CFleet*) 0x296a080
```
time -= V10 (0.1 days, raw 10000);
if (time <= 0) done = true;
```
Units: days, decremented by 0.1 per tick (Update runs once per tick while the action is the
current one). Number of Update calls = max(1, ceil(time_raw / 10000)); `done` is set in the last
of them (that same tick the action is removed). E.g. `wait=30` (no random) -> 300 ticks; the
next action starts on tick 301. A `wait` never ends early (no other condition), and it keeps
counting while the fleet moves/fights (only the MIA flag stops MicroUpdateSerial).

### Save of the instance
`CWaitFleetAction::WriteMembers` 0x296a0f0: `time=<fixed>` (tok 0x1a8, remaining days) and
`done=yes` if done. `ReadMember` 0x296a0b0: `time` -> +0x10, `done` -> +0x8. Example in the save:
`current={ wait={ time=9.9 } }` = 99 more ticks. A loaded wait makes no draw.

### Nested wait (repeat / find_planet), from the parent actions
- `CRepeatFleetAction::Init` 0x2969980: if data child count(+0x54) != 0: done=0, iteration(+0x18)=0,
  child(+0x20) = children[0]->CreateInstance(own scope +0x28) (=> wait draw), child->Init(fleet).
- `CRepeatFleetAction::Update` 0x29699e0:
  ```
  if (child) { child->Update(fleet);
               if (child->done) { delete child; child = 0; ++idx(+0x1c);
                  if (idx >= count) { ++iter; if ((max(+0x58) != -1 && iter >= max) ||
                                                 (while(+0x60) && !while->Evaluate(scope))) done = true;
                                       else idx = 0; } }
               return; }
  if (idx == -1) { done = true; return; }
  child = children[idx]->CreateInstance(scope)   // wait: 1 draw here
  if (!child) { done = true; return; }
  child->Init(fleet); goto top (Update it in this same tick)
  ```
  So a nested wait is created (and draws) on the tick after its predecessor finished, and its
  first decrement is in that same tick.
- `CFindPlanetFleetAction::Update` 0x296bc40 is the same pattern, but when it creates a child
  for a found (valid) planet it first draws once (fleet_actions.cpp 0x483=1155, seeds a local
  CCrudeRandom in a temporary scope with This=planet), THEN calls child CreateInstance (wait: its draw).
  For the `failed` branch (planet invalid) it creates the child with its own scope and no extra draw.
  Its children run once each (index +0x198, done when index >= count).

---------------------------------------------------------------------------------------------------

## 3. `effect` action (CExecuteEffectFleetAction)

Data `CExecuteEffectFleetActionData` (`ReadInternal` 0x296a1c0):
- block form `effect = { id = "x" ... }` -> a `CRootEffect` at data+0x40 (must carry an id that
  `CEffectDatabase::FindNamedEffectInstance` knows, else error log);
- string form `effect = "name"` -> `CScriptedInstanceBase<CSharedScriptedEffect>::Create(name, scope)`
  at data+0x48 (name kept at +0x50). `Write` 0x296a3f0 writes the string (scripted name, or the id).

`CreateInstance(CEventScope& s)` 0x296a140 (no draw):
```
inst = new 0x190 bytes; done = 0; id = 0x59 ("effect"); inst+0x10 = data;
inst+0x18 = CEventScope(s) + CopyInternalScopes(s);  inst+0x188 = 0 (owns data: no)
```
`Update(CFleet*)` 0x296a580 (no draw of its own):
```
if (data) { if (data+0x48 /*scripted instance*/) CScriptedEffectInstance::Execute(data+0x48, scope@+0x18);
            else if (data+0x40) data->effect->Execute(scope@+0x18) /*vf+0x48*/; }
done = true;
```
=> runs exactly once, in the first tick the action is current; the next action starts next tick.
Draws come only from the executed script.
Save: `WriteMembers` 0x296a720: `data=<data string>` (tok 0xf0), `scope={...}` (tok 0x2c8d), `done=yes`
if done. `ReadMember` 0x296a5c0: `data` -> new data object read by `CFleetActionData::Read`, +0x188=1
(owned); `scope` -> +0x18; `done`.

---------------------------------------------------------------------------------------------------

## 4. Auto-movement

### 4.1 SFleetAutoMoveSettings (CPersistent) at CFleet+0x12f0
| CFleet off | struct off | field | save key (token) |
|---|---|---|---|
| +0x12f8 | +0x8 | flags (int) | see bits |
| +0x12fc | +0xc | target id (planet id, or fleet id), -1 = none | `auto_move_target` (0x3af6) |
| +0x1300 | +0x10 | arrival effect: `CScriptedInstanceBase<CSharedScriptedEffect>` ptr | `arrival_effect` (0x2bf7, scope type 0x40) |
| +0x1308 | +0x18 | type (EFleetAutoMoveType) | `type` (0xe1) |

flags bits (+0x12f8):
| bit | save key | meaning |
|---|---|---|
| 0x1 | `clear_auto_move_on_arrival` (0x3af7) | Reset the settings on arrival |
| 0x2 | `clear_on_new_orders` (0x3c34) | `AddOrder` (non-internal) resets the settings |
| 0x4 | `destroy_on_arrival` (0x3afb) | `SetToBeKilled(true,false)` on arrival |
| 0x8 | `has_arrived` (0x3b20) | arrival already handled; HandleAutoMoveArrival does nothing |

type enum (`AutoMoveTokenToEnum` 0x2984800 / `AutoMoveEnumToToken` 0x29847e0):
0 `auto_move_none` (0x3b02), 1 `auto_move_planet` (0x3b04), 2 `auto_move_attack_fleet` (0x3b03),
3 `auto_move_follow_fleet` (0x3b1f).

Writer `SFleetAutoMoveSettings::WriteMembers` 0x294f660: `type=<token>`; `auto_move_target=` if != -1;
then `=yes` for each set flag in order bit1,2,4,8 (clear_auto_move_on_arrival, clear_on_new_orders,
destroy_on_arrival, has_arrived); `arrival_effect=` if the instance is set.
`CFleet::WriteMembers` writes the block `auto_movement=` (tok 0x3b01) only if type != 0 (@0x291bfc5);
`CFleet::ReadMember` reads 0x3b01 into +0x12f0 (`SFleetAutoMoveSettings::ReadMember` 0x294f760,
which maps the keys above to the bits; missing keys stay at the reset state).

`SFleetAutoMoveSettings::Reset()` 0x294e790: type = 0, flags = 0, target = -1, arrival effect cleared
(`CScriptedInstanceBase::Clear` nulls the pointer). No draws.

Checksum (OOS): `CFleet::CalcAutomoveChecksum` 0x294fc00 = target + type + flags.

### 4.2 Fleet conditions used by auto-move
- `is_mobile` = CFleet+0x1260 bit 0x200 (`testb $0x2,0x1261`), maintained by `CFleet::UpdateIsMobile`
  0x291ee00: ships>0 and (first ship +0x570 (speed) > 0, or (!IsSystemLocked() and first ship
  +0x998 != 0)), or HasJumpDrive().
- The "time" fields are not times: cached ship counters from `CFleet::UpdateCachedShipValues`
  0x29223b0 (saved as): +0x32c ship count; +0x1338 `cached_killed_ships` (ships with !IsAlive);
  +0x133c `cached_disabled_ships`; +0x1340 `cached_disengaged_ships`;
  +0x1344 `cached_combined_removed_ships` (disabled or disengaged).
  `has_active_ships(f) = ships == 0 || removed(+0x1344) <= 0 || removed < ships - killed`.
- `CFleet::CanTakeAutoMoveTarget()` 0x2928a40 = `is_mobile && has_active_ships`.
- `CFleet::HasAnyAutoMoveTarget()` 0x291c610 = `type != 0` (trigger `has_auto_move_target`).
  `HasAutoMoveFleetTarget()` 0x294e3b0 = type in {2,3}.
- `CFleet::ShouldInitiateAutoMove()` 0x29290b0 (also inlined twice in HandleAutoMovement):
  ```
  o = current order (+0x2c8); leaf = o; p = &o;
  while (leaf->IsValid() /*vf40*/) { p = &leaf->subOrder(+0x8); if (!(*p)->IsValid()) break; leaf = *p; }
  if (leaf->id(+0x18) == 0x2ce4 /*move_to_system_point_order*/) return false;
  if (movement(+0x508).IsInFTL()) return false;
  if (o->IsValid() && o->IsActualOrder() /*vf128*/) return false;
  return !combatMgr(+0x790).HasCombat();
  ```

### 4.3 Who sets auto-movement
1. **Effect `auto_move_to_planet`** (`CAutoMoveToPlanetEffect`):
   - `Read` 0x3793c30: `auto_move_to_planet = <target>` (bare value = target) or a block parsed
     by `ReadMember` 0x3793d50: `target` (0x6b, CEventTarget at +0xb8), `clear_auto_move_on_arrival`
     (bool +0x288, default **yes**), `destroy_on_arrival` (bool +0x289, default no),
     `arrival_effect` (string +0x258: name of a scripted effect). Defaults from
     `CEffectEntry<...>::Create` 0x3793ac0 (`movw $0x1,0x288`).
   - `ExecuteActual` 0x3793f00: planet = target resolved as planet; if !planet->IsValid() return;
     fleet = scope fleet if IsValid, else scope ship's fleet; if invalid return;
     inst = scripted effect instance created from the name (scope type 0x40);
     `fleet->AutoMoveToPlanet(planet, clear_auto_move_on_arrival, destroy_on_arrival, inst)`. No draw.
   - `CFleet::AutoMoveToPlanet(planet, bool clear, bool destroy, inst)` 0x294e5a0:
     ```
     if (!CanTakeAutoMoveTarget()) return;
     settings.Reset();
     type = 1; target = planet->id(+0x18);
     flags = (flags & ~5) | ((clear||destroy) ? 1 : 0) | (destroy ? 4 : 0);
     arrivalEffect = inst;
     flags &= ~2;                       // clear_on_new_orders always OFF for the effect
     ```
     Nothing moves yet; the order is created by the next HandleAutoMovement (daily).
2. **`CFleet::SaveOrbitTarget()`** 0x2922560, called from `CFleet::DailyUpdateSelfDontReadOthers`
   @0x2921081 (DailyUpdate runs the Self pass @0x1b2458c before the Serial pass @0x1b261b7, so the
   same day). Condition at 0x2921014:
   ```
   if (IsInOrbit() && !(cur->IsValid() && cur->IsActualOrder()) && type == 0 && CanTakeAutoMoveTarget())
       SaveOrbitTarget();
   ```
   (DailyUpdateSelfDontReadOthers itself is skipped when +0x1262&0x20, ships==0, killed==ships, or
   the fleet kind +0x1278 is not in {5,6,9} and the owner's vf+0x58 is false.)
   SaveOrbitTarget: planet = orbit planet (+0x670 if +0x674==1, else -1); if !IsValid return;
   Reset; type = 1; target = planet id; `flags = (flags & ~7) | 2` (clear_on_new_orders=yes);
   arrival effect cleared. **This is the origin of the save's `auto_move_planet ...
   clear_on_new_orders=yes has_arrived=yes` blocks: idle fleets parked in orbit.**
3. `CFleet::AutoAttackFleet` 0x294e430 (type 2), `AutoFollowFleet` 0x29281d0 (type 3) (armada/AI).

### 4.4 Who clears it -- `CFleet::ClearAutoMoveTarget(ECancelAutoMoveMode m)` 0x2928a80
Always `settings.Reset()` first (no draw), then by mode (jump table @0x46af454):
- 0: nothing more.
- 1: `ClearOrdersIf(order->+0x20 && order->id == 0x336e follow_order)`.
- 2: `ClearOrdersIf(order->+0x20 && order->id == 0x2ce5 orbit_planet_order)`.
- 3: `ClearOrdersIf(order->+0x20)`  (+0x20 = "order was created by auto-move").
- 4: if fleet IsValid: `CancelCurrentOrder(0)`; for each queued order (+0x2d8, n=+0x2e4):
  `OrderUnQueued(fleet)` (vf+0x58); then delete them all; queue size = 0.
Callers: HandleAutoMovement (mode 0), AddOrder (mode 0, clear_on_new_orders), CFleetCancelOrdersCommand
(0), HandleArmada / RemoveFleetFromOwnArmada / SetArmadaCommandMode... / PropagateArmadaOrder (1),
effect `remove_auto_move_target` (`CRemoveAutoMoveTargetEffect` 0x3795760: scope ship's fleet or
scope fleet, mode 4). `ClearFleetActions` also Resets if type != 0.

`CFleet::AddOrder(order, bool internal, bool front, CFleet const* follow)` 0x2926b30 (relevant part):
```
if ((cur->IsValid() ? 1 : 0) + queued >= 100) { delete order; return -1; }
if (!internal) { order->+0x12 = orderCounter(+0x1254)++; if (flags1260 & 0x8 && !order->+0x10) { delete; return -1; } }
if (!has_active_ships) { delete; return -1; }
if (!internal) {
    if (!order->CanQueue(fleet, 0) /*vf48*/) { maybe AutoFollowFleet(follow); delete; return -1; }
    if (type != 0 && (flags12f8 & 2)) ClearAutoMoveTarget(0);     // clear_on_new_orders
}
if (cur->id == 0x3300 /*assist_detection_order*/) CancelCurrentOrder(0);
front ? (push current back into queue front, insert order at front) : append order to queue;
if (!internal) order->OrderQueued(fleet); if no current order: StartFirstQueuedOrder();
```
Note: the auto-move's own orbit/follow order is added with internal=false, so for a
SaveOrbitTarget-made setting (clear_on_new_orders=yes) adding the return-to-orbit order Resets the
settings immediately (the fleet still flies back, but no auto-move/arrival is pending any more).

### 4.5 CFleet::DailyUpdateSerial() 0x2923340 -- order of calls
Skipped entirely if +0x1260&0x200000, ships==0, killed==ships, or (kind +0x1278 not in {5,6,9} and
owner vf+0x58 false). Then:
1. MIA handling (+0x688 type 2/3/4: may `GoMIAWithSettings`), unless MIA flag / CannotGoMIA.
2. flag 0x40000 from +0x2a0 bit 4; modifier invalidation if +0x2a0 bit 0.
3. `CTimedModifierCollection::DailyUpdate` (+0x2a8) (+ modifier invalidation).
4. `CFleet::DailyUpdateSerialHandleAccess` 0x291f980 (decloak, border access, OnBorderViolation/GoMIA, SetToBeKilled).
5. `CFleetCombatManager::DailyUpdateSerial` (+0x790).
6. `CFleet::HandleEvasionBehavior` 0x2923830.
7. if MIA flag (0x20): `CFleet::ReturnFromMIA(false)`.
8. if disengaged (+0x1340>0) and no combat: `CShip::SetIsDisengaged(false)` on flagged ships.
9. `CFleet::HandleArmada` 0x29245d0.
10. `CFleet::HandleOrders` 0x2924a90.
11. **`CFleet::HandleAutoMovement` 0x2924cb0 (call @0x2923703)** -- after the orders.
12. `CFleet::HandleMissions` 0x29250d0.
13. (leader class lookup), `CFleet::HandleOverCommandLimit` 0x29253d0.
14. if +0x1262&2: `RecalcCachedCloakingStrength` with CRandom forbidden.
15. `CFleet::UpdateVisibility`, `CFleetCloakingDetectionModule::Update(0)` (+0x12c0).
Fleets are iterated by CGameState::DailyUpdate @0x1b2615d (IsValid ones), each followed by a
ToBeKilled check.

### 4.6 CFleet::HandleAutoMovement() 0x2924cb0 (daily)
```
if (type == 0) return;
if (!CanTakeAutoMoveTarget()) { settings.Reset(); return; }
if (type == 1) {
    planet = Planet(target);
    if (!planet->IsValid()) { settings.Reset(); return; }
    if (movement.IsInOrbit() && orbitPlanetId(+0x674==1 ? +0x670 : -1) == planet->id)
        return HandleAutoMoveArrival();                     // tail call, every day while in orbit
    if (!ShouldInitiateAutoMove()) return;                  // inlined, see 4.2
    COrbitPlanetFleetOrder tmp(*planet); tmp.+0x20 = 1;     // auto-move order
    if (tmp.IsPossible(fleet, null) /*vf a8*/) AddOrder(tmp.Clone(), false, false, null);
    else ClearAutoMoveTarget(0);
} else if (type == 2 || type == 3) {
    tf = Fleet(target);  if (!tf->IsValid()) { settings.Reset(); return; }
    if (!ShouldInitiateAutoMove()) return;
    o = new CFollowFleetOrder(tf->id, /*attack*/ type == 2, false); o->+0x20 = 1;
    if (o->IsValid() && o->CanQueue(fleet, 0)) AddOrder(o, false, false, null);
    else { delete o; ClearAutoMoveTarget(0); }
}
```
No draws in HandleAutoMovement itself (pathing/FTL/orbit-entry draws happen later in movement code:
e.g. `CFleetMovementManager::EnterFTL` 3 draws, `CFleet::OnEnteredOrbit` 2 draws -- not part of this).

### 4.7 CFleet::HandleAutoMoveArrival() 0x2928cf0
```
if (flags12f8 & 8 /*has_arrived*/) return;              // no draw
old = flags; flags |= 8;                                 // has_arrived = yes
if (old & 1 /*clear_auto_move_on_arrival*/) settings.Reset();   // also clears arrival effect + has_arrived!
d1 = GetIntegerForMacro("fleet.cpp", 0xa5a /*2650*/); CEventScope A(d1);   // seed of root scope
d2 = GetIntegerForMacro("fleet.cpp", 0xa5b /*2651*/); CEventScope B(d2);   // seed of fleet scope
d3 = GetIntegerForMacro("fleet.cpp", 0xa5c /*2652*/); CEventScope C(d3);   // seed of planet scope
A.from = &B;  A.Set(type 4 = country, fleet+0x448 /*owner id*/);
B.SetFleet(this); B.from = &C;
C.SetPlanet(orbit planet: +0x674==1 ? Planet(+0x670) : null planet);
COnActionDatabase::PerformEvent("on_fleet_auto_move_arrival", A, 0, null);
   // This = owner country (A), From = fleet (B), FromFrom = planet (C)
if (arrivalEffect(+0x1300) != null) arrivalEffect.Execute(B);     // This = fleet, From = planet
if (old & 4 /*destroy_on_arrival*/) SetToBeKilled(true, false);
```
Consequences (port exactly):
- The 3 draws are unconditional once has_arrived was 0; d1, d2, d3 in that order become the
  `random` seeds of the root (owner), From (fleet) and FromFrom (planet) scopes. Any further draws
  are from the on_action's events (each fired event etc.) and from the arrival effect.
  (Measured 27 draws in 7 calls = 21 own + 6 from on_action handlers.)
- With `clear_auto_move_on_arrival` (bit 1; the effect sets it when clear OR destroy): the settings
  are Reset BEFORE the effect check, so the `arrival_effect` is never executed and the block
  disappears from the save (type 0). destroy uses the saved old flags, so it still kills.
- Without it: type/target stay, has_arrived=yes stays; later days re-enter (in orbit) and return
  immediately. If the fleet leaves the orbit, HandleAutoMovement sends it back (orbit order), but
  on re-arrival nothing fires again (has_arrived only clears via Reset).
- For SaveOrbitTarget settings (flags=2): the first daily pass after a fleet settles idle in orbit:
  Self pass -> SaveOrbitTarget (type 1, has_arrived 0), Serial pass -> HandleAutoMovement -> in orbit
  -> HandleAutoMoveArrival -> 3 draws + on_action, has_arrived=yes. It fires again only after some
  non-internal AddOrder (clear_on_new_orders) or other Reset, followed by idling in orbit again.

---------------------------------------------------------------------------------------------------

## 5. All CRandom draws on these paths
| site | call | count | condition |
|---|---|---|---|
| CWaitFleetActionData::CreateInstance 0x2969e30 | GetFixedPointForMacro (fleet_actions.cpp:698) -> 1 GetIntegerForMacro | 1 | every instance creation (queue_actions effect time for top-level; repeat/find_planet child creation for nested), regardless of `random` |
| CWaitFleetAction::Update | -- | 0 | |
| CExecuteEffectFleetActionData::CreateInstance / CExecuteEffectFleetAction::Update | -- | 0 | (only the script's own draws) |
| CFindPlanetFleetAction::Update 0x296bddb (context) | GetIntegerForMacro (fleet_actions.cpp:1155) | 1 | per child created with a found valid planet, before the child's CreateInstance |
| CFleet::HandleAutoMoveArrival 0x2928db9 / 0x2928dd5 / 0x2928df5 | GetIntegerForMacro (fleet.cpp:2650/2651/2652) | 3 | HandleAutoMovement: type==1, CanTakeAutoMoveTarget, planet valid, in orbit of the target, has_arrived==0 |
| on_fleet_auto_move_arrival events, arrival_effect | script | var | after the 3 draws |
| CFleet::HandleAutoMovement, AutoMoveToPlanet, SaveOrbitTarget, ClearAutoMoveTarget, SFleetAutoMoveSettings::*, CanTakeAutoMoveTarget, ShouldInitiateAutoMove, CAutoMoveToPlanetEffect::ExecuteActual, MicroUpdateSerial action loop | -- | 0 | (AddOrder has no direct draw; movement/orbit-entry draws are elsewhere) |
