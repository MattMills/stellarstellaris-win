//! The game's mesh animations (gfx/models/**/*.anim: binary pdx assets, read by pdxmesh.rs) as
//! far as the renderer plays them: the turn of a joint a part is skinned to as a whole, about a
//! fixed axis (the stars' idle animation, base_star_idle.anim: the `planet` joint turns once in
//! about 370 s, easing in and out, then rests until the loop's end) **[V]** the file, **[I]** how
//! the game blends and loops it.
//!
//! An .anim: `[info]` (`fps`, `sa` the samples, `j` the joints; a child per joint: `sa` which of
//! t, q, s are sampled, and its rest `t`, `q` (x y z w), `s`) and `[samples]` (`q`, `t`, `s`: each
//! frame's values of the sampled joints, in the joints' order).

use crate::math::M4;
use crate::pdxmesh;

/// A part's turn over time: about `axis` (the mesh's space), `angles` (radians) at `fps`, looped.
#[derive(Clone, Debug)]
pub struct Spin {
    pub axis: [f32; 3],
    pub fps: f32,
    pub angles: Vec<f32>,
}

impl Spin {
    /// The angle at `t` seconds (linear between the samples; the loop starts again at its end).
    pub fn angle_at(&self, t: f32) -> f32 {
        let n = self.angles.len();
        if n < 2 || self.fps <= 0.0 {
            return self.angles.first().copied().unwrap_or(0.0);
        }
        let f = (t.max(0.0) * self.fps) % n as f32;
        let i = (f.floor() as usize).min(n - 1);
        let k = f - i as f32;
        let a = self.angles[i];
        let b = if i + 1 < n { self.angles[i + 1] } else { a };
        a + (b - a) * k
    }

    /// The turn at `t` seconds as a rotation matrix (the mesh's space).
    pub fn matrix_at(&self, t: f32) -> M4 {
        let half = 0.5 * self.angle_at(t);
        let s = half.sin();
        M4::from_quat([self.axis[0] * s, self.axis[1] * s, self.axis[2] * s, half.cos()])
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

/// The spin of `joint` (its ancestors `parents`, the root first: their rest rotations carry the
/// joint's turn into the mesh's space) in an animation; none when the joint is not sampled, does
/// not turn, or turns about more than one axis.
pub fn joint_spin(anim: &pdxmesh::Node, joint: &str, parents: &[String]) -> Option<Spin> {
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
    // the ancestors' rest rotations as the row vectors meet them: the nearest parent first
    let mut w: Q = [0.0, 0.0, 0.0, 1.0];
    for p in parents.iter().rev() {
        if let Some((_, q)) = parent_rest.iter().find(|(n, _)| n == p) {
            w = qmul(w, *q);
        }
    }
    // each frame's turn from the rest, in the mesh's space. The game's rotations act on row
    // vectors (v x R, the joint's before its parents'): as column-vector quaternions they are
    // the conjugates in reverse order, w^-1 q(f)^-1 rest w [V: the game's frames; w q rest^-1
    // w^-1 turned a molten planet the other way]
    let deltas: Vec<Q> = (0..frames)
        .map(|f| {
            let o = (f * sampled + slot) * 4;
            let q = [qs[o], qs[o + 1], qs[o + 2], qs[o + 3]];
            qmul(qmul(conj(w), qmul(conj(q), rest)), w)
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
    Some(Spin { axis, fps, angles })
}

/// The spin of a sub-mesh skinned wholly to one bone (every vertex's first influence that bone,
/// weight 1), its bone and ancestors named by the shape's skeleton.
pub fn part_spin(anim: &pdxmesh::Node, skin: &pdxmesh::Skin, skeleton: &[pdxmesh::Bone]) -> Option<Spin> {
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
    joint_spin(anim, &bone.name, &parents)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn angle_interpolates_and_loops() {
        let s = Spin { axis: [0.0, 1.0, 0.0], fps: 2.0, angles: vec![0.0, 1.0, 2.0, 3.0] };
        assert!((s.angle_at(0.25) - 0.5).abs() < 1e-6);
        assert!((s.angle_at(1.5) - 3.0).abs() < 1e-6);
        // the loop: 4 samples at 2 fps last 2 s
        assert!((s.angle_at(2.25) - 0.5).abs() < 1e-6);
        let m = s.matrix_at(std::f32::consts::FRAC_PI_2 * 0.0);
        assert!((m.0[0][0] - 1.0).abs() < 1e-6);
    }
}
