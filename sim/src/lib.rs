//! A new engine for Stellaris 4.5.2: Rust is the platform, the game is in Lua from the game's own
//! files.
//!
//! - the definitions: every `common/` folder of the vanilla file set, read in place
//!   (`sim/lua/engine/defs.lua`);
//! - the script layer: events, on_actions, scripted triggers, effects and values, evaluated in Lua
//!   (`sim/lua/simscript`);
//! - the world: the game state from a save, in the save's own form (`sim/lua/engine/world.lua`);
//! - the engine's systems, phase by phase (`sim/lua/engine/systems.lua`), checked against the
//!   game's next save.
//!
//! Module map:
//! - [`fixed`]: `CFixedPoint` (int64, 1.0 = 100000)
//! - [`rng`]: the game's random number generator (`CRandom::_Random`, a `CNoiseRandom`)
//! - [`date`]: `CDate` / `CStellarisDate` (hours, 12 x 30-day months)
//! - [`save`]: reading saves
//! - [`runtime`]: the Lua runtime the game runs in
//! - [`scheduler`]: `HandleTurnTick`, `MicroUpdate`, `DailyUpdate`, `MonthlyUpdate`, `YearlyUpdate`
//! - [`modcheck`]: the modifier model against a capture of the game's modifier nodes
//! - [`frametime`]: the simulation inside a rendered game's frames, timed (docs/frame_timing.md)
//! - [`preempt`]: the Lua VM stopping a coroutine past a deadline (a count hook that yields)
//! - [`cadence`]: the simulation's threads in 1 ms slices, every other millisecond unused

pub mod cadence;
pub mod date;
pub mod fixed;
pub mod frametime;
pub mod modcheck;
pub mod preempt;
pub mod rng;
pub mod runtime;
pub mod save;
pub mod scheduler;
pub mod store;
pub mod workers;

/// The Lua binding, for callers that pass tables to and from the runtime.
pub use mlua;

pub use date::Date;
pub use fixed::Fixed;
pub use rng::NoiseRandom;
pub use runtime::Runtime;
pub use scheduler::{Command, Phase, Simulation, Step, Unit};
