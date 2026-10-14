//! The front end and the map as one application, for the window and for headless runs: the main
//! menu, the load game window over it, and the galaxy map of a loaded save. The mouse moves,
//! presses and releases over the GUI's buttons (whose sprites show their hover and pressed
//! frames); a click does the button's action:
//! - Exit closes; Load Game opens the load window; its Cancel closes it; a save in it loads that
//!   save and shows its galaxy map with the top bar;
//! - Continue (the key C on the menu: 4.5.2's front end has no Continue button; the launcher
//!   has it) loads the newest save;
//! - New Game, Multiplayer, Cooperative, Additional Content, Settings and Credits do nothing yet
//!   (their windows are not laid out);
//! - Escape on the map goes back to the menu, and closes the load window.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use stellar_sim::{save, Runtime};

use crate::camera::OrbitCamera;
use crate::dds::Cache;
use crate::font::Font;
use crate::models;
use crate::system;
use crate::gui::{self, GuiItem};
use crate::scene::{self, ButtonState, Scene, Textures};
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
    /// the map: in 3D from `camera` (else the 2D map), the galaxy or a system
    pub mode3d: bool,
    pub camera: Option<OrbitCamera>,
    pub view: MapView,
    pub system_camera: Option<OrbitCamera>,
    /// the model view: the model shown (an entity or a pdxmesh), and the models read for it
    pub model: Option<String>,
    pub models: models::Library,
    hover: Option<String>,
    pressed: Option<String>,
    items: Option<((u32, u32, Screen), Vec<GuiItem>)>,
    scene: Option<Scene>,
    generation: u64,
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
            model: None,
            models: models::Library::default(),
            hover: None,
            pressed: None,
            items: None,
            scene: None,
            generation: 0,
        })
    }

    /// The camera of what the map shows (the galaxy's or the system's).
    pub fn current_camera(&mut self) -> Option<&mut OrbitCamera> {
        match self.view {
            MapView::Galaxy => self.camera.as_mut(),
            MapView::System(_) | MapView::Model => self.system_camera.as_mut(),
        }
    }

    /// Moves the camera (degrees), zooms it (a factor), pans it (fractions of its distance).
    pub fn orbit(&mut self, dyaw: f32, dpitch: f32) {
        if let Some(c) = self.current_camera() {
            c.orbit(dyaw.to_radians(), dpitch.to_radians());
        }
        self.scene = None;
    }
    pub fn zoom(&mut self, factor: f32) {
        if let Some(c) = self.current_camera() {
            c.zoom(factor);
        }
        self.scene = None;
    }
    pub fn pan(&mut self, dx: f32, dy: f32) {
        if let Some(c) = self.current_camera() {
            c.pan(dx, dy);
        }
        self.scene = None;
    }
    pub fn set_camera(&mut self, c: OrbitCamera) {
        match self.view {
            MapView::Galaxy => self.camera = Some(c),
            MapView::System(_) | MapView::Model => self.system_camera = Some(c),
        }
        self.scene = None;
    }

    /// Shows the galaxy, or a system (by the save's id), on the map screen.
    pub fn show_galaxy(&mut self) {
        self.view = MapView::Galaxy;
        self.screen = Screen::Map;
        self.scene = None;
    }
    pub fn show_system(&mut self, index: usize) -> Result<(), String> {
        let map = self.map.as_mut().ok_or("no map loaded")?;
        if index >= map.galaxy.systems.len() {
            return Err(format!("no system {index}"));
        }
        self.system_camera = Some(system::camera_for(map, index));
        self.view = MapView::System(index);
        self.screen = Screen::Map;
        self.scene = None;
        self.log.push(format!("system view: {} (id {})", map.galaxy.systems[index].star_class, map.galaxy.systems[index].id));
        Ok(())
    }

    /// Shows a model alone (an entity or a pdxmesh of gfx/models), with a camera fitted to it.
    pub fn show_model(&mut self, name: &str) -> Result<(), String> {
        let cam = system::model_camera(&mut self.models, &self.runtime, &self.game_dir, name)?;
        self.system_camera = Some(cam);
        self.model = Some(name.to_string());
        self.view = MapView::Model;
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
        self.scene.as_ref().map(|s| (s, self.textures()))
    }

    /// The scene of the current screen (rebuilt when something changed).
    pub fn scene(&mut self) -> Result<&Scene, String> {
        if self.scene.is_none() {
            let (w, h) = self.size;
            let scene = match self.screen {
                Screen::Map if self.view == MapView::Model => {
                    let cam = self.system_camera.ok_or("no camera")?;
                    let name = self.model.clone().ok_or("no model")?;
                    let mut cache = self.cache.borrow_mut();
                    system::model_scene(&mut self.models, &self.runtime, &self.game_dir, &name, &cam, w, h, &mut self.textures, &mut cache)?
                }
                Screen::Map => {
                    let map = self.map.as_mut().ok_or("no map")?;
                    match (self.view, &self.system_camera) {
                        (MapView::System(i), Some(cam)) => system::build(map, i, cam, w, h)?,
                        _ => {
                            let cam = if self.mode3d { self.camera.as_ref() } else { None };
                            map.frame(w, h, cam)?.scene
                        }
                    }
                }
                _ => {
                    let items = self.items()?;
                    let mut states = HashMap::new();
                    if let Some(p) = &self.hover {
                        states.insert(p.clone(), ButtonState::Hover);
                    }
                    if let Some(p) = &self.pressed {
                        states.insert(p.clone(), ButtonState::Pressed);
                    }
                    scene::gui_scene(w, h, &items, &self.fonts, &mut self.textures, &mut self.cache.borrow_mut(), &self.game_dir, &states)
                }
            };
            self.scene = Some(scene);
            // a new scene, whoever asked for it (a hit test builds it too)
            self.generation += 1;
        }
        Ok(self.scene.as_ref().unwrap())
    }

    /// The textures of the current screen's scene.
    pub fn textures(&self) -> &Textures {
        match (&self.screen, &self.map) {
            (Screen::Map, Some(m)) if self.view != MapView::Model => &m.textures,
            _ => &self.textures,
        }
    }

    fn button_at(&mut self, x: f32, y: f32) -> Result<Option<(String, Option<String>)>, String> {
        if self.screen == Screen::Map {
            return Ok(None);
        }
        Ok(self.scene()?.button_at(x, y).map(|b| (b.path.clone(), b.action.clone())))
    }

    /// The mouse moved: the button under it shows its hover frame. Whether the frame changed.
    pub fn mouse_move(&mut self, x: f32, y: f32) -> Result<bool, String> {
        let hover = self.button_at(x, y)?.map(|b| b.0);
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

    /// The button released over the one pressed is a click: its action is done. On the galaxy
    /// map, a click on a star opens its system.
    pub fn mouse_up(&mut self, x: f32, y: f32) -> Result<bool, String> {
        if self.screen == Screen::Map {
            if self.view == MapView::Galaxy {
                let hit = self.scene()?.star_at(x, y, 14.0);
                if let Some(i) = hit {
                    self.show_system(i)?;
                    return Ok(true);
                }
            }
            return Ok(false);
        }
        let under = self.button_at(x, y)?;
        let pressed = self.pressed.take();
        self.scene = None;
        match (under, pressed) {
            (Some((path, action)), Some(p)) if path == p => {
                self.act(&path, action.as_deref())?;
                Ok(true)
            }
            _ => Ok(true),
        }
    }

    /// A click at (x, y): press and release.
    pub fn click(&mut self, x: f32, y: f32) -> Result<(), String> {
        self.mouse_move(x, y)?;
        self.mouse_down(x, y)?;
        if self.pressed.is_none() {
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
            Some(other) => self.log.push(format!("  {other}: not done yet (its window is not laid out)")),
            None => {}
        }
        Ok(())
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
        let radius = map.galaxy.systems.iter().map(|s| (s.x * s.x + s.y * s.y).sqrt()).fold(1.0f32, f32::max) * 1.05;
        self.camera = Some(OrbitCamera::galaxy(radius));
        self.view = MapView::Galaxy;
        self.log.push(format!(
            "loaded {path} in {:.1} s: {} systems, {} hyperlanes, {} owners",
            t0.elapsed().as_secs_f64(),
            map.galaxy.systems.len(),
            map.galaxy.lanes.len(),
            map.galaxy.countries.len()
        ));
        self.map = Some(map);
        self.show(Screen::Map);
        Ok(())
    }

    /// Continue: the newest save.
    pub fn continue_game(&mut self) -> Result<(), String> {
        let path = self.saves().first().map(|s| s.path.clone()).ok_or("no saves")?;
        self.log.push(format!("continue: {path}"));
        self.load(&path)
    }

    /// A key: Escape (back from a system to the galaxy, from the map or the load window to the
    /// menu), C (continue on the menu); on the map: W A S D pan, Q E turn, R F tilt, + - zoom,
    /// V the 2D map or 3D. Whether something changed.
    pub fn key(&mut self, key: &str) -> Result<bool, String> {
        if self.screen == Screen::Map {
            let step = 0.06;
            match key {
                "w" | "up" => self.pan(0.0, step),
                "s" | "down" => self.pan(0.0, -step),
                "a" | "left" => self.pan(-step, 0.0),
                "d" | "right" => self.pan(step, 0.0),
                "q" => self.orbit(-10.0, 0.0),
                "e" => self.orbit(10.0, 0.0),
                "r" => self.orbit(0.0, 5.0),
                "f" => self.orbit(0.0, -5.0),
                "+" | "=" | "pageup" => self.zoom(0.8),
                "-" | "pagedown" => self.zoom(1.25),
                "v" => {
                    self.mode3d = !self.mode3d;
                    self.scene = None;
                }
                "escape" if self.view != MapView::Galaxy && self.map.is_some() => {
                    self.log.push(format!("escape: {:?} -> Galaxy", self.view));
                    self.show_galaxy();
                }
                "escape" => {
                    self.log.push("escape: Map -> Menu".into());
                    self.show(Screen::Menu);
                }
                _ => return Ok(false),
            }
            return Ok(true);
        }
        match (key, self.screen) {
            ("escape", Screen::Load) => {
                self.log.push(format!("escape: {:?} -> Menu", self.screen));
                self.show(Screen::Menu);
                Ok(true)
            }
            ("c", Screen::Menu) => {
                self.continue_game()?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }
}
