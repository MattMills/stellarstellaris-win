//! The game's 3D models: an entity (gfx/models/**/*.asset) or a pdxmesh (gfx/models/**/*.gfx)
//! by name, through the Lua index (`lua/render/models.lua`), its mesh file read with
//! pdxmesh.rs, its textures (the mesh file's materials, with the pdxmesh's and the entity's
//! `meshsettings` over them by shape), and draws of it for a scene.

use std::collections::HashMap;
use std::sync::Arc;

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::dds::{self, Cache};
use crate::math::{M4, V3};
use crate::pdxmesh;
use crate::scene::{Look, MeshData, MeshDraw, MeshVertex, Shading, Textures};

/// A model's drawable part: one sub-mesh with its textures (paths in the game directory, or
/// generated names) and how it is shaded.
#[derive(Clone)]
pub struct Part {
    pub shape: String,
    pub shader: String,
    pub mesh: Arc<MeshData>,
    pub textures: [String; 3],
    pub shading: Shading,
    /// the defines of its effect (gfx/FX/pdxmesh.shader: effects.rs bits)
    pub flags: u32,
}

#[derive(Clone)]
pub struct Model {
    pub name: String,
    pub file: String,
    pub scale: f32,
    pub parts: Vec<Part>,
    pub locators: Vec<pdxmesh::Locator>,
    /// the drawn parts' bounds (model space, before `scale`)
    pub aabb: ([f32; 3], [f32; 3]),
    /// the entity's attachments: locator -> entity
    pub attach: Vec<(String, String)>,
    /// shapes skipped (collision, effects) and why
    pub skipped: Vec<String>,
    /// the particle effects its default state starts (the entity's `state` events)
    pub particles: Vec<String>,
    /// the entity's game_data bloom_factor (vBloomFactor: the lit colour times it), 1 if none
    pub bloom_factor: f32,
    /// game_data emissive_recolor_crunch (a ship's ShipVars.r), 1 if none
    pub recolor_crunch: f32,
}

impl Model {
    pub fn radius(&self) -> f32 {
        let (lo, hi) = self.aabb;
        let d = V3(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]);
        0.5 * d.len() * self.scale
    }
    pub fn centre(&self) -> V3 {
        let (lo, hi) = self.aabb;
        V3((lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5).scale(self.scale)
    }
    pub fn locator(&self, name: &str) -> Option<&pdxmesh::Locator> {
        self.locators.iter().find(|l| l.name == name)
    }
}

/// How a shader of the game's is drawn here (None: not drawn: collision volumes, effects not
/// ported). Effects of PixelPdxMeshAdditive (gfx/FX/pdxmesh.shader) are drawn as Additive.
pub fn shading_of(game_dir: &str, shader: &str) -> Option<Shading> {
    let s = shader.to_ascii_lowercase();
    if s.is_empty() || s.contains("collision") {
        return None;
    }
    if crate::effects::effect(game_dir, shader).is_some_and(|e| e.pixel_shader == "PixelPdxMeshAdditive") {
        return Some(Shading::Additive);
    }
    if s.contains("atmospherestar") {
        return Some(Shading::StarAtmosphere);
    }
    if s.contains("atmosphere") {
        return Some(Shading::Atmosphere);
    }
    if s.contains("clouds") {
        return Some(Shading::Clouds);
    }
    if s.contains("planetrings") {
        return Some(Shading::Ring);
    }
    if s == "pdxmeshnavigationbutton" {
        return Some(Shading::Button);
    }
    if s == "pdxmeshstar" {
        return Some(Shading::Star);
    }
    if s.contains("star") {
        return Some(Shading::Emissive);
    }
    // a portrait's parts (PdxMeshPortrait and its Skinned, HueShift, Clothes, Hair forms:
    // PixelPdxMeshPortrait), drawn in the views' portraits (portraits.rs)
    if s.starts_with("pdxmeshportrait") {
        return Some(Shading::Portrait);
    }
    if s.contains("additive") || s.contains("alphablend") || s.contains("shield") || s.contains("flow") || s.contains("portrait")
        || s.contains("navigation") || s.contains("gradient") || s.contains("rift") || s.contains("snare") || s.contains("frontend")
    {
        return None;
    }
    Some(Shading::Lit)
}

#[derive(Default)]
pub struct Library {
    /// mesh files read: path -> the mesh, or why not
    files: HashMap<String, Result<Arc<pdxmesh::Mesh>, String>>,
    models: HashMap<String, Result<Model, String>>,
    pub summary: Option<String>,
    /// the .dds files of gfx/models by their name (lower case) -> their path in the game
    /// directory: where a texture is found when it is not beside its mesh or its definition
    dds_names: Option<std::sync::Arc<HashMap<String, String>>>,
}

impl Library {
    /// The Lua index of the model definitions in a runtime (built once: RENDER_MODELS).
    pub fn ensure(&mut self, rt: &Runtime, game_dir: &str) -> Result<(), String> {
        if self.summary.is_some() {
            return Ok(());
        }
        let g = rt.lua.globals();
        if g.get::<Option<String>>("RENDER_GAME_DIR").ok().flatten().is_none() {
            g.set("RENDER_GAME_DIR", game_dir.replace('\\', "/")).map_err(|e| e.to_string())?;
        }
        let s: String = rt
            .lua
            .load(
                r#"
                if not RENDER_MODELS then RENDER_MODELS = require('render.models').load(RENDER_GAME_DIR) end
                local n, m = 0, 0
                for _ in pairs(RENDER_MODELS.entities) do n = n + 1 end
                for _ in pairs(RENDER_MODELS.meshes) do m = m + 1 end
                return string.format("%d entities, %d pdxmeshes from %d files of gfx/models (%d did not parse) in %.1f s",
                    n, m, RENDER_MODELS.files, RENDER_MODELS.errors, RENDER_MODELS.seconds)
                "#,
            )
            .eval()
            .map_err(|e| format!("render.models: {e}"))?;
        eprintln!("models: {s}");
        self.summary = Some(s);
        Ok(())
    }

    /// The .dds files of gfx/models by name (walked once).
    fn dds_names(&mut self, game_dir: &str) -> std::sync::Arc<HashMap<String, String>> {
        // (walked once a process, on a worker at a load: prepare.rs)
        self.dds_names.get_or_insert_with(|| crate::prepare::dds_names(game_dir)).clone()
    }

    fn mesh_file(&mut self, game_dir: &str, rel: &str) -> Result<Arc<pdxmesh::Mesh>, String> {
        if !self.files.contains_key(rel) {
            let path = dds::find_case_insensitive(game_dir, rel).unwrap_or_else(|| format!("{game_dir}/{rel}"));
            self.files.insert(rel.to_string(), pdxmesh::load(&path).map(Arc::new));
        }
        self.files[rel].clone()
    }

    /// A model by name (an entity, else a pdxmesh), loaded once.
    pub fn model(&mut self, rt: &Runtime, game_dir: &str, name: &str) -> Result<Model, String> {
        if let Some(m) = self.models.get(name) {
            return m.clone();
        }
        let r = self.load_model(rt, game_dir, name);
        self.models.insert(name.to_string(), r.clone());
        r
    }

    fn load_model(&mut self, rt: &Runtime, game_dir: &str, name: &str) -> Result<Model, String> {
        self.ensure(rt, game_dir)?;
        let span = crate::prof::span("model: described (lua)");
        let d: (Option<Table>, Option<String>) = rt
            .lua
            .load(format!("return require('render.models').describe(RENDER_MODELS, {name:?})"))
            .eval()
            .map_err(|e| format!("render.models: {e}"))?;
        let t = match d {
            (Some(t), _) => t,
            (None, why) => return Err(why.unwrap_or_else(|| format!("no model {name}"))),
        };
        let read = || -> mlua::Result<(String, f32, Vec<(String, Option<String>, Option<String>, Option<String>, Option<String>)>, Vec<(String, String)>)> {
            let file: String = t.get("file")?;
            let scale: f32 = t.get::<Option<f32>>("scale")?.unwrap_or(1.0);
            let mut settings = Vec::new();
            for s in t.get::<Table>("settings")?.sequence_values::<Table>() {
                let s = s?;
                settings.push((s.get("shape")?, s.get("diffuse")?, s.get("normal")?, s.get("specular")?, s.get("shader")?));
            }
            let mut attach = Vec::new();
            for a in t.get::<Table>("attach")?.sequence_values::<Table>() {
                let a = a?;
                attach.push((a.get("locator")?, a.get("entity")?));
            }
            Ok((file, scale, settings, attach))
        };
        let (file, scale, settings, attach) = read().map_err(|e| format!("render.models: {e}"))?;
        drop(span);
        let span = crate::prof::span("model: mesh file read, parsed");
        let mesh = self.mesh_file(game_dir, &file)?;
        drop(span);
        let _s = crate::prof::span("model: parts, texture paths");
        let dir = file.rsplit_once('/').map(|(d, _)| d.to_string()).unwrap_or_default();
        // the directories a texture's name is looked for in: the entity's and the pdxmesh's
        // definition files' (meshsettings), then the mesh file's
        let mut dirs: Vec<String> = t.get::<Option<Vec<String>>>("dirs").ok().flatten().unwrap_or_default();
        dirs.push(dir.clone());
        // then anywhere in gfx/models by its name [I] (nonormal.dds, nospec.dds are in
        // gfx/models; the starbases' meshes use their culture's textures in ships/<culture>)
        let names = self.dds_names(game_dir);
        let tex_path = |name: &str| -> String {
            if name.is_empty() {
                return String::new();
            }
            let mut n = name.replace('\\', "/");
            // a .tga named where only the .dds is shipped (4.5.2: 11 textures of ships) [I]
            if n.to_lowercase().ends_with(".tga") {
                n = format!("{}.dds", &n[..n.len() - 4]);
            }
            if n.contains('/') {
                return n;
            }
            for d in &dirs {
                let p = format!("{d}/{n}");
                if dds::find_case_insensitive(game_dir, &p).is_some() {
                    return p;
                }
            }
            if let Some(p) = names.get(&n.to_lowercase()) {
                return p.clone();
            }
            format!("{dir}/{n}")
        };
        let mut parts = Vec::new();
        let mut skipped = Vec::new();
        let (mut lo, mut hi) = ([f32::MAX; 3], [f32::MIN; 3]);
        for shape in &mesh.shapes {
            // the shape's settings, else settings naming no shape (all shapes) [I]
            let over = settings.iter().find(|s| s.0 == shape.name).or_else(|| settings.iter().find(|s| s.0.is_empty()));
            for (k, sm) in shape.meshes.iter().enumerate() {
                // a collision volume stays one whatever the settings say: a meshsettings naming no
                // shape (`shader = "PdxMeshShip"` in mammalian_01_science_mesh) does not draw it
                if sm.material.shader.to_ascii_lowercase().contains("collision") {
                    skipped.push(format!("{} ({})", shape.name, sm.material.shader));
                    continue;
                }
                let shader = over.and_then(|o| o.4.clone()).unwrap_or_else(|| sm.material.shader.clone());
                let Some(shading) = shading_of(game_dir, &shader) else {
                    skipped.push(format!("{} ({shader})", shape.name));
                    continue;
                };
                let pick = |o: Option<&Option<String>>, m: &str| -> String { o.and_then(|v| v.clone()).map(|v| tex_path(&v)).unwrap_or_else(|| tex_path(m)) };
                let textures = [
                    pick(over.map(|o| &o.1), &sm.material.diffuse),
                    pick(over.map(|o| &o.2), &sm.material.normal),
                    pick(over.map(|o| &o.3), &sm.material.specular),
                ];
                let vertices: Vec<MeshVertex> = (0..sm.positions.len())
                    .map(|i| MeshVertex { pos: sm.positions[i], normal: sm.normals[i], tangent: sm.tangents[i], uv: sm.uv0[i] })
                    .collect();
                for p in &sm.positions {
                    for c in 0..3 {
                        lo[c] = lo[c].min(p[c]);
                        hi[c] = hi[c].max(p[c]);
                    }
                }
                let key = format!("{file}#{}#{k}", shape.name);
                parts.push(Part {
                    shape: shape.name.clone(),
                    mesh: Arc::new(MeshData { key, vertices, indices: sm.indices.clone() }),
                    textures,
                    shading,
                    flags: crate::effects::effect(game_dir, &shader).map_or(0, |e| e.flags()),
                    shader,
                });
            }
        }
        if parts.is_empty() {
            (lo, hi) = ([0.0; 3], [0.0; 3]);
        }
        let particles: Vec<String> = t
            .get::<Option<Table>>("particles")
            .ok()
            .flatten()
            .map(|p| p.sequence_values::<Table>().filter_map(|x| x.ok()?.get::<String>("particle").ok()).collect())
            .unwrap_or_default();
        let bloom_factor = t.get::<Option<f32>>("bloom_factor").ok().flatten().unwrap_or(1.0);
        let recolor_crunch = t.get::<Option<f32>>("recolor_crunch").ok().flatten().unwrap_or(1.0);
        Ok(Model { name: name.to_string(), file, scale, parts, locators: mesh.locators.clone(), aabb: (lo, hi), attach, skipped, particles, bloom_factor, recolor_crunch })
    }
}

/// A texture for a part: the game's file, or a neutral stand-in when it has none or it does not
/// load (white diffuse, flat normal, no specular).
fn part_texture(tex: &mut Textures, cache: &mut Cache, game_dir: &str, path: &str, slot: usize) -> usize {
    let fallback = ["@white", "@flat_normal", "@black"][slot];
    if path.is_empty() || path.ends_with("nospec.dds") && slot == 0 {
        return tex.generated(fallback);
    }
    match tex.game(cache, game_dir, path) {
        Some(i) => i,
        None => tex.generated(fallback),
    }
}

/// The star textures of gfx/worldgfx (tex_lava_diffuse, tex_stone_diffuse: the same in every
/// star class's file).
pub const LAVA_TEXTURES: [&str; 2] = ["gfx/worldgfx/lava_d.dds", "gfx/worldgfx/stone_d.dds"];
/// The star classes' lava noise (tex_lava_noise in every star class's file): a cube map.
pub const LAVA_NOISE: &str = "gfx/worldgfx/lava_noise.dds";

/// What a part of the game's shader is lit as here: 1 a planet (IS_PLANET: PdxMeshPlanet,
/// PdxMeshClouds, PdxMeshGasGiant), 3 a planet whose emissive glows everywhere (NO_PLANET_EMISSIVE:
/// PdxMeshPlanetEmissive, PdxMeshMoltenPlanet and their skinned forms), 2 a ship (PdxMeshShip and
/// the ships' PdxMeshTerra), 0 else.
fn part_kind(shader: &str) -> f32 {
    let s = shader.to_ascii_lowercase();
    if (s.contains("planetemissive") && !s.contains("withlights")) || s.contains("moltenplanet") {
        3.0
    } else if s.contains("planet") || s.contains("clouds") || s.contains("gasgiant") {
        1.0
    } else if s.contains("ship") || s.contains("terra") {
        2.0
    } else {
        0.0
    }
}

/// The draws of a model at `transform` (the model's own scale applied first); `tint` multiplies
/// the lit parts; `look` gives the atmospheres' and the star's colours.
#[allow(clippy::too_many_arguments)]
pub fn draws(model: &Model, transform: M4, tint: [f32; 4], look: &Look, tex: &mut Textures, cache: &mut Cache, game_dir: &str) -> Vec<MeshDraw> {
    let m = transform.mul(&M4::scaling(model.scale));
    model
        .parts
        .iter()
        .map(|p| {
            let t = if p.shading == Shading::Star {
                let lava = tex.game(cache, game_dir, LAVA_TEXTURES[0]).unwrap_or_else(|| tex.generated("@white"));
                let stone = tex.game(cache, game_dir, LAVA_TEXTURES[1]).unwrap_or_else(|| tex.generated("@white"));
                [lava, stone, tex.generated("@black")]
            } else {
                [
                    part_texture(tex, cache, game_dir, &p.textures[0], 0),
                    part_texture(tex, cache, game_dir, &p.textures[1], 1),
                    part_texture(tex, cache, game_dir, &p.textures[2], 2),
                ]
            };
            let mut d = MeshDraw::new(p.mesh.clone(), m, t, p.shading, tint);
            d.look = *look;
            d.look.kind = part_kind(&p.shader);
            if p.shading == Shading::Star {
                // the lava noise (gfx/worldgfx: tex_lava_noise, a cube map)
                d.cube = tex.game_cube(cache, game_dir, LAVA_NOISE);
            }
            if d.look.kind == 1.0 || d.look.kind == 3.0 {
                d.params[3] = 0.08;
            }
            // PixelPdxMeshStandard's: the defines, vBloomFactor, (CubemapIntensity: the
            // scene's), AtmosphereColor.a (a class with an atmosphere colour)
            d.std = [p.flags as f32, model.bloom_factor, 0.0, look.colour_alpha];
            d
        })
        .collect()
}

impl Library {
    /// Forgets the models and mesh files read (the census reads them all once).
    fn forget(&mut self) {
        self.models.clear();
        self.files.clear();
    }
}

/// Every entity of gfx/models resolved to its mesh and textures: how many load, how many parts
/// are drawn (by shader) or skipped, which textures are not found. A report for docs/render.md.
pub fn census(game_dir: &str) -> Result<String, String> {
    use std::collections::BTreeMap;
    let cache = std::rc::Rc::new(std::cell::RefCell::new(Cache::default()));
    let rt = Runtime::new(stellar_sim::Date::from_ymd(2200, 1, 1), 0).map_err(|e| format!("the Lua runtime: {e}"))?;
    crate::gui::install(&rt, game_dir, &cache).map_err(|e| format!("gui: {e}"))?;
    let t0 = std::time::Instant::now();
    let mut lib = Library::default();
    lib.ensure(&rt, game_dir)?;
    let names: Vec<String> = rt
        .lua
        .load("local t = {} for k in pairs(RENDER_MODELS.entities) do t[#t + 1] = k end table.sort(t) return t")
        .eval()
        .map_err(|e| e.to_string())?;
    let (mut ok, mut failed, mut empty) = (0, 0, 0);
    let mut why: BTreeMap<String, usize> = BTreeMap::new();
    let mut shaders: BTreeMap<String, usize> = BTreeMap::new();
    let mut skipped: BTreeMap<String, usize> = BTreeMap::new();
    let (mut textures, mut found) = (0, 0);
    let mut missing: BTreeMap<String, usize> = BTreeMap::new();
    let mut exists: HashMap<String, bool> = HashMap::new();
    let mut with_attach = 0;
    let mut examples: Vec<String> = Vec::new();
    for (i, name) in names.iter().enumerate() {
        if i % 400 == 0 {
            lib.forget();
        }
        match lib.model(&rt, game_dir, name) {
            Ok(m) => {
                ok += 1;
                if m.parts.is_empty() {
                    empty += 1;
                }
                if !m.attach.is_empty() {
                    with_attach += 1;
                }
                for p in &m.parts {
                    *shaders.entry(p.shader.clone()).or_default() += 1;
                    for t in &p.textures {
                        if t.is_empty() {
                            continue;
                        }
                        textures += 1;
                        let e = *exists.entry(t.clone()).or_insert_with(|| dds::find_case_insensitive(game_dir, t).is_some());
                        if e {
                            found += 1;
                        } else {
                            *missing.entry(t.clone()).or_default() += 1;
                        }
                    }
                }
                for s in &m.skipped {
                    let shader = s.rsplit_once('(').map_or(s.as_str(), |(_, b)| b.trim_end_matches(')'));
                    *skipped.entry(shader.to_string()).or_default() += 1;
                }
            }
            Err(e) => {
                failed += 1;
                // the reason without the names
                let k = if e.contains("no pdxmesh (") {
                    "no pdxmesh: locator dummies, effects".to_string()
                } else if e.contains("is not defined") {
                    "the entity's pdxmesh is not defined".to_string()
                } else if e.contains("No such file") || e.contains("not found") {
                    "the mesh file is missing".to_string()
                } else {
                    e.chars().take(60).collect()
                };
                *why.entry(k).or_default() += 1;
                if examples.len() < 6 && (i % 97 == 0 || !e.contains("no pdxmesh (")) {
                    examples.push(e.clone());
                }
            }
        }
    }
    let mut out = format!(
        "{} entities of gfx/models (no portraits) in {:.1} s: {ok} loaded ({empty} with no drawn part: frames of locators, effects), {failed} not\n",
        names.len(),
        t0.elapsed().as_secs_f64()
    );
    out += &format!("  {with_attach} entities attach others at locators\n");
    for (k, n) in &why {
        out += &format!("  not loaded: {n:>5} {k}\n");
    }
    for e in &examples {
        out += &format!("    e.g. {e}\n");
    }
    out += &format!("  textures named by the drawn parts: {textures}, found {found}, not found {}\n", textures - found);
    let mut miss: Vec<_> = missing.into_iter().collect();
    miss.sort_by(|a, b| b.1.cmp(&a.1));
    for (t, n) in miss.iter().take(8) {
        out += &format!("    not found {n:>4} x {t}\n");
    }
    let mut sh: Vec<_> = shaders.into_iter().collect();
    sh.sort_by(|a, b| b.1.cmp(&a.1));
    out += "  parts drawn by shader:";
    for (s, n) in sh.iter().take(16) {
        out += &format!(" {s} {n},");
    }
    out += "\n  parts skipped by shader:";
    let mut sk: Vec<_> = skipped.into_iter().collect();
    sk.sort_by(|a, b| b.1.cmp(&a.1));
    for (s, n) in sk.iter().take(12) {
        out += &format!(" {s} {n},");
    }
    out += "\n";
    Ok(out)
}
