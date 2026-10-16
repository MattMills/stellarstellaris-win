//! The left bar's views (the game's top bar views, ETopBarView: docs/windows/empire.md), laid
//! out by `lua/render/views.lua` and the windows of `lua/render/windows/`: what a view shows of
//! the save is read in the map's runtime (the one with the world) and copied into the front end's
//! runtime (the .gfx database and the localisation), where the view is laid out.

use std::collections::HashMap;

use stellar_sim::mlua::{self, Lua, Table, Value};
use stellar_sim::Runtime;

use crate::app::App;
use crate::gui::{self, GuiItem};

/// The views in the game's ETopBarView order (CInGameIdler's array at +0xd38, read from the
/// Access*View getters; 7, 9, 12, 13 named from the left bar's order [I]).
pub const VIEWS: [&str; 18] = [
    "situation", "council", "traditions", "technology", "leaders", "species", "empire", "expansion_planner", "fleet_manager", "contacts", "factions",
    "edicts", "view12", "view13", "government", "discoveries", "claims", "market",
];

/// A view's number (ETopBarView), if `name` is one.
pub fn index(name: &str) -> Option<usize> {
    VIEWS.iter().position(|v| *v == name)
}

/// A value of one Lua state made again in another (strings, numbers, booleans and tables of
/// them; functions and userdata are left out).
fn copy(v: Value, to: &Lua, depth: u32) -> mlua::Result<Value> {
    Ok(match v {
        Value::Nil => Value::Nil,
        Value::Boolean(b) => Value::Boolean(b),
        Value::Integer(i) => Value::Integer(i),
        Value::Number(n) => Value::Number(n),
        Value::String(s) => Value::String(to.create_string(s.as_bytes())?),
        Value::Table(t) if depth < 64 => {
            let out = to.create_table()?;
            for pair in t.pairs::<Value, Value>() {
                let (k, v) = pair?;
                let k = copy(k, to, depth + 1)?;
                if k.is_nil() {
                    continue;
                }
                out.raw_set(k, copy(v, to, depth + 1)?)?;
            }
            Value::Table(out)
        }
        _ => Value::Nil,
    })
}

/// The open view's items for a screen of `w` x `h` (none when no view is open).
pub fn items(app: &App, w: u32, h: u32) -> Result<Vec<GuiItem>, String> {
    let Some(name) = app.open_view.as_deref() else { return Ok(Vec::new()) };
    let Some(map) = app.map.as_ref() else { return Ok(Vec::new()) };
    let read = || -> mlua::Result<Vec<GuiItem>> {
        let front = &app.runtime.lua;
        let state = front.create_table()?;
        for (k, v) in &app.view_state {
            state.set(k.as_str(), v.as_str())?;
        }
        // the save's part, read where the world is (a map loaded for a simulation has its world
        // on the clock's thread: the view is laid out without it)
        let data = match world_runtime(map) {
            Some(rt) => {
                let wstate = rt.lua.create_table()?;
                for (k, v) in &app.view_state {
                    wstate.set(k.as_str(), v.as_str())?;
                }
                rt.lua.globals().set("RENDER_VIEW_STATE", wstate)?;
                let d: Value = rt.lua.load(format!("return require('render.views').data({name:?}, RENDER_VIEW_STATE)")).eval()?;
                copy(d, front, 0)?
            }
            None => Value::Nil,
        };
        front.globals().set("RENDER_VIEW_DATA", data)?;
        front.globals().set("RENDER_VIEW_STATE", state)?;
        let t: Table = front
            .load(format!(
                "local items, report = require('render.views').build({name:?}, RENDER_GAME_DIR, RENDER_GFX, {{ width = {w}, height = {h} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_VIEW_DATA, RENDER_VIEW_STATE) return {{ items = items, report = report }}"
            ))
            .eval()?;
        // what could not be drawn (sprites without a definition or texture, windows not found)
        let report: Table = t.get("report")?;
        let mut missing: Vec<String> = report.get::<Table>("missing_sprites")?.sequence_values::<String>().collect::<mlua::Result<_>>()?;
        missing.sort();
        missing.dedup();
        if !missing.is_empty() {
            eprintln!("view {name}: not drawn: {}", missing.join(", "));
        }
        gui::read_items(t.get("items")?)
    };
    read().map_err(|e| {
        // (printed too: the scene is built after the command's log is written)
        eprintln!("render.views {name}: {e}");
        format!("render.views {name}: {e}")
    })
}

fn world_runtime(map: &crate::Map) -> Option<&Runtime> {
    map.has_world().then(|| map.rt())
}

/// What the views remember between frames (the tab shown, the leader selected ...), set by their
/// buttons' actions `view_set:KEY=VALUE`.
pub fn set_state(state: &mut HashMap<String, String>, kv: &str) {
    match kv.split_once('=') {
        Some((k, v)) if v.is_empty() => {
            state.remove(k);
        }
        Some((k, v)) => {
            state.insert(k.to_string(), v.to_string());
        }
        None => {
            state.remove(kv);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn views_in_the_games_order() {
        // CInGameIdler::Access*View: council 1, leaders 4, species 5, empire 6, factions 10,
        // edicts 11, government 14
        assert_eq!(index("council"), Some(1));
        assert_eq!(index("leaders"), Some(4));
        assert_eq!(index("species"), Some(5));
        assert_eq!(index("empire"), Some(6));
        assert_eq!(index("factions"), Some(10));
        assert_eq!(index("edicts"), Some(11));
        assert_eq!(index("government"), Some(14));
        assert_eq!(index("nothing"), None);
    }

    #[test]
    fn view_state_set_and_cleared() {
        let mut s = HashMap::new();
        set_state(&mut s, "tab=demographics");
        assert_eq!(s.get("tab").map(String::as_str), Some("demographics"));
        set_state(&mut s, "tab=");
        assert!(s.get("tab").is_none());
        set_state(&mut s, "expand_0=1");
        set_state(&mut s, "expand_0");
        assert!(s.is_empty());
    }

    #[test]
    fn values_copied_between_lua_states() {
        let (a, b) = (Lua::new(), Lua::new());
        let v: Value = a.load("return { name = 'Uthab', n = 3, x = 1.5, ok = true, list = { 'a', 'b' }, f = print }").eval().unwrap();
        let c = copy(v, &b, 0).unwrap();
        b.globals().set("T", c).unwrap();
        let r: String = b.load("return T.name .. T.n .. T.x .. tostring(T.ok) .. T.list[2] .. tostring(T.f)").eval().unwrap();
        assert_eq!(r, "Uthab31.5truebnil");
    }
}
