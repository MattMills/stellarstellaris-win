//! The game's files as the game sees them: the game directory with the enabled mods over it, one
//! file system per set of mounts, shared by every Lua state and thread of the process
//! (docs/script_loading.md).
//!
//! A mount later in the list wins for the same relative path, and a mount's `replace_path` folders
//! hide the files of the mounts before it in that folder (`stellar.script.source`'s rules, which
//! this replaces under it). Listings and path lookups are cached; a file's version is a counter that
//! [`Vfs::invalidate`] raises, so a cache keyed by (path, version) above (the parse cache in
//! `stellar.script.source`) stays valid until the file changes.
//!
//! Lua sees it as `RUST.vfs_open`, `vfs_list`, `vfs_dirs`, `vfs_path`, `vfs_read`, `vfs_version` and
//! `vfs_invalidate` ([`register`]).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use mlua::{Lua, Table, Value};

/// A mount: a directory, and the folders (relative, `/`, no trailing slash) whose files it replaces.
#[derive(Clone, Debug)]
pub struct Mount {
    pub path: PathBuf,
    pub replace: HashSet<String>,
}

type ListKey = (String, Option<String>, i32);

/// One set of mounts and its caches.
pub struct Vfs {
    mounts: Vec<Mount>,
    lists: Mutex<HashMap<ListKey, Arc<Vec<String>>>>,
    paths: Mutex<HashMap<String, Option<PathBuf>>>,
    versions: Mutex<HashMap<String, u64>>,
    /// raised by an invalidation of everything: part of every file's version
    generation: AtomicU64,
}

fn dirname(rel: &str) -> &str {
    rel.rfind('/').map_or("", |i| &rel[..i])
}

impl Vfs {
    pub fn new(mounts: Vec<Mount>) -> Vfs {
        Vfs {
            mounts,
            lists: Mutex::new(HashMap::new()),
            paths: Mutex::new(HashMap::new()),
            versions: Mutex::new(HashMap::new()),
            generation: AtomicU64::new(0),
        }
    }

    pub fn mounts(&self) -> &[Mount] {
        &self.mounts
    }

    /// The relative paths of `sub`'s files with extension `ext` (any when `None`; compared without
    /// case), `depth` folder levels down (0: `sub` itself; negative: all), sorted by byte order. A
    /// name in a later mount replaces the same name (without case) in an earlier one; a mount that
    /// replaces `sub` drops what the mounts before it listed. Names starting with `.` are skipped.
    pub fn list(&self, sub: &str, ext: Option<&str>, depth: i32) -> Arc<Vec<String>> {
        let sub = sub.trim_end_matches('/').to_string();
        let ext = ext.map(|e| e.trim_start_matches('.').to_ascii_lowercase());
        let key = (sub.clone(), ext.clone(), depth);
        if let Some(l) = self.lists.lock().unwrap().get(&key) {
            return l.clone();
        }
        fn walk(dir: &Path, prefix: &str, depth: i32, out: &mut Vec<String>) {
            let Ok(rd) = std::fs::read_dir(dir) else { return };
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                let Ok(ft) = e.file_type() else { continue };
                // a symbolic link counts as what it points to
                let (is_dir, is_file) = if ft.is_symlink() {
                    let p = e.path();
                    (p.is_dir(), p.is_file())
                } else {
                    (ft.is_dir(), ft.is_file())
                };
                if is_dir {
                    if depth != 0 {
                        walk(&e.path(), &format!("{prefix}{name}/"), depth - 1, out);
                    }
                } else if is_file {
                    out.push(format!("{prefix}{name}"));
                }
            }
        }
        let mut names: Vec<String> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        for m in &self.mounts {
            if m.replace.contains(&sub) {
                names.clear();
                seen.clear();
            }
            let mut found = Vec::new();
            walk(&m.path.join(&sub), "", depth, &mut found);
            for name in found {
                let lower = name.to_lowercase();
                let wanted = match &ext {
                    Some(e) => lower.ends_with(&format!(".{e}")),
                    None => true,
                };
                if wanted && seen.insert(lower) {
                    names.push(name);
                }
            }
        }
        names.sort();
        let out: Vec<String> = names.into_iter().map(|n| if sub.is_empty() { n } else { format!("{sub}/{n}") }).collect();
        let out = Arc::new(out);
        self.lists.lock().unwrap().insert(key, out.clone());
        out
    }

    /// The folders under `sub` (relative paths, recursively) in any mount, sorted.
    pub fn dirs(&self, sub: &str) -> Vec<String> {
        fn walk(base: &Path, rel: &str, out: &mut HashSet<String>) {
            let Ok(rd) = std::fs::read_dir(base.join(rel)) else { return };
            for e in rd.flatten() {
                if e.path().is_dir() {
                    let name = e.file_name().to_string_lossy().into_owned();
                    if name.starts_with('.') {
                        continue;
                    }
                    let r = if rel.is_empty() { name } else { format!("{rel}/{name}") };
                    out.insert(r.clone());
                    walk(base, &r, out);
                }
            }
        }
        let mut all = HashSet::new();
        for m in &self.mounts {
            walk(&m.path, sub.trim_end_matches('/'), &mut all);
        }
        let mut v: Vec<String> = all.into_iter().collect();
        v.sort();
        v
    }

    /// The file the game reads for a relative path: the last mount that has it, unless a mount
    /// after the ones that have it replaces its folder.
    pub fn path(&self, rel: &str) -> Option<PathBuf> {
        if let Some(p) = self.paths.lock().unwrap().get(rel) {
            return p.clone();
        }
        let dir = dirname(rel);
        let mut found = None;
        for m in self.mounts.iter().rev() {
            let p = m.path.join(rel);
            if p.is_file() {
                found = Some(p);
                break;
            }
            if m.replace.contains(dir) {
                break;
            }
        }
        self.paths.lock().unwrap().insert(rel.to_string(), found.clone());
        found
    }

    /// The bytes of the file the game reads for a relative path.
    pub fn read(&self, rel: &str) -> Result<Vec<u8>, String> {
        let p = self.path(rel).ok_or_else(|| format!("{rel}: no such file"))?;
        std::fs::read(&p).map_err(|e| format!("{}: {e}", p.display()))
    }

    /// The file's version: unchanged until the file (or everything) is invalidated.
    pub fn version(&self, rel: &str) -> u64 {
        let own = self.versions.lock().unwrap().get(rel).copied().unwrap_or(0);
        (self.generation.load(Ordering::Relaxed) << 32) | own
    }

    /// Forget what is cached for a relative path (its lookup, the listings of its folder and the
    /// folders above it) and raise its version; `None`: everything.
    pub fn invalidate(&self, rel: Option<&str>) {
        match rel {
            None => {
                self.generation.fetch_add(1, Ordering::Relaxed);
                self.lists.lock().unwrap().clear();
                self.paths.lock().unwrap().clear();
            }
            Some(rel) => {
                *self.versions.lock().unwrap().entry(rel.to_string()).or_insert(0) += 1;
                self.paths.lock().unwrap().remove(rel);
                let dir = dirname(rel);
                self.lists.lock().unwrap().retain(|(sub, _, _), _| !(dir == sub.as_str() || dir.starts_with(&format!("{sub}/")) || sub.is_empty()));
            }
        }
    }
}

/// The file systems of the process, by their mounts (one per distinct set).
fn registry() -> &'static Mutex<HashMap<String, Arc<Vfs>>> {
    static R: OnceLock<Mutex<HashMap<String, Arc<Vfs>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The key of a set of mounts (its paths and replaced folders), and the file system for it, made
/// once per process.
pub fn open(mounts: Vec<Mount>) -> (String, Arc<Vfs>) {
    let mut key = String::new();
    for m in &mounts {
        let mut r: Vec<&String> = m.replace.iter().collect();
        r.sort();
        key.push_str(&m.path.to_string_lossy());
        for x in r {
            key.push('|');
            key.push_str(x);
        }
        key.push('\n');
    }
    let mut reg = registry().lock().unwrap();
    let v = reg.entry(key.clone()).or_insert_with(|| Arc::new(Vfs::new(mounts))).clone();
    (key, v)
}

/// The file system with this key ([`open`]).
pub fn get(key: &str) -> Option<Arc<Vfs>> {
    registry().lock().unwrap().get(key).cloned()
}

fn by_key(key: &str) -> mlua::Result<Arc<Vfs>> {
    get(key).ok_or_else(|| mlua::Error::runtime(format!("no file system {key:?}")))
}

/// `RUST.vfs_*` in a Lua state's `RUST` table.
///
/// - `vfs_open(game_dir, mods)`: mods is a list of `{ path = dir, replace = { [folder] = true } }`
///   (`stellar.script.source.enabled_mods`); returns the file system's key
/// - `vfs_list(key, sub, ext, depth)` -> sorted relative paths; `vfs_dirs(key, sub)` -> folders
/// - `vfs_path(key, rel)` -> the file's path or nil; `vfs_read(key, rel)` -> its text, or nil and a
///   message
/// - `vfs_version(key, rel)` -> a number; `vfs_invalidate(key [, rel])`
pub fn register(lua: &Lua, rust: &Table) -> mlua::Result<()> {
    rust.set(
        "vfs_open",
        lua.create_function(|_, (game_dir, mods): (String, Option<Table>)| {
            let mut mounts = vec![Mount { path: PathBuf::from(game_dir), replace: HashSet::new() }];
            if let Some(mods) = mods {
                for m in mods.sequence_values::<Table>() {
                    let m = m?;
                    let path: String = m.get("path")?;
                    let mut replace = HashSet::new();
                    if let Ok(Value::Table(r)) = m.get::<Value>("replace") {
                        for pair in r.pairs::<Value, Value>() {
                            let (k, v) = pair?;
                            match (k, v) {
                                (Value::String(s), Value::Boolean(true)) => {
                                    replace.insert(s.to_str()?.trim_end_matches('/').replace('\\', "/"));
                                }
                                (Value::Integer(_), Value::String(s)) => {
                                    replace.insert(s.to_str()?.trim_end_matches('/').replace('\\', "/"));
                                }
                                _ => {}
                            }
                        }
                    }
                    mounts.push(Mount { path: PathBuf::from(path), replace });
                }
            }
            Ok(open(mounts).0)
        })?,
    )?;
    rust.set(
        "vfs_list",
        lua.create_function(|lua, (key, sub, ext, depth): (String, String, Option<String>, Option<i32>)| {
            let v = by_key(&key)?;
            let l = v.list(&sub, ext.as_deref(), depth.unwrap_or(0));
            lua.create_sequence_from(l.iter().map(|s| s.as_str()))
        })?,
    )?;
    rust.set(
        "vfs_dirs",
        lua.create_function(|lua, (key, sub): (String, String)| {
            let v = by_key(&key)?;
            lua.create_sequence_from(v.dirs(&sub))
        })?,
    )?;
    rust.set(
        "vfs_path",
        lua.create_function(|_, (key, rel): (String, String)| {
            Ok(by_key(&key)?.path(&rel).map(|p| p.to_string_lossy().replace('\\', "/")))
        })?,
    )?;
    rust.set(
        "vfs_read",
        lua.create_function(|lua, (key, rel): (String, String)| match by_key(&key)?.read(&rel) {
            Ok(bytes) => Ok((Some(lua.create_string(&bytes)?), None)),
            Err(e) => Ok((None, Some(e))),
        })?,
    )?;
    rust.set(
        "vfs_version",
        lua.create_function(|_, (key, rel): (String, String)| Ok(by_key(&key)?.version(&rel) as f64))?,
    )?;
    rust.set(
        "vfs_invalidate",
        lua.create_function(|_, (key, rel): (String, Option<String>)| {
            by_key(&key)?.invalidate(rel.as_deref());
            Ok(())
        })?,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("stellar-vfs-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
    fn put(root: &Path, rel: &str, text: &str) {
        let p = root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    #[test]
    fn mounts_override_replace_and_sort() {
        let game = tmp("game");
        let modd = tmp("mod");
        put(&game, "common/x/b.txt", "b");
        put(&game, "common/x/a.txt", "a");
        put(&game, "common/x/B2.txt", "B2");
        put(&game, "common/x/sub/c.txt", "c");
        put(&game, "common/y/old.txt", "old");
        put(&modd, "common/x/a.txt", "mod a");
        put(&modd, "common/x/m.TXT", "m");
        put(&modd, "common/y/new.txt", "new");
        let mut replace = HashSet::new();
        replace.insert("common/y".to_string());
        let v = Vfs::new(vec![
            Mount { path: game.clone(), replace: HashSet::new() },
            Mount { path: modd.clone(), replace },
        ]);
        // byte order (upper case first), the mod's a.txt once, depth 0 skips sub/
        assert_eq!(*v.list("common/x", Some("txt"), 0), vec!["common/x/B2.txt", "common/x/a.txt", "common/x/b.txt", "common/x/m.TXT"]);
        assert_eq!(*v.list("common/x", Some("txt"), -1), vec!["common/x/B2.txt", "common/x/a.txt", "common/x/b.txt", "common/x/m.TXT", "common/x/sub/c.txt"]);
        assert_eq!(v.read("common/x/a.txt").unwrap(), b"mod a");
        assert_eq!(v.read("common/x/b.txt").unwrap(), b"b");
        // the mod replaces common/y: the game's old.txt is gone from the listing and the lookup
        assert_eq!(*v.list("common/y", Some("txt"), 0), vec!["common/y/new.txt"]);
        assert!(v.path("common/y/old.txt").is_none());
        assert!(v.dirs("common").contains(&"common/x/sub".to_string()));
        // a change: the version moves and the listing is read again
        let v0 = v.version("common/x/b.txt");
        put(&game, "common/x/d.txt", "d");
        assert_eq!(v.list("common/x", Some("txt"), 0).len(), 4);
        v.invalidate(Some("common/x/d.txt"));
        assert_eq!(v.list("common/x", Some("txt"), 0).len(), 5);
        assert_eq!(v.version("common/x/b.txt"), v0);
        v.invalidate(None);
        assert_ne!(v.version("common/x/b.txt"), v0);
        let _ = std::fs::remove_dir_all(&game);
        let _ = std::fs::remove_dir_all(&modd);
    }
}
