#pragma once

struct lua_State;

// Adds the load screen hook's functions to the `stellar` table on the top of the stack:
// hook_loading(push, pop, render), loading_events(). See src/dll/loading_hook.cpp.
void stellar_loading_open(lua_State* L);
