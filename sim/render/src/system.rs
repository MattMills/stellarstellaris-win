//! A system in 3D, and a model alone. The system's own space (planets' and ships' coordinates in
//! the save, `origin` the system) is the world here in map units, a coordinate (x, y) the point
//! (x, h, y), as the galaxy (camera.rs); the game's world is it x 10. Checked against the game's
//! own frames (headless/view.sh, docs/render.md section 10):
//!
//! - bodies at h = -15 (the game's -150) **[V]**, each its entity scaled by the game's
//!   CPlanet::CalcCurrentEntityScale (`entity_scale`) **[V]**: stars, their class's entity
//!   (g_star_class_star_entity: base_star.mesh, PdxMeshStar); planets, their class's entity
//!   variant (`entity` = the variant: desert_planet_02_entity), lit by the first star (a point
//!   light), with clouds and an atmosphere in `atmosphere_color`;
//! - orbits: a ring at each body's distance from what it orbits, with the GUI (`gui off` hides
//!   them, as the game's g_bNoGUI does);
//! - ships at h = 0 **[V]** (their place on the game's screen): their culture's frame entity for the
//!   design's ship size with the design's sections' entities at the size's section slots'
//!   locators, at the ship's coordinate, turned to its forward_x / forward_y (a ship's model
//!   faces -z), at their model's size in the game's world **[I]**.

use std::collections::HashMap;
use std::sync::Arc;

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::camera::{OrbitCamera, ViewParams};
use crate::dds::Cache;
use crate::math::{M4, V3};
use crate::models::{self, Library};
use crate::scene::{self, Blend, Gui, Layer, Layout, Line, Look, Overlay, Pick, Pickable, Quad, Scene, Shading, Textures};
use crate::{particles, worldgfx, Map};

/// The system's plane: the game draws a system's bodies at y = -150 of its world (x 10: -15 map
/// units) **[V]** (their entities' world transforms, `state planet ID` of headless/view.sh).
pub const PLANE_Y: f32 = -15.0;
/// The game's world in a system is the map's x SYSTEM_SPACE_SCALE_MULT = 10 **[V]**.
pub const SYSTEM_SPACE_SCALE: f32 = 10.0;
/// A ship's model scale in map units: 1 in the game's world (x 10) **[I]**, fitted to the game's
/// frames of system 401 (its starbase within a few percent, at the same place and facing).
pub const SHIP_SCALE: f32 = 0.1;

/// A body's entity scale in the game's world (CPlanet::CalcCurrentEntityScale) **[V]**: planet_size
/// x 0.1 x the class's entity_scale x PLANET_SCALE_SYSTEM at the zoom (0.35 when g_bDisableScaling
/// is set, as in 4.5.2's defaults: the value seen at every zoom) x MOON_SCALE (0.7) for a moon.
pub fn entity_scale(size: f32, class_scale: f32, moon: bool) -> f32 {
    size * 0.1 * class_scale * 0.35 * if moon { 0.7 } else { 1.0 }
}

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
    /// the class's entity_scale (common/planet_classes)
    pub class_scale: f32,
    pub look: Look,
    /// it has a ring (binary_flags bit 8): PLANET_RING_ENTITY drawn with it
    pub ring: bool,
    pub name: crate::galaxy::Name,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct ShipInfo {
    pub id: u32,
    /// its fleet (a click on the ship selects it: CGameState::GetSelectableAt)
    pub fleet: u32,
    pub station: bool,
    pub x: f32,
    pub y: f32,
    pub fx: f32,
    pub fy: f32,
    pub size: String,
    pub frame: String,
    pub sections: Vec<(String, String)>,
    /// its weapons' turrets: (the section's index, the turret entity, the section's locator)
    pub turrets: Vec<(usize, String, String)>,
    /// the owner's empire colour (the `ship` swatch of its flag; None: the culture has no
    /// ship_color)
    pub colour: Option<[f32; 3]>,
    /// its culture's ship_lighting
    pub lighting: Option<ShipLighting>,
}

/// A graphical culture's ship_lighting (common/graphical_culture): the camera lights'
/// directions (camera space: x right, y up, z ahead) and the near-far values of their intensity,
/// the rim light's start and stop and the ambient, by the camera's distance (near_value ..
/// far_value of the game's world).
#[derive(Clone, Debug)]
pub struct ShipLighting {
    pub dirs: [[f32; 3]; 3],
    pub intensity: (f32, f32),
    pub fade: (f32, f32),
    pub rim_start: (f32, f32),
    pub rim_stop: (f32, f32),
    pub ambient: (f32, f32),
}

fn read_lighting(t: &Table) -> mlua::Result<ShipLighting> {
    let mut dirs = [[0.0; 3]; 3];
    let d: Table = t.get("dirs")?;
    for (k, v) in dirs.iter_mut().enumerate() {
        *v = rgb(&d.get::<Table>(k + 1)?)?;
    }
    let p = |a: &str, b: &str| -> mlua::Result<(f32, f32)> { Ok((t.get(a)?, t.get(b)?)) };
    Ok(ShipLighting {
        dirs,
        intensity: p("intensity_near", "intensity_far")?,
        fade: p("near_value", "far_value")?,
        rim_start: p("rim_start_near", "rim_start_far")?,
        rim_stop: p("rim_stop_near", "rim_stop_far")?,
        ambient: p("ambient_near", "ambient_far")?,
    })
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct SystemData {
    pub id: u32,
    pub bodies: Vec<Body>,
    pub ships: Vec<ShipInfo>,
    pub belts: Vec<Belt>,
    /// outer_radius (map units): the zoom steps are ZOOM_STEPS_SYSTEM_PERCENTAGES x it (x 10 in the
    /// game's world)
    pub outer_radius: f32,
    /// the gfx/worldgfx world of its star class (common/star_classes `class`: m_star for sc_m_giant)
    pub world: String,
}

/// An asteroid belt of the system: its inner_radius (map units) and its type's meshes, shader
/// (gfx/FX/asteroid.shader: Asteroid, AsteroidEmissive), density and width.
#[derive(Clone, Debug)]
pub struct Belt {
    pub radius: f32,
    pub meshes: Vec<String>,
    pub shader: String,
    pub density: f32,
    pub width: f32,
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
                class_scale: b.get::<Option<f32>>("entity_scale")?.unwrap_or(1.0),
                look: read_look(&b.get::<Table>("look")?)?,
                ring: b.get::<Option<bool>>("ring")?.unwrap_or(false),
                name: crate::galaxy::Name::read(b.get("name")?)?,
            });
        }
        let mut ships = Vec::new();
        for s in t.get::<Table>("ships")?.sequence_values::<Table>() {
            let s = s?;
            let mut sections = Vec::new();
            let mut turrets = Vec::new();
            for x in s.get::<Table>("sections")?.sequence_values::<Table>() {
                let x = x?;
                let mut t = Vec::new();
                for y in x.get::<Option<Table>>("turrets")?.map(|v| v.sequence_values::<Table>().collect::<Vec<_>>()).unwrap_or_default() {
                    let y = y?;
                    t.push((sections.len(), y.get::<String>("entity")?, y.get::<String>("locator")?));
                }
                turrets.extend(t);
                sections.push((x.get("entity")?, x.get("locator")?));
            }
            ships.push(ShipInfo {
                id: s.get("id")?,
                fleet: s.get("fleet")?,
                station: s.get("station")?,
                x: s.get("x")?,
                y: s.get("y")?,
                fx: s.get("fx")?,
                fy: s.get("fy")?,
                size: s.get("size")?,
                frame: s.get("frame")?,
                sections,
                turrets,
                colour: s.get::<Option<Table>>("colour")?.map(|c| rgb(&c)).transpose()?,
                lighting: s.get::<Option<Table>>("lighting")?.map(|l| read_lighting(&l)).transpose()?,
            });
        }
        let mut belts = Vec::new();
        for b in t.get::<Table>("belts")?.sequence_values::<Table>() {
            let b = b?;
            belts.push(Belt {
                radius: b.get("radius")?,
                meshes: b.get::<Table>("meshes")?.sequence_values::<String>().collect::<mlua::Result<_>>()?,
                shader: b.get("shader")?,
                density: b.get("density")?,
                width: b.get("width")?,
            });
        }
        Ok(SystemData { id, bodies, ships, belts, outer_radius: t.get::<Option<f32>>("outer_radius")?.unwrap_or(0.0), world: t.get::<Option<String>>("world")?.unwrap_or_default() })
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
    // SetPlanetEntityCustomData writes AtmosphereColor.a = 0 (4.5.2): no emissive recolouring and
    // no atmosphere tint on a planet's surface; its atmosphere is the shell
    look.colour_alpha = 0.0;
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

/// A camera over a system (its own space, centred on 0, 0): as the game enters a system, at
/// ENTER_SYSTEM_ZOOM_STEP 6 of ZOOM_STEPS_SYSTEM_PERCENTAGES { 0.025 0.1 0.25 0.5 1.0 1.5 3.0 }
/// of the system's size (outer_radius), pitch 50.
pub fn camera_for(map: &mut Map, index: usize) -> OrbitCamera {
    let id = map.galaxy.systems[index].id;
    let data = map.system_data(id).ok();
    let size = data.as_ref().map_or(0.0, |d| d.outer_radius);
    if size <= 0.0 {
        return OrbitCamera::system(data.map_or(250.0, |d| d.radius()));
    }
    let mut c = OrbitCamera::system(size);
    c.distance = 3.0 * size;
    c.max_distance = 3.0 * size;
    c.min_distance = 0.025 * size;
    c.zoom_steps = Some(SYSTEM_ZOOM_STEPS.map(|p| p * size));
    c
}

/// NCamera.ZOOM_STEPS_SYSTEM_PERCENTAGES: a system's zoom steps, shares of its outer_radius.
pub const SYSTEM_ZOOM_STEPS: [f32; 7] = [0.025, 0.1, 0.25, 0.5, 1.0, 1.5, 3.0];

/// The system's scene (`overlay`: the selection and the windows over it).
pub fn build(map: &mut Map, index: usize, camera: &OrbitCamera, width: u32, height: u32, overlay: &Overlay) -> Result<Scene, String> {
    let id = map.galaxy.systems[index].id;
    let gd = map.game_dir.clone();
    // the system's distance from the core, a share of the galaxy's radius (the sky's choice)
    let core_pct = {
        let s = &map.galaxy.systems[index];
        let r = map.galaxy.systems.iter().map(|o| (o.x * o.x + o.y * o.y).sqrt()).fold(1.0f32, f32::max);
        (s.x * s.x + s.y * s.y).sqrt() / r
    };
    // the top bar, as on the map
    let topbar = map.topbar(width, height)?;
    let data = map.system_data(id)?;
    // what was drawn is told once per system and world
    let key = (id, Arc::as_ptr(&data) as usize);
    let verbose = map.logged_system != Some(key);
    map.logged_system = Some(key);
    let Map { runtime, models: lib, textures: tex, cache, fonts, gui, particles: plib, button_states, .. } = map;
    let rt: &Runtime = runtime;
    lib.ensure(rt, &gd)?;
    let view = camera.view_params(width, height);
    let mut batches = Vec::new();
    let mut lines = Vec::new();
    let mut meshes = Vec::new();
    let mut picks = Vec::new();
    let mut cache = cache.borrow_mut();

    let mut light = [0.0, 30.0, 0.0, 1.0];
    let mut first_star = true;
    let positions: HashMap<u32, (f32, f32)> = data.bodies.iter().map(|b| (b.id, (b.x, b.y))).collect();
    let mut missing = Vec::new();
    for b in &data.bodies {
        let at = V3(b.x, PLANE_Y, b.y);
        // the entity's scale in map units: the game's (x 10 world) over the space scale
        let scale = entity_scale(b.size, b.class_scale, b.moon_of >= 0) / SYSTEM_SPACE_SCALE;
        if b.star && first_star {
            light = [b.x, PLANE_Y, b.y, 1.0];
            first_star = false;
        }
        match (!b.entity.is_empty()).then(|| lib.model(rt, &gd, &b.entity)) {
            Some(Ok(model)) => {
                if let Some((px, py, _)) = view.project(at) {
                    let r = model.radius() * scale * view.pixels_per_unit(at);
                    picks.push(Pick { what: Pickable::Body(b.id), centre: (px, py), radius: r.max(6.0) });
                }
                // its world transform: the position, the orientation, the scale (the entity's own
                // scale is applied by models::draws), as the game's (`state planet ID`)
                let m = M4::translation(at).mul(&body_rotation(b.id, b.x, b.y, b.star)).mul(&M4::scaling(scale));
                meshes.extend(models::draws(&model, m, [1.0; 4], &b.look, tex, &mut cache, &gd));
                // the entity's attachments (a black hole's rings and lens)
                attachments(lib, rt, &gd, &model, m, &b.look, tex, &mut cache, &mut meshes, &mut missing, 0);
                // its ring (PLANET_RING_ENTITY), at its place and scale, tilted by
                // PLANET_RING_TILT_FROM_SUN, the planet's custom data
                if b.ring {
                    match lib.model(rt, &gd, PLANET_RING_ENTITY) {
                        Ok(ring) => {
                            let rm = M4::translation(at).mul(&ring_rotation(b.x, b.y)).mul(&M4::scaling(scale));
                            meshes.extend(models::draws(&ring, rm, [1.0; 4], &b.look, tex, &mut cache, &gd));
                        }
                        Err(e) => missing.push(format!("{PLANET_RING_ENTITY}: {e}")),
                    }
                }
                // its particle effects (a star's surface fire and flares), with the entity's transform
                let em = m.mul(&M4::scaling(model.scale));
                for name in &model.particles {
                    match plib.effect(rt, &gd, name) {
                        Ok(e) => {
                            for (layer, blend, t, q) in particles::billboards(&e, &em, b.id, tex, &mut cache, &gd) {
                                batches_push(&mut batches, layer, blend, t, q);
                            }
                        }
                        Err(e) => missing.push(format!("{name}: {e}")),
                    }
                }
            }
            Some(Err(e)) => missing.push(format!("{} ({}): {e}", b.class, b.entity)),
            None => missing.push(format!("{}: no entity", b.class)),
        }
        // (the game draws no sprite over a star in a system: its glow is the star atmosphere)
        if !b.star && *gui {
            // the orbit: around the planet a moon orbits, else around the system's centre
            let (cx, cy) = if b.moon_of >= 0 { positions.get(&(b.moon_of as u32)).copied().unwrap_or((0.0, 0.0)) } else { (0.0, 0.0) };
            let r = ((b.x - cx).powi(2) + (b.y - cy).powi(2)).sqrt();
            let n = 96;
            for k in 0..n {
                let (a0, a1) = (k as f32 / n as f32 * std::f32::consts::TAU, (k + 1) as f32 / n as f32 * std::f32::consts::TAU);
                lines.push(Line {
                    a: V3(cx + r * a0.cos(), PLANE_Y, cy + r * a0.sin()),
                    b: V3(cx + r * a1.cos(), PLANE_Y, cy + r * a1.sin()),
                    colour: [0.45, 0.6, 0.85, if b.moon_of >= 0 { 0.25 } else { 0.35 }],
                    width: 1.2,
                    mode: 0.0,
                });
            }
        }
    }

    // the asteroid belts (CAsteroidGraphics::CalculateAsteroidFields, 4.5.2 Linux)
    let mut asteroids = 0;
    for belt in &data.belts {
        let models: Vec<models::Model> = belt.meshes.iter().filter_map(|n| lib.model(rt, &gd, n).ok()).collect();
        if models.is_empty() {
            missing.push(format!("asteroid belt meshes {:?}", belt.meshes));
            continue;
        }
        let flags = if belt.shader.eq_ignore_ascii_case("AsteroidEmissive") { crate::effects::EMISSIVE } else { 0 };
        for a in asteroid_field(belt, &models, id) {
            let m = &models[a.mesh];
            // the instance's frame (rows: its rotation axes), its size, in map units
            let r = a.rotation;
            let frame = M4([[r[0][0], r[0][1], r[0][2], 0.0], [r[1][0], r[1][1], r[1][2], 0.0], [r[2][0], r[2][1], r[2][2], 0.0], [0.0, 0.0, 0.0, 1.0]]);
            let t = M4::translation(a.pos).mul(&frame).mul(&M4::scaling(a.size / SYSTEM_SPACE_SCALE));
            let mut draws = models::draws(m, t, [1.0; 4], &Look::default(), tex, &mut cache, &gd);
            for d in &mut draws {
                // gfx/FX/asteroid.shader (the mesh's own shader is not used): PixelPdxMeshStandard
                // without IS_PLANET, EMISSIVE for AsteroidEmissive
                d.shading = Shading::Lit;
                d.params[0] = Shading::Lit.number();
                d.std = [flags as f32, 1.0, 0.0, 0.0];
            }
            meshes.extend(draws);
            asteroids += 1;
        }
    }
    if verbose && asteroids > 0 {
        eprintln!("system {id}: {asteroids} asteroids in {} belts", data.belts.len());
    }

    // ships
    let disc = tex.generated("@disc");
    let mut ships_drawn = 0;
    for s in &data.ships {
        // ships fly at the camera's plane, above the bodies' (their screen positions in the game's frames)
        let at = V3(s.x, 0.0, s.y);
        // PrimaryColor (in the look's atmosphere colour: the same constant slot as a planet's
        // AtmosphereColor) and the ship lights by the camera's distance (the game's world)
        let mut ship_look = Look::default();
        if let Some(c) = s.colour {
            ship_look.atmosphere = [c[0], c[1], c[2], 1.0];
            ship_look.colour_alpha = 1.0;
        }
        let ship_consts = |crunch: f32| -> [[f32; 4]; 4] {
            let Some(l) = &s.lighting else { return [[0.0; 4]; 4] };
            let dist = view.eye.sub(at).len() * SYSTEM_SPACE_SCALE;
            let f = ((dist - l.fade.0) / (l.fade.1 - l.fade.0).max(1e-3)).clamp(0.0, 1.0);
            let mix = |p: (f32, f32)| p.0 + (p.1 - p.0) * f;
            let d = l.dirs;
            [
                [d[0][0], d[0][1], d[0][2], mix(l.intensity)],
                [d[1][0], d[1][1], d[1][2], mix(l.rim_start)],
                [d[2][0], d[2][1], d[2][2], mix(l.rim_stop)],
                [mix(l.ambient), 0.0, crunch, 0.0],
            ]
        };
        let ship_draws = |model: &models::Model, t: M4, tex: &mut Textures, cache: &mut Cache| {
            let mut v = models::draws(model, t, [1.0; 4], &ship_look, tex, cache, &gd);
            let c = ship_consts(model.recolor_crunch);
            for d in &mut v {
                d.ship = c;
            }
            v
        };
        let yaw = (-s.fx).atan2(-s.fy);
        let base = M4::translation(at).mul(&M4::rotation_y(yaw)).mul(&M4::scaling(SHIP_SCALE));
        let frame = if s.frame.is_empty() { None } else { lib.model(rt, &gd, &s.frame).ok() };
        let mut drawn = 0;
        if let Some(f) = &frame {
            meshes.extend(ship_draws(f, base, tex, &mut cache));
            drawn += f.parts.len();
            // the frame entity's attachments (its `attach` entities at their locators)
            let mut extra = Vec::new();
            attachments(lib, rt, &gd, f, base, &ship_look, tex, &mut cache, &mut extra, &mut missing, 0);
            for d in &mut extra {
                d.ship = ship_consts(1.0);
            }
            meshes.extend(extra);
        }
        for (si, (entity, locator)) in s.sections.iter().enumerate() {
            let Ok(m) = lib.model(rt, &gd, entity) else { continue };
            let at_locator = frame
                .as_ref()
                .and_then(|f| f.locator(locator))
                .map(|l| M4::translation(V3(l.p[0], l.p[1], l.p[2])).mul(&M4::from_quat(l.q)))
                .unwrap_or(M4::IDENTITY);
            meshes.extend(ship_draws(&m, base.mul(&at_locator), tex, &mut cache));
            drawn += m.parts.len();
            let mut extra = Vec::new();
            attachments(lib, rt, &gd, &m, base.mul(&at_locator), &ship_look, tex, &mut cache, &mut extra, &mut missing, 0);
            for d in &mut extra {
                d.ship = ship_consts(1.0);
            }
            meshes.extend(extra);
            // its weapons' turrets at their slots' locators of the section's mesh
            for (_, te, tl) in s.turrets.iter().filter(|t| t.0 == si) {
                let (Ok(tm), Some(l)) = (lib.model(rt, &gd, te), m.locator(tl)) else { continue };
                let lt = M4::translation(V3(l.p[0], l.p[1], l.p[2])).mul(&M4::from_quat(l.q));
                meshes.extend(ship_draws(&tm, base.mul(&at_locator).mul(&M4::scaling(m.scale)).mul(&lt), tex, &mut cache));
            }
        }
        if let Some((px, py, _)) = view.project(at) {
            let r = frame.as_ref().map_or(1.0, |f| f.radius()) * SHIP_SCALE * view.pixels_per_unit(at);
            picks.push(Pick { what: Pickable::Fleet(s.fleet), centre: (px, py), radius: r.max(5.0) });
        }
        if drawn == 0 {
            // no model: a marker
            batches_push(&mut batches, Layer::Stars, Blend::Alpha, disc, Quad::billboard(s.x, s.y, 0.5, 0.8, [0.8, 0.9, 1.0, 1.0], 0.0, 3.0));
        } else {
            ships_drawn += 1;
        }
    }
    if verbose && !missing.is_empty() {
        eprintln!("system {id}: models not drawn: {}", missing.join("; "));
    }
    if verbose {
        eprintln!("system {id}: {} bodies, {} of {} ships with a model, {} mesh draws", data.bodies.len(), ships_drawn, data.ships.len(), meshes.len());
    }
    if verbose {
        let mut entities: Vec<String> = data.ships.iter().flat_map(|s| std::iter::once(s.frame.clone()).chain(s.sections.iter().map(|(e, l)| format!("{e}@{l}")))).collect();
        entities.sort();
        entities.dedup();
        eprintln!("system {id}: ship models: {}", entities.join(" "));
    }
    if verbose && !tex.missing.is_empty() {
        eprintln!("system {id}: textures not loaded: {}", tex.missing.join("; "));
    }

    // the post effects of the system's star: the gfx/worldgfx world its star class names
    // (CStarClass::CalcClassKeyHash: common/star_classes `class`, sc_binary_10: a_star)
    let world = if data.world.is_empty() { "system_view".to_string() } else { data.world.clone() };
    let world_gfx = worldgfx::read(rt, &gd, &world)?;
    let post = world_gfx.post(tex, &mut cache, &gd);
    let sky = world_gfx.sky(tex, &mut cache, &gd, core_pct);
    let env = world_gfx.env(tex, &mut cache, &gd);
    // the star's light (gfx/lights: the world's system_light, colour x intensity) and the back light
    let lc = worldgfx::light(rt, &gd, &world_gfx.system_light).unwrap_or([1.3, 1.3, 1.3]);
    let light_colour = [lc[0], lc[1], lc[2], 1.0];
    // the game makes the light settings linear twice (^2.2 in SLightDescription::ReadMember and
    // again in SetConstants): ^4.84
    let bl = world_gfx.back_light.map(|c| c.max(0.0).powf(2.2 * 2.2));
    let back_light = [bl[0], bl[1], bl[2], 1.0];
    // the ships' camera lights, rim light and ambient: light settings too (^4.84)
    let cam_lights = world_gfx.ship_lights.map(|c| [c[0].max(0.0).powf(4.84), c[1].max(0.0).powf(4.84), c[2].max(0.0).powf(4.84), 1.0]);
    if verbose {
        eprintln!("system {id}: world {world} ({}), light {} {:?}, back light {:?}", world_gfx.world, world_gfx.system_light, lc, world_gfx.back_light);
    }
    if let Some(sel) = overlay.selected {
        scene::selection_marker(&mut batches, &mut lines, tex, &mut cache, &gd, &view, &picks, sel, true);
    }
    let mut g = Gui::default();
    if *gui {
        scene::add_gui(&mut batches, &mut g, &topbar.items, fonts.as_ref().unwrap(), tex, &mut cache, &gd, button_states);
        scene::add_gui(&mut batches, &mut g, &overlay.items, fonts.as_ref().unwrap(), tex, &mut cache, &gd, button_states);
    }
    Ok(Scene {
        layout: Layout { width, height, world_to_ndc: [1.0, 1.0, 0.0, 0.0], scale: 1.0, lane_width: 1.0 },
        view,
        light,
        light_colour,
        back_light,
        cam_lights,
        batches,
        lines,
        meshes,
        clear: [0.005, 0.006, 0.016],
        stars: Vec::new(),
        picks,
        sprites: g.sprites,
        texts: g.texts,
        buttons: g.buttons,
        post: Some(post),
        sky,
        env,
        maps: None,
    })
}

/// The draws of an entity's `attach = { locator = entity }` (recursively): each at its parent's
/// locator (the mesh's; one the mesh lacks, such as an entity's own `locator = { name }`, at the
/// parent's origin), with the parent's look.
#[allow(clippy::too_many_arguments)]
fn attachments(
    lib: &mut models::Library,
    rt: &Runtime,
    gd: &str,
    model: &models::Model,
    transform: M4,
    look: &Look,
    tex: &mut scene::Textures,
    cache: &mut crate::dds::Cache,
    meshes: &mut Vec<scene::MeshDraw>,
    missing: &mut Vec<String>,
    depth: u32,
) {
    if depth > 4 {
        return;
    }
    let world = transform.mul(&M4::scaling(model.scale));
    for (locator, entity) in &model.attach {
        let child = match lib.model(rt, gd, entity) {
            Ok(c) => c,
            Err(e) => {
                missing.push(format!("{entity} (attached to {}): {e}", model.name));
                continue;
            }
        };
        let at = model.locator(locator).map(|l| M4::translation(V3(l.p[0], l.p[1], l.p[2])).mul(&M4::from_quat(l.q))).unwrap_or(M4::IDENTITY);
        let t = world.mul(&at);
        meshes.extend(models::draws(&child, t, [1.0; 4], look, tex, cache, gd));
        attachments(lib, rt, gd, &child, t, look, tex, cache, meshes, missing, depth + 1);
    }
}

/// The game's CNoiseRandom stream (GetInteger, GetFloat, GetInteger(lo, hi)).
struct NoiseRandom {
    pos: u32,
    seed: u32,
}

impl NoiseRandom {
    fn integer(&mut self) -> u32 {
        let x = noise_random(self.pos, self.seed);
        self.pos = self.pos.wrapping_add(1);
        (x & 0x7fff_fffe) ^ (x >> 8)
    }
    fn float(&mut self) -> f32 {
        self.integer() as f32 * (1.0 / 2_147_483_648.0)
    }
    fn range(&mut self, lo: u32, hi: u32) -> u32 {
        lo + self.integer() % (hi - lo + 1)
    }
}

/// One asteroid of a belt: its mesh (an index into the belt's meshes), place (map units),
/// rotation (rows) and size.
struct Asteroid {
    mesh: usize,
    pos: V3,
    rotation: [[f32; 3]; 3],
    size: f32,
}

/// A belt's asteroids as CAsteroidGraphics::CalculateAsteroidFields places them (4.5.2 Linux, read
/// from the code), in the game's system world (map x 10): N = trunc(2 pi R 0.1 density) with R the
/// inner_radius x 10, evenly spaced angles (i pi / (N / 2)), the radius R + 80 width t^3 (t in
/// [-1, 1)), the height -100 - 40 u, the size 1 + 4 u, a random axis; a slot retried (up to 1000
/// times) while its box overlaps the last placed one. The game seeds its random numbers from the
/// clock (the layout differs per run): here CNoiseRandom seeded with the system's id. Not done:
/// the asteroid planets' boxes that remove slots, the spin over time.
fn asteroid_field(belt: &Belt, models: &[models::Model], system: u32) -> Vec<Asteroid> {
    const SSM: f32 = SYSTEM_SPACE_SCALE;
    let mut rnd = NoiseRandom { pos: noise_random(system, 0x5ea6_ba9f) ^ (noise_random(system, 0x5ea6_ba9f) >> 8), seed: 0 };
    let r0 = belt.radius * SSM;
    let n = ((std::f32::consts::TAU * r0) * 0.1 * belt.density) as i64;
    let half = (n / 2).max(1);
    let step = 1.0 / half as f32;
    let mut out = Vec::new();
    let mut prev: Option<([f32; 3], [f32; 3])> = None;
    let mut retry = 0;
    let mut i = 1;
    while i <= n {
        if retry > 999 {
            retry = 0;
            i += 1;
            continue;
        }
        let mesh = rnd.range(0, models.len() as u32 - 1) as usize;
        let size = 1.0 + rnd.float() * 4.0;
        let t = 2.0 * rnd.float() - 1.0;
        let p = t * t * t;
        let r = r0 + belt.width * 80.0 * p;
        let th = i as f32 * std::f32::consts::PI * step;
        let (cx, cz) = (-r * th.sin(), r * th.cos());
        let m = &models[mesh];
        let (lo, hi) = m.aabb;
        let s = size * m.scale;
        let bx = ([cx + lo[0] * s, -100.0 + lo[1] * s, cz + lo[2] * s], [cx + hi[0] * s, -100.0 + hi[1] * s, cz + hi[2] * s]);
        if i != 1 && prev.is_some_and(|q| (0..3).all(|k| bx.0[k] <= q.1[k] && bx.1[k] >= q.0[k])) {
            retry += 1;
            continue;
        }
        let y = -100.0 - rnd.float() * 40.0;
        let d = V3(rnd.float() - 0.5, rnd.float() - 0.5, rnd.float() - 0.5);
        let z = if d.len() > 1e-6 { d.norm() } else { V3(0.0, 0.0, 1.0) };
        let x = V3(0.0, 1.0, 0.0).cross(z);
        let x = if x.len() > 1e-6 { x.norm() } else { V3(1.0, 0.0, 0.0) };
        let yv = z.cross(x);
        out.push(Asteroid { mesh, pos: V3(cx / SSM, y / SSM, cz / SSM), rotation: [[x.0, x.1, x.2], [yv.0, yv.1, yv.2], [z.0, z.1, z.2]], size });
        prev = Some(bx);
        retry = 0;
        i += 1;
    }
    out
}

/// CNoiseRandom (4.5.2): the hash before its last step, of a position and a seed.
fn noise_random(pos: u32, seed: u32) -> u32 {
    let mut a = pos.wrapping_mul(0xb529_7a4d).wrapping_add(seed);
    a = (a ^ (a >> 8)).wrapping_add(0x68e3_1da4);
    a = (a ^ (a << 8)).wrapping_mul(0x1b56_c4e9);
    (a ^ (a >> 8)).wrapping_mul(0x92d6_8ca2)
}

/// A body's orientation as CGraphicalMap::SetupPlanetEntityInstance makes it (4.5.2 Linux, read
/// from the code; the game's `state planet ID` agrees for system 401's bodies): a star turned
/// half about y; a planet's z axis toward the system's centre, raised by PLANET_TILT_FROM_SUN
/// (0.52) over the plane (z = normalize(-p.x / L, -p.y / L + 0.52, -p.z / L), p its place, L
/// its distance in the plane), x level (up x z), y = z x x; x and y turned over when a
/// CCrudeRandom seeded with the planet's id draws an even number (bit 8 of the hash).
pub fn body_rotation(id: u32, x: f32, z: f32, star: bool) -> M4 {
    if star {
        return M4::rotation_y(std::f32::consts::PI);
    }
    let l = (x * x + z * z).sqrt().max(1e-3);
    let fwd = V3(-x / l, -PLANE_Y / l + PLANET_TILT_FROM_SUN, -z / l).norm();
    let mut right = V3(0.0, 1.0, 0.0).cross(fwd).norm();
    let s = noise_random(id, 0x5ea6_ba9f);
    let s = s ^ (s >> 8);
    if (noise_random(s, 0) >> 8) & 1 == 0 {
        right = right.scale(-1.0);
    }
    let up = fwd.cross(right);
    M4([[right.0, up.0, fwd.0, 0.0], [right.1, up.1, fwd.1, 0.0], [right.2, up.2, fwd.2, 0.0], [0.0, 0.0, 0.0, 1.0]])
}

/// A planet's ring's orientation (SetupPlanetEntityInstance): as the planet's, raised by
/// PLANET_RING_TILT_FROM_SUN (-0.16) instead, never turned over.
pub fn ring_rotation(x: f32, z: f32) -> M4 {
    let l = (x * x + z * z).sqrt().max(1e-3);
    let fwd = V3(-x / l, -PLANE_Y / l + PLANET_RING_TILT_FROM_SUN, -z / l).norm();
    let right = V3(0.0, 1.0, 0.0).cross(fwd).norm();
    let up = fwd.cross(right);
    M4([[right.0, up.0, fwd.0, 0.0], [right.1, up.1, fwd.1, 0.0], [right.2, up.2, fwd.2, 0.0], [0.0, 0.0, 0.0, 1.0]])
}

/// NGraphics::PLANET_TILT_FROM_SUN, PLANET_RING_TILT_FROM_SUN (common/defines)
const PLANET_TILT_FROM_SUN: f32 = 0.52;
const PLANET_RING_TILT_FROM_SUN: f32 = -0.16;
/// the ring's entity (the game's PLANET_RING_ENTITY string)
const PLANET_RING_ENTITY: &str = "gas_giant_rings_01_entity";

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
    let world = worldgfx::read(rt, game_dir, "default")?;
    let post = world.post(tex, cache, game_dir);
    let env = world.env(tex, cache, game_dir);
    let sky = None;
    let view: ViewParams = camera.view_params(width, height);
    // the light from the upper left of the camera
    let to_eye = view.eye.sub(camera.target).norm();
    let l = view.right.scale(-0.7).add(view.up.scale(0.55)).add(to_eye.scale(0.45)).norm();
    Ok(Scene {
        layout: Layout { width, height, world_to_ndc: [1.0, 1.0, 0.0, 0.0], scale: 1.0, lane_width: 1.0 },
        view,
        light: [l.0, l.1, l.2, 0.0],
        light_colour: [1.3, 1.3, 1.3, 1.0],
        back_light: [0.41, 0.48, 0.55, 1.0],
        cam_lights: [[0.0; 4]; 5],
        batches: Vec::new(),
        lines: Vec::new(),
        meshes,
        clear: [0.02, 0.025, 0.04],
        stars: Vec::new(),
        picks: Vec::new(),
        sprites: Vec::new(),
        texts: Vec::new(),
        buttons: Vec::new(),
        post: Some(post),
        sky,
        env,
        maps: None,
    })
}
