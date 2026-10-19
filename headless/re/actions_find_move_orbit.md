# Fleet actions: find_planet, move_to, orbit_planet (Stellaris 4.5.2 Linux)

Source of truth: `/opt/stellaris-headless/re/full.asm` (non-PIE, addresses are absolute).
Source file string used by every macro draw: `0x46b28ac` =
`/mnt/gsg/stellaris/augustus/augustus/source/spatial_objects/fleet_actions.cpp`.
Token ids are resolved with `/root/drawprof/re/tokens.tsv`.

## 0. Common things

### CFleetAction base (vtable `0x526d490`)
```
+0x00 vtable
+0x08 bool  done              save key "done" (0x3103), written only when true
+0x0c int   type token        find_planet 0x3106, move_to 0x3108, orbit_planet 0x30fc
```
Virtual slots used: `+0x40 Init(CFleet*)` (base Init `0x2973ba0` = no-op), `+0x48 Update(CFleet*)`,
`+0x08` deleting dtor. `CFleetActionData` slot `+0x30 CreateInstance(CEventScope&)`.

### Fixed-point squared distance `fpsq` (inlined, 3 copies: FindPlanet Init x2, MoveTo Update)
CFixedPoint raw = value * 100000 (int64). Constants: `0xb504f333`, `0x16a09e667`,
`0x29f16b11c6d1e109` (signed /100000 via mulhi >>14), `0xa7c5ac471b47843` (unsigned /3125 via mulhi >>7).
```
int64 fpsq(int64 d):                         // = CFixedPoint d*d
    if ((uint64)(d + 0xb504f333) < 0x16a09e667)          // |d| small
        return ((uint64)(d*d) >> 5) / 3125;              // == floor(d*d / 100000)
    q = d / 100000;            // C truncating division
    r = d - q*100000;
    return q*d + (r*d) / 100000;                         // truncating
distSq(a, b) = fpsq(a.x - b.x) + fpsq(a.y - b.y)          // int64 add, no clamp
```
Coordinates: `CFleet::GetCoordinate()` (vtable slot 0x70, `0x2946440`) returns `fleet+0x580`
(a `CCelestialCoordinate`: +8 x, +0x10 y, raw fixed point, system-local).
`CPlanet::GetCoordinate()` (slot 0x58, `0x1a4e810`) returns `planet+0x30` (same layout).
Distances ignore the origin field (both are system-local coordinates).

### Planet list of a system
`CFleet::AccessCoordinateOrigin()` (`0x291e210`) = `(fleet+0x580).AccessOrigin()` → `CGalacticObject*`.
`go+0x498` = `uint32 planetIds[]`, `go+0x4a4` = count. This is exactly the
`planet=<id>` list of the galactic_object in the save, same order (`CGalacticObject::WriteMembers`
writes +0x498 with token `planet` 0x2a19).
Planet lookup (inlined `TPdxRef<CPlanet>` resolve): `db=TPdxRef<CPlanet>::_pDatabase`;
`slot = id & 0xffffff`; if `db && slot < db+0x20 && db->entries[slot].ptr && ptr->id(+0x18) == id`
→ ptr, else `TPdxNullObject<CPlanet>::_pInstance` (its `IsValid()` is false; `CPlanet::IsValid()`
`0x2a73530` returns true). So "planet valid" == "id resolves to a live planet".

### CEventScope bits used here
Size 0x170. `+0x08` scope type mask (2 planet, 4 country, 0x40 fleet, 0x80 galactic_object,
0x40000 deposit, 0x10000000000 colony), `+0x30`,`+0x38` root/from pointers, `+0x40` prev pointer
(default ctor `0x256f440` sets all three to self), `+0x68` CCrudeRandom state, `+0x169`
random_allowed (default 0). Save form: `random={ a b }`, `random_allowed=yes`.

`CCrudeRandom::Seed(u32 s)` (`0x422b0a0`): `state = CNoiseRandom{s, 0x5ea6ba9f}.GetNext()` — local, no draw.

`CRandom::GetIntegerForMacro(file,line)` (`0x3ca1ca0`) = one draw of `CRandom::_Random`
(`CNoiseRandom::GetInteger`), returned as int. All picks below are `r % n` with C signed `idiv`.

---

## 1. find_planet — CFindPlanetFleetAction

### Script keywords → data (`CFleetActionFactory::CreateAndReadData` `0x29676f0`, jump table `0x46b1728`)
| keyword | token | data created | method preset |
|---|---|---|---|
| `find_planet` | 0x3106 | CFindPlanetFleetActionData | closest (0) |
| `find_closest_planet` | 0x3104 | same (type id 0x3106) | closest (0) |
| `find_random_planet` | 0x3105 | same (type id 0x3106) | random (1) (`movb $1,0x79` at `0x2967bf1`) |

All three are saved as `find_planet={...}` with an explicit `method=`.

### CFindPlanetFleetActionData layout (size 0x80; ctor `0x296a780`)
```
+0x38 int   type 0x3106
+0x40 CPdxArray<CFleetActionData*> found_planet   (+0x48 ptr, +0x54 size)
+0x58 CPdxArray<CFleetActionData*> failed         (+0x60 ptr, +0x6c size)
+0x70 CTrigger* trigger     (null if absent)   name for save at trigger+0x88 (CString)
+0x78 bool  (out-param of ReadAndTrigger)
+0x79 u8    method: 0 = closest, 1 = random  (default 0)
```
`ReadMember` `0x296a9e0`: `trigger` 0x2ca2 → `ReadAndTrigger(reader, 2 /*planet scope*/, &+0x78)`;
`found_planet` 0x3107 → children via `CreateAndReadData(reader, 2 /*planet scope*/)` appended;
`failed` 0x30fa → children via `CreateAndReadData(reader, <outer scope type>)`;
`method` 0x3169 → `random` 0x2c9b → 1, `closest` 0x316a → 0 (other values ignored).
`WriteMembers` `0x296ad20`: `trigger="<name>"` if set, `found_planet={...}` if non-empty,
`failed={...}` if non-empty, `method=closest|random`.

### CreateInstance `0x296a940` (== ctor `0x296ae80`)
```
a = new(0x1a0)
a.done=0; a.type=0x3106; a.data(+0x10)=this
a.scope(+0x18) = CEventScope(copy of parentScope); a.scope.CopyInternalScopes(parentScope)
a.ownsData(+0x188)=0; a.child(+0x190)=null; a.index(+0x198)=-1; a.planet(+0x19c)=-1 (0xffffffff)
```
No draws. (Instance layout: +0x18 CEventScope 0x170 bytes, +0x188 bool ownsData,
+0x190 CFleetAction* current child, +0x198 int index, +0x19c TPdxRef<CPlanet> found planet.)

### Init(CFleet*) `0x296b000`
```
sys  = fleet.AccessCoordinateOrigin();  n = sys.planetCount;  ids = sys.planetIds
fpos = fleet.GetCoordinate()            // x,y
d    = this.data
found = null                            // CPlanet*
if d.trigger != null:
    if d.method == 1:                   // RANDOM + trigger      (0x296b458)
        S = CEventScope();  S.root/from(+0x30,+0x38) = this.scope.(+0x30,+0x38);  S.prev(+0x40) = &this.scope
        cand = []
        for i in 0..n-1:                // system planet order
            p = resolve(ids[i])         // may be null-object
            S.SetPlanet(p)
            ok = d.trigger.Evaluate(S)  // CTrigger::Evaluate(CEventScope&) vslot 0x10
            if ok: cand.push(p)
            if ok: break                // BUG/quirk: loop stops at first match (or i)
        if cand.size > 0:
            r = GetIntegerForMacro(file, 1060 /*0x424*/)     // DRAW, only if a match exists
            found = cand[r % cand.size]                      // size is always 1 -> cand[0]
    elif d.method == 0:                 // CLOSEST + trigger    (0x296b09f)
        pairs = [ {dist = distSq(fpos, p.coord), planet = p} for p = resolve(ids[i]), i in 0..n-1 ]
        std::stable_sort(pairs, by dist (signed int64 '<' only))   // ties keep system order
        S = as above
        for each pair in sorted order:
            S.SetPlanet(pair.planet)
            if d.trigger.Evaluate(S): found = pair.planet; break
    else: (method other) nothing
else:                                   // no trigger
    if d.method == 1:                   // RANDOM, no trigger   (0x296b774)
        if n != 0:
            r = GetIntegerForMacro(file, 1107 /*0x453*/)     // DRAW iff system has >=1 planet
            found = resolve(ids[r % n])                       // null-object if stale
    elif d.method == 0:                 // CLOSEST, no trigger  (0x296b2a1)
        if n > 0:
            best = null
            for i in 0..n-1:
                p = resolve(ids[i]); ds = distSq(fpos, p.coord)
                if best == null or ds < 0: best = p           // QUIRK: compared against 0, best
            found = best                                      //  distance never tracked
        // => effectively the FIRST planet in the system list (ds is never negative
        //    unless the int64 overflows).
this.index(+0x198) = 0                  // all paths
if found != null: this.planet(+0x19c) = found.id(+0x18)   // else stays -1
```
Trigger scope: `this` = candidate planet, `prev` = the find_planet action's scope (whose `this` is
the fleet), root/from = the action scope's root/from. Fresh scope, random_allowed=0, no seeding.
Only CScopedStartProfile wrappers appear when `g_ScriptProfiler` is on — no effect.
Init issues no orders.

Draws in Init: exactly one in `random` mode when (trigger and >=1 planet matches) or
(no trigger and system has >=1 planet); none in `closest` mode.

### Update(CFleet*) `0x296bc40`
```
p     = resolve(this.planet)
valid = p.IsValid()                     // vslot 0x20; false for null object / -1 / dead planet
list  = valid ? data.found_planet : data.failed
loop:
  if this.child != null:
      this.child.Update(fleet)          // vslot 0x48
      if !this.child.done: return       // still running
      fleet.RemoveActionToBeDeleted(this.child)   // 0x291f880
      delete this.child; this.child = null
      this.index++
      if this.index >= list.size: this.done = 1
      return                            // next child starts on the NEXT Update call
  // no child
  if this.index >= list.size: this.done = 1; return
  if resolve(this.planet).IsValid():    // found_planet branch (re-resolved)
      S = CEventScope()
      S.root/from = this.scope.(+0x30,+0x38); S.prev = &this.scope
      S.SetPlanet(resolve(this.planet))
      r = GetIntegerForMacro(file, 1155 /*0x483*/)     // DRAW: one per found_planet child created
      CCrudeRandom::Seed(&S+0x68, r)                    // seeds the child scope's crude random
      S.random_allowed(+0x169) = 1
      this.child = list[this.index].CreateInstance(S)   // child copies S
  else:                                 // failed branch: no new scope, no draw
      this.child = list[this.index].CreateInstance(this.scope)
  if this.child == null: this.done = 1; return          // e.g. orbit_planet target invalid
  this.child.Init(fleet)                // vslot 0x40
  goto loop                             // child.Update runs in the same call
```
So the child of `found_planet` runs in scope: this = found planet, prev = fleet scope,
root/from inherited, CCrudeRandom seeded from a CRandom draw, random allowed. Children of
`failed` run in the find_planet action's own scope (this = fleet).
With `found_planet={ move_to=this orbit_planet=this }` a successful find costs 2 draws
(line 1155) over the life of the action (one per child creation, regardless of whether the
child uses its scope's random). `move_to`/`orbit_planet` instances do not keep the scope, so the
seed is unused in that case.

Note: the move_to child created this way issues its order in Init and its Update is called right
away in the same tick; if it is already done, it is deleted, index++ and the action returns —
the next child is created on the next Update.

### Save / load (`WriteMembers` `0x296c190`, `ReadMember` `0x296bee0`)
```
find_planet={
    data={ trigger=".." found_planet={..} failed={..} method=closest|random }  # 0xf0, full copy of the data
    scope={ ... }            # 0x2c8d, this.scope (CEventScope persistent)
    planet=<id>              # 0x2a19, only if this.planet != 0xffffffff
    index=<int>              # 0x20c, always
    current={ <child>={..} } # 0x2ef3, only if child != null (CFleetActionFactory::CreateAndReadInstance)
    done=yes                 # 0x3103, only if done
}
```
On read, `data` allocates a new CFindPlanetFleetActionData, `CFleetActionData::Read(reader, 0)`
into it and sets `ownsData(+0x188)=1`. Init is not re-run after load.
Example (start.gamestate fleet 118): `planet=927 index=0 current={ move_to={ coordinate={...} } }`.

---

## 2. move_to — CMoveToFleetAction

### Data (CMoveToFleetActionData, size 0x1e0)
Factory (`0x2967b3e`) default target = `CEventTarget::CreateFromToken(this 0x2c91)` at data+0x40.
`ReadInternal` `0x29701a0`: the value token (`move_to = <target>`) becomes the CEventTarget at
+0x40 (token kept at +0xa8; `Write` `0x2970280` writes that token back).

### CreateInstance `0x296fb20`
```
coord = CCelestialCoordinate{ x=0, y=0 (VZERO), +0x18=0, origin=0xffffffff, b34=0, b35=0 }
if every link of data.target (CEventTarget chain via +0x188) is either flagged (+0x198 byte != 0
   or +0x194 int != 0, i.e. event targets) or its token (+0x68) is in a static scope-link whitelist
   (fleet, design, from, this, root, prev, capital_scope, owner, controller, fromfromfromfrom,
    species, colony, starbase, capital_star, federation, solar_system, ... — inlined switch):
    T = data.target.GetScope(parentScope)          // 0x257e690
    coord = T.GetSystemSpaceCoordinate()           // 0x25758c0
// otherwise coord stays zero/invalid origin
a = new(0x38): done=0, type=0x3108, +0x10 CCelestialCoordinate = coord
```
No draws. Never returns null. (The whitelist excludes e.g. `closest_system` / random_* links.)

Instance layout: `+0x10` CCelestialCoordinate (vtable, +0x18 x, +0x20 y, +0x28 qword, +0x30 origin id,
+0x34/+0x35 bytes).

### Init(CFleet*) `0x29702a0`
```
fleet.ClearOrders(0)                                     // 0x291e230: cancel current + queued
fleet.AddOrder(new CMoveToSystemPointFleetOrder(this.coord), false, false, null)   // 0x29a38b0, 0x2926b30
```

### Update(CFleet*) `0x2970300`
```
o = this.coord.GetOrigin()
if !o.IsValid(): done=1; return          // CGalacticObject::IsValid == true always -> never taken
if o == fleet.GetCoordinate().GetOrigin():          // same system (pointer compare)
    if distSq(fleet.coord, this.coord) < NDefines::NShip::MOVE_TO_ACTION_THRESHOLD:  // raw CFixedPoint
        done = 1; return                 // threshold 5.0 (00_defines.txt) compared to SQUARED distance
cur = fleet+0x2c8 (current order, no null check)
if !cur.IsValid() (always true) or cur.type(+0x18) != move_to_system_point_order (0x2ce4):
    done = 1                             // order finished/replaced -> action done
// else keep waiting
```
Done: arrived within sqrt(5)≈2.236 units in the same system, or the fleet's current order is no
longer a move_to_system_point_order. Never re-issues the order. No draws.

### Save / load (`WriteMembers` `0x2970510`, `ReadMember` `0x29704b0`)
`move_to={ coordinate={ x= y= origin= } done=yes? }` (0x2c52 coordinate; `system` 0x3091 block is
legacy and skipped).

---

## 3. orbit_planet — COrbitPlanetFleetAction

### Data (COrbitPlanetFleetActionData)
`ReadInternal` `0x2968c90`: stores file location string at +0x8; if the value is a block
(`reader+0x278 == 3`) uses generic `CFleetActionData::ReadInternal`; otherwise the value token
becomes the CEventTarget at +0x40 (token at +0xa8). `Write` `0x2968e50` writes the token.

### CreateInstance `0x29682f0`
```
if data.token(+0xa8) == random (0x2c9b):          // orbit_planet = random
    switch parentScope.type(+0x8):
      0x02 planet:   sys = planet(+0x20 sub-object).vslot0x88()   (its system)
      0x40 fleet:    c = fleet.GetCoordinate(); if !c.IsInSystemSpace(): goto bad; sys = c.GetOrigin()
      0x80 galactic_object: sys = it
      0x40000 deposit: sys = PointerFromTypeAndID(dep+0x30, dep+0x34).vslot0x88()
      0x10000000000 colony: sys = LookupCarrierRef(colony+0xf70).vslot0x88()
      0x04 country:
          L = country.CalcOwnedPlanets()          // CPdxArray<CPlanet const*>
          if L.size <= 0: return null             // no draw
          r = GetIntegerForMacro(file, 323 /*0x143*/)          // DRAW
          return new COrbitPlanetFleetAction(L[r % L.size])
      default: bad: log "Error. invalid scope for orbit_planet = random. %s" (line 0x188); return null
    if sys.planetCount == 0: return null           // no draw
    r = GetIntegerForMacro(file, 387 /*0x183*/)              // DRAW
    return new COrbitPlanetFleetAction(resolve(sys.planetIds[r % sys.planetCount]))
else:
    if target chain fails the same scope-link whitelist as move_to: return null
    T = data.target.GetScope(parentScope)
    if T.type == 2 (planet): return new COrbitPlanetFleetAction(T.GetPlanet())
    log "Error. invalid scope for orbit_planet = %s. %s" (line 0x195); return null
```
A null return makes the parent find_planet finish immediately (`done=1`).

### Instance (size 0x28; ctor `0x2968e70`)
```
+0x10 CRefObjectOrbitableRef<CFleetOrbitableEnumType>:
      +0x10 u32 id = planet.id(+0x18), +0x14 u8 kind = 1 (planet),
      +0x18 bool hasExtra = 0, +0x20 u64 extra (unused here)
```

### Init(CFleet*) `0x2968f30`
```
fleet.ClearOrders(0)
fleet.AddOrder(new COrbitPlanetFleetOrder(this.ref, EMergeOption 0), false, false, null)  // 0x29a3e70
```
(The order shows in saves as `orbit_planet_order={ orbitable={planet=..} star=.. sub_order={
move_to_system_point_order=...} }`.)

### Update(CFleet*) `0x2968ea0`
```
t = fleet.GetOrbitTarget()     // fleet+0x670 id, +0x674 kind, +0x678 hasExtra, +0x680 extra
if t.id == this.id and t.kind == this.kind and
   ((t.hasExtra and this.hasExtra and t.extra == this.extra) or (!t.hasExtra and !this.hasExtra)):
    done = 1; return                                   // fleet is orbiting the planet
cur = fleet+0x2c8
if cur.IsValid() (always) and cur.type(+0x18) == orbit_planet_order (0x2ce5): return   // wait
this.Init(fleet)              // RE-ISSUES ClearOrders + new COrbitPlanetFleetOrder every such tick
```
Done only when the fleet's orbit target equals the planet. No draws in Init/Update.

### Save / load (`WriteMembers` `0x2969080`, `ReadMember` `0x2968fc0`)
`orbit_planet={ orbitable={ planet=<id> } done=yes? }` via
`CFleetOrbitableRefSerializer` (key `orbitable` 0x3dc2). Legacy top-level `planet=<id>` (0x2a19) is
also accepted.

---

## 4. Draw summary (all `CRandom::GetIntegerForMacro`, file fleet_actions.cpp)
| where | line | condition | use |
|---|---|---|---|
| FindPlanet::Init `0x296b75c` | 1060 | method=random, trigger set, ≥1 planet passes (loop stops at the first pass) | `idx = r % 1` (always first match) |
| FindPlanet::Init `0x296b787` | 1107 | method=random, no trigger, system planet count > 0 | `planetIds[r % n]` |
| FindPlanet::Update `0x296bddb` | 1155 | each time a `found_planet` child is created (planet valid, index < size, no current child) | `CCrudeRandom::Seed(childScope+0x68, r)` |
| OrbitPlanetData::CreateInstance `0x2968aac` | 323 | `orbit_planet=random` in country scope, owned planets > 0 | `ownedPlanets[r % size]` |
| OrbitPlanetData::CreateInstance `0x2968b62` | 387 | `orbit_planet=random` in planet/fleet(in system)/system/deposit/colony scope, system planets > 0 | `planetIds[r % n]` |
MoveTo (CreateInstance/Init/Update), Orbit Init/Update, FindPlanet CreateInstance: no draws.
Order constructors used (`CMoveToSystemPointFleetOrder`, `COrbitPlanetFleetOrder`) and
`CFleet::AddOrder` contain no direct GetIntegerForMacro call.
