//! A new game without a save: the galaxy generated in Lua from the game's files
//! (`sim/lua/engine/newgame`, docs/newgame.md), written as a .sav, then loaded by the engine and run.
//!
//!   cargo run --release --example newgame -- [options]
//!
//! Options (defaults in brackets):
//!   --scenario NAME        setup scenario of map/setup_scenarios [tiny]
//!   --shape NAME           galaxy shape of map/galaxy [the scenario's first]
//!   --empires N            AI empires (the human comes on top) [the scenario's default]
//!   --fallen N, --marauders N, --nomads N, --advanced N
//!   --hyperlanes X         hyperlane density 0.5..3 [the scenario's default]
//!   --seed N               the galaxy seed [from the global stream, as the game does]
//!   --global-seed N        the seed of the game's global generator [0]
//!   --player DESIGN        the human's empire design (a key of the designs) [none]
//!   --designs FILE         the user's empire designs (a user_empire_designs_v3.4.txt) [none]
//!   --dlcs "A;B"           the DLCs the game owns [the install's dlc/*.dlc]
//!   --global-at "S=N,..."  put the global stream at position N when step S starts (the game's,
//!                          measured headless: the draws the Lua does not make) [none]
//!   --out FILE.sav         where to write the save [newgame.sav]
//!   --days N               days to run the saves for, 0 to skip [30]
//!   --start-script yes|no  run the script's part of game creation (init_effects, the empire
//!                          on_actions, on_game_start) on the generated world and write it as
//!                          FILE-started.sav [yes]
//!
//! The game's files: STELLARIS_DIR (or the Steam install / /opt/stellaris).

use stellar_sim::mlua::Table;
use stellar_sim::{save, Date, Runtime, Simulation};

/// Loads a save as any save (a fresh runtime) and runs it; returns the runtime's report.
fn load_and_run(game_dir: &str, path: &str, days: u64, global_seed: u32) -> String {
    let t1 = std::time::Instant::now();
    let gamestate = save::read_gamestate(path).expect("read the save");
    let date = save::date_of(&gamestate).expect("the save's date");
    let runtime = Runtime::new(date, global_seed).expect("the Lua runtime");
    let loaded = runtime.load(game_dir, Some(&gamestate), None).expect("engine.load");
    drop(gamestate);
    println!("{loaded}");
    println!("{path}: loaded in {:.1} s; running {days} days from {date:?}", t1.elapsed().as_secs_f64());
    let mut sim = Simulation::new(runtime);
    let t2 = std::time::Instant::now();
    sim.run_days(days);
    println!("{} ticks to {:?} in {:.1} s, {} errors", sim.ticks, sim.date(), t2.elapsed().as_secs_f64(), sim.errors.len());
    for e in sim.errors.iter().take(20) {
        println!("error: {e}");
    }
    match sim.runtime.save_text() {
        Ok((text, d)) => println!("written back after the run: {} KB, dated {d}", text.len() / 1024),
        Err(e) => println!("save after the run failed: {e}"),
    }
    sim.runtime.report()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut opts = std::collections::HashMap::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if let Some(key) = a.strip_prefix("--") {
            let value = args.get(i + 1).cloned().unwrap_or_default();
            opts.insert(key.to_string(), value);
            i += 2;
        } else {
            eprintln!("unexpected argument {a}");
            std::process::exit(2);
        }
    }
    let game_dir = save::game_dir().expect("no Stellaris install: set STELLARIS_DIR");
    let out = opts.get("out").cloned().unwrap_or_else(|| "newgame.sav".to_string());
    let days: u64 = opts.get("days").and_then(|s| s.parse().ok()).unwrap_or(30);
    let global_seed: u32 = opts.get("global-seed").and_then(|s| s.parse().ok()).unwrap_or(0);
    let start_script = opts.get("start-script").map(|s| s != "no").unwrap_or(true);
    let start = Date::from_ymd(2200, 1, 1);

    // generate
    let t0 = std::time::Instant::now();
    let runtime = Runtime::new(start, global_seed).expect("the Lua runtime");
    let lua = &runtime.lua;
    let settings: Table = lua.create_table().unwrap();
    let names = [
        ("scenario", "scenario", false),
        ("shape", "shape", false),
        ("empires", "empires", true),
        ("fallen", "fallen_empires", true),
        ("marauders", "marauders", true),
        ("nomads", "nomads", true),
        ("advanced", "advanced_empires", true),
        ("hyperlanes", "num_hyperlanes", true),
        ("seed", "seed", true),
        ("name", "name", false),
        ("player", "player_design", false),
        ("dlcs", "dlcs", false),
        ("global-at", "global_at", false),
    ];
    for (opt, key, numeric) in names {
        if let Some(v) = opts.get(opt) {
            if numeric {
                let n: f64 = v.parse().unwrap_or_else(|_| panic!("--{opt} wants a number"));
                settings.set(key, n).unwrap();
            } else {
                settings.set(key, v.as_str()).unwrap();
            }
        }
    }
    settings.set("global_seed", global_seed).unwrap();
    if let Some(path) = opts.get("designs") {
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("--designs {path}: {e}"));
        settings.set("designs_text", text).unwrap();
    }
    let newgame: Table = lua.load("return require('engine.newgame')").eval().expect("engine.newgame");
    let generate: stellar_sim::mlua::Function = newgame.get("generate_text").unwrap();
    let (gamestate, meta, summary): (String, String, String) =
        generate.call((game_dir.replace('\\', "/"), settings)).unwrap_or_else(|e| panic!("newgame.generate: {e}"));
    println!("{summary}");
    let date = save::date_of(&gamestate).expect("the generated gamestate's date");
    let date_text = format!("{date:?}");
    save::write_save(&out, &gamestate, &meta, &date_text).expect("write the save");
    println!("wrote {out} ({} KB of gamestate) in {:.1} s", gamestate.len() / 1024, t0.elapsed().as_secs_f64());

    // the script's part, on the generated world loaded in the same state (the generator's record
    // of the init_effects is there)
    let mut started = None;
    if start_script {
        let t1 = std::time::Instant::now();
        let text = save::read_gamestate(&out).expect("read the generated save");
        let loaded = runtime.load(&game_dir, Some(&text), None).expect("engine.load of the generated save");
        println!("{loaded}");
        let report: String = lua
            .load("return require('engine.newgame').start_script()")
            .eval()
            .unwrap_or_else(|e| format!("start script failed: {e}"));
        println!("{report}");
        match runtime.save_text() {
            Ok((text, d)) => {
                let path = out.trim_end_matches(".sav").to_string() + "-started.sav";
                save::write_save(&path, &text, &meta, &d).expect("write the started save");
                println!("wrote {path} ({} KB) in {:.1} s", text.len() / 1024, t1.elapsed().as_secs_f64());
                started = Some(path);
            }
            Err(e) => println!("writing the started world failed: {e}"),
        }
        println!("{}", runtime.report());
    }
    drop(runtime);
    if days == 0 {
        return;
    }
    let report = load_and_run(&game_dir, &out, days, global_seed);
    println!("{report}");
    if let Some(path) = started {
        let report = load_and_run(&game_dir, &path, days, global_seed);
        println!("{}", report.lines().take(12).collect::<Vec<_>>().join("\n"));
    }
}
