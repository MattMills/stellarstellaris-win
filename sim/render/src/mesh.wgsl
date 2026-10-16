// The game's meshes (gfx/models/**/*.mesh) with ports of the game's pixel shaders, simplified
// (gfx/FX/pdxmesh.shader, pdxmesh_ship.fxh, standardfuncsgfx.fxh; docs/render.md section 8):
// - lit (PixelPdxMeshStandard, PixelPdxMeshShip): the normal map unpacked as the game's
//   UnpackRRxGNormal (x = green, y = -alpha), the specular map's green = specular, blue =
//   metalness, alpha = glossiness, the normal map's blue = emissive; planets tinted by their
//   atmosphere towards the limb; ships with fill lights from the camera and a rim light;
// - clouds: the same, blended by the diffuse alpha, clipped towards the limb (IS_CLOUDS);
// - atmospheres (PixelPdxMeshAtmosphere, PixelPdxMeshAtmosphereStar): the back faces of a larger
//   sphere, added, brightest behind the body;
// - stars (PixelPdxMeshStar): lava and stone textures over the noise cube map, coloured by the
//   star class's gfx/worldgfx settings.
// No shadows; the bloom and tone mapping are post.wgsl's (the HDR scene: `linear`).

struct View {
    view_proj: mat4x4<f32>,
    right: vec4<f32>,
    up: vec4<f32>,
    eye: vec4<f32>,
    light: vec4<f32>,
    px_to_ndc: vec2<f32>,
    focal: f32,
    srgb: u32,
    // 1: the HDR scene of the post effects (textures and colours converted to linear, nothing
    // clamped; the alpha the emissive, for the bloom)
    linear: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    // the star's light (colour x intensity, gfx/lights) and the planets' back light
    // (system_back_light_diffuse, gfx/worldgfx)
    light_colour: vec4<f32>,
    back_light: vec4<f32>,
    // the ships' lights (gfx/worldgfx, linear): cam_light_1..3_diffuse, rim_light_diffuse, ambient
    cam_light: array<vec4<f32>, 5>,
};

struct Draw {
    model: mat4x4<f32>,
    tint: vec4<f32>,
    // x: the shading (0 lit, 1 emissive, 2 atmosphere, 3 clouds, 4 star, 5 star atmosphere),
    // y: emissive strength, z: specular strength, w: ambient
    params: vec4<f32>,
    // rgb: the atmosphere's colour, a: its intensity
    atmosphere: vec4<f32>,
    // x: the atmosphere's width, y: 1 a planet, 2 a ship
    extra: vec4<f32>,
    // a star's lava colours: bright, hot stone, cold stone
    lava0: vec4<f32>,
    lava1: vec4<f32>,
    lava2: vec4<f32>,
    // PixelPdxMeshStandard's: x the effect's defines (effects.rs bits), y vBloomFactor (the
    // entity's game_data bloom_factor), z CubemapIntensity (gfx/worldgfx), w AtmosphereColor.a
    stdc: vec4<f32>,
    // a ship part's (PixelPdxMeshShip): the camera lights' directions (camera space), w: the
    // lights' intensity, the rim's start, its stop; ship3: x the ambient intensity, z
    // EmissiveRecolorCrunch
    ship0: vec4<f32>,
    ship1: vec4<f32>,
    ship2: vec4<f32>,
    ship3: vec4<f32>,
};

@group(0) @binding(0) var<uniform> view: View;
@group(1) @binding(0) var diffuse_tex: texture_2d<f32>;
@group(1) @binding(1) var normal_tex: texture_2d<f32>;
@group(1) @binding(2) var specular_tex: texture_2d<f32>;
@group(1) @binding(3) var samp: sampler;
@group(1) @binding(4) var noise_cube: texture_cube<f32>;
// the world's environment_map (gfx/worldgfx: cubemap_filtered_ldr.dds, pre-filtered by level)
@group(1) @binding(5) var env_cube: texture_cube<f32>;
@group(2) @binding(0) var<uniform> draw: Draw;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) tangent: vec4<f32>,
    @location(3) uv: vec2<f32>,
    @location(4) local: vec3<f32>,
};

@vertex
fn vs_mesh(
    @location(0) pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) tangent: vec4<f32>,
    @location(3) uv: vec2<f32>,
) -> VsOut {
    let w = draw.model * vec4<f32>(pos, 1.0);
    var o: VsOut;
    o.pos = view.view_proj * w;
    o.world = w.xyz;
    // uniform scales only: the model's 3x3 keeps directions
    o.normal = normalize((draw.model * vec4<f32>(normal, 0.0)).xyz);
    o.tangent = vec4<f32>(normalize((draw.model * vec4<f32>(tangent.xyz, 0.0)).xyz + vec3<f32>(1e-6)), tangent.w);
    o.uv = uv;
    o.local = pos;
    return o;
}

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

fn output(c: vec3<f32>, alpha: f32) -> vec4<f32> {
    if (view.linear == 1u) {
        return vec4<f32>(max(c, vec3<f32>(0.0)), alpha);
    }
    let s = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    if (view.srgb == 1u) {
        return vec4<f32>(srgb_to_linear(s), alpha);
    }
    return vec4<f32>(s, alpha);
}

// a texture's colour, in the space the scene is lit in (the game samples its colour textures as
// sRGB; its colour settings, the lights', the atmospheres', the lava's, the renderer makes linear
// before they get here, as the game's GfxToLinear)
fn lin(c: vec3<f32>) -> vec3<f32> {
    if (view.linear == 1u) {
        return srgb_to_linear(c);
    }
    return c;
}

// an opaque part's alpha: in the HDR scene its emissive (the bloom's mask), else 1
fn emissive_alpha(e: f32) -> f32 {
    if (view.linear == 1u) {
        return e;
    }
    return 1.0;
}

// the light at a point: its direction and colour (the system's star, or the view's direction)
fn light_dir(world: vec3<f32>) -> vec3<f32> {
    if (view.light.w > 0.5) {
        return normalize(view.light.xyz - world);
    }
    return normalize(view.light.xyz);
}

fn star(i: VsOut) -> vec4<f32> {
    // PixelPdxMeshStar: the noise (the game samples the cube map LavaNoise at the direction
    // three times, at the same direction: 3 x (noise - 0.5)), animated by time (0 here)
    // the direction: the star mesh's tangent is its position ("tangent == position" in the
    // game's code), here the model-space position; the cube sampled three times at the same
    // direction (v, v x 4, v x 8): 3 x (noise - 0.5)
    let dir = normalize(i.local);
    // the game loads the noise, lava and stone textures as sRGB (AddTexture_sRGB in
    // SetStarEntityCustomData): read linear
    let noise = 3.0 * (lin(textureSample(noise_cube, samp, dir).rgb).r - 0.5);
    let animated = sin(noise * 10.0);
    let inv = (1.0 - animated) * 0.5;
    let inv2 = inv * inv;
    let lava_mask = clamp(-animated, 0.0, 1.0) * clamp(-animated, 0.0, 1.0);
    let to_camera = normalize(view.eye.xyz - i.world);
    let parallax = inv * to_camera.xz;
    let lava_tex = lin(textureSample(diffuse_tex, samp, i.uv * 10.0 - parallax * 0.1).rgb);
    let stone_tex = lin(textureSample(normal_tex, samp, i.uv * 25.0 - parallax * 0.15).rgb);
    var heated = stone_tex * draw.lava1.rgb * (pow(inv2, 0.5) + 0.1);
    let stone_lerp = 1.0 - clamp(animated, 0.0, 1.0);
    heated = mix(heated + stone_tex * draw.lava2.rgb, heated, stone_lerp);
    let lava = lava_tex * draw.lava0.rgb * pow(lava_mask, 0.7);
    var c = clamp(heated + lava, vec3<f32>(0.0), vec3<f32>(1.0));
    let n0 = normalize(i.normal);
    let a = clamp(dot(n0, -to_camera) + draw.extra.x, 0.0, 1.0);
    c = mix(c, draw.atmosphere.rgb, a * a * draw.atmosphere.a);
    let rim = smoothstep(0.5, 1.0, 1.0 - dot(n0, to_camera));
    c = clamp(c + c * rim * 3.5, vec3<f32>(0.0), vec3<f32>(1.0));
    // x 2 and alpha 0 as the game (the bright pass blooms it, not its emissive)
    return output(c * 2.0, emissive_alpha(0.0));
}

// the defines of an effect (effects.rs)
const F_PLANET: u32 = 1u;
const F_EMISSIVE: u32 = 2u;
const F_NO_PLANET_EMISSIVE: u32 = 4u;
const F_FLOWMAP: u32 = 8u;
const F_EMISSIVE_FLOW: u32 = 16u;
const F_CLOUDS: u32 = 32u;
const F_RING: u32 = 64u;
const F_PLANET_LIGHTS_EMISSIVE: u32 = 128u;
const F_NO_ALPHA_MULTIPLIED_EMISSIVE: u32 = 256u;
const F_ADD_COLOR: u32 = 512u;

fn has(f: u32, b: u32) -> bool {
    return (f & b) != 0u;
}

// UnpackRRxGNormal (x = green, y = -alpha, z rebuilt) in the frame of the vertex's tangent,
// bitangent cross(normal, tangent) x the tangent's w, and `n`
fn normal_mapped(i: VsOut, n: vec3<f32>, nm: vec4<f32>) -> vec3<f32> {
    let t = normalize(i.tangent.xyz - n * dot(n, i.tangent.xyz));
    let b = cross(n, t) * select(1.0, -1.0, i.tangent.w < 0.0);
    let nx = nm.g * 2.0 - 1.0;
    let ny = -(nm.a * 2.0 - 1.0);
    let nz = sqrt(max(0.0, 1.0 - nx * nx - ny * ny));
    if (nm.a == 0.0 && nm.g == 0.0) {
        return n;
    }
    return normalize(t * nx + b * ny + n * nz);
}

// PixelPdxMeshStandard (gfx/FX/pdxmesh.shader) at time 0, by the effect's defines: IS_PLANET,
// EMISSIVE, NO_PLANET_EMISSIVE, USE_FLOWMAP, EMISSIVE_FLOW, IS_CLOUDS, IS_RING. Not ported: the
// city lights, the tiled point lights, ADD_COLOR (the empire colour), dissolves, Sensor.
fn standard(i: VsOut) -> vec4<f32> {
    let flags = u32(draw.stdc.x + 0.5);
    let v = normalize(view.eye.xyz - i.world);
    let to_light = light_dir(i.world);
    var n_in = normalize(i.normal);
    // every sample first (uniform control flow): the flow map's offset samples at time 0
    // (frac(t) = 0: the first at the uv, the second at uv + flow x 0.5, blended 1: the second)
    let nm0 = textureSample(normal_tex, samp, i.uv);
    let props = textureSample(specular_tex, samp, i.uv);
    let flow = (nm0.xy - 0.5) * 2.0 * 0.05;
    let d_plain = textureSample(diffuse_tex, samp, i.uv);
    let d_flow = textureSample(diffuse_tex, samp, i.uv + flow * 0.5);
    let nm_flow = textureSample(normal_tex, samp, i.uv + flow * 0.5);
    let gloss = props.a;
    let env_level = (1.0 - gloss) * 8.0;
    var nm = nm0;
    var diffuse_s = d_plain;
    var n = n_in;
    if (has(flags, F_FLOWMAP)) {
        diffuse_s = d_flow;
        if (has(flags, F_EMISSIVE_FLOW)) {
            nm.b = nm_flow.b;
        }
    } else {
        if (has(flags, F_CLOUDS)) {
            // clipped at the limb, the normal bent toward the light
            if (clamp(dot(n_in, v), 0.0, 1.0) - 0.27 < 0.0) {
                discard;
            }
            n_in = normalize(mix(n_in, to_light, 0.01 + 0.10 * diffuse_s.a));
        }
        n = normal_mapped(i, n_in, nm);
    }
    var alpha = diffuse_s.a;
    var albedo = lin(diffuse_s.rgb);
    var emissive = 0.0;
    if (has(flags, F_EMISSIVE)) {
        emissive = nm.b;
        // the emissive recoloured by the atmosphere colour (the molten lava's glow)
        if (draw.stdc.w > 0.0) {
            let m = max(albedo.r, max(albedo.g, albedo.b));
            albedo = mix(albedo, vec3<f32>(m) * draw.atmosphere.rgb, clamp(emissive, 0.0, 1.0));
        }
    }
    // ADD_COLOR: the empire colour (on a ship's parts the colour slot is PrimaryColor) by the
    // specular map's red, in gamma space
    var col = albedo;
    if (has(flags, F_ADD_COLOR) && draw.stdc.w > 0.0) {
        let g = pow(max(albedo, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
        col = pow(max(mix(g, g * (props.r * draw.atmosphere.rgb), props.r), vec3<f32>(0.0)), vec3<f32>(2.2));
    }
    let spec_level = props.g * props.g * 0.4;
    let metal = 1.0 - (1.0 - props.b) * (1.0 - props.b);
    let diff = mix(col, vec3<f32>(0.0), metal);
    let spec_colour = mix(vec3<f32>(spec_level), col, metal);
    // the system's point light (ImprovedBlinnPhong: the normalisation capped at 5, Schlick, no
    // specular below glossiness 0.05) and, on planets, the back light (CalculateSystemPointLight)
    let h = normalize(v + to_light);
    let ndl = clamp(dot(n, to_light), 0.0, 1.0);
    let ndh = clamp(dot(n, h), 0.0, 1.0);
    let nlg = exp2(11.0 * gloss);
    let norm = min((nlg + 2.0) / 8.0, 5.0);
    let fres = spec_colour + (vec3<f32>(1.0) - spec_colour) * pow(1.0 - clamp(dot(to_light, h), 0.0, 1.0), 5.0);
    let gloss_cut = select(clamp(1.0 - 0.05 / max(gloss, 1e-4), 0.0, 1.0), 0.0, gloss <= 0.05);
    let gloss_cut_s = gloss_cut * gloss_cut * (3.0 - 2.0 * gloss_cut);
    var diff_light = view.light_colour.rgb * ndl;
    var spec_light = norm * pow(ndh, nlg) * fres * view.light_colour.rgb * ndl * gloss_cut_s;
    if (has(flags, F_PLANET)) {
        diff_light = diff_light + view.back_light.rgb * max(dot(n, -to_light), 0.0);
    }
    var cube = draw.stdc.z;
    if (has(flags, F_EMISSIVE) && !has(flags, F_RING) && !has(flags, F_NO_PLANET_EMISSIVE) && !has(flags, F_PLANET_LIGHTS_EMISSIVE) && has(flags, F_PLANET)) {
        // the emissive only on the dark side (the city lights' mask, props.r)
        let ndl_dark = clamp(clamp(dot(n_in, -to_light) - 0.05, 0.0, 1.0) * 5.0, 0.0, 1.0);
        let dark = 1.0 - clamp(length(diff_light + spec_light), 0.0, 1.0);
        emissive = emissive * dark * props.r * ndl_dark;
        cube = cube * (1.0 - dark) / 2.0;
    }
    // the environment map, by the glossiness (FresnelGlossy)
    let refl = reflect(-v, n);
    let env = lin(textureSampleLevel(env_cube, samp, refl, env_level).rgb) * cube;
    let fg = spec_colour + (max(vec3<f32>(gloss), spec_colour) - spec_colour) * pow(1.0 - clamp(dot(v, n), 0.0, 1.0), 5.0);
    spec_light = spec_light + env * fg;
    // ComposeLight: no ambient (gfx/worldgfx `ambient` has value 0), HdrRange 1
    var c = diff_light * diff + spec_light;
    if (has(flags, F_EMISSIVE)) {
        c = mix(c, albedo, emissive);
        if (!has(flags, F_NO_ALPHA_MULTIPLIED_EMISSIVE)) {
            alpha = alpha * emissive;
        }
    }
    if (has(flags, F_PLANET) && !has(flags, F_RING)) {
        let to_camera = clamp(dot(n_in, -v) + draw.extra.x, 0.0, 1.0);
        let to_sun = dot(n_in, to_light) * 0.5 + 0.5;
        let a = mix(to_camera, to_camera * to_sun, 0.5);
        c = mix(c, draw.atmosphere.rgb, a * a * draw.stdc.w * draw.atmosphere.a);
    }
    c = c * draw.stdc.y;
    if (view.linear != 1u) {
        alpha = select(1.0, alpha, has(flags, F_CLOUDS) || has(flags, F_RING));
    }
    return output(c, alpha);
}

const F_USE_NORMALMAP_AS_ALPHA: u32 = 2048u;
const F_BLACK_HOLE: u32 = 4096u;

// PixelPdxMeshAdditive (gfx/FX/pdxmesh.shader) at time 0 (ANIMATE_UV: the uv as it is): the
// diffuse x its alpha, the alpha x vBloomFactor, added by SRC_ALPHA (BlendStateAdditiveBlend).
// Not ported: the flow map variant, the ship's PrimaryColor (ADD_COLOR, USE_EMPIRE_COLOR).
fn additive(i: VsOut) -> vec4<f32> {
    let flags = u32(draw.stdc.x + 0.5);
    let nm = textureSample(normal_tex, samp, i.uv);
    var d = textureSample(diffuse_tex, samp, i.uv);
    if (has(flags, F_USE_NORMALMAP_AS_ALPHA)) {
        d.a = d.a * nm.r;
    }
    var c = lin(d.rgb) * d.a;
    if (has(flags, F_BLACK_HOLE)) {
        let look_dir = normalize(cross(view.right.xyz, view.up.xyz));
        c = c * pow(abs(1.0 - abs(dot(look_dir, vec3<f32>(0.0, 1.0, 0.0)))), 1.5);
    }
    return output(c, d.a * draw.stdc.y);
}

const F_RIM_LIGHT: u32 = 32768u;
const F_GLOSSY_EMISSIVE: u32 = 65536u;
const F_EMPIRE_MASK_EMISSIVE: u32 = 131072u;
const F_SHIP: u32 = 262144u;

struct Lit {
    diff: vec3<f32>,
    spec: vec3<f32>,
};

// ImprovedBlinnPhong (standardfuncsgfx.fxh): toward the light `to_light` (as given: the ship's
// camera lights pass theirs unnormalised), the normalisation capped at 5, Schlick, no specular
// below glossiness 0.05
fn blinn_phong(colour: vec3<f32>, to_light: vec3<f32>, n: vec3<f32>, v: vec3<f32>, spec_colour: vec3<f32>, gloss: f32) -> Lit {
    let h = normalize(v + to_light);
    let ndl = clamp(dot(n, to_light), 0.0, 1.0);
    let ndh = clamp(dot(n, h), 0.0, 1.0);
    let nlg = exp2(11.0 * gloss);
    let norm = min((nlg + 2.0) / 8.0, 5.0);
    let fres = spec_colour + (vec3<f32>(1.0) - spec_colour) * pow(1.0 - clamp(dot(to_light, h), 0.0, 1.0), 5.0);
    let t = select(clamp(1.0 - 0.05 / max(gloss, 1e-4), 0.0, 1.0), 0.0, gloss <= 0.05);
    let cut = t * t * (3.0 - 2.0 * t);
    return Lit(colour * ndl, norm * pow(ndh, nlg) * fres * colour * ndl * cut);
}

// PixelPdxMeshShip (gfx/FX/pdxmesh_ship.fxh) undamaged, uncloaked, at time 0: the emissive
// recoloured by the empire colour (PrimaryColor: the look's atmosphere colour) x
// EmissiveRecolorCrunch, the specular map's red the empire colour mask (in gamma space), lit by
// the system's light and the culture's three camera lights (their directions in camera space,
// left unnormalised as the game's code does), the environment map, the ambient, the rim light.
fn ship(i: VsOut) -> vec4<f32> {
    let flags = u32(draw.stdc.x + 0.5);
    let v = normalize(view.eye.xyz - i.world);
    let n_in = normalize(i.normal);
    let nm = textureSample(normal_tex, samp, i.uv);
    let props = textureSample(specular_tex, samp, i.uv);
    let d = textureSample(diffuse_tex, samp, i.uv);
    let n = normal_mapped(i, n_in, nm);
    let prim = draw.atmosphere.rgb;
    var emissive = nm.b;
    var diffuse = lin(d.rgb);
    if (draw.stdc.w > 0.0) {
        var mask = 1.0;
        if (has(flags, F_EMPIRE_MASK_EMISSIVE)) {
            mask = floor(props.r + 0.95);
        }
        let m = max(diffuse.r, max(diffuse.g, diffuse.b));
        diffuse = mix(diffuse, vec3<f32>(m) * prim, clamp(emissive * draw.ship3.z * mask, 0.0, 1.0));
    }
    // the empire colour mask, in gamma space (ToGamma, ToLinear: 2.2)
    let g = pow(max(diffuse, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    let col = pow(max(mix(g, g * (props.r * prim), props.r), vec3<f32>(0.0)), vec3<f32>(2.2));
    let gloss = props.a;
    let spec_level = props.g * props.g * 0.4;
    let metal = 1.0 - (1.0 - props.b) * (1.0 - props.b);
    let diff_colour = mix(col, vec3<f32>(0.0), metal);
    let spec_colour = mix(vec3<f32>(spec_level), col, metal);
    // the system's point light
    var lit = blinn_phong(view.light_colour.rgb, light_dir(i.world), n, v, spec_colour, gloss);
    var diff_light = lit.diff;
    var spec_light = lit.spec;
    // the camera lights: x the camera's right, y its up, z its look direction
    let look_dir = normalize(cross(view.right.xyz, view.up.xyz));
    let dirs = array<vec3<f32>, 3>(draw.ship0.xyz, draw.ship1.xyz, draw.ship2.xyz);
    for (var k = 0; k < 3; k++) {
        let dl = dirs[k].x * view.right.xyz + dirs[k].y * view.up.xyz + dirs[k].z * look_dir;
        if (dot(dl, dl) > 0.0) {
            let c = blinn_phong(view.cam_light[k].rgb, -dl, n, v, spec_colour, gloss);
            diff_light = diff_light + c.diff * draw.ship0.w;
            spec_light = spec_light + c.spec * draw.ship0.w;
        }
    }
    let env = lin(textureSampleLevel(env_cube, samp, reflect(-v, n), (1.0 - gloss) * 8.0).rgb) * draw.stdc.z;
    let fg = spec_colour + (max(vec3<f32>(gloss), spec_colour) - spec_colour) * pow(1.0 - clamp(dot(v, n), 0.0, 1.0), 5.0);
    spec_light = spec_light + env * fg;
    let ambient = view.cam_light[4].rgb * draw.ship3.x;
    var c: vec3<f32>;
    if (has(flags, F_GLOSSY_EMISSIVE)) {
        c = (ambient + diff_light) * diff_colour;
        c = mix(c, diffuse, emissive) + spec_light;
    } else {
        c = (ambient + diff_light) * diff_colour + spec_light;
        c = mix(c, diffuse, emissive);
    }
    var alpha = d.a;
    if (!has(flags, F_NO_ALPHA_MULTIPLIED_EMISSIVE)) {
        alpha = alpha * emissive * draw.stdc.y;
    }
    if (has(flags, F_RIM_LIGHT)) {
        let rim = smoothstep(draw.ship1.w, draw.ship2.w, 1.0 - dot(n, v));
        c = mix(c, view.cam_light[3].rgb, clamp(rim, 0.0, 1.0));
    }
    if (view.linear != 1u) {
        alpha = 1.0;
    }
    return output(c, alpha);
}

@fragment
fn fs_mesh(i: VsOut) -> @location(0) vec4<f32> {
    let kind = draw.params.x;
    let v = normalize(view.eye.xyz - i.world);
    let l = light_dir(i.world);
    let n0 = normalize(i.normal);
    if (kind > 3.5 && kind < 4.5) {
        return star(i);
    }
    if (kind > 4.5 && kind < 5.5) {
        // PixelPdxMeshAtmosphereStar, on the back faces: colour x NdotV^3, alpha NdotV^4, added
        let ndv = clamp(dot(n0, -v), 0.0, 1.0);
        return vec4<f32>(draw.atmosphere.rgb * pow(ndv, 3.0), pow(ndv, 4.0));
    }
    if (kind > 1.5 && kind < 2.5) {
        // PixelPdxMeshAtmosphere, on the back faces: CalculateSystemPointLight with a shadow
        // factor of 0.13 (the star's light and the back light, the specular of glossiness 1
        // with half the colour), then colour x 0.15 + colour x light x 2, x (NdotV x 1.2)^4
        let atm = draw.atmosphere.rgb;
        let ndl = clamp(dot(n0, l), 0.0, 1.0);
        let h = normalize(v + l);
        let sc = atm * 0.5;
        let fres = sc + (vec3<f32>(1.0) - sc) * pow(1.0 - clamp(dot(l, h), 0.0, 1.0), 5.0);
        let spec = 5.0 * pow(clamp(dot(n0, h), 0.0, 1.0), 2048.0) * fres * view.light_colour.rgb * ndl;
        let diff = view.light_colour.rgb * ndl + view.back_light.rgb * max(dot(n0, -l), 0.0);
        var c = atm * 0.15 + atm * (diff + spec) * 0.13 * 2.0;
        let ndv = clamp(dot(n0, -v), 0.0, 1.0);
        c = c * pow(ndv * 1.2, 4.0);
        // alpha 1 + 2.9 NdotV as the game's: the blend's SRC_ALPHA scales the colour by it (an
        // unclamped factor on the HDR target); alpha itself is not written (NoAlpha)
        return vec4<f32>(c, 1.0 + ndv * 2.9);
    }
    if (kind > 6.5 && kind < 7.5) {
        return additive(i);
    }
    if (kind > 7.5 && kind < 8.5) {
        // PixelPdxMeshNavigationButton, not hovered, pressed nor selected: the mesh's uv is for
        // four frames, the texture has five (u x 0.8), the first; the intel grey not applied
        let d = textureSample(diffuse_tex, samp, vec2<f32>(i.uv.x * 0.8, i.uv.y));
        return output(lin(d.rgb), d.a);
    }
    if (kind > 8.5 && kind < 9.5) {
        // PixelPdxMeshPortrait: the diffuse (the character texture) as it is, with its alpha
        let d = textureSample(diffuse_tex, samp, i.uv);
        return output(lin(d.rgb), d.a);
    }
    if (kind < 0.5 && has(u32(draw.stdc.x + 0.5), F_SHIP)) {
        return ship(i);
    }
    if (kind > 0.5 && kind < 1.5) {
        // a stand-in that glows: its texture as it is
        let base = textureSample(diffuse_tex, samp, i.uv);
        return output(lin(base.rgb * draw.tint.rgb) * draw.params.y, 1.0);
    }
    // planets, clouds, rings, asteroids and every other PixelPdxMeshStandard part
    return standard(i);
}
