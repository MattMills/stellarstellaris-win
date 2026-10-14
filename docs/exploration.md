# Exploration: each country's knowledge of the galaxy (4.5.2)

How the game keeps what each country knows of the galaxy: the systems it has visited, its sensor
coverage and the intel level it has on every system, the hyperlanes it knows, the unexplored space
of its map (terra incognita) and the fleets it sees. Read from the GOG 4.5.2 build and its PDB
(`/root/fnm_tmp` on hippo; GOG RVAs). **[V]** = read in the disassembly, **[I]** = inferred or
taken from the saves. Ported in `sim/lua/engine/exploration.lua`, called from `systems.lua`'s
`daily.countries_parallel`.

## The save's form

```
country = { 0 = {
    visited_objects = { 401 142 238 476 }        # SSafePrivate::_VisitedGalacticObjects, in the order added
    intel_level = { 0 0 ... 3 ... }              # _IntelLevelCache: one byte per system, 0 to 4
    highest_intel_level = { 0 0 ... 3 ... }      # _HighestIntelLevelCache: the shared intel, same size
    hyperlane_systems = { 401 238 476 142 504 }  # _HyperlaneCache: in the order the expansion found them
    terra_incognita = {                          # CTerraIncognitaMap (CCountry +0x2808)
        size = 256                               # NGameplay.TI_TEXTURE_SIZE
        data = { 41623 2 254 4 ... }             # runs over the size x size bytes: 0s, 255s, 0s, ... (from 0)
        systems = { 142 238 401 476 }            # _ClearededSystems, sorted
    }
    sensor_range_fleets = { 0 1 2 3 348 33554924 }   # _FleetsCanSeeInSensorRange, sorted by id
    intel_manager = { intel = { { 6 { intel = 0 stale_intel = { } } } ... } }   # CIntelManager
} }
```

An empty list is not written (the key is left out). The caches are sized by the galactic object
database (596 systems in the 2210 save) and indexed by the system's index (its id here).

## When **[V]**

`CGameState::DailyUpdate` (`0x25cde0`) runs these parallel passes over every country, after the
first `CModifierNodeManager::Update` (the sim's `daily.countries_parallel`):

| pass | functions |
|---|---|
| lambda_26 | `CCountry::DailyUpdateOnlyChangeSafePrivate` (`0x6efbf0`): `UpdateVisitedGalacticObjects` (`0x6ee430`), `CCountrySensorManager::Update` (`0xad5c90`), `UpdateIntelCache` (`0x6ec200`), detection and cloaking, `UpdateHyperlaneRange` (`0x6ec740`) |
| lambda_27 | `CCountry::UpdateHighestIntelCache` (`0x6ed240`), `CCloakingDetectionManager::UpdateHighestDetection` |
| lambda_28 | `CCountry::ClearTerraIncognitaInSensorRange` (`0x73f350`), `UpdateFleetsInSensorRange` (`0x7131b0`) |
| lambda_32 | `CCountry::DailyUpdateSelfDontReadOthers`: `CIntelManager::DailyUpdate` (`0x998860`) |
| serial | `CCountry::DailyUpdateSerial` (`0x6f0b30`): the surveys the shared intel gives (the sim's `daily.countries_serial`, before the country's events) |

Each pass reads only what the earlier ones wrote (lambda_27 reads every country's intel level of
the day), so a serial port in this order is the game's. At load, `CGameState::RecalculateCachedData`
runs `CCountry::InitCachedValues` (`0x745da0`: the sensor update, the intel cache, the hyperlane
range) and `FinalizeCachedValues` (`0x7460f0`: the highest cache, terra incognita, the fleets), the
same without the visited systems. The port runs that pass once before its first day
(`exploration.load_pass`): a save is written at tick 4, after fleets moved since the day's update,
and the game's own "just loaded" state already has the recomputed caches.

## Sensor coverage **[V]**

`CCountrySensorManager` (`CCountry +0x1270`) keeps one byte of flags per system, cleared each
update: 1 known, 2 in sensor range, 4 in the sensor range of a cloaked fleet, 8 surveyed, and 16/32
as the day's cache of "blocks sensors" / "does not". The update:

1. known: every system the country visited when its type `needs_survey`, else every system;
2. `CGameRules::HasFullSensorRange` (game rule `has_full_sensor_range`: the spy orb): every system
   in range, and nothing else;
3. `AccountSystemsInRange` (`0xad60e0`), two ranges per system (-1 = none), the larger kept:
   - owned, holdings and controlled colonies (`AccountOwnedColonies` and the two after it):
     `PLANET_SENSOR_RANGE + trunc(planet_sensor_range_add)` of the colony, flags 1|2;
   - owned fleets not MIA, at their system (`AccountFleets`): the best of their ships' sensor
     range, flags 1|2 (1|4 and the second range for a cloaked fleet);
   - armies on a planet: 1; megastructures not disabled: the type's sensor range;
   - enclaves the country has communications with: their capital's system is known
     (`AccountEnclaves`); the countries whose intel shows their capital (`CapitalLocation`) the same
     (`AccountIntel`);
   - surveyed (`AccountSurveyedSystems`): with `needs_survey`, the owned systems and those where
     the country surveyed as many deposit holders as the system has planets and astral rifts;
     every system otherwise;
4. the ranges spread (`NSensorRange::ExpandRange`, `0xad7920`): a priority queue of the ranges
   (`CPriorityQueue`, `0x760650`); each system popped gets the bit, and with a range above 1 lends
   range - 1 to its hyperlane neighbours and through its bypasses, unless it blocks sensors; a
   neighbour that blocks is never entered. Blocking is the game rule `system_blocks_sensors`
   (`CGameRules::IsSystemBlockingSensorsWithScope`: nebulae, storms, some star flags). A bypass
   lends range when its type `extends_sensors` (vanilla: wormholes), it is active, the country has
   seen the type when the type `requires_exploration` and the country needs surveys, and
   `HasPrereqs`, `NeedsExploration`, `CanPotentiallyBeUsedByCountry`, `CanBeUsedByCountry` and
   `CanPassThroughLock` hold: the port takes the country's `usable_bypasses` for the last five
   **[I]**; the range goes to its active connections' systems.

A ship's sensor range (`NShipUtil::CalcSensorRange`, `0xa14760`, cached in `CShip::_CachedSensorRange`
by `RecalcAllCachedValues`) is the design's (`CBaseDesignImplementation::AddComponentSpecialValues`,
`0xcd31a0`: the best `sensor_range` of its components) + `trunc(ship_sensor_range_add)` of the ship
(`CShipSize::GetModifierValue`); the hyperlane range the same with `hyperlane_range` and
`ship_hyperlane_range_add`. A fleet's is the best of its ships' (`CFleet::CalcSensorRange`).

`UpdateIntelCache`: the system's intel level is `TABLE[flags & 0xCF]` (`0x1423860d0`):

| flags | 0 | 1 | 2-7 | 8, 9 | 10, 11 | 12-15 |
|---|---|---|---|---|---|---|
| level | 0 | 1 | 3 | 2 | 4 | 3 |

so known 1, surveyed 2, in sensor range 3, both 4.

## Known hyperlanes **[V]**

`UpdateHyperlaneRange`: all systems with full sensor range; else a range per system: 1 for every
system of yesterday's list, `PLANET_HYPERLANE_RANGE + trunc(planet_hyperlane_range_add)` for the
owned and controlled colonies, the best ship hyperlane range of each owned fleet not MIA, 1 for
the armies on a planet, the megastructure type's hyperlane range; spread like the sensors
(`0x760850`, no blocking, through the same bypasses) and the systems listed in the order they are
popped. The order is the queue's: ascending by range with ties in insertion order (the initial
entries in index order, stable-sorted), popped from the end; a system queued again with a better
range is taken out and inserted at the upper bound of its new range.

## The shared intel **[V]**

`UpdateHighestIntelCache`, size the galaxy's:

- a country whose type `has_complete_sensor` (or with the cheat) empties the cache when it has
  one and computes it when it is empty: the cache alternates day by day (the load's pass counts),
  while `GetIntelLevel` answers 4 for every system anyway;
- for every country it has intel on (`intel_manager`) with `IntelEffectsSurveyed` (the instance
  property `faction.properties` bit 11, default yes) and communications towards it (or itself),
  the systems within that country's borders (lambda_4): the level of the system category the
  intel gives (`SystemLow/Medium/High/Full`: 1 to 4), at least 2 on an upgraded starbase with
  `MilitaryStarbases`, at least the colonies' category level (`EconomyColonies*`) on a system with
  colonies or when the system level is 3 or more. The information of an intel value is the
  `common/intel_levels` level whose range holds `trunc(intel)`, each category's levels up to it in
  `common/intel_categories` (cumulative), and the diplomatic pacts' categories
  (`GetMinIntelFromDiplomaticPacts`, `0x7ad6a0`: the port reads communications, closed borders,
  commercial, migration, research, embassy, defensive pacts, guarantees and non-aggression from
  the relations, and the federation's type **[I]**); the planets this intel surveys or
  unsurveys: below;
- then the highest of every country giving it sensor (`ListCountriesGivingSensor`, `0x713ab0`):
  its federation's members and their subjects not at war with them, or itself and its subjects,
  the overlord's when their agreement shares sensors, the countries of trade deals with a sensor
  link, its war allies (the port: the federation, subjects; no agreements or trade deals in the
  2210 save).

`GetIntelLevel` (`0x713ef0`) is 4 with complete sensor, else the highest cache; at least 2 for a
country without `needs_survey`; 1 for an unknown system a first contact of it is at.

## The surveys the intel gives **[V]**

The same pass over the intel on a country O (lambda_4, then O's controlled colonies) fills
`SSafePrivate::_NewSurveyed` and `_NewUnsurveyed`, the only places that do. For each planet of a
system within O's borders (a system with no colonies is skipped unless the second condition below
holds; one whose level is still 0 too) that nobody or O controls, and for each colony O controls:

- wanted: a colonized planet when the colonies' level is High or Full (`EconomyColoniesHigh/Full`),
  another when the system level is High or Full or the intel shows the deposits
  (`EconomyDeposits`: economy level 1, intel 30 and up);
- wanted and not surveyed (`HasAutoSurveyedSystem` or `_HasSurveyedDepositHolder`): to
  `_NewSurveyed`; not wanted, surveyed, and the planet not occupied (owner = controller): to
  `_NewUnsurveyed`.

`CCountry::DailyUpdateSerial` (`0x6f0b30`), after `UpdateContacts`, `UpdateVisited` and
`UpdatePoliciesSerial` and before the country's events, gives every holder of `_NewSurveyed` to
`AddSurveyedDepositHolder` (`0x71b0d0`: the sorted insert, three draws, `on_planet_surveyed`; the
port calls `engine.fleets.survey`'s) and every one of `_NewUnsurveyed` to
`RemoveSurveyedDepositHolder` (`0x71bb60`: out of the sorted list, nothing else), then empties both.
The lists are not emptied anywhere else: the load's pass fills them too, for the first day.

Of the 115 deposit holders the game adds in the 180 days, 53 are planets this pass wants (in the
territory of the federation partners 49, 50 and 16777223, who have intel 70 on each other), all
of them surveyed by the end; recomputed on the game's 2210.07.01 world, nothing is left to add.
They come as the partners' borders grow. The other 62 are 58 planets of unowned systems the
countries visited (science ships' surveys) and 4 in a country's own new systems.

## Terra incognita **[V]**

The map is `TI_TEXTURE_SIZE`² bytes, 0 fogged and 255 lifted. A static table
(`CTerraIncognitaMap::CreatePixelSystemOwnershipTable`, `0x995150`) gives every pixel to a system:
the galaxy's 1000 units on the texture (scale `TI_TEXTURE_SIZE / 1000`, `TransformCoordinateToPixel`
`0x994f40`: `trunc(trunc(x * scale) + size/2)`), each pixel to the system nearest in `|dx| + |dy|`
pixels (the first by index on a tie), except the circle of radius
`trunc(core_radius * scale * TI_CORE_SCALE)` around the centre (owner -1); each system's box of
pixels is kept.

`ClearTerraIncognitaInSensorRange` clears every system whose highest intel level is at least 1
(`ClearSystem`, `0x994c50`): the system is inserted in the sorted list, its fogged pixels in its box
are lifted, and once every core system is cleared the core's pixels are. The table reproduces the
2210.01.01 maps of 54 of the 55 countries from their lists alone (the 55th has 4 pixels lifted for
a system not in its list: an older table).

## Fleets in sensor range **[V]**

`UpdateFleetsInSensorRange`: every fleet `CCountry::CanSee` (`0x7141b0`), sorted by id: alive
(fewer ships removed than it has: `cached_combined_removed_ships`), not MIA, and the country's own,
or an enclave's that has communications with it, or in a system where the game rule
`can_force_see_fleets_in_system` holds (a solar storm), or at a system (`NFleetUtil::GetNearestSystem`
`0xe616d0`: in an FTL jump, the end nearer to the fleet) whose intel level is at least 3
(`HasInSensorRange`) and not hidden by cloaking (`CFleet::CalcIsHiddenFrom`; the port hides cloaked
fleets, no detection).

## Visited systems **[V]**

`UpdateVisitedGalacticObjects` drops systems that no longer exist and appends, in this order, the
systems within the borders, those of the owned colonies, of the controlled planets, of the owned
fleets (not in an FTL jump) and of the armies on a planet. Fleets entering a system also add it
and clear it from terra incognita at once (`CGalacticObject::OnFleetEntered`), which the daily
pass catches the next day; not ported.

## Check

- **At load**, 2210.01.01 (`STELLAR_LUA` probe): computed from the save's world, every field of all
  55 countries equals the headless game's `run.sh <save> 0` output: visited systems 25,854 values,
  intel levels and highest levels 32,780 each, known hyperlanes 1,324, sensor range fleets 3,750,
  terra incognita 1,610 runs and 25,880 cleared systems. Against the save itself the computed values
  differ where the save is 4 ticks old (fleets moved since the day's update: 213 sensor range
  fleets in 9 countries), on the two countries created that day (53, 54), and on the three
  countries with complete sensor (the alternating cache).
- **One day**, against the game's 2210.01.02 (`run.sh <save> 10`): all 7 fields equal in all 55
  countries.
- **On the game's own 180-day world** (its 2210.07.01 output loaded as the save): recomputed, the
  intel levels, known hyperlanes and sensor range fleets of all 53 countries equal the game's; the
  highest levels too but for the three alternating ones (the load's phase).
- **180 days** (1,798 ticks) against the headless game (`examples/diff`, the 53 countries in
  both; `STELLAR_EXPLORATION=off` for before):

| field | before | after |
|---|---:|---:|
| `highest_intel_level.[]` | 1,825 | 30 |
| `sensor_range_fleets.[]` | 942 | 928 |
| `hyperlane_systems.[]` | 346 | 321 |
| `intel_level.[]` | 34 | 29 |
| `terra_incognita.data.[]` | 514 | 514 |
| `terra_incognita.systems.[]` | 83 | 83 |
| `visited_objects.[]` | 11 | 11 |

  What is left comes from the world the passes read, not the passes: fleets do not move in the
  simulation yet (engine.fleets.movement), so the science ships do not explore, sensors stay where
  they were, the countries' new outposts and the two countries the game removes are not there.

## Not ported

- `CIntelManager::DailyUpdate`: the intel values move toward their target
  (`CIntelData::DailyUpdateThreaded` `0x7ae1a0`: `CalcTargetIntelValue`, a 30th of
  `GetIntelMonthlyChange` a day, `INTEL_CAP`); the save's values are kept.
- Detection and cloaking (`UpdateDetectionIntelCache`, `UpdateCloakingDetection`), intel reports.
- The bypass checks beyond `usable_bypasses`; sensor-sharing overlord agreements, trade-deal sensor
  links and war allies in the shared intel.
- The order of the systems within a country's borders (`CCountryBorderManager::_SystemsWithinBorder`,
  `NBordersUtil::CalcBorders`): the port takes the systems its starbases own, in index order **[I]**;
  it orders the surveys the intel adds (their draws and `on_planet_surveyed`).
- `CGalacticObject::OnFleetEntered` (visited and cleared as the fleet arrives; movement's).
