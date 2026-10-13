//! The game from the vanilla file set and a save: the definitions, the world, and a month of ticks
//! that does the same thing twice. Skipped when the Stellaris install or the save is not there.

use stellar_sim::{save, Runtime, Simulation};

fn load() -> Option<Runtime> {
    let game_dir = save::game_dir()?;
    let path = save::default_save()?;
    let gamestate = save::read_gamestate(&path).expect("read the save");
    let date = save::date_of(&gamestate).expect("the save's date");
    let runtime = Runtime::new(date, 7).expect("the Lua runtime");
    runtime.load(&game_dir, Some(&gamestate), None).expect("load");
    Some(runtime)
}

/// What a run leaves that must not depend on anything but the input: the date, the RNG's
/// position, every country's stockpile, and the script layer's counts.
fn fingerprint(sim: &Simulation) -> String {
    let lua: String = sim
        .runtime
        .eval(
            r#"
            local world, eval = require("engine.world"), require("simscript.eval")
            local parts = {}
            for _, id in ipairs(world.all("country")) do
                parts[#parts + 1] = id .. ":" .. tostring(E.resource(id, "energy")) .. "/" .. tostring(E.resource(id, "minerals"))
            end
            local s = eval.stats
            return table.concat(parts, ",") .. "|" .. tostring(s.fired_total) .. "|" .. tostring(s.script) .. "|" ..
                tostring(s.engine) .. "|" .. tostring(E.stats.applied)
            "#,
        )
        .expect("fingerprint");
    format!("{:?}|{}|{}", sim.date(), sim.runtime.rng.borrow_mut().next_int(), lua)
}

#[test]
fn the_vanilla_files_and_the_save_load() {
    let Some(rt) = load() else {
        eprintln!("skipped: no Stellaris install or no save");
        return;
    };
    let (folders, defs, events, countries, planets, pop_groups): (u32, u32, u32, u32, u32, u32) = rt
        .eval(
            r#"
            local defs, world, db = require("engine.defs"), require("engine.world"), require("simscript.db")
            local n = 0
            for _, c in pairs(defs.counts) do n = n + c end
            return #defs.order, n, #db.event_list, #world.all("country"), #world.all("planet"), #world.all("pop_group")
            "#,
        )
        .expect("counts");
    println!("{folders} folders, {defs} definitions, {events} events; {countries} countries, {planets} planets, {pop_groups} pop groups");
    assert!(folders > 150, "common/ has about 200 database folders");
    assert!(defs > 10_000);
    assert!(events > 5_000);
    assert!(countries > 10 && planets > 1_000 && pop_groups > 100);
    // the world answers from the save: the player's stockpile and capital
    let (energy, capital): (f64, Option<u32>) =
        rt.eval(r#"local w = require("engine.world") return E.resource(0, "energy"), w.field(w.object("country", 0), "capital")"#).expect("reads");
    assert!(energy > 0.0);
    assert!(capital.is_some());
}

#[test]
fn a_month_from_the_save_is_deterministic() {
    let (Some(a), Some(b)) = (load(), load()) else {
        eprintln!("skipped: no Stellaris install or no save");
        return;
    };
    let (mut a, mut b) = (Simulation::new(a), Simulation::new(b));
    a.run_days(31);
    b.run_days(31);
    assert!(a.errors.is_empty(), "{:?}", a.errors);
    let (fa, fb) = (fingerprint(&a), fingerprint(&b));
    assert_eq!(fa, fb);
    println!("{}", a.runtime.report());
}
