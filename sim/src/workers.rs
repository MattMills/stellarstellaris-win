//! The worker pool: N LuaJIT states on N OS threads, all mapping the same store
//! (docs/data_layer.md, "Workers").
//!
//! Each worker makes its own Lua state (`runtime::new_lua`: the require paths, `RUST.clock`, ...),
//! with `RUST.store()` returning the shared store's header and `RUST.worker_index` /
//! `RUST.worker_count` set, and loads `engine.store.worker`. A job is a function of that module
//! called with a string argument on every worker at once; `Pool::run` returns when all are done
//! (the phase's barrier), with each worker's result string in worker order. A Lua error in a worker
//! is that worker's `Err`; the worker stays usable.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;

use crate::store::{HeaderPtr, Store};

enum Msg {
    Run(String, String),
    Stop,
}

struct Worker {
    tx: Sender<Msg>,
    handle: Option<JoinHandle<()>>,
}

pub struct Pool {
    workers: Vec<Worker>,
    done: Receiver<(usize, Result<String, String>)>,
    _store: Arc<Store>,
}

fn worker_main(
    index: usize,
    count: usize,
    header: HeaderPtr,
    rx: Receiver<Msg>,
    done: Sender<(usize, Result<String, String>)>,
) {
    let setup = || -> mlua::Result<(mlua::Lua, mlua::Table)> {
        let lua = crate::runtime::new_lua()?;
        let rust: mlua::Table = lua.globals().get("RUST")?;
        let h = header;
        rust.set("store", lua.create_function(move |_, ()| Ok(mlua::LightUserData(h.0 as *mut std::ffi::c_void)))?)?;
        rust.set("worker_index", index)?;
        rust.set("worker_count", count)?;
        let w: mlua::Table = lua.load("return require('engine.store.worker')").set_name("worker").eval()?;
        Ok((lua, w))
    };
    let (lua, w) = match setup() {
        Ok(x) => {
            let _ = done.send((index, Ok(String::new())));
            x
        }
        Err(e) => {
            let _ = done.send((index, Err(format!("worker setup: {e}"))));
            return;
        }
    };
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Stop => break,
            Msg::Run(func, arg) => {
                let r = (|| -> mlua::Result<String> {
                    let f: mlua::Function = w.get(func.as_str())?;
                    let out: Option<String> = f.call(arg)?;
                    Ok(out.unwrap_or_default())
                })();
                let _ = done.send((index, r.map_err(|e| e.to_string())));
            }
        }
    }
    drop(lua);
}

impl Pool {
    /// N workers over the store; returns once every worker has loaded the engine's store modules.
    pub fn new(n: usize, store: Arc<Store>) -> Result<Pool, String> {
        let (done_tx, done) = channel();
        let header = store.header();
        let mut workers = Vec::new();
        for i in 0..n {
            let (tx, rx) = channel();
            let d = done_tx.clone();
            let handle = std::thread::Builder::new()
                .name(format!("lua-worker-{i}"))
                .stack_size(16 << 20)
                .spawn(move || worker_main(i, n, header, rx, d))
                .map_err(|e| e.to_string())?;
            workers.push(Worker { tx, handle: Some(handle) });
        }
        let pool = Pool { workers, done, _store: store };
        let mut errors = Vec::new();
        for _ in 0..n {
            match pool.done.recv() {
                Ok((_, Ok(_))) => {}
                Ok((i, Err(e))) => errors.push(format!("worker {i}: {e}")),
                Err(e) => errors.push(e.to_string()),
            }
        }
        if !errors.is_empty() {
            return Err(errors.join("; "));
        }
        Ok(pool)
    }

    pub fn len(&self) -> usize {
        self.workers.len()
    }

    /// `engine.store.worker[func](arg)` on every worker; their results in worker order.
    pub fn run(&self, func: &str, arg: &str) -> Vec<Result<String, String>> {
        for w in &self.workers {
            let _ = w.tx.send(Msg::Run(func.to_string(), arg.to_string()));
        }
        let mut out: Vec<Result<String, String>> = (0..self.workers.len()).map(|_| Err("no answer".to_string())).collect();
        for _ in 0..self.workers.len() {
            match self.done.recv() {
                Ok((i, r)) => out[i] = r,
                Err(_) => break,
            }
        }
        out
    }
}

impl Drop for Pool {
    fn drop(&mut self) {
        for w in &self.workers {
            let _ = w.tx.send(Msg::Stop);
        }
        for w in &mut self.workers {
            if let Some(h) = w.handle.take() {
                let _ = h.join();
            }
        }
    }
}
