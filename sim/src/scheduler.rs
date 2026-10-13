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
//! The phases inside `DailyUpdate` / `MonthlyUpdate` / `YearlyUpdate` follow docs/simulation.md
//! (section 1), restricted to the kept subsystems, each parallel phase run serially in id order with
//! random draws forbidden. Every root effect (a call into the script host) is followed by a flush:
//! the engine-effect queue is drained and the modifiers recomputed, where the game's
//! `CRootEffect::Execute` runs `CModifierNodeManager::Update`.

use crate::date::Date;
use crate::engine::{self, events, events::CallIn};
use crate::fixed::Fixed;
use crate::queue::EngineQueue;
use crate::rng::DAILY_POOL_SIZE;
use crate::script::{EffectOutcome, Scope, ScriptCtx, ScriptHost};
use crate::state::{GameState, Id};

/// A synchronized command (`CCommand`), executed before the next tick.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// A player action implemented in script (a decision, an event option).
    RunEffect { effect: String, scope: Scope },
    /// `CAddBuildableToQueueCommand`.
    QueueBuilding { colony: Id, building: String },
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

/// The daily phases, in order (`CGameState::DailyUpdate`, `0x25cde0`; the kept subsystems).
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

/// The monthly phases, in order (`CGameState::MonthlyUpdate`, `0x261620`; the kept subsystems).
pub const MONTHLY_PHASES: [&str; 5] = [
    "modifiers",        // CModifierNodeManager::Update (0x26195f)
    "budget",           // CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>
    "countries_serial", // CCountry::MonthlyUpdateSerial: on_monthly_pulse_country
    "colonies",         // NColonyUpdate::MonthlyUpdate: growth, jobs
    "on_monthly_pulse", // COnActionDatabase::PerformEvent
];

pub const YEARLY_PHASES: [&str; 2] = [
    "on_yearly_pulse", // COnActionDatabase::PerformEvent
    "cleanup",         // ClearUnusedShipDesigns, ClearInvalidFleetDesigns
];

pub struct Simulation<S: ScriptHost> {
    pub state: GameState,
    pub queue: EngineQueue,
    pub script: S,
    pub tracing: bool,
    pub trace: Vec<Phase>,
    pub ticks: u64,
    /// Totals of what the script host reported.
    pub outcome: EffectOutcome,
    commands: Vec<Command>,
    pool: Vec<i32>,
}

impl<S: ScriptHost> Simulation<S> {
    pub fn new(state: GameState, script: S) -> Simulation<S> {
        Simulation {
            state,
            queue: EngineQueue::new(),
            script,
            tracing: false,
            trace: Vec::new(),
            ticks: 0,
            outcome: EffectOutcome::default(),
            commands: Vec::new(),
            pool: Vec::new(),
        }
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

    /// Calls the script host with a context over the current state.
    pub fn with_script<R>(&mut self, f: impl FnOnce(&mut S, &mut ScriptCtx) -> R) -> R {
        let GameState { date, world, rng, .. } = &mut self.state;
        let mut ctx = ScriptCtx { date: *date, world, rng, queue: &mut self.queue };
        f(&mut self.script, &mut ctx)
    }

    /// Drains the engine-effect queue and recomputes modifiers (the barrier).
    pub fn flush(&mut self) -> usize {
        let GameState { date, world, rng, .. } = &mut self.state;
        crate::queue::barrier(world, &mut self.queue, rng, *date)
    }

    /// `CModifierNodeManager::Update` with random draws forbidden.
    fn update_modifiers(&mut self) {
        let old = self.state.rng.set_forbidden(true);
        engine::modifiers::update(&mut self.state.world);
        self.state.rng.set_forbidden(old);
    }

    /// A root effect: run, then flush (`CRootEffect::Execute`).
    pub fn root_effect(&mut self, effect: &str, scope: Scope) -> EffectOutcome {
        let out = self.with_script(|s, c| s.run_effect(effect, scope, c));
        self.outcome.merge(out);
        self.flush();
        out
    }

    /// An engine on_action: run, then flush.
    pub fn fire_on_action(&mut self, name: &str, scope: Scope) -> EffectOutcome {
        let out = self.with_script(|s, c| s.on_action(name, scope, c));
        self.outcome.merge(out);
        self.flush();
        out
    }

    fn dispatch(&mut self, calls: Vec<CallIn>) {
        for c in calls {
            match c {
                CallIn::OnAction { name, scope } => {
                    self.fire_on_action(name, scope);
                }
            }
        }
    }

    /// Runs a parallel phase: random draws are forbidden (the phase may read the pool).
    fn parallel<R>(&mut self, f: impl FnOnce(&mut Self) -> R) -> R {
        let old = self.state.rng.set_forbidden(true);
        let r = f(self);
        self.state.rng.set_forbidden(old);
        r
    }

    fn execute(&mut self, c: Command) {
        match c {
            Command::RunEffect { effect, scope } => {
                self.root_effect(&effect, scope);
            }
            Command::QueueBuilding { colony, building } => {
                engine::construction::queue_building(&mut self.state.world, colony, &building);
            }
        }
    }

    /// One `CSession::ProcessSynchronousCommands` pass: the commands, then `HandleTurnTick`.
    pub fn tick(&mut self) {
        let cmds = std::mem::take(&mut self.commands);
        if !cmds.is_empty() {
            self.mark(Phase::Commands(cmds.len()));
            for c in cmds {
                self.execute(c);
            }
            self.flush(); // CGameState::AfterCommandExecutedUpdate
        }

        self.state.tick_count += 1;
        let phase = self.state.tick_count % 10;
        let day = phase == 0;
        if day {
            self.state.tick_count = 0;
            self.state.date = self.state.date.add_days(1);
            let d = self.state.date;
            self.mark(Phase::DateAdvanced(d));
        }

        self.micro_update();
        if phase == 4 {
            self.process_ai();
        }
        if day {
            let (old_month, old_year) = (self.state.cached_month, self.state.cached_year);
            self.state.cached_month = self.state.date.month_index();
            self.state.cached_year = self.state.date.year();
            self.daily_update();
            if self.state.cached_month != old_month {
                self.monthly_update();
            }
            if self.state.cached_year != old_year {
                self.yearly_update();
            }
        }
        self.flush();
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

    /// `CGameState::MicroUpdate` (`0x253cf0`).
    fn micro_update(&mut self) {
        self.mark(Phase::Micro);
        let arrivals = engine::fleets::micro_update(&mut self.state.world);
        engine::combat::micro_update(&mut self.state.world);
        self.dispatch(arrivals);
    }

    /// `CGameState::ProcessAI` (`0x264600`): decisions become commands for the next tick.
    fn process_ai(&mut self) {
        self.mark(Phase::Ai);
        let cmds = engine::ai::process_ai(&self.state.world);
        self.commands.extend(cmds);
    }

    fn country_ids(&self) -> Vec<Id> {
        self.state.world.countries.iter().filter(|(_, c)| c.alive).map(|(id, _)| *id).collect()
    }

    fn colony_ids(&self) -> Vec<Id> {
        self.state.world.colonies.keys().copied().collect()
    }

    /// `CGameState::DailyUpdate` (`0x25cde0`), the kept phases.
    fn daily_update(&mut self) {
        let date = self.state.date;

        self.mark(Phase::Daily(DAILY_PHASES[0]));
        self.with_script(|s, c| s.daily_script_state(c));

        self.mark(Phase::Daily(DAILY_PHASES[1]));
        engine::construction::daily_manager(&mut self.state.world);

        self.mark(Phase::Daily(DAILY_PHASES[2]));
        self.pool = self.state.rng.draw_pool(DAILY_POOL_SIZE);

        self.mark(Phase::Daily(DAILY_PHASES[3]));
        self.update_modifiers();

        self.mark(Phase::Daily(DAILY_PHASES[4]));
        self.parallel(|sim| engine::modifiers::expire(&mut sim.state.world, date));

        self.mark(Phase::Daily(DAILY_PHASES[5]));
        for id in self.country_ids() {
            let scope = Scope::Country(id);
            // CCountryEventManager::DailyUpdateSerial: due delayed events and MTTH events
            let out = self.with_script(|s, c| s.scope_daily_events(scope, c));
            self.outcome.merge(out);
            self.flush();
            // CTechnologyStatus::DailyResearch, then QueueResearch
            let done = engine::research::daily_research(&mut self.state.world, id);
            for _ in &done {
                self.fire_on_action(events::ON_TECH_INCREASED, scope);
            }
            let picks = self.with_script(|s, c| {
                let mut picks = Vec::new();
                for area in engine::research::AREAS {
                    if engine::research::needs_pick(c.world, id, area) {
                        let opts = engine::research::options(c.world, id, area);
                        if let Some(t) = weighted_pick(s, c, scope, "tech:", &opts) {
                            picks.push((area, t));
                        }
                    }
                }
                picks
            });
            for (area, t) in picks {
                engine::research::start(&mut self.state.world, id, area, t);
            }
            engine::country::daily_serial(&mut self.state.world, id, date);
        }

        self.mark(Phase::Daily(DAILY_PHASES[6]));
        self.update_modifiers();

        self.mark(Phase::Daily(DAILY_PHASES[7]));
        // employment caches are rebuilt by the serial job update in the skeleton

        self.mark(Phase::Daily(DAILY_PHASES[8]));
        for col in self.colony_ids() {
            // the colony's delayed and MTTH events (CColony::DailyUpdateSerial -> CEventManager::TriggerEvent)
            let out = self.with_script(|s, c| s.scope_daily_events(Scope::Colony(col), c));
            self.outcome.merge(out);
            self.flush();
            let order = self.job_order(col);
            let calls = engine::colonies::daily_serial(&mut self.state.world, col, &order);
            self.dispatch(calls);
        }

        self.mark(Phase::Daily(DAILY_PHASES[9]));
        // ethics divergence, factions: not modelled

        self.mark(Phase::Daily(DAILY_PHASES[10]));
        let pool = std::mem::take(&mut self.pool);
        self.parallel(|sim| engine::fleets::daily_pathfinding(&mut sim.state.world, &pool));

        self.mark(Phase::Daily(DAILY_PHASES[11]));
        let dying = self.parallel(|sim| engine::country::leaders_parallel(&mut sim.state.world, &pool));
        let calls = engine::country::leaders_serial(&mut self.state.world, &dying);
        self.dispatch(calls);
        self.pool = pool;

        self.mark(Phase::Daily(DAILY_PHASES[12]));
        engine::diplomacy::daily(&mut self.state.world);
    }

    /// Jobs by script weight (highest first, then name).
    fn job_order(&mut self, col: Id) -> Vec<String> {
        self.with_script(|s, c| {
            let slots = engine::colonies::job_slots(c.world, col);
            let mut v: Vec<(Fixed, String)> =
                slots.keys().map(|j| (s.weight(&format!("job:{j}"), Scope::Colony(col), c), j.clone())).collect();
            v.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
            v.into_iter().map(|(_, j)| j).collect()
        })
    }

    /// `CGameState::MonthlyUpdate` (`0x261620`), the kept phases.
    fn monthly_update(&mut self) {
        self.mark(Phase::Monthly(MONTHLY_PHASES[0]));
        self.update_modifiers();

        self.mark(Phase::Monthly(MONTHLY_PHASES[1]));
        engine::economy::monthly_budget(&mut self.state.world);

        self.mark(Phase::Monthly(MONTHLY_PHASES[2]));
        for id in self.country_ids() {
            self.fire_on_action(events::ON_MONTHLY_PULSE_COUNTRY, Scope::Country(id));
        }

        self.mark(Phase::Monthly(MONTHLY_PHASES[3]));
        for col in self.colony_ids() {
            if engine::pops::monthly_growth(&mut self.state.world, col) {
                self.state.world.modifiers.dirty = true;
                self.fire_on_action(events::ON_POP_ASSEMBLED, Scope::Colony(col));
            }
            let order = self.job_order(col);
            let slots = engine::colonies::job_slots(&self.state.world, col);
            engine::pops::update_pop_jobs(&mut self.state.world, col, &slots, &order);
        }

        self.mark(Phase::Monthly(MONTHLY_PHASES[4]));
        self.fire_on_action(events::ON_MONTHLY_PULSE, Scope::None);
    }

    /// `CGameState::YearlyUpdate` (`0x262ee0`).
    fn yearly_update(&mut self) {
        self.mark(Phase::Yearly(YEARLY_PHASES[0]));
        self.fire_on_action(events::ON_YEARLY_PULSE, Scope::None);
        for id in self.country_ids() {
            self.fire_on_action(events::ON_YEARLY_PULSE_COUNTRY, Scope::Country(id));
        }
        // the longer pulses, by year (which caller fires them, and on which years, was not traced)
        let year = self.state.date.year();
        for (n, global, country) in [
            (2, events::ON_BI_YEARLY_PULSE, events::ON_BI_YEARLY_PULSE_COUNTRY),
            (5, events::ON_FIVE_YEAR_PULSE, events::ON_FIVE_YEAR_PULSE_COUNTRY),
            (10, events::ON_DECADE_PULSE, events::ON_DECADE_PULSE_COUNTRY),
        ] {
            if year % n == 0 {
                self.fire_on_action(global, Scope::None);
                for id in self.country_ids() {
                    self.fire_on_action(country, Scope::Country(id));
                }
            }
        }
        self.mark(Phase::Yearly(YEARLY_PHASES[1]));
    }
}

/// A weighted random pick among `options` (weights from script, `<prefix><option>`), drawing from
/// the synchronized RNG.
fn weighted_pick<S: ScriptHost>(s: &mut S, c: &mut ScriptCtx, scope: Scope, prefix: &str, options: &[String]) -> Option<String> {
    if options.is_empty() {
        return None;
    }
    let weights: Vec<i64> = options.iter().map(|o| s.weight(&format!("{prefix}{o}"), scope, c).raw().max(0)).collect();
    let total: i64 = weights.iter().sum();
    if total <= 0 {
        return None;
    }
    let mut r = (c.rng.next_int() as i64) % total;
    for (o, w) in options.iter().zip(weights) {
        if r < w {
            return Some(o.clone());
        }
        r -= w;
    }
    None
}
