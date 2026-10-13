//! The modifier sources (`sim/lua/engine/modifiers.lua`): every Country, Planet, Colony and PopGroup
//! node's own parts computed from the save and the vanilla files, fed into the modifier graph
//! (`lua/stellar/graph`, built from the capture's structure) and compared with the game's nodes in a
//! capture of the same moment (`sim/lua/engine/modifiers/check.lua`). Prints, per category, nodes
//! exact, values within 0.001, own parts matched and the types that differ most.
//!
//! `cargo test --release --test modifiers -- --nocapture`; skipped when the game, the save or the
//! capture is not on this machine. Paths: `STELLARIS_DIR`, `STELLAR_SAVE`, `MODCHECK_NODES`,
//! `MODCHECK_TYPES` (defaults: the dev machine's, then 10.5.0.24's `/opt/stellaris-captures`).
//! Without the Rust runtime: `luajit sim/tools/modifiers.lua`.

use std::path::Path;

use stellar_sim::{save, Runtime};

fn first_existing(var: &str, candidates: &[&str]) -> Option<String> {
    if let Ok(v) = std::env::var(var) {
        return Path::new(&v).exists().then_some(v);
    }
    candidates.iter().find(|p| Path::new(p).exists()).map(|p| p.to_string())
}

#[test]
fn modifier_sources_against_the_capture() {
    let nodes = first_existing(
        "MODCHECK_NODES",
        &[r"C:\lfm\captures\modifier-nodes-2210.tsv", "/opt/stellaris-captures/modifier-nodes-2210.tsv"],
    );
    let types =
        first_existing("MODCHECK_TYPES", &[r"C:\lfm\captures\modifiers-2210.log", "/opt/stellaris-captures/modifiers-2210.log"]);
    let save_path = save::default_save().or_else(|| first_existing("", &["/opt/stellaris-saves/autosave_2210.01.01.sav"]));
    let (Some(nodes), Some(types), Some(game_dir), Some(save_path)) = (nodes, types, save::game_dir(), save_path) else {
        eprintln!("skipped: the game, the save or the capture is not on this machine");
        return;
    };
    let gamestate = save::read_gamestate(&save_path).expect("read the save");
    let date = save::date_of(&gamestate).expect("the save's date");
    let rt = Runtime::new(date, 7).expect("the Lua runtime");
    rt.load(&game_dir, Some(&gamestate), None).expect("load");
    drop(gamestate);
    let fwd = |s: &str| s.replace('\\', "/");
    let chunk = format!(
        r#"return (require("engine.modifiers.check").run({{ nodes_tsv = {:?}, types_log = {:?}, game_dir = {:?} }}))"#,
        fwd(&nodes),
        fwd(&types),
        fwd(&game_dir)
    );
    let report: String = rt.eval(&chunk).expect("the check");
    println!("{report}");
    for cat in ["Country:", "Planet:", "Colony:", "PopGroup:"] {
        assert!(report.contains(cat), "no {cat} section");
    }
}
