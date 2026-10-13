// The galaxy map: hyperlanes as quads around their segment, stars as discs, both antialiased by
// their distance in pixels (no multisampling: a disc's inside is exactly its colour).

struct View {
    // map units -> clip space: ndc = p * world_to_ndc.xy + world_to_ndc.zw
    world_to_ndc: vec4<f32>,
    // pixels -> clip space: 2 / width, 2 / height
    px_to_ndc: vec2<f32>,
    // 1 when the target stores sRGB (the colours are given in sRGB and converted to linear)
    srgb: u32,
    pad: u32,
};

@group(0) @binding(0) var<uniform> view: View;

fn to_ndc(p: vec2<f32>) -> vec2<f32> {
    return p * view.world_to_ndc.xy + view.world_to_ndc.zw;
}

// the corners of a quad: two triangles
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

// ---- stars

struct StarOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) local: vec2<f32>,   // pixels from the centre
    @location(1) radius: f32,        // pixels
    @location(2) colour: vec4<f32>,
};

@vertex
fn vs_star(
    @builtin(vertex_index) vi: u32,
    @location(0) centre: vec2<f32>,
    @location(1) radius: f32,
    @location(2) colour: vec4<f32>,
) -> StarOut {
    let c = corner(vi);
    let r = radius + 1.0;   // a pixel more for the edge
    var o: StarOut;
    o.pos = vec4<f32>(to_ndc(centre) + c * r * view.px_to_ndc, 0.0, 1.0);
    o.local = c * r;
    o.radius = radius;
    o.colour = colour;
    return o;
}

@fragment
fn fs_star(i: StarOut) -> @location(0) vec4<f32> {
    let coverage = clamp(i.radius - length(i.local) + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) {
        discard;
    }
    return output(i.colour.rgb, i.colour.a * coverage);
}

// ---- hyperlanes

struct LaneOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) across: f32,   // pixels from the lane's middle line
    @location(1) half: f32,     // half the width, pixels
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
    // the segment in pixels
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
