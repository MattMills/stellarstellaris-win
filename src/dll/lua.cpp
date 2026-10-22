// lua.cpp : the Lua runtime of stellar-injected.
//
// The main LuaJIT state, created by the init thread, runs lua/init.lua (next to
// stellar-injected.dll); the init thread (heartbeat) and the game's main thread (turn tick, the
// databases) use it under stellar_lua_lock(). A thread that needs Lua for itself (the lexer hook,
// on every thread that reads script) gets a worker state of its own, which runs lua/worker.lua:
// Lua states are not shared between threads, and states share nothing with each other; what
// passes between them goes through C++.
//
// Every state gets the standard libraries (with the LuaJIT FFI), `fnmatch` (lua_fnmatch: finding
// functions by stellar-fnmatch signatures in any build, decoding instructions), `sigmatch`
// (lua_sigmatch: byte patterns, many in one pass), and `stellar`, this DLL: logging, the game
// module, thread suspension, memory patching, calls into the game and the hooks.
//
// Lua errors are raised only while no C++ object that owns resources is alive in the calling
// frame; scratch memory is Lua userdata.

#include "dll/lua_runtime.h"
#include "dll/dllmain.h"
#include "dll/code_hook.h"
#include "dll/lexer_hook.h"
#include "dll/loading_hook.h"
#include "dll/database_workers.h"
#include "dll/access_trace.h"
#include "dll/modifier_index.h"
#include "dll/modifier_stats.h"
#include "dll/modifier_shadow.h"
#include "dll/profiler.h"
#include "util/logging.h"
#include "git_version.h"

#include <lua.hpp>
#include <lua_fnmatch.h>
#include <lua_sigmatch.h>

#include <atomic>
#include <cstring>

namespace {

lua_State* L = nullptr;

// UTF-8 paths, set by stellar_lua_start()
char dll_path[MAX_PATH * 4] = "";
char lua_dir[MAX_PATH * 4] = "";

// the log file is written by every state's thread
std::mutex& log_lock() {
	static std::mutex lock;
	return lock;
}

void write_log(const char* text) {
	std::lock_guard<std::mutex> guard(log_lock());
	CLog& logger = *getLogger();
	logger << "[lua] " << text;
	logger.endl();
}

bool to_utf8(const wchar_t* wide, char* out, int size) {
	return WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, size, nullptr, nullptr) > 0;
}

// Addresses are numbers (exact up to 2^53 with LuaJIT, enough for user space).
void push_address(lua_State* L, const void* address) {
	lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(address)));
}

uintptr_t check_address(lua_State* L, int idx) {
	if (lua_islightuserdata(L, idx)) {
		return reinterpret_cast<uintptr_t>(lua_touserdata(L, idx));
	}
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value >= 0) || value >= 18446744073709551616.0 || value != static_cast<lua_Number>(static_cast<uint64_t>(value))) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

size_t check_size(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value >= 0) || value > (1 << 30) || value != static_cast<lua_Number>(static_cast<size_t>(value))) {
		luaL_argerror(L, idx, "size out of range");
	}
	return static_cast<size_t>(value);
}

// stellar.log(...): writes its arguments, like print, to stellarstellaris-debug.log
int l_log(lua_State* L) {
	const int n = lua_gettop(L);
	lua_getglobal(L, "tostring");
	for (int i = 1; i <= n; ++i) {
		if (i > 1) {
			lua_pushliteral(L, "\t");
		}
		lua_pushvalue(L, n + 1);
		lua_pushvalue(L, i);
		lua_call(L, 1, 1);
		if (!lua_isstring(L, -1)) {
			return luaL_error(L, "'tostring' must return a string to 'log'");
		}
	}
	lua_concat(L, lua_gettop(L) - (n + 1));
	write_log(lua_tostring(L, -1));
	return 0;
}

// stellar.suspend_threads() / stellar.resume_threads(): every other thread of the game
int l_suspend_threads(lua_State* L) {
	(void)L;
	SetOtherThreadsSuspended(true);
	return 0;
}

int l_resume_threads(lua_State* L) {
	(void)L;
	SetOtherThreadsSuspended(false);
	return 0;
}

// stellar.read(address, size) -> string | nil, message (checked: unmapped memory is an error, not
// a crash)
int l_read(lua_State* L) {
	const uintptr_t address = check_address(L, 1);
	const size_t size = check_size(L, 2);
	char* buffer = static_cast<char*>(lua_newuserdata(L, size > 0 ? size : 1));
	SIZE_T read = 0;
	if (size > 0 && (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address), buffer, size, &read) || read != size)) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot read %d bytes at %p", static_cast<int>(size), reinterpret_cast<void*>(address));
		return 2;
	}
	lua_pushlstring(L, buffer, size);
	return 1;
}

// stellar.patch(address, bytes) -> the bytes it replaced | nil, message: writes code or read-only
// data, then restores the page protection and flushes the instruction cache
int l_patch(lua_State* L) {
	const uintptr_t address = check_address(L, 1);
	size_t size = 0;
	const char* bytes = luaL_checklstring(L, 2, &size);
	char* old = static_cast<char*>(lua_newuserdata(L, size > 0 ? size : 1));
	void* target = reinterpret_cast<void*>(address);
	SIZE_T read = 0;
	if (size > 0 && (!ReadProcessMemory(GetCurrentProcess(), target, old, size, &read) || read != size)) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot read %d bytes at %p", static_cast<int>(size), target);
		return 2;
	}
	DWORD protect = 0;
	if (size > 0 && !VirtualProtect(target, size, PAGE_EXECUTE_READWRITE, &protect)) {
		lua_pushnil(L);
		lua_pushfstring(L, "VirtualProtect(%p) failed: error %d", target, static_cast<int>(GetLastError()));
		return 2;
	}
	if (size > 0) {
		std::memcpy(target, bytes, size);
		DWORD ignored = 0;
		VirtualProtect(target, size, protect, &ignored);
		FlushInstructionCache(GetCurrentProcess(), target, size);
	}
	lua_pushlstring(L, old, size);
	return 1;
}

// stellar.thread_id() -> the id of the calling thread
int l_thread_id(lua_State* L) {
	lua_pushnumber(L, static_cast<lua_Number>(GetCurrentThreadId()));
	return 1;
}

// turn tick calls skipped because another thread was running Lua (see call_turn_tick)
std::atomic<uint64_t> skipped_ticks{0};

// stellar.skipped_ticks() -> how many turn tick calls (before or after a tick) Lua missed because
// another thread was running Lua
int l_skipped_ticks(lua_State* L) {
	lua_pushnumber(L, static_cast<lua_Number>(skipped_ticks.load()));
	return 1;
}

// The turn tick (docs/main_loop.md, lua/stellar/game.lua). CGameState::HandleTurnTick runs one tick
// (10 per game day) on the main thread. Once stellar.hook_turn_tick has hooked it, it calls
// stellar.turn_tick("before" | "after", game_state, gate_was_open) around the tick, with
// g_AllowGlobalGameStateAccess open, as the game's own helpers open it around code that uses the
// game state. The main thread never waits for Lua: while another thread runs Lua (the heartbeat, a
// long dev\run.lua), the tick goes on without the call, and stellar.skipped_ticks() counts it.

// void CGameState::HandleTurnTick(CGameState *this, const CPdxArray<uint64_t, int> &checksums)
using handle_turn_tick_function = void (*)(void* game_state, const void* checksums);
handle_turn_tick_function handle_turn_tick = nullptr;
volatile bool* game_state_gate = nullptr;

bool call_protected(lua_State* L, int nargs, int nresults = 0);

void call_turn_tick(const char* phase, void* game_state) {
	std::unique_lock<std::recursive_mutex> guard(stellar_lua_lock(), std::try_to_lock);
	if (!guard.owns_lock()) {
		++skipped_ticks;
		return;
	}
	if (L == nullptr) {
		return;
	}
	const int top = lua_gettop(L);
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_getfield(L, -1, "stellar");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "turn_tick");
		if (lua_isfunction(L, -1)) {
			const bool gate = *game_state_gate;
			*game_state_gate = true;
			lua_pushstring(L, phase);
			push_address(L, game_state);
			lua_pushboolean(L, gate);
			if (!call_protected(L, 3)) {
				// a failing handler is reported once
				lua_pushnil(L);
				lua_setfield(L, -2, "turn_tick");
			}
			*game_state_gate = gate;
		}
	}
	lua_settop(L, top);
}

void turn_tick_hook(void* game_state, const void* checksums) {
	call_turn_tick("before", game_state);
	handle_turn_tick(game_state, checksums);
	call_turn_tick("after", game_state);
}

// stellar.hook_turn_tick(handle_turn_tick, gate) -> true | nil, message: hooks
// CGameState::HandleTurnTick at `handle_turn_tick`; `gate` is g_AllowGlobalGameStateAccess.
int l_hook_turn_tick(lua_State* L) {
	void* target = reinterpret_cast<void*>(check_address(L, 1));
	volatile bool* gate = reinterpret_cast<volatile bool*>(check_address(L, 2));
	if (handle_turn_tick != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "the turn tick is hooked already");
		return 2;
	}
	char value = 0;
	SIZE_T read = 0;
	if (!ReadProcessMemory(GetCurrentProcess(), const_cast<bool*>(gate), &value, 1, &read) || read != 1) {
		lua_pushnil(L);
		lua_pushfstring(L, "cannot read the gate at %p", const_cast<bool*>(gate));
		return 2;
	}
	game_state_gate = gate;
	// handle_turn_tick is set before the jmp is written: the game can call the hook right away
	const char* error = nullptr;
	if (!install_code_hook(target, reinterpret_cast<void*>(&turn_tick_hook), reinterpret_cast<void**>(&handle_turn_tick), &error)) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

// an integer or pointer argument: a number, a boolean, or nil (0)
uintptr_t check_argument(lua_State* L, int idx) {
	if (lua_isnoneornil(L, idx)) {
		return 0;
	}
	if (lua_isboolean(L, idx)) {
		return lua_toboolean(L, idx) ? 1 : 0;
	}
	return check_address(L, idx);
}

// stellar.call(address [, a1, a2, a3, a4]) -> rax: calls a function of the game with up to 4
// integer or pointer arguments, and returns what it returns in rax (a number; for a bool, the low
// byte: stellar.call(f) % 256 ~= 0). A C function of the classic API, so the game's code may call
// back into this Lua state through the hooks.
int l_call(lua_State* L) {
	using function = uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t);
	const function f = reinterpret_cast<function>(check_address(L, 1));
	const uintptr_t a1 = check_argument(L, 2), a2 = check_argument(L, 3), a3 = check_argument(L, 4),
		a4 = check_argument(L, 5);
	const uintptr_t result = f(a1, a2, a3, a4);
	lua_pushnumber(L, static_cast<lua_Number>(result));
	return 1;
}

// stellar.call_progress(function, current, total): calls a std::function<void(unsigned, unsigned)>
// of the game at `function` (MSVC: the callable at +56; its vtable's slot 2 calls it, with the
// arguments by reference)
int l_call_progress(lua_State* L) {
	uint8_t* function = reinterpret_cast<uint8_t*>(check_address(L, 1));
	unsigned current = static_cast<unsigned>(luaL_checknumber(L, 2));
	unsigned total = static_cast<unsigned>(luaL_checknumber(L, 3));
	void* callable = *reinterpret_cast<void* const*>(function + 56);
	if (callable != nullptr) {
		using call_function = void (*)(void* callable, unsigned* current, unsigned* total);
		const call_function call = (*reinterpret_cast<const call_function* const*>(callable))[2];
		call(callable, &current, &total);
	}
	return 0;
}

int luaopen_stellar(lua_State* L) {
	const luaL_Reg functions[] = {
		{"log", l_log},
		{"suspend_threads", l_suspend_threads},
		{"resume_threads", l_resume_threads},
		{"read", l_read},
		{"patch", l_patch},
		{"thread_id", l_thread_id},
		{"skipped_ticks", l_skipped_ticks},
		{"hook_turn_tick", l_hook_turn_tick},
		{"call", l_call},
		{"call_progress", l_call_progress},
		{nullptr, nullptr},
	};
	lua_newtable(L);
	for (const luaL_Reg* f = functions; f->name != nullptr; ++f) {
		lua_pushcfunction(L, f->func);
		lua_setfield(L, -2, f->name);
	}
	// hook_lexer, lexer_stats, lexer_mismatches (src/dll/lexer_hook.cpp)
	stellar_lexer_open(L);
	// hook_loading, loading_events (src/dll/loading_hook.cpp)
	stellar_loading_open(L);
	// db_workers, db_start, db_wait, db_lock_tokens (src/dll/database_workers.cpp)
	stellar_database_workers_open(L);
	// trace_begin, trace_set, trace_end (src/dll/access_trace.cpp)
	stellar_access_trace_open(L);
	// modifier_index, modifier_index_stats (src/dll/modifier_index.cpp)
	stellar_modifier_index_open(L);
	// modifier_stats_hook, modifier_stats (src/dll/modifier_stats.cpp)
	stellar_modifier_stats_open(L);
	// modifier_shadow_hook, modifier_shadow_stats (src/dll/modifier_shadow.cpp)
	stellar_modifier_shadow_open(L);
	// profile_hook, profile_serve, profile_requests, profile_note (src/dll/profiler.cpp)
	stellar_profiler_open(L);

	// the game
	push_address(L, hModule);
	lua_setfield(L, -2, "module_base");
	wchar_t wide[MAX_PATH * 2];
	char path[MAX_PATH * 4];
	if (GetModuleFileNameW(nullptr, wide, MAX_PATH * 2) > 0 && to_utf8(wide, path, sizeof(path))) {
		lua_pushstring(L, path);
		lua_setfield(L, -2, "module_path");
	}
	lua_pushnumber(L, static_cast<lua_Number>(GetCurrentProcessId()));
	lua_setfield(L, -2, "process_id");

	// this DLL
	lua_pushstring(L, dll_path);
	lua_setfield(L, -2, "dll_path");
	lua_pushstring(L, lua_dir);
	lua_setfield(L, -2, "lua_dir");
	lua_pushstring(L, kGitHash);
	lua_setfield(L, -2, "git_hash");
	return 1;
}

void preload(lua_State* L, const char* name, lua_CFunction open) {
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");
	lua_pushcfunction(L, open);
	lua_setfield(L, -2, name);
	lua_pop(L, 2);
}

int traceback(lua_State* L) {
	const char* message = lua_tostring(L, 1);
	lua_getglobal(L, "debug");
	lua_getfield(L, -1, "traceback");
	lua_pushstring(L, message != nullptr ? message : "(error object is not a string)");
	lua_pushinteger(L, 2);
	lua_call(L, 2, 1);
	return 1;
}

bool call_protected(lua_State* L, int nargs, int nresults);

// A new state with the libraries, `stellar`, `fnmatch` and `sigmatch`, scripts from lua/ and
// print() to the log; null if it cannot be made
lua_State* new_state() {
	lua_State* S = luaL_newstate();
	if (S == nullptr) {
		write_log("cannot create a Lua state");
		return nullptr;
	}
	luaL_openlibs(S);
	preload(S, "stellar", luaopen_stellar);
	preload(S, "fnmatch", luaopen_fnmatch);
	preload(S, "sigmatch", luaopen_sigmatch);
	lua_getglobal(S, "package");
	lua_pushfstring(S, "%s\\?.lua;%s\\?\\init.lua;", lua_dir, lua_dir);
	lua_getfield(S, -2, "path");
	lua_concat(S, 2);
	lua_setfield(S, -2, "path");
	lua_pop(S, 1);
	lua_pushcfunction(S, l_log);
	lua_setglobal(S, "print");
	return S;
}

// Runs lua/<script> in S; false (logged) when it cannot be loaded or fails
bool run_script(lua_State* S, const char* script) {
	lua_pushfstring(S, "%s\\%s", lua_dir, script);
	const int status = luaL_loadfile(S, lua_tostring(S, -1));
	lua_remove(S, -2);
	if (status != 0) {
		write_log(lua_tostring(S, -1));
		lua_pop(S, 1);
		return false;
	}
	return call_protected(S, 0, 0);
}

// the worker state of this thread (made on first use; null if it could not be)
thread_local lua_State* worker_state = nullptr;
thread_local bool worker_tried = false;

// Runs the function below the `nargs` arguments on the top of the stack and logs an error; leaves
// `nresults` results when it succeeds.
bool call_protected(lua_State* L, int nargs, int nresults) {
	const int base = lua_gettop(L) - nargs;
	lua_pushcfunction(L, traceback);
	lua_insert(L, base);
	const int status = lua_pcall(L, nargs, nresults, base);
	lua_remove(L, base);
	if (status != 0) {
		write_log(lua_tostring(L, -1));
		lua_pop(L, 1);
		return false;
	}
	return true;
}

} // namespace

std::recursive_mutex& stellar_lua_lock() {
	static std::recursive_mutex lock;
	return lock;
}

lua_State* stellar_lua_state() {
	return L;
}

lua_State* stellar_worker_state() {
	if (!worker_tried) {
		worker_tried = true;
		// after stellar_lua_start has found lua/
		if (lua_dir[0] == '\0') {
			return nullptr;
		}
		lua_State* S = new_state();
		if (S != nullptr && !run_script(S, "worker.lua")) {
			lua_close(S);
			S = nullptr;
		}
		worker_state = S;
	}
	return worker_state;
}

bool stellar_lua_call(lua_State* state, int nargs, int nresults) {
	return call_protected(state, nargs, nresults);
}

void stellar_lua_start() {
	std::lock_guard<std::recursive_mutex> guard(stellar_lua_lock());
	if (L != nullptr) {
		return;
	}

	// lua/ next to stellar-injected.dll
	HMODULE self = nullptr;
	wchar_t wide[MAX_PATH * 2];
	if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		reinterpret_cast<LPCWSTR>(&stellar_lua_start), &self)
		|| GetModuleFileNameW(self, wide, MAX_PATH * 2) == 0 || !to_utf8(wide, dll_path, sizeof(dll_path))) {
		write_log("cannot find the path of stellar-injected.dll, Lua is not started");
		return;
	}
	std::strcpy(lua_dir, dll_path);
	char* slash = std::strrchr(lua_dir, '\\');
	std::strcpy(slash != nullptr ? slash + 1 : lua_dir, "lua");

	L = new_state();
	if (L == nullptr) {
		return;
	}
	{
		std::lock_guard<std::mutex> log_guard(log_lock());
		CLog& logger = *getLogger();
		logger << "Lua: " << LUAJIT_VERSION << ", scripts in " << lua_dir;
		logger.endl();
	}
	// the main state keeps running whatever init.lua did before an error (its hooks)
	run_script(L, "init.lua");
}

void stellar_lua_heartbeat(uint64_t count) {
	std::lock_guard<std::recursive_mutex> guard(stellar_lua_lock());
	if (L == nullptr) {
		return;
	}
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_getfield(L, -1, "stellar");
	if (!lua_istable(L, -1)) {
		lua_pop(L, 3);
		return;
	}
	lua_getfield(L, -1, "heartbeat");
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 4);
		return;
	}
	lua_pushnumber(L, static_cast<lua_Number>(count));
	if (!call_protected(L, 1)) {
		// a failing heartbeat is reported once
		lua_pushnil(L);
		lua_setfield(L, -2, "heartbeat");
	}
	lua_pop(L, 3);
}
