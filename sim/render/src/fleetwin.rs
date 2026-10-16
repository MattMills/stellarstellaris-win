//! The fleet windows (docs/windows/fleet.md): the selected fleet's `fleet_view`
//! (interface/fleet_view.gui) and a ship's `ship_view` (ship_view.gui); the left bar's Fleet
//! Manager (`fleet_manager_view`) is a left bar view (views.rs, `lua/render/windows/
//! fleet_manager.lua`), opened here from the fleet and ship views' buttons. What the windows show
//! is read from the world by `lua/render/windows/fleet_data.lua` (in the map's runtime while it has
//! the world, else the simulation's thread) and laid out by `lua/render/windows/fleet.lua` (in the
//! front end's runtime: the GUI's database and localisation); the data crosses between the
//! runtimes as Lua source.
//!
//! The windows open as the game opens them: a fleet selected (the outliner, the map, `select
//! fleet ID`) shows its fleet_view; a ship row's inspect button (or `open ship ID`) its
//! ship_view, over the fleet_view. Clicks carry actions `fleet:...` (App::fleet_act).

use stellar_sim::mlua::{self, Table};

use crate::app::App;
use crate::gui::{self, GuiItem};
use crate::scene::Pickable;

/// What of the fleet windows is open besides the selected fleet's fleet_view.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FleetWindows {
    /// the ship_view's ship (CInGameIdler::ShowShipView)
    pub ship: Option<u32>,
    /// a targeted order armed (its button clicked: the next map click is its target, as the
    /// game's order buttons' OnClick(target) overloads): the fleet and the order's name
    pub armed: Option<(u32, String)>,
    /// a counter of the commands done (their effect re-read: the windows laid out again)
    pub commands: u64,
}

impl FleetWindows {
    /// What the windows were laid out for (a change lays them out again).
    pub fn key(&self) -> u64 {
        let mut k = self.ship.map_or(0, |s| s as u64 + 1);
        if let Some((f, o)) = &self.armed {
            k = k.wrapping_mul(1_000_003).wrapping_add(*f as u64 + o.len() as u64 * 7919);
        }
        k.wrapping_mul(1_000_003).wrapping_add(self.commands)
    }
}

/// The left bar view of the Fleet Manager (ETopBarView 8, `fleet_manager`).
const MANAGER: &str = "fleet_manager";

impl App {
    /// `open fleet ID`, `open ship ID`, `open fleet_manager` (the left bar's view, as
    /// `open_view fleet_manager`), `open none` (the headless game's command: the same windows
    /// opened with the game's own calls).
    pub fn fleet_open(&mut self, what: &str, id: Option<u32>) -> Result<String, String> {
        match (what, id) {
            ("fleet", Some(id)) => {
                let m = self.map.as_ref().ok_or("no map loaded")?;
                if !m.galaxy.fleets.iter().any(|f| f.id == id) {
                    return Err(format!("open: no fleet {id}"));
                }
                self.select(Some(Pickable::Fleet(id)));
            }
            ("ship", Some(id)) => {
                self.fleet.ship = Some(id);
            }
            ("fleet_manager", _) => {
                if self.open_view.as_deref() != Some(MANAGER) {
                    self.toggle_view(MANAGER);
                }
            }
            ("none", _) => {
                self.select(None);
                self.fleet = FleetWindows::default();
                if self.open_view.as_deref() == Some(MANAGER) {
                    self.close_view();
                }
            }
            _ => return Err("open fleet ID, ship ID, fleet_manager or none".into()),
        }
        self.relayout_windows();
        Ok(format!("open {what}{}", id.map_or(String::new(), |i| format!(" {i}"))))
    }

    /// A click on a fleet window's button: `fleet:ship:ID` (a ship row's inspect: the ship_view),
    /// `fleet:close_ship`, `fleet:manager:ID` (the fleet and ship views' Fleet Manager button),
    /// `fleet:select:ID` (a fleet selected); the buttons that change the game (docs/windows/
    /// fleet.md "The buttons"): `fleet:do:FID:NAME`, `fleet:arm:FID:NAME`, `fleet:ship_do:SID:NAME`,
    /// `fleet:tpl:FID:DESIGN:DELTA`, `fleet:focus:FID`, `fleet:designer[:DESIGN]`.
    pub fn fleet_act(&mut self, action: &str) -> Result<(), String> {
        let parts: Vec<&str> = action.split(':').collect();
        let verb = parts.get(1).copied().unwrap_or("");
        let id = parts.get(2).and_then(|v| v.parse::<u32>().ok());
        let name = parts.get(3).copied().unwrap_or("");
        match (verb, id) {
            // an order or action done at once (the buttons' OnClick() without a target):
            // render.windows.fleet_commands.NAME(FID) in the world
            ("do", Some(fid)) if is_name(name) => {
                self.fleet.armed = None;
                self.fleet_command(&format!("[{name:?}]({fid})"))?;
            }
            // a targeted order: armed (its button again: disarmed); the next map click is its
            // target (fleet_target)
            ("arm", Some(fid)) if is_name(name) => {
                let next = Some((fid, name.to_string()));
                self.fleet.armed = if self.fleet.armed == next { None } else { next };
                self.log.push(format!("fleet order armed: {:?}", self.fleet.armed));
            }
            // a ship's own action (its row's disband): fleet_commands.ship_NAME(SID)
            ("ship_do", Some(sid)) if is_name(name) => {
                self.fleet_command(&format!("[\"ship_{name}\"]({sid})"))?;
            }
            // a Fleet Manager design row's increase / decrease (`fleet:tpl:FID:DESIGN:DELTA`):
            // the template's count (fleet_commands.template)
            ("tpl", Some(fid)) => {
                let did = name.parse::<u32>().map_err(|_| format!("bad action {action}"))?;
                let delta = parts.get(4).and_then(|v| v.parse::<i32>().ok()).unwrap_or(0);
                self.fleet_command(&format!(".template({fid}, {did}, {delta})"))?;
            }
            // the focus button (CFleetViewEntry::OnFocus): the camera to the fleet, following it
            ("focus", Some(fid)) => {
                self.focus(Pickable::Fleet(fid))?;
            }
            // the ship view's Open Designer (CShipView's open_designer: the ship designer on the
            // ship's design, the one it upgrades to when it has one [I]): designer.rs; the ship view
            // closes [I]
            // (the fleet manager's Ship Designer tab: the designer without a design); the fleet
            // view closes too, as with the Fleet Manager button (its rows were drawn over the
            // designer) [I]
            ("designer", did) => {
                self.fleet.ship = None;
                self.fleet.armed = None;
                self.select(None);
                self.set_designer(crate::designer::Designer { open: true, design: did });
            }
            ("ship", Some(id)) => self.fleet.ship = Some(id),
            ("close_ship", _) => self.fleet.ship = None,
            // the fleet view's and ship view's Fleet Manager button (ShowFleetManagerView(the
            // fleet's template)): the left bar's view, one at a time, on that fleet with its side
            // panel (`side`: SelectTemplate shows the Build Queue; from the left bar the game
            // shows none [I: the game's frames]); the ship view and the fleet view close (the
            // game's frame after the click [V], the selection's end there [I])
            ("manager", id) => {
                if self.open_view.as_deref() != Some(MANAGER) {
                    self.toggle_view(MANAGER);
                }
                let fleet = id.map(|f| f.to_string()).unwrap_or_default();
                self.set_view_state(&[("fleet", fleet.as_str()), ("side", "1")]);
                self.fleet.ship = None;
                self.select(None);
            }
            ("select", Some(id)) => self.select(Some(Pickable::Fleet(id))),
            _ => self.log.push(format!("  {action}: not done yet")),
        }
        self.relayout_windows();
        Ok(())
    }

    /// Escape disarms an armed order, else closes the ship_view (its close button's shortcut);
    /// whether it did.
    pub fn fleet_escape(&mut self) -> bool {
        if self.fleet.armed.take().is_some() || self.fleet.ship.take().is_some() {
            self.relayout_windows();
            return true;
        }
        false
    }

    /// A fleet command run in the world (render.windows.fleet_commands, where the world is: the
    /// simulation's thread between days, else the map's own world): the state changed as the
    /// game's command changes it; the windows read it again. Returns the command's reply.
    pub fn fleet_command(&mut self, call: &str) -> Result<String, String> {
        // the engine's orders run in the simulation (its definitions, script layer, modifiers):
        // started now if the map shows the save's world alone (paused: no day runs, as `step 0`)
        if let Some(m) = self.map.as_mut() {
            if m.has_world() {
                let r = m.step(0)?;
                self.log.push(format!("fleet command: the simulation started ({r})"));
            }
        }
        let r = self.fleet_world_query(&format!("local fc = require('render.windows.fleet_commands') return tostring(fc{call})"))?;
        self.log.push(format!("fleet command: {call} -> {r}"));
        // the map shows it without a day run: a snapshot now, taken when it comes
        if let Some(c) = self.map.as_ref().and_then(|m| m.clock.as_ref()) {
            c.publish(true);
        }
        self.fleet.commands += 1;
        self.relayout_windows();
        Ok(r)
    }

    /// What a map pick is to a command: its kind and save id.
    fn fleet_target_of(&self, hit: Pickable) -> Option<(&'static str, u32)> {
        let m = self.map.as_ref()?;
        Some(match hit {
            Pickable::System(i) => ("system", m.galaxy.systems.get(i)?.id),
            Pickable::Fleet(f) => ("fleet", f),
            Pickable::Body(p) => ("planet", p),
            Pickable::Ship(s) => ("ship", s),
        })
    }

    /// A left click on the map while an order is armed: the order to what is under it
    /// (render.windows.fleet_commands.target(FID, ORDER, KIND, ID)); nothing under it disarms.
    /// Whether the click was taken.
    pub fn fleet_target(&mut self, hit: Option<Pickable>) -> Result<bool, String> {
        let Some((fid, order)) = self.fleet.armed.take() else { return Ok(false) };
        if let Some((kind, id)) = hit.and_then(|h| self.fleet_target_of(h)) {
            self.fleet_command(&format!(".target({fid}, {order:?}, {kind:?}, {id})"))?;
        } else {
            self.relayout_windows();
        }
        Ok(true)
    }

    /// The selected fleet whose fleet_view shows (a fleet that is not a station).
    pub fn fleet_view_id(&self) -> Option<u32> {
        let Some(Pickable::Fleet(id)) = self.selected else { return None };
        let m = self.map.as_ref()?;
        m.galaxy.fleets.iter().find(|f| f.id == id && !f.station).map(|f| f.id)
    }

    /// The fleet windows' items for a screen of `w` x `h`: fleet_view (the selected fleet),
    /// ship_view, in the game's order (later ones over earlier ones).
    pub fn fleet_items(&mut self, w: u32, h: u32) -> Result<Vec<GuiItem>, String> {
        let fleet = self.fleet_view_id();
        if fleet.is_none() && self.fleet.ship.is_none() {
            return Ok(Vec::new());
        }
        let mut calls = Vec::new();
        if let Some(id) = fleet {
            calls.push(format!("fleet = fd.fleet({id}),"));
        }
        if let Some(id) = self.fleet.ship {
            calls.push(format!("ship = fd.ship_view({id}),"));
        }
        // the armed order (its button's `_selected` sprite)
        if let Some((fid, name)) = &self.fleet.armed {
            calls.push(format!("armed = {{ {fid}, {name:?} }},"));
        }
        let source = self.fleet_world_query(&format!("return fd.serialize({{ {} }})", calls.join(" ")))?;
        let lua = &self.runtime.lua;
        let read = || -> mlua::Result<Vec<GuiItem>> {
            let data: Table = lua.load(&source).set_name("fleet windows' data").eval()?;
            lua.globals().set("RENDER_FLEET_WINDOWS", data)?;
            let t: Table = lua
                .load(format!(
                    "local items, report = require('render.windows.fleet').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {w}, height = {h} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_FLEET_WINDOWS) return {{ items = items, report = report }}"
                ))
                .eval()?;
            gui::read_items(t.get("items")?)
        };
        let mut items = read().map_err(|e| format!("render.windows.fleet: {e}"))?;
        // the fleet_view's flag: its owner's (CGameGraphics::ApplyCountryToButton); the greyed
        // buttons and the progress bars
        if let Some(m) = self.map.as_mut() {
            derived_textures(m, &items);
            let owner = fleet.and_then(|id| m.galaxy.fleets.iter().find(|f| f.id == id)).and_then(|f| f.owner);
            for it in items.iter_mut() {
                if let GuiItem::Sprite { path, sprite, kind, texture, .. } = it {
                    if kind == "unknownFlag" {
                        // a country the observer has no communications with: the define's
                        // PRE_COMMUNICATIONS_EMPIRE_FLAG (special/unknown.dds) [V] on a black solid
                        // background [I: the game's frame]
                        let name = format!("@flag:unknown:{sprite}");
                        if m.textures.find(&name).is_none() {
                            let def = gui::flag_sprite(&m.runtime, sprite);
                            let flag = crate::galaxy::Flag {
                                icon: ("special".into(), "unknown.dds".into()),
                                background: ("backgrounds".into(), "00_solid.dds".into()),
                                colours: vec![[0.0; 3], [0.0; 3], [0.0; 3], [0.0; 3]],
                            };
                            if let Some(img) = def.and_then(|d| crate::flag::compose(&mut m.cache.borrow_mut(), &m.game_dir, &d, &flag, [1.0; 4])) {
                                m.textures.add(&name, std::sync::Arc::new(img));
                            }
                        }
                        *texture = name;
                        *kind = "flagSpriteType".into();
                    } else if path.starts_with("/fleet_view/") {
                        m.flags(std::slice::from_mut(it), owner);
                    }
                }
            }
        }
        Ok(items)
    }

}

/// The textures render.windows.fleet names that are made, not read: `@grey:TEXTURE` (a disabled
/// button: the game's buttonstate shader's PixelShaderDisable, GreyOutLuminosity(colour,
/// GREY_OUT_GREYNESS 0.85, GREY_OUT_BRIGHTNESS 0.75) over the luminance 0.212671 r + 0.715160 g +
/// 0.072169 b: gfx/FX/utils.fxh, constants.fxh) and `@bar:FULL|EMPTY|VALUE|v|h` (a progress bar
/// at VALUE 0..100: progress.shader takes texture one where the bar's coordinate is within the
/// state, else texture two; a vertical bar fills from its bottom [I]). Made once, into the map's
/// textures.
pub(crate) fn derived_textures(m: &mut crate::Map, items: &[GuiItem]) {
    for it in items {
        let GuiItem::Sprite { texture, .. } = it else { continue };
        if !texture.starts_with('@') || m.textures.find(texture).is_some() {
            continue;
        }
        let mut cache = m.cache.borrow_mut();
        let img = if let Some(src) = texture.strip_prefix("@grey:") {
            let Ok(base) = cache.get(&m.game_dir, src) else { continue };
            let mut out = (**base).clone();
            for p in out.rgba.chunks_exact_mut(4) {
                let (r, g, b) = (p[0] as f32, p[1] as f32, p[2] as f32);
                let grey = 0.212671 * r + 0.715160 * g + 0.072169 * b;
                for (k, c) in [r, g, b].into_iter().enumerate() {
                    p[k] = ((grey * 0.85 + c * 0.15) * 0.75).round().clamp(0.0, 255.0) as u8;
                }
            }
            out
        } else if let Some(spec) = texture.strip_prefix("@bar:") {
            let parts: Vec<&str> = spec.split('|').collect();
            let [full, empty, value, dir] = parts[..] else { continue };
            let Ok(full) = cache.get(&m.game_dir, full).cloned() else { continue };
            let Ok(empty) = cache.get(&m.game_dir, empty).cloned() else { continue };
            let v = value.parse::<f32>().unwrap_or(100.0).clamp(0.0, 100.0) / 100.0;
            // the textures run along the bar (u: its length): a vertical bar's turned a quarter,
            // u from its bottom [I]
            let vertical = dir != "h";
            let (w, h) = if vertical { (full.height, full.width) } else { (full.width, full.height) };
            let mut rgba = vec![0u8; (w * h * 4) as usize];
            for y in 0..h {
                for x in 0..w {
                    let (u, t) = if vertical { (h - 1 - y, x) } else { (x, y) };
                    let filled = (u as f32 + 0.5) / full.width as f32 <= v;
                    let src = if filled { &full } else { &empty };
                    let su = (u * src.width / full.width.max(1)).min(src.width.saturating_sub(1));
                    let st = (t * src.height / full.height.max(1)).min(src.height.saturating_sub(1));
                    let i = ((y * w + x) * 4) as usize;
                    rgba[i..i + 4].copy_from_slice(&src.pixel(su, st));
                }
            }
            crate::dds::Image { width: w, height: h, rgba, format: "bar".into() }
        } else {
            continue;
        };
        drop(cache);
        m.textures.add(texture, std::sync::Arc::new(img));
    }
}

impl App {
    /// Runs `code` (with `fd` = render.windows.fleet_data) where the world is: the map's runtime
    /// while it has the save's world. Returns the string the code returns.
    fn fleet_world_query(&mut self, code: &str) -> Result<String, String> {
        let m = self.map.as_mut().ok_or("no map loaded")?;
        let code = format!("local fd = require('render.windows.fleet_data') {code}");
        if !m.has_world() {
            // the simulation's thread has the world (and its definitions and modifiers: the ship
            // view's stats)
            let clock = m.clock.as_ref().ok_or("no world: neither the map's nor a simulation")?;
            return clock.query(&code).map_err(|e| format!("render.windows.fleet_data (simulation): {e}"));
        }
        let lua = &m.runtime.lua;
        lua.load(code)
            .set_name("fleet windows' query")
            .eval::<String>()
            .map_err(|e| format!("render.windows.fleet_data: {e}"))
    }
}

/// A command's name: a Lua identifier (what an action may call in render.windows.fleet_commands).
fn is_name(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') && !s.starts_with(|c: char| c.is_ascii_digit())
}
