//! The left bar's views (the game's top bar views: technology, traditions, ...; docs/windows/):
//! one open at a time, as CInGameIdler::ToggleTopBarView keeps them (it closes the others before
//! it shows one). Each view is a Lua module `lua/render/windows/NAME.lua` (NAME the view's
//! ETopBarView token, as the left bar's GFX_topbar_NAME_button):
//!
//!   M.extract(game_dir) -> data      what the view shows of the world, read where the galaxy is
//!                                    read (galaxy::extract: the simulation's thread, or the save's
//!                                    world before it runs), carried in the snapshot (Galaxy::views)
//!   M.build(ctx, data, state) -> items, report
//!                                    the view laid out (render.gui) on the UI thread; ctx =
//!                                    { game_dir, db, screen, texture_size, loc }, state the view's
//!                                    own keys (its tab, the area chosen: `view_set:KEY=VALUE`)
//!
//! The data crosses threads as a [`Value`] tree (plain Lua tables, strings, numbers, booleans).

use std::collections::HashMap;

use stellar_sim::mlua::{self, Lua, Table};
use stellar_sim::Runtime;

use crate::gui::{self, Layout};

/// A Lua value without functions or userdata: what a view's `extract` returns.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Nil,
    Bool(bool),
    Num(f64),
    Str(String),
    /// a table: its sequence part in order, then its other keys
    Table(Vec<(Value, Value)>),
}

impl Value {
    pub fn read(v: mlua::Value, depth: u32) -> mlua::Result<Value> {
        Ok(match v {
            mlua::Value::Nil => Value::Nil,
            mlua::Value::Boolean(b) => Value::Bool(b),
            mlua::Value::Integer(i) => Value::Num(i as f64),
            mlua::Value::Number(n) => Value::Num(n),
            mlua::Value::String(s) => Value::Str(s.to_str()?.to_string()),
            mlua::Value::Table(t) if depth < 32 => {
                let n = t.raw_len();
                let mut out = Vec::new();
                for i in 1..=n {
                    out.push((Value::Num(i as f64), Value::read(t.raw_get(i)?, depth + 1)?));
                }
                for p in t.pairs::<mlua::Value, mlua::Value>() {
                    let (k, v) = p?;
                    let in_seq = match &k {
                        mlua::Value::Integer(i) => *i >= 1 && (*i as usize) <= n,
                        mlua::Value::Number(f) => f.fract() == 0.0 && *f >= 1.0 && (*f as usize) <= n,
                        _ => false,
                    };
                    if !in_seq {
                        out.push((Value::read(k, depth + 1)?, Value::read(v, depth + 1)?));
                    }
                }
                Value::Table(out)
            }
            _ => Value::Nil,
        })
    }

    pub fn to_lua(&self, lua: &Lua) -> mlua::Result<mlua::Value> {
        Ok(match self {
            Value::Nil => mlua::Value::Nil,
            Value::Bool(b) => mlua::Value::Boolean(*b),
            Value::Num(n) => mlua::Value::Number(*n),
            Value::Str(s) => mlua::Value::String(lua.create_string(s)?),
            Value::Table(pairs) => {
                let t = lua.create_table()?;
                for (k, v) in pairs {
                    t.raw_set(k.to_lua(lua)?, v.to_lua(lua)?)?;
                }
                mlua::Value::Table(t)
            }
        })
    }
}

/// The views there are: the modules of `lua/render/windows` (their names, sorted).
pub fn names() -> Vec<String> {
    let dir = std::path::Path::new(&crate::galaxy::lua_dir()).join("render/windows");
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .map(|d| {
            d.filter_map(|e| e.ok())
                .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".lua")).map(String::from))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// The game's top bar views (ETopBarView's tokens, the left bar's GFX_topbar_NAME_button): a
/// module of lua/render/windows by one of these names is a view; another module is one when it
/// says so (`M.view = true`). The other modules there (the outliner's, the map icons', the
/// diplomacy windows' data, helpers) have their own callers and arguments.
pub const TOP_BAR_VIEWS: [&str; 18] = [
    "situation", "council", "traditions", "technology", "leaders", "species", "empire", "expansion_planner",
    "fleet_manager", "contacts", "factions", "edicts", "view12", "view13", "government", "discoveries", "claims", "market",
];

/// The view open (App::toggle_view): the one view whose data the snapshots carry. Read where the
/// galaxy is extracted (the simulation's thread too).
static OPEN: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

pub fn set_open(name: Option<&str>) {
    if let Ok(mut o) = OPEN.lock() {
        *o = name.map(String::from);
    }
}

/// A view's data from a runtime's world (its module's `extract(game_dir)`), or none: not a view,
/// no extract, or its extract failed (the failure goes to stderr).
pub fn extract_one(runtime: &Runtime, game_dir: &str, name: &str) -> Option<Value> {
    if !names().iter().any(|n| n == name) {
        return None;
    }
    let read = || -> mlua::Result<Option<Value>> {
        let m: Table = runtime.lua.load(format!("return require('render.windows.{name}')")).eval()?;
        if !TOP_BAR_VIEWS.contains(&name) && m.get::<Option<bool>>("view")? != Some(true) {
            return Ok(None);
        }
        let Some(f) = m.get::<Option<mlua::Function>>("extract")? else { return Ok(None) };
        Ok(Some(Value::read(f.call(game_dir.replace('\\', "/"))?, 0)?))
    };
    match read() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("render.windows.{name}: extract: {e}");
            None
        }
    }
}

/// A view's command (the action `cmd:VIEW:ARG:ARG...`): its module's `command(ARG, ARG, ...)` run
/// in the simulation's runtime between days (its world, definitions, modifiers: the game's own
/// command, CResearchTechnologyCommand, CCountryActivateTraditionCommand, ...), started if it is not
/// running; then a snapshot published and taken. The string it returns (what it did) for the log.
pub fn command(map: &mut crate::Map, view: &str, args: &[&str]) -> Result<String, String> {
    if !names().iter().any(|n| n == view) {
        return Err(format!("no view {view}"));
    }
    let quoted: Vec<String> = args.iter().map(|a| format!("{a:?}")).collect();
    let code = format!("return tostring(require('render.windows.{view}').command({}))", quoted.join(", "));
    map.ready()?;
    let clock = map.clock.as_ref().ok_or("no simulation")?;
    let r = clock.query(&code).map_err(|e| format!("render.windows.{view}: command: {e}"))?;
    clock.publish(true);
    map.sync();
    Ok(r)
}

/// What Escape does in the open view with side windows open: its module's `escape(state)` (an
/// action: its innermost window closed), or none (the module has no escape: all of its state
/// cleared).
pub fn escape(runtime: &Runtime, name: &str, state: &HashMap<String, String>) -> Option<String> {
    let read = || -> mlua::Result<Option<String>> {
        let m: Table = runtime.lua.load(format!("return require('render.windows.{name}')")).eval()?;
        let Some(f) = m.get::<Option<mlua::Function>>("escape")? else { return Ok(None) };
        let s = runtime.lua.create_table()?;
        for (k, v) in state {
            s.set(k.as_str(), v.as_str())?;
        }
        f.call(s)
    };
    read().unwrap_or_else(|e| {
        eprintln!("render.windows.{name}: escape: {e}");
        None
    })
}

/// The open view's data from a runtime's world (only the open one: a snapshot carries what is
/// drawn; opening a view republishes it, Map::refresh_view).
pub fn extract(runtime: &Runtime, game_dir: &str) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    let open = OPEN.lock().ok().and_then(|o| o.clone());
    if let Some(name) = open {
        if let Some(v) = extract_one(runtime, game_dir, &name) {
            out.insert(name, v);
        }
    }
    out
}

/// The wheel over the open view `name` (its module's `wheel(ctx, data, state, notches, x, y)`:
/// the state's keys to set when the pointer is over one of its lists, else nil): the pairs, or
/// None (the wheel is the map's).
pub fn wheel(runtime: &Runtime, width: u32, height: u32, name: &str, data: Option<&Value>, state: &HashMap<String, String>, notches: f32, x: f32, y: f32) -> Option<Vec<(String, String)>> {
    let lua = &runtime.lua;
    let m: Table = lua.load(format!("return require('render.windows.{name}')")).eval().ok()?;
    let f: mlua::Function = m.get::<Option<mlua::Function>>("wheel").ok()??;
    let s = lua.create_table().ok()?;
    for (k, v) in state {
        s.set(k.as_str(), v.as_str()).ok()?;
    }
    let ctx: Table = lua
        .load(format!("return {{ game_dir = RENDER_GAME_DIR, db = RENDER_GFX, screen = {{ width = {width}, height = {height} }}, texture_size = RENDER_TEXTURE_SIZE, loc = RENDER_LOC }}"))
        .eval()
        .ok()?;
    let d = data.map_or(Ok(mlua::Value::Nil), |d| d.to_lua(lua)).ok()?;
    let out: Option<Table> = f.call((ctx, d, s, notches, x, y)).map_err(|e| eprintln!("render.windows.{name}: wheel: {e}")).ok()?;
    let out = out?;
    let mut pairs = Vec::new();
    for p in out.pairs::<String, String>() {
        let (k, v) = p.ok()?;
        pairs.push((k, v));
    }
    Some(pairs)
}

/// Whether a text box of the open view `name` has the keyboard (its module's `text_focus(state)`:
/// a rename dialog's edit box).
pub fn text_focus(runtime: &Runtime, name: &str, state: &HashMap<String, String>) -> bool {
    let read = || -> mlua::Result<bool> {
        let m: Table = runtime.lua.load(format!("return require('render.windows.{name}')")).eval()?;
        let Some(f) = m.get::<Option<mlua::Function>>("text_focus")? else { return Ok(false) };
        let s = runtime.lua.create_table()?;
        for (k, v) in state {
            s.set(k.as_str(), v.as_str())?;
        }
        Ok(f.call::<Option<bool>>(s)?.unwrap_or(false))
    };
    read().unwrap_or(false)
}

/// A key typed into the open view's focused text box (its module's `text_key(state, key)`, the key
/// `text:C` a character or `key:NAME` an editing key): the state's pairs to set and an action to
/// run, or None (the key not taken).
pub fn text_key(runtime: &Runtime, name: &str, state: &HashMap<String, String>, key: &str) -> Option<(Vec<(String, String)>, Option<String>)> {
    let read = || -> mlua::Result<Option<(Vec<(String, String)>, Option<String>)>> {
        let m: Table = runtime.lua.load(format!("return require('render.windows.{name}')")).eval()?;
        let Some(f) = m.get::<Option<mlua::Function>>("text_key")? else { return Ok(None) };
        let s = runtime.lua.create_table()?;
        for (k, v) in state {
            s.set(k.as_str(), v.as_str())?;
        }
        let (pairs, action): (Option<Table>, Option<String>) = f.call((s, key))?;
        let Some(pairs) = pairs else { return Ok(None) };
        let mut out = Vec::new();
        for p in pairs.pairs::<String, String>() {
            out.push(p?);
        }
        Ok(Some((out, action)))
    };
    read().unwrap_or_else(|e| {
        eprintln!("render.windows.{name}: text_key: {e}");
        None
    })
}

/// The state keys of the view `name` that are its side windows (its module's `escape_keys`:
/// Escape closes them first), or None when the module lists none (then any state is one).
pub fn escape_keys(runtime: &Runtime, name: &str) -> Option<Vec<String>> {
    let m: Table = runtime.lua.load(format!("return require('render.windows.{name}')")).eval().ok()?;
    let keys: Table = m.get::<Option<Table>>("escape_keys").ok()??;
    keys.sequence_values::<String>().collect::<mlua::Result<Vec<_>>>().ok()
}

/// The view `name` laid out for a screen of `width` x `height` (in the UI's runtime: the GUI and
/// the localisation installed), with its data and its state.
pub fn layout(runtime: &Runtime, width: u32, height: u32, name: &str, data: Option<&Value>, state: &HashMap<String, String>) -> Result<Layout, String> {
    let read = || -> mlua::Result<Layout> {
        let lua = &runtime.lua;
        let s = lua.create_table()?;
        for (k, v) in state {
            s.set(k.as_str(), v.as_str())?;
        }
        lua.globals().set("RENDER_VIEW_DATA", data.map_or(Ok(mlua::Value::Nil), |d| d.to_lua(lua))?)?;
        lua.globals().set("RENDER_VIEW_STATE", s)?;
        let t: Table = lua
            .load(format!(
                "local ctx = {{ game_dir = RENDER_GAME_DIR, db = RENDER_GFX, screen = {{ width = {width}, height = {height} }}, texture_size = RENDER_TEXTURE_SIZE, loc = RENDER_LOC }}
                 local items, report = require('render.windows.{name}').build(ctx, RENDER_VIEW_DATA, RENDER_VIEW_STATE)
                 RENDER_VIEW_DATA = nil
                 return {{ items = items, report = report }}"
            ))
            .eval()?;
        let report: Table = t.get("report")?;
        let mut rects = HashMap::new();
        if let Some(r) = report.get::<Option<Table>>("rects")? {
            for p in r.pairs::<String, Table>() {
                let (k, v) = p?;
                rects.insert(k, [v.get("x")?, v.get("y")?, v.get("w")?, v.get("h")?]);
            }
        }
        let missing = report.get::<Table>("missing_sprites")?.sequence_values::<String>().collect::<mlua::Result<Vec<_>>>()?;
        Ok(Layout { items: gui::read_items(t.get("items")?)?, missing, note: report.get::<Option<String>>("note")?.unwrap_or_default(), rects })
    };
    read().map_err(|e| format!("render.windows.{name}: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_cross_runtimes() {
        let a = Lua::new();
        let v: mlua::Value = a.load("return { 1, 'two', { x = 3.5, ok = true }, name = 'n' }").eval().unwrap();
        let v = Value::read(v, 0).unwrap();
        let b = Lua::new();
        b.globals().set("V", v.to_lua(&b).unwrap()).unwrap();
        let s: String = b.load("return V[1] .. V[2] .. V[3].x .. tostring(V[3].ok) .. V.name .. #V").eval().unwrap();
        assert_eq!(s, "1two3.5truen3");
    }
}
