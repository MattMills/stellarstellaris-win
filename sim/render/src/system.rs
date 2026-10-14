//! A system in 3D, and a model alone. The system's own space (planets' and ships' coordinates in
//! the save, `origin` the system) is the world here: its plane y = 0, a coordinate (x, y) the
//! point (x, 0, y), as the galaxy (camera.rs).
//!
//! - stars: their class's entity (common/planet_classes `entity`, e.g. g_star_class_star_entity:
//!   star_mesh, PdxMeshStar) glowing in the class's `atmosphere_color`, with the class's map sprite
//!   as a halo; the scene's light is at the first star;
//! - planets: their class's entity variant (`entity` = the variant: desert_planet_02_entity), lit,
//!   with clouds and an atmosphere rim in `atmosphere_color`; moons around their planet;
//! - orbits: a ring at each body's distance from what it orbits;
//! - ships: their culture's frame entity for the design's ship size with the design's sections'
//!   entities at the size's section slots' locators, at the ship's coordinate, turned to its
//!   forward_x / forward_y (a ship's model faces -z).
//!
//! Sizes are the renderer's (the game's scale factors are not found yet, docs/render.md):
//! a planet's radius is 0.3 x planet_size, a star's 0.45 x, ships and stations are drawn at 0.25
//! of their model's size.

use std::collections::HashMap;

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::camera::{OrbitCamera, ViewParams};
use crate::dds::Cache;
use crate::gui;
use crate::math::{M4, V3};
use crate::models::{self, Library, Model};
use crate::scene::{self, Blend, Gui, Layer, Layout, Line, Look, Quad, Scene, Textures};
use crate::{Map, Source};

pub const PLANET_RADIUS_PER_SIZE: f32 = 0.3;
pub const STAR_RADIUS_PER_SIZE: f32 = 0.45;
pub const SHIP_SCALE: f32 = 0.25;

#[derive(Clone, Debug)]
pub struct Body {
    pub id: u32,
    pub class: String,
    pub entity: String,
    pub star: bool,
    pub size: f32,
    pub x: f32,
    pub y: f32,
    pub moon_of: i64,
    pub look: Look,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct ShipInfo {
    pub id: u32,
    pub station: bool,
    pub x: f32,
    pub y: f32,
    pub fx: f32,
    pub fy: f32,
    pub size: String,
    pub frame: String,
    pub sections: Vec<(String, String)>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct SystemData {
    pub id: u32,
    pub bodies: Vec<Body>,
    pub ships: Vec<ShipInfo>,
}

impl SystemData {
    pub fn radius(&self) -> f32 {
        self.bodies.iter().map(|b| (b.x * b.x + b.y * b.y).sqrt() + 10.0).fold(60.0f32, f32::max)
    }
}

/// The system's bodies and ships from the world (`lua/render/system.lua`); the models' index
/// must be loaded.
pub fn extract(rt: &Runtime, game_dir: &str, id: u32) -> Result<SystemData, String> {
    let read = || -> mlua::Result<SystemData> {
        let (t, why): (Option<Table>, Option<String>) =
            rt.lua.load(format!("return require('render.system').extract({:?}, {id})", game_dir.replace('\\', "/"))).eval()?;
        let t = t.ok_or_else(|| mlua::Error::RuntimeError(why.unwrap_or_default()))?;
        let mut bodies = Vec::new();
        for b in t.get::<Table>("bodies")?.sequence_values::<Table>() {
            let b = b?;
            bodies.push(Body {
                id: b.get("id")?,
                class: b.get("class")?,
                entity: b.get("entity")?,
                star: b.get("star")?,
                size: b.get("size")?,
                x: b.get("x")?,
                y: b.get("y")?,
                moon_of: b.get("moon_of")?,
                look: read_look(&b.get::<Table>("look")?)?,
            });
        }
        let mut ships = Vec::new();
        for s in t.get::<Table>("ships")?.sequence_values::<Table>() {
            let s = s?;
            let mut sections = Vec::new();
            for x in s.get::<Table>("sections")?.sequence_values::<Table>() {
                let x = x?;
                sections.push((x.get("entity")?, x.get("locator")?));
            }
            ships.push(ShipInfo {
                id: s.get("id")?,
                station: s.get("station")?,
                x: s.get("x")?,
                y: s.get("y")?,
                fx: s.get("fx")?,
                fy: s.get("fy")?,
                size: s.get("size")?,
                frame: s.get("frame")?,
                sections,
            });
        }
        Ok(SystemData { id, bodies, ships })
    };
    read().map_err(|e| format!("render.system: {e}"))
}

fn rgb(t: &Table) -> mlua::Result<[f32; 3]> {
    Ok([t.get(1)?, t.get(2)?, t.get(3)?])
}

/// A look (render.system's: atmosphere, intensity, width, lava = { bright, hot, cold }).
fn read_look(t: &Table) -> mlua::Result<Look> {
    let mut look = Look::default();
    let a = rgb(&t.get::<Table>("atmosphere")?)?;
    let intensity: f32 = t.get("intensity")?;
    look.atmosphere = [a[0], a[1], a[2], intensity];
    look.width = t.get("width")?;
    if let Some(l) = t.get::<Option<Table>>("lava")? {
        for k in 0..3 {
            if let Some(c) = l.get::<Option<Table>>(k + 1)? {
                look.lava[k] = rgb(&c)?;
            }
        }
    }
    Ok(look)
}

/// The look of the planet class drawn with an entity (for a model shown alone).
pub fn look_of(rt: &Runtime, game_dir: &str, entity: &str) -> Look {
    let r: mlua::Result<Look> = rt
        .lua
        .load(format!("return require('render.system').look_of({:?}, {entity:?})", game_dir.replace('\\', "/")))
        .eval::<Table>()
        .and_then(|t| read_look(&t));
    r.unwrap_or_else(|e| {
        eprintln!("look of {entity}: {e}");
        Look::default()
    })
}

fn source_rt(source: &Source) -> &Runtime {
    match source {
        Source::World(r) => r,
        Source::Sim(s) => &s.runtime,
    }
}

/// A camera over a system (its own space, centred on 0, 0).
pub fn camera_for(map: &mut Map, index: usize) -> OrbitCamera {
    let id = map.galaxy.systems[index].id;
    let Map { source, models, game_dir, .. } = map;
    let rt = source_rt(source);
    let radius = models.ensure(rt, game_dir).ok().and_then(|_| extract(rt, game_dir, id).ok()).map_or(250.0, |d| d.radius());
    OrbitCamera::system(radius)
}

/// The transform placing a model (its draws: [`models::draws`] applies the model's own scale)
/// centred at `at`, `radius` world units across its half diagonal, turned by `yaw`.
fn place(model: &Model, at: V3, radius: f32, yaw: f32) -> M4 {
    let r = model.radius().max(1e-3);
    M4::translation(at).mul(&M4::rotation_y(yaw)).mul(&M4::scaling(radius / r)).mul(&M4::translation(model.centre().scale(-1.0)))
}

/// The system's scene.
pub fn build(map: &mut Map, index: usize, camera: &OrbitCamera, width: u32, height: u32) -> Result<Scene, String> {
    let id = map.galaxy.systems[index].id;
    let star_sprite = map.galaxy.systems[index].texture.clone();
    let gd = map.game_dir.clone();
    // the top bar, as on the map
    let topbar = gui::topbar(map.rt(), &gd, &map.cache, width, height)?;
    if map.fonts.is_none() {
        let mut fonts = HashMap::new();
        gui::fonts(map.rt(), &gd, &topbar.items, &mut fonts)?;
        map.fonts = Some(fonts);
    }
    let Map { source, models: lib, textures: tex, cache, fonts, .. } = map;
    let rt = source_rt(source);
    lib.ensure(rt, &gd)?;
    let data = extract(rt, &gd, id)?;
    let view = camera.view_params(width, height);
    let mut batches = Vec::new();
    let mut lines = Vec::new();
    let mut meshes = Vec::new();
    let mut cache = cache.borrow_mut();

    // a faint backdrop of dust, far below and around
    if let Some(dust) = tex.game(&mut cache, &gd, "gfx/map/dust.dds") {
        let mut rng = scene::Rng(0xd057_0001 ^ id);
        let r = data.radius();
        for _ in 0..40 {
            let (a, d) = (rng.next() * std::f32::consts::TAU, r * (0.5 + 2.5 * rng.next()));
            let colour = [0.35 + 0.2 * rng.next(), 0.35 + 0.15 * rng.next(), 0.45 + 0.2 * rng.next(), 0.25];
            batches_push(&mut batches, Layer::Background, Blend::Add, dust, Quad::billboard(d * a.cos(), d * a.sin(), -r * 0.4 * rng.next(), r * 0.6, colour, rng.next() * 6.28, 0.0));
        }
    }

    let mut light = [0.0, 30.0, 0.0, 1.0];
    let mut first_star = true;
    let positions: HashMap<u32, (f32, f32)> = data.bodies.iter().map(|b| (b.id, (b.x, b.y))).collect();
    let mut missing = Vec::new();
    for b in &data.bodies {
        let at = V3(b.x, 0.0, b.y);
        let radius = b.size * if b.star { STAR_RADIUS_PER_SIZE } else { PLANET_RADIUS_PER_SIZE };
        if b.star && first_star {
            light = [b.x, 0.0, b.y, 1.0];
            first_star = false;
        }
        match (!b.entity.is_empty()).then(|| lib.model(rt, &gd, &b.entity)) {
            Some(Ok(model)) => {
                let spin = (b.id as f32 * 1.7) % std::f32::consts::TAU;
                meshes.extend(models::draws(&model, place(&model, at, radius, spin), [1.0; 4], &b.look, tex, &mut cache, &gd));
            }
            Some(Err(e)) => missing.push(format!("{} ({}): {e}", b.class, b.entity)),
            None => missing.push(format!("{}: no entity", b.class)),
        }
        if b.star {
            // the halo: the class's map sprite, added
            if let Some(t) = tex.game(&mut cache, &gd, &star_sprite) {
                let c = b.look.atmosphere;
                batches_push(&mut batches, Layer::Stars, Blend::Add, t, Quad::billboard(b.x, b.y, 0.0, radius * 3.0, [c[0].max(0.5), c[1].max(0.5), c[2].max(0.5), 0.5], 0.0, 0.0));
            }
        } else {
            // the orbit: around the planet a moon orbits, else around the system's centre
            let (cx, cy) = if b.moon_of >= 0 { positions.get(&(b.moon_of as u32)).copied().unwrap_or((0.0, 0.0)) } else { (0.0, 0.0) };
            let r = ((b.x - cx).powi(2) + (b.y - cy).powi(2)).sqrt();
            let n = 96;
            for k in 0..n {
                let (a0, a1) = (k as f32 / n as f32 * std::f32::consts::TAU, (k + 1) as f32 / n as f32 * std::f32::consts::TAU);
                lines.push(Line {
                    a: V3(cx + r * a0.cos(), 0.0, cy + r * a0.sin()),
                    b: V3(cx + r * a1.cos(), 0.0, cy + r * a1.sin()),
                    colour: [0.45, 0.6, 0.85, if b.moon_of >= 0 { 0.25 } else { 0.35 }],
                    width: 1.2,
                });
            }
        }
    }

    // ships
    let disc = tex.generated("@disc");
    let ship_look = Look::default();
    let mut ships_drawn = 0;
    for s in &data.ships {
        let at = V3(s.x, 0.0, s.y);
        let yaw = (-s.fx).atan2(-s.fy);
        let base = M4::translation(at).mul(&M4::rotation_y(yaw)).mul(&M4::scaling(SHIP_SCALE));
        let frame = if s.frame.is_empty() { None } else { lib.model(rt, &gd, &s.frame).ok() };
        let mut drawn = 0;
        if let Some(f) = &frame {
            meshes.extend(models::draws(f, base, [1.0; 4], &ship_look, tex, &mut cache, &gd));
            drawn += f.parts.len();
        }
        for (entity, locator) in &s.sections {
            let Ok(m) = lib.model(rt, &gd, entity) else { continue };
            let at_locator = frame
                .as_ref()
                .and_then(|f| f.locator(locator))
                .map(|l| M4::translation(V3(l.p[0], l.p[1], l.p[2])).mul(&M4::from_quat(l.q)))
                .unwrap_or(M4::IDENTITY);
            meshes.extend(models::draws(&m, base.mul(&at_locator), [1.0; 4], &ship_look, tex, &mut cache, &gd));
            drawn += m.parts.len();
        }
        if drawn == 0 {
            // no model: a marker
            batches_push(&mut batches, Layer::Stars, Blend::Alpha, disc, Quad::billboard(s.x, s.y, 0.5, 0.8, [0.8, 0.9, 1.0, 1.0], 0.0, 3.0));
        } else {
            ships_drawn += 1;
        }
    }
    if !missing.is_empty() {
        eprintln!("system {id}: models not drawn: {}", missing.join("; "));
    }
    eprintln!("system {id}: {} bodies, {} of {} ships with a model, {} mesh draws", data.bodies.len(), ships_drawn, data.ships.len(), meshes.len());
    let mut entities: Vec<String> = data.ships.iter().flat_map(|s| std::iter::once(s.frame.clone()).chain(s.sections.iter().map(|(e, l)| format!("{e}@{l}")))).collect();
    entities.sort();
    entities.dedup();
    eprintln!("system {id}: ship models: {}", entities.join(" "));
    if !tex.missing.is_empty() {
        eprintln!("system {id}: textures not loaded: {}", tex.missing.join("; "));
    }

    let mut g = Gui::default();
    scene::add_gui(&mut batches, &mut g, &topbar.items, fonts.as_ref().unwrap(), tex, &mut cache, &gd, &HashMap::new());
    Ok(Scene {
        layout: Layout { width, height, world_to_ndc: [1.0, 1.0, 0.0, 0.0], scale: 1.0, lane_width: 1.0 },
        view,
        light,
        batches,
        lines,
        meshes,
        clear: [0.005, 0.006, 0.016],
        stars: Vec::new(),
        sprites: g.sprites,
        texts: g.texts,
        buttons: g.buttons,
    })
}

fn batches_push(batches: &mut Vec<scene::Batch>, layer: Layer, blend: Blend, texture: usize, q: Quad) {
    scene::push(batches, layer, blend, texture, q);
}

/// A camera fitted to a model alone.
pub fn model_camera(lib: &mut Library, rt: &Runtime, game_dir: &str, name: &str) -> Result<OrbitCamera, String> {
    lib.ensure(rt, game_dir)?;
    let m = lib.model(rt, game_dir, name)?;
    let mut c = OrbitCamera::system(m.radius() * 2.0);
    c.target = V3(0.0, 0.0, 0.0);
    c.pitch = 25f32.to_radians();
    c.yaw = 35f32.to_radians();
    c.min_distance = m.radius() * 0.3;
    Ok(c)
}

/// A model alone (an entity or a pdxmesh by name), centred, lit from the upper left.
#[allow(clippy::too_many_arguments)]
pub fn model_scene(
    lib: &mut Library,
    rt: &Runtime,
    game_dir: &str,
    name: &str,
    camera: &OrbitCamera,
    width: u32,
    height: u32,
    tex: &mut Textures,
    cache: &mut Cache,
) -> Result<Scene, String> {
    lib.ensure(rt, game_dir)?;
    let model = lib.model(rt, game_dir, name)?;
    let centre = model.centre();
    let transform = M4::translation(centre.scale(-1.0));
    let look = look_of(rt, game_dir, name);
    let meshes = models::draws(&model, transform, [1.0; 4], &look, tex, cache, game_dir);
    eprintln!(
        "model {name}: {} ({}), {} parts drawn: {}; skipped: {}; look {:?}",
        model.file,
        model.scale,
        model.parts.len(),
        model.parts.iter().map(|p| format!("{} {} [{}]", p.shape, p.shader, p.textures.join(" "))).collect::<Vec<_>>().join("; "),
        model.skipped.join(", "),
        look
    );
    let view: ViewParams = camera.view_params(width, height);
    // the light from the upper left of the camera
    let to_eye = view.eye.sub(camera.target).norm();
    let l = view.right.scale(-0.7).add(view.up.scale(0.55)).add(to_eye.scale(0.45)).norm();
    Ok(Scene {
        layout: Layout { width, height, world_to_ndc: [1.0, 1.0, 0.0, 0.0], scale: 1.0, lane_width: 1.0 },
        view,
        light: [l.0, l.1, l.2, 0.0],
        batches: Vec::new(),
        lines: Vec::new(),
        meshes,
        clear: [0.02, 0.025, 0.04],
        stars: Vec::new(),
        sprites: Vec::new(),
        texts: Vec::new(),
        buttons: Vec::new(),
    })
}
