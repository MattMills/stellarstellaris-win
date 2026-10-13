//! The Lua runtime the game runs in.
//!
//! Everything the game is made of runs in Lua from the game's own files (`sim/lua/engine`):
//! the definitions of every `common/` folder of the vanilla file set, the script layer
//! (`sim/lua/simscript`: events, on_actions, scripted triggers, effects and values), the world
//! loaded from a save, and the engine's systems. This module is the platform under it: a LuaJIT
//! state with the require paths (`sim/lua`, the repo's `lua/`, the pdxscript library), the
//! `RUST` helpers (`list_files`, `clock`, `date`, `rand`) and the calls into `engine`.
//!
//! The date and the game's random number generator are the platform's: the scheduler advances the
//! date and forbids random draws in the parallel phases, as the game does.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use mlua::{Function, Lua, LuaOptions, StdLib, Table};

use crate::date::Date;
use crate::rng::NoiseRandom;

/// The repository (the crate's parent directory).
pub fn repo_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
}

/// The `.<ext>` files (`txt` by default) under `root/sub`, recursively, as sorted relative paths
/// with `/`.
pub fn list_files(root: &str, sub: &str, ext: Option<&str>) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, ext: &str, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(base, &p, ext, out);
            } else if p.extension().map_or(false, |x| x.eq_ignore_ascii_case(ext)) {
                if let Ok(rel) = p.strip_prefix(base) {
                    out.push(rel.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    let base = Path::new(root);
    let mut out = Vec::new();
    walk(base, &base.join(sub), ext.unwrap_or("txt"), &mut out);
    out.sort();
    out
}

/// A LuaJIT state with the require paths and the `RUST.list_files` / `RUST.clock` helpers.
pub fn new_lua() -> mlua::Result<Lua> {
    // SAFETY: the full LuaJIT library (ffi included), as the game's runtime has it; the Lua code is
    // this repository's.
    let lua = unsafe { Lua::unsafe_new_with(StdLib::ALL, LuaOptions::new()) };
    let repo = repo_dir().to_string_lossy().replace('\\', "/");
    let package: Table = lua.globals().get("package")?;
    package.set(
        "path",
        format!(
            "{repo}/sim/lua/?.lua;{repo}/sim/lua/?/init.lua;{repo}/lib/stellar-lua-pdxscript/?.lua;{repo}/lua/?.lua;{repo}/lua/?/init.lua"
        ),
    )?;
    let rust = lua.create_table()?;
    rust.set(
        "list_files",
        lua.create_function(|_, (root, sub, ext): (String, String, Option<String>)| {
            Ok(list_files(&root, &sub, ext.as_deref()))
        })?,
    )?;
    let start = std::time::Instant::now();
    rust.set("clock", lua.create_function(move |_, ()| Ok(start.elapsed().as_secs_f64()))?)?;
    // the game's noise function, for generators kept in Lua (the AI's own, one per country)
    rust.set(
        "noise",
        lua.create_function(|_, (position, seed): (u32, u32)| Ok(crate::rng::noise(position, seed)))?,
    )?;
    lua.globals().set("RUST", rust)?;
    lua.globals().set("E", lua.create_table()?)?;
    Ok(lua)
}

/// The game in Lua, over the platform's date and random number generator.
pub struct Runtime {
    pub lua: Lua,
    engine: Table,
    pub date: Rc<Cell<Date>>,
    pub rng: Rc<RefCell<NoiseRandom>>,
    /// The month's pool of random draws (`CGameState::MonthlyUpdate` draws 1,000 at its start, read
    /// by the colonies' demography): `RUST.monthly_pool()`.
    pub monthly_pool: Rc<RefCell<Vec<i32>>>,
    /// The day's pool of random draws (`DailyUpdate`'s 1,000, read by the parallel per-object
    /// updates: ethics, factions, ...): `RUST.daily_pool()`.
    pub daily_pool: Rc<RefCell<Vec<i32>>>,
}

impl Runtime {
    /// A runtime at `date` with the game's generator seeded with `seed`; the engine module loaded,
    /// nothing read yet (see [`Runtime::load`]).
    pub fn new(date: Date, seed: u32) -> mlua::Result<Runtime> {
        let lua = new_lua()?;
        let date = Rc::new(Cell::new(date));
        let rng = Rc::new(RefCell::new(NoiseRandom::new(seed)));
        let rust: Table = lua.globals().get("RUST")?;
        let d = date.clone();
        rust.set("date", lua.create_function(move |_, ()| Ok(d.get().0))?)?;
        let r = rng.clone();
        rust.set(
            "rand",
            lua.create_function(move |_, ()| {
                let mut r = r.borrow_mut();
                if r.is_forbidden() {
                    return Err(mlua::Error::RuntimeError("random draw in a parallel phase".into()));
                }
                Ok(r.next_int())
            })?,
        )?;
        // RUST.skip(n): n draws whose values nothing reads (MicroUpdate's ship pool outside combat,
        // headless/README.md): the position advances by n
        let r = rng.clone();
        rust.set(
            "skip",
            lua.create_function(move |_, n: u32| {
                let mut r = r.borrow_mut();
                if r.is_forbidden() {
                    return Err(mlua::Error::RuntimeError("random draw in a parallel phase".into()));
                }
                r.position = r.position.wrapping_add(n);
                Ok(())
            })?,
        )?;
        let monthly_pool: Rc<RefCell<Vec<i32>>> = Rc::new(RefCell::new(Vec::new()));
        let mp = monthly_pool.clone();
        rust.set(
            "monthly_pool",
            lua.create_function(move |lua, ()| {
                let pool = mp.borrow();
                if pool.is_empty() {
                    return Ok(mlua::Value::Nil);
                }
                Ok(mlua::Value::Table(lua.create_sequence_from(pool.iter().copied())?))
            })?,
        )?;
        let daily_pool: Rc<RefCell<Vec<i32>>> = Rc::new(RefCell::new(Vec::new()));
        let dp = daily_pool.clone();
        rust.set(
            "daily_pool",
            lua.create_function(move |lua, ()| {
                let pool = dp.borrow();
                if pool.is_empty() {
                    return Ok(mlua::Value::Nil);
                }
                Ok(mlua::Value::Table(lua.create_sequence_from(pool.iter().copied())?))
            })?,
        )?;
        let engine: Table = lua.load("return require('engine')").set_name("engine").eval()?;
        Ok(Runtime { lua, engine, date, rng, monthly_pool, daily_pool })
    }

    /// Reads the vanilla file set from `game_dir` (the Stellaris install, in place) and the world
    /// from a save's gamestate; `docs_dir` is the game's `logs/script_documentation`, if any.
    /// Returns what was loaded.
    pub fn load(&self, game_dir: &str, gamestate: Option<&str>, docs_dir: Option<&str>) -> mlua::Result<String> {
        let f: Function = self.engine.get("load")?;
        let gs = match gamestate {
            Some(text) => Some(self.lua.create_string(text)?),
            None => None,
        };
        f.call((game_dir.replace('\\', "/"), gs, docs_dir.map(|d| d.replace('\\', "/"))))
    }

    /// Reads only the world from a save's gamestate (no definitions, no script layer): for tools
    /// and the renderer, which need the world fast.
    pub fn load_world(&self, gamestate: &str) -> mlua::Result<String> {
        let f: Function = self.engine.get("load_world")?;
        f.call(self.lua.create_string(gamestate)?)
    }

    /// One phase of the tick (`kind`: micro, ai, daily, monthly, yearly); whether something models it.
    pub fn phase(&self, kind: &str, name: &str) -> mlua::Result<bool> {
        let d = self.date.get();
        let f: Function = self.engine.get("phase")?;
        f.call((kind, name, d.year(), d.month(), d.day_of_month()))
    }

    /// A command between ticks: a scripted effect (or event) run on a scope.
    pub fn command_effect(&self, effect: &str, kind: &str, id: u32) -> mlua::Result<()> {
        let f: Function = self.engine.get("command")?;
        f.call(("effect", effect, kind, id))
    }

    /// The world as a save's gamestate, as it is now (dated today), and that date ("y.mm.dd").
    pub fn save_text(&self) -> mlua::Result<(String, String)> {
        let f: Function = self.engine.get("save")?;
        let text: mlua::String = f.call(())?;
        let date: Function = self.engine.get("date_text")?;
        Ok((text.to_str()?.to_string(), date.call(())?))
    }

    /// What ran, and what the world does not answer yet.
    pub fn report(&self) -> String {
        let f: mlua::Result<Function> = self.engine.get("report");
        match f.and_then(|f| f.call::<String>(())) {
            Ok(s) => s,
            Err(e) => format!("report failed: {e}"),
        }
    }

    /// Runs a chunk of Lua in the engine's state (tests, tools).
    pub fn eval<R: mlua::FromLuaMulti>(&self, chunk: &str) -> mlua::Result<R> {
        self.lua.load(chunk).eval()
    }
}
