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
    /// a job posted ([`Pool::post`]): the answers still to come, and those in
    outstanding: std::cell::Cell<usize>,
    answers: std::cell::RefCell<Vec<Result<String, String>>>,
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
    crate::cadence::fine_timers();
    let log = crate::cadence::register(&format!("lua-worker-{index}"));
    let mut earliest = 0.0;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Stop => break,
            Msg::Run(func, arg) => {
                let r = (|| -> mlua::Result<String> {
                    let f: mlua::Function = w.get(func.as_str())?;
                    let Some(cadence) = crate::cadence::current() else {
                        let out: Option<String> = f.call(arg)?;
                        return Ok(out.unwrap_or_default());
                    };
                    // the job in slices of the cadence, as the simulation's own thread: a
                    // coroutine the VM stops at each slice's deadline (crate::preempt)
                    let th = lua.create_thread(f)?;
                    let mut first = Some(arg);
                    loop {
                        let (slot_end, deadline) = cadence.wait_for_slice(earliest);
                        let start = crate::runtime::clock();
                        crate::preempt::arm(&lua, deadline);
                        let r = match first.take() {
                            Some(a) => th.resume::<Option<String>>(a),
                            None => th.resume::<Option<String>>(()),
                        };
                        crate::preempt::disarm(&lua);
                        let end = crate::runtime::clock();
                        log.lock().unwrap().record(start, end, slot_end);
                        earliest = cadence.next_start(end);
                        if th.status() != mlua::ThreadStatus::Resumable {
                            return Ok(r?.unwrap_or_default());
                        }
                        crate::cadence::sleep_until(earliest);
                    }
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
        let pool = Pool {
            workers,
            done,
            _store: store,
            outstanding: std::cell::Cell::new(0),
            answers: std::cell::RefCell::new(Vec::new()),
        };
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
        self.post(func, arg);
        loop {
            if let Some(out) = self.poll(std::time::Duration::from_secs(3600)) {
                return out;
            }
        }
    }

    /// Starts `engine.store.worker[func](arg)` on every worker and returns at once; the results
    /// come from [`Pool::poll`]. A job still running is waited for first.
    pub fn post(&self, func: &str, arg: &str) {
        while self.outstanding.get() > 0 {
            if self.poll(std::time::Duration::from_secs(3600)).is_some() {
                break;
            }
        }
        *self.answers.borrow_mut() = (0..self.workers.len()).map(|_| Err("no answer".to_string())).collect();
        self.outstanding.set(self.workers.len());
        for w in &self.workers {
            let _ = w.tx.send(Msg::Run(func.to_string(), arg.to_string()));
        }
    }

    /// The posted job's results in worker order once every worker has answered, waiting at most
    /// `wait` for them; None while some are still working.
    pub fn poll(&self, wait: std::time::Duration) -> Option<Vec<Result<String, String>>> {
        let until = std::time::Instant::now() + wait;
        while self.outstanding.get() > 0 {
            let left = until.saturating_duration_since(std::time::Instant::now());
            match self.done.recv_timeout(left) {
                Ok((i, r)) => {
                    self.answers.borrow_mut()[i] = r;
                    self.outstanding.set(self.outstanding.get() - 1);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => return None,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    self.outstanding.set(0);
                }
            }
        }
        Some(std::mem::take(&mut *self.answers.borrow_mut()))
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
