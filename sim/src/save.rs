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

/// The date of a gamestate (its `date="y.m.d"` near the top).
pub fn date_of(gamestate: &str) -> Option<Date> {
    let at = gamestate.find("\ndate=")?;
    let rest = &gamestate[at + 6..];
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
