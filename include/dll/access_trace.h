#pragma once

struct lua_State;

// Adds the access trace's functions to the `stellar` table on the top of the stack:
// trace_begin(addresses), trace_set(id), trace_end(). See src/dll/access_trace.cpp.
void stellar_access_trace_open(lua_State* L);
