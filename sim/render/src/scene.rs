//! What a frame draws, built on the CPU: textured quads in batches (by layer, blend and texture),
//! lines, meshes, the view they are seen through, and where everything went (for the checks).
//! World space: the galactic plane is y = 0 and a map coordinate (x, y) is the point (x, 0, y)
//! (camera.rs); the GUI and its texts are in screen pixels.
//!
//! Layers, in drawing order:
//! - Background: the galaxy's dust clouds (gfx/map/dust.dds, coloured by gfx/map/galaxycolor.dds
//!   at their position, added), its centre (gfx/map/center.dds, added), the nebulae
//!   (gfx/map/nebula.dds coloured by gfx/map/nebulacolor.dds), a system's backdrop;
//! - Borders: the territories (border.rs), one texture on the plane;
//! - Models: the game's meshes (planets, stars, ships), lit;
//! - Lanes: lines: the hyperlanes (NGraphics.HYPERLANE_DEFAULT_COLOR), the fleets' FTL trails,
//!   a system's orbits;
//! - Stars: each system's star sprite (gfx/map/star_classes/<class>.dds, added: glows on black),
//!   GALAXY_STAR_ICON_SCALE x the class's icon_scale, facing the camera; the fleets' markers;
//! - Gui: the top bar's sprites (interface/main.gui through render/gui.lua);
//! - Text: its texts, in the game's bitmap font.

use std::collections::HashMap;
use std::sync::Arc;

use bytemuck::{Pod, Zeroable};

use crate::border::Borders;
use crate::camera::{OrbitCamera, ViewParams};
use crate::dds::{Cache, Image};
use crate::font::Font;
use crate::galaxy::Galaxy;
use crate::gui::{GuiItem, Topbar};
use crate::math::{M4, V3};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Layer {
    Background = 0,
    Borders = 1,
    Models = 2,
    Lanes = 3,
    Stars = 4,
    Gui = 5,
    Text = 6,
}

pub const LAYERS: [Layer; 7] = [Layer::Background, Layer::Borders, Layer::Models, Layer::Lanes, Layer::Stars, Layer::Gui, Layer::Text];
pub const ALL: u32 = 0b1111111;

impl Layer {
    pub fn bit(self) -> u32 {
        1 << self as u32
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Blend {
    Alpha,
    Add,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum QuadKind {
    /// on a horizontal plane at `height`: the rect in map units (x, y = the world's x, z)
    Plane,
    /// pixels from the top left
    Screen,
    /// facing the camera, centred on the rect's centre at `height`, half the rect's width as its
    /// half size (world units), at least `least_px` pixels
    Billboard,
}

#[derive(Clone, Copy, Debug)]
pub struct Quad {
    /// x0, y0, x1, y1: map units (world) or pixels (screen); the corner (x0, y0) gets the
    /// texture's (u0, v0)
    pub rect: [f32; 4],
    pub uv: [f32; 4],
    /// multiplies the texel (sRGB, straight alpha)
    pub colour: [f32; 4],
    /// radians, about the rectangle's centre
    pub rot: f32,
    pub kind: QuadKind,
    pub height: f32,
    pub least_px: f32,
    /// the galaxy view's shading (map.wgsl fs_quad): mode, terra incognita brightness, tilt; the
    /// dust colour map's rectangle
    pub fx: [f32; 4],
    pub fx2: [f32; 4],
}

impl Quad {
    pub fn plane(rect: [f32; 4], colour: [f32; 4], rot: f32) -> Quad {
        Quad { rect, uv: [0.0, 0.0, 1.0, 1.0], colour, rot, kind: QuadKind::Plane, height: 0.0, least_px: 0.0, fx: [0.0; 4], fx2: [0.0; 4] }
    }
    pub fn billboard(x: f32, y: f32, height: f32, half: f32, colour: [f32; 4], rot: f32, least_px: f32) -> Quad {
        Quad { rect: [x - half, y - half, x + half, y + half], uv: [0.0, 0.0, 1.0, 1.0], colour, rot, kind: QuadKind::Billboard, height, least_px, fx: [0.0; 4], fx2: [0.0; 4] }
    }
}

pub struct Batch {
    pub layer: Layer,
    pub blend: Blend,
    pub texture: usize,
    pub quads: Vec<Quad>,
}

/// A line in the world, `width` pixels wide.
#[derive(Clone, Copy, Debug)]
pub struct Line {
    pub a: V3,
    pub b: V3,
    pub colour: [f32; 4],
    pub width: f32,
    /// 1: a hyperlane of the galaxy view (map.wgsl: greyed and faded outside the known space)
    pub mode: f32,
}

/// A mesh's vertex on the GPU.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable, Debug)]
pub struct MeshVertex {
    pub pos: [f32; 3],
    pub normal: [f32; 3],
    pub tangent: [f32; 4],
    pub uv: [f32; 2],
}

/// A sub-mesh ready for the GPU, uploaded once under its key.
pub struct MeshData {
    pub key: String,
    pub vertices: Vec<MeshVertex>,
    pub indices: Vec<u32>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Shading {
    /// lit by the scene's light: planets, ships (PixelPdxMeshStandard, PixelPdxMeshShip)
    Lit,
    /// its texture glows (stand-ins)
    Emissive,
    /// a planet's atmosphere: its back faces, added (PixelPdxMeshAtmosphere)
    Atmosphere,
    /// lit, blended by the texture's alpha (PdxMeshClouds: PixelPdxMeshStandard with IS_CLOUDS)
    Clouds,
    /// a star's surface: lava and stone (PixelPdxMeshStar)
    Star,
    /// a star's glow: its back faces, added (PixelPdxMeshAtmosphereStar)
    StarAtmosphere,
    /// a planet's ring: both faces, blended, its alpha added to the bloom's mask
    /// (PdxMeshPlanetRings: BlendStateAlphaBlendWriteAlpha, RasterizerStateNoCulling)
    Ring,
    /// an additive effect (PixelPdxMeshAdditive: BlendStateAdditiveBlend, no depth write): the
    /// diffuse x its alpha, alpha x vBloomFactor
    Additive,
}

impl Shading {
    pub fn number(self) -> f32 {
        match self {
            Shading::Lit => 0.0,
            Shading::Emissive => 1.0,
            Shading::Atmosphere => 2.0,
            Shading::Clouds => 3.0,
            Shading::Star => 4.0,
            Shading::StarAtmosphere => 5.0,
            Shading::Ring => 6.0,
            Shading::Additive => 7.0,
        }
    }
}

/// What a model is lit as, beyond its textures: the game's per-entity shader constants.
#[derive(Clone, Copy, Debug)]
pub struct Look {
    /// AtmosphereColor / StarAtmosphereColor (rgb) and AtmosphereIntensity (a); a = 0: none
    pub atmosphere: [f32; 4],
    /// AtmosphereWidth / StarAtmosphereWidth
    pub width: f32,
    /// 1: a planet (IS_PLANET), 2: a ship (camera lights, rim light), 0: neither
    pub kind: f32,
    /// a star's LavaBrightColor, LavaHotStoneColor, LavaColdStoneColor (gfx/worldgfx)
    pub lava: [[f32; 3]; 3],
    /// AtmosphereColor.a (0 for planets: SetPlanetEntityCustomData)
    pub colour_alpha: f32,
}

impl Default for Look {
    fn default() -> Look {
        Look { atmosphere: [0.55, 0.7, 1.0, 1.0], width: 0.5, kind: 0.0, lava: [[0.5, 0.55, 0.5], [1.0, 0.75, 0.3], [0.9, 0.4, 0.13]], colour_alpha: 0.0 }
    }
}

pub struct MeshDraw {
    pub mesh: Arc<MeshData>,
    pub model: M4,
    /// diffuse, normal, specular (indices into the scene's textures); a star: lava, stone, -
    pub textures: [usize; 3],
    pub shading: Shading,
    pub tint: [f32; 4],
    /// x: the shading's number (set from `shading`), y: emissive strength, z: specular strength,
    /// w: ambient
    pub params: [f32; 4],
    pub look: Look,
    /// a cube map (an index into the scene's textures): the stars' lava noise
    pub cube: Option<usize>,
    /// PixelPdxMeshStandard's constants: the effect's defines (effects.rs bits), vBloomFactor,
    /// - (the scene's CubemapIntensity), AtmosphereColor.a
    pub std: [f32; 4],
    /// a ship part's PixelPdxMeshShip constants: the three camera lights' directions (camera
    /// space) with w the lights' intensity, w of the second the rim's start and of the third its
    /// stop; the fourth: the ambient intensity, -, EmissiveRecolorCrunch, -
    pub ship: [[f32; 4]; 4],
}

impl MeshDraw {
    pub fn new(mesh: Arc<MeshData>, model: M4, textures: [usize; 3], shading: Shading, tint: [f32; 4]) -> MeshDraw {
        MeshDraw { mesh, model, textures, shading, tint, params: [shading.number(), 1.6, 1.0, 0.12], look: Look::default(), cube: None, std: [0.0, 1.0, 0.0, 1.0], ship: [[0.0; 4]; 4] }
    }
}

/// The view of a target of `width` x `height` pixels: the galaxy fitted into it (the 2D map).
#[derive(Clone, Copy, Debug)]
pub struct Layout {
    pub width: u32,
    pub height: u32,
    /// map units -> clip space: ndc = p * xy + zw. The save's x is drawn growing to the left
    /// and y downwards: the game's galaxy seen from above at yaw 0 (its camera, docs/render.md
    /// section 10).
    pub world_to_ndc: [f32; 4],
    /// pixels per map unit
    pub scale: f32,
    pub lane_width: f32,
}

impl Layout {
    /// Fits the galaxy below a top bar of `top` pixels.
    pub fn fit(galaxy: &Galaxy, width: u32, height: u32, top: f32) -> Layout {
        let (mut x0, mut x1, mut y0, mut y1) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
        for s in &galaxy.systems {
            x0 = x0.min(s.x);
            x1 = x1.max(s.x);
            y0 = y0.min(s.y);
            y1 = y1.max(s.y);
        }
        if galaxy.systems.is_empty() {
            (x0, x1, y0, y1) = (-1.0, 1.0, -1.0, 1.0);
        }
        let (w, h) = (width.max(1) as f32, height.max(1) as f32);
        let margin = 0.03 * w.min(h) + 8.0;
        let (avail_w, avail_h) = ((w - 2.0 * margin).max(1.0), (h - top - 2.0 * margin).max(1.0));
        let scale = (avail_w / (x1 - x0).max(1e-3)).min(avail_h / (y1 - y0).max(1e-3));
        let (cx, cy) = (0.5 * (x0 + x1), 0.5 * (y0 + y1));
        let (sx, sy) = (scale * 2.0 / w, scale * 2.0 / h);
        // the galaxy's centre at the middle of the area under the bar
        let ny = -(top / h);
        Layout { width, height, world_to_ndc: [-sx, -sy, cx * sx, cy * sy + ny], scale, lane_width: (scale * 0.6).clamp(1.0, 2.5) }
    }

    /// A map position -> pixels from the top left.
    pub fn to_pixel(&self, x: f32, y: f32) -> (f32, f32) {
        let nx = x * self.world_to_ndc[0] + self.world_to_ndc[2];
        let ny = y * self.world_to_ndc[1] + self.world_to_ndc[3];
        ((nx + 1.0) * 0.5 * self.width as f32, (1.0 - ny) * 0.5 * self.height as f32)
    }
}

/// The textures a scene uses: index -> (name, image). Game files by their path, generated ones
/// by a name starting with "@".
#[derive(Default)]
pub struct Textures {
    pub names: Vec<String>,
    pub images: Vec<Arc<Image>>,
    index: HashMap<String, usize>,
    pub missing: Vec<String>,
}

impl Textures {
    pub fn add(&mut self, name: &str, image: Arc<Image>) -> usize {
        if let Some(&i) = self.index.get(name) {
            self.images[i] = image;
            return i;
        }
        self.names.push(name.to_string());
        self.images.push(image);
        self.index.insert(name.to_string(), self.names.len() - 1);
        self.names.len() - 1
    }

    pub fn find(&self, name: &str) -> Option<usize> {
        self.index.get(name).copied()
    }

    /// A game texture by its path; None (and noted) if it does not load.
    pub fn game(&mut self, cache: &mut Cache, game_dir: &str, path: &str) -> Option<usize> {
        if let Some(&i) = self.index.get(path) {
            return Some(i);
        }
        match cache.get(game_dir, path) {
            Ok(img) => {
                let img = Arc::new(img.clone());
                Some(self.add(path, img))
            }
            Err(e) => {
                if !self.missing.contains(&e) {
                    self.missing.push(e);
                }
                None
            }
        }
    }

    /// A cube map from the game's files (dds::load_cube), its first level, under the name
    /// `cube:<path>`.
    pub fn game_cube(&mut self, cache: &mut Cache, game_dir: &str, path: &str) -> Option<usize> {
        self.game_cube_levels(cache, game_dir, path, 1)
    }

    /// A cube map with up to `levels` of its file's mip levels (a pre-filtered environment map).
    pub fn game_cube_levels(&mut self, cache: &mut Cache, game_dir: &str, path: &str, levels: u32) -> Option<usize> {
        let name = if levels <= 1 { format!("cube:{path}") } else { format!("cube{levels}:{path}") };
        if let Some(&i) = self.index.get(&name) {
            return Some(i);
        }
        match cache.get_cube(game_dir, path, levels) {
            Ok(img) => {
                let img = Arc::new(img.clone());
                Some(self.add(&name, img))
            }
            Err(e) => {
                if !self.missing.contains(&e) {
                    self.missing.push(e);
                }
                None
            }
        }
    }

    /// A generated texture: a soft disc (for markers), a flat colour.
    pub fn generated(&mut self, name: &str) -> usize {
        if let Some(i) = self.find(name) {
            return i;
        }
        let img = match name {
            "@disc" => {
                let n = 32u32;
                let mut rgba = vec![0u8; (n * n * 4) as usize];
                for y in 0..n {
                    for x in 0..n {
                        let (dx, dy) = (x as f32 + 0.5 - n as f32 / 2.0, y as f32 + 0.5 - n as f32 / 2.0);
                        let d = (dx * dx + dy * dy).sqrt() / (n as f32 / 2.0);
                        let a = ((1.0 - d) * 6.0).clamp(0.0, 1.0);
                        let i = ((y * n + x) * 4) as usize;
                        rgba[i..i + 4].copy_from_slice(&[255, 255, 255, (a * 255.0) as u8]);
                    }
                }
                Image { width: n, height: n, rgba, format: "generated".into() }
            }
            "@ring" => {
                let n = 64u32;
                let mut rgba = vec![0u8; (n * n * 4) as usize];
                for y in 0..n {
                    for x in 0..n {
                        let (dx, dy) = (x as f32 + 0.5 - n as f32 / 2.0, y as f32 + 0.5 - n as f32 / 2.0);
                        let d = (dx * dx + dy * dy).sqrt() / (n as f32 / 2.0);
                        let a = (1.0 - ((d - 0.8).abs() / 0.12)).clamp(0.0, 1.0);
                        let i = ((y * n + x) * 4) as usize;
                        rgba[i..i + 4].copy_from_slice(&[255, 255, 255, (a * 255.0) as u8]);
                    }
                }
                Image { width: n, height: n, rgba, format: "generated".into() }
            }
            // flat: white, a flat normal (x, y = 0.5 in green and alpha), no specular
            "@white" => Image { width: 1, height: 1, rgba: vec![255, 255, 255, 255], format: "generated".into() },
            // the game's layout (UnpackRRxGNormal): x in green, y in alpha, blue the emissive
            "@flat_normal" => Image { width: 1, height: 1, rgba: vec![128, 128, 0, 128], format: "generated".into() },
            "@black" => Image { width: 1, height: 1, rgba: vec![0, 0, 0, 255], format: "generated".into() },
            _ => Image { width: 1, height: 1, rgba: vec![255, 0, 255, 255], format: "generated".into() },
        };
        self.add(name, Arc::new(img))
    }
}

/// A star drawn: its system and its rectangle on screen.
pub struct PlacedStar {
    pub system: usize,
    pub rect: [f32; 4],
}

/// Something on the map a click can select.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pickable {
    /// a system (its index in the galaxy's systems)
    System(usize),
    /// a fleet (its save id)
    Fleet(u32),
    /// a planet, moon or star of a system (its save id)
    Body(u32),
    /// a ship in a system (its save id)
    Ship(u32),
}

/// Where a pickable thing is on the screen: its centre and radius in pixels.
#[derive(Clone, Copy, Debug)]
pub struct Pick {
    pub what: Pickable,
    pub centre: (f32, f32),
    pub radius: f32,
}

/// What the window adds over a view: the selection (marked), and GUI windows over the view
/// (the outliner, an info window) with their own buttons.
#[derive(Clone, Debug, Default)]
pub struct Overlay {
    pub selected: Option<Pickable>,
    pub items: Vec<GuiItem>,
}

/// A GUI sprite drawn: its element, sprite, rectangle on screen, and whether its frame has any
/// visible texel.
pub struct PlacedSprite {
    pub path: String,
    pub sprite: String,
    pub rect: [f32; 4],
    pub visible: bool,
    /// the drawing order among the GUI's sprites and texts
    pub order: usize,
}

/// A GUI text drawn: its element, text, font, box and where its pen started.
pub struct PlacedText {
    pub path: String,
    pub text: String,
    pub font: String,
    pub rect: [f32; 4],
    pub pen: (f32, f32),
    pub order: usize,
}

/// The sky behind a 3D view (sky.wgsl): a cube map, its YCoCg flag, the hue / saturation / value
/// shift and the colour cube (gfx/worldgfx `galaxy_background*`).
#[derive(Clone, Debug)]
pub struct SkyDraw {
    pub cube: usize,
    pub ycocg: bool,
    pub hsv_shift: [f32; 3],
    pub lut: Option<usize>,
}

/// The post effects of a world (gfx/worldgfx: worldgfx.rs; the shaders: post.wgsl).
#[derive(Clone, Debug)]
pub struct Post {
    pub bright_threshold: f32,
    pub bloom_width: f32,
    pub bloom_scale: f32,
    pub bloom_iterations: u32,
    pub emissive_bloom: f32,
    pub hdr_min: f32,
    pub hdr_max: f32,
    pub middle_grey: f32,
    /// the colour cube (an index into the scene's textures)
    pub lut: Option<usize>,
}

pub struct Scene {
    pub layout: Layout,
    pub view: ViewParams,
    /// xyz: toward the light (w = 0) or the light's position (w = 1)
    pub light: [f32; 4],
    /// the light's colour x intensity (linear); the planets' back light (gamma space)
    pub light_colour: [f32; 4],
    pub back_light: [f32; 4],
    /// the ships' lights (gfx/worldgfx, linear): cam_light_1..3_diffuse, rim_light_diffuse, ambient
    pub cam_lights: [[f32; 4]; 5],
    pub batches: Vec<Batch>,
    pub lines: Vec<Line>,
    pub meshes: Vec<MeshDraw>,
    pub clear: [f32; 3],
    pub stars: Vec<PlacedStar>,
    /// what a click can select, where it is drawn (the topmost last)
    pub picks: Vec<Pick>,
    pub sprites: Vec<PlacedSprite>,
    pub texts: Vec<PlacedText>,
    pub buttons: Vec<PlacedButton>,
    /// the game's post effects (HDR, bloom, exposure, tone mapping, the colour cube), for the 3D
    /// views; None: drawn straight to the target (the 2D map, the front end)
    pub post: Option<Post>,
    /// the sky drawn behind everything (with the post effects only)
    pub sky: Option<SkyDraw>,
    /// the world's environment map (a cube with its mip levels: an index into the textures) and
    /// cubemap_intensity, for the meshes' reflections
    pub env: Option<(usize, f32)>,
    /// the galaxy view's map textures (galaxymap.rs; indices into the textures): terra incognita,
    /// the borders' distance, edge and fill colours, the dust's colour map
    pub maps: Option<[usize; 5]>,
}

impl Scene {
    /// The button on top under a point (the last drawn), if any.
    pub fn button_at(&self, x: f32, y: f32) -> Option<&PlacedButton> {
        self.buttons.iter().rev().find(|b| x >= b.rect[0] && x < b.rect[2] && y >= b.rect[1] && y < b.rect[3])
    }

    /// The star nearest to a point on the screen within `radius` pixels: its system's index.
    pub fn star_at(&self, x: f32, y: f32, radius: f32) -> Option<usize> {
        self.stars
            .iter()
            .map(|s| {
                let (cx, cy) = (0.5 * (s.rect[0] + s.rect[2]), 0.5 * (s.rect[1] + s.rect[3]));
                (s.system, ((cx - x).powi(2) + (cy - y).powi(2)).sqrt())
            })
            .filter(|(_, d)| *d <= radius)
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(s, _)| s)
    }

    /// The pickable thing under a point, as the game picks (CGameState::DoSelection): fleets
    /// (on the galaxy, GUI icons that take the click first) and, in a system, ships and bodies,
    /// the nearest whose radius (at least `least` pixels) takes it (GetSelectableAt: the nearest
    /// along the ray); else the first system, in the galaxy's order, within its cone
    /// (FindGalacticObjectUnderMouse).
    pub fn pick_at(&self, x: f32, y: f32, least: f32) -> Option<Pickable> {
        let dist = |p: &Pick| ((p.centre.0 - x).powi(2) + (p.centre.1 - y).powi(2)).sqrt();
        let near = self
            .picks
            .iter()
            .filter(|p| !matches!(p.what, Pickable::System(_)))
            .filter_map(|p| {
                let r = p.radius.max(least);
                let d = dist(p);
                (d <= r).then_some((p.what, d / r))
            })
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(w, _)| w);
        near.or_else(|| self.picks.iter().find(|p| matches!(p.what, Pickable::System(_)) && dist(p) <= p.radius).map(|p| p.what))
    }
}

/// A galaxy star's billboard half size in map units for a camera `distance` (map units) away: the
/// game's CGalaxyGraphics::CalcCurrentStarScale, clamp(1 + (zoom - ZOOM_STEPS_GALAXY[0]) /
/// (ZOOM_STEPS_GALAXY[last] - [0]) x GALAXY_SPACE_SCALE_MULT x GALAXY_STAR_ICON_MAX_SCALE, 1,
/// GALAXY_SPACE_SCALE_MULT x GALAXY_STAR_ICON_MAX_SCALE), the zoom being the camera's distance in
/// the game's world (map x 2); times 1.5 (galaxy_stars.shader), over 2 back to map units.
pub fn star_half_size(distance: f32) -> f32 {
    let zoom = distance * 2.0;
    let max = 2.0 * 1.25;
    let scale = (1.0 + (zoom - 100.0) / (3000.0 - 100.0) * max).clamp(1.0, max);
    scale * 1.5 / 2.0
}

/// A small deterministic generator for the dust's placement.
pub struct Rng(pub u32);
impl Rng {
    pub fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        (self.0 >> 8) as f32 / (1u32 << 24) as f32
    }
}

pub fn sample(img: &Image, u: f32, v: f32) -> [f32; 4] {
    let x = (u.clamp(0.0, 1.0) * (img.width - 1) as f32) as u32;
    let y = (v.clamp(0.0, 1.0) * (img.height - 1) as f32) as u32;
    img.pixel(x, y).map(|c| c as f32 / 255.0)
}

pub fn push(batches: &mut Vec<Batch>, layer: Layer, blend: Blend, texture: usize, q: Quad) {
    match batches.last_mut() {
        Some(b) if b.layer == layer && b.blend == blend && b.texture == texture => b.quads.push(q),
        _ => batches.push(Batch { layer, blend, texture, quads: vec![q] }),
    }
}

pub struct Inputs<'a> {
    pub galaxy: &'a Galaxy,
    pub borders: &'a Borders,
    pub borders_texture: usize,
    /// the galaxy view's map textures (terra incognita, the borders' distance, edge and fill):
    /// with them the 3D galaxy is drawn as the game's (galaxy_3d)
    pub maps: Option<[usize; 4]>,
    pub topbar: &'a Topbar,
    pub fonts: &'a HashMap<String, Font>,
    pub gui: bool,
    pub game_dir: &'a str,
    /// the GUI's buttons under the mouse
    pub states: &'a HashMap<String, ButtonState>,
    /// the selection and the windows over the view
    pub overlay: &'a Overlay,
}

/// The galaxy view in 3D as the game draws it (CGalaxyGraphics and gfx/FX galaxy_*.shader,
/// hyperlane.shader, border.shader; docs/render.md section 11), in map units (the game's world
/// / 2): the nebulae's clouds, a dust cloud at every system and in the core, the core's glow,
/// the stars, the hyperlanes; the borders are not drawn themselves but tint the dust and the
/// nebulae (border.shader's target is read by them only); everything greyed outside the
/// player's terra incognita. Returns the scene's map textures.
#[allow(clippy::too_many_arguments)]
fn galaxy_3d(
    inp: &Inputs,
    maps: [usize; 4],
    tex: &mut Textures,
    cache: &mut Cache,
    camera: &OrbitCamera,
    view: &ViewParams,
    batches: &mut Vec<Batch>,
    lines: &mut Vec<Line>,
    stars: &mut Vec<PlacedStar>,
) -> Option<[usize; 5]> {
    let g = inp.galaxy;
    // the dust's colour map, stretched over the systems' bounding box with the origin
    let (mut x0, mut y0, mut x1, mut y1) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    for s in &g.systems {
        (x0, y0, x1, y1) = (x0.min(s.x), y0.min(s.y), x1.max(s.x), y1.max(s.y));
    }
    let rect = [x0, y0, 1.0 / (x1 - x0).max(1.0), 1.0 / (y1 - y0).max(1.0)];
    let colour_map = tex.game(cache, inp.game_dir, "gfx/map/galaxycolor.dds")?;
    let index: HashMap<u32, usize> = g.systems.iter().enumerate().map(|(i, s)| (s.id, i)).collect();
    let height = |s: &crate::galaxy::System| s.height * 0.5;

    // the nebulae (galaxy_nebula.shader, CGalaxyGraphics::InitNebulas): a cloud of the nebula's
    // radius at its place, one of (10 + 25 r) at each of its systems, 9 below the plane (the
    // game's world), turned by 2 pi r
    if let Some(nebula) = tex.game(cache, inp.game_dir, "gfx/map/nebula.dds") {
        let mean = tex.game(cache, inp.game_dir, "gfx/map/nebulacolor.dds").map(|i| {
            let img = &tex.images[i];
            let n = (img.width * img.height) as f32;
            let mut acc = [0f32; 4];
            for p in img.rgba.chunks_exact(4) {
                for c in 0..4 {
                    acc[c] += p[c] as f32 / 255.0;
                }
            }
            acc.map(|v| v / n)
        });
        let colour = mean.unwrap_or([1.0; 4]);
        let mut rng = Rng(0x0eb1_a5ed);
        for n in &g.nebulae {
            let mut clouds = vec![(n.x, n.y, n.radius)];
            for sid in &n.systems {
                if let Some(&i) = index.get(sid) {
                    clouds.push((g.systems[i].x, g.systems[i].y, 10.0 + 25.0 * rng.next()));
                }
            }
            for (x, y, half) in clouds {
                let mut q = Quad::plane([x - half, y - half, x + half, y + half], colour, rng.next() * std::f32::consts::TAU);
                q.height = -4.5;
                q.fx = [3.0, 1.0, 5.0 / half.max(1e-3) * 0.5, 0.0];
                push(batches, Layer::Background, Blend::Alpha, nebula, q);
            }
        }
    }

    // the dust (galaxy_dust.shader, CGalaxyGraphics::Init): a cloud at every system and
    // int(0.1 R) in the core's disc (R its radius in the game's world), of half size
    // GALAXY_DUST_SIZE + GALAXY_DUST_SIZE_EXTRA x r, 20 above or below the plane at most, turned
    // by +-2 pi r, tilted (y += (corner x + corner y) x size x 0.1)
    if let Some(dust) = tex.game(cache, inp.game_dir, "gfx/map/dust.dds") {
        let mut points: Vec<(f32, f32)> = g.systems.iter().map(|s| (s.x, s.y)).collect();
        let r_core = g.core_radius;
        let mut rng = Rng(0x5eed_1234);
        for _ in 0..(0.1 * r_core * 2.0) as usize {
            let (r, a) = (r_core * rng.next().sqrt(), rng.next() * std::f32::consts::TAU);
            points.push((r * a.cos(), r * a.sin()));
        }
        for (x, y) in points {
            let mut prng = Rng((x * 1000.0) as i32 as u32 ^ ((y * 1000.0) as i32 as u32).rotate_left(16) ^ 0x9e37_79b9);
            let half = g.dust_size + g.dust_size_extra * prng.next();
            let h = (prng.next() * 2.0 - 1.0) * 10.0;
            let rot = (prng.next() * 2.0 - 1.0) * std::f32::consts::TAU;
            let mut q = Quad::plane([x - half, y - half, x + half, y + half], [1.0; 4], rot);
            q.height = h;
            q.fx = [2.0, 1.0, 0.1, 0.0];
            q.fx2 = rect;
            push(batches, Layer::Background, Blend::Alpha, dust, q);
        }
    }

    // the core's glow (galaxy_center.shader): center.dds x 0.5 on the plane, its quad x 1.5, added
    // by ONE, ONE, greyed outside the known space; the quad's half size taken as core_radius of
    // the game's world [I] (twice that reaches beyond what the game's frames show)
    if let Some(center) = tex.game(cache, inp.game_dir, "gfx/map/center.dds") {
        let half = 1.5 * g.core_radius;
        if half > 0.0 {
            let mut q = Quad::plane([-half, -half, half, half], [0.5, 0.5, 0.5, 1.0], 0.0);
            q.height = -0.75;
            q.fx = [1.0, 1.0, 0.0, 1.0];
            push(batches, Layer::Background, Blend::Add, center, q);
        }
    }

    // the hyperlanes (hyperlane.shader): HYPERLANE_DEFAULT_COLOR (alpha 0.2 at the default
    // opacity), about a pixel wide, faded outside the known space
    // (built only when an end lies in the known space: HIDE_HYPERLANES_OUTSIDE_TERRA_INCOGNITA)
    let known = |s: &crate::galaxy::System| -> bool {
        let Some(ti) = &g.terra_incognita else { return true };
        let n = ti.size as f32;
        let (col, row) = ((s.x * n / 1000.0 + n / 2.0).floor(), (s.y * n / 1000.0 + n / 2.0).floor());
        col >= 0.0 && row >= 0.0 && col < n && row < n && ti.bitmap[row as usize * ti.size + col as usize] > 127
    };
    let lane_colour = g.hyperlane_colour;
    for &(a, b) in &g.lanes {
        let (sa, sb) = (&g.systems[a as usize], &g.systems[b as usize]);
        if known(sa) || known(sb) {
            lines.push(Line { a: V3(sa.x, height(sa), sa.y), b: V3(sb.x, height(sb), sb.y), colour: lane_colour, width: 1.0, mode: 1.0 });
        }
    }

    // the star pins (border.shader StarPin, CBordersGraphics::UpdatePins): a hexagon of radius 2
    // (the game's world) on the plane and a line up to the star, the owner's border colour (the
    // player's own and those it has communications with; otherwise the neutral grey 0.5, alpha
    // 0.5), alpha x 0.2
    for s in &g.systems {
        let c = match g.shown_owner(s) {
            Some(o) => {
                let k = g.countries[o].primary;
                [k[0], k[1], k[2], 0.2]
            }
            None => [0.5, 0.5, 0.5, 0.5 * 0.2],
        };
        let r = 1.0;
        for k in 0..6 {
            let (a0, a1) = (k as f32 * std::f32::consts::TAU / 6.0, (k + 1) as f32 * std::f32::consts::TAU / 6.0);
            lines.push(Line { a: V3(s.x + r * a0.cos(), 0.0, s.y + r * a0.sin()), b: V3(s.x + r * a1.cos(), 0.0, s.y + r * a1.sin()), colour: c, width: 1.2, mode: 2.0 });
        }
        lines.push(Line { a: V3(s.x, 0.0, s.y), b: V3(s.x, height(s), s.y), colour: c, width: 1.2, mode: 2.0 });
    }

    // the stars (galaxy_stars.shader): the class's sprite, a billboard of half size 1.5 x Scale
    // of the game's world, Scale = icon_scale x CalcCurrentStarScale x 1.5, the zoom's scale
    // clamp(1 + 2.5 (zoom - 100) / 2900, 1, 2.5); added, greyed outside the known space
    let zoom = camera.distance * 2.0;
    let s_zoom = (1.0 + 2.5 * (zoom - 100.0) / 2900.0).clamp(1.0, 2.5);
    let mut order: Vec<usize> = (0..g.systems.len()).collect();
    order.sort_by(|&a, &b| g.systems[a].texture.cmp(&g.systems[b].texture));
    for i in order {
        let s = &g.systems[i];
        let Some(t) = (if s.texture.is_empty() { None } else { tex.game(cache, inp.game_dir, &s.texture) }) else { continue };
        let half = 1.5 * s.icon_scale * s_zoom * 1.5 * 0.5;
        let mut q = Quad::billboard(s.x, s.y, height(s), half, [1.0; 4], 0.0, 0.0);
        q.fx = [1.0, 1.0, 0.0, 0.0];
        push(batches, Layer::Stars, Blend::Add, t, q);
        let p3 = V3(s.x, height(s), s.y);
        if let Some((px, py, _)) = view.project(p3) {
            let hp = (half * view.pixels_per_unit(p3)).max(3.0);
            stars.push(PlacedStar { system: i, rect: [px - hp, py - hp, px + hp, py + hp] });
        }
    }
    Some([maps[0], maps[1], maps[2], maps[3], colour_map])
}

/// The galaxy map for a target of `width` x `height`: the 2D map (no camera: top-down,
/// orthographic, fitted under the top bar) or the 3D galaxy seen from `camera`.
pub fn build(inp: &Inputs, tex: &mut Textures, cache: &mut Cache, width: u32, height: u32, camera: Option<&OrbitCamera>) -> Scene {
    let g = inp.galaxy;
    let bar_height = 36.0;
    let layout = Layout::fit(g, width, height, bar_height);
    let view = match camera {
        Some(c) => c.view_params(width, height),
        None => ViewParams::orthographic(layout.world_to_ndc, width, height),
    };
    let three_d = camera.is_some();
    let mut batches = Vec::new();

    // the 3D galaxy as the game draws it (with its map textures), else the renderer's own map
    let game3d = three_d && inp.maps.is_some();
    let mut lines: Vec<Line> = Vec::new();
    let mut stars = Vec::new();
    let mut scene_maps = None;
    if let (true, Some(maps), Some(c)) = (game3d, inp.maps, camera) {
        scene_maps = galaxy_3d(inp, maps, tex, cache, c, &view, &mut batches, &mut lines, &mut stars);
    } else {
    // ---- background: dust coloured by the galaxy's colour map, the centre, the nebulae
    let radius = g.systems.iter().map(|s| (s.x * s.x + s.y * s.y).sqrt()).fold(1.0f32, f32::max) * 1.05;
    let colour_map = tex.game(cache, inp.game_dir, "gfx/map/galaxycolor.dds").map(|i| tex.images[i].clone());
    if let (Some(dust), Some(cmap)) = (tex.game(cache, inp.game_dir, "gfx/map/dust.dds"), colour_map) {
        let mut rng = Rng(0x5eed_1234);
        let mut points: Vec<(f32, f32)> = g.systems.iter().map(|s| (s.x, s.y)).collect();
        for _ in 0..g.systems.len() / 2 {
            let (r, a) = (radius * rng.next().sqrt(), rng.next() * std::f32::consts::TAU);
            points.push((r * a.cos(), r * a.sin()));
        }
        for (x, y) in points {
            let (x, y) = (x + (rng.next() - 0.5) * 20.0, y + (rng.next() - 0.5) * 20.0);
            let size = g.dust_size + rng.next() * g.dust_size_extra;
            let c = sample(&cmap, 0.5 + x / (2.0 * radius), 0.5 - y / (2.0 * radius));
            let rot = rng.next() * std::f32::consts::TAU;
            let colour = [c[0], c[1], c[2], if three_d { 0.4 } else { 0.55 }];
            // in 3D the clouds have some thickness above and below the plane
            let height = if three_d { (rng.next() - 0.5) * 12.0 } else { 0.0 };
            push(&mut batches, Layer::Background, Blend::Add, dust, Quad::billboard(x, y, height, size, colour, rot, 0.0));
        }
    }
    if let Some(center) = tex.game(cache, inp.game_dir, "gfx/map/center.dds") {
        let half = radius * 0.55;
        let q = if three_d { Quad::billboard(0.0, 0.0, 0.0, half, [1.0, 1.0, 1.0, 0.9], 0.0, 0.0) } else { Quad::plane([-half, -half, half, half], [1.0, 1.0, 1.0, 0.9], 0.0) };
        push(&mut batches, Layer::Background, Blend::Add, center, q);
    }
    let nebula_map = tex.game(cache, inp.game_dir, "gfx/map/nebulacolor.dds").map(|i| tex.images[i].clone());
    if let (Some(nebula), Some(nmap)) = (tex.game(cache, inp.game_dir, "gfx/map/nebula.dds"), nebula_map) {
        let mut rng = Rng(0x0eb1_a5ed);
        for n in &g.nebulae {
            let c = sample(&nmap, 0.5 + n.x / (2.0 * radius), 0.5 - n.y / (2.0 * radius));
            // a few clouds over the nebula's disc
            for k in 0..6 {
                let (r, a) = (n.radius * 0.5 * rng.next().sqrt(), rng.next() * std::f32::consts::TAU);
                let (x, y) = (n.x + r * a.cos(), n.y + r * a.sin());
                let half = n.radius * (0.7 + 0.4 * rng.next());
                let colour = [c[0].max(0.25), c[1].max(0.25), c[2].max(0.3), 0.9];
                let _ = k;
                push(&mut batches, Layer::Background, Blend::Add, nebula, Quad::plane([x - half, y - half, x + half, y + half], colour, rng.next() * std::f32::consts::TAU));
            }
        }
    }

    // ---- borders: one texture on the plane
    let b = inp.borders;
    push(&mut batches, Layer::Borders, Blend::Alpha, inp.borders_texture, Quad::plane(b.rect, [1.0; 4], 0.0));

    // ---- lines: hyperlanes, then the fleets' FTL trails
    let lane_width = if three_d { 1.5 } else { layout.lane_width };
    lines = g
        .lanes
        .iter()
        .map(|&(a, b)| {
            let (sa, sb) = (&g.systems[a as usize], &g.systems[b as usize]);
            Line { a: V3(sa.x, 0.0, sa.y), b: V3(sb.x, 0.0, sb.y), colour: g.hyperlane_colour, width: lane_width, mode: 0.0 }
        })
        .collect();

    // ---- stars, by texture (one batch per sprite)
    let mut order: Vec<usize> = (0..g.systems.len()).collect();
    order.sort_by(|&a, &b| g.systems[a].texture.cmp(&g.systems[b].texture));
    for i in order {
        let s = &g.systems[i];
        let Some(t) = (if s.texture.is_empty() { None } else { tex.game(cache, inp.game_dir, &s.texture) }) else { continue };
        // the sprite's size in map units: 2D, 6 x GALAXY_STAR_ICON_SCALE x icon_scale, at least
        // 12 px; 3D, the game's (galaxy_stars.shader: a billboard of half size Scale x 1.5 in its
        // world, Scale = CGalaxyGraphics::CalcCurrentStarScale) **[V]**, x icon_scale **[I]**
        let size = 6.0 * g.star_icon_scale * s.icon_scale;
        let (half, least) = if three_d { (star_half_size(camera.map_or(600.0, |c| c.distance)) * s.icon_scale, 2.0) } else { ((size.max(12.0 / layout.scale)) * 0.5, 0.0) };
        push(&mut batches, Layer::Stars, Blend::Add, t, Quad::billboard(s.x, s.y, 0.0, half, [1.0; 4], 0.0, least));
        if let Some((px, py, _)) = view.project(V3(s.x, 0.0, s.y)) {
            let hp = (half * view.pixels_per_unit(V3(s.x, 0.0, s.y))).max(least);
            stars.push(PlacedStar { system: i, rect: [px - hp, py - hp, px + hp, py + hp] });
        }
    }

    }

    // ---- fleets: a marker in the owner's colour, a trail to where an FTL jump goes (the game
    // shows none without its GUI)
    let disc = tex.generated("@disc");
    let mut per_system: HashMap<(i32, i32), u32> = HashMap::new();
    // the systems, in the galaxy's order: in 3D within the cone of NCamera.SYSTEM_HOVER_RANGE
    // (0.005 of the camera's distance to the star off the mouse's ray), on the 2D map the sprite
    let mut by_system: Vec<&PlacedStar> = stars.iter().collect();
    by_system.sort_by_key(|s| s.system);
    let mut picks: Vec<Pick> = by_system
        .iter()
        .map(|s| Pick {
            what: Pickable::System(s.system),
            centre: (0.5 * (s.rect[0] + s.rect[2]), 0.5 * (s.rect[1] + s.rect[3])),
            radius: if three_d { 0.005 * view.focal_px } else { (0.5 * (s.rect[2] - s.rect[0])).max(6.0) },
        })
        .collect();
    for f in g.fleets.iter().filter(|_| !(game3d && !inp.gui)) {
        if f.station {
            continue;
        }
        let colour = match f.owner {
            Some(o) => {
                let c = g.countries[o].primary;
                [c[0].max(0.35), c[1].max(0.35), c[2].max(0.35), 1.0]
            }
            None => [0.85, 0.85, 0.85, 1.0],
        };
        // fleets at one place are spread around it
        let key = ((f.x * 4.0) as i32, (f.y * 4.0) as i32);
        let n = per_system.entry(key).or_default();
        let a = *n as f32 * 2.399;
        let r = if *n == 0 { 0.0 } else { 2.5 + 0.6 * (*n as f32).sqrt() };
        *n += 1;
        let (x, y) = (f.x + 4.0 + r * a.cos(), f.y + 4.0 + r * a.sin());
        let half = if f.military { 1.6 } else { 1.1 };
        push(&mut batches, Layer::Stars, Blend::Alpha, disc, Quad::billboard(x, y, 0.5, half, colour, 0.0, if three_d { 3.0 } else { 0.0 }));
        let p3 = V3(x, 0.5, y);
        if let Some((px, py, _)) = view.project(p3) {
            picks.push(Pick { what: Pickable::Fleet(f.id), centre: (px, py), radius: (half * view.pixels_per_unit(p3)).max(3.0) });
        }
        if let (Some((fx, fy)), Some((tx, ty))) = (f.from, f.to) {
            // the trail: from where the jump started to where it goes
            lines.push(Line { a: V3(fx, 0.3, fy), b: V3(tx, 0.3, ty), colour: [colour[0], colour[1], colour[2], 0.85], width: 2.0, mode: 0.0 });
        }
    }

    // ---- the selection's marker
    if let Some(sel) = inp.overlay.selected {
        selection_marker(&mut batches, &mut lines, tex, cache, inp.game_dir, &view, &picks, sel, three_d);
    }

    // ---- the top bar's sprites and texts, then the windows over the view
    let mut gui = Gui::default();
    if inp.gui {
        add_gui(&mut batches, &mut gui, &inp.topbar.items, inp.fonts, tex, cache, inp.game_dir, inp.states);
        add_gui(&mut batches, &mut gui, &inp.overlay.items, inp.fonts, tex, cache, inp.game_dir, inp.states);
    }

    Scene {
        layout,
        view,
        light: [0.4, 0.8, 0.3, 0.0],
        light_colour: [1.3, 1.3, 1.3, 1.0],
        back_light: [0.41, 0.48, 0.55, 1.0],
        cam_lights: [[0.0; 4]; 5],
        batches,
        lines,
        meshes: Vec::new(),
        clear: [0.0, 0.0, 0.0],
        stars,
        picks,
        sprites: gui.sprites,
        texts: gui.texts,
        buttons: gui.buttons,
        post: None,
        sky: None,
        env: None,
        maps: scene_maps,
    }
}

/// The selection's marker over a picked thing: a ring around it on the screen, in
/// NGraphics.RELATION_COLOR_SELECTED_RGB.
#[allow(clippy::too_many_arguments)]
pub fn selection_marker(
    batches: &mut Vec<Batch>,
    _lines: &mut Vec<Line>,
    tex: &mut Textures,
    _cache: &mut Cache,
    _game_dir: &str,
    _view: &ViewParams,
    picks: &[Pick],
    selected: Pickable,
    _three_d: bool,
) {
    let Some(p) = picks.iter().find(|p| p.what == selected) else { return };
    let ring = tex.generated("@ring");
    let r = (p.radius * 1.6).max(10.0);
    let (x, y) = p.centre;
    push(batches, Layer::Gui, Blend::Alpha, ring, screen_quad([x - r, y - r, x + r, y + r], [0.0, 0.0, 1.0, 1.0], [1.0, 0.73, 0.0, 1.0]));
}

/// A button's state under the mouse: its sprite shows the matching frame (frame 1 normal, 2
/// hover, 3 pressed, 4 disabled, as far as the sprite has frames).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ButtonState {
    Hover,
    Pressed,
}

/// The GUI drawn: sprites, texts and buttons, where they went.
#[derive(Default)]
pub struct Gui {
    pub sprites: Vec<PlacedSprite>,
    pub texts: Vec<PlacedText>,
    pub buttons: Vec<PlacedButton>,
}

/// A button drawn: its element, its rectangle on screen, and what a click does.
#[derive(Clone, Debug)]
pub struct PlacedButton {
    pub path: String,
    pub rect: [f32; 4],
    pub action: Option<String>,
}

fn screen_quad(rect: [f32; 4], uv: [f32; 4], colour: [f32; 4]) -> Quad {
    Quad { rect, uv, colour, rot: 0.0, kind: QuadKind::Screen, height: 0.0, least_px: 0.0, fx: [0.0; 4], fx2: [0.0; 4] }
}

/// Adds GUI items to the batches: sprites (button frames by state, cornered tiles as nine
/// slices; a background still in the Background layer) and texts (span by span, in their
/// colours, vertically centred when the box says so).
#[allow(clippy::too_many_arguments)]
pub fn add_gui(
    batches: &mut Vec<Batch>,
    gui: &mut Gui,
    items: &[GuiItem],
    fonts: &HashMap<String, Font>,
    tex: &mut Textures,
    cache: &mut Cache,
    game_dir: &str,
    states: &HashMap<String, ButtonState>,
) {
    for item in items {
        match item {
            GuiItem::Sprite { path, sprite, texture, frame, frames, x, y, w, h, border, kind, button, action } => {
                let Some(t) = tex.game(cache, game_dir, texture) else { continue };
                let img = tex.images[t].clone();
                let (tw, th) = (img.width as f32, img.height as f32);
                let n = (*frames).max(1);
                let mut frame = (*frame).max(1);
                if *button && (2..=4).contains(&n) {
                    frame = match states.get(path) {
                        Some(ButtonState::Hover) => 2,
                        Some(ButtonState::Pressed) => 3.min(n),
                        None => frame,
                    };
                }
                let (nf, f) = (n as f32, (frame.min(n) - 1) as f32);
                let (u0, u1) = (f / nf, (f + 1.0) / nf);
                let fw = tw / nf;
                let visible = {
                    let (a, bx) = ((u0 * tw) as u32, (u1 * tw) as u32);
                    (0..img.height).any(|yy| (a..bx.min(img.width)).any(|xx| img.pixel(xx, yy)[3] > 0))
                };
                let layer = if kind == "still" { Layer::Background } else { Layer::Gui };
                match border {
                    Some((bx, by)) if *bx > 0.0 || *by > 0.0 => {
                        // nine slices: the corners at their size, the edges and middle stretched
                        let (bx, by) = (bx.min(w / 2.0).min(fw / 2.0), by.min(h / 2.0).min(th / 2.0));
                        let xs = [*x, x + bx, x + w - bx, x + w];
                        let ys = [*y, y + by, y + h - by, y + h];
                        let us = [u0, u0 + bx / tw, u1 - bx / tw, u1];
                        let vs = [0.0, by / th, 1.0 - by / th, 1.0];
                        for r in 0..3 {
                            for c in 0..3 {
                                push(batches, layer, Blend::Alpha, t, screen_quad([xs[c], ys[r], xs[c + 1], ys[r + 1]], [us[c], vs[r], us[c + 1], vs[r + 1]], [1.0; 4]));
                            }
                        }
                    }
                    _ => push(batches, layer, Blend::Alpha, t, screen_quad([*x, *y, x + w, y + h], [u0, 0.0, u1, 1.0], [1.0; 4])),
                }
                if layer == Layer::Gui {
                    let order = gui.sprites.len() + gui.texts.len();
                    gui.sprites.push(PlacedSprite { path: path.clone(), sprite: sprite.clone(), rect: [*x, *y, x + w, y + h], visible, order });
                }
                if *button {
                    gui.buttons.push(PlacedButton { path: path.clone(), rect: [*x, *y, x + w, y + h], action: action.clone() });
                }
            }
            GuiItem::Text { path, font, text, spans, x, y, w, h, format, valign } => {
                let Some(f) = fonts.get(font) else { continue };
                let Some(t) = tex.game(cache, game_dir, &f.texture) else { continue };
                // a text wider than its box is cut, " ..." at its end (as the game's outliner
                // shows a long name)
                let cut;
                let (text, spans) = if *w > 8.0 && f.width(text) > w + 0.5 {
                    let mut keep: Vec<(String, [f32; 3])> = Vec::new();
                    let mut used = f.width(" ...");
                    'outer: for (s, c) in spans {
                        let mut part = String::new();
                        for ch in s.chars() {
                            let cw = f.width(&ch.to_string());
                            if used + cw > *w {
                                keep.push((part, *c));
                                break 'outer;
                            }
                            used += cw;
                            part.push(ch);
                        }
                        keep.push((part, *c));
                    }
                    let last = keep.last().map_or([1.0; 3], |k| k.1);
                    if let Some(k) = keep.last_mut() {
                        let trimmed = k.0.trim_end().to_string();
                        k.0 = trimmed;
                    }
                    keep.push((" ...".to_string(), last));
                    let plain: String = keep.iter().map(|k| k.0.as_str()).collect();
                    cut = (plain, keep);
                    (&cut.0, &cut.1)
                } else {
                    (text, spans)
                };
                let tw = f.width(text);
                let pen_x = match format.as_str() {
                    "center" | "centre" => x + (w - tw) / 2.0,
                    "right" => x + w - tw,
                    _ => *x,
                }
                .round();
                let pen_y = match valign.as_str() {
                    "center" | "centre" => y + (h - f.line_height) / 2.0,
                    "bottom" => y + h - f.line_height,
                    _ => *y,
                }
                .round();
                let (aw, ah) = (f.image.width as f32, f.image.height as f32);
                let mut pen = pen_x;
                for (s, colour) in spans {
                    for (_, r, uv) in f.place(s, pen, pen_y) {
                        push(batches, Layer::Text, Blend::Alpha, t, screen_quad(r, [uv[0] / aw, uv[1] / ah, uv[2] / aw, uv[3] / ah], [colour[0], colour[1], colour[2], 1.0]));
                    }
                    pen += f.width(s);
                }
                let order = gui.sprites.len() + gui.texts.len();
                gui.texts.push(PlacedText { path: path.clone(), text: text.clone(), font: font.clone(), rect: [*x, *y, x + w, y + h], pen: (pen_x, pen_y), order });
            }
        }
    }
}

/// A scene of GUI only (the front end), for a target of `width` x `height`.
#[allow(clippy::too_many_arguments)]
pub fn gui_scene(
    width: u32,
    height: u32,
    items: &[GuiItem],
    fonts: &HashMap<String, Font>,
    tex: &mut Textures,
    cache: &mut Cache,
    game_dir: &str,
    states: &HashMap<String, ButtonState>,
) -> Scene {
    let mut batches = Vec::new();
    let mut gui = Gui::default();
    add_gui(&mut batches, &mut gui, items, fonts, tex, cache, game_dir, states);
    let layout = Layout { width, height, world_to_ndc: [1.0, 1.0, 0.0, 0.0], scale: 1.0, lane_width: 1.0 };
    Scene {
        layout,
        view: ViewParams::orthographic(layout.world_to_ndc, width, height),
        light: [0.4, 0.8, 0.3, 0.0],
        light_colour: [1.3, 1.3, 1.3, 1.0],
        back_light: [0.41, 0.48, 0.55, 1.0],
        cam_lights: [[0.0; 4]; 5],
        batches,
        lines: Vec::new(),
        meshes: Vec::new(),
        clear: [0.0, 0.0, 0.0],
        stars: Vec::new(),
        picks: Vec::new(),
        sprites: gui.sprites,
        texts: gui.texts,
        buttons: gui.buttons,
        post: None,
        sky: None,
        env: None,
        maps: None,
    }
}
