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
}

impl State {
    /// Does a `view:contacts` or `diplo:...` action; whether anything changed.
    pub fn act(&mut self, action: &str) -> Result<bool, String> {
        let before = (self.open.clone(), self.selected, self.tab.clone(), self.sort.clone());
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
                self.open = Some(Open::Country(id(arg)?));
                self.tab = None;
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
        Ok(before != (self.open.clone(), self.selected, self.tab.clone(), self.sort.clone()))
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
