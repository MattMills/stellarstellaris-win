#pragma once

struct lua_State;

// Adds the profiler's functions to the `stellar` table on the top of the stack: profile_hook,
// profile_serve, profile_requests, profile_note. See src/dll/profiler.cpp.
void stellar_profiler_open(lua_State* L);
