//! The shared store: the world (a save's tree) and the definitions in plain memory that several
//! LuaJIT states, on separate OS threads, read and write through the FFI (docs/data_layer.md).
//!
//! The Rust side only allocates the regions, hands out ranges of them (atomically, so that workers
//! can allocate during a parallel phase) and interns strings (under a lock). The layout of the
//! records is the Lua side's (`sim/lua/engine/store/core.lua`, `ffi.cdef`); here they are bytes.
//!
//! Regions never move: every thread caches their pointers. Their memory is reserved at once and
//! committed by the kernel as it is touched (calloc of large sizes maps zero pages lazily), so the
//! capacities are virtual sizes, not memory use.
//!
//! - entries: 16-byte records (a key, a kind, an operator, a value: a string id, a number or a block)
//! - blocks: 16-byte records (the first entry, the count, the capacity, the key index)
//! - index: u32 slots of the blocks' key indexes
//! - strings: every key and text once (bytes, offsets, lengths), id 0 the empty string
//! - bytes: raw memory (bitmaps, per-phase arrays)
//! - roots: named block ids (the world, the definitions, the phase inputs)

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

/// The header the Lua side sees as `pdx_store` (sim/lua/engine/store/core.lua): keep in step.
#[repr(C)]
pub struct Header {
    pub entries: *mut u8,
    pub n_entries: AtomicU32,
    pub cap_entries: u32,
    pub blocks: *mut u8,
    pub n_blocks: AtomicU32,
    pub cap_blocks: u32,
    pub index: *mut u32,
    pub n_index: AtomicU32,
    pub cap_index: u32,
    pub str_bytes: *mut u8,
    pub str_off: *mut u32,
    pub str_len: *mut u32,
    pub n_str: AtomicU32,
    pub cap_str: u32,
    pub n_str_bytes: AtomicU32,
    pub cap_str_bytes: u32,
    pub bytes: *mut u8,
    pub n_bytes: AtomicU64,
    pub cap_bytes: u64,
    /// reserve(header, region, n) -> the first of n records of a region (0 entries, 1 blocks, 2
    /// index slots), or u32::MAX when the region is full
    pub reserve: extern "C" fn(*mut Header, u32, u32) -> u32,
    /// reserve_bytes(header, n) -> the offset of n bytes (8-aligned) in `bytes`, or u64::MAX
    pub reserve_bytes: extern "C" fn(*mut Header, u64) -> u64,
    /// intern(header, text, len) -> the string's id (made if new)
    pub intern: extern "C" fn(*mut Header, *const u8, usize) -> u32,
    /// lookup(header, text, len) -> the string's id, or 0 when it was never interned
    pub lookup: extern "C" fn(*mut Header, *const u8, usize) -> u32,
    pub interner: *mut c_void,
    /// fetch_add(header, slot, n) -> counters[slot] before adding n (atomic: work queues)
    pub fetch_add: extern "C" fn(*mut Header, u32, u64) -> u64,
    /// named roots (block ids), set by the Lua side: 0 the world, 1 the definitions, ...
    pub roots: [u32; 64],
    /// counters the Lua side may use (byte offsets of typed arrays, work queues, generations)
    pub counters: [AtomicU64; 64],
}

extern "C" fn fetch_add(h: *mut Header, slot: u32, n: u64) -> u64 {
    let h = unsafe { &*h };
    h.counters[(slot & 63) as usize].fetch_add(n, Ordering::AcqRel)
}

struct Interner {
    map: Mutex<HashMap<Box<[u8]>, u32>>,
}

/// The capacities, in records (entries, blocks, index slots, strings) and bytes.
#[derive(Clone, Copy, Debug)]
pub struct Capacity {
    pub entries: u32,
    pub blocks: u32,
    pub index: u32,
    pub strings: u32,
    pub string_bytes: u32,
    pub bytes: u64,
}

impl Capacity {
    /// The defaults, or `STELLAR_STORE_SCALE` times them (a factor, e.g. 0.25 on a small machine).
    /// On Windows the default factor is 0.25: its allocator commits a large allocation at once,
    /// where Linux maps pages as they are touched.
    pub fn from_env() -> Capacity {
        let default_scale = if cfg!(windows) { 0.25 } else { 1.0 };
        let scale: f64 = std::env::var("STELLAR_STORE_SCALE").ok().and_then(|s| s.parse().ok()).unwrap_or(default_scale);
        let s = |n: f64| (n * scale).max(1024.0);
        Capacity {
            entries: s(48.0 * 1048576.0) as u32,     // 768 MB virtual
            blocks: s(16.0 * 1048576.0) as u32,      // 256 MB
            index: s(32.0 * 1048576.0) as u32,       // 128 MB
            strings: s(8.0 * 1048576.0) as u32,      // 64 MB of offsets and lengths
            string_bytes: s(256.0 * 1048576.0) as u32,
            bytes: s(1024.0 * 1048576.0) as u64,
        }
    }
}

/// The store: its header and regions, freed when dropped.
pub struct Store {
    header: *mut Header,
    layouts: Vec<(*mut u8, std::alloc::Layout)>,
}

// The store is shared memory by design: the regions are written under the phase discipline
// (docs/data_layer.md: one writer per object in a parallel phase, the main thread otherwise), the
// counters are atomic and the interner is locked.
unsafe impl Send for Store {}
unsafe impl Sync for Store {}

/// A raw pointer to the header, to hand to worker threads.
#[derive(Clone, Copy)]
pub struct HeaderPtr(pub *mut Header);
unsafe impl Send for HeaderPtr {}
unsafe impl Sync for HeaderPtr {}

fn zeroed(size: usize, layouts: &mut Vec<(*mut u8, std::alloc::Layout)>) -> Result<*mut u8, String> {
    // 16-byte alignment: the allocator's calloc path (lazily committed zero pages for large sizes)
    let layout = std::alloc::Layout::from_size_align(size.max(16), 16).map_err(|e| e.to_string())?;
    let p = unsafe { std::alloc::alloc_zeroed(layout) };
    if p.is_null() {
        return Err(format!("the store: {size} bytes not available"));
    }
    layouts.push((p, layout));
    Ok(p)
}

extern "C" fn reserve(h: *mut Header, region: u32, n: u32) -> u32 {
    let h = unsafe { &*h };
    let (counter, cap) = match region {
        0 => (&h.n_entries, h.cap_entries),
        1 => (&h.n_blocks, h.cap_blocks),
        _ => (&h.n_index, h.cap_index),
    };
    let first = counter.fetch_add(n, Ordering::AcqRel);
    if first as u64 + n as u64 > cap as u64 {
        counter.fetch_sub(n, Ordering::AcqRel);
        return u32::MAX;
    }
    first
}

extern "C" fn reserve_bytes(h: *mut Header, n: u64) -> u64 {
    let h = unsafe { &*h };
    let n = (n + 7) & !7;
    let first = h.n_bytes.fetch_add(n, Ordering::AcqRel);
    if first + n > h.cap_bytes {
        h.n_bytes.fetch_sub(n, Ordering::AcqRel);
        return u64::MAX;
    }
    first
}

unsafe fn intern_in(h: &Header, map: &mut HashMap<Box<[u8]>, u32>, text: &[u8]) -> u32 {
    if let Some(&id) = map.get(text) {
        return id;
    }
    let id = h.n_str.load(Ordering::Acquire);
    let at = h.n_str_bytes.load(Ordering::Acquire);
    if id >= h.cap_str || at as u64 + text.len() as u64 > h.cap_str_bytes as u64 {
        return u32::MAX;
    }
    std::ptr::copy_nonoverlapping(text.as_ptr(), h.str_bytes.add(at as usize), text.len());
    *h.str_off.add(id as usize) = at;
    *h.str_len.add(id as usize) = text.len() as u32;
    h.n_str_bytes.store(at + text.len() as u32, Ordering::Release);
    h.n_str.store(id + 1, Ordering::Release);
    map.insert(text.to_vec().into_boxed_slice(), id);
    id
}

extern "C" fn intern(h: *mut Header, text: *const u8, len: usize) -> u32 {
    unsafe {
        let hd = &*h;
        let interner = &*(hd.interner as *const Interner);
        let mut map = interner.map.lock().unwrap();
        intern_in(hd, &mut map, std::slice::from_raw_parts(text, len))
    }
}

extern "C" fn lookup(h: *mut Header, text: *const u8, len: usize) -> u32 {
    unsafe {
        let hd = &*h;
        let interner = &*(hd.interner as *const Interner);
        let map = interner.map.lock().unwrap();
        map.get(std::slice::from_raw_parts(text, len)).copied().unwrap_or(0)
    }
}

impl Store {
    pub fn new(cap: Capacity) -> Result<Store, String> {
        let mut layouts = Vec::new();
        let entries = zeroed(cap.entries as usize * 16, &mut layouts)?;
        let blocks = zeroed(cap.blocks as usize * 16, &mut layouts)?;
        let index = zeroed(cap.index as usize * 4, &mut layouts)? as *mut u32;
        let str_bytes = zeroed(cap.string_bytes as usize, &mut layouts)?;
        let str_off = zeroed(cap.strings as usize * 4, &mut layouts)? as *mut u32;
        let str_len = zeroed(cap.strings as usize * 4, &mut layouts)? as *mut u32;
        let bytes = zeroed(cap.bytes as usize, &mut layouts)?;
        // the interner's map made as large as the strings can be: it never grows, so no intern
        // stops to move every string into a larger table (a frame cannot hold that once the
        // strings are many; docs/frame_timing.md). Its buckets are touched only as they fill.
        let map = HashMap::with_capacity(cap.strings as usize);
        let interner = Box::into_raw(Box::new(Interner { map: Mutex::new(map) })) as *mut c_void;
        let header = Box::into_raw(Box::new(Header {
            entries,
            // record 0 of every region is "none"
            n_entries: AtomicU32::new(1),
            cap_entries: cap.entries,
            blocks,
            n_blocks: AtomicU32::new(1),
            cap_blocks: cap.blocks,
            index,
            n_index: AtomicU32::new(1),
            cap_index: cap.index,
            str_bytes,
            str_off,
            str_len,
            n_str: AtomicU32::new(0),
            cap_str: cap.strings,
            n_str_bytes: AtomicU32::new(0),
            cap_str_bytes: cap.string_bytes,
            bytes,
            n_bytes: AtomicU64::new(8),
            cap_bytes: cap.bytes,
            reserve,
            reserve_bytes,
            intern,
            lookup,
            interner,
            fetch_add,
            roots: [0; 64],
            counters: std::array::from_fn(|_| AtomicU64::new(0)),
        }));
        // string 0 is the empty string (the key of a list's bare values)
        unsafe {
            let h = &*header;
            let it = &*(h.interner as *const Interner);
            let mut map = it.map.lock().unwrap();
            intern_in(h, &mut map, b"");
        }
        Ok(Store { header, layouts })
    }

    pub fn header(&self) -> HeaderPtr {
        HeaderPtr(self.header)
    }

    /// What is in use: entries, blocks, index slots, strings, string bytes, bytes.
    pub fn usage(&self) -> (u32, u32, u32, u32, u32, u64) {
        let h = unsafe { &*self.header };
        (
            h.n_entries.load(Ordering::Acquire),
            h.n_blocks.load(Ordering::Acquire),
            h.n_index.load(Ordering::Acquire),
            h.n_str.load(Ordering::Acquire),
            h.n_str_bytes.load(Ordering::Acquire),
            h.n_bytes.load(Ordering::Acquire),
        )
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        unsafe {
            let h = Box::from_raw(self.header);
            drop(Box::from_raw(h.interner as *mut Interner));
            for (p, layout) in self.layouts.drain(..) {
                std::alloc::dealloc(p, layout);
            }
        }
    }
}

/// The store and the worker pool of a runtime, made on demand from Lua (`RUST.store()`,
/// `RUST.pool_start(n)`).
#[derive(Default)]
pub struct Shared {
    pub store: Option<std::sync::Arc<Store>>,
    pub pool: Option<crate::workers::Pool>,
}

pub type Handle = std::rc::Rc<std::cell::RefCell<Shared>>;

/// Installs `RUST.store()` (the store's header as a light userdata, made on the first call),
/// `RUST.store_usage()`, and the worker pool's `RUST.pool_start(n)`, `RUST.pool_run(fn, arg)`
/// (on every worker; a table of their results, in worker order) and `RUST.pool_stop()`.
pub fn install(lua: &mlua::Lua) -> mlua::Result<Handle> {
    let shared: Handle = Default::default();
    let rust: mlua::Table = lua.globals().get("RUST")?;
    let s = shared.clone();
    rust.set(
        "store",
        lua.create_function(move |_, ()| {
            let mut sh = s.borrow_mut();
            if sh.store.is_none() {
                let st = Store::new(Capacity::from_env()).map_err(mlua::Error::RuntimeError)?;
                sh.store = Some(std::sync::Arc::new(st));
            }
            Ok(mlua::LightUserData(sh.store.as_ref().unwrap().header().0 as *mut c_void))
        })?,
    )?;
    let s = shared.clone();
    rust.set(
        "store_usage",
        lua.create_function(move |lua, ()| {
            let sh = s.borrow();
            let t = lua.create_table()?;
            if let Some(st) = &sh.store {
                let (e, b, i, n, nb, by) = st.usage();
                t.set("entries", e)?;
                t.set("blocks", b)?;
                t.set("index", i)?;
                t.set("strings", n)?;
                t.set("string_bytes", nb)?;
                t.set("bytes", by as f64)?;
            }
            Ok(t)
        })?,
    )?;
    // the machine's threads (the default worker count)
    rust.set(
        "cpus",
        lua.create_function(|_, ()| Ok(std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1)))?,
    )?;
    let s = shared.clone();
    rust.set(
        "pool_start",
        lua.create_function(move |_, n: usize| {
            let mut sh = s.borrow_mut();
            let store = sh.store.clone().ok_or_else(|| mlua::Error::RuntimeError("pool_start: no store".into()))?;
            sh.pool = None;
            let pool = crate::workers::Pool::new(n, store).map_err(mlua::Error::RuntimeError)?;
            sh.pool = Some(pool);
            Ok(n)
        })?,
    )?;
    let s = shared.clone();
    rust.set(
        "pool_run",
        lua.create_function(move |lua, (func, arg): (String, Option<String>)| {
            let sh = s.borrow();
            let pool = sh.pool.as_ref().ok_or_else(|| mlua::Error::RuntimeError("pool_run: no pool".into()))?;
            let results = pool.run(&func, arg.as_deref().unwrap_or(""));
            let t = lua.create_table()?;
            for (i, r) in results.into_iter().enumerate() {
                match r {
                    Ok(s) => t.set(i + 1, s)?,
                    Err(e) => return Err(mlua::Error::RuntimeError(format!("worker {i}: {e}"))),
                }
            }
            Ok(t)
        })?,
    )?;
    // RUST.pool_post(fn, arg) starts a job on every worker and returns at once; RUST.pool_poll(wait)
    // gives its results (as pool_run's) once all are in, waiting at most `wait` seconds, else nil:
    // a phase run in pieces waits for the workers across frames (engine.slice, docs/frame_timing.md)
    let s = shared.clone();
    rust.set(
        "pool_post",
        lua.create_function(move |_, (func, arg): (String, Option<String>)| {
            let sh = s.borrow();
            let pool = sh.pool.as_ref().ok_or_else(|| mlua::Error::RuntimeError("pool_post: no pool".into()))?;
            pool.post(&func, arg.as_deref().unwrap_or(""));
            Ok(())
        })?,
    )?;
    let s = shared.clone();
    rust.set(
        "pool_poll",
        lua.create_function(move |lua, wait: Option<f64>| {
            let sh = s.borrow();
            let pool = sh.pool.as_ref().ok_or_else(|| mlua::Error::RuntimeError("pool_poll: no pool".into()))?;
            let wait = std::time::Duration::from_secs_f64(wait.unwrap_or(3600.0).clamp(0.0, 3600.0));
            let Some(results) = pool.poll(wait) else { return Ok(mlua::Value::Nil) };
            let t = lua.create_table()?;
            for (i, r) in results.into_iter().enumerate() {
                match r {
                    Ok(s) => t.set(i + 1, s)?,
                    Err(e) => return Err(mlua::Error::RuntimeError(format!("worker {i}: {e}"))),
                }
            }
            Ok(mlua::Value::Table(t))
        })?,
    )?;
    let s = shared.clone();
    rust.set(
        "pool_stop",
        lua.create_function(move |_, ()| {
            s.borrow_mut().pool = None;
            Ok(())
        })?,
    )?;
    Ok(shared)
}
