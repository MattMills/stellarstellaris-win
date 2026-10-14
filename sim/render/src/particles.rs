//! The game's particle effects (gfx/particles: `lua/render/particles.lua` reads them), drawn as a
//! steady state: each subsystem's live particles (emission x mean life, at most max_amount) at
//! deterministic random places of its emitter, each at a random age over its life, its size and
//! alpha times the particle's animation curves at that age (size_grow, fade_in_out, ...), as
//! billboards of its texture, added (ParticleAdditive) or blended. What the game animates over
//! time (velocity, forces, trails) is not.

use std::collections::HashMap;

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::dds::Cache;
use crate::math::{M4, V3};
use crate::scene::{Blend, Layer, Quad, Rng, Textures};

/// An animation curve over a particle's life: min + (max - min) x the curve's value at the age
/// (its points (age, value) joined by lines).
#[derive(Clone, Debug)]
pub struct Curve {
    pub min: f32,
    pub max: f32,
    pub points: Vec<(f32, f32)>,
}

impl Curve {
    pub fn at(&self, t: f32) -> f32 {
        let p = &self.points;
        let v = match p.iter().position(|q| q.0 >= t) {
            None => p.last().map_or(1.0, |q| q.1),
            Some(0) => p[0].1,
            Some(i) => {
                let (a, b) = (p[i - 1], p[i]);
                let f = if b.0 > a.0 { (t - a.0) / (b.0 - a.0) } else { 0.0 };
                a.1 + (b.1 - a.1) * f
            }
        };
        self.min + (self.max - self.min) * v
    }
}

#[derive(Clone, Debug)]
pub struct Subsystem {
    pub name: String,
    pub count: usize,
    pub sphere: bool,
    pub radius: (f32, f32),
    pub yaw: (f32, f32),
    pub pitch: (f32, f32),
    pub texture: String,
    pub frames: (f32, f32),
    pub additive: bool,
    /// 0..1
    pub colour: [f32; 4],
    pub size: (f32, f32),
    pub rotation: (f32, f32),
    pub size_curve: Option<Curve>,
    pub alpha_curve: Option<Curve>,
}

#[derive(Clone, Debug)]
pub struct Effect {
    pub scale: f32,
    pub subsystems: Vec<Subsystem>,
}

#[derive(Default)]
pub struct Library {
    loaded: bool,
    effects: HashMap<String, Result<Effect, String>>,
}

fn pair(t: &Table, k: &str) -> mlua::Result<(f32, f32)> {
    let Some(v) = t.get::<Option<Table>>(k)? else { return Ok((0.0, 0.0)) };
    Ok((v.get::<Option<f32>>(1)?.unwrap_or(0.0), v.get::<Option<f32>>(2)?.unwrap_or(0.0)))
}

impl Library {
    pub fn effect(&mut self, rt: &Runtime, game_dir: &str, name: &str) -> Result<Effect, String> {
        if !self.loaded {
            let t0 = std::time::Instant::now();
            rt.lua
                .load(format!("if not RENDER_PARTICLES then RENDER_PARTICLES = require('render.particles').load({:?}) end", game_dir.replace('\\', "/")))
                .exec()
                .map_err(|e| format!("render.particles: {e}"))?;
            eprintln!("particles: gfx/particles read in {:.1} s", t0.elapsed().as_secs_f64());
            self.loaded = true;
        }
        if let Some(e) = self.effects.get(name) {
            return e.clone();
        }
        let read = || -> mlua::Result<Result<Effect, String>> {
            let (t, why): (Option<Table>, Option<String>) = rt.lua.load(format!("return require('render.particles').describe(RENDER_PARTICLES, {name:?})")).eval()?;
            let Some(t) = t else { return Ok(Err(why.unwrap_or_default())) };
            let curves: Table = t.get("curves")?;
            let curve = |name: Option<String>| -> mlua::Result<Option<Curve>> {
                let Some(name) = name else { return Ok(None) };
                let Some(c) = curves.get::<Option<Table>>(name)? else { return Ok(None) };
                let flat: Vec<f32> = c.get::<Table>("points")?.sequence_values::<f32>().collect::<mlua::Result<_>>()?;
                Ok(Some(Curve { min: c.get("min")?, max: c.get("max")?, points: flat.chunks_exact(2).map(|p| (p[0], p[1])).collect() }))
            };
            let mut subsystems = Vec::new();
            for s in t.get::<Table>("subsystems")?.sequence_values::<Table>() {
                let s = s?;
                if s.get::<bool>("hide")? || s.get::<bool>("trail")? {
                    continue;
                }
                let life = pair(&s, "life")?;
                let emission: f32 = s.get("emission")?;
                let max: f32 = s.get("max_amount")?;
                let count = (emission * (life.0 + 0.5 * life.1)).min(max).max(0.0) as usize;
                let c: Table = s.get("colour")?;
                // x 0.8: particle.shader's PixelParticle ("reduces bloom")
                let colour = [c.get::<f32>(1)? / 255.0, c.get::<f32>(2)? / 255.0, c.get::<f32>(3)? / 255.0, c.get::<f32>(4)? / 255.0 * 0.8];
                let size_curve = curve(s.get::<Option<Table>>("size")?.map(|t| t.get::<Option<String>>("curve")).transpose()?.flatten())?;
                let alpha_curve = curve(s.get("alpha_curve")?)?;
                let shader: String = s.get("shader")?;
                subsystems.push(Subsystem {
                    name: s.get("name")?,
                    count,
                    sphere: s.get::<String>("emitter")? == "sphere",
                    radius: pair(&s, "radius")?,
                    yaw: pair(&s, "yaw")?,
                    pitch: pair(&s, "pitch")?,
                    texture: s.get("texture")?,
                    frames: (s.get::<f32>("frames_x")?.max(1.0), s.get::<f32>("frames_y")?.max(1.0)),
                    additive: shader.to_ascii_lowercase().contains("additive"),
                    colour,
                    size: pair(&s, "size")?,
                    rotation: pair(&s, "rotation")?,
                    size_curve,
                    alpha_curve,
                });
            }
            Ok(Ok(Effect { scale: t.get::<Option<f32>>("scale")?.unwrap_or(1.0), subsystems }))
        };
        let r = read().map_err(|e| format!("render.particles: {e}"))?;
        self.effects.insert(name.to_string(), r.clone());
        r
    }
}

/// The billboards of an effect at an entity's `transform` (its scale scales the particles), as
/// (layer, blend, texture, quad).
pub fn billboards(effect: &Effect, transform: &M4, seed: u32, tex: &mut Textures, cache: &mut Cache, game_dir: &str) -> Vec<(Layer, Blend, usize, Quad)> {
    let mut out = Vec::new();
    let unit = transform.apply([1.0, 0.0, 0.0, 0.0]);
    let scale = V3(unit[0], unit[1], unit[2]).len() * effect.scale;
    for (k, s) in effect.subsystems.iter().enumerate() {
        let Some(t) = tex.game(cache, game_dir, &s.texture) else { continue };
        let mut rng = Rng(seed ^ (k as u32 + 1).wrapping_mul(0x9e37_79b9));
        let uv = [0.0, 0.0, 1.0 / s.frames.0, 1.0 / s.frames.1];
        for _ in 0..s.count {
            let r = s.radius.0 + s.radius.1 * rng.next();
            let local = if s.sphere {
                let yaw = (s.yaw.0 + s.yaw.1 * (2.0 * rng.next() - 1.0)).to_radians();
                let pitch = (s.pitch.0 + s.pitch.1 * (2.0 * rng.next() - 1.0)).to_radians();
                [r * pitch.cos() * yaw.cos(), r * pitch.sin(), r * pitch.cos() * yaw.sin(), 1.0]
            } else {
                [0.0, 0.0, 0.0, 1.0]
            };
            let p = transform.apply(local);
            // its age over its life, and the curves there
            let age = rng.next();
            let grow = s.size_curve.as_ref().map_or(1.0, |c| c.at(age));
            let fade = s.alpha_curve.as_ref().map_or(1.0, |c| c.at(age));
            let size = (s.size.0 + s.size.1 * rng.next()) * scale * grow;
            let rot = (s.rotation.0 + s.rotation.1 * (2.0 * rng.next() - 1.0)).to_radians();
            let colour = [s.colour[0], s.colour[1], s.colour[2], s.colour[3] * fade];
            let mut q = Quad::billboard(p[0], p[2], p[1], size * 0.5, colour, rot, 0.0);
            q.uv = uv;
            out.push((Layer::Stars, if s.additive { Blend::Add } else { Blend::Alpha }, t, q));
        }
    }
    out
}
