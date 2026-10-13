//! The engine subsystems: what the game's C++ simulates and the Lua script layer cannot.
//!
//! One module per subsystem of docs/simulation.md (section 2). The kept ones (economy, pops,
//! colonies, construction, research, country, modifiers) have a minimal working model; the
//! deferred ones (fleets, combat, diplomacy, AI) are stubs. Each module's doc names the C++
//! functions it replaces (GOG 4.5.2 RVAs).
//!
//! Engine code that fires script returns [`events::CallIn`]s; the scheduler dispatches them to the
//! `ScriptHost` as root effects (with a flush after each), where the game calls
//! `COnActionDatabase::PerformEvent` / `CEventManager::TriggerEvent` inside its serial updates.

pub mod ai;
pub mod checksums;
pub mod colonies;
pub mod combat;
pub mod construction;
pub mod country;
pub mod diplomacy;
pub mod economy;
pub mod events;
pub mod fleets;
pub mod modifiers;
pub mod pops;
pub mod research;
