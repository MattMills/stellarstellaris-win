//! The Lua -> engine effect queue.
//!
//! Engine effects (docs/simulation.md, section 4: about 610 of the 1,080 effects) change what only
//! the engine simulates. The script layer queues them; the scheduler drains the queue on the main
//! thread at the game's barriers, in FIFO order (deterministic, as multiplayer requires):
//!
//! - after every root effect, where `CRootEffect::Execute` runs `CModifierNodeManager::Update`;
//! - before a read of engine state that a pending effect changes (the host asks for a flush);
//! - at the end of every tick.
//!
//! Effects that create objects return a provisional [`Handle`] at once (the Lua side allocates
//! it, as `last_created_*` needs); later effects can target the handle; the drain resolves it to
//! the real id.

use std::collections::BTreeMap;

use crate::date::Date;
use crate::fixed::Fixed;
use crate::script::Scope;
use crate::state::{Id, Resource, World};

/// A provisional id for an object an effect creates.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Handle(pub u32);

/// The object an effect acts on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Target {
    Id(Id),
    /// The scope the effect ran in (a country target in a colony scope means its owner).
    Scope,
    /// An object created earlier in the queue.
    Pending(Handle),
}

/// The engine effects the skeleton models (a few of the game's; each maps to an effect class,
/// `CAddResourceEffect`, `CAddModifierEffect`, ...).
#[derive(Clone, Debug, PartialEq)]
pub enum EngineEffect {
    AddResource { country: Target, resource: Resource, amount: Fixed },
    /// `add_modifier`: a static modifier (`source`) with its entries, for `days` or forever.
    AddModifier { scope: Target, source: String, entries: Vec<(String, Fixed)>, days: Option<i32> },
    /// An engine effect the skeleton does not model (`create_ship`, `set_owner`, ...): counted.
    Unmodelled { keyword: String },
    AddBuilding { colony: Target, building: String },
    CreatePopGroup { colony: Target, species: String, size: i64, handle: Handle },
    ChangePopGroupSize { pop_group: Target, delta: i64 },
    GiveTechnology { country: Target, tech: String },
    CreateLeader { country: Target, handle: Handle },
    KillLeader { leader: Target },
}

#[derive(Clone, Debug)]
struct Queued {
    scope: Scope,
    effect: EngineEffect,
}

#[derive(Clone, Debug, Default)]
pub struct EngineQueue {
    pending: Vec<Queued>,
    next_handle: u32,
    resolved: BTreeMap<Handle, Id>,
    pub applied: u64,
    pub dropped: u64,
    /// Engine effects queued that the skeleton does not model, by keyword.
    pub unmodelled: BTreeMap<String, u64>,
    pub drains: u64,
}

impl EngineQueue {
    pub fn new() -> EngineQueue {
        EngineQueue::default()
    }

    pub fn push(&mut self, scope: Scope, effect: EngineEffect) {
        self.pending.push(Queued { scope, effect });
    }

    pub fn new_handle(&mut self) -> Handle {
        self.next_handle += 1;
        Handle(self.next_handle)
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    /// The id a handle resolved to (after the drain that created it).
    pub fn resolved(&self, h: Handle) -> Option<Id> {
        self.resolved.get(&h).copied()
    }

    /// Applies every pending effect in order; returns how many were applied.
    pub fn drain(&mut self, world: &mut World, date: Date) -> usize {
        if self.pending.is_empty() {
            return 0;
        }
        self.drains += 1;
        let items = std::mem::take(&mut self.pending);
        let mut n = 0;
        for q in items {
            if self.apply(world, date, q.scope, q.effect) {
                n += 1;
            } else {
                self.dropped += 1;
            }
        }
        self.applied += n as u64;
        if n > 0 {
            world.modifiers.dirty = true; // the objects' InvalidateModifier
        }
        n
    }

    fn resolve(&self, world: &World, t: Target, scope: Scope, want: Kind) -> Option<Id> {
        match t {
            Target::Id(id) => Some(id),
            Target::Pending(h) => self.resolved.get(&h).copied(),
            Target::Scope => match (want, scope) {
                (Kind::Country, Scope::Country(id)) => Some(id),
                (Kind::Country, Scope::Colony(c)) => world.colonies.get(&c).map(|c| c.owner),
                (Kind::Country, Scope::Leader(l)) => world.leaders.get(&l).map(|l| l.country),
                (Kind::Colony, Scope::Colony(id)) => Some(id),
                (Kind::Colony, Scope::PopGroup(p)) => world.pop_groups.get(&p).map(|p| p.colony),
                (Kind::PopGroup, Scope::PopGroup(id)) => Some(id),
                (Kind::Leader, Scope::Leader(id)) => Some(id),
                _ => None,
            },
        }
    }

    fn apply(&mut self, world: &mut World, date: Date, scope: Scope, e: EngineEffect) -> bool {
        match e {
            EngineEffect::AddResource { country, resource, amount } => {
                let Some(id) = self.resolve(world, country, scope, Kind::Country) else { return false };
                let Some(c) = world.countries.get_mut(&id) else { return false };
                c.stockpile.add(resource, amount);
                true
            }
            EngineEffect::AddModifier { scope: target, source, entries, days } => {
                let s = match target {
                    Target::Scope => scope,
                    Target::Id(id) => Scope::Country(id),
                    Target::Pending(_) => return false,
                };
                let end = days.map(|d| date.add_days(d));
                if entries.is_empty() {
                    world.modifiers.sources.insert((s, source.clone(), String::new()), (Fixed::ZERO, end));
                }
                for (name, value) in entries {
                    world.modifiers.sources.insert((s, source.clone(), name), (value, end));
                }
                true
            }
            EngineEffect::Unmodelled { keyword } => {
                *self.unmodelled.entry(keyword).or_insert(0) += 1;
                true
            }
            EngineEffect::AddBuilding { colony, building } => {
                let Some(id) = self.resolve(world, colony, scope, Kind::Colony) else { return false };
                if !world.defs.buildings.contains_key(&building) {
                    return false;
                }
                let Some(c) = world.colonies.get_mut(&id) else { return false };
                c.buildings.push(building);
                true
            }
            EngineEffect::CreatePopGroup { colony, species, size, handle } => {
                let Some(id) = self.resolve(world, colony, scope, Kind::Colony) else { return false };
                if !world.colonies.contains_key(&id) {
                    return false;
                }
                let p = world.add_pop_group(id, &species, size);
                self.resolved.insert(handle, p);
                true
            }
            EngineEffect::ChangePopGroupSize { pop_group, delta } => {
                let Some(id) = self.resolve(world, pop_group, scope, Kind::PopGroup) else { return false };
                let Some(p) = world.pop_groups.get_mut(&id) else { return false };
                p.size = (p.size + delta).max(0);
                true
            }
            EngineEffect::GiveTechnology { country, tech } => {
                let Some(id) = self.resolve(world, country, scope, Kind::Country) else { return false };
                let Some(c) = world.countries.get_mut(&id) else { return false };
                c.techs.insert(tech);
                true
            }
            EngineEffect::CreateLeader { country, handle } => {
                let Some(id) = self.resolve(world, country, scope, Kind::Country) else { return false };
                if !world.countries.contains_key(&id) {
                    return false;
                }
                let l = world.add_leader(id, 30 * 360);
                self.resolved.insert(handle, l);
                true
            }
            EngineEffect::KillLeader { leader } => {
                let Some(id) = self.resolve(world, leader, scope, Kind::Leader) else { return false };
                let Some(l) = world.leaders.get_mut(&id) else { return false };
                l.alive = false;
                true
            }
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Country,
    Colony,
    PopGroup,
    Leader,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fifo_and_handles() {
        let mut w = World::default();
        let c = w.add_country("a");
        let col = w.add_colony(c, "home");
        let mut q = EngineQueue::new();
        let h = q.new_handle();
        q.push(Scope::Colony(col), EngineEffect::CreatePopGroup { colony: Target::Scope, species: "human".into(), size: 100, handle: h });
        q.push(Scope::Colony(col), EngineEffect::ChangePopGroupSize { pop_group: Target::Pending(h), delta: 250 });
        q.push(Scope::Colony(col), EngineEffect::AddResource { country: Target::Scope, resource: Resource::Energy, amount: Fixed::from_int(5) });
        assert_eq!(q.len(), 3);
        // nothing is applied before the drain
        assert_eq!(w.colony_pops(col), 0);
        assert_eq!(q.drain(&mut w, Date::from_ymd(2200, 1, 1)), 3);
        let p = q.resolved(h).unwrap();
        assert_eq!(w.pop_groups[&p].size, 350);
        assert_eq!(w.colony_pops(col), 3);
        assert_eq!(w.countries[&c].stockpile.get(Resource::Energy), Fixed::from_int(5));
        assert!(w.modifiers.dirty);
    }
}

/// The barrier: drain the queue, then recompute modifiers with random draws forbidden (what the
/// game's `CRootEffect::Execute` does after a root effect).
pub fn barrier(world: &mut World, queue: &mut EngineQueue, rng: &mut crate::rng::NoiseRandom, date: Date) -> usize {
    let n = queue.drain(world, date);
    let old = rng.set_forbidden(true);
    crate::engine::modifiers::update(world);
    rng.set_forbidden(old);
    n
}
