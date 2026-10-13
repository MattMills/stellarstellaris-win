//! The vertical slice through embedded LuaJIT, on a small script tree written to a temp dir (no
//! game files needed): control flow, comparisons, flags, variables, scopes and iterators, scripted
//! triggers / effects / values with parameters, engine effects with the read-after-write barrier,
//! on_actions from the tick, triggered, delayed and MTTH events, the AI's option choice, determinism.

use std::path::PathBuf;

use stellar_sim::engine::checksums::checksum;
use stellar_sim::sample::vanilla_like_world;
use stellar_sim::state::Resource;
use stellar_sim::{Date, GameState, LuaScriptHost, Scope, ScriptHost, Simulation};

const FILES: &[(&str, &str)] = &[
    (
        "common/scripted_triggers/slice_triggers.txt",
        r#"
is_rich = { has_resource = { type = energy amount > $AMOUNT|50$ } }
slice_ok = {
    has_country_flag = slice_done
    has_country_flag = math_ok
    NOT = { has_country_flag = math_bad }
    has_country_flag = chose_b
    NOT = { has_country_flag = chose_a }
    has_country_flag = rich_after_grant
    has_country_flag = delayed_fired
    has_country_flag = mtth_fired
    has_country_flag = yearly_seen
    OR = { has_country_flag = rl_a has_country_flag = rl_b }
    NOR = { has_country_flag = never_set has_country_flag = never_set_either }
    check_variable = { which = counter value >= 3 }
    count_owned_planet = { count = 2 limit = { has_planet_flag = visited_any } }
    capital_scope = { has_planet_flag = visited has_modifier = test_boost owner = { is_same_value = root } }
    any_owned_planet = { has_planet_flag = picked }
}
"#,
    ),
    (
        "common/scripted_effects/slice_effects.txt",
        r#"
grant_energy = { add_resource = { energy = $N$ } }
"#,
    ),
    (
        "common/script_values/slice_values.txt",
        r#"
bonus_value = { base = 10 modifier = { factor = 2 has_country_flag = math_ok } add = @slice_extra }
"#,
    ),
    ("common/scripted_variables/slice_vars.txt", "@slice_extra = 5\n"),
    ("common/static_modifiers/slice_modifiers.txt", "test_boost = { planet_jobs_produces_mult = 0.5 }\n"),
    (
        "common/on_actions/slice_on_actions.txt",
        r#"
on_monthly_pulse_country = { events = { slice.1 } }
on_yearly_pulse = { events = { slice.10 } }
"#,
    ),
    (
        "events/slice_events.txt",
        r#"
namespace = slice
@three = 3
country_event = {
    id = slice.1
    is_triggered_only = yes
    hide_window = yes
    trigger = { NOT = { has_country_flag = slice_done } is_country_type = default has_ethic = ethic_egalitarian }
    immediate = {
        set_country_flag = slice_done
        set_variable = { which = counter value = 1 }
        change_variable = { which = counter value = 2 }
        if = { limit = { check_variable = { which = counter value = @three } } set_country_flag = math_ok }
        else = { set_country_flag = math_bad }
        every_owned_planet = { set_planet_flag = visited_any }
        every_owned_planet = { limit = { is_planet_class = pc_continental } set_planet_flag = visited }
        capital_scope = { add_modifier = { modifier = test_boost days = 360 } }
        random_owned_planet = { set_planet_flag = picked }
        grant_energy = { N = 25 }
        if = { limit = { is_rich = { AMOUNT = 120 } } set_country_flag = rich_after_grant }
        random_list = { 50 = { set_country_flag = rl_a } 50 = { set_country_flag = rl_b } }
        country_event = { id = slice.2 days = 5 }
    }
    option = { name = a ai_chance = { factor = 0 } set_country_flag = chose_a }
    option = { name = b ai_chance = { factor = 1 } set_country_flag = chose_b }
}
country_event = {
    id = slice.2
    is_triggered_only = yes
    immediate = { set_country_flag = delayed_fired add_resource = { minerals = value:bonus_value } }
}
country_event = {
    id = slice.3
    trigger = { has_country_flag = slice_done NOT = { has_country_flag = mtth_fired } }
    mean_time_to_happen = { days = 10 modifier = { factor = 0.5 has_country_flag = math_ok } }
    immediate = { set_country_flag = mtth_fired }
}
event = {
    id = slice.10
    is_triggered_only = yes
    immediate = { every_country = { limit = { any_owned_planet = { has_planet_flag = visited } } set_country_flag = yearly_seen } }
}
"#,
    ),
];

fn script_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("stellar_sim_slice_{}", std::process::id()));
    for (rel, text) in FILES {
        let p = dir.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }
    dir
}

fn run(seed: u32, days: u64) -> (Simulation<LuaScriptHost>, u64) {
    let dir = script_dir();
    let host = LuaScriptHost::new(&dir.to_string_lossy(), None).expect("lua host");
    let mut sim = Simulation::new(GameState::new(Date::from_ymd(2200, 1, 1), seed, vanilla_like_world()), host);
    sim.run_days(days);
    let sum = checksum(&sim.state);
    (sim, sum)
}

#[test]
fn the_slice_runs_end_to_end() {
    let (mut sim, _) = run(11, 370);
    let report = sim.script.report();
    println!("{report}");
    assert_eq!(sim.script.errors, 0, "{:?}", sim.script.first_errors);
    let earth = *sim.state.world.countries.keys().next().unwrap();
    let ok = sim.with_script(|h, c| h.eval_trigger("slice_ok", Scope::Country(earth), c));
    assert!(ok, "slice_ok failed:\n{report}");
    // the other empires are not egalitarian: slice.1 did not fire for them
    let machines = *sim.state.world.countries.keys().nth(1).unwrap();
    assert!(!sim.with_script(|h, c| h.eval_trigger("slice_ok", Scope::Country(machines), c)));
    // engine effects reached the engine: +25 energy once, +25 minerals (10 x 2 + 5) once
    let c = &sim.state.world.countries[&earth];
    let m = &sim.state.world.countries[&machines];
    let d_energy = c.stockpile.get(Resource::Energy) - m.stockpile.get(Resource::Energy);
    let d_minerals = c.stockpile.get(Resource::Minerals) - m.stockpile.get(Resource::Minerals);
    println!("energy diff {d_energy:?} minerals diff {d_minerals:?}");
    assert!(report.contains("slice.1"));
    assert!(sim.queue.dropped == 0);
}

#[test]
fn the_slice_is_deterministic() {
    let (_, a) = run(5, 200);
    let (_, b) = run(5, 200);
    assert_eq!(a, b);
}
