// access_trace.cpp : which of some globals a stretch of code reads (lua/stellar/databases.lua uses
// it to learn what a database's initialization takes from the other databases: their instance
// pointers).
//
// stellar.trace_begin(addresses) puts PAGE_GUARD on the pages of those addresses and adds a
// vectored exception handler. An access to a guarded page raises STATUS_GUARD_PAGE_VIOLATION (the
// system clears the guard): if it is one of the addresses, it is recorded with the tracing thread's
// current id (stellar.trace_set(id)); the handler sets the trap flag, and after that one
// instruction (STATUS_SINGLE_STEP) puts the guard back. stellar.trace_end() takes the guards and
// the handler away and returns what was read: { [id] = { address, ... } }.
//
// Every access to those pages traps, so the code runs much slower while tracing: it is for one
// load that learns, not for every load.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/access_trace.h"

#include <lua.hpp>

#include <algorithm>
#include <cstdint>
#include <map>
#include <mutex>
#include <set>
#include <vector>

namespace {

struct Page {
	uintptr_t base;
	DWORD protect;  // without the guard
};

std::vector<Page> pages;
std::set<uintptr_t> watched;
std::mutex records_lock;
std::map<double, std::set<uintptr_t>> records;
PVOID handler = nullptr;
double current_id = 0;                // the id of what the tracing thread runs now (0: nothing)
DWORD tracing_thread = 0;
uint64_t traps = 0;

thread_local uintptr_t rearm_page = 0;  // the page to guard again after the next single step
const uint64_t kMaxTraps = 50000000;

const Page* page_of(uintptr_t address) {
	const uintptr_t base = address & ~uintptr_t(4095);
	for (const Page& p : pages) {
		if (p.base == base) {
			return &p;
		}
	}
	return nullptr;
}

LONG CALLBACK on_exception(EXCEPTION_POINTERS* info) {
	const DWORD code = info->ExceptionRecord->ExceptionCode;
	if (code == STATUS_GUARD_PAGE_VIOLATION && info->ExceptionRecord->NumberParameters >= 2) {
		const uintptr_t address = static_cast<uintptr_t>(info->ExceptionRecord->ExceptionInformation[1]);
		const Page* page = page_of(address);
		if (page == nullptr) {
			return EXCEPTION_CONTINUE_SEARCH;  // a guard page of something else (a stack)
		}
		++traps;
		if (GetCurrentThreadId() == tracing_thread && current_id != 0 && watched.count(address & ~uintptr_t(7)) != 0) {
			std::lock_guard<std::mutex> guard(records_lock);
			records[current_id].insert(address & ~uintptr_t(7));
		}
		// let the instruction run, then guard the page again
		rearm_page = page->base;
		info->ContextRecord->EFlags |= 0x100;
		return EXCEPTION_CONTINUE_EXECUTION;
	}
	if (code == STATUS_SINGLE_STEP && rearm_page != 0) {
		const Page* page = page_of(rearm_page);
		rearm_page = 0;
		// past the limit the page stays unguarded: the trace stops rather than the load crawling
		if (page != nullptr && traps < kMaxTraps) {
			DWORD old = 0;
			VirtualProtect(reinterpret_cast<void*>(page->base), 4096, page->protect | PAGE_GUARD, &old);
		}
		return EXCEPTION_CONTINUE_EXECUTION;
	}
	return EXCEPTION_CONTINUE_SEARCH;
}

// stellar.trace_begin(addresses) -> pages guarded | nil, message: from the calling thread
int l_trace_begin(lua_State* L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	if (handler != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "a trace is running");
		return 2;
	}
	watched.clear();
	pages.clear();
	records.clear();
	traps = 0;
	const int n = static_cast<int>(lua_objlen(L, 1));
	for (int i = 1; i <= n; ++i) {
		lua_rawgeti(L, 1, i);
		const uintptr_t address = static_cast<uintptr_t>(lua_tonumber(L, -1));
		lua_pop(L, 1);
		if (address == 0) {
			continue;
		}
		watched.insert(address & ~uintptr_t(7));
		const uintptr_t base = address & ~uintptr_t(4095);
		if (page_of(base) == nullptr) {
			MEMORY_BASIC_INFORMATION mbi{};
			if (VirtualQuery(reinterpret_cast<void*>(base), &mbi, sizeof(mbi)) == sizeof(mbi)) {
				pages.push_back(Page{base, mbi.Protect & ~static_cast<DWORD>(PAGE_GUARD)});
			}
		}
	}
	tracing_thread = GetCurrentThreadId();
	current_id = 0;
	handler = AddVectoredExceptionHandler(1, on_exception);
	for (const Page& p : pages) {
		DWORD old = 0;
		VirtualProtect(reinterpret_cast<void*>(p.base), 4096, p.protect | PAGE_GUARD, &old);
	}
	lua_pushnumber(L, static_cast<lua_Number>(pages.size()));
	return 1;
}

// stellar.trace_set(id): what the tracing thread runs from now (0: nothing to record)
int l_trace_set(lua_State* L) {
	current_id = luaL_checknumber(L, 1);
	return 0;
}

// stellar.trace_end() -> { [id] = { address, ... } }, traps
int l_trace_end(lua_State* L) {
	for (const Page& p : pages) {
		DWORD old = 0;
		VirtualProtect(reinterpret_cast<void*>(p.base), 4096, p.protect, &old);
	}
	if (handler != nullptr) {
		RemoveVectoredExceptionHandler(handler);
		handler = nullptr;
	}
	current_id = 0;
	std::map<double, std::set<uintptr_t>> copy;
	{
		std::lock_guard<std::mutex> guard(records_lock);
		copy.swap(records);
	}
	lua_newtable(L);
	for (const auto& r : copy) {
		lua_createtable(L, static_cast<int>(r.second.size()), 0);
		int i = 0;
		for (uintptr_t address : r.second) {
			lua_pushnumber(L, static_cast<lua_Number>(address));
			lua_rawseti(L, -2, ++i);
		}
		lua_pushnumber(L, r.first);
		lua_insert(L, -2);
		lua_settable(L, -3);
	}
	lua_pushnumber(L, static_cast<lua_Number>(traps));
	pages.clear();
	return 2;
}

} // namespace

void stellar_access_trace_open(lua_State* L) {
	lua_pushcfunction(L, l_trace_begin);
	lua_setfield(L, -2, "trace_begin");
	lua_pushcfunction(L, l_trace_set);
	lua_setfield(L, -2, "trace_set");
	lua_pushcfunction(L, l_trace_end);
	lua_setfield(L, -2, "trace_end");
}
