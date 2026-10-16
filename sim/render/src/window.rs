//! The windowed mode: the front end and the map (app.rs) in a window (winit). The window's keys,
//! buttons, wheel and pointer go to the app as physical input (controls.rs: the keys by their
//! place on a US layout, as the game's SDL key codes name them there), and the bindings make
//! them the game's actions (docs/render.md section 12): the mouse hovers, presses and clicks the
//! GUI's buttons (the top bar's time controls too); on the map a click selects a system, fleet,
//! planet or ship and a double click on a star opens its system; the right button drags to turn
//! the camera, the middle (or left and right together) drags the plane, the wheel zooms by the
//! game's zoom steps; W A S D and the arrows scroll while held, the cursor at the window's edge
//! scrolls, and the camera glides to where input sends it. Space pauses or runs the game's clock
//! (on the simulation's thread: the window never waits for a day), the keypad's + and -, + = and
//! -, Shift+Up and Shift+Down change its speed, `.` runs one day (when released, as the game).
//! Escape goes back (the selection, then system -> galaxy -> menu); C on the menu continues the
//! newest save; Q on the menu closes. `frames` closes the window after that many frames (for
//! tests).
//!
//! The window's thread does nothing but render (ui.rs): the app runs on the UI thread, the input
//! goes to it as jobs, and each frame, 120 a second, draws the newest scene it published.

use std::sync::Arc;
use std::time::{Duration, Instant};

use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::PhysicalKey;
use winit::window::{Window, WindowId};

use crate::app::{App, Screen};
use crate::controls::{self, Button, Input};
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
    error: Option<String>,
    /// when the first frame was drawn (the first seconds after it are redrawn on a timer)
    first_frame: Option<std::time::Instant>,
    /// fit the window to the screen (no size was asked for)
    fit: bool,
    /// when the window opened (the input's times: a double click's)
    start: Instant,
}

/// A key's name (controls.rs): its place on the keyboard, named as on a US layout.
fn key_name(physical: &PhysicalKey) -> Option<String> {
    let PhysicalKey::Code(code) = physical else { return None };
    let n = format!("{code:?}");
    let name = if let Some(c) = n.strip_prefix("Key") {
        c.to_lowercase()
    } else if let Some(d) = n.strip_prefix("Digit") {
        d.to_string()
    } else if let Some(d) = n.strip_prefix("Numpad").filter(|d| d.len() == 1) {
        format!("kp_{d}")
    } else if n.len() <= 3 && n.starts_with('F') {
        n.to_lowercase()
    } else {
        match n.as_str() {
            "NumpadAdd" => "kp_plus",
            "NumpadSubtract" => "kp_minus",
            "NumpadMultiply" => "kp_multiply",
            "NumpadDivide" => "kp_divide",
            "NumpadEnter" => "kp_enter",
            "NumpadDecimal" => "kp_period",
            "Enter" => "return",
            "ArrowUp" => "up",
            "ArrowDown" => "down",
            "ArrowLeft" => "left",
            "ArrowRight" => "right",
            "Quote" => "apostrophe",
            "Backquote" => "grave",
            "ShiftLeft" | "ShiftRight" => "shift",
            "ControlLeft" | "ControlRight" => "ctrl",
            "AltLeft" | "AltRight" => "alt",
            "PrintScreen" => "print",
            other => return controls::key_name(other),
        }
        .to_string()
    };
    controls::key_name(&name)
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

    /// Input for the app, on its thread, with its time.
    fn input(&self, input: Input) {
        let ms = self.start.elapsed().as_secs_f64() * 1000.0;
        self.ui.post(move |app| app.input(&input, ms).map(|_| ()));
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
            WindowEvent::KeyboardInput { event: KeyEvent { physical_key, state, repeat, .. }, .. } => {
                let Some(key) = key_name(&physical_key) else { return };
                self.input(Input::Key { key, down: state == ElementState::Pressed, repeat });
            }
            WindowEvent::CursorLeft { .. } => self.input(Input::Leave),
            WindowEvent::CursorMoved { position, .. } => self.input(Input::Move { x: position.x as f32, y: position.y as f32 }),
            WindowEvent::MouseInput { state, button, .. } => {
                let button = match button {
                    MouseButton::Left => Button::Left,
                    MouseButton::Right => Button::Right,
                    MouseButton::Middle => Button::Middle,
                    _ => return,
                };
                self.input(Input::Button { button, down: state == ElementState::Pressed });
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let notches = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y,
                    MouseScrollDelta::PixelDelta(p) => p.y as f32 / 40.0,
                };
                self.input(Input::Wheel { notches });
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
        error: None,
        first_frame: None,
        fit,
        start: Instant::now(),
    };
    event_loop.run_app(&mut win).map_err(|e| format!("event loop: {e}"))?;
    match win.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
