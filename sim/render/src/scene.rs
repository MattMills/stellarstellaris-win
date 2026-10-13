//! What a frame draws, built on the CPU: textured quads in batches (by layer, blend and texture),
//! the hyperlanes, and where everything went (for the checks). The galaxy is in map units through
//! the fitted view; the GUI and its texts are in screen pixels.
//!
//! Layers, in drawing order:
//! - Background: the galaxy's dust clouds (gfx/map/dust.dds, coloured by gfx/map/galaxycolor.dds
//!   at their position, added) and its centre (gfx/map/center.dds, added);
//! - Borders: the territories (border.rs), one texture over the galaxy;
//! - Lanes: the hyperlanes, NGraphics.HYPERLANE_DEFAULT_COLOR;
//! - Stars: each system's star sprite (gfx/map/star_classes/<class>.dds, added: the sprites are
//!   glows on black), GALAXY_STAR_ICON_SCALE x the class's icon_scale;
//! - Gui: the top bar's sprites (interface/main.gui through render/gui.lua);
//! - Text: its texts, in the game's bitmap font.

use std::collections::HashMap;
use std::sync::Arc;

use crate::border::Borders;
use crate::dds::{Cache, Image};
use crate::font::Font;
use crate::galaxy::Galaxy;
use crate::gui::{GuiItem, Topbar};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Layer {
    Background = 0,
    Borders = 1,
    Lanes = 2,
    Stars = 3,
    Gui = 4,
    Text = 5,
}

pub const LAYERS: [Layer; 6] = [Layer::Background, Layer::Borders, Layer::Lanes, Layer::Stars, Layer::Gui, Layer::Text];
pub const ALL: u32 = 0b111111;

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

#[derive(Clone, Copy, Debug)]
pub struct Quad {
    /// x0, y0, x1, y1: map units (world) or pixels from the top left (screen); the corner (x0, y0)
    /// gets the texture's (u0, v0)
    pub rect: [f32; 4],
    pub uv: [f32; 4],
    /// multiplies the texel (sRGB, straight alpha)
    pub colour: [f32; 4],
    /// radians, about the rectangle's centre
    pub rot: f32,
    pub screen: bool,
}

pub struct Batch {
    pub layer: Layer,
    pub blend: Blend,
    pub texture: usize,
    pub quads: Vec<Quad>,
}

/// The view of a target of `width` x `height` pixels: the galaxy fitted into it.
#[derive(Clone, Copy, Debug)]
pub struct Layout {
    pub width: u32,
    pub height: u32,
    /// map units -> clip space: ndc = p * xy + zw. The save's x is drawn growing to the left
    /// (mirrored, the convention of save viewers such as Stellaris Dashboard; not yet checked
    /// against the game's own map); y grows up.
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
        Layout {
            width,
            height,
            world_to_ndc: [-sx, sy, cx * sx, -cy * sy + ny],
            scale,
            lane_width: (scale * 0.6).clamp(1.0, 2.5),
        }
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
}

/// A star drawn: its system and its rectangle on screen.
pub struct PlacedStar {
    pub system: usize,
    pub rect: [f32; 4],
}

/// A GUI sprite drawn: its element, sprite, rectangle on screen, and whether its frame has any
/// visible texel.
pub struct PlacedSprite {
    pub path: String,
    pub sprite: String,
    pub rect: [f32; 4],
    pub visible: bool,
}

/// A GUI text drawn: its element, text, font, box and where its pen started.
pub struct PlacedText {
    pub path: String,
    pub text: String,
    pub font: String,
    pub rect: [f32; 4],
    pub pen: (f32, f32),
}

pub struct Scene {
    pub layout: Layout,
    pub batches: Vec<Batch>,
    /// the hyperlanes in map units, their colour and width in pixels
    pub lanes: Vec<[f32; 4]>,
    pub lane_colour: [f32; 4],
    pub clear: [f32; 3],
    pub stars: Vec<PlacedStar>,
    pub sprites: Vec<PlacedSprite>,
    pub texts: Vec<PlacedText>,
}

/// A small deterministic generator for the dust's placement.
struct Rng(u32);
impl Rng {
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        (self.0 >> 8) as f32 / (1u32 << 24) as f32
    }
}

fn sample(img: &Image, u: f32, v: f32) -> [f32; 4] {
    let x = (u.clamp(0.0, 1.0) * (img.width - 1) as f32) as u32;
    let y = (v.clamp(0.0, 1.0) * (img.height - 1) as f32) as u32;
    img.pixel(x, y).map(|c| c as f32 / 255.0)
}

fn push(batches: &mut Vec<Batch>, layer: Layer, blend: Blend, texture: usize, q: Quad) {
    match batches.last_mut() {
        Some(b) if b.layer == layer && b.blend == blend && b.texture == texture => b.quads.push(q),
        _ => batches.push(Batch { layer, blend, texture, quads: vec![q] }),
    }
}

pub struct Inputs<'a> {
    pub galaxy: &'a Galaxy,
    pub borders: &'a Borders,
    pub borders_texture: usize,
    pub topbar: &'a Topbar,
    pub fonts: &'a HashMap<String, Font>,
    pub game_dir: &'a str,
}

pub fn build(inp: &Inputs, tex: &mut Textures, cache: &mut Cache, width: u32, height: u32) -> Scene {
    let g = inp.galaxy;
    let bar_height = 36.0;
    let layout = Layout::fit(g, width, height, bar_height);
    let mut batches = Vec::new();

    // ---- background: dust coloured by the galaxy's colour map, and the centre
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
            let half = size;
            push(&mut batches, Layer::Background, Blend::Add, dust, Quad {
                rect: [x - half, y - half, x + half, y + half],
                uv: [0.0, 0.0, 1.0, 1.0],
                colour: [c[0], c[1], c[2], 0.55],
                rot: rng.next() * std::f32::consts::TAU,
                screen: false,
            });
        }
    }
    if let Some(center) = tex.game(cache, inp.game_dir, "gfx/map/center.dds") {
        let half = radius * 0.55;
        push(&mut batches, Layer::Background, Blend::Add, center, Quad {
            rect: [-half, -half, half, half],
            uv: [0.0, 0.0, 1.0, 1.0],
            colour: [1.0, 1.0, 1.0, 0.9],
            rot: 0.0,
            screen: false,
        });
    }

    // ---- borders: one texture over the galaxy
    let b = inp.borders;
    push(&mut batches, Layer::Borders, Blend::Alpha, inp.borders_texture, Quad {
        rect: b.rect,
        uv: [0.0, 0.0, 1.0, 1.0],
        colour: [1.0; 4],
        rot: 0.0,
        screen: false,
    });

    // ---- lanes
    let lanes = g
        .lanes
        .iter()
        .map(|&(a, b)| {
            let (sa, sb) = (&g.systems[a as usize], &g.systems[b as usize]);
            [sa.x, sa.y, sb.x, sb.y]
        })
        .collect();

    // ---- stars, by texture (one batch per sprite)
    let mut stars = Vec::new();
    let mut order: Vec<usize> = (0..g.systems.len()).collect();
    order.sort_by(|&a, &b| g.systems[a].texture.cmp(&g.systems[b].texture));
    for i in order {
        let s = &g.systems[i];
        let Some(t) = (if s.texture.is_empty() { None } else { tex.game(cache, inp.game_dir, &s.texture) }) else { continue };
        // the sprite's size in map units: 6 x GALAXY_STAR_ICON_SCALE x icon_scale, at least 12 px
        let size = (6.0 * g.star_icon_scale * s.icon_scale).max(12.0 / layout.scale);
        let half = size * 0.5;
        push(&mut batches, Layer::Stars, Blend::Add, t, Quad {
            rect: [s.x - half, s.y - half, s.x + half, s.y + half],
            uv: [0.0, 0.0, 1.0, 1.0],
            colour: [1.0; 4],
            rot: 0.0,
            screen: false,
        });
        let (px, py) = layout.to_pixel(s.x, s.y);
        let hp = half * layout.scale;
        stars.push(PlacedStar { system: i, rect: [px - hp, py - hp, px + hp, py + hp] });
    }

    // ---- the top bar's sprites and texts
    let mut sprites = Vec::new();
    let mut texts = Vec::new();
    for item in &inp.topbar.items {
        match item {
            GuiItem::Sprite { path, sprite, texture, frame, frames, x, y, w, h, border, .. } => {
                let Some(t) = tex.game(cache, inp.game_dir, texture) else { continue };
                let img = tex.images[t].clone();
                let (tw, th) = (img.width as f32, img.height as f32);
                let n = (*frames).max(1) as f32;
                let f = ((*frame).max(1) - 1) as f32;
                let (u0, u1) = (f / n, (f + 1.0) / n);
                let fw = tw / n;
                let visible = {
                    let (a, bx) = ((u0 * tw) as u32, (u1 * tw) as u32);
                    (0..img.height).any(|yy| (a..bx.min(img.width)).any(|xx| img.pixel(xx, yy)[3] > 0))
                };
                let quad = |rect: [f32; 4], uv: [f32; 4]| Quad { rect, uv, colour: [1.0; 4], rot: 0.0, screen: true };
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
                                push(&mut batches, Layer::Gui, Blend::Alpha, t, quad(
                                    [xs[c], ys[r], xs[c + 1], ys[r + 1]],
                                    [us[c], vs[r], us[c + 1], vs[r + 1]],
                                ));
                            }
                        }
                    }
                    _ => push(&mut batches, Layer::Gui, Blend::Alpha, t, quad([*x, *y, x + w, y + h], [u0, 0.0, u1, 1.0])),
                }
                sprites.push(PlacedSprite { path: path.clone(), sprite: sprite.clone(), rect: [*x, *y, x + w, y + h], visible });
            }
            GuiItem::Text { path, font, text, x, y, w, h, format } => {
                let Some(f) = inp.fonts.get(font) else { continue };
                let Some(t) = tex.game(cache, inp.game_dir, &f.texture) else { continue };
                let tw = f.width(text);
                let pen_x = match format.as_str() {
                    "center" | "centre" => x + (w - tw) / 2.0,
                    "right" => x + w - tw,
                    _ => *x,
                }
                .round();
                let pen_y = y.round();
                let (aw, ah) = (f.image.width as f32, f.image.height as f32);
                for (_, r, uv) in f.place(text, pen_x, pen_y) {
                    push(&mut batches, Layer::Text, Blend::Alpha, t, Quad {
                        rect: r,
                        uv: [uv[0] / aw, uv[1] / ah, uv[2] / aw, uv[3] / ah],
                        colour: [1.0; 4],
                        rot: 0.0,
                        screen: true,
                    });
                }
                texts.push(PlacedText {
                    path: path.clone(),
                    text: text.clone(),
                    font: font.clone(),
                    rect: [*x, *y, x + w, y + h],
                    pen: (pen_x, pen_y),
                });
            }
        }
    }

    let hc = g.hyperlane_colour;
    Scene {
        layout,
        batches,
        lanes,
        lane_colour: hc,
        clear: [0.0, 0.0, 0.0],
        stars,
        sprites,
        texts,
    }
}
