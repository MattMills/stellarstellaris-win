#pragma once

#include <cstdint>
#include <mutex>

// Creates the Lua state and runs lua/init.lua from the directory of stellar-injected.dll. Called
// once, by the init thread.
void stellar_lua_start();

// Calls stellar.heartbeat(count) if a script set it: count is 1, 2, ... Called by the init thread
// every second.
void stellar_lua_heartbeat(uint64_t count);

// The Lua state is not thread-safe: hold this lock to call into Lua from any thread.
std::recursive_mutex& stellar_lua_lock();

struct lua_State;

// The main Lua state, or null before stellar_lua_start (hold stellar_lua_lock to use it).
lua_State* stellar_lua_state();

// The calling thread's own Lua state, made on first use by running lua/worker.lua (no lock: only
// this thread uses it); null before stellar_lua_start, or if it could not be made.
lua_State* stellar_worker_state();

// Calls the function below the `nargs` arguments on the top of the stack; an error is logged with
// its traceback and leaves nothing. Leaves `nresults` results when it succeeds.
bool stellar_lua_call(lua_State* L, int nargs, int nresults);
