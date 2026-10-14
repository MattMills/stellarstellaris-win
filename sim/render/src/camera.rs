//! The 3D view: the game's camera over the galactic plane, and the view parameters a scene is
//! drawn with (the view-projection matrix, the camera's axes for billboards, the eye, the light).
//!
//! The camera is the game's CGameCamera (4.5.2, read from the code and checked against the game's
//! frames, docs/render.md section 10) **[V]**: it orbits a target at `distance`, `pitch` above the
//! plane and `yaw` around it, the eye at target + distance (-cos p sin y, sin p, cos p cos y); the
//! view is left-handed (MatrixLookAtLH: z from the eye to the target), the projection a
//! left-handed perspective with a vertical field of view of NCamera.FOV = 35 degrees and depth
//! 0..1. World space: the galactic plane is y = 0 and a save's map coordinate (x, y) is the point
//! (x, 0, y), in map units (the game's world is them x GALAXY_SPACE_SCALE_MULT = 2 on the galaxy,
//! x SYSTEM_SPACE_SCALE_MULT = 10 in a system: the same picture). At yaw 0 the screen's right is
//! -x and its top -y: the save's x grows to the left and its y downwards, as the game shows them.
//! The galaxy camera is pitched between NCamera.GALAXY_MIN_PITCH (30) and GALAXY_MAX_PITCH (85)
//! degrees (57.5 on a load), a system's between SYSTEM_MIN_PITCH (20) and SYSTEM_MAX_PITCH (80).

use crate::math::{M4, V3};

#[derive(Clone, Copy, Debug)]
pub struct OrbitCamera {
    pub target: V3,
    /// radians: 0 = the eye on the +z side of the target (the game's CGameCamera +0x22c)
    pub yaw: f32,
    /// radians above the plane
    pub pitch: f32,
    pub distance: f32,
    pub fov_y: f32,
    pub min_distance: f32,
    pub max_distance: f32,
    pub min_pitch: f32,
    pub max_pitch: f32,
}

impl OrbitCamera {
    /// A camera that shows a disc of `radius` around the origin, pitched like the game's.
    pub fn galaxy(radius: f32) -> OrbitCamera {
        let fov_y = 35f32.to_radians();
        let distance = radius / (fov_y / 2.0).tan() * 1.05;
        OrbitCamera {
            target: V3(0.0, 0.0, 0.0),
            yaw: 0.0,
            pitch: 57.5f32.to_radians(),
            distance,
            fov_y,
            min_distance: 20.0,
            max_distance: distance * 3.0,
            min_pitch: 30f32.to_radians(),
            max_pitch: 85f32.to_radians(),
        }
    }

    /// A camera over a system of `radius` around its centre (the system's own space): its
    /// orbits filling the height of the screen at 40 degrees.
    pub fn system(radius: f32) -> OrbitCamera {
        let mut c = OrbitCamera::galaxy(radius);
        c.pitch = 50f32.to_radians();
        c.distance *= 0.62;
        c.min_distance = 2.0;
        c.min_pitch = 20f32.to_radians();
        c.max_pitch = 80f32.to_radians();
        c
    }

    pub fn eye(&self) -> V3 {
        let (sy, cy) = self.yaw.sin_cos();
        let (sp, cp) = self.pitch.sin_cos();
        // CGameCamera::UpdateInternalCamera
        self.target.add(V3(-cp * sy, sp, cp * cy).scale(self.distance))
    }

    pub fn orbit(&mut self, dyaw: f32, dpitch: f32) {
        self.yaw = (self.yaw + dyaw).rem_euclid(std::f32::consts::TAU);
        self.pitch = (self.pitch + dpitch).clamp(self.min_pitch, self.max_pitch);
    }

    /// The distance times `factor` (< 1 closer), within the limits.
    pub fn zoom(&mut self, factor: f32) {
        self.distance = (self.distance * factor).clamp(self.min_distance, self.max_distance);
    }

    /// Moves the target on the plane: `dx` to the screen's right, `dy` to its top, in fractions of
    /// the distance.
    pub fn pan(&mut self, dx: f32, dy: f32) {
        let (sy, cy) = self.yaw.sin_cos();
        // on the plane: the camera's forward (toward the target) and its right
        let forward = V3(sy, 0.0, -cy);
        let right = V3(-cy, 0.0, -sy);
        self.target = self.target.add(right.scale(dx * self.distance)).add(forward.scale(dy * self.distance));
    }

    pub fn view_params(&self, width: u32, height: u32) -> ViewParams {
        let eye = self.eye();
        let view = M4::look_at_lh(eye, self.target, V3(0.0, 1.0, 0.0));
        let near = (self.distance * 0.01).max(0.05);
        let far = self.distance * 4.0 + 2000.0;
        let proj = M4::perspective_lh(self.fov_y, width.max(1) as f32 / height.max(1) as f32, near, far);
        ViewParams {
            view_proj: proj.mul(&view),
            right: V3(view.0[0][0], view.0[0][1], view.0[0][2]),
            up: V3(view.0[1][0], view.0[1][1], view.0[1][2]),
            eye,
            width,
            height,
            focal_px: proj.0[1][1] * height as f32 / 2.0,
            perspective: true,
        }
    }
}

/// What a scene is drawn with.
#[derive(Clone, Copy, Debug)]
pub struct ViewParams {
    pub view_proj: M4,
    /// the camera's right and up in world space (billboards)
    pub right: V3,
    pub up: V3,
    pub eye: V3,
    pub width: u32,
    pub height: u32,
    /// pixels per unit at distance 1 (perspective), or per unit (orthographic)
    pub focal_px: f32,
    pub perspective: bool,
}

impl ViewParams {
    /// The top-down orthographic view of the 2D map: ndc = (x * w[0] + w[2], z * w[1] + w[3]).
    pub fn orthographic(world_to_ndc: [f32; 4], width: u32, height: u32) -> ViewParams {
        let w = world_to_ndc;
        let view_proj = M4([[w[0], 0.0, 0.0, w[2]], [0.0, 0.0, w[1], w[3]], [0.0, 0.0, 0.0, 0.5], [0.0, 0.0, 0.0, 1.0]]);
        ViewParams {
            view_proj,
            right: V3(w[0].signum(), 0.0, 0.0),
            up: V3(0.0, 0.0, w[1].signum()),
            eye: V3(0.0, 1e6, 0.0),
            width,
            height,
            focal_px: w[1].abs() * height as f32 / 2.0,
            perspective: false,
        }
    }

    /// A world point -> pixels from the top left and its depth (0..1), or None behind the camera.
    pub fn project(&self, p: V3) -> Option<(f32, f32, f32)> {
        let c = self.view_proj.apply([p.0, p.1, p.2, 1.0]);
        if c[3] <= 1e-6 {
            return None;
        }
        let (nx, ny, nz) = (c[0] / c[3], c[1] / c[3], c[2] / c[3]);
        Some(((nx + 1.0) * 0.5 * self.width as f32, (1.0 - ny) * 0.5 * self.height as f32, nz))
    }

    /// Pixels per world unit at a point (for sizes on screen).
    pub fn pixels_per_unit(&self, p: V3) -> f32 {
        if !self.perspective {
            return self.focal_px;
        }
        let c = self.view_proj.apply([p.0, p.1, p.2, 1.0]);
        if c[3] <= 1e-6 {
            0.0
        } else {
            self.focal_px / c[3]
        }
    }
}
