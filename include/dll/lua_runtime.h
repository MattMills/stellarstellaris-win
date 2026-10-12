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
