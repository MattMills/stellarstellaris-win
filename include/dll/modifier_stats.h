#pragma once

struct lua_State;

// Adds the modifier node statistics to the `stellar` table on the top of the stack:
// modifier_stats_hook(node_update, mark, manager_update), modifier_stats([reset]).
// See src/dll/modifier_stats.cpp.
void stellar_modifier_stats_open(lua_State* L);
