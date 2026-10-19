//! The diplomacy windows (docs/windows/diplomacy.md): Contacts (interface/galaxy_view.gui, the
//! left bar's contacts button), a country's diplomacy (diplomacy_view.gui), the galactic
//! community, a federation, a war. Which one is open and its run-time state (the tab, the
//! selected empire, the sort) live here; `lua/render/windows/diplomacy.lua` lays them out from
//! the world's part the galaxy carries (`Galaxy::diplomacy`, render.windows.diplomacy_data).
//!
//! Actions (a button's, App::act): `view:contacts` opens Contacts; `diplo:<what>[:<arg>]`:
//! `close`, `select:ID` (an empire's row), `country:ID` (its diplomacy), `tab:NAME`,
//! `sort:NAME`, `community`, `federation:ID`, `war:ID`, `peace:OPTION` (a war's peace option
//! selected), `peace_send`, `none` (a window's background: takes the click).

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
    /// that country, the action picked (ShowActionView; a war's peace option), the text after a
    /// proposal
    pub actions: Option<(u32, String)>,
    pub action: Option<String>,
    pub message: Option<String>,
    /// a leave awaiting the game's yes/no popup (CPopupMessageYesNo): `leave_federation` or
    /// `leave_community`
    pub confirm: Option<String>,
    /// the windows' lists scrolled (rows skipped, by list name), and their places and rows as last
    /// laid out (name, rect, rows, rows shown)
    pub scroll: std::collections::BTreeMap<String, usize>,
    pub lists: Vec<(String, [f32; 4], usize, usize)>,
}

type Snap = (Option<Open>, Option<u32>, Option<String>, Option<String>, std::collections::BTreeSet<String>, Option<String>, Option<String>, Option<String>);

impl State {
    fn snap(&self) -> Snap {
        (self.open.clone(), self.selected, self.tab.clone(), self.sort.clone(), self.filters_off.clone(), self.action.clone(), self.message.clone(), self.confirm.clone())
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
            // the popup's No (DeclineButton): the leave not done
            if rest == "confirm_no" {
                self.confirm = None;
                return Ok(before != self.snap());
            }
            if rest == "escape" {
                if self.confirm.is_some() {
                    self.confirm = None;
                } else if self.action.is_some() {
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
                self.action = None;
                self.message = None;
            }
            // the war overview's peace options: a click selects one, again unselects it
            // (OnClickOfferPeaceOption); kept in `action`
            ("diplo", "peace") => {
                let o = arg.map(String::from);
                self.action = if self.action == o { None } else { o };
            }
            _ => return Err(format!("unknown diplomacy action {action}")),
        }
        // another window: no popup left over
        if self.open != before.0 {
            self.confirm = None;
        }
        Ok(before != self.snap())
    }

    /// The open window laid out for a screen of `width` x `height` (none: nothing), in the front
    /// end's runtime, and the flags among its items: (item index, country id).
    pub fn items(&mut self, runtime: &Runtime, width: u32, height: u32, galaxy: &Galaxy, observe: bool) -> Result<(Vec<GuiItem>, Vec<(usize, u32)>), String> {
        // (no window open: the entry points only, the federation and community buttons and the
        // war badges, as window "none")
        let open = self.open.clone();
        type Lists = Vec<(String, [f32; 4], usize, usize)>;
        let read = || -> mlua::Result<(Vec<GuiItem>, Vec<(usize, u32)>, Lists)> {
            let lua = &runtime.lua;
            let (window, id) = open.as_ref().map(Open::name).unwrap_or(("none", -1));
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
            if let Some(c) = &self.confirm {
                s.set("confirm", c.as_str())?;
            }
            if let (Some((cid, chunk)), Some(Open::Country(id))) = (&self.actions, &open) {
                if cid == id {
                    s.set("actions", chunk.as_str())?;
                }
            }
            let sc = lua.create_table()?;
            for (k, v) in &self.scroll {
                sc.set(k.as_str(), *v)?;
            }
            s.set("scroll", sc)?;
            lua.globals().set("RENDER_DIPLO_STATE", s)?;
            lua.globals().set("RENDER_DIPLO_DATA", galaxy.diplomacy.as_str())?;
            let t: Table = lua
                .load(format!(
                    "local items, report, flags, lists = require('render.windows.diplomacy').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_DIPLO_STATE, RENDER_DIPLO_DATA) return {{ items = items, report = report, flags = flags, lists = lists }}"
                ))
                .eval()?;
            // the lists laid out: { name = { x, y, w, h, rows, shown } }
            let mut lists = Vec::new();
            if let Some(l) = t.get::<Option<Table>>("lists")? {
                for p in l.pairs::<String, Table>() {
                    let (k, v) = p?;
                    lists.push((k, [v.get(1)?, v.get(2)?, v.get(3)?, v.get(4)?], v.get::<usize>(5)?, v.get::<usize>(6)?));
                }
            }
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
            Ok((items, flags, lists))
        };
        let (items, flags, lists) = read().map_err(|e| format!("render.windows.diplomacy: {e}"))?;
        self.lists = lists;
        Ok((items, flags))
    }
}

/// The wheel over a diplomacy window's list (Contacts' empires, a country's actions): a row a
/// notch (> 0 up), within the rows it has; whether it took the wheel.
pub fn wheel(app: &mut crate::app::App, notches: f32, at: Option<(f32, f32)>) -> bool {
    let Some((x, y)) = at else { return false };
    let hit = app.diplomacy.lists.iter().find(|(_, r, _, _)| x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3]).cloned();
    let Some((name, _, rows, shown)) = hit else { return false };
    let max = rows.saturating_sub(shown);
    let cur = app.diplomacy.scroll.get(&name).copied().unwrap_or(0);
    let step = notches.round() as i64;
    let next = (cur as i64 - step).clamp(0, max as i64) as usize;
    if next != cur {
        app.diplomacy.scroll.insert(name, next);
        app.relayout();
    }
    true
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
///   country (render.windows.diplomacy_actions.apply), the list made again;
/// - `diplo:peace_send` (the war overview's send): the selected peace offered
///   (render.windows.diplomacy_peace.apply), the window closed;
/// - `diplo:member:leave_federation|join_community|leave_community` (the federation view's leave
///   button, the community view's join_leave_button): render.windows.diplomacy_membership.
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
    if let Some(what) = a.strip_prefix("diplo:inspect:") {
        // an object of the world as the save writes it, to the log (the tests' comparisons with
        // the game's saves): `diplo:inspect:KIND:ID`
        let (kind, id) = what.split_once(':').ok_or(format!("bad action {a}"))?;
        let out = world_command(app, &["inspect", kind, id])?;
        let note: String = app
            .runtime
            .lua
            .load(format!("local t = (loadstring or load)({out:?})() return tostring(t.note or '')"))
            .eval()
            .map_err(|e| format!("diplomacy: {e}"))?;
        app.log.push(format!("inspect {kind} {id}: {}", note.split_whitespace().collect::<Vec<_>>().join(" ")));
        return Ok(());
    }
    // the popup's Yes (AgreeButton): the leave it asked about done
    let confirmed = if a == "diplo:confirm_yes" { app.diplomacy.confirm.take().map(|v| format!("diplo:member:{v}")) } else { None };
    let a = confirmed.as_deref().unwrap_or(a);
    if a == "diplo:confirm_yes" {
        // (no popup open)
        return Ok(());
    }
    if let Some(verb) = a.strip_prefix("diplo:member:") {
        // Leave Federation, the community's Join / Leave (render.windows.diplomacy_membership). A
        // leave first asks with the game's yes/no popup (OnLeaveFederation, OnJoinLeave: its Yes
        // posts the command); Join is posted at once
        let Some(me) = player(app) else { return Ok(()) };
        let verb = match verb {
            "leave_federation" | "join_community" | "leave_community" => verb,
            _ => return Err(format!("bad action {a}")),
        };
        if verb != "join_community" && confirmed.is_none() {
            app.diplomacy.confirm = Some(verb.to_string());
            app.relayout();
            return Ok(());
        }
        let out = world_command(app, &[verb, &me.to_string()])?;
        let note: String = app
            .runtime
            .lua
            .load(format!("local t = (loadstring or load)({out:?})() return tostring(t.note or '')"))
            .eval()
            .map_err(|e| format!("diplomacy: {e}"))?;
        app.log.push(format!("diplomacy: {verb}: {note}"));
        app.relayout();
        return Ok(());
    }
    if a == "diplo:peace_send" {
        // the war overview's Send Offer (CWarOverview::OnOfferPeaceSendOffer): the offer posted,
        // the recipient's answer, the window closed
        let (Some(Open::War(id)), Some(opt), Some(me)) = (app.diplomacy.open.clone(), app.diplomacy.action.clone(), player(app)) else {
            return Ok(());
        };
        let (me, id_s) = (me.to_string(), id.to_string());
        let out = world_command(app, &["peace", &id_s, &opt, &me])?;
        let logged: String = app
            .runtime
            .lua
            .load(format!(
                "local t = (loadstring or load)({out:?})() return (t.accepted == nil and '' or (t.accepted and 'accepted' or 'refused')) .. ' ' .. tostring(t.acceptance or '') .. ' (' .. tostring(t.reasons or '') .. ') ' .. tostring(t.phrase or '') .. ' ' .. tostring(t.ran or '') .. ' ' .. tostring(t.note or '')"
            ))
            .eval()
            .map_err(|e| format!("diplomacy: {e}"))?;
        app.log.push(format!("diplomacy: peace ({opt}) offered in war {id}: {logged}"));
        app.diplomacy.open = None;
        app.diplomacy.action = None;
        app.relayout();
        return Ok(());
    }
    if a == "diplo:action_confirm" {
        let (Some(Open::Country(id)), Some(key), Some(me)) = (app.diplomacy.open.clone(), app.diplomacy.action.clone(), player(app)) else {
            return Ok(());
        };
        let (me, id_s) = (me.to_string(), id.to_string());
        let out = world_command(app, &["propose", &key, &me, &id_s])?;
        // the answer: the recipient's reply phrase (accept or refuse), else what was not done; the
        // log has the acceptance's terms
        let (shown, logged): (String, String) = app
            .runtime
            .lua
            .load(format!(
                "local t = (loadstring or load)({out:?})() return t.phrase or (t.done and '' or (t.note or 'not done')), \n                 (t.accepted == nil and '' or (t.accepted and 'accepted' or 'refused')) .. ' ' .. tostring(t.total or '') .. ' (' .. tostring(t.reasons or '') .. ') ' .. tostring(t.note or '')"
            ))
            .eval()
            .map_err(|e| format!("diplomacy: {e}"))?;
        app.log.push(format!("diplomacy: {key} proposed to {id}: {logged}"));
        app.diplomacy.action = None;
        app.diplomacy.message = Some(shown).filter(|n| !n.is_empty());
        list_actions(app, id);
        app.relayout();
        return Ok(());
    }
    let was = app.diplomacy.open.clone();
    if app.diplomacy.act(a)? {
        // another window: its lists from their top
        if app.diplomacy.open != was {
            app.diplomacy.scroll.clear();
        }
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

    #[test]
    fn leave_popup_cancelled() {
        let mut s = State::default();
        s.act("diplo:federation:1").unwrap();
        // (App::act sets it on Leave Federation's click)
        s.confirm = Some("leave_federation".into());
        // Escape closes the popup first, then the window
        assert!(s.act("diplo:escape").unwrap());
        assert_eq!((s.confirm.clone(), s.open.clone()), (None, Some(Open::Federation(1))));
        s.confirm = Some("leave_federation".into());
        assert!(s.act("diplo:confirm_no").unwrap());
        assert_eq!(s.confirm, None);
        // another window drops it
        s.confirm = Some("leave_community".into());
        s.act("diplo:community").unwrap();
        assert_eq!(s.confirm, None);
    }

    #[test]
    fn peace_option_toggles() {
        let mut s = State::default();
        assert!(s.act("diplo:war:0").unwrap());
        assert!(s.act("diplo:peace:status_quo").unwrap());
        assert_eq!(s.action.as_deref(), Some("status_quo"));
        // another option replaces it; the same one again unselects it
        assert!(s.act("diplo:peace:surrender").unwrap());
        assert_eq!(s.action.as_deref(), Some("surrender"));
        assert!(s.act("diplo:peace:surrender").unwrap());
        assert_eq!(s.action, None);
        // a war opened again starts with none selected
        s.act("diplo:peace:force_demands").unwrap();
        s.act("diplo:war:0").unwrap();
        assert_eq!(s.action, None);
    }
}
