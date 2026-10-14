//! The simulation in a rendered game's frames (docs/frame_timing.md). At 120 frames a second it
//! must keep the frames within 8.33 ms, either on the render thread in what each frame leaves
//! after the render work (its phases cut into pieces at engine.slice's checks; the game's pace is
//! what that leaves, reported), or on a thread of its own that the render thread only reads from
//! (and then at the game's pace too).
//!
//! Timed in real time from a load of the save, so long and machine-dependent: ignored by default.
//!
//!   cargo test --release --test frame_timing -- --ignored --nocapture --test-threads 1
//!
//! Settings: frametime::Config::from_env (STELLAR_FRAME_SPEED 3, STELLAR_FRAME_DAYS 35,
//! STELLAR_FRAME_RENDER_MS 4, STELLAR_FRAME_FPS 120, ...). Skipped when the Stellaris install or
//! the save is not there.

use std::sync::Mutex;
use std::time::Instant;

use stellar_sim::{frametime, save};

/// One at a time: two games loaded side by side would time each other.
static ONE: Mutex<()> = Mutex::new(());

fn inputs() -> Option<(String, String)> {
    Some((save::game_dir()?, save::default_save()?))
}

fn failures(r: &frametime::Report) -> Vec<String> {
    let mut v = Vec::new();
    if let Some(e) = &r.error {
        v.push(format!("error: {e}"));
        return v;
    }
    if !r.frames_fit() {
        let over: Vec<String> = r.units_over_room().iter().map(|u| format!("{} {:.1} ms", u.label, u.max_piece_ms)).collect();
        v.push(format!(
            "frames over {:.2} ms: {} of {} (p99 {:.2} ms, worst {:.1} ms){}",
            r.budget_ms(),
            r.frames.over_budget,
            r.frames.frames,
            r.frames.p99_ms,
            r.frames.max_ms,
            if r.mode == "inline" && !over.is_empty() { format!("; units with a piece longer than a frame's room: {}", over.join(", ")) } else { String::new() }
        ));
    }
    // inline, the game goes as fast as what each frame leaves holds (the frames are the limit; a
    // game whose simulation needs more slows down, as the game does): its pace is reported only
    if r.mode != "inline" && !r.keeps_pace() {
        v.push(format!("{:.2} game days a second, the speed asks for {:.2}", r.achieved_days_per_s, r.nominal_days_per_s));
    }
    v
}

#[test]
#[ignore]
fn inline_in_what_each_frame_leaves() {
    let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
    let Some((game_dir, save_path)) = inputs() else {
        eprintln!("skipped: no Stellaris install or no save");
        return;
    };
    let cfg = frametime::Config::from_env();
    let t = Instant::now();
    let mut sim = frametime::load(&game_dir, &save_path).expect("load");
    let load_s = t.elapsed().as_secs_f64();
    let mut r = frametime::run_inline(&mut sim, &cfg);
    r.load_s = load_s;
    print!("{}", r.text());
    let f = failures(&r);
    assert!(f.is_empty(), "inline at {} FPS, speed {}: {}", cfg.fps, cfg.speed, f.join("; "));
}

#[test]
#[ignore]
fn on_a_thread_of_its_own() {
    let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
    let Some((game_dir, save_path)) = inputs() else {
        eprintln!("skipped: no Stellaris install or no save");
        return;
    };
    let cfg = frametime::Config::from_env();
    let r = frametime::run_threaded(&cfg, move || frametime::load(&game_dir, &save_path));
    print!("{}", r.text());
    let f = failures(&r);
    assert!(f.is_empty(), "on its own thread at {} FPS, speed {}: {}", cfg.fps, cfg.speed, f.join("; "));
}
