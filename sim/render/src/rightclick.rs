//! The right click on the map with the player's fleets selected (docs/windows/fleet.md "Right
//! click"; CInGameIdler::HandleInputEvent's right button @0x1c862a2, CSelectionList::
//! PerformAction, CFleet::PerformAction 0x2dd36a0): an armed order button cancelled; else what the
//! selected fleets do on the target under the cursor, decided in the simulation's runtime by
//! `lua/render/windows/fleet_rightclick.lua`: an order at once, the order selector (main.gui's
//! `order_selector`, laid out by render.windows.fleet over the other windows), or a Yes/No popup
//! (popup.gui's `yes_no_popup_window`). An entry's click (`fleet:menu:I`) or the popup's Yes
//! (`fleet:popup_yes`) runs its commands, Shift / Ctrl read then; Escape, a click elsewhere or the
//! next right click closes them.
//!
//! The target: a map label's or an outliner row's object (their `select:fleet:ID`,
//! `select:planet:ID`, `map:slide:I` actions: CFleetMapIcon / CPlanetMapIcon::OnRightClick act on
//! their object [V]), else the map's pick at the cursor (a system, a planet or star, a fleet or a
//! ship's fleet), else in a system view the point of its plane (CalcMouseGroundIntersect) [V].

use crate::app::{App, MapView};
use crate::scene::Pickable;

impl App {
    /// The selected fleets: the box selection's when the selected fleet is one of them (the game
    /// selects them all; App::selected is the first), else the selected fleet.
    pub(crate) fn selected_fleets(&self) -> Vec<u32> {
        match self.selected {
            Some(Pickable::Fleet(id)) if self.fleet.group.contains(&id) => self.fleet.group.clone(),
            Some(Pickable::Fleet(id)) => vec![id],
            _ => Vec::new(),
        }
    }

    /// What a GUI button's action names as a right click's target: `select:fleet:ID`,
    /// `select:planet:ID`, `map:slide:I` (a star label: system I).
    fn action_target(&self, action: &str) -> Option<String> {
        let mut it = action.split(':');
        match (it.next(), it.next(), it.next().and_then(|v| v.parse::<u32>().ok())) {
            (Some("select"), Some("fleet"), Some(id)) => Some(format!("{{ kind = 'fleet', id = {id} }}")),
            (Some("select"), Some("planet"), Some(id)) => Some(format!("{{ kind = 'planet', id = {id} }}")),
            (Some("map"), Some("slide"), Some(i)) => {
                let s = self.map.as_ref()?.galaxy.systems.get(i as usize)?;
                Some(format!("{{ kind = 'system', id = {} }}", s.id))
            }
            _ => None,
        }
    }

    /// Whether the right click at (x, y) is the fleets' (some selected): a GUI element that is a
    /// map label or an outliner row of an object, or no GUI element.
    pub(crate) fn fleet_right_click_target(&mut self, x: f32, y: f32) -> Result<Option<String>, String> {
        if self.selected_fleets().is_empty() {
            return Ok(None);
        }
        if let Some((path, action)) = self.button_at(x, y)? {
            let object = path.starts_with("/label/") || path.starts_with("/outliner/");
            return Ok(if object { action.as_deref().and_then(|a| self.action_target(a)) } else { None });
        }
        let Some(map) = self.map.as_ref() else { return Ok(None) };
        let g = map.galaxy.clone();
        let hit = self.scene()?.pick_at(x, y, 6.0);
        let view = self.view;
        Ok(Some(match (view, hit) {
            (_, Some(Pickable::Fleet(f))) => format!("{{ kind = 'fleet', id = {f} }}"),
            (_, Some(Pickable::Ship(s))) => format!("{{ kind = 'ship', id = {s} }}"),
            (_, Some(Pickable::Body(p))) => format!("{{ kind = 'planet', id = {p} }}"),
            (_, Some(Pickable::System(i))) => match g.systems.get(i) {
                Some(s) => format!("{{ kind = 'system', id = {} }}", s.id),
                None => return Ok(None),
            },
            (MapView::System(si), None) => {
                let Some(c) = self.current() else { return Ok(None) };
                let p = c.ground_at(x, y, self.size.0, self.size.1);
                let Some(s) = g.systems.get(si) else { return Ok(None) };
                format!("{{ kind = 'point', x = {:.3}, y = {:.3}, origin = {} }}", p.0, p.2, s.id)
            }
            _ => "{ kind = 'none' }".to_string(),
        }))
    }

    /// The right click (the binding `order`) at (x, y): an armed order cancelled, the order
    /// selector and popup closed, then the selected fleets' action on `target` (a Lua table:
    /// fleet_right_click_target). Whether it was taken.
    pub(crate) fn fleet_right_click(&mut self, x: f32, y: f32, target: Option<String>) -> Result<bool, String> {
        // an armed order button: cancelled, nothing else (HandleInputEvent @0x1c862ce) [V]
        if self.fleet.armed.take().is_some() {
            self.log.push("right click: the armed order cancelled".into());
            self.relayout_windows();
            return Ok(true);
        }
        let closed = self.fleet.menu.take().is_some() | self.fleet.popup.take().is_some();
        let fleets = self.selected_fleets();
        let Some(target) = target.filter(|_| !fleets.is_empty()) else {
            if closed {
                self.relayout_windows();
            }
            return Ok(closed);
        };
        let m = self.controls.mods();
        let ids = fleets.iter().map(|f| f.to_string()).collect::<Vec<_>>().join(", ");
        let code = format!(
            "local rc = require('render.windows.fleet_rightclick') \
             local r = rc.at({{ {ids} }}, {target}, {{ shift = {}, ctrl = {}, alt = {} }}) \
             local kind = r.menu and 'menu' or r.popup and 'popup' or r.done and 'done' or 'none' \
             return kind .. '\\n' .. tostring(r.done or r.none or '') .. '\\n' .. fd.serialize(r)",
            m.shift, m.ctrl, m.alt
        );
        let reply = self.fleet_sim_query(&code)?;
        let mut parts = reply.splitn(3, '\n');
        let (kind, text, src) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or("").to_string());
        self.log.push(format!("right click {x},{y}: fleets {ids} on {target}: {kind} {text}"));
        match kind {
            // (the open menu or popup takes the cursor: the map's tooltip under it dropped)
            "menu" => {
                self.fleet.menu = Some(((x, y), src));
                self.hovered = None;
            }
            "popup" => {
                self.fleet.popup = Some(src);
                self.hovered = None;
            }
            "done" => self.fleet_published(),
            _ => {}
        }
        self.fleet.commands += 1;
        self.relayout_windows();
        Ok(true)
    }

    /// An order selector's entry chosen (`fleet:menu:I`, 1-based) or the popup's Yes / No
    /// (`fleet:popup_yes`, `fleet:popup_no`): its commands run (COrderWindow::OnClick: Click, then
    /// HideOrderSelector [V]; the popup's yes posts without queueing [V]).
    pub(crate) fn fleet_menu_act(&mut self, action: &str) -> Result<(), String> {
        let m = self.controls.mods();
        let code = if let Some(i) = action.strip_prefix("fleet:menu:").and_then(|v| v.parse::<usize>().ok()) {
            let Some((_, src)) = self.fleet.menu.take() else { return Ok(()) };
            format!(
                "local r = (function() {src} end)() local e = r.menu and r.menu[{i}] \
                 if not e then return 'no entry {i}' end \
                 if e.possible == false then return 'not possible: ' .. tostring(e.key) end \
                 return require('render.windows.fleet_rightclick').run(e.run, {}, {})",
                m.shift, m.ctrl
            )
        } else if action == "fleet:popup_yes" {
            let Some(src) = self.fleet.popup.take() else { return Ok(()) };
            format!("local r = (function() {src} end)() return require('render.windows.fleet_rightclick').run(r.popup and r.popup.run, false, false)")
        } else {
            self.fleet.popup = None;
            self.relayout_windows();
            return Ok(());
        };
        let r = self.fleet_run(&code)?;
        // Colonize Planet: the colonise view for that fleet (OpenColoniseView(planet, fleet)), the
        // planet view's colonize window with the fleet as its filter (planet.rs)
        // a command that asks first (Land Armies on a neutral planet): the Yes/No popup
        if let Some(src) = r.strip_prefix("popup:") {
            self.fleet.popup = Some(src.to_string());
            self.relayout_windows();
        }
        if let Some(rest) = r.strip_prefix("open_colonize ") {
            let mut it = rest.split(' ').map(|v| v.parse::<u32>().ok());
            if let (Some(Some(pid)), Some(Some(fid))) = (it.next(), it.next()) {
                self.select(Some(Pickable::Body(pid)));
                self.planet_view.colonize = Some(pid);
                self.planet_view.colonize_fleet = Some(fid);
                self.planet_view.source = None;
                self.planet_view.source_fleet = None;
                self.relayout_windows();
            }
        }
        Ok(())
    }

    /// The order selector closed by a click elsewhere (SetOpenAutocloseWindow [I]); the click
    /// goes on. Whether it was open.
    pub(crate) fn fleet_autoclose(&mut self, action: Option<&str>) -> bool {
        if action.is_some_and(|a| a.starts_with("fleet:menu:") || a.starts_with("fleet:popup")) {
            return false;
        }
        if self.fleet.menu.take().is_some() {
            self.relayout_windows();
            return true;
        }
        false
    }
}
