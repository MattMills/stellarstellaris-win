//! The script layer behind a trait.
//!
//! The Lua layer (lua/stellar, lib/stellar-lua-pdxscript) evaluates triggers, runs effects, owns
//! script state (flags, variables, saved event targets, scripted lists, delayed events) and fires
//! events and on_actions. The engine calls into it where the game's C++ calls script:
//! `COnActionDatabase::PerformEvent` (263 call sites), `CEventManager::TriggerEvent` (23),
//! weights, `potential`/`allow`, triggered modifiers, MTTH chances (`CEvent::GetChance`), delayed
//! event countdowns (`CDelayedEventManager::DailyUpdateThreaded` / `DailyUpdateSerial`).
//!
//! A host applies script effects itself and queues engine effects on [`ScriptCtx::queue`]; it may
//! read the engine state through [`ScriptCtx::world`] (engine reads), and draws random numbers
//! from the one synchronized stream [`ScriptCtx::rng`] (script and engine share it).

use std::collections::{BTreeMap, BTreeSet};

use crate::date::Date;
use crate::fixed::Fixed;
use crate::queue::{EngineEffect, EngineQueue, Handle, Target};
use crate::rng::NoiseRandom;
use crate::state::{Id, World};

/// A scope (`CScopeObjectReference`, reduced to the kinds the skeleton models).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Scope {
    None,
    Country(Id),
    Colony(Id),
    PopGroup(Id),
    Leader(Id),
    Fleet(Id),
}

/// What a root effect did: script effects applied in Lua, engine effects queued.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct EffectOutcome {
    pub script_effects: u32,
    pub engine_effects: u32,
}

impl EffectOutcome {
    pub fn merge(&mut self, o: EffectOutcome) {
        self.script_effects += o.script_effects;
        self.engine_effects += o.engine_effects;
    }
}

/// What the script layer gets for a call: the date, the engine state (read it; change it only
/// through the queue and [`ScriptCtx::flush`]), the synchronized RNG and the engine-effect queue.
pub struct ScriptCtx<'a> {
    pub date: Date,
    pub world: &'a mut World,
    pub rng: &'a mut NoiseRandom,
    pub queue: &'a mut EngineQueue,
}

impl ScriptCtx<'_> {
    /// The barrier inside a root effect: apply the queued engine effects now (a read of engine
    /// state that a pending effect changes, `last_created_*`, an event fired at once).
    pub fn flush(&mut self) -> usize {
        crate::queue::barrier(self.world, self.queue, self.rng, self.date)
    }
}

pub trait ScriptHost {
    /// Evaluates a trigger (by id: a scripted trigger, an event's trigger, a `potential` block)
    /// in a scope. Reads of engine state see the state as of the last flush.
    fn eval_trigger(&mut self, id: &str, scope: Scope, ctx: &mut ScriptCtx) -> bool;

    /// Runs an effect block (a root effect: an event's immediate or option, a decision, a scripted
    /// effect called by the engine) in a scope.
    fn run_effect(&mut self, id: &str, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome;

    /// An on_action fired by the engine (`COnActionDatabase::PerformEvent`).
    fn on_action(&mut self, name: &str, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome;

    /// A script weight the engine asks for (job weights, tech weights, `ai_weight`, ...).
    fn weight(&mut self, _id: &str, _scope: Scope, _ctx: &mut ScriptCtx) -> Fixed {
        Fixed::ONE
    }

    /// Daily expiry of script state (timed flags), where the game runs
    /// `CPdxIntegerFlags::UpdateFlags` in the daily task graph.
    fn daily_script_state(&mut self, _ctx: &mut ScriptCtx) {}

    /// A scope's daily events: delayed events that are due and MTTH events that fire, where the
    /// game runs `CCountryEventManager::DailyUpdateSerial` / `CDelayedEventManager::DailyUpdateSerial`
    /// and `CStandardEventCountryModule` (chances computed in the parallel phase).
    fn scope_daily_events(&mut self, _scope: Scope, _ctx: &mut ScriptCtx) -> EffectOutcome {
        EffectOutcome::default()
    }
}

// ---------------------------------------------------------------------------------------------
// A mock for tests

/// One step of a mock script.
#[derive(Clone, Debug)]
pub enum MockOp {
    /// A script effect: `set_<scope>_flag`.
    SetFlag(String),
    /// An engine effect, queued (its target may be `Target::Scope`, resolved by the host).
    Engine(EngineEffect),
    /// `random_list`-like: draw, and run `then` when the draw modulo 100 is below `percent`.
    IfRandomBelow { percent: i32, then: Vec<MockOp> },
    /// `create_pop_group` in the current colony scope, remembered as `last_created_pop_group`.
    CreatePopGroup { species: String, size: i64 },
    /// An engine effect on `last_created_pop_group` (a provisional handle until the flush).
    GrowLastCreatedPopGroup(i64),
}

/// A script host for tests: named effect blocks of [`MockOp`]s, fixed trigger results, a call log.
#[derive(Default)]
pub struct MockScriptHost {
    pub scripts: BTreeMap<String, Vec<MockOp>>,
    pub triggers: BTreeMap<String, bool>,
    pub weights: BTreeMap<String, Fixed>,
    pub flags: BTreeSet<(Scope, String)>,
    pub log: Vec<String>,
    /// Log daily calls too (noisy).
    pub log_daily: bool,
    last_created: Option<Handle>,
}

impl MockScriptHost {
    pub fn new() -> MockScriptHost {
        MockScriptHost::default()
    }

    pub fn script(mut self, id: &str, ops: Vec<MockOp>) -> MockScriptHost {
        self.scripts.insert(id.to_string(), ops);
        self
    }

    fn run_ops(&mut self, ops: &[MockOp], scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        let mut out = EffectOutcome::default();
        for op in ops {
            match op {
                MockOp::SetFlag(f) => {
                    self.flags.insert((scope, f.clone()));
                    out.script_effects += 1;
                }
                MockOp::Engine(e) => {
                    ctx.queue.push(scope, e.clone());
                    out.engine_effects += 1;
                }
                MockOp::IfRandomBelow { percent, then } => {
                    if ctx.rng.next_int() % 100 < *percent {
                        let then = then.clone();
                        out.merge(self.run_ops(&then, scope, ctx));
                    }
                }
                MockOp::CreatePopGroup { species, size } => {
                    let handle = ctx.queue.new_handle();
                    ctx.queue.push(
                        scope,
                        EngineEffect::CreatePopGroup { colony: Target::Scope, species: species.clone(), size: *size, handle },
                        );
                    self.last_created = Some(handle);
                    out.engine_effects += 1;
                }
                MockOp::GrowLastCreatedPopGroup(delta) => {
                    if let Some(h) = self.last_created {
                        ctx.queue.push(scope, EngineEffect::ChangePopGroupSize { pop_group: Target::Pending(h), delta: *delta });
                        out.engine_effects += 1;
                    }
                }
            }
        }
        out
    }
}

impl ScriptHost for MockScriptHost {
    fn eval_trigger(&mut self, id: &str, scope: Scope, _ctx: &mut ScriptCtx) -> bool {
        self.log.push(format!("trigger {id} {scope:?}"));
        self.triggers.get(id).copied().unwrap_or(false)
    }

    fn run_effect(&mut self, id: &str, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        self.log.push(format!("effect {id} {scope:?}"));
        let ops = self.scripts.get(id).cloned().unwrap_or_default();
        self.run_ops(&ops, scope, ctx)
    }

    fn on_action(&mut self, name: &str, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        self.log.push(format!("on_action {name} {scope:?}"));
        let ops = self.scripts.get(name).cloned().unwrap_or_default();
        self.run_ops(&ops, scope, ctx)
    }

    fn weight(&mut self, id: &str, _scope: Scope, _ctx: &mut ScriptCtx) -> Fixed {
        self.weights.get(id).copied().unwrap_or(Fixed::ONE)
    }

    fn daily_script_state(&mut self, ctx: &mut ScriptCtx) {
        if self.log_daily {
            self.log.push(format!("script_state {:?}", ctx.date));
        }
    }

    fn scope_daily_events(&mut self, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        if self.log_daily {
            self.log.push(format!("daily_events {scope:?}"));
        }
        let ops = self.scripts.get("daily_events").cloned().unwrap_or_default();
        self.run_ops(&ops, scope, ctx)
    }
}
