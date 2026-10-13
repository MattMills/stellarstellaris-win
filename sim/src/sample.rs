//! A small vanilla-like world for runs with the game's script: three empires with the properties
//! vanilla triggers read (`is_country_type`, `has_ethic`, `has_authority`, `has_civic`,
//! `has_origin`, `is_planet_class`, ...), capitals with pops, buildings and leaders, and a few
//! jobs and buildings for the economy.

use crate::fixed::Fixed;
use crate::state::{BuildingDef, Id, JobDef, Res, Resource, TechDef, World};

fn set(w: &mut World, c: Id, name: &str, members: &[&str]) {
    let s = w.countries.get_mut(&c).unwrap().sets.entry(name.to_string()).or_default();
    for m in members {
        s.insert(m.to_string());
    }
}

fn attr(w: &mut World, c: Id, name: &str, v: &str) {
    w.countries.get_mut(&c).unwrap().attrs.insert(name.into(), v.into());
}

pub fn defs(w: &mut World) {
    let f = Fixed::from_int;
    for (c, p) in [
        ("planet_jobs", None),
        ("planet_miners", Some("planet_jobs")),
        ("planet_technician", Some("planet_jobs")),
        ("planet_researchers", Some("planet_jobs")),
        ("planet_farmers", Some("planet_jobs")),
        ("planet_buildings", None),
    ] {
        w.defs.categories.insert(c.into(), p.map(String::from));
    }
    let job = |cat: &str, res: Res| JobDef { category: cat.into(), produces: res, upkeep: Res::default() };
    w.defs.jobs.insert("miner".into(), job("planet_miners", Res::default().with(Resource::Minerals, f(4))));
    w.defs.jobs.insert("technician".into(), job("planet_technician", Res::default().with(Resource::Energy, f(6))));
    w.defs.jobs.insert("farmer".into(), job("planet_farmers", Res::default().with(Resource::Food, f(6))));
    w.defs.jobs.insert(
        "researcher".into(),
        job(
            "planet_researchers",
            Res::default().with(Resource::Physics, f(4)).with(Resource::Society, f(4)).with(Resource::Engineering, f(4)),
        ),
    );
    for (name, cost, days, upkeep, jobname) in [
        ("building_mine", 50, 60, 1, "miner"),
        ("building_power_plant", 75, 90, 0, "technician"),
        ("building_farm", 50, 60, 0, "farmer"),
        ("building_research_lab_1", 100, 120, 2, "researcher"),
    ] {
        w.defs.buildings.insert(
            name.into(),
            BuildingDef {
                cost: Res::default().with(Resource::Minerals, f(cost)),
                build_days: days,
                upkeep: Res::default().with(Resource::Energy, f(upkeep)),
                category: "planet_buildings".into(),
                jobs: vec![(jobname.into(), 2)],
            },
        );
    }
    for (i, area) in [Resource::Physics, Resource::Society, Resource::Engineering].iter().enumerate() {
        for tier in 0..10 {
            let prereq = if tier > 0 { vec![format!("tech_{i}_{}", tier - 1)] } else { vec![] };
            w.defs.techs.insert(format!("tech_{i}_{tier}"), TechDef { area: *area, cost: f(150 * (tier + 1)), prerequisites: prereq });
        }
    }
}

/// Three empires (a democracy, a machine intelligence, a hive mind), each with a capital.
pub fn vanilla_like_world() -> World {
    let mut w = World::default();
    defs(&mut w);
    let f = Fixed::from_int;
    let empires: [(&str, &str, &[&str], &str, &[&str], &str); 3] = [
        ("United Nations of Earth", "humans", &["ethic_egalitarian", "ethic_xenophile"], "auth_democratic", &["civic_beacon_of_liberty", "civic_idealistic_foundation"], "pc_continental"),
        ("Machine Intelligence", "machines", &["ethic_gestalt_consciousness"], "auth_machine_intelligence", &["civic_machine_terraforming"], "pc_arid"),
        ("Hive of Kel", "kel", &["ethic_gestalt_consciousness"], "auth_hive_mind", &["civic_hive_strength_of_legions"], "pc_ocean"),
    ];
    for (i, (name, species, ethics, authority, civics, class)) in empires.iter().enumerate() {
        let c = w.add_country(name);
        attr(&mut w, c, "is_country_type", "default");
        attr(&mut w, c, "is_ai", if i == 0 { "no" } else { "yes" });
        attr(&mut w, c, "is_regular_empire", if i == 0 { "yes" } else { "no" });
        attr(&mut w, c, "is_gestalt", if i == 0 { "no" } else { "yes" });
        attr(&mut w, c, "is_machine_empire", if i == 1 { "yes" } else { "no" });
        attr(&mut w, c, "is_hive_empire", if i == 2 { "yes" } else { "no" });
        set(&mut w, c, "has_ethic", ethics);
        set(&mut w, c, "has_authority", &[authority]);
        set(&mut w, c, "has_civic", civics);
        set(&mut w, c, "has_valid_civic", civics);
        set(&mut w, c, "has_origin", &["origin_default"]);
        w.countries.get_mut(&c).unwrap().stockpile = Res::default()
            .with(Resource::Energy, f(100))
            .with(Resource::Minerals, f(200))
            .with(Resource::Food, f(100))
            .with(Resource::Influence, f(100))
            .with(Resource::Unity, f(100));
        let col = w.add_colony(c, &format!("{name} Prime"));
        {
            let colony = w.colonies.get_mut(&col).unwrap();
            colony.buildings =
                vec!["building_mine".into(), "building_power_plant".into(), "building_farm".into(), "building_research_lab_1".into()];
            colony.attrs.insert("is_planet_class".into(), class.to_string());
            colony.attrs.insert("is_capital".into(), "yes".into());
            colony.attrs.insert("is_homeworld".into(), "yes".into());
            colony.attrs.insert("has_owner".into(), "yes".into());
            colony.attrs.insert("is_colony".into(), "yes".into());
        }
        w.add_pop_group(col, species, 1000);
        let second = w.add_colony(c, &format!("{name} II"));
        {
            let colony = w.colonies.get_mut(&second).unwrap();
            colony.buildings = vec!["building_farm".into()];
            colony.attrs.insert("is_planet_class".into(), "pc_desert".into());
            colony.attrs.insert("has_owner".into(), "yes".into());
            colony.attrs.insert("is_colony".into(), "yes".into());
        }
        w.add_pop_group(second, species, 300);
        w.add_leader(c, 45 * 360);
        w.add_leader(c, 60 * 360);
    }
    w
}
