//! Every draw of the synchronized generator the simulation makes from Lua (RUST.rand / RUST.skip),
//! with its tick, position, scheduler unit and Lua call sites, and one UNIT line per unit (with the
//! draws made in Rust: the pools): to compare with the headless game's trace of every draw
//! (headless/README.md, HEADLESS_TRACE with a site table of every CRandom call).
//!
//!   sim\cargo_msvc.cmd run --release --example drawtrace -- <from.gamestate> <ticks> <out.tsv>
//!
//! Columns: tick (from 1), position before, draws, unit, rand | skip | UNIT, call sites (or date).
use std::cell::{Cell, RefCell};
use std::io::Write;
use std::rc::Rc;
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
    let file = Rc::new(RefCell::new(std::io::BufWriter::new(std::fs::File::create(out).unwrap())));
    let tick = Rc::new(Cell::new(0i64));
    let unit = Rc::new(RefCell::new(String::new()));
    {
        let (f, t, u, rng) = (file.clone(), tick.clone(), unit.clone(), rt.rng.clone());
        let log = rt
            .lua
            .create_function(move |_, (kind, n, site): (String, u32, String)| {
                let pos = rng.borrow().position;
                writeln!(f.borrow_mut(), "{}\t{}\t{}\t{}\t{}\t{}", t.get(), pos, n, u.borrow(), kind, site).unwrap();
                Ok(())
            })
            .unwrap();
        rt.lua.globals().set("DRAWLOG", log).unwrap();
        rt.lua
            .load(
                r#"
local rand, skip, log = RUST.rand, RUST.skip, DRAWLOG
local function site()
    local parts = {}
    for level = 3, 6 do
        local i = debug.getinfo(level, "Sl")
        if not i then break end
        parts[#parts + 1] = i.short_src:gsub("^.*/lua/", "") .. ":" .. i.currentline
    end
    return table.concat(parts, " < ")
end
RUST.rand = function() log("rand", 1, site()) return rand() end
RUST.skip = function(n) if n > 0 then log("skip", n, site()) end return skip(n) end
"#,
            )
            .exec()
            .unwrap();
    }
    let mut sim = Simulation::new(rt);
    sim.set_tick_count(st);
    let mut done = 0u64;
    while done < ticks {
        tick.set(done as i64 + 1);
        let next = sim.upcoming().label();
        *unit.borrow_mut() = next.clone();
        let p0 = sim.runtime.rng.borrow().position;
        let step = sim.step();
        let p1 = sim.runtime.rng.borrow().position;
        writeln!(file.borrow_mut(), "{}\t{}\t{}\t{}\tUNIT\t{:?}", tick.get(), p0, p1.wrapping_sub(p0), next, sim.date()).unwrap();
        if step.tick_done {
            done += 1;
        }
    }
    file.borrow_mut().flush().unwrap();
    println!("end position {}", sim.runtime.rng.borrow().position);
}
