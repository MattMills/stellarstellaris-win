// The game's post-effect chain (gfx/FX: downsample.shader, downsample_luminance.shader,
// bloom.shader, restorescene.shader; the constants from gfx/worldgfx; the passes as
// CGameRendering::RenderPostEffects runs them, 4.5.2 Linux), on the HDR scene:
//   1. fs_bright: the scene at half its size (one bilinear tap: a 2 x 2 box), each pixel times its
//      brightness over BrightThreshold (max(r, g, b) - threshold, then x / (0.5 + x)) plus its
//      emissive (the scene's alpha) x EmissiveBloomStrength; the log luminance in alpha
//      (downsample.shader);
//   2. fs_luminance: the average luminance: exp(mean(log luminance)), clamped to
//      [hdr_min_adjustment, hdr_max_adjustment] (downsample_luminance.shader's gather; the game
//      adapts toward it over time: a still frame has adapted);
//   3. the bloom, a pyramid of bloom_iterations levels (while a level is at least 4 pixels): each
//      level blurred by fs_blur along x then y (bloom.shader: a centre weight and four bilinear
//      pairs, the weights CGameRendering::Bloom computes from bloom_width and bloom_scale, so each
//      pass scales by bloom_scale), added into the accumulated bloom (fs_copy, additive), and
//      halved into the next level (fs_copy). The game keeps every level at the top left of the
//      half-size targets (BloomToScreenScale: uv_scale here) with the rest cleared;
//   4. fs_restore: scene + bloom, x MiddleGrey / the average luminance (ADJUSTED_EXPOSURE), the
//      Uncharted 2 tone map (W = 11.2), to gamma (1 / 2.2), then the colour cube
//      (colorcorrection_*.tga: 32 slices of 32 x 32) and Levels(0.04, 0.8) (COLOR_LUT)
//      (restorescene.shader).
// Not drawn: the lens flare (its ghosts and halo x gfx/lensdirt.dds, added in the restore).

struct Post {
    // 1 / the source's size; the blur's axis (0 x, 1 y) and centre weight
    inv_src: vec2<f32>,
    axis: f32,
    weight0: f32,
    weights: vec4<f32>,
    offsets: vec4<f32>,
    bright_threshold: f32,
    emissive_bloom: f32,
    middle_grey: f32,
    min_hdr: f32,
    max_hdr: f32,
    // 1 when the target stores sRGB (the restored colour is in gamma space)
    srgb_out: u32,
    use_lut: u32,
    _pad: f32,
    // the part of the source a copy reads (the game's BloomToScreenScale)
    uv_scale: vec2<f32>,
    _pad2: vec2<f32>,
};

@group(0) @binding(0) var<uniform> post: Post;
@group(1) @binding(0) var t0: texture_2d<f32>;
@group(1) @binding(1) var t1: texture_2d<f32>;
@group(1) @binding(2) var t2: texture_2d<f32>;
@group(1) @binding(3) var t3: texture_2d<f32>;
@group(1) @binding(4) var samp: sampler;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

// one triangle over the screen; uv (0, 0) at the top left
@vertex
fn vs_full(@builtin(vertex_index) i: u32) -> VsOut {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    var o: VsOut;
    o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = vec2<f32>(p.x, 1.0 - p.y);
    return o;
}

const LUMINANCE = vec3<f32>(0.2125, 0.7154, 0.0721);

@fragment
fn fs_bright(i: VsOut) -> @location(0) vec4<f32> {
    // one bilinear tap of the full scene at the half-size pixel's centre
    let c = textureSampleLevel(t0, samp, i.uv, 0.0);
    var m = max(0.0, max(max(c.r, c.g), c.b) - post.bright_threshold);
    m = m / (0.5 + m);
    m += c.a * post.emissive_bloom;
    let log_lum = log(max(0.0, dot(c.rgb, LUMINANCE)) + 0.0001);
    return vec4<f32>(c.rgb * m, log_lum);
}

@fragment
fn fs_luminance(i: VsOut) -> @location(0) vec4<f32> {
    var sum = 0.0;
    let nx = 32;
    let ny = 18;
    for (var y = 0; y < ny; y++) {
        for (var x = 0; x < nx; x++) {
            let uv = vec2<f32>((f32(x) + 0.5) / f32(nx), (f32(y) + 0.5) / f32(ny));
            sum += textureSampleLevel(t0, samp, uv, 0.0).a;
        }
    }
    let lum = clamp(exp(sum / f32(nx * ny)), post.min_hdr, post.max_hdr);
    return vec4<f32>(lum, 0.0, 0.0, 1.0);
}

@fragment
fn fs_blur(i: VsOut) -> @location(0) vec4<f32> {
    let step = post.inv_src * vec2<f32>(1.0 - post.axis, post.axis);
    var c = textureSampleLevel(t0, samp, i.uv, 0.0).rgb * post.weight0;
    for (var k = 0; k < 4; k++) {
        let o = step * post.offsets[k];
        c += post.weights[k] * (textureSampleLevel(t0, samp, i.uv + o, 0.0).rgb + textureSampleLevel(t0, samp, i.uv - o, 0.0).rgb);
    }
    return vec4<f32>(c, 1.0);
}

// downsample.shader's PixelShaderDownsample: the source's part uv_scale stretched over the target
// (the bloom's levels added into the accumulated bloom, and halved into the next level)
@fragment
fn fs_copy(i: VsOut) -> @location(0) vec4<f32> {
    return textureSampleLevel(t0, samp, i.uv * post.uv_scale, 0.0);
}

fn uncharted(x: vec3<f32>) -> vec3<f32> {
    let a = 0.22;
    let b = 0.30;
    let c = 0.10;
    let d = 0.20;
    let e = 0.01;
    let f = 0.30;
    return ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f;
}

// restorescene.shader's SampleColorCube: 32 slices of 32 x 32 side by side
fn colour_cube(c: vec3<f32>) -> vec3<f32> {
    let size = 32.0;
    let scale = (size - 1.0) / size;
    let offset = 0.5 / size;
    let x = (scale * c.r + offset) / size;
    let y = scale * c.g + offset;
    let z = floor((scale * c.b + offset) * size);
    let x1 = z / size;
    let x2 = min(size - 1.0, z + 1.0) / size;
    let c1 = textureSampleLevel(t3, samp, vec2<f32>(x + x1, y), 0.0).rgb;
    let c2 = textureSampleLevel(t3, samp, vec2<f32>(x + x2, y), 0.0).rgb;
    return mix(c1, c2, scale * c.b * size - z);
}

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

@fragment
fn fs_restore(i: VsOut) -> @location(0) vec4<f32> {
    var c = textureSampleLevel(t0, samp, i.uv, 0.0).rgb;
    c += textureSampleLevel(t1, samp, i.uv, 0.0).rgb;
    let avg = textureSampleLevel(t2, samp, vec2<f32>(0.5), 0.0).r;
    c = c * (post.middle_grey / max(avg, 1e-4));
    c = uncharted(c) / uncharted(vec3<f32>(11.2));
    c = pow(max(c, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    c = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    if (post.use_lut == 1u) {
        c = colour_cube(c);
        // Levels(0.04, 0.8)
        c = clamp((clamp(c - vec3<f32>(0.04), vec3<f32>(0.0), vec3<f32>(1.0))) / (0.8 - 0.04), vec3<f32>(0.0), vec3<f32>(1.0));
    }
    if (post.srgb_out == 1u) {
        return vec4<f32>(srgb_to_linear(c), 1.0);
    }
    return vec4<f32>(c, 1.0);
}
