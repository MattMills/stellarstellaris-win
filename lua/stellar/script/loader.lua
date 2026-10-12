-- loader.lua : the game's script text, read by Lua instead of the game's lexer.
--
-- The game reads every script text (files, inline scripts, the rewritten text of scripted triggers,
-- effects and values) with a CTextLexer over a CMemoryFile: its virtual GetTok gives the next
-- token to the C++ reader that builds the objects. This module locates GetTok and what the hook
-- needs in this build; the hook (src/dll/lexer_hook.cpp) asks Lua for the tokens of each text once
-- (loader.tokens, stellar.script.lexer), then compares them with the game's (shadow mode) or gives
-- them to the game instead (replace mode). See docs/text_lexer.md.
--
--   local loader = require("stellar.script.loader")
--   local where = assert(loader.locate(image, stellar.read))
--   assert(loader.hook(where))       -- shadow mode; loader.report() logs what it found

local ffi = require("ffi")
local resolve = require("stellar.resolve")
local code = require("stellar.code")
local lexer = require("stellar.script.lexer")

local loader = {}

-- loader.locate(image, read) -> where | nil, message:
--   get_tok             CTextLexer::GetTok
--   memory_file_vtable  the vtable of CMemoryFile. A constructor stores its bases' vtables in the
--                       object first and its own last: the last `lea r64, [rip+x]` followed by
--                       `mov [reg], r64` in CMemoryFile::CMemoryFile.
--   token_tree          the function GetTok calls for the static lexer's token tree, whose
--                       vtable's slot 2 finds a word: `call x; mov rcx, [rax]; mov r8, [rcx+16]`
function loader.locate(image, read)
    local found = resolve.functions(image)
    local get_tok, ctor = found["CTextLexer::GetTok"], found["CMemoryFile::CMemoryFile"]
    if not get_tok then
        return nil, "CTextLexer::GetTok not found"
    end
    if not ctor then
        return nil, "CMemoryFile::CMemoryFile not found"
    end
    local patterns = code.bundle(read, image)
    local stores = patterns:register({ name = "vtable stores in CMemoryFile::CMemoryFile", in_function = ctor,
        signature = "48 8d [00...101] ?? ?? ?? ?? [0100100.] 89 [00......]", count = false })
    local tree = patterns:register({ name = "the token tree in CTextLexer::GetTok", in_function = get_tok,
        signature = "e8 ?? ?? ?? ?? [01001.0.] 8b [00......] [01001.0.] 8b [01......] 10", count = false })
    local report = patterns:run()
    if not report.ok then
        return nil, "sigmatch: " .. tostring(report.error)
    end
    local last, first_tree
    for _, at in ipairs(stores.matches or {}) do
        if last == nil or at > last then
            last = at
        end
    end
    for _, at in ipairs(tree.matches or {}) do
        if first_tree == nil or at < first_tree then
            first_tree = at
        end
    end
    if last == nil then
        return nil, "no vtable stored by CMemoryFile::CMemoryFile"
    end
    if first_tree == nil then
        return nil, "no token tree call in CTextLexer::GetTok"
    end
    return { get_tok = get_tok, memory_file_vtable = code.relative(read, last + 3, last + 7),
        token_tree = code.relative(read, first_tree + 1, first_tree + 5),
        set_char = found["CToken::SetCharInString"] }
end

-- The structures the hook reads (4.5.2, from its PDB; docs/text_lexer.md)
loader.layout = {
    lexer_file = 0x8,          -- CLexer::_File
    lexer_peek = 0x13c,        -- CLexer::_bPeek
    lexer_peek_rc = 0x10,      -- CLexer::_PeekRC
    lexer_token = 0x18,        -- CLexer::_CurrTok, a CToken
    token_type = 0x18,         -- CLexer::_CurrTok._LexerToken
    token_explicit = 0x1c,     -- _CurrTok._bExplicitString
    token_text = 0x28,         -- _CurrTok._Val: the data
    token_capacity = 0x30,     -- _CurrTok._Val: the capacity
    token_size = 0x34,         -- _CurrTok._Val: the size, NUL included
    file_line = 0x8,           -- CFile::_LineNumber
    file_last = 0x10,          -- CFile::_szLastChar
    file_unget = 0x11,         -- CFile::_bUnget
    file_name = 0x30,          -- the file's name, a std::string
    memory_holder = 0x80,      -- CMemoryFile: a shared buffer (its data at +8), or null
    memory_holder_data = 0x8,
    memory_buffer = 0x88,      -- CMemoryFile::_pBuffer
    memory_pos = 0x94,         -- CMemoryFile::_nPos
    memory_get_size = 16,      -- the vtable slot of CMemoryFile::GetSize
}

-- loader.tokens(buffer, size, pos, last, unget, line) -> records, escaped | nil: the GetTok calls on
-- the text at buffer from that state of the file (lexer.records): a token's text is at its offset
-- in the buffer, or (a negative offset) in escaped. The hook calls it in each thread's worker state
-- (lua/worker.lua) as stellar.lexer_tokens.
loader.tokens = lexer.records

-- loader.hook(where, mode) -> true | nil, message: CTextLexer::GetTok hooked; mode "shadow" (the
-- game reads, Lua's tokens are compared with its) or "replace" (the game gets Lua's tokens)
function loader.hook(where, mode)
    local stellar = require("stellar")
    local layout = {}
    for k, v in pairs(loader.layout) do
        layout[k] = v
    end
    layout.memory_file_vtable, layout.token_tree, layout.set_char = where.memory_file_vtable, where.token_tree,
        where.set_char
    return stellar.hook_lexer(where.get_tok, layout, mode or "shadow")
end

local reported, logged = nil, 0

-- loader.report(force): logs the hook's counts when they changed (and the mismatches not logged
-- yet); with force, logs them anyway
function loader.report(force)
    local stellar = require("stellar")
    local s = stellar.lexer_stats()
    if not s.hooked then
        return
    end
    if not force and reported == s.calls then
        return
    end
    reported = s.calls
    stellar.log(string.format("loader (%s): %d GetTok calls (%d peeks, %d on other files), %d texts (%d not from the start), "
        .. "%d resyncs; Lua: %d calls (%d failed), %.2fs, %.1f MB; %d tokens from Lua, %d compared, %d mismatches, %d without Lua, %d words looked up",
        s.mode, s.calls, s.peeks, s.other_files, s.texts, s.texts_not_at_start, s.resyncs, s.lua_calls, s.lua_failures,
        s.lua_microseconds / 1e6, s.lua_bytes / 1e6, s.replaced, s.compared, s.mismatches, s.without_lua, s.lookups))
    local mismatches = stellar.lexer_mismatches()
    for i = logged + 1, #mismatches do
        stellar.log("loader:   " .. mismatches[i])
    end
    logged = #mismatches
end

return loader
