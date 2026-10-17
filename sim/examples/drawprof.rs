//! Per day, the synchronized generator's draws by scheduler unit (Simulation::phase_draws), the
//! rest (the commands before a tick) under "other": to compare with the headless game's profile
//! (headless/README.md, HEADLESS_PROFILE).
//!
//!   sim\cargo_msvc.cmd run --release --example drawprof -- <from.gamestate> <ticks> <out.tsv>
use std::io::Write;
use stellar_sim::{save, Runtime, Simulation};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (from, ticks, out) = (&a[1], a[2].parse::<u64>().unwrap(), &a[3]);
    let game_dir = save::game_dir().expect("STELLARIS_DIR");
    let gs = save::read_gamestate(from).expect("read");
    let start = save::date_of(&gs).expect("date");
    let st = save::tick_of(&gs).unwrap_or(0);
    let (seed, pos0) = save::random_of(&gs).unwrap_or((0, 0));
    let rt = Runtime::new(start, seed).expect("runtime");
    rt.rng.borrow_mut().position = pos0;
    println!("{}", rt.load(&game_dir, Some(&gs), None).expect("load"));
    drop(gs);
    let mut sim = Simulation::new(rt);
    sim.set_tick_count(st);
    let mut f = std::io::BufWriter::new(std::fs::File::create(out).unwrap());
    let mut day = sim.date();
    let mut last_pos = pos0;
    let mut last = sim.phase_draws.clone();
    let flush = |sim: &Simulation, day: stellar_sim::Date, last_pos: &mut u32, last: &mut std::collections::BTreeMap<String, u64>, f: &mut std::io::BufWriter<std::fs::File>| {
        let pos = sim.runtime.rng.borrow().position;
        let now = sim.phase_draws.clone();
        let total = pos.wrapping_sub(*last_pos) as u64;
        let mut parts = Vec::new();
        let mut sum = 0u64;
        for (k, v) in &now {
            let d = v - last.get(k).copied().unwrap_or(0);
            if d > 0 {
                parts.push(format!("{k}={d}"));
                sum += d;
            }
        }
        if total > sum {
            parts.push(format!("other={}", total - sum));
        }
        writeln!(f, "{day:?}\t{total}\t{}", parts.join(",")).unwrap();
        *last_pos = pos;
        *last = now;
    };
    for _ in 0..ticks {
        sim.run_ticks(1);
        if sim.date() != day {
            // the day tick's draws belong to the new day: flush the old day before it would be
            // mixed in. run_ticks(1) already ran the new day's tick, so a day line holds the
            // ticks after the previous day tick up to and including this one.
            flush(&sim, day, &mut last_pos, &mut last, &mut f);
            day = sim.date();
        }
    }
    flush(&sim, day, &mut last_pos, &mut last, &mut f);
    let pos = sim.runtime.rng.borrow().position;
    println!("total draws {}", pos.wrapping_sub(pos0));
    for (k, v) in &sim.phase_draws {
        println!("{k}\t{v}");
    }
}
