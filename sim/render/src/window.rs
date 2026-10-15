//! The windowed mode: the front end and the map (app.rs) in a window (winit). The mouse hovers,
//! presses and clicks the GUI's buttons (the top bar's time controls too); on the map a click
//! selects a system, fleet, planet or ship and a double click on a star opens its system; the
//! right button drags to turn the camera, the left drags to pan, the wheel zooms by the game's
//! zoom steps; W A S D and the arrows pan and Q E turn while held, the cursor at the window's
//! edge scrolls, and the camera glides to where input sends it. Space pauses or runs the game's
//! clock (on the simulation's thread: the window never waits for a day), + and - (the keypad's
//! too, Shift+Up and Shift+Down) change its speed, `.` runs one day. Escape goes back (the
//! selection, then system -> galaxy -> menu); C on the menu continues the newest save; Q on the
//! menu closes. `frames` closes the window after that many frames (for tests).
//!
//! The window's thread does nothing but render (ui.rs): the app runs on the UI thread, the input
//! goes to it as jobs, and each frame, 120 a second, draws the newest scene it published.

use std::sync::Arc;
use std::time::{Duration, Instant};

use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, Modifiers, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key, KeyCode, NamedKey, PhysicalKey};
use winit::window::{Window, WindowId};

use crate::app::{App, Screen};
use crate::render::{self, Renderer};
use crate::scene::ALL;
use crate::ui::{self, Ui};

struct Shown {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
    /// the generation of the scene uploaded (u64::MAX: none yet)
    uploaded: u64,
    /// the last frame's submission: the next frame waits for it (one frame in flight)
    in_flight: Option<wgpu::SubmissionIndex>,
}

struct Win {
    ui: Ui,
    /// the app's screen, as its newest scene has it
    screen: Screen,
    /// when the next frame is due
    next_frame: Instant,
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
    /// the keyboard's modifiers (Shift+Up and Shift+Down change the speed)
    modifiers: Modifiers,
    /// the last click: when and where (a second one near it soon after is a double click)
    last_click: Option<(Instant, (f32, f32))>,
}

/// A key's name for the app: named keys, the keypad's + and -, characters (lower case).
fn key_name(logical: &Key, physical: &PhysicalKey, shift: bool) -> Option<String> {
    match physical {
        PhysicalKey::Code(KeyCode::NumpadAdd) => return Some("kp_plus".into()),
        PhysicalKey::Code(KeyCode::NumpadSubtract) => return Some("kp_minus".into()),
        _ => {}
    }
    let name = match logical {
        Key::Named(NamedKey::Escape) => "escape".to_string(),
        Key::Named(NamedKey::ArrowUp) => "up".to_string(),
        Key::Named(NamedKey::ArrowDown) => "down".to_string(),
        Key::Named(NamedKey::ArrowLeft) => "left".to_string(),
        Key::Named(NamedKey::ArrowRight) => "right".to_string(),
        Key::Named(NamedKey::PageUp) => "pageup".to_string(),
        Key::Named(NamedKey::PageDown) => "pagedown".to_string(),
        Key::Named(NamedKey::Space) => "space".to_string(),
        Key::Named(NamedKey::Home) => "home".to_string(),
        Key::Named(NamedKey::Backspace) => "backspace".to_string(),
        Key::Character(c) => c.as_str().to_lowercase(),
        _ => return None,
    };
    if shift && (name == "up" || name == "down") {
        return Some(format!("shift+{name}"));
    }
    Some(name)
}

impl Win {
    fn open(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        // the size asked for; the default one made to fit the screen (85% of its width, 80% of its
        // height at most, leaving room for the title bar and the taskbar)
        let (mut w, mut h) = self.ui.call(|app| app.size)?;
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
        let (cw, ch) = (config.width, config.height);
        self.ui.post(move |app| {
            app.resize(cw, ch);
            Ok(())
        });
        window.request_redraw();
        self.shown = Some(Shown { window, surface, device, queue, config, renderer, uploaded: u64::MAX, in_flight: None });
        Ok(())
    }

    fn fail(&mut self, event_loop: &ActiveEventLoop, message: String) {
        eprintln!("error: {message}");
        self.error = Some(message);
        event_loop.exit();
    }

    /// A job for the app (the input), on its thread.
    fn post(&self, f: impl FnOnce(&mut App) -> Result<(), String> + Send + 'static) {
        self.ui.post(f);
    }

    fn redraw(&mut self, event_loop: &ActiveEventLoop) -> Result<(), String> {
        let Some(s) = self.shown.as_mut() else { return Ok(()) };
        match self.ui.ended() {
            Some(Ok(())) => {
                event_loop.exit();
                return Ok(());
            }
            Some(Err(e)) => return Err(e),
            None => {}
        }
        // the frame before finished on the GPU first: one frame in flight (with a mailbox present
        // nothing else holds the frames back, and the GPU's queue and the resources the scenes
        // replaced, freed when the device is polled, grew until the GPU ran out of memory)
        if let Some(idx) = s.in_flight.take() {
            let _ = s.device.poll(wgpu::PollType::Wait { submission_index: Some(idx), timeout: Some(Duration::from_millis(250)) });
        }
        // the newest scene: its resources up within the frame's budget, then drawn; until then
        // the one before (ui.rs)
        if let Some(frame) = self.ui.latest() {
            self.screen = frame.screen;
            ui::take(&mut s.renderer, &s.device, &s.queue, &frame, &mut s.uploaded);
        }
        if s.uploaded == u64::MAX {
            return Ok(());
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
        s.in_flight = Some(s.queue.submit([encoder.finish()]));
        s.window.pre_present_notify();
        s.queue.present(texture);
        self.drawn += 1;
        if self.drawn == 1 {
            eprintln!("first frame drawn ({:?})", self.screen);
            self.first_frame = Some(std::time::Instant::now());
        }
        if std::env::var("RENDER_TRACE").is_ok() {
            eprintln!("frame {} presented (scene {})", self.drawn, s.uploaded);
        }
        if let Some(n) = self.frames {
            if self.drawn >= n {
                eprintln!("{} frames drawn ({:?})", self.drawn, self.screen);
                event_loop.exit();
            }
        }
        Ok(())
    }
}

impl ApplicationHandler for Win {
    /// A frame every 1/120 s: the newest scene the UI thread published (the camera's glide, the
    /// held keys, the edge scrolling and the simulation's snapshots are the UI thread's). With a
    /// display slower than that the surface's present paces the frames. RENDER_TRACE=1 logs each
    /// frame and each surface state that gave none.
    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let Some(s) = &self.shown else { return };
        let now = Instant::now();
        if now >= self.next_frame {
            s.window.request_redraw();
            self.next_frame = (self.next_frame + ui::PERIOD).max(now);
        }
        event_loop.set_control_flow(winit::event_loop::ControlFlow::WaitUntil(self.next_frame));
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
            WindowEvent::ModifiersChanged(m) => self.modifiers = m,
            WindowEvent::KeyboardInput { event: KeyEvent { logical_key, physical_key, state, repeat, .. }, .. } => {
                let shift = self.modifiers.state().shift_key();
                let Some(key) = key_name(&logical_key, &physical_key, shift) else { return };
                if state == ElementState::Released {
                    self.post(move |app| {
                        app.key_up(&key);
                        if key.starts_with("shift+") {
                            app.key_up(key.trim_start_matches("shift+"));
                        }
                        Ok(())
                    });
                    return;
                }
                let on_map = self.screen == Screen::Map;
                if key == "q" && !on_map {
                    event_loop.exit();
                    return;
                }
                // a held key repeats: the clock's keys act once a press
                if repeat && matches!(key.as_str(), "space" | "." | "kp_plus" | "kp_minus" | "+" | "=" | "-" | "shift+up" | "shift+down") {
                    return;
                }
                self.post(move |app| app.key(&key).map(|_| ()));
            }
            WindowEvent::CursorLeft { .. } => self.post(|app| {
                app.mouse_left();
                Ok(())
            }),
            WindowEvent::CursorMoved { position, .. } => {
                let (px, py) = self.cursor;
                self.cursor = (position.x as f32, position.y as f32);
                let (dx, dy) = (self.cursor.0 - px, self.cursor.1 - py);
                let on_map = self.screen == Screen::Map;
                let cursor = self.cursor;
                let mut drag = None;
                if let Some((button, start, moved)) = self.held.as_mut() {
                    let far = (cursor.0 - start.0).powi(2) + (cursor.1 - start.1).powi(2) > crate::camera::MOUSE_MOVEMENT_TO_START_ROTATION_SQ;
                    if on_map && (*moved || far) {
                        *moved = true;
                        drag = Some(*button);
                    }
                }
                if let Some(button) = drag {
                    // the game's: the right button turns, the middle one drags the plane (the
                    // grabbed point stays under the cursor); a left drag is its box selection
                    // (not drawn)
                    match button {
                        MouseButton::Right => self.post(move |app| {
                            app.set_holding(true);
                            app.rotate(dx, dy);
                            Ok(())
                        }),
                        MouseButton::Middle => self.post(move |app| {
                            app.set_holding(true);
                            app.drag(Some(cursor));
                            Ok(())
                        }),
                        _ => {}
                    }
                    return;
                }
                self.post(move |app| app.mouse_move(cursor.0, cursor.1).map(|_| ()));
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let (x, y) = self.cursor;
                match state {
                    ElementState::Pressed => {
                        self.held = Some((button, (x, y), false));
                        if button == MouseButton::Left {
                            self.post(move |app| app.mouse_down(x, y).map(|_| ()));
                        }
                        if button == MouseButton::Middle {
                            // the plane's point under the cursor is grabbed
                            self.post(move |app| {
                                app.drag(None);
                                app.drag(Some((x, y)));
                                Ok(())
                            });
                        }
                    }
                    ElementState::Released => {
                        let dragged = self.held.take().is_some_and(|h| h.2);
                        self.post(|app| {
                            app.set_holding(false);
                            app.drag(None);
                            Ok(())
                        });
                        if button == MouseButton::Left && !dragged {
                            let double = self
                                .last_click
                                .is_some_and(|(t, (cx, cy))| t.elapsed() < Duration::from_millis(400) && (cx - x).abs() + (cy - y).abs() < 6.0);
                            self.last_click = Some((Instant::now(), (x, y)));
                            if double {
                                self.last_click = None;
                                self.post(move |app| app.double_click(x, y).map(|_| ()));
                            } else {
                                self.post(move |app| app.mouse_up(x, y).map(|_| ()));
                            }
                        }
                    }
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let dy = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y,
                    MouseScrollDelta::PixelDelta(p) => p.y as f32 / 40.0,
                };
                self.post(move |app| {
                    app.wheel(dy);
                    Ok(())
                });
            }
            WindowEvent::Resized(size) => {
                if let Some(s) = self.shown.as_mut() {
                    if size.width > 0 && size.height > 0 {
                        s.config.width = size.width;
                        s.config.height = size.height;
                        s.surface.configure(&s.device, &s.config);
                        s.window.request_redraw();
                        let (w, h) = (size.width, size.height);
                        self.ui.post(move |app| {
                            app.resize(w, h);
                            Ok(())
                        });
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

/// Shows the app `make` makes (on the UI thread: ui.rs) in a window until it is closed (or
/// `frames` frames are drawn); `fit`: make the window (the app's size) fit the screen. The
/// cameras glide in the window.
pub fn run<F>(make: F, backend: render::Backend, want: Option<String>, frames: Option<u32>, fit: bool) -> Result<(), String>
where
    F: FnOnce() -> Result<App, String> + Send + 'static,
{
    let ui = Ui::start(move || {
        let mut app = make()?;
        app.smooth = true;
        Ok(app)
    })?;
    let event_loop = EventLoop::new().map_err(|e| format!("event loop: {e}"))?;
    let mut win = Win {
        ui,
        screen: Screen::Menu,
        next_frame: Instant::now(),
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
        modifiers: Modifiers::default(),
        last_click: None,
    };
    event_loop.run_app(&mut win).map_err(|e| format!("event loop: {e}"))?;
    match win.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
