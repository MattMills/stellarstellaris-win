//! The ship designer and the combat view (docs/windows/designer.md): what is open, the data read
//! from the save's world (`lua/render/windows/designer.lua`, `combat.lua`, in the map's runtime),
//! laid out in the front end's runtime (its localisation and .gfx database), and the ship models
//! of the designer's 3D views, drawn as insets in the GUI (scene::Inset, render.rs).
//!
//! - The designer opens with `open_designer` (the game's: CShipDesignerBase::Show on
//!   CInGameIdler::AccessShipDesigner) with no design loaded, as the game opens it; a click on a
//!   design in its list (or `open_designer design ID`) loads it (CShipDesignEntry::Click); its close
//!   button and the fleet manager's tab close it.
//! - The combat view stands in for a selected fleet's window while the fleet is in combat
//!   (CInGameIdler::ShowFleetView: CFleet::HasCombat).

use std::collections::HashMap;

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::camera::OrbitCamera;
use crate::dds::Cache;
use crate::gui::GuiItem;
use crate::math::{M4, V3};
use crate::models;
use crate::scene::{Look, MeshDraw, Scene, Textures};
use crate::system::ShipLighting;

/// The designer's state: open or not, the design loaded.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Designer {
    pub open: bool,
    pub design: Option<u32>,
}

/// A ship design's model (render.system's design_model): its culture's frame entity, its sections'
/// entities at the frame's locators, their turrets, the owner's colour, the culture's lighting.
#[derive(Clone, Debug)]
pub struct ShipModel {
    pub frame: String,
    pub sections: Vec<(String, String)>,
    pub turrets: Vec<(usize, String, String)>,
    pub colour: Option<[f32; 3]>,
    pub lighting: Option<ShipLighting>,
}

fn read_model(t: &Table) -> mlua::Result<ShipModel> {
    let mut sections = Vec::new();
    let mut turrets = Vec::new();
    for x in t.get::<Table>("sections")?.sequence_values::<Table>() {
        let x = x?;
        for y in x.get::<Option<Table>>("turrets")?.map(|v| v.sequence_values::<Table>().collect::<Vec<_>>()).unwrap_or_default() {
            let y = y?;
            turrets.push((sections.len(), y.get::<String>("entity")?, y.get::<String>("locator")?));
        }
        sections.push((x.get("entity")?, x.get("locator")?));
    }
    Ok(ShipModel {
        frame: t.get::<Option<String>>("frame")?.unwrap_or_default(),
        sections,
        turrets,
        colour: t.get::<Option<Table>>("colour")?.map(|c| -> mlua::Result<[f32; 3]> { Ok([c.get(1)?, c.get(2)?, c.get(3)?]) }).transpose()?,
        lighting: t.get::<Option<Table>>("lighting")?.map(|l| crate::system::read_lighting(&l)).transpose()?,
    })
}

/// Whether a fleet is in combat (render.windows.combat: its save block's combat.in_combat_with).
pub fn in_combat(map_rt: &Runtime, fleet: u32) -> bool {
    map_rt.lua.load(format!("return require('render.windows.combat').in_combat({fleet})")).eval::<bool>().unwrap_or(false)
}

/// The first fleet in combat, by id (`open_designer combat`).
pub fn first_in_combat(map_rt: &Runtime) -> Option<u32> {
    map_rt.lua.load("return require('render.windows.combat').first_in_combat()").eval::<Option<u32>>().ok().flatten()
}

/// The window's data read from the world (designer.lua `extract`, serialized: the models of the
/// designs in it), kept until a command changes the world or the window opens again.
static DATA: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
/// Whether the window was open at the last layout (an opening resets its state).
static WAS_OPEN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Lua code run where the world is: the simulation's runtime when it runs (Clock::query, between
/// days: what a command changed is there), else the loaded save's.
fn world_eval(map: &crate::Map, code: &str) -> Result<String, String> {
    match map.clock.as_ref() {
        Some(c) if c.status().ready => c.query(code),
        _ => map.runtime.lua.load(code).eval::<String>().map_err(|e| e.to_string()),
    }
}

/// The designer's and the combat view's items for a screen of `width` x `height`, and the models
/// of the designer's 3D views by their inset's path.
#[allow(clippy::too_many_arguments)]
pub fn layout(
    gui_rt: &Runtime,
    map: &crate::Map,
    game_dir: &str,
    width: u32,
    height: u32,
    designer: &Designer,
    combat: Option<u32>,
) -> Result<(Vec<GuiItem>, HashMap<String, ShipModel>), String> {
    let gd = game_dir.replace('\\', "/");
    let mut items = Vec::new();
    let ctx = format!("{{ game_dir = {gd:?}, db = RENDER_GFX, screen = {{ width = {width}, height = {height} }}, texture_size = RENDER_TEXTURE_SIZE, loc = RENDER_LOC }}");
    if let Some(fleet) = combat {
        let data = world_eval(map, &format!("local d = require('render.windows.combat').extract({gd:?}, {fleet}) return d and require('render.windows.designer').serialize(d) or ''"))
            .map_err(|e| format!("render.windows.combat: {e}"))?;
        if !data.is_empty() {
            let read = || -> mlua::Result<Vec<GuiItem>> {
                gui_rt.lua.globals().set("RENDER_COMBAT_DATA", data.as_str())?;
                let t: Table = gui_rt
                    .lua
                    .load(format!("local data = load('return ' .. RENDER_COMBAT_DATA)() local items, report = require('render.windows.combat').build({ctx}, data) return {{ items = items, report = report }}"))
                    .eval()?;
                crate::gui::read_items(t.get("items")?)
            };
            items.extend(read().map_err(|e| format!("render.windows.combat: {e}"))?);
        }
    }
    if !designer.open {
        if WAS_OPEN.swap(false, std::sync::atomic::Ordering::Relaxed) {
            *DATA.lock().unwrap() = None;
        }
        return Ok((items, HashMap::new()));
    }
    if !WAS_OPEN.swap(true, std::sync::atomic::Ordering::Relaxed) {
        // opened: its data read anew, its state cleared (designer.lua reset)
        *DATA.lock().unwrap() = None;
        gui_rt.lua.load("require('render.windows.designer').reset()").exec().map_err(|e| format!("render.windows.designer: {e}"))?;
    }
    let cached = DATA.lock().unwrap().clone();
    let data = match cached {
        Some(d) => d,
        None => {
            let d = world_eval(map, &format!("return require('render.windows.designer_commands').data({gd:?})")).map_err(|e| format!("render.windows.designer: {e}"))?;
            *DATA.lock().unwrap() = Some(d.clone());
            d
        }
    };
    let mut read = || -> mlua::Result<HashMap<String, ShipModel>> {
        gui_rt.lua.globals().set("RENDER_DESIGNER_SRC", data.as_str())?;
        let state = match designer.design {
            Some(id) => format!("{{ design = {id} }}"),
            None => "{}".into(),
        };
        let t: Table = gui_rt
            .lua
            .load(format!(
                "RENDER_DESIGNER_DATA = load('return ' .. RENDER_DESIGNER_SRC)()
                 local items, report, insets = require('render.windows.designer').build({ctx}, RENDER_DESIGNER_DATA, {state})
                 return {{ items = items, report = report, insets = insets, models = RENDER_DESIGNER_DATA.models or {{}},
                          country = RENDER_DESIGNER_DATA.country, stage = require('render.windows.designer').stage() }}"
            ))
            .eval()?;
        items.extend(crate::gui::read_items(t.get("items")?)?);
        let mut by_id: HashMap<i64, ShipModel> = HashMap::new();
        for p in t.get::<Table>("models")?.pairs::<i64, Table>() {
            let (id, m) = p?;
            by_id.insert(id, read_model(&m)?);
        }
        // the design under modification's model: its stage where the world is (the game's files,
        // the models' index, the owner's colour), read back here
        if let Some(stage) = t.get::<Option<String>>("stage")? {
            let country: i64 = t.get::<Option<i64>>("country")?.unwrap_or(0);
            let code = format!(
                "if not RENDER_MODELS then RENDER_MODELS = require('render.models').load({gd:?}) end
                 local m = require('render.system').stage_model({gd:?}, load('return ' .. {stage:?})(), '', {country})
                 return m and require('render.windows.designer').serialize(m) or ''"
            );
            let m = world_eval(map, &code).map_err(mlua::Error::RuntimeError)?;
            if !m.is_empty() {
                gui_rt.lua.globals().set("RENDER_DESIGNER_MODEL", m)?;
                let m: Table = gui_rt.lua.load("return load('return ' .. RENDER_DESIGNER_MODEL)()").eval()?;
                by_id.insert(-1, read_model(&m)?);
            }
        }
        let mut out = HashMap::new();
        for p in t.get::<Table>("insets")?.pairs::<String, i64>() {
            let (path, id) = p?;
            // the designer's view with no design: its background alone
            let empty = ShipModel { frame: String::new(), sections: Vec::new(), turrets: Vec::new(), colour: None, lighting: None };
            out.insert(path, by_id.get(&id).cloned().unwrap_or(empty));
        }
        Ok(out)
    };
    let models = read().map_err(|e| format!("render.windows.designer: {e}"))?;
    Ok((items, models))
}

/// The wheel at (x, y) over the designer: one of its lists scrolled (designer.lua `wheel`); whether
/// it took it.
pub fn wheel(app: &mut crate::app::App, notches: f32, at: Option<(f32, f32)>) -> bool {
    let Some((x, y)) = at else { return false };
    let took = app
        .runtime
        .lua
        .load(format!("return require('render.windows.designer').wheel({notches}, {x}, {y})"))
        .eval::<bool>()
        .unwrap_or(false);
    if took {
        app.relayout();
    }
    took
}

/// Escape while the designer is open: its popup closed, else the window (the close buttons'
/// ESCAPE shortcut, the innermost first).
pub fn escape(app: &mut crate::app::App) {
    let popup = app.runtime.lua.load("return require('render.windows.designer').escape()").eval::<bool>().unwrap_or(false);
    if popup {
        app.relayout();
    } else {
        app.set_designer(Designer::default());
    }
}

/// The parts of a designer action: `designer:close`, `designer:fleet_manager`,
/// `designer:design:ID`, else the window's own (`designer:ui:...`, designer.lua `act`).
#[derive(Debug, PartialEq)]
enum Action<'a> {
    Close,
    FleetManager,
    Design(u32),
    CombatFocus(u32),
    Ui(&'a str),
}

fn parse(action: &str) -> Result<Action<'_>, String> {
    match action.strip_prefix("designer:") {
        Some("close") => Ok(Action::Close),
        Some("fleet_manager") => Ok(Action::FleetManager),
        Some(a) if a.starts_with("design:") => Ok(Action::Design(a[7..].parse().map_err(|_| format!("bad action {action}"))?)),
        Some(a) if a.starts_with("combat_focus:") => Ok(Action::CombatFocus(a[13..].parse().map_err(|_| format!("bad action {action}"))?)),
        Some(a) if a.starts_with("ui:") => Ok(Action::Ui(action)),
        _ => Err(format!("bad action {action}")),
    }
}

/// What a click on one of the designer's buttons does (docs/windows/designer.md "The buttons"):
/// the window's close button and the fleet manager's tab, a design in the list; the others are the
/// window's (designer.lua `act`), which may ask the simulation (designer_commands.lua, run between
/// its days: a design saved or deleted there is in its world) and take its answer (`done`).
pub fn act(app: &mut crate::app::App, action: &str) -> Result<(), String> {
    match parse(action)? {
        Action::Close => app.set_designer(Designer::default()),
        Action::FleetManager => {
            // the Fleet Manager tab: its view (one view at a time: the designer closes)
            app.set_designer(Designer::default());
            app.toggle_view("fleet_manager");
        }
        Action::Design(id) => app.set_designer(Designer { open: true, design: Some(id) }),
        Action::CombatFocus(fleet) => {
            // the combat view's focus (CCombatView::OnClickFocus): the camera to the combat, the
            // fleet's system entered and the fleet followed [I]
            let sys = app.map.as_ref().and_then(|m| {
                let s = m.galaxy.fleets.iter().find(|f| f.id == fleet)?.system?;
                m.galaxy.systems.iter().position(|x| x.id == s)
            });
            if let Some(i) = sys {
                app.enter_system(i, Some(crate::scene::Pickable::Fleet(fleet)))?;
            }
        }
        Action::Ui(a) => {
            let gd = app.game_dir.replace('\\', "/");
            let call = |app: &crate::app::App, f: &str, arg: &str| -> Result<String, String> {
                app.runtime.lua.globals().set("RENDER_DESIGNER_ARG", arg).map_err(|e| e.to_string())?;
                app.runtime
                    .lua
                    .load(format!("return require('render.windows.designer').{f}(RENDER_DESIGNER_ARG, RENDER_DESIGNER_DATA or {{}}, {gd:?})"))
                    .eval::<String>()
                    .map_err(|e| format!("render.windows.designer: {f}: {e}"))
            };
            let mut reply = call(app, "act", a)?;
            // the simulation's answers, and what the window asks next (a new design: its
            // components, then its name)
            for _ in 0..4 {
                let Some(code) = reply.strip_prefix("sim:").map(str::to_string) else { break };
                let map = app.map.as_mut().ok_or("no map")?;
                map.ready()?;
                let clock = map.clock.as_ref().ok_or("no simulation")?;
                let answer = clock.query(&code).map_err(|e| format!("render.windows.designer_commands: {e}"))?;
                if answer.starts_with("changed") {
                    clock.publish(true);
                    map.sync();
                    *DATA.lock().unwrap() = None;
                }
                app.log.push(format!("designer: {}", answer.chars().take(120).collect::<String>()));
                reply = call(app, "done", &answer)?;
            }
            if let Some(d) = reply.strip_prefix("design:") {
                app.set_designer(Designer { open: true, design: d.parse().ok() });
            }
            app.relayout();
        }
    }
    Ok(())
}

/// The designer's 3D views: each inset of the scene with a model gets the ship's meshes, a view
/// of it and the ship designer world's lights (gfx/worldgfx/ship_designer.txt) [I: the camera,
/// by the game's frame: the ship's side, its bow to the right, a little from above].
pub fn fill_insets(scene: &mut Scene, models: &HashMap<String, ShipModel>, lib: &mut models::Library, rt: &Runtime, game_dir: &str, tex: &mut Textures, cache: &mut Cache) {
    if scene.insets.is_empty() || models.is_empty() || lib.ensure(rt, game_dir).is_err() {
        return;
    }
    let world = crate::worldgfx::read(rt, game_dir, "ship_designer").ok();
    for inset in scene.insets.iter_mut() {
        let Some(m) = models.get(&inset.path) else { continue };
        let (w, h) = ((inset.rect[2] - inset.rect[0]).max(1.0), (inset.rect[3] - inset.rect[1]).max(1.0));
        let (meshes, radius, centre) = ship_meshes(lib, rt, game_dir, m, tex, cache);
        // a hull with nothing drawn (no section yet): the view's sky alone, at a ship's distance
        let ok = |v: V3| v.0.is_finite() && v.1.is_finite() && v.2.is_finite();
        let (radius, centre) = if meshes.is_empty() || !radius.is_finite() || radius <= 0.01 || !ok(centre) { (10.0, V3(0.0, 0.0, 0.0)) } else { (radius, centre) };
        let main = inset.path.starts_with("/designer/3d_view");
        if meshes.is_empty() && !main {
            continue;
        }
        let mut cam = OrbitCamera::system(radius * 2.0);
        cam.target = centre;
        cam.yaw = (-75f32).to_radians();
        cam.pitch = 14f32.to_radians();
        cam.min_distance = 0.0;
        cam.min_pitch = -1.5;
        // the ship fills the view's width: its radius over the half width's tangent, with a margin
        // (the list's small views show it smaller, on their entry's background) [I: by the frame]
        let aspect = w / h;
        let half_w = (cam.fov_y / 2.0).tan() * aspect;
        cam.distance = radius * if main { 1.15 } else { 1.7 } / half_w.max(1e-3);
        let view = cam.view_params(w as u32, h as u32);
        let to_eye = view.eye.sub(cam.target).norm();
        let l = view.right.scale(-0.7).add(view.up.scale(0.55)).add(to_eye.scale(0.45)).norm();
        inset.light = [l.0, l.1, l.2, 0.0];
        if let Some(wg) = &world {
            inset.cam_lights = wg.ship_lights.map(|c| [c[0].max(0.0).powf(4.84), c[1].max(0.0).powf(4.84), c[2].max(0.0).powf(4.84), 1.0]);
            inset.env = wg.env(tex, cache, game_dir);
            // its galaxy_background (gfx/map/sky_rim.dds) behind the ship (the designer's view)
            if main {
                inset.sky = wg.sky(tex, cache, game_dir, 0.0);
            }
        }
        inset.view = Some(view);
        inset.meshes = meshes;
    }
}

/// A ship's meshes at the origin (as system.rs draws a ship: the frame entity, its attachments,
/// the sections at the frame's locators, their turrets), its radius and centre.
fn ship_meshes(lib: &mut models::Library, rt: &Runtime, gd: &str, s: &ShipModel, tex: &mut Textures, cache: &mut Cache) -> (Vec<MeshDraw>, f32, V3) {
    let mut look = Look::default();
    if let Some(c) = s.colour {
        look.atmosphere = [c[0], c[1], c[2], 1.0];
        look.colour_alpha = 1.0;
    }
    // the camera lights at their near values (the designer's camera is close)
    let consts = |crunch: f32| -> [[f32; 4]; 4] {
        let Some(l) = &s.lighting else { return [[0.0; 4]; 4] };
        let d = l.dirs;
        [[d[0][0], d[0][1], d[0][2], l.intensity.0], [d[1][0], d[1][1], d[1][2], l.rim_start.0], [d[2][0], d[2][1], d[2][2], l.rim_stop.0], [l.ambient.0, 0.0, crunch, 0.0]]
    };
    let draws = |model: &models::Model, t: M4, tex: &mut Textures, cache: &mut Cache| {
        let mut v = models::draws(model, t, [1.0; 4], &look, tex, cache, gd);
        let c = consts(model.recolor_crunch);
        for d in &mut v {
            d.ship = c;
        }
        v
    };
    let mut meshes = Vec::new();
    let mut missing = Vec::new();
    let base = M4::IDENTITY;
    let frame = if s.frame.is_empty() { None } else { lib.model(rt, gd, &s.frame).ok() };
    let (mut radius, mut centre) = (1.0f32, V3(0.0, 0.0, 0.0));
    if let Some(f) = &frame {
        meshes.extend(draws(f, base, tex, cache));
        let mut extra = Vec::new();
        crate::system::attachments(lib, rt, gd, f, base, &look, tex, cache, &mut extra, &mut missing, 0);
        for d in &mut extra {
            d.ship = consts(1.0);
        }
        meshes.extend(extra);
        radius = f.radius();
        centre = f.centre();
    }
    for (si, (entity, locator)) in s.sections.iter().enumerate() {
        let Ok(m) = lib.model(rt, gd, entity) else { continue };
        let at = frame
            .as_ref()
            .and_then(|f| f.locator(locator))
            .map(|l| M4::translation(V3(l.p[0], l.p[1], l.p[2])).mul(&M4::from_quat(l.q)))
            .unwrap_or(M4::IDENTITY);
        meshes.extend(draws(&m, base.mul(&at), tex, cache));
        let mut extra = Vec::new();
        crate::system::attachments(lib, rt, gd, &m, base.mul(&at), &look, tex, cache, &mut extra, &mut missing, 0);
        for d in &mut extra {
            d.ship = consts(1.0);
        }
        meshes.extend(extra);
        if frame.is_none() || m.radius() > radius {
            radius = radius.max(m.radius());
            centre = m.centre();
        }
        for (_, te, tl) in s.turrets.iter().filter(|t| t.0 == si) {
            let (Ok(tm), Some(l)) = (lib.model(rt, gd, te), m.locator(tl)) else { continue };
            let lt = M4::translation(V3(l.p[0], l.p[1], l.p[2])).mul(&M4::from_quat(l.q));
            meshes.extend(draws(&tm, base.mul(&at).mul(&M4::scaling(m.scale)).mul(&lt), tex, cache));
        }
    }
    (meshes, radius, centre)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn designer_actions() {
        assert_eq!(parse("designer:design:2207"), Ok(Action::Design(2207)));
        assert_eq!(parse("designer:close"), Ok(Action::Close));
        assert_eq!(parse("designer:fleet_manager"), Ok(Action::FleetManager));
        assert_eq!(parse("designer:combat_focus:261"), Ok(Action::CombatFocus(261)));
        assert_eq!(parse("designer:ui:slot:1:SMALL_GUN_01"), Ok(Action::Ui("designer:ui:slot:1:SMALL_GUN_01")));
        assert!(parse("designer:design:x").is_err());
        assert!(parse("close").is_err());
    }
}
