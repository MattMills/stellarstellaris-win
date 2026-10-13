//! The game's own script, read in place from the install: parse coverage, keyword coverage, and a
//! multi-year run with every vanilla event and on_action loaded. Skipped unless STELLARIS_DIR is
//! set (the Stellaris install, e.g. `C:\Program Files (x86)\Steam\steamapps\common\Stellaris`);
//! STELLARIS_DOCS is the game's logs/script_documentation (trigger and effect names), defaulting to
//! the usual Documents path when it exists.

use stellar_sim::sample::vanilla_like_world;
use stellar_sim::{Date, GameState, LuaScriptHost, Simulation};

pub fn docs_dir() -> Option<String> {
    if let Ok(d) = std::env::var("STELLARIS_DOCS") {
        return Some(d);
    }
    let d = format!(
        "{}/Documents/Paradox Interactive/Stellaris/logs/script_documentation",
        std::env::var("USERPROFILE").unwrap_or_default()
    );
    std::path::Path::new(&d).exists().then_some(d)
}

#[test]
fn vanilla_coverage_and_run() {
    let Ok(game) = std::env::var("STELLARIS_DIR") else {
        eprintln!("STELLARIS_DIR not set: skipped");
        return;
    };
    let years: u64 = std::env::var("SIM_YEARS").ok().and_then(|y| y.parse().ok()).unwrap_or(3);
    let host = LuaScriptHost::new(&game, docs_dir().as_deref()).expect("lua host");
    let coverage: String = host.call_plain("coverage", ()).expect("coverage");
    println!("{coverage}");
    let mut sim = Simulation::new(GameState::new(Date::from_ymd(2200, 1, 1), 2200, vanilla_like_world()), host);
    let t0 = std::time::Instant::now();
    sim.run_days(years * 360);
    println!("ran {years} years ({} ticks) in {:?}", sim.ticks, t0.elapsed());
    println!("{}", sim.script.report());
    println!("rust-side Lua call errors: {} {:?}", sim.script.errors, sim.script.first_errors);
    println!("engine queue: applied {}, dropped {}, unmodelled {:?}", sim.queue.applied, sim.queue.dropped, sim.queue.unmodelled.len());
    assert!(coverage.contains("parse:"));
    assert!(sim.outcome.script_effects + sim.outcome.engine_effects > 0, "nothing ran");
}
