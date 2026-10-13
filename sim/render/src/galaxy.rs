//! The galaxy map of a save: the game's files and the save loaded through the Lua runtime
//! (`stellar_sim::Runtime`), then read with the query in `lua/render/galaxy.lua`.

use stellar_sim::{save, Runtime};

/// A star system: its position in map units (the save's `coordinate`), and the index of the
/// country that owns it in [`Galaxy::countries`].
#[derive(Clone, Debug)]
pub struct System {
    /// The save's id (of the galactic_object).
    #[allow(dead_code)]
    pub id: u32,
    pub x: f32,
    pub y: f32,
    pub owner: Option<usize>,
}

/// A country that owns at least one system, with its galaxy map colour.
#[derive(Clone, Debug)]
pub struct Country {
    pub id: u32,
    pub name: String,
    pub kind: String,
    /// The colour's name (the first of the flag's colours).
    pub colour_name: String,
    /// Where the colour came from: "map" (flags/colors.txt), "named" (common/named_colors), "".
    pub colour_source: String,
    /// sRGB, 0..1.
    pub rgb: [f32; 3],
    pub systems: usize,
}

#[derive(Clone, Debug)]
pub struct Galaxy {
    pub date: String,
    pub systems: Vec<System>,
    /// Indices into `systems`, each lane once.
    pub lanes: Vec<(u32, u32)>,
    pub countries: Vec<Country>,
    /// What the Lua query read (counts and timing).
    pub notes: String,
}

/// The renderer's Lua directory (`sim/render/lua`), for `package.path`.
fn lua_dir() -> String {
    concat!(env!("CARGO_MANIFEST_DIR"), "/lua").replace('\\', "/")
}

type Extract = (
    Vec<u32>,
    Vec<f64>,
    Vec<f64>,
    Vec<i64>,
    Vec<u32>,
    Vec<u32>,
    Vec<u32>,
    Vec<String>,
    Vec<String>,
    Vec<String>,
    Vec<f64>,
    Vec<f64>,
    Vec<f64>,
    Vec<String>,
    String,
);

/// Loads the game's files from `game_dir` and the save at `save_path` into a runtime, then reads
/// the galaxy map from its world.
pub fn load(game_dir: &str, save_path: &str) -> Result<Galaxy, String> {
    let t0 = std::time::Instant::now();
    let gamestate = save::read_gamestate(save_path)?;
    let date = save::date_of(&gamestate).ok_or("the save has no date")?;
    let runtime = Runtime::new(date, 0).map_err(|e| format!("the Lua runtime: {e}"))?;
    let loaded = runtime.load(game_dir, Some(&gamestate), None).map_err(|e| format!("load: {e}"))?;
    drop(gamestate);
    eprintln!("{loaded}");
    eprintln!("runtime loaded in {:.1} s", t0.elapsed().as_secs_f64());
    from_runtime(&runtime, game_dir)
}

/// The galaxy map of a loaded runtime's world.
pub fn from_runtime(runtime: &Runtime, game_dir: &str) -> Result<Galaxy, String> {
    let chunk = format!(
        "package.path = {path:?} .. ';' .. package.path\nreturn require('render.galaxy').extract({dir:?})",
        path = format!("{}/?.lua", lua_dir()),
        dir = game_dir.replace('\\', "/"),
    );
    let (ids, xs, ys, owners, la, lb, cid, cname, ckind, ccolour, cr, cg, cb, csource, notes): Extract =
        runtime.eval(&chunk).map_err(|e| format!("render.galaxy: {e}"))?;
    let date: String = runtime
        .eval("local w = require('engine.world') return tostring(w.meta.date)")
        .map_err(|e| format!("date: {e}"))?;

    let mut countries: Vec<Country> = (0..cid.len())
        .map(|i| Country {
            id: cid[i],
            name: cname[i].clone(),
            kind: ckind[i].clone(),
            colour_name: ccolour[i].clone(),
            colour_source: csource[i].clone(),
            rgb: [cr[i] as f32, cg[i] as f32, cb[i] as f32],
            systems: 0,
        })
        .collect();
    let mut systems = Vec::with_capacity(ids.len());
    for i in 0..ids.len() {
        let owner = if owners[i] >= 0 { countries.iter().position(|c| c.id as i64 == owners[i]) } else { None };
        if let Some(o) = owner {
            countries[o].systems += 1;
        }
        systems.push(System { id: ids[i], x: xs[i] as f32, y: ys[i] as f32, owner });
    }
    let lanes = la.into_iter().zip(lb).collect();
    Ok(Galaxy { date: date.trim_matches('"').to_string(), systems, lanes, countries, notes })
}

/// The Stellaris install: `STELLARIS_DIR`, else the Steam one (`save::game_dir`), else
/// /opt/stellaris.
pub fn default_game_dir() -> Option<String> {
    save::game_dir().or_else(|| {
        let p = "/opt/stellaris";
        std::path::Path::new(p).join("common").exists().then(|| p.to_string())
    })
}

/// The save: `STELLAR_SAVE` or the user's 2210.01.01 autosave (`save::default_save`), else the
/// copy of it under /opt/stellaris-saves.
pub fn default_save() -> Option<String> {
    save::default_save().or_else(|| {
        let p = "/opt/stellaris-saves/autosave_2210.01.01.sav";
        std::path::Path::new(p).exists().then(|| p.to_string())
    })
}
