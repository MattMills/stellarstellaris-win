#pragma once

struct lua_State;

// Adds the modifier index's functions to the `stellar` table on the top of the stack:
// modifier_index(t), modifier_index_stats(). See src/dll/modifier_index.cpp.
void stellar_modifier_index_open(lua_State* L);

// The index's lock (recursive): held around CModifier::TryAddDynamicModifier while the databases
// run in parallel (src/dll/database_workers.cpp), so that no lookup indexes a definition the game
// has added but not filled yet.
void stellar_modifier_index_enter();
void stellar_modifier_index_leave();
