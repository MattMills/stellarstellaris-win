#pragma once

#include <cstdint>

struct lua_State;

// Adds the lexer hook's functions to the `stellar` table on the top of the stack:
// hook_lexer(get_tok, layout, mode), lexer_stats(), lexer_mismatches(). See src/dll/lexer_hook.cpp.
void stellar_lexer_open(lua_State* L);

// The lexer hook's counts so far: texts started, tokens (compared or given by Lua), bytes of the
// texts started
void stellar_lexer_counts(uint64_t* texts, uint64_t* tokens, uint64_t* bytes);
