// The galaxy map and the GUI: textured quads (in map units through the fitted view, or in screen
// pixels), alpha-blended or added, and the hyperlanes as antialiased quads around their segment.

struct View {
    // map units -> clip space: ndc = p * world_to_ndc.xy + world_to_ndc.zw
    world_to_ndc: vec4<f32>,
    // pixels -> clip space: 2 / width, 2 / height
    px_to_ndc: vec2<f32>,
    // 1 when the target stores sRGB (colours are given in sRGB and converted to linear)
    srgb: u32,
    pad: u32,
};

@group(0) @binding(0) var<uniform> view: View;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

fn to_ndc(p: vec2<f32>) -> vec2<f32> {
    return p * view.world_to_ndc.xy + view.world_to_ndc.zw;
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
    if (view.srgb == 1u) {
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
    @location(3) misc: vec4<f32>,   // rotation (radians), screen (1) or map (0)
) -> QuadOut {
    let t = corner(vi) * 0.5 + vec2<f32>(0.5);
    let centre = 0.5 * (rect.xy + rect.zw);
    let half = 0.5 * (rect.zw - rect.xy);
    let local = (t * 2.0 - vec2<f32>(1.0)) * half;
    let cs = cos(misc.x);
    let sn = sin(misc.x);
    let p = centre + vec2<f32>(local.x * cs - local.y * sn, local.x * sn + local.y * cs);
    var ndc: vec2<f32>;
    if (misc.y > 0.5) {
        ndc = vec2<f32>(p.x * view.px_to_ndc.x - 1.0, 1.0 - p.y * view.px_to_ndc.y);
    } else {
        ndc = to_ndc(p);
    }
    var o: QuadOut;
    o.pos = vec4<f32>(ndc, 0.0, 1.0);
    o.uv = mix(uv.xy, uv.zw, t);
    o.colour = colour;
    return o;
}

@fragment
fn fs_quad(i: QuadOut) -> @location(0) vec4<f32> {
    let c = textureSample(tex, samp, i.uv) * i.colour;
    return output(c.rgb, c.a);
}

// ---- hyperlanes

struct LaneOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) across: f32,
    @location(1) half: f32,
    @location(2) colour: vec4<f32>,
};

@vertex
fn vs_lane(
    @builtin(vertex_index) vi: u32,
    @location(0) a: vec2<f32>,
    @location(1) b: vec2<f32>,
    @location(2) colour: vec4<f32>,
    @location(3) width: f32,
) -> LaneOut {
    let c = corner(vi);
    let pa = to_ndc(a) / view.px_to_ndc;
    let pb = to_ndc(b) / view.px_to_ndc;
    var dir = pb - pa;
    let len = length(dir);
    if (len > 0.0) {
        dir = dir / len;
    } else {
        dir = vec2<f32>(1.0, 0.0);
    }
    let normal = vec2<f32>(-dir.y, dir.x);
    let half = width * 0.5;
    let reach = half + 1.0;
    let p = select(pa, pb, c.x > 0.0) + normal * c.y * reach;
    var o: LaneOut;
    o.pos = vec4<f32>(p * view.px_to_ndc, 0.0, 1.0);
    o.across = c.y * reach;
    o.half = half;
    o.colour = colour;
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
