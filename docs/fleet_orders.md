# Fleet orders (4.5.2)

How a fleet keeps its orders, how each order goes on day by day, and what finishing one does to the
world. Surveys first (the commonest order), then the others found in the saves. Read from the GOG
4.5.2 build and its PDB (addresses are GOG RVAs); **[V]** = read in the disassembly, **[I]** =
inferred from the saves or the headless game's outputs. Ported in `sim/lua/engine/fleets/orders.lua`
(the queue, the orbit and move sub-orders, the station and return orders) and
`sim/lua/engine/fleets/survey.lua` (surveys, anomalies, anomaly research).

## The save's form

```
fleet = { <id> = { ...
    order_id = <the next order id: CFleet::_NextOrderID>
    current_order = { <type> = { <its own fields>  sub_order = { <type> = { ... } }
                                 can_reach = yes  order_id = <id>  commissioner = 4294967295 } }
    order = { <type> = { ... }  <type> = { ... } ... }          # the queue, CFleet::_OrderQueue
    ... } }
```

`current_order` is `CFleet::_pCurrentOrder` (+0x2c8), `order` the queue (+0x2d0), both left out when
empty. An order writes its own fields first, then `CFleetOrder`'s (`sub_order`, `can_reach`,
`order_id`, `commissioner`). A sub-order has no `order_id`.

## The order classes **[V]** (names, save tokens)

`CFleetOrder` (40 bytes: `_pSubOrder`, `_bForced`, `_CanReach`, `_nOrderID`, `_nToken`,
`_Commissioner`, `_FromAutoMove`) and its virtual table: `IsValid` (+56), `CanQueue` (+64),
`OrderQueued` (+72), `OrderUnQueued` (+80), `StartOrder` (+88), `CancelOrder` (+96), `TickOrder`
(+104), `Finish` (+112), `CreateReplacementOnAutoCancel` (+120), `ShouldCancel` (+168), `IsDone`
(+176), `GetProgress` (+224), `GetNeededProgress` (+232).

Save tokens of the order types (tokens452): `move_to_system_point_order`, `orbit_planet_order`,
`build_orbital_station_order`, `colonize_planet_order`, `research_anomaly_order`,
`build_space_station_order`, `analyze_ftl_trail_order`, `survey_planet_order`, `combat_order`,
`upgrade_design_fleet_order`, `collect_data_fleet_order`, `collect_resource_fleet_order`,
`collect_resource_and_data_fleet_order`, `repair_fleet_order`, `return_fleet_order`,
`assist_detection_order`, `active_reconnaissance_order`, `research_discovery_order`,
`evade_hostiles_order`, `follow_order`, `land_armies_order`, `merge_fleet_order`,
`aggressive_stance_fleet_order`, `auto_explore_order`, `automate_construction_ship_order`,
`auto_patrol_order`, `build_megastructure_fleet_order`, `scripted_fleet_order`,
`upgrade_design_at_orbitable_fleet_order`, `destroy_planet_order`, the planet killer orders,
`explore_bypass_order`, `use_bypass_order`, `lock_bypass_order`, `jumpdrive_order`,
`quantum_catapult_order`, `excavate_archaeological_site_fleet_order`,
`upgrade_design_at_starbase_fleet_order`, `explore_astral_rift_fleet_order`, `astral_jump_order`,
`phase_fleet_order`, `send_gravity_snare_order`, `capture_space_critter_order`, the cosmic storm
orders, `terraform_fleet_order`, `scripted_catapult_order`, `scripted_survey_order`,
`automate_fleet_order`. `survey_planet_order` is `CSurveyDepositHolderFleetOrder`.

In the saves:

| order | 2210.01.01 at load (sub-orders included) | issued by the game in 180 days (seen in 7 snapshots) |
|---|---:|---:|
| `survey_planet_order` | 211 | 37 |
| `aggressive_stance_fleet_order` | 74 | 8 |
| `move_to_system_point_order` | 46 | 45 |
| `build_orbital_station_order` | 23 | 23 |
| `orbit_planet_order` | 18 | 9 |
| `research_anomaly_order` | 4 | 9 |
| `colonize_planet_order` | 2 | |
| `excavate_archaeological_site_fleet_order` | 1 | |
| `return_fleet_order` | | 2 |

## The queue **[V]**

**Adding** (`CFleet::AddOrder`, `0xc69dd0`; the AI's and the player's commands):
- refused at 100 orders (current + queued);
- the order takes the fleet's `order_id`, which goes up by one;
- refused for a fleet whose property bit 3 is set unless the order is forced, or when `CanQueue`
  says no;
- the current order cancelled if it is the token 13056 one (**[I]**: the aggressive stance);
- in front (the AI's flag): the current order's sub-order cleared, the current order back in the
  queue's front, the new one before it; else at the queue's end; `OrderQueued`;
- no current order and the new one first in the queue: started at once.

**Starting** (`CFleet::StartFirstQueuedOrder`, `0xc6a0c0`): with no current order, the queue's first
leaves the queue, becomes the current order, `StartOrder`; then `CFleetOrder::OnShipOrder`
(`0xcd97a0`): a civilian fleet (property bit 1) with ships draws **two** values (the scopes) and fires
`on_ship_order` (this = the ship, from = the country). Armadas pass the order to their fleets.

**Each day** (`CFleet::DailyUpdateSerial` `0xc5ff60` -> `CFleet::HandleOrders` `0xc62460`, the fleets'
serial part of the daily ships/fleets/armies phase, fleet by fleet in the database's order):
1. no current order: the first queued one starts; that is the day;
2. while the current order `ShouldCancel`: its replacement (`CreateReplacementOnAutoCancel`) added,
   `CancelOrder`, `OrderUnQueued`, deleted, the next one started;
3. not `IsDone`: `TickOrder`;
4. `IsDone` (also right after the tick): `Finish`, the order deleted, the next queued one started the
   same day (and not ticked that day).

`CFleet::CancelCurrentOrder` (`0xc69760`) is what a `StartOrder` calls when the order is not possible.

## Surveys: `CSurveyDepositHolderFleetOrder`

Fields: `deposit_holder = { type id }` (`CMetaRef<CDepositHolder>`: type 0 a planet, 1 an astral
rift, 2 a ship, 3 ...), `progress` (CFixedPoint).

**Start** (`StartOrder`, `0xce39a0`): when `IsPossible`, one `TickOrder` then `progress = 0`; else the
fleet's current order cancelled **[V]**.

**A day** (`TickOrder`, `0xce3a00`) **[V]**:
- unless the fleet has the scripted override 17906: a civilian fleet of exactly one ship whose ship
  is a science ship (`CShip +0x8c0 == 3`);
- in orbit of the planet (the fleet's orbit target) and its movement state 2 (`move_idle`): the
  sub-order cleared and

  `progress += SCIENCE_SHIP_SURVEY_SPEED_MULT * (1 + science_ship_survey_speed + science_ship_survey_speed_uninhabitable)`

  in CFixedPoint, truncated. The modifiers are the head ship's (`CShipSize::GetModifierValue`
  `0xd28680`, modifier types 94 and 95: the modifier plus its ship-size variant
  `shipsize_<size>_science_survey_speed[_uninhabitable]`); the `_uninhabitable` one only on a
  planet that is not colonizable (`CDepositHolder::IsColonizable`: no owner, and a colonizable
  planet class);
- elsewhere: the orbit sub-order ticked, or made (`COrbitPlanetFleetOrder` of the planet, `star` the
  system's star) and started.

**Done** (`IsDone`, `0xce4be0`) **[V]**: the fleet's country auto-surveys the system
(`CCountry::HasAutoSurveyedSystem` `0x717370`: a country type without `needs_survey = yes`, or a
system it owns), has surveyed the holder already, the system cannot be surveyed
(`CGalacticObject::CanSurvey`, not ported), or `progress >= GetNeededProgress` (`0xce4ad0`):
`BASE_SURVEY_TIME * survey_time_factor` of the planet class (30 days, 15 for asteroids).

**Finish** (`0xce3d30`) **[V]**, in this order:
1. nothing for a fleet without ships or a holder that is gone; the country is the fleet's controller;
2. unless the system is auto-surveyed: two draws (the scopes), then `on_survey_planet` (this = the
   ship, from = the planet) or `on_survey_astral_rift`;
3. `CCountry::AddSurveyedDepositHolder` (`0x71b0d0`): nothing when the holder is in the country's
   `surveyed_deposit_holders` already; else inserted in order (type, then id), **three** draws (the
   scopes) and `on_planet_surveyed` (this = the planet, from = the country, fromfrom = the fleet),
   `on_astral_rift_surveyed` or `on_ship_surveyed`;
4. whether every holder of the system is surveyed now (for the message; a telemetry event for the
   local human);
5. auto-surveyed: nothing more;
6. the fleet's leader (`CFleet::GetLeader`: its ships' leader) gains
   `LEADER_SCIENTIST_SURVEY_EXPERIENCE` (10) through `CLeader::AddExperience` (docs/leaders.md);
7. a planet: `CPlanet::OnSurvey(ship)` (the anomaly roll, below); if the planet then has an anomaly
   for the country (`CPlanet::HasAnomaly`: an anomaly, and the country is its `surveyed_by`), the
   leader gains `LEADER_SCIENTIST_SURVEY_EXPERIENCE` again; when all the system's planets and astral
   rifts are surveyed, `CGalacticObject::OnFullySurveyed` (`0x86e790`): with a fleet two draws and
   `on_system_survey_ship` (this = the ship, from = the system), then three draws and
   `on_system_survey` (this = the country, from = the system, fromfrom = the fleet);
8. unless the fleet has property bit 5 (cleared by `CFleet::ReturnFromMIA`): `CPlanet::LeaveOrbit`
   (the fleet out of the planet's `planet_orbitals`, its `movement_manager.orbit` emptied).

Messages (`MESSAGE_FLEET_SYSTEM_FULLY_SURVEYED`, `MESSAGE_FLEET_ORDER_ANOMALY`) are not ported.

### The planet's survey and its anomaly: `CPlanet::OnSurvey(ship, forced)` (`0xe0b040`) **[V]**

- not forced: done once: `binary_flags` bit 2 (the save writes `binary_flags` when it is not its
  default 64: 64 + 4 = 68 after a survey); in a system that has an owner other than the ship's
  controller nothing more;
- `CPlanet::OnSurvey(country)` (`0xe0af90`): `surveyed_by` (`_AnomalyOwner`, `+0xbe0`) set if it is
  not; with an anomaly already, the planet added to the country's `events.anomalies`;
- no roll with `binary_flags` bit 3, or an anomaly already;
- one draw, the seed of `CAnomalyTypeDatabase::GetRandomAnomalyFor` (`0x841f50`), whose own stream is
  a `CNoiseRandom` (position `noise32(seed, 0x5EA6BA9F)`, seed 0, the galaxy generator's form,
  `engine.newgame.rng.stream`):
  - chance = `(ANOMALY_SPAWN_CHANCE + the country's accumulated_anomaly_spawn_chance) * (1 +
    ship_anomaly_generation_chance_mult [+ _uninhabitable])`, the head ship's modifiers (types 92,
    93);
  - its first value: `(v1 % 100000) * 100 >= chance * 100`: no category;
  - else `CollectEligibleAnomalies` (`0x842310`), in the database's order: a category for both AIs
    and humans (`should_ai_and_humans_use`), else for an AI (`should_ai_use`) or a human; not active
    on one of the country's anomaly planets; `CanSucceed` (`0x83ff50`: an `on_success` outcome of
    weight at least 1, outcomes with their max-once flags `anomaly_outcome_happened_<event>` set
    weigh 0 **[I]** (the flag's name)); `CalcSpawnChance` (`0x840140`: 0 once spawned, the global
    flag `anomaly_<key>` for `max_once_global`, the country's for `max_once`; else `spawn_chance`,
    scope the planet, from the ship) above 0;
  - a category by weight with the second value (`GetWeightedRandomInternal<CFixedPoint>`
    `0x1b4ad80`: `v2 % total`, the first whose running sum passes it);
- no category: the country's `accumulated_anomaly_spawn_chance` (`modules.standard_event_module`)
  + `ANOMALY_SPAWN_CHANCE_INCREMENT`;
- a category: one draw; `% 100000` below its `null_spawn_chance`: nothing spawns, its max-once flags
  set; else the accumulated chance back to 0 (left out of the save at 0), `CPlanet::SetAnomaly`
  (`anomaly = "<key>"`, the planet into its `surveyed_by` country's `events.anomalies`), two draws
  (the scopes), `CAnomalyType::OnSpawn` (`0x840910`): the max-once flags, then `on_spawn` (this = the
  planet, from = the ship).

## Anomaly research: `CResearchAnomalyFleetOrder` **[V]**

Fields: `planet`, `progress` (left out at 0).

- start (`0xce5d70`): one tick, then `progress = 0`;
- a day (`0xce5d90`): a civilian fleet of one science ship, in orbit of the planet, its ship idle
  (`CShip::IsIdle` `0xca4590`: at its target coordinate and turned to within 0.1 of its
  `post_move_angle`), a leader on the ship: `progress += CAnomalyType::GetResearchAnomalySpeed`
  (`0x83fa70`: 1 + `ship_anomaly_research_speed_mult` [+ `_uninhabitable`], types 90 and 91 with
  their ship-size variants, and the category's own research speed modifier: not ported); else the
  orbit sub-order;
- done (`0xce64d0`): `progress >= GetNeededProgress` (`0xce6b60`): `SCIENCE_SHIP_ANOMALY_RESEARCH_DAYS`
  at index `count / 2 + level - leader level - bonus_skill_level`, within the list (equal levels:
  120 days; one level above: 100);
- finish (`0xce6550`): `LEADER_SCIENTIST_SUCCESSFUL_ANOMALY_RESEARCH_EXPERIENCE` (50);
  `CAnomalyType::OnResearchComplete` (`0x840350`): two draws (the scopes), then `OnSuccess`: an
  outcome by weight (`NRandomListImpl::ExecuteRandomList`; one draw **[I]**), its max-once flag, its
  event (`anomaly_event`: this = the ship, from = the planet); then `CPlanet::SetAnomaly(none)`.

## The other orders

- **`orbit_planet_order`** (`COrbitPlanetFleetOrder`, `0xcdb660`): out of another orbit, a
  `move_to_system_point_order` to a free slot (`CalcFreeOrbitCoordinateInternal`; **[I]** from the
  saves: slot 0 at + (0.33 size + 2.7) on both axes; a starbase at its star + (d + 9, -(d + 9))),
  then `EnterOrbit` (`planet_orbitals = { <slot> = <fleet> }`, `movement_manager.orbit = { orbitable
  index }`); done in orbit (`IsDone` `0xcdc150`: `CFleetMovementManager::IsInOrbit`); `Finish`
  merges fleets for the merge option (none here).
- **`move_to_system_point_order`** (`CMoveToSystemPointFleetOrder`): the movement manager moves the
  fleet (`engine.fleets.movement`); done at the coordinate (`IsDone` `0xcdad20`).
- **`build_orbital_station_order`** (`CBuildOrbitalStationFleetOrder`): in position,
  `progress += CONSTRUCTION_SHIP_WORK_SPEED_MULT` a day (1, **[I]**: the modifiers it reads not
  traced), done at 100 (`CFleetOrder::GetNeededProgress` `0x1b1140`: 10000000); the station it builds
  (`Finish` `0xce0290`) is not ported: the order ends, the station is counted.
- **`return_fleet_order`** **[I]** (`exclude_allied home_base`, an orbit sub-order of a starbase): to
  the starbase of the country's capital system.
- **Kept, never run:** `aggressive_stance_fleet_order` (the military AI's targets), 
  `colonize_planet_order` (colonization), `excavate_archaeological_site_fleet_order` (archaeology).

## The API (`engine.fleets.orders`)

`orders.issue(fleet, order[, opts])` (an order in the save's form; `opts.front`), and
`orders.survey(fleet, planet)`, `orders.survey_system(fleet, system)` (every planet the country has
not surveyed, the nearest first, **[I]** from the queues in the save), `orders.research_anomaly(fleet,
planet)`, `orders.orbit(fleet, planet)`, `orders.move_to(fleet, { x, y, origin })`,
`orders.return_to_base(fleet)`; `orders.current`, `orders.queue`, `orders.cancel_current`,
`orders.clear`; `orders.daily(host, date)` in the daily `ships_fleets_armies` phase
(`engine.systems`). `STELLAR_FLEET_ORDERS=off` turns them off (for comparisons).

The triggers `is_surveyed = { who status }` and `has_anomaly` read them (simscript/eval.lua,
`E.is_surveyed`, `E.has_anomaly`).

## Check

Against the headless game from `autosave_2210.01.01` (`/opt/stellaris-headless/out/fleetorders/`,
`t<ticks>.gamestate` for 0, 6, 16, 56, 106, 306, 906 and 1,798 ticks), the simulation without
movement (`engine.fleets.movement` not there yet) and with the AI's exploration orders
(`engine.ai.exploration`):

- **Surveys in progress at load** (13 fleets in orbit): after one day every progress equals the
  game's (13 of 13; 0.575 to 0.95 a day); after 11 days too. Completion days: 12 of 13 equal the day
  the game's own progress gives (day 1 to 46, consistent with every snapshot); the 13th (fleet
  33554951, planet 2836) the game finished by day 31 instead of 41, its country having the planet
  surveyed another way first (`IsDone`).
- **After 11 days** (game 106 ticks, simulation 11 days): the same 4 planets changed (`surveyed_by`,
  `binary_flags` 68), the same 6 `surveyed_deposit_holders` added to the same 4 countries, the same
  `accumulated_anomaly_spawn_chance` (0.0075 -> 0.0125, 0.0425 -> 0.045, 0.0025, 0.015 -> 0.0175),
  the same `events.anomalies`, the same 6 scientists with the same experience (680, 310, 876, 635,
  732, 634: 10 a survey times their experience gain).
- **Anomaly research in progress at load** (2): one a day as the game, both finished (days 50 and
  75 by the table: 100 days, one level above).
- **Station building in progress at load** (23): 14 finished in both; the other 9 need to move.
- **The orders present at load** (336, separated from the game's later ones by `order_id`: below the
  fleet's `order_id` counter at load): 29 done in both, 228 pending in both (213 with the same
  progress, 15 that the game had moved on), 79 done only in the game, every one of them needing
  movement (52 surveys of the next planet, 18 moves, 4 stations, 2 research, 1 colonization, 1 orbit,
  1 aggressive stance). The game issued 133 orders after the load (37 surveys, 45 moves, 23 stations,
  9 research, 9 orbits, 8 aggressive stances, 2 returns); the simulation's AI (engine.ai.exploration)
  issued 289-290 (about 284 returns, 6 research), executed through the API.
- **Store by store** over 1,798 ticks (`examples/diff`, fields differing, `STELLAR_FLEET_ORDERS=off`
  -> on, the same code otherwise): all stores 14,823 -> 14,595; planet 232 -> 197, fleet 3,264 ->
  3,180, country 6,624 -> 6,532, leaders 119 -> 115, deposit 0 -> 0; 0 phase errors either way. The
  draws: 4,692,126 -> 4,692,820 (the game 4,755,856), of which 600 the `on_ship_order` scopes of the
  300 orders started (283 of them the AI's returns, which the game gave twice).
- On_actions fired over the 180 days: `on_survey_planet` 13, `on_planet_surveyed` 13,
  `on_system_survey_ship` 2, `on_system_survey` 2, `on_ship_order` 300.

## Not ported

- Movement (`engine.fleets.movement`, another part): without it, an order whose fleet must move waits.
- The station a construction ship builds, colonization, archaeology, the military orders.
- `CGalacticObject::CanSurvey`, scripted overrides, armadas, `ShouldCancel` of each order, the
  messages.
- The category's research speed modifier; `ExecuteRandomList`'s draw (one assumed).
- Surveyed holders added by intel (`CCountry::DailyUpdateSerial` also calls
  `AddSurveyedDepositHolder`): most of the game's new `surveyed_deposit_holders` in 180 days come from
  there, not from surveys.
