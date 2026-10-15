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
// the galaxy view's map textures (galaxymap.rs: the save's -500 .. 500, uv = (x + 500) / 1000):
// terra incognita, the borders' signed distance, edge and fill colours; the dust's colour map
@group(0) @binding(1) var ti_tex: texture_2d<f32>;
@group(0) @binding(2) var border_sdf: texture_2d<f32>;
@group(0) @binding(3) var border_edge: texture_2d<f32>;
@group(0) @binding(4) var border_fill: texture_2d<f32>;
@group(0) @binding(5) var dust_colour: texture_2d<f32>;
@group(0) @binding(6) var map_samp: sampler;

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
    // the point in the world (map units: x, height, y)
    @location(2) world: vec3<f32>,
    @location(3) fx: vec4<f32>,
    @location(4) fx2: vec4<f32>,
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
    // the galaxy view's shading (fs_quad): x the mode, y the terra incognita grey's brightness, z
    // a plane's tilt (galaxy_dust.shader: y += (corner x + corner y) x size x z); fx2: the dust
    // colour map's rectangle (x0, y0, 1 / width, 1 / height)
    @location(4) fx: vec4<f32>,
    @location(5) fx2: vec4<f32>,
) -> QuadOut {
    let t = corner(vi) * 0.5 + vec2<f32>(0.5);
    let centre = 0.5 * (rect.xy + rect.zw);
    var half = 0.5 * (rect.zw - rect.xy);
    let local = (t * 2.0 - vec2<f32>(1.0));
    let cs = cos(misc.x);
    let sn = sin(misc.x);
    var clip: vec4<f32>;
    var world = vec3<f32>(centre.x, misc.z, centre.y);
    if (misc.y > 1.5) {
        // a billboard: centred on (cx, height, cy), its half size in world units at least
        // misc.w pixels
        let c3 = vec3<f32>(centre.x, misc.z, centre.y);
        let cc = to_clip(c3);
        let ppu = view.focal / max(cc.w, 1e-4);
        let least = misc.w / max(ppu, 1e-6);
        let h = max(abs(half.x), least);
        let l = vec2<f32>(local.x * cs - local.y * sn, local.x * sn + local.y * cs) * h;
        world = c3 + view.right.xyz * l.x + view.up.xyz * l.y;
        clip = to_clip(world);
    } else if (misc.y > 0.5) {
        let p = centre + vec2<f32>(local.x * half.x * cs - local.y * half.y * sn, local.x * half.x * sn + local.y * half.y * cs);
        clip = vec4<f32>(p.x * view.px_to_ndc.x - 1.0, 1.0 - p.y * view.px_to_ndc.y, 0.0, 1.0);
    } else {
        let lr = vec2<f32>(local.x * half.x, local.y * half.y);
        let p = centre + vec2<f32>(lr.x * cs - lr.y * sn, lr.x * sn + lr.y * cs);
        world = vec3<f32>(p.x, misc.z + (local.x + local.y) * abs(half.x) * fx.z, p.y);
        clip = to_clip(world);
    }
    var o: QuadOut;
    o.pos = clip;
    o.uv = mix(uv.xy, uv.zw, t);
    o.colour = colour;
    o.world = world;
    o.fx = fx;
    o.fx2 = fx2;
    return o;
}

fn lin3(c: vec3<f32>) -> vec3<f32> {
    if (view.srgb == 1u || view.linear == 1u) {
        return srgb_to_linear(c);
    }
    return c;
}

fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(max(c, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

// a colour computed in linear space (the game's shader maths) for the target
fn out_lin(c: vec3<f32>, alpha: f32) -> vec4<f32> {
    if (view.srgb == 1u || view.linear == 1u) {
        return vec4<f32>(c, alpha);
    }
    return vec4<f32>(linear_to_srgb(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0))), alpha);
}

fn map_uv(w: vec3<f32>) -> vec2<f32> {
    return (w.xz + vec2<f32>(500.0)) / 1000.0;
}

// terra_incognita.fxh: the blurred known/unknown value, raw and smoothed (0.65 .. 0.75)
fn ti_raw(w: vec3<f32>) -> f32 {
    return textureSampleLevel(ti_tex, map_samp, map_uv(w), 0.0).a;
}

fn ti_value(w: vec3<f32>) -> f32 {
    return smoothstep(0.65, 0.75, ti_raw(w));
}

// border.shader's BorderSDF at a point of the plane (the borders are drawn into a target the dust
// reads at the same place): the edge colour on a band at the blob's edge, the fill inside, by the
// camera's distance f = |camera - point| / 1600 of the game's world (map x 2); premultiplied rgb
// and alpha as the blend leaves them on the cleared target
fn border_at(w_in: vec3<f32>) -> vec4<f32> {
    // the plane's point under the same pixel (the game reads the border target in screen space)
    let e = view.eye.xyz;
    let k = e.y / max(e.y - w_in.y, 1e-4);
    let w = e + (w_in - e) * k;
    let uv = map_uv(w);
    let d = textureSampleLevel(border_sdf, map_samp, uv, 0.0).a;
    let edge_c = textureSampleLevel(border_edge, map_samp, uv, 0.0);
    let fill_c = textureSampleLevel(border_fill, map_samp, uv, 0.0);
    if (d > 0.53 || edge_c.a < 0.5) {
        return vec4<f32>(0.0);
    }
    let p = vec3<f32>(w.x, 0.0, w.z);
    let f = clamp(length(view.eye.xyz - p) * 2.0 / 1600.0, 0.0, 1.0);
    let mid = mix(0.47, 0.53, f);
    let eps = 0.005 + 0.05 * f;
    let edge_w = 0.025 + 0.35 * f;
    let edge = clamp((d - mid + edge_w) * 100.0, 0.0, 1.0);
    let colour = mix(fill_c.rgb, edge_c.rgb, edge) * (1.0 - 0.25 * clamp((d - mid + 0.25 * edge_w) * 25.0, 0.0, 1.0));
    let a = clamp(edge + max(0.5 + 0.5 * f, clamp(mid + (d - 0.25 + edge_w) * 2.0, 0.0, 1.0) * 0.75), 0.0, 1.0)
        * smoothstep(mid + eps, mid - eps, d) * ti_raw(w);
    // src alpha / inv src alpha onto black (the alpha written as it is: the game's frames show
    // the ring as strong as that)
    return vec4<f32>(colour * a, a);
}

@fragment
fn fs_quad(i: QuadOut) -> @location(0) vec4<f32> {
    let texel = textureSample(tex, samp, i.uv);
    let mode = i.fx.x;
    if (mode > 0.5 && mode < 1.5) {
        // a star or the core (galaxy_stars.shader, galaxy_center.shader): greyed outside the
        // known space (ApplyTerraIncognita: the luminance x 0.15 x brightness); the colour (the
        // core's x 0.5) scales the texel once it is linear, as the game's shader does
        let c = lin3(texel.rgb) * i.colour.rgb;
        let grey = dot(c, vec3<f32>(0.2127, 0.7152, 0.0722)) * 0.15 * i.fx.y;
        // fx.w: added by ONE, ONE (the core): alpha 1 for the SRC_ALPHA blend
        let a = select(texel.a * i.colour.a, 1.0, i.fx.w > 0.5);
        return out_lin(mix(vec3<f32>(grey), c, ti_value(i.world)), a);
    }
    if (mode > 1.5 && mode < 2.5) {
        // a dust cloud (galaxy_dust.shader): the dust texture x the galaxy's colour map, tinted by
        // the borders, greyed (and faint) outside the known space
        let cuv = (i.world.xz - i.fx2.xy) * i.fx2.zw;
        let colour_map = textureSampleLevel(dust_colour, map_samp, cuv, 0.0);
        var col = vec4<f32>(lin3(colour_map.rgb), colour_map.a);
        let b = border_at(i.world);
        let ba = clamp(b.a * 0.8, 0.0, 1.0);
        col = vec4<f32>(mix(col.rgb, b.rgb, ba), col.a);
        var ti = ti_value(i.world);
        ti = clamp(ti + ba * 0.8 * clamp((1.0 - ti) * 1000.0, 0.0, 1.0), 0.0, 1.0);
        let dust = vec4<f32>(lin3(texel.rgb), texel.a);
        let c = dust * mix(col, vec4<f32>(0.15 + ba * 0.3), 1.0 - ti);
        return out_lin(c.rgb * i.colour.rgb, c.a * i.colour.a);
    }
    if (mode > 2.5 && mode < 3.5) {
        // a nebula's cloud (galaxy_nebula.shader): the nebula texture (alpha x 6) x its colour
        // texture (here its mean colour, in the instance's colour: one texture per batch), tinted
        // by the borders (x 2), greyed outside the known space
        let col = lin3(i.colour.rgb);
        let b = border_at(i.world);
        let ba = clamp(b.a * 0.5, 0.0, 1.0);
        let c0 = mix(col, b.rgb * 2.0, ba);
        let ti0 = ti_value(i.world);
        let grey = dot(c0, vec3<f32>(0.2127, 0.7152, 0.0722)) * 0.15 * 0.15;
        let ti_col = mix(vec3<f32>(grey), c0, ti0);
        let ti = clamp(ti0 + ba * 0.8 * clamp((1.0 - ti0) * 1000.0, 0.0, 1.0), 0.0, 1.0);
        let a = clamp(texel.a * 6.0, 0.0, 1.0);
        let c = lin3(texel.rgb) * mix(c0, ti_col + vec3<f32>(ba * 0.3), 1.0 - ti);
        return out_lin(c, a * i.colour.a);
    }
    let c = texel * i.colour;
    return output(c.rgb, c.a);
}

// ---- lines

struct LaneOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) across: f32,
    @location(1) half: f32,
    @location(2) colour: vec4<f32>,
    @location(3) world: vec3<f32>,
    @location(4) mode: f32,
};

@vertex
fn vs_lane(
    @builtin(vertex_index) vi: u32,
    @location(0) a: vec4<f32>,     // xyz: the start (world), w: width in pixels
    @location(1) b: vec4<f32>,     // xyz: the end, w: 1 a hyperlane of the galaxy view
    @location(2) colour: vec4<f32>,
) -> LaneOut {
    let c = corner(vi);
    let ca = to_clip(a.xyz);
    let cb = to_clip(b.xyz);
    var o: LaneOut;
    o.colour = colour;
    o.half = a.w * 0.5;
    o.world = select(a.xyz, b.xyz, c.x > 0.0);
    o.mode = b.w;
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
    if (i.mode > 0.5 && i.mode < 1.5) {
        // a hyperlane (hyperlane.shader): its colour in the known space; outside it a flat
        // grey (0.15 x 5) of alpha 0.05 (its visibility taken as 1: drawn lanes touch the known)
        let ti = ti_value(i.world);
        let c = mix(vec3<f32>(0.75), lin3(i.colour.rgb), ti);
        return out_lin(c, mix(0.05, i.colour.a, ti) * coverage);
    }
    if (i.mode > 1.5) {
        // a star pin (border.shader StarPin): greyed outside the known space (brightness 4)
        let c = lin3(i.colour.rgb);
        let grey = dot(c, vec3<f32>(0.2127, 0.7152, 0.0722)) * 0.15 * 4.0;
        return out_lin(mix(vec3<f32>(grey), c, ti_value(i.world)), i.colour.a * coverage);
    }
    return output(i.colour.rgb, i.colour.a * coverage);
}
