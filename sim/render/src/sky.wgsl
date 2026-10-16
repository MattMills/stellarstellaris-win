// The sky behind a system or the galaxy: the game's sky.shader (Sky, Sky_YCoCg). A cube map
// sampled in the view's direction (gfx/worldgfx: `galaxy_background`; a system's by its distance
// from the core: gfx/map/sky_core / sky_mid / sky_rim.dds, YCoCg in DXT5; the galaxy's
// gfx/worldgfx/stars.dds), YCoCg decoded and to linear, its hue, saturation and value shifted
// (`galaxy_background_hsv_shift`), through the colour cube (`galaxy_background_lut`), behind
// everything (depth 1).

struct Sky {
    // the view's direction at the centre, and the screen's right and up at its edges
    forward: vec4<f32>,
    right: vec4<f32>,
    up: vec4<f32>,
    // hue (in turns), saturation and value shifts; w: 1 YCoCg
    hsv_shift: vec4<f32>,
    // x: 1 with a colour cube, y: the intel (1 known: the colours kept), z: 1 gamma-encoded
    flags: vec4<f32>,
};

@group(0) @binding(0) var<uniform> sky: Sky;
@group(1) @binding(0) var cube: texture_cube<f32>;
@group(1) @binding(1) var lut: texture_2d<f32>;
@group(1) @binding(2) var samp: sampler;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) ndc: vec2<f32>,
};

@vertex
fn vs_sky(@builtin(vertex_index) i: u32) -> VsOut {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u)) * 2.0 - 1.0;
    var o: VsOut;
    // at the far plane
    o.pos = vec4<f32>(p, 1.0, 1.0);
    o.ndc = p;
    return o;
}

// standardfuncsgfx.fxh: hue in [0, 6)
fn hue(h: f32) -> vec3<f32> {
    return clamp(vec3<f32>(abs(h - 3.0) - 1.0, 2.0 - abs(h - 2.0), 2.0 - abs(h - 4.0)), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn hsv_to_rgb(c: vec3<f32>) -> vec3<f32> {
    if (c.y != 0.0) {
        let k = c.y * c.z;
        return clamp(hue(c.x) * k + (c.z - k), vec3<f32>(0.0), vec3<f32>(1.0));
    }
    return clamp(vec3<f32>(c.z), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn rgb_to_hsv(c: vec3<f32>) -> vec3<f32> {
    let cmax = max(c.r, max(c.g, c.b));
    let cmin = min(c.r, min(c.g, c.b));
    let d = cmax - cmin;
    var h = 0.0;
    var s = 0.0;
    if (d != 0.0) {
        s = d / cmax;
        if (cmax == c.r) {
            h = (c.g - c.b) / d + 6.0;
        } else if (cmax == c.g) {
            h = (c.b - c.r) / d + 2.0;
        } else {
            h = (c.r - c.g) / d + 4.0;
        }
    }
    return vec3<f32>(h, s, cmax);
}

fn colour_cube(c: vec3<f32>) -> vec3<f32> {
    let size = 32.0;
    let scale = (size - 1.0) / size;
    let offset = 0.5 / size;
    let x = (scale * c.r + offset) / size;
    let y = scale * c.g + offset;
    let z = floor((scale * c.b + offset) * size);
    let x1 = z / size;
    let x2 = min(size - 1.0, z + 1.0) / size;
    let c1 = textureSampleLevel(lut, samp, vec2<f32>(x + x1, y), 0.0).rgb;
    let c2 = textureSampleLevel(lut, samp, vec2<f32>(x + x2, y), 0.0).rgb;
    return mix(c1, c2, scale * c.b * size - z);
}

@fragment
fn fs_sky(i: VsOut) -> @location(0) vec4<f32> {
    let dir = normalize(sky.forward.xyz + sky.right.xyz * i.ndc.x + sky.up.xyz * i.ndc.y);
    let t = textureSampleLevel(cube, samp, dir, 0.0);
    var c = t.rgb;
    if (sky.hsv_shift.w > 0.5) {
        // YCoCg: Co in red, Cg in green, the scale in blue, Y in alpha
        let scale = t.b * (255.0 / 8.0) + 1.0;
        let co = (t.r - 0.5 * 256.0 / 255.0) / scale;
        let cg = (t.g - 0.5 * 256.0 / 255.0) / scale;
        let y = t.a;
        c = vec3<f32>(y + co - cg, y + cg, y - co - cg);
        // ToLinear (2.2)
        c = pow(max(c, vec3<f32>(0.0)), vec3<f32>(2.2));
    } else {
        // a colour texture: the game samples it as sRGB (linear out); here it is stored as is
        c = pow(c, vec3<f32>(2.2));
    }
    var hsv = rgb_to_hsv(c);
    hsv.x = (6.0 + hsv.x + sky.hsv_shift.x * 6.0) % 6.0;
    hsv = vec3<f32>(hsv.x, clamp(hsv.yz * (vec2<f32>(1.0) + sky.hsv_shift.yz), vec2<f32>(0.0), vec2<f32>(1.0)));
    c = hsv_to_rgb(hsv);
    if (sky.flags.x > 0.5) {
        c = colour_cube(c);
    }
    let grey = dot(c, vec3<f32>(0.3, 0.59, 0.11));
    c = mix(vec3<f32>(grey), c, sky.flags.y);
    // z: drawn into a target that is not sRGB, outside the HDR scene (an inset in the GUI)
    if (sky.flags.z > 0.5) {
        c = pow(max(c, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    }
    return vec4<f32>(c, 0.0);
}
