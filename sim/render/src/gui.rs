//! The top bar from the game's GUI files, laid out in Lua (`lua/render/gui.lua`,
//! `lua/render/topbar.lua`) over the sprite and font definitions of the .gfx files
//! (`lua/render/gfx.lua`), and bound to the player's country in the world.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use stellar_sim::mlua::{self, Table};
use stellar_sim::Runtime;

use crate::dds::Cache;
use crate::font::Font;

#[derive(Clone, Debug)]
pub enum GuiItem {
    Sprite {
        path: String,
        sprite: String,
        texture: String,
        #[allow(dead_code)]
        kind: String,
        frame: u32,
        frames: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        border: Option<(f32, f32)>,
    },
    Text {
        path: String,
        font: String,
        text: String,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        format: String,
    },
}

/// A text bound to the save: its element, the text and where its value came from.
#[derive(Clone, Debug)]
pub struct Bound {
    pub path: String,
    pub text: String,
    pub source: String,
}

pub struct Topbar {
    pub items: Vec<GuiItem>,
    pub bound: Vec<Bound>,
    pub country: i64,
    /// sprites the GUI names that have no definition or texture; element kinds skipped
    pub missing: Vec<String>,
    pub skipped: Vec<(String, u32)>,
    /// the .gfx database: files read, sprites by kind, fonts
    pub gfx_summary: String,
}

/// Lays the top bar out for a screen of `width` x `height`. The sprite database is read once and
/// kept in the Lua state (`RENDER_GFX`).
pub fn topbar(runtime: &Runtime, game_dir: &str, cache: &Rc<RefCell<Cache>>, width: u32, height: u32) -> Result<Topbar, String> {
    let read = || -> mlua::Result<Topbar> {
        let lua = &runtime.lua;
        let c = cache.clone();
        let gd = game_dir.to_string();
        let size = lua.create_function(move |_, path: String| {
            let mut c = c.borrow_mut();
            Ok(match c.get(&gd, &path) {
                Ok(img) => (Some(img.width), Some(img.height)),
                Err(_) => (None, None),
            })
        })?;
        lua.globals().set("RENDER_TEXTURE_SIZE", size)?;
        lua.globals().set("RENDER_GAME_DIR", game_dir.replace('\\', "/"))?;
        let t: Table = lua
            .load(format!(
                r#"
                if not RENDER_GFX then RENDER_GFX = require('render.gfx').load(RENDER_GAME_DIR) end
                return require('render.topbar').build(RENDER_GAME_DIR, RENDER_GFX,
                    {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE)
                "#
            ))
            .eval()?;
        let mut items = Vec::new();
        for it in t.get::<Table>("items")?.sequence_values::<Table>() {
            let it = it?;
            let kind: String = it.get("kind")?;
            if kind == "sprite" {
                let border: Option<Table> = it.get("border")?;
                items.push(GuiItem::Sprite {
                    path: it.get("path")?,
                    sprite: it.get("sprite")?,
                    texture: it.get("texture")?,
                    kind: it.get("sprite_kind")?,
                    frame: it.get::<f64>("frame")? as u32,
                    frames: it.get::<f64>("frames")? as u32,
                    x: it.get("x")?,
                    y: it.get("y")?,
                    w: it.get("w")?,
                    h: it.get("h")?,
                    border: match border {
                        Some(b) => Some((b.get("x")?, b.get("y")?)),
                        None => None,
                    },
                });
            } else {
                items.push(GuiItem::Text {
                    path: it.get("path")?,
                    font: it.get("font")?,
                    text: it.get("text")?,
                    x: it.get("x")?,
                    y: it.get("y")?,
                    w: it.get("w")?,
                    h: it.get("h")?,
                    format: it.get("format")?,
                });
            }
        }
        let mut bound = Vec::new();
        for pair in t.get::<Table>("values")?.pairs::<String, Table>() {
            let (path, v) = pair?;
            bound.push(Bound { path, text: v.get("text")?, source: v.get("source")? });
        }
        bound.sort_by(|a, b| a.path.cmp(&b.path));
        let report: Table = t.get("report")?;
        let missing: Vec<String> = report.get::<Table>("missing_sprites")?.sequence_values::<String>().collect::<mlua::Result<_>>()?;
        let mut skipped = Vec::new();
        for pair in report.get::<Table>("skipped")?.pairs::<String, u32>() {
            skipped.push(pair?);
        }
        skipped.sort();
        let gfx_summary: String = lua
            .load(
                r#"
                local n, kinds = 0, {}
                for k, c in pairs(RENDER_GFX.counts) do kinds[#kinds + 1] = k .. " " .. c end
                table.sort(kinds)
                local fonts = 0
                for _ in pairs(RENDER_GFX.fonts) do fonts = fonts + 1 end
                return string.format("%d .gfx files (%d did not parse): %s; %d bitmap fonts; read in %.2f s",
                    RENDER_GFX.files, #RENDER_GFX.errors, table.concat(kinds, ", "), fonts, RENDER_GFX.seconds)
                "#,
            )
            .eval()?;
        Ok(Topbar { items, bound, country: t.get("country")?, missing, skipped, gfx_summary })
    };
    read().map_err(|e| format!("render.topbar: {e}"))
}

/// The fonts the top bar's texts use, from the .gfx `bitmapfonts` (after [`topbar`]).
pub fn fonts(runtime: &Runtime, game_dir: &str, bar: &Topbar) -> Result<HashMap<String, Font>, String> {
    let mut out = HashMap::new();
    for item in &bar.items {
        if let GuiItem::Text { font, .. } = item {
            if out.contains_key(font) {
                continue;
            }
            let file: Option<String> = runtime
                .lua
                .load(format!("local f = RENDER_GFX.fonts[{font:?}] return f and f.file"))
                .eval()
                .map_err(|e| e.to_string())?;
            let file = file.ok_or(format!("font {font}: no bitmapfont in the .gfx files"))?;
            out.insert(font.clone(), Font::load(game_dir, font, &file)?);
        }
    }
    Ok(out)
}
