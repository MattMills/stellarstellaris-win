// modifier_shadow.cpp : the game's modifier node passes handed to Lua, so that the Lua graph of the
// nodes (lua/stellar/modifier_shadow.lua, stellar.graph.nodes) is checked against them as the game
// runs (docs/modifier_graph.md, "Shadow mode"). Observation only: the game's nodes are not changed.
//
// - CModifierNodeBase::Update(node): a node recomputed (registered and invalid when called): its id
//   (+8: the registry index in the low 20 bits, a version above) is kept, from whichever thread
//   recomputed it (the pass's parallel-fors, a child's AddModifierNode pulling a stale parent, an
//   UpdateModifier outside the passes). Lua finds the node again through the registry, so a node
//   destroyed since is never read.
// - CModifierNodeManager::Update(manager): after the game's pass, the ids kept since the last
//   delivery go to stellar.modifier_pass(ids, count) (a string of count uint32), on the thread that
//   ran the pass. The game never waits for Lua: while another thread runs Lua, the ids wait for the
//   next pass, and stellar.modifier_shadow_stats() counts it.
//
// It hooks the functions stellar.modifier_stats_hook counts: one of the two at a time.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/modifier_shadow.h"
#include "dll/code_hook.h"
#include "dll/lua_runtime.h"

#include <lua.hpp>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

namespace {

std::mutex recomputed_lock;
std::vector<uint32_t> recomputed;  // the ids of the nodes recomputed since the last delivery

std::atomic<uint64_t> passes{0};      // the game's passes
std::atomic<uint64_t> delivered{0};   // passes handed to Lua (with nodes)
std::atomic<uint64_t> deferred{0};    // passes whose nodes waited (Lua busy on another thread)
std::atomic<uint64_t> nodes_seen{0};  // recomputes recorded

using node_update_function = void (*)(uint8_t* node);
node_update_function original_node_update = nullptr;

void node_update_hook(uint8_t* node) {
	// registered (id != -1) and invalid (+0x108): a rebuild
	const bool rebuild = *reinterpret_cast<const int32_t*>(node + 8) != -1 && *(node + 0x108) != 0;
	original_node_update(node);
	if (rebuild) {
		++nodes_seen;
		std::lock_guard<std::mutex> guard(recomputed_lock);
		recomputed.push_back(*reinterpret_cast<const uint32_t*>(node + 8));
	}
}

using manager_update_function = void (*)(void* manager);
manager_update_function original_manager_update = nullptr;

void manager_update_hook(void* manager) {
	original_manager_update(manager);
	++passes;
	std::unique_lock<std::recursive_mutex> lua_guard(stellar_lua_lock(), std::try_to_lock);
	if (!lua_guard.owns_lock()) {
		++deferred;
		return;
	}
	std::vector<uint32_t> batch;
	{
		std::lock_guard<std::mutex> guard(recomputed_lock);
		batch.swap(recomputed);
	}
	if (batch.empty()) {
		return;
	}
	lua_State* L = stellar_lua_state();
	if (L == nullptr) {
		return;
	}
	const int top = lua_gettop(L);
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_getfield(L, -1, "stellar");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "modifier_pass");
		if (lua_isfunction(L, -1)) {
			lua_pushlstring(L, reinterpret_cast<const char*>(batch.data()), batch.size() * sizeof(uint32_t));
			lua_pushnumber(L, static_cast<lua_Number>(batch.size()));
			++delivered;
			if (!stellar_lua_call(L, 2, 0)) {
				// a failing handler is reported once
				lua_pushnil(L);
				lua_setfield(L, -2, "modifier_pass");
			}
		}
	}
	lua_settop(L, top);
}

uintptr_t check_address(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

// stellar.modifier_shadow_hook(node_update, manager_update) -> true | nil, message
int l_modifier_shadow_hook(lua_State* L) {
	if (original_node_update != nullptr) {
		lua_pushnil(L);
		lua_pushstring(L, "already hooked");
		return 2;
	}
	const struct {
		const char* name;
		void* target;
		void* hook;
		void** original;
	} hooks[] = {
		{"CModifierNodeBase::Update", reinterpret_cast<void*>(check_address(L, 1)), reinterpret_cast<void*>(&node_update_hook),
			reinterpret_cast<void**>(&original_node_update)},
		{"CModifierNodeManager::Update", reinterpret_cast<void*>(check_address(L, 2)),
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

// stellar.modifier_shadow_stats() -> { passes, delivered, deferred, nodes, waiting }
int l_modifier_shadow_stats(lua_State* L) {
	lua_createtable(L, 0, 5);
	lua_pushnumber(L, static_cast<lua_Number>(passes.load()));
	lua_setfield(L, -2, "passes");
	lua_pushnumber(L, static_cast<lua_Number>(delivered.load()));
	lua_setfield(L, -2, "delivered");
	lua_pushnumber(L, static_cast<lua_Number>(deferred.load()));
	lua_setfield(L, -2, "deferred");
	lua_pushnumber(L, static_cast<lua_Number>(nodes_seen.load()));
	lua_setfield(L, -2, "nodes");
	size_t waiting;
	{
		std::lock_guard<std::mutex> guard(recomputed_lock);
		waiting = recomputed.size();
	}
	lua_pushnumber(L, static_cast<lua_Number>(waiting));
	lua_setfield(L, -2, "waiting");
	return 1;
}

} // namespace

void stellar_modifier_shadow_open(lua_State* L) {
	lua_pushcfunction(L, l_modifier_shadow_hook);
	lua_setfield(L, -2, "modifier_shadow_hook");
	lua_pushcfunction(L, l_modifier_shadow_stats);
	lua_setfield(L, -2, "modifier_shadow_stats");
}
