//! Engine -> script call-ins: events and on_actions.
//!
//! Events, their triggers, MTTH, delayed events and on_action lists belong to the script layer
//! (Lua). The engine only says when: the C++ this replaces is the plumbing, not the content:
//!
//! - `COnActionDatabase::PerformEvent` (`0x3fa240`, `0x3fa2d0`): 263 call sites in engine code
//!   (colonization, ownership, combat, deaths, policies, ...), and the pulses from
//!   `CGameState::MonthlyUpdate` / `YearlyUpdate` / `CCountry::MonthlyUpdateSerial`;
//! - `CEventManager::TriggerEvent` (`0x3f6170`): 23 callers (delayed events, country event
//!   modules, colonies, research completion, archaeology, espionage, first contact);
//! - `CDelayedEventManager::DailyUpdateThreaded` (`0xaa26b0`, countdown and pre-evaluation in the
//!   parallel phase) and `DailyUpdateSerial` (`0xaa2370`, firing), per country, leader, planet,
//!   galactic object and starbase;
//! - `CStandardEventCountryModule::DailyUpdateOnlyChangeSafePrivate` -> `CEvent::GetChance`
//!   (`0x8e76a0`, MTTH chances, parallel) and `DailyUpdateSerial` (`0x84d9a0`, firing).
//!
//! In the skeleton a scope's daily events are one `ScriptHost::scope_daily_events` call in the
//! serial phase; pulses and engine on_actions are [`CallIn::OnAction`].

use crate::script::Scope;

/// The periodic on_actions of vanilla `common/on_actions` (names are strings in the executable).
pub const ON_MONTHLY_PULSE: &str = "on_monthly_pulse";
pub const ON_MONTHLY_PULSE_COUNTRY: &str = "on_monthly_pulse_country";
pub const ON_YEARLY_PULSE: &str = "on_yearly_pulse";
pub const ON_YEARLY_PULSE_COUNTRY: &str = "on_yearly_pulse_country";
pub const ON_BI_YEARLY_PULSE: &str = "on_bi_yearly_pulse";
pub const ON_BI_YEARLY_PULSE_COUNTRY: &str = "on_bi_yearly_pulse_country";
pub const ON_FIVE_YEAR_PULSE: &str = "on_five_year_pulse";
pub const ON_FIVE_YEAR_PULSE_COUNTRY: &str = "on_five_year_pulse_country";
pub const ON_DECADE_PULSE: &str = "on_decade_pulse";
pub const ON_DECADE_PULSE_COUNTRY: &str = "on_decade_pulse_country";
/// Engine on_actions the kept subsystems fire.
pub const ON_TECH_INCREASED: &str = "on_tech_increased";
pub const ON_BUILDING_COMPLETE: &str = "on_building_complete";
pub const ON_POP_ASSEMBLED: &str = "on_pop_assembled";
pub const ON_LEADER_DEATH: &str = "on_leader_death";
pub const ON_ENTERING_SYSTEM: &str = "on_entering_system";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CallIn {
    OnAction { name: &'static str, scope: Scope },
}

impl CallIn {
    pub fn on_action(name: &'static str, scope: Scope) -> CallIn {
        CallIn::OnAction { name, scope }
    }
}
