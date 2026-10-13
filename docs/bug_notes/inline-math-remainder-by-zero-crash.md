# Inline math: a remainder by zero crashes the game

`@[ x % 0 ]` in script kills the game's process while it reads the file: an integer division by
zero, raised by the `idiv` that computes the remainder. Division by zero does not crash. `@[ x / 0 ]`
gives 42949.67295 (0xFFFFFFFF in the fixed point); only `%` is unguarded.

Affected: every version with `%` in inline math, measured from 3.12.5 to 4.5.2. Before (2.x), `%`
is an invalid character, dropped from the expression (`7 % 3` is 73), so nothing crashes.

Severity: high for modders. It's a crash to desktop while the game loads, and the log names no
file. Vanilla never uses `%` in inline math, so the unmodded game can't hit it.

The divisor doesn't have to be a literal 0. Anything that comes to 0 when the math is solved
crashes the same way:
- an expression: `@[ 7 % (1 - 1) ]`;
- a scripted variable: `@zero = 0`, then `@[ 7 % zero ]`;
- a parameter: a scripted trigger or effect with `@\[ $A$ % $B$ ]` called with `B = 0`.


# Notes

The reader evaluates inline math as it reads a value (`CReader::ParseAdvancedStatementWithVariables`),
with `NMathParser::SolveExpression<CFixedPoint>`. That function's remainder is a signed `idiv` with
no check of the divisor, so the CPU's divide error ends the process (`EXCEPTION_INT_DIVIDE_BY_ZERO`
on Windows, `SIGFPE` on Linux). Its division checks for zero and returns 0xFFFFFFFF.

The other operand pair that faults is −2^63 % −1 in raw fixed point:
`@[ -92233720368547.75808 % -0.00001 ]`, a division overflow.

Measured, not inferred:
- stellar-lua-pdxscript's oracle runs each build's own `SolveExpression<CFixedPoint>` in an
  emulator (`oracle/gamemath.lua`). A fault there comes back as `{ crash = "interrupt 0 ..." }`,
  the divide error.
- `tools/oracle_mathfuzz.lua` compares crash against crash with `pdxmath.lua` on random
  expressions, on the 3.12.5 to 4.5.2 Linux builds.
- `pdxmath.solve` returns the crash and why (`integer division by zero`, `integer division
  overflow (-2^63 / -1)`).
- `pdxreader` reports it as the bug `math_crash` and stops reading.

The Windows builds are the same code, but they weren't run for this. There is no Linux build with
symbols between 2.5.0 and 3.12.5, so the first version with `%` isn't known.

A fix in the game: check the divisor of `%` the way `/` already does.

For script: inline math has no functions or conditions to guard a divisor with (`max` is read as
an unknown variable), so a divisor that can be 0 must not reach `%`.
