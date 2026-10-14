# Construction queues (4.5.2)

How the game advances construction each day and finishes what's built. Read from the GOG 4.5.2
build. **[V]** = read in the disassembly, **[I]** = inferred from the saves. Ported in
`sim/lua/engine/construction.lua`. The AI's orders that fill the queues are docs/ai_economy.md.

## The save's form

```
construction = {
    queue_mgr = { queues = { <id> = { items = { <item ids> } owner location = { type id }
                                      simultaneous type disabled } } }
    item_mgr = { items = { <id> = { queue paying_country progress progress_needed resources
                                    buildable_<kind> = { ... } } } }
}
```

A buildable's `planet` is a COLONY id in 4.5, like a pop group's `planet` and a country's
`capital`.

## The day **[V]**

`CConstructionManager::DailyUpdate` (`0x8fc700`) runs in the daily phase `construction_manager`.
It calls `CConstructionQueueManager::DailyUpdate` (`0x8fb830`), which for each queue runs
`CConstructionQueue::DailyUpdate` (`0x7b74b0`):

- a disabled queue does nothing;
- otherwise the first `simultaneous` items advance, from the last of them to the first:
  `progress += CalcProgressionSpeed`.

Then `CConstructionQueueItemManager::DailyUpdate` (`0x8fc360`) finishes the items that reached
`progress_needed`: each is taken out of its queue and its buildable's `OnFinished` runs.

## Speeds **[V]**

The planet items and armies read the modifier node of the colony they are on; the ships, the
starbase's (docs/shipbuilding.md section 2, Linux addresses).

| buildable | speed | function |
|---|---|---|
| district | 1 + `planet_building_build_speed_mult` + `planet_<district>_build_speed_mult` | `CDistrictType::CalcBuildSpeed` (`0x491190`) |
| zone | 1 + `planet_building_build_speed_mult` + `planet_<zone>_build_speed_mult` | `CZoneType::CalcBuildSpeed` (`0x47f560`) |
| building, upgrade | 1 + `planet_building_build_speed_mult` + `planet_<building>_build_speed_mult` | `CBuildingType::CalcBuildSpeed` (`0x470b80`) |
| army | 1 + `planet_army_build_speed_mult` | `CBuildableArmy::CalcProgressionSpeed` (`0xa2e170`) |
| ship | 1 + `starbase_shipyard_artificial_build_speed_mult` + `starbase_shipyard_build_speed_mult` (+ the defensive war mult) + `shipsize_<size>_build_speed_mult`, the starbase's node | `CBuildableShipBase<CBuildableShip>::CalcProgressionSpeed` (Linux `0x21a4e40`) |
| starbase upgrade | 1 + `starbase_upgrade_speed_mult` | `CBuildableStarbaseUpgrade::CalcProgressionSpeed` (Linux `0x21b5700`) |
| starbase module | 1 + `starbase_module_build_speed_mult` | Linux `0x21b3d00` |
| starbase building | 1 + `starbase_building_build_speed_mult` | Linux `0x21b2b30` |

## Finishing **[V]**

- **District** (`CBuildableDistrict::OnFinished`, `0xabad80`): the colony's district of that type gains a level; two draws (the scopes), `on_district_complete` (this = the colony).
- **Zone** (`CBuildableZone::OnFinished`, `0xabdf00`): a zone is created in its district's slot; two draws, `on_zone_complete`.
- **Building:** created and added to its zone; two draws, `on_building_complete`.
- **Building upgrade:** the building's type changes; `on_building_upgraded` (two draws [I]).
- **Ship, army, starbase upgrade, module, building:** docs/shipbuilding.md sections 3 to 5 (the
  ship made from its design and its fleet, the army and its transport, the starbase's level,
  module or building).
- **New ids:** the next index past the highest in the store, generation 0, as the game's databases hand them out **[I]**. It matches the game's ids in the check. Ships, fleets and armies take the save's free slots first (`engine.fleets.create.allocate`).

The draws of finishing, from the headless profile over 180 days: 73 in
`CConstructionQueueManager::DailyUpdate`, all in `OnFinished` (docs/shipbuilding.md section 6).

## Check

180 days, 2210.01.01 → the game's 2210.07.01: the game's new zone (132) and building (261) come
out with the same ids; districts differ on one field. The ships, armies and starbase items:
docs/shipbuilding.md section 9 (the two ships and three armies under way at load finish on the
game's days with the game's ids). `STELLAR_SHIPBUILD=off` leaves out everything ported with the
ships (their kinds, the armies' creation, the planet items' draws and on_actions).

## Not ported

- **Item kinds:** defense platforms, decisions, deposit blockers. Their items stay as they are and are counted in the report.
- The station design's regeneration on a starbase upgrade and the starbase's cached modifiers.
- Refunds of aborted items.
