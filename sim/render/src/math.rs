//! Small 3D math for the renderer: vectors and 4x4 matrices (row-major here, transposed for the
//! GPU, whose WGSL matrices are column-major), a right-handed look-at and a perspective projection
//! with depth in 0..1 (wgpu's clip space).

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3(pub f32, pub f32, pub f32);

impl V3 {
    pub fn add(self, o: V3) -> V3 {
        V3(self.0 + o.0, self.1 + o.1, self.2 + o.2)
    }
    pub fn sub(self, o: V3) -> V3 {
        V3(self.0 - o.0, self.1 - o.1, self.2 - o.2)
    }
    pub fn scale(self, s: f32) -> V3 {
        V3(self.0 * s, self.1 * s, self.2 * s)
    }
    pub fn dot(self, o: V3) -> f32 {
        self.0 * o.0 + self.1 * o.1 + self.2 * o.2
    }
    pub fn cross(self, o: V3) -> V3 {
        V3(self.1 * o.2 - self.2 * o.1, self.2 * o.0 - self.0 * o.2, self.0 * o.1 - self.1 * o.0)
    }
    pub fn len(self) -> f32 {
        self.dot(self).sqrt()
    }
    pub fn norm(self) -> V3 {
        let l = self.len();
        if l > 0.0 {
            self.scale(1.0 / l)
        } else {
            self
        }
    }
    pub fn arr(self) -> [f32; 3] {
        [self.0, self.1, self.2]
    }
}

/// A 4x4 matrix, rows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct M4(pub [[f32; 4]; 4]);

impl M4 {
    pub const IDENTITY: M4 = M4([[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]]);

    pub fn mul(&self, o: &M4) -> M4 {
        let mut r = [[0.0f32; 4]; 4];
        for (i, row) in r.iter_mut().enumerate() {
            for (j, v) in row.iter_mut().enumerate() {
                *v = (0..4).map(|k| self.0[i][k] * o.0[k][j]).sum();
            }
        }
        M4(r)
    }

    /// The matrix times (x, y, z, w).
    pub fn apply(&self, v: [f32; 4]) -> [f32; 4] {
        let mut r = [0.0f32; 4];
        for (i, out) in r.iter_mut().enumerate() {
            *out = (0..4).map(|k| self.0[i][k] * v[k]).sum();
        }
        r
    }

    /// For the GPU: column-major.
    pub fn cols(&self) -> [[f32; 4]; 4] {
        let mut c = [[0.0f32; 4]; 4];
        for (i, row) in self.0.iter().enumerate() {
            for (j, v) in row.iter().enumerate() {
                c[j][i] = *v;
            }
        }
        c
    }

    pub fn translation(t: V3) -> M4 {
        let mut m = M4::IDENTITY;
        m.0[0][3] = t.0;
        m.0[1][3] = t.1;
        m.0[2][3] = t.2;
        m
    }

    pub fn scaling(s: f32) -> M4 {
        let mut m = M4::IDENTITY;
        m.0[0][0] = s;
        m.0[1][1] = s;
        m.0[2][2] = s;
        m
    }

    /// A rotation about the y axis (radians).
    pub fn rotation_y(a: f32) -> M4 {
        let (s, c) = a.sin_cos();
        M4([[c, 0.0, s, 0.0], [0.0, 1.0, 0.0, 0.0], [-s, 0.0, c, 0.0], [0.0, 0.0, 0.0, 1.0]])
    }

    /// A rotation about the x axis (radians).
    pub fn rotation_x(a: f32) -> M4 {
        let (s, c) = a.sin_cos();
        M4([[1.0, 0.0, 0.0, 0.0], [0.0, c, -s, 0.0], [0.0, s, c, 0.0], [0.0, 0.0, 0.0, 1.0]])
    }

    /// A rotation from a unit quaternion (x, y, z, w).
    pub fn from_quat(q: [f32; 4]) -> M4 {
        let [x, y, z, w] = q;
        M4([
            [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w), 2.0 * (x * z + y * w), 0.0],
            [2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w), 0.0],
            [2.0 * (x * z - y * w), 2.0 * (y * z + x * w), 1.0 - 2.0 * (x * x + y * y), 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ])
    }

    /// A right-handed view matrix: the camera at `eye` looking at `at`.
    pub fn look_at(eye: V3, at: V3, up: V3) -> M4 {
        let f = at.sub(eye).norm();
        let s = f.cross(up).norm();
        let u = s.cross(f);
        M4([
            [s.0, s.1, s.2, -s.dot(eye)],
            [u.0, u.1, u.2, -u.dot(eye)],
            [-f.0, -f.1, -f.2, f.dot(eye)],
            [0.0, 0.0, 0.0, 1.0],
        ])
    }

    /// A left-handed look-at, the game's (MatrixLookAtLH, CCamera::UpdateMatrices): the view's z
    /// points from the eye to the target, x = up x z, y = z x x.
    pub fn look_at_lh(eye: V3, at: V3, up: V3) -> M4 {
        let z = at.sub(eye).norm();
        let x = up.cross(z).norm();
        let y = z.cross(x);
        M4([
            [x.0, x.1, x.2, -x.dot(eye)],
            [y.0, y.1, y.2, -y.dot(eye)],
            [z.0, z.1, z.2, -z.dot(eye)],
            [0.0, 0.0, 0.0, 1.0],
        ])
    }

    /// A left-handed perspective projection, depth 0 (near) .. 1 (far), w = the view's z: the
    /// game's (CCamera::UpdateMatrices: x scale = y scale / aspect, y scale = 1 / tan(fov / 2),
    /// z = f / (f - n), -n f / (f - n)).
    pub fn perspective_lh(fov_y: f32, aspect: f32, near: f32, far: f32) -> M4 {
        let ys = 1.0 / (fov_y / 2.0).tan();
        M4([
            [ys / aspect, 0.0, 0.0, 0.0],
            [0.0, ys, 0.0, 0.0],
            [0.0, 0.0, far / (far - near), -near * far / (far - near)],
            [0.0, 0.0, 1.0, 0.0],
        ])
    }

    /// A right-handed perspective projection, depth 0 (near) .. 1 (far).
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) -> M4 {
        let f = 1.0 / (fov_y / 2.0).tan();
        M4([
            [f / aspect, 0.0, 0.0, 0.0],
            [0.0, f, 0.0, 0.0],
            [0.0, 0.0, far / (near - far), near * far / (near - far)],
            [0.0, 0.0, -1.0, 0.0],
        ])
    }

    /// The inverse of an affine matrix (rotation, uniform scale and translation).
    pub fn inverse_affine(&self) -> M4 {
        let m = &self.0;
        // the 3x3 part's inverse by cofactors
        let a = [[m[0][0], m[0][1], m[0][2]], [m[1][0], m[1][1], m[1][2]], [m[2][0], m[2][1], m[2][2]]];
        let det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
        let id = if det.abs() > 1e-20 { 1.0 / det } else { 0.0 };
        let inv = [
            [
                (a[1][1] * a[2][2] - a[1][2] * a[2][1]) * id,
                (a[0][2] * a[2][1] - a[0][1] * a[2][2]) * id,
                (a[0][1] * a[1][2] - a[0][2] * a[1][1]) * id,
            ],
            [
                (a[1][2] * a[2][0] - a[1][0] * a[2][2]) * id,
                (a[0][0] * a[2][2] - a[0][2] * a[2][0]) * id,
                (a[0][2] * a[1][0] - a[0][0] * a[1][2]) * id,
            ],
            [
                (a[1][0] * a[2][1] - a[1][1] * a[2][0]) * id,
                (a[0][1] * a[2][0] - a[0][0] * a[2][1]) * id,
                (a[0][0] * a[1][1] - a[0][1] * a[1][0]) * id,
            ],
        ];
        let t = [m[0][3], m[1][3], m[2][3]];
        let mut r = M4::IDENTITY;
        for i in 0..3 {
            for j in 0..3 {
                r.0[i][j] = inv[i][j];
            }
            r.0[i][3] = -(inv[i][0] * t[0] + inv[i][1] * t[1] + inv[i][2] * t[2]);
        }
        r
    }
}
