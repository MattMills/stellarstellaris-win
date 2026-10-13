//! Country upkeep and leaders.
//!
//! Replaces the rest of `CCountry::DailyUpdateSerial` (`0x6f0b30`, 866 instructions: edicts,
//! policies, elections, contacts, relay networks, envoys, ...), `CCountry::MonthlyUpdateSerial`
//! (`0x6f4b10`), the leaders' daily updates (`CLeader::DailyUpdateOnlyChangeSafePrivate` and
//! `DailyUpdateSelfDontReadOthers`, both given the daily random pool through
//! `TConstFunctorWithRandomValues` / `TFunctorWithRandomValues`, then `CLeader::DailyUpdateSerial`
//! (`0x896910`)) and `CGovernment::DailyUpdateSerial`. Only edict expiry and leader aging and death
//! are modelled.

use crate::date::{Date, DAYS_PER_YEAR};
use crate::engine::events::{CallIn, ON_LEADER_DEATH};
use crate::script::Scope;
use crate::state::{Id, World};

/// Age from which a leader can die of old age (placeholder for the game's leader lifespan).
pub const OLD_AGE_DAYS: i32 = 70 * DAYS_PER_YEAR;
/// Daily death chance after `OLD_AGE_DAYS`, per 10,000.
pub const DEATH_CHANCE_PER_10K: i32 = 10;

/// Edicts that ended today are removed.
pub fn daily_serial(world: &mut World, country: Id, date: Date) {
    if let Some(c) = world.countries.get_mut(&country) {
        c.edicts.retain(|_, end| *end > date);
    }
}

/// The leaders' parallel phase: aging, and the death roll from the daily pool. How the game picks a
/// pool entry per object was not traced; the leader id modulo the pool size is the placeholder.
/// Returns the leaders that die (handled in the serial phase).
pub fn leaders_parallel(world: &mut World, pool: &[i32]) -> Vec<Id> {
    let mut dying = Vec::new();
    for (id, l) in world.leaders.iter_mut() {
        if !l.alive {
            continue;
        }
        l.age_days += 1;
        if l.age_days >= OLD_AGE_DAYS && !pool.is_empty() {
            let v = pool[*id as usize % pool.len()];
            if v % 10_000 < DEATH_CHANCE_PER_10K {
                dying.push(*id);
            }
        }
    }
    dying
}

/// The leaders' serial phase: deaths, each an on_action.
pub fn leaders_serial(world: &mut World, dying: &[Id]) -> Vec<CallIn> {
    let mut calls = Vec::new();
    for id in dying {
        if let Some(l) = world.leaders.get_mut(id) {
            l.alive = false;
            calls.push(CallIn::on_action(ON_LEADER_DEATH, Scope::Leader(*id)));
        }
    }
    calls
}
