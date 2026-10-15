# sim/vendor

## luajit-src (LuaJIT 2.1, patched)

`luajit-src` 210.6.6+707c12b from crates.io (the sources of LuaJIT 2.1 and the logic to build them,
which `mlua`'s `vendored` feature uses), changed so that a deadline stops compiled Lua code as it
stops interpreted code, and so that what no hook can stop stays clear of a deadline
(`sim/src/preempt.rs`, docs/frame_timing.md). Every change is marked `stellarstellaris` in the
source.

Compiled code checks the hooks:

- `luajit2/src/lj_record.c` defines `LUAJIT_ENABLE_CHECKHOOK`, LuaJIT's own compile-time option:
  every trace checks the instruction and line hooks at its start (and so at every iteration of a
  loop, which the loop optimisation copies the check into) and exits to the interpreter when one is
  set. A hook set with a count of 1 from another thread then stops the code at its next instruction,
  compiled or not (the use LuaJIT's comment there describes). The check is a load, a mask and a
  branch.
- `luajit2/src/lj_trace.c` (`lj_trace_exit`): an exit with an instruction or line hook set goes back
  to the interpreter as a profiler's exit does, without counting towards a side trace (a deadline's
  exits would otherwise grow side traces from the hook check).

The JIT's compiler and the collector know the slice's deadline (`stellar_set_deadline(remaining,
room, gc_room)`, called by `preempt::arm` and `disarm`; per thread, as a thread runs one VM):

- `lj_trace.c`: no trace starts (`lj_trace_hot`, a hot side exit, a stitch) in the last `room`
  seconds before the deadline (0.4 ms): a trace's recording and compile cannot be stopped, and one
  started there ran past it. A hot loop tries again 16 iterations later, in the next slice.
- `lj_trace.c` (`trace_abort`): a recording aborted asynchronously (the preempter's `lua_sethook`
  aborts the recording in progress, as any hook change does) is not penalized: LuaJIT blacklists a
  loop after about ten aborts, and a slice's deadline was not the trace's fault.
- `lj_gc.c` (`lj_gc_step`): no collector step in the last `gc_room` seconds (0.25 ms): the debt
  stays, the threshold moves 16 KB on, and the steps come in the next slice. A step is not stopped
  by a hook, and some are long (the atomic phase, a large table marked).

The machine code is not write-protected while it runs:

- `lj_arch.h` sets `LUAJIT_SECURITY_MCODE` to 0 (RWX machine code). With LuaJIT's default (RW^X)
  each trace compiled changed the protection of its 1 MB area twice, two `mprotect` calls and two
  TLB shootdowns on every core running a thread of the process: 0.05 ms a trace on average, up to
  0.4 ms (35 days sliced: the compiler's time on the simulation's thread from 1.18 s to 0.55 s, its
  steps over 0.1 ms from 854 to 7). The cost is the hardening W^X gives against a memory-corruption
  bug writing machine code.

A record of what no hook stops, per thread (`stellar_stalls`, read by `preempt::stalls`): the time
in the collector's phases (mark, atomic and its parts, sweep, finalize), in the compiler, each
trace's optimization and assembly by its size, and the traces and collector steps put off to the
next slice. The frame timing report prints it for the sliced mode.

`sim/Cargo.toml` and `sim/render/Cargo.toml` take it with `[patch.crates-io]`. Cargo does not see a
change to the C sources: after one, `cargo clean -p mlua-sys -p luajit-src` (mlua-sys builds
LuaJIT). To update LuaJIT: replace the directory with the new crate's sources and make the changes
again (search the old copy for `stellarstellaris`).
