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
// at startup in every mode, its id -> name lookup is never rebuilt again. The functions that write
// the other shared tables run under one lock (stellar.serialize, below).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/database_workers.h"
#include "dll/code_hook.h"
#include "dll/modifier_index.h"

#include <lua.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace {

double now() {
	FILETIME ft;
	GetSystemTimePreciseAsFileTime(&ft);
	const uint64_t t = (static_cast<uint64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
	return static_cast<double>(t - 116444736000000000ULL) / 1e7;
}

// What stopped a database: where, the stack there (return addresses, innermost first), and for a
// C++ exception the name of the type thrown (decorated: ".?AVbad_alloc@std@@")
const int kStackDepth = 24;
struct Failure {
	uintptr_t address = 0;
	uintptr_t stack[kStackDepth] = {};
	int depth = 0;
	char type[96] = {};
};

struct Job {
	double id;
	uintptr_t create, init;
	double start, finish;
	uint32_t thread;
	uint32_t exception;   // the code of the exception that stopped it, or 0
	Failure failure;
};

std::mutex jobs_lock;
std::condition_variable jobs_queued, jobs_done;
std::deque<Job> queue;
std::vector<Job> finished;
std::vector<std::thread> workers;

using call_function = uintptr_t (*)();

// the database (its id, from Lua) this thread is initializing, or 0
thread_local int current_database = 0;

// The stack at the exception, unwound from its context (the frames are still there while the
// filter runs). A stack too broken to unwind ends the walk, not the filter.
void walk_stack(const CONTEXT* at, Failure* f) {
	CONTEXT c = *at;
	__try {
		while (f->depth < kStackDepth && c.Rip != 0) {
			f->stack[f->depth++] = static_cast<uintptr_t>(c.Rip);
			DWORD64 image = 0;
			PRUNTIME_FUNCTION function = RtlLookupFunctionEntry(c.Rip, &image, nullptr);
			if (function == nullptr) {
				// a leaf function: its return address is at rsp
				c.Rip = *reinterpret_cast<const DWORD64*>(c.Rsp);
				c.Rsp += 8;
			} else {
				void* handler_data = nullptr;
				DWORD64 frame = 0;
				RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, c.Rip, function, &c, &handler_data, &frame, nullptr);
			}
		}
	} __except (EXCEPTION_EXECUTE_HANDLER) {
	}
}

// For an MSVC C++ exception (0xE06D7363), the name of the type thrown: ExceptionInformation[2] is
// its ThrowInfo, [3] the module the RVAs in it are relative to; ThrowInfo +12 the
// CatchableTypeArray, its first CatchableType, +4 its TypeDescriptor, the name at +16
void thrown_type(const EXCEPTION_RECORD* r, Failure* f) {
	if (r->ExceptionCode != 0xE06D7363 || r->NumberParameters < 4) {
		return;
	}
	__try {
		const uintptr_t base = static_cast<uintptr_t>(r->ExceptionInformation[3]);
		const int32_t* info = reinterpret_cast<const int32_t*>(r->ExceptionInformation[2]);
		const int32_t* types = reinterpret_cast<const int32_t*>(base + info[3]);
		const int32_t* type = reinterpret_cast<const int32_t*>(base + types[1]);
		const char* name = reinterpret_cast<const char*>(base + type[1] + 16);
		strncpy_s(f->type, name, _TRUNCATE);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		f->type[0] = 0;
	}
}

int exception_filter(EXCEPTION_POINTERS* info, Failure* f) {
	f->address = reinterpret_cast<uintptr_t>(info->ExceptionRecord->ExceptionAddress);
	walk_stack(info->ContextRecord, f);
	thrown_type(info->ExceptionRecord, f);
	return EXCEPTION_EXECUTE_HANDLER;
}

// Calls create (if any) and init under a structured exception handler: 0, or the code of the
// exception that stopped them (what it was in *f). The game's frames below are abandoned: the
// database is left half made, and the load cannot go on safely after that.
DWORD call_guarded(uintptr_t create, uintptr_t init, Failure* f) {
	__try {
		if (create != 0) {
			reinterpret_cast<call_function>(create)();
		}
		reinterpret_cast<call_function>(init)();
	} __except (exception_filter(GetExceptionInformation(), f)) {
		return GetExceptionCode();
	}
	return 0;
}

// pushes the failure's fields into the table on the top of the stack
void push_failure(lua_State* L, const Failure& f) {
	lua_pushnumber(L, static_cast<lua_Number>(f.address));
	lua_setfield(L, -2, "address");
	lua_createtable(L, f.depth, 0);
	for (int i = 0; i < f.depth; ++i) {
		lua_pushnumber(L, static_cast<lua_Number>(f.stack[i]));
		lua_rawseti(L, -2, i + 1);
	}
	lua_setfield(L, -2, "stack");
	lua_pushstring(L, f.type);
	lua_setfield(L, -2, "type");
}

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
		current_database = static_cast<int>(job.id);
		job.exception = call_guarded(job.create, job.init, &job.failure);
		current_database = 0;
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
	Job job{luaL_checknumber(L, 1), check_address(L, 2), check_address(L, 3), 0, 0, 0, 0, Failure{}};
	{
		std::lock_guard<std::mutex> guard(jobs_lock);
		queue.push_back(job);
	}
	jobs_queued.notify_one();
	return 0;
}

// stellar.db_wait([seconds]) -> the databases done since the last call (waits for one, or at most
// that long): { id, start, finish, thread, exception, address, stack, type }
int l_db_wait(lua_State* L) {
	const double seconds = luaL_optnumber(L, 1, -1);
	std::vector<Job> done;
	{
		std::unique_lock<std::mutex> guard(jobs_lock);
		if (seconds < 0) {
			jobs_done.wait(guard, [] { return !finished.empty(); });
		} else {
			jobs_done.wait_for(guard, std::chrono::milliseconds(static_cast<int64_t>(seconds * 1000)),
				[] { return !finished.empty(); });
		}
		done.swap(finished);
	}
	lua_createtable(L, static_cast<int>(done.size()), 0);
	for (size_t i = 0; i < done.size(); ++i) {
		lua_createtable(L, 0, 8);
		lua_pushnumber(L, done[i].exception);
		lua_setfield(L, -2, "exception");
		if (done[i].exception != 0) {
			push_failure(L, done[i].failure);
		}
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

// stellar.db_call(create, init[, id]) -> exception, { address, stack, type } | nil: create() then
// init() on this thread under the same handler as the workers' (0 when they returned)
int l_db_call(lua_State* L) {
	const uintptr_t create = static_cast<uintptr_t>(luaL_optnumber(L, 1, 0));
	const uintptr_t init = check_address(L, 2);
	Failure f;
	current_database = static_cast<int>(luaL_optnumber(L, 3, 0));
	const DWORD code = call_guarded(create, init, &f);
	current_database = 0;
	lua_pushnumber(L, code);
	if (code == 0) {
		return 1;
	}
	lua_createtable(L, 0, 3);
	push_failure(L, f);
	return 2;
}

// Background calls (stellar.run_async, stellar.join_async): a step of the load the game would run
// on its own thread, run on a thread of its own meanwhile (a function without arguments, under the
// same handler as the databases), and waited for where its result is needed.
struct AsyncCall {
	HANDLE thread = nullptr;
	uintptr_t function = 0;
	DWORD code = 0;
	Failure failure;
	double start = 0, finish = 0;
};
std::vector<AsyncCall*> async_calls;

DWORD WINAPI async_main(void* p) {
	AsyncCall* call = static_cast<AsyncCall*>(p);
	call->start = now();
	call->code = call_guarded(0, call->function, &call->failure);
	call->finish = now();
	return 0;
}

// stellar.run_async(function) -> id: a thread calls function()
int l_run_async(lua_State* L) {
	AsyncCall* call = new AsyncCall();
	call->function = check_address(L, 1);
	call->thread = CreateThread(nullptr, 0, async_main, call, 0, nullptr);
	if (call->thread == nullptr) {
		delete call;
		lua_pushnil(L);
		lua_pushliteral(L, "CreateThread failed");
		return 2;
	}
	async_calls.push_back(call);
	lua_pushnumber(L, static_cast<lua_Number>(async_calls.size()));
	return 1;
}

// stellar.join_async(id[, seconds]) -> exception, { start, finish, address, stack, type } | nil,
// "running": waits for the call (at most that long)
int l_join_async(lua_State* L) {
	const size_t id = static_cast<size_t>(luaL_checknumber(L, 1));
	if (id < 1 || id > async_calls.size()) {
		return luaL_argerror(L, 1, "no such call");
	}
	AsyncCall* call = async_calls[id - 1];
	const double seconds = luaL_optnumber(L, 2, -1);
	const DWORD wait = seconds < 0 ? INFINITE : static_cast<DWORD>(seconds * 1000);
	if (WaitForSingleObject(call->thread, wait) != WAIT_OBJECT_0) {
		lua_pushnil(L);
		lua_pushliteral(L, "running");
		return 2;
	}
	lua_pushnumber(L, call->code);
	lua_createtable(L, 0, 5);
	lua_pushnumber(L, call->start);
	lua_setfield(L, -2, "start");
	lua_pushnumber(L, call->finish);
	lua_setfield(L, -2, "finish");
	if (call->code != 0) {
		push_failure(L, call->failure);
	}
	return 2;
}

// stellar.exit_process(code): ends the game now (after a database failed: the load cannot go on)
int l_exit_process(lua_State* L) {
	TerminateProcess(GetCurrentProcess(), static_cast<UINT>(luaL_optnumber(L, 1, 1)));
	return 0;
}

// Serialized functions (stellar.serialize). Some game functions the databases call write tables
// every database shares: the deferred database object resolver's list, the trigger database's set
// of triggers, the event namespaces, the modifier definitions. A serialized function runs under
// one lock, recursive, that all of them share (one lock: no order between locks to get wrong),
// while the databases run in parallel (stellar.serialize_active).
// The lock is left by a __finally, so an exception that ends a database (call_guarded) leaves it
// too. Each records which databases called it (current_database): who writes what.
//
// The hook forwards 16 integer arguments (the 4 registers and 12 stack slots: more than the callee
// reads is harmless, they are the caller's frame; CModifier::TryAddDynamicModifier takes 12, and
// forwarding 8 lost its category); floating point arguments are not forwarded, so it is only for
// functions that take none.
CRITICAL_SECTION serial_lock;
bool serial_lock_ready = false;
std::atomic<bool> serial_active{false};

#define SERIAL_ARGS a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p
#define SERIAL_PARAMS uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d, uintptr_t e, uintptr_t f, uintptr_t g, \
	uintptr_t h, uintptr_t i, uintptr_t j, uintptr_t k, uintptr_t l, uintptr_t m, uintptr_t n, uintptr_t o, uintptr_t p
using serialized_function = uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t,
	uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);

struct Serialized {
	serialized_function original = nullptr;
	bool with_index = false;        // also holds the modifier index's lock (TryAddDynamicModifier)
	uint64_t calls = 0;
	uint64_t contended = 0;         // calls that found the lock taken
	double waited = 0;              // and the seconds they waited for it
	std::vector<uint8_t> callers;   // by database id; under serial_lock
};
const int kSerializedSlots = 32;
Serialized serialized[kSerializedSlots];
int serialized_count = 0;

__declspec(noinline) void record_serialized_call(int slot) {
	Serialized& s = serialized[slot];
	++s.calls;
	const int id = current_database;
	if (id > 0) {
		if (s.callers.size() <= static_cast<size_t>(id)) {
			s.callers.resize(static_cast<size_t>(id) + 1);
		}
		s.callers[id] = 1;
	}
}

// the original, with the modifier index's lock too if the slot wants it
uintptr_t call_serialized(int slot, SERIAL_PARAMS) {
	if (!serialized[slot].with_index) {
		return serialized[slot].original(SERIAL_ARGS);
	}
	uintptr_t result = 0;
	stellar_modifier_index_enter();
	__try {
		result = serialized[slot].original(SERIAL_ARGS);
	} __finally {
		stellar_modifier_index_leave();
	}
	return result;
}

template <int N>
uintptr_t serialized_hook(SERIAL_PARAMS) {
	// only while the databases run in parallel (stellar.serialize_active), on every thread (a
	// database's Init hands work to the game's task threads too): after, some of the game's
	// threads call these holding the game's own locks, and taking this one too spun the load
	// forever
	if (!serial_active.load(std::memory_order_acquire)) {
		return serialized[N].original(SERIAL_ARGS);
	}
	double waited = -1;
	if (!TryEnterCriticalSection(&serial_lock)) {
		const double start = now();
		EnterCriticalSection(&serial_lock);
		waited = now() - start;
	}
	uintptr_t result = 0;
	__try {
		record_serialized_call(N);
		if (waited >= 0) {
			++serialized[N].contended;
			serialized[N].waited += waited;
		}
		result = call_serialized(N, SERIAL_ARGS);
	} __finally {
		LeaveCriticalSection(&serial_lock);
	}
	return result;
}

template <int... N>
constexpr std::array<serialized_function, sizeof...(N)> make_serialized_hooks(std::integer_sequence<int, N...>) {
	return {&serialized_hook<N>...};
}
const auto serialized_hooks = make_serialized_hooks(std::make_integer_sequence<int, kSerializedSlots>{});

// stellar.serialize(address[, with_index]) -> slot | nil, message: the function runs under the
// shared lock from now on (see above), and under the modifier index's lock too with with_index
int l_serialize(lua_State* L) {
	void* target = reinterpret_cast<void*>(check_address(L, 1));
	const bool with_index = lua_toboolean(L, 2) != 0;
	if (!serial_lock_ready) {
		InitializeCriticalSection(&serial_lock);
		serial_lock_ready = true;
	}
	if (serialized_count >= kSerializedSlots) {
		lua_pushnil(L);
		lua_pushliteral(L, "no serialized slot left");
		return 2;
	}
	const int slot = serialized_count;
	const char* error = nullptr;
	if (!install_code_hook(target, reinterpret_cast<void*>(serialized_hooks[slot]),
			reinterpret_cast<void**>(&serialized[slot].original), &error)) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	serialized[slot].with_index = with_index;
	++serialized_count;
	lua_pushnumber(L, slot);
	return 1;
}

// stellar.serialize_active(on): the serialized functions take the lock (while the databases run in
// parallel) or not
int l_serialize_active(lua_State* L) {
	serial_active.store(lua_toboolean(L, 1) != 0, std::memory_order_release);
	return 0;
}

// stellar.serialized(slot) -> calls (under the lock), { database ids that called it }, contended
// (calls that found it taken), waited (their seconds)
int l_serialized(lua_State* L) {
	const int slot = static_cast<int>(luaL_checknumber(L, 1));
	if (slot < 0 || slot >= serialized_count) {
		return luaL_argerror(L, 1, "no such serialized slot");
	}
	std::vector<int> ids;
	uint64_t calls = 0, contended = 0;
	double waited = 0;
	EnterCriticalSection(&serial_lock);
	calls = serialized[slot].calls;
	contended = serialized[slot].contended;
	waited = serialized[slot].waited;
	for (size_t i = 0; i < serialized[slot].callers.size(); ++i) {
		if (serialized[slot].callers[i]) {
			ids.push_back(static_cast<int>(i));
		}
	}
	LeaveCriticalSection(&serial_lock);
	lua_pushnumber(L, static_cast<lua_Number>(calls));
	lua_createtable(L, static_cast<int>(ids.size()), 0);
	for (size_t i = 0; i < ids.size(); ++i) {
		lua_pushnumber(L, ids[i]);
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	lua_pushnumber(L, static_cast<lua_Number>(contended));
	lua_pushnumber(L, waited);
	return 4;
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
	lua_pushcfunction(L, l_db_call);
	lua_setfield(L, -2, "db_call");
	lua_pushcfunction(L, l_exit_process);
	lua_setfield(L, -2, "exit_process");
	lua_pushcfunction(L, l_run_async);
	lua_setfield(L, -2, "run_async");
	lua_pushcfunction(L, l_join_async);
	lua_setfield(L, -2, "join_async");
	lua_pushcfunction(L, l_serialize);
	lua_setfield(L, -2, "serialize");
	lua_pushcfunction(L, l_serialized);
	lua_setfield(L, -2, "serialized");
	lua_pushcfunction(L, l_serialize_active);
	lua_setfield(L, -2, "serialize_active");
	lua_pushcfunction(L, l_token_table);
	lua_setfield(L, -2, "token_table");
	lua_pushcfunction(L, l_token_table_stats);
	lua_setfield(L, -2, "token_table_stats");
}
