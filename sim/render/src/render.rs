//! The map on the GPU (wgpu: Vulkan, DX12 on Windows): a scene's textured quads (on the galactic
//! plane, facing the camera, or on the screen; alpha-blended or added), its lines (hyperlanes,
//! trails, orbits) and its meshes (the game's models, lit), seen through the scene's view (a
//! perspective camera, or the 2D map's top-down orthographic view). Textures are the game's,
//! decoded on the CPU, with their mip chains built on the CPU too. One renderer for both targets:
//! offscreen textures read back to memory (the PNGs, one render per layer mask for the checks)
//! and a window's surface.

use std::collections::HashMap;
use std::sync::Arc;

use bytemuck::{Pod, Zeroable};

use crate::dds::Image;
use crate::scene::{Blend, Layer, MeshData, MeshVertex, QuadKind, Scene, Shading, Textures};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ViewUniform {
    view_proj: [[f32; 4]; 4],
    right: [f32; 4],
    up: [f32; 4],
    eye: [f32; 4],
    light: [f32; 4],
    px_to_ndc: [f32; 2],
    focal: f32,
    srgb: u32,
    /// 1: the HDR scene (colours in linear space, nothing clamped)
    linear: u32,
    _pad: [u32; 3],
    /// the star's light (colour x intensity) and the planets' back light (gfx/lights, gfx/worldgfx)
    light_colour: [f32; 4],
    back_light: [f32; 4],
    /// the ships' lights: cam_light_1..3_diffuse, rim_light_diffuse, ambient (linear)
    cam_lights: [[f32; 4]; 5],
}

/// One post-effect pass's constants (post.wgsl's Post), one 256-byte slot each.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable, Default)]
struct PostUniform {
    inv_src: [f32; 2],
    axis: f32,
    weight0: f32,
    weights: [f32; 4],
    offsets: [f32; 4],
    bright_threshold: f32,
    emissive_bloom: f32,
    middle_grey: f32,
    min_hdr: f32,
    max_hdr: f32,
    srgb_out: u32,
    use_lut: u32,
    _pad: f32,
    uv_scale: [f32; 2],
    _pad2: [f32; 2],
}

const POST_SLOT: u64 = 256;
/// the post effects' constant slots: bright, luminance, 4 per bloom level, restore
const POST_SLOTS: u64 = 3 + 4 * MAX_BLOOM_LEVELS as u64;
const MAX_BLOOM_LEVELS: u32 = 16;
/// the scene's format under the post effects
pub const HDR_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;

/// The bloom's blur kernel as CGameRendering::Bloom makes it (4.5.2 Linux, read from the code):
/// a Gaussian of 2 sigma² = max(2 x width², 0.01) over taps 0..8, normalised over the 17 taps, x
/// `scale`; the centre weight and four bilinear pairs (taps 1+2, 3+4, 5+6, 7+8: their summed
/// weight at their weighted offset).
fn bloom_kernel(width: f32, scale: f32) -> (f32, [f32; 4], [f32; 4]) {
    let s2 = (2.0 * width * width).max(0.01);
    let w: Vec<f32> = (0..=8).map(|k| (-((k * k) as f32) / s2).exp()).collect();
    let total = w[0] + 2.0 * w[1..].iter().sum::<f32>();
    let n = scale / total;
    let (mut weights, mut offsets) = ([0.0; 4], [0.0; 4]);
    for i in 0..4 {
        let (a, b) = (w[2 * i + 1], w[2 * i + 2]);
        weights[i] = (a + b) * n;
        offsets[i] = if a + b > 0.0 { ((2 * i + 1) as f32 * a + (2 * i + 2) as f32 * b) / (a + b) } else { 0.0 };
    }
    (w[0] * n, weights, offsets)
}

/// The view's bind group: its uniform, the galaxy view's six map textures (map.wgsl) and a
/// clamping linear sampler.
fn view_bind_with(device: &wgpu::Device, layout: &wgpu::BindGroupLayout, uniform: &wgpu::Buffer, maps: [&wgpu::TextureView; 6], sampler: &wgpu::Sampler) -> wgpu::BindGroup {
    fn t(b: u32, v: &wgpu::TextureView) -> wgpu::BindGroupEntry<'_> {
        wgpu::BindGroupEntry { binding: b, resource: wgpu::BindingResource::TextureView(v) }
    }
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("view"),
        layout,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
            t(1, maps[0]),
            t(2, maps[1]),
            t(3, maps[2]),
            t(4, maps[3]),
            t(5, maps[4]),
            t(7, maps[5]),
            wgpu::BindGroupEntry { binding: 6, resource: wgpu::BindingResource::Sampler(sampler) },
        ],
    })
}

/// The pipelines of the map and the meshes for one target format.
struct Pipelines {
    quad_alpha: wgpu::RenderPipeline,
    quad_add: wgpu::RenderPipeline,
    line: wgpu::RenderPipeline,
    mesh_opaque: wgpu::RenderPipeline,
    mesh_alpha: wgpu::RenderPipeline,
    mesh_add: wgpu::RenderPipeline,
    /// added, alpha left alone (the game's BlendStateAdditiveBlendNoAlpha)
    mesh_add_rgb: wgpu::RenderPipeline,
    /// both faces, blended, alpha added (BlendStateAlphaBlendWriteAlpha: the planets' rings)
    mesh_ring: wgpu::RenderPipeline,
    /// additive effects (PixelPdxMeshAdditive), back faces culled
    mesh_glow: wgpu::RenderPipeline,
}

/// The post effects' sized resources and their bind groups, for the uploaded scene: the HDR
/// scene; at half its size the bright pass and each bloom level (`level`), the blur's middle
/// (`tmp`), the blurred level (`blurred`) and the accumulated bloom (`bloom`); the luminance.
struct PostFrame {
    size: (u32, u32),
    hdr_view: wgpu::TextureView,
    /// level, tmp, blurred, bloom
    half_views: [wgpu::TextureView; 4],
    lum_view: wgpu::TextureView,
    _textures: Vec<wgpu::Texture>,
    /// reading: the scene (bright), level (luminance, blur x), tmp (blur y), blurred (copies),
    /// the restore's (scene, bloom, luminance, colour cube)
    binds: Vec<wgpu::BindGroup>,
    /// each bloom level's size (the first the half size)
    levels: Vec<(u32, u32)>,
    clear: wgpu::Color,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct QuadInstance {
    rect: [f32; 4],
    uv: [f32; 4],
    colour: [f32; 4],
    misc: [f32; 4],
    fx: [f32; 4],
    fx2: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct LineInstance {
    a: [f32; 4],
    b: [f32; 4],
    colour: [f32; 4],
}

/// A mesh draw's uniform, one per 256-byte slot (dynamic offsets).
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct DrawUniform {
    model: [[f32; 4]; 4],
    tint: [f32; 4],
    params: [f32; 4],
    atmosphere: [f32; 4],
    extra: [f32; 4],
    lava: [[f32; 4]; 3],
    std: [f32; 4],
    /// a ship's PixelPdxMeshShip constants (MeshDraw::ship)
    ship: [[f32; 4]; 4],
}

const DRAW_SLOT: u64 = 256;

/// The adapter picked to render: its description, for reports.
pub fn describe(info: &wgpu::AdapterInfo) -> String {
    format!(
        "{} ({:?}, {:?}, driver {} {}, vendor {:#06x} device {:#06x})",
        info.name, info.device_type, info.backend, info.driver, info.driver_info, info.vendor, info.device
    )
}

/// The graphics API: DX12 on Windows (built only there; old Vulkan drivers crash or draw no
/// hyperlanes), Vulkan elsewhere; `--backend` chooses the other.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Vulkan,
    Dx12,
}

impl Backend {
    pub fn platform_default() -> Backend {
        if cfg!(windows) {
            Backend::Dx12
        } else {
            Backend::Vulkan
        }
    }

    pub fn parse(s: &str) -> Option<Backend> {
        match s.to_ascii_lowercase().as_str() {
            "vulkan" | "vk" => Some(Backend::Vulkan),
            "dx12" | "d3d12" => Some(Backend::Dx12),
            _ => None,
        }
    }

    fn bits(self) -> wgpu::Backends {
        match self {
            Backend::Vulkan => wgpu::Backends::VULKAN,
            Backend::Dx12 => wgpu::Backends::DX12,
        }
    }
}

/// An instance of one backend (wgpu's environment variables apply, e.g. WGPU_VALIDATION).
pub fn instance(backend: Backend) -> wgpu::Instance {
    let mut desc = wgpu::InstanceDescriptor::new_without_display_handle_from_env();
    desc.backends = backend.bits();
    wgpu::Instance::new(desc)
}

fn type_rank(t: wgpu::DeviceType) -> u32 {
    match t {
        wgpu::DeviceType::DiscreteGpu => 0,
        wgpu::DeviceType::IntegratedGpu => 1,
        wgpu::DeviceType::VirtualGpu => 2,
        wgpu::DeviceType::Other => 3,
        wgpu::DeviceType::Cpu => 4,
    }
}

/// The backend's adapters, best first (hardware before software), those whose name contains
/// `want` (any case) if given, and those that can present to `surface` if given; the first that
/// gives a device is used.
pub async fn open_device(
    instance: &wgpu::Instance,
    backend: Backend,
    want: Option<&str>,
    surface: Option<&wgpu::Surface<'_>>,
) -> Result<(wgpu::Adapter, wgpu::Device, wgpu::Queue), String> {
    let mut adapters = instance.enumerate_adapters(backend.bits()).await;
    for a in &adapters {
        eprintln!("{backend:?} adapter: {}", describe(&a.get_info()));
    }
    if let Some(w) = want {
        let w = w.to_lowercase();
        adapters.retain(|a| a.get_info().name.to_lowercase().contains(&w));
    }
    if let Some(s) = surface {
        adapters.retain(|a| a.is_surface_supported(s));
    }
    adapters.sort_by_key(|a| type_rank(a.get_info().device_type));
    if adapters.is_empty() {
        return Err(format!(
            "no {backend:?} adapter{}{}",
            want.map(|w| format!(" named like {w:?}")).unwrap_or_default(),
            if surface.is_some() { " that can present to the window" } else { "" }
        ));
    }
    let mut errors = Vec::new();
    for adapter in adapters {
        let info = adapter.get_info();
        let desc = wgpu::DeviceDescriptor {
            label: Some("stellar-render"),
            required_features: wgpu::Features::empty(),
            // all the adapter has (no downlevel cap)
            required_limits: adapter.limits(),
            ..Default::default()
        };
        match adapter.request_device(&desc).await {
            Ok((device, queue)) => return Ok((adapter, device, queue)),
            Err(e) => {
                eprintln!("{}: no device: {e}", info.name);
                errors.push(format!("{}: {e}", info.name));
            }
        }
    }
    Err(format!("no {backend:?} device: {}", errors.join("; ")))
}

struct GpuTexture {
    /// the image it was made from (a new image under the same name replaces it)
    source: Arc<Image>,
    _texture: wgpu::Texture,
    view: wgpu::TextureView,
    bind: wgpu::BindGroup,
}

struct GpuMesh {
    source: Arc<MeshData>,
    vertices: wgpu::Buffer,
    indices: wgpu::Buffer,
    count: u32,
}

struct Draw {
    layer: Layer,
    blend: Blend,
    texture: String,
    range: std::ops::Range<u32>,
}

struct MeshDrawGpu {
    mesh: String,
    textures: (String, String, String, String, String),
    shading: Shading,
    slot: u32,
}

/// A 3D view inside the GUI (scene::Inset): where it goes in the GUI's draws, its rectangle, its
/// view's bind group and its meshes.
struct InsetGpu {
    batch: usize,
    rect: [f32; 4],
    bind: wgpu::BindGroup,
    _buffer: wgpu::Buffer,
    draws: Vec<MeshDrawGpu>,
    /// its sky: the uniform (and its buffer) and the textures' bind groups
    sky: Option<(wgpu::Buffer, wgpu::BindGroup, wgpu::BindGroup)>,
}

/// The order meshes are drawn in: opaque first, then blended and added.
fn mesh_order(meshes: &[crate::scene::MeshDraw]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..meshes.len()).collect();
    order.sort_by_key(|&i| match meshes[i].shading {
        Shading::Lit | Shading::Emissive | Shading::Star => 0,
        Shading::Clouds | Shading::Ring | Shading::Button => 1,
        Shading::Atmosphere | Shading::StarAtmosphere | Shading::Additive => 2,
    });
    order
}

pub const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;

/// The map's pipelines, textures, meshes and buffers on one device, for one target format.
pub struct Renderer {
    /// for the target's format (the 2D map, the front end, the GUI over a 3D view)
    ldr: Pipelines,
    /// for the HDR scene under the post effects
    hdr: Pipelines,
    uniform: wgpu::Buffer,
    view_bind: wgpu::BindGroup,
    view_layout: wgpu::BindGroupLayout,
    /// the map textures the view bind group holds (their names), rebuilt when they change
    view_maps: Option<[String; 6]>,
    gui_uniform: wgpu::Buffer,
    gui_view_bind: wgpu::BindGroup,
    post_bright: wgpu::RenderPipeline,
    post_lum: wgpu::RenderPipeline,
    post_blur: wgpu::RenderPipeline,
    post_copy: wgpu::RenderPipeline,
    post_add: wgpu::RenderPipeline,
    post_restore: wgpu::RenderPipeline,
    post_textures_layout: wgpu::BindGroupLayout,
    post_uniform: wgpu::Buffer,
    post_uniform_bind: wgpu::BindGroup,
    _dummy: wgpu::Texture,
    dummy_view: wgpu::TextureView,
    _dummy_cube: wgpu::Texture,
    dummy_cube_view: wgpu::TextureView,
    post: Option<PostFrame>,
    sky_pipeline: wgpu::RenderPipeline,
    sky_pipeline_ldr: wgpu::RenderPipeline,
    sky_uniform_layout: wgpu::BindGroupLayout,
    sky_layout: wgpu::BindGroupLayout,
    sky_uniform: wgpu::Buffer,
    sky_uniform_bind: wgpu::BindGroup,
    sky_bind: Option<wgpu::BindGroup>,
    cubes: HashMap<String, (Arc<Image>, wgpu::Texture, wgpu::TextureView)>,
    texture_layout: wgpu::BindGroupLayout,
    mesh_texture_layout: wgpu::BindGroupLayout,
    draw_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    wrap_sampler: wgpu::Sampler,
    textures: HashMap<String, GpuTexture>,
    meshes: HashMap<String, GpuMesh>,
    mesh_binds: HashMap<(String, String, String, String, String), wgpu::BindGroup>,
    quads: Option<wgpu::Buffer>,
    lines: Option<wgpu::Buffer>,
    n_lines: u32,
    draw_uniforms: Option<(wgpu::Buffer, wgpu::BindGroup)>,
    mesh_draws: Vec<MeshDrawGpu>,
    draws: Vec<Draw>,
    insets: Vec<InsetGpu>,
    depth: Option<(u32, u32, wgpu::Texture, wgpu::TextureView)>,
    srgb: bool,
    clear: [f32; 3],
}

/// The mip levels below the image's own (level 0 is the image: not copied).
fn mip_chain(img: &Image) -> Vec<Image> {
    let mut levels: Vec<Image> = Vec::new();
    loop {
        let last = levels.last().unwrap_or(img);
        if last.width <= 1 && last.height <= 1 {
            return levels;
        }
        let next = last.half();
        levels.push(next);
    }
}

/// A GPU resource a scene uses: a texture or a cube map (its index in the scene's textures), or a
/// mesh.
pub enum Res<'a> {
    Texture(usize),
    Cube(usize),
    Mesh(&'a Arc<MeshData>),
}

/// Every GPU resource `scene` uses, as [`Renderer::upload`] takes them.
pub fn scene_resources(scene: &Scene) -> Vec<Res<'_>> {
    let mut v = Vec::new();
    if let Some(m) = scene.maps {
        v.extend(m.iter().map(|&i| Res::Texture(i)));
    }
    // (an inset's marker batch has no texture)
    v.extend(scene.batches.iter().filter(|b| b.texture != usize::MAX).map(|b| Res::Texture(b.texture)));
    if let Some((i, _)) = scene.env {
        v.push(Res::Cube(i));
    }
    for i in &scene.insets {
        v.extend(i.env.map(|(c, _)| Res::Cube(c)));
    }
    for m in scene.meshes.iter().chain(scene.insets.iter().flat_map(|i| i.meshes.iter())) {
        v.push(Res::Mesh(&m.mesh));
        v.extend(m.textures.iter().map(|&t| Res::Texture(t)));
        if let Some(c) = m.cube {
            v.push(Res::Cube(c));
        }
    }
    if let Some(s) = &scene.sky {
        v.push(Res::Cube(s.cube));
        v.extend(s.lut.map(Res::Texture));
    }
    if let Some(p) = &scene.post {
        v.extend(p.lut.map(Res::Texture));
    }
    v
}

/// The mip chains made ahead of their upload (the UI thread makes them: ui.rs), by the image's
/// address: the image (weak, so that the address is known to be its), and the chain until the
/// render thread takes it. A texture's mip chain is made on the CPU (a 2048x2048 one in 25 ms):
/// made there, its upload takes the render thread only the copy.
struct Premip {
    image: std::sync::Weak<Image>,
    mips: Option<Arc<Vec<Image>>>,
}
static PREMIPS: std::sync::Mutex<Option<HashMap<usize, Premip>>> = std::sync::Mutex::new(None);

/// The mip chain of `img` made now, for its upload later on another thread (small images are left
/// to the upload). Once per image.
pub fn premip(img: &Arc<Image>) {
    if (img.width as usize) * (img.height as usize) < 128 * 128 {
        return;
    }
    let key = Arc::as_ptr(img) as usize;
    {
        let guard = PREMIPS.lock().unwrap();
        if let Some(p) = guard.as_ref().and_then(|m| m.get(&key)) {
            if p.image.upgrade().is_some_and(|i| Arc::ptr_eq(&i, img)) {
                return;
            }
        }
    }
    let mips = Arc::new(mip_chain(img));
    let mut guard = PREMIPS.lock().unwrap();
    let map = guard.get_or_insert_with(HashMap::new);
    // the images gone are forgotten, their chains with them: an image the render thread never
    // took (a scene it skipped for a newer one, as a day's map textures at the fastest speed) left
    // its chain here (16 MB and more for the borders' map), 150 MB a second at the fastest speed
    if map.len() > 32 {
        map.retain(|_, p| p.image.strong_count() > 0);
    }
    map.insert(key, Premip { image: Arc::downgrade(img), mips: Some(mips) });
}

/// The mip chain of `img`: the one made ahead if there is one (taken), else made now.
fn mips_of(img: &Arc<Image>) -> Arc<Vec<Image>> {
    let key = Arc::as_ptr(img) as usize;
    if let Some(map) = PREMIPS.lock().unwrap().as_mut() {
        if let Some(p) = map.get_mut(&key) {
            if p.image.upgrade().is_some_and(|i| Arc::ptr_eq(&i, img)) {
                if let Some(m) = p.mips.take() {
                    return m;
                }
            }
        }
    }
    Arc::new(mip_chain(img))
}

impl Renderer {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Renderer {
        let shader = device.create_shader_module(wgpu::include_wgsl!("map.wgsl"));
        let mesh_shader = device.create_shader_module(wgpu::include_wgsl!("mesh.wgsl"));
        let uniform_entry = |binding: u32, dynamic: bool| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
            ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: dynamic, min_binding_size: None },
            count: None,
        };
        let texture_entry = |binding: u32| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let sampler_entry = |binding: u32| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
            count: None,
        };
        let cube_entry = |binding: u32| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::Cube,
                multisampled: false,
            },
            count: None,
        };
        // the view: its uniform; the galaxy view's map textures (terra incognita, the borders'
        // distance, edge and fill colours, the dust's colour map: map.wgsl) and their sampler
        let view_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("view"),
            entries: &[uniform_entry(0, false), texture_entry(1), texture_entry(2), texture_entry(3), texture_entry(4), texture_entry(5), sampler_entry(6), texture_entry(7)],
        });
        let texture_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("texture"), entries: &[texture_entry(0), sampler_entry(1)] });
        let mesh_texture_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("mesh textures"),
            entries: &[
                texture_entry(0),
                texture_entry(1),
                texture_entry(2),
                sampler_entry(3),
                // a cube map: the stars' lava noise (gfx/worldgfx/lava_noise.dds)
                cube_entry(4),
                // the world's environment map
                cube_entry(5),
            ],
        });
        let draw_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("draw"), entries: &[uniform_entry(0, true)] });
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("view"),
            size: std::mem::size_of::<ViewUniform>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let sampler_with = |mode: wgpu::AddressMode| {
            device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("linear"),
                address_mode_u: mode,
                address_mode_v: mode,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                mipmap_filter: wgpu::MipmapFilterMode::Linear,
                ..Default::default()
            })
        };
        let sampler = sampler_with(wgpu::AddressMode::ClampToEdge);
        let wrap_sampler = sampler_with(wgpu::AddressMode::Repeat);
        let quad_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("quads"),
            bind_group_layouts: &[Some(&view_layout), Some(&texture_layout)],
            immediate_size: 0,
        });
        let line_layout =
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: Some("lines"), bind_group_layouts: &[Some(&view_layout)], immediate_size: 0 });
        let mesh_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("meshes"),
            bind_group_layouts: &[Some(&view_layout), Some(&mesh_texture_layout), Some(&draw_layout)],
            immediate_size: 0,
        });
        let attr = |shader_location: u32, format: wgpu::VertexFormat, offset: usize| wgpu::VertexAttribute { format, offset: offset as u64, shader_location };
        let quad_attrs = [
            attr(0, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, rect)),
            attr(1, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, uv)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, colour)),
            attr(3, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, misc)),
            attr(4, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, fx)),
            attr(5, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, fx2)),
        ];
        let line_attrs = [
            attr(0, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(LineInstance, a)),
            attr(1, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(LineInstance, b)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(LineInstance, colour)),
        ];
        let mesh_attrs = [
            attr(0, wgpu::VertexFormat::Float32x3, std::mem::offset_of!(MeshVertex, pos)),
            attr(1, wgpu::VertexFormat::Float32x3, std::mem::offset_of!(MeshVertex, normal)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(MeshVertex, tangent)),
            attr(3, wgpu::VertexFormat::Float32x2, std::mem::offset_of!(MeshVertex, uv)),
        ];
        let additive = wgpu::BlendState {
            color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::SrcAlpha, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
            alpha: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::Zero, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
        };
        // the 2D map and the galaxy are drawn in order, tested against the meshes' depth (which
        // is cleared to the far plane) and not written; meshes write depth
        let depth = |write: bool, compare: wgpu::CompareFunction| {
            Some(wgpu::DepthStencilState {
                format: DEPTH_FORMAT,
                depth_write_enabled: Some(write),
                depth_compare: Some(compare),
                stencil: wgpu::StencilState::default(),
                bias: wgpu::DepthBiasState::default(),
            })
        };
        #[allow(clippy::too_many_arguments)]
        let pipeline = |name: &str,
                        module: &wgpu::ShaderModule,
                        layout: &wgpu::PipelineLayout,
                        vs: &str,
                        fs: &str,
                        stride: usize,
                        step: wgpu::VertexStepMode,
                        attrs: &[wgpu::VertexAttribute],
                        blend: Option<wgpu::BlendState>,
                        depth_stencil: Option<wgpu::DepthStencilState>,
                        cull: Option<wgpu::Face>,
                        format: wgpu::TextureFormat,
                        write_mask: wgpu::ColorWrites| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(name),
                layout: Some(layout),
                vertex: wgpu::VertexState {
                    module,
                    entry_point: Some(vs),
                    compilation_options: Default::default(),
                    buffers: &[Some(wgpu::VertexBufferLayout { array_stride: stride as u64, step_mode: step, attributes: attrs })],
                },
                // the game's meshes wind clockwise seen from outside under its left-handed view (D3D)
                primitive: wgpu::PrimitiveState { front_face: wgpu::FrontFace::Cw, cull_mode: cull, ..Default::default() },
                depth_stencil,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let qs = std::mem::size_of::<QuadInstance>();
        let ls = std::mem::size_of::<LineInstance>();
        let ms = std::mem::size_of::<MeshVertex>();
        let inst = wgpu::VertexStepMode::Instance;
        let vert = wgpu::VertexStepMode::Vertex;
        let tested = depth(false, wgpu::CompareFunction::LessEqual);
        // the HDR scene keeps the bloom's mask in alpha, as the game's scene does: the opaque
        // meshes write their emissive; the additive passes (the game's BlendStateAdditiveBlend and
        // the particles' BlendStateAdditive: SRC_ALPHA, ONE, alpha written, no alpha factors of
        // their own, so OpenGL's glBlendFunc blends alpha by the same factors) add alpha x alpha;
        // the alpha-blended ones (RGB only in the game) leave it
        let additive_hdr = wgpu::BlendState { color: additive.color, alpha: additive.color };
        let ring_blend = wgpu::BlendState {
            color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::SrcAlpha, dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha, operation: wgpu::BlendOperation::Add },
            alpha: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
        };
        let set = |format: wgpu::TextureFormat, hdr: bool| {
            let (all, colour) = (wgpu::ColorWrites::ALL, if hdr { wgpu::ColorWrites::COLOR } else { wgpu::ColorWrites::ALL });
            let alpha = Some(wgpu::BlendState::ALPHA_BLENDING);
            let add = Some(if hdr { additive_hdr } else { additive });
            Pipelines {
                quad_alpha: pipeline("quads", &shader, &quad_layout, "vs_quad", "fs_quad", qs, inst, &quad_attrs, alpha, tested.clone(), None, format, colour),
                quad_add: pipeline("quads added", &shader, &quad_layout, "vs_quad", "fs_quad", qs, inst, &quad_attrs, add, tested.clone(), None, format, all),
                line: pipeline("lines", &shader, &line_layout, "vs_lane", "fs_lane", ls, inst, &line_attrs, alpha, tested.clone(), None, format, colour),
                mesh_opaque: pipeline("meshes", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, None, depth(true, wgpu::CompareFunction::Less), Some(wgpu::Face::Back), format, all),
                mesh_alpha: pipeline("meshes blended", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, alpha, tested.clone(), Some(wgpu::Face::Back), format, colour),
                mesh_add: pipeline("meshes added", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, add, tested.clone(), Some(wgpu::Face::Front), format, all),
                mesh_add_rgb: pipeline("meshes added rgb", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, Some(additive), tested.clone(), Some(wgpu::Face::Front), format, colour),
                // BlendStateAlphaBlendWriteAlpha: SRC_ALPHA, INV_SRC_ALPHA; DestAlpha ONE with
                // the default SourceAlpha ONE: alpha added
                mesh_ring: pipeline("meshes ring", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, Some(ring_blend), tested.clone(), None, format, all),
                // PixelPdxMeshAdditive effects: BlendStateAdditiveBlend (alpha written), the default
                // rasterizer (back faces culled), no depth write
                mesh_glow: pipeline("meshes glow", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, add, tested.clone(), Some(wgpu::Face::Back), format, all),
            }
        };
        let ldr = set(format, false);
        let hdr = set(HDR_FORMAT, true);

        // the post effects (post.wgsl): a uniform slot per pass, four textures and a sampler
        let post_shader = device.create_shader_module(wgpu::include_wgsl!("post.wgsl"));
        let post_uniform_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("post"), entries: &[uniform_entry(0, true)] });
        let post_textures_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("post textures"),
            entries: &[texture_entry(0), texture_entry(1), texture_entry(2), texture_entry(3), sampler_entry(4)],
        });
        let post_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("post"),
            bind_group_layouts: &[Some(&post_uniform_layout), Some(&post_textures_layout)],
            immediate_size: 0,
        });
        let full_blend = |name: &str, fs: &str, format: wgpu::TextureFormat, blend: Option<wgpu::BlendState>| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(name),
                layout: Some(&post_layout),
                vertex: wgpu::VertexState { module: &post_shader, entry_point: Some("vs_full"), compilation_options: Default::default(), buffers: &[] },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &post_shader,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask: wgpu::ColorWrites::ALL })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let full = |name: &str, fs: &str, format: wgpu::TextureFormat| full_blend(name, fs, format, None);
        // downsample.shader's BlendStateAdditive (ONE, ONE): the levels into the bloom
        let one_one = wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add };
        let post_add = full_blend("post bloom add", "fs_copy", HDR_FORMAT, Some(wgpu::BlendState { color: one_one, alpha: one_one }));
        let post_uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("post"),
            size: POST_SLOT * POST_SLOTS,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let post_uniform_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("post"),
            layout: &post_uniform_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &post_uniform, offset: 0, size: wgpu::BufferSize::new(std::mem::size_of::<PostUniform>() as u64) }),
            }],
        });
        let gui_uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gui view"),
            size: std::mem::size_of::<ViewUniform>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let dummy = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("dummy"),
            size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let dummy_view = dummy.create_view(&wgpu::TextureViewDescriptor::default());
        let view_bind = view_bind_with(device, &view_layout, &uniform, [&dummy_view; 6], &sampler);
        let gui_view_bind = view_bind_with(device, &view_layout, &gui_uniform, [&dummy_view; 6], &sampler);
        let dummy_cube = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("dummy cube"),
            size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 6 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let dummy_cube_view = dummy_cube.create_view(&wgpu::TextureViewDescriptor { dimension: Some(wgpu::TextureViewDimension::Cube), ..Default::default() });
        // the sky (sky.wgsl): a uniform, a cube map, a colour cube and a sampler; the HDR scene only
        let sky_shader = device.create_shader_module(wgpu::include_wgsl!("sky.wgsl"));
        let sky_uniform_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("sky"), entries: &[uniform_entry(0, false)] });
        let sky_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sky textures"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::Cube,
                        multisampled: false,
                    },
                    count: None,
                },
                texture_entry(1),
                sampler_entry(2),
            ],
        });
        let sky_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sky"),
            bind_group_layouts: &[Some(&sky_uniform_layout), Some(&sky_layout)],
            immediate_size: 0,
        });
        let sky_pipeline_for = |format: wgpu::TextureFormat| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("sky"),
                layout: Some(&sky_pipeline_layout),
                vertex: wgpu::VertexState { module: &sky_shader, entry_point: Some("vs_sky"), compilation_options: Default::default(), buffers: &[] },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: depth(false, wgpu::CompareFunction::LessEqual),
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &sky_shader,
                    entry_point: Some("fs_sky"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::COLOR })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let sky_pipeline = sky_pipeline_for(HDR_FORMAT);
        // an inset's sky (scene::Inset), drawn with the GUI over the target
        let sky_pipeline_ldr = sky_pipeline_for(format);
        let sky_uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("sky"),
            size: 80,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let sky_uniform_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sky"),
            layout: &sky_uniform_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: sky_uniform.as_entire_binding() }],
        });
        Renderer {
            ldr,
            hdr,
            uniform,
            view_bind,
            view_layout,
            view_maps: None,
            gui_uniform,
            gui_view_bind,
            post_bright: full("post bright", "fs_bright", HDR_FORMAT),
            post_lum: full("post luminance", "fs_luminance", HDR_FORMAT),
            post_blur: full("post blur", "fs_blur", HDR_FORMAT),
            post_copy: full("post copy", "fs_copy", HDR_FORMAT),
            post_add,
            post_restore: full("post restore", "fs_restore", format),
            post_textures_layout,
            post_uniform,
            post_uniform_bind,
            _dummy: dummy,
            dummy_view,
            _dummy_cube: dummy_cube,
            dummy_cube_view,
            post: None,
            sky_pipeline,
            sky_pipeline_ldr,
            sky_uniform_layout,
            sky_layout,
            sky_uniform,
            sky_uniform_bind,
            sky_bind: None,
            cubes: HashMap::new(),
            texture_layout,
            mesh_texture_layout,
            draw_layout,
            sampler,
            wrap_sampler,
            textures: HashMap::new(),
            meshes: HashMap::new(),
            mesh_binds: HashMap::new(),
            quads: None,
            lines: None,
            n_lines: 0,
            draw_uniforms: None,
            mesh_draws: Vec::new(),
            draws: Vec::new(),
            insets: Vec::new(),
            depth: None,
            srgb: format.is_srgb(),
            clear: [0.0; 3],
        }
    }

    fn texture(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, name: &str, img: &Arc<Image>) {
        if self.textures.get(name).is_some_and(|t| Arc::ptr_eq(&t.source, img)) {
            return;
        }
        let t0 = std::time::Instant::now();
        let levels = mips_of(img);
        crate::prof(&format!("upload: {name} {}x{} mips", img.width, img.height), t0);
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(name),
            size: wgpu::Extent3d { width: img.width, height: img.height, depth_or_array_layers: 1 },
            mip_level_count: levels.len() as u32 + 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        // (level 0 the image itself, the chain the levels below it)
        for (level, l) in std::iter::once(&**img).chain(levels.iter()).enumerate() {
            queue.write_texture(
                wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: level as u32, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                &l.rgba,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(l.width * 4), rows_per_image: Some(l.height) },
                wgpu::Extent3d { width: l.width, height: l.height, depth_or_array_layers: 1 },
            );
        }
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(name),
            layout: &self.texture_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        // a replaced texture: the mesh bind groups that used it are made again
        self.mesh_binds.retain(|k, _| k.0 != name && k.1 != name && k.2 != name);
        self.textures.insert(name.to_string(), GpuTexture { source: img.clone(), _texture: texture, view, bind });
        crate::prof(&format!("upload: {name} in all"), t0);
    }

    /// A cube map (dds::load_cube: six faces stacked) as a cube texture, one mip.
    fn cube(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, name: &str, img: &Arc<Image>) {
        if self.cubes.get(name).is_some_and(|c| Arc::ptr_eq(&c.0, img)) {
            return;
        }
        self.mesh_binds.retain(|k, _| k.3 != name && k.4 != name);
        let size = img.width;
        let levels = crate::dds::cube_levels(img);
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(name),
            size: wgpu::Extent3d { width: size, height: size, depth_or_array_layers: 6 },
            mip_level_count: levels,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let mut offset = 0usize;
        for m in 0..levels {
            let s = (size >> m).max(1);
            let bytes = (s * s * 24) as usize;
            queue.write_texture(
                wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: m, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                &img.rgba[offset..offset + bytes],
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(s * 4), rows_per_image: Some(s) },
                wgpu::Extent3d { width: s, height: s, depth_or_array_layers: 6 },
            );
            offset += bytes;
        }
        let view = texture.create_view(&wgpu::TextureViewDescriptor { dimension: Some(wgpu::TextureViewDimension::Cube), ..Default::default() });
        self.cubes.insert(name.to_string(), (img.clone(), texture, view));
    }

    fn mesh(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, m: &Arc<MeshData>) {
        if self.meshes.get(&m.key).is_some_and(|g| Arc::ptr_eq(&g.source, m)) {
            return;
        }
        let buffer = |label: &str, bytes: &[u8], usage: wgpu::BufferUsages| {
            let buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: (bytes.len().max(16) as u64).next_multiple_of(4),
                usage: usage | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            if !bytes.is_empty() {
                queue.write_buffer(&buf, 0, bytes);
            }
            buf
        };
        let vertices = buffer(&m.key, bytemuck::cast_slice(&m.vertices), wgpu::BufferUsages::VERTEX);
        let indices = buffer(&m.key, bytemuck::cast_slice(&m.indices), wgpu::BufferUsages::INDEX);
        self.meshes.insert(m.key.clone(), GpuMesh { source: m.clone(), vertices, indices, count: m.indices.len() as u32 });
    }

    /// Uploads a scene for a target of its view's size: the view, the textures and meshes it uses
    /// (those not uploaded yet), its quads, lines and mesh draws, and a depth buffer of its size.
    /// The resources of `scene` not uploaded yet, about `budget` bytes of them in this call (the
    /// first one whatever its size); whether all it uses are uploaded now, so that
    /// [`Renderer::upload`] uploads no more than the scene's own buffers. The render thread calls
    /// it each frame for a scene newly published, and draws the one before until it is ready: a
    /// frame never uploads more than the budget (docs/render.md section 12).
    pub fn preload(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, scene: &Scene, textures: &Textures, budget: usize) -> bool {
        let mut spent = 0usize;
        let mut ready = true;
        for r in scene_resources(scene) {
            let bytes = match &r {
                Res::Texture(i) => {
                    let (name, img) = (&textures.names[*i], &textures.images[*i]);
                    if self.textures.get(name).is_some_and(|t| Arc::ptr_eq(&t.source, img)) {
                        continue;
                    }
                    img.rgba.len() * 4 / 3
                }
                Res::Cube(i) => {
                    let (name, img) = (&textures.names[*i], &textures.images[*i]);
                    if self.cubes.get(name).is_some_and(|c| Arc::ptr_eq(&c.0, img)) {
                        continue;
                    }
                    img.rgba.len()
                }
                Res::Mesh(m) => {
                    if self.meshes.get(&m.key).is_some_and(|g| Arc::ptr_eq(&g.source, m)) {
                        continue;
                    }
                    m.vertices.len() * std::mem::size_of::<MeshVertex>() + m.indices.len() * 4
                }
            };
            if spent > 0 && spent + bytes > budget {
                ready = false;
                continue;
            }
            spent += bytes;
            match r {
                Res::Texture(i) => self.texture(device, queue, &textures.names[i], &textures.images[i]),
                Res::Cube(i) => self.cube(device, queue, &textures.names[i], &textures.images[i]),
                Res::Mesh(m) => self.mesh(device, queue, m),
            }
        }
        ready
    }

    pub fn upload(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, scene: &Scene, textures: &Textures) {
        let v = &scene.view;
        let view = ViewUniform {
            view_proj: v.view_proj.cols(),
            right: [v.right.0, v.right.1, v.right.2, 0.0],
            up: [v.up.0, v.up.1, v.up.2, 0.0],
            eye: [v.eye.0, v.eye.1, v.eye.2, 1.0],
            light: scene.light,
            px_to_ndc: [2.0 / v.width.max(1) as f32, 2.0 / v.height.max(1) as f32],
            focal: v.focal_px,
            srgb: self.srgb as u32,
            linear: 0,
            _pad: [0; 3],
            light_colour: scene.light_colour,
            back_light: scene.back_light,
            cam_lights: scene.cam_lights,
        };
        // the scene's view (linear under the post effects) and the GUI's (over the target)
        let hdr = scene.post.is_some();
        let scene_view = ViewUniform { srgb: if hdr { 0 } else { self.srgb as u32 }, linear: hdr as u32, ..view };
        queue.write_buffer(&self.uniform, 0, bytemuck::bytes_of(&scene_view));
        // the galaxy view's map textures in the view's bind group (rebuilt when they change)
        let maps = scene.maps.map(|m| m.map(|i| textures.names[i].clone()));
        if let Some(m) = scene.maps {
            for i in m {
                self.texture(device, queue, &textures.names[i], &textures.images[i]);
            }
        }
        if maps.is_some() || maps != self.view_maps {
            let views: [&wgpu::TextureView; 6] = match &maps {
                Some(names) => [0, 1, 2, 3, 4, 5].map(|k| &self.textures[&names[k]].view),
                None => [&self.dummy_view; 6],
            };
            self.view_bind = view_bind_with(device, &self.view_layout, &self.uniform, views, &self.sampler);
            self.view_maps = maps;
        }
        queue.write_buffer(&self.gui_uniform, 0, bytemuck::bytes_of(&view));
        self.clear = scene.clear;
        if self.depth.as_ref().is_none_or(|d| (d.0, d.1) != (v.width, v.height)) {
            let texture = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("depth"),
                size: wgpu::Extent3d { width: v.width.max(1), height: v.height.max(1), depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: DEPTH_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            self.depth = Some((v.width, v.height, texture, view));
        }

        let mut instances = Vec::new();
        self.draws.clear();
        for b in &scene.batches {
            if b.texture == usize::MAX {
                // an inset's place (scene::Inset): nothing of its own
                self.draws.push(Draw { layer: b.layer, blend: b.blend, texture: String::new(), range: 0..0 });
                continue;
            }
            let name = &textures.names[b.texture];
            self.texture(device, queue, name, &textures.images[b.texture]);
            let start = instances.len() as u32;
            instances.extend(b.quads.iter().map(|q| QuadInstance {
                rect: q.rect,
                uv: q.uv,
                colour: q.colour,
                misc: [
                    q.rot,
                    match q.kind {
                        QuadKind::Plane => 0.0,
                        QuadKind::Screen => 1.0,
                        QuadKind::Billboard => 2.0,
                    },
                    q.height,
                    q.least_px,
                ],
                fx: q.fx,
                fx2: q.fx2,
            }));
            self.draws.push(Draw { layer: b.layer, blend: b.blend, texture: name.clone(), range: start..instances.len() as u32 });
        }
        let lines: Vec<LineInstance> = scene
            .lines
            .iter()
            .map(|l| LineInstance { a: [l.a.0, l.a.1, l.a.2, l.width], b: [l.b.0, l.b.1, l.b.2, l.mode], colour: l.colour })
            .collect();
        let buffer = |label: &str, bytes: &[u8]| {
            let buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: (bytes.len().max(16) as u64).next_multiple_of(4),
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            if !bytes.is_empty() {
                queue.write_buffer(&buf, 0, bytes);
            }
            buf
        };
        self.quads = Some(buffer("quads", bytemuck::cast_slice(&instances)));
        self.lines = Some(buffer("lines", bytemuck::cast_slice(&lines)));
        self.n_lines = lines.len() as u32;

        // meshes: opaque first, then blended and added
        self.mesh_draws.clear();
        let mut uniforms: Vec<DrawUniform> = Vec::new();
        // the world's environment map (its levels by glossiness), shared by every mesh
        let env_name = scene.env.map(|(i, _)| {
            self.cube(device, queue, &textures.names[i], &textures.images[i]);
            textures.names[i].clone()
        });
        for i in mesh_order(&scene.meshes) {
            let d = self.mesh_draw(device, queue, &scene.meshes[i], textures, &env_name, scene.env.map_or(0.0, |e| e.1), hdr, &mut uniforms);
            self.mesh_draws.push(d);
        }
        // the insets' meshes (drawn with the GUI, over the target: not in the HDR scene) and their
        // views
        self.insets.clear();
        for inset in &scene.insets {
            let Some(v) = &inset.view else { continue };
            let env_name = inset.env.map(|(i, _)| {
                self.cube(device, queue, &textures.names[i], &textures.images[i]);
                textures.names[i].clone()
            });
            let mut draws = Vec::new();
            for i in mesh_order(&inset.meshes) {
                draws.push(self.mesh_draw(device, queue, &inset.meshes[i], textures, &env_name, inset.env.map_or(0.0, |e| e.1), false, &mut uniforms));
            }
            let u = ViewUniform {
                view_proj: v.view_proj.cols(),
                right: [v.right.0, v.right.1, v.right.2, 0.0],
                up: [v.up.0, v.up.1, v.up.2, 0.0],
                eye: [v.eye.0, v.eye.1, v.eye.2, 1.0],
                light: inset.light,
                px_to_ndc: [2.0 / v.width.max(1) as f32, 2.0 / v.height.max(1) as f32],
                focal: v.focal_px,
                srgb: self.srgb as u32,
                linear: 0,
                _pad: [0; 3],
                light_colour: inset.light_colour,
                back_light: scene.back_light,
                cam_lights: inset.cam_lights,
            };
            let buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("inset view"),
                size: std::mem::size_of::<ViewUniform>() as u64,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            queue.write_buffer(&buf, 0, bytemuck::bytes_of(&u));
            let bind = view_bind_with(device, &self.view_layout, &buf, [&self.dummy_view; 6], &self.sampler);
            let sky = inset.sky.as_ref().map(|s| self.sky_binds(device, queue, s, v, textures, !self.srgb));
            self.insets.push(InsetGpu { batch: inset.batch, rect: inset.rect, bind, _buffer: buf, draws, sky });
        }
        if !uniforms.is_empty() {
            let buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("draws"),
                size: uniforms.len() as u64 * DRAW_SLOT,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            queue.write_buffer(&buf, 0, bytemuck::cast_slice(&uniforms));
            let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("draws"),
                layout: &self.draw_layout,
                entries: &[wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &buf, offset: 0, size: wgpu::BufferSize::new(DRAW_SLOT) }),
                }],
            });
            self.draw_uniforms = Some((buf, bind));
        }
        self.upload_post(device, queue, scene, textures);
    }

    /// A sky's uniform (its direction, edges, shifts and flags; `encode`: gamma-encoded for a
    /// target that is not sRGB) and its textures' bind group.
    fn sky_binds(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, s: &crate::scene::SkyDraw, v: &crate::camera::ViewParams, textures: &Textures, encode: bool) -> (wgpu::Buffer, wgpu::BindGroup, wgpu::BindGroup) {
        let name = textures.names[s.cube].clone();
        self.cube(device, queue, &name, &textures.images[s.cube]);
        let lut = s.lut.map(|i| {
            self.texture(device, queue, &textures.names[i], &textures.images[i]);
            textures.names[i].clone()
        });
        let (sx, sy) = (v.width as f32 / (2.0 * v.focal_px), v.height as f32 / (2.0 * v.focal_px));
        let fwd = v.right.cross(v.up);
        let uniform: [[f32; 4]; 5] = [
            [fwd.0, fwd.1, fwd.2, 0.0],
            [v.right.0 * sx, v.right.1 * sx, v.right.2 * sx, 0.0],
            [v.up.0 * sy, v.up.1 * sy, v.up.2 * sy, 0.0],
            [s.hsv_shift[0], s.hsv_shift[1], s.hsv_shift[2], s.ycocg as u32 as f32],
            [lut.is_some() as u32 as f32, 1.0, encode as u32 as f32, 0.0],
        ];
        let buf = device.create_buffer(&wgpu::BufferDescriptor { label: Some("inset sky"), size: 80, usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
        queue.write_buffer(&buf, 0, bytemuck::cast_slice(&uniform));
        let ubind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("inset sky"),
            layout: &self.sky_uniform_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() }],
        });
        let lut_view = lut.as_ref().map_or(&self.dummy_view, |n| &self.textures[n].view);
        let tbind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("inset sky"),
            layout: &self.sky_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&self.cubes[&name].2) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(lut_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        (buf, ubind, tbind)
    }

    /// One mesh's textures, bind group and draw constants (its slot in `uniforms`).
    #[allow(clippy::too_many_arguments)]
    fn mesh_draw(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        m: &crate::scene::MeshDraw,
        textures: &Textures,
        env_name: &Option<String>,
        env_intensity: f32,
        hdr: bool,
        uniforms: &mut Vec<DrawUniform>,
    ) -> MeshDrawGpu {
        {
            self.mesh(device, queue, &m.mesh);
            for &t in &m.textures {
                self.texture(device, queue, &textures.names[t], &textures.images[t]);
            }
            let cube_name = m.cube.map(|i| {
                self.cube(device, queue, &textures.names[i], &textures.images[i]);
                textures.names[i].clone()
            });
            let names = (
                textures.names[m.textures[0]].clone(),
                textures.names[m.textures[1]].clone(),
                textures.names[m.textures[2]].clone(),
                cube_name.clone().unwrap_or_default(),
                env_name.clone().unwrap_or_default(),
            );
            if !self.mesh_binds.contains_key(&names) {
                let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("mesh textures"),
                    layout: &self.mesh_texture_layout,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&self.textures[&names.0].view) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&self.textures[&names.1].view) },
                        wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&self.textures[&names.2].view) },
                        wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.wrap_sampler) },
                        wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(cube_name.as_ref().map_or(&self.dummy_cube_view, |c| &self.cubes[c].2)) },
                        wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(env_name.as_ref().map_or(&self.dummy_cube_view, |c| &self.cubes[c].2)) },
                    ],
                });
                self.mesh_binds.insert(names.clone(), bind);
            }
            let k = &m.look;
            let l = |c: [f32; 3]| [c[0], c[1], c[2], 1.0];
            // the planet class's atmosphere colour, made linear in the HDR scene (^2.2: GfxToLinear
            // in SetStarEntityCustomData / SetPlanetEntityCustomData); its intensity as it is
            let a = k.atmosphere;
            let atmosphere = if hdr { [a[0].max(0.0).powf(2.2), a[1].max(0.0).powf(2.2), a[2].max(0.0).powf(2.2), a[3]] } else { a };
            uniforms.push(DrawUniform {
                model: m.model.cols(),
                tint: m.tint,
                params: m.params,
                atmosphere,
                extra: [k.width, k.kind, 0.0, 0.0],
                lava: [l(k.lava[0]), l(k.lava[1]), l(k.lava[2])],
                std: [m.std[0], m.std[1], env_intensity, m.std[3]],
                ship: m.ship,
            });
            MeshDrawGpu { mesh: m.mesh.key.clone(), textures: names, shading: m.shading, slot: (uniforms.len() - 1) as u32 }
        }
    }

    /// The post effects of an uploaded scene: their targets (kept while the size holds), constants
    /// and bind groups; the sky.
    fn upload_post(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, scene: &Scene, textures: &Textures) {
        let v = &scene.view;
        let Some(p) = scene.post.clone() else {
            self.post = None;
            self.sky_bind = None;
            return;
        };
        // the sky
        self.sky_bind = None;
        if let Some(s) = &scene.sky {
            let name = textures.names[s.cube].clone();
            self.cube(device, queue, &name, &textures.images[s.cube]);
            let lut = s.lut.map(|i| {
                self.texture(device, queue, &textures.names[i], &textures.images[i]);
                textures.names[i].clone()
            });
            let (sx, sy) = (v.width as f32 / (2.0 * v.focal_px), v.height as f32 / (2.0 * v.focal_px));
            let fwd = v.right.cross(v.up);
            let uniform: [[f32; 4]; 5] = [
                [fwd.0, fwd.1, fwd.2, 0.0],
                [v.right.0 * sx, v.right.1 * sx, v.right.2 * sx, 0.0],
                [v.up.0 * sy, v.up.1 * sy, v.up.2 * sy, 0.0],
                [s.hsv_shift[0], s.hsv_shift[1], s.hsv_shift[2], s.ycocg as u32 as f32],
                [lut.is_some() as u32 as f32, 1.0, 0.0, 0.0],
            ];
            queue.write_buffer(&self.sky_uniform, 0, bytemuck::cast_slice(&uniform));
            let lut_view = lut.as_ref().map_or(&self.dummy_view, |n| &self.textures[n].view);
            self.sky_bind = Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("sky"),
                layout: &self.sky_layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&self.cubes[&name].2) },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(lut_view) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                ],
            }));
        }
        let (w, h) = (v.width.max(1), v.height.max(1));
        let (hw, hh) = ((w / 2).max(1), (h / 2).max(1));
        let make = |label: &str, w: u32, h: u32| {
            let t = device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: HDR_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let view = t.create_view(&wgpu::TextureViewDescriptor::default());
            (t, view)
        };
        let reuse = self.post.as_ref().is_some_and(|f| f.size == (w, h));
        let (hdr_view, half_views, lum_view, textures_kept) = if reuse {
            let f = self.post.take().unwrap();
            (f.hdr_view, f.half_views, f.lum_view, f._textures)
        } else {
            let (t0, v0) = make("hdr scene", w, h);
            let (t1, v1) = make("bloom level", hw, hh);
            let (t2, v2) = make("bloom tmp", hw, hh);
            let (t3, v3) = make("bloom blurred", hw, hh);
            let (t4, v4) = make("bloom", hw, hh);
            let (t5, v5) = make("luminance", 1, 1);
            (v0, [v1, v2, v3, v4], v5, vec![t0, t1, t2, t3, t4, t5])
        };
        let lut_name = p.lut.map(|i| {
            self.texture(device, queue, &textures.names[i], &textures.images[i]);
            textures.names[i].clone()
        });
        // the bloom's levels: bloom_iterations of them while a level is at least 4 x 4, each half
        // the last (RenderPostEffects' loop)
        let mut levels = Vec::new();
        let (mut lw, mut lh) = (hw, hh);
        while levels.len() < p.bloom_iterations.min(MAX_BLOOM_LEVELS) as usize && lw >= 4 && lh >= 4 {
            levels.push((lw, lh));
            lw /= 2;
            lh /= 2;
        }
        // the constants: bright, luminance, per level (blur x, blur y, add, halve), restore
        let (weight0, weights, offsets) = bloom_kernel(p.bloom_width, p.bloom_scale);
        let base = PostUniform {
            bright_threshold: p.bright_threshold,
            emissive_bloom: p.emissive_bloom,
            middle_grey: p.middle_grey,
            min_hdr: p.hdr_min,
            max_hdr: p.hdr_max,
            srgb_out: self.srgb as u32,
            use_lut: lut_name.is_some() as u32,
            weight0,
            weights,
            offsets,
            uv_scale: [1.0, 1.0],
            ..Default::default()
        };
        let mut slots = vec![PostUniform { inv_src: [1.0 / w as f32, 1.0 / h as f32], ..base }, base];
        let inv_half = [1.0 / hw as f32, 1.0 / hh as f32];
        for &(lw, lh) in &levels {
            // the blur over the whole half-size target (the level at its top left, the rest
            // cleared), then the level's part copied
            let part = [lw as f32 / hw as f32, lh as f32 / hh as f32];
            slots.push(PostUniform { inv_src: inv_half, axis: 0.0, ..base });
            slots.push(PostUniform { inv_src: inv_half, axis: 1.0, ..base });
            slots.push(PostUniform { uv_scale: part, ..base });
            slots.push(PostUniform { uv_scale: part, ..base });
        }
        slots.push(base);
        let mut bytes = vec![0u8; slots.len() * POST_SLOT as usize];
        for (k, s) in slots.iter().enumerate() {
            let b = bytemuck::bytes_of(s);
            bytes[k * POST_SLOT as usize..k * POST_SLOT as usize + b.len()].copy_from_slice(b);
        }
        queue.write_buffer(&self.post_uniform, 0, &bytes);
        let bind = |t: [&wgpu::TextureView; 4]| {
            device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("post textures"),
                layout: &self.post_textures_layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(t[0]) },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(t[1]) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(t[2]) },
                    wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(t[3]) },
                    wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                ],
            })
        };
        let d = &self.dummy_view;
        let lut_view = lut_name.as_ref().map_or(d, |n| &self.textures[n].view);
        let binds = vec![
            bind([&hdr_view, d, d, d]),
            bind([&half_views[0], d, d, d]),
            bind([&half_views[1], d, d, d]),
            bind([&half_views[2], d, d, d]),
            bind([&hdr_view, &half_views[3], &lum_view, lut_view]),
        ];
        let lin = |c: f32| {
            let c = c as f64;
            if c <= 0.04045 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        };
        let clear = wgpu::Color { r: lin(scene.clear[0]), g: lin(scene.clear[1]), b: lin(scene.clear[2]), a: 0.0 };
        self.post = Some(PostFrame { size: (w, h), hdr_view, half_views, lum_view, _textures: textures_kept, binds, levels, clear });
    }

    fn clear_colour(&self) -> wgpu::Color {
        let to = |c: f32| {
            let c = c as f64;
            if !self.srgb {
                c
            } else if c <= 0.04045 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        };
        wgpu::Color { r: to(self.clear[0]), g: to(self.clear[1]), b: to(self.clear[2]), a: 1.0 }
    }

    /// Records the uploaded scene into `target`, the layers in `mask` (bits of Layer::bit). Without
    /// post effects: everything straight into the target. With them: the world's layers into the
    /// HDR scene, the game's post-effect chain (post.wgsl) into the target, then the GUI's layers
    /// over it.
    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, mask: u32) {
        let Some(f) = &self.post else {
            self.draw_layers(encoder, target, self.clear_colour(), true, &self.ldr, &self.view_bind, mask, false);
            return;
        };
        let gui = Layer::Gui.bit() | Layer::Text.bit();
        self.draw_layers(encoder, &f.hdr_view, f.clear, true, &self.hdr, &self.view_bind, mask & !gui, true);
        let [level, tmp, blurred, bloom] = &f.half_views;
        self.post_pass(encoder, &self.post_bright, level, 0, &f.binds[0], true, None);
        self.post_pass(encoder, &self.post_lum, &f.lum_view, 1, &f.binds[1], true, None);
        if f.levels.is_empty() {
            self.post_pass(encoder, &self.post_copy, bloom, 0, &f.binds[0], true, Some((0, 0)));
        }
        for (k, &(lw, lh)) in f.levels.iter().enumerate() {
            let s = 2 + 4 * k as u32;
            self.post_pass(encoder, &self.post_blur, tmp, s, &f.binds[1], true, None);
            self.post_pass(encoder, &self.post_blur, blurred, s + 1, &f.binds[2], true, None);
            self.post_pass(encoder, &self.post_add, bloom, s + 2, &f.binds[3], k == 0, None);
            if k + 1 < f.levels.len() {
                // the next level at the top left of the cleared level target
                self.post_pass(encoder, &self.post_copy, level, s + 3, &f.binds[3], true, Some((lw / 2, lh / 2)));
            }
        }
        self.post_pass(encoder, &self.post_restore, target, 2 + 4 * f.levels.len() as u32, &f.binds[4], true, None);
        if mask & gui != 0 {
            self.draw_layers(encoder, target, wgpu::Color::BLACK, false, &self.ldr, &self.gui_view_bind, mask & gui, false);
        }
    }

    /// One full-screen pass of the post effects into `target` (cleared first, or loaded), over
    /// its `viewport` at the top left (all of it when None; nothing drawn when empty).
    #[allow(clippy::too_many_arguments)]
    fn post_pass(&self, encoder: &mut wgpu::CommandEncoder, pipeline: &wgpu::RenderPipeline, target: &wgpu::TextureView, slot: u32, bind: &wgpu::BindGroup, clear: bool, viewport: Option<(u32, u32)>) {
        let load = if clear { wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT) } else { wgpu::LoadOp::Load };
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("post"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load, store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        if let Some((w, h)) = viewport {
            if w == 0 || h == 0 {
                return;
            }
            pass.set_viewport(0.0, 0.0, w as f32, h as f32, 0.0, 1.0);
        }
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &self.post_uniform_bind, &[slot * POST_SLOT as u32]);
        pass.set_bind_group(1, bind, &[]);
        pass.draw(0..3, 0..1);
    }

    /// One pass over `target` (cleared to `clear`, or loaded): the batches of the layers in
    /// `mask` in order, the meshes when the Models layer is reached, the lines at the Lanes layer.
    #[allow(clippy::too_many_arguments)]
    fn draw_layers(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::TextureView,
        clear: wgpu::Color,
        clear_target: bool,
        pipes: &Pipelines,
        view_bind: &wgpu::BindGroup,
        mask: u32,
        sky: bool,
    ) {
        let Some((_, _, _, depth_view)) = &self.depth else { return };
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("map"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: if clear_target { wgpu::LoadOp::Clear(clear) } else { wgpu::LoadOp::Load }, store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: depth_view,
                depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Store }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        if let (true, Some(b)) = (sky && mask & Layer::Background.bit() != 0, &self.sky_bind) {
            // the sky first, behind everything
            pass.set_pipeline(&self.sky_pipeline);
            pass.set_bind_group(0, &self.sky_uniform_bind, &[]);
            pass.set_bind_group(1, b, &[]);
            pass.draw(0..3, 0..1);
        }
        pass.set_bind_group(0, view_bind, &[]);
        let (Some(quads), Some(lines)) = (&self.quads, &self.lines) else { return };
        let mut meshes_drawn = false;
        let mut lines_drawn = false;
        let draw_list = |pass: &mut wgpu::RenderPass<'_>, list: &[MeshDrawGpu]| {
            let Some((_, draw_bind)) = &self.draw_uniforms else { return };
            for d in list {
                let g = &self.meshes[&d.mesh];
                pass.set_pipeline(match d.shading {
                    Shading::Lit | Shading::Emissive | Shading::Star => &pipes.mesh_opaque,
                    Shading::Clouds | Shading::Button => &pipes.mesh_alpha,
                    Shading::Ring => &pipes.mesh_ring,
                    // PdxMeshAtmosphere: BlendStateAdditiveBlendNoAlpha; PdxMeshAtmosphereStar:
                    // BlendStateAdditiveBlend (alpha written: the star's bloom)
                    Shading::Atmosphere => &pipes.mesh_add_rgb,
                    Shading::StarAtmosphere => &pipes.mesh_add,
                    Shading::Additive => &pipes.mesh_glow,
                });
                pass.set_bind_group(1, &self.mesh_binds[&d.textures], &[]);
                pass.set_bind_group(2, draw_bind, &[d.slot * DRAW_SLOT as u32]);
                pass.set_vertex_buffer(0, g.vertices.slice(..));
                pass.set_index_buffer(g.indices.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed(0..g.count, 0, 0..1);
            }
        };
        let draw_meshes = |pass: &mut wgpu::RenderPass<'_>| {
            if mask & Layer::Models.bit() != 0 {
                draw_list(pass, &self.mesh_draws);
            }
        };
        // a 3D view inside the GUI: its meshes in its rectangle, through its own view (the GUI's
        // quads write no depth: the pass's depth, cleared, is the inset's)
        let (tw, th) = (self.depth.as_ref().map_or(1, |d| d.0), self.depth.as_ref().map_or(1, |d| d.1));
        let draw_inset = |pass: &mut wgpu::RenderPass<'_>, inset: &InsetGpu| {
            let [x0, y0, x1, y1] = inset.rect;
            let (x0, y0) = (x0.clamp(0.0, tw as f32), y0.clamp(0.0, th as f32));
            let (x1, y1) = (x1.clamp(x0, tw as f32), y1.clamp(y0, th as f32));
            if x1 - x0 < 1.0 || y1 - y0 < 1.0 {
                return;
            }
            pass.set_viewport(x0, y0, x1 - x0, y1 - y0, 0.0, 1.0);
            pass.set_scissor_rect(x0 as u32, y0 as u32, (x1 - x0) as u32, (y1 - y0) as u32);
            if let Some((_, ubind, tbind)) = &inset.sky {
                pass.set_pipeline(&self.sky_pipeline_ldr);
                pass.set_bind_group(0, ubind, &[]);
                pass.set_bind_group(1, tbind, &[]);
                pass.draw(0..3, 0..1);
            }
            pass.set_bind_group(0, &inset.bind, &[]);
            draw_list(pass, &inset.draws);
            pass.set_viewport(0.0, 0.0, tw as f32, th as f32, 0.0, 1.0);
            pass.set_scissor_rect(0, 0, tw, th);
            pass.set_bind_group(0, view_bind, &[]);
        };
        let draw_lines = |pass: &mut wgpu::RenderPass<'_>| {
            if mask & Layer::Lanes.bit() != 0 && self.n_lines > 0 {
                pass.set_pipeline(&pipes.line);
                pass.set_vertex_buffer(0, lines.slice(..));
                pass.draw(0..6, 0..self.n_lines);
            }
        };
        for (k, d) in self.draws.iter().enumerate() {
            if mask & Layer::Gui.bit() != 0 {
                for inset in self.insets.iter().filter(|i| i.batch == k) {
                    draw_inset(&mut pass, inset);
                }
            }
            if !meshes_drawn && d.layer as u32 >= Layer::Models as u32 {
                draw_meshes(&mut pass);
                meshes_drawn = true;
            }
            // the lines go between the borders (and models) and the stars
            if !lines_drawn && d.layer as u32 > Layer::Lanes as u32 {
                draw_lines(&mut pass);
                lines_drawn = true;
            }
            if mask & d.layer.bit() == 0 || d.range.is_empty() {
                continue;
            }
            pass.set_pipeline(if d.blend == Blend::Add { &pipes.quad_add } else { &pipes.quad_alpha });
            pass.set_bind_group(1, &self.textures[&d.texture].bind, &[]);
            pass.set_vertex_buffer(0, quads.slice(..));
            pass.draw(0..6, d.range.clone());
        }
        if !meshes_drawn {
            draw_meshes(&mut pass);
        }
        if !lines_drawn {
            draw_lines(&mut pass);
        }
    }
}

/// An offscreen device and target: renders an uploaded scene with any layer mask and reads it
/// back.
pub struct Offscreen {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub adapter: String,
    pub info: wgpu::AdapterInfo,
    pub renderer: Renderer,
}

pub const OFFSCREEN_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

impl Offscreen {
    pub fn new(backend: Backend, want: Option<&str>) -> Result<Offscreen, String> {
        let instance = instance(backend);
        let (adapter, device, queue) = pollster::block_on(open_device(&instance, backend, want, None))?;
        let info = adapter.get_info();
        let adapter = describe(&info);
        let renderer = Renderer::new(&device, OFFSCREEN_FORMAT);
        Ok(Offscreen { device, queue, adapter, info, renderer })
    }

    /// Uploads a scene (see Renderer::upload).
    pub fn upload(&mut self, scene: &Scene, textures: &Textures) {
        self.renderer.upload(&self.device, &self.queue, scene, textures);
    }

    /// Draws the uploaded scene's layers in `mask` into a `width` x `height` target and waits for
    /// the GPU to finish, as a window's frame does before its present (no read-back): `bench`'s
    /// frame. `target` keeps the target texture from one frame to the next.
    pub fn draw_frame(&self, width: u32, height: u32, mask: u32, target: &mut Option<(u32, u32, wgpu::Texture)>) -> Result<(), String> {
        if !target.as_ref().is_some_and(|t| t.0 == width && t.1 == height) {
            let texture = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("bench"),
                size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: OFFSCREEN_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            *target = Some((width, height, texture));
        }
        let view = target.as_ref().unwrap().2.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("bench") });
        self.renderer.draw(&mut encoder, &view, mask);
        self.queue.submit([encoder.finish()]);
        self.device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| format!("poll: {e}"))?;
        Ok(())
    }

    /// Renders the uploaded scene's layers in `mask` into a `width` x `height` RGBA8 image (rows
    /// top to bottom).
    pub fn render(&self, width: u32, height: u32, mask: u32) -> Result<Vec<u8>, String> {
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("map"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: OFFSCREEN_FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let row = width as usize * 4;
        let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT as usize;
        let padded = row.div_ceil(align) * align;
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: (padded * height as usize) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("map") });
        self.renderer.draw(&mut encoder, &view, mask);
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded as u32), rows_per_image: Some(height) },
            },
            wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        );
        self.queue.submit([encoder.finish()]);
        let slice = readback.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        self.device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| format!("poll: {e}"))?;
        rx.recv().map_err(|e| format!("map: {e}"))?.map_err(|e| format!("map: {e}"))?;
        let mut pixels = Vec::with_capacity(row * height as usize);
        {
            let data = slice.get_mapped_range().map_err(|e| format!("map: {e}"))?;
            for y in 0..height as usize {
                pixels.extend_from_slice(&data[y * padded..y * padded + row]);
            }
        }
        readback.unmap();
        Ok(pixels)
    }
}
