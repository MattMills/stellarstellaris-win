#pragma once

#include <cstddef>
#include <cstdint>

struct lua_State;

// Adds the database workers' functions to the `stellar` table on the top of the stack:
// db_workers(n), db_start(id, create, init), db_wait(), token_table(add_dynamic_token, find,
// rebuild_lookup, access, reserve, assign), token_table_stats(). See src/dll/database_workers.cpp.
void stellar_database_workers_open(lua_State* L);

// Waits for the background call `id` (stellar.run_async); its return value in *result, how long
// the wait was in *seconds (if not null). False if there is no such call or it failed.
bool stellar_async_join(size_t id, uintptr_t* result, double* seconds);

// The shared lock of the serialized functions taken (on) or not (stellar.serialize_active).
void stellar_serialize_set(bool on);
