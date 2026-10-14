//! Checks a rendered frame by reading its PNG back from disk and comparing it with renders of the
//! same scene with one layer left out: what each layer changed, and where.
//! - stars: every star sprite changes pixels inside its rectangle;
//! - lanes: every hyperlane changes the pixel at its middle;
//! - borders: each owner's territory changes the pixels inside it, and its edge band has the
//!   owner's first colour;
//! - GUI: every top bar sprite with visible texels changes pixels inside its rectangle;
//! - texts: the top bar's numbers are read back from the pixels (each glyph of the font matched
//!   against what the text layer drew, by normalised cross-correlation) and compared with the
//!   values the save gives.

use std::collections::HashMap;

use crate::border::Borders;
use crate::font::Font;
use crate::galaxy::Galaxy;
use crate::gui::Topbar;
use crate::scene::{Layer, Layout, Scene, LAYERS};

/// Reads an RGBA8 (or RGB8) PNG.
pub fn read_png(path: &str) -> Result<(u32, u32, Vec<u8>), String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
    let decoder = png::Decoder::new(std::io::BufReader::new(file));
    let mut reader = decoder.read_info().map_err(|e| format!("{path}: {e}"))?;
    let mut buf = vec![0; reader.output_buffer_size().ok_or("png: no buffer size")?];
    let info = reader.next_frame(&mut buf).map_err(|e| format!("{path}: {e}"))?;
    buf.truncate(info.buffer_size());
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf.chunks(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        other => return Err(format!("{path}: colour type {other:?}")),
    };
    Ok((info.width, info.height, rgba))
}

/// Writes RGBA8 pixels as a PNG.
pub fn write_png(path: &str, width: u32, height: u32, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| format!("{path}: {e}"))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| format!("{path}: {e}"))?;
    writer.write_image_data(rgba).map_err(|e| format!("{path}: {e}"))?;
    writer.finish().map_err(|e| format!("{path}: {e}"))?;
    Ok(())
}

impl Layout {
    /// Pixels from the top left -> a map position.
    pub fn to_map(&self, px: f32, py: f32) -> (f32, f32) {
        let nx = px / self.width as f32 * 2.0 - 1.0;
        let ny = 1.0 - py / self.height as f32 * 2.0;
        ((nx - self.world_to_ndc[2]) / self.world_to_ndc[0], (ny - self.world_to_ndc[3]) / self.world_to_ndc[1])
    }
}

/// A frame and the frame without one layer: the difference per pixel (the largest of the three
/// channels, 0..255).
struct Diff<'a> {
    w: u32,
    h: u32,
    full: &'a [u8],
    off: &'a [u8],
}

impl Diff<'_> {
    fn at(&self, x: i32, y: i32) -> u8 {
        if x < 0 || y < 0 || x >= self.w as i32 || y >= self.h as i32 {
            return 0;
        }
        let i = (y as usize * self.w as usize + x as usize) * 4;
        (0..3).map(|c| self.full[i + c].abs_diff(self.off[i + c])).max().unwrap()
    }
    fn changed_in(&self, r: [f32; 4]) -> usize {
        let (x0, y0) = (r[0].floor().max(0.0) as i32, r[1].floor().max(0.0) as i32);
        let (x1, y1) = (r[2].ceil().min(self.w as f32) as i32, r[3].ceil().min(self.h as f32) as i32);
        let mut n = 0;
        for y in y0..y1 {
            for x in x0..x1 {
                if self.at(x, y) > 2 {
                    n += 1;
                }
            }
        }
        n
    }
    fn total(&self) -> usize {
        (0..self.h as i32).map(|y| (0..self.w as i32).filter(|&x| self.at(x, y) > 2).count()).sum()
    }
}

pub struct OwnerCheck {
    pub country: usize,
    /// the territory's pixels, and those the borders layer changed
    pub pixels: usize,
    pub changed: usize,
    /// the fill's pixels; those where the border should show (its colour over what is under it
    /// differs from what is under it), and of those the ones changed; the mean difference
    /// between each pixel and its prediction (0..255)
    pub fill_pixels: usize,
    pub fill_visible: usize,
    pub fill_visible_changed: usize,
    pub fill_error: f32,
    pub edge_pixels: usize,
    /// the edge band's mean colour in the frame, and its distance to the owner's first colour
    pub edge_mean: [f32; 3],
    pub edge_error: f32,
}

pub struct TextCheck {
    pub path: String,
    pub expected: String,
    pub read: String,
    pub score: f32,
    pub source: String,
}

pub struct Check {
    pub width: u32,
    pub height: u32,
    pub changed: Vec<(Layer, usize)>,
    pub stars: usize,
    pub stars_ok: usize,
    pub lanes: usize,
    pub lanes_ok: usize,
    pub owners: Vec<OwnerCheck>,
    pub sprites: usize,
    pub sprites_visible: usize,
    pub sprites_ok: usize,
    pub sprites_missing: Vec<String>,
    pub texts: Vec<TextCheck>,
}

impl Check {
    /// Whether everything was drawn (the lanes only if `lanes` is set).
    pub fn ok(&self, lanes: bool) -> bool {
        self.stars_ok == self.stars
            && (!lanes || self.lanes_ok == self.lanes)
            // (the owners of fleets alone have no territory)
            && self.owners.iter().filter(|o| o.pixels > 0).all(|o| {
                o.fill_visible_changed * 100 >= o.fill_visible * 98 && o.fill_error < 3.0 && o.edge_error < 40.0
            })
            && self.sprites_ok == self.sprites_visible
            && self.texts.iter().all(|t| t.read == t.expected)
    }
}

/// The characters the top bar's numbers are made of.
const CHARSET: &str = "0123456789.,KM-+/";

/// The printable ASCII characters a font has (for reading words).
pub fn printable(font: &Font) -> Vec<char> {
    (33u8..=126).map(char::from).filter(|c| font.glyphs.contains_key(c)).collect()
}

/// Reads the text the text layer drew in a box: the glyphs of `font` (those of `charset`, and
/// spaces where a space's advance has no ink) matched left to right against the difference the
/// layer made, starting where its first ink is.
fn read_text(font: &Font, diff: &Diff, rect: [f32; 4], top: f32, charset: &[char]) -> (String, f32) {
    let (x0, x1) = (rect[0].floor() as i32 - 6, rect[2].ceil() as i32 + 6);
    let (y0, y1) = (top as i32, (top + font.line_height) as i32 + 2);
    let ink = |x: i32| (y0..y1).any(|y| diff.at(x, y) > 40);
    let Some(left) = (x0..x1).find(|&x| ink(x)) else { return (String::new(), 0.0) };
    let right = (x0..x1).rev().find(|&x| ink(x)).unwrap();
    let atlas = &font.image;
    let alpha = |gx: i32, gy: i32| -> f32 {
        if gx < 0 || gy < 0 || gx >= atlas.width as i32 || gy >= atlas.height as i32 {
            0.0
        } else {
            atlas.pixel(gx as u32, gy as u32)[3] as f32 / 255.0
        }
    };
    // the glyph's ink's first column, from its pen position
    let ink_left = |c: char| -> Option<f32> {
        let g = font.glyphs.get(&c)?;
        (0..g.width as i32).find(|&dx| (0..g.height as i32).any(|dy| alpha(g.x as i32 + dx, g.y as i32 + dy) > 0.3)).map(|dx| g.xoffset + dx as f32)
    };
    // the match of glyph c with its pen at `pen`: the columns of its advance only (the glyph
    // cells overlap their neighbours by the font's padding)
    let score = |c: char, pen: f32| -> f32 {
        let Some(g) = font.glyphs.get(&c) else { return -1.0 };
        let (mut m, mut d) = (Vec::new(), Vec::new());
        for dy in 0..g.height as i32 {
            for dx in 0..g.width as i32 {
                let sx = (pen + g.xoffset) as i32 + dx;
                if (sx as f32) < pen || (sx as f32) >= pen + g.xadvance {
                    continue;
                }
                m.push(alpha(g.x as i32 + dx, g.y as i32 + dy));
                d.push(diff.at(sx, (top + g.yoffset) as i32 + dy) as f32 / 255.0);
            }
        }
        let n = m.len() as f32;
        if n == 0.0 {
            return -1.0;
        }
        let (mm, dm) = (m.iter().sum::<f32>() / n, d.iter().sum::<f32>() / n);
        let (mut num, mut sm, mut sd) = (0.0, 0.0, 0.0);
        for (a, b) in m.iter().zip(&d) {
            num += (a - mm) * (b - dm);
            sm += (a - mm) * (a - mm);
            sd += (b - dm) * (b - dm);
        }
        if sm <= 0.0 || sd <= 0.0 {
            return 0.0;
        }
        num / (sm * sd).sqrt()
    };
    let space = font.glyphs.get(&' ').map_or(0.0, |g| g.xadvance);
    let no_ink = |a: f32, b: f32| (a.ceil() as i32..b.floor() as i32).all(|x| !ink(x));
    // one reading per possible start of the pen (the first ink less a glyph's ink offset); the
    // best is the one that covers the ink, then the one that matches best
    // (and the pixels either side: the first ink column is antialiased)
    let mut starts: Vec<f32> = charset
        .iter()
        .filter_map(|&c| ink_left(c))
        .flat_map(|il| {
            let s = (left as f32 - il).round();
            [s - 1.0, s, s + 1.0]
        })
        .collect();
    starts.sort_by(f32::total_cmp);
    starts.dedup();
    // the line's region (down to the lowest glyph cell: descenders count), and what the text
    // layer drew there (0..1)
    let (rx0, rx1) = (x0 - 8, x1 + 8);
    let bottom = font.glyphs.values().map(|g| g.yoffset + g.height).fold(font.line_height, f32::max);
    let (ry0, ry1) = (y0 - 2, (top + bottom) as i32 + 2);
    let (rw, rh) = ((rx1 - rx0) as usize, (ry1 - ry0) as usize);
    let actual: Vec<f32> = (0..rh).flat_map(|j| (0..rw).map(move |i| (i, j))).map(|(i, j)| diff.at(rx0 + i as i32, ry0 + j as i32) as f32 / 255.0).collect();
    // a glyph drawn into a mask of the region (the brighter of the two where glyphs overlap)
    let stamp = |mask: &mut Vec<f32>, c: char, pen: f32| {
        let Some(g) = font.glyphs.get(&c) else { return };
        for dy in 0..g.height as i32 {
            for dx in 0..g.width as i32 {
                let (sx, sy) = ((pen + g.xoffset) as i32 + dx - rx0, (top + g.yoffset) as i32 + dy - ry0);
                if sx >= 0 && sy >= 0 && (sx as usize) < rw && (sy as usize) < rh {
                    let k = sy as usize * rw + sx as usize;
                    mask[k] = mask[k].max(alpha(g.x as i32 + dx, g.y as i32 + dy));
                }
            }
        }
    };
    // how well a mask matches what was drawn, over the columns up to `to`
    let global = |mask: &Vec<f32>, to: i32| -> f32 {
        let cols = ((to - rx0).clamp(1, rw as i32)) as usize;
        let n = (cols * rh) as f32;
        let (mut sm, mut sd) = (0.0, 0.0);
        for j in 0..rh {
            for i in 0..cols {
                sm += mask[j * rw + i];
                sd += actual[j * rw + i];
            }
        }
        let (mm, dm) = (sm / n, sd / n);
        let (mut num, mut vm, mut vd) = (0.0, 0.0, 0.0);
        for j in 0..rh {
            for i in 0..cols {
                let (a, b) = (mask[j * rw + i] - mm, actual[j * rw + i] - dm);
                num += a * b;
                vm += a * a;
                vd += b * b;
            }
        }
        if vm <= 0.0 || vd <= 0.0 {
            0.0
        } else {
            num / (vm * vd).sqrt()
        }
    };
    // a beam search: readings extended glyph by glyph (the few that match best locally, or a
    // space where a space's advance has no ink), kept by how well the whole reading so far
    // matches what was drawn
    // wide enough that a reading started a pixel off (whose glyphs then fit shifted twins, such
    // as q for o) does not push the right one out
    const BEAM: usize = 32;
    let mut beam: Vec<(f32, f32, String, Vec<f32>)> = starts.iter().map(|&s| (0.0, s, String::new(), vec![0.0; rw * rh])).collect();
    let mut finished: Vec<(f32, String)> = Vec::new();
    for _ in 0..64 {
        let mut next: Vec<(f32, f32, String, Vec<f32>)> = Vec::new();
        for (_, pen, text, mask) in &beam {
            if *pen >= right as f32 - 1.0 {
                finished.push((global(mask, right + 3), text.trim_end().to_string()));
                continue;
            }
            if space > 1.0 && !text.is_empty() && no_ink(*pen, pen + space) {
                let p = pen + space;
                next.push((global(mask, p as i32), p, format!("{text} "), mask.clone()));
            }
            // the pen moves by the kerning of the previous glyph and this one, as when drawn
            let prev = text.chars().last();
            let kern = |c: char| prev.and_then(|p| font.kerning.get(&(p, c))).copied().unwrap_or(0.0);
            let mut local: Vec<(f32, char)> =
                charset.iter().map(|&c| (score(c, pen + kern(c)), c)).filter(|(s, _)| *s >= 0.25).collect();
            local.sort_by(|a, b| b.0.total_cmp(&a.0));
            for &(_, c) in local.iter().take(12) {
                let mut m = mask.clone();
                let at = pen + kern(c);
                stamp(&mut m, c, at);
                let p = at + font.glyphs[&c].xadvance;
                next.push((global(&m, p as i32), p, format!("{text}{c}"), m));
            }
        }
        if next.is_empty() {
            break;
        }
        next.sort_by(|a, b| b.0.total_cmp(&a.0));
        next.truncate(BEAM);
        beam = next;
    }
    finished.sort_by(|a, b| b.0.total_cmp(&a.0));
    finished.into_iter().next().map(|(s, t)| (t, s)).unwrap_or_default()
}

/// What the GUI check of a front end screen found.
pub struct GuiCheck {
    pub width: u32,
    pub height: u32,
    pub changed: Vec<(Layer, usize)>,
    pub sprites: usize,
    pub sprites_visible: usize,
    pub sprites_ok: usize,
    pub sprites_missing: Vec<String>,
    pub buttons: usize,
    pub texts: Vec<TextCheck>,
    /// texts under a sprite drawn after them (not read)
    pub covered: Vec<String>,
}

impl GuiCheck {
    pub fn ok(&self) -> bool {
        self.sprites_ok == self.sprites_visible && self.texts.iter().all(|t| t.read == t.expected)
    }
}

/// Checks a GUI screen's PNG read back from disk: every sprite with visible texels changes pixels
/// inside its rectangle (against the frame without the GUI layer), and every text is read back
/// from the pixels (its font's printable glyphs, against the frame without the text layer) and
/// compared with the text laid out (the localised text).
pub fn check_gui(path: &str, frames: &Frames, scene: &Scene, fonts: &HashMap<String, Font>) -> Result<GuiCheck, String> {
    let (w, h, full) = read_png(path)?;
    if (w, h) != (frames.width, frames.height) {
        return Err(format!("{path}: {w}x{h}, rendered {}x{}", frames.width, frames.height));
    }
    let diff = |l: Layer| Diff { w, h, full: &full, off: &frames.without[&l] };
    let changed = LAYERS.iter().map(|&l| (l, diff(l).total())).collect();
    let dg = diff(Layer::Gui);
    let (mut visible, mut ok, mut missing) = (0, 0, Vec::new());
    for s in &scene.sprites {
        if !s.visible {
            continue;
        }
        visible += 1;
        if dg.changed_in(s.rect) > 0 {
            ok += 1;
        } else {
            missing.push(format!("{} ({})", s.path, s.sprite));
        }
    }
    let dt = diff(Layer::Text);
    let mut texts = Vec::new();
    let mut covered = Vec::new();
    for p in &scene.texts {
        let Some(font) = fonts.get(&p.font) else { continue };
        if p.text.trim().is_empty() {
            continue;
        }
        // a text under a sprite drawn after it (a window open over the menu) is not read
        let over = |r: [f32; 4], s: [f32; 4]| r[0] < s[2] && s[0] < r[2] && r[1] < s[3] && s[1] < r[3];
        if scene.sprites.iter().any(|s| s.visible && s.order > p.order && over(p.rect, s.rect)) {
            covered.push(p.path.clone());
            continue;
        }
        let (read, score) = read_text(font, &dt, p.rect, p.pen.1, &printable(font));
        texts.push(TextCheck { path: p.path.clone(), expected: p.text.trim().to_string(), read, score, source: p.font.clone() });
    }
    Ok(GuiCheck {
        width: w,
        height: h,
        changed,
        sprites: scene.sprites.len(),
        sprites_visible: visible,
        sprites_ok: ok,
        sprites_missing: missing,
        buttons: scene.buttons.len(),
        texts,
        covered,
    })
}

pub struct Frames<'a> {
    pub width: u32,
    pub height: u32,
    /// the renders without one layer each
    pub without: &'a HashMap<Layer, Vec<u8>>,
}

pub fn check(
    path: &str,
    frames: &Frames,
    scene: &Scene,
    galaxy: &Galaxy,
    borders: &Borders,
    bar: &Topbar,
    fonts: &HashMap<String, Font>,
) -> Result<Check, String> {
    let (w, h, full) = read_png(path)?;
    if (w, h) != (frames.width, frames.height) {
        return Err(format!("{path}: {w}x{h}, rendered {}x{}", frames.width, frames.height));
    }
    let diff = |l: Layer| Diff { w, h, full: &full, off: &frames.without[&l] };
    let changed = LAYERS.iter().map(|&l| (l, diff(l).total())).collect();
    let layout = &scene.layout;

    // stars
    let ds = diff(Layer::Stars);
    let stars_ok = scene.stars.iter().filter(|s| ds.changed_in(s.rect) > 0).count();

    // lanes, at their middle
    let dl = diff(Layer::Lanes);
    let mut lanes_ok = 0;
    // (the hyperlanes are the scene's first lines; the fleets' trails follow)
    for l in scene.lines.iter().take(galaxy.lanes.len()) {
        let (mx, my) = layout.to_pixel(0.5 * (l.a.0 + l.b.0), 0.5 * (l.a.2 + l.b.2));
        if (-1..=1).any(|dy| (-1..=1).any(|dx| dl.at(mx as i32 + dx, my as i32 + dy) > 0)) {
            lanes_ok += 1;
        }
    }

    // borders: the pixels each owner's territory covers (its texels' distance > 1.5 texels); in
    // its fill (past the edge band), what each pixel should be: the border texture's colour over
    // the frame without the borders
    let db = diff(Layer::Borders);
    let under = &frames.without[&Layer::Borders];
    let mut owners: Vec<OwnerCheck> = (0..galaxy.countries.len())
        .map(|c| OwnerCheck {
            country: c,
            pixels: 0,
            changed: 0,
            fill_pixels: 0,
            fill_visible: 0,
            fill_visible_changed: 0,
            fill_error: 0.0,
            edge_pixels: 0,
            edge_mean: [0.0; 3],
            edge_error: 0.0,
        })
        .collect();
    let top_bar = 40;
    for y in top_bar..h as i32 {
        for x in 0..w as i32 {
            let (mx, my) = layout.to_map(x as f32 + 0.5, y as f32 + 0.5);
            let Some(t) = borders.texel_at(mx, my) else { continue };
            let o = borders.owner[t];
            let d = borders.dist[t];
            if o == 0 || d < borders.texel * 1.5 {
                continue;
            }
            let oc = &mut owners[o as usize - 1];
            oc.pixels += 1;
            if db.at(x, y) > 2 {
                oc.changed += 1;
            }
            let i = (y as usize * w as usize + x as usize) * 4;
            if d > crate::border::EDGE + 3.0 * borders.texel && dl.at(x, y) == 0 && ds.at(x, y) == 0 {
                let s = borders.sample(mx, my);
                let a = s[3] / 255.0;
                let mut err = 0f32;
                let mut visible = 0f32;
                for c in 0..3 {
                    let predicted = s[c] * a + under[i + c] as f32 * (1.0 - a);
                    err = err.max((predicted - full[i + c] as f32).abs());
                    visible = visible.max((predicted - under[i + c] as f32).abs());
                }
                oc.fill_pixels += 1;
                oc.fill_error += err;
                if visible > 4.0 {
                    oc.fill_visible += 1;
                    if db.at(x, y) > 2 {
                        oc.fill_visible_changed += 1;
                    }
                }
            }
            // the edge band, inside the darker line, where no lane or star is drawn over it
            if d > 1.0 && d < 1.7 && dl.at(x, y) == 0 && ds.at(x, y) == 0 {
                for c in 0..3 {
                    oc.edge_mean[c] += full[i + c] as f32;
                }
                oc.edge_pixels += 1;
            }
        }
    }
    for oc in &mut owners {
        if oc.fill_pixels > 0 {
            oc.fill_error /= oc.fill_pixels as f32;
        }
        if oc.edge_pixels > 0 {
            for c in 0..3 {
                oc.edge_mean[c] /= oc.edge_pixels as f32;
            }
            let p = galaxy.countries[oc.country].primary;
            // the band is the first colour at 90% over what is under it
            oc.edge_error = (0..3).map(|c| (oc.edge_mean[c] - p[c] * 255.0 * 0.9).abs()).fold(0.0, f32::max);
        } else {
            oc.edge_error = f32::INFINITY;
        }
    }

    // GUI sprites
    let dg = diff(Layer::Gui);
    let mut sprites_ok = 0;
    let mut sprites_missing = Vec::new();
    let mut sprites_visible = 0;
    for s in &scene.sprites {
        if !s.visible {
            continue;
        }
        sprites_visible += 1;
        if dg.changed_in(s.rect) > 0 {
            sprites_ok += 1;
        } else {
            sprites_missing.push(format!("{} ({})", s.path, s.sprite));
        }
    }

    // texts bound to the save, read back
    let dt = diff(Layer::Text);
    let mut texts = Vec::new();
    for b in &bar.bound {
        let Some(p) = scene.texts.iter().find(|t| t.path == b.path) else { continue };
        let Some(font) = fonts.get(&p.font) else { continue };
        let charset: Vec<char> = CHARSET.chars().collect();
        let (read, score) = read_text(font, &dt, p.rect, p.pen.1, &charset);
        texts.push(TextCheck { path: b.path.clone(), expected: b.text.clone(), read, score, source: b.source.clone() });
    }

    Ok(Check {
        width: w,
        height: h,
        changed,
        stars: scene.stars.len(),
        stars_ok,
        lanes: galaxy.lanes.len(),
        lanes_ok,
        owners,
        sprites: scene.sprites.len(),
        sprites_visible,
        sprites_ok,
        sprites_missing,
        texts,
    })
}
