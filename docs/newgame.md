# A new game (4.5.2)

How the game makes a new game, from the galaxy setup screen to the first day, and the Lua that does
it for the engine (`sim/lua/engine/newgame/`, `sim/examples/newgame.rs`), so that a game can start
without a save.

Reverse engineered statically from the GOG 4.5.2 build and its PDB on hippo (`/root/fnm_tmp`:
`annotate.py`, `pdbtype.py`, `names452.tsv`, `full452.asm`). Addresses are GOG RVAs. **[V]** marks
what was seen in the disassembly (the address is given), **[I]** what is inferred (from names, the
script files or the saves). Nothing was measured at runtime.

Sections 1-6 are the game, section 7 the Lua, section 8 the checks against the game's saves, section
9 what differs and what is left.

## 1. The path

| step | function | what |
|---|---|---|
| setup screen | `CFrontEndIdler::LaunchNewGame` | a lambda calls `CGameState::GenerateNewGalaxy` **[V]** (its only caller) |
| 1 | `CGameState::GenerateNewGalaxy` (`0x263b00`) | allows random draws off the main thread (`CRandom::_MultithreadAllowed = 1`), derives the galaxy seed from the global stream, pushes the load screen state, calls `CGalaxyGenerator::Generate` (`0x263c02`), then (achievements, the save folder name, hot-join and modifier dumps) `CGameState::InitPostGalaxyCreation` (`0x26426f`) **[V]** |
| 2 | `CGalaxyGenerator::Generate` (`0x98bd50`) | `CRandomNameDatabase::FillDatabase` (the random name lists, `random_name_database` in the save), the generator's own random stream (section 2), then `GenerateFromStaticScenario` (`0x98d130`) when the template is static (`+344 == 1`) or `GenerateFromRandomScenario` (`0x98bfe0`) when it is random (`+344 == 0`) **[V]** |
| 3 | `CGalaxyGenerator::GenerateFromRandomScenario` (`0x98bfe0`) | the whole galaxy, in the order of section 3 |
| 4 | `CGameState::InitPostGalaxyCreation` (`0x264340`) | the game's state after creation (section 6) |
| 5 | `CGameState::OnNewGameStarted` (`0x272000`) | the first-day script: on_actions (section 6) |

## 2. Seeding **[V]**

The galaxy generator does not draw from the game's global generator (`CRandom::_Random`, the
platform's `RUST.rand`): it gets a stream of its own, a local `CNoiseRandom { uint32 position (+0);
uint32 seed (+4) }` passed by pointer to every step.

`GenerateNewGalaxy` (`0x263b47`-`0x263bf1`):

```
v    = CRandom::GetIntegerForMacro()                  -- one draw of the global stream
h    = noise32(position = v, seed = 0x5EA6BA9F)       -- 1587985055; all 32 bits (no btr)
seed = noise32(position = h, seed = 0) & 0x7FFFFFFF   -- a local CNoiseRandom {h, 0}, one draw
CGalaxyGenerator::Generate(config, template, seed)
```

`Generate` (`0x98be5f`): when the seed it is given is negative (`js 0x98bea6`) it draws one from the
global stream (`0x98beb2`) instead; then

```
generator = CNoiseRandom { position = noise32(position = seed, seed = 0x5EA6BA9F), seed = 0 }
```

`noise32` is the game's noise function (docs/simulation.md, section 3; `sim/src/rng.rs`):
`x = seed + position * 0xB5297A4D; x ^= x >> 8; x += 0x68E31DA4; x ^= x << 8; x *= 0x1B56C4E9;
x ^= x >> 8; x *= 0x92D68CA2; x ^= x >> 8`. Every draw of the generator is inlined in the
generator's functions (grep `1759714724`, `0x68E31DA4`): the value is `noise32(position, seed) &
0x7FFFFFFF` and the position goes up by one. A value in `[0, n)` is the remainder of a signed
division (`cdq; idiv`). `CNoiseRandom::GetInt64` (`0x1b50900`) and `GetFixedPoint` (`0x1b509b0`) are
the two draws not inlined.

Two streams take part:

- **G**, the generator's stream: the stars, the nebulas' places, the empires' placement, the
  partitions, the resource clusters, the initializer picks and their spawn rolls, the planet class
  picks, the neighbour searches, the home planet picks;
- **C**, the global stream (`CRandom::_Random`): the galaxy seed itself, the nebula and star names,
  the hyperlane thinning (two draws seed sub-streams), and in system initialization the planet
  counts, orbits, sizes, angles, rings, star classes (a C draw seeds a local stream that picks),
  asteroid belts, planet modifiers and deposits; the species and the empire setup
  (`InitEmpireShared` 6 call sites, `InitEmpireSystems` 2), the scopes of every script effect, and
  `OnNewGameStarted` (3).

So the star map (positions, nebulas, partitions, home systems) is a pure function of the galaxy seed
and the settings, while the lanes and the systems' contents also depend on C's state when the
generation starts. In a new game C is `{ position 0, seed = g_nGameDebugRandom (-random=) if >= 0,
else the low dword of QueryPerformanceCounter }` when the main menu opens
(`CFrontEndIdler::SetAsCurrentIdler` `0x8bb348`). Every draw the menus make before the generation
moves it: editing an empire design in the setup (`CGameSetupView::EditEmpireDesign` draws, then
re-rolls the flag) and the empire designer's randomize functions do. When the setup moves on,
`CGameSetup::StartSyncPlayers` (`0xb28117`, single player and multiplayer) posts
`CSetRandomSeed(g_nGameDebugRandom if >= 0 else _nSeed, _nRandomCount)`, which
`CSetRandomSeed::Execute` (`0xa94600`) sets on every player. `CGameState::InitPostRead` applies
`-rng_seed=` / `-rng_pos=` to loaded game states only. An event scope's seed is `noise32(r,
0x5EA6BA9F)` for a draw r of C.

Value draws (both streams):

- `CStatInterval<int>` (`x` read as `{x, 0}`, `{min max}` as `{min, max - min}`): the caller always
  draws r; the value is `min + (r % (|delta| + 1)) * sign(delta)` (`0xa09770`);
- `CStatInterval<CFixedPoint>::GetRandom` (`0xa09430`): `k = r % 1000`, `min + trunc(k * 100 *
  delta / 100000)` (raw): steps of a thousandth of the interval; r is drawn even when delta is 0;
- weighted picks: `GetWeightedRandomInternal` (`0x1b4ad80`): `t = r % total` (over 2^31 - 1:
  `floor(floor(total * 1000 / (2^31 - 1)) * r / 1000)`), the first with cumulative weight > t;
  `PickRandomClassFromArray` (`0x4a7a90`) and `GetRandomClassForOrbit`: `t -= w` until `t <= 0`.

In Lua: `engine/newgame/rng.lua` (`rng.stream(seed)`, `rng.seed_from_global(v)`, `rng.global()` over
`RUST.rand`), checked against the reference values of `sim/src/rng.rs`.

## 3. `GenerateFromRandomScenario` (`0x98bfe0`), in order **[V]** (the calls)

| at | call | what |
|---|---|---|
| `0x98c0d8`-`0x98c2b8` | (inline) | the settings copied from the configuration and the template |
| `0x98c2c8`-`0x98c44f` | `CountHumanEmpiresToSpawn` and draws | with `random_empires` (config `+116`) the number of AI empires is drawn: `n/2 + draw % (n - n/2 + 1)`; likewise the fallen (`+117`, capped) and marauder (`+120`) counts. Without the random setting no draw is made |
| `0x98c482`-`0x98c575` | `CNoiseRandom::GetInt64` | when the template has clusters (`+168 > 0`): a draw scaled by 314200 (pi in fixed point): an angle |
| `0x98c806` | `SGalaxyGenerationMetaData::SGalaxyGenerationMetaData` | the generation's working data (assigned systems, home planets, species classes, species, start clusters, designs, the initializer use counter, distances) |
| `0x98c822` | `GenerateStars` (`0x974860`) | the stars (section 4) |
| `0x98c82f` | `GenerateNebula` (`0x9762f0`) | nebulas |
| `0x98c837` | `CGameState::GenerateGalacticMap` (`0x26d5d0`) | |
| `0x98c845` | `CreateEmpireStartClusters` (`0x97f2c0`) | the start clusters (`clusters` in the save) |
| `0x98c85d` | `PlaceEmpires` (`0x9805e0`) | the empires' home systems |
| `0x98c943` | `PartitionGalaxyForEmpires` (`0x980e90`) | |
| `0x98c9f7`-`0x98cae2` | `CGalacticObjectCluster`, `CGameState::FindCluster` | |
| `0x98caf1` | `CalcDesignsForEmpires` (`0x988900`) | the empire designs (prescripted, the player's) |
| `0x98cafd` | `GenerateEmpireSpeciesClasses` (`0x981470`) | |
| `0x98cb18` | `RandomizeEmpireGovernments` (`0x988a10`) | |
| `0x98cb24` | `GenerateEmpireSpecies` (`0x9816e0`) | |
| `0x98cb2c` | `CreateResouceClusters` (`0x97fdd0`) | |
| `0x98cb48` | `GenerateHyperlanes` (`0x97a7e0`) | |
| `0x98cb5e` | `InitEmpireSystems` (`0x984eb0`) | |
| `0x98cb8a` | `GenerateSingleEmpire` (`0x97a210`) | once per empire |
| `0x98cbc2` | `CGameState::UpdateDatabaseArrays` | |
| `0x98cbef` | `GenerateFallenEmpires` (`0x985ce0`) | |
| `0x98cbf4` | `AssignBaseSpecies` (`0x98b9d0`) | |
| `0x98cc0b` | `InitializeUninitializedSystems` (`0x97e5c0`) | every system no empire initialized |
| `0x98cc13` | `CGameState::GenerateGalacticMap` | again, with the final lanes |
| `0x98cc1d` | `ConnectDividedEmpirePartitions` (`0x97ab30`) | |
| `0x98cc2a` | `AssignAdvancedStatusToEmpires` (`0x9840c0`) | |
| `0x98cc2f` | `ConnectEmpireSystems` (`0x97ac00`) | |
| `0x98cc34` | `ProcessNeighbourContact` (`0x97a640`) | |
| `0x98cc43` | `GeneratePrecursorCivilizations` (`0x97b630`) | |
| `0x98cc4b` | `GenerateResourceRegions` (`0x97c0b0`) | |
| `0x98cd13` | `CreateCosmicStormPartionClusters` (`0x97f980`) | |

The generator's functions are free functions at `0x974000`-`0x98d600` (`names452.tsv`).

## 4. The inputs

- `map/setup_scenarios/*.txt`, `setup_scenario = { name num_stars radius num_empires ... }`:
  `CGalaxyTemplate` / `CRandomGalaxyTemplate` (`ReadMember` `0x510510`, `0x510fa0`). Fields:
  `_HomeSystems` and `_OpenSystems` (`CGalaxyPartitionerSettings`: home_system_partitions,
  open_space_partitions) `+0x40`, `+0x54`; `_NumEmpires` `+0x68`; the empire counts `+0x70`-`+0x104`;
  `_vNumWormholePairs` `+0x108`, `_vNumGateways` `+0x120`, `_vNumHyperlanes` `+0x138` (default
  `+0x148`), `_vMaxHyperlaneDistance` `+0x150`, `_SupportedShapes` `+0x160`; random templates add
  `_nNumStars` `+0x178`, `_vRadius` `+0x180`, `_nNumNebulas` `+0x188`, `_vNebulaSize` `+0x190`,
  `_vNebulaMinDistBetween` `+0x198`, `_ClusterSetup` `+0x1a0`.
- `map/galaxy/galaxy_shapes.txt`: `CGalaxyShape` (`ReadMember` `0x5138c0`): `_NumStarsCorePerc`
  `+0x48`, `_CoreRadiusPerc` `+0x50`, `_StarsMinDist` `+0x58`, `_Countries` `+0x60` (ideal and min
  squared distance between empires), `_FallenEmpires` `+0x68`, `_Arms` `+0x78`, `_Ring` `+0x98`,
  `_NumArms` `+0xa8`, `_HasRing` `+0xac`.
- `common/solar_system_initializers`, `common/star_classes` (+ `randomizers`),
  `common/planet_classes` (with its `random_list`s), `common/random_names/base` (star, nebula and
  asteroid names), `common/scripted_variables` (numbers written as `@variables`).
- The setup (`CGalaxyConfiguration`, written as `galaxy = { }` in the save).

## 5. The galaxy

### 5.0 Fixed point and draws **[V]**

Everything in star placement is `CFixedPoint` (int64, 1.0 = 100000):

- `fixmul(a, b) = trunc(a * b / 100000)` toward zero (when |a| or |b| > 3037000499 the game splits
  the larger operand into its integer and fraction parts: the same value);
- `fixdiv(a, b) = trunc(a * 100000 / b)` (`0x974df7`);
- `fixed_int64::sin` (`0x1b43e30`): `t = a mod 628319` made non-negative; `t > 314159`: `t -= 314159`
  and the result negated; `t > 157080`: `t = 314160 - t`; then `_sinx` (`0x1b43c60`), three
  Taylor terms `x - x^3/6 + x^5/120`, each `trunc(p / fact)`, `p = fixmul(x, fixmul(x, p))`.
  `cos(a) = sin(a + 157080)` (`0x1b43ee0`). The spiral branch of GenerateStars inlines the same;
- `draw31()`: one position of the generator's stream, `noise & 0x7FFFFFFF`; `% n` for a range;
- `u()`: `CNoiseRandom::GetInt64` (`0x1b50900`): `hi = draw31` (position p), `lo` = all 32 bits of
  position p+1, `(hi << 32) | lo`, reduced `% 100000`: a fraction in [0, 1) using two positions.
  `GetFixedPoint(lo, hi)` (`0x1b509b0`) is `lo + GetInt64() % (hi - lo + 1)` (not used for stars).
- distances: `CCelestialDistance::IsLessThan` (`0x996550`) on a difference (dx, dy) and a distance
  m: when |dx| and |dy| are both under 1.0 ("near") they are scaled by 100 and compared with
  `(100 m)^2` if m < 10, and are always closer if m >= 10; otherwise closer is
  `fixmul(dx,dx) + fixmul(dy,dy) < fixmul(m,m)`.

`engine/newgame/fixed.lua` implements these exactly (doubles hold every product of game
creation's magnitudes exactly).

### 5.1 The parameters and the draws before the stars **[V]**

`GenerateFromRandomScenario` fills a `SGalaxyGenerationParameters` (216 bytes) for `GenerateStars`
and `GenerateNebula`:

| field | value | at |
|---|---|---|
| stars | `num_stars` | `0x98c0e1` |
| core stars | `trunc(num_stars * num_stars_core_perc)` (0 in every vanilla shape) | `0x98c0f0` |
| disk stars | stars - core stars | `0x98c117` |
| core radius | `fixmul(radius, core_radius_perc)`, also written to the configuration (`galaxy = { core_radius }`) | `0x98c11f`, `0x98c7e5` |
| disk radius | radius - core radius | `0x98c1b6` |
| min distance | `stars_min_dist` | `0x98c1d0` |
| countries' ideal / min squared distance | the shape's `countries` | `0x98c1d8` |
| nebulas, radius, min distance | `num_nebulas`, `trunc(nebula_size / 2)`, `nebula_min_dist` | `0x98c1e4`-`0x98c2b1` |
| countries to spawn | `max(count, humans)`, `count` = AI empires + humans (`CountHumanEmpiresToSpawn` 0x974770, no draws) | `0x98c7ec` |

The draws, in order, all `draw31() % (range + 1)` with `n/2` truncated:

1. AI empires, only with `random_empires`: `n/2 + draw % (n - n/2 + 1)`;
2. advanced empires, only with the random setting: `A/2 + draw % (A - A/2 + 1)`;
3. fallen empires, likewise;
4. for shapes with arms only: the arms' rotation `2 * trunc(u() * 314200 / 100000)` (2 pi with
   pi = 3.142); `tightness_winding`, `width`, `fuzz`, `seperation` copied;
5. a ring (no draw): ring width and offset = `fixmul(radius, ring.width / offset)`;
6. marauders, nomads: like 1, written back to the configuration.

### 5.2 Stars: `GenerateStars` (`0x974860`) **[V]**

It makes `num_stars - countries to spawn` stars (medium with 9 AI empires: 590). Each attempt,
with `i` the stars made so far:

1. the distance from the centre: with a ring `fixmul(u, ring width) + ring offset + core radius`;
   else for disk stars `core radius + fixmul(u, disk radius)`; else `fixmul(u, core radius)`.
   Linear in u: the density falls as 1/r, which the real saves show (as many systems at 100-125 as
   at 375-400);
2. the angle. Without arms (elliptical, ring): `deg = u * 360`,
   `rad = fixdiv(fixmul(deg, 314159), 18000000)`. With arms (spiral_2/3/4/6, bar, starburst,
   cartwheel, spoked): `wind = fixmul(fixmul(fixdiv(R, disk radius), tightness), disk radius)`,
   `w = fixmul(u, width)`, `arm = draw31 % num_arms`, `f = 2 * fixmul(u, fuzz) - fuzz`,
   `rad = fixdiv(fixmul(w + wind + arm * seperation + f, 314159), 18000000) + rotation`;
3. `x = fixmul(cos(rad), R)`, `y = fixmul(sin(rad), R)`;
4. rejected when closer than `stars_min_dist` (5.0) to any star made so far, in order (4
   positions of the stream per attempt without arms, 7 with); 10,000 tries per star, after which
   the game logs "Galaxy generation failed to create enough systems" and stops making stars;
5. accepted: `CGameState::CreateNewStar` (no draws), the coordinate clamped to [-500, 500],
   `origin = -1`; with arms, `CGalacticObject._nArm` = the arm.

The visual height (`visual_height=3.65056` on every system and nebula) is
`GetRandomizedHeightForCoordinate` (`0xf10980`) of the coordinate (0, 0), computed by the
constructor before the coordinate is set: `k = (int)(x*10000 + y*10)`, `h1 = noise32(k,
0x5EA6BA9F)`, `h = (noise32(h1, 0) & 0x7FFFFFFF) / 2^31 * 40 - 20`.

Then one relaxation (`GALAXY_GENERATION_RELAX_ITERATIONS = 1`):

- the points: each star at `trunc(x * 100)` (0.01 units, as floats), and
  `GALAXY_GENERATION_CENTER_DUMMY_POINTS = 256` points on a circle at 0.9 x the core radius
  (angle `k * 2454` raw, `(cos, sin) * core radius * 0.9 * 100`, each a fixmul);
- `triangulate("pczAevnQ")` (`0x1b7da40`, Shewchuk's Triangle with float coordinates): the Delaunay
  triangulation and its Voronoi diagram;
- `CPdxTriangulate::RelaxPoints(-50000, 50000, -50000, 50000)` (`0x1b46440`), one Jacobi Lloyd
  step: every point whose Voronoi cell is closed (not on the hull) and inside the bounds moves to
  the cell's centroid (`CPdxTriangulate::Centroid` `0x1b50a10`, a fan from the first vertex);
- each star: `x = trunc(px) / 100`. Coordinates are on a 0.01 grid, as the save writes them.

### 5.3 Nebulas: `GenerateNebula` (`0x9762f0`) **[V]**

```
tries = 10000
while nebulas < num_nebulas:
    s = systems[draw31 % #systems]                       -- one position per attempt
    ok = s is not closer than nebula_min_dist to any nebula so far
    if tries < 1: stop
    if ok:
        name = CRandomNameDatabase::TakeNebulaName       -- 0x907760: a draw of the GLOBAL stream
                                                          -- % names left, swap-removed
        nebula at s (clamped), radius trunc(nebula_size / 2), height as above
        AssignGalacticObjectsToNebula(nebula)            -- 0x977ca0
        tries = 10000
    else: tries -= 1
```

`NGalaxyGenerator::AssignGalacticObjectsToNebula` (no draws): every system not in a nebula yet
and closer than the radius (the "near" threshold here is 0.1, not 1.0) joins it, in system order:
the save's `nebula = { galactic_object = ... }`. The save's nebula centres are system positions
(-98.44, -321.45 and 35.53, 233.35 both are). Nebulas of radius 25 come from elsewhere (scripted).

### 5.4 `CGameState::GenerateGalacticMap` (`0x26d5d0`) **[V]**

No draws. Called after the nebulas and again after the systems are initialized:

1. a Delaunay/Voronoi of every system at whole units (`trunc(x)`), 64 points on a circle at
   `1.414 x` the farthest system's distance and, with a core, 64 at `0.5 x` the nearest's (angles
   `k * 628400 / 64`, points `(R cos, -R sin)`);
2. every finite Voronoi edge between two systems: `CGraphicalMap::AddBorderEdge` (the map's
   borders, graphics only);
3. every Delaunay edge between two systems whose midpoint lies between the nearest and the farthest
   system's distance (edges across the empty core are dropped) is a neighbour pair:
   `CGalacticObject._GalacticNeighbors` (`+0x10f0`), both ways, in Triangle's edge order. Read by
   `PartitionGalaxyForEmpires`, `AddRandomNeighborSystemsToPartition` and the
   `neighbor_system_euclidean` script lists;
4. `galaxy_radius` = the farthest system's distance (`SafeSqrt` of the largest `fixmul |p|^2`): the
   save's `galaxy_radius=437.9122` is its farthest system, at 437.912.

### 5.5 Start clusters and the empires' home systems **[V]**

`CreateEmpireStartClusters` (`0x97f2c0`, no draws). With N the countries to spawn: with
`cluster_count = { method = one_every_x_empire value max }` there are `(N - 1 + value) / value`
clusters (`constant`: value), at most `max` (unless -1), at least one. Cluster i is centred at
`(fixmul(d, cos a), fixmul(d, -sin a))`, `a = i * fixdiv(628400, n)` (2 pi = 6.284), d =
`cluster_distance_from_core`, named `start_cluster_<i>`, made with `CGalacticObjectCluster::
CreateCircle(cluster_radius)`: the systems with `|p - c|^2 < r^2`. The six clusters of the medium
save match this exactly (251.1325, 0; 124.9725, -216.5925; ...). A union cluster `start_cluster` of
them all is added after the partitions (`0x98c9f7`).

`PlaceEmpires` (`0x9805e0`), clustered (the setting `clustered = yes` and `player_locations` not
random): cluster c (0-based) gets `(N + c) / clusters` empires. Each goes to the first system of the
cluster (in id order) that minimises `|ideal_sq_dist_between - d|` over the systems with d < 0 (no
empire of this cluster yet) or `d >= min_sq_dist_between`, d being the squared distance to the
nearest empire already placed in the cluster; if none qualifies, the first free system. No draws:
the first empire of each cluster is on the cluster's first system. Then `ShuffleArray`
(`0x98e0e0`) shuffles the homes twice with the generator's stream: forward (`j = i + draw % (n -
i)`) and backward (`j = draw % (i + 1)`), 2 (n - 1) draws. The homes of the medium save (systems 1,
8, 7, 2 and 242, 20 and 541, 6 and 401) are exactly these. Random placement: for each empire up to
1000 draws `s = draw % systems`, refused when taken or within `RANDOM_START_DISTANCE` (75) of a
home; no shuffle.

`ReorderPlayerLocations` (`0x984960`, from `InitEmpireSystems`): `normal`: each human's slot is
swapped with `draw % N`; `clustered`: a random start cluster's slots go to the humans; `close`:
sorted by distance to the first.

### 5.6 Partitions: `PartitionGalaxyForEmpires` (`0x980e90`) **[V]**

The systems are cut into partitions, which decide which hyperlanes are "islands" (inside a
partition) and which "bridges" (between two). Squared distances against
`max_hyperlane_distance^2`.

- Home partitions (`home_system_partitions`) are seeded by the home systems in their shuffled
  order; open ones (`open_space_partitions`) by every system not in one yet, in id order.
- A new partition: `desired = min_systems + draw % (max_systems - min_systems)` (max excluded),
  `bridges = min_bridges + draw % (round(max_bridges * num_hyperlanes) - min_bridges + 1)`; its arm
  is the seed's.
- `depth_first`: at once `AddRandomNeighborSystemsToPartition(seed, desired)`. `breadth_first`: all
  seeds first, then over the active list from last to first, one system at a time to each, a
  partition leaving the list when full or stuck.
- `AddRandomNeighborSystemsToPartition` (`0xa35270`): the candidates are the system's neighbours
  (`_GalacticNeighbors`, 5.4) in no partition or in this one, not visited, of the same arm and
  within the distance; `k = draw % m`, the candidate joins (if it is not in already), is swapped to
  the end, m decreases, until enough joined or m = 0; then the search goes on through the
  candidates round-robin (each marked visited, a recursive call for one system; a candidate that
  gives none is dropped).
- `MergeNeighborPartitions` (`0xa35c00`): a partition filled to 60% or less of `desired` joins the
  neighbour partition minimising `sqrt(min distance^2) + (Q.count + P.count) / Q.desired` (+1000 for
  another arm); the merged keeps the larger desired bridges.

### 5.7 Hyperlanes: `GenerateHyperlanes` (`0x97a7e0` -> `0x8854a0`) **[V]**

The medium save confirms it: all 844 lanes of generation (systems 0-589) are edges of the Delaunay
triangulation of the systems' truncated coordinates, after the core filter; 48.7% of those edges are
kept; island lanes are listed longest first, then the bridges.

1. The systems (pirate star classes left out), at `(trunc(x), trunc(y))` as floats; Triangle
   `"pczAevnQ"`. Each edge whose midpoint is not strictly between the nearest and the farthest
   system's squared distance is dropped (the empty core). `length = trunc(isqrt(dx^2 + dy^2))`
   (the save's `length`, an integer: the distance rounded down). An edge inside one partition is an
   island; between two, a bridge (both partitions count it).
2. `ReduceHyperlaneIslandEdges` (`0x884480`): islands sorted longest first (stable, by length,
   then the two ends: `SHyperlaneEdgeComp` `0x886ff0`); `remove = trunc(edges * 0.15 / density)`
   (`HYPERLANE_GEN_REMOVE_PERC`); those longer than `max_hyperlane_distance` go first; a sub-stream
   seeded by one draw g of the **global** stream (`CNoiseRandom { noise32(g, 0x5EA6BA9F), 0 }`)
   removes random others (`j = draw % candidates`, swap-removed) up to `remove`; then, when the
   density is under the setting's maximum, `RemoveIfExceedsEdgeLimit` (`0x886620`): an edge whose
   two ends both have `limit` lanes goes, `limit = density > 1 ? round(4 * density) : 4`
   (`HYPERLANE_GEN_REMOVE_TOO_MANY_EDGES`).
3. `ReAddRemovedEdgeIfNeeded` (`0x8867d0`), the removed edges shortest first: a label-correcting
   search (FIFO) from one end, weighted by length, stopped when the other end is reached; the edge
   comes back if the ends are no longer connected, or if it is not longer than the maximum and the
   way found takes more than 20 jumps (`HYPERLANE_GEN_REMOVED_MAX_DIST`).
4. The islands are added both ways (`CHyperlane { to, length }`).
5. `ReduceHyperlaneBridgeEdges` (`0x884a00`): bridges sorted, another global draw seeds another
   sub-stream; in a random order (one draw per bridge) a bridge goes when both its partitions have
   more bridges than they want (and the density is under the maximum) or it is too long; the edge
   limit, the re-adding (over bridges and islands), then the bridges are added with `bridge=yes`.

| num_hyperlanes | islands removed at random | edge limit |
|---|---|---|
| 0.5 | 30% | 4 |
| 1 | 15% | 4 |
| 1.5 | 10% | 6 |
| 2 | 7.5% | 8 |
| 3 (the maximum) | 5% | none; no bridge thinning |

After the systems are initialized: `ConnectDividedEmpirePartitions` (`0xa36000`) adds back the
cheapest removed bridge or island where an empire's systems lie in partitions the thinning
separated (cost: the length, x10 when the ends are not one owner's), and `ConnectEmpireSystems`
(`0x977680`) gives every system with planets on the path between two of an empire's systems a
starbase (an A* along the lanes). Neither draws. `AddAndRemoveSpecificHyperlanes` (`0x98b610`) is
for static galaxies only.

### 5.8 Clusters, regions, wormholes, gateways

- `CreateResouceClusters` (`0x97fdd0`, `RESOURCE_CLUSTER_COUNT` = 6): the order 0..5 shuffled
  forward (6 draws), an offset `fixmul(628400, u())`, six pie slices from the offset
  (`CreatePieSlice`: `CFixedPoint::Atan2 - 1.571` within the slice): `resource_cluster_<k>`, which
  initializers test (`is_in_cluster = resource_cluster_3`).
- `GenerateResourceRegions` (`0x97c0b0`, after the systems): slots `[0,0,0,0,1,1,1,2,2,3]`
  shuffled twice (18 draws); the Delaunay edges of `GenerateEdgesFromGalacticObjects` (`0x97adf0`)
  walked in chunks, each endpoint flagged `resource_region_*` up to a cap (the save: 236 / 177 /
  118 / 59 systems).
- `CreateCosmicStormPartionClusters` (`0x97f980`): 32 slices x 2 rings, no draws, not saved.
- **Natural wormholes are script**: event `game_start.31` of `on_game_start` makes
  `trunc(num_wormhole_pairs * 5)` pairs, each a `random_system` (not a starting system, not in an
  empire cluster, no wormhole) and another 500 or more along the hyperlanes from it,
  `spawn_natural_wormhole` in both and `link_wormholes`.
- **Gateways are script**: the initializer `abandoned_gateways_01` (a `gateway_ruined` megastructure,
  its bypass made inactive in `CMegaStructure::Initialize`), with
  `scaled_spawn_settings = num_gateways`.

## 6. Systems and empires

### 6.1 The initializers' data **[V]**

`CSystemInitializerDataBase` keeps one list per `usage`: `empire_init` (`+0x70`),
`fallen_empire_init` (`+0xc0`), `misc_system_init` (`+0x110`), `custom_empire` (`+0x160`), `origin`
(`+0x1b0`), `nomad_init` (`+0x200`). A `CSystemInitializer`: `usage_odds` (an MTTH with modifiers on
the system), `primitive_system` (`+0x48`), `prevent_anomalies` (`+0x49`), `max_instances` (`+0x4c`,
-1), the system (`CPrescriptedSystem` `+0x50`), `neighbor_system`s (`+0x370`),
`mandatory_neighbors` (`+0x388`), `spawn_chance` (`+0x3c0`, 100), `scaled_spawn_chance` (`+0x3c4`,
-1), `scaled_spawn_settings` (`+0x3c8`). `change_orbit = X` is read as a planet of class `none` with
`orbit_distance = X` (`0x507853`); inside a planet it is a sub-planet. A `CPrescriptedPlanet`'s
defaults (`0x505520`): `class = random`, `count = 1`, `size` -1 (the class's), `orbit_distance = {
10 20 }`, `orbit_angle = { 90 270 }`.

### 6.2 `InitializeUninitializedSystems` (`0x97e5c0`) **[V]**

Every system not initialized yet, in id order:

1. `GetRandomFromList` (`0x50a830`) over `misc_system_init`: the initializers not at their most uses,
   weighted by `usage_odds` (a primitive system's x the primitive setting), weights >= 0 kept; one
   G draw x, `GetWeightedRandomInternal(x)` (all weights 0: `x % count`);
2. a G draw `% 100` against `GetSpawnChance` (`0x5089b0`): `spawn_chance`, or
   `round(scaled_spawn_chance * systems / 100)`, times the setting `scaled_spawn_settings` names
   (`num_gateways`), rounded. A pick that fails still counts as a use (`RegisterUse`), and the
   system picks again. `HasReachedMaxUses` (`0x50b450`): uses >= `round(max_instances * setting)`.
   The save's `system_initializer_counter` lists the uses in the order of their first use (the
   2210 save has one never used, rejected between systems 4 and 5);
3. `GetClass` once as a check (a C draw for a random class);
4. `InitializeWholeTree` (`0x97e200`): a C draw seeds the tree's script scope; the system is queued
   and `InitializeQueue` runs.

`InitializeQueue` (`0x97ded0`): the queued systems are initialized, then each yields at most one
neighbour per round (`MakeNeighborInitState` `0x97d380`, round-robin) until none does; the
neighbours are the next layer. `MakeNeighborInitState`, per `neighbor_system` entry: a G draw `%
100` against its `spawn_chance` (passes on `<=`); the candidates by squared distance (stable),
within `distance` (default 0-1000), `min/max_orientation_angle` (degrees x 3.142 / 180, the angle
`Atan2(-dy, -dx)`), `hyperlane_distance` and `hyperlane_jumps`, not queued, not initialized, not
owned; a non-empty `trigger` costs a G draw (the scope) per candidate; the first that passes gets
the `initializer`. None and `mandatory_neighbors`: `CreateSystemForNeighbor` (`0x97c7c0`) makes a
system (a star class picked by G, a name by C, 15 tries of 3 G draws for its distance and angle)
joined by a hyperlane. The neighbour keeps its parent's context (an empire's ideal class) and scope.

### 6.3 One system: `CGalacticObject::InitializeSystem` (`0x870250`) **[V]**

```
register the use; initializer = tag
star_class = GetClass(class)        -- a name: no draw; random or a randomizer: r = C(),
                                    -- local {noise32(r, 0x5EA6BA9F), 0} picks by spawn_odds
name = name, or TakeStarName (C)    -- TakeBlackHoleName for black holes
each asteroid_belt: inner_radius = GetRandom(radius, C())
flags
cum = 0, angle = 0, d = 0, star = star_class
for each planet entry (change_orbit = an entry of class none):
    n = count (C)
    repeat n:
        d, star = distance to the nearest star made so far, its class (none yet: 0, the system's)
        class = CalcPlanetClass(entry, G, d, star)      -- at cum BEFORE this planet's orbit
        cum += GetRandom(orbit_distance, C())
        no class: next
        a star: (cum, its class) recorded; d = 0
        size = size or the class's planet_size (C)
        create the planet; RandomizePlanetModifiers (C until none is picked)
        angle += GetRandom(orbit_angle, C())
        InitializePlanet: coordinate x = fixmul(-cos a, cum), y = fixmul(-sin a, cum) with
            a = angle * 3.142 / 180 (around the parent for moons); orbit = cum;
            deposits (RandomizeDeposits, C); anomaly; ring: has_ring if given, else (not a moon)
            chance_of_ring > C() % 100000; flags; the planet's init_effect (C, C: its scope)
        moons (InitializeSubPlanets 0x86fb50): the same from cum = 0 around the planet, the class
            distance |planet's d - moon cum|, sizes from moon_size
        extent = max(extent, cum + the moons' extent)
orbital lines: a C draw each
inner_radius = max(extent + 30, 150); outer_radius = inner_radius + 100
the system's init_effect (its scope)
```

The 2200.01.11 save agrees: system 0 (`basic_init_02`): planets at 0 / 50, 70 / 95 x 3 / 120, 145,
170, 195, 220, moons at 15 (`change_orbit = 10` + `orbit_distance = 5`), `inner_radius = 220 + 15
+ 30 = 265`, `outer_radius = 365`; `ai_system_03`'s gas giant without an `orbit_distance` at
164.97 = 145 + 19.97 (the default 10-20); `pc_molten` (`max_distance_from_sun = 60`) at orbits up
to 124, picked at the distance before the orbit.

`CPrescriptedPlanet::CalcPlanetClass` (`0x506670`):

| class | pick |
|---|---|
| `star` | the star class's `planet` (the n-th for multi-star classes) |
| `none` | none (the orbit still moves) |
| `random` | `GetRandomClassForOrbit` (`0xd36690`) |
| `random_colonizable` / `random_non_colonizable` | the same, filtered |
| `random_non_ideal` | the same without the empire's ideal class |
| `random_asteroid` | the asteroid classes by spawn_odds, no distance |
| `ideal_planet_class` | the empire's ideal class (non-colonizable for nomads) |
| `ideal_design_class` | the design's, else a random colonizable, else random |
| a name | a `home_planet` with an ideal class: that; a planet class; a planet class `random_list`: `G % n` (drawn even if it fails) |

`GetRandomClassForOrbit`: the planet classes in database order, asteroids and stars left out; the
odds are the nearest star class's `pc_x = { spawn_odds = f }` (used as is, not multiplied) or the
class's `spawn_odds` (`CPlanetClass::GetSpawnOdds` `0xd343c0`: 0 if its `potential` fails;
colonizable ones x max(habitability, 0.25)); colonizable ones x the scenario's
`colonizable_planet_odds`; kept if > 0, `min_distance_from_sun <= d <= max_distance_from_sun` and,
for a moon, `can_be_moon`; one G draw picks.

Deposits (`CColonyCarrier::RandomizeDeposits` `0xcce9e0`): none if the `should_spawn_deposits` game
rule fails or the resource abundance is the minimum; rolls: colonizable `5 + size/5` fixed and `2 +
size/5` random, others 1 (+ `C % (random + 1)`); each roll a C draw and a weighted pick over
`common/deposits` (`drop_weight` with its modifiers on the planet, `is_for_colonizable` matching,
`potential`; the null deposit's weight / abundance; each weight / (1 + 0.25 x same-category deposits
already there)); then the district caps and the blockers balanced (`MIN_UNBLOCKED_DEPOSITS` 3,
`MIN_BLOCKED_DEPOSITS` 1).

### 6.4 Empires **[V]** (the order) / **[I]** (details)

1. `CalcDesignsForEmpires` (`0x988900`): each slot a design of the configuration (forced ones picked
   uniformly by G, then `spawn_enabled` ones by G), valid, unused and with an unused portrait; else
   a randomized design. Then `GenerateEmpireSpeciesClasses` (`CSpecies::GetRandomClass`, C),
   `RandomizeEmpireGovernments` (a solver over the government restrictions; an origin with
   `initializers` gives the first valid one), `GenerateEmpireSpecies` (C).
2. `InitEmpireSystems` (`0x984eb0`): `ReorderPlayerLocations` (G); per empire: the design's
   initializer, else `GetRandomFromList(empire_init)` (`nomad_init` for nomads); `GetClass` as a
   check (C); the context: the ideal class (`GetStartingPlanetClass`), a G draw for the ideal design
   class; a C draw for the scope. One `InitializeQueue` for all: the empires' systems first (planet
   ids 0 ... in empire order in the 2210 save), then their neighbours layer by layer
   (`neighbor_t1` x 10, `neighbor_t1_first_colony` x 10, ...).
3. `GenerateSingleEmpire` (`0x97a210`), each: `CreateNewSpecies`, `CreateNewCountry` (default
   type), the founder species, `CCountry::InitFromDesign`, the modules, the ship designs;
   `InitHomePlanet` (`0x9785a0`): the home planet is `home_planets[G % n]` (none: the last planet,
   its class changed), owner and controller, `SetCapital`, the system surveyed and renamed;
   `InitEmpireShared` (`0x9793c0`): `CreatePrimaryStarbase` (C++), species rights, names, then the
   script: on_action `empire_init_add_technologies` (country: `game_start.8`), policies, ethics,
   `empire_init_capital_colony` (the capital colony: `game_start.12`: buildings, districts, pops),
   sectors, one leader (`CLeaderClassDatabase::Randomize`, C), `empire_init_create_ships`
   (`game_start.9`), fleets, councilors.
4. `GenerateFallenEmpires`, `AssignBaseSpecies`, then the other systems (6.2).

Pops, buildings, districts, ships, technologies and resources are script; the country, the
species, the home system and planet, the starbase and the first leader are C++.

### 6.5 After the generation **[V]**

`CGameState::InitPostGalaxyCreation` (`0x264340`): the map's pixel ownership,
`RecalculateCachedData`, the terra incognita in each country's sensor range,
`GenerateGalacticMap`, `CalculateRimGalacticObjects` (the save's `rim_galactic_objects`), the
sectors, the megastructures. `CGameState::OnNewGameStarted` (`0x272000`), when the game's idler
starts: `RecalculateCachedData`; the cosmic storm names (C); the global ship designs;
**on_game_start** (a C draw for its scope); for each country `CCountry::OnNewGameStarted`
(`0x746e00`): the economy, the AI personality (C), species rights, leader pools, patrons, pops,
**on_game_start_country** (a C draw); then the colonies, the leaders, the budgets, pop growth.

## 7. The Lua (`sim/lua/engine/newgame/`)

| file | what |
|---|---|
| `init.lua` | `newgame.generate(game_dir, settings)`: the steps in `GenerateFromRandomScenario`'s order, the summary; `newgame.start_script()`: the script's part on the loaded world |
| `rng.lua` | the streams: the generator's (section 2), sub-streams, the global one (`RUST.rand`) |
| `fixed.lua` | `CFixedPoint` arithmetic, the game's sine and cosine, `GetInt64 % 100000`, the distance test (5.0) |
| `delaunay.lua` | Delaunay triangulation (Bowyer-Watson) and one Lloyd relaxation (Triangle's part) |
| `scenario.lua` | the setup scenario, the shape, the defines, the scripted variables, the settings |
| `galaxy.lua` | the parameters, stars, nebulas, the galactic map's neighbours, start clusters, empire placement, resource clusters |
| `lanes.lua` | partitions and hyperlanes (5.6, 5.7) |
| `systems.lua` | the initializers: picks, spawn chances, trees and neighbours, star classes, planets, moons, belts, names (6.2, 6.3) |
| `empires.lua` | designs, the empires' systems, home planets, and their objects (6.4) |
| `save.lua` | the result in the save's form (`gamestate` and `meta`) |

The steps, as `newgame.generate` runs them (each with its draws, in the summary): parameters (5.1),
stars (5.2), nebulas (5.3), galactic map (5.4), start clusters and placement (5.5), partitions
(5.6), designs (6.4.1), resource clusters (5.8), hyperlanes (5.7), the empires' systems (6.4.2),
the empires (6.4.3), the other systems (6.2), galactic map. What follows the game, and what does
not:

| part | as the game | not (yet) |
|---|---|---|
| seeding | the generator's stream from the seed; the global stream through `RUST.rand` | the lobby's draws before generation; the global stream's state is the platform's |
| stars | everything of 5.2 in fixed point; the relaxation's input and output grids | Triangle's float Delaunay is replaced by Bowyer-Watson in doubles: the same triangulation up to ties and rounding, so positions can differ by 0.01 |
| nebulas | 5.3 | |
| neighbours, clusters, placement | 5.4, 5.5 | `ReorderPlayerLocations` only `normal`; random placement's distance in doubles |
| partitions | 5.6 | the round-robin's index after a removal [I] |
| hyperlanes | 5.7 with both global sub-streams | the edges' tie order (Triangle's orientation) in the sort; `ConnectDividedEmpirePartitions` and `ConnectEmpireSystems` not done |
| resource clusters | the draws | `CFixedPoint::Atan2` (not decoded) by `math.atan2`; `GenerateResourceRegions` not done |
| initializers | 6.2 and 6.3: picks, rolls, uses, trees, neighbours, mandatory neighbours, classes, intervals, coordinates, radii, rings | `usage_odds` modifiers whose triggers the small evaluator does not know are left out (counted in the summary); planet modifiers (one C draw, none picked); deposits (not made); `potential` of planet classes taken as passed; orbital lines |
| empires | the order of 6.4, the queue, the home planet pick | designs: the prescripted ones with `spawn_enabled` drawn by G, no randomized designs, species or governments; the C++ objects made directly: species, country (the technologies with `start_tech = yes`, the default stockpile), the capital colony with the default origin's pops (standing in for `game_start.12` until the engine runs it), the starbase with its station and fleet; no leader; no fallen empires, marauders or nomads |
| script | `newgame.start_script()` runs, on the loaded world, the init_effects in order, the empire on_actions, on_game_start and on_game_start_country | most engine effects of these are not modelled by the engine yet (section 8) |
| save | `galactic_object`, `planets`, `nebula`, `clusters`, `species_db`, `country`, `colony`, `pop_groups`, `starbase_mgr`, `ships`, `fleet`, `galaxy`, `galaxy_radius`, `flags` | the system `index` (0-63, not traced: a hash of the id); `system_initializer_counter`, `random_name_database`, deposits, leaders, sectors, `rim_galactic_objects` |

`sim/examples/newgame.rs` generates a galaxy from the settings and a seed, writes a .sav with
`save::write_save`, prints a summary, runs the start script in the same Lua state and writes the
result as `FILE-started.sav`, then loads both saves as any save (`engine.load` in a fresh runtime)
and runs them for N days:

```
cd sim && CARGO_TARGET_DIR=/root/simtarget-newgame STELLARIS_DIR=/opt/stellaris \
    cargo run --release --example newgame -- --scenario tiny --seed 1234 --out /root/ngwork/tiny.sav --days 30
stellar-render --png tiny.png --save /root/ngwork/tiny.sav     # CARGO_TARGET_DIR=/root/target-render
```

## 8. Checks

Against the game's medium save of 2200.01.11 (`/opt/stellaris-saves/2200.01.11.sav`, elliptical,
9 AI empires, 10 days in: 590 systems from generation and 6 made later), three galaxy seeds of the
Lua (medium, elliptical, 9 AI empires; the scripts are in `H:\code_working\tmp_newgame`:
`stats.py`, `nn.py`, `moons2.py`):

| | the game | Lua 1234 | Lua 7 | Lua 99 |
|---|---|---|---|---|
| systems (generation) | 590 (+6) | 590 | 590 | 590 |
| distance from the centre | 101.8-437.9 | 102.8-434.0 | 101.2-421.2 | 103.9-427.2 |
| systems per 25 between 100 and 400 | 36-60 | 40-57 | 39-58 | 43-53 |
| nearest neighbour, mean (min) | 22.3 (11.4) | 22.1 (11.9) | 22.2 (9.5) | 21.9 (10.8) |
| hyperlanes per system | 2.86 | 2.84 | 2.83 | 2.85 |
| degree 1/2/3/4/5/6+ | 59/140/257/102/25/12 | 55/131/286/96/16/6 | 44/170/249/105/17/5 | 51/137/283/91/22/6 |
| lane length, mean | 29.4 | 29.2 | 29.2 | 29.3 |
| planets (moons) | 6080 (1497) | 6108 (1540) | 6069 (1584) | 6057 (1523) |
| planets per system, no stars | 9.02 | 9.14 | 9.01 | 9.08 |
| barren_cold / barren / molten / asteroid | 968/932/782/689 | 968/936/772/699 | 876/941/816/596 | 861/901/782/761 |
| gas giant / frozen / ice asteroid / toxic | 552/528/395/351 | 540/542/347/371 | 592/497/375/374 | 587/516/371/374 |
| sc_g / sc_m / sc_m_giant / sc_k | 112/74/74/65 | 105/79/63/85 | 120/75/76/52 | 124/58/81/72 |
| nebulas of the generator (radius 30) | 6 | 6 | 6 | 6 |

Every lane's `length` is the distance rounded down, as in the save. The six start clusters have the
save's centres. The moons' classes by their planet's orbit match the save's band by band (molten
moons around planets at 60-120, frozen ones past 160). Hyperlanes within the save's 3%, degree
distributions alike; the planet classes within a few percent; the star classes within the spread
of a 600-system sample.

Load and run (tiny, 3 AI empires and the human, seed 1234): 196 systems, 286 hyperlanes, 2,023
planets, 4 empires, written as a 1.3 MB gamestate in 0.4 s; `engine.load` reads it (9 stores) and
runs 30 days (300 ticks) with no errors, and writes it back after the run. The start script runs
304 init_effects and 17 on_actions (181 script effects, 38 engine effects, no errors); the engine
applies 21 of them (resources, modifiers, technologies) and lacks, among others,
`create_ambient_object`, `prevent_anomaly`, `add_deposit`, `create_country`, `create_fleet`,
`create_species`, `set_policy`, `create_leader`, `spawn_megastructure`, `create_colony`,
`set_owner`: what pops, ships, deposits, the guardians and the wormholes need.

Render: `stellar-render --png` draws the tiny galaxy: 194/194 star sprites (the 2 toxoid stars have
no texture), 286/286 hyperlanes, the 4 empires' borders in their flag colours. Its check of the top
bar reports two texts it reads differently (the navy and starbase counters), not the map.

## 9. What differs and what is left

- **Exact reproduction** of a real galaxy is not possible yet: the global stream's state at
  generation (the lobby's draws) is unknown, Triangle's float triangulation is approximated, and
  the deposits, planet modifiers and species and government randomization draw from the streams in
  ways the Lua does not repeat. The galaxy seed alone gives the star map up to the relaxation.
- **Tiny galaxies** get a few systems far out (to 334 for radius 200): the relaxation moves a
  point next to the hull to the centroid of a cell with a far vertex. The game's Triangle has the
  same rule; whether its tiny galaxies show it was not checked (no tiny save).
- **Not done**: randomized empire designs (species, names, governments: the
  `RandomizeEmpireGovernments` solver), fallen empires, marauders, nomads, advanced empires;
  `ConnectDividedEmpirePartitions`, `ConnectEmpireSystems` (starbases between an empire's
  systems), `GenerateResourceRegions`, `GeneratePrecursorCivilizations`, `ProcessNeighbourContact`;
  deposits; planet modifiers; the static galaxy scenarios (`GenerateFromStaticScenario`,
  `static_galaxy_scenario`); shapes other than elliptical were not compared with a save.
- **The script's part** runs only as far as the engine models its effects. A playable start needs:
  `create_pop_group` and the pops, `add_building`, `add_district`, `create_fleet` / `create_ship`,
  `create_leader`, `add_deposit` / `clear_deposits`, `set_policy`, `create_country` /
  `create_species` (guardians, primitives), `spawn_natural_wormhole` / `link_wormholes`
  (`game_start.31`), `spawn_megastructure` (gateways), `create_ambient_object`.
- **Platform helpers** that would help (outside `newgame/`): a `RUST.noise(position, seed)` (the
  Lua does the 32-bit noise with 16-bit halves), and a `world.load_tree(tree)` to hand the
  generated tree to the world without writing and parsing text.
