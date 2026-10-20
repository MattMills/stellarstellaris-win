//! The outliner and the alerts (docs/windows/outliner.md): what the simulation's thread reads of
//! the world for them (`lua/render/windows/outliner.lua` `extract`, `alerts.lua`), carried to the
//! render thread as plain data, and laid out there (`outliner.lua` `layout`) with the window's own
//! state: the tab shown, the groups collapsed, which view shows.

use std::collections::BTreeSet;
use std::sync::Arc;

use stellar_sim::mlua::{self, Lua, Table, Value};
use stellar_sim::Runtime;

/// A Lua value copied out of a runtime (numbers, strings, booleans, tables), to rebuild in another.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum LuaData {
    #[default]
    Nil,
    Bool(bool),
    Num(f64),
    Str(String),
    Table(Vec<(LuaData, LuaData)>),
}

impl LuaData {
    /// The value copied (functions and userdata become nil; tables nested to any depth).
    pub fn read(v: Value) -> mlua::Result<LuaData> {
        Ok(match v {
            Value::Boolean(b) => LuaData::Bool(b),
            Value::Integer(i) => LuaData::Num(i as f64),
            Value::Number(n) => LuaData::Num(n),
            Value::String(s) => LuaData::Str(s.to_str()?.to_string()),
            Value::Table(t) => {
                let mut out = Vec::new();
                for p in t.pairs::<Value, Value>() {
                    let (k, v) = p?;
                    out.push((LuaData::read(k)?, LuaData::read(v)?));
                }
                LuaData::Table(out)
            }
            _ => LuaData::Nil,
        })
    }

    /// The value made again in `lua`.
    pub fn to_lua(&self, lua: &Lua) -> mlua::Result<Value> {
        Ok(match self {
            LuaData::Nil => Value::Nil,
            LuaData::Bool(b) => Value::Boolean(*b),
            LuaData::Num(n) => {
                if n.fract() == 0.0 && n.abs() < 9.0e15 {
                    Value::Integer(*n as i64)
                } else {
                    Value::Number(*n)
                }
            }
            LuaData::Str(s) => Value::String(lua.create_string(s)?),
            LuaData::Table(pairs) => {
                let t = lua.create_table()?;
                for (k, v) in pairs {
                    t.raw_set(k.to_lua(lua)?, v.to_lua(lua)?)?;
                }
                Value::Table(t)
            }
        })
    }

    /// A field of a table (None for other values or a missing key).
    pub fn get(&self, key: &str) -> Option<&LuaData> {
        match self {
            LuaData::Table(pairs) => pairs.iter().find(|(k, _)| matches!(k, LuaData::Str(s) if s == key)).map(|(_, v)| v),
            _ => None,
        }
    }
}

/// The outliner's own state (the player's clicks): the tab shown, the groups collapsed (by key),
/// what shows (COutlinerControllerView's mode): 0 the tabs, 1 the observer's list, 2 neither.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub tab: u32,
    /// how often each tab was switched to (its groups' order flips each time: section 2 of the
    /// doc)
    pub shows: [u32; 4],
    pub collapsed: BTreeSet<String>,
    pub shown: u8,
    /// the tab window's popup: 0 none, 1 the options (COutlinerOptions), 2 the colonies' order
    /// (COutlinerRearrange)
    pub popup: u8,
    /// the groups shown or hidden against their default (`NAME@TAB`: the options' checkboxes)
    pub toggled: BTreeSet<String>,
    /// a tab's groups in the order the options' up and down buttons gave (names, comma separated)
    pub order: std::collections::BTreeMap<u32, String>,
    /// the colonies' display mode (the options' spinner, 0..3)
    pub planet_mode: u8,
    /// the tabs whose badge is off (the options' Notification checkbox)
    pub notifications_off: BTreeSet<u32>,
    /// the options' Custom Outliner Tab checkbox
    pub custom_tab: bool,
    /// the colonies in the order the rearrange window gave (planet ids, comma separated), the
    /// last moved
    pub colony_order: String,
    pub last_moved: Option<u32>,
}

impl State {
    /// An `outliner:...` action of a click (the buttons' actions outliner.lua gives): whether the
    /// outliner changed.
    pub fn act(&mut self, action: &str) -> bool {
        let mut it = action.splitn(2, ':');
        match (it.next(), it.next()) {
            (Some("tab"), Some(n)) => {
                let n = n.parse().unwrap_or(0);
                let changed = self.tab != n;
                if changed && (n as usize) < self.shows.len() {
                    self.shows[n as usize] += 1;
                }
                // (a tab switched closes its popup)
                if changed {
                    self.popup = 0;
                }
                self.tab = n;
                changed
            }
            (Some("toggle"), Some(key)) => {
                if !self.collapsed.remove(key) {
                    self.collapsed.insert(key.to_string());
                }
                true
            }
            // the toggles (COutlinerControllerView::OnToggleTabbedOutliner, OnToggleObserverOutliner):
            // a view's button hides it when it shows, else shows it instead of the other
            (Some("tabbed"), None) => {
                self.shown = if self.shown == 0 { 2 } else { 0 };
                true
            }
            (Some("observer"), None) => {
                self.shown = if self.shown == 1 { 2 } else { 1 };
                true
            }
            // the tab window's buttons: options, rearrange (each toggles its popup, closing the
            // other), the popups' close
            (Some("options"), None) => {
                self.popup = if self.popup == 1 { 0 } else { 1 };
                true
            }
            (Some("rearrange"), None) => {
                self.popup = if self.popup == 2 { 0 } else { 2 };
                true
            }
            (Some("close"), None) => {
                self.popup = 0;
                true
            }
            (Some("group"), Some(key)) => {
                if !self.toggled.remove(key) {
                    self.toggled.insert(key.to_string());
                }
                true
            }
            (Some("order"), Some(rest)) => {
                let (tab, list) = rest.split_once(':').unwrap_or((rest, ""));
                self.order.insert(tab.parse().unwrap_or(0), list.to_string());
                true
            }
            (Some("planet_mode"), Some(n)) => {
                self.planet_mode = n.parse::<u8>().unwrap_or(0) % 4;
                true
            }
            (Some("notify"), Some(tab)) => {
                let t = tab.parse().unwrap_or(0);
                if !self.notifications_off.remove(&t) {
                    self.notifications_off.insert(t);
                }
                true
            }
            (Some("custom"), None) => {
                self.custom_tab = !self.custom_tab;
                true
            }
            (Some("colonies"), Some(rest)) => {
                let (last, list) = rest.split_once(':').unwrap_or(("", rest));
                self.last_moved = last.parse().ok();
                self.colony_order = list.to_string();
                true
            }
            _ => false,
        }
    }
}

thread_local! {
    /// The view installed last: its `tips` are read from it as they are asked for ([`install`]).
    static VIEW: std::cell::RefCell<Option<Arc<LuaData>>> = const { std::cell::RefCell::new(None) };
}

/// The field of a table under a Lua key (a string, or a number: the ids).
fn field<'a>(d: &'a LuaData, key: &Value) -> Option<&'a LuaData> {
    let LuaData::Table(pairs) = d else { return None };
    pairs
        .iter()
        .find(|(k, _)| match (k, key) {
            (LuaData::Str(a), Value::String(b)) => b.as_bytes().as_ref() == a.as_bytes(),
            (LuaData::Num(a), Value::Integer(b)) => *a == *b as f64,
            (LuaData::Num(a), Value::Number(b)) => a == b,
            (LuaData::Bool(a), Value::Boolean(b)) => a == b,
            _ => false,
        })
        .map(|(_, v)| v)
}

/// The view's `tips` (render.tooltip_data: 350,000 values in the 2210 save, the rest of the view
/// 2,000) made in Lua as they are read, two levels deep: `tips.fleets[id]` makes that fleet's
/// table alone. Made whole at each layout they took 50 to 80 ms (docs/profiling.md); the layout
/// and the tooltips read a few dozen of them by key (render.windows.outliner row_tip,
/// render.tooltip), never by `pairs`.
const LAZY_TIPS: &str = r#"
local get = RENDER_TIPS_GET
local function level2(k1)
    return setmetatable({}, { __index = function(t, k2)
        local _, v = get(k1, k2)
        rawset(t, k2, v)
        return v
    end })
end
return setmetatable({}, { __index = function(t, k1)
    local nested, v = get(k1)
    if nested then
        v = level2(k1)
    end
    rawset(t, k1, v)
    return v
end })
"#;

/// What the outliner is laid out from, set as RENDER_OUTLINER in the GUI's runtime for
/// render.windows: the world's view (`extract`; its `tips` made as they are read: [`LAZY_TIPS`]),
/// the state, the selection (kind, id), observing.
pub fn install(runtime: &Runtime, view: &Arc<LuaData>, state: &State, selected: Option<(&str, u32)>, observe: bool) -> Result<(), String> {
    install_in(&runtime.lua, view, state, selected, observe)
}

fn install_in(lua: &Lua, view: &Arc<LuaData>, state: &State, selected: Option<(&str, u32)>, observe: bool) -> Result<(), String> {
    let set = || -> mlua::Result<()> {
        if lua.globals().get::<Option<mlua::Function>>("RENDER_TIPS_GET")?.is_none() {
            // (nested: whether the field is a table, its fields then asked for one by one)
            let get = lua.create_function(|lua, (k1, k2): (Value, Option<Value>)| -> mlua::Result<(bool, Value)> {
                VIEW.with(|v| {
                    let v = v.borrow();
                    let Some(a) = v.as_ref().and_then(|v| v.get("tips")).and_then(|t| field(t, &k1)) else { return Ok((false, Value::Nil)) };
                    match k2 {
                        None if matches!(a, LuaData::Table(_)) => Ok((true, Value::Nil)),
                        None => Ok((false, a.to_lua(lua)?)),
                        Some(k2) => Ok((false, field(a, &k2).map(|b| b.to_lua(lua)).transpose()?.unwrap_or(Value::Nil))),
                    }
                })
            })?;
            lua.globals().set("RENDER_TIPS_GET", get)?;
        }
        // (the view before freed elsewhere: crate::drop_later)
        if let Some(old) = VIEW.with(|v| v.borrow_mut().replace(view.clone())) {
            crate::drop_later(old);
        }
        let t = lua.create_table()?;
        let v = lua.create_table()?;
        if let LuaData::Table(pairs) = &**view {
            for (k, x) in pairs {
                if matches!(k, LuaData::Str(s) if s == "tips") {
                    v.raw_set("tips", lua.load(LAZY_TIPS).set_name("outliner tips").eval::<Table>()?)?;
                } else {
                    v.raw_set(k.to_lua(lua)?, x.to_lua(lua)?)?;
                }
            }
        }
        t.set("view", v)?;
        let s = lua.create_table()?;
        s.set("tab", state.tab)?;
        // (Overview shows once at the load)
        let shows = lua.create_table()?;
        for (t, n) in state.shows.iter().enumerate() {
            shows.set(t, n + u32::from(t == 0))?;
        }
        s.set("shows", shows)?;
        let c = lua.create_table()?;
        for k in &state.collapsed {
            c.set(k.as_str(), true)?;
        }
        s.set("collapsed", c)?;
        s.set("shown", state.shown)?;
        s.set("popup", state.popup)?;
        let tg = lua.create_table()?;
        for k in &state.toggled {
            tg.set(k.as_str(), true)?;
        }
        s.set("toggled", tg)?;
        let order = lua.create_table()?;
        for (t, l) in &state.order {
            order.set(*t, l.as_str())?;
        }
        s.set("order", order)?;
        s.set("planet_mode", state.planet_mode)?;
        let off = lua.create_table()?;
        for t in &state.notifications_off {
            off.set(*t, true)?;
        }
        s.set("notifications_off", off)?;
        s.set("custom_tab", state.custom_tab)?;
        s.set("colony_order", state.colony_order.as_str())?;
        if let Some(l) = state.last_moved {
            s.set("last_moved", l)?;
        }
        t.set("state", s)?;
        if let Some((kind, id)) = selected {
            let sel = lua.create_table()?;
            sel.set("kind", kind)?;
            sel.set("id", id)?;
            t.set("selected", sel)?;
        }
        t.set("observe", observe)?;
        lua.globals().set("RENDER_OUTLINER", t)
    };
    set().map_err(|e| format!("outliner: {e}"))
}

/// The country a sprite of the outliner shows the flag of: `@ID/` in its path (a row of the
/// observer's list).
pub fn flag_country(path: &str) -> Option<u32> {
    let at = path.find('@')?;
    let rest = &path[at + 1..];
    let end = rest.find('/').unwrap_or(rest.len());
    rest[..end].parse().ok()
}

/// The view of a galaxy's extract (`outliner_view`), copied.
pub fn read_view(g: &Table) -> mlua::Result<LuaData> {
    LuaData::read(g.get::<Value>("outliner_view")?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lua_data_round_trip() {
        let lua = Lua::new();
        let v: Value = lua.load("return { 1, 2.5, 'x', { a = true, b = { 'y' } }, n = 3 }").eval().unwrap();
        let d = LuaData::read(v).unwrap();
        let back = d.to_lua(&lua).unwrap();
        let again = LuaData::read(back).unwrap();
        // (a table's pairs come in the hash's order: compare by field)
        assert_eq!(again.get("n"), Some(&LuaData::Num(3.0)));
        let t: Table = lua.load("return ...").call(d.to_lua(&lua).unwrap()).unwrap();
        assert_eq!(t.get::<f64>(2).unwrap(), 2.5);
        assert_eq!(t.get::<String>(3).unwrap(), "x");
        let inner: Table = t.get(4).unwrap();
        assert!(inner.get::<bool>("a").unwrap());
        assert_eq!(inner.get::<Table>("b").unwrap().get::<String>(1).unwrap(), "y");
    }

    #[test]
    fn tips_made_as_read() {
        let lua = Lua::new();
        let v: Value = lua
            .load("return { groups = { { key = 'military' } }, tips = { player_name = 'UOR', fleets = { [3] = { name = 'Typhoon', sizes = { { 'corvette', 3 } } } }, economy = { energy = { stock = 9000 } } } }")
            .eval()
            .unwrap();
        let view = Arc::new(LuaData::read(v).unwrap());
        install_in(&lua, &view, &State::default(), None, false).unwrap();
        let check = |code: &str| lua.load(code).eval::<String>().unwrap();
        assert_eq!(check("return RENDER_OUTLINER.view.groups[1].key"), "military");
        assert_eq!(check("return RENDER_OUTLINER.view.tips.player_name"), "UOR");
        assert_eq!(check("local f = RENDER_OUTLINER.view.tips.fleets[3] return f.name .. ' ' .. f.sizes[1][1] .. ' ' .. f.sizes[1][2]"), "Typhoon corvette 3");
        assert_eq!(check("return tostring(RENDER_OUTLINER.view.tips.economy.energy.stock)"), "9000");
        assert_eq!(check("local t = RENDER_OUTLINER.view.tips return tostring(t.fleets[4]) .. ' ' .. tostring(t.ships) .. ' ' .. tostring((t.ships or {})[1])"), "nil nil nil");
        // a new view installed: the tips read from it
        let v: Value = lua.load("return { tips = { player_name = 'Other' } }").eval().unwrap();
        install_in(&lua, &Arc::new(LuaData::read(v).unwrap()), &State::default(), None, false).unwrap();
        assert_eq!(check("return RENDER_OUTLINER.view.tips.player_name"), "Other");
    }

    #[test]
    fn flag_country_from_path() {
        assert_eq!(flag_country("/observer_outliner/2/3@16777225/observer_outliner_country_window/country"), Some(16777225));
        assert_eq!(flag_country("/outliner/1/2/outliner_member_planet_entry_window/name"), None);
    }

    #[test]
    fn popup_actions() {
        let mut s = State::default();
        assert!(s.act("options"));
        assert_eq!(s.popup, 1);
        assert!(s.act("rearrange"));
        assert_eq!(s.popup, 2);
        assert!(s.act("tab:1"));
        assert_eq!(s.popup, 0);
        assert!(s.act("group:planets@0"));
        assert!(s.toggled.contains("planets@0"));
        assert!(s.act("order:0:sectors,civilian"));
        assert_eq!(s.order.get(&0).map(String::as_str), Some("sectors,civilian"));
        assert!(s.act("planet_mode:5"));
        assert_eq!(s.planet_mode, 1);
        assert!(s.act("colonies:7:7,5"));
        assert_eq!((s.last_moved, s.colony_order.as_str()), (Some(7), "7,5"));
        assert!(s.act("colonies::5,7"));
        assert_eq!(s.last_moved, None);
    }

    #[test]
    fn state_actions() {
        let mut s = State::default();
        assert!(s.act("tab:1"));
        assert_eq!(s.tab, 1);
        assert!(!s.act("tab:1"));
        assert_eq!(s.shows, [0, 1, 0, 0]);
        assert!(s.act("toggle:military"));
        assert!(s.collapsed.contains("military"));
        assert!(s.act("toggle:military"));
        assert!(s.collapsed.is_empty());
        assert!(s.act("observer"));
        assert_eq!(s.shown, 1);
        assert!(s.act("observer"));
        assert_eq!(s.shown, 2);
        assert!(s.act("tabbed"));
        assert_eq!(s.shown, 0);
        assert!(s.act("tabbed"));
        assert_eq!(s.shown, 2);
        assert!(!s.act("bogus"));
    }
}
