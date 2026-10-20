//! The game's particle effects (gfx/particles: `lua/render/particles.lua` reads them), drawn as a
//! steady state: each subsystem's live particles (emission x mean life, at most max_amount) at
//! deterministic random places of its emitter, each at a random age over its life, its size and
//! alpha times the particle's animation curves at that age (size_grow, fade_in_out, ...), as
//! billboards of its texture, added (ParticleAdditive) or blended. Over time (map.wgsl vs_quad,
//! the view's time): each particle's age goes round its life from its random start, its alpha
//! and size curves at that age, its rotation at rotation_speed; it stays where it was placed (a
//! new place each life, velocity, forces and trails are not done) [I].

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
    /// degrees a second
    pub rotation_speed: (f32, f32),
    /// seconds
    pub life: (f32, f32),
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
    /// gfx/particles read (once): what a star's first system view read in its frame (330 ms on
    /// 10.5.0.24), read with the load (Map::warm).
    pub fn ensure(&mut self, rt: &Runtime, game_dir: &str) {
        let _ = self.effect(rt, game_dir, "");
    }

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
                    rotation_speed: pair(&s, "rotation_speed")?,
                    life,
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
            // over time (map.wgsl's particle mode): its life and spin, the curves packed
            let life = (s.life.0 + s.life.1 * (2.0 * rng.next() - 1.0)).max(0.05);
            let spin = (s.rotation_speed.0 + s.rotation_speed.1 * (2.0 * rng.next() - 1.0)).to_radians();
            if let (Some(alpha), Some(sz)) = (packed(s.alpha_curve.as_ref(), 4), packed(s.size_curve.as_ref(), 2)) {
                let base = size / grow.max(1e-3);
                q = Quad::billboard(p[0], p[2], p[1], base * 0.5, [s.colour[0], s.colour[1], s.colour[2], s.colour[3]], rot, sz[1]);
                q.uv = uv;
                q.fx = [5.0 + 0.4 * age, 1.0 / life, spin, sz[0]];
                q.fx2 = [alpha[0], alpha[1], alpha[2], alpha[3]];
            }
            out.push((Layer::Stars, if s.additive { Blend::Add } else { Blend::Alpha }, t, q));
        }
    }
    out
}

/// A curve's points for map.wgsl's particle mode: up to `n` points (age, value), each packed into
/// one float (the age in 10 bits, the value 0 .. 8 in 13: exact in an f32), the value with the
/// curve's min and max applied, the last repeated to `n`; none (no curve: constant 1) gives
/// (0, 1) .. (1, 1). None when it does not fit (more points, values outside 0 .. 8).
fn packed(c: Option<&Curve>, n: usize) -> Option<Vec<f32>> {
    let pts: Vec<(f32, f32)> = match c {
        None => vec![(0.0, 1.0), (1.0, 1.0)],
        Some(c) => c.points.iter().map(|&(x, v)| (x, c.min + (c.max - c.min) * v)).collect(),
    };
    if pts.is_empty() || pts.len() > n || pts.iter().any(|&(x, y)| !(0.0..=1.0).contains(&x) || !(0.0..8.0).contains(&y)) {
        return None;
    }
    let pack = |(x, y): (f32, f32)| ((x * 1023.0).round() * 8192.0 + (y * 1023.0).round()) as f32;
    let mut out: Vec<f32> = pts.iter().map(|&p| pack(p)).collect();
    while out.len() < n {
        out.push(*out.last().unwrap());
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curves_pack_exactly() {
        let c = Curve { min: 1.0, max: 3.0, points: vec![(0.0, 0.0), (1.0, 1.0)] };
        let p = packed(Some(&c), 2).unwrap();
        let v = p[1] as u32;
        assert_eq!(v / 8192, 1023);
        assert_eq!(v % 8192, 3069);
        assert_eq!(packed(None, 4).unwrap().len(), 4);
        let big = Curve { min: 0.0, max: 9.0, points: vec![(0.0, 1.0)] };
        assert!(packed(Some(&big), 4).is_none());
    }
}
