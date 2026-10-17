//! Leader portraits in the GUI (docs/windows/portraits.md). The game draws a character's portrait
//! (CPortraitObject: the portrait's entity, gfx/models/portraits, with its character texture)
//! into a render target laid out by gfx/portraits/portraits/00_portraits_main.txt's `character`
//! (575 x 380, the entity at its centre bottom, 24 pixels a unit), and shows it as the card's
//! portrait icon (GFX_portrait_character_close_up and the like, scaled). Here the view's layout
//! puts an "inset" item where the portrait shows (render/portraits.lua: its path carries the
//! entity, the texture, the pixels a unit and the entity's anchor in the inset), and this fills
//! it: the entity's meshes in an orthographic view from the front, drawn as PixelPdxMeshPortrait
//! draws them (Shading::Portrait: the texture unlit, blended by its alpha).

use stellar_sim::Runtime;

use crate::camera::ViewParams;
use crate::dds::Cache;
use crate::math::{M4, V3};
use crate::models;
use crate::scene::{Look, Scene, Shading, Textures};

/// The inset path's marker: `.../portrait|ENTITY|TEXTURE|PPU|AX|AY` (render/portraits.lua).
const MARK: &str = "/portrait|";

/// Fills the scene's portrait insets (those whose path has [`MARK`]).
pub fn fill_insets(scene: &mut Scene, lib: &mut models::Library, rt: &Runtime, game_dir: &str, tex: &mut Textures, cache: &mut Cache) {
    if !scene.insets.iter().any(|i| i.path.contains(MARK)) || lib.ensure(rt, game_dir).is_err() {
        return;
    }
    for inset in scene.insets.iter_mut() {
        let Some(at) = inset.path.find(MARK) else { continue };
        let parts: Vec<&str> = inset.path[at + MARK.len()..].split('|').collect();
        if parts.len() < 5 {
            continue;
        }
        let (entity, texture) = (parts[0], parts[1]);
        let num = |s: &str| s.parse::<f32>().unwrap_or(0.0);
        let (ppu, ax, ay) = (num(parts[2]), num(parts[3]), num(parts[4]));
        let Ok(model) = lib.model(rt, game_dir, entity) else { continue };
        let mut draws = models::draws(&model, M4::IDENTITY, [1.0; 4], &Look::default(), tex, cache, game_dir);
        if draws.is_empty() || ppu <= 0.0 {
            continue;
        }
        // the character texture: the diffuse of the body's parts (PdxMeshPortrait and its
        // Skinned / HueShift forms; the clothes' and hair's keep theirs [I: their selectors'
        // textures not chosen])
        if !texture.is_empty() {
            if let Some(t) = tex.game(cache, game_dir, texture) {
                for (d, p) in draws.iter_mut().zip(model.parts.iter()) {
                    let sh = p.shader.to_ascii_lowercase();
                    if d.shading == Shading::Portrait && !sh.contains("clothes") && !sh.contains("hair") {
                        d.textures[0] = t;
                    }
                }
            }
        }
        let (w, h) = ((inset.rect[2] - inset.rect[0]).max(1.0), (inset.rect[3] - inset.rect[1]).max(1.0));
        // model space (x right, y up, the character facing +z) to the inset: the bounds' bottom
        // centre (cx, y0) at the anchor (orientation center_down), pixel x = ax + ppu (x - cx),
        // pixel y = ay - ppu (y - y0) (the entity's scale in the model's draws); depth over z
        let (lo, hi) = model.aabb;
        let s = model.scale;
        let (cx, y0) = ((lo[0] + hi[0]) * 0.5 * s, lo[1] * s);
        let (z0, z1) = (lo[2] * s - 1.0, hi[2] * s + 1.0);
        let dz = (z1 - z0).max(0.01);
        let (sx, sy) = (2.0 * ppu / w, 2.0 * ppu / h);
        let view_proj = M4([
            [sx, 0.0, 0.0, 2.0 * ax / w - 1.0 - sx * cx],
            [0.0, sy, 0.0, 1.0 - 2.0 * ay / h - sy * y0],
            [0.0, 0.0, -1.0 / dz, z1 / dz],
            [0.0, 0.0, 0.0, 1.0],
        ]);
        let eye = V3(0.0, hi[1] * s, z1 + 1000.0);
        inset.view = Some(ViewParams { view_proj, right: V3(1.0, 0.0, 0.0), up: V3(0.0, 1.0, 0.0), eye, width: w as u32, height: h as u32, focal_px: ppu, perspective: false });
        inset.meshes = draws;
    }
}
