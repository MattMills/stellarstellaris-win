# 1.0.x: a word longer than 256 bytes overruns the lexer's token buffer

In Stellaris 1.0.0 to 1.0.3, the text lexer (`CTextLexer::GetTok`) writes a word longer than 256
bytes (an unbroken run outside quotes) past the token's buffer. The bytes beyond land in the
token's quoted flag next to it, so the token comes out wrong.

Gone from 1.1.0: the 45 measured builds from 1.1.0 to 4.5.2 read such words correctly. Only these
early versions (2016) are affected.

Severity: low today. It's still a buffer overrun driven by a script file's text.


# Notes

Measured with stellar-lua-pdxscript's lexer oracle, which runs each build's own `GetTok` in an
emulator against its lexer cases (`oracle/README.md`: "a word longer than 256 bytes overruns the
token's buffer into its quoted flag").
- 1.0.0 to 1.0.3: 4 cases differ, all from tokens longer than 256 bytes.
- 1.1.0 to 4.5.2: none.

`pdxlexer.lua` deliberately doesn't imitate it, and counts such tokens in `long_tokens` instead.
