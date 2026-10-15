//! The simulation's threads in slices of a millisecond, every other millisecond unused
//! (docs/frame_timing.md). Time is cut into slots of `slot` seconds on the platform's clock
//! (`runtime::clock`, the same for every thread): the even slots are for work, the odd ones are
//! left unused. A thread works only inside a work slot, up to the slot's end less a margin (a phase
//! yields at `engine.slice`'s next check past that), then sleeps until the first work slot that
//! begins at least a slot after it stopped. So a slice is at most a slot, the gap after it at least
//! one, and every thread rests in the same slots.
//!
//! The cadence is set for the process (`set`): the simulation's own thread follows it where its
//! loop asks (`frametime::run_threaded`), and the worker pool's threads run each job as a coroutine
//! that follows it (`workers.rs`). Every thread that does records its slices (`register`), which
//! the report reads (`logs`).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::runtime::clock;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cadence {
    /// a slot, seconds (the work slots and the unused ones alike)
    pub slot: f64,
    /// a slice's deadline is its slot's end less this, seconds: the slack for the stretch between
    /// two of the engine's checks that runs past the deadline
    pub margin: f64,
}

static CURRENT: Mutex<Option<Cadence>> = Mutex::new(None);

/// The cadence the simulation's threads follow from now on (None: they run as they like).
pub fn set(c: Option<Cadence>) {
    *CURRENT.lock().unwrap() = c;
}

pub fn current() -> Option<Cadence> {
    *CURRENT.lock().unwrap()
}

impl Cadence {
    fn period(&self) -> f64 {
        2.0 * self.slot
    }

    /// The start of the work slot that holds `t`, or None when `t` is in an unused slot.
    pub fn work_slot(&self, t: f64) -> Option<f64> {
        let p = self.period();
        let s = (t / p).floor() * p;
        if t - s < self.slot {
            Some(s)
        } else {
            None
        }
    }

    /// The slot's end and the deadline of a slice that would begin at `t`: None unless `t` is in a
    /// work slot with time left before the deadline.
    pub fn slice_at(&self, t: f64) -> Option<(f64, f64)> {
        let s = self.work_slot(t)?;
        let end = s + self.slot;
        let deadline = end - self.margin;
        if t < deadline {
            Some((end, deadline))
        } else {
            None
        }
    }

    /// The start of the first work slot that begins at least a slot after `t` (when a slice that
    /// stopped at `t` may begin the next).
    pub fn next_start(&self, t: f64) -> f64 {
        let p = self.period();
        let mut s = (t / p).floor() * p;
        loop {
            s += p;
            if s - t >= self.slot * (1.0 - 1e-9) {
                return s;
            }
        }
    }

    /// The start of the first work slot at or after `t`.
    pub fn first_start(&self, t: f64) -> f64 {
        let p = self.period();
        let s = (t / p).floor() * p;
        if t <= s {
            s
        } else {
            s + p
        }
    }

    /// Waits (asleep) until a slice may begin, no earlier than `earliest`; the slice's slot end and
    /// deadline.
    pub fn wait_for_slice(&self, earliest: f64) -> (f64, f64) {
        loop {
            let t = clock();
            if t >= earliest {
                if let Some(x) = self.slice_at(t) {
                    return x;
                }
            }
            sleep_until(self.first_start(t.max(earliest)).max(earliest));
        }
    }
}

/// Sleeps until `t` on the platform's clock (the thread is off the CPU; it wakes a few tens of
/// microseconds late at most with fine timers).
pub fn sleep_until(t: f64) {
    loop {
        let now = clock();
        if now >= t {
            return;
        }
        std::thread::sleep(Duration::from_secs_f64(t - now));
    }
}

/// The calling thread's timer slack at a nanosecond (Linux: 50 us by default, by which a sleep may
/// wake late), so that a slice starts close to its slot's start.
pub fn fine_timers() {
    #[cfg(target_os = "linux")]
    unsafe {
        extern "C" {
            fn prctl(option: i32, ...) -> i32;
        }
        const PR_SET_TIMERSLACK: i32 = 29;
        prctl(PR_SET_TIMERSLACK, 1u64);
    }
}

// The physical cores, each as its logical CPUs (its SMT siblings), in order, CPU 0's core left out
// (it takes most of the interrupts); Linux only, none elsewhere.
fn cores() -> &'static [Vec<usize>] {
    static CORES: std::sync::OnceLock<Vec<Vec<usize>>> = std::sync::OnceLock::new();
    CORES.get_or_init(|| {
        let mut index = std::collections::HashMap::new();
        let mut out: Vec<Vec<usize>> = Vec::new();
        for cpu in 0..1024usize {
            let dir = format!("/sys/devices/system/cpu/cpu{cpu}/topology");
            let read = |f: &str| std::fs::read_to_string(format!("{dir}/{f}")).ok().map(|s| s.trim().to_string());
            let (Some(pkg), Some(core)) = (read("physical_package_id"), read("core_id")) else {
                if cpu > 0 && !std::path::Path::new(&dir).exists() {
                    break;
                }
                continue;
            };
            let i = *index.entry((pkg, core)).or_insert_with(|| {
                out.push(Vec::new());
                out.len() - 1
            });
            out[i].push(cpu);
        }
        if !out.is_empty() {
            out.remove(0);
        }
        out
    })
}

/// This thread pinned to a physical core of its own (its logical CPUs, so that it can still run on
/// the other when something else holds one), the `slot`th of those [`cores`] finds (the preempter
/// 0, the simulation's thread 1, worker i 2 + i), when there is one: the system had at times put two
/// of the simulation's threads on one CPU, and the one waiting lost a whole scheduler slice (a slice
/// 2.6 ms late); pinned to one logical CPU, a thread woke late when the system ran something there
/// (waits back up to 3.5 ms late). Linux only; STELLAR_PIN=off leaves the threads free.
pub fn pin(slot: usize) {
    if std::env::var("STELLAR_PIN").as_deref() == Ok("off") {
        return;
    }
    let Some(cpus) = cores().get(slot) else { return };
    #[cfg(target_os = "linux")]
    unsafe {
        extern "C" {
            fn sched_setaffinity(pid: i32, size: usize, mask: *const u64) -> i32;
        }
        let mut mask = [0u64; 16];
        for &cpu in cpus {
            mask[cpu / 64] |= 1 << (cpu % 64);
        }
        sched_setaffinity(0, std::mem::size_of_val(&mask), mask.as_ptr());
    }
    #[cfg(not(target_os = "linux"))]
    let _ = cpus;
}

/// The render thread pinned to the last of the cores [`pin`] uses, away from the simulation's: left
/// free, the system put it at times on the core of a pinned simulation thread.
pub fn pin_render() {
    let n = cores().len();
    if n > 0 {
        pin(n - 1);
    }
}

/// This thread free to run on any CPU again (it was pinned with [`pin`]).
pub fn unpin() {
    #[cfg(target_os = "linux")]
    unsafe {
        extern "C" {
            fn sched_setaffinity(pid: i32, size: usize, mask: *const u64) -> i32;
        }
        let mask = [u64::MAX; 16];
        sched_setaffinity(0, std::mem::size_of_val(&mask), mask.as_ptr());
    }
}

/// A thread's slices: their lengths, the gaps between them, those that ended after their slot.
#[derive(Clone, Debug, Default)]
pub struct Slices {
    pub thread: String,
    pub lengths: Vec<f64>,
    pub gaps: Vec<f64>,
    /// slices that ended after their slot's end
    pub late: usize,
    /// the busy time and the time from the first slice's start to the last one's end, seconds
    pub busy: f64,
    pub first: Option<f64>,
    pub last_end: Option<f64>,
}

impl Slices {
    pub fn record(&mut self, start: f64, end: f64, slot_end: f64) {
        self.lengths.push(end - start);
        if let Some(e) = self.last_end {
            self.gaps.push(start - e);
        }
        if end > slot_end {
            self.late += 1;
        }
        self.busy += end - start;
        self.first.get_or_insert(start);
        self.last_end = Some(end);
    }

    fn clear(&mut self) {
        let thread = std::mem::take(&mut self.thread);
        *self = Slices { thread, ..Default::default() };
    }
}

static LOGS: Mutex<Vec<Arc<Mutex<Slices>>>> = Mutex::new(Vec::new());

/// A thread's record, kept for the report.
pub fn register(thread: &str) -> Arc<Mutex<Slices>> {
    let s = Arc::new(Mutex::new(Slices { thread: thread.to_string(), ..Default::default() }));
    LOGS.lock().unwrap().push(s.clone());
    s
}

/// Every thread's record as it is now.
pub fn logs() -> Vec<Slices> {
    LOGS.lock().unwrap().iter().map(|s| s.lock().unwrap().clone()).collect()
}

/// Every thread's record emptied (a run starts).
pub fn clear_logs() {
    for s in LOGS.lock().unwrap().iter() {
        s.lock().unwrap().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots() {
        let c = Cadence { slot: 0.001, margin: 0.0002 };
        assert_eq!(c.work_slot(0.0105), Some(0.010));
        assert_eq!(c.work_slot(0.0115), None);
        let (end, deadline) = c.slice_at(0.0101).unwrap();
        assert!((end - 0.011).abs() < 1e-12 && (deadline - 0.0108).abs() < 1e-12);
        assert!(c.slice_at(0.0109).is_none());
        // a slice that stopped in its slot: the next work slot; one that ran into the unused slot:
        // the one after
        assert!((c.next_start(0.0107) - 0.012).abs() < 1e-12);
        assert!((c.next_start(0.0112) - 0.014).abs() < 1e-12);
        assert!((c.first_start(0.0112) - 0.012).abs() < 1e-12);
    }
}
