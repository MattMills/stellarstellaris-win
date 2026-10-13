//! The PDXScript layer in embedded LuaJIT: a [`ScriptHost`] backed by `sim/lua/simscript`.
//!
//! The Lua side parses the game's script files with `lib/stellar-lua-pdxscript` (`require
//! "pdxscript"`) and the repo's `stellar.script.source` (files, inline scripts, scripted trigger and
//! effect instantiation, as the game does), and evaluates triggers, effects, script values, events
//! and on_actions itself. Script state (flags, variables, event targets, delayed events, fired-once
//! events) lives in Lua. Engine state is read through the `E` table this module fills for each call
//! (`E.get`, `E.has`, `E.resource`, `E.colonies`, ...); engine effects go back through `E.push` onto
//! the [`EngineQueue`](crate::queue::EngineQueue); `E.flush` is the barrier (`last_created_*`, a
//! read after a write); `E.rand` draws from the game's one RNG.
//!
//! The runtime is LuaJIT 2.1 with its full library (`ffi`, `jit`, `io`), as in the game.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use mlua::{Function, Lua, LuaOptions, StdLib, Table, Value};

use crate::fixed::Fixed;
use crate::queue::{barrier, EngineEffect, Handle, Target};
use crate::script::{EffectOutcome, Scope, ScriptCtx, ScriptHost};
use crate::state::{Id, Resource, World};

pub struct LuaScriptHost {
    lua: Lua,
    host: Table,
    /// Lua errors raised by calls (the call then returns its default).
    pub errors: u64,
    pub first_errors: Vec<String>,
}

fn scope_to_lua(s: Scope) -> (&'static str, Id) {
    match s {
        Scope::None => ("none", 0),
        Scope::Country(id) => ("country", id),
        Scope::Colony(id) => ("planet", id),
        Scope::PopGroup(id) => ("pop_group", id),
        Scope::Leader(id) => ("leader", id),
        Scope::Fleet(id) => ("fleet", id),
    }
}

fn scope_from_lua(kind: &str, id: Id) -> Scope {
    match kind {
        "country" => Scope::Country(id),
        "planet" => Scope::Colony(id),
        "pop_group" => Scope::PopGroup(id),
        "leader" => Scope::Leader(id),
        "fleet" => Scope::Fleet(id),
        _ => Scope::None,
    }
}

pub fn resource_by_name(name: &str) -> Option<Resource> {
    Resource::ALL.iter().copied().find(|r| r.name() == name)
}

fn fx(v: f64) -> Fixed {
    Fixed((v * Fixed::SCALE as f64).round() as i64)
}

fn unfx(v: Fixed) -> f64 {
    v.0 as f64 / Fixed::SCALE as f64
}

/// The `.txt` files under `root/sub`, recursively, as sorted relative paths with `/`.
pub fn list_files(root: &str, sub: &str) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(base, &p, out);
            } else if p.extension().map_or(false, |x| x.eq_ignore_ascii_case("txt")) {
                if let Ok(rel) = p.strip_prefix(base) {
                    out.push(rel.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    let base = Path::new(root);
    let mut out = Vec::new();
    walk(base, &base.join(sub), &mut out);
    out.sort();
    out
}

fn str_value(lua: &Lua, s: &str) -> mlua::Result<Value> {
    Ok(Value::String(lua.create_string(s)?))
}

fn get_field(lua: &Lua, w: &World, kind: &str, id: Id, field: &str) -> mlua::Result<Value> {
    Ok(match kind {
        "country" => match w.countries.get(&id) {
            None => Value::Nil,
            Some(c) => match field {
                "name" => str_value(lua, &c.name)?,
                "alive" => Value::Boolean(c.alive),
                "capital" => c.capital.map_or(Value::Nil, |x| Value::Integer(x as i64)),
                "num_colonies" => Value::Integer(w.colonies.values().filter(|x| x.owner == id).count() as i64),
                "num_techs" => Value::Integer(c.techs.len() as i64),
                "num_leaders" => Value::Integer(w.leaders.values().filter(|l| l.alive && l.country == id).count() as i64),
                "num_pops" => Value::Integer(
                    w.colonies.iter().filter(|(_, x)| x.owner == id).map(|(cid, _)| w.colony_pops(*cid) as i64).sum(),
                ),
                _ => c.attrs.get(field).map_or(Ok(Value::Nil), |v| str_value(lua, v))?,
            },
        },
        "planet" => match w.colonies.get(&id) {
            None => Value::Nil,
            Some(c) => match field {
                "owner" => Value::Integer(c.owner as i64),
                "name" => str_value(lua, &c.name)?,
                "pops" => Value::Integer(w.colony_pops(id) as i64),
                "num_buildings" => Value::Integer(c.buildings.len() as i64),
                "unemployed" => Value::Integer(c.unemployed as i64),
                _ => c.attrs.get(field).map_or(Ok(Value::Nil), |v| str_value(lua, v))?,
            },
        },
        "pop_group" => match w.pop_groups.get(&id) {
            None => Value::Nil,
            Some(p) => match field {
                "colony" => Value::Integer(p.colony as i64),
                "species" => str_value(lua, &p.species)?,
                "size" => Value::Number(p.size as f64 / crate::state::POP_UNIT as f64),
                _ => Value::Nil,
            },
        },
        "leader" => match w.leaders.get(&id) {
            None => Value::Nil,
            Some(l) => match field {
                "country" => Value::Integer(l.country as i64),
                "age" => Value::Integer((l.age_days / crate::date::DAYS_PER_YEAR) as i64),
                "alive" => Value::Boolean(l.alive),
                _ => l.attrs.get(field).map_or(Ok(Value::Nil), |v| str_value(lua, v))?,
            },
        },
        _ => Value::Nil,
    })
}

fn has_member(w: &World, kind: &str, id: Id, set: &str, member: &str) -> bool {
    match kind {
        "country" => w.countries.get(&id).map_or(false, |c| match set {
            "tech" => c.techs.contains(member),
            "edict" => c.edicts.contains_key(member),
            _ => c.sets.get(set).map_or(false, |s| s.contains(member)),
        }),
        "planet" => w.colonies.get(&id).map_or(false, |c| match set {
            "building" => c.buildings.iter().any(|b| b == member),
            _ => c.sets.get(set).map_or(false, |s| s.contains(member)),
        }),
        _ => false,
    }
}

fn effect_from_table(t: &Table) -> mlua::Result<(Scope, EngineEffect)> {
    let ty: String = t.get("type")?;
    let kind: Option<String> = t.get("kind")?;
    let id: Option<Id> = t.get("id")?;
    let scope = scope_from_lua(kind.as_deref().unwrap_or("none"), id.unwrap_or(0));
    let target_handle: Option<u32> = t.get("target_handle")?;
    let target = target_handle.map_or(Target::Scope, |h| Target::Pending(Handle(h)));
    let effect = match ty.as_str() {
        "add_resource" => {
            let res: String = t.get("resource")?;
            let amount: f64 = t.get("amount")?;
            match resource_by_name(&res) {
                Some(r) => EngineEffect::AddResource { country: target, resource: r, amount: fx(amount) },
                None => EngineEffect::Unmodelled { keyword: format!("add_resource:{res}") },
            }
        }
        "add_modifier" => {
            let source: String = t.get("source")?;
            let days: Option<i32> = t.get("days")?;
            let mut entries = Vec::new();
            if let Some(list) = t.get::<Option<Table>>("entries")? {
                for pair in list.sequence_values::<Table>() {
                    let pair = pair?;
                    let name: String = pair.get(1)?;
                    let value: f64 = pair.get(2)?;
                    entries.push((name, fx(value)));
                }
            }
            EngineEffect::AddModifier { scope: target, source, entries, days }
        }
        "create_pop_group" => {
            let species: String = t.get("species")?;
            let size: f64 = t.get("size")?;
            let h: u32 = t.get("handle")?;
            EngineEffect::CreatePopGroup {
                colony: target,
                species,
                size: (size * crate::state::POP_UNIT as f64).round() as i64,
                handle: Handle(h),
            }
        }
        "change_pop_group_size" => {
            let delta: f64 = t.get("delta")?;
            EngineEffect::ChangePopGroupSize { pop_group: target, delta: (delta * crate::state::POP_UNIT as f64).round() as i64 }
        }
        "give_technology" => EngineEffect::GiveTechnology { country: target, tech: t.get("tech")? },
        "create_leader" => EngineEffect::CreateLeader { country: target, handle: Handle(t.get("handle")?) },
        "kill_leader" => EngineEffect::KillLeader { leader: target },
        _ => {
            let kw: Option<String> = t.get("keyword")?;
            EngineEffect::Unmodelled { keyword: kw.unwrap_or(ty) }
        }
    };
    Ok((scope, effect))
}

impl LuaScriptHost {
    /// The repository root (sim/..), for the Lua require paths.
    pub fn repo_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
    }

    /// Creates the Lua state and loads the game's script from `game_dir` (the Stellaris install);
    /// `docs_dir` is the game's `logs/script_documentation` (trigger and effect names), if any.
    pub fn new(game_dir: &str, docs_dir: Option<&str>) -> mlua::Result<LuaScriptHost> {
        let lua = Self::new_lua()?;
        let host: Table = lua.load("return require('simscript.host')").set_name("simscript").eval()?;
        let init: Function = host.get("init")?;
        init.call::<()>((game_dir.replace('\\', "/"), docs_dir.map(|d| d.replace('\\', "/"))))?;
        Ok(LuaScriptHost { lua, host, errors: 0, first_errors: Vec::new() })
    }

    /// A LuaJIT state with the require paths (sim/lua, the pdxscript library, the repo's lua/) and
    /// the `RUST` helpers (`list_files`, `clock`), without the script host loaded.
    pub fn new_lua() -> mlua::Result<Lua> {
        // SAFETY: the full LuaJIT library (ffi included), as the game's runtime has it; the Lua
        // code is this repository's.
        let lua = unsafe { Lua::unsafe_new_with(StdLib::ALL, LuaOptions::new()) };
        let repo = Self::repo_dir().to_string_lossy().replace('\\', "/");
        let package: Table = lua.globals().get("package")?;
        package.set(
            "path",
            format!(
                "{repo}/sim/lua/?.lua;{repo}/sim/lua/?/init.lua;{repo}/lib/stellar-lua-pdxscript/?.lua;{repo}/lua/?.lua;{repo}/lua/?/init.lua"
            ),
        )?;
        let rust = lua.create_table()?;
        rust.set("list_files", lua.create_function(|_, (root, sub): (String, String)| Ok(list_files(&root, &sub)))?)?;
        let start = std::time::Instant::now();
        rust.set("clock", lua.create_function(move |_, ()| Ok(start.elapsed().as_secs_f64()))?)?;
        lua.globals().set("RUST", rust)?;
        lua.globals().set("E", lua.create_table()?)?;
        Ok(lua)
    }

    /// Calls a function of the host module with no engine context (reports, coverage).
    pub fn call_plain<A: mlua::IntoLuaMulti, R: mlua::FromLuaMulti>(&self, name: &str, args: A) -> mlua::Result<R> {
        let f: Function = self.host.get(name)?;
        f.call::<R>(args)
    }

    /// What ran and what is missing (built by the Lua side).
    pub fn report(&self) -> String {
        self.call_plain::<_, String>("report", ()).unwrap_or_else(|e| format!("report failed: {e}"))
    }

    /// Calls a host function with the engine table `E` bound to this context.
    fn call<A: mlua::IntoLuaMulti, R: mlua::FromLuaMulti>(&mut self, ctx: &mut ScriptCtx, name: &str, args: A) -> mlua::Result<R> {
        let date = ctx.date;
        let world = RefCell::new(&mut *ctx.world);
        let rng = RefCell::new(&mut *ctx.rng);
        let queue = RefCell::new(&mut *ctx.queue);
        let (world, rng, queue) = (&world, &rng, &queue);
        let lua = &self.lua;
        let host = &self.host;
        lua.scope(move |scope| {
            let e: Table = lua.globals().get("E")?;
            e.set("date", scope.create_function(move |_, ()| Ok(date.0))?)?;
            e.set(
                "rand",
                scope.create_function(move |_, ()| {
                    let mut r = rng.borrow_mut();
                    if r.is_forbidden() {
                        return Err(mlua::Error::RuntimeError("random draw in a forbidden zone".into()));
                    }
                    Ok(r.next_int())
                })?,
            )?;
            e.set(
                "countries",
                scope.create_function(move |_, ()| {
                    let w = world.borrow();
                    Ok(w.countries.iter().filter(|(_, c)| c.alive).map(|(id, _)| *id).collect::<Vec<Id>>())
                })?,
            )?;
            e.set(
                "colonies",
                scope.create_function(move |_, owner: Option<Id>| {
                    let w = world.borrow();
                    Ok(w.colonies
                        .iter()
                        .filter(|(_, c)| owner.map_or(true, |o| o == 0 || c.owner == o))
                        .map(|(id, _)| *id)
                        .collect::<Vec<Id>>())
                })?,
            )?;
            e.set(
                "pop_groups",
                scope.create_function(move |_, colony: Id| {
                    let w = world.borrow();
                    Ok(w.colonies.get(&colony).map(|c| c.pop_groups.clone()).unwrap_or_default())
                })?,
            )?;
            e.set(
                "leaders",
                scope.create_function(move |_, country: Id| {
                    let w = world.borrow();
                    Ok(w.leaders.iter().filter(|(_, l)| l.alive && l.country == country).map(|(id, _)| *id).collect::<Vec<Id>>())
                })?,
            )?;
            e.set(
                "get",
                scope.create_function(move |lua, (kind, id, field): (String, Id, String)| get_field(lua, &world.borrow(), &kind, id, &field))?,
            )?;
            e.set(
                "has",
                scope.create_function(move |_, (kind, id, set, member): (String, Id, String, String)| {
                    Ok(has_member(&world.borrow(), &kind, id, &set, &member))
                })?,
            )?;
            e.set(
                "resource",
                scope.create_function(move |_, (country, res): (Id, String)| {
                    let w = world.borrow();
                    Ok(match (w.countries.get(&country), resource_by_name(&res)) {
                        (Some(c), Some(r)) => Some(unfx(c.stockpile.get(r))),
                        _ => None,
                    })
                })?,
            )?;
            e.set(
                "income",
                scope.create_function(move |_, (country, res): (Id, String)| {
                    let w = world.borrow();
                    Ok(match (w.countries.get(&country), resource_by_name(&res)) {
                        (Some(c), Some(r)) => Some(unfx(c.last_month_income.get(r))),
                        _ => None,
                    })
                })?,
            )?;
            e.set(
                "modifier",
                scope.create_function(move |_, (kind, id, name): (String, Id, String)| {
                    Ok(unfx(world.borrow().modifier(scope_from_lua(&kind, id), &name)))
                })?,
            )?;
            e.set(
                "has_modifier",
                scope.create_function(move |_, (kind, id, source): (String, Id, String)| {
                    Ok(world.borrow().has_modifier_source(scope_from_lua(&kind, id), &source))
                })?,
            )?;
            e.set(
                "push",
                scope.create_function(move |_, t: Table| {
                    let (s, eff) = effect_from_table(&t)?;
                    queue.borrow_mut().push(s, eff);
                    Ok(())
                })?,
            )?;
            e.set("new_handle", scope.create_function(move |_, ()| Ok(queue.borrow_mut().new_handle().0))?)?;
            e.set("resolve", scope.create_function(move |_, h: u32| Ok(queue.borrow().resolved(Handle(h))))?)?;
            e.set("pending", scope.create_function(move |_, ()| Ok(queue.borrow().len()))?)?;
            e.set(
                "flush",
                scope.create_function(move |_, ()| {
                    let mut w = world.borrow_mut();
                    let mut q = queue.borrow_mut();
                    let mut r = rng.borrow_mut();
                    Ok(barrier(&mut **w, &mut **q, &mut **r, date))
                })?,
            )?;
            let f: Function = host.get(name)?;
            f.call::<R>(args)
        })
    }

    fn record(&mut self, e: mlua::Error) {
        self.errors += 1;
        if self.first_errors.len() < 10 {
            self.first_errors.push(e.to_string());
        }
    }

    fn outcome(&mut self, r: mlua::Result<(u32, u32)>) -> EffectOutcome {
        match r {
            Ok((s, e)) => EffectOutcome { script_effects: s, engine_effects: e },
            Err(e) => {
                self.record(e);
                EffectOutcome::default()
            }
        }
    }
}

impl ScriptHost for LuaScriptHost {
    fn eval_trigger(&mut self, id: &str, scope: Scope, ctx: &mut ScriptCtx) -> bool {
        let (k, i) = scope_to_lua(scope);
        match self.call::<_, bool>(ctx, "eval_trigger", (id, k, i)) {
            Ok(b) => b,
            Err(e) => {
                self.record(e);
                false
            }
        }
    }

    fn run_effect(&mut self, id: &str, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        let (k, i) = scope_to_lua(scope);
        let r = self.call(ctx, "run_effect", (id, k, i));
        self.outcome(r)
    }

    fn on_action(&mut self, name: &str, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        let (k, i) = scope_to_lua(scope);
        let r = self.call(ctx, "on_action", (name, k, i));
        self.outcome(r)
    }

    fn weight(&mut self, id: &str, scope: Scope, ctx: &mut ScriptCtx) -> Fixed {
        let (k, i) = scope_to_lua(scope);
        match self.call::<_, Option<f64>>(ctx, "weight", (id, k, i)) {
            Ok(Some(w)) => fx(w),
            Ok(None) => Fixed::ONE,
            Err(e) => {
                self.record(e);
                Fixed::ONE
            }
        }
    }

    fn daily_script_state(&mut self, ctx: &mut ScriptCtx) {
        if let Err(e) = self.call::<_, ()>(ctx, "daily_script_state", ()) {
            self.record(e);
        }
    }

    fn scope_daily_events(&mut self, scope: Scope, ctx: &mut ScriptCtx) -> EffectOutcome {
        let (k, i) = scope_to_lua(scope);
        let r = self.call(ctx, "scope_daily_events", (k, i));
        self.outcome(r)
    }
}
