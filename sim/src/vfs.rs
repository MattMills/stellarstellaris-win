//! The game's files as the game sees them: the game directory with the enabled mods over it, one
//! file system per set of mounts, shared by every Lua state and thread of the process
//! (docs/script_loading.md).
//!
//! A mount later in the list wins for the same relative path, and a mount's `replace_path` folders
//! hide the files of the mounts before it in that folder (`stellar.script.source`'s rules, which
//! this replaces under it). A folder is listed as the game lists it (4.5.2, `VFSEnumerateFiles`):
//! to the depth the game reads it at ([`GAME_FOLDERS`]), sorted by byte order, a name once. Listings and path lookups are cached; a file's version is a counter that
//! [`Vfs::invalidate`] raises, so a cache keyed by (path, version) above (the parse cache in
//! `stellar.script.source`) stays valid until the file changes.
//!
//! What changed on disk is found by [`Vfs::scan`]: the files read (their size and modification
//! time when read) and the folders listed, compared with the disk. Each change is invalidated and
//! appended to the file system's change log, which every Lua state reads from its own place
//! ([`Vfs::changes_since`], `engine.reload.poll`).
//!
//! [`Vfs::watch`] does the same without being asked: a watcher on every mount (the `notify` crate),
//! its events gathered until 150 ms pass without one, then the paths they name checked as `scan`
//! checks everything ([`Vfs::check`]).
//!
//! Lua sees it as `RUST.vfs_open`, `vfs_list`, `vfs_dirs`, `vfs_path`, `vfs_read`, `vfs_version`,
//! `vfs_invalidate`, `vfs_scan`, `vfs_changes`, `vfs_changed` and `vfs_watch` ([`register`]);
//! a host asks [`change_count`] whether its Lua states have changes to apply.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

use mlua::{Lua, Table, Value};

/// A mount: a directory, and the folders (relative, `/`, no trailing slash) whose files it replaces.
#[derive(Clone, Debug)]
pub struct Mount {
    pub path: PathBuf,
    pub replace: HashSet<String>,
}

type ListKey = (String, Option<String>, i32);

include!("vfs_folders.rs");

/// The depth the game lists a folder at for files with this extension: its `VFSPreEnumerateFiles`
/// call's ([`GAME_FOLDERS`]: the entry for this extension, else the one for any file), and 0 for a
/// folder it doesn't pre-enumerate (`VFSGetEnumeratedFiles`' fallback); negative: all levels.
pub fn game_depth(sub: &str, ext: Option<&str>) -> i32 {
    let sub = sub.trim_end_matches('/');
    let ext = ext.map(|e| e.trim_start_matches('.').to_ascii_lowercase());
    let mut any = None;
    for (folder, e, depth) in GAME_FOLDERS {
        if *folder == sub {
            match (e, &ext) {
                (Some(e), Some(x)) if e.eq_ignore_ascii_case(x) => return *depth,
                (None, _) => any = any.or(Some(*depth)),
                _ => {}
            }
        }
    }
    any.unwrap_or(0)
}

/// One set of mounts and its caches.
pub struct Vfs {
    mounts: Vec<Mount>,
    lists: Mutex<HashMap<ListKey, Arc<Vec<String>>>>,
    paths: Mutex<HashMap<String, Option<PathBuf>>>,
    versions: Mutex<HashMap<String, u64>>,
    /// raised by an invalidation of everything: part of every file's version
    generation: AtomicU64,
    /// the files read: the path, size and modification time read
    read: Mutex<HashMap<String, Stamp>>,
    /// the relative paths found changed, in order (a change's sequence number is its index + 1)
    log: Mutex<Vec<String>>,
    /// the watcher, once started (Vfs::watch)
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

/// Every change logged by any file system of the process: a host compares it with the last it saw
/// to know whether its Lua states have changes to apply (engine.reload.poll).
static CHANGES: AtomicUsize = AtomicUsize::new(0);

/// The number of changes logged in the process so far.
pub fn change_count() -> usize {
    CHANGES.load(Ordering::Relaxed)
}

type Stamp = Option<(PathBuf, u64, Option<SystemTime>)>;

fn stamp_of(p: Option<PathBuf>) -> Stamp {
    let p = p?;
    let m = std::fs::metadata(&p).ok()?;
    Some((p, m.len(), m.modified().ok()))
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
            read: Mutex::new(HashMap::new()),
            log: Mutex::new(Vec::new()),
            watcher: Mutex::new(None),
        }
    }

    pub fn mounts(&self) -> &[Mount] {
        &self.mounts
    }

    /// The relative paths of `sub`'s files with extension `ext` (any when `None`; compared without
    /// case), `depth` folder levels down (0: `sub` itself; negative: all), sorted by byte order
    /// (`CString::operator<`: memcmp, then the shorter first). A name is listed once: the same
    /// name (exactly, as the game's `std::unique`) in a later mount is the same file; a mount that
    /// replaces `sub` drops what the mounts before it listed. Names starting with `.` are skipped.
    pub fn list(&self, sub: &str, ext: Option<&str>, depth: i32) -> Arc<Vec<String>> {
        let sub = sub.trim_end_matches('/').to_string();
        let ext = ext.map(|e| e.trim_start_matches('.').to_ascii_lowercase());
        let key = (sub.clone(), ext.clone(), depth);
        if let Some(l) = self.lists.lock().unwrap().get(&key) {
            return l.clone();
        }
        let out = Arc::new(self.list_now(&sub, ext.as_deref(), depth));
        self.lists.lock().unwrap().insert(key, out.clone());
        out
    }

    /// [`Vfs::list`] read from the disk now (`ext` lower case, without the dot).
    fn list_now(&self, sub: &str, ext: Option<&str>, depth: i32) -> Vec<String> {
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
            if m.replace.contains(sub) {
                names.clear();
                seen.clear();
            }
            let mut found = Vec::new();
            walk(&m.path.join(sub), "", depth, &mut found);
            for name in found {
                let wanted = match ext {
                    Some(e) => name.to_lowercase().ends_with(&format!(".{e}")),
                    None => true,
                };
                if wanted && seen.insert(name.clone()) {
                    names.push(name);
                }
            }
        }
        names.sort();
        names.into_iter().map(|n| if sub.is_empty() { n } else { format!("{sub}/{n}") }).collect()
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
        let found = self.path_now(rel);
        self.paths.lock().unwrap().insert(rel.to_string(), found.clone());
        found
    }

    fn path_now(&self, rel: &str) -> Option<PathBuf> {
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
        found
    }

    /// The bytes of the file the game reads for a relative path.
    pub fn read(&self, rel: &str) -> Result<Vec<u8>, String> {
        let p = self.path(rel);
        self.read.lock().unwrap().insert(rel.to_string(), stamp_of(p.clone()));
        let p = p.ok_or_else(|| format!("{rel}: no such file"))?;
        std::fs::read(&p).map_err(|e| format!("{}: {e}", p.display()))
    }

    /// The files changed on disk since they were read or listed: a file read whose winning path,
    /// size or modification time is not what was read, and the files added to or gone from a folder
    /// listed. Each is invalidated and appended to the change log; returns them.
    pub fn scan(&self) -> Vec<String> {
        let mut changed: Vec<String> = Vec::new();
        let mut set: HashSet<String> = HashSet::new();
        let read: Vec<(String, Stamp)> = self.read.lock().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        for (rel, was) in read {
            if stamp_of(self.path_now(&rel)) != was && set.insert(rel.clone()) {
                changed.push(rel);
            }
        }
        let lists: Vec<(ListKey, Arc<Vec<String>>)> = self.lists.lock().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        for ((sub, ext, depth), was) in lists {
            let now = self.list_now(&sub, ext.as_deref(), depth);
            if now != *was {
                let old: HashSet<&String> = was.iter().collect();
                let new: HashSet<&String> = now.iter().collect();
                for rel in old.symmetric_difference(&new) {
                    if set.insert((*rel).clone()) {
                        changed.push((*rel).clone());
                    }
                }
            }
        }
        changed.sort();
        self.changed(&changed);
        changed
    }

    /// [`Vfs::scan`] for these relative paths only (what a watcher's events named): a file read
    /// whose stamp changed, and the files added to or gone from the listed folders that hold one.
    pub fn check(&self, rels: &[String]) -> Vec<String> {
        let mut changed: Vec<String> = Vec::new();
        let mut set: HashSet<String> = HashSet::new();
        for rel in rels {
            let was = self.read.lock().unwrap().get(rel).cloned();
            if let Some(was) = was {
                if stamp_of(self.path_now(rel)) != was && set.insert(rel.clone()) {
                    changed.push(rel.clone());
                }
            }
        }
        let lists: Vec<(ListKey, Arc<Vec<String>>)> = self.lists.lock().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        for ((sub, ext, depth), was) in lists {
            let inside = rels.iter().any(|r| sub.is_empty() || r == &sub || r.starts_with(&format!("{sub}/")));
            if !inside {
                continue;
            }
            let now = self.list_now(&sub, ext.as_deref(), depth);
            if now != *was {
                let old: HashSet<&String> = was.iter().collect();
                let new: HashSet<&String> = now.iter().collect();
                for rel in old.symmetric_difference(&new) {
                    if set.insert((*rel).clone()) {
                        changed.push((*rel).clone());
                    }
                }
            }
        }
        changed.sort();
        self.changed(&changed);
        changed
    }

    /// The relative path (with `/`) of a path in one of the mounts.
    pub fn rel_of(&self, path: &Path) -> Option<String> {
        for m in &self.mounts {
            if let Ok(r) = path.strip_prefix(&m.path) {
                let s = r.to_string_lossy().replace('\\', "/");
                if !s.is_empty() {
                    return Some(s);
                }
            }
        }
        None
    }

    /// Watches every mount (once): what changes there is checked ([`Vfs::check`]) when 150 ms
    /// pass without another event, and logged.
    pub fn watch(self: &Arc<Self>) -> Result<(), String> {
        use notify::{EventKind, RecursiveMode, Watcher};
        let mut slot = self.watcher.lock().unwrap();
        if slot.is_some() {
            return Ok(());
        }
        let (tx, rx) = std::sync::mpsc::channel::<PathBuf>();
        let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(ev) = res {
                // opening and reading a file (ours too) changes nothing
                if matches!(ev.kind, EventKind::Access(_)) {
                    return;
                }
                for p in ev.paths {
                    let _ = tx.send(p);
                }
            }
        })
        .map_err(|e| format!("file watcher: {e}"))?;
        for m in &self.mounts {
            if m.path.is_dir() {
                w.watch(&m.path, RecursiveMode::Recursive).map_err(|e| format!("file watcher: {}: {e}", m.path.display()))?;
            }
        }
        let me = self.clone();
        std::thread::Builder::new()
            .name("vfs watcher".into())
            .spawn(move || loop {
                let Ok(first) = rx.recv() else { return };
                let mut paths: HashSet<PathBuf> = HashSet::new();
                paths.insert(first);
                loop {
                    match rx.recv_timeout(std::time::Duration::from_millis(150)) {
                        Ok(p) => {
                            paths.insert(p);
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => break,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
                    }
                }
                let mut rels: Vec<String> = paths.iter().filter_map(|p| me.rel_of(p)).collect();
                rels.sort();
                rels.dedup();
                me.check(&rels);
            })
            .map_err(|e| format!("file watcher: {e}"))?;
        *slot = Some(w);
        Ok(())
    }

    /// The changes after sequence number `since` (0: all), and the last sequence number.
    pub fn changes_since(&self, since: usize) -> (Vec<String>, usize) {
        let log = self.log.lock().unwrap();
        (log.get(since.min(log.len())..).unwrap_or(&[]).to_vec(), log.len())
    }

    /// Records changes (found by scan or check, or named by the caller): invalidated and logged.
    pub fn changed(&self, rels: &[String]) {
        if rels.is_empty() {
            return;
        }
        for rel in rels {
            self.invalidate(Some(rel));
            self.read.lock().unwrap().remove(rel);
        }
        self.log.lock().unwrap().extend(rels.iter().cloned());
        CHANGES.fetch_add(rels.len(), Ordering::Relaxed);
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
/// - `vfs_list(key, sub, ext [, depth])` -> sorted relative paths (depth: the game's for the
///   folder when nil); `vfs_dirs(key, sub)` -> folders; `vfs_depth(sub, ext)` -> the game's depth
/// - `vfs_path(key, rel)` -> the file's path or nil; `vfs_read(key, rel)` -> its text, or nil and a
///   message
/// - `vfs_version(key, rel)` -> a number; `vfs_invalidate(key [, rel])`
/// - `vfs_scan(key)` -> the files found changed; `vfs_changes(key, since)` -> the changes after
///   sequence number since, and the last one; `vfs_changed(key, rels)`: these changed (invalidated and logged); `vfs_watch(key)`: watch the
///   mounts ([`Vfs::watch`])
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
            let depth = depth.unwrap_or_else(|| game_depth(&sub, ext.as_deref()));
            let l = v.list(&sub, ext.as_deref(), depth);
            lua.create_sequence_from(l.iter().map(|s| s.as_str()))
        })?,
    )?;
    rust.set(
        "vfs_depth",
        lua.create_function(|_, (sub, ext): (String, Option<String>)| Ok(game_depth(&sub, ext.as_deref())))?,
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
        "vfs_scan",
        lua.create_function(|lua, key: String| lua.create_sequence_from(by_key(&key)?.scan()))?,
    )?;
    rust.set(
        "vfs_changes",
        lua.create_function(|lua, (key, since): (String, Option<usize>)| {
            let (list, last) = by_key(&key)?.changes_since(since.unwrap_or(0));
            Ok((lua.create_sequence_from(list)?, last))
        })?,
    )?;
    rust.set(
        "vfs_watch",
        lua.create_function(|_, key: String| Ok(by_key(&key)?.watch().map_err(mlua::Error::runtime)?))?,
    )?;
    rust.set(
        "vfs_changed",
        lua.create_function(|_, (key, rels): (String, Vec<String>)| {
            by_key(&key)?.changed(&rels);
            Ok(())
        })?,
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
        put(&modd, "common/x/A.txt", "mod A");
        put(&modd, "common/y/new.txt", "new");
        let mut replace = HashSet::new();
        replace.insert("common/y".to_string());
        let v = Vfs::new(vec![
            Mount { path: game.clone(), replace: HashSet::new() },
            Mount { path: modd.clone(), replace },
        ]);
        // byte order (upper case first), the mod's a.txt once, depth 0 skips sub/
        // a name differing in case is another name (the game's exact std::unique)
        assert_eq!(*v.list("common/x", Some("txt"), 0), vec!["common/x/A.txt", "common/x/B2.txt", "common/x/a.txt", "common/x/b.txt", "common/x/m.TXT"]);
        assert_eq!(*v.list("common/x", Some("txt"), -1), vec!["common/x/A.txt", "common/x/B2.txt", "common/x/a.txt", "common/x/b.txt", "common/x/m.TXT", "common/x/sub/c.txt"]);
        assert_eq!(v.read("common/x/a.txt").unwrap(), b"mod a");
        assert_eq!(v.read("common/x/b.txt").unwrap(), b"b");
        // the mod replaces common/y: the game's old.txt is gone from the listing and the lookup
        assert_eq!(*v.list("common/y", Some("txt"), 0), vec!["common/y/new.txt"]);
        assert!(v.path("common/y/old.txt").is_none());
        assert!(v.dirs("common").contains(&"common/x/sub".to_string()));
        // a change: the version moves and the listing is read again
        let v0 = v.version("common/x/b.txt");
        put(&game, "common/x/d.txt", "d");
        assert_eq!(v.list("common/x", Some("txt"), 0).len(), 5);
        v.invalidate(Some("common/x/d.txt"));
        assert_eq!(v.list("common/x", Some("txt"), 0).len(), 6);
        assert_eq!(v.version("common/x/b.txt"), v0);
        v.invalidate(None);
        assert_ne!(v.version("common/x/b.txt"), v0);
        let _ = std::fs::remove_dir_all(&game);
        let _ = std::fs::remove_dir_all(&modd);
    }

    #[test]
    fn scan_finds_changes() {
        let game = tmp("scan");
        put(&game, "common/z/a.txt", "a");
        put(&game, "common/z/b.txt", "b");
        let v = Vfs::new(vec![Mount { path: game.clone(), replace: HashSet::new() }]);
        assert_eq!(v.list("common/z", Some("txt"), 0).len(), 2);
        assert_eq!(v.read("common/z/a.txt").unwrap(), b"a");
        let v0 = v.version("common/z/a.txt");
        assert!(v.scan().is_empty());
        // a longer text (the size changes even within the clock's resolution), a new file, one gone
        put(&game, "common/z/a.txt", "a, changed");
        put(&game, "common/z/c.txt", "c");
        std::fs::remove_file(game.join("common/z/b.txt")).unwrap();
        let changed = v.scan();
        assert_eq!(changed, vec!["common/z/a.txt", "common/z/b.txt", "common/z/c.txt"]);
        assert_ne!(v.version("common/z/a.txt"), v0);
        assert_eq!(v.read("common/z/a.txt").unwrap(), b"a, changed");
        assert_eq!(*v.list("common/z", Some("txt"), 0), vec!["common/z/a.txt", "common/z/c.txt"]);
        let (all, last) = v.changes_since(0);
        assert_eq!((all.len(), last), (3, 3));
        assert!(v.changes_since(last).0.is_empty());
        assert!(v.scan().is_empty());
        let _ = std::fs::remove_dir_all(&game);
    }

    #[test]
    fn watcher_logs_changes() {
        let game = tmp("watch");
        put(&game, "common/w/a.txt", "a");
        let (_, v) = open(vec![Mount { path: game.clone(), replace: HashSet::new() }]);
        assert_eq!(v.list("common/w", Some("txt"), 0).len(), 1);
        assert_eq!(v.read("common/w/a.txt").unwrap(), b"a");
        v.watch().unwrap();
        let (_, before) = v.changes_since(0);
        put(&game, "common/w/a.txt", "a, changed by the test");
        put(&game, "common/w/b.txt", "b");
        // the events, the 150 ms quiet, the check
        let mut got = Vec::new();
        for _ in 0..50 {
            std::thread::sleep(std::time::Duration::from_millis(100));
            got = v.changes_since(before).0;
            if got.len() >= 2 {
                break;
            }
        }
        got.sort();
        got.dedup();
        assert_eq!(got, vec!["common/w/a.txt", "common/w/b.txt"]);
        assert_eq!(v.read("common/w/a.txt").unwrap(), b"a, changed by the test");
        let _ = std::fs::remove_dir_all(&game);
    }

    #[test]
    fn game_depths() {
        assert_eq!(game_depth("common/technology", Some("txt")), 0);
        assert_eq!(game_depth("common/terraform", Some("txt")), -1);
        assert_eq!(game_depth("common/inline_scripts", Some("txt")), -1);
        assert_eq!(game_depth("events", Some("txt")), 0);
        assert_eq!(game_depth("localisation", Some("yml")), -1);
        // map/galaxy: every file at depth 0, .txt at every depth
        assert_eq!(game_depth("map/galaxy", Some("txt")), -1);
        assert_eq!(game_depth("map/galaxy", None), 0);
        assert_eq!(game_depth("gfx/portraits/portraits", Some("txt")), 0);
    }
}
