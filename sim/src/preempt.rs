//! Preemption at the Lua VM: a coroutine runs until a deadline and the VM itself stops it, whatever
//! Lua code it is in (docs/frame_timing.md). While a slice runs, the VM's own thread keeps a count
//! hook on it (every `EVERY` instructions); the hook reads the platform's clock and, past the
//! deadline, yields the running coroutine (`lua_yield` from a hook: LuaJIT adds a continuation frame
//! and the coroutine goes on at the same instruction when it is resumed). Nothing in the scripts
//! takes part.
//!
//! What it cannot stop: a call into C or Rust in progress (a `table.sort` with a Lua comparator, a
//! Rust function the engine calls, a wait on the worker pool), a step of the collector, and a trace
//! of compiled code (the hooks run in the interpreter only). Where the coroutine cannot yield (a
//! comparator's call from C, a metamethod called from C) the hook waits for the next instruction
//! where it can.
//!
//! LuaJIT's hooks belong to the VM (all its coroutines), and only the VM's own thread sets them
//! (`lua_sethook` also aborts a trace being recorded, which another thread may not touch).

use std::cell::Cell;
use std::os::raw::c_int;

use mlua::ffi;

/// Instructions between two looks at the clock.
pub const EVERY: c_int = 1000;

thread_local! {
    /// The deadline of the slice running on this thread (each VM runs on one thread).
    static DEADLINE: Cell<f64> = const { Cell::new(f64::INFINITY) };
    /// The hook's yields on this thread, and its looks at the clock that could not yield.
    static YIELDS: Cell<u64> = const { Cell::new(0) };
    static REFUSED: Cell<u64> = const { Cell::new(0) };
}

extern "C-unwind" {
    // LuaJIT 2.1 has it (lj_api.c); mlua-sys declares it for Lua 5.3+ only.
    fn lua_isyieldable(L: *mut ffi::lua_State) -> c_int;
}

unsafe extern "C-unwind" fn hook(state: *mut ffi::lua_State, _ar: *mut ffi::lua_Debug) {
    if crate::runtime::clock() < DEADLINE.with(|d| d.get()) {
        return;
    }
    if lua_isyieldable(state) == 0 {
        REFUSED.with(|r| r.set(r.get() + 1));
        return;
    }
    YIELDS.with(|y| y.set(y.get() + 1));
    // (no value of this frame needs dropping: lua_yield unwinds through it)
    ffi::lua_yield(state, 0);
}

/// Sets the hook on `lua`'s VM for a slice that ends at `deadline` (on `runtime::clock`).
pub fn arm(lua: &mlua::Lua, deadline: f64) {
    DEADLINE.with(|d| d.set(deadline));
    unsafe {
        let _ = lua.exec_raw::<()>((), |state| {
            ffi::lua_sethook(state, Some(hook), ffi::LUA_MASKCOUNT, EVERY);
        });
    }
}

/// Takes the hook off `lua`'s VM (the slice is over).
pub fn disarm(lua: &mlua::Lua) {
    DEADLINE.with(|d| d.set(f64::INFINITY));
    unsafe {
        let _ = lua.exec_raw::<()>((), |state| {
            ffi::lua_sethook(state, None, 0, 0);
        });
    }
}

/// This thread's hook yields, and the looks past the deadline where the coroutine could not yield.
pub fn counts() -> (u64, u64) {
    (YIELDS.with(|y| y.get()), REFUSED.with(|r| r.get()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // A loop with no yield of its own, run in slices of 1 ms: the number of slices, the longest
    // slice, and whether it reached the result of a whole run.
    fn sliced(jit: bool) -> (usize, f64, bool) {
        let lua = crate::runtime::new_lua().unwrap();
        lua.load(if jit { "jit.on()" } else { "jit.off()" }).exec().unwrap();
        let code = "local s = 0 for i = 1, 2e7 do s = (s + i * 7) % 1000003 end return s";
        let whole: i64 = lua.load(code).call(()).unwrap();
        let th = lua.create_thread(lua.load(code).into_function().unwrap()).unwrap();
        let (mut slices, mut longest) = (0, 0.0f64);
        let result: i64 = loop {
            let t = crate::runtime::clock();
            arm(&lua, t + 0.001);
            let r = th.resume::<Option<i64>>(());
            disarm(&lua);
            longest = longest.max(crate::runtime::clock() - t);
            slices += 1;
            if th.status() != mlua::ThreadStatus::Resumable {
                break r.unwrap().unwrap();
            }
        };
        (slices, longest, result == whole)
    }

    #[test]
    fn preempts_interpreted_code() {
        let (slices, longest, same) = sliced(false);
        eprintln!("interpreted: {slices} slices, the longest {:.3} ms", longest * 1000.0);
        assert!(same);
        assert!(slices > 1, "the loop was not stopped");
        assert!(longest < 0.0015, "a slice of {:.3} ms", longest * 1000.0);
    }

    #[test]
    fn compiled_code() {
        // a trace of compiled code does not run the hooks: what the VM stops of a hot loop
        let (slices, longest, same) = sliced(true);
        eprintln!("compiled: {slices} slices, the longest {:.3} ms", longest * 1000.0);
        assert!(same);
    }
}
