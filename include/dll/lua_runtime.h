#pragma once

#include <cstdint>
#include <mutex>

// Creates the Lua state and runs lua/init.lua from the directory of stellar-injected.dll. Called
// once, by the init thread, after the C++ hooks are installed.
void stellar_lua_start();

// Calls stellar.heartbeat(frame) if a script set it. Called by the init thread every second.
void stellar_lua_heartbeat(uint64_t frame);

// The Lua state is not thread-safe: hold this lock to call into Lua from any thread.
std::recursive_mutex& stellar_lua_lock();
