//! The diplomacy windows (docs/windows/diplomacy.md): Contacts (interface/galaxy_view.gui, the
//! left bar's contacts button), a country's diplomacy (diplomacy_view.gui), the galactic
//! community, a federation, a war. Which one is open and its run-time state (the tab, the
//! selected empire, the sort) live here; `lua/render/windows/diplomacy.lua` lays them out from
//! the world's part the galaxy carries (`Galaxy::diplomacy`, render.windows.diplomacy_data).
//!
//! Actions (a button's, App::act): `view:contacts` opens Contacts; `diplo:<what>[:<arg>]`:
//! `close`, `select:ID` (an empire's row), `country:ID` (its diplomacy), `tab:NAME`,
//! `sort:NAME`, `community`, `federation:ID`, `war:ID`, `none` (a window's background: takes
//! the click).

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::galaxy::Galaxy;
use crate::gui::{self, GuiItem};

/// The window open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Open {
    Contacts,
    Country(u32),
    Community,
    Federation(u32),
    War(u32),
}

impl Open {
    fn name(&self) -> (&'static str, i64) {
        match self {
            Open::Contacts => ("contacts", -1),
            Open::Country(id) => ("country", *id as i64),
            Open::Community => ("community", -1),
            Open::Federation(id) => ("federation", *id as i64),
            Open::War(id) => ("war", *id as i64),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct State {
    pub open: Option<Open>,
    /// Contacts: the empire selected in the list (its profile on the left), the tab, the sort
    pub selected: Option<u32>,
    pub tab: Option<String>,
    pub sort: Option<String>,
    /// Contacts' filters the player has unchecked (CGalaxyView's checkboxes: all checked at Setup)
    pub filters_off: std::collections::BTreeSet<String>,
    /// a country's diplomacy: its actions (render.windows.diplomacy_actions.list, a Lua chunk) for
    /// that country, the action picked (ShowActionView), the text after a proposal
    pub actions: Option<(u32, String)>,
    pub action: Option<String>,
    pub message: Option<String>,
}

type Snap = (Option<Open>, Option<u32>, Option<String>, Option<String>, std::collections::BTreeSet<String>, Option<String>, Option<String>);

impl State {
    fn snap(&self) -> Snap {
        (self.open.clone(), self.selected, self.tab.clone(), self.sort.clone(), self.filters_off.clone(), self.action.clone(), self.message.clone())
    }

    /// Does a `view:contacts` or `diplo:...` action on the windows' state; whether anything
    /// changed (the world's: [`act`]).
    pub fn act(&mut self, action: &str) -> Result<bool, String> {
        let before = self.snap();
        if let Some(rest) = action.strip_prefix("diplo:") {
            // the action view: an action picked from the list, cancelled (CDiplomacyView::
            // SelectAction, CancelAction)
            if let Some(k) = rest.strip_prefix("action:") {
                self.action = Some(k.to_string());
                self.message = None;
                return Ok(before != self.snap());
            }
            if rest == "action_cancel" {
                self.action = None;
                return Ok(before != self.snap());
            }
            // Escape: the picked action's view first (its Cancel), then the window
            if rest == "escape" {
                if self.action.is_some() {
                    self.action = None;
                } else {
                    self.open = None;
                }
                return Ok(before != self.snap());
            }
            // Contacts' filters: a checkbox toggled
            if let Some(f) = rest.strip_prefix("filter:") {
                if !self.filters_off.remove(f) {
                    self.filters_off.insert(f.to_string());
                }
                return Ok(true);
            }
        }
        let mut parts = action.splitn(3, ':');
        let (verb, what, arg) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next());
        let id = |s: Option<&str>| -> Result<u32, String> { s.and_then(|v| v.parse().ok()).ok_or(format!("bad action {action}")) };
        match (verb, what) {
            ("view", "contacts") => {
                // the left bar's button toggles the view (CGalaxyView::Show / Hide)
                if self.open == Some(Open::Contacts) {
                    self.open = None;
                } else {
                    self.open = Some(Open::Contacts);
                    self.tab = None;
                }
            }
            ("diplo", "close") => self.open = None,
            ("diplo", "none") => {}
            ("diplo", "select") => self.selected = Some(id(arg)?),
            ("diplo", "country") => {
                // (the tab is remembered between openings: Show uses the stored one)
                self.open = Some(Open::Country(id(arg)?));
                self.action = None;
                self.message = None;
            }
            ("diplo", "espionage") => {
                // the Espionage button: the window on its espionage tab
                self.open = Some(Open::Country(id(arg)?));
                self.tab = Some("espionage".into());
                self.action = None;
            }
            ("diplo", "contacts") => {
                self.open = Some(Open::Contacts);
                self.tab = None;
            }
            ("diplo", "tab") => self.tab = arg.map(String::from),
            ("diplo", "sort") => self.sort = arg.map(String::from),
            ("diplo", "community") => {
                self.open = Some(Open::Community);
                self.tab = None;
            }
            ("diplo", "federation") => {
                self.open = Some(Open::Federation(id(arg)?));
                self.tab = None;
            }
            ("diplo", "war") => {
                self.open = Some(Open::War(id(arg)?));
                self.tab = None;
            }
            _ => return Err(format!("unknown diplomacy action {action}")),
        }
        Ok(before != self.snap())
    }

    /// The open window laid out for a screen of `width` x `height` (none: nothing), in the front
    /// end's runtime, and the flags among its items: (item index, country id).
    pub fn items(&self, runtime: &Runtime, width: u32, height: u32, galaxy: &Galaxy, observe: bool) -> Result<(Vec<GuiItem>, Vec<(usize, u32)>), String> {
        let Some(open) = &self.open else { return Ok((Vec::new(), Vec::new())) };
        let read = || -> mlua::Result<(Vec<GuiItem>, Vec<(usize, u32)>)> {
            let lua = &runtime.lua;
            let (window, id) = open.name();
            let s = lua.create_table()?;
            s.set("window", window)?;
            s.set("id", id)?;
            s.set("observe", observe)?;
            if let Some(sel) = self.selected {
                s.set("selected", sel)?;
            }
            if let Some(t) = &self.tab {
                s.set("tab", t.as_str())?;
            }
            if let Some(t) = &self.sort {
                s.set("sort", t.as_str())?;
            }
            let off = lua.create_table()?;
            for f in &self.filters_off {
                off.set(f.as_str(), true)?;
            }
            s.set("filters_off", off)?;
            if let Some(a) = &self.action {
                s.set("action", a.as_str())?;
            }
            if let Some(m) = &self.message {
                s.set("message", m.as_str())?;
            }
            if let (Some((cid, chunk)), Open::Country(id)) = (&self.actions, open) {
                if cid == id {
                    s.set("actions", chunk.as_str())?;
                }
            }
            lua.globals().set("RENDER_DIPLO_STATE", s)?;
            lua.globals().set("RENDER_DIPLO_DATA", galaxy.diplomacy.as_str())?;
            let t: Table = lua
                .load(format!(
                    "local items, report, flags = require('render.windows.diplomacy').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_DIPLO_STATE, RENDER_DIPLO_DATA) return {{ items = items, report = report, flags = flags }}"
                ))
                .eval()?;
            let items = gui::read_items(t.get("items")?)?;
            // the flags: element path -> country id
            let mut by_path = std::collections::HashMap::new();
            if let Some(f) = t.get::<Option<Table>>("flags")? {
                for p in f.pairs::<String, u32>() {
                    let (k, v) = p?;
                    by_path.insert(k, v);
                }
            }
            let flags = items
                .iter()
                .enumerate()
                .filter_map(|(i, it)| match it {
                    GuiItem::Sprite { path, .. } => by_path.get(path).map(|c| (i, *c)),
                    _ => None,
                })
                .collect();
            Ok((items, flags))
        };
        read().map_err(|e| format!("render.windows.diplomacy: {e}"))
    }
}

/// Contacts' command in the simulation (render-buttons-1's views.rs: render.windows.contacts's
/// `command(VERB, GAME_DIR, ...)` run between days, the simulation started if it is not running,
/// then a snapshot published and taken): its string.
fn world_command(app: &mut crate::app::App, args: &[&str]) -> Result<String, String> {
    let gd = app.game_dir.replace('\\', "/");
    let mut all = vec![args[0], gd.as_str()];
    all.extend_from_slice(&args[1..]);
    let m = app.map.as_mut().ok_or("no map loaded")?;
    crate::views::command(m, "contacts", &all)
}

/// The player's country id (none: an observer).
fn player(app: &crate::app::App) -> Option<u32> {
    app.map.as_ref().map(|m| m.galaxy.player).filter(|_| !app.map.as_ref().is_some_and(|m| m.observe))
}

/// The country's actions listed again (the window opened, an action done).
fn list_actions(app: &mut crate::app::App, id: u32) {
    let Some(me) = player(app) else { return };
    let (me, id_s) = (me.to_string(), id.to_string());
    match world_command(app, &["list", &me, &id_s]) {
        Ok(chunk) => app.diplomacy.actions = Some((id, chunk)),
        Err(e) => {
            app.log.push(format!("diplomacy: the actions of {id}: {e}"));
            app.diplomacy.actions = None;
        }
    }
}

/// A diplomacy window's action (App::act's `view:contacts` and `diplo:` arm): the windows' state
/// (State::act), and what changes the world, done where the world is:
/// - `diplo:zoom:ID` (Contacts' zoom_to_capital_button, the diplomacy view's to_to_home_world:
///   CGalaxyViewEmpireProfile::OnEmpireZoomToCapital): the camera to the capital's system;
/// - `diplo:action_confirm` (the action view's confirm_button): the picked action proposed to the
///   country (render.windows.diplomacy_actions.apply), the list made again.
pub fn act(app: &mut crate::app::App, a: &str) -> Result<(), String> {
    if let Some(id) = a.strip_prefix("diplo:zoom:") {
        let id: u32 = id.parse().map_err(|_| format!("bad action {a}"))?;
        let code = format!("local d = require('render.windows.diplomacy_data').load(RENDER_DIPLO_DATA) local c = d and d.countries[{id}] return c and c.capital_system or -1");
        let m = app.map.as_ref().ok_or("no map loaded")?;
        app.runtime.lua.globals().set("RENDER_DIPLO_DATA", m.galaxy.diplomacy.as_str()).map_err(|e| e.to_string())?;
        let sys: i64 = app.runtime.lua.load(code).eval().map_err(|e| format!("diplomacy: {e}"))?;
        let i = app.map.as_ref().and_then(|m| m.galaxy.systems.iter().position(|s| s.id as i64 == sys));
        if let Some(i) = i {
            app.diplomacy.open = None;
            app.relayout();
            app.focus(crate::scene::Pickable::System(i))?;
        }
        return Ok(());
    }
    if a == "diplo:action_confirm" {
        let (Some(Open::Country(id)), Some(key), Some(me)) = (app.diplomacy.open.clone(), app.diplomacy.action.clone(), player(app)) else {
            return Ok(());
        };
        let (me, id_s) = (me.to_string(), id.to_string());
        let out = world_command(app, &["propose", &key, &me, &id_s])?;
        let note: Option<String> = app
            .runtime
            .lua
            .load(format!("local t = (loadstring or load)({out:?})() return t.done and '' or (t.note or 'not done')"))
            .eval()
            .map_err(|e| format!("diplomacy: {e}"))?;
        app.log.push(format!("diplomacy: {key} proposed to {id}: {}", note.clone().filter(|n| !n.is_empty()).unwrap_or_else(|| "done".into())));
        app.diplomacy.action = None;
        app.diplomacy.message = note.filter(|n| !n.is_empty());
        list_actions(app, id);
        app.relayout();
        return Ok(());
    }
    let was = app.diplomacy.open.clone();
    if app.diplomacy.act(a)? {
        // Contacts is a left bar view: one view at a time (ToggleTopBarView)
        if app.diplomacy.open == Some(Open::Contacts) && was != Some(Open::Contacts) {
            app.close_view();
            app.set_designer(Default::default());
        }
        // a country's window opened: its actions listed
        if let Some(Open::Country(id)) = app.diplomacy.open.clone() {
            if was != Some(Open::Country(id)) {
                list_actions(app, id);
            }
        }
        app.relayout();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actions_open_and_close() {
        let mut s = State::default();
        // the left bar's button toggles Contacts
        assert!(s.act("view:contacts").unwrap());
        assert_eq!(s.open, Some(Open::Contacts));
        assert!(s.act("diplo:select:16").unwrap());
        assert_eq!(s.selected, Some(16));
        assert!(!s.act("diplo:none").unwrap());
        assert!(s.act("diplo:country:16").unwrap());
        assert_eq!(s.open, Some(Open::Country(16)));
        assert!(s.act("diplo:tab:espionage").unwrap());
        // a new window starts on its first tab
        assert!(s.act("diplo:community").unwrap());
        assert_eq!((s.open.clone(), s.tab.clone()), (Some(Open::Community), None));
        assert!(s.act("diplo:close").unwrap());
        assert_eq!(s.open, None);
        assert!(s.act("view:contacts").unwrap());
        assert!(s.act("view:contacts").unwrap());
        assert_eq!(s.open, None);
        assert!(s.act("diplo:country:x").is_err());
        assert!(s.act("diplo:what").is_err());
    }
}
