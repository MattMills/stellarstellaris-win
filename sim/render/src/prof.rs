//! The frame profiler (docs/profiling.md): span timers by name, per thread, summed by frame.
//!
//! STELLAR_PROF=1 turns it on (read once, at the start: [`init`]); off, a span is one relaxed
//! atomic load and nothing else. A span is a guard: `let _s = prof::span("scene: galaxy");` times
//! the scope it lives in, its own time apart from its children's (the spans opened inside it on
//! the same thread). [`frame_end`] closes a thread's frame: each span's time in that frame is
//! one sample of its per-frame cost (the UI thread's period in the window, a `bench` frame).
//!
//! [`report`] is the table of every thread's spans by their total time: calls, calls a frame,
//! the total and self time, the mean a frame, the most a frame and the longest call. The
//! protocol's `prof report [PATH]` and `bench` print it; the window prints it at its end (and
//! every STELLAR_PROF_EVERY seconds with it set). render.prof (lua/render/prof.lua) is the GUI
//! Lua's sampling profiler (STELLAR_LUA_PROF), reported with it.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

static ON: AtomicBool = AtomicBool::new(false);

/// Reads STELLAR_PROF (anything but empty or 0 turns the profiler on).
pub fn init() {
    let on = std::env::var("STELLAR_PROF").is_ok_and(|v| !v.is_empty() && v != "0");
    ON.store(on, Ordering::Relaxed);
}

#[inline]
pub fn on() -> bool {
    ON.load(Ordering::Relaxed)
}

/// Turns the profiler on or off from a command (`prof on|off`).
pub fn set(on: bool) {
    ON.store(on, Ordering::Relaxed);
}

#[derive(Default, Clone)]
struct Acc {
    calls: u64,
    total: f64,
    own: f64,
    longest: f64,
    /// this frame's sum, and the frames it was in, the most of one
    frame: f64,
    frames: u64,
    frame_max: f64,
}

#[derive(Default)]
struct Data {
    name: String,
    spans: HashMap<&'static str, Acc>,
    /// the children's time of each span open, innermost last
    stack: Vec<f64>,
    frames: u64,
}

fn threads() -> &'static Mutex<Vec<Arc<Mutex<Data>>>> {
    static T: OnceLock<Mutex<Vec<Arc<Mutex<Data>>>>> = OnceLock::new();
    T.get_or_init(Default::default)
}

thread_local! {
    static MINE: Arc<Mutex<Data>> = {
        let d = Arc::new(Mutex::new(Data { name: std::thread::current().name().unwrap_or("?").to_string(), ..Default::default() }));
        threads().lock().unwrap().push(d.clone());
        d
    };
}

/// A name made at run time, kept for the process (the names are few: windows, phases).
pub fn intern(name: &str) -> &'static str {
    static NAMES: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();
    let mut set = NAMES.get_or_init(Default::default).lock().unwrap();
    if let Some(n) = set.get(name) {
        return n;
    }
    let n: &'static str = Box::leak(name.to_string().into_boxed_str());
    set.insert(n);
    n
}

/// A span open: timed until dropped.
#[must_use]
pub struct Span(Option<(&'static str, Instant)>);

/// Times the scope the guard lives in under `name`.
#[inline]
pub fn span(name: &'static str) -> Span {
    if !on() {
        return Span(None);
    }
    MINE.with(|d| d.lock().unwrap().stack.push(0.0));
    Span(Some((name, Instant::now())))
}

/// [`span`] with a name made at run time (interned: only when the profiler is on).
#[inline]
pub fn span_dyn(name: impl FnOnce() -> String) -> Span {
    if !on() {
        return Span(None);
    }
    span(intern(&name()))
}

impl Drop for Span {
    fn drop(&mut self) {
        if let Some((name, t0)) = self.0.take() {
            let dt = t0.elapsed().as_secs_f64();
            MINE.with(|d| {
                let mut d = d.lock().unwrap();
                let children = d.stack.pop().unwrap_or(0.0);
                if let Some(parent) = d.stack.last_mut() {
                    *parent += dt;
                }
                add(&mut d, name, dt, (dt - children).max(0.0));
            });
        }
    }
}

fn add(d: &mut Data, name: &'static str, dt: f64, own: f64) {
    let a = d.spans.entry(name).or_default();
    a.calls += 1;
    a.total += dt;
    a.own += own;
    a.longest = a.longest.max(dt);
    a.frame += dt;
}

/// A time measured elsewhere (`t0` to now) recorded as a span of its own (no children).
pub fn record(name: &str, t0: Instant) {
    if !on() {
        return;
    }
    let dt = t0.elapsed().as_secs_f64();
    let name = intern(name);
    MINE.with(|d| {
        let mut d = d.lock().unwrap();
        if let Some(parent) = d.stack.last_mut() {
            *parent += dt;
        }
        add(&mut d, name, dt, dt);
    });
}

/// The end of this thread's frame: each span's time in it a sample of its cost a frame.
pub fn frame_end() {
    if !on() {
        return;
    }
    MINE.with(|d| {
        let mut d = d.lock().unwrap();
        d.frames += 1;
        for a in d.spans.values_mut() {
            if a.frame > 0.0 {
                a.frames += 1;
                a.frame_max = a.frame_max.max(a.frame);
                a.frame = 0.0;
            }
        }
    });
}

/// Every thread's spans forgotten (a measurement's start).
pub fn reset() {
    for d in threads().lock().unwrap().iter() {
        let mut d = d.lock().unwrap();
        d.spans.clear();
        d.frames = 0;
    }
}

/// The spans' table, each thread's by total time; `top`: the rows a thread at most.
pub fn report(top: usize) -> String {
    let mut out = String::new();
    for d in threads().lock().unwrap().iter() {
        let d = d.lock().unwrap();
        if d.spans.is_empty() {
            continue;
        }
        let frames = d.frames.max(1) as f64;
        out.push_str(&format!(
            "thread {} ({} frames)\n  {:<44} {:>8} {:>7} {:>10} {:>10} {:>9} {:>9} {:>9}\n",
            d.name, d.frames, "span", "calls", "/frame", "total ms", "self ms", "ms/frame", "max/frame", "max call"
        ));
        let mut rows: Vec<(&&str, &Acc)> = d.spans.iter().collect();
        rows.sort_by(|a, b| b.1.total.partial_cmp(&a.1.total).unwrap());
        for (name, a) in rows.into_iter().take(top) {
            let frame_max = a.frame_max.max(a.frame);
            out.push_str(&format!(
                "  {:<44} {:>8} {:>7.1} {:>10.1} {:>10.1} {:>9.3} {:>9.2} {:>9.2}\n",
                name,
                a.calls,
                a.calls as f64 / frames,
                a.total * 1e3,
                a.own * 1e3,
                a.total * 1e3 / frames,
                frame_max * 1e3,
                a.longest * 1e3
            ));
        }
    }
    out
}

/// The GUI Lua's sampling profiler started in `runtime` with STELLAR_LUA_PROF set (its interval
/// in ms; STELLAR_LUA_PROF_DEPTH the stacks' depth): render.prof.
pub fn lua_start(runtime: &stellar_sim::Runtime) {
    let Some(ms) = std::env::var("STELLAR_LUA_PROF").ok().and_then(|v| v.parse::<f64>().ok()).filter(|v| *v > 0.0) else { return };
    let depth = std::env::var("STELLAR_LUA_PROF_DEPTH").ok().and_then(|v| v.parse::<u32>().ok()).unwrap_or(8);
    match runtime.lua.load(format!("return require('render.prof').start({ms}, {depth})")).eval::<bool>() {
        Ok(true) => eprintln!("lua profiler: a sample every {ms} ms, stacks {depth} deep"),
        Ok(false) => eprintln!("lua profiler: not started (no jit.profile, or another state has it)"),
        Err(e) => eprintln!("lua profiler: {e}"),
    }
}

/// The Rust spans' table and the GUI Lua's samples (`runtime`'s, if it has them); `reset`:
/// both forgotten after.
pub fn full_report(runtime: &stellar_sim::Runtime, top: usize, reset_after: bool) -> String {
    let mut out = report(top);
    if let Ok(s) = runtime.lua.load(format!("return package.loaded['render.prof'] and require('render.prof').report({top}) or ''")).eval::<String>() {
        out.push_str(&s);
    }
    if reset_after {
        reset();
        let _ = runtime.lua.load("if package.loaded['render.prof'] then require('render.prof').reset() end").exec();
    }
    out
}

/// The few spans that cost the most a frame on this thread: `name ms/frame` pairs (a reply's
/// summary).
pub fn summary(top: usize) -> String {
    MINE.with(|d| {
        let d = d.lock().unwrap();
        let frames = d.frames.max(1) as f64;
        let mut rows: Vec<(&&str, &Acc)> = d.spans.iter().collect();
        rows.sort_by(|a, b| b.1.own.partial_cmp(&a.1.own).unwrap());
        rows.into_iter().take(top).map(|(n, a)| format!("{n} {:.2}", a.own * 1e3 / frames)).collect::<Vec<_>>().join(", ")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_nest_and_sum_by_frame() {
        set(true);
        for _ in 0..2 {
            let _outer = span("test: outer");
            {
                let _inner = span("test: inner");
                std::thread::sleep(std::time::Duration::from_millis(3));
            }
            frame_end();
        }
        let (outer, inner) = MINE.with(|d| {
            let d = d.lock().unwrap();
            (d.spans["test: outer"].clone(), d.spans["test: inner"].clone())
        });
        assert_eq!((outer.calls, inner.calls), (2, 2));
        // the inner's time is the outer's children's: its own time is the rest
        assert!(inner.total >= 0.006 && outer.total >= inner.total);
        assert!(outer.own < 0.002, "outer's own time {}", outer.own);
        assert!(report(10).contains("test: inner"));
    }
}
