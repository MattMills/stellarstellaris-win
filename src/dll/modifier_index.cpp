// modifier_index.cpp : an index of the game's modifier definitions by token
// (lua/stellar/modifier_index.lua installs it; docs/modifiers.md).
//
// The game finds a modifier type from its token with a linear scan of
// CPdxModifier<...>::_Definitions (176-byte definitions, the token at +0x90, the type at +0x94):
// in CModifier::GetTypeFromToken, in CPdxModifier::TryReadMember (every modifier key read from
// script) and in CModifier::TryAddDynamicModifier (every generated modifier, 45,000 in 4.5.2, each
// scanning all those before it). The index (token -> the first definition with it, as the scan
// finds) answers instead, kept up to date as definitions are added:
// - GetTypeFromToken is replaced;
// - in the other two, the scan is replaced by a stub that asks the index and goes on where the
//   scan's result goes (found: the definition; not found: what the code does then).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/modifier_index.h"
#include "dll/code_hook.h"

#include <lua.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

uint8_t* const* definitions_data = nullptr;  // &_Definitions._pData
const int32_t* definitions_size = nullptr;   // &_Definitions._nSize
const size_t kDefinitionSize = 176, kToken = 0x90, kType = 0x94;

std::mutex index_lock;
std::vector<int32_t> by_token;  // token -> index + 1 (0: none)
int32_t indexed = 0;
uint64_t lookups = 0, found = 0;

// the index of the first definition with this token, or -1
int64_t find_index(int32_t token) {
	std::lock_guard<std::mutex> guard(index_lock);
	++lookups;
	const int32_t size = *definitions_size;
	const uint8_t* data = *definitions_data;
	if (size < indexed) {
		// fewer definitions than indexed: index them again
		std::fill(by_token.begin(), by_token.end(), 0);
		indexed = 0;
	}
	for (; indexed < size; ++indexed) {
		int32_t t = 0;
		std::memcpy(&t, data + static_cast<size_t>(indexed) * kDefinitionSize + kToken, 4);
		if (t < 0) {
			continue;
		}
		if (static_cast<size_t>(t) >= by_token.size()) {
			by_token.resize(static_cast<size_t>(t) * 2 + 1024, 0);
		}
		if (by_token[static_cast<size_t>(t)] == 0) {
			by_token[static_cast<size_t>(t)] = indexed + 1;
		}
	}
	if (token < 0 || static_cast<size_t>(token) >= by_token.size() || by_token[static_cast<size_t>(token)] == 0) {
		return -1;
	}
	++found;
	return by_token[static_cast<size_t>(token)] - 1;
}

// the definition with this token, or null (for the stub in TryAddDynamicModifier)
uint8_t* find_definition(int32_t token) {
	const int64_t i = find_index(token);
	return i < 0 ? nullptr : *definitions_data + static_cast<size_t>(i) * kDefinitionSize;
}

// CModifier::GetTypeFromToken(int token) -> ModifierType (0x7FFFFFFF when there is none)
int32_t get_type_hook(int32_t token) {
	const uint8_t* d = find_definition(token);
	if (d == nullptr) {
		return 0x7FFFFFFF;
	}
	int32_t type = 0;
	std::memcpy(&type, d + kType, 4);
	return type;
}

void* get_type_original = nullptr;

uint8_t* stubs = nullptr;
size_t stubs_used = 0;

uint8_t* put(uint8_t* p, const void* bytes, size_t size) {
	std::memcpy(p, bytes, size);
	return p + size;
}

uint8_t* put64(uint8_t* p, uint64_t value) {
	return put(p, &value, 8);
}

// jmp [rip+0] followed by the address
uint8_t* put_jump(uint8_t* p, uintptr_t to) {
	const uint8_t jmp[] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};
	p = put(p, jmp, sizeof(jmp));
	return put64(p, to);
}

// The stub for TryAddDynamicModifier's scan (the token in ebx; with `prefix`, the stub starts
// where `mov ebx, eax` was): found, r8 = the definition and on to `found_at`; not found, eax = the
// number of definitions (the new type) and on to `missing_at`.
uint8_t* stub_add(bool prefix, uintptr_t found_at, uintptr_t missing_at) {
	uint8_t* start = stubs + stubs_used;
	uint8_t* p = start;
	if (prefix) {
		const uint8_t mov_ebx_eax[] = {0x8B, 0xD8};
		p = put(p, mov_ebx_eax, sizeof(mov_ebx_eax));
	}
	const uint8_t a[] = {
		0x48, 0x83, 0xEC, 0x20,  // sub rsp, 32
		0x8B, 0xCB,              // mov ecx, ebx
		0x48, 0xB8,              // mov rax, find_definition
	};
	p = put(p, a, sizeof(a));
	p = put64(p, reinterpret_cast<uint64_t>(&find_definition));
	const uint8_t b[] = {
		0xFF, 0xD0,              // call rax
		0x48, 0x83, 0xC4, 0x20,  // add rsp, 32
		0x48, 0x85, 0xC0,        // test rax, rax
		0x74, 0x11,              // je +17: not found
		0x4C, 0x8B, 0xC0,        // mov r8, rax
	};
	p = put(p, b, sizeof(b));
	p = put_jump(p, found_at);
	const uint8_t c[] = {0x48, 0xB8};  // mov rax, &size
	p = put(p, c, sizeof(c));
	p = put64(p, reinterpret_cast<uint64_t>(definitions_size));
	const uint8_t d[] = {0x8B, 0x00};  // mov eax, [rax]
	p = put(p, d, sizeof(d));
	p = put_jump(p, missing_at);
	stubs_used = static_cast<size_t>(p - stubs + 15) & ~size_t(15);
	return start;
}

// The stub for TryReadMember's scan (the token in r8d): found, edi = the definition's index and on
// to `found_at`; not found, on to `missing_at`.
uint8_t* stub_read(uintptr_t found_at, uintptr_t missing_at) {
	uint8_t* start = stubs + stubs_used;
	uint8_t* p = start;
	const uint8_t a[] = {
		0x48, 0x83, 0xEC, 0x20,  // sub rsp, 32
		0x41, 0x8B, 0xC8,        // mov ecx, r8d
		0x48, 0xB8,              // mov rax, find_index
	};
	p = put(p, a, sizeof(a));
	p = put64(p, reinterpret_cast<uint64_t>(&find_index));
	const uint8_t b[] = {
		0xFF, 0xD0,              // call rax
		0x48, 0x83, 0xC4, 0x20,  // add rsp, 32
		0x48, 0x85, 0xC0,        // test rax, rax
		0x78, 0x10,              // js +16: not found
		0x8B, 0xF8,              // mov edi, eax
	};
	p = put(p, b, sizeof(b));
	p = put_jump(p, found_at);
	p = put_jump(p, missing_at);
	stubs_used = static_cast<size_t>(p - stubs + 15) & ~size_t(15);
	return start;
}

uintptr_t check_address(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0 || value != static_cast<lua_Number>(static_cast<uint64_t>(value))) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

// stellar.modifier_index(t) -> results: t = { data, size (the addresses of _Definitions' data
// pointer and size), get_type (GetTypeFromToken), add_scan, add_prefix (true when add_scan is the
// `mov ebx, eax` before the scan), add_found, add_missing, read_scan, read_found, read_missing };
// results = { get_type, add, read }: true or why that one is not installed
int l_modifier_index(lua_State* L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	auto number = [L](const char* name) -> uintptr_t {
		lua_getfield(L, 1, name);
		const uintptr_t value = lua_isnumber(L, -1) ? static_cast<uintptr_t>(lua_tonumber(L, -1)) : 0;
		lua_pop(L, 1);
		return value;
	};
	if (definitions_data != nullptr) {
		return luaL_error(L, "the modifier index is installed already");
	}
	definitions_data = reinterpret_cast<uint8_t* const*>(number("data"));
	definitions_size = reinterpret_cast<const int32_t*>(number("size"));
	if (definitions_data == nullptr || definitions_size == nullptr) {
		return luaL_error(L, "the addresses of _Definitions are needed");
	}
	stubs = static_cast<uint8_t*>(VirtualAlloc(nullptr, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
	lua_createtable(L, 0, 3);
	const char* error = nullptr;
	const uintptr_t get_type = number("get_type");
	if (get_type == 0) {
		lua_pushliteral(L, "not found");
	} else if (!install_code_hook(reinterpret_cast<void*>(get_type), reinterpret_cast<void*>(&get_type_hook), &get_type_original, &error)) {
		lua_pushstring(L, error);
	} else {
		lua_pushboolean(L, 1);
	}
	lua_setfield(L, -2, "get_type");
	void* unused = nullptr;
	const uintptr_t add_scan = number("add_scan"), add_found = number("add_found"), add_missing = number("add_missing");
	lua_getfield(L, 1, "add_prefix");
	const bool add_prefix = lua_toboolean(L, -1) != 0;
	lua_pop(L, 1);
	if (add_scan == 0 || add_found == 0 || add_missing == 0) {
		lua_pushliteral(L, "not found");
	} else if (!install_code_hook(reinterpret_cast<void*>(add_scan), stub_add(add_prefix, add_found, add_missing), &unused, &error)) {
		lua_pushstring(L, error);
	} else {
		lua_pushboolean(L, 1);
	}
	lua_setfield(L, -2, "add");
	const uintptr_t read_scan = number("read_scan"), read_found = number("read_found"), read_missing = number("read_missing");
	if (read_scan == 0 || read_found == 0 || read_missing == 0) {
		lua_pushliteral(L, "not found");
	} else if (!install_code_hook(reinterpret_cast<void*>(read_scan), stub_read(read_found, read_missing), &unused, &error)) {
		lua_pushstring(L, error);
	} else {
		lua_pushboolean(L, 1);
	}
	lua_setfield(L, -2, "read");
	FlushInstructionCache(GetCurrentProcess(), stubs, 4096);
	return 1;
}

// stellar.modifier_index_stats() -> lookups, found, indexed
int l_modifier_index_stats(lua_State* L) {
	std::lock_guard<std::mutex> guard(index_lock);
	lua_pushnumber(L, static_cast<lua_Number>(lookups));
	lua_pushnumber(L, static_cast<lua_Number>(found));
	lua_pushnumber(L, static_cast<lua_Number>(indexed));
	return 3;
}

} // namespace

void stellar_modifier_index_open(lua_State* L) {
	lua_pushcfunction(L, l_modifier_index);
	lua_setfield(L, -2, "modifier_index");
	lua_pushcfunction(L, l_modifier_index_stats);
	lua_setfield(L, -2, "modifier_index_stats");
}
