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
// made safe. The static lexer's token table is the first (stellar.token_table, below): taken over
// at startup in every mode, its id -> name lookup is never rebuilt again.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/database_workers.h"
#include "dll/code_hook.h"

#include <lua.hpp>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
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

// The token table (stellar.token_table). The static lexer (CStaticLexer::AccessStaticLexer) has the
// tokens' tree (name -> id) and _LookUp, a CPdxArray<CString> from id to name. The game rebuilds
// _LookUp whenever it is out of date (its size is not _nDesiredLookup) from some 16,000 places
// where the check is inlined: CStaticLexer::RebuildLookup empties every name in place, may move the
// array, and fills it again, while other threads may be reading it. Here it never runs:
// - AddDynamicToken (which adds a token and raises _nDesiredLookup) takes the table's lock and,
//   before it returns the new id, adds the new names to _LookUp in place;
// - _LookUp gets room for kLookupRoom names at once, so adding never moves it;
// - RebuildLookup does the same update in place, under the lock, if anything is missing.
// The tree's find (name -> id) takes the lock to read. While a thread holds it to add, its own
// lookups do not take it again.
SRWLOCK token_lock = SRWLOCK_INIT;
thread_local bool adding_token = false;

const int32_t kLookupRoom = 262144;

// CStaticLexer (4.5.2): _DynamicTokens (CPdxArray<CToken*>) data +0x58, size +0x64; _LookUp
// (CPdxArray<CString>) at +0x68: data +0x70, capacity +0x78, size +0x7c; _nDesiredLookup +0x80;
// _nBase +0x84 (dynamic token i has the id _nBase + 1 + i). A CToken has its id at +0 and its name
// (a C string) at +16; a CString is 48 bytes.
struct TokenTable {
	void* (*access)() = nullptr;                                 // CStaticLexer::AccessStaticLexer
	void (*reserve)(void* array, int32_t capacity) = nullptr;    // CPdxArray<CString,int>::Reserve
	void* (*assign)(void* string, const char* text, size_t length) = nullptr;  // the CString's assign
};
TokenTable table;

uint64_t lookup_updates = 0, lookup_names = 0, lookup_moves = 0, rebuild_calls = 0;

template <typename T>
T& field(uint8_t* base, size_t offset) {
	return *reinterpret_cast<T*>(base + offset);
}

// Adds the names _LookUp is missing (under the exclusive lock)
void update_lookup() {
	uint8_t* lexer = static_cast<uint8_t*>(table.access());
	const int32_t desired = field<int32_t>(lexer, 0x80);
	int32_t size = field<int32_t>(lexer, 0x7c);
	if (size >= desired) {
		return;
	}
	++lookup_updates;
	if (field<int32_t>(lexer, 0x78) < desired) {
		// moves the array: the one time a reader could see it move, made rare by the room
		++lookup_moves;
		table.reserve(lexer + 0x68, desired + kLookupRoom);
	}
	uint8_t* data = field<uint8_t*>(lexer, 0x70);
	const int32_t base = field<int32_t>(lexer, 0x84);
	uint8_t* const* dynamic = field<uint8_t* const*>(lexer, 0x58);
	const int32_t dynamic_size = field<int32_t>(lexer, 0x64);
	for (; size < desired; ++size) {
		uint8_t* name = data + static_cast<size_t>(size) * 48;
		// an empty CString, as CPdxArray<CString>::SetSize makes it
		std::memset(name, 0, 48);
		field<uint64_t>(name, 40) = 15;
		const int32_t i = size - base - 1;
		if (i >= 0 && i < dynamic_size && dynamic[i] != nullptr && field<int32_t>(dynamic[i], 0) == size) {
			const char* text = field<const char*>(dynamic[i], 16);
			if (text != nullptr) {
				table.assign(name, text, std::strlen(text));
				++lookup_names;
			}
		}
		// the name first, then the size that makes it visible
		std::atomic_thread_fence(std::memory_order_release);
		field<int32_t>(lexer, 0x7c) = size + 1;
	}
}

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
	update_lookup();
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

// static void CStaticLexer::RebuildLookup(): the update in place
using rebuild_function = void (*)();
rebuild_function original_rebuild = nullptr;

void rebuild_hook() {
	++rebuild_calls;
	if (adding_token) {
		update_lookup();
		return;
	}
	AcquireSRWLockExclusive(&token_lock);
	adding_token = true;
	update_lookup();
	adding_token = false;
	ReleaseSRWLockExclusive(&token_lock);
}

// stellar.token_table(add_dynamic_token, find, rebuild_lookup, access, reserve, assign) -> true |
// nil, message: the token table taken over (see above)
int l_token_table(lua_State* L) {
	void* add = reinterpret_cast<void*>(check_address(L, 1));
	void* find = reinterpret_cast<void*>(check_address(L, 2));
	void* rebuild = reinterpret_cast<void*>(check_address(L, 3));
	table.access = reinterpret_cast<void* (*)()>(check_address(L, 4));
	table.reserve = reinterpret_cast<void (*)(void*, int32_t)>(check_address(L, 5));
	table.assign = reinterpret_cast<void* (*)(void*, const char*, size_t)>(check_address(L, 6));
	if (original_add_token != nullptr || original_find != nullptr || original_rebuild != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "the token table is taken over already");
		return 2;
	}
	// up to date once with the game's own rebuild, then the room, before the hooks
	AcquireSRWLockExclusive(&token_lock);
	uint8_t* lexer = static_cast<uint8_t*>(table.access());
	if (field<int32_t>(lexer, 0x7c) != field<int32_t>(lexer, 0x80)) {
		reinterpret_cast<rebuild_function>(rebuild)();
	}
	if (field<int32_t>(lexer, 0x78) < field<int32_t>(lexer, 0x80) + kLookupRoom) {
		table.reserve(lexer + 0x68, field<int32_t>(lexer, 0x80) + kLookupRoom);
	}
	const char* error = nullptr;
	const bool ok = install_code_hook(find, reinterpret_cast<void*>(&find_hook), reinterpret_cast<void**>(&original_find), &error)
		&& install_code_hook(add, reinterpret_cast<void*>(&add_token_hook), reinterpret_cast<void**>(&original_add_token), &error)
		&& install_code_hook(rebuild, reinterpret_cast<void*>(&rebuild_hook), reinterpret_cast<void**>(&original_rebuild), &error);
	ReleaseSRWLockExclusive(&token_lock);
	if (!ok) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

// stellar.token_table_stats() -> { updates, names, moves, rebuild_calls, size, desired, capacity }
int l_token_table_stats(lua_State* L) {
	lua_createtable(L, 0, 7);
	lua_pushnumber(L, static_cast<lua_Number>(lookup_updates));
	lua_setfield(L, -2, "updates");
	lua_pushnumber(L, static_cast<lua_Number>(lookup_names));
	lua_setfield(L, -2, "names");
	lua_pushnumber(L, static_cast<lua_Number>(lookup_moves));
	lua_setfield(L, -2, "moves");
	lua_pushnumber(L, static_cast<lua_Number>(rebuild_calls));
	lua_setfield(L, -2, "rebuild_calls");
	if (table.access != nullptr) {
		uint8_t* lexer = static_cast<uint8_t*>(table.access());
		lua_pushnumber(L, field<int32_t>(lexer, 0x7c));
		lua_setfield(L, -2, "size");
		lua_pushnumber(L, field<int32_t>(lexer, 0x80));
		lua_setfield(L, -2, "desired");
		lua_pushnumber(L, field<int32_t>(lexer, 0x78));
		lua_setfield(L, -2, "capacity");
	}
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
	lua_pushcfunction(L, l_token_table);
	lua_setfield(L, -2, "token_table");
	lua_pushcfunction(L, l_token_table_stats);
	lua_setfield(L, -2, "token_table_stats");
}
