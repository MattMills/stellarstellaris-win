//! The planet view (interface/planet_view.gui, CPlanetView; docs/windows/planet.md): the planet's
//! data read from the save's world (`render.windows.planet`'s `data`, in the map's runtime) and
//! handed to the front end's runtime, where render.windows lays the window out with it
//! (`RENDER_PLANET`); which tab shows.

use crate::Map;
use stellar_sim::mlua;
use stellar_sim::runtime::Runtime;

/// The tabs (CPlanetView +0xc3a0: 1 summary, 2 management, 3 population, 4 armies; the holdings
/// tab is the corporate one), as the actions and `open_planet` name them.
pub const TABS: [&str; 5] = ["summary", "management", "population", "armies", "corporate"];

/// What the window shows: the planet it was opened for and its tab. Another planet keeps the tab
/// (CInGameIdler::ShowPlanetView passes tab 0, which CPlanetView::Show keeps; the game's frames:
/// the holdings tab stays on for the next planet); where the tab cannot open the window shows the
/// summary (CanOpenTab, render.windows.planet).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub id: Option<u32>,
    pub tab: String,
    /// the colonize window (colonize_planet_view.gui, CSurfaceView), open for this planet
    pub colonize: Option<u32>,
}

impl State {
    /// The tab asked for planet `id`.
    pub fn tab_for(&mut self, id: u32) -> &str {
        if !TABS.contains(&self.tab.as_str()) {
            self.tab = "summary".into();
        }
        self.id = Some(id);
        &self.tab
    }

    /// Shows `tab` (one of [`TABS`]) for planet `id`.
    pub fn open(&mut self, id: u32, tab: &str) -> Result<(), String> {
        if !TABS.contains(&tab) {
            return Err(format!("no planet view tab {tab} ({})", TABS.join(", ")));
        }
        self.id = Some(id);
        self.tab = tab.into();
        Ok(())
    }
}

/// The planet's data (a Lua expression, render.windows.planet.encode) from the map's world, or
/// None when the map has no world (a running simulation: its world is on its own thread).
pub fn data(map: &Map, id: u32) -> Result<Option<String>, String> {
    if !map.world {
        return Ok(None);
    }
    let gd = map.game_dir.replace('\\', "/");
    map.runtime
        .lua
        .load(format!(
            "local p = require('render.windows.planet') local d = p.data({gd:?}, {id}) return d and p.encode(d)"
        ))
        .eval::<Option<String>>()
        .map_err(|e| format!("render.windows.planet.data: {e}"))
}

/// Hands planet `id`'s data and the tab shown to the front end's runtime (`RENDER_PLANET =
/// { id, tab, colonize, data }`, render.windows reads it); returns the planet's owner (a country
/// id).
pub fn prepare(front: &Runtime, map: &Map, id: u32, tab: &str, colonize: bool) -> Result<Option<u32>, String> {
    let data = data(map, id)?;
    let lua = &front.lua;
    let set = || -> mlua::Result<Option<u32>> {
        let t = lua.create_table()?;
        t.set("id", id)?;
        t.set("tab", tab)?;
        t.set("colonize", colonize)?;
        let mut owner = None;
        if let Some(d) = &data {
            lua.globals().set("RENDER_PLANET_TEXT", d.as_str())?;
            let decoded: mlua::Value = lua.load("local t = RENDER_PLANET_TEXT RENDER_PLANET_TEXT = nil return require('render.windows.planet').decode(t)").eval()?;
            if let mlua::Value::Table(dt) = &decoded {
                owner = dt.get::<Option<u32>>("owner")?;
                // the triggers the script layer could not evaluate (their parts drawn as false)
                if let Some(errors) = dt.get::<Option<Vec<String>>>("errors")? {
                    for e in errors {
                        eprintln!("planet view {id}: trigger: {e}");
                    }
                }
            }
            t.set("data", decoded)?;
        }
        lua.globals().set("RENDER_PLANET", t)?;
        Ok(owner)
    };
    set().map_err(|e| format!("planet view: {e}"))
}

/// The planet view's portraits among `items` (render.windows.planet names them
/// `@planet_portrait:PICTURE:CITY:LEVEL:TOP:HEIGHT`): composed once into the map's textures.
/// The game draws the planet's picture as a portrait (`CPortraitObject::SetEverythingByColonyCarrier`,
/// GFX_portrait_planet): `gfx/portraits/environments/<picture>_sky.dds` and its layers
/// `_l01`.. over it **[V]** (the files), each with the owner's city set's layer of the same number
/// (`gfx/portraits/city_sets/<city culture>_city_lNN.dds`) up to the colony's level **[I]** (the
/// game's frame of the capital: the spires of the molluscoid set over the ocean's islands); the
/// rows the window shows (its `portrait` container clips the 800 x 400 picture).
pub fn portraits(map: &mut Map, items: &mut [crate::gui::GuiItem], unowned: bool) {
    for it in items.iter_mut() {
        let crate::gui::GuiItem::Sprite { texture, path, kind, sprite, .. } = it else { continue };
        // an unowned planet's flag: the pre-communications flag (PRE_COMMUNICATIONS_EMPIRE_FLAG,
        // flags/special/unknown.dds, CPlanetView::UpdatePlanetPortrait) on a black field **[I]**
        if unowned && kind == "flagSpriteType" && path == "/planet_view/planet_portrait_window/flag" {
            let name = format!("@flag:unknown:{sprite}");
            if map.textures.find(&name).is_none() {
                let _ = crate::gui::install(&map.runtime, &map.game_dir, &map.cache);
                let flag = crate::galaxy::Flag {
                    icon: ("special".into(), "unknown.dds".into()),
                    background: ("backgrounds".into(), "00_solid.dds".into()),
                    colours: vec![[0.02, 0.03, 0.03]; 4],
                };
                let def = crate::gui::flag_sprite(&map.runtime, sprite);
                let img = def.and_then(|def| crate::flag::compose(&mut map.cache.borrow_mut(), &map.game_dir, &def, &flag, [1.0; 4]));
                match img {
                    Some(img) => {
                        map.textures.add(&name, std::sync::Arc::new(img));
                    }
                    None => continue,
                }
            }
            *texture = name;
            continue;
        }
        if map.textures.find(texture).is_some() {
            continue;
        }
        // an icon the .gui turns a quarter (`rotation = 1.56`, which render.gui does not draw):
        // its texture turned, the image's bottom to its right
        if let Some(path) = texture.strip_prefix("@planet_rot90:") {
            let img = crate::dds::find_case_insensitive(&map.game_dir, path).and_then(|f| crate::dds::load(&f).ok());
            if let Some(img) = img {
                let (w, h) = (img.width as usize, img.height as usize);
                let mut rgba = vec![0u8; w * h * 4];
                for y in 0..h {
                    for x in 0..w {
                        // (x, y) -> (y, w - 1 - x) in an h x w image: a quarter turn, the
                        // bottom edge becoming the right one
                        let (nx, ny) = (y, w - 1 - x);
                        let (s, d) = ((y * w + x) * 4, (ny * h + nx) * 4);
                        rgba[d..d + 4].copy_from_slice(&img.rgba[s..s + 4]);
                    }
                }
                let turned = crate::dds::Image { width: h as u32, height: w as u32, rgba, format: "planet view rotated".into() };
                map.textures.add(texture, std::sync::Arc::new(turned));
            }
            continue;
        }
        if !texture.starts_with("@planet_portrait:") {
            continue;
        }
        match compose(&map.game_dir, texture) {
            Some(img) => {
                map.textures.add(texture, std::sync::Arc::new(img));
            }
            None => eprintln!("planet view: no portrait {texture}"),
        }
    }
}

fn compose(game_dir: &str, name: &str) -> Option<crate::dds::Image> {
    let mut p = name.trim_start_matches("@planet_portrait:").split(':');
    let (picture, city, level, top, height) = (p.next()?, p.next()?, p.next()?.parse::<u32>().ok()?, p.next()?.parse::<u32>().ok()?, p.next()?.parse::<u32>().ok()?);
    let load = |rel: String| crate::dds::find_case_insensitive(game_dir, &rel).and_then(|f| crate::dds::load(&f).ok());
    let mut img = load(format!("gfx/portraits/environments/{picture}_sky.dds"))?;
    let (w, h) = (img.width as usize, img.height as usize);
    let mut over = |layer: crate::dds::Image| {
        if layer.width as usize != w || layer.height as usize != h {
            return;
        }
        for (d, s) in img.rgba.chunks_exact_mut(4).zip(layer.rgba.chunks_exact(4)) {
            let a = s[3] as f32 / 255.0;
            for c in 0..3 {
                d[c] = (s[c] as f32 * a + d[c] as f32 * (1.0 - a)).round() as u8;
            }
            d[3] = (s[3] as f32 + d[3] as f32 * (1.0 - a)).round().min(255.0) as u8;
        }
    };
    for i in 1..=6u32 {
        if let Some(l) = load(format!("gfx/portraits/environments/{picture}_l{i:02}.dds")) {
            over(l);
        }
        if !city.is_empty() && i <= level {
            if let Some(l) = load(format!("gfx/portraits/city_sets/{city}_city_l{i:02}.dds")) {
                over(l);
            }
        }
    }
    // the rows (and, given, the columns) the window shows
    let left = p.next().and_then(|v| v.parse::<usize>().ok()).unwrap_or(0).min(w);
    let cols = p.next().and_then(|v| v.parse::<usize>().ok()).unwrap_or(w).min(w - left);
    let top = (top as usize).min(h);
    let rows = (height as usize).min(h - top);
    let mut rgba = Vec::with_capacity(rows * cols * 4);
    for y in top..top + rows {
        rgba.extend_from_slice(&img.rgba[(y * w + left) * 4..(y * w + left + cols) * 4]);
    }
    Some(crate::dds::Image { width: cols as u32, height: rows as u32, rgba, format: "planet portrait".into() })
}

/// Forgets the window's data in the front end's runtime (another selection).
pub fn clear(front: &Runtime) {
    let _ = front.lua.globals().set("RENDER_PLANET", mlua::Value::Nil);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn another_planet_keeps_the_tab() {
        let mut s = State::default();
        assert_eq!(s.tab_for(5), "summary");
        s.open(5, "armies").unwrap();
        assert_eq!(s.tab_for(5), "armies");
        assert_eq!(s.tab_for(6), "armies");
        assert!(s.open(6, "nothing").is_err());
        assert_eq!(s.tab_for(6), "armies");
    }
}
