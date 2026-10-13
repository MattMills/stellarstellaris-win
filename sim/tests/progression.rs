//! Tick order, determinism and the engine-effect barrier.

use stellar_sim::engine::checksums::checksum;
use stellar_sim::queue::{EngineEffect, Target};
use stellar_sim::scheduler::{DAILY_PHASES, MONTHLY_PHASES, YEARLY_PHASES};
use stellar_sim::script::MockOp;
use stellar_sim::state::{BuildingDef, JobDef, Res, Resource, TechDef};
use stellar_sim::{Date, Fixed, GameState, MockScriptHost, Phase, Scope, Simulation, World};

fn world() -> World {
    let mut w = World::default();
    let f = Fixed::from_int;
    w.defs.categories.insert("planet_jobs".into(), None);
    w.defs.categories.insert("planet_miners".into(), Some("planet_jobs".into()));
    w.defs.categories.insert("planet_technician".into(), Some("planet_jobs".into()));
    w.defs.categories.insert("planet_researchers".into(), Some("planet_jobs".into()));
    w.defs.categories.insert("planet_buildings".into(), None);
    w.defs.jobs.insert(
        "miner".into(),
        JobDef { category: "planet_miners".into(), produces: Res::default().with(Resource::Minerals, f(4)), upkeep: Res::default() },
    );
    w.defs.jobs.insert(
        "technician".into(),
        JobDef { category: "planet_technician".into(), produces: Res::default().with(Resource::Energy, f(6)), upkeep: Res::default() },
    );
    w.defs.jobs.insert(
        "researcher".into(),
        JobDef {
            category: "planet_researchers".into(),
            produces: Res::default().with(Resource::Physics, f(4)).with(Resource::Society, f(4)).with(Resource::Engineering, f(4)),
            upkeep: Res::default().with(Resource::ConsumerGoods, f(1)),
        },
    );
    w.defs.buildings.insert(
        "mine".into(),
        BuildingDef {
            cost: Res::default().with(Resource::Minerals, f(50)),
            build_days: 60,
            upkeep: Res::default().with(Resource::Energy, f(1)),
            category: "planet_buildings".into(),
            jobs: vec![("miner".into(), 2)],
        },
    );
    w.defs.buildings.insert(
        "power_plant".into(),
        BuildingDef {
            cost: Res::default().with(Resource::Minerals, f(75)),
            build_days: 90,
            upkeep: Res::default(),
            category: "planet_buildings".into(),
            jobs: vec![("technician".into(), 2)],
        },
    );
    w.defs.buildings.insert(
        "lab".into(),
        BuildingDef {
            cost: Res::default().with(Resource::Minerals, f(100)),
            build_days: 120,
            upkeep: Res::default().with(Resource::Energy, f(2)),
            category: "planet_buildings".into(),
            jobs: vec![("researcher".into(), 2)],
        },
    );
    for (i, area) in [Resource::Physics, Resource::Society, Resource::Engineering].iter().enumerate() {
        for tier in 0..4 {
            let name = format!("tech_{i}_{tier}");
            let prereq = if tier > 0 { vec![format!("tech_{i}_{}", tier - 1)] } else { vec![] };
            w.defs.techs.insert(name, TechDef { area: *area, cost: f(60 * (tier + 1)), prerequisites: prereq });
        }
    }
    let c = w.add_country("United Nations of Earth");
    w.countries.get_mut(&c).unwrap().stockpile = Res::default().with(Resource::Minerals, f(200)).with(Resource::Energy, f(100));
    let col = w.add_colony(c, "Earth");
    {
        let colony = w.colonies.get_mut(&col).unwrap();
        colony.buildings = vec!["mine".into(), "power_plant".into(), "lab".into()];
    }
    w.add_pop_group(col, "human", 500);
    w.add_pop_group(col, "human_alt", 200);
    w.add_leader(c, 69 * 360);
    w.add_leader(c, 40 * 360);
    w
}

fn sim(seed: u32, script: MockScriptHost) -> Simulation<MockScriptHost> {
    Simulation::new(GameState::new(Date::from_ymd(2200, 1, 1), seed, world()), script)
}

#[test]
fn one_day_is_ten_ticks_with_ai_on_the_fourth() {
    let mut s = sim(1, MockScriptHost::new());
    s.tracing = true;
    s.run_ticks(10);
    let coarse: Vec<Phase> = s
        .trace
        .iter()
        .filter(|p| matches!(p, Phase::Micro | Phase::Ai | Phase::DateAdvanced(_)))
        .cloned()
        .collect();
    let d = Date::from_ymd(2200, 1, 2);
    let mut want = vec![Phase::Micro, Phase::Micro, Phase::Micro, Phase::Micro, Phase::Ai];
    want.extend([Phase::Micro, Phase::Micro, Phase::Micro, Phase::Micro, Phase::Micro]);
    want.extend([Phase::DateAdvanced(d), Phase::Micro]);
    assert_eq!(coarse, want);
    // the day's phases come after the 10th MicroUpdate, in order
    let days: Vec<&str> = s.trace.iter().filter_map(|p| if let Phase::Daily(n) = p { Some(*n) } else { None }).collect();
    assert_eq!(days, DAILY_PHASES.to_vec());
    let last_micro = s.trace.iter().rposition(|p| *p == Phase::Micro).unwrap();
    let first_daily = s.trace.iter().position(|p| matches!(p, Phase::Daily(_))).unwrap();
    assert!(last_micro < first_daily);
    assert_eq!(s.state.date, d);
    assert_eq!(s.state.tick_count, 0);
}

#[test]
fn months_and_years_start_on_the_right_day() {
    let mut s = sim(1, MockScriptHost::new());
    s.tracing = true;
    s.run_days(29);
    assert!(!s.trace.iter().any(|p| matches!(p, Phase::Monthly(_))));
    s.run_days(1); // 2200.02.01
    assert_eq!(format!("{:?}", s.state.date), "2200.02.01");
    let months: Vec<&str> = s.trace.iter().filter_map(|p| if let Phase::Monthly(n) = p { Some(*n) } else { None }).collect();
    assert_eq!(months, MONTHLY_PHASES.to_vec());
    // the month runs after that day's daily phases
    let last_daily = s.trace.iter().rposition(|p| matches!(p, Phase::Daily(_))).unwrap();
    let first_monthly = s.trace.iter().position(|p| matches!(p, Phase::Monthly(_))).unwrap();
    assert!(last_daily < first_monthly);

    s.trace.clear();
    s.run_days(330); // 2201.01.01
    assert_eq!(format!("{:?}", s.state.date), "2201.01.01");
    let count = |f: &dyn Fn(&Phase) -> bool| s.trace.iter().filter(|p| f(p)).count();
    assert_eq!(count(&|p| *p == Phase::Monthly("budget")), 11);
    assert_eq!(count(&|p| *p == Phase::Ai), 330);
    assert_eq!(count(&|p| *p == Phase::Micro), 3300);
    let years: Vec<&str> = s.trace.iter().filter_map(|p| if let Phase::Yearly(n) = p { Some(*n) } else { None }).collect();
    assert_eq!(years, YEARLY_PHASES.to_vec());
    // the year runs after that day's month
    let last_monthly = s.trace.iter().rposition(|p| matches!(p, Phase::Monthly(_))).unwrap();
    let first_yearly = s.trace.iter().position(|p| matches!(p, Phase::Yearly(_))).unwrap();
    assert!(last_monthly < first_yearly);
}

fn random_script() -> MockScriptHost {
    let f = Fixed::from_int;
    MockScriptHost::new()
        .script(
            "on_monthly_pulse_country",
            vec![MockOp::IfRandomBelow {
                percent: 50,
                then: vec![
                    MockOp::SetFlag("lucky".into()),
                    MockOp::Engine(EngineEffect::AddResource { country: Target::Scope, resource: Resource::Energy, amount: f(10) }),
                ],
            }],
        )
        .script(
            "daily_events",
            vec![MockOp::IfRandomBelow {
                percent: 2,
                then: vec![MockOp::Engine(EngineEffect::AddModifier {
                    scope: Target::Scope,
                    source: "pm_lucky".into(),
                    entries: vec![("planet_jobs_produces_mult".into(), Fixed::from_centi(10))],
                    days: Some(90),
                    })],
            }],
        )
}

#[test]
fn deterministic_for_a_seed() {
    let run = |seed| {
        let mut s = sim(seed, random_script());
        s.run_days(720);
        (checksum(&s.state), s.state.rng.position, s.outcome)
    };
    let a = run(7);
    let b = run(7);
    assert_eq!(a, b);
    let c = run(8);
    assert_ne!(a.0, c.0);
    // the daily pool is 1,000 draws a day; script draws come on top
    assert!(a.1 >= 720 * 1000);
}

#[test]
fn engine_effects_wait_for_the_barrier() {
    let script = MockScriptHost::new().script(
        "colonize_moon",
        vec![
            MockOp::SetFlag("colonized".into()),
            MockOp::CreatePopGroup { species: "human".into(), size: 100 },
            MockOp::GrowLastCreatedPopGroup(200),
            MockOp::Engine(EngineEffect::AddResource { country: Target::Scope, resource: Resource::Unity, amount: Fixed::from_int(3) }),
        ],
    );
    let mut s = sim(1, script);
    let col = *s.state.world.colonies.keys().next().unwrap();
    let before = s.state.world.colony_pops(col);
    // run the effect without the barrier: the script effect is applied, the engine effects wait
    let out = s.with_script(|h, c| stellar_sim::ScriptHost::run_effect(h, "colonize_moon", Scope::Colony(col), c));
    assert_eq!(out.script_effects, 1);
    assert_eq!(out.engine_effects, 3);
    assert!(s.script.flags.contains(&(Scope::Colony(col), "colonized".into())));
    assert_eq!(s.state.world.colony_pops(col), before);
    assert_eq!(s.queue.len(), 3);
    // the barrier applies them in order, resolving the provisional handle
    assert_eq!(s.flush(), 3);
    assert_eq!(s.state.world.colony_pops(col), before + 3);
    let owner = s.state.world.colonies[&col].owner;
    assert_eq!(s.state.world.countries[&owner].stockpile.get(Resource::Unity), Fixed::from_int(3));
    // a command runs as a root effect before the next tick, with its own flush
    s.post_command(stellar_sim::Command::RunEffect { effect: "colonize_moon".into(), scope: Scope::Colony(col) });
    s.tick();
    assert_eq!(s.state.world.colony_pops(col), before + 6);
    assert!(s.queue.is_empty());
}

#[test]
fn the_economy_progresses() {
    let mut s = sim(42, MockScriptHost::new());
    let country = *s.state.world.countries.keys().next().unwrap();
    let col = *s.state.world.colonies.keys().next().unwrap();
    s.run_days(5 * 360);
    let w = &s.state.world;
    let c = &w.countries[&country];
    // jobs were filled and the budget ran: research completed, pops grew, the AI built
    assert!(!c.techs.is_empty(), "no technology researched");
    assert!(w.colony_pops(col) > 7, "no pop growth: {}", w.colony_pops(col));
    assert!(w.colonies[&col].buildings.len() > 3, "the AI built nothing");
    assert!(c.last_month_income.get(Resource::Minerals) > Fixed::ZERO);
    assert!(s.queue.dropped == 0);
    // the old leader died of old age at some point, or is still alive and aged
    let old = w.leaders.values().next().unwrap();
    assert!(!old.alive || old.age_days >= 74 * 360);
}

#[test]
fn modifiers_change_production() {
    let mut s = sim(3, MockScriptHost::new());
    let col = *s.state.world.colonies.keys().next().unwrap();
    s.run_days(1); // jobs assigned
    let base = stellar_sim::engine::economy::colony_balance(&s.state.world, col).get(Resource::Minerals);
    let owner = s.state.world.colonies[&col].owner;
    s.queue.push(
        Scope::Country(owner),
        EngineEffect::AddModifier { scope: Target::Scope, source: "edict".into(), entries: vec![("planet_jobs_produces_mult".into(), Fixed::from_centi(50))], days: None },
    );
    s.flush();
    let boosted = stellar_sim::engine::economy::colony_balance(&s.state.world, col).get(Resource::Minerals);
    assert_eq!(boosted, base.mul(Fixed::from_centi(150)));
}
