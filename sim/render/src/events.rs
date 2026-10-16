//! The event windows, the popups, the Situation Log and the Discoveries view (docs/windows/events.md):
//! what is open (the windows' state, the clicks on them, the `event` command), laid out in Lua
//! (`lua/render/windows/events.lua`, `situations.lua`, `discoveries.lua`) from the world's data
//! (`lua/render/windows/events_data.lua`, carried in [`crate::galaxy::Galaxy::events`]).
//!
//! As the game: an event the simulation opens for the player shows its window at once (the game's
//! message system opens it, CMessageSystem::Update -> CInGameIdler::AddEventWindow); the events
//! open in a loaded save do not (the game's frame after a load shows none: the alert or the
//! Situation Log leads to them), `event ID` opens one as the headless game's `event ID` does.
//! Choosing an option closes the window: the simulation has already taken the first valid option
//! for the human player (simscript.events), so the click sends it no command [I].

use std::collections::{HashMap, HashSet};

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::app::App;
use crate::font::Font;
use crate::gui::{self, GuiItem};

/// A popup (popup.gui): its kind ("ok", "yes_no"), title and text (localisation keys or texts).
#[derive(Clone, Debug)]
pub struct Popup {
    pub kind: String,
    pub title: String,
    pub text: String,
}

/// What of these windows is open.
#[derive(Default)]
pub struct EventsUi {
    /// the event windows shown (open player event ids), the top one last
    pub open: Vec<i64>,
    /// the events seen in the world's data (a new one the simulation fired opens its window)
    seen: HashSet<i64>,
    /// the data has been read once since the load
    started: bool,
    pub popups: Vec<Popup>,
    /// the data chunk loaded into the runtime last (to load it again only when it changed)
    chunk: String,
}

/// The actions these windows' buttons carry.
pub fn handles(action: &str) -> bool {
    action.starts_with("event:") || action.starts_with("popup:")
}

impl EventsUi {
    /// A click: an option chosen or a window closed, a view opened or closed, a tab.
    pub fn act(&mut self, action: &str) {
        let parts: Vec<&str> = action.split(':').collect();
        let id = |k: usize| parts.get(k).and_then(|v| v.parse::<i64>().ok());
        match parts.as_slice() {
            // CEventWindow::DismissEvent / PostEventOptionSelection: the window closes
            ["event", "close", ..] | ["event", "option", ..] => {
                if let Some(id) = id(2) {
                    self.open.retain(|e| *e != id);
                }
            }
            // a click on a window brings it to the front (CEventWindow::MoveToFront)
            ["event", "front", ..] => {
                if let Some(id) = id(2) {
                    if let Some(k) = self.open.iter().position(|e| *e == id) {
                        let e = self.open.remove(k);
                        self.open.push(e);
                    }
                }
            }
            ["event", "open", ..] => {
                if let Some(id) = id(2) {
                    self.open.retain(|e| *e != id);
                    self.open.push(id);
                }
            }
            ["popup", _, k] => {
                if let Ok(k) = k.parse::<usize>() {
                    if k >= 1 && k <= self.popups.len() {
                        self.popups.remove(k - 1);
                    }
                }
            }
            _ => {}
        }
    }

    /// The world's data read: the events it no longer has close; one the simulation opened since
    /// the last read opens its window.
    fn update(&mut self, events: &[(i64, String, bool)]) {
        let ids: HashSet<i64> = events.iter().map(|e| e.0).collect();
        self.open.retain(|e| ids.contains(e));
        for (id, _, fired) in events {
            if self.seen.insert(*id) && self.started && *fired {
                self.open.push(*id);
            }
        }
        self.started = true;
    }
}

/// The world's data for these windows (render.windows.events_data's chunk), read where the galaxy
/// is read (the simulation's thread, or the save's world before it runs); "" if it fails.
pub fn extract(runtime: &Runtime, game_dir: &str) -> String {
    let code = format!("return require('render.windows.events_data').chunk({:?})", game_dir.replace('\\', "/"));
    runtime.lua.load(code).eval::<String>().unwrap_or_else(|e| {
        eprintln!("render.windows.events_data: {e}");
        String::new()
    })
}

/// Exports a font's advances and kerning to Lua (RENDER_FONT_METRICS[name]) for the texts these
/// windows wrap (render.windows.events `wrap`: the widths as [`Font::width`] measures).
fn export_metrics(lua: &mlua::Lua, name: &str, font: &Font) -> mlua::Result<()> {
    let all: Table = match lua.globals().get::<Option<Table>>("RENDER_FONT_METRICS")? {
        Some(t) => t,
        None => {
            let t = lua.create_table()?;
            lua.globals().set("RENDER_FONT_METRICS", t.clone())?;
            t
        }
    };
    if all.contains_key(name)? {
        return Ok(());
    }
    let m = lua.create_table()?;
    let adv = lua.create_table()?;
    for (c, g) in &font.glyphs {
        adv.set(*c as u32, g.xadvance)?;
    }
    let kern = lua.create_table()?;
    for ((a, b), k) in &font.kerning {
        kern.set(*a as u64 * 65536 + *b as u64, *k)?;
    }
    m.set("adv", adv)?;
    m.set("kern", kern)?;
    m.set("line", font.line_height)?;
    all.set(name, m)
}

/// The events of the data loaded (RENDER_EVENTS_DATA): (id, event, fired since the load).
fn event_list(lua: &mlua::Lua) -> mlua::Result<Vec<(i64, String, bool)>> {
    let mut out = Vec::new();
    if let Some(d) = lua.globals().get::<Option<Table>>("RENDER_EVENTS_DATA")? {
        if let Some(evs) = d.get::<Option<Table>>("events")? {
            for e in evs.sequence_values::<Table>() {
                let e = e?;
                out.push((e.get::<Option<i64>>("id")?.unwrap_or(-1), e.get::<Option<String>>("event")?.unwrap_or_default(), e.get::<Option<bool>>("fired")?.unwrap_or(false)));
            }
        }
    }
    Ok(out)
}

/// Loads the world's data chunk into the runtime when it changed.
fn load_data(ui: &mut EventsUi, runtime: &Runtime, chunk: &str) -> Result<(), String> {
    if ui.chunk == chunk && runtime.lua.globals().contains_key("RENDER_EVENTS_DATA").unwrap_or(false) {
        return Ok(());
    }
    let lua = &runtime.lua;
    let data: mlua::Value = if chunk.is_empty() { mlua::Value::Nil } else { lua.load(chunk).eval().map_err(|e| format!("events data: {e}"))? };
    lua.globals().set("RENDER_EVENTS_DATA", data).map_err(|e| e.to_string())?;
    ui.chunk = chunk.to_string();
    let list = event_list(lua).map_err(|e| e.to_string())?;
    ui.update(&list);
    Ok(())
}

/// These windows' items over the map, for a screen of `width` x `height`, in the map's runtime
/// (the GUI and the localisation installed).
pub fn items(ui: &mut EventsUi, runtime: &Runtime, game_dir: &str, fonts: &mut HashMap<String, Font>, chunk: &str, width: u32, height: u32) -> Result<Vec<GuiItem>, String> {
    load_data(ui, runtime, chunk)?;
    // the fonts the wrapped texts are measured in (the views' too: render.windows.situation)
    let probe: Vec<GuiItem> = ["cg_16b", "malgun_goth_24", "cg_16b_shadow"]
        .iter()
        .map(|f| GuiItem::Text { path: String::new(), font: f.to_string(), text: String::new(), spans: Vec::new(), x: 0.0, y: 0.0, w: 0.0, h: 0.0, format: String::new(), valign: String::new() })
        .collect();
    for p in &probe {
        let _ = gui::fonts(runtime, game_dir, std::slice::from_ref(p), fonts);
    }
    let lua = &runtime.lua;
    for (name, f) in fonts.iter() {
        export_metrics(lua, name, f).map_err(|e| e.to_string())?;
    }
    if ui.open.is_empty() && ui.popups.is_empty() {
        return Ok(Vec::new());
    }
    let read = || -> mlua::Result<Vec<GuiItem>> {
        let state = lua.create_table()?;
        state.set("open", lua.create_sequence_from(ui.open.iter().copied())?)?;
        let popups = lua.create_table()?;
        for p in &ui.popups {
            let t = lua.create_table()?;
            t.set("kind", p.kind.as_str())?;
            t.set("title", p.title.as_str())?;
            t.set("text", p.text.as_str())?;
            popups.push(t)?;
        }
        state.set("popups", popups)?;
        lua.globals().set("RENDER_EVENTS_STATE", state)?;
        let t: Table = lua
            .load(format!(
                "local items, report = require('render.windows.events').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_EVENTS_DATA, RENDER_EVENTS_STATE) return {{ items = items, report = report }}"
            ))
            .eval()?;
        gui::read_items(t.get("items")?)
    };
    read().map_err(|e| format!("render.windows.events: {e}"))
}

/// The `event` command (as the headless game's): `event` lists the open player events (`ID:NAME`),
/// `event ID` opens its window.
pub fn command(app: &mut App, arg: &str) -> Result<String, String> {
    let chunk = app.map.as_ref().ok_or("no map loaded")?.galaxy.events.clone();
    load_data(&mut app.events, &app.runtime, &chunk)?;
    let list = event_list(&app.runtime.lua).map_err(|e| e.to_string())?;
    let arg = arg.trim();
    if arg.is_empty() {
        let names: Vec<String> = list.iter().map(|(id, name, _)| format!(" {id}:{name}")).collect();
        return Ok(format!("event{}", names.concat()));
    }
    let id: i64 = arg.parse().map_err(|_| format!("event {arg}: an id"))?;
    let (_, name, _) = list.iter().find(|e| e.0 == id).ok_or(format!("event {id}: no such open player event"))?;
    let name = name.clone();
    app.events.act(&format!("event:open:{id}"));
    app.relayout();
    Ok(format!("event {id} {name} opened"))
}
