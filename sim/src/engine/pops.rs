//! Pops: jobs, growth, decline.
//!
//! Replaces `NPlanetJobs::UpdatePopJobs` (daily from `CColony::DailyUpdateSerial` and
//! `NColonyUpdate::MonthlyOrDailyUpdatePopJobsInColony` (`0xe3a740`), monthly from
//! `NColonyUpdate::MonthlyUpdate` (`0xe3a7c0`)), the monthly growth and decline
//! (`CColony::ApplyMonthlyAssembly`, `CColony::ApplyMonthlyDecline`, from
//! `CColony::MonthlyUpdateSerial` (`0xdc2c20`)), migration (`CColony::CalcAutoMigrationSafePrivate`
//! in `NColonyUpdate::MonthlyParallelUpdate` (`0xe3ac40`), `ApplyAutoMigrationResults`) and the pop
//! group daily updates (`CPopGroup::DailyUpdateSelfDoNotReadOthers` (`0x677400`),
//! `CPopGroup::DailyUpdateSerial` (`0x677800`): ethics divergence, factions; not modelled).
//!
//! Job weights are script (`weight = { }` of each job): the scheduler asks the `ScriptHost` and
//! passes the order in.

use std::collections::BTreeMap;

use crate::fixed::Fixed;
use crate::script::Scope;
use crate::state::{Id, World, POP_UNIT};

/// Base monthly growth, in pops (the game's growth rate comes from species and modifiers).
pub const BASE_GROWTH_PER_MONTH: Fixed = Fixed::from_centi(30);

/// Fills the colony's job slots in `job_order` (highest weight first) with its whole pops.
pub fn update_pop_jobs(world: &mut World, colony: Id, slots: &BTreeMap<String, u32>, job_order: &[String]) {
    let mut free = world.colony_pops(colony);
    let mut employed = BTreeMap::new();
    for job in job_order {
        let n = slots.get(job).copied().unwrap_or(0).min(free);
        if n > 0 {
            employed.insert(job.clone(), n);
            free -= n;
        }
    }
    if let Some(c) = world.colonies.get_mut(&colony) {
        c.employed = employed;
        c.unemployed = free;
    }
}

/// Monthly growth: progress toward the next pop; a finished pop joins the largest pop group (ties:
/// the lowest id). Returns whether a pop was assembled.
pub fn monthly_growth(world: &mut World, colony: Id) -> bool {
    let speed = world.modifier(Scope::Colony(colony), "pop_growth_speed");
    let Some(c) = world.colonies.get_mut(&colony) else { return false };
    if c.pop_groups.is_empty() {
        return false;
    }
    c.growth_progress += BASE_GROWTH_PER_MONTH.mul(Fixed::ONE + speed);
    if c.growth_progress < Fixed::ONE {
        return false;
    }
    c.growth_progress -= Fixed::ONE;
    let groups = c.pop_groups.clone();
    let target = groups
        .iter()
        .filter_map(|id| world.pop_groups.get(id).map(|p| (p.size, *id)))
        .max_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)))
        .map(|(_, id)| id);
    if let Some(id) = target {
        world.pop_groups.get_mut(&id).unwrap().size += POP_UNIT;
        true
    } else {
        false
    }
}
