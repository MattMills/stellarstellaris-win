//! The game's GUI from its files, laid out in Lua (`lua/render/gui.lua`) over the sprite and
//! font definitions of the .gfx files (`lua/render/gfx.lua`): the main screen's top bar bound to
//! the player's country in the world (`lua/render/topbar.lua`), and the front end's main menu
//! and load game window with their texts localised (`lua/render/frontend.lua`,
//! `sim/lua/engine/localisation.lua`).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use stellar_sim::mlua::{self, Table};
use stellar_sim::{Date, Runtime};

use crate::dds::Cache;
use crate::font::Font;

#[derive(Clone, Debug)]
pub enum GuiItem {
    Sprite {
        path: String,
        sprite: String,
        texture: String,
        kind: String,
        frame: u32,
        frames: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        border: Option<(f32, f32)>,
        /// a button (clickable), and what a click does
        button: bool,
        action: Option<String>,
        /// its colour multiplied in (the relation colour of a map label)
        tint: [f32; 4],
        /// the part of its frame drawn, u0..u1 (a progress bar's two textures; the rectangle cut
        /// the same)
        clip: [f32; 2],
    },
    Text {
        path: String,
        font: String,
        text: String,
        /// the text's parts and their colours (sRGB, 0..1)
        spans: Vec<(String, [f32; 3])>,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        format: String,
        valign: String,
    },
}

/// A text bound to the save: its element, the text and where its value came from.
#[derive(Clone, Debug)]
pub struct Bound {
    pub path: String,
    pub text: String,
    pub source: String,
}

#[derive(Clone)]
pub struct Topbar {
    pub items: Vec<GuiItem>,
    pub bound: Vec<Bound>,
    #[allow(dead_code)]
    pub country: i64,
    /// sprites the GUI names that have no definition or texture; element kinds skipped
    pub missing: Vec<String>,
    pub skipped: Vec<(String, u32)>,
    /// the .gfx database: files read, sprites by kind, fonts
    pub gfx_summary: String,
}

/// A laid-out window (or several): its items, sprites missing, and a note.
pub struct Layout {
    pub items: Vec<GuiItem>,
    pub missing: Vec<String>,
    pub note: String,
    /// the elements' rectangles (x, y, w, h) by path (layout_specs)
    pub rects: HashMap<String, [f32; 4]>,
}

/// Makes a runtime ready for the GUI: the renderer's Lua modules on the path, the game
/// directory, and RENDER_TEXTURE_SIZE (a texture's size, from the texture cache).
pub fn install(runtime: &Runtime, game_dir: &str, cache: &Rc<RefCell<Cache>>) -> mlua::Result<()> {
    let lua = &runtime.lua;
    let package: Table = lua.globals().get("package")?;
    let path: String = package.get("path")?;
    let dir = stellar_sim::runtime::repo_dir().join("sim/render/lua").to_string_lossy().replace('\\', "/");
    if !path.contains(&dir) {
        package.set("path", format!("{dir}/?.lua;{path}"))?;
    }
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
    // the subdirectories under a directory of the game (relative paths, recursively, sorted): the
    // .gfx files of interface/'s subfolders are loaded too (game_setup/customization.gfx has the
    // empire flags)
    let gd2 = game_dir.to_string();
    let subdirs = lua.create_function(move |_, rel: String| {
        fn walk(base: &std::path::Path, rel: &str, out: &mut Vec<String>) {
            let Ok(rd) = std::fs::read_dir(base.join(rel)) else { return };
            let mut dirs: Vec<String> = rd.flatten().filter(|e| e.path().is_dir()).map(|e| format!("{rel}/{}", e.file_name().to_string_lossy())).collect();
            dirs.sort();
            for d in dirs {
                out.push(d.clone());
                walk(base, &d, out);
            }
        }
        let mut out = Vec::new();
        walk(std::path::Path::new(&gd2), &rel, &mut out);
        Ok(out)
    })?;
    lua.globals().set("RENDER_SUBDIRS", subdirs)?;
    lua.globals().set("RENDER_GAME_DIR", game_dir.replace('\\', "/"))?;
    lua.load("if not RENDER_GFX then RENDER_GFX = require('render.gfx').load(RENDER_GAME_DIR) end").exec()
}

/// A runtime for the front end (no world): the GUI installed and the localisation loaded.
pub fn frontend_runtime(game_dir: &str, cache: &Rc<RefCell<Cache>>, language: &str) -> Result<(Runtime, String), String> {
    let rt = Runtime::new(Date::from_ymd(2200, 1, 1), 0).map_err(|e| format!("the Lua runtime: {e}"))?;
    install(&rt, game_dir, cache).map_err(|e| format!("gui: {e}"))?;
    let summary: String = rt
        .lua
        .load(format!(
            r#"
            RENDER_LOC = require('engine.localisation')
            RENDER_LOC.load(RENDER_GAME_DIR, {language:?})
            return string.format("%d keys from %d files of localisation/{language} in %.2f s",
                RENDER_LOC.keys, RENDER_LOC.files, RENDER_LOC.seconds)
            "#
        ))
        .eval()
        .map_err(|e| format!("localisation: {e}"))?;
    Ok((rt, summary))
}

fn colour(t: &Table) -> mlua::Result<[f32; 3]> {
    Ok([t.get(1)?, t.get(2)?, t.get(3)?])
}

/// The items of a layout table (render.gui's).
pub(crate) fn read_items(items: Table) -> mlua::Result<Vec<GuiItem>> {
    let mut out = Vec::new();
    for it in items.sequence_values::<Table>() {
        let it = it?;
        let kind: String = it.get("kind")?;
        if kind == "sprite" {
            let border: Option<Table> = it.get("border")?;
            let button: Option<Table> = it.get("button")?;
            out.push(GuiItem::Sprite {
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
                action: match &button {
                    Some(b) => b.get("action")?,
                    None => None,
                },
                button: button.is_some(),
                tint: match it.get::<Option<Table>>("tint")? {
                    Some(t) => [t.get(1)?, t.get(2)?, t.get(3)?, t.get::<Option<f32>>(4)?.unwrap_or(1.0)],
                    None => [1.0; 4],
                },
                clip: match it.get::<Option<Table>>("clip")? {
                    Some(c) => [c.get(1)?, c.get(2)?],
                    None => [0.0, 1.0],
                },
            });
        } else {
            let mut spans = Vec::new();
            match it.get::<Option<Table>>("spans")? {
                Some(s) => {
                    for sp in s.sequence_values::<Table>() {
                        let sp = sp?;
                        spans.push((sp.get("text")?, colour(&sp.get("colour")?)?));
                    }
                }
                None => spans.push((it.get("text")?, [1.0; 3])),
            }
            out.push(GuiItem::Text {
                path: it.get("path")?,
                font: it.get("font")?,
                text: it.get("text")?,
                spans,
                x: it.get("x")?,
                y: it.get("y")?,
                w: it.get("w")?,
                h: it.get("h")?,
                format: it.get("format")?,
                valign: it.get::<Option<String>>("valign")?.unwrap_or_else(|| "top".into()),
            });
        }
    }
    Ok(out)
}

fn missing(report: &Table) -> mlua::Result<Vec<String>> {
    report.get::<Table>("missing_sprites")?.sequence_values::<String>().collect()
}

/// What the top bar shows that the game decides at run time: the amounts and the date (from the
/// simulation's snapshot; None: read from the runtime's world), the clock's state.
pub struct TopbarState<'a> {
    pub texts: Option<&'a HashMap<String, String>>,
    pub date: Option<&'a str>,
    pub paused: bool,
    pub speed: u8,
    /// the speed's name as time_description shows it (GAME_SPEED_0 when paused), localised
    pub speed_name: Option<&'a str>,
}

/// Lays the top bar out for a screen of `width` x `height` (in the map's runtime).
pub fn topbar(runtime: &Runtime, game_dir: &str, cache: &Rc<RefCell<Cache>>, width: u32, height: u32, state: &TopbarState) -> Result<Topbar, String> {
    let read = || -> mlua::Result<Topbar> {
        install(runtime, game_dir, cache)?;
        let lua = &runtime.lua;
        let s = lua.create_table()?;
        if let Some(texts) = state.texts {
            let t = lua.create_table()?;
            for (k, v) in texts {
                t.set(k.as_str(), v.as_str())?;
            }
            s.set("text", t)?;
        }
        if let Some(d) = state.date {
            s.set("date", d)?;
        }
        s.set("paused", state.paused)?;
        s.set("speed", state.speed)?;
        if let Some(n) = state.speed_name {
            s.set("speed_name", n)?;
        }
        lua.globals().set("RENDER_TOPBAR_STATE", s)?;
        let t: Table = lua
            .load(format!(
                "return require('render.topbar').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_TOPBAR_STATE)"
            ))
            .eval()?;
        let items = read_items(t.get("items")?)?;
        let mut bound = Vec::new();
        for pair in t.get::<Table>("values")?.pairs::<String, Table>() {
            let (path, v) = pair?;
            bound.push(Bound { path, text: v.get("text")?, source: v.get("source")? });
        }
        bound.sort_by(|a, b| a.path.cmp(&b.path));
        let report: Table = t.get("report")?;
        let mut skipped = Vec::new();
        for pair in report.get::<Table>("skipped")?.pairs::<String, u32>() {
            skipped.push(pair?);
        }
        skipped.sort();
        let gfx_summary: String = lua
            .load(
                r#"
                local kinds = {}
                for k, c in pairs(RENDER_GFX.counts) do kinds[#kinds + 1] = k .. " " .. c end
                table.sort(kinds)
                local fonts = 0
                for _ in pairs(RENDER_GFX.fonts) do fonts = fonts + 1 end
                return string.format("%d .gfx files (%d did not parse): %s; %d bitmap fonts; read in %.2f s",
                    RENDER_GFX.files, #RENDER_GFX.errors, table.concat(kinds, ", "), fonts, RENDER_GFX.seconds)
                "#,
            )
            .eval()?;
        Ok(Topbar { items, bound, country: t.get("country")?, missing: missing(&report)?, skipped, gfx_summary })
    };
    read().map_err(|e| format!("render.topbar: {e}"))
}

/// The main menu for a screen of `width` x `height` (in the front end's runtime); `modal`: a
/// window is open over it.
pub fn menu(runtime: &Runtime, width: u32, height: u32, version: &str, modal: bool) -> Result<Layout, String> {
    let read = || -> mlua::Result<Layout> {
        let t: Table = runtime
            .lua
            .load(format!(
                "return require('render.frontend').menu(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, {version:?}, {modal})"
            ))
            .eval()?;
        let report: Table = t.get("report")?;
        let bg: Option<Table> = t.get("background")?;
        let note = match bg {
            Some(b) => format!(
                "background: common/frontend_backgrounds {} -> entity {} -> pdxmesh {} -> {} (a still of the 3D scene)",
                b.get::<String>("tag")?,
                b.get::<String>("entity")?,
                b.get::<String>("mesh")?,
                b.get::<String>("texture")?
            ),
            None => format!("background: none ({})", t.get::<Option<String>>("background_missing")?.unwrap_or_default()),
        };
        Ok(Layout { items: read_items(t.get("items")?)?, missing: missing(&report)?, note, rects: HashMap::new() })
    };
    read().map_err(|e| format!("render.frontend.menu: {e}"))
}

/// A save in the load window: the empire's name, the date, the file's name.
pub struct SaveRow<'a> {
    pub name: &'a str,
    pub date: &'a str,
    pub file: &'a str,
}

/// The load game window for a screen of `width` x `height`, one row per save (newest first).
pub fn load_window(runtime: &Runtime, width: u32, height: u32, saves: &[SaveRow]) -> Result<Layout, String> {
    let read = || -> mlua::Result<Layout> {
        let lua = &runtime.lua;
        let list = lua.create_table()?;
        for s in saves {
            let r = lua.create_table()?;
            r.set("name", s.name)?;
            r.set("date", s.date)?;
            r.set("file", s.file)?;
            list.push(r)?;
        }
        lua.globals().set("RENDER_SAVES", list)?;
        let t: Table = lua
            .load(format!(
                "return require('render.frontend').load_window(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_SAVES)"
            ))
            .eval()?;
        let report: Table = t.get("report")?;
        let shown: Option<u32> = report.get("saves_shown")?;
        Ok(Layout {
            items: read_items(t.get("items")?)?,
            missing: missing(&report)?,
            note: format!("{} of {} saves listed", shown.unwrap_or(0), saves.len()),
            rects: HashMap::new(),
        })
    };
    read().map_err(|e| format!("render.frontend.load_window: {e}"))
}

/// A row of the outliner: what it selects (its id), its name and the texts beside it.
#[derive(Clone, Debug, PartialEq)]
pub struct OutlinerRow {
    pub id: u32,
    pub name: String,
    pub sub: String,
    pub location: String,
    /// the strength (military power) shown, if any
    pub power: String,
    pub selected: bool,
}

/// A group of the outliner's Overview tab: its title (a localisation key), its kind (planet,
/// fleet, civilian, starbase) and rows.
#[derive(Clone, Debug, PartialEq)]
pub struct OutlinerGroup {
    pub title: String,
    pub kind: String,
    pub rows: Vec<OutlinerRow>,
    /// its header window (None: outliner_title_entry_window) and the count it shows (None: its
    /// rows')
    pub header: Option<String>,
    pub amount: Option<String>,
}

/// The window the selection opens: its kind (fleet, starbase, planet), id and texts.
#[derive(Clone, Debug, PartialEq)]
pub struct SelectedWindow {
    pub kind: String,
    pub id: u32,
    pub name: String,
    pub sub: String,
}

/// The outliner and the selection's window for a screen of `width` x `height` (render.windows,
/// in the front end's runtime: its localisation and .gfx database).
pub fn windows(runtime: &Runtime, width: u32, height: u32, outliner: &[OutlinerGroup], selected: Option<&SelectedWindow>) -> Result<Layout, String> {
    let read = || -> mlua::Result<Layout> {
        let lua = &runtime.lua;
        let data = lua.create_table()?;
        let groups = lua.create_table()?;
        for g in outliner {
            let t = lua.create_table()?;
            t.set("title", g.title.as_str())?;
            t.set("kind", g.kind.as_str())?;
            if let Some(h) = &g.header {
                t.set("header", h.as_str())?;
            }
            if let Some(a) = &g.amount {
                t.set("amount", a.as_str())?;
            }
            let rows = lua.create_table()?;
            for r in &g.rows {
                let row = lua.create_table()?;
                row.set("id", r.id)?;
                row.set("name", r.name.as_str())?;
                row.set("sub", r.sub.as_str())?;
                row.set("location", r.location.as_str())?;
                row.set("power", r.power.as_str())?;
                row.set("selected", r.selected)?;
                rows.push(row)?;
            }
            t.set("rows", rows)?;
            groups.push(t)?;
        }
        data.set("outliner", groups)?;
        if let Some(s) = selected {
            let t = lua.create_table()?;
            t.set("kind", s.kind.as_str())?;
            t.set("id", s.id)?;
            t.set("name", s.name.as_str())?;
            t.set("sub", s.sub.as_str())?;
            data.set("selected", t)?;
        }
        lua.globals().set("RENDER_WINDOWS", data)?;
        let t: Table = lua
            .load(format!(
                "local items, report = require('render.windows').build(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_WINDOWS) return {{ items = items, report = report }}"
            ))
            .eval()?;
        let report: Table = t.get("report")?;
        Ok(Layout { items: read_items(t.get("items")?)?, missing: missing(&report)?, note: String::new(), rects: HashMap::new() })
    };
    read().map_err(|e| format!("render.windows: {e}"))
}

/// A window to lay out (render.windows.specs): its file and name, and what the game decides at
/// run time: the children drawn (`only`, none: all) and hidden, texts, sprite frames, button
/// actions, sizes, a path prefix, the rectangle it is laid out in (none: the screen).
#[derive(Clone, Debug, Default)]
pub struct WindowSpec {
    pub file: String,
    pub window: String,
    pub only: Option<Vec<String>>,
    pub hide: Vec<String>,
    pub text: Vec<(String, String)>,
    pub frames: Vec<(String, u32)>,
    pub actions: Vec<(String, String)>,
    pub sizes: Vec<(String, (f32, f32))>,
    pub positions: Vec<(String, (f32, f32))>,
    pub sprites: Vec<(String, String)>,
    pub tints: Vec<(String, [f32; 4])>,
    pub prefix: Option<String>,
    pub parent: Option<[f32; 4]>,
}

impl WindowSpec {
    pub fn new(file: &str, window: &str) -> WindowSpec {
        WindowSpec { file: file.into(), window: window.into(), ..Default::default() }
    }
}

/// Windows laid out for a screen of `width` x `height`, in a runtime with the GUI installed (the
/// front end's: localisation too).
pub fn layout_specs(runtime: &Runtime, width: u32, height: u32, specs: &[WindowSpec]) -> Result<Layout, String> {
    let read = || -> mlua::Result<Layout> {
        let lua = &runtime.lua;
        let list = lua.create_table()?;
        for s in specs {
            let t = lua.create_table()?;
            t.set("file", s.file.as_str())?;
            t.set("window", s.window.as_str())?;
            if let Some(only) = &s.only {
                t.set("only", lua.create_sequence_from(only.iter().map(|v| v.as_str()))?)?;
            }
            t.set("hide", lua.create_sequence_from(s.hide.iter().map(|v| v.as_str()))?)?;
            let map = |pairs: &[(String, String)]| -> mlua::Result<Table> {
                let m = lua.create_table()?;
                for (k, v) in pairs {
                    m.set(k.as_str(), v.as_str())?;
                }
                Ok(m)
            };
            t.set("text", map(&s.text)?)?;
            t.set("actions", map(&s.actions)?)?;
            let frames = lua.create_table()?;
            for (k, v) in &s.frames {
                frames.set(k.as_str(), *v)?;
            }
            t.set("frames", frames)?;
            let sizes = lua.create_table()?;
            for (k, (w, h)) in &s.sizes {
                sizes.set(k.as_str(), lua.create_sequence_from([*w, *h])?)?;
            }
            t.set("sizes", sizes)?;
            let positions = lua.create_table()?;
            for (k, (x, y)) in &s.positions {
                positions.set(k.as_str(), lua.create_sequence_from([*x, *y])?)?;
            }
            t.set("positions", positions)?;
            t.set("sprites", map(&s.sprites)?)?;
            let tints = lua.create_table()?;
            for (k, c) in &s.tints {
                tints.set(k.as_str(), lua.create_sequence_from(*c)?)?;
            }
            t.set("tints", tints)?;
            if let Some(p) = &s.prefix {
                t.set("prefix", p.as_str())?;
            }
            if let Some(r) = s.parent {
                let p = lua.create_table()?;
                p.set("x", r[0])?;
                p.set("y", r[1])?;
                p.set("w", r[2])?;
                p.set("h", r[3])?;
                t.set("parent", p)?;
            }
            list.push(t)?;
        }
        lua.globals().set("RENDER_SPECS", list)?;
        let t: Table = lua
            .load(format!(
                "local items, report = require('render.windows').specs(RENDER_GAME_DIR, RENDER_GFX, {{ width = {width}, height = {height} }}, RENDER_TEXTURE_SIZE, RENDER_LOC, RENDER_SPECS) return {{ items = items, report = report }}"
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
        Ok(Layout { items: read_items(t.get("items")?)?, missing: missing(&report)?, note: String::new(), rects })
    };
    read().map_err(|e| format!("render.windows.specs: {e}"))
}

/// A sprite's frame size in pixels (its texture's width over its frames).
pub fn sprite_size(runtime: &Runtime, cache: &Rc<RefCell<Cache>>, game_dir: &str, name: &str) -> Option<(f32, f32)> {
    let s: Table = runtime.lua.load(format!("return RENDER_GFX.sprites[{name:?}]")).eval::<Option<Table>>().ok()??;
    let texture: String = s.get::<Option<String>>("texture").ok()??;
    let frames: u32 = s.get::<Option<u32>>("frames").ok().flatten().unwrap_or(1).max(1);
    let mut c = cache.borrow_mut();
    let img = c.get(game_dir, &texture).ok()?;
    Some((img.width as f32 / frames as f32, img.height as f32))
}

/// A flagSpriteType's definition from the .gfx database (render.gfx), if `name` is one.
pub fn flag_sprite(runtime: &Runtime, name: &str) -> Option<crate::flag::FlagSprite> {
    let s: Table = runtime.lua.load(format!("return RENDER_GFX.sprites[{name:?}]")).eval::<Option<Table>>().ok()??;
    if s.get::<Option<String>>("kind").ok()?? != "flagSpriteType" {
        return None;
    }
    let rect = |p: &str, z: &str| -> Option<([f32; 2], [f32; 2])> {
        let a: Table = s.get::<Option<Table>>(p).ok()??;
        let b: Table = s.get::<Option<Table>>(z).ok()??;
        Some(([a.get(1).ok()?, a.get(2).ok()?], [b.get(1).ok()?, b.get(2).ok()?]))
    };
    Some(crate::flag::FlagSprite {
        frame: s.get::<Option<String>>("texture").ok()??,
        mask: s.get("mask").ok().flatten(),
        texture_size: s.get("texture_size").ok().flatten(),
        bg: rect("bg_position", "bg_size"),
        symbol: rect("symbol_position", "symbol_size"),
        mask_rect: rect("mask_offset", "mask_size"),
    })
}

/// Names from the save, localised (render.names, with the front end's localisation; a runtime
/// that has none, a save loaded without the front end, loads the English one first).
pub fn format_names(runtime: &Runtime, names: &[&crate::galaxy::Name]) -> Result<Vec<String>, String> {
    let read = || -> mlua::Result<Vec<String>> {
        let lua = &runtime.lua;
        let list = lua.create_table()?;
        for n in names {
            list.push(n.to_lua(lua)?)?;
        }
        lua.globals().set("RENDER_NAMES", list)?;
        lua.load(
            "if not RENDER_LOC and RENDER_GAME_DIR then
                RENDER_LOC = require('engine.localisation')
                if (RENDER_LOC.keys or 0) == 0 then RENDER_LOC.load(RENDER_GAME_DIR, 'english') end
            end
            local f = require('render.names').format local out = {} for i, n in ipairs(RENDER_NAMES) do out[i] = f(RENDER_LOC, n) end return out",
        )
        .eval()
    };
    read().map_err(|e| format!("render.names: {e}"))
}

/// The fonts a list of items uses, from the .gfx `bitmapfonts`, added to `out`.
pub fn fonts(runtime: &Runtime, game_dir: &str, items: &[GuiItem], out: &mut HashMap<String, Font>) -> Result<(), String> {
    for item in items {
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
    Ok(())
}
