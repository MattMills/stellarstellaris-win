//! The map on the GPU (wgpu on Vulkan): a scene's textured quads (alpha-blended or added) and its
//! hyperlanes, for one target format. Textures are the game's, decoded on the CPU, with their mip
//! chains built on the CPU too. One renderer for both targets: offscreen textures read back to
//! memory (the PNG mode, one render per layer mask for the checks) and a window's surface.

use std::collections::HashMap;
use std::sync::Arc;

use bytemuck::{Pod, Zeroable};

use crate::dds::Image;
use crate::scene::{Blend, Layer, Scene, Textures};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ViewUniform {
    world_to_ndc: [f32; 4],
    px_to_ndc: [f32; 2],
    srgb: u32,
    pad: u32,
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
struct LaneInstance {
    a: [f32; 2],
    b: [f32; 2],
    colour: [f32; 4],
    width: f32,
    pad: [f32; 3],
}

/// The adapter picked to render: its description, for reports.
pub fn describe(info: &wgpu::AdapterInfo) -> String {
    format!(
        "{} ({:?}, {:?}, driver {} {}, vendor {:#06x} device {:#06x})",
        info.name, info.device_type, info.backend, info.driver, info.driver_info, info.vendor, info.device
    )
}

/// A Vulkan instance (wgpu's environment variables apply, e.g. WGPU_VALIDATION; the backend is
/// always Vulkan).
pub fn instance() -> wgpu::Instance {
    let mut desc = wgpu::InstanceDescriptor::new_without_display_handle_from_env();
    desc.backends = wgpu::Backends::VULKAN;
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

/// The Vulkan adapters, best first (hardware before software), those whose name contains `want`
/// (any case) if given, and those that can present to `surface` if given; the first that gives a
/// device is used.
pub async fn open_device(
    instance: &wgpu::Instance,
    want: Option<&str>,
    surface: Option<&wgpu::Surface<'_>>,
) -> Result<(wgpu::Adapter, wgpu::Device, wgpu::Queue), String> {
    let mut adapters = instance.enumerate_adapters(wgpu::Backends::VULKAN).await;
    for a in &adapters {
        eprintln!("vulkan adapter: {}", describe(&a.get_info()));
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
            "no Vulkan adapter{}{}",
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
    Err(format!("no Vulkan device: {}", errors.join("; ")))
}

struct GpuTexture {
    /// the image it was made from (a new image under the same name replaces it)
    source: Arc<Image>,
    _texture: wgpu::Texture,
    bind: wgpu::BindGroup,
}

struct Draw {
    layer: Layer,
    blend: Blend,
    texture: String,
    range: std::ops::Range<u32>,
}

/// The map's pipelines, textures and buffers on one device, for one target format.
pub struct Renderer {
    quad_alpha: wgpu::RenderPipeline,
    quad_add: wgpu::RenderPipeline,
    lane_pipeline: wgpu::RenderPipeline,
    uniform: wgpu::Buffer,
    view_bind: wgpu::BindGroup,
    texture_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    textures: HashMap<String, GpuTexture>,
    quads: Option<wgpu::Buffer>,
    lanes: Option<wgpu::Buffer>,
    n_lanes: u32,
    draws: Vec<Draw>,
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
        let view_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("view"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let texture_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("texture"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
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
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("linear"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            ..Default::default()
        });
        let quad_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("quads"),
            bind_group_layouts: &[Some(&view_layout), Some(&texture_layout)],
            immediate_size: 0,
        });
        let lane_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("lanes"),
            bind_group_layouts: &[Some(&view_layout)],
            immediate_size: 0,
        });
        let attr = |shader_location: u32, format: wgpu::VertexFormat, offset: usize| wgpu::VertexAttribute {
            format,
            offset: offset as u64,
            shader_location,
        };
        let quad_attrs = [
            attr(0, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, rect)),
            attr(1, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, uv)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, colour)),
            attr(3, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(QuadInstance, misc)),
        ];
        let lane_attrs = [
            attr(0, wgpu::VertexFormat::Float32x2, std::mem::offset_of!(LaneInstance, a)),
            attr(1, wgpu::VertexFormat::Float32x2, std::mem::offset_of!(LaneInstance, b)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(LaneInstance, colour)),
            attr(3, wgpu::VertexFormat::Float32, std::mem::offset_of!(LaneInstance, width)),
        ];
        let additive = wgpu::BlendState {
            color: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::SrcAlpha,
                dst_factor: wgpu::BlendFactor::One,
                operation: wgpu::BlendOperation::Add,
            },
            alpha: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::Zero,
                dst_factor: wgpu::BlendFactor::One,
                operation: wgpu::BlendOperation::Add,
            },
        };
        let pipeline = |name: &str,
                        layout: &wgpu::PipelineLayout,
                        vs: &str,
                        fs: &str,
                        stride: usize,
                        attrs: &[wgpu::VertexAttribute],
                        blend: wgpu::BlendState| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(name),
                layout: Some(layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some(vs),
                    compilation_options: Default::default(),
                    buffers: &[Some(wgpu::VertexBufferLayout {
                        array_stride: stride as u64,
                        step_mode: wgpu::VertexStepMode::Instance,
                        attributes: attrs,
                    })],
                },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format, blend: Some(blend), write_mask: wgpu::ColorWrites::ALL })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let qs = std::mem::size_of::<QuadInstance>();
        let ls = std::mem::size_of::<LaneInstance>();
        Renderer {
            quad_alpha: pipeline("quads", &quad_layout, "vs_quad", "fs_quad", qs, &quad_attrs, wgpu::BlendState::ALPHA_BLENDING),
            quad_add: pipeline("quads added", &quad_layout, "vs_quad", "fs_quad", qs, &quad_attrs, additive),
            lane_pipeline: pipeline("lanes", &lane_layout, "vs_lane", "fs_lane", ls, &lane_attrs, wgpu::BlendState::ALPHA_BLENDING),
            uniform,
            view_bind,
            texture_layout,
            sampler,
            textures: HashMap::new(),
            quads: None,
            lanes: None,
            n_lanes: 0,
            draws: Vec::new(),
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
                wgpu::TexelCopyTextureInfo {
                    texture: &texture,
                    mip_level: level as u32,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
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
        self.textures.insert(name.to_string(), GpuTexture { source: img.clone(), _texture: texture, bind });
    }

    /// Uploads a scene for a target of its layout's size: the view, the textures it uses (those
    /// not uploaded yet), its quads and lanes.
    pub fn upload(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, scene: &Scene, textures: &Textures) {
        let l = &scene.layout;
        let view = ViewUniform {
            world_to_ndc: l.world_to_ndc,
            px_to_ndc: [2.0 / l.width.max(1) as f32, 2.0 / l.height.max(1) as f32],
            srgb: self.srgb as u32,
            pad: 0,
        };
        queue.write_buffer(&self.uniform, 0, bytemuck::bytes_of(&view));
        self.clear = scene.clear;

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
                misc: [q.rot, if q.screen { 1.0 } else { 0.0 }, 0.0, 0.0],
            }));
            self.draws.push(Draw { layer: b.layer, blend: b.blend, texture: name.clone(), range: start..instances.len() as u32 });
        }
        let lanes: Vec<LaneInstance> = scene
            .lanes
            .iter()
            .map(|s| LaneInstance { a: [s[0], s[1]], b: [s[2], s[3]], colour: scene.lane_colour, width: l.lane_width, pad: [0.0; 3] })
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
        self.lanes = Some(buffer("lanes", bytemuck::cast_slice(&lanes)));
        self.n_lanes = lanes.len() as u32;
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

    /// Records the uploaded scene into `target`, the layers in `mask` (bits of Layer::bit).
    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, mask: u32) {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("map"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(self.clear_colour()), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_bind_group(0, &self.view_bind, &[]);
        let (Some(quads), Some(lanes)) = (&self.quads, &self.lanes) else { return };
        let mut lanes_drawn = false;
        let draw_lanes = |pass: &mut wgpu::RenderPass<'_>| {
            if mask & Layer::Lanes.bit() != 0 && self.n_lanes > 0 {
                pass.set_pipeline(&self.lane_pipeline);
                pass.set_vertex_buffer(0, lanes.slice(..));
                pass.draw(0..6, 0..self.n_lanes);
            }
        };
        for d in &self.draws {
            // the lanes go between the borders and the stars
            if !lanes_drawn && d.layer as u32 > Layer::Lanes as u32 {
                draw_lanes(&mut pass);
                lanes_drawn = true;
            }
            if mask & d.layer.bit() == 0 || d.range.is_empty() {
                continue;
            }
            pass.set_pipeline(if d.blend == Blend::Add { &self.quad_add } else { &self.quad_alpha });
            pass.set_bind_group(1, &self.textures[&d.texture].bind, &[]);
            pass.set_vertex_buffer(0, quads.slice(..));
            pass.draw(0..6, d.range.clone());
        }
        if !lanes_drawn {
            draw_lanes(&mut pass);
        }
    }
}

/// An offscreen device and target: renders an uploaded scene with any layer mask and reads it
/// back.
pub struct Offscreen {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub adapter: String,
    pub renderer: Renderer,
}

pub const OFFSCREEN_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

impl Offscreen {
    pub fn new(want: Option<&str>) -> Result<Offscreen, String> {
        let instance = instance();
        let (adapter, device, queue) = pollster::block_on(open_device(&instance, want, None))?;
        let adapter = describe(&adapter.get_info());
        let renderer = Renderer::new(&device, OFFSCREEN_FORMAT);
        Ok(Offscreen { device, queue, adapter, renderer })
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
