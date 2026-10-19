//! The planet view (interface/planet_view.gui, CPlanetView; docs/windows/planet.md): the planet's
//! data read from the save's world (`render.windows.planet`'s `data`, in the map's runtime) and
//! handed to the front end's runtime, where render.windows lays the window out with it
//! (`RENDER_PLANET`); which tab shows.

use crate::Map;
use stellar_sim::mlua;
use stellar_sim::runtime::Runtime;

/// The tabs (CPlanetView +0xc3a0: 1 summary, 2 management, 3 population, 4 armies; the holdings
/// tab is the corporate one), as the actions and `open_planet` name them.
pub const TABS: [&str; 5] = ["summary", "management", "population", "armies", "corporate"];

/// What the window shows: the planet it was opened for and its tab. Another planet keeps the tab
/// (CInGameIdler::ShowPlanetView passes tab 0, which CPlanetView::Show keeps; the game's frames:
/// the holdings tab stays on for the next planet); where the tab cannot open the window shows the
/// summary (CanOpenTab, render.windows.planet).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub id: Option<u32>,
    pub tab: String,
    /// the colonize window (colonize_planet_view.gui, CSurfaceView), open for this planet
    pub colonize: Option<u32>,
    /// the side bar's window (CPlanetView +0x390) and what it shows: `district:TYPE`,
    /// `building:ID`, `construction:ZONE`, `zone_construction:DISTRICT:SLOT`, `designation`,
    /// `decisions`, `terraform`, `automation`, `queue`, `pop:GROUP`, `job:TYPE`; None: closed
    pub side: Option<String>,
    /// the simulation's commands clicked before it was ready, done once it is (in order)
    pub pending: Vec<(u32, String)>,
    /// the last command's result, for the command protocol
    pub last: String,
    /// a dialog over the view: `rename`, `move_capital`, `destroy_building:ID`,
    /// `destroy_district:TYPE`, `disband:ARMY`; its OK runs the command (dialog_ok)
    pub dialog: Option<String>,
    /// the rename dialog's text as typed (None: the planet's name, untouched)
    pub text: Option<String>,
    /// the colonize window's selected source (a species id)
    pub source: Option<u32>,
    /// the colonize window's selected colony ship (a fleet id: expansion_source_fleet_entry)
    pub source_fleet: Option<u32>,
    /// the colonize window opened from a fleet's Colonize Planet (OpenColoniseView with the fleet
    /// as its filter: that fleet alone listed)
    pub colonize_fleet: Option<u32>,
}

impl State {
    /// The tab asked for planet `id`.
    pub fn tab_for(&mut self, id: u32) -> &str {
        if !TABS.contains(&self.tab.as_str()) {
            self.tab = "summary".into();
        }
        self.id = Some(id);
        &self.tab
    }

    /// Shows `tab` (one of [`TABS`]) for planet `id`.
    pub fn open(&mut self, id: u32, tab: &str) -> Result<(), String> {
        if !TABS.contains(&tab) {
            return Err(format!("no planet view tab {tab} ({})", TABS.join(", ")));
        }
        self.id = Some(id);
        self.tab = tab.into();
        Ok(())
    }
}

/// The planet's data (a Lua expression, render.windows.planet.encode) from the map's world, or
/// None when the map has no world (a running simulation: its world is on its own thread).
pub fn data(map: &Map, id: u32, side: &str) -> Result<Option<String>, String> {
    let gd = map.game_dir.replace('\\', "/");
    let code = format!("local p = require('render.windows.planet') local d = p.data({gd:?}, {id}, {side:?}) return d and p.encode(d) or ''");
    if map.world {
        return map
            .runtime
            .lua
            .load(code)
            .eval::<String>()
            .map(|s| if s.is_empty() { None } else { Some(s) })
            .map_err(|e| format!("render.windows.planet.data: {e}"));
    }
    // the simulation's world (its own thread): asked once a snapshot, when it is ready (the
    // window shows its frame and name until then; Clock::query would wait for the load)
    let Some(clock) = map.clock.as_ref() else { return Ok(None) };
    if !clock.status().ready {
        return Ok(None);
    }
    let generation = map.snapshot.as_ref().map_or(0, |s| s.generation);
    if let Some(d) = CACHE.with(|c| c.borrow().as_ref().filter(|(i, g, s, _)| *i == id && *g == generation && s == side).map(|(_, _, _, d)| d.clone())) {
        return Ok(d);
    }
    let d = clock.query(&code).map(|s| if s.is_empty() { None } else { Some(s) }).map_err(|e| format!("render.windows.planet.data: {e}"))?;
    CACHE.with(|c| *c.borrow_mut() = Some((id, generation, side.to_string(), d.clone())));
    Ok(d)
}

thread_local! {
    /// the last planet's data from the simulation: (planet, snapshot generation, data)
    static CACHE: std::cell::RefCell<Option<(u32, u64, String, Option<String>)>> = const { std::cell::RefCell::new(None) };
}

/// A planet view click (its `planet:` actions; docs/windows/planet.md, the buttons):
///   tab:TAB              the tab shown (CPlanetView::On*Tab)
///   colonize, colonize_close   the colonize window opened, closed
///   side:WINDOW[:ARGS]   the side bar shows WINDOW (CPlanetView +0x390); side_close closes it
///   prev, next           the previous / next planet of the owner's (previous_planet, next_planet)
///   zoom                 the camera to the planet (zoom_to_planet_button)
///   cmd:VERB[:ARGS]      a change to the game, done by the simulation (render.windows.planet
///                        .command): queued until the simulation is ready
pub fn act(app: &mut crate::app::App, action: &str) -> Result<(), String> {
    use crate::scene::Pickable;
    let rest = action.strip_prefix("planet:").unwrap_or(action);
    let Some(Pickable::Body(id)) = app.selected else { return Ok(()) };
    let (verb, arg) = rest.split_once(':').unwrap_or((rest, ""));
    match verb {
        "tab" => {
            app.planet_view.side = None;
            app.open_planet(id, arg)?;
        }
        "colonize" => app.planet_view.colonize = Some(id),
        "colonize_close" => {
            app.planet_view.colonize = None;
            app.planet_view.source = None;
            app.planet_view.source_fleet = None;
            app.planet_view.colonize_fleet = None;
        }
        "side" => {
            // the same window again closes it (the side bar's buttons toggle **[I]**)
            app.planet_view.side = if app.planet_view.side.as_deref() == Some(arg) { None } else { Some(arg.to_string()) };
        }
        "side_close" => app.planet_view.side = None,
        // the dialogs (rename, the confirmations): opened, typed into, accepted, closed
        "dialog" => {
            app.planet_view.dialog = Some(arg.to_string());
            app.planet_view.text = None;
        }
        "dialog_close" => {
            app.planet_view.dialog = None;
            app.planet_view.text = None;
        }
        "dialog_ok" => {
            if let Some(d) = app.planet_view.dialog.take() {
                let text = app.planet_view.text.take();
                let cmd = match d.split_once(':') {
                    None if d == "rename" => text.filter(|t| !t.trim().is_empty()).map(|t| format!("rename:{}", t.trim())),
                    None => Some(d.clone()),
                    Some((what, a)) => Some(format!("{what}:{a}")),
                };
                if let Some(cmd) = cmd {
                    // a demolished building's details close with it (the side bar shows nothing)
                    if cmd.starts_with("destroy_building:") {
                        app.planet_view.side = None;
                    }
                    app.planet_view.pending.push((id, cmd));
                    run_pending(app)?;
                }
            }
        }
        "text" => {
            // a character typed into the rename dialog (`:` would split the command: left out)
            if app.planet_view.dialog.as_deref() == Some("rename") && arg != ":" {
                app.planet_view.text.get_or_insert_with(String::new).push_str(arg);
            }
        }
        "key" => match arg {
            "backspace" => {
                let t = app.planet_view.text.get_or_insert_with(String::new);
                t.pop();
            }
            "return" => return act(app, "planet:dialog_ok"),
            "escape" => return act(app, "planet:dialog_close"),
            _ => {}
        },
        "source" => {
            let sid = arg.parse::<u32>().ok();
            app.planet_view.source = if app.planet_view.source == sid { None } else { sid };
            app.planet_view.source_fleet = None;
        }
        // a colony ship's entry (expansion_source_fleet_entry): selected, the species' unselected
        "source_fleet" => {
            let fid = arg.parse::<u32>().ok();
            app.planet_view.source_fleet = if app.planet_view.source_fleet == fid { None } else { fid };
            app.planet_view.source = None;
        }
        "prev" | "next" => {
            let owned: Vec<u32> = app.map.as_ref().map(|m| m.galaxy.planets.iter().map(|p| p.id).collect()).unwrap_or_default();
            if let Some(i) = owned.iter().position(|&p| p == id) {
                let n = owned.len();
                let j = if verb == "next" { (i + 1) % n } else { (i + n - 1) % n };
                let tab = app.planet_view.tab.clone();
                app.planet_view.side = None;
                app.open_planet(owned[j], if tab.is_empty() { "summary" } else { &tab })?;
            }
        }
        "zoom" => {
            let system = app.map.as_ref().and_then(|m| {
                let sid = m.galaxy.planets.iter().find(|p| p.id == id).map(|p| p.system).or(DATA_SYSTEM.with(|c| *c.borrow()))?;
                m.galaxy.systems.iter().position(|s| s.id as i64 == sid)
            });
            if let Some(i) = system {
                app.enter_system(i, None)?;
                app.focus(Pickable::Body(id))?;
            }
        }
        "cmd" => {
            app.planet_view.pending.push((id, arg.to_string()));
            run_pending(app)?;
            // colonizing closes the colonize window (the game's surface view closes on its order)
            if (arg.starts_with("colonize:") || arg.starts_with("colonize_fleet:")) && app.planet_view.last.starts_with("ok") {
                app.planet_view.colonize = None;
                app.planet_view.source = None;
                app.planet_view.source_fleet = None;
                app.planet_view.colonize_fleet = None;
            }
        }
        _ => app.log.push(format!("  planet view: {action}: not done")),
    }
    app.relayout();
    Ok(())
}

/// Escape on the planet view: closes its side bar, else its colonize window (both close buttons
/// have the shortcut ESCAPE); false when neither is open (the view closes then).
pub fn escape(app: &mut crate::app::App) -> bool {
    use crate::scene::Pickable;
    if !matches!(app.selected, Some(Pickable::Body(_))) {
        return false;
    }
    if app.planet_view.dialog.take().is_some() {
        app.planet_view.text = None;
        app.relayout();
        return true;
    }
    if app.planet_view.side.take().is_some() || app.planet_view.colonize.take().is_some() {
        app.relayout();
        return true;
    }
    false
}

/// The simulation's commands waiting for it: done when it is ready (started if it is not), each
/// as render.windows.planet.command in its world; the planet's data asked again after.
pub fn run_pending(app: &mut crate::app::App) -> Result<(), String> {
    if app.planet_view.pending.is_empty() {
        return Ok(());
    }
    let Some(map) = app.map.as_mut() else { return Ok(()) };
    map.start_clock();
    let ready = map.clock.as_ref().is_some_and(|c| c.status().ready);
    if !ready {
        app.log.push(format!("planet view: {} command(s) wait for the simulation", app.planet_view.pending.len()));
        return Ok(());
    }
    let gd = map.game_dir.replace('\\', "/");
    for (id, cmd) in std::mem::take(&mut app.planet_view.pending) {
        let mut parts = cmd.split(':');
        let verb = parts.next().unwrap_or("");
        let args: Vec<String> = if verb == "rename" {
            vec![format!("{:?}", cmd["rename:".len()..].to_string())]
        } else {
            parts.map(|a| format!("{a:?}")).collect()
        };
        let code = format!(
            "local r = require('render.windows.planet').command({gd:?}, {id}, {verb:?}{}{}) return tostring(r)",
            if args.is_empty() { "" } else { ", " },
            args.join(", ")
        );
        let r = map.clock.as_ref().unwrap().query(&code).unwrap_or_else(|e| format!("error {e}"));
        app.log.push(format!("planet view: {cmd}: {r}"));
        app.planet_view.last = r;
    }
    // the change in the next snapshot, the window's data asked again
    if let Some(c) = map.clock.as_ref() {
        c.publish(true);
    }
    map.sync();
    forget();
    Ok(())
}

thread_local! {
    /// the system of the planet whose data was read last (a planet not the player's: zoom)
    static DATA_SYSTEM: std::cell::RefCell<Option<i64>> = const { std::cell::RefCell::new(None) };
}

/// The view's dialog, the rename's text and the colonize window's source in `RENDER_PLANET`
/// (after [`prepare`]).
pub fn set_extras(front: &Runtime, view: &State) -> Result<(), String> {
    let lua = &front.lua;
    let set = || -> mlua::Result<()> {
        let Some(t) = lua.globals().get::<Option<mlua::Table>>("RENDER_PLANET")? else { return Ok(()) };
        t.set("dialog", view.dialog.clone())?;
        t.set("text", view.text.clone())?;
        t.set("source", view.source)?;
        t.set("source_fleet", view.source_fleet)?;
        t.set("colonize_fleet", view.colonize_fleet)?;
        Ok(())
    };
    set().map_err(|e| format!("planet view: {e}"))
}

/// A key typed while the rename dialog is open: its action (`planet:text:C`, `planet:key:NAME`),
/// from the empire creator's key names (app.rs creator_key); None when no dialog takes keys.
pub fn typed(view: &State, creator_action: &str) -> Option<String> {
    if view.dialog.as_deref() != Some("rename") {
        return None;
    }
    if let Some(c) = creator_action.strip_prefix("creator:text:") {
        return Some(format!("planet:text:{c}"));
    }
    creator_action.strip_prefix("creator:key:").map(|k| format!("planet:key:{k}"))
}

/// Forgets the simulation's data (a command changed the planet).
pub fn forget() {
    CACHE.with(|c| *c.borrow_mut() = None);
}

/// Hands planet `id`'s data and the tab shown to the front end's runtime (`RENDER_PLANET =
/// { id, tab, colonize, data }`, render.windows reads it); returns the planet's owner (a country
/// id).
pub fn prepare(front: &Runtime, map: &Map, id: u32, tab: &str, colonize: bool, side: Option<&str>) -> Result<Option<u32>, String> {
    let data = data(map, id, side.unwrap_or(""))?;
    let lua = &front.lua;
    let set = || -> mlua::Result<Option<u32>> {
        let t = lua.create_table()?;
        t.set("id", id)?;
        t.set("tab", tab)?;
        t.set("colonize", colonize)?;
        t.set("side", side)?;
        let mut owner = None;
        if let Some(d) = &data {
            lua.globals().set("RENDER_PLANET_TEXT", d.as_str())?;
            let decoded: mlua::Value = lua.load("local t = RENDER_PLANET_TEXT RENDER_PLANET_TEXT = nil return require('render.windows.planet').decode(t)").eval()?;
            if let mlua::Value::Table(dt) = &decoded {
                owner = dt.get::<Option<u32>>("owner")?;
                let system = dt.get::<Option<i64>>("system")?;
                DATA_SYSTEM.with(|c| *c.borrow_mut() = system);
                // the triggers the script layer could not evaluate (their parts drawn as false)
                if let Some(errors) = dt.get::<Option<Vec<String>>>("errors")? {
                    for e in errors {
                        eprintln!("planet view {id}: trigger: {e}");
                    }
                }
            }
            t.set("data", decoded)?;
        }
        lua.globals().set("RENDER_PLANET", t)?;
        Ok(owner)
    };
    set().map_err(|e| format!("planet view: {e}"))
}

/// The planet view's portraits among `items` (render.windows.planet names them
/// `@planet_portrait:PICTURE:CITY:LEVEL:TOP:HEIGHT`): composed once into the map's textures.
/// The game draws the planet's picture as a portrait (`CPortraitObject::SetEverythingByColonyCarrier`,
/// GFX_portrait_planet): `gfx/portraits/environments/<picture>_sky.dds` and its layers
/// `_l01`.. over it **[V]** (the files), each with the owner's city set's layer of the same number
/// (`gfx/portraits/city_sets/<city culture>_city_lNN.dds`) up to the colony's level **[I]** (the
/// game's frame of the capital: the spires of the molluscoid set over the ocean's islands); the
/// rows the window shows (its `portrait` container clips the 800 x 400 picture).
pub fn portraits(map: &mut Map, items: &mut [crate::gui::GuiItem], unowned: bool) {
    for it in items.iter_mut() {
        let crate::gui::GuiItem::Sprite { texture, path, kind, sprite, .. } = it else { continue };
        // an unowned planet's flag: the pre-communications flag (PRE_COMMUNICATIONS_EMPIRE_FLAG,
        // flags/special/unknown.dds, CPlanetView::UpdatePlanetPortrait) on a black field **[I]**
        if unowned && kind == "flagSpriteType" && path == "/planet_view/planet_portrait_window/flag" {
            let name = format!("@flag:unknown:{sprite}");
            if map.textures.find(&name).is_none() {
                let _ = crate::gui::install(&map.runtime, &map.game_dir, &map.cache);
                let flag = crate::galaxy::Flag {
                    icon: ("special".into(), "unknown.dds".into()),
                    background: ("backgrounds".into(), "00_solid.dds".into()),
                    colours: vec![[0.02, 0.03, 0.03]; 4],
                };
                let def = crate::gui::flag_sprite(&map.runtime, sprite);
                let img = def.and_then(|def| crate::flag::compose(&mut map.cache.borrow_mut(), &map.game_dir, &def, &flag, [1.0; 4]));
                match img {
                    Some(img) => {
                        map.textures.add(&name, std::sync::Arc::new(img));
                    }
                    None => continue,
                }
            }
            *texture = name;
            continue;
        }
        if map.textures.find(texture).is_some() {
            continue;
        }
        // an icon the .gui turns a quarter (`rotation = 1.56`, which render.gui does not draw):
        // its texture turned, the image's bottom to its right
        if let Some(path) = texture.strip_prefix("@planet_rot90:") {
            let img = crate::dds::find_case_insensitive(&map.game_dir, path).and_then(|f| crate::dds::load(&f).ok());
            if let Some(img) = img {
                let (w, h) = (img.width as usize, img.height as usize);
                let mut rgba = vec![0u8; w * h * 4];
                for y in 0..h {
                    for x in 0..w {
                        // (x, y) -> (y, w - 1 - x) in an h x w image: a quarter turn, the
                        // bottom edge becoming the right one
                        let (nx, ny) = (y, w - 1 - x);
                        let (s, d) = ((y * w + x) * 4, (ny * h + nx) * 4);
                        rgba[d..d + 4].copy_from_slice(&img.rgba[s..s + 4]);
                    }
                }
                let turned = crate::dds::Image { width: h as u32, height: w as u32, rgba, format: "planet view rotated".into() };
                map.textures.add(texture, std::sync::Arc::new(turned));
            }
            continue;
        }
        if !texture.starts_with("@planet_portrait:") {
            continue;
        }
        match compose(&map.game_dir, texture) {
            Some(img) => {
                map.textures.add(texture, std::sync::Arc::new(img));
            }
            None => eprintln!("planet view: no portrait {texture}"),
        }
    }
}

fn compose(game_dir: &str, name: &str) -> Option<crate::dds::Image> {
    let mut p = name.trim_start_matches("@planet_portrait:").split(':');
    let (picture, city, level, top, height) = (p.next()?, p.next()?, p.next()?.parse::<u32>().ok()?, p.next()?.parse::<u32>().ok()?, p.next()?.parse::<u32>().ok()?);
    let load = |rel: String| crate::dds::find_case_insensitive(game_dir, &rel).and_then(|f| crate::dds::load(&f).ok());
    let mut img = load(format!("gfx/portraits/environments/{picture}_sky.dds"))?;
    let (w, h) = (img.width as usize, img.height as usize);
    let mut over = |layer: crate::dds::Image| {
        if layer.width as usize != w || layer.height as usize != h {
            return;
        }
        for (d, s) in img.rgba.chunks_exact_mut(4).zip(layer.rgba.chunks_exact(4)) {
            let a = s[3] as f32 / 255.0;
            for c in 0..3 {
                d[c] = (s[c] as f32 * a + d[c] as f32 * (1.0 - a)).round() as u8;
            }
            d[3] = (s[3] as f32 + d[3] as f32 * (1.0 - a)).round().min(255.0) as u8;
        }
    };
    for i in 1..=6u32 {
        if let Some(l) = load(format!("gfx/portraits/environments/{picture}_l{i:02}.dds")) {
            over(l);
        }
        if !city.is_empty() && i <= level {
            if let Some(l) = load(format!("gfx/portraits/city_sets/{city}_city_l{i:02}.dds")) {
                over(l);
            }
        }
    }
    // the rows (and, given, the columns) the window shows
    let left = p.next().and_then(|v| v.parse::<usize>().ok()).unwrap_or(0).min(w);
    let cols = p.next().and_then(|v| v.parse::<usize>().ok()).unwrap_or(w).min(w - left);
    let top = (top as usize).min(h);
    let rows = (height as usize).min(h - top);
    let mut rgba = Vec::with_capacity(rows * cols * 4);
    for y in top..top + rows {
        rgba.extend_from_slice(&img.rgba[(y * w + left) * 4..(y * w + left + cols) * 4]);
    }
    Some(crate::dds::Image { width: cols as u32, height: rows as u32, rgba, format: "planet portrait".into() })
}

/// Forgets the window's data in the front end's runtime (another selection).
pub fn clear(front: &Runtime) {
    let _ = front.lua.globals().set("RENDER_PLANET", mlua::Value::Nil);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn another_planet_keeps_the_tab() {
        let mut s = State::default();
        assert_eq!(s.tab_for(5), "summary");
        s.open(5, "armies").unwrap();
        assert_eq!(s.tab_for(5), "armies");
        assert_eq!(s.tab_for(6), "armies");
        assert!(s.open(6, "nothing").is_err());
        assert_eq!(s.tab_for(6), "armies");
    }
}
