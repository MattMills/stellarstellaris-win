//! Preemption at the Lua VM: a coroutine runs until a deadline, and the VM itself stops it, whatever
//! Lua code it is in, interpreted or compiled (docs/frame_timing.md). Nothing in the scripts takes
//! part.
//!
//! While a slice runs no hook is set: the interpreter and the compiled code run at full speed. A
//! preempter thread sleeps until the earliest deadline of the VMs that run a slice, and at a VM's
//! deadline sets an instruction hook with a count of 1 on it (from another thread: the use LuaJIT
//! documents for `LUAJIT_ENABLE_CHECKHOOK`). The interpreter runs the hook at its next instruction;
//! compiled code, which LuaJIT builds here to check the hooks at the start of every trace and every
//! loop iteration (sim/vendor/README.md), exits to the interpreter at its next check, which runs the
//! hook. The hook yields the running coroutine (`lua_yield` from a hook: LuaJIT adds a continuation
//! frame, and the coroutine goes on at the same instruction when it is resumed).
//!
//! What it cannot stop: a call into C or Rust in progress (a `table.sort` with a Lua comparator, a
//! Rust function the engine calls), a step of the collector. Where the coroutine cannot yield (a Lua
//! function called from C) the hook stays set and yields at the first instruction where it can.
//!
//! LuaJIT's hooks belong to the VM (all its coroutines). The VM's thread and the preempter set them
//! under the VM's lock, never at once.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::os::raw::c_int;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

use mlua::ffi;

use crate::runtime::clock;

/// A VM the preempter may stop: a state of it, the deadline of the slice it runs (infinite when
/// none), the deadline its hook was set for, and the lock both threads set its hooks under.
struct Vm {
    state: usize,
    deadline: AtomicU64,
    armed: AtomicU64,
    /// when the preempter set the hook (on `runtime::clock`)
    armed_at: AtomicU64,
    hooks: Mutex<()>,
}

struct Preempter {
    vms: Mutex<Vec<Arc<Vm>>>,
    wake: Condvar,
}

static PREEMPTER: OnceLock<Arc<Preempter>> = OnceLock::new();

fn preempter() -> &'static Arc<Preempter> {
    PREEMPTER.get_or_init(|| {
        let p = Arc::new(Preempter { vms: Mutex::new(Vec::new()), wake: Condvar::new() });
        let q = p.clone();
        std::thread::Builder::new().name("preempter".into()).spawn(move || run(&q)).expect("the preempter's thread");
        p
    })
}

const NONE: u64 = 0x7ff0_0000_0000_0000; // f64::INFINITY's bits

// How long before a deadline the preempter stops sleeping and spins to it: a sleeping thread wakes
// late by the timer's and the core's wake-up latency, tens of microseconds and at times over 100
// (with 80 µs, 2% of the hooks were set more than 10 µs late in some runs, up to 0.9 ms). On
// Windows 1 ms: its high resolution timers wake about half a millisecond late (with 0.25 ms, half
// the hooks came more than 0.1 ms late on the laptop; with 1 ms, 13,705 of 14,094 within 10 µs).
// STELLAR_PREEMPT_SPIN_US overrides it.
fn spin() -> f64 {
    static SPIN: OnceLock<f64> = OnceLock::new();
    *SPIN.get_or_init(|| {
        let default = if cfg!(windows) { 1000.0 } else { 250.0 };
        std::env::var("STELLAR_PREEMPT_SPIN_US").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(default) / 1e6
    })
}

// The preempter's thread above the others where the system allows it (a real-time policy on
// Linux, which needs the privilege; a time-critical thread on Windows): the system preempted it at
// times while it waited for a deadline, and the hooks came late.
fn raise_priority() {
    #[cfg(target_os = "linux")]
    unsafe {
        extern "C" {
            fn sched_setscheduler(pid: i32, policy: i32, param: *const i32) -> i32;
        }
        const SCHED_FIFO: i32 = 1;
        let priority = 1;
        sched_setscheduler(0, SCHED_FIFO, &priority);
    }
    #[cfg(windows)]
    unsafe {
        extern "system" {
            fn GetCurrentThread() -> *mut std::ffi::c_void;
            fn SetThreadPriority(thread: *mut std::ffi::c_void, priority: i32) -> i32;
        }
        const THREAD_PRIORITY_TIME_CRITICAL: i32 = 15;
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    }
}

// The preempter's lateness in setting the hooks: their number, the latest (seconds), and how many
// were set within 10, 25, 50 and 100 µs of the deadline and later
static ARMED: [AtomicU64; 5] = [const { AtomicU64::new(0) }; 5];
static ARMED_MAX: AtomicU64 = AtomicU64::new(0);

fn note_armed(late: f64) {
    let i = [10e-6, 25e-6, 50e-6, 100e-6].iter().position(|&b| late < b).unwrap_or(4);
    ARMED[i].fetch_add(1, Ordering::Relaxed);
    ARMED_MAX.fetch_max(late.max(0.0).to_bits(), Ordering::Relaxed);
}

/// The hooks the preempter set, by how late (within 10, 25, 50 and 100 µs of the deadline, and
/// later), and the latest (seconds).
pub fn armed_lateness() -> ([u64; 5], f64) {
    (std::array::from_fn(|i| ARMED[i].load(Ordering::Relaxed)), f64::from_bits(ARMED_MAX.load(Ordering::Relaxed)))
}

fn run(p: &Preempter) {
    crate::cadence::fine_timers();
    raise_priority();
    crate::cadence::pin(0);
    let mut vms = p.vms.lock().unwrap();
    loop {
        let now = clock();
        let mut next = f64::INFINITY;
        for vm in vms.iter() {
            let bits = vm.deadline.load(Ordering::Acquire);
            let d = f64::from_bits(bits);
            if !d.is_finite() || vm.armed.load(Ordering::Acquire) == bits {
                continue;
            }
            if d > now {
                next = next.min(d);
                continue;
            }
            // (a VM's thread holding its lock, itself held up, does not hold up the others': its hook
            // is tried again at once)
            let Ok(_h) = vm.hooks.try_lock() else {
                next = now;
                continue;
            };
            // (the slice may have ended in the meantime)
            if vm.deadline.load(Ordering::Acquire) == bits {
                let at = clock();
                vm.armed_at.store(at.to_bits(), Ordering::Release);
                unsafe {
                    ffi::lua_sethook(vm.state as *mut ffi::lua_State, Some(hook), ffi::LUA_MASKCOUNT, 1);
                }
                vm.armed.store(bits, Ordering::Release);
                note_armed(at - d);
            }
        }
        vms = if next.is_finite() {
            let wait = next - clock();
            if wait <= spin() {
                // (the lock free meanwhile: the VMs' threads take it to start a slice)
                drop(vms);
                while clock() < next {
                    std::hint::spin_loop();
                }
                p.vms.lock().unwrap()
            } else {
                // (Windows: a condition variable's timed wait wakes at the system timer's
                // granularity, a millisecond at best, where a sleep is high resolution: the lock
                // free, a sleep of 0.5 ms at most, and the VMs looked at again)
                #[cfg(windows)]
                {
                    drop(vms);
                    std::thread::sleep(Duration::from_secs_f64((wait - spin()).min(0.0005)));
                    p.vms.lock().unwrap()
                }
                #[cfg(not(windows))]
                {
                    p.wake.wait_timeout(vms, Duration::from_secs_f64(wait - spin())).unwrap().0
                }
            }
        } else {
            p.wake.wait(vms).unwrap()
        };
    }
}

thread_local! {
    /// The VM this thread runs (a thread runs one VM at a time).
    static VM: RefCell<Option<Arc<Vm>>> = const { RefCell::new(None) };
    /// The deadline of the slice running on this thread.
    static DEADLINE: Cell<f64> = const { Cell::new(f64::INFINITY) };
    /// The hook's yields on this thread, and its calls that could not yield.
    static YIELDS: Cell<u64> = const { Cell::new(0) };
    static REFUSED: Cell<u64> = const { Cell::new(0) };
    /// When the hook last yielded on this thread.
    static HOOK_AT: Cell<f64> = const { Cell::new(0.0) };
    /// The seconds per kind of [`stalls`] when the slice's piece began.
    static STALLS_AT: Cell<[f64; 5]> = const { Cell::new([0.0; 5]) };
}

// This thread's page faults, involuntary and voluntary context switches (getrusage RUSAGE_THREAD)
// and CPU time in ns (CLOCK_THREAD_CPUTIME_ID), to tell a late piece that waited for memory, for a
// CPU or for a lock.
#[cfg(target_os = "linux")]
fn thread_usage() -> [i64; 4] {
    #[repr(C)]
    struct RUsage {
        utime: [i64; 2],
        stime: [i64; 2],
        l: [i64; 14],
    }
    extern "C" {
        fn getrusage(who: i32, usage: *mut RUsage) -> i32;
        fn clock_gettime(clock: i32, ts: *mut [i64; 2]) -> i32;
    }
    let mut u = RUsage { utime: [0; 2], stime: [0; 2], l: [0; 14] };
    let mut ts = [0i64; 2];
    unsafe {
        getrusage(1, &mut u);
        clock_gettime(3, &mut ts);
    }
    [u.l[4] + u.l[5], u.l[13], u.l[12], ts[0] * 1_000_000_000 + ts[1]]
}
#[cfg(not(target_os = "linux"))]
fn thread_usage() -> [i64; 4] {
    [0; 4]
}

thread_local! {
    /// [`thread_usage`] and the clock when the slice's piece began.
    static USAGE_AT: Cell<([i64; 4], f64)> = const { Cell::new(([0; 4], 0.0)) };
}

fn stall_sums() -> [f64; 5] {
    let s = stalls();
    std::array::from_fn(|i| s[i][0])
}

extern "C-unwind" {
    // LuaJIT 2.1 has it (lj_api.c); mlua-sys declares it for Lua 5.3+ only.
    fn lua_isyieldable(L: *mut ffi::lua_State) -> c_int;
    // the vendored LuaJIT's record of this thread's steps no hook can stop (lj_gc.c)
    fn stellar_stalls(out: *mut f64);
    // the vendored LuaJIT told the deadline of this thread's slice: its compiler starts no trace
    // in the last `room` seconds before it (lj_gc.c, lj_trace.c)
    fn stellar_set_deadline(remaining: f64, room: f64, gc_room: f64);
}

// The room the JIT's compiler needs before a deadline to record and compile a trace: a trace that
// would start later waits for the next slice. STELLAR_JIT_ROOM_MS overrides it.
fn jit_room() -> f64 {
    static ROOM: OnceLock<f64> = OnceLock::new();
    *ROOM.get_or_init(|| std::env::var("STELLAR_JIT_ROOM_MS").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.4) / 1000.0)
}

// The room the collector needs before a deadline: a step that would come later waits for the next
// slice (the atomic phase, a large table marked: steps no hook stops). STELLAR_GC_ROOM_MS
// overrides it.
fn gc_room() -> f64 {
    static ROOM: OnceLock<f64> = OnceLock::new();
    *ROOM.get_or_init(|| std::env::var("STELLAR_GC_ROOM_MS").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.25) / 1000.0)
}

/// The kinds of steps no hook can stop, as the vendored LuaJIT records them per thread
/// (sim/vendor/README.md): the collector's phases, the JIT's compiler, the atomic phase's parts;
/// then two counts, the traces the compiler put off to the next slice and the recordings the
/// preempter's hook aborted; then a trace's optimization and assembly by its size (seconds in all,
/// the longest, the count).
pub const STALL_KINDS: [&str; 18] = [
    "GC mark",
    "GC atomic",
    "GC sweep",
    "GC finalize",
    "JIT compiler",
    "  atomic: left-overs",
    "  atomic: weak tables and roots",
    "  atomic: 2nd chance list",
    "  atomic: userdata",
    "  atomic: weak tables cleared",
    "JIT traces put off (count)",
    "JIT recordings aborted (count)",
    "trace compiled, < 100 IR",
    "trace compiled, 100-299 IR",
    "trace compiled, 300-999 IR",
    "trace compiled, 1000-2999 IR",
    "trace compiled, 3000+ IR",
    "GC steps put off (count)",
];

/// This thread's record: per kind the seconds in all, the longest step, the steps over 0.1 ms.
pub fn stalls() -> [[f64; 3]; 18] {
    let mut a = [[0.0; 3]; 18];
    unsafe { stellar_stalls(a.as_mut_ptr() as *mut f64) };
    a
}

static KEPT: Mutex<Vec<(String, [[f64; 3]; 18])>> = Mutex::new(Vec::new());

/// Keeps this thread's record under its name, in place of the one kept before.
pub fn keep_stalls(thread: &str) {
    let s = stalls();
    let mut kept = KEPT.lock().unwrap();
    match kept.iter_mut().find(|k| k.0 == thread) {
        Some(k) => k.1 = s,
        None => kept.push((thread.to_string(), s)),
    }
}

/// The records kept (and empties them).
pub fn kept_stalls() -> Vec<(String, [[f64; 3]; 18])> {
    std::mem::take(&mut *KEPT.lock().unwrap())
}

fn take_hook_off(vm: &Vm) {
    let _h = vm.hooks.lock().unwrap();
    unsafe {
        ffi::lua_sethook(vm.state as *mut ffi::lua_State, None, 0, 0);
    }
    vm.armed.store(NONE, Ordering::Release);
}

unsafe extern "C-unwind" fn hook(state: *mut ffi::lua_State, _ar: *mut ffi::lua_Debug) {
    let (now, deadline) = (clock(), DEADLINE.with(|d| d.get()));
    if now < deadline {
        // set for a slice that is over: off again
        VM.with(|v| {
            if let Some(vm) = v.borrow().as_ref() {
                take_hook_off(vm);
            }
        });
        return;
    }
    if lua_isyieldable(state) == 0 {
        let n = REFUSED.with(|r| {
            r.set(r.get() + 1);
            r.get()
        });
        if n % 64 == 1 && *TRACE.get_or_init(|| std::env::var("STELLAR_PREEMPT_TRACE").as_deref() == Ok("1")) {
            let w = where_(state);
            *REFUSALS.lock().unwrap().get_or_insert_with(HashMap::new).entry(w).or_insert(0) += 1;
        }
        return;
    }
    YIELDS.with(|y| y.set(y.get() + 1));
    HOOK_AT.with(|h| h.set(now));
    if now - deadline > LATE {
        let armed_at = VM.with(|v| v.borrow().as_ref().map(|vm| f64::from_bits(vm.armed_at.load(Ordering::Acquire))));
        let cause = if armed_at.unwrap_or(deadline) - deadline > LATE { "set late" } else { "ran late" };
        note_late(cause, now - deadline, where_(state));
    }
    // (no value of this frame needs dropping: lua_yield unwinds through it)
    ffi::lua_yield(state, 0);
}

/// This thread's VM record for `lua`, registered with the preempter when new.
fn vm_of(lua: &mlua::Lua) -> Arc<Vm> {
    let mut state = 0usize;
    unsafe {
        let _ = lua.exec_raw::<()>((), |s| state = s as usize);
    }
    VM.with(|v| {
        let mut v = v.borrow_mut();
        // (hooks are the VM's: any state of it will do, but the main one stays for its life)
        if let Some(vm) = v.as_ref() {
            if vm.state == state {
                return vm.clone();
            }
        }
        let p = preempter();
        let vm = Arc::new(Vm { state, deadline: AtomicU64::new(NONE), armed: AtomicU64::new(NONE), armed_at: AtomicU64::new(0), hooks: Mutex::new(()) });
        let mut vms = p.vms.lock().unwrap();
        if let Some(old) = v.take() {
            vms.retain(|x| !Arc::ptr_eq(x, &old));
        }
        vms.push(vm.clone());
        *v = Some(vm.clone());
        vm
    })
}

/// A slice of `lua` that ends at `deadline` (on `runtime::clock`): the preempter stops it there.
pub fn arm(lua: &mlua::Lua, deadline: f64) {
    let vm = vm_of(lua);
    let now = clock();
    if now - deadline > LATE {
        note_late("piece", now - deadline, "started past its deadline".to_string());
    }
    STALLS_AT.with(|s| s.set(stall_sums()));
    USAGE_AT.with(|u| u.set((thread_usage(), now)));
    unsafe { stellar_set_deadline(deadline - now, jit_room(), gc_room()) };
    DEADLINE.with(|d| d.set(deadline));
    let p = preempter();
    {
        let _vms = p.vms.lock().unwrap();
        vm.deadline.store(deadline.to_bits(), Ordering::Release);
    }
    p.wake.notify_one();
}

/// The slice is over: no deadline, and the hook off if the preempter set it.
pub fn disarm(lua: &mlua::Lua) {
    let vm = vm_of(lua);
    let deadline = DEADLINE.with(|d| d.replace(f64::INFINITY));
    unsafe { stellar_set_deadline(f64::INFINITY, 0.0, 0.0) };
    let end = clock();
    if end - deadline > LATE {
        // a piece that ran past its deadline by more than the margin: how it ended
        let hook_at = HOOK_AT.with(|h| h.get());
        let cause = if hook_at >= deadline {
            if hook_at - deadline > LATE {
                "the hook yielded late"
            } else {
                "the hook yielded in time, the resume came back late"
            }
        } else if vm.armed.load(Ordering::Acquire) != deadline.to_bits() {
            "ended by itself before the hook was set"
        } else {
            "ended by itself after the hook was set (in C or Rust, or could not yield)"
        };
        // the longest kind of step no hook stops in the piece, if one took half the margin
        let (a, b) = (STALLS_AT.with(|s| s.get()), stall_sums());
        let (kind, secs) = (0..5).map(|i| (i, b[i] - a[i])).fold((0, 0.0), |m, x| if x.1 > m.1 { x } else { m });
        let cause = if secs > LATE / 2.0 {
            let ms = secs * 1000.0;
            let b = if ms < 0.1 { "0.05-0.1" } else if ms < 0.5 { "0.1-0.5" } else if ms < 1.0 { "0.5-1" } else if ms < 2.0 { "1-2" } else { "2+" };
            format!("{cause}; in it {} of {b} ms", STALL_KINDS[kind])
        } else {
            cause.to_string()
        };
        // and whether the thread waited: page faults, or off the CPU (preempted by the system)
        let ((u0, t0), u1) = (USAGE_AT.with(|u| u.get()), thread_usage());
        let faults = u1[0] - u0[0];
        let off = (end - t0) - (u1[3] - u0[3]) as f64 / 1e9;
        let mut cause = cause;
        if faults > 0 {
            cause += if faults < 10 { "; page faults 1-9" } else if faults < 100 { "; page faults 10-99" } else { "; page faults 100+" };
        }
        if off > LATE / 2.0 {
            let how = if u1[1] > u0[1] { "preempted" } else if u1[2] > u0[2] { "blocked" } else { "?" };
            cause += &format!("; off the CPU ({how})");
        }
        note_late("piece", end - deadline, cause);
    }
    vm.deadline.store(NONE, Ordering::Release);
    if vm.armed.load(Ordering::Acquire) != NONE {
        take_hook_off(&vm);
    }
}

/// This thread's VM no longer preempted (before the VM is dropped).
pub fn release() {
    VM.with(|v| {
        if let Some(old) = v.borrow_mut().take() {
            if let Some(p) = PREEMPTER.get() {
                p.vms.lock().unwrap().retain(|x| !Arc::ptr_eq(x, &old));
            }
        }
    });
}

/// This thread's hook yields, and its calls past the deadline where the coroutine could not yield.
pub fn counts() -> (u64, u64) {
    (YIELDS.with(|y| y.get()), REFUSED.with(|r| r.get()))
}

// STELLAR_PREEMPT_TRACE=1: where the hook found a coroutine that could not yield (one call in 64,
// every thread), the stack as `file:line < ...` with `[C]` for a C or Rust frame
static TRACE: OnceLock<bool> = OnceLock::new();
static REFUSALS: Mutex<Option<HashMap<String, u64>>> = Mutex::new(None);

unsafe fn where_(state: *mut ffi::lua_State) -> String {
    let mut parts = Vec::new();
    for level in 0..14 {
        let mut ar: ffi::lua_Debug = std::mem::zeroed();
        if ffi::lua_getstack(state, level, &mut ar) == 0 {
            break;
        }
        if ffi::lua_getinfo(state, c"Sl".as_ptr(), &mut ar) == 0 {
            break;
        }
        let what = if ar.what.is_null() { "" } else { std::ffi::CStr::from_ptr(ar.what).to_str().unwrap_or("") };
        if what == "C" {
            parts.push("[C]".to_string());
        } else {
            let src = std::ffi::CStr::from_ptr(ar.short_src.as_ptr()).to_string_lossy();
            let file = src.rsplit(['/', '\\']).next().unwrap_or(&src).to_string();
            parts.push(format!("{file}:{}", ar.currentline));
        }
    }
    parts.join(" < ")
}

// A yield more than this past its deadline (the slice's margin, so a slice that ends after its
// slot): the stack it came at and the cause (the preempter set the hook late, or the hook ran late:
// the coroutine was in C or Rust, in the collector or the JIT's compiler, or could not yield), every
// thread
const LATE: f64 = 0.0001;
static LATES: Mutex<Option<HashMap<String, (u64, f64)>>> = Mutex::new(None);

fn note_late(cause: &str, by: f64, at: String) {
    let mut m = LATES.lock().unwrap();
    let e = m.get_or_insert_with(HashMap::new).entry(format!("{cause}: {at}")).or_insert((0, 0.0));
    e.0 += 1;
    e.1 = e.1.max(by);
}

/// The yields more than 0.1 ms past their deadline, by cause and stack: their number and the latest
/// (seconds past), the most often first.
pub fn lates() -> Vec<(String, u64, f64)> {
    let mut v: Vec<(String, u64, f64)> =
        LATES.lock().unwrap().as_ref().map(|m| m.iter().map(|(k, (n, by))| (k.clone(), *n, *by)).collect()).unwrap_or_default();
    v.sort_by(|a, b| b.1.cmp(&a.1));
    v
}

/// STELLAR_PREEMPT_TRACE=1: the stacks where the hook could not yield, the most often first.
pub fn refusals() -> Vec<(String, u64)> {
    let mut v: Vec<(String, u64)> =
        REFUSALS.lock().unwrap().as_ref().map(|m| m.iter().map(|(k, n)| (k.clone(), *n)).collect()).unwrap_or_default();
    v.sort_by(|a, b| b.1.cmp(&a.1));
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    // A loop with no yield of its own, run in slices of 1 ms: the number of slices, the longest
    // slice, and whether it reached the result of a whole run.
    fn sliced(jit: bool) -> (usize, f64, bool) {
        let lua = crate::runtime::new_lua().unwrap();
        lua.load(if jit { "jit.on()" } else { "jit.off()" }).exec().unwrap();
        let code = "local s = 0 for i = 1, 2e7 do s = (s + i * 7) % 1000003 end return s";
        let whole: i64 = lua.load(code).call(()).unwrap();
        let th = lua.create_thread(lua.load(code).into_function().unwrap()).unwrap();
        let (mut slices, mut longest) = (0, 0.0f64);
        let result: i64 = loop {
            let t = clock();
            arm(&lua, t + 0.001);
            let r = th.resume::<Option<i64>>(());
            disarm(&lua);
            longest = longest.max(clock() - t);
            slices += 1;
            if th.status() != mlua::ThreadStatus::Resumable {
                break r.unwrap().unwrap();
            }
        };
        release();
        (slices, longest, result == whole)
    }

    #[test]
    fn preempts_interpreted_code() {
        let (slices, longest, same) = sliced(false);
        eprintln!("interpreted: {slices} slices, the longest {:.3} ms", longest * 1000.0);
        assert!(same);
        assert!(slices > 1, "the loop was not stopped");
        assert!(longest < 0.0015, "a slice of {:.3} ms", longest * 1000.0);
    }

    // table.sort in Lua (sim/src/table_sort.lua) leaves the elements in the order LuaJIT's C sort
    // does: random lists, ties, a comparator that is not a strict order, the default comparison
    #[test]
    fn table_sort_is_the_c_one() {
        // a plain state's table.sort is LuaJIT's C function
        let plain = unsafe { mlua::Lua::unsafe_new_with(mlua::StdLib::ALL, mlua::LuaOptions::new()) };
        let csort: mlua::Function = plain.load("return table.sort").eval().unwrap();
        let lsort: mlua::Function = plain.load(include_str!("table_sort.lua")).eval().unwrap();
        plain.globals().set("csort", csort).unwrap();
        plain.globals().set("lsort", lsort).unwrap();
        let same: bool = plain
            .load(
                r#"
                local seed = 12345
                local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return seed % n end
                local comps = {
                    false,
                    function(a, b) return a.k < b.k end,
                    function(a, b) return a.k <= b.k end,   -- not a strict order (C may raise too)
                    function(a, b) return (a.k % 7) > (b.k % 7) end,
                }
                for round = 1, 300 do
                    local n = rnd(200)
                    local base = {}
                    for i = 1, n do base[i] = { k = rnd(round % 3 == 0 and 5 or 1000), id = i } end
                    for c, comp in ipairs(comps) do
                        local a, b = {}, {}
                        for i = 1, n do
                            a[i] = comp and base[i] or base[i].k
                            b[i] = a[i]
                        end
                        local f = comp or nil
                        local oka, ea = pcall(csort, a, f)
                        local okb, eb = pcall(lsort, b, f)
                        if oka ~= okb then return false end
                        if oka then
                            for i = 1, n do if a[i] ~= b[i] then return false end end
                        end
                    end
                end
                return true
                "#,
            )
            .eval()
            .unwrap();
        assert!(same, "the Lua sort's order differs from the C one's");
    }

    #[test]
    fn preempts_compiled_code() {
        // the trace of the hot loop checks the hooks at each iteration (LUAJIT_ENABLE_CHECKHOOK)
        let (slices, longest, same) = sliced(true);
        eprintln!("compiled: {slices} slices, the longest {:.3} ms", longest * 1000.0);
        assert!(same);
        assert!(slices > 1, "the loop was not stopped");
        assert!(longest < 0.0015, "a slice of {:.3} ms", longest * 1000.0);
    }
}
