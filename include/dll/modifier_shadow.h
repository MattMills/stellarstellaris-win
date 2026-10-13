#pragma once

struct lua_State;

// Adds the modifier shadow hooks to the `stellar` table on the top of the stack:
// modifier_shadow_hook(node_update, manager_update), modifier_shadow_stats(). After each pass of
// the game's node manager, the ids of the nodes it recomputed go to stellar.modifier_pass(ids, count).
// See src/dll/modifier_shadow.cpp.
void stellar_modifier_shadow_open(lua_State* L);
