//! The windowed mode: the front end and the map (app.rs) in a window (winit). The mouse hovers,
//! presses and clicks the GUI's buttons; on the map a click on a star opens its system, the
//! right button drags to turn the camera, the left drags to pan, the wheel zooms (and W A S D,
//! Q E, R F, + - as in app.rs); Space steps the simulation a day, P runs it (a day a frame);
//! Escape goes back (system -> galaxy -> menu); C on the menu continues the newest save; Q on the
//! menu closes. `frames` closes the window after that many frames (for tests).

use std::sync::Arc;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
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
    /// fit the window to the screen (no size was asked for)
    fit: bool,
    /// a mouse button held: which, where it went down, whether it moved (a drag, not a click)
    held: Option<(MouseButton, (f32, f32), bool)>,
    /// the simulation runs a day a frame
    running: bool,
}

impl Win {
    fn open(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        // the size asked for; the default one made to fit the screen (85% of its width, 80% of its
        // height at most, leaving room for the title bar and the taskbar)
        let (mut w, mut h) = self.app.size;
        if self.fit {
            if let Some(m) = event_loop.primary_monitor() {
                let ms = m.size();
                if ms.width > 0 && ms.height > 0 {
                    let s = (ms.width as f32 * 0.85 / w as f32).min(ms.height as f32 * 0.8 / h as f32).min(1.0);
                    (w, h) = ((w as f32 * s) as u32, (h as f32 * s) as u32);
                    eprintln!("screen {}x{}: window {w}x{h}", ms.width, ms.height);
                }
            }
        }
        let attrs = Window::default_attributes()
            .with_title("Stellaris")
            .with_inner_size(winit::dpi::PhysicalSize::new(w, h));
        let window = Arc::new(event_loop.create_window(attrs).map_err(|e| format!("window: {e}"))?);
        let surface = self.instance.create_surface(window.clone()).map_err(|e| format!("surface: {e}"))?;
        let (adapter, device, queue) =
            pollster::block_on(render::open_device(&self.instance, self.backend, self.want.as_deref(), Some(&surface)))?;
        eprintln!("rendering on: {}", render::describe(&adapter.get_info()));
        let size = window.inner_size();
        let mut config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or("the surface is not supported by the adapter")?;
        // a format that is not sRGB if the surface has one: colours blend as in the PNGs (and the
        // game), in gamma space
        if let Some(f) = surface.get_capabilities(&adapter).formats.iter().find(|f| !f.is_srgb()) {
            config.format = *f;
        }
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
        if self.running {
            // a day a frame while it runs
            match self.app.step(1) {
                Ok(r) => eprintln!("step: {r}"),
                Err(e) => {
                    self.running = false;
                    eprintln!("step: {e}");
                }
            }
            s.window.request_redraw();
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
                    Key::Named(NamedKey::ArrowUp) => Some("up".to_string()),
                    Key::Named(NamedKey::ArrowDown) => Some("down".to_string()),
                    Key::Named(NamedKey::ArrowLeft) => Some("left".to_string()),
                    Key::Named(NamedKey::ArrowRight) => Some("right".to_string()),
                    Key::Named(NamedKey::PageUp) => Some("pageup".to_string()),
                    Key::Named(NamedKey::PageDown) => Some("pagedown".to_string()),
                    Key::Named(NamedKey::Space) => Some("space".to_string()),
                    Key::Character(c) => Some(c.as_str().to_lowercase()),
                    _ => None,
                };
                let on_map = self.app.screen == crate::app::Screen::Map;
                match key.as_deref() {
                    Some("q") if !on_map => event_loop.exit(),
                    Some("space") if on_map => {
                        let r = self.app.step(1).map(|s| {
                            eprintln!("step: {s}");
                            true
                        });
                        self.after(event_loop, r);
                    }
                    Some("p") if on_map => {
                        self.running = !self.running;
                        eprintln!("simulation {}", if self.running { "running" } else { "paused" });
                        if let Some(s) = &self.shown {
                            s.window.request_redraw();
                        }
                    }
                    Some(k) => {
                        let r = self.app.key(k);
                        self.after(event_loop, r);
                    }
                    None => {}
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                let (px, py) = self.cursor;
                self.cursor = (position.x as f32, position.y as f32);
                let (dx, dy) = (self.cursor.0 - px, self.cursor.1 - py);
                let on_map = self.app.screen == crate::app::Screen::Map;
                let cursor = self.cursor;
                let mut drag = None;
                if let Some((button, start, moved)) = self.held.as_mut() {
                    let far = (cursor.0 - start.0).abs() + (cursor.1 - start.1).abs() > 4.0;
                    if on_map && (*moved || far) {
                        *moved = true;
                        drag = Some(*button);
                    }
                }
                if let Some(button) = drag {
                    let h = self.shown.as_ref().map_or(900.0, |s| s.config.height as f32);
                    match button {
                        MouseButton::Right => self.app.orbit(-dx * 0.3, dy * 0.3),
                        _ => self.app.pan(-dx / h * 1.2, dy / h * 1.2),
                    }
                    self.after(event_loop, Ok(true));
                    return;
                }
                let r = self.app.mouse_move(self.cursor.0, self.cursor.1);
                self.after(event_loop, r);
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let (x, y) = self.cursor;
                match state {
                    ElementState::Pressed => {
                        self.held = Some((button, (x, y), false));
                        if button == MouseButton::Left {
                            let r = self.app.mouse_down(x, y);
                            self.after(event_loop, r);
                        }
                    }
                    ElementState::Released => {
                        let dragged = self.held.take().is_some_and(|h| h.2);
                        if button == MouseButton::Left && !dragged {
                            let r = self.app.mouse_up(x, y);
                            self.after(event_loop, r);
                        }
                    }
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let dy = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y,
                    MouseScrollDelta::PixelDelta(p) => p.y as f32 / 40.0,
                };
                self.app.zoom(0.85f32.powf(dy));
                self.after(event_loop, Ok(true));
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

/// Shows the app in a window until it is closed (or `frames` frames are drawn); `fit`: make the
/// window (the app's size) fit the screen.
pub fn run(app: App, backend: render::Backend, want: Option<String>, frames: Option<u32>, fit: bool) -> Result<(), String> {
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
        fit,
        held: None,
        running: false,
    };
    event_loop.run_app(&mut win).map_err(|e| format!("event loop: {e}"))?;
    win.flush_log();
    match win.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
