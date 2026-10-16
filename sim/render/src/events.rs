//! The event windows, the popups, the Situation Log and the Discoveries view (docs/windows/events.md):
//! what is open (the windows' state, the clicks on them, the `event` command), laid out in Lua
//! (`lua/render/windows/events.lua`, `situations.lua`, `discoveries.lua`) from the world's data
//! (`lua/render/windows/events_data.lua`, carried in [`crate::galaxy::Galaxy::events`]).
//!
//! As the game: an event the simulation opens for the player shows its window at once (the game's
//! message system opens it, CMessageSystem::Update -> CInGameIdler::AddEventWindow); the events
//! open in a loaded save do not (the game's frame after a load shows none: the alert or the
//! Situation Log leads to them), `event ID` opens one as the headless game's `event ID` does.
//! Choosing an option runs it where the world is (the simulation keeps a human player's event
//! open, simscript.events `defer`; render.windows.events_data `answer` runs the option's effects
//! and `after`, the save's own open events too) and closes the window; unanswered, an event times
//! out with its default option after EVENT_AUTOSELECT_MONTHS.

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
    /// the first contact view open (a first contact's id: "Show First Contact")
    pub first_contact: Option<i64>,
    /// the data chunk loaded into the runtime last (to load it again only when it changed)
    chunk: String,
    /// the message settings open (an event window's settings button): the message type they are
    /// filtered to
    pub msg_type: Option<String>,
    /// the message settings changed (message type -> notification, toast, popup, pause -> on),
    /// over common/message_types' defaults (the renderer's; the game keeps them in its settings)
    pub msg: HashMap<String, HashMap<String, bool>>,
    /// the settings when the window opened (Cancel and Discard Changes go back to them)
    msg_before: HashMap<String, HashMap<String, bool>>,
    /// an event fired whose message type auto-pauses: the game to pause (App takes it)
    want_pause: bool,
    /// the tracked entries' systems of the data loaded, and whether they changed (the map's
    /// scene to build again: App takes it)
    trackers: Vec<i64>,
    trackers_changed: bool,
}

/// The actions these windows' buttons carry: the event windows' (`event:`), the popups'
/// (`popup:`), the first contact view's (`fc:`), and the Situation Log's that move the camera
/// (`sitlog:`). (Discoveries' artifact actions are `cmd:discoveries:artifact:KEY`, views.rs.)
pub fn handles(action: &str) -> bool {
    ["event:", "popup:", "fc:", "sitlog:", "msgset:"].iter().any(|p| action.starts_with(p))
}

/// A command of a windows module run in the simulation between days (views.rs' frame: the
/// simulation started if it is not, a snapshot published and taken after): what it did.
fn world_do(app: &mut App, module: &str, args: &[&str]) -> Result<String, String> {
    let m = app.map.as_mut().ok_or("no map loaded")?;
    crate::views::command(m, module, args)
}

/// The system the camera goes to (NGuiUtil::FocusOnScope: the game enters it, `state` reads
/// `system ID` after a click on the event window's focus button).
fn focus_system(app: &mut App, system: i64) -> Result<(), String> {
    let i = app.map.as_ref().and_then(|m| m.galaxy.systems.iter().position(|s| s.id as i64 == system)).ok_or(format!("no system {system}"))?;
    app.focus(crate::scene::Pickable::System(i))
}

/// The galaxy over a system (the Situation Log's goto: the game shows the galaxy, the camera's
/// target at the system, at the distance it leaves a system with: `state` after the click reads
/// view galaxy, target 2 x the system's map place, distance 198.6, pitch 57.5).
fn galaxy_focus(app: &mut App, system: i64) -> Result<(), String> {
    let (x, y) = app.map.as_ref().and_then(|m| m.galaxy.systems.iter().find(|s| s.id as i64 == system).map(|s| (s.x, s.y))).ok_or(format!("no system {system}"))?;
    app.show_galaxy();
    // the camera's goal: with a smooth camera (the window) show_galaxy starts the camera at
    // distance 0.001 and flies it out to the goal
    if let Some(mut c) = app.camera_goal.or(app.camera) {
        c.target = crate::math::V3(x, 0.0, y);
        app.set_camera(c);
    }
    Ok(())
}

/// A number of the windows' data (RENDER_EVENTS_DATA): `expr` evaluated with `d` the data.
fn data_number(app: &App, expr: &str) -> Option<i64> {
    app.runtime.lua.load(format!("local d = RENDER_EVENTS_DATA or {{}} return {expr}")).eval::<Option<i64>>().ok().flatten()
}

/// A key released over the map: the action of these windows' .gui shortcuts, the top window's
/// first: a popup's RETURN (AgreeButton); the top event window's first option (Setup gives it
/// RETURN) and its focus button's Q; the Situation Log's and Discoveries' tabs (Z, X).
pub fn key(app: &App, key: &str) -> Option<String> {
    let ui = &app.events;
    if !ui.popups.is_empty() {
        return (key == "return").then(|| format!("popup:agree:{}", ui.popups.len()));
    }
    if ui.first_contact.is_none() {
        if let Some(&id) = ui.open.last() {
            return match key {
                "return" => {
                    let k = data_number(app, &format!("(function() for _, e in ipairs(d.events or {{}}) do if e.id == {id} then local o = (e.options or {{}})[1] return o and (o.index or 1) or 1 end end end)()"))?;
                    Some(format!("event:option:{id}:{k}"))
                }
                "q" => Some(format!("event:focus:{id}")),
                _ => None,
            };
        }
    }
    match (app.open_view.as_deref(), key) {
        (Some("situation"), "z") => Some("view_set:tab=".into()),
        (Some("situation"), "x") => Some("view_set:tab=anomalies".into()),
        (Some("discoveries"), "z") => Some("view_set:tab=relics".into()),
        _ => None,
    }
}

/// Escape (the controls' Back) on these windows, the top one first: a popup's DeclineButton
/// (ESCAPE: popup.gui's invisible button), the first contact view's close (ESCAPE). The event window's
/// close has no shortcut. Whether it closed something.
pub fn escape(app: &mut App) -> bool {
    let a = if app.events.msg_type.is_some() {
        // the settings window's close button: ESCAPE
        "msgset:cancel".to_string()
    } else if !app.events.popups.is_empty() {
        format!("popup:decline:{}", app.events.popups.len())
    } else if app.events.first_contact.is_some() {
        "fc:close".to_string()
    } else {
        return false;
    };
    app.events.act(&a);
    app.relayout();
    true
}

/// A click on one of these windows' buttons (App::act's arm for [`handles`]).
pub fn app_act(app: &mut App, action: &str) -> Result<(), String> {
    let parts: Vec<&str> = action.split(':').collect();
    let num = |k: usize| parts.get(k).and_then(|v| v.parse::<i64>().ok());
    match parts.as_slice() {
        // an option: CEventWindow::PostEventOptionSelection posts the option's command, its effects
        // run (COpenPlayerEvent::OnOptionSelected) and the event is no longer open
        ["event", "option", ..] | ["fc", "option", ..] => {
            if let (Some(id), Some(k)) = (num(2), num(3)) {
                let r = world_do(app, "events_data", &["answer", &id.to_string(), &k.to_string()])?;
                app.log.push(format!("event {id} option {k}: {r}"));
            }
        }
        // the focus button (CEventWindow::FocusOn): the event's location
        ["event", "focus", ..] => {
            if let Some(id) = num(2) {
                let sys = data_number(app, &format!("(function() for _, e in ipairs(d.events or {{}}) do if e.id == {id} then return e.location_system end end end)()"));
                if let Some(s) = sys {
                    focus_system(app, s)?;
                }
            }
        }
        // the Situation Log's and the first contact view's goto: the galaxy over the system
        ["sitlog", "focus", ..] | ["fc", "focus", ..] => {
            if let Some(s) = num(2) {
                galaxy_focus(app, s)?;
            }
        }
        // the first contact view replaces the top bar view (the game's Situation Log closes when
        // "Show First Contact" opens it)
        ["fc", "open", ..] => app.close_view(),
        _ => {}
    }
    app.events.act(action);
    app.relayout();
    Ok(())
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
            // the first contact view (CFirstContactView): opened, closed; an option chosen closes it
            // (the simulation has answered the event) [I]
            ["fc", "open", ..] => self.first_contact = id(2),
            ["fc", "close"] => self.first_contact = None,
            ["fc", "option", ..] => {
                self.first_contact = None;
                if let Some(id) = id(2) {
                    self.open.retain(|e| *e != id);
                }
            }
            // the message settings: opened on an event's type, closed (Back, Apply, the close
            // button), reset (their defaults), a checkbox set
            ["event", "settings", t] => {
                self.msg_type = Some(t.to_string());
                self.msg_before = self.msg.clone();
            }
            // Apply & Close keeps them; Cancel (and Escape) puts them back and closes; Discard
            // Changes puts them back; Reset Default clears them
            ["msgset", "close"] => self.msg_type = None,
            ["msgset", "cancel"] => {
                self.msg = self.msg_before.clone();
                self.msg_type = None;
            }
            ["msgset", "discard"] => self.msg = self.msg_before.clone(),
            ["msgset", "reset"] => self.msg.clear(),
            ["msgset", "set", t, k, v] => {
                self.msg.entry(t.to_string()).or_default().insert(k.to_string(), *v == "1");
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
    /// the last read opens its window when its message type's popup is on, and pauses the game
    /// when its auto-pause is (`decide`: the type's popup and pause).
    fn update(&mut self, events: &[(i64, String, bool, String)], decide: impl Fn(&str) -> (bool, bool)) {
        let ids: HashSet<i64> = events.iter().map(|e| e.0).collect();
        self.open.retain(|e| ids.contains(e));
        for (id, _, fired, ty) in events {
            if self.seen.insert(*id) && self.started && *fired {
                let (popup, pause) = decide(ty);
                if popup {
                    self.open.push(*id);
                }
                self.want_pause |= pause;
            }
        }
        self.started = true;
    }

    /// Whether the trackers changed since the last call (the galaxy's scene to build again).
    pub fn take_trackers_changed(&mut self) -> bool {
        std::mem::take(&mut self.trackers_changed)
    }

    /// Whether an event fired that pauses the game (once).
    pub fn take_pause(&mut self) -> bool {
        std::mem::take(&mut self.want_pause)
    }
}

/// The trackers of the Situation Log's tracked entries on the galaxy (CPingMapManager: a
/// CPingMapInstance per tracked entry, gfx/pingmap's first_contact_tracker, situation_tracker ...:
/// `galaxy_entity = project_tracker_galaxy_effect_entity`, whose particle is
/// project_tracker_galaxy_effect_particle, an orange hexagon and its growing halo), at each
/// tracked entry's system, the entity's scale 1 in the game's galaxy world (2 x the map's units:
/// half of it here) [I]. The systems: the windows' data (RENDER_EVENTS_DATA.trackers). Not in a
/// system's view (its system_entity is not placed) [I].
pub fn draw_trackers(scene: &mut crate::scene::Scene, ui_runtime: &Runtime, map: &mut crate::Map, view: crate::app::MapView, game_dir: &str) {
    if view != crate::app::MapView::Galaxy {
        return;
    }
    let systems = tracker_systems(&ui_runtime.lua);
    if systems.is_empty() {
        return;
    }
    let effect = match map.particles.effect(&map.runtime, game_dir, "project_tracker_galaxy_effect_particle") {
        Ok(e) => e,
        Err(e) => {
            eprintln!("events: the tracker's particle: {e}");
            return;
        }
    };
    let cache = map.cache.clone();
    let mut cache = cache.borrow_mut();
    for sys in systems {
        let Some(s) = map.galaxy.systems.iter().find(|s| s.id as i64 == sys) else { continue };
        let m = crate::math::M4::translation(crate::math::V3(s.x, 0.0, s.y)).mul(&crate::math::M4::scaling(0.5));
        for (layer, blend, t, q) in crate::particles::billboards(&effect, &m, sys as u32, &mut map.textures, &mut cache, game_dir) {
            crate::scene::push(&mut scene.batches, layer, blend, t, q);
        }
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

/// The events of the data loaded (RENDER_EVENTS_DATA): (id, event, fired since the load, its
/// message type).
fn event_list(lua: &mlua::Lua) -> mlua::Result<Vec<(i64, String, bool, String)>> {
    let mut out = Vec::new();
    if let Some(d) = lua.globals().get::<Option<Table>>("RENDER_EVENTS_DATA")? {
        if let Some(evs) = d.get::<Option<Table>>("events")? {
            for e in evs.sequence_values::<Table>() {
                let e = e?;
                out.push((
                    e.get::<Option<i64>>("id")?.unwrap_or(-1),
                    e.get::<Option<String>>("event")?.unwrap_or_default(),
                    e.get::<Option<bool>>("fired")?.unwrap_or(false),
                    e.get::<Option<String>>("message_type")?.unwrap_or_else(|| "EVENT_MESSAGE_TYPE".into()),
                ));
            }
        }
    }
    Ok(out)
}

/// The tracked entries' systems of the data loaded (RENDER_EVENTS_DATA.trackers).
fn tracker_systems(lua: &mlua::Lua) -> Vec<i64> {
    lua.load("local out = {} for _, t in ipairs((RENDER_EVENTS_DATA or {}).trackers or {}) do out[#out + 1] = t.system end return out")
        .eval::<Vec<i64>>()
        .unwrap_or_default()
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
    let trackers = tracker_systems(lua);
    if trackers != ui.trackers {
        ui.trackers = trackers;
        ui.trackers_changed = true;
    }
    let list = event_list(lua).map_err(|e| e.to_string())?;
    let overrides = msg_table(lua, &ui.msg).map_err(|e| e.to_string())?;
    let decide = |ty: &str| -> (bool, bool) {
        let f = || -> mlua::Result<(bool, bool)> {
            let m: Table = lua.load("return require('render.windows.message_settings')").eval()?;
            let f: mlua::Function = m.get("effective")?;
            f.call((lua.globals().get::<String>("RENDER_GAME_DIR")?, ty, overrides.clone()))
        };
        f().unwrap_or((true, true))
    };
    ui.update(&list, decide);
    Ok(())
}

/// The message settings changed, as a Lua table (type -> { notification = .. popup = .. }).
fn msg_table(lua: &mlua::Lua, msg: &HashMap<String, HashMap<String, bool>>) -> mlua::Result<Table> {
    let t = lua.create_table()?;
    for (ty, m) in msg {
        let s = lua.create_table()?;
        for (k, v) in m {
            s.set(k.as_str(), *v)?;
        }
        t.set(ty.as_str(), s)?;
    }
    Ok(t)
}

/// These windows' items over the map, for a screen of `width` x `height`, in the map's runtime
/// (the GUI and the localisation installed).
pub fn items(ui: &mut EventsUi, runtime: &Runtime, game_dir: &str, fonts: &mut HashMap<String, Font>, chunk: &str, width: u32, height: u32) -> Result<Vec<GuiItem>, String> {
    load_data(ui, runtime, chunk)?;
    // the fonts the wrapped texts are measured in (the views' too: render.windows.situation)
    let probe: Vec<GuiItem> = ["cg_16b", "malgun_goth_24", "cg_16b_shadow"]
        .iter()
        .map(|f| GuiItem::Text { path: String::new(), font: f.to_string(), text: String::new(), spans: Vec::new(), x: 0.0, y: 0.0, w: 0.0, h: 0.0, format: String::new(), valign: String::new(), fixed: true })
        .collect();
    for p in &probe {
        let _ = gui::fonts(runtime, game_dir, std::slice::from_ref(p), fonts);
    }
    let lua = &runtime.lua;
    for (name, f) in fonts.iter() {
        export_metrics(lua, name, f).map_err(|e| e.to_string())?;
    }
    if ui.open.is_empty() && ui.popups.is_empty() && ui.first_contact.is_none() && ui.msg_type.is_none() {
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
        if let Some(fc) = ui.first_contact {
            state.set("first_contact", fc)?;
        }
        if let Some(t) = &ui.msg_type {
            state.set("message_type", t.as_str())?;
            state.set("message_settings", msg_table(lua, &ui.msg)?)?;
        }
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
    // `event fc ID`: the first contact view of the first contact ID (the Findings' "Show First
    // Contact"), `event fc` closes it
    if let Some(rest) = arg.strip_prefix("fc") {
        let rest = rest.trim();
        app.events.act(&if rest.is_empty() { "fc:close".to_string() } else { format!("fc:open:{rest}") });
        app.relayout();
        return Ok(format!("event fc {rest}"));
    }
    // `event fire NAME`: the event fired for the player in the simulation (the game's console
    // `event NAME`); `event influence`: the stockpile's influence (to check an option's cost)
    if let Some(name) = arg.strip_prefix("fire ") {
        return world_do(app, "events_data", &["fire", name.trim()]).map(|r| format!("event {r}"));
    }
    if arg == "influence" {
        return world_do(app, "events_data", &["influence"]).map(|r| format!("event {r}"));
    }
    // the simulation's commands of these windows, for the checks (events_commands.lua):
    // `event effect TEXT` (the game's console `effect`), `event start_situation TYPE`, `event stock
    // RESOURCE`, `event approach SITUATION KEY`, `event relic KEY`
    let (verb, rest) = arg.split_once(' ').unwrap_or((arg, ""));
    if matches!(verb, "effect" | "start_situation" | "stock" | "approach" | "relic" | "modifiers") {
        let args: Vec<&str> = if verb == "effect" { vec![verb, rest.trim()] } else { std::iter::once(verb).chain(rest.split_whitespace()).collect() };
        return world_do(app, "events_data", &args).map(|r| format!("event {r}"));
    }
    if arg.is_empty() {
        let names: Vec<String> = list.iter().map(|(id, name, _, _)| format!(" {id}:{name}")).collect();
        return Ok(format!("event{}", names.concat()));
    }
    let id: i64 = arg.parse().map_err(|_| format!("event {arg}: an id"))?;
    let (_, name, _, _) = list.iter().find(|e| e.0 == id).ok_or(format!("event {id}: no such open player event"))?;
    let name = name.clone();
    app.events.act(&format!("event:open:{id}"));
    app.relayout();
    Ok(format!("event {id} {name} opened"))
}
