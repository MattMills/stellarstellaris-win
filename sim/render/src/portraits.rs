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

/// The inset path's marker: `.../portrait|ENTITY|TEXTURE|PPU|AX|AY|CLOTHES|HAIR`
/// (render/portraits.lua).
const MARK: &str = "/portrait|";

/// A model inset's marker: `.../model|planet|ENTITY` (a planet class's entity, as
/// CSpeciesPreviewWindow::CreateHomeworldPreview's 3d_icon), `.../model|ship|CULTURE|SIZE` (a ship
/// size's frame and section in a culture, as its ship_preview's render_target:
/// `.../model|ship|CULTURE|SIZE|TEMPLATE|SLOT`; TEMPLATE `*`: the size's default sections,
/// render.system.default_sections), `...|SLOT|COLOURS|main|CX|CY|VW` a ship browser's main view
/// (customize_species_shipsets' 3d_view: the designer's sky behind it, the ship centred at (CX, CY)
/// of a view VW wide, the inset its visible part) (render/portraits.lua, creator_editors.lua).
const MODEL: &str = "/model|";

/// Fills the scene's portrait insets (those whose path has [`MARK`]) and model insets ([`MODEL`]).
pub fn fill_insets(scene: &mut Scene, lib: &mut models::Library, rt: &Runtime, game_dir: &str, tex: &mut Textures, cache: &mut Cache) {
    if !scene.insets.iter().any(|i| i.path.contains(MARK) || i.path.contains(MODEL)) || lib.ensure(rt, game_dir).is_err() {
        return;
    }
    fill_models(scene, lib, rt, game_dir, tex, cache);
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
        // the diffuses (PixelPdxMeshPortrait's: PortraitCharacter on the body's parts, PortraitClothes
        // on PdxMeshPortraitClothes', PortraitHair on PdxMeshPortraitHair's): the character
        // texture, the clothes' and the hair's selectors' textures (render/portraits.lua)
        let clothes = parts.get(5).copied().unwrap_or("");
        let hair = parts.get(6).copied().unwrap_or("");
        let slot = |tex: &mut Textures, cache: &mut Cache, name: &str| if name.is_empty() { None } else { tex.game(cache, game_dir, name) };
        let (t_body, t_clothes, t_hair) = (slot(tex, cache, texture), slot(tex, cache, clothes), slot(tex, cache, hair));
        for (d, p) in draws.iter_mut().zip(model.parts.iter()) {
            if d.shading != Shading::Portrait {
                continue;
            }
            let sh = p.shader.to_ascii_lowercase();
            let t = if sh.contains("clothes") { t_clothes } else if sh.contains("hair") { t_hair } else { t_body };
            if let Some(t) = t {
                d.textures[0] = t;
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
        if std::env::var("STELLAR_PORTRAIT_DEBUG").is_ok() {
            eprintln!(
                "portraits: {entity}: bounds {lo:?} {hi:?} scale {s} ppu {ppu} anchor {ax} {ay} in {w} x {h} at {:?}; parts {:?}",
                inset.rect,
                model.parts.iter().map(|p| format!("{} {}", p.shader, p.textures[0])).collect::<Vec<_>>()
            );
        }
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

/// Fills the model insets: a planet (its class's look, PixelPdxMeshStandard's planet: system.rs
/// look_of) or a ship (designer.rs's ship model: the frame entity, the culture's lighting), centred
/// and fitted to the inset (the entity sprite's view [I: CEntitySprite's camera not traced]), lit by
/// the worldgfx the game names (customization_view_planet, ship_details_view).
fn fill_models(scene: &mut Scene, lib: &mut models::Library, rt: &Runtime, game_dir: &str, tex: &mut Textures, cache: &mut Cache) {
    for inset in scene.insets.iter_mut() {
        let Some(at) = inset.path.find(MODEL) else { continue };
        let parts: Vec<String> = inset.path[at + MODEL.len()..].split('|').map(str::to_string).collect();
        let (w, h) = ((inset.rect[2] - inset.rect[0]).max(1.0), (inset.rect[3] - inset.rect[1]).max(1.0));
        // a ship browser's main view: its centre and width (screen pixels)
        let main = if parts.first().map(String::as_str) == Some("ship") && parts.get(6).map(String::as_str) == Some("main") {
            let num = |i: usize| parts.get(i).and_then(|s| s.parse::<f32>().ok());
            match (num(7), num(8), num(9)) {
                (Some(cx), Some(cy), Some(vw)) if vw > 0.0 => Some((cx, cy, vw)),
                _ => None,
            }
        } else {
            None
        };
        let (meshes, radius, centre, world, yaw, pitch, fill) = match parts.first().map(String::as_str) {
            Some("planet") if parts.len() >= 2 => {
                let Ok(model) = lib.model(rt, game_dir, &parts[1]) else { continue };
                let look = crate::system::look_of(rt, game_dir, &parts[1]);
                let draws = models::draws(&model, M4::IDENTITY, [1.0; 4], &look, tex, cache, game_dir);
                // (the planet's radius: its mesh's bounds' half width, not its diagonal)
                let (lo, hi) = model.aabb;
                let r = (hi[0] - lo[0]).max(hi[1] - lo[1]) * 0.5 * model.scale;
                (draws, r, model.centre(), "customization_view_planet", 30f32, 8f32, 0.92f32)
            }
            Some("ship") if parts.len() >= 3 => {
                // (its section: `.../SIZE|TEMPLATE|SLOT`, the size's mid section's mesh)
                let section = match (parts.get(3), parts.get(4)) {
                    (Some(t), _) if t == "*" => format!(
                        "require('render.system').default_sections({:?}, {:?})",
                        game_dir.replace('\\', "/"),
                        parts[2]
                    ),
                    (Some(t), Some(s)) => format!("{{ {{ template = {t:?}, slot = {s:?}, components = {{}} }} }}"),
                    _ => "{}".to_string(),
                };
                // (the flag's colours: `...|SLOT|blue,black`: the ship's PrimaryColor, CEmpireFlag::
                // GetEntityColor [I: the first that names a ship swatch, as an owner's])
                let colours = parts.get(5).map_or(String::new(), |c| c.split(',').filter(|n| !n.is_empty()).map(|n| format!("{n:?}")).collect::<Vec<_>>().join(", "));
                let code = format!(
                    "return require('render.system').stage_model({:?}, {{ size = {:?}, sections = {section} }}, {:?}, nil, {{ {colours} }})",
                    game_dir.replace('\\', "/"),
                    parts[2],
                    parts[1]
                );
                let t = match rt.lua.load(code).eval::<Option<stellar_sim::mlua::Table>>() {
                    Ok(Some(t)) => t,
                    Ok(None) => continue,
                    Err(e) => {
                        eprintln!("portraits: {}: {e}", inset.path);
                        continue;
                    }
                };
                let ship = match crate::designer::read_model(&t) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("portraits: {}: {e}", inset.path);
                        continue;
                    }
                };
                if std::env::var("STELLAR_PORTRAIT_DEBUG").is_ok() {
                    eprintln!("portraits: ship frame {:?} sections {:?} model {:?}", ship.frame, ship.sections, lib.model(rt, game_dir, &ship.frame).err());
                }
                let (draws, mut r, mut c) = crate::designer::ship_meshes(lib, rt, game_dir, &ship, tex, cache);
                // (the frame is the size's locators: the drawn meshes' bounds frame the ship, its
                // radius the larger of its length and breadth)
                let (mut lo, mut hi) = ([f32::MAX; 3], [f32::MIN; 3]);
                for d in &draws {
                    for v in &d.mesh.vertices {
                        let p = d.model.apply([v.pos[0], v.pos[1], v.pos[2], 1.0]);
                        for k in 0..3 {
                            lo[k] = lo[k].min(p[k]);
                            hi[k] = hi[k].max(p[k]);
                        }
                    }
                }
                if lo[0] <= hi[0] {
                    r = (hi[0] - lo[0]).max(hi[2] - lo[2]) * 0.5;
                    c = V3((lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5);
                }
                // (lit as the ship designer's view: ship_details_view's cubemap and ambient wash our
                // ship shading out [I]; the ship fitted to the box's width: a negative fill; the angle by
                // the game's frame of the empire selection [I])
                // (a main view: broadside, as the designer's [I: by the game's frame])
                if main.is_some() {
                    (draws, r, c, "ship_designer", -75f32, 14f32, -0.7f32)
                } else {
                    (draws, r, c, "ship_designer", 235f32, 30f32, -0.7f32)
                }
            }
            _ => continue,
        };
        if std::env::var("STELLAR_PORTRAIT_DEBUG").is_ok() {
            eprintln!("portraits: {} {} meshes, radius {radius}, centre {centre:?}, rect {:?}", inset.path, meshes.len(), inset.rect);
        }
        if meshes.is_empty() || !radius.is_finite() || radius <= 0.0 {
            continue;
        }
        let mut cam = crate::camera::OrbitCamera::system(radius * 2.0);
        cam.target = centre;
        cam.yaw = yaw.to_radians();
        cam.pitch = pitch.to_radians();
        cam.min_distance = 0.0;
        cam.min_pitch = -1.5;
        // the model fills the inset's smaller side (its radius over the half view's tangent), or its
        // width (a negative fill)
        let half = (cam.fov_y / 2.0).tan() * if fill < 0.0 { w / h } else { (w / h).min(1.0) };
        let fill = fill.abs();
        cam.distance = radius / fill / half.max(1e-3);
        let mut view = cam.view_params(w as u32, h as u32);
        if let Some((cx, cy, vw)) = main {
            // the ship 0.22 of the view's width (the game's frame: 275 of 1254 pixels), its centre
            // at the view's: the target moved by the offset from the inset's centre
            let d = 2.0 * radius * view.focal_px / (0.22 * vw);
            let (dx, dy) = (cx - (inset.rect[0] + inset.rect[2]) * 0.5, cy - (inset.rect[1] + inset.rect[3]) * 0.5);
            let s = d / view.focal_px.max(1e-3);
            cam.distance = d;
            cam.target = centre.sub(view.right.scale(dx * s)).add(view.up.scale(dy * s));
            view = cam.view_params(w as u32, h as u32);
        }
        let to_eye = view.eye.sub(cam.target).norm();
        let l = view.right.scale(-0.7).add(view.up.scale(0.45)).add(to_eye.scale(0.55)).norm();
        inset.light = [l.0, l.1, l.2, 0.0];
        if let Ok(wg) = crate::worldgfx::read(rt, game_dir, world) {
            inset.cam_lights = wg.ship_lights.map(|c| [c[0].max(0.0).powf(4.84), c[1].max(0.0).powf(4.84), c[2].max(0.0).powf(4.84), 1.0]);
            inset.env = wg.env(tex, cache, game_dir);
            // (a main view: the designer's galaxy_background behind the ship)
            if main.is_some() {
                inset.sky = wg.sky(tex, cache, game_dir, 0.0);
            }
        }
        inset.view = Some(view);
        inset.meshes = meshes;
    }
}
