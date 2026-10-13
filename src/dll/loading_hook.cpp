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
#include "dll/database_workers.h"
#include "dll/lexer_hook.h"
#include "dll/code_hook.h"
#include "dll/lua_runtime.h"

#include <lua.hpp>

#include <atomic>
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
	std::string text;     // push: the file; render: the text drawn; file: its path; list: the folder
	uint64_t texts, tokens, bytes;  // the lexer hook's counts at that moment
	double d1 = 0, d2 = 0;          // file: seconds to read it, to parse it; list: seconds
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

void record(const char* kind, int a, int b, int line, bool flag, std::string text, int c = 0, double d1 = 0,
	double d2 = 0) {
	LoadingEvent e{now(), GetCurrentThreadId(), kind, a, b, line, c, flag, std::move(text), 0, 0, 0, d1, d2};
	stellar_lexer_counts(&e.texts, &e.tokens, &e.bytes);
	std::lock_guard<std::mutex> guard(events_lock);
	if (events.size() < kMaxEvents) {
		events.push_back(std::move(e));
	}
}

// A C string of the game, read with checks (at most `max` bytes): at once, or byte by byte when the
// bytes run into memory that cannot be read
std::string read_string(const char* p, size_t max) {
	std::string out;
	if (p == nullptr || max == 0) {
		return out;
	}
	out.resize(max);
	SIZE_T read = 0;
	if (ReadProcessMemory(GetCurrentProcess(), p, &out[0], max, &read) && read == max) {
		out.resize(std::strlen(out.c_str()));
		return out;
	}
	out.clear();
	char c = 0;
	for (size_t i = 0; i < max; ++i) {
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
	return read_string(data, static_cast<size_t>(size));
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

// The bar, Lua's (stellar.loading_map, stellar.loading_schedule, stellar.loading_tick). The game
// shows each phase of the startup load on a part of the bar it fixed (interface 5-30%, graphics
// 30-80%, databases 80-100%) and nothing after the databases (16 seconds at 100%). Lua gives each
// phase its part of a bar for the whole load (from the times of the last load) and a schedule for
// what comes after: a segment of the bar for each function marked (its entry starts it), crossed
// in the time it took last. The bar moves through the game's own LoadingScreenCallback, which
// also keeps the game's services and window alive: called with (p, 100, 0, 100) it draws p% (when
// p is more than it drew last). Only on the game's thread, at most ten times a second.
// RenderLoadScreen called by the game outside a step (at the start of a phase: its own 30%, 80%)
// draws nothing while the bar is Lua's. The schedule's last segment ends it.
struct BarMap {
	unsigned start, span, new_start, new_span;
};
struct Segment {
	double from = 0, to = 0, seconds = 0;
	bool last = false;  // the load screen goes: the bar is the game's again
};
struct Scheduled {
	uint64_t id;        // the mark that starts it
	Segment segment;
	bool used;          // a mark entered again (a second call) starts the next one with its id
};
std::mutex bar_lock;
std::vector<BarMap> bar_maps;
std::vector<Scheduled> schedule;                      // in the order of the last load
Segment segment;                                      // the current one
double segment_start = 0;
std::atomic<bool> bar_active{false};
void* bar_application = nullptr;                      // CGameApplication, from the game's steps
std::atomic<DWORD> game_thread{0};
double last_tick = 0;
int drawn = -1;                 // the progress on the screen (the most drawn yet)
int* bar_gate = nullptr;        // LoadingScreenCallback's last progress: it draws only above it
int direct_limit = 100;         // before the phases, the game's own frames are drawn up to this
thread_local bool in_step = false;

using step_function = void (*)(void* application, unsigned current, unsigned total, unsigned start, unsigned span);
step_function original_step = nullptr;

// the game's step draws anything above what is on the screen (its own last progress may be
// another: its phases' numbers, before the bar was Lua's)
void sync_gate() {
	if (bar_gate != nullptr) {
		*bar_gate = drawn < 0 ? 0 : drawn;
	}
}

// draws p% through the game's step (on the game's thread, the bar Lua's)
void tick(int p) {
	if (in_step || bar_application == nullptr || p <= drawn || p > 100) {
		return;
	}
	last_tick = now();
	sync_gate();
	in_step = true;
	original_step(bar_application, static_cast<unsigned>(p), 100, 0, 100);
	in_step = false;
}

// the current segment's progress by now, drawn if it moved (main thread, every 100 ms at most)
void maybe_tick() {
	if (!bar_active.load() || in_step || GetCurrentThreadId() != game_thread.load()) {
		return;
	}
	const double t = now();
	if (t - last_tick < 0.1) {
		return;
	}
	double p = segment.from;
	if (segment.seconds > 0) {
		const double f = (t - segment_start) / segment.seconds;
		p = segment.from + (segment.to - segment.from) * (f < 0.98 ? f : 0.98);
	}
	tick(static_cast<int>(p));
}

// a mark entered: the segment it starts, if the schedule has one
void bar_enter(uint64_t id) {
	if (!bar_active.load() || GetCurrentThreadId() != game_thread.load()) {
		return;
	}
	// (the schedule may still be filled from Lua's thread; the lock is not held while drawing)
	bool found = false;
	{
		std::lock_guard<std::mutex> guard(bar_lock);
		for (auto& s : schedule) {
			if (s.id == id && !s.used) {
				s.used = true;
				segment = s.segment;
				segment_start = now();
				found = true;
				break;
			}
		}
	}
	if (!found) {
		maybe_tick();
		return;
	}
	tick(static_cast<int>(segment.from));
	if (segment.last) {
		bar_active.store(false);
	}
}

// RenderLoadScreen(screen, const CString& text, int progress, ..., bool)
using render_function = uintptr_t (*)(void* screen, const void* text, int progress, uintptr_t r9, uintptr_t stack5);
render_function original_render = nullptr;

uintptr_t render_hook(void* screen, const void* text, int progress, uintptr_t r9, uintptr_t stack5) {
	if (bar_active.load() && !in_step && (bar_application != nullptr || progress > direct_limit)) {
		// the game's own number outside a step (once the phases began, or ahead of where the
		// first phase begins on Lua's bar): the bar is Lua's
		record("render", progress, 1, 0, false, read_cstring(text));
		return 0;
	}
	record("render", progress, 0, 0, false, read_cstring(text));
	if (progress > drawn) {
		drawn = progress;
	}
	return original_render(screen, text, progress, r9, stack5);
}

// CGameApplication::LoadingScreenCallback(this, current, total, start, span): a step of a phase of
// the startup load, which has the part [start, start + span] of the bar (moved to Lua's part of
// it, see above)
void step_hook(void* application, unsigned current, unsigned total, unsigned start, unsigned span) {
	record("step", static_cast<int>(current), static_cast<int>(total), static_cast<int>(start), false, std::string(),
		static_cast<int>(span));
	if (in_step) {
		original_step(application, current, total, start, span);
		return;
	}
	bar_application = application;
	game_thread.store(GetCurrentThreadId());
	const bool lua_bar = bar_active.load();
	if (lua_bar) {
		for (const BarMap& m : bar_maps) {
			if (m.start == start && m.span == span) {
				start = m.new_start;
				span = m.new_span;
				break;
			}
		}
		sync_gate();
	}
	in_step = true;
	original_step(application, current, total, start, span);
	in_step = false;
	if (lua_bar) {
		last_tick = now();
	}
}

// Entry hooks: a stub per function records "enter" with the function's id, then runs the function.
// The stub saves and restores the argument registers (rcx, rdx, r8, r9, xmm0-3) around the call to
// record_entry and jumps to the trampoline that install_code_hook writes into its last 8 bytes.
// Each stub has a skip flag (a byte): while it is set, the function returns 0 at once, without the
// event (stellar.set_entry_skip; the original still runs through its trampoline).
// A function may also be deferred (stellar.defer_mark(id, call)): Lua ran it already, on a thread
// of its own (stellar.run_async), and the game's next call of it waits for that run and returns
// what it returned, instead of running it again.
std::mutex deferred_lock;
std::vector<std::pair<uint64_t, size_t>> deferred;    // mark id -> background call
thread_local uintptr_t deferred_result = 0;
std::atomic<uint64_t> deferred_joins{0};
std::atomic<uint64_t> deferred_wait_us{0};

uintptr_t* record_entry(uint64_t id) {
	record("enter", static_cast<int>(id), 0, 0, false, std::string());
	bar_enter(id);
	size_t call = 0;
	{
		std::lock_guard<std::mutex> guard(deferred_lock);
		for (size_t i = 0; i < deferred.size(); ++i) {
			if (deferred[i].first == id) {
				call = deferred[i].second;
				deferred.erase(deferred.begin() + static_cast<std::ptrdiff_t>(i));
				break;
			}
		}
	}
	if (call == 0) {
		return nullptr;
	}
	double waited = 0;
	stellar_async_join(call, &deferred_result, &waited);
	++deferred_joins;
	deferred_wait_us += static_cast<uint64_t>(waited * 1e6);
	return &deferred_result;
}

// the skip flags of the stubs, by id (1, 2, ... across every hook_entries call)
std::vector<uint8_t*> entry_flags(1, nullptr);

const uint8_t kStubSkip[] = {
	0x48, 0xB8,                                // mov rax, imm64 (the skip flag)
};
const uint8_t kStubSkipTest[] = {
	0x80, 0x38, 0x00,                          // cmp byte ptr [rax], 0
	0x74, 0x03,                                // je +3: not skipped
	0x31, 0xC0,                                // xor eax, eax
	0xC3,                                      // ret
};
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
// record_entry returns null (run the function) or where the result of its deferred run is (the
// stub returns that, without running the function: stellar.defer_mark)
const uint8_t kStubTail[] = {
	0xFF, 0xD0,                                // call rax
	0x48, 0x85, 0xC0,                          // test rax, rax
	0x75, 0x3D,                                // jnz deferred (61 bytes on: past the trampoline's address)
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
const uint8_t kStubDeferred[] = {
	0x48, 0x8B, 0x00,                          // deferred: mov rax, [rax] (the result)
	0x48, 0x81, 0xC4, 0x88, 0x00, 0x00, 0x00,  // add rsp, 0x88
	0xC3,                                      // ret
};
static_assert(sizeof(kStubTail) - 7 + 8 == 0x3D, "the jnz offset");
const size_t kStubSize = 192;
static_assert(sizeof(kStubSkip) + 8 + sizeof(kStubSkipTest) + sizeof(kStubHead) + 8 + sizeof(kStubCall) + 8
	+ sizeof(kStubTail) + 8 + sizeof(kStubDeferred) <= kStubSize, "stub size");

// Writes the stub for `id` (with its skip flag) at `stub`; returns where the trampoline's address
// goes
void** write_stub(uint8_t* stub, uint64_t id, const uint8_t* flag) {
	uint8_t* p = stub;
	std::memcpy(p, kStubSkip, sizeof(kStubSkip));
	p += sizeof(kStubSkip);
	const uint64_t flag_address = reinterpret_cast<uint64_t>(flag);
	std::memcpy(p, &flag_address, 8);
	p += 8;
	std::memcpy(p, kStubSkipTest, sizeof(kStubSkipTest));
	p += sizeof(kStubSkipTest);
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
	std::memcpy(p + 8, kStubDeferred, sizeof(kStubDeferred));
	return reinterpret_cast<void**>(p);
}

// The read. CLexer::CLexer(const CString& path, EFileType, ELexerFileType) reads a file into a
// CMemoryFile (VFSOpenFile, PHYSFS_readBytes) that the lexer owns; the reader then parses it until
// the lexer goes, which deletes the CMemoryFile. (The lexer's destructor is often inlined, the
// file's is not: CMemoryFile::~CMemoryFile marks the end.) Each file is one event "file" then: its
// path, size (a), tokens (b), the seconds to read it (d1) and to parse it (d2).
// VFSGetEnumeratedFiles(folder, files, ...) lists a folder from the list a task made
// (VFSPreEnumerateFiles): "list" with the folder, the count (a) and the seconds it took (d1);
// "prelist" when a list is started.
struct OpenFile {
	void* file;  // the lexer's CMemoryFile
	std::string path;
	double start, read;
	uint64_t tokens;
	int64_t size;
};
thread_local std::vector<OpenFile>* open_files = nullptr;  // a reader may open a file while parsing one

using lexer_ctor_function = void* (*)(void* self, const void* path, int file_type, int lexer_type);
lexer_ctor_function original_lexer_ctor = nullptr;

std::atomic<uint64_t> lexer_ctor_calls{0}, lexer_dtor_calls{0}, lexer_dtor_matched{0};

void* lexer_ctor_hook(void* self, const void* path, int file_type, int lexer_type) {
	++lexer_ctor_calls;
	const double start = now();
	void* result = original_lexer_ctor(self, path, file_type, lexer_type);
	uint64_t texts = 0, tokens = 0, bytes = 0;
	stellar_lexer_counts(&texts, &tokens, &bytes);
	if (open_files == nullptr) {
		open_files = new std::vector<OpenFile>();
	}
	void* file = *reinterpret_cast<void* const*>(static_cast<uint8_t*>(self) + 8);  // CLexer::_File
	std::string name = read_cstring(path);
	char file_address[32];
	std::snprintf(file_address, sizeof(file_address), "%p", file);
	record("open", 0, 0, 0, false, name + "|" + file_address);
	open_files->push_back(OpenFile{file, std::move(name), start, now(), tokens, stellar_lexer_file_size(self)});
	return result;
}

// CMemoryFile::~CMemoryFile(this): the end of the parse of a file read by a lexer
using file_dtor_function = void (*)(void* self);
file_dtor_function original_file_dtor = nullptr;

void file_dtor_hook(void* self) {
	++lexer_dtor_calls;
	if (open_files != nullptr) {
		for (size_t i = open_files->size(); i-- > 0;) {
			OpenFile& f = (*open_files)[i];
			if (f.file == self) {
				++lexer_dtor_matched;
				uint64_t texts = 0, tokens = 0, bytes = 0;
				stellar_lexer_counts(&texts, &tokens, &bytes);
				record("file", static_cast<int>(f.size), static_cast<int>(tokens - f.tokens), 0, false, std::move(f.path), 0,
					f.read - f.start, now() - f.read);
				open_files->erase(open_files->begin() + static_cast<std::ptrdiff_t>(i));
				break;
			}
		}
	}
	original_file_dtor(self);
	// a file read: the bar moves on, if it is the game's thread's
	maybe_tick();
}

// void VFSGetEnumeratedFiles(const char* folder, CPdxArray<CString>& files, const char*, const char*, int)
using enumerated_function = void (*)(const char* folder, void* files, const char* a, const char* b, int flag);
enumerated_function original_enumerated = nullptr;

void enumerated_hook(const char* folder, void* files, const char* a, const char* b, int flag) {
	const double start = now();
	original_enumerated(folder, files, a, b, flag);
	int32_t count = 0;
	std::memcpy(&count, static_cast<const uint8_t*>(files) + 20, 4);  // CPdxArray: count at +20
	// the folder and the filter (the next argument is not set by every caller)
	(void)b;
	std::string text = read_string(folder, 512);
	if (a != nullptr) {
		text += "|" + read_string(a, 64);
	}
	record("list", count, flag, 0, false, std::move(text), 0, now() - start);
}

// void VFSPreEnumerateFiles(const char* folder, const char*, const char*, int)
using pre_enumerate_function = void (*)(const char* folder, const char* a, const char* b, int flag);
pre_enumerate_function original_pre_enumerate = nullptr;

void pre_enumerate_hook(const char* folder, const char* a, const char* b, int flag) {
	(void)b;
	std::string text = read_string(folder, 512);
	if (a != nullptr) {
		text += "|" + read_string(a, 64);
	}
	record("prelist", flag, 0, 0, false, std::move(text));
	original_pre_enumerate(folder, a, b, flag);
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

// stellar.hook_entries(functions) -> results, base: hooks each function of the list (addresses) so
// that entering it records the event "enter" with the id base + its index in the list;
// results[i] is the address of its trampoline (which runs the original function, past the hook),
// or the reason it could not be hooked
int l_hook_entries(lua_State* L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	const int n = static_cast<int>(lua_objlen(L, 1));
	// the stubs, then their skip flags
	uint8_t* block = n > 0 ? static_cast<uint8_t*>(VirtualAlloc(nullptr, (kStubSize + 1) * static_cast<size_t>(n),
		MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE)) : nullptr;
	if (n > 0 && block == nullptr) {
		return luaL_error(L, "cannot allocate %d entry stubs", n);
	}
	const size_t base = entry_flags.size() - 1;
	lua_createtable(L, n, 0);
	for (int i = 1; i <= n; ++i) {
		lua_rawgeti(L, 1, i);
		const lua_Number value = lua_tonumber(L, -1);
		lua_pop(L, 1);
		void* target = reinterpret_cast<void*>(static_cast<uintptr_t>(value));
		uint8_t* stub = block + kStubSize * static_cast<size_t>(i - 1);
		uint8_t* flag = block + kStubSize * static_cast<size_t>(n) + static_cast<size_t>(i - 1);
		*flag = 0;
		entry_flags.push_back(flag);
		void** original = write_stub(stub, static_cast<uint64_t>(base + i), flag);
		FlushInstructionCache(GetCurrentProcess(), stub, kStubSize);
		const char* error = nullptr;
		if (!(value > 0)) {
			lua_pushliteral(L, "not an address");
		} else if (!install_code_hook(target, stub, original, &error)) {
			lua_pushstring(L, error);
		} else {
			lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(*original)));
		}
		lua_rawseti(L, -2, i);
	}
	lua_pushnumber(L, static_cast<lua_Number>(base));
	return 2;
}

// stellar.set_entry_skip(id, skip): while skip, the function hooked with this id returns 0 at once
int l_set_entry_skip(lua_State* L) {
	const lua_Number id = luaL_checknumber(L, 1);
	if (id >= 1 && id < static_cast<lua_Number>(entry_flags.size())) {
		*entry_flags[static_cast<size_t>(id)] = lua_toboolean(L, 2) ? 1 : 0;
	}
	return 0;
}

// The databases. NNullObjAndDatabaseInitUtil::SetupDatabases(a, done, progress) initializes them
// (lua/stellar/databases.lua). The hook lets Lua run the loop first: stellar.setup_databases(a,
// done, progress) in the main state, which initializes databases itself and sets the skip flags of
// their CreateInstance and InitInstance; then the game's SetupDatabases runs as always, its loop
// skipping those, and the rest of it (deferred references, PostReadInitInstance) runs on every
// database. The skip flags Lua's loop set are cleared after (not those set meanwhile by hooks
// inside the game's SetupDatabases: CModifier::InitDefinitionIcons is called from it).
using setup_function = void (*)(void* a, void* done, void* progress);
setup_function original_setup = nullptr;

void setup_hook(void* a, void* done, void* progress) {
	// the flags Lua's loop sets are cleared after the game's; flags set later, while the game's
	// SetupDatabases runs (from hooks inside it, such as InitDefinitionIcons'), are left alone
	std::vector<uint8_t> before(entry_flags.size(), 0);
	for (size_t i = 1; i < entry_flags.size(); ++i) {
		before[i] = *entry_flags[i];
	}
	{
		std::lock_guard<std::recursive_mutex> guard(stellar_lua_lock());
		lua_State* L = stellar_lua_state();
		if (L != nullptr) {
			const int top = lua_gettop(L);
			lua_getglobal(L, "package");
			lua_getfield(L, -1, "loaded");
			lua_getfield(L, -1, "stellar");
			if (lua_istable(L, -1)) {
				lua_getfield(L, -1, "setup_databases");
				if (lua_isfunction(L, -1)) {
					lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(a)));
					lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(done)));
					lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(progress)));
					stellar_lua_call(L, 3, 0);
				}
			}
			lua_settop(L, top);
		}
	}
	std::vector<size_t> set_by_lua;
	for (size_t i = 1; i < entry_flags.size() && i < before.size(); ++i) {
		if (*entry_flags[i] != 0 && before[i] == 0) {
			set_by_lua.push_back(i);
		}
	}
	original_setup(a, done, progress);
	for (size_t i : set_by_lua) {
		*entry_flags[i] = 0;
	}
}

// stellar.hook_setup_databases(address) -> true | nil, message
int l_hook_setup_databases(lua_State* L) {
	void* target = reinterpret_cast<void*>(check_address(L, 1));
	const char* error = nullptr;
	if (original_setup != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "SetupDatabases is hooked already");
		return 2;
	}
	if (!install_code_hook(target, reinterpret_cast<void*>(&setup_hook), reinterpret_cast<void**>(&original_setup), &error)) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

// Before hooks (stellar.hook_before(address, name)): the function at address (at most four integer
// or pointer arguments) first calls stellar[name]() in the main state, on its own thread, then
// runs. A few slots, one function each.
void call_lua_named(const std::string& name) {
	std::lock_guard<std::recursive_mutex> guard(stellar_lua_lock());
	lua_State* L = stellar_lua_state();
	if (L == nullptr) {
		return;
	}
	const int top = lua_gettop(L);
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_getfield(L, -1, "stellar");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, name.c_str());
		if (lua_isfunction(L, -1)) {
			stellar_lua_call(L, 0, 0);
		}
	}
	lua_settop(L, top);
}

using before_function = uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t);

template <int Slot>
struct Before {
	static before_function original;
	static std::string name;
	static uintptr_t hook(uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d) {
		call_lua_named(name);
		return original(a, b, c, d);
	}
};
template <int Slot> before_function Before<Slot>::original = nullptr;
template <int Slot> std::string Before<Slot>::name;

struct BeforeSlot {
	void* hook;
	before_function* original;
	std::string* name;
};
BeforeSlot before_slots[] = {
	{reinterpret_cast<void*>(&Before<0>::hook), &Before<0>::original, &Before<0>::name},
	{reinterpret_cast<void*>(&Before<1>::hook), &Before<1>::original, &Before<1>::name},
	{reinterpret_cast<void*>(&Before<2>::hook), &Before<2>::original, &Before<2>::name},
	{reinterpret_cast<void*>(&Before<3>::hook), &Before<3>::original, &Before<3>::name},
};

// stellar.hook_before(address, name) -> true | nil, message
int l_hook_before(lua_State* L) {
	void* target = reinterpret_cast<void*>(check_address(L, 1));
	const char* name = luaL_checkstring(L, 2);
	for (BeforeSlot& slot : before_slots) {
		if (*slot.original == nullptr) {
			*slot.name = name;
			const char* error = nullptr;
			if (!install_code_hook(target, slot.hook, reinterpret_cast<void**>(slot.original), &error)) {
				*slot.original = nullptr;
				lua_pushnil(L);
				lua_pushstring(L, error);
				return 2;
			}
			lua_pushboolean(L, 1);
			return 1;
		}
	}
	lua_pushnil(L);
	lua_pushliteral(L, "no before hook left");
	return 2;
}

// stellar.mark(id): records "enter" with this id, as entering a hooked function does (for a
// function that Lua calls through its trampoline)
int l_mark(lua_State* L) {
	record_entry(static_cast<uint64_t>(luaL_checknumber(L, 1)));
	return 0;
}

// stellar.hook_reads(lexer_ctor, file_dtor, enumerated, pre_enumerate) -> results: hooks the read
// (see above: file_dtor is CMemoryFile::~CMemoryFile); results[i] is true or why the i-th could
// not be hooked
int l_hook_reads(lua_State* L) {
	const struct {
		void* hook;
		void** original;
	} hooks[] = {
		{reinterpret_cast<void*>(&file_dtor_hook), reinterpret_cast<void**>(&original_file_dtor)},
		{reinterpret_cast<void*>(&lexer_ctor_hook), reinterpret_cast<void**>(&original_lexer_ctor)},
		{reinterpret_cast<void*>(&enumerated_hook), reinterpret_cast<void**>(&original_enumerated)},
		{reinterpret_cast<void*>(&pre_enumerate_hook), reinterpret_cast<void**>(&original_pre_enumerate)},
	};
	// the destructor first: a file read after the constructor is hooked must be seen going
	const int order[] = {2, 1, 3, 4};
	lua_createtable(L, 4, 0);
	for (int k = 0; k < 4; ++k) {
		const int i = order[k];
		const lua_Number value = luaL_optnumber(L, i, 0);
		const char* error = nullptr;
		if (*hooks[k].original != nullptr) {
			lua_pushliteral(L, "hooked already");
		} else if (!(value > 0)) {
			lua_pushliteral(L, "not found");
		} else if (!install_code_hook(reinterpret_cast<void*>(static_cast<uintptr_t>(value)), hooks[k].hook, hooks[k].original, &error)) {
			lua_pushstring(L, error);
		} else {
			lua_pushboolean(L, 1);
		}
		lua_rawseti(L, -2, i);
	}
	return 1;
}

// stellar.read_counts() -> CLexer constructor calls (from a path), CMemoryFile destructor calls,
// those of files of lexers made from a path
int l_read_counts(lua_State* L) {
	lua_pushnumber(L, static_cast<lua_Number>(lexer_ctor_calls.load()));
	lua_pushnumber(L, static_cast<lua_Number>(lexer_dtor_calls.load()));
	lua_pushnumber(L, static_cast<lua_Number>(lexer_dtor_matched.load()));
	return 3;
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
		lua_pushnumber(L, e.d1);
		lua_setfield(L, -2, "d1");
		lua_pushnumber(L, e.d2);
		lua_setfield(L, -2, "d2");
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

// stellar.defer_mark(id, call): the game's next call of the marked function id waits for the
// background call (stellar.run_async: Lua ran the function already) and returns its result
int l_defer_mark(lua_State* L) {
	const uint64_t id = static_cast<uint64_t>(luaL_checknumber(L, 1));
	const size_t call = static_cast<size_t>(luaL_checknumber(L, 2));
	std::lock_guard<std::mutex> guard(deferred_lock);
	deferred.emplace_back(id, call);
	return 0;
}

// stellar.loading_application() -> the CGameApplication (from the game's LoadingScreenCallback),
// or nil before its first step
int l_loading_application(lua_State* L) {
	if (bar_application == nullptr) {
		lua_pushnil(L);
	} else {
		lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(bar_application)));
	}
	return 1;
}

// stellar.deferred_stats() -> joins, seconds waited in them, deferrals not joined yet
int l_deferred_stats(lua_State* L) {
	lua_pushnumber(L, static_cast<lua_Number>(deferred_joins.load()));
	lua_pushnumber(L, static_cast<lua_Number>(deferred_wait_us.load()) / 1e6);
	std::lock_guard<std::mutex> guard(deferred_lock);
	lua_pushnumber(L, static_cast<lua_Number>(deferred.size()));
	return 3;
}

// stellar.loading_map(start, span, new_start, new_span): the phase the game shows on [start,
// start + span] of the bar is shown on [new_start, new_start + new_span] (set before
// stellar.loading_bar(true))
int l_loading_map(lua_State* L) {
	BarMap m{static_cast<unsigned>(luaL_checknumber(L, 1)), static_cast<unsigned>(luaL_checknumber(L, 2)),
		static_cast<unsigned>(luaL_checknumber(L, 3)), static_cast<unsigned>(luaL_checknumber(L, 4))};
	std::lock_guard<std::mutex> guard(bar_lock);
	bar_maps.push_back(m);
	return 0;
}

// stellar.loading_schedule(id, from, to, seconds[, last]): entering the mark id starts the
// segment [from, to] of the bar, crossed in about `seconds`; with last, the bar is the game's again
// once it is drawn (set before stellar.loading_bar(true))
int l_loading_schedule(lua_State* L) {
	Segment s;
	s.from = luaL_checknumber(L, 2);
	s.to = luaL_checknumber(L, 3);
	s.seconds = luaL_checknumber(L, 4);
	s.last = lua_toboolean(L, 5) != 0;
	std::lock_guard<std::mutex> guard(bar_lock);
	schedule.push_back(Scheduled{static_cast<uint64_t>(luaL_checknumber(L, 1)), s, false});
	return 0;
}

// stellar.loading_gate(address, limit): LoadingScreenCallback's last progress (a global: it draws
// only above it), kept at what is on the screen; and the most the game's own frames before the
// phases may draw (where the first phase begins on Lua's bar)
int l_loading_gate(lua_State* L) {
	bar_gate = reinterpret_cast<int*>(check_address(L, 1));
	direct_limit = static_cast<int>(luaL_optnumber(L, 2, 100));
	return 0;
}

// stellar.loading_bar(on): the bar is Lua's (the maps and the schedule set) or the game's
int l_loading_bar(lua_State* L) {
	bar_active.store(lua_toboolean(L, 1) != 0);
	return 0;
}

// stellar.loading_segment(from, to, seconds): the current segment, from Lua (on the game's thread:
// a part Lua runs itself, such as the PostReadInitInstance calls)
int l_loading_segment(lua_State* L) {
	if (!bar_active.load() || GetCurrentThreadId() != game_thread.load()) {
		return 0;
	}
	segment.from = luaL_checknumber(L, 1);
	segment.to = luaL_checknumber(L, 2);
	segment.seconds = luaL_checknumber(L, 3);
	segment.last = false;
	segment_start = now();
	tick(static_cast<int>(segment.from));
	return 0;
}

// stellar.loading_tick(): the current segment's progress drawn, if it moved (game's thread only)
int l_loading_tick(lua_State* L) {
	(void)L;
	maybe_tick();
	return 0;
}

} // namespace

void stellar_loading_open(lua_State* L) {
	lua_pushcfunction(L, l_defer_mark);
	lua_setfield(L, -2, "defer_mark");
	lua_pushcfunction(L, l_deferred_stats);
	lua_setfield(L, -2, "deferred_stats");
	lua_pushcfunction(L, l_loading_application);
	lua_setfield(L, -2, "loading_application");
	lua_pushcfunction(L, l_loading_map);
	lua_setfield(L, -2, "loading_map");
	lua_pushcfunction(L, l_loading_schedule);
	lua_setfield(L, -2, "loading_schedule");
	lua_pushcfunction(L, l_loading_bar);
	lua_setfield(L, -2, "loading_bar");
	lua_pushcfunction(L, l_loading_gate);
	lua_setfield(L, -2, "loading_gate");
	lua_pushcfunction(L, l_loading_segment);
	lua_setfield(L, -2, "loading_segment");
	lua_pushcfunction(L, l_loading_tick);
	lua_setfield(L, -2, "loading_tick");
	lua_pushcfunction(L, l_hook_loading);
	lua_setfield(L, -2, "hook_loading");
	lua_pushcfunction(L, l_loading_events);
	lua_setfield(L, -2, "loading_events");
	lua_pushcfunction(L, l_hook_entries);
	lua_setfield(L, -2, "hook_entries");
	lua_pushcfunction(L, l_set_entry_skip);
	lua_setfield(L, -2, "set_entry_skip");
	lua_pushcfunction(L, l_hook_setup_databases);
	lua_setfield(L, -2, "hook_setup_databases");
	lua_pushcfunction(L, l_mark);
	lua_setfield(L, -2, "mark");
	lua_pushcfunction(L, l_hook_before);
	lua_setfield(L, -2, "hook_before");
	lua_pushcfunction(L, l_hook_reads);
	lua_setfield(L, -2, "hook_reads");
	lua_pushcfunction(L, l_read_counts);
	lua_setfield(L, -2, "read_counts");
}
