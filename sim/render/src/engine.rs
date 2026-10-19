//! The renderer without a window, driven by commands: from a script (`--script FILE`) or over TCP
//! (`--listen ADDR:PORT`, or STELLAR_RENDER_LISTEN; localhost unless an address is given). One
//! command per line, one reply per command, sent after the change or the frame is complete, so a
//! client can script an exact sequence of shots. Replies are one line: `ok ...` or `error ...`;
//! `frame -` replies `ok frame - W H MS BYTES` and then the PNG's bytes.
//!
//! Commands (angles in degrees, positions in map units):
//! - `load PATH` (the save's world), `load-sim PATH` (as a running simulation), `step DAYS`
//! - `load-sim async PATH`: the save loaded behind the load screen (as the window's Load and
//!   Continue do); `loaded` waits for it. `console on|off`: the load screens' console of the
//!   renderer's log (console.rs; off by default here, STELLAR_LOAD_CONSOLE=1 turns it on)
//! - `newgame [async] KEY=VALUE ... [empire=DESIGN]`: a new game (newgame.rs; the keys are
//!   newgame.generate's: scenario, shape, empires, seed, global_seed, ...), the load screen shown
//!   while it is made (`frame` draws it, `state` says `Loading`); the reply when it is shown
//!   paused on the capital at 2200.01.01, or at once with `async`, then `loaded` waits for it
//! - `view galaxy`, `view system ID` (the save's system id), `view model NAME` (an entity or a
//!   pdxmesh of gfx/models alone), `view menu`, `view 2d`, `view 3d`
//! - `focus system ID`, `focus fleet ID`: the galaxy camera over it
//! - `camera X Y Z YAW PITCH DISTANCE` (the target on the plane is X, Z = the map's x, y; the
//!   game's camera: the eye at target + distance (-cos p sin y, sin p, cos p cos y), camera.rs),
//!   `orbit DYAW DPITCH`, `zoom FACTOR` (< 1 closer), `pan DX DY` (fractions of the distance)
//! - `resize W H`, `gui off|on` (the top bar, a system's orbit lines)
//! - the clock (clock.rs: the simulation on its own thread): `pause` (stopped, as the game's
//!   headless), `pause off` (running), `speed 1..5`, `wait SECONDS` (real time passes)
//! - `select system|fleet|planet|ship ID`, `select none`: the selection (marked; `state` names it)
//! - `open_starbase [starbase] ID [tab N]`: a starbase's window (its station fleet selected), a tab
//! - `open fleet ID|ship ID|fleet_manager|none`: the fleet windows (fleetwin.rs; the headless
//!   game's `open` opens the same ones)
//! - input, as a keyboard and a mouse make it (controls.rs; headless.c makes the same in the
//!   game by XTest): `key CHORD [down|up|tap]`, `hold CHORD DURATION`, `mouse X Y [BUTTON
//!   [down|up]]`, `move X Y`, `button BUTTON down|up [X Y]`, `click X Y [BUTTON] [double]`,
//!   `wheel NOTCHES [X Y]` (`scroll`), `drag BUTTON X0 Y0 X1 Y1 [STEPS [FRAMES]]`; `bindings`
//! - frames: `timestep MS` (lockstep: frames of MS each run only by commands, the camera glides
//!   as the game's, input reaches the app at the next frame as the game's does), `timestep off`,
//!   `tick N` (N frames). A DURATION is frames (`30`, `30f`) or time (`500ms`, `0.5s`: frames of
//!   the timestep)
//! - `frame PATH.png` (renders the view, writes the PNG: `ok frame PATH W H MS`), `frame -`;
//!   in lockstep the camera arrives first (frames run), `frame PATH now` takes the frame as it is
//! - `bench SECONDS [FPS]`: frames drawn back to back at FPS (120) as a window draws them, the
//!   clock running as it is; what each frame took against the frame's time
//! - `state` (JSON: screen, view, camera, date, the clock, the selection, the input, size), `quit`

use std::io::{BufRead, BufReader, Write};

use crate::app::{App, MapView, Screen};
use crate::controls::{self, Action, Button, Input};
use crate::scene::Pickable;
use crate::camera::OrbitCamera;
use crate::math::V3;
use crate::render::{Backend, Offscreen};
use crate::scene::ALL;
use crate::verify;

pub struct Engine {
    pub app: App,
    pub off: Offscreen,
    pub frames: u64,
    /// `bench`'s target texture
    target: Option<(u32, u32, wgpu::Texture)>,
    /// a frame's time (`tick`), seconds: `timestep MS`, 1/60 s by default
    timestep: f32,
    /// lockstep (`timestep MS`): the camera glides as the game's, the input given since the last
    /// frame reaches the app after the next frame's update (`pending`), as the game's SDL events
    /// reach it at the start of the frame after the one they were made in
    lockstep: bool,
    pending: Vec<Input>,
    /// frames run (`tick`), and the input's clock (their time, ms)
    frame_no: u64,
    clock_ms: f64,
}

/// A frame of `bench`: its parts, seconds: the app's update (the camera, the simulation's
/// snapshot taken), the scene built (when something changed), its upload, the GPU's frame; and
/// whether a new snapshot came in it.
#[derive(Clone, Copy, Default)]
struct BenchFrame {
    update: f64,
    prepare: f64,
    upload: f64,
    gpu: f64,
    snapshot: bool,
}

impl BenchFrame {
    fn total(&self) -> f64 {
        self.update + self.prepare + self.upload + self.gpu
    }
    fn cpu(&self) -> f64 {
        self.update + self.prepare + self.upload
    }
}

/// A reply: its line, the bytes that follow it (`frame -`), and whether the session ends.
pub struct Reply {
    pub line: String,
    pub bytes: Option<Vec<u8>>,
    pub quit: bool,
}

impl Reply {
    fn ok(s: impl Into<String>) -> Reply {
        Reply { line: format!("ok {}", s.into()), bytes: None, quit: false }
    }
}

fn num<T: std::str::FromStr>(s: Option<&&str>, what: &str) -> Result<T, String> {
    s.ok_or(format!("{what} missing"))?.parse().map_err(|_| format!("{what}: not a number"))
}

impl Engine {
    pub fn new(game_dir: &str, backend: Backend, adapter: Option<&str>, size: (u32, u32)) -> Result<Engine, String> {
        let mut app = App::new(game_dir, size)?;
        // driven by commands: the load screens' console off unless asked for (STELLAR_LOAD_CONSOLE=1,
        // `console on`), so the frames compare with the game's; the menu's loads at once
        app.console = crate::console::enabled(true);
        app.async_loads = false;
        let off = Offscreen::new(backend, adapter)?;
        eprintln!("rendering on: {}", off.adapter);
        Ok(Engine { app, off, frames: 0, target: None, timestep: 1.0 / 60.0, lockstep: false, pending: Vec::new(), frame_no: 0, clock_ms: 0.0 })
    }

    /// Frames drawn back to back at `fps` for `secs` seconds as a window draws them (the app
    /// updated, the scene built when something changed and uploaded, the GPU's frame waited for;
    /// no read-back), with the clock running as it is: what each frame took against the frame's
    /// time (docs/frame_timing.md, the 120 FPS standard). A frame that ends late starts the next
    /// at once.
    fn bench(&mut self, secs: f64, fps: f64) -> Result<String, String> {
        let period = 1.0 / fps.max(1.0);
        let days0 = self.app.map.as_ref().and_then(|m| m.clock.as_ref()).map_or(0, |c| c.status().days);
        let date0 = self.app.map.as_ref().map_or(String::new(), |m| m.date());
        let mut uploaded = u64::MAX;
        let mut frames: Vec<BenchFrame> = Vec::new();
        let start = std::time::Instant::now();
        let mut next = start;
        while start.elapsed().as_secs_f64() < secs {
            // the frame's start: slept to, the last 2 ms spun (a sleep wakes late, 15 ms on Windows)
            loop {
                let left = next.saturating_duration_since(std::time::Instant::now());
                if left.is_zero() {
                    break;
                }
                if left > std::time::Duration::from_millis(2) {
                    std::thread::sleep(left - std::time::Duration::from_millis(2));
                } else {
                    std::hint::spin_loop();
                }
            }
            let t0 = std::time::Instant::now();
            let gen0 = self.app.map.as_ref().and_then(|m| m.snapshot.as_ref()).map_or(0, |s| s.generation);
            self.app.update();
            let gen1 = self.app.map.as_ref().and_then(|m| m.snapshot.as_ref()).map_or(0, |s| s.generation);
            let t1 = std::time::Instant::now();
            let generation = self.app.prepare()?;
            let t2 = std::time::Instant::now();
            if generation != uploaded {
                let (scene, textures) = self.app.parts().ok_or("no scene")?;
                self.off.upload(scene, textures);
                uploaded = generation;
            }
            let t3 = std::time::Instant::now();
            let (w, h) = self.app.size;
            self.off.draw_frame(w, h, ALL, &mut self.target)?;
            let t4 = std::time::Instant::now();
            frames.push(BenchFrame {
                update: (t1 - t0).as_secs_f64(),
                prepare: (t2 - t1).as_secs_f64(),
                upload: (t3 - t2).as_secs_f64(),
                gpu: (t4 - t3).as_secs_f64(),
                snapshot: gen1 != gen0,
            });
            self.frames += 1;
            next += std::time::Duration::from_secs_f64(period);
            if next < t4 {
                next = t4;
            }
        }
        let wall = start.elapsed().as_secs_f64();
        let days = self.app.map.as_ref().and_then(|m| m.clock.as_ref()).map_or(0, |c| c.status().days) - days0;
        let date = self.app.map.as_ref().map_or(String::new(), |m| m.date());
        let ms = |s: f64| s * 1000.0;
        let pct = |v: &mut Vec<f64>, p: f64| {
            v.sort_by(|a, b| a.partial_cmp(b).unwrap());
            if v.is_empty() { 0.0 } else { v[((v.len() - 1) as f64 * p).round() as usize] }
        };
        let mut total: Vec<f64> = frames.iter().map(|f| f.total()).collect();
        let mut cpu: Vec<f64> = frames.iter().map(|f| f.cpu()).collect();
        let mut gpu: Vec<f64> = frames.iter().map(|f| f.gpu).collect();
        let over = frames.iter().filter(|f| f.total() > period).count();
        let cpu_over = frames.iter().filter(|f| f.cpu() > period).count();
        let snaps: Vec<&BenchFrame> = frames.iter().filter(|f| f.snapshot).collect();
        let worst = frames.iter().copied().fold(BenchFrame::default(), |a, f| if f.total() > a.total() { f } else { a });
        let worst_cpu = frames.iter().copied().fold(BenchFrame::default(), |a, f| if f.cpu() > a.cpu() { f } else { a });
        let snap_max = snaps.iter().map(|f| f.cpu()).fold(0.0, f64::max);
        Ok(format!(
            "{} frames in {wall:.1} s at {fps} FPS ({:.2} ms a frame); frame ms p50 {:.2} p99 {:.2} max {:.2}, over the frame's time {over}; the CPU's part (update, scene, upload) p50 {:.2} p99 {:.2} max {:.2}, over {cpu_over}; the GPU's p50 {:.2} p99 {:.2} max {:.2}; the worst frame update {:.2} scene {:.2} upload {:.2} gpu {:.2}; the worst CPU part update {:.2} scene {:.2} upload {:.2}; {} frames took a new snapshot, their CPU part at most {:.2} ms; {days} days run, {date0} to {date}",
            frames.len(),
            ms(period),
            ms(pct(&mut total, 0.5)),
            ms(pct(&mut total, 0.99)),
            ms(pct(&mut total, 1.0)),
            ms(pct(&mut cpu, 0.5)),
            ms(pct(&mut cpu, 0.99)),
            ms(pct(&mut cpu, 1.0)),
            ms(pct(&mut gpu, 0.5)),
            ms(pct(&mut gpu, 0.99)),
            ms(pct(&mut gpu, 1.0)),
            ms(worst.update),
            ms(worst.prepare),
            ms(worst.upload),
            ms(worst.gpu),
            ms(worst_cpu.update),
            ms(worst_cpu.prepare),
            ms(worst_cpu.upload),
            snaps.len(),
            ms(snap_max),
        ))
    }

    /// Renders the current view: the RGBA pixels and the milliseconds it took (the scene's
    /// build, upload and the GPU's frame).
    pub fn render(&mut self) -> Result<(Vec<u8>, f64), String> {
        let t0 = std::time::Instant::now();
        let (w, h) = self.app.size;
        self.app.prepare()?;
        let (scene, textures) = self.app.parts().ok_or("no scene")?;
        self.off.upload(scene, textures);
        let px = self.off.render(w, h, ALL)?;
        self.frames += 1;
        Ok((px, t0.elapsed().as_secs_f64() * 1000.0))
    }

    fn state(&self) -> String {
        let a = &self.app;
        let view = match (a.screen, a.view) {
            (Screen::Map, MapView::Galaxy) => if a.mode3d { "galaxy".to_string() } else { "2d".to_string() },
            (Screen::Map, MapView::System(i)) => format!("system {}", a.map.as_ref().map_or(0, |m| m.galaxy.systems[i].id)),
            (Screen::Map, MapView::Model) => format!("model {}", a.model.as_deref().unwrap_or("")),
            (s, _) => format!("{s:?}").to_lowercase(),
        };
        let cam = match a.view {
            MapView::Galaxy => a.camera,
            MapView::System(_) | MapView::Model => a.system_camera,
        };
        let camera = cam.map_or("null".to_string(), |c| {
            format!(
                "{{\"target\":[{:.3},{:.3},{:.3}],\"yaw\":{:.3},\"pitch\":{:.3},\"distance\":{:.3}}}",
                c.target.0,
                c.target.1,
                c.target.2,
                c.yaw.to_degrees(),
                c.pitch.to_degrees(),
                c.distance
            )
        });
        let (date, systems, fleets, sim) = a.map.as_ref().map_or(("".to_string(), 0, 0, false), |m| {
            (m.date(), m.galaxy.systems.len(), m.galaxy.fleets.len(), m.clock.as_ref().is_some_and(|c| c.status().ready))
        });
        // the clock: paused, the speed, the simulation's thread (loading, days run, a day's time)
        let clock = a.map.as_ref().map_or("null".to_string(), |m| {
            let s = m.clock.as_ref().map(|c| c.status()).unwrap_or_default();
            format!(
                "{{\"paused\":{},\"speed\":{},\"loading\":{},\"days\":{},\"day_ms\":{:.0},\"snapshot_ms\":{:.0}}}",
                m.paused, m.speed, s.loading, s.days, s.day_ms, s.snapshot_ms
            )
        });
        let selected = match (a.selected, &a.map) {
            (Some(Pickable::System(i)), Some(m)) => format!("\"system {}\"", m.galaxy.systems[i].id),
            (Some(Pickable::Fleet(id)), _) => format!("\"fleet {id}\""),
            (Some(Pickable::Body(id)), _) => format!("\"planet {id}\""),
            (Some(Pickable::Ship(id)), _) => format!("\"ship {id}\""),
            _ => "null".to_string(),
        };
        // the fleets by movement state, and those in an FTL jump (drawn with a trail)
        let mut states: std::collections::BTreeMap<String, usize> = Default::default();
        let mut jumping = 0;
        if let Some(m) = &a.map {
            for f in &m.galaxy.fleets {
                *states.entry(f.state.clone()).or_default() += 1;
                if f.to.is_some() {
                    jumping += 1;
                }
            }
        }
        let states: Vec<String> = states.iter().map(|(k, n)| format!("\"{k}\":{n}")).collect();
        // the input as the commands left it: the pointer, the buttons and keys held, the held
        // actions going on, the timestep
        let c = &a.controls;
        let list = |v: Vec<String>| v.iter().map(|s| format!("\"{s}\"")).collect::<Vec<_>>().join(",");
        let input = format!(
            "{{\"pointer\":{},\"buttons\":[{}],\"keys\":[{}],\"held\":[{}],\"timestep\":{:.3},\"lockstep\":{},\"frame\":{},\"pending\":{}}}",
            c.pointer().map_or("null".to_string(), |(x, y)| format!("[{x},{y}]")),
            list(c.buttons().map(|b| b.name().to_string()).collect()),
            list(c.keys().cloned().collect()),
            list(c.held().iter().map(|h| h.name().to_string()).collect()),
            self.timestep * 1000.0,
            self.lockstep,
            self.frame_no,
            self.pending.len()
        );
        // a new game's load screen: its text and bar, the generation's progress and stage
        let load_screen = a.pending.as_ref().map_or("null".to_string(), |p| {
            let (key, percent) = p.shown();
            format!("{{\"text\":\"{key}\",\"percent\":{percent},\"world_gen\":{},\"stage\":{}}}", p.progress.world_gen(), p.progress.stage())
        });
        format!(
            "{{\"screen\":\"{:?}\",\"load_screen\":{load_screen},\"view\":\"{view}\",\"camera\":{camera},\"date\":\"{date}\",\"clock\":{clock},\"selected\":{selected},\"input\":{input},\"systems\":{systems},\"fleets\":{fleets},\"movement\":{{{}}},\"ftl_trails\":{jumping},\"simulation\":{sim},\"size\":[{},{}],\"frames\":{}}}",
            a.screen,
            states.join(","),
            a.size.0,
            a.size.1,
            self.frames
        )
    }

    /// The game loaded, as `load` replies it: the date, the systems, fleets and countries, the
    /// view.
    fn loaded_line(&self) -> String {
        let Some(m) = self.app.map.as_ref() else { return "no map".into() };
        let view = match self.app.view {
            MapView::System(i) => format!("system {}", m.galaxy.systems[i].id),
            _ => "galaxy".into(),
        };
        format!(
            "date {} systems {} fleets {} countries {} player {} view {view}",
            m.date(),
            m.galaxy.systems.len(),
            m.galaxy.fleets.len(),
            m.galaxy.countries.len(),
            m.galaxy.player
        )
    }

    /// Runs one command line.
    pub fn command(&mut self, line: &str) -> Reply {
        match self.run(line) {
            Ok(r) => r,
            Err(e) => Reply { line: format!("error {e}"), bytes: None, quit: false },
        }
    }

    fn open_designer(&mut self, a: &[&str]) -> Result<Reply, String> {
        use crate::designer::Designer;
        match (a.first().copied(), a.get(1)) {
            (None, _) => self.app.set_designer(Designer { open: true, design: None }),
            (Some("design"), Some(_)) => self.app.set_designer(Designer { open: true, design: Some(num(a.get(1), "id")?) }),
            (Some("combat"), id) => {
                let map = self.app.map.as_ref().ok_or("no map loaded")?;
                let fleet = match id {
                    Some(_) => Some(num(a.get(1), "id")?).filter(|&f| crate::designer::in_combat(map, f)),
                    None => crate::designer::first_in_combat(map),
                };
                let fleet = fleet.ok_or("open_designer: no fleet in combat")?;
                self.app.select(Some(Pickable::Fleet(fleet)));
                self.flush_log();
                return Ok(Reply::ok(format!("open_designer combat {fleet}")));
            }
            (Some("close"), _) => {
                self.app.set_designer(Designer::default());
                if matches!(self.app.selected, Some(Pickable::Fleet(_))) {
                    self.app.select(None);
                }
            }
            // a designer or combat view button's action (designer:...), as its click does it
            (Some("action"), Some(act)) if act.starts_with("designer:") => {
                let act = act.to_string();
                self.app.action(&act)?;
                let lines = self.flush_log();
                return Ok(Reply::ok(format!("open_designer action {act} ({})", lines.join("; "))));
            }
            other => return Err(format!("open_designer {other:?}: [design ID | combat [FLEET] | action designer:... | close]")),
        }
        self.flush_log();
        Ok(Reply::ok(format!("open_designer {}", a.join(" "))))
    }

    fn system_index(&self, id: u32) -> Result<usize, String> {
        let m = self.app.map.as_ref().ok_or("no map loaded")?;
        m.galaxy.systems.iter().position(|s| s.id == id).ok_or(format!("no system {id}"))
    }

    fn run(&mut self, line: &str) -> Result<Reply, String> {
        let words: Vec<&str> = line.split_whitespace().collect();
        let Some(&verb) = words.first() else { return Ok(Reply::ok("")) };
        let a = &words[1..];
        let rest = line.trim_start()[verb.len()..].trim();
        match verb {
            // `console Effect WORDS...`: the game console's effect, as the headless game's `console
            // Effect` (one command file for both): `effect`
            "console" if a.first().copied() == Some("Effect") => {
                let words = rest["Effect".len()..].trim();
                let code = format!("return require('render.windows.console_effect').run({words:?})");
                self.app.fleet_run(&code).map(|r| Reply::ok(format!("console {r}")))
            }
            "console" => {
                // the load screens' console (console.rs): `console on|off`
                let on = match a.first().copied() {
                    Some("on") => true,
                    Some("off") => false,
                    _ => return Err("console on|off".into()),
                };
                self.app.set_console(on);
                Ok(Reply::ok(format!("console {}", if on { "on" } else { "off" })))
            }
            "load-sim" if a.first().copied() == Some("async") => {
                // a save loaded behind the load screen, as the window's Load does; `loaded` waits
                let path = rest["async".len()..].trim();
                self.app.start_load_save(path)?;
                Ok(Reply::ok(format!("load-sim async {path}")))
            }
            "load" | "load-sim" => {
                let t0 = std::time::Instant::now();
                self.app.load_as(rest, verb == "load-sim")?;
                let m = self.app.map.as_ref().unwrap();
                Ok(Reply::ok(format!(
                    "load {} {:.1} s {} systems {} fleets {}",
                    m.date(),
                    t0.elapsed().as_secs_f64(),
                    m.galaxy.systems.len(),
                    m.galaxy.fleets.len(),
                    if verb == "load-sim" { "simulation" } else { "world" }
                )))
            }
            "newgame" => {
                // `newgame [async] KEY=VALUE ... [empire=DESIGN]` (newgame.rs): the load screen
                // shown while the game is made; without `async` the reply waits for the game
                let wait = a.first().copied() != Some("async");
                let words: Vec<&str> = a.iter().copied().filter(|w| *w != "async").collect();
                let settings = crate::newgame::NewGameSettings::parse(&words)?;
                let described = settings.describe();
                self.app.start_new_game(settings)?;
                if !wait {
                    return Ok(Reply::ok(format!("newgame async {described}")));
                }
                let took = self.app.finish_loading()?;
                self.flush_log();
                Ok(Reply::ok(format!("newgame {} {took} {}", described, self.loaded_line())))
            }
            "loaded" => {
                // waits for the new game in progress (`newgame async`)
                if self.app.pending.is_none() {
                    return Err("no new game in progress".into());
                }
                let took = self.app.finish_loading()?;
                self.flush_log();
                Ok(Reply::ok(format!("loaded {took} {}", self.loaded_line())))
            }
            "step" => {
                let days: u64 = num(a.first(), "days")?;
                let r = self.app.step(days)?;
                Ok(Reply::ok(format!("step {r}")))
            }
            "view" => match a.first().copied() {
                Some("galaxy") | Some("3d") => {
                    self.app.mode3d = true;
                    self.app.show_galaxy();
                    Ok(Reply::ok("view galaxy"))
                }
                Some("2d") => {
                    self.app.mode3d = false;
                    self.app.show_galaxy();
                    Ok(Reply::ok("view 2d"))
                }
                Some("system") => {
                    let id: u32 = num(a.get(1), "system id")?;
                    let i = self.system_index(id)?;
                    self.app.show_system(i)?;
                    Ok(Reply::ok(format!("view system {id}")))
                }
                Some("model") => {
                    let name = a.get(1).copied().ok_or("view model ENTITY|PDXMESH")?;
                    self.app.show_model(name)?;
                    let log = self.flush_log();
                    Ok(Reply::ok(format!("view model {name}{}", if log.is_empty() { String::new() } else { format!(" ({})", log.join("; ")) })))
                }
                Some("menu") => {
                    self.app.perform(Action::Back)?;
                    self.app.perform(Action::Back)?;
                    Ok(Reply::ok(format!("view {:?}", self.app.screen).to_lowercase()))
                }
                other => Err(format!("view {other:?}: galaxy, system ID, model NAME, 2d, 3d or menu")),
            },
            "focus" => {
                let id: u32 = num(a.get(1), "id")?;
                let m = self.app.map.as_ref().ok_or("no map loaded")?;
                let (x, y, what) = match a.first().copied() {
                    Some("system") => {
                        let s = &m.galaxy.systems[self.system_index(id)?];
                        (s.x, s.y, "system")
                    }
                    Some("fleet") => {
                        let f = m.galaxy.fleets.iter().find(|f| f.id == id).ok_or(format!("no fleet {id}"))?;
                        (f.x, f.y, "fleet")
                    }
                    other => return Err(format!("focus {other:?}: system ID or fleet ID")),
                };
                self.app.show_galaxy();
                if let Some(mut c) = self.app.camera {
                    c.target = V3(x, 0.0, y);
                    c.distance = c.distance.min(180.0).max(c.min_distance);
                    self.app.set_camera(c);
                }
                Ok(Reply::ok(format!("focus {what} {id} at {x:.1} {y:.1}")))
            }
            "camera" => {
                if a.len() < 6 {
                    return Err("camera X Y Z YAW PITCH DISTANCE".into());
                }
                let v: Vec<f32> = a.iter().take(6).map(|s| s.parse::<f32>()).collect::<Result<_, _>>().map_err(|_| "camera: not a number")?;
                let mut c = match self.app.view {
                    MapView::Galaxy => self.app.camera,
                    MapView::System(_) | MapView::Model => self.app.system_camera,
                }
                .unwrap_or_else(|| OrbitCamera::galaxy(500.0));
                c.target = V3(v[0], v[1], v[2]);
                c.yaw = v[3].to_radians();
                // as the game's headless `camera`: set as given (the limits widened to it)
                c.pitch = v[4].to_radians();
                c.distance = v[5].max(1e-3);
                c.min_pitch = c.min_pitch.min(c.pitch);
                c.max_pitch = c.max_pitch.max(c.pitch);
                c.min_distance = c.min_distance.min(c.distance);
                c.max_distance = c.max_distance.max(c.distance);
                self.app.set_camera(c);
                Ok(Reply::ok("camera"))
            }
            "gui" => {
                let on = a.first().copied() != Some("off");
                let m = self.app.map.as_mut().ok_or("no map loaded")?;
                m.gui = on;
                self.app.invalidate();
                Ok(Reply::ok(format!("gui {}", if on { "on" } else { "off" })))
            }
            // a starbase's window, as headless.c's `open_starbase` (starbase.rs)
            "open_starbase" => crate::starbase::command(&mut self.app, &a).map(Reply::ok),
            "event" => {
                // the open player events, or one's window opened (headless.c serves it too): events.rs
                let r = crate::events::command(&mut self.app, rest)?;
                Ok(Reply::ok(r))
            }
            "open_view" => {
                // a left bar button's view toggled (headless.c serves it too): views.rs; with KEY
                // VALUE after the name, the view open with that state (`open_view technology
                // select physics`: its select_window, as headless.c's CTechnologyView::Show)
                match (a.first(), a.get(1), a.get(2)) {
                    (Some(name), Some(key), Some(value)) => {
                        if self.app.open_view.as_deref() != Some(*name) {
                            self.app.toggle_view(name);
                        }
                        self.app.view_state.clear();
                        self.app.set_view_state(&[(*key, *value)]);
                        self.flush_log();
                        Ok(Reply::ok(format!("open_view {}", a.join(" "))))
                    }
                    (Some(name), _, _) => {
                        let shown = self.app.toggle_view(name);
                        self.flush_log();
                        Ok(Reply::ok(format!("open_view {name} {}", if shown { "shown" } else { "hidden" })))
                    }
                    _ => Err("open_view NAME [KEY VALUE]".into()),
                }
            }
            "open_diplomacy" => {
                // the diplomacy windows (headless.c serves it too, with the game's own calls):
                // contacts, country ID, community, federation ID, war ID, close
                // (contacts TAB: 0 contacts, 1 agreements, 2 the shroud, as CGalaxyView::Show)
                if let ["contacts", tab] = a {
                    if self.app.diplomacy.open != Some(crate::diplomacy::Open::Contacts) {
                        self.app.action("view:contacts")?;
                    }
                    let name = match *tab {
                        "1" => "agreements",
                        "2" => "shroud",
                        _ => "contacts",
                    };
                    self.app.action(&format!("diplo:tab:{name}"))?;
                    self.flush_log();
                    return Ok(Reply::ok(format!("open_diplomacy {rest}")));
                }
                let action = match a {
                    ["contacts"] => "view:contacts".to_string(),
                    ["close"] => "diplo:close".to_string(),
                    ["community"] => "diplo:community".to_string(),
                    [what @ ("country" | "federation" | "war"), id] => format!("diplo:{what}:{id}"),
                    [what @ ("select" | "tab" | "sort" | "action" | "filter" | "zoom" | "peace" | "member"), v] => format!("diplo:{what}:{v}"),
                    // the picked action proposed (its Confirm button), whether or not the list offers it
                    ["confirm"] => "diplo:action_confirm".to_string(),
                    // a war's selected peace option sent (Send Offer)
                    ["peace_send"] => "diplo:peace_send".to_string(),
                    // a leave's yes/no popup answered
                    [ans @ ("confirm_yes" | "confirm_no")] => format!("diplo:{ans}"),
                    // an object of the world as the save writes it (the tests' comparisons)
                    ["inspect", kind, id] => format!("diplo:inspect:{kind}:{id}"),
                    _ => return Err("open_diplomacy contacts|country ID|community|federation ID|war ID|close (or select ID, tab NAME, sort NAME, action KEY, confirm, filter NAME, zoom ID, peace OPTION, peace_send, member VERB, confirm_yes, confirm_no, inspect KIND ID)".into()),
                };
                // (the left bar's button toggles Contacts; the command opens it)
                if action == "view:contacts" && self.app.diplomacy.open == Some(crate::diplomacy::Open::Contacts) {
                    return Ok(Reply::ok("open_diplomacy contacts"));
                }
                self.app.action(&action)?;
                // what it did (the log: a proposal's answer and its terms), in the reply
                let lines = self.flush_log();
                Ok(Reply::ok(if lines.is_empty() { format!("open_diplomacy {rest}") } else { format!("open_diplomacy {rest} ({})", lines.join("; ")) }))
            }
            "observe" => {
                // the game's console `observe` (headless.c serves it too): the player an observer
                let m = self.app.map.as_mut().ok_or("no map loaded")?;
                m.set_observe();
                self.app.invalidate();
                Ok(Reply::ok("observe: Now observing"))
            }
            "pause" => {
                // `pause` (as the game's headless: the clock stopped), `pause off` runs it
                let on = a.first().copied() != Some("off");
                self.app.set_paused(on)?;
                self.flush_log();
                Ok(Reply::ok(if on { "pause" } else { "pause off" }))
            }
            "wait" => {
                // real time passes (the clock runs on its own thread while unpaused)
                let s: f64 = num(a.first(), "seconds")?;
                if self.lockstep {
                    // that many frames of the timestep, as the game's in lockstep
                    let n = self.frames_of(s)?;
                    self.tick(n)?;
                } else {
                    std::thread::sleep(std::time::Duration::from_secs_f64(s.clamp(0.0, 600.0)));
                    self.app.update();
                }
                Ok(Reply::ok(format!("wait {s} date {}", self.app.map.as_ref().map_or(String::new(), |m| m.date()))))
            }
            "speed" => {
                let s: u8 = num(a.first(), "speed")?;
                if !(1..=crate::clock::SPEEDS).contains(&s) {
                    return Err(format!("speed 1..{}", crate::clock::SPEEDS));
                }
                self.app.set_speed(s)?;
                self.flush_log();
                Ok(Reply::ok(format!("speed {s}")))
            }
            "select" => {
                let what = match (a.first().copied(), a.get(1)) {
                    (Some("none"), _) | (None, _) => None,
                    (Some("system"), Some(_)) => Some(Pickable::System(self.system_index(num(a.get(1), "id")?)?)),
                    (Some("fleet"), Some(_)) => Some(Pickable::Fleet(num(a.get(1), "id")?)),
                    (Some("planet"), Some(_)) => Some(Pickable::Body(num(a.get(1), "id")?)),
                    (Some("ship"), Some(_)) => Some(Pickable::Ship(num(a.get(1), "id")?)),
                    other => return Err(format!("select {other:?}: system ID, fleet ID, planet ID, ship ID or none")),
                };
                self.app.select(what);
                self.flush_log();
                Ok(Reply::ok(format!("select {}", a.join(" "))))
            }
            "open" => {
                let id = a.get(1).and_then(|v| v.parse::<u32>().ok());
                let r = self.app.fleet_open(a.first().copied().unwrap_or(""), id)?;
                self.flush_log();
                Ok(Reply::ok(r))
            }
            // the game's headless `open_designer` (headless.c): the ship designer (CShipDesignerBase::
            // Show, no design loaded; `design ID` loads one), a fleet in combat selected (the combat
            // view: the first in combat without ID), `close`
            "open_designer" => self.open_designer(a),
            "open_planet" => {
                // the planet view (planet.rs; headless.c serves it too): `open_planet ID [TAB]`,
                // `open_planet close`
                if a.first().copied() == Some("close") {
                    self.app.select(None);
                    self.flush_log();
                    return Ok(Reply::ok("open_planet close"));
                }
                // `open_planet act ACTION`: a `planet:` action as its button sends it (planet.rs act),
                // the reply the simulation's answer to a command
                if a.first().copied() == Some("act") {
                    let action = rest["act".len()..].trim().to_string();
                    crate::planet::act(&mut self.app, &action)?;
                    crate::planet::run_pending(&mut self.app)?;
                    self.app.scene()?;
                    self.flush_log();
                    return Ok(Reply::ok(format!("open_planet act {action}: {}", self.app.planet_view.last)));
                }
                let id: u32 = num(a.first(), "planet id")?;
                // without a tab the window keeps its own (the game's `open_planet ID` too)
                let tab = a.get(1).copied().unwrap_or(self.app.planet_view.tab.as_str()).to_string();
                let tab = if tab.is_empty() { "summary".to_string() } else { tab };
                // `colonize`: the planet view's colonize button (the colonize window); `resettle`:
                // its resettle button (no window unless the player has two colonies: render.windows.planet)
                let button = tab == "colonize" || tab == "resettle";
                let keep = if self.app.planet_view.tab.is_empty() { "summary".to_string() } else { self.app.planet_view.tab.clone() };
                self.app.open_planet(id, if button { &keep } else { &tab })?;
                if tab == "colonize" {
                    self.app.planet_view.colonize = Some(id);
                    self.app.invalidate();
                }
                // laid out now: what went wrong in the reply
                self.app.scene()?;
                let log: Vec<String> = self.flush_log().into_iter().filter(|l| l.starts_with("windows:")).collect();
                Ok(Reply::ok(format!("open_planet {id} {tab}{}", if log.is_empty() { String::new() } else { format!(" ({})", log.join("; ")) })))
            }
            "orbit" => {
                self.app.orbit(num(a.first(), "dyaw")?, num(a.get(1), "dpitch")?);
                Ok(Reply::ok("orbit"))
            }
            "zoom" => {
                self.app.zoom(num(a.first(), "factor")?);
                Ok(Reply::ok("zoom"))
            }
            "pan" => {
                self.app.pan(num(a.first(), "dx")?, num(a.get(1), "dy")?);
                Ok(Reply::ok("pan"))
            }
            "resize" => {
                let (w, h): (u32, u32) = (num(a.first(), "width")?, num(a.get(1), "height")?);
                if w == 0 || h == 0 || w > 8192 || h > 8192 {
                    return Err("resize: 1..8192".into());
                }
                self.app.resize(w, h);
                Ok(Reply::ok(format!("resize {w} {h}")))
            }
            "timestep" => {
                if a.first().copied() == Some("off") {
                    self.lockstep = false;
                    self.app.smooth = false;
                    self.take_pending()?;
                    return Ok(Reply::ok("timestep off"));
                }
                let ms: f32 = num(a.first(), "ms")?;
                if !(ms > 0.0 && ms <= 1000.0) {
                    return Err("timestep MS (0 < MS <= 1000) or timestep off".into());
                }
                self.timestep = ms / 1000.0;
                self.lockstep = true;
                self.app.smooth = true;
                Ok(Reply::ok(format!("timestep {ms:.3}")))
            }
            "tick" | "frames" => {
                let n: u64 = num(a.first(), "frames")?;
                self.tick(n.min(1_000_000))?;
                Ok(Reply::ok(format!("tick {n} frame {}", self.frame_no)))
            }
            "bindings" => {
                let d = self.app.controls.describe();
                Ok(Reply::ok(format!("bindings {}: {}", d.len(), d.join("; "))))
            }
            "key" => {
                // key CHORD [down|up|tap]: tap (the default) presses and releases in one frame
                let c = controls::chord(a.first().ok_or("key CHORD [down|up|tap]")?)?;
                let how = a.get(1).copied().unwrap_or("tap");
                match how {
                    "down" => self.feed_all(controls::chord_inputs(&c, true))?,
                    "up" => self.feed_all(controls::chord_inputs(&c, false))?,
                    "tap" => {
                        self.feed_all(controls::chord_inputs(&c, true))?;
                        self.feed_all(controls::chord_inputs(&c, false))?;
                    }
                    other => return Err(format!("key {c}: {other}? down, up or tap")),
                }
                Ok(self.reply_input(format!("key {c} {how} frame {}", self.frame_no)))
            }
            "hold" => {
                // hold CHORD DURATION: pressed, DURATION's frames run, released
                let c = controls::chord(a.first().ok_or("hold CHORD FRAMES|Nf|Nms|Ns")?)?;
                let n = self.duration(a.get(1).ok_or("hold CHORD FRAMES|Nf|Nms|Ns")?)?;
                self.feed_all(controls::chord_inputs(&c, true))?;
                self.tick(n)?;
                self.feed_all(controls::chord_inputs(&c, false))?;
                Ok(self.reply_input(format!("hold {c} {n} frames frame {}", self.frame_no)))
            }
            "mouse" | "move" => {
                // mouse X Y [BUTTON [down|up]]: the pointer to the pixel; a button alone clicks
                let (x, y): (f32, f32) = (num(a.first(), "x")?, num(a.get(1), "y")?);
                self.feed(Input::Move { x, y })?;
                if let Some(b) = a.get(2) {
                    let button = Button::parse(b).ok_or(format!("mouse: button {b}"))?;
                    let how = a.get(3).copied();
                    if how != Some("up") {
                        self.feed(Input::Button { button, down: true })?;
                    }
                    if how != Some("down") {
                        self.feed(Input::Button { button, down: false })?;
                    }
                }
                Ok(self.reply_input(format!("{verb} {x} {y} frame {}", self.frame_no)))
            }
            "button" => {
                // button BUTTON down|up [X Y]
                let usage = "button left|right|middle down|up [X Y]";
                let button = Button::parse(a.first().ok_or(usage)?).ok_or(usage)?;
                let down = match a.get(1).copied() {
                    Some("down") => true,
                    Some("up") => false,
                    _ => return Err(usage.into()),
                };
                if a.len() >= 4 {
                    self.feed(Input::Move { x: num(a.get(2), "x")?, y: num(a.get(3), "y")? })?;
                }
                self.feed(Input::Button { button, down })?;
                Ok(self.reply_input(format!("button {} {} frame {}", button.name(), if down { "down" } else { "up" }, self.frame_no)))
            }
            "click" => {
                // click X Y [BUTTON] [double]: pressed and released there (twice: a double click)
                let (x, y): (f32, f32) = (num(a.first(), "x")?, num(a.get(1), "y")?);
                let button = a.get(2).and_then(|b| Button::parse(b)).unwrap_or(Button::Left);
                let double = a[2..].contains(&"double");
                self.feed(Input::Move { x, y })?;
                for _ in 0..if double { 2 } else { 1 } {
                    self.feed(Input::Button { button, down: true })?;
                    self.feed(Input::Button { button, down: false })?;
                }
                Ok(self.reply_input(format!("click {x} {y}{} frame {}", if double { " double" } else { "" }, self.frame_no)))
            }
            "wheel" | "scroll" => {
                // wheel NOTCHES [X Y]: a notch a frame (the game zooms by a frame's last), > 0 in
                let n: f32 = num(a.first(), "notches")?;
                if a.len() >= 3 {
                    self.feed(Input::Move { x: num(a.get(1), "x")?, y: num(a.get(2), "y")? })?;
                }
                let k = n.abs().round() as u64;
                for i in 0..k {
                    self.feed(Input::Wheel { notches: n.signum() })?;
                    if i + 1 < k {
                        self.tick(1)?;
                    }
                }
                Ok(self.reply_input(format!("{verb} {} frame {}", k as i64 * n.signum() as i64, self.frame_no)))
            }
            "drag" => {
                // drag BUTTON X0 Y0 X1 Y1 [STEPS [FRAMES]]: pressed at the start, FRAMES frames,
                // then STEPS moves along the line (whole pixels) each followed by FRAMES frames,
                // released at the end
                let usage = "drag BUTTON X0 Y0 X1 Y1 [STEPS [FRAMES]]";
                let button = Button::parse(a.first().ok_or(usage)?).ok_or(usage)?;
                let p: Vec<i64> = a[1..].iter().take(6).map(|v| v.parse::<i64>()).collect::<Result<_, _>>().map_err(|_| usage)?;
                if p.len() < 4 {
                    return Err(usage.into());
                }
                let (steps, frames) = (p.get(4).copied().unwrap_or(10), p.get(5).copied().unwrap_or(1));
                if steps < 1 || frames < 1 {
                    return Err(usage.into());
                }
                self.feed(Input::Move { x: p[0] as f32, y: p[1] as f32 })?;
                self.feed(Input::Button { button, down: true })?;
                self.tick(frames as u64)?;
                for i in 1..=steps {
                    // as headless.c computes it (C's integer division)
                    let x = p[0] + (p[2] - p[0]) * i / steps;
                    let y = p[1] + (p[3] - p[1]) * i / steps;
                    self.feed(Input::Move { x: x as f32, y: y as f32 })?;
                    self.tick(frames as u64)?;
                }
                self.feed(Input::Button { button, down: false })?;
                Ok(self.reply_input(format!("drag to {} {} frame {}", p[2], p[3], self.frame_no)))
            }
            "frame" => {
                let target = a.first().copied().ok_or("frame PATH.png or frame -")?;
                // `now`: as it is; else in lockstep the camera arrives first, as the game's
                // `frame` waits for its picture to settle
                let now = a.get(1).copied() == Some("now");
                let rest = rest.strip_suffix("now").map_or(rest, |r| if now { r.trim_end() } else { rest });
                if self.lockstep && !now {
                    self.take_pending()?;
                    let mut n = 0;
                    while (n < 2 || self.app.camera_moving()) && n < 3000 {
                        self.tick(1)?;
                        n += 1;
                    }
                }
                let (px, ms) = self.render()?;
                let (w, h) = self.app.size;
                if target == "-" {
                    let tmp = std::env::temp_dir().join(format!("stellar-render-{}.png", std::process::id()));
                    let tmp = tmp.to_string_lossy().into_owned();
                    verify::write_png(&tmp, w, h, &px)?;
                    let bytes = std::fs::read(&tmp).map_err(|e| e.to_string())?;
                    let _ = std::fs::remove_file(&tmp);
                    return Ok(Reply { line: format!("ok frame - {w} {h} {ms:.0} {}", bytes.len()), bytes: Some(bytes), quit: false });
                }
                verify::write_png(rest, w, h, &px)?;
                Ok(Reply::ok(format!("frame {rest} {w} {h} {ms:.0}")))
            }
            "bench" => {
                let secs: f64 = num(a.first(), "seconds")?;
                let fps: f64 = if a.len() > 1 { num(a.get(1), "fps")? } else { 120.0 };
                let r = self.bench(secs.clamp(0.1, 600.0), fps)?;
                Ok(Reply::ok(format!("bench {r}")))
            }
            "state" => Ok(Reply::ok(self.state())),
            // `effect WORDS...`: the console's effect in the simulation (render.windows.console_effect),
            // as the headless game's `effect`: a test's setup made the same way on both sides
            "effect" => {
                let code = format!("return require('render.windows.console_effect').run({rest:?})");
                self.app.fleet_run(&code).map(Reply::ok)
            }
            // `fleet_cmd CALL`: a render.windows.fleet_commands call in the simulation (fleetwin.rs:
            // `fleet_cmd .debug(1)`, `fleet_cmd ["stop"](3)`), its reply
            "fleet_cmd" => self.app.fleet_command(rest).map(|r| Reply::ok(format!("fleet_cmd {r}"))),
            "quit" => Ok(Reply { line: "ok quit".into(), bytes: None, quit: true }),
            other => Err(format!("unknown command {other:?}")),
        }
    }

    fn flush_log(&mut self) -> Vec<String> {
        // (into the load screens' console here: these go into the replies, not to stderr, so
        // eprintln!'s copy does not take them)
        let lines: Vec<String> = self.app.log.drain(..).collect();
        for l in &lines {
            crate::console::push(l);
        }
        lines
    }

    /// Input for the app: in lockstep kept for the next frame; else taken at once (the polled
    /// part too: a frame of no time).
    fn feed(&mut self, input: Input) -> Result<(), String> {
        if self.lockstep {
            self.pending.push(input);
            return Ok(());
        }
        self.app.input(&input, self.clock_ms)?;
        self.app.advance(0.0);
        Ok(())
    }

    fn feed_all(&mut self, inputs: Vec<Input>) -> Result<(), String> {
        inputs.into_iter().try_for_each(|i| self.feed(i))
    }

    /// The input given since the last frame, taken (the game's next frame's events).
    fn take_pending(&mut self) -> Result<(), String> {
        for i in std::mem::take(&mut self.pending) {
            self.app.input(&i, self.clock_ms)?;
        }
        Ok(())
    }

    /// `n` frames of the timestep: each the app's update (the camera's), then the input given
    /// before it taken (in the game: injected during frame f, its events reach frame f + 1).
    fn tick(&mut self, n: u64) -> Result<(), String> {
        for _ in 0..n {
            self.app.advance(self.timestep);
            self.frame_no += 1;
            self.clock_ms += self.timestep as f64 * 1000.0;
            self.take_pending()?;
        }
        Ok(())
    }

    /// A duration's frames: `N`, `Nf` frames; `Nms`, `Ns` time, in frames of the timestep.
    fn duration(&self, s: &str) -> Result<u64, String> {
        let bad = || format!("{s}: a duration: N, Nf, Nms or Ns");
        if let Some(v) = s.strip_suffix("ms") {
            return self.frames_of(v.parse::<f64>().map_err(|_| bad())? / 1000.0);
        }
        if let Some(v) = s.strip_suffix('s') {
            return self.frames_of(v.parse::<f64>().map_err(|_| bad())?);
        }
        s.strip_suffix('f').unwrap_or(s).parse::<u64>().map_err(|_| bad())
    }

    fn frames_of(&self, secs: f64) -> Result<u64, String> {
        if !(0.0..=3600.0).contains(&secs) {
            return Err(format!("{secs} s: 0 to 3600"));
        }
        Ok((secs / self.timestep as f64).round() as u64)
    }

    /// An input command's reply, with what the app logged (clicks, actions not done).
    fn reply_input(&mut self, line: String) -> Reply {
        let log = self.flush_log();
        Reply::ok(if log.is_empty() { line } else { format!("{line} ({})", log.join("; ")) })
    }
}

/// Runs a script's commands, printing each reply.
pub fn run_script(engine: &mut Engine, path: &str) -> Result<(), String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let r = engine.command(line);
        println!("> {line}\n{}", r.line);
        if r.quit {
            break;
        }
    }
    Ok(())
}

/// Serves the protocol on `addr` until a client sends `quit`.
pub fn serve(engine: &mut Engine, addr: &str) -> Result<(), String> {
    let listener = std::net::TcpListener::bind(addr).map_err(|e| format!("listen {addr}: {e}"))?;
    eprintln!("listening on {}", listener.local_addr().map_err(|e| e.to_string())?);
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("accept: {e}");
                continue;
            }
        };
        let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_default();
        eprintln!("client {peer}");
        let mut out = stream.try_clone().map_err(|e| e.to_string())?;
        let reader = BufReader::new(stream);
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let line = line.trim().to_string();
            if line.is_empty() {
                continue;
            }
            let r = engine.command(&line);
            eprintln!("{peer} > {line} -> {}", r.line);
            if out.write_all(format!("{}\n", r.line).as_bytes()).is_err() {
                break;
            }
            if let Some(b) = &r.bytes {
                if out.write_all(b).is_err() {
                    break;
                }
            }
            let _ = out.flush();
            if r.quit {
                return Ok(());
            }
        }
        eprintln!("client {peer} gone");
    }
    Ok(())
}
