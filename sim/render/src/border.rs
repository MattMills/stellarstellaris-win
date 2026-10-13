//! Country borders: each owner's territory around its systems, as a texture over the galaxy in
//! map space (BORDER_TEXTURE_SIZE texels on its long side, as the game's border data texture).
//!
//! A point belongs to the owner of the nearest owned system when that system is within
//! BORDER_SYSTEM_RADIUS (a Voronoi diagram of the owned systems, clipped to discs; unowned systems
//! do not cut it). Each texel keeps its signed distance to the territory's edge, in map units:
//! the smaller of the distance to the disc's rim and to the bisector with the nearest system of
//! another owner. It is shaded the way the game's border shader (gfx/FX/border.shader,
//! PixelShaderSDF) does: the owner's first colour as a saturated band at the edge with a darker
//! line at its outside, the second colour as a soft fill that grows denser toward the edge.

use crate::galaxy::Galaxy;

pub struct Borders {
    pub width: u32,
    pub height: u32,
    /// RGBA8, straight alpha; texel (i, j) covers map x0 + i * texel .. , y0 + j * texel ..
    pub rgba: Vec<u8>,
    /// the map rectangle covered: x0, y0, x1, y1
    pub rect: [f32; 4],
    pub texel: f32,
    /// per texel: the owner's index in Galaxy::countries + 1 (0: none), and the distance to the
    /// territory's edge (map units, > 0 inside)
    pub owner: Vec<u16>,
    pub dist: Vec<f32>,
}

impl Borders {
    /// The texture's colour at a map position, filtered as the GPU does (bilinear between texel
    /// centres, clamped at the sides): RGBA, 0..255.
    pub fn sample(&self, x: f32, y: f32) -> [f32; 4] {
        let u = ((x - self.rect[0]) / self.texel - 0.5).clamp(0.0, (self.width - 1) as f32);
        let v = ((y - self.rect[1]) / self.texel - 0.5).clamp(0.0, (self.height - 1) as f32);
        let (i0, j0) = (u.floor() as usize, v.floor() as usize);
        let (i1, j1) = ((i0 + 1).min(self.width as usize - 1), (j0 + 1).min(self.height as usize - 1));
        let (fu, fv) = (u - i0 as f32, v - j0 as f32);
        let at = |i: usize, j: usize, c: usize| self.rgba[(j * self.width as usize + i) * 4 + c] as f32;
        let mut out = [0f32; 4];
        for (c, o) in out.iter_mut().enumerate() {
            let top = at(i0, j0, c) * (1.0 - fu) + at(i1, j0, c) * fu;
            let bottom = at(i0, j1, c) * (1.0 - fu) + at(i1, j1, c) * fu;
            *o = top * (1.0 - fv) + bottom * fv;
        }
        out
    }

    /// The texel at a map position, if inside.
    pub fn texel_at(&self, x: f32, y: f32) -> Option<usize> {
        let i = ((x - self.rect[0]) / self.texel).floor();
        let j = ((y - self.rect[1]) / self.texel).floor();
        if i < 0.0 || j < 0.0 || i >= self.width as f32 || j >= self.height as f32 {
            return None;
        }
        Some(j as usize * self.width as usize + i as usize)
    }
}

/// The edge band's width and the darker line's, in map units.
pub const EDGE: f32 = 2.2;
pub const DARK_LINE: f32 = 0.6;

pub fn compute(g: &Galaxy) -> Borders {
    let radius = g.border_system_radius.max(1.0);
    let owned: Vec<(f32, f32, usize)> = g.systems.iter().filter_map(|s| s.owner.map(|o| (s.x, s.y, o))).collect();
    let (mut x0, mut y0, mut x1, mut y1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for s in &g.systems {
        x0 = x0.min(s.x);
        y0 = y0.min(s.y);
        x1 = x1.max(s.x);
        y1 = y1.max(s.y);
    }
    if g.systems.is_empty() {
        (x0, y0, x1, y1) = (-1.0, -1.0, 1.0, 1.0);
    }
    let pad = radius + 2.0;
    let (x0, y0, x1, y1) = (x0 - pad, y0 - pad, x1 + pad, y1 + pad);
    let size = g.border_texture_size.clamp(64, 4096) as f32;
    let texel = (x1 - x0).max(y1 - y0) / size;
    let (w, h) = (((x1 - x0) / texel).ceil() as u32, ((y1 - y0) / texel).ceil() as u32);

    // the owned systems in a grid of cells of `radius`
    let cell = radius;
    let (cw, ch) = (((x1 - x0) / cell).ceil() as i32 + 1, ((y1 - y0) / cell).ceil() as i32 + 1);
    let mut grid: Vec<Vec<usize>> = vec![Vec::new(); (cw * ch) as usize];
    for (k, &(x, y, _)) in owned.iter().enumerate() {
        let (cx, cy) = (((x - x0) / cell) as i32, ((y - y0) / cell) as i32);
        grid[(cy * cw + cx) as usize].push(k);
    }

    let n = (w * h) as usize;
    let mut rgba = vec![0u8; n * 4];
    let mut owner = vec![0u16; n];
    let mut dist = vec![f32::MIN; n];
    let mut near: Vec<(usize, f32)> = Vec::with_capacity(32);
    for j in 0..h {
        let py = y0 + (j as f32 + 0.5) * texel;
        let cy = ((py - y0) / cell) as i32;
        for i in 0..w {
            let px = x0 + (i as f32 + 0.5) * texel;
            let cx = ((px - x0) / cell) as i32;
            // the systems within two radii: the nearest owns the texel if within one, and the
            // bisectors with systems up to two radii away can still be nearer than the rim
            near.clear();
            for gy in (cy - 2).max(0)..=(cy + 2).min(ch - 1) {
                for gx in (cx - 2).max(0)..=(cx + 2).min(cw - 1) {
                    for &k in &grid[(gy * cw + gx) as usize] {
                        let (sx, sy, _) = owned[k];
                        let d2 = (px - sx).powi(2) + (py - sy).powi(2);
                        if d2 <= (radius + 2.0 * texel).powi(2) * 4.0 {
                            near.push((k, d2));
                        }
                    }
                }
            }
            let Some(&(a, da2)) = near.iter().min_by(|p, q| p.1.total_cmp(&q.1)) else { continue };
            let (ax, ay, o) = owned[a];
            let da = da2.sqrt();
            let mut d = radius - da;
            for &(c, dc2) in &near {
                let (cxs, cys, oc) = owned[c];
                if oc != o {
                    let ac = ((ax - cxs).powi(2) + (ay - cys).powi(2)).sqrt().max(1e-3);
                    d = d.min((dc2 - da2) / (2.0 * ac));
                }
            }
            let t = (j * w + i) as usize;
            dist[t] = d;
            let coverage = (d / texel + 0.5).clamp(0.0, 1.0);
            if coverage <= 0.0 {
                continue;
            }
            owner[t] = o as u16 + 1;
            let c = &g.countries[o];
            // the edge band in the first colour, the fill in the second
            let edge = ((EDGE - d) / texel + 0.5).clamp(0.0, 1.0);
            let mut col = [0f32; 3];
            for k in 0..3 {
                col[k] = c.primary[k] * edge + c.secondary[k] * (1.0 - edge);
            }
            // a darker line at the very outside of the edge
            let dark = ((DARK_LINE - d) / texel + 0.5).clamp(0.0, 1.0);
            for v in &mut col {
                *v *= 1.0 - 0.35 * dark;
            }
            // the fill grows denser toward the edge
            let fill = 0.22 + 0.2 * (1.0 - (d / (radius * 0.6)).clamp(0.0, 1.0));
            let alpha = (edge * 0.9 + (1.0 - edge) * fill) * coverage;
            rgba[t * 4] = (col[0] * 255.0).round() as u8;
            rgba[t * 4 + 1] = (col[1] * 255.0).round() as u8;
            rgba[t * 4 + 2] = (col[2] * 255.0).round() as u8;
            rgba[t * 4 + 3] = (alpha * 255.0).round() as u8;
        }
    }
    Borders { width: w, height: h, rgba, rect: [x0, y0, x0 + w as f32 * texel, y0 + h as f32 * texel], texel, owner, dist }
}
