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

// The game's camera input (CGameCamera, 4.5.2 Linux, read from the code; docs/render.md section
// 12) **[V]**: input moves the target orientation, the camera follows it smoothly.

/// NCamera.EDGE_SCROLLING_PIXELS: the cursor this near the screen's edge scrolls the map.
pub const EDGE_SCROLLING_PIXELS: f32 = 3.0;
/// Scrolling's speed, the camera's distance a second (UpdateScrollingMovement): the setting
/// scroll_speed (50) x NCamera.SCROLL_SPEED (0.035) x tan(FOV / 2).
pub const SCROLL_SPEED: f32 = 50.0 * 0.035 * 0.315_299_2;
/// SCameraOffset::SmoothChangeTowards: a frame covers min(dt x 6.67, 1) of the way.
pub const SMOOTHING_PER_SECOND: f32 = 6.666_666_5;
/// NCamera.ROTATION_RADIANS_PER_MOUSE_UNIT (x camera_look_sensitivity, 1): a pixel of the
/// mouse turns the camera this much.
pub const ROTATION_RADIANS_PER_MOUSE_UNIT: f32 = 0.004;
/// NCamera.MOUSE_MOVEMENT_TO_START_ROTATION_SQ: a drag starts this far (squared pixels) from the
/// press.
pub const MOUSE_MOVEMENT_TO_START_ROTATION_SQ: f32 = 16.0;
/// NCamera.KEYBOARD_ZOOM_RATE x FOCUSED_ZOOM_RATE: Page Up and Page Down zoom by this share of
/// the distance a second.
pub const KEYBOARD_ZOOM: f32 = 7.5 * 0.2;
/// NCamera.ZOOM_STEPS_GALAXY (the game's world) in map units.
pub const GALAXY_ZOOM_STEPS: [f32; 7] = [50.0, 100.0, 200.0, 300.0, 450.0, 750.0, 1500.0];

/// Where the camera's target may go (RestrictOrientation): the galaxy's box (each coordinate
/// within +-500 map units), a system's sphere (its outer radius + SYSTEM_CAMERA_RESTRICT_
/// EXTRA_SPACE).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Bounds {
    None,
    Box(f32),
    Sphere(f32),
}

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
    /// the zoom steps (camera distances, map units) the wheel moves between, if any, and the
    /// step it is at (CGameCamera +0x24c)
    pub zoom_steps: Option<[f32; 7]>,
    pub zoom_index: usize,
    pub bounds: Bounds,
}

impl OrbitCamera {
    /// The galaxy's camera as the game makes it (ResetToDefaultCamera): at the centre, pitch
    /// 57.5 (the middle of GALAXY_MIN_PITCH and GALAXY_MAX_PITCH), the last zoom step.
    pub fn galaxy_default() -> OrbitCamera {
        OrbitCamera {
            target: V3(0.0, 0.0, 0.0),
            yaw: 0.0,
            pitch: 57.5f32.to_radians(),
            distance: GALAXY_ZOOM_STEPS[6],
            fov_y: 35f32.to_radians(),
            min_distance: GALAXY_ZOOM_STEPS[0],
            max_distance: GALAXY_ZOOM_STEPS[6],
            min_pitch: 30f32.to_radians(),
            max_pitch: 85f32.to_radians(),
            zoom_steps: Some(GALAXY_ZOOM_STEPS),
            zoom_index: 6,
            bounds: Bounds::Box(500.0),
        }
    }

    /// A camera that shows a disc of `radius` around the origin, pitched like the game's (for
    /// views without the game's steps: the 2D map, models).
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
            zoom_steps: None,
            zoom_index: 0,
            bounds: Bounds::None,
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
        self.sync_index();
    }

    /// The zoom step: the first at least the distance (UpdateZoom).
    fn sync_index(&mut self) {
        if let Some(s) = self.zoom_steps {
            self.zoom_index = s.iter().position(|&v| v >= self.distance * 0.9999).unwrap_or(s.len() - 1);
        }
    }

    /// Moves the target on the plane: `dx` to the screen's right, `dy` to its top, in fractions of
    /// the distance.
    pub fn pan(&mut self, dx: f32, dy: f32) {
        let (sy, cy) = self.yaw.sin_cos();
        // on the plane: the camera's forward (toward the target) and its right
        let forward = V3(sy, 0.0, -cy);
        let right = V3(-cy, 0.0, -sy);
        self.target = self.target.add(right.scale(dx * self.distance)).add(forward.scale(dy * self.distance));
        self.restrict();
    }

    /// The target kept within the bounds (RestrictOrientation).
    pub fn restrict(&mut self) {
        match self.bounds {
            Bounds::None => {}
            Bounds::Box(r) => self.target = V3(self.target.0.clamp(-r, r), self.target.1.clamp(-r, r), self.target.2.clamp(-r, r)),
            Bounds::Sphere(r) => {
                let l = self.target.len();
                if l > r {
                    self.target = self.target.scale(r / l);
                }
            }
        }
    }

    /// The mouse wheel (UpdateZoom, SetTargetZoom): one zoom step in (`notches` > 0) or out a
    /// frame, the target scaled about `ground` (the plane's point under the cursor, which stays
    /// under it); without steps a factor of 0.85 a notch.
    pub fn wheel(&mut self, notches: f32, ground: Option<V3>) {
        let Some(steps) = self.zoom_steps else {
            self.zoom(0.85f32.powf(notches));
            return;
        };
        if notches == 0.0 {
            return;
        }
        let delta: i32 = if notches > 0.0 { -1 } else { 1 };
        let k = (self.zoom_index as i32 + delta).clamp(0, steps.len() as i32 - 1) as usize;
        let new = steps[k].clamp(self.min_distance, self.max_distance);
        if let Some(p) = ground {
            let f = 1.0 - new / self.distance.max(1e-6);
            self.target = self.target.add(p.sub(self.target).scale(f));
            self.restrict();
        }
        self.zoom_index = k;
        self.distance = new;
    }

    /// Page Up and Page Down held (UpdateZoom's continuous zoom): `dir` (> 0 in) over `dt`, by
    /// the distance `current` the camera is at; the step follows.
    pub fn zoom_keys(&mut self, dir: f32, dt: f32, current: f32) {
        self.distance = (self.distance - dir * KEYBOARD_ZOOM * dt * current).clamp(self.min_distance, self.max_distance);
        self.sync_index();
    }

    /// Scrolling (the keys held, the cursor at the screen's edge): `dx` right, `dy` up (the
    /// input's sum, not normalised), over `dt` seconds, in proportion to the distance.
    pub fn scroll(&mut self, dx: f32, dy: f32, dt: f32) {
        let k = SCROLL_SPEED * dt;
        self.pan(dx * k, dy * k);
    }

    /// The galaxy's yaw springs back to 0 a frame after a turn (UpdateRotation, the right button
    /// up): x 0.9 while a radian or more, else toward 0 by at most 0.1. Whether it moved.
    pub fn spring_yaw(&mut self) -> bool {
        let mut y = self.yaw.rem_euclid(std::f32::consts::TAU);
        if y > std::f32::consts::PI {
            y -= std::f32::consts::TAU;
        }
        if y == 0.0 {
            return false;
        }
        y = if y.abs() >= 1.0 { y * 0.9 } else { y - y.signum() * y.abs().min(0.1) };
        self.yaw = y.rem_euclid(std::f32::consts::TAU);
        true
    }

    /// Moves toward `goal` over `dt` seconds (UpdateOrientation: a lerp by min(dt x 6.67, 1) of
    /// the position, distance, pitch and yaw, the yaw the short way round; while the player drags
    /// or turns, the position on the plane and the angles at once). Whether it moved.
    pub fn approach(&mut self, goal: &OrbitCamera, dt: f32, holding: bool) -> bool {
        let (zs, zi, mi, ma, mip, map, b) = (goal.zoom_steps, goal.zoom_index, goal.min_distance, goal.max_distance, goal.min_pitch, goal.max_pitch, goal.bounds);
        self.zoom_steps = zs;
        self.zoom_index = zi;
        self.min_distance = mi;
        self.max_distance = ma;
        self.min_pitch = mip;
        self.max_pitch = map;
        self.bounds = b;
        if self.at(goal) {
            let moved = self.target != goal.target || self.distance != goal.distance || self.yaw != goal.yaw || self.pitch != goal.pitch;
            *self = *goal;
            return moved;
        }
        let t = (dt * SMOOTHING_PER_SECOND).min(1.0);
        let lerp = |a: f32, b: f32| a * (1.0 - t) + b * t;
        let wrap = |a: f32| {
            let a = a.rem_euclid(std::f32::consts::TAU);
            if a > std::f32::consts::PI {
                a - std::f32::consts::TAU
            } else {
                a
            }
        };
        let (cy, mut gy) = (wrap(self.yaw), wrap(goal.yaw));
        if (gy - cy).abs() > std::f32::consts::PI {
            gy += if gy > cy { -std::f32::consts::TAU } else { std::f32::consts::TAU };
        }
        if holding {
            self.target = V3(goal.target.0, lerp(self.target.1, goal.target.1), goal.target.2);
            self.yaw = goal.yaw;
            self.pitch = goal.pitch;
        } else {
            self.target = V3(lerp(self.target.0, goal.target.0), lerp(self.target.1, goal.target.1), lerp(self.target.2, goal.target.2));
            self.yaw = lerp(cy, gy).rem_euclid(std::f32::consts::TAU);
            self.pitch = lerp(self.pitch, goal.pitch);
        }
        self.distance = lerp(self.distance, goal.distance);
        true
    }

    /// Whether the camera is (as good as) at `goal`.
    pub fn at(&self, goal: &OrbitCamera) -> bool {
        let d = goal.target.sub(self.target).len();
        let mut dyaw = (goal.yaw - self.yaw).rem_euclid(std::f32::consts::TAU);
        if dyaw > std::f32::consts::PI {
            dyaw -= std::f32::consts::TAU;
        }
        d < self.distance * 1e-4 && (goal.distance / self.distance - 1.0).abs() < 1e-4 && dyaw.abs() < 1e-4 && (goal.pitch - self.pitch).abs() < 1e-4
    }

    /// The plane's point (y = 0) under a pixel of a `width` x `height` screen (the cursor's ray,
    /// 4000 of the game's world along it when it misses the plane: SetTargetZoom).
    pub fn ground_at(&self, x: f32, y: f32, width: u32, height: u32) -> V3 {
        let eye = self.eye();
        let z = self.target.sub(eye).norm();
        let xa = V3(0.0, 1.0, 0.0).cross(z).norm();
        let ya = z.cross(xa);
        let t = (self.fov_y / 2.0).tan();
        let aspect = width.max(1) as f32 / height.max(1) as f32;
        let (nx, ny) = (2.0 * x / width.max(1) as f32 - 1.0, 1.0 - 2.0 * y / height.max(1) as f32);
        let d = z.add(xa.scale(nx * t * aspect)).add(ya.scale(ny * t)).norm();
        let s = if d.1 < -1e-4 { -eye.1 / d.1 } else { 2000.0 };
        eye.add(d.scale(s))
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
