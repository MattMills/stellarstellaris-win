//! A skeleton simulation of Stellaris 4.5.2's progression.
//!
//! The game's tick (`CGameState::HandleTurnTick`) in the game's order, with the script layer
//! (the Lua PDXScript layer: triggers, effects, events, flags, variables) behind [`script::ScriptHost`]
//! and the engine's own work (economy, pops, colonies, construction, research, ...) as subsystems in
//! [`engine`]. Script effects are applied by the script host directly; engine effects are queued
//! ([`queue::EngineQueue`]) and drained at the game's barriers. See `docs/simulation.md`.
//!
//! Module map:
//! - [`fixed`]: `CFixedPoint` (int64, 1.0 = 100000)
//! - [`rng`]: the game's random number generator (`CRandom::_Random`, a `CNoiseRandom`)
//! - [`date`]: `CDate` / `CStellarisDate` (hours, 12 x 30-day months)
//! - [`state`]: the game state of the subsystems the minimal simulation keeps
//! - [`script`]: the `ScriptHost` trait and a mock
//! - [`queue`]: the Lua -> engine effect queue
//! - [`engine`]: one module per engine subsystem, each naming the C++ it replaces
//! - [`scheduler`]: `HandleTurnTick`, `MicroUpdate`, `DailyUpdate`, `MonthlyUpdate`, `YearlyUpdate`

pub mod date;
pub mod engine;
pub mod fixed;
pub mod lua_host;
pub mod modcheck;
pub mod queue;
pub mod rng;
pub mod sample;
pub mod scheduler;
pub mod script;
pub mod state;

pub use date::Date;
pub use fixed::Fixed;
pub use lua_host::LuaScriptHost;
pub use rng::NoiseRandom;
pub use scheduler::{Command, Phase, Simulation};
pub use script::{EffectOutcome, MockScriptHost, Scope, ScriptCtx, ScriptHost};
pub use state::{GameState, Id, World};
