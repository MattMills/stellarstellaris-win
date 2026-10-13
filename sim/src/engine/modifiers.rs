//! Modifier recomputation.
//!
//! Replaces `NModifierNode::CModifierNodeManager::Update` (`0x29e250`: the task graph of 34 node
//! categories, run after every root effect (`CRootEffect::Execute`, `0x3ac1b0`), after player
//! commands, twice in `DailyUpdate` (`0x25e898`, `0x25eec3`) and at the start of `MonthlyUpdate`
//! (`0x26195f`)), every object's `CalculateModifier` (virtual), `AddModifierNode` (`0x232b40`) and
//! the invalidation functions (`CModifierNodeBase::Invalidate`, `0x23a770`). See
//! docs/modifiers.md; the real replacement is the Lua dependency graph of docs/modifier_graph.md.
//!
//! The skeleton: sources per scope; a colony sees its own sources plus its owner country's
//! (the parent node). Random draws are forbidden during the update (the game sets
//! `CRandom::_InForbiddenZone`); the scheduler sets that around [`update`].

use std::collections::BTreeMap;

use crate::date::Date;
use crate::fixed::Fixed;
use crate::script::Scope;
use crate::state::World;

/// Rebuilds the computed values if anything was invalidated. Returns whether it ran.
pub fn update(world: &mut World) -> bool {
    if !world.modifiers.dirty {
        return false;
    }
    let mut computed: BTreeMap<(Scope, String), Fixed> = BTreeMap::new();
    for ((scope, _source, name), (value, _)) in &world.modifiers.sources {
        *computed.entry((*scope, name.clone())).or_default() += *value;
        if let Scope::Country(cid) = scope {
            for (col_id, col) in &world.colonies {
                if col.owner == *cid {
                    *computed.entry((Scope::Colony(*col_id), name.clone())).or_default() += *value;
                }
            }
        }
    }
    world.modifiers.computed = computed;
    world.modifiers.dirty = false;
    world.modifiers.recomputes += 1;
    true
}

/// Timed modifiers that ended (the owners' daily updates: `CCountry::DailyUpdateSelfDontReadOthers`,
/// fleets' and planets' timed modifiers). Returns how many were removed.
pub fn expire(world: &mut World, date: Date) -> usize {
    let before = world.modifiers.sources.len();
    world.modifiers.sources.retain(|_, (_, end)| end.map_or(true, |e| e > date));
    let n = before - world.modifiers.sources.len();
    if n > 0 {
        world.modifiers.dirty = true;
    }
    n
}
