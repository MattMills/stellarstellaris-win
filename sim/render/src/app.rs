//! The front end and the map as one application, for the window and for headless runs: the main
//! menu, the load game window over it, and the galaxy map of a loaded save. The mouse moves,
//! presses and releases over the GUI's buttons (whose sprites show their hover and pressed
//! frames); a click does the button's action:
//! - Exit closes; Load Game opens the load window; its Cancel closes it; a save in it loads that
//!   save and shows its home system with the top bar and the outliner, as the game does;
//! - Continue (the key C on the menu: 4.5.2's front end has no Continue button; the launcher
//!   has it) loads the newest save;
//! - New Game, Multiplayer, Cooperative, Additional Content, Settings and Credits do nothing yet
//!   (their windows are not laid out);
//! - on the map: the top bar's time controls run the clock (clock.rs), a click selects (the
//!   outliner's rows too) and opens the selection's window, a double click enters a system or
//!   follows a planet or fleet; the camera moves as the game's (docs/render.md section 12);
//! - Escape clears the selection, leaves a system, goes back to the menu, closes the load window.
//!
//! Input comes as physical input (controls.rs: keys, buttons, the wheel, the pointer) through
//! the bindings to actions: [`App::input`], [`App::perform`].

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Instant;

use stellar_sim::{save, Runtime};

use crate::camera::{self, OrbitCamera};
use crate::clock;
use crate::controls::{Action, Button, Context, Controls, Effect, Input};
use crate::dds::Cache;
use crate::font::Font;
use crate::math::V3;
use crate::models;
use crate::system;
use crate::gui::{self, GuiItem};
use crate::scene::{self, ButtonState, Pickable, Scene, Textures};
use crate::Map;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Screen {
    Menu,
    Load,
    Map,
}

/// A save the load window lists.
#[derive(Clone, Debug)]
pub struct SaveInfo {
    pub path: String,
    pub file: String,
    pub name: String,
    pub date: String,
    pub modified: std::time::SystemTime,
}

/// The saves in the known places, newest first: the folder of STELLAR_SAVE (or of the default
/// save), the user's Stellaris save games (each game's folder), C:\lfm\saves and
/// /opt/stellaris-saves. The empire's name and the date are read from each gamestate's head.
pub fn list_saves() -> Vec<SaveInfo> {
    let mut dirs: Vec<std::path::PathBuf> = Vec::new();
    for p in [std::env::var("STELLAR_SAVE").ok(), save::default_save()].into_iter().flatten() {
        if let Some(d) = std::path::Path::new(&p).parent() {
            dirs.push(d.to_path_buf());
        }
    }
    if let Ok(home) = std::env::var("USERPROFILE") {
        let root = std::path::Path::new(&home).join(r"Documents\Paradox Interactive\Stellaris\save games");
        if let Ok(rd) = std::fs::read_dir(&root) {
            dirs.extend(rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()));
        }
    }
    dirs.push(r"C:\lfm\saves".into());
    dirs.push("/opt/stellaris-saves".into());
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for d in dirs {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if !p.extension().is_some_and(|x| x.eq_ignore_ascii_case("sav")) {
                continue;
            }
            let key = std::fs::canonicalize(&p).unwrap_or(p.clone());
            if !seen.insert(key) {
                continue;
            }
            let path = p.to_string_lossy().into_owned();
            let modified = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
            let file = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
            let (mut name, mut date) = (String::new(), String::new());
            if let Ok(gs) = save::read_gamestate(&path) {
                for line in gs.lines().take(12) {
                    if let Some(v) = line.strip_prefix("name=") {
                        name = v.trim_matches('"').to_string();
                    } else if let Some(v) = line.strip_prefix("date=") {
                        date = v.trim_matches('"').to_string();
                    }
                }
            }
            out.push(SaveInfo { path, file, name, date, modified });
        }
    }
    // newest first: by the game's date, then the file's time
    out.sort_by(|a, b| b.date.cmp(&a.date).then(b.modified.cmp(&a.modified)));
    out
}

/// The game's version, as the launcher's settings give it ("Cygnus v4.5.2 (9776)").
fn game_version(game_dir: &str) -> String {
    let text = std::fs::read_to_string(format!("{game_dir}/launcher-settings.json")).unwrap_or_default();
    text.lines()
        .find_map(|l| l.trim().strip_prefix("\"version\":").map(|v| v.trim().trim_end_matches(',').trim_matches('"').to_string()))
        .unwrap_or_default()
}


pub struct App {
    pub game_dir: String,
    pub runtime: Runtime,
    pub cache: Rc<RefCell<Cache>>,
    pub textures: Textures,
    pub fonts: HashMap<String, Font>,
    pub screen: Screen,
    pub map: Option<Map>,
    pub saves: Option<Vec<SaveInfo>>,
    pub size: (u32, u32),
    pub exit: bool,
    pub version: String,
    /// what happened, for the output
    pub log: Vec<String>,
    /// notes of the last layout (background, saves listed, sprites missing)
    pub notes: Vec<String>,
    /// the map: in 3D from `camera` (else the 2D map), the galaxy or a system; the cameras as
    /// drawn, and where the player's input sends them (the goal they move to smoothly)
    pub mode3d: bool,
    pub camera: Option<OrbitCamera>,
    pub view: MapView,
    pub system_camera: Option<OrbitCamera>,
    camera_goal: Option<OrbitCamera>,
    system_camera_goal: Option<OrbitCamera>,
    /// the cameras move to their goals over time (the window), else at once (commands)
    pub smooth: bool,
    /// the model view: the model shown (an entity or a pdxmesh), and the models read for it
    pub model: Option<String>,
    pub models: models::Library,
    /// what is selected on the map
    pub selected: Option<Pickable>,
    /// the windows over the map for the selection (the outliner, an info window)
    pub overlay_items: Vec<GuiItem>,
    /// the map labels (mapicons.gui) of what the view shows
    pub overlay_labels: Vec<scene::Label>,
    /// the outliner's state: its tab, the groups collapsed (render.windows.outliner)
    pub outliner: crate::outliner::State,
    /// the ship designer (designer.rs) and the ship models of its 3D views, by inset
    pub designer: crate::designer::Designer,
    designer_models: HashMap<String, crate::designer::ShipModel>,
    /// what the windows were laid out for: the size, view, selection, snapshot, GUI shown, paused,
    /// star names' zoom, observing
    overlay_key: Option<(u32, u32, MapView, Option<Pickable>, u64, bool, bool, bool, bool)>,
    /// the player holds the camera (a drag, a turn); the plane's point a drag holds; what the
    /// camera follows; the systems' cameras as they were left; the last system shown
    holding: bool,
    drag_anchor: Option<V3>,
    follow: Option<Pickable>,
    saved_system_cameras: HashMap<u32, OrbitCamera>,
    last_system: Option<usize>,
    /// what the cursor is over, since when (the tooltips' hook: [`Tooltips`])
    pub hovered: Option<(HoverTarget, Instant)>,
    /// the tooltips' text (a later phase: cached through the modifier graph); none yet
    pub tooltips: Option<Box<dyn Tooltips>>,
    hover: Option<String>,
    pressed: Option<String>,
    items: Option<((u32, u32, Screen), Vec<GuiItem>)>,
    /// the scene built (shared with the render thread once published: ui.rs)
    scene: Option<std::sync::Arc<Scene>>,
    generation: u64,
    /// the input's state and the bindings (the held keys' actions move the camera each frame);
    /// the cursor (edge scrolling), the time of the last update
    pub controls: Controls,
    /// the clock's commands of the input, done at the next frame ([`ClockCommand`])
    commands: Vec<ClockCommand>,
    cursor: Option<(f32, f32)>,
    last_update: Option<Instant>,
}

/// What the cursor is over: a GUI element (its path, e.g. "/maingui/topbar_static/
/// tb_energy_group/amount") or something on the map.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HoverTarget {
    Element(String),
    Map(Pickable),
}

/// The tooltips' hook (docs/render.md section 12): the text for what the cursor is over, at the
/// world's date. The next phase implements it over the modifier graph, its texts cached with
/// bounded staleness (about a second or 60 frames); the window shows the text once the cursor
/// has rested on the target (`App::hovered` keeps since when).
pub trait Tooltips {
    fn text(&mut self, target: &HoverTarget, date: &str) -> Option<String>;
}

/// The clock's commands of the input (keys, the top bar's buttons) **[V]**: the game posts them
/// to its session (CPauseGame with !paused, CIncreaseGameSpeedCommand, ...; HandleInputEvent
/// @0x1c85c80) and runs them in the next frame: a key injected in frame f is seen in f + 1 and its
/// clock changed in f + 2 (headless view mode). The pause is the clock's state as it is, negated
/// (two Spaces in one frame pause once); the speed a step each (two presses in one frame: two
/// steps, 3 to 5), within 1..5.
#[derive(Clone, Copy, Debug, PartialEq)]
enum ClockCommand {
    Paused(bool),
    Speed(i8),
    NextDay,
}

/// What the map screen shows.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MapView {
    Galaxy,
    /// a system: its index in the galaxy's systems
    System(usize),
    /// a model alone (App::model), on the map screen with or without a map
    Model,
}

impl App {
    pub fn new(game_dir: &str, size: (u32, u32)) -> Result<App, String> {
        let cache = Rc::new(RefCell::new(Cache::default()));
        let t0 = std::time::Instant::now();
        let (runtime, loc) = gui::frontend_runtime(game_dir, &cache, "english")?;
        let version = game_version(game_dir);
        let log = vec![format!("localisation: {loc}"), format!("front end ready in {:.1} s", t0.elapsed().as_secs_f64())];
        Ok(App {
            game_dir: game_dir.to_string(),
            runtime,
            cache,
            textures: Textures::default(),
            fonts: HashMap::new(),
            screen: Screen::Menu,
            map: None,
            saves: None,
            size,
            exit: false,
            version,
            log,
            notes: Vec::new(),
            mode3d: true,
            camera: None,
            view: MapView::Galaxy,
            system_camera: None,
            camera_goal: None,
            system_camera_goal: None,
            smooth: false,
            model: None,
            models: models::Library::default(),
            selected: None,
            overlay_items: Vec::new(),
            overlay_labels: Vec::new(),
            outliner: Default::default(),
            designer: Default::default(),
            designer_models: HashMap::new(),
            overlay_key: None,
            holding: false,
            drag_anchor: None,
            follow: None,
            saved_system_cameras: HashMap::new(),
            last_system: None,
            hovered: None,
            tooltips: None,
            hover: None,
            pressed: None,
            items: None,
            scene: None,
            generation: 0,
            controls: Controls::from_env()?,
            commands: Vec::new(),
            cursor: None,
            last_update: None,
        })
    }

    /// The camera of what the map shows (the galaxy's or the system's): its goal, where input
    /// moves it.
    fn goal_mut(&mut self) -> Option<&mut OrbitCamera> {
        match self.view {
            MapView::Galaxy => {
                if self.camera_goal.is_none() {
                    self.camera_goal = self.camera;
                }
                self.camera_goal.as_mut()
            }
            MapView::System(_) | MapView::Model => {
                if self.system_camera_goal.is_none() {
                    self.system_camera_goal = self.system_camera;
                }
                self.system_camera_goal.as_mut()
            }
        }
    }

    /// After the goal moved: without smoothing, the camera is there at once.
    fn goal_moved(&mut self) {
        if !self.smooth {
            match self.view {
                MapView::Galaxy => self.camera = self.camera_goal,
                MapView::System(_) | MapView::Model => self.system_camera = self.system_camera_goal,
            }
            self.scene = None;
        }
    }

    /// Moves the camera (degrees), zooms it (a factor), pans it (fractions of its distance).
    pub fn orbit(&mut self, dyaw: f32, dpitch: f32) {
        if let Some(c) = self.goal_mut() {
            c.orbit(dyaw.to_radians(), dpitch.to_radians());
        }
        self.goal_moved();
    }
    pub fn zoom(&mut self, factor: f32) {
        if let Some(c) = self.goal_mut() {
            c.zoom(factor);
        }
        self.goal_moved();
    }
    /// The camera drawn now (the galaxy's or the system's).
    fn current(&self) -> Option<OrbitCamera> {
        match self.view {
            MapView::Galaxy => self.camera,
            MapView::System(_) | MapView::Model => self.system_camera,
        }
    }

    /// The plane's point under the cursor (the screen's centre without one), by the camera drawn.
    fn ground_under_cursor(&self) -> Option<V3> {
        let c = self.current()?;
        let (w, h) = self.size;
        let (x, y) = self.cursor.unwrap_or((w as f32 / 2.0, h as f32 / 2.0));
        Some(c.ground_at(x, y, w, h))
    }

    /// The wheel: `notches` (> 0 in), one zoom step about the point under the cursor.
    pub fn wheel(&mut self, notches: f32) {
        let ground = if self.holding { None } else { self.ground_under_cursor() };
        if let Some(c) = self.goal_mut() {
            c.wheel(notches, ground);
        }
        self.goal_moved();
    }
    pub fn pan(&mut self, dx: f32, dy: f32) {
        self.follow = None;
        if let Some(c) = self.goal_mut() {
            c.pan(dx, dy);
        }
        self.goal_moved();
    }

    /// The right button dragged `dx`, `dy` pixels (UpdateRotation): the pitch by dy, the yaw by
    /// -dx, ROTATION_RADIANS_PER_MOUSE_UNIT a pixel.
    pub fn rotate(&mut self, dx: f32, dy: f32) {
        let k = camera::ROTATION_RADIANS_PER_MOUSE_UNIT;
        if let Some(c) = self.goal_mut() {
            c.orbit(-dx * k, dy * k);
        }
        self.goal_moved();
    }

    /// A drag of the middle button (or both) holds the plane's point grabbed at (x, y) under
    /// the cursor (UpdateDragMovement); `None` ends it.
    pub fn drag(&mut self, at: Option<(f32, f32)>) {
        let (w, h) = self.size;
        let Some((x, y)) = at else {
            self.drag_anchor = None;
            return;
        };
        let Some(cur) = self.current() else { return };
        let p = cur.ground_at(x, y, w, h);
        match self.drag_anchor {
            None => self.drag_anchor = Some(p),
            Some(a) => {
                self.follow = None;
                if let Some(g) = self.goal_mut() {
                    g.target = V3(cur.target.0 + a.0 - p.0, 0.0, cur.target.2 + a.2 - p.2);
                    g.restrict();
                }
                self.goal_moved();
            }
        }
    }

    /// The player holds the camera (a drag or a turn): it moves on the plane at once.
    pub fn set_holding(&mut self, holding: bool) {
        self.holding = holding;
    }

    /// Sets the camera of what the map shows, at once (and its goal).
    pub fn set_camera(&mut self, c: OrbitCamera) {
        match self.view {
            MapView::Galaxy => {
                self.camera = Some(c);
                self.camera_goal = Some(c);
            }
            MapView::System(_) | MapView::Model => {
                self.system_camera = Some(c);
                self.system_camera_goal = Some(c);
            }
        }
        self.scene = None;
    }

    /// Where a followed thing is now (a body or a fleet of the system shown).
    fn followed_position(&mut self) -> Option<V3> {
        let (what, MapView::System(i)) = (self.follow?, self.view) else { return None };
        let map = self.map.as_mut()?;
        let id = map.galaxy.systems[i].id;
        let data = map.system_data(id).ok()?;
        match what {
            Pickable::Body(b) => data.bodies.iter().find(|x| x.id == b).map(|x| V3(x.x, system::PLANE_Y, x.y)),
            Pickable::Fleet(f) => data.ships.iter().find(|s| s.fleet == f).map(|s| V3(s.x, 0.0, s.y)),
            _ => None,
        }
    }

    /// A frame in real time: [`App::advance`] by the time since the last one.
    pub fn update(&mut self) -> bool {
        let now = Instant::now();
        // the frame's time, at most 0.1 s (CGameIdler::Idle)
        let dt = self.last_update.map_or(0.0, |t| (now - t).as_secs_f32()).min(0.1);
        self.last_update = Some(now);
        self.advance(dt)
    }

    /// The app's screen, the bindings' context.
    pub fn context(&self) -> Context {
        match self.screen {
            Screen::Map => Context::Map,
            Screen::Menu => Context::Menu,
            Screen::Load => Context::Load,
        }
    }

    /// A frame of `dt` seconds (the game's camera update): what the controls poll (the drags,
    /// the wheel), the cameras toward their goals, the held keys and the edge scrolling, the
    /// simulation's newest snapshot taken. Whether the picture changed (a frame is due).
    pub fn advance(&mut self, dt: f32) -> bool {
        let mut changed = false;
        // the clock's commands of the last frame's input
        for c in std::mem::take(&mut self.commands) {
            let r = match c {
                ClockCommand::Paused(p) => self.set_paused(p),
                ClockCommand::Speed(d) => {
                    let s = self.map.as_ref().map_or(clock::DEFAULT_SPEED, |m| m.speed) as i8;
                    self.set_speed((s + d).clamp(1, clock::SPEEDS as i8) as u8)
                }
                ClockCommand::NextDay => {
                    if let Some(m) = self.map.as_mut() {
                        m.next_day();
                        self.log.push("clock: the next day".into());
                    }
                    Ok(())
                }
            };
            match r {
                Ok(()) => changed = true,
                Err(e) => self.log.push(format!("clock: {e}")),
            }
        }
        let ctx = self.context();
        for e in self.controls.frame(ctx) {
            match self.apply(e) {
                Ok(c) => changed |= c,
                Err(e) => self.log.push(format!("input: {e}")),
            }
        }
        if self.screen != Screen::Map {
            return changed;
        }
        if let Some(m) = self.map.as_mut() {
            if m.sync() {
                changed = true;
                // the topbar's date, the galaxy, the system's ships
                self.scene = None;
            }
        }
        // a followed planet or fleet: the target on it (RefreshFollowPosition)
        if let Some(p) = self.followed_position() {
            if let Some(g) = self.goal_mut() {
                if g.target != p {
                    g.target = p;
                    changed = true;
                }
            }
            self.goal_moved();
        }
        // the camera's held actions (W A S D, the arrows; diagonals not normalised), the cursor
        // at the screen's edge (toward it from the centre), Page Up and Page Down
        let (mut dx, mut dy, mut zoom) = (0.0f32, 0.0f32, 0.0f32);
        for a in self.controls.held() {
            match a {
                Action::ScrollUp => dy += 1.0,
                Action::ScrollDown => dy -= 1.0,
                Action::ScrollLeft => dx -= 1.0,
                Action::ScrollRight => dx += 1.0,
                Action::ZoomIn => zoom += 1.0,
                Action::ZoomOut => zoom -= 1.0,
                _ => {}
            }
        }
        if let (Some((x, y)), false) = (self.cursor, self.holding) {
            let (cx, cy) = (self.size.0 as f32 / 2.0, self.size.1 as f32 / 2.0);
            let edge = camera::EDGE_SCROLLING_PIXELS;
            if cx - (x - cx).abs() < edge || cy - (y - cy).abs() < edge {
                let l = ((x - cx).powi(2) + (y - cy).powi(2)).sqrt().max(1e-3);
                dx += (x - cx) / l;
                dy -= (y - cy) / l;
            }
        }
        if dt > 0.0 && (dx != 0.0 || dy != 0.0) {
            self.follow = None;
            if let Some(c) = self.goal_mut() {
                c.scroll(dx, dy, dt);
            }
            self.goal_moved();
            changed = true;
        }
        if dt > 0.0 && zoom != 0.0 {
            let d = self.current().map_or(1.0, |c| c.distance);
            if let Some(c) = self.goal_mut() {
                c.zoom_keys(zoom, dt, d);
            }
            self.goal_moved();
            changed = true;
        }
        // the galaxy's yaw back to 0 a frame once the right button is up
        if self.view == MapView::Galaxy && !self.holding && self.smooth {
            if let Some(g) = self.camera_goal.as_mut() {
                if g.spring_yaw() {
                    changed = true;
                }
            }
        }
        if self.smooth && dt > 0.0 {
            let holding = self.holding;
            let (cur, goal) = match self.view {
                MapView::Galaxy => (&mut self.camera, &self.camera_goal),
                MapView::System(_) | MapView::Model => (&mut self.system_camera, &self.system_camera_goal),
            };
            if let (Some(c), Some(g)) = (cur.as_mut(), goal) {
                if c.approach(g, dt, holding) {
                    changed = true;
                }
            }
        }
        if changed {
            self.scene = None;
        }
        changed
    }

    /// Whether frames are due without input: the simulation runs or loads, the camera moves.
    pub fn animating(&self) -> bool {
        if self.screen != Screen::Map {
            return false;
        }
        let running = self.map.as_ref().is_some_and(|m| m.clock.is_some() && (!m.paused || m.clock.as_ref().is_some_and(|c| !c.status().ready)));
        running || self.camera_moving()
    }

    /// Whether the camera moves without input: on its way to its goal (the galaxy's yaw back to
    /// 0), held keys or a drag, the cursor at the edge, a thing followed.
    pub fn camera_moving(&self) -> bool {
        if self.screen != Screen::Map {
            return false;
        }
        let moving = match self.view {
            MapView::Galaxy => matches!((&self.camera, &self.camera_goal), (Some(c), Some(g)) if !c.at(g) || g.yaw != 0.0),
            _ => matches!((&self.system_camera, &self.system_camera_goal), (Some(c), Some(g)) if !c.at(g)),
        };
        let keys = !self.controls.held().is_empty() || self.controls.holding();
        let edge = self.cursor.is_some_and(|(x, y)| {
            let (cx, cy) = (self.size.0 as f32 / 2.0, self.size.1 as f32 / 2.0);
            cx - (x - cx).abs() < camera::EDGE_SCROLLING_PIXELS || cy - (y - cy).abs() < camera::EDGE_SCROLLING_PIXELS
        });
        moving || keys || edge || self.follow.is_some()
    }

    /// Shows the galaxy (CGameCamera::OnLeaveSystem from a system: the camera at its star,
    /// ZOOM_STEPS_GALAXY[LEAVE_SYSTEM_ZOOM_STEP] away; the system's camera kept for coming back).
    pub fn show_galaxy(&mut self) {
        if let (MapView::System(i), Some(map)) = (self.view, self.map.as_ref()) {
            let s = &map.galaxy.systems[i];
            if let Some(g) = self.system_camera_goal {
                self.saved_system_cameras.insert(s.id, g);
            }
            let at = V3(s.x, s.height * 0.5, s.y);
            let mut c = self.camera.unwrap_or_else(OrbitCamera::galaxy_default);
            c.target = at;
            c.yaw = 0.0;
            c.pitch = 57.5f32.to_radians();
            let mut goal = c;
            c.distance = 0.001;
            goal.distance = camera::GALAXY_ZOOM_STEPS[1];
            goal.zoom_index = 1;
            self.camera = Some(if self.smooth { c } else { goal });
            self.camera_goal = Some(goal);
        }
        self.follow = None;
        self.view = MapView::Galaxy;
        self.screen = Screen::Map;
        self.scene = None;
        let smooth = self.smooth;
        if let Some(m) = self.map.as_mut() {
            m.watch(None, !smooth);
        }
    }

    /// Shows a system (CGameCamera::OnEnterSystem): the camera flies in from twice the last zoom
    /// step to ENTER_SYSTEM_ZOOM_STEP (FOCUS_START_ZOOM_STEP with something to follow), pitch
    /// 50; a system entered before comes back as it was left.
    pub fn show_system(&mut self, index: usize) -> Result<(), String> {
        self.enter_system(index, None)
    }

    fn enter_system(&mut self, index: usize, focus: Option<Pickable>) -> Result<(), String> {
        let map = self.map.as_mut().ok_or("no map loaded")?;
        if index >= map.galaxy.systems.len() {
            return Err(format!("no system {index}"));
        }
        let id = map.galaxy.systems[index].id;
        map.watch(Some(id), !self.smooth);
        let fresh = system::camera_for(map, index);
        let (start, goal) = match (self.saved_system_cameras.get(&id), focus) {
            (Some(saved), None) => (*saved, *saved),
            _ => {
                let mut goal = fresh;
                if let Some(s) = fresh.zoom_steps {
                    let k = if focus.is_some() { 4 } else { 6 };
                    goal.distance = s[k];
                    goal.zoom_index = k;
                }
                let mut start = goal;
                start.distance = fresh.zoom_steps.map_or(goal.distance * 2.0, |s| 2.0 * s[6]);
                (start, goal)
            }
        };
        self.system_camera = Some(if self.smooth { start } else { goal });
        self.system_camera_goal = Some(goal);
        self.follow = focus;
        self.last_system = Some(index);
        self.view = MapView::System(index);
        self.screen = Screen::Map;
        self.scene = None;
        self.log.push(format!("system view: {} (id {})", map.galaxy.systems[index].star_class, map.galaxy.systems[index].id));
        if focus.is_some() {
            // the target on the followed thing at once
            if let Some(p) = self.followed_position() {
                for c in [self.system_camera.as_mut(), self.system_camera_goal.as_mut()].into_iter().flatten() {
                    c.target = p;
                }
            }
        }
        Ok(())
    }

    /// A double click on something (CSelectable::FocusOn): a system from the galaxy is entered;
    /// a planet or a fleet in the system shown is followed.
    pub fn focus(&mut self, what: Pickable) -> Result<(), String> {
        match (what, self.view) {
            (Pickable::System(i), _) => self.enter_system(i, None),
            (Pickable::Body(_), MapView::System(_)) | (Pickable::Fleet(_), MapView::System(_)) => {
                self.follow = Some(what);
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// The camera's shortcuts (CGameCamera::HandleShortcutsInput): R turns it back (a system:
    /// its centre, pitch 50, yaw 0; the galaxy: pitch 57.5, yaw 0, at the last system,
    /// ZOOM_STEPS_GALAXY[1]); E and M enter the system under the cursor or go between the system
    /// and the galaxy; Home and Backspace go to the capital.
    fn camera_action(&mut self, action: Action) -> Result<bool, String> {
        match action {
            Action::ResetCamera => {
                let last = self.last_system;
                let map_ok = self.map.is_some();
                match self.view {
                    MapView::System(_) => {
                        if let Some(g) = self.goal_mut() {
                            g.target = V3(0.0, 0.0, 0.0);
                            g.pitch = 50f32.to_radians();
                            g.yaw = 0.0;
                        }
                    }
                    MapView::Galaxy if map_ok => {
                        let at = last.and_then(|i| self.map.as_ref().map(|m| (m.galaxy.systems[i].x, m.galaxy.systems[i].y)));
                        if let Some(g) = self.goal_mut() {
                            g.pitch = 57.5f32.to_radians();
                            g.yaw = 0.0;
                            if let Some((x, y)) = at {
                                g.target = V3(x, 0.0, y);
                                g.distance = camera::GALAXY_ZOOM_STEPS[1];
                                g.zoom_index = 1;
                            }
                        }
                    }
                    _ => return Ok(false),
                }
                self.follow = None;
                self.goal_moved();
                Ok(true)
            }
            Action::ToggleSystem => {
                let (x, y) = self.cursor.unwrap_or((self.size.0 as f32 / 2.0, self.size.1 as f32 / 2.0));
                match self.view {
                    MapView::Galaxy => {
                        let under = match self.scene()?.pick_at(x, y, 6.0) {
                            Some(Pickable::System(i)) => Some(i),
                            _ => self.last_system,
                        };
                        match under {
                            Some(i) => self.show_system(i)?,
                            None => return Ok(false),
                        }
                    }
                    MapView::System(_) => self.show_galaxy(),
                    MapView::Model => return Ok(false),
                }
                Ok(true)
            }
            Action::HomeSystem => {
                let Some((planet, system)) = self.map.as_ref().and_then(|m| m.galaxy.capital) else { return Ok(false) };
                let Some(i) = self.map.as_ref().and_then(|m| m.galaxy.systems.iter().position(|s| s.id == system)) else { return Ok(false) };
                let _ = planet;
                self.enter_system(i, None)?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// Shows a model alone (an entity or a pdxmesh of gfx/models), with a camera fitted to it.
    pub fn show_model(&mut self, name: &str) -> Result<(), String> {
        let cam = system::model_camera(&mut self.models, &self.runtime, &self.game_dir, name)?;
        self.model = Some(name.to_string());
        self.view = MapView::Model;
        self.set_camera(cam);
        self.screen = Screen::Map;
        self.scene = None;
        self.log.push(format!("model view: {name}"));
        Ok(())
    }

    /// Steps the simulation behind the map `days` days.
    pub fn step(&mut self, days: u64) -> Result<String, String> {
        let map = self.map.as_mut().ok_or("no map loaded")?;
        let r = map.step(days)?;
        self.scene = None;
        Ok(r)
    }

    /// Pauses or runs the game's clock.
    pub fn set_paused(&mut self, paused: bool) -> Result<(), String> {
        let map = self.map.as_mut().ok_or("no map loaded")?;
        map.set_paused(paused);
        self.log.push(format!("clock: {}", if paused { "paused".to_string() } else { format!("running at speed {}", map.speed) }));
        self.scene = None;
        Ok(())
    }

    /// The game's speed, 1..5.
    pub fn set_speed(&mut self, speed: u8) -> Result<(), String> {
        let map = self.map.as_mut().ok_or("no map loaded")?;
        map.set_speed(speed);
        self.log.push(format!("clock: speed {}", map.speed));
        self.scene = None;
        Ok(())
    }

    /// Selects something on the map (or nothing).
    pub fn select(&mut self, what: Option<Pickable>) {
        if self.selected != what {
            self.selected = what;
            self.log.push(format!("selected: {what:?}"));
            self.scene = None;
        }
    }

    /// The system view's map labels (mapicons.gui; docs/render.md section 12): each fleet's and
    /// station's `fleet_map_icon` (CFleetMapIcon::Update), each planet's `planet_map_icon` with
    /// an owner or deposits (CPlanetMapIcon::Update), in the relation colour
    /// (GetDiplomaticRelationColor: the player's, else neutral; the selected one gold).
    fn system_labels(&mut self) -> Result<Vec<scene::Label>, String> {
        if self.view == MapView::Galaxy && self.mode3d {
            return self.galaxy_labels();
        }
        let MapView::System(si) = self.view else { return Ok(Vec::new()) };
        let (w, h) = self.size;
        let gd = self.game_dir.clone();
        // the fonts (the name's width) come with the top bar
        self.map.as_mut().ok_or("no map")?.topbar(w, h)?;
        let map = self.map.as_mut().ok_or("no map")?;
        if !map.gui {
            return Ok(Vec::new());
        }
        let g = map.galaxy.clone();
        let data = map.system_data(g.systems[si].id)?;
        let player = map.player_country();
        let selected = self.selected;
        // CColor::SwitchHSVtoRGB of RELATION_COLOR_PLAYER_HSV and _NEUTRAL_HSV; _SELECTED_RGB
        let tint = |owner: Option<usize>, sel: bool| -> [f32; 4] {
            if sel {
                [1.5, 1.1, 0.0, 1.0]
            } else if owner.is_some() && owner == player {
                [0.0, 0.89, 0.61, 1.0]
            } else {
                [0.56, 0.56, 0.56, 1.0]
            }
        };
        let size = |name: &str| gui::sprite_size(&self.runtime, &self.cache, &gd, name).unwrap_or((32.0, 32.0));
        let mut specs = Vec::new();
        // (label index -> anchor, drop, bounds, sort, owner)
        let mut meta: Vec<(V3, f32, Option<[f32; 4]>, i64, Option<usize>)> = Vec::new();
        // the fleets, in the system's order of their ships
        let mut seen = std::collections::HashSet::new();
        for s in &data.ships {
            if !seen.insert(s.fleet) {
                continue;
            }
            let Some(f) = g.fleets.iter().find(|f| f.id == s.fleet) else { continue };
            let prefix = format!("/label/fleet/{}", f.id);
            let p = format!("{prefix}/fleet_map_icon");
            let mut spec = gui::WindowSpec::new("interface/mapicons.gui", "fleet_map_icon");
            spec.parent = Some([0.0, 0.0, 0.0, 0.0]);
            // (the shield bar hidden at 0: the military ones have shields, the others none [I];
            // the ship counters laid out below)
            for n in ["fleet_icon", "fleet_type", "cloaked_state", "has_ftl_magnet", "has_ftl_inhibitor", "ship_counters", "resources", "special_project"] {
                spec.hide.push(n.into());
            }
            if f.military_power <= 0.0 {
                spec.hide.push("shield".into());
            }
            // the type icon (GFX_ship_class_small) by what the fleet is [I: CFleet::GetIconFrame
            // not read; matched by eye to the game's frame]: military 3, a starbase 8, science and
            // research 9, mining 7, construction 2, colony 6
            let kind = s.size.as_str();
            let frame = if kind.contains("starbase") {
                8
            } else if kind.contains("research") || kind.contains("science") || kind.contains("observation") {
                9
            } else if kind.contains("mining") {
                7
            } else if kind.contains("construct") {
                2
            } else if kind.contains("colon") {
                6
            } else {
                3
            };
            spec.frames.push((format!("{p}/type"), frame));
            let sel = selected == Some(Pickable::Fleet(f.id));
            let c = tint(f.owner, sel);
            for n in ["bg", "flag", "type_bg"] {
                spec.tints.push((format!("{p}/{n}"), c));
            }
            spec.actions.push((format!("{p}/bg"), format!("select:fleet:{}", f.id)));
            let military = f.military_power > 0.0;
            if military {
                // CFleetMapIcon: MILITARY_POWER "£military_power£ $VALUE|*0$" (*1 with K from 1000)
                spec.text.push((format!("{p}/offensive_power"), format!("\u{a3}military_power\u{a3} {}", si_number(f.military_power.round()))));
            } else {
                spec.hide.push("offensive_power".into());
            }
            spec.prefix = Some(prefix.clone());
            specs.push(spec);
            // the ship counters (ship_counters: a ship_counter_entry per ship size of its military
            // ships, centred under the bar; GFX_ship_counter_<n> by the size [I])
            let c_tint = c;
            if military && !f.station {
                let mut counts: Vec<(u32, u32)> = Vec::new();
                for sh in data.ships.iter().filter(|x| x.fleet == f.id) {
                    let n = match sh.size.as_str() {
                        "corvette" => 4,
                        "destroyer" => 8,
                        "cruiser" => 16,
                        "battleship" => 32,
                        "titan" => 64,
                        "juggernaut" | "colossus" => 128,
                        _ => continue,
                    };
                    match counts.iter_mut().find(|c| c.0 == n) {
                        Some(c) => c.1 += 1,
                        None => counts.push((n, 1)),
                    }
                }
                let k = counts.len() as f32;
                for (j, (n, c)) in counts.iter().enumerate() {
                    let mut e = gui::WindowSpec::new("interface/mapicons.gui", "ship_counter_entry");
                    let ep = format!("{prefix}/res{j}");
                    e.parent = Some([-65.0 + 25.0 + 87.0 / 2.0 - k * 18.0 / 2.0 + j as f32 * 18.0, 8.0 + 24.0, 0.0, 0.0]);
                    e.sprites.push((format!("{ep}/ship_counter_entry/icon"), format!("GFX_ship_counter_{n}")));
                    e.text.push((format!("{ep}/ship_counter_entry/count"), c.to_string()));
                    e.tints.push((format!("{ep}/ship_counter_entry/icon"), c_tint));
                    e.prefix = Some(ep);
                    specs.push(e);
                }
            }
            // civilian fleets (not stations) take military_fleet_icon_size 108 x 48 less: 32
            let bounds = [-65.0, 8.0, 108.0, if military || f.station { 48.0 } else { 32.0 }];
            // (stations sort with the military: not flagged civilian [I], the frame's order)
            let sort = f.id as i64 + if military || f.station { 0x1_FFFF_FFFE } else { 0xFFFF_FFFF };
            meta.push((V3(s.x, 0.0, s.y), 0.0, Some(bounds), sort, f.owner));
        }
        // the planets with an owner or deposits; their names localised
        let shown: Vec<&system::Body> = data.bodies.iter().filter(|b| b.owner >= 0 || !b.deposits.is_empty()).collect();
        let names = gui::format_names(&self.runtime, &shown.iter().map(|b| &b.name).collect::<Vec<_>>())?;
        let widths: Vec<f32> = names.iter().map(|n| map.fonts.as_ref().and_then(|f| f.get("cg_16b")).map_or(8.0 * n.len() as f32, |f| f.width(n)).min(800.0)).collect();
        let flag_w = size("GFX_map_icon_flag").0;
        let (cap_w, cap_h) = size("GFX_map_icon_flag_capital");
        let (deco_w, deco_h) = size("GFX_map_icon_flag_capital_decoration");
        let health_w = size("GFX_planet_map_icon_health").0;
        for ((b, name), tw) in shown.iter().zip(names).zip(widths) {
            let owner = if b.owner >= 0 { g.countries.iter().position(|c| c.id as i64 == b.owner) } else { None };
            let capital = g.capital.is_some_and(|(p, _)| p == b.id);
            let prefix = format!("/label/planet/{}", b.id);
            let p = format!("{prefix}/planet_map_icon");
            let mut spec = gui::WindowSpec::new("interface/mapicons.gui", "planet_map_icon");
            spec.parent = Some([0.0, 0.0, 0.0, 0.0]);
            let mut only: Vec<String> = vec!["name".into()];
            let bg = if capital { "bg_capital" } else { "bg" };
            only.push(bg.into());
            spec.positions.push((format!("{p}/{bg}"), (-(tw + 23.0) / 2.0, 12.0)));
            spec.sizes.push((format!("{p}/{bg}"), (tw + 23.0, 22.0)));
            let left = |ew: f32, ox: f32| -tw / 2.0 - ew + ox;
            if owner.is_some() {
                if capital {
                    only.push("flag_capital".into());
                    only.push("flag_capital_decoration".into());
                    spec.positions.push((format!("{p}/flag_capital"), (left(cap_w, -12.0), 3.0)));
                    // the decoration about the flag [I]
                    let fx = left(cap_w, -12.0);
                    spec.positions.push((format!("{p}/flag_capital_decoration"), (fx + (cap_w - deco_w) / 2.0, 3.0 + (cap_h - deco_h) / 2.0)));
                    spec.frames.push((format!("{p}/flag_capital_decoration"), 1));
                } else {
                    only.push("flag".into());
                    spec.positions.push((format!("{p}/flag"), (left(flag_w, -14.0), 7.0)));
                }
            }
            if b.colony {
                for n in ["type", "type_bg", "type_bg2", "health"] {
                    only.push(n.into());
                }
                spec.positions.push((format!("{p}/type"), (tw / 2.0 + 9.0, 8.0)));
                spec.positions.push((format!("{p}/type_bg2"), (tw / 2.0 + 9.0, 8.0)));
                spec.positions.push((format!("{p}/type_bg"), (tw / 2.0 + 5.0, 7.0)));
                spec.positions.push((format!("{p}/health"), (left(health_w, -17.0), 11.0)));
            }
            let sel = selected == Some(Pickable::Body(b.id));
            let c = tint(owner, sel);
            for n in ["bg", "bg_capital", "flag", "flag_capital", "type_bg"] {
                spec.tints.push((format!("{p}/{n}"), c));
            }
            spec.text.push((format!("{p}/name"), name.clone()));
            spec.actions.push((format!("{p}/{bg}"), format!("select:planet:{}", b.id)));
            spec.only = Some(only);
            spec.prefix = Some(prefix.clone());
            specs.push(spec);
            // the deposits under the name: a resource_icon_item each, centred, the amount green
            let n = b.deposits.len() as f32;
            for (k, (res, amount)) in b.deposits.iter().enumerate() {
                let mut r = gui::WindowSpec::new("interface/mapicons.gui", "resource_icon_item");
                let rp = format!("{prefix}/res{k}");
                r.parent = Some([-n * 19.0 / 2.0 + k as f32 * 19.0 + 3.0, 37.0, 0.0, 0.0]);
                r.sprites.push((format!("{rp}/resource_icon_item/icon"), format!("GFX_resource_{}", res.trim_end_matches("_research"))));
                r.text.push((format!("{rp}/resource_icon_item/num"), format!("\u{a7}G{}\u{a7}!", amount.trunc() as i64)));
                r.prefix = Some(rp);
                specs.push(r);
            }
            // the label's place: under the planet by 0.6 of its size (PLANET_MAP_ICON_OFFSET)
            let radius = {
                let crate::Map { models, runtime, .. } = &mut *map;
                // the bounding sphere: half the largest extent
                models.model(runtime, &gd, &b.entity).map(|m| { let (lo, hi) = m.aabb; 0.5 * (hi[0] - lo[0]).max(hi[1] - lo[1]).max(hi[2] - lo[2]) * m.scale }).unwrap_or(1.0)
            };
            let drop = radius * system::entity_scale(b.size, b.class_scale, b.moon_of >= 0) / system::SYSTEM_SPACE_SCALE * 0.6;
            let hh = 22.0 + if b.deposits.is_empty() { 0.0 } else { 42.0 };
            meta.push((V3(b.x, system::PLANE_Y, b.y), drop, Some([-tw / 2.0, -hh / 2.0, tw, hh]), b.id as i64, owner));
        }
        let layout = gui::layout_specs(&self.runtime, w, h, &specs)?;
        // the items back to their labels (by their path's prefix)
        let mut labels: Vec<scene::Label> = Vec::new();
        let mut index: HashMap<String, usize> = HashMap::new();
        let mut k = 0;
        for s in &specs {
            let key = s.prefix.clone().unwrap_or_default();
            let base = key.split("/res").next().unwrap_or("").to_string();
            if !index.contains_key(&base) {
                let (anchor, drop, bounds, sort, _) = meta[k];
                k += 1;
                index.insert(base.clone(), labels.len());
                labels.push(scene::Label { anchor, drop, items: Vec::new(), bounds, sort });
            }
        }
        for it in layout.items {
            let path = match &it {
                GuiItem::Sprite { path, .. } | GuiItem::Text { path, .. } => path.clone(),
            };
            let base = path.split('/').take(4).collect::<Vec<_>>().join("/");
            let base = base.split("/res").next().unwrap_or("").to_string();
            if let Some(&i) = index.get(&base) {
                labels[i].items.push(it);
            }
        }
        // the owners' flags
        let owners: Vec<Option<usize>> = meta.iter().map(|m| m.4).collect();
        let map = self.map.as_mut().unwrap();
        for (l, o) in labels.iter_mut().zip(owners) {
            map.flags(&mut l.items, o);
        }
        let all: Vec<GuiItem> = labels.iter().flat_map(|l| l.items.iter().cloned()).collect();
        gui::fonts(&self.runtime, &self.game_dir, &all, map.fonts.get_or_insert_with(HashMap::new))?;
        Ok(labels)
    }

    /// The galaxy's star labels (mapicons.gui `star_mapicon`, CGalacticObjectMapIcon): the name of
    /// each system the player knows (its terra incognita's systems) on its plate under the star,
    /// within GALAXY_SHOW_STARNAME_ZOOM (800 of the game's world: 400 map units); the plate in
    /// the owner's relation colour (the player's; others grey), gold when selected **[I]**: the
    /// icon's own update not read.
    fn galaxy_labels(&mut self) -> Result<Vec<scene::Label>, String> {
        let (w, h) = self.size;
        let gd = self.game_dir.clone();
        if self.camera.is_some_and(|c| c.distance > 400.0) {
            return Ok(Vec::new());
        }
        self.map.as_mut().ok_or("no map")?.topbar(w, h)?;
        let map = self.map.as_mut().ok_or("no map")?;
        if !map.gui {
            return Ok(Vec::new());
        }
        let g = map.galaxy.clone();
        let player = map.player_country();
        let known: Vec<usize> = match &g.terra_incognita {
            Some(ti) => ti.systems.iter().filter_map(|id| g.systems.iter().position(|s| s.id == *id)).collect(),
            None => (0..g.systems.len()).collect(),
        };
        let names = gui::format_names(&self.runtime, &known.iter().map(|&i| &g.systems[i].name).collect::<Vec<_>>())?;
        let widths: Vec<f32> = names.iter().map(|n| map.fonts.as_ref().and_then(|f| f.get("cg_16b")).map_or(8.0 * n.len() as f32, |f| f.width(n)).min(176.0)).collect();
        let mut specs = Vec::new();
        let mut anchors = Vec::new();
        for ((&i, name), tw) in known.iter().zip(names).zip(widths) {
            let s = &g.systems[i];
            let prefix = format!("/label/system/{}", s.id);
            let p = format!("{prefix}/star_mapicon");
            let mut spec = gui::WindowSpec::new("interface/mapicons.gui", "star_mapicon");
            spec.parent = Some([0.0, 0.0, 0.0, 0.0]);
            spec.only = Some(vec!["name_bg".into(), "name".into()]);
            // the plate fitted to the name (NMapIcon::AdjustNameBg), centred under the star
            let bw = tw + 10.0;
            spec.positions.push((format!("{p}/name_bg"), (-bw / 2.0, 14.0)));
            spec.sizes.push((format!("{p}/name_bg"), (bw, 18.0)));
            spec.text.push((format!("{p}/name"), name));
            let sel = self.selected == Some(Pickable::System(i));
            let owner = g.shown_owner(s);
            let c = if sel {
                [1.5, 1.1, 0.0, 1.0]
            } else if owner.is_some() && owner == player {
                [0.0, 0.89, 0.61, 1.0]
            } else {
                [0.56, 0.56, 0.56, 1.0]
            };
            spec.tints.push((format!("{p}/name_bg"), c));
            spec.actions.push((format!("{p}/name_bg"), format!("select:system:{i}")));
            spec.prefix = Some(prefix);
            specs.push(spec);
            anchors.push(V3(s.x, s.height * 0.5, s.y));
        }
        let layout = gui::layout_specs(&self.runtime, w, h, &specs)?;
        let mut labels: Vec<scene::Label> = anchors.iter().map(|&a| scene::Label { anchor: a, drop: 0.0, items: Vec::new(), bounds: None, sort: 0 }).collect();
        let index: HashMap<String, usize> = specs.iter().enumerate().map(|(k, s)| (s.prefix.clone().unwrap_or_default(), k)).collect();
        for it in layout.items {
            let path = match &it {
                GuiItem::Sprite { path, .. } | GuiItem::Text { path, .. } => path.clone(),
            };
            let base = path.split('/').take(4).collect::<Vec<_>>().join("/");
            if let Some(&k) = index.get(&base) {
                labels[k].items.push(it);
            }
        }
        let map = self.map.as_mut().unwrap();
        let all: Vec<GuiItem> = labels.iter().flat_map(|l| l.items.iter().cloned()).collect();
        gui::fonts(&self.runtime, &gd, &all, map.fonts.get_or_insert_with(HashMap::new))?;
        Ok(labels)
    }

    /// The main screen's other windows (docs/render.md section 12): the left bar's buttons
    /// (main.gui `maingui_left_bar_buttons`, as collapsed), the alerts (alerts.gui), the bottom
    /// bar (main_bottom.gui: the system's or the galaxy's banner, the map modes, the toolbar).
    fn main_screen_items(&mut self) -> Result<Vec<GuiItem>, String> {
        let (w, h) = self.size;
        let Some(map) = self.map.as_ref() else { return Ok(Vec::new()) };
        let g = map.galaxy.clone();
        let paused = map.paused;
        let player = map.player_country();
        let mut specs = Vec::new();
        // the left bar, collapsed (hide_position): the views' icons (right_icon, x 0.6) down its
        // gridbox; the order of the game's frame (CTopbarMenuOrderSettings' default) [I]
        let mut bar = gui::WindowSpec::new("interface/main.gui", "maingui_left_bar_buttons");
        bar.positions.push(("/maingui_left_bar_buttons".into(), (-225.0, 35.0)));
        // its background (the container `background`, GFX_navbar_bg_wide at its 320 x 610): the
        // game's frame has its right edge at x = 35, 65 left of its (5, 5) in the window at the
        // hide position [I: what moves it is not read; no clip: the texture's own edge shows]
        bar.positions.push(("/maingui_left_bar_buttons/background".into(), (-60.0, 5.0)));
        bar.only = Some(vec!["lock".into(), "background".into(), "navbar_bg".into()]);
        specs.push(bar);
        let views = ["situation", "council", "traditions", "technology", "leaders", "species", "empire", "expansion_planner", "fleet_manager", "contacts", "discoveries", "claims", "market"];
        for (i, v) in views.iter().enumerate() {
            let mut e = gui::WindowSpec::new("interface/main.gui", "maingui_left_bar_button");
            let prefix = format!("/left_bar/{i}");
            e.parent = Some([-225.0 + 34.0, 35.0 + 50.0 + 40.0 * i as f32, 0.0, 0.0]);
            e.only = Some(vec!["right_icon".into()]);
            e.sprites.push((format!("{prefix}/maingui_left_bar_button/right_icon"), format!("GFX_topbar_{v}_button")));
            e.prefix = Some(prefix);
            specs.push(e);
        }
        // the alerts (CAlertManager::GetXFromIndex, GetYFromIndex): from (200, 30), 55 x 72 apart,
        // five a row; the banner by priority, the alert's icon
        for (i, (_, icon, prio)) in g.alerts.iter().enumerate() {
            let mut a = gui::WindowSpec::new("interface/alerts.gui", "alerticon_window");
            let prefix = format!("/alerts/{i}");
            a.parent = Some([200.0 + ((i % 5) + 1) as f32 * 55.0, 30.0 + (i / 5) as f32 * 72.0, 0.0, 0.0]);
            let banner = match prio.as_str() {
                "HIGH" => "GFX_alerticon_banner_high",
                "LOW" => "GFX_alerticon_banner_low",
                _ => "GFX_alerticon_banner_med",
            };
            a.sprites.push((format!("{prefix}/alerticon_window/alerticon_banner"), banner.into()));
            a.sprites.push((format!("{prefix}/alerticon_window/alerticon"), icon.clone()));
            a.prefix = Some(prefix);
            specs.push(a);
        }
        // the bottom bar: the system's banner (CMainGuiBottomBarLeaveSystemWindow::Update) or the
        // galaxy's, the map modes and the toolbar
        let mut bottom = gui::WindowSpec::new("interface/main_bottom.gui", "maingui_bottombar");
        let mut flag_owner = player;
        let mut names: Vec<&crate::galaxy::Name> = Vec::new();
        let banner = match self.view {
            MapView::System(i) => {
                let s = &g.systems[i];
                flag_owner = g.shown_owner(s).or(s.owner);
                names.push(&s.name);
                // the system's type (GetSystemTypeNameForPlayer) [I: the common/system_types
                // weights not evaluated]: the owner's capital system, a colonised one, an outpost;
                // unclaimed; an alien's
                let ty = match s.owner {
                    None => "sys_unclaimed",
                    Some(o) if Some(o) != player && g.shown_owner(s).is_none() => "sys_alien",
                    Some(_) if g.capital.is_some_and(|(_, sid)| sid == s.id) => "sys_homeworld",
                    Some(_) if g.planets.iter().any(|p| p.system == s.id as i64) => "sys_colonized",
                    Some(_) => "sys_outpost",
                };
                bottom.text.push(("/maingui_bottombar/leave_system_window/system_type".into(), ty.into()));
                if s.owner.is_none() {
                    bottom.hide.push("flag_button".into());
                }
                "leave_system_window"
            }
            _ => {
                if let Some(p) = player {
                    names.push(&g.countries[p].name_block);
                    // CGovernmentType::GetName: the government type's name
                    bottom.text.push(("/maingui_bottombar/leave_galaxy_window/empire_type".into(), g.countries[p].government.clone()));
                }
                "leave_galaxy_window"
            }
        };
        bottom.only = Some(vec![banner.into(), "mapmodes".into(), "toolbar".into()]);
        // (no claims, no restriction, no hazard or psionic aura in the player's systems; no error log)
        for n in ["claim_system_button", "claims_button_bg", "restricted_system_button", "restricted_button_bg", "environmental_effects_icon", "psionic_aura_icon", "error_log_button"] {
            bottom.hide.push(n.into());
        }
        if !paused {
            bottom.hide.push("paused".into());
            bottom.hide.push("paused_bar_bg".into());
        }
        let texts = gui::format_names(&self.runtime, &names)?;
        if let Some(t) = texts.first() {
            bottom.text.push(("/maingui_bottombar/leave_system_window/system_name".into(), t.clone()));
            bottom.text.push(("/maingui_bottombar/leave_galaxy_window/empire_name".into(), t.clone()));
        }
        specs.push(bottom);
        let layout = gui::layout_specs(&self.runtime, w, h, &specs)?;
        let mut items = layout.items;
        // the map modes (common/map_modes in file order; the cosmic storm forecast's left out
        // [I]): a main_gui_map_mode_entry each in the gridbox `map_modes` (LOWER_LEFT: from the
        // bottom left, four a row, 34 apart)
        if let Some(r) = layout.rects.get("/maingui_bottombar/mapmodes/map_modes") {
            let modes = ["default", "unions", "diplomatic", "intel", "opinion", "attitude", "neighbours"];
            let mut mspecs = Vec::new();
            for (k, m) in modes.iter().enumerate() {
                let mut e = gui::WindowSpec::new("interface/main_bottom.gui", "main_gui_map_mode_entry");
                let prefix = format!("/map_modes/{k}");
                e.parent = Some([r[0] + (k % 4) as f32 * 34.0, r[1] + r[3] - ((k / 4) + 1) as f32 * 34.0, 0.0, 0.0]);
                e.sprites.push((format!("{prefix}/main_gui_map_mode_entry/icon"), format!("GFX_map_mode_{m}")));
                // the active mode (the default after a load) in its second frame
                if k == 0 {
                    e.frames.push((format!("{prefix}/main_gui_map_mode_entry/icon"), 2));
                }
                e.prefix = Some(prefix);
                mspecs.push(e);
            }
            items.extend(gui::layout_specs(&self.runtime, w, h, &mspecs)?.items);
        }
        let map = self.map.as_mut().unwrap();
        for it in items.iter_mut() {
            if let GuiItem::Sprite { path, .. } = it {
                if path.starts_with("/maingui_bottombar") {
                    map.flags(std::slice::from_mut(it), flag_owner);
                }
            }
        }
        Ok(items)
    }

    /// The outliner and the window the selection opens (render.windows), with the names from
    /// the world localised; nothing without a map or with the GUI hidden.
    fn selection_windows(&mut self) -> Vec<GuiItem> {
        match self.window_items() {
            Ok(items) => items,
            Err(e) => {
                self.log.push(format!("windows: {e}"));
                Vec::new()
            }
        }
    }

    fn window_items(&mut self) -> Result<Vec<GuiItem>, String> {
        let (w, h) = self.size;
        let Some(map) = self.map.as_mut() else { return Ok(Vec::new()) };
        if !map.gui || self.view == MapView::Model {
            return Ok(Vec::new());
        }
        // a selected planet's name: from the system's bodies
        let body = match (self.selected, self.view) {
            (Some(Pickable::Body(id)), MapView::System(i)) => {
                let sid = map.galaxy.systems[i].id;
                map.system_data(sid).ok().and_then(|d| d.bodies.iter().find(|b| b.id == id).map(|b| (b.id, b.name.clone(), b.class.clone())))
            }
            // one of the player's planets (from the outliner)
            (Some(Pickable::Body(id)), _) => map.galaxy.planets.iter().find(|p| p.id == id).map(|p| (p.id, p.name.clone(), p.class.clone())),
            _ => None,
        };
        let g = map.galaxy.clone();
        let observe = map.observe;

        // the name of the selection's window, localised
        let mut names: Vec<&crate::galaxy::Name> = Vec::new();
        // the selection's window: a fleet (a station: the starbase's), a planet
        let mut selected: Option<(String, u32)> = None;
        match self.selected {
            Some(Pickable::Fleet(id)) => {
                if let Some(f) = g.fleets.iter().find(|f| f.id == id) {
                    names.push(&f.name);
                    selected = Some((if f.station { "starbase" } else { "fleet" }.into(), id));
                }
            }
            Some(Pickable::Body(_)) => {
                if let Some((id, name, _)) = &body {
                    names.push(name);
                    selected = Some(("planet".into(), *id));
                }
            }
            _ => {}
        }
        // a fleet in combat shows the combat view instead of its window (designer.rs)
        let combat = match self.selected {
            Some(Pickable::Fleet(id)) if crate::designer::in_combat(&map.runtime, id) => Some(id),
            _ => None,
        };
        if combat.is_some() {
            selected = None;
        }
        let texts = gui::format_names(&self.runtime, &names)?;
        let mut rest = texts.iter();
        let mut next = || rest.next().cloned().unwrap_or_default();
        // the outliner (render.windows.outliner, from the world's view and its own state)
        let row_selected = match self.selected {
            Some(Pickable::Fleet(f)) => Some(("fleet", f)),
            Some(Pickable::Body(b)) => Some(("planet", b)),
            _ => None,
        };
        crate::outliner::install(&self.runtime, &g.outliner_view, &self.outliner, row_selected, observe)?;
        let selected = selected.map(|(kind, id)| gui::SelectedWindow { kind, id, name: next(), sub: String::new() });
        let layout = gui::windows(&self.runtime, w, h, &[], selected.as_ref())?;
        // the main screen's other windows under the outliner and the selection's window
        let mut items = self.main_screen_items()?;
        items.extend(layout.items);
        // the ship designer and the combat view over them
        let map = self.map.as_ref().unwrap();
        match crate::designer::layout(&self.runtime, &map.runtime, &self.game_dir, w, h, &self.designer, combat) {
            Ok((more, models)) => {
                items.extend(more);
                self.designer_models = models;
            }
            Err(e) => {
                eprintln!("windows: {e}");
                self.log.push(format!("windows: {e}"));
            }
        }
        let map = self.map.as_mut().unwrap();
        // the outliner's flags (the observer's countries: `@ID` in their path)
        for it in items.iter_mut() {
            let id = match it {
                GuiItem::Sprite { path, .. } => crate::outliner::flag_country(path),
                _ => None,
            };
            if let Some(id) = id {
                let c = map.galaxy.countries.iter().position(|c| c.id == id);
                map.flags(std::slice::from_mut(it), c);
            }
        }
        gui::fonts(&self.runtime, &self.game_dir, &items, map.fonts.get_or_insert_with(HashMap::new))?;
        Ok(items)
    }

    /// The scene must be built again (the world or the view changed).
    pub fn invalidate(&mut self) {
        self.scene = None;
    }

    pub fn resize(&mut self, w: u32, h: u32) {
        if self.size != (w, h) {
            self.size = (w, h);
            self.scene = None;
        }
    }

    fn saves(&mut self) -> &Vec<SaveInfo> {
        if self.saves.is_none() {
            self.saves = Some(list_saves());
        }
        self.saves.as_ref().unwrap()
    }

    /// The GUI items of the menu or the load window (laid out once per size).
    fn items(&mut self) -> Result<Vec<GuiItem>, String> {
        let key = (self.size.0, self.size.1, self.screen);
        if let Some((k, items)) = &self.items {
            if *k == key {
                return Ok(items.clone());
            }
        }
        let (w, h) = self.size;
        let menu = gui::menu(&self.runtime, w, h, &self.version, self.screen == Screen::Load)?;
        self.notes = vec![menu.note.clone()];
        let mut items = menu.items;
        let mut missing = menu.missing;
        if self.screen == Screen::Load {
            // the blocker takes the menu's input while the window is open
            for it in &mut items {
                if let GuiItem::Sprite { button, .. } = it {
                    *button = false;
                }
            }
            let saves = self.saves().clone();
            let rows: Vec<gui::SaveRow> =
                saves.iter().map(|s| gui::SaveRow { name: &s.name, date: &s.date, file: &s.file }).collect();
            let load = gui::load_window(&self.runtime, w, h, &rows)?;
            self.notes.push(format!("load window: {}", load.note));
            items.extend(load.items);
            missing.extend(load.missing);
        }
        if !missing.is_empty() {
            self.notes.push(format!("sprites without a definition or texture: {}", missing.join(", ")));
        }
        gui::fonts(&self.runtime, &self.game_dir, &items, &mut self.fonts)?;
        self.items = Some((key, items.clone()));
        Ok(items)
    }

    /// Builds the current screen's scene if something changed; its generation (a new number for
    /// each scene built).
    pub fn prepare(&mut self) -> Result<u64, String> {
        self.scene()?;
        Ok(self.generation)
    }

    /// The scene built and its textures (after [`App::prepare`]).
    pub fn parts(&self) -> Option<(&Scene, &Textures)> {
        self.scene.as_deref().map(|s| (s, self.textures()))
    }

    /// The button states of the screen's GUI (hover, pressed).
    fn states(&self) -> HashMap<String, ButtonState> {
        let mut states = HashMap::new();
        if let Some(p) = &self.hover {
            states.insert(p.clone(), ButtonState::Hover);
        }
        if let Some(p) = &self.pressed {
            states.insert(p.clone(), ButtonState::Pressed);
        }
        states
    }

    /// The scene of the current screen (rebuilt when something changed).
    pub fn scene(&mut self) -> Result<&Scene, String> {
        if self.scene.is_none() {
            let (w, h) = self.size;
            let states = self.states();
            if self.screen == Screen::Map {
                let key = self.map.as_ref().map(|m| (w, h, self.view, self.selected, m.snapshot.as_ref().map_or(0, |s| s.generation), m.gui, m.paused, self.camera.is_some_and(|c| c.distance <= 400.0), m.observe));
                if key != self.overlay_key {
                    let t = Instant::now();
                    self.overlay_items = self.selection_windows();
                    crate::prof("scene: selection windows", t);
                    let t = Instant::now();
                    let labels = self.system_labels();
                    crate::prof("scene: system labels", t);
                    self.overlay_labels = match labels {
                        Ok(l) => l,
                        Err(e) => {
                            self.log.push(format!("labels: {e}"));
                            Vec::new()
                        }
                    };
                    self.overlay_key = key;
                }
            }
            let overlay = scene::Overlay { selected: self.selected, items: self.overlay_items.clone(), labels: self.overlay_labels.clone() };
            let scene = match self.screen {
                Screen::Map if self.view == MapView::Model => {
                    let cam = self.system_camera.ok_or("no camera")?;
                    let name = self.model.clone().ok_or("no model")?;
                    let mut cache = self.cache.borrow_mut();
                    system::model_scene(&mut self.models, &self.runtime, &self.game_dir, &name, &cam, w, h, &mut self.textures, &mut cache)?
                }
                Screen::Map => {
                    let map = self.map.as_mut().ok_or("no map")?;
                    map.button_states = states;
                    match (self.view, &self.system_camera) {
                        (MapView::System(i), Some(cam)) => system::build(map, i, cam, w, h, &overlay)?,
                        _ => {
                            let cam = if self.mode3d { self.camera.as_ref() } else { None };
                            map.frame(w, h, cam, &overlay)?.scene
                        }
                    }
                }
                _ => {
                    let items = self.items()?;
                    scene::gui_scene(w, h, &items, &self.fonts, &mut self.textures, &mut self.cache.borrow_mut(), &self.game_dir, &states)
                }
            };
            // the designer's 3D views (designer.rs)
            let mut scene = scene;
            if let (Screen::Map, Some(map)) = (self.screen, self.map.as_mut()) {
                let cache = map.cache.clone();
                crate::designer::fill_insets(&mut scene, &self.designer_models, &mut map.models, &map.runtime, &self.game_dir, &mut map.textures, &mut cache.borrow_mut());
            }
            self.scene = Some(std::sync::Arc::new(scene));
            // a new scene, whoever asked for it (a hit test builds it too)
            self.generation += 1;
        }
        Ok(self.scene.as_deref().unwrap())
    }

    /// The scene built (after [`App::prepare`]), shared: what the UI thread publishes (ui.rs).
    pub fn scene_shared(&self) -> Option<std::sync::Arc<Scene>> {
        self.scene.clone()
    }

    /// The textures of the current screen's scene.
    pub fn textures(&self) -> &Textures {
        match (&self.screen, &self.map) {
            (Screen::Map, Some(m)) if self.view != MapView::Model => &m.textures,
            _ => &self.textures,
        }
    }

    fn button_at(&mut self, x: f32, y: f32) -> Result<Option<(String, Option<String>)>, String> {
        Ok(self.scene()?.button_at(x, y).map(|b| (b.path.clone(), b.action.clone())))
    }

    /// The tooltip for what the cursor has rested on for `rest` (the hook: none until a
    /// [`Tooltips`] is set).
    #[allow(dead_code)]
    pub fn tooltip(&mut self, rest: std::time::Duration) -> Option<String> {
        let (target, since) = self.hovered.clone()?;
        if since.elapsed() < rest {
            return None;
        }
        let date = self.map.as_ref().map(|m| m.date()).unwrap_or_default();
        self.tooltips.as_mut()?.text(&target, &date)
    }

    /// The cursor left the window (no edge scrolling).
    pub fn mouse_left(&mut self) {
        self.cursor = None;
    }

    /// The mouse moved: the button under it shows its hover frame. Whether the frame changed.
    pub fn mouse_move(&mut self, x: f32, y: f32) -> Result<bool, String> {
        self.cursor = Some((x, y));
        let hover = self.button_at(x, y)?.map(|b| b.0);
        // the tooltips' hook: the element or the thing on the map under the cursor
        let target = match &hover {
            Some(path) => Some(HoverTarget::Element(path.clone())),
            None if self.screen == Screen::Map => self.scene()?.pick_at(x, y, 6.0).map(HoverTarget::Map),
            None => None,
        };
        if self.hovered.as_ref().map(|h| &h.0) != target.as_ref() {
            self.hovered = target.map(|t| (t, Instant::now()));
        }
        if hover != self.hover {
            self.hover = hover;
            self.scene = None;
            return Ok(true);
        }
        Ok(false)
    }

    pub fn mouse_down(&mut self, x: f32, y: f32) -> Result<bool, String> {
        let pressed = self.button_at(x, y)?.map(|b| b.0);
        if pressed != self.pressed {
            self.pressed = pressed;
            self.scene = None;
            return Ok(true);
        }
        Ok(false)
    }

    /// The button released over the one pressed is a click: its action is done. On the map
    /// elsewhere, a click selects what is under it (a system, a fleet, a planet, a ship), or
    /// nothing.
    pub fn mouse_up(&mut self, x: f32, y: f32) -> Result<bool, String> {
        let under = self.button_at(x, y)?;
        let pressed = self.pressed.take();
        if pressed.is_some() {
            self.scene = None;
            if let (Some((path, action)), Some(p)) = (under, pressed) {
                if path == p {
                    self.act(&path, action.as_deref())?;
                }
            }
            return Ok(true);
        }
        if self.screen == Screen::Map && under.is_none() {
            let hit = self.scene()?.pick_at(x, y, 6.0);
            self.select(hit);
            return Ok(true);
        }
        Ok(false)
    }

    /// A double click: on the galaxy, a system opens (the game's camera goes into it).
    pub fn double_click(&mut self, x: f32, y: f32) -> Result<bool, String> {
        if self.screen != Screen::Map {
            return Ok(false);
        }
        // a map label (a star's name, a planet's or a fleet's icon) is its thing; another GUI
        // element takes the double click
        let under = match self.button_at(x, y)? {
            Some((_, Some(a))) if a.starts_with("select:") => Some(pickable_of(&a)?),
            Some(_) => return Ok(false),
            None => self.scene()?.pick_at(x, y, 6.0),
        };
        match under {
            Some(p) => {
                self.select(Some(p));
                self.focus(p)?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// A click at (x, y): press and release.
    pub fn click(&mut self, x: f32, y: f32) -> Result<(), String> {
        self.mouse_move(x, y)?;
        self.mouse_down(x, y)?;
        if self.pressed.is_none() && self.screen != Screen::Map {
            self.log.push(format!("click at {x},{y}: no button there ({:?})", self.screen));
        }
        self.mouse_up(x, y)?;
        Ok(())
    }

    fn act(&mut self, path: &str, action: Option<&str>) -> Result<(), String> {
        self.log.push(format!("click: {path} -> {}", action.unwrap_or("no action")));
        match action {
            Some("exit") => self.exit = true,
            Some("open_load") => self.show(Screen::Load),
            Some("close_load") => self.show(Screen::Menu),
            Some(a) if a.starts_with("load:") => {
                let i: usize = a[5..].parse().map_err(|_| format!("bad action {a}"))?;
                let path = self.saves().get(i - 1).map(|s| s.path.clone()).ok_or(format!("no save {i}"))?;
                self.load(&path)?;
            }
            // the clock's commands, done at the next frame
            Some("pause") => {
                let p = self.map.as_ref().is_some_and(|m| m.paused);
                self.commands.push(ClockCommand::Paused(!p));
            }
            Some("speed_up") | Some("speed_down") => {
                // CInGameIdler::ModifyGameSpeed: one step, within 1..5
                self.commands.push(ClockCommand::Speed(if action == Some("speed_up") { 1 } else { -1 }));
            }
            // the selection's window closed; an outliner row selects its planet or fleet
            Some("close") => self.select(None),
            Some(a) if a.starts_with("select:") => self.select(Some(pickable_of(a)?)),
            // the outliner's tabs, groups, observer list (outliner.rs State::act): laid out again
            Some(a) if a.starts_with("outliner:") => {
                if self.outliner.act(&a["outliner:".len()..]) {
                    self.overlay_key = None;
                    self.scene = None;
                }
            }
            Some(a) if a.starts_with("designer:") => {
                let mut d = self.designer.clone();
                crate::designer::act(&mut d, a)?;
                self.set_designer(d);
            }
            Some(other) => self.log.push(format!("  {other}: not done yet (its window is not laid out)")),
            None => {}
        }
        Ok(())
    }

    /// The ship designer opened, closed or given a design (designer.rs): the windows laid out again.
    pub fn set_designer(&mut self, d: crate::designer::Designer) {
        if d != self.designer {
            self.designer = d;
            self.overlay_key = None;
            self.scene = None;
        }
    }

    fn show(&mut self, screen: Screen) {
        self.screen = screen;
        self.hover = None;
        self.pressed = None;
        self.scene = None;
    }

    /// Loads a save and shows its map (with `sim`: as a running simulation, which can step).
    pub fn load(&mut self, path: &str) -> Result<(), String> {
        self.load_as(path, false)
    }

    pub fn load_as(&mut self, path: &str, sim: bool) -> Result<(), String> {
        let t0 = std::time::Instant::now();
        let mut map = if sim { Map::load_sim(&self.game_dir, path)? } else { Map::load(&self.game_dir, path)? };
        // the speeds' names (time_description), from the front end's localisation
        map.speed_names = self
            .runtime
            .lua
            .load("local t = {} for i = 0, 5 do t[#t + 1] = RENDER_LOC.get('GAME_SPEED_' .. i) end return t")
            .eval::<Vec<String>>()
            .ok()
            .and_then(|v| v.try_into().ok());
        // the galaxy's camera as the game makes it; the systems' cameras and what is followed
        // start anew
        self.view = MapView::Galaxy;
        self.set_camera(OrbitCamera::galaxy_default());
        self.saved_system_cameras.clear();
        self.follow = None;
        self.last_system = None;
        let capital = map.galaxy.capital.and_then(|(planet, system)| map.galaxy.systems.iter().position(|s| s.id == system).map(|i| (planet, i)));
        self.selected = None;
        self.overlay_items.clear();
        self.overlay_key = None;
        self.log.push(format!(
            "loaded {path} in {:.1} s: {} systems, {} hyperlanes, {} owners",
            t0.elapsed().as_secs_f64(),
            map.galaxy.systems.len(),
            map.galaxy.lanes.len(),
            map.galaxy.countries.len()
        ));
        self.map = Some(map);
        self.show(Screen::Map);
        // as the game after a load (CInGameIdler::RestoreDeviceObjects: FocusOnCoordinate on the
        // home system; the game's `state` after a load: view system 401, its centre,
        // ENTER_SYSTEM_ZOOM_STEP, pitch 50): the capital's system entered
        if let Some((_, i)) = capital {
            self.enter_system(i, None)?;
        }
        Ok(())
    }

    /// Continue: the newest save.
    pub fn continue_game(&mut self) -> Result<(), String> {
        let path = self.saves().first().map(|s| s.path.clone()).ok_or("no saves")?;
        self.log.push(format!("continue: {path}"));
        self.load(&path)
    }

    /// Physical input (controls.rs): the bindings' effects carried out. `now_ms`: the input's
    /// time (a double click's). Whether something changed.
    pub fn input(&mut self, input: &Input, now_ms: f64) -> Result<bool, String> {
        let ctx = self.context();
        let mut changed = false;
        for e in self.controls.input(input, now_ms, ctx) {
            changed |= self.apply(e)?;
        }
        Ok(changed)
    }

    /// An effect of the input.
    fn apply(&mut self, e: Effect) -> Result<bool, String> {
        match e {
            Effect::Act(a) => self.perform(a),
            Effect::Pointer(Some((x, y))) => self.mouse_move(x, y),
            Effect::Pointer(None) => {
                self.mouse_left();
                Ok(false)
            }
            Effect::Down(Button::Left, x, y) => self.mouse_down(x, y),
            Effect::Down(..) => Ok(false),
            Effect::At(Action::Select, x, y) => self.mouse_up(x, y),
            Effect::At(Action::Focus, x, y) => self.double_click(x, y),
            Effect::At(a, x, y) => {
                // the left button's press over a GUI button ends without a click
                if a == Action::BoxSelect && self.pressed.take().is_some() {
                    self.scene = None;
                }
                if self.screen == Screen::Map {
                    self.log.push(format!("{} at {x},{y}: not done yet", a.name()));
                }
                Ok(false)
            }
            Effect::DragStart(a, x, y) => {
                self.set_holding(true);
                if a == Action::DragPlane {
                    // the plane's point under the cursor is grabbed
                    self.drag(None);
                    self.drag(Some((x, y)));
                }
                Ok(true)
            }
            Effect::Drag(Action::Rotate, dx, dy, ..) => {
                if dx != 0.0 || dy != 0.0 {
                    self.rotate(dx, dy);
                }
                Ok(true)
            }
            Effect::Drag(Action::DragPlane, _, _, x, y) => {
                self.drag(Some((x, y)));
                Ok(true)
            }
            Effect::Drag(..) => Ok(false),
            Effect::DragEnd(_) => {
                self.set_holding(self.controls.holding());
                self.drag(None);
                Ok(true)
            }
            Effect::Zoom(n, false) => {
                self.wheel(n);
                Ok(true)
            }
            Effect::Zoom(n, true) => {
                // the right button held: a fifth of the distance (UpdateZoom @0x2e665ae)
                let d = self.current().map_or(1.0, |c| c.distance);
                if let Some(c) = self.goal_mut() {
                    c.zoom_keys(n, 1.0 / 7.5, d);
                }
                self.goal_moved();
                Ok(true)
            }
        }
    }

    /// An action of a key binding (controls.rs `BINDINGS`). Whether something changed.
    pub fn perform(&mut self, action: Action) -> Result<bool, String> {
        match (action, self.screen) {
            (Action::Back, Screen::Load) => {
                self.log.push(format!("escape: {:?} -> Menu", self.screen));
                self.show(Screen::Menu);
                Ok(true)
            }
            (Action::Continue, Screen::Menu) => {
                self.continue_game()?;
                Ok(true)
            }
            (Action::Quit, _) => {
                self.exit = true;
                Ok(true)
            }
            (Action::ToggleGui, _) => {
                let Some(m) = self.map.as_mut() else { return Ok(false) };
                m.gui = !m.gui;
                self.invalidate();
                Ok(true)
            }
            (_, Screen::Map) => {
                if self.camera_action(action)? {
                    return Ok(true);
                }
                match action {
                    // the clock (CInGameIdler::HandleInputEvent): Space pauses or runs; the speed
                    // a step; `.` one day
                    Action::Pause => self.act("/key/pause", Some("pause"))?,
                    Action::SpeedUp => self.act("/key/speed_up", Some("speed_up"))?,
                    Action::SpeedDown => self.act("/key/speed_down", Some("speed_down"))?,
                    Action::NextDay => self.commands.push(ClockCommand::NextDay),
                    Action::Map2D3D => {
                        self.mode3d = !self.mode3d;
                        self.scene = None;
                    }
                    // the designer's close button has the shortcut ESCAPE (ship_designer.gui)
                    Action::Back if self.designer.open => self.set_designer(Default::default()),
                    Action::Back if self.selected.is_some() => self.select(None),
                    Action::Back if self.view != MapView::Galaxy && self.map.is_some() => {
                        self.log.push(format!("escape: {:?} -> Galaxy", self.view));
                        self.show_galaxy();
                    }
                    Action::Back => {
                        self.log.push("escape: Map -> Menu".into());
                        self.show(Screen::Menu);
                    }
                    a => {
                        self.log.push(format!("{}: not done yet", a.name()));
                        return Ok(false);
                    }
                }
                Ok(true)
            }
            _ => Ok(false),
        }
    }
}

/// The thing a GUI element's `select:KIND:ID` action names (a system by its index).
fn pickable_of(action: &str) -> Result<Pickable, String> {
    let mut it = action.split(':').skip(1);
    let (kind, id) = (it.next().unwrap_or(""), it.next().and_then(|v| v.parse::<u32>().ok()).ok_or(format!("bad action {action}"))?);
    Ok(match kind {
        "planet" => Pickable::Body(id),
        "system" => Pickable::System(id as usize),
        _ => Pickable::Fleet(id),
    })
}

/// A number as the game's `*0` / `*1` formats write it (CreateSIValueNoColor; the military
/// power's MILITARY_POWER / MILITARY_POWER_1): under 1000 whole, then K with one decimal (to
/// 100K), K whole (to 1M), M with one decimal; cut, not rounded.
pub fn si_number(v: f32) -> String {
    let (s, a) = (if v < 0.0 { "-" } else { "" }, v.abs());
    if a < 1000.0 {
        format!("{s}{}", a.trunc() as i64)
    } else if a < 100_000.0 {
        format!("{s}{:.1}K", (a / 100.0).trunc() / 10.0)
    } else if a < 1_000_000.0 {
        format!("{s}{}K", (a / 1000.0).trunc() as i64)
    } else {
        format!("{s}{:.1}M", (a / 100_000.0).trunc() / 10.0)
    }
}
