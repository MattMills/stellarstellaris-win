// profiler.cpp : the profiler's hook mode (profiler.txt "hook": lua/stellar/profiler.lua finds the
// functions, by fnmatch globs over the game's symbols, and hooks them here; docs/profiler.md).
//
// Every hooked function jumps (src/dll/code_hook.cpp) to a stub of its own, `mov r11, hook; jmp
// thunk`, and the thunk, one for all of them:
//   - keeps rcx, rdx, r8, r9 and xmm0-3, and calls enter(hook, rsp);
//   - copies 12 stack arguments (the 5th to the 16th) under its own frame, restores the argument
//     registers and calls the original function (the hook's trampoline);
//   - keeps rax and xmm0, calls leave(hook, rsp) and returns them.
// So a hooked function must follow the x64 calling convention, take at most 16 arguments and return
// in rax or xmm0 (not a __vectorcall aggregate). The thunk has unwind data (RtlAddFunctionTable): a
// C++ exception passes through it, and the frames it skipped are dropped from the thread's stack at
// the next enter or leave on that thread (they are deeper: their rsp is lower).
//
// Per function: calls, inclusive time (the outermost call of a recursion only), self time (without
// the hooked functions it called) and the longest call, in QueryPerformanceCounter ticks. The cost
// of the thunk itself shows in the self time of the caller.
//
// Hooks are installed with every other thread suspended (none of them can be in the first
// instructions of a target while its jmp is written: those that are leave that target unhooked),
// and nothing then allocates from the heap.
//
// profile_serve(port, page) starts a web server on 127.0.0.1: `/` is the page (a file, read at
// each request: lua/stellar/profiler.html), `/stats` the counts in JSON, and POST /reset, /enable,
// /hook (patterns queued for Lua: profile_requests) change them. POSTs need the header
// `X-Stellar: 1`, which another site's page cannot send without the server's consent, and every
// request needs a Host of this machine (no DNS rebinding).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <TlHelp32.h>

#include "dll/profiler.h"
#include "dll/code_hook.h"
#include "dll/dllmain.h"

#include <lua.hpp>

#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")

namespace {

// A hooked function. The stub passes its address; `original` is at +0, called by the thunk.
struct Hook {
	void* original;
	std::atomic<uint64_t> calls;
	std::atomic<uint64_t> inclusive;  // ticks
	std::atomic<uint64_t> self;
	std::atomic<uint64_t> longest;
	uintptr_t address;
	size_t index;  // in `names`
};

std::mutex& hooks_lock() {
	static std::mutex lock;
	return lock;
}
std::vector<std::unique_ptr<Hook>> hooks;  // installed, under hooks_lock()
std::vector<std::string> names;

std::atomic<bool> enabled{true};
std::atomic<int64_t> reset_at{0};  // ticks
int64_t frequency = 1;

int64_t now() {
	LARGE_INTEGER count;
	QueryPerformanceCounter(&count);
	return count.QuadPart;
}

//
// The calls in progress on each thread
//

struct Frame {
	Hook* hook;
	uintptr_t sp;       // the thunk's rsp: unique to the call while it runs
	int64_t start;
	uint64_t children;  // ticks in the hooked functions it called
	bool outer;         // not inside a call of the same function
};

const int kMaxDepth = 256;

struct ThreadStack {
	int depth;
	Frame frames[kMaxDepth];
};
thread_local ThreadStack thread_stack;

void enter(Hook* hook, uintptr_t sp) {
	ThreadStack& s = thread_stack;
	// frames an exception went through: as deep as this call or deeper
	while (s.depth > 0 && s.frames[s.depth - 1].sp <= sp) {
		--s.depth;
	}
	if (s.depth == kMaxDepth) {
		return;  // not timed: leave finds no frame of its own
	}
	bool outer = true;
	for (int i = 0; i < s.depth; ++i) {
		if (s.frames[i].hook == hook) {
			outer = false;
			break;
		}
	}
	s.frames[s.depth++] = Frame{hook, sp, now(), 0, outer};
}

void leave(Hook* hook, uintptr_t sp) {
	const int64_t end = now();
	ThreadStack& s = thread_stack;
	while (s.depth > 0 && s.frames[s.depth - 1].sp < sp) {
		--s.depth;
	}
	if (s.depth == 0 || s.frames[s.depth - 1].sp != sp || s.frames[s.depth - 1].hook != hook) {
		return;
	}
	const Frame f = s.frames[--s.depth];
	const uint64_t elapsed = static_cast<uint64_t>(end - f.start);
	if (s.depth > 0) {
		s.frames[s.depth - 1].children += elapsed;
	}
	if (!enabled.load(std::memory_order_relaxed)) {
		return;
	}
	hook->calls.fetch_add(1, std::memory_order_relaxed);
	if (f.outer) {
		hook->inclusive.fetch_add(elapsed, std::memory_order_relaxed);
	}
	hook->self.fetch_add(elapsed > f.children ? elapsed - f.children : 0, std::memory_order_relaxed);
	uint64_t longest = hook->longest.load(std::memory_order_relaxed);
	while (elapsed > longest && !hook->longest.compare_exchange_weak(longest, elapsed, std::memory_order_relaxed)) {
	}
}

//
// The thunk and the stubs
//

// The thunk's frame below its saved rbx
const uint32_t kFrame = 0x100;
const uint32_t kStackArgs = 0x20;    // the 5th to 16th arguments, for the original
const int kStackArgCount = 12;
const uint32_t kRegisters = 0x80;    // rcx, rdx, r8, r9
const uint32_t kVectors = 0xA0;      // xmm0-3
const uint32_t kResult = 0xE0;       // rax
const uint32_t kVectorResult = 0xF0; // xmm0
const uint32_t kCallerArgs = kFrame + 8 + 8 + 0x20;  // rbx, the return address, the home area

struct Code {
	std::vector<uint8_t> bytes;
	void put(std::initializer_list<uint8_t> b) {
		bytes.insert(bytes.end(), b);
	}
	void u32(uint32_t v) {
		for (int i = 0; i < 4; ++i) {
			bytes.push_back(static_cast<uint8_t>(v >> (8 * i)));
		}
	}
	void u64(uint64_t v) {
		for (int i = 0; i < 8; ++i) {
			bytes.push_back(static_cast<uint8_t>(v >> (8 * i)));
		}
	}
	// mov [rsp+disp], reg / mov reg, [rsp+disp]: reg 0-7 is rax..rdi, 8-15 r8..r15
	void store(int reg, uint32_t disp) {
		put({static_cast<uint8_t>(reg >= 8 ? 0x4C : 0x48), 0x89, static_cast<uint8_t>(0x84 | ((reg & 7) << 3)), 0x24});
		u32(disp);
	}
	void load(int reg, uint32_t disp) {
		put({static_cast<uint8_t>(reg >= 8 ? 0x4C : 0x48), 0x8B, static_cast<uint8_t>(0x84 | ((reg & 7) << 3)), 0x24});
		u32(disp);
	}
	// movdqu [rsp+disp], xmmN / movdqu xmmN, [rsp+disp]
	void store_xmm(int n, uint32_t disp) {
		put({0xF3, 0x0F, 0x7F, static_cast<uint8_t>(0x84 | (n << 3)), 0x24});
		u32(disp);
	}
	void load_xmm(int n, uint32_t disp) {
		put({0xF3, 0x0F, 0x6F, static_cast<uint8_t>(0x84 | (n << 3)), 0x24});
		u32(disp);
	}
	// rcx = rbx (the hook), rdx = rsp; call f
	void call_with_hook(void (*f)(Hook*, uintptr_t)) {
		put({0x48, 0x89, 0xD9, 0x48, 0x89, 0xE2, 0x48, 0xB8});  // mov rcx, rbx; mov rdx, rsp; mov rax, f
		u64(reinterpret_cast<uint64_t>(f));
		put({0xFF, 0xD0});  // call rax
	}
};

const int kRcx = 1, kRdx = 2, kRax = 0, kR8 = 8, kR9 = 9;

uint8_t* thunk = nullptr;
RUNTIME_FUNCTION thunk_function;

// The thunk, with its unwind data registered; false if it cannot be made
bool make_thunk() {
	if (thunk != nullptr) {
		return true;
	}
	Code c;
	c.put({0x53});                               // push rbx
	c.put({0x48, 0x81, 0xEC}); c.u32(kFrame);    // sub rsp, kFrame
	const uint8_t prolog = static_cast<uint8_t>(c.bytes.size());
	c.store(kRcx, kRegisters); c.store(kRdx, kRegisters + 8); c.store(kR8, kRegisters + 16); c.store(kR9, kRegisters + 24);
	for (int n = 0; n < 4; ++n) {
		c.store_xmm(n, kVectors + 16 * n);
	}
	c.put({0x4C, 0x89, 0xDB});                   // mov rbx, r11: the hook
	c.call_with_hook(&enter);
	for (int i = 0; i < kStackArgCount; ++i) {
		c.load(kRax, kCallerArgs + 8 * i);
		c.store(kRax, kStackArgs + 8 * i);
	}
	c.load(kRcx, kRegisters); c.load(kRdx, kRegisters + 8); c.load(kR8, kRegisters + 16); c.load(kR9, kRegisters + 24);
	for (int n = 0; n < 4; ++n) {
		c.load_xmm(n, kVectors + 16 * n);
	}
	c.put({0xFF, 0x13});                         // call [rbx]: the original
	c.store(kRax, kResult);
	c.store_xmm(0, kVectorResult);
	c.call_with_hook(&leave);
	c.load(kRax, kResult);
	c.load_xmm(0, kVectorResult);
	c.put({0x48, 0x81, 0xC4}); c.u32(kFrame);    // add rsp, kFrame
	c.put({0x5B, 0xC3});                         // pop rbx; ret

	// UNWIND_INFO: version 1, no handler; UWOP_ALLOC_LARGE (kFrame / 8) at the end of the prolog,
	// UWOP_PUSH_NONVOL rbx after the push (codes in reverse order, padded to an even count)
	const size_t code_size = c.bytes.size();
	while (c.bytes.size() % 4 != 0) {
		c.put({0xCC});
	}
	const size_t unwind = c.bytes.size();
	c.put({0x01, prolog, 3, 0x00});
	c.put({prolog, 0x01});
	c.put({static_cast<uint8_t>((kFrame / 8) & 0xFF), static_cast<uint8_t>((kFrame / 8) >> 8)});
	c.put({0x01, 0x30});
	c.put({0x00, 0x00});

	uint8_t* block = static_cast<uint8_t*>(VirtualAlloc(nullptr, c.bytes.size(), MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
	if (block == nullptr) {
		return false;
	}
	std::memcpy(block, c.bytes.data(), c.bytes.size());
	DWORD protect = 0;
	VirtualProtect(block, c.bytes.size(), PAGE_EXECUTE_READ, &protect);
	FlushInstructionCache(GetCurrentProcess(), block, c.bytes.size());
	thunk_function.BeginAddress = 0;
	thunk_function.EndAddress = static_cast<DWORD>(code_size);
	thunk_function.UnwindData = static_cast<DWORD>(unwind);
	if (!RtlAddFunctionTable(&thunk_function, 1, reinterpret_cast<DWORD64>(block))) {
		VirtualFree(block, 0, MEM_RELEASE);
		return false;
	}
	thunk = block;
	return true;
}

// Stubs: `mov r11, hook; jmp [rip+0]; thunk` (24 bytes), in blocks of 64 KB written before use
const size_t kStubSize = 24;
const size_t kStubBlock = 64 * 1024;
uint8_t* stub_block = nullptr;
size_t stub_used = kStubBlock;

uint8_t* make_stub(Hook* hook) {
	if (stub_used + kStubSize > kStubBlock) {
		stub_block = static_cast<uint8_t*>(VirtualAlloc(nullptr, kStubBlock, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READ));
		if (stub_block == nullptr) {
			return nullptr;
		}
		stub_used = 0;
	}
	uint8_t* stub = stub_block + stub_used;
	DWORD protect = 0;
	if (!VirtualProtect(stub, kStubSize, PAGE_EXECUTE_READWRITE, &protect)) {
		return nullptr;
	}
	const uint64_t h = reinterpret_cast<uint64_t>(hook), t = reinterpret_cast<uint64_t>(thunk);
	const uint8_t mov[] = {0x49, 0xBB};
	const uint8_t jmp[] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};
	std::memcpy(stub, mov, 2);
	std::memcpy(stub + 2, &h, 8);
	std::memcpy(stub + 10, jmp, 6);
	std::memcpy(stub + 16, &t, 8);
	VirtualProtect(stub, kStubSize, PAGE_EXECUTE_READ, &protect);
	FlushInstructionCache(GetCurrentProcess(), stub, kStubSize);
	stub_used += kStubSize;
	return stub;
}

//
// Lua
//

uintptr_t to_address(lua_State* L, int idx) {
	const lua_Number value = lua_tonumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0 || value != static_cast<lua_Number>(static_cast<uint64_t>(value))) {
		return 0;
	}
	return static_cast<uintptr_t>(value);
}

struct Pending {
	uintptr_t address;
	std::string name;
	std::unique_ptr<Hook> hook;
	uint8_t* stub;
	const char* error;
};

// stellar.profile_hook({ {address = a, name = "..."}, ... }) -> results, hooked: results[i] is true
// or why the i-th was not hooked
int l_profile_hook(lua_State* L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	const int count = static_cast<int>(lua_objlen(L, 1));
	for (int i = 1; i <= count; ++i) {
		lua_rawgeti(L, 1, i);
		luaL_argcheck(L, lua_istable(L, -1), 1, "a list of { address, name } expected");
		lua_getfield(L, -1, "address");
		luaL_argcheck(L, to_address(L, -1) != 0, 1, "an entry without an address");
		lua_getfield(L, -2, "name");
		luaL_argcheck(L, lua_isstring(L, -1), 1, "an entry without a name");
		lua_pop(L, 3);
	}
	lua_createtable(L, count, 0);
	int hooked = 0;
	{
		std::vector<Pending> pending(static_cast<size_t>(count));
		const bool ready = make_thunk();
		for (int i = 0; i < count; ++i) {
			Pending& p = pending[static_cast<size_t>(i)];
			lua_rawgeti(L, 1, i + 1);
			lua_getfield(L, -1, "address");
			p.address = to_address(L, -1);
			lua_getfield(L, -2, "name");
			p.name = lua_tostring(L, -1);
			lua_pop(L, 3);
			p.error = ready ? nullptr : "the profiler's thunk cannot be made";
			if (p.error == nullptr) {
				p.hook.reset(new Hook{nullptr, {0}, {0}, {0}, {0}, p.address, 0});
				p.stub = make_stub(p.hook.get());
				if (p.stub == nullptr) {
					p.error = "no memory for the hook's stub";
				}
			}
		}

		// every other thread, suspended; where each one is
		std::vector<HANDLE> threads;
		HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
		if (snapshot != INVALID_HANDLE_VALUE) {
			THREADENTRY32 te;
			te.dwSize = sizeof(te);
			for (BOOL more = Thread32First(snapshot, &te); more; more = Thread32Next(snapshot, &te)) {
				if (te.th32OwnerProcessID == GetCurrentProcessId() && te.th32ThreadID != GetCurrentThreadId()) {
					HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, FALSE, te.th32ThreadID);
					if (thread != nullptr) {
						threads.push_back(thread);
					}
				}
			}
			CloseHandle(snapshot);
		}
		std::vector<uint64_t> where(threads.size(), 0);
		std::vector<bool> suspended(threads.size(), false);
		// no heap allocation from here to the resume
		for (size_t t = 0; t < threads.size(); ++t) {
			suspended[t] = SuspendThread(threads[t]) != static_cast<DWORD>(-1);
		}
		for (size_t t = 0; t < threads.size(); ++t) {
			alignas(16) CONTEXT context;
			context.ContextFlags = CONTEXT_CONTROL;
			if (suspended[t] && GetThreadContext(threads[t], &context)) {
				where[t] = context.Rip;
			}
		}
		for (Pending& p : pending) {
			if (p.error != nullptr) {
				continue;
			}
			for (uint64_t rip : where) {
				if (rip > p.address && rip < p.address + 16) {
					p.error = "a thread was in its first instructions";
				}
			}
			if (p.error == nullptr) {
				install_code_hook(reinterpret_cast<void*>(p.address), p.stub, &p.hook->original, &p.error);
			}
		}
		for (size_t t = 0; t < threads.size(); ++t) {
			if (suspended[t]) {
				ResumeThread(threads[t]);
			}
			CloseHandle(threads[t]);
		}

		std::lock_guard<std::mutex> guard(hooks_lock());
		for (int i = 0; i < count; ++i) {
			Pending& p = pending[static_cast<size_t>(i)];
			if (p.error == nullptr) {
				p.hook->index = names.size();
				names.push_back(p.name);
				hooks.push_back(std::move(p.hook));
				++hooked;
				lua_pushboolean(L, 1);
			}
			else {
				lua_pushstring(L, p.error);
			}
			lua_rawseti(L, -2, i + 1);
		}
	}
	lua_pushnumber(L, hooked);
	return 2;
}

// Notes for the page (what Lua did: patterns, how many hooked), the last 200
std::mutex& notes_lock() {
	static std::mutex lock;
	return lock;
}
std::deque<std::string> notes;

// stellar.profile_note(text)
int l_profile_note(lua_State* L) {
	const char* text = luaL_checkstring(L, 1);
	std::lock_guard<std::mutex> guard(notes_lock());
	notes.emplace_back(text);
	while (notes.size() > 200) {
		notes.pop_front();
	}
	return 0;
}

// Patterns asked for on the page, for Lua to hook (stellar.profile_requests)
std::mutex& requests_lock() {
	static std::mutex lock;
	return lock;
}
std::vector<std::string> requests;

// stellar.profile_requests() -> the patterns asked for since the last call
int l_profile_requests(lua_State* L) {
	std::vector<std::string> taken;
	{
		std::lock_guard<std::mutex> guard(requests_lock());
		taken.swap(requests);
	}
	lua_createtable(L, static_cast<int>(taken.size()), 0);
	for (size_t i = 0; i < taken.size(); ++i) {
		lua_pushlstring(L, taken[i].data(), taken[i].size());
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

//
// The web server
//

std::string page_path;
std::atomic<bool> serving{false};

void json_string(std::string& out, const std::string& s) {
	out += '"';
	for (unsigned char ch : s) {
		if (ch == '"' || ch == '\\') {
			out += '\\';
			out += static_cast<char>(ch);
		}
		else if (ch < 0x20) {
			char buffer[8];
			std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
			out += buffer;
		}
		else {
			out += static_cast<char>(ch);
		}
	}
	out += '"';
}

double ticks_us(uint64_t ticks) {
	return static_cast<double>(ticks) * 1e6 / static_cast<double>(frequency);
}

// {"enabled", "seconds" since the reset, "hooks", "pending" requests, "notes", "functions": [[index,
// name, rva, calls, inclusive us, self us, longest us], ...]}; only the functions called since the
// reset unless `all`
std::string stats_json(bool all) {
	std::string out;
	char buffer[160];
	std::snprintf(buffer, sizeof(buffer), "{\"enabled\":%s,\"seconds\":%.3f,", enabled.load() ? "true" : "false",
		static_cast<double>(now() - reset_at.load()) / static_cast<double>(frequency));
	out += buffer;
	{
		std::lock_guard<std::mutex> guard(requests_lock());
		std::snprintf(buffer, sizeof(buffer), "\"pending\":%u,", static_cast<unsigned>(requests.size()));
		out += buffer;
	}
	out += "\"notes\":[";
	{
		std::lock_guard<std::mutex> guard(notes_lock());
		for (size_t i = 0; i < notes.size(); ++i) {
			if (i > 0) {
				out += ',';
			}
			json_string(out, notes[i]);
		}
	}
	out += "],";
	std::lock_guard<std::mutex> guard(hooks_lock());
	std::snprintf(buffer, sizeof(buffer), "\"hooks\":%u,\"functions\":[", static_cast<unsigned>(hooks.size()));
	out += buffer;
	bool first = true;
	for (const auto& h : hooks) {
		const uint64_t calls = h->calls.load(std::memory_order_relaxed);
		if (calls == 0 && !all) {
			continue;
		}
		if (!first) {
			out += ',';
		}
		first = false;
		std::snprintf(buffer, sizeof(buffer), "[%u,", static_cast<unsigned>(h->index));
		out += buffer;
		json_string(out, names[h->index]);
		std::snprintf(buffer, sizeof(buffer), ",%llu,%llu,%.3f,%.3f,%.3f]",
			static_cast<unsigned long long>(h->address - reinterpret_cast<uintptr_t>(hModule)),
			static_cast<unsigned long long>(calls), ticks_us(h->inclusive.load(std::memory_order_relaxed)),
			ticks_us(h->self.load(std::memory_order_relaxed)), ticks_us(h->longest.load(std::memory_order_relaxed)));
		out += buffer;
	}
	out += "]}";
	return out;
}

void reset_counts() {
	std::lock_guard<std::mutex> guard(hooks_lock());
	for (const auto& h : hooks) {
		h->calls.store(0, std::memory_order_relaxed);
		h->inclusive.store(0, std::memory_order_relaxed);
		h->self.store(0, std::memory_order_relaxed);
		h->longest.store(0, std::memory_order_relaxed);
	}
	reset_at.store(now());
}

void send_all(SOCKET s, const char* data, size_t size) {
	while (size > 0) {
		const int n = send(s, data, static_cast<int>(size > 65536 ? 65536 : size), 0);
		if (n <= 0) {
			return;
		}
		data += n;
		size -= static_cast<size_t>(n);
	}
}

void respond(SOCKET s, const char* status, const char* type, const std::string& body) {
	char head[256];
	const int n = std::snprintf(head, sizeof(head),
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %u\r\nCache-Control: no-store\r\n"
		"X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
		status, type, static_cast<unsigned>(body.size()));
	send_all(s, head, static_cast<size_t>(n));
	send_all(s, body.data(), body.size());
}

int hex_digit(char c) {
	return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

// the value of `key` in a query string, decoded ("" if absent)
std::string query_value(const std::string& query, const char* key) {
	const std::string k = std::string(key) + "=";
	size_t at = 0;
	while (at < query.size()) {
		size_t end = query.find('&', at);
		if (end == std::string::npos) {
			end = query.size();
		}
		if (query.compare(at, k.size(), k) == 0) {
			std::string out;
			for (size_t i = at + k.size(); i < end; ++i) {
				if (query[i] == '+') {
					out += ' ';
				}
				else if (query[i] == '%' && i + 2 < end && hex_digit(query[i + 1]) >= 0 && hex_digit(query[i + 2]) >= 0) {
					out += static_cast<char>(hex_digit(query[i + 1]) * 16 + hex_digit(query[i + 2]));
					i += 2;
				}
				else {
					out += query[i];
				}
			}
			return out;
		}
		at = end + 1;
	}
	return "";
}

// the value of a header (name in lower case), trimmed
std::string header(const std::string& request, const char* name) {
	size_t at = request.find("\r\n");
	while (at != std::string::npos && at + 2 < request.size()) {
		const size_t start = at + 2;
		const size_t end = request.find("\r\n", start);
		if (end == std::string::npos || end == start) {
			break;
		}
		const size_t colon = request.find(':', start);
		if (colon != std::string::npos && colon < end && colon - start == std::strlen(name)) {
			bool same = true;
			for (size_t i = 0; i < colon - start && same; ++i) {
				same = static_cast<char>(std::tolower(static_cast<unsigned char>(request[start + i]))) == name[i];
			}
			if (same) {
				size_t v = colon + 1, e = end;
				while (v < e && request[v] == ' ') {
					++v;
				}
				while (e > v && request[e - 1] == ' ') {
					--e;
				}
				return request.substr(v, e - v);
			}
		}
		at = end;
	}
	return "";
}

bool local_host(const std::string& host) {
	std::string name = host;
	if (!name.empty() && name[0] == '[') {
		name = name.substr(0, name.find(']') + 1);
	}
	else {
		name = name.substr(0, name.find(':'));
	}
	return name == "127.0.0.1" || name == "localhost" || name == "[::1]";
}

void handle(SOCKET s) {
	std::string request;
	char buffer[4096];
	while (request.find("\r\n\r\n") == std::string::npos) {
		if (request.size() > 16384) {
			return;
		}
		const int n = recv(s, buffer, sizeof(buffer), 0);
		if (n <= 0) {
			return;
		}
		request.append(buffer, static_cast<size_t>(n));
	}
	const size_t space = request.find(' ');
	const size_t space2 = space == std::string::npos ? std::string::npos : request.find(' ', space + 1);
	if (space2 == std::string::npos) {
		respond(s, "400 Bad Request", "text/plain", "bad request\n");
		return;
	}
	const std::string method = request.substr(0, space);
	const std::string target = request.substr(space + 1, space2 - space - 1);
	const size_t question = target.find('?');
	const std::string path = target.substr(0, question);
	const std::string query = question == std::string::npos ? "" : target.substr(question + 1);
	if (!local_host(header(request, "host"))) {
		respond(s, "403 Forbidden", "text/plain", "this server answers requests for 127.0.0.1 only\n");
		return;
	}
	if (method == "GET" && (path == "/" || path == "/index.html")) {
		// the path is UTF-8
		std::string page;
		wchar_t wide[MAX_PATH * 2];
		FILE* f = nullptr;
		if (MultiByteToWideChar(CP_UTF8, 0, page_path.c_str(), -1, wide, MAX_PATH * 2) > 0) {
			_wfopen_s(&f, wide, L"rb");
		}
		if (f != nullptr) {
			size_t n;
			while ((n = std::fread(buffer, 1, sizeof(buffer), f)) > 0) {
				page.append(buffer, n);
			}
			std::fclose(f);
			respond(s, "200 OK", "text/html; charset=utf-8", page);
		}
		else {
			respond(s, "404 Not Found", "text/plain", "the page is missing: " + page_path + "\n");
		}
		return;
	}
	if (method == "GET" && path == "/stats") {
		respond(s, "200 OK", "application/json", stats_json(query_value(query, "all") == "1"));
		return;
	}
	if (method == "POST" && (path == "/reset" || path == "/enable" || path == "/hook")) {
		if (header(request, "x-stellar") != "1") {
			respond(s, "403 Forbidden", "text/plain", "the header X-Stellar: 1 is needed\n");
			return;
		}
		if (path == "/reset") {
			reset_counts();
		}
		else if (path == "/enable") {
			enabled.store(query_value(query, "on") != "0");
		}
		else {
			const std::string pattern = query_value(query, "pattern");
			if (pattern.empty() || pattern.size() > 1000) {
				respond(s, "400 Bad Request", "text/plain", "pattern= is needed\n");
				return;
			}
			std::lock_guard<std::mutex> guard(requests_lock());
			requests.push_back(pattern);
		}
		respond(s, "200 OK", "application/json", "{\"ok\":true}");
		return;
	}
	respond(s, "404 Not Found", "text/plain", "not found\n");
}

void serve(SOCKET listener) {
	for (;;) {
		SOCKET s = accept(listener, nullptr, nullptr);
		if (s == INVALID_SOCKET) {
			Sleep(100);
			continue;
		}
		DWORD timeout = 5000;
		setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
		setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
		handle(s);
		shutdown(s, SD_SEND);
		closesocket(s);
	}
}

// stellar.profile_serve(port, page) -> true | nil, message: the web server on 127.0.0.1:port, its
// page the file at `page`
int l_profile_serve(lua_State* L) {
	const lua_Number port = luaL_checknumber(L, 1);
	const char* page = luaL_checkstring(L, 2);
	luaL_argcheck(L, port >= 1 && port <= 65535 && port == static_cast<int>(port), 1, "a port expected");
	if (serving.load()) {
		lua_pushnil(L);
		lua_pushliteral(L, "the profiler's server runs already");
		return 2;
	}
	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
		lua_pushnil(L);
		lua_pushliteral(L, "WSAStartup failed");
		return 2;
	}
	SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (listener == INVALID_SOCKET) {
		lua_pushnil(L);
		lua_pushfstring(L, "socket failed: error %d", WSAGetLastError());
		return 2;
	}
	BOOL exclusive = TRUE;
	setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
	sockaddr_in address{};
	address.sin_family = AF_INET;
	address.sin_port = htons(static_cast<u_short>(port));
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 || listen(listener, 16) != 0) {
		const int error = WSAGetLastError();
		closesocket(listener);
		lua_pushnil(L);
		lua_pushfstring(L, "cannot listen on 127.0.0.1:%d: error %d", static_cast<int>(port), error);
		return 2;
	}
	page_path = page;
	serving.store(true);
	std::thread(serve, listener).detach();
	lua_pushboolean(L, 1);
	return 1;
}

} // namespace

void stellar_profiler_open(lua_State* L) {
	// once: every Lua state (the workers' too) opens `stellar`
	static std::once_flag clock;
	std::call_once(clock, [] {
		LARGE_INTEGER f;
		QueryPerformanceFrequency(&f);
		frequency = f.QuadPart > 0 ? f.QuadPart : 1;
		reset_at.store(now());
	});
	const luaL_Reg functions[] = {
		{"profile_hook", l_profile_hook},
		{"profile_serve", l_profile_serve},
		{"profile_requests", l_profile_requests},
		{"profile_note", l_profile_note},
		{nullptr, nullptr},
	};
	for (const luaL_Reg* f = functions; f->name != nullptr; ++f) {
		lua_pushcfunction(L, f->func);
		lua_setfield(L, -2, f->name);
	}
}
