//! Planets and colonies.
//!
//! Replaces `NColonyUpdate::DailyParallelUpdate` (`0xe3a340`) -> `CColony::DailyUpdateSelfDontReadOthers`
//! (`0xddbe50`: invalid pops, employable pops, buildings, species cache, triggered modifiers, pop
//! triggered modifiers, unemployment, slavery, planet MTTH chances), `NColonyUpdate::DailySerialUpdate`
//! (`0xe3a470`) -> `CColony::DailyUpdateSerial` (`0xdc2490`: jobs, colony on_actions, construction,
//! events, branch offices, ground combat), `CPlanetManager::DailyUpdate` and the monthly
//! `NColonyUpdate::MonthlyUpdate`. Districts, zones, deposits and habitability are not modelled.

use std::collections::BTreeMap;

use crate::engine::{construction, events::CallIn, events::ON_BUILDING_COMPLETE, pops};
use crate::script::Scope;
use crate::state::{Id, World};

/// Job slots from the colony's buildings.
pub fn job_slots(world: &World, colony: Id) -> BTreeMap<String, u32> {
    let mut slots = BTreeMap::new();
    if let Some(c) = world.colonies.get(&colony) {
        for b in &c.buildings {
            if let Some(def) = world.defs.buildings.get(b) {
                for (job, n) in &def.jobs {
                    *slots.entry(job.clone()).or_insert(0) += *n;
                }
            }
        }
    }
    slots
}

/// The serial daily update of one colony: jobs, then construction. Returns the call-ins.
pub fn daily_serial(world: &mut World, colony: Id, job_order: &[String]) -> Vec<CallIn> {
    let slots = job_slots(world, colony);
    pops::update_pop_jobs(world, colony, &slots, job_order);
    let mut calls = Vec::new();
    if construction::daily_colony(world, colony).is_some() {
        world.modifiers.dirty = true; // CColony::InvalidateModifier
        calls.push(CallIn::on_action(ON_BUILDING_COMPLETE, Scope::Colony(colony)));
    }
    calls
}
