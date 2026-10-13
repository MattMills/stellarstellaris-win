// lexer_hook.cpp : the hook on CTextLexer::GetTok, the game's script tokenizer (docs/text_lexer.md,
// lua/stellar/script/loader.lua).
//
// The game reads its script text with a CTextLexer over a CMemoryFile: each GetTok reads the next
// token of the file into the lexer's _CurrTok and returns 1 (0 at the end). Once hooked, the
// tokens of a text come from Lua: stellar.lexer_tokens(buffer, size, pos, last, unget, line)
// tokenizes the text from that file state and returns the tokens packed (LuaToken) and the text of
// the quoted strings that are not as they are in the file (escapes).
// Lua is asked once per text, and again whenever the file is not where the previous token left it
// (CTextLexer::ReadUntilCharacter reads raw text between tokens, readers may seek).
//
// Shadow mode: the game's GetTok runs, and what it read (its result, the token and the state of the
// file after it) is compared with Lua's token, field by field. stellar.lexer_stats() and
// stellar.lexer_mismatches() report.
//
// Replace mode: the game's GetTok does not run on a CMemoryFile. The hook writes Lua's token into
// _CurrTok (growing its text with the game's CToken::SetCharInString) and the file's state after
// it (_nPos, the line, the last byte, the byte put back), and returns Lua's result. The game's
// readers, and CTextLexer::ReadUntilCharacter, carry on from there.
//
// The offsets of the structures come from Lua (`layout`, from the PDB of 4.5.2 for now).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "dll/lexer_hook.h"
#include "dll/lua_runtime.h"
#include "dll/code_hook.h"

#include <lua.hpp>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct Layout {
	// CLexer
	int lexer_file = 0;        // CFile* _File
	int lexer_peek = 0;        // bool _bPeek: the next GetTok returns the peeked token again
	int lexer_peek_rc = 0;     // int _PeekRC: what it returns then
	int lexer_token = 0;       // _CurrTok, a CToken
	int token_type = 0;        // _CurrTok._LexerToken
	int token_explicit = 0;    // _CurrTok._bExplicitString (a quoted string)
	int token_text = 0;        // _CurrTok._Val: the text
	int token_capacity = 0;    // _CurrTok._Val: its capacity
	int token_size = 0;        // _CurrTok._Val: its size, the NUL included
	// CFile
	int file_line = 0;         // _LineNumber
	int file_last = 0;         // the last character read
	int file_unget = 0;        // the last character is read again by the next Get
	int file_name = 0;         // the name (std::string)
	// CMemoryFile
	uintptr_t memory_file_vtable = 0;
	int memory_holder = 0;     // a shared buffer, or null
	int memory_holder_data = 0;// its data
	int memory_buffer = 0;     // the buffer, without a shared one
	int memory_pos = 0;        // _nPos
	int memory_get_size = 0;   // the vtable slot of GetSize
	// the token table: a function that returns it, find(name) is in its vtable's slot 2
	void* (*token_tree)() = nullptr;
	// CToken::SetCharInString(token, index, byte): writes a byte of the text, growing it
	void (*set_char)(void* token, int index, char byte) = nullptr;
};

Layout layout;

// Replace mode: the tokens of the CMemoryFiles are Lua's, the game's GetTok does not read them
bool replace_mode = false;

// int CLexer::GetTok(CLexer* this)
using get_tok_function = int (*)(void* lexer);
get_tok_function original_get_tok = nullptr;

struct FileState {
	int32_t pos;
	int32_t line;
	uint8_t last;
	uint8_t unget;
	bool operator==(const FileState& other) const {
		return pos == other.pos && line == other.line && last == other.last && unget == other.unget;
	}
	bool operator!=(const FileState& other) const {
		return !(*this == other);
	}
};

// One GetTok call, from Lua (packed by lua/stellar/script/loader.lua)
struct LuaToken {
	int32_t rc;              // what GetTok returns
	int32_t type;            // > 0 the type; < 0 a word: the token table's id for it, or -type
	int32_t text;            // the text: its offset in the file's text, or -1 - its offset in escaped
	int32_t size;            // the size of _Val: the length of the text + 1
	int32_t pos;             // the file after the token
	int32_t line;
	uint8_t filled;          // whether GetTok wrote _CurrTok (not at the end of the text)
	uint8_t explicit_string;
	uint8_t last;
	uint8_t unget;
};
static_assert(sizeof(LuaToken) == 28, "LuaToken is packed by Lua: 6 int32 and 4 bytes");

// The tokens of the text a thread reads
struct Stream {
	const void* file = nullptr;
	const char* buffer = nullptr;
	int32_t size = 0;
	std::vector<LuaToken> tokens;
	std::string escaped;
	size_t next = 0;
	FileState expected{};  // the file after the previous token
};

// The texts a thread is reading: a reader reads other texts in the middle of one (an inline script
// in a file), then goes back to it. The one used least recently gives way to a new one.
struct Streams {
	static const int kCount = 8;
	Stream slots[kCount];
	uint64_t used[kCount] = {};
	uint64_t clock = 0;
};

thread_local Streams* streams = nullptr;

struct Stats {
	std::atomic<uint64_t> calls{0};        // GetTok calls
	std::atomic<uint64_t> peeks{0};        // returning a peeked token
	std::atomic<uint64_t> other_files{0};  // on a file that is not a CMemoryFile
	std::atomic<uint64_t> texts{0};        // texts (new streams)
	std::atomic<uint64_t> texts_not_at_start{0};
	std::atomic<uint64_t> resyncs{0};      // the file was not where the previous token left it
	std::atomic<uint64_t> lua_calls{0};
	std::atomic<uint64_t> lua_failures{0};
	std::atomic<uint64_t> lua_microseconds{0};
	std::atomic<uint64_t> lua_bytes{0};    // of text tokenized
	std::atomic<uint64_t> compared{0};     // tokens compared
	std::atomic<uint64_t> lookups{0};      // of words in the token table
	std::atomic<uint64_t> mismatches{0};
	std::atomic<uint64_t> without_lua{0};  // calls without a Lua token (the game's GetTok reads)
	std::atomic<uint64_t> replaced{0};     // replace mode: tokens Lua gave the game
	std::atomic<uint64_t> text_bytes{0};   // the sizes of the texts started
};

Stats stats;

std::mutex mismatch_lock;
std::vector<std::string> mismatch_examples;
const size_t kMaxExamples = 50;

FileState file_state(const uint8_t* file) {
	FileState state;
	std::memcpy(&state.pos, file + layout.memory_pos, 4);
	std::memcpy(&state.line, file + layout.file_line, 4);
	state.last = file[layout.file_last];
	state.unget = file[layout.file_unget];
	return state;
}

const char* memory_buffer(const uint8_t* file) {
	const uint8_t* holder = *reinterpret_cast<const uint8_t* const*>(file + layout.memory_holder);
	if (holder != nullptr) {
		return *reinterpret_cast<const char* const*>(holder + layout.memory_holder_data);
	}
	return *reinterpret_cast<const char* const*>(file + layout.memory_buffer);
}

int32_t memory_size(uint8_t* file) {
	using get_size_function = int32_t (*)(void*);
	const get_size_function* vtable = *reinterpret_cast<const get_size_function* const*>(file);
	return vtable[layout.memory_get_size](file);
}

// The name of the file (an MSVC std::string: inline below 16 characters)
std::string file_name(const uint8_t* file) {
	const uint8_t* s = file + layout.file_name;
	uint64_t size = 0, capacity = 0;
	std::memcpy(&size, s + 16, 8);
	std::memcpy(&capacity, s + 24, 8);
	if (size > 4096 || capacity < size) {
		return "?";
	}
	const char* data = capacity >= 16 ? *reinterpret_cast<const char* const*>(s) : reinterpret_cast<const char*>(s);
	return data != nullptr ? std::string(data, static_cast<size_t>(size)) : std::string("?");
}

// The type GetTok gives a word (`length` bytes at text): its id in the token table, unless it is
// not there or is 12
int32_t word_type(const char* text, size_t length, int32_t fallback) {
	++stats.lookups;
	char small[256];
	std::string large;
	const char* name = small;
	if (length < sizeof(small)) {
		std::memcpy(small, text, length);
		small[length] = '\0';
	} else {
		large.assign(text, length);
		name = large.c_str();
	}
	void* tree = layout.token_tree();
	using find_function = const int32_t* (*)(void* tree, const char* name);
	const find_function find = (*reinterpret_cast<const find_function* const*>(tree))[2];
	const int32_t* entry = find(tree, name);
	return entry != nullptr && *entry != 12 ? *entry : fallback;
}

// The text of a Lua token (size - 1 bytes): in the file's text, or in the escaped strings
const char* token_text(const Stream& s, const LuaToken& t) {
	return t.text >= 0 ? s.buffer + t.text : s.escaped.data() + (-1 - static_cast<int64_t>(t.text));
}

// Asks Lua for the tokens of the text from `from`: the worker state of this thread
// (lua/worker.lua), so the threads that read script do not wait for each other.
bool load_tokens(Stream& s, const FileState& from) {
	s.tokens.clear();
	s.escaped.clear();
	s.next = 0;
	++stats.lua_calls;
	LARGE_INTEGER t0, t1, frequency;
	QueryPerformanceCounter(&t0);
	bool ok = false;
	{
		lua_State* L = stellar_worker_state();
		if (L != nullptr) {
			const int top = lua_gettop(L);
			lua_getglobal(L, "package");
			lua_getfield(L, -1, "loaded");
			lua_getfield(L, -1, "stellar");
			if (lua_istable(L, -1)) {
				lua_getfield(L, -1, "lexer_tokens");
				if (lua_isfunction(L, -1)) {
					lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(s.buffer)));
					lua_pushnumber(L, s.size);
					lua_pushnumber(L, from.pos);
					lua_pushnumber(L, from.last);
					lua_pushboolean(L, from.unget != 0);
					lua_pushnumber(L, from.line);
					if (stellar_lua_call(L, 6, 2)) {
						size_t records_size = 0, escaped_size = 0;
						const char* records = lua_type(L, -2) == LUA_TSTRING ? lua_tolstring(L, -2, &records_size) : nullptr;
						const char* escaped = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &escaped_size) : nullptr;
						if (records != nullptr && escaped != nullptr && records_size % sizeof(LuaToken) == 0) {
							s.tokens.resize(records_size / sizeof(LuaToken));
							if (records_size > 0) {
								std::memcpy(s.tokens.data(), records, records_size);
							}
							s.escaped.assign(escaped, escaped_size);
							ok = true;
						}
					}
				}
			}
			lua_settop(L, top);
		}
	}
	QueryPerformanceCounter(&t1);
	QueryPerformanceFrequency(&frequency);
	stats.lua_microseconds += static_cast<uint64_t>((t1.QuadPart - t0.QuadPart) * 1000000 / frequency.QuadPart);
	if (ok) {
		stats.lua_bytes += static_cast<uint64_t>(s.size - from.pos);
	} else {
		++stats.lua_failures;
	}
	// the text of a token GetTok writes has to be in the file's text or in the escaped strings
	for (const LuaToken& t : s.tokens) {
		if (!t.filled) {
			continue;
		}
		const int64_t length = static_cast<int64_t>(t.size) - 1;
		const bool inside = t.size >= 1 && (t.text >= 0
			? static_cast<int64_t>(t.text) + length <= s.size
			: -1 - static_cast<int64_t>(t.text) + length <= static_cast<int64_t>(s.escaped.size()));
		if (!inside) {
			s.tokens.clear();
			++stats.lua_failures;
			return false;
		}
	}
	return ok;
}

// Lua's token for the GetTok that starts with the file in state `before` (and its text in
// *stream), or null
const LuaToken* next_lua_token(uint8_t* file, const FileState& before, const Stream** stream) {
	if (streams == nullptr) {
		streams = new Streams();
	}
	const char* buffer = memory_buffer(file);
	const int32_t size = memory_size(file);
	int slot = -1, oldest = 0;
	for (int i = 0; i < Streams::kCount; ++i) {
		const Stream& candidate = streams->slots[i];
		if (candidate.file == file && candidate.buffer == buffer && candidate.size == size) {
			slot = i;
			break;
		}
		if (streams->used[i] < streams->used[oldest]) {
			oldest = i;
		}
	}
	const bool same_text = slot >= 0;
	if (!same_text) {
		slot = oldest;
	}
	streams->used[slot] = ++streams->clock;
	Stream& s = streams->slots[slot];
	*stream = &s;
	if (!same_text || s.next >= s.tokens.size() || before != s.expected) {
		if (same_text) {
			++stats.resyncs;
		} else {
			++stats.texts;
			stats.text_bytes += static_cast<uint64_t>(size > 0 ? size : 0);
			if (before.pos != 0) {
				++stats.texts_not_at_start;
			}
		}
		s.file = file;
		s.buffer = buffer;
		s.size = size;
		if (buffer == nullptr || size < 0 || before.pos < 0 || !load_tokens(s, before) || s.tokens.empty()) {
			s.tokens.clear();
			s.expected = FileState{-1, -1, 0, 0};
			return nullptr;
		}
	}
	const LuaToken& t = s.tokens[s.next++];
	s.expected = FileState{t.pos, t.line, t.last, t.unget};
	return &t;
}

std::string quoted(const char* text, size_t size) {
	std::string out = "'";
	for (size_t i = 0; i < size && i < 60; ++i) {
		const unsigned char c = static_cast<unsigned char>(text[i]);
		if (c >= 32 && c < 127 && c != '\'' && c != '\\') {
			out += static_cast<char>(c);
		} else {
			char escaped[8];
			std::snprintf(escaped, sizeof(escaped), "\\x%02x", c);
			out += escaped;
		}
	}
	return out + (size > 60 ? "'..." : "'");
}

void compare(const uint8_t* lexer, const uint8_t* file, const FileState& before, int rc, const LuaToken& t,
	const Stream& s) {
	++stats.compared;
	const FileState after = file_state(file);
	int32_t type = 0, size = 0;
	std::memcpy(&type, lexer + layout.token_type, 4);
	std::memcpy(&size, lexer + layout.token_size, 4);
	const bool explicit_string = lexer[layout.token_explicit] != 0;
	const char* text = *reinterpret_cast<const char* const*>(lexer + layout.token_text);
	const char* expected_text = t.filled ? token_text(s, t) : "";
	bool same = rc == t.rc && after == FileState{t.pos, t.line, t.last, t.unget};
	int32_t expected_type = t.type;
	if (same && t.filled) {
		if (expected_type < 0) {
			expected_type = word_type(expected_text, static_cast<size_t>(t.size - 1), -expected_type);
		}
		same = type == expected_type && explicit_string == (t.explicit_string != 0) && size == t.size && text != nullptr
			&& std::memcmp(text, expected_text, static_cast<size_t>(std::max(size - 1, 0))) == 0;
	}
	if (same) {
		return;
	}
	if (++stats.mismatches > kMaxExamples) {
		return;
	}
	char line[1024];
	std::snprintf(line, sizeof(line),
		"%s line %d pos %d: game rc %d type %d%s %s size %d -> pos %d line %d last 0x%02x unget %d; "
		"lua rc %d type %d%s %s size %d -> pos %d line %d last 0x%02x unget %d",
		file_name(file).c_str(), before.line, before.pos,
		rc, type, explicit_string ? " quoted" : "",
		text != nullptr ? quoted(text, static_cast<size_t>(std::max(size - 1, 0))).c_str() : "(null)", size,
		after.pos, after.line, after.last, after.unget,
		t.rc, expected_type, t.explicit_string ? " quoted" : "",
		t.filled ? quoted(expected_text, static_cast<size_t>(t.size - 1)).c_str() : "(not filled)", t.size,
		t.pos, t.line, t.last, t.unget);
	std::lock_guard<std::mutex> guard(mismatch_lock);
	mismatch_examples.emplace_back(line);
}

// Replace mode: what GetTok writes, from Lua's token: _CurrTok (unless the call wrote nothing) and
// the file after it. Returns what GetTok returns.
int deliver(uint8_t* lexer, uint8_t* file, const LuaToken& t, const Stream& s) {
	if (t.filled) {
		const char* text = token_text(s, t);
		const size_t length = static_cast<size_t>(t.size - 1);
		const int32_t type = t.type < 0 ? word_type(text, length, -t.type) : t.type;
		int32_t capacity = 0;
		std::memcpy(&capacity, lexer + layout.token_capacity, 4);
		if (t.size > capacity) {
			// the game's own growth of _Val (it sets the size to index + 1)
			layout.set_char(lexer + layout.lexer_token, t.size - 1, '\0');
		}
		char* data = *reinterpret_cast<char* const*>(lexer + layout.token_text);
		std::memcpy(data, text, length);
		data[length] = '\0';
		std::memcpy(lexer + layout.token_size, &t.size, 4);
		std::memcpy(lexer + layout.token_type, &type, 4);
		lexer[layout.token_explicit] = t.explicit_string;
	}
	std::memcpy(file + layout.memory_pos, &t.pos, 4);
	std::memcpy(file + layout.file_line, &t.line, 4);
	file[layout.file_last] = t.last;
	file[layout.file_unget] = t.unget;
	++stats.replaced;
	return t.rc;
}

int get_tok_hook(void* lexer_pointer) {
	uint8_t* const lexer = static_cast<uint8_t*>(lexer_pointer);
	++stats.calls;
	if (lexer[layout.lexer_peek] != 0) {
		++stats.peeks;
		if (replace_mode) {
			// as GetTok: the peeked token again
			lexer[layout.lexer_peek] = 0;
			int32_t rc = 0;
			std::memcpy(&rc, lexer + layout.lexer_peek_rc, 4);
			return rc;
		}
		return original_get_tok(lexer_pointer);
	}
	uint8_t* const file = *reinterpret_cast<uint8_t* const*>(lexer + layout.lexer_file);
	if (file == nullptr || *reinterpret_cast<const uintptr_t*>(file) != layout.memory_file_vtable) {
		++stats.other_files;
		return original_get_tok(lexer_pointer);
	}
	const FileState before = file_state(file);
	const Stream* stream = nullptr;
	const LuaToken* expected = next_lua_token(file, before, &stream);
	if (replace_mode) {
		if (expected == nullptr) {
			// no tokens from Lua for this text: the game reads it
			++stats.without_lua;
			return original_get_tok(lexer_pointer);
		}
		return deliver(lexer, file, *expected, *stream);
	}
	const int rc = original_get_tok(lexer_pointer);
	if (expected != nullptr) {
		compare(lexer, file, before, rc, *expected, *stream);
	} else {
		++stats.without_lua;
	}
	return rc;
}

uintptr_t check_address(lua_State* L, int idx) {
	const lua_Number value = luaL_checknumber(L, idx);
	if (!(value > 0) || value >= 18446744073709551616.0 || value != static_cast<lua_Number>(static_cast<uint64_t>(value))) {
		luaL_argerror(L, idx, "address expected");
	}
	return static_cast<uintptr_t>(value);
}

// layout[name], a number: an offset (0 to 4095) or, for an address, any
bool layout_field(lua_State* L, const char* name, lua_Number* value) {
	lua_getfield(L, 2, name);
	const bool ok = lua_type(L, -1) == LUA_TNUMBER;
	*value = ok ? lua_tonumber(L, -1) : 0;
	lua_pop(L, 1);
	return ok;
}

// stellar.hook_lexer(get_tok, layout, mode) -> true | nil, message: hooks CTextLexer::GetTok.
// layout: the offsets above, by name, and the addresses memory_file_vtable, token_tree and (for
// replace mode) set_char. mode: "shadow" (the default: compare) or "replace" (Lua's tokens).
int l_hook_lexer(lua_State* L) {
	void* target = reinterpret_cast<void*>(check_address(L, 1));
	luaL_checktype(L, 2, LUA_TTABLE);
	const char* mode = luaL_optstring(L, 3, "shadow");
	const bool replace = std::strcmp(mode, "replace") == 0;
	if (!replace && std::strcmp(mode, "shadow") != 0) {
		return luaL_argerror(L, 3, "\"shadow\" or \"replace\" expected");
	}
	if (original_get_tok != nullptr) {
		lua_pushnil(L);
		lua_pushliteral(L, "the lexer is hooked already");
		return 2;
	}
	struct Offset {
		const char* name;
		int* field;
	};
	const Offset offsets[] = {
		{"lexer_file", &layout.lexer_file}, {"lexer_peek", &layout.lexer_peek},
		{"lexer_peek_rc", &layout.lexer_peek_rc}, {"lexer_token", &layout.lexer_token},
		{"token_type", &layout.token_type}, {"token_explicit", &layout.token_explicit},
		{"token_text", &layout.token_text}, {"token_capacity", &layout.token_capacity},
		{"token_size", &layout.token_size},
		{"file_line", &layout.file_line}, {"file_last", &layout.file_last},
		{"file_unget", &layout.file_unget}, {"file_name", &layout.file_name},
		{"memory_holder", &layout.memory_holder}, {"memory_holder_data", &layout.memory_holder_data},
		{"memory_buffer", &layout.memory_buffer}, {"memory_pos", &layout.memory_pos},
		{"memory_get_size", &layout.memory_get_size},
	};
	for (const Offset& o : offsets) {
		lua_Number value = 0;
		if (!layout_field(L, o.name, &value) || value < 0 || value > 4095 || value != static_cast<int>(value)) {
			lua_pushnil(L);
			lua_pushfstring(L, "layout.%s: an offset expected", o.name);
			return 2;
		}
		*o.field = static_cast<int>(value);
	}
	lua_Number vtable = 0, tree = 0;
	if (!layout_field(L, "memory_file_vtable", &vtable) || !(vtable > 0) || !layout_field(L, "token_tree", &tree) || !(tree > 0)) {
		lua_pushnil(L);
		lua_pushliteral(L, "layout: memory_file_vtable and token_tree expected");
		return 2;
	}
	layout.memory_file_vtable = static_cast<uintptr_t>(vtable);
	layout.token_tree = reinterpret_cast<void* (*)()>(static_cast<uintptr_t>(tree));
	lua_Number set_char = 0;
	if (replace && (!layout_field(L, "set_char", &set_char) || !(set_char > 0))) {
		lua_pushnil(L);
		lua_pushliteral(L, "layout: set_char (CToken::SetCharInString) expected for replace mode");
		return 2;
	}
	layout.set_char = reinterpret_cast<void (*)(void*, int, char)>(static_cast<uintptr_t>(set_char));
	replace_mode = replace;
	const char* error = nullptr;
	if (!install_code_hook(target, reinterpret_cast<void*>(&get_tok_hook), reinterpret_cast<void**>(&original_get_tok), &error)) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

// stellar.lexer_stats() -> a table of counts (see Stats)
int l_lexer_stats(lua_State* L) {
	lua_newtable(L);
	const struct {
		const char* name;
		const std::atomic<uint64_t>* value;
	} fields[] = {
		{"calls", &stats.calls}, {"peeks", &stats.peeks}, {"other_files", &stats.other_files},
		{"texts", &stats.texts}, {"texts_not_at_start", &stats.texts_not_at_start}, {"resyncs", &stats.resyncs},
		{"lua_calls", &stats.lua_calls}, {"lua_failures", &stats.lua_failures},
		{"lua_microseconds", &stats.lua_microseconds}, {"lua_bytes", &stats.lua_bytes},
		{"compared", &stats.compared}, {"lookups", &stats.lookups}, {"mismatches", &stats.mismatches},
		{"without_lua", &stats.without_lua}, {"replaced", &stats.replaced},
	};
	for (const auto& f : fields) {
		lua_pushnumber(L, static_cast<lua_Number>(f.value->load()));
		lua_setfield(L, -2, f.name);
	}
	lua_pushboolean(L, original_get_tok != nullptr);
	lua_setfield(L, -2, "hooked");
	lua_pushstring(L, replace_mode ? "replace" : "shadow");
	lua_setfield(L, -2, "mode");
	return 1;
}

// stellar.lexer_mismatches() -> the first mismatches, as text
int l_lexer_mismatches(lua_State* L) {
	std::vector<std::string> copy;
	{
		std::lock_guard<std::mutex> guard(mismatch_lock);
		copy = mismatch_examples;
	}
	lua_createtable(L, static_cast<int>(copy.size()), 0);
	for (size_t i = 0; i < copy.size(); ++i) {
		lua_pushlstring(L, copy[i].data(), copy[i].size());
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

} // namespace

int64_t stellar_lexer_file_size(void* lexer_pointer) {
	if (layout.memory_file_vtable == 0 || lexer_pointer == nullptr) {
		return -1;
	}
	uint8_t* const file = *reinterpret_cast<uint8_t* const*>(static_cast<uint8_t*>(lexer_pointer) + layout.lexer_file);
	if (file == nullptr || *reinterpret_cast<const uintptr_t*>(file) != layout.memory_file_vtable) {
		return -1;
	}
	return memory_size(file);
}

void stellar_lexer_counts(uint64_t* texts, uint64_t* tokens, uint64_t* bytes) {
	*texts = stats.texts.load();
	*tokens = stats.compared.load() + stats.replaced.load();
	*bytes = stats.text_bytes.load();
}

void stellar_lexer_open(lua_State* L) {
	lua_pushcfunction(L, l_hook_lexer);
	lua_setfield(L, -2, "hook_lexer");
	lua_pushcfunction(L, l_lexer_stats);
	lua_setfield(L, -2, "lexer_stats");
	lua_pushcfunction(L, l_lexer_mismatches);
	lua_setfield(L, -2, "lexer_mismatches");
}
