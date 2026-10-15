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

/// The directory the Lua tree is read from (`sim/lua`, `lua/`, `lib/stellar-lua-pdxscript`,
/// `sim/render/lua`), found at run time: `STELLAR_HOME` if set; else the executable's directory if
/// it holds the tree (`sim/lua/engine`: a release package); else the repository the crate was built
/// from (its parent directory).
pub fn repo_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("STELLAR_HOME").filter(|home| !home.is_empty()) {
        return PathBuf::from(home);
    }
    if let Some(dir) = std::env::current_exe().ok().as_deref().and_then(Path::parent) {
        if dir.join("sim/lua/engine").is_dir() {
            return dir.to_path_buf();
        }
    }
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

static CLOCK_START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();

/// The platform's clock: seconds since the process first read it. The deadlines of a phase run in
/// pieces (`Simulation::step_until`) are on it, and Lua reads it through `RUST.now_fn`.
pub fn clock() -> f64 {
    CLOCK_START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

/// An instant on the platform's clock (0 for one before its start).
pub fn clock_at(t: std::time::Instant) -> f64 {
    t.saturating_duration_since(*CLOCK_START.get_or_init(std::time::Instant::now)).as_secs_f64()
}

/// [`clock`] for LuaJIT's FFI: engine.slice casts `RUST.now_fn` to `double (*)(void)`, a call that
/// compiles into the traces.
extern "C" fn clock_ffi() -> f64 {
    clock()
}

/// glibc's allocator set for the simulation's heaps (once per process; the Lua states allocate
/// through it, mlua's allocator being the global one). By default a thread's arena grows its heap
/// by a page or so at a time with mprotect and gives memory back as soon as 128 KB are free at its
/// top, so the collector's frees and the next allocations faulted the same pages in again (35 days
/// from the 2210 save: 278,000 mprotect calls on the simulation's thread, each taking the process's
/// memory map lock, which the other threads' page faults then waited for); and freeing a block of 64
/// KB or more walked the arena's fastbins, the many small blocks the collector freed (sweep steps of
/// 1-2 ms). Here: memory kept (trim threshold 1 GB), heaps grown 64 MB at a time, blocks up to 32
/// MB from the heap, no fastbins. 35 days sliced: 2.25 game days a second against 1.92, the slices
/// longer than 1 ms from 54 to 19 (docs/frame_timing.md). STELLAR_MALLOC=default leaves glibc's
/// defaults.
pub fn tune_malloc() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        if std::env::var("STELLAR_MALLOC").as_deref() == Ok("default") {
            return;
        }
        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        unsafe {
            extern "C" {
                fn mallopt(param: i32, value: i32) -> i32;
            }
            const M_MXFAST: i32 = 1;
            const M_TRIM_THRESHOLD: i32 = -1;
            const M_TOP_PAD: i32 = -2;
            const M_MMAP_THRESHOLD: i32 = -3;
            mallopt(M_MXFAST, 0);
            mallopt(M_TRIM_THRESHOLD, 1 << 30);
            mallopt(M_TOP_PAD, 64 << 20);
            mallopt(M_MMAP_THRESHOLD, 32 << 20);
        }
    });
}

static GC_PAUSE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(400);

/// The collector's pause the Lua states made from now on take (400 unless set; STELLAR_GC_PAUSE
/// overrides it): set before a state is made, since LuaJIT takes a new pause only at the end of
/// a cycle (a state that loaded at 400 grows to five times its live heap before the next).
pub fn set_gc_pause(percent: u32) {
    GC_PAUSE.store(percent, std::sync::atomic::Ordering::Release);
}

fn gc_pause() -> u32 {
    GC_PAUSE.load(std::sync::atomic::Ordering::Acquire)
}

static SLICES_AHEAD: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether the simulation made from now on will run in slices (set before its load: the worker
/// pool, made with the load, faults its threads' heaps in then: [`prefault_heap`]).
pub fn set_slices_ahead(on: bool) {
    SLICES_AHEAD.store(on, std::sync::atomic::Ordering::Release);
}

pub fn slices_ahead() -> bool {
    SLICES_AHEAD.load(std::sync::atomic::Ordering::Acquire)
}

/// Memory for this thread's heap faulted in now, `mb` MB of it (the environment variable `env`
/// overrides it; 0: none): blocks allocated, a byte written in each page, and freed. With
/// [`tune_malloc`]'s settings glibc keeps them in the thread's arena, so the heap's growth while
/// the simulation runs takes pages already there: a first touch is a page fault, which no hook stops
/// (35 days sliced from the 2210 save: 1.2 GB of new pages on the simulation's thread, bursts of 100
/// faults and more making a piece up to 1 ms late; 64,000 faults still with 1.5 GB faulted in, none
/// to speak of with 2 GB). Run on the thread that will run the Lua state, before its slices
/// (glibc's arena is the thread's).
pub fn prefault_heap(mb: usize, env: &str) {
    let mb = std::env::var(env).ok().and_then(|v| v.parse().ok()).unwrap_or(mb);
    if mb == 0 || cfg!(not(all(target_os = "linux", target_env = "gnu"))) {
        return;
    }
    // (blocks under glibc's mmap threshold, 32 MB with tune_malloc, so they come from the arena)
    const BLOCK: usize = 16 << 20;
    let layout = std::alloc::Layout::from_size_align(BLOCK, 16).unwrap();
    let mut blocks = Vec::new();
    for _ in 0..(mb << 20) / BLOCK {
        // SAFETY: a fresh allocation of `BLOCK` bytes, written within its bounds and freed below
        unsafe {
            let p = std::alloc::alloc(layout);
            if p.is_null() {
                break;
            }
            for off in (0..BLOCK).step_by(4096) {
                std::ptr::write_volatile(p.add(off), 0);
            }
            blocks.push(p);
        }
    }
    for p in blocks {
        unsafe { std::alloc::dealloc(p, layout) };
    }
}

/// A LuaJIT state with the require paths and the `RUST.list_files` / `RUST.clock` helpers.
pub fn new_lua() -> mlua::Result<Lua> {
    tune_malloc();
    // SAFETY: the full LuaJIT library (ffi included), as the game's runtime has it; the Lua code is
    // this repository's.
    let lua = unsafe { Lua::unsafe_new_with(StdLib::ALL, LuaOptions::new()) };
    // the JIT's limits raised: with LuaJIT's defaults (1000 traces, 512 KB of machine code) the
    // engine's code fills the trace cache and LuaJIT flushes and recompiles it all, about 3 times a
    // simulated day (181 flushes and 257,000 traces in 60 days, against none and 28,000 with these)
    lua.load(
        r#"jit.opt.start("maxtrace=40000", "maxrecord=40000", "maxirconst=4000", "maxside=400",
            "maxsnap=2000", "sizemcode=1024", "maxmcode=524288", "hotloop=56", "hotexit=10")"#,
    )
    .exec()?;
    // STELLAR_JIT=off: the interpreter only (to compare: the VM stops compiled code at a deadline
    // too, sim/vendor/README.md)
    if std::env::var("STELLAR_JIT").as_deref() == Ok("off") {
        lua.load("jit.off()").exec()?;
    }
    // table.sort in Lua, the C function's algorithm and order: a comparator called from C cannot
    // yield, so the VM could not stop a sort at a deadline (sim/src/preempt.rs)
    let sort: Function = lua.load(include_str!("table_sort.lua")).set_name("=table.sort (sim/src/table_sort.lua)").eval()?;
    lua.globals().get::<Table>("table")?.set("sort", sort)?;
    // require in Lua for the same reason: a module's first load (its chunk, run to its end) would
    // otherwise be one call the VM cannot stop
    let (require, precompile): (Function, Function) =
        lua.load(include_str!("require.lua")).set_name("=require (sim/src/require.lua)").eval()?;
    lua.globals().set("require", require)?;
    // the collector's pause (percent of the live heap to allocate before a new cycle): the heap is
    // mostly the world and the definitions, which live for the whole run, so every cycle walks them
    // again. 180 days from 2210.01.01: 238 ms a day and 4.1 GB at LuaJIT's 200, 209 ms and 6.0 GB at
    // 400, 203 ms and 9.0 GB at 800 (half of the monthly modifier rebuild had been the collector);
    // STELLAR_GC_PAUSE overrides it, and a program may choose another default ([`set_gc_pause`])
    let pause = std::env::var("STELLAR_GC_PAUSE").ok().and_then(|v| v.parse::<u32>().ok()).unwrap_or_else(gc_pause);
    lua.load(format!("collectgarbage('setpause', {pause})")).exec()?;
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
    // the platform's clock as a C function's address, for engine.slice (an FFI call compiles)
    rust.set("now_fn", clock_ffi as extern "C" fn() -> f64 as usize as f64)?;
    // the game's noise function, for generators kept in Lua (the AI's own, one per country)
    rust.set(
        "noise",
        lua.create_function(|_, (position, seed): (u32, u32)| Ok(crate::rng::noise(position, seed)))?,
    )?;
    lua.globals().set("RUST", rust)?;
    lua.globals().set("E", lua.create_table()?)?;
    // the simulation's modules compiled now, the first three templates of the path above (a
    // module's compile at its first require would be a step the VM cannot stop)
    let templates = lua.create_sequence_from([
        lua.create_sequence_from([format!("{repo}/sim/lua"), "?.lua".to_string()])?,
        lua.create_sequence_from([format!("{repo}/sim/lua"), "?/init.lua".to_string()])?,
        lua.create_sequence_from([format!("{repo}/lib/stellar-lua-pdxscript"), "?.lua".to_string()])?,
    ])?;
    precompile.call::<()>(templates)?;
    Ok(lua)
}

/// The game in Lua, over the platform's date and random number generator.
pub struct Runtime {
    pub lua: Lua,
    engine: Table,
    /// engine.slice.set_deadline: the deadline of the phase's next piece
    set_deadline: Function,
    /// the end of the frame the pieces run in ([`Runtime::set_frame_end`]), for engine.slice's
    /// record of the stretches that cross it
    frame_end: Cell<f64>,
    /// whether the VM itself stops a piece past its deadline ([`Runtime::set_preempt`])
    preempt: Cell<bool>,
    pub date: Rc<Cell<Date>>,
    pub rng: Rc<RefCell<NoiseRandom>>,
    /// The month's pool of random draws (`CGameState::MonthlyUpdate` draws 1,000 at its start, read
    /// by the colonies' demography): `RUST.monthly_pool()`.
    pub monthly_pool: Rc<RefCell<Vec<i32>>>,
    /// The day's pool of random draws (`DailyUpdate`'s 1,000, read by the parallel per-object
    /// updates: ethics, factions, ...): `RUST.daily_pool()`.
    pub daily_pool: Rc<RefCell<Vec<i32>>>,
    /// The shared store and the worker pool, made when Lua asks for them (`RUST.store()`,
    /// `RUST.pool_start(n)`: sim/src/store.rs, docs/data_layer.md).
    pub shared: crate::store::Handle,
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
        let shared = crate::store::install(&lua)?;
        let engine: Table = lua.load("return require('engine')").set_name("engine").eval()?;
        let slice: Table = engine.get("slice")?;
        let set_deadline: Function = slice.get("set_deadline")?;
        Ok(Runtime {
            lua,
            engine,
            set_deadline,
            frame_end: Cell::new(f64::INFINITY),
            preempt: Cell::new(false),
            date,
            rng,
            monthly_pool,
            daily_pool,
            shared,
        })
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

    /// The end of the frame the next pieces run in, on the platform's [`clock`] (the deadline a
    /// piece is given is earlier, by a margin): engine.slice records the stretches between its
    /// checks that cross it (`slice.report`).
    pub fn set_frame_end(&self, t: f64) {
        self.frame_end.set(t);
    }

    /// Whether the VM itself stops a phase's piece past its deadline ([`crate::preempt`]: a count
    /// hook that yields, wherever the Lua code is), in place of engine.slice's checks, which then
    /// only keep their record (`slice.passive`); engine.slice still yields where a phase waits for
    /// the worker pool.
    pub fn set_preempt(&self, on: bool) -> mlua::Result<()> {
        self.preempt.set(on);
        let f: Function = self.engine.get::<Table>("slice")?.get("passive")?;
        f.call(on)
    }

    /// A phase of the tick as a coroutine, to run in pieces with [`Runtime::resume_phase`].
    pub fn phase_thread(&self) -> mlua::Result<mlua::Thread> {
        let f: Function = self.engine.get("phase")?;
        self.lua.create_thread(f)
    }

    /// Runs a phase's coroutine (the first time with the phase's arguments: its kind and name)
    /// until it finishes, or, past `deadline` on the platform's [`clock`], until it yields (the VM
    /// stops it with [`Runtime::set_preempt`], else at one of engine.slice's checks); whether it
    /// finished (an error finishes it).
    pub fn resume_phase(&self, thread: &mlua::Thread, first: Option<(&str, &str)>, deadline: f64) -> mlua::Result<bool> {
        self.set_deadline.call::<()>((deadline, self.frame_end.get()))?;
        let preempt = self.preempt.get() && deadline.is_finite();
        if preempt {
            crate::preempt::arm(&self.lua, deadline);
        }
        let r = match first {
            Some((kind, name)) => {
                let d = self.date.get();
                thread.resume::<mlua::MultiValue>((kind, name, d.year(), d.month(), d.day_of_month()))
            }
            None => thread.resume::<mlua::MultiValue>(()),
        };
        if preempt {
            crate::preempt::disarm(&self.lua);
        }
        // outside the pieces nothing yields: commands, saves and tools run whole
        self.set_deadline.call::<()>(f64::INFINITY)?;
        r?;
        Ok(!matches!(thread.status(), mlua::ThreadStatus::Resumable))
    }

    /// What engine.slice saw: the yields, and the longest gaps between its checks by site.
    pub fn slice_report(&self) -> String {
        self.eval::<String>("return require('engine.slice').report(30)").unwrap_or_else(|e| format!("slice report failed: {e}"))
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
