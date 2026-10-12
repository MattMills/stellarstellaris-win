-- lexer.lua : CTextLexer::GetTok, the game's script tokenizer (4.5.2), in Lua: for any text, the
-- tokens the game reads, with the same ids, text, quoted flag and line counter, and the same state
-- of the file behind them (docs/text_lexer.md).
--
--   local lexer = require("stellar.script.lexer")
--   local toks = lexer.tokens(text, lookup)       -- every token GetTok gives, in order
--   toks[i] = { type = id, text = "...", quoted = true or nil, line = n, size = n, at = i }
--   lookup(word) -> id or nil: the static lexer (CStaticLexer), asked with the word in lower case
--
--   local lex = lexer.new(text, lookup)           -- a CTextLexer reading a CMemoryFile of text
--   while lex:next() == 1 do print(lex.type, lex.text, lex.line) end
--   local expression = lex:read_until("]")        -- CTextLexer::ReadUntilCharacter
--
-- text is what the CMemoryFile holds: the file's bytes, a BOM included (only CNameListDatabase has
-- it removed, see lexer.strip_bom). A token's line is the file's line counter after GetTok returned
-- it, which is what the readers report: the line of the last byte GetTok read.

local byte, char, sub, find, lower = string.byte, string.char, string.sub, string.find, string.lower
local concat = table.concat

local lexer = {}

-- Token ids (_CurrTok._LexerToken). Bytes and operators have fixed ids; a word gets the id of the
-- static lexer's token of that name, or NUMBER or STRING.
lexer.EQUALS = 1        -- =
lexer.QUOTE = 2         -- only while GetTok reads a quoted string, which ends as STRING
lexer.OPEN = 3          -- {
lexer.CLOSE = 4         -- }
lexer.LPAREN = 5        -- (
lexer.RPAREN = 6        -- )
lexer.COMMA = 8         -- ,
lexer.COMMENT = 9       -- # or ; to the end of the line (skipped, never returned)
lexer.NUMBER = 12       -- a word of digits, '.' and '-', or any word starting with a digit or '-'
lexer.STRING = 15       -- a quoted string, or a word the static lexer does not know
lexer.EOF = 19          -- set by CLexer::Peek and the readers when GetTok returns 0
lexer.GREATER = 467     -- > (greater_than)
lexer.LESS = 468        -- < (less_than)
lexer.GREATER_EQ = 971  -- >= (greater_eq_than)
lexer.LESS_EQ = 972     -- <= (less_eq_than)
lexer.NOT = 1062        -- ! (not, also the id of the word NOT)
lexer.NOT_EQ = 1063     -- != (not_eq)

-- GetTok's first switch: the bytes that are a token of their own (they also end a word). Every
-- other byte, control bytes, bytes >= 0x80 and NUL included, is part of a word.
local SINGLE, SPACE, STOP, CHAR = {}, {}, {}, {}
for b = 0, 255 do
    SINGLE[b], SPACE[b], CHAR[b] = false, false, char(b)
end
for b, id in pairs({ [33] = 1062, [34] = 2, [35] = 9, [40] = 5, [41] = 6, [44] = 8, [59] = 9,
    [60] = 468, [61] = 1, [62] = 467, [123] = 3, [125] = 4 }) do
    SINGLE[b] = id
end
-- iswspace of the byte as a signed char: HT, LF, VT, FF, CR and space (a byte >= 0x80 becomes
-- U+FF80..U+FFFF, none of them a space)
for _, b in ipairs({ 9, 10, 11, 12, 13, 32 }) do
    SPACE[b] = true
end
for b = 0, 255 do
    STOP[b] = SPACE[b] or SINGLE[b] ~= false
end
-- CheckComparisons (inlined): < > ! followed by =
local WITH_EQUALS = { [467] = 971, [468] = 972, [1062] = 1063 }

-- The file while GetTok runs (CMemoryFile: _nPos, CFile: _szLastChar, _bUnget, _LineNumber).
-- Upvalues for speed: Lexer:next and Lexer:read_until load them from the lexer and store them back.
local src, size, pos, last, ungot, line

-- CMemoryFile::Get (0x1b44430): count the line of the byte read before, then give back the byte
-- UnGet left, or the next one (255 past the end, where _nPos still advances). Valid (IsValid)
-- while pos <= size: the byte it gave was in the file.
local function get()
    if last == 10 then
        line = line + 1
    end
    if ungot then
        ungot = false
        return last
    end
    local c = 255
    if pos < size then
        c = byte(src, pos + 1)
    end
    last = c
    pos = pos + 1
    return c
end

-- CFile::UnGet (inlined): the next Get gives the last byte again, and counts its line again, so a
-- line feed put back lowers the line until then.
local function unget()
    ungot = true
    if last == 10 then
        line = line - 1
    end
end

local cuts = {}

-- CTextLexer::GetTok (0x1bb1220) on the file in the upvalues, without the peek and the lookup:
-- returns 1 (a token) or 0 (the end of the file), and whether it wrote a word (to classify).
local function gettok(self)
    while true do
        -- blanks
        local c = get()
        if pos <= size then
            while SPACE[c] do
                c = get()
                if pos > size then
                    break
                end
            end
        end
        if pos > size and c == 255 then
            return 0, false
        end
        local at = pos
        local id = SINGLE[c]
        self.at, self.quoted = at, false
        if not id then
            -- a word, to a blank (read) or a byte of SINGLE (put back), or the end of the file
            c = get()
            if pos <= size then
                while not STOP[c] do
                    c = get()
                    if pos > size then
                        break
                    end
                end
            end
            if SINGLE[c] then
                unget()
            end
            self.text, self.size = sub(src, at, pos - 1), pos - at + 1
            if c == 255 then
                return 0, true  -- the word is in _CurrTok, but GetTok says the file ended
            end
            return 1, true
        elseif id == 9 then
            -- a comment: to a line feed (read), then the next token
            self.type, self.text, self.size = 9, CHAR[c], 2
            c = get()
            if pos <= size then
                while c ~= 10 do
                    c = get()
                    if pos > size then
                        break
                    end
                end
            end
        elseif id == 2 then
            -- a quoted string, to the next quote not escaped: \" and \\ lose their backslash, any
            -- other backslash stays (the game logs a warning)
            local prev, ncut = 0, 0
            c = get()
            if pos <= size then
                while true do
                    if c == 34 and prev ~= 92 then
                        break
                    end
                    if prev == 92 and (c == 34 or c == 92) then
                        ncut = ncut + 1
                        cuts[ncut] = pos - 1
                        prev = 0
                    else
                        if prev == 92 then
                            self.warnings[#self.warnings + 1] = line
                        end
                        prev = c
                    end
                    c = get()
                    if pos > size then
                        break
                    end
                end
            end
            local text
            if ncut == 0 then
                text = sub(src, at + 1, pos - 1)
            else
                local parts, from = {}, at + 1
                for i = 1, ncut do
                    parts[i] = sub(src, from, cuts[i] - 1)
                    from = cuts[i] + 1
                end
                parts[ncut + 1] = sub(src, from, pos - 1)
                text = concat(parts)
            end
            self.type, self.text, self.quoted = 15, text, true
            self.size = #text + 1 < 2 and 2 or #text + 1
            return 1, false
        elseif WITH_EQUALS[id] then
            if get() == 61 then
                self.type, self.text, self.size = WITH_EQUALS[id], CHAR[c] .. "=", 3
            else
                unget()
                self.type, self.text, self.size = id, CHAR[c], 2
            end
            return 1, false
        else
            self.type, self.text, self.size = id, CHAR[c], 2
            return 1, false
        end
    end
end

-- The id of a word (the end of GetTok): NUMBER if it starts with a digit or '-', else the static
-- lexer's token (unless that is 12), else NUMBER if it has only digits, '.' and '-', else STRING.
-- Returns the id, or nil, the key to look up (the word in lower case: CTernary::Get compares the
-- tolower of each byte) and the id when the static lexer has no token for it. The game reads the
-- word as a C string: a NUL ends it.
local function word_class(text)
    local word = text
    if find(text, "\0", 1, true) then
        word = sub(text, 1, find(text, "\0", 1, true) - 1)
    end
    local c = byte(word, 1)
    if c and (c >= 48 and c <= 57 or c == 45) then
        return 12
    end
    return nil, lower(word), find(word, "^[%d%.%-]*$") and 12 or 15
end

local Lexer = {}
Lexer.__index = Lexer

-- lexer.new(text, lookup) -> lex: a CTextLexer over a CMemoryFile of text, as CLexer::CLexer makes
-- them: line 1, nothing read, _CurrTok an empty token of id 0.
--   lex.type, lex.text, lex.quoted, lex.size  _CurrTok: _LexerToken, the bytes of _Val before its
--                                             NUL, _bExplicitString, the size of _Val (NUL included)
--   lex.line, lex.last, lex.ungot, lex.pos    CFile::_LineNumber, _szLastChar (0..255),
--                                             _bUnget, CMemoryFile::_nPos
--   lex.peeked, lex.peek_rc                   CLexer::_bPeek, _PeekRC
--   lex.at                                    where the token starts in text (its first byte)
--   lex.key, lex.fallback                     for a word the static lexer was asked about: the
--                                             key (lower case) and the id it gets if the static
--                                             lexer has no token of that name (12 or 15)
--   lex.end_word                              the last next() returned 0 after a word, which is in
--                                             _CurrTok: a file ending in a word without a blank
--   lex.warnings                              the line of each backslash GetTok warned about
function lexer.new(text, lookup)
    return setmetatable({ src = text, length = #text, lookup = lookup,
        type = 0, text = "", quoted = false, size = 1, at = 0,
        line = 1, last = 0, ungot = false, pos = 0,
        peeked = false, peek_rc = 0, end_word = false, warnings = {} }, Lexer)
end

-- lex:next() -> 1 or 0: GetTok. While a peek is pending it only returns its result.
function Lexer:next()
    if self.peeked then
        self.peeked = false
        return self.peek_rc
    end
    src, size, pos, last, ungot, line = self.src, self.length, self.pos, self.last, self.ungot,
        self.line
    local rc, word = gettok(self)
    self.pos, self.last, self.ungot, self.line = pos, last, ungot, line
    src = nil
    self.key, self.fallback = nil, nil
    if word then
        local id, key, fallback = word_class(self.text)
        if id == nil then
            local found = self.lookup and self.lookup(key)
            id = found and found ~= 12 and found or fallback
            self.key, self.fallback = key, fallback
        end
        self.type = id
    end
    self.end_word = rc == 0 and word
    return rc
end

-- lex:peek() -> id: CLexer::Peek (inlined in the readers): GetTok once, keeping its result for the
-- next GetTok; the id of the token, EOF (19) at the end.
function Lexer:peek()
    if not self.peeked then
        self.peek_rc = self:next()
        if self.peek_rc == 0 then
            self.type = 19
        end
        self.peeked = true
    end
    return self.type
end

-- lex:read_until(byte or char) -> text: CTextLexer::ReadUntilCharacter (0x1bb18e0): the raw bytes
-- up to that byte, which is read and left out. The game reads on forever past the end of the file;
-- here that returns nil, "end of file" (the file state is then past its end).
function Lexer:read_until(stop)
    if type(stop) == "string" then
        stop = byte(stop)
    end
    src, size, pos, last, ungot, line = self.src, self.length, self.pos, self.last, self.ungot,
        self.line
    local c = get()
    local from, text = pos, nil
    while c ~= stop do
        if pos > size and c == 255 then
            break
        end
        c = get()
    end
    if c == stop then
        text = sub(src, from, pos - 1)
    end
    self.pos, self.last, self.ungot, self.line = pos, last, ungot, line
    src = nil
    if text == nil then
        return nil, "end of file"
    end
    return text
end

-- Whether CReader::ParseAdvancedStatementWithVariables reads the rest of this token's inline math
-- with ReadUntilCharacter(']'): an unquoted token "@[..." whose text does not end in ']'.
function lexer.reads_math(text, quoted)
    return not quoted and sub(text, 1, 2) == "@[" and sub(text, -1) ~= "]"
end

-- lexer.tokens(text, lookup [, read_math]) -> toks: every token GetTok returns for text, until it
-- returns 0. toks.line is the line counter at the end, toks.dropped the word GetTok left in
-- _CurrTok while returning 0 (a file ending in a word: the readers never see it). With read_math,
-- the inline math the readers read with ReadUntilCharacter (lexer.reads_math) is read the same way
-- after its token, into the token's math (and math_line, the line counter after it), so that the
-- tokens are those the game's GetTok calls get.
function lexer.tokens(text, lookup, read_math)
    local lex = lexer.new(text, lookup)
    local toks, n = {}, 0
    while lex:next() == 1 do
        n = n + 1
        local tok = { type = lex.type, text = lex.text, quoted = lex.quoted or nil, line = lex.line,
            size = lex.size, at = lex.at }
        toks[n] = tok
        if read_math and lexer.reads_math(lex.text, lex.quoted) then
            local math, message = lex:read_until(93)
            if math == nil then
                toks.error = "line " .. lex.line .. ": inline math without ']': " .. message
                break
            end
            tok.math, tok.math_line = math, lex.line
        end
    end
    toks.line, toks.warnings = lex.line, lex.warnings
    if lex.end_word then
        toks.dropped = { type = lex.type, text = lex.text, line = lex.line, size = lex.size,
            at = lex.at }
    end
    return toks
end

-- lexer.at(text, start, lookup) -> lex: a lexer reading text from a file state: start is a
-- CMemoryFile::_nPos (the bytes before it read, nothing put back, the line counted from them) or
-- { pos = n, last = byte, ungot = bool, line = n } as read from the game's CFile.
function lexer.at(text, start, lookup)
    local lex = lexer.new(text, lookup)
    if type(start) == "table" then
        lex.pos, lex.last, lex.ungot, lex.line = start.pos, start.last, start.ungot, start.line
    elseif start and start > 0 then
        local lines, i = 1, 0
        while true do
            i = find(text, "\n", i + 1, true)
            if i == nil or i >= start then
                break
            end
            lines = lines + 1
        end
        lex.pos, lex.last, lex.line = start, byte(text, start) or 255, lines
    end
    return lex
end

-- lexer.tokenize(text [, start [, lookup [, read_math]]]) -> calls: every GetTok call from start
-- (see lexer.at) to the first that returns 0, which is the last entry, each with what the harness
-- compares: { rc, type, quoted, text, size, line, pos, last, ungot, at }, _CurrTok and the file
-- after the call (for rc 0 _CurrTok is what the call left: the previous token, the comment byte or
-- the dropped word). Without lookup a word the static lexer decides has type nil, key (the word in
-- lower case) and fallback: its id is lookup(key) unless that is nil or 12, else fallback.
-- read_math as in lexer.tokens (math, and the file after it in math_pos, math_last, math_ungot,
-- math_line).
function lexer.tokenize(text, start, lookup, read_math)
    local lex = lexer.at(text, start, lookup)
    local calls, n = {}, 0
    repeat
        local rc = lex:next()
        local call = { rc = rc, type = lex.type, quoted = lex.quoted, text = lex.text,
            size = lex.size, line = lex.line, pos = lex.pos, last = lex.last, ungot = lex.ungot,
            at = lex.at }
        if lex.key and not lookup then
            call.type, call.key, call.fallback = nil, lex.key, lex.fallback
        end
        n = n + 1
        calls[n] = call
        if rc == 1 and read_math and lexer.reads_math(lex.text, lex.quoted) then
            local math, message = lex:read_until(93)
            if math == nil then
                calls.error = "line " .. lex.line .. ": inline math without ']': " .. message
                break
            end
            call.math, call.math_pos, call.math_last = math, lex.pos, lex.last
            call.math_ungot, call.math_line = lex.ungot, lex.line
        end
    until rc == 0
    calls.warnings = lex.warnings
    return calls
end

-- lexer.scan: GetTok as above, fast, for the lexer hook (lua/stellar/script/loader.lua,
-- src/dll/lexer_hook.cpp): it reads the text in place through a pointer and writes each GetTok call
-- into a C array, without a Lua string or table per token.
--
-- lexer.scan(data, size, pos, last, ungot, line) -> records, n, escaped: the GetTok calls from that
-- state of the file to the first that returns 0, records[0 .. n-1] (stellar_lexer_token, valid
-- until the next call). A token's text is where it is in data (text = its offset) except a quoted
-- string with escapes: its text is in `escaped` (a Lua string), at -1 - text. A word the static
-- lexer decides has type -12 or -15: its id there, unless it has none (or 12), else 12 or 15.

local ffi = require("ffi")
ffi.cdef([[
typedef struct stellar_lexer_token {
    int32_t rc, type, text, size, pos, line;
    uint8_t filled, explicit_string, last, unget;
} stellar_lexer_token;
]])
lexer.TOKEN_SIZE = ffi.sizeof("stellar_lexer_token")

local IS_SPACE, IS_STOP, SINGLE_ID, WITH_EQ, NUMERIC = ffi.new("uint8_t[256]"), ffi.new("uint8_t[256]"),
    ffi.new("int32_t[256]"), ffi.new("int32_t[2048]"), ffi.new("uint8_t[256]")
for b = 0, 255 do
    IS_SPACE[b] = SPACE[b] and 1 or 0
    IS_STOP[b] = STOP[b] and 1 or 0
    SINGLE_ID[b] = SINGLE[b] or 0
    NUMERIC[b] = ((b >= 48 and b <= 57) or b == 45 or b == 46) and 1 or 0
end
for id, combined in pairs(WITH_EQUALS) do
    WITH_EQ[id] = combined
end

local records, capacity = nil, 0
local fp, fsize, fpos, flast, fungot, fline  -- the file while scan runs

local function fget()
    if flast == 10 then
        fline = fline + 1
    end
    if fungot then
        fungot = false
        return flast
    end
    local c = 255
    if fpos < fsize then
        c = fp[fpos]
    end
    flast = c
    fpos = fpos + 1
    return c
end

local function funget()
    fungot = true
    if flast == 10 then
        fline = fline - 1
    end
end

function lexer.scan(data, size, pos, last, ungot, line)
    fp, fsize, fpos, flast, fungot, fline = ffi.cast("const uint8_t *", data), size, pos, last, ungot and true or false, line
    local n, escaped, escaped_size = 0, {}, 0
    while true do
        if n >= capacity then
            local new_capacity = math.max(4096, capacity * 2)
            local new = ffi.new("stellar_lexer_token[?]", new_capacity)
            if capacity > 0 then
                ffi.copy(new, records, capacity * lexer.TOKEN_SIZE)
            end
            records, capacity = new, new_capacity
        end
        local rc, filled, typ, text, tsize, quoted = 1, 0, 0, 0, 0, 0
        while true do
            -- blanks
            local c = fget()
            if fpos <= fsize then
                while IS_SPACE[c] == 1 do
                    c = fget()
                    if fpos > fsize then
                        break
                    end
                end
            end
            if fpos > fsize and c == 255 then
                rc = 0
                break
            end
            local at = fpos - 1  -- where c is in data
            local id = SINGLE_ID[c]
            filled = 1
            if id == 0 then
                -- a word, to a blank (read) or a byte of SINGLE (put back), or the end of the file
                c = fget()
                if fpos <= fsize then
                    while IS_STOP[c] == 0 do
                        c = fget()
                        if fpos > fsize then
                            break
                        end
                    end
                end
                if SINGLE_ID[c] ~= 0 then
                    funget()
                end
                local length = fpos - 1 - at
                text, tsize = at, length + 1
                -- its id: NUMBER if it starts with a digit or '-', else the static lexer's, else
                -- NUMBER or STRING (the game reads it as a C string: a NUL ends it)
                local first = length > 0 and fp[at] or 0
                if first ~= 0 and ((first >= 48 and first <= 57) or first == 45) then
                    typ = 12
                else
                    typ = -12
                    for i = at, at + length - 1 do
                        local b = fp[i]
                        if b == 0 then
                            break
                        end
                        if NUMERIC[b] == 0 then
                            typ = -15
                            break
                        end
                    end
                end
                if c == 255 then
                    rc = 0  -- the word is in _CurrTok, but GetTok says the file ended
                end
                break
            elseif id == 9 then
                -- a comment: to a line feed (read), then the next token
                typ, text, tsize = 9, at, 2
                c = fget()
                if fpos <= fsize then
                    while c ~= 10 do
                        c = fget()
                        if fpos > fsize then
                            break
                        end
                    end
                end
            elseif id == 2 then
                -- a quoted string: \" and \\ lose their backslash
                local prev, cuts = 0, nil
                c = fget()
                if fpos <= fsize then
                    while true do
                        if c == 34 and prev ~= 92 then
                            break
                        end
                        if prev == 92 and (c == 34 or c == 92) then
                            cuts = cuts or {}
                            cuts[#cuts + 1] = fpos - 2  -- the backslash
                            prev = 0
                        else
                            prev = c
                        end
                        c = fget()
                        if fpos > fsize then
                            break
                        end
                    end
                end
                local from, to = at + 1, fpos - 1  -- the text: [from, to)
                local length = to - from
                if length == 0 then
                    -- "": _Val is a NUL of size 2 (what GetTok wrote over the quote)
                    escaped[#escaped + 1] = "\0"
                    text = -1 - escaped_size
                    escaped_size = escaped_size + 1
                elseif cuts == nil then
                    text = from
                else
                    local parts, p = {}, from
                    for i = 1, #cuts do
                        parts[i] = ffi.string(fp + p, cuts[i] - p)
                        p = cuts[i] + 1
                    end
                    parts[#cuts + 1] = ffi.string(fp + p, to - p)
                    local s = table.concat(parts)
                    escaped[#escaped + 1] = s
                    text = -1 - escaped_size
                    escaped_size = escaped_size + #s
                    length = #s
                end
                typ, quoted = 15, 1
                tsize = length + 1 < 2 and 2 or length + 1
                break
            else
                local combined = id < 2048 and WITH_EQ[id] or 0
                if combined ~= 0 then
                    if fget() == 61 then
                        typ, text, tsize = combined, at, 3
                    else
                        funget()
                        typ, text, tsize = id, at, 2
                    end
                else
                    typ, text, tsize = id, at, 2
                end
                break
            end
        end
        local r = records[n]
        r.rc, r.type, r.text, r.size = rc, typ, text, tsize
        r.pos, r.line, r.last, r.unget = fpos, fline, flast, fungot and 1 or 0
        r.filled, r.explicit_string = filled, quoted
        n = n + 1
        if rc == 0 then
            break
        end
    end
    fp = nil
    return records, n, table.concat(escaped)
end

local scan_failures = 0

-- lexer.records(buffer, size, pos, last, unget, line) -> records, escaped | nil: lexer.scan packed
-- for the lexer hook (src/dll/lexer_hook.cpp calls it as stellar.lexer_tokens in each thread's
-- worker state, lua/worker.lua): the calls as one string of stellar_lexer_token, and the escaped
-- strings
function lexer.records(buffer, size, pos, last, unget, line)
    local ok, records, n, escaped = pcall(lexer.scan, buffer, size, pos, last, unget, line)
    if ok then
        return ffi.string(records, n * lexer.TOKEN_SIZE), escaped
    end
    scan_failures = scan_failures + 1
    if scan_failures <= 5 then
        require("stellar").log("lexer: the scan failed: " .. tostring(records))
    end
    return nil
end

-- The text CLexer::CLexer gives a CMemoryFile for a file of type LexerFileType_UTF8_BOM (name
-- lists): without its BOM (the game logs a warning when there is none). Other files keep it.
function lexer.strip_bom(text)
    if sub(text, 1, 3) == "\239\187\191" then
        return sub(text, 4)
    end
    return text
end

return lexer
