//! Research.
//!
//! Replaces `CTechnologyStatus::DailyResearch` (`0x818de0`, from `CCountry::DailyUpdateSerial`),
//! `CTechnologyStatus::QueueResearch`, research options (tech `weight` blocks are script: the
//! scheduler asks the `ScriptHost`, and picks with the synchronized RNG) and
//! `CTechnologyStatus::DoResearchTechnologyCompleted` (which fires `on_tech_increased` and events).
//! Each day adds a 30th of last month's research output.

use crate::date::DAYS_PER_MONTH;
use crate::fixed::Fixed;
use crate::state::{Id, Resource, ResearchSlot, World};

pub const AREAS: [Resource; 3] = [Resource::Physics, Resource::Society, Resource::Engineering];

/// Whether `area` has no current project.
pub fn needs_pick(world: &World, country: Id, area: Resource) -> bool {
    world.countries.get(&country).map_or(false, |c| {
        c.alive && c.research.get(&area).map_or(true, |s| s.tech.is_none())
    })
}

/// Technologies of `area` the country can research (not known, prerequisites known), by name.
pub fn options(world: &World, country: Id, area: Resource) -> Vec<String> {
    let Some(c) = world.countries.get(&country) else { return Vec::new() };
    world
        .defs
        .techs
        .iter()
        .filter(|(name, def)| def.area == area && !c.techs.contains(*name) && def.prerequisites.iter().all(|p| c.techs.contains(p)))
        .map(|(name, _)| name.clone())
        .collect()
}

pub fn start(world: &mut World, country: Id, area: Resource, tech: String) {
    if let Some(c) = world.countries.get_mut(&country) {
        c.research.insert(area, ResearchSlot { tech: Some(tech), progress: Fixed::ZERO });
    }
}

/// One day of research; returns the technologies completed.
pub fn daily_research(world: &mut World, country: Id) -> Vec<String> {
    let mut done = Vec::new();
    let costs: Vec<(Resource, Fixed)> = AREAS
        .iter()
        .filter_map(|a| {
            let c = world.countries.get(&country)?;
            let t = c.research.get(a)?.tech.as_ref()?;
            Some((*a, world.defs.techs.get(t)?.cost))
        })
        .collect();
    let Some(c) = world.countries.get_mut(&country) else { return done };
    for (area, cost) in costs {
        let daily = c.last_month_income.get(area).div_int(DAYS_PER_MONTH as i64);
        let slot = c.research.get_mut(&area).unwrap();
        slot.progress += daily.max(Fixed::ZERO);
        if slot.progress >= cost {
            let t = slot.tech.take().unwrap();
            slot.progress = Fixed::ZERO;
            c.techs.insert(t.clone());
            done.push(t);
        }
    }
    done
}
