//! Runs the game from a save: the vanilla file set read in place, the world from the save, the
//! tick in the game's order for N days, then what ran and what is not modelled yet.
//!
//!   sim\cargo_msvc.cmd run --release --example run -- [days] [save.sav]
//!
//! Defaults: 31 days, the 2210.01.01 autosave (save::default_save), the Steam install
//! (STELLARIS_DIR).

use stellar_sim::{save, Runtime, Simulation};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let days: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(31);
    let save_path = args.get(2).cloned().or_else(save::default_save).expect("no save: give one, or set STELLAR_SAVE");
    let game_dir = save::game_dir().expect("no Stellaris install: set STELLARIS_DIR");

    let t0 = std::time::Instant::now();
    let gamestate = save::read_gamestate(&save_path).expect("read the save");
    let date = save::date_of(&gamestate).expect("the save's date");
    let runtime = Runtime::new(date, 0).expect("the Lua runtime");
    let loaded = runtime.load(&game_dir, Some(&gamestate), None).expect("load");
    drop(gamestate);
    println!("{loaded}");
    println!("loaded in {:.1} s; running {days} days from {date:?}", t0.elapsed().as_secs_f64());

    let mut sim = Simulation::new(runtime);
    let t1 = std::time::Instant::now();
    sim.run_days(days);
    println!("{} ticks to {:?} in {:.1} s", sim.ticks, sim.date(), t1.elapsed().as_secs_f64());
    for e in &sim.errors {
        println!("error: {e}");
    }
    println!("{}", sim.runtime.report());
}
