#pragma once

struct lua_State;

// Adds the lexer hook's functions to the `stellar` table on the top of the stack:
// hook_lexer(get_tok, layout), lexer_stats(), lexer_mismatches(). See src/dll/lexer_hook.cpp.
void stellar_lexer_open(lua_State* L);
