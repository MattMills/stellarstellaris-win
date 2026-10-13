//! Checking the modifier model against a capture of the game's modifier nodes.
//!
//! Inputs: a dump of every registered modifier node of a live game (TSV: `id`, `category`, `owner`,
//! `invalid`, `values`, `parts`; values and parts in fixed point, 1.0 = 100000), the game's
//! `modifiers.log` of the same session (the types and their categories), the save the session
//! loaded, and the vanilla script in place. The work is in `sim/lua/simscript/modcheck.lua`; see
//! docs/simulation.md, "Checking against the game's modifier nodes".

use std::io::Read;

use mlua::{Function, Table};

use crate::lua_host::LuaScriptHost;

/// The paths of one comparison.
#[derive(Clone, Debug)]
pub struct Inputs {
    pub nodes_tsv: String,
    pub types_log: String,
    pub save: String,
    pub game_dir: String,
}

impl Inputs {
    /// The capture of 2210.01.01 and its save, from the environment (`MODCHECK_NODES`,
    /// `MODCHECK_TYPES`, `MODCHECK_SAVE`, `STELLARIS_DIR`) or the default locations; None when a
    /// file is missing.
    pub fn from_env() -> Option<Inputs> {
        let home = std::env::var("USERPROFILE").unwrap_or_default();
        let get = |k: &str, d: String| std::env::var(k).unwrap_or(d);
        let i = Inputs {
            nodes_tsv: get("MODCHECK_NODES", r"C:\lfm\captures\modifier-nodes-2210.tsv".into()),
            types_log: get("MODCHECK_TYPES", r"C:\lfm\captures\modifiers-2210.log".into()),
            save: get(
                "MODCHECK_SAVE",
                format!(r"{home}\Documents\Paradox Interactive\Stellaris\save games\sacreduthabulanorder_-730439522\autosave_2210.01.01.sav"),
            ),
            game_dir: get("STELLARIS_DIR", r"C:\Program Files (x86)\Steam\steamapps\common\Stellaris".into()),
        };
        let all = [&i.nodes_tsv, &i.types_log, &i.save, &i.game_dir].iter().all(|p| std::path::Path::new(p).exists());
        all.then_some(i)
    }
}

/// The `gamestate` of a save (a zip, read in memory; the save is not changed or copied).
pub fn read_gamestate(save: &str) -> Result<String, String> {
    let f = std::fs::File::open(save).map_err(|e| format!("{save}: {e}"))?;
    let mut z = zip::ZipArchive::new(f).map_err(|e| format!("{save}: {e}"))?;
    let mut entry = z.by_name("gamestate").map_err(|e| format!("{save}: gamestate: {e}"))?;
    let mut text = String::new();
    entry.read_to_string(&mut text).map_err(|e| format!("{save}: gamestate: {e}"))?;
    Ok(text)
}

/// Runs the comparison and returns its report.
pub fn run(inputs: &Inputs) -> Result<String, String> {
    let gamestate = read_gamestate(&inputs.save)?;
    let lua = LuaScriptHost::new_lua().map_err(|e| e.to_string())?;
    let m: Table = lua.load("return require('simscript.modcheck')").eval().map_err(|e| e.to_string())?;
    let f: Function = m.get("run").map_err(|e| e.to_string())?;
    let opts = lua.create_table().map_err(|e| e.to_string())?;
    let fwd = |s: &str| s.replace(std::path::MAIN_SEPARATOR, "/");
    opts.set("nodes_tsv", fwd(&inputs.nodes_tsv)).map_err(|e| e.to_string())?;
    opts.set("types_log", fwd(&inputs.types_log)).map_err(|e| e.to_string())?;
    opts.set("game_dir", fwd(&inputs.game_dir)).map_err(|e| e.to_string())?;
    opts.set("gamestate", lua.create_string(&gamestate).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    drop(gamestate);
    f.call::<String>(opts).map_err(|e| e.to_string())
}
