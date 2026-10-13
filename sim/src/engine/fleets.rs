//! Fleets, movement and pathfinding (deferred: a stub).
//!
//! Replaces `CFleetMovementManager::MicroUpdate` (`0xe25160`, every tick: parallel
//! `CFleetOnlyUpdateOnlyChangeSelfPrivateFunc`, `CFleetMoveUpdateFunc`, `UpdateFleetMovementSerial`,
//! parallel `SShipMoveUpdateFunc` / `SShipMoveFinalizeFunc`), `CFleet::MicroUpdateSerial`
//! (`0xc5f8e0`), `CFleet::DailyUpdateHandleOrderPathfinding` (daily, parallel, with the random pool),
//! `CFleet::DailyUpdateSelfDontReadOthers`, `CFleet::DailyUpdateSerial` (`0xc5ff60`), the fleet order
//! classes (`CFleetOrder` subclasses, virtual), `CAStarAlgorithm<...>` over the hyperlane graph and
//! `CBypass::CalcConnections` (gateways, wormholes). Class census about 268 k instructions.
//!
//! The stub: a fleet with a destination advances `speed_per_tick` of a jump per tick and arrives.

use crate::engine::events::{CallIn, ON_ENTERING_SYSTEM};
use crate::fixed::Fixed;
use crate::script::Scope;
use crate::state::World;

/// One tick of movement; returns the arrivals (`on_entering_system`).
pub fn micro_update(world: &mut World) -> Vec<CallIn> {
    let mut calls = Vec::new();
    for (id, f) in world.fleets.iter_mut() {
        let Some(dest) = f.destination else { continue };
        f.progress += f.speed_per_tick;
        if f.progress >= Fixed::ONE {
            f.system = dest;
            f.destination = None;
            f.progress = Fixed::ZERO;
            calls.push(CallIn::on_action(ON_ENTERING_SYSTEM, Scope::Fleet(*id)));
        }
    }
    calls
}

/// Daily order handling and pathfinding with the random pool: not modelled.
pub fn daily_pathfinding(_world: &mut World, _pool: &[i32]) {}
