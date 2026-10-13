//! The windowed mode: the map in a window (winit), the scene rebuilt for the window's size on
//! resize. Escape or Q closes it; `frames` closes it after that many frames (for tests).

use std::sync::Arc;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowId};

use crate::render::{self, Renderer};
use crate::scene::ALL;
use crate::Map;

struct Shown {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
    /// the size the uploaded scene was built for
    built: (u32, u32),
}

struct App {
    map: Map,
    want: Option<String>,
    frames: Option<u32>,
    drawn: u32,
    instance: wgpu::Instance,
    shown: Option<Shown>,
    error: Option<String>,
}

impl App {
    fn open(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        let attrs = Window::default_attributes()
            .with_title(format!("Stellaris galaxy, {}", self.map.galaxy.date))
            .with_inner_size(winit::dpi::LogicalSize::new(1280.0, 1024.0));
        let window = Arc::new(event_loop.create_window(attrs).map_err(|e| format!("window: {e}"))?);
        let surface = self.instance.create_surface(window.clone()).map_err(|e| format!("surface: {e}"))?;
        let (adapter, device, queue) =
            pollster::block_on(render::open_device(&self.instance, self.want.as_deref(), Some(&surface)))?;
        eprintln!("rendering on: {}", render::describe(&adapter.get_info()));
        let size = window.inner_size();
        let config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or("the surface is not supported by the adapter")?;
        surface.configure(&device, &config);
        eprintln!("surface: {:?} {}x{}, {:?}", config.format, config.width, config.height, config.present_mode);
        let renderer = Renderer::new(&device, config.format);
        window.request_redraw();
        self.shown = Some(Shown { window, surface, device, queue, config, renderer, built: (0, 0) });
        Ok(())
    }

    fn fail(&mut self, event_loop: &ActiveEventLoop, message: String) {
        eprintln!("error: {message}");
        self.error = Some(message);
        event_loop.exit();
    }

    fn redraw(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        let Some(s) = self.shown.as_mut() else { return Ok(()) };
        let size = (s.config.width, s.config.height);
        if s.built != size {
            let frame = self.map.frame(size.0, size.1)?;
            s.renderer.upload(&s.device, &s.queue, &frame.scene, &self.map.textures);
            s.built = size;
        }
        let texture = match s.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                s.surface.configure(&s.device, &s.config);
                s.window.request_redraw();
                return Ok(());
            }
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => return Ok(()),
            other => return Err(format!("the surface gave no frame: {other:?}")),
        };
        let view = texture.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = s.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("frame") });
        s.renderer.draw(&mut encoder, &view, ALL);
        s.queue.submit([encoder.finish()]);
        s.window.pre_present_notify();
        s.queue.present(texture);
        self.drawn += 1;
        if let Some(n) = self.frames {
            if self.drawn >= n {
                eprintln!("{} frames drawn", self.drawn);
                event_loop.exit();
            } else {
                s.window.request_redraw();
            }
        }
        Ok(())
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.shown.is_none() {
            if let Err(e) = self.open(event_loop) {
                self.fail(event_loop, e);
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::KeyboardInput { event: KeyEvent { logical_key, state: ElementState::Pressed, .. }, .. } => {
                let quit = matches!(logical_key, Key::Named(NamedKey::Escape))
                    || matches!(&logical_key, Key::Character(c) if c.as_str().eq_ignore_ascii_case("q"));
                if quit {
                    event_loop.exit();
                }
            }
            WindowEvent::Resized(size) => {
                if let Some(s) = self.shown.as_mut() {
                    if size.width > 0 && size.height > 0 {
                        s.config.width = size.width;
                        s.config.height = size.height;
                        s.surface.configure(&s.device, &s.config);
                        s.window.request_redraw();
                    }
                }
            }
            WindowEvent::RedrawRequested => {
                if let Err(e) = self.redraw(event_loop) {
                    self.fail(event_loop, e);
                }
            }
            _ => {}
        }
    }
}

/// Shows the map in a window until it is closed (or `frames` frames are drawn).
pub fn run(map: Map, want: Option<String>, frames: Option<u32>) -> Result<(), String> {
    let event_loop = EventLoop::new().map_err(|e| format!("event loop: {e}"))?;
    let mut app = App { map, want, frames, drawn: 0, instance: render::instance(), shown: None, error: None };
    event_loop.run_app(&mut app).map_err(|e| format!("event loop: {e}"))?;
    match app.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
