# Fleets (4.5.2): the plan and the interfaces

Fleets are being ported in four parts, each with its own reverse engineering doc. This page is
the map: which part owns what, the interfaces between them, where each runs in the tick, and how
each is checked. It is updated as the parts land.

| part | module | doc | owns |
|---|---|---|---|
| movement | `engine/fleets/movement.lua` (+ `path.lua`) | docs/fleet_movement.md | pathfinding, sublight and hyperlane movement each tick, arrival, the fleets' `movement_manager`, ships' positions, systems' `fleet_presence`, the fleet phase's random draws |
| orders | `engine/fleets/orders.lua` | docs/fleet_orders.md | the order queue (`fleet.order`), each order's progress and completion; surveys: planets' `surveyed_by`, anomalies, deposits revealed, the country's `surveyed_deposit_holders`, the science leader's experience |
| exploration | `engine/exploration.lua` | docs/exploration.md | each country's `terra_incognita`, `hyperlane_systems`, `sensor_range_fleets`, `highest_intel_level` and intel |
| the AI's fleet decisions | `engine/ai/` (`exploration.lua`, ...) | docs/ai.md | science ships' survey targets, construction ships' outposts and starbases, ship building through the AI budget, then military movements |

## Interfaces

- **Movement:**
  - `movement.move_to(fleet_id, target)`, where `target` is `{ system = id }` or a coordinate `{ x, y, origin }`;
  - `movement.tick(host, date)`;
  - `movement.is_moving(fleet_id)`, `movement.system_of(fleet_id)`, `movement.arrived(fleet_id)`.
- **Orders:**
  - `orders.issue(fleet_id, order)`, with the order in the save's own form (the block the game writes in `fleet.order`);
  - helpers such as `orders.survey(fleet_id, planet_id)`.
  - An order whose fleet must travel asks movement to take it there.
- **The AI:** decides during `ProcessAI`, and its commands are executed after every AI has decided (`engine/ai/init.lua`). A fleet command calls `orders.issue`.
- **Optional modules:** each part calls the others only when they're there (`package.searchpath`), so each can land on its own.

## Where they run in the tick

| game | phase | part |
|---|---|---|
| `CGameState::MicroUpdate`, the fleet phase (fleet combat, update, movement), before the ship pool | `micro.update`, before `RUST.skip` | movement |
| `CFleet::DailyUpdateSerial` | `daily.ships_fleets_armies` | orders |
| the countries' sensor and intel updates | as the game does them | exploration |
| `CGameState::ProcessAI` (tick 4) | `ai.process` | the AI |

## How each part is checked

Each part is checked against the real game run headless (`headless/run.sh`, docs/random.md) from
the same save, at the same tick: `examples/diff <save> <the headless output>`. The fleets moving at
load and the orders in progress at load are checked first. The game's new orders come from its AI,
so each part separates those from its own.
