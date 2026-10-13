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
    // from the first save's tick within the day to the second's (`tick`)
    let (start_tick, end_tick) = (save::tick_of(&gamestate).unwrap_or(0), save::tick_of(&target_text).unwrap_or(0));
    let ticks = (days as i64 * 10 + (end_tick - start_tick) as i64).max(0) as u64;
    // the synchronized generator: the first save's seed and position (the game going on as saved);
    // with STELLAR_RANDOM=target, the second save's seed from position 0 (a game that reseeded when
    // it loaded the first save: its draws since the load are the second save's random_count)
    let (seed, position) = if std::env::var("STELLAR_RANDOM").as_deref() == Ok("target") {
        (save::random_of(&target_text).map(|r| r.0).unwrap_or(0), 0)
    } else {
        save::random_of(&gamestate).unwrap_or((0, 0))
    };

    let runtime = Runtime::new(start, seed).expect("the Lua runtime");
    runtime.rng.borrow_mut().position = position;
    println!("random: seed {seed}, position {position}");
    println!("{}", runtime.load(&game_dir, Some(&gamestate), None).expect("load"));
    drop(gamestate);
    // the stockpiles at the start, to compare their change with the game's
    let before: mlua::Table = runtime.lua.load("return require('engine.diff').snapshot_stockpiles()").eval().expect("snapshot");
    let research_before: mlua::Table = runtime.lua.load("return require('engine.diff').snapshot_research()").eval().expect("snapshot");
    let mut sim = Simulation::new(runtime);
    sim.set_tick_count(start_tick);
    let t0 = std::time::Instant::now();
    sim.run_ticks(ticks);
    println!("{days} days, {start:?} tick {start_tick} -> {:?} tick {}, in {:.1} s; {} phase errors", sim.date(), sim.tick_count(), t0.elapsed().as_secs_f64(), sim.errors.len());
    for e in sim.errors.iter().take(5) {
        println!("error: {e}");
    }
    let drawn = sim.runtime.rng.borrow().position.wrapping_sub(position);
    match save::random_of(&target_text) {
        Some((s, c)) => println!("random: {drawn} draws here; the second save's seed {s}, position {c}"),
        None => println!("random: {drawn} draws here"),
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
