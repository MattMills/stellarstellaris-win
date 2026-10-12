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
	const char* kind;     // "push", "pop", "render"
	int a, b, line;       // push: start, end, line; render: progress; step: current, total, start
	int c;                // step: span
	bool flag;            // push: the state was pushed; pop: it had been
	std::string text;     // push: the file; render: the text drawn
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
	LoadingEvent e{now(), GetCurrentThreadId(), kind, a, b, line, c, flag, std::move(text)};
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

// stellar.loading_events() -> the events since the last call:
// { time, thread, kind, a, b, line, flag, text }
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
}
