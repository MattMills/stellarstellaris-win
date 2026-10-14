//! Runs the game from a save: the vanilla file set read in place, the world from the save, the
//! tick in the game's order for N days, then what ran and what is not modelled yet.
//!
//!   sim\cargo_msvc.cmd run --release --example run -- [days] [save.sav]
//!
//! Defaults: 31 days, the 2210.01.01 autosave (save::default_save), the Steam install
//! (STELLARIS_DIR). With STELLAR_LUA=<file>, that Lua file runs after the days (the engine
//! loaded: require("engine.research") etc.) and what it returns is printed.

use stellar_sim::{save, Runtime, Simulation};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let days: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(31);
    let save_path = args.get(2).cloned().or_else(save::default_save).expect("no save: give one, or set STELLAR_SAVE");
    let game_dir = save::game_dir().expect("no Stellaris install: set STELLARIS_DIR");

    let t0 = std::time::Instant::now();
    let gamestate = save::read_gamestate(&save_path).expect("read the save");
    let date = save::date_of(&gamestate).expect("the save's date");
    let tick = save::tick_of(&gamestate).unwrap_or(0);
    // the synchronized generator as saved (`random_seed`, `random_count`)
    let (seed, position) = save::random_of(&gamestate).unwrap_or((0, 0));
    let runtime = Runtime::new(date, seed).expect("the Lua runtime");
    runtime.rng.borrow_mut().position = position;
    let loaded = runtime.load(&game_dir, Some(&gamestate), None).expect("load");
    drop(gamestate);
    println!("{loaded}");
    println!("loaded in {:.1} s; running {days} days from {date:?}", t0.elapsed().as_secs_f64());

    // with STELLAR_LUA_BEFORE=<file>, that Lua file runs after the load, before the first tick
    // (e.g. starting a profiler that the STELLAR_LUA file reads out)
    if let Ok(path) = std::env::var("STELLAR_LUA_BEFORE") {
        let code = std::fs::read_to_string(&path).expect("read STELLAR_LUA_BEFORE");
        if let Err(e) = runtime.lua.load(&code).set_name(path.as_str()).exec() {
            println!("STELLAR_LUA_BEFORE failed: {e}");
        }
    }
    let mut sim = Simulation::new(runtime);
    sim.set_tick_count(tick);
    let t1 = std::time::Instant::now();
    // with STELLAR_PROGRESS=<days>, a line every that many days: the date, the time taken, the
    // Lua memory and the phase errors so far (for long runs)
    let step: u64 = std::env::var("STELLAR_PROGRESS").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
    if step == 0 {
        sim.run_days(days);
    } else {
        let mut done = 0;
        while done < days {
            let n = step.min(days - done);
            let t = std::time::Instant::now();
            sim.run_days(n);
            done += n;
            let secs = t.elapsed().as_secs_f64();
            println!(
                "progress: {:?}, {done} of {days} days; {n} days in {secs:.1} s ({:.1} ms a day), {:.1} s in all; Lua {:.0} MB; {} phase errors",
                sim.date(),
                secs * 1000.0 / n as f64,
                t1.elapsed().as_secs_f64(),
                sim.runtime.lua.used_memory() as f64 / 1048576.0,
                sim.errors.len()
            );
        }
    }
    println!("{} ticks to {:?} in {:.1} s", sim.ticks, sim.date(), t1.elapsed().as_secs_f64());
    print!("{}", sim.phase_report());
    for e in &sim.errors {
        println!("error: {e}");
    }
    println!("{}", sim.runtime.report());
    if let Ok(path) = std::env::var("STELLAR_LUA") {
        let code = std::fs::read_to_string(&path).expect("read STELLAR_LUA");
        match sim.runtime.lua.load(&code).set_name(path.as_str()).eval::<Option<String>>() {
            Ok(Some(s)) => println!("{s}"),
            Ok(None) => {}
            Err(e) => println!("STELLAR_LUA failed: {e}"),
        }
    }
}
