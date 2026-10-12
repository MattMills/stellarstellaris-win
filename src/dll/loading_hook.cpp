// loading_hook.cpp : the load screen's stages and progress (lua/stellar/loading.lua logs them).
//
// SPushLoadScreenState(start, end, file, line) begins a stage of loading: the part [start, end]
// (0 to 100) of the stage around it, named by the C++ file and line that pushed it; its destructor
// ends the stage (loading a save, a new game). CGameApplication::LoadingScreenCallback(current,
// total, start, span) is a step of a phase of the startup load, which has the part [start,
// start + span] of the bar. RenderLoadScreen draws the load screen at a progress (0 to 100). The
// hooks only record these events, with the time and the thread; stellar.loading_events() hands
// them to Lua.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/loading_hook.h"
#include "dll/lexer_hook.h"
#include "dll/code_hook.h"

#include <lua.hpp>

#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct LoadingEvent {
	double time;          // seconds since 1970
	uint32_t thread;
	const char* kind;     // "push", "pop", "render", "step", "enter"
	int a, b, line;       // push: start, end, line; render: progress; step: current, total, start;
	                      // enter: the id of the function entered
	int c;                // step: span
	bool flag;            // push: the state was pushed; pop: it had been
	std::string text;     // push: the file; render: the text drawn
	uint64_t texts, tokens, bytes;  // the lexer hook's counts at that moment
};

std::mutex events_lock;
std::vector<LoadingEvent> events;
const size_t kMaxEvents = 100000;  // while Lua does not take them

double now() {
	FILETIME ft;
	GetSystemTimePreciseAsFileTime(&ft);
	const uint64_t t = (static_cast<uint64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
	return static_cast<double>(t - 116444736000000000ULL) / 1e7;
}

void record(const char* kind, int a, int b, int line, bool flag, std::string text, int c = 0) {
	LoadingEvent e{now(), GetCurrentThreadId(), kind, a, b, line, c, flag, std::move(text), 0, 0, 0};
	stellar_lexer_counts(&e.texts, &e.tokens, &e.bytes);
	std::lock_guard<std::mutex> guard(events_lock);
	if (events.size() < kMaxEvents) {
		events.push_back(std::move(e));
	}
}

// A C string of the game, read with checks (at most `max` bytes)
std::string read_string(const char* p, size_t max) {
	std::string out;
	char c = 0;
	SIZE_T read = 0;
	for (size_t i = 0; p != nullptr && i < max; ++i) {
		if (!ReadProcessMemory(GetCurrentProcess(), p + i, &c, 1, &read) || read != 1 || c == '\0') {
			break;
		}
		out += c;
	}
	return out;
}

// A CString of the game: a std::string at +16 (inline below 16 bytes)
std::string read_cstring(const void* s) {
	uint8_t raw[48];
	SIZE_T read = 0;
	if (s == nullptr || !ReadProcessMemory(GetCurrentProcess(), s, raw, sizeof(raw), &read) || read != sizeof(raw)) {
		return "";
	}
	uint64_t size = 0, capacity = 0;
	std::memcpy(&size, raw + 32, 8);
	std::memcpy(&capacity, raw + 40, 8);
	if (capacity < size || size > 4096) {
		return "";
	}
	if (capacity < 16) {
		return std::string(reinterpret_cast<const char*>(raw + 16), static_cast<size_t>(size));
	}
	const char* data = nullptr;
	std::memcpy(&data, raw + 16, 8);
	return read_string(data, static_cast<size_t>(size < 200 ? size : 200));
}

// SPushLoadScreenState::SPushLoadScreenState(this, int start, int end, const char* file, int line)
using push_function = void* (*)(void* self, int start, int end, const char* file, int line);
push_function original_push = nullptr;

void* push_hook(void* self, int start, int end, const char* file, int line) {
	void* result = original_push(self, start, end, file, line);
	record("push", start, end, line, *static_cast<const uint8_t*>(self) != 0, read_string(file, 260));
	return result;
}

// SPushLoadScreenState::~SPushLoadScreenState(this): pops the state if it was pushed (_bDidPush)
using pop_function = void (*)(void* self);
pop_function original_pop = nullptr;

void pop_hook(void* self) {
	const bool pushed = *static_cast<const uint8_t*>(self) != 0;
	original_pop(self);
	record("pop", 0, 0, 0, pushed, std::string());
}

// RenderLoadScreen(screen, const CString& text, int progress, ..., bool)
using render_function = uintptr_t (*)(void* screen, const void* text, int progress, uintptr_t r9, uintptr_t stack5);
render_function original_render = nullptr;

uintptr_t render_hook(void* screen, const void* text, int progress, uintptr_t r9, uintptr_t stack5) {
	record("render", progress, 0, 0, false, read_cstring(text));
	return original_render(screen, text, progress, r9, stack5);
}

// CGameApplication::LoadingScreenCallback(this, current, total, start, span): a step of a phase of
// the startup load, which has the part [start, start + span] of the bar
using step_function = void (*)(void* application, unsigned current, unsigned total, unsigned start, unsigned span);
step_function original_step = nullptr;

void step_hook(void* application, unsigned current, unsigned total, unsigned start, unsigned span) {
	record("step", static_cast<int>(current), static_cast<int>(total), static_cast<int>(start), false, std::string(),
		static_cast<int>(span));
	original_step(application, current, total, start, span);
}

// Entry hooks: a stub per function records "enter" with the function's id, then runs the function.
// The stub saves and restores the argument registers (rcx, rdx, r8, r9, xmm0-3) around the call to
// record_entry and jumps to the trampoline that install_code_hook writes into its last 8 bytes.
void record_entry(uint64_t id) {
	record("enter", static_cast<int>(id), 0, 0, false, std::string());
}

const uint8_t kStubHead[] = {
	0x48, 0x81, 0xEC, 0x88, 0x00, 0x00, 0x00,  // sub rsp, 0x88 (aligned for the call)
	0x48, 0x89, 0x4C, 0x24, 0x20,              // mov [rsp+0x20], rcx
	0x48, 0x89, 0x54, 0x24, 0x28,              // mov [rsp+0x28], rdx
	0x4C, 0x89, 0x44, 0x24, 0x30,              // mov [rsp+0x30], r8
	0x4C, 0x89, 0x4C, 0x24, 0x38,              // mov [rsp+0x38], r9
	0x0F, 0x11, 0x44, 0x24, 0x40,              // movups [rsp+0x40], xmm0
	0x0F, 0x11, 0x4C, 0x24, 0x50,              // movups [rsp+0x50], xmm1
	0x0F, 0x11, 0x54, 0x24, 0x60,              // movups [rsp+0x60], xmm2
	0x0F, 0x11, 0x5C, 0x24, 0x70,              // movups [rsp+0x70], xmm3
	0x48, 0xB9,                                // mov rcx, imm64 (the id)
};
const uint8_t kStubCall[] = {0x48, 0xB8};      // mov rax, imm64 (record_entry)
const uint8_t kStubTail[] = {
	0xFF, 0xD0,                                // call rax
	0x48, 0x8B, 0x4C, 0x24, 0x20,              // mov rcx, [rsp+0x20]
	0x48, 0x8B, 0x54, 0x24, 0x28,              // mov rdx, [rsp+0x28]
	0x4C, 0x8B, 0x44, 0x24, 0x30,              // mov r8, [rsp+0x30]
	0x4C, 0x8B, 0x4C, 0x24, 0x38,              // mov r9, [rsp+0x38]
	0x0F, 0x10, 0x44, 0x24, 0x40,              // movups xmm0, [rsp+0x40]
	0x0F, 0x10, 0x4C, 0x24, 0x50,              // movups xmm1, [rsp+0x50]
	0x0F, 0x10, 0x54, 0x24, 0x60,              // movups xmm2, [rsp+0x60]
	0x0F, 0x10, 0x5C, 0x24, 0x70,              // movups xmm3, [rsp+0x70]
	0x48, 0x81, 0xC4, 0x88, 0x00, 0x00, 0x00,  // add rsp, 0x88
	0xFF, 0x25, 0x00, 0x00, 0x00, 0x00,        // jmp [rip+0]: the trampoline, in the next 8 bytes
};
const size_t kStubSize = 160;
static_assert(sizeof(kStubHead) + 8 + sizeof(kStubCall) + 8 + sizeof(kStubTail) + 8 <= kStubSize, "stub size");

// Writes the stub for `id` at `stub`; returns where the trampoline's address goes
void** write_stub(uint8_t* stub, uint64_t id) {
	uint8_t* p = stub;
	std::memcpy(p, kStubHead, sizeof(kStubHead));
	p += sizeof(kStubHead);
	std::memcpy(p, &id, 8);
	p += 8;
	std::memcpy(p, kStubCall, sizeof(kStubCall));
	p += sizeof(kStubCall);
	const uint64_t function = reinterpret_cast<uint64_t>(&record_entry);
	std::memcpy(p, &function, 8);
	p += 8;
	std::memcpy(p, kStubTail, sizeof(kStubTail));
	p += sizeof(kStubTail);
	std::memset(p, 0, 8);
	return reinterpret_cast<void**>(p);
}

uintptr_t check_address(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0 || value != static_cast<lua_Number>(static_cast<uint64_t>(value))) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

// stellar.hook_loading(push, pop, render, step) -> true | nil, message: hooks SPushLoadScreenState's
// constructor and destructor, RenderLoadScreen and CGameApplication::LoadingScreenCallback
int l_hook_loading(lua_State* L) {
	void* push = reinterpret_cast<void*>(check_address(L, 1));
	void* pop = reinterpret_cast<void*>(check_address(L, 2));
	void* render = reinterpret_cast<void*>(check_address(L, 3));
	void* step = reinterpret_cast<void*>(check_address(L, 4));
	if (original_push != nullptr || original_pop != nullptr || original_render != nullptr || original_step != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "the load screen is hooked already");
		return 2;
	}
	const struct {
		const char* name;
		void* target;
		void* hook;
		void** original;
	} hooks[] = {
		{"SPushLoadScreenState::~SPushLoadScreenState", pop, reinterpret_cast<void*>(&pop_hook), reinterpret_cast<void**>(&original_pop)},
		{"SPushLoadScreenState::SPushLoadScreenState", push, reinterpret_cast<void*>(&push_hook), reinterpret_cast<void**>(&original_push)},
		{"RenderLoadScreen", render, reinterpret_cast<void*>(&render_hook), reinterpret_cast<void**>(&original_render)},
		{"CGameApplication::LoadingScreenCallback", step, reinterpret_cast<void*>(&step_hook), reinterpret_cast<void**>(&original_step)},
	};
	for (const auto& h : hooks) {
		const char* error = nullptr;
		if (!install_code_hook(h.target, h.hook, h.original, &error)) {
			lua_pushnil(L);
			lua_pushfstring(L, "%s: %s", h.name, error);
			return 2;
		}
	}
	lua_pushboolean(L, 1);
	return 1;
}

// stellar.hook_entries(functions) -> results: hooks each function of the list (addresses) so that
// entering it records the event "enter" with its index in the list; results[i] is true or the
// reason it could not be hooked
int l_hook_entries(lua_State* L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	const int n = static_cast<int>(lua_objlen(L, 1));
	uint8_t* block = n > 0 ? static_cast<uint8_t*>(VirtualAlloc(nullptr, kStubSize * static_cast<size_t>(n),
		MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE)) : nullptr;
	if (n > 0 && block == nullptr) {
		return luaL_error(L, "cannot allocate %d entry stubs", n);
	}
	lua_createtable(L, n, 0);
	for (int i = 1; i <= n; ++i) {
		lua_rawgeti(L, 1, i);
		const lua_Number value = lua_tonumber(L, -1);
		lua_pop(L, 1);
		void* target = reinterpret_cast<void*>(static_cast<uintptr_t>(value));
		uint8_t* stub = block + kStubSize * static_cast<size_t>(i - 1);
		void** original = write_stub(stub, static_cast<uint64_t>(i));
		FlushInstructionCache(GetCurrentProcess(), stub, kStubSize);
		const char* error = nullptr;
		if (!(value > 0)) {
			lua_pushliteral(L, "not an address");
		} else if (!install_code_hook(target, stub, original, &error)) {
			lua_pushstring(L, error);
		} else {
			lua_pushboolean(L, 1);
		}
		lua_rawseti(L, -2, i);
	}
	return 1;
}

// stellar.loading_events() -> the events since the last call:
// { time, thread, kind, a, b, c, line, flag, text, texts, tokens, bytes }
int l_loading_events(lua_State* L) {
	std::vector<LoadingEvent> taken;
	{
		std::lock_guard<std::mutex> guard(events_lock);
		taken.swap(events);
	}
	lua_createtable(L, static_cast<int>(taken.size()), 0);
	for (size_t i = 0; i < taken.size(); ++i) {
		const LoadingEvent& e = taken[i];
		lua_createtable(L, 0, 8);
		lua_pushnumber(L, e.time);
		lua_setfield(L, -2, "time");
		lua_pushnumber(L, e.thread);
		lua_setfield(L, -2, "thread");
		lua_pushstring(L, e.kind);
		lua_setfield(L, -2, "kind");
		lua_pushinteger(L, e.a);
		lua_setfield(L, -2, "a");
		lua_pushinteger(L, e.b);
		lua_setfield(L, -2, "b");
		lua_pushinteger(L, e.c);
		lua_setfield(L, -2, "c");
		lua_pushinteger(L, e.line);
		lua_setfield(L, -2, "line");
		lua_pushboolean(L, e.flag);
		lua_setfield(L, -2, "flag");
		lua_pushlstring(L, e.text.data(), e.text.size());
		lua_setfield(L, -2, "text");
		lua_pushnumber(L, static_cast<lua_Number>(e.texts));
		lua_setfield(L, -2, "texts");
		lua_pushnumber(L, static_cast<lua_Number>(e.tokens));
		lua_setfield(L, -2, "tokens");
		lua_pushnumber(L, static_cast<lua_Number>(e.bytes));
		lua_setfield(L, -2, "bytes");
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

} // namespace

void stellar_loading_open(lua_State* L) {
	lua_pushcfunction(L, l_hook_loading);
	lua_setfield(L, -2, "hook_loading");
	lua_pushcfunction(L, l_loading_events);
	lua_setfield(L, -2, "loading_events");
	lua_pushcfunction(L, l_hook_entries);
	lua_setfield(L, -2, "hook_entries");
}
