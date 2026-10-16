//! The fleet windows (docs/windows/fleet.md): the selected fleet's `fleet_view`
//! (interface/fleet_view.gui), a ship's `ship_view` (ship_view.gui) and the left bar's Fleet
//! Manager (`fleet_manager_view`, fleet_manager_view.gui). What they show is read from the map's
//! world by `lua/render/windows/fleet_data.lua` (in the map's runtime, which has the world) and
//! laid out by `lua/render/windows/fleet.lua` (in the front end's runtime: the GUI's database and
//! localisation); the data crosses between the two runtimes as Lua source.
//!
//! The windows open as the game opens them: a fleet selected (the outliner, the map, `select
//! fleet ID`) shows its fleet_view; a ship row's inspect button (or `open ship ID`) its
//! ship_view, over the fleet_view; the left bar's Fleet Manager button (or `open fleet_manager`)
//! the fleet manager. Clicks carry actions `fleet:...` (FleetWindows::act).

use stellar_sim::mlua::{self, Table};

use crate::app::App;
use crate::gui::{self, GuiItem};
use crate::scene::Pickable;

/// What of the fleet windows is open besides the selected fleet's fleet_view.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FleetWindows {
    /// the ship_view's ship (CInGameIdler::ShowShipView)
    pub ship: Option<u32>,
    /// the fleet manager shown (CFleetManagerView::Show), its selected fleet
    pub manager: bool,
    pub manager_fleet: Option<u32>,
}

impl FleetWindows {
    /// What the windows were laid out for (a change lays them out again).
    pub fn key(&self) -> u64 {
        let mut k = self.ship.map_or(0, |s| s as u64 + 1);
        k = k.wrapping_mul(1_000_003).wrapping_add(self.manager as u64);
        k.wrapping_mul(1_000_003).wrapping_add(self.manager_fleet.map_or(0, |f| f as u64 + 1))
    }
}

impl App {
    /// `open fleet ID`, `open ship ID`, `open fleet_manager`, `open none` (the headless game's
    /// command: the same windows opened with the game's own calls).
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
                self.fleet.manager = true;
            }
            ("none", _) => {
                self.select(None);
                self.fleet = FleetWindows::default();
            }
            _ => return Err("open fleet ID, ship ID, fleet_manager or none".into()),
        }
        self.relayout_windows();
        Ok(format!("open {what}{}", id.map_or(String::new(), |i| format!(" {i}"))))
    }

    /// A click on a fleet window's button: `fleet:ship:ID` (a ship row's inspect: the ship_view),
    /// `fleet:close_ship`, `fleet:manager` (open), `fleet:close_manager`, `fleet:manager_fleet:ID`
    /// (a fleet manager entry selected), `fleet:select:ID` (a fleet selected).
    pub fn fleet_act(&mut self, action: &str) -> Result<(), String> {
        let mut it = action.split(':').skip(1);
        let verb = it.next().unwrap_or("");
        let id = it.next().and_then(|v| v.parse::<u32>().ok());
        match (verb, id) {
            ("ship", Some(id)) => self.fleet.ship = Some(id),
            ("close_ship", _) => self.fleet.ship = None,
            ("manager", _) => self.fleet.manager = true,
            // the left bar's button (`view:fleet_manager`): toggles it, as
            // CInGameIdler::ToggleTopBarView does a top bar view (ETopBarView 8)
            ("fleet_manager", _) => self.fleet.manager = !self.fleet.manager,
            ("close_manager", _) => self.fleet.manager = false,
            ("manager_fleet", Some(id)) => self.fleet.manager_fleet = Some(id),
            ("select", Some(id)) => self.select(Some(Pickable::Fleet(id))),
            _ => self.log.push(format!("  {action}: not done yet")),
        }
        self.relayout_windows();
        Ok(())
    }

    /// Escape closes the topmost fleet window (the ship_view, then the fleet manager: their
    /// close buttons' shortcut); whether one was closed.
    pub fn fleet_escape(&mut self) -> bool {
        if self.fleet.ship.take().is_some() || std::mem::take(&mut self.fleet.manager) {
            self.relayout_windows();
            return true;
        }
        false
    }

    /// The selected fleet whose fleet_view shows (a fleet that is not a station).
    pub fn fleet_view_id(&self) -> Option<u32> {
        let Some(Pickable::Fleet(id)) = self.selected else { return None };
        let m = self.map.as_ref()?;
        m.galaxy.fleets.iter().find(|f| f.id == id && !f.station).map(|f| f.id)
    }

    /// The fleet windows' items for a screen of `w` x `h`: fleet_view (the selected fleet),
    /// ship_view, the fleet manager, in the game's order (later ones over earlier ones).
    pub fn fleet_items(&mut self, w: u32, h: u32) -> Result<Vec<GuiItem>, String> {
        let fleet = self.fleet_view_id();
        if fleet.is_none() && self.fleet.ship.is_none() && !self.fleet.manager {
            return Ok(Vec::new());
        }
        let mut calls = Vec::new();
        if let Some(id) = fleet {
            calls.push(format!("fleet = fd.fleet({id}),"));
        }
        if let Some(id) = self.fleet.ship {
            calls.push(format!("ship = fd.ship_view({id}),"));
        }
        if self.fleet.manager {
            calls.push(format!("manager = fd.manager(nil, {}),", self.fleet.manager_fleet.map_or("nil".into(), |f| f.to_string())));
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
                if let GuiItem::Sprite { path, .. } = it {
                    if path.starts_with("/fleet_view/") {
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
fn derived_textures(m: &mut crate::Map, items: &[GuiItem]) {
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
