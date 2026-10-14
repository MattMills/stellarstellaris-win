//! The renderer without a window, driven by commands: from a script (`--script FILE`) or over TCP
//! (`--listen ADDR:PORT`, or STELLAR_RENDER_LISTEN; localhost unless an address is given). One
//! command per line, one reply per command, sent after the change or the frame is complete, so a
//! client can script an exact sequence of shots. Replies are one line: `ok ...` or `error ...`;
//! `frame -` replies `ok frame - W H MS BYTES` and then the PNG's bytes.
//!
//! Commands (angles in degrees, positions in map units):
//! - `load PATH` (the save's world), `load-sim PATH` (as a running simulation), `step DAYS`
//! - `view galaxy`, `view system ID` (the save's system id), `view model NAME` (an entity or a
//!   pdxmesh of gfx/models alone), `view menu`, `view 2d`, `view 3d`
//! - `focus system ID`, `focus fleet ID`: the galaxy camera over it
//! - `camera X Y Z YAW PITCH DISTANCE` (the target on the plane is X, Z = the map's x, y),
//!   `orbit DYAW DPITCH`, `zoom FACTOR` (< 1 closer), `pan DX DY` (fractions of the distance)
//! - `resize W H`
//! - `key NAME down|up`, `mouse X Y [left|right down|up]`, `scroll DY`
//! - `frame PATH.png` (renders the view, writes the PNG: `ok frame PATH W H MS`), `frame -`
//! - `state` (JSON: screen, view, camera, date, size), `quit`

use std::io::{BufRead, BufReader, Write};

use crate::app::{App, MapView, Screen};
use crate::camera::OrbitCamera;
use crate::math::V3;
use crate::render::{Backend, Offscreen};
use crate::scene::ALL;
use crate::verify;

pub struct Engine {
    pub app: App,
    pub off: Offscreen,
    pub frames: u64,
    mouse: (f32, f32),
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
        let app = App::new(game_dir, size)?;
        let off = Offscreen::new(backend, adapter)?;
        eprintln!("rendering on: {}", off.adapter);
        Ok(Engine { app, off, frames: 0, mouse: (0.0, 0.0) })
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
            (m.date(), m.galaxy.systems.len(), m.galaxy.fleets.len(), matches!(m.source, crate::Source::Sim(_)))
        });
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
        format!(
            "{{\"screen\":\"{:?}\",\"view\":\"{view}\",\"camera\":{camera},\"date\":\"{date}\",\"systems\":{systems},\"fleets\":{fleets},\"movement\":{{{}}},\"ftl_trails\":{jumping},\"simulation\":{sim},\"size\":[{},{}],\"frames\":{}}}",
            a.screen,
            states.join(","),
            a.size.0,
            a.size.1,
            self.frames
        )
    }

    /// Runs one command line.
    pub fn command(&mut self, line: &str) -> Reply {
        match self.run(line) {
            Ok(r) => r,
            Err(e) => Reply { line: format!("error {e}"), bytes: None, quit: false },
        }
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
                    self.app.key("escape")?;
                    self.app.key("escape")?;
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
                if let Some(c) = self.app.camera.as_mut() {
                    c.target = V3(x, 0.0, y);
                    c.distance = c.distance.min(180.0).max(c.min_distance);
                }
                self.app.invalidate();
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
                c.pitch = v[4].to_radians().clamp(c.min_pitch, c.max_pitch);
                c.distance = v[5].clamp(c.min_distance, c.max_distance);
                self.app.set_camera(c);
                Ok(Reply::ok("camera"))
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
            "key" => {
                let name = a.first().ok_or("key NAME [down|up]")?.to_lowercase();
                // a key acts when pressed
                if a.get(1).copied() != Some("up") {
                    let changed = self.app.key(&name)?;
                    self.flush_log();
                    return Ok(Reply::ok(format!("key {name} {}", if changed { "acted" } else { "nothing" })));
                }
                Ok(Reply::ok(format!("key {name} up")))
            }
            "mouse" => {
                let (x, y): (f32, f32) = (num(a.first(), "x")?, num(a.get(1), "y")?);
                self.mouse = (x, y);
                self.app.mouse_move(x, y)?;
                if let Some(&button) = a.get(2) {
                    match (button, a.get(3).copied()) {
                        ("left", Some("down")) => {
                            self.app.mouse_down(x, y)?;
                        }
                        ("left", Some("up")) | ("left", None) => {
                            if a.get(3).is_none() {
                                self.app.mouse_down(x, y)?;
                            }
                            self.app.mouse_up(x, y)?;
                        }
                        ("right", _) => {}
                        other => return Err(format!("mouse: {other:?}")),
                    }
                }
                let log = self.flush_log();
                Ok(Reply::ok(format!("mouse {x} {y}{}", if log.is_empty() { String::new() } else { format!(" {}", log.join("; ")) })))
            }
            "scroll" => {
                let dy: f32 = num(a.first(), "dy")?;
                self.app.zoom(0.85f32.powf(dy));
                Ok(Reply::ok("scroll"))
            }
            "frame" => {
                let target = a.first().copied().ok_or("frame PATH.png or frame -")?;
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
            "state" => Ok(Reply::ok(self.state())),
            "quit" => Ok(Reply { line: "ok quit".into(), bytes: None, quit: true }),
            other => Err(format!("unknown command {other:?}")),
        }
    }

    fn flush_log(&mut self) -> Vec<String> {
        self.app.log.drain(..).collect()
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
