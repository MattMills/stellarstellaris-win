// modifier_stats.cpp : what the game's modifier nodes cost over time (lua/stellar/modifier_capture.lua
// installs it; docs/modifiers.md, "Per-object modifier nodes"). Observation only.
//
// - CModifierNodeBase::Update(node): a node recomputed (a full rebuild) when it was invalid:
//   counted with its time, by node category. Called for every parent a node reads, valid or not:
//   the valid calls are counted apart.
// - CModifierNodeManager::MarkNodeAsInvalid(manager, id, category): a node marked invalid, by
//   category, and by the function that marked it (its return address).
// - CModifierNodeManager::Update(manager): a pass over the invalid nodes, with its time.
// stellar.modifier_stats([reset]) hands the counts to Lua.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <intrin.h>

#include "dll/modifier_stats.h"
#include "dll/code_hook.h"

#include <lua.hpp>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <unordered_map>

namespace {

const int kCategories = 40;

struct Counts {
	std::atomic<uint64_t> recomputed[kCategories];
	std::atomic<uint64_t> recompute_ns[kCategories];
	std::atomic<uint64_t> valid_calls{0};
	std::atomic<uint64_t> marked[kCategories];
	std::atomic<uint64_t> passes{0};
	std::atomic<uint64_t> pass_ns{0};
};
Counts counts;

std::mutex callers_lock;
std::unordered_map<uintptr_t, uint64_t> mark_callers;   // return address -> marks

LARGE_INTEGER frequency;

uint64_t ticks_to_ns(int64_t ticks) {
	return static_cast<uint64_t>(ticks * 1000000000.0 / frequency.QuadPart);
}

int category_of(const uint8_t* node) {
	const uint8_t* type = *reinterpret_cast<const uint8_t* const*>(node);
	if (type == nullptr) {
		return kCategories - 1;
	}
	const int c = *reinterpret_cast<const int32_t*>(type + 8);
	return c >= 0 && c < kCategories - 1 ? c : kCategories - 1;
}

using node_update_function = void (*)(uint8_t* node);
node_update_function original_node_update = nullptr;

void node_update_hook(uint8_t* node) {
	// registered (id != -1) and invalid (+0x108): a rebuild
	if (*reinterpret_cast<const int32_t*>(node + 8) == -1 || *(node + 0x108) == 0) {
		++counts.valid_calls;
		original_node_update(node);
		return;
	}
	const int c = category_of(node);
	LARGE_INTEGER start, end;
	QueryPerformanceCounter(&start);
	original_node_update(node);
	QueryPerformanceCounter(&end);
	++counts.recomputed[c];
	counts.recompute_ns[c] += ticks_to_ns(end.QuadPart - start.QuadPart);
}

using mark_function = void (*)(void* manager, uint32_t id, uint32_t category);
mark_function original_mark = nullptr;

void mark_hook(void* manager, uint32_t id, uint32_t category) {
	const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
	++counts.marked[category < kCategories - 1 ? category : kCategories - 1];
	{
		std::lock_guard<std::mutex> guard(callers_lock);
		++mark_callers[caller];
	}
	original_mark(manager, id, category);
}

using manager_update_function = void (*)(void* manager);
manager_update_function original_manager_update = nullptr;

void manager_update_hook(void* manager) {
	LARGE_INTEGER start, end;
	QueryPerformanceCounter(&start);
	original_manager_update(manager);
	QueryPerformanceCounter(&end);
	++counts.passes;
	counts.pass_ns += ticks_to_ns(end.QuadPart - start.QuadPart);
}

uintptr_t check_address(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

// stellar.modifier_stats_hook(node_update, mark, manager_update) -> true | nil, message
int l_modifier_stats_hook(lua_State* L) {
	QueryPerformanceFrequency(&frequency);
	const struct {
		const char* name;
		void* target;
		void* hook;
		void** original;
	} hooks[] = {
		{"CModifierNodeBase::Update", reinterpret_cast<void*>(check_address(L, 1)), reinterpret_cast<void*>(&node_update_hook),
			reinterpret_cast<void**>(&original_node_update)},
		{"MarkNodeAsInvalid", reinterpret_cast<void*>(check_address(L, 2)), reinterpret_cast<void*>(&mark_hook),
			reinterpret_cast<void**>(&original_mark)},
		{"CModifierNodeManager::Update", reinterpret_cast<void*>(check_address(L, 3)),
			reinterpret_cast<void*>(&manager_update_hook), reinterpret_cast<void**>(&original_manager_update)},
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

// stellar.modifier_stats([reset]) -> { passes, pass_seconds, valid_calls, categories = { [c] = {
// recomputed, seconds, marked } }, callers = { [return address] = marks } }
int l_modifier_stats(lua_State* L) {
	const bool reset = lua_toboolean(L, 1) != 0;
	lua_createtable(L, 0, 5);
	lua_pushnumber(L, static_cast<lua_Number>(reset ? counts.passes.exchange(0) : counts.passes.load()));
	lua_setfield(L, -2, "passes");
	lua_pushnumber(L, static_cast<lua_Number>(reset ? counts.pass_ns.exchange(0) : counts.pass_ns.load()) / 1e9);
	lua_setfield(L, -2, "pass_seconds");
	lua_pushnumber(L, static_cast<lua_Number>(reset ? counts.valid_calls.exchange(0) : counts.valid_calls.load()));
	lua_setfield(L, -2, "valid_calls");
	lua_createtable(L, kCategories, 0);
	for (int c = 0; c < kCategories; ++c) {
		const uint64_t r = reset ? counts.recomputed[c].exchange(0) : counts.recomputed[c].load();
		const uint64_t ns = reset ? counts.recompute_ns[c].exchange(0) : counts.recompute_ns[c].load();
		const uint64_t m = reset ? counts.marked[c].exchange(0) : counts.marked[c].load();
		if (r == 0 && m == 0) {
			continue;
		}
		lua_createtable(L, 0, 3);
		lua_pushnumber(L, static_cast<lua_Number>(r));
		lua_setfield(L, -2, "recomputed");
		lua_pushnumber(L, static_cast<lua_Number>(ns) / 1e9);
		lua_setfield(L, -2, "seconds");
		lua_pushnumber(L, static_cast<lua_Number>(m));
		lua_setfield(L, -2, "marked");
		lua_rawseti(L, -2, c);
	}
	lua_setfield(L, -2, "categories");
	lua_newtable(L);
	{
		std::lock_guard<std::mutex> guard(callers_lock);
		for (const auto& c : mark_callers) {
			lua_pushnumber(L, static_cast<lua_Number>(c.first));
			lua_pushnumber(L, static_cast<lua_Number>(c.second));
			lua_settable(L, -3);
		}
		if (reset) {
			mark_callers.clear();
		}
	}
	lua_setfield(L, -2, "callers");
	return 1;
}

} // namespace

void stellar_modifier_stats_open(lua_State* L) {
	lua_pushcfunction(L, l_modifier_stats_hook);
	lua_setfield(L, -2, "modifier_stats_hook");
	lua_pushcfunction(L, l_modifier_stats);
	lua_setfield(L, -2, "modifier_stats");
}
