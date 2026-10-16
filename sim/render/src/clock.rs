//! The simulation on its own thread, and the game's clock (docs/render.md section 12).
//!
//! The thread owns the simulation's Lua runtime (the save loaded with the game's definitions and
//! the script layer: `galaxy::sim_runtime`); nothing of it is shared. It runs days while the game
//! is not paused, one day every [`day_length`] of the speed (as fast as it can when a day takes
//! longer), and after every day publishes a [`Snapshot`]: the galaxy read from the world, the
//! galaxy view's map textures (made again only when the owners or terra incognita changed), the
//! system the window looks at, the top bar's texts and the date. The render thread takes the
//! newest snapshot when it draws a frame; it keeps its own runtime (the save's world alone) for
//! the game's files: models, GUI, worlds.
//!
//! Commands go one way, over a channel: run N days (the reply when they are done: `step`),
//! pause, the speed, the system to watch.
//!
//! The days run in 1 ms slices with every other millisecond unused (stellar_sim's cadence; the
//! worker pool's jobs too), the Lua VM stopping the engine's code at each slice's deadline
//! (stellar_sim::preempt, docs/frame_timing.md): the simulation never holds a CPU for longer. By
//! default on Linux; on Windows each day runs whole ([`slices_wanted`]; STELLAR_RENDER_CLOCK=sliced
//! or =thread chooses). The snapshot is read between days, whole.

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use stellar_sim::cadence::{self, Cadence};
use stellar_sim::mlua::Table;
use stellar_sim::{Runtime, Simulation};

use crate::border::{self, Borders};
use crate::dds::Image;
use crate::galaxy::{self, Galaxy};
use crate::galaxymap;
use crate::mapnames;
use crate::models;
use crate::system::{self, SystemData};

/// The game's speeds 1 to 5 (GAME_SPEED_1 "Slowest" .. GAME_SPEED_5 "Fastest"; CInGameIdler
/// +0x590 keeps them as 0..4).
pub const SPEEDS: u8 = 5;
/// The speed a loaded save runs at when unpaused: Normal (the CInGameIdler constructor's index
/// 2), paused.
pub const DEFAULT_SPEED: u8 = 3;

/// The real time a game day lasts at a speed (1..5) **[V]**: CInGameIdler::CheckTick posts two
/// tick commands every gGameSpeedTurnTimes[speed] seconds { 0.3 0.15 0.075 0.04 0 } and a day is
/// ten ticks (CGameState::HandleTurnTick): 1.5, 0.75, 0.375, 0.2 s, and at the fastest a day
/// every five frames (here: as fast as the simulation runs).
pub fn day_length(speed: u8) -> Duration {
    const TURN: [f32; 5] = [0.3, 0.15, 0.075, 0.04, 0.0];
    Duration::from_secs_f32(5.0 * TURN[(speed.clamp(1, SPEEDS) - 1) as usize])
}

/// The first unpause after a load waits this long more (CheckTick's accumulator starts at -1).
const FIRST_DELAY: Duration = Duration::from_secs(1);

/// The galaxy view's textures made from a galaxy: terra incognita, the borders' distance, edge
/// and fill (galaxymap.rs), and the 2D map's borders (border.rs) with their image.
pub struct MapImages {
    pub ti: Arc<Image>,
    pub sdf: Arc<Image>,
    pub edge: Arc<Image>,
    pub fill: Arc<Image>,
    pub borders: Arc<Borders>,
    pub borders_image: Arc<Image>,
    /// the borders' blobs with a symbol (mapnames.rs)
    pub blobs: Arc<Vec<mapnames::Blob>>,
}

impl MapImages {
    pub fn of(g: &Galaxy) -> MapImages {
        let ti = galaxymap::terra_incognita(g);
        let owner = galaxymap::owner_grid(g);
        let (sdf, edge, fill) = galaxymap::borders_of(g, &owner);
        let blobs = mapnames::blobs(&owner);
        let borders = border::compute(g);
        let borders_image = Image { width: borders.width, height: borders.height, rgba: borders.rgba.clone(), format: "generated".into() };
        MapImages {
            ti: Arc::new(ti),
            sdf: Arc::new(sdf),
            edge: Arc::new(edge),
            fill: Arc::new(fill),
            borders: Arc::new(borders),
            borders_image: Arc::new(borders_image),
            blobs: Arc::new(blobs),
        }
    }

    /// What the textures depend on: each system's shown owner (its country's id) and colours,
    /// and the player's terra incognita.
    pub fn key(g: &Galaxy) -> u64 {
        let mut h = DefaultHasher::new();
        for s in &g.systems {
            let o = s.owner.map(|i| &g.countries[i]);
            o.map(|c| c.id).hash(&mut h);
            g.shown_owner(s).is_some().hash(&mut h);
            if let Some(c) = o {
                for v in c.primary.iter().chain(c.secondary.iter()) {
                    v.to_bits().hash(&mut h);
                }
            }
        }
        if let Some(ti) = &g.terra_incognita {
            ti.bitmap.hash(&mut h);
        }
        h.finish()
    }
}

/// What the render thread draws from: the world after a day.
pub struct Snapshot {
    /// a new number for each snapshot
    pub generation: u64,
    pub date: String,
    pub galaxy: Arc<Galaxy>,
    pub images: Arc<MapImages>,
    /// the watched system's bodies and ships (its save id)
    pub system: Option<(u32, Arc<SystemData>)>,
    /// the top bar's texts: element path -> text (the resource groups' amounts)
    pub topbar: Arc<HashMap<String, String>>,
    /// the Lua errors raised by the simulation's phases so far
    pub errors: usize,
}

/// The thread's state, for the window and `state`.
#[derive(Clone, Debug, Default)]
pub struct Status {
    pub loading: bool,
    pub ready: bool,
    pub error: Option<String>,
    /// days run since the save
    pub days: u64,
    /// the last day's time (the simulation, then the snapshot), ms
    pub day_ms: f64,
    pub snapshot_ms: f64,
    pub load_s: f64,
    /// in slices: the slices run, those longer than 1 ms, the longest (ms)
    pub slices: u64,
    pub slices_over: u64,
    pub slice_max_ms: f64,
    /// the simulation's Lua heap after the last day (MB), and the most it has been
    pub lua_mb: f64,
    pub lua_max_mb: f64,
}

enum Cmd {
    Run(u64, Sender<Result<String, String>>),
    Pause(bool),
    Speed(u8),
    Watch(Option<u32>, Option<Sender<()>>),
    /// the key `.`: one day at once, then paused again (CJumpToNextDayCommand)
    NextDay,
    Quit,
}

struct Shared {
    latest: Mutex<Option<Arc<Snapshot>>>,
    status: Mutex<Status>,
}

/// The simulation's thread, seen from the render thread.
pub struct Clock {
    tx: Sender<Cmd>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl Clock {
    /// Starts the thread: it loads the save as a simulation (several seconds), then publishes the
    /// first snapshot and waits, paused or running at `speed`.
    pub fn start(game_dir: &str, save_path: &str, paused: bool, speed: u8, watch: Option<u32>) -> Clock {
        let (tx, rx) = mpsc::channel::<Cmd>();
        let shared = Arc::new(Shared { latest: Mutex::new(None), status: Mutex::new(Status { loading: true, ..Default::default() }) });
        let sh = shared.clone();
        let (game_dir, save_path) = (game_dir.to_string(), save_path.to_string());
        let thread = std::thread::Builder::new()
            .name("simulation".into())
            .spawn(move || {
                let t0 = Instant::now();
                let runtime = match galaxy::sim_runtime(&game_dir, &save_path) {
                    Ok(r) => r,
                    Err(e) => {
                        let mut s = sh.status.lock().unwrap();
                        s.loading = false;
                        s.error = Some(e);
                        return;
                    }
                };
                let cadence = match sliced(&runtime) {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("simulation: not in slices: {e}");
                        None
                    }
                };
                let mut w = Worker {
                    sim: Simulation::new(runtime),
                    game_dir,
                    shared: sh.clone(),
                    watch,
                    models: models::Library::default(),
                    images: None,
                    generation: 0,
                    paused,
                    speed: speed.clamp(1, SPEEDS),
                    cadence,
                    earliest: 0.0,
                };
                if let Err(e) = w.publish() {
                    eprintln!("simulation: the first snapshot: {e}");
                }
                {
                    let mut s = sh.status.lock().unwrap();
                    s.loading = false;
                    s.ready = true;
                    s.load_s = t0.elapsed().as_secs_f64();
                }
                eprintln!("simulation: loaded in {:.1} s", t0.elapsed().as_secs_f64());
                w.run(rx);
            })
            .expect("the simulation's thread");
        Clock { tx, shared, thread: Some(thread) }
    }

    pub fn status(&self) -> Status {
        self.shared.status.lock().unwrap().clone()
    }

    /// The newest snapshot.
    pub fn latest(&self) -> Option<Arc<Snapshot>> {
        self.shared.latest.lock().unwrap().clone()
    }

    /// Waits until the save is loaded (or failed).
    pub fn wait_ready(&self) -> Result<(), String> {
        loop {
            let s = self.status();
            if let Some(e) = s.error {
                return Err(format!("the simulation did not load: {e}"));
            }
            if s.ready {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Runs `days` days now and waits for them (paused or not); what happened.
    pub fn run_days(&self, days: u64) -> Result<String, String> {
        self.wait_ready()?;
        let (tx, rx) = mpsc::channel();
        self.tx.send(Cmd::Run(days, tx)).map_err(|_| "the simulation's thread has ended")?;
        rx.recv().map_err(|_| "the simulation's thread has ended".to_string())?
    }

    pub fn set_paused(&self, paused: bool) {
        let _ = self.tx.send(Cmd::Pause(paused));
    }

    pub fn set_speed(&self, speed: u8) {
        let _ = self.tx.send(Cmd::Speed(speed));
    }

    /// One day now (when paused), without waiting for it.
    pub fn next_day(&self) {
        let _ = self.tx.send(Cmd::NextDay);
    }

    /// The system whose bodies and ships the snapshots carry; with `wait`, until a snapshot has
    /// them (at most a second: a day may be running).
    pub fn watch(&self, system: Option<u32>, wait: bool) {
        if wait && self.status().ready {
            let (tx, rx) = mpsc::channel();
            if self.tx.send(Cmd::Watch(system, Some(tx))).is_ok() {
                let _ = rx.recv_timeout(Duration::from_secs(1));
            }
        } else {
            let _ = self.tx.send(Cmd::Watch(system, None));
        }
    }
}

impl Drop for Clock {
    fn drop(&mut self) {
        let _ = self.tx.send(Cmd::Quit);
        if let Some(t) = self.thread.take() {
            // a day or the load in progress finishes first; the window does not wait for a load
            if self.shared.status.lock().map(|s| s.ready).unwrap_or(false) {
                let _ = t.join();
            }
        }
    }
}

/// Whether the days run in slices: STELLAR_RENDER_CLOCK=sliced or =thread (whole days); by
/// default in slices on Linux and whole on Windows. On Windows a thread woken from a sleep starts
/// about half a millisecond late (its timers' best), so a slice began half-way through its
/// millisecond, and the simulation ran at a sixth of its speed in slices on the laptop where
/// whole days keep 84% of Normal (docs/render.md section 12); there a precise millisecond needs
/// the unused ones spent waiting.
fn slices_wanted() -> bool {
    match std::env::var("STELLAR_RENDER_CLOCK").as_deref() {
        Ok("thread") => false,
        Ok("sliced") => true,
        _ => !cfg!(windows),
    }
}

/// The simulation's thread set to run in slices ([`slices_wanted`]): fine timers, a core of its
/// own (Linux), the VM's preemption on, the cadence set for it and the worker pool (stellar_sim:
/// cadence, preempt; docs/frame_timing.md). Its heap's growth is not faulted in ahead
/// (runtime::prefault_heap: 2 GB on this thread and 384 MB on each worker, which the frame timing
/// harness takes to keep every slice within its millisecond): here the frames are what must keep
/// their time, and a slice late by a page fault does not touch them.
fn sliced(runtime: &Runtime) -> Result<Option<Cadence>, String> {
    if !slices_wanted() {
        return Ok(None);
    }
    cadence::fine_timers();
    cadence::pin(1);
    runtime.set_preempt(true).map_err(|e| e.to_string())?;
    let _ = runtime.eval::<()>("require('engine.slice').reset()");
    let c = Cadence { slot: 0.001, margin: 0.0001 };
    cadence::set(Some(c));
    eprintln!("simulation: in 1 ms slices, every other millisecond unused");
    Ok(Some(c))
}

struct Worker {
    sim: Simulation,
    game_dir: String,
    shared: Arc<Shared>,
    watch: Option<u32>,
    models: models::Library,
    images: Option<(u64, Arc<MapImages>)>,
    generation: u64,
    paused: bool,
    speed: u8,
    /// the slices' cadence (None: the days run whole), and when the next slice may begin
    cadence: Option<Cadence>,
    earliest: f64,
}

impl Worker {
    fn rt(&self) -> &Runtime {
        &self.sim.runtime
    }

    fn run(&mut self, rx: mpsc::Receiver<Cmd>) {
        // when the next day is due while running; the first unpause waits a second more
        let mut first = true;
        let mut next = Instant::now() + day_length(self.speed) + FIRST_DELAY;
        loop {
            let wait = if self.paused { Duration::from_secs(3600) } else { next.saturating_duration_since(Instant::now()) };
            match rx.recv_timeout(wait) {
                Ok(Cmd::Run(days, reply)) => {
                    let r = self.days(days);
                    let _ = reply.send(r);
                    next = Instant::now() + day_length(self.speed);
                }
                Ok(Cmd::Pause(p)) => {
                    if self.paused && !p {
                        next = Instant::now() + day_length(self.speed) + if first { FIRST_DELAY } else { Duration::ZERO };
                        first = false;
                    }
                    self.paused = p;
                }
                Ok(Cmd::Speed(s)) => {
                    self.speed = s.clamp(1, SPEEDS);
                    next = next.min(Instant::now() + day_length(self.speed));
                }
                Ok(Cmd::Watch(id, reply)) => {
                    if self.watch != id {
                        self.watch = id;
                        if let Err(e) = self.publish() {
                            eprintln!("simulation: snapshot: {e}");
                        }
                    }
                    if let Some(r) = reply {
                        let _ = r.send(());
                    }
                }
                Ok(Cmd::NextDay) => {
                    if self.paused {
                        if let Err(e) = self.days(1) {
                            eprintln!("simulation: {e}");
                        }
                    }
                }
                Ok(Cmd::Quit) | Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => {
                    if self.paused {
                        continue;
                    }
                    if let Err(e) = self.days(1) {
                        eprintln!("simulation: {e}");
                        self.paused = true;
                    }
                    // the next day one day's length after this one was due; when the simulation
                    // is behind, at most 0.4 of a day is made up (the accumulator is clamped to
                    // two of a day's five rounds)
                    let now = Instant::now();
                    let day = day_length(self.speed);
                    next = (next + day).max(now.checked_sub(day.mul_f32(0.4)).unwrap_or(now));
                }
            }
        }
    }

    /// Runs days, in slices (or whole), then publishes the world.
    fn days(&mut self, days: u64) -> Result<String, String> {
        let t0 = Instant::now();
        match self.cadence {
            Some(c) => self.run_sliced(days, c),
            None => self.sim.run_days(days),
        }
        let ran = t0.elapsed().as_secs_f64();
        let t1 = Instant::now();
        self.publish()?;
        let published = t1.elapsed().as_secs_f64();
        let date = format!("{:?}", self.sim.date());
        let errors = self.sim.errors.len();
        let lua_mb = self.rt().eval::<f64>("return collectgarbage('count') / 1024").unwrap_or(0.0);
        {
            let mut s = self.shared.status.lock().unwrap();
            s.lua_mb = lua_mb;
            s.lua_max_mb = s.lua_max_mb.max(lua_mb);
            s.days += days;
            s.day_ms = ran * 1000.0 / days.max(1) as f64;
            s.snapshot_ms = published * 1000.0;
        }
        Ok(format!("{days} days in {ran:.1} s to {date}; {errors} errors so far"))
    }

    /// `days` days in slices: each in a work millisecond, no earlier than a millisecond after the
    /// last one ended, the engine's units run to the slice's deadline (the VM stops the one running
    /// there), then asleep.
    fn run_sliced(&mut self, days: u64, c: Cadence) {
        let target = self.sim.ticks + days * 10;
        let (mut n, mut over, mut longest) = (0u64, 0u64, 0.0f64);
        while self.sim.ticks < target || self.sim.mid_tick() {
            let (slot_end, deadline) = c.wait_for_slice(self.earliest);
            self.sim.runtime.set_frame_end(slot_end);
            let start = stellar_sim::runtime::clock();
            loop {
                if (self.sim.ticks >= target && !self.sim.mid_tick()) || stellar_sim::runtime::clock() >= deadline {
                    break;
                }
                if !self.sim.step_until(deadline).done {
                    break;
                }
            }
            let end = stellar_sim::runtime::clock();
            n += 1;
            if end - start > c.slot {
                over += 1;
            }
            longest = longest.max(end - start);
            self.earliest = c.next_start(end);
            if self.sim.ticks < target || self.sim.mid_tick() {
                cadence::sleep_until(self.earliest);
            }
        }
        let mut s = self.shared.status.lock().unwrap();
        s.slices += n;
        s.slices_over += over;
        s.slice_max_ms = s.slice_max_ms.max(longest * 1000.0);
    }

    /// Reads the world into a snapshot and makes it the newest.
    fn publish(&mut self) -> Result<(), String> {
        // the owners the world keeps indexed: built again from the objects' fields
        let _ = self.rt().eval::<()>("local w = require('engine.world') if w.index then w.index() end");
        let galaxy = galaxy::extract(self.rt(), &self.game_dir)?;
        let key = MapImages::key(&galaxy);
        let images = match &self.images {
            Some((k, i)) if *k == key => i.clone(),
            _ => {
                let i = Arc::new(MapImages::of(&galaxy));
                self.images = Some((key, i.clone()));
                i
            }
        };
        let system = match self.watch {
            Some(id) => {
                self.models.ensure(&self.sim.runtime, &self.game_dir)?;
                Some((id, Arc::new(system::extract(&self.sim.runtime, &self.game_dir, id)?)))
            }
            None => None,
        };
        let topbar = topbar_texts(self.rt()).map_err(|e| format!("render.topbar: {e}"))?;
        self.generation += 1;
        let snap = Snapshot {
            generation: self.generation,
            date: format!("{:?}", self.sim.date()),
            galaxy: Arc::new(galaxy),
            images,
            system,
            topbar: Arc::new(topbar),
            errors: self.sim.errors.len(),
        };
        *self.shared.latest.lock().unwrap() = Some(Arc::new(snap));
        Ok(())
    }
}

/// The top bar's amounts from the world (render.topbar's values): element path -> text.
fn topbar_texts(rt: &Runtime) -> Result<HashMap<String, String>, stellar_sim::mlua::Error> {
    let t: Table = rt
        .lua
        .load(
            r#"
            local tb = require('render.topbar')
            local out = {}
            for group, v in pairs(tb.values(tb.player())) do
                out['/maingui/topbar_static/' .. group .. '/amount'] = v.text
            end
            return out
            "#,
        )
        .eval()?;
    let mut out = HashMap::new();
    for p in t.pairs::<String, String>() {
        let (k, v) = p?;
        out.insert(k, v);
    }
    Ok(out)
}
