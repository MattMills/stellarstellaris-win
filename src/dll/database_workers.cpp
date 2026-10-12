// database_workers.cpp : threads that initialize game databases in parallel, for the Lua loop
// (lua/stellar/databases.lua, databases.run_parallel).
//
// stellar.db_workers(n) starts n threads. stellar.db_start(id, create, init) queues a database: a
// worker calls its CreateInstance and then its InitInstance (the trampolines Lua gives: they run
// past the skip hooks). stellar.db_wait() blocks until at least one database is done and returns
// them: { id, start, finish, thread }. The Lua loop decides what runs when (its dependencies) and
// reports the progress on the game's thread.
//
// The game's databases were written to be initialized one at a time, so what they share has to be
// made safe. The static lexer's token table is the first: CStaticLexer::AddDynamicToken (which
// writes it) and the token tree's find (which reads it) are hooked to take a reader/writer lock
// (stellar.db_lock_tokens(add_dynamic_token, find)).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/database_workers.h"
#include "dll/code_hook.h"

#include <lua.hpp>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace {

double now() {
	FILETIME ft;
	GetSystemTimePreciseAsFileTime(&ft);
	const uint64_t t = (static_cast<uint64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
	return static_cast<double>(t - 116444736000000000ULL) / 1e7;
}

struct Job {
	double id;
	uintptr_t create, init;
	double start, finish;
	uint32_t thread;
};

std::mutex jobs_lock;
std::condition_variable jobs_queued, jobs_done;
std::deque<Job> queue;
std::vector<Job> finished;
std::vector<std::thread> workers;

using call_function = uintptr_t (*)();

void worker() {
	for (;;) {
		Job job;
		{
			std::unique_lock<std::mutex> guard(jobs_lock);
			jobs_queued.wait(guard, [] { return !queue.empty(); });
			job = queue.front();
			queue.pop_front();
		}
		job.thread = GetCurrentThreadId();
		job.start = now();
		reinterpret_cast<call_function>(job.create)();
		reinterpret_cast<call_function>(job.init)();
		job.finish = now();
		{
			std::lock_guard<std::mutex> guard(jobs_lock);
			finished.push_back(job);
		}
		jobs_done.notify_all();
	}
}

uintptr_t check_address(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0 || value != static_cast<lua_Number>(static_cast<uint64_t>(value))) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

// stellar.db_workers(n) -> the number of workers (started once; later calls add none)
int l_db_workers(lua_State* L) {
	const int n = static_cast<int>(luaL_checknumber(L, 1));
	if (workers.empty()) {
		for (int i = 0; i < n && i < 64; ++i) {
			workers.emplace_back(worker);
			workers.back().detach();
		}
	}
	lua_pushnumber(L, static_cast<lua_Number>(workers.size()));
	return 1;
}

// stellar.db_start(id, create, init): a worker will call create(), then init()
int l_db_start(lua_State* L) {
	Job job{luaL_checknumber(L, 1), check_address(L, 2), check_address(L, 3), 0, 0, 0};
	{
		std::lock_guard<std::mutex> guard(jobs_lock);
		queue.push_back(job);
	}
	jobs_queued.notify_one();
	return 0;
}

// stellar.db_wait() -> the databases done since the last call (waits for one): { id, start,
// finish, thread }
int l_db_wait(lua_State* L) {
	std::vector<Job> done;
	{
		std::unique_lock<std::mutex> guard(jobs_lock);
		jobs_done.wait(guard, [] { return !finished.empty(); });
		done.swap(finished);
	}
	lua_createtable(L, static_cast<int>(done.size()), 0);
	for (size_t i = 0; i < done.size(); ++i) {
		lua_createtable(L, 0, 4);
		lua_pushnumber(L, done[i].id);
		lua_setfield(L, -2, "id");
		lua_pushnumber(L, done[i].start);
		lua_setfield(L, -2, "start");
		lua_pushnumber(L, done[i].finish);
		lua_setfield(L, -2, "finish");
		lua_pushnumber(L, done[i].thread);
		lua_setfield(L, -2, "thread");
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

// The token table's lock. AddDynamicToken looks names up itself: while a thread holds the lock to
// add, its lookups do not take it again.
SRWLOCK token_lock = SRWLOCK_INIT;
thread_local bool adding_token = false;

// static int CStaticLexer::AddDynamicToken(const CString& name, bool)
using add_token_function = int (*)(const void* name, bool flag);
add_token_function original_add_token = nullptr;

int add_token_hook(const void* name, bool flag) {
	if (adding_token) {
		return original_add_token(name, flag);
	}
	AcquireSRWLockExclusive(&token_lock);
	adding_token = true;
	const int id = original_add_token(name, flag);
	adding_token = false;
	ReleaseSRWLockExclusive(&token_lock);
	return id;
}

// the token tree's find(tree, name) (its vtable's slot 2)
using find_function = const void* (*)(void* tree, const char* name);
find_function original_find = nullptr;

const void* find_hook(void* tree, const char* name) {
	if (adding_token) {
		return original_find(tree, name);
	}
	AcquireSRWLockShared(&token_lock);
	const void* entry = original_find(tree, name);
	ReleaseSRWLockShared(&token_lock);
	return entry;
}

// stellar.db_lock_tokens(add_dynamic_token, find) -> true | nil, message
int l_db_lock_tokens(lua_State* L) {
	void* add = reinterpret_cast<void*>(check_address(L, 1));
	void* find = reinterpret_cast<void*>(check_address(L, 2));
	if (original_add_token != nullptr || original_find != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "the token table is locked already");
		return 2;
	}
	const char* error = nullptr;
	if (!install_code_hook(find, reinterpret_cast<void*>(&find_hook), reinterpret_cast<void**>(&original_find), &error)
		|| !install_code_hook(add, reinterpret_cast<void*>(&add_token_hook), reinterpret_cast<void**>(&original_add_token), &error)) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

} // namespace

void stellar_database_workers_open(lua_State* L) {
	lua_pushcfunction(L, l_db_workers);
	lua_setfield(L, -2, "db_workers");
	lua_pushcfunction(L, l_db_start);
	lua_setfield(L, -2, "db_start");
	lua_pushcfunction(L, l_db_wait);
	lua_setfield(L, -2, "db_wait");
	lua_pushcfunction(L, l_db_lock_tokens);
	lua_setfield(L, -2, "db_lock_tokens");
}
