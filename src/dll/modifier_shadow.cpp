// modifier_shadow.cpp : the game's modifier node passes handed to Lua, so that the Lua graph of the
// nodes (lua/stellar/modifier_shadow.lua, stellar.graph.nodes) is checked against them as the game
// runs (docs/modifier_graph.md, "Shadow mode"). Observation only: the game's nodes are not changed.
//
// - CModifierNodeBase::Update(node): a node recomputed (registered and invalid when called): its id
//   (+8: the registry index in the low 20 bits, a version above) is kept, from whichever thread
//   recomputed it (a child's AddModifierNode pulling a stale parent, an UpdateModifier, the ~60
//   other direct callers). Lua finds the node again through the registry, so a node destroyed
//   since is never read.
// - CModifierNodeManager::Update(manager): the pass itself rebuilds its nodes with an inlined copy
//   of Update, so the nodes invalid before it and valid after it are kept too. Then the ids kept
//   since the last delivery go to stellar.modifier_pass(ids, count) (a string of count uint32), on
//   the thread that ran the pass. The game never waits for Lua: while another thread runs Lua, the
//   ids wait for the next pass, and stellar.modifier_shadow_stats() counts it.
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
		try {
			std::lock_guard<std::mutex> guard(recomputed_lock);
			recomputed.push_back(*reinterpret_cast<const uint32_t*>(node + 8));
		} catch (...) {
			// out of memory: the shadow misses this rebuild, the game goes on
		}
	}
}

using manager_update_function = void (*)(void* manager);
manager_update_function original_manager_update = nullptr;

std::atomic<uint64_t> pass_nodes{0};  // nodes the passes rebuilt (found invalid before, valid after)
std::atomic<uint64_t> failures{0};    // deliveries that failed in Lua (after kMaxFailures, none)
const uint64_t kMaxFailures = 3;

// stellar.modifier_pass(ids, count), run by lua_cpcall: the batch is the light userdata argument
int deliver(lua_State* L) {
	const auto* batch = static_cast<const std::vector<uint32_t>*>(lua_touserdata(L, 1));
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_getfield(L, -1, "stellar");
	if (!lua_istable(L, -1)) {
		return 0;
	}
	lua_getfield(L, -1, "modifier_pass");
	if (!lua_isfunction(L, -1)) {
		return 0;
	}
	lua_pushlstring(L, reinterpret_cast<const char*>(batch->data()), batch->size() * sizeof(uint32_t));
	lua_pushnumber(L, static_cast<lua_Number>(batch->size()));
	++delivered;
	lua_call(L, 2, 0);
	return 0;
}

// the node at a registry index if it is still the one with this id (registry: manager +8, count
// +20; 24-byte entries, the node at +8)
uint8_t* node_of(const uint8_t* manager, uint32_t id) {
	const uint8_t* data = *reinterpret_cast<uint8_t* const*>(manager + 8);
	const int32_t count = *reinterpret_cast<const int32_t*>(manager + 20);
	const uint32_t index = id & 0xFFFFF;
	if (data == nullptr || static_cast<int32_t>(index) >= count) {
		return nullptr;
	}
	uint8_t* node = *reinterpret_cast<uint8_t* const*>(data + index * 24 + 8);
	if (node == nullptr || *reinterpret_cast<const uint32_t*>(node + 8) != id) {
		return nullptr;
	}
	return node;
}

void manager_update_hook(void* manager) {
	// The pass rebuilds its invalid nodes with an inlined copy of CModifierNodeBase::Update (the
	// manager's UpdateInvalid tasks never call it), so they are found here: invalid before the pass
	// (+0x108), valid after it.
	// Nothing of the shadow's may throw into the game's frames: out of memory, it misses the pass.
	const uint8_t* m = static_cast<const uint8_t*>(manager);
	std::vector<uint32_t> invalid;
	const uint8_t* data = *reinterpret_cast<uint8_t* const*>(m + 8);
	const int32_t count = *reinterpret_cast<const int32_t*>(m + 20);
	if (data != nullptr && *(m + 0x901) != 0) {  // _Dirty: there is something to do
		try {
			for (int32_t k = 0; k < count; ++k) {
				const uint8_t* node = *reinterpret_cast<uint8_t* const*>(data + k * 24 + 8);
				if (node != nullptr && *reinterpret_cast<const int32_t*>(node + 8) != -1 && *(node + 0x108) != 0) {
					invalid.push_back(*reinterpret_cast<const uint32_t*>(node + 8));
				}
			}
		} catch (...) {
			invalid.clear();
		}
	}
	original_manager_update(manager);
	++passes;
	if (!invalid.empty()) {
		try {
			std::lock_guard<std::mutex> guard(recomputed_lock);
			for (const uint32_t id : invalid) {
				const uint8_t* node = node_of(m, id);
				if (node != nullptr && *(node + 0x108) == 0) {
					recomputed.push_back(id);
					++pass_nodes;
				}
			}
		} catch (...) {
		}
	}
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
	if (batch.empty() || failures >= kMaxFailures) {
		return;
	}
	lua_State* L = stellar_lua_state();
	if (L == nullptr) {
		return;
	}
	// Everything that touches the Lua stack runs protected: an error of Lua's (out of memory among
	// them) comes back as a status here, never as an exception through the game's frames.
	const int top = lua_gettop(L);
	if (lua_cpcall(L, &deliver, &batch) != 0) {
		++failures;
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

// stellar.modifier_shadow_stats() -> { passes, delivered, deferred, failures, nodes (rebuilt
// through CModifierNodeBase::Update), pass_nodes (rebuilt inside the passes), waiting }
int l_modifier_shadow_stats(lua_State* L) {
	lua_createtable(L, 0, 7);
	lua_pushnumber(L, static_cast<lua_Number>(failures.load()));
	lua_setfield(L, -2, "failures");
	lua_pushnumber(L, static_cast<lua_Number>(passes.load()));
	lua_setfield(L, -2, "passes");
	lua_pushnumber(L, static_cast<lua_Number>(delivered.load()));
	lua_setfield(L, -2, "delivered");
	lua_pushnumber(L, static_cast<lua_Number>(deferred.load()));
	lua_setfield(L, -2, "deferred");
	lua_pushnumber(L, static_cast<lua_Number>(nodes_seen.load()));
	lua_setfield(L, -2, "nodes");
	lua_pushnumber(L, static_cast<lua_Number>(pass_nodes.load()));
	lua_setfield(L, -2, "pass_nodes");
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
