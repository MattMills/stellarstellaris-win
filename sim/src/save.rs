//! Saves: a `.sav` is a zip of `gamestate` (the game's object databases, written member by member)
//! and `meta`. Read in memory; the save is not changed or copied.

use std::io::Read;

use crate::date::Date;

/// The `gamestate` of a save.
pub fn read_gamestate(save: &str) -> Result<String, String> {
    let f = std::fs::File::open(save).map_err(|e| format!("{save}: {e}"))?;
    let mut z = zip::ZipArchive::new(f).map_err(|e| format!("{save}: {e}"))?;
    let mut entry = z.by_name("gamestate").map_err(|e| format!("{save}: gamestate: {e}"))?;
    let mut text = String::new();
    entry.read_to_string(&mut text).map_err(|e| format!("{save}: gamestate: {e}"))?;
    Ok(text)
}

/// The `meta` of a save (name, version, date, DLCs, flag).
pub fn read_meta(save: &str) -> Result<String, String> {
    let f = std::fs::File::open(save).map_err(|e| format!("{save}: {e}"))?;
    let mut z = zip::ZipArchive::new(f).map_err(|e| format!("{save}: {e}"))?;
    let mut entry = z.by_name("meta").map_err(|e| format!("{save}: meta: {e}"))?;
    let mut text = String::new();
    entry.read_to_string(&mut text).map_err(|e| format!("{save}: meta: {e}"))?;
    Ok(text)
}

/// Writes a save: a zip of `meta` (its date set to `date`, "y.mm.dd") and `gamestate`, deflated as
/// the game writes them.
pub fn write_save(path: &str, gamestate: &str, meta: &str, date: &str) -> Result<(), String> {
    use std::io::Write;
    let mut meta_out = String::new();
    for line in meta.lines() {
        if line.starts_with("date=") {
            meta_out.push_str(&format!("date=\"{date}\"\n"));
        } else {
            meta_out.push_str(line);
            meta_out.push('\n');
        }
    }
    let f = std::fs::File::create(path).map_err(|e| format!("{path}: {e}"))?;
    let mut z = zip::ZipWriter::new(f);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    z.start_file("meta", opts).map_err(|e| e.to_string())?;
    z.write_all(meta_out.as_bytes()).map_err(|e| e.to_string())?;
    z.start_file("gamestate", opts).map_err(|e| e.to_string())?;
    z.write_all(gamestate.as_bytes()).map_err(|e| e.to_string())?;
    z.finish().map_err(|e| e.to_string())?;
    Ok(())
}

/// The date of a gamestate (its `date="y.m.d"` near the top).
pub fn date_of(gamestate: &str) -> Option<Date> {
    // the top-level `date="y.m.d"` (the game's spelling) or `date = "y.m.d"` (pdxscript.write's)
    let line = gamestate.lines().find(|l| l.starts_with("date") && l[4..].trim_start().starts_with('='))?;
    let rest = line[4..].trim_start()[1..].trim_start();
    let text = rest.trim_start_matches('"');
    let end = text.find('"')?;
    let mut parts = text[..end].split('.').map(|p| p.parse::<i32>().ok());
    let (y, m, d) = (parts.next()??, parts.next()??, parts.next()??);
    Some(Date::from_ymd(y, m, d))
}

/// The user's save of 2210.01.01 (the capture's), or `STELLAR_SAVE`; None when it is not there.
pub fn default_save() -> Option<String> {
    let home = std::env::var("USERPROFILE").unwrap_or_default();
    let path = std::env::var("STELLAR_SAVE").unwrap_or(format!(
        r"{home}\Documents\Paradox Interactive\Stellaris\save games\sacreduthabulanorder_-730439522\autosave_2210.01.01.sav"
    ));
    std::path::Path::new(&path).exists().then_some(path)
}

/// The Stellaris install (`STELLARIS_DIR`, default the Steam one); None when it is not there.
pub fn game_dir() -> Option<String> {
    let dir = std::env::var("STELLARIS_DIR").unwrap_or(r"C:\Program Files (x86)\Steam\steamapps\common\Stellaris".into());
    std::path::Path::new(&dir).join("common").exists().then_some(dir)
}
