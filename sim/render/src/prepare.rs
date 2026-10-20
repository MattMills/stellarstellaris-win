//! Windows prepared ahead, off the UI thread (docs/profiling.md section 10).
//!
//! Most of a window's first opening that is not its Lua is Rust work on the UI thread: textures
//! and cube maps read and decoded (dds.rs), their mip chains made (render::premip), the index of
//! gfx/models' texture names walked (models.rs). None of it needs a Lua state, so worker threads
//! do it while the save loads, from what each window used before:
//!
//! - **What a window uses** is recorded as it is built: the textures and cube maps decoded while
//!   the scene is built with a window open ([`set_window`], `App::scene`) are noted under that
//!   window (`designer`, a left bar view's name, `diplomacy`, `planet`, `fleet`, `starbase`) in a
//!   manifest file kept between runs ([`manifest_path`]: STELLAR_PREPARE_FILE, else the user's
//!   cache directory), with a few known from the game's files ([`SEED`]).
//! - **At a load** ([`start`]) worker threads (STELLAR_PREPARE_THREADS, 3; 0 turns it off) decode
//!   the manifest's assets into a shared store and make their mip chains, the gfx/models index
//!   too; [`crate::dds::Cache`] takes an asset from the store instead of decoding it
//!   ([`take`]), and the upload finds its mip chain made. At most STELLAR_PREPARE_MB (256) of
//!   decoded images are prepared a load (and forgotten at the next one).
//! - **Pinned on the GPU**: each asset decoded is queued for the render thread, which uploads it
//!   in its idle frames within its upload budget ([`next_pins`], `Renderer::pin`) under the name the
//!   scenes give it, so that a window's first scene finds its textures on the GPU already (the
//!   renderer keeps them for the session). At most STELLAR_PIN_MB (1024; 0: none) pinned, in the
//!   manifest's order (the designer's first); none on a CPU adapter (lavapipe: a second copy in
//!   memory); an upload the GPU refuses (out of memory) stops the pinning ([`pin_failed`]) and the
//!   windows upload their textures themselves, from the decoded store, as without it.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex, OnceLock};

use crate::dds::{self, Image};

type Decoded = Result<Arc<Image>, String>;

/// Assets known from the game's files, prepared before any run recorded them: the ship
/// designer's world (gfx/worldgfx/ship_designer.txt: its environment map, background and colour
/// correction).
const SEED: &[(&str, &str)] = &[
    ("designer", "cube16:gfx/worldgfx/cubemap_filtered_ldr.dds"),
    ("designer", "cube1:gfx/map/sky_rim.dds"),
    ("designer", "gfx/worldgfx/colorcorrection_neutral.tga"),
];

/// The assets decoded and waiting for the render thread to pin them on the GPU (the renderer's
/// name for each: `PATH`, `cube:PATH`, `cubeN:PATH`; whether a cube map), the bytes pinned, and
/// whether pinning is on.
struct Pins {
    queue: std::collections::VecDeque<(usize, String, bool, Arc<Image>)>,
    bytes: usize,
    on: bool,
    /// the workers still decoding (the total logged once they are done and all is pinned)
    workers: usize,
    /// the assets left unpinned for the budget (the first one logged)
    skipped: usize,
}

fn pins() -> &'static Mutex<Pins> {
    static P: OnceLock<Mutex<Pins>> = OnceLock::new();
    P.get_or_init(|| {
        let mb = std::env::var("STELLAR_PIN_MB").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(1024);
        Mutex::new(Pins { queue: Default::default(), bytes: 0, on: mb > 0, workers: 0, skipped: 0 })
    })
}

fn pin_budget() -> usize {
    // (1 GB: a 4 GB GPU's quarter, compressed textures counted as their blocks)
    std::env::var("STELLAR_PIN_MB").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(1024) << 20
}

/// The assets to pin on the GPU now, about `budget` bytes of them (one at least): for the render
/// thread's idle frames. None once pinning is off or its budget spent.
pub fn next_pins(budget: usize) -> Vec<(String, bool, Arc<Image>)> {
    let mut p = pins().lock().unwrap();
    let mut out = Vec::new();
    let mut spent = 0;
    while p.on {
        let Some(front) = p.queue.front() else { break };
        let bytes = gpu_cost(&front.3);
        // (one that does not fit the budget left: uploaded when used, the others pinned)
        if p.bytes + bytes > pin_budget() {
            let (_, name, _, _) = p.queue.pop_front().unwrap();
            if p.skipped == 0 {
                eprintln!("prepare: {name} ({} MB) not pinned, nor the others past STELLAR_PIN_MB: {} MB pinned", bytes >> 20, p.bytes >> 20);
            }
            p.skipped += 1;
            continue;
        }
        if !out.is_empty() && spent + bytes > budget {
            break;
        }
        spent += bytes;
        p.bytes += bytes;
        let (_, name, cube, img) = p.queue.pop_front().unwrap();
        out.push((name, cube, img));
    }
    if p.on && p.workers == 0 && p.queue.is_empty() && !out.is_empty() {
        eprintln!("prepare: {} MB of the windows' textures pinned on the GPU", p.bytes >> 20);
    }
    out
}

/// The GPU refused a pinned upload (out of memory), or the adapter is the CPU: no more pinning;
/// the windows upload what they use when they are built, as without it.
pub fn pin_failed(why: &str) {
    let mut p = pins().lock().unwrap();
    if p.on {
        p.on = false;
        p.queue.clear();
        eprintln!("prepare: no more textures pinned on the GPU ({why}; {} MB pinned)", p.bytes >> 20);
    }
}

/// The bytes read and waiting to be pinned (0 once pinning is off).
fn pins_waiting() -> usize {
    let p = pins().lock().unwrap();
    if !p.on {
        return 0;
    }
    p.queue.iter().map(|e| gpu_cost(&e.3)).sum()
}

fn ahead_budget() -> usize {
    std::env::var("STELLAR_PREPARE_AHEAD_MB").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(128) << 20
}

/// The renderer's name of an asset of the store (`cube1:` is `cube:` there: scene::Textures).
fn renderer_name(key: &str) -> (String, bool) {
    match key.strip_prefix("cube").and_then(|r| r.split_once(':')) {
        Some(("1", rel)) => (format!("cube:{rel}"), true),
        Some(_) => (key.to_string(), true),
        None => (key.to_string(), false),
    }
}

/// The decoded assets waiting to be taken, by dds::Cache's keys (`PATH`, `cubeN:PATH`).
fn store() -> &'static Mutex<HashMap<String, Decoded>> {
    static S: OnceLock<Mutex<HashMap<String, Decoded>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// What each window used (window -> asset keys), as read from the manifest and recorded since;
/// whether something new was recorded (to write).
fn manifest() -> &'static Mutex<(BTreeMap<String, BTreeSet<String>>, bool)> {
    static M: OnceLock<Mutex<(BTreeMap<String, BTreeSet<String>>, bool)>> = OnceLock::new();
    M.get_or_init(|| Mutex::new((read_manifest(), false)))
}

thread_local! {
    /// the window being built on this thread ([`set_window`])
    static WINDOW: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

/// The manifest's file: STELLAR_PREPARE_FILE, else `stellar-render/prepare.txt` in the user's
/// cache directory (XDG_CACHE_HOME, ~/.cache, LOCALAPPDATA).
pub fn manifest_path() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("STELLAR_PREPARE_FILE") {
        return (!p.is_empty()).then(|| p.into());
    }
    let base = std::env::var("XDG_CACHE_HOME")
        .ok()
        .filter(|v| !v.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var("HOME").ok().filter(|v| !v.is_empty()).map(|h| std::path::Path::new(&h).join(".cache")))
        .or_else(|| std::env::var("LOCALAPPDATA").ok().filter(|v| !v.is_empty()).map(std::path::PathBuf::from))?;
    Some(base.join("stellar-render").join("prepare.txt"))
}

/// The manifest: lines `WINDOW<TAB>KEY`.
fn read_manifest() -> BTreeMap<String, BTreeSet<String>> {
    let mut m: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (w, k) in SEED {
        m.entry(w.to_string()).or_default().insert(k.to_string());
    }
    if let Some(text) = manifest_path().and_then(|p| std::fs::read_to_string(p).ok()) {
        for line in text.lines() {
            if let Some((w, k)) = line.split_once('\t') {
                m.entry(w.to_string()).or_default().insert(k.to_string());
            }
        }
    }
    m
}

/// The window whose scene is built now on this thread (None: none, or the map alone): the assets
/// decoded meanwhile are recorded under it.
pub fn set_window(window: Option<String>) {
    WINDOW.with(|w| *w.borrow_mut() = window);
}

/// An asset decoded on the UI thread (dds::Cache): recorded under the window being built.
pub fn record(key: &str) {
    let Some(window) = WINDOW.with(|w| w.borrow().clone()) else { return };
    let mut m = manifest().lock().unwrap();
    if m.0.entry(window).or_default().insert(key.to_string()) {
        m.1 = true;
    }
}

/// The manifest written if something new was recorded (after a scene: a few kilobytes).
pub fn save() {
    let text = {
        let mut m = manifest().lock().unwrap();
        if !m.1 {
            return;
        }
        m.1 = false;
        let seed: BTreeSet<(&str, &str)> = SEED.iter().copied().collect();
        let mut out = String::new();
        for (w, keys) in &m.0 {
            for k in keys {
                if !seed.contains(&(w.as_str(), k.as_str())) {
                    out.push_str(&format!("{w}\t{k}\n"));
                }
            }
        }
        out
    };
    let Some(path) = manifest_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(e) = std::fs::write(&path, text) {
        eprintln!("prepare: {}: {e}", path.display());
    }
}

/// An asset prepared ahead (decoded, its mip chain made), taken from the store.
pub fn take(key: &str) -> Option<Decoded> {
    store().lock().unwrap().remove(key)
}

/// The index of gfx/models' textures by name (lower case -> the shortest path), walked once,
/// on a worker at a load ([`start`]) or by the first model that needs it.
pub fn dds_names(game_dir: &str) -> Arc<HashMap<String, String>> {
    static NAMES: OnceLock<Mutex<Option<(String, Arc<HashMap<String, String>>)>>> = OnceLock::new();
    let lock = NAMES.get_or_init(Default::default);
    let mut g = lock.lock().unwrap();
    if let Some((gd, n)) = g.as_ref() {
        if gd == game_dir {
            return n.clone();
        }
    }
    let _s = crate::prof::span("prepare: gfx/models' texture names");
    let mut out = HashMap::new();
    let mut stack = vec![std::path::PathBuf::from(format!("{game_dir}/gfx/models"))];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("dds")) {
                let rel = p.strip_prefix(game_dir).map(|r| r.to_string_lossy().replace('\\', "/")).unwrap_or_default();
                let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
                // the shortest path wins (the shared ones higher up)
                let rel = rel.trim_start_matches('/').to_string();
                match out.get(&name) {
                    Some(old) if String::len(old) <= rel.len() => {}
                    _ => {
                        out.insert(name, rel);
                    }
                }
            }
        }
    }
    let n = Arc::new(out);
    *g = Some((game_dir.to_string(), n.clone()));
    n
}

/// An asset read as dds::Cache would (`PATH`, `cubeN:PATH`): compressed for the GPU where it may
/// be, else decoded (dds.rs load_texture, load_cube_texture).
fn decode(game_dir: &str, key: &str) -> Decoded {
    if let Some((levels, rel)) = key.strip_prefix("cube").and_then(|r| r.split_once(':')).and_then(|(n, rel)| Some((n.parse::<u32>().ok()?, rel))) {
        let path = dds::find_case_insensitive(game_dir, rel).unwrap_or_else(|| format!("{game_dir}/{rel}"));
        return dds::load_cube_texture(&path, levels);
    }
    let tga_dds = key.strip_suffix(".tga").map(|b| format!("{b}.dds"));
    let path = dds::find_case_insensitive(game_dir, key)
        .or_else(|| tga_dds.as_ref().and_then(|d| dds::find_case_insensitive(game_dir, d)))
        .unwrap_or_else(|| format!("{game_dir}/{key}"));
    dds::load_texture(key, &path)
}

/// Prepares, on worker threads, every window's recorded assets (the designer's first), and the
/// gfx/models texture index; returns at once. Called where a load begins.
pub fn start(game_dir: &str) {
    // (what the last load prepared and no window took: forgotten)
    store().lock().unwrap().clear();
    let threads = std::env::var("STELLAR_PREPARE_THREADS").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(3);
    if threads == 0 {
        return;
    }
    let budget = std::env::var("STELLAR_PREPARE_MB").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(256) << 20;
    // the designer's first (the costliest window), then the others by name; each asset once
    let keys: Vec<String> = {
        let m = manifest().lock().unwrap();
        let mut seen = BTreeSet::new();
        let mut keys = Vec::new();
        let designer = m.0.get("designer").into_iter();
        for set in designer.chain(m.0.iter().filter(|(w, _)| *w != "designer").map(|(_, s)| s)) {
            for k in set {
                if seen.insert(k.clone()) {
                    keys.push(k.clone());
                }
            }
        }
        keys
    };
    {
        let gd = game_dir.to_string();
        let _ = std::thread::Builder::new().name("prepare".into()).spawn(move || {
            dds_names(&gd);
        });
    }
    spawn(game_dir, keys.into_iter().enumerate().collect(), threads, budget);
}

/// More assets to prepare, after the manifest's (their pins after its): the textures the game can
/// show (texture_set.lua, App::warm), in their order; those prepared already skipped.
pub fn add(game_dir: &str, keys: Vec<String>) {
    let threads = std::env::var("STELLAR_PREPARE_THREADS").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(3);
    if threads == 0 || keys.is_empty() {
        return;
    }
    let budget = std::env::var("STELLAR_PREPARE_MB").ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(256) << 20;
    spawn(game_dir, keys.into_iter().enumerate().map(|(i, k)| (1_000_000 + i, k)).collect(), threads, budget);
}

/// What an image prepared holds in memory until a window takes it: its pixels decoded, or its
/// compressed levels while they are not on the GPU (pinning off).
fn ram_cost(img: &Arc<Image>) -> usize {
    if !img.rgba.is_empty() {
        return img.rgba.len();
    }
    if pins().lock().unwrap().on {
        return 0;
    }
    dds::compressed_of(img).map_or(0, |c| c.bytes())
}

/// What an image takes on the GPU pinned: its compressed levels, or its pixels with their mips.
fn gpu_cost(img: &Arc<Image>) -> usize {
    if img.rgba.is_empty() {
        dds::compressed_of(img).map_or(0, |c| c.bytes())
    } else {
        img.rgba.len() * 4 / 3
    }
}

/// Worker threads preparing `keys` (index, key: the pins' order) within `budget` bytes of memory.
fn spawn(game_dir: &str, keys: Vec<(usize, String)>, threads: usize, budget: usize) {
    // (the keys left; the bytes kept in memory; the bytes queued for the GPU)
    let queue = Arc::new(Mutex::new((keys.into_iter(), 0usize, 0usize)));
    let gd = game_dir.to_string();
    pins().lock().unwrap().workers += threads;
    for i in 0..threads {
        let (queue, gd) = (queue.clone(), gd.clone());
        let _ = std::thread::Builder::new().name(format!("prepare-{i}")).spawn(move || loop {
            let (index, key) = {
                let mut q = queue.lock().unwrap();
                // (the memory's budget spent, or the GPU's: what is left is read when a window uses it)
                if q.1 >= budget || (pins().lock().unwrap().on && q.2 >= pin_budget()) {
                    pins().lock().unwrap().workers -= 1;
                    return;
                }
                match q.0.next() {
                    Some(k) => k,
                    None => {
                        pins().lock().unwrap().workers -= 1;
                        return;
                    }
                }
            };
            // (no more than STELLAR_PREPARE_AHEAD_MB (128) read and waiting for the render thread to pin
            // it: what is pinned is freed here, so the memory stays near the GPU's use)
            while pins_waiting() > ahead_budget() {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            // (already decoded on the UI thread, or by another load's workers: skipped)
            if store().lock().unwrap().contains_key(&key) {
                continue;
            }
            let _s = crate::prof::span("prepare: an asset decoded, its mips");
            let r = decode(&gd, &key);
            if let Ok(img) = &r {
                // (a cube map uploads its own levels: no 2D chain)
                if !key.starts_with("cube") {
                    crate::render::premip(img);
                }
                {
                    let (ram, gpu) = (ram_cost(img), gpu_cost(img));
                    let mut q = queue.lock().unwrap();
                    q.1 += ram;
                    q.2 += gpu;
                }
                let mut p = pins().lock().unwrap();
                if p.on {
                    // (in the manifest's order, whichever worker finished first)
                    let (name, cube) = renderer_name(&key);
                    let at = p.queue.iter().position(|e| e.0 > index).unwrap_or(p.queue.len());
                    p.queue.insert(at, (index, name, cube, img.clone()));
                }
            }
            store().lock().unwrap().insert(key, r);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_are_noted_under_the_window_built() {
        // (no window: nothing noted)
        set_window(None);
        record("gfx/test/none.dds");
        set_window(Some("test_window".into()));
        record("gfx/test/a.dds");
        record("cube16:gfx/test/b.dds");
        set_window(None);
        let m = manifest().lock().unwrap();
        let keys = m.0.get("test_window").cloned().unwrap_or_default();
        assert_eq!(keys.into_iter().collect::<Vec<_>>(), ["cube16:gfx/test/b.dds", "gfx/test/a.dds"]);
        assert!(!m.0.values().any(|s| s.contains("gfx/test/none.dds")));
        // the seed is there before any run noted anything
        assert!(m.0.get("designer").is_some_and(|s| s.contains("cube16:gfx/worldgfx/cubemap_filtered_ldr.dds")));
    }

    #[test]
    fn a_prepared_asset_is_taken_once() {
        let img = Arc::new(Image { width: 1, height: 1, rgba: vec![0; 4], format: "test".into() });
        store().lock().unwrap().insert("gfx/test/taken.dds".into(), Ok(img));
        assert!(take("gfx/test/taken.dds").is_some_and(|r| r.is_ok()));
        assert!(take("gfx/test/taken.dds").is_none());
    }
}
