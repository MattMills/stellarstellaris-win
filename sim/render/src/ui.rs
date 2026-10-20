//! The app on a thread of its own, and the render thread doing nothing but render (docs/render.md
//! section 12).
//!
//! The UI thread owns the [`App`]: its Lua runtime (the GUI's layouts, the names' localisation, the
//! game's files), the input, the simulation's clock (clock.rs: the simulation on a thread of its
//! own again) and the scene. It runs the jobs the window sends it (the input, commands), and every
//! 1/120 s updates the app (the camera's glide, the simulation's newest snapshot) and builds the
//! scene when something changed, then publishes it with the textures it uses, their mip chains made
//! here ([`render::premip`]). The render thread draws the newest published scene every frame, and
//! uploads a new one within a budget a frame ([`Renderer::preload`](crate::render::Renderer::preload)),
//! drawing the one before until it is ready: no Lua, no scene building and no large upload takes a
//! frame's time.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::app::{App, Screen};
use crate::render::{self, Backend, Offscreen, Res};
use crate::scene::{Scene, Textures, ALL};

/// What the UI thread publishes: the scene to draw, the textures it uses, the app's screen.
pub struct Frame {
    /// a new number for each scene
    pub generation: u64,
    pub scene: Arc<Scene>,
    pub textures: Arc<Textures>,
    pub screen: Screen,
}

/// A job for the app: an error ends the app (as the window's input did when it ran there).
type Job = Box<dyn FnOnce(&mut App) -> Result<(), String> + Send>;

struct Shared {
    latest: Mutex<Option<Arc<Frame>>>,
    /// the app's end: closed (its `exit`), or an error
    ended: Mutex<Option<Result<(), String>>>,
}

/// The UI thread, seen from the render thread.
pub struct Ui {
    tx: Option<Sender<Job>>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

/// How often the UI thread updates the app and builds a new scene: the frames' rate.
pub const PERIOD: Duration = Duration::from_micros(8333);

/// The bytes a frame uploads at most of a new scene's textures, cube maps and meshes (one at
/// least): a scene that needs more is drawn a few frames later, the one before meanwhile.
pub const UPLOAD_BUDGET: usize = 4 << 20;

impl Ui {
    /// Starts the UI thread with the app `make` makes there (it stays there: its Lua runtime and
    /// caches are the thread's); returns once it is made.
    pub fn start<F>(make: F) -> Result<Ui, String>
    where
        F: FnOnce() -> Result<App, String> + Send + 'static,
    {
        let (tx, rx) = mpsc::channel::<Job>();
        let shared = Arc::new(Shared { latest: Mutex::new(None), ended: Mutex::new(None) });
        let sh = shared.clone();
        let (made_tx, made_rx) = mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("ui".into())
            .spawn(move || {
                let app = match make() {
                    Ok(a) => {
                        let _ = made_tx.send(Ok(()));
                        a
                    }
                    Err(e) => {
                        let _ = made_tx.send(Err(e));
                        return;
                    }
                };
                run(app, rx, &sh);
            })
            .map_err(|e| format!("the UI thread: {e}"))?;
        made_rx.recv().map_err(|_| "the UI thread ended".to_string())??;
        Ok(Ui { tx: Some(tx), shared, thread: Some(thread) })
    }

    /// A job for the app, run on its thread in order; returns at once.
    pub fn post(&self, f: impl FnOnce(&mut App) -> Result<(), String> + Send + 'static) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(Box::new(f));
        }
    }

    /// A job waited for: what it returns.
    pub fn call<R: Send + 'static>(&self, f: impl FnOnce(&mut App) -> R + Send + 'static) -> Result<R, String> {
        let (rtx, rrx) = mpsc::channel();
        self.post(move |app| {
            let _ = rtx.send(f(app));
            Ok(())
        });
        rrx.recv().map_err(|_| "the UI thread ended".to_string())
    }

    /// The newest scene published.
    pub fn latest(&self) -> Option<Arc<Frame>> {
        self.shared.latest.lock().unwrap().clone()
    }

    /// The app's end: Some(Ok) closed, Some(Err) failed.
    pub fn ended(&self) -> Option<Result<(), String>> {
        self.shared.ended.lock().unwrap().clone()
    }
}

impl Drop for Ui {
    fn drop(&mut self) {
        self.tx = None;
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn end(sh: &Shared, r: Result<(), String>) {
    let mut e = sh.ended.lock().unwrap();
    if e.is_none() {
        *e = Some(r);
    }
}

fn run(mut app: App, rx: Receiver<Job>, sh: &Shared) {
    let mut published = u64::MAX;
    // STELLAR_PROF=1: the spans' table on stderr every STELLAR_PROF_EVERY seconds, and at the end
    let every = std::env::var("STELLAR_PROF_EVERY").ok().and_then(|v| v.parse::<f64>().ok()).filter(|s| *s > 0.0).map(Duration::from_secs_f64);
    let mut reported = Instant::now();
    let mut next = Instant::now();
    // a job ran since the last update (its effect is drawn at the next period)
    let mut pending = true;
    loop {
        // the jobs as they come; the app's update and scene once a period while something moves
        // (the clock, the camera, a held key: App::animating) or after a job, else every 100 ms
        let wait = if pending || app.animating() { next.saturating_duration_since(Instant::now()) } else { Duration::from_millis(100) };
        match rx.recv_timeout(wait) {
            Ok(job) => {
                let _s = crate::prof::span("ui: jobs (input, commands)");
                if let Err(e) = job(&mut app) {
                    end(sh, Err(e));
                }
                while let Ok(job) = rx.try_recv() {
                    if let Err(e) = job(&mut app) {
                        end(sh, Err(e));
                    }
                }
                pending = true;
                if Instant::now() < next {
                    continue;
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                if crate::prof::on() {
                    eprintln!("{}", crate::prof::full_report(&app.runtime, 40, false));
                }
                break;
            }
        }
        next = (next + PERIOD).max(Instant::now());
        pending = false;
        app.update();
        for l in app.log.drain(..) {
            eprintln!("{l}");
        }
        if app.exit {
            end(sh, Ok(()));
        }
        match app.prepare() {
            Ok(g) if g != published => {
                let Some(scene) = app.scene_shared() else { continue };
                let textures = app.textures();
                let s = crate::prof::span("ui: mip chains");
                for r in render::scene_resources(&scene) {
                    if let Res::Texture(i) = r {
                        render::premip(&textures.images[i]);
                    }
                }
                drop(s);
                let frame = Frame { generation: g, scene, textures: Arc::new(textures.clone()), screen: app.screen };
                if std::env::var("RENDER_TRACE").is_ok() {
                    eprintln!("scene {g} published ({}x{})", frame.scene.view.width, frame.scene.view.height);
                }
                *sh.latest.lock().unwrap() = Some(Arc::new(frame));
                published = g;
            }
            Ok(_) => {}
            Err(e) => end(sh, Err(e)),
        }
        crate::prof::frame_end();
        if let Some(every) = every.filter(|_| crate::prof::on()) {
            if reported.elapsed() >= every {
                let unix = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
                eprintln!("prof report at {unix:.1} (the last {:.1} s)\n{}", reported.elapsed().as_secs_f64(), crate::prof::full_report(&app.runtime, 25, true));
                reported = Instant::now();
            }
        }
    }
}

/// The render thread's side of a new scene: its resources uploaded within the frame's budget,
/// then the scene; whether the scene is the one drawn now.
pub fn take(renderer: &mut render::Renderer, device: &wgpu::Device, queue: &wgpu::Queue, frame: &Frame, uploaded: &mut u64) -> bool {
    if frame.generation == *uploaded {
        return true;
    }
    if !renderer.preload(device, queue, &frame.scene, &frame.textures, UPLOAD_BUDGET) {
        return false;
    }
    renderer.upload(device, queue, &frame.scene, &frame.textures);
    *uploaded = frame.generation;
    true
}

/// A frame of [`bench`]: the render thread's parts (the newest scene taken and its resources
/// uploaded, the GPU's frame), seconds, and whether a new scene was switched to in it.
#[derive(Clone, Copy, Default)]
struct BenchFrame {
    cpu: f64,
    gpu: f64,
    switched: bool,
}

/// Frames at `fps` for `secs` seconds, drawn as the window draws them: what they took.
fn frames_for(ui: &Ui, off: &mut Offscreen, target: &mut Option<(u32, u32, wgpu::Texture)>, uploaded: &mut u64, secs: f64, fps: f64) -> Result<String, String> {
    let period = 1.0 / fps;
    let status = |ui: &Ui| {
        ui.call(|app| {
            app.map.as_ref().map(|m| {
                let s = m.clock.as_ref().map(|c| c.status()).unwrap_or_default();
                (m.date(), s.days, s.slices, s.slices_over, s.slice_max_ms)
            })
        })
        .ok()
        .flatten()
    };
    let before = status(ui);
    let mut frames: Vec<BenchFrame> = Vec::new();
    let mut waiting = 0usize;
    let start = Instant::now();
    let mut next = start;
    while start.elapsed().as_secs_f64() < secs {
        loop {
            let left = next.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            if left > Duration::from_millis(2) {
                std::thread::sleep(left - Duration::from_millis(2));
            } else {
                std::hint::spin_loop();
            }
        }
        if let Some(Err(e)) = ui.ended() {
            return Err(e);
        }
        let t0 = Instant::now();
        let mut switched = false;
        if let Some(frame) = ui.latest() {
            let was = *uploaded;
            if !take(&mut off.renderer, &off.device, &off.queue, &frame, uploaded) {
                waiting += 1;
            }
            switched = *uploaded != was;
        }
        let t1 = Instant::now();
        if let Some(frame) = ui.latest() {
            let v = &frame.scene.view;
            off.draw_frame(v.width.max(1), v.height.max(1), ALL, target)?;
        }
        let t2 = Instant::now();
        frames.push(BenchFrame { cpu: (t1 - t0).as_secs_f64(), gpu: (t2 - t1).as_secs_f64(), switched });
        next += Duration::from_secs_f64(period);
        if next < t2 {
            next = t2;
        }
    }
    let wall = start.elapsed().as_secs_f64();
    let after = status(ui);
    let ms = |s: f64| s * 1000.0;
    let pct = |mut v: Vec<f64>, p: f64| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        if v.is_empty() { 0.0 } else { v[((v.len() - 1) as f64 * p).round() as usize] }
    };
    let total: Vec<f64> = frames.iter().map(|f| f.cpu + f.gpu).collect();
    let cpu: Vec<f64> = frames.iter().map(|f| f.cpu).collect();
    let gpu: Vec<f64> = frames.iter().map(|f| f.gpu).collect();
    let over = frames.iter().filter(|f| f.cpu + f.gpu > period).count();
    let cpu_over = frames.iter().filter(|f| f.cpu > period).count();
    let switches: Vec<&BenchFrame> = frames.iter().filter(|f| f.switched).collect();
    let switch_max = switches.iter().map(|f| f.cpu).fold(0.0, f64::max);
    let days = match (&before, &after) {
        (Some((d0, n0, s0, o0, _)), Some((d1, n1, s1, o1, smax))) => {
            let slices = if s1 > s0 { format!("; the simulation in {} slices, {} longer than 1 ms, the longest of the run {smax:.2} ms", s1 - s0, o1 - o0) } else { String::new() };
            format!("{} days run, {d0} to {d1}{slices}", n1 - n0)
        }
        _ => "no map".into(),
    };
    Ok(format!(
        "{} frames in {wall:.1} s at {fps} FPS ({:.2} ms a frame): frame ms p50 {:.2} p99 {:.2} max {:.2}, over the frame's time {over}; the render thread's CPU part (the scene taken, its uploads) p50 {:.3} p99 {:.3} max {:.3}, over {cpu_over}; the GPU's p50 {:.2} p99 {:.2} max {:.2}; {} new scenes drawn (their frame's CPU part at most {:.3} ms), {waiting} frames drew the scene before while a new one's resources went up; {days}",
        frames.len(),
        ms(period),
        ms(pct(total.clone(), 0.5)),
        ms(pct(total.clone(), 0.99)),
        ms(pct(total, 1.0)),
        ms(pct(cpu.clone(), 0.5)),
        ms(pct(cpu.clone(), 0.99)),
        ms(pct(cpu, 1.0)),
        ms(pct(gpu.clone(), 0.5)),
        ms(pct(gpu.clone(), 0.99)),
        ms(pct(gpu, 1.0)),
        switches.len(),
        ms(switch_max),
    ))
}

/// The process's resident memory (MB): Linux's VmRSS, Windows' working set (K32GetProcessMemoryInfo).
fn process_mb() -> f64 {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|s| s.lines().find(|l| l.starts_with("VmRSS:")).and_then(|l| l.split_whitespace().nth(1)?.parse::<f64>().ok()))
            .map_or(0.0, |kb| kb / 1024.0)
    }
    #[cfg(windows)]
    unsafe {
        #[repr(C)]
        #[derive(Default)]
        struct Counters {
            cb: u32,
            page_faults: u32,
            peak_working_set: usize,
            working_set: usize,
            quota: [usize; 4],
            pagefile: usize,
            peak_pagefile: usize,
        }
        extern "system" {
            fn GetCurrentProcess() -> *mut std::ffi::c_void;
            fn K32GetProcessMemoryInfo(process: *mut std::ffi::c_void, counters: *mut Counters, cb: u32) -> i32;
        }
        let mut c = Counters { cb: std::mem::size_of::<Counters>() as u32, ..Default::default() };
        K32GetProcessMemoryInfo(GetCurrentProcess(), &mut c, c.cb);
        c.working_set as f64 / 1048576.0
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        0.0
    }
}

/// Where the memory is: the process's, the simulation's Lua heap (now, the most), the UI thread's
/// runtimes' (the front end's, the map's), the decoded textures.
fn memory(ui: &Ui) -> String {
    let parts = ui
        .call(|app| {
            let lua = |rt: &stellar_sim::Runtime| rt.eval::<f64>("return collectgarbage('count') / 1024").unwrap_or(0.0);
            let images = |c: &crate::dds::Cache| c.images.values().filter_map(|r| r.as_ref().ok()).map(|i| i.rgba.len()).sum::<usize>() as f64 / 1048576.0;
            let (sim, sim_max) = app.map.as_ref().and_then(|m| m.clock.as_ref()).map_or((0.0, 0.0), |c| {
                let s = c.status();
                (s.lua_mb, s.lua_max_mb)
            });
            let map_lua = app.map.as_ref().map_or(0.0, |m| lua(&m.runtime));
            let textures = images(&app.cache.borrow()) + app.map.as_ref().map_or(0.0, |m| images(&m.cache.borrow()));
            (sim, sim_max, lua(&app.runtime), map_lua, textures)
        })
        .unwrap_or_default();
    format!(
        "memory: the process {:.0} MB; the simulation's Lua heap {:.0} MB (at most {:.0}); the UI thread's runtimes {:.0} MB (the front end) + {:.0} MB (the map's); decoded textures {:.0} MB",
        process_mb(),
        parts.0,
        parts.1,
        parts.2,
        parts.3,
        parts.4
    )
}

/// `--bench SECONDS`: the window's way of drawing, offscreen. The app on its UI thread with the
/// save as a running simulation (the galaxy view in 3D), the render thread drawing the newest
/// scene at 120 FPS (STELLAR_BENCH_FPS) as the window does (a new scene's resources within the
/// budget a frame, then the scene; the GPU's frame waited for; no read-back): 3 s paused, then
/// SECONDS with the clock running at STELLAR_BENCH_SPEED (3, Normal). Prints what the frames took
/// against the frame's time (docs/frame_timing.md: the 120 FPS standard).
pub fn bench(game: &str, save: &str, backend: Backend, adapter: Option<&str>, size: (u32, u32), secs: f64) -> Result<(), String> {
    let env = |k: &str, d: f64| std::env::var(k).ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(d);
    let (fps, speed) = (env("STELLAR_BENCH_FPS", 120.0), env("STELLAR_BENCH_SPEED", 3.0) as u8);
    let mut off = Offscreen::new(backend, adapter)?;
    println!("rendering on: {}", off.adapter);
    let (g, s) = (game.to_string(), save.to_string());
    let t0 = Instant::now();
    let ui = Ui::start(move || {
        let mut app = App::new(&g, size)?;
        app.smooth = true;
        app.load_as(&s, true)?;
        app.mode3d = true;
        app.show_galaxy();
        Ok(app)
    })?;
    println!("the save loaded as a running simulation in {:.1} s", t0.elapsed().as_secs_f64());
    let (mut target, mut uploaded) = (None, u64::MAX);
    // the first scene and its textures up, whatever they take (the load's)
    let t0 = Instant::now();
    loop {
        if let Some(Err(e)) = ui.ended() {
            return Err(e);
        }
        if let Some(frame) = ui.latest() {
            if take(&mut off.renderer, &off.device, &off.queue, &frame, &mut uploaded) {
                break;
            }
        } else {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    println!("the first scene up in {:.2} s", t0.elapsed().as_secs_f64());
    println!("{}", memory(&ui));
    println!("paused: {}", frames_for(&ui, &mut off, &mut target, &mut uploaded, 3.0, fps)?);
    ui.call(move |app| app.set_paused(false).and_then(|_| app.set_speed(speed)))??;
    println!("running at speed {speed}: {}", frames_for(&ui, &mut off, &mut target, &mut uploaded, secs, fps)?);
    println!("{}", memory(&ui));
    Ok(())
}
