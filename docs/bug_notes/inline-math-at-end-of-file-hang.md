# Inline math as the last value of a file hangs the game

A script file whose very last value is inline math, such as a file that ends in `a = @[ 1 + 2 ]`,
makes the game read on past the end of the file looking for a `]`, forever. The game hangs while
it loads, with nothing in the log.

Affected: every version with inline math, 2.3.0 to 4.5.2. Vanilla never ends a file that way;
a mod can. Any statement after the math is enough to avoid it: `a = @[ 1 + 2 ] b = c` is fine.
So is math written without blanks (`@[1+2]`), which is one token ending in `]`.

Severity: high for modders. The game hangs at load time and gives no hint which file did it.


# Notes

How the game reads `@[ 1 + 2 ]` (4.5.2 Windows addresses, [text_lexer.md](../text_lexer.md)):

- The lexer's token is `@[`; a blank ends it.
- `CReader::ParseAdvancedStatementWithVariables` sees a token that starts with `@[` and doesn't end
  in `]`. It reads the rest of the math with `CTextLexer::ReadUntilCharacter(']')` (`0x1bb18e0`).
- At the end of the file the lexer has nothing more to give, but its current token is still `@[`.
  The reader takes it for another inline math value and calls `ReadUntilCharacter(']')` again.
- Past the end, `CMemoryFile::Get` (`0x1b44430`) returns 0xFF and keeps advancing. The `]` never
  comes, so the loop never ends.

Measured: stellar-lua-pdxscript runs each build's own statement reader (`CPersistent::Read`) in an
emulator on the case `bug.math_last` (`oracle/reader_cases.lua`). On every build from 2.3.0 it
runs until the oracle's 5-second time limit stops it. Only where it stops differs from build to
build. `pdxreader` reports the case as the bug `math_at_end` and stops reading there.
`lua/stellar/script/lexer.lua` (`read_until`) returns "end of file" where the game would loop.

A fix in the game: stop `ReadUntilCharacter` at the end of the file, or don't take the token left
at the end for a new value.
