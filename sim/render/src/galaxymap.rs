//! The galaxy view's map textures as the game makes them (4.5.2 Linux, read from the code; see
//! docs/render.md section 11), over the save's coordinates -500 .. 500 on both axes (the game's
//! world -1000 .. 1000, `uv = (x + 500) / 1000`, v along the save's y):
//!
//! - terra incognita: the player's 256 x 256 known/unknown bitmap, bilinearly upscaled to
//!   512 x 512 and blurred by bloom.shader's `bloom_alpha` (a Gaussian of sigma 3 texels, as a
//!   centre and four bilinear pairs) (CTerraIncognitaGraphics::UpdateTexture);
//! - borders: each system a ball tagged with its owner (0 unowned, or owned by a country the
//!   player has no communications with) of radius 35 (30 unowned),
//!   each hyperlane between two systems of one tag a line of radius 20, on a 2048 grid
//!   (2.048 cells a unit); a cell's field per tag is the sum of max(0, R^2 / d^2 - 1 / 1.88^2),
//!   the cell goes to the tag with the largest sum above 0.05 (CBorderShapeCalculator); each
//!   owned blob's signed distance to its edge in cells, clamped to +-15 and stored as
//!   (d + 15) / 30 (0.5 on the edge, 0 inside), downsampled x 4 and blurred 3 x 3 (weights 1,
//!   the centre 2, over 10) (CalculateBlobSdf); with the owner's map colours: the edge (primary)
//!   and the fill (secondary).

use crate::dds::Image;
use crate::galaxy::Galaxy;

/// The map textures' size and the save's half extent they cover.
pub const SIZE: usize = 512;
pub const EXTENT: f32 = 500.0;

/// The terra incognita texture (its value in every channel); all known without data.
pub fn terra_incognita(g: &Galaxy) -> Image {
    let Some(ti) = &g.terra_incognita else {
        return Image { width: SIZE as u32, height: SIZE as u32, rgba: vec![255; SIZE * SIZE * 4], format: "generated".into() };
    };
    let n = ti.size;
    let src = |x: i64, y: i64| -> f32 { ti.bitmap[(y.clamp(0, n as i64 - 1) as usize) * n + x.clamp(0, n as i64 - 1) as usize] as f32 };
    // bilinear 256 -> 512 (texel centres)
    let mut up = vec![0f32; SIZE * SIZE];
    let s = n as f32 / SIZE as f32;
    for j in 0..SIZE {
        for i in 0..SIZE {
            let (u, v) = ((i as f32 + 0.5) * s - 0.5, (j as f32 + 0.5) * s - 0.5);
            let (x0, y0) = (u.floor(), v.floor());
            let (fx, fy) = (u - x0, v - y0);
            let (x0, y0) = (x0 as i64, y0 as i64);
            let top = src(x0, y0) * (1.0 - fx) + src(x0 + 1, y0) * fx;
            let bottom = src(x0, y0 + 1) * (1.0 - fx) + src(x0 + 1, y0 + 1) * fx;
            up[j * SIZE + i] = top * (1.0 - fy) + bottom * fy;
        }
    }
    // the blur: bloom_alpha's weights at bilinear offsets, along x then y
    const W0: f32 = 0.13357;
    const W: [f32; 4] = [0.23331, 0.13593, 0.05138, 0.01259];
    const O: [f32; 4] = [1.4584, 3.4040, 5.3518, 7.3029];
    let blur = |img: &[f32], dx: bool| -> Vec<f32> {
        let at = |i: f32, j: usize, k: usize| -> f32 {
            // linear interpolation along the axis at fractional texel i (clamped)
            let i = i.clamp(0.0, (SIZE - 1) as f32);
            let (i0, f) = (i.floor() as usize, i - i.floor());
            let i1 = (i0 + 1).min(SIZE - 1);
            let get = |a: usize| if dx { img[j * SIZE + a] } else { img[a * SIZE + k] };
            get(i0) * (1.0 - f) + get(i1) * f
        };
        let mut out = vec![0f32; SIZE * SIZE];
        for j in 0..SIZE {
            for i in 0..SIZE {
                let (line, pos) = if dx { (j, i) } else { (i, j) };
                let mut v = W0 * at(pos as f32, line, line);
                for k in 0..4 {
                    v += W[k] * (at(pos as f32 + O[k], line, line) + at(pos as f32 - O[k], line, line));
                }
                out[j * SIZE + i] = v;
            }
        }
        out
    };
    let b = blur(&blur(&up, true), false);
    let mut rgba = vec![0u8; SIZE * SIZE * 4];
    for (k, v) in b.iter().enumerate() {
        let c = v.round().clamp(0.0, 255.0) as u8;
        rgba[k * 4..k * 4 + 4].copy_from_slice(&[c, c, c, c]);
    }
    Image { width: SIZE as u32, height: SIZE as u32, rgba, format: "generated".into() }
}

/// The borders' grid: GRID x GRID cells over the map (the game's BORDER_TEXTURE_SIZE).
pub const GRID: usize = 2048;

/// Each cell's owner on the borders' grid (row y = the save's y): -1 none (or unowned), else
/// the country's index.
pub fn owner_grid(g: &Galaxy) -> Vec<i32> {
    let scale = GRID as f32 / (2.0 * EXTENT);
    let cell = |x: f32, y: f32| (((x + EXTENT) * scale).clamp(0.0, (GRID - 1) as f32), ((y + EXTENT) * scale).clamp(0.0, (GRID - 1) as f32));
    // the shapes: (tag, kind, a, b, radius); tag = owner index + 1, 0 unowned
    struct Shape {
        tag: usize,
        a: (f32, f32),
        b: (f32, f32),
        r: f32,
    }
    let tag = |s: &crate::galaxy::System| g.shown_owner(s).map_or(0, |o| o + 1);
    let mut shapes = Vec::new();
    for s in &g.systems {
        let p = cell(s.x, s.y);
        shapes.push(Shape { tag: tag(s), a: p, b: p, r: if tag(s) > 0 { 35.0 } else { 30.0 } });
    }
    for &(a, b) in &g.lanes {
        let (sa, sb) = (&g.systems[a as usize], &g.systems[b as usize]);
        if tag(sa) == tag(sb) {
            shapes.push(Shape { tag: tag(sa), a: cell(sa.x, sa.y), b: cell(sb.x, sb.y), r: 20.0 });
        }
    }
    // buckets of 64 cells, each shape in the buckets its reach (r x 1.88) touches
    const B: usize = 64;
    let nb = GRID / B;
    let mut buckets: Vec<Vec<usize>> = vec![Vec::new(); nb * nb];
    for (k, s) in shapes.iter().enumerate() {
        let reach = s.r * 1.88;
        let (x0, x1) = (s.a.0.min(s.b.0) - reach, s.a.0.max(s.b.0) + reach);
        let (y0, y1) = (s.a.1.min(s.b.1) - reach, s.a.1.max(s.b.1) + reach);
        let bx = |v: f32| ((v / B as f32).floor().max(0.0) as usize).min(nb - 1);
        for by in bx(y0)..=bx(y1) {
            for bxx in bx(x0)..=bx(x1) {
                buckets[by * nb + bxx].push(k);
            }
        }
    }
    let k188 = 1.0 / (1.88 * 1.88);
    // the owner of each cell: -1 none (or unowned), else the country's index
    let mut owner = vec![-1i32; GRID * GRID];
    let mut sums: Vec<(usize, f32)> = Vec::new();
    for y in 0..GRID {
        for x in 0..GRID {
            let list = &buckets[(y / B) * nb + x / B];
            if list.is_empty() {
                continue;
            }
            sums.clear();
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            for &k in list {
                let s = &shapes[k];
                // the distance to the shape's segment
                let (dx, dy) = (s.b.0 - s.a.0, s.b.1 - s.a.1);
                let len2 = dx * dx + dy * dy;
                let t = if len2 > 0.0 { (((px - s.a.0) * dx + (py - s.a.1) * dy) / len2).clamp(0.0, 1.0) } else { 0.0 };
                let (qx, qy) = (s.a.0 + t * dx - px, s.a.1 + t * dy - py);
                let d2 = (qx * qx + qy * qy).max(1e-4);
                let v = s.r * s.r / d2 - k188;
                if v > 0.0 {
                    match sums.iter_mut().find(|e| e.0 == s.tag) {
                        Some(e) => e.1 += v,
                        None => sums.push((s.tag, v)),
                    }
                }
            }
            if let Some(best) = sums.iter().max_by(|a, b| a.1.total_cmp(&b.1)) {
                if best.1 > 0.05 && best.0 > 0 {
                    owner[y * GRID + x] = best.0 as i32 - 1;
                }
            }
        }
    }
    owner
}

/// The border textures from the owner grid (owner_grid): the signed distance (every channel)
/// and the owner's edge and fill colours (sRGB), 512 x 512.
pub fn borders_of(g: &Galaxy, owner: &[i32]) -> (Image, Image, Image) {
    // the signed distance to the blobs' edges (cells, clamped to 15): splatted from the edge
    // cells (an owned cell beside a cell of another owner or none)
    const MAXD: i64 = 15;
    let mut dist = vec![MAXD as f32; GRID * GRID];
    let mut near = vec![-1i32; GRID * GRID];
    for y in 0..GRID as i64 {
        for x in 0..GRID as i64 {
            let o = owner[(y as usize) * GRID + x as usize];
            if o < 0 {
                continue;
            }
            let edge = [(1, 0), (-1, 0), (0, 1), (0, -1)].iter().any(|(dx, dy)| {
                let (nx, ny) = (x + dx, y + dy);
                nx < 0 || ny < 0 || nx >= GRID as i64 || ny >= GRID as i64 || owner[(ny as usize) * GRID + nx as usize] != o
            });
            if !edge {
                continue;
            }
            for dy in -MAXD..=MAXD {
                for dx in -MAXD..=MAXD {
                    let (nx, ny) = (x + dx, y + dy);
                    if nx < 0 || ny < 0 || nx >= GRID as i64 || ny >= GRID as i64 {
                        continue;
                    }
                    // the edge lies half a cell outside the edge cell's centre; a cell of another
                    // blob takes its distance from its own blob's edge
                    let i = (ny as usize) * GRID + nx as usize;
                    let inside = owner[i] == o;
                    if owner[i] >= 0 && !inside {
                        continue;
                    }
                    let d = ((dx * dx + dy * dy) as f32).sqrt();
                    let d = if inside { d + 0.5 } else { (d - 0.5).max(0.0) };
                    if d < dist[i] {
                        dist[i] = d;
                        near[i] = o;
                    }
                }
            }
        }
    }
    // to 512: the average of the 4 x 4 cells, then the 3 x 3 blur
    let f = GRID / SIZE;
    let mut sdf = vec![0f32; SIZE * SIZE];
    let mut own = vec![-1i32; SIZE * SIZE];
    for j in 0..SIZE {
        for i in 0..SIZE {
            let mut acc = 0.0;
            let mut votes: Vec<(i32, u32)> = Vec::new();
            for y in j * f..(j + 1) * f {
                for x in i * f..(i + 1) * f {
                    let k = y * GRID + x;
                    let o = owner[k];
                    let d = if o >= 0 { -dist[k] } else { dist[k] };
                    acc += ((d + 15.0) / 30.0).clamp(0.0, 1.0);
                    let who = if o >= 0 { o } else { near[k] };
                    if who >= 0 {
                        match votes.iter_mut().find(|v| v.0 == who) {
                            Some(v) => v.1 += 1,
                            None => votes.push((who, 1)),
                        }
                    }
                }
            }
            sdf[j * SIZE + i] = acc / (f * f) as f32;
            own[j * SIZE + i] = votes.iter().max_by_key(|v| v.1).map_or(-1, |v| v.0);
        }
    }
    let mut blurred = vec![0f32; SIZE * SIZE];
    for j in 0..SIZE {
        for i in 0..SIZE {
            let mut acc = 0.0;
            for dy in -1i64..=1 {
                for dx in -1i64..=1 {
                    let (x, y) = ((i as i64 + dx).clamp(0, SIZE as i64 - 1) as usize, (j as i64 + dy).clamp(0, SIZE as i64 - 1) as usize);
                    acc += sdf[y * SIZE + x] * if dx == 0 && dy == 0 { 2.0 } else { 1.0 };
                }
            }
            blurred[j * SIZE + i] = acc / 10.0;
        }
    }
    let mut sdf_rgba = vec![0u8; SIZE * SIZE * 4];
    let mut prim = vec![0u8; SIZE * SIZE * 4];
    let mut sec = vec![0u8; SIZE * SIZE * 4];
    let to8 = |v: f32| (v * 255.0).round().clamp(0.0, 255.0) as u8;
    for k in 0..SIZE * SIZE {
        let c = to8(blurred[k]);
        sdf_rgba[k * 4..k * 4 + 4].copy_from_slice(&[c, c, c, c]);
        if own[k] >= 0 {
            let country = &g.countries[own[k] as usize];
            let (p, s) = (country.primary, country.secondary);
            prim[k * 4..k * 4 + 4].copy_from_slice(&[to8(p[0]), to8(p[1]), to8(p[2]), 255]);
            sec[k * 4..k * 4 + 4].copy_from_slice(&[to8(s[0]), to8(s[1]), to8(s[2]), 255]);
        }
    }
    let img = |rgba: Vec<u8>| Image { width: SIZE as u32, height: SIZE as u32, rgba, format: "generated".into() };
    (img(sdf_rgba), img(prim), img(sec))
}
