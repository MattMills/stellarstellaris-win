//! Construction and queues.
//!
//! Replaces `CConstructionManager::DailyUpdate` (`0x8fc700`: `CConstructionQueueItemManager::DailyUpdate`,
//! `CConstructionQueueManager::DailyUpdate` (`0x8fb830`), `UpdateCachedData`; ship and starbase
//! queues), `CColony::DailyUpdateSerialHandleConstruction` (buildings), `CStarbaseManager::DailyUpdate`,
//! `CMegaStructure::DailyUpdateSerial`, and the command that queues a buildable
//! (`CAddBuildableToQueueCommand`, `0xac9ee0`).

use crate::state::{Construction, Id, World};

/// Ship, starbase and megastructure queues: not modelled.
pub fn daily_manager(_world: &mut World) {}

/// Pays the cost and queues a building; false if unaffordable or unknown.
pub fn queue_building(world: &mut World, colony: Id, building: &str) -> bool {
    let Some(def) = world.defs.buildings.get(building).cloned() else { return false };
    let Some(owner) = world.colonies.get(&colony).map(|c| c.owner) else { return false };
    let Some(country) = world.countries.get_mut(&owner) else { return false };
    if !country.stockpile.covers(&def.cost) {
        return false;
    }
    country.stockpile.sub_all(&def.cost);
    world.colonies.get_mut(&colony).unwrap().construction.push_back(Construction {
        building: building.to_string(),
        days_left: def.build_days.max(1),
    });
    true
}

/// One day of the colony's first queue item; returns the building finished today.
pub fn daily_colony(world: &mut World, colony: Id) -> Option<String> {
    let c = world.colonies.get_mut(&colony)?;
    let item = c.construction.front_mut()?;
    item.days_left -= 1;
    if item.days_left > 0 {
        return None;
    }
    let done = c.construction.pop_front()?.building;
    c.buildings.push(done.clone());
    Some(done)
}
