//! The AI (deferred: a trivial stand-in).
//!
//! Replaces `CGameState::ProcessAI` (`0x264600`, on the 4th tick of each day), `UpdateAIParallel`
//! (`0xb851e0`) -> `ParallelFor<CUpdateAIFunctor>` -> `CCountryAI::Update` / `DailyUpdate` /
//! `MonthlyUpdate` (`0xb6d800`, `0xb6d910`, `0xb6ddc0`) and the ministers behind virtual calls
//! (`CAIInteriorMinister`, `CAIMilitaryMinister`, `CAIEconomicStrategy`, ...). Class census about
//! 187 k instructions. The AI does not change the game state directly: its decisions are commands
//! (`CCountryAI::AddAICommandForPosting`) posted to the session and executed like a player's, which
//! is what [`process_ai`] returns.
//!
//! The stand-in: each country with an idle colony queues the cheapest affordable building.

use crate::scheduler::Command;
use crate::state::{Resource, World};

pub fn process_ai(world: &World) -> Vec<Command> {
    let mut cmds = Vec::new();
    for (cid, c) in &world.countries {
        if !c.alive {
            continue;
        }
        let Some((col_id, _)) = world.colonies.iter().find(|(_, col)| col.owner == *cid && col.construction.is_empty()) else {
            continue;
        };
        let pick = world
            .defs
            .buildings
            .iter()
            .filter(|(_, d)| c.stockpile.covers(&d.cost))
            .min_by(|a, b| a.1.cost.get(Resource::Minerals).cmp(&b.1.cost.get(Resource::Minerals)).then(a.0.cmp(b.0)));
        if let Some((name, _)) = pick {
            cmds.push(Command::QueueBuilding { colony: *col_id, building: name.clone() });
        }
    }
    cmds
}
