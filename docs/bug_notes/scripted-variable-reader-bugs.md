# Scripted variables: a skipped token, and a key read twice

Two quiet mistakes in the game's statement reader (`CReader::ReadSimpleStatement` in
`CPersistent::Read`), around scripted variable definitions (`@name = value`) inside a script
file. Neither crashes, and vanilla hits neither. A mod can, and gets script that doesn't do what it
says.

## A variable defined from an `@` value skips the next token (2.3.0 to 4.5.2)

When the value of a definition starts with `@`, a variable or inline math (`@a = @b`,
`@a = @[ 1 + 2 ]`), the reader resolves it and then skips the token after it. So
`@a = @[ 1 + 2 ] @b = 5` defines `a` and leaves `b` undefined: the skipped token is `@b`, and
` = 5` is read as a broken statement. (1.x does something else: `@a = @x` reads `x` as another
definition.)

## A file that ends in a variable definition reads its last key again (all versions)

When the last statement of a file is a variable definition, the reader hands the object the key of
the statement before it once more. For example, `a = 1` followed by `@x = 2` at the end of a file
reads `a` twice. (A file of only variables, like those of `common/scripted_variables`, is read by
another reader and isn't affected.)


# Notes

Both are measured: stellar-lua-pdxscript runs each of the 50 Linux builds' own reader in an
emulator on its reader cases (`oracle/reader_cases.lua`, `oracle/README.md`). Its fuzzer
(`tools/oracle_readfuzz.lua`) compares random texts with `pdxreader.lua`, which reports the two as
the bugs `variable_value_eats` and `stale_key` (`tree.bugs`); `pdxast` gives them as diagnostics.

For script: put a statement between a definition from an `@` value and whatever follows it, and
don't end a file with a variable definition.
