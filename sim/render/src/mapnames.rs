//! The galaxy map's names and flags as the game places them (4.5.2 Linux, read from the code;
//! docs/render.md section 11), in map units (the game's world / 2):
//!
//! - each owned blob of the borders' grid (galaxymap::owner_grid; 4-connected cells of one owner)
//!   whose largest square of its own cells is at least BORDER_MIN_SIZE_FOR_SYMBOL (16) cells gets
//!   a symbol quad, that square (CBorderBlobCalculator::GetCentroidQuads); the country's flag is
//!   the quad scaled by BORDER_FLAG_SCALE (0.6) about its centre (CBordersGraphics::
//!   CalculateCentroids), its name below it at the centre + 0.75 x the quad's half size +
//!   4 of the game's world (MAPNAME_BORDER_OFFSET_MUL, _ADD), as wide as 0.2 x min(letters, 10)
//!   x s, s the half width of the owner's cells along the name's row from the name's point
//!   (at least MAPNAME_BORDER_MIN_SIZE / 2) (GenerateBorderNames);
//! - each sector of the player has its name at its capital's system, 3 x its letters of the
//!   game's world wide (MAPNAME_SECTOR_SCALE; GenerateSectorNames);
//! - the names lie flat on the plane, their x along the world's -x and their lines down along
//!   +z, centred on their point (AddName, CBitmapFont::FillVertexBuffer: a name's width is its
//!   scale x its size); drawn by mapname.shader in the font's colour at alpha 0.25 x the
//!   opacity; the empire names and flags show from BORDER_NAMES_FADEOUT_ZOOM (600 of the game's
//!   world) out, the sector names closer in (CGraphicalMap::Render); the flags by
//!   border.shader's PixelShaderCentroid at alpha 0.65 x the fade.

use crate::galaxymap::{EXTENT, GRID};

/// BORDER_MIN_SIZE_FOR_SYMBOL: a blob's largest square of cells to have a symbol.
const MIN_SQUARE: u16 = 16;
/// BORDER_FLAG_SCALE
pub const FLAG_SCALE: f32 = 0.6;
/// MAPNAME_BORDER_OFFSET_MUL, MAPNAME_BORDER_OFFSET_ADD (the game's world)
const OFFSET_MUL: f32 = 0.75;
const OFFSET_ADD: f32 = 4.0;
/// MAPNAME_BORDER_MIN_SIZE (the game's world)
const BORDER_MIN_SIZE: f32 = 100.0;
/// MAPNAME_BORDER_SCALE, MAPNAME_SECTOR_SCALE
const BORDER_SCALE: f32 = 1.0;
const SECTOR_SCALE: f32 = 3.0;
/// BORDER_NAMES_FADEOUT_ZOOM (and BORDER_FLAG_FADEOUT_ZOOM): the game's world
pub const FADEOUT_ZOOM: f32 = 600.0;
/// mapname.shader's alpha, border.shader's flag alpha
pub const NAME_ALPHA: f32 = 0.25;
pub const FLAG_ALPHA: f32 = 0.65;

/// An owned blob with a symbol: its owner (the country's index), its square's centre and half
/// size, and where its name goes and the half width the name scales by (map units).
#[derive(Clone, Debug)]
pub struct Blob {
    pub owner: usize,
    pub x: f32,
    pub y: f32,
    pub half: f32,
    pub name_y: f32,
    pub span: f32,
}

impl Blob {
    /// The flag's rectangle (x0, y0, x1, y1): x0 > x1, so that the texture's left lies at the
    /// screen's left from the default camera (border.shader samples -u)
    pub fn flag_rect(&self) -> [f32; 4] {
        let h = self.half * FLAG_SCALE;
        [self.x + h, self.y - h, self.x - h, self.y + h]
    }

    /// The width of its name `text` (map units).
    pub fn name_width(&self, text: &str) -> f32 {
        // the size in the game's world: s x 0.2 x min(letters, 10), s = 2 x span
        BORDER_SCALE * 2.0 * self.span * 0.2 * (text.len().min(10) as f32) / 2.0
    }
}

/// The width of a sector's name (map units).
pub fn sector_name_width(text: &str) -> f32 {
    SECTOR_SCALE * text.len() as f32 / 2.0
}

fn find(parent: &mut [u32], mut i: u32) -> u32 {
    while parent[i as usize] != i {
        let p = parent[parent[i as usize] as usize];
        parent[i as usize] = p;
        i = p;
    }
    i
}

/// The blobs with a symbol, from the owner grid (galaxymap::owner_grid).
pub fn blobs(owner: &[i32]) -> Vec<Blob> {
    let n = GRID;
    let cell = 2.0 * EXTENT / n as f32;
    let to_map = |t: f32| t * cell - EXTENT;
    // the blobs: 4-connected cells of one owner
    let mut parent: Vec<u32> = (0..(n * n) as u32).collect();
    for y in 0..n {
        for x in 0..n {
            let i = y * n + x;
            let o = owner[i];
            if o < 0 {
                continue;
            }
            for j in [if x > 0 { Some(i - 1) } else { None }, if y > 0 { Some(i - n) } else { None }].into_iter().flatten() {
                if owner[j] == o {
                    let (a, b) = (find(&mut parent, i as u32), find(&mut parent, j as u32));
                    if a != b {
                        parent[a.max(b) as usize] = a.min(b);
                    }
                }
            }
        }
    }
    // the largest square of one owner's cells ending at each cell, the largest per blob (the
    // first in row order)
    let mut sq = vec![0u16; n * n];
    let mut best: std::collections::HashMap<u32, (u16, usize)> = std::collections::HashMap::new();
    for y in 0..n {
        for x in 0..n {
            let i = y * n + x;
            let o = owner[i];
            if o < 0 {
                continue;
            }
            let s = if x > 0 && y > 0 && owner[i - 1] == o && owner[i - n] == o && owner[i - n - 1] == o {
                1 + sq[i - 1].min(sq[i - n]).min(sq[i - n - 1])
            } else {
                1
            };
            sq[i] = s;
            let r = find(&mut parent, i as u32);
            let e = best.entry(r).or_insert((0, i));
            if s > e.0 {
                *e = (s, i);
            }
        }
    }
    let mut roots: Vec<(u32, (u16, usize))> = best.into_iter().filter(|(_, (s, _))| *s >= MIN_SQUARE).collect();
    roots.sort_by_key(|(r, _)| *r);
    roots
        .into_iter()
        .map(|(_, (s, i))| {
            let (px, py) = ((i % n) as f32, (i / n) as f32);
            let s = s as f32;
            // the square spans cells p + 1 - s .. p + 1
            let (x, y) = (to_map(px + 1.0 - s / 2.0), to_map(py + 1.0 - s / 2.0));
            let half = s / 2.0 * cell;
            let name_y = y + (OFFSET_MUL * half * 2.0 + OFFSET_ADD) / 2.0;
            // the owner's cells to both sides along the name's row, from at least half the minimum
            // size (the cell under the name may be another owner's: its own cells are counted)
            let tx = (((x + EXTENT) / cell) as i64).clamp(0, n as i64 - 1);
            let ty = (((name_y + EXTENT) / cell) as i64).clamp(0, n as i64 - 1);
            let id = |cx: i64| owner[(ty as usize) * n + cx as usize];
            let c = id(tx);
            let r0 = (BORDER_MIN_SIZE * 0.5 / 2.0 / cell) as i64;
            let mut span = BORDER_MIN_SIZE * 0.5 / 2.0;
            for r in r0..n as i64 {
                if tx - r < 0 || tx + r >= n as i64 || id(tx - r) != c || id(tx + r) != c {
                    span = r as f32 * cell;
                    break;
                }
            }
            Blob { owner: owner[i] as usize, x, y, half, name_y, span }
        })
        .collect()
}

/// The fonts map_name_border, map_name_sector (interface/fonts.gfx: gfx/fonts/orbitron in
/// English), under this name in the renderer's fonts.
pub const FONT: &str = "map_name";
pub const FONT_FILE: &str = "gfx/fonts/orbitron";

/// The map's names, localised: the blobs with their country's name, and the player's sectors'
/// names at their capitals (map units).
#[derive(Clone, Debug, Default)]
pub struct MapNames {
    pub blobs: Vec<Blob>,
    pub empires: Vec<String>,
    pub sectors: Vec<(String, f32, f32)>,
}

/// A name's glyphs on the plane, `width` wide, centred on (x, y): each glyph's rectangle (map
/// units; its texture's left at the larger x, the world's -x being the screen's right from the
/// default camera, and its top at the smaller y) and its rectangle in the font's page (0..1).
/// Centred on the line's height with the font's padding above and below **[I]** (FitTextInternal
/// not read: against the game's frames that centring is within a pixel, the line's alone 5 to 6
/// of the font's pixels low).
pub fn text_quads(font: &crate::font::Font, text: &str, x: f32, y: f32, width: f32) -> Vec<([f32; 4], [f32; 4])> {
    let w = font.width(text);
    if w <= 0.0 {
        return Vec::new();
    }
    let k = width / w;
    let (pw, ph) = (font.image.width as f32, font.image.height as f32);
    let h = font.line_height + font.padding[0] + font.padding[2];
    font.place(text, -w / 2.0, -h / 2.0)
        .into_iter()
        .map(|(_, r, t)| ([x - r[0] * k, y + r[1] * k, x - r[2] * k, y + r[3] * k], [t[0] / pw, t[1] / ph, t[2] / pw, t[3] / ph]))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_square_blob_and_one_too_small() {
        let n = GRID;
        let mut owner = vec![-1i32; n * n];
        // country 3: cells 1000..1040 on both axes; country 5: a 10 x 10 blob (below the minimum)
        for y in 1000..1040 {
            for x in 1000..1040 {
                owner[y * n + x] = 3;
            }
        }
        for y in 100..110 {
            for x in 100..110 {
                owner[y * n + x] = 5;
            }
        }
        let b = blobs(&owner);
        assert_eq!(b.len(), 1);
        let cell = 2.0 * EXTENT / n as f32;
        assert_eq!(b[0].owner, 3);
        assert!((b[0].x - (1020.0 * cell - EXTENT)).abs() < 1e-3);
        assert!((b[0].y - (1020.0 * cell - EXTENT)).abs() < 1e-3);
        assert!((b[0].half - 20.0 * cell).abs() < 1e-3);
        // the name's row is inside the blob, 20 cells to its edge from the centre column: the scan
        // starts at int(50 of the game's world) = 51 cells and stops there, so 51 cells
        let span = 51.0 * cell;
        assert!((b[0].span - span).abs() < 1e-3);
        // a name of 10 letters or more is 0.2 x 10 x 2 x span of the game's world wide
        assert!((b[0].name_width("Sacred Uthabulan Order") - 0.2 * 10.0 * 2.0 * span / 2.0).abs() < 1e-3);
        assert!((b[0].name_width("Uthab") - 0.2 * 5.0 * 2.0 * span / 2.0).abs() < 1e-3);
    }
}
