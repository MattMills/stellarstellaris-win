//! A country's flag as a flagSpriteType draws it (gfx/FX/flag_sprite.shader, composed on the
//! CPU): the background texture's red, green and blue channels weight the flag's first three
//! colours, the emblem laid over it by its alpha in its rectangle, the alpha cut by the sprite's
//! mask, then the sprite's frame texture over everything. The parts' rectangles are the sprite's
//! `bg_position`/`bg_size`, `symbol_position`/`symbol_size`, `mask_offset`/`mask_size` (pixels
//! of the frame); the emblem comes from flags/<category>/<texture_size>/<file> (`small`, `map`;
//! the full size without one), the background from flags/backgrounds/<file>.

use crate::dds::{Cache, Image};
use crate::galaxy::Flag;

/// A flagSpriteType's definition (render.gfx).
#[derive(Clone, Debug, Default)]
pub struct FlagSprite {
    pub frame: String,
    pub mask: Option<String>,
    pub texture_size: Option<String>,
    pub bg: Option<([f32; 2], [f32; 2])>,
    pub symbol: Option<([f32; 2], [f32; 2])>,
    pub mask_rect: Option<([f32; 2], [f32; 2])>,
}

/// Bilinear, clamped to the edges; RGBA 0..1.
fn sample(img: &Image, u: f32, v: f32) -> [f32; 4] {
    let (w, h) = (img.width as f32, img.height as f32);
    let (x, y) = ((u * w - 0.5).clamp(0.0, w - 1.0), (v * h - 0.5).clamp(0.0, h - 1.0));
    let (x0, y0) = (x.floor(), y.floor());
    let (fx, fy) = (x - x0, y - y0);
    let (x0, y0) = (x0 as u32, y0 as u32);
    let (x1, y1) = ((x0 + 1).min(img.width - 1), (y0 + 1).min(img.height - 1));
    let p = |x: u32, y: u32| img.pixel(x, y).map(|c| c as f32 / 255.0);
    let (a, b, c, d) = (p(x0, y0), p(x1, y0), p(x0, y1), p(x1, y1));
    let mut out = [0.0; 4];
    for k in 0..4 {
        out[k] = (a[k] * (1.0 - fx) + b[k] * fx) * (1.0 - fy) + (c[k] * (1.0 - fx) + d[k] * fx) * fy;
    }
    out
}

/// The flag composed at the frame's size (the frame's first frame); None if its frame does not
/// load.
pub fn compose(cache: &mut Cache, game_dir: &str, sprite: &FlagSprite, flag: &Flag, modulate: [f32; 4]) -> Option<Image> {
    let frame = cache.get(game_dir, &sprite.frame).ok()?.clone();
    let (w, h) = (frame.width, frame.height);
    let (fw, fh) = (w as f32, h as f32);
    let emblem = {
        let (cat, file) = &flag.icon;
        let sized = sprite.texture_size.as_deref().map(|s| format!("flags/{cat}/{s}/{file}"));
        sized.and_then(|p| cache.get(game_dir, &p).ok().cloned()).or_else(|| cache.get(game_dir, &format!("flags/{cat}/{file}")).ok().cloned())
    };
    let background = cache.get(game_dir, &format!("flags/backgrounds/{}", flag.background.1)).ok().cloned();
    let mask = sprite.mask.as_ref().and_then(|m| cache.get(game_dir, m).ok().cloned());
    let colour = |k: usize| flag.colours.get(k).copied().unwrap_or([0.0; 3]);
    let rect = |r: Option<([f32; 2], [f32; 2])>| r.map_or(([0.0, 0.0], [1.0, 1.0]), |(p, s)| ([p[0] / fw, p[1] / fh], [s[0].max(1.0) / fw, s[1].max(1.0) / fh]));
    let (bgp, bgs) = rect(sprite.bg);
    let (syp, sys) = rect(sprite.symbol);
    let (mp, ms) = rect(sprite.mask_rect);
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    for y in 0..h {
        for x in 0..w {
            let (u, v) = ((x as f32 + 0.5) / fw, (y as f32 + 0.5) / fh);
            // GetFlagColor
            let mut c = [0.0f32, 0.0, 0.0, 1.0];
            if let Some(bg) = &background {
                let t = sample(bg, (u - bgp[0]) / bgs[0], (v - bgp[1]) / bgs[1]);
                for (k, wgt) in [t[0], t[1], t[2]].into_iter().enumerate() {
                    let col = colour(k);
                    for j in 0..3 {
                        c[j] += col[j] * wgt;
                    }
                }
                for j in 0..3 {
                    c[j] = c[j].clamp(0.0, 1.0);
                }
            }
            let (su, sv) = ((u - syp[0]) / sys[0], (v - syp[1]) / sys[1]);
            if let (Some(e), true) = (&emblem, (0.0..=1.0).contains(&su) && (0.0..=1.0).contains(&sv)) {
                let s = sample(e, su, sv);
                for j in 0..3 {
                    c[j] = c[j] * (1.0 - s[3]) + s[j] * s[3];
                }
            }
            if let Some(m) = &mask {
                c[3] *= sample(m, (u - mp[0]) / ms[0], (v - mp[1]) / ms[1])[3];
            }
            // AddFrame: the frame x ModulateColor (a map label's relation colour)
            let mut f = frame.pixel(x, y).map(|c| c as f32 / 255.0);
            for j in 0..4 {
                f[j] = (f[j] * modulate[j]).clamp(0.0, 1.0);
            }
            let out = [
                c[0] * c[3] * (1.0 - f[3]) + f[0] * f[3],
                c[1] * c[3] * (1.0 - f[3]) + f[1] * f[3],
                c[2] * c[3] * (1.0 - f[3]) + f[2] * f[3],
                c[3].max(f[3]),
            ];
            // straight alpha for the GUI's blend (the shader's colour is premultiplied by the
            // flag's alpha where the frame is clear)
            let a = out[3].max(1e-4);
            let i = ((y * w + x) * 4) as usize;
            for j in 0..3 {
                rgba[i + j] = ((out[j] / a).clamp(0.0, 1.0) * 255.0).round() as u8;
            }
            rgba[i + 3] = (out[3].clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    Some(Image { width: w, height: h, rgba, format: "generated".into() })
}
