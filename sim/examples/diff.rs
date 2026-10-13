//! Runs the game from one save to the date of a later save the game wrote, then compares the
//! simulation's world with that save, store by store and field by field (engine/diff.lua).
//!
//!   sim\cargo_msvc.cmd run --release --example diff -- <from.sav> <to.sav> [top]
//!
//! The commands of the player and the AI between the two saves are not in them: some differences
//! are theirs.

use stellar_sim::{mlua, save, Runtime, Simulation};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (from, to) = (args.get(1).expect("from.sav"), args.get(2).expect("to.sav"));
    let top: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(12);
    let game_dir = save::game_dir().expect("no Stellaris install: set STELLARIS_DIR");

    let gamestate = save::read_gamestate(from).expect("read the first save");
    let start = save::date_of(&gamestate).expect("its date");
    let target_text = save::read_gamestate(to).expect("read the second save");
    let end = save::date_of(&target_text).expect("its date");
    let days = (end.days() - start.days()) as u64;

    let runtime = Runtime::new(start, 0).expect("the Lua runtime");
    println!("{}", runtime.load(&game_dir, Some(&gamestate), None).expect("load"));
    drop(gamestate);
    // the stockpiles at the start, to compare their change with the game's
    let before: mlua::Table = runtime.lua.load("return require('engine.diff').snapshot_stockpiles()").eval().expect("snapshot");
    let research_before: mlua::Table = runtime.lua.load("return require('engine.diff').snapshot_research()").eval().expect("snapshot");
    let mut sim = Simulation::new(runtime);
    let t0 = std::time::Instant::now();
    sim.run_days(days);
    println!("{days} days, {start:?} -> {:?}, in {:.1} s; {} phase errors", sim.date(), t0.elapsed().as_secs_f64(), sim.errors.len());
    for e in sim.errors.iter().take(5) {
        println!("error: {e}");
    }
    // the world's own date as the save writes it
    let _ = sim.runtime.save_text().expect("date the world");
    let run: mlua::Function = sim.runtime.lua.load("return require('engine.diff').run").eval().expect("engine.diff");
    let text = sim.runtime.lua.create_string(&target_text).expect("text");
    drop(target_text);
    let report: String = run.call((text.clone(), top)).expect("diff");
    println!("{report}");
    let stockpiles: mlua::Function = sim.runtime.lua.load("return require('engine.diff').stockpiles").eval().expect("engine.diff");
    let report: String = stockpiles.call((text.clone(), before)).expect("stockpiles");
    println!("{report}");
    let research: mlua::Function = sim.runtime.lua.load("return require('engine.diff').research").eval().expect("engine.diff");
    let report: String = research.call((text, research_before)).expect("research");
    println!("{report}");
    println!("{}", sim.runtime.report());
}
