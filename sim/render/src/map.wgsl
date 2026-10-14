// The galaxy map and the GUI: textured quads (on the galactic plane, facing the camera, or in
// screen pixels), alpha-blended or added, and lines (hyperlanes, trails, orbits) as antialiased
// quads around their segment, widened on the screen. World space: the galactic plane is y = 0, a
// map coordinate (x, y) is the point (x, 0, y).

struct View {
    view_proj: mat4x4<f32>,
    // the camera's right and up in world space (billboards)
    right: vec4<f32>,
    up: vec4<f32>,
    eye: vec4<f32>,
    // xyz: the light's direction toward the light (w = 0) or its position (w = 1)
    light: vec4<f32>,
    // pixels -> clip space: 2 / width, 2 / height; focal: pixels per unit at distance 1
    px_to_ndc: vec2<f32>,
    focal: f32,
    // 1 when the target stores sRGB (colours are given in sRGB and converted to linear)
    srgb: u32,
    // 1: the HDR scene of the post effects (colours converted to linear, nothing clamped)
    linear: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    light_colour: vec4<f32>,
    back_light: vec4<f32>,
};

@group(0) @binding(0) var<uniform> view: View;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

fn to_clip(p: vec3<f32>) -> vec4<f32> {
    return view.view_proj * vec4<f32>(p, 1.0);
}

fn corner(i: u32) -> vec2<f32> {
    var c = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0),
    );
    return c[i];
}

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

fn output(c: vec3<f32>, alpha: f32) -> vec4<f32> {
    if (view.srgb == 1u || view.linear == 1u) {
        return vec4<f32>(srgb_to_linear(c), alpha);
    }
    return vec4<f32>(c, alpha);
}

// ---- quads

struct QuadOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) colour: vec4<f32>,
};

@vertex
fn vs_quad(
    @builtin(vertex_index) vi: u32,
    @location(0) rect: vec4<f32>,
    @location(1) uv: vec4<f32>,
    @location(2) colour: vec4<f32>,
    // rotation (radians); kind: 0 on the plane, 1 screen pixels, 2 a billboard; height; the
    // billboard's least half size in pixels
    @location(3) misc: vec4<f32>,
) -> QuadOut {
    let t = corner(vi) * 0.5 + vec2<f32>(0.5);
    let centre = 0.5 * (rect.xy + rect.zw);
    var half = 0.5 * (rect.zw - rect.xy);
    let local = (t * 2.0 - vec2<f32>(1.0));
    let cs = cos(misc.x);
    let sn = sin(misc.x);
    var clip: vec4<f32>;
    if (misc.y > 1.5) {
        // a billboard: centred on (cx, height, cy), its half size in world units at least
        // misc.w pixels
        let c3 = vec3<f32>(centre.x, misc.z, centre.y);
        let cc = to_clip(c3);
        let ppu = view.focal / max(cc.w, 1e-4);
        let least = misc.w / max(ppu, 1e-6);
        let h = max(abs(half.x), least);
        let l = vec2<f32>(local.x * cs - local.y * sn, local.x * sn + local.y * cs) * h;
        clip = to_clip(c3 + view.right.xyz * l.x + view.up.xyz * l.y);
    } else if (misc.y > 0.5) {
        let p = centre + vec2<f32>(local.x * half.x * cs - local.y * half.y * sn, local.x * half.x * sn + local.y * half.y * cs);
        clip = vec4<f32>(p.x * view.px_to_ndc.x - 1.0, 1.0 - p.y * view.px_to_ndc.y, 0.0, 1.0);
    } else {
        let lr = vec2<f32>(local.x * half.x, local.y * half.y);
        let p = centre + vec2<f32>(lr.x * cs - lr.y * sn, lr.x * sn + lr.y * cs);
        clip = to_clip(vec3<f32>(p.x, misc.z, p.y));
    }
    var o: QuadOut;
    o.pos = clip;
    o.uv = mix(uv.xy, uv.zw, t);
    o.colour = colour;
    return o;
}

@fragment
fn fs_quad(i: QuadOut) -> @location(0) vec4<f32> {
    let c = textureSample(tex, samp, i.uv) * i.colour;
    return output(c.rgb, c.a);
}

// ---- lines

struct LaneOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) across: f32,
    @location(1) half: f32,
    @location(2) colour: vec4<f32>,
};

@vertex
fn vs_lane(
    @builtin(vertex_index) vi: u32,
    @location(0) a: vec4<f32>,     // xyz: the start (world), w: width in pixels
    @location(1) b: vec4<f32>,     // xyz: the end
    @location(2) colour: vec4<f32>,
) -> LaneOut {
    let c = corner(vi);
    let ca = to_clip(a.xyz);
    let cb = to_clip(b.xyz);
    var o: LaneOut;
    o.colour = colour;
    o.half = a.w * 0.5;
    if (ca.w <= 1e-4 || cb.w <= 1e-4) {
        // behind the camera: not drawn
        o.pos = vec4<f32>(2.0, 2.0, 0.0, 1.0);
        o.across = 1e6;
        return o;
    }
    // the segment in pixels
    let pa = (ca.xy / ca.w) / view.px_to_ndc;
    let pb = (cb.xy / cb.w) / view.px_to_ndc;
    var dir = pb - pa;
    let len = length(dir);
    if (len > 0.0) {
        dir = dir / len;
    } else {
        dir = vec2<f32>(1.0, 0.0);
    }
    let normal = vec2<f32>(-dir.y, dir.x);
    let reach = o.half + 1.0;
    let end = select(ca, cb, c.x > 0.0);
    let p = select(pa, pb, c.x > 0.0) + normal * c.y * reach;
    o.pos = vec4<f32>(p * view.px_to_ndc * end.w, end.z, end.w);
    o.across = c.y * reach;
    return o;
}

@fragment
fn fs_lane(i: LaneOut) -> @location(0) vec4<f32> {
    let coverage = clamp(i.half - abs(i.across) + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) {
        discard;
    }
    return output(i.colour.rgb, i.colour.a * coverage);
}
