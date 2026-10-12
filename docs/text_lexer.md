# The text lexer

The game reads all of its script text (files, inline scripts, the text of scripted triggers,
effects and values rewritten with their arguments) with a `CTextLexer` over a `CMemoryFile`. The
C++ readers call the lexer's virtual `GetTok` for each token. `lua/stellar/script/lexer.lua` is
that tokenizer in Lua. `src/dll/lexer_hook.cpp` hooks `GetTok`: in shadow mode it compares every
token the game reads with Lua's. Replace mode, where Lua gives the game its tokens, is the next
step.

Everything here is from Stellaris 4.5.2 (GOG and Steam builds, PDB of the GOG build). Addresses
are GOG RVAs.

## Structures

| | offset | |
|---|---|---|
| `CLexer` (320 bytes) | +0x8 | `_File`, a `CFile*` |
| | +0x10 | `_PeekRC` |
| | +0x18 | `_CurrTok`, a `CToken` (288 bytes) |
| | +0x138 | `_LexerFileType` |
| | +0x13c | `_bPeek` |
| `_CurrTok` (in the lexer) | +0x18 | `_LexerToken`, the token's id |
| | +0x1c | `_bExplicitString`, a quoted string |
| | +0x28 | `_Val`'s data (a `CPdxHybridArray<char,256>`) |
| | +0x30 | its capacity |
| | +0x34 | its size, the NUL included (2 for `""`) |
| `CFile` | +0x8 | `_LineNumber` |
| | +0x10 | `_szLastChar`, the last byte read |
| | +0x11 | `_bUnget`: the next `Get` gives the last byte again |
| | +0x30 | the file's name (an MSVC `std::string`) |
| `CMemoryFile` | +0x80 | a shared buffer (its data at +8), or null |
| | +0x88 | `_pBuffer` |
| | +0x94 | `_nPos` |
| | vtable +128 | `GetSize` |

A new `CMemoryFile` has line 1, last byte 0, nothing put back, `_nPos` 0.

## Reading the file

`CMemoryFile::Get` (vtable +8, 0x1b44430):

1. If the last byte was a line feed, the line count goes up.
2. A byte put back is given again.
3. Otherwise it gives `buffer[_nPos]`, or 0xFF past the end, and `_nPos` goes up either way.

`IsValid` (vtable +80, 0x991440) holds while `_nPos <= size`. The last byte of a file is read
like any other; it turns false only after a read past the end. `UnGet` (inlined) sets `_bUnget`
and lowers the line if the byte put back is a line feed. So a line feed put back after `<`, `>`
or `!` counts its line again when it is read.

## GetTok (0x1bb1220)

`int CLexer::GetTok()` returns 1 for a token and 0 at the end of the file. If `_bPeek` is set,
it clears it and returns `_PeekRC`: `CLexer::Peek`, inlined in the readers, calls `GetTok` and
sets these two. Otherwise it reads:

1. **Blanks**: `iswspace` of the byte as a signed char, so HT, LF, VT, FF, CR and space; a byte
   0x80 or above is never a blank. At the end of the file it returns 0 and leaves `_CurrTok` as it
   was.
2. **Single bytes**: each gets an id. The token is written at once: the id, the byte as its text,
   not quoted.

   | byte | id |
   |---|---|
   | `=` | 1 |
   | `"` | 2 (only while reading a string) |
   | `{` | 3 |
   | `}` | 4 |
   | `(` | 5 |
   | `)` | 6 |
   | `,` | 8 |
   | `#` `;` | 9 (a comment) |
   | `>` | 467 |
   | `<` | 468 |
   | `!` | 1062 |

   - `>` `<` `!` followed by `=` become 971, 972 and 1063 (`>=` `<=` `!=`). Any other byte after
     them is put back.
   - `==` is two `=` tokens; `?=` is the word `?` and then `=`.
3. **Comments** (`#`, `;`): the bytes up to a line feed are skipped and the next token is read. A
   comment that runs to the end of the file leaves `_CurrTok` as id 9 with the comment byte, and
   returns 0.
4. **Quoted strings**: everything to the next `"` that has no backslash before it. `\"` and `\\`
   lose their backslash. Any other backslash stays, and the game logs a warning. The string may
   span lines, and the end of the file ends it. The result is id 15, quoted.
5. **Words**: any other byte starts a word. The word ends at a blank (read) or at one of
   `! " # ( ) , ; < = > { }` (put back). Its id:
   - 12 (number) if it starts with a digit or `-`;
   - otherwise the static lexer's id for it, if there is one other than 12 (looked up case
     insensitively: `CTernary::Get`, slot 2 of the vtable of the token tree that 0x1bb01e0
     returns);
   - otherwise 12 if it has only digits, `.` and `-`;
   - otherwise 15 (string).

   The game reads the word as a C string, so a NUL byte ends it for these checks.

   **A word that the end of the file ends** is written to `_CurrTok`, but `GetTok` returns 0, so
   the readers never see it.

### Between tokens

`CReader::ParseAdvancedStatementWithVariables` reads the rest of an inline math token: an unquoted
`@[...` that does not end in `]`. It calls `ReadUntilCharacter(']')` (vtable +16, 0x1bb18e0),
which reads raw bytes through the same `Get`. So the file moves between two `GetTok` calls; the
hook notices and starts again from where the file is.

## The hook

`stellar.script.loader` locates everything the hook needs:
- `GetTok`, by its stellar-fnmatch signature;
- the vtable of `CMemoryFile`, from its constructor;
- the token tree, from the call in `GetTok`.

It then installs the hook at startup. The proxy `version.dll` loads StellarStellaris before the
game reads any script.

On a `GetTok` over a `CMemoryFile`:
1. The hook asks Lua (`lexer.scan`) for the calls from the file's current state. It does this
   once per text, and again whenever the file is not where the previous token left it.
2. Each thread keeps 8 texts, because a reader reads other texts (inline scripts) in the middle of
   one.
3. In shadow mode the game's `GetTok` runs. The hook compares Lua's record field by field: the
   return value, the id, the quoted flag, the text and its size, `_nPos`, the line, the last byte
   and the byte put back.
4. A word whose id Lua leaves to the static lexer (type -12 or -15) is looked up in the game's own
   token tree, as `GetTok` does.

`lexer.tokenize` is the readable reference; `lexer.scan` gives the same calls without a Lua value
per token: about 160 MB/s against 13 MB/s.

## Results (vanilla 4.5.2, Steam)

Shadow mode, a whole startup load: 13,754,674 tokens compared in 148,819 texts, 0 mismatches. That
is 21.7 million `GetTok` calls, 8 million of them returning a peeked token, and 21,078 restarts
after the file moved between tokens. Lua tokenized 117.5 MB in about 7s, on the threads that read
script and under the one Lua lock.

The log also has the load screen's progress (`stellar.loading`). The startup load has three
phases, each a part of the bar:

| phase | bar | time |
|---|---|---|
| interface (GUI) | 5% to 30% | 3s |
| graphics (GFX) | 30% to 80% | 7s |
| game databases (`InitGame`, 198 steps) | 80% to 100% | 26s |

After 100% the game still reads about 130,000 small texts before the load screen goes away: the
load is done when the load screen is gone.
