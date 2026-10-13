//! Combat, space and ground (deferred: a stub).
//!
//! Replaces, every tick from `CGameState::MicroUpdate`: `CFleetCombatManager::CheckForNewCombats`
//! (`0xd740e0`), `CFleetCombatManager::MicroUpdateSerial` (`0xd71d50`), `UpdateShipsMainTargets`,
//! `UpdateCombatCoordinate`, `CTargeting::BuildPotentialTargetsData` (`0xa09ac0`),
//! `CShip::MicroUpdateSections` (`0xc9d030`, weapons), `CShipAura::MicroUpdateAuras`,
//! `UpdateShipParallel` (`0x2539f0`, draws with `GetIntegersForMacro`), `CStrikeCraftManager::MicroUpdate`,
//! `CMissileManager::MicroUpdateSerial`; daily: ground combat (`CColony::DailyUpdateSerialHandleCombat`,
//! `CGroundCombat`), monthly `CFleet::CheckShipsMonthlyDamage`. Class census about 139 k instructions.

use crate::state::World;

/// One tick of space combat: not modelled.
pub fn micro_update(_world: &mut World) {}
