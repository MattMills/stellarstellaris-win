//! Loads a save, runs N days and writes the world as a save the game loads (docs/saves.md): the
//! round trip's own half (tools/save_roundtrip.sh).
//!
//!   cargo run --release --example resave -- <in.sav> <days> <out.sav>
//!
//! The load is the run example's: the save's tick within the day, its synchronized generator
//! (random_seed, random_count), the vanilla files (STELLARIS_DIR). With 0 days the save is read and
//! written back as it is (the writer's own round trip). What of the save this build does not read
//! is printed (engine.savegame.report).

use stellar_sim::{save, Runtime, Simulation};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (Some(input), Some(days), Some(out)) = (args.get(1), args.get(2).and_then(|d| d.parse::<u64>().ok()), args.get(3)) else {
        eprintln!("usage: resave <in.sav> <days> <out.sav>");
        std::process::exit(2);
    };
    let game_dir = save::game_dir().expect("no Stellaris install: set STELLARIS_DIR");
    let t0 = std::time::Instant::now();
    let gamestate = save::read_gamestate(input).expect("read the save");
    let meta = save::read_meta(input).ok();
    let date = save::date_of(&gamestate).expect("the save's date");
    let tick = save::tick_of(&gamestate).unwrap_or(0);
    let (seed, position) = save::random_of(&gamestate).unwrap_or((0, 0));
    let runtime = Runtime::new(date, seed).expect("the Lua runtime");
    runtime.rng.borrow_mut().position = position;
    let loaded = runtime.load(&game_dir, Some(&gamestate), None).expect("load");
    drop(gamestate);
    println!("{loaded}");
    for line in runtime.save_report(meta.as_deref()).unwrap_or_default() {
        println!("save: {line}");
    }
    println!("loaded {input} in {:.1} s ({date:?}, tick {tick}); running {days} days", t0.elapsed().as_secs_f64());
    let mut sim = Simulation::new(runtime);
    sim.set_tick_count(tick);
    let t1 = std::time::Instant::now();
    if days > 0 {
        sim.run_days(days);
    }
    println!("{days} days in {:.1} s to {:?}; {} errors", t1.elapsed().as_secs_f64(), sim.date(), sim.errors.len());
    for e in sim.errors.iter().take(10) {
        println!("  error: {e}");
    }
    let t2 = std::time::Instant::now();
    let written = sim.write_save(out, meta.as_deref()).expect("write the save");
    println!("wrote {out} ({written}, tick {}) in {:.1} s", sim.tick_count(), t2.elapsed().as_secs_f64());
}
