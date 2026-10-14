# Stations: what construction ships build, and the AI that sends them (4.5.2)

How a construction ship's build order ends in a new outpost or orbital station, what that does to the
world (the starbase, the station ship and its fleet, the system's owner, borders, sectors), and how
the AI picks what its construction ships build and how it upgrades its starbases. Read from the GOG
4.5.2 build and its PDB (addresses are GOG RVAs) and, where the GOG build inlines a function, from the
Linux 4.5.2 build with its symbols (r2ghidra, `L:` addresses). **[V]** = read in the code, **[I]** =
inferred from the saves or the headless game's runs. The decompiles behind this page are in
`tmp_stations/` on the share.

| part | module |
|---|---|
| the order's start, tick and finish; the station, the starbase, ownership, borders, sectors | `sim/lua/engine/fleets/stations.lua` (run by `engine.fleets.orders`) |
| the construction ships' choices (HandleCivilianFleets' constructor branch, BuildStation) | `sim/lua/engine/ai/construction_ships.lua` |
| the starbases' upgrades (HandleStarbases) | `sim/lua/engine/ai/starbases.lua` |
| the strategy lists 3 (BUILD_ORBITAL_STATION) and 19 (EXPAND_BORDERS) | `sim/lua/engine/ai/strategy.lua` |
| the trigger `exploitable_planets` (the AI budget's stations entry) | `simscript/eval.lua`, `engine/interface.lua` (`-- stations`) |

## The order: `CBuildOrbitalStationFleetOrder`

```
build_orbital_station_order = { deposit_holder = { type = 0 id = <planet> } progress = <0..100>
    cost = 0  in_progress = no  class = shipclass_mining_station | ..._research_station |
    ..._observation_station | shipclass_starbase
    ship_design = { design = <id> upgrade = 4294967295 growth_stage = 0 }
    resources = { minerals = 100 }          # what StartOrder took from the stockpile
    sub_order = { move_to_system_point_order = { coordinate = { x y origin } can_reach commissioner } }
    can_reach = yes  order_id = <n>  commissioner = 4294967295 }
```

- **The command** (`CFleetBuildOrbitalStationCommand::Execute` 0xa57650) **[V]**: unless queued, the
  fleet's orders cleared (`CFleet::ClearOrders`); the order made for (holder, class), `IsPossible`,
  then `CFleet::AddOrder`.
- **OrderQueued** (0xcdebe0) **[V]**: `ship_design` = `CalcShipDesign` (0xce0170): for a starbase the
  country's custom starbase type's design, else `CCountry::GetLatestOrbitalShipDesignOfClass`
  (0x70deb0); the latest design of the class: the country's `ship_design_collection` from its last
  design back, the first whose growth stage's ship size has the class (`GetLatestShipDesignOfClass`
  0x70d7e0 compares a value of each stage and keeps, for starbases, the lowest: the outpost **[I]**).
- **StartOrder** (0xcdf390) **[V]**: what `resources` holds goes back to the stockpile; the cost
  (`CalcCost` 0xce1eb0: `NEconomyUtil::GetOrbitalStationConstructionCost`, the design's growth stage
  as an economic unit with the country's modifiers, plus for a starbase on the system's star the
  influence of `CCountry::CalcExpansionInfluenceCost` 0x72d2b0); when the stockpile pays: taken into
  `resources`, progress 0, and a system of another country without communications is attacked
  (`OnAttackedBy`, not modelled); otherwise the order is cancelled.
- **TickOrder** (0xcdfac0) **[V]**: a fleet in orbit of the holder, or at `GetTargetCoord` (0xcdf7e0,
  compared exactly), adds `CONSTRUCTION_SHIP_WORK_SPEED_MULT * (1 + the class's build speed
  modifier) * the size's factor * (1 + its modifier)` (1 a day in the 2210 saves); elsewhere a
  `move_to_system_point_order` to `GetTargetCoord` (made when there is none, else ticked and dropped
  when done). `GetTargetCoord`: the station's place + `CONSTRUCTION_SHIP_STATION_OFFSET` (5) *
  (fleet - place) / |fleet - place|, the fleet's x and y whatever system it is in, the integer root of
  the raw squares, fixed-point products and quotients truncated. Checked: every build position of
  the 2210.01.01 save is 5.00000 or 4.99999 from the station's place, and the AI's new orders get the
  game's sub-order coordinate to the digit (fleet 344, (72.19436, -134.81141)).
- **IsDone** (0xce0f50): `progress >= GetNeededProgress` (100). **ShouldCancel** (0xce1e80): not
  `IsPossibleExceptPathfinding` (ported: the planet gone, a station of the class there, a starbase in
  the system, another country's system **[I]**); a cancelled order's `resources` are refunded
  (OrderUnQueued 0xcdedc0).

### Finish (0xce0290) **[V]**

1. `CDepositHolder::CanCreateOrbitalStation` (0xd93050); the design from `CalcShipDesign`.
2. `CDepositHolder::CreateOrbitalStation(fleet, design)` (0xd93c80): **two draws** (the scopes) and
   `on_building_<ship size>` (`on_building_mining_station`, `on_building_starbase_outpost`, ...; this =
   the construction ship, from = the planet); then `CreateOrbitalStation(country, design)` (0xd945a0):
   - `CGameState::CreateNewOrbitalStation` (0x268b10): the ship, named `<ship class>_name` with
     `PLANET` = the planet's name; `CreateNewFleet` (0x2698e0, `last_created_fleet`); `CFleet::AddShip`
     (the fleet named the same);
   - a starbase: the ship at the planet's coordinate, `CGalacticObject::CreateStarbase` (0x865ad0):
     the ship renamed `STARBASE_STATION_NAME_FORMAT_NON_PRIMARY` (a primary starbase replacing another
     gets `STARBASE_STATION_NAME_FORMAT`), `CGameState::CreateNewStarbase` -> `CStarbaseManager::
     CreateStarbase` (0x966b20) -> `CStarbase::Initialize` (0x7cdd90): a construction queue (`type =
     starbase`, owner, location the ship), a copy of the design (`CreateNewShipDesign`, without
     `auto_gen_design`; `last_created_design`), the level from the size (`starbase_level_outpost`);
     the system's `starbases` (the first entry is the primary, `4294967295` without one), the
     ownership cache, the controller's systems with starbases;
   - the planet's `shipclass_orbital_station` or `orbital_defence` = the fleet; its controller (not
     for an observation post; `CPlanet::SetController` 0xdf8690: `controlled_planets`, the
     occupation on_actions only for an owned planet);
   - the fleet in orbit (`orbit = { orbitable = { planet } index = -1 }`), placed by
     `CalcOrbitalStationCoordinate` (0xd90930): d = max(0, (size - 10) * 0.33), a starbase at the
     planet + (d + 15, -(d + 15)), a station at + (-(d + 6), -(d + 6)); facing the planet
     (`AngleTo`), the ship snapped (rotation, forward = (-sin, cos) normalized).
3. A starbase on the system's star: `CGameState::CalcBorders` (0x2550f0): the systems' ownership
   updated (`CGalacticObject::OnOwnershipUpdated` 0x86d5d0: `on_system_lost` / `on_system_gained`,
   their scopes from a `CCrudeRandom` seeded with the countries' ids and the date, no draws),
   `NBordersUtil::CalcBorders` (0x960490: each country's systems within its borders, on the border,
   with controlled starbases), then each diplomacy module's `UpdateBorderCache`: the module's
   `borders` = the number of systems within the borders, each relation's `borders = yes` (bordering
   either way), `border_range` (not modelled).
4. An AI country's starbase: `CFleetSetExpansionFlag` (0xa6a020): `dirty_expand_strategy = yes`
   (written last in the AI block); the next strategic data rebuilds the lists and clears it.
5. The new system joins a sector in `NSectorManager::Update` (0x946d00) the same day:
   `AddSystemToBestSector` (0x947760): of the country's sectors, those whose capital is within the
   type's `max_jumps` (+ `sector_max_jumps_add`) through systems of that sector or of none, the one
   whose type has the highest `system_scores` (core 100, normal 1).
6. Messages and telemetry: not modelled.

The ids: `TPdxRefDatabase<T>::CreateNewObject`, index | generation << 24; the save's `id = none`
slots are free, taken in ascending order at load, a slot freed since pushed in front, else the index
past the highest (the stations use `engine.fleets.create`'s allocator when it is there, so the ship
building and the stations share one view of every store).

The objects are written as the game has them the day after (its `combat.coordinate.origin` set,
`dirty_cloaking_strength` gone, `created_this_update = no`). The hit points, the sections and
weapons, the graphical culture, the fleet's power and properties are those of a ship of the same
design (stations) or of the country's outpost with the same components (starbases) **[I]**: in the
2210 saves every new station has the hit points of the country's other ships of its design.

## The AI's construction ships

On the AI's week, `CAIInteriorMinister::HandleCivilianFleets` (0xbbab50), the constructor branch
(0xbbbf94-0xbbc11b) **[V]**, the fleets in the owned fleets' order (starbases first):

- a civilian construction ship not MIA, not between systems, mobile: with an actual order, or while
  the AI's `DirtyExpandStrategy` is set: counted, nothing ordered; otherwise `BuildStation(fleet,
  taken, first, constructors)` with `first` = no construction ship counted yet this week;
- after the fleets: `CToggleAINeedsStationsCommand` (0x6c4a80) when "a construction ship was counted"
  differs from the AI's `NeedsStations`. No AI block of the 2210-2212 saves has `station = yes`, so
  the flag is kept in Lua, not written **[I]**.

`BuildStation` (0xbbe150) **[V]**:

1. (not in war mode: `BuildStationForSpecialProject`, not ported)
2. `FindDepositHolderForOrbitalStation` (0xbbd230): **one draw** of the AI's unsynced generator (the
   scope's seed); the BUILD_ORBITAL_STATION list (3) in its order; a holder not taken, without a
   station, of a class the fleet can build (`construction_capabilities`), in a system no other
   construction ship's executing order goes to; a mining or research station needs
   `CanBuildStation`, known orbital resources, and the budget (`CanAffordExpenditure` of the cost,
   `CanAffordUpkeep` of the upkeep, a mining station's upkeep less `EXPANSION_RESOURCE_GAIN_UPKEEP`
   (0.5) of what it would mine); score = -jumps * `CONSTRUCTION_SHIP_DISTANCE_PENALTY` (20), the
   best whose path is clear (`NAIUtil::IsPathClear`), a later one winning a tie.
3. The class: an observation post when the fleet can build one there (never here), else the holder's
   orbital deposit's (`GetOrbitalDepositClass` 0xd92540: the first deposit's `station`).
4. No holder, or the week's first construction ship: `FindPlanetForStarbase` (0xbbc820): the outpost's
   cost affordable; the EXPAND_BORDERS list (19) in its order: not a system of ours with a primary
   starbase, not taken, `CanBuildStation(star, starbase)`, the path clear, the upkeep less the
   system's orbital resources * 0.5 affordable; score = value - jumps * 20 + (a draw % 
   `EXPANSION_RANDOM_AMOUNT` (50)), **one draw per candidate** that gets that far; the best above 0
   replaces the station.
5. Nothing: (megastructures, not ported) a fleet outside our systems returns to base.
6. Else, when the budget pays: `CFleetBuildOrbitalStationCommand(fleet, holder, class)` posted, its cost
   withdrawn from the budget, the holder taken.

The lists walk in the order `CreateColonizeData` made them since the last rebuild, after a load in
the save's (sorted) order, which is the order `ReadMember` added them (`strategy.entries`).

### The lists 3 and 19 (`CCountryAI::CreateColonizeData` 0xb6f280)

- **3 BUILD_ORBITAL_STATION**, own systems only: each surveyed planet nobody can colonize whose first
  deposit has a `station` class, when `CanBuildStation(P, class)`: `(3, P, class, 1)`.
- **19 EXPAND_BORDERS**, for a colonizer: the star of a system nobody owns (or one of ours without a
  primary starbase: `EXPANSION_OWN_PRIORITY`) whose planets are all surveyed, when
  `CanBuildStation(star, starbase)` and `NAIUtil::ShouldBuildStarbase` (0xba4fa0: within
  `MAX_EXPANSION_DISTANCE` (2) jumps of our systems, `CalcNumJumpsFromBorder` 0xa0f2d0; the systems
  that would anger a fallen empire: not modelled): `(19, star, 0, CalcExpansionValue)` (0xba5390:
  `CalcResourceSum` (0xba5520, every orbital deposit's output, strategic resources included) * 2 +
  400 with a colonizable planet + 10 with a bypass + 10 when every neighbour is ours, else 500 when
  it borders us).
- `CDepositHolder::CanBuildStation` (0xd949f0, `CPlanet::CanBuildStation` 0xe00c90) **[V]** (the
  checks ported): a design of the class; the system known (intel level); for a station the planet
  surveyed, no station on it, its deposit's resource visible (`HasResourceForGetPrerequisites`: every
  technology of the resource's `prerequisites`, one of each `OR`), not another country's system, no
  megastructure (`can_planet_support_orbital_station`); for a starbase no primary starbase in the
  system. Observation posts (pre-FTL rules): never.

### `exploitable_planets`

`CExploitablePlanets::GetTriggerValue` (0x19af250) **[V]**: the planets of the country's systems that
are not colonies, have no orbital station and have orbital resources. The AI budget's
`minerals_expenditure_stations_expand` (weight 0.05, `desired_min` 100) needs it at 1 or more: without
it the stations' minerals budget is ~10% of the stockpile, too little for a 100-mineral station.

## The AI's starbases

`CAIInteriorMinister::HandleStarbases` (0xbc4f70) on the AI's week, after the districts and buildings
**[V]**: capacity = trunc(`starbase_capacity`), used = the systems whose primary starbase is upgraded
or upgrading (`CalcNumStarbasesIncludingConstruction` L:0x23acf30); the primary outposts (not a
waystation) are upgrade candidates, the others the upgraded list; `DowngradeStarbases(capacity -
used)`, `BuildStarbaseModulesAndBuildings`, and with `ai.starbase_upgrade`: `UpgradeExistingStarbases`
(the next level of upgraded ones) and, with room, `BuildNewStarbases` (0xbc5ab0): the first outpost of
the highest `CalcStarbaseSystemScore(system, starbase, true)` (0xbc4c10: 5 with a colony of ours, else 3
with a colonizable planet, + 5 megastructure, + 10 bypass, + the chokepoint's value, + 5 sector
capital, divided by max(1, the level's `ai_weight`)) above 0, its upgrade posted with its cost and
upkeep (`AddAICommandWithCostAndUpkeepForPosting`). Ported: the counting and `BuildNewStarbases`
(chokepoints not); the item goes to the starbase's queue in the save's form through
`engine.ai.economy.orders`:

```
<id> = { queue = <the starbase's build_queue> paying_country progress = 0 progress_needed = 360
         resources = { alloys = 250 }
         buildable_starbase_upgrade = { starbase_upgrade = "starbase_level_starport" starbase = <id> } }
```

Not ported: downgrades, modules and buildings, `UpgradeExistingStarbases`, `HandleStarbasesDefenses`
(defense platforms, from `AI_BUDGETING_MID_YEARS`).

## Checks

Against the headless game from `autosave_2210.01.01` (`/opt/stellaris-headless/out/stations/`: `t<N>`
the day before and the day of each starbase, plus `fleetorders/`).

**The objects.** The first mining station (2210.01.03, 16777225, planet 3579) and the first outpost
(2210.02.10, 16777223, planet 5673, starbase 131): the ship, the fleet, the planet, the system, the
sector, the construction queue, the starbase, the country's `owned_fleets`, `controlled_planets` and
`borders` equal the game's of that day field for field (the same ids), but the outpost's design id
(the game made a starbase-module design copy and four AI ship designs first, which took the first
free slots) and the three fields the game settles the next day.

**What is built in 180 days** (the game: 5 outposts, 21 stations):

| game | country | what | planet | the simulation |
|---|---|---|---|---|
| 01.03 | 16777225 | mining | 3579 | 01.03 |
| 01.15 | 6 | mining | 4539 | 01.15 |
| 01.25 | 16777219 | mining | 862 | 01.25 |
| 01.30 | 16777217 | mining | 1494 | 01.30 |
| 02.03 | 6 | mining | 288 | 02.03 |
| 02.05 | 49 | mining | 2160 | 02.05 |
| 02.09 | 6 | mining | 3581 | 02.09 |
| 02.10 | 16777223 | outpost | 5673 | 02.10 |
| 02.14 | 16777220 | mining | 413 | 02.14 |
| 03.03 | 16777224 | mining | 4754 | 03.03 |
| 03.08 | 16777224 | outpost | 3319 | 03.08 |
| 03.11 | 50 | outpost | 5866 | 03.11 |
| 03.15 | 50 | research | 1326 | 03.15 |
| 04.03 | 16777225 | mining | 2553 | 04.03 |
| 05.02 | 16777221 | outpost | 330 | 05.05 |
| 05.12 | 16777219 | mining (AI) | 861 | 05.14 |
| 05.20 | 26 | mining | 4585 | (a scripted country: mining drones) |
| 05.22 | 16777221 | mining (AI) | 1153 | 05.24 |
| 05.29 | 6 | mining (AI) | 3580 | (4541 on 05.05, research 3587 on 06.15) |
| 05.30 | 16777224 | mining | 455 | 06.03 |
| 06.04 | 16777220 | mining (AI) | 412 | 06.06 |
| 06.05 | 16777225 | mining (AI) | 3578 | 06.08 |
| 06.12 | 26 | mining | 3387 | (scripted) |
| 06.17 | 16777224 | mining (AI) | 4753 | 06.19 |
| 06.24 | 16777223 | outpost | 1033 | 06.26 |
| 06.27 | 16777218 | mining | 2144 | (progress 98-99 on 07.01) |

The orders in progress at load finish on the game's day when the ship is in position (14 of 14),
2-4 days late when it must move (the movement port stops within 1.0 of a target and follows the
target `move_to` gave it, where the game asks the order every tick; and the AI's civilian ships'
speed factor, docs/fleet_movement.md). The simulation also builds 49's 2159 (06.20).

**The AI's orders.** The game issued 23 new build orders in the 180 days (seen in 15 snapshots); the
simulation 31, 15 of them the same fleet and planet (11 of the game's 14 stations: 1153, 861, 3578,
4753, 412, 5874, 2552, 337, 857, 4301, 3330; 4 of its 9 outposts: 1431, 138, 4148, 423), often earlier
(the simulation's AI spends its budget on nothing else yet). The outposts' choice adds a draw of the
unsynced AI generator, which drifts from the game's after the first unported draw (docs/random.md),
so those compare only statistically. The orders themselves are the game's: fleet 22's (1431: alloys
100, influence 75, order_id 11) and fleet 344's (5874, its build position to the digit) equal the
game's field for field.

**The lists.** Lists 3 and 19 computed at load equal the saved ones entry for entry: 2210.01.01 114 of
114 and 38 of 38, 2210.07.01 119/119 and 36/36, 2211.01.01 115/115 and 36/36.

**The starbases.** One upgrade ordered in 180 days: country 6's starbase 114 to a starport, the one
starbase item the game queued (the game around 06.11, the simulation on 01.14: the game spends its
alloys on ships first).

**Store by store** over 1,798 ticks (`examples/diff`, against `fleetorders/t1798.gamestate`; "off"
is `STELLAR_STATIONS=off STELLAR_AI_CONSTRUCTION=off STELLAR_AI_STARBASES=off`, run right before
"on" with the same code otherwise, the ship building of docs/shipbuilding.md in both; the lists 3/19
and `exploitable_planets` are on in both). No phase errors either way.

| store | objects in both, off | on | fields equal, off | on | differ, off | on |
|---|---:|---:|---:|---:|---:|---:|
| all 34 stores | | | 720,273 | 723,366 | 14,681 | 13,265 |
| country | 53 | 53 | 222,038 | 223,167 | 6,336 | 4,431 |
| galactic_object | 596 | 596 | 21,926 | 21,947 | 102 | 86 |
| starbases | 131 (5 only in the game) | 136 (0) | 1,191 | 1,220 | 24 | 30 |
| fleet | 809 (23 only in the game) | 827 (5) | 56,578 | 57,815 | 3,214 | 3,361 |
| ships | 2,502 (44 only in the game) | 2,526 (20) | 107,855 | 108,466 | 2,974 | 3,257 |
| sectors | 14 | 14 | 182 | 187 | 5 | 0 |
| planet | 6,080 | 6,080 | 115,634 | 115,662 | 202 | 178 |
| ship_design | 2,199 | 2,204 | 100,638 | 100,667 | 45 | 175 |
| construction queues | 6,285 (6 only in the game) | 6,290 (1) | 31,862 | 31,885 | 33 | 33 |

The stockpiles' change explained: minerals 52.4% -> 56.4%, alloys 54.9% -> 74.1%, influence -12.7%
-> -5.0%. What the new objects add in differences is mostly their ids: the game's other creations
in the window (its AI's ship designs, a starbase-module design copy, the ships its shipyards build
and merge) take ids the simulation gives to its stations first, so a design or a ship at the same id
is another object (ship_design +130 differences, the 5 outposts' designs).

## Not modelled

- The class's and size's build speed modifiers (1 a day in the saves), `OnAttackedBy`, the subject's
  expansion tithe, messages and telemetry.
- `CCountry::AbandonOrDisbandStationsAndStructures` / `TakeAbandonedStationsAndStructures` (stations of
  others in a system that changes owner), the relations' `border_range`, the AI's `NeedStrategicWarData`
  when borders change.
- The AI: special projects, megastructures, observation posts, the fallen-empire anger check, the
  stance command before a return, chokepoints, downgrades, modules and buildings, defense platforms.
- The per-tick target of a move sub-order (a fleet the movement leaves within 1.0 of the build
  position is sent on the next day).
