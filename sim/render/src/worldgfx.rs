//! The game's per-world graphics settings, gfx/worldgfx/*.txt (`gfx_settings = { world = <tag>
//! ... }`): the galaxy's (`default`), each star class's (`g_star`, `a_star`, ...: a system with
//! that star), the system view's fallback (`system_view`). Read by `lua/render/system.lua`; here
//! the values the renderer uses: the post effects (bloom, exposure, the colour cube), the sky.

use stellar_sim::mlua::{self, Table, Value};
use stellar_sim::Runtime;

use crate::dds::Cache;
use crate::scene::{Post, SkyDraw, Textures};

#[derive(Clone, Debug)]
pub struct WorldGfx {
    pub world: String,
    pub bright_threshold: f32,
    pub bloom_width: f32,
    pub bloom_scale: f32,
    pub bloom_iterations: u32,
    pub emissive_bloom: f32,
    pub hdr_min: f32,
    pub hdr_max: f32,
    pub middle_grey: f32,
    pub color_lut: String,
    /// the sky's cube maps: texture, the distance_to_core_percent it is for (below), YCoCg
    pub backgrounds: Vec<(String, f32, bool)>,
    pub background_hsv_shift: [f32; 3],
    pub background_lut: String,
    pub system_light: String,
    /// the planets' back light (system_back_light_diffuse, gamma space)
    pub back_light: [f32; 3],
    /// the meshes' reflections: environment_map (a pre-filtered cube map), cubemap_intensity
    pub environment_map: String,
    pub cubemap_intensity: f32,
    /// the ships' light settings (gamma space): cam_light_1..3_diffuse, rim_light_diffuse, ambient
    pub ship_lights: [[f32; 3]; 5],
}

/// The settings of a world tag (the `default` world's when the tag has none).
pub fn read(rt: &Runtime, game_dir: &str, world: &str) -> Result<WorldGfx, String> {
    let read = || -> mlua::Result<WorldGfx> {
        let t: Table = rt
            .lua
            .load(format!("return require('render.system').world_settings({:?}, {world:?})", game_dir.replace('\\', "/")))
            .eval()?;
        let num = |k: &str, d: f32| -> f32 { t.get::<Option<f32>>(k).ok().flatten().unwrap_or(d) };
        let text = |k: &str| -> String { t.get::<Option<String>>(k).ok().flatten().unwrap_or_default() };
        let mut backgrounds = Vec::new();
        if let Ok(Some(b)) = t.get::<Option<Table>>("backgrounds") {
            for e in b.sequence_values::<Table>() {
                let e = e?;
                backgrounds.push((e.get::<Option<String>>("texture")?.unwrap_or_default(), e.get::<Option<f32>>("below")?.unwrap_or(2.0), e.get::<Option<bool>>("ycocg")?.unwrap_or(false)));
            }
        }
        let mut hsv = [0.0; 3];
        if let Ok(Value::Table(h)) = t.get::<Value>("galaxy_background_hsv_shift") {
            for (k, v) in hsv.iter_mut().enumerate() {
                *v = h.get::<Option<f32>>(k + 1)?.unwrap_or(0.0);
            }
        }
        Ok(WorldGfx {
            world: text("world"),
            bright_threshold: num("bright_threshold", 0.95),
            bloom_width: num("bloom_width", 2.0),
            bloom_scale: num("bloom_scale", 0.95),
            bloom_iterations: num("bloom_iterations", 8.0) as u32,
            emissive_bloom: num("emissive_bloom_strength", 0.6),
            hdr_min: num("hdr_min_adjustment", 0.08),
            hdr_max: num("hdr_max_adjustment", 0.2),
            middle_grey: num("tonemap_middlegrey", 0.14),
            color_lut: text("color_lut"),
            backgrounds,
            background_hsv_shift: hsv,
            background_lut: text("galaxy_background_lut"),
            system_light: text("system_light"),
            back_light: match t.get::<Value>("system_back_light_diffuse") {
                Ok(Value::Table(c)) => [c.get(1).unwrap_or(0.41), c.get(2).unwrap_or(0.48), c.get(3).unwrap_or(0.55)],
                _ => [0.41, 0.48, 0.55],
            },
            environment_map: text("environment_map"),
            cubemap_intensity: num("cubemap_intensity", 0.4),
            ship_lights: ["cam_light_1_diffuse", "cam_light_2_diffuse", "cam_light_3_diffuse", "rim_light_diffuse", "ambient"].map(|k| match t.get::<Value>(k) {
                Ok(Value::Table(c)) => [c.get(1).unwrap_or(0.0), c.get(2).unwrap_or(0.0), c.get(3).unwrap_or(0.0)],
                _ => [0.0; 3],
            }),
        })
    };
    read().map_err(|e| format!("render.system.world_settings({world}): {e}"))
}

impl WorldGfx {
    /// The post effects of this world (its colour cube loaded into the scene's textures).
    pub fn post(&self, tex: &mut Textures, cache: &mut Cache, game_dir: &str) -> Post {
        let lut = if self.color_lut.is_empty() { None } else { tex.game(cache, game_dir, &self.color_lut) };
        Post {
            bright_threshold: self.bright_threshold,
            bloom_width: self.bloom_width,
            bloom_scale: self.bloom_scale,
            bloom_iterations: self.bloom_iterations,
            emissive_bloom: self.emissive_bloom,
            hdr_min: self.hdr_min,
            hdr_max: self.hdr_max,
            middle_grey: self.middle_grey,
            lut,
        }
    }
}

impl WorldGfx {
    /// The environment map with its mip levels (the reflections by glossiness) and its intensity.
    pub fn env(&self, tex: &mut Textures, cache: &mut Cache, game_dir: &str) -> Option<(usize, f32)> {
        if self.environment_map.is_empty() {
            return None;
        }
        Some((tex.game_cube_levels(cache, game_dir, &self.environment_map, 16)?, self.cubemap_intensity))
    }

    /// The sky of this world for a place `core_pct` of the galaxy's radius from its core: the
    /// first `galaxy_background` whose `distance_to_core_percent` bound it is under (the last
    /// has `always = yes`).
    pub fn sky(&self, tex: &mut Textures, cache: &mut Cache, game_dir: &str, core_pct: f32) -> Option<SkyDraw> {
        let (path, _, ycocg) = self.backgrounds.iter().find(|b| core_pct < b.1).or(self.backgrounds.last())?;
        let cube = tex.game_cube(cache, game_dir, path)?;
        let lut = if self.background_lut.is_empty() { None } else { tex.game(cache, game_dir, &self.background_lut) };
        Some(SkyDraw { cube, ycocg: *ycocg, hsv_shift: self.background_hsv_shift, lut })
    }
}

/// A light of gfx/lights (render.system's `light`): its colour made linear (^2.2, the game's
/// GfxToLinear in CGameRendering::SetSystemLight) x its intensity.
pub fn light(rt: &Runtime, game_dir: &str, name: &str) -> Option<[f32; 3]> {
    let t: Option<Table> = rt
        .lua
        .load(format!("return require('render.system').light({:?}, {name:?})", game_dir.replace('\\', "/")))
        .eval()
        .ok()?;
    let t = t?;
    let (r, g, b, i): (f32, f32, f32, f32) = (t.get(1).ok()?, t.get(2).ok()?, t.get(3).ok()?, t.get(4).ok()?);
    Some([r.max(0.0).powf(2.2) * i, g.max(0.0).powf(2.2) * i, b.max(0.0).powf(2.2) * i])
}
