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
    /// the new game: empire selection (select_empire_design.gui), the empire creator (session
    /// ng-creator's render.newgame_creator), the galaxy settings (game_setup/setup.gui)
    SelectEmpire,
    Creator,
    GameSetup,
    /// the load screen of a new game (newgame.rs)
    Loading,
}

impl Screen {
    /// One of the new game's screens (render.frontend_newgame): its name there.
    pub fn newgame(self) -> Option<&'static str> {
        match self {
            Screen::SelectEmpire => Some("select"),
            Screen::Creator => Some("creator"),
            Screen::GameSetup => Some("setup"),
            _ => None,
        }
    }
}

/// A new game on its way (App::start_new_game): the simulation's thread generating and loading
/// it, the load screen's bar, then RestoreDeviceObjects' part (`map_gfx`: the map made, the bar at
/// LOAD_MAP_GFX's steps) before the map is shown.
pub struct Pending {
    pub settings: crate::newgame::NewGameSettings,
    /// a save loaded behind the load screen (App::start_load_save) instead of a new game
    pub save: Option<String>,
    pub progress: std::sync::Arc<crate::newgame::Progress>,
    clock: Option<clock::Clock>,
    pub bar: crate::newgame::Bar,
    pub picture: Option<String>,
    pub started: Instant,
    /// RestoreDeviceObjects' step (0..100) once the game is made
    pub map_gfx: Option<i32>,
    /// when the map was made (the wait for the capital system's bodies)
    pub map_at: Option<Instant>,
    /// what the simulation's thread reported when it was done
    pub report: Option<String>,
}

impl Pending {
    /// The load screen's text and bar now.
    pub fn shown(&self) -> (&'static str, i32) {
        match self.map_gfx {
            Some(k) => ("LOAD_MAP_GFX", crate::newgame::map_gfx_percent(k)),
            // a save's load (CFrontEndIdler::LaunchSave's own stages are not followed: the bar
            // stays at 0 until the simulation has loaded it) [I]
            None if self.save.is_some() => ("LOAD_SAVE_GAME", 0),
            None => ("START_NEW_GAME", self.bar.percent()),
        }
    }
}

/// A save the load window lists.
#[derive(Clone, Debug)]
pub struct SaveInfo {
    pub path: String,
    pub file: String,
    pub name: String,
    pub date: String,
    pub modified: std::time::SystemTime,
    /// its folder: the game's load window lists a folder's saves as one session
    pub dir: String,
    /// the save's `meta` (name, date, version, DLCs, flag, portrait, fleets, planets, ironman)
    pub meta: String,
}

/// The saves in the known places, newest first (by the file's time: the game's load window and
/// Continue; whole seconds, see below): the folder of STELLAR_SAVE (or of the default save), each game's folder of the
/// user's Stellaris save games and of STELLAR_SAVE_GAMES (a `save games` folder), C:\lfm\saves
/// and /opt/stellaris-saves. The empire's name and the date come from each save's meta (from the
/// gamestate's head for a save that is not zipped).
pub fn list_saves() -> Vec<SaveInfo> {
    let mut dirs: Vec<std::path::PathBuf> = Vec::new();
    for p in [std::env::var("STELLAR_SAVE").ok(), save::default_save()].into_iter().flatten() {
        if let Some(d) = std::path::Path::new(&p).parent() {
            dirs.push(d.to_path_buf());
        }
    }
    let mut roots: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(r) = std::env::var("STELLAR_SAVE_GAMES") {
        roots.push(r.into());
    }
    if let Ok(home) = std::env::var("USERPROFILE") {
        roots.push(std::path::Path::new(&home).join(r"Documents\Paradox Interactive\Stellaris\save games"));
    }
    for root in roots {
        if let Ok(rd) = std::fs::read_dir(&root) {
            // (in the directory's own order: the game's sort keeps it for saves of the same second)
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
            let meta = save::read_meta(&path).ok().or_else(|| save::read_gamestate(&path).ok().map(|g| g.lines().take(60).collect::<Vec<_>>().join("
"))).unwrap_or_default();
            let (mut name, mut date) = (String::new(), String::new());
            for line in meta.lines() {
                if let Some(v) = line.strip_prefix("name=") {
                    name = v.trim_matches('"').to_string();
                } else if let Some(v) = line.strip_prefix("date=") {
                    date = v.trim_matches('"').to_string();
                }
            }
            let dir = d.to_string_lossy().into_owned();
            out.push(SaveInfo { path, file, name, date, modified, dir, meta });
        }
    }
    // newest first by the file's time in whole seconds, a stable sort (the game's
    // DescendingFileDateSort in CLoadGameView::BuildSessionsList @0x2f216a8: saves of the same
    // second stay in the directory's order)
    let secs = |s: &SaveInfo| s.modified.duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    out.sort_by(|a, b| secs(b).cmp(&secs(a)));
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
    pub(crate) camera_goal: Option<OrbitCamera>,
    pub(crate) system_camera_goal: Option<OrbitCamera>,
    /// the cameras move to their goals over time (the window), else at once (commands)
    pub smooth: bool,
    /// the model view: the model shown (an entity or a pdxmesh), and the models read for it
    pub model: Option<String>,
    pub models: models::Library,
    /// what is selected on the map
    pub selected: Option<Pickable>,
    /// the starbase window's tab (starbase.rs)
    pub starbase: crate::starbase::State,
    /// the event windows and popups open (events.rs)
    pub events: crate::events::EventsUi,
    /// the left bar's view open (views.rs: one at a time, CInGameIdler::ToggleTopBarView) and
    /// its own state (`view_set:KEY=VALUE`: a tab, an area chosen)
    pub open_view: Option<String>,
    pub view_state: HashMap<String, String>,
    /// the windows over the map for the selection (the outliner, an info window)
    pub overlay_items: Vec<GuiItem>,
    /// the fleet windows open besides the selected fleet's (fleetwin.rs)
    pub fleet: crate::fleetwin::FleetWindows,
    /// the map labels (mapicons.gui) of what the view shows
    pub overlay_labels: Vec<scene::Label>,
    /// the outliner's state: its tab, the groups collapsed (render.windows.outliner)
    pub outliner: crate::outliner::State,
    /// the main screen's bars, alerts and in-game menu (mainbars.rs)
    pub bars: crate::mainbars::Bars,
    /// the ship designer (designer.rs) and the ship models of its 3D views, by inset
    pub designer: crate::designer::Designer,
    designer_models: HashMap<String, crate::designer::ShipModel>,
    /// the planet view's state: the planet and the tab shown (planet.rs)
    pub planet_view: crate::planet::State,
    /// what the windows were laid out for: the size, view, selection, snapshot, GUI shown, paused,
    /// star names' zoom, observing
    overlay_key: Option<(u32, u32, MapView, Option<Pickable>, u64, bool, bool, bool, bool, u64)>,
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
    items: Option<((u32, u32, Screen, (&'static str, i32, u64)), Vec<GuiItem>)>,
    /// the load screens' console shown (console.rs), and the console lines laid out
    pub console: bool,
    console_gen: u64,
    /// the window's Load and Continue load behind the load screen (App::start_load_save); commands
    /// load at once (`load`, `load-sim`)
    pub async_loads: bool,
    /// a new game starting (its load screen shown), and the setup the menu's Start begins one
    /// from (the galaxy settings and the empire: the setup screens fill it; none: the scenario's
    /// defaults)
    pub pending: Option<Pending>,
    pub newgame_setup: Option<crate::newgame::NewGameSettings>,
    /// the scene built (shared with the render thread once published: ui.rs)
    scene: Option<std::sync::Arc<Scene>>,
    generation: u64,
    /// the input's state and the bindings (the held keys' actions move the camera each frame);
    /// the cursor (edge scrolling), the time of the last update
    pub controls: Controls,
    /// the clock's commands of the input, done at the next frame ([`ClockCommand`])
    commands: Vec<ClockCommand>,
    pub cursor: Option<(f32, f32)>,
    /// where the left button went down on the map (a box selection's corner: mapicons.rs)
    pub(crate) map_press: Option<(f32, f32)>,
    last_update: Option<Instant>,
    /// the diplomacy windows (Contacts, a country's diplomacy, ...: diplomacy.rs)
    pub diplomacy: crate::diplomacy::State,
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
            starbase: Default::default(),
            events: Default::default(),
            open_view: None,
            view_state: HashMap::new(),
            overlay_items: Vec::new(),
            fleet: Default::default(),
            overlay_labels: Vec::new(),
            outliner: Default::default(),
            bars: Default::default(),
            designer: Default::default(),
            designer_models: HashMap::new(),
            overlay_key: None,
            planet_view: Default::default(),
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
            pending: None,
            newgame_setup: None,
            console: crate::console::enabled(false),
            console_gen: 0,
            async_loads: true,
            scene: None,
            generation: 0,
            controls: Controls::from_env()?,
            commands: Vec::new(),
            cursor: None,
            map_press: None,
            last_update: None,
            diplomacy: Default::default(),
        })
    }

    /// The camera of what the map shows (the galaxy's or the system's): its goal, where input
    /// moves it.
    pub(crate) fn goal_mut(&mut self) -> Option<&mut OrbitCamera> {
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
    pub(crate) fn goal_moved(&mut self) {
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
    pub(crate) fn current(&self) -> Option<OrbitCamera> {
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
            Screen::Load | Screen::Loading => Context::Load,
            Screen::SelectEmpire | Screen::Creator | Screen::GameSetup => Context::Setup,
        }
    }

    /// A frame of `dt` seconds (the game's camera update): what the controls poll (the drags,
    /// the wheel), the cameras toward their goals, the held keys and the edge scrolling, the
    /// simulation's newest snapshot taken. Whether the picture changed (a frame is due).
    pub fn advance(&mut self, dt: f32) -> bool {
        let mut changed = false;
        // a system's camera fitted to a stand-in (its data not come yet) fitted again (mapicons.rs)
        changed |= self.refit_system_camera();
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
        if self.screen == Screen::Loading {
            return match self.loading(dt) {
                Ok(c) => changed | c,
                Err(e) => {
                    self.log.push(format!("new game: {e}"));
                    self.pending = None;
                    self.show(Screen::Menu);
                    true
                }
            };
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
        if self.screen == Screen::Loading {
            return true;
        }
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

    pub(crate) fn enter_system(&mut self, index: usize, focus: Option<Pickable>) -> Result<(), String> {
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

    /// The planet view of planet `id` on its tab `tab` (planet.rs: summary, management, population,
    /// armies, corporate): the planet selected.
    pub fn open_planet(&mut self, id: u32, tab: &str) -> Result<(), String> {
        self.select(Some(Pickable::Body(id)));
        self.planet_view.open(id, tab)?;
        self.log.push(format!("planet view: {id} {tab}"));
        self.overlay_key = None;
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

    // the map labels (system_labels, galaxy_labels): mapicons.rs

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
        // open under the cursor (show_position -5), else collapsed at its hide_position (-225)
        // (mainbars.rs hover; the slide's 200 ms not animated)
        let expanded = self.bars.expanded;
        let bar_x = if expanded { -5.0 } else { -225.0 };
        bar.positions.push(("/maingui_left_bar_buttons".into(), (bar_x, 35.0)));
        // its background (the container `background`, GFX_navbar_bg_wide at its 320 x 610): the
        // game's frame has its right edge at x = 35, 65 left of its (5, 5) in the window at the
        // hide position [I: what moves it is not read; no clip: the texture's own edge shows]
        bar.positions.push(("/maingui_left_bar_buttons/background".into(), (-60.0, 5.0)));
        bar.only = Some(vec!["lock".into(), "background".into(), "navbar_bg".into()]);
        // the lock (CMainGui::ToggleLeftBarLock: frame 2 locked)
        bar.actions.push(("/maingui_left_bar_buttons/lock".into(), "bar:lock".into()));
        bar.frames.push(("/maingui_left_bar_buttons/lock".into(), if self.bars.lock { 2 } else { 1 }));
        specs.push(bar);
        for (i, v) in crate::mainbars::LEFT_BAR.iter().enumerate() {
            let mut e = gui::WindowSpec::new("interface/main.gui", "maingui_left_bar_button");
            let prefix = format!("/left_bar/{i}");
            let p = format!("{prefix}/maingui_left_bar_button");
            // (27 left of the gridbox's 34: the game's frames have the icons' left edge at x = 5,
            // inside the bar, with and without a view open [I: measured; the rule not read])
            e.parent = Some([bar_x + 34.0 - 27.0, 35.0 + 50.0 + 40.0 * i as f32, 0.0, 0.0]);
            let mut only = vec!["right_icon".to_string()];
            if expanded {
                // open: the entry's icon, name (topbar_button_<view>_name), key (F1..F10 by its
                // place: CMainGuiLeftBarButton::Update) and its button
                only.extend(["icon", "text", "hotkey", "button"].iter().map(|s| s.to_string()));
                e.sprites.push((format!("{p}/icon"), format!("GFX_topbar_{v}_button")));
                e.text.push((format!("{p}/text"), format!("topbar_button_{v}_name")));
                e.text.push((format!("{p}/hotkey"), if i < 10 { format!("F{}", i + 1) } else { String::new() }));
                e.actions.push((format!("{p}/button"), format!("view:{v}")));
            }
            e.sprites.push((format!("{p}/right_icon"), format!("GFX_topbar_{v}_button")));
            // a click toggles its view (CInGameIdler::ToggleTopBarView)
            e.actions.push((format!("{p}/right_icon"), format!("view:{v}")));
            // its view shown (CMainGuiLeftBarButton::Update): the icons' frame 3 (2 x shown + 1)
            // and the highlight shown [V; which children: I, by the game's frame]
            if self.view_shown(v) {
                only.push("highlight".into());
                e.frames.push((format!("{p}/right_icon"), 3));
                e.frames.push((format!("{p}/icon"), 3));
            }
            e.only = Some(only);
            e.prefix = Some(prefix);
            specs.push(e);
        }
        // the alerts (CAlertManager::GetXFromIndex, GetYFromIndex): from (200, 30), 55 x 72 apart,
        // five a row; the banner by priority, the alert's icon; the banner takes the clicks (left:
        // what the alert points to, right: dismissed until its condition ends: mainbars.rs)
        let keys: Vec<String> = g.alerts.iter().map(|a| a.0.clone()).collect();
        self.bars.dismissed.retain(|k| keys.contains(k));
        let shown: Vec<_> = g.alerts.iter().filter(|a| !self.bars.dismissed.contains(&a.0)).collect();
        for (i, (key, icon, prio)) in shown.into_iter().enumerate() {
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
            a.actions.push((format!("{prefix}/alerticon_window/alerticon_banner"), format!("alert:{key}")));
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
        // the buttons (mainbars.rs): the toolbar's, the banners' (leave the system, enter one,
        // rename), the map filters' (the icon's frame + 1 when on; details + 1 or + 2); the
        // tutorial's help button is the databank's place (one of them is detached [I])
        bottom.hide.push("button_topbar_help_menu".into());
        let bb = "/maingui_bottombar";
        for (el, a) in [
            ("toolbar/button_topbar_menu", "bar:menu"),
            ("toolbar/button_topbar_chat", "bar:chat"),
            ("toolbar/button_topbar_help", "bar:databank"),
            ("toolbar/toggle_gotobox", "bar:find"),
            ("toolbar/home_button", "bar:home"),
            ("leave_system_window/button", "bar:galaxy"),
            ("leave_system_window/system_rename_button", "bar:rename"),
            ("leave_galaxy_window/change_camera_mode_button", "bar:system"),
        ] {
            bottom.actions.push((format!("{bb}/{el}"), a.into()));
        }
        for (i, f) in crate::mainbars::FILTERS.iter().enumerate() {
            bottom.actions.push((format!("{bb}/toolbar/toggle_mapmode_{f}"), format!("bar:filter:{f}")));
            bottom.frames.push((format!("{bb}/toolbar/toggle_mapmode_icon_{f}"), 1 + self.bars.filters[i] as u32));
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
                // the active mode (the default after a load) in its second frame; a click sets
                // the mode (CMapModeEntry::OnClick: SetCurrentMapMode)
                if k == self.bars.map_mode {
                    e.frames.push((format!("{prefix}/main_gui_map_mode_entry/icon"), 2));
                }
                e.actions.push((format!("{prefix}/main_gui_map_mode_entry/button"), format!("bar:mapmode:{k}")));
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
        // the planet view's commands that waited for the simulation (planet.rs)
        crate::planet::run_pending(self)?;
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

        // the name of the selection's window, localised (`none`: a planet the view names itself)
        let none = crate::galaxy::Name::default();
        let mut names: Vec<&crate::galaxy::Name> = Vec::new();
        // the selection's window: a fleet (a station: the starbase's), a planet
        let mut selected: Option<(String, u32)> = None;
        match self.selected {
            Some(Pickable::Fleet(id)) => {
                if let Some(f) = g.fleets.iter().find(|f| f.id == id && f.station) {
                    names.push(&f.name);
                    selected = Some((if f.station { "starbase" } else { "fleet" }.into(), id));
                }
            }
            Some(Pickable::Body(id)) => {
                if let Some((id, name, _)) = &body {
                    names.push(name);
                    selected = Some(("planet".into(), *id));
                } else {
                    // any other planet: the planet view names it from its own data (planet.rs;
                    // the world's, or the simulation's once it runs)
                    names.push(&none);
                    selected = Some(("planet".into(), id));
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
        // the planet view's data and tab (planet.rs), its owner's flag
        let mut planet_owner = None;
        match selected.as_ref() {
            Some(s) if s.kind == "planet" => {
                let tab = self.planet_view.tab_for(s.id).to_string();
                let colonize = self.planet_view.colonize == Some(s.id);
                let side = self.planet_view.side.clone();
                planet_owner = crate::planet::prepare(&self.runtime, self.map.as_ref().unwrap(), s.id, &tab, colonize, side.as_deref())?;
                crate::planet::set_extras(&self.runtime, &self.planet_view)?;
            }
            _ => crate::planet::clear(&self.runtime),
        }
        crate::starbase::prepare(&self.runtime, &g, &self.starbase, self.selected.is_some())?;
        let mut layout = gui::windows(&self.runtime, w, h, &[], selected.as_ref())?;
        if let Some(owner) = planet_owner {
            let map = self.map.as_mut().unwrap();
            let c = map.galaxy.countries.iter().position(|c| c.id == owner);
            map.flags(&mut layout.items, c);
        }
        if selected.as_ref().is_some_and(|s| s.kind == "planet") {
            crate::planet::portraits(self.map.as_mut().unwrap(), &mut layout.items, planet_owner.is_none());
        }
        // the main screen's other windows under the outliner and the selection's window
        let mut items = self.main_screen_items()?;
        items.extend(layout.items);
        // the fleet windows (fleetwin.rs): the selected fleet's fleet_view, ship_view, the fleet manager
        match self.fleet_items(w, h) {
            Ok(f) => items.extend(f),
            Err(e) => self.log.push(format!("fleet windows: {e}")),
        }
        // the event windows and popups, over the others (events.rs)
        let map = self.map.as_mut().unwrap();
        crate::starbase::flags(&self.runtime, &self.starbase, map, &mut items);
        let chunk = map.galaxy.events.clone();
        match crate::events::items(&mut self.events, &self.runtime, &self.game_dir, map.fonts.get_or_insert_with(HashMap::new), &chunk, w, h) {
            Ok(e) => items.extend(e),
            Err(e) => self.log.push(format!("events: {e}")),
        }
        // an event fired whose message type auto-pauses (the message settings): paused
        if self.events.take_pause() {
            self.commands.push(ClockCommand::Paused(true));
        }
        // an entry tracked or no longer: the galaxy's scene with its trackers again
        if self.events.take_trackers_changed() {
            self.scene = None;
        }
        // the left bar's view open (views.rs)
        if let Some(name) = self.open_view.clone() {
            let data = self.map.as_ref().and_then(|m| m.galaxy.views.get(&name).cloned());
            match crate::views::layout(&self.runtime, w, h, &name, data.as_ref(), &self.view_state) {
                Ok(l) => items.extend(l.items),
                Err(e) => self.log.push(format!("view {name}: {e}")),
            }
        }
        // the ship designer and the combat view over them
        let map = self.map.as_ref().unwrap();
        match crate::designer::layout(&self.runtime, map, &self.game_dir, w, h, &self.designer, combat) {
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
        // the diplomacy window open, over them (diplomacy.rs), its flags composed
        let observe = self.map.as_ref().is_some_and(|m| m.observe);
        let (mut diplo, flags) = self.diplomacy.items(&self.runtime, w, h, &g, observe)?;
        let map = self.map.as_mut().unwrap();
        for (i, id) in flags {
            let c = map.galaxy.countries.iter().position(|c| c.id == id);
            map.flags(std::slice::from_mut(&mut diplo[i]), c);
        }
        items.extend(diplo);
        // the in-game menu and its dialogs, over all (mainbars.rs)
        items.extend(crate::mainbars::menu_items(&self.runtime, w, h, &self.bars, &self.version)?);
        // the textures the windows name that are made (a disabled button greyed, a progress bar
        // filled: fleetwin.rs), for any window's items
        crate::fleetwin::derived_textures(map, &items);
        gui::fonts(&self.runtime, &self.game_dir, &items, map.fonts.get_or_insert_with(HashMap::new))?;
        Ok(items)
    }

    /// The scene must be built again (the world or the view changed).
    pub fn invalidate(&mut self) {
        self.scene = None;
    }

    /// The windows must be laid out again (a window opened or closed: their state changed).
    pub fn relayout_windows(&mut self) {
        self.overlay_key = None;
        self.scene = None;
    }

    /// The windows over the map must be laid out again (their state changed) and the scene built.
    pub fn relayout(&mut self) {
        self.overlay_key = None;
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
        let shown = match (&self.pending, self.screen) {
            (Some(p), Screen::Loading) => p.shown(),
            _ => ("", 0),
        };
        // (and the console's lines: laid out again when new ones came)
        let console = if self.console && self.screen == Screen::Loading { crate::console::generation() + 1 } else { 0 };
        let key = (self.size.0, self.size.1, self.screen, (shown.0, shown.1, console));
        if let Some((k, items)) = &self.items {
            if *k == key {
                return Ok(items.clone());
            }
        }
        let (w, h) = self.size;
        if let Some(name) = self.screen.newgame() {
            let l = gui::newgame(&self.runtime, w, h, name)?;
            self.notes = vec![l.note.clone()];
            if !l.missing.is_empty() {
                self.notes.push(format!("sprites without a definition or texture: {}", l.missing.join(", ")));
            }
            gui::fonts(&self.runtime, &self.game_dir, &l.items, &mut self.fonts)?;
            self.items = Some((key, l.items.clone()));
            return Ok(l.items);
        }
        if self.screen == Screen::Loading {
            let picture = self.pending.as_ref().and_then(|p| p.picture.clone());
            let mut l = gui::load_screen(&self.runtime, w, h, shown.0, shown.1, picture.as_deref())?;
            self.notes = vec![l.note.clone()];
            if !l.missing.is_empty() {
                self.notes.push(format!("sprites without a definition or texture: {}", l.missing.join(", ")));
            }
            // the renderer's console over it (console.rs; not the game's)
            if self.console {
                let lines = crate::console::tail(80);
                l.items.extend(gui::load_console(&self.runtime, w, h, &lines)?);
            }
            gui::fonts(&self.runtime, &self.game_dir, &l.items, &mut self.fonts)?;
            self.items = Some((key, l.items.clone()));
            return Ok(l.items);
        }
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
            let rows: Vec<gui::SaveRow> = saves
                .iter()
                .map(|s| gui::SaveRow {
                    name: &s.name,
                    date: &s.date,
                    file: &s.file,
                    path: &s.path,
                    dir: &s.dir,
                    meta: &s.meta,
                    modified: s.modified.duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs() as f64),
                })
                .collect();
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
                let key = self.map.as_ref().map(|m| (w, h, self.view, self.selected, m.snapshot.as_ref().map_or(0, |s| s.generation), m.gui, m.paused, self.camera.is_some_and(|c| c.distance <= 400.0), m.observe, self.fleet.key()));
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
                // the leaders' portraits in the views (portraits.rs)
                crate::portraits::fill_insets(&mut scene, &mut map.models, &map.runtime, &self.game_dir, &mut map.textures, &mut cache.borrow_mut());
            }
            // the Situation Log's trackers on the galaxy (events.rs)
            if let (Screen::Map, Some(map)) = (self.screen, self.map.as_mut()) {
                crate::events::draw_trackers(&mut scene, &self.runtime, map, self.view, &self.game_dir);
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

    pub(crate) fn button_at(&mut self, x: f32, y: f32) -> Result<Option<(String, Option<String>)>, String> {
        // the in-game menu or its dialog open: only their buttons take the input (their dimmed
        // layer covers the screen, the map labels too: mainbars.rs)
        if let Some(prefix) = crate::mainbars::modal(&self.bars) {
            let scene = self.scene()?;
            let hit = scene.buttons.iter().rev().find(|b| b.path.starts_with(prefix) && x >= b.rect[0] && x < b.rect[2] && y >= b.rect[1] && y < b.rect[3]);
            return Ok(hit.map(|b| (b.path.clone(), b.action.clone())));
        }
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
        // the left bar opens under the cursor (mainbars.rs)
        if self.screen == Screen::Map && crate::mainbars::hover(self, x, y) {
            self.relayout();
        }
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
        self.map_press = Some((x, y));
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
            // an armed fleet order takes the click as its target (fleetwin.rs)
            if self.fleet_target(hit)? {
                return Ok(true);
            }
            self.select(hit);
            return Ok(true);
        }
        Ok(false)
    }

    /// A right click on a GUI button whose action is `LEFT||RIGHT` (a monthly trade's entry:
    /// removed): RIGHT done; whether there was one.
    fn gui_right_click(&mut self, x: f32, y: f32) -> Result<bool, String> {
        if let Some((path, Some(a))) = self.button_at(x, y)? {
            if let Some((_, right)) = a.split_once("||") {
                let right = right.to_string();
                self.log.push(format!("right click: {path} -> {right}"));
                self.act(&path, Some(&right))?;
                return Ok(true);
            }
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

    /// A button's action done as its click does it (the command protocol's window commands).
    pub fn action(&mut self, action: &str) -> Result<(), String> {
        self.act("/command", Some(action))
    }

    fn act(&mut self, path: &str, action: Option<&str>) -> Result<(), String> {
        self.log.push(format!("click: {path} -> {}", action.unwrap_or("no action")));
        // an action `LEFT||RIGHT`: a left click does LEFT (a right click RIGHT: gui_right_click)
        let action = action.map(|a| a.split_once("||").map_or(a, |(l, _)| l));
        match action {
            Some("exit") => self.exit = true,
            // the main menu's New Game: the empire selection with a new setup (render.newgame_setup)
            Some("new_game") => self.newgame_act("ng:open")?,
            Some(a) if a.starts_with("ng:") || a.starts_with("creator:") => self.newgame_act(a)?,
            Some("open_load") => {
                // the window opens on its first session (CLoadGameView::Show)
                gui::load_act(&self.runtime, "loadwin:open")?;
                self.show(Screen::Load);
            }
            // the load window's sessions, saves, delete toggle (render.frontend.load_act): laid out
            // again, or a save loaded
            Some(a) if a.starts_with("loadwin:") => {
                let load = gui::load_act(&self.runtime, a)?;
                self.items = None;
                self.scene = None;
                if let Some(path) = load {
                    if self.async_loads {
                        self.start_load_save(&path)?;
                    } else {
                        self.load(&path)?;
                    }
                }
            }
            Some("close_load") => self.show(Screen::Menu),
            // the galaxy setup's Start (CFrontEndIdler::LaunchNewGame): a new game from the setup
            Some("start_new_game") => {
                let settings = self.newgame_setup.clone().unwrap_or_default();
                self.start_new_game(settings)?;
            }
            Some(a) if a.starts_with("load:") => {
                let i: usize = a[5..].parse().map_err(|_| format!("bad action {a}"))?;
                let path = self.saves().get(i - 1).map(|s| s.path.clone()).ok_or(format!("no save {i}"))?;
                if self.async_loads {
                    self.start_load_save(&path)?;
                } else {
                    self.load(&path)?;
                }
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
            // the event windows' and popups' buttons (events.rs)
            Some(a) if crate::events::handles(a) => crate::events::app_act(self, a)?,
            // the diplomacy windows (diplomacy.rs): Contacts from the left bar, the others from it
            Some(a) if a == "view:contacts" || a.starts_with("diplo:") => crate::diplomacy::act(self, a)?,
            // the left bar's views (views.rs): a button toggles its view, a view's close button
            // closes it, `view_set:KEY=VALUE;KEY2=VALUE2` sets keys of the view's state (`KEY=`
            // removes one)
            Some(a) if a.starts_with("view:") => {
                self.toggle_view(&a[5..]);
            }
            Some("view_close") => self.close_view(),
            // a view's command in the simulation (views.rs): `cmd:VIEW:ARG...`, then `#K=V;K2=` the
            // view's state set (a side window closed after a choice)
            Some(a) if a.starts_with("cmd:") => {
                let (cmd, then) = a[4..].split_once('#').unwrap_or((&a[4..], ""));
                let mut parts = cmd.split(':');
                let view = parts.next().unwrap_or("").to_string();
                let args: Vec<&str> = parts.collect();
                let map = self.map.as_mut().ok_or("no map")?;
                let r = crate::views::command(map, &view, &args)?;
                self.log.push(format!("{view}: {r}"));
                let pairs: Vec<(&str, &str)> = if then.is_empty() { Vec::new() } else { then.split(';').map(|kv| kv.split_once('=').unwrap_or((kv, ""))).collect() };
                self.set_view_state(&pairs);
            }
            Some(a) if a.starts_with("view_set:") => {
                let pairs: Vec<(&str, &str)> = a[9..].split(';').map(|kv| kv.split_once('=').unwrap_or((kv, ""))).collect();
                self.set_view_state(&pairs);
            }
            // the selection's window closed; an outliner row selects its planet or fleet
            Some("close") => self.select(None),
            Some(a) if a.starts_with("fleet:") => self.fleet_act(a)?,
            // the planet view's and the colonize window's clicks (planet.rs)
            Some(a) if a.starts_with("planet:") => crate::planet::act(self, a)?,
            // the map labels' own actions (mapicons.rs: a star label slides the camera there)
            Some(a) if a.starts_with("map:") => self.map_act(a)?,
            Some(a) if a.starts_with("select:") => self.select(Some(pickable_of(a)?)),
            Some(a) if a.starts_with("starbase:") => crate::starbase::act(self, a)?,
            Some(a) if a.starts_with("economy:") => crate::economy::act(self, a)?,
            // the outliner's tabs, groups, observer list (outliner.rs State::act): laid out again
            Some(a) if a.starts_with("outliner:") => {
                if self.outliner.act(&a["outliner:".len()..]) {
                    self.overlay_key = None;
                    self.scene = None;
                }
            }
            Some(a) if a.starts_with("designer:") => crate::designer::act(self, a)?,
            // the bars, the alerts, the in-game menu (mainbars.rs)
            Some(a) if crate::mainbars::handles(a) => crate::mainbars::act(self, a)?,
            Some(other) => self.log.push(format!("  {other}: not done yet (its window is not laid out)")),
            None => {}
        }
        Ok(())
    }

    /// A left bar view toggled (CInGameIdler::ToggleTopBarView): shown, it is hidden; else the
    /// view open is closed and it is shown, its state anew. Whether it is shown.
    pub fn toggle_view(&mut self, name: &str) -> bool {
        // Contacts is diplomacy.rs's (the `view:contacts` action)
        if name == "contacts" {
            let _ = self.diplomacy.act("view:contacts");
            let shown = self.diplomacy.open == Some(crate::diplomacy::Open::Contacts);
            if shown {
                self.close_view();
                self.set_designer(Default::default());
            }
            self.overlay_key = None;
            self.scene = None;
            return shown;
        }
        if self.open_view.as_deref() == Some(name) {
            self.close_view();
            return false;
        }
        self.log.push(format!("view: {name}"));
        // the other views closed: Contacts (diplomacy.rs) and the ship designer
        if self.diplomacy.open == Some(crate::diplomacy::Open::Contacts) {
            self.diplomacy.open = None;
        }
        self.set_designer(Default::default());
        self.open_view = Some(name.to_string());
        // its data (views.rs: the snapshots carry the open view's only)
        crate::views::set_open(Some(name));
        let smooth = self.smooth;
        if let Some(m) = self.map.as_mut() {
            m.refresh_view(name, !smooth);
        }
        self.view_state.clear();
        self.overlay_key = None;
        self.scene = None;
        true
    }

    /// Keys of the open view's state set (an empty value removes the key).
    pub fn set_view_state(&mut self, pairs: &[(&str, &str)]) {
        for (k, v) in pairs {
            if v.is_empty() {
                self.view_state.remove(*k);
            } else {
                self.view_state.insert(k.to_string(), v.to_string());
            }
        }
        self.overlay_key = None;
        self.scene = None;
    }

    /// Escape on the open view: its side windows closed (the state keys its module lists in
    /// `escape_keys`; without the list, all its state), true; nothing to close there, false.
    fn view_escape(&mut self) -> bool {
        let Some(name) = self.open_view.clone() else { return false };
        // a view with M.escape(state) says what Escape does: its innermost window closed (a popup,
        // then its dialog)
        if !self.view_state.is_empty() {
            if let Some(a) = crate::views::escape(&self.runtime, &name, &self.view_state) {
                return self.act("/key/escape", Some(&a)).is_ok();
            }
        }
        let keys: Vec<String> = match crate::views::escape_keys(&self.runtime, &name) {
            Some(list) => list.into_iter().filter(|k| self.view_state.contains_key(k)).collect(),
            None => self.view_state.keys().cloned().collect(),
        };
        if keys.is_empty() {
            return false;
        }
        let pairs: Vec<(&str, &str)> = keys.iter().map(|k| (k.as_str(), "")).collect();
        self.set_view_state(&pairs);
        true
    }

    /// The wheel over the open view: its lists scroll (views::wheel); whether it took it.
    fn view_wheel(&mut self, notches: f32) -> bool {
        let (Some(name), Some((x, y))) = (self.open_view.clone(), self.cursor) else { return false };
        let data = self.map.as_ref().and_then(|m| m.galaxy.views.get(&name).cloned());
        let (w, h) = self.size;
        match crate::views::wheel(&self.runtime, w, h, &name, data.as_ref(), &self.view_state, notches, x, y) {
            Some(pairs) => {
                if !pairs.is_empty() {
                    let p: Vec<(&str, &str)> = pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                    self.set_view_state(&p);
                }
                true
            }
            None => false,
        }
    }

    pub fn close_view(&mut self) {
        if let Some(v) = self.open_view.take() {
            crate::views::set_open(None);
            self.log.push(format!("view: {v} closed"));
            self.view_state.clear();
            self.overlay_key = None;
            self.scene = None;
        }
    }

    /// Whether the left bar's view NAME is shown (its button's state): the open view, or
    /// Contacts in diplomacy.rs.
    pub fn view_shown(&self, name: &str) -> bool {
        self.open_view.as_deref() == Some(name)
            || (name == "contacts" && self.diplomacy.open == Some(crate::diplomacy::Open::Contacts))
    }

    /// The ship designer opened, closed or given a design (designer.rs): the windows laid out again.
    pub fn set_designer(&mut self, d: crate::designer::Designer) {
        if d != self.designer {
            // the designer opened: the left bar's view closed (one at a time)
            if d.open && !self.designer.open {
                self.close_view();
                if self.diplomacy.open == Some(crate::diplomacy::Open::Contacts) {
                    self.diplomacy.open = None;
                }
            }
            self.designer = d;
            self.overlay_key = None;
            self.scene = None;
        }
    }

    /// An action of the new game's screens (render.frontend_newgame.act on the setup state
    /// RENDER_NEWGAME): the screen it goes to, laid out again.
    fn newgame_act(&mut self, action: &str) -> Result<(), String> {
        let to = gui::newgame_act(&self.runtime, action, self.cursor.unwrap_or((0.0, 0.0)))?;
        self.log.push(format!("new game: {action} -> {}", to.as_deref().unwrap_or("-")));
        self.items = None;
        self.scene = None;
        match to.as_deref() {
            Some("menu") => self.show(Screen::Menu),
            Some("select") => self.show(Screen::SelectEmpire),
            Some("creator") => self.show(Screen::Creator),
            Some("setup") => self.show(Screen::GameSetup),
            Some("play") => self.newgame_play()?,
            _ => {}
        }
        Ok(())
    }

    /// Play on the galaxy settings (and Return there): a new game from the setup state
    /// (render.newgame_setup.settings of RENDER_NEWGAME, newgame.rs NewGameSettings::from_lua).
    fn newgame_play(&mut self) -> Result<(), String> {
        let settings = {
            let t: stellar_sim::mlua::Table = self
                .runtime
                .lua
                .load("return require('render.newgame_setup').settings(RENDER_NEWGAME)")
                .eval()
                .map_err(|e| format!("render.newgame_setup.settings: {e}"))?;
            crate::newgame::NewGameSettings::from_lua(&self.runtime.lua, &t).map_err(|e| format!("the new game's settings: {e}"))?
        };
        let summary = gui::newgame_summary(&self.runtime)?;
        self.log.push(format!("new game: play {summary}"));
        self.start_new_game(settings)
    }

    /// The game resigned (CInGameIdler::DoResign): the map left for the main menu.
    pub(crate) fn resign(&mut self) {
        self.close_view();
        self.select(None);
        self.map = None;
        self.overlay_key = None;
        self.show(Screen::Menu);
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
        let map = if sim { Map::load_sim(&self.game_dir, path)? } else { Map::load(&self.game_dir, path)? };
        self.pending = None;
        self.show_map(map, path, t0)
    }

    /// A new game started from `settings` (the setup's: newgame.rs): the load screen shown while
    /// the simulation's thread generates, loads and starts it ([`App::advance`] moves the bar and
    /// shows the game when it is ready, paused, on the player's capital).
    pub fn start_new_game(&mut self, settings: crate::newgame::NewGameSettings) -> Result<(), String> {
        let progress = std::sync::Arc::new(crate::newgame::Progress::default());
        self.log.push(format!("new game: {}", settings.describe()));
        // the previous game's simulation stops (the game destroys its game state first)
        self.map = None;
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos() as u64);
        let seed = std::env::var("STELLAR_LOADSCREEN").ok().and_then(|v| v.parse().ok()).unwrap_or(seed);
        let clock = clock::Clock::start_from(&self.game_dir, clock::Source::NewGame(settings.clone(), progress.clone()), true, clock::DEFAULT_SPEED, None);
        self.pending = Some(Pending {
            settings,
            save: None,
            progress,
            clock: Some(clock),
            bar: Default::default(),
            picture: crate::newgame::background(&self.game_dir, seed),
            started: Instant::now(),
            map_gfx: None,
            map_at: None,
            report: None,
        });
        self.show(Screen::Loading);
        Ok(())
    }

    /// The load screens' console shown or hidden (console.rs).
    pub fn set_console(&mut self, on: bool) {
        self.console = on;
        self.items = None;
        self.scene = None;
    }

    /// A save loaded behind the load screen (the window's Load and Continue; the command `load-sim
    /// async PATH`): the simulation's thread loads it, then the map is shown as after a new game.
    pub fn start_load_save(&mut self, path: &str) -> Result<(), String> {
        self.log.push(format!("loading {path}"));
        self.map = None;
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos() as u64);
        let seed = std::env::var("STELLAR_LOADSCREEN").ok().and_then(|v| v.parse().ok()).unwrap_or(seed);
        let clock = clock::Clock::start_from(&self.game_dir, clock::Source::Save(path.to_string()), true, clock::DEFAULT_SPEED, None);
        self.pending = Some(Pending {
            settings: Default::default(),
            save: Some(path.to_string()),
            progress: Default::default(),
            clock: Some(clock),
            bar: Default::default(),
            picture: crate::newgame::background(&self.game_dir, seed),
            started: Instant::now(),
            map_gfx: None,
            map_at: None,
            report: None,
        });
        self.show(Screen::Loading);
        Ok(())
    }

    /// A frame of the load screen: the bar moved as the game moves it while the game is made, then
    /// the map made (LOAD_MAP_GFX at 0) and shown (at 100). Whether the screen changed.
    fn loading(&mut self, dt: f32) -> Result<bool, String> {
        // the screen laid out again when the console has new lines (the app's log reaches it
        // where it is written out, once: the window's eprintln!, the engine's flush_log)
        let changed = self.loading_step(dt)?;
        let gen = crate::console::generation();
        if self.console && self.screen == Screen::Loading && gen != self.console_gen {
            self.console_gen = gen;
            self.scene = None;
            return Ok(true);
        }
        Ok(changed)
    }

    fn loading_step(&mut self, dt: f32) -> Result<bool, String> {
        let Some(p) = self.pending.as_mut() else {
            self.show(Screen::Menu);
            return Ok(true);
        };
        let before = p.shown();
        match p.map_gfx {
            None => {
                let status = p.clock.as_ref().map(|c| c.status()).unwrap_or_default();
                if let Some(e) = status.error {
                    return Err(e);
                }
                if status.ready {
                    // LaunchNewGame draws 50 when the task is done, then the in-game idler's
                    // RestoreDeviceObjects begins at its step 0
                    p.report = status.report;
                    p.map_gfx = Some(0);
                } else {
                    p.bar.advance(dt, p.progress.stage(), p.progress.world_gen());
                }
            }
            Some(0) => {
                let clock = p.clock.take().ok_or("no simulation")?;
                let t0 = p.started;
                let name = p.save.clone().unwrap_or_else(|| "a new game".into());
                let map = Map::of_clock(&self.game_dir, &name, clock)?;
                self.show_map(map, &name, t0)?;
                let p = self.pending.as_mut().unwrap();
                p.map_gfx = Some(100);
                self.screen = Screen::Loading;
                self.scene = None;
            }
            Some(_) => {
                // the capital's system as the simulation sends it (its bodies and ships: its
                // thread reads the models' index first, seconds on a medium galaxy): the load
                // screen stays at LOAD_MAP_GFX until it has come, as RestoreDeviceObjects makes
                // the map's graphics before DestroyLoadScreen (at most 60 s)
                if let (MapView::System(i), Some(map)) = (self.view, self.map.as_mut()) {
                    let id = map.galaxy.systems[i].id;
                    map.sync();
                    let has = map.snapshot.as_ref().and_then(|s| s.system.as_ref()).is_some_and(|(sid, _)| *sid == id);
                    let p = self.pending.as_mut().unwrap();
                    let since = *p.map_at.get_or_insert_with(Instant::now);
                    if !has && since.elapsed() < std::time::Duration::from_secs(60) {
                        return Ok(false);
                    }
                }
                // DestroyLoadScreen: the game is shown
                let p = self.pending.take().unwrap();
                match &p.save {
                    Some(path) => self.log.push(format!("{path} loaded behind the load screen in {:.1} s", p.started.elapsed().as_secs_f64())),
                    None => self.log.push(format!("new game ({}) started in {:.1} s", p.settings.describe(), p.started.elapsed().as_secs_f64())),
                }
                if let Some(r) = p.report {
                    self.log.push(r);
                }
                self.show(Screen::Map);
                return Ok(true);
            }
        }
        let p = self.pending.as_ref().unwrap();
        if p.shown() != before {
            self.scene = None;
            return Ok(true);
        }
        Ok(false)
    }

    /// Waits for the new game in progress to be shown (commands: `newgame` without `async`,
    /// `loaded`), a frame of `dt` each 16 ms; what it took.
    pub fn finish_loading(&mut self) -> Result<String, String> {
        let t0 = Instant::now();
        while self.screen == Screen::Loading && self.pending.is_some() {
            self.loading(0.016)?;
            if self.pending.is_some() {
                std::thread::sleep(std::time::Duration::from_millis(16));
            }
        }
        if self.screen != Screen::Map {
            return Err("the new game did not start (see the log)".into());
        }
        Ok(format!("{:.1} s", t0.elapsed().as_secs_f64()))
    }

    /// The map made the app's, its galaxy camera and the capital's system set up as the game does
    /// after a load; the map screen shown.
    fn show_map(&mut self, mut map: Map, path: &str, t0: Instant) -> Result<(), String> {
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
        self.events = Default::default();
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
        if self.async_loads {
            self.start_load_save(&path)
        } else {
            self.load(&path)
        }
    }

    /// Physical input (controls.rs): the bindings' effects carried out. `now_ms`: the input's
    /// time (a double click's). Whether something changed.
    pub fn input(&mut self, input: &Input, now_ms: f64) -> Result<bool, String> {
        // the empire creator's text fields (render.newgame_creator): with one focused, a key
        // typed goes to it (the game's CEditBox takes the keyboard), Shift giving capitals
        if self.screen == Screen::Creator {
            if let Input::Key { key, down: true, .. } = input {
                if !matches!(key.as_str(), "shift" | "ctrl" | "alt") && self.creator_focused() {
                    if let Some(a) = creator_key(key, self.controls.mods().shift) {
                        self.newgame_act(&a)?;
                        return Ok(true);
                    }
                }
            }
        }
        // the planet view's rename dialog takes the keyboard (its edit box), as the creator's fields
        if self.screen == Screen::Map && self.planet_view.dialog.as_deref() == Some("rename") {
            if let Input::Key { key, down, .. } = input {
                if !matches!(key.as_str(), "shift" | "ctrl" | "alt") {
                    // a key's release too: the bindings act on release (Space: pause)
                    if !*down {
                        return Ok(false);
                    }
                    if let Some(a) = creator_key(key, self.controls.mods().shift).and_then(|a| crate::planet::typed(&self.planet_view, &a)) {
                        crate::planet::act(self, &a)?;
                        return Ok(true);
                    }
                }
            }
        }
        // a text box of the open view (a rename dialog's: views::text_focus) has the keyboard: a key
        // typed goes to it (its press; its release taken too, so no shortcut fires), RETURN its OK;
        // ESCAPE goes on to the view's Escape (the dialog's Cancel)
        if self.screen == Screen::Map {
            if let (Input::Key { key, down, .. }, Some(name)) = (input, self.open_view.clone()) {
                if !matches!(key.as_str(), "shift" | "ctrl" | "alt" | "escape") && crate::views::text_focus(&self.runtime, &name, &self.view_state) {
                    if *down {
                        if let Some(t) = creator_key(key, self.controls.mods().shift) {
                            let token = t.trim_start_matches("creator:").to_string();
                            if let Some((pairs, action)) = crate::views::text_key(&self.runtime, &name, &self.view_state, &token) {
                                let p: Vec<(&str, &str)> = pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                                self.set_view_state(&p);
                                if let Some(a) = action {
                                    self.act("/key", Some(&a))?;
                                }
                            }
                        }
                    }
                    return Ok(true);
                }
            }
        }
        // the bars' .gui shortcuts (F1..F10, F, L, Alt+B, Ctrl+Z ..., O: mainbars.rs), on release
        if self.screen == Screen::Map {
            if let Input::Key { key, down: false, .. } = input {
                let m = self.controls.mods();
                if let Some(a) = crate::mainbars::shortcut(key, m.ctrl, m.alt, m.shift) {
                    self.act("/key", Some(&a))?;
                    return Ok(true);
                }
                // the event windows', popups' and their views' shortcuts (events.rs)
                if let Some(a) = crate::events::key(self, key) {
                    self.act("/key", Some(&a))?;
                    return Ok(true);
                }
            }
        }
        let ctx = self.context();
        let mut changed = false;
        for e in self.controls.input(input, now_ms, ctx) {
            changed |= self.apply(e)?;
        }
        Ok(changed)
    }

    /// Whether a text field of the empire creator has the keyboard.
    fn creator_focused(&self) -> bool {
        self.runtime
            .lua
            .load("return RENDER_NEWGAME ~= nil and RENDER_NEWGAME.creator ~= nil and RENDER_NEWGAME.creator.focus ~= nil")
            .eval::<bool>()
            .unwrap_or(false)
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
            Effect::At(Action::Order, x, y) if self.screen == Screen::Map => {
                // a button's own right click (`action||right`: the market's amounts, economy)
                if self.gui_right_click(x, y)? {
                    return Ok(true);
                }
                // a map label orders as the place it is on (mapicons.rs order_at); another GUI
                // element takes the right click itself (an alert dismissed, an outliner row's
                // camera: mainbars.rs), never an order under it
                let label = matches!(self.button_at(x, y)?, Some((p, _)) if p.starts_with("/label/"));
                if !label && crate::mainbars::right_click(self, x, y)? {
                    return Ok(true);
                }
                self.order_at(x, y)
            }
            Effect::At(Action::BoxSelect, x, y) if self.screen == Screen::Map && self.pressed.is_none() => self.box_select(x, y),
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
            Effect::Zoom(n, _) if self.screen.newgame().is_some() => {
                self.newgame_act(&format!("ng:wheel:{n}"))?;
                Ok(true)
            }
            // the wheel over the open view's list scrolls it (the view's own `wheel`)
            Effect::Zoom(n, _) if self.view_wheel(n) => Ok(true),
            // the wheel over the starbase window's side view scrolls its list (starbase.rs)
            Effect::Zoom(n, _) if crate::starbase::wheel(self, n) => Ok(true),
            // the wheel over the ship designer's lists (designer.rs)
            Effect::Zoom(n, _) if self.designer.open && { let at = self.cursor; crate::designer::wheel(self, n, at) } => Ok(true),
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
            // the load window opened from the in-game menu: back to the map (mainbars.rs)
            (Action::Back, Screen::Load) if self.bars.load_from_game && self.map.is_some() => {
                self.bars.load_from_game = false;
                self.show(Screen::Map);
                self.relayout();
                Ok(true)
            }
            (Action::Back, Screen::Load) => {
                self.log.push(format!("escape: {:?} -> Menu", self.screen));
                self.show(Screen::Menu);
                Ok(true)
            }
            (Action::Back, s) if s.newgame().is_some() => {
                self.newgame_act("ng:back")?;
                Ok(true)
            }
            (Action::Accept, s) if s.newgame().is_some() => {
                self.newgame_act("ng:accept")?;
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
            (Action::ToggleConsole, _) => {
                self.set_console(!self.console);
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
                    // the in-game menu and its dialogs are over the other windows (mainbars.rs)
                    Action::Back if crate::mainbars::escape(self, true)? => {}
                    // a popup's and the first contact view's ESCAPE (events.rs)
                    Action::Back if crate::events::escape(self) => {}
                    // the fleet windows' close buttons first (their ESCAPE shortcut)
                    Action::Back if self.fleet_escape() => {}
                    // the open view's close buttons (shortcut ESCAPE) have the key first (the
                    // GUI's input before the idler's): a side window's (the view's state: the
                    // game's frames, the researched window closes and the view stays), then the
                    // view's
                    // (a view that lists its side windows' keys, M.escape_keys, has those closed
                    // first and is closed itself otherwise: its other keys are its filters, tabs)
                    Action::Back if self.open_view.is_some() && self.view_escape() => {}
                    Action::Back if self.open_view.is_some() => self.close_view(),
                    // the diplomacy window closes first (its close button: ESCAPE)
                    Action::Back if self.diplomacy.open.is_some() => self.act("/key/escape", Some("diplo:escape"))?,
                    // the designer's close button has the shortcut ESCAPE (ship_designer.gui)
                    Action::Back if self.designer.open => crate::designer::escape(self),
                    // the starbase window's dialog, then its side view (a slot's), close before the window
                    Action::Back if self.starbase.dialog.is_some() => {
                        self.starbase.dialog = None;
                        self.relayout();
                    }
                    Action::Back if self.selected.is_some() && self.starbase.side.is_some() => {
                        self.starbase.side = None;
                        self.relayout();
                    }
                    Action::Back if self.starbase.megastructure.is_some() || self.starbase.network.is_some() => {
                        self.starbase.megastructure = None;
                        self.starbase.network = None;
                        self.relayout();
                    }
                    // the planet view's side bar, then its colonize window (their close buttons:
                    // ESCAPE), before the view
                    Action::Back if crate::planet::escape(self) => {}
                    Action::Back if self.selected.is_some() => self.select(None),
                    // nothing open: the game's menu window opens (main_bottom.gui button_topbar_menu,
                    // shortcut ESCAPE: mainbars.rs)
                    Action::Back => {
                        crate::mainbars::escape(self, false)?;
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

/// A key typed into the empire creator's focused field: its character (`creator:text:C`) or an
/// editing key (`creator:key:NAME`); keys are named by their place on a US layout (controls.rs).
fn creator_key(key: &str, shift: bool) -> Option<String> {
    let c = match key {
        "space" => " ".to_string(),
        "minus" => if shift { "_" } else { "-" }.to_string(),
        "apostrophe" => if shift { "\"" } else { "'" }.to_string(),
        "period" => ".".to_string(),
        "comma" => ",".to_string(),
        "backspace" | "return" | "escape" | "tab" | "delete" => return Some(format!("creator:key:{key}")),
        k if k.len() == 1 && k.chars().all(|c| c.is_ascii_alphanumeric()) => {
            if shift { k.to_ascii_uppercase() } else { k.to_string() }
        }
        _ => return None,
    };
    Some(format!("creator:text:{c}"))
}
