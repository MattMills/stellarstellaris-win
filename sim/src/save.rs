//! Saves: a `.sav` is a zip of `gamestate` (the game's object databases, written member by member)
//! and `meta`. Read in memory; the save is not changed or copied.

use std::io::Read;

use crate::date::Date;

/// The `gamestate` of a save, or a plain gamestate file (what `headless/run.sh` writes).
pub fn read_gamestate(save: &str) -> Result<String, String> {
    let mut f = std::fs::File::open(save).map_err(|e| format!("{save}: {e}"))?;
    let mut magic = [0u8; 2];
    let zipped = f.read_exact(&mut magic).is_ok() && &magic == b"PK";
    drop(f);
    if !zipped {
        let bytes = std::fs::read(save).map_err(|e| format!("{save}: {e}"))?;
        return String::from_utf8(bytes).map_err(|e| format!("{save}: {e}"));
    }
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

/// Writes a save: a zip of `gamestate` and `meta` (its date set to `date`, "y.mm.dd") as the game
/// writes them [V 4.5.2's saves]: gamestate first, then meta, deflated, DOS date and time 0. The
/// file is written next to `path` and renamed over it, so a save that fails leaves the old one.
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
    if let Some(dir) = std::path::Path::new(path).parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
    }
    let tmp = format!("{path}.tmp");
    let f = std::fs::File::create(&tmp).map_err(|e| format!("{tmp}: {e}"))?;
    let mut z = zip::ZipWriter::new(f);
    // SAFETY: DOS date and time 0 is a bit pattern, as the game writes it (1980-00-00 00:00)
    let zero = unsafe { zip::DateTime::from_msdos_unchecked(0, 0) };
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .last_modified_time(zero);
    z.start_file("gamestate", opts).map_err(|e| e.to_string())?;
    z.write_all(gamestate.as_bytes()).map_err(|e| e.to_string())?;
    z.start_file("meta", opts).map_err(|e| e.to_string())?;
    z.write_all(meta_out.as_bytes()).map_err(|e| e.to_string())?;
    z.finish().map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{path}: {e}"))?;
    Ok(())
}

/// The game's folder of save games: `Documents/Paradox Interactive/Stellaris/save games` on
/// Windows, `~/.local/share/Paradox Interactive/Stellaris/save games` on Linux (the game's user
/// dir; STELLAR_SAVE_GAMES chooses another).
pub fn save_games_dir() -> Option<std::path::PathBuf> {
    if let Ok(d) = std::env::var("STELLAR_SAVE_GAMES") {
        return Some(d.into());
    }
    if cfg!(windows) {
        let home = std::env::var("USERPROFILE").ok()?;
        Some(std::path::Path::new(&home).join(r"Documents\Paradox Interactive\Stellaris\save games"))
    } else {
        let home = std::env::var("HOME").ok()?;
        Some(std::path::Path::new(&home).join(".local/share/Paradox Interactive/Stellaris/save games"))
    }
}

/// The folder of a game's saves in the save games folder (CGameState::GetSaveFolderName
/// @0x1b40f20 [V]): the game's name (the gamestate's `name`) with every character but ASCII
/// letters and digits removed; when that removed something, `_` and the MurmurHash3 (x86, 32 bit,
/// seed 0: PMurHash32) of the whole name as a signed int are added; then lowercased.
/// "Sacred Uthabulan Order" -> `sacreduthabulanorder_-730439522`.
pub fn save_folder_name(name: &str) -> String {
    let kept: String = name.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    let folder = if kept == name { kept } else { format!("{kept}_{}", murmur3_32(name.as_bytes(), 0) as i32) };
    folder.to_ascii_lowercase()
}

/// MurmurHash3_x86_32 (the game's PMurHash32).
pub fn murmur3_32(data: &[u8], seed: u32) -> u32 {
    const C1: u32 = 0xcc9e_2d51;
    const C2: u32 = 0x1b87_3593;
    let mut h = seed;
    let mut chunks = data.chunks_exact(4);
    for c in &mut chunks {
        let k = u32::from_le_bytes([c[0], c[1], c[2], c[3]]).wrapping_mul(C1).rotate_left(15).wrapping_mul(C2);
        h = (h ^ k).rotate_left(13).wrapping_mul(5).wrapping_add(0xe654_6b64);
    }
    let tail = chunks.remainder();
    if !tail.is_empty() {
        let mut k = 0u32;
        for (i, b) in tail.iter().enumerate() {
            k |= (*b as u32) << (8 * i);
        }
        h ^= k.wrapping_mul(C1).rotate_left(15).wrapping_mul(C2);
    }
    h ^= data.len() as u32;
    h ^= h >> 16;
    h = h.wrapping_mul(0x85eb_ca6b);
    h ^= h >> 13;
    h = h.wrapping_mul(0xc2b2_ae35);
    h ^ (h >> 16)
}

/// A save's file name made safe the way the game's save window keeps it: the characters a file
/// name cannot hold dropped, `.sav` added.
pub fn save_file_name(name: &str) -> String {
    let clean: String = name.chars().filter(|c| !matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') && !c.is_control()).collect();
    let clean = clean.trim().trim_end_matches('.');
    let clean = if clean.is_empty() { "save" } else { clean };
    if clean.to_ascii_lowercase().ends_with(".sav") {
        clean.to_string()
    } else {
        format!("{clean}.sav")
    }
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

/// The tick within the day of a gamestate (its top-level `tick=n`, `CGameState::_nTickCount`, 0 to
/// 9): a save written at tick 4 or later was written after that day's AI pass.
pub fn tick_of(gamestate: &str) -> Option<i32> {
    let line = gamestate.lines().take(200).find(|l| l.starts_with("tick") && l[4..].trim_start().starts_with('='))?;
    line[4..].trim_start()[1..].trim().parse().ok()
}

/// A top-level `key=value` of a gamestate (a key at the start of a line), the last one written.
fn top_value<'a>(gamestate: &'a str, key: &str) -> Option<&'a str> {
    let at = gamestate.rfind(&format!("\n{key}="))? + key.len() + 2;
    let rest = &gamestate[at..];
    Some(rest[..rest.find(['\n', '\r']).unwrap_or(rest.len())].trim())
}

/// The synchronized generator's state in a gamestate (`random_seed`, `random_count`: `CRandom::_Random`'s
/// seed and position as `u32`).
pub fn random_of(gamestate: &str) -> Option<(u32, u32)> {
    let seed = top_value(gamestate, "random_seed")?.parse::<i64>().ok()? as u32;
    let count = top_value(gamestate, "random_count")?.parse::<i64>().ok()? as u32;
    Some((seed, count))
}

/// The save of 2210.01.01 (the modifier capture's): `STELLAR_SAVE`, else the first of the known
/// places that has it; None when none does.
pub fn default_save() -> Option<String> {
    if let Ok(path) = std::env::var("STELLAR_SAVE") {
        return std::path::Path::new(&path).exists().then_some(path);
    }
    let home = std::env::var("USERPROFILE").unwrap_or_default();
    [
        r"C:\lfm\saves\autosave_2210.01.01.sav".to_string(),
        format!(r"{home}\Documents\Paradox Interactive\Stellaris\save games\sacreduthabulanorder_-730439522\autosave_2210.01.01.sav"),
        "/opt/stellaris-saves/autosave_2210.01.01.sav".to_string(),
    ]
    .into_iter()
    .find(|p| std::path::Path::new(p).exists())
}

/// The Stellaris install: `STELLARIS_DIR`, else the Steam one on Windows or `/opt/stellaris`;
/// None when it is not there.
pub fn game_dir() -> Option<String> {
    if let Ok(dir) = std::env::var("STELLARIS_DIR") {
        return std::path::Path::new(&dir).join("common").exists().then_some(dir);
    }
    [r"C:\Program Files (x86)\Steam\steamapps\common\Stellaris", "/opt/stellaris"]
        .into_iter()
        .find(|d| std::path::Path::new(d).join("common").exists())
        .map(str::to_string)
}
