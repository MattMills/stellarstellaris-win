//! The economy: the monthly budget.
//!
//! Replaces `CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>` (`0x16605d0`, the 22 kinds of
//! economic units, "UpdateResources" then "CalcProduces" / "CalcUpkeep"),
//! `CEconomicUnitBase<...>::ApplyModifiersToTable<N>` (Cost `0x3cc5f0`, Produces `0x420450`,
//! Upkeep `0x3cc2d0`), `CTriggeredResourceTable::CalcResources` (`0x16d42d0`),
//! `CCountryBudget::EndMonthlyUpdate<0>` and `CEconomyCountryModule::AddResources`; daily market
//! work (`CMarket::DailyUpdate`, `CTradeDeal::*`) is not modelled. Formula from docs/modifiers.md,
//! "The formula": for an entry of category C with scale s,
//!
//! `out = s * (base + A) * (1 + max(MIN_ECONOMIC_MODIFIER_MULT, G + P))`, 0 if that factor is <= 0,
//!
//! with A the own category's `<C>_<res>_<kind>_add`, G the sum over C and its ancestors of
//! `<a>_<kind>_mult`, P the sum over the chain of `<a>_<res>_<kind>_mult`.

use crate::fixed::Fixed;
use crate::script::Scope;
use crate::state::{Res, Resource, World};

/// `NDefines MIN_ECONOMIC_MODIFIER_MULT` (`0x313d630`), -0.9 in vanilla.
pub const MIN_ECONOMIC_MODIFIER_MULT: Fixed = Fixed::from_centi(-90);

/// One resource of one entry: `s * (base + add) * (1 + max(-0.9, g + p))`.
pub fn apply_entry(base: Fixed, scale: Fixed, add: Fixed, g: Fixed, p: Fixed) -> Fixed {
    let mut sum = g + p;
    if sum < MIN_ECONOMIC_MODIFIER_MULT {
        sum = MIN_ECONOMIC_MODIFIER_MULT;
    }
    let mult = Fixed::ONE + sum;
    if mult <= Fixed::ZERO {
        return Fixed::ZERO;
    }
    scale.mul(base + add).mul(mult)
}

/// A table (`produces` or `upkeep`) of one entry of `category`, with the modifiers of `scope`.
pub fn apply_table(world: &World, scope: Scope, category: &str, kind: &str, base: &Res, scale: Fixed) -> Res {
    let chain = world.defs.category_chain(category);
    let mut g = Fixed::ZERO;
    for a in &chain {
        g += world.modifier(scope, &format!("{a}_{kind}_mult"));
    }
    let mut out = Res::default();
    for r in Resource::ALL {
        let add = world.modifier(scope, &format!("{category}_{}_{kind}_add", r.name()));
        let b = base.get(r);
        if b == Fixed::ZERO && add == Fixed::ZERO {
            continue;
        }
        let mut p = Fixed::ZERO;
        for a in &chain {
            p += world.modifier(scope, &format!("{a}_{}_{kind}_mult", r.name()));
        }
        out.set(r, apply_entry(b, scale, add, g, p));
    }
    out
}

/// A colony's monthly balance: every filled job's produces and upkeep, every building's upkeep.
pub fn colony_balance(world: &World, colony: crate::state::Id) -> Res {
    let mut total = Res::default();
    let Some(c) = world.colonies.get(&colony) else { return total };
    let scope = Scope::Colony(colony);
    for (job, n) in &c.employed {
        let Some(def) = world.defs.jobs.get(job) else { continue };
        let scale = Fixed::from_int(*n as i64);
        let p = apply_table(world, scope, &def.category, "produces", &def.produces, scale);
        let u = apply_table(world, scope, &def.category, "upkeep", &def.upkeep, scale);
        for r in Resource::ALL {
            total.add(r, p.get(r) - u.get(r));
        }
    }
    for b in &c.buildings {
        let Some(def) = world.defs.buildings.get(b) else { continue };
        let u = apply_table(world, scope, &def.category, "upkeep", &def.upkeep, Fixed::ONE);
        for r in Resource::ALL {
            total.add(r, -u.get(r));
        }
    }
    total
}

/// The monthly budget: per country, the sum of its colonies' balances becomes `last_month_income`;
/// stockpiled resources are added to the stockpile (research is spent daily instead).
pub fn monthly_budget(world: &mut World) {
    let ids: Vec<_> = world.countries.keys().copied().collect();
    for cid in ids {
        let mut income = Res::default();
        let cols: Vec<_> = world.colonies.iter().filter(|(_, c)| c.owner == cid).map(|(id, _)| *id).collect();
        for col in cols {
            let b = colony_balance(world, col);
            for r in Resource::ALL {
                income.add(r, b.get(r));
            }
        }
        let c = world.countries.get_mut(&cid).unwrap();
        if !c.alive {
            continue;
        }
        c.last_month_income = income;
        for r in Resource::ALL {
            if !r.is_research() {
                c.stockpile.add(r, income.get(r));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_formula() {
        let f = Fixed::from_int;
        // 2 workers x (4 + 1 add) x (1 + 0.25 + 0.10)
        assert_eq!(apply_entry(f(4), f(2), f(1), Fixed::from_centi(25), Fixed::from_centi(10)), Fixed::from_centi(1350));
        // the floor of the multiplier is 1 - 0.9
        assert_eq!(apply_entry(f(10), f(1), f(0), f(-5), f(0)), f(1));
    }
}
