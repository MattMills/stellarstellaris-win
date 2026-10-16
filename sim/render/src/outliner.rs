//! The outliner and the alerts (docs/windows/outliner.md): what the simulation's thread reads of
//! the world for them (`lua/render/windows/outliner.lua` `extract`, `alerts.lua`), carried to the
//! render thread as plain data, and laid out there (`outliner.lua` `layout`) with the window's own
//! state: the tab shown, the groups collapsed, which view shows.

use std::collections::BTreeSet;

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
            _ => false,
        }
    }
}

/// What the outliner is laid out from, set as RENDER_OUTLINER in the GUI's runtime for
/// render.windows: the world's view (`extract`), the state, the selection (kind, id), observing.
pub fn install(runtime: &Runtime, view: &LuaData, state: &State, selected: Option<(&str, u32)>, observe: bool) -> Result<(), String> {
    let set = || -> mlua::Result<()> {
        let lua = &runtime.lua;
        let t = lua.create_table()?;
        t.set("view", view.to_lua(lua)?)?;
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
    fn flag_country_from_path() {
        assert_eq!(flag_country("/observer_outliner/2/3@16777225/observer_outliner_country_window/country"), Some(16777225));
        assert_eq!(flag_country("/outliner/1/2/outliner_member_planet_entry_window/name"), None);
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
