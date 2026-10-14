// The game's meshes (gfx/models/**/*.mesh) with ports of the game's pixel shaders, simplified
// (gfx/FX/pdxmesh.shader, pdxmesh_ship.fxh, standardfuncsgfx.fxh; docs/render.md section 8):
// - lit (PixelPdxMeshStandard, PixelPdxMeshShip): the normal map unpacked as the game's
//   UnpackRRxGNormal (x = green, y = -alpha), the specular map's green = specular, blue =
//   metalness, alpha = glossiness, the normal map's blue = emissive; planets tinted by their
//   atmosphere towards the limb; ships with fill lights from the camera and a rim light;
// - clouds: the same, blended by the diffuse alpha, clipped towards the limb (IS_CLOUDS);
// - atmospheres (PixelPdxMeshAtmosphere, PixelPdxMeshAtmosphereStar): the back faces of a larger
//   sphere, added, brightest behind the body;
// - stars (PixelPdxMeshStar): lava and stone textures over a noise (a procedural one here: the
//   game's is a cube map), coloured by the star class's gfx/worldgfx settings.
// No shadows, no environment map, no bloom, no tone mapping.

struct View {
    view_proj: mat4x4<f32>,
    right: vec4<f32>,
    up: vec4<f32>,
    eye: vec4<f32>,
    light: vec4<f32>,
    px_to_ndc: vec2<f32>,
    focal: f32,
    srgb: u32,
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
};

@group(0) @binding(0) var<uniform> view: View;
@group(1) @binding(0) var diffuse_tex: texture_2d<f32>;
@group(1) @binding(1) var normal_tex: texture_2d<f32>;
@group(1) @binding(2) var specular_tex: texture_2d<f32>;
@group(1) @binding(3) var samp: sampler;
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
    let s = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    if (view.srgb == 1u) {
        return vec4<f32>(srgb_to_linear(s), alpha);
    }
    return vec4<f32>(s, alpha);
}

fn hash3(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3<f32>(127.1, 311.7, 74.7))) * 43758.5453);
}

// value noise in 0..1
fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(hash3(i), hash3(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(hash3(i + vec3<f32>(0.0, 1.0, 0.0)), hash3(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(hash3(i + vec3<f32>(0.0, 0.0, 1.0)), hash3(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(hash3(i + vec3<f32>(0.0, 1.0, 1.0)), hash3(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

// the light at a point: its direction and colour (the system's star, or the view's direction)
fn light_dir(world: vec3<f32>) -> vec3<f32> {
    if (view.light.w > 0.5) {
        return normalize(view.light.xyz - world);
    }
    return normalize(view.light.xyz);
}

// Blinn-Phong with the glossiness as the exponent (2 .. 2048), energy normalised
fn specular(n: vec3<f32>, l: vec3<f32>, v: vec3<f32>, gloss: f32) -> f32 {
    let h = normalize(l + v);
    let power = exp2(gloss * 10.0 + 1.0);
    return pow(max(dot(n, h), 0.0), power) * (power + 8.0) / 25.13;
}

fn star(i: VsOut) -> vec4<f32> {
    // PixelPdxMeshStar: the noise (the game samples the cube map LavaNoise at the direction
    // three times, at the same direction: 3 x (noise - 0.5)), animated by time (0 here)
    let dir = normalize(i.local);
    let noise = 3.0 * (noise3(dir * 7.0) * 0.6 + noise3(dir * 21.0) * 0.4 - 0.5);
    let animated = sin(noise * 10.0);
    let inv = (1.0 - animated) * 0.5;
    let inv2 = inv * inv;
    let lava_mask = clamp(-animated, 0.0, 1.0) * clamp(-animated, 0.0, 1.0);
    let to_camera = normalize(view.eye.xyz - i.world);
    let parallax = inv * to_camera.xz;
    let lava_tex = textureSample(diffuse_tex, samp, i.uv * 10.0 - parallax * 0.1).rgb;
    let stone_tex = textureSample(normal_tex, samp, i.uv * 25.0 - parallax * 0.15).rgb;
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
    // x 2 as the game; its HDR and bloom brighten it further: a little of the star's colour added
    return output(c * 2.0 + draw.atmosphere.rgb * 0.35, 1.0);
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
    if (kind > 4.5) {
        // PixelPdxMeshAtmosphereStar, on the back faces: colour x NdotV^3, alpha NdotV^4, added
        let ndv = clamp(dot(n0, -v), 0.0, 1.0);
        return vec4<f32>(draw.atmosphere.rgb * pow(ndv, 3.0), pow(ndv, 4.0));
    }
    if (kind > 1.5 && kind < 2.5) {
        // PixelPdxMeshAtmosphere, on the back faces: the colour, lit (x 0.13) by the star,
        // x (NdotV x 1.2)^4, added
        let ndl = max(dot(n0, l), 0.0);
        var c = draw.atmosphere.rgb * 0.15 + draw.atmosphere.rgb * ndl * 0.13 * 2.0 * 1.5;
        let ndv = clamp(dot(n0, -v), 0.0, 1.0);
        c = c * pow(ndv * 1.2, 4.0);
        return vec4<f32>(c, 1.0);
    }
    let base = textureSample(diffuse_tex, samp, i.uv);
    let nm = textureSample(normal_tex, samp, i.uv);
    let sp = textureSample(specular_tex, samp, i.uv);
    if (kind > 0.5 && kind < 1.5) {
        let c = base.rgb * draw.tint.rgb * draw.params.y;
        return output(c, 1.0);
    }
    if (kind > 2.5 && dot(n0, v) < 0.27) {
        // clouds clipped towards the limb
        discard;
    }
    // the normal map (UnpackRRxGNormal): x = green, y = -alpha, z rebuilt; the bitangent
    // cross(normal, tangent) x the tangent's w
    let t = normalize(i.tangent.xyz - n0 * dot(n0, i.tangent.xyz));
    let b = cross(n0, t) * select(1.0, -1.0, i.tangent.w < 0.0);
    let nx = nm.g * 2.0 - 1.0;
    let ny = -(nm.a * 2.0 - 1.0);
    let nz = sqrt(max(0.0, 1.0 - nx * nx - ny * ny));
    var n = normalize(t * nx + b * ny + n0 * nz);
    if (nm.a == 0.0 && nm.g == 0.0) {
        n = n0;
    }
    // the specular map: green the specular, blue the metalness, alpha the glossiness
    let spec_level = sp.g * sp.g * 0.4;
    let metal = 1.0 - (1.0 - sp.b) * (1.0 - sp.b);
    let albedo = base.rgb * draw.tint.rgb;
    let diffuse = mix(albedo, vec3<f32>(0.0), metal);
    let spec_colour = mix(vec3<f32>(spec_level), albedo, metal);
    let ndl = max(dot(n, l), 0.0);
    var light = vec3<f32>(ndl);
    var spec_light = spec_colour * specular(n, l, v, sp.a) * ndl * draw.params.z;
    let ship = draw.extra.y > 1.5 && draw.extra.y < 2.5;
    let planet = (draw.extra.y > 0.5 && draw.extra.y < 1.5) || draw.extra.y > 2.5;
    let planet_glow = draw.extra.y > 2.5;
    if (planet) {
        // the star's light, and the system's back light on the side away from it
        // (CalculateSystemPointLight with IS_PLANET: system_back_light_diffuse, about hsv 0.58
        // 0.25 0.55 for the star classes of gfx/worldgfx)
        light = light * 1.3 + vec3<f32>(0.41, 0.48, 0.55) * max(dot(n, -l), 0.0);
    }
    if (ship) {
        // the ship camera lights (gfx/worldgfx: cam_light_2 from the right, cam_light_3 from
        // above, blue)
        let l2 = normalize(view.right.xyz + v * 0.4 - view.up.xyz * 0.3);
        let l3 = normalize(view.up.xyz + v * 0.5);
        let c2 = vec3<f32>(0.27, 0.38, 0.45);
        let c3 = vec3<f32>(0.49, 0.65, 0.75) * 0.6;
        light = light * 1.35 + c2 * max(dot(n, l2), 0.0) + c3 * max(dot(n, l3), 0.0);
        spec_light = spec_light + spec_colour * specular(n, l3, v, sp.a) * max(dot(n, l3), 0.0) * 0.5;
    }
    // the environment map's reflection (cubemap_intensity 0.4): a sky brighter above the
    // camera, by the glossiness, with Schlick's Fresnel
    let r = reflect(-v, n);
    let sky = mix(vec3<f32>(0.06, 0.07, 0.1), vec3<f32>(0.55, 0.6, 0.7), clamp(dot(r, view.up.xyz) * 0.5 + 0.5, 0.0, 1.0));
    let fresnel = spec_colour + (vec3<f32>(1.0) - spec_colour) * pow(1.0 - max(dot(n, v), 0.0), 5.0) * sp.a;
    var cubemap = 0.4;
    if (planet) {
        cubemap = 0.1;
    }
    spec_light = spec_light + sky * fresnel * cubemap * (0.3 + 0.7 * sp.a);
    var c = diffuse * (vec3<f32>(draw.params.w) + light) + spec_light;
    // emissive: the normal map's blue (EMISSIVE); on planets with NO_PLANET_EMISSIVE everywhere,
    // on the others only the night side's city lights (not drawn)
    var emissive = nm.b;
    if (planet && !planet_glow) {
        emissive = 0.0;
    }
    c = mix(c, albedo, emissive);
    if (planet && draw.atmosphere.a > 0.0) {
        // the atmosphere towards the limb, more on the lit side
        let to_camera = clamp(dot(n0, -v) + draw.extra.x, 0.0, 1.0);
        let to_sun = dot(n0, l) * 0.5 + 0.5;
        let a = mix(to_camera, to_camera * to_sun, 0.5);
        c = mix(c, draw.atmosphere.rgb, a * a * draw.atmosphere.a);
    }
    if (ship) {
        // the rim light (rim_light_diffuse)
        let rim = smoothstep(0.6, 1.0, 1.0 - dot(n0, v));
        c = mix(c, vec3<f32>(0.125, 0.21, 0.25), rim);
    }
    var alpha = 1.0;
    if (kind > 2.5) {
        alpha = base.a * draw.tint.a;
    }
    return output(c, alpha);
}
