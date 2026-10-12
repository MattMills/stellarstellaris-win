#pragma once

struct lua_State;

// Adds the database workers' functions to the `stellar` table on the top of the stack:
// db_workers(n), db_start(id, create, init), db_wait(), token_table(add_dynamic_token, find,
// rebuild_lookup, access, reserve, assign), token_table_stats(). See src/dll/database_workers.cpp.
void stellar_database_workers_open(lua_State* L);
