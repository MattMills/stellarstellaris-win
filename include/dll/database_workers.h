#pragma once

struct lua_State;

// Adds the database workers' functions to the `stellar` table on the top of the stack:
// db_workers(n), db_start(id, create, init), db_wait(), db_lock_tokens(add_dynamic_token, find).
// See src/dll/database_workers.cpp.
void stellar_database_workers_open(lua_State* L);
