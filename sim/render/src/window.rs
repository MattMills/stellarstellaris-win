//! The windowed mode: the front end and the map (app.rs) in a window (winit). The mouse hovers,
//! presses and clicks the GUI's buttons; Escape goes back from the map (or the load window) to
//! the menu; C on the menu continues the newest save; Q closes. `frames` closes the window after
//! that many frames (for tests).

use std::sync::Arc;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowId};

use crate::app::App;
use crate::render::{self, Renderer};
use crate::scene::ALL;

struct Shown {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
    /// the generation of the scene uploaded
    uploaded: u64,
}

struct Win {
    app: App,
    backend: render::Backend,
    want: Option<String>,
    frames: Option<u32>,
    drawn: u32,
    instance: wgpu::Instance,
    shown: Option<Shown>,
    cursor: (f32, f32),
    error: Option<String>,
    /// when the first frame was drawn (the first seconds after it are redrawn on a timer)
    first_frame: Option<std::time::Instant>,
}

impl Win {
    fn open(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        let attrs = Window::default_attributes()
            .with_title("Stellaris")
            .with_inner_size(winit::dpi::PhysicalSize::new(self.app.size.0, self.app.size.1));
        let window = Arc::new(event_loop.create_window(attrs).map_err(|e| format!("window: {e}"))?);
        let surface = self.instance.create_surface(window.clone()).map_err(|e| format!("surface: {e}"))?;
        let (adapter, device, queue) =
            pollster::block_on(render::open_device(&self.instance, self.backend, self.want.as_deref(), Some(&surface)))?;
        eprintln!("rendering on: {}", render::describe(&adapter.get_info()));
        let size = window.inner_size();
        let config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or("the surface is not supported by the adapter")?;
        surface.configure(&device, &config);
        eprintln!("surface: {:?} {}x{}, {:?}", config.format, config.width, config.height, config.present_mode);
        let renderer = Renderer::new(&device, config.format);
        self.app.resize(config.width, config.height);
        window.request_redraw();
        self.shown = Some(Shown { window, surface, device, queue, config, renderer, uploaded: 0 });
        Ok(())
    }

    fn fail(&mut self, event_loop: &ActiveEventLoop, message: String) {
        eprintln!("error: {message}");
        self.error = Some(message);
        event_loop.exit();
    }

    fn flush_log(&mut self) {
        for l in self.app.log.drain(..) {
            eprintln!("{l}");
        }
    }

    fn redraw(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        let Some(s) = self.shown.as_mut() else { return Ok(()) };
        self.app.resize(s.config.width, s.config.height);
        let generation = self.app.prepare()?;
        if generation != s.uploaded {
            let (scene, textures) = self.app.parts().ok_or("no scene")?;
            s.renderer.upload(&s.device, &s.queue, scene, textures);
            s.uploaded = generation;
        }
        let texture = match s.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                // the surface changed under the swapchain: configure it again and draw anew
                drop(t);
                if self.drawn == 0 {
                    eprintln!("the surface is suboptimal: configured again");
                }
                s.surface.configure(&s.device, &s.config);
                s.window.request_redraw();
                return Ok(());
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                s.surface.configure(&s.device, &s.config);
                s.window.request_redraw();
                return Ok(());
            }
            state @ (wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded) => {
                if std::env::var("RENDER_TRACE").is_ok() {
                    eprintln!("no frame after {}: the surface is {state:?}", self.drawn);
                }
                return Ok(());
            }
            other => return Err(format!("the surface gave no frame: {other:?}")),
        };
        let view = texture.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = s.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("frame") });
        s.renderer.draw(&mut encoder, &view, ALL);
        s.queue.submit([encoder.finish()]);
        s.window.pre_present_notify();
        s.queue.present(texture);
        self.drawn += 1;
        if self.drawn == 1 {
            eprintln!("first frame drawn ({:?})", self.app.screen);
            self.first_frame = Some(std::time::Instant::now());
        }
        if std::env::var("RENDER_TRACE").is_ok() {
            eprintln!("frame {} presented (scene {})", self.drawn, s.uploaded);
        }
        if let Some(n) = self.frames {
            if self.drawn >= n {
                eprintln!("{} frames drawn ({:?})", self.drawn, self.app.screen);
                event_loop.exit();
            } else {
                s.window.request_redraw();
            }
        }
        Ok(())
    }

    /// After an input: redraw if it changed something, close if the app is done.
    fn after(&mut self, event_loop: &ActiveEventLoop, changed: Result<bool, String>) {
        self.flush_log();
        match changed {
            Err(e) => self.fail(event_loop, e),
            Ok(changed) => {
                if self.app.exit {
                    event_loop.exit();
                } else if changed {
                    if let Some(s) = &self.shown {
                        s.window.request_redraw();
                    }
                }
            }
        }
    }
}

impl ApplicationHandler for Win {
    /// For the first seconds after the first frame, redraw every 100 ms (a frame presented
    /// before the window shows can be lost); then wait for events. RENDER_TRACE=1 logs each
    /// frame and each surface state that gave none.
    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let Some(s) = &self.shown else { return };
        let early = match self.first_frame {
            None => true,
            Some(t) => t.elapsed() < std::time::Duration::from_secs(3),
        };
        if early {
            s.window.request_redraw();
            event_loop.set_control_flow(winit::event_loop::ControlFlow::WaitUntil(
                std::time::Instant::now() + std::time::Duration::from_millis(100),
            ));
        } else {
            event_loop.set_control_flow(winit::event_loop::ControlFlow::Wait);
        }
    }

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
                let key = match &logical_key {
                    Key::Named(NamedKey::Escape) => Some("escape".to_string()),
                    Key::Character(c) => Some(c.as_str().to_lowercase()),
                    _ => None,
                };
                if key.as_deref() == Some("q") {
                    event_loop.exit();
                } else if let Some(k) = key {
                    let r = self.app.key(&k);
                    self.after(event_loop, r);
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor = (position.x as f32, position.y as f32);
                let r = self.app.mouse_move(self.cursor.0, self.cursor.1);
                self.after(event_loop, r);
            }
            WindowEvent::MouseInput { state, button: MouseButton::Left, .. } => {
                let (x, y) = self.cursor;
                let r = match state {
                    ElementState::Pressed => self.app.mouse_down(x, y),
                    ElementState::Released => self.app.mouse_up(x, y),
                };
                self.after(event_loop, r);
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

/// Shows the app in a window until it is closed (or `frames` frames are drawn).
pub fn run(app: App, backend: render::Backend, want: Option<String>, frames: Option<u32>) -> Result<(), String> {
    let event_loop = EventLoop::new().map_err(|e| format!("event loop: {e}"))?;
    let mut win = Win {
        app,
        backend,
        want,
        frames,
        drawn: 0,
        instance: render::instance(backend),
        shown: None,
        cursor: (0.0, 0.0),
        error: None,
        first_frame: None,
    };
    event_loop.run_app(&mut win).map_err(|e| format!("event loop: {e}"))?;
    win.flush_log();
    match win.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
