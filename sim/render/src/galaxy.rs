//! The galaxy map of a save: the world loaded through the Lua runtime
//! (`stellar_sim::Runtime::load_world`), then read with the query in `lua/render/galaxy.lua`,
//! with the game files it is drawn with (star classes, colours, defines).

use std::collections::HashMap;

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
    /// the star's height over the plane (the save's visual_height: the game's world, map x 2)
    pub height: f32,
    /// its name (a save's name block, localised by render.names)
    pub name: Name,
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
    /// its flag: emblem and background (category, file) and colours (sRGB, the `flag` swatches)
    pub flag: Option<Flag>,
    /// its name block (render.names localises it)
    pub name_block: Name,
    /// its government type (a localisation key: the galaxy banner's empire_type)
    pub government: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Flag {
    pub icon: (String, String),
    pub background: (String, String),
    pub colours: Vec<[f32; 3]>,
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
    /// the player's terra incognita: its bitmap (size x size, row by row, 0 unknown, 255 known)
    /// and the systems it has cleared
    pub terra_incognita: Option<TerraIncognita>,
    /// the terra incognita the hyperlanes were built from, when not the current one: the game builds
    /// its lane geometry from the player's knowledge and `observe` does not build it again
    pub lanes_ti: Option<TerraIncognita>,
    /// the save's galaxy.core_radius (map units)
    pub core_radius: f32,
    /// the player's country id
    pub player: u32,
    /// the countries the player has communications with (None: no player country, all shown)
    pub communications: Option<Vec<u32>>,
    /// the player's planets (the outliner's colonies)
    pub planets: Vec<PlanetInfo>,
    /// the player's capital: its planet and system (save ids)
    pub capital: Option<(u32, u32)>,
    /// the player's alerts: (key, icon sprite, priority HIGH/MEDIUM/LOW), in their order
    pub alerts: Vec<(String, String, String)>,
    /// the outliner's members (utility ships by class, military fleets, shipyards, starbases,
    /// colonies by sector) and the player's sectors
    pub outliner: Vec<OutlinerEntry>,
    pub sectors: Vec<(u32, Name)>,
    /// the player's sectors' capital systems (sector id -> system id)
    pub sector_capitals: HashMap<u32, u32>,
    /// the outliner's and the observer outliner's view of the world (render.windows.outliner)
    pub outliner_view: crate::outliner::LuaData,
    /// what the map labels show (render.windows.mapicons: mapicons.rs)
    pub mapicons: std::sync::Arc<crate::mapicons::Data>,
    /// what the diplomacy windows show of the world: a Lua chunk (render.windows.diplomacy_data)
    pub diplomacy: String,
}

impl Galaxy {
    /// The owner a system's border and pin show (CBorderShapeCalculator::CalculateOwnerIds): its
    /// owner when that is the player or a country the player has communications with.
    pub fn shown_owner(&self, s: &System) -> Option<usize> {
        let o = s.owner?;
        let id = self.countries[o].id;
        match &self.communications {
            Some(c) if id != self.player && !c.contains(&id) => None,
            _ => Some(o),
        }
    }
}

#[derive(Clone, Debug)]
pub struct TerraIncognita {
    pub size: usize,
    pub bitmap: Vec<u8>,
    #[allow(dead_code)]
    pub systems: Vec<u32>,
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
    /// the save's military_power (the map label's strength)
    pub military_power: f32,
    pub from: Option<(f32, f32)>,
    pub to: Option<(f32, f32)>,
    pub name: Name,
    /// the system it is in (None: between systems)
    pub system: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct Nebula {
    pub x: f32,
    pub y: f32,
    pub radius: f32,
    #[allow(dead_code)]
    pub name: String,
    /// the ids of the systems in it
    pub systems: Vec<u32>,
}

/// A save's name block: a localisation key (or the name itself when `literal`), and the
/// variables its text takes (render.names puts them together).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Name {
    pub key: String,
    pub literal: bool,
    pub vars: Vec<(String, Name)>,
}

impl Name {
    pub fn read(t: Option<Table>) -> mlua::Result<Name> {
        let Some(t) = t else { return Ok(Name::default()) };
        let mut vars = Vec::new();
        if let Some(v) = t.get::<Option<Table>>("vars")? {
            for p in v.sequence_values::<Table>() {
                let p = p?;
                vars.push((p.get("key")?, Name::read(p.get("value")?)?));
            }
        }
        Ok(Name { key: t.get::<Option<String>>("key")?.unwrap_or_default(), literal: t.get::<Option<bool>>("literal")?.unwrap_or(false), vars })
    }

    /// As a Lua table for render.names.
    pub fn to_lua(&self, lua: &mlua::Lua) -> mlua::Result<Table> {
        let t = lua.create_table()?;
        t.set("key", self.key.as_str())?;
        t.set("literal", self.literal)?;
        let vars = lua.create_table()?;
        for (k, v) in &self.vars {
            let e = lua.create_table()?;
            e.set("key", k.as_str())?;
            e.set("value", v.to_lua(lua)?)?;
            vars.push(e)?;
        }
        t.set("vars", vars)?;
        Ok(t)
    }
}

/// An outliner member: its kind (civilian, military, shipyard, starbase, planet), id, name, its
/// second line's key (a ship size, a starbase type, a colony designation), military power,
/// system and sector.
#[derive(Clone, Debug)]
pub struct OutlinerEntry {
    pub kind: String,
    pub id: u32,
    pub name: Name,
    pub sub: String,
    pub power: f32,
    pub system: i64,
    pub sector: i64,
}

/// A planet of the player's: its id, name, class and system.
#[derive(Clone, Debug)]
pub struct PlanetInfo {
    pub id: u32,
    pub name: Name,
    pub class: String,
    pub system: i64,
}

/// The renderer's Lua directory (`sim/render/lua` under `runtime::repo_dir`), for `package.path`.
fn lua_dir() -> String {
    stellar_sim::runtime::repo_dir().join("sim/render/lua").to_string_lossy().replace('\\', "/")
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

/// A runtime with no world, for the game's files (models, GUI, worlds' graphics), and the
/// renderer's Lua modules on the path: the map's while a simulation runs, which has the one world
/// (its snapshots carry what is drawn of it).
pub fn files_runtime() -> Result<Runtime, String> {
    let runtime = Runtime::new(stellar_sim::Date::from_ymd(2200, 1, 1), 0).map_err(|e| format!("the Lua runtime: {e}"))?;
    let path = format!("{}/?.lua", lua_dir());
    let package: Table = runtime.lua.globals().get("package").map_err(|e| e.to_string())?;
    let old: String = package.get("path").map_err(|e| e.to_string())?;
    package.set("path", format!("{path};{old}")).map_err(|e| e.to_string())?;
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
                name_block: Name::read(c.get("name_block")?)?,
                government: c.get::<Option<String>>("government")?.unwrap_or_default(),
                flag: match c.get::<Option<Table>>("flag")? {
                    Some(f) => {
                        let part = |k: &str| -> mlua::Result<(String, String)> {
                            Ok(match f.get::<Option<Table>>(k)? {
                                Some(p) => (p.get("category")?, p.get("file")?),
                                None => (String::new(), String::new()),
                            })
                        };
                        let mut colours = Vec::new();
                        if let Some(cs) = f.get::<Option<Table>>("colours")? {
                            for c in cs.sequence_values::<Table>() {
                                colours.push(rgb(&c?)?);
                            }
                        }
                        Some(Flag { icon: part("icon")?, background: part("background")?, colours })
                    }
                    None => None,
                },
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
                height: s.get::<Option<f32>>("height")?.unwrap_or(0.0),
                name: Name::read(s.get("name")?)?,
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
                military_power: f.get::<Option<f32>>("military_power")?.unwrap_or(0.0),
                from: pair("from_x", "from_y")?,
                to: pair("to_x", "to_y")?,
                name: Name::read(f.get("name")?)?,
                system: f.get("system")?,
            });
        }
        let mut nebulae = Vec::new();
        for n in g.get::<Table>("nebulae")?.sequence_values::<Table>() {
            let n = n?;
            nebulae.push(Nebula {
                x: n.get("x")?,
                y: n.get("y")?,
                radius: n.get("radius")?,
                name: n.get("name")?,
                systems: n.get::<Option<Table>>("systems")?.map(|t| t.sequence_values::<u32>().collect::<mlua::Result<Vec<_>>>()).transpose()?.unwrap_or_default(),
            });
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
            lanes_ti: None,
            terra_incognita: match g.get::<Option<Table>>("terra_incognita")? {
                Some(t) => {
                    let size: usize = t.get::<Option<usize>>("size")?.unwrap_or(256);
                    let runs: Vec<u32> = t.get::<Table>("runs")?.sequence_values::<u32>().collect::<mlua::Result<_>>()?;
                    let systems: Vec<u32> = t.get::<Table>("systems")?.sequence_values::<u32>().collect::<mlua::Result<_>>()?;
                    // run lengths, the first unknown, alternating (CTerraIncognitaMap)
                    let mut bitmap = Vec::with_capacity(size * size);
                    for (k, n) in runs.iter().enumerate() {
                        let v = if k % 2 == 0 { 0u8 } else { 255u8 };
                        bitmap.extend(std::iter::repeat_n(v, *n as usize));
                    }
                    bitmap.resize(size * size, 0);
                    Some(TerraIncognita { size, bitmap, systems })
                }
                None => None,
            },
            core_radius: g.get::<Option<f32>>("core_radius")?.unwrap_or(0.0),
            mapicons: std::sync::Arc::new(crate::mapicons::read(g.get("mapicons")?)?),
            player: g.get::<Option<u32>>("player")?.unwrap_or(0),
            communications: g.get::<Option<Table>>("communications")?.map(|t| t.sequence_values::<u32>().collect::<mlua::Result<Vec<_>>>()).transpose()?,
            outliner: match g.get::<Option<Table>>("outliner")? {
                Some(t) => t
                    .sequence_values::<Table>()
                    .map(|e| -> mlua::Result<OutlinerEntry> {
                        let e = e?;
                        Ok(OutlinerEntry {
                            kind: e.get("kind")?,
                            id: e.get("id")?,
                            name: Name::read(e.get("name")?)?,
                            sub: e.get::<Option<String>>("sub")?.unwrap_or_default(),
                            power: e.get::<Option<f32>>("power")?.unwrap_or(0.0),
                            system: e.get::<Option<i64>>("system")?.unwrap_or(-1),
                            sector: e.get::<Option<i64>>("sector")?.unwrap_or(-1),
                        })
                    })
                    .collect::<mlua::Result<_>>()?,
                None => Vec::new(),
            },
            sectors: match g.get::<Option<Table>>("sectors")? {
                Some(t) => t.sequence_values::<Table>().map(|s| -> mlua::Result<(u32, Name)> { let s = s?; Ok((s.get("id")?, Name::read(s.get("name")?)?)) }).collect::<mlua::Result<_>>()?,
                None => Vec::new(),
            },
            sector_capitals: match g.get::<Option<Table>>("sectors")? {
                Some(t) => t
                    .sequence_values::<Table>()
                    .filter_map(|s| -> Option<mlua::Result<(u32, u32)>> {
                        let s = match s {
                            Ok(s) => s,
                            Err(e) => return Some(Err(e)),
                        };
                        match (s.get::<u32>("id"), s.get::<Option<u32>>("capital")) {
                            (Ok(id), Ok(Some(c))) => Some(Ok((id, c))),
                            (Err(e), _) | (_, Err(e)) => Some(Err(e)),
                            _ => None,
                        }
                    })
                    .collect::<mlua::Result<_>>()?,
                None => HashMap::new(),
            },
            diplomacy: g.get::<Option<String>>("diplomacy")?.unwrap_or_default(),
            outliner_view: crate::outliner::read_view(&g)?,
            alerts: match g.get::<Option<Table>>("alerts")? {
                Some(t) => t
                    .sequence_values::<Table>()
                    .map(|a| -> mlua::Result<(String, String, String)> {
                        let a = a?;
                        Ok((a.get("key")?, a.get("icon")?, a.get("priority")?))
                    })
                    .collect::<mlua::Result<_>>()?,
                None => Vec::new(),
            },
            capital: match g.get::<Option<Table>>("capital")? {
                Some(t) => Some((t.get("planet")?, t.get("system")?)),
                None => None,
            },
            planets: match g.get::<Option<Table>>("planets")? {
                Some(t) => t
                    .sequence_values::<Table>()
                    .map(|p| -> mlua::Result<PlanetInfo> {
                        let p = p?;
                        Ok(PlanetInfo { id: p.get("id")?, name: Name::read(p.get("name")?)?, class: p.get("class")?, system: p.get("system")? })
                    })
                    .collect::<mlua::Result<_>>()?,
                None => Vec::new(),
            },
        })
    };
    read().map_err(|e| format!("render.galaxy: {e}"))
}
