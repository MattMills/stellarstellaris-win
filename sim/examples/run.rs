//! Runs a small world for some years and prints its progression.
//! `cargo run --example run -- [years] [seed]`

use stellar_sim::engine::checksums::checksum;
use stellar_sim::state::{BuildingDef, JobDef, Res, Resource, TechDef};
use stellar_sim::{Date, Fixed, GameState, MockScriptHost, Simulation, World};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let years: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(10);
    let seed: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(2200);
    let f = Fixed::from_int;

    let mut w = World::default();
    for (c, p) in [("planet_jobs", None), ("planet_miners", Some("planet_jobs")), ("planet_technician", Some("planet_jobs")),
        ("planet_researchers", Some("planet_jobs")), ("planet_buildings", None)]
    {
        w.defs.categories.insert(c.into(), p.map(String::from));
    }
    w.defs.jobs.insert("miner".into(), JobDef { category: "planet_miners".into(), produces: Res::default().with(Resource::Minerals, f(4)), upkeep: Res::default() });
    w.defs.jobs.insert("technician".into(), JobDef { category: "planet_technician".into(), produces: Res::default().with(Resource::Energy, f(6)), upkeep: Res::default() });
    w.defs.jobs.insert(
        "researcher".into(),
        JobDef {
            category: "planet_researchers".into(),
            produces: Res::default().with(Resource::Physics, f(4)).with(Resource::Society, f(4)).with(Resource::Engineering, f(4)),
            upkeep: Res::default(),
        },
    );
    for (name, cost, days, upkeep, job) in [("mine", 50, 60, 1, "miner"), ("power_plant", 75, 90, 0, "technician"), ("lab", 100, 120, 2, "researcher")] {
        w.defs.buildings.insert(
            name.into(),
            BuildingDef {
                cost: Res::default().with(Resource::Minerals, f(cost)),
                build_days: days,
                upkeep: Res::default().with(Resource::Energy, f(upkeep)),
                category: "planet_buildings".into(),
                jobs: vec![(job.into(), 2)],
            },
        );
    }
    for (i, area) in [Resource::Physics, Resource::Society, Resource::Engineering].iter().enumerate() {
        for tier in 0..10 {
            let prereq = if tier > 0 { vec![format!("tech_{i}_{}", tier - 1)] } else { vec![] };
            w.defs.techs.insert(format!("tech_{i}_{tier}"), TechDef { area: *area, cost: f(100 * (tier + 1)), prerequisites: prereq });
        }
    }
    let c = w.add_country("United Nations of Earth");
    w.countries.get_mut(&c).unwrap().stockpile = Res::default().with(Resource::Minerals, f(200)).with(Resource::Energy, f(100));
    let col = w.add_colony(c, "Earth");
    w.colonies.get_mut(&col).unwrap().buildings = vec!["mine".into(), "power_plant".into(), "lab".into()];
    w.add_pop_group(col, "human", 800);
    w.add_leader(c, 50 * 360);

    let mut sim = Simulation::new(GameState::new(Date::from_ymd(2200, 1, 1), seed, w), MockScriptHost::new());
    let t0 = std::time::Instant::now();
    for _ in 0..years {
        sim.run_days(360);
        let w = &sim.state.world;
        let c = &w.countries[&c];
        println!(
            "{:?}  pops {:3}  buildings {:3}  minerals {:?}  energy {:?}  techs {:2}  rng position {}",
            sim.state.date,
            w.colony_pops(col),
            w.colonies[&col].buildings.len(),
            c.stockpile.get(Resource::Minerals),
            c.stockpile.get(Resource::Energy),
            c.techs.len(),
            sim.state.rng.position
        );
    }
    println!("{} ticks in {:?}, checksum {:016x}", sim.ticks, t0.elapsed(), checksum(&sim.state));
}
