//! The controls: physical input (keys, mouse buttons, the wheel, the pointer) kept apart from the
//! game's actions (pause, the speed, scrolling, zooming, turning, selecting, entering a system,
//! ...), joined by bindings that are data (`BINDINGS`, the game's own: docs/render.md section 12,
//! each with the game function it was read from). The window (window.rs) and the command protocol
//! (engine.rs) both send [`Input`] here; [`Controls`] turns it into [`Effect`]s the app carries out
//! (app.rs `App::input`), at events and once a frame ([`Controls::frame`]: what the game polls).
//!
//! The game's input, 4.5.2 Linux (read from the code; `controls_bindings` notes, docs/render.md
//! section 12) **[V]**: SDL key codes (a key's code on the layout, letters lower case) with the
//! modifiers matched exactly (CKeyEvent::Is); the clock's keys act when released, the camera's
//! (E, M, R) when pressed; W A S D and the arrows start scrolling when pressed without a modifier
//! and scroll while held (polled); Page Up and Page Down zoom while held; the wheel zooms one
//! step a frame (the frame's last notch); the right button turns once the pointer is 4 pixels
//! from the press (each frame by the frame's motion); the middle button, or left and right
//! together, drag the plane; a left release selects (box selection after 4 pixels); a second
//! left press within 500 ms with no motion between is a double click (focus).
//!
//! Key names (the protocol's, headless.c's): X keysym names in lower case, of a US layout's keys
//! (`KEYS`): `a`..`z`, `0`..`9`, `f1`..`f24`, `kp_0`..`kp_9`, `space`, `escape`, `up`, `pageup`,
//! `equal`, `minus`, `period`, `shift`, `ctrl`, `alt`, ...; aliases (`ALIASES`) such as `.` `=`
//! `-` `esc` `pgup` `kp_add`; `plus` (`+`) is Shift and `equal`, as typed on that layout.

use std::collections::{BTreeMap, BTreeSet};

use crate::camera::MOUSE_MOVEMENT_TO_START_ROTATION_SQ;

/// The named keys (X keysym names, lower case) besides letters, digits, `f1`..`f24` and
/// `kp_0`..`kp_9`.
pub const KEYS: &[&str] = &[
    "space", "escape", "return", "tab", "backspace", "up", "down", "left", "right", "pageup", "pagedown", "home", "end", "insert", "delete",
    "kp_plus", "kp_minus", "kp_multiply", "kp_divide", "kp_enter", "kp_period", "minus", "equal", "period", "comma", "slash", "semicolon",
    "apostrophe", "grave", "bracketleft", "bracketright", "backslash", "shift", "ctrl", "alt", "pause", "print",
];

/// Other names for keys (the characters, the game's own names: CPdxKeys::InitPdxKeySDLMap's
/// `DEL`, `PAGE_UP`, `DOT`, ...).
pub const ALIASES: &[(&str, &str)] = &[
    (".", "period"),
    ("dot", "period"),
    ("=", "equal"),
    ("-", "minus"),
    (",", "comma"),
    ("/", "slash"),
    (";", "semicolon"),
    ("'", "apostrophe"),
    ("`", "grave"),
    ("[", "bracketleft"),
    ("]", "bracketright"),
    ("\\", "backslash"),
    ("esc", "escape"),
    ("enter", "return"),
    ("kp_return", "kp_enter"),
    ("pgup", "pageup"),
    ("page_up", "pageup"),
    ("prior", "pageup"),
    ("pgdn", "pagedown"),
    ("page_down", "pagedown"),
    ("next", "pagedown"),
    ("del", "delete"),
    ("kp_add", "kp_plus"),
    ("kp_subtract", "kp_minus"),
    ("control", "ctrl"),
    ("lshift", "shift"),
    ("rshift", "shift"),
    ("lctrl", "ctrl"),
    ("rctrl", "ctrl"),
    ("lalt", "alt"),
    ("ralt", "alt"),
];

/// A key's canonical name, if it is one.
pub fn key_name(s: &str) -> Option<String> {
    let l = s.to_lowercase();
    let l = ALIASES.iter().find(|(a, _)| *a == l).map_or(l.clone(), |(_, k)| k.to_string());
    let c: Vec<char> = l.chars().collect();
    let ok = KEYS.contains(&l.as_str())
        || (c.len() == 1 && c[0].is_ascii_alphanumeric())
        || (c.len() >= 2 && c.len() <= 3 && c[0] == 'f' && l[1..].parse::<u32>().is_ok_and(|n| (1..=24).contains(&n)))
        || (c.len() == 4 && l.starts_with("kp_") && c[3].is_ascii_digit());
    ok.then_some(l)
}

/// The modifiers held (CKeyEvent's EModKey: Ctrl 1, Alt 2, Shift 4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Mods {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
}

impl Mods {
    fn prefix(&self) -> String {
        format!("{}{}{}", if self.ctrl { "ctrl+" } else { "" }, if self.alt { "alt+" } else { "" }, if self.shift { "shift+" } else { "" })
    }
}

/// A key with its modifiers: `w`, `shift+up`, `ctrl+f9`, `plus` (Shift and `equal`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chord {
    pub mods: Mods,
    pub key: String,
}

impl std::fmt::Display for Chord {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}{}", self.mods.prefix(), self.key)
    }
}

/// Reads a chord: modifiers (`shift+`, `ctrl+`/`control+`, `alt+`, any case) and a key name.
pub fn chord(s: &str) -> Result<Chord, String> {
    let mut mods = Mods::default();
    let mut rest = s.trim();
    loop {
        let l = rest.to_lowercase();
        let m = ["shift+", "ctrl+", "control+", "alt+"].iter().find(|p| l.starts_with(**p) && l.len() > p.len());
        let Some(p) = m else { break };
        match *p {
            "shift+" => mods.shift = true,
            "alt+" => mods.alt = true,
            _ => mods.ctrl = true,
        }
        rest = &rest[p.len()..];
    }
    let key = match rest.to_lowercase().as_str() {
        "+" | "plus" => {
            mods.shift = true;
            "equal".to_string()
        }
        _ => key_name(rest).ok_or(format!("unknown key {rest:?}"))?,
    };
    Ok(Chord { mods, key })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Button {
    Left,
    Middle,
    Right,
}

impl Button {
    pub fn parse(s: &str) -> Option<Button> {
        match s {
            "left" => Some(Button::Left),
            "middle" => Some(Button::Middle),
            "right" => Some(Button::Right),
            _ => None,
        }
    }
    pub fn name(&self) -> &'static str {
        match self {
            Button::Left => "left",
            Button::Middle => "middle",
            Button::Right => "right",
        }
    }
}

/// Physical input, as a keyboard and a mouse make it.
#[derive(Clone, Debug, PartialEq)]
pub enum Input {
    /// a key pressed or released; `repeat`: the keyboard's repeat of a key held
    Key { key: String, down: bool, repeat: bool },
    /// a button pressed or released at the pointer
    Button { button: Button, down: bool },
    /// the pointer to a pixel of the window
    Move { x: f32, y: f32 },
    /// wheel notches, > 0 away from the user
    Wheel { notches: f32 },
    /// the pointer left the window
    Leave,
}

/// What the player asks of the game.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Action {
    // the clock
    Pause,
    SpeedUp,
    SpeedDown,
    NextDay,
    // the camera, while held
    ScrollUp,
    ScrollDown,
    ScrollLeft,
    ScrollRight,
    ZoomIn,
    ZoomOut,
    // the camera, once
    ResetCamera,
    ToggleSystem,
    HomeSystem,
    CycleSystem,
    CycleSystemBack,
    // the mouse
    Select,
    BoxSelect,
    Focus,
    Order,
    Ping,
    Rotate,
    DragPlane,
    Zoom,
    // the screens
    Back,
    /// a screen's Return: its next or start button (the new game's screens)
    Accept,
    ToggleGui,
    /// the renderer's load screen console (console.rs)
    ToggleConsole,
    Map2D3D,
    Continue,
    Quit,
    // the game's, not done here
    Disband,
    Screenshot,
    LockCamera,
}

/// The actions' names in the bindings and the replies.
pub const ACTIONS: &[(Action, &str)] = &[
    (Action::Pause, "pause"),
    (Action::SpeedUp, "speed_up"),
    (Action::SpeedDown, "speed_down"),
    (Action::NextDay, "next_day"),
    (Action::ScrollUp, "scroll_up"),
    (Action::ScrollDown, "scroll_down"),
    (Action::ScrollLeft, "scroll_left"),
    (Action::ScrollRight, "scroll_right"),
    (Action::ZoomIn, "zoom_in"),
    (Action::ZoomOut, "zoom_out"),
    (Action::ResetCamera, "reset_camera"),
    (Action::ToggleSystem, "toggle_system"),
    (Action::HomeSystem, "home_system"),
    (Action::CycleSystem, "cycle_system"),
    (Action::CycleSystemBack, "cycle_system_back"),
    (Action::Select, "select"),
    (Action::BoxSelect, "box_select"),
    (Action::Focus, "focus"),
    (Action::Order, "order"),
    (Action::Ping, "ping"),
    (Action::Rotate, "rotate"),
    (Action::DragPlane, "drag_plane"),
    (Action::Zoom, "zoom"),
    (Action::Back, "back"),
    (Action::Accept, "accept"),
    (Action::ToggleGui, "toggle_gui"),
    (Action::ToggleConsole, "toggle_console"),
    (Action::Map2D3D, "map_2d_3d"),
    (Action::Continue, "continue"),
    (Action::Quit, "quit"),
    (Action::Disband, "disband"),
    (Action::Screenshot, "screenshot"),
    (Action::LockCamera, "lock_camera"),
];

impl Action {
    pub fn name(&self) -> &'static str {
        ACTIONS.iter().find(|(a, _)| a == self).map(|(_, n)| *n).unwrap_or("?")
    }
    pub fn parse(s: &str) -> Option<Action> {
        ACTIONS.iter().find(|(_, n)| *n == s).map(|(a, _)| *a)
    }
}

/// Where a binding acts: the app's screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Context {
    Map,
    Menu,
    Load,
    /// the new game's screens: empire selection, the empire creator, the galaxy settings
    Setup,
    Any,
}

/// The modifiers a key binding wants: exactly these (CKeyEvent::Is), or any (`any+`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModMatch {
    Exact(Mods),
    Any,
}

impl ModMatch {
    fn matches(&self, m: Mods) -> bool {
        match self {
            ModMatch::Exact(e) => *e == m,
            ModMatch::Any => true,
        }
    }
}

/// What sets a binding off.
#[derive(Clone, Debug, PartialEq)]
pub enum Trigger {
    /// the key pressed (not its repeats)
    Press(ModMatch, String),
    /// the key released
    Release(ModMatch, String),
    /// pressed with these modifiers it starts; it goes on each frame while the key (or another
    /// `hold` key of the same action) is down (UpdateScrollingMovement's latch, then polled)
    Hold(ModMatch, String),
    /// each frame the key is down (polled: CKeyBoard::IsKeyDown)
    Poll(String),
    /// a button released less than 4 pixels from its press
    Click(ModMatch, Button),
    /// a button released 4 pixels or more from its press
    DragRelease(Button),
    /// a second press within 500 ms with no motion since the first
    Double(Button),
    /// each frame these buttons are all held (rotate: from 4 pixels on)
    Drag(Vec<Button>),
    /// a wheel notch (a frame's last)
    Wheel,
}

#[derive(Clone, Debug)]
pub struct Binding {
    pub context: Context,
    pub trigger: Trigger,
    pub action: Action,
    /// where the game does it, and whether that is read **[V]** or inferred **[I]** (**[R]**: the
    /// renderer's own)
    pub source: String,
}

/// The bindings: the game's (4.5.2 Linux, read from the code; addresses of the Linux build) and
/// the renderer's own ([R]). One a line: CONTEXT TRIGGER INPUT ACTION SOURCE. TRIGGER: press,
/// release, hold, poll (keys: a chord, `any+` for any modifiers), click, drag_release, double,
/// drag (mouse buttons, `left+right` for both), wheel (no input: `-`).
pub const BINDINGS: &str = "\
# the clock: CInGameIdler::HandleInputEvent @0x1c85c80 (single player), on release
map   release any+space     pause            [V] HandleInputEvent @0x1c86895: Space, any modifiers
map   release kp_plus       speed_up         [V] @0x1c86986: KP_PLUS (main.gui increase_speed's shortcut too)
map   release equal         speed_up         [V] @0x1c86986: '=' (0x3d), no modifier
map   release shift+equal   speed_up         [V] @0x1c86986: '=' with Shift ('+' on a US layout)
map   release shift+up      speed_up         [V] @0x1c86a9c: Up with Shift
map   release kp_minus      speed_down       [V] @0x1c86ab8: KP_MINUS
map   release minus         speed_down       [V] @0x1c86ab8: '-'
map   release shift+down    speed_down       [V] @0x1c86b99: Down with Shift
map   release period        next_day         [V] @0x1c86b9e: '.' (CJumpToNextDayCommand)
map   release home          home_system      [V] @0x1c863a1: FocusCameraOnCountryHomeSystem (main_bottom.gui home_button HOME too)
map   release backspace     home_system      [V] @0x1c863a1 (main_bottom.gui home_button BACKSPACE too)
map   release delete        disband          [V] @0x1c86708: CMainGui::ShowFleetDisband (not done here)
map   press tab             cycle_system     [V] @0x1c86016: CycleCameraSystemFocus(false) (not done here)
map   press shift+tab       cycle_system_back [V] @0x1c867b9 (not done here)
map   press ctrl+tab        cycle_system_back [V] @0x1c867b9 (not done here)
# the camera: CGameCamera::HandleShortcutsInput @0x2e612f0, on press, no modifier
map   press e               toggle_system    [V] @0x2e613ad: ToggleSystem (which system [I])
map   press m               toggle_system    [V] @0x2e613cc
map   press r               reset_camera     [V] @0x2e613eb
# CGameCamera::UpdateScrollingMovement @0x2e659f0: a press without modifiers starts, held goes on
map   hold w                scroll_up        [V] @0x2e659f0 (+0x2a8)
map   hold up               scroll_up        [V]
map   hold s                scroll_down      [V] (+0x2a9)
map   hold down             scroll_down      [V]
map   hold a                scroll_left      [V] (+0x2aa)
map   hold left             scroll_left      [V]
map   hold d                scroll_right     [V] (+0x2ab)
map   hold right            scroll_right     [V]
# CGameCamera::UpdateZoom @0x2e66450: Page Up and Page Down polled (IsKeyDown @0x2e622db)
map   poll pageup           zoom_in          [V] KEYBOARD_ZOOM_RATE x FOCUSED_ZOOM_RATE
map   poll pagedown         zoom_out         [V]
# the mouse: HandleInputEvent (select, orders), CGameCamera (turn, drag, zoom)
map   click left            select           [V] HandleInputEvent @0x1c8609f: DoSelection on release
map   click alt+left        ping             [V] @0x1c860b5: CPingMapManager (not done here)
map   drag_release left     box_select       [V] @0x1c8613f: 16 px squared from the press (not done here)
map   double left           focus            [V] @0x1c862f4: GetSelectableAt, FocusOn
map   click any+right       order            [V] @0x1c862a2: PerformAction / PerformRightClickActionAt unless turning, any modifiers (Shift queues, Ctrl front, Alt: no class entries; rightclick.rs)
map   drag right            rotate           [V] UpdateRotation @0x2e66210: over 16 px squared, 0.004 rad a pixel
map   drag middle           drag_plane       [V] UpdateDragMovement @0x2e65730
map   drag left+right       drag_plane       [V] UpdateDragMovement: IsPressedLeft and IsPressedRight
map   wheel -               zoom             [V] UpdateZoom @0x2e66518: one step a frame, toward the cursor; right held: smooth
# the engine: CGameIdler::Idle @0x1afd770, every screen
any   press ctrl+f9         toggle_gui       [V] Idle @0x1afdd9b: g_bNoGUI
any   press grave           toggle_console   [R] the load screens' console of the renderer's log (console.rs)
any   press ctrl+f10        lock_camera      [V] Idle @0x1afdda4: g_bLockCamera (not done here)
any   press f11             screenshot       [V] Idle @0x1afdcf8 (not done here)
# the screens: the game's Escape is the .gui shortcuts' (main_bottom.gui button_topbar_menu,
# the windows' close buttons); the renderer's back goes selection, system, galaxy, menu
map   press escape          back             [I] main_bottom.gui ESCAPE: the game opens its menu window
load  press escape          back             [R]
load  click left            select           [V] loadgame_view.gui: a session row (select) or its Load Latest Save button acts on the release
map   press v               map_2d_3d        [R] the renderer's 2D map
menu  press c               continue         [R]
menu  click left            select           [V] a GUI button acts on the release over the button pressed (CButton)
# the new game's screens (select_empire_design.gui, game_setup/setup.gui): a button's click, its
# shortcuts, the lists' wheel
setup click left            select           [V] a GUI button acts on the release over the button pressed
setup press escape          back             [V] select_empire_design_view back / gamesetup_setupview back_button: shortcut ESCAPE
setup press return          accept           [V] select_empire_design_view next / gamesetup_setupview next_button: shortcut RETURN
setup wheel -               zoom             [V] the list under the pointer scrolls (smoothListbox)
menu  press q               quit             [R]
";

/// Reads bindings (`BINDINGS`' format); `#` starts a comment.
pub fn parse_bindings(text: &str) -> Result<Vec<Binding>, String> {
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let w: Vec<&str> = line.split_whitespace().collect();
        let err = |m: &str| format!("bindings line {}: {m}: {line}", n + 1);
        if w.len() < 4 {
            return Err(err("CONTEXT TRIGGER INPUT ACTION [SOURCE]"));
        }
        let context = match w[0] {
            "map" => Context::Map,
            "menu" => Context::Menu,
            "load" => Context::Load,
            "setup" => Context::Setup,
            "any" => Context::Any,
            c => return Err(err(&format!("context {c}"))),
        };
        let keyed = |s: &str| -> Result<(ModMatch, String), String> {
            match s.strip_prefix("any+") {
                Some(k) => Ok((ModMatch::Any, chord(k).map_err(|e| err(&e))?.key)),
                None => chord(s).map(|c| (ModMatch::Exact(c.mods), c.key)).map_err(|e| err(&e)),
            }
        };
        let button = |s: &str| -> Result<(ModMatch, Button), String> {
            let (mods, b) = match s.rsplit_once('+') {
                // `any+BUTTON`: whatever modifiers are held (the right click's Shift / Ctrl / Alt)
                Some(("any", b)) => (ModMatch::Any, b),
                Some((m, b)) => (ModMatch::Exact(chord(&format!("{m}+a")).map_err(|e| err(&e))?.mods), b),
                None => (ModMatch::Exact(Mods::default()), s),
            };
            Ok((mods, Button::parse(b).ok_or(err(&format!("button {b}")))?))
        };
        let trigger = match w[1] {
            "press" => keyed(w[2]).map(|(m, k)| Trigger::Press(m, k))?,
            "release" => keyed(w[2]).map(|(m, k)| Trigger::Release(m, k))?,
            "hold" => keyed(w[2]).map(|(m, k)| Trigger::Hold(m, k))?,
            "poll" => Trigger::Poll(keyed(w[2])?.1),
            "click" => button(w[2]).map(|(m, b)| Trigger::Click(m, b))?,
            "drag_release" => Trigger::DragRelease(button(w[2])?.1),
            "double" => Trigger::Double(button(w[2])?.1),
            "drag" => Trigger::Drag(w[2].split('+').map(|b| Button::parse(b).ok_or(err(&format!("button {b}")))).collect::<Result<_, _>>()?),
            "wheel" => Trigger::Wheel,
            t => return Err(err(&format!("trigger {t}"))),
        };
        let action = Action::parse(w[3]).ok_or(err(&format!("action {}", w[3])))?;
        out.push(Binding { context, trigger, action, source: w[4..].join(" ") });
    }
    Ok(out)
}

/// What the app does for input.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// a key binding's action
    Act(Action),
    /// the pointer moved (the GUI's hover, the edge scrolling), or left the window
    Pointer(Option<(f32, f32)>),
    /// a button went down at the pointer (the GUI's pressed frame)
    Down(Button, f32, f32),
    /// a button binding's action at the pointer (select, focus, order, box select, ping)
    At(Action, f32, f32),
    /// a drag binding, this frame: the pointer's motion this frame and where it is
    Drag(Action, f32, f32, f32, f32),
    /// a drag binding starts (the pointer where it is), or ends
    DragStart(Action, f32, f32),
    DragEnd(Action),
    /// a wheel step (+1 in, -1 out); smooth: the right button held
    Zoom(f32, bool),
}

/// A button held: where it went down, whether it went 4 pixels from there.
#[derive(Clone, Copy, Debug)]
struct Held {
    at: (f32, f32),
    far: bool,
}

/// The input's state and the bindings.
pub struct Controls {
    pub bindings: Vec<Binding>,
    keys: BTreeSet<String>,
    buttons: BTreeMap<Button, Held>,
    pointer: Option<(f32, f32)>,
    /// the pointer at the last frame (the frame's motion)
    frame_pointer: Option<(f32, f32)>,
    /// a hold binding's action started (latched) and going on
    latched: BTreeSet<Action>,
    /// the drag bindings going on
    dragging: BTreeSet<Action>,
    /// a left press armed for a double click: when (ms); any motion disarms it
    armed: Option<(Button, f64)>,
    /// the wheel's last notch since the last frame
    wheel: Option<f32>,
}

impl Default for Controls {
    fn default() -> Self {
        Controls::new(parse_bindings(BINDINGS).expect("the built-in bindings"))
    }
}

/// The double click's time (CSdlEvents::HandlePdxEvents @0x42d5011: disarmed at 501 ms).
pub const DOUBLE_CLICK_MS: f64 = 500.0;

impl Controls {
    pub fn new(bindings: Vec<Binding>) -> Controls {
        Controls {
            bindings,
            keys: BTreeSet::new(),
            buttons: BTreeMap::new(),
            pointer: None,
            frame_pointer: None,
            latched: BTreeSet::new(),
            dragging: BTreeSet::new(),
            armed: None,
            wheel: None,
        }
    }

    /// The bindings of STELLAR_RENDER_BINDINGS (a file in `BINDINGS`' format) if set, else the
    /// built-in ones.
    pub fn from_env() -> Result<Controls, String> {
        match std::env::var("STELLAR_RENDER_BINDINGS") {
            Ok(p) if !p.is_empty() => {
                let text = std::fs::read_to_string(&p).map_err(|e| format!("{p}: {e}"))?;
                Ok(Controls::new(parse_bindings(&text)?))
            }
            _ => Ok(Controls::default()),
        }
    }

    pub fn mods(&self) -> Mods {
        Mods { shift: self.keys.contains("shift"), ctrl: self.keys.contains("ctrl"), alt: self.keys.contains("alt") }
    }
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.keys.iter()
    }
    pub fn buttons(&self) -> impl Iterator<Item = &Button> {
        self.buttons.keys()
    }
    pub fn pointer(&self) -> Option<(f32, f32)> {
        self.pointer
    }
    /// The held actions going on (scrolling, the keyboard's zoom).
    pub fn held(&self) -> Vec<Action> {
        let mut v: Vec<Action> = self.latched.iter().copied().collect();
        for b in &self.bindings {
            if let Trigger::Poll(k) = &b.trigger {
                if self.keys.contains(k) && !v.contains(&b.action) {
                    v.push(b.action);
                }
            }
        }
        v
    }
    /// Whether a drag binding is going on (the camera held: no edge scrolling).
    pub fn holding(&self) -> bool {
        !self.dragging.is_empty()
    }

    fn active(&self, b: &Binding, ctx: Context) -> bool {
        b.context == Context::Any || b.context == ctx
    }

    /// An input event: the effects of the bindings it sets off. `now_ms`: the time (a double
    /// click's), `ctx`: the app's screen.
    pub fn input(&mut self, input: &Input, now_ms: f64, ctx: Context) -> Vec<Effect> {
        let mut out = Vec::new();
        match input {
            Input::Key { key, down: true, repeat } => {
                let mods = self.mods();
                let first = self.keys.insert(key.clone());
                if *repeat || !first {
                    return out;
                }
                let mut latch = Vec::new();
                for b in self.bindings.iter().filter(|b| self.active(b, ctx)) {
                    match &b.trigger {
                        Trigger::Press(m, k) if k == key && m.matches(mods) => out.push(Effect::Act(b.action)),
                        Trigger::Hold(m, k) if k == key && m.matches(mods) => latch.push(b.action),
                        _ => {}
                    }
                }
                self.latched.extend(latch);
            }
            Input::Key { key, down: false, .. } => {
                // the modifiers as they are with the key still down (the game's event carries them)
                let mods = self.mods();
                self.keys.remove(key);
                let mods = if matches!(key.as_str(), "shift" | "ctrl" | "alt") { self.mods() } else { mods };
                for b in self.bindings.iter().filter(|b| self.active(b, ctx)) {
                    if let Trigger::Release(m, k) = &b.trigger {
                        if k == key && m.matches(mods) {
                            out.push(Effect::Act(b.action));
                        }
                    }
                }
            }
            Input::Move { x, y } => {
                if self.pointer != Some((*x, *y)) {
                    self.pointer = Some((*x, *y));
                    // any motion disarms a double click (HandlePdxEventsNormal @0x42d51cf)
                    self.armed = None;
                    for h in self.buttons.values_mut() {
                        if (x - h.at.0).powi(2) + (y - h.at.1).powi(2) > MOUSE_MOVEMENT_TO_START_ROTATION_SQ {
                            h.far = true;
                        }
                    }
                    if self.dragging.is_empty() {
                        out.push(Effect::Pointer(Some((*x, *y))));
                    }
                }
            }
            Input::Leave => {
                self.pointer = None;
                out.push(Effect::Pointer(None));
            }
            Input::Wheel { notches } => {
                if *notches != 0.0 {
                    self.wheel = Some(*notches);
                }
            }
            Input::Button { button, down: true } => {
                let (x, y) = self.pointer.unwrap_or((0.0, 0.0));
                self.buttons.insert(*button, Held { at: (x, y), far: false });
                let double = matches!(self.armed, Some((b, t)) if b == *button && now_ms - t <= DOUBLE_CLICK_MS);
                if double {
                    self.armed = None;
                    for b in self.bindings.iter().filter(|b| self.active(b, ctx)) {
                        if b.trigger == Trigger::Double(*button) {
                            out.push(Effect::At(b.action, x, y));
                        }
                    }
                } else {
                    self.armed = Some((*button, now_ms));
                    out.push(Effect::Down(*button, x, y));
                }
            }
            Input::Button { button, down: false } => {
                let Some(h) = self.buttons.remove(button) else { return out };
                let (x, y) = self.pointer.unwrap_or(h.at);
                let mods = self.mods();
                // a drag ends when one of its buttons is up
                let ended: Vec<Action> = self
                    .bindings
                    .iter()
                    .filter(|b| matches!(&b.trigger, Trigger::Drag(bs) if bs.contains(button)) && self.dragging.contains(&b.action))
                    .map(|b| b.action)
                    .collect();
                // the right button's release orders unless it turned the camera (@0x1c862a2)
                let turned = ended.contains(&Action::Rotate);
                for a in ended {
                    if self.dragging.remove(&a) {
                        out.push(Effect::DragEnd(a));
                    }
                }
                for b in self.bindings.iter().filter(|b| self.active(b, ctx)) {
                    match &b.trigger {
                        Trigger::Click(m, bt) if bt == button && !h.far && !turned && m.matches(mods) => out.push(Effect::At(b.action, x, y)),
                        Trigger::DragRelease(bt) if bt == button && h.far && !turned => out.push(Effect::At(b.action, x, y)),
                        _ => {}
                    }
                }
            }
        }
        out
    }

    /// A frame (the game's camera update): what it polls. Held keys that are up end their
    /// actions; drags start (rotate: from 4 pixels on) and go on by the frame's motion; the
    /// wheel's last notch zooms.
    pub fn frame(&mut self, ctx: Context) -> Vec<Effect> {
        let mut out = Vec::new();
        // a latched hold goes on while one of its keys is down (UpdateScrollingMovement)
        let keys = &self.keys;
        let bindings = &self.bindings;
        self.latched.retain(|a| bindings.iter().any(|b| b.action == *a && matches!(&b.trigger, Trigger::Hold(_, k) if keys.contains(k))));
        let p = self.pointer.unwrap_or((0.0, 0.0));
        let fp = self.frame_pointer.unwrap_or(p);
        let (dx, dy) = (p.0 - fp.0, p.1 - fp.1);
        self.frame_pointer = self.pointer;
        let mut drags: Vec<(Action, bool)> = Vec::new();
        for b in self.bindings.iter().filter(|b| b.context == Context::Any || b.context == ctx) {
            if let Trigger::Drag(bs) = &b.trigger {
                let held = bs.iter().all(|x| self.buttons.contains_key(x));
                // turning waits for 4 pixels from the press; dragging the plane starts at once
                let far = b.action != Action::Rotate || bs.iter().all(|x| self.buttons.get(x).is_some_and(|h| h.far));
                if held && far && !drags.iter().any(|(a, _)| *a == b.action) {
                    drags.push((b.action, true));
                }
            }
        }
        for (a, _) in &drags {
            if self.dragging.insert(*a) {
                out.push(Effect::DragStart(*a, p.0, p.1));
            }
            out.push(Effect::Drag(*a, dx, dy, p.0, p.1));
        }
        let gone: Vec<Action> = self.dragging.iter().filter(|a| !drags.iter().any(|(d, _)| d == *a)).copied().collect();
        for a in gone {
            self.dragging.remove(&a);
            out.push(Effect::DragEnd(a));
        }
        if let Some(n) = self.wheel.take() {
            let smooth = self.buttons.contains_key(&Button::Right);
            if self.bindings.iter().any(|b| b.trigger == Trigger::Wheel && self.active(b, ctx)) {
                out.push(Effect::Zoom(n.signum(), smooth));
            }
        }
        out
    }

    /// The bindings as text (the protocol's `bindings`).
    pub fn describe(&self) -> Vec<String> {
        self.bindings
            .iter()
            .map(|b| {
                let ctx = format!("{:?}", b.context).to_lowercase();
                let mm = |m: &ModMatch| match m {
                    ModMatch::Any => "any+".to_string(),
                    ModMatch::Exact(m) => m.prefix(),
                };
                let t = match &b.trigger {
                    Trigger::Press(m, k) => format!("press {}{k}", mm(m)),
                    Trigger::Release(m, k) => format!("release {}{k}", mm(m)),
                    Trigger::Hold(m, k) => format!("hold {}{k}", mm(m)),
                    Trigger::Poll(k) => format!("poll {k}"),
                    Trigger::Click(m, bt) => format!("click {}{}", mm(m), bt.name()),
                    Trigger::DragRelease(bt) => format!("drag_release {}", bt.name()),
                    Trigger::Double(bt) => format!("double {}", bt.name()),
                    Trigger::Drag(bs) => format!("drag {}", bs.iter().map(|b| b.name()).collect::<Vec<_>>().join("+")),
                    Trigger::Wheel => "wheel -".to_string(),
                };
                format!("{ctx} {t} {} {}", b.action.name(), b.source)
            })
            .collect()
    }
}

/// The inputs of a chord pressed (`down`: the modifiers, then the key) or released (the key,
/// then the modifiers), as headless.c's XTest presses them.
pub fn chord_inputs(c: &Chord, down: bool) -> Vec<Input> {
    let mods: Vec<&str> = [(c.mods.ctrl, "ctrl"), (c.mods.alt, "alt"), (c.mods.shift, "shift")].iter().filter(|m| m.0).map(|m| m.1).collect();
    let key = |k: &str| Input::Key { key: k.to_string(), down, repeat: false };
    let mut v: Vec<Input> = mods.iter().map(|m| key(m)).collect();
    if down {
        v.push(key(&c.key));
    } else {
        v.insert(0, key(&c.key));
        v[1..].reverse();
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(k: &str, down: bool) -> Input {
        Input::Key { key: k.into(), down, repeat: false }
    }

    #[test]
    fn names_and_chords() {
        assert_eq!(key_name("W").as_deref(), Some("w"));
        assert_eq!(key_name(".").as_deref(), Some("period"));
        assert_eq!(key_name("PAGE_UP").as_deref(), Some("pageup"));
        assert_eq!(key_name("F12").as_deref(), Some("f12"));
        assert_eq!(key_name("kp_7").as_deref(), Some("kp_7"));
        assert_eq!(key_name("f25"), None);
        assert_eq!(key_name("wat"), None);
        let c = chord("Shift+Up").unwrap();
        assert_eq!((c.mods, c.key.as_str()), (Mods { shift: true, ..Default::default() }, "up"));
        let c = chord("+").unwrap();
        assert_eq!(c.to_string(), "shift+equal");
        assert_eq!(chord("ctrl+alt+f9").unwrap().to_string(), "ctrl+alt+f9");
        assert!(chord("shift+nope").is_err());
        let i = chord_inputs(&chord("ctrl+shift+backspace").unwrap(), false);
        assert_eq!(i, vec![key("backspace", false), key("shift", false), key("ctrl", false)]);
    }

    #[test]
    fn the_built_in_bindings_parse() {
        let b = parse_bindings(BINDINGS).unwrap();
        assert!(b.len() > 40);
        // every action named, every binding described back the same way
        let c = Controls::new(b.clone());
        let again = parse_bindings(&c.describe().join("\n")).unwrap();
        assert_eq!(again.len(), b.len());
        for (x, y) in b.iter().zip(&again) {
            assert_eq!(x.trigger, y.trigger);
            assert_eq!(x.action, y.action);
        }
    }

    #[test]
    fn the_clock_acts_on_release_with_exact_modifiers() {
        let mut c = Controls::default();
        assert!(c.input(&key("space", true), 0.0, Context::Map).is_empty());
        assert_eq!(c.input(&key("space", false), 0.0, Context::Map), vec![Effect::Act(Action::Pause)]);
        // Shift+Up: the speed when released, and no scrolling
        c.input(&key("shift", true), 0.0, Context::Map);
        c.input(&key("up", true), 0.0, Context::Map);
        c.frame(Context::Map);
        assert!(c.held().is_empty());
        assert_eq!(c.input(&key("up", false), 0.0, Context::Map), vec![Effect::Act(Action::SpeedUp)]);
        c.input(&key("shift", false), 0.0, Context::Map);
        // '=' alone and with Shift: faster; Ctrl+'=' nothing
        assert_eq!(c.input(&key("equal", true), 0.0, Context::Map), vec![]);
        assert_eq!(c.input(&key("equal", false), 0.0, Context::Map), vec![Effect::Act(Action::SpeedUp)]);
        c.input(&key("ctrl", true), 0.0, Context::Map);
        c.input(&key("equal", true), 0.0, Context::Map);
        assert!(c.input(&key("equal", false), 0.0, Context::Map).is_empty());
        // not on the menu
        c.input(&key("ctrl", false), 0.0, Context::Map);
        c.input(&key("space", true), 0.0, Context::Menu);
        assert!(c.input(&key("space", false), 0.0, Context::Menu).is_empty());
    }

    #[test]
    fn scrolling_latches_on_a_plain_press_and_polls() {
        let mut c = Controls::default();
        c.input(&key("w", true), 0.0, Context::Map);
        c.frame(Context::Map);
        assert_eq!(c.held(), vec![Action::ScrollUp]);
        // Shift pressed meanwhile: it goes on while W is down
        c.input(&key("shift", true), 0.0, Context::Map);
        c.frame(Context::Map);
        assert_eq!(c.held(), vec![Action::ScrollUp]);
        c.input(&key("w", false), 0.0, Context::Map);
        c.frame(Context::Map);
        assert!(c.held().is_empty());
        // a press with Shift does not start it; Page Up polls with any modifier
        c.input(&key("s", true), 0.0, Context::Map);
        c.input(&key("pageup", true), 0.0, Context::Map);
        c.frame(Context::Map);
        assert_eq!(c.held(), vec![Action::ZoomIn]);
    }

    #[test]
    fn clicks_drags_and_double_clicks() {
        let mut c = Controls::default();
        let m = |x: f32, y: f32| Input::Move { x, y };
        let b = |b: Button, down: bool| Input::Button { button: b, down };
        c.input(&m(100.0, 100.0), 0.0, Context::Map);
        assert_eq!(c.input(&b(Button::Left, true), 0.0, Context::Map), vec![Effect::Down(Button::Left, 100.0, 100.0)]);
        assert_eq!(c.input(&b(Button::Left, false), 10.0, Context::Map), vec![Effect::At(Action::Select, 100.0, 100.0)]);
        // the second press within 500 ms, no motion: a double click; its release selects
        assert_eq!(c.input(&b(Button::Left, true), 20.0, Context::Map), vec![Effect::At(Action::Focus, 100.0, 100.0)]);
        assert_eq!(c.input(&b(Button::Left, false), 30.0, Context::Map), vec![Effect::At(Action::Select, 100.0, 100.0)]);
        // a motion between disarms it
        c.input(&b(Button::Left, true), 40.0, Context::Map);
        c.input(&b(Button::Left, false), 40.0, Context::Map);
        c.input(&m(101.0, 100.0), 40.0, Context::Map);
        assert_eq!(c.input(&b(Button::Left, true), 50.0, Context::Map), vec![Effect::Down(Button::Left, 101.0, 100.0)]);
        c.input(&b(Button::Left, false), 50.0, Context::Map);
        // too late
        assert_eq!(c.input(&b(Button::Left, true), 600.0, Context::Map), vec![Effect::Down(Button::Left, 101.0, 100.0)]);
        c.input(&b(Button::Left, false), 600.0, Context::Map);
        // the right button turns from 4 pixels on, by each frame's motion; then no order
        c.frame(Context::Map);
        c.input(&b(Button::Right, true), 700.0, Context::Map);
        c.input(&m(103.0, 100.0), 700.0, Context::Map);
        assert!(c.frame(Context::Map).is_empty());
        c.input(&m(111.0, 103.0), 700.0, Context::Map);
        let f = c.frame(Context::Map);
        assert_eq!(f, vec![Effect::DragStart(Action::Rotate, 111.0, 103.0), Effect::Drag(Action::Rotate, 8.0, 3.0, 111.0, 103.0)]);
        assert_eq!(c.input(&b(Button::Right, false), 700.0, Context::Map), vec![Effect::DragEnd(Action::Rotate)]);
        // a right click without turning orders
        c.input(&b(Button::Right, true), 800.0, Context::Map);
        assert_eq!(c.input(&b(Button::Right, false), 800.0, Context::Map), vec![Effect::At(Action::Order, 111.0, 103.0)]);
        // the middle button drags the plane at once
        c.input(&b(Button::Middle, true), 900.0, Context::Map);
        assert_eq!(c.frame(Context::Map), vec![Effect::DragStart(Action::DragPlane, 111.0, 103.0), Effect::Drag(Action::DragPlane, 0.0, 0.0, 111.0, 103.0)]);
        c.input(&b(Button::Middle, false), 900.0, Context::Map);
        // the wheel: the frame's last notch, smooth with the right button held
        c.input(&Input::Wheel { notches: 1.0 }, 0.0, Context::Map);
        c.input(&Input::Wheel { notches: -2.0 }, 0.0, Context::Map);
        assert_eq!(c.frame(Context::Map), vec![Effect::Zoom(-1.0, false)]);
        assert!(c.frame(Context::Map).is_empty());
    }
}
