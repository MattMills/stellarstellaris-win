//! The galaxy map on the GPU (wgpu on Vulkan): hyperlanes as antialiased quads, stars as
//! antialiased discs, in an orthographic view fitted to the galaxy. One renderer for both targets:
//! an offscreen texture read back to memory (the PNG mode) and a window's surface.

use bytemuck::{Pod, Zeroable};

use crate::galaxy::Galaxy;

/// Colours of the map (sRGB, 0..1).
#[derive(Clone, Debug)]
pub struct Style {
    pub background: [f32; 3],
    pub lane: [f32; 3],
    pub unowned: [f32; 3],
    /// An owner's colour darker than this (luma, 0..1) is mixed with white up to it, so that dark
    /// swatches (black, dark_blue, ...) show on the dark background.
    pub min_luma: f32,
}

impl Default for Style {
    fn default() -> Style {
        Style {
            background: [6.0 / 255.0, 8.0 / 255.0, 18.0 / 255.0],
            lane: [72.0 / 255.0, 96.0 / 255.0, 128.0 / 255.0],
            unowned: [150.0 / 255.0, 150.0 / 255.0, 150.0 / 255.0],
            min_luma: 0.3,
        }
    }
}

impl Style {
    /// The colour an owner's systems are drawn with: its map colour, lightened if too dark.
    pub fn owner_colour(&self, rgb: [f32; 3]) -> [f32; 3] {
        let luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        if luma >= self.min_luma || luma >= 1.0 {
            return rgb;
        }
        let t = (self.min_luma - luma) / (1.0 - luma);
        rgb.map(|c| c + (1.0 - c) * t)
    }

    /// The colour system `i` is drawn with.
    pub fn system_colour(&self, galaxy: &Galaxy, i: usize) -> [f32; 3] {
        match galaxy.systems[i].owner {
            Some(o) => self.owner_colour(galaxy.countries[o].rgb),
            None => self.unowned,
        }
    }
}

/// The view of a target of `width` x `height` pixels: the galaxy fitted into it, and the sizes of
/// what is drawn, in pixels.
#[derive(Clone, Copy, Debug)]
pub struct Layout {
    pub width: u32,
    pub height: u32,
    /// map units -> clip space: ndc = p * xy + zw. The save's x is drawn growing to the left
    /// (mirrored, the convention of save viewers such as Stellaris Dashboard; not yet checked
    /// against the game's own map); y grows up.
    pub world_to_ndc: [f32; 4],
    /// pixels per map unit
    pub scale: f32,
    pub star_radius: f32,
    pub unowned_radius: f32,
    pub lane_width: f32,
}

impl Layout {
    pub fn fit(galaxy: &Galaxy, width: u32, height: u32) -> Layout {
        let (mut x0, mut x1, mut y0, mut y1) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
        for s in &galaxy.systems {
            x0 = x0.min(s.x);
            x1 = x1.max(s.x);
            y0 = y0.min(s.y);
            y1 = y1.max(s.y);
        }
        if galaxy.systems.is_empty() {
            (x0, x1, y0, y1) = (-1.0, 1.0, -1.0, 1.0);
        }
        let (w, h) = (width.max(1) as f32, height.max(1) as f32);
        let margin = 0.04 * w.min(h) + 8.0;
        let span_x = (x1 - x0).max(1e-3);
        let span_y = (y1 - y0).max(1e-3);
        let scale = ((w - 2.0 * margin).max(1.0) / span_x).min((h - 2.0 * margin).max(1.0) / span_y);
        let (cx, cy) = (0.5 * (x0 + x1), 0.5 * (y0 + y1));
        let (sx, sy) = (scale * 2.0 / w, scale * 2.0 / h);
        let star_radius = (scale * 1.6).clamp(2.0, 10.0);
        Layout {
            width,
            height,
            world_to_ndc: [-sx, sy, cx * sx, -cy * sy],
            scale,
            star_radius,
            unowned_radius: (star_radius * 0.7).max(1.5),
            lane_width: (scale * 0.45).clamp(1.0, 3.0),
        }
    }

    /// A map position -> pixel coordinates (from the top left corner; pixel (i, j) covers
    /// [i, i+1) x [j, j+1)).
    pub fn to_pixel(&self, x: f32, y: f32) -> (f32, f32) {
        let nx = x * self.world_to_ndc[0] + self.world_to_ndc[2];
        let ny = y * self.world_to_ndc[1] + self.world_to_ndc[3];
        ((nx + 1.0) * 0.5 * self.width as f32, (1.0 - ny) * 0.5 * self.height as f32)
    }
}

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
struct StarInstance {
    centre: [f32; 2],
    radius: f32,
    pad: f32,
    colour: [f32; 4],
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

/// The map's pipelines and buffers on one device, for one target format.
pub struct Renderer {
    star_pipeline: wgpu::RenderPipeline,
    lane_pipeline: wgpu::RenderPipeline,
    uniform: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    stars: wgpu::Buffer,
    lanes: wgpu::Buffer,
    n_stars: u32,
    n_lanes: u32,
    srgb: bool,
    pub style: Style,
    galaxy: Galaxy,
}

impl Renderer {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat, galaxy: &Galaxy, style: Style) -> Renderer {
        let shader = device.create_shader_module(wgpu::include_wgsl!("galaxy.wgsl"));
        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
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
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("view"),
            size: std::mem::size_of::<ViewUniform>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("view"),
            layout: &bgl,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() }],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("galaxy"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });
        let attr = |shader_location: u32, format: wgpu::VertexFormat, offset: usize| wgpu::VertexAttribute {
            format,
            offset: offset as u64,
            shader_location,
        };
        // as laid out in StarInstance and LaneInstance
        let star_attrs = [
            attr(0, wgpu::VertexFormat::Float32x2, std::mem::offset_of!(StarInstance, centre)),
            attr(1, wgpu::VertexFormat::Float32, std::mem::offset_of!(StarInstance, radius)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(StarInstance, colour)),
        ];
        let lane_attrs = [
            attr(0, wgpu::VertexFormat::Float32x2, std::mem::offset_of!(LaneInstance, a)),
            attr(1, wgpu::VertexFormat::Float32x2, std::mem::offset_of!(LaneInstance, b)),
            attr(2, wgpu::VertexFormat::Float32x4, std::mem::offset_of!(LaneInstance, colour)),
            attr(3, wgpu::VertexFormat::Float32, std::mem::offset_of!(LaneInstance, width)),
        ];
        let pipeline = |name: &str, vs: &str, fs: &str, stride: usize, attrs: &[wgpu::VertexAttribute]| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(name),
                layout: Some(&layout),
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
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let star_pipeline = pipeline("stars", "vs_star", "fs_star", std::mem::size_of::<StarInstance>(), &star_attrs);
        let lane_pipeline = pipeline("lanes", "vs_lane", "fs_lane", std::mem::size_of::<LaneInstance>(), &lane_attrs);
        let n_stars = galaxy.systems.len() as u32;
        let n_lanes = galaxy.lanes.len() as u32;
        let stars = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("stars"),
            size: (n_stars.max(1) as usize * std::mem::size_of::<StarInstance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let lanes = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("lanes"),
            size: (n_lanes.max(1) as usize * std::mem::size_of::<LaneInstance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Renderer {
            star_pipeline,
            lane_pipeline,
            uniform,
            bind_group,
            stars,
            lanes,
            n_stars,
            n_lanes,
            srgb: format.is_srgb(),
            style,
            galaxy: galaxy.clone(),
        }
    }

    /// Fits the galaxy to a target of `width` x `height` pixels and uploads the view and the
    /// instances (whose sizes are in pixels).
    pub fn layout(&self, queue: &wgpu::Queue, width: u32, height: u32) -> Layout {
        let l = Layout::fit(&self.galaxy, width, height);
        let view = ViewUniform {
            world_to_ndc: l.world_to_ndc,
            px_to_ndc: [2.0 / width.max(1) as f32, 2.0 / height.max(1) as f32],
            srgb: self.srgb as u32,
            pad: 0,
        };
        queue.write_buffer(&self.uniform, 0, bytemuck::bytes_of(&view));
        let g = &self.galaxy;
        // unowned stars first, owned ones over them
        let mut order: Vec<usize> = (0..g.systems.len()).collect();
        order.sort_by_key(|&i| g.systems[i].owner.is_some());
        let stars: Vec<StarInstance> = order
            .iter()
            .map(|&i| {
                let s = &g.systems[i];
                let c = self.style.system_colour(g, i);
                StarInstance {
                    centre: [s.x, s.y],
                    radius: if s.owner.is_some() { l.star_radius } else { l.unowned_radius },
                    pad: 0.0,
                    colour: [c[0], c[1], c[2], 1.0],
                }
            })
            .collect();
        let lc = self.style.lane;
        let lanes: Vec<LaneInstance> = g
            .lanes
            .iter()
            .map(|&(a, b)| {
                let (sa, sb) = (&g.systems[a as usize], &g.systems[b as usize]);
                LaneInstance {
                    a: [sa.x, sa.y],
                    b: [sb.x, sb.y],
                    colour: [lc[0], lc[1], lc[2], 1.0],
                    width: l.lane_width,
                    pad: [0.0; 3],
                }
            })
            .collect();
        if !stars.is_empty() {
            queue.write_buffer(&self.stars, 0, bytemuck::cast_slice(&stars));
        }
        if !lanes.is_empty() {
            queue.write_buffer(&self.lanes, 0, bytemuck::cast_slice(&lanes));
        }
        l
    }

    /// The clear colour for the target (linear when the target stores sRGB).
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
        let b = self.style.background;
        wgpu::Color { r: to(b[0]), g: to(b[1]), b: to(b[2]), a: 1.0 }
    }

    /// Records the map into `target`: cleared, the lanes, then the stars.
    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView) {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("galaxy"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(self.clear_colour()), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_bind_group(0, &self.bind_group, &[]);
        if self.n_lanes > 0 {
            pass.set_pipeline(&self.lane_pipeline);
            pass.set_vertex_buffer(0, self.lanes.slice(..));
            pass.draw(0..6, 0..self.n_lanes);
        }
        if self.n_stars > 0 {
            pass.set_pipeline(&self.star_pipeline);
            pass.set_vertex_buffer(0, self.stars.slice(..));
            pass.draw(0..6, 0..self.n_stars);
        }
    }
}

/// Renders the map offscreen into an RGBA8 image of `width` x `height` (rows top to bottom, no
/// padding). Returns the pixels, the layout used and the adapter's description.
pub fn render_offscreen(
    galaxy: &Galaxy,
    width: u32,
    height: u32,
    want: Option<&str>,
) -> Result<(Vec<u8>, Layout, String), String> {
    let instance = instance();
    let (adapter, device, queue) = pollster::block_on(open_device(&instance, want, None))?;
    let adapter_text = describe(&adapter.get_info());
    eprintln!("rendering on: {adapter_text}");
    let format = wgpu::TextureFormat::Rgba8Unorm;
    let renderer = Renderer::new(&device, format, galaxy, Style::default());
    let layout = renderer.layout(&queue, width, height);

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("galaxy"),
        size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    let row = width as usize * 4;
    let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT as usize;
    let padded = row.div_ceil(align) * align;
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("readback"),
        size: (padded * height as usize) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("galaxy") });
    renderer.draw(&mut encoder, &view);
    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo {
            texture: &texture,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::TexelCopyBufferInfo {
            buffer: &readback,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(padded as u32),
                rows_per_image: Some(height),
            },
        },
        wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
    );
    let t0 = std::time::Instant::now();
    queue.submit([encoder.finish()]);

    let slice = readback.slice(..);
    let (tx, rx) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r);
    });
    device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| format!("poll: {e}"))?;
    rx.recv().map_err(|e| format!("map: {e}"))?.map_err(|e| format!("map: {e}"))?;
    let mut pixels = Vec::with_capacity(row * height as usize);
    {
        let data = slice.get_mapped_range().map_err(|e| format!("map: {e}"))?;
        for y in 0..height as usize {
            pixels.extend_from_slice(&data[y * padded..y * padded + row]);
        }
    }
    readback.unmap();
    eprintln!("rendered {width}x{height} in {:.0} ms", t0.elapsed().as_secs_f64() * 1000.0);
    Ok((pixels, layout, adapter_text))
}
