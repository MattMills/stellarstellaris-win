//! The simulation inside a rendered game's frames (docs/frame_timing.md): at 120 frames a second,
//! run on the render thread in what each frame leaves ("inline"), and on a thread of its own
//! ("thread"), each from a fresh load of the save, then the two end states compared.
//!
//!   cargo run --release --example frametime -- [days] [save.sav]
//!
//! Defaults: 35 days (one month's end), the 2210.01.01 autosave (save::default_save), the
//! Stellaris install (STELLARIS_DIR). Settings (frametime::Config::from_env):
//! STELLAR_FRAME_FPS (120), STELLAR_FRAME_RENDER_MS (4: the render thread's own work a frame),
//! STELLAR_FRAME_MARGIN_MS (0.5), STELLAR_FRAME_BASELINE_S (3), and here:
//! STELLAR_FRAME_SPEED (3, Normal; a list such as "3,5", or "all" for 1 to 5),
//! STELLAR_FRAME_MODE (both, inline or thread).

use std::time::Instant;

use stellar_sim::{frametime, save};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let save_path = args.get(2).cloned().or_else(save::default_save).expect("no save: give one, or set STELLAR_SAVE");
    let game_dir = save::game_dir().expect("no Stellaris install: set STELLARIS_DIR");
    let mut cfg = frametime::Config::from_env();
    if let Some(days) = args.get(1).and_then(|s| s.parse().ok()) {
        cfg.days = days;
    }
    let speeds: Vec<u8> = match std::env::var("STELLAR_FRAME_SPEED").ok().as_deref() {
        Some("all") => (1..=5).collect(),
        Some(list) => list.split(',').filter_map(|s| s.trim().parse().ok()).filter(|s| (1..=5).contains(s)).collect(),
        None => vec![cfg.speed],
    };
    let mode = std::env::var("STELLAR_FRAME_MODE").unwrap_or_else(|_| "both".into());
    println!("save {save_path}, {} days, modes {mode}, speeds {speeds:?}", cfg.days);

    let mut summary = Vec::new();
    for speed in speeds {
        cfg.speed = speed;
        let mut ends = Vec::new();
        if mode == "both" || mode == "inline" {
            let t = Instant::now();
            let mut sim = frametime::load(&game_dir, &save_path).expect("load");
            let load_s = t.elapsed().as_secs_f64();
            let mut r = frametime::run_inline(&mut sim, &cfg);
            r.load_s = load_s;
            drop(sim);
            print!("{}", r.text());
            ends.push(r.fingerprint.clone());
            summary.push(r);
        }
        if mode == "both" || mode == "thread" {
            let (g, s) = (game_dir.clone(), save_path.clone());
            let r = frametime::run_threaded(&cfg, move || frametime::load(&g, &s));
            print!("{}", r.text());
            ends.push(r.fingerprint.clone());
            summary.push(r);
        }
        if ends.len() == 2 {
            // two whole-tick runs of the same build can differ in the last digit of a stockpile
            // (docs/frame_timing.md section 4): STELLAR_FRAME_SAVE_DIR keeps both ends to compare
            println!(
                "speed {speed}: the two modes end {}",
                if ends[0] == ends[1] { "alike" } else { "differently (compare the saves: STELLAR_FRAME_SAVE_DIR)" }
            );
        }
        println!();
    }

    println!("summary ({} FPS, {:.2} ms a frame, render {:.2} ms):", cfg.fps, cfg.budget() * 1000.0, cfg.render_ms);
    println!("  speed    mode    keeps pace  days/s (asked)   frames fit  frames over  worst frame  units over the room");
    for r in &summary {
        println!(
            "  {} {:<7} {:<7} {:<10}  {:>6.2} ({:>5.2})   {:<10}  {:>11}  {:>8.1} ms  {}",
            r.config.speed,
            r.config.speed_name(),
            r.mode,
            if r.keeps_pace() { "yes" } else { "no" },
            r.achieved_days_per_s,
            r.nominal_days_per_s,
            if r.frames_fit() { "yes" } else { "no" },
            r.frames.over_budget,
            r.frames.max_ms,
            if r.mode == "inline" { r.units_over_room().len().to_string() } else { "-".into() }
        );
    }
}
