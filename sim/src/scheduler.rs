//! The tick, in the game's order.
//!
//! `CSession::ProcessSynchronousCommands` executes the frame's commands (player and AI), then the
//! `CTurnTickCommand`, whose `Execute` runs `CGameState::HandleTurnTick` (`0x252830`):
//!
//! 1. `_nTickCount += 1`; the day tick is `_nTickCount % 10 == 0`;
//! 2. on the day tick: `_nTickCount = 0`, `_CurrentDate += 24` hours;
//! 3. every tick: `MicroUpdate` (movement, combat);
//! 4. `_nTickCount % 10 == 4`: `ProcessAI` (once a day);
//! 5. on the day tick: cache the date, `DailyUpdate`, then `MonthlyUpdate` if the month index
//!    changed, then `YearlyUpdate` if the year changed.
//!
//! The phases of `DailyUpdate` / `MonthlyUpdate` / `YearlyUpdate` are the game's (docs/simulation.md,
//! section 1). Each runs in the Lua engine (`engine.phase`), followed by its barrier (the engine
//! effects queued in it applied). Parallel phases run with random draws forbidden; the day's pool of
//! 1,000 draws is taken where the game takes it.

use crate::date::Date;
use crate::rng::DAILY_POOL_SIZE;

/// Values drawn at the start of `MonthlyUpdate` for the colonies' demography.
pub const MONTHLY_POOL_SIZE: usize = 1000;
use crate::runtime::Runtime;

/// A synchronized command (`CCommand`), executed before the next tick.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// A player action implemented in script (a decision, an event option): a scripted effect or
    /// an event, on a scope (`country`, `planet`, ... and its id).
    Effect { effect: String, kind: String, id: u32 },
}

/// What ran, for tests and tracing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Phase {
    Commands(usize),
    DateAdvanced(Date),
    Micro,
    Ai,
    Daily(&'static str),
    Monthly(&'static str),
    Yearly(&'static str),
}

/// The daily phases, in order (`CGameState::DailyUpdate`, `0x25cde0`).
pub const DAILY_PHASES: [&str; 13] = [
    "script_state_expiry",  // the daily task graph: CPdxIntegerFlags::UpdateFlags
    "construction_manager", // CConstructionManager::DailyUpdate
    "random_pool",          // 1,000 x CRandom::GetIntegerForMacro (0x25e6a0)
    "modifiers_1",          // CModifierNodeManager::Update (0x25e898)
    "countries_parallel",   // CCountry::DailyUpdateSelfDontReadOthers (timed modifiers)
    "countries_serial",     // CCountry::DailyUpdateSerial: events, research, edicts
    "modifiers_2",          // CModifierNodeManager::Update (0x25eec3)
    "colonies_parallel",    // NColonyUpdate::DailyParallelUpdate
    "colonies_serial",      // NColonyUpdate::DailySerialUpdate: jobs, construction
    "pop_groups",           // CPopGroup::DailyUpdate*
    "ships_fleets_armies",  // with the random pool
    "leaders",              // with the random pool, then CLeader::DailyUpdateSerial
    "galaxy",               // market, galactic community, borders, ...
];

/// The daily phases that run in parallel in the game: no random draws (they use the pool).
const PARALLEL: [&str; 5] = ["modifiers_1", "countries_parallel", "modifiers_2", "colonies_parallel", "pop_groups"];

/// The monthly phases, in order (`CGameState::MonthlyUpdate`, `0x261620`).
pub const MONTHLY_PHASES: [&str; 5] = [
    "modifiers",        // CModifierNodeManager::Update (0x26195f)
    "budget",           // CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>
    "countries_serial", // CCountry::MonthlyUpdateSerial: on_monthly_pulse_country
    "colonies",         // NColonyUpdate::MonthlyUpdate: growth, jobs
    "on_monthly_pulse", // COnActionDatabase::PerformEvent
];

/// The yearly phases, in order (`CGameState::YearlyUpdate`).
pub const YEARLY_PHASES: [&str; 2] = [
    "on_yearly_pulse", // COnActionDatabase::PerformEvent (and the longer pulses)
    "cleanup",         // ClearUnusedShipDesigns, ClearInvalidFleetDesigns
];

pub struct Simulation {
    pub runtime: Runtime,
    pub tracing: bool,
    pub trace: Vec<Phase>,
    pub ticks: u64,
    /// Lua errors raised by phases (the phase is cut short, the tick goes on).
    pub errors: Vec<String>,
    tick_count: i32,
    cached_month: i32,
    cached_year: i32,
    commands: Vec<Command>,
    pool: Vec<i32>,
}

impl Simulation {
    /// A simulation over a loaded runtime, at its date.
    pub fn new(runtime: Runtime) -> Simulation {
        let d = runtime.date.get();
        Simulation {
            runtime,
            tracing: false,
            trace: Vec::new(),
            ticks: 0,
            errors: Vec::new(),
            tick_count: 0,
            cached_month: d.month_index(),
            cached_year: d.year(),
            commands: Vec::new(),
            pool: Vec::new(),
        }
    }

    pub fn date(&self) -> Date {
        self.runtime.date.get()
    }

    /// Posts a command (`PostCommandToSession`); it runs before the next tick.
    pub fn post_command(&mut self, c: Command) {
        self.commands.push(c);
    }

    fn mark(&mut self, p: Phase) {
        if self.tracing {
            self.trace.push(p);
        }
    }

    fn phase(&mut self, kind: &str, name: &str, parallel: bool) {
        let old = self.runtime.rng.borrow_mut().set_forbidden(parallel);
        if let Err(e) = self.runtime.phase(kind, name) {
            if self.errors.len() < 20 {
                self.errors.push(format!("{kind}.{name}: {e}"));
            }
        }
        self.runtime.rng.borrow_mut().set_forbidden(old);
    }

    /// One `CSession::ProcessSynchronousCommands` pass: the commands, then `HandleTurnTick`.
    pub fn tick(&mut self) {
        let cmds = std::mem::take(&mut self.commands);
        if !cmds.is_empty() {
            self.mark(Phase::Commands(cmds.len()));
            for c in cmds {
                let Command::Effect { effect, kind, id } = c;
                if let Err(e) = self.runtime.command_effect(&effect, &kind, id) {
                    self.errors.push(format!("command {effect}: {e}"));
                }
            }
        }

        self.tick_count += 1;
        let phase = self.tick_count % 10;
        let day = phase == 0;
        if day {
            self.tick_count = 0;
            let d = self.date().add_days(1);
            self.runtime.date.set(d);
            self.mark(Phase::DateAdvanced(d));
        }

        // CGameState::MicroUpdate (0x253cf0): movement, combat
        self.mark(Phase::Micro);
        self.phase("micro", "update", false);
        // CGameState::ProcessAI (0x264600): decisions become commands for the next tick
        if phase == 4 {
            self.mark(Phase::Ai);
            self.phase("ai", "process", false);
        }
        if day {
            let (old_month, old_year) = (self.cached_month, self.cached_year);
            self.cached_month = self.date().month_index();
            self.cached_year = self.date().year();
            self.daily_update();
            if self.cached_month != old_month {
                self.monthly_update();
            }
            if self.cached_year != old_year {
                self.yearly_update();
            }
        }
        self.ticks += 1;
    }

    pub fn run_ticks(&mut self, n: u64) {
        for _ in 0..n {
            self.tick();
        }
    }

    pub fn run_days(&mut self, days: u64) {
        self.run_ticks(days * 10);
    }

    /// `CGameState::DailyUpdate` (`0x25cde0`).
    fn daily_update(&mut self) {
        for name in DAILY_PHASES {
            self.mark(Phase::Daily(name));
            if name == "random_pool" {
                self.pool = self.runtime.rng.borrow_mut().draw_pool(DAILY_POOL_SIZE);
                *self.runtime.daily_pool.borrow_mut() = self.pool.clone();
            } else {
                self.phase("daily", name, PARALLEL.contains(&name));
            }
        }
    }

    /// `CGameState::MonthlyUpdate` (`0x261620`): first the month's pool of 1,000 draws (`0x26169a`),
    /// read by the colonies' demography (docs/pops.md), then the phases.
    fn monthly_update(&mut self) {
        let pool = self.runtime.rng.borrow_mut().draw_pool(MONTHLY_POOL_SIZE);
        *self.runtime.monthly_pool.borrow_mut() = pool;
        for name in MONTHLY_PHASES {
            self.mark(Phase::Monthly(name));
            self.phase("monthly", name, name == "modifiers");
        }
    }

    /// `CGameState::YearlyUpdate`.
    fn yearly_update(&mut self) {
        for name in YEARLY_PHASES {
            self.mark(Phase::Yearly(name));
            self.phase("yearly", name, false);
        }
    }

    /// The day's pool of random draws (taken in `random_pool`), for the parallel phases.
    pub fn pool(&self) -> &[i32] {
        &self.pool
    }
}
