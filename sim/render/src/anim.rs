//! The game's mesh animations (gfx/models/**/*.anim: binary pdx assets, read by pdxmesh.rs) as
//! far as the renderer plays them: the rotation of a joint a part is skinned to as a whole, a
//! turn about a fixed axis after a fixed rotation (the stars' and planets' idle animations:
//! base_star_idle.anim, the `planet` joint turning once in about 370 s, easing in and out, then
//! resting until the loop's end; the planets' turn once in 333 s, their axial tilt the
//! animation's rest of `planet_rotation`) **[V]** the files, **[I]** how the game blends and
//! loops them.
//!
//! An .anim: `[info]` (`fps`, `sa` the samples, `j` the joints; a child per joint: `sa` which of
//! t, q, s are sampled, and its rest `t`, `q` (x y z w), `s`) and `[samples]` (`q`, `t`, `s`: each
//! frame's values of the sampled joints, in the joints' order).
//!
//! The skinning (column vectors, as the matrices are stored): a vertex goes by the joint's world
//! rotation in the animation times its inverse bind pose (the mesh skeleton's `tx`, a 3x4 stored by
//! columns): S(t) = P R(q(t)) B, P the ancestors' rest rotations, the root first. With the
//! joint's turn dq(t) = q(t) q_rest^-1 that is D(t) K: D(t) = P dq(t) P^-1 a turn about a fixed axis
//! (the mesh's space), K = P R(q_rest) B fixed (the identity for the stars, whose animation rests
//! in the bind pose; the planets' tilt) **[V]: the star's S is the identity at rest only so**.

use crate::math::M4;
use crate::pdxmesh;

/// A part's rotation over time: `base` (a 3x3, by columns), then a turn about `axis` (the mesh's
/// space), `angles` (radians) at `fps` times `rate` (the entity's playback_rate; < 0 backwards),
/// looped.
#[derive(Clone, Debug)]
pub struct Spin {
    pub axis: [f32; 3],
    pub fps: f32,
    pub angles: Vec<f32>,
    pub base: [[f32; 3]; 3],
    pub rate: f32,
}

impl Spin {
    /// The turn's angle at `t` seconds (linear between the samples; the loop starts again at its
    /// end, backwards with a negative rate).
    pub fn angle_at(&self, t: f32) -> f32 {
        let n = self.angles.len();
        if n < 2 || self.fps <= 0.0 {
            return self.angles.first().copied().unwrap_or(0.0);
        }
        let f = (t * self.rate * self.fps).rem_euclid(n as f32);
        let i = (f.floor() as usize).min(n - 1);
        let k = f - i as f32;
        let a = self.angles[i];
        let b = if i + 1 < n { self.angles[i + 1] } else { a };
        a + (b - a) * k
    }

    /// The part's rotation at `t` seconds (the mesh's space): the turn after the base.
    pub fn matrix_at(&self, t: f32) -> M4 {
        let half = 0.5 * self.angle_at(t);
        let s = half.sin();
        let turn = M4::from_quat([self.axis[0] * s, self.axis[1] * s, self.axis[2] * s, half.cos()]);
        let b = self.base;
        let base = M4([
            [b[0][0], b[1][0], b[2][0], 0.0],
            [b[0][1], b[1][1], b[2][1], 0.0],
            [b[0][2], b[1][2], b[2][2], 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ]);
        turn.mul(&base)
    }
}

type Q = [f32; 4];

fn qmul(a: Q, b: Q) -> Q {
    let [ax, ay, az, aw] = a;
    let [bx, by, bz, bw] = b;
    [
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ]
}

fn conj(a: Q) -> Q {
    [-a[0], -a[1], -a[2], a[3]]
}

/// The spin of `joint` (its ancestors `parents`, the root first; `bind` its inverse bind pose,
/// the mesh skeleton's `tx`) in an animation played at `rate`; none when the joint's rotation is
/// not sampled, does not turn, or turns about more than one axis.
pub fn joint_spin(anim: &pdxmesh::Node, joint: &str, parents: &[String], bind: &[f32; 12], rate: f32) -> Option<Spin> {
    let info = anim.child("info")?;
    let fps = info.prop("fps")?.floats().first().copied()?;
    let frames = info.prop("sa")?.ints().first().copied()? as usize;
    let samples = anim.child("samples")?;
    let qs = samples.prop("q").map(|v| v.floats()).unwrap_or(&[]);
    // the joints whose rotation is sampled, in order: the joint's place among them
    let mut sampled = 0usize;
    let mut slot = None;
    let mut rest: Option<Q> = None;
    let mut parent_rest: Vec<(String, Q)> = Vec::new();
    for j in &info.children {
        let q = j.prop("q").map(|v| v.floats()).filter(|f| f.len() == 4).map(|f| [f[0], f[1], f[2], f[3]]);
        let turns = j.prop("sa").and_then(|v| v.first_str()).is_some_and(|s| s.contains('q'));
        if j.name == joint {
            rest = q;
            if turns {
                slot = Some(sampled);
            }
        } else if let Some(q) = q {
            parent_rest.push((j.name.clone(), q));
        }
        if turns {
            sampled += 1;
        }
    }
    let (slot, rest) = (slot?, rest?);
    if sampled == 0 || qs.len() < frames * sampled * 4 || frames < 2 {
        return None;
    }
    // the ancestors' rest rotations, the root first
    let mut p: Q = [0.0, 0.0, 0.0, 1.0];
    for name in parents {
        if let Some((_, q)) = parent_rest.iter().find(|(n, _)| n == name) {
            p = qmul(p, *q);
        }
    }
    // each frame's turn from the rest in the mesh's space: P q(f) rest^-1 P^-1
    let deltas: Vec<Q> = (0..frames)
        .map(|f| {
            let o = (f * sampled + slot) * 4;
            let q = [qs[o], qs[o + 1], qs[o + 2], qs[o + 3]];
            qmul(qmul(p, qmul(q, conj(rest))), conj(p))
        })
        .collect();
    // the axis: the largest turn's
    let big = deltas.iter().max_by(|a, b| {
        let la = a[0] * a[0] + a[1] * a[1] + a[2] * a[2];
        let lb = b[0] * b[0] + b[1] * b[1] + b[2] * b[2];
        la.total_cmp(&lb)
    })?;
    let len = (big[0] * big[0] + big[1] * big[1] + big[2] * big[2]).sqrt();
    if len < 1e-4 {
        return None;
    }
    let axis = [big[0] / len, big[1] / len, big[2] / len];
    // the angles about it, made continuous (q and -q are one rotation)
    let mut angles = Vec::with_capacity(frames);
    let mut prev = 0.0f32;
    for d in &deltas {
        let along = d[0] * axis[0] + d[1] * axis[1] + d[2] * axis[2];
        let off = ((d[0] - along * axis[0]).powi(2) + (d[1] - along * axis[1]).powi(2) + (d[2] - along * axis[2]).powi(2)).sqrt();
        if off > 1e-2 {
            return None;
        }
        let mut a = 2.0 * along.atan2(d[3]);
        // the nearest of a + k x 2 pi to the angle before
        let tau = std::f32::consts::TAU;
        a += tau * ((prev - a) / tau).round();
        angles.push(a);
        prev = a;
    }
    // K = P R(rest) B (B: the 3x3 of `tx`, stored by columns)
    let pr = M4::from_quat(qmul(p, rest));
    let b = M4([
        [bind[0], bind[3], bind[6], 0.0],
        [bind[1], bind[4], bind[7], 0.0],
        [bind[2], bind[5], bind[8], 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]);
    let k = pr.mul(&b);
    let base = [[k.0[0][0], k.0[1][0], k.0[2][0]], [k.0[0][1], k.0[1][1], k.0[2][1]], [k.0[0][2], k.0[1][2], k.0[2][2]]];
    Some(Spin { axis, fps, angles, base, rate })
}

/// The spin of a sub-mesh skinned wholly to one bone (every vertex's first influence that bone,
/// weight 1), its bone and ancestors named by the shape's skeleton; `rate` the entity's
/// playback_rate.
pub fn part_spin(anim: &pdxmesh::Node, skin: &pdxmesh::Skin, skeleton: &[pdxmesh::Bone], rate: f32) -> Option<Spin> {
    let first = *skin.ix.first()?;
    let rigid = skin.ix.chunks(4).zip(skin.w.chunks(4)).all(|(ix, w)| ix.first() == Some(&first) && w.first().is_some_and(|w| (*w - 1.0).abs() < 1e-3));
    if !rigid {
        return None;
    }
    let bone = skeleton.iter().find(|b| b.ix == first)?;
    let mut parents = Vec::new();
    let mut p = bone.parent;
    while let Some(ix) = p {
        let Some(b) = skeleton.iter().find(|b| b.ix == ix) else { break };
        parents.push(b.name.clone());
        p = b.parent;
    }
    parents.reverse();
    joint_spin(anim, &bone.name, &parents, &bone.tx, rate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn angle_interpolates_and_loops() {
        let s = Spin { axis: [0.0, 1.0, 0.0], fps: 2.0, angles: vec![0.0, 1.0, 2.0, 3.0], base: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], rate: 1.0 };
        assert!((s.angle_at(0.25) - 0.5).abs() < 1e-6);
        assert!((s.angle_at(1.5) - 3.0).abs() < 1e-6);
        // the loop: 4 samples at 2 fps last 2 s
        assert!((s.angle_at(2.25) - 0.5).abs() < 1e-6);
        // backwards
        let r = Spin { rate: -1.0, ..s.clone() };
        assert!((r.angle_at(0.75) - 2.5).abs() < 1e-6);
        let m = s.matrix_at(0.0);
        assert!((m.0[0][0] - 1.0).abs() < 1e-6);
    }
}
