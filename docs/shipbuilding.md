# Ships, starbases and armies built (4.5.2)

How the game builds ships, starbase upgrades, modules and buildings, and armies from its
construction queues, what finishing one puts in the world, and how its AI decides what to build.
Read from the Linux 4.5.2 build with its symbols (`/root/fnm_tmp/fleetmove/dec.py`, Linux
addresses) and the GOG 4.5.2 PDB (layouts), checked against the real game run headless
(`headless/run.sh`, docs/random.md). **[V]** = read in the code or measured in the headless game;
**[I]** = inferred from the saves. Ported in `sim/lua/engine/construction.lua` (the queue items),
`sim/lua/engine/fleets/create.lua` (ships and fleets from a design) and
`sim/lua/engine/ai/shipbuilding.lua` (the AI). The queues themselves are docs/construction.md; the
AI's budget is docs/ai_economy.md.

## In short

- **Progress** is the queue's own (docs/construction.md): a ship item gains 1 + the shipyard's
  `starbase_shipyard_build_speed_mult`, `starbase_shipyard_artificial_build_speed_mult` and
  `shipsize_<size>_build_speed_mult` a day, from the starbase's modifier node; a starbase upgrade
  1 + `starbase_upgrade_speed_mult`, a module 1 + `starbase_module_build_speed_mult`, a building
  1 + `starbase_building_build_speed_mult`; an army 1 + `planet_army_build_speed_mult` **[V]**.
- **A ship finished** (`CBuildableShip::OnFinished`, `0x219a660`) is made from its design at the
  shipyard's orbit (`CGameState::CreateNewShip`: a name drawn from the country's name list, the
  sections and weapons of the design, the hit points of its size, sections and components times the
  country's mults), then joins a military fleet of the owner in orbit there or gets a new fleet in
  a free orbit slot, and `on_ship_built` fires **[V]**.
- **An army finished** (`CBuildableArmy::OnFinished`, `0x26cfac0`) is created with the next
  sequential name of the country's army names; an assault army goes to orbit in a transport of
  the country's latest transport design, in a new transport fleet (`TRANS_FLEET_NAME` with the
  country's `next_transport_fleet_number`) **[V]**.
- **Ids**: the next index past the highest of the store, the save's free slots first (none in the
  ships, fleets and armies of the 2210 saves); the game's new ship 2510 (into fleet 7), ship 2511
  with fleet 810 and the transport fleet 814 come out with the game's ids **[V]**.
- **Random draws** (the synchronized generator): a ship two a try of its name (the country takes
  names it has not used), two for `on_ship_enter_fleet`, two for `on_ship_built`, three for a new
  fleet's orbit; an army two (`on_army_recruited`) + five (its transport) + one; a district, zone
  or building two. The game's construction phase drew 73 in 180 days **[V]** (profile).
- **The AI** decides daily, in the interior minister (`CAIInteriorMinister::DailyUpdate`):
  `BuildArmies` (two AI draws a day) and `BuildShips` -> `BuildShipOfOwnerType`, one ship at most a
  day, the size the strategy's list 9 wants most (`GetOrRequestDesign`: one AI draw a size), within
  the ships budget, in a shipyard with room **[V]**. The AI's designer, list 9's monthly rebuild,
  the upkeep check and the budget's missing entries are docs/ai_fleets.md.

## 1. The items (the save's form)

```
<id> = { queue paying_country progress progress_needed resources = { alloys = 104.5 }
         buildable_ship = { ship_design_implementation = { design upgrade = 4294967295 growth_stage = 0 }
                            orbitable = { starbase = 1 } } }
         buildable_army = { army_type = "assault_army" species planet = <colony> starbase = 4294967295 }
         buildable_starbase_upgrade = { starbase_upgrade = "starbase_level_starport" starbase }
         buildable_starbase_module = { ... starbase slot }      (CBuildableStarbaseModule)
         buildable_starbase_building = { ... starbase slot }    (CBuildableStarbaseBuilding)
```

A ship item sits in the starbase's `shipyard_build_queue` (a queue of type `ships`), an army item
in the planet's army queue (type `army`, location the planet), a starbase item in the starbase's
`build_queue`. In 2210.01.01: 2 ships, 3 armies and 1 starbase upgrade under way.

## 2. Progress **[V]**

| buildable | speed a day | build time |
|---|---|---|
| ship (`CBuildableShipBase<CBuildableShip>::CalcProgressionSpeed`, `0x21a4e40`) | 1 + `starbase_shipyard_artificial_build_speed_mult` (`starbase_shipyard_space_fauna_build_speed_mult` for a fauna size) + `starbase_shipyard_build_speed_mult` (+ `starbase_defensive_war_ship_build_speed_mult` in a defensive war) (+ the fauna sizes' small..titanic mult) + `shipsize_<size>_build_speed_mult`, of `CFleetOrbitalSlotHandle::GetEconomicModifiers(orbitable)` (the starbase's node) | `CBaseDesignImplementation::CalcBuildTime` (the size's `base_buildtime` and the time mults) |
| starbase upgrade (`0x21b5700`) | 1 + `starbase_upgrade_speed_mult` (the starbase's node) | the level's time x (1 + `starbase_upgrade_time_mult`) |
| starbase module (`0x21b3d00`) | 1 + `starbase_module_build_speed_mult` | `construction_days` x (1 + `starbase_module_build_time_mult`) [I] |
| starbase building (`0x21b2b30`) | 1 + `starbase_building_build_speed_mult` | x (1 + `starbase_building_build_time_mult`) [I] |
| army (`CBuildableArmy::CalcProgressionSpeed`, `0x26d0180`) | 1 + `planet_army_build_speed_mult` (the colony's node) | the type's `time` x (1 + `planet_army_build_time_mult`) |

The modifier enum (`ModifierType` in the PDB) names the ids the code reads: 283
`starbase_shipyard_build_speed_mult`, 286 `..._artificial_...`, 289 `..._space_fauna_...`, 294
`starbase_upgrade_speed_mult`, 298 `starbase_building_build_speed_mult`, 301
`starbase_module_build_speed_mult`, 295 `starbase_defensive_war_ship_build_speed_mult`, 166
`planet_army_build_speed_mult`, 96 `ship_starting_experience_add`.

The items at load, against the game: 16777217's corvette at starbase 1 (16.25 of 60; the
starbase's `shipsize_corvette_build_speed_mult` 0.25: 1.25 a day) and 16777219's construction ship
at starbase 3 (15 of 60, `starbase_shipyard_build_speed_mult` 0.25) finish on 2210.02.06 and
02.07, as in the game; 6's starport upgrade (143 of 360, 1 a day) stands at 323 on 2210.07.01 in
both.

## 3. A ship finished: `CBuildableShip::OnFinished` (`0x219a660`) **[V]**

```
owner = CFleetOrbitalSlotHandle::GetEconomicUnitOwnerRef(orbitable)      (the starbase's owner)
ship  = CreateShipAroundOrbital(owner, design, orbitable)   (0x219ad80):
          CGameState::CreateNewShip(design, owner)          (0x1b44ae0)
          CShip::ResetToCoordinate(the orbitable's coordinate), ResetToRotation(VFixedPI)
          CShip::AddToConstantModifier(GetBuiltShipModifiers(orbitable)), the rarity modifier,
          + ship_starting_experience_add
fleet = CFleetOrbitalSlotHandle::FindMergeFleet(orbitable, owner, ship)
        (an arkship's following fleets when there is none)
none: fleet = CreateFleetAroundOrbital(owner, ship, design, orbitable)   (0x219aee0):
          CGameState::CreateNewFleet (CFleet::Initialize: the owner), SetIsCivilian(the size's
          civilian flag), EnterOrbitInternal(orbitable)
CFleet::AddShip(fleet, ship)
a starbase-class size: CGameState::CreateNewStarbase(ship); a colony ship: CreateColonyInsideShip
a mobile starbase's station: the new fleet follows it when idle
FireOnShipBuiltOnAction(ship, orbitable)   (0x219b100): two draws (the scopes), on_ship_built
        (this = the ship, from = the planet or starbase)
```

**`CGameState::CreateNewShip`**: the next ship id (`TPdxRefDatabase<CShip>::CreateNewObject`);
the name, unless one is given (an army's transport takes the army's name):
`GetShipNameWithRomanNumerals` -> `CNameListManager::TakeRandomShipName(size, country)`
(`0x1dc1910`): up to 100 tries of `CNameListShip::GetRandomNameKey` (`0x1dbc650`: one draw, odd
picks the name list's `generic` names when there are some; one draw for the name), the first one
the country has not used (`ship_names` count 0); a used name gets the roman numeral of its count +
1 (`SUFFIX_NAME_FORMAT`). A size without `uses_name_prefix = no` puts the country's `ship_prefix`
in front (`PREFIX_NAME_FORMAT { NAME PREFIX }`), and `CCountry::AddShipNameKey` counts the name's
key in `ship_names` (`"%SEQ%"` for a transport). `CShip::Initialize` builds the sections of the
design and a `weapon` per weapon component (`index` the ship's own counter, `next_weapon_index`).

The headless profile gives the names' cost: 25 ships named in 180 days, 2,129 tries (4,258
draws): a country that has used most of its list tries many times.

**The hit points** (`create.hit_points` [I], checked on every ship of the 2210.01.01 save): hull =
the size's `max_hitpoints` + the `ship_hull_add` of the size's `modifier`, the sections' and the
components' `modifier` blocks; armor and shields the same with `ship_armor_add`,
`ship_shield_add`; each times 1 + the country's `ship_<kind>_mult` + `shipsize_<size>_<kind>_mult`.
2,163 of the 2,504 ships exact on all three (every corvette, constructor, science ship,
colonizer, mining and research station, and the space fauna); starbases (their modules' and
buildings' armor), fallen empires and some transports are off.

**`FindMergeFleet`** (`NFleet::CanMergeShipWithFleet`, `0x29176c0`): a fleet of the country (owner
and controller) in orbit there with ships, neither civilian, a station nor a transport fleet, that
can take the ship. A military ship joins it; a civilian one gets a fleet of its own.

**`CFleet::AddShip`** (`0x292d430`): the ship in the fleet's `ships` by size; its `fleet`, its
`reserve` (the fleet's count - 1); with the first ship the fleet's name (`CFleet::CreateName`,
`0x292b620`: a military fleet a random name of the name list's `fleet_names.random_names`, one
draw a try while another fleet of the country has it, else the sequential name; a transport fleet
`TRANS_FLEET_NAME` with the country's adjective and `next_transport_fleet_number` + 1; any other
the ship's name); the fleet's hit points; `CFleetTemplateManager::OnShipAdded` (`0x2a1b120`): the
design added to the fleet's template (`count` + 1) while its `fleet_size` stays within the command
limit, or a new template for a military fleet without one; then `NScriptUtil::OnShipEnterFleet`
(`0x2957710`): two draws and `on_ship_enter_fleet` (this = the fleet, from = the ship). The
country's `fleet_size` and `used_naval_capacity` grow by the size's `size_multiplier` (5 for a
corvette) [I].

**The new fleet**: `ship_class` the size's class, `fleet_stance = evasive` for a civilian one,
`properties` (`civilian`, `mobile`, `valid_for_combat`, `can_construct_megastructures` for a
constructor, `dirty_cloaking_strength`), `can_orbitable_repair_ships` in orbit of a starbase above
an outpost [I]; `movement_manager.orbit = { orbitable = { starbase } index = <slot> }`. A
starbase's orbit slots are its `orbitals = { <slot> = <fleet> }` (the first free one), slot k at the
station's place + (-1 + 2 floor(k/4), -1 + 2 (k mod 4)) [I] (from the save's fleets in orbit);
entering an orbit (`CStarbase::EnterOrbit` / `CPlanet::EnterOrbit` -> `CFleet::OnEnteredOrbit`)
draws three **[V]** (profile: 168 calls, 504 draws in 180 days, nearly all from the fleet orders).

## 4. An army finished: `CBuildableArmy::OnFinished` (`0x26cfac0`) **[V]**

```
country = the colony's planet's owner
army = CGameState::CreateNewArmy(country, colony, species, type, name)   (0x1b47030)
         the name: CNameListManager::TakeSequentialArmyName (the name list's army_names, the
         type's entry or generic): %SEQ% { fmt = <sequential_name> num = n }, no draw
NPlanetArmies::GiveModifierAndStartingExperience
CArmy::PerformBuildingOnAction("on_army_recruited"): two draws (this = the colony, from = the army)
NPlanetArmies::AddOrEmbark(colony, army, true, starbase ? 2 : 0)        (0x1e50610)
    a defensive army stays (colony =); any other: CArmy::MoveToOrbit (0x22305e0 Linux):
      the country's latest transport design (GetLatestShipDesignOfClass(transport)),
      CreateNewShip(design, country, the army's name) at the planet, rotation pi,
      a merge fleet at the planet (none in the 2210 saves) else a new fleet in orbit of the planet
      (TRANS_FLEET_NAME, CPlanet::EnterOrbit: three draws), CArmy::SetShip, CShip::SetArmy,
      AddShip (two draws); five draws a transport in the profile (one not placed)
the item had a starbase and the transport's fleet is not civilian: an orbit order to it
one draw: CArmyType::OnBuilt(colony, the value)
```

The army in the save: `name type health max_health jump_drive_cooldown owner species` and `ship`
(embarked) or `colony`, then `morale`. The three armies under way at load finish on 2210.02.20,
03.18 and 03.20 as in the game; their transports 2515 (fleet 814: the game's), 2520 and 2522 get
new transport fleets; the game later merges 2515's fleet into 570 (the AI).

## 5. Starbase items finished **[V]**

- **Upgrade** (`CBuildableStarbaseUpgrade::OnFinished`, `0x21b4b70`): `CStarbase::SetLevel`
  (`0x2030f30`): `SetupUpdateData`, `SetLevelParallelPart`, `RebuildSerial` (which calls
  `UpgradeStationDesign`: the station's design regenerated for the level's `ship_size`,
  `CCountry::AddUtilities`, `UpgradeComponents`, the ship initialized again), then
  `CShip::FireOnShipUpgradedAction`: one draw, `on_ship_upgraded` (this = the station); a message.
- **Module** (`0x21b2f70`): `CStarbase::SetModule(module, slot)`, the starbase flagged for its
  rebuild (`+0x19 |= 2`); a module with an `on_finished` effect: one draw, the effect in the
  starbase's scope.
- **Building** (`0x21b1460`): `CStarbase::SetBuilding(building, slot)`, the same flag.

Ported: the level (and the station design's `ship_size`), the module or building in its slot, the
draws and the on_actions. Not ported: the station design's regeneration and the rebuild of its
cached modifiers (`RecalcCachedModifiers`). No starbase item finishes in the 180 days checked
(6's upgrade at 323 of 360; the AI's second upgrade, 2210.06.10, at 20).

## 6. The random draws of the construction phase **[V]**

`HEADLESS_PROFILE` over 180 days from 2210.01.01 with a table of the construction functions
(`/opt/stellaris-headless/out/shipbuild/sites_con.tsv`, `sites_con2.tsv`):

| | calls | draws |
|---|---:|---:|
| `CConstructionQueueItem::OnFinished` (all kinds) | 14 | 73 |
| - `CBuildableDistrict::OnFinished` (2 sites) | 4 | 8 |
| - `CBuildableZone::OnFinished` | 2 | 4 |
| - a building | 1 | 2 |
| - `CBuildableShip::OnFinished`: `CreateShipAroundOrbital` (the name) / `AddShip` / `CreateFleetAroundOrbital` (its orbit) / `FireOnShipBuiltOnAction` | 4 | 16 / 6+2 / 3 / 8 |
| - `CBuildableArmy::OnFinished`: `PerformBuildingOnAction` / `AddOrEmbark` / `OnBuilt` | 3 | 6 / 15 / 3 |
| `NScriptUtil::OnShipEnterFleet`, everywhere (stations included) | 55 | 110 |
| `CGalacticObject::OnFleetEntered` | 76 | 106 + 13 |

## 7. The AI **[V]**

`CAIInteriorMinister::DailyUpdate` (`0x2751e20`), after `UnlockTechnologies` (the research
choice) and the special projects:

- **`BuildArmies`** (`0x27525d0`) when the type's AI has `construction` or `limited_construction`
  and the country was not human recently: two unsynced AI draws (`CAIModule::GetRandomInt`, the
  script scopes); then each colony of the country without an army queued, on a planet it owns:
  each army type the strategy's list 10 (BUILD_ARMY, id = the army type's index in the database)
  wants scores `1 - queued / (wanted + queued)` (x 10 at war for a type that is not defensive), the
  best kept (a tie: one draw, odd takes the new one); `NAIUtil::GetBestSpeciesForArmyType`; posted
  with `AddAICommandWithCostAndUpkeepForPosting` (the armies budget, expenditure and upkeep).
- **`BuildShips`** (`0x2753350`) with `construction` or `limited_military_construction`:
  `BuildColonizer` (when the AI has colonize data, not in war mode), then
  `BuildShipOfOwnerType` (`0x2764b40`) for the country (or its federation's or the galactic
  community's fleet when it leads them):

  ```
  owned, queued = CountOwnedShips, CountQueuedShips (per size)
  for each ship size in the database's order whose list-9 value (BUILD_SHIP, id = the size's
          index + GetShipSizeBuildStrategyOffset) is > 0:
      design = GetOrRequestDesign(size)                          (0x2766270)
      skip unless valid and of that size
      cost = the design's cost (CShipGrowthStageEconomicUnit, the country's node)
      CanAffordExpenditure(the size's economic category, cost), else a cheaper design is asked for
      not a colonizer (BuildColonizer's), not a constructor or science ship when human recently
      CShipDesign::CanCountryBuild
      ratio = (owned + queued) x the size's naval cap usage / wanted (a size family: the family's)
      each of the country's shipyard queues with room (CConstructionQueue::CanAddItem):
          the lowest ratio wins (a tie: the queue with fewer items)
  the winner: PostBuildCommand (one ship a day at most)
  ```

  `GetOrRequestDesign`: one unsynced draw for the role
  (`SShipDesignPreferences::GetEffectiveRoleForShipSize`); a size without roles (constructor,
  science ship) takes `CCountry::GetLatestShipDesign`; with roles, the minister's
  `SShipSizeDesignInfo` of the size (a name and a date, not saved) gives the design of that name
  while it is younger than `SHIP_DESIGN_STALE_MONTHS`, else `RequestNewShipDesign` (a first entry
  draws the class name, `TakeRandomShipClassNameForDesign`).

**What the game did** from 2210.01.01 in 180 days (the headless game's queues every 2 days to day
75 and every 10 days after): six ships ordered and no army.

| country | posted | design | note |
|---|---|---|---|
| 16777221 | 2210.01.23 | 16779209 (corvette, new) | the day after its first AI month (01.22): its first budget |
| 16777217 | 2210.02.06 | 16777369 (corvette, existing) | the day its shipyard's corvette was done |
| 16777224 | ~2210.05.26 | 16779214 (corvette, new) | |
| 16777217 | ~2210.06.19 | 16777378 (constructor, existing) | |
| 16777218 | 2210.06.20 | 16779207 (corvette, new) | |
| 16777219 | 2210.06.21 | 16779208 (corvette, new) | |

(dates from the items' progress at 1.0 or 1.25 a day; "~" where the item was first seen days
after it was posted). 6's second starport upgrade (2210.06.10) is the stations' port's.

17 designs were made in those days (corvettes, constructors, starbase stations): the AI's
designer. The strategy's list 9 keeps its values at load (16777217: corvettes 7, constructors 1)
until an order takes one off.

## 8. The port

| file | |
|---|---|
| `engine/construction.lua` | the speeds and the finishing of ships, armies and starbase items (above); the planet items' draws and on_actions; `STELLAR_SHIPBUILD=off` leaves all of it out (the baseline of a check) |
| `engine/fleets/create.lua` | `create.allocate` (ids), `ship`, `fleet`, `add_ship`, `enter_orbit`, `find_merge_fleet`, `around_orbital` (the shipyard's path), `on_ship_built`, `station` (a station's ship and fleet, for `engine.fleets.stations`), `hit_points`, `design_info` (API at the top of the file) |
| `engine/ai/shipbuilding.lua` | `daily(country, today, commands)` from `engine/ai/init.lua` after the research: `build_armies`, `build_ships` (`get_or_request_design`, `ship_table` the design's cost, `shipyards`, the strategy lists' value and decrement); the orders through `engine.ai.economy.orders` |
| `simscript/eval.lua`, `engine/interface.lua` | `used_naval_capacity_percent` (the AI budget's alloys entries read it) |

The AI's designer (`engine/ai/designer.lua`), list 9 (`engine/ai/navy.lua`) and the order's
upkeep check are docs/ai_fleets.md (`STELLAR_AI_DESIGNS=latest` lets the country's latest design
of the size stand in for the designer's).

## 9. Checks

2210.01.01 + 180 days against the headless game's 2210.07.01 (`fleetorders/t1798.gamestate`),
with `STELLAR_SHIPBUILD=off` as the baseline in the same tree (the stations' port included in both):

| | off | on |
|---|---|---|
| random draws (the game: 4,755,436) | 4,715,343 | 4,725,089 |
| all fields equal / differ | 722,948 / 12,921 | 723,366 / 13,265 |
| ships: in both, only the game's; fields equal / differ | 2,517, 29; 108,194 / 3,178 | 2,526, 20; 108,466 / 3,257 |
| fleet | 824, 8; 57,669 / 3,146 | 827, 5; 57,815 / 3,361 |
| army | 422, 7; 5,714 / 0 | 425, 4; 5,730 / 27 |
| starbases | 1,220 / 30 | 1,220 / 30 |
| fleet_template | 1,122 / 11 | 1,125 / 8 |
| construction queues | 31,882 / 36 | 31,885 / 33 |
| construction items | 70 / 42 | 70 / 10 |
| country | 223,191 / 4,377 | 223,167 / 4,431 |

(Before both ports, the same comparison stood at 719,675 / 14,179 and 4,692,845 draws.)

The game's new ships in those days (54 made, 12 gone; `newclass.py`): 4 from shipyards (2510
and 2511 from the items at load; 2521, 16777221's corvette of a new design, and 2523,
16777217's second corvette, from the AI's orders), 3 army transports (all from the items at
load), 26 stations built by construction ships (the stations' port), 21 space fauna (events).
The simulation makes 2510 and 2511 (the game's ids, days and fleets) and the three transports
(the game's days), not 2521 and 2523 (no design; the second corvette's queue goes to a
constructor), and four constructors the game does not build (49 on 03.11, 16777218 on 03.20 and
05.20, 16777217 on 04.06).

The two ships under way at load come out as the game's at 2210.02.08 (`objcmp.py` on the game's
`d37` and the simulation's state): ids 2510 (into fleet 7) and 2511 (fleet 810), sections,
weapons, hit points, `reserve`, construction date, the template's new design; what differs is the
name drawn (the stream is not the game's), the ships' turn and move to their formation place,
the fleets' military power. The three armies under way come out on the game's days (02.20, 03.18,
03.20) with the game's names and fields but morale (the game's grows from below its maximum);
the first transport and its fleet 814 are the game's (`TRANS_FLEET_NAME` 7), the later ones get
other ids as the stations' ships come first.

The AI: the simulation orders 4 ships (constructors: 16777218 on 01.20 and 03.20, 49 on 01.21,
16777217 on 02.06) and no army, where the game orders the six ships above and no army. With
`STELLAR_AI_DESIGNS=latest` (the latest design standing in for the designer's) it orders 16
ships, 16777217's corvette on 02.06 among them, but every AI orders a corvette in its first
month. Answered in docs/ai_fleets.md section 3: the game's ships budgets are far smaller (the
ship upgrades' and colonies' entries take their share, and energy upkeep is weighed in the
country's pool); with them the simulation orders the game's ships on the game's days.

## 10. Not ported

- The size families, `BuildColonizer`, `DisbandShips`, the federation's and galactic community's
  ships, the military minister's fleet groups and merges, list 10 rebuilt each month
  (`CreateArmyBuildData`); the designer and list 9 are ported (docs/ai_fleets.md).
- Military power (the fleets' and countries' `military_power`, `diplomacy_weight`), the ships'
  experience, rarity modifiers, arkships, colony ships' colonies.
- The station design's regeneration on a starbase upgrade (`UpgradeStationDesign`) and the
  starbase's cached modifiers.
- The new ship's movement to its formation place in its fleet.
