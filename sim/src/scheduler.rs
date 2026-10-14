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
//!
//! A tick can also be run a [`Unit`] at a time ([`Simulation::step`]): a renderer that gives the
//! simulation what is left of each frame runs units until the frame's time is used, and goes on with
//! the same tick in the next frame (docs/frame_timing.md). Stepping and [`Simulation::tick`] run the
//! same units in the same order.

use std::collections::VecDeque;

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
pub const DAILY_PHASES: [&str; 14] = [
    "ai_attitudes",         // CCountryAI::UpdateAttitudesThreaded (each AI every 10 days)
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
const PARALLEL: [&str; 6] = ["ai_attitudes", "modifiers_1", "countries_parallel", "modifiers_2", "colonies_parallel", "pop_groups"];

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

/// The pieces a tick is run in by [`Simulation::step`]: one phase each, which cannot be cut
/// shorter (a phase is one call into the Lua engine, and its barrier).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Unit {
    /// `MicroUpdate`, every tick (the first unit of a tick, after the commands)
    Micro,
    /// `ProcessAI`, on the tick `_nTickCount % 10 == 4`
    Ai,
    /// a phase of `DailyUpdate` (`random_pool` draws the day's pool)
    Daily(&'static str),
    /// a phase of `MonthlyUpdate` (the first draws the month's pool before it runs)
    Monthly(&'static str),
    /// a phase of `YearlyUpdate`
    Yearly(&'static str),
}

impl Unit {
    /// The phase's kind, as in [`Simulation::phase_times`]: micro, ai, daily, monthly, yearly.
    pub fn kind(&self) -> &'static str {
        match self {
            Unit::Micro => "micro",
            Unit::Ai => "ai",
            Unit::Daily(_) => "daily",
            Unit::Monthly(_) => "monthly",
            Unit::Yearly(_) => "yearly",
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Unit::Micro => "update",
            Unit::Ai => "process",
            Unit::Daily(n) | Unit::Monthly(n) | Unit::Yearly(n) => n,
        }
    }

    /// `kind.name`, the key of [`Simulation::phase_times`].
    pub fn label(&self) -> String {
        format!("{}.{}", self.kind(), self.name())
    }
}

/// What a [`Simulation::step`] ran.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Step {
    pub unit: Unit,
    /// the tick's last unit: the tick is done
    pub tick_done: bool,
}

pub struct Simulation {
    pub runtime: Runtime,
    pub tracing: bool,
    pub trace: Vec<Phase>,
    pub ticks: u64,
    /// Lua errors raised by phases (the phase is cut short, the tick goes on).
    pub errors: Vec<String>,
    /// Time spent per phase (`kind.name`): calls and seconds, for profiling.
    pub phase_times: std::collections::BTreeMap<String, (u64, f64)>,
    tick_count: i32,
    cached_month: i32,
    cached_year: i32,
    commands: Vec<Command>,
    pool: Vec<i32>,
    /// the units of the tick in progress not run yet (empty between ticks)
    pending: VecDeque<Unit>,
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
            phase_times: std::collections::BTreeMap::new(),
            tick_count: 0,
            cached_month: d.month_index(),
            cached_year: d.year(),
            commands: Vec::new(),
            pool: Vec::new(),
            pending: VecDeque::new(),
        }
    }

    pub fn date(&self) -> Date {
        self.runtime.date.get()
    }

    /// Resumes at a save's tick within the day (`_nTickCount`, the save's `tick`, `save::tick_of`):
    /// a save written at tick 4 or later already had that day's AI pass, so the next is the next
    /// day's.
    pub fn set_tick_count(&mut self, tick: i32) {
        self.tick_count = tick.rem_euclid(10);
    }

    pub fn tick_count(&self) -> i32 {
        self.tick_count
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
        let t = std::time::Instant::now();
        if let Err(e) = self.runtime.phase(kind, name) {
            if self.errors.len() < 20 {
                self.errors.push(format!("{kind}.{name}: {e}"));
            }
        }
        let e = self.phase_times.entry(format!("{kind}.{name}")).or_insert((0, 0.0));
        e.0 += 1;
        e.1 += t.elapsed().as_secs_f64();
        self.runtime.rng.borrow_mut().set_forbidden(old);
    }

    /// The phases by time spent, slowest first: `phase  calls  seconds  ms per call`.
    pub fn phase_report(&self) -> String {
        let mut v: Vec<_> = self.phase_times.iter().collect();
        v.sort_by(|a, b| b.1 .1.partial_cmp(&a.1 .1).unwrap_or(std::cmp::Ordering::Equal));
        let total: f64 = v.iter().map(|(_, (_, s))| s).sum();
        let mut out = format!("phases: {total:.1} s in all\n");
        for (name, (calls, secs)) in v {
            out += &format!(
                "  {name:<34} {calls:>7} calls {secs:>8.2} s {:>5.1}%  {:>8.3} ms a call\n",
                100.0 * secs / total.max(1e-9),
                secs * 1000.0 / (*calls).max(1) as f64
            );
        }
        out
    }

    /// One `CSession::ProcessSynchronousCommands` pass: the commands, then `HandleTurnTick`. In the
    /// middle of a tick (after [`Simulation::step`]), the rest of that tick.
    pub fn tick(&mut self) {
        while !self.step().tick_done {}
    }

    pub fn run_ticks(&mut self, n: u64) {
        for _ in 0..n {
            self.tick();
        }
    }

    pub fn run_days(&mut self, days: u64) {
        self.run_ticks(days * 10);
    }

    /// Whether a tick is in progress: some of its units have run, the others not yet.
    pub fn mid_tick(&self) -> bool {
        !self.pending.is_empty()
    }

    /// The unit the next [`Simulation::step`] runs: the tick's next, or between ticks the next
    /// tick's first ([`Unit::Micro`], after the commands).
    pub fn upcoming(&self) -> Unit {
        self.pending.front().copied().unwrap_or(Unit::Micro)
    }

    /// Runs one unit of a tick: between ticks, the next tick begins first (its commands, the tick
    /// count, the date). The units of a tick are the phases [`Simulation::tick`] runs, in its order.
    pub fn step(&mut self) -> Step {
        if self.pending.is_empty() {
            self.begin_tick();
        }
        let unit = self.pending.pop_front().expect("a tick has at least MicroUpdate");
        self.run_unit(unit);
        let tick_done = self.pending.is_empty();
        if tick_done {
            self.ticks += 1;
        }
        Step { unit, tick_done }
    }

    /// The start of `HandleTurnTick`: the commands, `_nTickCount`, the date on the day tick; the
    /// tick's units queued (the day's, the month's and the year's when they are due).
    fn begin_tick(&mut self) {
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
        self.pending.push_back(Unit::Micro);
        // CGameState::ProcessAI (0x264600): decisions become commands for the next tick
        if phase == 4 {
            self.pending.push_back(Unit::Ai);
        }
        if day {
            // MicroUpdate and ProcessAI do not move the date: the month and the year compared now
            // are those HandleTurnTick compares after them
            let (old_month, old_year) = (self.cached_month, self.cached_year);
            self.cached_month = self.date().month_index();
            self.cached_year = self.date().year();
            // CGameState::DailyUpdate (0x25cde0)
            self.pending.extend(DAILY_PHASES.iter().map(|&n| Unit::Daily(n)));
            if self.cached_month != old_month {
                // CGameState::MonthlyUpdate (0x261620)
                self.pending.extend(MONTHLY_PHASES.iter().map(|&n| Unit::Monthly(n)));
            }
            if self.cached_year != old_year {
                // CGameState::YearlyUpdate
                self.pending.extend(YEARLY_PHASES.iter().map(|&n| Unit::Yearly(n)));
            }
        }
    }

    fn run_unit(&mut self, unit: Unit) {
        match unit {
            Unit::Micro => {
                self.mark(Phase::Micro);
                self.phase("micro", "update", false);
            }
            Unit::Ai => {
                self.mark(Phase::Ai);
                self.phase("ai", "process", false);
            }
            Unit::Daily(name) => {
                self.mark(Phase::Daily(name));
                if name == "random_pool" {
                    self.pool = self.runtime.rng.borrow_mut().draw_pool(DAILY_POOL_SIZE);
                    *self.runtime.daily_pool.borrow_mut() = self.pool.clone();
                } else {
                    self.phase("daily", name, PARALLEL.contains(&name));
                }
            }
            Unit::Monthly(name) => {
                // MonthlyUpdate first draws the month's pool of 1,000 (0x26169a), read by the
                // colonies' demography (docs/pops.md)
                if name == MONTHLY_PHASES[0] {
                    let pool = self.runtime.rng.borrow_mut().draw_pool(MONTHLY_POOL_SIZE);
                    *self.runtime.monthly_pool.borrow_mut() = pool;
                }
                self.mark(Phase::Monthly(name));
                self.phase("monthly", name, name == "modifiers");
            }
            Unit::Yearly(name) => {
                self.mark(Phase::Yearly(name));
                self.phase("yearly", name, false);
            }
        }
    }

    /// The day's pool of random draws (taken in `random_pool`), for the parallel phases.
    pub fn pool(&self) -> &[i32] {
        &self.pool
    }
}
