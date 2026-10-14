//! The galaxy map of a save: the world loaded through the Lua runtime
//! (`stellar_sim::Runtime::load_world`), then read with the query in `lua/render/galaxy.lua`,
//! with the game files it is drawn with (star classes, colours, defines).

use stellar_sim::mlua::{self, Table};
use stellar_sim::{save, Runtime};

/// A star system: its position in map units (the save's `coordinate`), its star and the index of
/// the country that owns it in [`Galaxy::countries`].
#[derive(Clone, Debug)]
pub struct System {
    /// The save's id (of the galactic_object).
    #[allow(dead_code)]
    pub id: u32,
    pub x: f32,
    pub y: f32,
    pub owner: Option<usize>,
    pub star_class: String,
    /// the star's sprite on the galaxy map (a path in the game directory), "" if none
    pub texture: String,
    pub icon_scale: f32,
}

/// A country that owns at least one system, with its two map colours.
#[derive(Clone, Debug)]
pub struct Country {
    pub id: u32,
    pub name: String,
    pub kind: String,
    /// The names of its first two flag colours.
    pub colour_names: [String; 2],
    /// Where the colours came from: "map" (flags/colors.txt), "named" (common/named_colors), "".
    pub colour_source: String,
    /// sRGB, 0..1: the border's edge (the first colour) and fill (the second).
    pub primary: [f32; 3],
    pub secondary: [f32; 3],
    pub systems: usize,
}

#[derive(Clone, Debug)]
pub struct Galaxy {
    pub date: String,
    pub systems: Vec<System>,
    /// Indices into `systems`, each lane once.
    pub lanes: Vec<(u32, u32)>,
    pub countries: Vec<Country>,
    /// NGraphics.HYPERLANE_DEFAULT_COLOR (RGBA, 0..1)
    pub hyperlane_colour: [f32; 4],
    /// NGraphics.GALAXY_STAR_ICON_SCALE, BORDER_SYSTEM_RADIUS, BORDER_HYPERLANE_THICKNESS
    pub star_icon_scale: f32,
    pub border_system_radius: f32,
    #[allow(dead_code)]
    pub border_hyperlane_thickness: f32,
    /// NGraphics.BORDER_TEXTURE_SIZE, GALAXY_DUST_SIZE, GALAXY_DUST_SIZE_EXTRA
    pub border_texture_size: u32,
    pub dust_size: f32,
    pub dust_size_extra: f32,
    pub fleets: Vec<Fleet>,
    pub nebulae: Vec<Nebula>,
    /// What the Lua query read (counts and timing).
    pub notes: String,
}

/// A fleet on the map: its position (its system's, or the galaxy coordinate between systems),
/// owner, movement state, and where an FTL jump takes it.
#[derive(Clone, Debug)]
pub struct Fleet {
    pub id: u32,
    pub owner: Option<usize>,
    pub x: f32,
    pub y: f32,
    pub state: String,
    pub station: bool,
    pub ships: u32,
    pub military: bool,
    pub from: Option<(f32, f32)>,
    pub to: Option<(f32, f32)>,
}

#[derive(Clone, Debug)]
pub struct Nebula {
    pub x: f32,
    pub y: f32,
    pub radius: f32,
    #[allow(dead_code)]
    pub name: String,
}

/// The renderer's Lua directory (`sim/render/lua`), for `package.path`.
fn lua_dir() -> String {
    concat!(env!("CARGO_MANIFEST_DIR"), "/lua").replace('\\', "/")
}

/// A runtime with the save's world loaded (only the world: no definitions, no script layer) and
/// the renderer's Lua modules on the path.
pub fn runtime(save_path: &str) -> Result<Runtime, String> {
    let t0 = std::time::Instant::now();
    let gamestate = save::read_gamestate(save_path)?;
    let date = save::date_of(&gamestate).ok_or("the save has no date")?;
    let runtime = Runtime::new(date, 0).map_err(|e| format!("the Lua runtime: {e}"))?;
    let loaded = runtime.load_world(&gamestate).map_err(|e| format!("load_world: {e}"))?;
    drop(gamestate);
    eprintln!("{loaded}");
    let path = format!("{}/?.lua", lua_dir());
    let package: Table = runtime.lua.globals().get("package").map_err(|e| e.to_string())?;
    let old: String = package.get("path").map_err(|e| e.to_string())?;
    package.set("path", format!("{path};{old}")).map_err(|e| e.to_string())?;
    eprintln!("world loaded in {:.1} s", t0.elapsed().as_secs_f64());
    Ok(runtime)
}

/// A runtime with the game's files and the save loaded for a simulation (the definitions, the
/// script layer, the world), and the renderer's Lua modules on the path.
pub fn sim_runtime(game_dir: &str, save_path: &str) -> Result<Runtime, String> {
    let t0 = std::time::Instant::now();
    let gamestate = save::read_gamestate(save_path)?;
    let date = save::date_of(&gamestate).ok_or("the save has no date")?;
    let runtime = Runtime::new(date, 0).map_err(|e| format!("the Lua runtime: {e}"))?;
    let loaded = runtime.load(game_dir, Some(&gamestate), None).map_err(|e| format!("load: {e}"))?;
    drop(gamestate);
    eprintln!("{loaded}");
    let path = format!("{}/?.lua", lua_dir());
    let package: Table = runtime.lua.globals().get("package").map_err(|e| e.to_string())?;
    let old: String = package.get("path").map_err(|e| e.to_string())?;
    package.set("path", format!("{path};{old}")).map_err(|e| e.to_string())?;
    eprintln!("simulation loaded in {:.1} s", t0.elapsed().as_secs_f64());
    Ok(runtime)
}

fn rgb(t: &Table) -> mlua::Result<[f32; 3]> {
    Ok([t.get::<f32>(1)?, t.get::<f32>(2)?, t.get::<f32>(3)?])
}

/// The galaxy map of a runtime's world.
pub fn extract(runtime: &Runtime, game_dir: &str) -> Result<Galaxy, String> {
    let read = || -> mlua::Result<Galaxy> {
        let galaxy: Table = runtime.lua.load("return require('render.galaxy')").eval()?;
        let extract: mlua::Function = galaxy.get("extract")?;
        let g: Table = extract.call(game_dir.replace('\\', "/"))?;
        let mut countries = Vec::new();
        for c in g.get::<Table>("countries")?.sequence_values::<Table>() {
            let c = c?;
            let names: Table = c.get("colours")?;
            countries.push(Country {
                id: c.get("id")?,
                name: c.get("name")?,
                kind: c.get("kind")?,
                colour_names: [names.get(1)?, names.get(2)?],
                colour_source: c.get("source")?,
                primary: rgb(&c.get("primary")?)?,
                secondary: rgb(&c.get("secondary")?)?,
                systems: 0,
            });
        }
        let mut systems = Vec::new();
        for s in g.get::<Table>("systems")?.sequence_values::<Table>() {
            let s = s?;
            let owner_id: i64 = s.get("owner")?;
            let owner = if owner_id >= 0 { countries.iter().position(|c| c.id as i64 == owner_id) } else { None };
            if let Some(o) = owner {
                countries[o].systems += 1;
            }
            systems.push(System {
                id: s.get("id")?,
                x: s.get("x")?,
                y: s.get("y")?,
                owner,
                star_class: s.get("star_class")?,
                texture: s.get("texture")?,
                icon_scale: s.get("icon_scale")?,
            });
        }
        let mut lanes = Vec::new();
        for l in g.get::<Table>("lanes")?.sequence_values::<Table>() {
            let l = l?;
            lanes.push((l.get::<u32>(1)? - 1, l.get::<u32>(2)? - 1));
        }
        let hc: Table = g.get("hyperlane_colour")?;
        let mut fleets = Vec::new();
        for f in g.get::<Table>("fleets")?.sequence_values::<Table>() {
            let f = f?;
            let owner_id: i64 = f.get("owner")?;
            let pair = |a: &str, b: &str| -> mlua::Result<Option<(f32, f32)>> {
                Ok(match (f.get::<Option<f32>>(a)?, f.get::<Option<f32>>(b)?) {
                    (Some(x), Some(y)) => Some((x, y)),
                    _ => None,
                })
            };
            fleets.push(Fleet {
                id: f.get("id")?,
                owner: if owner_id >= 0 { countries.iter().position(|c| c.id as i64 == owner_id) } else { None },
                x: f.get("x")?,
                y: f.get("y")?,
                state: f.get("state")?,
                station: f.get("station")?,
                ships: f.get("ships")?,
                military: f.get("military")?,
                from: pair("from_x", "from_y")?,
                to: pair("to_x", "to_y")?,
            });
        }
        let mut nebulae = Vec::new();
        for n in g.get::<Table>("nebulae")?.sequence_values::<Table>() {
            let n = n?;
            nebulae.push(Nebula { x: n.get("x")?, y: n.get("y")?, radius: n.get("radius")?, name: n.get("name")? });
        }
        Ok(Galaxy {
            date: g.get("date")?,
            systems,
            lanes,
            countries,
            fleets,
            nebulae,
            hyperlane_colour: [hc.get(1)?, hc.get(2)?, hc.get(3)?, hc.get(4)?],
            star_icon_scale: g.get("star_icon_scale")?,
            border_system_radius: g.get("border_system_radius")?,
            border_hyperlane_thickness: g.get("border_hyperlane_thickness")?,
            border_texture_size: g.get("border_texture_size")?,
            dust_size: g.get("dust_size")?,
            dust_size_extra: g.get("dust_size_extra")?,
            notes: g.get("notes")?,
        })
    };
    read().map_err(|e| format!("render.galaxy: {e}"))
}
