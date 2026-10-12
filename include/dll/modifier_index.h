#pragma once

struct lua_State;

// Adds the modifier index's functions to the `stellar` table on the top of the stack:
// modifier_index(t), modifier_index_stats(). See src/dll/modifier_index.cpp.
void stellar_modifier_index_open(lua_State* L);
