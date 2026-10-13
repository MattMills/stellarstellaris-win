//! The modifier check against the capture of the game's modifier nodes (skipped when the capture,
//! the save or the game is not on this machine).

#[test]
fn modifier_nodes_against_the_capture() {
    let Some(inputs) = stellar_sim::modcheck::Inputs::from_env() else {
        eprintln!("capture, save or game not found: skipped");
        return;
    };
    let report = stellar_sim::modcheck::run(&inputs).expect("modcheck");
    println!("{report}");
    assert!(report.contains("internal check:"));
    assert!(report.contains("countries:"));
}
