//! The economy's windows (docs/windows/economy.md): the market (interface/market_view.gui) and
//! the expansion planner (interface/expansion_planner_view.gui), opened from the left bar.
//!
//! What a window shows is read from the save's world (`render.windows.<view>.data`, in the
//! map's runtime, which holds the world until a simulation runs) and laid out in the front end's
//! runtime (its localisation and .gfx database: `render.windows.<view>.build`). The data crosses
//! between the two runtimes as a Lua table constructor (`render.windows.serial`).

use std::collections::HashMap;

use stellar_sim::mlua::Table;

use crate::app::App;
use crate::gui::{self, GuiItem};

/// The Lua module that draws a view: market -> render.windows.market.
fn module(view: &str) -> &'static str {
    match view {
        "expansion_planner" => "render.windows.expansion",
        _ => "render.windows.market",
    }
}

fn state_table(lua: &stellar_sim::mlua::Lua, state: &HashMap<String, String>) -> stellar_sim::mlua::Result<Table> {
    let t = lua.create_table()?;
    for (k, v) in state {
        t.set(k.as_str(), v.as_str())?;
    }
    Ok(t)
}

/// The view's data from the world, as a Lua table constructor (None without a world).
fn data(app: &App, view: &str) -> Result<Option<String>, String> {
    let Some(map) = app.map.as_ref() else { return Ok(None) };
    if !map.world {
        return Ok(None);
    }
    let lua = &map.runtime.lua;
    let read = || -> stellar_sim::mlua::Result<String> {
        lua.globals().set("RENDER_VIEW_STATE", state_table(lua, &app.view_state)?)?;
        lua.load(format!(
            "local m = require('{}') return require('render.windows.serial').dump(m.data({}, RENDER_VIEW_STATE, RENDER_GAME_DIR))",
            module(view),
            map.galaxy.player
        ))
        .eval()
    };
    // the map's runtime has the game's files once the top bar is laid out; RENDER_GAME_DIR for
    // the definitions the data reads
    let _ = gui::install(&map.runtime, &map.game_dir, &map.cache);
    read().map(Some).map_err(|e| format!("{}.data: {e}", module(view)))
}

/// The view's window: its items, the save's values in it.
pub fn items(app: &mut App, view: &str) -> Result<Vec<GuiItem>, String> {
    let (w, h) = app.size;
    let data = data(app, view)?;
    let lua = &app.runtime.lua;
    let read = || -> stellar_sim::mlua::Result<gui::Layout> {
        lua.globals().set("RENDER_VIEW_STATE", state_table(lua, &app.view_state)?)?;
        lua.globals().set("RENDER_VIEW_DATA", data.as_deref().unwrap_or("return nil"))?;
        let t: Table = lua
            .load(format!(
                "local d = load(RENDER_VIEW_DATA)() local items, report = require('{}').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {w}, height = {h} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, d, RENDER_VIEW_STATE) return {{ items = items, report = report }}",
                module(view)
            ))
            .eval()?;
        gui::read_layout(t)
    };
    let layout = read().map_err(|e| format!("{}.build: {e}", module(view)))?;
    if !layout.missing.is_empty() {
        app.log.push(format!("{view}: sprites missing: {}", layout.missing.join(", ")));
    }
    let mut items = layout.items;
    // the flags among them (the market leader's), as the map composes them
    if let Some(map) = app.map.as_mut() {
        let player = map.player_country();
        map.flags(&mut items, player);
    }
    Ok(items)
}
