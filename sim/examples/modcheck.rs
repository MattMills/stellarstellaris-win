//! The modifier check: `cargo run --release --example modcheck` (paths from the environment or
//! the defaults of `stellar_sim::modcheck::Inputs::from_env`).

fn main() {
    let Some(inputs) = stellar_sim::modcheck::Inputs::from_env() else {
        eprintln!("inputs missing: set MODCHECK_NODES, MODCHECK_TYPES, MODCHECK_SAVE, STELLARIS_DIR");
        std::process::exit(2);
    };
    match stellar_sim::modcheck::run(&inputs) {
        Ok(r) => println!("{r}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
