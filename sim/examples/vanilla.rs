//! Runs the vanilla game's script in the simulation: `cargo run --release --example vanilla --
//! <Stellaris dir> [years] [seed] [--coverage]`.

use stellar_sim::sample::vanilla_like_world;
use stellar_sim::{Date, GameState, LuaScriptHost, Simulation};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let game = args.get(1).cloned().or_else(|| std::env::var("STELLARIS_DIR").ok()).expect("the Stellaris directory");
    let years: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5);
    let seed: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(2200);
    let docs = std::env::var("STELLARIS_DOCS").ok().or_else(|| {
        let d = format!("{}/Documents/Paradox Interactive/Stellaris/logs/script_documentation", std::env::var("USERPROFILE").unwrap_or_default());
        std::path::Path::new(&d).exists().then_some(d)
    });
    let t0 = std::time::Instant::now();
    let host = LuaScriptHost::new(&game, docs.as_deref()).expect("lua host");
    println!("loaded in {:?}", t0.elapsed());
    if args.iter().any(|a| a == "--coverage") {
        let c: String = host.call_plain("coverage", ()).expect("coverage");
        println!("{c}");
    }
    let mut sim = Simulation::new(GameState::new(Date::from_ymd(2200, 1, 1), seed, vanilla_like_world()), host);
    let t1 = std::time::Instant::now();
    sim.run_days(years * 360);
    println!("ran {years} years ({} ticks) in {:?}", sim.ticks, t1.elapsed());
    println!("checksum {:016x}, rng position {}", stellar_sim::engine::checksums::checksum(&sim.state), sim.state.rng.position);
    println!("{}", sim.script.report());
    println!("rust-side Lua call errors: {} {:?}", sim.script.errors, sim.script.first_errors);
    println!("engine queue: applied {}, dropped {}, unmodelled kinds {}", sim.queue.applied, sim.queue.dropped, sim.queue.unmodelled.len());
    for (c, country) in &sim.state.world.countries {
        println!("country {c} {}: techs {} energy {:?} minerals {:?}", country.name, country.techs.len(),
            country.stockpile.get(stellar_sim::state::Resource::Energy), country.stockpile.get(stellar_sim::state::Resource::Minerals));
    }
}
