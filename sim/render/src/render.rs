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
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct QuadInstance {
    rect: [f32; 4],
    uv: [f32; 4],
    colour: [f32; 4],
    misc: [f32; 4],
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
    pad: [[f32; 4]; 5],
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
            required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
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
    textures: (String, String, String),
    shading: Shading,
    slot: u32,
}

pub const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;

/// The map's pipelines, textures, meshes and buffers on one device, for one target format.
pub struct Renderer {
    quad_alpha: wgpu::RenderPipeline,
    quad_add: wgpu::RenderPipeline,
    line_pipeline: wgpu::RenderPipeline,
    mesh_opaque: wgpu::RenderPipeline,
    mesh_alpha: wgpu::RenderPipeline,
    mesh_add: wgpu::RenderPipeline,
    uniform: wgpu::Buffer,
    view_bind: wgpu::BindGroup,
    texture_layout: wgpu::BindGroupLayout,
    mesh_texture_layout: wgpu::BindGroupLayout,
    draw_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    wrap_sampler: wgpu::Sampler,
    textures: HashMap<String, GpuTexture>,
    meshes: HashMap<String, GpuMesh>,
    mesh_binds: HashMap<(String, String, String), wgpu::BindGroup>,
    quads: Option<wgpu::Buffer>,
    lines: Option<wgpu::Buffer>,
    n_lines: u32,
    draw_uniforms: Option<(wgpu::Buffer, wgpu::BindGroup)>,
    mesh_draws: Vec<MeshDrawGpu>,
    draws: Vec<Draw>,
    depth: Option<(u32, u32, wgpu::Texture, wgpu::TextureView)>,
    srgb: bool,
    clear: [f32; 3],
}

fn mip_chain(img: &Image) -> Vec<Image> {
    let mut levels = vec![img.clone()];
    while levels.last().map_or(false, |l| l.width > 1 || l.height > 1) {
        let next = levels.last().unwrap().half();
        levels.push(next);
    }
    levels
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
        let view_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("view"), entries: &[uniform_entry(0, false)] });
        let texture_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("texture"), entries: &[texture_entry(0), sampler_entry(1)] });
        let mesh_texture_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("mesh textures"),
            entries: &[texture_entry(0), texture_entry(1), texture_entry(2), sampler_entry(3)],
        });
        let draw_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("draw"), entries: &[uniform_entry(0, true)] });
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("view"),
            size: std::mem::size_of::<ViewUniform>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let view_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("view"),
            layout: &view_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() }],
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
                        cull: Option<wgpu::Face>| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(name),
                layout: Some(layout),
                vertex: wgpu::VertexState {
                    module,
                    entry_point: Some(vs),
                    compilation_options: Default::default(),
                    buffers: &[Some(wgpu::VertexBufferLayout { array_stride: stride as u64, step_mode: step, attributes: attrs })],
                },
                primitive: wgpu::PrimitiveState { cull_mode: cull, ..Default::default() },
                depth_stencil,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask: wgpu::ColorWrites::ALL })],
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
        Renderer {
            quad_alpha: pipeline("quads", &shader, &quad_layout, "vs_quad", "fs_quad", qs, inst, &quad_attrs, Some(wgpu::BlendState::ALPHA_BLENDING), tested.clone(), None),
            quad_add: pipeline("quads added", &shader, &quad_layout, "vs_quad", "fs_quad", qs, inst, &quad_attrs, Some(additive), tested.clone(), None),
            line_pipeline: pipeline("lines", &shader, &line_layout, "vs_lane", "fs_lane", ls, inst, &line_attrs, Some(wgpu::BlendState::ALPHA_BLENDING), tested.clone(), None),
            mesh_opaque: pipeline("meshes", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, None, depth(true, wgpu::CompareFunction::Less), None),
            mesh_alpha: pipeline("meshes blended", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, Some(wgpu::BlendState::ALPHA_BLENDING), tested.clone(), None),
            mesh_add: pipeline("meshes added", &mesh_shader, &mesh_layout, "vs_mesh", "fs_mesh", ms, vert, &mesh_attrs, Some(additive), tested, Some(wgpu::Face::Front)),
            uniform,
            view_bind,
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
            depth: None,
            srgb: format.is_srgb(),
            clear: [0.0; 3],
        }
    }

    fn texture(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, name: &str, img: &Arc<Image>) {
        if self.textures.get(name).is_some_and(|t| Arc::ptr_eq(&t.source, img)) {
            return;
        }
        let levels = mip_chain(img);
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(name),
            size: wgpu::Extent3d { width: img.width, height: img.height, depth_or_array_layers: 1 },
            mip_level_count: levels.len() as u32,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        for (level, l) in levels.iter().enumerate() {
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
        };
        queue.write_buffer(&self.uniform, 0, bytemuck::bytes_of(&view));
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
            }));
            self.draws.push(Draw { layer: b.layer, blend: b.blend, texture: name.clone(), range: start..instances.len() as u32 });
        }
        let lines: Vec<LineInstance> = scene
            .lines
            .iter()
            .map(|l| LineInstance { a: [l.a.0, l.a.1, l.a.2, l.width], b: [l.b.0, l.b.1, l.b.2, 0.0], colour: l.colour })
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
        let mut order: Vec<usize> = (0..scene.meshes.len()).collect();
        order.sort_by_key(|&i| match scene.meshes[i].shading {
            Shading::Lit | Shading::Emissive | Shading::Star => 0,
            Shading::Clouds => 1,
            Shading::Atmosphere | Shading::StarAtmosphere => 2,
        });
        for i in order {
            let m = &scene.meshes[i];
            self.mesh(device, queue, &m.mesh);
            for &t in &m.textures {
                self.texture(device, queue, &textures.names[t], &textures.images[t]);
            }
            let names = (textures.names[m.textures[0]].clone(), textures.names[m.textures[1]].clone(), textures.names[m.textures[2]].clone());
            if !self.mesh_binds.contains_key(&names) {
                let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("mesh textures"),
                    layout: &self.mesh_texture_layout,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&self.textures[&names.0].view) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&self.textures[&names.1].view) },
                        wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&self.textures[&names.2].view) },
                        wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.wrap_sampler) },
                    ],
                });
                self.mesh_binds.insert(names.clone(), bind);
            }
            let k = &m.look;
            let l = |c: [f32; 3]| [c[0], c[1], c[2], 1.0];
            uniforms.push(DrawUniform {
                model: m.model.cols(),
                tint: m.tint,
                params: m.params,
                atmosphere: k.atmosphere,
                extra: [k.width, k.kind, 0.0, 0.0],
                lava: [l(k.lava[0]), l(k.lava[1]), l(k.lava[2])],
                pad: [[0.0; 4]; 5],
            });
            self.mesh_draws.push(MeshDrawGpu { mesh: m.mesh.key.clone(), textures: names, shading: m.shading, slot: (uniforms.len() - 1) as u32 });
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

    /// Records the uploaded scene into `target`, the layers in `mask` (bits of Layer::bit): the
    /// batches in order, the meshes when the Models layer is reached, the lines at the Lanes
    /// layer.
    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, mask: u32) {
        let Some((_, _, _, depth_view)) = &self.depth else { return };
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("map"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(self.clear_colour()), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: depth_view,
                depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Store }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        pass.set_bind_group(0, &self.view_bind, &[]);
        let (Some(quads), Some(lines)) = (&self.quads, &self.lines) else { return };
        let mut meshes_drawn = false;
        let mut lines_drawn = false;
        let draw_meshes = |pass: &mut wgpu::RenderPass<'_>| {
            if mask & Layer::Models.bit() == 0 {
                return;
            }
            let Some((_, draw_bind)) = &self.draw_uniforms else { return };
            for d in &self.mesh_draws {
                let g = &self.meshes[&d.mesh];
                pass.set_pipeline(match d.shading {
                    Shading::Lit | Shading::Emissive | Shading::Star => &self.mesh_opaque,
                    Shading::Clouds => &self.mesh_alpha,
                    Shading::Atmosphere | Shading::StarAtmosphere => &self.mesh_add,
                });
                pass.set_bind_group(1, &self.mesh_binds[&d.textures], &[]);
                pass.set_bind_group(2, draw_bind, &[d.slot * DRAW_SLOT as u32]);
                pass.set_vertex_buffer(0, g.vertices.slice(..));
                pass.set_index_buffer(g.indices.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed(0..g.count, 0, 0..1);
            }
        };
        let draw_lines = |pass: &mut wgpu::RenderPass<'_>| {
            if mask & Layer::Lanes.bit() != 0 && self.n_lines > 0 {
                pass.set_pipeline(&self.line_pipeline);
                pass.set_vertex_buffer(0, lines.slice(..));
                pass.draw(0..6, 0..self.n_lines);
            }
        };
        for d in &self.draws {
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
            pass.set_pipeline(if d.blend == Blend::Add { &self.quad_add } else { &self.quad_alpha });
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
