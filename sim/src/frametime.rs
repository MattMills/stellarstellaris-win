//! The simulation inside a rendered game's frames, timed (docs/frame_timing.md).
//!
//! A game that renders 120 frames a second has 8.33 ms a frame. The simulation can share that time
//! in two ways, and this module runs each in a frame loop and measures it:
//!
//! - **inline** ([`run_inline`]): on the render thread, in what each frame leaves after its render
//!   work. The simulation runs [`Unit`]s (one phase each, which cannot be cut shorter) while the
//!   frame has time for the next one by its running estimate, and goes on with the same tick in the
//!   next frame. A unit longer than a whole frame's room runs in a frame of its own and overruns it.
//! - **thread** ([`run_threaded`]): on a thread of its own, with its own Lua state, which the render
//!   thread only reads what it publishes from. The frames must keep their time, and the thread the
//!   game's pace.
//!
//! In both the render thread is the game's clock, as `CInGameIdler::CheckTick` is: it posts two
//! ticks every `gGameSpeedTurnTimes[speed]` seconds (0.3, 0.15, 0.075, 0.04 s; at the fastest, two
//! every frame), and the simulation runs the ticks posted (docs/render.md section 12). The render
//! work is a busy wait of `render_ms` a frame (the renderer's own cost is measured on its own,
//! docs/render.md); the end of a frame waits for its deadline, as vsync does, and a frame that ends
//! after its deadline misses that deadline and every one it passes.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::scheduler::{Simulation, Unit};
use crate::{save, Runtime};

/// `gGameSpeedTurnTimes`: the seconds between two posts of two ticks, by speed (1 Slowest to 5
/// Fastest); 0 posts two every frame.
pub const TURN_TIMES: [f64; 5] = [0.3, 0.15, 0.075, 0.04, 0.0];

/// The speeds' names (GAME_SPEED_1 .. GAME_SPEED_5).
pub const SPEED_NAMES: [&str; 5] = ["Slowest", "Slow", "Normal", "Fast", "Fastest"];

#[derive(Clone, Debug)]
pub struct Config {
    /// frames a second the game renders
    pub fps: f64,
    /// the render thread's own work in a frame, ms (a busy wait)
    pub render_ms: f64,
    /// inline: what the simulation leaves free at the end of a frame, ms (its pieces stop at the
    /// frame's end less this: the slack for a stretch between two of its checks that runs past)
    pub margin_ms: f64,
    /// the game's speed, 1 (Slowest) to 5 (Fastest)
    pub speed: u8,
    /// game days to run
    pub days: u64,
    /// thread: seconds of frames without the simulation first, to compare with
    pub baseline_s: f64,
    /// sliced: a slice, ms; the simulation's threads work in every other slot of this length
    pub slice_ms: f64,
    /// sliced: a slice's deadline is its slot's end less this, ms
    pub slice_margin_ms: f64,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            fps: 120.0,
            render_ms: 4.0,
            margin_ms: 1.0,
            speed: 3,
            days: 35,
            baseline_s: 3.0,
            slice_ms: 1.0,
            slice_margin_ms: 0.1,
        }
    }
}

fn env<T: std::str::FromStr>(name: &str) -> Option<T> {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok())
}

impl Config {
    /// The defaults (120 FPS, 4 ms of render work, a 1 ms margin, Normal speed, 35 days, a 3 s
    /// baseline, 1 ms slices with a 0.1 ms margin), each overridden by its variable:
    /// `STELLAR_FRAME_FPS`, `STELLAR_FRAME_RENDER_MS`, `STELLAR_FRAME_MARGIN_MS`,
    /// `STELLAR_FRAME_SPEED`, `STELLAR_FRAME_DAYS`, `STELLAR_FRAME_BASELINE_S`,
    /// `STELLAR_FRAME_SLICE_MS`, `STELLAR_FRAME_SLICE_MARGIN_MS`.
    pub fn from_env() -> Config {
        let d = Config::default();
        Config {
            fps: env("STELLAR_FRAME_FPS").unwrap_or(d.fps),
            render_ms: env("STELLAR_FRAME_RENDER_MS").unwrap_or(d.render_ms),
            margin_ms: env("STELLAR_FRAME_MARGIN_MS").unwrap_or(d.margin_ms),
            speed: env::<u8>("STELLAR_FRAME_SPEED").unwrap_or(d.speed).clamp(1, 5),
            days: env("STELLAR_FRAME_DAYS").unwrap_or(d.days),
            baseline_s: env("STELLAR_FRAME_BASELINE_S").unwrap_or(d.baseline_s),
            slice_ms: env("STELLAR_FRAME_SLICE_MS").unwrap_or(d.slice_ms),
            slice_margin_ms: env("STELLAR_FRAME_SLICE_MARGIN_MS").unwrap_or(d.slice_margin_ms),
        }
    }

    /// sliced: the cadence the simulation's threads follow.
    pub fn cadence(&self) -> crate::cadence::Cadence {
        crate::cadence::Cadence { slot: self.slice_ms / 1000.0, margin: self.slice_margin_ms / 1000.0 }
    }

    /// A frame's time, seconds.
    pub fn budget(&self) -> f64 {
        1.0 / self.fps
    }

    /// What a frame leaves the inline simulation after the render work and the margin, seconds.
    pub fn room(&self) -> f64 {
        (self.budget() - (self.render_ms + self.margin_ms) / 1000.0).max(0.0)
    }

    pub fn turn(&self) -> f64 {
        TURN_TIMES[(self.speed.clamp(1, 5) - 1) as usize]
    }

    /// The game days a second the speed asks for: ten ticks a day, two a turn (or a frame).
    pub fn nominal_days_per_s(&self) -> f64 {
        let turn = self.turn();
        if turn <= 0.0 {
            2.0 * self.fps / 10.0
        } else {
            2.0 / turn / 10.0
        }
    }

    pub fn speed_name(&self) -> &'static str {
        SPEED_NAMES[(self.speed.clamp(1, 5) - 1) as usize]
    }
}

/// The game's clock on the render thread: the ticks posted so far.
struct GameClock {
    turn: f64,
    acc: f64,
    due: u64,
}

impl GameClock {
    fn new(turn: f64) -> GameClock {
        GameClock { turn, acc: 0.0, due: 0 }
    }

    /// A frame `dt` seconds after the last one: `CheckTick` posts two ticks for each turn time
    /// passed, or two every frame at the fastest speed.
    fn frame(&mut self, dt: f64) {
        if self.turn <= 0.0 {
            self.due += 2;
            return;
        }
        self.acc += dt;
        while self.acc >= self.turn {
            self.acc -= self.turn;
            self.due += 2;
        }
    }
}

fn busy(ms: f64) {
    let end = Instant::now() + Duration::from_secs_f64(ms.max(0.0) / 1000.0);
    while Instant::now() < end {
        std::hint::spin_loop();
    }
}

/// Sleeps to within a millisecond of `t`, then spins (the OS's sleeps are coarse).
fn wait_until(t: Instant) {
    loop {
        let now = Instant::now();
        if now >= t {
            return;
        }
        let left = t - now;
        if left > Duration::from_micros(1500) {
            std::thread::sleep(left - Duration::from_millis(1));
        } else {
            std::hint::spin_loop();
        }
    }
}

/// Frames at a fixed rate, as vsync shows them.
struct Pacer {
    budget: Duration,
    next: Instant,
    missed: u64,
}

impl Pacer {
    fn new(budget: Duration) -> Pacer {
        Pacer { budget, next: Instant::now() + budget, missed: 0 }
    }

    /// The frame's deadline.
    fn deadline(&self) -> Instant {
        self.next
    }

    /// The frame ends at `end`: it is shown at its deadline, or, late, at the first deadline after
    /// `end` (every deadline before that missed); the next frame starts then.
    fn present(&mut self, end: Instant) {
        if end > self.next {
            let late = (end - self.next).as_nanos();
            let k = (late / self.budget.as_nanos().max(1)) as u32 + 1;
            self.missed += k as u64;
            self.next += self.budget * k;
        }
        wait_until(self.next);
        self.next += self.budget;
    }
}

/// Frames until `frame` says there are no more: each the render work, then `frame(dt, deadline)`
/// (what else the render thread does in it: `dt` the seconds since the last frame began), then the
/// wait for its deadline. The frames' times (from their start to the end of their work, seconds)
/// and the deadlines missed.
fn frame_loop(cfg: &Config, mut frame: impl FnMut(f64, Instant) -> bool) -> (Vec<f64>, u64) {
    let mut pacer = Pacer::new(Duration::from_secs_f64(cfg.budget()));
    let mut times = Vec::new();
    let mut last = Instant::now();
    loop {
        let f0 = Instant::now();
        let dt = (f0 - last).as_secs_f64();
        last = f0;
        busy(cfg.render_ms);
        let more = frame(dt, pacer.deadline());
        let f1 = Instant::now();
        times.push((f1 - f0).as_secs_f64());
        pacer.present(f1);
        if !more {
            break;
        }
    }
    (times, pacer.missed)
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

fn sorted(v: &[f64]) -> Vec<f64> {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    s
}

/// A run's frames.
#[derive(Clone, Debug, Default)]
pub struct FrameStats {
    pub frames: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub p99_ms: f64,
    pub max_ms: f64,
    /// frames whose work took longer than a frame
    pub over_budget: usize,
    /// the late frames by how late: under 0.5 ms, 0.5 to 1, 1 to 2, 2 to 5, 5 or more
    pub late_by: [usize; 5],
    /// the deadlines (vsyncs) the late frames missed
    pub missed: u64,
}

impl FrameStats {
    fn of(times: &[f64], budget: f64, missed: u64) -> FrameStats {
        let s = sorted(times);
        let mut late_by = [0usize; 5];
        for &t in s.iter().filter(|&&t| t > budget) {
            let ms = (t - budget) * 1000.0;
            late_by[if ms < 0.5 { 0 } else if ms < 1.0 { 1 } else if ms < 2.0 { 2 } else if ms < 5.0 { 3 } else { 4 }] += 1;
        }
        FrameStats {
            frames: s.len(),
            p50_ms: percentile(&s, 0.5) * 1000.0,
            p95_ms: percentile(&s, 0.95) * 1000.0,
            p99_ms: percentile(&s, 0.99) * 1000.0,
            max_ms: s.last().copied().unwrap_or(0.0) * 1000.0,
            over_budget: s.iter().filter(|&&t| t > budget).count(),
            late_by,
            missed,
        }
    }

    fn text(&self, budget_ms: f64) -> String {
        let l = &self.late_by;
        format!(
            "{} frames, ms p50 {:.2} p95 {:.2} p99 {:.2} max {:.1}; over {budget_ms:.2} ms: {} ({:.2}%; late by <0.5 ms {}, 0.5-1 {}, 1-2 {}, 2-5 {}, 5+ {}), deadlines missed: {}",
            self.frames,
            self.p50_ms,
            self.p95_ms,
            self.p99_ms,
            self.max_ms,
            self.over_budget,
            100.0 * self.over_budget as f64 / self.frames.max(1) as f64,
            l[0],
            l[1],
            l[2],
            l[3],
            l[4],
            self.missed
        )
    }
}

/// The time a unit (a phase) took, over a run.
#[derive(Clone, Debug, Default)]
pub struct UnitStats {
    pub label: String,
    /// the units finished
    pub calls: u64,
    pub total_ms: f64,
    /// the longest unit, all its pieces together
    pub max_ms: f64,
    /// the pieces the units ran in (inline: one a frame at most), and the longest: what a frame
    /// had to hold of it at once
    pub pieces: u64,
    pub max_piece_ms: f64,
    /// inline: the frames that ran past their deadline in this unit
    pub overruns: u64,
}

#[derive(Default)]
struct Units {
    stats: HashMap<Unit, UnitStats>,
    /// the unit in progress: its time so far, seconds
    running: HashMap<Unit, f64>,
}

impl Units {
    /// A piece of a unit: `secs` long, the unit `done` or not.
    fn piece(&mut self, u: Unit, secs: f64, done: bool, overran: bool) {
        let s = self.stats.entry(u).or_insert_with(|| UnitStats { label: u.label(), ..Default::default() });
        s.pieces += 1;
        s.total_ms += secs * 1000.0;
        s.max_piece_ms = s.max_piece_ms.max(secs * 1000.0);
        s.overruns += overran as u64;
        let so_far = self.running.entry(u).or_insert(0.0);
        *so_far += secs;
        if done {
            s.calls += 1;
            s.max_ms = s.max_ms.max(*so_far * 1000.0);
            self.running.remove(&u);
        }
    }

    /// The longest piece first.
    fn list(self) -> Vec<UnitStats> {
        let mut v: Vec<UnitStats> = self.stats.into_values().collect();
        v.sort_by(|a, b| b.max_piece_ms.partial_cmp(&a.max_piece_ms).unwrap_or(std::cmp::Ordering::Equal));
        v
    }
}

/// sliced: one of the simulation's threads, its slices.
#[derive(Clone, Debug, Default)]
pub struct SliceStats {
    pub thread: String,
    pub slices: usize,
    pub p50_ms: f64,
    pub p99_ms: f64,
    pub p999_ms: f64,
    pub max_ms: f64,
    /// slices longer than a slot
    pub over: usize,
    /// slices that ended after their slot's end
    pub late: usize,
    /// the shortest gap between two slices, ms
    pub min_gap_ms: f64,
    /// the share of its time from its first slice to its last that the thread worked
    pub busy: f64,
}

impl SliceStats {
    fn of(s: &crate::cadence::Slices, slot: f64) -> SliceStats {
        let l = sorted(&s.lengths);
        let span = match (s.first, s.last_end) {
            (Some(a), Some(b)) if b > a => b - a,
            _ => 0.0,
        };
        SliceStats {
            thread: s.thread.clone(),
            slices: l.len(),
            p50_ms: percentile(&l, 0.5) * 1000.0,
            p99_ms: percentile(&l, 0.99) * 1000.0,
            p999_ms: percentile(&l, 0.999) * 1000.0,
            max_ms: l.last().copied().unwrap_or(0.0) * 1000.0,
            over: l.iter().filter(|&&x| x > slot).count(),
            late: s.late,
            min_gap_ms: s.gaps.iter().copied().fold(f64::INFINITY, f64::min) * 1000.0,
            busy: if span > 0.0 { s.busy / span } else { 0.0 },
        }
    }

    fn text(&self, slot_ms: f64) -> String {
        format!(
            "  {:<14} {:>7} slices, ms p50 {:.3} p99 {:.3} p99.9 {:.3} max {:.2}; longer than {slot_ms:.2} ms: {} ({:.3}%); the shortest gap {:.3} ms; busy {:.0}%\n",
            self.thread,
            self.slices,
            self.p50_ms,
            self.p99_ms,
            self.p999_ms,
            self.max_ms,
            self.over,
            100.0 * self.over as f64 / self.slices.max(1) as f64,
            if self.min_gap_ms.is_finite() { self.min_gap_ms } else { 0.0 },
            100.0 * self.busy
        )
    }
}

/// What a run measured.
#[derive(Clone, Debug, Default)]
pub struct Report {
    /// "inline", "thread" or "sliced"
    pub mode: &'static str,
    pub config: Config,
    /// game days run
    pub days: f64,
    /// seconds from the first frame of the run to its last tick
    pub wall_s: f64,
    pub nominal_days_per_s: f64,
    pub achieved_days_per_s: f64,
    /// the frames while the simulation ran
    pub frames: FrameStats,
    /// thread: frames with no simulation, and while the thread loaded the save
    pub baseline: Option<FrameStats>,
    pub loading: Option<FrameStats>,
    /// inline: the simulation's time in a frame, ms: p50, p99, max
    pub sim_in_frame: Option<(f64, f64, f64)>,
    /// inline: the units that yielded at a frame's deadline and went on in a later frame
    pub yielded: u64,
    /// engine.slice's report: the longest gaps between the engine's checks
    pub slices: String,
    /// ticks posted and not run yet, at the end of a frame: p50, p99, max, and at the last frame
    pub backlog: (u64, u64, u64, u64),
    /// thread: the render thread's longest wait for the published state, ms
    pub lock_wait_max_ms: f64,
    /// the units, the longest call first
    pub units: Vec<UnitStats>,
    pub load_s: f64,
    /// the end state: date, ticks, the generator's position, a hash of the world as saved
    pub fingerprint: String,
    pub error: Option<String>,
    /// sliced: each of the simulation's threads, its slices
    pub threads: Vec<SliceStats>,
    /// sliced: the VM's yields (the count hook's) and its looks past a deadline where it could not
    pub vm_yields: (u64, u64),
    /// sliced, STELLAR_PREEMPT_TRACE=1: the stacks where the hook could not yield, sampled
    pub vm_refusals: Vec<(String, u64)>,
    /// sliced: the hook's yields more than 0.1 ms past the deadline, by cause and stack (their
    /// number, the latest in seconds past)
    pub vm_lates: Vec<(String, u64, f64)>,
    /// sliced: the hooks the preempter set, by how late (within 10, 25, 50, 100 µs, later), and
    /// the latest (seconds)
    pub vm_armed: ([u64; 5], f64),
    /// sliced: per thread, the steps of its VM no hook can stop, by kind
    /// ([`crate::preempt::STALL_KINDS`]): seconds in all, the longest, the steps over 0.1 ms
    pub stalls: Vec<(String, [[f64; 3]; 18])>,
    /// sliced: the worker pool's waits back more than 0.1 ms late, and the latest (seconds)
    pub poll_late: (u64, f64),
}

impl Report {
    pub fn budget_ms(&self) -> f64 {
        self.config.budget() * 1000.0
    }

    /// sliced: every thread's slices within a slot (at least 999 in 1,000, none over two slots),
    /// and every gap at least a slot.
    pub fn slices_fit(&self) -> bool {
        let slot = self.config.slice_ms;
        self.error.is_none()
            && !self.threads.is_empty()
            && self.threads.iter().all(|t| {
                t.over * 1000 <= t.slices && t.max_ms <= 2.0 * slot && (t.slices < 2 || t.min_gap_ms >= slot * 0.999)
            })
    }

    /// The game days a second ran are at least 95% of what the speed asks for.
    pub fn keeps_pace(&self) -> bool {
        self.error.is_none() && self.achieved_days_per_s >= 0.95 * self.nominal_days_per_s
    }

    /// The 99th percentile within the frame's time, and few frames over it. Thread: at most one in a
    /// thousand (the OS's own hiccups; the baseline shows them). Inline: at most one in two hundred,
    /// and none over two frames' time (no frame dropped to half the rate): what is left over the
    /// time are single stretches between two of the simulation's checks that the runtime does not
    /// cut (a block's first compilation, the collector's atomic step, pages first touched;
    /// docs/frame_timing.md).
    pub fn frames_fit(&self) -> bool {
        if self.error.is_some() || self.frames.frames == 0 {
            return false;
        }
        let p99 = self.frames.p99_ms <= self.budget_ms();
        match self.mode {
            "inline" => p99 && self.frames.over_budget * 200 <= self.frames.frames && self.frames.max_ms <= 2.0 * self.budget_ms(),
            _ => p99 && self.frames.over_budget * 1000 <= self.frames.frames,
        }
    }

    /// The units whose longest piece is longer than a frame's room for the simulation.
    pub fn units_over_room(&self) -> Vec<&UnitStats> {
        let room = self.config.room() * 1000.0;
        self.units.iter().filter(|u| u.max_piece_ms > room).collect()
    }

    pub fn text(&self) -> String {
        let c = &self.config;
        let budget = self.budget_ms();
        let yes = |b: bool| if b { "yes" } else { "NO" };
        let mut out = format!(
            "frame timing, {}: speed {} ({}: {:.2} game days a second), {} FPS ({budget:.2} ms a frame), render {:.2} ms",
            self.mode,
            c.speed,
            c.speed_name(),
            self.nominal_days_per_s,
            c.fps,
            c.render_ms
        );
        if self.mode == "inline" {
            out += &format!(" + margin {:.2} ms: {:.2} ms a frame for the simulation", c.margin_ms, c.room() * 1000.0);
        }
        if self.mode == "sliced" {
            out += &format!(
                "; the simulation's threads in {:.2} ms slices, every other {:.2} ms unused (deadline {:.2} ms before a slot's end, the VM stops the Lua code)",
                c.slice_ms, c.slice_ms, c.slice_margin_ms
            );
        }
        out += "\n";
        if let Some(e) = &self.error {
            out += &format!("  error: {e}\n");
            return out;
        }
        out += &format!("  load: {:.1} s{}\n", self.load_s, if self.mode == "inline" { " (on the render thread, before the frames)" } else { " (on the thread)" });
        out += &format!(
            "  {:.1} days in {:.1} s: {:.2} game days a second, {:.0}% of the speed's {:.2}; keeps pace: {}\n",
            self.days,
            self.wall_s,
            self.achieved_days_per_s,
            100.0 * self.achieved_days_per_s / self.nominal_days_per_s.max(1e-9),
            self.nominal_days_per_s,
            yes(self.keeps_pace())
        );
        if let Some(b) = &self.baseline {
            out += &format!("  frames, no simulation:   {}\n", b.text(budget));
        }
        if let Some(l) = &self.loading {
            out += &format!("  frames, while it loads:  {}\n", l.text(budget));
        }
        out += &format!("  frames, while it runs:   {}; frames fit: {}\n", self.frames.text(budget), yes(self.frames_fit()));
        if let Some((p50, p99, max)) = self.sim_in_frame {
            out += &format!(
                "  the simulation in a frame: ms p50 {p50:.2} p99 {p99:.2} max {max:.1}; units that yielded at a frame's deadline and went on later: {}\n",
                self.yielded
            );
        }
        let (b50, b99, bmax, bend) = self.backlog;
        out += &format!("  ticks posted and not run at a frame's end: p50 {b50} p99 {b99} max {bmax}, at the last {bend}\n");
        if self.mode != "inline" {
            out += &format!("  the render thread's longest wait for the published state: {:.3} ms\n", self.lock_wait_max_ms);
        }
        if !self.threads.is_empty() {
            out += &format!(
                "  the simulation's threads, their slices (VM yields {}, looks past a deadline that could not yield {}); slices fit: {}\n",
                self.vm_yields.0,
                self.vm_yields.1,
                yes(self.slices_fit())
            );
            for t in &self.threads {
                out += &t.text(c.slice_ms);
            }
            for (w, n) in self.vm_refusals.iter().take(15) {
                out += &format!("    could not yield ({n} samples): {w}\n");
            }
            let (a, amax) = self.vm_armed;
            out += &format!(
                "    the preempter's hooks set within 10 µs of the deadline {}, 25 µs {}, 50 µs {}, 100 µs {}, later {}; the latest {:.3} ms\n",
                a[0],
                a[1],
                a[2],
                a[3],
                a[4],
                amax * 1000.0
            );
            for (thread, s) in &self.stalls {
                out += &format!("    {thread}, its steps no hook can stop (in all, the longest, the steps over 0.1 ms):\n");
                for (k, v) in s.iter().enumerate() {
                    if (12..17).contains(&k) {
                        if v[2] > 0.0 {
                            out += &format!(
                                "      {:<32} {:>6} traces, mean {:.3} ms, the longest {:.3} ms\n",
                                crate::preempt::STALL_KINDS[k],
                                v[2],
                                v[0] / v[2] * 1000.0,
                                v[1] * 1000.0
                            );
                        }
                    } else if k >= 10 {
                        out += &format!("      {:<32} {:>9}\n", crate::preempt::STALL_KINDS[k], v[0]);
                    } else if v[0] > 0.0 {
                        out += &format!(
                            "      {:<32} {:>9.1} ms  {:>7.3} ms  {:>6}\n",
                            crate::preempt::STALL_KINDS[k],
                            v[0] * 1000.0,
                            v[1] * 1000.0,
                            v[2]
                        );
                    }
                }
            }
            let (pl, platest) = self.poll_late;
            out += &format!(
                "    the worker pool's waits back more than 0.1 ms late: {pl}, the latest {:.3} ms\n",
                platest * 1000.0
            );
            let late: u64 = self.vm_lates.iter().map(|l| l.1).sum();
            out += &format!("    pieces and yields more than 0.1 ms past the deadline: {late}\n");
            for (w, n, by) in self.vm_lates.iter().take(24) {
                out += &format!("      {n:>5}, at most {:.3} ms past: {w}\n", by * 1000.0);
            }
        }
        let room = c.room() * 1000.0;
        let over = self.units_over_room();
        out += &format!(
            "  units, the longest piece first ({} of {} with a piece longer than a frame's {room:.2} ms of room):\n",
            over.len(),
            self.units.len()
        );
        for u in self.units.iter().take(16) {
            out += &format!(
                "    {:<34} {:>6} calls  mean {:>9.3} ms  max {:>9.3} ms  {:>6} pieces, longest {:>8.3} ms{}{}\n",
                u.label,
                u.calls,
                u.total_ms / u.calls.max(1) as f64,
                u.max_ms,
                u.pieces,
                u.max_piece_ms,
                if u.max_piece_ms > room { "  over the room" } else { "" },
                if u.overruns > 0 { format!("  overran {} frames", u.overruns) } else { String::new() }
            );
        }
        if !self.slices.is_empty() {
            for line in self.slices.lines() {
                out += &format!("  {line}\n");
            }
        }
        out += &format!("  end: {}\n", self.fingerprint);
        out
    }
}

fn hash(bytes: &[u8]) -> u64 {
    // FNV-1a: the same everywhere, so two builds' runs compare
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// The simulation from a save, as `examples/run` makes it: the save's generator state and its tick
/// within the day.
pub fn load(game_dir: &str, save_path: &str) -> Result<Simulation, String> {
    let gamestate = save::read_gamestate(save_path)?;
    let date = save::date_of(&gamestate).ok_or("the save has no date")?;
    let tick = save::tick_of(&gamestate).unwrap_or(0);
    let (seed, position) = save::random_of(&gamestate).unwrap_or((0, 0));
    let runtime = Runtime::new(date, seed).map_err(|e| format!("the Lua runtime: {e}"))?;
    runtime.rng.borrow_mut().position = position;
    runtime.load(game_dir, Some(&gamestate), None).map_err(|e| format!("load: {e}"))?;
    let mut sim = Simulation::new(runtime);
    sim.set_tick_count(tick);
    Ok(sim)
}

/// What a run ends with: the date, the ticks run, the generator's position, the phase errors and a
/// hash of the world as a save writes it. Two runs of the same days from the same save end alike.
pub fn fingerprint(sim: &Simulation) -> String {
    end_state(sim, None)
}

/// [`fingerprint`], and with `STELLAR_FRAME_SAVE_DIR` set the world's text written there as
/// `<name>.gamestate` (to compare two runs' ends).
fn end_state(sim: &Simulation, name: Option<String>) -> String {
    let position = sim.runtime.rng.borrow().position;
    let world = match sim.runtime.save_text() {
        Ok((text, _)) => {
            if let (Some(dir), Some(name)) = (std::env::var_os("STELLAR_FRAME_SAVE_DIR"), name) {
                let path = std::path::Path::new(&dir).join(format!("{name}.gamestate"));
                if let Err(e) = std::fs::write(&path, &text) {
                    eprintln!("frame timing: {}: {e}", path.display());
                }
            }
            format!("{:016x}", hash(text.as_bytes()))
        }
        Err(e) => format!("(not saved: {e})"),
    };
    format!("{:?}, {} ticks, generator at {position}, {} phase errors, world {world}", sim.date(), sim.ticks, sim.errors.len())
}

fn backlog(v: &[u64], last: u64) -> (u64, u64, u64, u64) {
    let mut s = v.to_vec();
    s.sort_unstable();
    let p = |q: f64| if s.is_empty() { 0 } else { s[((s.len() - 1) as f64 * q).round() as usize] };
    (p(0.5), p(0.99), s.last().copied().unwrap_or(0), last)
}

/// The simulation on the render thread, in what each frame leaves: `cfg.days` days from where
/// `sim` is, at `cfg.speed`. After the render work it runs units in pieces up to the frame's
/// deadline less the margin (`Simulation::step_until`): a phase past that deadline yields at the
/// engine's next check and goes on in the next frame.
pub fn run_inline(sim: &mut Simulation, cfg: &Config) -> Report {
    let margin = Duration::from_secs_f64(cfg.margin_ms / 1000.0);
    let target = cfg.days * 10;
    let start_ticks = sim.ticks;
    let mut clock = GameClock::new(cfg.turn());
    let mut units = Units::default();
    let (mut in_frame, mut backlogs) = (Vec::new(), Vec::new());
    let mut yielded = 0u64;
    let _ = sim.runtime.eval::<()>("require('engine.slice').reset()");
    let start = Instant::now();
    let mut end = start;
    let (times, missed) = frame_loop(cfg, |dt, deadline| {
        clock.frame(dt);
        let soft = deadline.checked_sub(margin).unwrap_or(deadline);
        let soft_clock = crate::runtime::clock_at(soft);
        sim.runtime.set_frame_end(crate::runtime::clock_at(deadline));
        let (mut worked, mut charged) = (0.0, false);
        loop {
            let done = sim.ticks - start_ticks;
            if !sim.mid_tick() && (done >= clock.due || done >= target) {
                break;
            }
            if Instant::now() >= soft {
                break;
            }
            let u = sim.upcoming();
            let t = Instant::now();
            let step = sim.step_until(soft_clock);
            let now = Instant::now();
            let secs = (now - t).as_secs_f64();
            worked += secs;
            let overran = now > deadline && !charged;
            charged |= overran;
            units.piece(u, secs, step.done, overran);
            if !step.done {
                yielded += 1;
                break;
            }
        }
        let done = sim.ticks - start_ticks;
        in_frame.push(worked);
        backlogs.push(clock.due.saturating_sub(done));
        let finished = done >= target && !sim.mid_tick();
        if finished {
            end = Instant::now();
        }
        !finished
    });
    let wall = (end - start).as_secs_f64();
    let s = sorted(&in_frame);
    let days = (sim.ticks - start_ticks) as f64 / 10.0;
    let slices = sim.runtime.slice_report();
    Report {
        mode: "inline",
        config: cfg.clone(),
        days,
        wall_s: wall,
        nominal_days_per_s: cfg.nominal_days_per_s(),
        achieved_days_per_s: days / wall.max(1e-9),
        frames: FrameStats::of(&times, cfg.budget(), missed),
        sim_in_frame: Some((percentile(&s, 0.5) * 1000.0, percentile(&s, 0.99) * 1000.0, s.last().copied().unwrap_or(0.0) * 1000.0)),
        yielded,
        backlog: backlog(&backlogs, backlogs.last().copied().unwrap_or(0)),
        units: units.list(),
        slices,
        fingerprint: end_state(sim, Some(format!("inline-speed{}", cfg.speed))),
        ..Default::default()
    }
}

/// What the simulation's thread shares with the render thread.
struct Shared {
    /// ticks posted by the render thread's clock
    due: AtomicU64,
    /// ticks the simulation has run
    done: AtomicU64,
    loaded: AtomicBool,
    finished: AtomicBool,
    /// what the render thread reads after a day: the ticks run and the date
    published: Mutex<(u64, String)>,
}

struct ThreadResult {
    units: Vec<UnitStats>,
    load_s: f64,
    slices: String,
    fingerprint: String,
    vm_yields: (u64, u64),
}

/// The simulation on a thread of its own: `load` makes it there (a simulation's Lua state stays
/// on the thread that made it), then it runs the ticks the render thread's clock posts, `cfg.days`
/// days, publishing the date after each day. The render thread first draws `cfg.baseline_s`
/// seconds of frames with no simulation, then frames while the thread loads (the game paused),
/// then frames while it runs.
pub fn run_threaded<F>(cfg: &Config, load: F) -> Report
where
    F: FnOnce() -> Result<Simulation, String> + Send + 'static,
{
    run_on_threads(cfg, load, false)
}

/// As [`run_threaded`], the render thread doing nothing but render, and the simulation's threads
/// (its own and the worker pool's) in slices of `cfg.slice_ms`, every other slot unused
/// ([`crate::cadence`]): the VM stops the Lua code at a slice's deadline ([`crate::preempt`]).
pub fn run_sliced<F>(cfg: &Config, load: F) -> Report
where
    F: FnOnce() -> Result<Simulation, String> + Send + 'static,
{
    run_on_threads(cfg, load, true)
}

fn run_on_threads<F>(cfg: &Config, load: F, sliced: bool) -> Report
where
    F: FnOnce() -> Result<Simulation, String> + Send + 'static,
{
    let budget = cfg.budget();
    let baseline_end = Instant::now() + Duration::from_secs_f64(cfg.baseline_s);
    let (times, missed) = frame_loop(cfg, |_, _| Instant::now() < baseline_end);
    let baseline = FrameStats::of(&times, budget, missed);

    let shared = Arc::new(Shared {
        due: AtomicU64::new(0),
        done: AtomicU64::new(0),
        loaded: AtomicBool::new(false),
        finished: AtomicBool::new(false),
        published: Mutex::new((0, String::new())),
    });
    let sh = shared.clone();
    let target = cfg.days * 10;
    let mode = if sliced { "sliced" } else { "thread" };
    let end_name = format!("{mode}-speed{}", cfg.speed);
    let cadence = cfg.cadence();
    let handle = std::thread::Builder::new()
        .name("simulation".into())
        .spawn(move || {
            let run = || -> Result<ThreadResult, String> {
                let t0 = Instant::now();
                let mut sim = load()?;
                let load_s = t0.elapsed().as_secs_f64();
                // the heap's growth faulted in before the run (crate::runtime::prefault_heap), and
                // the store's (Store::prefault)
                crate::runtime::prefault_heap(2048, "STELLAR_PREFAULT_MB");
                let _ = sim.runtime.eval::<()>("if RUST.store_prefault then RUST.store_prefault(64) end");
                let log = if sliced {
                    crate::cadence::fine_timers();
                    crate::cadence::pin(1);
                    sim.runtime.set_preempt(true).map_err(|e| e.to_string())?;
                    let _ = sim.runtime.eval::<()>("require('engine.slice').reset()");
                    crate::cadence::clear_logs();
                    crate::cadence::set(Some(cadence));
                    Some(crate::cadence::register("simulation"))
                } else {
                    None
                };
                let vm0 = crate::preempt::counts();
                sh.loaded.store(true, Ordering::Release);
                let start_ticks = sim.ticks;
                let mut units = Units::default();
                let mut earliest = 0.0;
                let publish = |sim: &Simulation| {
                    let done = sim.ticks - start_ticks;
                    if sim.tick_count() == 0 {
                        *sh.published.lock().unwrap() = (done, format!("{:?}", sim.date()));
                    }
                    sh.done.store(done, Ordering::Release);
                };
                loop {
                    let done = sim.ticks - start_ticks;
                    if done >= target && !sim.mid_tick() {
                        break;
                    }
                    if !sim.mid_tick() && done >= sh.due.load(Ordering::Acquire) {
                        std::thread::park_timeout(Duration::from_millis(2));
                        continue;
                    }
                    let Some(log) = &log else {
                        let u = sim.upcoming();
                        let t = Instant::now();
                        let step = sim.step();
                        units.piece(u, t.elapsed().as_secs_f64(), true, false);
                        if step.tick_done {
                            publish(&sim);
                        }
                        continue;
                    };
                    // a slice: in a work slot, no earlier than a slot after the last one ended,
                    // units in pieces up to the deadline (the VM stops the one running there)
                    let (slot_end, deadline) = cadence.wait_for_slice(earliest);
                    sim.runtime.set_frame_end(slot_end);
                    let start = crate::runtime::clock();
                    loop {
                        let done = sim.ticks - start_ticks;
                        if !sim.mid_tick() && (done >= target || done >= sh.due.load(Ordering::Acquire)) {
                            break;
                        }
                        if crate::runtime::clock() >= deadline {
                            break;
                        }
                        let u = sim.upcoming();
                        let t = crate::runtime::clock();
                        let step = sim.step_until(deadline);
                        units.piece(u, crate::runtime::clock() - t, step.done, false);
                        if step.tick_done {
                            publish(&sim);
                        }
                        if !step.done {
                            break;
                        }
                    }
                    let end = crate::runtime::clock();
                    log.lock().unwrap().record(start, end, slot_end);
                    earliest = cadence.next_start(end);
                    crate::cadence::sleep_until(earliest);
                }
                let vm1 = crate::preempt::counts();
                if sliced {
                    crate::preempt::keep_stalls("simulation");
                    crate::cadence::set(None);
                    let _ = sim.runtime.set_preempt(false);
                    crate::preempt::release();
                    crate::cadence::unpin();
                }
                Ok(ThreadResult {
                    units: units.list(),
                    load_s,
                    slices: sim.runtime.slice_report(),
                    fingerprint: end_state(&sim, Some(end_name)),
                    vm_yields: (vm1.0 - vm0.0, vm1.1 - vm0.1),
                })
            };
            let r = run();
            sh.finished.store(true, Ordering::Release);
            r
        })
        .expect("the simulation's thread");
    let thread = handle.thread().clone();
    // (sliced: the render thread on a core of its own, as the simulation's threads are on theirs;
    // after the simulation's thread is made, which would take the render thread's one CPU as its
    // own, and its worker pool a size of one CPU's)
    if sliced {
        crate::cadence::pin_render();
    }

    let (times, missed) = frame_loop(cfg, |_, _| {
        let _ = shared.published.lock().unwrap().0;
        !shared.loaded.load(Ordering::Acquire) && !shared.finished.load(Ordering::Acquire)
    });
    let loading = FrameStats::of(&times, budget, missed);

    let mut clock = GameClock::new(cfg.turn());
    let mut backlogs = Vec::new();
    let mut lock_wait: f64 = 0.0;
    let start = Instant::now();
    let mut end = start;
    let (times, missed) = if shared.finished.load(Ordering::Acquire) {
        (Vec::new(), 0)
    } else {
        frame_loop(cfg, |dt, _| {
            clock.frame(dt);
            shared.due.store(clock.due, Ordering::Release);
            thread.unpark();
            let t = Instant::now();
            let _seen = shared.published.lock().unwrap().0;
            lock_wait = lock_wait.max(t.elapsed().as_secs_f64());
            let done = shared.done.load(Ordering::Acquire);
            backlogs.push(clock.due.saturating_sub(done));
            let more = done < target && !shared.finished.load(Ordering::Acquire);
            if !more {
                end = Instant::now();
            }
            more
        })
    };
    let wall = (end - start).as_secs_f64();
    let done = shared.done.load(Ordering::Acquire);
    let result = handle.join().map_err(|_| "the simulation's thread panicked".to_string()).and_then(|r| r);
    if sliced {
        crate::cadence::unpin();
    }
    let days = done as f64 / 10.0;
    let threads = if sliced {
        crate::cadence::set(None);
        let slot = cfg.slice_ms / 1000.0;
        crate::cadence::logs().iter().filter(|s| !s.lengths.is_empty()).map(|s| SliceStats::of(s, slot)).collect()
    } else {
        Vec::new()
    };
    let mut report = Report {
        mode,
        threads,
        vm_refusals: if sliced { crate::preempt::refusals() } else { Vec::new() },
        vm_lates: if sliced { crate::preempt::lates() } else { Vec::new() },
        vm_armed: if sliced { crate::preempt::armed_lateness() } else { Default::default() },
        stalls: if sliced { crate::preempt::kept_stalls() } else { Vec::new() },
        poll_late: crate::workers::poll_lateness(),
        config: cfg.clone(),
        days,
        wall_s: wall,
        nominal_days_per_s: cfg.nominal_days_per_s(),
        achieved_days_per_s: days / wall.max(1e-9),
        frames: FrameStats::of(&times, budget, missed),
        baseline: Some(baseline),
        loading: Some(loading),
        backlog: backlog(&backlogs, backlogs.last().copied().unwrap_or(0)),
        lock_wait_max_ms: lock_wait * 1000.0,
        ..Default::default()
    };
    match result {
        Ok(r) => {
            report.units = r.units;
            report.load_s = r.load_s;
            report.slices = r.slices;
            report.fingerprint = r.fingerprint;
            report.vm_yields = r.vm_yields;
        }
        Err(e) => report.error = Some(e),
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_posts_two_ticks_a_turn_or_a_frame() {
        let mut c = GameClock::new(0.075);
        for _ in 0..120 {
            c.frame(1.0 / 120.0);
        }
        // one second at Normal: 13 turns of 0.075 s, two ticks each
        assert_eq!(c.due, 26);
        let mut f = GameClock::new(0.0);
        for _ in 0..120 {
            f.frame(1.0 / 120.0);
        }
        assert_eq!(f.due, 240);
    }

    #[test]
    fn the_speeds_ask_for_their_days() {
        let mut c = Config::default();
        let want = [1.0 / 1.5, 1.0 / 0.75, 1.0 / 0.375, 1.0 / 0.2, 24.0];
        for (i, w) in want.iter().enumerate() {
            c.speed = i as u8 + 1;
            assert!((c.nominal_days_per_s() - w).abs() < 1e-9, "speed {}: {}", c.speed, c.nominal_days_per_s());
        }
        assert!((c.room() * 1000.0 - (1000.0 / 120.0 - 5.0)).abs() < 1e-9);
    }

    #[test]
    fn a_late_frame_misses_the_deadlines_it_passes() {
        let mut p = Pacer::new(Duration::from_millis(8));
        let d = p.deadline();
        p.present(d + Duration::from_millis(17));
        assert_eq!(p.missed, 3);
        assert!(p.deadline() > d + Duration::from_millis(17));
    }

    #[test]
    fn the_inline_frame_fits_and_the_thread_report_checks() {
        let mut r = Report { mode: "inline", config: Config::default(), ..Default::default() };
        r.frames = FrameStats::of(&[0.004, 0.005, 0.0081], r.config.budget(), 0);
        assert!(r.frames_fit());
        r.frames = FrameStats::of(&[0.004, 0.009], r.config.budget(), 1);
        assert!(!r.frames_fit());
        r.mode = "thread";
        let mut t = vec![0.004; 2000];
        t[0] = 0.02;
        r.frames = FrameStats::of(&t, r.config.budget(), 2);
        assert!(r.frames_fit(), "one late frame in 2,000");
    }
}
